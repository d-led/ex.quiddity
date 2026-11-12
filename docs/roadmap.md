# Roadmap

Not built yet, in the order it would pay. Nothing here is a promise about dates.

## 1. A MuJoCo binding of its own

`Quiddity.Mjcf` writes a part as an MJCF model. A model is not a world: stepping
one, reading its state and rendering a camera from it needs MuJoCo itself, and
there is no maintained Elixir binding of the C API.

`ex_mujoco`, as a package beside this one:

- load an MJCF/XML model, step it, read `qpos`/`qvel`/`xpos`/`sensordata`;
- render a camera to RGBA and depth offscreen, with no display;
- apply `qfrc_applied` and controls, reset, read contacts;
- ownership: an `mjModel`/`mjData` pair is mutable and not shareable, so one
  world per process behind a `Mutex` — unlike the read-only B-rep handle here.

Not in scope: writing MJCF from Elixir structures (a file is the interface) and
any modelling. `Quiddity.Mjcf` already produces the part.

## 2. An instance's placement, applied to the rays

`Quiddity.parts/1` reports where each instance of an assembly sits, but `ray/4`,
`nearest/3` and `frame/2` ask the question in the file's own coordinates, so a
caller that wants to sense instance three has to transform its ray into that
instance's frame and the answer back out. A `:place` option taking the matrix
`parts/1` already reports would put that arithmetic on the side of the boundary
where the geometry is.

## 3. Registering a scan to the part

`Quiddity.ray/4` against a B-rep is a perfect range image; a real sensor's is
noisy, partial, and in its own frame. Registering a point cloud to the part would
make the exactness usable on measured data rather than on drawings. It needs the
nearest *point* on a surface, which `Quiddity.nearest/3` does not answer today —
it names the nearest faces with a distance and a normal, which is what naming the
feature at a coordinate wants and not what ICP does.

## 4. Written by hand, not generated

`Quiddity.Api.operations/0` and `Quiddity.Native` are kept in step by a test that
calls every listed operation. That covers arity and existence; it does not cover
the argument validation each wrapper does, so a new operation is one table entry
and a written wrapper, and the test is what catches it when the two disagree.
