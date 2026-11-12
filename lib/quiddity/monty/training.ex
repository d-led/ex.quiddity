defmodule Quiddity.Monty.Training do
  @moduledoc """
  A graph memory built from a CAD part — supervised training without an episode.

  Monty learns an object by touching it: a surface agent explores, and every
  patch it lands on becomes a node with the percept it made there. A CAD part
  already *is* the explored object — its surface is known exactly — so the
  exploration can be replaced by sampling: put a patch sensor on the surface,
  spacing the visits as far apart as the detail needs, and take the percept each
  visit makes.

  What comes out is what a training episode comes out with: locations in the
  part's own frame and the features the sensor modules measured there. The
  difference is that the *labels* are exact — quiddity says which face each node
  is on and which feature that face belongs to — which is what makes this
  supervised: a node's feature family is read, never concluded.

  ## What this is not

  It is not a replacement for a training episode's *action* policy. Monty's
  episodes also learn where to look next, and a CAD-built memory does not hold
  that. What it holds is the part, densely and evenly, which is the thing an
  episode spends its first minutes doing badly.

  ## Cost

  One patch is one frame — 4 096 rays — and a percept is Monty's own feature
  extraction on top. A plate at 2 mm spacing is a few hundred patches; a large
  part at 0.5 mm is thousands, so `:limit` caps the work and `:spacing` is the
  honest dial.
  """

  alias Quiddity.{Camera, Frame, Part, Percept, Recognition}
  alias Quiddity.Monty.Library

  @default_spacing 2.0
  @default_limit 2_000
  # A Monty patch sensor stands a centimetre or two off the surface it reads. A
  # closer stand reads a smaller patch, so fewer visits straddle a face's edge
  # and are skipped for it.
  @default_distance 5.0

  @typedoc """
  One node: where the sensor was, what it perceived, and what quiddity says it
  is looking at.
  """
  @type visit_node :: %{
          location: [float()],
          features: %{optional(String.t()) => term()},
          face: non_neg_integer(),
          family: String.t() | nil
        }

  @doc """
  Visits the part and takes a percept at each one.

  Options:

    * `:spacing` — how far apart the visits are, in millimetres (default 2.0);
    * `:limit` — the most visits to make (default 2 000);
    * `:distance` — how far the sensor stands off the surface (default 5 mm,
      which keeps a patch's footprint smaller than a face on most parts);
    * `:min_coverage` — the share of a patch that must land on the part for the
      visit to count (default 0.6);
    * `:features` — the sensor's feature list, defaulting to a Monty patch's;
    * `:progress` — a one-argument function called after each percept, for a
      caller that wants to show a count rather than wait.

  A visit whose patch does not see the surface — a corner sharper than the
  patch's field of view, or a face the rays miss — is *skipped*, not invented:
  the node count is what the sensor could perceive, and `:skipped` in the answer
  says how many visits it was.
  """
  @spec nodes(Part.t(), keyword()) :: {:ok, map()} | {:error, Quiddity.Error.t()}
  def nodes(%Part{} = part, options \\ []) do
    with {:ok, recognition} <- Quiddity.features(part),
         {:ok, samples} <-
           Quiddity.samples(part,
             spacing: Keyword.get(options, :spacing, @default_spacing),
             limit: Keyword.get(options, :limit, @default_limit)
           ) do
      visits = Enum.zip([samples.points, samples.normals, samples.faces])
      node_options = Keyword.put(options, :recognition, recognition)

      nodes = Enum.map(visits, &visit(part, &1, node_options))

      kept = for {:ok, node} <- nodes, do: node

      {:ok,
       %{
         nodes: kept,
         visited: length(visits),
         skipped: length(visits) - length(kept),
         truncated: samples.meta["truncated"] == true,
         families: kept |> Enum.map(& &1.family) |> Enum.frequencies()
       }}
    end
  end

  @doc """
  The nodes a previous visit produced, as the library a run loads.

  `object_id` is what the graph is called — the name a recognition would answer
  — so a run matching this library says `"bracket"`, not `"new_object0"`.
  """
  @spec library([visit_node()], String.t(), keyword()) ::
          {:ok, Library.t()} | {:error, Quiddity.Error.t()}
  def library(nodes, object_id, options \\ []) do
    Library.new(
      object_id,
      Enum.map(nodes, & &1.location),
      Enum.map(nodes, & &1.features),
      options
    )
  end

  @doc """
  Samples the part and writes the library a run loads, in one call.

  Answers what was written and what it holds: the path, the node count, the
  feature names, and how many nodes each feature family contributed.
  """
  @spec write(Part.t(), String.t(), Path.t(), keyword()) ::
          {:ok, map()} | {:error, Quiddity.Error.t()}
  def write(%Part{} = part, object_id, path, options \\ []) do
    with {:ok, %{nodes: nodes} = visits} <- nodes(part, options),
         {:ok, library} <- library(nodes, object_id, options),
         :ok <- Library.write(library, path) do
      {:ok,
       %{
         path: path,
         object_id: object_id,
         nodes: Library.size(library),
         visited: visits.visited,
         skipped: visits.skipped,
         truncated: visits.truncated,
         families: visits.families,
         features: Library.feature_names(library),
         source_sha256: part.summary["sha256"]
       }}
    end
  end

  defp visit(part, {point, normal, face}, options) do
    recognition = Keyword.fetch!(options, :recognition)

    with {:ok, camera} <-
           Camera.patch(point, normal,
             distance: Keyword.get(options, :distance, @default_distance)
           ),
         {:ok, frame} <- Quiddity.frame(part, camera),
         :ok <- sees_surface(frame, options),
         {:ok, message} <- Percept.message(frame, options) do
      {:ok,
       %{
         location: Enum.map(message.location, &(&1 * 1.0)),
         features: Percept.node_features(message),
         face: face,
         family: Recognition.family_of(recognition, face),
         coverage: Frame.coverage(frame)
       }}
    else
      {:error, %Quiddity.Error{}} -> :skipped
      :off_surface -> :skipped
    end
  end

  # A visit on a face's edge sees mostly off the part: the centre pixel misses,
  # the surface fit has too little to fit, and the features describe nothing. A
  # surface agent never *is* on an edge — contact keeps it inside the face — so
  # the honest thing is to skip the visit rather than store a node whose pose is
  # undefined and whose location is the far plane.
  defp sees_surface(frame, options) do
    {_point, _normal, face} = Frame.centre(frame)
    enough = Keyword.get(options, :min_coverage, 0.6)

    if face != nil and Frame.coverage(frame) >= enough, do: :ok, else: :off_surface
  end
end
