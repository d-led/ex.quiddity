# Test fixtures

Three STEP files from [quiddity](https://github.com/pzfreo/quiddity)'s own test
suite (`tests/fixtures/`), used under its Apache-2.0 licence:

| File                        | What it is                                                   |
| --------------------------- | ------------------------------------------------------------ |
| `golden_simple_through_hole.step` | a 60 × 50 × 18 mm plate with one through hole and a boss |
| `blend_r5.step`             | a part with an R5 blend                                      |
| `blend_r5_enlarged.step`    | the same part with the blend enlarged — a second revision    |

The two `blend_r5` files are a revision pair, which is what `Quiddity.correspond/2`
is asked about.

Their golden expectations live in quiddity's `tests/`, not here: this package's
tests state what *this* wrapper must answer (a face count, a hole with a
diameter, a ray that meets the plate), not quiddity's recognition corpus.
