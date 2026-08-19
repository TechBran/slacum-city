class_name WaterBoot
extends RefCounted
## Builds a live `WaterSystem` from doc 09's authored starter city
## (`data/starter_city.json` §2.9.6) and keeps the coordinate conversion in one
## place: the file is core-local, the sim is global (`+ CORE_TILE_OFFSET`).
##
## `WTR-1` is ONE building hosting three co-located nodes — the intake, the
## package treatment skid and the pump house — so all three share a
## `power_ref`, and losing `F_SOUTH` stops the whole site at once. That is the
## cascade doc 09 §2.9.6 designed the starter city around.
##
## Doc 09's mains carry no `tier` column, so `service` (53.5 m³/h) is assumed
## unless the record names one — see the report's open questions.

const DEFAULT_TIER := "service"


static func build(water_data: WaterData, loader: StarterCityLoader,
		terrain: Object = null) -> WaterSystem:
	var system := WaterSystem.new(water_data, TileGrid.SIZE)
	system.terrain = terrain if terrain != null else (loader.world.grid if loader.world else null)
	var water: Dictionary = loader.water
	for record in water.get("nodes", []):
		var node_id := String(record.get("id", ""))
		var variant := StringName(String(record.get("variant", "junction")))
		var terminal: Array = record.get("terminal", [0, 0])
		var opts: Dictionary = {
			"level": int(record.get("level", 1)),
			"subtype": String(record.get("subtype", "river" if variant == &"source" else "")),
			"power_ref": String(record.get("building", node_id)),
			"condition": float(record.get("condition", 1.0)),
			"backup_installed": float(_backup_coverage(water, String(record.get("building", "")))) > 0.0,
		}
		if record.has("volume_m3"):
			opts["volume_m3"] = float(record["volume_m3"])
		system.add_node(node_id, variant,
				StarterCityLoader.core_to_global(int(terminal[0]), int(terminal[1])), opts)
	for record in water.get("mains", []):
		system.add_main(String(record.get("id", "")), _global_path(record.get("path", [])),
				{"tier": String(record.get("tier", DEFAULT_TIER)),
				"insulation": int(record.get("insulation", 0))})
	var lateral_index := 1
	for record in water.get("laterals", []):
		var lateral_id := String(record.get("id", "LAT_%s" % record.get("block", lateral_index)))
		system.add_main(lateral_id, _global_path(record.get("path", [])),
				{"tier": String(record.get("tier", DEFAULT_TIER))})
		lateral_index += 1
	system.rebuild_zones()
	return system


## Attach every starter building to the demand cache. Doc 02 owns the
## magnitude; this only publishes the archetype and the access tile.
static func attach_buildings(system: WaterSystem, loader: StarterCityLoader) -> void:
	for record in loader.buildings:
		system.attach_building(String(record["id"]), record["origin_global"],
				String(record["type"]))


## Doc 02's `W_b` per building for the current level and state (§2.4): the
## magnitude, the state derate and doc 07's pre-applied weather multiplier.
static func compose_demands(catalog: BuildingCatalog, buildings: Dictionary,
		weather_water_mult: float = 1.0) -> Dictionary:
	var out: Dictionary = {}
	var ids := buildings.keys()
	ids.sort()
	for id in ids:
		var b: Building = buildings[id]
		var stats: Dictionary = catalog.stats(String(b.archetype), maxi(b.level, 1))
		out[String(id)] = float(stats.get("water_demand", 0.0)) \
				* b.water_demand_mult() * weather_water_mult
	return out


static func _global_path(path: Array) -> Array:
	var out: Array = []
	for pair in path:
		out.append(StarterCityLoader.core_to_global(int(pair[0]), int(pair[1])))
	return out


static func _backup_coverage(water: Dictionary, building_id: String) -> float:
	return float(water.get("power_dependency", {}).get(building_id, {})
			.get("backup_coverage_frac", 0.0))
