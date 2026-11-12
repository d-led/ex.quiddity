defmodule Quiddity.McpTest do
  @moduledoc """
  The protocol, and what each tool answers. The server is driven through
  `handle/2`, which is one message in and one out — the transport is a pipe.
  """

  use ExUnit.Case, async: true

  alias Quiddity.Mcp

  @fixture "test/fixtures/golden_simple_through_hole.step"
  @boss_top [15.0, 0.0, 23.0]

  test "initialize answers a protocol revision, capabilities and instructions" do
    {reply, state} = call("initialize", %{"protocolVersion" => "2025-06-18"})

    assert %{"jsonrpc" => "2.0", "id" => 1} = reply
    assert reply["result"]["protocolVersion"] == "2025-06-18"
    assert reply["result"]["capabilities"]["tools"]
    assert reply["result"]["serverInfo"]["name"] == "ex-quiddity"
    assert reply["result"]["instructions"] =~ "quiddity_features"
    assert state == %{parts: %{}}
  end

  test "initialize answers the newest revision this server speaks to an older client" do
    {reply, _state} = call("initialize", %{"protocolVersion" => "1999-01-01"})

    assert reply["result"]["protocolVersion"] == hd(Mcp.protocol_versions())
  end

  test "tools/list names every tool, each with a schema and annotations" do
    {reply, _state} = call("tools/list", %{})

    tools = reply["result"]["tools"]
    assert length(tools) == length(Mcp.Tools.names())
    assert Enum.map(tools, & &1["name"]) == Mcp.Tools.names()
    assert Enum.all?(tools, &(&1["inputSchema"]["type"] == "object"))
  end

  test "a notification is answered with nothing" do
    assert {nil, _state} =
             Mcp.handle(~s({"jsonrpc":"2.0","method":"notifications/initialized"}), %{parts: %{}})
  end

  test "an unknown method is a JSON-RPC error, not a crash" do
    {reply, _state} = call("no/such/method", %{})

    assert reply["error"]["code"] == -32_601
    assert reply["error"]["message"] =~ "no/such/method"
  end

  test "a line that is not JSON is a parse error" do
    assert {reply, _state} = Mcp.handle("not json at all", %{parts: %{}})
    assert Jason.decode!(reply)["error"]["code"] == -32_700
  end

  describe "quiddity_part" do
    test "says what the file holds, and remembers the part" do
      {reply, state} = tool("quiddity_part", %{"path" => @fixture})

      text = text_of(reply)
      assert text =~ "9 faces"
      assert text =~ "60.000" and text =~ "50.000" and text =~ "18.000"
      assert reply["result"]["isError"] == false
      assert reply["result"]["structuredContent"]["faces"] == 9
      assert Map.has_key?(state.parts, @fixture)
    end

    test "a file that is not there is an error a model can read" do
      {reply, _state} = tool("quiddity_part", %{"path" => "no/such/part.step"})

      assert reply["result"]["isError"] == true
      assert text_of(reply) =~ "unreadable"
    end
  end

  describe "quiddity_features" do
    test "names the hole and the boss, with their measured sizes" do
      {reply, _state} = tool("quiddity_features", %{"path" => @fixture})

      text = text_of(reply)
      assert text =~ "holes/0"
      assert text =~ "bosses/0"
      assert text =~ "diameter 8.000"
      assert text =~ "diameter 16.000"
    end

    test "narrows to one family when asked" do
      {reply, _state} = tool("quiddity_features", %{"path" => @fixture, "family" => "holes"})

      assert reply["result"]["structuredContent"]["records"] |> length() == 1
      assert text_of(reply) =~ "holes/0"
      refute text_of(reply) =~ "bosses/0"
    end
  end

  describe "quiddity_face" do
    test "describes a face and says whose it is" do
      {reply, _state} = tool("quiddity_face", %{"path" => @fixture, "face" => 6})

      text = text_of(reply)
      assert text =~ "cylinder"
      assert text =~ "radius 4.000 mm"
      assert text =~ "holes/0"
      assert reply["result"]["structuredContent"]["family"] == "holes"
    end

    test "a face the part does not have is an error, with the range in it" do
      {reply, _state} = tool("quiddity_face", %{"path" => @fixture, "face" => 99})

      assert reply["result"]["isError"] == true
      assert text_of(reply) =~ "0 to 8"
    end
  end

  describe "quiddity_probe" do
    test "a ray says what it meets, and where" do
      {reply, _state} =
        tool("quiddity_probe", %{
          "path" => @fixture,
          "point" => @boss_top,
          "direction" => [0.0, 0.0, -1.0]
        })

      text = text_of(reply)
      assert text =~ "meets the part"
      assert text =~ "10.000 mm in"
      assert text =~ "face 8"
    end

    test "without a direction it names the nearest faces" do
      {reply, _state} = tool("quiddity_probe", %{"path" => @fixture, "point" => @boss_top})

      text = text_of(reply)
      assert text =~ "The faces nearest"
      assert text =~ "10.000 mm away"
    end
  end

  describe "quiddity_sense" do
    test "a sensor on the boss sees the boss" do
      {reply, _state} = tool("quiddity_sense", %{"path" => @fixture, "point" => @boss_top})

      text = text_of(reply)
      assert text =~ "64 × 64 frame"
      assert text =~ "Depth"
      assert reply["result"]["structuredContent"]["coverage"] > 0.9
    end
  end

  describe "quiddity_export_mjcf" do
    @tag :tmp_dir
    test "writes a scene in metres", %{tmp_dir: dir} do
      out = Path.join(dir, "plate.xml")
      {reply, _state} = tool("quiddity_export_mjcf", %{"path" => @fixture, "out" => out})

      assert reply["result"]["isError"] == false, text_of(reply)
      xml = File.read!(out)
      assert xml =~ ~s(<mujoco model="part">)
      assert xml =~ "<mesh name="
    end
  end

  describe "quiddity_correspond" do
    test "compares two revisions of a part" do
      {reply, _state} =
        tool("quiddity_correspond", %{
          "old" => "test/fixtures/blend_r5.step",
          "new" => "test/fixtures/blend_r5_enlarged.step"
        })

      assert reply["result"]["isError"] == false, text_of(reply)
      assert text_of(reply) =~ "feature(s) compared"
    end
  end

  test "an unknown tool is an error naming the ones that exist" do
    {reply, _state} = tool("quiddity_nonsense", %{})

    assert reply["result"]["isError"] == true
    assert text_of(reply) =~ "quiddity_part"
  end

  test "a tool called without its required arguments says which" do
    {reply, _state} = tool("quiddity_face", %{"path" => @fixture})

    assert reply["result"]["isError"] == true
    assert text_of(reply) =~ "path, face"
  end

  defp call(method, params) do
    line = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
    {reply, state} = Mcp.handle(line, %{parts: %{}})
    {Jason.decode!(reply), state}
  end

  defp tool(name, arguments) do
    call("tools/call", %{"name" => name, "arguments" => arguments})
  end

  defp text_of(reply), do: reply["result"]["content"] |> hd() |> Map.fetch!("text")
end
