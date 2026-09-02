extends Node
## Screen previewer and screen auditor for the whole UI deck (doc 12 §2).
##
## `game/main.tscn` brings the screens up over a live sim and a 3D world, which is
## the wrong instrument for a UX pass: it takes seconds to boot, it can only show
## the states the sim happens to be in, and half the interesting states (an empty
## drawer, a full save list, a blocked placement, an ineligible unit) never occur
## on demand. So this scene mounts `game/ui/ui_root.tscn` on a flat backdrop,
## drives it to one **named state** with fixture data, and either screenshots it
## or walks it with `UIAudit`. It is a development harness, not a game scene: it
## holds no renderer and nothing the player runs references it.
##
##     godot --path . tools/ui_preview.tscn -- --screen=drawer \
##         --size=794x924 --screenshot=/tmp/drawer.png
##     godot --path . tools/ui_preview.tscn -- --screen=all --size=412x915 \
##         --audit --screenshot=/tmp/shots
##     godot --path . tools/ui_preview.tscn -- --screen=all --size=360x800 \
##         --text-scale=1.3 --large-targets --audit --strict
##
## * `--screen=` — any id in `SCREENS`, or `all` to walk every one of them (with
##   `--screenshot=` then naming a **directory**).
## * `--size=WxH` — the device box, in dp: content scaling is off here and the
##   safe area is the window, so one pixel is one dp and §2.1's four breakpoints
##   are reachable without a device.
## * `--text-scale=` / `--large-targets` — the two A2/A3 settings a player can
##   change. A sweep that only ever runs at 100 % is the happy path, not a sweep.
## * `--audit` prints every finding `UIAudit` has; `--strict` also exits non-zero
##   when it found any, which is what a CI shot would use.
## * `--rects=SUBSTRING` prints the laid-out rect of every `Control` whose path
##   contains it. An overlap finding names two nodes and their rects; fixing one
##   needs the rects of everything ELSE in that column, which only a live layout
##   knows. `--rects=TopBar` beside `--rects=Rail` is how the vertical budget in
##   §2.4's solver was measured.
##
## `tests/test_ui_audit.gd` runs the frame-free half of the same checks inside the
## suite; this is the pixel-accurate pass, and the one that can take a picture.

const SHOT_AT_S := 0.6
const DEFAULT_SIZE := Vector2i(880, 400)

## Every state this harness can reach, in walk order — a screen that cannot be
## named here cannot be swept, so a new one is a row in this list plus a branch
## in `_apply()`.
const SCREENS: Array[String] = [
	"hud", "hud_banners", "hud_critical",
	"build", "build_grid", "build_locked", "build_roads",
	"placement_ok", "placement_blocked",
	"path_aiming", "path_ok", "path_blocked", "path_refund", "path_feeder",
	"building", "building_blocked", "building_repairable", "building_water",
	# Wave 17's POWER section (doc 12 §2.9 D-70) in its two states: the wire with
	# room, and the wire that is the reason the UPGRADE button is dead.
	"building_power", "building_power_fix",
	"land_buy", "land_blocked", "land_developing",
	"drawer", "drawer_empty", "drawer_expanded", "drawer_water",
	"picker", "picker_empty",
	"dashboard", "economy", "infrastructure", "response",
	"away", "away_short",
	"alerts", "alerts_empty",
	"overlay", "overlay_police", "overlay_fire", "overlay_folded", "overlay_power",
	"goals", "goals_late", "goals_done",
	"settings", "saves", "pause",
	"title", "title_fresh", "title_confirm", "title_crisis",
	# S15. A91-D-28's lesson, applied on the way in rather than a wave late: a
	# screen with no state here is a screen the sweep has never opened, and the
	# one that caused D-12 was exactly that. Two states, because the veil has two
	# phases and they carry different copy.
	"veil_load", "veil_catchup",
	"coach_welcome", "coach_place_house", "coach_dispatch", "coach_payoff",
	# Wave 14's payday. Two states, because it lands on two surfaces that are
	# never on screen together: the one-shot discovery mark over the world, and
	# the Economy ledger with the two lines doc 03 does not settle.
	"street_coach", "economy_street",
	# Wave 18, Lane S. `economy_assistance` (99-PA PA-32) is the founding
	# fortnight: doc 03 §2.5a's grant still paying, with the row that now says
	# what it pays today and which game-day it stops — `economy` above is a
	# settlement with the grant already retired, so it can never photograph this.
	# `economy_upkeep` (PA-31/PA-33) is the Upkeep band with a worn city under it
	# and the batch button live, which is the state the band exists for.
	"economy_assistance", "economy_upkeep",
	# S16, Wave 17 (doc 12 §2.22). Four states, in the same commit as the screen
	# — A91-D-28's lesson, applied on the way in. `queue` is the mixed list the
	# panel is written for; `queue_uncrewed` is the row that says so in words
	# rather than counting down from nothing; `queue_empty` is the panel with the
	# last project gone out from under it (reachable: the queue can drain while
	# it is open, and the chip leaves with it); `building_upgrading` is the same
	# facts inline on S5.
	"queue", "queue_uncrewed", "queue_empty", "building_upgrading",

	# Wave 17's tilt slider (doc 12 §2.23). Two faces, same commit as the
	# control: the RESTING column, ghosted after its idle fade, thumb on the
	# AUTO detent; and MID-DRAG, full alpha, the thumb leaned toward the
	# facades with the pressed face.
	"tilt_rest", "tilt_drag",
]

## A `Control` does not have a size until its container has laid it out, and the
## whole point of this harness is to judge sizes — so every state gets a settle
## window before it is measured or photographed.
const SETTLE_S := 0.12
## …and at least this many whole frames, because a settle window measured in
## seconds can be satisfied by ONE frame whose `delta` carried the boot. Two: the
## frame `_apply()` ran in, and one in which every child has processed since.
const MIN_FRAMES_BEFORE_MEASURE := 2

## S0's fixture profile: a city in the autosave rotation plus one manual save, so
## CONTINUE carries a meta line and NEW CITY's confirmation has both a save to
## name as kept and a free slot to offer.
const _TITLE_SLOTS: Array = [
	{"slot": 0, "saved_at_unix": 1755500000, "day_index": 12,
			"population": 184291, "treasury": 8420000},
	{"slot": 1, "saved_at_unix": 1755000000, "day_index": 3,
			"population": 1204, "treasury": 42000},
]

var _screen := "drawer"
var _path := ""
var _audit := false
var _strict := false
var _size := Vector2i.ZERO
var _shot_at := SHOT_AT_S
var _timer := 0.0
## Frames processed since the current state was applied — see
## `MIN_FRAMES_BEFORE_MEASURE`.
var _frames_since_apply := 0
var _root: UIRoot
var _sim: CitySim
var _controller: BuildController
var _building_panel: BuildingPanel
var _findings := 0
var _queue: PackedStringArray = []
var _text_scale := 1.0
var _large_targets := false
## `--no-goal-chip`: suppress S14's top-bar chip for this run. The A/B half of a
## finding — a top-bar defect that is present with and without it is the bar's,
## not the chip's, and doc 91 D-12's lesson is that "it was already broken" has
## to be MEASURED rather than assumed.
var _no_goal_chip := false
## `--rects=`: print the laid-out rect of every Control whose path contains this.
var _rects := ""
## S16's provider, as a swappable fixture. The seam is a `Callable` precisely so
## this harness can reach a queue with an uncrewed row on demand — in a live city
## a starved job and a crewed one are hours apart, and a sweep cannot wait.
var _queue_rows: Array = []


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var text := String(arg)
		if text.begins_with("--screen="):
			_screen = text.trim_prefix("--screen=")
		elif text.begins_with("--screenshot="):
			_path = text.trim_prefix("--screenshot=")
		elif text.begins_with("--size="):
			_size = _parse_size(text.trim_prefix("--size="))
		elif text.begins_with("--shot-at="):
			_shot_at = float(text.trim_prefix("--shot-at="))
		elif text.begins_with("--text-scale="):
			_text_scale = float(text.trim_prefix("--text-scale="))
		elif text == "--large-targets":
			_large_targets = true
		elif text == "--no-goal-chip":
			_no_goal_chip = true
		elif text.begins_with("--rects="):
			_rects = text.trim_prefix("--rects=")
		elif text == "--audit":
			_audit = true
		elif text == "--strict":
			_strict = true
	var window := get_window()
	if window != null and _size.x > 0:
		window.size = _size
		window.content_scale_factor = 1.0
	_mount()
	_queue = PackedStringArray(SCREENS) if _screen == "all" \
			else PackedStringArray([_screen])
	_apply(_queue[0])


static func _parse_size(text: String) -> Vector2i:
	var parts := text.split("x")
	if parts.size() < 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))


## Writes `--text-scale` / `--large-targets` into `data/ui.json.defaults` in
## memory, before any screen reads it. Both are the two A2/A3 settings the player
## can actually change, and both move every dimension in the deck — a sweep that
## only ever runs at 100 % is not a sweep, it is the happy path.
func _apply_accessibility(cfg: UIConfig) -> void:
	if cfg == null:
		return
	var defaults: Variant = cfg.ui_data().get("defaults", {})
	if not (defaults is Dictionary):
		return
	(defaults as Dictionary)["text_scale"] = _text_scale
	(defaults as Dictionary)["larger_touch_targets"] = _large_targets


func _mount() -> void:
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	_root = packed.instantiate()
	# One dp is one pixel here: `--size=` is then a device box in the units doc 12
	# §2.1 is written in, and a screenshot measures what the doc measures.
	_root.apply_content_scale = false
	# The window IS the device: no desktop dock inset, no screen-sized safe area.
	_root.safe_area_override = Rect2i(Vector2i.ZERO,
			_size if _size.x > 0 else DEFAULT_SIZE)
	# Before `add_child`, because a child's `_ready()` runs during it and every
	# screen reads the two A2/A3 settings once, in its own `setup()`. Injecting
	# afterwards leaves half the deck configured at 100 %.
	_root.config = UIConfig.load_from_files()
	_apply_accessibility(_root.config)
	add_child(_root)
	_root.initialize()
	# The tilt slider needs an axis to draw; this harness has no rig, so it gets
	# a fresh `CameraState` — the same wiring `game/main.gd` does with the live
	# one, and what puts the column into every sweep rather than only its own.
	_root.bind_camera(CameraState.load_from_files())
	_sim = CitySim.boot_from_files()
	_controller = BuildController.new(_sim)
	_building_panel = _root.safe_area.get_node_or_null(
			"PanelLayer/BuildingPanel") as BuildingPanel
	if _building_panel != null:
		_building_panel.setup(_root.config, _controller)
	if _root.land_panel != null:
		_root.land_panel.setup(_root.config, LandPanelModel.new(_sim,
				_controller.formatter, _root.config, _controller.tile_m))
	if _root.build_sheet != null:
		_root.build_sheet.setup(_root.config, _controller)
	# S14. Same wiring `game/main.gd` does: the sheet gets the shared config and a
	# model over the live fixture sim, so the reward card is READ from the real
	# build-card table rather than from a fixture that could drift from it.
	if _root.goals_sheet != null:
		_root.goals_sheet.setup(_root.config,
				GoalsModel.new(_sim, _root.config, _controller))
	_populate()


# ---------------------------------------------------------------------------
# Fixtures — one city's worth of plain data, shared by every screen
# ---------------------------------------------------------------------------

func _populate() -> void:
	var snapshot := _snapshot()
	if _root.hud != null:
		_root.hud.refresh(snapshot)
	_root.set_incident_locator(func(_kind: StringName, id: Variant) -> Variant:
		var tile: Vector2i = id
		return Vector3(float(tile.x) * 8.0, 0.0, float(tile.y) * 8.0))
	_root.set_alert_locator(func(_kind: StringName, _id: Variant) -> Variant:
		return Vector3(96.0, 0.0, 160.0))
	_root.refresh_incidents(_incidents(), 24.0)
	_root.set_unit_provider(func(_incident_id: int) -> Array:
		return [
			{"id": 1, "dept": "fire", "kind": "engine", "eta_gs": 48.0, "state": "IDLE"},
			{"id": 2, "dept": "fire", "kind": "ladder", "eta_gs": 132.0,
					"state": "RETURNING"},
			{"id": 3, "dept": "utility", "kind": "utility_truck", "eta_gs": 260.0,
					"state": "ON_SCENE", "required": false},
			{"id": 4, "dept": "police", "kind": "patrol_car", "eta_gs": -1.0,
					"state": "REFIT", "frees_in_gs": 420.0},
			{"id": 5, "dept": "water", "kind": "water_crew", "eta_gs": -1.0,
					"state": "OFFLINE"},
		])
	for i in 96:
		var t := float(i)
		_root.sample_history({
			"hour": i,
			"treasury": 6_000_000.0 + t * 26_000.0 + sin(t * 0.4) * 320_000.0,
			"population": 176_000.0 + t * 72.0,
			"net_per_hour": 4200.0 + sin(t * 0.7) * 2600.0,
			"happiness": 0.58 + sin(t * 0.25) * 0.06,
			"stability": 0.74 - sin(t * 0.18) * 0.05,
			"power01": 0.99 - maxf(0.0, sin(t * 0.31)) * 0.22,
			"water01": 0.92 - maxf(0.0, sin(t * 0.12)) * 0.10,
		})
	_root.feed_settlement({
		"hour": 96,
		"revenue": {"tax": 12480.0, "power_tariff": 940.0, "water_tariff": 410.0,
				"city_services": 120.0, "assistance": 0.0, "gross": 13950.0},
		"expenses": {"building_maint": 4120.0, "departments": 2260.0, "fleet": 610.0,
				"vehicle_fuel": 140.0, "grid": 320.0, "generation_fuel": 830.0,
				"water": 260.0, "roads_repair": 90.0, "debt": 0.0, "total": 8630.0},
		"net": 5320.0,
	})
	_root.bind_tax(_sim.cmd_set_tax_level, _sim.tax_level(), _sim.tax_level_count(),
			_sim.tax_rate)
	# Doc 06 §2.11's recall and doc 10 §2.13's auto-repair dials, on the same
	# terms `game/main.gd` binds them: without the wires the drawer draws no
	# recall chip and S9's two road rows never see the city's own policy, so the
	# sweep would photograph a deck the shipped game does not have.
	_root.bind_recall(_sim.cmd_recall_unit)
	_root.bind_road_policy(_sim.cmd_set_auto_repair_policy, _sim.auto_repair_policy())
	_root.ingest_service({"power01": 0.93, "water01": 0.71})
	_root.feed_infrastructure(_infrastructure())
	_root.feed_response(_response())
	_root.refresh_dashboard(snapshot)
	# S14's chip rides every screen in this sweep, not just the goals ones: it is
	# a top-bar chip, so it changes the bar's solve at every device box and has to
	# be measured there. `--no-goal-chip` takes it back out, which is how a
	# finding is attributed to the chip rather than to the bar it landed on.
	if not _no_goal_chip:
		_root.refresh_goals()
	# S16's seam. Bound in `_populate` and not in one state's branch, for the
	# goal chip's reason: the queue chip is a corner-rail affordance and it
	# changes the rail's solve on EVERY screen behind it, so it has to be
	# measured on every screen — a chip that only exists in its own state is a
	# chip nothing else in the deck has ever been laid out beside.
	_queue_rows = _queue_fixture()
	_root.bind_construction(
			func() -> Array: return _queue_rows,
			func(job_id: Variant) -> Dictionary:
				# The fixture door: it answers, it takes the money, and it drops
				# the row — so the sweep can photograph the list before and after
				# without a sim. `int(str())` at the door is the contract's own
				# coercion (the Wave-14 String-id lesson).
				var wanted := int(str(job_id))
				for i in _queue_rows.size():
					var row: Dictionary = _queue_rows[i]
					if int(row["job_id"]) != wanted:
						continue
					_queue_rows.remove_at(i)
					return {"ok": true, "err": "", "cost": int(row["rush_cost"])}
				return {"ok": false, "err": "E_UNKNOWN_JOB", "cost": 0},
			func() -> int: return int(_sim.treasury.balance))
	if _building_panel != null and _root.construction_queue != null:
		_building_panel.bind_construction(_root.construction_queue.model)
	for mode: StringName in [OverlayModel.MODE_POLICE, OverlayModel.MODE_FIRE]:
		_root.feed_overlay_summary(mode, _coverage_summary())
	# Wave 17's grid reading (doc 12 §2.10 D-72), through the SAME door the shell
	# uses, so this photographs the shipping lines rather than a fixture.
	_root.feed_overlay_summary(OverlayModel.MODE_POWER,
			UIRoot.power_summary_lines(_controller.power.grid_reading(), _root.config))


## §2.10's Infrastructure feed, in the shape `PowerGrid.feeder_rows()` and
## `WaterSnapshot.build()` publish — a mid-sized city an hour into a heat wave,
## which is the state the tab exists to read.
static func _infrastructure() -> Dictionary:
	var feeders: Array = []
	for i in 9:
		var ratio := 0.28 + 0.09 * float(i)
		feeders.append({"id": "F-%02d" % (i + 1), "kind": "feeder", "parent": "SUB-1",
				"load_kw": 3000.0 * ratio, "capacity_kw": 3000.0,
				"effective_kw": 3000.0, "load_ratio": ratio,
				"headroom_kw": 3000.0 * (1.0 - ratio), "condition": 0.94 - 0.04 * float(i),
				"state": "OPEN" if i == 8 else "OK", "energized": i != 8,
				"shed": i == 7, "customers": 12 + i * 5})
	var transformers: Array = []
	for i in 7:
		var ratio := 0.42 + 0.11 * float(i)
		transformers.append({"id": "T-%02d" % (i + 1), "kind": "transformer",
				"parent": "F-01", "load_kw": 400.0 * ratio, "capacity_kw": 400.0,
				"effective_kw": 400.0, "load_ratio": ratio,
				"headroom_kw": 400.0 * (1.0 - ratio), "condition": 0.88,
				"state": "OK", "energized": true, "shed": false,
				"customers": 4 + i * 3, "temp_c": 58.0 + 6.0 * float(i)})
	return {
		"power": {"supply_kw": 51000.0, "demand_kw": 42100.0,
				"plant_capacity_kw": 51000.0, "headroom_kw": 8900.0,
				"load_ratio": 0.8255, "feeders_over": 2, "transformers_over": 1,
				"shed_feeders": 1},
		"feeders": feeders,
		"transformers": transformers,
		"water": {
			"zones": [
				{"zone_key": "Harbour", "pressure": 0.07, "building_count": 12},
				{"zone_key": "Old Town", "pressure": 0.31, "building_count": 41},
				{"zone_key": "Riverside", "pressure": 0.52, "building_count": 28},
				{"zone_key": "Northgate", "pressure": 0.78, "building_count": 63},
				{"zone_key": "Foundry", "pressure": 0.91, "building_count": 19},
				{"zone_key": "Millpond", "pressure": 0.96, "building_count": 22},
			],
			"city": {"total_supply_m3h": 1840.0, "total_demand_m3h": 1912.0,
					"storage_frac": 0.41, "zones_in_deficit": 2},
		},
	}


## §2.10's Response feed: doc 06's roster mid-incident, with the fire department
## fully committed — the state the tab is for.
static func _response() -> Dictionary:
	var units: Array = []
	var roster := {"fire": 4, "police": 6, "utility": 3, "water": 2}
	var busy := {"fire": 4, "police": 2, "utility": 1, "water": 0}
	var next_id := 1
	for dept: String in ["fire", "police", "utility", "water"]:
		for i in int(roster[dept]):
			units.append({"id": next_id, "department": dept,
					"status": "RESPONDING" if i < int(busy[dept]) else "IDLE"})
			next_id += 1
	return {
		"units": units,
		"stats": {"resolved_total": 58, "failed_total": 4, "abandoned_total": 1,
				"avg_response_min": 9.4, "rolling_response_score": 0.71,
				"response_samples": 63},
		"open": 3,
	}


## §2.5's aggregate lines for a coverage overlay.
static func _coverage_summary() -> Array:
	return [
		{"label": "Stations", "value": "2"},
		{"label": "Lots with no cover", "value": "18", "state": "critical"},
		{"label": "Below requirement", "value": "5", "state": "warning"},
	]


static func _snapshot() -> Dictionary:
	return {
		"population": 182904, "population_delta_pct_per_day": 0.4,
		"treasury": 8420000, "net_per_hour": 5750.0, "stability": 0.71,
		"happiness": 0.64, "incidents": {"count": 3, "worst_tier": 4},
		"clock": {"minute_of_day": 372, "day_index": 2}, "speed": 1, "paused": false,
	}


## The drawer fixture. Not static any more: the `water_main_break` row names a
## main the LIVE sim actually has, because doc 05 §2.12's valve is drawn from
## `target_ref` and a made-up edge id would photograph a row without one.
func _incidents() -> Array:
	var water_break := _incident(35, "water_main_break", 2.4, "Riverside",
			[4, 9], -1.0, 1.2, 8.0)
	water_break["target_ref"] = {"kind": "water_segment", "id": _first_main()}
	return [
		_incident(31, "structure_fire", 4.6, "Harbour", [7], 12.0, 0.0, 47.0),
		_incident(28, "transformer_failure", 3.2, "Old Town", [], 96.0, 0.0, 118.0),
		water_break,
		_incident(12, "crime", 1.6, "Docks", [], 210.0, 0.0, 340.0),
	]


## The first main in the starter city's own topology, sorted.
func _first_main() -> String:
	if _sim == null:
		return ""
	var ids := _sim.water.edges.keys()
	ids.sort()
	return str(ids[0]) if not ids.is_empty() else ""


## The first `water_facility` shell — the one building in the city whose panel
## carries doc 05 §6's node block.
func _water_shell() -> String:
	var keys := _sim.buildings.keys()
	keys.sort()
	for key: Variant in keys:
		if String((_sim.buildings[key] as Building).archetype) == "water_facility":
			return str(key)
	return _first_building()


## `path_feeder`'s run. §2.1 makes a feeder start ON the network, so the anchor
## is the first tile of an authored feeder's route and the head is four tiles
## along it — the sim's assist fills in the rest.
func _feeder_ghost() -> void:
	var sheet := _root.build_sheet
	sheet.open()
	sheet.select_category(BuildController.CATEGORY_INFRASTRUCTURE)
	var card := sheet.card_button("feeder_c2")
	if card == null:
		return
	card.pressed.emit()
	var anchor := _feeder_anchor()
	sheet.move_ghost(Vector3(float(anchor.x) * 8.0 + 4.0, 0.0,
			float(anchor.y) * 8.0 + 4.0))
	sheet.confirm_placement()   # START: pins the anchor
	var head := anchor + _run_direction(anchor, 4) * 4
	sheet.move_ghost(Vector3(float(head.x) * 8.0 + 4.0, 0.0, float(head.y) * 8.0 + 4.0))


func _feeder_anchor() -> Vector2i:
	for id: Variant in _sim.grid.component_ids_of_kind(&"feeder"):
		var route: Array = _sim.grid.component(String(id)).get("route", [])
		if route.is_empty():
			continue
		var pair: Array = route[0]
		return Vector2i(int(pair[0]), int(pair[1]))
	return _occupied_tile()


static func _incident(id: int, type_id: String, severity: float, where: String,
		assigned: Array, eta_min: float, assist: float,
		wait_min: float) -> Dictionary:
	return {"id": id, "type": type_id, "subtype": "", "tier": int(floor(severity)),
			"severity": severity, "status": "ASSIGNED" if not assigned.is_empty()
					else "QUEUED",
			"pos": [12 + id, 20 + id], "district_id": where,
			"wait_min": wait_min, "assigned": assigned, "assist_ratio": assist,
			"progress": 0.2, "escalation_eta_min": eta_min, "priority": 100.0,
			"pinned": false, "seen": false, "unreachable": false,
			"notification_priority": 2}


## S16's contract rows (doc 12 §2.22), in `CitySim.construction_overview()`'s
## shape verbatim: a mixed queue with an upgrade climbing a level, a new
## building, and a land development, sorted the way the seam promises.
##
## The first row's `ref` is the LIVE sim's own first building, because
## `building_upgrading` shows the same facts on S5 and S5 finds them by `ref` —
## a made-up id would photograph a panel with no block on it and nothing would
## fail.
func _queue_fixture() -> Array:
	return [
		{"job_id": 41, "source": &"upgrade", "title_key": "ui_build_card_house",
				"ref": _first_building(), "tile": _occupied_tile(),
				"level_from": 2, "level_to": 3, "progress01": 0.62,
				"eta_gm": 14.0, "crews": 2, "rushable": true, "rush_cost": 1240},
		{"job_id": 44, "source": &"build",
				"title_key": "ui_build_card_fire_station", "ref": "b_new_1",
				"tile": Vector2i(46, 38), "level_from": 0, "level_to": 0,
				"progress01": 0.18, "eta_gm": 96.0, "crews": 1,
				"rushable": true, "rush_cost": 18400},
		{"job_id": 47, "source": &"development", "title_key": "ui_land_phase_grading",
				"ref": "E4", "tile": Vector2i(64, 48), "level_from": 0,
				"level_to": 0, "progress01": 0.35, "eta_gm": 1_910.0, "crews": 1,
				"rushable": false, "rush_cost": 0},
	]


## Sim-bus events for the alerts centre — one of every notifiable shape, so the
## feed shows the copy the player actually reads rather than one lucky row.
static func _alert_events() -> Array:
	return [
		{"type": "BlockDarkChanged", "block_id": "Harbour", "block_dark": true},
		{"type": "PowerComponentFailed", "component": "T-04", "cause": "overload"},
		{"type": "PowerComponentTripped", "component": "F-12"},
		{"type": "LoadShedStarted", "shed_kw": 1840.0},
		{"type": "credit_line_engaged", "balance": -240000},
		# `from`/`to` and `block` are what sim/ actually emits — the deleted
		# stand-in table read `level` and `block_id`, so these two rows rendered
		# an EMPTY title in the preview and in the game alike.
		{"type": "city_level_changed", "from": 2, "to": 3},
		{"type": "building_completed", "building": 7, "level": 2},
		{"type": "block_ready", "block": "B-14"},
		# NOT extended past eight rows, though doc 08's table now wires ~14 more
		# shapes: at 412x915 the alerts list already overlaps the incident-drawer
		# handle and the event-log chip from its FIRST row (a pre-existing
		# `overlapping_targets` finding at HEAD, in ui/alerts_center.gd's panel
		# geometry, not in this fixture). Adding rows only deepens somebody
		# else's defect; `tests/test_notifications.gd` covers the new shapes.
	]


# ---------------------------------------------------------------------------
# States
# ---------------------------------------------------------------------------

func _apply(screen: String) -> void:
	_close_everything()
	match screen:
		"hud":
			pass
		"hud_banners":
			_root.hud.push_alert({"id": "a1", "class": "p1",
					"event_type": "outage_major", "title": "3 blocks are dark"})
			_root.hud.push_alert({"id": "a2", "class": "p2",
					"event_type": "component_tripped", "title": "F-12 tripped"})
		"hud_critical":
			var bad := _snapshot()
			bad["treasury"] = -1240000
			bad["net_per_hour"] = -8200.0
			bad["stability"] = 0.18
			bad["incidents"] = {"count": 14, "worst_tier": 5}
			_root.hud.refresh(bad)
			_root.ingest_service({"power01": 0.41, "water01": 0.22})
		"build":
			_root.build_sheet.open()
		"build_grid":
			_root.build_sheet.open()
			_root.build_sheet.select_category(BuildController.CATEGORY_INFRASTRUCTURE)
		"build_locked":
			_root.build_sheet.open()
			_root.build_sheet.select_category("commercial")
		"build_roads":
			# §2.7's ROADS tab: four run cards, each quoting a per-tile price.
			_root.build_sheet.open()
			_root.build_sheet.select_category(PathTool.CATEGORY_ROADS)
		"placement_ok":
			_place_ghost(true)
		"placement_blocked":
			_place_ghost(false)
		"path_aiming":
			# Step one of the two-step run flow: the card is held, the ghost is
			# hunting, and the bar's primary button reads START.
			_run_ghost("road_street", false, false)
		"path_ok":
			_run_ghost("road_street", true, false)
		"path_blocked":
			# A run that touches no existing road — doc 10's E_NOT_CONNECTED, in
			# the formatter's words, with PLACE dead.
			_run_ghost("road_street", true, true)
		"path_refund":
			# The one card in the deck whose money goes the other way.
			_run_ghost("road_remove", true, false)
		"path_feeder":
			# Doc 04 §4's run verb, drawn from the network it has to start on.
			# Its geometry is the C-41 assist rather than an L, so this is also
			# the state that photographs a run the player did not draw tile by
			# tile — and the bar's longest sentence, `E_NO_SLOT`, when doc 09's
			# two authored feeders have already taken SUB-A's slots.
			_feeder_ghost()
		"building":
			if _building_panel != null:
				_building_panel.show_building(_first_building())
		"building_blocked":
			if _building_panel != null:
				var b: Building = _sim.buildings[_first_building()]
				b.condition = 0.35
				_building_panel.show_building(_first_building())
		"building_repairable":
			# §2.9 item 6's actions row with everything live: a repair to buy, a
			# shed tier to pick, and a demolition to hold for.
			#
			# **A CITY asset** since Wave 17 (doc 02 §2.6a): private stock keeps
			# itself up, so a worn house draws no repair row and this state used
			# to render the one thing it exists to show as absent. `POL-1` is
			# the founding police station.
			if _building_panel != null:
				var worn: Building = _sim.buildings["POL-1"]
				worn.condition = 0.72
				_sim.treasury.balance = 500_000
				_building_panel.show_building("POL-1")
		"building_water":
			# Doc 05 §6's node block: a `water_facility` shell with its own
			# ladder rows under the doc-02 one. `WTR-1` hosts three nodes, which
			# is the widest this block ever gets.
			if _building_panel != null:
				_sim.treasury.balance = 500_000
				_building_panel.show_building(_water_shell())
		"building_power":
			# Wave 17's POWER section with the wire in good shape: the hops named,
			# the spare capacity in words, and a live UPGRADE button with its
			# price on its face.
			if _building_panel != null:
				_sim.treasury.balance = 500_000
				_building_panel.show_building(_first_building())
		"building_power_fix":
			# The state the wave exists for: the next level does not fit on the
			# transformer, the checklist row says so, and the `Fix this →` strip
			# under it quotes the one purchase that clears it. `T-18` is the
			# starter city's own bottleneck — `WTR-2`'s +98 kW on a 150 kW node
			# — so this is a photograph of a real refusal, not a fixture.
			if _building_panel != null:
				_sim.treasury.balance = 500_000
				_building_panel.show_building(_power_blocked_building())
		"land_buy":
			# The city can afford it: the panel's happy face, with the primary
			# button live and no blocker rows under it.
			_sim.treasury.balance = 500_000
			_root.land_panel.show_block(_purchasable_block())
		"land_blocked":
			# Broke. `cmd_buy_block(preview)` answers E_FUNDS and the button goes
			# dead with the formatter's sentence under it — the state §2.8's
			# blocker list exists for.
			_sim.treasury.balance = 0
			_root.land_panel.show_block(_purchasable_block())
		"land_developing":
			# Bought, developing, one phase in — the six-step progress list with a
			# live bar and an ETA (§2.8 item 4).
			_sim.treasury.balance = 500_000
			var block_id := _purchasable_block()
			_sim.cmd_buy_block(block_id, false, true)
			_sim.advance_hours(3.0)
			_root.land_panel.show_block(block_id)
		"drawer":
			_root.incident_drawer.open()
		"drawer_empty":
			_root.refresh_incidents([], 24.0)
			_root.incident_drawer.open()
		"drawer_expanded":
			_root.incident_drawer.open()
			_root.incident_drawer.row_button(31).pressed.emit()
		"drawer_water":
			# The one row that carries a fourth action: doc 05 §2.12's valve, on
			# a `water_main_break` whose target the sim still has.
			_root.incident_drawer.open()
			_root.incident_drawer.row_button(35).pressed.emit()
		"picker":
			_root.incident_drawer.open()
			_root.incident_drawer.row_button(31).pressed.emit()
			_root.incident_drawer.action_button("Assign", 31).pressed.emit()
		"picker_empty":
			_root.set_unit_provider(func(_incident_id: int) -> Array: return [])
			_root.incident_drawer.open()
			_root.incident_drawer.row_button(28).pressed.emit()
			_root.incident_drawer.action_button("Assign", 28).pressed.emit()
		"dashboard":
			_root.city_dashboard.open(DashboardModel.TAB_OVERVIEW)
			_root.city_dashboard.row_button("treasury").pressed.emit()
		"economy":
			_root.city_dashboard.open(DashboardModel.TAB_ECONOMY)
		"economy_assistance":
			# Game-day 3 of the founding week: the grant is still paying and the
			# row has to say what it pays TODAY and which day it stops (99-PA
			# PA-32). The settlement is doc 03's own snapshot shape, `hour` and
			# `assistance_days_left` included, because the end day is derived
			# from those two and not authored anywhere in `ui/`.
			_root.feed_settlement({
				"hour": 74,
				"assistance_days_left": 4,
				"revenue": {"tax": 980.0, "power_tariff": 61.0, "water_tariff": 26.0,
						"city_services": 38.0, "assistance": 98.29, "gross": 1203.29},
				"expenses": {"building_maint": 214.0, "departments": 96.0,
						"fleet": 76.0, "vehicle_fuel": 12.0, "grid": 31.0,
						"generation_fuel": 74.0, "water": 21.0, "roads_repair": 8.0,
						"debt": 0.0, "total": 532.0},
				"net": 671.29,
			})
			_root.city_dashboard.open(DashboardModel.TAB_ECONOMY)
		"economy_upkeep":
			# A worn city, through the REAL verbs: the band's repair half is
			# `CitySim.cmd_repair_all_worn` and its policy line is
			# `CitySim.building_repair_policy`, so what this photographs is the
			# shipped screen and not a fixture of it (99-PA PA-31/PA-33).
			for sim_id: String in _sim.roster_ids():
				var worn: Building = _sim.buildings[sim_id]
				if worn.state == &"active":
					worn.condition = 0.62
			# One settled game-hour on the worn roster, so `last_settlement`
			# carries doc 03's own per-building `f_condition` rows — which is
			# where every figure on the band comes from.
			_sim.advance_coarse_hours(1)
			_root.feed_settlement(_sim.last_settlement)
			_root.city_dashboard.bind_upkeep(_sim.cmd_repair_all_worn,
					_sim.building_repair_policy,
					func() -> float: return float(_sim.treasury.balance))
			_root.city_dashboard.open(DashboardModel.TAB_ECONOMY)
		"economy_street":
			# The same ledger with a policed city's real income in it: bounties
			# are the second-largest line on this screen once a fleet is out, and
			# they have never been drawn before this wave.
			_root.feed_events([
				{"type": &"incident_resolved", "incident_id": 4,
						"incident_type": "crime", "reward": 1840},
				{"type": &"street_opportunity_collected", "id": "opp_3",
						"by_player": false, "reward": 260},
				{"type": &"economy_hour_settled", "hour": 41, "gross": 5840.0,
						"expense": 2100.0, "net": 3740.0},
			])
			_root.city_dashboard.open(DashboardModel.TAB_ECONOMY)
		"street_coach":
			# The discovery mark, pointed at a fixed spot: the coach layer only
			# cares that a world point RESOLVES, and a live camera is not what
			# this pass is judging (same contract as `_coach` below).
			var centre := get_viewport().get_visible_rect().size * 0.5
			_root.set_onboarding_world_projector(
					func(_world: Vector3) -> Variant: return centre)
			_root.feed_events([{"type": &"street_opportunity_spawned",
					"id": "opp_1", "kind": "loose_dog",
					"world_pos": Vector3(96.0, 0.0, 128.0)}])
		"infrastructure":
			_root.city_dashboard.open(DashboardModel.TAB_INFRASTRUCTURE)
		"response":
			_root.city_dashboard.open(DashboardModel.TAB_RESPONSE)
		"away":
			_root.present_away_report(_away_input(22320.0, true))
		"away_short":
			_root.present_away_report(_away_input(1500.0, false))
		"alerts":
			_root.alerts_center.set_clock(372, 2)
			_root.alerts_center.feed_batch(_alert_events())
			_root.alerts_center.open()
		"alerts_empty":
			_root.alerts_center.open()
		"overlay":
			_root.overlay_rail.open()
			# The first enabled mode past `none`, so the shot shows a *selected*
			# chip whichever overlays this build has actually landed.
			for mode: StringName in _root.overlay_rail.model.modes():
				if mode != OverlayModel.MODE_NONE \
						and _root.overlay_rail.model.is_enabled(mode):
					_root.overlay_rail.select(mode)
					break
		"overlay_police":
			# The §2.5 legend CARD, which is the point of these two states: the
			# strip is closed and the reading is still on screen.
			_root.overlay_rail.select(OverlayModel.MODE_POLICE)
		"overlay_fire":
			_root.overlay_rail.open()
			_root.overlay_rail.select(OverlayModel.MODE_FIRE)
		"overlay_folded":
			_root.overlay_rail.select(OverlayModel.MODE_FIRE)
			_root.overlay_rail.legend_card().toggle_button().pressed.emit()
		"overlay_power":
			# Wave 17's grid reading on the §2.5 legend card (D-72): the pool, the
			# WIRES, and which of the two is the wall.
			_root.overlay_rail.open()
			_root.overlay_rail.select(OverlayModel.MODE_POWER)
		"goals":
			# Level 1 with one objective landed — the state a player is in for
			# their first session, and the one the copy is written for.
			_goals_at(0, 1)
		"goals_late":
			# Level 5's four objectives with two of them landed: the widest the
			# sheet ever gets, and where its reward card is longest.
			_goals_at(4, 2)
		"goals_done":
			# The curriculum finished. The chip has left the bar and the sheet is
			# a payoff card — the one state with no objective rows at all.
			_goals_at(5, 0)
		"settings":
			# Doc 03 §2.9's read-only city block only exists once a city has been
			# reported, and the shell reports it — so the preview reports one too,
			# or this state photographs a screen the game never shows.
			_root.set_city_difficulty(Difficulty.DEFAULT_PRESET)
			_root.settings_sheet.open()
		"saves":
			_root.save_load_sheet.open()
		"pause":
			_root.pause_menu.open()
		"title":
			_title(_TITLE_SLOTS, false)
		"title_fresh":
			_title([], false)
		"title_confirm":
			_title(_TITLE_SLOTS, true)
		"title_crisis":
			# The widest the difficulty chip gets: the longest preset word on the
			# door, with the permanence line under it.
			_title(_TITLE_SLOTS, false)
			while _root.title_screen.model.difficulty() != "crisis":
				_root.title_screen.action_button(
						TitleModel.ACTION_DIFFICULTY).pressed.emit()
		"veil_load":
			# S15 mid-restore, on the benchmark city's own step count: eleven
			# steps with `roads_graph` — step 7, and 37 % of the work — running.
			# That is the moment doc 13 §2.9.1's arithmetic is written about.
			_root.present_veil_load(
					UIWidgets.t(_root.config, "ui_saves_slot_autosave"), 11)
			_root.advance_veil_load(7)
		"queue":
			# The list S16 is written for: an upgrade climbing a level with two
			# crews on it, a new building an hour out, and a land development a
			# day out that cannot be rushed at all.
			_sim.treasury.balance = 500_000
			_root.open_construction_queue()
		"queue_uncrewed":
			# The row §2.8's rule exists for. `eta_gm = -1` and no crew: the line
			# says so in words, the bar is hatched, and nothing anywhere renders
			# `0:00`. The rush price is still on its face — a project nobody is
			# working is exactly the one a player would pay to unstick.
			var starved: Array = _queue_fixture()
			var row: Dictionary = starved[0]
			row["crews"] = 0
			row["eta_gm"] = -1.0
			starved.remove_at(0)
			starved.append(row)   # the seam sorts uncrewed last; so does the model
			_queue_rows = starved
			_sim.treasury.balance = 500_000
			_root.open_construction_queue()
		"queue_empty":
			# Reachable, not theoretical: the last project can finish while the
			# panel is open. The chip goes with it (the empty-state rule) and the
			# panel says what a player should do next instead of showing a blank.
			_queue_rows = []
			_root.open_construction_queue()
		"building_upgrading":
			# The same three facts inline on S5, from the same model — the first
			# fixture row's `ref` is this building.
			if _building_panel != null:
				_sim.treasury.balance = 500_000
				_building_panel.show_building(_first_building())
		"veil_catchup":
			# The C-19 cap exactly: 12 real hours away is 720 coarse game-hours,
			# and the absence ran longer than the sim will credit — so this is
			# also the only state that shows the capped line.
			_root.present_veil_catchup(720, 720, true)
			_root.advance_veil_catchup(415)
		"tilt_rest":
			# The resting face: nobody has touched it, the thumb is on the AUTO
			# detent, and the idle clock is wound past the fade so the photo
			# shows the ghost the player actually lives with.
			if _root.tilt_slider != null:
				_root.tilt_slider.preview_rest()
				_root.tilt_slider.advance(_root.tilt_slider.fade_after_s() + 1.0)
				_root.tilt_slider.advance(1.0)
		"tilt_drag":
			# Mid-drag toward the facades: full alpha, pressed face, the lit
			# half of the track from the detent to the thumb.
			if _root.tilt_slider != null:
				_root.tilt_slider.preview_drag(0.7)
		_:
			if screen.begins_with("coach_"):
				_coach(screen.trim_prefix("coach_"))
			else:
				push_error("ui_preview: unknown screen '%s'" % screen)


func _close_everything() -> void:
	if _root.build_sheet != null:
		_root.build_sheet.cancel_placement()
	if _root.tilt_slider != null:
		_root.tilt_slider.preview_rest()
	for layer: Control in [_root.panel_layer, _root.sheet_layer, _root.modal_layer]:
		if layer == null:
			continue
		for child in layer.get_children():
			if child.has_method("close"):
				child.call("close")
	if _root.overlay_rail != null:
		_root.overlay_rail.close()
		_root.overlay_rail.select(OverlayModel.MODE_NONE)
	if _root.onboarding != null:
		_root.onboarding.reset()
		# A one-shot notice is not a step, so `reset()` does not know about it.
		_root.onboarding.dismiss_notice()
	# …and the flag behind it, or the sweep would only ever see the mark once.
	if _root.street != null:
		_root.street.coached = false
		_root.street.coach_pending = false
	_root.dismiss_title()
	_root.dismiss_veil()
	# Banners live for `alert_ttl_s`, which is longer than a settle window — one
	# state's banners would otherwise photobomb the next four screens.
	for alert: Dictionary in _root.hud.model.active_alerts(0.0):
		_root.hud.model.dismiss_alert(str(alert["id"]))
	_root.refresh_incidents(_incidents(), 24.0)
	_root.hud.refresh(_snapshot())
	_root.ingest_service({"power01": 0.93, "water01": 0.71})
	# S16's fixture is state, and state leaks: an emptied queue would take the
	# corner rail's third rung away from the 60 screens after it.
	_queue_rows = _queue_fixture()
	_root.refresh_construction()


## Drives the fixture sim's curriculum to a named state and opens S14.
##
## `earned` levels are marked complete and `landed` objectives of the level after
## them are ticked — straight into `GoalSystem`'s own state rather than through a
## fixture dictionary, because the sheet's job is to render what the SIM says and
## a fixture would let the two disagree without anybody noticing.
func _goals_at(earned: int, landed: int) -> void:
	var goals: GoalSystem = _sim.goals
	goals.earned_level = earned
	goals.done.clear()
	goals.progress.clear()
	for raw: Variant in GoalSystem.levels():
		var row: Dictionary = raw
		if int(row["level"]) > earned:
			continue
		for entry: Variant in (row["objectives"] as Array):
			goals.done[str((entry as Dictionary)["id"])] = true
	var active := goals.active_level()
	if active != GoalSystem.LEVEL_COMPLETE:
		var objectives: Array = GoalSystem.level_row(active)["objectives"]
		for i in mini(landed, objectives.size()):
			goals.done[str((objectives[i] as Dictionary)["id"])] = true
	goals.reconcile(_sim.goal_state_view())
	goals.drain_events()
	_root.refresh_goals()
	_root.open_goals()


## S0 with a chosen profile behind it. The service is a stub for the same reason
## every other fixture here is one: this harness photographs SCREENS, and a real
## `SaveService` would photograph whatever happens to be in `user://saves`.
class TitleSlots extends RefCounted:
	var rows: Array = []

	func list_slots() -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for raw: Variant in rows:
			out.append((raw as Dictionary).duplicate())
		return out

	func latest_slot() -> int:
		var best := -1
		var best_at := -1
		for raw: Variant in rows:
			var row: Dictionary = raw
			if int(row["saved_at_unix"]) > best_at:
				best_at = int(row["saved_at_unix"])
				best = int(row["slot"])
		return best

	func autosave_slots() -> Array[int]:
		return [0, 7]


func _title(slots: Array, confirming: bool) -> void:
	var stub := TitleSlots.new()
	stub.rows = slots
	_root.title_screen.bind_service(stub)
	_root.present_title()
	if confirming:
		_root.title_screen.action_button(TitleModel.ACTION_NEW_GAME).pressed.emit()


## Walks S12 to one step with the same observations the shell would produce, and
## resolves its world targets to a fixed rectangle — the coach layer only cares
## that a target *resolves*, and a real camera is not what this pass is judging.
func _coach(step_id: String) -> void:
	var flow: OnboardingFlow = _root.onboarding
	if flow == null:
		return
	var box := get_viewport().get_visible_rect()
	flow.set_world_resolver(func(_tag: String) -> Variant:
		return Rect2(box.size * 0.5 - Vector2(48.0, 48.0), Vector2(96.0, 96.0)))
	_root.start_onboarding({"tutorial_lot_a": Vector2i(43, 40),
			"tutorial_lot_b": Vector2i(45, 40)})
	var guard := 0
	while str(flow.model.current().get("id", "")) != step_id and flow.is_active():
		guard += 1
		if guard > 32:
			break
		_satisfy(flow)


func _satisfy(flow: OnboardingFlow) -> void:
	match str(flow.model.current().get("id", "")):
		"look_around":
			flow.feed({"kind": "camera", "focus": Vector3.ZERO, "zoom_t": 0.4})
			flow.feed({"kind": "camera", "focus": Vector3(400.0, 0.0, 0.0),
					"zoom_t": 0.7})
		"open_build":
			flow.feed({"kind": "ui_opened", "path": "build_sheet"})
		"place_house":
			flow.feed({"kind": "command", "command": "place_building", "ok": true,
					"archetype": "house", "tile": Vector2i(45, 40)})
		"unserved_wall":
			flow.feed({"kind": "verdict", "code": "E_UNSERVED", "tile": Vector2i(43, 40)})
		"place_transformer":
			flow.feed({"kind": "command", "command": "place_grid_component", "ok": true,
					"archetype": "transformer", "tile": Vector2i(42, 40)})
		"blackout":
			flow.feed({"kind": "sim_event", "event": "incident_created", "payload": {}})
		"open_drawer":
			flow.feed({"kind": "ui_opened", "path": "incident_drawer"})
		"dispatch":
			flow.feed({"kind": "command", "command": "dispatch_unit", "ok": true})
		"relight":
			flow.feed({"kind": "sim_event", "event": "incident_resolved", "payload": {}})
		_:
			flow.feed({"kind": "ack"})


func _away_input(elapsed_s: float, with_unresolved: bool) -> Dictionary:
	var days := int(elapsed_s / 1440.0)
	var unresolved: Array = []
	if with_unresolved:
		for id in [31, 28]:
			unresolved.append(_root.incident_drawer.model.row(id))
	return {
		"elapsed_wall_s": elapsed_s, "elapsed_game_minutes": elapsed_s,
		"before": {"treasury": 8_420_000, "population": 182_904,
				"day_index": 2, "stability": 0.71, "happiness": 0.62},
		"after": {"treasury": 10_788_800, "population": 184_291,
				"day_index": 2 + days, "stability": 0.68, "happiness": 0.64},
		"ledger": {"taxes": 3_120_400.0, "expenses": 751_600.0,
				"net": 2_368_800.0, "treasury_before": 8_420_000,
				"treasury_after": 10_788_800},
		"events_digest": [
			{"type": "BlockDarkChanged", "block_id": "Harbour", "block_dark": true},
			{"type": "PowerComponentFailed", "component": "T-04", "cause": "overload"},
			{"type": "building_completed", "building": 1, "level": 2},
			{"type": "building_completed", "building": 2, "level": 3},
			{"type": "building_completed", "building": 3, "level": 2},
			{"type": "city_level_changed", "from": 2, "to": 3},
		],
		"unresolved": unresolved,
	}


## The build sheet's own path into placement: pick the card, then move the ghost.
## Going through `BuildController` directly would leave the sheet's bar stale,
## which is precisely the state this harness is meant to photograph honestly.
func _place_ghost(want_valid: bool) -> void:
	var sheet := _root.build_sheet
	sheet.open()
	sheet.select_category("residential")
	var card := sheet.card_button("house")
	if card == null:
		return
	card.pressed.emit()
	var tile := _valid_tile(sheet.controller) if want_valid else _occupied_tile()
	sheet.move_ghost(Vector3(float(tile.x) * 8.0 + 4.0, 0.0, float(tile.y) * 8.0 + 4.0))


## Drives §2.7's drag-path tool to one of its three bar states. `started` pins
## the anchor (the bar flips from START to PLACE); `lonely` puts the run where
## doc 10 refuses it. The tiles are ASKED for, never named — doc 09's starter
## city is data and it may move.
func _run_ghost(card_id: String, started: bool, lonely: bool) -> void:
	var sheet := _root.build_sheet
	sheet.open()
	sheet.select_category(str(PathTool.row(card_id)["category"]))
	var card := sheet.card_button(card_id)
	if card == null:
		return
	card.pressed.emit()
	var tile := Vector2i(TileGrid.SIZE - 2, TileGrid.SIZE - 2) if lonely \
			else _road_edge_tile()
	sheet.move_ghost(Vector3(float(tile.x) * 8.0 + 4.0, 0.0, float(tile.y) * 8.0 + 4.0))
	if not started:
		return
	sheet.confirm_placement()   # START: pins the anchor
	var head := tile + _run_direction(tile, 3) * 3
	sheet.move_ghost(Vector3(float(head.x) * 8.0 + 4.0, 0.0, float(head.y) * 8.0 + 4.0))


## The first of the four axes along which `length` more tiles are layable, so
## `path_ok` photographs a VALID run rather than whichever direction happened to
## hit a footprint. Falls back to +X, which is what a blocked state looks like.
func _run_direction(from: Vector2i, length: int) -> Vector2i:
	var grid := _sim.world.grid
	for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]:
		var clear := true
		for step in range(1, length + 1):
			var q := from + d * step
			if not TileGrid.in_bounds(q.x, q.y) \
					or grid.road_class_at(q.x, q.y) != TileGrid.ROAD_NONE \
					or not grid.can_place(q, Vector2i.ONE):
				clear = false
				break
		if clear:
			return d
	return Vector2i(1, 0)


## A tile a run can legally start from: for a build card, free ground beside an
## existing road; for the remove card, a road tile.
func _road_edge_tile() -> Vector2i:
	var grid := _sim.world.grid
	for z in TileGrid.SIZE:
		for x in TileGrid.SIZE:
			if grid.road_class_at(x, z) == TileGrid.ROAD_NONE:
				continue
			var here := Vector2i(x, z)
			if _root.build_sheet.path != null \
					and _root.build_sheet.path.card_id == "road_remove":
				return here
			for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0),
					Vector2i(0, -1)]:
				var q := here + d
				if not TileGrid.in_bounds(q.x, q.y):
					continue
				if grid.road_class_at(q.x, q.y) != TileGrid.ROAD_NONE:
					continue
				if not grid.can_place(q, Vector2i.ONE):
					continue
				var block := _sim.world.block_of_tile(q.x, q.y)
				if block != null and block.is_ready():
					return q
	return Vector2i(56, 56)


## The first block doc 09's starter city leaves for sale. Asked rather than
## named, like `_valid_tile` — the map is data and may move.
func _purchasable_block() -> String:
	for id: Variant in _sim.world.block_ids_sorted():
		var block: LandBlock = _sim.world.block(String(id))
		if block.ownership_state == &"PURCHASABLE":
			return String(id)
	return String(_sim.world.block_ids_sorted()[0])


func _first_building() -> String:
	var keys := _sim.buildings.keys()
	keys.sort()
	return str(keys[0]) if not keys.is_empty() else ""


## The first building whose next level is refused on POWER, for
## `building_power_fix`. Found rather than fabricated — `cmd_upgrade_building
## (preview)` is the same gate the panel draws, so the state photographs a
## refusal the shipped city actually makes. Falls back to the first building, so
## the sweep never has a hole in it.
func _power_blocked_building() -> String:
	var keys := _sim.buildings.keys()
	keys.sort()
	for key: Variant in keys:
		var preview := _sim.cmd_upgrade_building(str(key), true)
		var blockers: Array = (preview.get("payload", {}) as Dictionary).get("blockers", [])
		if blockers.has(&"E_POWER_HEADROOM"):
			return str(key)
	return _first_building()


func _occupied_tile() -> Vector2i:
	var id := _first_building()
	if id == "":
		return Vector2i(40, 40)
	return (_sim.buildings[id] as Building).origin


## A tile the preflight is happy with, found by asking the preflight — the
## harness must never hardcode a lot the starter city might move. Only valid once
## the controller is already in placement mode, which is why it takes one.
func _valid_tile(controller: BuildController) -> Vector2i:
	var origin := _occupied_tile()
	for radius in range(1, 16):
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				var tile := origin + Vector2i(dx, dy)
				var verdict := controller.evaluate(tile)
				if StringName(str(verdict.get("verdict", ""))) \
						== BuildController.VERDICT_VALID:
					return tile
	return origin + Vector2i(2, 0)


# ---------------------------------------------------------------------------
# Audit + screenshot
# ---------------------------------------------------------------------------

func _report(screen: String) -> void:
	var touch := float(ThemeBuilder.touch_min_dp(_root.config, 1.0, false))
	var findings := UIAudit.walk(_root.safe_area, touch,
			get_viewport().get_visible_rect())
	_findings += findings.size()
	print(UIAudit.format(findings, "── %s @ %s" % [screen,
			str(get_window().size if get_window() != null else DEFAULT_SIZE)]))


## `--rects=`: what a named part of the tree actually measured. A finding names
## two rects; a FIX needs the rects of everything else sharing that column, and
## only a laid-out tree has them.
func _dump_rects(screen: String) -> void:
	print("── rects %s @ %s" % [screen,
			str(get_window().size if get_window() != null else DEFAULT_SIZE)])
	_walk_rects(_root.safe_area)


func _walk_rects(node: Node) -> void:
	var control := node as Control
	if control != null and control.visible:
		var path := UIAudit.path_of(control, _root.safe_area)
		if path.contains(_rects):
			print("  %-56s P%s S%s min%s" % [path, str(control.global_position),
					str(control.size), str(control.get_combined_minimum_size())])
	for child in node.get_children():
		_walk_rects(child)


## One state per settle window: measure it, shoot it if this run wanted a picture
## of it, then move on. The whole deck is one process loop rather than one run per
## screen because booting the sim costs more than every screen put together.
func _process(delta: float) -> void:
	_timer += delta
	_frames_since_apply += 1
	if _timer < (_shot_at if _path != "" else SETTLE_S) or _queue.is_empty():
		return
	# **Two whole frames, not just the settle window** (Wave 17, doc 98 RR-113).
	# A parent's `_process` runs before its children's, and the first frame's
	# `delta` carries the whole boot — so `--screen=<one>` used to audit on the
	# very first frame, before any sibling chip had run the `_process` that
	# yields the edge to an open panel. Measured: three single states across the
	# six gate boxes reported 46 `overlapping_targets` that `--screen=all` never
	# saw, on a tree the whole-deck sweep called clean in all eighteen of its
	# cells; after this guard, all eighteen read zero (doc 92 §46.3). A
	# single-state run is what a developer reaches for first, and it has to
	# answer the same as the sweep.
	if _frames_since_apply < MIN_FRAMES_BEFORE_MEASURE:
		return
	var screen := _queue[0]
	if _audit:
		_report(screen)
	if _rects != "":
		_dump_rects(screen)
	if _path != "":
		# `--screen=all --screenshot=DIR` writes one file per state; a single state
		# writes exactly the file it was given.
		var out := _path if _screen != "all" \
				else "%s/%s.png" % [_path.trim_suffix("/"), screen]
		var image := get_viewport().get_texture().get_image()
		image.save_png(out)
		print("screenshot saved: ", out, " (", screen, ")")
	_queue.remove_at(0)
	if _queue.is_empty():
		get_tree().quit(1 if (_strict and _findings > 0) else 0)
		return
	_timer = 0.0
	_frames_since_apply = 0
	_apply(_queue[0])
