# Changelog

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
