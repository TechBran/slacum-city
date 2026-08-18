#!/usr/bin/env python3
"""Generate and validate `data/building_shapes.json` for SLACUM CITY.

Source of truth: `docs/design/11-rendering-performance.md` §2.14 (gray-box
massing, level markers, AO table, silhouette descriptor) and §3.2 (schema).
The roster is `data/buildings.json`'s 12 shipped archetypes (doc 02), not doc
11 §2.14's 15-row placeholder table; `doc11_id` maps each shipped archetype
onto the §2.14 silhouette row it realises.

Every invariant doc 11 asserts on the generated meshes is re-checked here in
plain arithmetic BEFORE the JSON is written, so a bad edit fails at authoring
time rather than in the Godot generator:

  * LOD0 <= 320 tris (<= 420 for the tall archetypes named in data/render.json)
  * LOD1 <= 96 tris AND <= 0.40 x LOD0
  * silhouette descriptors: Hamming >= 4 between archetypes at equal level,
    >= 2 between levels of one archetype (doc 11 §7.1 test 7)

The tri counts mirror tools/gen_graybox.gd's emitters exactly (4 side faces,
+1 quad row where a face crosses the 3 m AO band, +top, +bottom only for
overhangs; gable 6, mast 4 (+10 with a beacon cap), octprism 8*n+6, fence 8,
pad 2).

Usage:
    python3 tools/gen_building_shapes.py [--out-dir DATA_DIR] [--check]

    --check   validate and compare against the committed file; write nothing.
"""

from __future__ import annotations

import argparse
import itertools
import json
import os
import re
import sys

FLOOR = 3.5
TILE = 8.0
AO_BAND = 3.0

HEIGHT_T = [4, 7, 11, 15, 20, 26, 34, 44, 56, 72, 92, 118, 150, 190, 240]
SLENDER_T = [0.35, 0.7, 1.2, 2.0, 3.2, 5.0, 8.0]
# 4-bit roof-signature codes, hand-assigned so that the eight "yard-like"
# signatures (which share footprint/props/flag fields) form an even-weight code
# (pairwise Hamming >= 2) and the four building-like ones an odd-weight code.
ROOF_SIG_ID = {
    "parapet_sign_band": 0b0111, "chiller_bank": 0b0011, "hose_tower": 0b0101,
    "transformer_yard": 0b0110, "crane_mast": 0b1001, "twin_stacks": 0b1010,
    "tank_cluster": 0b1100, "antenna_mast": 0b1111,
    "gable_prism": 0b0001, "flat_stair_boxes": 0b0010, "hvac_cluster": 0b0100,
    "setback_tower_mast": 0b1000,
}
ROOF_SIGS = list(ROOF_SIG_ID.keys())

# ------------------------------------------------------------------ tri counts

def box_tris(y0, y1, overhang=False):
    per_side = 4 if (y0 < AO_BAND < y1) else 2
    t = 4 * per_side + 2
    if overhang:
        t += 2
    return t

def prop_tris(p):
    t = p["type"]
    base = p.get("base_m", 0.0)
    if t in ("box", "notch", "sign_band"):
        y1 = base + p["height_m"]
        return box_tris(base, y1, p.get("overhang", False))
    if t == "mast":
        return 4 + (10 if p.get("beacon", False) else 0)
    if t == "gable":
        return 6
    if t == "octprism":
        y1 = base + p["height_m"]
        per_side = 4 if (base < AO_BAND < y1) else 2
        return 8 * per_side + 6
    if t == "fence":
        return 8
    if t == "pad":
        return 2
    raise ValueError(t)

def block_y(b):
    y0 = b.get("base_m", b.get("base_floor", 0) * FLOOR)
    if "height_m" in b:
        y1 = y0 + b["height_m"]
    else:
        y1 = y0 + b["floors"] * FLOOR
    return y0, y1

def block_tris(b):
    y0, y1 = block_y(b)
    return box_tris(y0, y1, b.get("overhang", False))

def block_volume(b):
    y0, y1 = block_y(b)
    return b["size_t"][0] * b["size_t"][1] * TILE * TILE * (y1 - y0)


def popcount(x):
    return bin(x).count("1")

MK = {
    "rooftop_box": {"from_level": 2, "size_frac": 0.30, "offset_frac": [0.55, 0.15],
                    "height_frac": 0.06, "height_min_m": 2.0, "height_max_m": 4.0},
    "crown_band": {"from_level": 4, "inset_m": 0.5, "height_frac": 0.02,
                   "height_min_m": 0.8, "height_max_m": 2.5},
    "masts": {"from_level": 4, "count": 2, "width_m": 0.5, "height_frac": 0.10,
              "height_min_m": 3.0, "height_max_m": 9.0,
              "pos_frac": [[0.2, 0.2], [0.8, 0.8]]},
    "spire": {"from_level": 5, "width_m": 0.6, "height_frac": 0.18,
              "height_min_m": 4.5, "height_max_m": 14.0, "beacon_m": 0.6,
              "beacon_blink_hz": 0.5},
}
LOD1_KEEP = 0.15


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def marker_props(level, top):
    x, z = top["pos_t"]; w, d = top["size_t"]
    ty = block_y(top)[1]
    out = []
    if level >= MK["rooftop_box"]["from_level"]:
        c = MK["rooftop_box"]
        out.append({"type": "box", "pos_t": [x + w * c["offset_frac"][0],
                                             z + d * c["offset_frac"][1]],
                    "size_t": [w * c["size_frac"], d * c["size_frac"]],
                    "base_m": ty,
                    "height_m": clamp(ty * c["height_frac"], c["height_min_m"], c["height_max_m"])})
    crown_h = 0.0
    if level >= MK["crown_band"]["from_level"]:
        c = MK["crown_band"]
        inset = c["inset_m"] / TILE
        crown_h = clamp(ty * c["height_frac"], c["height_min_m"], c["height_max_m"])
        out.append({"type": "box", "pos_t": [x + inset, z + inset],
                    "size_t": [max(0.1, w - 2 * inset), max(0.1, d - 2 * inset)],
                    "base_m": ty, "height_m": crown_h})
        m = MK["masts"]
        mh = clamp(ty * m["height_frac"], m["height_min_m"], m["height_max_m"])
        for pf in m["pos_frac"][:m["count"]]:
            out.append({"type": "mast", "pos_t": [x + w * pf[0], z + d * pf[1]],
                        "base_m": ty + crown_h, "height_m": mh, "width_m": m["width_m"]})
    if level >= MK["spire"]["from_level"]:
        s = MK["spire"]
        sh = clamp(ty * s["height_frac"], s["height_min_m"], s["height_max_m"])
        out.append({"type": "mast", "pos_t": [x + w * 0.5, z + d * 0.5],
                    "base_m": ty + crown_h, "height_m": sh, "width_m": s["width_m"],
                    "beacon": True})
    return out


def block_tris_lod(b, ao_band):
    y0, y1 = block_y(b)
    per_side = 4 if (ao_band and y0 < AO_BAND < y1) else 2
    t = 4 * per_side + 2
    if b.get("overhang"):
        t += 2
    return t


def prop_tris_lod(p, ao_band):
    t = p["type"]
    base = p.get("base_m", 0.0)
    if t in ("box", "notch", "sign_band"):
        y1 = base + p["height_m"]
        per_side = 4 if (ao_band and base < AO_BAND < y1) else 2
        return 4 * per_side + 2 + (2 if p.get("overhang") else 0)
    if t == "mast":
        return 4 + (10 if p.get("beacon") else 0)
    if t == "gable":
        return 6
    if t == "octprism":
        y1 = base + p["height_m"]
        per_side = 4 if (ao_band and base < AO_BAND < y1) else 2
        return 8 * per_side + 6
    if t == "fence":
        return 8
    if t == "pad":
        return 2
    raise ValueError(t)


def evaluate(arch, lvl):
    blocks = lvl["blocks"]
    top = max(blocks, key=lambda b: block_y(b)[1])
    props = list(lvl["roof_props"]) + marker_props(lvl["level"], top)

    tris0 = sum(block_tris_lod(b, True) for b in blocks) + \
            sum(prop_tris_lod(p, True) for p in props)

    total_vol = sum(block_volume(b) for b in blocks if not b.get("decor"))
    keep = [b for b in blocks if not b.get("decor") and block_volume(b) >= LOD1_KEEP * total_vol]
    if not keep:
        keep = [max(blocks, key=block_volume)]
    sig = [p for p in props if p.get("lod1")]
    tris1 = sum(block_tris_lod(b, False) for b in keep) + \
            sum(prop_tris_lod(p, False) for p in sig)
    if not sig and props:
        tris1 += 10  # one merged AABB box

    height = max([block_y(b)[1] for b in blocks] +
                 [p.get("base_m", 0.0) + p.get("height_m", 0.0) +
                  (MK["spire"]["beacon_m"] if p.get("beacon") else 0.0) for p in props])
    fx, fz = lvl["footprint_tiles"]
    slender = height / (TILE * max(fx, fz))
    setbacks = sum(1 for b in blocks if block_y(b)[0] > 0.01 and not b.get("decor"))
    masts = sum(1 for p in props if p["type"] == "mast")
    windowless = 0 if any(b.get("window") == "grid" for b in blocks) else 1
    nf = 0
    if any(p.get("overhang") for p in props) or any(b.get("overhang") for b in blocks):
        nf |= 1
    if any(p["type"] in ("notch", "pad") for p in props):
        nf |= 2
    if any(p["type"] == "fence" for p in props):
        nf |= 4
    f = {
        "h": sum(1 for t in HEIGHT_T if t < height),
        "a": sum(1 for t in SLENDER_T if t < slender),
        "r": ROOF_SIG_ID[arch["roof_signature"]],
        "s": min(3, setbacks), "m": min(3, masts), "p": min(7, len(props)),
        "n": nf, "w": windowless, "f": min(3, max(fx, fz) - 1),
    }
    desc = (f["h"] << 20 | f["a"] << 17 | f["r"] << 13 | f["s"] << 11 | f["m"] << 9
            | f["p"] << 6 | f["n"] << 3 | f["w"] << 2 | f["f"])
    return tris0, tris1, height, desc, f


R = lambda v: round(v, 4)

# ------------------------------------------------------------------ helpers

def blk(x, z, w, d, base_floor=0, floors=1, window="grid", **kw):
    b = {"pos_t": [R(x), R(z)], "size_t": [R(w), R(d)], "base_floor": base_floor,
         "floors": floors, "window": window}
    b.update(kw)
    return b

def blk_m(x, z, w, d, base_m, height_m, window="none", **kw):
    b = {"pos_t": [R(x), R(z)], "size_t": [R(w), R(d)], "base_m": R(base_m),
         "height_m": R(height_m), "window": window}
    b.update(kw)
    return b

def box(x, z, w, d, base_m, height_m, **kw):
    p = {"type": "box", "pos_t": [R(x), R(z)], "size_t": [R(w), R(d)],
         "base_m": R(base_m), "height_m": R(height_m)}
    p.update(kw)
    return p

def mast(x, z, base_m, height_m, width_m=0.6, **kw):
    p = {"type": "mast", "pos_t": [R(x), R(z)], "base_m": R(base_m),
         "height_m": R(height_m), "width_m": width_m}
    p.update(kw)
    return p

def gable(x, z, w, d, base_m, height_m, **kw):
    p = {"type": "gable", "pos_t": [R(x), R(z)], "size_t": [R(w), R(d)],
         "base_m": R(base_m), "height_m": R(height_m)}
    p.update(kw)
    return p

def octp(x, z, w, d, base_m, height_m, **kw):
    p = {"type": "octprism", "pos_t": [R(x), R(z)], "size_t": [R(w), R(d)],
         "base_m": R(base_m), "height_m": R(height_m)}
    p.update(kw)
    return p

def fence(x, z, w, d, height_m=2.4):
    return {"type": "fence", "pos_t": [R(x), R(z)], "size_t": [R(w), R(d)],
            "base_m": 0.0, "height_m": height_m}

def pad(x, z, w, d, y=0.05):
    return {"type": "pad", "pos_t": [R(x), R(z)], "size_t": [R(w), R(d)], "base_m": y,
            "height_m": 0.0}

def notch(x, z, w, d, height_m=2.8):
    return {"type": "notch", "pos_t": [R(x), R(z)], "size_t": [R(w), R(d)],
            "base_m": 0.0, "height_m": height_m}

def band(x, z, w, d, base_m, height_m=0.7):
    return {"type": "sign_band", "pos_t": [R(x), R(z)], "size_t": [R(w), R(d)],
            "base_m": R(base_m), "height_m": R(height_m)}

def canopy(x, z, w, d, base_m, thickness=0.35):
    return {"type": "box", "pos_t": [R(x), R(z)], "size_t": [R(w), R(d)],
            "base_m": R(base_m), "height_m": thickness, "overhang": True}

MARKERS = ["none", "rooftop_box", "setback", "crown_band_plus_masts", "spire_beacon"]

# ------------------------------------------------------------- archetypes

def a_house(lv, fx, fz):
    F = [1, 2, 2, 3, 3][lv - 1]
    ridge = [2.0, 2.4, 2.8, 3.2, 3.6][lv - 1]
    blocks = []
    if lv < 3:
        blocks.append(blk(0.05, 0.05, 0.9, 0.9, 0, F))
        top_h, tx, tz, tw, td = F * FLOOR, 0.05, 0.05, 0.9, 0.9
    else:
        blocks.append(blk(0.05, 0.05, 0.9, 0.9, 0, F - 1))
        blocks.append(blk(0.15, 0.15, 0.7, 0.7, F - 1, 1))
        top_h, tx, tz, tw, td = F * FLOOR, 0.15, 0.15, 0.7, 0.7
    props = [
        gable(tx, tz, tw, td, top_h, ridge, signature=True, lod1=True),
        box(0.68, 0.12, 0.16, 0.16, top_h, 1.6),                      # chimney
        canopy(0.0, 0.30, 0.35, 0.4, 2.6),                            # porch
    ]
    return blocks, props


def a_apartment(lv, fx, fz):
    F = [3, 4, 6, 8, 10][lv - 1]
    blocks = []
    if lv < 3:
        blocks.append(blk(0.05, 0.05, 1.9, 1.9, 0, F))
        top_h, tx, tz, tw, td = F * FLOOR, 0.05, 0.05, 1.9, 1.9
    else:
        lower = int(round(F * 0.65))
        blocks.append(blk(0.05, 0.05, 1.9, 1.9, 0, lower))
        blocks.append(blk(0.25, 0.25, 1.5, 1.5, lower, F - lower))
        top_h, tx, tz, tw, td = F * FLOOR, 0.25, 0.25, 1.5, 1.5
    # balcony ledge bands every 2 floors (2 authored bands, decor)
    for k in (2, 4):
        if k < F:
            blocks.append(blk_m(0.0, 0.0, 2.0, 2.0, k * FLOOR, 0.4,
                                decor=True, overhang=True))
    props = [
        box(0.25, 0.25, 0.45, 0.45, top_h, 3.0),      # stair box A
        box(1.3, 1.3, 0.45, 0.45, top_h, 3.0),        # stair box B
    ]
    return blocks, props


def a_store(lv, fx, fz):
    F = [1, 2, 3, 3, 4][lv - 1]
    s = float(fx)
    blocks = []
    if lv < 3:
        blocks.append(blk(0.05, 0.05, s - 0.1, s - 0.1, 0, F))
        top_h, tx, tz, tw, td = F * FLOOR, 0.05, 0.05, s - 0.1, s - 0.1
    elif lv < 5:
        lower = max(1, F - 1)
        blocks.append(blk(0.05, 0.05, s - 0.1, s - 0.1, 0, lower))
        blocks.append(blk(0.3, 0.3, s - 0.6, s - 0.6, lower, F - lower))
        top_h, tx, tz, tw, td = F * FLOOR, 0.3, 0.3, s - 0.6, s - 0.6
    else:
        # L5 department store: stepped upper floors (two setbacks)
        blocks.append(blk(0.05, 0.05, s - 0.1, s - 0.1, 0, F - 2))
        blocks.append(blk(0.3, 0.3, s - 0.6, s - 0.6, F - 2, 1))
        blocks.append(blk(0.55, 0.55, s - 1.1, s - 1.1, F - 1, 1))
        top_h, tx, tz, tw, td = F * FLOOR, 0.55, 0.55, s - 1.1, s - 1.1
    props = [
        band(0.0, 0.0, s, 0.18, F * FLOOR, 1.1),                   # parapet sign band
        band(0.0, s - 0.18, s, 0.18, F * FLOOR, 1.1),
        canopy(0.0, s - 0.55, s, 0.55, 3.0),                       # front canopy
        box(0.55 * s, 0.15 * s, 0.3, 0.3, top_h, 2.0),             # rooftop plant
        pad(0.0, s - 0.5, s, 0.5),                                 # customer apron
    ]
    return blocks, props


def a_office(lv, fx, fz):
    F = [4, 6, 9, 13, 18][lv - 1]
    blocks = []
    if lv < 3:
        blocks.append(blk(0.05, 0.05, 1.9, 1.9, 0, F))
        top_h, tx, tz, tw, td = F * FLOOR, 0.05, 0.05, 1.9, 1.9
    else:
        lower = int(round(F * 0.65))
        blocks.append(blk(0.05, 0.05, 1.9, 1.9, 0, lower))
        blocks.append(blk(0.2, 0.2, 1.6, 1.6, lower, F - lower))
        top_h, tx, tz, tw, td = F * FLOOR, 0.2, 0.2, 1.6, 1.6
    props = [
        box(tx + 0.15, tz + 0.15, 0.4, 0.35, top_h, 2.2),
        box(tx + 0.65, tz + 0.2, 0.35, 0.3, top_h, 1.6),
        box(tx + 0.25, tz + 0.75, 0.5, 0.3, top_h, 1.9),
        canopy(0.0, 1.55, 2.0, 0.45, 4.2),
    ]
    return blocks, props


def a_high_rise(lv, fx, fz):
    F = [12, 24, 36, 48, 62][lv - 1]
    blocks = []
    if lv < 3:
        blocks.append(blk(0.05, 0.05, 1.9, 1.9, 0, F))
        top_h, tx, tz, tw, td = F * FLOOR, 0.05, 0.05, 1.9, 1.9
    elif lv < 5:
        lower = int(round(F * 0.62))
        blocks.append(blk(0.05, 0.05, 1.9, 1.9, 0, lower))
        blocks.append(blk(0.25, 0.25, 1.5, 1.5, lower, F - lower))
        top_h, tx, tz, tw, td = F * FLOOR, 0.25, 0.25, 1.5, 1.5
    else:
        b1 = int(round(F * 0.55))
        b2 = int(round(F * 0.30))
        blocks.append(blk(0.05, 0.05, 1.9, 1.9, 0, b1))
        blocks.append(blk(0.25, 0.25, 1.5, 1.5, b1, b2))
        blocks.append(blk(0.45, 0.45, 1.1, 1.1, b1 + b2, F - b1 - b2))
        top_h, tx, tz, tw, td = F * FLOOR, 0.45, 0.45, 1.1, 1.1
    props = [
        mast(tx + tw * 0.5, tz + td * 0.5, top_h, max(8.0, F * 0.22), 0.5,
             signature=True, lod1=True),
        box(tx + 0.1, tz + 0.1, 0.35, 0.35, top_h, 2.6),
        canopy(0.0, 1.55, 2.0, 0.45, 4.2),
    ]
    return blocks, props


def a_data_center(lv, fx, fz):
    F = [2, 2, 3, 3, 4][lv - 1]
    blocks = []
    if lv < 3:
        blocks.append(blk(0.15, 0.15, 1.7, 1.7, 0, F, window="none"))
        top_h, tx, tz, tw, td = F * FLOOR, 0.15, 0.15, 1.7, 1.7
    else:
        blocks.append(blk(0.15, 0.15, 1.7, 1.7, 0, F - 1, window="none"))
        blocks.append(blk(0.35, 0.35, 1.3, 1.3, F - 1, 1, window="none"))
        top_h, tx, tz, tw, td = F * FLOOR, 0.35, 0.35, 1.3, 1.3
    props = [fence(0.0, 0.0, 2.0, 2.0, 2.2)]
    for i in range(4):                                    # chiller bank
        cx = tx + 0.12 + (i % 2) * (tw * 0.5)
        cz = tz + 0.12 + (i // 2) * (td * 0.5)
        props.append(box(cx, cz, 0.36, 0.32, top_h, 1.8, lod1=(i == 0), signature=(i == 0)))
    return blocks, props


def a_police(lv, fx, fz):
    F = [1, 2, 2, 3, 3][lv - 1]
    ant = [9.0, 11.0, 13.0, 15.0, 18.0][lv - 1]
    blocks = []
    if lv < 3:
        blocks.append(blk(0.05, 0.05, 1.5, 1.3, 0, F))
        top_h, tx, tz, tw, td = F * FLOOR, 0.05, 0.05, 1.5, 1.3
    else:
        blocks.append(blk(0.05, 0.05, 1.5, 1.3, 0, F - 1))
        blocks.append(blk(0.25, 0.2, 1.1, 1.0, F - 1, 1))
        top_h, tx, tz, tw, td = F * FLOOR, 0.25, 0.2, 1.1, 1.0
    props = [
        mast(1.35, 0.25, F * FLOOR, ant, 0.4, signature=True, lod1=True),
        pad(0.05, 1.45, 1.9, 0.5),                        # vehicle apron
        band(0.05, 0.02, 1.5, 0.12, 2.4, 0.45),           # blue stripe
        box(tx + 0.2, tz + 0.2, 0.4, 0.35, top_h, 1.5),
    ]
    return blocks, props


def a_fire(lv, fx, fz):
    F = [1, 2, 2, 3, 3][lv - 1]
    tower = [9.0, 11.5, 13.5, 16.0, 19.0][lv - 1]
    blocks = [blk(0.05, 0.05, 1.5, 1.2, 0, F)]
    if lv >= 3:
        blocks.append(blk(0.2, 0.2, 1.15, 0.9, F, 1))
    blocks.append(blk_m(1.58, 0.1, 0.36, 0.36, 0.0, tower, window="none"))  # hose tower
    top_h = max(F * FLOOR, tower)
    props = [
        notch(0.15, 1.18, 0.4, 0.14),                    # 3 bay doors
        notch(0.65, 1.18, 0.4, 0.14),
        notch(1.15, 1.18, 0.4, 0.14),
        band(0.05, 1.2, 1.5, 0.12, F * FLOOR - 0.6, 0.45),   # red stripe
        pad(0.05, 1.45, 1.9, 0.5),
    ]
    return blocks, props


def a_power(lv, fx, fz):
    F = [2, 2, 3, 3, 4][lv - 1]
    stack = [18.0, 22.0, 28.0, 34.0, 42.0][lv - 1]
    s = float(fx)
    blocks = [blk(0.1, 0.1, s * 0.62, s - 0.2, 0, F)]
    if lv >= 3:
        blocks.append(blk(0.3, 0.35, s * 0.35, s * 0.45, F, 1))
    props = [
        box(s * 0.72, 0.35, 0.42, 0.42, 0.0, stack, signature=True, lod1=True),
        box(s * 0.72, s - 0.77, 0.42, 0.42, 0.0, stack * 0.92, signature=True, lod1=True),
        fence(0.0, 0.0, s, s, 2.4),
        box(s * 0.68, s * 0.45, 0.5, 0.4, 0.0, 2.6),
        box(s * 0.68, s * 0.62, 0.5, 0.4, 0.0, 2.6),
    ]
    return blocks, props


def a_substation(lv, fx, fz):
    F = [1, 1, 2, 2, 3][lv - 1]
    pyl = [11.0, 13.0, 17.0, 21.0, 30.0][lv - 1]
    blocks = [blk(0.1, 0.1, 0.75, 0.7, 0, F)]
    if lv >= 3:
        blocks.append(blk(0.2, 0.18, 0.55, 0.5, F, 1))
    props = [
        mast(1.5, 1.5, 0.0, pyl, 0.9, signature=True, lod1=True),
        fence(0.0, 0.0, 2.0, 2.0, 2.4),
        box(1.0, 0.15, 0.4, 0.4, 0.0, 2.6),
        box(1.0, 0.75, 0.4, 0.4, 0.0, 2.6),
        box(0.15, 1.2, 0.4, 0.4, 0.0, 2.2),
    ]
    return blocks, props


def a_water(lv, fx, fz):
    F = [1, 2, 2, 3, 3][lv - 1]
    tank_h = [8.0, 10.0, 12.0, 15.0, 18.0][lv - 1]
    s = float(fx)
    tw = s * 0.45
    blocks = [blk(0.12, 0.12, s * 0.42, s * 0.38, 0, F)]
    if lv >= 3:
        blocks.append(blk(0.25, 0.22, s * 0.28, s * 0.24, F, 1))
    props = [
        octp(s - tw - 0.12, s - tw - 0.12, tw, tw, 0.0, tank_h,
             signature=True, lod1=True),
        fence(0.0, 0.0, s, s, 2.2),
        box(0.12, s * 0.6, s * 0.42, s * 0.3, 0.0, 1.4),       # filter bed
        box(s * 0.6, 0.12, s * 0.3, s * 0.3, 0.0, 1.4),
        box(s * 0.62, s * 0.62, 0.3, 0.28, 0.0, 2.4),          # chlorination shed
    ]
    return blocks, props


def a_yard(lv, fx, fz):
    F = [1, 2, 2, 3, 3][lv - 1]
    crane = [16.0, 20.0, 24.0, 27.0, 38.0][lv - 1]
    s = float(fx)
    blocks = [blk(0.1, 0.1, s * 0.45, s * 0.4, 0, F)]
    if lv >= 3:
        blocks.append(blk(0.2, 0.18, s * 0.3, s * 0.26, F, 1))
    props = [
        mast(s - 0.5, s - 0.5, 0.0, crane, 0.7, signature=True, lod1=True),
        fence(0.0, 0.0, s, s, 2.0),
        box(0.15, s * 0.62, s * 0.4, s * 0.28, 0.0, 2.2),   # material stacks
        box(s * 0.55, 0.15, s * 0.3, s * 0.3, 0.0, 1.8),
        pad(s * 0.5, s * 0.5, s * 0.45, s * 0.45),
    ]
    return blocks, props


ARCHETYPES = [
    ("house",             "res_house",       "residential", "gable_prism",
     [[1, 1]] * 5, a_house,      [1, 2, 2, 3, 3]),
    ("apartment",         "res_apartment",   "residential", "flat_stair_boxes",
     [[2, 2]] * 5, a_apartment,  [3, 4, 6, 8, 10]),
    ("store",             "com_retail",      "commercial",  "parapet_sign_band",
     [[1, 1], [1, 1], [2, 2], [2, 2], [2, 2]], a_store, [1, 2, 3, 3, 4]),
    ("office",            "com_office",      "commercial",  "hvac_cluster",
     [[2, 2]] * 5, a_office,     [4, 6, 9, 13, 18]),
    ("high_rise",         "res_highrise",    "residential", "setback_tower_mast",
     [[2, 2]] * 5, a_high_rise,  [12, 24, 36, 48, 62]),
    ("data_center",       "tech_datacenter", "tech",        "chiller_bank",
     [[2, 2]] * 5, a_data_center, [2, 2, 3, 3, 4]),
    ("police_station",    "civ_police",      "civic",       "antenna_mast",
     [[2, 2]] * 5, a_police,     [1, 2, 2, 3, 3]),
    ("fire_station",      "civ_fire",        "civic",       "hose_tower",
     [[2, 2]] * 5, a_fire,       [1, 2, 2, 3, 3]),
    ("power_facility",    "civ_utility",     "civic",       "twin_stacks",
     [[3, 3], [3, 3], [3, 3], [4, 4], [4, 4]], a_power, [2, 2, 3, 3, 4]),
    ("substation",        "civ_substation",  "civic",       "transformer_yard",
     [[2, 2]] * 5, a_substation, [1, 1, 2, 2, 3]),
    ("water_facility",    "civ_waterworks",  "civic",       "tank_cluster",
     [[3, 3], [3, 3], [3, 3], [3, 3], [4, 4]], a_water, [1, 2, 2, 3, 3]),
    ("construction_yard", "civ_yard",        "civic",       "crane_mast",
     [[2, 2], [2, 2], [2, 2], [3, 3], [3, 3]], a_yard, [1, 2, 2, 3, 3]),
]


def build():
    out = []
    for aid, doc11, family, sig, foots, fn, floors in ARCHETYPES:
        levels = []
        for lv in range(1, 6):
            fx, fz = foots[lv - 1]
            blocks, props = fn(lv, fx, fz)
            levels.append({"level": lv, "floors": floors[lv - 1],
                           "footprint_tiles": [fx, fz],
                           "level_marker": MARKERS[lv - 1],
                           "blocks": blocks, "roof_props": props})
        out.append({"id": aid, "doc11_id": doc11, "family": family,
                    "roof_signature": sig,
                    "footprint_tiles_by_level": foots, "levels": levels})
    return out




def build_document():
    data = build()
    return {
        "schema_version": 1,
        "generator_version": 3,
        "_owner": "doc 11 \u00a73.2 (rendering & performance). Generator input for tools/gen_graybox.gd.",
        "_generator": "tools/gen_building_shapes.py",
        "_roster_note": "The shipped roster is data/buildings.json's 12 archetypes (doc 02), not doc 11 \u00a72.14's 15-row placeholder table; doc11_id maps each shipped archetype onto the \u00a72.14 silhouette row it realises. Tri budgets, lod1_volume_keep_frac and the tall-archetype list are read from data/render.json \u00a78 'lod' and are never restated here.",
        "floor_height_m": FLOOR,
        "tile_m": TILE,
        "window_spacing_x_m": 3.2,
        "uv0_atlas_cells": 4,
        "ao": {
            "_rule": "doc 11 \u00a72.14 baked vertex-colour AO table, written to COLOR.rgb as a multiplier.",
            "default": 1.0,
            "facade_base": 0.55, "facade_band_m": 3.0,
            "inner_corner": 0.70, "inner_corner_dist_m": 1.0,
            "overhang_underside": 0.45,
            "roof_prop_contact": 0.65, "roof_prop_contact_m": 0.5,
        },
        "level_markers": {
            "_rule": "Cumulative per doc 11 \u00a72.14: L1 none; L2 +1 rooftop box; L3 +setback at 60% height (authored in blocks); L4 +crown band + 2 masts; L5 +spire with blinking red aviation beacon. Sizes are proportional to the top block so a house does not grow a skyscraper mast.",
            "sequence": MARKERS,
            "rooftop_box": MK["rooftop_box"],
            "crown_band": MK["crown_band"],
            "masts": MK["masts"],
            "spire": MK["spire"],
        },
        "lod1": {
            "_rule": "doc 11 \u00a72.14: keep blocks with volume >= lod.lod1_volume_keep_frac of total (data/render.json), drop decor (balcony ledges, sign bands, chamfers), replace roof_props with one AABB box UNLESS the archetype's signature props are flagged lod1 -- those are kept instead, because they are the silhouette that preserves archetype readability at 400 m. The 3 m AO band split is dropped at LOD1.",
            "ao_band_split": False,
            "merged_prop_box": True,
        },
        "silhouette": {
            "_rule": "doc 11 \u00a72.14 24-bit descriptor: [height_bucket:4][aspect_bucket:3][roof_sig_id:4][setback_count:2][mast_count:2][prop_count:3][notch_flags:3][windowless:1][footprint_id:2]. Tested in \u00a77.1 test 7.",
            "bits": [["height_bucket", 4], ["aspect_bucket", 3], ["roof_sig_id", 4],
                     ["setback_count", 2], ["mast_count", 2], ["prop_count", 3],
                     ["notch_flags", 3], ["windowless", 1], ["footprint_id", 2]],
            "height_buckets_m": HEIGHT_T,
            "slenderness_buckets": SLENDER_T,
            "notch_flag_bits": {"overhang_or_canopy": 1, "notch_or_apron": 2, "fenced_yard": 4},
            "roof_signature_id": {k: v for k, v in sorted(ROOF_SIG_ID.items(), key=lambda kv: kv[1])},
        },
        "far_mesh": {
            "_rule": "doc 11 \u00a72.14 LOD2: one shared 12-tri unit box for the whole city, scaled per instance to (fx*8, height_m, fz*8) by the FAR shader.",
            "id": "far_unit_box", "tris": 12,
        },
        "archetypes": data,
    }


def render_json(doc):
    text = json.dumps(doc, indent=1)
    prev = None
    while prev != text:
        prev = text
        text = re.sub(
            r"\[\s*\n\s*((?:-?[\d.]+(?:e-?\d+)?)(?:,\s*\n\s*-?[\d.]+(?:e-?\d+)?)*)\s*\n\s*\]",
            lambda m: "[" + ", ".join(x.strip() for x in m.group(1).split(",")) + "]", text)
    return text + "\n"


def validate(doc, render_path):
    failures = []
    tall = ["res_highrise", "com_highrise", "civ_stadium"]
    budget0, budget0_tall, budget1, ratio_max = 320, 420, 96, 0.40
    if os.path.exists(render_path):
        lod = json.load(open(render_path))["lod"]
        tall = lod["tall_archetypes"]
        budget0 = lod["tri_budget_lod0"]
        budget0_tall = lod["tri_budget_lod0_tall"]
        budget1 = lod["tri_budget_lod1"]
        ratio_max = lod["lod1_ratio_max"]
    desc = {}
    for arch in doc["archetypes"]:
        cap0 = budget0_tall if arch["doc11_id"] in tall else budget0
        prev_h = -1.0
        for lvl in arch["levels"]:
            t0, t1, h, d, _f = evaluate(arch, lvl)
            desc[(arch["id"], lvl["level"])] = d
            key = "%s L%d" % (arch["id"], lvl["level"])
            if t0 > cap0:
                failures.append("%s LOD0 %d > %d" % (key, t0, cap0))
            if t1 > budget1:
                failures.append("%s LOD1 %d > %d" % (key, t1, budget1))
            if t1 > ratio_max * t0:
                failures.append("%s LOD1 %d > %.2f x LOD0 %d" % (key, t1, ratio_max, t0))
            if h <= prev_h:
                failures.append("%s is not taller than the level below" % key)
            prev_h = h
    ids = [a["id"] for a in doc["archetypes"]]
    for lv in range(1, 6):
        for x, y in itertools.combinations(ids, 2):
            d = popcount(desc[(x, lv)] ^ desc[(y, lv)])
            if d < 4:
                failures.append("L%d %s vs %s silhouette Hamming %d < 4" % (lv, x, y, d))
    for a in ids:
        for l1, l2 in itertools.combinations(range(1, 6), 2):
            d = popcount(desc[(a, l1)] ^ desc[(a, l2)])
            if d < 2:
                failures.append("%s L%d vs L%d silhouette Hamming %d < 2" % (a, l1, l2, d))
    return failures


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default=os.path.join(os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))), "data"))
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    doc = build_document()
    render_path = os.path.join(args.out_dir, "render.json")
    failures = validate(doc, render_path)
    if failures:
        print("gen_building_shapes: %d FAILURES" % len(failures), file=sys.stderr)
        for f in failures:
            print("  FAIL %s" % f, file=sys.stderr)
        return 1

    text = render_json(doc)
    path = os.path.join(args.out_dir, "building_shapes.json")
    if args.check:
        if not os.path.exists(path):
            print("gen_building_shapes: %s missing" % path, file=sys.stderr)
            return 1
        if open(path).read() != text:
            print("gen_building_shapes: %s is out of sync with its generator" % path,
                  file=sys.stderr)
            return 1
        print("gen_building_shapes: all invariants pass, file in sync (--check)")
        return 0

    os.makedirs(args.out_dir, exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    print("gen_building_shapes: wrote %s" % path)
    print("  12 archetypes x 5 levels; every tri budget and silhouette "
          "Hamming distance verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
