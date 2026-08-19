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
	"build", "build_grid", "build_locked",
	"placement_ok", "placement_blocked",
	"building", "building_blocked",
	"drawer", "drawer_empty", "drawer_expanded",
	"picker", "picker_empty",
	"dashboard", "economy",
	"away", "away_short",
	"alerts", "alerts_empty",
	"overlay", "settings", "saves", "pause",
	"coach_welcome", "coach_place_house", "coach_dispatch", "coach_payoff",
]

## A `Control` does not have a size until its container has laid it out, and the
## whole point of this harness is to judge sizes — so every state gets a settle
## window before it is measured or photographed.
const SETTLE_S := 0.12

var _screen := "drawer"
var _path := ""
var _audit := false
var _strict := false
var _size := Vector2i.ZERO
var _shot_at := SHOT_AT_S
var _timer := 0.0
var _root: UIRoot
var _sim: CitySim
var _controller: BuildController
var _building_panel: BuildingPanel
var _findings := 0
var _queue: PackedStringArray = []
var _text_scale := 1.0
var _large_targets := false


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
	_sim = CitySim.boot_from_files()
	_controller = BuildController.new(_sim)
	_building_panel = _root.safe_area.get_node_or_null(
			"PanelLayer/BuildingPanel") as BuildingPanel
	if _building_panel != null:
		_building_panel.setup(_root.config, _controller)
	if _root.build_sheet != null:
		_root.build_sheet.setup(_root.config, _controller)
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
				"fines": 120.0, "gross": 13950.0},
		"expenses": {"building_maint": 4120.0, "departments": 2260.0, "fleet": 610.0,
				"vehicle_fuel": 140.0, "grid": 320.0, "generation_fuel": 830.0,
				"water": 260.0, "roads_repair": 90.0, "debt": 0.0, "total": 8630.0},
		"net": 5320.0,
	})
	_root.bind_tax(_sim.cmd_set_tax_level, _sim.tax_level(), _sim.tax_level_count(),
			_sim.tax_rate)
	_root.ingest_service({"power01": 0.93, "water01": 0.71})
	_root.refresh_dashboard(snapshot)


static func _snapshot() -> Dictionary:
	return {
		"population": 182904, "population_delta_pct_per_day": 0.4,
		"treasury": 8420000, "net_per_hour": 5750.0, "stability": 0.71,
		"happiness": 0.64, "incidents": {"count": 3, "worst_tier": 4},
		"clock": {"minute_of_day": 372, "day_index": 2}, "speed": 1, "paused": false,
	}


static func _incidents() -> Array:
	return [
		_incident(31, "structure_fire", 4.6, "Harbour", [7], 12.0, 0.0, 47.0),
		_incident(28, "transformer_failure", 3.2, "Old Town", [], 96.0, 0.0, 118.0),
		_incident(35, "water_main_break", 2.4, "Riverside", [4, 9], -1.0, 1.2, 8.0),
		_incident(12, "crime", 1.6, "Docks", [], 210.0, 0.0, 340.0),
	]


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


## Sim-bus events for the alerts centre — one of every notifiable shape, so the
## feed shows the copy the player actually reads rather than one lucky row.
static func _alert_events() -> Array:
	return [
		{"type": "BlockDarkChanged", "block_id": "Harbour", "block_dark": true},
		{"type": "PowerComponentFailed", "component": "T-04", "cause": "overload"},
		{"type": "PowerComponentTripped", "component": "F-12"},
		{"type": "LoadShedStarted", "shed_kw": 1840.0},
		{"type": "credit_line_engaged", "balance": -240000},
		{"type": "city_level_changed", "level": 3},
		{"type": "building_completed", "building": 7, "level": 2},
		{"type": "block_ready", "block_id": "B-14"},
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
		"placement_ok":
			_place_ghost(true)
		"placement_blocked":
			_place_ghost(false)
		"building":
			if _building_panel != null:
				_building_panel.show_building(_first_building())
		"building_blocked":
			if _building_panel != null:
				var b: Building = _sim.buildings[_first_building()]
				b.condition = 0.35
				_building_panel.show_building(_first_building())
		"drawer":
			_root.incident_drawer.open()
		"drawer_empty":
			_root.refresh_incidents([], 24.0)
			_root.incident_drawer.open()
		"drawer_expanded":
			_root.incident_drawer.open()
			_root.incident_drawer.row_button(31).pressed.emit()
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
		"settings":
			_root.settings_sheet.open()
		"saves":
			_root.save_load_sheet.open()
		"pause":
			_root.pause_menu.open()
		_:
			if screen.begins_with("coach_"):
				_coach(screen.trim_prefix("coach_"))
			else:
				push_error("ui_preview: unknown screen '%s'" % screen)


func _close_everything() -> void:
	if _root.build_sheet != null:
		_root.build_sheet.cancel_placement()
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
	# Banners live for `alert_ttl_s`, which is longer than a settle window — one
	# state's banners would otherwise photobomb the next four screens.
	for alert: Dictionary in _root.hud.model.active_alerts(0.0):
		_root.hud.model.dismiss_alert(str(alert["id"]))
	_root.refresh_incidents(_incidents(), 24.0)
	_root.hud.refresh(_snapshot())
	_root.ingest_service({"power01": 0.93, "water01": 0.71})


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
			{"type": "city_level_changed", "level": 3},
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


func _first_building() -> String:
	var keys := _sim.buildings.keys()
	keys.sort()
	return str(keys[0]) if not keys.is_empty() else ""


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


## One state per settle window: measure it, shoot it if this run wanted a picture
## of it, then move on. The whole deck is one process loop rather than one run per
## screen because booting the sim costs more than every screen put together.
func _process(delta: float) -> void:
	_timer += delta
	if _timer < (_shot_at if _path != "" else SETTLE_S) or _queue.is_empty():
		return
	var screen := _queue[0]
	if _audit:
		_report(screen)
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
	_apply(_queue[0])
