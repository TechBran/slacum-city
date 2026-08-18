#!/usr/bin/env python3
"""Generate `data/starter_city.json` and `data/world.json` for SLACUM CITY.

Source of truth: `docs/design/09-map-land-starter-city.md` (post report-98,
recomputation R-16).  Every authored value below is transcribed from that
document -- the 7x7 attribute sheet (doc 09 s2.8.2), the 48x48 core ASCII map
(s2.9.2), the building manifest (s2.9.3), the power topology (s2.9.5), the
water topology (s2.9.6) and the tag registry (s2.9.7).

Every derived value is recomputed here and asserted against the doc's own
published figure.  If any invariant fails the script prints all failures and
exits non-zero WITHOUT writing either file: the JSON is only ever the output of
a fully validated run (doc 09 s3.1).

Usage:
    python3 tools/gen_starter_city.py [--out-dir DATA_DIR] [--check]

    --check   validate only; do not write.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Dict, List, Tuple

# --------------------------------------------------------------------------
# 0. World geometry (doc 09 s2.1)
# --------------------------------------------------------------------------

TILE_METERS = 8
BLOCK_TILES = 16
WORLD_BLOCKS = 7
WORLD_TILES = WORLD_BLOCKS * BLOCK_TILES  # 112
CORE_ORIGIN_BLOCK = (2, 2)
CORE_SIZE_BLOCKS = (3, 3)
CORE_TILES = CORE_SIZE_BLOCKS[0] * BLOCK_TILES  # 48
CORE_TILE_OFFSET = CORE_ORIGIN_BLOCK[0] * BLOCK_TILES  # 32 (core-local + 32 = global)
CITY_CENTER_TILE = (56, 56)
GRID_COLUMNS = "ABCDEFG"

# Road template (doc 09 s2.9.1): core-local road lines on both axes.
AVENUE_INDICES = [0, 15, 16, 31, 32, 47]
STREET_INDICES = [7, 23, 39]
AVENUE_NAMES_X = {0: "Levee Rd", 15: "Slacum Ave", 16: "Slacum Ave",
                  31: "Foundry Ave", 32: "Foundry Ave", 47: "Ridge Rd"}
AVENUE_NAMES_Z = {0: "North Loop", 15: "Grand Ave", 16: "Grand Ave",
                  31: "Canal St", 32: "Canal St", 47: "South Loop"}

# Doc 09 s2.9.1 / s2.9.4 published totals for the 48x48 core.
DOC_ROAD_TILES = 783
DOC_AVENUE_TILES = 540
DOC_STREET_TILES = 243
DOC_INTERSECTIONS = 81
DOC_ROAD_TILES_PER_BLOCK = 87
DOC_CLEAN_BUILDABLE = 169
DOC_B23_BUILDABLE_COUNT = 154
DOC_B23_BUILDABLE_EST = 159
DOC_VACANT_LOTS = 1429
DOC_FOOTPRINT_TILES = 77
DOC_WATER_TILES = 15

# --------------------------------------------------------------------------
# 1. Terrain / environment defaults (doc 09 s2.8.2 notes + s8.1 world.json)
# --------------------------------------------------------------------------

ENV_PROFILES = {
    "waterfront": {"wildfire": 0.05, "subsidence": 0.35, "pollution": 0.20, "wind": 0.25, "hazmat": 0.05},
    "flat_upland": {"wildfire": 0.20, "subsidence": 0.10, "pollution": 0.06, "wind": 0.22, "hazmat": 0.03},
    "flat_floodplain": {"wildfire": 0.10, "subsidence": 0.30, "pollution": 0.12, "wind": 0.20, "hazmat": 0.05},
    "hills": {"wildfire": 0.45, "subsidence": 0.20, "pollution": 0.04, "wind": 0.45, "hazmat": 0.02},
    "industrial_edge": {"wildfire": 0.30, "subsidence": 0.15, "pollution": 0.70, "wind": 0.20, "hazmat": 0.60},
}

ENV_RISK_WEIGHTS = {"flood": 0.35, "wildfire": 0.15, "subsidence": 0.15,
                    "pollution": 0.20, "wind": 0.10, "hazmat": 0.05}

VEGETATION_BY_TERRAIN = {"flat": 0.35, "waterfront": 0.45, "hills": 0.70, "industrial_edge": 0.20}
AMENITY = {"river": 0.75, "marsh": 0.35, "ridge": 0.80, "hills_low": 0.65,
           "farmland": 0.45, "flats": 0.35, "flat_other": 0.40, "industrial_edge": 0.10}
ELEVATION_M_BY_CLASS = [0, 5, 12, 22, 34]
ELEVATION_BAND_BY_CLASS = ["LOW", "LOW", "MID", "HIGH", "HIGH"]

# --------------------------------------------------------------------------
# 2. The 40 purchasable blocks -- doc 09 s2.8.2 attribute + price sheet.
#    Columns transcribed verbatim:
#    id, label, ring, terrain_class, dev_terrain, elev_class, flood, ERI,
#    waterfront_edges, arterial_connections(n), prestige, buildable, price, minLvl
# --------------------------------------------------------------------------

SHEET: List[Tuple[str, str, int, str, str, int, float, float, int, int, float, int, int, int]] = [
    ("B_1_1", "B2", 1, "flat", "gentle", 1, 0.45, 0.264, 1, 0, 0.00, 169, 9200, 0),
    ("B_2_1", "C2", 1, "flat", "flat", 2, 0.18, 0.143, 0, 1, 0.80, 169, 11600, 0),
    ("B_3_1", "D2", 1, "flat", "flat", 2, 0.18, 0.143, 0, 2, 0.80, 169, 12600, 0),
    ("B_4_1", "E2", 1, "flat", "flat", 2, 0.18, 0.143, 0, 2, 0.80, 169, 12600, 0),
    ("B_5_1", "F2", 1, "hills", "hilly", 3, 0.08, 0.180, 0, 0, 0.00, 158, 11100, 0),
    ("B_1_2", "B3", 1, "flat", "gentle", 1, 0.48, 0.275, 1, 1, 0.80, 169, 12800, 0),
    ("B_5_2", "F3", 1, "hills", "hilly", 3, 0.08, 0.180, 0, 1, 0.80, 158, 15500, 0),
    ("B_1_3", "B4", 1, "flat", "gentle", 1, 0.51, 0.285, 1, 1, 0.80, 169, 12700, 0),
    ("B_5_3", "F4", 1, "hills", "hilly", 3, 0.08, 0.180, 0, 2, 0.77, 158, 16700, 0),
    ("B_1_4", "B5", 1, "flat", "gentle", 1, 0.54, 0.296, 1, 1, 0.77, 169, 12500, 0),
    ("B_5_4", "F5", 1, "hills", "hilly", 3, 0.08, 0.180, 0, 2, 0.69, 158, 16300, 0),
    ("B_1_5", "B6", 1, "flat", "gentle", 1, 0.57, 0.306, 1, 0, 0.00, 169, 9000, 0),
    ("B_2_5", "C6", 1, "flat", "flat", 1, 0.30, 0.186, 0, 1, 0.77, 169, 10800, 0),
    ("B_3_5", "D6", 1, "industrial_edge", "forest", 1, 0.30, 0.363, 0, 1, 0.76, 169, 10300, 0),
    ("B_4_5", "E6", 1, "industrial_edge", "forest", 1, 0.30, 0.363, 0, 1, 0.69, 169, 10100, 0),
    ("B_5_5", "F6", 1, "industrial_edge", "forest", 2, 0.22, 0.335, 0, 0, 0.00, 169, 7900, 0),
    ("B_0_0", "A1", 2, "waterfront", "gentle", 0, 0.72, 0.380, 2, 0, 0.00, 116, 8500, 2),
    ("B_1_0", "B1", 2, "flat", "gentle", 1, 0.42, 0.253, 1, 0, 0.00, 169, 8500, 2),
    ("B_2_0", "C1", 2, "flat", "flat", 2, 0.18, 0.143, 0, 0, 0.00, 169, 7600, 2),
    ("B_3_0", "D1", 2, "flat", "flat", 2, 0.18, 0.143, 0, 1, 0.00, 169, 8300, 1),
    ("B_4_0", "E1", 2, "flat", "flat", 2, 0.18, 0.143, 0, 1, 0.00, 169, 8300, 1),
    ("B_5_0", "F1", 2, "flat", "flat", 2, 0.12, 0.122, 0, 0, 0.00, 169, 7700, 2),
    ("B_6_0", "G1", 2, "hills", "steep", 3, 0.06, 0.173, 0, 0, 0.00, 143, 13000, 2),
    ("B_0_1", "A2", 2, "waterfront", "gentle", 0, 0.74, 0.387, 2, 0, 0.00, 116, 8400, 2),
    ("B_6_1", "G2", 2, "hills", "steep", 4, 0.04, 0.166, 0, 0, 0.00, 143, 13600, 2),
    ("B_0_2", "A3", 2, "waterfront", "gentle", 0, 0.76, 0.394, 2, 0, 0.00, 116, 8400, 2),
    ("B_6_2", "G3", 2, "hills", "steep", 4, 0.04, 0.166, 0, 0, 0.00, 143, 13600, 2),
    ("B_0_3", "A4", 2, "waterfront", "gentle", 0, 0.78, 0.401, 2, 0, 0.00, 116, 8400, 2),
    ("B_6_3", "G4", 2, "hills", "steep", 4, 0.04, 0.166, 0, 1, 0.00, 143, 14800, 1),
    ("B_0_4", "A5", 2, "waterfront", "gentle", 0, 0.80, 0.408, 2, 0, 0.00, 116, 8300, 2),
    ("B_6_4", "G5", 2, "hills", "steep", 4, 0.04, 0.166, 0, 1, 0.00, 143, 14800, 1),
    ("B_0_5", "A6", 2, "waterfront", "marsh", 0, 0.88, 0.436, 3, 0, 0.00, 106, 6700, 2),
    ("B_6_5", "G6", 2, "hills", "steep", 4, 0.04, 0.166, 0, 0, 0.00, 143, 13600, 2),
    ("B_0_6", "A7", 2, "waterfront", "marsh", 0, 0.90, 0.443, 3, 0, 0.00, 106, 6700, 2),
    ("B_1_6", "B7", 2, "flat", "gentle", 1, 0.60, 0.317, 1, 0, 0.00, 169, 8200, 2),
    ("B_2_6", "C7", 2, "industrial_edge", "forest", 1, 0.42, 0.404, 0, 0, 0.00, 169, 6700, 2),
    ("B_3_6", "D7", 2, "industrial_edge", "forest", 1, 0.42, 0.404, 0, 0, 0.00, 169, 6700, 2),
    ("B_4_6", "E7", 2, "industrial_edge", "forest", 1, 0.42, 0.404, 0, 0, 0.00, 169, 6700, 2),
    ("B_5_6", "F7", 2, "industrial_edge", "forest", 2, 0.28, 0.356, 0, 0, 0.00, 169, 7200, 2),
    ("B_6_6", "G7", 2, "hills", "steep", 3, 0.10, 0.187, 0, 0, 0.00, 143, 12900, 2),
]

# Core blocks (doc 09 s2.9).  The 9 core blocks are OWNED / READY and the doc's
# s2.8.2 sheet covers only the 40 purchasable blocks, so their attributes are
# derived from the doc's own authored defaults:
#   * terrain `flat` / dev_terrain `flat` -- s2.8.1 shows the core inside the
#     Northfield/flats belt and every core block is AVENUE-fronted farmland-grade
#     ground; env profile `flat_upland` (s8.1 `env_profiles`).
#   * elevation_class 1 for block column C (bx 2) and 2 for D/E -- s2.7 states
#     "the whole core (5-12 m)" and pins WTR-2 (in B_2_3, C4) at elevation_m 5.
#   * flood_risk 0.30 on the class-1 column (the sheet's only flat class-1 block,
#     B_2_5 C6, is 0.30) and 0.18 on the class-2 columns (every flat class-2
#     block in the sheet is 0.18).
#   * amenity_score 0.40 = s8.1's `flat_other` bucket.
# See the summary note: the sheet's `prestige` column is NOT reproducible from
# any single authored core amenity value, so prestige is left derived (it is not
# a stored field in the s3.1 schema).
CORE_DISTRICT = {
    "B_2_2": "D_NORTHGATE", "B_3_2": "D_NORTHGATE", "B_4_2": "D_NORTHGATE",
    "B_2_3": "D_MILLPOND", "B_2_4": "D_MILLPOND",
    "B_3_3": "D_DOWNTOWN", "B_4_3": "D_DOWNTOWN",
    "B_3_4": "D_FOUNDRY", "B_4_4": "D_FOUNDRY",
}

# --------------------------------------------------------------------------
# 3. The 48x48 core ASCII map -- doc 09 s2.9.2, transcribed verbatim.
#    A AVENUE - c STREET - . vacant - ~ water
#    h house - H apartment - s store - O office
#    P power_facility - S substation - W WTR-1 - T WTR-2 (tank)
#    L police_station - F fire_station - Y construction_yard
# --------------------------------------------------------------------------

PLAIN = "A......c.......AA......c.......AA......c.......A"
STREET_ROW = "AccccccccccccccAAccccccccccccccAAccccccccccccccA"
AVENUE_ROW = "A" * 48

CORE_MAP: List[str] = [
    AVENUE_ROW,                                                          # 0
    "AYY.h.hcHH....hAAHH....ch.h.h..AAFF.h.hc.......A",                  # 1
    "AYY....cHH.....AAHH....c.......AAFF....c.......A",                  # 2
    "A.....hc.......AA......c.......AA.....hc.......A",                  # 3
    "A......c.......AAh.....c.......AA......c.......A",                  # 4
    PLAIN,                                                               # 5
    "A......c.......AA..h...c.......AA......c.......A",                  # 6
    STREET_ROW,                                                          # 7
    "Ah.....c.......AA......c.......AA......c.......A",                  # 8
    PLAIN, PLAIN, PLAIN, PLAIN, PLAIN, PLAIN,                            # 9-14
    AVENUE_ROW,                                                          # 15
    AVENUE_ROW,                                                          # 16
    "A....h.ch......AAs.s.s.cOO.s...AASS....c.......A",                  # 17
    "A......c.......AA......cOO.....AASS....c.......A",                  # 18
    "A~~~~~~c.......AA......c.......AA......c.......A",                  # 19
    "AWWW~~~c.......AA......c.......AA......c.......A",                  # 20
    "AWWW~~~c.......AA......c.......AA......c.......A",                  # 21
    "AWWW~~~c.......AA......c.......AA......c.......A",                  # 22
    STREET_ROW,                                                          # 23
    "ATT....c.......AA......cHH.....AA......c.......A",                  # 24
    "ATT....c.......AA......cHH.....AA......c.......A",                  # 25
    PLAIN, PLAIN, PLAIN, PLAIN, PLAIN,                                   # 26-30
    AVENUE_ROW,                                                          # 31
    AVENUE_ROW,                                                          # 32
    "ALL.h.hc.......AAs....hc.......AA......c.......A",                  # 33
    "ALL....c.......AA......c.......AA......c.......A",                  # 34
    PLAIN, PLAIN, PLAIN, PLAIN,                                          # 35-38
    STREET_ROW,                                                          # 39
    "A......c.......AA......c.......AA......cPPP....A",                  # 40
    "A......c.......AA......c.......AA......cPPP....A",                  # 41
    "A......c.......AA......c.......AA......cPPP....A",                  # 42
    PLAIN, PLAIN, PLAIN, PLAIN,                                          # 43-46
    AVENUE_ROW,                                                          # 47
]

GLYPH_TO_TYPE = {
    "h": ("house", None), "H": ("apartment", None), "s": ("store", None),
    "O": ("office", None), "P": ("power_facility", None), "S": ("substation", None),
    "W": ("water_facility", "pump"), "T": ("water_facility", "tank"),
    "L": ("police_station", None), "F": ("fire_station", None),
    "Y": ("construction_yard", None),
}

# --------------------------------------------------------------------------
# 4. Building manifest -- doc 09 s2.9.3.  (id, type, variant, origin, size, block)
# --------------------------------------------------------------------------

CIVIC_MANIFEST = [
    ("YARD-1", "construction_yard", None, (1, 1), (2, 2), "B_2_2"),
    ("FIRE-1", "fire_station", None, (33, 1), (2, 2), "B_4_2"),
    ("WTR-1", "water_facility", "pump", (1, 20), (3, 3), "B_2_3"),
    ("WTR-2", "water_facility", "tank", (1, 24), (2, 2), "B_2_3"),
    ("SUB-A", "substation", None, (33, 17), (2, 2), "B_4_3"),
    ("POL-1", "police_station", None, (1, 33), (2, 2), "B_2_4"),
    ("PLANT-1", "power_facility", None, (40, 40), (3, 3), "B_4_4"),
]

HOUSE_ORIGINS = [
    (4, 1), (6, 1), (14, 1), (6, 3), (1, 8),          # B_2_2 C3
    (24, 1), (26, 1), (28, 1), (17, 4), (19, 6),      # B_3_2 D3
    (36, 1), (38, 1), (38, 3),                        # B_4_2 E3
    (5, 17), (8, 17),                                 # B_2_3 C4
    (4, 33), (6, 33),                                 # B_2_4 C5
    (22, 33),                                         # B_3_4 D5
]
APARTMENT_ORIGINS = [(8, 1), (17, 1), (24, 24)]
STORE_ORIGINS = [(17, 17), (19, 17), (21, 17), (27, 17), (17, 33)]
OFFICE_ORIGINS = [(24, 17)]

MANIFEST_COUNTS = {"house": 18, "store": 5, "apartment": 3, "office": 1,
                   "construction_yard": 1, "fire_station": 1, "police_station": 1,
                   "substation": 1, "power_facility": 1, "water_facility": 2}

# Doc 09 s2.9.4 per-block table (contents / tax $-gh / pop / jobs) and the
# per-archetype L1 rows its arithmetic quotes (doc 03 base_tax, doc 02 pop/jobs).
ARCHETYPE_STATS = {  # (tax $/gh, population, jobs)
    "house": (12, 4, 0), "store": (26, 0, 6), "apartment": (70, 24, 2),
    "office": (130, 0, 30), "police_station": (0, 0, 12), "fire_station": (0, 0, 14),
    "power_facility": (0, 0, 20), "substation": (0, 0, 4), "water_facility": (0, 0, 10),
    "construction_yard": (0, 0, 16),
}
DOC_PER_BLOCK = {  # block -> (tax, pop, jobs)
    "B_2_2": (130, 44, 18), "B_3_2": (130, 44, 2), "B_4_2": (36, 12, 14),
    "B_2_3": (24, 8, 20), "B_3_3": (304, 24, 56), "B_4_3": (0, 0, 4),
    "B_2_4": (24, 8, 12), "B_3_4": (38, 4, 6), "B_4_4": (0, 0, 20),
}
DOC_TOTAL_TAX, DOC_TOTAL_POP, DOC_TOTAL_JOBS = 686, 144, 152

# --------------------------------------------------------------------------
# 5. Power topology -- doc 09 s2.9.5
# --------------------------------------------------------------------------

PLANT_TERMINAL = (39, 41)
SUB_TERMINAL = (32, 18)

TL1_PATH = [(39, 41), (39, 32), (32, 32), (32, 18)]
F_NORTH_PATH = [(32, 18), (32, 16), (0, 16)]
F_NORTH_LATERALS = [[(39, 16), (39, 7)], [(23, 16), (23, 7)], [(7, 16), (7, 7)]]
F_SOUTH_PATH = [(32, 18), (32, 32), (0, 32)]
F_SOUTH_LATERALS = [[(7, 32), (7, 39)], [(23, 32), (23, 39)],
                    [(32, 32), (39, 32), (39, 39)], [(0, 32), (0, 20)]]

DOC_TRANSMISSION_TILES = 30
DOC_FEEDER_TILES = 147
DOC_LINE_TILES = 177
DOC_LINE_KM = 1.42

# id, tile, feeder, level, night_load_kw, streetlights, signals
TRANSFORMERS = [
    ("T-01", (0, 0), "F_NORTH", 1, 15.1, 7, 1),
    ("T-02", (8, 0), "F_NORTH", 2, 35.5, 8, 1),
    ("T-03", (27, 0), "F_NORTH", 1, 10.9, 6, 0),
    ("T-04", (35, 0), "F_NORTH", 2, 60.4, 48, 6),
    ("T-05", (31, 1), "F_NORTH", 1, 12.9, 30, 4),
    ("T-06", (7, 2), "F_NORTH", 1, 18.6, 14, 1),
    ("T-07", (16, 3), "F_NORTH", 2, 52.4, 17, 2),
    ("T-08", (23, 3), "F_NORTH", 1, 12.6, 20, 2),
    ("T-09", (15, 5), "F_NORTH", 1, 7.5, 18, 2),
    ("T-10", (0, 7), "F_NORTH", 1, 9.9, 14, 1),
    ("T-11", (7, 14), "F_NORTH", 1, 21.2, 32, 2),
    ("T-12", (18, 15), "F_NORTH", 2, 44.7, 33, 4),
    ("T-13", (26, 15), "F_NORTH", 2, 60.1, 25, 2),
    ("T-14", (31, 17), "F_SOUTH", 2, 37.3, 91, 9),
    ("T-15", (0, 20), "F_SOUTH", 3, 135.1, 19, 3),
    ("T-16", (15, 21), "F_SOUTH", 1, 10.3, 26, 2),
    ("T-17", (23, 21), "F_SOUTH", 2, 40.8, 23, 1),
    ("T-18", (0, 24), "F_SOUTH", 1, 7.8, 7, 1),
    ("T-19", (3, 31), "F_SOUTH", 1, 21.2, 32, 2),
    ("T-20", (19, 31), "F_SOUTH", 1, 33.6, 49, 3),
    ("T-21", (0, 33), "F_SOUTH", 2, 43.7, 46, 6),
    ("T-22", (15, 33), "F_SOUTH", 1, 31.3, 74, 9),
    ("T-23", (39, 37), "F_SOUTH", 2, 60.6, 144, 17),
]
TRANSFORMER_CAPACITY_KW = {1: 50, 2: 150, 3: 400}      # doc 04 L1/L2/L3
TRANSFORMER_MVA = {1: 0.05, 2: 0.15, 3: 0.40}
TRANSFORMER_RADIUS = {1: 3, 2: 4, 3: 5}
TRANSFORMER_HEADROOM_FRAC = 0.70
DOC_TRANSFORMER_LEVELS = {1: 13, 2: 9, 3: 1}
DOC_RATED_MVA = 2.40
DOC_FEEDER_NIGHT_KW = {"F_NORTH": 361.8, "F_SOUTH": 421.6}
DOC_NIGHT_PEAK_KW = 783.3
DOC_STREETLIGHT_KW = 0.35
DOC_SIGNAL_KW = 0.6

# Reserved second-substation parcel and the designed tie-switch buy (s2.9.5).
RESERVED_SUBSTATION_PARCEL = {"block": "B_4_3", "from": [40, 24], "to": [46, 30]}
PLANNED_TIE_SWITCH = {"tile": [23, 23], "path": [[23, 16], [23, 32]], "length_tiles": 16}

# --------------------------------------------------------------------------
# 6. Water topology -- doc 09 s2.9.6
# --------------------------------------------------------------------------

WTR1_TERMINAL = (0, 20)
WTR2_TERMINAL = (0, 24)
MAINS = [
    ("M_RISER", [(0, 20), (0, 24)], 4),
    ("M_NORTH", [(0, 20), (0, 16), (47, 16)], 51),
    ("M_SOUTH", [(0, 24), (0, 32), (47, 32)], 55),
    ("M_TIE", [(23, 16), (23, 32)], 16),
]
HYDRANTS = [(8, 7), (24, 7), (40, 7), (8, 23), (24, 23), (40, 23), (8, 39), (24, 39), (40, 39)]
MAX_SERVICE_DISTANCE_TILES = 12
WATER_NODES = [
    # id, building, variant, subtype, terminal, base_kw, ratings
    ("WTR-1-SRC", "WTR-1", "source", "river", WTR1_TERMINAL, 32.0, {"yield_m3h": 107.0}),
    ("WTR-1-TRT", "WTR-1", "treatment", None, WTR1_TERMINAL, 40.0, {"throughput_m3h": 80.0}),
    ("WTR-1-PMP", "WTR-1", "pump", None, WTR1_TERMINAL, 60.0, {"rated_flow_m3h": 40.0, "head_m": 34}),
    ("WTR-2", "WTR-2", "tank", None, WTR2_TERMINAL, 5.0,
     {"capacity_m3": 120, "max_out_m3h": 66.5, "max_in_m3h": 26.5, "head_m": 30}),
]
DOC_WTR1_SITE_KW = 132.0
DOC_TANK_INITIAL_M3 = 108          # s3.1 authors volume_m3 108 against a 120 m3 capacity
DOC_WATER_DEMAND_M3H = 5.56

# --------------------------------------------------------------------------
# 7. Districts and tags -- doc 09 s2.9.4 / s2.9.7
# --------------------------------------------------------------------------

DISTRICTS = [
    ("D_NORTHGATE", "Northgate", "N", ["B_2_2", "B_3_2", "B_4_2"], 0),
    ("D_DOWNTOWN", "Downtown", "D", ["B_3_3", "B_4_3"], 1),
    ("D_MILLPOND", "Millpond", "M", ["B_2_3", "B_2_4"], 2),
    ("D_FOUNDRY", "Foundry Flats", "F", ["B_3_4", "B_4_4"], 3),
]

TUTORIAL_LOT_A = (11, 8)
TUTORIAL_LOT_B = (13, 8)

# --------------------------------------------------------------------------
# Validation harness
# --------------------------------------------------------------------------

FAILURES: List[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        FAILURES.append(message)


def check_eq(actual: Any, expected: Any, message: str) -> None:
    if actual != expected:
        FAILURES.append("%s: expected %r, got %r" % (message, expected, actual))


def check_close(actual: float, expected: float, tol: float, message: str) -> None:
    if abs(actual - expected) > tol:
        FAILURES.append("%s: expected %s +- %s, got %s" % (message, expected, tol, actual))


def half_up(value: float) -> int:
    """Round half away from zero -- matches Godot's roundi()."""
    return int(value + 0.5) if value >= 0 else -int(-value + 0.5)


# --------------------------------------------------------------------------
# Road template
# --------------------------------------------------------------------------

def road_class_at(x: int, z: int) -> str:
    if x in AVENUE_INDICES or z in AVENUE_INDICES:
        return "AVENUE"
    if x in STREET_INDICES or z in STREET_INDICES:
        return "STREET"
    return ""


def build_road_entries() -> List[Dict[str, Any]]:
    entries: List[Dict[str, Any]] = []
    for axis, names in (("x", AVENUE_NAMES_X), ("z", AVENUE_NAMES_Z)):
        for index in AVENUE_INDICES:
            entries.append({
                "axis": axis, "index": index, "class": "AVENUE", "name": names[index],
                "from": 0, "to": CORE_TILES - 1,
                "half": index in (0, CORE_TILES - 1),
            })
        for index in STREET_INDICES:
            entries.append({"axis": axis, "index": index, "class": "STREET",
                            "from": 0, "to": CORE_TILES - 1})
    return entries


def validate_roads(road_entries: List[Dict[str, Any]]) -> Dict[Tuple[int, int], str]:
    """Stamp the template, cross-check it against the ASCII map, count everything."""
    stamped: Dict[Tuple[int, int], str] = {}
    for entry in road_entries:
        for t in range(entry["from"], entry["to"] + 1):
            tile = (entry["index"], t) if entry["axis"] == "x" else (t, entry["index"])
            existing = stamped.get(tile)
            # AVENUE wins over STREET where the two cross.
            if existing is None or entry["class"] == "AVENUE":
                stamped[tile] = entry["class"]

    check_eq(len(road_entries), 18, "road template entry count (doc 09 s3.1)")
    check_eq(len(stamped), DOC_ROAD_TILES, "core road tiles (doc 09 s2.9.1)")
    check_eq(sum(1 for c in stamped.values() if c == "AVENUE"), DOC_AVENUE_TILES, "AVENUE tiles")
    check_eq(sum(1 for c in stamped.values() if c == "STREET"), DOC_STREET_TILES, "STREET tiles")

    road_indices = set(AVENUE_INDICES) | set(STREET_INDICES)
    intersections = sum(1 for (x, z) in stamped if x in road_indices and z in road_indices)
    check_eq(intersections, DOC_INTERSECTIONS, "road-grid intersections")

    # 87 road tiles per core block.
    for bj in range(3):
        for bi in range(3):
            count = sum(1 for (x, z) in stamped
                        if bi * 16 <= x < bi * 16 + 16 and bj * 16 <= z < bj * 16 + 16)
            check_eq(count, DOC_ROAD_TILES_PER_BLOCK, "road tiles in core block (%d,%d)" % (bi, bj))

    # The template must agree with the authored ASCII map, tile for tile.
    for z, row in enumerate(CORE_MAP):
        check_eq(len(row), CORE_TILES, "ASCII map row %d length" % z)
        for x, glyph in enumerate(row):
            expected = road_class_at(x, z)
            if glyph == "A":
                check_eq(expected, "AVENUE", "map (%d,%d) glyph A vs template" % (x, z))
            elif glyph == "c":
                check_eq(expected, "STREET", "map (%d,%d) glyph c vs template" % (x, z))
            else:
                check_eq(expected, "", "map (%d,%d) glyph %r on a template road tile" % (x, z, glyph))
    return stamped


# --------------------------------------------------------------------------
# Water tiles + buildings derived from the ASCII map
# --------------------------------------------------------------------------

def water_tiles_from_map() -> List[Tuple[int, int]]:
    tiles = [(x, z) for z, row in enumerate(CORE_MAP) for x, g in enumerate(row) if g == "~"]
    check_eq(len(tiles), DOC_WATER_TILES, "Mill Creek + Mill Pond water tiles (doc 09 s2.9.2)")
    # Creek (1-3, 19); pond (4-6, 19-22).
    expected = [(x, 19) for x in (1, 2, 3)] + [(x, z) for z in range(19, 23) for x in (4, 5, 6)]
    check_eq(sorted(tiles), sorted(expected), "water tile set")
    check((0, 19) not in tiles, "Levee Rd (0,19) is a culvert -- road, not water")
    return sorted(tiles, key=lambda t: (t[1], t[0]))


def buildings_from_map() -> List[Tuple[str, str, Tuple[int, int], Tuple[int, int]]]:
    """Connected components of identical building glyphs -> (type, variant, origin, size)."""
    seen = set()
    found = []
    for z, row in enumerate(CORE_MAP):
        for x, glyph in enumerate(row):
            if glyph not in GLYPH_TO_TYPE or (x, z) in seen:
                continue
            stack = [(x, z)]
            component = []
            seen.add((x, z))
            while stack:
                cx, cz = stack.pop()
                component.append((cx, cz))
                for nx, nz in ((cx + 1, cz), (cx - 1, cz), (cx, cz + 1), (cx, cz - 1)):
                    if 0 <= nx < CORE_TILES and 0 <= nz < CORE_TILES and (nx, nz) not in seen \
                            and CORE_MAP[nz][nx] == glyph:
                        seen.add((nx, nz))
                        stack.append((nx, nz))
            xs = [p[0] for p in component]
            zs = [p[1] for p in component]
            origin = (min(xs), min(zs))
            size = (max(xs) - min(xs) + 1, max(zs) - min(zs) + 1)
            check_eq(len(component), size[0] * size[1],
                     "glyph %r component at %s is not a filled rectangle" % (glyph, origin))
            btype, variant = GLYPH_TO_TYPE[glyph]
            found.append((btype, variant, origin, size))
    return found


def block_id_of(origin: Tuple[int, int]) -> str:
    bx = CORE_ORIGIN_BLOCK[0] + origin[0] // BLOCK_TILES
    bz = CORE_ORIGIN_BLOCK[1] + origin[1] // BLOCK_TILES
    return "B_%d_%d" % (bx, bz)


def build_buildings() -> List[Dict[str, Any]]:
    records: List[Dict[str, Any]] = []
    for bid, btype, variant, origin, size, block in CIVIC_MANIFEST:
        record = {"id": bid, "type": btype}
        if variant:
            record["variant"] = variant
        record.update({"level": 1, "origin": list(origin), "size": list(size),
                       "block": block, "rotation": 0, "tags": []})
        records.append(record)

    def add(prefix: str, btype: str, origins, size):
        for i, origin in enumerate(origins, start=1):
            records.append({"id": "%s-%03d" % (prefix, i), "type": btype, "level": 1,
                            "origin": list(origin), "size": list(size),
                            "block": block_id_of(origin), "rotation": 0, "tags": []})

    add("H", "house", HOUSE_ORIGINS, (1, 1))
    add("APT", "apartment", APARTMENT_ORIGINS, (2, 2))
    add("STR", "store", STORE_ORIGINS, (1, 1))
    add("OFF", "office", OFFICE_ORIGINS, (2, 2))
    # OFF-1 is named in the manifest; keep the doc's id.
    for record in records:
        if record["id"] == "OFF-001":
            record["id"] = "OFF-1"
    records.sort(key=lambda r: (r["origin"][1], r["origin"][0]))
    return records


def validate_buildings(records: List[Dict[str, Any]],
                       roads: Dict[Tuple[int, int], str],
                       water: List[Tuple[int, int]]) -> None:
    check_eq(len(records), 34, "building count (doc 09 s2.9.3)")

    counts: Dict[str, int] = {}
    for record in records:
        counts[record["type"]] = counts.get(record["type"], 0) + 1
        check_eq(record["level"], 1, "%s is Level 1 (doc 09 s2.9.2)" % record["id"])
    check_eq(counts, MANIFEST_COUNTS, "manifest archetype census")

    # Derived from the ASCII map, compared to the authored manifest.
    from_map = sorted((t, v, o, s) for (t, v, o, s) in buildings_from_map())
    from_manifest = sorted((r["type"], r.get("variant"), tuple(r["origin"]), tuple(r["size"]))
                           for r in records)
    check_eq(from_map, from_manifest, "ASCII map (s2.9.2) vs building manifest (s2.9.3)")

    water_set = set(water)
    occupied: Dict[Tuple[int, int], str] = {}
    footprint_tiles = 0
    for record in records:
        ox, oz = record["origin"]
        sx, sz = record["size"]
        check_eq(block_id_of((ox, oz)), record["block"], "%s stated block" % record["id"])
        road_adjacent = False
        for z in range(oz, oz + sz):
            for x in range(ox, ox + sx):
                footprint_tiles += 1
                check(0 <= x < CORE_TILES and 0 <= z < CORE_TILES,
                      "%s tile (%d,%d) out of core bounds" % (record["id"], x, z))
                check(block_id_of((x, z)) == record["block"],
                      "%s tile (%d,%d) crosses out of %s" % (record["id"], x, z, record["block"]))
                check((x, z) not in roads, "%s tile (%d,%d) on a road tile" % (record["id"], x, z))
                check((x, z) not in water_set, "%s tile (%d,%d) on water" % (record["id"], x, z))
                check((x, z) not in occupied,
                      "%s overlaps %s at (%d,%d)" % (record["id"], occupied.get((x, z)), x, z))
                occupied[(x, z)] = record["id"]
                for nx, nz in ((x + 1, z), (x - 1, z), (x, z + 1), (x, z - 1)):
                    if (nx, nz) in roads:
                        road_adjacent = True
        check(road_adjacent, "%s is not orthogonally adjacent to a road tile" % record["id"])
    check_eq(footprint_tiles, DOC_FOOTPRINT_TILES, "total footprint tiles (doc 09 s2.9.4)")

    # No two same-archetype buildings orthogonally adjacent (doc 09 s2.9.2).
    tile_type = {}
    for record in records:
        ox, oz = record["origin"]
        for z in range(oz, oz + record["size"][1]):
            for x in range(ox, ox + record["size"][0]):
                tile_type[(x, z)] = (record["type"], record["id"])
    for (x, z), (btype, bid) in tile_type.items():
        for nx, nz in ((x + 1, z), (x, z + 1)):
            other = tile_type.get((nx, nz))
            if other and other[1] != bid:
                check(other[0] != btype,
                      "same-archetype %s buildings %s and %s are orthogonally adjacent"
                      % (btype, bid, other[1]))

    # Vacant buildable lots (doc 09 s2.9.4).
    vacant = CORE_TILES * CORE_TILES - len(roads) - len(water_set) - footprint_tiles
    check_eq(vacant, DOC_VACANT_LOTS, "vacant buildable lots")

    # Tutorial lots must be vacant, buildable, in B_2_2.
    for tile, name in ((TUTORIAL_LOT_A, "tutorial_lot_a"), (TUTORIAL_LOT_B, "tutorial_lot_b")):
        check(tile not in roads and tile not in water_set and tile not in occupied,
              "%s at %s is not a vacant lot" % (name, tile))
        check_eq(block_id_of(tile), "B_2_2", "%s block" % name)

    # Per-block economy rollup (doc 09 s2.9.4 table).
    tax = pop = jobs = 0
    per_block: Dict[str, List[int]] = {b: [0, 0, 0] for b in CORE_DISTRICT}
    for record in records:
        t, p, j = ARCHETYPE_STATS[record["type"]]
        tax += t
        pop += p
        jobs += j
        row = per_block[record["block"]]
        row[0] += t
        row[1] += p
        row[2] += j
    for block, expected in DOC_PER_BLOCK.items():
        check_eq(tuple(per_block[block]), expected, "s2.9.4 per-block (tax,pop,jobs) for %s" % block)
    check_eq(tax, DOC_TOTAL_TAX, "starter gross base tax $/gh")
    check_eq(pop, DOC_TOTAL_POP, "starter population")
    check_eq(jobs, DOC_TOTAL_JOBS, "starter jobs")


# --------------------------------------------------------------------------
# Blocks
# --------------------------------------------------------------------------

def env_risk_index(env: Dict[str, float]) -> float:
    return sum(ENV_RISK_WEIGHTS[k] * env[k] for k in ENV_RISK_WEIGHTS)


def amenity_for(block_id: str, terrain: str, dev_terrain: str, bx: int, bz: int) -> float:
    if terrain == "waterfront":
        return AMENITY["marsh"] if dev_terrain == "marsh" else AMENITY["river"]
    if terrain == "hills":
        return AMENITY["ridge"] if bx == 6 else AMENITY["hills_low"]
    if terrain == "industrial_edge":
        return AMENITY["industrial_edge"]
    # flat
    if bx == 1:
        return AMENITY["flats"]
    if bz <= 1:                       # Northfield farmland, rows 1-2 (doc 09 s2.8.1)
        return AMENITY["farmland"]
    return AMENITY["flat_other"]


def build_blocks() -> List[Dict[str, Any]]:
    blocks: List[Dict[str, Any]] = []
    sheet_ids = set()

    for (bid, label, ring, terrain, dev_terrain, elev, flood, doc_eri,
         wf_edges, arterials, prestige, doc_buildable, price, min_level) in SHEET:
        sheet_ids.add(bid)
        bx, bz = int(bid.split("_")[1]), int(bid.split("_")[2])
        check_eq(label, "%s%d" % (GRID_COLUMNS[bx], bz + 1), "%s grid label" % bid)
        check_eq(max(abs(bx - 3), abs(bz - 3)), ring + 1, "%s ring vs d-from-centre" % bid)

        if terrain == "waterfront":
            profile = ENV_PROFILES["waterfront"]
        elif terrain == "hills":
            profile = ENV_PROFILES["hills"]
        elif terrain == "industrial_edge":
            profile = ENV_PROFILES["industrial_edge"]
        else:
            profile = ENV_PROFILES["flat_floodplain"] if bx == 1 else ENV_PROFILES["flat_upland"]

        env = {"flood": flood}
        env.update(profile)
        env = {k: env[k] for k in ("flood", "wildfire", "subsidence", "pollution", "wind", "hazmat")}
        check_close(env_risk_index(env), doc_eri, 0.0006, "%s env_risk_index vs s2.8.2 ERI" % bid)

        water_tiles = 0
        if bx == 0:
            water_tiles = 96 if dev_terrain == "marsh" else 80
        blocked = 0
        if terrain == "hills":
            blocked = 16 if bx == 5 else 40

        usable = 256 - water_tiles - blocked
        buildable_est = usable - half_up(0.34 * usable)
        check_eq(buildable_est, doc_buildable, "%s buildable estimate vs s2.8.2" % bid)

        if terrain == "hills":
            slope = 0.45 if bx == 5 else 0.70
        elif terrain == "waterfront":
            slope = 0.10
        elif terrain == "industrial_edge":
            slope = 0.10
        else:
            slope = 0.05

        blocks.append({
            "id": bid, "grid": [bx, bz], "label": label,
            "terrain_class": terrain, "dev_terrain": dev_terrain,
            "elevation_class": elev, "flood_risk": flood, "env_risk": env,
            "road_access": "ARTERIAL" if arterials > 0 else "NONE",
            "arterial_connections": arterials,
            "water_tiles": water_tiles, "blocked_tiles": blocked, "waterfront_edges": wf_edges,
            "amenity_score": amenity_for(bid, terrain, dev_terrain, bx, bz),
            "vegetation_density": VEGETATION_BY_TERRAIN[terrain],
            "slope_index": slope,
            "min_city_level": min_level,
            "ownership_state": "LOCKED", "development_state": "UNDEVELOPED",
            "district_id": None, "tags": ["tutorial_land_block"] if bid == "B_3_1" else [],
            "bridge_required": None, "satellite": None, "special_zone_id": None,
        })

    # The nine core blocks -- OWNED / READY (see the CORE_DISTRICT note above).
    for bz in range(2, 5):
        for bx in range(2, 5):
            bid = "B_%d_%d" % (bx, bz)
            check(bid not in sheet_ids, "%s must not appear in the purchasable sheet" % bid)
            elev = 1 if bx == 2 else 2
            flood = 0.30 if bx == 2 else 0.18
            env = {"flood": flood}
            env.update(ENV_PROFILES["flat_upland"])
            env = {k: env[k] for k in ("flood", "wildfire", "subsidence", "pollution", "wind", "hazmat")}
            water_tiles = DOC_WATER_TILES if bid == "B_2_3" else 0
            tags = ["tutorial_expansion_block"] if bid == "B_4_3" else []
            blocks.append({
                "id": bid, "grid": [bx, bz], "label": "%s%d" % (GRID_COLUMNS[bx], bz + 1),
                "terrain_class": "flat", "dev_terrain": "flat",
                "elevation_class": elev, "flood_risk": flood, "env_risk": env,
                "road_access": "ARTERIAL", "arterial_connections": 4,
                "water_tiles": water_tiles, "blocked_tiles": 0, "waterfront_edges": 0,
                "amenity_score": AMENITY["flat_other"],
                "vegetation_density": VEGETATION_BY_TERRAIN["flat"], "slope_index": 0.05,
                "min_city_level": 0,
                "ownership_state": "OWNED", "development_state": "READY",
                "district_id": CORE_DISTRICT[bid], "tags": tags,
                "bridge_required": None, "satellite": None, "special_zone_id": None,
            })

    blocks.sort(key=lambda b: (b["grid"][1], b["grid"][0]))
    return blocks


def validate_blocks(blocks: List[Dict[str, Any]]) -> None:
    check_eq(len(blocks), WORLD_BLOCKS * WORLD_BLOCKS, "world block count (doc 09 s2.1)")
    ids = {b["id"] for b in blocks}
    check_eq(len(ids), 49, "unique block ids")

    owned = [b for b in blocks if b["ownership_state"] == "OWNED"]
    check_eq(len(owned), 9, "OWNED blocks at t0")
    check(all(b["development_state"] == "READY" for b in owned), "every OWNED block is READY")
    check(all(b["development_state"] == "UNDEVELOPED"
              for b in blocks if b["ownership_state"] != "OWNED"),
          "no unowned block is developed")

    # Purchasability at city_level 0: full-edge contact with an OWNED block.
    by_grid = {(b["grid"][0], b["grid"][1]): b for b in blocks}
    purchasable = 0
    locked = 0
    for b in blocks:
        if b["ownership_state"] == "OWNED":
            continue
        bx, bz = b["grid"]
        touches = any((n := by_grid.get((bx + dx, bz + dz))) and n["ownership_state"] == "OWNED"
                      for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)))
        expected = "PURCHASABLE" if touches and b["min_city_level"] <= 0 else "LOCKED"
        b["ownership_state"] = expected
        if expected == "PURCHASABLE":
            purchasable += 1
        else:
            locked += 1
    check_eq(purchasable, 12, "PURCHASABLE blocks at t0 (doc 09 s2.5)")
    check_eq(locked, 28, "LOCKED blocks at t0")
    for diagonal in ("B_1_1", "B_5_1", "B_1_5", "B_5_5"):
        block = next(b for b in blocks if b["id"] == diagonal)
        check_eq(block["ownership_state"], "LOCKED",
                 "ring-1 diagonal %s is LOCKED on adjacency" % diagonal)

    for b in blocks:
        check(0 <= b["min_city_level"] <= 5, "%s min_city_level on the s2.11 ladder" % b["id"])
        check(0 <= b["elevation_class"] <= 4, "%s elevation_class range" % b["id"])
        check(0.0 <= b["flood_risk"] <= 1.0, "%s flood_risk range" % b["id"])
        check(b["water_tiles"] + b["blocked_tiles"] <= 256, "%s tile budget" % b["id"])

    # Doc 09 s2.2 worked drain-rate rows.
    for bid, expected in (("B_0_4", 9.0), ("B_1_3", 16.65), ("B_3_1", 26.75), ("B_6_2", 36.3)):
        b = next(x for x in blocks if x["id"] == bid)
        drain = 25.0 * (1 - 0.80 * b["flood_risk"]) * (1 + 0.50 * b["elevation_class"] / 4)
        check_close(drain, expected, 0.02, "%s drain_rate_mm_h (s2.2)" % bid)

    # Doc 09 s3.1's authored example row for B_3_1.
    b31 = next(b for b in blocks if b["id"] == "B_3_1")
    check_eq([b31["terrain_class"], b31["dev_terrain"], b31["elevation_class"], b31["flood_risk"],
              b31["road_access"], b31["arterial_connections"], b31["amenity_score"],
              b31["vegetation_density"], b31["slope_index"], b31["min_city_level"],
              b31["ownership_state"], b31["development_state"], b31["tags"]],
             ["flat", "flat", 2, 0.18, "ARTERIAL", 2, 0.45, 0.35, 0.05, 0,
              "PURCHASABLE", "UNDEVELOPED", ["tutorial_land_block"]],
             "B_3_1 matches the doc 09 s3.1 example row")

    b23 = next(b for b in blocks if b["id"] == "B_2_3")
    usable = 256 - b23["water_tiles"]
    check_eq(usable - half_up(0.34 * usable), DOC_B23_BUILDABLE_EST, "B_2_3 buildable estimate")
    check_eq(256 - DOC_ROAD_TILES_PER_BLOCK - b23["water_tiles"], DOC_B23_BUILDABLE_COUNT,
             "B_2_3 buildable count")


# --------------------------------------------------------------------------
# Power
# --------------------------------------------------------------------------

def polyline_length(path: List[Tuple[int, int]]) -> int:
    """Doc 09 s2.9.5's tile convention: the sum of the axis-aligned segment lengths."""
    total = 0
    for (x0, z0), (x1, z1) in zip(path, path[1:]):
        check(x0 == x1 or z0 == z1, "polyline segment %s->%s is not axis-aligned"
              % ((x0, z0), (x1, z1)))
        total += abs(x1 - x0) + abs(z1 - z0)
    return total


def polyline_tiles(path: List[Tuple[int, int]]) -> List[Tuple[int, int]]:
    tiles: List[Tuple[int, int]] = []
    for (x0, z0), (x1, z1) in zip(path, path[1:]):
        step_x = (x1 > x0) - (x1 < x0)
        step_z = (z1 > z0) - (z1 < z0)
        x, z = x0, z0
        while (x, z) != (x1, z1):
            tiles.append((x, z))
            x += step_x
            z += step_z
    tiles.append(path[-1])
    return tiles


def check_on_roads(path: List[Tuple[int, int]], roads: Dict[Tuple[int, int], str], label: str) -> None:
    for tile in polyline_tiles(path):
        check(tile in roads, "%s leaves the road right-of-way at %s" % (label, tile))


def build_power(records: List[Dict[str, Any]], roads: Dict[Tuple[int, int], str]) -> Dict[str, Any]:
    nodes: List[Dict[str, Any]] = [
        {"id": "PLANT-1", "kind": "plant_gas", "level": 1, "terminal": list(PLANT_TERMINAL), "tags": []},
        {"id": "SUB-A", "kind": "substation", "level": 1, "terminal": list(SUB_TERMINAL),
         "feeder_slots": 2, "tags": ["tutorial_substation"]},
    ]
    for tid, tile, feeder, level, night_kw, lights, signals in TRANSFORMERS:
        nodes.append({
            "id": tid, "kind": "transformer", "level": level, "tile": list(tile),
            "feeder": feeder, "night_load_kw": night_kw,
            "streetlights": lights, "signals": signals,
            "tags": ["tutorial_transformer"] if tid == "T-04" else [],
        })

    lines = [
        {"id": "TL-1", "kind": "transmission", "class": 1, "from": "PLANT-1", "to": "SUB-A",
         "overhead": True, "condition": 1.0, "path": [list(p) for p in TL1_PATH],
         "length_tiles": polyline_length(TL1_PATH)},
        {"id": "F_NORTH", "kind": "feeder", "class": 1, "overhead": True, "from": "SUB-A",
         "condition": 1.0, "path": [list(p) for p in F_NORTH_PATH],
         "laterals": [[list(p) for p in lat] for lat in F_NORTH_LATERALS],
         "length_tiles": polyline_length(F_NORTH_PATH)
                        + sum(polyline_length(lat) for lat in F_NORTH_LATERALS)},
        {"id": "F_SOUTH", "kind": "feeder", "class": 1, "overhead": True, "from": "SUB-A",
         "condition": 1.0, "path": [list(p) for p in F_SOUTH_PATH],
         "laterals": [[list(p) for p in lat] for lat in F_SOUTH_LATERALS],
         "length_tiles": polyline_length(F_SOUTH_PATH)
                         + sum(polyline_length(lat) for lat in F_SOUTH_LATERALS)},
    ]

    # --- validation -------------------------------------------------------
    check_eq(len(TRANSFORMERS), 23, "transformer count (doc 09 s2.9.5)")
    levels: Dict[int, int] = {}
    for tid, tile, feeder, level, night_kw, lights, signals in TRANSFORMERS:
        levels[level] = levels.get(level, 0) + 1
        check(tile in roads, "%s at %s is not on a road tile" % (tid, tile))
        capacity = TRANSFORMER_CAPACITY_KW[level]
        check(night_kw <= TRANSFORMER_HEADROOM_FRAC * capacity,
              "%s night load %.1f kW exceeds %.0f%% of %d kW"
              % (tid, night_kw, TRANSFORMER_HEADROOM_FRAC * 100, capacity))
        if level > 1:
            smaller = TRANSFORMER_CAPACITY_KW[level - 1]
            check(night_kw > TRANSFORMER_HEADROOM_FRAC * smaller,
                  "%s is authored above the smallest level that satisfies the headroom rule" % tid)
    check_eq(levels, DOC_TRANSFORMER_LEVELS, "transformer fleet by level")
    rated_mva = round(sum(TRANSFORMER_MVA[t[3]] for t in TRANSFORMERS), 4)
    check_close(rated_mva, DOC_RATED_MVA, 1e-9, "transformer rated_mva")

    check_eq(sum(t[5] for t in TRANSFORMERS), DOC_ROAD_TILES,
             "streetlight sinks == one per core road tile (doc 04 s2.3)")
    check_eq(sum(t[6] for t in TRANSFORMERS), DOC_INTERSECTIONS,
             "traffic-signal sinks == one per road intersection")

    # Feeder night-load rollups (doc 09 s2.9.5).  The authored per-transformer
    # column sums to 421.7 on F_SOUTH against the doc's stated 421.6 -- 0.1 kW of
    # rounding drift, tolerated here and reported.
    for feeder, expected in DOC_FEEDER_NIGHT_KW.items():
        total = round(sum(t[4] for t in TRANSFORMERS if t[2] == feeder), 4)
        check_close(total, expected, 0.15, "%s night load rollup" % feeder)
    total_night = round(sum(t[4] for t in TRANSFORMERS), 4)
    check_close(total_night, DOC_NIGHT_PEAK_KW, 0.25, "city night peak rollup (s2.9.4)")
    south_share = sum(t[4] for t in TRANSFORMERS if t[2] == "F_SOUTH") / total_night
    check_close(south_share, 0.538, 0.002, "F_SOUTH share of city load")
    check_close(DOC_ROAD_TILES * DOC_STREETLIGHT_KW, 274.05, 0.01, "streetlight load kW")
    check_close(DOC_INTERSECTIONS * DOC_SIGNAL_KW, 48.60, 0.01, "traffic-signal load kW")

    # Line inventory.
    transmission = polyline_length(TL1_PATH)
    feeders = (polyline_length(F_NORTH_PATH) + sum(polyline_length(l) for l in F_NORTH_LATERALS)
               + polyline_length(F_SOUTH_PATH) + sum(polyline_length(l) for l in F_SOUTH_LATERALS))
    check_eq(transmission, DOC_TRANSMISSION_TILES, "transmission line tiles")
    check_eq(feeders, DOC_FEEDER_TILES, "feeder line tiles")
    check_eq(transmission + feeders, DOC_LINE_TILES, "total line tiles")
    check_close((transmission + feeders) * TILE_METERS / 1000.0, DOC_LINE_KM, 0.01, "line_km")

    check_on_roads(TL1_PATH, roads, "TL-1")
    check_on_roads(F_NORTH_PATH, roads, "F_NORTH")
    check_on_roads(F_SOUTH_PATH, roads, "F_SOUTH")
    for lat in F_NORTH_LATERALS + F_SOUTH_LATERALS:
        check_on_roads(lat, roads, "feeder lateral %s" % (lat,))
    check(PLANT_TERMINAL in roads, "PLANT-1 terminal is on a road tile")
    check(SUB_TERMINAL in roads, "SUB-A terminal is on a road tile")
    check_eq(F_SOUTH_PATH[0], SUB_TERMINAL, "F_SOUTH starts at SUB-A")
    check_eq(F_NORTH_PATH[0], SUB_TERMINAL, "F_NORTH starts at SUB-A")
    check_eq(TL1_PATH[0], PLANT_TERMINAL, "TL-1 starts at PLANT-1")
    check_eq(TL1_PATH[-1], SUB_TERMINAL, "TL-1 ends at SUB-A")

    # Every building origin within its transformer's L1 service radius (3 tiles).
    for record in records:
        ox, oz = record["origin"]
        nearest = min(max(abs(ox - t[1][0]), abs(oz - t[1][1])) for t in TRANSFORMERS)
        check(nearest <= TRANSFORMER_RADIUS[1],
              "%s origin (%d,%d) is %d tiles from the nearest transformer (max 3)"
              % (record["id"], ox, oz, nearest))

    return {"nodes": nodes, "lines": lines, "tie_switches": [],
            "reserved_substation_parcel": RESERVED_SUBSTATION_PARCEL,
            "planned_tie_switch": PLANNED_TIE_SWITCH}


# --------------------------------------------------------------------------
# Water
# --------------------------------------------------------------------------

def build_water(roads: Dict[Tuple[int, int], str]) -> Dict[str, Any]:
    nodes: List[Dict[str, Any]] = []
    for nid, building, variant, subtype, terminal, base_kw, ratings in WATER_NODES:
        node = {"id": nid, "building": building, "variant": variant, "level": 1,
                "terminal": list(terminal), "base_kw": base_kw}
        if subtype:
            node["subtype"] = subtype
        node.update(ratings)
        if variant == "pump":
            node["pumps"] = [{"id": "P-1", "state": "ok", "tags": []},
                             {"id": "P-2", "state": "offline_manual", "tags": ["tutorial_pump"]}]
        if variant == "tank":
            node["volume_m3"] = DOC_TANK_INITIAL_M3
        node["tags"] = []
        nodes.append(node)

    mains = []
    for mid, path, doc_length in MAINS:
        length = polyline_length(path)
        check_eq(length, doc_length, "%s length (doc 09 s2.9.6)" % mid)
        check_on_roads(path, roads, mid)
        mains.append({"id": mid, "path": [list(p) for p in path], "length_tiles": length})

    # Block laterals: interior STREET from the nearest trunk main to the block centre.
    laterals = []
    for bj in range(3):
        for bi in range(3):
            cx, cz = bi * 16 + 7, bj * 16 + 7
            trunk_z = 16 if bj <= 1 else 32
            path = [(cx, trunk_z), (cx, cz)]
            check_on_roads(path, roads, "water lateral %s" % ((cx, cz),))
            laterals.append({"block": "B_%d_%d" % (2 + bi, 2 + bj),
                             "path": [list(p) for p in path],
                             "length_tiles": polyline_length(path)})

    check_eq(len(HYDRANTS), 9, "hydrant count (doc 09 s2.9.6)")
    for hydrant in HYDRANTS:
        check(hydrant in roads, "hydrant %s is not on a road tile" % (hydrant,))

    site_kw = sum(n[5] for n in WATER_NODES if n[1] == "WTR-1")
    check_close(site_kw, DOC_WTR1_SITE_KW, 1e-9, "WTR-1 site load kW (doc 09 s2.9.6)")
    tank = next(n for n in WATER_NODES if n[2] == "tank")
    check_eq(tank[6]["capacity_m3"], 120, "WTR-2 tank capacity")
    check_close(120 / DOC_WATER_DEMAND_M3H, 21.6, 0.05, "tank autonomy on the daily mean")
    check_close(120 / 7.10, 16.9, 0.05, "tank autonomy at the morning peak")
    check_close(120 / (6.24 + 2 * 8.0), 5.4, 0.05, "tank autonomy with two engines flowing")

    # Service coverage: every core tile within 12 tiles (Chebyshev) of a live main
    # tile and of a hydrant (doc 09 s7 test 7, doc 05 max_service_distance_tiles).
    main_tiles = set()
    for _, path, _ in MAINS:
        main_tiles.update(polyline_tiles(path))
    for lateral in laterals:
        main_tiles.update(polyline_tiles([tuple(p) for p in lateral["path"]]))
    worst_main = 0
    worst_hydrant = 0
    for z in range(CORE_TILES):
        for x in range(CORE_TILES):
            worst_main = max(worst_main, min(max(abs(x - mx), abs(z - mz)) for mx, mz in main_tiles))
            worst_hydrant = max(worst_hydrant,
                                min(max(abs(x - hx), abs(z - hz)) for hx, hz in HYDRANTS))
    check(worst_main <= MAX_SERVICE_DISTANCE_TILES,
          "core tile %d tiles from the nearest main (max %d)" % (worst_main, MAX_SERVICE_DISTANCE_TILES))
    check(worst_hydrant <= MAX_SERVICE_DISTANCE_TILES,
          "core tile %d tiles from the nearest hydrant (max %d)"
          % (worst_hydrant, MAX_SERVICE_DISTANCE_TILES))

    return {
        "nodes": nodes,
        "mains": mains,
        "laterals": laterals,
        "hydrants": [list(h) for h in HYDRANTS],
        "pressure_zones": [{"id": "Z1", "blocks": sorted(CORE_DISTRICT.keys())}],
        "max_service_distance_tiles": MAX_SERVICE_DISTANCE_TILES,
        "power_dependency": {
            "WTR-1": {"feeder": "F_SOUTH", "transformer": "T-15", "backup_coverage_frac": 0.0},
            "WTR-2": {"feeder": "F_SOUTH", "transformer": "T-18", "backup_coverage_frac": 0.0},
        },
    }


# --------------------------------------------------------------------------
# Districts + tags
# --------------------------------------------------------------------------

def build_districts(blocks: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    by_id = {b["id"]: b for b in blocks}
    out = []
    assigned = set()
    for did, name, label, members, color in DISTRICTS:
        check(len(members) <= 4, "%s holds at most 4 blocks (doc 09 s2.6)" % did)
        for bid in members:
            check(bid in by_id, "%s references unknown block %s" % (did, bid))
            check(bid not in assigned, "%s is claimed by two districts" % bid)
            assigned.add(bid)
            check_eq(by_id[bid]["district_id"], did, "%s district_id" % bid)
        # 4-connectivity of the membership set.
        coords = {tuple(by_id[b]["grid"]) for b in members}
        stack = [next(iter(coords))]
        seen = {stack[0]}
        while stack:
            x, z = stack.pop()
            for n in ((x + 1, z), (x - 1, z), (x, z + 1), (x, z - 1)):
                if n in coords and n not in seen:
                    seen.add(n)
                    stack.append(n)
        check_eq(len(seen), len(coords), "%s membership is 4-connected" % did)
        out.append({"id": did, "name": name, "label": label,
                    "blocks": list(members), "color_index": color})
    check_eq(sorted(assigned), sorted(CORE_DISTRICT.keys()),
             "every core block belongs to exactly one district")
    return out


def build_tags(blocks: List[Dict[str, Any]], records: List[Dict[str, Any]],
               power: Dict[str, Any], water: Dict[str, Any]) -> Dict[str, Any]:
    tags = {
        "tutorial_lot_a": {"kind": "tile", "tile": list(TUTORIAL_LOT_A), "block": "B_2_2"},
        "tutorial_lot_b": {"kind": "tile", "tile": list(TUTORIAL_LOT_B), "block": "B_2_2"},
        "tutorial_transformer": {"kind": "power_node", "id": "T-04"},
        "tutorial_pump": {"kind": "pump", "node": "WTR-1-PMP", "id": "P-2"},
        "tutorial_utility_vehicle": {"kind": "vehicle", "vehicle_type": "utility_service_truck",
                                     "home_building": "YARD-1"},
        "tutorial_expansion_block": {"kind": "block", "id": "B_4_3"},
        "tutorial_substation": {"kind": "power_node", "id": "SUB-A"},
        "tutorial_land_block": {"kind": "block", "id": "B_3_1"},
    }
    block_ids = {b["id"] for b in blocks}
    building_ids = {r["id"] for r in records}
    node_ids = {n["id"] for n in power["nodes"]}
    pump_ids = {(n["id"], p["id"]) for n in water["nodes"] for p in n.get("pumps", [])}

    for tag, entry in tags.items():
        kind = entry["kind"]
        if kind == "tile":
            x, z = entry["tile"]
            check(0 <= x < CORE_TILES and 0 <= z < CORE_TILES, "tag %s tile in core" % tag)
        elif kind == "block":
            check(entry["id"] in block_ids, "tag %s -> unknown block" % tag)
        elif kind == "power_node":
            check(entry["id"] in node_ids, "tag %s -> unknown power node" % tag)
        elif kind == "pump":
            check((entry["node"], entry["id"]) in pump_ids, "tag %s -> unknown pump" % tag)
        elif kind == "vehicle":
            check(entry["home_building"] in building_ids, "tag %s -> unknown home building" % tag)
        else:
            check(False, "tag %s has an unknown kind %r" % (tag, kind))

    # Inline `tags` arrays must agree with the registry.
    inline = []
    for b in blocks:
        inline.extend(b["tags"])
    for n in power["nodes"]:
        inline.extend(n["tags"])
    for n in water["nodes"]:
        for p in n.get("pumps", []):
            inline.extend(p["tags"])
    for tag in inline:
        check(tag in tags, "inline tag %r is missing from the registry" % tag)
    for expected in ("tutorial_land_block", "tutorial_expansion_block",
                     "tutorial_transformer", "tutorial_substation", "tutorial_pump"):
        check(expected in inline, "tag %r is not stamped on its entity" % expected)

    # P-2 must be the standby pump (doc 09 s7 test 9).
    pmp = next(n for n in water["nodes"] if n.get("variant") == "pump")
    p2 = next(p for p in pmp["pumps"] if p["id"] == "P-2")
    check_eq(p2["state"], "offline_manual", "tutorial_pump P-2 state")
    return tags


# --------------------------------------------------------------------------
# data/world.json -- doc 09 s8.1, transcribed verbatim
# --------------------------------------------------------------------------

def build_world_json() -> Dict[str, Any]:
    return {
        "schema_version": 2,
        "world": {
            "tile_meters": 8, "block_tiles": 16, "size_blocks": [7, 7],
            "core_origin_block": [2, 2], "core_size_blocks": [3, 3],
            "city_center_tile": [56, 56],
            "road_area_fraction": 0.34, "reference_buildable_tiles": 169,
            "grid_label_columns": "ABCDEFG", "grid_label_row_offset": 1,
        },
        "elevation_meters_by_class": [0, 5, 12, 22, 34],
        "elevation_band_by_class": ["LOW", "LOW", "MID", "HIGH", "HIGH"],
        "env_risk_weights": {
            "flood": 0.35, "wildfire": 0.15, "subsidence": 0.15,
            "pollution": 0.20, "wind": 0.10, "hazmat": 0.05,
        },
        "land_value_index": {"base": 0.25, "amenity_weight": 0.30,
                             "safety_weight": 0.25, "stability_weight": 0.20},
        "block_road_access_score": {"NONE": 0.00, "STUB": 0.35, "EDGE": 0.70, "ARTERIAL": 1.00},
        "_renamed": ("road_access_score -> block_road_access_score (report 98 C-61). Tile-level "
                     "road access is doc 10's access_quality(pos); this key is a block development "
                     "attribute and the two must never be conflated."),
        "flood": {
            "drain_base_mm_h": 25.0, "drain_flood_coeff": 0.80, "drain_elevation_coeff": 0.50,
            "impassable_at_depth_class": 2, "depth_classes": 3,
        },
        "development": {
            "phase_order": ["SURVEY", "CLEARING", "GRADING", "ROAD_INSTALL",
                            "UTILITY_CORRIDOR", "FINAL_DEVELOPMENT"],
            "crew_hours": {"SURVEY": 4, "CLEARING": 8, "GRADING": 12,
                           "ROAD_INSTALL": 14, "UTILITY_CORRIDOR": 16, "FINAL_DEVELOPMENT": 6},
            "primary_crew": {"SURVEY": "construction_crew", "CLEARING": "heavy_equipment_crew",
                             "GRADING": "heavy_equipment_crew", "ROAD_INSTALL": "road_crew",
                             "UTILITY_CORRIDOR": "heavy_equipment_crew",
                             "FINAL_DEVELOPMENT": "construction_crew"},
            "fallback_time_mult": {
                "SURVEY": {"road_crew": 1.0, "heavy_equipment_crew": 1.0, "crane_crew": 1.0},
                "CLEARING": {"construction_crew": 1.4},
                "GRADING": {"construction_crew": 1.6},
                "ROAD_INSTALL": {"construction_crew": 1.8},
                "UTILITY_CORRIDOR": {"road_crew": 1.3, "construction_crew": 2.0},
                "FINAL_DEVELOPMENT": {"road_crew": 1.0, "heavy_equipment_crew": 1.0,
                                      "crane_crew": 1.0},
            },
            "work_units_multiply_construction_rate": True,
            "_c29": ("Every work unit multiplies ctx.channels.construction_rate (24-h mean 0.804, "
                     "night floor 0.60) per report 98 C-29. Authored crew-hours are WORK, not wall time."),
            "first_block_time_mult": 0.48,
            "_first_block_retune": ("0.60 -> 0.48 (C-29): 97.6 crew-h x 0.48 = 46.85 crew-h / 0.804 "
                                    "= 58.27 gh wall time, preserving the one-session-plus-one-offline-gap "
                                    "beat that 0.60 delivered against the un-channelled figure."),
            "pause_allowed_mid_phase": False,
            "risk_hidden_until_survey": True, "pre_survey_risk_band": 0.20,
            "placement_requires_ready": True,
        },
        "terrain_defaults": {
            "vegetation_density": {"flat": 0.35, "waterfront": 0.45, "hills": 0.70,
                                   "industrial_edge": 0.20},
            "slope_index": {"flat": 0.05, "waterfront": 0.10, "hills_low": 0.45,
                            "hills_high": 0.70, "industrial_edge": 0.10},
            "amenity_score": {"river": 0.75, "marsh": 0.35, "ridge": 0.80, "hills_low": 0.65,
                              "farmland": 0.45, "flats": 0.35, "flat_other": 0.40,
                              "industrial_edge": 0.10},
            "dev_terrain_map": {"flat": "flat", "flats_floodplain": "gentle", "river": "gentle",
                                "marsh": "marsh", "hills_low": "hilly", "hills_high": "steep",
                                "industrial_edge": "forest"},
        },
        "env_profiles": {
            "waterfront": {"wildfire": 0.05, "subsidence": 0.35, "pollution": 0.20,
                           "wind": 0.25, "hazmat": 0.05},
            "flat_upland": {"wildfire": 0.20, "subsidence": 0.10, "pollution": 0.06,
                            "wind": 0.22, "hazmat": 0.03},
            "flat_floodplain": {"wildfire": 0.10, "subsidence": 0.30, "pollution": 0.12,
                                "wind": 0.20, "hazmat": 0.05},
            "hills": {"wildfire": 0.45, "subsidence": 0.20, "pollution": 0.04,
                      "wind": 0.45, "hazmat": 0.02},
            "industrial_edge": {"wildfire": 0.30, "subsidence": 0.15, "pollution": 0.70,
                                "wind": 0.20, "hazmat": 0.60},
        },
        "districts": {
            "min_blocks": 1, "max_blocks": 4,
            "reassign_cooldown_game_hours": 24,
            "reliability_ema_halflife_game_hours": 6,
            "auto_assign_prefers_same_terrain": True,
            "workforce_fraction_of_population": 0.55,
            "stability_weights": {"power": 0.30, "water": 0.20, "crime": 0.20,
                                  "road": 0.15, "employment": 0.10, "fire": 0.05},
            "district_dark_threshold": 0.60,
            "district_dark_weight": "population",
            "_c38": ("district_dark is the population-weighted aggregate of doc 04's per-block "
                     "block_dark; unweighted mean is the zero-population fallback."),
            "city_stability_weight": "population",
            "_c56": ("city_stability = population-weighted mean of district stability, on [0,1], "
                     "published by this doc. Doc 03 reads it as f_stability = 0.25 + 0.75*S^0.70 "
                     "with S already in [0,1]."),
        },
        "roads": {
            "boundary_arterial_tiles_per_side": 1,
            "interior_collector_block_local_index": 7,
            "widen_boundary_on_neighbour_development": True,
            "boundary_class": "AVENUE",
            "interior_class": "STREET",
            "player_placed_default_class": "STREET",
            "_c60": ("This doc owns the template; doc 10 owns the class semantics. 87 road tiles "
                     "per block; 540 AVENUE + 243 STREET in the 48x48 core."),
        },
        "starter": {
            "manifest": {"house": 18, "store": 5, "apartment": 3, "office": 1,
                         "construction_yard": 1, "fire_station": 1, "police_station": 1,
                         "substation": 1, "power_facility": 1, "water_facility": 2},
            "target_gross_tax_per_hour": 686,
            "target_population": 144, "target_jobs": 152,
            "target_jobs_market": 66, "target_jobs_civic": 86,
            "building_nameplate_kw": 402.0,
            "night_peak_kw": 783.3,
            "night_peak_hour": 20,
            "feeder_night_kw": {"F_NORTH": 361.8, "F_SOUTH": 421.6},
            "water_demand_m3h": 5.56,
            "water_peak_m3h": 7.10, "water_peak_hour": 7,
            "tank_autonomy_gh_mean": 21.6, "tank_autonomy_gh_peak": 16.9,
            "tank_autonomy_gh_two_engines": 5.4,
            "vacant_buildable_tiles": 1429,
            "transformer_headroom_frac": 0.70,
            "transformer_levels": {"L1": 13, "L2": 9, "L3": 1},
            "transformer_rated_mva_total": 2.40,
            "line_tiles": {"feeder": 147, "transmission": 30}, "line_km": 1.42,
            "hydrant_effective_radius_tiles": 12,
            "t0_city_stability": 0.9475, "t0_happiness": 82.0, "t0_city_level": 0,
        },
    }


def validate_cross_file(city: Dict[str, Any], world: Dict[str, Any]) -> None:
    """data/world.json's `starter` targets must describe data/starter_city.json."""
    starter = world["starter"]
    counts: Dict[str, int] = {}
    for record in city["buildings"]:
        counts[record["type"]] = counts.get(record["type"], 0) + 1
    check_eq(counts, starter["manifest"], "world.json starter manifest vs starter_city.json")
    check_eq(starter["vacant_buildable_tiles"], DOC_VACANT_LOTS, "world.json vacant lots")
    levels: Dict[str, int] = {}
    for node in city["power"]["nodes"]:
        if node["kind"] == "transformer":
            key = "L%d" % node["level"]
            levels[key] = levels.get(key, 0) + 1
    check_eq(levels, starter["transformer_levels"], "world.json transformer levels")
    feeder_tiles = sum(l["length_tiles"] for l in city["power"]["lines"] if l["kind"] == "feeder")
    trans_tiles = sum(l["length_tiles"] for l in city["power"]["lines"] if l["kind"] == "transmission")
    check_eq(feeder_tiles, starter["line_tiles"]["feeder"], "world.json feeder tiles")
    check_eq(trans_tiles, starter["line_tiles"]["transmission"], "world.json transmission tiles")
    check_eq(len(city["water"]["hydrants"]), 9, "hydrant count in the emitted file")
    check_eq(world["world"]["size_blocks"], list(city["world"]["size_blocks"]), "world size agreement")
    check_eq(world["world"]["city_center_tile"], list(city["world"]["city_center_tile"]),
             "city centre agreement")
    check_eq(world["world"]["reference_buildable_tiles"], DOC_CLEAN_BUILDABLE,
             "clean-block buildable reference")


# --------------------------------------------------------------------------
# JSON writer (stable, readable, compact where it helps)
# --------------------------------------------------------------------------

INLINE_LIMIT = 118


def _compact(value: Any) -> str:
    return json.dumps(value, separators=(", ", ": "), sort_keys=False)


def _encode(value: Any, level: int) -> str:
    pad = "  " * level
    pad_inner = "  " * (level + 1)
    if isinstance(value, dict):
        if not value:
            return "{}"
        flat = _compact(value)
        if len(flat) + len(pad) <= INLINE_LIMIT and "\n" not in flat:
            return flat
        items = ["%s%s: %s" % (pad_inner, json.dumps(k), _encode(v, level + 1))
                 for k, v in value.items()]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(value, list):
        if not value:
            return "[]"
        flat = _compact(value)
        if len(flat) + len(pad) <= INLINE_LIMIT and "\n" not in flat:
            return flat
        items = ["%s%s" % (pad_inner, _encode(v, level + 1)) for v in value]
        return "[\n" + ",\n".join(items) + "\n" + pad + "]"
    return json.dumps(value)


def write_json(path: str, payload: Dict[str, Any]) -> None:
    text = _encode(payload, 0) + "\n"
    # Round-trip guard: the emitted text must parse back to the same object.
    if json.loads(text) != json.loads(json.dumps(payload)):
        FAILURES.append("emitted JSON for %s does not round-trip" % path)
        return
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def build_starter_city() -> Dict[str, Any]:
    road_entries = build_road_entries()
    roads = validate_roads(road_entries)
    water_tiles = water_tiles_from_map()
    blocks = build_blocks()
    validate_blocks(blocks)
    records = build_buildings()
    validate_buildings(records, roads, water_tiles)
    power = build_power(records, roads)
    water = build_water(roads)
    districts = build_districts(blocks)
    tags = build_tags(blocks, records, power, water)

    return {
        "schema_version": 2,
        "world": {"size_blocks": [WORLD_BLOCKS, WORLD_BLOCKS], "tile_meters": TILE_METERS,
                  "block_tiles": BLOCK_TILES, "city_center_tile": list(CITY_CENTER_TILE),
                  "core_origin_block": list(CORE_ORIGIN_BLOCK),
                  "core_size_blocks": list(CORE_SIZE_BLOCKS)},
        "blocks": blocks,
        "roads": road_entries,
        "water_tiles": [list(t) for t in water_tiles],
        "buildings": records,
        "power": power,
        "water": water,
        "districts": districts,
        "population": {"attractiveness": 1.00, "happiness": 82.0,
                       "building_age_hours_default": 36},
        "tags": tags,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", default=None,
                        help="directory for the emitted JSON (default: <repo>/data)")
    parser.add_argument("--check", action="store_true", help="validate only, write nothing")
    args = parser.parse_args()

    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = args.out_dir or os.path.join(repo_root, "data")

    city = build_starter_city()
    world = build_world_json()
    validate_cross_file(city, world)

    if FAILURES:
        print("gen_starter_city: %d invariant(s) FAILED -- nothing written" % len(FAILURES),
              file=sys.stderr)
        for failure in FAILURES:
            print("  FAIL %s" % failure, file=sys.stderr)
        return 1

    if args.check:
        print("gen_starter_city: all invariants pass (--check, nothing written)")
        return 0

    os.makedirs(out_dir, exist_ok=True)
    write_json(os.path.join(out_dir, "starter_city.json"), city)
    write_json(os.path.join(out_dir, "world.json"), world)
    if FAILURES:
        for failure in FAILURES:
            print("  FAIL %s" % failure, file=sys.stderr)
        return 1

    print("gen_starter_city: wrote %s" % os.path.join(out_dir, "starter_city.json"))
    print("gen_starter_city: wrote %s" % os.path.join(out_dir, "world.json"))
    print("  49 blocks (9 OWNED/READY, 12 PURCHASABLE, 28 LOCKED) - 34 buildings"
          " - %d road tiles - %d line tiles - %d hydrants"
          % (DOC_ROAD_TILES, DOC_LINE_TILES, len(HYDRANTS)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
