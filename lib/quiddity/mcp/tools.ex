defmodule Quiddity.Mcp.Tools do
  @moduledoc """
  The tools the MCP server offers, and the one place a name becomes a function.

  A tool answers `{:ok, %{text: text, structured: map}, state}` or
  `{:error, message, state}`. The text is what a model reads; the structured
  part is the same answer for a program that would rather not parse prose. The
  protocol layer turns the second form into `isError`, which is how the
  specification says "this call failed, the message says how" rather than "the
  server is broken".

  Every tool is read-only except one that writes a file the caller named:
  `quiddity_export_mjcf`, a scene in metres.

  ## Where the parts come from

  A call names a path. The server keeps the parsed part from the first call, so
  asking three questions about one file reads it once — and a tool never takes a
  *handle* from a caller, because a handle is not something a model should have
  to hold.
  """

  alias Quiddity.{Camera, Face, Frame, Mjcf, Part, Recognition}

  @read_only %{
    "readOnlyHint" => true,
    "destructiveHint" => false,
    "idempotentHint" => true,
    "openWorldHint" => false
  }

  @writes %{
    "readOnlyHint" => false,
    "destructiveHint" => false,
    "idempotentHint" => true,
    "openWorldHint" => false
  }

  @path %{
    "type" => "string",
    "description" => "Path to a STEP file (.step, .stp, either gzipped)."
  }

  @point %{
    "type" => "array",
    "items" => %{"type" => "number"},
    "minItems" => 3,
    "maxItems" => 3,
    "description" => "A point in millimetres, in the file's own coordinates."
  }

  @tools [
    %{
      "name" => "quiddity_part",
      "title" => "What a STEP part is",
      "description" =>
        "Opens a STEP file and says what it holds: bodies, faces, edges, the bounding box " <>
          "in millimetres, whether each solid is valid, and the file's digest. Ask this " <>
          "first — every other tool takes the same path.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"path" => @path},
        "required" => ["path"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "quiddity_features",
      "title" => "The part's manufacturing features",
      "description" =>
        "Recognises the part's features from the B-rep alone: holes (through, blind, " <>
          "counterbored, countersunk), pockets, slots, steps, bosses, patterns, fillets, " <>
          "chamfers, grooves, channels, sheet-metal and turned features — each with its " <>
          "measured size, position and the faces it is made of, and whether the evidence " <>
          "was proved. Also says what every face is: part of a feature, part of the body, " <>
          "refused, or unexplained. Optional `family` narrows to one family.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "path" => @path,
          "family" => %{
            "type" => "string",
            "description" => "Only this family, e.g. `holes` or `pockets`."
          }
        },
        "required" => ["path"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "quiddity_face",
      "title" => "One face of the part",
      "description" =>
        "What one face is: its surface (plane, cylinder with a radius, cone, sphere, " <>
          "torus, freeform), area, centroid, outward normal, neighbours, and which " <>
          "feature owns it. Faces are numbered 0 to face count − 1.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "path" => @path,
          "face" => %{"type" => "integer", "minimum" => 0, "description" => "A face index."}
        },
        "required" => ["path", "face"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "quiddity_probe",
      "title" => "What is at a point, or under a ray",
      "description" =>
        "With `direction`: where a ray from `point` meets the part, nearest first — each " <>
          "hit naming the face, the point, outward normal and distance in millimetres. " <>
          "Without it: the faces nearest the point, which is how a coordinate becomes a " <>
          "face and then a feature.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "path" => @path,
          "point" => @point,
          "direction" => %{
            "type" => "array",
            "items" => %{"type" => "number"},
            "minItems" => 3,
            "maxItems" => 3,
            "description" => "A ray direction. Omit to ask which faces are nearest."
          }
        },
        "required" => ["path", "point"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "quiddity_sense",
      "title" => "What a sensor sees at a pose",
      "description" =>
        "Puts a 64 × 64 sensor `distance` mm off the part, looking along `normal` (by " <>
          "default the outward normal of the face nearest `point`), and renders the frame " <>
          "against the exact B-rep. Answers coverage, the depth range, how many pixels " <>
          "met the part, and how much of the view each feature family covers.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "path" => @path,
          "point" => @point,
          "normal" => %{
            "type" => "array",
            "items" => %{"type" => "number"},
            "minItems" => 3,
            "maxItems" => 3,
            "description" => "The surface normal to look along. Defaults to the nearest face's."
          },
          "distance" => %{
            "type" => "number",
            "description" => "How far off the surface to stand, in millimetres (default 5)."
          },
          "resolution" => %{
            "type" => "integer",
            "minimum" => 4,
            "maximum" => 256,
            "description" => "Pixels a side (default 64)."
          }
        },
        "required" => ["path", "point"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "quiddity_export_mjcf",
      "title" => "The part as a MuJoCo scene",
      "description" =>
        "Meshes the part and writes an MJCF model of it, in metres, for a physics " <>
          "simulator. The part keeps the place the file gives it; a body, its sensors and " <>
          "its actuators stay the experiment's. Writes the file you name.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "path" => @path,
          "out" => %{"type" => "string", "description" => "Where to write the MJCF."},
          "deflection" => %{
            "type" => "number",
            "description" => "Mesh chord tolerance in millimetres (default 0.05)."
          }
        },
        "required" => ["path", "out"]
      },
      "annotations" => @writes
    },
    %{
      "name" => "quiddity_correspond",
      "title" => "What changed between two revisions",
      "description" =>
        "Compares two revisions of a part — each a STEP file or a recognition JSON file — " <>
          "and says what happened to each feature: carried unchanged, adapted (with what " <>
          "changed), orphaned, ambiguous, or new. It works when the part was moved or " <>
          "re-modelled, because it matches revision-independent fingerprints.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "old" => %{"type" => "string", "description" => "The earlier revision."},
          "new" => %{"type" => "string", "description" => "The later revision."}
        },
        "required" => ["old", "new"]
      },
      "annotations" => @read_only
    }
  ]

  @doc "The tool catalogue, as `tools/list` answers it."
  @spec catalogue() :: [map()]
  def catalogue, do: @tools

  @doc "The names of the tools, for a test to hold the catalogue to."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@tools, & &1["name"])

  @doc """
  Calls a tool by name.

  An unknown name, or a missing required argument, is an error a model can read
  and retry — not a crash.
  """
  @spec call(String.t(), map(), Quiddity.Mcp.state()) ::
          {:ok, %{text: String.t(), structured: map()}, Quiddity.Mcp.state()}
          | {:error, String.t(), Quiddity.Mcp.state()}
  def call(name, arguments, state) when is_binary(name) and is_map(arguments) do
    if name in names() do
      action(name, arguments, state)
    else
      {:error, "`#{name}` is not one of the tools: " <> Enum.join(names(), ", "), state}
    end
  end

  def call(name, _arguments, state) do
    {:error, "`#{inspect(name)}` is not one of the tools: " <> Enum.join(names(), ", "), state}
  end

  defp action("quiddity_part", %{"path" => path}, state) do
    with_part(state, path, fn part, state -> {:ok, part_answer(part), state} end)
  end

  defp action("quiddity_features", %{"path" => path} = arguments, state) do
    with_part(state, path, fn part, state ->
      case Quiddity.features(part) do
        {:ok, recognition} ->
          {:ok, features_answer(part, recognition, Map.get(arguments, "family")), state}

        {:error, error} ->
          {:error, Quiddity.Mcp.describe_error(error), state}
      end
    end)
  end

  defp action("quiddity_face", %{"path" => path, "face" => index}, state)
       when is_integer(index) and index >= 0 do
    with_part(state, path, fn part, state ->
      with {:ok, face} <- Quiddity.face(part, index),
           {:ok, recognition} <- Quiddity.features(part) do
        {:ok, face_answer(face, recognition), state}
      else
        {:error, error} -> {:error, Quiddity.Mcp.describe_error(error), state}
      end
    end)
  end

  defp action("quiddity_probe", %{"path" => path, "point" => point} = arguments, state) do
    with_part(state, path, fn part, state ->
      case Map.get(arguments, "direction") do
        nil -> probe_nearest(part, point, state)
        direction -> probe_ray(part, point, direction, state)
      end
    end)
  end

  defp action("quiddity_sense", %{"path" => path, "point" => point} = arguments, state) do
    with_part(state, path, fn part, state ->
      with {:ok, camera} <- sensor_camera(part, point, arguments),
           {:ok, frame} <- Quiddity.frame(part, camera),
           {:ok, recognition} <- Quiddity.features(part) do
        {:ok, sense_answer(frame, recognition), state}
      else
        {:error, error} -> {:error, Quiddity.Mcp.describe_error(error), state}
      end
    end)
  end

  defp action("quiddity_export_mjcf", %{"path" => path, "out" => out} = arguments, state) do
    with_part(state, path, fn part, state ->
      options =
        case Map.get(arguments, "deflection") do
          nil -> []
          deflection -> [deflection: deflection]
        end

      case Mjcf.write(part, out, options) do
        :ok -> {:ok, mjcf_answer(part, out), state}
        {:error, error} -> {:error, Quiddity.Mcp.describe_error(error), state}
      end
    end)
  end

  defp action("quiddity_correspond", %{"old" => old, "new" => new}, state) do
    case Quiddity.correspond(old, new) do
      {:ok, correspondence} -> {:ok, correspond_answer(old, new, correspondence), state}
      {:error, error} -> {:error, Quiddity.Mcp.describe_error(error), state}
    end
  end

  defp action(name, arguments, state) do
    {:error,
     "#{name} needs #{required(name) |> Enum.join(", ")}, and got #{inspect(Map.keys(arguments))}",
     state}
  end

  defp required("quiddity_part"), do: ["path"]
  defp required("quiddity_features"), do: ["path"]
  defp required("quiddity_face"), do: ["path", "face"]
  defp required("quiddity_probe"), do: ["path", "point"]
  defp required("quiddity_sense"), do: ["path", "point"]
  defp required("quiddity_export_mjcf"), do: ["path", "out"]
  defp required("quiddity_correspond"), do: ["old", "new"]
  defp required(_unknown), do: []

  # -- answers ---------------------------------------------------------------

  defp part_answer(part) do
    {min, max} = Part.bounds(part)
    extent = Part.extent(part)

    text = """
    #{Path.basename(part.path)} — #{Part.face_count(part)} faces, #{part.summary["edges"]} edges, #{part.summary["solids"]} solid(s)#{if Part.shell?(part), do: " (a shell: no solid authority)"}.
    Bounding box: #{box(min, max)} mm; extent #{Enum.map_join(extent, " × ", &number/1)} mm.
    Digest: #{part.summary["sha256"]}
    #{if part.summary["unresolved_faces"] == [], do: "Every face resolved.", else: "Unresolved faces: #{inspect(part.summary["unresolved_faces"])} — a ray may pass through them."}
    """

    %{text: text, structured: part.summary}
  end

  defp features_answer(part, recognition, family) do
    records =
      case family do
        nil -> Recognition.records(recognition)
        name -> Recognition.by_family(recognition, name)
      end

    families =
      recognition
      |> Recognition.families()
      |> Enum.map_join(", ", fn {name, count} -> "#{name} (#{count})" end)

    unexplained = Recognition.unexplained_faces(recognition)
    unproved = recognition |> Recognition.unproved() |> Enum.map(& &1["id"])

    text = """
    #{Path.basename(part.path)} — #{length(Recognition.records(recognition))} features: #{families}.

    #{records |> Enum.map_join("\n", &record_line/1)}

    Faces: #{Part.face_count(part)}, of which #{unexplained |> length()} unexplained#{if unexplained == [], do: "", else: " (#{inspect(unexplained)})"} and #{unproved |> length()} record(s) unproved#{if unproved == [], do: "", else: " (#{Enum.join(unproved, ", ")})"}.
    """

    %{
      text: text,
      structured: %{
        "path" => part.path,
        "families" => Map.new(Recognition.families(recognition)),
        "records" => records,
        "unexplained_faces" => unexplained,
        "unproved" => unproved
      }
    }
  end

  defp record_line(record) do
    "* #{record["id"]} (#{record["evidence_status"]}) — #{summarise(record["parameters"])} on faces #{inspect(record["faces"])}"
  end

  defp face_answer(face, recognition) do
    owner = Recognition.owner(recognition, face.index)
    family = Recognition.family_of(recognition, face.index)

    text = """
    Face #{face.index}: #{Face.describe(face)}.
    #{if face.normal, do: "Facing #{vector(face.normal)}; ", else: ""}centroid #{if face.centroid, do: vector(face.centroid), else: "unknown"}.
    #{if is_binary(owner), do: "Part of #{owner}#{if family, do: " — a #{family} feature", else: ""}.", else: "Belongs to no feature (#{owner})."}
    Touches faces #{inspect(face.neighbours)}.
    """

    %{
      text: text,
      structured: %{
        "face" => face.index,
        "surface" => face.surface,
        "area" => face.area,
        "centroid" => face.centroid,
        "normal" => face.normal,
        "neighbours" => face.neighbours,
        "owner" => if(is_atom(owner), do: Atom.to_string(owner), else: owner),
        "family" => family
      }
    }
  end

  defp probe_ray(part, point, direction, state) do
    case Quiddity.ray(part, point, direction) do
      {:ok, %{"hits" => []} = answer} ->
        {:ok,
         %{
           text:
             "A ray from #{vector(point)} along #{vector(direction)} met nothing within #{number(answer["searched"])} mm.",
           structured: answer
         }, state}

      {:ok, %{"hits" => hits} = answer} ->
        text = """
        A ray from #{vector(point)} along #{vector(direction)} meets the part #{length(hits)} time(s):
        #{Enum.map_join(hits, "\n", &hit_line/1)}
        """

        {:ok, %{text: text, structured: answer}, state}

      {:error, error} ->
        {:error, Quiddity.Mcp.describe_error(error), state}
    end
  end

  defp hit_line(hit) do
    "  * #{number(hit["distance"])} mm in, face #{hit["face"]} at #{vector(hit["point"])}, facing #{if hit["normal"], do: vector(hit["normal"]), else: "an undefined normal"}"
  end

  defp probe_nearest(part, point, state) do
    case Quiddity.nearest(part, point) do
      {:ok, %{"nearest" => nearest} = answer} ->
        lines = Enum.map_join(nearest, "\n", &nearest_line/1)
        text = "The faces nearest #{vector(point)}:\n" <> lines

        {:ok, %{text: text, structured: answer}, state}

      {:error, error} ->
        {:error, Quiddity.Mcp.describe_error(error), state}
    end
  end

  defp nearest_line(near) do
    facing = if near["normal"], do: vector(near["normal"]), else: "unknown"
    "  * face #{near["face"]}, #{number(near["distance"])} mm away, facing #{facing}"
  end

  defp sense_answer(frame, recognition) do
    {nearest, furthest} = Frame.depth_range(frame)
    families = Frame.families(frame, recognition)

    text = """
    #{frame.width} × #{frame.height} frame: #{Frame.hits(frame)} of #{frame.width * frame.height} pixels met the part (#{percent(Frame.coverage(frame))} covered).
    Depth #{if nearest == :none, do: "—", else: "#{number(nearest)} to #{number(furthest)} mm"}.
    In view: #{if families == [], do: "nothing on the part", else: Enum.map_join(families, ", ", fn {family, count} -> "#{family} (#{count} px)" end)}.
    """

    %{
      text: text,
      structured: %{
        "width" => frame.width,
        "height" => frame.height,
        "hits" => Frame.hits(frame),
        "coverage" => Frame.coverage(frame),
        "depth" => %{"nearest" => nearest, "furthest" => furthest},
        "families" => Map.new(families)
      }
    }
  end

  defp mjcf_answer(part, out) do
    text = """
    Wrote #{out} — #{Path.basename(part.path)} as an MJCF model in metres. #{Part.face_count(part)} faces, and the part keeps the place the file gives it.
    """

    %{text: text, structured: %{"out" => out, "faces" => Part.face_count(part)}}
  end

  defp correspond_answer(old, new, correspondence) do
    features = correspondence["features"] || correspondence["records"] || []

    text = """
    #{Path.basename(old)} → #{Path.basename(new)}: #{length(features)} feature(s) compared.
    #{features |> Enum.take(40) |> Enum.map_join("\n", &correspond_line/1)}
    """

    %{text: text, structured: correspondence}
  end

  defp correspond_line(entry) do
    "  * #{entry["old"] || "—"} → #{entry["new"] || "—"}: #{entry["class"]}#{if entry["changes"], do: " (#{summarise(entry["changes"])})", else: ""}"
  end

  # -- shared ----------------------------------------------------------------

  # The part from the first call, or a read now: a caller names a path, and a
  # handle is not something a model should have to hold.
  defp with_part(state, path, fun) do
    case Map.fetch(state.parts, path) do
      {:ok, part} ->
        fun.(part, state)

      :error ->
        case Quiddity.open(path) do
          {:ok, part} -> fun.(part, %{state | parts: Map.put(state.parts, path, part)})
          {:error, error} -> {:error, Quiddity.Mcp.describe_error(error), state}
        end
    end
  end

  # A sensor stands on the part and looks at it. The normal defaults to the
  # nearest face's own outward normal, and the point is brought down to the
  # surface by looking along it — so a coordinate that is merely *near* the part
  # still reads the part rather than reading the air around it.
  defp sensor_camera(part, point, arguments) do
    distance = Map.get(arguments, "distance") || 5.0
    resolution = Map.get(arguments, "resolution") || 64

    with {:ok, normal} <- surface_normal(part, point, Map.get(arguments, "normal")),
         {:ok, surface} <- surface_below(part, point, normal) do
      Camera.patch(surface, normal, distance: distance, width: resolution, height: resolution)
    end
  end

  defp surface_below(part, point, normal) do
    case Quiddity.ray(part, point, Enum.map(normal, &(-&1)), limit: 1) do
      {:ok, %{"hits" => [%{"point" => surface} | _rest]}} -> {:ok, surface}
      _nothing_that_way -> {:ok, point}
    end
  end

  defp surface_normal(_part, _point, normal) when is_list(normal), do: {:ok, normal}

  defp surface_normal(part, point, nil) do
    case Quiddity.nearest(part, point, limit: 1) do
      {:ok, %{"nearest" => [%{"normal" => normal} | _rest]}} when is_list(normal) ->
        {:ok, normal}

      {:ok, _nothing} ->
        {:error,
         %Quiddity.Error{
           code: "bad_request",
           message: "no face is near that point, so there is no normal to look along"
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp summarise(parameters) when is_map(parameters) do
    keep = [
      "diameter",
      "depth",
      "height",
      "radius",
      "width",
      "length",
      "location",
      "axis",
      "bottom"
    ]

    kept = for {key, value} <- parameters, key in keep, value != nil, do: "#{key} #{print(value)}"

    if kept == [], do: "supplementary parameters", else: Enum.join(kept, ", ")
  end

  defp summarise(other), do: inspect(other)

  defp print(value) when is_float(value), do: number(value)
  defp print(value) when is_list(value), do: vector(value)
  defp print(value), do: to_string(value)

  defp vector(values) when is_list(values),
    do: "(" <> Enum.map_join(values, ", ", &number/1) <> ")"

  defp vector(other), do: inspect(other)

  defp box(min, max), do: "#{vector(min)} to #{vector(max)}"

  defp percent(share), do: :erlang.float_to_binary(share * 100, decimals: 1) <> " %"

  defp number(value) when is_integer(value), do: Integer.to_string(value)
  defp number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp number(other), do: inspect(other)
end
