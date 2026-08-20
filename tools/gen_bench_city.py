#!/usr/bin/env python3
"""Generate `tests/fixtures/bench_city.json` -- the benchmark city (doc 09 s2.13).

Doc 09 owns this generator (report 98 G-7); doc 11 consumes the fixture in its
draw-call regression test (s7.2 test 19), its fixture tripwire (test 26) and its
on-device flythrough (s7.4); doc 08 validates it against the save schema in CI
(test 37).

SAME GENERATOR FAMILY as `tools/gen_starter_city.py`, parameterised rather than
forked: this module *imports* that one and reuses its environment profiles, its
risk weights, its elevation ladder and its JSON encoder, so a change to the
block schema or the emitted formatting cannot leave the fixture behind.

WHAT IS DIFFERENT FROM THE STARTER CITY, and why
------------------------------------------------
The starter city is hand-authored content: an ASCII map, a manifest of named
buildings, a hand-solved transformer cover.  The benchmark city is *generated*
-- it has no narrative, only a shape and a size -- so the layout rules are
stated as code:

  * The world is still 7x7 land blocks (112x112 tiles).  `TileGrid.BLOCKS` is 7
    and `StarterCityLoader` requires exactly 49 block rows, so doc 09 s2.13's
    "8x8 world" is not reachable without a sim change; the fixture takes the
    6x6 DEVELOPED CORE the doc actually sizes its contents against and leaves
    the remaining 13 blocks as the purchasable ring.
  * The road template is doc 09 s2.9.1's, stamped per block instead of per
    3x3 core: AVENUE at block-local 0 and 15, STREET at block-local 7, on both
    axes.  That is 87 road tiles and 169 buildable tiles per block -- doc 09's
    published clean-block figures -- and 36 x 87 = 3,132 road tiles, which is
    the number doc 09 s2.13 states for the bench profile.
  * Buildings are packed by a RING PACKER: each of a block's four parcels is
    bounded by roads on all four sides, and buildings are placed flush against
    those edges, footprint extending inward.  Every building therefore has road
    frontage (doc 09's placement rule), and the block reads as a city block --
    built-up street walls, open courtyards -- rather than a solid slab.

Determinism is by construction: the archetype/level sequence comes from an
explicit 64-bit LCG seeded per parcel, never from `random`, so the output is
byte-identical across Python versions and machines (doc 09 test 40).

Usage:
    python3 tools/gen_bench_city.py [--profile bench] [--out PATH] [--check]

    --profile   bench (default, 1500 buildings) | reference (800, doc 08 s2.12)
    --out       output path (default: <repo>/tests/fixtures/bench_city.json)
    --check     validate only; write nothing
    --seed      LCG seed (default 20260819); changing it changes the city
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Dict, List, Optional, Sequence, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gen_starter_city as gsc  # noqa: E402  (same generator family, reused wholesale)

# --------------------------------------------------------------------------
# 0. Geometry -- constitution s6 and doc 09 s2.1, via gen_starter_city
# --------------------------------------------------------------------------

TILE_METERS = gsc.TILE_METERS          # 8
BLOCK_TILES = gsc.BLOCK_TILES          # 16
WORLD_BLOCKS = gsc.WORLD_BLOCKS        # 7  (TileGrid.BLOCKS -- not negotiable)
WORLD_TILES = gsc.WORLD_TILES          # 112
CORE_TILE_OFFSET = gsc.CORE_TILE_OFFSET  # 32 (StarterCityLoader.core_to_global)
GRID_COLUMNS = gsc.GRID_COLUMNS

CORE_ORIGIN_BLOCK = (0, 0)
CORE_SIZE_BLOCKS = (6, 6)
CORE_BLOCKS = CORE_SIZE_BLOCKS[0] * CORE_SIZE_BLOCKS[1]      # 36
CORE_TILES = CORE_SIZE_BLOCKS[0] * BLOCK_TILES               # 96
CITY_CENTER_TILE = (CORE_TILES // 2, CORE_TILES // 2)        # (48, 48) global

# Doc 09 s2.9.1's block road template, expressed per block instead of per core.
AVENUE_LOCAL = (0, 15)
STREET_LOCAL = (7,)
ROAD_LOCAL = tuple(sorted(AVENUE_LOCAL + STREET_LOCAL))      # (0, 7, 15)

# Doc 09 s2.9.4's published clean-block figures, asserted below.
DOC_ROAD_TILES_PER_BLOCK = gsc.DOC_ROAD_TILES_PER_BLOCK      # 87
DOC_CLEAN_BUILDABLE = gsc.DOC_CLEAN_BUILDABLE                # 169
DOC_BENCH_ROAD_TILES = CORE_BLOCKS * DOC_ROAD_TILES_PER_BLOCK  # 3,132

# The four road-bounded parcels of a block, in block-local tiles (inclusive).
#   x in [1,6] u [8,14],  z in [1,6] u [8,14]  ->  36 + 42 + 42 + 49 = 169
PARCELS: Tuple[Tuple[int, int, int, int], ...] = (
    (1, 1, 6, 6),
    (8, 1, 14, 6),
    (1, 8, 6, 14),
    (8, 8, 14, 14),
)

# --------------------------------------------------------------------------
# 1. Profiles (doc 09 s2.13 / s8 `bench_city.profiles`)
# --------------------------------------------------------------------------
#
# `starter` is NOT a profile here: `data/starter_city.json` is hand-authored
# content emitted by `tools/gen_starter_city.py`, and duplicating it would give
# the shipped city two sources of truth.  Doc 09 s2.13's table lists it for
# completeness of the family, not as an output of this script.

PROFILES: Dict[str, Dict[str, Any]] = {
    # 1,500 is doc 91's figure for the city doc 11 s2.13's device matrix is
    # written against, and the count this fixture is measured at.  Doc 09
    # s2.13's table row and s8's `bench_city.profiles.bench.buildings` move
    # with it (see the branch report's flagged doc edits).
    "bench": {"buildings": 1500, "districts": 12},
    # Doc 08 s2.12's coarse-step cost measurement wants a lighter city.
    "reference": {"buildings": 800, "districts": 24},
}

# --------------------------------------------------------------------------
# 2. Building roster
# --------------------------------------------------------------------------
#
# Footprints and families are READ FROM `game/meshes/generated/manifest.json`
# rather than restated: doc 11 test 26 asserts every archetype in the fixture
# resolves there, and a table copied by hand is exactly how that assertion
# starts passing against stale data.  The sim reads `size` from this file and
# the renderer reads the manifest, so the two must agree by construction.

MANIFEST_PATH = os.path.join("game", "meshes", "generated", "manifest.json")

# Level mix, weighted toward L2-L3 "so LOD tiers are all exercised" (doc 09
# s2.13) while keeping the electrical peak inside the grid built below.
LEVEL_WEIGHTS: Tuple[float, ...] = (0.26, 0.34, 0.24, 0.13, 0.03)

# Fill archetypes and their share of the non-civic roster.  `data_center` is
# deliberately rare and capped at L2: doc 02 prices it at 16.9 MW by L5, which
# would size the whole grid around eight buildings nobody can see the inside of.
FILL_MIX: Tuple[Tuple[str, float, int], ...] = (
    # (archetype, share, max_level)
    ("house", 0.50, 5),
    ("store", 0.22, 5),
    ("apartment", 0.16, 5),
    ("office", 0.07, 5),
    ("high_rise", 0.04, 5),
    ("data_center", 0.01, 2),
)

# Civic shells, placed before the fill so the fleet, the water plant and the
# grid have real homes.  Doc 11 s7.4 wants ~20 emergency vehicles; doc 06
# houses a roster per station, so the station count is what produces them.
CIVIC_ROSTER: Tuple[Tuple[str, str, int, int], ...] = (
    # (id_prefix, archetype, level, count)
    ("POL", "police_station", 2, 6),
    ("FIRE", "fire_station", 2, 6),
    ("YARD", "construction_yard", 1, 2),
    ("WTR", "water_facility", 2, 4),
)

# --------------------------------------------------------------------------
# 3. Electrical topology
# --------------------------------------------------------------------------
#
# Sized against `sim/power/power_grid.gd`'s tables, not against prose:
#   TRANSFORMER_SERVICE_RADIUS = [3, 4, 5, 6, 8]   CAPACITY.transformer[3] = 1000 kW
#   FEEDER_CAPACITY            = [1200, 3000, 7500]
#   SUBSTATION_FEEDER_SLOTS    = [2, 3, 4, 6, 8]   CAPACITY.substation[3]  = 60000 kW
#   CAPACITY.plant_gas[4]      = 120000 kW
#
# Four L5 transformers per block at block-local (3,3) (12,3) (3,12) (12,12).
# Chebyshev radius 8 from those four covers every tile of a 16x16 block several
# times over, so `attach_building`'s nearest-then-least-loaded tie-break always
# has a choice and no building can fall outside a service radius at any packing
# the ring packer produces.  The SIZE is set by the city, not the other way
# round: a 1,500-building core weighted to L2-L3 draws ~120 MW at night
# (measured, printed by --check), which four L4 transformers per block could
# not carry.  Doc 04 authors L5 components for exactly this city.
TRANSFORMER_LOCAL = ((3, 3), (12, 3), (3, 12), (12, 12))
TRANSFORMER_LEVEL = 5
TRANSFORMER_RADIUS = 8
TRANSFORMER_CAPACITY_KW = 2500.0

FEEDER_CLASS = 3          # 7,500 kW
FEEDER_CAPACITY_KW = 7500.0
SUBSTATION_LEVEL = 4      # 60,000 kW, 6 feeder slots
SUBSTATION_SLOTS = 6
SUBSTATION_COUNT = 6
SUBSTATION_CAPACITY_KW = 60000.0
PLANT_LEVEL = 5           # 120,000 kW
PLANT_COUNT = 2
PLANT_CAPACITY_KW = 120000.0
TRANSMISSION_CLASS = 2    # 90,000 kW

STREETLIGHT_KW = gsc.DOC_STREETLIGHT_KW   # 0.35, doc 04
SIGNAL_KW = gsc.DOC_SIGNAL_KW             # 0.60, doc 04

# Headroom the fixture must keep, so the benchmark city is a working city and
# not a rolling brownout that would make every render measurement a blackout.
TRANSFORMER_HEADROOM_FRAC = 0.70
PLANT_HEADROOM_FRAC = 0.60

MAX_SERVICE_DISTANCE_TILES = 12

# --------------------------------------------------------------------------
# 4. Water
# --------------------------------------------------------------------------
#
# Two lakes, each filling one 6x6 parcel exactly.  A parcel is road-bounded, so
# a lake never lands on a road tile and never splits a street wall; the packer
# simply skips the parcel.  72 water tiles total.
LAKE_PARCELS: Tuple[Tuple[int, int, int], ...] = (
    # (block_x, block_z, parcel_index)
    (0, 2, 0),
    (4, 4, 3),
)

FAILURES: List[str] = []
STATS: Dict[str, float] = {}


def check(condition: bool, message: str) -> None:
    if not condition:
        FAILURES.append(message)


def check_eq(actual: Any, expected: Any, message: str) -> None:
    check(actual == expected, "%s: got %r, expected %r" % (message, actual, expected))


# --------------------------------------------------------------------------
# 5. Deterministic stream
# --------------------------------------------------------------------------

class Lcg:
    """A 64-bit LCG (Knuth's MMIX constants).

    Python's `random` is stable across versions today, but the fixture's
    byte-identity guarantee (doc 09 test 40) should not rest on a stdlib
    promise; four lines of arithmetic make it structural instead.
    """

    __slots__ = ("state",)

    MASK = (1 << 64) - 1
    A = 6364136223846793005
    C = 1442695040888963407

    def __init__(self, seed: int) -> None:
        self.state = seed & self.MASK

    def next_u32(self) -> int:
        self.state = (self.state * self.A + self.C) & self.MASK
        return (self.state >> 32) & 0xFFFFFFFF

    def unit(self) -> float:
        return self.next_u32() / 4294967296.0

    def pick(self, weights: Sequence[float]) -> int:
        u = self.unit()
        acc = 0.0
        for i, w in enumerate(weights):
            acc += w
            if u < acc:
                return i
        return len(weights) - 1


def mix_seed(*parts: int) -> int:
    """Stable per-parcel seed. Splitmix64's finaliser over a packed key."""
    key = 0
    for p in parts:
        key = ((key << 16) ^ (key >> 3) ^ (p & 0xFFFF)) & Lcg.MASK
    key = (key + 0x9E3779B97F4A7C15) & Lcg.MASK
    key = ((key ^ (key >> 30)) * 0xBF58476D1CE4E5B9) & Lcg.MASK
    key = ((key ^ (key >> 27)) * 0x94D049BB133111EB) & Lcg.MASK
    return key ^ (key >> 31)


# --------------------------------------------------------------------------
# 6. Mesh manifest (footprints, families, heights)
# --------------------------------------------------------------------------

def load_manifest(repo_root: str) -> Dict[Tuple[str, int], Dict[str, Any]]:
    path = os.path.join(repo_root, MANIFEST_PATH)
    if not os.path.exists(path):
        FAILURES.append("mesh manifest missing: %s (run tools/gen_graybox.gd)" % path)
        return {}
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    table: Dict[Tuple[str, int], Dict[str, Any]] = {}
    for entry in payload.get("meshes", []):
        if int(entry.get("lod", 0)) != 0:
            continue
        table[(str(entry["archetype"]), int(entry["level"]))] = entry
    return table


def load_economy(repo_root: str) -> Dict[str, List[Dict[str, Any]]]:
    with open(os.path.join(repo_root, "data", "buildings.json"), "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    return {k: v["levels"] for k, v in payload["archetypes"].items()}


# --------------------------------------------------------------------------
# 7. Blocks
# --------------------------------------------------------------------------

def is_core(bx: int, bz: int) -> bool:
    return (CORE_ORIGIN_BLOCK[0] <= bx < CORE_ORIGIN_BLOCK[0] + CORE_SIZE_BLOCKS[0]
            and CORE_ORIGIN_BLOCK[1] <= bz < CORE_ORIGIN_BLOCK[1] + CORE_SIZE_BLOCKS[1])


def block_id(bx: int, bz: int) -> str:
    return "B_%d_%d" % (bx, bz)


def block_label(bx: int, bz: int) -> str:
    return "%s%d" % (GRID_COLUMNS[bx], bz + 1)


def terrain_of(bx: int, bz: int, lake_blocks: Dict[Tuple[int, int], int]) -> str:
    if (bx, bz) in lake_blocks:
        return "waterfront"
    if bx == WORLD_BLOCKS - 1 or bz == WORLD_BLOCKS - 1:
        return "hills"
    if bz == 0:
        return "flat_floodplain"
    if bx == 0:
        return "industrial_edge"
    return "flat_upland"


def build_blocks(lake_blocks: Dict[Tuple[int, int], int],
                 districts_of_block: Dict[str, str]) -> List[Dict[str, Any]]:
    blocks: List[Dict[str, Any]] = []
    for bz in range(WORLD_BLOCKS):
        for bx in range(WORLD_BLOCKS):
            bid = block_id(bx, bz)
            core = is_core(bx, bz)
            terrain = terrain_of(bx, bz, lake_blocks)
            env = dict(gsc.ENV_PROFILES[terrain])
            # Flood risk falls with distance from the north-west lowland, the
            # same shape doc 09 s2.8.2 authors by hand for the starter sheet.
            flood = round(max(0.05, 0.62 - 0.055 * (bx + bz)), 2)
            env["flood"] = flood
            elevation_class = min(4, (bx + bz) // 3)
            water_tiles = lake_blocks.get((bx, bz), 0)
            dev_terrain = "flat" if elevation_class <= 1 else (
                "gentle" if elevation_class == 2 else "steep")
            terrain_family = ("waterfront" if terrain == "waterfront"
                              else "hills" if terrain == "hills"
                              else "industrial_edge" if terrain == "industrial_edge"
                              else "flat")
            blocks.append({
                "id": bid,
                "grid": [bx, bz],
                "label": block_label(bx, bz),
                "terrain_class": terrain_family,
                "dev_terrain": dev_terrain,
                "elevation_class": elevation_class,
                "flood_risk": flood,
                "env_risk": {k: env[k] for k in
                             ("flood", "wildfire", "subsidence", "pollution", "wind", "hazmat")},
                "road_access": "ARTERIAL" if core else ("EDGE" if _touches_core(bx, bz) else "NONE"),
                "arterial_connections": 4 if core else (1 if _touches_core(bx, bz) else 0),
                "water_tiles": water_tiles,
                "blocked_tiles": 0,
                "waterfront_edges": 1 if water_tiles else 0,
                "amenity_score": round(gsc.AMENITY["river"] if water_tiles
                                       else 0.40 + 0.02 * ((bx * 3 + bz) % 6), 2),
                "vegetation_density": gsc.VEGETATION_BY_TERRAIN[terrain_family],
                "slope_index": round(0.05 * (elevation_class + 1), 2),
                "min_city_level": 0 if core else (1 if _touches_core(bx, bz) else 2),
                "ownership_state": "OWNED" if core else (
                    "PURCHASABLE" if _touches_core(bx, bz) else "LOCKED"),
                "development_state": "READY" if core else "UNDEVELOPED",
                "district_id": districts_of_block.get(bid),
                "tags": [],
                "bridge_required": None,
                "satellite": None,
                "special_zone_id": None,
            })
    return blocks


def _touches_core(bx: int, bz: int) -> bool:
    if is_core(bx, bz):
        return False
    for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        if is_core(bx + dx, bz + dz):
            return True
    return False


# --------------------------------------------------------------------------
# 8. Roads
# --------------------------------------------------------------------------

def build_road_entries() -> List[Dict[str, Any]]:
    """Doc 09 s2.9.1's template, stamped per block across the 6x6 core.

    Coordinates are CORE-LOCAL, i.e. global - 32, because
    `StarterCityLoader.core_to_global` adds a fixed 32.  With the core at block
    (0,0) that makes the near edge -32; the loader handles it (it is plain
    arithmetic) and the resulting global tiles are 0..95, inside the grid.
    """
    entries: List[Dict[str, Any]] = []
    span_from = -CORE_TILE_OFFSET
    span_to = CORE_TILES - 1 - CORE_TILE_OFFSET
    for axis in ("x", "z"):
        for b in range(CORE_SIZE_BLOCKS[0 if axis == "x" else 1]):
            base = b * BLOCK_TILES
            for local in ROAD_LOCAL:
                road_class = "AVENUE" if local in AVENUE_LOCAL else "STREET"
                entries.append({
                    "axis": axis,
                    "index": base + local - CORE_TILE_OFFSET,
                    "class": road_class,
                    "name": _road_name(axis, b, local),
                    "from": span_from,
                    "to": span_to,
                    "half": road_class == "AVENUE" and local in AVENUE_LOCAL,
                })
    return entries


def _road_name(axis: str, block_index: int, local: int) -> str:
    if axis == "x":
        return "%s Ave" % GRID_COLUMNS[block_index] if local in AVENUE_LOCAL \
            else "%s St" % GRID_COLUMNS[block_index]
    return "%d Ave" % (block_index + 1) if local in AVENUE_LOCAL else "%d St" % (block_index + 1)


def road_tile_set() -> Dict[Tuple[int, int], str]:
    """Global tile -> road class, for the whole developed core."""
    lines_x: Dict[int, str] = {}
    lines_z: Dict[int, str] = {}
    for b in range(CORE_SIZE_BLOCKS[0]):
        for local in ROAD_LOCAL:
            cls = "AVENUE" if local in AVENUE_LOCAL else "STREET"
            g = b * BLOCK_TILES + local
            # AVENUE wins where the classes cross (doc 09 s2.9.1).
            if lines_x.get(g) != "AVENUE":
                lines_x[g] = cls
            if lines_z.get(g) != "AVENUE":
                lines_z[g] = cls
    roads: Dict[Tuple[int, int], str] = {}
    for x, cls in lines_x.items():
        for z in range(CORE_TILES):
            roads[(x, z)] = cls
    for z, cls in lines_z.items():
        for x in range(CORE_TILES):
            if roads.get((x, z)) != "AVENUE":
                roads[(x, z)] = cls
    return roads


# --------------------------------------------------------------------------
# 9. Building placement -- the ring packer
# --------------------------------------------------------------------------

def parcel_rect(bx: int, bz: int, index: int) -> Tuple[int, int, int, int]:
    """Global-tile inclusive rect of one road-bounded parcel."""
    x0, z0, x1, z1 = PARCELS[index]
    ox, oz = bx * BLOCK_TILES, bz * BLOCK_TILES
    return ox + x0, oz + z0, ox + x1, oz + z1


def ring_slots(rect: Tuple[int, int, int, int]) -> List[Tuple[int, int, str]]:
    """Anchor tiles along a parcel's four edges, in a stable clockwise order.

    `side` says which way the footprint grows: a building on the north edge
    extends south, one on the east edge extends west, and so on, so every
    building's street face is on the road and its back is on the courtyard.
    """
    x0, z0, x1, z1 = rect
    slots: List[Tuple[int, int, str]] = []
    for x in range(x0, x1 + 1):
        slots.append((x, z0, "N"))
    for z in range(z0 + 1, z1 + 1):
        slots.append((x1, z, "E"))
    for x in range(x1 - 1, x0 - 1, -1):
        slots.append((x, z1, "S"))
    for z in range(z1 - 1, z0, -1):
        slots.append((x0, z, "W"))
    return slots


def footprint_origin(anchor: Tuple[int, int], side: str, size: Tuple[int, int]) -> Tuple[int, int]:
    ax, az = anchor
    w, h = size
    if side == "N":
        return ax, az
    if side == "S":
        return ax, az - h + 1
    if side == "E":
        return ax - w + 1, az
    return ax, az


class Packer:
    """Places buildings on parcel rings, tracking occupancy per block."""

    def __init__(self, manifest: Dict[Tuple[str, int], Dict[str, Any]],
                 reserved: Dict[Tuple[int, int], str],
                 water: Dict[Tuple[int, int], bool]) -> None:
        self.manifest = manifest
        self.reserved = reserved
        self.water = water
        self.occupied: Dict[Tuple[int, int], str] = {}
        self.records: List[Dict[str, Any]] = []
        self._next_id = 1

    def size_of(self, archetype: str, level: int) -> Tuple[int, int]:
        entry = self.manifest.get((archetype, level))
        if entry is None:
            FAILURES.append("no mesh manifest entry for %s L%d" % (archetype, level))
            return (1, 1)
        foot = entry["footprint_tiles"]
        return int(foot[0]), int(foot[1])

    def fits(self, origin: Tuple[int, int], size: Tuple[int, int],
             rect: Tuple[int, int, int, int]) -> bool:
        ox, oz = origin
        w, h = size
        x0, z0, x1, z1 = rect
        if ox < x0 or oz < z0 or ox + w - 1 > x1 or oz + h - 1 > z1:
            return False
        for z in range(oz, oz + h):
            for x in range(ox, ox + w):
                key = (x, z)
                if key in self.occupied or key in self.reserved or key in self.water:
                    return False
        return True

    def place(self, archetype: str, level: int, origin: Tuple[int, int],
              size: Tuple[int, int], bid: str, prefix: str,
              variant: Optional[str] = None) -> Dict[str, Any]:
        ox, oz = origin
        w, h = size
        for z in range(oz, oz + h):
            for x in range(ox, ox + w):
                self.occupied[(x, z)] = prefix
        record: Dict[str, Any] = {
            "id": "%s-%04d" % (prefix, self._next_id),
            "type": archetype,
            "level": level,
            "origin": [ox - CORE_TILE_OFFSET, oz - CORE_TILE_OFFSET],
            "size": [w, h],
            "block": bid,
            "rotation": 0,
            "tags": [],
        }
        if variant is not None:
            record["variant"] = variant
        self._next_id += 1
        self.records.append(record)
        return record


def plan_roster(profile: Dict[str, Any], seed: int) -> Dict[Tuple[int, int], List[Tuple[str, int]]]:
    """Per-block (archetype, level) sequences, deterministic and quota-exact."""
    total = int(profile["buildings"])
    pre_placed = (sum(count for _, _, _, count in CIVIC_ROSTER)
                  + SUBSTATION_COUNT + PLANT_COUNT)
    fill_total = total - pre_placed
    check(fill_total > 0, "profile too small to carry the civic roster")

    # Whole-number split of the fill mix by largest remainder, so the roster
    # sums to exactly `fill_total` no matter how the shares round.
    raw = [(archetype, fill_total * share, cap) for archetype, share, cap in FILL_MIX]
    counts = [(archetype, int(value), value - int(value), cap) for archetype, value, cap in raw]
    assigned = sum(c for _, c, _, _ in counts)
    order = sorted(range(len(counts)), key=lambda i: (-counts[i][2], counts[i][0]))
    i = 0
    while assigned < fill_total:
        idx = order[i % len(order)]
        archetype, c, frac, cap = counts[idx]
        counts[idx] = (archetype, c + 1, frac, cap)
        assigned += 1
        i += 1

    # Expand into a level-resolved pool, then deal it round-robin over blocks
    # so every block gets the same mix rather than the city being sorted by
    # archetype (which would make one corner all houses and ruin the LOD read).
    rng = Lcg(mix_seed(seed, 0xB0DE))
    pool: List[Tuple[str, int]] = []
    for archetype, count, _, cap in counts:
        for _ in range(count):
            level = min(cap, rng.pick(LEVEL_WEIGHTS) + 1)
            pool.append((archetype, level))
    # Interleave: stride through the pool with a step coprime to its length so
    # neighbours differ in archetype without any sort or shuffle.
    n = len(pool)
    stride = 7 if n % 7 else 11
    if n % stride == 0:
        stride = 13
    dealt: Dict[Tuple[int, int], List[Tuple[str, int]]] = {}
    core_blocks = [(bx, bz) for bz in range(CORE_SIZE_BLOCKS[1])
                   for bx in range(CORE_SIZE_BLOCKS[0])]
    for k in range(n):
        item = pool[(k * stride) % n]
        block = core_blocks[k % len(core_blocks)]
        dealt.setdefault(block, []).append(item)
    return dealt


# --------------------------------------------------------------------------
# 10. Power
# --------------------------------------------------------------------------

def transformer_tiles(bx: int, bz: int) -> List[Tuple[int, int]]:
    ox, oz = bx * BLOCK_TILES, bz * BLOCK_TILES
    return [(ox + lx, oz + lz) for lx, lz in TRANSFORMER_LOCAL]


def build_power(records: List[Dict[str, Any]], economy: Dict[str, List[Dict[str, Any]]],
                roads: Dict[Tuple[int, int], str],
                substation_sites: List[Dict[str, Any]],
                plant_sites: List[Dict[str, Any]]) -> Tuple[Dict[str, Any], Dict[str, float]]:
    nodes: List[Dict[str, Any]] = []
    lines: List[Dict[str, Any]] = []

    for site in plant_sites:
        nodes.append({"id": site["node"], "kind": "plant_gas", "level": PLANT_LEVEL,
                      "terminal": site["terminal"], "tags": []})
    for site in substation_sites:
        nodes.append({"id": site["node"], "kind": "substation", "level": SUBSTATION_LEVEL,
                      "terminal": site["terminal"], "feeder_slots": SUBSTATION_SLOTS,
                      "tags": []})

    # Transmission: each substation hangs off the nearer plant, along avenues.
    for i, site in enumerate(substation_sites):
        plant = plant_sites[i % len(plant_sites)]
        path = _manhattan_on_roads(plant["terminal"], site["terminal"], roads)
        lines.append({"id": "TL-%d" % (i + 1), "kind": "transmission",
                      "class": TRANSMISSION_CLASS, "from": plant["node"], "to": site["node"],
                      "overhead": True, "condition": 1.0, "path": path,
                      "length_tiles": gsc.polyline_length([tuple(p) for p in path])})

    # One class-3 feeder per developed block, four L4 transformers under it.
    # Streetlight and signal sinks are the ELECTRICAL counts (one lamp per road
    # tile, doc 04) -- deliberately not the ~22 art props per block doc 11
    # s2.10 draws, which doc 09 s2.13 warns must never be conflated.
    per_block_load = _block_night_load(records, economy)
    feeder_index = 0
    transformer_index = 0
    for bz in range(CORE_SIZE_BLOCKS[1]):
        for bx in range(CORE_SIZE_BLOCKS[0]):
            bid = block_id(bx, bz)
            site = substation_sites[feeder_index // SUBSTATION_SLOTS]
            feeder_id = "F_%d_%d" % (bx, bz)
            street_x = bx * BLOCK_TILES + STREET_LOCAL[0]
            street_z = bz * BLOCK_TILES + STREET_LOCAL[0]
            trunk = _manhattan_on_roads(site["terminal"], (street_x, street_z), roads)
            laterals = [
                [_local(street_x, bz * BLOCK_TILES), _local(street_x,
                                                            bz * BLOCK_TILES + BLOCK_TILES - 1)],
                [_local(bx * BLOCK_TILES, street_z), _local(bx * BLOCK_TILES + BLOCK_TILES - 1,
                                                            street_z)],
            ]
            lines.append({"id": feeder_id, "kind": "feeder", "class": FEEDER_CLASS,
                          "overhead": True, "from": site["node"], "condition": 1.0,
                          "path": trunk, "laterals": laterals,
                          "length_tiles": gsc.polyline_length([tuple(p) for p in trunk])
                          + sum(gsc.polyline_length([tuple(p) for p in lat]) for lat in laterals)})
            feeder_index += 1

            block_roads = [t for t in roads
                           if bx * BLOCK_TILES <= t[0] < (bx + 1) * BLOCK_TILES
                           and bz * BLOCK_TILES <= t[1] < (bz + 1) * BLOCK_TILES]
            signals = sum(1 for t in block_roads
                          if t[0] % BLOCK_TILES in ROAD_LOCAL and t[1] % BLOCK_TILES in ROAD_LOCAL)
            tiles = transformer_tiles(bx, bz)
            share = len(block_roads) // len(tiles)
            share_signals = signals // len(tiles)
            for k, tile in enumerate(tiles):
                transformer_index += 1
                lamps = share + (len(block_roads) - share * len(tiles) if k == 0 else 0)
                sigs = share_signals + (signals - share_signals * len(tiles) if k == 0 else 0)
                nodes.append({
                    "id": "T-%03d" % transformer_index,
                    "kind": "transformer",
                    "level": TRANSFORMER_LEVEL,
                    "tile": list(_local(tile[0], tile[1])),
                    "feeder": feeder_id,
                    "night_load_kw": round(per_block_load.get(bid, 0.0) / len(tiles), 1),
                    "streetlights": lamps,
                    "signals": sigs,
                    "tags": [],
                })

    totals = {
        "transformer_installed_kw": TRANSFORMER_CAPACITY_KW * transformer_index,
        "plant_capacity_kw": PLANT_CAPACITY_KW * len(plant_sites),
        "substation_capacity_kw": SUBSTATION_CAPACITY_KW * len(substation_sites),
        "feeder_count": feeder_index,
        "transformer_count": transformer_index,
    }
    power = {
        "nodes": nodes,
        "lines": lines,
        "tie_switches": [],
        "reserved_substation_parcel": None,
        "planned_tie_switch": None,
    }
    return power, totals


def _local(x: int, z: int) -> List[int]:
    return [x - CORE_TILE_OFFSET, z - CORE_TILE_OFFSET]


def _manhattan_on_roads(a: Tuple[int, int], b: Tuple[int, int],
                        roads: Dict[Tuple[int, int], str]) -> List[List[int]]:
    """Two-segment L route in core-local coords, both legs on road tiles.

    Substation and feeder terminals sit on road intersections, so the corner is
    on a road too; the assertion below is the one that proves it rather than
    the comment.
    """
    corner = (b[0], a[1])
    for tile in gsc.polyline_tiles([a, corner, b]):
        if tile not in roads:
            FAILURES.append("power route leaves the road grid at %r" % (tile,))
            break
    return [_local(*a), _local(*corner), _local(*b)]


def _block_night_load(records: List[Dict[str, Any]],
                      economy: Dict[str, List[Dict[str, Any]]]) -> Dict[str, float]:
    out: Dict[str, float] = {}
    for record in records:
        kw = float(economy[record["type"]][int(record["level"]) - 1].get("power_demand_kw", 0.0))
        out[record["block"]] = out.get(record["block"], 0.0) + kw
    return out


# --------------------------------------------------------------------------
# 11. Water
# --------------------------------------------------------------------------

def build_water(water_records: List[Dict[str, Any]], roads: Dict[Tuple[int, int], str],
                blocks: List[Dict[str, Any]]) -> Dict[str, Any]:
    nodes: List[Dict[str, Any]] = []
    laterals: List[Dict[str, Any]] = []
    hydrants: List[List[int]] = []

    for i, record in enumerate(water_records):
        base = record["id"]
        ox, oz = record["origin"]
        terminal = [ox, oz]
        nodes.append({"id": "%s-SRC" % base, "building": base, "variant": "source", "level": 2,
                      "terminal": terminal, "base_kw": 32.0, "subtype": "river",
                      "yield_m3h": 320.0, "tags": []})
        nodes.append({"id": "%s-TRT" % base, "building": base, "variant": "treatment", "level": 2,
                      "terminal": terminal, "base_kw": 40.0, "throughput_m3h": 260.0, "tags": []})
        nodes.append({"id": "%s-PMP" % base, "building": base, "variant": "pump", "level": 2,
                      "terminal": terminal, "base_kw": 60.0, "rated_flow_m3h": 150.0, "head_m": 40,
                      "pumps": [{"id": "%s-P1" % base, "state": "ok", "tags": []},
                                {"id": "%s-P2" % base, "state": "ok", "tags": []}],
                      "tags": []})
        nodes.append({"id": "%s-TNK" % base, "building": base, "variant": "tank", "level": 2,
                      "terminal": terminal, "base_kw": 0.0, "volume_m3": 4000.0, "tags": []})
        _ = i

    # Trunk mains along the core's two central avenues, laterals down every
    # block's street line -- the same trunk/lateral shape doc 09 s2.9.6 uses,
    # scaled from one core to thirty-six blocks.
    mid_x = (CORE_SIZE_BLOCKS[0] // 2) * BLOCK_TILES
    mid_z = (CORE_SIZE_BLOCKS[1] // 2) * BLOCK_TILES
    mains = [
        {"id": "M_SPINE_X", "path": [_local(mid_x, 0), _local(mid_x, CORE_TILES - 1)],
         "length_tiles": CORE_TILES - 1},
        {"id": "M_SPINE_Z", "path": [_local(0, mid_z), _local(CORE_TILES - 1, mid_z)],
         "length_tiles": CORE_TILES - 1},
    ]
    for main in mains:
        for tile in gsc.polyline_tiles([tuple(p) for p in main["path"]]):
            check((tile[0] + CORE_TILE_OFFSET, tile[1] + CORE_TILE_OFFSET) in roads,
                  "water main %s leaves the road grid" % main["id"])
            break

    for bz in range(CORE_SIZE_BLOCKS[1]):
        for bx in range(CORE_SIZE_BLOCKS[0]):
            street_x = bx * BLOCK_TILES + STREET_LOCAL[0]
            laterals.append({
                "block": block_id(bx, bz),
                "path": [_local(street_x, mid_z),
                         _local(street_x, bz * BLOCK_TILES + STREET_LOCAL[0])],
                "length_tiles": abs(bz * BLOCK_TILES + STREET_LOCAL[0] - mid_z),
            })
            hydrants.append(_local(street_x + 1, bz * BLOCK_TILES + STREET_LOCAL[0]))

    zones = []
    per_zone = CORE_SIZE_BLOCKS[1] // 2
    for zi in range(2):
        zone_blocks = [block_id(bx, bz)
                       for bz in range(zi * per_zone, (zi + 1) * per_zone)
                       for bx in range(CORE_SIZE_BLOCKS[0])]
        zones.append({"id": "Z%d" % (zi + 1), "blocks": zone_blocks})
    _ = blocks

    return {
        "nodes": nodes,
        "mains": mains,
        "laterals": laterals,
        "hydrants": hydrants,
        "pressure_zones": zones,
        "max_service_distance_tiles": MAX_SERVICE_DISTANCE_TILES,
        "power_dependency": {r["id"]: {"feeder": "F_%s" % r["block"][2:],
                                       "transformer": None,
                                       "backup_coverage_frac": 0.0}
                             for r in water_records},
    }


# --------------------------------------------------------------------------
# 12. Districts
# --------------------------------------------------------------------------

DISTRICT_NAMES = [
    "Northgate", "Foundry Flats", "Canal Ward", "Ridgeline", "Old Slacum", "Harbour Row",
    "Steelyard", "Lantern Hill", "Meridian", "Cinder Park", "Waterside", "Beacon Row",
    "Quarry End", "Tannery Lane", "Crown Heights", "Kiln Row", "Marsh Gate", "Tram Yard",
    "Copper Row", "Saltgate", "Ember Fields", "Verge", "Longwharf", "Ashcroft",
]


def build_districts(count: int) -> Tuple[List[Dict[str, Any]], Dict[str, str]]:
    core_blocks = [block_id(bx, bz)
                   for bz in range(CORE_SIZE_BLOCKS[1])
                   for bx in range(CORE_SIZE_BLOCKS[0])]
    check(count <= len(DISTRICT_NAMES), "not enough authored district names for %d" % count)
    check(CORE_BLOCKS % count == 0, "district count %d does not divide %d blocks"
          % (count, CORE_BLOCKS))
    per = CORE_BLOCKS // count
    districts: List[Dict[str, Any]] = []
    of_block: Dict[str, str] = {}
    for i in range(count):
        name = DISTRICT_NAMES[i]
        did = "D_%s" % name.upper().replace(" ", "_")
        members = core_blocks[i * per:(i + 1) * per]
        districts.append({"id": did, "name": name, "label": name[0],
                          "blocks": members, "color_index": i % 4})
        for bid in members:
            of_block[bid] = did
    return districts, of_block


# --------------------------------------------------------------------------
# 13. Assembly
# --------------------------------------------------------------------------

def build_bench_city(profile_name: str, seed: int, repo_root: str) -> Dict[str, Any]:
    profile = PROFILES[profile_name]
    manifest = load_manifest(repo_root)
    economy = load_economy(repo_root)
    if FAILURES:
        return {}

    roads = road_tile_set()
    check_eq(len(roads), DOC_BENCH_ROAD_TILES,
             "core road tiles (doc 09 s2.13: 36 blocks x 87)")

    # --- water tiles ------------------------------------------------------
    water_tiles: Dict[Tuple[int, int], bool] = {}
    lake_blocks: Dict[Tuple[int, int], int] = {}
    for bx, bz, parcel in LAKE_PARCELS:
        x0, z0, x1, z1 = parcel_rect(bx, bz, parcel)
        for z in range(z0, z1 + 1):
            for x in range(x0, x1 + 1):
                water_tiles[(x, z)] = True
        lake_blocks[(bx, bz)] = lake_blocks.get((bx, bz), 0) + (x1 - x0 + 1) * (z1 - z0 + 1)

    districts, districts_of_block = build_districts(int(profile["districts"]))
    blocks = build_blocks(lake_blocks, districts_of_block)
    check_eq(len(blocks), WORLD_BLOCKS * WORLD_BLOCKS, "block rows (StarterCityLoader requires 49)")

    # --- transformer tiles are reserved before anything is packed ---------
    reserved: Dict[Tuple[int, int], str] = {}
    for bz in range(CORE_SIZE_BLOCKS[1]):
        for bx in range(CORE_SIZE_BLOCKS[0]):
            for tile in transformer_tiles(bx, bz):
                reserved[tile] = "transformer"

    packer = Packer(manifest, reserved, water_tiles)

    # --- civic shells, then the substations and plants they power ---------
    civic_records: List[Dict[str, Any]] = []
    water_records: List[Dict[str, Any]] = []
    civic_plan: List[Tuple[str, str, int]] = []
    for prefix, archetype, level, count in CIVIC_ROSTER:
        for _ in range(count):
            civic_plan.append((prefix, archetype, level))
    # Spread them across the core on a coprime stride so no two land together.
    core_blocks = [(bx, bz) for bz in range(CORE_SIZE_BLOCKS[1])
                   for bx in range(CORE_SIZE_BLOCKS[0])]
    for i, (prefix, archetype, level) in enumerate(civic_plan):
        bx, bz = core_blocks[(i * 5 + 2) % len(core_blocks)]
        record = _place_on_ring(packer, bx, bz, archetype, level, prefix,
                                variant="pump" if archetype == "water_facility" else None)
        if record is None:
            FAILURES.append("civic %s L%d found no ring slot in block %d,%d"
                            % (archetype, level, bx, bz))
            continue
        civic_records.append(record)
        if archetype == "water_facility":
            water_records.append(record)

    substation_sites: List[Dict[str, Any]] = []
    plant_sites: List[Dict[str, Any]] = []
    sub_blocks = [core_blocks[(i * 7 + 3) % len(core_blocks)] for i in range(SUBSTATION_COUNT)]
    for i, (bx, bz) in enumerate(sub_blocks):
        record = _place_on_ring(packer, bx, bz, "substation", SUBSTATION_LEVEL, "SUB")
        if record is None:
            FAILURES.append("substation found no ring slot in block %d,%d" % (bx, bz))
            continue
        civic_records.append(record)
        terminal = (bx * BLOCK_TILES + STREET_LOCAL[0], bz * BLOCK_TILES + STREET_LOCAL[0])
        substation_sites.append({"node": "SUB-%s" % "ABCDEF"[i], "terminal": terminal,
                                 "building": record["id"]})
    plant_blocks = [core_blocks[(i * 13 + 8) % len(core_blocks)] for i in range(PLANT_COUNT)]
    for i, (bx, bz) in enumerate(plant_blocks):
        record = _place_on_ring(packer, bx, bz, "power_facility", 3, "PLANT")
        if record is None:
            FAILURES.append("plant found no ring slot in block %d,%d" % (bx, bz))
            continue
        civic_records.append(record)
        terminal = (bx * BLOCK_TILES + STREET_LOCAL[0], bz * BLOCK_TILES + STREET_LOCAL[0])
        plant_sites.append({"node": "PLANT-%d" % (i + 1), "terminal": terminal,
                            "building": record["id"]})

    # --- the fill ---------------------------------------------------------
    plan = plan_roster(profile, seed)
    for (bx, bz), sequence in sorted(plan.items()):
        cursor = 0
        for parcel in range(len(PARCELS)):
            rect = parcel_rect(bx, bz, parcel)
            if all(tile in water_tiles for tile in
                   ((rect[0], rect[1]), (rect[2], rect[3]))):
                continue
            for anchor_x, anchor_z, side in ring_slots(rect):
                if cursor >= len(sequence):
                    break
                archetype, level = sequence[cursor]
                size = packer.size_of(archetype, level)
                origin = footprint_origin((anchor_x, anchor_z), side, size)
                if not packer.fits(origin, size, rect):
                    continue
                packer.place(archetype, level, origin, size, block_id(bx, bz), _prefix(archetype))
                cursor += 1
            if cursor >= len(sequence):
                break
        if cursor < len(sequence):
            FAILURES.append("block %d,%d could seat only %d of %d buildings"
                            % (bx, bz, cursor, len(sequence)))

    records = sorted(packer.records, key=lambda r: (r["block"], r["origin"][1], r["origin"][0]))
    # Ids are re-issued in final order so the file reads top-left to
    # bottom-right and a diff between two runs is a diff of the CITY, not of a
    # placement order that happens to have moved.
    counters: Dict[str, int] = {}
    for record in records:
        prefix = record["id"].split("-")[0]
        counters[prefix] = counters.get(prefix, 0) + 1
        record["id"] = "%s-%04d" % (prefix, counters[prefix])
    for record in water_records:
        for candidate in records:
            if candidate["origin"] == record["origin"]:
                record["id"] = candidate["id"]
                break

    power, totals = build_power(records, economy, roads, substation_sites, plant_sites)
    water = build_water(water_records, roads, blocks)

    validate(records, blocks, roads, water_tiles, reserved, economy, totals, profile)

    return {
        "schema_version": 2,
        "world": {"size_blocks": [WORLD_BLOCKS, WORLD_BLOCKS], "tile_meters": TILE_METERS,
                  "block_tiles": BLOCK_TILES, "city_center_tile": list(CITY_CENTER_TILE),
                  "core_origin_block": list(CORE_ORIGIN_BLOCK),
                  "core_size_blocks": list(CORE_SIZE_BLOCKS)},
        "blocks": blocks,
        "roads": build_road_entries(),
        "water_tiles": [_local(x, z) for (x, z) in sorted(water_tiles)],
        "buildings": records,
        "power": power,
        "water": water,
        "districts": districts,
        "population": {"attractiveness": 1.00, "happiness": 78.0,
                       "building_age_hours_default": 240},
        "tags": {},
    }


def _prefix(archetype: str) -> str:
    return {"house": "H", "store": "S", "apartment": "A", "office": "O",
            "high_rise": "R", "data_center": "DC"}.get(archetype, archetype[:3].upper())


def _place_on_ring(packer: Packer, bx: int, bz: int, archetype: str, level: int,
                   prefix: str, variant: Optional[str] = None) -> Optional[Dict[str, Any]]:
    size = packer.size_of(archetype, level)
    for parcel in range(len(PARCELS)):
        rect = parcel_rect(bx, bz, parcel)
        for anchor_x, anchor_z, side in ring_slots(rect):
            origin = footprint_origin((anchor_x, anchor_z), side, size)
            if packer.fits(origin, size, rect):
                return packer.place(archetype, level, origin, size, block_id(bx, bz),
                                    prefix, variant)
    return None


# --------------------------------------------------------------------------
# 14. Invariants (doc 09 s7 tests 2-8, applied to the bench profile)
# --------------------------------------------------------------------------

def validate(records: List[Dict[str, Any]], blocks: List[Dict[str, Any]],
             roads: Dict[Tuple[int, int], str], water: Dict[Tuple[int, int], bool],
             reserved: Dict[Tuple[int, int], str],
             economy: Dict[str, List[Dict[str, Any]]], totals: Dict[str, float],
             profile: Dict[str, Any]) -> None:
    check_eq(len(records), int(profile["buildings"]), "building count")

    seen: Dict[Tuple[int, int], str] = {}
    frontage = 0
    for record in records:
        ox = record["origin"][0] + CORE_TILE_OFFSET
        oz = record["origin"][1] + CORE_TILE_OFFSET
        w, h = record["size"]
        touches_road = False
        for z in range(oz, oz + h):
            for x in range(ox, ox + w):
                check(0 <= x < WORLD_TILES and 0 <= z < WORLD_TILES,
                      "building %s leaves the world grid" % record["id"])
                check((x, z) not in roads, "building %s sits on a road" % record["id"])
                check((x, z) not in water, "building %s sits on water" % record["id"])
                check((x, z) not in reserved, "building %s sits on a transformer"
                      % record["id"])
                prev = seen.get((x, z))
                check(prev is None, "buildings %s and %s overlap at %d,%d"
                      % (prev, record["id"], x, z))
                seen[(x, z)] = record["id"]
        for z in range(oz - 1, oz + h + 1):
            for x in range(ox - 1, ox + w + 1):
                if (x, z) in roads:
                    touches_road = True
        if touches_road:
            frontage += 1
    check_eq(frontage, len(records), "every building has road frontage")

    ready = [b for b in blocks if b["development_state"] == "READY"]
    check_eq(len(ready), CORE_BLOCKS, "developed blocks")

    # Every building is inside some transformer's Chebyshev service radius --
    # the assertion `CitySim._boot_power` turns into a boot error if it fails.
    covered = 0
    for record in records:
        ox = record["origin"][0] + CORE_TILE_OFFSET
        oz = record["origin"][1] + CORE_TILE_OFFSET
        bx, bz = ox // BLOCK_TILES, oz // BLOCK_TILES
        for tx, tz in transformer_tiles(bx, bz):
            if max(abs(ox - tx), abs(oz - tz)) <= TRANSFORMER_RADIUS:
                covered += 1
                break
    check_eq(covered, len(records), "buildings inside a transformer service radius")

    peak = sum(float(economy[r["type"]][int(r["level"]) - 1].get("power_demand_kw", 0.0))
               for r in records)
    lamp_kw = len(roads) * STREETLIGHT_KW
    signal_kw = sum(1 for t in roads
                    if t[0] % BLOCK_TILES in ROAD_LOCAL
                    and t[1] % BLOCK_TILES in ROAD_LOCAL) * SIGNAL_KW
    total_kw = peak + lamp_kw + signal_kw
    check(total_kw <= TRANSFORMER_HEADROOM_FRAC * totals["transformer_installed_kw"],
          "night peak %.0f kW exceeds %.0f%% of %.0f kW of transformer capacity"
          % (total_kw, TRANSFORMER_HEADROOM_FRAC * 100, totals["transformer_installed_kw"]))
    check(total_kw <= PLANT_HEADROOM_FRAC * totals["plant_capacity_kw"],
          "night peak %.0f kW exceeds %.0f%% of %.0f kW of plant capacity"
          % (total_kw, PLANT_HEADROOM_FRAC * 100, totals["plant_capacity_kw"]))
    check(totals["feeder_count"] <= SUBSTATION_COUNT * SUBSTATION_SLOTS,
          "feeders (%d) exceed the substations' %d slots"
          % (totals["feeder_count"], SUBSTATION_COUNT * SUBSTATION_SLOTS))
    totals["night_peak_kw"] = total_kw
    totals["building_kw"] = peak
    totals["lamp_kw"] = lamp_kw
    totals["signal_kw"] = signal_kw
    totals["population"] = sum(
        int(economy[r["type"]][int(r["level"]) - 1].get("population", 0)) for r in records)
    totals["jobs"] = sum(
        int(economy[r["type"]][int(r["level"]) - 1].get("jobs", 0)) for r in records)
    STATS.update(totals)


# --------------------------------------------------------------------------
# 15. Main
# --------------------------------------------------------------------------

def _print_stats(city: Dict[str, Any], profile_name: str) -> None:
    """The measured contents, printed so the doc-11 table is transcribed from a
    run and never from an intention."""
    import collections
    archetypes = collections.Counter(b["type"] for b in city["buildings"])
    levels = collections.Counter(int(b["level"]) for b in city["buildings"])
    print("gen_bench_city: profile %s" % profile_name)
    print("  buildings      %d   %s" % (len(city["buildings"]),
                                        dict(sorted(archetypes.items()))))
    print("  level mix      %s" % {("L%d" % k): v for k, v in sorted(levels.items())})
    print("  population     %d   jobs %d" % (STATS.get("population", 0), STATS.get("jobs", 0)))
    print("  night peak     %.0f kW  (buildings %.0f + lamps %.0f + signals %.0f)"
          % (STATS.get("night_peak_kw", 0.0), STATS.get("building_kw", 0.0),
             STATS.get("lamp_kw", 0.0), STATS.get("signal_kw", 0.0)))
    print("  installed      transformers %.0f kW  substations %.0f kW  plants %.0f kW"
          % (STATS.get("transformer_installed_kw", 0.0),
             STATS.get("substation_capacity_kw", 0.0), STATS.get("plant_capacity_kw", 0.0)))
    print("  road tiles     %d   water tiles %d   districts %d"
          % (DOC_BENCH_ROAD_TILES, len(city["water_tiles"]), len(city["districts"])))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", default="bench", choices=sorted(PROFILES))
    parser.add_argument("--out", default=None)
    parser.add_argument("--check", action="store_true", help="validate only, write nothing")
    parser.add_argument("--seed", type=int, default=20260819)
    args = parser.parse_args()

    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_path = args.out or os.path.join(repo_root, "tests", "fixtures", "bench_city.json")

    city = build_bench_city(args.profile, args.seed, repo_root)

    if FAILURES:
        print("gen_bench_city: %d invariant(s) FAILED -- nothing written" % len(FAILURES),
              file=sys.stderr)
        for failure in FAILURES:
            print("  FAIL %s" % failure, file=sys.stderr)
        return 1

    _print_stats(city, args.profile)
    if args.check:
        print("gen_bench_city: all invariants pass (--check, nothing written)")
        return 0

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    gsc.write_json(out_path, city)
    if gsc.FAILURES:
        for failure in gsc.FAILURES:
            print("  FAIL %s" % failure, file=sys.stderr)
        return 1

    lights = sum(int(n.get("streetlights", 0)) for n in city["power"]["nodes"])
    print("gen_bench_city: wrote %s" % out_path)
    print("  profile %s - %d blocks (%d developed) - %d buildings - %d road tiles"
          % (args.profile, len(city["blocks"]), CORE_BLOCKS, len(city["buildings"]),
             DOC_BENCH_ROAD_TILES))
    print("  %d transformers - %d feeders - %d substations - %d plants - %d lamp sinks"
          % (sum(1 for n in city["power"]["nodes"] if n["kind"] == "transformer"),
             sum(1 for l in city["power"]["lines"] if l["kind"] == "feeder"),
             sum(1 for n in city["power"]["nodes"] if n["kind"] == "substation"),
             sum(1 for n in city["power"]["nodes"] if n["kind"] == "plant_gas"),
             lights))
    return 0


if __name__ == "__main__":
    sys.exit(main())
