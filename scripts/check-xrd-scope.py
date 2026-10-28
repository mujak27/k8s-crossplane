#!/usr/bin/env python3
import sys
import yaml

with open(sys.argv[1]) as stream:
    xrd = yaml.safe_load(stream)
spec = xrd.get("spec", {}) if isinstance(xrd, dict) else {}
version = sys.argv[2].split("/", 1)[1]
served = next((item for item in spec.get("versions", []) if item.get("name") == version and item.get("served")), None)
if xrd.get("kind") != "CompositeResourceDefinition" or spec.get("group", "") + "/" + version != sys.argv[2] or served is None or spec.get("names", {}).get("kind") != sys.argv[3]:
    raise SystemExit(f"[crossplane] XRD identity mismatch for {sys.argv[2]} Kind={sys.argv[3]}")
if xrd.get("apiVersion", "").endswith("/v2") and "scope" not in spec:
    raise SystemExit(f"[crossplane] v2 XRD missing spec.scope: {sys.argv[1]}")
if spec.get("scope") != "Namespaced":
    raise SystemExit(f"[crossplane] expected Namespaced scope, got {spec.get('scope')!r}: {sys.argv[1]}")
