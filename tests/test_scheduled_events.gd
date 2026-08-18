extends SimTest
## Doc 01 §2.8 / T-16: phase timelines fire on exact ticks, modifiers ride the
## channel stack while a phase is open, and events survive save/load and
## coarse catch-up.

const TEST_TEMPLATE := {
	"phases": [
		{"name": "announce", "offset_minutes": -2880, "notify": "routine", "modifiers": {}},
		{"name": "inbound", "offset_minutes": -120, "notify": "routine",
			"modifiers": {"traffic_density": 1.9, "incident_rate": 1.4}},
		{"name": "live", "offset_minutes": 0, "notify": "routine",
			"modifiers": {"traffic_density": 0.7, "incident_rate": 2.2}},
		{"name": "outbound", "offset_minutes": 150, "notify": "routine",
			"modifiers": {"traffic_density": 2.4}},
		{"name": "end", "offset_minutes": 270, "notify": "none", "modifiers": {}},
	],
}


func _service() -> Array:
	var timers := TimerService.new()
	var mods := ModifierStack.new()
	var service := ScheduledEventService.new({"stadium": TEST_TEMPLATE}, timers, mods)
	return [service, timers, mods]


func test_phases_fire_on_exact_ticks() -> void:
	# Doc 01's worked example: anchor 918,962 → inbound at anchor − 480 ticks.
	var parts := _service()
	var service: ScheduledEventService = parts[0]
	var timers: TimerService = parts[1]
	service.schedule("stadium", 918962)
	var expected := {
		"announce": 918962 - 2880 * 4, "inbound": 918962 - 480,
		"live": 918962, "outbound": 918962 + 600, "end": 918962 + 1080,
	}
	var fired := {}
	for t in [expected["announce"], expected["inbound"], expected["live"],
			expected["outbound"], expected["end"]]:
		service.process_due(timers.collect_due(int(t)))
		for event in service.drain_events():
			if event["type"] == &"event_phase_begin":
				fired[String(event["phase"])] = int(event["due_tick"])
	for phase_name in expected:
		assert_eq(fired.get(phase_name, -1), int(expected[phase_name]),
				"phase %s fires at its exact tick" % phase_name)


func test_modifiers_ride_and_replace() -> void:
	var parts := _service()
	var service: ScheduledEventService = parts[0]
	var timers: TimerService = parts[1]
	var mods: ModifierStack = parts[2]
	service.schedule("stadium", 10000)
	# announce: no modifiers.
	service.process_due(timers.collect_due(10000 - 2880 * 4))
	assert_almost_eq(mods.product_for("traffic_density"), 1.0, 1e-12)
	# inbound: ×1.9.
	service.process_due(timers.collect_due(10000 - 480))
	assert_almost_eq(mods.product_for("traffic_density"), 1.9, 1e-12)
	assert_almost_eq(mods.product_for("incident_rate"), 1.4, 1e-12)
	# live replaces inbound (not stacks): ×0.7.
	service.process_due(timers.collect_due(10000))
	assert_almost_eq(mods.product_for("traffic_density"), 0.7, 1e-12)
	# outbound: ×2.4, incident modifier gone.
	service.process_due(timers.collect_due(10600))
	assert_almost_eq(mods.product_for("traffic_density"), 2.4, 1e-12)
	assert_almost_eq(mods.product_for("incident_rate"), 1.0, 1e-12)
	# end: everything popped; event complete and removed.
	service.process_due(timers.collect_due(11080))
	assert_almost_eq(mods.product_for("traffic_density"), 1.0, 1e-12)
	assert_eq(service.active_count(), 0)


func test_stacks_with_weather_source() -> void:
	# Doc 01's clamp example: curve 1.87 × event 1.9 × weather 1.35 clamps at
	# the channel max — the stack side of that product.
	var parts := _service()
	var service: ScheduledEventService = parts[0]
	var timers: TimerService = parts[1]
	var mods: ModifierStack = parts[2]
	mods.push_source(&"weather", "storm", {"traffic_density": 1.35})
	service.schedule("stadium", 5000)
	service.process_due(timers.collect_due(5000 - 480))
	assert_almost_eq(mods.product_for("traffic_density"), 1.9 * 1.35, 1e-12)


func test_coarse_catchup_fires_in_order() -> void:
	# A coarse jump across several phase boundaries fires them all, in
	# (due_tick, id) order, each reporting its true due_tick.
	var parts := _service()
	var service: ScheduledEventService = parts[0]
	var timers: TimerService = parts[1]
	service.schedule("stadium", 20000)
	service.drain_events()
	service.process_due(timers.collect_due(25000))  # far past everything
	var sequence: Array = []
	for event in service.drain_events():
		if event["type"] == &"event_phase_begin":
			sequence.append(String(event["phase"]))
	assert_eq(sequence, ["announce", "inbound", "live", "outbound", "end"])
	assert_eq(service.active_count(), 0)


func test_save_roundtrip_mid_event() -> void:
	var parts := _service()
	var service: ScheduledEventService = parts[0]
	var timers: TimerService = parts[1]
	var mods: ModifierStack = parts[2]
	service.schedule("stadium", 10000)
	service.process_due(timers.collect_due(10000 - 480))  # inbound open
	# Restore both the timers and the service into a fresh pair.
	var timers2 := TimerService.new()
	timers2.deserialize(timers.serialize())
	var mods2 := ModifierStack.new()
	var service2 := ScheduledEventService.new({"stadium": TEST_TEMPLATE}, timers2, mods2)
	service2.deserialize(service.serialize())
	assert_eq(service2.active_count(), 1)
	assert_eq(String(service2.event(1)["open_phase"]), "inbound")
	# Remaining phases still fire on their exact ticks.
	service2.process_due(timers2.collect_due(10000))
	var fired_live := false
	for event in service2.drain_events():
		if event["type"] == &"event_phase_begin" and String(event["phase"]) == "live":
			fired_live = true
	assert_true(fired_live)
	assert_almost_eq(mods2.product_for("traffic_density"), 0.7, 1e-12)


func test_cancel_clears_modifiers_and_ignores_orphans() -> void:
	var parts := _service()
	var service: ScheduledEventService = parts[0]
	var timers: TimerService = parts[1]
	var mods: ModifierStack = parts[2]
	var event_id := service.schedule("stadium", 10000)
	service.process_due(timers.collect_due(10000 - 480))
	assert_almost_eq(mods.product_for("traffic_density"), 1.9, 1e-12)
	service.drain_events()  # flush pre-cancel events so the orphan check is clean
	assert_true(service.cancel(event_id))
	assert_almost_eq(mods.product_for("traffic_density"), 1.0, 1e-12)
	# Orphaned timers for the cancelled event fire harmlessly.
	service.process_due(timers.collect_due(12000))
	assert_eq(service.drain_events().filter(
			func(e: Dictionary) -> bool: return e["type"] == &"event_phase_begin").size(), 0)


func test_thunderstorm_template_from_data() -> void:
	# The shipped MVP template (data/time.json): five phases, empty modifiers
	# (doc 07 owns storm effects per C-27), warning notify classes present.
	var text := FileAccess.get_file_as_string("res://data/time.json")
	var data: Dictionary = JSON.parse_string(text)
	var templates: Dictionary = data["event_templates"]
	assert_true(templates.has("thunderstorm_hazard"))
	var timers := TimerService.new()
	var mods := ModifierStack.new()
	var service := ScheduledEventService.new(templates, timers, mods)
	service.schedule("thunderstorm_hazard", 100000)
	service.process_due(timers.collect_due(100000))  # watch (−240m), warning (−60m), impact (0)
	var fired: Array = []
	for event in service.drain_events():
		if event["type"] == &"event_phase_begin":
			fired.append([String(event["phase"]), String(event["notify"])])
	assert_eq(fired.size(), 3)
	assert_eq(fired[0], ["watch", "important"])
	assert_eq(fired[1], ["warning", "critical"])
	assert_eq(fired[2], ["impact", "critical"])
	assert_almost_eq(mods.product_for("traffic_density"), 1.0, 1e-12,
			"C-27: the template carries timing only; doc 07 owns storm effects")
