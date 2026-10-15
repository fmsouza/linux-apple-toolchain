#!/usr/bin/env python3
"""Pulls the app executable's compile and link command lines out of Xcode build logs.

Usage: tauri-reference-xcodelog.py <executable-name> <out-dir> <log>...
Each <log> is plain xcodebuild output or a gzipped .xcactivitylog (`tauri ios build` does not echo xcodebuild's
output, so the transcript is read from the DerivedData activity log). A task transcript is a title line
("Ld <path>/<exe> normal …", "CompileC <obj> <src> normal arm64 …") followed by indented lines; the command is the
last indented line that starts with "/". Writes:
  <out>/link.txt     the last Ld command for <exe>
  <out>/linkfiles.txt  the contents of its -filelist (the object files linked)
  <out>/compile.json [{"source", "command", "responseFile", "responseArgs"}] for every CompileC in the logs
"""
import gzip
import json
import os
import re
import sys

exe, out, logs = sys.argv[1], sys.argv[2], sys.argv[3:]
title = re.compile(r"(Ld|CompileC) (\S+)( \S+)? normal\b[^\r\n]*")
link, compiles = "", {}
for path in logs:
    raw = open(path, "rb").read()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    text = raw.decode("utf-8", "replace")
    for m in title.finditer(text):
        tail = text[m.end():m.end() + 200000]
        if not tail[:1] in ("\r", "\n"):
            continue          # a title, not a transcript
        cmd, resp = None, None
        for line in re.split(r"\r\n|\r|\n", tail)[1:]:
            if not line.startswith("    "):
                break
            s = line.strip()
            if s.startswith("Using response file: "):
                resp = s[len("Using response file: "):]
            elif s.startswith("/"):
                cmd = s
        if not cmd:
            continue
        if m.group(1) == "Ld" and m.group(2).endswith("/" + exe):
            link = cmd
        elif m.group(1) == "CompileC" and m.group(3):
            compiles[m.group(3).strip()] = (cmd, resp)

with open(os.path.join(out, "link.txt"), "w") as f:
    f.write(link + "\n")
m = re.search(r"-filelist (\S+)", link)
with open(os.path.join(out, "linkfiles.txt"), "w") as f:
    if m and os.path.exists(m.group(1)):
        f.write(open(m.group(1)).read())
entries = []
for src, (cmd, resp) in sorted(compiles.items()):
    args = open(resp).read().strip() if resp and os.path.exists(resp) else None
    entries.append({"source": src, "command": cmd, "responseFile": resp, "responseArgs": args})
with open(os.path.join(out, "compile.json"), "w") as f:
    json.dump(entries, f, indent=2)
print(f"xcodelog: link {'found' if link else 'NOT found'} for {exe}; {len(entries)} compile command(s)")
