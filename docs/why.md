# Why this exists

Two tools answer questions about a physical part, and neither can answer the
other's.

**quiddity** reads a STEP file and says what the part *is*: a Ø8 hole through the
plate, a counterbore, six fillets, a pattern of pockets. It works from the B-rep
alone — the exact surfaces a CAD system wrote — so its answers are precise, and
it needs the whole file to give them.

**Monty** learns an object by sensing it: a patch of surface here, another there,
evidence accumulating about which object this is and where on it the sensor is.
It works from partial, noisy, local information — a touch, a depth patch, a
sequence of them — which is what a real machine has.

A CAD part sits between them, and that is what this package is for.

## What quiddity has that Monty cannot get on its own

A part's surface, exactly, and the labels. Monty's pretrained memories come from
episodes: an agent explores an object and stores what it perceived. That works,
and it is slow, uneven (the agent explores what it happened to touch), and it
cannot tell you *why* a region is called what it is called.

A CAD part has been explored already. Sampling its surface at a chosen spacing
gives a graph memory that is dense and even, and the recognition labels every
face, so each node knows which feature it belongs to — a hole's wall, a fillet,
plain stock — without concluding it from evidence. That is supervised training
without a supervisor: the drawing is the supervision.

## What Monty has that quiddity cannot get on its own

Robustness to *not* having the file. quiddity needs a well-formed B-rep; a real
inspection touches a part, sees a patch of it, and has no idea which half of the
drawing it is on. Monty's whole machinery — hypotheses, evidence, voting between
modules — is about deciding that from partial information.

So the two compose in both directions:

- **training**: CAD → sampled percepts → a graph memory a run loads;
- **interpretation**: a sensed patch → Monty's percept → the same features
  quiddity would name, because the graph was built from the same percepts. And
  `Quiddity.ray/4` and `Quiddity.nearest/3` answer what is under a coordinate against the exact B-rep,
  which is how a sensed point becomes a named feature.

## Where MuJoCo comes in

A B-rep can be ray cast exactly, which is what `Quiddity.frame/2` does — but a
surface agent that has to make contact, slide along a wall and be pushed around
needs a physics engine. `Quiddity.Mjcf` writes the meshed part as a MuJoCo scene,
so the same part can be explored by a body with contacts as well as by rays. The
scene holds the part and nothing else: the body, its sensors and its actuators
are the experiment's.

## What this is not

It is not a model of an inspection cell, and it is not a substitute for a
metrology pipeline. It is the join between a drawing and a sensorimotor learner,
built so that each side keeps its own vocabulary: quiddity's faces and families
on one side, Monty's locations, poses and evidence on the other, and one module
where they meet.
