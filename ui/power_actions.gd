class_name PowerActions
extends RefCounted
## Doc 04 §4's operating verbs, given doors (Wave 17 — doc 93 §AD, doc 92 §48,
## doc 12 §2.9 D-70/D-71/D-72).
##
## Three things the player could not do and one thing the player could not see:
##
##   * **See the connection.** A building drew power from a transformer it was
##     never told the name of, through a feeder whose spare capacity was
##     invisible. The panel's POWER section is `building_block()` — which transformer,
##     how many hops, what it carries now, what it carries at the evening peak,
##     and what the NEXT level would add.
##   * **Fix a `POWER_CAPACITY` blocker.** `Fix this →` focused the camera on
##     the building the player already had open (game/main.gd, the lead's
##     reproduction; A91-D-54). `fix_quote()` / `fix()` run
##     `CitySim.cmd_fix_power_capacity`, which quotes the cheapest single
##     purchase that clears the serving path and buys it on confirm.
##   * **Buy a bigger transformer for the one that is there.** `upgrade_quote()`
##     / `upgrade()` run `cmd_upgrade_grid_component` — a transformer one rung up
##     doc 04 §2.2's ladder, or a feeder onto heavier copper.
##   * **Take a transformer out and put it somewhere else.**
##     `demolish_quote()` / `demolish()` run `cmd_demolish_grid_component`:
##     doc 03 §2.3's 25 % refund, the customers it strands, and a `replace_cost`
##     so a MOVE can be quoted before the hold starts.
##
## Constitution §3 / doc 12 §1: pure `RefCounted`, no `Node`, no scene tree, no
## copy and no threshold authored here. Every verdict is the sim's own
## `preview = true`, every string is a `data/strings.en.json` KEY, and every
## number is formatted by `RequirementFormatter`.

## The gate `cmd_upgrade_grid_component` runs, in its order — the rows the
## UPGRADE button's checklist draws. `E_UNKNOWN_COMPONENT` is not a row: it is
## the reason there is no block at all.
const UPGRADE_CHECKS: Array[StringName] = [
	&"E_MAX_LEVEL", &"E_STATE", &"E_FUNDS",
]

## The refusals `cmd_fix_power_capacity` can answer with that are worth a line of
## copy under the button. `E_NOT_BLOCKED` is not among them — a building whose
## next level is not power-blocked simply has no fix strip.
const FIX_CHECKS: Array[StringName] = [
	&"E_UNSERVED", &"E_NEEDS_TRANSFORMER", &"E_NO_SLOT", &"E_FUNDS",
]

## The gate `cmd_repair_grid_component` runs, in its order (Wave 25, RR-206).
## `E_NOT_DAMAGED` and `E_UNKNOWN_COMPONENT` are NOT rows: neither is a thing the
## player can fix, and a strip that drew `✗ In good repair` under a dead REPAIR
## button would be selling a refusal as a requirement. `repair_quote()` folds
## both into `available: false` and the panel draws no strip at all — the same
## shape `fix_quote()` gives `E_NOT_BLOCKED`.
const REPAIR_CHECKS: Array[StringName] = [
	&"E_ALREADY_REPAIRING", &"E_FUNDS",
]

## §5.10's overlay bands, as the doc 12 §2.5 state tokens the row tints with, so
## the panel reads the same three colours the overlay paints (A5: the glyph and
## the word carry it too, colour is the third channel).
const BAND_STATE := [HudModel.STATE_NORMAL, HudModel.STATE_WARNING, HudModel.STATE_CRITICAL]
## …and the string key per band. Copy lives in `data/strings.en.json`.
const BAND_KEY := ["ui_power_band_ok", "ui_power_band_warning", "ui_power_band_critical"]

var sim: CitySim
var formatter: RequirementFormatter


func _init(p_sim: CitySim = null, p_formatter: RequirementFormatter = null) -> void:
	sim = p_sim
	formatter = p_formatter if p_formatter != null else RequirementFormatter.load_from_files()


# ===========================================================================
# The TRANSFORMER's own reading — doc 12 §2.25, Wave 25 (RR-207, doc 93 §AY2)
# ===========================================================================

## Everything S18 draws about one transformer, as plain data.
##
## **The same numbers the building panel's hop row has always shown, read from
## the thing itself rather than through one of its customers** — plus the two
## the hop row could not answer: who else is behind this pad
## (`PowerGrid.buildings_served_by`, RR-205), and what a crew would cost
## (`repair_quote`, RR-206).
##
## `available` is false only for an id the grid has never heard of.
## `unattached` is a real state and not an error: a pad the player placed ahead
## of the houses feeds nobody, and the panel says so.
func transformer_block(component_id: String) -> Dictionary:
	if sim == null or component_id == "" or not sim.grid.has_component(component_id):
		return {"available": false, "component": component_id}
	var c := sim.grid.component(component_id)
	var ambient := sim.ambient_c()
	var effective := sim.grid.cap_eff(component_id, ambient)
	var peaks := sim.peak_component_loads()
	var load := float(c["load_kw"])
	var peak := maxf(load, float(peaks.get(component_id, 0.0)))
	var band := PowerGrid.capacity_band(peak / maxf(1.0, effective))
	var served := sim.grid.buildings_served_by(component_id)
	var rows: Array[Dictionary] = []
	for building_id: Variant in served:
		rows.append(_customer_row(String(building_id)))
	# The two hops ABOVE this one — the feeder and the substation behind the pad.
	# Wave 17 drew them on the BUILDING panel; they belong here, because they are
	# facts about the transformer and not about any one house it feeds.
	var upstream: Array[Dictionary] = []
	var parent := String(c["parent"])
	var hop := 1
	while parent != "" and sim.grid.has_component(parent):
		var up := sim.grid.component(parent)
		var up_eff := sim.grid.cap_eff(parent, ambient)
		var up_peak := maxf(float(up["load_kw"]), float(peaks.get(parent, 0.0)))
		var up_band := PowerGrid.capacity_band(up_peak / maxf(1.0, up_eff))
		upstream.append({
			"id": parent,
			"kind": String(up["kind"]),
			"name_key": "ui_power_kind_%s" % String(up["kind"]),
			"hop": hop,
			"level": int(up["level"]),
			"state": String(up["state"]),
			"energized": bool(up["energized"]),
			"shed": sim.grid.shed_feeders.has(parent),
			"load_kw": up_peak,
			"load_text": RequirementFormatter.power(up_peak),
			"capacity_kw": up_eff,
			"capacity_text": RequirementFormatter.power(up_eff),
			"headroom_text": RequirementFormatter.power(maxf(0.0, up_eff - up_peak)),
			"load_ratio": up_peak / maxf(1.0, up_eff),
			"band": up_band,
			"band_key": BAND_KEY[up_band],
			"band_state": BAND_STATE[up_band],
			"upgrade": upgrade_quote(parent),
		})
		parent = String(up["parent"])
		hop += 1
	var state := String(c["state"])
	var repair := repair_quote(component_id)
	return {
		"available": true,
		"component": component_id,
		"kind": String(c["kind"]),
		"name_key": "ui_power_kind_%s" % String(c["kind"]),
		"level": int(c["level"]),
		"max_level": PowerGrid.CAPACITY[c["kind"]].size(),
		"tile": sim.grid.component_tile(component_id),
		"state": state,
		"state_key": "ui_power_state_%s" % state.to_lower(),
		"failed": state == "FAILED",
		"energized": bool(c["energized"]),
		"condition": float(c["condition"]),
		"condition_text": RequirementFormatter.percent(c["condition"]),
		# §5.10's distress band — `PowerGrid.distress_band`, the SAME function
		# `PowerInfraModel` classifies the pad with, so the word on the panel and
		# the look of the cabinet in the world are one verdict (doc 93 §AY2).
		"distress": PowerGrid.distress_band(state, bool(c["energized"]),
				peak / maxf(1.0, effective), float(c["condition"]),
				ambient + float(c["theta_c"])),
		"distress_key": "ui_power_distress_%d" % PowerGrid.distress_band(state,
				bool(c["energized"]), peak / maxf(1.0, effective),
				float(c["condition"]), ambient + float(c["theta_c"])),
		"temp_c": ambient + float(c["theta_c"]),
		"ambient_c": ambient,
		# The meter: what it carries at its own customers' worst hour against
		# what it can carry AT TODAY'S AMBIENT. Doc 04 §2.7's derating is why the
		# nameplate is not the answer, and why the panel prints both.
		"load_kw": load,
		"load_text": RequirementFormatter.power(load),
		"peak_load_kw": peak,
		"peak_text": RequirementFormatter.power(peak),
		"capacity_kw": effective,
		"capacity_text": RequirementFormatter.power(effective),
		"nameplate_kw": float(c["capacity_kw"]),
		"nameplate_text": RequirementFormatter.power(c["capacity_kw"]),
		"derated": effective < float(c["capacity_kw"]) - 0.5,
		"headroom_kw": effective - peak,
		"headroom_text": RequirementFormatter.power(maxf(0.0, effective - peak)),
		"load_ratio": peak / maxf(1.0, effective),
		"band": band,
		"band_key": BAND_KEY[band],
		"band_state": BAND_STATE[band],
		"peak_hour": sim.peak_hour_of_day(),
		"service_radius_tiles": PowerGrid.TRANSFORMER_SERVICE_RADIUS[
				clampi(int(c["level"]) - 1, 0, PowerGrid.TRANSFORMER_SERVICE_RADIUS.size() - 1)],
		"customers": rows,
		"customer_count": rows.size(),
		"unattached": rows.is_empty(),
		"upstream": upstream,
		"upgrade": upgrade_quote(component_id),
		"repair": repair,
		"demolish": demolish_quote(component_id),
	}


## One building behind the pad: what it is, what it draws, what class it sheds
## in, and whether it is lit right now. Every row is a JUMP target, so it carries
## the origin the camera needs.
func _customer_row(sim_id: String) -> Dictionary:
	var b: Building = sim.buildings.get(sim_id)
	if b == null:
		# Attached but not in the roster: a save that lost a building the grid
		# still holds. Named rather than dropped, because a silent omission here
		# would make the panel's count disagree with the demolition quote's.
		return {"sim_id": sim_id, "exists": false, "name_key": "",
				"name_fallback": sim_id, "demand_kw": 0.0, "demand_text": "—",
				"priority": "STANDARD",
				"priority_key": BuildController.priority_key("STANDARD"),
				"powered": false, "tile": Vector2i.ZERO}
	var priority := String(sim.grid.priority_class_of(sim_id))
	return {
		"sim_id": sim_id,
		"exists": true,
		"archetype": String(b.archetype),
		"name_key": BuildController.card_name_key(String(b.archetype), String(b.variant)),
		"name_fallback": str(sim.catalog.archetype_info(String(b.archetype)).get("name",
				String(b.archetype))),
		"level": b.level,
		"demand_kw": sim.building_demand_kw(sim_id),
		"demand_text": RequirementFormatter.power(sim.building_demand_kw(sim_id)),
		"priority": priority,
		"priority_key": BuildController.priority_key(priority),
		"powered": sim.grid.is_powered(sim_id),
		"tile": b.origin,
	}


# ===========================================================================
# The POWER section — doc 12 §2.9 D-70
# ===========================================================================

## The building panel's power block. `available` is false only when the sim is
## missing or the building is not on the grid's books at all; an UNSERVED
## building still gets the block, because "nothing feeds this" is the single most
## useful thing the section can say.
##
## `hops` is how many components sit between the building and the bulk pool —
## 3 is the ordinary transformer → feeder → substation, 1 is an orphaned
## transformer whose feeder is gone, 0 is unserved. `rows` is one entry per hop
## in `PowerGrid.service_path()`'s shape plus the band and the two readings:
## `load_kw` now and `peak_load_kw` at its own customers' worst hour.
##
## `next_level` is the headroom question the player is actually asking — "if I
## upgrade this building, does the wire carry it?" — answered against the same
## `power_headroom` the UPGRADE button's checklist is gated on, so the section
## and the checklist can never disagree.
func building_block(sim_id: String) -> Dictionary:
	if sim == null or not sim.buildings.has(sim_id):
		return {"available": false}
	var b: Building = sim.buildings[sim_id]
	var path := sim.grid.service_path(sim_id, sim.ambient_c(), sim.peak_component_loads())
	var rows: Array[Dictionary] = []
	for row: Dictionary in (path["rows"] as Array):
		rows.append(_hop_row(row))
	var top: int = sim.catalog.max_level_of(String(b.archetype))
	var next := _next_level_block(sim_id, b, top)
	return {
		"available": true,
		"sim_id": sim_id,
		"unserved": bool(path["unserved"]),
		"transformer": String(path["transformer"]),
		"feeder": String(path["feeder"]),
		"substation": String(path["substation"]),
		"hops": int(path["hops"]),
		"energized": bool(path["energized"]),
		"powered": bool(path["powered"]),
		"shed": bool(path["shed"]),
		"demand_kw": sim.building_demand_kw(sim_id),
		"demand_text": RequirementFormatter.power(sim.building_demand_kw(sim_id)),
		"peak_hour": sim.peak_hour_of_day(),
		"rows": rows,
		"next_level": next,
		"fix": fix_quote(sim_id),
	}


## One hop, shaped for a row of the section. `headroom_text` is the words half of
## §5.10's band — the section has to be readable without the ratio, because a
## ratio is a number a player has to be taught and "62 kW spare" is not.
func _hop_row(row: Dictionary) -> Dictionary:
	var peak := float(row.get("peak_load_kw", row["load_kw"]))
	var effective := float(row["effective_kw"])
	var band := PowerGrid.capacity_band(peak / maxf(1.0, effective))
	return {
		"id": String(row["id"]),
		"kind": String(row["kind"]),
		"hop": int(row["hop"]),
		"level": int(row["level"]),
		"conductor_class": int(row.get("conductor_class", 0)),
		"name_key": "ui_power_kind_%s" % String(row["kind"]),
		"customers": int(row["customers"]),
		"state": String(row["state"]),
		"energized": bool(row["energized"]),
		"shed": bool(row["shed"]),
		"load_kw": float(row["load_kw"]),
		"load_text": RequirementFormatter.power(row["load_kw"]),
		"peak_load_kw": peak,
		"peak_text": RequirementFormatter.power(peak),
		"capacity_kw": effective,
		"capacity_text": RequirementFormatter.power(effective),
		"headroom_kw": effective - peak,
		"headroom_text": RequirementFormatter.power(maxf(0.0, effective - peak)),
		"load_ratio": peak / maxf(1.0, effective),
		"band": band,
		"band_key": BAND_KEY[band],
		"band_state": BAND_STATE[band],
		"upgrade": upgrade_quote(String(row["id"])),
	}


## "Does the wire carry the next level?" — the same numbers `cmd_upgrade_building`
## refuses on, quoted whether or not it refuses, because a player deciding to
## save up wants the answer BEFORE the row turns red.
func _next_level_block(sim_id: String, b: Building, top: int) -> Dictionary:
	if b.level >= top:
		return {"available": false}
	var next_stats: Dictionary = sim.catalog.stats(String(b.archetype), b.level + 1)
	var delta := (float(next_stats.get("power_demand_kw", 0.0))
			- float(b.stats.get("power_demand_kw", 0.0))) * CitySim.UPGRADE_HEADROOM_MARGIN
	var headroom := sim.power_headroom(sim_id, delta)
	return {
		"available": true,
		"to_level": b.level + 1,
		"delta_kw": delta,
		"delta_text": RequirementFormatter.power(delta),
		"ok": bool(headroom["ok"]),
		"binds_at": String(headroom.get("at", "")),
		"binds_kind": String(headroom.get("kind", "")),
		"r_after": float(headroom.get("r_after", 0.0)),
		"deficit_kw": float(headroom.get("deficit_kw", 0.0)),
		"deficit_text": RequirementFormatter.power(headroom.get("deficit_kw", 0.0)),
	}


# ===========================================================================
# The one-tap fix — doc 12 §2.7's `Fix this →`, A91-D-54
# ===========================================================================

## What one tap would buy, and what it would cost. `{available, action, cost,
## cost_text, component, clears, blockers, checklist, …}`; `available` is false
## when the next level is not power-blocked (`E_NOT_BLOCKED`), which is the
## ordinary case and draws no strip at all.
##
## The strip is a CONFIRM, not a button: `cost` is real money and the sim's
## `preview = true` is the only thing that knows it, so the panel quotes first
## and charges on the second tap (doc 12 §2.7's "never spend on one tap" and the
## same shape the demolish row's hold-to-confirm has).
func fix_quote(sim_id: String) -> Dictionary:
	if sim == null or sim_id == "":
		return {"available": false}
	var preview := sim.cmd_fix_power_capacity(sim_id, true)
	var payload: Dictionary = preview.get("payload", {})
	var code := StringName(str(preview.get("reason_code", &"")))
	if code == &"E_NOT_BLOCKED" or code == &"E_UNKNOWN_BUILDING":
		return {"available": false, "reason": String(code)}
	var blockers: Array = payload.get("blockers", [])
	var action := String(payload.get("action", ""))
	var cost := int(payload.get("cost", 0))
	var rows := formatter.checklist(FIX_CHECKS, blockers,
			{"cost": cost, "balance": sim.treasury.balance},
			{&"E_NEEDS_TRANSFORMER": {"component": String(payload.get("at", "")),
					"cost": int(payload.get("place_cost", 0))},
			&"E_NO_SLOT": {"component": String(payload.get("at", "")),
					"cost": int(payload.get("substation_cost", 0))}})
	return {
		"available": true,
		"ok": bool(preview["ok"]),
		"action": action,
		# One key per action, spliced. An action this file does not know renders
		# as the raw token rather than as a wrong word.
		"action_key": "ui_power_fix_%s" % action if action != "" else "",
		"component": String(payload.get("component", "")),
		"binds_at": String(payload.get("binds_at", "")),
		"binds_kind": String(payload.get("binds_kind", "")),
		"to_level": int(payload.get("to_level", 0)),
		"to_class": int(payload.get("to_class", 0)),
		"to_capacity_kw": float(payload.get("to_capacity_kw", 0.0)),
		"to_capacity_text": RequirementFormatter.power(payload.get("to_capacity_kw", 0.0)),
		"clears": bool(payload.get("clears", false)),
		"cost": cost,
		"cost_text": RequirementFormatter.money(cost),
		"affordable": sim.treasury.balance >= cost,
		"blockers": blockers,
		"checklist": rows,
		"blocked_by": RequirementFormatter.first_blocker(rows),
	}


## Buy it. Returns the sim's own `{ok, reason_code, payload}`; `payload.cleared`
## says whether the blocker is gone and `payload.next_blocker` names what a
## second tap would meet.
func fix(sim_id: String) -> Dictionary:
	if sim == null or sim_id == "":
		return CommandQueue.fail(&"E_UNKNOWN_BUILDING")
	return sim.cmd_fix_power_capacity(sim_id)


# ===========================================================================
# The bigger transformer / the heavier copper — doc 04 §2.2's ladder
# ===========================================================================

## `cmd_upgrade_grid_component(preview = true)`, shaped for a button face:
## `{available, ok, cost_text, to_capacity_text, checklist, …}`. `available` is
## false for a component with no ladder here (a substation and a plant are
## BUILDINGS and upgrade through their own panel — report 98 C-30).
func upgrade_quote(component_id: String) -> Dictionary:
	if sim == null or component_id == "" or not sim.grid.has_component(component_id):
		return {"available": false}
	var kind := String(sim.grid.component(component_id)["kind"])
	if kind != "transformer" and kind != "feeder":
		return {"available": false, "kind": kind}
	var preview := sim.cmd_upgrade_grid_component(component_id, true)
	var payload: Dictionary = preview.get("payload", {})
	var blockers: Array = payload.get("blockers", [])
	var cost := int(payload.get("cost", 0))
	var rows := formatter.checklist(UPGRADE_CHECKS, blockers,
			{"cost": cost, "balance": sim.treasury.balance},
			{&"E_MAX_LEVEL": {"level": int(payload.get("max_level", 0))},
			&"E_STATE": {"state": String(payload.get("state", "")),
					"required": String(payload.get("required_state", "OK"))}})
	return {
		"available": true,
		"component": component_id,
		"kind": kind,
		"ok": bool(preview["ok"]),
		"from_level": int(payload.get("from_level", 0)),
		"to_level": int(payload.get("to_level", 0)),
		"from_class": int(payload.get("from_class", 0)),
		"to_class": int(payload.get("to_class", 0)),
		"tiles": int(payload.get("tiles", 0)),
		"capacity_kw": float(payload.get("capacity_kw", 0.0)),
		"to_capacity_kw": float(payload.get("to_capacity_kw", 0.0)),
		"to_capacity_text": RequirementFormatter.power(payload.get("to_capacity_kw", 0.0)),
		"cost": cost,
		# The price is ON THE FACE, and it is on the face of a DISABLED button
		# too (doc 12 §2.7): a button that hides its price while the player is
		# broke teaches nothing about how much to save.
		"cost_text": RequirementFormatter.money(cost),
		"affordable": sim.treasury.balance >= cost,
		"blockers": blockers,
		"checklist": rows,
		"blocked_by": RequirementFormatter.first_blocker(rows),
	}


func upgrade(component_id: String) -> Dictionary:
	if sim == null or component_id == "":
		return CommandQueue.fail(&"E_UNKNOWN_COMPONENT")
	return sim.cmd_upgrade_grid_component(component_id)


# ===========================================================================
# Take it out, put it back — doc 02 §2.12's demolition on a grid node
# ===========================================================================

## `cmd_demolish_grid_component(preview = true)`. `customers` is how many
## buildings it feeds and `stranded` how many of those no other transformer
## reaches — the number the hold-to-confirm has to put in front of the player,
## because that is how many go dark.
##
## `move_cost` is the honest price of a MOVE: replace it at the same level, less
## the refund. A move is demolish + place and this file does not pretend
## otherwise; it just says what the pair costs before the first half is done.
func demolish_quote(component_id: String) -> Dictionary:
	if sim == null or component_id == "" or not sim.grid.has_component(component_id):
		return {"available": false}
	var preview := sim.cmd_demolish_grid_component(component_id, true)
	if not bool(preview["ok"]):
		return {"available": false, "reason": String(preview.get("reason_code", &""))}
	var payload: Dictionary = preview.get("payload", {})
	var refund := int(payload.get("refund", 0))
	var replace := int(payload.get("replace_cost", 0))
	return {
		"available": true,
		"component": component_id,
		"level": int(payload.get("level", 1)),
		"refund": refund,
		"refund_text": RequirementFormatter.money(refund),
		"replace_cost": replace,
		"move_cost": maxi(0, replace - refund),
		"move_cost_text": RequirementFormatter.money(maxi(0, replace - refund)),
		"customers": int(payload.get("customers", 0)),
		"stranded": (payload.get("stranded", []) as Array).size(),
		"fed": payload.get("fed", []),
	}


func demolish(component_id: String) -> Dictionary:
	if sim == null or component_id == "":
		return CommandQueue.fail(&"E_UNKNOWN_COMPONENT")
	return sim.cmd_demolish_grid_component(component_id)


# ===========================================================================
# Call the crews — doc 04 §4.2 (Wave 25, RR-206, doc 93 §AY1)
# ===========================================================================

## `cmd_repair_grid_component(preview = true)`, shaped for a button face:
## `{available, ok, cost_text, crew_hours, eta_text, checklist, …}`.
##
## `available` is false for the two answers that are not a purchase the player
## can make — `E_NOT_DAMAGED` (there is nothing here to fix, which is the
## ORDINARY case and draws no strip) and `E_UNKNOWN_COMPONENT`. Everything else
## draws, including the refusals, because a REPAIR button that hides its price
## while the player is broke teaches nothing about how much to save (doc 12
## §2.7, the same rule the UPGRADE button obeys one section up).
##
## `in_flight` is the live job, when there is one: the panel shows a crew's
## progress bar and its ETA instead of a button, because at that point the
## player has already decided and the question is *when*.
func repair_quote(component_id: String) -> Dictionary:
	if sim == null or component_id == "":
		return {"available": false}
	var preview := sim.cmd_repair_grid_component(component_id, true)
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
			{"cost": cost, "balance": sim.treasury.balance,
			"at": component_id},
			{&"E_ALREADY_REPAIRING": {"component": component_id}})
	var job := sim.construction.job(job_id) if job_id >= 0 else {}
	return {
		"available": true,
		"ok": bool(preview["ok"]),
		"component": component_id,
		"kind": String(payload.get("kind", "")),
		"failed": bool(payload.get("failed", false)),
		"condition": float(payload.get("condition", 1.0)),
		"condition_text": RequirementFormatter.percent(payload.get("condition", 1.0)),
		"damage_fraction": float(payload.get("damage_fraction", 0.0)),
		"damage_text": RequirementFormatter.percent(payload.get("damage_fraction", 0.0)),
		"repair_target": float(payload.get("repair_target", 1.0)),
		"repair_target_text": RequirementFormatter.percent(payload.get("repair_target", 1.0)),
		"cost": cost,
		"cost_text": RequirementFormatter.money(cost),
		"affordable": sim.treasury.balance >= cost,
		"crew_hours": float(payload.get("crew_hours", 0.0)),
		"crew_type": String(payload.get("crew_type", "")),
		"crew_key": "ui_unit_kind_%s" % String(payload.get("crew_type", "")),
		"customers": int(payload.get("customers", 0)),
		# The job, when a crew is already on it. `progress01` and `eta_gm` are the
		# queue's own — the same two numbers S16 draws, so the panel and the queue
		# can never count down differently.
		"in_flight": job_id >= 0,
		"job_id": job_id,
		"progress01": sim.construction.progress(job_id) if job_id >= 0 else 0.0,
		"eta_gm": sim.construction.eta_game_minutes(job_id) if job_id >= 0 else -1.0,
		"crewed": (job.get("assigned_crews", {}) as Dictionary).size() if job_id >= 0 else 0,
		"blockers": blockers,
		"checklist": rows,
		"blocked_by": RequirementFormatter.first_blocker(rows),
	}


## Send the crew. Returns the sim's own `{ok, reason_code, payload}`;
## `payload.job_id` is the project the panel then follows.
func repair(component_id: String) -> Dictionary:
	if sim == null or component_id == "":
		return CommandQueue.fail(&"E_UNKNOWN_COMPONENT")
	return sim.cmd_repair_grid_component(component_id)


# ===========================================================================
# The grid reading — doc 12 §2.10, D-72
# ===========================================================================

## Supply against demand against what is shed, plus the two counts that say
## WHERE the wall is. Doc 12 §2.10's dashboard row and §2.5's overlay legend
## footer read the same dictionary, because a player who reads one and then the
## other must not be told two different things.
##
## The band counts are the reason this exists rather than a supply bar. Measured
## on every city this wave audited, the pool had headroom (starter 6 %, benchmark
## 56 %) and the transformers were the wall (starter 1 blocker of 1 bound at a
## transformer, benchmark 140 of 140) — so a reading that showed only supply
## against demand told the player to buy the one thing that could not help, which
## is precisely the second-power-station experience this wave was opened on.
func grid_reading() -> Dictionary:
	if sim == null:
		return {"available": false}
	var s := sim.grid.capacity_summary(sim.ambient_c())
	var supply := float(s["supply_kw"])
	var demand := float(s["demand_kw"])
	var shed := float(s["shed_kw"])
	var transformers_hot := int(s["transformers_warning"])
	var feeders_hot := int(s["feeders_warning"])
	# Which half of the grid the player should be looking at, in one token: the
	# pool when the pool is short, the wires when the wires are the constraint,
	# `ok` when neither.
	var wall := "ok"
	if demand > supply or shed > 0.0:
		wall = "supply"
	elif transformers_hot > 0 or feeders_hot > 0:
		wall = "wires"
	return {
		"available": true,
		"supply_kw": supply,
		"supply_text": RequirementFormatter.power(supply),
		"demand_kw": demand,
		"demand_text": RequirementFormatter.power(demand),
		"headroom_kw": float(s["headroom_kw"]),
		"headroom_text": RequirementFormatter.power(s["headroom_kw"]),
		"load_ratio": float(s["load_ratio"]),
		"shed_kw": shed,
		"shed_text": RequirementFormatter.power(shed),
		"shed_feeders": int(s["shed_feeders"]),
		"transformers": int(s["transformers"]),
		"transformers_warning": transformers_hot,
		"transformers_critical": int(s["transformers_critical"]),
		"feeders": int(s["feeders"]),
		"feeders_warning": feeders_hot,
		"feeders_critical": int(s["feeders_critical"]),
		"wall": wall,
		"wall_key": "ui_power_wall_%s" % wall,
		"state": _reading_state(demand, supply, shed, s),
	}


static func _reading_state(demand: float, supply: float, shed: float,
		s: Dictionary) -> StringName:
	if shed > 0.0 or demand > supply or int(s["transformers_critical"]) > 0 \
			or int(s["feeders_critical"]) > 0:
		return HudModel.STATE_CRITICAL
	if int(s["transformers_warning"]) > 0 or int(s["feeders_warning"]) > 0 \
			or demand > PowerGrid.OVERLAY_WARNING_R * supply:
		return HudModel.STATE_WARNING
	return HudModel.STATE_NORMAL
