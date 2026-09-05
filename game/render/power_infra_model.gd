class_name PowerInfraModel
extends RefCounted
## The DISTRIBUTION layer's arithmetic (doc 11 §2.10, doc 04 §2.1): where a
## transformer pad stands, which way it faces, where each of its service wires
## starts and ends, and what "this one is in trouble" looks like as numbers.
##
## Deliberately a RefCounted with no Node and no sim dependency, for the same
## reason `RenderStateModel` is: every rule below is then headless-testable, and
## `PowerInfraView` is a thin uploader over it. Time is a parameter — `advance`
## drives the three ramps, nothing here reads a clock.
##
## ── what the sim owns and this does not ──────────────────────────────────
## Doc 04 owns the grid. Every number this class classifies on is READ out of
## `PowerGrid` (its rows, its constants), never re-authored here: the
## WARNING/CRITICAL bands are §5.10's `OVERLAY_WARNING_R` / `OVERLAY_CRITICAL_R`,
## the hazard knee is `HAZARD[&"transformer"][0]`, and `severe_ratio()` below is
## SOLVED from §2.6's thermal and hazard rows rather than picked. The renderer
## may not have an opinion about when a transformer is in trouble; it may only
## have an opinion about what trouble looks like.

## Distress bands, in severity order — the value packed into the pad buffer's
## `.b` channel and the only thing the shaders switch on.
## **Aliases of `PowerGrid`'s, not a second table** (Wave 25, RR-207). The bands
## moved into doc 04 when `ui/power_actions.gd` became a second reader of them,
## because a panel and a shader that disagreed about whether a transformer is in
## trouble is precisely the defect the three-channel rule exists to prevent. The
## names stay here because this is the file the shaders are written against.
const DISTRESS_CLEAN := PowerGrid.DISTRESS_CLEAN
const DISTRESS_STRESSED := PowerGrid.DISTRESS_STRESSED
const DISTRESS_TROUBLED := PowerGrid.DISTRESS_TROUBLED
const DISTRESS_SEVERE := PowerGrid.DISTRESS_SEVERE
const DISTRESS_DARK := PowerGrid.DISTRESS_DARK
const DISTRESS_FAILED := PowerGrid.DISTRESS_FAILED
const DISTRESS_COUNT := PowerGrid.DISTRESS_COUNT

## `packed = distress + OVERLAY_STRIDE * overlay_state`, the SAME stride and the
## same decoder shape `building.gdshader`'s `overlay_of()` uses (doc 12 §2.5 /
## report C-64). A pad has no variant, no construction stage and no level atlas,
## so the low field is the distress band instead — but keeping the overlay field
## at 112 means the two shaders decode the overlay with one expression and can
## never drift apart on the thing they SHARE.
const OVERLAY_STRIDE := 112.0

## Doc 04's own reference ambient: the default `t_ambient` of every `PowerGrid`
## read-only query. `severe_ratio()` is solved at this temperature because the
## band has to be a fixed, explainable line — a smoking threshold that slid with
## the weather would make the same transformer smoke and stop smoking while its
## load never moved.
const REFERENCE_AMBIENT_C := PowerGrid.REFERENCE_AMBIENT_C

## The hazard rate, per game-hour, that defines DISTRESS_SEVERE: 1.0 means the
## component is odds-on (1 − e⁻¹ = 63 %) to fail inside one game hour. That is
## the honest reading of "about to go", and it is the only authored number in
## this file — everything else about the band is solved from doc 04 §2.6.
const SEVERE_HAZARD_PER_GH := PowerGrid.SEVERE_HAZARD_PER_GH

# ------------------------------------------------------------------- config

var chunk_m: float = 128.0
var tile_m: float = 8.0

## Pad geometry, metres. The view builds its mesh from these, and `riser_local`
## is where a service wire leaves the cabinet.
var pad_size := Vector2(2.40, 2.00)
var cabinet_h: float = 1.47        # lid top, above grade
var riser_local := Vector3(0.0, 1.62, -0.46)

## Service-drop geometry (doc 04 §2.1's attachment, drawn).
var service_h_max: float = 5.20
var service_h_min: float = 2.60
var service_clearance_m: float = 0.35   # the wire stops this far off the wall
var sag_frac: float = 0.055
var sag_max_m: float = 1.35

## Distress bands, filled by `configure()` from `PowerGrid`'s constants.
var warn_r: float = PowerGrid.OVERLAY_WARNING_R
var critical_r: float = PowerGrid.OVERLAY_CRITICAL_R
var severe_r: float = 1.40
var hot_c: float = 85.0
var worn_condition: float = 0.4226

## Ramp time constants, seconds of RENDER time. Asymmetric on purpose: a
## transformer that fails goes dark and black in well under a second (it is an
## event), and one that is repaired washes clean over a couple of seconds (it is
## a crew leaving). The player asked to SEE the fix land; a step change would
## read as a glitch.
var char_rise_s: float = 0.55
var char_fall_s: float = 2.40
var glow_tau_s: float = 1.60
var smoke_tau_s: float = 1.10

## Smoke budget. `puffs_per_pad` billboards ride one distressed pad; the cap is
## the whole city's, enforced worst-first so the transformer that is actually
## burning is never the one that got dropped.
var puffs_per_pad: int = 6
var puff_cap: int = 132
var puff_rise_m: float = 5.40
var puff_size_m: float = 1.15

# -------------------------------------------------------------------- state

var _pads: Array = []             # PadRec, ascending by transformer id
var _pad_index: Dictionary = {}   # transformer id -> index into _pads
var _spans: Array = []            # SpanRec, ascending by (transformer, building)
var _spans_by_chunk: Dictionary = {}  # Vector2i -> Array[int] (index into _spans)
var _puffs: Array = []            # PuffRec, rebuilt when the distressed set moves
var _puffs_dirty: bool = true
var _road_probe := Callable()
## Set whenever a pad's per-instance data actually changed, cleared by the view
## when it uploads. A city with nothing happening in it uploads NOTHING: the
## flicker, the smoke loop and the overlay pulse are all shader functions of
## `sc_time`, so a settled grid needs no per-frame buffer traffic at all — which
## is what lets the pad buffer be city-wide without a write budget.
var _buffers_dirty: bool = true
## `fingerprint()` of the last topology actually built — the early-out that lets
## the view poll for an adoption without paying for a rebuild.
var _topology_mark: int = 0


# ------------------------------------------------------------------ records

class PadRec extends RefCounted:
	var id: String = ""
	var tile := Vector2i.ZERO
	var world_pos := Vector3.ZERO
	var chunk := Vector2i.ZERO
	var yaw: float = 0.0
	var level: int = 1
	## Deterministic per-id 0..1, the pad's slot in every animation that must
	## not march in lockstep with its neighbours.
	var phase: float = 0.0
	var riser := Vector3.ZERO

	var distress: int = DISTRESS_CLEAN
	var load_ratio: float = 0.0
	var condition: float = 1.0
	var temp_c: float = 0.0
	var customers: int = 0

	var glow: float = 0.0
	var glow_target: float = 0.0
	var char01: float = 0.0
	var char_target: float = 0.0
	var smoke: float = 0.0
	var smoke_target: float = 0.0
	var spark: float = 0.0


class SpanRec extends RefCounted:
	var transformer_id: String = ""
	var building_id: String = ""
	var pad_index: int = -1
	var from := Vector3.ZERO
	var to := Vector3.ZERO
	var sag: float = 0.0
	var chunk := Vector2i.ZERO

	func length() -> float:
		return from.distance_to(to)


class PuffRec extends RefCounted:
	var pad_index: int = -1
	var origin := Vector3.ZERO
	var phase: float = 0.0
	var size: float = 1.0
	## 0 smoke, 1 spark. One buffer carries both — see `power_smoke.gdshader`.
	var kind: int = 0


# ------------------------------------------------------------------- config

func _init(render_data: Dictionary = {}) -> void:
	if not render_data.is_empty():
		configure(render_data)


## Read `data/render.json`. Every geometric number is doc 11's and lives there;
## every ELECTRICAL band is doc 04's and is taken from `PowerGrid` directly, so
## a balance edit to the grid moves the visuals without a second edit here.
func configure(render_data: Dictionary) -> void:
	var world: Dictionary = render_data.get("world", {})
	chunk_m = float(world.get("chunk_m", chunk_m))
	tile_m = float(world.get("tile_m", tile_m))
	var cfg: Dictionary = render_data.get("power_infra", {})
	var pad: Array = cfg.get("pad_m", [pad_size.x, pad_size.y])
	pad_size = Vector2(float(pad[0]), float(pad[1]))
	cabinet_h = float(cfg.get("cabinet_top_m", cabinet_h))
	var riser: Array = cfg.get("riser_local_m", [riser_local.x, riser_local.y, riser_local.z])
	riser_local = Vector3(float(riser[0]), float(riser[1]), float(riser[2]))
	service_h_max = float(cfg.get("service_height_max_m", service_h_max))
	service_h_min = float(cfg.get("service_height_min_m", service_h_min))
	service_clearance_m = float(cfg.get("service_clearance_m", service_clearance_m))
	sag_frac = float(cfg.get("wire_sag_frac", sag_frac))
	sag_max_m = float(cfg.get("wire_sag_max_m", sag_max_m))
	char_rise_s = float(cfg.get("char_rise_s", char_rise_s))
	char_fall_s = float(cfg.get("char_fall_s", char_fall_s))
	glow_tau_s = float(cfg.get("glow_tau_s", glow_tau_s))
	smoke_tau_s = float(cfg.get("smoke_tau_s", smoke_tau_s))
	puffs_per_pad = int(cfg.get("puffs_per_pad", puffs_per_pad))
	puff_cap = int(cfg.get("puff_cap", puff_cap))
	puff_rise_m = float(cfg.get("puff_rise_m", puff_rise_m))
	puff_size_m = float(cfg.get("puff_size_m", puff_size_m))
	# Doc 04's bands, not doc 11's. Read, never re-authored.
	warn_r = PowerGrid.OVERLAY_WARNING_R
	critical_r = PowerGrid.OVERLAY_CRITICAL_R
	severe_r = severe_ratio()
	hot_c = float((PowerGrid.HAZARD[&"transformer"] as Array)[0])
	worn_condition = worn_condition_threshold()


## `is_road(Vector2i) -> bool`. Supplied by the shell (doc 10's tile flags); an
## empty Callable means "no road data", and every pad then takes the fixed yaw.
func set_road_probe(probe: Callable) -> void:
	_road_probe = probe


# ------------------------------------------------------- the two derived bands

## The load ratio at which a transformer's hazard rate reaches
## `SEVERE_HAZARD_PER_GH`, solved from doc 04 §2.6's own rows rather than picked.
##
## §2.6: θ_ss = θ_rated · r², temp = ambient + θ, stress = (temp − knee)/span,
## hazard = h_cold + h_hot · stress³ per game-hour. Setting hazard = H and
## inverting:
##
##     stress = ((H − h_cold) / h_hot)^⅓
##     r      = √( (knee + span·stress − ambient) / θ_rated )
##
## With the shipped transformer row (θ_rated 55, knee 85, span 60, h_hot 2.00,
## h_cold 0.00012) at 25 °C that is **r = 1.399** — a transformer at 140 % of its
## derated plate is odds-on to burn out inside the game-hour, which is the only
## defensible reading of "throwing sparks". Retuning §2.6 moves this line with
## it; nothing has to be re-picked.
static func severe_ratio(t_ambient: float = REFERENCE_AMBIENT_C,
		hazard_per_gh: float = SEVERE_HAZARD_PER_GH) -> float:
	return PowerGrid.severe_load_ratio(t_ambient, hazard_per_gh)


## The condition at which §2.6's wear/hazard multiplier `1 + 3(1−c)²` has
## DOUBLED — i.e. the point past which a transformer is failing for its age
## rather than for its load, and the point at which this layer starts showing
## soot on a pad that is not otherwise in trouble. `(1−c)² = ⅓ ⇒ c = 0.4226`.
static func worn_condition_threshold() -> float:
	return PowerGrid.worn_condition_threshold()


## Which band a transformer row falls in. Pure, and the whole of the mapping the
## test pins: `state` and `energized` win over any load number, because a burned
## transformer with a stale 1.8 load ratio is CHARRED, not SPARKING.
func distress_for(state: String, energized: bool, load_ratio: float,
		condition: float, temp_c: float) -> int:
	return PowerGrid.distress_band(state, energized, load_ratio, condition, temp_c)


# ---------------------------------------------------------------- topology

## Rebuild pads and spans. `transformers` is `[{id, tile: Vector2i, level}]`,
## `buildings` is `{id: {world_pos: Vector3, footprint_m: Vector2, height_m}}`
## and `attachments` is `PowerGrid.attachment_map()`.
##
## Every output array is built in ASCENDING ID ORDER and nothing here consults a
## Dictionary's insertion order, so two runs over the same grid upload
## byte-identical buffers. Live ramp state survives a rebuild for any pad that is
## still there — otherwise placing one transformer would re-light the char on
## every other pad in the city.
##
## Returns **false when nothing moved**, having touched nothing. The view polls
## this every few seconds as a safety net (doc 04 §2.9's adoption re-parents a
## building without changing any count), and on a settled bench city that poll
## would otherwise free 49 MultiMesh nodes and rewrite 1,500 span transforms for
## a byte-identical answer. `fingerprint()` reads the INPUT — ids, tiles, levels
## and the attachment pairs — so the early-out costs one pass over data the
## caller has already built, and never a rebuild.
func build_topology(transformers: Array, buildings: Dictionary,
		attachments: Dictionary) -> bool:
	var mark := fingerprint(transformers, attachments)
	if mark == _topology_mark and not _pads.is_empty():
		return false
	_topology_mark = mark
	var previous := _pad_index.duplicate()
	var old_pads := _pads
	var rows := transformers.duplicate()
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a.get("id", "")) < String(b.get("id", "")))
	_pads = []
	_pad_index = {}
	for row: Dictionary in rows:
		var rec := PadRec.new()
		rec.id = String(row.get("id", ""))
		rec.tile = row.get("tile", Vector2i.ZERO)
		rec.level = int(row.get("level", 1))
		rec.world_pos = tile_center(rec.tile)
		rec.chunk = chunk_of(rec.world_pos)
		rec.yaw = yaw_for(rec.tile)
		rec.phase = phase_for(rec.id)
		rec.riser = rec.world_pos + Basis.from_euler(Vector3(0.0, rec.yaw, 0.0)) * riser_local
		if previous.has(rec.id):
			var was: PadRec = old_pads[int(previous[rec.id])]
			rec.distress = was.distress
			rec.glow = was.glow
			rec.glow_target = was.glow_target
			rec.char01 = was.char01
			rec.char_target = was.char_target
			rec.smoke = was.smoke
			rec.smoke_target = was.smoke_target
			rec.spark = was.spark
			rec.load_ratio = was.load_ratio
			rec.condition = was.condition
			rec.temp_c = was.temp_c
		_pad_index[rec.id] = _pads.size()
		_pads.append(rec)

	_spans = []
	_spans_by_chunk = {}
	var building_ids := attachments.keys()
	building_ids.sort()
	for building_id: String in building_ids:
		var transformer_id := String(attachments[building_id])
		if not _pad_index.has(transformer_id) or not buildings.has(building_id):
			continue
		var pad: PadRec = _pads[int(_pad_index[transformer_id])]
		var view: Dictionary = buildings[building_id]
		var span := SpanRec.new()
		span.transformer_id = transformer_id
		span.building_id = building_id
		span.pad_index = int(_pad_index[transformer_id])
		span.from = pad.riser
		span.to = service_point(view, pad.riser)
		span.sag = minf(sag_max_m, span.from.distance_to(span.to) * sag_frac)
		# The whole fan hangs off the PAD's chunk, not each wire's own midpoint:
		# a pad either shows all of its drops or none of them, so walking the
		# camera across a chunk seam can never leave half a fan in the air.
		span.chunk = pad.chunk
		if not _spans_by_chunk.has(span.chunk):
			_spans_by_chunk[span.chunk] = []
		(_spans_by_chunk[span.chunk] as Array).append(_spans.size())
		_spans.append(span)
	_puffs_dirty = true
	_buffers_dirty = true
	return true


## A 64-bit mark over everything `build_topology` reads: the transformer roster
## (id, tile, level) and the attachment pairs. Order-independent — each row folds
## into its own hash and the row hashes are SUMMED — so a caller that hands the
## rows over in a different order still gets the same mark, which is the point:
## the mark says "the grid's shape", not "the order this array happened to be in".
static func fingerprint(transformers: Array, attachments: Dictionary) -> int:
	var mark := 0
	for row: Dictionary in transformers:
		var tile: Vector2i = row.get("tile", Vector2i.ZERO)
		mark += hash([String(row.get("id", "")), tile.x, tile.y,
				int(row.get("level", 1))])
	for building_id in attachments:
		mark += hash([String(building_id), String(attachments[building_id])])
	return mark


## Doc 04 stores a transformer as ONE tile; doc 11 draws it at that tile's
## centre, on grade — the same `tile * tile_m + tile_m/2` every other tile-placed
## prop in the renderer uses.
func tile_center(tile: Vector2i) -> Vector3:
	return Vector3(tile.x * tile_m + tile_m * 0.5, 0.0, tile.y * tile_m + tile_m * 0.5)


func chunk_of(world_pos: Vector3) -> Vector2i:
	return Vector2i(int(floor(world_pos.x / chunk_m)), int(floor(world_pos.z / chunk_m)))


## Which way the cabinet's door faces. A padmount is set with its doors to the
## street — that is the working clearance a crew needs, and it is also the only
## orientation that does not read as scenery dropped at random.
##
## The four orthogonal neighbours are tested in a FIXED order (−Z, +X, +Z, −X)
## and the first road wins, so a pad on a corner resolves the same way on every
## run and after every load. With no road adjacent (a pad in a back lot) the
## diagonals are tried next, and a pad with no road anywhere near it faces −Z:
## a deterministic fallback, never a hash, because a randomly-spun cabinet in an
## otherwise aligned row is more conspicuous than an aligned one facing nowhere.
func yaw_for(tile: Vector2i) -> float:
	if not _road_probe.is_valid():
		return 0.0
	const ORTHO := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	const DIAG := [Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1), Vector2i(-1, -1)]
	for step: Vector2i in ORTHO:
		if bool(_road_probe.call(tile + step)):
			return yaw_towards(step)
	for step: Vector2i in DIAG:
		if bool(_road_probe.call(tile + step)):
			return yaw_towards(step)
	return 0.0


## The yaw that points local +Z (the door face) at `step`. `atan2(x, z)` rather
## than the usual `atan2(z, x)`: Godot's yaw is measured from −Z, and the door
## normal is +Z in the mesh this drives.
static func yaw_towards(step: Vector2i) -> float:
	return atan2(float(step.x), float(step.y))


## A deterministic 0..1 from the component id. FNV-1a over the id's bytes, taken
## mod 2^24 so the float is exact — the pad's animation slot has to survive a
## save/load round trip, and an id is the only thing about a transformer that
## does.
static func phase_for(id: String) -> float:
	var h: int = 0x811C9DC5
	for i in id.length():
		h = (h ^ id.unicode_at(i)) & 0xFFFFFFFF
		h = (h * 16777619) & 0xFFFFFFFF
	return float(h % 16777216) / 16777216.0


## Where a service drop lands on a building: the point on its footprint
## rectangle nearest the transformer, pushed `service_clearance_m` back OUT
## along the approach so the wire stops at a weatherhead off the wall rather
## than inside it, at a height that is the building's own eave when the building
## is short and a fixed service entrance when it is tall.
##
## Deterministic from the footprint alone — no hash, no per-building authored
## anchor — which is what makes the same city draw the same wires after a load.
func service_point(view: Dictionary, from: Vector3) -> Vector3:
	var center: Vector3 = view.get("world_pos", Vector3.ZERO)
	var footprint: Vector2 = view.get("footprint_m", Vector2(8.0, 8.0))
	var half := footprint * 0.5
	var nearest := Vector3(
			clampf(from.x, center.x - half.x, center.x + half.x),
			0.0,
			clampf(from.z, center.z - half.y, center.z + half.y))
	# `from` inside the footprint (a transformer on the lot) leaves `nearest`
	# equal to `from`'s xz and no approach direction; fall back to the centre,
	# which always has one.
	var approach := Vector2(nearest.x - from.x, nearest.z - from.z)
	if approach.length() < 0.001:
		approach = Vector2(center.x - from.x, center.z - from.z)
	if approach.length() < 0.001:
		approach = Vector2(0.0, 1.0)
	approach = approach.normalized()
	var height := float(view.get("height_m", 9.0))
	var y := clampf(height - 0.90, service_h_min, service_h_max)
	return Vector3(nearest.x - approach.x * service_clearance_m, y,
			nearest.z - approach.y * service_clearance_m)


# ------------------------------------------------------------------- state

## Ingest `PowerGrid.transformer_rows()`. Rows for pads this model has never
## heard of are ignored (the topology rebuild that introduces them is the one
## that owns them); pads with no row hold their last state, which is what a
## paused sim should look like.
func apply_state(rows: Array) -> void:
	for row: Dictionary in rows:
		var id := String(row.get("id", ""))
		if not _pad_index.has(id):
			continue
		var pad: PadRec = _pads[int(_pad_index[id])]
		pad.load_ratio = float(row.get("load_ratio", 0.0))
		pad.condition = float(row.get("condition", 1.0))
		pad.temp_c = float(row.get("temp_c", 0.0))
		pad.customers = int(row.get("customers", 0))
		var was := pad.distress
		pad.distress = distress_for(String(row.get("state", "OK")),
				bool(row.get("energized", false)), pad.load_ratio,
				pad.condition, pad.temp_c)
		pad.glow_target = glow_target_for(pad)
		pad.char_target = char_target_for(pad)
		pad.smoke_target = smoke_target_for(pad)
		pad.spark = 1.0 if pad.distress == DISTRESS_SEVERE else 0.0
		_buffers_dirty = true
		if was != pad.distress:
			_puffs_dirty = true


## Heat, as the fins show it: 0 through the NORMAL band, then a linear climb
## across WARNING → SEVERE so the ramp the player watches IS the load ratio and
## not a step. A dark or failed transformer carries no heat at all.
func glow_target_for(pad: PadRec) -> float:
	if pad.distress == DISTRESS_DARK or pad.distress == DISTRESS_FAILED:
		return 0.0
	return clampf((pad.load_ratio - warn_r) / maxf(severe_r - warn_r, 0.001), 0.0, 1.0)


## Soot. Two sources, and the worse wins: the burn itself (a FAILED unit goes
## fully charred), and plain age — a transformer under `worn_condition` is dirty
## before anything goes wrong with it, which is the visual tell that a player
## can act on BEFORE the incident fires.
func char_target_for(pad: PadRec) -> float:
	var age := clampf((worn_condition - pad.condition) / maxf(worn_condition, 0.001),
			0.0, 1.0) * 0.55
	if pad.distress == DISTRESS_FAILED:
		return 1.0
	return age


## How hard it smokes. TROUBLED wisps, SEVERE pours, and a FAILED unit keeps a
## thin smoulder — a burned-out transformer that stopped smoking the instant it
## died would read as "nothing happened here".
func smoke_target_for(pad: PadRec) -> float:
	match pad.distress:
		DISTRESS_TROUBLED:
			return 0.42
		DISTRESS_SEVERE:
			return 1.0
		DISTRESS_FAILED:
			return 0.16
		_:
			return 0.0


## Advance the three ramps by `delta` seconds of RENDER time. Exponential
## approach, the same shape `RenderStateModel`'s emissive ramp uses, with the
## char ramp asymmetric (see `char_rise_s` / `char_fall_s`).
func advance(delta: float) -> void:
	if delta <= 0.0:
		return
	for pad: PadRec in _pads:
		var before := Vector3(pad.glow, pad.smoke, pad.char01)
		pad.glow = _approach(pad.glow, pad.glow_target, delta, glow_tau_s)
		pad.smoke = _approach(pad.smoke, pad.smoke_target, delta, smoke_tau_s)
		var tau := char_rise_s if pad.char_target > pad.char01 else char_fall_s
		pad.char01 = _approach(pad.char01, pad.char_target, delta, tau)
		if not before.is_equal_approx(Vector3(pad.glow, pad.smoke, pad.char01)):
			_buffers_dirty = true


## True once for every change that has to reach a MultiMesh, and false forever
## after until something moves again.
func take_dirty() -> bool:
	var was := _buffers_dirty
	_buffers_dirty = false
	return was


func mark_dirty() -> void:
	_buffers_dirty = true


func invalidate_puffs() -> void:
	_puffs_dirty = true


static func _approach(current: float, target: float, delta: float, tau: float) -> float:
	var alpha := clampf(delta / maxf(tau, 0.0001), 0.0, 1.0)
	var out := current + (target - current) * alpha
	return target if absf(target - out) < 0.0005 else out


# ------------------------------------------------------------------ buffers

func pads() -> Array:
	return _pads


func pad_count() -> int:
	return _pads.size()


func pad(index: int) -> PadRec:
	return _pads[index]


func pad_of(id: String) -> PadRec:
	return _pads[int(_pad_index[id])] if _pad_index.has(id) else null


func spans() -> Array:
	return _spans


func spans_by_chunk() -> Dictionary:
	return _spans_by_chunk


## `.r` emissive (heat), `.g` damage (soot), `.b` packed, `.a` anim phase — doc
## 11 §2.6's channel roles, with the packed field described at `OVERLAY_STRIDE`.
func pad_custom(index: int, overlay_state: int = 0) -> Color:
	var rec: PadRec = _pads[index]
	return Color(rec.glow, rec.char01,
			float(rec.distress) + OVERLAY_STRIDE * float(overlay_state), rec.phase)


## The wire buffer's custom data. `.r` carries the SOURCE pad's heat, so a run
## off a cooking transformer warms along its whole length; `.g` is the sag in
## metres (the vertex stage's only geometric input); `.b` is packed the same way
## as the pad's; `.a` is the pad's phase, shared so a fan animates as one thing.
func span_custom(index: int, overlay_state: int = 0) -> Color:
	var span: SpanRec = _spans[index]
	var rec: PadRec = _pads[span.pad_index]
	return Color(rec.glow, span.sag,
			float(rec.distress) + OVERLAY_STRIDE * float(overlay_state), rec.phase)


## Smoke and sparks, as one capped billboard roster. Rebuilt only when the set
## of distressed pads MOVES — not per frame and not per tick — because the
## animation itself is a shader function of `sc_time` and the buffer holds only
## where a plume starts and which slot in the loop it occupies.
##
## The cap is spent worst-first (SEVERE before FAILED before TROUBLED, then by
## id) so a city with forty warm transformers and one on fire always spends its
## billboards on the fire.
func puffs() -> Array:
	if _puffs_dirty:
		_rebuild_puffs()
	return _puffs


func puffs_dirty() -> bool:
	return _puffs_dirty


func _rebuild_puffs() -> void:
	_puffs_dirty = false
	_puffs = []
	var ranked: Array = []
	for i in _pads.size():
		var rec: PadRec = _pads[i]
		if smoke_target_for(rec) <= 0.0:
			continue
		ranked.append(i)
	ranked.sort_custom(func(a: int, b: int) -> bool:
			var pa: PadRec = _pads[a]
			var pb: PadRec = _pads[b]
			var ka := _severity_key(pa)
			var kb := _severity_key(pb)
			if ka != kb:
				return ka > kb
			return pa.id < pb.id)
	for index: int in ranked:
		var rec: PadRec = _pads[index]
		var basis := Basis.from_euler(Vector3(0.0, rec.yaw, 0.0))
		var vent := rec.world_pos + basis * Vector3(0.0, cabinet_h + 0.06, 0.18)
		for k in puffs_per_pad:
			if _puffs.size() >= puff_cap:
				return
			var puff := PuffRec.new()
			puff.pad_index = index
			puff.origin = vent
			# Evenly spaced slots in one loop plus the pad's own offset: six
			# billboards on a 1/6 stagger read as a continuous column, and two
			# adjacent pads never pulse together.
			puff.phase = fmod(rec.phase + float(k) / float(maxi(puffs_per_pad, 1)), 1.0)
			puff.size = puff_size_m
			puff.kind = 0
			_puffs.append(puff)
		if rec.distress != DISTRESS_SEVERE:
			continue
		# Sparks ride the same buffer (`power_smoke.gdshader` premultiplies), so
		# the whole distress layer stays ONE draw call however bad it gets.
		for k in 2:
			if _puffs.size() >= puff_cap:
				return
			var spark := PuffRec.new()
			spark.pad_index = index
			spark.origin = rec.world_pos + basis * Vector3(
					0.30 if k == 0 else -0.30, cabinet_h + 0.20, 0.0)
			spark.phase = fmod(rec.phase * 1.618 + 0.5 * float(k), 1.0)
			spark.size = puff_size_m * 0.42
			spark.kind = 1
			_puffs.append(spark)


func _severity_key(rec: PadRec) -> int:
	match rec.distress:
		DISTRESS_SEVERE:
			return 3
		DISTRESS_FAILED:
			return 2
		DISTRESS_TROUBLED:
			return 1
		_:
			return 0


## `.r` severity, `.g` billboard size in metres, `.b` packed kind + overlay,
## `.a` anim phase — the same four roles again.
func puff_custom(index: int, overlay_state: int = 0) -> Color:
	var puff: PuffRec = _puffs[index]
	var rec: PadRec = _pads[puff.pad_index]
	return Color(rec.smoke, puff.size,
			float(puff.kind) + OVERLAY_STRIDE * float(overlay_state), puff.phase)


## The world-space box a set of spans occupies, sag included — what a wire
## bucket's `custom_aabb` has to be, since the vertex stage moves geometry the
## CPU-side mesh does not know about.
func span_aabb(indices: Array) -> AABB:
	if indices.is_empty():
		return AABB(Vector3.ZERO, Vector3.ZERO)
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for index: int in indices:
		var span: SpanRec = _spans[index]
		for p: Vector3 in [span.from, span.to]:
			lo = Vector3(minf(lo.x, p.x), minf(lo.y, p.y), minf(lo.z, p.z))
			hi = Vector3(maxf(hi.x, p.x), maxf(hi.y, p.y), maxf(hi.z, p.z))
		lo.y = minf(lo.y, minf(span.from.y, span.to.y) - span.sag)
	var margin := Vector3(0.5, 0.5, 0.5)
	return AABB(lo - margin, (hi - lo) + margin * 2.0)


## The pad layer's box. One MultiMesh carries every pad in the city (see
## `PowerInfraView`), so this is the whole roster's extent plus the cabinet.
func pad_aabb() -> AABB:
	if _pads.is_empty():
		return AABB(Vector3.ZERO, Vector3.ZERO)
	var lo := Vector3(INF, 0.0, INF)
	var hi := Vector3(-INF, cabinet_h + 0.6, -INF)
	for rec: PadRec in _pads:
		lo = Vector3(minf(lo.x, rec.world_pos.x), 0.0, minf(lo.z, rec.world_pos.z))
		hi = Vector3(maxf(hi.x, rec.world_pos.x), hi.y, maxf(hi.z, rec.world_pos.z))
	var margin := Vector3(maxf(pad_size.x, pad_size.y), 0.0, maxf(pad_size.x, pad_size.y))
	return AABB(lo - margin - Vector3(0.0, 0.5, 0.0),
			(hi - lo) + margin * 2.0 + Vector3(0.0, 1.0, 0.0))


## The box every puff can reach: its origin plus the full rise and the widest
## the billboard grows to.
func puff_aabb() -> AABB:
	var live := puffs()
	if live.is_empty():
		return AABB(Vector3.ZERO, Vector3.ZERO)
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for puff: PuffRec in live:
		lo = Vector3(minf(lo.x, puff.origin.x), minf(lo.y, puff.origin.y),
				minf(lo.z, puff.origin.z))
		hi = Vector3(maxf(hi.x, puff.origin.x), maxf(hi.y, puff.origin.y + puff_rise_m),
				maxf(hi.z, puff.origin.z))
	var margin := Vector3(puff_size_m * 3.0, 0.0, puff_size_m * 3.0)
	return AABB(lo - margin, (hi - lo) + margin * 2.0 + Vector3(0.0, puff_size_m * 3.0, 0.0))
