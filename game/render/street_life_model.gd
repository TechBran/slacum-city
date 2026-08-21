class_name StreetLifeModel
extends RefCounted
## What the STREET LIFE layer LOOKS like, as a pure function of the sim's own
## opportunity events (doc 11 §2.17).
##
## The sim publishes three facts about an opportunity and nothing else:
## `opportunity_spawned {id, kind, tile, reward}`, `opportunity_collected` and
## `opportunity_expired`. Everything the player sees — where on the pavement the
## crook is standing this second, which way the goat is facing, how the dog's
## legs are moving, where the marker floats, what the poof looks like — is
## DERIVED here from those three plus a hash of the id. There is no new sim
## state, no sim RNG stream, and **nothing in this file is persisted**: a save
## re-derives the same wander for the same id at the same game-minute, which is
## why the state hash cannot move. This layer is a pure event CONSUMER.
##
## TWO CLOCKS, and the split is deliberate.
##
##   * The WANDER runs on GAME-MINUTES, like doc 11 §2.12's traffic and §2.16's
##     plant. A paused city is a still city: the goat stands exactly where the
##     player left it, and a 3× city has three times as much happening. The view
##     re-syncs this clock to `GameClock.game_seconds()` whenever the caller
##     offers it, so a load or a catch-up puts the roster where the save says.
##   * The FX — the collect burst, the rising label, a body shrinking as it
##     leaves — run on REAL SECONDS. They are feedback about a TAP, not motion
##     in the world, and a `+$120` that freezes in mid-air because the player
##     paused a quarter-second after collecting is a bug, not a feature.
##
## THE WANDER IS A CLOSED FORM, not an integration, and that is the load-bearing
## decision in the file. Each opportunity gets a ring of hashed waypoints round
## its anchor, each leg gets a hashed MOVE and PAUSE duration, and the position
## at time `t` is read out of `fposmod(t, cycle)` — so it is a pure function of
## `(id, elapsed)`. Nothing drifts across a frame-rate change, a pause, a
## re-sync or a save; the same id walks the same path on every device, and
## `tests/test_street_life.gd` asserts exactly that by sampling one id twice
## through two differently-stepped clocks.
##
## THE GAITS ARE THE CHARACTERISATION. A crook SKULKS — a long wait and a short
## fast dash, head turning while it waits. A dog TROTS — barely a pause, the
## diagonal legs swinging, tail going. A goat BROWSES — a long head-down pause,
## an amble, and now and then a straight-legged hop, which is what goats do. The
## three read differently at Z1 from their timing alone, before any triangle of
## their bodies is resolvable.
##
## Node-free (`RefCounted`) and clock-injected, for the reason `ConstructionActivity`
## is: the whole model can be driven a thousand frames in microseconds by a
## headless test, and the view above it does nothing but upload what it says.

# ------------------------------------------------------------------- kinds

const KIND_CROOK := 0
const KIND_DOG := 1
const KIND_GOAT := 2
## A dropped stash — no body at all, a sparkle and a `$`. It is here because the
## cheapest opportunity to draw is also a good one to have: it varies the street
## without a fourth MultiMesh.
const KIND_STASH := 3
const KIND_COUNT := 4

const STATE_LIVE := 0
const STATE_COLLECTED := 1
const STATE_EXPIRED := 2

## The names the sim may use, and the body each one draws. Unknown kinds fall
## through to the stash: a marker and a sparkle are true of ANY opportunity,
## whereas guessing "goat" for an event this layer has never heard of would put
## livestock on the street because a string was typo'd.
const KIND_NAMES := {
	"petty_crime": KIND_CROOK,
	"crook": KIND_CROOK, "thief": KIND_CROOK, "burglar": KIND_CROOK,
	"mugger": KIND_CROOK, "vandal": KIND_CROOK, "crime": KIND_CROOK,
	"dog": KIND_DOG, "stray": KIND_DOG, "stray_dog": KIND_DOG,
	"animal": KIND_DOG, "loose_dog": KIND_DOG, "loose_animal": KIND_DOG,
	"goat": KIND_GOAT, "loose_goat": KIND_GOAT, "livestock": KIND_GOAT,
	"stash": KIND_STASH, "valuables": KIND_STASH, "cash": KIND_STASH,
	"glint": KIND_STASH, "lost_cash": KIND_STASH, "lost_valuables": KIND_STASH,
}

## Marker glyph per kind — `!` for the crook, a paw for the dog, a bell for the
## goat, `$` for a stash.
const KIND_GLYPH := [
	StreetGlyphAtlas.G_BANG, StreetGlyphAtlas.G_PAW,
	StreetGlyphAtlas.G_BELL, StreetGlyphAtlas.G_CASH,
]

## Crown of each body, metres — where the marker hangs from.
const KIND_TOP_M := [
	StreetLifeMesh.CROOK_TOP_M, StreetLifeMesh.DOG_TOP_M,
	StreetLifeMesh.GOAT_TOP_M, 0.30,
]

# ------------------------------------------------- the fx buffer's mode codes

## `street_fx.gdshader`'s `INSTANCE_CUSTOM.r`. Five effects, one buffer, one
## draw call — the whole reason this layer costs four calls and not seven.
const FX_MARKER := 0.0
const FX_PUFF := 1.0
const FX_RING := 2.0
## The `.a` channel changes meaning on this one: a glyph carries its SLOT in the
## label (`i − (n−1)/2`) where the others carry a hashed phase, and the shader
## steps the run apart along the billboard's own +X. See `_emit_label`.
const FX_GLYPH := 3.0
const FX_SPARKLE := 4.0
## The BLOB SHADOW under a body — the sixth mode and the only one that is not a
## billboard. It rides the same buffer for the same reason the other five do:
## a contact shadow is a flat alpha-blended quad that writes no depth, so making
## it a sixth MODE costs a `mix` in the vertex stage and a mask in the fragment
## stage, while making it a fifth BUFFER would cost a draw call — and the whole
## claim of this layer is that it costs four.
const FX_BLOB := 5.0

# ------------------------------------------------------------------- tuning

var tile_m := 8.0
## Top of the footway — `road_surface.asphalt_top_m + kerb_height_m`. A body
## snapped to a kerb line stands on this; a body with no street in reach stands
## on the block, which this renderer draws flat at y = 0.
var walk_top_m := 0.25
## Top of the CARRIAGEWAY — `road_surface.asphalt_top_m`. The ground a body
## stands on when its tile is a road with no kerb anywhere on it (the middle of
## a junction, which has four road neighbours and therefore no footway at all).
## Before this existed such a body stood at y = 0, which is **ten centimetres
## inside the asphalt it is standing on**: invisible on the body itself, whose
## feet are a dark box against a dark road, and fatal to a blob shadow, which is
## a flat disc and was being depth-buried under the road it belonged to. It is
## the same defect report NIGHT-1 found under the lamp pools, in the same
## 0.10 m, and it is fixed here for the same reason.
var road_top_m := 0.10
var walk_width_street_m := 1.40
var walk_width_avenue_m := 1.05
## Metres of wander around the anchor. Small on purpose: the player has to be
## able to come back to a thing they saw and still find it.
var wander_radius_m := 2.9
## How much of that radius survives ACROSS a kerb line. A crook pacing a
## pavement paces ALONG it; the same ellipse turned loose across an 8 m road
## puts him in the middle of the carriageway.
var wander_across := 0.30
var waypoints := 5
## Metres of travel per full stride cycle, per kind.
var stride_m: Array[float] = [1.35, 1.05, 1.15, 1.0]
## Move and pause seconds per leg, per kind — the gait table, and the single
## place the three characterisations live. Game-minutes; at 1× a game-minute is
## a real second, so the crook waits a second and a half and crosses his patch
## in under one, the dog barely stops at all, and the goat spends two seconds
## with its head down for every one and a half it spends moving.
var gait_move_gm: Array[float] = [0.90, 1.10, 1.55, 1.0]
var gait_pause_gm: Array[float] = [1.55, 0.34, 1.95, 1.0]

## Bodies are not drawn past this; markers are.
var body_radius_m := 240.0
var visible_radius_m := 430.0
## The marker holds an angular size instead of a metric one, so it is the same
## number of screen pixels at Z0 as it is at Z1 — which is the whole
## "a player scrubbing around their town can actually SEE them" requirement.
## `marker_angular` is `metres of marker per metre of camera distance`; the
## clamps stop it becoming a postage stamp at Z0 or a billboard at Z2.
var marker_angular := 0.0310
var marker_min_m := 0.95
var marker_max_m := 3.30
var marker_gap_m := 0.62
var marker_bob_m := 0.13
var marker_bob_hz := 0.44
var marker_fade_begin_m := 150.0
var marker_far_alpha := 0.30
var body_fade_m := 45.0

## Seconds of each leaving animation, and of the poof over it.
var collect_s := 0.62
var expire_s := 0.70
var burst_s := 0.58
var label_s := 1.35
## How far the `+$N` climbs, as a MULTIPLE OF THE MARKER SIZE rather than in
## metres. The marker already holds a screen size, so tying the rise to it makes
## the label travel the same number of screen pixels at Z0 as at Z1 — an
## authored 1.55 m is a hand's width at Z0 and a twitch at Z1.
var label_rise_frac := 0.85
var label_glyph_frac := 0.50
var label_pitch_frac := 0.66
## Metres an animal bounds away as it goes.
var bound_m := 3.2

## THE CROOK LEGS IT. An animal bounds off the moment it is collected; a crook
## RUNS, and then is caught — a short dash down the pavement and only then the
## cuff-flash. It is the same two facts every other kind carries (something
## left, you were paid) told in the order the fiction wants them, and it costs
## one extra float on the record and no new buffer, no new event and no new
## clock.
##
## THE ORDER MATTERS AND IT IS DELIBERATE. The `+$N` rises at the TAP, not at
## the cuff — doc 93 §T1's rule is that a value transfer has a sensory surface
## **at the moment it lands**, and the money lands when the player's finger does.
## The POOF waits for the cuff, because a poof is a physical event and the
## physical event is the arrest. So the beat reads: tap → number → he runs →
## he is taken. Half a second, and it is the difference between collecting a
## token and catching somebody.
##
## Seconds, hashed per id between the two. Fast enough that the layer's own
## `max_live` slack still covers a collect and its replacement.
var flee_s_min := 0.40
var flee_s_max := 0.70
## Metres of that dash. 3.6 m over ~0.55 s is a sprint and it is meant to be:
## the read is PANIC, and a crook who jogs looks like a crook out for a walk.
var flee_m := 3.6

## BLOB SHADOWS (doc 11 §2.11's `blob_shadow`). A cheap dark decal under each
## body, drawn ONLY where the preset has switched real shadows off — which is
## every preset but High, so on a phone this is the whole of the contact shadow
## these bodies get. Without it a crook at Z0 reads as a decal printed on the
## pavement rather than as a person standing on it; `vehicle_shadows` is the
## knob, and this is what fills the hole it leaves.
##
## The numbers are `data/render.json`'s `blob_shadow` block — the same block
## §2.11's building decal reads, because a shadow is a shadow and two tables
## would drift.
var blob_enabled := false
var blob_y_m := 0.04
var blob_scale := 1.15
var blob_alpha := 0.35
var blob_night_fade := 0.6
## Ground DIAMETER of each body, metres — the disc the blob is sized off. The
## crook is the narrowest thing here and the goat the widest; a stash has no
## body and therefore no shadow.
var blob_body_m: Array[float] = [0.62, 0.78, 0.82, 0.0]
## How much of the blob survives as the body leaves the ground. An animal's
## bound lifts it 0.55 m and a shadow that stayed solid under it would nail the
## goat to the pavement it has just jumped off.
var blob_lift_m := 0.60

## Pool ceilings. The sim caps live opportunities well below `max_live`; the
## slack is for the frame on which one is collected and its replacement spawns.
var max_live := 8
var max_bursts := 6
var max_labels := 6
var puffs_per_burst := 6

## Coat colours, indexed by kind, jittered per id.
var coat: Array[Color] = [
	Color(0.20, 0.21, 0.26),    # the crook's hoodie — near black, so the pale
								# swag bag is the thing that reads
	Color(0.55, 0.42, 0.27),    # a brown stray
	Color(0.86, 0.85, 0.80),    # a white goat
	Color(0.80, 0.72, 0.40),
]
var marker_tint: Array[Color] = [
	Color(0.95, 0.32, 0.26),    # ! — the crook is the urgent one
	Color(0.42, 0.72, 0.96),    # paw
	Color(0.55, 0.84, 0.44),    # bell
	Color(1.00, 0.80, 0.24),    # $
]
var label_tint := Color(1.00, 0.86, 0.34)

## The same colours, CONVERTED TO LINEAR, and this is not a detail — it is the
## difference between the authored red and a pale salmon.
##
## Every colour above is authored the way a human picks one: an sRGB hex in
## `data/render.json`. A shader uniform hinted `source_color` is converted for
## free, and `StandardMaterial3D.albedo_color` is too — but a **MultiMesh
## INSTANCE COLOUR is neither.** It arrives in the shader exactly as written and
## is used as a linear value, so an authored `#F25242` renders as if it were
## linear (0.95, 0.32, 0.26), which displays at roughly sRGB (250, 165, 150).
## The marker came out the colour of a plaster.
##
## Converted once here rather than per frame: `srgb_to_linear` allocates, and
## this layer writes a colour per instance per frame.
##
## OPEN, for the lead: `VehicleView` and `ConstructionVehicleView` pass their
## authored liveries into `set_instance_color` raw, so every vehicle and every
## machine in the city has the same latent lift. It reads as a deliberately
## chalky palette rather than as a bug, which is why it is filed and not fixed
## from this branch.
var coat_linear: Array[Color] = []
var marker_linear: Array[Color] = []
var label_linear := Color.WHITE

# -------------------------------------------------------------------- state

## `id -> Op`, and a stable ascending id order so the emitted buffers are the
## same on every device — a MultiMesh slice's contents must not depend on a
## Dictionary's iteration order.
var ops: Dictionary = {}
var _order: Array[int] = []
var _road_probe: Callable = Callable()

var _gm := 0.0
var _real_s := 0.0

## Live census, refreshed by `refresh`.
var body_used: Array[int] = [0, 0, 0, 0]
var fx_used := 0
var marker_used := 0
var label_used := 0
var burst_used := 0
var blob_used := 0

var body_poses: Array = [[], [], [], []]
var fx_poses: Array = []


class Pose extends RefCounted:
	var basis := Basis()
	var origin := Vector3.ZERO
	var tint := Color.WHITE
	var custom := Color(0.0, 0.0, 0.0, 0.0)


class Op extends RefCounted:
	var id := 0
	var kind := KIND_STASH
	var tile := Vector2i.ZERO
	var reward := 0
	var state := STATE_LIVE
	## Anchor of the wander, already snapped to a kerb line where one was
	## offered, and the ground it stands on.
	var anchor := Vector3.ZERO
	## Unit XZ direction the wander is ELONGATED along — the kerb line, when
	## there is one.
	var along := Vector3(1.0, 0.0, 0.0)
	var snapped := false
	## Game-minutes at spawn, and real seconds at the moment it stopped being
	## live. The two clocks meet here and nowhere else.
	##
	## `born_gm` is the sim's own `born_gm` where the payload carried one, and
	## only this layer's clock reading where it did not. That distinction is the
	## whole of render q2: the wander is a pure function of `(id, now − born)`,
	## so a body re-seeded after a COLD LOAD anchors its beat to the minute it
	## actually appeared instead of to the minute the save was opened, and the
	## crook is standing where the save says rather than back on his first
	## waypoint. See `spawn`.
	var born_gm := 0.0
	var ended_s := -1.0
	## Seconds of FLEE before the cuff-flash, or 0 for anything that does not
	## run. Resolved at COLLECT rather than at spawn: an expiry is a crook who
	## was never caught, and he does not run from nobody.
	var flee_s := 0.0
	## Unit XZ the dash goes along, and where it ends. Frozen at collect so the
	## dash is a pure function of `(id, elapsed since the tap)` exactly as the
	## wander is a pure function of `(id, elapsed since spawn)`.
	var flee_dir := Vector3(1.0, 0.0, 0.0)
	var flee_from := Vector3.ZERO
	## The wander, resolved once: waypoints, per-leg lengths, per-leg timings.
	var path: PackedVector3Array = PackedVector3Array()
	var leg_len: PackedFloat32Array = PackedFloat32Array()
	var leg_cum: PackedFloat32Array = PackedFloat32Array()
	var move_gm := 1.0
	var pause_gm := 1.0
	var cycle_gm := 1.0
	var loop_len := 1.0
	var phase := 0.0
	var coat := Color.WHITE
	## Last pose the wander produced, kept so a body that is LEAVING carries on
	## from where it was rather than snapping back to its anchor.
	var last_pos := Vector3.ZERO
	var last_head := 0.0
	var marker_pos := Vector3.ZERO
	var marker_size := 0.0


# --------------------------------------------------------------- public API

func _init() -> void:
	# The pools and the baked palette exist before `configure` does, so a caller
	# that never configures still draws with the shipping numbers rather than
	# drawing nothing.
	_bake_colours()
	_reserve()


## `cfg` is `data/render.json` → `street_life`; `roads` is its `road_surface`
## block, which owns the footway numbers this layer stands its bodies on. Every
## key is optional — the values above are the shipping ones, so the layer works
## against a render.json that has never heard of it.
##
## `blob` is `data/render.json` → `blob_shadow`, the LOOK of a contact shadow.
## Whether one is drawn at all is not in it and must not be: that answer is the
## preset's `vehicle_shadows`, and `StreetLifeView.set_preset` pushes it through
## `set_blob_shadows`. One knob, one shadow — real where the tier can afford
## one, faked where it cannot, never both and never neither.
func configure(cfg: Dictionary, roads: Dictionary, p_tile_m: float,
		blob: Dictionary = {}) -> void:
	tile_m = p_tile_m
	blob_y_m = _num(blob, "y_m", blob_y_m)
	blob_scale = _num(blob, "footprint_scale", blob_scale)
	# `body_alpha` first, `alpha` as the fallback. The two are different numbers
	# on purpose: §2.11's building decal is a 12 m footprint under a mass that
	# blocks the sky, and 0.35 is right for it; a 0.7 m disc under a person is a
	# tenth of the screen area and 0.35 of it, on a shaded carriageway, measured
	# as nothing at all. This is the art call and it is documented in the block.
	blob_alpha = _num(blob, "body_alpha", _num(blob, "alpha", blob_alpha))
	blob_night_fade = _num(blob, "night_fade", blob_night_fade)
	blob_lift_m = _num(blob, "body_lift_m", blob_lift_m)
	if blob.has("body_m"):
		blob_body_m = _floats(blob["body_m"], blob_body_m)
	road_top_m = _num(roads, "asphalt_top_m", 0.10)
	walk_top_m = road_top_m + _num(roads, "kerb_height_m", 0.15)
	walk_width_street_m = _num(roads, "sidewalk_width_street_m", walk_width_street_m)
	walk_width_avenue_m = _num(roads, "sidewalk_width_avenue_m", walk_width_avenue_m)
	wander_radius_m = _num(cfg, "wander_radius_m", wander_radius_m)
	wander_across = _num(cfg, "wander_across_frac", wander_across)
	waypoints = maxi(3, int(cfg.get("waypoints", waypoints)))
	body_radius_m = _num(cfg, "body_radius_m", body_radius_m)
	visible_radius_m = _num(cfg, "visible_radius_m", visible_radius_m)
	marker_angular = _num(cfg, "marker_angular", marker_angular)
	marker_min_m = _num(cfg, "marker_min_m", marker_min_m)
	marker_max_m = _num(cfg, "marker_max_m", marker_max_m)
	marker_gap_m = _num(cfg, "marker_gap_m", marker_gap_m)
	marker_bob_m = _num(cfg, "marker_bob_m", marker_bob_m)
	marker_bob_hz = _num(cfg, "marker_bob_hz", marker_bob_hz)
	marker_fade_begin_m = _num(cfg, "marker_fade_begin_m", marker_fade_begin_m)
	marker_far_alpha = _num(cfg, "marker_far_alpha", marker_far_alpha)
	body_fade_m = _num(cfg, "body_fade_m", body_fade_m)
	collect_s = _num(cfg, "collect_s", collect_s)
	expire_s = _num(cfg, "expire_s", expire_s)
	burst_s = _num(cfg, "burst_s", burst_s)
	label_s = _num(cfg, "label_s", label_s)
	label_rise_frac = _num(cfg, "label_rise_frac", label_rise_frac)
	label_glyph_frac = _num(cfg, "label_glyph_frac", label_glyph_frac)
	label_pitch_frac = _num(cfg, "label_pitch_frac", label_pitch_frac)
	bound_m = _num(cfg, "bound_m", bound_m)
	flee_m = _num(cfg, "flee_m", flee_m)
	if cfg.has("flee_s"):
		var span: Array[float] = _floats(cfg["flee_s"], [flee_s_min, flee_s_max])
		flee_s_min = maxf(0.0, span[0])
		flee_s_max = maxf(flee_s_min, span[1])
	max_live = maxi(1, int(cfg.get("max_live", max_live)))
	max_bursts = maxi(1, int(cfg.get("max_bursts", max_bursts)))
	max_labels = maxi(1, int(cfg.get("max_labels", max_labels)))
	puffs_per_burst = maxi(1, int(cfg.get("puffs_per_burst", puffs_per_burst)))
	if cfg.has("gait_move_gm"):
		gait_move_gm = _floats(cfg["gait_move_gm"], gait_move_gm)
	if cfg.has("gait_pause_gm"):
		gait_pause_gm = _floats(cfg["gait_pause_gm"], gait_pause_gm)
	if cfg.has("stride_m"):
		stride_m = _floats(cfg["stride_m"], stride_m)
	const COAT_KEYS := ["crook_coat", "dog_coat", "goat_coat", "stash_coat"]
	const MARKER_KEYS := ["crook_marker", "dog_marker", "goat_marker", "stash_marker"]
	for i in KIND_COUNT:
		if cfg.has(COAT_KEYS[i]):
			coat[i] = Color(String(cfg[COAT_KEYS[i]]))
		if cfg.has(MARKER_KEYS[i]):
			marker_tint[i] = Color(String(cfg[MARKER_KEYS[i]]))
	if cfg.has("label_tint"):
		label_tint = Color(String(cfg["label_tint"]))
	_bake_colours()
	_reserve()


## sRGB → linear, once, for every colour that will ride an instance buffer.
func _bake_colours() -> void:
	coat_linear.clear()
	marker_linear.clear()
	for i in KIND_COUNT:
		coat_linear.append((coat[i] as Color).srgb_to_linear())
		marker_linear.append((marker_tint[i] as Color).srgb_to_linear())
	label_linear = label_tint.srgb_to_linear()


## `func(tile: Vector2i) -> int`, answering `TileGrid.ROAD_*`. Optional: without
## it nothing snaps to a kerb and every body wanders its own tile, which is what
## a preview harness with no city wants.
func set_road_probe(probe: Callable) -> void:
	_road_probe = probe
	for id: int in _order:
		var op: Op = ops[id]
		_anchor(op)
		_lay_out(op)


## Whether a body gets a faked contact shadow. The view pushes the preset's
## `vehicle_shadows` here INVERTED — blob when real is off — so the two can
## never both be on and can never both be off.
func set_blob_shadows(enabled: bool) -> void:
	blob_enabled = enabled


func set_game_minutes(value: float) -> void:
	_gm = value


func game_minutes() -> float:
	return _gm


## Advance both clocks. `gm_per_s` is game-minutes per real second (0 while
## paused); `game_minutes` pins the wander to the save's own clock, or -1 to
## free-run.
func advance(dt_s: float, gm_per_s: float, game_minutes: float = -1.0) -> void:
	_real_s += maxf(dt_s, 0.0)
	_gm += maxf(dt_s, 0.0) * maxf(gm_per_s, 0.0)
	if game_minutes >= 0.0 and absf(game_minutes - _gm) > 2.0:
		_gm = game_minutes


# ------------------------------------------------------------------ events

## One sim batch. Unknown event types are ignored, and a payload missing the
## fields this layer needs is ignored rather than guessed at — a renderer that
## invents a tile draws a goat somewhere nobody tapped.
func feed_events(batch: Array) -> void:
	for event: Variant in batch:
		if not (event is Dictionary):
			continue
		var e: Dictionary = event
		match StringName(String(e.get("type", ""))):
			&"opportunity_spawned":
				# `born_gm` is doc 06 §2.16's spawn game-minute, carried on the
				# payload since render q2. A build whose sim predates it sends
				# no such key, and -1 puts the wander on this layer's own clock
				# exactly as it always was.
				spawn(int(e.get("id", -1)), String(e.get("kind", "")),
						_tile_of(e.get("tile", null)), int(e.get("reward", 0)),
						float(e.get("born_gm", -1.0)))
			&"opportunity_collected":
				collect(int(e.get("id", -1)), int(e.get("reward", -1)))
			&"opportunity_expired":
				expire(int(e.get("id", -1)))


## `born_gm` < 0 means "this is happening now" — the live path, where the event
## arrives in the frame the sim spawned it. A value >= 0 is the sim's own spawn
## minute, and it is what a COLD LOAD hands over: `seed_roster` replays a
## restored roster whose rows are hours old, and anchoring each body to the
## minute it really appeared is the difference between a save that restores the
## street and one that restarts it.
func spawn(id: int, kind_name: String, tile: Vector2i, reward: int,
		born_gm: float = -1.0) -> void:
	if id < 0:
		return
	if ops.has(id):
		# A respawn of a live id is the sim correcting itself; take the new one.
		_drop(id)
	if _order.size() >= max_live:
		# The oldest LEAVING record goes first; failing that, the oldest live
		# one. Dropping the newest would hide the thing that just appeared.
		_evict()
		if _order.size() >= max_live:
			return
	var op := Op.new()
	op.id = id
	op.kind = kind_of(kind_name)
	op.tile = tile
	op.reward = maxi(0, reward)
	op.born_gm = born_gm if born_gm >= 0.0 else _gm
	op.phase = VehicleMotion.hash01(id, 17)
	var tone := (VehicleMotion.hash01(id, 23) - 0.5) * 0.16
	var base: Color = coat_linear[op.kind]
	op.coat = Color(clampf(base.r + tone, 0.0, 1.0), clampf(base.g + tone, 0.0, 1.0),
			clampf(base.b + tone, 0.0, 1.0))
	op.move_gm = gait_move_gm[op.kind] * (0.82 + 0.36 * VehicleMotion.hash01(id, 31))
	op.pause_gm = gait_pause_gm[op.kind] * (0.78 + 0.44 * VehicleMotion.hash01(id, 37))
	ops[id] = op
	_anchor(op)
	_lay_out(op)
	op.last_pos = op.anchor
	_order.append(id)
	_order.sort()


func collect(id: int, reward: int = -1) -> void:
	var op: Op = ops.get(id)
	if op == null or op.state != STATE_LIVE:
		return
	if reward >= 0:
		op.reward = reward
	op.state = STATE_COLLECTED
	op.ended_s = _real_s
	_arm_flee(op)


func expire(id: int) -> void:
	var op: Op = ops.get(id)
	if op == null or op.state != STATE_LIVE:
		return
	op.state = STATE_EXPIRED
	op.ended_s = _real_s


## THE CROOK LEGS IT — which way, and for how long.
##
## **Along the street, and the street is the exit.** A body snapped to a kerb
## already carries `along`, the direction of the footway it is standing on; the
## nearest road exit a man on a pavement has IS that pavement, and a flee across
## the carriageway would be a flee into traffic. The id picks the SIGN, so two
## crooks caught on the same corner do not both run the same way — and the same
## crook runs the same way on every device and after every load, because the
## hash is the id's and nothing here is random.
##
## An unsnapped body (no road probe, or a lot with no street in reach) has no
## kerb line to run down, so it takes a hashed compass bearing instead. It is
## the honest answer: there is no street to head for.
func _arm_flee(op: Op) -> void:
	if op.kind != KIND_CROOK or flee_m <= 0.0:
		op.flee_s = 0.0
		return
	op.flee_s = lerpf(flee_s_min, flee_s_max, VehicleMotion.hash01(op.id, 43))
	op.flee_from = op.last_pos
	if op.snapped:
		var sign_h := 1.0 if VehicleMotion.hash01(op.id, 47) < 0.5 else -1.0
		op.flee_dir = op.along * sign_h
	else:
		var a := VehicleMotion.hash01(op.id, 47) * TAU
		op.flee_dir = Vector3(cos(a), 0.0, sin(a))


## Re-seed the whole roster from the sim's own `OpportunitySystem.live()` rows —
## the COLD LOAD path, and the reason `born_gm` exists.
##
## A loaded save restores the sim's roster silently: no `opportunity_spawned` is
## emitted for a row that was already there, so without this call the crook the
## player was walking toward is on the sim's books, is tappable, is paying, and
## is INVISIBLE until it expires. This replays the roster as spawns with each
## row's real spawn minute, so every body is standing exactly where the save
## says rather than back on its first waypoint.
##
## Rows are the sim's shape (`tile_x` / `tile_y` / `kind` / `reward` /
## `born_gm`), read defensively — a row missing `born_gm` is a pre-render-q2
## save and falls back to this layer's clock, which is the old behaviour and
## not a crash.
func seed_roster(rows: Array) -> void:
	clear()
	for raw: Variant in rows:
		if not (raw is Dictionary):
			continue
		var row: Dictionary = raw
		spawn(int(row.get("id", -1)), String(row.get("kind", "")),
				Vector2i(int(row.get("tile_x", 0)), int(row.get("tile_y", 0))),
				int(row.get("reward", 0)), float(row.get("born_gm", -1.0)))


func clear() -> void:
	ops.clear()
	_order.clear()
	for k in KIND_COUNT:
		body_used[k] = 0
	fx_used = 0
	marker_used = 0
	label_used = 0
	burst_used = 0
	blob_used = 0


# ------------------------------------------------------------------ queries

## Where the shell should aim a tap: the marker's centre, bob included, in world
## space. `Vector3.INF` when this layer is not drawing that id.
func marker_world_pos(id: int) -> Vector3:
	var op: Op = ops.get(id)
	if op == null or op.state != STATE_LIVE or op.marker_size <= 0.0:
		return Vector3.INF
	return op.marker_pos


## The marker's world RADIUS, so the shell can size its tap target off the thing
## the player is actually aiming at rather than off a constant.
func marker_radius_m(id: int) -> float:
	var op: Op = ops.get(id)
	return 0.0 if op == null else op.marker_size * 0.5


## Ids this layer is currently drawing a live marker for, ascending.
func live_ids() -> Array[int]:
	var out: Array[int] = []
	for id: int in _order:
		if (ops[id] as Op).state == STATE_LIVE:
			out.append(id)
	return out


## Where the BODY is standing this frame — the crook's own feet, not the marker
## over his head. `Vector3.INF` for an id this layer does not hold.
func body_world_pos(id: int) -> Vector3:
	var op: Op = ops.get(id)
	return Vector3.INF if op == null else op.last_pos


func census() -> Dictionary:
	return {
		"live": live_ids().size(),
		"held": _order.size(),
		"crook": body_used[KIND_CROOK], "dog": body_used[KIND_DOG],
		"goat": body_used[KIND_GOAT],
		"markers": marker_used, "labels": label_used, "bursts": burst_used,
		"blobs": blob_used, "fx": fx_used,
	}


static func kind_of(name: String) -> int:
	return int(KIND_NAMES.get(name.to_lower(), KIND_STASH))


# ------------------------------------------------------------------- frame

## Rebuild every pose array from the roster. `camera_pos` drives the distance
## gate and the marker's angular size; pass `Vector3.INF` to disable both, which
## is what the headless tests do.
func refresh(camera_pos: Vector3) -> void:
	for k in KIND_COUNT:
		body_used[k] = 0
	fx_used = 0
	marker_used = 0
	label_used = 0
	burst_used = 0
	blob_used = 0
	var gated := camera_pos != Vector3.INF
	var retire: Array[int] = []
	for id: int in _order:
		var op: Op = ops[id]
		var leaving := op.state != STATE_LIVE
		var since := _real_s - op.ended_s
		# The DASH comes first and the cuff-flash after it, so every clock below
		# that belongs to the LEAVING (the shrink, the poof) is measured from the
		# end of the dash and not from the tap. `flee_s` is 0 for everything that
		# does not run, and this is then exactly the arithmetic it always was.
		var flee01 := 1.0
		var fx_t := 0.0
		if leaving:
			if op.flee_s > 0.0:
				flee01 = clampf(since / op.flee_s, 0.0, 1.0)
			var span := collect_s if op.state == STATE_COLLECTED else expire_s
			fx_t = clampf((since - op.flee_s) / maxf(span, 0.0001), 0.0, 1.0)
		# The LABEL is the one thing that still runs from the tap: the money
		# landed when the finger did (doc 93 §T1), so the `+$N` does not wait for
		# an arrest.
		var label_done := op.state != STATE_COLLECTED or since >= label_s
		var burst_done := not leaving or (since - op.flee_s) >= burst_s
		if leaving and fx_t >= 1.0 and label_done and burst_done:
			retire.append(id)
			continue
		_emit(op, camera_pos, gated, leaving, fx_t, flee01)
	for id2: int in retire:
		_drop(id2)


## Everything one opportunity contributes this frame.
func _emit(op: Op, camera_pos: Vector3, gated: bool, leaving: bool,
		fx_t: float, flee01: float) -> void:
	var elapsed := maxf(_gm - op.born_gm, 0.0)
	var walk := sample(op, elapsed)
	var pos: Vector3 = walk["pos"]
	var head: float = walk["head"]
	var limb: float = walk["limb"]
	var head_t: float = walk["head_t"]
	var extra: float = walk["extra"]
	var lean: float = walk["lean"]
	var bounce: float = walk["bounce"]
	if leaving:
		# A body that is going does not keep walking its loop: it holds the pose
		# it was in, an animal bounds off it — and a crook RUNS off it.
		pos = op.last_pos
		head = op.last_head
		if op.state == STATE_COLLECTED and op.kind != KIND_CROOK:
			var hop := sin(PI * clampf(fx_t, 0.0, 1.0))
			pos += VehicleMotion.dir_xz(head) * (bound_m * fx_t)
			pos.y += hop * 0.55
		elif op.flee_s > 0.0:
			# THE DASH. Eased out, not linear: he is off the mark at once and
			# already slowing when the hand lands on his shoulder, which is what
			# makes the cuff read as an arrest rather than as a body stopping.
			var run := _ease_out(flee01)
			pos = op.flee_from + op.flee_dir * (flee_m * run)
			head = atan2(op.flee_dir.z, op.flee_dir.x)
			# The legs follow the DISTANCE covered, exactly as the wander's do —
			# it is the same rule and the same stride table, so the sprint is the
			# walk cycle turned up rather than a second animation.
			var stride: float = maxf(stride_m[op.kind], 0.05)
			limb = 0.5 + 0.5 * sin(TAU * (flee_m * run / stride + op.phase))
			# Arms pumping counter to the legs; a hard forward hunch; and the head
			# thrown back over his shoulder at whoever is behind him. The head
			# channel is a YAW on this body (see `sample`), so the extreme IS the
			# look back.
			extra = 1.0 - limb
			lean = -0.34
			head_t = 0.94
			bounce = 0.055 * maxf(sin(TAU * (flee_m * run / stride + op.phase)), 0.0)
			# `last_pos` is deliberately NOT advanced by the dash: it is where the
			# opportunity was TAKEN, and that is the spot the `+$N` belongs to.
			# The poof follows him — see the `_emit_burst` call below.
	else:
		op.last_pos = pos
		op.last_head = head

	# Where the FURNITURE stands. A collected animal bounds away; its poof and
	# its `+$N` belong to the spot it was TAKEN at, not to where the bound has
	# carried it — a label chasing a departing goat across the street reads as a
	# second thing happening rather than as the reward for the first.
	var fx_at := op.last_pos if leaving else pos

	var to_cam := 0.0 if not gated else camera_pos.distance_to(pos)
	if gated and to_cam > visible_radius_m:
		op.marker_size = 0.0
		return

	# ---- the marker ------------------------------------------------------
	var size := marker_min_m
	if gated:
		size = clampf(marker_angular * to_cam, marker_min_m, marker_max_m)
	else:
		size = clampf(marker_angular * 90.0, marker_min_m, marker_max_m)
	var bob := sin(TAU * (_real_s * marker_bob_hz + op.phase)) * marker_bob_m
	var head_y: float = KIND_TOP_M[op.kind]
	var marker_pos := Vector3(fx_at.x, op.anchor.y + head_y + marker_gap_m
			+ size * 0.5 + bob, fx_at.z)
	op.marker_pos = marker_pos
	op.marker_size = size
	var far_fade := 1.0
	if gated and to_cam > marker_fade_begin_m:
		far_fade = lerpf(1.0, marker_far_alpha, clampf(
				(to_cam - marker_fade_begin_m)
				/ maxf(visible_radius_m - marker_fade_begin_m, 0.001), 0.0, 1.0))
	if not leaving:
		var mp := _fx_pose()
		if mp != null:
			mp.basis = Basis().scaled(Vector3(size, size, size))
			mp.origin = marker_pos
			mp.tint = marker_linear[op.kind]
			mp.custom = Color(FX_MARKER, float(KIND_GLYPH[op.kind]), far_fade,
					op.phase)
			marker_used += 1
		if op.kind == KIND_STASH:
			var sp := _fx_pose()
			if sp != null:
				var s := size * 0.75
				sp.basis = Basis().scaled(Vector3(s, s, s))
				sp.origin = Vector3(pos.x, op.anchor.y + 0.24, pos.z)
				sp.tint = Color.WHITE
				sp.custom = Color(FX_SPARKLE, 0.0, far_fade, op.phase)

	# ---- the body --------------------------------------------------------
	if op.kind != KIND_STASH and (not gated or to_cam <= body_radius_m):
		var body_fade := 1.0
		if gated and to_cam > body_radius_m - body_fade_m:
			body_fade = clampf((body_radius_m - to_cam) / maxf(body_fade_m, 0.001),
					0.0, 1.0)
		var bp := _body_pose(op.kind)
		var leave := fx_t if leaving else (1.0 - body_fade)
		if bp != null:
			bp.basis = Basis.from_euler(Vector3(0.0, -head, 0.0)) \
					* Basis.from_euler(Vector3(0.0, 0.0, lean))
			bp.origin = Vector3(pos.x, pos.y + bounce, pos.z)
			bp.tint = Color(op.coat.r, op.coat.g, op.coat.b,
					1.0 if op.state == STATE_COLLECTED else 0.0)
			# A body faded out by distance is retired by shrinking it on the FX
			# channel, which is the one shrink the shader already has.
			bp.custom = Color(limb, head_t, extra, leave)
			body_used[op.kind] += 1
		# ---- the blob shadow, under the feet ------------------------------
		# Emitted beside the body and gated by exactly the same distance test, so
		# there is never a shadow with nothing standing on it. It shrinks with
		# the body's own leave curve for the same reason.
		_emit_blob(op, pos, leave, far_fade)

	# ---- the poof and the label -----------------------------------------
	if leaving:
		# The poof lands where the body IS. For an animal that is the spot it was
		# taken at (the bound carries the animal away and leaves the dust behind);
		# for a crook it is the end of the dash, because the poof IS the arrest
		# and the arrest happens where he was caught.
		_emit_burst(op, pos if op.flee_s > 0.0 else fx_at, fx_t, far_fade)
	if op.state == STATE_COLLECTED and op.reward > 0:
		_emit_label(op, marker_pos, far_fade)


## The contact shadow: one flat disc under the body, on the fx buffer, mode 5.
##
## It is a QUAD LAID FLAT, which is the one thing on that buffer that is not a
## billboard — the basis written here survives into the shader (see
## `street_fx.gdshader`'s `is_blob` mix) instead of being replaced by a
## camera-facing frame. Rotated −90° about X so the quad's own +Y becomes world
## −Z and it lies on the pavement.
##
## Height: `anchor.y` and not zero. A body standing on a footway is 0.25 m up
## (`asphalt_top_m + kerb_height_m`), and a shadow at world y = 0.04 would be
## buried under the kerb it belongs to — the same defect report NIGHT-1's
## `pool_y_superseded` note records for the lamp pools, in the same 0.15 m.
func _emit_blob(op: Op, pos: Vector3, leave: float, fade: float) -> void:
	if not blob_enabled:
		return
	var d: float = blob_body_m[op.kind] * blob_scale
	if d <= 0.0:
		return
	# Off the ground, the shadow goes: an animal mid-bound is 0.55 m up and a
	# solid disc under it would nail it back to the pavement.
	var lift := clampf((pos.y - op.anchor.y) / maxf(blob_lift_m, 0.001), 0.0, 1.0)
	var alpha := blob_alpha * (1.0 - lift * 0.75) * (1.0 - smoothstep(0.0, 0.9, leave))
	if alpha <= 0.004:
		return
	var p := _fx_pose()
	if p == null:
		return
	# A blob spreads slightly as its owner lifts — the same read a real contact
	# shadow gives, and it costs the multiply that was already there.
	var s := d * (1.0 + 0.35 * lift)
	p.basis = Basis.from_euler(Vector3(-PI * 0.5, 0.0, 0.0)).scaled(Vector3(s, s, s))
	p.origin = Vector3(pos.x, op.anchor.y + blob_y_m, pos.z)
	p.tint = Color(0.0, 0.0, 0.0, alpha)
	p.custom = Color(FX_BLOB, blob_night_fade, fade, op.phase)
	blob_used += 1


func _emit_burst(op: Op, pos: Vector3, fx_t: float, fade: float) -> void:
	# Measured from the END of the dash, not from the tap — see `refresh`. While
	# the crook is still running there is no poof at all: a dust cloud that
	# started at the tap and travelled with him would say the arrest had already
	# happened, which is the one thing the dash exists to delay.
	var since_cuff := _real_s - op.ended_s - op.flee_s
	if since_cuff < 0.0:
		return
	var t := clampf(since_cuff / maxf(burst_s, 0.0001), 0.0, 1.0)
	if t >= 1.0 or burst_used >= max_bursts:
		return
	burst_used += 1
	var collected := op.state == STATE_COLLECTED
	var centre := Vector3(pos.x, op.anchor.y + KIND_TOP_M[op.kind] * 0.45, pos.z)
	# Scaled off the BODY, not off the marker. The marker holds an angular size
	# — 3.3 m at Z2 — and a poof scaled to that is a dust cloud three times the
	# height of the thing that made it. A poof is a physical event: it is as big
	# as the animal was.
	var scale: float = maxf(KIND_TOP_M[op.kind] * 0.80, 0.60)
	# An EXPIRY deflates: half the puffs, no ring, and they fall rather than fly.
	var n := puffs_per_burst if collected else int(puffs_per_burst / 2)
	for i in n:
		var p := _fx_pose()
		if p == null:
			return
		var a := TAU * (float(i) / float(maxi(n, 1))
				+ VehicleMotion.hash01(op.id, 41 + i) * 0.22)
		var reach: float = scale * (0.32 + 0.46 * VehicleMotion.hash01(op.id, 53 + i))
		var rise := scale * (0.55 if collected else -0.18)
		var s: float = scale * (0.30 + 0.55 * t) \
				* (0.7 + 0.5 * VehicleMotion.hash01(op.id, 67 + i))
		p.basis = Basis().scaled(Vector3(s, s, s))
		p.origin = centre + Vector3(cos(a) * reach * t, rise * t, sin(a) * reach * t)
		p.tint = Color.WHITE if collected else Color(0.62, 0.62, 0.64)
		p.custom = Color(FX_PUFF, t, fade, VehicleMotion.hash01(op.id, 71 + i))
	if not collected:
		return
	var ring := _fx_pose()
	if ring == null:
		return
	var rs := scale * (0.8 + 1.1 * t)
	ring.basis = Basis().scaled(Vector3(rs, rs, rs))
	ring.origin = centre
	ring.tint = Color.WHITE
	ring.custom = Color(FX_RING, t, fade, op.phase)


func _emit_label(op: Op, marker_pos: Vector3, fade: float) -> void:
	var t := clampf((_real_s - op.ended_s) / maxf(label_s, 0.0001), 0.0, 1.0)
	if t >= 1.0 or label_used >= max_labels:
		return
	var glyphs := StreetGlyphAtlas.reward_glyphs(op.reward)
	if glyphs.is_empty():
		return
	label_used += 1
	var h: float = maxf(op.marker_size, marker_min_m) * label_glyph_frac
	var rise := maxf(op.marker_size, marker_min_m) * label_rise_frac * _ease_out(t)
	# Held solid for the first 55% and then faded — a number that starts
	# dissolving the instant it appears is a number nobody reads.
	var alpha := 1.0 - smoothstep(0.55, 1.0, t)
	# Clear of the marker's own top before it starts rising: a label that begins
	# life ON the pin puts its middle glyphs behind the chip, which is how
	# `+$120` reads as `+ 20` for the first third of a second.
	var base := marker_pos + Vector3(0.0,
			op.marker_size * 0.55 + h * 0.5 + rise, 0.0)
	# Every glyph shares ONE world origin and carries its SLOT; the shader steps
	# them apart along the billboard's own local +X, which is screen right.
	# Laying the run out here in world space instead — the first pass did — puts
	# the number along world +X, so it skews and foreshortens with the camera
	# yaw and reads as a number painted on the road.
	var mid := (float(glyphs.size()) - 1.0) * 0.5
	for i in glyphs.size():
		var p := _fx_pose()
		if p == null:
			return
		# The quad has to carry the atlas cell's own aspect or the digits
		# stretch; the page states that ratio and nothing else restates it.
		p.basis = Basis().scaled(Vector3(h * StreetGlyphAtlas.cell_aspect(), h, h))
		p.origin = base
		p.tint = Color(label_linear.r, label_linear.g, label_linear.b, alpha)
		p.custom = Color(FX_GLYPH, float(glyphs[i]), fade, float(i) - mid)


# ------------------------------------------------------------- the wander

## The whole gait, as a pure function of `(op, elapsed game-minutes)`. Returns
## position, heading, the three animation channels, the body's lean and its
## vertical bounce.
##
## `elapsed` is folded into the cycle, so this is defined for any time — before
## the spawn, an hour after it, or after a load put the clock somewhere else —
## and it is the ONLY place the wander is computed. Nothing accumulates.
func sample(op: Op, elapsed: float) -> Dictionary:
	var n := op.path.size()
	if n < 2 or op.cycle_gm <= 0.0:
		return {"pos": op.anchor, "head": 0.0, "limb": 0.5, "head_t": 0.5,
				"extra": 0.5, "lean": 0.0, "bounce": 0.0}
	var leg_gm := op.move_gm + op.pause_gm
	var t := fposmod(elapsed, op.cycle_gm)
	var leg := clampi(int(t / leg_gm), 0, n - 1)
	var within := t - float(leg) * leg_gm
	var u := clampf(within / maxf(op.move_gm, 0.0001), 0.0, 1.0)
	# Ease in and out of every leg, so a dash starts and stops rather than
	# switching velocity at a waypoint.
	var eased := u * u * (3.0 - 2.0 * u)
	var a: Vector3 = op.path[leg]
	var b: Vector3 = op.path[(leg + 1) % n]
	var pos := a.lerp(b, eased)
	var head := atan2(b.z - a.z, b.x - a.x)
	# 0 while paused at a waypoint, 1 in the middle of a dash.
	var moving := smoothstep(0.0, 0.16, u) * (1.0 - smoothstep(0.84, 1.0, u))

	# Stride phase follows DISTANCE, not time, so the legs match the speed the
	# body is actually crossing the pavement at — the one thing that separates
	# a walk cycle from a body sliding along with its legs waving.
	var travelled: float = op.leg_cum[leg] + op.leg_len[leg] * eased
	var cycles := float(int(elapsed / op.cycle_gm))
	var stride: float = maxf(stride_m[op.kind], 0.05)
	var sp := (travelled + cycles * op.loop_len) / stride
	var walk_limb := 0.5 + 0.5 * sin(TAU * (sp + op.phase))
	var idle_limb := 0.5 + 0.055 * sin(TAU * (elapsed * 0.31 + op.phase))
	var limb := lerpf(idle_limb, walk_limb, moving)

	var head_t := 0.5
	var extra := 0.5
	var lean := 0.0
	var bounce := 0.0
	match op.kind:
		KIND_CROOK:
			# Head YAW: a thief checks over his shoulder, and he does it most
			# while he is standing still.
			head_t = 0.5 + 0.44 * sin(TAU * (elapsed * 0.27 + op.phase * 1.7)) \
					* (1.0 - moving * 0.55)
			# Arms counter-swing the legs.
			extra = 1.0 - limb
			# Hunched at rest, more so mid-dash.
			lean = -(0.11 + 0.13 * moving)
		KIND_DOG:
			var bob := 0.5 + 0.16 * sin(TAU * (sp * 2.0 + op.phase))
			var sniff := 0.17 + 0.05 * sin(TAU * (elapsed * 0.9 + op.phase))
			head_t = lerpf(sniff, bob, moving)
			# The tail goes hardest when the dog is moving, and never stops.
			extra = 0.5 + (0.20 + 0.26 * moving) \
					* sin(TAU * (elapsed * (1.4 + 1.6 * moving) + op.phase))
			bounce = 0.030 * maxf(sin(TAU * (sp * 2.0 + op.phase)), 0.0) * moving
		KIND_GOAT:
			# Browse: head right down at the kerb while parked, level on the
			# amble. And now and then, because it is a goat, a hop.
			var hop_t := fposmod(elapsed * 0.5 + op.phase, 1.0)
			var hop := maxf(sin(PI * clampf((hop_t - 0.86) / 0.14, 0.0, 1.0)), 0.0)
			var browse := 0.07 + 0.05 * sin(TAU * (elapsed * 0.55 + op.phase))
			head_t = lerpf(browse, 0.56, moving)
			head_t = lerpf(head_t, 0.92, hop)
			extra = 0.5 + 0.22 * sin(TAU * (elapsed * 0.8 + op.phase))
			lean = 0.05 + 0.42 * hop
			bounce = 0.26 * hop
			limb = lerpf(limb, 0.86, hop)
		_:
			pass
	return {"pos": pos, "head": head, "limb": clampf(limb, 0.0, 1.0),
			"head_t": clampf(head_t, 0.0, 1.0), "extra": clampf(extra, 0.0, 1.0),
			"lean": lean, "bounce": bounce}


## The waypoint ring, resolved once at spawn. Angles and radii are hashed off
## the id, so the same crook paces the same beat on every device and after every
## load — and two crooks on one street never pace the same one.
func _lay_out(op: Op) -> void:
	var n := waypoints
	op.path = PackedVector3Array()
	op.path.resize(n)
	var across := op.along.cross(Vector3.UP).normalized()
	var spin := VehicleMotion.hash01(op.id, 11) * TAU
	for i in n:
		var a := spin + TAU * float(i) / float(n) \
				+ (VehicleMotion.hash01(op.id, 101 + i) - 0.5) * 0.55
		var r := wander_radius_m * (0.42 + 0.58 * VehicleMotion.hash01(op.id, 131 + i))
		var scale_across := wander_across if op.snapped else 1.0
		op.path[i] = op.anchor + op.along * (cos(a) * r) \
				+ across * (sin(a) * r * scale_across)
	op.leg_len = PackedFloat32Array()
	op.leg_cum = PackedFloat32Array()
	op.leg_len.resize(n)
	op.leg_cum.resize(n)
	var cum := 0.0
	for i2 in n:
		var d: float = op.path[i2].distance_to(op.path[(i2 + 1) % n])
		op.leg_cum[i2] = cum
		op.leg_len[i2] = d
		cum += d
	op.loop_len = maxf(cum, 0.01)
	op.cycle_gm = float(n) * (op.move_gm + op.pause_gm)


## Snap the anchor to a kerb line where the road classification offers one.
##
## Three cases, and the middle one is the one that matters. If the spawn tile IS
## a road, the body belongs on that tile's FOOTWAY — a crook loitering in a live
## traffic lane is a different event. If a NEIGHBOUR is a road, the footway on
## that road's near side is the pavement in front of this lot, which is exactly
## where a stray or a dropped wallet would be. With no road in reach at all, the
## body wanders its own tile and the ellipse is left circular.
func _anchor(op: Op) -> void:
	var centre := Vector3((float(op.tile.x) + 0.5) * tile_m, 0.0,
			(float(op.tile.y) + 0.5) * tile_m)
	op.anchor = centre
	op.along = Vector3(1.0, 0.0, 0.0)
	op.snapped = false
	if not _road_probe.is_valid():
		return
	var dirs := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	var here := int(_road_probe.call(op.tile))
	if here > 0:
		# Kerbed sides first, in a fixed order, then the id picks between them —
		# two crooks on one tile do not stand on the same slab.
		var kerbs: Array[int] = []
		for i in 4:
			if int(_road_probe.call(op.tile + dirs[i])) <= 0:
				kerbs.append(i)
		if kerbs.is_empty():
			# Deep inside a junction: four road neighbours, no footway anywhere
			# on the tile. The body wanders the carriageway — there is nowhere
			# else — and it stands on the ASPHALT TOP rather than at y = 0,
			# which is 10 cm below the slab it is walking on.
			op.anchor.y = road_top_m
			return
		var pick: int = kerbs[int(VehicleMotion.hash01(op.id, 7) * float(kerbs.size()))
				% kerbs.size()]
		var d: Vector2i = dirs[pick]
		var w := _walk_width(here)
		var off := tile_m * 0.5 - w * 0.5
		op.anchor = Vector3(centre.x + float(d.x) * off, walk_top_m,
				centre.z + float(d.y) * off)
		op.along = Vector3(float(-d.y), 0.0, float(d.x))
		op.snapped = true
		return
	for i2 in 4:
		var q: Vector2i = op.tile + dirs[i2]
		var cls := int(_road_probe.call(q))
		if cls <= 0:
			continue
		var w2 := _walk_width(cls)
		var d2: Vector2i = dirs[i2]
		var off2 := tile_m * 0.5 + w2 * 0.5
		op.anchor = Vector3(centre.x + float(d2.x) * off2, walk_top_m,
				centre.z + float(d2.y) * off2)
		op.along = Vector3(float(-d2.y), 0.0, float(d2.x))
		op.snapped = true
		return


func _walk_width(road_class: int) -> float:
	return walk_width_avenue_m if road_class == TileGrid.ROAD_AVENUE \
			else walk_width_street_m


# ------------------------------------------------------------------- pools

## Pose objects are allocated once and reused, never rebuilt: at the cap this
## layer writes ~100 rows a frame and a fresh `Pose` for each of them would be
## the layer's whole CPU budget spent on the allocator.
func _reserve() -> void:
	for k in KIND_COUNT:
		var pool: Array = body_poses[k]
		while pool.size() < max_live:
			pool.append(Pose.new())
	# `max_live * 3`: a marker, a stash sparkle and a BLOB per live opportunity.
	# The blob is on this buffer (mode 5), so the pool has to carry it or a full
	# frame would silently drop the last body's shadow.
	var want := max_live * 3 + max_bursts * (puffs_per_burst + 1) \
			+ max_labels * 8
	while fx_poses.size() < want:
		fx_poses.append(Pose.new())


func _body_pose(kind: int) -> Pose:
	var pool: Array = body_poses[kind]
	if body_used[kind] >= pool.size():
		return null
	return pool[body_used[kind]]


func _fx_pose() -> Pose:
	if fx_used >= fx_poses.size():
		return null
	var p: Pose = fx_poses[fx_used]
	fx_used += 1
	return p


func _drop(id: int) -> void:
	ops.erase(id)
	_order.erase(id)


## Make room. A record that is already LEAVING goes first — its story is told —
## and only then the oldest live one.
func _evict() -> void:
	var victim := -1
	for id: int in _order:
		if (ops[id] as Op).state != STATE_LIVE:
			victim = id
			break
	if victim < 0 and not _order.is_empty():
		victim = _order[0]
	if victim >= 0:
		_drop(victim)


# ----------------------------------------------------------------- helpers

static func _ease_out(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	return 1.0 - (1.0 - x) * (1.0 - x)


## A payload's `tile`, however the sim chose to say it.
static func _tile_of(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Vector2:
		return Vector2i(value)
	if value is Array and (value as Array).size() >= 2:
		var a: Array = value
		return Vector2i(int(a[0]), int(a[1]))
	if value is Dictionary:
		var d: Dictionary = value
		return Vector2i(int(d.get("x", 0)), int(d.get("y", d.get("z", 0))))
	return Vector2i.ZERO


static func _num(cfg: Dictionary, key: String, fallback: float) -> float:
	return float(cfg.get(key, fallback))


static func _floats(value: Variant, fallback: Array[float]) -> Array[float]:
	if not (value is Array):
		return fallback
	var out: Array[float] = fallback.duplicate()
	var a: Array = value
	for i in mini(a.size(), out.size()):
		out[i] = float(a[i])
	return out
