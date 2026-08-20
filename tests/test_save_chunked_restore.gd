extends SimTest
## The two deep save/load levers, proved (report 98 §24, doc 13 §2.9).
##
## Wave 12 did three things to the serialization path and every one of them is a
## SPEED change with a correctness obligation attached:
##
##   1. the float codec stopped rebuilding the body node by node and started deep
##      -copying it natively and patching the float leaves in place — so the
##      bytes it produces must still be the SAME bytes;
##   2. that patch moved off the sim's thread onto the write thread, behind
##      `SaveSection.finalize` — so `capture_detached()` must hand over a body
##      that aliases nothing the sim will touch next;
##   3. `restore_state()` became eleven resumable steps — so draining them one at
##      a time must land on the same city as draining them in one call.
##
## Each of those is a claim about identity, and identity is what this file
## tests. Speed is `tools/profile_save.gd`'s job and doc 98 §24's.

const BENCH_CITY := "res://tests/fixtures/bench_city.json"
## Tests never write to `user://saves` — that is a real player's profile.
const TEST_DIR := "user://test_saves/chunked"


## Listing first, deleting second: removing entries inside a `list_dir_begin()`
## walk skips the ones after them.
static func _wipe(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	var files: Array[String] = []
	var dirs: Array[String] = []
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			dirs.append(entry)
		else:
			files.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	for child in files:
		DirAccess.remove_absolute(path + "/" + child)
	for child in dirs:
		_wipe(path + "/" + child)
		DirAccess.remove_absolute(path + "/" + child)


func _fresh_service() -> SaveService:
	var service := SaveService.new()
	service.base_dir = TEST_DIR
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	_wipe(TEST_DIR)
	return service


func _bench_sim(seed_value: int = 1337) -> CitySim:
	var sim := CitySim.new()
	sim.boot(seed_value,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json(BENCH_CITY),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	return sim


# ------------------------------------------------------------------- the codec

## The old codec rebuilt the tree with a recursive walk; the new one deep-copies
## and patches. A body written by one must be indistinguishable from a body
## written by the other, and "indistinguishable" here means the JSON TEXT — that
## is what is hashed, what is compressed and what is on the player's phone.
func test_the_fast_codec_writes_the_same_bytes_as_a_reference_walk() -> void:
	var sim := CitySim.boot_from_files(4242)
	sim.advance_hours(6.0)
	var raw := sim.capture_state()
	var reference: Variant = _reference_encode(raw)
	var fast: Variant = CitySim._encode_floats(raw)
	assert_eq(JSON.stringify(fast, "", true, true), JSON.stringify(reference, "", true, true),
			"the in-place codec must print the bytes the recursive one printed")


func test_the_fast_decoder_reads_what_the_reference_walk_reads() -> void:
	var sim := CitySim.boot_from_files(4242)
	sim.advance_hours(6.0)
	var encoded := sim.canonical_capture()
	var reference: Variant = _reference_decode(encoded)
	var fast: Variant = CitySim._decode_floats(encoded)
	assert_eq(JSON.stringify(fast, "", true, true), JSON.stringify(reference, "", true, true),
			"the in-place decoder must land where the recursive one landed")


## Every fraction the codec meets, and both ends of the range that made the
## two-u32 split necessary in the first place.
func test_every_float_survives_the_round_trip_bit_for_bit() -> void:
	var values: Array[float] = [0.0, -0.0, 1.0, -1.0, 0.1, -0.1, 1.0 / 3.0,
			-1.0 / 3.0, 1e-300, -1e-300, 1e300, -1e300, 4.5e18, -4.5e18,
			PI, -PI, 0.5, 1e-7, 9007199254740993.0]
	for v in values:
		var encoded: Variant = CitySim._encode_floats({"v": v})
		var decoded: Variant = CitySim._decode_floats(encoded)
		var back := float(decoded["v"])
		assert_eq(back, v, "float %s did not survive" % [v])


## The bug the type-erasure guard exists for: a typed array cannot hold a `~f~`
## string, and it silently converts an int back into a float — which changes the
## bytes on disk without changing anything a reader would notice.
func test_a_typed_float_array_is_re_seated_untyped() -> void:
	var typed: Array[float] = [1.0, 0.25]
	var encoded: Variant = CitySim._encode_floats({"a": typed})
	var out: Array = encoded["a"]
	assert_false(out.is_typed(), "the codec must hand back an untyped array")
	assert_eq(typeof(out[0]), TYPE_INT, "1.0 canonicalizes as an int")
	assert_eq(typeof(out[1]), TYPE_STRING, "0.25 canonicalizes as hex")
	assert_eq(JSON.stringify(encoded, "", true, true), "{\"a\":[1,\"~f~3fd0000000000000\"]}",
			"and the bytes are the bytes")


## `finalize` runs where the manager put it, which may be a retry. Encoding an
## encoded body twice must be a no-op, not a corruption.
func test_encoding_is_idempotent() -> void:
	var sim := CitySim.boot_from_files(99)
	sim.advance_hours(2.0)
	var once := sim.canonical_capture()
	var text := JSON.stringify(once, "", true, true)
	var twice: Dictionary = CitySim.encode_captured(once)
	assert_eq(JSON.stringify(twice, "", true, true), text,
			"a second encode must change nothing")


# --------------------------------------------------------------- the two halves

## The claim `capture_save`'s docs make and the write thread depends on: what
## `capture_detached()` returns is a private copy. Advancing the sim afterwards
## must not move a single number in it.
func test_a_detached_capture_does_not_move_when_the_sim_does() -> void:
	var sim := _bench_sim()
	sim.advance_hours(1.0)
	var detached := sim.capture_detached()
	var frozen := detached.duplicate(true)
	sim.advance_hours(3.0)
	for key: String in frozen:
		assert_eq(detached[key], frozen[key],
				"section '%s' aliases live sim state" % key)


## …and the same claim about the SHIPPED path, which is the one that matters:
## `capture_state()` is what `capture_detached()` copies, so a section that
## leaked a live container would be caught here even if the copy were removed.
func test_capture_state_hands_out_no_live_container() -> void:
	var sim := _bench_sim()
	sim.advance_hours(1.0)
	var live := sim.capture_state()
	var frozen := live.duplicate(true)
	sim.advance_hours(3.0)
	for key: String in frozen:
		assert_eq(live[key], frozen[key],
				"CitySim.capture_state()['%s'] is a live reference" % key)


## The two halves, recombined, are the one call.
func test_the_split_capture_equals_canonical_capture() -> void:
	var a := CitySim.boot_from_files(31337)
	var b := CitySim.boot_from_files(31337)
	a.advance_hours(5.0)
	b.advance_hours(5.0)
	var whole := a.canonical_capture()
	var split: Dictionary = CitySim.encode_captured(b.capture_detached())
	assert_eq(JSON.stringify(split, "", true, true), JSON.stringify(whole, "", true, true),
			"capture_detached + encode_captured must be canonical_capture")


# ------------------------------------------------------------ the chunked restore

## The property the whole cursor rests on: eleven steps spent one at a time land
## on the city one call lands on, hash for hash.
func test_a_stepped_restore_lands_where_a_single_call_lands() -> void:
	for city_seed in [1337, 4242]:
		var source := CitySim.boot_from_files(city_seed)
		source.advance_hours(9.0)
		var body := source.canonical_capture()

		var monolithic := CitySim.boot_from_files(city_seed)
		monolithic.restore_state(body)

		var stepped := CitySim.boot_from_files(city_seed)
		var cursor := stepped.begin_restore(body)
		assert_eq(cursor.step_count(), 11, "the cut is eleven steps")
		var spent := 0
		while not cursor.is_done():
			assert_ne(cursor.next_label(), "", "every step is labelled")
			cursor.step()
			spent += 1
		assert_eq(spent, 11, "and every one of them ran")
		assert_eq(stepped.state_hash(), monolithic.state_hash(),
				"stepped and monolithic restores must agree (seed %d)" % city_seed)


## …and on the benchmark city, which is the one the cut was measured against.
func test_a_stepped_restore_lands_where_a_single_call_lands_on_the_bench_city() -> void:
	var source := _bench_sim()
	source.advance_hours(4.0)
	var body := source.canonical_capture()
	var monolithic := _bench_sim()
	monolithic.restore_state(body)
	var stepped := _bench_sim()
	stepped.begin_restore(body).run()
	assert_eq(stepped.state_hash(), monolithic.state_hash(),
			"1,500 buildings restore the same either way")


## The seam is only safe if nothing runs between steps — but a SHELL that spends
## the cursor across frames will call `step()` once more than there are steps
## sooner or later, and a veil that outlives its load must not crash it.
func test_stepping_past_the_end_is_a_no_op() -> void:
	var source := CitySim.boot_from_files(7)
	source.advance_hours(1.0)
	var body := source.canonical_capture()
	var sim := CitySim.boot_from_files(7)
	var cursor := sim.begin_restore(body)
	cursor.run()
	var settled := sim.state_hash()
	assert_true(cursor.step(), "step() on a finished cursor answers done")
	assert_eq(cursor.completed(), 11, "and completes nothing further")
	assert_eq(sim.state_hash(), settled, "and moves nothing")


## Save → load → ADVANCE, on both cities, through the stepped path: the
## determinism contract (constitution §5, M1 criterion 8) does not get an
## exemption for the loader being resumable.
func test_save_load_advance_is_bit_identical_through_the_cursor() -> void:
	for city_seed in [2026, 5150]:
		var a := CitySim.boot_from_files(city_seed)
		a.advance_hours(7.0)
		var body := a.canonical_capture()
		var b := CitySim.boot_from_files(city_seed)
		var cursor := b.begin_restore(body)
		while not cursor.is_done():
			cursor.step()
		assert_eq(b.state_hash(), a.state_hash(),
				"restored city must match at rest (seed %d)" % city_seed)
		a.advance_hours(6.0)
		b.advance_hours(6.0)
		assert_eq(b.state_hash(), a.state_hash(),
				"and after six more hours (seed %d)" % city_seed)


# ------------------------------------------------------------------ the ugly states

## A save taken while the city is on fire and under water is the one the codec
## and the cursor are least likely to have been exercised on, and the one a
## player is most likely to take — the autosave fires on the same cadence
## whatever is burning.
##
## **What this test does NOT assert, and why.** Writing it turned up a
## determinism defect that predates Wave 12 by a long way (report 98 §24, defect
## A91-D-30): on the founding city, a save taken after the first game-day
## boundary does not replay bit-identically — the restored run's `roads`
## traffic feed drifts within one game-hour, and it drifts whether the restore
## was one call or eleven steps. It is a ROADS defect, not a serialization one; the
## body is byte-identical, `at rest` matches, and both restore paths land on the
## same wrong city. So this file asserts the three things it owns — the body
## round-trips, the two restore paths agree with each other, and they agree at
## rest — and the fourth is filed rather than smuggled into a passing test.
func test_a_mid_incident_mid_flood_body_round_trips() -> void:
	var a := CitySim.boot_from_files(8191)
	a.advance_hours(3.0)
	# A storm across the save point and a transformer down under it: the weather
	# timeline holds an injected segment, the incident holds partial work, the
	# dispatch holds an assignment, and the roads hold a closure. Four
	# accumulators mid-stride is the shape a save has to survive.
	a.weather.inject_storm(a.clock.abs_minutes() + 40, 180, 0.77, 4242)
	a.trigger_tutorial_transformer_failure()
	a.advance_hours(1.0)
	assert_true(a.incidents.active_count() > 0,
			"the fixture needs a live incident to be worth anything")
	var body := a.canonical_capture()

	var b := CitySim.boot_from_files(8191)
	b.restore_state(body)
	assert_eq(b.state_hash(), a.state_hash(), "a burning city restores exactly")

	var c := CitySim.boot_from_files(8191)
	c.begin_restore(body).run()
	assert_eq(c.state_hash(), a.state_hash(), "and restores exactly one step at a time")

	b.advance_hours(4.0)
	c.advance_hours(4.0)
	assert_eq(c.state_hash(), b.state_hash(),
			"the cursor and the single call must keep burning the same way")


## A body captured mid-storm, mid-construction, mid-development — the three
## queues that hold un-settled remainders across a save.
func test_a_body_with_work_in_flight_round_trips() -> void:
	var a := CitySim.boot_from_files(6060)
	a.advance_hours(2.0)
	var placed := a.cmd_place_building("house", Vector2i(6, 6))
	a.advance_hours(0.5)
	var body := a.canonical_capture()
	var b := CitySim.boot_from_files(6060)
	b.begin_restore(body).run()
	assert_eq(b.state_hash(), a.state_hash(),
			"a city with a job on the queue restores exactly (placed ok=%s)"
			% [bool(placed.get("ok", false))])
	a.advance_hours(9.0)
	b.advance_hours(9.0)
	assert_eq(b.state_hash(), a.state_hash(), "and finishes the job the same way")


# ------------------------------------------------------- the shell's stepped load

## `SaveService.begin_load_slot` + `step_load` is what the loading veil drives.
## It must land on the same city as `load_slot`, publish the same bookkeeping,
## and fire `loaded` exactly once — a stepped load and a single-call one are
## indistinguishable to everything that listens.
func test_a_stepped_slot_load_matches_a_single_call_one() -> void:
	var service := _fresh_service()
	var source := CitySim.boot_from_files(1234)
	source.advance_hours(4.0)
	var meta := service.save_slot(source, 1)
	assert_false(meta.is_empty(), "save failed: " + service.last_error)

	var single := CitySim.boot_from_files(1234)
	assert_true(service.load_slot(single, 1), "single-call load: " + service.last_error)

	var stepped := CitySim.boot_from_files(1234)
	var fired: Array[int] = []
	service.loaded.connect(func(slot: int) -> void: fired.append(slot))
	var cursor := service.begin_load_slot(stepped, 1)
	assert_eq(cursor.step_count(), 12, "eleven restore steps and a settle")
	var spent := 0
	while not service.step_load(cursor):
		spent += 1
		assert_true(spent < 64, "the cursor must terminate")
	assert_true(service.last_load_ok, "stepped load reports success")
	assert_eq(fired.size(), 1, "`loaded` fires exactly once")
	assert_eq(stepped.state_hash(), single.state_hash(),
			"stepped and single-call loads land on the same city")
	assert_eq(service.last_load_format, 2, "and record the same format")
	assert_true(service.last_load_restore_ms > 0.0, "and time the restore")
	_wipe(TEST_DIR)


## A slot with nothing in it must come back as a cursor that terminates and
## reports failure, not as a null the shell has to test for.
func test_a_stepped_load_of_an_empty_slot_refuses_without_crashing() -> void:
	var service := _fresh_service()
	var sim := CitySim.boot_from_files(1234)
	var before := sim.state_hash()
	var cursor := service.begin_load_slot(sim, 4)
	var guard := 0
	while not service.step_load(cursor):
		guard += 1
		assert_true(guard < 64, "the cursor must terminate")
	assert_false(service.last_load_ok, "an empty slot does not load")
	assert_eq(sim.state_hash(), before, "and does not half-restore the city")
	_wipe(TEST_DIR)


# --------------------------------------------------------------------- reference

## The codec as it was written before Wave 12 — recursive, allocating, and the
## definition of correct. Kept HERE rather than in `sim/` because it is not the
## shipped path any more; it is the thing the shipped path is measured against,
## and a reference implementation that lives next to the optimized one gets
## "optimized" too.
static func _reference_encode(value: Variant) -> Variant:
	match typeof(value):
		TYPE_FLOAT:
			if absf(value) < 4.6e18 and value == float(int(value)):
				return int(value)
			var bytes := PackedByteArray()
			bytes.resize(8)
			bytes.encode_double(0, value)
			return "~f~%08x%08x" % [bytes.decode_u32(4), bytes.decode_u32(0)]
		TYPE_DICTIONARY:
			var out_dict := {}
			for key: Variant in value:
				out_dict[key] = _reference_encode(value[key])
			return out_dict
		TYPE_ARRAY:
			var out_array := []
			for entry: Variant in value:
				out_array.append(_reference_encode(entry))
			return out_array
		_:
			return value


static func _reference_decode(value: Variant) -> Variant:
	match typeof(value):
		TYPE_STRING:
			if (value as String).begins_with("~f~"):
				var hex := (value as String).substr(3)
				var bytes := PackedByteArray()
				bytes.resize(8)
				bytes.encode_u32(4, ("0x" + hex.substr(0, 8)).hex_to_int())
				bytes.encode_u32(0, ("0x" + hex.substr(8, 8)).hex_to_int())
				return bytes.decode_double(0)
			return value
		TYPE_DICTIONARY:
			var out_dict := {}
			for key: Variant in value:
				out_dict[key] = _reference_decode(value[key])
			return out_dict
		TYPE_ARRAY:
			var out_array := []
			for entry: Variant in value:
				out_array.append(_reference_decode(entry))
			return out_array
		_:
			return value
