#!/usr/bin/env python3
import sys
import yaml

path, expected = sys.argv[1:]
with open(path) as stream:
    docs = yaml.safe_load_all(stream)
    for doc in docs:
        if not isinstance(doc, dict):
            continue
        resources = doc.get("resources", [])
        for entry in resources:
            if isinstance(entry, str) and "?ref=" in entry:
                if entry.rsplit("?ref=", 1)[1] == expected:
                    raise SystemExit(0)
        def matches(value):
            if isinstance(value, dict):
                if value.get("targetRevision") == expected and value.get("repoURL") == "https://github.com/mujak27/crossplane-compilations":
                    return True
                return any(matches(child) for child in value.values())
            if isinstance(value, list):
                return any(matches(child) for child in value)
            return False
        if matches(doc):
            raise SystemExit(0)
raise SystemExit(1)
