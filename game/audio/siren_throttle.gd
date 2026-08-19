class_name SirenThrottle
extends RefCounted
## Which moving sirens are audible right now, and when each one gets its next
## pass (doc 11 §2.15's `vehicle_state.siren`, wired by the Audio-2 ruling).
##
## §2.15 listed per-vehicle sirens under **not wired, deliberately**, and gave
## the reason: doc 10's feed is ~1,400 events per game hour and "a per-vehicle
## emitter needs its own throttle design". This class is that design. The
## emitter is trivial; everything hard is here.
##
## `RefCounted`, Node-free, clock-injected: `update()` is handed `now` and the
## listener, so a test drives it a frame at a time and gets the same answer
## twice. Every iteration is over a sorted key list and the only ordering
## tiebreak is the vehicle id, so two runs of the same city produce the same
## audible set in the same order (constitution §5).
##
## Three problems, three separate mechanisms
## -----------------------------------------
##
## **How many.** `max_sources` — a hard cap on how many sirens can sound at
## once, chosen nearest-first. Not a voice-pool cap: the pool would happily give
## eight sirens eight voices, and eight sirens is not a busier city, it is mush.
##
## **Popping in and out.** One radius pops three different ways, so there are
## three defences and they cover different failures:
##
##   * `enter_m` < `exit_m` — a source must come *closer* to win a slot than it
##     must stay to keep one. This is what stops a unit hovering on the boundary
##     from strobing as the camera drifts a metre.
##   * `takeover_margin_m` — a waiting source only displaces an audible one when
##     it is that many metres **closer**, not merely closer. Two engines running
##     the same street would otherwise trade the slot every frame.
##   * `min_hold_s` — once audible, a source keeps its slot for at least this
##     long *whatever else arrives*. The first two are geometric and can both be
##     defeated by a genuinely fast approach; this one bounds how often the
##     audible set may change at all, which is the property a listener actually
##     hears.
##
## **Standing still.** `siren_pass` is a **pass-by**, doppler and all, baked into
## the asset — the ruling keeps it that way, so nothing here pitch-shifts
## anything. A unit that is audible re-triggers its pass every `retrigger_s`
## **at wherever it is now**, so the mix follows it across the city out of the
## ordinary distance model and the doppler stays authored rather than computed.
##
## Ingest is two doors into one table, exactly as `game/render/vehicle_view.gd`
## takes the same fleet two ways:
##
##   * `observe()` — doc 10's `vehicle_state` bus events (`siren` is a field).
##   * `observe_unit_states()` — doc 06's `IncidentSystem.vehicle_states()`
##     snapshot, where "siren" is the FSM status and `sirens.siren_statuses` in
##     `data/audio.json` is the only place audio names one.

## Returned by `update()` when nothing should fire this frame.
const NOTHING: Array[Dictionary] = []

const _DEFAULT_MAX_SOURCES := 2
const _DEFAULT_ENTER_M := 420.0
const _DEFAULT_EXIT_M := 640.0
const _DEFAULT_TAKEOVER_M := 90.0
const _DEFAULT_MIN_HOLD_S := 4.0
const _DEFAULT_RETRIGGER_S := 3.3
const _DEFAULT_TTL_S := 6.0
## Far enough in the past that a source seen for the first time fires at once
## without a special case in the retrigger test.
const _NEVER := -1.0e9

var _spec: Dictionary = {}
var _statuses: Dictionary = {}          ## status name -> true
var _max_sources := _DEFAULT_MAX_SOURCES
var _enter_m := _DEFAULT_ENTER_M
var _exit_m := _DEFAULT_EXIT_M
var _takeover_m := _DEFAULT_TAKEOVER_M
var _min_hold_s := _DEFAULT_MIN_HOLD_S
var _retrigger_s := _DEFAULT_RETRIGGER_S
var _ttl_s := _DEFAULT_TTL_S

## id -> {"pos": Vector3, "seen": float, "audible": bool, "since": float,
##        "last_cue": float}. Keyed by String so a doc 10 vehicle id and a doc 06
## unit id can never collide silently — the caller namespaces them.
var _sources: Dictionary = {}
var _audible: Array[String] = []


func _init(spec: Dictionary = {}) -> void:
	_spec = spec
	_max_sources = maxi(0, AudioConfig.get_int(spec, "max_sources", _DEFAULT_MAX_SOURCES))
	_enter_m = AudioConfig.get_num(spec, "enter_m", _DEFAULT_ENTER_M)
	# An exit radius inside the enter radius is not hysteresis, it is a bug that
	# makes every source strobe; clamp rather than trust the file.
	_exit_m = maxf(_enter_m, AudioConfig.get_num(spec, "exit_m", _DEFAULT_EXIT_M))
	_takeover_m = maxf(0.0, AudioConfig.get_num(spec, "takeover_margin_m", _DEFAULT_TAKEOVER_M))
	_min_hold_s = maxf(0.0, AudioConfig.get_num(spec, "min_hold_s", _DEFAULT_MIN_HOLD_S))
	_retrigger_s = maxf(0.05, AudioConfig.get_num(spec, "retrigger_s", _DEFAULT_RETRIGGER_S))
	_ttl_s = maxf(0.0, AudioConfig.get_num(spec, "ttl_s", _DEFAULT_TTL_S))
	var raw: Variant = spec.get("siren_statuses", [])
	if raw is Array:
		for entry: Variant in raw:
			_statuses[str(entry)] = true


func spec() -> Dictionary:
	return _spec


func cue_id() -> String:
	return str(_spec.get("cue", "siren_pass"))


func attenuation() -> Dictionary:
	var raw: Variant = _spec.get("attenuation", {})
	return raw if raw is Dictionary else {}


# ---------------------------------------------------------------------------
# Ingest
# ---------------------------------------------------------------------------

## One vehicle, this instant. `siren_on` false **forgets** the source rather than
## leaving it to time out: a siren that was switched off has to stop sounding
## now, not `ttl_s` from now.
func observe(id: String, world_pos: Vector3, siren_on: bool, now: float) -> void:
	if id == "":
		return
	if not siren_on:
		forget(id)
		return
	var source: Variant = _sources.get(id, null)
	if source is Dictionary:
		(source as Dictionary)["pos"] = world_pos
		(source as Dictionary)["seen"] = now
		return
	_sources[id] = {
		"pos": world_pos, "seen": now, "audible": false,
		"since": now, "last_cue": _NEVER,
	}


## doc 06's fleet snapshot (`IncidentSystem.vehicle_states()`), whole. `locate`
## turns a record into metres — the caller owns tile→world, because only it knows
## `tile_m`. Units the snapshot no longer lists, or that are no longer running
## hot, are forgotten in the same pass: a snapshot is the complete truth about
## the fleet, so absence from it *means* something, unlike a missing bus event.
func observe_unit_states(states: Array, now: float, locate: Callable,
		prefix: String = "u") -> void:
	var seen: Dictionary = {}
	for raw: Variant in states:
		if not (raw is Dictionary):
			continue
		var record: Dictionary = raw
		var id := "%s%s" % [prefix, str(record.get("id", ""))]
		seen[id] = true
		var on := _statuses.has(str(record.get("status", "")))
		if not on:
			forget(id)
			continue
		var located: Variant = locate.call(record) if locate.is_valid() else null
		observe(id, located if located is Vector3 else Vector3.ZERO, true, now)
	for id: String in _sources.keys():
		if id.begins_with(prefix) and not seen.has(id):
			forget(id)


## A siren cue for this source was scheduled by somebody else — `unit_dispatched`
## is the one that matters, and it is the unit's departure. Stamping it here is
## what makes the departure count as that unit's *first* pass, so the throttle
## waits a full `retrigger_s` instead of doubling the sound at the station door.
func note_cue(id: String, now: float) -> void:
	var source: Variant = _sources.get(id, null)
	if source is Dictionary:
		(source as Dictionary)["last_cue"] = now


func forget(id: String) -> void:
	if not _sources.has(id):
		return
	_sources.erase(id)
	_audible.erase(id)


func clear() -> void:
	_sources.clear()
	_audible.clear()


func is_empty() -> bool:
	return _sources.is_empty()


func tracks(id: String) -> bool:
	return _sources.has(id)


# ---------------------------------------------------------------------------
# Per-frame
# ---------------------------------------------------------------------------

## Retire the stale, choose the audible set, and hand back the passes to fire —
## `[{"id", "world_pos", "distance_m"}]`, nearest first. Deterministic: the only
## tiebreak is the id.
func update(now: float, listener: Vector3) -> Array[Dictionary]:
	_expire(now)
	if _sources.is_empty():
		_audible.clear()
		return NOTHING

	var distance: Dictionary = {}
	for id: String in _ids():
		distance[id] = listener.distance_to((_sources[id] as Dictionary)["pos"] as Vector3)

	var chosen := _select(now, distance)
	for id: String in _audible:
		if not chosen.has(id):
			(_sources[id] as Dictionary)["audible"] = false
	var fired: Array[Dictionary] = []
	for id: String in chosen:
		var source: Dictionary = _sources[id]
		if not bool(source["audible"]):
			source["audible"] = true
			source["since"] = now
		if now - float(source["last_cue"]) < _retrigger_s:
			continue
		source["last_cue"] = now
		fired.append({
			"id": id,
			"world_pos": source["pos"],
			"distance_m": float(distance[id]),
		})
	_audible = chosen
	return fired


## Ids in a stable order. `Dictionary` iteration order is insertion order, which
## depends on the order events happened to arrive — sorting is what makes two
## runs of the same city agree (constitution §5).
func _ids() -> Array[String]:
	var out: Array[String] = []
	for key: Variant in _sources:
		out.append(str(key))
	out.sort()
	return out


## A unit that arrives, despawns or is destroyed stops emitting rather than
## announcing that it has stopped, so silence has to expire on its own.
func _expire(now: float) -> void:
	if _ttl_s <= 0.0:
		return
	for id: String in _ids():
		if now - float((_sources[id] as Dictionary)["seen"]) > _ttl_s:
			forget(id)


## The audible set for this frame. Three tiers, in this order: sources inside
## their `min_hold_s`, then incumbents defending with `takeover_margin_m`, then
## everything else nearest-first.
func _select(now: float, distance: Dictionary) -> Array[String]:
	if _max_sources <= 0:
		return []
	var held: Array[String] = []
	var incumbents: Array[String] = []
	var challengers: Array[String] = []
	for id: String in _ids():
		var source: Dictionary = _sources[id]
		var audible := bool(source["audible"])
		# The whole of the enter/exit hysteresis is this one line.
		var reach := _exit_m if audible else _enter_m
		if float(distance[id]) > reach:
			continue
		if audible and now - float(source["since"]) < _min_hold_s:
			held.append(id)
		elif audible:
			incumbents.append(id)
		else:
			challengers.append(id)
	var by_distance := func(a: String, b: String) -> bool:
		var da := float(distance[a])
		var db := float(distance[b])
		return a < b if is_equal_approx(da, db) else da < db
	held.sort_custom(by_distance)
	incumbents.sort_custom(by_distance)
	challengers.sort_custom(by_distance)

	var chosen: Array[String] = []
	# A hold is unconditional, but it is not unlimited: if more sources are
	# inside their hold than there are slots, the nearest keep theirs.
	for id: String in held:
		if chosen.size() >= _max_sources:
			break
		chosen.append(id)
	var i := 0
	var c := 0
	while chosen.size() < _max_sources and (i < incumbents.size() or c < challengers.size()):
		if i >= incumbents.size():
			chosen.append(challengers[c])
			c += 1
		elif c >= challengers.size():
			chosen.append(incumbents[i])
			i += 1
		elif float(distance[challengers[c]]) + _takeover_m < float(distance[incumbents[i]]):
			# Closer *by the margin*: merely closer is not enough, or two units
			# on the same street would swap the slot every frame.
			chosen.append(challengers[c])
			c += 1
		else:
			chosen.append(incumbents[i])
			i += 1
	return chosen


# ---------------------------------------------------------------------------
# Read side — the whole policy is observable, which is how it is tested
# ---------------------------------------------------------------------------

func audible_ids() -> Array[String]:
	return _audible.duplicate()


func audible_count() -> int:
	return _audible.size()


func source_count() -> int:
	return _sources.size()


func tracked_ids() -> Array[String]:
	return _ids()


func source_position(id: String) -> Vector3:
	var source: Variant = _sources.get(id, null)
	return (source as Dictionary)["pos"] if source is Dictionary else Vector3.ZERO


func max_sources() -> int:
	return _max_sources


func retrigger_s() -> float:
	return _retrigger_s
