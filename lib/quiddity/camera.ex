defmodule Quiddity.Camera do
  @moduledoc """
  A pinhole camera: where a sensor is, what it looks along, and how wide it sees.

  The basis is spelled out rather than inferred — `forward`, `right`, `up` — so a
  frame's pixel geometry is a property of this struct and nothing has to agree
  with MuJoCo about which way a camera's own −z points. The defaults are the ones
  a Monty patch sensor uses: 64 × 64 pixels, a 66° field of view, a metre past the
  part, so a CAD frame and a simulator frame cover the same solid angle.

  Millimetres, everywhere: a STEP file is in millimetres and so is this.
  """

  @default_fov_degrees 66.0
  @default_far 10_000.0

  defstruct origin: [0.0, 0.0, 0.0],
            forward: [0.0, 0.0, -1.0],
            right: [1.0, 0.0, 0.0],
            up: [0.0, 1.0, 0.0],
            width: 64,
            height: 64,
            fov_x: @default_fov_degrees * :math.pi() / 180.0,
            near: 0.0,
            far: @default_far

  @type t :: %__MODULE__{
          origin: [float()],
          forward: [float()],
          right: [float()],
          up: [float()],
          width: pos_integer(),
          height: pos_integer(),
          fov_x: float(),
          near: float(),
          far: float()
        }

  @doc """
  A camera at *eye* looking at *target*.

  Options: `:width`, `:height`, `:fov_x` (radians), `:up` (the roll reference,
  defaulting to the world axis least aligned with the view so a straight-down
  look still has a sensible up), `:near` and `:far`.
  """
  @spec looking_at([float()], [float()], keyword()) :: {:ok, t()} | {:error, Quiddity.Error.t()}
  def looking_at(eye, target, options \\ []) do
    with {:ok, forward} <- unit(sub(target, eye)) do
      up = Keyword.get_lazy(options, :up, fn -> least_aligned_axis(forward) end)

      case unit(project_out(up, forward)) do
        {:ok, up} ->
          {:ok, build(eye, forward, up, options)}

        {:error, _degenerate} ->
          # A caller whose up is parallel to its view: square the basis off
          # against the world instead of refusing a camera that has an answer.
          {:ok, forward} = unit(forward)
          {:ok, fallback} = unit(project_out(least_aligned_axis(forward), forward))
          {:ok, build(eye, forward, fallback, options)}
      end
    end
  end

  @doc """
  A sensor placed *distance* mm off a surface, looking straight at it.

  This is the placement a patch camera has on a part: the eye sits on the outward
  normal, the view runs back down it. The roll reference is a tangent to the
  surface, so the patch's rows and columns follow the surface rather than the
  world.
  """
  @spec patch([float()], [float()], keyword()) :: {:ok, t()} | {:error, Quiddity.Error.t()}
  def patch(point, normal, options \\ []) do
    distance = Keyword.get(options, :distance, 10.0)

    with {:ok, normal} <- unit(normal) do
      eye = add(point, scale(normal, distance))
      options = Keyword.put_new_lazy(options, :up, fn -> tangent(normal) end)
      looking_at(eye, point, options)
    end
  end

  @doc "The camera as the engine reads it."
  @spec to_params(t()) :: map()
  def to_params(%__MODULE__{} = camera) do
    %{
      "origin" => camera.origin,
      "forward" => camera.forward,
      "right" => camera.right,
      "up" => camera.up,
      "width" => camera.width,
      "height" => camera.height,
      "fov_x" => camera.fov_x,
      "near" => camera.near,
      "far" => camera.far
    }
  end

  @doc "The `cam_to_world` matrix a Monty observation carries, as rows."
  @spec cam_to_world(t()) :: [[float()]]
  def cam_to_world(%__MODULE__{} = camera) do
    [r1, r2, r3] = [camera.right, camera.up, camera.forward]
    [x, y, z] = camera.origin

    [
      [r1 |> at(0), r2 |> at(0), r3 |> at(0), x],
      [r1 |> at(1), r2 |> at(1), r3 |> at(1), y],
      [r1 |> at(2), r2 |> at(2), r3 |> at(2), z],
      [0.0, 0.0, 0.0, 1.0]
    ]
  end

  @doc "The width one pixel covers at *distance* mm, in millimetres."
  @spec pixel_size(t(), float()) :: float()
  def pixel_size(%__MODULE__{} = camera, distance) do
    distance * 2.0 * :math.tan(camera.fov_x / 2.0) / camera.width
  end

  defp build(eye, forward, up, options) do
    %__MODULE__{
      origin: Enum.map(eye, &(&1 * 1.0)),
      forward: forward,
      up: up,
      right: cross(forward, up),
      width: Keyword.get(options, :width, 64),
      height: Keyword.get(options, :height, 64),
      fov_x: Keyword.get(options, :fov_x, @default_fov_degrees * :math.pi() / 180.0),
      near: Keyword.get(options, :near, 0.0),
      far: Keyword.get(options, :far, @default_far)
    }
  end

  @doc """
  A tangent to a surface with *normal*: the direction a patch's `up` follows.

  The world axis least aligned with the normal is crossed with it, so a part
  that is not aligned to the world gets a tangent that follows it, and a part
  that is gets one along its own axes.
  """
  @spec tangent([float()]) :: [float()]
  def tangent(normal) do
    {:ok, normal} = unit(normal)
    {:ok, tangent} = unit(cross(normal, least_aligned_axis(normal)))
    tangent
  end

  @doc "The world axis least aligned with a direction — a usable roll reference."
  @spec least_aligned_axis([float()]) :: [float()]
  def least_aligned_axis(direction) do
    axes = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]

    axes
    |> Enum.min_by(fn axis -> abs(dot(axis, direction)) end)
    |> then(fn axis -> if dot(axis, direction) >= 0.0, do: axis, else: scale(axis, -1.0) end)
  end

  defp project_out(vector, direction), do: sub(vector, scale(direction, dot(vector, direction)))

  defp at([a, _b, _c], 0), do: a
  defp at([_a, b, _c], 1), do: b
  defp at([_a, _b, c], 2), do: c

  defp add([ax, ay, az], [bx, by, bz]), do: [ax + bx, ay + by, az + bz]
  defp sub([ax, ay, az], [bx, by, bz]), do: [ax - bx, ay - by, az - bz]
  defp scale([x, y, z], k), do: [x * k, y * k, z * k]

  defp dot([ax, ay, az], [bx, by, bz]), do: ax * bx + ay * by + az * bz

  defp cross([ax, ay, az], [bx, by, bz]),
    do: [ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx]

  defp unit([x, y, z] = vector) do
    length = :math.sqrt(x * x + y * y + z * z)

    if length == 0.0 do
      {:error, %Quiddity.Error{code: "bad_request", message: "no direction"}}
    else
      {:ok, scale(vector, 1.0 / length)}
    end
  end
end
