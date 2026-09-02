extends SimTest
## THE EVENT MATRIX, as a gate (doc 91 §18, doc 93's event ruling, open q3).
##
## The audit counted 121 event type names coming out of `sim/` and crossed them
## against every consumer in the tree, and the number that mattered was **43
## consumed by nothing at all**. Counting them once found `flood_level_changed`
## (A91-D-26) and would have found the next one a month late. This file is that
## count, run on every commit, with a rule attached.
##
## ── the rule (doc 93, adopted here) ───────────────────────────────────────
## *Every event whose payload describes a PLAYER-VISIBLE state change must have
## a consumer or a written exemption. Everything else carries a one-line
## classification and no consumer is expected.*
##
## And the sentence that makes the rule cheap enough to keep: **a RENDERER is a
## consumer.** A flooded street that the player can see does not also need a
## line in the log; the 40 mm nuisance band has `game/render/flood_view.gd` and
## nothing else, on purpose. Narrate what changes what the player can DO; draw
## what only changes how the city looks.
##
## ── what this test actually asserts ───────────────────────────────────────
##   1. Every type `sim/` emits is either consumed somewhere, or is named in
##      `REGISTER` below with a classification. **Zero unexplained rows.**
##   2. Every `REGISTER` row still names a type `sim/` really emits — so the
##      register cannot quietly rot into a list of events that no longer exist.
##   3. Every classification is one of `CLASSIFICATIONS`, and every one carries
##      a reason after the colon. "bookkeeping" on its own is not an argument.
##   4. **Every type the two data routers name is emitted.** This is doc 91
##      §18.1's clean direction, which doc 11 §7.2 test 27 already held for doc
##      04's slice, extended to `data/ui.json.event_log.events` and
##      `data/notifications.json.bindings` whole — the "cheap next step" §18.2
##      ranks. It is the RR-1 failure mode: copy wired to an event nobody sends.
##
## ── what it deliberately does NOT claim ───────────────────────────────────
## The emit scan is a regex over source and **fails open**: the day someone
## writes `bus.emit(kind_variable, …)` this test will not see that name and will
## not complain. §18.3 says so and it is still true. What the scan does hold is
## the direction that matters — a name it CAN see and that nothing consumes has
## to be explained here before the suite goes green — and assertion 4, which
## fails CLOSED and is the one that catches a router wired to nothing.
##
## The consumer scan is deliberately generous: any string literal of the right
## shape in `game/` or `ui/`, plus the two routers, plus doc 09's goal system.
## A name mentioned in a live file and not actually matched on would read as
## "wired" here. That is the right way round for a gate whose job is to stop
## dead wires, not to prove liveness — a false "wired" is a missing test, a
## false "dead" is a stalled commit.

const SIM_DIR := "res://sim"
const CONSUMER_DIRS: Array[String] = ["res://game", "res://ui"]
## Doc 09's curriculum is a sim-side consumer of sim events, and the only one.
const SIM_CONSUMERS: Array[String] = ["res://sim/progression/goal_system.gd"]
const MEASUREMENT_DIRS: Array[String] = ["res://tests", "res://tools"]

## The vocabulary. Six words, and a row has to pick one and then say why.
const CLASSIFICATIONS: Array[String] = [
	# A sibling event, a snapshot or a poll that IS wired carries the same
	# player-visible change. The row names which.
	"covered",
	# The player's own command produced it and the screen that issued it
	# already knows. Announcing it would be the game repeating the player.
	"player_initiated",
	# Internal accounting or pacing. Nothing the player can see changed.
	"bookkeeping",
	# A doc forbids surfacing it. The row names the doc.
	"invisible_by_design",
	# A measurement seam: real, useful, and read by tests or tools only.
	"measurement",
	# Emitted only into a command result that its caller discards, so it never
	# reaches the bus at all.
	"unreachable",
	# The scan matched a `"type":` field that is not an event payload.
	"not_an_event",
	# A player-visible event whose consumer is COMMITTED and NAMED but has not
	# landed in this tree yet — a sim branch that ships the emit ahead of the
	# renderer branch that draws it. Deliberately the narrowest word here, and
	# the only one with a mechanical expiry: `test_the_register_names_a_consumer_
	# that_is_no_longer_needed` fails the suite the moment the consumer appears,
	# so the row deletes itself rather than aging into a permanent excuse. A row
	# using it MUST name the wave and the file that will consume it — asserted
	# below, so "somebody will get to it" cannot be written here.
	"awaiting_consumer",
]

## THE REGISTER. One row per event `sim/` emits that nothing consumes, and the
## reason it is allowed to stay that way. Adding an emit without adding a
## consumer or a row here fails this suite, which is the whole mechanism.
const REGISTER := {
	# ── doc 04, the grid ────────────────────────────────────────────────────
	"CascadeStep":
		"covered: doc 04's cascade trace. Every step of a cascade the player can"
		+ " see is a component tripping, and each of those is a"
		+ " PowerComponentTripped and (where a block goes out) a"
		+ " BlockDarkChanged, both wired.",
	"SurgeAbsorbed":
		"bookkeeping: an arrester did its job and nothing happened. The absence"
		+ " of an outage is not an event.",
	"TieTransferBlocked":
		"covered: what the player sees is the block that STAYED dark, which is"
		+ " BlockDarkChanged.",
	"TieTransferSuccess":
		"covered: what the player sees is the block coming back, which is"
		+ " BlockDarkChanged(false) and PowerRestored.",
	"grid_node_rerated":
		"player_initiated: it fires only when an upgrade the player bought"
		+ " re-rates a node, and PowerInfraView re-polls the grid's topology on"
		+ " its own timer regardless.",
	"power_restored_by_repair":
		"covered: the relight is BlockDarkChanged(false) / PowerRestored, which"
		+ " is what the blackout ceremony rides.",
	"power_capacity_fixed":
		"player_initiated: the one-tap POWER_CAPACITY fix reports itself twice"
		+ " over — the confirm strip that spent the money redraws with the"
		+ " blocker gone, and the purchase it made emits its OWN event"
		+ " (grid_component_upgraded, grid_component_placed or"
		+ " grid_feeder_routed) which carries the world change. This one is the"
		+ " receipt for the plan, and it is here for the stats counter and the"
		+ " tests (Wave 17, doc 12 §2.7 D-71).",

	# ── doc 09, the land and its development ───────────────────────────────
	"block_road_access_changed":
		"covered: the visible change is the ROAD, and road_graph_changed /"
		+ " block_roads_stamped both rebuild the street surface.",
	"block_surveyed":
		"covered: the land panel reads the block's development_state on the"
		+ " HUD cadence, and block_ready announces the end of the sequence.",
	"development_phase_started":
		"covered: same land-panel poll; block_ready is the announced end.",
	"development_phase_completed":
		"covered: same land-panel poll; block_ready is the announced end.",
	# `development_phase_charged` used to be exempt here — *"bookkeeping: money
	# moving. Spend belongs in the budget sheet's ledger, not in the alerts
	# feed."* 99-PA PA-83 measured what that reasoning cost: **six debits per
	# block, $1.2K–$21K a phase, 14–15 per 21 game-days, and the budget sheet's
	# ledger does not itemise them either**, so the exemption was covering a
	# dollar that reached no surface at all. It has a doc 12 log row now (report
	# 98 §53.4) and its exemption is gone, which is exactly what this gate's
	# `..._no_longer_needed` half exists to force.
	"development_paused":
		"player_initiated: cmd_pause_development. The panel that paused it is"
		+ " showing that it is paused.",
	"utility_corridor_extended":
		"covered: a development phase effect; block_ready is the announced end.",

	# ── doc 02, buildings ──────────────────────────────────────────────────
	"building_ignited":
		"unreachable: Building.ignite() returns it inside a command result and"
		+ " its only caller (sim/incidents/city_incident_world.gd) reads `ok`"
		+ " and drops `events`. The fire the player sees is incident_created.",
	"building_priority_changed":
		"player_initiated: the building panel set it.",
	"upgrade_started":
		"covered: CitySim re-emits the same fact as upgrade_started_sim, which"
		+ " the shell turns into a construction site.",

	# ── doc 07, the Director ───────────────────────────────────────────────
	"director_event_scheduled":
		"invisible_by_design: doc 07 §2.6. What the player gets is"
		+ " weather_warning, at the fairness rule's lead time — never the"
		+ " Director's own schedule.",
	"director_event_started":
		"invisible_by_design: doc 07 §2.6. The event's own systems announce"
		+ " themselves (weather_changed, incident_created).",
	"director_event_ended":
		"invisible_by_design: doc 07 §2.6. The event's own systems announce"
		+ " their own ends (incident_resolved, weather_changed, road_reopened).",
	"director_recovery_mode":
		"invisible_by_design: doc 07 §2.6. Telling a player the game has"
		+ " decided to go easy on them is the one thing the Director must never"
		+ " do.",
	"director_suppressed":
		"invisible_by_design: doc 07 §2.6. The fairness gates are felt, never"
		+ " read.",
	"director_scripted_suppression":
		"invisible_by_design: doc 07 §2.6. A scripted suppression window is the"
		+ " Director holding its fire, and a player who is told about it stops"
		+ " believing the ones it does not hold.",
	"storm_incident_downgraded":
		"invisible_by_design: doc 07's fairness clamp on a storm's damage. The"
		+ " incident the player actually gets is announced; the one they were"
		+ " spared is not a thing that happened.",
	"storm_prep_action":
		"player_initiated: the storm prep sheet issued it.",
	"storm_prep_taken":
		"player_initiated: S17 (doc 12 §2.24) issued the command and already"
		+ " knows what it bought — this is the SHELL's copy of the fact, for a"
		+ " toast and a cue, and a screen that announced the button the player"
		+ " just pressed would be the game repeating them (99-PA PA-26).",
	"storm_report_ready":
		"awaiting_consumer: doc 07 §2.7.6's Storm Report, on S12's away-report"
		+ " layout. Wave 18 ships the sim half — the report is built at the"
		+ " storm's resolution with doc 03's ledger total read back, and the"
		+ " Storm Ready reimbursement is paid — and doc 12 D-78's deferral table"
		+ " owes the sheet: `game/main.gd`'s `_on_sim_batch` arm and a"
		+ " `ui/storm_report_sheet.gd` beside `ui/away_report_sheet.gd`.",

	# ── doc 01, the scheduler ──────────────────────────────────────────────
	"event_scheduled":
		"bookkeeping: doc 01's ScheduledEvents plumbing. What a scheduled event"
		+ " DOES has its own events.",
	"event_phase_begin":
		"bookkeeping: doc 01's ScheduledEvents plumbing, and a phase boundary is"
		+ " a timer edge rather than anything the city did.",
	"event_phase_end":
		"bookkeeping: doc 01's ScheduledEvents plumbing, same timer edge from"
		+ " the other side.",
	"event_completed":
		"bookkeeping: doc 01's ScheduledEvents plumbing. The event is off the"
		+ " queue; whatever it did announced itself while it ran.",

	# ── doc 06, incidents and the fleet ────────────────────────────────────
	"fire_spread":
		"covered: the child fire is created with incident_created, which is"
		+ " wired to the drawer, the log and a push.",
	"incident_roster_saturated":
		"invisible_by_design: doc 06 §2.13(b). The ceiling is an ENGINE bound on"
		+ " a cost model, not a city fact — what the player can see is a drawer"
		+ " holding forty open incidents, which the drawer already shows and the"
		+ " alerts feed already narrated one at a time. Announcing the clamp"
		+ " would tell them the simulation stopped trying, which is the one"
		+ " thing it must not say. Emitted on the RISING EDGE only, so a dead"
		+ " city produces one of these and not thousands.",
	"incident_roster_relieved":
		"invisible_by_design: doc 06 §2.13(b), the falling edge of the same"
		+ " latch. The player's evidence that pressure came back is the next"
		+ " incident_created, which is wired.",
	"unit_commissioned":
		"covered: VehicleView takes incidents.vehicle_states() every tick, so"
		+ " the roster syncs idempotently whatever the event says.",
	"unit_decommissioned":
		"covered: the same vehicle_states() snapshot, which is idempotent and"
		+ " therefore cannot miss a retirement.",
	"fleet_station_synced":
		"covered: the same vehicle_states() snapshot. A station gaining units is"
		+ " a roster fact and the roster is re-read every tick.",
	"fleet_station_retired":
		"covered: the same vehicle_states() snapshot; the units simply stop"
		+ " being in it.",
	"policy_changed":
		"player_initiated: the dispatch policy sheet set it.",

	# ── doc 10, roads ──────────────────────────────────────────────────────
	"road_block_stamped":
		"covered: block_roads_stamped is the shell's arm for the same stamp and"
		+ " rebuilds the street.",
	"road_built":
		"covered: road_graph_changed rebuilds the street surface.",
	"road_removed":
		"covered: road_graph_changed rebuilds the street surface, which is the"
		+ " whole of what a removed road looks like.",
	"road_demolished":
		"covered: road_graph_changed rebuilds the street; the refund is the"
		+ " budget sheet's business.",
	"road_upgraded":
		"covered: road_graph_changed repaints the class.",
	"road_upgrade_started":
		"player_initiated: cmd_upgrade_road. The sheet that spent the money is"
		+ " showing the quote it spent it on.",
	"road_job_rejected":
		"player_initiated: the quote path hands the reason straight back to the"
		+ " sheet that asked.",
	"road_closure_opened":
		"covered: closures reach the renderer through"
		+ " RoadNetwork.snapshot.active_closures (the traffic_snapshot event),"
		+ " and the cause-specific road_closed_flood / road_collapsed are what"
		+ " get announced.",
	"road_closure_cleared":
		"covered: same snapshot, and road_reopened is the announced half.",
	"route_ready":
		"bookkeeping: a routing job finished. The visible half is the vehicle"
		+ " that drives it.",
	"route_invalidated":
		"bookkeeping: the router dropped a cached path.",
	"congestion_updated":
		"measurement: the congestion epoch. The overlay repaints off"
		+ " RoadNetwork.snapshot.visible_edges, which carries the band already.",

	# ── doc 03, the treasury ───────────────────────────────────────────────
	"treasury_credited":
		"bookkeeping: sim/city_sim.gd:76 says so out loud — it fires on every"
		+ " incident and every refund, and the treasury readout is the surface.",
	"deferred_liability_accrued":
		"bookkeeping: doc 03's accrual. The liability itself is a line on the"
		+ " budget sheet, which reads the treasury and not the bus.",
	"deferred_liability_cleared":
		"bookkeeping: doc 03's accrual again. A liability coming off the books"
		+ " is a budget-sheet line, not a moment.",
	"progression_milestone":
		"covered: every id ProgressionSystem grants is `city_level_<n>`, and"
		+ " city_level_changed carries the same rung to a toast, the log and a"
		+ " push.",

	# ── doc 05, water ──────────────────────────────────────────────────────
	"water_incident_raised":
		"covered: the specific failure is the story and all of them are now"
		+ " wired — water_main_break, water_freeze_break, water_pump_failed,"
		+ " water_treatment_failed, water_source_failed.",
	"water_main_isolated":
		"player_initiated: cmd_isolate_water_main. Doc 05 §2.12's tactical"
		+ " trade is the player's own, made from the water actions sheet.",
	"water_component_commissioned":
		"covered: the shell building already went up on water_component_placed,"
		+ " and the water overlay polls service factors.",
	"water_component_retired":
		"covered: building_removed takes the mesh with it.",
	"water_component_upgraded":
		"player_initiated: cmd_upgrade_water_component.",

	# ── construction ───────────────────────────────────────────────────────
	"job_started":
		"bookkeeping: the site the player sees is stood up on"
		+ " building_placed_sim / upgrade_started_sim.",
	"job_cancelled":
		"player_initiated: cmd_cancel_job, and the site's disappearance rides"
		+ " building_removed.",
	"construction_job_preempted":
		"bookkeeping: the queue re-ordered itself. Neither site changed state.",

	# ── doc 06 §2.16, the opportunity layer ────────────────────────────────
	# opportunity_spawned / opportunity_expired: consumed by
	# game/render/street_life_view.gd since the marker landed at the Wave-14
	# integration — their awaiting_consumer rows deleted themselves exactly as
	# written. opportunity_collected: goal_system + street_life + ui/street_model.,

	# ── not an event at all ────────────────────────────────────────────────
	"water_works":
		"not_an_event: sim/city_sim.gd builds a STATION roster row"
		+ " {\"type\": \"water_works\"}, which the scan's `\"type\":` arm cannot"
		+ " tell from an event payload. Naming it here is cheaper and more"
		+ " honest than a cleverer regex.",
}


# ===========================================================================
# The scan
# ===========================================================================

## Emit sites take two forms and this has to see both (doc 91 §18's own
## finding): a literal first argument to `bus.emit(…)` / `_emit(…)`, and a
## `{"type": &"…"}` row on a command result that CitySim re-emits generically.
##
## The emit-call arm reads every literal from the call up to the payload dict,
## not just the first — because `_emit(&"water_freeze_break" if main.frozen
## else &"water_main_break", {…})` is a real line in sim/water/water_system.gd,
## and a scan that took the first literal only would have called
## `water_main_break` un-emitted while two routers were wired to it.
func _emitted() -> Dictionary:
	var out: Dictionary = {}
	var emit_call := RegEx.new()
	emit_call.compile("(?:bus\\.emit\\(|_emit\\()")
	var payload_cut := RegEx.new()
	payload_cut.compile(",\\s*\\{")
	var literal := RegEx.new()
	literal.compile("&?\"([a-zA-Z_][A-Za-z0-9_]*)\"")
	var typed := RegEx.new()
	typed.compile("\"type\"\\s*:\\s*&?\"([a-zA-Z_][A-Za-z0-9_]*)\"")
	for path: String in _gd_files(SIM_DIR):
		for line: String in _code_lines(path):
			for m in typed.search_all(line):
				out[m.get_string(1)] = path
			var call := emit_call.search(line)
			if call == null:
				continue
			var head := line.substr(call.get_end())
			var cut := payload_cut.search(head)
			if cut != null:
				head = head.substr(0, cut.get_start())
			for m2 in literal.search_all(head):
				out[m2.get_string(1)] = path
	return out


## Names any live consumer mentions. Generous by design — see the class doc.
func _consumed() -> Dictionary:
	var out: Dictionary = {}
	var literal := RegEx.new()
	literal.compile("&?\"([a-zA-Z_][A-Za-z0-9_]*)\"")
	var files: Array[String] = []
	for dir: String in CONSUMER_DIRS:
		files.append_array(_gd_files(dir))
	files.append_array(SIM_CONSUMERS)
	for path: String in files:
		for line: String in _code_lines(path):
			for m in literal.search_all(line):
				out[m.get_string(1)] = path
	for row: Variant in _router_types():
		out[str(row)] = "data router"
	return out


## The names read by tests and tools only. A row here is a MEASUREMENT seam,
## which is a real answer to "who consumes this" and a different one from
## "nobody does".
func _measured() -> Dictionary:
	var out: Dictionary = {}
	var literal := RegEx.new()
	literal.compile("&?\"([a-zA-Z_][A-Za-z0-9_]*)\"")
	for dir: String in MEASUREMENT_DIRS:
		for path: String in _gd_files(dir):
			for line: String in _code_lines(path):
				for m in literal.search_all(line):
					out[m.get_string(1)] = path
	return out


## Every event type the two data-driven routers name, in file order.
func _router_types() -> Array:
	var out: Array = []
	var ui: Dictionary = StarterCityLoader.read_json("res://data/ui.json")
	for raw: Variant in (ui.get("event_log", {}) as Dictionary).get("events", []):
		if (raw as Dictionary).has("type"):
			out.append(str((raw as Dictionary)["type"]))
	var notifications: Dictionary = StarterCityLoader.read_json(
			"res://data/notifications.json")
	for raw2: Variant in notifications.get("bindings", []):
		if (raw2 as Dictionary).has("type"):
			out.append(str((raw2 as Dictionary)["type"]))
	return out


## Source lines with whole-line comments dropped. A `##` class-doc paragraph
## that names an event it is explaining must not read as a consumer of it.
func _code_lines(path: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for line: String in FileAccess.get_file_as_string(path).split("\n"):
		if line.strip_edges().begins_with("#"):
			continue
		out.append(line)
	return out


func _gd_files(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := dir_path + "/" + entry
		if dir.current_is_dir():
			if not entry.begins_with("."):
				out.append_array(_gd_files(full))
		elif entry.ends_with(".gd"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


# ===========================================================================
# The gate
# ===========================================================================

func test_every_emitted_event_is_consumed_or_classified() -> void:
	var emitted := _emitted()
	var consumed := _consumed()
	var measured := _measured()
	var unexplained: PackedStringArray = []
	var wired := 0
	var measurement := 0
	for name: String in emitted:
		if consumed.has(name):
			wired += 1
			continue
		if REGISTER.has(name):
			if str(REGISTER[name]).begins_with("measurement"):
				measurement += 1
			continue
		# A measurement seam still needs its row: "tests read it" is a
		# classification, not an excuse for not writing one down.
		unexplained.append("%s (emitted by %s%s)" % [name, emitted[name],
				", read by tests only" if measured.has(name) else ""])
	unexplained.sort()
	assert_eq(str(unexplained), "[]",
			"every event sim/ emits is consumed or carries a written"
			+ " classification (doc 93's event ruling)")
	print("  [event-matrix] %d types emitted, %d consumed by the game, %d classified"
			% [emitted.size(), wired, REGISTER.size()])
	assert_true(emitted.size() >= 120,
			"the scan still sees the whole tree: %d types" % emitted.size())


func test_the_register_cannot_rot() -> void:
	# A row for an event that no longer exists is a claim nobody re-checked.
	var emitted := _emitted()
	var ghosts: PackedStringArray = []
	for name: String in REGISTER:
		if not emitted.has(name):
			ghosts.append(name)
	ghosts.sort()
	assert_eq(str(ghosts), "[]", "every classified row names a live emit site")


func test_the_register_names_a_consumer_that_is_no_longer_needed() -> void:
	# The other rot: a row that stayed after the event was actually wired. It is
	# not an error — a wired event with a stale exemption still behaves — but it
	# is a line of prose that has stopped being true, so it fails.
	var consumed := _consumed()
	var stale: PackedStringArray = []
	for name: String in REGISTER:
		if consumed.has(name):
			stale.append(name)
	stale.sort()
	assert_eq(str(stale), "[]",
			"an event that acquired a consumer has had its exemption removed")


func test_every_classification_is_one_word_and_a_reason() -> void:
	for name: String in REGISTER:
		var row := str(REGISTER[name])
		var colon := row.find(":")
		assert_true(colon > 0, "%s: `<classification>: <reason>`" % name)
		var word := row.substr(0, colon).strip_edges()
		assert_true(CLASSIFICATIONS.has(word),
				"%s is classified `%s`, which is not one of %s"
				% [name, word, str(CLASSIFICATIONS)])
		assert_true(row.substr(colon + 1).strip_edges().length() >= 24,
				"%s says WHY, not just what: `%s`" % [name, row])
		# The one word with a stricter contract: a deferred consumer has to be
		# a commitment, which means naming the wave that owes it and the file
		# that will do the consuming. Without this, `awaiting_consumer` would be
		# the escape hatch every other word in this list exists to prevent.
		if word == "awaiting_consumer":
			assert_true(row.contains("Wave ") and (row.contains("game/")
					or row.contains("ui/") or row.contains("data/")),
					"%s defers to a NAMED wave and a NAMED file: `%s`"
					% [name, row])


func test_every_type_the_routers_name_is_emitted() -> void:
	# Doc 91 §18.1's clean direction, extended to both tables whole — the RR-1
	# failure mode, and the "cheap next step" §18.2 ranks. This one fails
	# CLOSED: copy wired to an event nobody sends renders as silence.
	var emitted := _emitted()
	var orphans: PackedStringArray = []
	for name: Variant in _router_types():
		if not emitted.has(str(name)):
			orphans.append(str(name))
	orphans.sort()
	assert_eq(str(orphans), "[]",
			"every row in data/ui.json.event_log and"
			+ " data/notifications.json.bindings names an event sim/ emits")


func test_the_flood_is_wired_end_to_end() -> void:
	# A91-D-26, held down. Doc 07 §2.4's standing water reached a renderer, a
	# log row and a push in one branch, and this is the assertion that stops any
	# of the three quietly going away again.
	var consumed := _consumed()
	assert_true(consumed.has("flood_level_changed"),
			"flood_level_changed has a consumer at all")
	var router := _router_types()
	assert_true(router.has("flood_level_changed"),
			"...and a row in the event log / notification tables")
	assert_true(router.has("road_reopened"),
			"...and the closure's missing other half is wired too")
	assert_false(REGISTER.has("flood_level_changed"),
			"and it is NOT sitting in the exemption register")
