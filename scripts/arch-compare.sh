#!/usr/bin/env bash
# Compares two finished .app directories built from one project on hosts of different architectures (an arm64 and an
# amd64 build container): the output must not depend on the host.
# Usage: scripts/arch-compare.sh <app-a> <app-b>
#   1. prints `xless tauri report` (the summary reference.json is made of) of each app and diffs the two;
#   2. lists every file whose bytes differ outside _CodeSignature/ and the Mach-O code-signature blob (a file in only
#      one app counts as different). A Mach-O image is compared without its LC_CODE_SIGNATURE data, that command's
#      offset and size, and __LINKEDIT's file and VM size, which the signature's length moves.
# Exit: 0 identical, 1 a summary or byte difference, 2 usage. XLESS: the xless binary (default: `xless` on PATH, else the
# host build `swift build --product xless`).
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# -eq 2 ]] || { echo "usage: $0 <app-a> <app-b>" >&2; exit 2; }
for d in "$1" "$2"; do [[ -d "$d" ]] || { echo "arch-compare: $d is not a directory" >&2; exit 2; }; done
a="$(cd "$1" && pwd)"; b="$(cd "$2" && pwd)"
x="${XLESS:-}"
if [[ -z "$x" ]]; then
  if command -v xless >/dev/null 2>&1; then x=xless
  else (cd "$repo" && swift build --product xless -q) && x="$(cd "$repo" && swift build --show-bin-path)/xless"; fi
fi
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
rc=0

"$x" tauri report "$a" --json "$t/a.json" >/dev/null
"$x" tauri report "$b" --json "$t/b.json" >/dev/null
echo "==> summary of $a"; cat "$t/a.json"; echo
echo "==> summary of $b"; cat "$t/b.json"; echo
if diff -u "$t/a.json" "$t/b.json" >"$t/summary.diff"; then
  echo "==> summaries are identical"
else
  echo "==> summaries differ:"; cat "$t/summary.diff"; rc=1
fi

echo "==> bytes outside _CodeSignature/ and the Mach-O code-signature blob"
if python3 -I - "$a" "$b" <<'PY'
import os, struct, sys

def files(root):
    out = {}
    for d, _, names in os.walk(root):
        rel = os.path.relpath(d, root)
        if rel == "_CodeSignature" or rel.startswith("_CodeSignature" + os.sep):
            continue
        for n in names:
            p = os.path.join(d, n)
            out[os.path.relpath(p, root)] = p
    return out

def masked(path):
    """The file's bytes; a thin 64-bit little-endian Mach-O without its code-signature data."""
    if os.path.islink(path):
        return b"link:" + os.readlink(path).encode()
    data = bytearray(open(path, "rb").read())
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != 0xfeedfacf:
        return bytes(data)
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off, sig = 32, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x1d:                                   # LC_CODE_SIGNATURE: dataoff, datasize
            sig = struct.unpack_from("<II", data, off + 8)
            struct.pack_into("<II", data, off + 8, 0, 0)
        elif cmd == 0x19 and data[off + 8:off + 24].rstrip(b"\0") == b"__LINKEDIT":
            struct.pack_into("<Q", data, off + 32, 0)     # vmsize
            struct.pack_into("<Q", data, off + 48, 0)     # filesize
        off += size
    if sig:
        del data[sig[0]:sig[0] + sig[1]]
    return bytes(data)

fa, fb = files(sys.argv[1]), files(sys.argv[2])
bad = []
for rel in sorted(set(fa) | set(fb)):
    if rel not in fa:
        bad.append((rel, "only in the second app"))
    elif rel not in fb:
        bad.append((rel, "only in the first app"))
    elif masked(fa[rel]) != masked(fb[rel]):
        bad.append((rel, "bytes differ"))
for rel, why in bad:
    print(f"  {rel}: {why}")
print(f"  {len(bad)} difference(s) in {len(set(fa) | set(fb))} files")
sys.exit(1 if bad else 0)
PY
then :; else rc=1; fi
[[ $rc == 0 ]] && echo "==> identical" || echo "==> DIFFERENT" >&2
exit $rc
