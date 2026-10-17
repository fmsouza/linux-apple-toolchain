#!/usr/bin/env python3
"""Merges the logs of scripts/tauri-ios-reference.sh into <out>/calls.json.

Usage: tauri-reference-normalize.py <out-dir> [ios|macos]
Reads <out>/prefixes.json ([["$VAR", "/abs/prefix"], …]) and the logs below, rewrites every absolute prefix to its
variable (longest prefix first) and writes <out>/calls.json.

ios (default) reads cargo.jsonl, xcrun.jsonl, swift.jsonl, link.txt, linkfiles.txt, compile.json:
  cargo       every cargo invocation, in order: {"cwd", "argv", "env"}
  xcrun       distinct xcrun argvs, in first-seen order
  swiftBuild  every `swift build` invocation, in order: {"cwd", "argv"}
  swift       distinct other swift argvs (e.g. -print-target-info), in first-seen order
  link        the final clang link command line for the app executable, from the Xcode build log
  linkFiles   the object files in that link's -filelist
  compile     the app target's clang compile lines: [{"source", "command", "responseFile", "responseArgs"}]

macos reads cargo.jsonl, xcrun.jsonl, swift.jsonl, lipo.jsonl, hdiutil.jsonl, codesign.jsonl, SetFile.jsonl,
bless.jsonl and build.log (per-run names are made stable: rw.<pid>.*.dmg, /dev/disk<N>, /Volumes/dmg.<random>):
  frontend    the beforeBuildCommand hook env, from tauri's `-v` log ("Setting environment for hook {…}")
  frontendCommand  the hook command line (the log's "beforeBuildCommand `…`")
  cargo       every `cargo build`, in order: {"target", "cwd", "argv", "env"} (target = the --target value)
  cargoOther  every other cargo invocation (metadata, …), in order: {"cwd", "argv", "env"}
  lipo        every lipo argv, in order
  xcrun       distinct xcrun argvs, in first-seen order
  swift       distinct swift argvs, in first-seen order
  dmgScript   tauri-bundler's bundle_dmg.sh command line (from the `-v` log)
  hdiutil     every hdiutil argv (from bundle_dmg.sh), in order
  SetFile     every SetFile argv (bundle_dmg.sh: volume icon), in order
  bless       every bless argv, in order
  codesign    every codesign argv, in order (an unsigned --no-sign build has none)
"""
import json
import os
import re
import sys

out = sys.argv[1]
platform = sys.argv[2] if len(sys.argv) > 2 else "ios"
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


def stable(x):
    """Per-run names in the DMG script's calls: its rw.<pid>.<name>.dmg temp image, the device and the mount dir."""
    if isinstance(x, list):
        return [stable(i) for i in x]
    x = re.sub(r"/rw\.\d+\.", "/rw.<pid>.", x)
    x = re.sub(r"^/dev/disk\d+", "/dev/disk<N>", x)
    return re.sub(r"/Volumes/dmg\.\w+", "/Volumes/dmg.<random>", x)


def ios():
    swift = [norm(e) for e in lines("swift.jsonl")]
    link_path = os.path.join(out, "link.txt")
    return {
        "cargo": [norm(e) for e in lines("cargo.jsonl")],
        "xcrun": distinct([norm(e["argv"]) for e in lines("xcrun.jsonl")]),
        "swiftBuild": [e for e in swift if e["argv"][:1] == ["build"]],
        "swift": distinct([e["argv"] for e in swift if e["argv"][:1] != ["build"]]),
        "link": norm(open(link_path).read().strip()) if os.path.exists(link_path) else "",
        "linkFiles": norm(read_lines("linkfiles.txt")),
        "compile": norm(json.load(open(os.path.join(out, "compile.json")))) if os.path.exists(os.path.join(out, "compile.json")) else [],
    }


def macos():
    ansi = re.compile(r"\x1b\[[0-9;]*m")
    log = ansi.sub("", open(os.path.join(out, "build.log"), errors="replace").read())
    hooks = [json.loads(m.group(1)) for m in re.finditer(r"Setting environment for hook (\{[^\n]*\})", log)]
    commands = re.findall(r"beforeBuildCommand `([^`]*)`", log)
    dmg_script = re.findall(r"Command `([^`]*/bundle_dmg\.sh [^`]*)`", log)
    if len(distinct(hooks)) > 1:
        sys.exit("tauri-reference-normalize: the beforeBuildCommand hook ran with different envs: %s" % hooks)
    cargo, other = [], []
    for e in lines("cargo.jsonl"):
        e = norm(e)
        argv = e["argv"]
        if argv[:1] == ["build"]:
            target = argv[argv.index("--target") + 1] if "--target" in argv else None
            cargo.append(dict(e, target=target))
        else:
            other.append(e)
    return {
        "frontend": norm(hooks[0]) if hooks else {},
        "frontendCommand": norm(commands[0]) if commands else "",
        "cargo": cargo,
        "cargoOther": other,
        "lipo": [norm(e["argv"]) for e in lines("lipo.jsonl")],
        "xcrun": distinct([norm(e["argv"]) for e in lines("xcrun.jsonl")]),
        "swift": distinct([norm(e["argv"]) for e in lines("swift.jsonl")]),
        "dmgScript": norm(dmg_script[0]) if dmg_script else "",
        "hdiutil": [stable(norm(e["argv"])) for e in lines("hdiutil.jsonl")],
        "SetFile": [stable(norm(e["argv"])) for e in lines("SetFile.jsonl")],
        "bless": [stable(norm(e["argv"])) for e in lines("bless.jsonl")],
        "codesign": [norm(e["argv"]) for e in lines("codesign.jsonl")],
    }


calls = macos() if platform == "macos" else ios()
with open(os.path.join(out, "calls.json"), "w") as f:
    json.dump(calls, f, indent=2, sort_keys=True)
    f.write("\n")
