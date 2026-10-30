#!/usr/bin/env python3
import subprocess
import sys
import re

entries = [line.strip() for line in open(sys.argv[1]) if line.strip() and not line.lstrip().startswith("#")]
listed = {entry.removeprefix("empty ") for entry in entries if not entry.startswith("https://")}
remote = [entry for entry in entries if entry.startswith("https://")]
tracked = subprocess.check_output(["git", "ls-files", "-z"]).decode().split("\0")
actual = {path.rsplit("/", 1)[0] if "/" in path else "." for path in tracked
          if path.rsplit("/", 1)[-1] in ("kustomization.yaml", "kustomization.yml", "Kustomization")}
if listed != actual:
    raise SystemExit(f"[roots] registry mismatch; missing={sorted(actual-listed)} unregistered={sorted(listed-actual)}")
sources = []
for line in open("validation/xr-sources.tsv"):
    fields = line.strip().split("|")
    if len(fields) == 8 and not fields[0].startswith("#"):
        sources.append((fields[7], fields[3], fields[4]))
for url in remote:
    match = re.fullmatch(r"https://raw\.githubusercontent\.com/([^/]+/[^/]+)/([0-9a-f]{40})/(.+\.yaml)", url)
    if not match or not any(repo == match.group(1) and pin == match.group(2) and xrd.rsplit("/", 1)[0] == match.group(3).rsplit("/", 1)[0] for repo, pin, xrd in sources):
        raise SystemExit(f"[roots] remote root must be a public full-SHA URL aligned with its XR source: {url}")
