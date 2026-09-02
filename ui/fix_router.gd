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
##    `{sheet, arm, binds_at, world_pos}`. `FIX_POWER`'s answer is not a place to
##    go (the player is already looking at the building); it is the panel's power
##    strip, armed to quote. `binds_at` is the component the headroom binds at —
##    which is what the id on this kind actually is — and `world_pos` is where
##    that wall stands, for a surface that wants to show it. `sim_id` and `quote`
##    appear only when the caller supplied the BUILDING explicitly, because the
##    component id is not one and must never be mistaken for one.
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

## The surface `FIX_POWER` arms. `ui/building_panel.gd` performs this in place
## today (`_power_fix_armed = _sim_id`); naming it here is what lets the
## placement bar and the alerts centre reach the same behaviour without each
## re-deriving it (PA-23's consumer).
const SHEET_BUILDING_PANEL := &"building_panel"
const ARM_POWER_FIX := &"power_fix"

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
			# Same reason, one row down: the panel arms its own power strip and
			# the strip spends. The router names the surface and the arm.
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
			var armed := {"action": ACTION_SHEET, "reason": &"", "kind": kind, "id": id,
					"sheet": SHEET_BUILDING_PANEL, "arm": ARM_POWER_FIX,
					"binds_at": id, "world_pos": wall}
			var subject := str(fix_target.get("sim_id", ""))
			if subject != "" and sim.buildings.has(subject):
				armed["sim_id"] = subject
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
	return _none(kind, id, REASON_UNKNOWN_KIND)


## `true` when routing this target will actually do something — what a panel
## should gate its button on. `building_panel.gd:414-416` draws `Fix this →` on
## `kind != FIX_NONE` alone, which is why the `E_AVENUE` row rendered a button
## over an empty id; the land panel already required an id, which is why it was
## safe (PA-05 evidence).
static func can_route(sim: CitySim, fix_target: Dictionary) -> bool:
	return String(route(sim, fix_target, false)["action"]) != String(ACTION_NONE)


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
	return &""


static func _none(kind: StringName, id: String, reason: StringName) -> Dictionary:
	return {"action": ACTION_NONE, "reason": reason, "kind": kind, "id": id}
