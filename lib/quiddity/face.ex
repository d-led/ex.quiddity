defmodule Quiddity.Face do
  @moduledoc """
  One face of a part: what kind of surface it is, how big it is, which way it
  faces, and what it touches.

  "Face" here is the B-rep face — one trimmed piece of one surface — which is the
  unit quiddity's records are made of. A feature is a *set* of them
  (`Quiddity.Recognition.owner/2` goes the other way), so a caller reading a
  face's `surface` is reading what it is made of, not what it is for.
  """

  defstruct [:index, :surface, :area, :centroid, :normal, :bounds, :reversed, :neighbours, :edges]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          surface: map(),
          area: float() | nil,
          centroid: [float()] | nil,
          normal: [float()] | nil,
          bounds: map(),
          reversed: boolean(),
          neighbours: [non_neg_integer()],
          edges: [non_neg_integer()]
        }

  @doc "A face, as the engine answered it."
  @spec parse(map()) :: t()
  def parse(face) when is_map(face) do
    %__MODULE__{
      index: face["face"],
      surface: face["surface"] || %{"kind" => "unknown"},
      area: face["area"],
      centroid: face["centroid"],
      normal: face["normal"],
      bounds: face["bounds"],
      reversed: face["reversed"],
      neighbours: face["neighbours"] || [],
      edges: face["edges"] || []
    }
  end

  @doc ~s(What kind of surface the face is: `"plane"`, `"cylinder"`, …)
  @spec kind(t()) :: String.t()
  def kind(%__MODULE__{surface: %{"kind" => kind}}), do: kind

  @doc """
  The radius of a cylindrical or spherical face, in millimetres, or `nil`.

  A hole's wall is a cylinder, so this is the hole's radius — but a cylinder can
  also be a boss or a pin, which is why the *family* comes from the recognition
  and not from here.
  """
  @spec radius(t()) :: float() | nil
  def radius(%__MODULE__{surface: %{"radius" => radius}}), do: radius
  def radius(%__MODULE__{}), do: nil

  @doc "The diameter of a round face, in millimetres, or `nil`."
  @spec diameter(t()) :: float() | nil
  def diameter(%__MODULE__{} = face) do
    case radius(face) do
      nil -> nil
      radius -> 2.0 * radius
    end
  end

  @doc """
  One line about the face, in the words a person would use.

  A `.step` file is a list of surface entities; a reader wants "cylindrical wall,
  4 mm radius, 125.7 mm², facing +x". This is that sentence, and it is what the
  MCP tools print, so a model reads the same words a person would.
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = face) do
    parts = [kind(face), radius_phrase(face), "area #{number(face.area)} mm²"]
    Enum.join(Enum.reject(parts, &is_nil/1), " · ")
  end

  defp radius_phrase(%__MODULE__{} = face) do
    case radius(face) do
      nil -> nil
      radius -> "radius #{number(radius)} mm"
    end
  end

  defp number(nil), do: nil
  defp number(value), do: :erlang.float_to_binary(value * 1.0, decimals: 3)
end
