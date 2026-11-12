# Why this exists

quiddity is a Rust library. This is a binding of it, and a binding has to say
what a call from Elixir adds to a call from Rust.

## The engine is worth having on its own

Feature recognition from a STEP B-rep is a hard problem that quiddity already
solves: holes, pockets, slots, bosses, steps, patterns, fillets, chamfers,
grooves, sheet-metal and turned features, each with a measured size and position,
with a face-by-face account of what it could not explain. The alternative to a
binding is to reimplement that, or to shell out to another process and pass files
across. Both are worse than a function call.

## A part is a value, and geometry is a resource

- A **part** is a value functions take: `Quiddity.open/1` answers a
  `Quiddity.Part`, and every other call names it.
- A part is a **Rust resource**. It is parsed once, it never changes, and every
  process on the node uses the same one — there is no pool, no checkout and no
  copy of the geometry per process.
- Answers are **plain Elixir data**: maps, lists, floats. Nothing hands a caller
  a pointer to interpret.

That last point decides the rest of the design. Recognition documents, camera
descriptions and scene notes are document-shaped, so they arrive as decoded maps
in quiddity's own JSON shape. Points, normals, faces and depth are pixel-scale,
so they arrive as flat binaries, read with `:binary` rather than decoded element
by element.

## The exact B-rep is what makes the frame worth having

A rasteriser answers "which triangle is nearest this pixel's ray", to the
precision of the mesh. `Quiddity.frame/2` intersects the ray with the surfaces
the CAD system actually wrote, so a pixel knows the point on the surface, the
outward normal there, and which face it landed on. A curvature read off a
tessellation is the curvature of the tessellation.

`Quiddity.mesh/2` is still there for the cases that want triangles — a physics
engine, a viewer — and it is explicit about being an approximation, with a
tolerance the caller chooses.

## What it is not

It is not a CAD system, a viewer or a modelling API: it reads geometry and does
not write it. It is not a metrology pipeline, and it does not compare a scan
against a drawing. It carries no sensor model: the camera here is geometry, and
what a perception framework makes of a frame belongs in that framework's own
package.

## Where the limits are

- quiddity reports what it can prove from the geometry. A file that reads without
  errors is not a promise every feature was found; `Recognition.unexplained_faces/1`
  is where that accounting is kept.
- A B-rep has no colour. `Quiddity.Frame.rgba/2` shades by surface direction, so
  a colour read from a frame says how the surface turns, not what it is painted.
- A resource is local to its node. A `Quiddity.Part` cannot be sent to another
  node: geometry does not travel.
