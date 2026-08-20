extends Node
## Screenshots the VISIBLE POWER LAYER over the real game.
##
## Like `tools/overlay_preview.gd` this instantiates `game/main.tscn` — the real
## shell, the real sim, the real camera — rather than assembling a harness scene,
## and for the same reason: the question about a transformer pad is whether it
## sits right IN THE CITY, beside the road, under the streetlights, at the zoom a
## player actually uses. A backdrop cannot answer that.
##
## It also **is the integration test for the shell hook**. `PowerInfraView` is
## attached here with exactly the four lines `game/main.gd` needs (report to the
## lead, §3), against the live `main.tscn` instance — so if the snippet were
## wrong, this harness would be the thing that failed.
##
##   godot --path . tools/power_infra_preview.tscn -- --state=severe \
##       --hour=21 --out=/tmp/severe_night.png
##
##   --state=      normal | stressed | troubled | severe | failed | live
##                 Anything but `live` overrides the render rows so the look can
##                 be reviewed without waiting for the grid to cook. RENDER-SIDE
##                 ONLY: the sim is never touched and no state hash moves.
##   --hour=H      advance the shell's clock to this hour before shooting
##   --zoom=T      camera zoom_t 0..1 (0 = Z0, 0.5 = Z1, 1 = Z2). Default 0.
##   --overlay=    `power` turns doc 12 §2.5's mode 1 on
##   --incident    cook the tutorial transformer for real (doc 12 P1-38's hook)
##   --out=PATH    where the PNG lands
##   --shot-at=S   real seconds of warm-up before the shot (default 2.5)

const MESH_MANIFEST := "res://game/meshes/generated/manifest.json"

var _state := "live"
var _out := ""
var _shot_at := 2.5
var _hour := -1.0
var _zoom := 0.0
var _overlay := ""
var _incident := false
## Two A/B switches, for isolating one element of the layer in a screenshot.
var _no_wires := false
var _no_pad_shadows := false
var _timer := 0.0
var _shot := false

var _main: Node
var _sim: CitySim
var _power: PowerInfraView
var _height_of: Dictionary = {}


func _ready() -> void:
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		if arg.begins_with("--state="):
			_state = arg.trim_prefix("--state=")
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
		elif arg.begins_with("--shot-at="):
			_shot_at = float(arg.trim_prefix("--shot-at="))
		elif arg.begins_with("--hour="):
			_hour = float(arg.trim_prefix("--hour="))
		elif arg.begins_with("--zoom="):
			_zoom = clampf(float(arg.trim_prefix("--zoom=")), 0.0, 1.0)
		elif arg.begins_with("--overlay="):
			_overlay = arg.trim_prefix("--overlay=")
		elif arg == "--incident":
			_incident = true
		elif arg == "--no-wires":
			_no_wires = true
		elif arg == "--no-pad-shadows":
			_no_pad_shadows = true
	var packed: PackedScene = load("res://game/main.tscn")
	_main = packed.instantiate()
	add_child(_main)
	_arm()


func _arm() -> void:
	var host: Node = _main.get("sim_host") as Node
	_sim = host.get("sim") as CitySim if host != null else null
	var ui: UIRoot = _main.get("ui_root") as UIRoot
	if _sim == null:
		push_error("power_infra_preview: the shell did not come up")
		return
	if ui != null:
		# The tutorial owns the screen on a fresh boot and is not what this is
		# for. Same treatment `overlay_preview` gives it.
		ui.reset_onboarding()
		if ui.onboarding != null:
			ui.onboarding.visible = false
	if _hour >= 0.0:
		var now := float(_sim.clock.minute_of_day()) / 60.0
		var ahead := _hour - now
		_sim.advance_hours(ahead if ahead > 0.0 else ahead + 24.0)
	if _incident:
		_sim.trigger_tutorial_transformer_failure()

	# ══════════ the shell hook, verbatim ═══════════════════════════════════
	# These four statements are the whole of the `game/main.gd` integration.
	var render_data: Dictionary = StarterCityLoader.read_json("res://data/render.json")
	var manifest: Dictionary = StarterCityLoader.read_json(MESH_MANIFEST)
	for entry in manifest.get("meshes", []):
		if int(entry.get("lod", 0)) == 0:
			_height_of["%s:%d" % [entry["archetype"], int(entry["level"])]] = \
					float(entry.get("height_m", 10.0))
	_power = PowerInfraView.new()
	_power.name = "PowerInfra"
	_main.add_child(_power)
	_power.setup(render_data, func(archetype: StringName, level: int) -> float:
			return float(_height_of.get("%s:%d" % [archetype, level], 10.0)))
	_power.set_road_probe(PowerInfraFeed.road_probe(_sim.world))
	# ═══════════════════════════════════════════════════════════════════════

	if _no_wires:
		_power.wire_gate_m = -1.0
	if _no_pad_shadows:
		_power.set_pad_shadows(false)
	_frame_on_a_transformer()
	if _overlay == "power":
		RenderingServer.global_shader_parameter_set("sc_overlay_mode", 1)


## Park the camera on the transformer with the most customers, which is the one
## with the biggest wire fan and therefore the one worth photographing.
func _frame_on_a_transformer() -> void:
	var camera_state: CameraState = _main.get("camera_state") as CameraState
	if camera_state == null:
		return
	var best := ""
	var best_count := -1
	var customers: Dictionary = {}
	for building_id: String in _sim.grid.attachment_map():
		var host := String(_sim.grid.attachment_map()[building_id])
		customers[host] = int(customers.get(host, 0)) + 1
	for id: String in _sim.grid.component_ids_of_kind(&"transformer"):
		var count := int(customers.get(id, 0))
		if count > best_count:
			best_count = count
			best = id
	if best == "":
		return
	var tile := _sim.grid.component_tile(best)
	camera_state.set_focus(Vector3(tile.x * 8.0 + 4.0, 0.0, tile.y * 8.0 + 4.0))
	camera_state.set_zoom_t(_zoom)
	print("power_infra_preview: framed %s (%d customers) at tile %s"
			% [best, best_count, tile])


## The five looks, as render rows. `PowerInfraModel.distress_for()` classifies
## them exactly as it classifies the sim's own rows — this only decides which
## numbers arrive.
func _forced_rows() -> Array:
	var rows: Array = PowerInfraFeed.state(_sim)
	var severe := PowerInfraModel.severe_ratio()
	for row: Dictionary in rows:
		match _state:
			"normal":
				row["state"] = "OK"; row["energized"] = true
				row["load_ratio"] = 0.35; row["condition"] = 0.95
				row["temp_c"] = 34.0
			"stressed":
				row["state"] = "OK"; row["energized"] = true
				row["load_ratio"] = 0.82; row["condition"] = 0.70
				row["temp_c"] = 62.0
			"troubled":
				row["state"] = "OK"; row["energized"] = true
				row["load_ratio"] = 1.12; row["condition"] = 0.55
				row["temp_c"] = 96.0
			"severe":
				row["state"] = "OK"; row["energized"] = true
				row["load_ratio"] = severe + 0.30; row["condition"] = 0.40
				row["temp_c"] = 132.0
			"failed":
				row["state"] = "FAILED"; row["energized"] = false
				row["load_ratio"] = 0.0; row["condition"] = 0.10
				row["temp_c"] = 40.0
	return rows


func _process(delta: float) -> void:
	if _power == null or _sim == null:
		return
	var rig: CameraRig = _main.get("camera_rig") as CameraRig
	var camera_pos := rig.camera.global_position if rig != null else Vector3.ZERO
	if _state == "live":
		_power.sync(_sim, delta, camera_pos)
	else:
		# `sync` would re-poll the sim and undo the forced rows, so the two halves
		# are driven by hand: topology once, then the look every frame.
		if _power.model.pad_count() == 0:
			_power.apply_topology(PowerInfraFeed.topology(_sim,
					func(archetype: StringName, level: int) -> float:
						return float(_height_of.get("%s:%d" % [archetype, level], 10.0)),
					_power.model.tile_m))
		_power.apply_state(_forced_rows())
		_power.refresh(delta, camera_pos)
	_timer += delta
	if _shot or _out == "" or _timer < _shot_at:
		return
	_shot = true
	var image := get_viewport().get_texture().get_image()
	if image == null or image.save_png(_out) != OK:
		printerr("power_infra_preview: cannot write " + _out)
	else:
		print("wrote %s   (%d power draw calls, %d wire buckets, %d puffs)"
				% [_out, _power.draw_calls(), _power.visible_wire_bucket_count(),
				_power.live_puff_count()])
	get_tree().quit(0)
