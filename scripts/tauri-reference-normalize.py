#!/usr/bin/env python3
"""Merges the logs of scripts/tauri-ios-reference.sh into <out>/calls.json.

Usage: tauri-reference-normalize.py <out-dir>
Reads <out>/cargo.jsonl, xcrun.jsonl, swift.jsonl, link.txt, linkfiles.txt, compile.json and <out>/prefixes.json ([["$VAR", "/abs/prefix"], …]),
rewrites every absolute prefix to its variable (longest prefix first) and writes <out>/calls.json:
  cargo       every cargo invocation, in order: {"cwd", "argv", "env"}
  xcrun       distinct xcrun argvs, in first-seen order
  swiftBuild  every `swift build` invocation, in order: {"cwd", "argv"}
  swift       distinct other swift argvs (e.g. -print-target-info), in first-seen order
  link        the final clang link command line for the app executable, from the Xcode build log
  linkFiles   the object files in that link's -filelist
  compile     the app target's clang compile lines: [{"source", "command", "responseFile", "responseArgs"}]
"""
import json
import os
import sys

out = sys.argv[1]
prefixes = json.load(open(os.path.join(out, "prefixes.json")))
pairs = sorted(((p, v) for v, p in prefixes if p), key=lambda pv: -len(pv[0]))


def norm(x):
    if isinstance(x, str):
        for p, v in pairs:
            x = x.replace(p, v)
        return x
    if isinstance(x, list):
        return [norm(i) for i in x]
    if isinstance(x, dict):
        return {k: norm(v) for k, v in x.items()}
    return x


def lines(name):
    path = os.path.join(out, name)
    if not os.path.exists(path):
        return []
    return [json.loads(l) for l in open(path) if l.strip()]


def read_lines(name):
    path = os.path.join(out, name)
    return [l for l in open(path).read().splitlines() if l.strip()] if os.path.exists(path) else []


def distinct(items):
    seen, res = set(), []
    for i in items:
        k = json.dumps(i)
        if k not in seen:
            seen.add(k)
            res.append(i)
    return res


swift = [norm(e) for e in lines("swift.jsonl")]
link_path = os.path.join(out, "link.txt")
calls = {
    "cargo": [norm(e) for e in lines("cargo.jsonl")],
    "xcrun": distinct([norm(e["argv"]) for e in lines("xcrun.jsonl")]),
    "swiftBuild": [e for e in swift if e["argv"][:1] == ["build"]],
    "swift": distinct([e["argv"] for e in swift if e["argv"][:1] != ["build"]]),
    "link": norm(open(link_path).read().strip()) if os.path.exists(link_path) else "",
    "linkFiles": norm(read_lines("linkfiles.txt")),
    "compile": norm(json.load(open(os.path.join(out, "compile.json")))) if os.path.exists(os.path.join(out, "compile.json")) else [],
}
with open(os.path.join(out, "calls.json"), "w") as f:
    json.dump(calls, f, indent=2, sort_keys=True)
    f.write("\n")
