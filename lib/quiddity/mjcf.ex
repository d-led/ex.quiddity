defmodule Quiddity.Mjcf do
  @moduledoc """
  A part as a MuJoCo scene: the triangles quiddity meshed, as an MJCF model.

  This is the bridge to a *simulated* world rather than an exact one. A B-rep can
  be ray cast exactly — that is what `Quiddity.frame/2` does — but a sensor that
  has to make contact, slide and be pushed needs a physics engine. MuJoCo is the
  one this writes for, so the part becomes a mesh geometry in metres, which is
  what an MJCF holds.

  ## Units

  A STEP file is in millimetres and MuJoCo is in metres, so every coordinate is
  divided by 1000 on the way out. Nothing else is changed: the part keeps the
  place the file gives it, so a scene written from a part and a frame rendered
  from the same part agree about where it is, up to that factor.

  ## What it is not

  It is not a model of the *agent*. A scene holds the part; a body, its sensors
  and its actuators are the experiment's, and putting them here would be a second
  description of something the experiment already configures.

  ```elixir
  {:ok, part} = Quiddity.open("bracket.step")
  {:ok, xml} = Quiddity.Mjcf.document(part)
  File.write!("bracket.xml", xml)
  ```
  """

  alias Quiddity.Part

  @default_deflection 0.05
  @millimetres_per_metre 1000.0

  @doc """
  The scene as MJCF text.

  Options: `:deflection` (mm, default 0.05), `:angular` (radians, default 0.3),
  `:name` (the model's name, default `"part"`) and `:rgba` (the material's colour,
  default a neutral grey).
  """
  @spec document(Part.t(), keyword()) :: {:ok, String.t()} | {:error, Quiddity.Error.t()}
  def document(%Part{} = part, options \\ []) do
    with {:ok, mesh} <-
           Quiddity.mesh(part,
             deflection: Keyword.get(options, :deflection, @default_deflection),
             angular: Keyword.get(options, :angular, 0.3)
           ),
         :ok <- meshed(mesh) do
      name = Keyword.get(options, :name, "part")
      rgba = Keyword.get(options, :rgba, [0.72, 0.72, 0.75, 1.0])

      {:ok,
       """
       <!-- #{Path.basename(part.path)}: #{mesh.meta["faces"]} faces, \
       #{length(mesh.triangles)} triangles, written by ex_quiddity -->
       <mujoco model="#{escape(name)}">
         <compiler angle="radian" meshdir="."/>
         <asset>
           <mesh name="#{escape(name)}" vertex="#{vertices(mesh)}" face="#{faces(mesh)}"/>
         </asset>
         <worldbody>
           <body name="#{escape(name)}" pos="0 0 0">
             <geom name="#{escape(name)}" type="mesh" mesh="#{escape(name)}" \
       rgba="#{Enum.map_join(rgba, " ", &number/1)}"/>
           </body>
         </worldbody>
       </mujoco>
       """}
    end
  end

  @doc "Writes the scene as MJCF text."
  @spec write(Part.t(), Path.t(), keyword()) :: :ok | {:error, Quiddity.Error.t()}
  def write(%Part{} = part, path, options \\ []) do
    with {:ok, xml} <- document(part, options) do
      case File.write(path, xml) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error,
           %Quiddity.Error{code: "unwritable", message: "#{path}: #{:file.format_error(reason)}"}}
      end
    end
  end

  defp meshed(%{triangles: []}) do
    {:error,
     %Quiddity.Error{
       code: "unmeshable",
       message: "the part meshed to no triangles, so a scene of it would be empty"
     }}
  end

  defp meshed(_mesh), do: :ok

  # One vertex per point, in metres, on one line — MJCF reads a whitespace-
  # separated list and a file per vertex would be a thousand times longer.
  defp vertices(%{points: points}) do
    points
    |> Enum.map_join(" ", fn point ->
      point |> Enum.map_join(" ", &number(&1 / @millimetres_per_metre))
    end)
  end

  defp faces(%{triangles: triangles}) do
    Enum.map_join(triangles, " ", fn [a, b, c] -> "#{a} #{b} #{c}" end)
  end

  defp number(value) when is_integer(value), do: Integer.to_string(value)

  defp number(value) do
    :erlang.float_to_binary(value * 1.0, [:short])
  end

  # A name is written into an attribute: a `"` or a `<` in a part's own name
  # would end it early, and a scene that half-parses is worse than one that does
  # not.
  defp escape(name) do
    name
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
