defmodule Quiddity.MontyTest do
  @moduledoc """
  The bridge to Monty: the observations a frame becomes, the percept Monty's own
  processor fits, and the graph memory a run loads.

  The library format is the contract that matters — `Monty.Studio.Memory` reads it
  back — so one test writes a library and reads it with the format's own rules.
  """

  use ExUnit.Case, async: true

  alias Quiddity.{Camera, Mjcf, Percept}
  alias Quiddity.Monty.{Library, Training}

  @fixture "test/fixtures/golden_simple_through_hole.step"
  @boss_top [15.0, 0.0, 13.0]

  setup_all do
    {:ok, part} = Quiddity.open(@fixture)
    %{part: part}
  end

  defp patch(part, point \\ @boss_top, normal \\ [0.0, 0.0, 1.0]) do
    {:ok, camera} = Camera.patch(point, normal, distance: 5.0)
    Quiddity.frame(part, camera)
  end

  describe "the observation a frame becomes" do
    test "is shaped as the sensor modules read it", %{part: part} do
      {:ok, frame} = patch(part)
      observation = Percept.observation(frame)

      assert length(observation["semantic_3d"]) == frame.width * frame.height
      assert [x, y, z, id] = hd(observation["semantic_3d"])
      assert is_float(x) and is_float(y) and is_float(z)
      assert id in [0.0, 1.0]

      # An image is rows of pixels, not a flat list.
      assert length(observation["rgba"]) == frame.height
      assert length(hd(observation["rgba"])) == frame.width
      assert length(hd(hd(observation["rgba"]))) == 4

      assert [[_, _, _, _], _, _, [0.0, 0.0, 0.0, 1.0]] = observation["cam_to_world"]
    end

    test "a background pixel carries Monty's background, not a face number", %{part: part} do
      {:ok, camera} = Camera.looking_at([0.0, 0.0, 200.0], [0.0, 0.0, 400.0])
      {:ok, frame} = Quiddity.frame(part, camera)

      assert Enum.all?(Percept.observation(frame)["semantic_3d"], &(List.last(&1) == 0.0))
    end
  end

  describe "the percept" do
    test "is Monty's own processor's answer, and it is a node's worth of features", %{part: part} do
      {:ok, frame} = patch(part)
      {:ok, message} = Percept.message(frame)
      features = Percept.node_features(message)

      # The location is the middle pixel, which is within a pixel of the spot the
      # sensor was put on — a pixel is a patch of surface, not a point.
      assert_in_delta 0.0,
                      distance(message.location, @boss_top),
                      Camera.pixel_size(frame.camera, 5.0)

      assert features["on_object"] == 1.0
      assert features["object_coverage"] == 1.0
      assert [normal | _rest] = features["pose_vectors"]
      assert_in_delta 1.0, length_of(normal), 1.0e-9
      # A flat patch reads flat.
      assert_in_delta 0.0, features["principal_curvatures_log"] |> Enum.at(0), 0.1
      assert is_integer(message.semantic_id) or is_nil(message.semantic_id)
      assert message.sender_id == "patch"
    end

    test "a frame that met nothing still makes a percept, and it says so", %{part: part} do
      {:ok, camera} = Camera.looking_at([0.0, 0.0, 200.0], [0.0, 0.0, 400.0])
      {:ok, frame} = Quiddity.frame(part, camera)

      assert {:ok, message} = Percept.message(frame)
      assert Percept.node_features(message)["on_object"] == 0.0
      refute message.process_features_in_lm
    end
  end

  describe "training from a part" do
    test "visits land on the surface, and each node says which feature it is on", %{part: part} do
      {:ok, %{nodes: nodes} = visits} = Training.nodes(part, spacing: 14.0, limit: 24)

      assert visits.visited == 24
      assert length(nodes) <= visits.visited
      assert visits.skipped == visits.visited - length(nodes)
      assert nodes != []

      for node <- nodes do
        assert {:ok, %{"nearest" => [%{"distance" => away} | _rest]}} =
                 Quiddity.nearest(part, node.location)

        assert_in_delta 0.0, away, 1.0e-3

        assert is_integer(node.face)
        assert node.features["pose_vectors"] != nil
        assert node.family in [nil, "holes", "bosses", "risers"]
      end
    end

    test "a coarser spacing visits less often", %{part: part} do
      {:ok, dense} = Training.nodes(part, spacing: 12.0, limit: 500)
      {:ok, sparse} = Training.nodes(part, spacing: 40.0, limit: 500)

      assert dense.visited > sparse.visited
      assert length(dense.nodes) > length(sparse.nodes)
    end

    test "a visit whose patch misses the surface is skipped, not stored", %{part: part} do
      # A coverage nothing can satisfy: every visit fails the rule, and the
      # answer says they were visits rather than nodes.
      {:ok, %{nodes: nodes, visited: visited, skipped: skipped}} =
        Training.nodes(part, spacing: 10.0, limit: 5, min_coverage: 1.01)

      assert nodes == []
      assert visited == 5
      assert skipped == 5
    end

    test "an edge visit is skipped rather than stored with no pose", %{part: part} do
      {:ok, %{nodes: nodes, skipped: skipped}} = Training.nodes(part, spacing: 3.0, limit: 400)

      assert skipped > 0
      assert Enum.all?(nodes, &(&1.coverage >= 0.6))
    end
  end

  describe "the library a run loads" do
    test "holds one column per feature, as long as its node list", %{part: part} do
      {:ok, %{nodes: nodes}} = Training.nodes(part, spacing: 14.0, limit: 12)
      {:ok, library} = Training.library(nodes, "through_hole_plate")

      assert Library.size(library) == length(nodes)
      assert "pose_vectors" in Library.feature_names(library)

      for {_name, column} <- library.features do
        assert length(column) == length(nodes)
      end
    end

    test "refuses a library whose columns and nodes disagree" do
      assert {:error, %Quiddity.Error{code: "bad_request", message: message}} =
               Library.new("part", [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0]], [
                 %{"hsv" => [0.0, 0.0, 0.0]}
               ])

      assert message =~ "2 locations but 1 nodes' features"
    end

    test "refuses a location that is not three numbers" do
      assert {:error, %Quiddity.Error{code: "bad_request"}} =
               Library.new("part", [[0.0, 1.0]], [%{"hsv" => [0.0, 0.0, 0.0]}])
    end

    @tag :tmp_dir
    test "writes the format the studio reads back", %{part: part, tmp_dir: dir} do
      path = Path.join(dir, "through_hole_plate.jsonl.gz")
      {:ok, written} = Training.write(part, "through_hole_plate", path, spacing: 14.0, limit: 12)

      assert written.nodes > 0
      assert written.source_sha256 == part.summary["sha256"]
      assert File.exists?(path)

      # Read it the way `Monty.Studio.Memory` does: gunzip, one JSON record a
      # line, positions and feature columns of the same length.
      [record] =
        path
        |> File.read!()
        |> :zlib.gunzip()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert record["object_id"] == "through_hole_plate"
      assert record["input_channel"] == "patch"
      assert record["lm_index"] == 0
      assert length(record["positions"]) == written.nodes

      positions = record["positions"]
      features = record["features"]

      assert Enum.all?(positions, &(length(&1) == 3))
      assert Enum.all?(features, fn {_name, column} -> length(column) == length(positions) end)

      # The names a Monty memory matches on are present, and each node's pose is
      # three rows of three.
      for name <- ["pose_vectors", "pose_fully_defined", "principal_curvatures_log"] do
        assert Map.has_key?(features, name)
      end

      assert Enum.all?(features["pose_vectors"], fn rows -> length(rows) == 3 end)
    end
  end

  describe "a scene for a simulator" do
    test "is an MJCF model of the part, in metres", %{part: part} do
      {:ok, xml} = Mjcf.document(part)

      assert xml =~ ~s(<mujoco model="part">)
      assert xml =~ ~s(<geom name="part" type="mesh")
      assert xml =~ "<mesh name=\"part\" vertex="

      # Vertices are metres: the plate is 60 mm wide, so no coordinate reaches 0.1.
      [vertices] = Regex.run(~r/vertex="([^"]+)"/, xml) |> Enum.drop(1)
      coordinates = vertices |> String.split(" ") |> Enum.map(&String.to_float/1)

      assert coordinates != []
      assert Enum.all?(coordinates, &(abs(&1) < 0.1))
      assert_in_delta 0.06, Enum.max(coordinates) - Enum.min(coordinates), 0.11
    end

    @tag :tmp_dir
    test "writes the scene where it is told", %{part: part, tmp_dir: dir} do
      path = Path.join(dir, "plate.xml")
      assert :ok = Mjcf.write(part, path)
      assert File.read!(path) =~ "<worldbody>"
    end
  end

  defp distance([ax, ay, az], [bx, by, bz]) do
    :math.sqrt((ax - bx) ** 2 + (ay - by) ** 2 + (az - bz) ** 2)
  end

  defp length_of([x, y, z]), do: :math.sqrt(x * x + y * y + z * z)
end
