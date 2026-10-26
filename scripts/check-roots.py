#!/usr/bin/env python3
import pathlib
import sys

listed = {line.strip() for line in open(sys.argv[1]) if line.strip() and not line.lstrip().startswith("#")}
actual = set()
for base in ("apps", "bootstrap", "crossplane", "infra"):
    for path in pathlib.Path(base).rglob("*"):
        if path.name in ("kustomization.yaml", "kustomization.yml", "Kustomization"):
            actual.add(str(path.parent))
if listed != actual:
    raise SystemExit(f"[roots] registry mismatch; missing={sorted(actual-listed)} unregistered={sorted(listed-actual)}")
