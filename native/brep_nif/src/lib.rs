//! Quiddity on the BEAM: a parsed STEP part that stays parsed, and the four
//! questions a robot arm's sensor has about it.
//!
//! Everything here is `quiddity` and `haecceity` doing the work; this module is
//! the boundary. It holds one `Part` per handle — a B-rep is read-only once
//! read, so sharing one is safe and re-reading it is the only thing that would
//! cost — and it answers in flat binaries, because a 64 × 64 frame is 4 096
//! points and building that as nested Erlang terms one at a time would cost more
//! than the ray casting did.
//!
//! Answers that are *about* a part rather than *geometry* are JSON strings:
//! quiddity's own recognition document is JSON, `quiddity serve` speaks JSON,
//! and one representation means the Elixir side has nothing to model twice.
//!
//! No `unwrap`, `expect`, `panic!` or index arithmetic that can go out of bounds
//! on file-driven data: a NIF panic takes the whole VM down, so a refusal is
//! always an `Err` the Elixir side can print.

use std::path::Path;

use haecceity::brep::Part;
use haecceity::classify::Classifier;
use haecceity::cloud::FaceProbe;
use haecceity::geom::{self, V3};
use haecceity::rays::RayCaster;
use rustler::{Binary, Env, NewBinary, ResourceArc};
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};

/// A parsed part, and nothing else: `Part` is immutable once read.
struct Brep {
    /// Kept for the questions that are about the *file* rather than the geometry
    /// — its semantic PMI and its assembly structure are read from the STEP text.
    path: String,
    part: Part,
}

// A B-rep is read-only once read, so handing one to several processes is the
// immutable-shared-reference the BEAM is designed for: a frame is computed from
// it, never written into it.
//
// `resource_impl` is not decoration: it is what submits the type to Rustler's
// inventory, so the loader registers it with the VM. Without it a `ResourceArc`
// has no resource type and `ResourceArc::new` panics.
#[rustler::resource_impl]
impl rustler::Resource for Brep {}

/// The refusal shape every NIF here answers: a code a caller can branch on and a
/// sentence a person can read.
type Refusal = (String, String);

fn refusal(code: &str, message: impl Into<String>) -> Refusal {
    (code.to_string(), message.into())
}

/// Always true, from the native side: the only way to know this library loaded.
///
/// `Quiddity.Native.loaded?/0` asks this and treats a `:nif_not_loaded` raise as
/// the answer "no", which is how a VM that never built the crate says so.
#[rustler::nif]
fn available() -> bool {
    true
}

// -- reading ---------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn brep_open(path: String) -> Result<(ResourceArc<Brep>, String), Refusal> {
    if !Path::new(&path).is_file() {
        return Err(refusal("unreadable", format!("{path}: no such file")));
    }

    let bytes = std::fs::read(&path)
        .map_err(|e| refusal("unreadable", format!("{path}: {e}")))?;

    // The hash of the bytes as they arrived: a part is identified by the file it
    // came from, and a run's record keeps that identity rather than a path that
    // may point at a different revision tomorrow.
    let source_sha256 = Sha256::digest(&bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();

    let part = quiddity::read_step_file(Path::new(&path))
        .map_err(|e| refusal("broken_step", format!("{path}: {e}")))?;

    let bounds = part.bounds();
    let summary = json!({
        "path": path,
        "sha256": source_sha256,
        "bytes": bytes.len(),
        "faces": part.faces.len(),
        "edges": part.edges.len(),
        "solids": part.solids.len(),
        "shell_only": part.solids.is_empty(),
        "bounds": { "min": bounds.min, "max": bounds.max },
        "extent": geom::sub(bounds.max, bounds.min),
        "units": "mm",
        "valid_solids": (0..part.solids.len()).map(|s| part.solid_is_valid(s)).collect::<Vec<_>>(),
        "unresolved_faces": part.unresolved_faces(),
        "unresolved_edges": part.unresolved_edges(),
        "input_repairs": part.input_repairs(),
    });

    Ok((
        ResourceArc::new(Brep {
            path: path.clone(),
            part,
        }),
        summary.to_string(),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn brep_recognise(brep: ResourceArc<Brep>) -> Result<String, Refusal> {
    let recognized = quiddity::correspondence::recognise(&brep.part);
    let document = quiddity::recognition::document(&recognized, brep.part.faces.len());

    serde_json::to_string(&document)
        .map_err(|e| refusal("internal", format!("cannot write the document: {e}")))
}

// -- a sensor's frame ------------------------------------------------------

#[derive(Deserialize)]
struct Camera {
    origin: [f64; 3],
    forward: [f64; 3],
    right: [f64; 3],
    up: [f64; 3],
    width: u32,
    height: u32,
    #[serde(default = "default_fov")]
    fov_x: f64,
    #[serde(default)]
    near: f64,
    #[serde(default = "default_far")]
    far: f64,
}

fn default_fov() -> f64 {
    // 66 degrees: the horizontal field of view the MuJoCo worlds give a patch
    // camera, so a CAD frame and a simulator frame cover the same solid angle.
    66.0_f64.to_radians()
}

fn default_far() -> f64 {
    // 10 m: past any part this tool is for, so a background pixel is the far
    // plane rather than a number a caller has to interpret.
    10_000.0
}

/// An orthonormal basis from what a caller passed.
///
/// `forward` is what the camera looks along and is taken as given; `up` decides
/// the roll, and `right` is the fallback for a camera whose up is parallel to
/// its view direction (looking straight down, say). A caller that built its
/// camera from a look-at leaves these slightly off-square, so they are squared
/// up here rather than trusted.
fn basis(camera: &Camera) -> Option<(V3, V3, V3)> {
    let forward = geom::unit(camera.forward)?;
    let up = geom::unit(geom::sub(
        camera.up,
        geom::scale(forward, geom::dot(camera.up, forward)),
    ))
    .or_else(|| geom::unit(geom::cross(camera.right, forward)))?;
    let right = geom::cross(forward, up);
    Some((forward, right, up))
}

/// What one pixel sees: where the ray met the part, the outward normal there,
/// which face claimed it, and how far along the ray.
struct Sample {
    point: V3,
    normal: V3,
    face: Option<usize>,
    t: f64,
}

fn caster(part: &Part) -> RayCaster<'_> {
    if part.solids.is_empty() {
        RayCaster::for_faces(part, (0..part.faces.len()).collect())
    } else {
        RayCaster::for_solid(part, 0)
    }
}

fn cast(part: &Part, rays: &RayCaster<'_>, origin: V3, direction: V3, far: f64) -> Sample {
    let hit = rays
        .hits(origin, direction, far)
        .and_then(|hits| hits.into_iter().next());

    match hit {
        Some(hit) => {
            let point = geom::add(origin, geom::scale(direction, hit.t));
            // A face the ray met has a normal at that point; a pole or an apex
            // has none, and the ray's own direction is the honest stand-in
            // (a normal pointing back at the sensor is what a surface facing
            // the sensor means).
            let normal = part
                .normal_at_point(hit.face, point)
                .unwrap_or_else(|| geom::scale(direction, -1.0));
            Sample {
                point,
                normal,
                face: Some(hit.face),
                t: hit.t,
            }
        }
        None => Sample {
            point: geom::add(origin, geom::scale(direction, far)),
            normal: geom::scale(direction, -1.0),
            face: None,
            t: far,
        },
    }
}

/// One frame: for each pixel, the point on the part the ray met, the normal
/// there, the face that claimed it and the distance along the ray.
///
/// Answers `(points, normals, faces, depth)` — `3 * w * h` little-endian f64,
/// `3 * w * h` f64, `w * h` u32 (`4_294_967_295` where the ray met nothing) and
/// `w * h` f64.
#[rustler::nif(schedule = "DirtyCpu")]
fn brep_frame<'a>(
    env: Env<'a>,
    brep: ResourceArc<Brep>,
    camera_json: String,
) -> Result<
    (
        Binary<'a>,
        Binary<'a>,
        Binary<'a>,
        Binary<'a>,
    ),
    Refusal,
> {
    let camera: Camera = serde_json::from_str(&camera_json)
        .map_err(|e| refusal("bad_request", format!("cannot read the camera: {e}")))?;

    if camera.width == 0 || camera.height == 0 || camera.width > 1024 || camera.height > 1024 {
        return Err(refusal(
            "bad_request",
            format!(
                "a frame is between 1 and 1024 pixels a side, not {} x {}",
                camera.width, camera.height
            ),
        ));
    }

    if !(camera.fov_x > 0.0 && camera.fov_x < std::f64::consts::PI) || !(camera.far > camera.near) {
        return Err(refusal(
            "bad_request",
            "the camera needs a field of view between 0 and 180 degrees and far beyond near",
        ));
    }

    let (forward, right, up) = basis(&camera)
        .ok_or_else(|| refusal("bad_request", "the camera's axes do not span a direction"))?;

    let pixels = (camera.width as usize) * (camera.height as usize);
    let mut points = NewBinary::new(env, pixels * 24);
    let mut normals = NewBinary::new(env, pixels * 24);
    let mut faces = NewBinary::new(env, pixels * 4);
    let mut depth = NewBinary::new(env, pixels * 8);

    let rays = caster(&brep.part);
    let origin = camera.origin;
    // One pixel's angular width, as the tangent the ray's offset is measured in.
    let step = 2.0 * (camera.fov_x / 2.0).tan() / camera.width as f64;
    let (half_w, half_h) = (camera.width as f64 / 2.0, camera.height as f64 / 2.0);

    for row in 0..camera.height {
        for column in 0..camera.width {
            let x = (column as f64 + 0.5 - half_w) * step;
            // Screen rows run down, the camera's `up` runs up.
            let y = (half_h - (row as f64 + 0.5)) * step;
            let direction = geom::unit(geom::add(
                forward,
                geom::add(geom::scale(right, x), geom::scale(up, y)),
            ))
            .unwrap_or(forward);

            let sample = cast(&brep.part, &rays, origin, direction, camera.far);
            let index = (row as usize) * (camera.width as usize) + column as usize;

            write_v3(&mut points, index * 24, sample.point);
            write_v3(&mut normals, index * 24, sample.normal);
            faces[index * 4..(index + 1) * 4]
                .copy_from_slice(&(sample.face.map(|f| f as u32).unwrap_or(u32::MAX)).to_le_bytes());
            depth[index * 8..(index + 1) * 8].copy_from_slice(&sample.t.to_le_bytes());
        }
    }

    Ok((points.into(), normals.into(), faces.into(), depth.into()))
}

fn write_v3(binary: &mut NewBinary<'_>, at: usize, value: V3) {
    for (axis, component) in value.iter().enumerate() {
        let start = at + axis * 8;
        binary[start..start + 8].copy_from_slice(&component.to_le_bytes());
    }
}

// -- triangles, for a scene or a viewer -----------------------------------

/// The part as triangles: `(points, indices, face_of_triangle, meta)`.
///
/// `points` is `3 * n` f64, one vertex after another; `indices` is `3 * t` u32
/// into it; `face_of_triangle` is `t` u32 naming the B-rep face each triangle
/// came from, which is what lets a rendered part be coloured by feature. A face
/// that will not mesh is counted in `meta`, never silently dropped.
#[rustler::nif(schedule = "DirtyCpu")]
fn brep_mesh<'a>(
    env: Env<'a>,
    brep: ResourceArc<Brep>,
    deflection: f64,
    angular: f64,
) -> Result<(Binary<'a>, Binary<'a>, Binary<'a>, String), Refusal> {
    if !(deflection > 0.0) || !(angular > 0.0 && angular < std::f64::consts::PI) {
        return Err(refusal(
            "bad_request",
            "a mesh needs a positive deflection and an angular tolerance under 180 degrees",
        ));
    }

    let meshes = brep.part.mesh(deflection, angular);
    let mut vertices: Vec<V3> = Vec::new();
    let mut indices: Vec<u32> = Vec::new();
    let mut face_of_triangle: Vec<u32> = Vec::new();
    let mut refused: Vec<usize> = Vec::new();
    let mut unconverged: Vec<usize> = Vec::new();

    for (face, mesh) in meshes.iter().enumerate() {
        let Ok(mesh) = mesh else {
            refused.push(face);
            continue;
        };

        if !mesh.converged {
            unconverged.push(face);
        }

        let base = vertices.len() as u32;
        vertices.extend_from_slice(&mesh.points);

        for triangle in &mesh.triangles {
            for corner in triangle {
                indices.push(base + *corner as u32);
            }
            face_of_triangle.push(face as u32);
        }
    }

    let mut points = NewBinary::new(env, vertices.len() * 24);
    for (index, vertex) in vertices.iter().enumerate() {
        write_v3(&mut points, index * 24, *vertex);
    }

    let mut triangles = NewBinary::new(env, indices.len() * 4);
    for (index, value) in indices.iter().enumerate() {
        triangles[index * 4..(index + 1) * 4].copy_from_slice(&value.to_le_bytes());
    }

    let mut owners = NewBinary::new(env, face_of_triangle.len() * 4);
    for (index, value) in face_of_triangle.iter().enumerate() {
        owners[index * 4..(index + 1) * 4].copy_from_slice(&value.to_le_bytes());
    }

    let meta = json!({
        "vertices": vertices.len(),
        "triangles": face_of_triangle.len(),
        "faces": brep.part.faces.len(),
        "refused_faces": refused,
        "unconverged_faces": unconverged,
        "deflection": deflection,
        "angular": angular,
        "units": "mm",
    });

    Ok((
        points.into(),
        triangles.into(),
        owners.into(),
        meta.to_string(),
    ))
}

// -- points on the surface, for a graph memory ----------------------------

/// Points spread over the part's surface, `spacing` millimetres apart:
/// `(points, normals, faces, meta)`.
///
/// This is what a superlative sensor would see: the surface itself, sampled
/// evenly, with the outward normal at each point. Each face is meshed finely
/// enough that the triangle interiors carry the geometry (`deflection` is a
/// quarter of `spacing`), and the lattice points inside each triangle are taken
/// in barycentric coordinates — so the sample density is per area, not per face,
/// and a small fillet is sampled as well as a large plate.
#[rustler::nif(schedule = "DirtyCpu")]
fn brep_samples<'a>(
    env: Env<'a>,
    brep: ResourceArc<Brep>,
    spacing: f64,
    limit: u32,
) -> Result<(Binary<'a>, Binary<'a>, Binary<'a>, String), Refusal> {
    if !(spacing > 0.0) || spacing > 1_000.0 {
        return Err(refusal(
            "bad_request",
            "a sample spacing is between 0 and 1000 mm",
        ));
    }

    let limit = limit.max(1) as usize;
    let deflection = (spacing / 4.0).max(0.001);
    let meshes = brep.part.mesh(deflection, 0.5);

    let mut out_points: Vec<V3> = Vec::new();
    let mut out_normals: Vec<V3> = Vec::new();
    let mut out_faces: Vec<u32> = Vec::new();
    let mut truncated = false;
    // One point per cell of a `spacing` grid. A finely meshed face has many small
    // triangles, and three lattice points *each* would make the density follow
    // the mesh rather than the spacing asked for; a cell that already gave a
    // point gives no second one, so the count follows the area.
    let mut taken: std::collections::HashSet<(i64, i64, i64)> = std::collections::HashSet::new();

    'faces: for (face, mesh) in meshes.iter().enumerate() {
        let Ok(mesh) = mesh else { continue };

        for triangle in &mesh.triangles {
            let [a, b, c] = triangle.map(|corner| mesh.points[corner]);
            let area = 0.5 * geom::norm(geom::cross(geom::sub(b, a), geom::sub(c, a)));
            // A lattice of `n` steps a side holds about `n² / 2` points, and one
            // point per `spacing²` of area is what was asked for.
            let steps = ((2.0 * area).sqrt() / spacing).ceil().max(1.0) as usize;

            for i in 0..=steps {
                for j in 0..=(steps - i) {
                    let (u, v) = (i as f64 / steps as f64, j as f64 / steps as f64);
                    let w = 1.0 - u - v;
                    let point = [
                        w * a[0] + u * b[0] + v * c[0],
                        w * a[1] + u * b[1] + v * c[1],
                        w * a[2] + u * b[2] + v * c[2],
                    ];

                    let cell = (
                        (point[0] / spacing).round() as i64,
                        (point[1] / spacing).round() as i64,
                        (point[2] / spacing).round() as i64,
                    );

                    if !taken.insert(cell) {
                        continue;
                    }

                    if out_points.len() >= limit {
                        truncated = true;
                        break 'faces;
                    }

                    let normal = brep
                        .part
                        .normal_at_point(face, point)
                        .unwrap_or_else(|| {
                            let across = geom::cross(geom::sub(b, a), geom::sub(c, a));
                            geom::scale(geom::unit(across).unwrap_or([0.0, 0.0, 1.0]), -1.0)
                        });

                    out_points.push(point);
                    out_normals.push(normal);
                    out_faces.push(face as u32);
                }
            }
        }
    }

    let mut points = NewBinary::new(env, out_points.len() * 24);
    let mut normals = NewBinary::new(env, out_normals.len() * 24);
    for (index, (point, normal)) in out_points.iter().zip(out_normals.iter()).enumerate() {
        write_v3(&mut points, index * 24, *point);
        write_v3(&mut normals, index * 24, *normal);
    }

    let mut faces = NewBinary::new(env, out_faces.len() * 4);
    for (index, face) in out_faces.iter().enumerate() {
        faces[index * 4..(index + 1) * 4].copy_from_slice(&face.to_le_bytes());
    }

    let meta = json!({
        "points": out_points.len(),
        "spacing": spacing,
        "truncated": truncated,
        "units": "mm",
    });

    Ok((
        points.into(),
        normals.into(),
        faces.into(),
        meta.to_string(),
    ))
}

// -- questions about a face or a point ------------------------------------

fn surface_json(part: &Part, face: usize) -> serde_json::Value {
    use haecceity::geom::Surface;

    match part.faces.get(face) {
        Some(brep_face) => match &brep_face.surface {
            Surface::Plane { .. } => json!({ "kind": "plane" }),
            Surface::Cylinder { radius, .. } => {
                json!({ "kind": "cylinder", "radius": radius, "diameter": 2.0 * radius })
            }
            Surface::Cone {
                radius, semi_angle, ..
            } => json!({
                "kind": "cone",
                "radius": radius,
                "semi_angle_degrees": semi_angle.to_degrees(),
            }),
            Surface::Sphere { radius, .. } => json!({ "kind": "sphere", "radius": radius }),
            Surface::Torus { major, minor, .. } => {
                json!({ "kind": "torus", "major_radius": major, "minor_radius": minor })
            }
            Surface::Freeform { kind, .. } => json!({ "kind": "freeform", "file_calls_it": kind }),
            Surface::Other { kind } => json!({ "kind": "other", "file_calls_it": kind }),
        },
        None => json!({ "kind": "unknown" }),
    }
}

/// What one face of the part is: its surface, how big it is, where it is, which
/// way it faces, and which faces it touches.
#[rustler::nif(schedule = "DirtyCpu")]
fn brep_face(brep: ResourceArc<Brep>, face: u32) -> Result<String, Refusal> {
    let face = face as usize;
    let part = &brep.part;

    if face >= part.faces.len() {
        return Err(refusal(
            "bad_request",
            format!(
                "this part has {} faces, numbered 0 to {}",
                part.faces.len(),
                part.faces.len().saturating_sub(1)
            ),
        ));
    }

    let bounds = part.face_bounds(face);
    let moments = part.face_moments(face);
    let (area, centroid, normal) = match moments {
        Some(m) => {
            let normal = part
                .normal_at_point(face, m.centroid)
                .map(|n| json!(n))
                .unwrap_or(serde_json::Value::Null);
            (json!(m.area), json!(m.centroid), normal)
        }
        None => (serde_json::Value::Null, serde_json::Value::Null, serde_json::Value::Null),
    };

    let answer = json!({
        "face": face,
        "surface": surface_json(part, face),
        "area": area,
        "centroid": centroid,
        "normal": normal,
        "bounds": { "min": bounds.min, "max": bounds.max },
        "reversed": part.faces[face].reversed,
        "neighbours": part.neighbours(face),
        "edges": part.face_edges(face),
    });

    Ok(answer.to_string())
}

/// A point or direction a caller passed, held to being three numbers.
///
/// Rustler hands a NIF a list rather than a fixed-size array, and a list of two
/// or four is a caller's mistake worth naming rather than indexing past.
fn v3(values: Vec<f64>) -> Result<V3, Refusal> {
    match values.as_slice() {
        [x, y, z] => Ok([*x, *y, *z]),
        other => Err(refusal(
            "bad_request",
            format!("a point is three numbers, and this one has {}", other.len()),
        )),
    }
}

/// Where a ray from *origin* along *direction* meets the part, nearest first.
///
/// This is the "what is under this point?" question: a hit names the face, the
/// point, the outward normal there and the distance along the ray. A ray that
/// meets nothing answers an empty list and the distance it searched, which is a
/// different fact from an error.
#[rustler::nif(schedule = "DirtyCpu")]
fn brep_ray(
    brep: ResourceArc<Brep>,
    origin: Vec<f64>,
    direction: Vec<f64>,
    far: f64,
    limit: u32,
) -> Result<String, Refusal> {
    let origin = v3(origin)?;
    let direction = geom::unit(v3(direction)?)
        .ok_or_else(|| refusal("bad_request", "a ray needs a direction"))?;
    let far = if far > 0.0 { far } else { default_far() };
    let hits = caster(&brep.part)
        .hits(origin, direction, far)
        .ok_or_else(|| {
            refusal(
                "unresolved_geometry",
                "a face this ray meets has a surface the kernel cannot intersect",
            )
        })?;

    let hits: Vec<_> = hits
        .into_iter()
        .take(limit.max(1) as usize)
        .map(|hit| {
            let point = geom::add(origin, geom::scale(direction, hit.t));
            json!({
                "face": hit.face,
                "point": point,
                "normal": brep.part.normal_at_point(hit.face, point),
                "distance": hit.t,
            })
        })
        .collect();

    Ok(json!({ "hits": hits, "searched": far, "units": "mm" }).to_string())
}

/// The faces nearest a point in space, closest first.
///
/// A ray answers "straight on"; this answers "nearby", which is what naming the
/// feature at a coordinate wants when the coordinate came from a sensor rather
/// than from the model.
#[rustler::nif(schedule = "DirtyCpu")]
fn brep_nearest(
    brep: ResourceArc<Brep>,
    point: Vec<f64>,
    limit: u32,
) -> Result<String, Refusal> {
    let point = v3(point)?;

    let mut distances: Vec<(usize, f64)> = (0..brep.part.faces.len())
        .map(|face| {
            let probe = FaceProbe::new(&brep.part, face);
            (face, probe.distance(point))
        })
        .collect();

    distances.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));

    let nearest: Vec<_> = distances
        .into_iter()
        .take(limit.max(1) as usize)
        .map(|(face, distance)| {
            let normal = part_normal_json(&brep.part, face);
            json!({ "face": face, "distance": distance, "normal": normal })
        })
        .collect();

    Ok(json!({ "nearest": nearest, "point": point, "units": "mm" }).to_string())
}

fn part_normal_json(part: &Part, face: usize) -> serde_json::Value {
    match part.face_moments(face) {
        Some(m) => match part.normal_at_point(face, m.centroid) {
            Some(n) => json!(n),
            None => serde_json::Value::Null,
        },
        None => serde_json::Value::Null,
    }
}

// -- what this build can do, and what a part is made of -------------------

/// The versioned capabilities document `quiddity capabilities` prints.
#[rustler::nif]
fn brep_capabilities() -> String {
    quiddity::file_api::capabilities()
}

/// The recognition evidence: what each feature rests on, and what was refused.
///
/// `framed` asks for part coordinates, which need an inferred frame; a file whose
/// frame cannot be inferred is answered in its own file coordinates instead, and
/// which one you got is in the document.
#[rustler::nif(schedule = "DirtyCpu")]
fn brep_evidence(brep: ResourceArc<Brep>, framed: bool) -> Result<String, Refusal> {
    quiddity::file_api::evidence(&brep.part, framed).map_err(|e| refusal("internal", e))
}

/// The part's recognition fingerprints: the revision-independent identity each
/// feature is matched by when two revisions are compared.
#[rustler::nif(schedule = "DirtyCpu")]
fn brep_fingerprints(brep: ResourceArc<Brep>) -> Result<String, Refusal> {
    let recognized = quiddity::correspondence::recognise(&brep.part);

    serde_json::to_string_pretty(&recognized.fingerprints)
        .map_err(|e| refusal("internal", format!("cannot write the fingerprints: {e}")))
}

/// What happened to each feature between two revisions.
///
/// Either side is a STEP file or a recognition JSON file — the same two things
/// `quiddity correspond` takes — and the answer says which features were
/// `carried`, `adapted` (with what changed), `orphaned` or `ambiguous`, and which
/// are new.
#[rustler::nif(schedule = "DirtyCpu")]
fn brep_correspond(old: String, new: String) -> Result<String, Refusal> {
    let revision = |path: &str| {
        quiddity::serve::fingerprints_file(path)
            .map(|(fingerprints, _warnings)| fingerprints)
            .map_err(|failure| refusal(failure.code, failure.message))
    };

    let correspondence = quiddity::serve::correspond(&revision(&old)?, &revision(&new)?)
        .map_err(|failure| refusal(failure.code, failure.message))?;

    serde_json::to_string_pretty(&correspondence)
        .map_err(|e| refusal("internal", format!("cannot write the correspondence: {e}")))
}

/// The volume, surface area and centroid of every solid, and the mass at a
/// density.
///
/// Volumes are cubic millimetres and areas square millimetres. `density` is
/// grams per cubic millimetre — 0.00785 for steel — and `null` answers no mass
/// rather than guessing a material.
#[rustler::nif(schedule = "DirtyCpu")]
fn brep_mass(brep: ResourceArc<Brep>, density: Option<f64>) -> Result<String, Refusal> {
    let solids: Vec<_> = (0..brep.part.solids.len())
        .map(|solid| {
            let (volume, area) = brep.part.solid_mass(solid).unwrap_or((0.0, 0.0));
            let mass = density.map(|density| volume * density);
            json!({
                "solid": solid,
                "volume": volume,
                "area": area,
                "mass": mass,
                "valid": brep.part.solid_is_valid(solid),
            })
        })
        .collect();

    let volume: f64 = solids
        .iter()
        .filter_map(|solid| solid["volume"].as_f64())
        .sum();

    let centroid = brep.part.volume_centroid().map(|(_, centroid)| json!(centroid));

    Ok(json!({
        "solids": solids,
        "volume": volume,
        "centroid": centroid,
        "mass": density.map(|density| volume * density),
        "density": density,
        "units": { "volume": "mm3", "area": "mm2", "length": "mm", "mass": "g" },
    })
    .to_string())
}

/// Whether a point is inside the material, outside it, on a face, or something
/// the classifier could not decide.
#[rustler::nif(schedule = "DirtyCpu")]
fn brep_classify(brep: ResourceArc<Brep>, point: Vec<f64>) -> Result<String, Refusal> {
    let point = v3(point)?;
    let state = Classifier::new(&brep.part).classify(point);

    let answer = match state {
        haecceity::classify::State::In => "in",
        haecceity::classify::State::Out => "out",
        haecceity::classify::State::On => "on",
        haecceity::classify::State::Unknown => "unknown",
    };

    Ok(json!({ "point": point, "state": answer }).to_string())
}

/// The distinct parts of the assembly this file describes: indices, names, face
/// and edge counts, and where each instance is placed.
#[rustler::nif(schedule = "DirtyCpu")]
fn brep_parts(brep: ResourceArc<Brep>) -> Result<String, Refusal> {
    let raw = std::fs::read(&brep.path)
        .map_err(|e| refusal("unreadable", format!("{}: {e}", brep.path)))?;
    let step_bytes = quiddity::kernel::step::decode_step_file_bytes(Path::new(&brep.path), raw.clone())
        .map_err(|e| refusal("broken_step", format!("{}: {e}", brep.path)))?;

    quiddity::file_api::parts(&step_bytes, &raw).map_err(|e| refusal("broken_step", e))
}

/// The file's semantic PMI — dimensions, tolerances, datums and notes — as
/// quiddity's versioned JSON, for one part or all of them.
#[rustler::nif(schedule = "DirtyCpu")]
fn brep_pmi(brep: ResourceArc<Brep>, part: Option<u32>) -> Result<String, Refusal> {
    use quiddity::kernel::pmi;
    use quiddity::pmi_json::{self, Binding};

    let raw = std::fs::read(&brep.path)
        .map_err(|e| refusal("unreadable", format!("{}: {e}", brep.path)))?;
    let step_bytes = quiddity::kernel::step::decode_step_file_bytes(Path::new(&brep.path), raw.clone())
        .map_err(|e| refusal("broken_step", format!("{}: {e}", brep.path)))?;

    let definitions = quiddity::kernel::step::read_part_definitions(&step_bytes)
        .map_err(|e| refusal("broken_step", format!("{}: {e}", brep.path)))?;

    if let Some(index) = part {
        if index as usize >= definitions.len() {
            return Err(refusal(
                "bad_request",
                format!(
                    "the file has {} parts (0 to {}); there is no part {index}",
                    definitions.len(),
                    definitions.len().saturating_sub(1)
                ),
            ));
        }
    }

    let document = quiddity::kernel::p21::Document::parse(step_bytes)
        .map_err(|e| refusal("broken_step", format!("{}: {e}", brep.path)))?;
    let read = pmi::read(&document, &definitions)
        .map_err(|e| refusal("broken_step", format!("{}: {e}", brep.path)))?;

    let answer = pmi_json::read_document(
        &read,
        &definitions,
        Binding::of(&raw),
        part.map(|index| index as usize),
    );

    serde_json::to_string_pretty(&pmi_json::document_to_json(&answer))
        .map_err(|e| refusal("internal", format!("cannot write the PMI document: {e}")))
}

// -- the module ------------------------------------------------------------

rustler::init!("Elixir.Quiddity.Native");
