class_name AudioEvents
extends RefCounted
## The mix's brain (doc 11 §2.15): sim/UI events in, *scheduled cues* out, plus
## the running ambience picture. Headless and Node-free — no `AudioServer`, no
## clock, no scene — so the whole of the interesting behaviour is testable in
## `tests/test_audio_model.gd` and `AudioService` is left with nothing to decide.
##
## Ingest is one call — `feed(event)` — taking a **sim bus event verbatim**
## (`sim/core/event_bus.gd` dictionaries: a `type` plus that system's payload),
## exactly like `ui/alerts_model.gd`. The shell pipes the same drained batch into
## both; nothing upstream knows this class exists, and this class never holds a
## sim reference. `game/render/render_state_model.gd`'s outward hooks
## (`render_blackout_started`, `render_relight_started`) are accepted from the
## same door, and the UI layer feeds three synthetic events — `ui_tap`,
## `ui_confirm`, `ui_deny` — so there is exactly one path from "something
## happened" to "a sound is scheduled".
##
## Four behaviours are the whole design:
##
##   * **Dedup.** A repeat of a cue inside its `dedup_s` window folds into the
##     one already scheduled and bumps its `count` — which is what makes a
##     blackout that darkens twelve blocks ONE thunk rather than twelve. The
##     `dedup_by` field picks the identity: `cue` (they are all one story) or
##     `key` (each unit, each block is its own).
##   * **Cooldown.** Measured from the last *accepted request*, not from
##     playback, so a thunder delayed four seconds behind its flash still gates
##     the next one.
##   * **Distance.** Every event is placed before any rule is tried, so
##     `@distance_m` is a field a rule can match on — that is how lightning picks
##     the crack or the rumble without a second concept — and an event beyond a
##     cue's `max_m` is dropped outright rather than played at -60 dB.
##   * **Delay.** `speed_of_sound: true` schedules the cue at
##     `distance / 340 m·s⁻¹` behind the event, which is the only reason thunder
##     lands after the flash instead of on it.
##
## Positions: an event that carries `world_pos`/`pos`/`tile` places itself. One
## that carries only an id is placed by an injected `locator` —
## `Callable(kind: StringName, id: Variant) -> Vector3` — because only the shell
## knows where an id sits in metres (the same Callable `AlertsModel` takes). An
## event that resolves to nothing plays *at the listener*: a missing locator
## makes the mix flat, never silent.

## `feed()` returns this when the event makes no sound — an empty Dictionary, so
## `if not result.is_empty()` is the whole contract.
const NOT_SONIFIED := {}

## Derived field a rule may match on, injected alongside the payload. Resolved
## before any rule is tried, which is what lets lightning pick the crack or the
## rumble off `{"range": {"@distance_m": {"max": 260.0}}}` rather than needing a
## second cue-selection concept.
const DERIVED_DISTANCE := "@distance_m"

const DEDUP_CUE := "cue"
const DEDUP_KEY := "key"

const CURVE_INVERSE := "inverse"
const CURVE_LINEAR := "linear"
## `none` opts a cue out of the positional model entirely — the player's own
## confirmation and a critical sting are feedback, not scenery, and must not get
## quieter because the camera drifted.
const CURVE_NONE := "none"

const SOURCE_DAY := "day"
const SOURCE_NIGHT := "night"
const SOURCE_PRECIP := "precip"
const SOURCE_WIND := "wind"
const SOURCE_SITES := "sites"

## Event types this class learns from even when they make no sound of their own
## — the weather that drives the beds, the incident whose place a later siren
## borrows, the construction site the crane loop follows.
const OBSERVED_TYPES := [
	"weather_changed",
	"incident_created", "incident_resolved", "incident_closed",
	"building_placed_sim", "building_construction_stage", "upgrade_started_sim",
	"building_completed", "building_destroyed", "building_demolished",
]

const MIN_GAIN_DB := -60.0
const _DEFAULT_TILE_M := 8.0
const _DEFAULT_SPEED_OF_SOUND := 340.0
const _DEFAULT_MAX_DELAY_S := 8.0
const _DEFAULT_SITE_TTL_S := 600.0

var _cfg: AudioConfig
var _rules: Array = []
var _mix: Dictionary = {}
var _world: Dictionary = {}
var _position_keys: Array = []
var _default_attenuation: Dictionary = {}
var _tile_m := _DEFAULT_TILE_M
var _speed_of_sound := _DEFAULT_SPEED_OF_SOUND
var _max_delay_s := _DEFAULT_MAX_DELAY_S

var _rng := RandomNumberGenerator.new()
var _locator := Callable()

## Seconds since setup, advanced only by `update()` — this class never reads a
## clock, so a test drives it a frame at a time and gets the same answer twice.
var _now := 0.0
var _listener := Vector3.ZERO
var _seq := 0

var _pending: Array[Dictionary] = []   ## scheduled, not yet due
var _last_at: Dictionary = {}          ## identity -> last accepted request time
## The set of event types worth a second look, built once from the rules plus
## `OBSERVED_TYPES`. doc 10's vehicle feed alone is ~1,400 events per game hour
## and every one of them carries a `pos`, so an unrecognised type has to cost one
## dictionary probe — not a position resolve and a locator call.
var _interesting: Dictionary = {}

## Ambience inputs. `night01` comes from the shell's day/night controller; the
## weather pair is read straight off `weather_changed`.
var _night01 := 0.0
var _precip01 := 0.0
var _wind_kph := 0.0
var _sites: Dictionary = {}            ## building id -> {"pos": Vector3, "seen": float}
var _incident_pos: Dictionary = {}     ## incident_id -> Vector3
var _bed_gain: Dictionary = {}
var _bed_pitch: Dictionary = {}

var _duck := 0.0
var _duck_target := 0.0

var missing_cues: PackedStringArray = []


func _init(cfg: AudioConfig = null) -> void:
	if cfg == null:
		return
	_cfg = cfg
	_rules = cfg.rules()
	_mix = cfg.mix()
	_world = cfg.world()
	_tile_m = AudioConfig.get_num(_world, "tile_m", _DEFAULT_TILE_M)
	_speed_of_sound = maxf(1.0, AudioConfig.get_num(_world, "speed_of_sound_ms",
			_DEFAULT_SPEED_OF_SOUND))
	_max_delay_s = AudioConfig.get_num(_world, "max_delay_s", _DEFAULT_MAX_DELAY_S)
	var keys: Variant = _world.get("position_keys", [])
	_position_keys = keys if keys is Array else []
	var att: Variant = _world.get("default_attenuation", {})
	_default_attenuation = att if att is Dictionary else {}
	_rng.seed = int(AudioConfig.get_num(_mix, "rng_seed", 0.0))
	for type_name: String in OBSERVED_TYPES:
		_interesting[type_name] = true
	for raw: Variant in _rules:
		_interesting[str((raw as Dictionary).get("type", ""))] = true
	for bed_id: String in cfg.bed_ids():
		_bed_gain[bed_id] = 0.0
		_bed_pitch[bed_id] = 1.0


static func load_from_files() -> AudioEvents:
	return AudioEvents.new(AudioConfig.load_from_files())


func config() -> AudioConfig:
	return _cfg


## `Callable(kind: StringName, id: Variant) -> Variant` returning a `Vector3`
## (anything else reads as "no position"). Injected by the shell — the only layer
## that knows where a block or a building sits in metres. `game/main.gd` already
## has one for the alerts centre; audio takes the same Callable.
func set_locator(locator: Callable) -> void:
	_locator = locator


func set_listener(pos: Vector3) -> void:
	_listener = pos


## Direct ambience control for the shell or a test. `weather_changed` writes the
## same two values, so this is only needed when there is no weather event yet.
func set_weather(precip01: float, wind_kph: float) -> void:
	_precip01 = clampf(precip01, 0.0, 1.0)
	_wind_kph = maxf(0.0, wind_kph)


## Drop everything scheduled and every cooldown — a save load replaced the city,
## and the thunder from the old one must not arrive in the new one.
func reset() -> void:
	_pending.clear()
	_last_at.clear()
	_sites.clear()
	_incident_pos.clear()
	_duck = 0.0
	_duck_target = 0.0


# ---------------------------------------------------------------------------
# Ingest
# ---------------------------------------------------------------------------

## One event in, one **scheduled** cue out (or `{}` when the event makes no
## sound). The cue is not "played" here — it is queued at `due_at` and handed to
## the caller by `update()`, which is what lets thunder trail its flash.
func feed(event: Dictionary) -> Dictionary:
	var type_name := str(event.get("type", ""))
	# One probe decides whether this event is ours at all. Everything below —
	# placing it, matching it, scheduling it — is off the hot path for the
	# ~99% of a drained batch that is doc 10's traffic feed.
	if not _interesting.has(type_name):
		return NOT_SONIFIED

	var world_pos: Variant = _position_of(event)
	_remember(event, type_name, world_pos)

	var placed := world_pos is Vector3
	var distance := _listener.distance_to(world_pos) if placed else 0.0
	var delay := 0.0
	var rule := rule_for(event, {DERIVED_DISTANCE: distance})
	if rule.is_empty():
		return NOT_SONIFIED
	var cue_id := str(rule.get("cue", ""))
	var cue_def := _cfg.cue(cue_id) if _cfg != null else {}
	if cue_def.is_empty():
		if not missing_cues.has(cue_id):
			missing_cues.append(cue_id)
		return NOT_SONIFIED

	# Distance decides audibility BEFORE a voice is reserved: a strike four
	# kilometres past the far edge of the map is not a quiet sound, it is no
	# sound, and it must not cost a player.
	var attenuation := _attenuation_for(rule, cue_def)
	var reach01 := _attenuate(distance, attenuation) if placed else 1.0
	if reach01 <= 0.0:
		return NOT_SONIFIED

	if bool(rule.get("speed_of_sound", false)) and placed:
		delay = clampf(distance / _speed_of_sound, 0.0, _max_delay_s)

	var identity := _identity(rule, cue_id, event)
	var dedup_s := AudioConfig.get_num(rule, "dedup_s", 0.0)
	var merged := _merge_pending(identity, dedup_s)
	if not merged.is_empty():
		return merged

	var cooldown := AudioConfig.get_num(rule, "cooldown_s", 0.0)
	if cooldown > 0.0 and _last_at.has(identity) \
			and _now - float(_last_at[identity]) < cooldown:
		return NOT_SONIFIED
	_last_at[identity] = _now

	var gain_db := AudioConfig.get_num(cue_def, "gain_db", 0.0)
	gain_db += linear_to_db(maxf(reach01, 0.0001))
	gain_db += _value_gain_db(rule, event)
	var jitter := AudioConfig.get_num(cue_def, "pitch_jitter", 0.0)
	var pitch := 1.0 + (_rng.randf_range(-jitter, jitter) if jitter > 0.0 else 0.0)

	_seq += 1
	var scheduled := {
		"seq": _seq,
		"cue": cue_id,
		"stream": str(cue_def.get("stream", cue_id)),
		"bus": str(cue_def.get("bus", "SFX")),
		"gain_db": maxf(gain_db, MIN_GAIN_DB),
		"reach01": reach01,
		"pitch": pitch,
		"delay_s": delay,
		"due_at": _now + delay,
		"distance_m": distance,
		"placed": placed,
		"world_pos": world_pos if placed else _listener,
		"identity": identity,
		"count": 1,
		"duck": AudioConfig.get_num(cue_def, "duck", 0.0),
		"priority": AudioConfig.get_int(cue_def, "priority", 1),
		"event_type": type_name,
	}
	_pending.append(scheduled)
	return scheduled


## Drain-shaped ingest: hand it `SimEventBus.drain()` and get back only the cues
## that were actually scheduled or folded into, oldest first.
func feed_batch(events: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw: Variant in events:
		if not (raw is Dictionary):
			continue
		var scheduled := feed(raw)
		if not scheduled.is_empty():
			out.append(scheduled)
	return out


## First matching rule wins, so `data/audio.json` orders the two
## `BlockDarkChanged` rules and the near-lightning rule ahead of the far one.
func rule_for(event: Dictionary, ctx: Dictionary = {}) -> Dictionary:
	var type_name := str(event.get("type", ""))
	if type_name == "":
		return {}
	for raw: Variant in _rules:
		var rule: Dictionary = raw
		if str(rule.get("type", "")) != type_name:
			continue
		if not _matches(rule.get("match", {}), event):
			continue
		if not _in_range(rule.get("range", {}), event, ctx):
			continue
		return rule
	return {}


## Exact equality, JSON-number aware — the shape `AlertsModel` uses, for the same
## reason: JSON has one number type, so bools and numbers compare by value.
static func _matches(raw_match: Variant, event: Dictionary) -> bool:
	if not (raw_match is Dictionary):
		return true
	for key: String in (raw_match as Dictionary):
		var wanted: Variant = (raw_match as Dictionary)[key]
		if not event.has(key):
			return false
		var actual: Variant = event[key]
		if wanted is bool or actual is bool:
			if bool(actual) != bool(wanted):
				return false
		elif (wanted is float or wanted is int) and (actual is float or actual is int):
			if not is_equal_approx(float(actual), float(wanted)):
				return false
		elif str(actual) != str(wanted):
			return false
	return true


## `{"range": {"@distance_m": {"max": 260.0}}}`. Reads the derived context first,
## then the payload — so a rule can key off metres the sim never computed.
static func _in_range(raw_range: Variant, event: Dictionary, ctx: Dictionary) -> bool:
	if not (raw_range is Dictionary):
		return true
	for key: String in (raw_range as Dictionary):
		var bounds: Variant = (raw_range as Dictionary)[key]
		if not (bounds is Dictionary):
			continue
		var source: Variant = ctx.get(key, event.get(key, null))
		if not (source is float or source is int):
			return false
		var value := float(source)
		var window: Dictionary = bounds
		if window.has("min") and value < AudioConfig.get_num(window, "min", 0.0):
			return false
		if window.has("max") and value > AudioConfig.get_num(window, "max", 0.0):
			return false
	return true


func _identity(rule: Dictionary, cue_id: String, event: Dictionary) -> String:
	var key_name := str(rule.get("key", ""))
	var mode := str(rule.get("dedup_by", DEDUP_KEY if key_name != "" else DEDUP_CUE))
	if mode == DEDUP_KEY and key_name != "" and event.has(key_name):
		return "%s/%s" % [cue_id, str(event[key_name])]
	return cue_id


## Fold a repeat into the instance already scheduled. Only cues still waiting to
## be handed out can absorb one, which is exactly right: once a sound has been
## given to a voice, the next request is a new sound.
func _merge_pending(identity: String, dedup_s: float) -> Dictionary:
	if dedup_s <= 0.0:
		return NOT_SONIFIED
	for entry: Dictionary in _pending:
		if str(entry["identity"]) != identity:
			continue
		if _now - (float(entry["due_at"]) - float(entry["delay_s"])) > dedup_s:
			continue
		entry["count"] = int(entry["count"]) + 1
		return entry
	return NOT_SONIFIED


## `gain_from` maps a 0..1 payload field onto a dB range — lightning's
## `magnitude` is the one that matters, so a weak strike is not a loud one.
func _value_gain_db(rule: Dictionary, event: Dictionary) -> float:
	var field := str(rule.get("gain_from", ""))
	if field == "" or not event.has(field):
		return 0.0
	var raw: Variant = event[field]
	if not (raw is float or raw is int):
		return 0.0
	var span: Variant = rule.get("gain_range_db", null)
	if not (span is Array) or (span as Array).size() < 2:
		return 0.0
	var lo := float((span as Array)[0])
	var hi := float((span as Array)[1])
	return lerpf(lo, hi, clampf(float(raw), 0.0, 1.0))


# ---------------------------------------------------------------------------
# Position
# ---------------------------------------------------------------------------

## Fixed precedence, independent of any rule — the distance has to exist before
## the rules are tried, because a rule may match on it. Returns a `Vector3` or
## `null` for "wherever the listener is".
func _position_of(event: Dictionary) -> Variant:
	var world: Variant = event.get("world_pos", null)
	if world is Vector3:
		return world
	var pos: Variant = event.get("pos", null)
	if pos is Vector3:
		return pos
	if pos is Vector2:
		return _tile_to_world(float((pos as Vector2).x), float((pos as Vector2).y))
	var tile: Variant = event.get("tile", null)
	if tile is Array and (tile as Array).size() >= 2:
		return _tile_to_world(float((tile as Array)[0]), float((tile as Array)[1]))
	if tile is Vector2i:
		return _tile_to_world(float((tile as Vector2i).x), float((tile as Vector2i).y))
	# A dispatch carries the incident it is answering, not a place: the incident
	# told us where it was when it was created, and that is where the siren goes.
	var incident: Variant = event.get("incident_id", null)
	if incident != null and _incident_pos.has(str(incident)):
		return _incident_pos[str(incident)]
	if not _locator.is_valid():
		return null
	for raw: Variant in _position_keys:
		if not (raw is Array) or (raw as Array).size() < 2:
			continue
		var pair: Array = raw
		var field := str(pair[0])
		if not event.has(field):
			continue
		var located: Variant = _locator.call(StringName(str(pair[1])), event[field])
		if located is Vector3:
			return located
	return null


func _tile_to_world(tx: float, tz: float) -> Vector3:
	return Vector3(tx * _tile_m + _tile_m * 0.5, 0.0, tz * _tile_m + _tile_m * 0.5)


func _attenuation_for(rule: Dictionary, cue_def: Dictionary) -> Dictionary:
	for source: Dictionary in [rule, cue_def]:
		var raw: Variant = source.get("attenuation", null)
		if raw is Dictionary and not (raw as Dictionary).is_empty():
			return raw
	return _default_attenuation


## 1.0 inside `ref_m`, falling to exactly 0.0 at `max_m` so a distant event can
## be dropped rather than mixed. The `inverse` curve is `ref/d` with a linear
## window fade over the last stretch, which keeps the near field natural and
## still reaches true zero.
func _attenuate(distance: float, attenuation: Dictionary) -> float:
	var curve := str(attenuation.get("curve", CURVE_INVERSE))
	if curve == CURVE_NONE:
		return 1.0
	var ref_m := maxf(0.01, AudioConfig.get_num(attenuation, "ref_m", 90.0))
	var max_m := AudioConfig.get_num(attenuation, "max_m", 1400.0)
	if max_m <= 0.0:
		return 1.0
	if distance >= max_m:
		return 0.0
	if distance <= ref_m:
		return 1.0
	var window := clampf((max_m - distance) / maxf(max_m - ref_m, 0.0001), 0.0, 1.0)
	if str(attenuation.get("curve", CURVE_INVERSE)) == CURVE_LINEAR:
		return window
	return (ref_m / maxf(distance, ref_m)) * window


# ---------------------------------------------------------------------------
# Memory: what an event tells us about the world, whether or not it makes a sound
# ---------------------------------------------------------------------------

func _remember(event: Dictionary, type_name: String, world_pos: Variant) -> void:
	match type_name:
		"weather_changed":
			_precip01 = clampf(AudioConfig.get_num(event, "precip01", 0.0), 0.0, 1.0)
			_wind_kph = maxf(0.0, AudioConfig.get_num(event, "wind_kph", 0.0))
		"incident_created":
			if world_pos is Vector3 and event.has("incident_id"):
				_incident_pos[str(event["incident_id"])] = world_pos
		"incident_resolved", "incident_closed":
			_incident_pos.erase(str(event.get("incident_id", "")))
		"building_placed_sim", "building_construction_stage", "upgrade_started_sim":
			var key := _site_key(event)
			if key != "":
				_sites[key] = {
					"pos": world_pos if world_pos is Vector3 else _listener,
					"seen": _now,
				}
		"building_completed", "building_destroyed", "building_demolished":
			_sites.erase(_site_key(event))
		_:
			pass


## Sites are keyed on the integer building id, the one field every construction
## event carries (`building_completed` has no `sim_id`).
static func _site_key(event: Dictionary) -> String:
	for field: String in ["building", "sim_id"]:
		if event.has(field):
			return str(event[field])
	return ""


## A cancelled job leaves no completion event, so a site that has not been heard
## from in `ttl_s` is retired rather than droning forever.
func _expire_sites() -> void:
	var ttl := AudioConfig.get_num(_cfg.bed("site") if _cfg != null else {},
			"ttl_s", _DEFAULT_SITE_TTL_S)
	if ttl <= 0.0:
		return
	for key: Variant in _sites.keys():
		if _now - float((_sites[key] as Dictionary)["seen"]) > ttl:
			_sites.erase(key)


# ---------------------------------------------------------------------------
# Per-frame
# ---------------------------------------------------------------------------

## Advance, then hand back every cue that has come due. `dt` is real seconds —
## audio runs on the wall, not on the sim clock, so a paused city still rains.
func update(dt: float, listener_pos: Vector3, night01: float) -> Array[Dictionary]:
	_now += maxf(dt, 0.0)
	_listener = listener_pos
	_night01 = clampf(night01, 0.0, 1.0)

	var due: Array[Dictionary] = []
	var keep: Array[Dictionary] = []
	for entry: Dictionary in _pending:
		if float(entry["due_at"]) <= _now:
			due.append(entry)
		else:
			keep.append(entry)
	_pending = keep
	due.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["seq"]) < int(b["seq"]))

	_expire_sites()
	_update_beds()
	_update_duck(dt, due)
	return due


## Ambience targets, recomputed every frame from the inputs the shell and the
## weather system hand over. `AudioService` ramps toward these; nothing here
## knows what a ramp is.
func _update_beds() -> void:
	if _cfg == null:
		return
	for bed_id: String in _cfg.bed_ids():
		var bed := _cfg.bed(bed_id)
		var gain := 0.0
		var pitch := 1.0
		match str(bed.get("source", "")):
			SOURCE_DAY:
				gain = 1.0 - _night01
			SOURCE_NIGHT:
				gain = _night01
			SOURCE_PRECIP:
				var threshold := AudioConfig.get_num(bed, "threshold", 0.0)
				var span := maxf(1.0 - threshold, 0.0001)
				var x := clampf((_precip01 - threshold) / span, 0.0, 1.0)
				gain = pow(x, AudioConfig.get_num(bed, "exponent", 1.0))
			SOURCE_WIND:
				var lo := AudioConfig.get_num(bed, "min_kph", 0.0)
				var hi := AudioConfig.get_num(bed, "max_kph", 100.0)
				var w := clampf((_wind_kph - lo) / maxf(hi - lo, 0.0001), 0.0, 1.0)
				gain = pow(w, AudioConfig.get_num(bed, "exponent", 1.0))
				pitch = lerpf(1.0, AudioConfig.get_num(bed, "pitch_at_max", 1.0), w)
			SOURCE_SITES:
				gain = _site_bed_gain(bed)
			_:
				gain = 0.0
		_bed_gain[bed_id] = clampf(maxf(gain, AudioConfig.get_num(bed, "floor", 0.0)),
				0.0, 1.0)
		_bed_pitch[bed_id] = pitch


## Site bed: how many are live (up to `ref_count`) times how close the nearest
## one is. Two cranes across the map are quieter than one outside the window.
func _site_bed_gain(bed: Dictionary) -> float:
	if _sites.is_empty():
		return 0.0
	var nearest := INF
	for key: Variant in _sites:
		var site: Dictionary = _sites[key]
		nearest = minf(nearest, _listener.distance_to(site["pos"]))
	var att: Variant = bed.get("attenuation", {})
	var reach := _attenuate(nearest, att if att is Dictionary else {})
	var ref_count := maxf(1.0, AudioConfig.get_num(bed, "ref_count", 1.0))
	return clampf(float(_sites.size()) / ref_count, 0.0, 1.0) * reach


## Ducking: a cue with a `duck` pulls the beds down, fast in and slow out, so the
## thunder has a hole to land in and the city fades back rather than snapping.
func _update_duck(dt: float, due: Array[Dictionary]) -> void:
	for entry: Dictionary in due:
		_duck_target = maxf(_duck_target, float(entry["duck"]))
	var attack := maxf(AudioConfig.get_num(_mix, "duck_attack_s", 0.06), 0.0001)
	var release := maxf(AudioConfig.get_num(_mix, "duck_release_s", 1.0), 0.0001)
	var step := maxf(dt, 0.0)
	if _duck_target > _duck:
		_duck += (_duck_target - _duck) * (1.0 - exp(-step / attack))
	else:
		_duck = _duck_target
	_duck_target *= exp(-step / release)
	if _duck < 0.0005:
		_duck = 0.0


# ---------------------------------------------------------------------------
# Read side
# ---------------------------------------------------------------------------

func bed_ids() -> Array[String]:
	return _cfg.bed_ids() if _cfg != null else ([] as Array[String])


## 0..1 target for one bed, before the bed's own `gain_db` and before the duck.
func bed_gain(bed_id: String) -> float:
	return float(_bed_gain.get(bed_id, 0.0))


func bed_pitch(bed_id: String) -> float:
	return float(_bed_pitch.get(bed_id, 1.0))


## 0..1 — how far `AudioService` should pull the ambience bus down right now.
func duck01() -> float:
	return _duck


func now() -> float:
	return _now


func pending_count() -> int:
	return _pending.size()


func active_site_count() -> int:
	return _sites.size()


func precip01() -> float:
	return _precip01


func wind_kph() -> float:
	return _wind_kph


func night01() -> float:
	return _night01
