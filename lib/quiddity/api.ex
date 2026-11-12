defmodule Quiddity.Api do
  @moduledoc """
  The engine's operations, as data — and the stubs generated from it.

  Quiddity's Rust surface is a fixed list of functions, and a hand-written Elixir
  stub for each is a place for the two to drift: a Rust operation nobody can call,
  an Elixir function that raises `:nif_not_loaded` because the name moved. So the
  list is written once here, and `Quiddity.Native` is generated from it at compile
  time — the same shape as the Elixir libraries that generate a function per
  Unicode property from a table (`:unicode_set`, `:tz`) rather than typing it out.

  Two things come out of one table:

    * the stub of every operation (`define_stubs/0`), at the arity the Rust
      function has — a NIF whose arity disagrees with its stub is a call that can
      never succeed, and now cannot be *written*;
    * `operations/0`, which a test walks to prove every listed operation is
      loaded and answers, and which `Quiddity.Mcp` reads so a tool cannot name an
      operation the engine does not have.

  What is *not* generated is the typed, documented wrapper in `Quiddity`: an
  answer's shape is a fact about the operation (a handle, a JSON document, four
  flat binaries) and a caller deserves that in the signature rather than in a
  match.
  """

  @typedoc "What an argument is, as far as a stub is concerned."
  @type arg ::
          :path
          | :handle
          | :camera
          | :json
          | :point
          | :direction
          | :number
          | :index
          | :framed
          | :density
          | :part

  @typedoc """
  What an operation answers.

    * `:handle` — `{handle, summary_json}`, a part opened;
    * `:json` — a JSON string;
    * `:binaries` — flat binaries plus a JSON note (`frame`, `mesh`, `samples`).
  """
  @type answer :: :handle | :json | :binaries

  @type operation :: %{
          name: atom(),
          args: [arg()],
          answer: answer(),
          summary: String.t()
        }

  @operations [
    %{
      name: :brep_open,
      args: [:path],
      answer: :handle,
      summary: "read a STEP file into a handle, with a summary of what it holds"
    },
    %{
      name: :brep_recognise,
      args: [:handle],
      answer: :json,
      summary: "the recognition document: features, face accounting, source hash"
    },
    %{
      name: :brep_frame,
      args: [:handle, :camera],
      answer: :binaries,
      summary: "one camera frame: a point, a normal, a face and a depth per pixel"
    },
    %{
      name: :brep_mesh,
      args: [:handle, :number, :number],
      answer: :binaries,
      summary: "the part as triangles, each naming the B-rep face it came from"
    },
    %{
      name: :brep_samples,
      args: [:handle, :number, :index],
      answer: :binaries,
      summary: "points over the surface, `spacing` mm apart, with normals and faces"
    },
    %{
      name: :brep_face,
      args: [:handle, :index],
      answer: :json,
      summary: "one face: its surface, area, centroid, normal and neighbours"
    },
    %{
      name: :brep_ray,
      args: [:handle, :point, :direction, :number, :index],
      answer: :json,
      summary: "where a ray meets the part, nearest first"
    },
    %{
      name: :brep_nearest,
      args: [:handle, :point, :index],
      answer: :json,
      summary: "the faces nearest a point, closest first"
    },
    %{
      name: :brep_capabilities,
      args: [],
      answer: :json,
      summary: "what this build of quiddity can do, versioned"
    },
    %{
      name: :brep_evidence,
      args: [:handle, :framed],
      answer: :json,
      summary: "the evidence each feature rests on, and what was refused"
    },
    %{
      name: :brep_fingerprints,
      args: [:handle],
      answer: :json,
      summary: "the revision-independent identity of each feature"
    },
    %{
      name: :brep_correspond,
      args: [:path, :path],
      answer: :json,
      summary: "what happened to each feature between two revisions"
    },
    %{
      name: :brep_mass,
      args: [:handle, :density],
      answer: :json,
      summary: "volume, area, centroid and (at a density) mass of every solid"
    },
    %{
      name: :brep_classify,
      args: [:handle, :point],
      answer: :json,
      summary: "whether a point is inside the material, outside it, or on a face"
    },
    %{
      name: :brep_parts,
      args: [:handle],
      answer: :json,
      summary: "the distinct parts of an assembly, with their placements"
    },
    %{
      name: :brep_pmi,
      args: [:handle, :part],
      answer: :json,
      summary: "the file's semantic PMI: dimensions, tolerances, datums, notes"
    }
  ]

  @doc "Every operation this build wraps, in the order the docs read them."
  @spec operations() :: [operation()]
  def operations, do: @operations

  @doc "One operation by name, or `nil`."
  @spec operation(atom() | String.t()) :: operation() | nil
  def operation(name) do
    name = if is_binary(name), do: safe_atom(name), else: name
    Enum.find(@operations, &(&1.name == name))
  end

  @doc "The arity an operation's stub has."
  @spec arity(atom()) :: non_neg_integer() | nil
  def arity(name) do
    case operation(name) do
      nil -> nil
      %{args: args} -> length(args)
    end
  end

  @doc """
  Generates `Quiddity.Native`'s stubs: one function per operation, at the arity
  the operation declares.

  A stub that is never replaced by a NIF call raises `:nif_not_loaded`, which is
  how Rustler says "this function is not here" — so the generated function is a
  real stub, not a placeholder.
  """
  defmacro define_stubs do
    stubs =
      for %{name: name, args: args} <- @operations do
        parameters = for index <- 1..length(args)//1, do: Macro.var(:"arg#{index}", __MODULE__)

        quote do
          @doc false
          def unquote(name)(unquote_splicing(parameters)),
            do: :erlang.nif_error(:nif_not_loaded)
        end
      end

    # A block of every stub, built as AST rather than spliced into a
    # parenthesised expression: a `(...)` holding several definitions parses as a
    # call, and the definitions then land in the wrong place.
    {:__block__, [], stubs}
  end

  # A name that is not a known operation is answered `nil` rather than creating an
  # atom: this runs on names a caller supplied.
  defp safe_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end
end
