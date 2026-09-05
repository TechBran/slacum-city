class_name WaterPanelModel
extends RefCounted
## The headless half of **S19 — the water panel** (doc 12 D-124, Wave 28).
##
## The player, 2026-09-05, on the device: *"The water pumping situation. Our
## water capacity — we need to be able to, one, create a water source; two, put
## pumps on it to increase our volume. My volume is starting to get low. We've
## got to make sure the pump stations, the whole water infrastructure, is
## tight."*
##
## Doc 05 §6.1's Wave-11 ruling was that there should be **no** water-node panel,
## on the argument that a node's only verb was an upgrade and the doc-02 shell it
## sits on already had a panel. That argument was about a verb LIST, and this
## wave changed the list: a node now answers *which stage of §2.5's chain binds
## this zone*, *what the zone supplies against what it is asked for*, *which of
## its mains are broken and what stopping the leak costs*, and *whether another
## pump here would move anything at all*. None of those is a fact about a
## building. Doc 04's transformer was given exactly this panel in Wave 25 for
## exactly this reason (doc 93 §AY2), and this is that ruling one utility over —
## doc 93 §BD1.
##
## Same contract `TransformerPanelModel` has with S18: **this class reads the sim
## and computes every value, and `ui/water_panel.gd` binds what it returns.** It
## owns no threshold, no price and no copy (constitution §3, doc 12 §1). Every
## capacity is `WaterSystem.supply_chain()`'s, every price is the owning
## command's own `preview = true`, every band is doc 05 §5.8's, and every
## sentence is a `data/strings.en.json` KEY the view resolves.
##
## ## The one thing this file decides
##
## **Which verb the panel opens on.** A player taps a pump because something is
## wrong, and the thing they came for is almost never the ladder: `focus_of()`
## answers `repair` when the node is down or a crew is already rolling, `mains`
## when the zone is leaking through a broken main (the case that pinned the
## player's own city — doc 92 §69.1), and `upgrade` otherwise. That is a decision
## about ORDER, not content: every verb is on the panel in every state and every
## one is quoted whether or not it can be pressed (doc 12 §2.7).

## The verb the panel opens on. Also the anchor names the view scrolls to.
const FOCUS_REPAIR := &"repair"
const FOCUS_MAINS := &"mains"
const FOCUS_UPGRADE := &"upgrade"

## `data/ui.json`'s block for this screen. Presentation only.
const SECTION := "water"
## How many customer rows are drawn before the list is capped and a "+N more"
## line takes their place. **Measured, not picked**: doc 92 §69.1 finds the
## player's own zone serving **89** buildings, so an uncapped list would be
## eleven screens of panel. Eight rows at 48 dp is 384 dp, which leaves the
## chain and the verbs above the fold on a 915 dp display — the same budget
## S18's cap was fitted to, and the same override key.
const MAX_CUSTOMER_ROWS_DEFAULT := 8
## …and the same for broken mains. A zone with more than three open breaks is
## already telling the player everything they need to know.
const MAX_BREAK_ROWS_DEFAULT := 4

var sim: CitySim
var water: WaterActions
var formatter: RequirementFormatter
var config: UIConfig
var tile_m := BuildController.TILE_M_DEFAULT


func _init(p_sim: CitySim = null, p_water: WaterActions = null,
		p_config: UIConfig = null, p_tile_m: float = -1.0) -> void:
	sim = p_sim
	config = p_config if p_config != null else UIConfig.load_from_files()
	formatter = RequirementFormatter.new(config)
	water = p_water if p_water != null else WaterActions.new(p_sim, formatter)
	if p_tile_m > 0.0:
		tile_m = p_tile_m


## `data/ui.json.water`, or `{}`.
func section() -> Dictionary:
	return config.section(SECTION) if config != null else {}


func max_customer_rows() -> int:
	return maxi(1, int(UIConfig.get_num(section(), "max_customer_rows",
			MAX_CUSTOMER_ROWS_DEFAULT)))


func max_break_rows() -> int:
	return maxi(1, int(UIConfig.get_num(section(), "max_break_rows",
			MAX_BREAK_ROWS_DEFAULT)))


## Is there a doc-05 node here for the panel to open on? The pick already
## answered this, but a panel refreshed after a REMOVE has to be able to find
## out that its subject is gone.
func opens_for(node_id: String) -> bool:
	return water != null and water.opens_for(node_id)


## The whole panel, as plain data. `exists` false is the only reason the view
## draws nothing — a node demolished out from under an open panel, which is
## reachable, because the REMOVE row is on this very panel.
func view(node_id: String) -> Dictionary:
	if not opens_for(node_id):
		return {"exists": false, "node": node_id}
	var block := water.node_block(node_id)
	if not bool(block.get("available", false)):
		return {"exists": false, "node": node_id}
	var zone: Dictionary = block.get("zone", {})
	var customers: Array = block.get("customers", [])
	var breaks: Array = block.get("breaks", [])
	var shown: Array[Dictionary] = []
	var under_gate := 0
	for entry: Variant in customers:
		var row: Dictionary = entry
		if bool(row.get("under_gate", false)):
			under_gate += 1
		if shown.size() < max_customer_rows():
			shown.append(row)
	var break_rows: Array[Dictionary] = []
	var leaking := 0.0
	for entry2: Variant in breaks:
		var row2: Dictionary = entry2
		leaking += float(row2.get("leak_m3h", 0.0))
		if break_rows.size() < max_break_rows():
			break_rows.append(row2)
	var out := block.duplicate()
	out["exists"] = true
	out["focus"] = focus_of(block)
	out["title_key"] = String(block["name_key"])
	out["title_fallback"] = String(block["name_fallback"])
	out["level_pips"] = BuildingPanel.level_pips(int(block["level"]),
			int(block["max_level"]))
	# The meter is the ZONE's utilization, not this node's flow: doc 92 §67.5's
	# argument is that a reading on pressure is green until the zone is already
	# short, and the number that moves before the wall is demand / supply.
	out["meter01"] = float(zone.get("meter01", 0.0)) if bool(zone.get("exists", false)) else 0.0
	out["meter_state"] = zone.get("band_state", HudModel.STATE_CRITICAL)
	out["customer_rows"] = shown
	out["customers_total"] = customers.size()
	out["customers_hidden"] = maxi(0, customers.size() - shown.size())
	out["customers_under_gate"] = under_gate
	out["break_rows"] = break_rows
	out["breaks_total"] = breaks.size()
	out["breaks_hidden"] = maxi(0, breaks.size() - break_rows.size())
	out["leaking_m3h"] = leaking
	out["leaking_text"] = RequirementFormatter.water_m3h(leaking)
	# **The sentence the whole panel exists to say.** Which stage binds, what it
	# would take to move it, and what binds after that — because a player who
	# buys the wrong stage buys nothing (doc 92 §67.4: 118 pumps, $5.5M, and the
	# zone's supply did not move).
	out["advice"] = advice_of(block)
	out["world_pos"] = world_pos_of(node_id)
	return out


## See the header. A crew already rolling wins over a dead node, because "when
## does it come back?" is the question a player who has already paid is asking;
## and a zone bleeding through a broken main wins over the ladder, because
## buying capacity to replace water that is running into the ground is the one
## purchase that is certainly wrong.
func focus_of(block: Dictionary) -> StringName:
	var repair: Dictionary = block.get("repair", {})
	if bool(repair.get("in_flight", false)) or bool(repair.get("down", false)):
		return FOCUS_REPAIR
	if not (block.get("breaks", []) as Array).is_empty():
		return FOCUS_MAINS
	return FOCUS_UPGRADE


## The advice line: `{key, args, stage, node, actionable}`. Copy is a string KEY
## and every number in `args` is doc 05's own — this method picks WHICH sentence,
## never what it says.
func advice_of(block: Dictionary) -> Dictionary:
	var zone: Dictionary = block.get("zone", {})
	if not bool(zone.get("exists", false)):
		return {"key": "ui_water_advice_no_zone", "args": {}, "stage": "none",
				"node": "", "actionable": false}
	if bool(zone.get("dead", false)):
		return {"key": "ui_water_advice_dead", "args": {}, "stage": "none",
				"node": "", "actionable": false}
	# A leak first, always: it is demand the city is paying for and nobody is
	# drinking, and it is the one line the player's own save needed.
	var breaks: Array = block.get("breaks", [])
	if not breaks.is_empty():
		var worst: Dictionary = breaks[0]
		return {"key": "ui_water_advice_leak", "stage": "mains",
				"node": String(worst.get("edge", "")), "actionable": true,
				"args": {"count": str(breaks.size()),
						"leak": RequirementFormatter.water_m3h(worst.get("leak_m3h", 0.0)),
						"cost": String((worst.get("repair", {}) as Dictionary)
								.get("cost_text", ""))}}
	var stage := String(block.get("binding", "none"))
	var chain_row := _chain_row(block, stage)
	if stage == "mains":
		return {"key": "ui_water_advice_mains", "stage": stage, "node": "",
				"actionable": true,
				"args": {"m3h": String(chain_row.get("text", "")),
						"zone": String(zone.get("key", ""))}}
	if stage == "none":
		return {"key": "ui_water_advice_none", "args": {}, "stage": stage,
				"node": "", "actionable": false}
	var node_id := String(chain_row.get("node", ""))
	if node_id == "":
		return {"key": "ui_water_advice_place", "stage": stage, "node": "",
				"actionable": true,
				"args": {"stage": "ui_water_stage_%s" % stage}}
	# **…and what would bind after it** (doc 12 §2.26). §2.5's supply is a MIN of
	# four terms, so raising the narrowest one moves the zone exactly as far as
	# the second narrowest and not one m³ further. A panel that says "raise the
	# intake" and stops has sold a purchase whose ceiling the player cannot see —
	# which is doc 92 §67.4's $5.5M of pumps, told the other way round.
	# `next_binding` has been on `WaterSystem.supply_chain` since this wave
	# opened; this is its reader.
	var next_stage := String(block.get("next_binding", "none"))
	var args := {"stage": "ui_water_stage_%s" % stage,
			"m3h": String(chain_row.get("text", "")), "at": node_id,
			"next": "ui_water_stage_%s" % next_stage,
			"next_m3h": String(block.get("next_binding_text", ""))}
	return {"key": "ui_water_advice_binds_next" if next_stage != "none" \
					else "ui_water_advice_binds",
			"stage": stage, "node": node_id, "next_stage": next_stage,
			"actionable": true, "args": args}


static func _chain_row(block: Dictionary, stage: String) -> Dictionary:
	for entry: Variant in (block.get("chain", []) as Array):
		if String((entry as Dictionary)["stage"]) == stage:
			return entry
	return {}


## Where the camera looks when the panel opens, and where the node is for the
## shell's selection highlight. `WorldLocator` owns the arithmetic.
func world_pos_of(node_id: String) -> Variant:
	if sim == null:
		return null
	var node: WaterNode = sim.water.nodes.get(node_id)
	if node == null:
		return null
	return WorldLocator.locate(sim, WorldLocator.KIND_TILE, node.tile)


func customer_world_pos(sim_id: String) -> Variant:
	return WorldLocator.locate(sim, WorldLocator.KIND_BUILDING, sim_id)


# ===========================================================================
# The verbs. Each is one line, and each returns the sim's own answer.
# ===========================================================================

## Send a crew to this node — or, from a break row, to that main. The panel arms
## first and calls this on the second tap (doc 12 §2.7's "never spend on one
## tap", the same contract S18's crew row and the fix strip obey).
func repair(asset_id: String) -> Dictionary:
	return water.repair(asset_id)


func upgrade(node_id: String) -> Dictionary:
	return water.upgrade_node(node_id)


func remove(node_id: String) -> Dictionary:
	return water.remove(node_id)


func isolate(edge_id: String) -> Dictionary:
	return water.isolate(edge_id)


func restore(edge_id: String) -> Dictionary:
	return water.restore(edge_id)


## The one-row summary the BUILDING panel draws for a building's WATER, beside
## the POWER row S18 gave it (doc 12 D-125). Lives here, not in
## `BuildController`, for `TransformerPanelModel.building_row`'s reason: it is a
## reading OF A ZONE shown somewhere else, and putting it here is what stops two
## surfaces computing the same sentence twice.
##
## `{available, unserved, zone, pressure, band_state, text_key, args, node,
##   main_distance_tiles, under_gate}`.
static func building_row(actions: WaterActions, sim_id: String) -> Dictionary:
	if actions == null or actions.sim == null or not actions.sim.buildings.has(sim_id):
		return {"available": false}
	var sim_ref: CitySim = actions.sim
	var tile: Vector2i = sim_ref.water.demand.access_tile(sim_id)
	var zone: PressureZone = sim_ref.water.zone_at(tile)
	if zone == null:
		return {"available": true, "unserved": true, "zone": "", "node": "",
				"text_key": "ui_water_row_unserved", "args": {},
				"band_state": HudModel.STATE_CRITICAL, "pressure": 0.0,
				"main_distance_tiles": -1, "under_gate": true}
	var pressure := sim_ref.water.pressure_at(tile)
	var gate := sim_ref.water.data.effect("upgrade_min_pressure", 0.55)
	var normal := sim_ref.water.data.effect("happiness_pressure_ref", 0.60)
	var chain := sim_ref.water.supply_chain_of(zone)
	# **Which of the two arms is short, said in the row.** A zone at pressure
	# 1.00 refusing a building at 0.50 is a DISTANCE problem and no amount of
	# supply answers it (doc 92 §67.8); a zone short of supply is answered by
	# the stage that binds. The row says which, and the fix strip routes on it.
	var distance := sim_ref.water.topology.distance_at_tile(tile)
	var far := pressure < gate and zone.pressure >= gate
	return {
		"available": true, "unserved": false,
		"zone": zone.zone_key,
		"pressure": pressure,
		"zone_pressure": zone.pressure,
		"headroom_m3h": zone.headroom_m3h(),
		"binding": String(chain.get("binding", "none")),
		"node": String((chain["binding_ids"] as Array)[0]) \
				if not (chain.get("binding_ids", []) as Array).is_empty() else "",
		"main_distance_tiles": distance,
		"too_far": far,
		"under_gate": pressure < gate,
		"band_state": HudModel.STATE_NORMAL if pressure >= normal \
				else (HudModel.STATE_WARNING if pressure >= gate
						else HudModel.STATE_CRITICAL),
		"text_key": "ui_water_row_far" if far else "ui_water_row",
		"args": {"zone": zone.zone_key,
				"pct": RequirementFormatter.percent(pressure),
				"tiles": str(distance),
				"binding": "ui_water_stage_%s" % String(chain.get("binding", "none"))},
	}
