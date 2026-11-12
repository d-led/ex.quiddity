defmodule ExQuiddity.MixProject do
  use Mix.Project

  @version "0.1.2"
  @source_url "https://github.com/d-led/ex.quiddity"

  def project do
    [
      app: :ex_quiddity,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      dialyzer: [plt_add_apps: [:mix, :ex_unit]],

      # Hex.pm: a CAD part you can ask questions about.
      name: "ExQuiddity",
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url,
      test_coverage: [summary: [threshold: 75]]
    ]
  end

  def application do
    # A library, not an application: a host starts what it needs. The only thing
    # this code calls is `Logger`.
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # The NIF crate under `native/brep_nif` is built when this package is:
      # that wants a Rust toolchain at build time, and nothing at run time
      # beyond the `.so` the release carries.
      {:rustler, "~> 0.38", runtime: false},

      # Recognition documents, camera descriptions and scene notes are JSON: the
      # boundary keeps one representation instead of a struct for every shape.
      {:jason, "~> 1.2"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  defp description do
    "An Elixir wrapper of github.com/pzfreo/quiddity to bring feature extraction " <>
      "from CAD, with the geometry underneath it: rays, frames, meshes and surface " <>
      "samples. Wrapped via rustler."
  end

  defp package do
    [
      files: ~w(lib native/brep_nif/src native/brep_nif/Cargo.toml
                native/brep_nif/Cargo.lock native/brep_nif/.cargo docs mix.exs
                README.md CHANGELOG.md LICENSE NOTICE .formatter.exs),
      licenses: ["MPL-2.0"],
      links: %{"GitHub" => @source_url},
      maintainers: ["Dmitry Ledentsov"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "docs/why.md", "docs/roadmap.md"],
      groups_for_modules: [
        Geometry: [Quiddity, Quiddity.Part, Quiddity.Face, Quiddity.Camera, Quiddity.Frame],
        Scenes: [Quiddity.Mjcf],
        "Model Context Protocol": [Quiddity.Mcp]
      ]
    ]
  end
end
