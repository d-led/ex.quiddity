defmodule Quiddity.Error do
  @moduledoc """
  A refusal from the engine, with the code a caller can branch on.

  The codes are quiddity's own vocabulary, so a caller who reads its
  documentation is not learning a second one:

    * `"unreadable"` — the file is not there, or cannot be opened;
    * `"broken_step"` — the kernel read it and refused it (parse, unsupported,
      incomplete, or past a bound it keeps);
    * `"bad_request"` — the question was malformed: not three numbers, a camera
      with no direction, a face the part does not have;
    * `"unresolved_geometry"` — a face the ray meets has a surface the kernel
      cannot intersect, so the answer would be a guess;
    * `"internal"` — a document that could not be written.

  A refusal is a *value*, not an exception: a tool that cannot answer still
  answers, and says what to try next.
  """

  defexception [:code, :message]

  @type t :: %__MODULE__{code: String.t(), message: String.t()}

  @impl true
  def message(%__MODULE__{code: code, message: message}), do: "#{code}: #{message}"

  @doc "A refusal, from the engine's `{code, message}` pair."
  @spec new({String.t(), String.t()}) :: t()
  def new({code, message}), do: %__MODULE__{code: code, message: message}
end
