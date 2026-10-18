#!/usr/bin/env bash
# Records what Apple's copypng makes of the PNG cases Tests/XlessAssetsTests/CopyPNGShimTests.swift uses. Mac only.
#
#   DEVELOPER_DIR=<Xcode>/Contents/Developer scripts/copypng-golden.sh
#
# Builds the cases below (our own tiny PNGs, the same pixels and chunks as the shim tests), runs `xcrun copypng` on each
# with the option sets the shim knows (`-compress -strip-PNG-text`, `-strip-PNG-text`, none) and writes
# Tests/XlessAssetsTests/Fixtures/copypng/<build>.json, the build read from `xcodebuild -version`: per case and option
# set the exit code, stderr, the output's IHDR fields, its chunk order, whether CgBI is present (and its bytes), whether
# the output is byte-identical to the input, and the sha256 of the decoded pixels (unfiltered scanlines as stored,
# after inflating). No copypng output bytes are committed, only these fields.
# Any Xcode build is accepted (a build without an XcodeToolsProfile is how a profile is born).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname)" == Darwin ]] || { echo "copypng-golden: needs macOS (uname is $(uname))" >&2; exit 1; }
BUILD="$(xcodebuild -version | sed -n 's/^Build version //p')"
[[ -n $BUILD ]] || { echo "copypng-golden: cannot read the Xcode build from xcodebuild -version" >&2; exit 1; }
COPYPNG="$(xcrun --find copypng)"
OUT="$ROOT/Tests/XlessAssetsTests/Fixtures/copypng/$BUILD.json"
mkdir -p "$(dirname "$OUT")"
/usr/bin/python3 -I - "$COPYPNG" "$OUT" "$BUILD" <<'PY'
import hashlib, json, os, struct, subprocess, sys, tempfile, zlib

copypng, out, build = sys.argv[1:]

def chunk(t, body):
    t = t.encode()
    return struct.pack(">I", len(body)) + t + body + struct.pack(">I", zlib.crc32(t + body))

def png(w, h, ct, rows, depth=8, extra=()):
    raw = b"".join(b"\0" + bytes(r) for r in rows)
    o = b"\x89PNG\r\n\x1a\n" + chunk("IHDR", struct.pack(">IIBBBBB", w, h, depth, ct, 0, 0, 0))
    for t, b in extra:
        o += chunk(t, b)
    return o + chunk("IDAT", zlib.compress(raw, 0)) + chunk("IEND", b"")

rgba_rows = [[v for x in range(4) for v in (10 * x + y, 20 * y, 200, 60 * x)] for y in range(4)]
cases = {
    "rgba-4x4-text": png(4, 4, 6, rgba_rows, extra=[("tEXt", b"Comment\0hi")]),
    "rgba-4x4": png(4, 4, 6, rgba_rows),
    "rgb-2x2": png(2, 2, 2, [[0, 0, 200, 10, 0, 200], [1, 20, 200, 11, 20, 200]]),
    "rgb16-1x1": png(1, 1, 2, [[0, 1, 0, 2, 0, 3]], depth=16),
    "rgba16-1x1-text": png(1, 1, 6, [[0, 1, 0, 2, 0, 3, 0, 4]], depth=16, extra=[("tEXt", b"a\0b")]),
    "gray16-1x1": png(1, 1, 0, [[0, 1]], depth=16),
    "rgb16-1x1-srgb": png(1, 1, 2, [[0, 1, 0, 2, 0, 3]], depth=16, extra=[("sRGB", b"\0")]),
    "gray-1x1": png(1, 1, 0, [[7]]),
    "rgb-1x1-srgb": png(1, 1, 2, [[1, 2, 3]], extra=[("sRGB", b"\0")]),
    "rgb-1x1-text": png(1, 1, 2, [[1, 2, 3]], extra=[("tEXt", b"a\0b")]),
}
optionsets = {
    "compress-strip": ["-compress", "-strip-PNG-text"],
    "compress": ["-compress"],
    "strip": ["-strip-PNG-text"],
    "none": [],
}

def parse(d):
    assert d[:8] == b"\x89PNG\r\n\x1a\n"
    i, chunks = 8, []
    while i + 8 <= len(d):
        n = struct.unpack(">I", d[i:i + 4])[0]
        chunks.append((d[i + 4:i + 8].decode(), d[i + 8:i + 8 + n]))
        i += 12 + n
    return chunks

def pixels_sha(chunks, cgbi):
    ihdr = dict(zip(("w", "h", "depth", "ct"), struct.unpack(">IIBB", chunks[[c[0] for c in chunks].index("IHDR")][1][:10])))
    idat = b"".join(b for t, b in chunks if t == "IDAT")
    raw = zlib.decompress(idat, -15 if cgbi else 15)
    chan = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ihdr["ct"]]
    bpp = max(1, chan * ihdr["depth"] // 8)
    stride = (ihdr["w"] * chan * ihdr["depth"] + 7) // 8
    prev = bytearray(stride)
    pix = bytearray()
    for y in range(ihdr["h"]):
        row = raw[y * (stride + 1): (y + 1) * (stride + 1)]
        f, cur = row[0], bytearray(row[1:])
        for x in range(stride):
            a = cur[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1: cur[x] = (cur[x] + a) & 255
            elif f == 2: cur[x] = (cur[x] + b) & 255
            elif f == 3: cur[x] = (cur[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                cur[x] = (cur[x] + pr) & 255
        pix += cur
        prev = cur
    return hashlib.sha256(bytes(pix)).hexdigest()

result = {"xcodeBuild": build, "note": "copypng output fields only; pixelsSha256 hashes the unfiltered scanlines as stored (CgBI: raw deflate, BGRA premultiplied)", "cases": {}}
with tempfile.TemporaryDirectory() as tmp:
    for name, data in cases.items():
        src = os.path.join(tmp, name + ".png")
        open(src, "wb").write(data)
        per = {}
        for oname, opts in optionsets.items():
            dst = os.path.join(tmp, f"{name}.{oname}.out.png")
            p = subprocess.run([copypng, *opts, src, dst], capture_output=True)
            entry = {"exit": p.returncode, "stderr": p.stderr.decode(errors="replace").strip(), "stdout": p.stdout.decode(errors="replace").strip()}
            if p.returncode == 0 and os.path.exists(dst):
                d = open(dst, "rb").read()
                chunks = parse(d)
                cg = [b for t, b in chunks if t == "CgBI"]
                ihdr = [b for t, b in chunks if t == "IHDR"][0]
                w, h, depth, ct, comp, flt, ilace = struct.unpack(">IIBBBBB", ihdr)
                entry.update({
                    "identicalToInput": d == data,
                    "ihdr": {"width": w, "height": h, "bitDepth": depth, "colorType": ct, "compression": comp, "filter": flt, "interlace": ilace},
                    "chunkOrder": [t for t, _ in chunks],
                    "cgbi": cg[0].hex() if cg else None,
                    "pixelsSha256": pixels_sha(chunks, bool(cg)),
                })
            per[oname] = entry
        result["cases"][name] = per
with open(out, "w") as f:
    json.dump(result, f, indent=2, sort_keys=True)
    f.write("\n")
print(f"wrote {out}: {len(cases)} cases x {len(optionsets)} option sets (Xcode {build})")
PY
