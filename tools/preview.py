"""Draws render.awk's commands the way FBInk does, as a PNG, to check a layout on the Mac.

    ... | uv run --project tools python tools/preview.py out.png

FBInk metrics (fbink.c, fbink_print_ot): scale = px / (ascent - descent) (stbtt_ScaleForPixelHeight),
baseline = top + ceil(scale * ascent), "-m" centres the line in [left, width - right].
Pillow sizes fonts by the em, so em = px * unitsPerEm / (ascent - descent).
Warns when a text would not fit in its box (FBInk would wrap it onto a second line).
"""

from __future__ import annotations

import math
import sys
from functools import lru_cache
from pathlib import Path

from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFont

EXT = Path(__file__).resolve().parent.parent / "kindle" / "kindledash"
FONTS = {k: f"{k}.ttf" for k in "RSBD"}
SW, SH = 758, 1024


def color(name: str) -> int:
    if name == "BLACK":
        return 0
    if name == "WHITE":
        return 255
    if name.startswith("GRAY"):
        return int(name[4:], 16) * 17
    raise ValueError(name)


@lru_cache
def metrics(key: str) -> tuple[int, int, int]:
    f = TTFont(EXT / "fonts" / FONTS[key])
    return f["hhea"].ascent, f["hhea"].descent, f["head"].unitsPerEm


@lru_cache
def font(key: str, px: int) -> ImageFont.FreeTypeFont:
    asc, desc, upem = metrics(key)
    return ImageFont.truetype(str(EXT / "fonts" / FONTS[key]), size=px * upem / (asc - desc))


def main(out: str) -> None:
    img = Image.new("L", (SW, SH), 255)
    d = ImageDraw.Draw(img)
    for line in sys.stdin.read().splitlines():
        kind, *f = line.split("|")
        if kind == "R":
            x, y, w, h = map(int, f[:4])
            if w > 0 and h > 0:
                d.rectangle((x, y, x + w - 1, y + h - 1), fill=color(f[4]))
        elif kind == "I":
            img.paste(Image.open(EXT / f[0]).convert("L"), (int(f[1]), int(f[2])))
        elif kind == "T":
            key, px, left, right, top, col, flags = f[0], int(f[1]), int(f[2]), int(f[3]), int(f[4]), f[5], f[6]
            text = "|".join(f[7:])
            asc, desc, _ = metrics(key)
            base = top + math.ceil(px / (asc - desc) * asc)
            fnt = font(key, px)
            w = d.textlength(text, font=fnt)
            box = SW - right - left
            if w > box:
                print(f"warning: text wider than its box ({w:.0f} > {box}): {text!r}", file=sys.stderr)
            x = left + (box - w) / 2 if "c" in flags else left
            d.text((x, base), text, font=fnt, fill=color(col), anchor="ls")
        else:
            print(f"warning: unknown command {line!r}", file=sys.stderr)
    img.save(out)


if __name__ == "__main__":
    main(sys.argv[1])
