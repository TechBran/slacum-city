extends SimTest
## **The lot dressing** (doc 11 §2.16a, doc 02 §2.3a, doc 93 §BE7, Wave 29).
##
## The visible half of the lot rule: the reserved-but-unbuilt part of a lot is
## drawn as an apron, and it recedes as the building grows into it. These hold
## the four properties that make the layer safe to ship — it is a pure function
## of the sim (so it cannot move a hash), it draws only on ground the building
## actually owns, it empties itself as the building grows, and the governor can
## thin it without taking the ground away.


static func _model(render_data: Dictionary = {}) -> LotDressingModel:
	var m := LotDressingModel.new()
	m.configure(render_data)
	return m


static func _row(sim_id: String, archetype: StringName, origin: Vector2i,
		held: Vector2i, built: Vector2i) -> Dictionary:
	return {"sim_id": sim_id, "archetype": archetype, "origin": origin,
			"held": held, "built": built, "elev_m": 0.0}


# ------------------------------------------------------ it draws the remainder

func test_the_apron_covers_exactly_the_unbuilt_part_of_the_lot() -> void:
	var m := _model()
	# A young store: 2×2 reserved, 1×1 built — so three tiles of apron.
	m.apply_rows([_row("S-1", &"store", Vector2i(10, 10), Vector2i(2, 2), Vector2i(1, 1))])
	assert_eq(m.pads.size(), 3, "three of the four lot tiles are un-built")
	# …and none of them is the tile the building is standing on.
	var built_centre := TileGrid.centre_of(Vector2i(10, 10))
	for pad in m.pads:
		var pos: Vector3 = pad["world_pos"]
		assert_false(is_equal_approx(pos.x, built_centre.x)
				and is_equal_approx(pos.z, built_centre.z),
				"the apron is never drawn under the building itself")


func test_the_apron_recedes_as_the_building_grows_into_it() -> void:
	var m := _model()
	var shrinking: Array[int] = []
	for built in [Vector2i(1, 1), Vector2i(2, 2)]:
		m.apply_rows([_row("S-1", &"store", Vector2i(10, 10), Vector2i(2, 2), built)])
		shrinking.append(m.pads.size())
	assert_eq(shrinking, [3, 0] as Array[int],
			"a store that fills its lot has no apron left")
	assert_eq(m.props.size(), 0, "and nothing standing on it either")
	# The same on the biggest grower: a plant is 9 of 16 built at L1, 16 of 16 at L4.
	m.apply_rows([_row("P-1", &"power_facility", Vector2i(20, 20),
			Vector2i(4, 4), Vector2i(3, 3))])
	assert_eq(m.pads.size(), 7, "16 − 9 tiles of compound")
	m.apply_rows([_row("P-1", &"power_facility", Vector2i(20, 20),
			Vector2i(4, 4), Vector2i(4, 4))])
	assert_eq(m.pads.size(), 0)


func test_it_never_dresses_ground_the_building_does_not_hold() -> void:
	# A LOT-LOCKED store holds 1×1 of a 2×2 lot. Dressing the lot rather than the
	# HELD extent would paint an apron over the neighbour that is boxing it in.
	var m := _model()
	m.apply_rows([_row("S-9", &"store", Vector2i(10, 10), Vector2i(1, 1), Vector2i(1, 1))])
	assert_eq(m.pads.size(), 0, "it holds only what it has built, so there is no apron")


func test_each_growing_archetype_dresses_as_the_site_it_is() -> void:
	var m := _model()
	m.apply_rows([
		_row("S-1", &"store", Vector2i(10, 10), Vector2i(2, 2), Vector2i(1, 1)),
		_row("Y-1", &"construction_yard", Vector2i(20, 20), Vector2i(3, 3), Vector2i(2, 2)),
		_row("P-1", &"power_facility", Vector2i(30, 30), Vector2i(4, 4), Vector2i(3, 3)),
	])
	var kinds := {}
	for pad in m.pads:
		kinds[int(pad["site"])] = true
	assert_true(kinds.has(LotDressingModel.SITE_FORECOURT), "a shop parks its customers")
	assert_true(kinds.has(LotDressingModel.SITE_YARD), "a yard stacks its material")
	assert_true(kinds.has(LotDressingModel.SITE_COMPOUND), "a plant fences its switchgear")
	# The nine flat archetypes never reach the layer at all.
	m.apply_rows([_row("H-1", &"house", Vector2i(40, 40), Vector2i(1, 1), Vector2i(1, 1))])
	assert_eq(m.pads.size(), 0)


# --------------------------------------------------- it is a PURE function

func test_the_same_lot_dresses_identically_every_time() -> void:
	# No RNG stream, named or otherwise: two independent models must agree
	# instance for instance, or two devices would draw different cities.
	var rows: Array[Dictionary] = [
		_row("Y-1", &"construction_yard", Vector2i(20, 20), Vector2i(3, 3), Vector2i(2, 2)),
	]
	var a := _model()
	var b := _model()
	a.apply_rows(rows)
	b.apply_rows(rows)
	assert_eq(a.props.size(), b.props.size())
	for i in a.props.size():
		assert_eq((a.props[i] as Dictionary)["world_pos"],
				(b.props[i] as Dictionary)["world_pos"],
				"prop %d is in the same place on both" % i)
		assert_eq((a.props[i] as Dictionary)["yaw"], (b.props[i] as Dictionary)["yaw"])
	# …and rebuilding in place is the same as building fresh.
	a.rebuild()
	assert_eq(a.props.size(), b.props.size())


func test_drawing_the_layer_cannot_move_the_state_hash() -> void:
	# The strongest form of "it is a pure consumer": build the whole layer off a
	# live city and assert the city is byte-identical afterwards.
	var sim := CitySim.boot_from_files(1337)
	var before := sim.state_hash()
	var m := _model()
	m.apply_rows(LotDressingModel.rows_from_sim(sim))
	assert_true(m.pads.size() > 0, "the founding city has aprons to draw")
	assert_eq(sim.state_hash(), before, "reading the sim to dress it changed nothing")


func test_rows_from_sim_finds_the_founding_citys_growers() -> void:
	var sim := CitySim.boot_from_files(1337)
	var rows := LotDressingModel.rows_from_sim(sim)
	# Doc 93 §BE6: five stores, the plant, the yard and WTR-2 (a doc-05 TANK) all
	# hold more ground than they cover at L1. Every one of them is an apron.
	assert_eq(rows.size(), 8, "the eight founding growers")
	var by_id := {}
	for row in rows:
		by_id[String(row["sim_id"])] = row
	assert_true(by_id.has("STR-001"))
	assert_true(by_id.has("PLANT-1"))
	assert_true(by_id.has("YARD-1"))
	assert_true(by_id.has("WTR-2"), "the tank grows; doc 02's pump column would hide it")
	assert_false(by_id.has("WTR-1"), "the pump does not grow, so it has no apron")


# ------------------------------------------------------------- the budget

func test_the_governor_thins_the_props_and_never_the_ground() -> void:
	var m := _model()
	var rows: Array[Dictionary] = [
		_row("P-1", &"power_facility", Vector2i(30, 30), Vector2i(4, 4), Vector2i(3, 3)),
	]
	m.apply_rows(rows)
	var pads_full := m.pads.size()
	var props_full := m.props.size()
	assert_true(props_full > 0)
	m.prop_ratio = 0.5
	m.rebuild()
	assert_eq(m.pads.size(), pads_full, "the ground never thins")
	assert_true(m.props.size() < props_full, "…and what stands on it does")
	# The floor: everything standing goes, the apron stays.
	m.prop_ratio = 0.0
	m.rebuild()
	assert_eq(m.pads.size(), pads_full, "a throttled phone can still see reserved ground")
	assert_eq(m.props.size(), 0)


func test_the_governor_ladder_carries_the_knob_this_layer_reads() -> void:
	var render_data: Dictionary = StarterCityLoader.read_json("res://data/render.json")
	var ids: Array[String] = []
	for rung: Dictionary in (render_data["governor"]["knobs"] as Array):
		ids.append(String(rung["id"]))
	assert_true(ids.has("lot_prop_ratio"),
			"the knob LotDressingView.apply_governor reads must be on the ladder")
	# It is spent BEFORE the preset is latched down, because dropping apron props
	# is strictly gentler than dropping every setting a tier away.
	assert_true(ids.find("lot_prop_ratio") < ids.find("preset_drop"))
	assert_true(ids.find("lot_prop_ratio") > ids.find("street_lights"),
			"…and after the four rungs that shipped before it, so no device's "
			+ "existing ladder position moves")


func test_the_layer_is_two_draw_calls_whatever_the_city_does() -> void:
	var sim := CitySim.boot_from_files(1337)
	var view := LotDressingView.new()
	view.setup(LotDressingModel.new(),
			StarterCityLoader.read_json("res://data/render.json"))
	view.apply_rows(LotDressingModel.rows_from_sim(sim))
	assert_eq(view.draw_calls(), 2, "one pad buffer, one prop buffer, city-wide")
	assert_true(view.pad_count() > 0)
	assert_true(view.prop_count() > 0)
	# An empty roster empties both buffers rather than leaving the last city on
	# the ground, and costs nothing at all.
	view.apply_rows([] as Array[Dictionary])
	assert_eq(view.pad_count(), 0)
	assert_eq(view.prop_count(), 0)
	assert_eq(view.draw_calls(), 0, "a city with nothing mid-growth pays nothing")
	view.free()
