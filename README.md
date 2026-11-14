# ex_quiddity

Read a STEP file and ask what it *is*: its holes, pockets, slots, bosses,
fillets and turned features, where its surfaces are, and what a sensor placed on
it would perceive.

It binds [quiddity](https://github.com/pzfreo/quiddity) and
[haecceity](https://github.com/pzfreo/quiddity/tree/main/crates/haecceity) — both
pure Rust, no OpenCascade and no CAD system behind them — through Rustler. The
geometry is the B-rep itself, so a ray hits the surface rather than a mesh of it.

```elixir
{:ok, part} = Quiddity.open("bracket.step")
{:ok, recognition} = Quiddity.features(part)

Quiddity.Recognition.families(recognition)
#=> [{"holes", 4}, {"fillets", 6}, {"pockets", 1}]
```

Everything is in millimetres, in the file's own coordinates, and the same file
always gives the same answer.

## What it answers

| Question                        | Call                                               |
| ------------------------------- | -------------------------------------------------- |
| What is this part?              | `Quiddity.open/1`, `Quiddity.features/1`           |
| What is this face, and whose?   | `Quiddity.face/2`, `Quiddity.Recognition.owner/2`  |
| What is at this point?          | `Quiddity.ray/4`, `Quiddity.nearest/3`             |
| Inside, outside, or on it?      | `Quiddity.classify/2`                              |
| How heavy is it?                | `Quiddity.mass/2`                                  |
| What would a camera see?        | `Quiddity.frame/2`                                 |
| What does the file demand?      | `Quiddity.pmi/2` — dimensions, tolerances, datums  |
| What changed between revisions? | `Quiddity.correspond/2`                            |
| What is it made of?             | `Quiddity.mesh/2`, `Quiddity.samples/2`            |

A frame is the interesting one: rays are cast against the **exact B-rep**, so
every pixel knows the point on the surface, the outward normal there, and which
face it landed on — not a depth buffer's approximation of it.

## Install

```elixir
def deps do
  [{:ex_quiddity, "~> 0.1.3"}]
end
```

The Rust engine is compiled when the dependency is: **building wants a Rust
toolchain** (`scripts/install-rust.sh` installs one), and running wants none.

## As an MCP server

`mix quiddity.mcp` speaks the Model Context Protocol over stdio, so an assistant
can ask about a part directly:

```json
{"mcpServers": {"quiddity": {"command": "mix", "args": ["run", "--no-halt", "quiddity.mcp"]}}}
```

Seven tools: `quiddity_part`, `quiddity_features`, `quiddity_face`,
`quiddity_probe`, `quiddity_sense`, `quiddity_correspond`,
`quiddity_export_mjcf`.

## Where to find what

| Question                                         | Where                                                                                    |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| The curated surface, and the engine behind it    | [`Quiddity`](https://hexdocs.pm/ex_quiddity/Quiddity.html)                              |
| What was recognised, and what every face is      | [`Quiddity.Recognition`](https://hexdocs.pm/ex_quiddity/Quiddity.Recognition.html)       |
| Cameras, frames, points, normals, `semantic_3d`  | [`Quiddity.Camera`](https://hexdocs.pm/ex_quiddity/Quiddity.Camera.html), [`Quiddity.Frame`](https://hexdocs.pm/ex_quiddity/Quiddity.Frame.html) |
| Writing a scene for MuJoCo                       | [`Quiddity.Mjcf`](https://hexdocs.pm/ex_quiddity/Quiddity.Mjcf.html)                    |
| The protocol server and its tools                | [`Quiddity.Mcp`](https://hexdocs.pm/ex_quiddity/Quiddity.Mcp.html), [`Quiddity.Mcp.Tools`](https://hexdocs.pm/ex_quiddity/Quiddity.Mcp.Tools.html) |
| Why the wrapper exists, and what it refuses to do | [`why`](https://hexdocs.pm/ex_quiddity/why.html)                                        |
| What is not here yet                             | [`roadmap`](https://hexdocs.pm/ex_quiddity/roadmap.html)                               |
| Working on the package: the generated engine, MCP wiring, releasing | [`development`](https://hexdocs.pm/ex_quiddity/development.html)   |

The same pages are published from `main` at
[d-led.github.io/ex.quiddity](https://d-led.github.io/ex.quiddity/), with
[`llms.txt`](https://d-led.github.io/ex.quiddity/llms.txt) for a model with no
browser; [HexDocs](https://hexdocs.pm/ex_quiddity) is the released version.

## Limits, said out loud

- quiddity reports what it can prove from the geometry. A file that reads without
  errors is not a promise every feature was found:
  `Quiddity.Recognition.unexplained_faces/1` is where that promise is kept, and
  `unproved/1` names the records whose evidence it could not verify.
- A B-rep has no colour. `Quiddity.Frame.rgba/2` is *shading*, so an `hsv`
  feature read from a CAD frame says how the surface turns, not what it is
  painted.
- A geometry handle is a Rust resource: it serves every process on its node at
  once and cannot be sent to another node.
- A frame is a rendering, and what a perception or learning framework makes of it
  is that framework's business. `Quiddity.Camera.cam_to_world/1` and
  `Quiddity.Frame.semantic_3d/2` produce the two matrices such a framework
  conventionally wants; nothing here interprets them.

## Licence

MPL-2.0 (`LICENSE`). The engine it binds is Apache-2.0 and stays a dependency;
`NOTICE` says what came from where.
