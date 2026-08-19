#!/usr/bin/env python3
"""Generate the procedural building texture set for SLACUM CITY.

Source of truth: `docs/design/11-rendering-performance.md` §2.6 (the
custom-data / window-emission contract) and §2.14 (the gray-box art pipeline
this dresses).  The gray-box massing stays exactly as `tools/gen_graybox.gd`
emits it — no mesh and no UV is touched here.  What this adds is *surface*: an
albedo with the light already baked into it (window reveals, sills, mullion
drop shadows, brick coursing) plus a shine mask, so a Mobile-renderer city
gets material read for two texture fetches and no normal map.

Layout — the one idea the whole file hangs on
---------------------------------------------
`UV2` on a facade runs 0..1 across the block and the shader turns it into
window cells with `floor(UV2 * vec2(window_cols, window_rows))`.  So one
window cell — a *bay* — is the natural texture tile.  Every facade page here
is a **2x2 grid of bays**, seamless, `BAY_PX` per bay:

    +-----------+-----------+   v = 0.0   (image top)     odd  bay rows
    |  bay 0    |  bay 1    |
    +-----------+-----------+   v = 0.5
    |  bay 2    |  bay 3    |
    +-----------+-----------+   v = 1.0   (image bottom)  even bay rows

and the shader samples it with

    bay    = UV2 * vec2(window_cols, window_rows)      // == the emissive cell
    tex_uv = vec2(bay.x + variant_shift, 2.0 - bay.y) * 0.5

which makes a texture bay land *exactly* on an emissive cell: the glow comes
up inside the pane that is drawn, not smeared across the wall.  `2.0 - bay.y`
flips v (Godot images are top-left origin) and pins **bay row 0 — the ground
floor — to the bottom half of the page**, which is why the storefront page can
put shopfront glazing on its lower row and a sign frieze above it.

`variant_shift` is a whole number of bays, so it never breaks that alignment.

Channels: RGB = albedo with baked shading, **A = shine mask** (255 = glass or
polished metal, 0 = matte wall).  The shader drives ROUGHNESS/SPECULAR from A
and multiplies EMISSION by it, which is what turns "the cell is lit" into "the
*pane* is lit".

Non-facade surfaces — roofs, roof props, gable ends, the windowless
data-center walls: everything the gray-box marks `UV2 = (-1,-1)` — are
projected in model space instead, horizontal-ish onto the roof page at
`ROOF_TILE_M`, vertical onto the facade page at bay size.  No new UVs needed.

Determinism: no `random` module, no wall clock, no dict-iteration ordering — a
small explicit LCG seeded from `SEED`, and sorted key order everywhere.  Two
runs on two machines produce byte-identical PNGs, which is what `--check`
asserts in CI.

Usage:
    python3 tools/gen_textures.py [--out-dir game/textures/generated] [--check]

    --check   regenerate in memory and compare against the committed pages and
              manifest; write nothing, exit 1 on any drift.

After a regeneration:  ~/.local/bin/godot --headless --path . --import
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import sys

try:
    from PIL import Image, ImageChops, ImageDraw
except ImportError:  # pragma: no cover - environment guard
    print("gen_textures: Pillow is required (pip install Pillow)", file=sys.stderr)
    raise

GENERATOR = "tools/gen_textures.py"
GENERATOR_VERSION = 2
SEED = 20260818

BAY_PX = 256                 # one window bay
PAGE = BAY_PX * 2            # 512x512 facade page, 2x2 bays
ROOF_PAGE = 512              # roof / ground pages
ROOF_TILE_M = 4.0            # metres per roof-page repeat
BAY_M = (3.2, 3.5)           # nominal bay footprint, doc 11 §2.14 window grid

# --- the props set (construction sites, streetlight poles) ------------------
# Everything that is NOT a building, a road or the water: hoarding, crane
# lattice, scaffold tube, stockpiles, lamp poles. Three seamless pages, tiled in
# METRES so a 0.22 m crane leg and an 8 m pole carry the same grain, plus one
# non-tiling page that is a single hoarding panel drawn end to end.
PROP_PAGE = 512
PROP_TILE_M = 2.0            # metres per repeat for the tiling prop pages
HOARDING_PANEL_M = (4.0, 2.2)  # the hoarding page IS one panel: u,v run 0..1

# --- the vehicle micro-atlas ----------------------------------------------
# 2x2 cells. UV2 on a vehicle body is `cell + inset..1-inset`, so one cell is
# one material and the mesh never tiles: a face maps its own extent into its
# cell exactly once. The inset is what keeps a mip level from bleeding a
# neighbouring cell into a car door at 200 m.
VEHICLE_PAGE = 512
VEHICLE_CELL = VEHICLE_PAGE // 2
VEHICLE_UV_INSET = 0.06


# --------------------------------------------------------------- determinism

class Lcg:
    """Numerical Recipes 32-bit LCG. Explicit, so output never depends on the
    host Python's `random` implementation."""

    __slots__ = ("s",)

    def __init__(self, seed: int) -> None:
        self.s = seed & 0xFFFFFFFF

    def u32(self) -> int:
        self.s = (self.s * 1664525 + 1013904223) & 0xFFFFFFFF
        return self.s

    def f(self) -> float:
        return self.u32() / 4294967296.0


def name_seed(name: str) -> int:
    return int(hashlib.sha256(name.encode("utf-8")).hexdigest()[:8], 16)


# ------------------------------------------------------------------- colour

def c8(v: float) -> int:
    return 0 if v < 0 else (255 if v > 255 else int(v))


def shade(rgb, k: float):
    """Multiply a colour by `k` — the baked-lighting primitive of this file."""
    return (c8(rgb[0] * k), c8(rgb[1] * k), c8(rgb[2] * k))


def mixc(a, b, t: float):
    return (c8(a[0] + (b[0] - a[0]) * t),
            c8(a[1] + (b[1] - a[1]) * t),
            c8(a[2] + (b[2] - a[2]) * t))


# ------------------------------------------------------------------- canvas

class Page:
    """A seamless tile: an opaque RGB colour plane plus an L shine plane.

    Every primitive wraps at the page edges, so anything crossing a border
    reappears on the far side and the page tiles cleanly in both axes.
    Translucent draws really composite (PIL's ImageDraw would overwrite), which
    is what makes the soft contact shadows read as shadows rather than as
    flat gray bars.
    """

    def __init__(self, size: int, base_rgb, base_shine: int = 0) -> None:
        self.size = size
        self.c = Image.new("RGB", (size, size), base_rgb)
        self.a = Image.new("L", (size, size), base_shine)
        self.dc = ImageDraw.Draw(self.c)
        self.da = ImageDraw.Draw(self.a)

    # -- geometry -----------------------------------------------------------

    def _boxes(self, x0, y0, x1, y1):
        """All wrapped, page-clipped copies of an inclusive box."""
        s = self.size
        x0, y0, x1, y1 = int(x0), int(y0), int(x1), int(y1)
        if x1 < x0 or y1 < y0:
            return []
        out = []
        for dx in (-s, 0, s):
            for dy in (-s, 0, s):
                bx0 = max(0, x0 + dx)
                by0 = max(0, y0 + dy)
                bx1 = min(s - 1, x1 + dx)
                by1 = min(s - 1, y1 + dy)
                if bx0 <= bx1 and by0 <= by1:
                    out.append((bx0, by0, bx1, by1))
        return out

    # -- opaque -------------------------------------------------------------

    def rect(self, x0, y0, x1, y1, rgb=None, shine=None) -> None:
        for b in self._boxes(x0, y0, x1, y1):
            if rgb is not None:
                self.dc.rectangle(b, fill=rgb)
            if shine is not None:
                self.da.rectangle(b, fill=shine)

    def vgrad(self, x0, y0, x1, y1, top, bot, shine=None) -> None:
        """Vertical linear ramp — the cheap stand-in for a normal map: it is
        what makes a flat quad read as a recess or as a sheet of glass."""
        y0i, y1i = int(y0), int(y1)
        h = max(1, y1i - y0i)
        for y in range(y0i, y1i + 1):
            self.rect(x0, y, x1, y, mixc(top, bot, (y - y0i) / h))
        if shine is not None:
            self.rect(x0, y0, x1, y1, shine=shine)

    # -- translucent (true composite) ---------------------------------------

    def over(self, x0, y0, x1, y1, rgb, alpha: int) -> None:
        if alpha <= 0:
            return
        for b in self._boxes(x0, y0, x1, y1):
            box = (b[0], b[1], b[2] + 1, b[3] + 1)
            region = self.c.crop(box).convert("RGBA")
            layer = Image.new("RGBA", region.size, (rgb[0], rgb[1], rgb[2], alpha))
            self.c.paste(Image.alpha_composite(region, layer).convert("RGB"), box)

    def shadow_down(self, x0, x1, y, depth: int, strength: float) -> None:
        """Contact shadow falling below an edge: rows of decreasing alpha
        black. Reads as an overhang without a single extra triangle."""
        for i in range(depth):
            a = int(255 * strength * (1.0 - i / depth) ** 1.6)
            self.over(x0, y + i, x1, y + i, (0, 0, 0), a)

    def shadow_up(self, x0, x1, y, depth: int, strength: float) -> None:
        for i in range(depth):
            a = int(255 * strength * (1.0 - i / depth) ** 1.6)
            self.over(x0, y - i, x1, y - i, (0, 0, 0), a)

    def shadow_right(self, y0, y1, x, depth: int, strength: float) -> None:
        for i in range(depth):
            a = int(255 * strength * (1.0 - i / depth) ** 1.6)
            self.over(x + i, y0, x + i, y1, (0, 0, 0), a)

    def light_up(self, x0, x1, y, depth: int, strength: float) -> None:
        for i in range(depth):
            a = int(255 * strength * (1.0 - i / depth) ** 1.6)
            self.over(x0, y - i, x1, y - i, (255, 255, 255), a)

    # -- finish -------------------------------------------------------------

    def noise(self, lcg: Lcg, amount: float) -> None:
        """Value jitter, applied to colour only (the shine mask must stay
        hard-edged or the glow bleeds outside the pane). It is what stops a
        flat wall reading as vector art.

        Authored at half resolution and point-upscaled: a 2 px grain survives
        the first mip where a 1 px one just averages away, and it roughly
        halves the committed PNG — per-pixel white noise is the single most
        expensive thing you can hand a PNG encoder. Still trivially seamless,
        since every sample is independent."""
        d = max(1, int(amount * 255.0))
        s = self.size
        half = s // 2
        buf = bytearray(half * half)
        for i in range(half * half):
            buf[i] = int(lcg.f() * (2 * d + 1))
        n = Image.frombytes("L", (half, half), bytes(buf)).resize(
            (s, s), Image.NEAREST).convert("RGB")
        self.c = ImageChops.add(self.c, n, 1.0, -d)
        self.dc = ImageDraw.Draw(self.c)

    def image(self) -> Image.Image:
        r, g, b = self.c.split()
        return Image.merge("RGBA", (r, g, b, self.a))


# ---------------------------------------------------------- shared elements

def pane(p: Page, x0, y0, x1, y1, glass_top, glass_bot, reveal=0.55,
         shine=235, sheen=True) -> None:
    """A window pane with a baked reveal: darkness on the top and left inner
    edges (the sun is high and to the left everywhere in this set), a vertical
    glass gradient, a sky sheen and a bounce hairline on the sill. This one
    helper carries most of the depth in the whole texture set."""
    p.vgrad(x0, y0, x1, y1, glass_top, glass_bot, shine=shine)
    if sheen:
        # diagonal sky wedge across the upper-left of the pane
        h = y1 - y0
        w = x1 - x0
        for i in range(int(h * 0.55)):
            t = i / max(1.0, h * 0.55)
            xa = x0 + int(w * (0.02 + 0.85 * t))
            p.over(x0, y0 + int(h * 0.06) + i, xa, y0 + int(h * 0.06) + i,
                   (226, 240, 250), 58)
    d = max(2, (x1 - x0) // 13)
    for i in range(d):
        a = int(255 * reveal * (1.0 - i / d) ** 1.25)
        p.over(x0 + i, y0 + i, x1 - i, y0 + i, (0, 0, 0), a)
        p.over(x0 + i, y0 + i, x0 + i, y1 - i, (0, 0, 0), a)
    p.over(x0 + d, y1 - 1, x1 - d, y1 - 1, (255, 255, 255), 46)


def mullion(p: Page, x0, y0, x1, y1, rgb, shine=40) -> None:
    p.rect(x0, y0, x1, y1, rgb, shine=shine)
    p.shadow_right(y0, y1, x1 + 1, 4, 0.34)


# ============================================================== facade pages
#
# Each `facade_*` draws ONE bay at (ox, oy); `build_facade` calls it four times
# with a per-cell index so the 2x2 grid never reads as a stamp. Everything is
# authored inside the bay, which keeps the page seamless for free.

def facade_clapboard(p: Page, lcg: Lcg, ox: int, oy: int, cell: int) -> None:
    """res_house — painted horizontal clapboard, double-hung sash, shutters."""
    B = BAY_PX
    wall = [(230, 222, 206), (222, 227, 220), (234, 218, 202), (224, 219, 209)][cell]
    step = 18
    for y in range(oy, oy + B, step):
        p.rect(ox, y, ox + B - 1, y + step - 4, shade(wall, 1.03), shine=0)
        p.rect(ox, y + step - 3, ox + B - 1, y + step - 1, shade(wall, 0.70), shine=0)
    wx0, wx1 = ox + 80, ox + 176
    wy0, wy1 = oy + 54, oy + 174
    trim = shade(wall, 1.13)
    p.rect(wx0 - 12, wy0 - 12, wx1 + 12, wy1 + 14, trim, shine=0)
    p.shadow_down(wx0 - 12, wx1 + 12, wy1 + 15, 9, 0.42)
    p.shadow_right(wy0 - 12, wy1 + 14, wx1 + 13, 8, 0.34)
    pane(p, wx0, wy0, wx1, wy1, (52, 66, 78), (24, 32, 41), reveal=0.62)
    mid = (wy0 + wy1) // 2
    p.rect(wx0, mid - 3, wx1, mid + 3, trim, shine=18)
    cx = (wx0 + wx1) // 2
    p.rect(cx - 2, wy0, cx + 2, wy1, trim, shine=18)
    p.rect(wx0 - 16, wy1 + 8, wx1 + 16, wy1 + 15, shade(wall, 1.2), shine=0)
    if cell in (1, 2):
        sh = [(94, 108, 96), (104, 96, 112)][cell - 1]
        for sx in (wx0 - 40, wx1 + 18):
            p.rect(sx, wy0 - 8, sx + 22, wy1 + 8, sh, shine=0)
            for i in range(4):
                yy = wy0 + i * 30
                p.rect(sx, yy, sx + 22, yy + 3, shade(sh, 0.68), shine=0)
            p.shadow_right(wy0 - 8, wy1 + 8, sx + 23, 5, 0.3)


def facade_brick(p: Page, lcg: Lcg, ox: int, oy: int, cell: int) -> None:
    """res_apartment — running-bond brick with a precast lintel and sill."""
    B = BAY_PX
    # Mortar sits close to the brick in value on purpose: at Z1 (87 m) a
    # high-contrast joint mips into a pink haze and the wall stops reading as
    # masonry at all.
    mortar = (176, 166, 152)
    base = [(158, 92, 70), (150, 84, 66), (164, 100, 76), (146, 88, 74)][cell]
    p.rect(ox, oy, ox + B - 1, oy + B - 1, mortar, shine=0)
    bw, bh = 26, 11
    row = 0
    for y in range(oy, oy + B, bh + 3):
        off = 0 if row % 2 == 0 else bw // 2
        for x in range(ox - bw, ox + B + bw, bw + 3):
            k = 0.86 + 0.30 * lcg.f()
            xa, xb = x + off, x + off + bw - 1
            if xb < ox or xa > ox + B - 1:
                continue
            p.rect(max(ox, xa), y, min(ox + B - 1, xb), y + bh - 1,
                   shade(base, k), shine=0)
        row += 1
    stone = (208, 202, 190)
    wx0, wx1 = ox + 70, ox + 186
    wy0, wy1 = oy + 48, oy + 184
    p.rect(wx0 - 10, wy0 - 20, wx1 + 10, wy0 - 6, stone, shine=0)
    p.shadow_down(wx0 - 10, wx1 + 10, wy0 - 5, 7, 0.36)
    pane(p, wx0, wy0, wx1, wy1, (62, 80, 94), (26, 36, 46), reveal=0.74)
    cx = (wx0 + wx1) // 2
    p.rect(cx - 3, wy0, cx + 3, wy1, (74, 76, 78), shine=26)
    p.rect(wx0 - 14, wy1 + 1, wx1 + 14, wy1 + 12, stone, shine=0)
    p.shadow_down(wx0 - 14, wx1 + 14, wy1 + 13, 11, 0.48)


def facade_tower(p: Page, lcg: Lcg, ox: int, oy: int, cell: int) -> None:
    """res_highrise — precast panel tower, strip window, and an alternating
    balcony slab (doc 11 §2.14: 'balcony ledge band every 2 floors')."""
    B = BAY_PX
    panel = [(196, 190, 178), (189, 184, 175), (201, 194, 181), (185, 181, 173)][cell]
    p.rect(ox, oy, ox + B - 1, oy + B - 1, panel, shine=0)
    p.rect(ox, oy, ox + 26, oy + B - 1, shade(panel, 1.07), shine=0)
    p.rect(ox + B - 27, oy, ox + B - 1, oy + B - 1, shade(panel, 0.90), shine=0)
    p.shadow_right(oy, oy + B - 1, ox + 27, 10, 0.30)
    p.rect(ox, oy + B - 4, ox + B - 1, oy + B - 2, shade(panel, 0.68), shine=0)
    wx0, wx1 = ox + 32, ox + B - 33
    wy0, wy1 = oy + 58, oy + 172
    pane(p, wx0, wy0, wx1, wy1, (86, 116, 130), (34, 52, 64), reveal=0.6, shine=248)
    for i in (1, 2):
        cx = wx0 + (wx1 - wx0) * i // 3
        mullion(p, cx - 3, wy0, cx + 3, wy1, (152, 154, 152), shine=40)
    p.rect(wx0, wy1 + 1, wx1, wy1 + 22, shade(panel, 0.80), shine=0)
    if oy == 0:   # the odd bay row carries the balcony slab
        p.rect(ox, oy + B - 30, ox + B - 1, oy + B - 12, shade(panel, 1.12), shine=0)
        p.shadow_down(ox, ox + B - 1, oy + B - 11, 13, 0.52)


def facade_storefront(p: Page, lcg: Lcg, ox: int, oy: int, cell: int) -> None:
    """com_retail — bay ROW 0 (the page's bottom half) is shopfront glazing
    under an awning; row 1 is the parapet sign band plus a clerestory. Because
    the shader pins bay row 0 to the bottom half, a 2-row store gets a real
    ground floor."""
    B = BAY_PX
    wall = (206, 198, 186)
    if oy >= BAY_PX:                              # ground floor
        p.rect(ox, oy, ox + B - 1, oy + B - 1, wall, shine=0)
        gx0, gx1 = ox + 14, ox + B - 15
        gy0, gy1 = oy + 60, oy + B - 22
        p.rect(gx0 - 8, gy0 - 8, gx1 + 8, gy1 + 8, (64, 66, 70), shine=0)
        pane(p, gx0, gy0, gx1, gy1, (112, 140, 150), (44, 62, 74),
             reveal=0.44, shine=250)
        for i in (1, 2, 3):
            cx = gx0 + (gx1 - gx0) * i // 4
            mullion(p, cx - 3, gy0, cx + 3, gy1, (192, 196, 198), shine=44)
        ty = gy0 + (gy1 - gy0) * 30 // 100      # transom, same reason as curtain
        p.rect(gx0, ty, gx1, ty + 6, (188, 192, 194), shine=26)
        p.shadow_down(gx0, gx1, ty + 7, 5, 0.34)
        p.rect(ox, oy + B - 22, ox + B - 1, oy + B - 1, (84, 82, 80), shine=0)
        p.rect(ox, oy + B - 22, ox + B - 1, oy + B - 20, (118, 116, 112), shine=0)
        aw = [(178, 76, 62), (56, 106, 122), (176, 118, 54), (86, 122, 78)][cell]
        p.rect(ox, oy + 30, ox + B - 1, oy + 56, aw, shine=0)
        for x in range(ox, ox + B, 32):
            p.rect(x, oy + 30, x + 15, oy + 56, shade(aw, 1.20), shine=0)
        p.shadow_down(ox, ox + B - 1, oy + 57, 18, 0.58)
        p.rect(ox, oy + 26, ox + B - 1, oy + 29, shade(wall, 0.72), shine=0)
    else:                                          # upper floor
        p.rect(ox, oy, ox + B - 1, oy + B - 1, shade(wall, 0.97), shine=0)
        band = (56, 60, 66)
        p.rect(ox, oy + 6, ox + B - 1, oy + 62, band, shine=0)
        p.rect(ox, oy + 6, ox + B - 1, oy + 12, shade(band, 1.7), shine=0)
        blk = [(216, 198, 122), (118, 190, 200), (216, 140, 120), (170, 200, 150)][cell]
        p.rect(ox + 30, oy + 24, ox + B - 31, oy + 44, blk, shine=90)
        p.shadow_down(ox, ox + B - 1, oy + 63, 11, 0.42)
        wx0, wx1 = ox + 26, ox + B - 27
        wy0, wy1 = oy + 98, oy + 186
        pane(p, wx0, wy0, wx1, wy1, (76, 102, 116), (32, 48, 60), reveal=0.62)
        cx = (wx0 + wx1) // 2
        mullion(p, cx - 3, wy0, cx + 3, wy1, (182, 184, 186), shine=40)
        p.rect(ox, oy + B - 8, ox + B - 1, oy + B - 5, shade(wall, 0.70), shine=0)


def facade_curtain(p: Page, lcg: Lcg, ox: int, oy: int, cell: int) -> None:
    """com_office / com_highrise — aluminium-and-glass curtain wall. The
    spandrel keeps the floor line legible after the glass goes dark at
    night."""
    B = BAY_PX
    frame = (176, 182, 186)
    p.rect(ox, oy, ox + B - 1, oy + B - 1, frame, shine=0)
    warm = [0.0, 0.10, -0.06, 0.04][cell]
    top = (c8(104 + 46 * warm), c8(140 + 26 * warm), c8(158 - 8 * warm))
    bot = (c8(36 + 28 * warm), c8(60 + 20 * warm), c8(78 - 6 * warm))
    gx0, gx1 = ox + 10, ox + B - 11
    gy0, gy1 = oy + 8, oy + B - 62
    pane(p, gx0, gy0, gx1, gy1, top, bot, reveal=0.34, shine=252)
    p.rect(ox, oy, ox + 9, oy + B - 1, shade(frame, 1.10), shine=0)
    p.rect(ox + B - 10, oy, ox + B - 1, oy + B - 1, shade(frame, 0.84), shine=0)
    p.shadow_right(gy0, gy1, ox + 10, 7, 0.40)
    for i in (1, 2):
        cx = gx0 + (gx1 - gx0) * i // 3
        mullion(p, cx - 3, gy0, cx + 3, gy1, shade(frame, 1.02), shine=56)
    # Transom. At Z2 a full-bay sheet of lit glass reads as a solid white
    # sticker; splitting it horizontally keeps the tower a grid at every zoom.
    ty = gy0 + (gy1 - gy0) * 45 // 100
    p.rect(gx0, ty, gx1, ty + 6, shade(frame, 0.98), shine=24)
    p.shadow_down(gx0, gx1, ty + 7, 5, 0.34)
    sp = (74, 84, 90)
    p.rect(ox, gy1 + 1, ox + B - 1, oy + B - 1, sp, shine=10)
    p.rect(ox, gy1 + 1, ox + B - 1, gy1 + 5, shade(sp, 1.6), shine=10)
    p.rect(ox, oy + B - 5, ox + B - 1, oy + B - 1, shade(sp, 0.62), shine=0)


def facade_civic(p: Page, lcg: Lcg, ox: int, oy: int, cell: int) -> None:
    """civ_* — cast-stone civic front: big panels, pilasters, deep reveals."""
    B = BAY_PX
    stone = [(214, 209, 194), (207, 203, 191), (219, 213, 199), (203, 200, 189)][cell]
    p.rect(ox, oy, ox + B - 1, oy + B - 1, stone, shine=0)
    p.rect(ox, oy, ox + B - 1, oy + 3, shade(stone, 0.76), shine=0)
    p.rect(ox, oy, ox + 3, oy + B - 1, shade(stone, 0.84), shine=0)
    p.rect(ox + B - 4, oy, ox + B - 1, oy + B - 1, shade(stone, 0.70), shine=0)
    p.rect(ox + 6, oy + 4, ox + 26, oy + B - 1, shade(stone, 1.06), shine=0)
    p.rect(ox + B - 27, oy + 4, ox + B - 6, oy + B - 1, shade(stone, 0.93), shine=0)
    p.shadow_right(oy + 4, oy + B - 1, ox + 27, 7, 0.28)
    wx0, wx1 = ox + 46, ox + B - 47
    wy0, wy1 = oy + 42, oy + 194
    p.rect(wx0 - 8, wy0 - 8, wx1 + 8, wy1 + 8, shade(stone, 0.88), shine=0)
    pane(p, wx0, wy0, wx1, wy1, (56, 70, 82), (22, 32, 42), reveal=0.82)
    cx = (wx0 + wx1) // 2
    p.rect(cx - 3, wy0, cx + 3, wy1, (212, 208, 198), shine=30)
    my = wy0 + (wy1 - wy0) // 3
    p.rect(wx0, my - 3, wx1, my + 3, (212, 208, 198), shine=30)
    p.rect(wx0 - 12, wy1 + 6, wx1 + 12, wy1 + 16, shade(stone, 1.16), shine=0)
    p.shadow_down(wx0 - 12, wx1 + 12, wy1 + 17, 12, 0.42)


def facade_utility(p: Page, lcg: Lcg, ox: int, oy: int, cell: int) -> None:
    """civ_utility / power / water / construction — ribbed industrial cladding
    with a small industrial sash set high in the bay."""
    B = BAY_PX
    steel = [(134, 144, 139), (127, 137, 133), (140, 148, 142), (123, 133, 130)][cell]
    for x in range(ox, ox + B, 16):
        p.rect(x, oy, x + 8, oy + B - 1, shade(steel, 1.10), shine=26)
        p.rect(x + 9, oy, x + 11, oy + B - 1, shade(steel, 0.76), shine=0)
        p.rect(x + 12, oy, x + 15, oy + B - 1, steel, shine=12)
    gy = oy + 152
    p.rect(ox, gy, ox + B - 1, gy + 9, shade(steel, 0.86), shine=0)
    p.shadow_down(ox, ox + B - 1, gy + 10, 6, 0.30)
    for x in range(ox + 8, ox + B, 32):
        p.rect(x, gy + 3, x + 3, gy + 6, shade(steel, 0.58), shine=0)
    wx0, wx1 = ox + 54, ox + B - 55
    wy0, wy1 = oy + 42, oy + 124
    p.rect(wx0 - 6, wy0 - 6, wx1 + 6, wy1 + 6, shade(steel, 1.16), shine=0)
    pane(p, wx0, wy0, wx1, wy1, (62, 78, 82), (26, 36, 42), reveal=0.72, shine=230)
    for i in (1, 2):
        cx = wx0 + (wx1 - wx0) * i // 3
        p.rect(cx - 2, wy0, cx + 2, wy1, (152, 160, 158), shine=24)
    my = (wy0 + wy1) // 2
    p.rect(wx0, my - 2, wx1, my + 2, (152, 160, 158), shine=24)
    p.shadow_down(wx0 - 6, wx1 + 6, wy1 + 7, 8, 0.34)
    # No hazard stripe here: the page repeats every 2 bays, so anything that
    # only belongs at grade would reappear on every second floor.


def facade_techpanel(p: Page, lcg: Lcg, ox: int, oy: int, cell: int) -> None:
    """tech_datacenter — windowless composite cassette panel with louvre
    banks. This is also what every data-center roof-prop side samples, which
    is right: the chiller boxes wear the same cladding."""
    B = BAY_PX
    dark = [(66, 72, 78), (61, 67, 73), (70, 76, 82), (58, 64, 70)][cell]
    p.rect(ox, oy, ox + B - 1, oy + B - 1, shade(dark, 0.7), shine=0)
    for gy in range(oy, oy + B, 64):
        for gx in range(ox, ox + B, 64):
            k = 0.94 + 0.16 * lcg.f()
            p.rect(gx + 2, gy + 2, gx + 61, gy + 61, shade(dark, k), shine=30)
            p.rect(gx + 2, gy + 2, gx + 61, gy + 3, shade(dark, 1.55), shine=40)
            p.rect(gx + 2, gy + 59, gx + 61, gy + 61, shade(dark, 0.58), shine=10)
    ly0, ly1 = oy + 86, oy + 170
    p.rect(ox + 20, ly0 - 6, ox + B - 21, ly1 + 6, shade(dark, 0.62), shine=0)
    for y in range(ly0, ly1, 12):
        p.rect(ox + 24, y, ox + B - 25, y + 6, shade(dark, 1.4), shine=60)
        p.rect(ox + 24, y + 7, ox + B - 25, y + 10, shade(dark, 0.42), shine=0)
    p.shadow_down(ox + 20, ox + B - 21, ly1 + 7, 8, 0.42)
    if cell == 1:
        p.rect(ox + 98, oy + 26, ox + 158, oy + 40, (86, 196, 168), shine=140)


FACADES = {
    "brick": (facade_brick, (156, 92, 72), 0.026),
    "civic": (facade_civic, (212, 207, 193), 0.030),
    "clapboard": (facade_clapboard, (228, 220, 204), 0.030),
    "curtain": (facade_curtain, (120, 150, 166), 0.016),
    "storefront": (facade_storefront, (204, 196, 184), 0.024),
    "techpanel": (facade_techpanel, (62, 68, 74), 0.024),
    "tower": (facade_tower, (194, 189, 178), 0.030),
    "utility": (facade_utility, (130, 140, 136), 0.028),
}


def build_facade(name: str) -> Image.Image:
    fn, base, spk = FACADES[name]
    lcg = Lcg(SEED ^ name_seed("facade:" + name))
    p = Page(PAGE, base, 0)
    for cell in range(4):                     # fixed order -> stable LCG stream
        fn(p, lcg, (cell % 2) * BAY_PX, (cell // 2) * BAY_PX, cell)
    p.noise(lcg, spk)
    return p.image()


# ================================================================ roof pages

def roof_shingle(p: Page, lcg: Lcg) -> None:
    # Chunky on purpose. A house is a 1x1 tile read from 20-90 m; authored at a
    # real 0.14 m course the pattern mips to a flat brown smear before the
    # camera ever gets close enough to count courses.
    base = (78, 70, 64)
    p.rect(0, 0, p.size - 1, p.size - 1, shade(base, 0.7), shine=0)
    step = 34
    row = 0
    for y in range(0, p.size, step):
        off = 0 if row % 2 == 0 else 40
        for x in range(-80, p.size + 80, 80):
            k = 0.88 + 0.30 * lcg.f()
            p.rect(x + off, y, x + off + 76, y + step - 5, shade(base, k), shine=0)
            p.rect(x + off, y, x + off + 76, y + 1, shade(base, k * 1.30), shine=0)
        p.shadow_down(0, p.size - 1, y + step - 4, 6, 0.7)
        row += 1


def roof_gravel(p: Page, lcg: Lcg) -> None:
    base = (116, 113, 105)
    p.rect(0, 0, p.size - 1, p.size - 1, base, shine=0)
    for _ in range(150):
        x = int(lcg.f() * p.size)
        y = int(lcg.f() * p.size)
        w = 8 + int(lcg.f() * 34)
        h = 8 + int(lcg.f() * 34)
        p.rect(x, y, x + w, y + h, shade(base, 0.80 + 0.38 * lcg.f()), shine=0)
    for y in range(0, p.size, 128):
        p.rect(0, y, p.size - 1, y + 5, shade(base, 0.70), shine=0)
        p.rect(0, y, p.size - 1, y + 1, shade(base, 1.22), shine=0)
    p.rect(196, 210, 236, 250, shade(base, 0.55), shine=40)
    p.rect(202, 216, 230, 244, (40, 42, 44), shine=70)
    p.shadow_down(196, 236, 251, 8, 0.4)


def roof_mech(p: Page, lcg: Lcg) -> None:
    base = (142, 145, 144)
    p.rect(0, 0, p.size - 1, p.size - 1, base, shine=0)
    for y in range(0, p.size, 64):
        for x in range(0, p.size, 64):
            p.rect(x + 2, y + 2, x + 61, y + 61,
                   shade(base, 0.93 + 0.14 * lcg.f()), shine=0)
    for y in range(0, p.size, 64):
        p.rect(0, y, p.size - 1, y + 1, shade(base, 0.72), shine=0)
    for x in range(0, p.size, 64):
        p.rect(x, 0, x + 1, p.size - 1, shade(base, 0.72), shine=0)
    p.rect(56, 60, 216, 172, shade(base, 0.86), shine=0)
    p.rect(64, 68, 208, 164, (98, 102, 106), shine=120)
    for x in range(72, 204, 14):
        p.rect(x, 74, x + 7, 158, (154, 160, 164), shine=180)
    p.shadow_down(56, 216, 173, 12, 0.5)
    p.shadow_right(60, 172, 217, 10, 0.42)
    p.rect(300, 320, 470, 350, (124, 128, 130), shine=150)
    p.shadow_down(300, 470, 351, 9, 0.45)
    p.rect(330, 90, 400, 160, shade(base, 1.06), shine=20)
    p.rect(342, 102, 388, 148, (86, 90, 94), shine=90)
    p.shadow_down(330, 400, 161, 10, 0.44)


def roof_metal(p: Page, lcg: Lcg) -> None:
    base = (120, 130, 128)
    for x in range(0, p.size, 32):
        p.rect(x, 0, x + 21, p.size - 1, base, shine=40)
        p.rect(x + 22, 0, x + 27, p.size - 1, shade(base, 1.24), shine=170)
        p.rect(x + 28, 0, x + 31, p.size - 1, shade(base, 0.70), shine=16)
    for y in range(0, p.size, 256):
        p.rect(0, y, p.size - 1, y + 4, shade(base, 0.78), shine=24)
        for x in range(6, p.size, 32):
            p.rect(x, y + 1, x + 3, y + 3, shade(base, 0.52), shine=0)


ROOFS = {
    "gravel": (roof_gravel, (116, 113, 105), 0.038),
    "mech": (roof_mech, (142, 145, 144), 0.026),
    "metal": (roof_metal, (120, 130, 128), 0.020),
    "shingle": (roof_shingle, (84, 73, 64), 0.030),
}


def build_roof(name: str) -> Image.Image:
    fn, base, spk = ROOFS[name]
    lcg = Lcg(SEED ^ name_seed("roof:" + name))
    p = Page(ROOF_PAGE, base, 0)
    fn(p, lcg)
    p.noise(lcg, spk)
    return p.image()


# ============================================================== ground pages

def ground_asphalt(p: Page, lcg: Lcg) -> None:
    base = (58, 59, 64)
    p.rect(0, 0, p.size - 1, p.size - 1, base, shine=0)
    for _ in range(1100):
        x = int(lcg.f() * p.size)
        y = int(lcg.f() * p.size)
        s = 1 + int(lcg.f() * 3)
        p.rect(x, y, x + s, y + s, shade(base, 0.76 + 0.52 * lcg.f()), shine=0)
    for i in range(40):
        a = int(26 * (1.0 - abs(i - 20) / 20.0))
        p.over(96 + i * 2, 0, 96 + i * 2, p.size - 1, (255, 255, 255), a)
        p.over(336 + i * 2, 0, 336 + i * 2, p.size - 1, (255, 255, 255), a)
    p.rect(0, 250, p.size - 1, 253, shade(base, 0.74), shine=0)
    p.rect(252, 0, 255, p.size - 1, shade(base, 0.78), shine=0)


def ground_pavement(p: Page, lcg: Lcg) -> None:
    base = (130, 128, 122)
    p.rect(0, 0, p.size - 1, p.size - 1, base, shine=0)
    for y in range(0, p.size, 128):
        for x in range(0, p.size, 128):
            p.rect(x + 3, y + 3, x + 124, y + 124,
                   shade(base, 0.94 + 0.13 * lcg.f()), shine=0)
            p.rect(x + 3, y + 3, x + 124, y + 5, shade(base, 1.13), shine=0)
            p.rect(x + 3, y + 121, x + 124, y + 124, shade(base, 0.82), shine=0)
    for y in range(0, p.size, 128):
        p.rect(0, y, p.size - 1, y + 2, shade(base, 0.68), shine=0)
    for x in range(0, p.size, 128):
        p.rect(x, 0, x + 2, p.size - 1, shade(base, 0.68), shine=0)


GROUNDS = {
    "asphalt": (ground_asphalt, (58, 59, 64), 0.030),
    "pavement": (ground_pavement, (130, 128, 122), 0.028),
}


def build_ground(name: str) -> Image.Image:
    fn, base, spk = GROUNDS[name]
    lcg = Lcg(SEED ^ name_seed("ground:" + name))
    p = Page(ROOF_PAGE, base, 0)
    fn(p, lcg)
    p.noise(lcg, spk)
    return p.image()


# =============================================================== prop pages
#
# The non-building world: construction hoarding, crane lattice, scaffold tube,
# stockpiles, streetlight poles. Every consumer multiplies the page by a VERTEX
# or INSTANCE colour it already had (safety orange, crane yellow, timber brown,
# galvanised grey), so these pages are authored as near-neutral VALUE — light
# where the material catches the sky, dark in the joints — and the colour still
# comes from the same place it always did. That is what lets one steel page
# serve a yellow crane leg, a grey scaffold standard and a lamp post.

def prop_hoarding(p: Page, lcg: Lcg) -> None:
    """One printed site-hoarding panel, drawn end to end: the page IS the panel
    (u and v both run 0..1 across it) rather than a tile, which is what puts the
    hazard band at a fixed height above the pavement instead of wherever the
    repeat happens to land. Value only — ConstructionSiteView tints one panel in
    `fence_accent_every` safety orange and the rest hoarding grey."""
    S = p.size
    board = (206, 208, 205)
    p.rect(0, 0, S - 1, S - 1, board, shine=0)
    # Three ply sheets across the panel, each a shade off its neighbour.
    for i in range(3):
        x0 = S * i // 3
        x1 = S * (i + 1) // 3 - 1
        p.rect(x0, 0, x1, S - 1, shade(board, 0.95 + 0.07 * lcg.f()), shine=0)
        p.rect(x1 - 3, 0, x1, S - 1, shade(board, 0.72), shine=0)      # seam
        p.rect(x0, 0, x0 + 2, S - 1, shade(board, 1.08), shine=0)      # lit edge
    # Top and bottom rails, with the bolt line that reads as fixings at 30 m.
    for ry, rh in ((0, 46), (S - 54, 54)):
        p.rect(0, ry, S - 1, ry + rh, shade(board, 0.86), shine=30)
        p.rect(0, ry, S - 1, ry + 4, shade(board, 1.14), shine=40)
        p.shadow_down(0, S - 1, ry + rh + 1, 10, 0.40)
        for x in range(26, S, 96):
            p.rect(x, ry + rh // 2 - 5, x + 9, ry + rh // 2 + 4,
                   shade(board, 1.20), shine=60)
            p.rect(x + 1, ry + rh // 2 - 1, x + 9, ry + rh // 2 + 4,
                   shade(board, 0.62), shine=10)
    # The hazard band: 45° bars, drawn row by row so the diagonal is exact and
    # the page needs no rotation pass. Alternating value, not alternating hue —
    # the instance tint decides whether this ends up orange/black or grey/black.
    by0, by1 = int(S * 0.56), int(S * 0.78)
    p.rect(0, by0 - 6, S - 1, by0 - 1, shade(board, 0.66), shine=0)
    p.rect(0, by1 + 1, S - 1, by1 + 6, shade(board, 0.66), shine=0)
    period = 68
    for y in range(by0, by1 + 1):
        off = y - by0
        for x in range(-period * 2, S + period * 2, period):
            xa = x + off
            p.rect(xa, y, xa + period // 2 - 1, y, shade(board, 1.16), shine=0)
            p.rect(xa + period // 2, y, xa + period - 1, y,
                   shade(board, 0.34), shine=0)
    p.shadow_down(0, S - 1, by1 + 7, 8, 0.30)
    # Weathering: rain streaks off the top rail, a splash line at grade, and
    # scuffs where plant has clipped it.
    for _ in range(70):
        x = int(lcg.f() * S)
        w = 1 + int(lcg.f() * 4)
        h = 60 + int(lcg.f() * (S * 0.55))
        p.over(x, 50, x + w, 50 + h, (58, 54, 48), 14 + int(lcg.f() * 26))
    for _ in range(120):
        x = int(lcg.f() * S)
        y = S - 70 + int(lcg.f() * 66)
        s = 2 + int(lcg.f() * 7)
        p.over(x, y, x + s, y + s, (74, 62, 48), 30 + int(lcg.f() * 60))
    for _ in range(9):
        x = int(lcg.f() * S)
        y = int(S * 0.30 + lcg.f() * S * 0.55)
        w = 14 + int(lcg.f() * 60)
        p.over(x, y, x + w, y + 2 + int(lcg.f() * 3), (250, 250, 250), 40)
    p.rect(0, S - 8, S - 1, S - 1, shade(board, 0.52), shine=0)


def prop_steel(p: Page, lcg: Lcg) -> None:
    """Hot-dip galvanised: spangle, a drawn vertical grain, and — the reason
    this page exists — horizontal AO bands every half metre. A crane leg is a
    0.22 m square beam with four flat faces and no geometry to catch light; the
    bands are what give it segments and therefore depth, and they land at the
    same physical pitch on a scaffold standard and a lamp post because the page
    is tiled in metres."""
    S = p.size
    steel = (176, 180, 183)
    p.rect(0, 0, S - 1, S - 1, steel, shine=90)
    # Spangle: many SMALL crystal facets at low contrast. The earlier draft used
    # 260 big ones and the page came out reading as breeze block — a galvanised
    # surface is a fine crystalline scatter, and the moment a facet is bigger
    # than the beam it lands on it stops being a surface and becomes a stain.
    for _ in range(900):
        x = int(lcg.f() * S)
        y = int(lcg.f() * S)
        w = 4 + int(lcg.f() * 16)
        h = 3 + int(lcg.f() * 13)
        p.over(x, y, x + w, y + h,
               (255, 255, 255) if lcg.f() < 0.5 else (24, 30, 36),
               12 + int(lcg.f() * 26))
    # Drawn grain, vertical: the mill direction. Low contrast but continuous, so
    # a minified beam keeps a lengthwise read instead of dissolving to flat grey.
    for x in range(0, S, 5):
        up = lcg.f() < 0.5
        p.over(x, 0, x + 1, S - 1, (255, 255, 255) if up else (0, 0, 0),
               6 + int(lcg.f() * 14))
    # The AO bands: a joint line, its shadow below and its catch-light above.
    band = S // 4                       # 0.5 m at PROP_TILE_M = 2.0
    for y in range(0, S, band):
        p.rect(0, y, S - 1, y + 2, shade(steel, 0.56), shine=40)
        p.shadow_down(0, S - 1, y + 3, 14, 0.42)
        p.light_up(0, S - 1, y - 1, 8, 0.30)
    # Rust freckles where the coating has been kicked off. Sparse and low —
    # visible on a 512 px page, invisible on a 0.22 m leg at 80 m, which is
    # exactly the budget a weathering pass gets.
    for _ in range(70):
        x = int(lcg.f() * S)
        y = int(lcg.f() * S)
        s = 2 + int(lcg.f() * 7)
        p.over(x, y, x + s, y + s, (126, 78, 46), 26 + int(lcg.f() * 44))


def prop_stock(p: Page, lcg: Lcg) -> None:
    """Bulk site material: coarse aggregate grain with strap bands across it.
    One page for the timber bundles, the aggregate ridge and the skip, because
    all three are the same read at 30–150 m — a heap of stuff with banding — and
    the vertex colour already separates them into brown, grey-brown and green."""
    S = p.size
    base = (172, 168, 160)
    p.rect(0, 0, S - 1, S - 1, base, shine=0)
    for _ in range(1400):
        x = int(lcg.f() * S)
        y = int(lcg.f() * S)
        s = 2 + int(lcg.f() * 9)
        p.rect(x, y, x + s, y + s, shade(base, 0.70 + 0.56 * lcg.f()), shine=0)
    for _ in range(90):
        x = int(lcg.f() * S)
        y = int(lcg.f() * S)
        w = 12 + int(lcg.f() * 30)
        h = 8 + int(lcg.f() * 20)
        p.rect(x, y, x + w, y + h, shade(base, 0.74 + 0.42 * lcg.f()), shine=0)
        p.rect(x, y, x + w, y + 1, shade(base, 1.24), shine=0)
        p.shadow_down(x, x + w, y + h + 1, 5, 0.44)
    # Strap / course bands: what makes a tinted box read as a BUNDLE rather than
    # a painted crate.
    for y in range(0, S, S // 4):
        p.rect(0, y, S - 1, y + 3, shade(base, 0.60), shine=0)
        p.rect(0, y + 4, S - 1, y + 5, shade(base, 1.18), shine=20)
        p.shadow_down(0, S - 1, y + 6, 7, 0.34)


PROPS = {
    "hoarding": (prop_hoarding, (204, 206, 203), 0.030),
    "steel": (prop_steel, (176, 180, 183), 0.026),
    "stock": (prop_stock, (172, 168, 160), 0.040),
}


def build_prop(name: str) -> Image.Image:
    fn, base, spk = PROPS[name]
    lcg = Lcg(SEED ^ name_seed("prop:" + name))
    p = Page(PROP_PAGE, base, 0)
    fn(p, lcg)
    p.noise(lcg, spk)
    return p.image()


# ========================================================== vehicle atlas
#
# Four cells, one page, ONE extra texture fetch on the whole traffic layer.
# `game/render/vehicle_mesh.gd` writes UV2 = cell + the face's own [0,1]
# coordinate (inset), so a cell is a MATERIAL, not a tile: the paint cell covers
# a car door once, the glass cell covers a windscreen once, and the reflection
# gradient therefore runs the right way up on both.
#
#   (0,0) paint   (1,0) glass
#   (0,1) dark    (1,1) livery
#
# A = the shine mask, exactly as on the façade pages: it drives ROUGHNESS and
# SPECULAR, so glass is glossy and rubber is dead without a second texture.

def veh_paint(p: Page, lcg: Lcg) -> None:
    """Automotive paint. Near-white because the PAINT is the instance colour —
    everything here is the metallic fleck, the clear-coat sheen and a whisper of
    panel curvature, which is what stops 200 cars reading as 200 flat chips."""
    S = p.size
    base = (238, 239, 241)
    p.rect(0, 0, S - 1, S - 1, base, shine=55)
    # Metallic fleck. Authored at 3 px so it survives the first mip.
    for _ in range(2600):
        x = int(lcg.f() * S)
        y = int(lcg.f() * S)
        s = 1 + int(lcg.f() * 3)
        k = 0.93 + 0.13 * lcg.f()
        p.rect(x, y, x + s, y + s, shade(base, k), shine=None)
    # Panel curvature: a soft bright sweep across the upper third and a darker
    # sill. Deliberately weak (a few per cent) — the cell lands on roofs, doors
    # and bonnets alike and must not read as a baked light direction.
    for i in range(S // 3):
        t = i / float(S // 3)
        p.over(0, i, S - 1, i, (255, 255, 255), int(26 * (1.0 - t)))
    for i in range(S // 5):
        t = i / float(S // 5)
        p.over(0, S - 1 - i, S - 1, S - 1 - i, (0, 0, 0), int(30 * (1.0 - t)))
    # Clear-coat highlight: one soft diagonal wedge.
    for i in range(S):
        w = int(S * 0.16)
        x0 = int(S * 0.10) + int(i * 0.55)
        p.over(x0, i, x0 + w, i, (255, 255, 255), 16)


def veh_glass(p: Page, lcg: Lcg) -> None:
    """Glazing with the reflection BAKED IN: sky down the top, the dark cabin
    below it, one horizontal sweep where the far side of the street lands. This
    is what a car has instead of a reflection probe — §2.11 gates the one probe
    the game may own to High and to the city at large."""
    S = p.size
    # Deliberately NOT a bright sky: the shine mask already drives a low
    # roughness, and at 0.64 luma the first draft turned a raked windscreen into
    # a silver wedge every time the sun caught it. The gradient has to read as
    # glass at 30 m, not as chrome.
    sky = (92, 108, 128)
    deep = (16, 20, 28)
    p.vgrad(0, 0, S - 1, S - 1, sky, deep, shine=235)
    # Horizon sweep — the buildings opposite, as one soft band.
    p.rect(0, int(S * 0.34), S - 1, int(S * 0.44), (48, 58, 70), shine=240)
    for i in range(10):
        p.over(0, int(S * 0.44) + i, S - 1, int(S * 0.44) + i, (0, 0, 0),
               int(60 * (1.0 - i / 10.0)))
    # A diagonal sheen off the upper left, the same wedge the façade panes use.
    # Weak: glass is an ALBEDO of about 0.08 in the real world and the shine mask
    # is already buying it a low roughness. Two drafts of this cell were rejected
    # for turning the raked screens into silver wedges — a car's glass has to
    # read DARK from a 45° city camera or the whole fleet looks chromed.
    for i in range(int(S * 0.62)):
        t = i / (S * 0.62)
        xa = int(S * (0.02 + 0.80 * t))
        p.over(0, i, xa, i, (208, 226, 242), 30)
    # Frit band along the bottom edge — the black ceramic border on a real
    # screen, and the thing that stops the glass quad glowing at its sill.
    p.rect(0, S - 26, S - 1, S - 1, (18, 22, 30), shine=200)
    p.light_up(0, S - 1, S - 28, 6, 0.22)
    for _ in range(24):
        x = int(lcg.f() * S)
        y = int(lcg.f() * S * 0.9)
        w = 20 + int(lcg.f() * 90)
        p.over(x, y, x + w, y + 1 + int(lcg.f() * 2), (255, 255, 255), 26)


def veh_dark(p: Page, lcg: Lcg) -> None:
    """Rubber and dark trim: tyre tread ribs, a sidewall ring and the grain of
    moulded plastic. Authored near white for the same reason as the paint cell —
    `VehicleMesh.TYRE` and `TRIM` are the colours, this is only the surface."""
    S = p.size
    base = (228, 228, 230)
    p.rect(0, 0, S - 1, S - 1, base, shine=10)
    # Tread ribs across the cell, with a shoulder either side.
    for x in range(0, S, 26):
        p.rect(x, 0, x + 15, S - 1, shade(base, 1.06), shine=8)
        p.rect(x + 16, 0, x + 25, S - 1, shade(base, 0.70), shine=0)
    p.rect(0, 0, S - 1, 22, shade(base, 0.84), shine=14)
    p.rect(0, S - 23, S - 1, S - 1, shade(base, 0.84), shine=14)
    p.shadow_down(0, S - 1, 23, 10, 0.34)
    p.shadow_up(0, S - 1, S - 24, 10, 0.34)
    for _ in range(700):
        x = int(lcg.f() * S)
        y = int(lcg.f() * S)
        s = 1 + int(lcg.f() * 3)
        p.rect(x, y, x + s, y + s, shade(base, 0.88 + 0.20 * lcg.f()), shine=None)


def veh_livery(p: Page, lcg: Lcg) -> None:
    """Department livery: a battenburg block band and an emblem roundel. VALUE
    only and deliberately WORDLESS — the stripe is drawn light/dark and the
    department's own colour arrives as the vertex tint, so police blue, fire
    silver, ambulance red and utility amber all come off this one cell. Doc 12's
    rule against baked text in a texture is why the emblem is a roundel and not
    a badge with a name on it: it never has to be translated and it never turns
    into three grey pixels of noise at 150 m."""
    S = p.size
    base = (242, 242, 244)
    p.rect(0, 0, S - 1, S - 1, base, shine=45)
    # Battenburg: two rows of blocks, offset, occupying the middle of the panel.
    # The blocks are BIG — a livery cell is stretched across a 2 m door and a
    # 4 m locker line alike, and at S/6 the first draft came out as a picket
    # fence of thin bars that read as graffiti rather than as a service marking.
    y0, y1 = int(S * 0.28), int(S * 0.72)
    mid = (y0 + y1) // 2
    block = S // 4
    p.rect(0, y0, S - 1, y1, shade(base, 0.98), shine=50)
    for row, ry0, ry1 in ((0, y0, mid - 1), (1, mid, y1)):
        for i, x in enumerate(range(-block, S + block, block)):
            xa = x + (block // 2 if row else 0)
            if (i + row) % 2 == 0:
                p.rect(xa, ry0, xa + block - 1, ry1, shade(base, 0.40), shine=30)
    p.rect(0, y0 - 5, S - 1, y0 - 1, shade(base, 0.62), shine=30)
    p.rect(0, y1 + 1, S - 1, y1 + 5, shade(base, 0.62), shine=30)
    p.shadow_down(0, S - 1, y1 + 6, 9, 0.32)
    # Emblem: a filled roundel inside a ring, a fifth along the panel. Crude on
    # purpose — three concentric value steps is everything that survives to 150 m
    # and everything a crest needs to read as a crest.
    cx, cy, r = int(S * 0.20), (y0 + y1) // 2, int(S * 0.16)
    for dy in range(-r, r + 1):
        half = int((r * r - dy * dy) ** 0.5)
        p.rect(cx - half, cy + dy, cx + half, cy + dy, shade(base, 1.10), shine=70)
    r2 = int(r * 0.74)
    for dy in range(-r2, r2 + 1):
        half = int((r2 * r2 - dy * dy) ** 0.5)
        p.rect(cx - half, cy + dy, cx + half, cy + dy, shade(base, 0.30), shine=30)
    r3 = int(r * 0.44)
    for dy in range(-r3, r3 + 1):
        half = int((r3 * r3 - dy * dy) ** 0.5)
        p.rect(cx - half, cy + dy, cx + half, cy + dy, shade(base, 1.16), shine=80)
    # Reflective chevron tape, confined to the trailing fifth so it never
    # crowds the battenburg blocks.
    for i, x in enumerate(range(int(S * 0.80), S, 26)):
        p.rect(x, y0 + 4, x + 12, y1 - 4, shade(base, 1.14 if i % 2 else 0.50),
               shine=110)
    for _ in range(40):
        x = int(lcg.f() * S)
        y = int(lcg.f() * S)
        s = 3 + int(lcg.f() * 12)
        p.over(x, y, x + s, y + s, (70, 66, 60), 16 + int(lcg.f() * 22))


VEHICLE_CELLS = [
    # (cell x, cell y, builder, base rgb, base shine, noise)
    (0, 0, veh_paint, (238, 239, 241), 55, 0.014),
    (1, 0, veh_glass, (94, 110, 128), 235, 0.010),
    (0, 1, veh_dark, (228, 228, 230), 10, 0.022),
    (1, 1, veh_livery, (242, 242, 244), 45, 0.014),
]


def build_vehicle_atlas() -> Image.Image:
    """Each cell is authored as its OWN page and pasted, which is what makes it
    seamless inside itself and independent of its neighbours — the atlas never
    wraps across a cell boundary because no UV ever leaves its cell."""
    out = Image.new("RGBA", (VEHICLE_PAGE, VEHICLE_PAGE))
    for cx, cy, fn, base, shine, spk in VEHICLE_CELLS:
        lcg = Lcg(SEED ^ name_seed("vehicle:%d,%d" % (cx, cy)))
        p = Page(VEHICLE_CELL, base, shine)
        fn(p, lcg)
        p.noise(lcg, spk)
        out.paste(p.image(), (cx * VEHICLE_CELL, cy * VEHICLE_CELL))
    return out


# ------------------------------------------------------ archetype -> surface
#
# Keyed by the archetype ids in game/meshes/generated/manifest.json. `family`
# is the fallback for anything not listed, so a new archetype still gets a sane
# surface the day it lands.

ARCHETYPE_SURFACE = {
    "apartment":         {"facade": "brick",      "roof": "gravel"},
    "construction_yard": {"facade": "utility",    "roof": "metal"},
    "data_center":       {"facade": "techpanel",  "roof": "metal"},
    "fire_station":      {"facade": "civic",      "roof": "gravel"},
    "high_rise":         {"facade": "tower",      "roof": "mech"},
    "house":             {"facade": "clapboard",  "roof": "shingle"},
    "office":            {"facade": "curtain",    "roof": "mech"},
    "police_station":    {"facade": "civic",      "roof": "gravel"},
    "power_facility":    {"facade": "utility",    "roof": "metal"},
    "store":             {"facade": "storefront", "roof": "gravel"},
    "substation":        {"facade": "utility",    "roof": "metal"},
    "water_facility":    {"facade": "utility",    "roof": "metal"},
}

FAMILY_SURFACE = {
    "civic":       {"facade": "civic",     "roof": "gravel"},
    "commercial":  {"facade": "curtain",   "roof": "mech"},
    "industrial":  {"facade": "utility",   "roof": "metal"},
    "residential": {"facade": "brick",     "roof": "gravel"},
    "tech":        {"facade": "techpanel", "roof": "metal"},
}


# --------------------------------------------------------------------- io

def png_bytes(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=False, compress_level=9)
    return buf.getvalue()


def render_manifest(pages: dict) -> str:
    doc = {
        "generator": GENERATOR,
        "generator_version": GENERATOR_VERSION,
        "seed": SEED,
        "bay_px": BAY_PX,
        "page_px": PAGE,
        "bay_m": list(BAY_M),
        "roof_tile_m": ROOF_TILE_M,
        "note": ("facade pages are a seamless 2x2 grid of window bays; bay row "
                 "0 (ground floor) maps to the page's bottom half. RGB = albedo "
                 "with baked shading, A = shine/glass mask."),
        "prop_tile_m": PROP_TILE_M,
        "hoarding_panel_m": list(HOARDING_PANEL_M),
        "prop_note": ("prop pages are tiled in METRES at prop_tile_m and are "
                      "authored as near-neutral VALUE: the consumer's existing "
                      "vertex/instance colour is still the colour. `hoarding` is "
                      "the exception - it is ONE panel, u and v run 0..1 across "
                      "it, so the hazard band sits at a fixed height."),
        "vehicle_page_px": VEHICLE_PAGE,
        "vehicle_cell_px": VEHICLE_CELL,
        "vehicle_uv_inset": VEHICLE_UV_INSET,
        "vehicle_cells": {"paint": [0, 0], "glass": [1, 0],
                          "dark": [0, 1], "livery": [1, 1]},
        "vehicle_note": ("UV2 on a vehicle body is cell + the face's own [0,1] "
                         "coordinate, inset by vehicle_uv_inset. A cell is a "
                         "MATERIAL, never a tile - no UV ever leaves its cell, "
                         "which is what keeps a mip from bleeding the glass cell "
                         "into a car door."),
        "facades": pages["facades"],
        "roofs": pages["roofs"],
        "grounds": pages["grounds"],
        "props": pages["props"],
        "vehicles": pages["vehicles"],
        "archetype_surface": ARCHETYPE_SURFACE,
        "family_surface": FAMILY_SURFACE,
    }
    return json.dumps(doc, indent="\t", sort_keys=False) + "\n"


# `.import` sidecars are committed so a fresh clone renders without an editor
# round-trip. The three rows that matter are `compress/mode=2` (VRAM — the
# project sets `textures/vram_compression/import_etc2_astc`, doc 13's Android
# target), `mipmaps/generate=true` (a 512 px bay is ~1 px at Z2; without mips
# the skyline crawls) and `detect_3d/compress_to=0` (already VRAM, so Godot
# must not re-decide on first 3D use). The `uid` line is deliberately absent:
# Godot mints and stamps one on first import, which keeps this text stable.
IMPORT_TEMPLATE = """[remap]

importer="texture"
type="CompressedTexture2D"
path.s3tc="res://.godot/imported/{base}-{md5}.s3tc.ctex"
path.etc2="res://.godot/imported/{base}-{md5}.etc2.ctex"
metadata={{
"imported_formats": ["s3tc_bptc", "etc2_astc"],
"vram_texture": true
}}

[deps]

source_file="res://{res_path}"
dest_files=["res://.godot/imported/{base}-{md5}.s3tc.ctex", "res://.godot/imported/{base}-{md5}.etc2.ctex"]

[params]

compress/mode=2
compress/high_quality=false
compress/lossy_quality=0.7
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression=1
compress/normal_map=0
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/channel_remap/red=0
process/channel_remap/green=1
process/channel_remap/blue=2
process/channel_remap/alpha=3
process/fix_alpha_border=false
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=0
"""


def import_text(res_path: str) -> str:
    md5 = hashlib.md5(res_path.encode("utf-8")).hexdigest()
    base = os.path.basename(res_path)
    return IMPORT_TEMPLATE.format(base=base, md5=md5, res_path=res_path)


# --------------------------------------------------------------------- main

def generate() -> dict:
    """Everything the tool produces, as {file name: bytes}."""
    out = {}
    pages = {"facades": {}, "roofs": {}, "grounds": {}, "props": {},
             "vehicles": {}}
    groups = (
        ("facades", "facade_%s.png", sorted(FACADES), build_facade),
        ("roofs", "roof_%s.png", sorted(ROOFS), build_roof),
        ("grounds", "ground_%s.png", sorted(GROUNDS), build_ground),
        ("props", "prop_%s.png", sorted(PROPS), build_prop),
        ("vehicles", "vehicle_%s.png", ["atlas"],
         lambda _name: build_vehicle_atlas()),
    )
    for key, pattern, names, builder in groups:
        for name in names:
            data = png_bytes(builder(name))
            fn = pattern % name
            out[fn] = data
            pages[key][name] = {
                "path": "res://game/textures/generated/" + fn,
                "sha256": hashlib.sha256(data).hexdigest(),
            }
    out["manifest.json"] = render_manifest(pages).encode("utf-8")
    for fn in sorted(k for k in out if k.endswith(".png")):
        out[fn + ".import"] = import_text(
            "game/textures/generated/" + fn).encode("utf-8")
    return out


def main() -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir",
                    default=os.path.join(root, "game", "textures", "generated"))
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    files = generate()
    pngs = [k for k in files if k.endswith(".png")]

    if args.check:
        bad = []
        for name in sorted(files):
            if name.endswith(".import"):
                continue      # Godot re-stamps uid/metadata lines on import
            path = os.path.join(args.out_dir, name)
            if not os.path.exists(path):
                bad.append("%s missing" % name)
                continue
            if name.endswith(".png"):
                # compare decoded pixels, not the container: another Pillow
                # build may pick different zlib blocks for identical art
                want = Image.open(io.BytesIO(files[name])).convert("RGBA")
                have = Image.open(path).convert("RGBA")
                if want.size != have.size or want.tobytes() != have.tobytes():
                    bad.append("%s differs from its generator" % name)
            elif open(path, "rb").read() != files[name]:
                bad.append("%s differs from its generator" % name)
        if bad:
            print("gen_textures: %d FAILURES" % len(bad), file=sys.stderr)
            for b in bad:
                print("  FAIL %s" % b, file=sys.stderr)
            return 1
        print("gen_textures: %d pages + manifest in sync (--check)" % len(pngs))
        return 0

    os.makedirs(args.out_dir, exist_ok=True)
    for name in sorted(files):
        path = os.path.join(args.out_dir, name)
        if name.endswith(".import") and os.path.exists(path):
            continue          # never clobber an .import Godot already re-stamped
        with open(path, "wb") as f:
            f.write(files[name])
    print("gen_textures: wrote %d pages + manifest to %s" % (len(pngs), args.out_dir))
    print("  facades: %s" % ", ".join(sorted(FACADES)))
    print("  roofs:   %s" % ", ".join(sorted(ROOFS)))
    print("  grounds: %s" % ", ".join(sorted(GROUNDS)))
    print("  props:   %s" % ", ".join(sorted(PROPS)))
    print("  vehicles: atlas (%d px, %d px cells)" % (VEHICLE_PAGE, VEHICLE_CELL))
    print("  next:    ~/.local/bin/godot --headless --path . --import")
    return 0


if __name__ == "__main__":
    sys.exit(main())
