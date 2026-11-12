defmodule Quiddity.Percept do
  @moduledoc """
  A CAD frame as the observation a Monty sensor module reads.

  This is the one place the two worlds meet, and it is deliberately thin: the
  frame supplies exact points, and Monty's own
  `Monty.Frameworks.Models.SensorModules.ObservationProcessor` fits the surface,
  finds the principal curvatures and assembles the message. Nothing here
  re-implements a percept — a node trained on a CAD part has to be the percept a
  run would have made, or the graph being built is a graph of something else.

  ## The observation

  Monty's sensor modules never see a depth image: the transform chain turns one
  into `"semantic_3d"` — one row per pixel, `[x, y, z, semantic_id]` — and that
  is what they read. Here the points come from ray casting the exact B-rep, so
  `"semantic_3d"` is exact rather than an un-projection of a depth buffer, and a
  pixel that met nothing carries `0.0`, Monty's background.

  `"rgba"` is *shading*: a B-rep has no colour, so the image is lit by one light
  from the upper left of the camera. A `"hsv"` feature read from it says how the
  surface turns, not what it is painted; a file with no appearance has no colour
  to perceive, and inventing one would be worse than saying so.

  ## The features a node keeps

  `node_features/1` merges the morphological and non-morphological features, the
  same way `GraphLM.select_features_to_use/2` does. Those are the columns a graph
  memory stores per node: `hsv`, `pose_vectors`, `pose_fully_defined`,
  `principal_curvatures_log`, and whatever else the sensor was asked for.
  """

  alias Monty.Frameworks.Models.SensorModules.ObservationProcessor
  alias Quiddity.{Camera, Frame}

  @default_features [
    "pose_vectors",
    "pose_fully_defined",
    "on_object",
    "object_coverage",
    "min_depth",
    "mean_depth",
    "hsv",
    "principal_curvatures",
    "principal_curvatures_log"
  ]

  @typedoc "A Monty observation: the map the sensor modules read."
  @type observation :: %{optional(String.t()) => term()}

  @doc """
  The observation a Monty sensor module reads from this frame.

  Options: `:semantic_id` (what an on-surface pixel is called, default `1`).
  """
  @spec observation(Frame.t(), keyword()) :: observation()
  def observation(%Frame{} = frame, options \\ []) do
    semantic_id = Keyword.get(options, :semantic_id, 1)

    %{
      "semantic_3d" => Frame.semantic_3d(frame, semantic_id: semantic_id),
      "rgba" => rows(Frame.rgba(frame), frame.width),
      "depth" => rows(Frame.depths(frame), frame.width),
      "semantic" => frame |> labels() |> rows(frame.width),
      "cam_to_world" => Camera.cam_to_world(frame.camera)
    }
  end

  @doc """
  The percept: Monty's own processor over this frame.

  Answers `{:ok, %Monty.Cmp.Message{}}`, whose `location` is the centre pixel's
  point, whose `morphological_features` carry the surface normal and whether the
  pose is defined, and whose `non_morphological_features` carry the depths,
  colour and curvatures the sensor asked for.

  A frame that met nothing still makes a message — Monty's processor does that,
  with `on_object` `0.0` and `process_features_in_lm` false — because "the sensor
  is over empty space" is a fact a model is allowed to act on. A caller that
  wants only real percepts filters on `on_object`, the way `Training.nodes/2`
  does.
  """
  @spec message(Frame.t(), keyword()) :: {:ok, Monty.Cmp.Message.t()}
  def message(%Frame{} = frame, options \\ []) do
    processor =
      ObservationProcessor.new(
        features: Keyword.get(options, :features, @default_features),
        sensor_module_id: Keyword.get(options, :sensor_module_id, "patch"),
        pc1_is_pc2_threshold: Keyword.get(options, :pc1_is_pc2_threshold, 10.0),
        weight_curvature: Keyword.get(options, :weight_curvature, true),
        is_surface_sm: Keyword.get(options, :is_surface_sm, true)
      )

    ObservationProcessor.process(processor, observation(frame, options))
  end

  @doc """
  The features a graph node keeps from a message — morphological and the rest,
  merged, the way `GraphLM.select_features_to_use/2` merges them.

  Keys are strings and values are what Monty stores: a three-element list for a
  pose vector, a two-element list for curvatures, a float for a defined pose.
  """
  @spec node_features(Monty.Cmp.Message.t()) :: %{optional(String.t()) => term()}
  def node_features(%Monty.Cmp.Message{} = message) do
    message
    |> message_features()
    |> Enum.into(%{}, fn {name, value} -> {name, flatten(value)} end)
  end

  defp message_features(message) do
    Map.merge(message.morphological_features || %{}, message.non_morphological_features || %{})
  end

  # A pose vector is a struct in Monty's vocabulary; a graph stores numbers, so
  # the rows it holds are what travels.
  defp flatten(%Monty.Geometry.SurfacePoseVectors{value: rows}), do: Enum.map(rows, &flatten/1)

  defp flatten(values) when is_list(values), do: Enum.map(values, &flatten/1)
  defp flatten(value), do: value

  defp labels(frame) do
    for face <- Frame.face_ids(frame), do: if(face == nil, do: 0, else: face + 1)
  end

  defp rows(values, width) do
    values
    |> Enum.chunk_every(width)
    |> Enum.map(&Enum.map(&1, fn value -> value end))
  end
end
