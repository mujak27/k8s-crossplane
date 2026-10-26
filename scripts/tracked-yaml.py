#!/usr/bin/env python3
import os

import subprocess
import sys

paths = subprocess.check_output(["git", "ls-files", "-z", "--", "*.yaml", "*.yml"]).decode().split("\0")
lint_only = {".yamllint.yaml"}
for path in filter(None, paths):
    if path in lint_only or path.startswith(".github/workflows/") or path.rsplit("/", 1)[-1] in ("kustomization.yaml", "kustomization.yml", "Kustomization"):
        continue
    if os.path.islink(path):
        raise SystemExit(f"[tracked-yaml] refusing tracked symlink: {path}")
    with open(path, "rb") as stream:
        sys.stdout.buffer.write(b"---\n" + stream.read() + b"\n")
