defmodule Quiddity.Mcp do
  @moduledoc """
  A Model Context Protocol server over stdio: a STEP part, for an assistant.

  One JSON-RPC message per line in, one out — the stdio transport, which is what
  a client launches as a process. No sessions, no server-sent events, no batches:
  every request is self-contained, which is what lets a client treat it as a
  pipe.

  ## What the tools are for

  quiddity answers "what is this part?" and this server exposes that, plus the
  geometry underneath it. The questions worth asking are different enough to be
  separate tools:

    * **what is it?** — `quiddity_part`, `quiddity_features`, `quiddity_face`;
    * **what is here?** — `quiddity_probe` and `quiddity_sense`: a ray, a point,
      and a camera frame rendered against the exact B-rep;
    * **how do two parts differ?** — `quiddity_correspond` matches the features
      of one part against another's by name and size.

  `quiddity_export_mjcf` is the one tool that writes: it puts the part on disk as
  a MuJoCo model.

  ## Parts are opened once

  Calls name a path; the server keeps the parsed part, so a second question about
  the same file does not re-read it. The cache is this process's — restarting the
  server costs a re-read, and nothing on disk depends on it.

  A tool that cannot answer answers: a refusal is text saying what was wrong and
  what to try, never a dropped connection.
  """

  alias Quiddity.{Error, Part}
  alias Quiddity.Mcp.Tools

  @protocol_versions ~w(2025-06-18 2025-03-26 2024-11-05)

  @typedoc "What the server remembers between messages: the parts it has read."
  @type state :: %{parts: %{optional(String.t()) => Part.t()}}

  @doc "The protocol revisions this server speaks, newest first."
  @spec protocol_versions() :: [String.t()]
  def protocol_versions, do: @protocol_versions

  @doc """
  Reads JSON-RPC messages from stdin and writes answers to stdout until stdin
  closes.

  Notifications are answered with nothing, which is what the transport says: a
  `notifications/initialized` gets no reply.
  """
  @spec serve() :: :ok
  def serve do
    state = %{parts: %{}}

    _ =
      IO.stream(:stdio, :line)
      |> Enum.reduce(state, fn line, state ->
        {reply, state} = handle(String.trim_trailing(line), state)
        if reply, do: IO.puts(reply)
        state
      end)

    :ok
  end

  @doc """
  One message: the reply (or `nil` for a notification) and the state after it.

  `nil` for a blank line, and for a line that is not JSON — a transport that
  crashes on garbage is a transport nobody can debug.
  """
  @spec handle(String.t(), state()) :: {String.t() | nil, state()}
  def handle(line, state) when line in ["", " ", nil], do: {nil, state}

  def handle(line, state) do
    case Jason.decode(line) do
      {:ok, message} when is_map(message) -> dispatch(message, state)
      {:ok, _not_an_object} -> {error_reply(nil, -32_600, "not a JSON-RPC object"), state}
      {:error, _reason} -> {error_reply(nil, -32_700, "the line is not JSON"), state}
    end
  end

  defp dispatch(%{"method" => method, "id" => id} = message, state) when is_binary(method) do
    case result(method, Map.get(message, "params", %{}), state) do
      {:ok, result, state} -> {reply(id, result), state}
      {:error, message} -> {error_reply(id, -32_601, message), state}
    end
  end

  defp dispatch(%{"method" => method} = message, state) when is_binary(method) do
    # A notification: do the work, answer nothing.
    _ = result(method, Map.get(message, "params", %{}), state)
    {nil, state}
  end

  defp dispatch(_message, state) do
    {error_reply(nil, -32_600, "no method"), state}
  end

  defp result("initialize", params, state) do
    {:ok,
     %{
       "protocolVersion" => negotiate(Map.get(params, "protocolVersion")),
       "capabilities" => %{"tools" => %{"listChanged" => false}},
       "serverInfo" => %{
         "name" => "ex-quiddity",
         "title" => "Manufacturing features of STEP parts",
         "version" => version()
       },
       "instructions" => instructions()
     }, state}
  end

  defp result("tools/list", _params, state), do: {:ok, %{"tools" => Tools.catalogue()}, state}

  defp result("tools/call", params, state) do
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments") || %{}

    case Tools.call(name, arguments, state) do
      {:ok, %{text: text, structured: structured}, state} ->
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => text}],
           "structuredContent" => structured,
           "isError" => false
         }, state}

      {:error, message, state} ->
        {:ok, %{"content" => [%{"type" => "text", "text" => message}], "isError" => true}, state}
    end
  end

  defp result("ping", _params, state), do: {:ok, %{}, state}

  defp result(method, _params, _state), do: {:error, "unknown method: #{method}"}

  defp negotiate(requested) do
    if requested in @protocol_versions, do: requested, else: hd(@protocol_versions)
  end

  defp instructions do
    """
    This server reads STEP parts and answers two kinds of question about them.

    WHAT THE PART IS: quiddity_part opens a file and says what it holds (bodies,
    faces, size, validity); quiddity_features names its manufacturing features —
    holes, pockets, slots, bosses, steps, patterns, fillets, chamfers, grooves,
    sheet-metal and turned features — with measured sizes and positions, and
    accounts for every face; quiddity_face says what one face is and which
    feature owns it.

    WHERE SOMETHING IS: quiddity_probe answers what a ray meets, or which faces
    are nearest a point, in millimetres. quiddity_sense puts a 64 × 64 sensor on
    the part and says what it sees: depth, on-object, the normal and curvature at
    each pixel, and the feature the surface there is on.

    SCENES: quiddity_export_mjcf writes the part as an MJCF model in metres, so
    the same geometry can be simulated.

    Numbers are quiddity's own: a face count, a diameter in millimetres, an
    unexplained face. Where a recognition cannot prove a feature it says so, and
    "unexplained" is an answer, not an absence.
    """
  end

  defp version do
    case Application.spec(:ex_quiddity, :vsn) do
      nil -> "dev"
      version -> to_string(version)
    end
  end

  defp reply(id, result) do
    Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp error_reply(id, code, message) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  @doc false
  # Used by the tools to turn a refusal into text a model can act on.
  @spec describe_error(Error.t()) :: String.t()
  def describe_error(%Error{code: code, message: message}), do: "#{code}: #{message}"
end
