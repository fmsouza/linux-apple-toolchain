#!/usr/bin/env python3
"""Normalised summaries for scripts/rn-reference.sh (Mac only; stdlib only).

Writes into --out:
  build-settings.json   selected keys of each target's `xcodebuild -showBuildSettings -json` (Release, iphoneos)
  pif-summary.json      the app project's targets from `xcodebuild -dumpPIF`: name, product type, product, explicit
                        dependencies, build phases (type, name, the product/file names in frameworks and copy-files
                        phases); plus the workspace's projects with their target counts
  reference-appex.json  the `xless tauri report` of each embedded .appex, keyed by bundle name (only if any)
Every string has the --prefix paths (longest first) replaced by their names.
"""
import argparse
import json
import os
import sys

KEYS = [
    "PRODUCT_NAME", "PRODUCT_TYPE", "WRAPPER_EXTENSION", "PRODUCT_BUNDLE_IDENTIFIER", "DEVELOPMENT_TEAM",
    "CODE_SIGN_ENTITLEMENTS", "INFOPLIST_FILE", "IPHONEOS_DEPLOYMENT_TARGET", "TARGETED_DEVICE_FAMILY",
    "SWIFT_VERSION", "SWIFT_OBJC_BRIDGING_HEADER", "APPLICATION_EXTENSION_API_ONLY", "GCC_PREPROCESSOR_DEFINITIONS",
    "OTHER_CFLAGS", "OTHER_SWIFT_FLAGS", "OTHER_LDFLAGS", "LD_RUNPATH_SEARCH_PATHS", "FRAMEWORK_SEARCH_PATHS",
    "HEADER_SEARCH_PATHS", "LIBRARY_SEARCH_PATHS", "SWIFT_INCLUDE_PATHS",
]


def pairs(values, what):
    if len(values) % 2:
        sys.exit(f"rn-reference-summary: {what} needs <name> <file> pairs")
    return list(zip(values[::2], values[1::2]))


def normaliser(prefixes):
    prefixes = sorted(((path.rstrip("/"), name) for name, path in prefixes if path), key=lambda p: -len(p[0]))

    def norm(value):
        if isinstance(value, str):
            for path, name in prefixes:
                value = value.replace(path, name)
            return value
        if isinstance(value, list):
            return [norm(v) for v in value]
        if isinstance(value, dict):
            return {k: norm(v) for k, v in value.items()}
        return value
    return norm


def write(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=2, sort_keys=True)
        f.write("\n")


def build_settings(settings_files, norm):
    targets = {}
    for target, path in settings_files:
        entries = json.load(open(path))
        entry = next((e for e in entries if e.get("target") == target), entries[0])
        bs = entry["buildSettings"]
        targets[target] = {k: norm(bs[k]) for k in KEYS if k in bs}
    return targets


def pif_summary(pif_path, project_path, norm):
    objects = json.load(open(pif_path))
    by_sig = {o["signature"]: o for o in objects}
    workspace = next(o for o in objects if o["type"] == "workspace")["contents"]
    projects = [by_sig[s]["contents"] for s in workspace["projects"]]
    app_project = next(p for p in projects if os.path.realpath(p["path"]) == os.path.realpath(project_path))

    # guid → name for targets (all projects: an app may link a Pods target's product) and for file references.
    target_names = {}
    for p in projects:
        for s in p.get("targets", []):
            t = by_sig[s]["contents"]
            target_names[t["guid"]] = t["name"]
    file_names = {}

    def walk(node):
        if node.get("type") == "file":
            file_names[node["guid"]] = os.path.basename(node.get("path", node.get("name", "")))
        for child in node.get("children", []):
            walk(child)
    for p in projects:
        walk(p["groupTree"])

    def ref_name(build_file):
        if "targetReference" in build_file:
            return {"target": target_names.get(build_file["targetReference"], build_file["targetReference"])}
        if "fileReference" in build_file:
            return {"file": file_names.get(build_file["fileReference"], build_file["fileReference"])}
        return {k: v for k, v in build_file.items() if k != "guid"}

    targets = []
    for s in app_project["targets"]:
        t = by_sig[s]["contents"]
        phases = []
        for ph in t.get("buildPhases", []):
            entry = {"type": ph["type"].removeprefix("com.apple.buildphase.")}
            if "name" in ph:
                entry["name"] = ph["name"]
            if entry["type"] in ("frameworks", "copy-files"):
                entry["buildFiles"] = [ref_name(bf) for bf in ph.get("buildFiles", [])]
            if entry["type"] == "copy-files":
                entry["destinationSubfolder"] = ph.get("destinationSubfolder")
                entry["destinationSubpath"] = ph.get("destinationSubpath")
            if entry["type"] == "shell-script":
                entry["alwaysOutOfDate"] = ph.get("alwaysOutOfDate")
            phases.append(entry)
        targets.append({
            "name": t["name"],
            "type": t["type"],
            "productTypeIdentifier": t.get("productTypeIdentifier"),
            "product": (t.get("productReference") or {}).get("name"),
            "dependencies": [d.get("name", target_names.get(d["guid"], d["guid"])) for d in t.get("dependencies", [])],
            "buildConfigurations": sorted(c["name"] for c in t.get("buildConfigurations", [])),
            "baseConfigurations": sorted({
                file_names.get(c["baseConfigurationFileReference"], c["baseConfigurationFileReference"])
                for c in t.get("buildConfigurations", []) if c.get("baseConfigurationFileReference")}),
            "buildPhases": phases,
        })
    return norm({
        "workspaceProjects": sorted(
            ({"name": os.path.basename(p["path"]), "targets": len(p.get("targets", []))} for p in projects),
            key=lambda p: p["name"]),
        "project": os.path.basename(app_project["path"]),
        "targets": targets,
    })


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--xcode", required=True)
    ap.add_argument("--project", required=True)
    ap.add_argument("--pif", required=True)
    ap.add_argument("--prefix", nargs=2, action="append", default=[], metavar=("NAME", "PATH"))
    ap.add_argument("--settings", nargs="*", default=[])
    ap.add_argument("--appex", nargs="*", default=[])
    a = ap.parse_args()
    norm = normaliser(a.prefix)

    write(os.path.join(a.out, "build-settings.json"), {
        "xcodeBuild": a.xcode, "configuration": "Release", "sdk": "iphoneos",
        "targets": build_settings(pairs(a.settings, "--settings"), norm),
    })
    summary = pif_summary(a.pif, a.project, norm)
    summary["xcodeBuild"] = a.xcode
    write(os.path.join(a.out, "pif-summary.json"), summary)
    appex = {name: json.load(open(path)) for name, path in pairs(a.appex, "--appex")}
    if appex:
        write(os.path.join(a.out, "reference-appex.json"), appex)


if __name__ == "__main__":
    main()
