extends Node
## Screenshots the data overlays **over the real game** (doc 12 §2.5, S13).
##
## `tools/ui_preview.gd` mounts `ui_root.tscn` on a flat backdrop, which is
## right for a sheet and wrong for an overlay: the whole question about the
## water map is whether the block downstream of a broken main actually goes
## red, and that is a question about the city. So this harness instantiates
## `game/main.tscn` — the real shell, the real sim, the real camera — breaks
## something, turns the overlay on and takes the shot. It edits nothing in
## `game/`.
##
##   godot --path . tools/overlay_preview.tscn -- --mode=water --break-main \
##       --out=/tmp/water.png --shot-at=2.5
##   godot --path . tools/overlay_preview.tscn -- --mode=traffic --hour=8 \
##       --out=/tmp/traffic.png
##   godot --path . tools/overlay_preview.tscn -- --mode=log --incident \
##       --out=/tmp/log.png
##
## `--mode=` is `water`, `traffic`, `power`, `police`, `fire`, `none` or `log`
## (the S13 sheet). POLICE and FIRE need nothing broken to be worth a look — a
## starter city with one L1 station of each covers a corner of the map and
## nothing else, which is the reading, and the §2.5 legend card prints the count
## of uncovered lots beside it.
## `--break-main` snaps the highest-capacity main in the city, which is the one
## whose loss is visible; `--incident` cooks the tutorial transformer; `--hour=`
## advances the sim to that hour of the day first, which is how you get the
## traffic map at a rush hour instead of at 3 a.m.

const TILE_M := 8.0

var _mode := "water"
var _out := ""
var _shot_at := 2.5
var _hour := -1.0
var _break_main := false
var _incident := false
var _jam := false
var _timer := 0.0

var _main: Node
var _ui: UIRoot
var _sim: CitySim


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var text := String(arg)
		if text.begins_with("--mode="):
			_mode = text.trim_prefix("--mode=")
		elif text.begins_with("--out="):
			_out = text.trim_prefix("--out=")
		elif text.begins_with("--shot-at="):
			_shot_at = float(text.trim_prefix("--shot-at="))
		elif text.begins_with("--hour="):
			_hour = float(text.trim_prefix("--hour="))
		elif text == "--break-main":
			_break_main = true
		elif text == "--incident":
			_incident = true
		elif text == "--jam":
			_jam = true
	var packed: PackedScene = load("res://game/main.tscn")
	_main = packed.instantiate()
	add_child(_main)
	_arm()


func _arm() -> void:
	_ui = _main.get("ui_root") as UIRoot
	var host: Node = _main.get("sim_host") as Node
	_sim = host.get("sim") as CitySim if host != null else null
	if _ui == null or _sim == null:
		push_error("overlay_preview: the shell did not come up")
		return
	# The tutorial owns the screen on a fresh boot; an overlay shot is not what
	# it is for, so it is skipped rather than fought with.
	_ui.reset_onboarding()
	if _ui.onboarding != null:
		_ui.onboarding.visible = false
	if _hour >= 0.0:
		var now := float(_sim.clock.minute_of_day()) / 60.0
		var delta := _hour - now
		_sim.advance_hours(delta if delta > 0.0 else delta + 24.0)
	if _break_main:
		_snap_a_main()
	if _incident:
		var inc: Object = _sim.trigger_tutorial_transformer_failure()
		if inc != null:
			_sim.advance_hours(1.0)
	# Drain what we just caused into the UI feeds, exactly as the shell's tick
	# handler would — the log is only interesting once it has something in it.
	if _main.has_method("_on_sim_batch"):
		_main.call("_on_sim_batch", _sim.bus.drain())
	_stage()


## The city's fattest main, broken at full severity with doc 06's worst tiered
## pressure delta. Deterministic: the highest capacity wins, ties by id.
func _snap_a_main() -> void:
	var ids: Array = _sim.water.edges.keys()
	ids.sort()
	var best := ""
	var best_capacity := -1.0
	for edge_id: String in ids:
		var edge: WaterEdge = _sim.water.edges[edge_id]
		if edge.capacity_m3h > best_capacity:
			best_capacity = edge.capacity_m3h
			best = edge_id
	if best == "":
		push_warning("overlay_preview: this city has no mains to break")
		return
	_sim.water.set_segment_broken(best, 1.0, "preview", -0.80)
	# The break has to be SOLVED before it shows: pressure is a per-tick answer.
	_sim.advance_hours(2.0)
	print("[overlay-preview] broke main ", best, " (", best_capacity, " m3/h)")


func _stage() -> void:
	var rail := _ui.overlay_rail
	match _mode:
		"log":
			if _ui.event_log != null:
				_ui.event_log.open()
				print("[overlay-preview] log rows: ", _ui.event_log.count())
		"none":
			pass
		_:
			if rail != null:
				rail.open()
				var verdict := rail.select(StringName(_mode))
				print("[overlay-preview] overlay ", _mode, " -> ", verdict)
	if _mode == "water":
		var dry := 0
		for sim_id: String in _sim.buildings:
			if float(_sim.water.get_water_service(sim_id).get("pressure", 1.0)) < 0.35:
				dry += 1
		print("[overlay-preview] buildings below 0.35 pressure: ", dry, " / ",
				_sim.buildings.size())
	if _mode == "traffic":
		var view: Object = _main.get("road_overlay")
		if view != null:
			print("[overlay-preview] road tiles painted: ", view.call("tile_count"),
					" active=", view.call("is_active"))


## `--jam`: a BAND SWATCH, not a simulation. The starter city at 08:00 is all
## clear/light, which proves the plumbing and shows nothing about the ramp, so
## this stamps a synthetic congestion gradient across the real road tiles —
## every band on screen at once, in the real material, at the real scale. Re-fed
## per frame because the shell republishes the honest snapshot at 1 Hz.
func _stamp_band_swatch() -> void:
	var view: Object = _main.get("road_overlay")
	if view == null or _sim.roads == null:
		return
	var rows: Array = []
	for raw: Variant in _sim.roads.snapshot.visible_edges:
		var edge: Dictionary = raw
		var tiles: Array = edge["tiles"]
		if tiles.is_empty():
			continue
		var first: Vector2i = tiles[0]
		# A diagonal ramp across the map: every band appears, in order.
		var t := clampf(float(first.x + first.y) / 160.0, 0.0, 0.999)
		rows.append({"edge_id": edge["edge_id"], "tiles": tiles, "congestion": t})
	view.call("apply_edges", rows)


func _process(delta: float) -> void:
	if _jam:
		_stamp_band_swatch()
	if _out == "":
		return
	_timer += delta
	if _timer < _shot_at:
		return
	var image := get_viewport().get_texture().get_image()
	image.save_png(_out)
	print("screenshot saved: ", _out, " (", _mode, ")")
	get_tree().quit()
