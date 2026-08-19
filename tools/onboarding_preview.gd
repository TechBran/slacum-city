extends Node
## Screenshots S12's coach marks **over the real game** (doc 12 §2.17).
##
## `tools/ui_preview.gd` mounts `ui_root.tscn` on a flat backdrop, which is right
## for a drawer or a dashboard but wrong for a coach mark: the whole question
## about a cutout is whether it lands on the thing it points at, and half of
## those things are in the world. So this harness instantiates `game/main.tscn`
## itself — the actual shell, the actual sim, the actual camera — drives the
## tutorial to one step, and takes the shot. It edits nothing in `game/`.
##
##   godot --path . tools/onboarding_preview.tscn -- --coach-step=open_build \
##       --out=/tmp/coach_open_build.png --shot-at=2.5
##
## `--coach-step=` is any step id in `data/ui.json.onboarding.steps`; the harness
## walks the machine to it with the same observations the shell would produce,
## and stages the city so the picture is honest (the house is really built, the
## transformer really failed).

const TILE_M := 8.0
## Two tiles across: big enough to read as "that lot", small enough that the
## bubble still finds room outside the cutout at tutorial zoom.
const HIGHLIGHT_TILES := 2.0

var _step := "welcome"
var _out := ""
var _shot_at := 2.5
var _timer := 0.0
var _armed := false

var _main: Node
var _ui: UIRoot
var _sim: CitySim


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var text := String(arg)
		if text.begins_with("--coach-step="):
			_step = text.trim_prefix("--coach-step=")
		elif text.begins_with("--out="):
			_out = text.trim_prefix("--out=")
		elif text.begins_with("--shot-at="):
			_shot_at = float(text.trim_prefix("--shot-at="))
	var packed: PackedScene = load("res://game/main.tscn")
	_main = packed.instantiate()
	add_child(_main)
	_arm()


func _arm() -> void:
	if _armed:
		return
	_armed = true
	_ui = _main.get("ui_root") as UIRoot
	var host: Node = _main.get("sim_host") as Node
	_sim = host.get("sim") as CitySim if host != null else null
	if _ui == null or _sim == null:
		push_error("onboarding_preview: the shell did not come up")
		return
	_ui.set_onboarding_world_resolver(_world_rect)
	_ui.start_onboarding({
		"tutorial_lot_a": _tag_tile("tutorial_lot_a"),
		"tutorial_lot_b": _tag_tile("tutorial_lot_b"),
	})
	_stage()
	_walk_to(_step)
	_frame()


## The city as it would be when the player reaches this step. Only the sim is
## touched — the coach layer is never told anything the player did not do.
func _stage() -> void:
	if _step in ["place_house", "open_build", "welcome", "look_around"]:
		return
	_sim.cmd_place_building("house", _tag_tile("tutorial_lot_b"))
	if _step in ["unserved_wall", "place_transformer"]:
		return
	_sim.cmd_place_grid_component("transformer",
			_tag_tile("tutorial_lot_a") + Vector2i(-1, 0), 1)
	if _step == "blackout":
		return
	_sim.trigger_tutorial_transformer_failure()
	_sim.advance_hours(0.2)


func _walk_to(step_id: String) -> void:
	var flow: OnboardingFlow = _ui.onboarding
	var guard := 0
	while str(flow.model.current().get("id", "")) != step_id and flow.is_active():
		guard += 1
		if guard > 32:
			break
		_satisfy(flow)


func _satisfy(flow: OnboardingFlow) -> void:
	var lot_a := _tag_tile("tutorial_lot_a")
	var lot_b := _tag_tile("tutorial_lot_b")
	match str(flow.model.current().get("id", "")):
		"welcome", "payoff":
			flow.feed({"kind": "ack"})
		"look_around":
			flow.feed({"kind": "camera", "focus": Vector3.ZERO, "zoom_t": 0.4})
			flow.feed({"kind": "camera", "focus": Vector3(400.0, 0.0, 0.0), "zoom_t": 0.7})
		"open_build":
			flow.feed({"kind": "ui_opened", "path": "build_sheet"})
		"place_house":
			flow.feed({"kind": "command", "command": "place_building", "ok": true,
					"archetype": "house", "tile": lot_b})
		"unserved_wall":
			flow.feed({"kind": "verdict", "code": "E_UNSERVED", "tile": lot_a})
		"place_transformer":
			flow.feed({"kind": "command", "command": "place_grid_component", "ok": true,
					"archetype": "transformer", "tile": lot_a + Vector2i(-1, 0)})
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


## Frames the shot the way the step's own `focus_camera` request would.
func _frame() -> void:
	var camera: CameraState = _main.get("camera_state") as CameraState
	if camera == null:
		return
	var target := _tag_tile("tutorial_lot_a")
	var zoom := 0.42
	match _step:
		"welcome", "look_around":
			target = Vector2i(56, 56)
			zoom = 0.5
		"open_build", "place_house":
			target = _tag_tile("tutorial_lot_b")
		"blackout", "open_drawer", "dispatch", "relight":
			target = _tag_tile("tutorial_transformer")
			zoom = 0.46
	camera.set_focus(Vector3(target.x * TILE_M, 0.0, target.y * TILE_M))
	camera.set_zoom_t(zoom)
	# In play the sheet closes itself when the card is tapped (`BuildSheet.
	# _on_card_pressed`); the harness feeds the command straight in, so it has to
	# put the sheet away by hand or every later shot has a build sheet in it.
	if _step in ["blackout", "open_drawer", "dispatch", "relight", "payoff"]:
		_ui.build_sheet.close()


func _tag_tile(tag: String) -> Vector2i:
	var entry := _sim.loader.resolve_tag(tag)
	if entry.has("tile_global"):
		return entry["tile_global"]
	if entry.has("node"):
		var node: Dictionary = entry["node"]
		var tile: Array = node.get("tile", [0, 0])
		return StarterCityLoader.core_to_global(int(tile[0]), int(tile[1]))
	return Vector2i.ZERO


## The world half of the cutout: project a 3-tile square around the tag and take
## its screen bounding box. Returns null when the tag is off camera, which is the
## case the flow already handles by centring its bubble.
func _world_rect(tag: String) -> Variant:
	var camera: CameraState = _main.get("camera_state") as CameraState
	if camera == null:
		return null
	var tile := _tag_tile(tag)
	if tile == Vector2i.ZERO:
		return null
	var viewport := Vector2(get_viewport().get_visible_rect().size)
	var centre := Vector3(tile.x * TILE_M + TILE_M * 0.5, 0.0, tile.y * TILE_M + TILE_M * 0.5)
	var half := HIGHLIGHT_TILES * TILE_M * 0.5
	var box := Rect2()
	var first := true
	for dx in [-half, half]:
		for dz in [-half, half]:
			var answer := camera.project_to_screen(
					centre + Vector3(dx, 0.0, dz), viewport)
			if bool(answer["behind"]):
				return null
			var point: Vector2 = answer["position"]
			if first:
				box = Rect2(point, Vector2.ZERO)
				first = false
			else:
				box = box.expand(point)
	return box


func _process(delta: float) -> void:
	if _out == "":
		return
	_timer += delta
	if _timer < _shot_at:
		return
	var image := get_viewport().get_texture().get_image()
	image.save_png(_out)
	print("coach screenshot saved: ", _out, " (", _step, ")")
	get_tree().quit()
