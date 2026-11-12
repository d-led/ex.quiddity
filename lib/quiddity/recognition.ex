defmodule Quiddity.Recognition do
  @moduledoc """
  What quiddity recognised in a part: its features, and what every face is.

  This is quiddity's own `recognition/6` document, read rather than reshaped,
  with three questions answered once at the door because everything downstream
  asks them:

    * `by_family/1` — the records grouped under the family that found them;
    * `owner/2` — which feature a given face belongs to, which is what turns a
      point a sensor landed on into a named feature;
    * every face accounted for — a face is part of a feature, part of the body
      (with the reason), refused, or unexplained. A file that reads without
      errors is not a promise every feature was found, and the unexplained faces
      are where that promise is kept honest.
  """

  defstruct [
    :schema_version,
    :package,
    :coordinate_space,
    :frame,
    :face_count,
    :source_sha256,
    :run_mode,
    records: [],
    by_family: %{},
    face_owner: %{},
    failures: [],
    input_repairs: []
  ]

  @type face_owner :: String.t() | :body | :refused | :unexplained | :unaccounted

  @type t :: %__MODULE__{
          schema_version: String.t(),
          package: map(),
          coordinate_space: String.t(),
          frame: map(),
          face_count: non_neg_integer(),
          source_sha256: String.t() | nil,
          run_mode: String.t(),
          records: [map()],
          by_family: %{optional(String.t()) => [map()]},
          face_owner: %{optional(non_neg_integer()) => face_owner()},
          failures: [map()],
          input_repairs: [String.t()]
        }

  @doc "Reads a recognition document, as the engine wrote it."
  @spec parse(map()) :: t()
  def parse(document) when is_map(document) do
    records = Map.get(document, "records") || []

    %__MODULE__{
      schema_version: document["schema_version"],
      package: document["package"],
      coordinate_space: document["coordinate_space"],
      frame: document["frame"],
      face_count: document["face_count"] || 0,
      source_sha256: document["source_sha256"],
      run_mode: document["run_mode"],
      records: records,
      by_family: Enum.group_by(records, & &1["family"]),
      face_owner: owners(document["face_accounting"], document["face_count"] || 0),
      failures: Map.get(document, "failures") || [],
      input_repairs: Map.get(document, "input_repairs") || []
    }
  end

  # quiddity serialises a face's account as a tagged object: `{"group" =>
  # "feature", "record_ids" => [...]}`, `"body"`, `"refused"` or
  # `"unexplained"`. The list is indexed by face, so its order is the answer.
  defp owners(nil, _count), do: %{}

  defp owners(accounts, _count) do
    accounts
    |> Enum.with_index()
    |> Map.new(fn {account, face} -> {face, owner(account)} end)
  end

  defp owner(%{"group" => "feature", "record_ids" => [id | _]}), do: id
  defp owner(%{"group" => "feature"}), do: :unexplained
  defp owner(%{"group" => "body"}), do: :body
  defp owner(%{"group" => "refused"}), do: :refused
  defp owner(%{"group" => "unexplained"}), do: :unexplained
  defp owner(_other), do: :unaccounted

  @doc "Every record, in the order the families are documented."
  @spec records(t()) :: [map()]
  def records(%__MODULE__{records: records}), do: records

  @doc "The records a family found, and `[]` for a family that found none."
  @spec by_family(t(), String.t()) :: [map()]
  def by_family(%__MODULE__{by_family: grouped}, family), do: Map.get(grouped, family, [])

  @doc "The families with records, and how many each found, biggest first."
  @spec families(t()) :: [{String.t(), non_neg_integer()}]
  def families(%__MODULE__{by_family: grouped}) do
    grouped
    |> Enum.map(fn {family, records} -> {family, length(records)} end)
    |> Enum.sort_by(fn {family, count} -> {-count, family} end)
  end

  @doc "A record by its id (`\"holes/0\"`), or `nil`."
  @spec record(t(), String.t()) :: map() | nil
  def record(%__MODULE__{records: records}, id), do: Enum.find(records, &(&1["id"] == id))

  @doc """
  What a face is: the id of the feature it belongs to, `:body`, `:refused`, or
  `:unexplained`.
  """
  @spec owner(t(), non_neg_integer()) :: face_owner()
  def owner(%__MODULE__{face_owner: owners}, face), do: Map.get(owners, face, :unaccounted)

  @doc """
  The family a face's feature belongs to, or `nil` when no feature owns it.

  This is the question a sensel asks: "what am I on?"
  """
  @spec family_of(t(), non_neg_integer()) :: String.t() | nil
  def family_of(%__MODULE__{} = recognition, face) do
    with id when is_binary(id) <- owner(recognition, face),
         %{"family" => family} <- record(recognition, id) do
      family
    else
      _not_a_feature -> nil
    end
  end

  @doc "The faces no feature claims and nothing else explains."
  @spec unexplained_faces(t()) :: [non_neg_integer()]
  def unexplained_faces(%__MODULE__{face_owner: owners} = recognition) do
    for face <- 0..(recognition.face_count - 1)//1,
        Map.get(owners, face) == :unexplained,
        do: face
  end

  @doc "The records whose evidence quiddity could not prove."
  @spec unproved(t()) :: [map()]
  def unproved(%__MODULE__{records: records}) do
    Enum.filter(records, &(&1["evidence_status"] != "verified"))
  end
end
