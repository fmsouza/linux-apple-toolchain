#!/usr/bin/env python3
"""HelloCargo's app icon: an opaque 1024x1024 PNG (a solid colour with a disc and a notch), original work.

  python3 scripts/make-icon.py [out.png]      default Assets.xcassets/AppIcon.appiconset/icon-1024.png

Standard library only (zlib, struct). The PNG is 8-bit RGB with no alpha channel: App Store Connect rejects iOS app icons
with one (ITMS-90717).
"""
import os
import struct
import sys
import zlib

SIZE = 1024
BG = (36, 112, 160)
DISC = (255, 200, 64)
CENTER, RADIUS = SIZE // 2, 280


def pixel(x, y):
    if 462 <= x < 562 and 352 <= y < 672:  # the notch: background shows through
        return BG
    inside = (x - CENTER) ** 2 + (y - CENTER) ** 2 <= RADIUS ** 2
    return DISC if inside else BG


def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def png():
    rows = bytearray()
    for y in range(SIZE):
        rows.append(0)  # filter: none
        for x in range(SIZE):
            rows.extend(pixel(x, y))
    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)  # 8-bit, colour type 2 (RGB)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png")
    with open(out, "wb") as f:
        f.write(png())
