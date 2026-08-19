class_name AudioService
extends Node
## The mix's hands (doc 11 §2.15). Owns the buses, a small polyphonic voice pool
## and one looping player per ambience bed — and decides **nothing**: which cue,
## how loud, how far and how late all come from `AudioEvents`, which is
## Node-free and tested headless. If a sound is wrong, the fix is in
## `data/audio.json` or `game/audio/audio_events.gd`, never here.
##
## `AudioDirector` in doc 11 §2.15 is this class under its planning-era name: a
## listener on the same drained event batch `RenderBridge` consumes, never a
## second consumer of sim state and never a `sim/` dependency.
##
## Wiring, in the shell (`game/main.gd`):
##
##     audio = AudioService.new(); add_child(audio); audio.setup()
##     audio.set_locator(_alert_world_pos)                        # ids → metres
##     audio.set_sound_volume(settings_model.value_num("sound_volume"))
##     sim_host.ticked.connect(audio.feed_batch)                  # sim events
##     ui_root.ui_coverage_changed.connect(audio.set_ui_coverage) # interior muffle
##     ... each sim tick:
##     audio.feed_unit_states(sim.incidents.vehicle_states())     # moving sirens
##     ... each frame:
##     audio.update_audio(delta, camera_rig.camera.global_position,
##             environment_controller.last_night)
##
## Volume is `ui/settings_model.gd`'s `sound_volume` row (0..1, default 0.8)
## applied to the Master bus, and at 0 the bus is *muted* rather than played at
## -60 dB — a phone that is told to be silent should cost nothing to be silent.

const BUS_MASTER := &"Master"
const UI_TAP := &"ui_tap"
const UI_CONFIRM := &"ui_confirm"
const UI_DENY := &"ui_deny"

const _MIN_AUDIBLE_LINEAR := 0.0001

var events: AudioEvents

## Non-fatal bring-up problems, kept rather than pushed: a missing asset makes
## the game quieter, and `tests/test_audio_model.gd` is where it becomes loud.
var missing_streams: PackedStringArray = []

var _cfg: AudioConfig
var _mix: Dictionary = {}
var _streams: Dictionary = {}          ## stream name -> AudioStream
## {player, cue, priority, started_at, busy_until}. Occupancy is tracked on the
## cue's own length rather than polled off `AudioStreamPlayer.playing`: the
## driver's answer lags a frame, and a pool that mis-reads "free" steals a voice
## that is still sounding. It also makes the whole stealing policy deterministic,
## which is why `tests/test_audio_model.gd` can hold it to account.
var _voices: Array[Dictionary] = []
var _beds: Dictionary = {}             ## bed id -> {player, current, gain_db, running}
var _bus_indices: Dictionary = {}

var _sound_volume := 1.0
var _muted := false
var _elapsed := 0.0
var _ready_to_play := false

## Interior muffle. `_coverage` is what the UI last reported (0 = nothing over
## the city, 1 = a full-screen sheet); `_muffle` is the ramped value the filter
## actually runs at, so opening a sheet is a fade and not a switch.
var _coverage := 0.0
var _muffle := 0.0
var _muffle_spec: Dictionary = {}
var _lowpass: AudioEffectLowPassFilter = null
var _muffle_bus := -1
var _muffle_bus_db := 0.0


func setup(cfg: AudioConfig = null) -> void:
	_cfg = cfg if cfg != null else AudioConfig.load_from_files()
	_mix = _cfg.mix()
	events = AudioEvents.new(_cfg)
	_build_buses()
	_build_muffle()
	_build_voices()
	_build_beds()
	_apply_master()
	_ready_to_play = true


## `Callable(kind: StringName, id: Variant) -> Vector3` — forwarded straight to
## the model. `game/main.gd` already has one for the alerts centre.
func set_locator(locator: Callable) -> void:
	if events != null:
		events.set_locator(locator)


# ---------------------------------------------------------------------------
# Buses
# ---------------------------------------------------------------------------

func _build_buses() -> void:
	_bus_indices[String(BUS_MASTER)] = 0
	for raw: Variant in _cfg.buses():
		if not (raw is Dictionary):
			continue
		var spec: Dictionary = raw
		var name := str(spec.get("name", ""))
		if name == "":
			continue
		var index := AudioServer.get_bus_index(name)
		if index < 0:
			index = AudioServer.bus_count
			AudioServer.add_bus(index)
			AudioServer.set_bus_name(index, name)
		AudioServer.set_bus_send(index, str(spec.get("send", String(BUS_MASTER))))
		AudioServer.set_bus_volume_db(index, AudioConfig.get_num(spec, "volume_db", 0.0))
		_bus_indices[name] = index


# ---------------------------------------------------------------------------
# Interior muffle
# ---------------------------------------------------------------------------

## One `AudioEffectLowPassFilter`, on the **Ambient bus only**, created once.
##
## When a sheet or a panel covers more than half the screen the player has
## stopped looking at the city and started looking at a document about it — and
## the city should be heard the way it is seen: through something. Rolling the
## ambience off (and trimming it a few dB) is the cheapest possible version of
## that, and it is the correct one, because the alternative — a second set of
## "interior" beds — would double the asset budget to say the same thing.
##
## The SFX and UI buses are deliberately untouched. A confirmation blip and a
## critical sting are in the room with the player, not out of the window; if
## they muffled too, the sheet would feel like a fault rather than a place.
func _build_muffle() -> void:
	_muffle_spec = _mix.get("muffle", {}) if _mix.get("muffle", null) is Dictionary else {}
	if _muffle_spec.is_empty():
		return
	var bus_name := str(_muffle_spec.get("bus", "Ambient"))
	_muffle_bus = AudioServer.get_bus_index(bus_name)
	if _muffle_bus < 0:
		return
	_muffle_bus_db = AudioServer.get_bus_volume_db(_muffle_bus)
	# Idempotent: `setup()` runs once per process in the game but repeatedly
	# across a test file, and a second filter on the same bus would double the
	# rolloff for every test after the first.
	for i in AudioServer.get_bus_effect_count(_muffle_bus):
		var existing := AudioServer.get_bus_effect(_muffle_bus, i) as AudioEffectLowPassFilter
		if existing != null:
			_lowpass = existing
			break
	if _lowpass == null:
		_lowpass = AudioEffectLowPassFilter.new()
		AudioServer.add_bus_effect(_muffle_bus, _lowpass)
	_lowpass.resonance = AudioConfig.get_num(_muffle_spec, "resonance", 0.5)
	_apply_muffle()


## What `ui/ui_root.gd` reports: the fraction of the screen currently covered by
## a sheet or panel. Below `threshold01` nothing happens at all — a 300 dp side
## panel is not an interior — and the roll-off reaches full at `full01`.
func set_ui_coverage(coverage01: float) -> void:
	_coverage = clampf(coverage01, 0.0, 1.0)


func ui_coverage() -> float:
	return _coverage


## 0..1 — how far the muffle has actually ramped, which is not the same as how
## much of the screen is covered until the ramp has caught up.
func muffle01() -> float:
	return _muffle


func muffle_cutoff_hz() -> float:
	return _lowpass.cutoff_hz if _lowpass != null else 0.0


func _muffle_target() -> float:
	if _muffle_spec.is_empty():
		return 0.0
	var threshold := AudioConfig.get_num(_muffle_spec, "threshold01", 0.5)
	var full := AudioConfig.get_num(_muffle_spec, "full01", 1.0)
	return clampf((_coverage - threshold) / maxf(full - threshold, 0.0001), 0.0, 1.0)


func _update_muffle(delta: float) -> void:
	if _lowpass == null:
		return
	var target := _muffle_target()
	var ramp := maxf(AudioConfig.get_num(_muffle_spec, "ramp_s", 0.25), 0.0001)
	_muffle = lerpf(_muffle, target, 1.0 - exp(-maxf(delta, 0.0) / ramp))
	if absf(_muffle - target) < 0.001:
		_muffle = target
	_apply_muffle()


## Cutoff is interpolated in LOG frequency, because that is the axis hearing
## uses: a linear slide from 20 kHz to 900 Hz spends its first half doing
## nothing audible and then slams shut.
func _apply_muffle() -> void:
	if _lowpass == null:
		return
	var open_hz := maxf(AudioConfig.get_num(_muffle_spec, "open_hz", 20500.0), 20.0)
	var covered_hz := maxf(AudioConfig.get_num(_muffle_spec, "covered_hz", 900.0), 20.0)
	_lowpass.cutoff_hz = open_hz * pow(covered_hz / open_hz, clampf(_muffle, 0.0, 1.0))
	if _muffle_bus >= 0:
		AudioServer.set_bus_volume_db(_muffle_bus, _muffle_bus_db
				+ AudioConfig.get_num(_muffle_spec, "covered_db", 0.0) * _muffle)


func bus_index(name: String) -> int:
	if _bus_indices.has(name):
		return int(_bus_indices[name])
	return maxi(AudioServer.get_bus_index(name), 0)


## The settings slider. 0 mutes Master outright; anything above the configured
## floor is `master_db + linear_to_db(v)`, so the data file still owns the trim.
func set_sound_volume(volume01: float) -> void:
	_sound_volume = clampf(volume01, 0.0, 1.0)
	_apply_master()


func sound_volume() -> float:
	return _sound_volume


## doc 13 §2: `NOTIFICATION_APPLICATION_FOCUS_OUT` mutes, `FOCUS_IN` restores.
func set_muted(muted: bool) -> void:
	_muted = muted
	_apply_master()


func is_muted() -> bool:
	return _muted


func _apply_master() -> void:
	var floor01 := AudioConfig.get_num(_mix, "silence_below_volume01", 0.0)
	var silent := _muted or _sound_volume <= floor01
	AudioServer.set_bus_mute(0, silent)
	if silent:
		return
	AudioServer.set_bus_volume_db(0, AudioConfig.get_num(_mix, "master_db", 0.0)
			+ linear_to_db(maxf(_sound_volume, _MIN_AUDIBLE_LINEAR)))


# ---------------------------------------------------------------------------
# Streams
# ---------------------------------------------------------------------------

func _stream(stream_name: String) -> AudioStream:
	if _streams.has(stream_name):
		return _streams[stream_name]
	var path := _cfg.stream_path(stream_name)
	var loaded: AudioStream = null
	if path != "" and ResourceLoader.exists(path):
		loaded = ResourceLoader.load(path) as AudioStream
	if loaded == null and not missing_streams.has(stream_name):
		missing_streams.append(stream_name)
	_streams[stream_name] = loaded
	return loaded


## Beds must loop. `tools/gen_audio.py` writes a `smpl` chunk so Godot's importer
## detects the loop from the WAV itself, but an `.import` regenerated with
## `Disabled` would silently turn the rain into a one-shot — so the bed asserts
## it here too rather than trusting a file it does not own.
func _looping_stream(stream_name: String) -> AudioStream:
	var stream := _stream(stream_name)
	var wav := stream as AudioStreamWAV
	if wav != null and wav.loop_mode == AudioStreamWAV.LOOP_DISABLED:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = _frame_count(wav)
	return stream


## Frames from length × rate rather than from `data.size()`: the importer's
## default `compress/mode` is QOA, so the byte count is not the frame count and
## the arithmetic that works for 16-bit PCM would silently loop at the wrong
## point. Length and mix rate are true for every format.
static func _frame_count(wav: AudioStreamWAV) -> int:
	return int(round(wav.get_length() * float(wav.mix_rate)))


# ---------------------------------------------------------------------------
# Voices
# ---------------------------------------------------------------------------

func _build_voices() -> void:
	var count := maxi(1, AudioConfig.get_int(_cfg.pool(), "voices", 8))
	for i in count:
		var player := AudioStreamPlayer.new()
		player.name = "Voice%02d" % i
		add_child(player)
		_voices.append({"player": player, "cue": "", "priority": 0,
				"started_at": -1.0, "busy_until": -1.0})


func voice_count() -> int:
	return _voices.size()


func busy_voice_count() -> int:
	var count := 0
	for voice: Dictionary in _voices:
		if _voice_busy(voice):
			count += 1
	return count


## Which cue a voice is carrying right now, "" when it is free. The pool's whole
## policy is observable through this.
func voice_cue(index: int) -> String:
	if index < 0 or index >= _voices.size():
		return ""
	return str(_voices[index]["cue"]) if _voice_busy(_voices[index]) else ""


func _voice_busy(voice: Dictionary) -> bool:
	return _elapsed < float(voice["busy_until"])


## Fire one cue as `AudioEvents` scheduled it. Returns false when the pool
## refused it — every voice busy with something more important, or no asset.
func play_cue(cue: Dictionary) -> bool:
	if not _ready_to_play or cue.is_empty():
		return false
	var stream := _stream(str(cue.get("stream", "")))
	if stream == null:
		return false
	var voice := _claim_voice(str(cue.get("cue", "")),
			AudioConfig.get_int(cue, "priority", 1))
	if voice.is_empty():
		return false
	var pitch := maxf(0.05, AudioConfig.get_num(cue, "pitch", 1.0))
	var player: AudioStreamPlayer = voice["player"]
	player.stream = stream
	player.bus = str(cue.get("bus", "SFX"))
	player.volume_db = AudioConfig.get_num(cue, "gain_db", 0.0)
	player.pitch_scale = pitch
	voice["cue"] = str(cue.get("cue", ""))
	voice["priority"] = AudioConfig.get_int(cue, "priority", 1)
	voice["started_at"] = _elapsed
	voice["busy_until"] = _elapsed + maxf(stream.get_length(), 0.05) / pitch
	if player.is_inside_tree():
		player.play()
	return true


func _claim_voice(cue_id: String, priority: int) -> Dictionary:
	var free: Dictionary = {}
	var same_cue: Array[Dictionary] = []
	var weakest: Dictionary = {}
	for voice: Dictionary in _voices:
		if not _voice_busy(voice):
			if free.is_empty():
				free = voice
			continue
		if str(voice["cue"]) == cue_id:
			same_cue.append(voice)
		if weakest.is_empty() or int(voice["priority"]) < int(weakest["priority"]) \
				or (int(voice["priority"]) == int(weakest["priority"])
					and float(voice["started_at"]) < float(weakest["started_at"])):
			weakest = voice
	# At the per-cue cap the NEWEST instance wins: a fourth simultaneous thunder
	# is better spent restarting the oldest voice than stealing from a siren.
	var cap := maxi(1, AudioConfig.get_int(_cfg.pool(), "max_per_cue", 3))
	if same_cue.size() >= cap:
		same_cue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a["started_at"]) < float(b["started_at"]))
		return same_cue[0]
	if not free.is_empty():
		return free
	if not weakest.is_empty() and int(weakest["priority"]) <= priority:
		return weakest
	return {}


# ---------------------------------------------------------------------------
# Beds
# ---------------------------------------------------------------------------

func _build_beds() -> void:
	for bed_id: String in _cfg.bed_ids():
		var bed := _cfg.bed(bed_id)
		var stream := _looping_stream(str(bed.get("stream", "")))
		if stream == null:
			continue
		var player := AudioStreamPlayer.new()
		player.name = "Bed_%s" % bed_id
		player.stream = stream
		player.bus = str(bed.get("bus", "Ambient"))
		player.volume_db = AudioEvents.MIN_GAIN_DB
		add_child(player)
		_beds[bed_id] = {
			"player": player,
			"current": 0.0,
			"running": false,
			"gain_db": AudioConfig.get_num(bed, "gain_db", 0.0),
		}


func bed_level(bed_id: String) -> float:
	var bed: Variant = _beds.get(bed_id, null)
	return float((bed as Dictionary)["current"]) if bed is Dictionary else 0.0


func bed_playing(bed_id: String) -> bool:
	var bed: Variant = _beds.get(bed_id, null)
	return bool((bed as Dictionary)["running"]) if bed is Dictionary else false


func _update_beds(delta: float) -> void:
	var ramp := maxf(AudioConfig.get_num(_mix, "bed_ramp_s", 0.5), 0.0001)
	var stop_below := AudioConfig.get_num(_mix, "bed_stop_below", 0.001)
	var duck := 1.0 - clampf(events.duck01(), 0.0, 1.0)
	var alpha := 1.0 - exp(-maxf(delta, 0.0) / ramp)
	for bed_id: String in _beds:
		var bed: Dictionary = _beds[bed_id]
		var player: AudioStreamPlayer = bed["player"]
		var target := events.bed_gain(bed_id)
		var current := lerpf(float(bed["current"]), target, alpha)
		bed["current"] = current
		var level := current * duck
		# A bed at zero is STOPPED, not played at -60 dB: five silent loops
		# decoding forever is a battery cost with nothing to show for it.
		if level <= stop_below:
			if bool(bed["running"]):
				bed["running"] = false
				player.stop()
			continue
		if not bool(bed["running"]):
			bed["running"] = true
			if player.is_inside_tree():
				player.play()
		player.volume_db = float(bed["gain_db"]) + linear_to_db(maxf(level, _MIN_AUDIBLE_LINEAR))
		player.pitch_scale = maxf(0.05, events.bed_pitch(bed_id))


# ---------------------------------------------------------------------------
# The two calls the shell makes
# ---------------------------------------------------------------------------

## Hand it the same drained batch `RenderStateModel` and `AlertsModel` get.
func feed_batch(batch: Array) -> void:
	if events != null:
		events.feed_batch(batch)


## doc 06's fleet snapshot — `IncidentSystem.vehicle_states()` — once per sim
## tick, the same call `game/render/vehicle_view.gd` already takes. It is what
## gives the siren throttle a moving position for a unit that is out; without it
## the mix still works, and a dispatched unit simply sounds once at its incident
## instead of following the streets.
func feed_unit_states(states: Array) -> void:
	if events != null:
		events.feed_unit_states(states)


## One synthetic UI event — `AudioService.UI_TAP` / `UI_CONFIRM` / `UI_DENY`.
## The UI layer emits intent signals, not sounds; the shell translates.
func ui_cue(kind: StringName) -> void:
	if events != null:
		events.feed({"type": kind})


## Per frame: advance the model, play what came due, ramp the beds.
func update_audio(delta: float, listener_pos: Vector3, night01: float) -> void:
	if not _ready_to_play:
		return
	_elapsed += delta
	for cue: Dictionary in events.update(delta, listener_pos, night01):
		play_cue(cue)
	_update_beds(delta)
	_update_muffle(delta)


## A save load replaced the city: drop scheduled sound from the old one and let
## the beds fall rather than cut, so the transition is a fade and not a click.
func reset() -> void:
	if events != null:
		events.reset()
	for voice: Dictionary in _voices:
		voice["busy_until"] = -1.0
		voice["cue"] = ""
		(voice["player"] as AudioStreamPlayer).stop()
