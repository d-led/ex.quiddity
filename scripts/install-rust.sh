#!/usr/bin/env bash
# Installs a Rust toolchain unless one is already on PATH.
#
# The engine under `native/brep_nif` is compiled when this package is, so a
# machine without `cargo` cannot build it — and the failure it gives then
# ("Could not cd to native/brep_nif") names a directory rather than the missing
# tool. This script is what CI and a fresh laptop run first.
#
# Idempotent: a `cargo` on PATH means it does nothing and says nothing. Rustup
# only edits shell profiles, and a CI step is a non-interactive shell, so the
# binary is probed where rustup puts it and printed for the caller to prepend.

set -euo pipefail

if command -v cargo >/dev/null 2>&1; then
  exit 0
fi

echo "installing Rust with rustup..." >&2

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
  sh -s -- -y --profile minimal --default-toolchain stable >&2

for candidate in "${CARGO_HOME:-$HOME/.cargo}/bin" /usr/local/cargo/bin; do
  if [ -x "$candidate/cargo" ]; then
    echo "$candidate"
    exit 0
  fi
done

echo "rustup finished but no cargo was found; add it to PATH by hand" >&2
exit 1
