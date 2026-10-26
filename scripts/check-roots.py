#!/usr/bin/env python3
import subprocess
import sys

listed = {line.strip() for line in open(sys.argv[1]) if line.strip() and not line.lstrip().startswith("#")}
tracked = subprocess.check_output(["git", "ls-files", "-z"]).decode().split("\0")
actual = {path.rsplit("/", 1)[0] if "/" in path else "." for path in tracked
          if path.rsplit("/", 1)[-1] in ("kustomization.yaml", "kustomization.yml", "Kustomization")}
if listed != actual:
    raise SystemExit(f"[roots] registry mismatch; missing={sorted(actual-listed)} unregistered={sorted(listed-actual)}")
