#!/bin/sh
set -eu
repo=$(git rev-parse --show-toplevel)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/validation-seam.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
git clone --quiet --local "$repo" "$tmp/repo"
cd "$tmp/repo"
awk '$0 != "crossplane/_shared"' validation/roots.txt > "$tmp/roots.txt"
mv "$tmp/roots.txt" validation/roots.txt
if PATH="${PATH}" scripts/validate.sh >"$tmp/output" 2>&1; then
  echo '[test] validation unexpectedly accepted an unregistered root' >&2
  exit 1
fi
grep -F '[roots] registry mismatch' "$tmp/output" >/dev/null || { cat "$tmp/output" >&2; exit 1; }
echo '[test] validation rejects an unregistered root'
