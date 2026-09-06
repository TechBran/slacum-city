class_name TransformerPanelModel
extends RefCounted
## The headless half of **S18 — the transformer panel** (doc 12 §2.25, Wave 25;
## report 98 §68 RR-207, doc 93 §AY2).
##
## The player, 2026-09-04: *"if you click on the transformer, you can repair it —
## which means calling your crews there … and all of the buildings that connect
## to that transformer and the power-feed situation, and the ability to upgrade
## the transformer — all should be there on the transformer. You click the
## transformer and all of that information pops up just like a building does."*
##
## Same contract `LandPanelModel` has with S4: **this class reads the sim and
## computes every value, and `ui/transformer_panel.gd` binds what it returns.**
## It owns no threshold, no price and no copy (constitution §3, doc 12 §1).
## Every number is `PowerActions`' — which is to say the sim's own
## `preview = true` — every band is `PowerGrid.distress_band`'s, and every
## sentence is a `data/strings.en.json` KEY that the view resolves.
##
## ## The one thing this file decides
##
## **Which verb the panel opens on.** A panel that always opened on the same row
## would be wrong at the only moment that matters: a player taps a transformer
## because it is smoking or dead, and the thing they came for is the crew. So
## `focus_of()` answers `repair` when the unit is FAILED or a crew is already on
## it, and `upgrade` otherwise — and the view scrolls that verb into place and
## draws it first. That is a presentation decision about ORDER, not about
## content: every verb is on the panel in every state, and every one of them is
## quoted whether or not it can be pressed (doc 12 §2.7 — a button that hides its
## price while the player is broke teaches nothing about how much to save).
##
## ## What it deliberately does not do
##
## It does not decide whether a transformer is in trouble. `PowerGrid` does
## (`distress_band`), and `game/render/power_infra_model.gd` reads the same
## function to decide whether the pad smokes — so the word on the panel and the
## look of the cabinet in the world can never be two different opinions.

## The verb the panel opens on. Also the anchor names the view scrolls to.
const FOCUS_REPAIR := &"repair"
const FOCUS_UPGRADE := &"upgrade"

## Doc 12 §2.5's four data states, as the panel's own token for a customer row's
## power light. `STATE_OFFLINE` is a building the grid is not delivering to right
## now — shed, dark or behind a failed unit — and it is the row the player is
## looking for when they open this panel during an outage.
const CUSTOMER_STATE_LIT := HudModel.STATE_NORMAL
const CUSTOMER_STATE_DARK := HudModel.STATE_CRITICAL

## `data/ui.json`'s block for this screen. Presentation only.
const SECTION := "transformer"
## How many customer rows are drawn before the list is capped and a
## "+N more" line takes their place. Measured, not picked: doc 92 §65.1 finds a
## grown city's widest transformer feeding **17** buildings, and 17 rows at 48 dp
## is 816 dp of list on a 915 dp display — so the whole panel would be one list.
## The cap's own default is here and `data/ui.json.transformer.max_customer_rows`
## overrides it, because it is a layout number and not a rule of the grid.
const MAX_CUSTOMER_ROWS_DEFAULT := 8

var sim: CitySim
var power: PowerActions
var formatter: RequirementFormatter
var config: UIConfig
var tile_m := BuildController.TILE_M_DEFAULT


func _init(p_sim: CitySim = null, p_power: PowerActions = null,
		p_config: UIConfig = null, p_tile_m: float = -1.0) -> void:
	sim = p_sim
	config = p_config if p_config != null else UIConfig.load_from_files()
	formatter = RequirementFormatter.new(config)
	power = p_power if p_power != null else PowerActions.new(p_sim, formatter)
	if p_tile_m > 0.0:
		tile_m = p_tile_m


## `data/ui.json.transformer`, or `{}`.
func section() -> Dictionary:
	return config.section(SECTION) if config != null else {}


func max_customer_rows() -> int:
	return maxi(1, int(UIConfig.get_num(section(), "max_customer_rows",
			MAX_CUSTOMER_ROWS_DEFAULT)))


## Is there a transformer here for the panel to open on? The pick already
## answered this, but a panel that is refreshed after a demolition has to be able
## to find out that the thing it was describing is gone.
func opens_for(component_id: String) -> bool:
	return sim != null and sim.grid != null and component_id != "" \
			and sim.grid.has_component(component_id) \
			and BuildController.PICKABLE_COMPONENT_KINDS.has(
					StringName(String(sim.grid.component(component_id)["kind"])))


## The whole panel, as plain data. `exists` false is the only reason the view
## draws nothing — a transformer that has been demolished out from under an open
## panel, which is reachable (the REMOVE row is on this very panel).
func view(component_id: String) -> Dictionary:
	if not opens_for(component_id):
		return {"exists": false, "component": component_id}
	var block := power.transformer_block(component_id)
	if not bool(block.get("available", false)):
		return {"exists": false, "component": component_id}
	var repair: Dictionary = block.get("repair", {})
	var customers: Array = block.get("customers", [])
	var cap := max_customer_rows()
	var shown: Array[Dictionary] = []
	var dark := 0
	var total_kw := 0.0
	for entry: Variant in customers:
		var row: Dictionary = entry
		total_kw += float(row.get("demand_kw", 0.0))
		if not bool(row.get("powered", false)):
			dark += 1
		if shown.size() < cap:
			shown.append(_customer(row))
	var out := block.duplicate()
	out["exists"] = true
	out["focus"] = focus_of(block)
	out["title_key"] = String(block["name_key"])
	out["title_fallback"] = component_id
	out["level_pips"] = BuildingPanel.level_pips(int(block["level"]),
			int(block["max_level"]))
	# The meter the panel draws: peak load against the capacity AT TODAY'S
	# AMBIENT. `value01` is clamped for the bar; `load_ratio` above it is not,
	# because a transformer at 140 % has to be able to say 140 %.
	out["meter01"] = clampf(float(block["load_ratio"]), 0.0, 1.0)
	out["meter_state"] = StringName(String(block["band_state"]))
	out["customer_rows"] = shown
	out["customers_hidden"] = maxi(0, customers.size() - shown.size())
	out["customers_dark"] = dark
	out["customer_demand_kw"] = total_kw
	out["customer_demand_text"] = RequirementFormatter.power(total_kw)
	out["repair"] = repair
	out["world_pos"] = world_pos_of(component_id)
	return out


## Which verb the panel opens on — see the header. A crew already rolling wins
## over a dead unit, because "when does it come back?" is the question a player
## who has already paid is asking.
func focus_of(block: Dictionary) -> StringName:
	var repair: Dictionary = block.get("repair", {})
	if bool(repair.get("in_flight", false)):
		return FOCUS_REPAIR
	if bool(block.get("failed", false)) and bool(repair.get("available", false)):
		return FOCUS_REPAIR
	return FOCUS_UPGRADE


## Where the camera looks when a customer row is tapped, and where the pad is for
## the shell's selection highlight. `WorldLocator` owns the arithmetic — the
## panel does not multiply a tile by a metre anywhere.
func world_pos_of(component_id: String) -> Variant:
	return WorldLocator.locate(sim, WorldLocator.KIND_COMPONENT, component_id)


func customer_world_pos(sim_id: String) -> Variant:
	return WorldLocator.locate(sim, WorldLocator.KIND_BUILDING, sim_id)


## One customer row, with the two things the view needs that `PowerActions` does
## not decide: which data state its power light is, and the string key for the
## shed class the player put it in.
func _customer(row: Dictionary) -> Dictionary:
	var out := row.duplicate()
	out["state"] = CUSTOMER_STATE_LIT if bool(row.get("powered", false)) \
			else CUSTOMER_STATE_DARK
	out["power_key"] = "ui_transformer_customer_lit" if bool(row.get("powered", false)) \
			else "ui_transformer_customer_dark"
	return out


# ===========================================================================
# The verbs. Each is one line, and each returns the sim's own answer.
# ===========================================================================

## Send a crew (doc 04 §2.15.2). The panel arms first and calls this on the second
## tap — see `ui/transformer_panel.gd`, and doc 12 §2.7's "never spend on one
## tap", which is the same contract the demolish row and the fix strip obey.
func repair(component_id: String) -> Dictionary:
	return power.repair(component_id)


func upgrade(component_id: String) -> Dictionary:
	return power.upgrade(component_id)


func demolish(component_id: String) -> Dictionary:
	return power.demolish(component_id)


## The one-row summary the BUILDING panel draws in place of Wave 17's whole POWER
## section (doc 12 D-115, RR-208). Lives here, not in `BuildController`, because
## it is a reading OF A TRANSFORMER shown somewhere else — and putting it here is
## what stops the two surfaces computing the same sentence twice.
##
## `{available, unserved, transformer, ratio, band_state, text_key, args}`.
## `available` is false only when the sim has never heard of the building.
static func building_row(actions: PowerActions, sim_id: String) -> Dictionary:
	if actions == null or actions.sim == null or not actions.sim.buildings.has(sim_id):
		return {"available": false}
	var transformer := String(actions.sim.grid.attachment_of(sim_id))
	if transformer == "":
		# The single most useful thing this row can say, and it is drawn in the
		# critical state rather than hidden behind a tap (doc 93 §AY3).
		return {"available": true, "unserved": true, "transformer": "",
				"text_key": "ui_power_row_unserved", "args": {}, "shed": false,
				"band_state": HudModel.STATE_CRITICAL, "ratio": 0.0}
	var block := actions.transformer_block(transformer)
	# Doc 04 §2.4's rolling blackout, on the panel of a building that is IN one.
	# It is a fact about this building's power right now — not about the
	# transformer, which is working perfectly — so it is the one line besides the
	# row itself that stays on S5 (doc 93 §AY3).
	var feeder := String(actions.sim.grid.component(transformer).get("parent", ""))
	# **Which rung the NEXT level needs** (Wave 28, doc 12 D-123, doc 93 §BC-3).
	# The row already named the transformer and its ratio; what it could not say
	# is the one thing the player is deciding — whether the pad they are on can
	# carry the upgrade they are looking at, and if not, which rung can. The
	# numbers are `PowerActions.rung_needed`'s, which is the sim's own gate walk.
	var next: Dictionary = actions.next_level(sim_id)
	var upgrade := {}
	var second := bool(next.get("needs_second", false))
	var no_rung := bool(next.get("no_rung_carries", false))
	if bool(next.get("needs_bigger", false)) or second or no_rung:
		# **Which rung the sentence is about.** When a bigger unit under this
		# building carries it, that is `needs_rung`. When none does, the answer is
		# doc 04 §2.9's PARALLEL transformer and the rung that matters is
		# `alone_rung` — what a pad of its own would have to be — because that is
		# the thing `cmd_fix_power_capacity` will actually place and charge for.
		var rung: int = int(next.get("alone_rung", 0)) if second \
				else int(next.get("needs_rung", 0))
		upgrade = {
			"to_level": int(next.get("to_level", 0)),
			"needs_rung": rung,
			"host_level": int(next.get("host_level", 0)),
			"needs_capacity_text": RequirementFormatter.power(
					PowerActions.rung_capacity(rung)),
			# Three sentences, three states, and only ONE of them is a wall:
			# `no_rung_carries` means no transformer in the game carries this
			# building at any price; `needs_second` means this pad cannot be
			# re-rated to carry it but a second one beside it can, which is a
			# purchase and not a refusal; anything else is one rung up.
			"text_key": "ui_power_row_no_rung" if no_rung \
					else ("ui_power_row_needs_second" if second \
					else "ui_power_row_needs_rung"),
		}
	return {
		"available": true,
		"unserved": false,
		"transformer": transformer,
		"needs_upgrade": upgrade,
		"shed": feeder != "" and actions.sim.grid.shed_feeders.has(feeder),
		"ratio": float(block.get("load_ratio", 0.0)),
		"band_state": StringName(String(block.get("band_state", HudModel.STATE_NORMAL))),
		"text_key": "ui_power_row",
		"args": {"id": transformer,
				"pct": RequirementFormatter.percent(block.get("load_ratio", 0.0)),
				"kind": "ui_power_kind_%s" % String(block.get("kind", "transformer"))},
	}
