defmodule QuiddityTest do
  @moduledoc """
  What this wrapper must answer, on a part whose features are known:

  a 60 × 50 × 10 mm plate carrying a Ø16 × 8 mm boss and a Ø8 through hole —
  nine faces: five flat sides, the top and the bottom, the hole's wall and the
  boss's wall, and the boss's top.
  """

  use ExUnit.Case, async: true

  alias Quiddity.{Camera, Error, Face, Frame, Part, Recognition}

  @fixture "test/fixtures/golden_simple_through_hole.step"
  @blend "test/fixtures/blend_r5.step"
  @blend_enlarged "test/fixtures/blend_r5_enlarged.step"

  # The faces the assertions below name, from the recognition's own account.
  @hole_wall 6
  @boss_wall 7
  @boss_top 8

  setup_all do
    {:ok, part} = Quiddity.open(@fixture)
    {:ok, recognition} = Quiddity.features(part)
    %{part: part, recognition: recognition}
  end

  describe "opening a part" do
    test "answers a handle holding the parsed B-rep, with a summary of it", %{part: part} do
      assert part.summary["faces"] == Part.face_count(part)
      assert part.summary["faces"] == 9
      assert part.summary["edges"] == 18
      assert part.summary["solids"] == 1
      refute Part.shell?(part)
      assert part.path == Path.expand(@fixture)
      assert Part.unresolved_faces(part) == []
    end

    test "identifies the file by its bytes, not by its path", %{part: part} do
      assert part.summary["sha256"] =~ ~r/\A[0-9a-f]{64}\z/
      assert part.summary["bytes"] == File.stat!(@fixture).size
    end

    test "measures the plate the file describes", %{part: part} do
      extent = part |> Part.extent() |> Enum.map(&Float.round(&1, 6))

      assert extent == [60.0, 50.0, 18.0]
      assert {[-30.0, -25.0, -5.0], [30.0, 25.0, 13.0]} = Part.bounds(part)

      assert_in_delta 2 * :math.sqrt(30 * 30 + 25 * 25 + 9 * 9), Part.diagonal(part), 1.0e-9
    end

    test "refuses a file that is not there, in words a person can act on" do
      assert {:error, %Error{code: "unreadable", message: message}} =
               Quiddity.open("no/such/part.step")

      assert message =~ "no such file"
    end

    test "refuses a file that is not a STEP part" do
      path = Path.join(System.tmp_dir!(), "not-a-part.step")

      File.write!(path, "ISO-10303-21;\nHEADER;\nENDSEC;\nEND-ISO-10303-21;\n")
      assert {:error, %Error{code: "broken_step"}} = Quiddity.open(path)
      File.rm!(path)
    end

    test "answers the engine's own capabilities, versioned" do
      assert {:ok, capabilities} = Quiddity.capabilities()

      assert capabilities["schema_version"] == "quiddity-rust/capabilities/1"
      assert capabilities["package"]["name"] == "quiddity-rust"
      assert "recognise" in capabilities["functions"]
      assert "correspond" in capabilities["functions"]
    end
  end

  describe "recognising the part" do
    test "names the hole the plate has, and its measured size", %{recognition: recognition} do
      assert [hole] = Recognition.by_family(recognition, "holes")
      assert hole["parameters"]["diameter"] == 8.0
      assert hole["parameters"]["depth"] == 10.0
      assert hole["parameters"]["bottom"] == "through"
      assert_in_delta(-12.0, hole["parameters"]["location"] |> Enum.at(0), 1.0e-6)
      assert hole["evidence_status"] == "verified"
    end

    test "names the boss standing on the plate, and its measured height",
         %{recognition: recognition} do
      assert [boss] = Recognition.by_family(recognition, "bosses")
      assert boss["parameters"]["diameter"] == 16.0
      assert boss["parameters"]["height"] == 8.0
      assert_in_delta 13.0, boss["parameters"]["location"] |> Enum.at(2), 1.0e-6
    end

    test "groups the records by family, and counts every face", %{
      part: part,
      recognition: recognition
    } do
      assert {"holes", 1} in Recognition.families(recognition)

      owned =
        for face <- 0..(Part.face_count(part) - 1)//1,
            do: Recognition.owner(recognition, face)

      assert length(owned) == Part.face_count(part)
      assert Enum.all?(owned, &(&1 in [:body, :refused, :unexplained] or is_binary(&1)))
    end

    test "says which feature a face belongs to — what a sensel asks", %{recognition: recognition} do
      assert Recognition.family_of(recognition, @hole_wall) == "holes"
      assert Recognition.family_of(recognition, @boss_wall) == "bosses"
      # The plate's own top face is the riser the boss stands on.
      assert Recognition.family_of(recognition, 2) == "risers"
      # A flat side of the stock belongs to no feature, and that is an answer.
      assert Recognition.family_of(recognition, 0) == nil
      assert Recognition.owner(recognition, 0) == :body
    end

    test "accounts for every face of the part, none silently dropped", %{
      recognition: recognition
    } do
      assert recognition.face_owner == %{
               0 => :body,
               1 => :body,
               2 => "risers/0",
               3 => :body,
               4 => :body,
               5 => :body,
               6 => "holes/0",
               7 => "bosses/0",
               # quiddity 0.5 does not claim the boss's top face for the boss;
               # an unexplained face is said out loud rather than attached to
               # the nearest thing that fits.
               8 => :unexplained
             }

      assert Recognition.unexplained_faces(recognition) == [8]
    end

    test "a face of the hole's wall is a cylinder of the hole's radius", %{part: part} do
      assert {:ok, face} = Quiddity.face(part, @hole_wall)

      assert Face.kind(face) == "cylinder"
      assert_in_delta 4.0, Face.radius(face), 1.0e-9
      assert_in_delta 8.0, Face.diameter(face), 1.0e-9
      assert_in_delta :math.pi() * 8 * 10, face.area, 1.0e-6
      assert Face.describe(face) =~ "radius 4.000 mm"
    end

    test "a flat face knows which way it faces", %{part: part} do
      assert {:ok, top} = Quiddity.face(part, @boss_top)

      assert Face.kind(top) == "plane"
      assert_in_delta 1.0, top.normal |> Enum.at(2), 1.0e-12
      assert_in_delta :math.pi() * 64, top.area, 1.0e-6
      assert @boss_wall in top.neighbours
    end

    test "refuses a face the part does not have, and says the range", %{part: part} do
      assert {:error, %Error{code: "bad_request", message: message}} =
               Quiddity.face(part, Part.face_count(part))

      assert message =~ "0 to 8"
    end
  end

  describe "asking where things are" do
    test "a ray from 10 mm off a face, towards it, meets that face", %{part: part} do
      {:ok, boss_top} = Quiddity.face(part, @boss_top)
      origin = Enum.zip_with(boss_top.centroid, boss_top.normal, fn c, n -> c + 10.0 * n end)
      towards = Enum.map(boss_top.normal, &(-&1))

      assert {:ok, %{"hits" => [first | _rest], "searched" => 100.0}} =
               Quiddity.ray(part, origin, towards, far: 100.0)

      assert first["face"] == @boss_top
      assert_in_delta 10.0, first["distance"], 1.0e-9
      assert_in_delta 0.0, distance(first["point"], boss_top.centroid), 1.0e-9
    end

    test "a ray into open space meets nothing, and says how far it looked", %{part: part} do
      assert {:ok, %{"hits" => [], "searched" => 50.0}} =
               Quiddity.ray(part, [0.0, 0.0, 500.0], [0.0, 0.0, 1.0], far: 50.0)
    end

    test "the nearest faces to a point above the boss are the boss's", %{part: part} do
      assert {:ok, %{"nearest" => [nearest | _rest]}} =
               Quiddity.nearest(part, [15.0, 0.0, 23.0])

      assert nearest["face"] == @boss_top
      assert_in_delta 10.0, nearest["distance"], 1.0e-9
      assert_in_delta 1.0, nearest["normal"] |> Enum.at(2), 1.0e-9
    end

    test "a point inside the plate is in it, and one beside it is out", %{part: part} do
      assert {:ok, %{"state" => "in"}} = Quiddity.classify(part, [25.0, 20.0, 0.0])
      assert {:ok, %{"state" => "in"}} = Quiddity.classify(part, [15.0, 0.0, 9.0])
      assert {:ok, %{"state" => "out"}} = Quiddity.classify(part, [15.0, 0.0, 20.0])
      # The hole's bore, at the plate's mid-height, is not material.
      assert {:ok, %{"state" => "out"}} = Quiddity.classify(part, [-12.0, 0.0, 0.0])
    end
  end

  describe "a camera on the part" do
    test "a patch 10 mm above the boss's top reads back that spot", %{part: part} do
      {:ok, boss_top} = Quiddity.face(part, @boss_top)
      {:ok, camera} = Camera.patch(boss_top.centroid, boss_top.normal, distance: 10.0)

      assert {:ok, frame} = Quiddity.frame(part, camera)

      {point, normal, face} = Frame.centre(frame)
      assert face == @boss_top

      # A pixel is a patch of surface, not a point: the centre pixel is half a
      # pixel off the exact centroid, and one pixel's worth is the tolerance.
      assert_in_delta 0.0, distance(point, boss_top.centroid), Camera.pixel_size(camera, 10.0)
      assert_in_delta 1.0, dot(normal, boss_top.normal), 1.0e-9
      # The boss's top is Ø16 and the patch sees ~13 mm across at 10 mm out, so
      # the frame is nearly all boss.
      assert Frame.coverage(frame) > 0.9
    end

    test "a camera pointed away sees nothing, and that is not an error", %{part: part} do
      {:ok, camera} = Camera.looking_at([0.0, 0.0, 400.0], [0.0, 0.0, 800.0], width: 8, height: 8)

      assert {:ok, frame} = Quiddity.frame(part, camera)
      assert Frame.hits(frame) == 0
      assert Frame.coverage(frame) == 0.0
      assert Frame.depth_range(frame) == {:none, :none}
    end

    test "a frame is exactly as many pixels as the camera asked for", %{part: part} do
      {:ok, camera} = Camera.looking_at([0.0, 0.0, 60.0], [0.0, 0.0, 0.0], width: 24, height: 16)
      {:ok, frame} = Quiddity.frame(part, camera)

      assert length(Frame.rows(frame)) == 24 * 16
      assert length(Frame.semantic_3d(frame)) == 24 * 16

      {_point, _normal, face} = Frame.centre(frame)
      assert face in 0..8
      # Every pixel says which semantic id it carries: 1 on the part, 0 off it.
      assert Enum.uniq(Frame.semantic_3d(frame) |> Enum.map(&List.last/1)) == [0.0, 1.0]
    end

    test "a camera's basis is orthonormal and right-handed", %{part: part} do
      {:ok, camera} = Camera.looking_at([0.0, 0.0, 60.0], [0.0, 3.0, 0.0], width: 8, height: 8)

      assert_in_delta 1.0, length_of(camera.forward), 1.0e-12
      assert_in_delta 1.0, length_of(camera.right), 1.0e-12
      assert_in_delta 1.0, length_of(camera.up), 1.0e-12
      assert_in_delta 0.0, dot(camera.forward, camera.right), 1.0e-12
      assert_in_delta 0.0, dot(camera.right, camera.up), 1.0e-12

      # right × forward = up, which is what makes a frame's rows run down.
      assert_in_delta 0.0, distance(cross(camera.right, camera.forward), camera.up), 1.0e-12

      assert {:ok, _frame} = Quiddity.frame(part, camera)
    end

    test "a camera whose up is parallel to its view still has a basis" do
      assert {:ok, camera} =
               Camera.looking_at([0.0, 0.0, 10.0], [0.0, 0.0, 0.0], up: [0.0, 0.0, 1.0])

      assert_in_delta 1.0, length_of(camera.up), 1.0e-12
      assert_in_delta 0.0, dot(camera.up, camera.forward), 1.0e-12
    end

    test "the camera's pose is the matrix a Monty observation carries" do
      {:ok, camera} = Camera.looking_at([1.0, 2.0, 3.0], [1.0, 2.0, 0.0])
      [r1, r2, r3, r4] = Camera.cam_to_world(camera)

      # The translation column is the camera's origin, and the frame is rigid.
      assert Enum.at(r1, 3) == 1.0
      assert Enum.at(r2, 3) == 2.0
      assert Enum.at(r3, 3) == 3.0
      assert r4 == [0.0, 0.0, 0.0, 1.0]
    end
  end

  describe "the part's triangles and surface" do
    test "the part meshes into triangles that name their faces", %{part: part} do
      assert {:ok, %{triangles: triangles, face_of_triangle: owners, meta: meta}} =
               Quiddity.mesh(part)

      assert meta["faces"] == Part.face_count(part)
      assert meta["refused_faces"] == []
      assert length(triangles) == length(owners)
      refute triangles == []
      assert Enum.all?(owners, &(&1 < Part.face_count(part)))
      # Every face the part has is represented by at least one triangle.
      assert owners |> Enum.uniq() |> Enum.sort() == Enum.to_list(0..8)
    end

    test "a coarser deflection makes fewer triangles of the same part", %{part: part} do
      {:ok, fine} = Quiddity.mesh(part, deflection: 0.01)
      {:ok, coarse} = Quiddity.mesh(part, deflection: 2.0)

      assert length(fine.triangles) > length(coarse.triangles)
    end

    test "sampling the surface puts points on it, spaced as asked", %{part: part} do
      {:ok, %{points: points, normals: normals, faces: faces, meta: meta}} =
        Quiddity.samples(part, spacing: 4.0)

      assert length(points) == length(normals)
      assert length(points) == length(faces)
      assert meta["points"] == length(points)
      assert meta["truncated"] == false

      assert Enum.all?(faces, &(&1 < Part.face_count(part)))
      assert Enum.all?(normals, fn normal -> abs(length_of(normal) - 1.0) < 1.0e-9 end)

      # Every sample is on the part, not floating beside it: the nearest face to
      # it is one of the part's, at zero distance.
      sample = hd(points)
      assert {:ok, %{"nearest" => [nearest | _rest]}} = Quiddity.nearest(part, sample)
      assert_in_delta 0.0, nearest["distance"], 1.0e-6
    end

    test "a limit truncates the sample rather than running away", %{part: part} do
      {:ok, %{points: points, meta: meta}} = Quiddity.samples(part, spacing: 0.5, limit: 100)

      assert length(points) == 100
      assert meta["truncated"] == true
    end

    test "a spacing of zero is refused", %{part: part} do
      assert {:error, %Error{code: "bad_request"}} = Quiddity.samples(part, spacing: 0.0)
    end
  end

  describe "what the part is made of" do
    test "the plate's volume is the box less the hole plus the boss", %{part: part} do
      assert {:ok, mass} = Quiddity.mass(part)

      # 60 × 50 × 10 of stock, less a Ø8 through hole, plus a Ø16 × 8 boss.
      expected = 60 * 50 * 10 - :math.pi() * 4 * 4 * 10 + :math.pi() * 8 * 8 * 8
      assert_in_delta expected, mass["volume"], 1.0

      assert [solid] = mass["solids"]
      assert_in_delta expected, solid["volume"], 1.0
      assert solid["valid"] == true
    end

    test "a density gives a mass, and none is guessed without one", %{part: part} do
      {:ok, without} = Quiddity.mass(part)
      {:ok, steel} = Quiddity.mass(part, density: 0.00785)

      assert without["mass"] == nil
      assert_in_delta without["volume"] * 0.00785, steel["mass"], 1.0e-6
      assert steel["density"] == 0.00785
    end

    test "the centroid is inside the box the part occupies", %{part: part} do
      {:ok, mass} = Quiddity.mass(part)
      {min, max} = Part.bounds(part)

      assert Enum.zip_with([min, max, mass["centroid"]], fn [lo, hi, c] -> c > lo and c < hi end)
             |> Enum.all?()
    end

    test "one part is an assembly of one, with its placement", %{part: part} do
      assert {:ok, parts} = Quiddity.parts(part)
      assert [only] = parts["parts"]

      assert only["faces"] == Part.face_count(part)
      assert only["edges"] == part.summary["edges"]
      assert [placement] = only["placements"]
      assert Enum.all?(placement, &(length(&1) == 4))
    end

    test "the file carries no PMI, which is a document with none", %{part: part} do
      assert {:ok, pmi} = Quiddity.pmi(part)
      assert is_map(pmi)
      assert get_in(pmi, ["parts"]) |> Enum.all?(&(&1["pmi"] in [nil, %{}]))
    end

    test "evidence is a document about the features, not an empty view", %{part: part} do
      assert {:ok, evidence} = Quiddity.evidence(part)

      assert evidence["schema_version"] =~ "quiddity-rust/evidence"
      assert is_list(evidence["features"])
    end
  end

  describe "comparing two revisions" do
    test "fingerprints name every feature, revision-independently", %{part: part} do
      assert {:ok, fingerprints} = Quiddity.fingerprints(part)

      assert is_map(fingerprints)
      assert fingerprints["fingerprint_version"]
      assert [_ | _] = fingerprints["features"]
    end

    test "an enlarged blend corresponds: the same part, with something changed" do
      assert {:ok, correspondence} = Quiddity.correspond(@blend, @blend_enlarged)

      assert is_map(correspondence)
      assert [_ | _] = correspondence["features"] || correspondence["records"]
    end

    test "a revision that cannot be read is refused, with its path in the message" do
      assert {:error, %Error{code: "unreadable", message: message}} =
               Quiddity.correspond(@blend, "no/such/revision.step")

      assert message =~ "no/such/revision.step"
    end
  end

  defp length_of([x, y, z]), do: :math.sqrt(x * x + y * y + z * z)
  defp dot([ax, ay, az], [bx, by, bz]), do: ax * bx + ay * by + az * bz

  defp cross([ax, ay, az], [bx, by, bz]),
    do: [ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx]

  defp distance([ax, ay, az], [bx, by, bz]) do
    :math.sqrt((ax - bx) ** 2 + (ay - by) ** 2 + (az - bz) ** 2)
  end
end
