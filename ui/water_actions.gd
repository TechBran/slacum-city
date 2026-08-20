class_name WaterActions
extends RefCounted
## Doc 05 §6's last three verbs, given doors (doc 93 §J1, doc 92 §27).
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
## `BuildController._check_params` keeps: the command returns codes and totals,
## and the numbers each row quotes are re-read here.
func _check_params(node: WaterNode, next_level: int, top: int,
		payload: Dictionary) -> Dictionary:
	var delta_kw := float(payload.get("delta_kw", 0.0))
	var deficit := float(payload.get("deficit_kw", 0.0))
	var required := delta_kw * HEADROOM_MARGIN
	return {
		&"E_MAX_LEVEL": {"level": node.level, "max_level": top},
		&"E_LEVEL_UNAVAILABLE": {"need": next_level, "have": node.level},
		&"E_POWER_HEADROOM": {
			"deficit_kw": deficit,
			"required_kw": required,
			"headroom_kw": maxf(0.0, required - deficit),
			# The TRANSFORMER the site hangs off, not the site — `power_ref` is
			# the shell the player already has open, and `Fix this →` that flies
			# the camera to the thing under their thumb moves nothing (doc 12
			# D-35's lesson, applied one doc over).
			"at": _attachment_of(node),
			"fix_target_id": _attachment_of(node),
		},
		&"E_FUNDS": {"cost": int(payload.get("cost", 0)),
				"balance": sim.treasury.balance if sim != null else 0},
	}


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
