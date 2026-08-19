extends SimTest
## The soundscape (doc 11 §2.15): `data/audio.json`, `game/audio/audio_events.gd`,
## `game/audio/audio_service.gd` and the generated set from `tools/gen_audio.py`.
##
## The events fed here are the **actual dictionaries** `sim/` emits
## (`building_placed_sim`, `BlockDarkChanged`, `lightning_strike`,
## `incident_created`, `unit_dispatched`, `weather_changed`, …), so a rename on
## either side fails this file rather than going quietly silent in the mix — the
## same contract `tests/test_ui_alerts.gd` holds for the alerts centre.
##
## What is actually load-bearing here, and why each is a test:
##   * a blackout that darkens twelve blocks is ONE thunk (dedup),
##   * thunder arrives `distance / 340` seconds after its flash (delay),
##   * an event past a cue's `max_m` costs no voice at all (drop, not -60 dB),
##   * every loop is seamless and the whole set fits the 4 MB budget.

const MANIFEST := "res://game/audio/generated/manifest.json"
const SPEED_OF_SOUND := 340.0
const FRAME := 1.0 / 60.0


func _cfg() -> AudioConfig:
	return AudioConfig.load_from_files()


func _model() -> AudioEvents:
	return AudioEvents.new(_cfg())


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


## One frame at the origin, in daylight — the shell's `update()` call, minus the
## shell. Returns the cues that came due.
func _tick(model: AudioEvents, dt: float = FRAME,
		listener: Vector3 = Vector3.ZERO, night01: float = 0.0) -> Array[Dictionary]:
	return model.update(dt, listener, night01)


## Feed one event and run the frame that hands out whatever is due now.
func _fire(model: AudioEvents, event: Dictionary) -> Array[Dictionary]:
	model.feed(event)
	return _tick(model)


func _cue_ids(cues: Array[Dictionary]) -> PackedStringArray:
	var out: PackedStringArray = []
	for cue: Dictionary in cues:
		out.append(str(cue["cue"]))
	return out


# ===========================================================================
# Data + assets
# ===========================================================================

func test_01_config_is_internally_consistent() -> void:
	var cfg := _cfg()
	assert_true(cfg.is_valid(), "data/audio.json parses: %s" % str(cfg.errors))
	assert_true(cfg.cue_ids().size() >= 12, "the cue table is populated")
	assert_true(cfg.rules().size() >= 12, "the event rules are populated")

	for cue_id: String in cfg.cue_ids():
		var cue := cfg.cue(cue_id)
		var path := cfg.stream_path(str(cue.get("stream", "")))
		assert_true(FileAccess.file_exists(path),
				"cue '%s' points at a generated asset (%s)" % [cue_id, path])
		assert_ne(str(cue.get("bus", "")), "", "cue '%s' names a bus" % cue_id)

	var bus_names: PackedStringArray = ["Master"]
	for raw: Variant in cfg.buses():
		bus_names.append(str((raw as Dictionary).get("name", "")))
	for cue_id: String in cfg.cue_ids():
		assert_true(bus_names.has(str(cfg.cue(cue_id).get("bus", ""))),
				"cue '%s' names a bus that data/audio.json creates" % cue_id)

	for raw: Variant in cfg.rules():
		var rule: Dictionary = raw
		var cue_id := str(rule.get("cue", ""))
		assert_false(cfg.cue(cue_id).is_empty(),
				"rule for '%s' names a real cue ('%s')" % [str(rule.get("type", "")), cue_id])

	for bed_id: String in cfg.bed_ids():
		var bed := cfg.bed(bed_id)
		var stream := str(bed.get("stream", ""))
		assert_true(FileAccess.file_exists(cfg.stream_path(stream)),
				"bed '%s' points at a generated asset" % bed_id)
		assert_true(bool(cfg.asset(stream).get("loop", false)),
				"bed '%s' uses a looping asset" % bed_id)


func test_02_the_generated_set_fits_its_budget_and_loops_are_seamless() -> void:
	var manifest: Dictionary = StarterCityLoader.read_json(MANIFEST)
	assert_false(manifest.is_empty(), "run tools/gen_audio.py to build the set")
	var total := int(manifest.get("total_bytes", 0))
	var budget := int(manifest.get("budget_bytes", 4 * 1024 * 1024))
	assert_true(total > 0 and total <= budget,
			"the whole soundscape is %d B against a %d B budget" % [total, budget])
	assert_eq(int(manifest.get("channels", 0)), 1, "mono: a phone speaker is mono")

	var assets: Array = manifest.get("assets", [])
	assert_true(assets.size() >= 15, "the set covers every cue and bed")
	for raw: Variant in assets:
		var asset: Dictionary = raw
		var name := str(asset["name"])
		var rate := int(asset["sample_rate"])
		assert_true(float(asset["peak"]) > 0.05, "%s is not silent" % name)
		assert_true(rate == 44100 or rate == 22050, "%s uses a sanctioned rate" % name)
		# A bed filed at the reduced rate has to have earned it: content crowding
		# its own Nyquist would mean the bytes were saved by dulling the sound.
		if rate < 44100:
			assert_true(float(asset["top_band_energy"]) < 0.01,
					"%s fits inside %d Hz (%.3f%% against Nyquist)"
					% [name, rate, 100.0 * float(asset["top_band_energy"])])
		if bool(asset["loop"]):
			assert_true(float(asset["seconds"]) < 8.0, "%s loop stays short" % name)
			assert_true(float(asset["seconds"]) >= 5.0,
					"%s loop is long enough not to read as a pattern" % name)
			# The seam is measured against the buffer's OWN median sample step,
			# so this catches a broken loop rather than a loud one.
			assert_true(float(asset["seam_ratio"]) < 8.0,
					"%s loop point is continuous (ratio %.2f)"
					% [name, float(asset["seam_ratio"])])
			assert_true(float(asset["seam_ratio_d2"]) < 8.0,
					"%s loop point has no slope break (ratio %.2f)"
					% [name, float(asset["seam_ratio_d2"])])
		else:
			assert_true(float(asset["seconds"]) <= 3.2, "%s one-shot stays short" % name)
			assert_true(float(asset["tail"]) < 0.005,
					"%s ends on silence, so a stolen voice never clicks" % name)


func test_03_every_asset_imports_and_the_beds_carry_their_loop() -> void:
	var cfg := _cfg()
	for raw: Variant in cfg.assets():
		var asset: Dictionary = raw
		var path := cfg.stream_path(str(asset["name"]))
		assert_true(ResourceLoader.exists(path), "%s is imported" % path)
		var stream := ResourceLoader.load(path) as AudioStream
		assert_ne(stream, null, "%s loads as an AudioStream" % path)
		if stream == null:
			continue
		assert_almost_eq(stream.get_length(), float(asset["seconds"]), 0.02,
				"%s imported at its authored length" % path)
		if bool(asset["loop"]):
			# tools/gen_audio.py writes a `smpl` chunk; Godot's importer defaults
			# to "Detect From WAV", so the asset carries its own loop and no
			# `.import` edit can silently turn the rain into a one-shot.
			var wav := stream as AudioStreamWAV
			assert_ne(wav, null, "%s imported as an AudioStreamWAV" % path)
			if wav != null:
				assert_eq(wav.loop_mode, AudioStreamWAV.LOOP_FORWARD,
						"%s loops (smpl chunk detected)" % path)


# ===========================================================================
# Event → cue
# ===========================================================================

func test_04_every_wired_sim_event_reaches_its_cue() -> void:
	var expected := {
		"building_placed_sim": "purchase",
		"building_construction_stage": "construct_stage",
		"building_completed": "construct_complete",
		"city_level_changed": "level_fanfare",
	}
	for type_name: String in expected:
		var model := _model()
		var cues := _fire(model, {"type": StringName(type_name), "building": 7,
				"sim_id": "b_7", "stage": 3, "level": 2, "from": 1, "to": 2})
		assert_eq(_cue_ids(cues), PackedStringArray([expected[type_name]]),
				"%s makes its sound" % type_name)

	var dark := _model()
	assert_eq(_cue_ids(_fire(dark, {"type": &"BlockDarkChanged", "block_id": "B2",
			"block_dark": true, "dark_fraction": 1.0})),
			PackedStringArray(["blackout_whomp"]), "the lights going out whomps")
	var lit := _model()
	assert_eq(_cue_ids(_fire(lit, {"type": &"BlockDarkChanged", "block_id": "B2",
			"block_dark": false, "dark_fraction": 0.0})),
			PackedStringArray(["relight_hum"]), "the lights coming back swell")

	var routine := _model()
	assert_eq(_cue_ids(_fire(routine, {"type": &"incident_created", "incident_id": 4,
			"type_id": "structure_fire", "tile": [40, 40], "severity": 0.3,
			"notification_priority": 3})),
			PackedStringArray(["alert_low"]), "a routine incident is a soft sting")
	var critical := _model()
	assert_eq(_cue_ids(_fire(critical, {"type": &"incident_created", "incident_id": 5,
			"tile": [40, 40], "severity": 0.9, "notification_priority": 1})),
			PackedStringArray(["alert_high"]), "a P1 incident is the urgent sting")


func test_05_events_with_no_sound_stay_silent() -> void:
	var model := _model()
	assert_true(model.feed({"type": &"job_started", "building": 4}).is_empty(),
			"internal bookkeeping makes no noise")
	assert_true(model.feed({}).is_empty(), "a typeless event is not a cue")
	assert_true(model.feed({"type": &"economy_hour_settled", "net": 12.0}).is_empty())
	assert_eq(model.pending_count(), 0)


func test_06_ui_intents_are_events_like_any_other() -> void:
	for kind: String in ["ui_tap", "ui_confirm", "ui_deny"]:
		var model := _model()
		assert_eq(_cue_ids(_fire(model, {"type": StringName(kind)})),
				PackedStringArray([kind]), "%s reaches its blip" % kind)
	# The UI bus, not SFX: a blip must not duck or fight the city bed.
	var cfg := _cfg()
	for kind: String in ["ui_tap", "ui_confirm", "ui_deny"]:
		assert_eq(str(cfg.cue(kind).get("bus", "")), "UI")


# ===========================================================================
# Dedup and cooldown
# ===========================================================================

func test_07_a_blackout_of_twelve_blocks_is_one_thunk() -> void:
	var model := _model()
	var scheduled: Array[Dictionary] = []
	for i in 12:
		var out := model.feed({"type": &"BlockDarkChanged", "block_id": "B%d" % i,
				"block_dark": true, "dark_fraction": 1.0})
		if not out.is_empty():
			scheduled.append(out)
	assert_eq(model.pending_count(), 1, "twelve dark blocks scheduled ONE whomp")
	var cues := _tick(model)
	assert_eq(cues.size(), 1, "and exactly one voice is asked for")
	assert_eq(int(cues[0]["count"]), 12, "the fold counted all twelve")
	assert_eq(str(cues[0]["cue"]), "blackout_whomp")


func test_08_dedup_folds_but_cooldown_gates() -> void:
	# Two strikes 0.1 s apart fold into the one still in flight (dedup_s 0.30);
	# a third past the fold window is refused by the 0.35 s cooldown, which is
	# measured from the first REQUEST and not from when the thunder landed.
	var model := _model()
	model.feed({"type": &"lightning_strike", "world_pos": Vector3(500, 0, 0),
			"magnitude": 0.8, "ground": false})
	_tick(model, 0.10)
	model.feed({"type": &"lightning_strike", "world_pos": Vector3(500, 0, 0),
			"magnitude": 0.8, "ground": false})
	assert_eq(model.pending_count(), 1, "two strikes, one thunder still in flight")
	_tick(model, 0.22)   # t = 0.32 s: past the 0.30 s fold, inside the 0.35 s gate
	model.feed({"type": &"lightning_strike", "world_pos": Vector3(500, 0, 0),
			"magnitude": 0.8, "ground": false})
	assert_eq(model.pending_count(), 1,
			"past the fold but inside the cooldown: still no second thunder")
	var landed := _tick(model, 1.5)
	assert_eq(landed.size(), 1, "and exactly one arrives, 500/340 s after the flash")
	assert_eq(int(landed[0]["count"]), 2, "carrying the fold's count")

	var slow := _model()
	slow.feed({"type": &"city_level_changed", "from": 1, "to": 2})
	_tick(slow)
	slow.feed({"type": &"city_level_changed", "from": 2, "to": 3})
	assert_eq(_tick(slow).size(), 0, "a second level-up inside 20 s is not a second fanfare")
	# Past the cooldown it plays again — this is a gate, not a mute.
	_tick(slow, 21.0)
	slow.feed({"type": &"city_level_changed", "from": 3, "to": 4})
	assert_eq(_tick(slow).size(), 1, "past the cooldown the fanfare returns")


func test_09_dedup_by_key_keeps_entities_apart() -> void:
	# Sirens dedup per unit: two units answering the same incident are two
	# sirens, but one unit re-dispatched inside the window is still one.
	var model := _model()
	model.feed({"type": &"incident_created", "incident_id": 9, "tile": [10, 10],
			"severity": 0.5, "notification_priority": 2})
	_tick(model, 1.0)
	model.feed({"type": &"unit_dispatched", "unit_id": 1, "unit_type": "engine",
			"incident_id": 9, "role": "primary", "eta_h": 0.1, "manual": false})
	model.feed({"type": &"unit_dispatched", "unit_id": 2, "unit_type": "engine",
			"incident_id": 9, "role": "support", "eta_h": 0.1, "manual": false})
	model.feed({"type": &"unit_dispatched", "unit_id": 1, "unit_type": "engine",
			"incident_id": 9, "role": "primary", "eta_h": 0.1, "manual": false})
	var cues := _tick(model)
	assert_eq(cues.size(), 2, "two units, two sirens; the repeat folded")
	assert_eq(int(cues[0]["count"]), 2, "unit 1's repeat folded into unit 1's siren")


func test_10_the_renderer_hook_and_the_sim_event_are_one_thunk() -> void:
	# doc 11 §2.15 offers `render_blackout_started` for the same beat
	# BlockDarkChanged already carries. A shell that feeds both event sources
	# must still get one sound — they share a cue identity, so they fold.
	var model := _model()
	model.feed({"type": &"BlockDarkChanged", "block_id": "B3", "block_dark": true})
	model.feed({"type": &"render_blackout_started", "block_id": "B3"})
	assert_eq(model.pending_count(), 1, "one whomp from two descriptions of it")
	assert_eq(_tick(model).size(), 1)


# ===========================================================================
# Distance, delay, position
# ===========================================================================

func test_11_thunder_trails_its_flash_by_distance_over_340() -> void:
	var model := _model()
	for metres: float in [0.0, 340.0, 1700.0]:
		var fresh := _model()
		var cue := fresh.feed({"type": &"lightning_strike",
				"world_pos": Vector3(metres, 0.0, 0.0), "magnitude": 0.7,
				"ground": false, "tile": [int(metres / 8.0), 0]})
		assert_false(cue.is_empty(), "a strike %.0f m away is audible" % metres)
		assert_almost_eq(float(cue["distance_m"]), metres, 0.01)
		assert_almost_eq(float(cue["delay_s"]), metres / SPEED_OF_SOUND, 0.0005,
				"thunder is delayed by distance / 340 m·s")
		assert_almost_eq(float(cue["due_at"]), metres / SPEED_OF_SOUND, 0.0005)

	# And the delay is real: the cue is withheld until its arrival time.
	var far := _model()
	far.feed({"type": &"lightning_strike", "world_pos": Vector3(1700, 0, 0),
			"magnitude": 0.7, "ground": false})
	assert_eq(_tick(far, 1.0).size(), 0, "at +1 s the thunder has not arrived")
	assert_eq(_tick(far, 3.5).size(), 0, "at +4.5 s it still has not")
	assert_eq(_tick(far, 0.6).size(), 1, "at +5.1 s it lands")


func test_12_near_lightning_cracks_and_far_lightning_rumbles() -> void:
	var near := _model()
	var crack := near.feed({"type": &"lightning_strike", "world_pos": Vector3(100, 0, 0),
			"magnitude": 0.9, "ground": false})
	assert_eq(str(crack["cue"]), "thunder_crack", "260 m or closer is a crack")
	var far := _model()
	var rumble := far.feed({"type": &"lightning_strike", "world_pos": Vector3(900, 0, 0),
			"magnitude": 0.9, "ground": false})
	assert_eq(str(rumble["cue"]), "thunder_rumble", "further away it smears into a rumble")
	assert_true(float(rumble["gain_db"]) < float(crack["gain_db"]),
			"and it is quieter for being further")


func test_13_distance_attenuates_monotonically_and_drops_past_max() -> void:
	var last := 1000.0
	for metres: float in [0.0, 300.0, 900.0, 2000.0, 5000.0]:
		var model := _model()
		var cue := model.feed({"type": &"lightning_strike",
				"world_pos": Vector3(metres, 0.0, 0.0), "magnitude": 0.5, "ground": false})
		assert_false(cue.is_empty(), "%.0f m is still inside the rumble's reach" % metres)
		assert_true(float(cue["gain_db"]) <= last + 0.001,
				"gain never rises with distance (%.0f m)" % metres)
		last = float(cue["gain_db"])
	var beyond := _model()
	assert_true(beyond.feed({"type": &"lightning_strike",
			"world_pos": Vector3(9000, 0, 0), "magnitude": 0.5, "ground": false}).is_empty(),
			"past max_m the strike costs no voice at all")
	assert_eq(beyond.pending_count(), 0)


func test_14_magnitude_scales_the_strike() -> void:
	var weak := _model().feed({"type": &"lightning_strike", "world_pos": Vector3(80, 0, 0),
			"magnitude": 0.0, "ground": false})
	var strong := _model().feed({"type": &"lightning_strike", "world_pos": Vector3(80, 0, 0),
			"magnitude": 1.0, "ground": false})
	assert_almost_eq(float(strong["gain_db"]) - float(weak["gain_db"]), 6.0, 0.001,
			"gain_range_db spans the magnitude, so a weak strike is a weak sound")


func test_15_an_id_only_event_is_placed_by_the_shells_locator() -> void:
	# The sim's events carry ids, not metres; only the shell knows where a block
	# sits. Same Callable contract as AlertsModel.set_locator.
	var model := _model()
	var asked: Array = []
	model.set_locator(func(kind: StringName, id: Variant) -> Variant:
		asked.append([String(kind), str(id)])
		return Vector3(400.0, 0.0, 0.0) if String(kind) == "block_id" else null)
	var cue := model.feed({"type": &"BlockDarkChanged", "block_id": "B7", "block_dark": true})
	assert_almost_eq(float(cue["distance_m"]), 400.0, 0.01, "the locator placed it")
	assert_eq(asked.size(), 1)
	assert_eq(str(asked[0][0]), "block_id")

	# No locator at all: the cue plays AT the listener rather than not at all.
	var blind := _model()
	var flat := blind.feed({"type": &"BlockDarkChanged", "block_id": "B7", "block_dark": true})
	assert_false(flat.is_empty(), "a missing locator makes the mix flat, never silent")
	assert_almost_eq(float(flat["distance_m"]), 0.0, 0.001)
	assert_false(bool(flat["placed"]))


func test_16_a_siren_borrows_the_position_of_the_incident_it_answers() -> void:
	# `unit_dispatched` carries no place — only the incident it is answering.
	var model := _model()
	model.feed({"type": &"incident_created", "incident_id": 12, "tile": [50, 0],
			"severity": 0.6, "notification_priority": 2})
	_tick(model)
	var siren := model.feed({"type": &"unit_dispatched", "unit_id": 3,
			"unit_type": "engine", "incident_id": 12, "role": "primary",
			"eta_h": 0.05, "manual": false})
	assert_eq(str(siren["cue"]), "siren_pass")
	# tile [50, 0] -> centre of an 8 m tile (constitution §6), so (404, 0, 4) m.
	assert_almost_eq(float(siren["distance_m"]), Vector3(404.0, 0.0, 4.0).length(), 0.01,
			"the siren is where the incident is")
	assert_true(bool(siren["placed"]))


func test_17_a_tile_payload_places_itself_without_a_locator() -> void:
	var model := _model()
	var cue := model.feed({"type": &"incident_created", "incident_id": 1,
			"tile": [10, 20], "severity": 0.2, "notification_priority": 3})
	var expected := Vector3(10 * 8.0 + 4.0, 0.0, 20 * 8.0 + 4.0)
	assert_almost_eq(float(cue["distance_m"]), expected.length(), 0.01)


# ===========================================================================
# Ambience beds
# ===========================================================================

func test_18_the_city_bed_crossfades_into_night() -> void:
	var model := _model()
	_tick(model, FRAME, Vector3.ZERO, 0.0)
	assert_almost_eq(model.bed_gain("city_day"), 1.0, 0.001)
	assert_almost_eq(model.bed_gain("city_night"), 0.0, 0.001)
	_tick(model, FRAME, Vector3.ZERO, 1.0)
	assert_almost_eq(model.bed_gain("city_day"), 0.0, 0.001)
	assert_almost_eq(model.bed_gain("city_night"), 1.0, 0.001)
	_tick(model, FRAME, Vector3.ZERO, 0.5)
	assert_almost_eq(model.bed_gain("city_day"), 0.5, 0.001, "the two always sum to one")
	assert_almost_eq(model.bed_gain("city_night"), 0.5, 0.001)


func test_19_the_rain_bed_is_gated_by_precip01() -> void:
	var model := _model()
	# The real doc 07 payload, verbatim.
	model.feed({"type": &"weather_changed", "weather_state": &"CLEAR",
			"intensity": 0.0, "precip01": 0.0, "wind": Vector2.ZERO, "wind_kph": 4.0,
			"fog": 0.0, "temp_c": 18.0, "segment_id": 1})
	_tick(model)
	assert_almost_eq(model.bed_gain("rain"), 0.0, 0.001, "dry weather has no rain bed")

	var last := -1.0
	for precip: float in [0.02, 0.2, 0.6, 1.0]:
		model.feed({"type": &"weather_changed", "precip01": precip, "wind_kph": 10.0})
		_tick(model)
		var gain := model.bed_gain("rain")
		assert_true(gain >= last, "the rain bed rises with precip01 (%.2f)" % precip)
		last = gain
	assert_almost_eq(model.bed_gain("rain"), 1.0, 0.001, "a downpour is the full bed")
	assert_almost_eq(model.precip01(), 1.0, 0.001)


func test_20_the_wind_bed_follows_wind_kph_and_rises_in_pitch() -> void:
	var model := _model()
	model.feed({"type": &"weather_changed", "precip01": 0.0, "wind_kph": 10.0})
	_tick(model)
	assert_almost_eq(model.bed_gain("wind"), 0.0, 0.001, "a breeze is not a wind bed")
	assert_almost_eq(model.bed_pitch("wind"), 1.0, 0.001)

	model.feed({"type": &"weather_changed", "precip01": 0.0, "wind_kph": 100.0})
	_tick(model)
	assert_almost_eq(model.bed_gain("wind"), 1.0, 0.001, "a gale is the full bed")
	assert_true(model.bed_pitch("wind") > 1.05, "and it rises in pitch as it rises")

	model.feed({"type": &"weather_changed", "precip01": 0.0, "wind_kph": 47.0})
	_tick(model)
	var mid := model.bed_gain("wind")
	assert_true(mid > 0.05 and mid < 0.95, "and reads a real value in between: %.3f" % mid)


func test_21_the_site_bed_follows_live_sites_and_the_nearest_one() -> void:
	var model := _model()
	model.set_locator(func(_kind: StringName, id: Variant) -> Variant:
		return Vector3(50.0 * float(str(id).to_int()), 0.0, 0.0))
	_tick(model)
	assert_almost_eq(model.bed_gain("site"), 0.0, 0.001, "no sites, no crane loop")

	model.feed({"type": &"building_construction_stage", "building": 1,
			"sim_id": "b_1", "stage": 2})
	_tick(model)
	assert_eq(model.active_site_count(), 1)
	var one := model.bed_gain("site")
	assert_true(one > 0.0, "one site 50 m away is audible")

	model.feed({"type": &"building_construction_stage", "building": 2,
			"sim_id": "b_2", "stage": 2})
	model.feed({"type": &"building_construction_stage", "building": 3,
			"sim_id": "b_3", "stage": 2})
	_tick(model)
	assert_eq(model.active_site_count(), 3)
	assert_true(model.bed_gain("site") > one, "three sites are a busier site bed")

	# Completion takes the scaffolding — and the loop — down.
	model.feed({"type": &"building_completed", "building": 1, "level": 1})
	model.feed({"type": &"building_completed", "building": 2, "level": 1})
	model.feed({"type": &"building_completed", "building": 3, "level": 1})
	_tick(model)
	assert_eq(model.active_site_count(), 0)
	assert_almost_eq(model.bed_gain("site"), 0.0, 0.001)


func test_22_a_far_site_is_quieter_than_a_near_one() -> void:
	var near := _model()
	near.set_locator(func(_k: StringName, _i: Variant) -> Variant: return Vector3(40, 0, 0))
	near.feed({"type": &"building_construction_stage", "building": 1, "stage": 2})
	_tick(near)
	var far := _model()
	far.set_locator(func(_k: StringName, _i: Variant) -> Variant: return Vector3(380, 0, 0))
	far.feed({"type": &"building_construction_stage", "building": 1, "stage": 2})
	_tick(far)
	assert_true(far.bed_gain("site") < near.bed_gain("site"),
			"two cranes across the map are quieter than one outside the window")
	assert_true(far.bed_gain("site") >= 0.0)


# ===========================================================================
# Ducking, determinism, lifecycle
# ===========================================================================

func test_23_a_whomp_ducks_the_beds_and_they_come_back() -> void:
	var model := _model()
	assert_almost_eq(model.duck01(), 0.0, 0.001)
	model.feed({"type": &"BlockDarkChanged", "block_id": "B1", "block_dark": true})
	for i in 10:
		_tick(model, 0.05)
	assert_true(model.duck01() > 0.3, "the city gets out of the whomp's way")
	for i in 40:
		_tick(model, 0.1)
	assert_true(model.duck01() < 0.05, "and comes back rather than staying down")


func test_24_pitch_jitter_is_seeded_and_repeatable() -> void:
	var first: Array[float] = []
	var second: Array[float] = []
	for run in 2:
		var model := _model()
		var into: Array[float] = first if run == 0 else second
		for i in 4:
			model.feed({"type": &"ui_tap"})
			for cue: Dictionary in _tick(model, 0.5):
				into.append(float(cue["pitch"]))
	assert_eq(first.size(), 4, "four taps, four blips")
	assert_eq(first, second, "the audio RNG stream is seeded, so runs match")
	var varied := false
	for pitch: float in first:
		if absf(pitch - 1.0) > 0.001:
			varied = true
		assert_true(absf(pitch - 1.0) <= 0.05, "jitter stays inside the cue's ± range")
	assert_true(varied, "a repeated blip does not phase against itself")


func test_25_reset_drops_sound_scheduled_by_the_city_that_was_replaced() -> void:
	var model := _model()
	model.feed({"type": &"lightning_strike", "world_pos": Vector3(1700, 0, 0),
			"magnitude": 0.9, "ground": false})
	model.feed({"type": &"building_construction_stage", "building": 1, "stage": 2})
	_tick(model)
	assert_eq(model.pending_count(), 1, "thunder is still in flight")
	assert_eq(model.active_site_count(), 1)
	model.reset()
	assert_eq(model.pending_count(), 0, "a load does not carry the old city's thunder in")
	assert_eq(model.active_site_count(), 0)
	assert_eq(_tick(model, 10.0).size(), 0)


# ===========================================================================
# The service (buses, pool, beds) — everything that needs a scene
# ===========================================================================

func _mount_service() -> AudioService:
	var service := AudioService.new()
	service.name = "AudioServiceTest"
	_tree().root.add_child(service)
	service.setup()
	return service


func _unmount(service: AudioService) -> void:
	_tree().root.remove_child(service)
	service.queue_free()


func test_26_the_service_brings_up_buses_pool_and_beds() -> void:
	var service := _mount_service()
	for bus: String in ["SFX", "Ambient", "UI"]:
		assert_true(AudioServer.get_bus_index(bus) >= 0, "%s bus exists" % bus)
		assert_ne(AudioServer.get_bus_send(AudioServer.get_bus_index(bus)), StringName(""))
	assert_eq(service.missing_streams.size(), 0,
			"every cue and bed resolved to an imported asset: %s"
			% str(service.missing_streams))
	assert_true(service.voice_count() >= 8, "the pool is allocated up front")
	assert_eq(service.busy_voice_count(), 0, "and starts idle")
	assert_ne(service.events, null)
	for bed_id: String in service.events.bed_ids():
		assert_false(service.bed_playing(bed_id), "a bed starts silent and stopped")
		assert_almost_eq(service.bed_level(bed_id), 0.0, 0.0001)
	_unmount(service)


func test_27_the_service_plays_what_the_model_scheduled() -> void:
	var service := _mount_service()
	service.feed_batch([
		{"type": &"BlockDarkChanged", "block_id": "B1", "block_dark": true},
		{"type": &"BlockDarkChanged", "block_id": "B2", "block_dark": true},
	])
	assert_eq(service.events.pending_count(), 1, "one whomp for both blocks")
	service.update_audio(FRAME, Vector3.ZERO, 0.0)
	assert_eq(service.events.pending_count(), 0, "and it was handed to a voice")
	assert_eq(service.busy_voice_count(), 1, "which is now carrying it")
	assert_eq(service.voice_cue(0), "blackout_whomp")

	service.ui_cue(AudioService.UI_CONFIRM)
	service.update_audio(FRAME, Vector3.ZERO, 0.0)
	assert_eq(service.busy_voice_count(), 2, "a blip does not evict the whomp")

	# The whomp is 1.4 s long; once it has run its length the voice is free
	# again, without anyone having to poll the audio driver.
	for i in 100:
		service.update_audio(0.05, Vector3.ZERO, 0.0)
	assert_eq(service.busy_voice_count(), 0, "voices free themselves when the cue ends")
	_unmount(service)


func test_30_the_pool_caps_one_cue_and_steals_from_the_weakest() -> void:
	var service := _mount_service()
	var cap := AudioConfig.get_int(_cfg().pool(), "max_per_cue", 3)
	for i in cap + 4:
		service.play_cue({"cue": "thunder_rumble", "stream": "thunder_rumble",
				"bus": "SFX", "gain_db": -6.0, "pitch": 1.0, "priority": 4})
	assert_eq(service.busy_voice_count(), cap,
			"a storm cannot spend the whole pool on thunder")

	_unmount(service)

	# Fill every voice with something unimportant, then ask for the most
	# important cue there is: the pool must find room by taking the weakest.
	var weak := _mount_service()
	for i in weak.voice_count():
		weak.play_cue({"cue": "filler_%d" % i, "stream": "construct_stage",
				"bus": "SFX", "gain_db": -12.0, "pitch": 1.0, "priority": 1})
	assert_eq(weak.busy_voice_count(), weak.voice_count(), "the pool is full")
	assert_true(weak.play_cue({"cue": "level_fanfare", "stream": "level_fanfare",
			"bus": "UI", "gain_db": -4.0, "pitch": 1.0, "priority": 6}),
			"a priority-6 fanfare gets in by stealing a priority-1 tick")
	_unmount(weak)

	# And the reverse is refused rather than allowed to trample the ceremony.
	var strong := _mount_service()
	for i in strong.voice_count():
		strong.play_cue({"cue": "held_%d" % i, "stream": "level_fanfare", "bus": "UI",
				"gain_db": -4.0, "pitch": 1.0, "priority": 9})
	assert_false(strong.play_cue({"cue": "construct_stage", "stream": "construct_stage",
			"bus": "SFX", "gain_db": -12.0, "pitch": 1.0, "priority": 1}),
			"a construction tick never evicts something more important")
	_unmount(strong)


# ===========================================================================
# The firehose, and the real sim
# ===========================================================================

func test_31_the_traffic_feed_costs_one_dictionary_probe() -> void:
	# doc 10 emits ~1,400 `vehicle_state` events per game hour and every one of
	# them carries a `pos`. If an unrecognised type reached the position
	# resolver, the mix would pay a locator call per vehicle per tick.
	var model := _model()
	var locator_calls := 0
	model.set_locator(func(_kind: StringName, _id: Variant) -> Variant:
		locator_calls += 1
		return Vector3.ZERO)
	var firehose: Array = []
	for i in 200:
		firehose.append({"type": &"vehicle_state", "id": i, "kind": "car",
				"vehicle_class": "civilian", "pos": Vector2(i, i), "heading": 0.0,
				"speed": 9.0, "siren": false, "lightbar": false, "headlights": false,
				"edge_id": i, "dark": false})
		firehose.append({"type": &"congestion_updated", "edge_id": i, "density": 0.4})
	assert_eq(model.feed_batch(firehose).size(), 0, "the traffic feed is silent")
	assert_eq(locator_calls, 0, "and never asked the shell to place anything")
	assert_eq(model.pending_count(), 0)


func test_32_a_real_city_blacking_out_makes_exactly_one_thunk() -> void:
	# End to end on the real thing: CitySim's own feeder trip, its own
	# BlockDarkChanged payloads, no fixtures anywhere.
	var sim := CitySim.boot_from_files(4242)
	var model := _model()
	sim.grid.force_open("F_SOUTH")
	sim.advance_hours(1.0)

	var batch := sim.bus.drain()
	var dark_events := 0
	for event: Dictionary in batch:
		if str(event.get("type", "")) == "BlockDarkChanged" and bool(event.get("block_dark", false)):
			dark_events += 1
	assert_true(dark_events >= 2,
			"the trip really did darken several blocks (%d)" % dark_events)

	model.feed_batch(batch)
	var cues := _tick(model, 0.5)
	assert_eq(_cue_ids(cues), PackedStringArray(["blackout_whomp"]),
			"%d dark blocks, one thunk" % dark_events)
	assert_eq(int(cues[0]["count"]), dark_events, "the fold saw every one of them")

	# …and the relight is its own single swell when the feeder comes back.
	for i in 60:
		_tick(model, 0.1)
	sim.grid.force_close("F_SOUTH")
	sim.advance_hours(1.0)
	model.feed_batch(sim.bus.drain())
	assert_eq(_cue_ids(_tick(model, 0.5)), PackedStringArray(["relight_hum"]),
			"and the lights coming back are one rising hum")


func test_28_the_sound_volume_row_drives_the_master_bus() -> void:
	var service := _mount_service()
	var settings := SettingsModel.load_from_files()
	assert_true(settings.has_key("sound_volume"),
			"data/ui.json still carries the row data/audio.json names")
	assert_eq(str(_cfg().mix().get("settings_key", "")), "sound_volume",
			"and audio.json points at that exact row")

	service.set_sound_volume(settings.value_num("sound_volume"))
	assert_false(AudioServer.is_bus_mute(0), "the default 0.8 is not silence")
	var loud := AudioServer.get_bus_volume_db(0)
	service.set_sound_volume(0.25)
	assert_true(AudioServer.get_bus_volume_db(0) < loud, "turning it down turns it down")

	service.set_sound_volume(0.0)
	assert_true(AudioServer.is_bus_mute(0),
			"zero MUTES the bus rather than playing it at -60 dB")
	service.set_sound_volume(0.8)
	assert_false(AudioServer.is_bus_mute(0))

	# doc 13 §2: FOCUS_OUT mutes, FOCUS_IN restores.
	service.set_muted(true)
	assert_true(AudioServer.is_bus_mute(0), "backgrounding the app silences it")
	service.set_muted(false)
	assert_false(AudioServer.is_bus_mute(0))
	AudioServer.set_bus_mute(0, false)
	_unmount(service)


func test_29_beds_ramp_rather_than_snap() -> void:
	var service := _mount_service()
	service.feed_batch([{"type": &"weather_changed", "precip01": 1.0, "wind_kph": 0.0}])
	service.update_audio(FRAME, Vector3.ZERO, 0.0)
	var after_one_frame := service.bed_level("rain")
	assert_true(after_one_frame > 0.0 and after_one_frame < 0.5,
			"one frame is a ramp, not a switch: %.3f" % after_one_frame)
	for i in 240:
		service.update_audio(FRAME, Vector3.ZERO, 0.0)
	assert_true(service.bed_level("rain") > 0.95, "four seconds later it is fully up")
	assert_true(service.bed_playing("rain"), "and the loop is running")
	_unmount(service)
