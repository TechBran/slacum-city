extends Node
## Screen previewer for the Wave-2 UI (doc 12 S6/S7/S8/S11).
##
## `game/main.tscn` cannot show these yet — the shell that feeds them is the lead
## engineer's to wire — so this scene mounts `game/ui/ui_root.tscn` on its own,
## fills the screens with representative fixture data and screenshots one of them.
## It is a **development harness**, not a game scene: it holds no sim and it is
## not referenced by anything the player runs.
##
##   godot --path . tools/ui_preview.tscn -- --screen=drawer --screenshot=/tmp/x.png
##
## `--screen=` is one of `drawer`, `picker`, `dashboard`, `economy`, `away`.

const SHOT_AT_S := 0.6

var _screen := "drawer"
var _path := ""
var _timer := 0.0
var _root: UIRoot


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var text := String(arg)
		if text.begins_with("--screen="):
			_screen = text.trim_prefix("--screen=")
		elif text.begins_with("--screenshot="):
			_path = text.trim_prefix("--screenshot=")
	var packed: PackedScene = load("res://game/ui/ui_root.tscn")
	_root = packed.instantiate()
	_root.apply_content_scale = false
	add_child(_root)
	_root.initialize()
	_populate()


func _populate() -> void:
	var snapshot := {
		"population": 182904, "population_delta_pct_per_day": 0.4,
		"treasury": 8420000, "net_per_hour": 5750.0, "stability": 0.71,
		"happiness": 0.64, "incidents": {"count": 3, "worst_tier": 4},
		"clock": {"minute_of_day": 372, "day_index": 2}, "speed": 1, "paused": false,
	}
	if _root.hud != null:
		_root.hud.refresh(snapshot)
	_root.set_incident_locator(func(_kind: StringName, id: Variant) -> Variant:
		var tile: Vector2i = id
		return Vector3(float(tile.x) * 8.0, 0.0, float(tile.y) * 8.0))
	_root.refresh_incidents([
		_incident(31, "structure_fire", 4.6, ["Harbour"], [7], 12.0, 0.0, 47.0),
		_incident(28, "transformer_failure", 3.2, ["Old Town"], [], 96.0, 0.0, 118.0),
		_incident(35, "water_main_break", 2.4, ["Riverside"], [4, 9], -1.0, 1.2, 8.0),
		_incident(12, "crime", 1.6, ["Docks"], [], 210.0, 0.0, 340.0),
	], 24.0)
	_root.set_unit_provider(func(_incident_id: int) -> Array:
		return [
			{"id": 1, "dept": "fire", "kind": "engine", "eta_gs": 48.0, "state": "IDLE"},
			{"id": 2, "dept": "fire", "kind": "ladder", "eta_gs": 132.0,
					"state": "RETURNING"},
			{"id": 3, "dept": "utility", "kind": "utility_truck", "eta_gs": 260.0,
					"state": "ON_SCENE", "required": false},
			{"id": 4, "dept": "police", "kind": "patrol_car", "eta_gs": -1.0,
					"state": "REFIT", "frees_in_gs": 420.0},
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
	var sim := CitySim.boot_from_files()
	_root.bind_tax(sim.cmd_set_tax_level, sim.tax_level(), sim.tax_level_count(),
			sim.tax_rate)
	_root.ingest_service({"power01": 0.93, "water01": 0.71})
	_root.refresh_dashboard(snapshot)

	match _screen:
		"hud":
			pass   # everything closed: the handle, the chips and the rails
		"picker":
			_root.incident_drawer.open()
			_root.incident_drawer.row_button(31).pressed.emit()
			_root.incident_drawer.action_button("Assign", 31).pressed.emit()
		"dashboard":
			_root.city_dashboard.open(DashboardModel.TAB_OVERVIEW)
			_root.city_dashboard.row_button("treasury").pressed.emit()
		"economy":
			_root.city_dashboard.open(DashboardModel.TAB_ECONOMY)
		"away":
			_root.present_away_report({
				"elapsed_wall_s": 22320.0, "elapsed_game_minutes": 22320.0,
				"before": {"treasury": 8_420_000, "population": 182_904,
						"day_index": 2, "stability": 0.71, "happiness": 0.62},
				"after": {"treasury": 10_788_800, "population": 184_291,
						"day_index": 4, "stability": 0.68, "happiness": 0.64},
				"ledger": {"taxes": 3_120_400.0, "expenses": 751_600.0,
						"net": 2_368_800.0, "treasury_before": 8_420_000,
						"treasury_after": 10_788_800},
				"events_digest": [
					{"type": "BlockDarkChanged", "block_id": "Harbour",
							"block_dark": true},
					{"type": "PowerComponentFailed", "component": "T-04",
							"cause": "overload"},
					{"type": "building_completed", "building": 1, "level": 2},
					{"type": "building_completed", "building": 2, "level": 3},
					{"type": "building_completed", "building": 3, "level": 2},
					{"type": "city_level_changed", "level": 3},
				],
				"unresolved": [_drawer_row(31), _drawer_row(28)],
			})
		_:
			_root.incident_drawer.open()
			_root.incident_drawer.row_button(31).pressed.emit()


func _drawer_row(incident_id: int) -> Dictionary:
	return _root.incident_drawer.model.row(incident_id)


static func _incident(id: int, type_id: String, severity: float, where: Array,
		assigned: Array, eta_min: float, assist: float,
		wait_min: float) -> Dictionary:
	return {"id": id, "type": type_id, "subtype": "", "tier": int(floor(severity)),
			"severity": severity, "status": "ASSIGNED" if not assigned.is_empty()
					else "QUEUED",
			"pos": [12 + id, 20 + id], "district_id": String(where[0]),
			"wait_min": wait_min, "assigned": assigned, "assist_ratio": assist,
			"progress": 0.2, "escalation_eta_min": eta_min, "priority": 100.0,
			"pinned": false, "seen": false, "unreachable": false,
			"notification_priority": 2}


func _process(delta: float) -> void:
	if _path == "":
		return
	_timer += delta
	if _timer < SHOT_AT_S:
		return
	var image := get_viewport().get_texture().get_image()
	image.save_png(_path)
	print("screenshot saved: ", _path, " (", _screen, ")")
	get_tree().quit()
