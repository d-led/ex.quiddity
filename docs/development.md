# Working on the package

What a caller needs is in [`README`](readme.html). This page is for changing the
package: where the pieces are, what is generated, and how a version is published.

| Path                                | What it is                                                        |
| ----------------------------------- | ----------------------------------------------------------------- |
| `lib/quiddity.ex`                   | the curated surface: one function per question a caller asks      |
| `lib/quiddity/{part,face,camera,frame,recognition,error,mjcf}.ex` | the types and the readers over them |
| `lib/quiddity/api.ex`               | the engine's operations, as data — the one table every stub comes from |
| `lib/quiddity/native.ex`            | generated: the Rustler stubs and the decode of their flat answers  |
| `lib/quiddity/mcp.ex`, `mcp/tools.ex` | the Model Context Protocol server and its seven tools            |
| `lib/mix/tasks/quiddity.mcp.ex`     | `mix quiddity.mcp`, which an MCP client launches                  |
| `native/brep_nif/`                  | the Rust side: `src/lib.rs`, `Cargo.toml`, and the Engine's crates |
| `test/quiddity/upstream_test.exs`   | the cases translated from quiddity's own suite, and the ones that are not, and why |
| `docs/why.md`, `docs/roadmap.md`    | why the wrapper exists; what is not here yet                      |

## The engine is generated from one table

`Quiddity.Api.operations/0` lists every operation the Rust side has, and
`Quiddity.Native` is generated from it at compile time — the stubs, their
arities, and the MCP catalogue all come from the one list. A Rust function that
is not listed cannot be called, and a listed one that does not exist fails a test
rather than a call.

Adding an operation is therefore two edits: the function in `native/brep_nif/src/lib.rs`,
and its row in `@operations`. `test/quiddity/api_test.exs` proves the two agree,
so a missing half is a red test rather than a call that fails at run time.

## Tests

`mix test` builds the Rust engine and runs the suite against the fixtures in
`test/fixtures`: behaviour through the curated surface, the operation table, and
the MCP tools. `test/quiddity/upstream_test.exs` is the record of what was
translated from quiddity's own tests, one case for one, and it names the cases
that were not translated and why — congruence, rigid transforms and assembly
layouts need something this binding does not offer.

## CI and publishing

`.github/workflows/ci.yml` proves a commit; `.github/workflows/docs.yml` publishes
the documentation from `main` to d-led.github.io/ex_quiddity;
`.github/workflows/release.yml` publishes a tag to Hex and needs the
`HEX_API_KEY` secret on this repository.

Nothing is published from a branch: `ci` proves a commit, a tag says it is a
version. The version lives in `VERSION` and is written into `mix.exs` (and the
dependency line in the README) by the script that moves it:

```bash
elixir scripts/release.exs bump patch     # 0.1.2 -> 0.1.3, in every file
git add -A && git commit -m "release: 0.1.3" && git push
./scripts/tag_and_push_version.sh          # refuses a dirty tree or red CI
```

Then watch the release run: the package and the documentation are staged for
approval on Hex separately, so `mix hex.publish` succeeding is not the same as
being installable.
