defmodule Quiddity do
  @moduledoc """
  Manufacturing features of a STEP part, and the geometry under them, from
  Elixir.

  Two questions, and quiddity answers both from the B-rep alone — no CAD system,
  no feature tree, no OpenCascade, and the same file always gives the same
  answer:

    * **what is this part?** — `features/1` names its holes, pockets, slots,
      bosses, steps, patterns, fillets, chamfers, grooves, springs and turned
      profiles, with their measured sizes and positions, from
      [quiddity](https://github.com/pzfreo/quiddity);
    * **where is it?** — `ray/4`, `frame/2`, `samples/2` and `face/2` answer in
      millimetres against the exact surfaces, from `haecceity`, the kernel
      quiddity re-exports.

  ```elixir
  {:ok, part} = Quiddity.open("bracket.step")
  {:ok, recognition} = Quiddity.features(part)

  Recognition.families(recognition)
  #=> [{"holes", 4}, {"fillets", 6}, {"pockets", 1}]

  {:ok, camera} = Quiddity.Camera.looking_at([0, 0, 120], [0, 0, 0])
  {:ok, frame} = Quiddity.frame(part, camera)
  Frame.coverage(frame)
  #=> 0.62
  ```

  ## Why a handle

  `open/1` reads the file once and answers a `Quiddity.Part` holding the parsed
  B-rep. Everything else takes that handle, so a part is parsed once however many
  questions follow. A B-rep is immutable, so one handle serves every process on
  the node at once — and, because it is a resource rather than a term, it cannot
  be sent to another node, which is the honest boundary: geometry is local.

  ## The camera is geometry, not a learner

  `Quiddity.Camera` and `Quiddity.Frame` are a pinhole camera and the frame it
  renders against the exact B-rep. `Camera.cam_to_world/1` and
  `Frame.semantic_3d/2` answer the two matrices a sensor model conventionally
  takes; what a perception or learning framework makes of them is that
  framework's business, in that framework's package. Nothing here interprets
  them.

  ## Limits, said out loud

  quiddity reports what it can prove from the geometry. A file that reads without
  errors is not a promise every feature was found: `Recognition.unexplained_faces/1`
  is where that promise is kept, and `Recognition.unproved/1` names the records
  whose evidence it could not verify. A refusal is a record too, so nothing is
  silently dropped.
  """

  alias Quiddity.{Camera, Error, Face, Frame, Native, Part, Recognition}

  @doc "Whether the Rust engine is built and loaded in this VM."
  @spec loaded?() :: boolean()
  defdelegate loaded?(), to: Native

  @doc """
  Reads a STEP file.

  A `.step` or `.stp`, plain or gzipped. A refusal comes back as
  `{:error, %Quiddity.Error{}}` with quiddity's own code — `"unreadable"` for a
  file that is not there, `"broken_step"` for one the kernel read and refused.
  """
  @spec open(Path.t()) :: {:ok, Part.t()} | {:error, Error.t()}
  def open(path) when is_binary(path) do
    with :ok <- engine(),
         path = Path.expand(path),
         {:ok, {ref, summary}} <- answer(Native.brep_open(path)) do
      {:ok, %Part{ref: ref, path: path, summary: Jason.decode!(summary)}}
    end
  end

  @doc """
  What quiddity recognised in the part.

  Every face of the B-rep is accounted for: part of a feature, part of the body
  with the reason, refused, or unexplained.
  """
  @spec features(Part.t()) :: {:ok, Recognition.t()} | {:error, Error.t()}
  def features(%Part{ref: ref}) do
    with :ok <- engine(),
         {:ok, document} <- answer(Native.brep_recognise(ref)) do
      {:ok, document |> Jason.decode!() |> Recognition.parse()}
    end
  end

  @doc "One face: its surface, area, centroid, normal and neighbours."
  @spec face(Part.t(), non_neg_integer()) :: {:ok, Face.t()} | {:error, Error.t()}
  def face(%Part{ref: ref}, index) when is_integer(index) and index >= 0 do
    with :ok <- engine(),
         {:ok, json} <- answer(Native.brep_face(ref, index)) do
      {:ok, json |> Jason.decode!() |> Face.parse()}
    end
  end

  @doc """
  Where a ray from *origin* along *direction* meets the part.

  The answer is the hits, nearest first, each naming the face, the point, the
  outward normal there and the distance along the ray — plus how far the ray was
  allowed to search, because "nothing that way" needs to say how far it looked.

  Options: `:far` (millimetres, default the camera's own 10 m) and `:limit`
  (default 8).
  """
  @spec ray(Part.t(), [number()], [number()], keyword()) :: {:ok, map()} | {:error, Error.t()}
  def ray(%Part{ref: ref}, origin, direction, options \\ []) do
    with :ok <- engine(),
         {:ok, json} <-
           answer(
             Native.brep_ray(
               ref,
               numbers(origin),
               numbers(direction),
               Keyword.get(options, :far, 10_000.0),
               Keyword.get(options, :limit, 8)
             )
           ) do
      {:ok, Jason.decode!(json)}
    end
  end

  @doc """
  The faces nearest a point, closest first.

  A ray answers "straight on"; this answers "nearby", which is what naming the
  feature at a coordinate wants when the coordinate came from a sensor rather
  than from the model.
  """
  @spec nearest(Part.t(), [number()], keyword()) :: {:ok, map()} | {:error, Error.t()}
  def nearest(%Part{ref: ref}, point, options \\ []) do
    with :ok <- engine(),
         {:ok, json} <-
           answer(Native.brep_nearest(ref, numbers(point), Keyword.get(options, :limit, 4))) do
      {:ok, Jason.decode!(json)}
    end
  end

  @doc """
  One camera frame: what each pixel of the camera landed on.

  Rays are cast against the exact B-rep, so the answer is where the surface *is*,
  not a depth buffer's approximation of it.
  """
  @spec frame(Part.t(), Camera.t()) :: {:ok, Frame.t()} | {:error, Error.t()}
  def frame(%Part{ref: ref}, %Camera{} = camera) do
    with :ok <- engine(),
         {:ok, {points, normals, faces, depth}} <-
           answer(Native.brep_frame(ref, Jason.encode!(Camera.to_params(camera)))) do
      {:ok, Frame.new(%{points: points, normals: normals, faces: faces, depth: depth}, camera)}
    end
  end

  @doc """
  The part as triangles, with the face each triangle came from.

  Options: `:deflection` (mm, default 0.05) and `:angular` (radians, default 0.3).
  """
  @spec mesh(Part.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def mesh(%Part{ref: ref}, options \\ []) do
    with :ok <- engine(),
         {:ok, {points, indices, owners, meta}} <-
           answer(
             Native.brep_mesh(
               ref,
               Keyword.get(options, :deflection, 0.05),
               Keyword.get(options, :angular, 0.3)
             )
           ) do
      {:ok,
       %{
         points: triplets(points),
         triangles: triplets_of_ints(indices),
         face_of_triangle: ints(owners),
         meta: Jason.decode!(meta)
       }}
    end
  end

  @doc """
  Points spread over the surface, roughly *spacing* millimetres apart.

  Each carries its outward normal and the face it is on, which is everything a
  graph node needs before it is given a percept. Options: `:spacing` (mm, default
  2.0) and `:limit` (default 200 000 points).
  """
  @spec samples(Part.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def samples(%Part{ref: ref}, options \\ []) do
    with :ok <- engine(),
         {:ok, {points, normals, faces, meta}} <-
           answer(
             Native.brep_samples(
               ref,
               Keyword.get(options, :spacing, 2.0),
               Keyword.get(options, :limit, 200_000)
             )
           ) do
      {:ok,
       %{
         points: triplets(points),
         normals: triplets(normals),
         faces: ints(faces),
         meta: Jason.decode!(meta)
       }}
    end
  end

  @doc """
  What this build of quiddity can do, as the versioned document it publishes.

  Capabilities are the engine's own statement, not this library's: it says which
  recognition schema is current, which fingerprint version is in use, and whether
  the optional PMI interchange is compiled in.
  """
  @spec capabilities() :: {:ok, map()} | {:error, Error.t()}
  def capabilities do
    with :ok <- engine() do
      {:ok, Native.brep_capabilities() |> Jason.decode!()}
    end
  end

  @doc """
  The evidence each feature rests on, and every family that was refused.

  `framed` asks for part coordinates, which need an inferred frame; when the
  frame cannot be inferred the document says it was written in the file's own
  coordinates instead. A refused evidence view stays an explicit error in the
  document rather than an empty one — an empty view looks like a part with
  nothing in it.
  """
  @spec evidence(Part.t(), boolean()) :: {:ok, map()} | {:error, Error.t()}
  def evidence(%Part{ref: ref}, framed \\ true) do
    with :ok <- engine(), {:ok, json} <- answer(Native.brep_evidence(ref, framed)) do
      {:ok, Jason.decode!(json)}
    end
  end

  @doc """
  Each feature's fingerprint: the revision-independent identity two revisions are
  matched through, which is why a part that was moved or re-modelled still
  corresponds.
  """
  @spec fingerprints(Part.t()) :: {:ok, map()} | {:error, Error.t()}
  def fingerprints(%Part{ref: ref}) do
    with :ok <- engine(), {:ok, json} <- answer(Native.brep_fingerprints(ref)) do
      {:ok, Jason.decode!(json)}
    end
  end

  @doc """
  What happened to each feature between two revisions.

  Each side is a path to a STEP file or to a recognition JSON file. The answer
  lists what was `carried`, `adapted` (with what changed), `orphaned` or
  `ambiguous` — more than one candidate, so none is guessed — and which features
  are new.
  """
  @spec correspond(Path.t(), Path.t()) :: {:ok, map()} | {:error, Error.t()}
  def correspond(old, new) when is_binary(old) and is_binary(new) do
    with :ok <- engine(),
         {:ok, json} <- answer(Native.brep_correspond(Path.expand(old), Path.expand(new))) do
      {:ok, Jason.decode!(json)}
    end
  end

  @doc """
  Volume, area, centroid and — when a density is given — mass of every solid.

  `density` is grams per cubic millimetre (steel is 0.00785). `nil` answers no
  mass: a B-rep does not say what the part is made of, and guessing a material
  would make a number that looks measured.
  """
  @spec mass(Part.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def mass(%Part{ref: ref}, options \\ []) do
    density = Keyword.get(options, :density)

    with :ok <- engine(),
         {:ok, json} <- answer(Native.brep_mass(ref, density && density * 1.0)) do
      {:ok, Jason.decode!(json)}
    end
  end

  @doc """
  Whether a point in space is inside the material, outside it, on a face, or
  something the classifier will not decide (`"unknown"` — every ray ambiguous,
  or a surface it cannot intersect).
  """
  @spec classify(Part.t(), [number()]) :: {:ok, map()} | {:error, Error.t()}
  def classify(%Part{ref: ref}, point) do
    with :ok <- engine(), {:ok, json} <- answer(Native.brep_classify(ref, numbers(point))) do
      {:ok, Jason.decode!(json)}
    end
  end

  @doc """
  The distinct parts of an assembly: indices, names, face and edge counts, and
  where each instance sits.

  A file that holds one part answers one entry, which is the useful answer: a
  caller that does not know whether it was handed a part or an assembly can ask.
  """
  @spec parts(Part.t()) :: {:ok, map()} | {:error, Error.t()}
  def parts(%Part{ref: ref}) do
    with :ok <- engine(), {:ok, json} <- answer(Native.brep_parts(ref)) do
      {:ok, Jason.decode!(json)}
    end
  end

  @doc """
  The file's semantic PMI — dimensions, geometric tolerances, datums and notes —
  as quiddity's versioned JSON, for one part (`part: 0`) or all of them.

  This is what the part *demands*, not what it looks like: the tolerance on a
  bore, the datum a face is measured from. A file without PMI answers a document
  with none, which is a different answer from a file that could not be read.
  """
  @spec pmi(Part.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def pmi(%Part{ref: ref}, options \\ []) do
    with :ok <- engine(),
         {:ok, json} <- answer(Native.brep_pmi(ref, Keyword.get(options, :part))) do
      {:ok, Jason.decode!(json)}
    end
  end

  defp engine do
    if Native.loaded?() do
      :ok
    else
      {:error,
       %Error{
         code: "no_engine",
         message:
           "the Rust engine is not loaded in this VM: build it with `mix deps.compile ex_quiddity` (it needs cargo)"
       }}
    end
  end

  defp answer(:ok), do: {:error, %Error{code: "internal", message: "the engine answered nothing"}}
  defp answer({:ok, value}), do: {:ok, value}
  defp answer({:error, {code, message}}), do: {:error, Error.new({code, message})}

  defp numbers(values) when is_list(values), do: Enum.map(values, &(&1 * 1.0))

  defp triplets(binary) do
    for <<x::float-64-little, y::float-64-little, z::float-64-little <- binary>>, do: [x, y, z]
  end

  defp triplets_of_ints(binary) do
    for <<a::unsigned-little-32, b::unsigned-little-32, c::unsigned-little-32 <- binary>>,
      do: [a, b, c]
  end

  defp ints(binary), do: for(<<value::unsigned-little-32 <- binary>>, do: value)
end
