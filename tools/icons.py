"""Playful weather icons for e-ink: thick rounded outlines, light gray fills, teardrop rain.

Each icon is drawn at SS x the target size and scaled down (anti-aliasing). Coordinates are in
units of the icon size (0..1). `bg` is the background gray (255 = white, 238 = card gray), baked
into the PNG because FBInk draws the images without transparency here.
"""

from __future__ import annotations

import math
from functools import lru_cache

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SS = 4
SUN = 187      # sun and moon fill
DARK = 136     # back cloud / storm cloud fill
WHITE = 255


class Pen:
    def __init__(self, size: int, bg: int, stroke: float = 0.055):
        self.n = size * SS
        self.img = Image.new("L", (self.n, self.n), bg)
        self.d = ImageDraw.Draw(self.img)
        # small icons need relatively thicker lines to stay visible
        self.w = max(2.0, self.n * (stroke if size >= 100 else stroke * 1.35))

    def p(self, v: float) -> float:
        return v * self.n

    def mask(self) -> tuple[Image.Image, ImageDraw.ImageDraw]:
        m = Image.new("L", (self.n, self.n), 0)
        return m, ImageDraw.Draw(m)

    def disc(self, d: ImageDraw.ImageDraw, cx: float, cy: float, r: float, fill: int = 255) -> None:
        r = self.p(r)
        d.ellipse((self.p(cx) - r, self.p(cy) - r, self.p(cx) + r, self.p(cy) + r), fill=fill)

    def line(self, pts: list[tuple[float, float]], fill: int = 0, w: float | None = None) -> None:
        w = w or self.w
        xy = [(self.p(x), self.p(y)) for x, y in pts]
        self.d.line(xy, fill=fill, width=round(w), joint="curve")
        for x, y in (xy[0], xy[-1]):  # round caps
            self.d.ellipse((x - w / 2, y - w / 2, x + w / 2, y + w / 2), fill=fill)

    def shape(self, mask: Image.Image, fill: int) -> None:
        """Fills a mask shape and gives it a black outline of stroke width."""
        self.img.paste(0, (0, 0), mask)
        self.img.paste(fill, (0, 0), erode(mask, self.w))

    def done(self, size: int) -> Image.Image:
        return self.img.resize((size, size), Image.Resampling.LANCZOS)


def erode(mask: Image.Image, w: float) -> Image.Image:
    """Moves the edge of a white-on-black mask inward by about w pixels.

    A Gaussian blur with sigma = w/1.5 leaves Phi(1.5) = 93.3 % (238/255) of full white
    at distance w inside a straight edge, so the threshold at 238 sits at that distance.
    """
    return mask.filter(ImageFilter.GaussianBlur(w / 1.5)).point(lambda v: 255 if v >= 238 else 0)


# --- Parts --------------------------------------------------------------------------------

def sun(p: Pen, cx: float, cy: float, r: float) -> None:
    m, d = p.mask()
    p.disc(d, cx, cy, r)
    p.shape(m, SUN)
    for k in range(8):
        a = k * math.pi / 4 + math.pi / 8
        r0, r1 = r * 1.42, r * (1.95 if k % 2 == 0 else 1.72)  # long and short rays
        p.line([(cx + r0 * math.cos(a), cy + r0 * math.sin(a)), (cx + r1 * math.cos(a), cy + r1 * math.sin(a))])


def sparkle(p: Pen, cx: float, cy: float, r: float) -> None:
    """Four-point star."""
    k = r * 0.28
    pts = [(cx, cy - r), (cx + k, cy - k), (cx + r, cy), (cx + k, cy + k),
           (cx, cy + r), (cx - k, cy + k), (cx - r, cy), (cx - k, cy - k)]
    p.d.polygon([(p.p(x), p.p(y)) for x, y in pts], fill=0)


def moon(p: Pen, cx: float, cy: float, r: float, stars: bool = True) -> None:
    m, d = p.mask()
    p.disc(d, cx, cy, r)
    cut, cd = p.mask()
    p.disc(cd, cx + r * 0.6, cy - r * 0.42, r * 0.82)
    p.shape(ImageChops.subtract(m, cut), SUN)
    if stars:
        sparkle(p, cx + r * 0.95, cy + r * 0.35, r * 0.24)
        sparkle(p, cx + r * 0.55, cy - r * 1.05, r * 0.16)


def cloud(p: Pen, ox: float = 0, oy: float = 0, s: float = 1.0, fill: int = WHITE) -> None:
    m, d = p.mask()
    for cx, cy, r in ((0.31, 0.58, 0.17), (0.52, 0.45, 0.23), (0.73, 0.57, 0.16)):
        p.disc(d, ox + cx * s, oy + cy * s, r * s)
    box = (p.p(ox + 0.14 * s), p.p(oy + 0.55 * s), p.p(ox + 0.89 * s), p.p(oy + 0.76 * s))
    d.rounded_rectangle(box, radius=p.p(0.105 * s), fill=255)
    p.shape(m, fill)


def drop(p: Pen, cx: float, cy: float, r: float, fill: int = 0, outline: bool = False) -> None:
    """Teardrop: round bottom at (cx, cy), tip 2.3 r above."""
    m, d = p.mask()
    p.disc(d, cx, cy, r)
    tip = cy - r * 2.3
    a = math.asin(r / (cy - tip))  # tangent points
    tx = r * math.cos(a)
    ty = cy - r * math.sin(a)
    d.polygon([(p.p(cx), p.p(tip)), (p.p(cx + tx), p.p(ty)), (p.p(cx - tx), p.p(ty))], fill=255)
    if outline:
        p.shape(m, fill)
    else:
        p.img.paste(fill, (0, 0), m)


def flake(p: Pen, cx: float, cy: float, r: float) -> None:
    for k in range(3):
        a = k * math.pi / 3 + math.pi / 2
        p.line([(cx - r * math.cos(a), cy - r * math.sin(a)), (cx + r * math.cos(a), cy + r * math.sin(a))], w=p.w * 0.75)


def wave(p: Pen, x0: float, x1: float, y: float, amp: float = 0.025, periods: float = 2.0) -> None:
    pts = [(x0 + (x1 - x0) * t / 40, y + amp * math.sin(2 * math.pi * periods * t / 40)) for t in range(41)]
    p.line(pts)


def bolt(p: Pen, ox: float, oy: float, s: float = 1.0) -> None:
    pts = [(0.58, 0.60), (0.38, 0.82), (0.50, 0.82), (0.42, 0.99), (0.68, 0.73), (0.55, 0.73), (0.65, 0.60)]
    m, d = p.mask()
    d.polygon([(p.p(ox + x * s), p.p(oy + y * s)) for x, y in pts], fill=255)
    m = m.filter(ImageFilter.GaussianBlur(p.w * 0.25)).point(lambda v: 255 if v > 100 else 0)  # soften corners
    p.img.paste(0, (0, 0), m)


# --- Weather icons --------------------------------------------------------------------------

@lru_cache(maxsize=512)
def icon(kind: str, size: int, is_day: bool = True, bg: int = WHITE) -> Image.Image:
    """kind: clear, partly, cloudy, fog, drizzle, rain, snow, storm."""
    p = Pen(size, bg)
    if kind == "clear":
        if is_day:
            sun(p, 0.5, 0.5, 0.21)
        else:
            moon(p, 0.44, 0.52, 0.29)
    elif kind == "partly":
        if is_day:
            sun(p, 0.37, 0.36, 0.15)
        else:
            moon(p, 0.33, 0.30, 0.23, stars=False)
            sparkle(p, 0.80, 0.16, 0.06)
        cloud(p, 0.07, 0.13, 0.9)
    elif kind == "cloudy":
        cloud(p, 0.13, -0.10, 0.82, fill=DARK)
        cloud(p, -0.04, 0.06, 0.96)
    elif kind == "fog":
        cloud(p, 0.0, -0.16, 1.0)
        wave(p, 0.18, 0.82, 0.76)
        wave(p, 0.26, 0.90, 0.90)
    elif kind == "storm":
        cloud(p, 0.0, -0.16, 1.0, fill=DARK)
        bolt(p, 0.0, 0.0)
    else:
        cloud(p, 0.0, -0.16, 1.0)
        if kind == "rain":
            for i, x in enumerate((0.33, 0.52, 0.71)):
                drop(p, x, 0.86 + (i % 2) * 0.05, 0.055)
        elif kind == "drizzle":
            for i, x in enumerate((0.36, 0.52, 0.68)):
                drop(p, x, 0.83 + (i % 2) * 0.07, 0.035)
        elif kind == "snow":
            for i, x in enumerate((0.30, 0.52, 0.74)):
                flake(p, x, 0.81 + (i % 2) * 0.09, 0.058)
    return p.done(size)


# --- Small detail icons ---------------------------------------------------------------------

@lru_cache(maxsize=128)
def mini(kind: str, size: int, bg: int = WHITE) -> Image.Image:
    """kind: drop (filled), humidity, umbrella, wind, sunrise, sunset."""
    p = Pen(size, bg, stroke=0.085)
    if kind == "drop":
        drop(p, 0.5, 0.66, 0.24)
    elif kind == "humidity":
        drop(p, 0.5, 0.64, 0.26, fill=SUN, outline=True)
    elif kind == "umbrella":
        m, d = p.mask()
        d.pieslice((p.p(0.1), p.p(0.12), p.p(0.9), p.p(0.92)), 180, 360, fill=255)
        p.shape(m, SUN)
        p.line([(0.5, 0.52), (0.5, 0.80), (0.48, 0.86), (0.42, 0.88), (0.36, 0.84)])
    elif kind == "wind":
        p.line([(0.10, 0.36), (0.62, 0.36)])
        p.d.arc((p.p(0.50), p.p(0.12), p.p(0.74), p.p(0.36)), 180, 450, fill=0, width=round(p.w))
        p.line([(0.10, 0.56), (0.80, 0.56)])
        p.d.arc((p.p(0.68), p.p(0.56), p.p(0.92), p.p(0.80)), 270, 180 + 360, fill=0, width=round(p.w))
        p.line([(0.10, 0.76), (0.48, 0.76)])
    elif kind in ("sunrise", "sunset"):
        m, d = p.mask()
        d.pieslice((p.p(0.24), p.p(0.40), p.p(0.76), p.p(0.92)), 180, 360, fill=255)
        p.shape(m, SUN)
        p.line([(0.08, 0.68), (0.92, 0.68)])
        if kind == "sunrise":
            p.line([(0.36, 0.22), (0.5, 0.08), (0.64, 0.22)])
        else:
            p.line([(0.36, 0.10), (0.5, 0.24), (0.64, 0.10)])
    return p.done(size)


def corner_ring(r: int, width: int, quadrant: str) -> Image.Image:
    """r x r corner piece of an outlined box: white outside, black ring of `width` px, white inside."""
    n, w = r * SS, width * SS
    img = Image.new("L", (n, n), WHITE)
    d = ImageDraw.Draw(img)
    cx = n if "l" in quadrant else 0
    cy = n if "t" in quadrant else 0
    d.ellipse((cx - n, cy - n, cx + n, cy + n), fill=0)
    d.ellipse((cx - n + w, cy - n + w, cx + n - w, cy + n - w), fill=WHITE)
    return img.resize((r, r), Image.Resampling.LANCZOS)


def corner(r: int, color: int, quadrant: str, bg: int = WHITE) -> Image.Image:
    """r x r corner piece of a rounded box: `color` inside the quarter disc, `bg` outside."""
    n = r * SS
    img = Image.new("L", (n, n), bg)
    d = ImageDraw.Draw(img)
    cx = n if "l" in quadrant else 0
    cy = n if "t" in quadrant else 0
    d.ellipse((cx - n, cy - n, cx + n, cy + n), fill=color)
    return img.resize((r, r), Image.Resampling.LANCZOS)
