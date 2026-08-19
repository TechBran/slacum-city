class_name WaterNode
extends RefCounted
## One node of the water graph (doc 05 §2.1). Five `water_facility` variants
## plus the implicit, building-less `junction` created by `place_main`.
##
## Doc 02 owns the archetype shell; every per-variant NUMBER (capacity, head,
## `base_kw`, `coverage_frac`, footprint) is doc 05's and is read from
## `data/water.json` through `WaterData`, never stored here.

const VARIANTS := [&"source", &"treatment", &"pump", &"tank", &"booster", &"junction"]
const SUPPLY_VARIANTS := [&"pump", &"tank"]

var id: String = ""
var variant: StringName = &"junction"
var subtype: String = ""  # source: "river" | "well"
var tile := Vector2i.ZERO
var level: int = 1
var condition: float = 1.0
var state: StringName = &"ok"  # ok | degraded | failed | offline_manual
var built_at_minutes: float = 0.0
## The doc-04 sink this node's power is read through (§2.6). Water facilities
## co-locate several nodes on one building, so this is the HOST building id.
var power_ref: String = ""
var backup_installed: bool = false
var restart_timer_min: float = 0.0
var volume_m3: float = 0.0  # tanks only
var insulation: int = 0  # exposed-pump freeze protection (§2.9)
var flow_m3h: float = 0.0  # last tick, for the overlay
var share_m3h: float = 0.0  # upstream allocation (§2.5), rebuilt on topology change


static func make(node_id: String, node_variant: StringName, at_tile: Vector2i,
		opts: Dictionary = {}) -> WaterNode:
	var node := WaterNode.new()
	node.id = node_id
	node.variant = node_variant
	node.tile = at_tile
	node.subtype = String(opts.get("subtype", "river" if node_variant == &"source" else ""))
	node.level = int(opts.get("level", 1))
	node.condition = float(opts.get("condition", 1.0))
	node.state = StringName(String(opts.get("state", "ok")))
	node.built_at_minutes = float(opts.get("built_at_minutes", 0.0))
	node.power_ref = String(opts.get("power_ref", node_id))
	node.backup_installed = bool(opts.get("backup_installed", false))
	node.insulation = int(opts.get("insulation", 0))
	return node


func is_supply() -> bool:
	return variant == &"pump" or variant == &"tank"


func is_powered_kind() -> bool:
	return variant != &"junction"


func is_live() -> bool:
	return state == &"ok" or state == &"degraded"


## §2.5: a failed node contributes nothing; otherwise condition derates it.
func cond_factor() -> float:
	if not is_live():
		return 0.0
	return 0.5 + 0.5 * condition


func component_key() -> String:
	return WaterData.component_key(variant, subtype)


func serialize() -> Dictionary:
	return {
		"id": id, "variant": String(variant), "subtype": subtype,
		"level": level, "tile": [tile.x, tile.y], "condition": condition,
		"state": String(state), "built_at_minutes": built_at_minutes,
		"power_ref": power_ref, "restart_timer_min": restart_timer_min,
		"backup_installed": backup_installed, "volume_m3": volume_m3,
		"insulation": insulation,
	}


static func deserialize(record: Dictionary) -> WaterNode:
	var node := WaterNode.new()
	node.id = String(record.get("id", ""))
	node.variant = StringName(String(record.get("variant", "junction")))
	node.subtype = String(record.get("subtype", ""))
	node.level = int(record.get("level", 1))
	var tile_pair: Array = record.get("tile", [0, 0])
	node.tile = Vector2i(int(tile_pair[0]), int(tile_pair[1]))
	node.condition = float(record.get("condition", 1.0))
	node.state = StringName(String(record.get("state", "ok")))
	node.built_at_minutes = float(record.get("built_at_minutes", 0.0))
	node.power_ref = String(record.get("power_ref", node.id))
	node.restart_timer_min = float(record.get("restart_timer_min", 0.0))
	node.backup_installed = bool(record.get("backup_installed", false))
	node.volume_m3 = float(record.get("volume_m3", 0.0))
	node.insulation = int(record.get("insulation", 0))
	return node
