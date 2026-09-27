#!/usr/bin/env bash
# Runs the luau unit tests. Usage: tools/test.sh [name-filter]
# Noctalia needs `require("./x.luau")`, the standalone luau CLI needs
# `require("./x")`, so the tests run against a copy with the suffix removed.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
luau="${LUAU:-$root/.tools/bin/luau}"
command -v "$luau" >/dev/null 2>&1 || luau="luau"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -r "$root/tests" "$root/pixel-shift" "$tmp/"
find "$tmp/pixel-shift" -name '*.luau' -exec sed -i -E 's/require\("([^"]+)\.luau"\)/require("\1")/g' {} +
cd "$tmp"
exec "$luau" -O2 tests/run.luau -a "${1:-}"
