extends SimTest
## Doc 12 §2.17, played rather than unit-tested: the whole eleven-step tutorial
## driven **through the real UI models over a real `CitySim`**, one step at a
## time, asserting after every one that the step machine actually moved.
##
## `tests/test_ui_onboarding.gd` already proves each advance condition in
## isolation, with hand-written observations. This file proves the seam: that
## the observations the shipped screens *emit while a player uses them* are the
## observations the table waits for. Nothing here feeds `OnboardingModel`
## directly except the per-frame `tick` (which is `OnboardingFlow._process`, and
## `_process` does not run inside a headless test) and the camera sample (which
## is the one line `game/main.gd._process` owns). Every other observation is
## produced by pressing a real control:
##
##     welcome            CoachMark's GOT IT button
##     look_around        a real CameraState, sampled the way main.gd samples it
##     open_build         BuildSheet.open()          → sheet_toggled
##     place_house        the house card → move_ghost → PLACE → cmd_place_building
##     unserved_wall      the same card over tutorial_lot_a → the E_UNSERVED preflight
##     place_transformer  the transformer card → PLACE → cmd_place_grid_component
##     blackout           the step's own on_enter action, honoured by the shell
##     open_drawer        IncidentDrawer.open()      → drawer_toggled
##     dispatch           the drawer's ASSIGN → the unit picker's row → cmd_dispatch_unit
##     relight            the sim's own incident_resolved, off SimEventBus
##     payoff             GOT IT again
##
## The wiring below is `game/main.gd`'s `_wire_build_ui` / `_wire_ui_screens`
## seam, reproduced with no shortcuts: if the shell's contract with `ui/` drifts,
## this file stops compiling or stops advancing.
##
## The city is asserted at the end, not just the step machine: the transformer
## the player placed exists, the failed one is closed and then repaired, its
## customers relight, and the tutorial's finished flag survives the UI-state
## round trip (doc 12 §3.2 `ui.onboarding`).

const SEED := 1337
## The eleven ids of `data/ui.json.onboarding.steps`, in order. Asserted against
## the file so a renumbering breaks here rather than silently skipping a beat.
## Wave 9 appends a twelfth: doc 09 §2.14's handoff. The tutorial used to end at
## `payoff` and leave the player in a running city with nothing to aim at;
## `next_goals` points at the goals chip on the way out.
const STEP_IDS: Array[String] = [
	"welcome", "look_around", "open_build", "place_house", "unserved_wall",
	"place_transformer", "blackout", "open_drawer", "dispatch", "relight", "payoff",
	"next_goals",
]
## `blackout`'s `on_enter.delay_s` is 6 real seconds; the flow accumulates it out
## of `tick` observations, so the test feeds them in 0.1 s slices like a 10 Hz
## frame would rather than one fat 6 s jump.
const TICK_S := 0.1
const TICK_SLICES := 70
## Game-minutes of sim allowed while waiting for one event. The scripted arc
## resolves in ~62 game-minutes measured (see the window test below), so 240 is
## four times the headroom and still under a second of wall clock.
const MAX_WAIT_MINUTES := 240
const TILE_M := 8.0


# ===========================================================================
# Rig — game/main.gd's seam, with a real sim on one end and the real scene on
# the other
# ===========================================================================

class Rig extends RefCounted:
	var sim: CitySim
	var root: UIRoot
	var controller: BuildController
	var camera: CameraState
	var cfg: UIConfig
	var lot_a := Vector2i.ZERO
	var lot_b := Vector2i.ZERO
	var incident_id := 0
	var dispatch_results: Array[Dictionary] = []
	var actions: Array[StringName] = []
	var trace: Array[String] = []

	## `game/main.gd._on_ui_dispatch`, verbatim.
	func on_dispatch(unit_id: int, incident: int) -> void:
		var r := sim.cmd_dispatch_unit(unit_id, incident)
		dispatch_results.append(r)
		root.report_dispatch_result(unit_id, bool(r["ok"]))

	## `game/main.gd._on_coach_action`, minus the camera move (there is no
	## CameraRig here) — the two the tutorial actually needs are the incident and
	## the director hold.
	func on_coach_action(action: StringName, payload: Dictionary) -> void:
		actions.append(action)
		match action:
			&"focus_camera":
				var tile: Vector2i = sim.loader.resolve_tag(
						str(payload.get("tag", "")))["tile_global"]
				camera.set_focus(Vector3(tile.x * 8.0, 0.0, tile.y * 8.0))
			&"trigger_tutorial_incident":
				var inc := sim.trigger_tutorial_transformer_failure()
				if inc != null:
					incident_id = inc.id
			&"suppress_director":
				sim.suppress_director(float(payload.get("seconds", 300.0)) * 60.0)
			&"release_director":
				sim.release_director()

	func step_id() -> String:
		return str(root.onboarding.model.current().get("id", ""))

	## One game-minute of city, pumped into the UI exactly where main.gd pumps it:
	## the event batch to `feed_events` (alerts, log, drawer, coach) and the
	## incident snapshot to `refresh_incidents` (the drawer's rows and clock).
	func pump(minutes: int = 1) -> void:
		for i in maxi(1, minutes):
			sim.advance_hours(1.0 / 60.0)
			root.set_sim_clock(sim.clock.minute_of_day(), sim.clock.day_index())
			root.feed_events(sim.bus.drain())
			root.refresh_incidents(sim.incidents.snapshot(), sim.incidents.now_h)

	## `OnboardingFlow._process` — the only observation a headless mount cannot
	## get for free, because nothing calls `_process` inside a test.
	func tick(seconds: float) -> void:
		root.onboarding.feed({"kind": OnboardingModel.OBS_TICK, "dt": seconds})

	## The unit rows the picker asks for: `game/main.gd._dispatchable_units`.
	func dispatchable_units(incident: int) -> Array:
		var inc: Incident = sim.incidents.incident(incident)
		if inc == null:
			return []
		var primary := String(sim.incidents.catalog.type_row(inc.type, inc.subtype)
				.get("primary_role", ""))
		var out: Array = []
		for uid: int in sim.incidents.fleet.unit_ids():
			var u: Vehicle = sim.incidents.fleet.unit(uid)
			var eta: float = sim.incidents.fleet.eta_h(u, inc.tile)
			out.append({
				"id": u.id, "dept": u.department, "kind": u.type, "state": u.status,
				"eta_gs": -1.0 if is_inf(eta) else eta * 3600.0,
				"eligible": u.is_dispatchable_now(),
				"required": u.has_capability_for(primary),
				"incident_id": u.incident_id,
				"frees_in_gs": -1.0,
			})
		return out


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _rig() -> Rig:
	var rig := Rig.new()
	rig.sim = CitySim.boot_from_files(SEED)
	rig.cfg = UIConfig.load_from_files()
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	rig.root = packed.instantiate()
	rig.root.apply_content_scale = false
	_tree().root.add_child(rig.root)
	rig.root.initialize()

	# --- main.gd._wire_build_ui
	rig.controller = BuildController.new(rig.sim, RequirementFormatter.new(rig.cfg))
	rig.root.build_sheet.setup(rig.cfg, rig.controller)

	# --- main.gd._wire_ui_screens (the parts with a sim behind them)
	rig.camera = CameraState.load_from_files()
	rig.camera.set_focus(Vector3(56 * TILE_M, 0.0, 56 * TILE_M))
	rig.camera.set_zoom_t(0.55)
	rig.root.set_unit_provider(rig.dispatchable_units)
	rig.root.dispatch_requested.connect(rig.on_dispatch)
	rig.root.onboarding_action.connect(rig.on_coach_action)
	rig.root.set_onboarding_world_resolver(func(_tag: String) -> Variant: return null)
	rig.lot_a = rig.sim.loader.resolve_tag("tutorial_lot_a")["tile_global"]
	rig.lot_b = rig.sim.loader.resolve_tag("tutorial_lot_b")["tile_global"]
	rig.root.start_onboarding({"tutorial_lot_a": rig.lot_a, "tutorial_lot_b": rig.lot_b})
	return rig


func _drop(rig: Rig) -> void:
	_tree().root.remove_child(rig.root)
	rig.root.free()


static func _ground(tile: Vector2i) -> Vector3:
	return Vector3(tile.x * TILE_M + TILE_M * 0.5, 0.0, tile.y * TILE_M + TILE_M * 0.5)


# ===========================================================================
# The eleven steps
# ===========================================================================

func test_the_table_is_the_eleven_steps_this_file_plays() -> void:
	var model := OnboardingModel.load_from_files()
	assert_eq(model.step_count(), STEP_IDS.size(),
			"data/ui.json.onboarding.steps still has %d rows" % STEP_IDS.size())
	assert_eq(model.step_ids(), STEP_IDS, "in the order this test drives them")


func test_full_tutorial_through_the_real_ui() -> void:
	var rig := _rig()
	assert_true(rig.sim.boot_errors.is_empty(),
			"the starter city boots clean: %s" % str(rig.sim.boot_errors))
	assert_true(rig.root.onboarding_active(), "the tutorial is up on a fresh city")
	assert_eq(rig.step_id(), "welcome", "and it starts at step 1")
	assert_true(rig.actions.has(&"suppress_director"),
			"§2.17's global guarantee: the director is held for the whole flow")

	# --- 1. welcome ---------------------------------------------------------
	# The card's GOT IT, pressed on the real button the CoachMark built.
	var ack := rig.root.onboarding.mark().ack_button()
	assert_ne(ack, null, "the card step renders an acknowledge button")
	ack.pressed.emit()
	_expect(rig, "look_around", "GOT IT advanced step 1")

	# --- 2. look_around -----------------------------------------------------
	# main.gd samples CameraState every frame; two samples 400 m apart with a
	# zoom change is the doc's "both verbs" completion.
	rig.root.feed_onboarding({"kind": OnboardingModel.OBS_CAMERA,
			"focus": rig.camera.focus, "zoom_t": rig.camera.zoom_t})
	rig.camera.set_focus(Vector3(rig.lot_b.x * TILE_M, 0.0, rig.lot_b.y * TILE_M))
	rig.camera.set_zoom_t(0.35)
	rig.root.feed_onboarding({"kind": OnboardingModel.OBS_CAMERA,
			"focus": rig.camera.focus, "zoom_t": rig.camera.zoom_t})
	_expect(rig, "open_build", "a real pan + zoom advanced step 2")

	# --- 3. open_build ------------------------------------------------------
	assert_false(rig.root.build_sheet.is_open(), "the sheet is shut before the tap")
	rig.root.build_sheet.open()
	_expect(rig, "place_house", "the sheet's own sheet_toggled advanced step 3")

	# --- 4. place_house -----------------------------------------------------
	var treasury_before := rig.sim.treasury.balance
	var buildings_before := rig.sim.buildings.size()
	_press_card(rig, "house")
	assert_true(rig.controller.is_placing(), "the card tap entered placement mode")
	rig.root.build_sheet.move_ghost(_ground(rig.lot_b))
	assert_eq(rig.controller.origin, rig.lot_b, "the ghost is on tutorial_lot_b")
	assert_eq(str(rig.controller.verdict().get("verdict", "")), "valid",
			"the served lot preflights clean")
	rig.root.build_sheet.confirm_placement()
	_expect(rig, "unserved_wall", "the committed place_building advanced step 4")
	assert_eq(rig.sim.buildings.size(), buildings_before + 1,
			"the city really grew a house")
	assert_true(rig.sim.treasury.balance < treasury_before,
			"and the treasury really paid for it")

	# --- 5. unserved_wall ---------------------------------------------------
	# The wall is a VERDICT, not a refused command: the PLACE button is disabled
	# before the player can press it (§2.17).
	rig.root.build_sheet.open()
	_press_card(rig, "house")
	rig.root.build_sheet.move_ghost(_ground(rig.lot_a))
	assert_eq(str(rig.controller.verdict().get("code", "")), "E_UNSERVED",
			"tutorial_lot_a has no transformer reaching it")
	assert_false(rig.controller.can_confirm(), "so PLACE is refused, not charged")
	_expect(rig, "place_transformer", "the E_UNSERVED preflight advanced step 5")
	assert_true(rig.actions.has(&"focus_camera"),
			"the step's on_enter focus reached the shell")

	# --- 6. place_transformer ----------------------------------------------
	# The step's on_enter already asked the root to open the GRID tab; the
	# player cancels the house they could not place and buys the answer.
	assert_true(rig.root.build_sheet.is_open(), "the coach opened the sheet for us")
	assert_eq(rig.root.build_sheet.active_category(), BuildController.CATEGORY_INFRASTRUCTURE,
			"on the GRID tab, per the step's on_enter action")
	rig.root.build_sheet.cancel_placement()
	var components_before := rig.sim.grid.component_ids().size()
	_press_card(rig, "transformer")
	assert_true(rig.controller.is_placing_component(), "placing a grid component")
	rig.root.build_sheet.move_ghost(_ground(rig.lot_a + Vector2i(-1, 0)))
	assert_eq(str(rig.controller.verdict().get("verdict", "")), "valid",
			"a transformer next to the lot is placeable")
	rig.root.build_sheet.confirm_placement()
	_expect(rig, "blackout", "the committed place_grid_component advanced step 6")
	assert_eq(rig.sim.grid.component_ids().size(), components_before + 1,
			"the component is on the grid")

	# --- 7. blackout --------------------------------------------------------
	# `on_enter` here carries `delay_s: 6.0`, so the incident is not triggered
	# until six real seconds of coach-mark time have gone by.
	assert_false(rig.actions.has(&"trigger_tutorial_incident"),
			"nothing has cooked yet — the step's action is on a 6 s delay")
	for i in TICK_SLICES:
		rig.tick(TICK_S)
	assert_true(rig.actions.has(&"trigger_tutorial_incident"),
			"after 6 s the shell was asked to fail the tutorial transformer")
	assert_true(rig.incident_id > 0, "and it filed an incident")
	assert_eq(String(rig.sim.grid.component("T-04")["state"]), "OPEN",
			"doc 04 took the transformer out")
	var created := _pump_until(rig, "blackout", "open_drawer")
	assert_true(created, "incident_created reached the coach layer through feed_events")
	assert_eq(rig.step_id(), "open_drawer", "the blackout advanced step 7")

	# --- 8. open_drawer -----------------------------------------------------
	assert_true(rig.root.incident_drawer.count() >= 1,
			"the drawer already lists the incident it is about to be opened for")
	rig.root.incident_drawer.open()
	_expect(rig, "dispatch", "the drawer's own drawer_toggled advanced step 8")

	# --- 9. dispatch --------------------------------------------------------
	# ASSIGN on the row → the unit picker → a unit row → cmd_dispatch_unit.
	var row_button := rig.root.incident_drawer.row_button(rig.incident_id)
	assert_ne(row_button, null, "the incident has a row in the drawer")
	row_button.pressed.emit()   # expand, which is what builds the action bar
	var assign := rig.root.incident_drawer.action_button("Assign", rig.incident_id)
	assert_ne(assign, null, "the expanded row offers ASSIGN")
	assign.pressed.emit()
	assert_true(rig.root.unit_picker.is_open(), "which opened the unit picker")
	var unit_id := _first_eligible_unit(rig)
	assert_true(unit_id > 0, "the picker offers at least one dispatchable unit")
	var unit_button := rig.root.unit_picker.unit_button(unit_id)
	assert_ne(unit_button, null, "with a row to tap")
	unit_button.pressed.emit()
	assert_eq(rig.dispatch_results.size(), 1, "one dispatch reached the sim")
	assert_true(bool(rig.dispatch_results[0]["ok"]),
			"and it was accepted: %s" % str(rig.dispatch_results[0]))
	_expect(rig, "relight", "the accepted cmd_dispatch_unit advanced step 9")
	var responder: Vehicle = rig.sim.incidents.fleet.unit(unit_id)
	assert_true(responder.manual_lock, "a hand-picked unit is locked to the job")

	# --- 10. relight --------------------------------------------------------
	var resolved := _pump_until(rig, "relight", "payoff")
	assert_true(resolved, "the repair finished and incident_resolved reached the UI")
	assert_eq(rig.step_id(), "payoff", "which advanced step 10")
	assert_eq(String(rig.sim.grid.component("T-04")["state"]), "OK",
			"doc 04 closed the component the crew repaired")

	# --- 11. payoff ---------------------------------------------------------
	var payoff_ack := rig.root.onboarding.mark().ack_button()
	payoff_ack.pressed.emit()
	assert_true(rig.root.onboarding_active(),
			"the payoff hands off rather than ending — doc 09 §2.14")
	assert_eq(rig.step_id(), "next_goals", "and it hands off to the goals chip")

	# --- 12. next_goals -----------------------------------------------------
	# Either half of the step's `any_of` finishes it; this is the one the player
	# who understood takes.
	rig.root.open_goals()
	assert_false(rig.root.onboarding_active(), "the flow is over")
	assert_true(rig.root.onboarding.is_finished(), "and finished, not skipped")
	assert_false(rig.root.onboarding.model.skipped, "the player played it")
	assert_eq(rig.root.onboarding.model.completed_ids(), STEP_IDS,
			"all twelve steps completed, in order")
	assert_true(rig.actions.has(&"release_director"),
			"and the director hold was lifted on the way out")

	# --- the city the player is left with -----------------------------------
	var relit := _pump_until_lit(rig, "T-04")
	assert_true(relit, "every T-04 customer is lit again")
	var state := rig.root.capture_ui_state()
	var coach: Dictionary = state["onboarding"]
	assert_true(bool(coach["finished"]), "doc 12 §3.2's ui.onboarding.finished is set")
	assert_false(bool(coach["active"]))
	assert_eq((coach["completed"] as Array).size(), STEP_IDS.size())
	_drop(rig)


## §2.17: "it never shows again once done". The finished flag has to survive the
## `ui` block's round trip, and a restored-finished machine must refuse to start.
func test_finished_flag_survives_the_ui_state_round_trip() -> void:
	var rig := _rig()
	rig.root.onboarding.model.skip()   # the cheap way to a finished machine
	var state := rig.root.capture_ui_state()
	var text := JSON.stringify(state)
	var reloaded: Variant = JSON.parse_string(text)
	assert_true(reloaded is Dictionary, "the ui block is plain JSON")

	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var other: UIRoot = packed.instantiate()
	other.apply_content_scale = false
	_tree().root.add_child(other)
	other.initialize()
	other.restore_ui_state(reloaded as Dictionary)
	assert_true(other.onboarding.is_finished(), "the resumed shell knows it is done")
	assert_false(other.start_onboarding({"tutorial_lot_a": rig.lot_a,
			"tutorial_lot_b": rig.lot_b}), "and refuses to play it again")
	assert_false(other.onboarding_active())
	other.reset_onboarding()
	assert_true(other.start_onboarding({"tutorial_lot_a": rig.lot_a,
			"tutorial_lot_b": rig.lot_b}), "Settings ▸ Replay tutorial still works")
	_tree().root.remove_child(other)
	other.free()
	_drop(rig)


## A mid-flow save: doc 12 §3.2 says the resumed shell comes back on the step it
## left. Driven the same way as the full run, then round-tripped at step 5.
func test_mid_flow_save_resumes_on_the_same_step() -> void:
	var rig := _rig()
	rig.root.onboarding.mark().ack_button().pressed.emit()
	rig.root.feed_onboarding({"kind": OnboardingModel.OBS_CAMERA,
			"focus": Vector3.ZERO, "zoom_t": 0.55})
	rig.root.feed_onboarding({"kind": OnboardingModel.OBS_CAMERA,
			"focus": Vector3(400.0, 0.0, 0.0), "zoom_t": 0.2})
	rig.root.build_sheet.open()
	assert_eq(rig.step_id(), "place_house", "parked mid-flow")

	var state := rig.root.capture_ui_state()
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	var other: UIRoot = packed.instantiate()
	other.apply_content_scale = false
	_tree().root.add_child(other)
	other.initialize()
	other.restore_ui_state(state)
	assert_true(other.onboarding_active(), "the tutorial resumed")
	assert_eq(str(other.onboarding.model.current().get("id", "")), "place_house",
			"on the step it was left on")
	assert_eq(other.onboarding.model.completed_ids(),
			["welcome", "look_around", "open_build"] as Array[String],
			"with the three completed beats remembered")
	_tree().root.remove_child(other)
	other.free()
	_drop(rig)


## The measurement behind the `dispatch` step's timing risk: with no player
## input at all, the auto-dispatcher takes the scripted job and resolves it. The
## window between the blackout and that resolution is the whole time the player
## has to reach step 9 — and step 9 has no autohelp and no `any_of` fallback, so
## the number matters. Recorded here so a change to doc 06's dispatch cadence or
## repair rate shows up as a failing measurement rather than a dead tutorial.
func test_scripted_incident_leaves_a_usable_dispatch_window() -> void:
	var sim := CitySim.boot_from_files(SEED)
	sim.advance_hours(0.25)
	var inc := sim.trigger_tutorial_transformer_failure()
	assert_ne(inc, null, "the scripted failure filed an incident")
	sim.bus.drain()
	var auto_assign_minute := -1
	var resolve_minute := -1
	for minute in MAX_WAIT_MINUTES:
		sim.advance_hours(1.0 / 60.0)
		for event: Variant in sim.bus.drain():
			var data: Dictionary = event
			var kind := String(data.get("type", ""))
			if kind == "unit_dispatched" and auto_assign_minute < 0 \
					and int(data.get("incident_id", 0)) == inc.id:
				auto_assign_minute = minute + 1
			elif kind == "incident_resolved" and resolve_minute < 0 \
					and int(data.get("incident_id", 0)) == inc.id:
				resolve_minute = minute + 1
		if resolve_minute > 0:
			break
	assert_true(auto_assign_minute > 0,
			"doc 06's auto-dispatcher takes the job on its own")
	assert_true(resolve_minute > 0, "and finishes it")
	print("[tutorial-window] auto-assign at +%d game-min, resolved at +%d game-min"
			% [auto_assign_minute, resolve_minute])
	# One real second is one game-minute at 1x (SimHost.GAME_MS_PER_REAL_MS), so
	# this is also the player's window in real seconds. 30 is the floor a coach
	# mark plus a two-tap dispatch can plausibly fit inside.
	assert_true(resolve_minute >= 30,
			"the player has at least 30 game-minutes to reach ASSIGN, got %d"
					% resolve_minute)


# ===========================================================================
# Helpers
# ===========================================================================

## Asserts the machine moved off whatever it was on and onto `expected`.
func _expect(rig: Rig, expected: String, message: String) -> void:
	assert_eq(rig.step_id(), expected, message)


## Presses the real card button, selecting its tab first the way a player would.
func _press_card(rig: Rig, card_id: String) -> void:
	var sheet := rig.root.build_sheet
	if not sheet.is_open():
		sheet.open()
	for card: Dictionary in rig.controller.cards():
		if str(card["id"]) == card_id:
			sheet.select_category(str(card["category"]))
			break
	var button := sheet.card_button(card_id)
	assert_ne(button, null, "the sheet carries a %s card" % card_id)
	if button != null:
		button.pressed.emit()


## Advances the city a game-minute at a time, pumping every batch into the UI,
## until the step machine leaves `from`. Returns false if it never did.
func _pump_until(rig: Rig, from: String, to: String) -> bool:
	for minute in MAX_WAIT_MINUTES:
		rig.pump()
		if rig.step_id() == to:
			return true
		if rig.step_id() != from:
			return false
	return false


func _pump_until_lit(rig: Rig, component_id: String) -> bool:
	var customers: Array[String] = []
	var ids: Array = rig.sim.buildings.keys()
	ids.sort()
	for id: Variant in ids:
		if rig.sim.grid.attachment_of(String(id)) == component_id:
			customers.append(String(id))
	if customers.is_empty():
		return false
	for minute in MAX_WAIT_MINUTES:
		rig.pump()
		var all_lit := true
		for id: String in customers:
			if not rig.sim.grid.is_powered(id):
				all_lit = false
				break
		if all_lit:
			return true
	return false


## The picker's own ranking, read off its model: the first row it would let a
## player tap.
func _first_eligible_unit(rig: Rig) -> int:
	for row: Dictionary in rig.root.unit_picker.model.eligible_rows():
		return int(row["id"])
	return -1
