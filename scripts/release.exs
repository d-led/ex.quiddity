# The version of the published package, bumped in one place and written into
# everything that carries it.
#
#   elixir scripts/release.exs bump patch    # 0.1.2 -> 0.1.3
#   elixir scripts/release.exs bump minor
#   elixir scripts/release.exs bump major
#   elixir scripts/release.exs check         # exit 1 when they disagree
#
# `VERSION` is the source: a `mix.exs` is read only to check that nothing
# drifted. `check` runs in CI and before a tag, because a version edited in one
# file by hand survives until the tag — and then the tag is refused, or worse, a
# number nobody reviewed is what Hex shows.
#
# Tagging is a separate step (`scripts/tag_and_push_version.sh`) and publishes
# nothing by itself: `.github/workflows/release.yml` publishes from the tag, and
# only after the commit's CI is green.
defmodule Release do
  @version_file "VERSION"

  # Every file that states the version. The package's `mix.exs` is the one Hex
  # will show.
  @mix_files ["mix.exs"]

  @readme "README.md"
  @package "ex_quiddity"

  def main(["bump", kind]) do
    current = current_version()
    next = bump(kind, current)

    File.write!(@version_file, next <> "\n")
    Enum.each(@mix_files, &rewrite!(&1, next))
    pinned = pin(@readme, next)

    IO.puts("#{current} -> #{next}")
    IO.puts("Updated #{@version_file}, #{length(@mix_files)} mix.exs file(s)#{pinned}")

    # The bump is only done when the tree agrees with itself: a file the pattern
    # did not reach would leave the same drift the bump exists to prevent.
    main(["check"])

    IO.puts("\nNext: review the diff, commit, push, wait for CI to be green, then")
    IO.puts("./scripts/tag_and_push_version.sh")
  end

  def main(["check"]) do
    versions = [{"VERSION", current_version()} | Enum.map(@mix_files, &{&1, mix_version(&1)})]

    case Enum.uniq_by(versions, &elem(&1, 1)) do
      [_one] ->
        IO.puts("Everything is at #{current_version()}")

      _disagreement ->
        Enum.each(versions, fn {name, version} -> IO.puts("  #{name}: #{version}") end)
        Mix.raise("Versions disagree; run `elixir scripts/release.exs bump patch`")
    end
  end

  def main(_) do
    Mix.raise("Usage: elixir scripts/release.exs bump {major|minor|patch} | check")
  end

  defp bump("major", version), do: version |> parts() |> then(fn [m, _, _] -> "#{m + 1}.0.0" end)

  defp bump("minor", version),
    do: version |> parts() |> then(fn [m, n, _] -> "#{m}.#{n + 1}.0" end)

  defp bump("patch", version),
    do: version |> parts() |> then(fn [m, n, p] -> "#{m}.#{n}.#{p + 1}" end)

  defp bump(kind, _version),
    do: Mix.raise("Unknown bump #{inspect(kind)}; use major, minor or patch")

  defp parts(version) do
    case String.split(version, ".") do
      [major, minor, patch] ->
        [String.to_integer(major), String.to_integer(minor), String.to_integer(patch)]

      _not_a_release ->
        Mix.raise("Cannot parse version #{version}")
    end
  end

  defp current_version do
    @version_file |> File.read!() |> String.trim()
  end

  defp mix_version(path) do
    case Regex.run(~r/@version "([^"]+)"/, File.read!(path)) do
      [_, version] -> version
      nil -> Mix.raise("No @version in #{path}")
    end
  end

  # What a file states, or the same contents back when it already states the
  # version being written. A file with no `@version` at all is a broken file and
  # says so: that is the one case where "nothing to change" means the wrong
  # thing.
  defp rewrite!(path, version) do
    contents = File.read!(path)

    unless Regex.match?(~r/@version "[^"]+"/, contents) do
      Mix.raise("No @version in #{path}")
    end

    next = Regex.replace(~r/@version "[^"]+"/, contents, ~s(@version "#{version}"))
    if next != contents, do: File.write!(path, next)
  end

  # The README's dependency line is what a reader copies, so it is pinned to the
  # version being released rather than left at whatever it said.
  defp pin(path, version) do
    pattern = ~r/\{:#{@package}, "~> [^"]+"\}/
    contents = File.read!(path)

    if Regex.match?(pattern, contents) do
      File.write!(path, Regex.replace(pattern, contents, ~s({:#{@package}, "~> #{version}"})))
      " and the README's dependency line"
    else
      ""
    end
  end
end

Release.main(System.argv())
