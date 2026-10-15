#!/usr/bin/env python3
"""HelloTauri icons.

  python3 scripts/make-icon-source.py <out.png>       draw the opaque 1024x1024 source (solid colour plus a shape)
  pnpm tauri icon <out.png>                           generate the icon set (also gen/apple's AppIcon.appiconset)
  python3 scripts/make-icon-source.py --flatten <dir>...
                                                      re-save every PNG in <dir> as RGB: `tauri icon` writes RGBA even
                                                      for an opaque source, and App Store Connect rejects iOS app
                                                      icons with an alpha channel (ITMS-90717)
"""
import glob
import os
import sys
from PIL import Image

BG = (36, 112, 160)

if sys.argv[1] == "--flatten":
    for d in sys.argv[2:]:
        for f in sorted(glob.glob(os.path.join(d, "*.png"))):
            im = Image.open(f)
            if im.mode != "RGB":
                flat = Image.new("RGB", im.size, BG)
                flat.paste(im, mask=im.convert("RGBA").split()[3])
                flat.save(f)
else:
    from PIL import ImageDraw
    img = Image.new("RGB", (1024, 1024), BG)
    d = ImageDraw.Draw(img)
    d.ellipse((232, 232, 792, 792), fill=(255, 200, 64))
    d.rectangle((462, 352, 562, 672), fill=BG)
    img.save(sys.argv[1])
