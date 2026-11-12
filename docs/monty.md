# The bridge to Monty

What `Quiddity.Percept`, `Quiddity.Monty.Training` and `Quiddity.Mjcf` do, what
they deliberately do not do, and how to check each claim.

## The percept is Monty's own

The temptation is to compute "features" from the B-rep directly: the surface
normal is a property of the surface, the principal curvatures have closed forms
for a cylinder, and a node could be built in microseconds. That would be a
percept nobody else makes. A graph trained on it would not be the graph a run
matches against, and every difference would be a silent domain gap.

So a percept here is produced the way a run produces one:

1. `Quiddity.frame/2` renders a camera frame against the exact B-rep: per pixel a
   point, an outward normal, a face and a depth.
2. `Quiddity.Percept.observation/2` lays it out as Monty's sensor modules read it
   — `"semantic_3d"` (one row per pixel, `[x, y, z, semantic_id]`), `"rgba"`,
   `"depth"`, `"semantic"` and `"cam_to_world"`.
3. `Monty.Frameworks.Models.SensorModules.ObservationProcessor.process/2` — the
   ported Monty module, not a copy — fits the surface, finds the principal
   curvatures and assembles the message.

What a test holds: on a flat face the fitted principal curvatures are zero, the
pose vector's first row is the surface normal in the sensor's own frame, and
`on_object` is `1.0` exactly where the frame met the part.

### Two conventions worth knowing

- **A pose vector is in the sensor's frame.** A patch reading a surface straight
  on reports a normal of `[0, 0, -1]`, because a camera looks along its own −z.
  This is Monty's convention, and it is the one a graph stores.
- **`on_object` is read from the fourth column of `semantic_3d`.** A CAD frame
  puts the object's semantic id there (`1`) for a pixel that met the part and
  `0.0` for background, which is what the processor reads.

## A node is a visit, and a visit has to see something

`Quiddity.Monty.Training.nodes/2` spreads points over the surface at a spacing,
and stands a patch sensor `distance` mm off each, looking at it. A visit whose
patch is mostly off the part — the sensor is on a face's edge — is **skipped**,
not stored: its centre pixel misses, the fit has too little to fit, and the
features would describe nothing. A surface agent never *is* on an edge, because
contact keeps it inside a face, so skipping is what makes the graph look like a
run's.

The answer says how many visits were made and how many were skipped, so the
number of nodes is never a mystery.

### Labels

Each node carries the face it was placed on and the family quiddity assigned that
face: `"holes"`, `"bosses"`, `"risers"`, or `nil` for plain stock. That is the
supervised part — the graph knows what it is looking at, rather than inferring it
from evidence.

## The library file

`Quiddity.Monty.Library` writes the format a run loads: one gzipped JSON record
per object and input channel, holding `positions` (one per node) and `features`
(one column per feature name, as long as `positions`).

```json
{"object_id": "through_hole_plate", "input_channel": "patch",
 "positions": [[15.0, -0.05, 13.0], …],
 "features": {"pose_vectors": [[[…],[…],[…]], …], "principal_curvatures_log": [[0.0,0.0], …]},
 "lm_index": 0}
```

`Monty.Studio.Memory` in the studio reads it back into a `GraphMemory` and
matches with it; a test here reads it the same way and checks the columns line up.

## What is not faithful, said out loud

- **Shading, not colour.** A STEP file without appearance data has no colour. The
  `rgba` image is lit from the upper left of the camera, so an `hsv` feature read
  from a CAD frame says how the surface turns, not what it is painted. A run
  matching on `hsv` against a CAD-trained library is matching on shading.
- **No exploration policy.** A training episode also learns where to look; a CAD
  library holds the part, evenly, and nothing about actions.
- **Millimetres.** Every coordinate is the file's own. A run's world may work in
  metres (MuJoCo does); the MJCF writer divides by 1000 and nothing else does.

## The MuJoCo scene

`Quiddity.Mjcf.document/2` meshes the part and writes an MJCF model in metres:
one body, one mesh geometry, no body/sensors/actuators. A scene is a *place*; the
agent is the experiment's, and duplicating its description here would be a second
source of truth for the same thing.
