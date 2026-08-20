#!/usr/bin/env python3
"""Play Store listing assets — icon, feature graphic, screenshots (doc 13 §2.12).

    python3 tools/gen_store_assets.py                # everything
    python3 tools/gen_store_assets.py --graphics-only # no engine runs
    python3 tools/gen_store_assets.py --list          # what would be produced

Everything here is **deterministic**. The graphics are drawn from the same
authored skyline coordinate system as the launcher icon (`tools/gen_icon.py`), so
the feature graphic and the icon are literally the same mark at two crops; the
screenshots are rendered off `game/main.tscn` at fixed clock times, fixed camera
focus and fixed zoom, with the sim seeded as it always is. Run it twice, get the
same bytes twice — which is what makes a store listing reviewable in a diff
instead of by eye.

WHAT PLAY REQUIRES, and what this produces (Play Console, 2026 listing rules):

    icon                512×512 32-bit PNG, no alpha, no rounded corners
    feature graphic    1024×500 PNG or JPEG, no alpha
    phone screenshots  2–8, 16:9 landscape, ≥ 1080p on the long edge
    7"  tablet         up to 8, same shots at tablet aspect
    10" tablet         up to 8, same shots at tablet aspect

Landscape only, because the game is landscape only (constitution §1). The tablet
sets are re-renders at the tablet aspect ratio rather than upscales — a stretched
phone shot is the single most obvious sign of a listing nobody looked at.

THE FIVE MOMENTS, and why these five:

  1. `night_skyline`  21:00 over the showcase metropolis — the lead image. Every
                      window is a lit rectangle in a black field, which is the
                      game's own mark blown up to a city: "you built it, now keep
                      it alive". If a player sees one picture of this game, this
                      one has to carry it.
  2. `dusk_skyline`   16:00, warm haze. The same city with light on it: façade
                      texture, roof props, the canal, and a sky that is not black.
  3. `night_storm`    21:00 under a pinned thunderstorm with a stroke on the
                      shutter. The promise of the whole game in one frame — the
                      city at the hour it is hardest to keep alive.
  4. `power_overlay`  The power overlay over the same skyline: this is a
                      simulation, and the simulation is legible.
  5. `first_run`      `game/main.tscn` itself — the real HUD, the real starter
                      city, the coach card on step 1. A store listing with no
                      interface in it is a trailer, not a screenshot.

The first four come off `game/showcase.tscn`, which exists precisely because it
is "the frame the project is marketed on" — a grown metropolis with no simulation
behind it. The fifth is the actual game, because a listing where nothing shows
the interface is a listing that gets a one-star "not what the pictures showed".

Screenshots need a display, so they run under `xvfb-run` when there is no
`$DISPLAY` — headless Godot renders nothing but a black frame, and a black
screenshot that "succeeded" is worse than a failure.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys

from PIL import Image, ImageChops, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gen_icon as mark  # noqa: E402  (path juggling above is deliberate)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join("build", "store")
GODOT = os.environ.get("GODOT", os.path.expanduser("~/.local/bin/godot"))

# Play's three screenshot form factors. Landscape, ≥ 1080p long edge, ratio ≤ 2:1.
FORM_FACTORS = [
    ("phone", 1920, 1080),
    ("tablet7", 2048, 1152),
    ("tablet10", 2560, 1440),
]

SHOWCASE = "res://game/showcase.tscn"
MAIN = "res://game/main.tscn"

# (name, scene, args). Every flag here is documented in that scene's own header;
# none of them exist only for this script, and none of them change the game.
SHOTS = [
    ("night_skyline", SHOWCASE, [
        "--hour=21",                # the showcase's own hero pose
        "--shot-at=3.0",
    ]),
    ("dusk_skyline", SHOWCASE, [
        # 16:00 in the showcase is a warm, hazy low sun rather than flat daylight
        # — the fog and the sun angle make it dusk, so it is named dusk. The
        # daylight frames in this set are the two off `main.tscn` below, at 13:00.
        "--hour=16",
        "--shot-at=3.0",
    ]),
    ("night_storm", SHOWCASE, [
        "--hour=21",
        "--storm=0.85",
        # The stroke decays in a few tenths of a second, so the shutter has to be
        # right behind it — 2.85 fires, 3.00 photographs.
        "--lightning-at=2.85",
        "--shot-at=3.0",
    ]),
    ("power_overlay", MAIN, [
        # The overlay off `main.tscn` rather than the showcase: the showcase has
        # no sim, so its overlay is a shader mode with no state behind it and
        # the frame reads as a plain dusk skyline. Here the rail, the legend card
        # and the tinted blocks are all the real thing.
        "--advance-hours=7.0",      # 13:00 — the tint has to read, so daylight
        "--overlay=1",              # doc 12 §2.5's power mode
        # doc 12's zoom_t: 0 = street, 1 = skyline. Half way is where the
        # starter city fills the frame — wider and it is mostly empty blocks,
        # which is honest about day one and useless as a picture.
        "--zoom=0.50",
        "--shot-at=3.2",
    ]),
    ("first_run", MAIN, [
        "--advance-hours=7.0",      # founding is 06:00 → 13:00, the good light
        "--zoom=0.38",              # close enough for brick, shingle and shadow
        "--shot-at=3.5",
    ]),
]


# --------------------------------------------------------------------------
# Feature graphic — the icon's skyline, at 1024×500
# --------------------------------------------------------------------------

def render_feature_graphic(px: int = 1024, py: int = 500) -> Image.Image:
    """The store banner: the full skyline, the wordmark, the one lit window.

    Deliberately the *same* drawing as the boot splash rather than a second
    illustration. A player sees the feature graphic in the store, then the splash
    on first launch, and the two being one image is the difference between a game
    with a mark and a game with some art.
    """
    ss = mark.SS
    w, h = px * ss, py * ss
    canvas = mark.vignette(mark.sky_gradient(w, h), 0.36)

    ground_line = h * 0.94
    band_top = h * 0.30
    # The banner is much wider than it is tall, so the skyline crop is pushed
    # right: the hero tower (and its lit window) lands off-centre-left, which
    # leaves the right third clear for the wordmark. Play overlays nothing on
    # the feature graphic, but every store surface crops it differently, so the
    # subject stays out of the outer eighth on every side.
    crop = (0.0, mark.SKYLINE_WIDTH)
    p = mark.fit(crop, (0.0, mark.GROUND_Y),
                 (-w * 0.02, band_top, w * 1.02, ground_line))
    ImageDraw.Draw(canvas).rectangle([0, p.py(mark.GROUND_Y), w, h],
                                     fill=mark.GROUND)

    rect = mark.lit_window_rect(p)
    towers = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    mark.paint_skyline(towers, p, crop)
    canvas = Image.alpha_composite(canvas.convert("RGBA"), towers)
    canvas = ImageChops.add(canvas,
                            mark.amber_glow((w, h), rect, 1.15).convert("RGBA"))
    mark.draw_lit_window(canvas, rect)

    cap = h * 0.150
    top = h * 0.150
    mark.draw_wordmark(canvas, "SLACUM CITY", cap, w * 0.5, top, mark.WORDMARK)

    rule_y = top + cap * 1.62
    rule_w = mark.text_width("SLACUM CITY") * cap * 0.5
    thickness = max(1, h * 0.005)
    draw = ImageDraw.Draw(canvas)
    draw.rectangle([w * 0.5 - rule_w, rule_y, w * 0.5 + rule_w,
                    rule_y + thickness], fill=(38, 66, 100, 255))
    draw.rectangle([w * 0.5 - rule_w * 0.10, rule_y,
                    w * 0.5 + rule_w * 0.10, rule_y + thickness],
                   fill=mark.AMBER + (255,))
    mark.draw_wordmark(canvas, "YOU BUILT IT.  NOW KEEP IT ALIVE.", cap * 0.235,
                       w * 0.5, rule_y + cap * 0.46, mark.TAGLINE,
                       gap=mark.GLYPH_GAP * 1.7, weight=0.155)
    return mark.downsample(canvas, px, py).convert("RGB")


def render_store_icon(px: int = 512) -> Image.Image:
    """Play's icon slot: the launcher mark, flattened. 32-bit PNG, no alpha —
    Play adds its own rounding and rejects an icon that pre-rounds itself."""
    return mark.render_full(px).convert("RGB")


# --------------------------------------------------------------------------
# Screenshots — the real game, at fixed moments
# --------------------------------------------------------------------------

def display_prefix() -> list[str]:
    """`xvfb-run` when there is no display. Godot's headless driver renders
    nothing at all, so a screenshot taken under it is a black rectangle that
    exits 0 — the most expensive kind of silent failure."""
    if os.environ.get("DISPLAY"):
        return []
    xvfb = shutil.which("xvfb-run")
    if xvfb:
        return [xvfb, "-a", "-s", "-screen 0 2560x1440x24"]
    return []


def render_screenshot(name: str, scene: str, args: list[str], width: int,
                      height: int, out_path: str, verbose: bool = True) -> bool:
    cmd = display_prefix() + [
        GODOT, "--path", REPO_ROOT, scene,
        "--resolution", "%dx%d" % (width, height),
        "--position", "0,0",
        "--", "--screenshot=%s" % out_path,
    ] + args
    if verbose:
        print("  rendering %s at %dx%d" % (name, width, height))
    result = subprocess.run(cmd, cwd=REPO_ROOT, capture_output=True, text=True)
    if not os.path.exists(out_path):
        sys.stderr.write("  FAILED %s\n%s\n%s\n"
                         % (name, result.stdout[-2000:], result.stderr[-2000:]))
        return False
    # A frame that is uniformly dark means the renderer never drew the city —
    # the failure mode `--headless` produces, and the one worth catching here
    # rather than in the Play Console review queue.
    with Image.open(out_path) as shot:
        extrema = shot.convert("L").getextrema()
    if extrema[1] - extrema[0] < 12:
        sys.stderr.write("  FAILED %s: the frame is flat (%s) — no display?\n"
                         % (name, extrema))
        return False
    return True


# --------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=OUT_DIR,
                        help="output directory, relative to the repo root")
    parser.add_argument("--graphics-only", action="store_true",
                        help="icon and feature graphic only; no engine runs")
    parser.add_argument("--shots-only", action="store_true")
    parser.add_argument("--form-factor", default="",
                        help="only this one: phone | tablet7 | tablet10")
    parser.add_argument("--list", action="store_true",
                        help="print the asset list and exit")
    args = parser.parse_args()

    out_root = args.out if os.path.isabs(args.out) \
        else os.path.join(REPO_ROOT, args.out)
    factors = [f for f in FORM_FACTORS
               if not args.form_factor or f[0] == args.form_factor]

    if args.list:
        print("icon_512.png                   512x512")
        print("feature_graphic.png           1024x500")
        for label, w, h in factors:
            for name, scene, _ in SHOTS:
                print("%-30s %dx%d  %s" % ("%s/%s.png" % (label, name), w, h,
                                           scene))
        return 0

    os.makedirs(out_root, exist_ok=True)
    failures = 0

    if not args.shots_only:
        print("Store graphics")
        for filename, image in [
            ("icon_512.png", render_store_icon(512)),
            ("feature_graphic.png", render_feature_graphic()),
        ]:
            path = os.path.join(out_root, filename)
            image.save(path, "PNG", optimize=True)
            print("  wrote %s (%dx%d)" % (os.path.relpath(path, REPO_ROOT),
                                          image.size[0], image.size[1]))

    if not args.graphics_only:
        print("Screenshots")
        if not os.path.exists(GODOT):
            sys.stderr.write("  godot not found at %s — set $GODOT\n" % GODOT)
            return 1
        for label, width, height in factors:
            os.makedirs(os.path.join(out_root, label), exist_ok=True)
            for name, scene, shot_args in SHOTS:
                path = os.path.join(out_root, label, "%s.png" % name)
                if not render_screenshot("%s/%s" % (label, name), scene,
                                         shot_args, width, height, path):
                    failures += 1

    if failures:
        sys.stderr.write("%d asset(s) failed\n" % failures)
        return 1
    print("Store assets are in %s" % os.path.relpath(out_root, REPO_ROOT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
