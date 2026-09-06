extends Node
## Photographs **where a source can legally go** over the real game
## (doc 12 §2.7 D-130, doc 11 §2.20, Wave 30).
##
## `tools/ui_preview.gd` mounts `ui_root.tscn` on a flat backdrop, which is the
## right instrument for a sheet and no instrument at all for this: the whole
## question about the site paint is whether the tiles land on the GROUND, in the
## right place, under the ghost the player is dragging — and that is a question
## about the 3D city. So this harness instantiates `game/main.tscn` (the real
## shell, the real sim, the real camera), enters a card, walks the ghost onto a
## tile the command refuses, and takes the shot. Doc 12 §2.5's
## `tools/overlay_preview.gd` is the same instrument one layer over.
##
##   godot --path . tools/site_paint_preview.tscn -- --card=source \
##       --at=38,51 --out=/tmp/source_sites.png
##   godot --path . tools/site_paint_preview.tscn -- --save=player --card=source \
##       --out=/tmp/player_none.png
##   godot --path . tools/site_paint_preview.tscn -- --save=player --card=source \
##       --at=38,51 --lift-austerity --out=/tmp/player_three.png
##
## * `--card=` — any build-sheet archetype (`house`, `store`, …) or doc 05 water
##   kind (`source`, `treatment`, `pump`, `tank`).
## * `--at=X,Y` — where to stand the ghost. Default: the card's own window home
##   (`BuildController._site_home()`), which is where the game puts it.
## * `--save=player` — restore `tests/fixtures/player_save_0903` first, the city
##   the whole read was built for: **no legal tile within ten of his plant**.
## * `--lift-austerity` — clear doc 03 §2.10 layer 2's spending freeze, which on
##   that save is the ONLY thing refusing his three shoreline intakes and which
##   the game itself lifts at the first hourly settlement after the load.
## * `--radius=` — override the window, capped by `SITE_SCAN_RADIUS_MAX` (20).
## * `--balance=` — set the treasury before the scan, and SAY SO on stdout. The
##   founding city opens at **$25,000** and a river intake is **$38,086**, so
##   every tile on its shoreline refuses for `E_FUNDS` and a shot taken as the
##   game boots would photograph an empty answer and call it the paint. This
##   flag is the one thing here that changes the city, which is why it prints.
##
## ── it wires the layer the way `game/main.gd` is asked to ─────────────────
## `SitePaintView` is a `game/render/` node and the shell owns the wiring
## (report 98 §76 RR-249 carries the snippet). Until that lands, THIS is the
## only place the three lines exist, and they are the same three lines: build
## the node, `setup()` it from `BuildSheet`'s own config, and feed it
## `build_sheet.site_paint()` whenever placement changes. A preview that wired
## it differently would be photographing a layer the game does not have.

const TILE_M := 8.0
const FIXTURE := "res://tests/fixtures/player_save_0903"

var _card := "source"
var _at := Vector2i(-1, -1)
var _radius := -1
var _out := ""
var _shot_at := 2.0
var _save := ""
var _lift_austerity := false
var _balance := -1
var _timer := 0.0

var _main: Node
var _ui: UIRoot
var _sim: CitySim
var _paint_view: SitePaintView


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var text := String(arg)
		if text.begins_with("--card="):
			_card = text.trim_prefix("--card=")
		elif text.begins_with("--at="):
			var parts := text.trim_prefix("--at=").split(",")
			if parts.size() == 2:
				_at = Vector2i(int(parts[0]), int(parts[1]))
		elif text.begins_with("--radius="):
			_radius = int(text.trim_prefix("--radius="))
		elif text.begins_with("--out="):
			_out = text.trim_prefix("--out=")
		elif text.begins_with("--shot-at="):
			_shot_at = float(text.trim_prefix("--shot-at="))
		elif text.begins_with("--save="):
			_save = text.trim_prefix("--save=")
		elif text == "--lift-austerity":
			_lift_austerity = true
		elif text.begins_with("--balance="):
			_balance = int(text.trim_prefix("--balance="))
	var packed: PackedScene = load("res://game/main.tscn")
	_main = packed.instantiate()
	add_child(_main)
	_arm()


func _arm() -> void:
	_ui = _main.get("ui_root") as UIRoot
	var host: Node = _main.get("sim_host") as Node
	_sim = host.get("sim") as CitySim if host != null else null
	if _ui == null or _sim == null:
		push_error("site_paint_preview: the shell did not come up")
		return
	# The tutorial owns the screen on a fresh boot; a placement shot is not what
	# it is for, so it is skipped rather than fought with.
	_ui.reset_onboarding()
	if _ui.onboarding != null:
		_ui.onboarding.visible = false
	if _save == "player":
		if not _restore_fixture():
			push_error("site_paint_preview: the fixture did not restore")
			return
		_sim = (_main.get("sim_host") as Node).get("sim") as CitySim
	if _lift_austerity:
		_sim.treasury.austerity_active = false
		print("[site-paint] austerity freeze lifted by hand (the game lifts it at "
				+ "the first hourly settlement after a load)")
	if _balance >= 0:
		print("[site-paint] treasury set to $%d (was $%d)"
				% [_balance, int(_sim.treasury.balance)])
		_sim.treasury.balance = _balance
	_wire_paint()
	_stage()


## **The shell snippet, run here** — see this file's header. Three lines.
func _wire_paint() -> void:
	_paint_view = SitePaintView.new()
	_paint_view.name = "SitePaint"
	_main.add_child(_paint_view)
	_paint_view.setup(SitePaintModel.new(_ui.config), TILE_M)


func _restore_fixture() -> bool:
	var dest := "user://site_paint_preview"
	DirAccess.make_dir_recursive_absolute(dest)
	if _copy_tree(FIXTURE, dest) == 0:
		return false
	var service := SaveService.new()
	service.base_dir = dest
	add_child(service)
	var ok := service.load_slot(_sim, 0)
	remove_child(service)
	service.free()
	print("[site-paint] player save restored: %s  buildings=%d  balance=$%d  austerity=%s"
			% [str(ok), _sim.buildings.size(), int(_sim.treasury.balance),
			str(_sim.treasury.austerity_active)])
	return ok


func _stage() -> void:
	var sheet: BuildSheet = _ui.build_sheet
	var controller: BuildController = sheet.controller
	var entered := controller.enter(_card)
	if not bool(entered["ok"]):
		push_error("site_paint_preview: `%s` refused: %s"
				% [_card, str(entered.get("reason_code", ""))])
		return
	var home := _at
	if not TileGrid.in_bounds(home.x, home.y):
		home = Vector2i(controller.placement_sites(Vector2i(-1, -1), _radius)["centre"])
	sheet.move_ghost(Vector3((float(home.x) + 0.5) * TILE_M, 0.0,
			(float(home.y) + 0.5) * TILE_M))
	var hint := sheet.site_hint()
	var paint := sheet.site_paint()
	_paint_view.apply(paint)
	print("[site-paint] card=%s ghost=%s verdict=%s"
			% [_card, str(controller.origin),
			str(controller.verdict().get("verdict", ""))])
	print("[site-paint] window centre=%s r=%d scanned=%d legal=%d clean=%d nearest=%s d=%d cost=$%d"
			% [str(hint.get("centre", "")), int(hint.get("radius", 0)),
			int(hint.get("scanned", 0)), int(hint.get("count", 0)),
			int(hint.get("clean", 0)), str(hint.get("nearest", "")),
			int(hint.get("nearest_distance", -1)), int(hint.get("cost", 0))])
	print("[site-paint] reasons=%s" % str(hint.get("reasons", {})))
	print("[site-paint] bar: %s" % sheet.placement_issue_text())
	print("[site-paint] painted tiles=%d  draw calls=%d"
			% [_paint_view.tile_count(), _paint_view.draw_calls()])
	for raw: Variant in (paint.get("tiles", []) as Array):
		var row: Dictionary = raw
		print("    origin=%s anchor=%s glyph=%d alpha=%.3f nearest=%s"
				% [str(row["origin"]), str(row["anchor"]), int(row["glyph"]),
				float(row["alpha"]), str(row["nearest"])])
	# Put the camera over the answer if there is one, over the ghost if not —
	# a screenshot of a set the camera is not looking at proves nothing.
	var focus: Vector2i = hint.get("nearest", Vector2i(-1, -1))
	if not TileGrid.in_bounds(focus.x, focus.y):
		focus = home
	var camera: Object = _main.get("camera_state")
	if camera != null:
		camera.call("focus_on", Vector3((float(focus.x) + 0.5) * TILE_M, 0.0,
				(float(focus.y) + 0.5) * TILE_M))


func _process(delta: float) -> void:
	if _out == "":
		return
	_timer += delta
	if _timer < _shot_at:
		return
	var image := get_viewport().get_texture().get_image()
	image.save_png(_out)
	print("screenshot saved: ", _out)
	get_tree().quit()


static func _copy_tree(source: String, dest: String) -> int:
	var dir := DirAccess.open(source)
	if dir == null:
		return 0
	var copied := 0
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var from := source.path_join(entry)
		var to := dest.path_join(entry)
		if dir.current_is_dir():
			DirAccess.make_dir_recursive_absolute(to)
			copied += _copy_tree(from, to)
		else:
			if DirAccess.copy_absolute(from, to) == OK:
				copied += 1
		entry = dir.get_next()
	dir.list_dir_end()
	return copied
