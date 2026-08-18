extends SimTest
## Doc 01 T-07 (sampling), T-08 (validation), T-09 (fine/coarse equivalence),
## T-17 (modifier clamp & order determinism).


static func load_time_data() -> Dictionary:
	var text := FileAccess.get_file_as_string("res://data/time.json")
	return JSON.parse_string(text)


func _loaded_curves() -> DayCurveSet:
	var curves := DayCurveSet.new()
	var loaded := curves.load_from(load_time_data())
	assert_true(loaded, "data/time.json must validate: " + ", ".join(curves.errors))
	return curves


func test_sampling_worked_examples() -> void:
	var curves := _loaded_curves()
	# 07:30 traffic: between (7, 1.71) and (8, 2.08) -> 1.895
	assert_almost_eq(curves.sample("traffic_density", 7.5), 1.895, 1e-9)
	# Wrap-around 23:30 traffic: between (23, 0.37) and (24 -> 0, 0.19) -> 0.28
	assert_almost_eq(curves.sample("traffic_density", 23.5), 0.28, 1e-9)
	# Before first keyframe with wrap: crime at 23.5 between (23,1.66)+(24,1.66)
	assert_almost_eq(curves.sample("crime_rate", 23.5), 1.66, 1e-9)
	# Flat single-key curve
	assert_almost_eq(curves.sample("response_speed", 13.7), 1.0, 1e-9)
	# Construction 20:30: between (19, 0.75) and (21, 0.60) -> 0.6375
	assert_almost_eq(curves.sample("construction_rate", 20.5), 0.6375, 1e-9)


func test_normalized_means_within_tolerance() -> void:
	var curves := _loaded_curves()
	var data := load_time_data()
	for curve_name in data["curves"]:
		if String(data["curves"][curve_name]["kind"]) == "normalized":
			var mean := curves.curve_mean_24h(String(curve_name))
			assert_true(absf(mean - 1.0) <= 0.02,
					"%s mean %f outside 1.000±0.02" % [curve_name, mean])


func test_malformed_fixtures_rejected() -> void:
	var bad_hour := DayCurveSet.new()
	assert_false(bad_hour.load_from({"curves": {"c": {"kind": "absolute", "keys": [[7.5, 1.0]]}}, "channels": {}}))
	var not_ascending := DayCurveSet.new()
	assert_false(not_ascending.load_from({"curves": {"c": {"kind": "absolute", "keys": [[5, 1.0], [5, 2.0]]}}, "channels": {}}))
	var missing_curve := DayCurveSet.new()
	assert_false(missing_curve.load_from({"curves": {}, "channels": {"x": {"curve": "nope", "min": 0, "max": 1}}}))
	var bad_clamp := DayCurveSet.new()
	assert_false(bad_clamp.load_from({"curves": {"c": {"kind": "absolute", "keys": [[0, 1.0]]}}, "channels": {"x": {"curve": "c", "min": 2, "max": 1}}}))
	var off_mean := DayCurveSet.new()
	assert_false(off_mean.load_from({"curves": {"c": {"kind": "normalized", "keys": [[0, 2.0]]}}, "channels": {}}))


func test_fine_coarse_equivalence_all_channels() -> void:
	# T-09: mean of 240 per-tick midpoint samples across an hour equals the
	# single coarse midpoint sample, to 1e-9, for every channel and all 24 hours.
	var curves := _loaded_curves()
	for channel_name in curves.channel_names():
		for hour in 24:
			var total := 0.0
			for q in 240:
				var x := float(hour) + (float(q * 15) + 7.5) / 3600.0
				total += curves.channel_curve_value(String(channel_name), x)
			var coarse: float = curves.channel_curve_value(String(channel_name), float(hour) + 0.5)
			assert_true(absf(total / 240.0 - coarse) < 1e-9,
					"%s hour %d: fine mean %.12f != coarse %.12f" % [channel_name, hour, total / 240.0, coarse])


func test_modifier_product_order_deterministic() -> void:
	# T-17: same source set in shuffled push orders gives a bit-identical float,
	# and the channel clamp catches a storm-plus-event pileup.
	var curves := _loaded_curves()
	var sources := [
		[&"weather", "storm", {"traffic_density": 1.35}],
		[&"scheduled_event", "match", {"traffic_density": 1.9}],
		[&"policy", "curfew", {"traffic_density": 0.97}],
		[&"district", "d3", {"traffic_density": 1.13}],
		[&"weather", "fog", {"traffic_density": 1.08}],
	]
	var reference := -1.0
	var orders := [[0, 1, 2, 3, 4], [4, 3, 2, 1, 0], [2, 0, 4, 1, 3], [1, 4, 0, 3, 2]]
	for order in orders:
		var stack := ModifierStack.new()
		for i: int in order:
			stack.push_source(sources[i][0], sources[i][1], sources[i][2])
		var product := stack.product_for("traffic_density")
		if reference < 0.0:
			reference = product
		else:
			assert_true(product == reference, "bit-identical product regardless of push order")
	# Clamp: curve 1.87 × 1.9 × 1.35 = 4.797... -> clamped to channel max 4.00
	assert_almost_eq(curves.channel_clamp("traffic_density", 1.87 * 1.9 * 1.35), 4.0, 1e-9)


func test_channel_registry_completeness() -> void:
	# Doc 01 T-22: exactly the 15 channels of §2.6; the pre-C-33 key
	# "water_demand" must no longer resolve.
	var curves := _loaded_curves()
	var expected := [
		"commercial_output", "construction_rate", "crime_rate", "daylight",
		"incident_rate", "power_demand_civic", "power_demand_commercial",
		"power_demand_datacenter", "power_demand_industrial", "power_demand_residential",
		"response_speed", "streetlight_load", "traffic_density",
		"water_demand_commercial", "water_demand_residential",
	]
	assert_eq(curves.channel_names(), expected)
	assert_false(curves.has_channel("water_demand"), "renamed key must fail loudly, not resolve")


func test_push_same_source_replaces() -> void:
	var stack := ModifierStack.new()
	stack.push_source(&"weather", "storm", {"traffic_density": 1.5})
	stack.push_source(&"weather", "storm", {"traffic_density": 1.2})
	assert_eq(stack.source_count(), 1)
	assert_almost_eq(stack.product_for("traffic_density"), 1.2, 1e-12)
	stack.remove_source(&"weather", "storm")
	assert_almost_eq(stack.product_for("traffic_density"), 1.0, 1e-12)
