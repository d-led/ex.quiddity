defmodule Quiddity.Frame do
  @moduledoc """
  One camera frame of a part: what each pixel landed on.

  Four answers per pixel, all of them exact, because the ray met the surface
  rather than a depth buffer that then had to be un-projected:

    * the point on the part (millimetres, the file's own coordinates);
    * the outward normal there — and for a pixel that met nothing, the ray
      stopped at the far plane and the normal points back at the sensor, which is
      what "a surface would face me here" means;
    * the face that claimed it (`nil` for a pixel that met nothing);
    * the distance along the ray.

  Points and normals are kept as the flat binaries the engine answered; a caller
  asks for `rows/1` when it wants lists, and pays for the walk then rather than
  on every frame.
  """

  @no_face 4_294_967_295

  defstruct [:width, :height, :points, :normals, :faces, :depth, :camera]

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          points: binary(),
          normals: binary(),
          faces: binary(),
          depth: binary(),
          camera: Quiddity.Camera.t()
        }

  @doc """
  The frame built from what the engine answered.

  `points`, `normals` and `faces` are the engine's own binaries: `3 * w * h`
  little-endian f64, `3 * w * h` f64, `w * h` u32 — and `depth`, `w * h` f64.
  """
  @spec new(map(), Quiddity.Camera.t()) :: t()
  def new(%{points: points, normals: normals, faces: faces, depth: depth}, camera) do
    %__MODULE__{
      width: camera.width,
      height: camera.height,
      points: points,
      normals: normals,
      faces: faces,
      depth: depth,
      camera: camera
    }
  end

  @doc "One `{[x, y, z], [nx, ny, nz], face}` row per pixel, row-major."
  @spec rows(t()) :: [{[float()], [float()], non_neg_integer() | nil}]
  def rows(%__MODULE__{} = frame) do
    Enum.zip_with([points(frame), normals(frame), face_ids(frame)], fn [point, normal, face] ->
      {point, normal, face}
    end)
  end

  @doc "The pixel's point, in millimetres."
  @spec point(t(), non_neg_integer()) :: [float()]
  def point(%__MODULE__{} = frame, index), do: frame |> points() |> Enum.at(index)

  @doc "Every pixel's point, in millimetres."
  @spec points(t()) :: [[float()]]
  def points(%__MODULE__{points: points}), do: triplets(points)

  @doc "Every pixel's outward normal."
  @spec normals(t()) :: [[float()]]
  def normals(%__MODULE__{normals: normals}), do: triplets(normals)

  @doc "Every pixel's face, and `nil` where the ray met nothing."
  @spec face_ids(t()) :: [non_neg_integer() | nil]
  def face_ids(%__MODULE__{faces: faces}) do
    for <<id::unsigned-little-32 <- faces>>, do: if(id == @no_face, do: nil, else: id)
  end

  @doc "Every pixel's distance along its ray, in millimetres."
  @spec depths(t()) :: [float()]
  def depths(%__MODULE__{depth: depth}), do: for(<<d::float-64-little <- depth>>, do: d)

  @doc "How many pixels met the part."
  @spec hits(t()) :: non_neg_integer()
  def hits(%__MODULE__{} = frame), do: frame |> face_ids() |> Enum.count(&(&1 != nil))

  @doc "The share of pixels that met the part, from 0 to 1."
  @spec coverage(t()) :: float()
  def coverage(%__MODULE__{} = frame), do: hits(frame) / (frame.width * frame.height)

  @doc """
  The distance to the nearest and furthest pixel that met the part.

  `{:none, :none}` for a frame that met nothing, which is a different answer from
  a frame whose surface is at zero distance.
  """
  @spec depth_range(t()) :: {float() | :none, float() | :none}
  def depth_range(%__MODULE__{} = frame) do
    case for {depth, face} <- Enum.zip(depths(frame), face_ids(frame)), face != nil, do: depth do
      [] -> {:none, :none}
      hit_depths -> {Enum.min(hit_depths), Enum.max(hit_depths)}
    end
  end

  @doc """
  The centre pixel's row: `{point, normal, face}`.

  A patch sensor reads its location from the middle pixel, which is why this is
  the one pixel with a name.
  """
  @spec centre(t()) :: {[float()], [float()], non_neg_integer() | nil}
  def centre(%__MODULE__{width: width, height: height} = frame) do
    index = div(height, 2) * width + div(width, 2)
    Enum.at(rows(frame), index)
  end

  @doc """
  The rows a Monty observation carries: `[x, y, z, semantic_id]` per pixel.

  A pixel that met the part carries `semantic_id`; a pixel that met nothing
  carries `0.0`, which is Monty's background. That fourth column is what
  `Monty.Frameworks.Models.SensorModules.ObservationProcessor` reads to decide
  `on_object` and `object_coverage`, so it has to mean exactly this.
  """
  @spec semantic_3d(t(), keyword()) :: [[float()]]
  def semantic_3d(%__MODULE__{} = frame, options \\ []) do
    hit_id = Keyword.get(options, :semantic_id, 1) * 1.0

    Enum.zip_with([points(frame), face_ids(frame)], fn [point, face] ->
      point ++ [if(face == nil, do: 0.0, else: hit_id)]
    end)
  end

  @doc """
  A shaded image of the frame, `[r, g, b, a]` per pixel, 0 to 255.

  A B-rep has no colour: quiddity reads geometry, and a STEP file that carries no
  appearance is grey. So this is *shading* — one light from the upper left of the
  camera — and it is honest about what it is: a `hsv` feature read from these
  pixels says how the surface turns, not what it is painted.
  """
  @spec rgba(t(), keyword()) :: [[non_neg_integer()]]
  def rgba(%__MODULE__{} = frame, options \\ []) do
    light = Keyword.get(options, :light, [0.4, 0.5, 0.77])
    light = unit!(light)
    ambient = Keyword.get(options, :ambient, 0.25)

    for normal <- normals(frame) do
      shade = ambient + (1.0 - ambient) * max(0.0, dot(normal, light))
      value = round(shade * 255)
      [value, value, value, 255]
    end
  end

  @doc """
  The families present in the frame, and how many pixels each covers.

  This is the answer to "what am I looking at": the frame's faces are looked up in
  the part's recognition, so a patch on a counterbore says so, and a patch on
  plain stock says nothing at all.
  """
  @spec families(t(), Quiddity.Recognition.t()) :: [
          {String.t() | :body | :unexplained, pos_integer()}
        ]
  def families(%__MODULE__{} = frame, recognition) do
    frame
    |> face_ids()
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies_by(&(Quiddity.Recognition.family_of(recognition, &1) || :unlabelled))
    |> Enum.sort_by(fn {_family, count} -> -count end)
  end

  defp triplets(binary) do
    for <<x::float-64-little, y::float-64-little, z::float-64-little <- binary>>, do: [x, y, z]
  end

  defp dot([ax, ay, az], [bx, by, bz]), do: ax * bx + ay * by + az * bz

  defp unit!([x, y, z]) do
    length = :math.sqrt(x * x + y * y + z * z)
    [x / length, y / length, z / length]
  end
end
