defmodule Quiddity.Part do
  @moduledoc """
  A STEP part, read once and asked about as often as you like.

  The struct holds the engine's handle — the parsed B-rep lives in Rust, and the
  handle is a reference to it — plus the summary that came with it. Nothing here
  is a copy of the geometry: a `Part` is a *capability* to answer questions about
  one file.

  A B-rep is immutable once read, so one handle serves every process on the node
  at once; that is the sharing the BEAM is built for, and the reason a handle
  rather than a term is what `Quiddity.open/1` answers.
  """

  @enforce_keys [:ref, :path, :summary]
  defstruct [:ref, :path, :summary]

  @type t :: %__MODULE__{
          ref: reference(),
          path: Path.t(),
          summary: map()
        }

  @doc "The part's bounding box, as `{min, max}` in millimetres."
  @spec bounds(t()) :: {[float()], [float()]}
  def bounds(%__MODULE__{summary: %{"bounds" => %{"min" => min, "max" => max}}}), do: {min, max}

  @doc "The extent of the part along each axis, in millimetres."
  @spec extent(t()) :: [float()]
  def extent(%__MODULE__{summary: %{"extent" => extent}}), do: extent

  @doc "How many faces the B-rep has — the numbers `Quiddity.face/2` takes."
  @spec face_count(t()) :: non_neg_integer()
  def face_count(%__MODULE__{summary: %{"faces" => faces}}), do: faces

  @doc """
  Whether the part is a shell with no solid behind it.

  Geometry questions still answer, but "inside" and "outside" do not: a shell
  has no authority to say which side is material, so a ray's first hit is the
  only hit that means anything.
  """
  @spec shell?(t()) :: boolean()
  def shell?(%__MODULE__{summary: %{"shell_only" => shell_only}}), do: shell_only

  @doc "Faces the kernel could not resolve; a ray may pass through one."
  @spec unresolved_faces(t()) :: [non_neg_integer()]
  def unresolved_faces(%__MODULE__{summary: %{"unresolved_faces" => faces}}), do: faces

  @doc "The centre of the bounding box, in millimetres."
  @spec centre(t()) :: [float()]
  def centre(%__MODULE__{} = part) do
    {min, max} = bounds(part)
    Enum.zip_with(min, max, fn a, b -> (a + b) / 2 end)
  end

  @doc "The part's diagonal, in millimetres: the scale a tolerant question uses."
  @spec diagonal(t()) :: float()
  def diagonal(%__MODULE__{} = part) do
    part |> extent() |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()
  end
end
