class_name SitePaintModel
extends RefCounted
## **THE GHOST PAINTS WHERE A SOURCE CAN LEGALLY GO** (doc 12 §2.7 D-130,
## doc 93 §BG1, closing doc 91 `A91-D-162`).
##
## Wave 28 gave `BuildController.placement_sites()` the read the player's first
## sentence needed — *"where CAN this go"* — and `ui/build_sheet.gd` printed its
## answer as a sentence: *"3 spots for this within 10 tiles — the nearest is 3
## tiles away, $38.1K."* **Nothing painted the tiles.** `site_hint()["tiles"]`
## was an `Array[Vector2i]` of verified legal origins that no file in `game/`
## ever read, which is this project's signature defect (`A91-D-19`): authored
## behaviour with no consumer. A player told there are three spots and not shown
## which three has been told a number, not an answer.
##
## This is the headless half of the paint. It owns no legality rule, asks no
## sim and reads no clock: it turns **the window the bar already computed** into
## the per-instance rows `game/render/site_paint_view.gd` uploads, and the suite
## drives it without a viewport.
##
## ── the three things it decides ──────────────────────────────────────────
##
## **1. WHERE THE FINGER GOES — the anchor, not the origin.** `placement_sites`
## returns footprint ORIGINS (the tile `cmd_place_building` stamps from) and the
## shell's tap path is `BuildController.move_to_ground()`, which *centres* the
## footprint on the tapped tile: `origin_for_ground(p) = tile_at(p) −
## centre_offset()`. Paint the origin of a 3×3 pump and the tap that follows the
## paint lands the ghost one tile up-left of the site that was verified — the
## paint would be a lie for every footprint bigger than 1×1, and doc 05's
## roster is 2×2 and 3×3. So each row is painted on its **anchor**,
## `origin + centre_offset()`, which is by construction the one tile whose tap
## produces exactly that origin. The door the paint implies is the tap the shell
## already had (`main.gd::_handle_tap` → `BuildSheet.move_ghost`), and
## `tests/test_site_paint.gd` pins the round trip on a 1×1, a 2×2 and a 3×3.
##
## **2. WHICH MARK — the legend's own vocabulary, never a fifth glyph.** A site
## `placement_sites` calls CLEAN takes the state `normal` (`●`); a site it warns
## about — `E_TRANSFORMER_FULL`, doc 93 §BD9's "legal and not the one to
## recommend" — takes `warning` (`▲`). Those are `data/ui.json.state_glyphs`
## rows 0 and 1, the same table the overlay legend and the placement bar draw
## from, so the ground and the card can never disagree and the palette's
## colourblind variants carry the hue for free. **Colour is never the only
## channel** (§A5): hue, glyph and the alpha ramp all say the same thing, and
## the two the ramp does not carry survive greyscale.
##
## **Warned sites are the TAIL of `tiles`, and that is a contract, not a guess.**
## `placement_sites` sorts `legal` on `[warned, distance, y, x, cost]` and fills
## `tiles` in that order, so the first `clean` entries are the clean ones. This
## model reads that invariant and `tests/test_site_paint.gd` asserts it by
## re-running `evaluate()` over the painted set — the day the sort changes, the
## test says so rather than the ground quietly lying.
##
## **3. HOW BRIGHT — the fade, from the ghost.** Alpha runs from `alpha_near` at
## the ghost's own tile to `alpha_far` at the window's edge, so the sites near
## the finger are the loud ones and a 32-tile set does not read as wallpaper.
## The fade is measured from the GHOST, which moves; the sentence's "the nearest
## is N tiles away" is measured from the WINDOW CENTRE, which does not. Those
## are two different true statements about the same set, and the one the
## sentence names is marked rather than described: `nearest` gets the ring.
##
## Reads `data/ui.json.placement.site_paint` for its numbers and
## `data/ui.json.palette` for its hues. Owns no constant that is not a fallback.

## The four data states of §2.5, in `data/ui.json.state_glyphs` order. The index
## is what the view writes per instance and what `site_paint.gdshader` switches
## its mark on, so this is a wire contract — append only.
const STATE_INDEX := {
	&"normal": 0, &"warning": 1, &"critical": 2, &"offline": 3,
}

## Fallbacks for `data/ui.json.placement.site_paint`. Every one of them is a
## LOOK number, not a rule: the rule is `placement_sites`, one file over.
const DEFAULT_TILE_Y_M := 0.13
const DEFAULT_ALPHA_NEAR := 0.55
const DEFAULT_ALPHA_FAR := 0.18
const DEFAULT_WASH_FLOOR := 0.34
const DEFAULT_GLYPH_SCALE := 0.30
const DEFAULT_GLYPH_EDGE := 0.05
const DEFAULT_RING_RADIUS := 0.42
const DEFAULT_RING_WIDTH := 0.05
const DEFAULT_MAX_TILES := 64

var config: UIConfig

var _placement: Dictionary = {}
var _palette: Dictionary = {}
var _state_glyphs: Dictionary = {}
var _variant := "default"


func _init(cfg: UIConfig = null, palette_variant: String = "default") -> void:
	config = cfg if cfg != null else UIConfig.load_from_files()
	_variant = palette_variant
	_placement = config.section("placement")
	_state_glyphs = config.section("state_glyphs")
	_palette = config.palette(palette_variant)


static func load_from_files(palette_variant: String = "default") -> SitePaintModel:
	return SitePaintModel.new(UIConfig.load_from_files(), palette_variant)


## Settings ▸ colourblind palette changed. The hues are the legend's, so the
## ground follows the theme (`RoadOverlayView.set_palette_variant`'s rule, one
## layer over).
func set_palette_variant(palette_variant: String) -> void:
	_variant = palette_variant
	_palette = config.palette(palette_variant)


func palette_variant() -> String:
	return _variant


## Everything `game/render/site_paint_view.gd` needs that is not geometry.
func render_opts() -> Dictionary:
	var section: Dictionary = _placement.get("site_paint", {}) as Dictionary \
			if _placement.get("site_paint", null) is Dictionary else {}
	return {
		"tile_y_m": UIConfig.get_num(section, "tile_y_m", DEFAULT_TILE_Y_M),
		"wash_floor": UIConfig.get_num(section, "wash_floor", DEFAULT_WASH_FLOOR),
		"glyph_scale": UIConfig.get_num(section, "glyph_scale", DEFAULT_GLYPH_SCALE),
		"glyph_edge": UIConfig.get_num(section, "glyph_edge", DEFAULT_GLYPH_EDGE),
		"ring_radius": UIConfig.get_num(section, "ring_radius", DEFAULT_RING_RADIUS),
		"ring_width": UIConfig.get_num(section, "ring_width", DEFAULT_RING_WIDTH),
	}


func alpha_near() -> float:
	var section: Variant = _placement.get("site_paint", {})
	return UIConfig.get_num(section as Dictionary if section is Dictionary else {},
			"alpha_near", DEFAULT_ALPHA_NEAR)


func alpha_far() -> float:
	var section: Variant = _placement.get("site_paint", {})
	return UIConfig.get_num(section as Dictionary if section is Dictionary else {},
			"alpha_far", DEFAULT_ALPHA_FAR)


## The hard ceiling on instances, whatever `placement.site_rows` says. One more
## belt than braces: `site_rows` is already 32 and `SITE_SCAN_RADIUS_MAX` caps
## the window, but a buffer sized from data is a buffer a data edit can blow up.
func max_tiles() -> int:
	var section: Variant = _placement.get("site_paint", {})
	return maxi(1, int(UIConfig.get_num(
			section as Dictionary if section is Dictionary else {},
			"max_tiles", DEFAULT_MAX_TILES)))


## The state token a painted site carries — the legend's, so the hue and the
## glyph both come out of the shipped table.
static func state_for(clean: bool) -> StringName:
	return HudModel.STATE_NORMAL if clean else HudModel.STATE_WARNING


func glyph_index(state: StringName) -> int:
	return int(STATE_INDEX.get(state, 0))


## The glyph CHARACTER for a state, straight out of `data/ui.json.state_glyphs`
## — the same lookup `HudModel.state_glyph` makes. The view draws the mark
## procedurally (a texture page for four shapes would be four draw calls of
## bookkeeping for nothing), so this exists for the tests and for any card that
## wants to print the mark beside the sentence.
func glyph_char(state: StringName) -> String:
	return str(HudModel.STATE_GLYPH_CHARS.get(
			str(_state_glyphs.get(String(state), "")), ""))


func hue(state: StringName) -> Color:
	var hex := str(_palette.get(String(state), "#FFFFFF"))
	# LINEAR at the write (A91-D-36 / RR-91): a MultiMesh instance colour takes
	# no sRGB decode, so an authored hue handed over raw arrives lifted and the
	# ground stops matching the chip the bar draws beside it.
	return (Color(hex) if Color.html_is_valid(hex) else Color.WHITE).srgb_to_linear()


# ---------------------------------------------------------------------------
# The paint
# ---------------------------------------------------------------------------

## Turn one `BuildController.placement_sites()` answer into instance rows.
##
## `hint` is that answer verbatim — the same dictionary the placement bar
## printed its sentence from, which is the whole of requirement (2): one call,
## one window, one truth. `ghost` is `BuildController.ghost()`; `offset` is the
## controller's `centre_offset()`, which is the only thing here the model cannot
## derive for itself (it is a function of the footprint, and the footprint is the
## controller's).
##
## Returns `{visible, count, clean, nearest, centre, radius, tile_m, tile_y_m,
## tiles: [{origin, anchor, world, state, hue, glyph, alpha, distance,
## nearest}]}` —
## and `visible false` with an empty `tiles` whenever there is nothing honest to
## draw, which is what makes the view cost zero draw calls at rest.
func paint(hint: Dictionary, ghost: Dictionary, offset: Vector2i,
		tile_m: float = BuildController.TILE_M_DEFAULT) -> Dictionary:
	var out := {
		"visible": false, "count": 0, "clean": 0, "radius": 0,
		"centre": Vector2i(-1, -1), "nearest": Vector2i(-1, -1),
		"tile_m": tile_m, "tile_y_m": float(render_opts()["tile_y_m"]),
		"tiles": [] as Array[Dictionary],
	}
	if hint.is_empty():
		return out
	var origins: Array = hint.get("tiles", []) as Array
	if origins.is_empty():
		# A window that found NOTHING is not a bug and not an empty paint job —
		# it is the player's own case on `tests/fixtures/player_save_0903`, and
		# the answer to it is the bar's sentence and the door under it. The
		# ground stays clean rather than drawing a set of size zero.
		out["radius"] = int(hint.get("radius", 0))
		out["centre"] = hint.get("centre", Vector2i(-1, -1))
		return out
	var reach := maxi(1, int(hint.get("radius", 1)))
	var centre: Vector2i = hint.get("centre", Vector2i(-1, -1))
	var here: Vector2i = ghost.get("origin", centre) if bool(ghost.get("visible", false)) \
			else centre
	var nearest: Vector2i = hint.get("nearest", Vector2i(-1, -1))
	# The clean/warned split. `placement_sites` sorts `legal` on
	# `[warned, distance, y, x, cost]` and fills `tiles` in that order, so the
	# first `clean` of them are the clean ones — capped, because `clean` counts
	# the WHOLE window and `tiles` is `site_rows` of it.
	var clean_drawn := clampi(int(hint.get("clean", 0)), 0, origins.size())
	var near_a := alpha_near()
	var far_a := alpha_far()
	var limit := mini(origins.size(), max_tiles())
	var rows: Array[Dictionary] = []
	for i in limit:
		var origin: Vector2i = origins[i]
		var anchor := origin + offset
		var distance := maxi(absi(anchor.x - here.x), absi(anchor.y - here.y))
		var t := clampf(float(distance) / float(reach), 0.0, 1.0)
		var state := SitePaintModel.state_for(i < clean_drawn)
		rows.append({
			"origin": origin,
			"anchor": anchor,
			"world": Vector3((float(anchor.x) + 0.5) * tile_m, 0.0,
					(float(anchor.y) + 0.5) * tile_m),
			"state": state,
			"hue": hue(state),
			"glyph": glyph_index(state),
			"alpha": lerpf(near_a, far_a, t),
			"distance": distance,
			"nearest": origin == nearest,
		})
	out["visible"] = not rows.is_empty()
	out["tiles"] = rows
	out["count"] = int(hint.get("count", rows.size()))
	out["clean"] = clean_drawn
	out["radius"] = reach
	out["centre"] = centre
	out["nearest"] = nearest
	return out


## The tile a finger has to land on to put the ghost on `origin` — the inverse
## of `BuildController.origin_for_ground`, and the reason the paint is drawn
## where it is. Static and one line so the test can assert the identity rather
## than a picture of it.
static func anchor_of(origin: Vector2i, offset: Vector2i) -> Vector2i:
	return origin + offset
