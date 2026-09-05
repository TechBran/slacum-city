class_name WaterActions
extends RefCounted
## Doc 05 §6's last three verbs, given doors (doc 93 §J1, doc 92 §28).
##
## `cmd_upgrade_water_component`, `cmd_isolate_water_main` and
## `cmd_restore_water_main` shipped in Wave 5 and reached nothing: doc 05 §6.1
## and doc 93 §G recorded them as "wanting a water-NODE panel doc 12's screen map
## does not have", and doc 91 §14.5 D-4 carried the row. **There is no such
## panel**, and the ruling in doc 93 §J1 is that there should not be one — the
## two verbs belong to two different moments and a screen that hosted both would
## be a screen the player has to go and find:
##
##   * **Upgrade is a purchase against a standing asset**, exactly like doc 02's
##     building upgrade, and a water site already has a panel — the doc-02 SHELL
##     it is hosted on (`water_facility`). `cmd_place_water_component` builds a
##     shell and a node together and `WTR-1` hosts three nodes at once, so the
##     block below is a LIST: one upgrade row per node whose `power_ref` is that
##     shell, each priced by the verb's own `preview = true`.
##   * **Isolate/restore is a tactical trade under a live incident** (§2.12:
##     "trade a neighbourhood's taps for the fire's hydrants"). It targets a
##     MAIN, and a main is a thing the player only ever meets as the target of a
##     `water_main_break` — so it belongs on the incident drawer's expanded row,
##     beside `ASSIGN`, and nowhere else.
##
## This class is the headless half of both (constitution §3 / doc 12 §1: pure
## `RefCounted`, every value read from the sim's own preview, no threshold and no
## copy authored here). `ui/building_panel.gd` binds the node block through
## `BuildController.building_view()`; `ui/incident_drawer.gd` binds the segment
## view directly.

## Doc 02's shell every doc-05 variant is drawn as — the archetype whose
## `ui_build_card_water_facility_<variant>` keys name a node without inventing a
## second table (the same constant `BuildController` uses, spelled here so the
## dependency runs one way).
const WATER_SHELL_ARCHETYPE := "water_facility"

## Doc 06's `target_ref.kind` for a main. `Incident.target_ref` names it and
## `sim/incidents/city_incident_world.gd` is the only writer.
const TARGET_WATER_SEGMENT := "water_segment"

## The gate `cmd_upgrade_water_component` runs, in its order. `E_UNKNOWN_NODE`
## and `E_NOT_UPGRADEABLE` are NOT here: they are not rows in a checklist, they
## are the reason there is no checklist (a junction has no ladder), and the block
## simply does not draw for a node that raises them.
const UPGRADE_CHECKS: Array[StringName] = [
	&"E_MAX_LEVEL", &"E_LEVEL_UNAVAILABLE", &"E_POWER_HEADROOM", &"E_FUNDS",
]

## Doc 05 §6's own headroom margin, quoted so the checklist's `{need}` is the kW
## the command actually asked doc 04 for rather than the raw delta. ×1.15, the
## same margin doc 02 §2.11's upgrade check uses.
const HEADROOM_MARGIN := 1.15

## Doc 05's ladder cap, and the flag that lifts it. Mirrors
## `CitySim.cmd_upgrade_water_component`'s own `next_level > 5 or (>= 4 and not
## levels_4_5_enabled)` — the panel draws the pips the command will honour.
const MAX_LEVEL := 5
const MAX_LEVEL_GATED := 3
const FLAG_LEVELS_4_5 := "levels_4_5_enabled"

var sim: CitySim
var formatter: RequirementFormatter


func _init(p_sim: CitySim = null, p_formatter: RequirementFormatter = null) -> void:
	sim = p_sim
	formatter = p_formatter if p_formatter != null else RequirementFormatter.load_from_files()


# ===========================================================================
# The node block — doc 05 §6's `cmd_upgrade_water_component`, on S5
# ===========================================================================

## Every doc-05 node hosted on this doc-02 shell, sorted. `power_ref` is the
## join: `cmd_place_water_component` sets it to the shell's sim id and
## `data/starter_city.json` does the same for the authored sites, which is why
## `WTR-1` answers with its source, its treatment train and its pump.
func nodes_of(sim_id: String) -> Array[String]:
	var out: Array[String] = []
	if sim == null or sim_id == "":
		return out
	for key: Variant in sim.water.nodes:
		var node: WaterNode = sim.water.nodes[key]
		if node.power_ref == sim_id:
			out.append(String(key))
	out.sort()
	return out


## The building panel's water block: `{available, nodes: [node_view…]}`.
## `available` is false for every building that hosts no node, which is every
## building in the city except a `water_facility` — so the block is drawn only
## where it means something, exactly as the repair row is.
func building_block(sim_id: String) -> Dictionary:
	var rows: Array[Dictionary] = []
	for node_id: String in nodes_of(sim_id):
		var view := node_view(node_id)
		if not view.is_empty():
			rows.append(view)
	return {"available": not rows.is_empty(), "nodes": rows}


## One node's row. Everything quoted comes from doc 05's own tables through the
## sim, and every verdict from `cmd_upgrade_water_component(preview = true)`.
func node_view(node_id: String) -> Dictionary:
	if sim == null:
		return {}
	var node: WaterNode = sim.water.nodes.get(node_id)
	if node == null:
		return {}
	var variant := String(node.variant)
	var top := max_level_of(variant)
	var preview := sim.cmd_upgrade_water_component(node_id, true)
	var payload: Dictionary = preview.get("payload", {})
	var code := StringName(str(preview.get("reason_code", &"")))
	var blockers: Array = payload.get("blockers", [])
	# A junction has no ladder at all (doc 05 §2.1: it is a tile where mains
	# meet, not a component). It still gets a row — the player tapped a site that
	# hosts it — but the row says so instead of showing a dead button.
	var upgradeable := code != &"E_NOT_UPGRADEABLE" and node.variant != &"junction"
	var next_level: int = int(payload.get("to_level", node.level + 1))
	var cost := int(payload.get("cost", 0))
	var delta_kw := float(payload.get("delta_kw", 0.0))
	var rows: Array[Dictionary] = []
	var blocked_by: Dictionary = {}
	if upgradeable and node.level < top:
		rows = formatter.checklist(UPGRADE_CHECKS, blockers,
				{"cost": cost, "balance": sim.treasury.balance},
				_check_params(node, next_level, top, payload))
		blocked_by = RequirementFormatter.first_blocker(rows)
	return {
		"node": node_id,
		"variant": variant,
		"subtype": node.subtype,
		"name_key": BuildController.card_name_key(WATER_SHELL_ARCHETYPE, variant),
		"name_fallback": variant.capitalize(),
		"level": node.level,
		"max_level": top,
		"state": String(node.state),
		# Doc 05 `WaterNode.state`: `ok | degraded | failed | offline_manual`.
		# One key per rung, spliced — a state doc 05 grows later renders as the
		# raw token rather than as a wrong word.
		"state_key": "ui_water_node_state_%s" % String(node.state),
		"kw": sim.water.data.kw_required(node.variant, node.level, node.subtype),
		"upgradeable": upgradeable,
		"upgrade": {
			"available": upgradeable and node.level < top,
			"ok": upgradeable and blockers.is_empty() and bool(preview["ok"]),
			"to_level": next_level,
			"cost": cost,
			"cost_text": RequirementFormatter.money(cost),
			"delta_kw": delta_kw,
			"deficit_kw": float(payload.get("deficit_kw", 0.0)),
			"checklist": rows,
			"blocked_by": blocked_by,
			"blocker_count": blockers.size(),
		},
	}


## Doc 05's ladder height for a variant: the tallest level its `placeable` roster
## offers, clamped by the `levels_4_5_enabled` gate the upgrade command applies.
## Read, never authored — `source` and `treatment` stop at 2, `pump` and `tank`
## at 3, and turning the flag on is a data change.
func max_level_of(variant: String) -> int:
	if sim == null:
		return MAX_LEVEL_GATED
	var gate := MAX_LEVEL if sim.water.data.flag(FLAG_LEVELS_4_5) else MAX_LEVEL_GATED
	var top := 1
	for entry: Variant in (sim.water.data.placeable_rules(variant)
			.get("placeable_levels", []) as Array):
		top = maxi(top, int(entry))
	return mini(top, gate)


## Per-code parameters for the node checklist — the same contract
## `BuildController._check_params` keeps.
##
## **Since Wave 18 that is literally true** (PA-75). Three of these rows are
## asked for by both panels and were written out twice, and the two copies had
## already drifted: `required_kw` carried the ×1.15 margin here and not there
## (PA-12), and `headroom_kw` was computed off `required` here and off the raw
## delta there. `RequirementFormatter` owns the shape now — the class whose own
## docstring says it is the only place a code's parameter shape is written down —
## and `tests/test_requirement_formatter.gd` asserts the two callers hand it
## identical dictionaries for one deficit.
func _check_params(node: WaterNode, next_level: int, top: int,
		payload: Dictionary) -> Dictionary:
	return {
		&"E_MAX_LEVEL": RequirementFormatter.level_params(node.level, top),
		&"E_LEVEL_UNAVAILABLE": {"need": next_level, "have": node.level},
		&"E_POWER_HEADROOM": RequirementFormatter.power_headroom_params(
				float(payload.get("delta_kw", 0.0)),
				float(payload.get("deficit_kw", 0.0)),
				headroom_margin(), _attachment_of(node)),
		&"E_FUNDS": RequirementFormatter.funds_params(int(payload.get("cost", 0)),
				sim.treasury.balance if sim != null else 0),
	}


## Doc 02 §8's `headroom_safety.power` — the margin `CitySim.cmd_upgrade_water_
## component` applies before it asks doc 04, read rather than authored (PA-12).
## `HEADROOM_MARGIN` above is the fallback for a fixture with no rules block.
func headroom_margin() -> float:
	if sim == null or sim.catalog == null:
		return HEADROOM_MARGIN
	var safety: Variant = sim.catalog.rules().get("headroom_safety", {})
	if not (safety is Dictionary):
		return HEADROOM_MARGIN
	return float((safety as Dictionary).get("power", HEADROOM_MARGIN))


## Doc 04's service record for the shell this node is hosted on — the component
## whose headroom the upgrade is short of. "" when the grid has no record, in
## which case the row simply has no camera target.
func _attachment_of(node: WaterNode) -> String:
	if sim == null or node.power_ref == "":
		return ""
	return sim.grid.attachment_of(node.power_ref)


## The real command (doc 12 §4.4). The panel refreshes from what the sim answers.
func upgrade_node(node_id: String) -> Dictionary:
	if sim == null:
		return CommandQueue.fail(&"E_UNKNOWN_NODE", {"node": node_id})
	return sim.cmd_upgrade_water_component(node_id)


# ===========================================================================
# The tactical pair — doc 05 §2.12, on the incident drawer's expanded row
# ===========================================================================

## The main a drawer row is about, or "" — doc 06 stamps
## `target_ref = {kind: "water_segment", id: <edge>}` on every `water_main_break`
## and on nothing else, so this is a lookup and not a guess.
static func segment_of_row(row: Dictionary) -> String:
	if str(row.get("target_kind", "")) != TARGET_WATER_SEGMENT:
		return ""
	return str(row.get("target_id", ""))


## What the drawer needs to draw ISOLATE / RESTORE for one main:
## `{exists, edge, tier, state, isolated, broken, tiles, length_km, zone,
##   condition, severity, can_isolate, can_restore, work_minutes}`.
##
## The two buttons are one button in two moods, and which mood is the main's
## own `state` — doc 05 §2.12 gives an isolated main back to the network only
## through `restore`, and `set_segment_repaired` clears the flag when the crew
## finishes, so a main isolated during a break cannot be stranded by resolving.
func segment_view(edge_id: String) -> Dictionary:
	var out := {"exists": false, "edge": edge_id, "tier": "", "state": "",
			"isolated": false, "broken": false, "tiles": 0, "length_km": 0.0,
			"zone": "", "condition": 1.0, "severity": 0.0,
			"can_isolate": false, "can_restore": false, "work_minutes": 0.0}
	if sim == null or edge_id == "":
		return out
	var edge: WaterEdge = sim.water.edge(edge_id)
	if edge == null:
		return out
	var zone := sim.water.topology.zone_of(edge_id)
	var isolated := edge.state == &"isolated"
	out["exists"] = true
	out["tier"] = edge.tier
	out["state"] = String(edge.state)
	out["isolated"] = isolated
	out["broken"] = edge.is_broken()
	out["tiles"] = edge.path.size()
	out["length_km"] = edge.length_km()
	out["zone"] = zone.zone_key if zone != null else ""
	out["condition"] = edge.condition
	out["severity"] = edge.severity
	out["can_isolate"] = not isolated
	out["can_restore"] = isolated
	# §2.12's work content for the valve run, at the same 0.5 severity
	# `WaterSystem.cmd_isolate_main` quotes it at. Doc 03 prices neither verb —
	# no capital changes hands — so this is the only figure either one has.
	out["work_minutes"] = sim.water.repairs.work_content_minutes("isolate_main", 0.5)
	return out


func isolate(edge_id: String) -> Dictionary:
	if sim == null:
		return CommandQueue.fail(&"E_UNKNOWN_MAIN", {"edge": edge_id})
	return sim.cmd_isolate_water_main(edge_id)


func restore(edge_id: String) -> Dictionary:
	if sim == null:
		return CommandQueue.fail(&"E_UNKNOWN_MAIN", {"edge": edge_id})
	return sim.cmd_restore_water_main(edge_id)


# ===========================================================================
# S19 — the water panel (doc 12 D-124, Wave 28)
# ===========================================================================
#
# The player, 2026-09-05: *"We've got to make sure the pump stations, the whole
# water infrastructure, is tight."* Doc 05 §6.1's Wave-11 ruling was that there
# should be NO water-node panel, on the argument that a node's only verb was an
# upgrade and the shell it is hosted on already had a panel. **That argument was
# true of the verb list of the time and is not true of this one.** A water node
# now answers four questions the shell's panel cannot: which stage of §2.5's
# CHAIN binds this zone, what the zone supplies against what it is asked for,
# which mains are broken and what stopping their leak would cost, and — the one
# the player asked for by name — whether adding a pump here would move anything.
# Those are facts about a NODE and its ZONE, not about a doc-02 building, and
# S18 is the precedent one document over: doc 04's transformer got exactly this
# panel in Wave 25 for exactly this reason.

## The stages of §2.5's chain, in the order the panel draws them — which is the
## order the water flows, not the order it binds. `WaterSystem.SUPPLY_STAGES` is
## the authority; this only fixes the row order and is asserted equal to it.
const CHAIN_STAGES: Array[StringName] = [&"source", &"treatment", &"pump", &"mains"]

## The gate `cmd_repair_water_asset` runs, in its order. `E_UNKNOWN_COMPONENT`
## and `E_NOT_DAMAGED` are not rows: they are the reason there is no row (a main
## in perfect condition is not a purchase), and the block simply does not draw.
const REPAIR_CHECKS: Array[StringName] = [&"E_ALREADY_REPAIRING", &"E_FUNDS"]

## Doc 05 §5.8's bands, as doc 12 §2.5's data-state tokens. Colour is the THIRD
## channel here as everywhere (constitution §11): the band word and the glyph
## carry it too.
const BAND_STATE := {
	"normal": HudModel.STATE_NORMAL, "warn": HudModel.STATE_WARNING,
	"critical": HudModel.STATE_CRITICAL, "none": HudModel.STATE_CRITICAL,
}


## Is there a doc-05 node here for S19 to open on? A `junction` is not one
## (§2.1: it is where mains meet, not a component), which is also why the pick
## does not offer it.
func opens_for(node_id: String) -> bool:
	if sim == null or node_id == "":
		return false
	var node: WaterNode = sim.water.nodes.get(node_id)
	return node != null and node.variant != &"junction"


## **The whole panel, as plain data.** Everything quoted is the sim's own
## `preview = true` or `WaterSystem.supply_chain()` — this class computes no
## capacity, prices nothing and authors no threshold.
func node_block(node_id: String) -> Dictionary:
	if not opens_for(node_id):
		return {"available": false, "node": node_id}
	var node: WaterNode = sim.water.nodes[node_id]
	var chain := sim.water.supply_chain_at_node(node_id)
	var zone: PressureZone = sim.water.topology.zone_of(node_id)
	var bands: Dictionary = sim.water.data.effects.get("bands", {})
	var band := zone.color_band(bands) if zone != null else "none"
	var record: Dictionary = sim.water.data.component(node.variant, node.level, node.subtype)
	var rated := float(record.get("rated_flow_m3h", record.get("throughput_m3h",
			record.get("yield_m3h", record.get("boost_flow_m3h",
			record.get("capacity_m3", 0.0))))))
	var fraction := sim.water.power_fraction_of(node)
	var out := node_view(node_id)
	out["available"] = true
	out["condition"] = node.condition
	out["condition_text"] = RequirementFormatter.percent(node.condition)
	out["tile"] = [node.tile.x, node.tile.y]
	out["power_ref"] = node.power_ref
	out["power_fraction"] = fraction
	out["on_backup"] = node.backup_installed and fraction > 0.0 and fraction < 1.0
	out["tripped"] = node.restart_timer_min > 0.0
	out["flow_m3h"] = node.flow_m3h
	out["rated_m3h"] = rated
	out["rated_text"] = RequirementFormatter.water_m3h(rated)
	out["is_tank"] = node.variant == &"tank"
	out["level_frac"] = (node.volume_m3 / maxf(float(record.get("capacity_m3", 0.0)), 1e-6)) \
			if node.variant == &"tank" else 1.0
	out["zone"] = _zone_row(zone, chain, band)
	out["chain"] = chain_rows(chain)
	out["binding"] = String(chain.get("binding", "none"))
	out["breaks"] = break_rows(zone)
	out["customers"] = customer_rows(zone)
	out["repair"] = repair_quote(node_id)
	out["remove"] = remove_quote(node_id)
	return out


## The zone this node feeds, in the words doc 05 §5.8 publishes for the overlay
## — so the panel and the overlay can never be two opinions about one zone.
func _zone_row(zone: PressureZone, chain: Dictionary, band: String) -> Dictionary:
	if zone == null:
		return {"exists": false}
	var buffer := zone.buffer_hours()
	return {
		"exists": true, "key": zone.zone_key, "band": band,
		"band_state": BAND_STATE.get(band, HudModel.STATE_CRITICAL),
		"band_key": "ui_water_band_%s" % band,
		"pressure": zone.pressure,
		"pressure_text": RequirementFormatter.percent(zone.pressure),
		"dead": zone.dead, "contaminated": zone.contaminated,
		"supply_m3h": zone.supply_m3h, "demand_m3h": zone.demand_m3h,
		"delivered_m3h": zone.delivered_m3h,
		"supply_text": RequirementFormatter.water_m3h(zone.supply_m3h),
		"demand_text": RequirementFormatter.water_m3h(zone.demand_m3h),
		"headroom_m3h": zone.headroom_m3h(),
		"headroom_text": RequirementFormatter.water_m3h(zone.headroom_m3h()),
		# The meter: how much of what the zone is asked for it can actually
		# supply. Doc 92 §67.5's argument, restated — a bar on PRESSURE reads
		# green until the zone is already short, so the bar is on utilization
		# and the BAND beside it is on pressure.
		"meter01": clampf(zone.demand_m3h / maxf(zone.supply_m3h, 0.001), 0.0, 1.0),
		"leak_m3h": zone.leak_m3h,
		"leak_text": RequirementFormatter.water_m3h(zone.leak_m3h),
		"fire_draw_m3h": zone.fire_draw_m3h,
		"break_penalty": zone.break_penalty,
		"tank_volume_m3": zone.tank_volume_m3, "tank_capacity_m3": zone.tank_capacity_m3,
		"tank_frac": zone.level_frac(),
		"buffer_hours": buffer,
		"buffer_text": "—" if buffer < 0.0 else "%.1f" % buffer,
		"building_count": zone.building_count,
		"stranded_m3h": float(chain.get("stranded_m3h", 0.0)),
	}


## **§2.5's chain, one row per stage, with the binding one marked.** This is the
## read doc 92 §67.4 bought 118 pumps for the want of: the zone was
## treatment-bound the whole time, and no surface in the game said so.
func chain_rows(chain: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if chain.is_empty() or not bool(chain.get("live", false)):
		return out
	var binding := String(chain.get("binding", "none"))
	for stage: StringName in CHAIN_STAGES:
		var value := 0.0
		var detail := ""
		match stage:
			&"source":
				value = float(chain["source_m3h"])
			&"treatment":
				value = float(chain["treatment_m3h"])
			&"pump":
				value = float(chain["pump_available_m3h"])
				detail = RequirementFormatter.water_m3h(chain["pump_rated_m3h"])
			&"mains":
				value = float(chain["mains_m3h"])
		out.append({
			"stage": String(stage),
			"name_key": "ui_water_stage_%s" % String(stage),
			"m3h": value,
			"text": RequirementFormatter.water_m3h(value),
			"rated_text": detail,
			"binding": String(stage) == binding,
			# The bar is each stage against the widest stage, so the narrow one
			# is visibly the narrow one. No threshold: a ratio of two numbers
			# doc 05 already published.
			"meter01": clampf(value / maxf(_widest(chain), 0.001), 0.0, 1.0),
			"state": HudModel.STATE_WARNING if String(stage) == binding \
					else HudModel.STATE_NORMAL,
			# What the player would tap to raise this stage. `mains` has none —
			# it is answered by laying a main, not by upgrading a node.
			"node": String((chain["binding_ids"] as Array)[0]) \
					if String(stage) == binding and not (chain["binding_ids"] as Array).is_empty() \
					else "",
		})
	return out


static func _widest(chain: Dictionary) -> float:
	return maxf(maxf(float(chain["source_m3h"]), float(chain["treatment_m3h"])),
			maxf(float(chain["pump_available_m3h"]), float(chain["mains_m3h"])))


## Every main in this zone that is not OK, with what putting it back costs. The
## row exists because a break's only other surface is doc 06's incident drawer,
## and a break whose incident has gone terminal is on no drawer at all — which
## is how the player's own save came to be leaking 95 % of its water with
## nothing in the game saying so (doc 92 §69.1).
func break_rows(zone: PressureZone) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if zone == null:
		return out
	for raw: Variant in zone.edge_ids:
		var edge_id := String(raw)
		var edge: WaterEdge = sim.water.edge(edge_id)
		if edge == null or edge.state == &"ok":
			continue
		var row := segment_view(edge_id)
		row["leak_m3h"] = edge.capacity_m3h * sim.water.data.global_value(
				"leak_frac_of_capacity", 0.25) * edge.severity if edge.is_broken() else 0.0
		row["leak_text"] = RequirementFormatter.water_m3h(row["leak_m3h"])
		row["repair"] = repair_quote(edge_id)
		row["state_key"] = "ui_water_main_state_%s" % String(edge.state)
		out.append(row)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(float(a["leak_m3h"]), float(b["leak_m3h"])):
			return float(a["leak_m3h"]) > float(b["leak_m3h"])
		return String(a["edge"]) < String(b["edge"]))
	return out


## The buildings this zone serves, worst pressure first — because the row a
## player opens this panel to find is the one that is dry.
func customer_rows(zone: PressureZone) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if zone == null or sim == null:
		return out
	var gate := sim.water.data.effect("upgrade_min_pressure", 0.55)
	var normal := sim.water.data.effect("happiness_pressure_ref", 0.60)
	for raw: Variant in sim.water.demand.sorted_ids():
		var sim_id := String(raw)
		var tile: Vector2i = sim.water.demand.access_tile(sim_id)
		if sim.water.topology.zone_at_tile(tile) != zone.index:
			continue
		var pressure := sim.water.pressure_at(tile)
		var building: Building = sim.buildings.get(sim_id)
		out.append({
			"sim_id": sim_id,
			"archetype": String(building.archetype) if building != null else "",
			"name_key": BuildController.card_name_key(
					String(building.archetype) if building != null else "", ""),
			"pressure": pressure,
			"pressure_text": RequirementFormatter.percent(pressure),
			# §2.3's factor is DISTANCE TO A MAIN, and it is the whole reason a
			# zone at pressure 1.00 can refuse a building at 0.50 (doc 92 §67.8).
			# The row says how far, so the answer — lay a main — is readable.
			"main_distance_tiles": sim.water.topology.distance_at_tile(tile),
			"under_gate": pressure < gate,
			"state": HudModel.STATE_NORMAL if pressure >= normal \
					else (HudModel.STATE_WARNING if pressure >= gate
							else HudModel.STATE_CRITICAL),
			"tile": [tile.x, tile.y],
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(float(a["pressure"]), float(b["pressure"])):
			return float(a["pressure"]) < float(b["pressure"])
		return String(a["sim_id"]) < String(b["sim_id"]))
	return out


## REPAIR — CALL CREWS, for a node or a main. `cmd_repair_water_asset`'s own
## preview, in the shape `PowerActions.repair_quote` publishes one document over.
func repair_quote(asset_id: String) -> Dictionary:
	if sim == null or asset_id == "":
		return {"available": false}
	var preview := sim.cmd_repair_water_asset(asset_id, true)
	var payload: Dictionary = preview.get("payload", {})
	var code := StringName(str(preview.get("reason_code", &"")))
	if code == &"E_UNKNOWN_COMPONENT":
		return {"available": false, "reason": String(code)}
	var job_id := int(payload.get("job_id", -1))
	if code == &"E_NOT_DAMAGED" and job_id < 0:
		return {"available": false, "reason": String(code)}
	var blockers: Array = payload.get("blockers", [])
	var cost := int(payload.get("cost", 0))
	var rows := formatter.checklist(REPAIR_CHECKS, blockers,
			{"cost": cost, "balance": sim.treasury.balance, "at": asset_id},
			{&"E_ALREADY_REPAIRING": {"component": asset_id},
			&"E_FUNDS": RequirementFormatter.funds_params(cost, sim.treasury.balance)})
	return {
		"available": true,
		"ok": bool(preview["ok"]),
		"asset": asset_id,
		"target_kind": String(payload.get("target_kind", "")),
		"kind": String(payload.get("kind", "")),
		"down": bool(payload.get("down", false)),
		"condition": float(payload.get("condition", 1.0)),
		"condition_text": RequirementFormatter.percent(payload.get("condition", 1.0)),
		"damage_fraction": float(payload.get("damage_fraction", 0.0)),
		"damage_text": RequirementFormatter.percent(payload.get("damage_fraction", 0.0)),
		"repair_target": float(payload.get("repair_target", 1.0)),
		"repair_target_text": RequirementFormatter.percent(payload.get("repair_target", 1.0)),
		"leak_m3h": float(payload.get("leak_m3h", 0.0)),
		"leak_text": RequirementFormatter.water_m3h(payload.get("leak_m3h", 0.0)),
		"cost": cost,
		"cost_text": RequirementFormatter.money(cost),
		"affordable": sim.treasury.balance >= cost,
		"crew_hours": float(payload.get("crew_hours", 0.0)),
		"crew_type": String(payload.get("crew_type", "")),
		"crew_key": "ui_unit_kind_%s" % String(payload.get("crew_type", "")),
		"customers": int(payload.get("customers", 0)),
		"in_flight": job_id >= 0,
		"job_id": job_id,
		"progress01": sim.construction.progress(job_id) if job_id >= 0 else 0.0,
		"eta_gm": sim.construction.eta_game_minutes(job_id) if job_id >= 0 else -1.0,
		"blockers": blockers,
		"checklist": rows,
		"blocked_by": RequirementFormatter.first_blocker(rows),
	}


## REMOVE. A doc-05 node has no demolition verb of its own and does not want
## one: `cmd_place_water_component` builds a doc-02 SHELL and the node hosted on
## it together, and `CitySim._retire_water_nodes` already takes the node with the
## shell. So REMOVE is the shell's demolition, quoted through the node the player
## is standing on — which is also why a node whose shell the sim has never heard
## of (an authored fixture) draws no row rather than a dead button.
func remove_quote(node_id: String) -> Dictionary:
	if sim == null or node_id == "":
		return {"available": false}
	var node: WaterNode = sim.water.nodes.get(node_id)
	if node == null or node.power_ref == "" or not sim.buildings.has(node.power_ref):
		return {"available": false, "reason": "E_NO_SHELL"}
	var preview := sim.cmd_demolish_building(node.power_ref, true)
	var payload: Dictionary = preview.get("payload", {})
	var refund := int(payload.get("refund", 0))
	var hosted := nodes_of(node.power_ref)
	return {
		"available": true,
		"ok": bool(preview["ok"]),
		"sim_id": node.power_ref,
		"reason": String(preview.get("reason_code", &"")),
		"refund": refund,
		"refund_text": RequirementFormatter.money(refund),
		# **The sentence that stops a mis-tap**: `WTR-1` hosts an intake, a
		# treatment train and a pump, and removing the building removes all
		# three. The panel says how many before the second tap, not after.
		"hosted_nodes": hosted.size(),
		"hosted": hosted,
	}


# --- the verbs, one line each -------------------------------------------

func repair(asset_id: String) -> Dictionary:
	if sim == null:
		return CommandQueue.fail(&"E_UNKNOWN_COMPONENT", {"asset": asset_id})
	return sim.cmd_repair_water_asset(asset_id)


func remove(node_id: String) -> Dictionary:
	if sim == null:
		return CommandQueue.fail(&"E_UNKNOWN_NODE", {"node": node_id})
	var node: WaterNode = sim.water.nodes.get(node_id)
	if node == null or node.power_ref == "":
		return CommandQueue.fail(&"E_UNKNOWN_NODE", {"node": node_id})
	return sim.cmd_demolish_building(node.power_ref)
