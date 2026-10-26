#!/usr/bin/env python3
import subprocess
import sys

paths = subprocess.check_output(["git", "ls-files", "-z", "--", "*.yaml", "*.yml"]).decode().split("\0")
for path in filter(None, paths):
    with open(path, "rb") as stream:
        sys.stdout.buffer.write(b"---\n" + stream.read() + b"\n")
