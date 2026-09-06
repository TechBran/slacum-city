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
##   godot --path . tools/site_paint_preview.tscn -- --state=founding_source \
##       --out=/tmp/founding_source.png
##   for s in founding_source founding_yard player_none player_three; do \
##       godot --path . tools/site_paint_preview.tscn -- --state=$s \
##           --out=/tmp/shots/$s.png; done
##
## * `--state=` — one of `STATES` below: the four named states of this layer,
##   each of which asserts the tile count it claims. Everything after it is an
##   override of that row.
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

## **The named preview states of this layer** — doc 12 D-130's deck, the way
## `tools/ui_preview.gd`'s `SCREENS` is the sheet deck's. A state that cannot be
## NAMED cannot be swept, cannot be re-shot after a change and cannot be quoted
## in a report, which is how a preview turns into an argv incantation somebody
## has to reconstruct from a commit message. Each row is exactly the flags below
## it, and `--state=` applies them before any explicit flag overrides them.
##
## `tests/test_site_paint.gd::test_every_named_preview_state_is_one_the_game_can_reach`
## drives all four headlessly — the card enters, the window answers, and the
## count is the count the row claims — so a state that stops being reachable
## fails in the suite rather than in a screenshot nobody took.
const STATES := {
	# The founding city's shoreline: three river intakes, all clean, the nearest
	# 3 tiles from the ghost at $38,086. Needs a treasury, because the city opens
	# at $24,133 and an intake is $38,086 (see `--balance=`).
	"founding_source": {
		"card": "source", "at": Vector2i(38, 51), "balance": 5_000_000,
		"expect": 3,
	},
	# A 3×3 lot, which is the case the anchor exists for: every lit tile is
	# `origin + (1, 1)`, so the tap that follows the paint centres the yard on
	# the origin the window verified rather than one tile up-left of it.
	"founding_yard": {
		"card": "construction_yard", "at": Vector2i(40, 40), "balance": 5_000_000,
		"expect": 32,
	},
	# The player's own save, ghost on his own water plant — the sentence the
	# whole read was built for. NOTHING is lit: 441 tiles scanned, 0 legal, and
	# the answer is the bar's words and the door under them, which fly the
	# camera 41 tiles to the water.
	"player_none": {"card": "source", "save": "player", "expect": 0},
	# The same save at the water, with doc 03 §2.10's freeze lifted — which the
	# game itself does at the first hourly settlement after the load. Three
	# intakes, and austerity was the only thing refusing them.
	"player_three": {
		"card": "source", "save": "player", "at": Vector2i(38, 51),
		"lift_austerity": true, "expect": 3,
	},
}

var _card := "source"
var _at := Vector2i(-1, -1)
var _radius := -1
var _out := ""
var _shot_at := 2.0
var _save := ""
var _lift_austerity := false
var _balance := -1
var _state := ""
var _expect := -1
var _timer := 0.0

var _main: Node
var _ui: UIRoot
var _sim: CitySim
var _paint_view: SitePaintView


func _ready() -> void:
	# `--state=` first, whatever order it was typed in, so an explicit flag
	# beside it is an OVERRIDE of the named state rather than a coin toss.
	for arg in OS.get_cmdline_user_args():
		var text := String(arg)
		if text.begins_with("--state="):
			_apply_state(text.trim_prefix("--state="))
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


## One row of `STATES`, applied. Unknown names are a hard error rather than a
## silent default: a screenshot of the wrong state is worse than no screenshot.
func _apply_state(name: String) -> void:
	if not STATES.has(name):
		push_error("site_paint_preview: unknown --state=%s; known: %s"
				% [name, str(STATES.keys())])
		return
	_state = name
	var row: Dictionary = STATES[name]
	_card = str(row.get("card", _card))
	_at = row.get("at", Vector2i(-1, -1))
	_save = str(row.get("save", ""))
	_balance = int(row.get("balance", -1))
	_lift_austerity = bool(row.get("lift_austerity", false))
	_expect = int(row.get("expect", -1))


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
	# The shell wires its own layer now (Wave 30 merge, RR-249): reuse it, so the
	# preview photographs ONE layer — the merge verifier caught two SitePaint
	# nodes and doubled alpha the moment the shell snippets landed.
	var existing: Variant = _main.get("site_paint_view")
	if existing != null:
		_paint_view = existing
		return
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
	# A named state that stopped showing what it is named for is a picture of a
	# regression, so it says so on stdout rather than in the image.
	if _expect >= 0 and _paint_view.tile_count() != _expect:
		push_error("site_paint_preview: state `%s` lit %d tiles, not the %d it claims"
				% [_state, _paint_view.tile_count(), _expect])
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
