defmodule Quiddity.UpstreamTest do
  @moduledoc """
  Cases translated from quiddity's own high-level tests.

  quiddity's `tests/*.rs` at the repository root drive its public library API —
  `serve::recognise_step` and the document it answers — which is the level this
  binding exposes. A case here is one case there: the name says which, and the
  comment says what changed in the translation.

  ## What is not here, and why

  The rest of that suite asks the library for things this binding does not yet
  offer, so a translation would be a different test wearing the same name:

    * `tests/congruent.rs`, `tests/rigid_transform.rs` — need a part to be
      translated, rotated or composed before it is read; this binding reads a
      file in the coordinates it holds.
    * `tests/assembly_layout.rs` — needs assembly files and the placement
      sidecar form; the binding exposes `Quiddity.parts/1` and not the layouts.
    * `tests/mutations.rs` — drives the reader over mutated STEP byte streams,
      which is `haecceity`'s level rather than this one. What survives here is
      "a broken file is refused", which the reader's own suite covers.
    * `tests/face_accounting.rs`'s corpus half — the corpus is not shipped, so
      only its goldens half is translated.
  """

  use ExUnit.Case, async: true

  alias Quiddity.Recognition

  @fixtures Path.wildcard("test/fixtures/*.step")

  setup_all do
    parts =
      Map.new(@fixtures, fn path ->
        {:ok, part} = Quiddity.open(path)
        {path, part}
      end)

    %{parts: parts}
  end

  test "the fixtures this suite runs over are the ones it says", %{parts: parts} do
    assert Path.basename("golden_simple_through_hole.step") in Enum.map(parts, fn {p, _} ->
             Path.basename(p)
           end)
  end

  describe "quiddity tests/determinism.rs" do
    # Translated from `recognition_json_is_the_same_twice_in_one_process`. The
    # upstream case reads each corpus part twice in one process and compares the
    # recognition documents; this reads each part twice and compares what the
    # binding answers. The corpus half is not shipped, so the goldens carry it.
    test "the recognition document is the same twice in one process", %{parts: parts} do
      for {path, part} <- parts do
        assert {:ok, first} = Quiddity.features(part), path
        assert {:ok, second} = Quiddity.features(part), path

        assert first == second,
               "#{path}: the recognition differs between two reads in one process"
      end
    end
  end

  describe "quiddity tests/face_accounting.rs" do
    # Translated from `complete_partition_on_all_goldens_and_recorded_corpus`.
    # Upstream counts the face accounting groups and asserts their sum is the
    # face count, for every `golden_*.step` and then the corpus. Here every face
    # is asked for its owner, and the claim is the same: the accounting is a
    # partition — one group per face, none of them "unaccounted".
    test "every face is accounted for exactly once", %{parts: parts} do
      for {path, part} <- parts do
        assert {:ok, recognition} = Quiddity.features(part), path
        assert recognition.face_count > 0, "#{path}: no faces"

        owners =
          for face <- 0..(recognition.face_count - 1)//1 do
            Recognition.owner(recognition, face)
          end

        assert length(owners) == recognition.face_count
        refute :unaccounted in owners, "#{path}: a face nothing accounts for"

        groups =
          owners
          |> Enum.map(fn
            :body -> :body
            :refused -> :refused
            :unexplained -> :unexplained
            _feature_id -> :feature
          end)
          |> Enum.frequencies()

        assert groups |> Map.values() |> Enum.sum() == recognition.face_count,
               "#{path}: the groups do not add up to the faces"

        # A partition over faces nothing claims would pass vacuously: the
        # fixtures have to exercise a feature group for this to mean anything.
        assert Map.get(groups, :feature, 0) > 0,
               "#{path}: no feature claimed a face, so there is nothing to partition here"
      end
    end
  end
end
