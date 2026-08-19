#!/usr/bin/env python3
"""Slacum City brand mark generator — app icon, adaptive icons, boot splash.

Deterministic: no RNG, no system fonts, no network. Every shape is authored
below in a single skyline coordinate system, so the launcher icon is literally
a crop of the boot splash's skyline and the two read as one mark.

The mark is the game's promise in one image: a blacked-out city, and one
window still burning amber. "You built it. Now keep it alive."

Coordinate system (SKYLINE): x grows right in the same units as y, y = 0 is
the top of the tallest spire and y = 1.0 is the ground line. A render maps a
crop window of that space onto a pixel box, preserving aspect.

Usage:
    python3 tools/gen_icon.py [--out-root .]

Outputs (paths relative to the project root):
    icon.png                        512x512  project icon / Play store master
    game/branding/icon_192.png      192x192  legacy Android launcher icon
    game/branding/icon_fg_432.png   432x432  adaptive foreground (transparent)
    game/branding/icon_bg_432.png   432x432  adaptive background (opaque)
    game/branding/icon_mono_432.png 432x432  adaptive monochrome (themed icons)
    game/branding/splash.png       1280x720  boot splash
"""

from __future__ import annotations

import argparse
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter

# --------------------------------------------------------------------------
# Palette — "blackout blue": a night sky with the power out, and one amber
# window. Sky brightens toward the horizon (distant city glow), buildings are
# near-black, so the silhouette reads even at 48 dp.
# --------------------------------------------------------------------------
SKY_TOP = (7, 15, 28)
SKY_HORIZON = (38, 76, 120)
GROUND = (4, 7, 13)
SILHOUETTE = (4, 8, 15)
WINDOW_DARK = (19, 36, 57)
AMBER = (255, 176, 42)
AMBER_CORE = (255, 238, 198)
AMBER_GLOW = (255, 146, 32)
WORDMARK = (226, 234, 244)
TAGLINE = (128, 150, 178)

# --------------------------------------------------------------------------
# Geometry
# --------------------------------------------------------------------------
# (x0, width, roof_y, crown) — crown in {None, "step", "spire"}.
TOWERS = [
    (0.00, 0.30, 0.72, None),
    (0.28, 0.22, 0.60, None),
    (0.48, 0.34, 0.44, "step"),
    (0.80, 0.26, 0.66, None),
    (1.04, 0.30, 0.52, None),
    (1.32, 0.24, 0.34, "step"),
    (1.54, 0.40, 0.20, "spire"),  # hero — carries the lit window
    (1.92, 0.28, 0.42, None),
    (2.18, 0.30, 0.56, None),
    (2.46, 0.26, 0.30, "step"),
    (2.70, 0.34, 0.50, None),
    (3.02, 0.24, 0.66, None),
    (3.24, 0.36, 0.38, "step"),
    (3.58, 0.28, 0.58, None),
    (3.84, 0.36, 0.46, None),
]
HERO = 6
SKYLINE_WIDTH = 4.20
GROUND_Y = 1.0

# The lit window: hero tower, column 2 of 4, third row down.
LIT_COL = 2
LIT_ROW = 2

# Window grid metrics, in skyline units.
WIN_PITCH_X = 0.118
WIN_W = 0.062
WIN_PITCH_Y = 0.098
WIN_H = 0.052
WIN_TOP_PAD = 0.058
WIN_BOTTOM_PAD = 0.048

# Icon crop: five towers, hero just left of centre, both edge towers cut so the
# city reads as continuing past the frame.
ICON_CROP = (1.24, 2.35)
ICON_TOP = 0.02

SS = 4  # supersample factor; every canvas is drawn 4x and box-filtered down


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def mix(c0, c1, t: float):
    return tuple(int(round(lerp(c0[i], c1[i], t))) for i in range(3))


def sky_gradient(w: int, h: int, horizon: float = 1.0) -> Image.Image:
    """Vertical night-sky ramp, eased so the glow hugs the horizon line.

    `horizon` is where the skyline's ground sits, 0..1 down the canvas.
    Below it the field drops to street black, so an adaptive icon never
    shows a bright band under the city when the launcher masks it.
    """
    img = Image.new("RGB", (w, h), SKY_TOP)
    draw = ImageDraw.Draw(img)
    hy = max(1.0, h * horizon)
    for y in range(h):
        if y <= hy:
            colour = mix(SKY_TOP, SKY_HORIZON, (y / hy) ** 2.6)
        else:
            t = (y - hy) / max(1.0, h - hy)
            colour = mix(SKY_HORIZON, GROUND, min(1.0, t * 2.4))
        draw.line([(0, y), (w, y)], fill=colour)
    return img


class Projection:
    """Maps skyline units onto a pixel box (uniform scale, no distortion)."""

    def __init__(self, x0: float, y0: float, scale: float, ox: float, oy: float):
        self.x0, self.y0, self.scale, self.ox, self.oy = x0, y0, scale, ox, oy

    def px(self, x: float) -> float:
        return self.ox + (x - self.x0) * self.scale

    def py(self, y: float) -> float:
        return self.oy + (y - self.y0) * self.scale

    def u(self, v: float) -> float:
        return v * self.scale


def fit(crop_x, crop_y, box) -> Projection:
    """Fit a skyline crop into a pixel box, centred, preserving aspect."""
    cw = crop_x[1] - crop_x[0]
    ch = crop_y[1] - crop_y[0]
    bx0, by0, bx1, by1 = box
    scale = min((bx1 - bx0) / cw, (by1 - by0) / ch)
    ox = bx0 + ((bx1 - bx0) - cw * scale) * 0.5
    oy = by0 + ((by1 - by0) - ch * scale) * 0.5
    return Projection(crop_x[0], crop_y[0], scale, ox, oy)


def tower_body(t) -> list:
    """Silhouette rectangles for one tower, including its crown."""
    x0, w, roof, crown = t
    parts = [(x0, roof, x0 + w, GROUND_Y)]
    if crown == "step":
        parts.append((x0 + w * 0.22, roof - 0.055, x0 + w * 0.78, roof))
    elif crown == "spire":
        parts.append((x0 + w * 0.20, roof - 0.062, x0 + w * 0.80, roof))
        parts.append((x0 + w * 0.455, roof - 0.150, x0 + w * 0.545, roof - 0.062))
        parts.append((x0 + w * 0.487, roof - 0.198, x0 + w * 0.513, roof - 0.150))
    return parts


def windows(ti: int, t) -> list:
    """Deterministic window grid for a tower: (col, row, x0, y0, x1, y1)."""
    x0, w, roof, _crown = t
    cols = max(1, int(round(w / WIN_PITCH_X)))
    span_top = roof + WIN_TOP_PAD
    span_bottom = GROUND_Y - WIN_BOTTOM_PAD
    rows = max(0, int((span_bottom - span_top) / WIN_PITCH_Y))
    if rows == 0 or cols == 0:
        return []
    step_x = w / cols
    out = []
    for ci in range(cols):
        cx = x0 + step_x * (ci + 0.5)
        for ri in range(rows):
            # A fixed integer sieve knocks out ~9% of the grid so the facades
            # look inhabited rather than printed. No RNG: bit-identical runs.
            if (ti * 7 + ci * 13 + ri * 29) % 11 == 0:
                continue
            cy = span_top + WIN_PITCH_Y * (ri + 0.5)
            out.append((ci, ri, cx - WIN_W / 2, cy - WIN_H / 2,
                        cx + WIN_W / 2, cy + WIN_H / 2))
    return out


def lit_window_rect(p: Projection) -> tuple:
    """Pixel rect of the one amber window, slightly wider than its neighbours."""
    t = TOWERS[HERO]
    for ci, ri, wx0, wy0, wx1, wy1 in windows(HERO, t):
        if ci == LIT_COL and ri == LIT_ROW:
            grow = WIN_W * 0.09
            return (p.px(wx0 - grow), p.py(wy0), p.px(wx1 + grow), p.py(wy1))
    raise RuntimeError("lit window (col %d, row %d) is not on the hero tower"
                       % (LIT_COL, LIT_ROW))


def paint_skyline(layer: Image.Image, p: Projection, crop_x,
                  silhouette=SILHOUETTE, window_fill=WINDOW_DARK,
                  street=None) -> None:
    """Draw towers + dark windows onto an RGBA layer.

    `street` (a colour) fills everything below the ground line to the bottom
    edge, which is what keeps the adaptive foreground opaque under the city.
    """
    draw = ImageDraw.Draw(layer)
    if street is not None:
        draw.rectangle([0, p.py(GROUND_Y), layer.size[0], layer.size[1]],
                       fill=street + (255,))
    for ti, t in enumerate(TOWERS):
        if t[0] + t[1] < crop_x[0] or t[0] > crop_x[1]:
            continue
        for rx0, ry0, rx1, ry1 in tower_body(t):
            draw.rectangle([p.px(rx0), p.py(ry0), p.px(rx1), p.py(ry1)],
                           fill=silhouette + (255,))
        if window_fill is None:
            continue
        for ci, ri, wx0, wy0, wx1, wy1 in windows(ti, t):
            if ti == HERO and ci == LIT_COL and ri == LIT_ROW:
                continue  # the one lit window is drawn last, over the bloom
            draw.rectangle([p.px(wx0), p.py(wy0), p.px(wx1), p.py(wy1)],
                           fill=window_fill + (255,))


def amber_glow(size, rect, strength: float) -> Image.Image:
    """Three-stop bloom around the lit window.

    The halo is the whole point of the mark: one light, no other, so it has to
    carry far enough to tint the neighbouring facades without turning the
    silhouette to mush.
    """
    w, h = size
    span = max(w, h)
    bloom = Image.new("RGB", (w, h), (0, 0, 0))
    ImageDraw.Draw(bloom).rectangle(rect, fill=AMBER_GLOW)
    stops = ((0.016, 1.00), (0.052, 0.78), (0.135, 0.42))
    out = Image.new("RGB", (w, h), (0, 0, 0))
    for radius, weight in stops:
        layer = bloom.filter(ImageFilter.GaussianBlur(radius=span * radius))
        out = ImageChops.add(
            out, layer.point(lambda v, k=weight: int(v * k * strength)))
    return out


def vignette(img: Image.Image, amount: float = 0.30) -> Image.Image:
    """Darken the corners so the frame reads as night, not as flat paint."""
    w, h = img.size
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).ellipse([-w * 0.18, -h * 0.18, w * 1.18, h * 1.18],
                                 fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(radius=max(w, h) * 0.16))
    dark = img.point(lambda v: int(v * (1.0 - amount)))
    return Image.composite(img, dark, mask)


def draw_lit_window(layer: Image.Image, rect) -> None:
    draw = ImageDraw.Draw(layer)
    draw.rectangle(rect, fill=AMBER + (255,))
    inset_x = (rect[2] - rect[0]) * 0.26
    inset_y = (rect[3] - rect[1]) * 0.26
    draw.rectangle([rect[0] + inset_x, rect[1] + inset_y,
                    rect[2] - inset_x, rect[3] - inset_y],
                   fill=AMBER_CORE + (255,))


def downsample(img: Image.Image, px: int, py: int) -> Image.Image:
    return img.resize((px, py), Image.LANCZOS)


# --------------------------------------------------------------------------
# Renders
# --------------------------------------------------------------------------

def render_full(px: int) -> Image.Image:
    """Full-bleed square icon: sky, skyline, one amber window."""
    s = px * SS
    canvas = vignette(sky_gradient(s, s))
    p = fit(ICON_CROP, (ICON_TOP, GROUND_Y),
            (s * 0.015, s * 0.035, s * 0.985, s * 0.965))
    # Street level under the towers.
    ImageDraw.Draw(canvas).rectangle([0, p.py(GROUND_Y), s, s], fill=GROUND)

    rect = lit_window_rect(p)
    towers = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    paint_skyline(towers, p, ICON_CROP)
    canvas = Image.alpha_composite(canvas.convert("RGBA"), towers)

    canvas = ImageChops.add(canvas, amber_glow((s, s), rect, 1.0).convert("RGBA"))
    draw_lit_window(canvas, rect)
    return downsample(canvas, px, px).convert("RGB")


def render_adaptive_background(px: int) -> Image.Image:
    """Opaque field only — Android masks this to the launcher's shape.

    Its horizon is pinned to the foreground's ground line so the two layers
    meet without a seam under any mask, and it stays legible if the launcher
    parallaxes the foreground.
    """
    s = px * SS
    horizon = _adaptive_projection(s).py(GROUND_Y) / s
    canvas = sky_gradient(s, s, horizon)
    # A soft blue lift behind the skyline, so a masked circle is not just a
    # flat slice of the ramp.
    lift = Image.new("RGB", (s, s), (0, 0, 0))
    ImageDraw.Draw(lift).ellipse([-s * 0.30, s * (horizon - 0.30), s * 1.30,
                                  s * (horizon + 0.16)], fill=(20, 44, 74))
    lift = lift.filter(ImageFilter.GaussianBlur(radius=s * 0.10))
    canvas = ImageChops.add(canvas, lift)
    return downsample(vignette(canvas, 0.22), px, px).convert("RGB")


def _adaptive_projection(s: int) -> Projection:
    """Skyline fitted to the adaptive safe zone (central 66.6% of the canvas)."""
    safe = s * (1.0 - 0.6667) * 0.5
    return fit(ICON_CROP, (ICON_TOP, GROUND_Y),
               (safe, safe, s - safe, s - safe))


def render_adaptive_foreground(px: int) -> Image.Image:
    s = px * SS
    p = _adaptive_projection(s)
    rect = lit_window_rect(p)
    layer = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    paint_skyline(layer, p, ICON_CROP, street=GROUND)
    glow = amber_glow((s, s), rect, 1.0)
    # Glow carries its own alpha so it lifts the background instead of
    # punching a dark box through it.
    glow_a = glow.convert("L").point(lambda v: min(255, int(v * 1.35)))
    glow_rgba = glow.convert("RGBA")
    glow_rgba.putalpha(glow_a)
    layer = Image.alpha_composite(layer, glow_rgba)
    draw_lit_window(layer, rect)
    return downsample(layer, px, px)


def render_adaptive_monochrome(px: int) -> Image.Image:
    """Themed icon: solid silhouette, the one window punched out of it."""
    s = px * SS
    p = _adaptive_projection(s)
    layer = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    paint_skyline(layer, p, ICON_CROP, silhouette=(255, 255, 255),
                  window_fill=None, street=(255, 255, 255))
    rect = lit_window_rect(p)
    grow = (rect[2] - rect[0]) * 0.22
    ImageDraw.Draw(layer).rectangle(
        [rect[0] - grow, rect[1] - grow, rect[2] + grow, rect[3] + grow],
        fill=(0, 0, 0, 0))
    return downsample(layer, px, px)


# --------------------------------------------------------------------------
# Wordmark — a geometric stroke alphabet, so the splash needs no font file.
# Glyphs live on a unit box: x right in [0,1], y down in [0,1].
# --------------------------------------------------------------------------
GLYPHS = {
    "S": [[(1.0, 0.14), (0.78, 0.0), (0.22, 0.0), (0.0, 0.14), (0.0, 0.38),
           (0.22, 0.5), (0.78, 0.5), (1.0, 0.62), (1.0, 0.86), (0.78, 1.0),
           (0.22, 1.0), (0.0, 0.86)]],
    "L": [[(0.0, 0.0), (0.0, 1.0), (0.92, 1.0)]],
    "A": [[(0.0, 1.0), (0.5, 0.0), (1.0, 1.0)], [(0.19, 0.62), (0.81, 0.62)]],
    "C": [[(1.0, 0.14), (0.78, 0.0), (0.22, 0.0), (0.0, 0.14), (0.0, 0.86),
           (0.22, 1.0), (0.78, 1.0), (1.0, 0.86)]],
    "U": [[(0.0, 0.0), (0.0, 0.84), (0.2, 1.0), (0.8, 1.0), (1.0, 0.84),
           (1.0, 0.0)]],
    "M": [[(0.0, 1.0), (0.0, 0.0), (0.5, 0.56), (1.0, 0.0), (1.0, 1.0)]],
    "I": [[(0.5, 0.0), (0.5, 1.0)]],
    "T": [[(0.0, 0.0), (1.0, 0.0)], [(0.5, 0.0), (0.5, 1.0)]],
    "Y": [[(0.0, 0.0), (0.5, 0.52), (1.0, 0.0)], [(0.5, 0.52), (0.5, 1.0)]],
    "O": [[(0.22, 0.0), (0.78, 0.0), (1.0, 0.16), (1.0, 0.84), (0.78, 1.0),
           (0.22, 1.0), (0.0, 0.84), (0.0, 0.16), (0.22, 0.0)]],
    "B": [[(0.0, 0.0), (0.72, 0.0), (0.95, 0.15), (0.95, 0.35), (0.72, 0.5),
           (0.0, 0.5)],
          [(0.72, 0.5), (0.98, 0.65), (0.98, 0.85), (0.75, 1.0), (0.0, 1.0),
           (0.0, 0.0)]],
    "N": [[(0.0, 1.0), (0.0, 0.0), (1.0, 1.0), (1.0, 0.0)]],
    "W": [[(0.0, 0.0), (0.22, 1.0), (0.5, 0.42), (0.78, 1.0), (1.0, 0.0)]],
    "K": [[(0.0, 0.0), (0.0, 1.0)], [(0.95, 0.0), (0.05, 0.58)],
          [(0.30, 0.42), (1.0, 1.0)]],
    "E": [[(1.0, 0.0), (0.0, 0.0), (0.0, 1.0), (1.0, 1.0)],
          [(0.0, 0.5), (0.76, 0.5)]],
    "P": [[(0.0, 1.0), (0.0, 0.0), (0.75, 0.0), (1.0, 0.16), (1.0, 0.42),
           (0.75, 0.58), (0.0, 0.58)]],
    "V": [[(0.0, 0.0), (0.5, 1.0), (1.0, 0.0)]],
}
GLYPH_W = 0.64
GLYPH_GAP = 0.26
SPACE_W = 0.46
DOT_W = 0.16


def _advance(ch: str) -> float:
    if ch == " ":
        return SPACE_W
    if ch == ".":
        return DOT_W
    return GLYPH_W


def text_width(text: str, gap: float = GLYPH_GAP) -> float:
    """Wordmark width in cap-height units."""
    total = 0.0
    for i, ch in enumerate(text):
        total += _advance(ch)
        if i < len(text) - 1:
            total += gap
    return total


def draw_wordmark(layer: Image.Image, text: str, cap: float, cx: float,
                  top: float, color, gap: float = GLYPH_GAP,
                  weight: float = 0.125) -> None:
    draw = ImageDraw.Draw(layer)
    stroke = max(1, int(round(cap * weight)))
    x = cx - text_width(text, gap) * cap * 0.5
    for ch in text:
        if ch == ".":
            r = stroke * 0.62
            draw.ellipse([x - r, top + cap - r, x + DOT_W * cap + r,
                          top + cap + r], fill=color + (255,))
        elif ch != " ":
            for poly in GLYPHS[ch]:
                pts = [(x + px * GLYPH_W * cap, top + py * cap)
                       for px, py in poly]
                draw.line(pts, fill=color + (255,), width=stroke, joint="curve")
                for pt in (pts[0], pts[-1]):  # round the caps
                    r = stroke * 0.5
                    draw.ellipse([pt[0] - r, pt[1] - r, pt[0] + r, pt[1] + r],
                                 fill=color + (255,))
        x += (_advance(ch) + gap) * cap


def render_splash(px: int, py: int) -> Image.Image:
    """Boot splash: the full skyline, the wordmark, the same amber window.

    Landscape and dark end to end — the launch window, the splash and the
    first rendered frame all sit on the same near-black field, so there is
    no white flash anywhere in the boot sequence.
    """
    w, h = px * SS, py * SS
    canvas = vignette(sky_gradient(w, h), 0.34)
    ground_line = h * 0.955
    band_top = h * 0.50
    p = fit((0.0, SKYLINE_WIDTH), (0.0, GROUND_Y),
            (-w * 0.01, band_top, w * 1.01, ground_line))
    ImageDraw.Draw(canvas).rectangle([0, p.py(GROUND_Y), w, h], fill=GROUND)

    rect = lit_window_rect(p)
    towers = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    paint_skyline(towers, p, (0.0, SKYLINE_WIDTH))
    canvas = Image.alpha_composite(canvas.convert("RGBA"), towers)
    canvas = ImageChops.add(canvas, amber_glow((w, h), rect, 1.0).convert("RGBA"))
    draw_lit_window(canvas, rect)

    cap = h * 0.105
    top = h * 0.175
    draw_wordmark(canvas, "SLACUM CITY", cap, w * 0.5, top, WORDMARK)
    # Hairline rule under the wordmark, lit amber at its midpoint.
    rule_y = top + cap * 1.62
    rule_w = text_width("SLACUM CITY") * cap * 0.5
    thickness = max(1, h * 0.0035)
    draw = ImageDraw.Draw(canvas)
    draw.rectangle([w * 0.5 - rule_w, rule_y, w * 0.5 + rule_w,
                    rule_y + thickness], fill=(38, 66, 100, 255))
    draw.rectangle([w * 0.5 - rule_w * 0.10, rule_y,
                    w * 0.5 + rule_w * 0.10, rule_y + thickness],
                   fill=AMBER + (255,))
    draw_wordmark(canvas, "YOU BUILT IT.  NOW KEEP IT ALIVE.", cap * 0.235,
                  w * 0.5, rule_y + cap * 0.46, TAGLINE,
                  gap=GLYPH_GAP * 1.7, weight=0.155)
    return downsample(canvas, px, py).convert("RGB")


# --------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-root", default=os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))))
    args = parser.parse_args()
    root = args.out_root
    branding = os.path.join(root, "game", "branding")
    os.makedirs(branding, exist_ok=True)

    outputs = [
        (os.path.join(root, "icon.png"), render_full(512)),
        (os.path.join(branding, "icon_192.png"), render_full(192)),
        (os.path.join(branding, "icon_fg_432.png"), render_adaptive_foreground(432)),
        (os.path.join(branding, "icon_bg_432.png"), render_adaptive_background(432)),
        (os.path.join(branding, "icon_mono_432.png"), render_adaptive_monochrome(432)),
        (os.path.join(branding, "splash.png"), render_splash(1280, 720)),
    ]
    for path, image in outputs:
        image.save(path, "PNG", optimize=True)
        print("wrote %s (%dx%d)" % (os.path.relpath(path, root),
                                    image.size[0], image.size[1]))


if __name__ == "__main__":
    main()
