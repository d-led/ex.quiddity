defmodule Quiddity.Monty.Library do
  @moduledoc """
  A graph memory in the form a Monty run loads.

  Monty's pretrained memory is one file of JSON lines, gzipped, one record per
  object and input channel:

      {"object_id": "bracket", "input_channel": "patch",
       "positions": [[x, y, z], …], "features": {"hsv": [[h, s, v], …], …}}

  That is the whole format — `Monty.Studio.Memory` in the studio reads it back
  into a `GraphMemory` and matches with it. So a part learned from CAD writes the
  same file a training episode writes, and a run does not know the difference.

  Records are written with `lm_index` `0`: a library built from one part is one
  learning module's memory, and a heterarchy's is several libraries.
  """

  defstruct [:object_id, :channel, positions: [], features: %{}]

  @type t :: %__MODULE__{
          object_id: String.t(),
          channel: String.t(),
          positions: [[float()]],
          features: %{optional(String.t()) => [term()]}
        }

  @doc """
  A library from nodes: their locations and their features, one column a feature.

  `features` is what `Quiddity.Percept.node_features/1` answered per node, so
  this is a transpose with the shape of the file to write: every feature becomes
  a column of the same length as `positions`.
  """
  @spec new(String.t(), [[float()]], [%{optional(String.t()) => term()}], keyword()) ::
          {:ok, t()} | {:error, Quiddity.Error.t()}
  def new(object_id, positions, features, options \\ []) when is_binary(object_id) do
    with :ok <- uniform(positions, 3, "a location is three numbers"),
         :ok <- same_length(positions, features),
         :ok <- any_feature(features) do
      names = features |> Enum.flat_map(&Map.keys/1) |> Enum.uniq() |> Enum.sort()

      {:ok,
       %__MODULE__{
         object_id: object_id,
         channel: Keyword.get(options, :channel, "patch"),
         positions: positions,
         features: Map.new(names, fn name -> {name, Enum.map(features, &Map.get(&1, name))} end)
       }}
    end
  end

  @doc "How many nodes the library holds."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{positions: positions}), do: length(positions)

  @doc "The feature names the library holds."
  @spec feature_names(t()) :: [String.t()]
  def feature_names(%__MODULE__{features: features}), do: features |> Map.keys() |> Enum.sort()

  @doc """
  The library as the records the file holds — one, for one object and channel.
  """
  @spec records(t(), keyword()) :: [map()]
  def records(%__MODULE__{} = library, options \\ []) do
    [
      %{
        "object_id" => library.object_id,
        "input_channel" => library.channel,
        "positions" => library.positions,
        "features" => library.features,
        "lm_index" => Keyword.get(options, :lm_index, 0)
      }
    ]
  end

  @doc """
  Writes the library, gzipped, at `path` — the shape `Monty.Studio.Memory` reads.

  A file the format's reader can rebuild is the whole contract, so a write that
  fails is an error rather than a partial file that looks like a memory.
  """
  @spec write(t(), Path.t(), keyword()) :: :ok | {:error, Quiddity.Error.t()}
  def write(%__MODULE__{} = library, path, options \\ []) do
    body = library |> records(options) |> Enum.map_join("\n", &Jason.encode!/1)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      case File.write(path, :zlib.gzip(body <> "\n")) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error,
           %Quiddity.Error{code: "unwritable", message: "#{path}: #{:file.format_error(reason)}"}}
      end
    end
  end

  defp uniform(rows, width, message) do
    if Enum.all?(rows, &(is_list(&1) and length(&1) == width)) do
      :ok
    else
      {:error, %Quiddity.Error{code: "bad_request", message: message}}
    end
  end

  defp same_length(positions, features) do
    if length(positions) == length(features) do
      :ok
    else
      {:error,
       %Quiddity.Error{
         code: "bad_request",
         message: "#{length(positions)} locations but #{length(features)} nodes' features"
       }}
    end
  end

  defp any_feature(features) do
    if Enum.any?(features, &(map_size(&1) > 0)) do
      :ok
    else
      {:error,
       %Quiddity.Error{
         code: "bad_request",
         message: "a node with no features cannot be matched, so nothing is written"
       }}
    end
  end
end
