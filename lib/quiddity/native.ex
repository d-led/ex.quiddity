defmodule Quiddity.Native do
  @moduledoc """
  The Rust engine: `quiddity` for what a part's features are, `haecceity` for
  where its surfaces are.

  Every answer here is either a flat binary — points, normals, face ids, depths,
  triangle indices — or a JSON string. That is deliberate. A 64 × 64 frame is
  4 096 points, and building it as nested Erlang terms one at a time in Rust
  costs more than the ray casting that found them; quiddity's own recognition
  document is already JSON, and `quiddity serve` speaks JSON, so one
  representation means nothing is modelled twice.

  A NIF is a library the BEAM loads into itself, so its absence is a raised
  `ErlangError` rather than a returned error: `loaded?/0` is the question a
  caller asks once.
  """

  use Rustler, otp_app: :ex_quiddity, crate: "brep_nif"

  # One place lists the engine's operations, and the stubs come from it: a Rust
  # function is callable here exactly when it is listed, at the arity it declares.
  require Quiddity.Api
  Quiddity.Api.define_stubs()

  @doc "Whether this VM built and loaded the engine."
  @spec loaded?() :: boolean()
  def loaded? do
    available()
  rescue
    ErlangError -> false
  end

  @doc "True, from the native side — the only way to know it is loaded."
  def available, do: :erlang.nif_error(:nif_not_loaded)
end
