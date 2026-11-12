# Changelog

## 0.1.2

The version to install. 0.1.0 was staged on Hex for approval and superseded by
this one rather than shipped.

### Added

- Two cases translated from quiddity's own high-level suite, one case for one:
  `tests/determinism.rs`'s "the recognition document is the same twice in one
  process", and `tests/face_accounting.rs`'s "every face is accounted for
  exactly once" over the goldens this package ships rather than the corpus.
  `test/quiddity/upstream_test.exs` names the cases it does not translate —
  congruence, rigid transforms, assembly layouts — and why each needs something
  this binding does not offer.

### Changed

- The package and repository description starts from what this is — a wrapper of
  quiddity — instead of from a list of the features it recognises.

## 0.1.0

The first release: quiddity on the BEAM.

### Added

- **The engine.** A Rustler binding of quiddity 0.5 and haecceity 0.5: open a
  STEP file once into a handle and ask it questions — recognition, face
  accounting, fingerprints, correspondence between revisions, semantic AP242
  PMI, assembly parts, volume/area/centroid, point classification, rays, meshes
  and surface samples.
- **Exact frames.** `Quiddity.frame/2` casts a camera's rays against the B-rep:
  a point, an outward normal, a face and a depth per pixel, with `Quiddity.Camera`
  building the pinhole camera and `Quiddity.Frame` decoding the answer.
- **A scene.** `Quiddity.Mjcf` writes the meshed part as a MuJoCo model, in
  metres.
- **An MCP server.** `mix quiddity.mcp` — seven tools over stdio, one part
  opened once per process.
- **Generated wrappers.** `Quiddity.Api.operations/0` is the one list of engine
  operations; `Quiddity.Native`'s stubs and arities are generated from it, and a
  test holds the two together.
