#!/usr/bin/env python3
"""Mask the full-bleed lime icon into a macOS-style squircle with transparent corners."""
from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw

# iOS/macOS continuous-corner ratio on the icon body.
CORNER_RATIO = 0.2237
# A custom NSDockTile contentView bypasses the system's normal icon renderer, so
# we must preserve the same transparent perimeter ourselves. On this macOS 26
# install the bundled App Store, Xcode, Photos and Notes icons all have a 224 px
# alpha body inside a 256 px icon image: 224 / 256 == 0.875.
INNER_SCALE = 0.875


def squircle_mask(size: int) -> Image.Image:
    supersample = 4
    big = size * supersample
    radius = int(round(big * CORNER_RATIO))
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, big - 1, big - 1), radius=radius, fill=255)
    return mask.resize((size, size), Image.Resampling.LANCZOS)


def bake(src: Path, dest: Path) -> None:
    canvas = 1024
    inner = int(round(canvas * INNER_SCALE))
    offset = (canvas - inner) // 2
    src_img = Image.open(src).convert("RGBA").resize((inner, inner), Image.Resampling.LANCZOS)
    masked = Image.new("RGBA", (inner, inner), (0, 0, 0, 0))
    masked.paste(src_img, (0, 0))
    masked.putalpha(squircle_mask(inner))
    out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    out.paste(masked, (offset, offset), masked)
    dest.parent.mkdir(parents=True, exist_ok=True)
    out.save(dest, "PNG")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: bake_macos_icon.py SRC.png DEST.png")
    bake(Path(sys.argv[1]), Path(sys.argv[2]))
    print(sys.argv[2])
