#!/usr/bin/env python3
import csv
import sys
import yaml

sources = {}
with open(sys.argv[1], newline="") as stream:
    for api, kind, source, *_ in csv.reader((line for line in stream if not line.startswith("#")), delimiter="|"):
        with open(source) as docs:
            for doc in yaml.safe_load_all(docs):
                if isinstance(doc, dict) and doc.get("apiVersion") == api and doc.get("kind") == kind:
                    metadata = doc.get("metadata", {})
                    key = (api, kind, metadata.get("namespace", ""), metadata.get("name", ""))
                    if key in sources:
                        raise SystemExit(f"[coverage] duplicate mapped source identity: {key}")
                    sources[key] = (source, doc)
seen = set()
with open(sys.argv[3]) as stream:
    for doc in yaml.safe_load_all(stream):
        metadata = doc.get("metadata", {})
        key = (doc.get("apiVersion"), doc.get("kind"), metadata.get("namespace", ""), metadata.get("name", ""))
        if key not in sources:
            raise SystemExit(f"[coverage] rendered XR has no validated source mapping: {key}")
        _, original = sources[key]
        if doc != original:
            raise SystemExit(f"[coverage] rendered XR differs from CLI-validated source: {key}")
        seen.add(key)
with open(sys.argv[2]) as stream:
    expected = {tuple(line.rstrip("\n").split("\t", 3)) for line in stream}
if seen != expected:
    raise SystemExit("[coverage] XR listing and rendered payloads disagree")
if not seen:
    raise SystemExit("[coverage] expected mapped XR documents, found none")
print(f"[coverage] all {len(seen)} excluded rendered XR document(s) have validated sources")
