#!/usr/bin/bash
set -euo pipefail
IFS=$'\n\t'

# micros-version-check.bash: Verify every declared MicrOS version site agrees with
# src/version.zig. Run by `make check` so a release can never ship banners, docs, and
# the changelog that disagree (v0.15.0 banners once coexisted with a 0.1.0-dev kernel
# and a 0.1.0 Sphinx release).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

readonly VersionSource="src/version.zig"


version="$(sed -n 's/^pub const version = "\([0-9]\+\.[0-9]\+\.[0-9]\+\)";$/\1/p' "$VersionSource" | head -n1)"
if [[ -z "$version" ]]; then
    printf 'ERROR: %s does not declare pub const version = X.Y.Z\n' "$VersionSource" >&2
    exit 1
fi

failures=0
expected=(
    "lib/macros/init.mx:uOS ${version}"
    "lib/macros/ush.mx:µShell ${version}"
    "docs/conf.py:release = '${version}'"
    "README.rst:${version}"
    "CHANGELOG.rst:[${version}]"
)

for site in "${expected[@]}"; do
    file="${site%%:*}"
    needle="${site#*:}"
    if [[ ! -f "$file" ]]; then
        printf 'ERROR: version site missing: %s\n' "$file" >&2
        failures=$((failures + 1))
        continue
    fi
    if ! grep -Fq -- "$needle" "$file"; then
        printf 'ERROR: %s does not declare "%s" (expected from %s)\n' "$file" "$needle" "$VersionSource" >&2
        failures=$((failures + 1))
    fi
done

# The kernel banner must interpolate the constant rather than repeat a literal.
if grep -Eq 'uOS [0-9]+\.[0-9]+\.[0-9]+' src/kernel/main.zig; then
    printf 'ERROR: src/kernel/main.zig hardcodes a version literal; interpolate %s instead\n' "$VersionSource" >&2
    failures=$((failures + 1))
fi

if [[ "$failures" -gt 0 ]]; then
    printf '\n[version-check] FAIL: %d version site(s) out of sync with %s\n' "$failures" "$version" >&2
    exit 1
fi

printf '[version-check] PASS: all version sites agree on %s\n' "$version"
