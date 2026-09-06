class_name FixRouter
extends RefCounted
## **`Fix this →`, resolved.** One `fix_target` in, one ACTION out — and never a
## silent nothing.
##
## Doc 12 §2.7 calls the `Fix this →` row *"the single most important teaching
## device in the game"*. At the Wave-17 fork it was **dead on two of the building
## panel's seven checklist rows** (PA-05), and dead in the worst possible way:
## `game/main.gd::_on_fix_requested` opened with `if id == "" … return` and
## closed with `if b == null: return`, so a row whose target was a transformer
## (`POWER_CAPACITY` → `sim.grid.attachment_of()` → `T-01`) and a row whose target
## was empty (`E_AVENUE`, whose params carried no `fix_target_id` at all) both
## produced a button that depressed and did nothing. No camera move, no toast, no
## haptic — and no test could see it, because the dispatcher lived in the one
## file the suite never loads (PA-38).
##
## This class is that dispatcher, headless. `sim` is injected, every method is
## static, nothing here touches the scene tree or the camera. It **decides**; the
## shell **performs**. `game/main.gd::_on_fix_requested` is now three lines.
##
## ### The three action shapes
##
##  * `ACTION_FOCUS` — *go and look at this*: `{world_pos: Vector3}`. Every fix
##    whose answer is a place.
##  * `ACTION_SHEET` — *open this surface, already armed*:
##    `{sheet, arm, binds_at, world_pos}`. **Wave 25 moved where it points.**
##    Until this wave the only sheet a fix row could name was S5 with its power
##    strip armed — the best answer available while the transformer had no
##    surface, and a poor one: the row said *"T-02 is full"* and offered a
##    purchase with no picture of the thing being purchased. `FIX_POWER` and a
##    transformer's own `FIX_COMPONENT` both answer `SHEET_TRANSFORMER_PANEL`
##    now, because the wall became a PLACE (doc 04 §2.15.3). `binds_at` is the
##    component — which is what the id on these kinds actually is — and
##    `world_pos` is where that wall stands, for a surface that wants to show
##    it. `sim_id` and `quote` appear only when the caller supplied the BUILDING
##    explicitly, because the component id is not one and must never be mistaken
##    for one.
##  * `ACTION_VERB` — *run this, and here is what it will cost*:
##    `{verb, args, quote}`. `FIX_REPAIR` buys a repair. The quote is the sim's
##    own `preview: true` return, which is a pure read — it stops before the
##    first mutation in both `cmd_repair_building` and `cmd_fix_power_capacity` —
##    so routing a fix target never moves a hash.
##
## And one refusal shape: `ACTION_NONE` with a `reason`. A router that cannot
## answer says which of the FIVE ways it failed, so a gate can tell "this code has
## no fix" (`no_fix`) apart from "this code has a fix and the id was empty"
## (`empty_id`) — the second is a bug in the caller's params and the first is not.

const ACTION_NONE := &"none"
const ACTION_FOCUS := &"focus"
const ACTION_SHEET := &"open_sheet"
const ACTION_VERB := &"verb"

## `ACTION_NONE` reasons. Every one of these is a DIFFERENT bug (or non-bug), and
## keeping them apart is what lets `test_fix_router.gd` assert that no
## `CODE_TABLE` row falls through silently.
const REASON_NO_FIX := &"no_fix"              ## FIX_NONE: the row has no remedy
const REASON_EMPTY_ID := &"empty_id"          ## a fixable kind with no target
const REASON_UNKNOWN_KIND := &"unknown_kind"  ## a FIX_* this router has not met
const REASON_UNRESOLVED := &"unresolved"      ## the id named nothing on the map
const REASON_NO_SIM := &"no_sim"              ## called before boot

## Wave 25's S18 (doc 12 §2.25). The surface a `POWER_CAPACITY` row and a grid
## component's own row both open now — the wall is a PLACE, and this is it.
##
## **It replaced `SHEET_BUILDING_PANEL`, which is gone rather than kept.** That
## name had exactly one producer, the `FIX_POWER` arm below, and this wave moved
## it; no shell and no test ever matched on the string. A sheet name a router
## can no longer answer is a door in the wall of a room nobody can enter, which
## is the defect class this wave is named after — so it is not left behind as
## decoration. The in-place path it described is unaffected and is still the
## right one: `building_panel.gd::_on_fix_pressed` intercepts `FIX_POWER` before
## the router ever sees it (A91-D-54), and now raises `power_row_opened`.
const SHEET_TRANSFORMER_PANEL := &"transformer_panel"
## Wave 28's S19 (doc 12 D-124). The surface an `E_WATER_HEADROOM` row opens when
## the zone is short of SUPPLY — the panel that names which stage of doc 05
## §2.5's chain binds it, which is the difference between the purchase that helps
## and the 118 pumps doc 92 §67.4 measured buying nothing.
const SHEET_WATER_PANEL := &"water_panel"
## S19 opened with nothing armed: `WaterPanelModel.focus_of()` decides which verb
## it lands on, because it knows whether the node is down and whether the zone is
## leaking, and this does not.
const ARM_WATER := &"water"
## Which of S18's two purchases the row was about. Kept on the `FIX_POWER` answer
## because a surface with NO in-place path has to be able to tell them apart.
const ARM_POWER_FIX := &"power_fix"
## S18 opened with nothing armed: the panel's own `focus_of()` decides which verb
## it lands on, because it knows whether the unit is dead and this does not.
const ARM_TRANSFORMER := &"transformer"

## Kinds whose fix is a PURCHASE rather than a place. Both are answered by the
## building panel in place; both are listed here so the router is total over
## `RequirementFormatter`'s kinds rather than total over the ones the shell
## happens to receive today.
const VERB_REPAIR := &"cmd_repair_building"


## The whole contract. Returns
##
##     {action, reason, kind, id, world_pos, sheet, arm, sim_id, verb, args, quote}
##
## with only the keys its action uses, plus `action`, `reason`, `kind` and `id`
## on every answer. Never returns an empty dictionary and never returns `null`.
##
## `with_quote` is `false` for callers that only want to know WHERE to go — the
## shell's camera path does — so the sim preview is not run on a tap that will
## not show a price.
static func route(sim: CitySim, fix_target: Dictionary,
		with_quote: bool = true) -> Dictionary:
	var kind := StringName(str(fix_target.get("kind", RequirementFormatter.FIX_NONE)))
	var id := str(fix_target.get("id", ""))
	if kind == RequirementFormatter.FIX_NONE:
		return _none(kind, id, REASON_NO_FIX)
	if sim == null:
		return _none(kind, id, REASON_NO_SIM)

	match kind:
		RequirementFormatter.FIX_REPAIR:
			# Not a place: the target is the building the player already has
			# open, and focusing the camera on it moves nothing (A91-D-54).
			if id == "":
				return _none(kind, id, REASON_EMPTY_ID)
			if not sim.buildings.has(id):
				return _none(kind, id, REASON_UNRESOLVED)
			var answer := {"action": ACTION_VERB, "reason": &"", "kind": kind, "id": id,
					"verb": VERB_REPAIR, "args": {"sim_id": id}}
			if with_quote:
				answer["quote"] = sim.cmd_repair_building(id, true)
			return answer
		RequirementFormatter.FIX_POWER:
			# Not a place either, and for a DIFFERENT reason from FIX_REPAIR's:
			# the building panel intercepts this kind before the router sees it
			# and spends in place (A91-D-54). What follows is the answer for
			# every OTHER surface — the ones that have no strip to arm.
			if id == "":
				return _none(kind, id, REASON_EMPTY_ID)
			# **`FIX_POWER`'s id is NOT the building.** `build_controller.gd`
			# fills it from `sim.grid.attachment_of(sim_id)` — the component the
			# headroom BINDS AT (`T-02`), which is the whole of PA-05's first
			# half. Treating it as a building id is the bug this row exists to
			# kill, and a `sim.buildings.has(id)` guard here reproduces it: the
			# real checklist sweep failed 33 rows on exactly that, which is what
			# `test_no_real_checklist_row_falls_through_silently` is for.
			#
			# So: resolve the id in whatever namespace it belongs to, carry it as
			# `binds_at` with the wall's position, and take the BUILDING only
			# from an explicit `sim_id` a caller chose to add — never by
			# reinterpreting the component id as one.
			var wall: Variant = WorldLocator.locate_any(sim, id)
			if wall == null:
				return _none(kind, id, REASON_UNRESOLVED)
			# **Wave 25 (report 98 §68 RR-207): the sheet is S18, not S5.** The id
			# on this kind is the COMPONENT the headroom binds at, and until this
			# wave the only thing a surface could do with it was arm a confirm
			# strip on a panel that was describing something else. The wall is a
			# PLACE now, so the router sends the player to it. `arm` still says
			# `power_fix`, because the building panel performs that verb IN PLACE
			# (A91-D-54) and a surface with no in-place path has to know which of
			# the two purchases the row was about.
			var armed := {"action": ACTION_SHEET, "reason": &"", "kind": kind, "id": id,
					"sheet": SHEET_TRANSFORMER_PANEL, "arm": ARM_POWER_FIX,
					"binds_at": id, "world_pos": wall}
			var subject := str(fix_target.get("sim_id", ""))
			if subject != "" and sim.buildings.has(subject):
				armed["sim_id"] = subject
				# **…and WHICH RUNG the row is actually asking for** (Wave 28,
				# doc 93 §BC-3). `cmd_fix_power_capacity` quotes ONE purchase —
				# the next rung up — and returns `clears: false` when that rung
				# is not enough, which is honest and unactionable: the player is
				# told the purchase will not work and not what will. `rung_needed`
				# names the rung that carries the load, so the row can say
				# "L2 → this needs L4" and the player can decide to buy the ladder
				# rather than tap once and be refused again. `needs_rung` 0 is
				# `E_NEEDS_TRANSFORMER`'s own case — no rung under THIS pad
				# carries it — and is passed through as 0 rather than clamped,
				# because `needs_second` (buy a parallel unit) and
				# `no_rung_carries` (nothing on the ladder feeds this at all) are
				# two different sentences and the row has to be able to tell them
				# apart.
				#
				# **Outside `with_quote`, deliberately** (Wave 28 fix pass). It
				# used to sit inside it, and BOTH production callers —
				# `ui/ui_root.gd` and `game/main.gd` — pass `false`, so the one
				# number this row exists to add reached no surface at all: doc 12
				# D-123(c) sold it as the third of three and it was billed to a
				# test and a tool. It is a pure read of the grid — no preview, no
				# placement search — so it costs a camera move nothing, which is
				# the reason `with_quote` guards `cmd_fix_power_capacity` and not
				# this.
				armed["needs"] = PowerActions.rung_needed_for_next_level(sim, subject)
				if with_quote:
					armed["quote"] = sim.cmd_fix_power_capacity(subject, true)
			return armed
		RequirementFormatter.FIX_BUILDING, RequirementFormatter.FIX_BLOCK, \
				RequirementFormatter.FIX_TILE, RequirementFormatter.FIX_DISTRICT, \
				RequirementFormatter.FIX_ROAD_SEGMENT:
			if id == "":
				return _none(kind, id, REASON_EMPTY_ID)
			var where: Variant = WorldLocator.locate(sim, _locator_kind(kind), id)
			if where == null:
				return _none(kind, id, REASON_UNRESOLVED)
			return {"action": ACTION_FOCUS, "reason": &"", "kind": kind, "id": id,
					"world_pos": where}
		RequirementFormatter.FIX_COMPONENT:
			# **Wave 25.** A grid component's fix stopped being *"go and look at
			# it"* the moment it became a thing with a panel: a transformer opens
			# S18, where its condition, its customers, its ladder and its crew
			# are. **Wave 28 closes the sentence this paragraph used to end on** —
			# *"a doc-05 pump still has no surface of its own and keeps the camera
			# move"* — because it has one now (S19, doc 12 D-124). A water
			# refusal that lands the camera on a pump without saying which stage
			# of §2.5's chain binds is the refusal doc 92 §67.4 measured costing
			# $5.5M in pumps that bought nothing. A feeder still keeps the camera
			# move, and the branch is still decided by what the SIM says the id is
			# rather than by how the id is spelled.
			if id == "":
				return _none(kind, id, REASON_EMPTY_ID)
			var at: Variant = WorldLocator.locate(sim, WorldLocator.KIND_COMPONENT, id)
			if at == null:
				return _none(kind, id, REASON_UNRESOLVED)
			if FixRouter._opens_transformer_panel(sim, id):
				return {"action": ACTION_SHEET, "reason": &"", "kind": kind, "id": id,
						"sheet": SHEET_TRANSFORMER_PANEL, "arm": ARM_TRANSFORMER,
						"binds_at": id, "world_pos": at}
			if FixRouter._opens_water_panel(sim, id):
				return {"action": ACTION_SHEET, "reason": &"", "kind": kind, "id": id,
						"sheet": SHEET_WATER_PANEL, "arm": ARM_WATER,
						"binds_at": id, "world_pos": at}
			return {"action": ACTION_FOCUS, "reason": &"", "kind": kind, "id": id,
					"world_pos": at}
	return _none(kind, id, REASON_UNKNOWN_KIND)


## `true` when routing this target will actually do something — what a panel
## should gate its button on. `building_panel.gd:414-416` draws `Fix this →` on
## `kind != FIX_NONE` alone, which is why the `E_AVENUE` row rendered a button
## over an empty id; the land panel already required an id, which is why it was
## safe (PA-05 evidence).
static func can_route(sim: CitySim, fix_target: Dictionary) -> bool:
	return String(route(sim, fix_target, false)["action"]) != String(ACTION_NONE)


## Is this id a component S18 can open? **Asked of the GRID, never of the id's
## spelling** — `T-06` and a doc-05 pump are both `FIX_COMPONENT` ids and only
## one of them has a panel, and a rule that read the prefix would send a player
## to a blank sheet the first time a component kind is renamed. The authority is
## `BuildController.PICKABLE_COMPONENT_KINDS`, which is the same list the tap
## radius answers `PICK_COMPONENT` for, so the router and the map cannot come to
## different conclusions about what is a thing you can open.
static func _opens_transformer_panel(sim: CitySim, id: String) -> bool:
	if sim == null or sim.grid == null or not sim.grid.has_component(id):
		return false
	return BuildController.PICKABLE_COMPONENT_KINDS.has(
			StringName(String(sim.grid.component(id)["kind"])))


## Is this id a doc-05 node S19 can open? **Asked of the WATER SYSTEM, never of
## the id's spelling** — `_opens_transformer_panel`'s rule one document over, and
## the authority is the same array the tap radius answers `PICK_COMPONENT` for
## (`BuildController.PICKABLE_WATER_VARIANTS`), so the router and the map cannot
## come to different conclusions about what is a thing you can open. A `junction`
## answers false and keeps the camera move, which is right: §2.1 says a junction
## is where mains meet, not a component.
static func _opens_water_panel(sim: CitySim, id: String) -> bool:
	if sim == null or sim.water == null:
		return false
	var node: WaterNode = sim.water.node(id)
	return node != null and BuildController.PICKABLE_WATER_VARIANTS.has(node.variant)


## The `WorldLocator` kind a `RequirementFormatter.FIX_*` resolves through. They
## are spelled the same on purpose — this exists so the mapping is stated once
## and a new `FIX_*` fails loudly here rather than quietly in a match arm.
static func _locator_kind(fix_kind: StringName) -> StringName:
	match fix_kind:
		RequirementFormatter.FIX_BUILDING:
			return WorldLocator.KIND_BUILDING
		RequirementFormatter.FIX_BLOCK:
			return WorldLocator.KIND_BLOCK
		RequirementFormatter.FIX_TILE:
			return WorldLocator.KIND_TILE
		RequirementFormatter.FIX_DISTRICT:
			return WorldLocator.KIND_DISTRICT
		RequirementFormatter.FIX_ROAD_SEGMENT:
			return WorldLocator.KIND_ROAD_SEGMENT
		RequirementFormatter.FIX_COMPONENT:
			# Declared in `RequirementFormatter`'s table by the power wave and
			# used by Lane L's E_WATER_HEADROOM row; this mapping was the piece
			# no single lane owned, and its absence made every component row
			# answer `unknown_kind` (Wave 18 merge, report 98 §57).
			return WorldLocator.KIND_COMPONENT
	return &""


static func _none(kind: StringName, id: String, reason: StringName) -> Dictionary:
	return {"action": ACTION_NONE, "reason": reason, "kind": kind, "id": id}
