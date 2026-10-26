#!/bin/sh
set -eu
repo=$(git rev-parse --show-toplevel)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/validation-seam.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
git clone --quiet --local "$repo" "$tmp/repo"
cd "$tmp/repo"
sed -i '' '/^crossplane\/01-tls-ingress\/compositions$/d' validation/roots.txt
if PATH="${PATH}" scripts/validate.sh >"$tmp/output" 2>&1; then
  echo '[test] validation unexpectedly accepted an unregistered root' >&2
  exit 1
fi
grep -F '[roots] registry mismatch' "$tmp/output" >/dev/null || { cat "$tmp/output" >&2; exit 1; }
echo '[test] validation rejects an unregistered root'
