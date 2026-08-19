class_name CoverageIndex
extends RefCounted
## Doc 02 §2.9's service-coverage field, evaluated for any tile.
##
## **Ownership note.** Report 98 C-51 gives the FORMULA to doc 02 and names
## `sim/buildings/coverage.gd` as its home; doc 06 only consumes the scalar. This
## class is that formula, verbatim, with every constant read from
## `data/building_rules.json.coverage_ladder` — it is deliberately **pure**
## (station rows in, scalars out; it knows nothing about `Building`, `CitySim` or
## the fleet) so that moving it to `sim/buildings/coverage.gd` is a file move and
## nothing else. It lives here for now because the adapter that can assemble its
## inputs — station shell from doc 02, staffing from doc 06's roster — is
## `CityIncidentWorld`, and doc 06 is the only consumer today.
##
## ```
## c_station(pos, s) = clamp(1 − (dist/radius)^FALLOFF, 0, 1)
##                   * staffing(s) * station_condition_factor(s) * state_mult(s)
## coverage(pos)     = min(1, max_s c_station + BONUS * count{c ≥ MIN} − BONUS)
## ```
##
## `dist` is Euclidean between footprint CENTROIDS in tiles (doc 02 §2.9), which
## is why a row carries a centroid rather than an origin: a 3×3 yard's reach is
## measured from its middle, not from its north-west corner.
##
## The redundancy term is `+0.15 per EXTRA overlapping station`: one station in
## range nets zero, two net +0.15, and the sum is capped at 1.0 (Pillar 2 —
## redundancy is rewarded, perfection is not required).

const KIND_POLICE := &"police"
const KIND_FIRE := &"fire"
const KINDS: Array[StringName] = [KIND_POLICE, KIND_FIRE]

## Which archetype feeds which coverage field. `construction_yard` also carries a
## `coverage_radius_tiles` (doc 02 §2.4) but it answers `E_NO_CREW`, not police
## or fire, so it is deliberately absent.
const ARCHETYPE_KIND := {
	"police_station": KIND_POLICE,
	"fire_station": KIND_FIRE,
}

# data/building_rules.json.coverage_ladder — never authored here (constitution:
# no magic numbers in code). The fallbacks are doc 02 §2.9's published values and
# exist only so a fixture-built index behaves before `configure()`.
var falloff_exponent: float = 1.5
var redundancy_bonus: float = 0.15
var redundancy_min: float = 0.30
var condition_floor: float = 0.50
var condition_span: float = 0.50
var condition_low_anchor: float = 0.20
var condition_range: float = 0.80

var _by_kind: Dictionary = {}  # StringName -> Array[Dictionary] (sorted by id)


func _init(ladder: Dictionary = {}) -> void:
	_by_kind = {KIND_POLICE: [] as Array, KIND_FIRE: [] as Array}
	if not ladder.is_empty():
		configure(ladder)


## `data/building_rules.json.coverage_ladder`, whole.
func configure(ladder: Dictionary) -> void:
	falloff_exponent = float(ladder.get("falloff_exponent", falloff_exponent))
	redundancy_bonus = float(ladder.get("redundancy_bonus_per_extra_station",
			redundancy_bonus))
	redundancy_min = float(ladder.get("redundancy_min_contribution", redundancy_min))
	condition_floor = float(ladder.get("station_condition_floor", condition_floor))
	condition_span = float(ladder.get("station_condition_span", condition_span))
	condition_low_anchor = float(ladder.get("station_condition_low_anchor",
			condition_low_anchor))
	condition_range = float(ladder.get("station_condition_range", condition_range))


## The station roster this field is built from. One row per station:
##
##     {id: String, kind: &"police"|&"fire", centroid: Vector2, level: int,
##      radius_tiles: float, staffing: float, condition: float, state_mult: float}
##
## Rows are stored sorted by id inside each kind, so every read walks them in the
## same order whatever order the caller assembled them in (constitution:
## sorted iteration).
func set_stations(rows: Array) -> void:
	var buckets: Dictionary = {KIND_POLICE: [] as Array, KIND_FIRE: [] as Array}
	for raw: Variant in rows:
		if not (raw is Dictionary):
			continue
		var row: Dictionary = raw
		var kind := StringName(str(row.get("kind", "")))
		if not buckets.has(kind):
			continue
		(buckets[kind] as Array).append(_normalise(row, kind))
	for kind: StringName in KINDS:
		var bucket: Array = buckets[kind]
		bucket.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a["id"]) < String(b["id"]))
		buckets[kind] = bucket
	_by_kind = buckets


static func _normalise(row: Dictionary, kind: StringName) -> Dictionary:
	var centroid: Variant = row.get("centroid", Vector2.ZERO)
	return {
		"id": str(row.get("id", "")),
		"kind": kind,
		"centroid": centroid if centroid is Vector2 else Vector2(centroid),
		"level": maxi(1, int(row.get("level", 1))),
		"radius_tiles": maxf(0.0, float(row.get("radius_tiles", 0.0))),
		"staffing": clampf(float(row.get("staffing", 0.0)), 0.0, 1.0),
		"condition": clampf(float(row.get("condition", 1.0)), 0.0, 1.0),
		"state_mult": clampf(float(row.get("state_mult", 1.0)), 0.0, 1.0),
	}


func stations(kind: StringName) -> Array:
	var bucket: Variant = _by_kind.get(kind, [])
	return (bucket as Array).duplicate() if bucket is Array else []


func station_count(kind: StringName) -> int:
	var bucket: Variant = _by_kind.get(kind, [])
	return (bucket as Array).size() if bucket is Array else 0


func is_empty() -> bool:
	return station_count(KIND_POLICE) == 0 and station_count(KIND_FIRE) == 0


# ---------------------------------------------------------------------------
# The formula
# ---------------------------------------------------------------------------

## Doc 02 §2.9's `station_condition_factor`: 0.50 at or below the low anchor,
## rising linearly to 1.00 at full condition. A neglected station is HALF a
## station long before it is a broken one.
func station_condition_factor(condition: float) -> float:
	return condition_floor + condition_span * clampf(
			(condition - condition_low_anchor) / maxf(condition_range, 0.000001),
			0.0, 1.0)


## One station's contribution at `pos`, in tiles.
func station_contribution(row: Dictionary, pos: Vector2) -> float:
	var radius := float(row["radius_tiles"])
	if radius <= 0.0:
		return 0.0
	var distance := (pos - (row["centroid"] as Vector2)).length()
	var falloff := clampf(1.0 - pow(distance / radius, falloff_exponent), 0.0, 1.0)
	if falloff <= 0.0:
		return 0.0
	return falloff * float(row["staffing"]) \
			* station_condition_factor(float(row["condition"])) \
			* float(row["state_mult"])


## `coverage_police(pos)` / `coverage_fire(pos)` — both ∈ [0,1].
func coverage(kind: StringName, pos: Vector2) -> float:
	return float(explain(kind, pos)["coverage"])


func coverage_at_tile(kind: StringName, tile: Vector2i) -> float:
	return coverage(kind, Vector2(float(tile.x), float(tile.y)))


## The same answer with its reasons attached, for the §2.7 "Fed by …" line and
## for the overlay's tap readout: `{coverage, best_id, best, overlapping,
## redundancy}`. `overlapping` counts every station at or above
## `redundancy_min_contribution`, INCLUDING the best one — the doc's own
## `count{…} − BONUS` is what turns that into "extra".
func explain(kind: StringName, pos: Vector2) -> Dictionary:
	var bucket: Variant = _by_kind.get(kind, [])
	var rows: Array = bucket if bucket is Array else []
	var best := 0.0
	var best_id := ""
	var overlapping := 0
	for raw: Variant in rows:
		var row: Dictionary = raw
		var c := station_contribution(row, pos)
		if c >= redundancy_min:
			overlapping += 1
		if c > best:
			best = c
			best_id = str(row["id"])
	var redundancy := redundancy_bonus * float(overlapping) - redundancy_bonus
	if overlapping <= 0:
		redundancy = 0.0
	return {
		"coverage": clampf(best + redundancy, 0.0, 1.0),
		"best": best,
		"best_id": best_id,
		"overlapping": overlapping,
		"redundancy": maxf(0.0, redundancy),
	}
