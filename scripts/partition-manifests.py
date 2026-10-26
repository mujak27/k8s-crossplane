#!/usr/bin/env python3
"""Route exact XR GVKs; all other YAML documents stay in kubeconform input."""
import csv
import sys
import yaml

mapping = {}
with open(sys.argv[1], newline="") as stream:
    for row in csv.reader((line for line in stream if not line.startswith("#")), delimiter="|"):
        if len(row) != 7:
            raise SystemExit(f"[partition] malformed mapping row: {row}")
        api, kind, source, pin, xrd, witness, ref = row
        key = (api, kind)
        if key in mapping:
            raise SystemExit(f"[partition] duplicate XR mapping: {key}")
        mapping[key] = source

general, excluded = [], []
with open(sys.argv[2]) as stream:
    try:
        for doc in yaml.safe_load_all(stream):
            if doc is None:
                continue
            if not isinstance(doc, dict):
                raise SystemExit("[partition] rendered YAML contains a non-mapping document")
            if "apiVersion" not in doc and "kind" not in doc:
                continue
            if not doc.get("apiVersion") or not doc.get("kind"):
                raise SystemExit(f"[partition] malformed API document missing apiVersion/kind: {doc}")
            key = (doc["apiVersion"], doc.get("kind"))
            if key in mapping:
                excluded.append((key, doc))
            else:
                general.append(doc)
    except yaml.YAMLError as exc:
        raise SystemExit(f"[partition] rendered YAML is invalid: {exc}")
with open(sys.argv[3], "w") as out:
    yaml.safe_dump_all(general, out, explicit_start=True, sort_keys=False)
with open(sys.argv[4], "w") as out:
    for (api, kind), doc in excluded:
        out.write(f"{api}\t{kind}\t{doc.get('metadata', {}).get('name', '')}\n")
with open(sys.argv[5], "w") as out:
    yaml.safe_dump_all([doc for _, doc in excluded], out, explicit_start=True, sort_keys=False)
print(f"[partition] general={len(general)} excluded-XR={len(excluded)}")
