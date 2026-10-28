#!/usr/bin/env python3
import sys
import yaml

path, repo, expected, upstream_path = sys.argv[1:]
with open(path) as stream:
    docs = yaml.safe_load_all(stream)
    for doc in docs:
        if not isinstance(doc, dict):
            continue
        def matches(value):
            if isinstance(value, dict):
                if value.get("targetRevision") == expected and value.get("repoURL") == "https://github.com/" + repo:
                    return True
                if value.get("repoURL") == "https://github.com/" + repo and upstream_path in value.get("kustomize", {}).get("remoteBases", []):
                    return True
                if any(isinstance(entry, str) and entry.startswith("https://github.com/" + repo + "//" + upstream_path.rsplit("/", 1)[0] + "?") and "ref=" + expected in entry.split("?", 1)[1].split("&") for entry in value.get("resources", [])):
                    return True
                return any(matches(child) for child in value.values())
            if isinstance(value, list):
                return any(matches(child) for child in value)
            return False
        if matches(doc):
            raise SystemExit(0)
raise SystemExit(1)
