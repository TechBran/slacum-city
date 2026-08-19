class_name GridStrikeAdapter
extends RefCounted
## The seam between this doc's strike generation and doc 04's damage
## resolution (report 98 C-54). It does two things and nothing else:
##
##   1. `roster()` — turns a `PowerGrid` into §2.7.3 target descriptors.
##   2. `resolve()` — hands a `LightningStrike` to `PowerGrid.resolve_lightning()`,
##      which owns the ds0–ds3 bands, and then enforces F10's `condition_floor`.
##
## There is NO damage band table in this file. The bands, the failure types and
## `p_damage = 0.55 · (1 − 0.22·arrester_level) · clamp(energy, 0.6, 1.6)` all
## live in doc 04 (`sim/power/power_grid.gd`), which is where a reader looking
## for a strike outcome must go.
##
## Seam note: F10 reaches doc 04 as `condition_floor` on the payload, and doc 04
## is meant to clamp on it. `PowerGrid.resolve_lightning()` does not take that
## argument yet, so the clamp is applied here immediately after resolution.
## When doc 04 grows the parameter, delete `apply_condition_floor()` — it is a
## bridge, not a second owner.

## Doc 04 kind → (§2.7.3 weight class, typical height_m). The lightning table
## has no `plant` row; a gas plant is sited and massed like a factory, so it
## borrows that row until doc 07's table grows one (flagged as an open question).
const KIND_MAP := {
	&"transmission": ["transmission_line", 30.0],
	&"substation": ["substation", 20.0],
	&"transformer": ["distribution_transformer", 10.0],
	&"feeder": ["distribution_line", 12.0],
	&"plant_gas": ["factory", 22.0],
}
## F10 (§2.6.4): the last of these is irreplaceable and may never be destroyed
## nor pushed below `condition = 0.10`.
const IRREPLACEABLE_KINDS: Array[StringName] = [&"plant_gas", &"substation"]


## Deterministic roster, sorted by component id. `grid_inventory()` is doc 04's
## published contract (C-12), so this never reaches into the grid's internals.
static func roster(grid: PowerGrid) -> Array:
	var ids: Array[String] = []
	var inventory := grid.grid_inventory()
	for group in ["nodes", "lines", "plants"]:
		for entry in inventory[group]:
			ids.append(String(entry["id"]))
	ids.sort()
	var kind_counts := {}
	for id in ids:
		var kind: StringName = grid.component(id)["kind"]
		kind_counts[kind] = int(kind_counts.get(kind, 0)) + 1
	var out: Array = []
	for id in ids:
		var component := grid.component(id)
		var kind: StringName = component["kind"]
		if not KIND_MAP.has(kind):
			continue
		var mapping: Array = KIND_MAP[kind]
		var protections: Array = []
		if int(component.get("arrester_level", 0)) > 0:
			protections.append("arrester")
		if bool(component.get("has_ground_grid", false)):
			protections.append("ground_grid")
		if bool(component.get("has_surge_protection", false)):
			protections.append("surge_protection")
		var last_of_kind: bool = IRREPLACEABLE_KINDS.has(kind) and int(kind_counts[kind]) <= 1
		out.append({
			"ref": id,
			"domain": "grid",
			"weight_class": String(mapping[0]),
			"height_m": float(mapping[1]),
			"condition": float(component.get("condition", 1.0)),
			"exposure": "underground" if bool(component.get("underground", false)) else "outdoor",
			"protections": protections,
			"pos": position_of(component),
			"f10_protected": last_of_kind,
		})
	return out


static func position_of(component: Dictionary) -> Vector2:
	var route: Array = component.get("route", [])
	if not route.is_empty():
		var mid: Variant = route[route.size() / 2]
		if mid is Vector2i:
			return Vector2(mid.x, mid.y)
		if mid is Array and (mid as Array).size() >= 2:
			return Vector2(float(mid[0]), float(mid[1]))
	var tile: Variant = component.get("tile", Vector2i.ZERO)
	if tile is Vector2i:
		return Vector2(tile.x, tile.y)
	return Vector2.ZERO


## Hand the strike to doc 04 and enforce F10. Returns doc 04's own result
## dictionary, annotated with `ref` and `f10_clamped`.
static func resolve(grid: PowerGrid, strike: Dictionary, rng: RngStreams) -> Dictionary:
	var id := String(strike["target_ref"])
	if grid.component(id).is_empty():
		return {"ref": id, "band": "none", "damage_fraction": 0.0, "f10_clamped": false}
	var result := grid.resolve_lightning(id, float(strike["energy"]), rng)
	var floor_value := float(strike.get("condition_floor", 0.0))
	var clamped := apply_condition_floor(grid, id, floor_value)
	result["ref"] = id
	result["f10_clamped"] = clamped
	result["event_uid"] = int(strike.get("event_uid", -1))
	return result


## F10: an irreplaceable asset is still STRUCK — the drama survives — but it is
## clamped at `condition_floor` and stays repairable.
static func apply_condition_floor(grid: PowerGrid, id: String, floor_value: float) -> bool:
	if floor_value <= 0.0:
		return false
	var component := grid.component(id)
	if component.is_empty():
		return false
	var clamped := false
	if float(component["condition"]) < floor_value:
		component["condition"] = floor_value
		clamped = true
	if String(component.get("failed_cause", "")) == "LIGHTNING_DESTROYED":
		component["failed_cause"] = "LIGHTNING"
		clamped = true
	return clamped
