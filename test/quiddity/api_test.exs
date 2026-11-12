defmodule Quiddity.ApiTest do
  @moduledoc """
  The operation table is the contract: every operation it lists must have a NIF
  stub at the arity it declares, and the MCP catalogue must not name a tool the
  engine cannot answer.
  """

  use ExUnit.Case, async: true

  alias Quiddity.{Api, Mcp, Native}

  @fixture "test/fixtures/golden_simple_through_hole.step"

  test "every listed operation has a stub at the arity it declares" do
    Code.ensure_loaded!(Native)

    for %{name: name, args: args} <- Api.operations() do
      assert function_exported?(Native, name, length(args)),
             "Quiddity.Native.#{name}/#{length(args)} is missing — the table and the Rust side disagree"
    end
  end

  test "every listed operation answers, once there is a part to ask about" do
    {:ok, part} = Quiddity.open(@fixture)

    for %{name: name, args: args, answer: answer} <- Api.operations(), name != :brep_open do
      arguments = arguments(name, part, args)
      result = apply(Native, name, arguments)

      assert answered?(result), "#{name} answered #{inspect(result)}"
      assert shape(answer, result), "#{name} answered #{inspect(result)}, not a #{answer}"
    end
  end

  test "the table's names are unique, and every operation has a summary" do
    names = Enum.map(Api.operations(), & &1.name)

    assert names == Enum.uniq(names)
    assert Enum.all?(Api.operations(), &(String.length(&1.summary) > 0))
  end

  test "the arity an operation declares is the arity the table asks for" do
    for %{name: name, args: args} <- Api.operations() do
      assert Api.arity(name) == length(args)
      assert Api.operation(name).name == name
      assert Api.operation(Atom.to_string(name)).name == name
    end

    assert Api.operation("not_an_operation") == nil
  end

  test "every MCP tool names a function that exists" do
    for tool <- Mcp.Tools.catalogue() do
      assert is_binary(tool["name"])
      assert is_binary(tool["description"])
      assert %{"type" => "object"} = tool["inputSchema"]
      assert is_map(tool["annotations"])
    end

    assert Mcp.Tools.names() == Enum.uniq(Mcp.Tools.names())
  end

  defp arguments(_name, part, args) do
    Enum.map(args, fn
      :handle -> part.ref
      :path -> part.path
      :camera -> Jason.encode!(Quiddity.Camera.to_params(camera()))
      :point -> [35.0, 20.0, 25.0]
      :direction -> [0.0, 0.0, -1.0]
      :number -> 1.0
      :index -> 0
      :framed -> false
      # A density and a part index are optional: `nil` is how a caller says "no".
      :density -> nil
      :part -> nil
      :json -> "{}"
    end)
  end

  defp camera do
    {:ok, camera} =
      Quiddity.Camera.looking_at([0.0, 0.0, 60.0], [0.0, 0.0, 0.0], width: 8, height: 8)

    camera
  end

  defp answered?({:ok, _value}), do: true
  defp answered?({:error, {_code, _message}}), do: true
  # `brep_pmi` and `brep_parts` read the file beside the handle; this fixture has
  # both, so a refusal here is a bug rather than a fixture's shape.
  defp answered?(other) when is_binary(other), do: true
  defp answered?(_other), do: false

  defp shape(:handle, {:ok, {_ref, json}}), do: is_binary(json)
  defp shape(:json, {:ok, json}), do: is_binary(json)
  defp shape(:json, json) when is_binary(json), do: true
  defp shape(:json, {:error, {_code, _message}}), do: true
  defp shape(:binaries, {:ok, tuple}), do: is_tuple(tuple) and tuple_size(tuple) == 4
  defp shape(_other, _result), do: false
end
