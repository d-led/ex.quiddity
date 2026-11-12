# ex_quiddity

Manufacturing features of a STEP part, and the exact geometry under them, from
Elixir — with the bridge that lets [Monty](https://thousandbrains.org) learn an
object from a CAD file.

It is a binding of [quiddity](https://github.com/pzfreo/quiddity) and
[haecceity](https://github.com/pzfreo/quiddity/tree/main/crates/haecceity), both
pure Rust with no OpenCascade and no CAD system: read a STEP file, and ask what
its holes, pockets, slots, bosses, fillets and turned features are, where its
surfaces are, and what a sensor placed on it would perceive.

```elixir
{:ok, part} = Quiddity.open("bracket.step")
{:ok, recognition} = Quiddity.features(part)

Quiddity.Recognition.families(recognition)
#=> [{"holes", 4}, {"fillets", 6}, {"pockets", 1}]
```

Everything is in millimetres, in the file's own coordinates, and the same file
always gives the same answer.

## What it answers

| Question                     | Call                                          |
| ---------------------------- | --------------------------------------------- |
| What is this part?           | `Quiddity.open/1`, `Quiddity.features/1`      |
| What is this face, and whose? | `Quiddity.face/2`, `Quiddity.Recognition.owner/2` |
| What is at this point?       | `Quiddity.ray/4`, `Quiddity.nearest/3`        |
| Inside, outside, or on it?   | `Quiddity.classify/2`                         |
| How heavy is it?             | `Quiddity.mass/2`                             |
| What would a camera see?     | `Quiddity.frame/2`                            |
| What does the file demand?   | `Quiddity.pmi/2` — dimensions, tolerances, datums |
| What changed between revisions? | `Quiddity.correspond/2`                     |
| What is it made of?          | `Quiddity.mesh/2`, `Quiddity.samples/2`       |

A frame is the interesting one: rays are cast against the **exact B-rep**, so
every pixel knows the point on the surface, the outward normal there, and which
face it landed on — not a depth buffer's approximation of it.

## The bridge to Monty

[Monty](https://thousandbrains.org) is a sensorimotor learning framework: it
learns an object by touching it, and recognises it later from partial sensing.
A CAD part is the one object it cannot be trained on the usual way — nobody can
feel every point of it — and a CAD part is also the one object whose surface is
known exactly. So:

```elixir
{:ok, part} = Quiddity.open("bracket.step")

# What Monty's own sensor modules perceive here:
{:ok, camera} = Quiddity.Camera.patch([15.0, 0.0, 13.0], [0.0, 0.0, 1.0], distance: 5.0)
{:ok, frame} = Quiddity.frame(part, camera)
{:ok, message} = Quiddity.Percept.message(frame)
Quiddity.Percept.node_features(message)
#=> %{"pose_vectors" => [...], "principal_curvatures_log" => [0.0, 0.0], ...}

# A graph memory a Monty run loads:
{:ok, written} = Quiddity.Monty.Training.write(part, "bracket", "bracket.jsonl.gz")
written.nodes
#=> 186
```

The percept is **Monty's own**
(`Monty.Frameworks.Models.SensorModules.ObservationProcessor` over the frame),
not a re-implementation — so a node trained from a CAD part is the percept a run
would have made. The labels are the supervised part: quiddity says which face
each node is on, and which feature that face belongs to, so nothing is concluded
from evidence. And `Quiddity.Mjcf` writes the same part as a MuJoCo scene for a
world where the agent has to make real contact.

`docs/monty.md` says exactly what is faithful and what is not.

## As an MCP server

`mix quiddity.mcp` speaks the Model Context Protocol over stdio, so an assistant
can ask about a part directly:

```json
{"mcpServers": {"quiddity": {"command": "mix", "args": ["run", "--no-halt", "quiddity.mcp"]}}}
```

Nine tools: `quiddity_part`, `quiddity_features`, `quiddity_face`,
`quiddity_probe`, `quiddity_sense`, `monty_perceive`, `monty_train`,
`quiddity_export_mjcf`, `quiddity_correspond`.

## Install

```elixir
def deps do
  [{:ex_quiddity, "~> 0.1"}]
end
```

The Rust engine is compiled when the dependency is: **building wants a Rust
toolchain** (`scripts/install-rust.sh` installs one), and running wants none.

## The engine is generated from one table

`Quiddity.Api.operations/0` lists every operation the Rust side has, and
`Quiddity.Native` is generated from it at compile time — the stubs, their
arities, and the MCP catalogue all come from the one list. A Rust function that
is not listed cannot be called, and a listed one that does not exist fails a
test rather than a call.

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
- A CAD-built graph memory holds the part, densely and evenly. It does not hold
  an exploration policy — that is what a training episode is for.

## Licence

MPL-2.0 (`LICENSE`). The engine it binds is Apache-2.0 and stays a dependency;
`NOTICE` says what came from where.
