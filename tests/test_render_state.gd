extends SimTest
## Doc 11 §7.2 (RenderStateModel) plus §7.3b tests 24 and 25.
## Numbering in the method names follows the doc's test numbers.

const NEAR := RenderStateModel.TIER_NEAR
const MEDIUM := RenderStateModel.TIER_MEDIUM
const FAR := RenderStateModel.TIER_FAR
const CULLED := RenderStateModel.TIER_CULLED

const STEP := 1.0 / 60.0


func _model(at_hour: float = 21.0) -> RenderStateModel:
	var m := RenderStateModel.new(RenderStateModel.load_config())
	m.set_hour(at_hour)
	return m


func _view(id: int, pos: Vector3, block_id: Variant = 0, extra: Dictionary = {}) -> Dictionary:
	var v := {"id": id, "archetype_id": &"apartment", "level": 3, "family": "residential",
			"world_pos": pos, "block_id": block_id, "chunk": Vector2i(0, 0), "occ_b": 0.90,
			"transform": Transform3D(Basis.IDENTITY, pos)}
	for k in extra:
		v[k] = extra[k]
	return v


func _advance_to(m: RenderStateModel, seconds: float, step: float = STEP) -> void:
	var steps := int(round(seconds / step))
	for i in steps:
		m.advance(step)


# ------------------------------------------------------- 8 — LOD + hysteresis

func test_08_lod_banding_and_hysteresis() -> void:
	var m := _model()
	# doc's exact sequence: 100 -> 160 -> 145 -> 200 with dwell 0.5 satisfied
	var tier := m.lod_for(100.0, -1, 1.0)
	assert_eq(tier, NEAR, "d=100 is NEAR")
	tier = m.lod_for(160.0, tier, 1.0)
	assert_eq(tier, NEAR, "160 < 150+20 stays NEAR")
	tier = m.lod_for(145.0, tier, 1.0)
	assert_eq(tier, NEAR, "back inside the band")
	tier = m.lod_for(200.0, tier, 1.0)
	assert_eq(tier, MEDIUM, "200 > 170 downgrades once")

	# upgrade needs edge - 20
	assert_eq(m.lod_for(140.0, MEDIUM, 1.0), MEDIUM, "140 > 130, no upgrade")
	assert_eq(m.lod_for(129.0, MEDIUM, 1.0), NEAR, "129 <= 130 upgrades")
	# medium/far edges
	assert_eq(m.lod_for(430.0, MEDIUM, 1.0), MEDIUM, "430 < 440 holds MEDIUM")
	assert_eq(m.lod_for(441.0, MEDIUM, 1.0), FAR, "441 > 440 downgrades")
	assert_eq(m.lod_for(401.0, FAR, 1.0), FAR, "401 > 400 holds FAR")
	assert_eq(m.lod_for(399.0, FAR, 1.0), MEDIUM, "399 <= 400 upgrades")
	# cull edge uses the preset's far_cull_m (balanced = 1200)
	assert_eq(m.lod_for(1210.0, FAR, 1.0), FAR, "1210 < 1220 holds FAR")
	assert_eq(m.lod_for(1230.0, FAR, 1.0), CULLED, "1230 > 1220 culls")
	# dwell gate and one-step-at-a-time
	assert_eq(m.lod_for(1000.0, NEAR, 0.2), NEAR, "dwell < 0.5 suppresses the change")
	assert_eq(m.lod_for(5.0, FAR, 1.0), MEDIUM, "at most one tier per dwell")


func test_08b_chunk_tier_dwell_no_oscillation() -> void:
	var m := _model()
	m.add_building(_view(1, Vector3(64, 0, 64)))
	var cam := Vector3(64.0, 100.0, 64.0)
	m.update_chunk_tiers(cam, 1.0)
	assert_eq(m.chunk_tier(Vector2i(0, 0)), NEAR, "camera overhead is NEAR")
	# oscillating around the 150 m edge must not flip the tier
	var flips := 0
	var prev := m.chunk_tier(Vector2i(0, 0))
	for i in 40:
		var y := 155.0 if i % 2 == 0 else 145.0
		m.update_chunk_tiers(Vector3(64.0, y, 64.0), STEP)
		if m.chunk_tier(Vector2i(0, 0)) != prev:
			flips += 1
			prev = m.chunk_tier(Vector2i(0, 0))
	assert_eq(flips, 0, "hysteresis + dwell prevent oscillation")


# ------------------------------------------- 19b — ground-plane AABB LOD rule

func test_19b_lod_distance_uses_ground_plane_aabb() -> void:
	var m := _model()
	# Z2 pose: D=420, pitch 62 -> camera height 370.8 m
	assert_almost_eq(m.camera_distance_m(1.0), 420.0, 1e-3, "D(1) = D_MAX")
	assert_almost_eq(m.camera_pitch_deg(1.0), 62.0, 1e-3, "pitch(1) = 62")
	var h := 420.0 * sin(deg_to_rad(62.0))
	assert_almost_eq(h, 370.8, 0.1, "Z2 camera height")

	# chunk (0,0) spans [0,128]^2; camera 52.1 m outside its near edge
	var cam := Vector3(-52.1, h, 64.0)
	var d := m.chunk_ground_distance(Vector2i(0, 0), cam)
	assert_almost_eq(d, 374.4, 0.2, "ground-plane nearest-point distance")
	assert_eq(m.lod_for(d, -1, 1.0), MEDIUM, "still MEDIUM at Z2")

	# a 217 m res_highrise in that chunk collapses a building-inclusive AABB from
	# 374 m to 162 m (doc 11 §2.5's worked number) — 212 m of error on one chunk.
	var d_building_inclusive := sqrt(52.1 * 52.1 + pow(h - 217.0, 2.0))
	assert_almost_eq(d_building_inclusive, 162.0, 1.0, "the rejected building-AABB distance")
	assert_true(d - d_building_inclusive > 200.0, "the wrong rule mis-tiers by over 200 m")
	# and with the tower directly under the camera the building-inclusive rule
	# does cross into NEAR, re-arming the shadow pass at max zoom.
	var d_overhead := h - 250.0
	assert_true(d_overhead < m.near_max_m - m.hysteresis_m,
			"a 250 m tower under the Z2 camera would tier NEAR on the wrong rule")
	assert_eq(m.lod_for(d_overhead, -1, 1.0), NEAR, "which is exactly what §2.5 forbids")
	assert_eq(m.lod_for(d_overhead, MEDIUM, 1.0), NEAR, "and it would actively upgrade the tier")
	assert_eq(m.lod_for(m.chunk_ground_distance(Vector2i(0, 0), Vector3(64.0, h, 64.0)), -1, 1.0),
			MEDIUM, "the ground-plane rule keeps that chunk MEDIUM")


func test_19c_no_near_chunks_at_z2() -> void:
	var m := _model()
	var focus := Vector3(1024.0, 0.0, 1024.0)
	var cam := m.camera_position(focus, 1.0, 0.0)
	assert_almost_eq(cam.y, 370.8, 0.1, "Z2 height")
	assert_almost_eq(cam.z - focus.z, 197.2, 0.1, "nadir sits 197.2 m behind focus")
	var near_count := 0
	var medium_count := 0
	for bx in range(0, 16):
		for by in range(0, 16):
			var dist := m.chunk_ground_distance(Vector2i(bx, by), cam)
			var tier := m.lod_for(dist, -1, 1.0)
			if tier == NEAR:
				near_count += 1
			elif tier == MEDIUM:
				medium_count += 1
	assert_eq(near_count, 0, "the shadow pass is empty at Z2")
	assert_true(medium_count > 0, "the nearest rows are MEDIUM, not FAR")


func test_19d_camera_pose_table() -> void:
	var m := _model()
	assert_almost_eq(m.camera_distance_m(0.0), 18.0, 1e-4, "Z0 D")
	assert_almost_eq(m.camera_pitch_deg(0.0), 34.0, 1e-4, "Z0 pitch")
	assert_almost_eq(m.camera_distance_m(0.5), 86.9, 0.05, "Z1 D = 18*sqrt(420/18)")
	assert_almost_eq(m.camera_pitch_deg(0.5), 48.0, 1e-4, "Z1 pitch")
	var z1 := m.camera_position(Vector3.ZERO, 0.5, 0.0)
	assert_almost_eq(z1.y, 64.6, 0.1, "Z1 camera height")


# ------------------------------------------------------ 9 / 9b — emissive art

func test_09_emissive_target_rows() -> void:
	var m := _model(21.0)
	var rec := m.add_building(_view(1, Vector3(8, 0, 8), 0, {"occ_b": 0.92}))
	assert_almost_eq(rec.emissive_target, 0.9640, 1e-4, "21:00 powered undamaged")
	assert_eq(int(round(rec.emissive_target * 960.0)), 925, "925 lit windows")

	m.set_hour(3.0)
	assert_almost_eq(rec.emissive_target, 0.5997, 1e-4, "03:00 powered undamaged")
	assert_eq(int(round(rec.emissive_target * 960.0)), 576, "576 lit windows")

	m.set_hour(21.0)
	rec.powered = false
	assert_almost_eq(m.emissive_target_for(rec), 0.05, 1e-4, "blackout, no backup")
	assert_eq(int(round(m.emissive_target_for(rec) * 960.0)), 48, "48 lit windows")

	rec.has_backup_power = true
	assert_almost_eq(m.emissive_target_for(rec), 0.22, 1e-4, "blackout, backup generator")
	assert_eq(int(round(m.emissive_target_for(rec) * 960.0)), 211, "211 lit windows")

	rec.has_backup_power = false
	rec.damage = 0.60
	assert_almost_eq(m.emissive_target_for(rec), 0.035, 1e-4, "blackout, 60% fire damage")
	assert_eq(int(round(m.emissive_target_for(rec) * 960.0)), 34, "34 lit windows")

	# condition gate (§2.7.1, report C-14 scale)
	rec.damage = 0.0
	rec.powered = true
	rec.condition = 0.10
	assert_almost_eq(m.emissive_target_for(rec), 0.9640 * 0.40, 1e-4, "condition < 0.15 dims")


func test_09b_occupancy_curves() -> void:
	var m := _model()
	for family in ["residential", "commercial", "industrial", "tech", "civic"]:
		var h := 0.0
		while h < 24.0:
			var v := m.occupancy_curve(family, h)
			assert_true(v >= 0.0 and v <= 1.0, "%s in [0,1] at %.1f" % [family, h])
			h += 0.25
		var seam_a := m.occupancy_curve(family, 23.999)
		var seam_b := m.occupancy_curve(family, 0.001)
		assert_true(absf(seam_a - seam_b) < 0.05, "%s continuous across the 24 h wrap" % family)
	for h2 in [0.0, 6.0, 12.0, 18.0, 23.0]:
		assert_almost_eq(m.occupancy_curve("tech", h2), 1.0, 1e-6, "tech is flat")
	assert_true(m.occupancy_curve("residential", 21.0) > m.occupancy_curve("residential", 12.0),
			"residential peaks at night, not noon")
	assert_true(m.occupancy_curve("residential", 21.0) > m.occupancy_curve("residential", 3.0),
			"residents asleep at 03:00 are not lit windows")
	assert_true(m.occupancy_curve("commercial", 13.0) > m.occupancy_curve("commercial", 3.0),
			"commercial is the reverse: daytime peak")


# --------------------------------------------------------- 10 — lit windows

func test_10_lit_window_count() -> void:
	var m := _model()
	var lit := m.lit_window_count(5, 48, 4, 0.05, 0)
	assert_true(lit >= 38 and lit <= 58, "5%% of 960 cells lit, got %d" % lit)
	assert_eq(m.lit_window_count(5, 48, 4, 0.05, 0), lit, "stable across evaluations")
	assert_eq(m.lit_window_count(5, 48, 4, 1.0, 0), 960, "e = 1 lights every cell")
	assert_eq(m.lit_window_count(5, 48, 4, 0.0, 0), 0, "e = 0 lights nothing")


# ------------------------------------------------------- 11 — going dark

func test_11_blackout_timeline() -> void:
	var m := _model(21.0)
	for i in 24:
		m.add_building(_view(100 + i, Vector3(float(i) * 4.0, 0.0, 16.0), 7))
	var mean0 := _block_mean(m, 7)
	assert_true(mean0 > 0.9, "block starts lit")

	m.plan_blackout(7, 0.0)
	_advance_to(m, 0.10)
	var mean_stutter := _block_mean(m, 7)
	assert_true(mean_stutter < 0.25 * mean0,
			"stutter fired: %.4f vs %.4f" % [mean_stutter, 0.25 * mean0])

	_advance_to(m, 1.15)  # total 1.25 s
	for i in 24:
		var rec := m.building(100 + i)
		assert_almost_eq(m.emissive_out(100 + i), rec.emissive_target, 0.001,
				"settled within 1% by t=1.25")
	assert_almost_eq(m.chunk_power_mult(7), 0.45, 0.02, "ground darkens to 0.45")
	var events := m.drain_render_events()
	assert_eq(events.size(), 1, "one render_blackout_started")
	assert_eq(events[0]["type"], &"render_blackout_started", "event name")


func _block_mean(m: RenderStateModel, block_id: Variant) -> float:
	var b := m.block(block_id)
	var sum := 0.0
	for id in b.buildings:
		sum += m.emissive_out(id)
	return sum / float(maxi(1, b.buildings.size()))


func test_11b_stutter_envelope_shape() -> void:
	var m := _model()
	var keys: Array = m.blackout_cfg["stutter_envelope"]
	assert_eq(keys.size(), 7, "7 keyframes")
	m.add_building(_view(1, Vector3(8, 0, 8), 3))
	m.plan_blackout(3, 0.0)
	assert_almost_eq(m.envelope_mult(3), 1.00, 1e-6, "t=0")
	m.advance(0.09)
	assert_almost_eq(m.envelope_mult(3), 0.12, 1e-6, "first dip at 0.09")
	m.advance(0.06)
	assert_almost_eq(m.envelope_mult(3), 0.95, 1e-6, "recovery at 0.15")
	m.advance(0.02)
	assert_almost_eq(m.envelope_mult(3), 0.08, 1e-6, "second dip at 0.17")
	m.advance(0.14)
	assert_almost_eq(m.envelope_mult(3), 1.0, 1e-6, "released after 0.30")


# ------------------------------------------ 12 / 12b — relight sweep ordering

func _relight_block(m: RenderStateModel, block_id: Variant, n: int) -> Array:
	var ids: Array = []
	for i in n:
		var id := 200 + i
		# geometry deliberately ordered left-to-right
		m.add_building(_view(id, Vector3(float(i) * 4.0, 0.0, 0.0), block_id))
		ids.append(id)
	return ids


func test_12_relight_ordering_restore_order() -> void:
	var m := _model()
	m.blackout_cfg["relight_jitter_s"] = 0.0  # jitter zeroed per the doc's example
	var ids := _relight_block(m, 11, 28)
	# restore_order REVERSED relative to geometry: ranks must beat metres
	var order: Array = []
	for i in range(ids.size() - 1, -1, -1):
		order.append(ids[i])
	var sl_pos := Vector3(4.0, 0.0, 0.0)  # nearest building is ids[1] (rank 26)
	m.add_streetlight(900, 11, sl_pos)

	var result := m.plan_relight(11, order, null, 1.0)
	var delays: Dictionary = result["delays"]
	assert_false(bool(result["momentary"]), "never dark -> sustained ceremony")
	assert_almost_eq(float(delays[order[0]]), 0.0, 1e-6, "k=0 lights immediately")
	assert_almost_eq(float(delays[order[9]]), 2.2 * 9.0 / 27.0, 1e-3, "k=9 at 0.733 s")
	assert_almost_eq(float(delays[order[9]]), 0.7333, 1e-3, "0.733 s exactly")
	assert_almost_eq(float(delays[order[27]]), 2.200, 1e-6, "last rank at 2.2 s")
	var prev := -1.0
	for k in order.size():
		var d := float(delays[order[k]])
		assert_true(d >= prev - 1e-9, "delays non-decreasing in rank")
		prev = d
	# rank beats distance: the geometrically nearest building is nearly last
	assert_true(float(delays[ids[0]]) > float(delays[ids[27]]),
			"the reversed order is honoured, not the metres")
	assert_almost_eq(m.streetlight(900).delay, 0.80 * float(delays[ids[1]]), 1e-6,
			"streetlight takes 0.80 x its nearest building's delay")
	assert_almost_eq(float(result["duration_s"]), 3.15 - 0.5, 1e-6,
			"duration = sweep + jitter(0) + ramp + settle")


func test_12b_relight_fallback_distance_and_centroid() -> void:
	var m := _model()
	m.blackout_cfg["relight_jitter_s"] = 0.0
	var ids: Array = []
	for i in 28:
		var id := 300 + i
		m.add_building(_view(id, Vector3(float(i) * 4.5, 0.0, 0.0), 12))
		ids.append(id)
	var source := Vector3(0.0, 0.0, 0.0)
	var res := m.plan_relight(12, [], source, 1.0)
	var delays: Dictionary = res["delays"]
	var prev := -1.0
	for i in ids.size():
		var d := float(delays[ids[i]])
		assert_true(d >= prev - 1e-9, "delays non-decreasing in distance")
		prev = d
	assert_almost_eq(float(delays[ids[0]]), 0.0, 1e-6, "at the source")
	assert_almost_eq(float(delays[ids[27]]), 2.200, 1e-6, "farthest at 2.2 s")

	# no source_pos at all -> block centroid, still terminating at 2.2 s
	var res2 := m.plan_relight(12, [], null, 1.0)
	var delays2: Dictionary = res2["delays"]
	var max_delay := 0.0
	for id in ids:
		max_delay = maxf(max_delay, float(delays2[id]))
	assert_almost_eq(max_delay, 2.200, 1e-6, "centroid fallback still spans 2.2 s")


# ------------------------------------------------------------ 13 — overshoot

func test_13_relight_inrush_overshoot() -> void:
	var m := _model(21.0)
	m.blackout_cfg["relight_jitter_s"] = 0.0
	m.add_building(_view(1, Vector3(8, 0, 8), 20, {"occ_b": 0.92}))
	var target := m.building(1).emissive_target
	m.plan_relight(20, [1], null, 1.0)
	var peak := 0.0
	var t := 0.0
	var peak_t := 0.0
	for i in 144:  # 0.6 s at 1/240
		m.advance(1.0 / 240.0)
		t += 1.0 / 240.0
		var e := m.emissive_out(1)
		if e > peak:
			peak = e
			peak_t = t
	assert_almost_eq(peak, 1.35 * target, 0.01 * 1.35 * target, "peak is 1.35 x target")
	assert_almost_eq(peak_t, 0.15, 0.01, "peak lands at delay + 0.15 s")
	assert_almost_eq(m.emissive_out(1), target, 0.01 * target, "settled by delay + 0.45 s")


# ------------------------------------ 14 — momentary vs sustained (§2.7.5)

func _outage_case(outage_s: float) -> Dictionary:
	var m := _model(21.0)
	m.blackout_cfg["relight_jitter_s"] = 0.0
	var ids: Array = []
	for i in 8:
		var id := 400 + i
		m.add_building(_view(id, Vector3(float(i) * 8.0, 0.0, 0.0), 31))
		ids.append(id)
	m.plan_blackout(31, 0.0)
	_advance_to(m, outage_s)
	var res := m.plan_relight(31, ids, null, 1.0)
	return {"model": m, "result": res, "ids": ids}


func test_14_momentary_classification() -> void:
	var momentary_s := float(_model().blackout_cfg["momentary_outage_s"])
	assert_almost_eq(momentary_s, 4.50, 1e-9, "§8 momentary_outage_s")

	# reclose succeeds on attempt 1 — 90 gs = 1.5 real s
	var c1 := _outage_case(1.5)
	assert_true(bool((c1["result"] as Dictionary)["momentary"]), "1.5 s is momentary")
	var delays1: Dictionary = (c1["result"] as Dictionary)["delays"]
	for id in c1["ids"]:
		assert_almost_eq(float(delays1[id]), 0.0, 1e-9, "no sweep delay scheduled")
	var m1: RenderStateModel = c1["model"]
	_advance_to(m1, 0.85)
	for id in c1["ids"]:
		assert_almost_eq(m1.emissive_out(id), m1.building(id).emissive_target, 0.001,
				"block fully lit by t = 0.85 s")

	# reclose succeeds on attempt 2 — 180 gs = 3.0 real s (mis-classified under the old 2.50)
	assert_true(bool((_outage_case(3.0)["result"] as Dictionary)["momentary"]),
			"3.0 s is momentary at the recomputed 4.50 threshold")
	# the boundary itself classifies as momentary
	assert_true(bool((_outage_case(4.50)["result"] as Dictionary)["momentary"]),
			"4.50 s exactly is momentary")
	# past the threshold the full ceremony returns
	assert_false(bool((_outage_case(6.0)["result"] as Dictionary)["momentary"]), "6.0 s is sustained")
	var c11 := _outage_case(11.0)
	assert_false(bool((c11["result"] as Dictionary)["momentary"]), "11.0 s lockout is sustained")
	var delays11: Dictionary = (c11["result"] as Dictionary)["delays"]
	var ids11: Array = c11["ids"]
	assert_almost_eq(float(delays11[ids11[ids11.size() - 1]]), 2.200, 1e-6,
			"last-ranked building sweeps at 2.2 s")


# --------------------------------------------------- 15 — partial outage

func test_15_partial_outage_is_stable() -> void:
	var m := _model()
	var ids: Array = []
	for i in 40:
		var id := 500 + i
		var priority := i % 10 == 0
		m.add_building(_view(id, Vector3(float(i) * 3.0, 0.0, 0.0), 44,
				{"priority_load": priority}))
		ids.append(id)
	var first := m.powered_set(44, 0.4)
	for n in 100:
		assert_eq(m.powered_set(44, 0.4), first, "hash-stable dark set")
	assert_true(first.size() > 0 and first.size() < ids.size(), "a real subset stays lit")
	for i in 40:
		if i % 10 == 0:
			assert_true(first.has(500 + i), "priority_load stays lit while fraction > 0")
	m.plan_blackout(44, 0.4)
	for i in 40:
		var rec := m.building(500 + i)
		assert_eq(rec.powered, first.has(500 + i), "plan_blackout used the same set")
	assert_eq(m.powered_set(44, 0.0).size(), 0, "fraction 0 darkens everything")


# ------------------------------------------------------- 16 — slot allocator

func test_16_slot_allocator_churn() -> void:
	var m := _model()
	var live: Array = []
	for i in 100:
		m.add_building(_view(600 + i, Vector3(float(i), 0.0, 0.0), 50))
		live.append(600 + i)
	var b := m.bucket(Vector2i(0, 0), &"apartment", 3)
	assert_eq(b.visible_count, 100, "100 live instances")
	assert_eq(b.capacity, 128, "capacity rounded to a multiple of 32")

	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for n in 40:
		var pick := rng.randi_range(0, live.size() - 1)
		var id: int = live[pick]
		live.remove_at(pick)
		m.remove_building(id)
	assert_eq(b.visible_count, 60, "40 removed")
	for i in 40:
		m.add_building(_view(800 + i, Vector3(float(i), 0.0, 4.0), 50))
		live.append(800 + i)

	assert_eq(b.visible_count, 100, "back to 100 visible instances")
	var seen: Dictionary = {}
	for id in live:
		var rec := m.building(id)
		assert_true(rec.slot >= 0 and rec.slot < b.visible_count, "slot in range")
		assert_false(seen.has(rec.slot), "no duplicate slots")
		seen[rec.slot] = id
		assert_eq(b.slot_owner[rec.slot], id, "slot_owner consistent")
	for s in b.visible_count:
		assert_true(seen.has(s), "no holes below visible_instance_count")
		var owner: int = seen[s]
		var origin_x := b.mirror[s * RenderStateModel.INSTANCE_STRIDE + 3]
		assert_almost_eq(origin_x, m.building(owner).transform.origin.x, 1e-4,
				"no stale transform in a live slot")
	for s in range(b.visible_count, b.capacity):
		assert_eq(b.slot_owner[s], -1, "tail slots are free")
	assert_eq(b.free_slots.size(), b.capacity - b.visible_count, "free list is the tail")


func test_16b_instance_mirror_stride() -> void:
	var m := _model()
	assert_eq(RenderStateModel.INSTANCE_STRIDE, 16, "12 transform + 4 custom floats")
	var pos := Vector3(12.0, 0.0, 34.0)
	m.add_building(_view(1, pos, 60))
	var b := m.bucket(Vector2i(0, 0), &"apartment", 3)
	assert_eq(b.mirror.size(), b.capacity * 16, "mirror is stride x capacity")
	assert_almost_eq(b.mirror[3], 12.0, 1e-5, "origin.x at float 3")
	assert_almost_eq(b.mirror[7], 0.0, 1e-5, "origin.y at float 7")
	assert_almost_eq(b.mirror[11], 34.0, 1e-5, "origin.z at float 11")
	var custom := m.mirror_custom(Vector2i(0, 0), &"apartment", 3, 0)
	assert_almost_eq(custom.r, m.emissive_out(1), 1e-5, "custom.r = emissive")
	assert_almost_eq(custom.g, 0.0, 1e-5, "custom.g = damage")
	assert_almost_eq(custom.a, m.building(1).anim_phase, 1e-5, "custom.a = anim_phase")


# ------------------------------------------------- 17 — custom-data packing

func test_17_custom_data_packing_round_trip() -> void:
	var count := 0
	for variant in 16:
		for stage in 7:
			for overlay in 4:
				var packed := RenderStateModel.pack_state(variant, stage, overlay)
				var back := RenderStateModel.unpack_state(packed)
				assert_eq(back["variant"], variant, "variant round-trip")
				assert_eq(back["stage"], stage, "stage round-trip")
				assert_eq(back["overlay"], overlay, "overlay round-trip")
				assert_eq(packed, float(int(packed)), "exact in f32")
				count += 1
	assert_eq(count, 448, "16 x 7 x 4 combinations")
	assert_almost_eq(RenderStateModel.pack_state(15, 6, 3), 447.0, 1e-9, "max packed value")
	assert_eq(RenderStateModel.PACK_OVERLAY_STRIDE, 112, "the locked packing constant")


func test_17b_variant_and_phase_ranges() -> void:
	for id in 500:
		var v := RenderStateModel.variant_of(id)
		assert_true(v >= 0 and v < 16, "variant in 0..15")
		var p := RenderStateModel.anim_phase_of(id)
		assert_true(p >= 0.0 and p <= 1.0, "anim_phase in [0,1]")
		var h := RenderStateModel.hash01(id)
		assert_true(h >= 0.0 and h < 1.0, "hash01 in [0,1)")


# ------------------------------------------------------- 18 — flush budget

func test_18_dirty_flush_budget_and_order() -> void:
	var m := _model()
	var per_chunk := 125
	for c in 40:
		var chunk := Vector2i(c, 0)
		for i in per_chunk:
			var id := 10000 + c * per_chunk + i
			var pos := Vector3(float(c) * 128.0 + 4.0, 0.0, 4.0)
			m.add_building({"id": id, "archetype_id": &"house", "level": 1,
					"family": "residential", "world_pos": pos, "block_id": c,
					"chunk": chunk, "occ_b": 0.9,
					"transform": Transform3D(Basis.IDENTITY, pos)})
	assert_eq(m.building_count(), 5000, "5000 buildings")
	assert_eq(m.dirty_instance_count(), 5000, "all dirty after the build")

	var cam := Vector3(0.0, 50.0, 0.0)
	var f1 := m.flush_dirty(cam, 2000)
	assert_eq(f1["writes"], 2000, "frame 1 writes the budget")
	assert_eq(m.dirty_instance_count(), 3000, "3000 carried over")
	var f2 := m.flush_dirty(cam, 2000)
	assert_eq(f2["writes"], 2000, "frame 2 writes the budget")
	var f3 := m.flush_dirty(cam, 2000)
	assert_eq(f3["writes"], 1000, "frame 3 drains the remainder")
	assert_eq(m.dirty_instance_count(), 0, "exactly 3 frames to drain 5000 at 2000/frame")

	# flush order is ascending chunk distance
	var chunks: Array = f1["chunks"]
	var prev := -1.0
	for coord in chunks:
		var d := m.chunk_ground_distance(coord, cam)
		assert_true(d >= prev - 1e-6, "chunks drained in ascending distance order")
		prev = d
	assert_eq((chunks[0] as Vector2i).x, 0, "nearest chunk first")
	assert_eq(m.writes_per_frame, 2000, "budget comes from data/render.json")


func test_18b_max_animating_cap() -> void:
	var m := _model()
	m.max_animating = 10
	for i in 30:
		m.add_building(_view(700 + i, Vector3(float(i), 0.0, 0.0), 70))
	m.plan_blackout(70, 0.0)
	assert_eq(m.animating_count(), 30, "all queued before the cap applies")
	m.advance(STEP)
	assert_true(m.animating_count() <= 10, "capped at max_animating_buildings")
	var snapped := 0
	for i in 30:
		var rec := m.building(700 + i)
		if rec.ramp_mode == RenderStateModel.RAMP_IDLE:
			assert_almost_eq(rec.emissive_cur, rec.emissive_target, 1e-6,
					"uncapped remainder snapped to target")
			snapped += 1
	assert_true(snapped >= 20, "the overflow snapped rather than animating")


# ------------------------------------- 24 — cross-file momentary_outage_s floor

func test_24_momentary_outage_floor_against_power_constants() -> void:
	var render := RenderStateModel.load_config()
	var momentary_s := float((render["blackout"] as Dictionary)["momentary_outage_s"])

	var delay_gs := float(PowerGrid.AUTO_RECLOSE_DELAY_GS)
	var attempts := float(PowerGrid.AUTO_RECLOSE_MAX_ATTEMPTS)
	var manual_gm := -1.0
	if FileAccess.file_exists("res://data/power.json"):
		var f := FileAccess.open("res://data/power.json", FileAccess.READ)
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(parsed) == TYPE_DICTIONARY:
			var prot: Dictionary = (parsed as Dictionary).get("protection", {})
			delay_gs = float(prot.get("auto_reclose_delay_gs", delay_gs))
			attempts = float(prot.get("auto_reclose_max_attempts", attempts))
			manual_gm = float(prot.get("manual_reclose_gm", -1.0))

	var floor_s := 1.5 * (delay_gs / 60.0) * attempts
	assert_almost_eq(floor_s, 4.50, 1e-9, "1.5 x (90/60) x 2 = 4.50")
	assert_true(momentary_s >= floor_s - 1e-9,
			"momentary_outage_s %.2f >= derived floor %.2f" % [momentary_s, floor_s])

	# the two populations must not merge: the shortest crew-driven restoration
	# stays at least 1 s above the threshold (§7.3b test 24).
	if manual_gm >= 0.0:
		var crew_s := attempts * (delay_gs / 60.0) + manual_gm
		assert_true(crew_s >= momentary_s + 1.0,
				"crew restoration %.2f >= threshold + 1 s" % crew_s)
	else:
		# data/power.json does not exist yet; assert the reclose population alone
		# still sits strictly below the threshold.
		assert_true(attempts * (delay_gs / 60.0) < momentary_s,
				"the worst self-healing outage is below the momentary threshold")


# ------------------------------------------------------------- 25 — resync

func test_25_resync_snaps_and_suppresses() -> void:
	var m := _model(21.0)
	var ids: Array = []
	for i in 12:
		var id := 900 + i
		m.add_building(_view(id, Vector3(float(i) * 6.0, 0.0, 0.0), 77))
		ids.append(id)
	m.add_streetlight(1000, 77, Vector3(10.0, 0.0, 0.0))

	m.apply_event({"type": &"BlockDarkChanged", "block_id": 77, "block_dark": true,
			"powered_fraction": 0.0})
	m.advance(0.2)
	assert_true(m.queued_plan_count() > 0, "a blackout plan is live")
	m.drain_render_events()

	var snap_buildings: Array = []
	for id in ids:
		snap_buildings.append({"id": id, "powered": true})
	m.apply_snapshot({"is_resync": true, "hour": 21.0, "buildings": snap_buildings,
			"blocks": [{"block_id": 77, "block_dark": false, "powered_fraction": 1.0}]})

	for id in ids:
		var rec := m.building(id)
		assert_almost_eq(rec.emissive_cur, rec.emissive_target, 1e-9,
				"resync snaps on the same frame")
		assert_almost_eq(rec.emissive_delay, 0.0, 1e-9, "no stagger survives a resync")
	assert_eq(m.queued_plan_count(), 0, "every queued plan dropped")
	assert_eq(m.animating_count(), 0, "nothing is animating")
	assert_eq(m.drain_render_events().size(), 0,
			"no relight/blackout events emitted for the resync snapshot")
	assert_almost_eq(m.chunk_power_mult(77), 1.0, 1e-9, "ground back to full")

	# live events after the resync animate normally
	m.blackout_cfg["relight_jitter_s"] = 0.5
	m.apply_event({"type": &"BlockDarkChanged", "block_id": 77, "block_dark": true,
			"powered_fraction": 0.0})
	_advance_to(m, 6.0)
	m.drain_render_events()
	m.apply_event({"type": &"BlockDarkChanged", "block_id": 77, "block_dark": false,
			"powered_fraction": 1.0, "restore_order": ids})
	var events := m.drain_render_events()
	assert_eq(events.size(), 1, "render_relight_started fired")
	assert_eq(events[0]["type"], &"render_relight_started", "event name")
	assert_almost_eq(float(events[0]["duration_s"]), 3.15, 1e-6,
			"the full 3.15 s ceremony is scheduled")
	var last := m.building(ids[ids.size() - 1])
	assert_true(last.emissive_delay > 2.0, "the last-ranked building sweeps late")

	# and the peak event lands at 1.1 s
	_advance_to(m, 1.2)
	var peak_events := m.drain_render_events()
	var found := false
	for e in peak_events:
		if e["type"] == &"render_relight_peak":
			found = true
			assert_true(absf(float(e["t"]) - (float(events[0]["t"]) + 1.1)) < 0.05,
					"peak fires 1.1 s after the sweep starts")
	assert_true(found, "render_relight_peak emitted")


# --------------------------------------------------- events + bucket routing

func test_26_apply_event_building_lifecycle() -> void:
	var m := _model(21.0)
	m.add_building(_view(1, Vector3(8, 0, 8), 5))
	m.apply_event({"type": &"BuildingPowerChanged", "building": 1, "state": &"DARK"})
	assert_false(m.building(1).powered, "DARK clears powered")
	assert_almost_eq(m.building(1).emissive_target, 0.05, 1e-6, "dark target")
	m.apply_event({"type": &"BuildingPowerChanged", "building": 1, "state": &"LIT"})
	assert_true(m.building(1).powered, "LIT restores powered")

	m.apply_event({"type": &"building_damaged", "building": 1, "damage": 0.5})
	assert_almost_eq(m.building(1).damage, 0.5, 1e-6, "damage applied")
	m.apply_event({"type": &"building_construction_stage", "building": 1, "stage": 4})
	assert_eq(m.building(1).stage, 4, "construction stage packed")
	var custom := m.custom_data(1)
	assert_eq(RenderStateModel.unpack_state(custom.b)["stage"], 4, "stage survives packing")

	m.apply_event({"type": &"building_completed", "building": 1, "level": 4})
	assert_eq(m.building(1).level, 4, "level change re-buckets")
	assert_eq(m.building(1).stage, 0, "completed clears the stage")
	assert_true(m.bucket(Vector2i(0, 0), &"apartment", 4) != null, "new bucket exists")
	assert_eq(m.bucket(Vector2i(0, 0), &"apartment", 3).visible_count, 0, "old bucket emptied")

	m.apply_event({"type": &"building_destroyed", "building": 1})
	assert_almost_eq(m.building(1).damage, 1.0, 1e-6, "destroyed is fully damaged")
	assert_eq(m.building(1).overlay_state, RenderStateModel.OVERLAY_OFFLINE, "overlay OFFLINE")

	m.apply_event({"type": &"building_removed", "building": 1})
	assert_eq(m.building_count(), 0, "removed from the model")


func test_27_power_restored_relights_dark_blocks_only() -> void:
	var m := _model()
	m.add_building(_view(1, Vector3(8, 0, 8), 1))
	m.add_building(_view(2, Vector3(200, 0, 8), 2, {"chunk": Vector2i(1, 0)}))
	m.plan_blackout(1, 0.0)
	_advance_to(m, 6.0)
	m.drain_render_events()
	m.apply_event({"type": &"PowerRestored", "restore_order": [], "powered_fraction": 1.0})
	var events := m.drain_render_events()
	assert_eq(events.size(), 1, "only the dark block relights")
	assert_eq(events[0]["block_id"], 1, "the dark block")
	assert_false(m.block(1).dark, "block flag cleared")


# ------------------------- 27 (partial) — consumed event names exist upstream

func _source_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


func test_28_consumed_event_names_exist_on_the_emitter() -> void:
	## §7.3b test 27, scoped to what doc 04's grid emits today. The renamed
	## carrier `BlockDarkChanged` and the streetlight/signal events are not
	## emitted yet (doc 04 exposes block_dark_fractions() but no event), so this
	## asserts the shipped half and keeps the old name out of the renderer.
	var grid := _source_text("res://sim/power/power_grid.gd")
	assert_true(grid.length() > 0, "power grid source is readable")
	for name in ["BuildingPowerChanged", "PowerRestored", "AutoReclosedOK",
			"AutoRecloseLockout", "LoadShedStarted", "LoadShedEnded",
			"RollingBlackoutRotated"]:
		assert_true(grid.contains("&\"%s\"" % name),
				"doc 04 still emits %s" % name)
	var model := _source_text("res://game/render/render_state_model.gd")
	assert_false(model.contains("DistrictDarkChanged"),
			"the renderer subscribes to no event named DistrictDarkChanged (report RR-1)")
	assert_true(model.contains("BlockDarkChanged"), "it subscribes to the renamed carrier")

	# and the renamed carrier is what actually drives the ceremony
	var m := _model()
	m.add_building(_view(1, Vector3(8, 0, 8), 88))
	m.apply_event({"type": &"DistrictDarkChanged", "block_id": 88, "block_dark": true})
	assert_eq(m.queued_plan_count(), 0, "the dead name does nothing")
	m.apply_event({"type": &"BlockDarkChanged", "block_id": 88, "block_dark": true,
			"powered_fraction": 0.0})
	assert_true(m.queued_plan_count() > 0, "the live name plays the blackout")


# ---------------------------------------------- 28 — the streetlight lifecycle

## §2.10.1's open item 1. The model could ADD a streetlight and nothing else, so
## a lamp the player bulldozed kept ramping for the rest of the session and kept
## its id in `BlockRec.streetlights` for the rest of the session's blackouts.
func test_28_a_retired_streetlight_stops_being_ticked() -> void:
	var m := _model()
	m.add_streetlight(500, 7, Vector3(10.0, 0.0, 10.0))
	m.add_streetlight(501, 7, Vector3(18.0, 0.0, 10.0))
	assert_eq(m.streetlight_count(), 2)
	assert_eq(m.block_streetlight_ids(7), [500, 501], "both are on the block roster")

	assert_true(m.remove_streetlight(500), "the lamp retires")
	assert_false(m.remove_streetlight(500), "…once, and an unknown id is a no-op")
	assert_eq(m.streetlight_count(), 1)
	assert_eq(m.block_streetlight_ids(7), [501], "…and leaves the block roster")
	assert_true(m.streetlight(500) == null, "the record is gone")

	# The proof that it stopped being TICKED: darken the block and advance. A
	# retired lamp's record would still ramp if `advance()` could reach it.
	m.apply_event({"type": &"StreetlightsChanged", "block_id": 7, "lit": false})
	_advance_to(m, 2.0)
	assert_almost_eq(m.streetlight_out(501), 0.0, 1e-3, "the live lamp went dark")
	assert_almost_eq(m.streetlight_out(500), 0.0, 1e-9,
			"and the retired one reads zero rather than a stale ramp")


## THE DOUBLE-STUTTER HAZARD the streets branch filed by name. `add_streetlight`
## appended to `BlockRec.streetlights` unconditionally, so re-registering one id
## put it in the block's roster TWICE — and every blackout, relight and stagger
## the block drove then hit that lamp twice in the same frame. A live re-place
## pass re-registers lamps by construction, so this is the defect that would
## have shipped with it.
func test_28b_re_registering_a_streetlight_never_duplicates_it() -> void:
	var m := _model()
	m.add_streetlight(600, 3, Vector3(10.0, 0.0, 10.0))
	var phase := m.streetlight(600).anim_phase
	m.add_streetlight(600, 3, Vector3(10.0, 0.0, 10.0))
	m.add_streetlight(600, 3, Vector3(26.0, 0.0, 10.0))
	assert_eq(m.streetlight_count(), 1, "one id is one lamp")
	assert_eq(m.block_streetlight_ids(3), [600], "…and one roster entry")
	assert_eq(m.streetlight(600).world_pos, Vector3(26.0, 0.0, 10.0),
			"re-registering MOVES the lamp")
	assert_almost_eq(m.streetlight(600).anim_phase, phase, 1e-9,
			"…and keeps its phase, so a road edit does not restart every ramp")

	# Moved to another block: exactly one roster carries it.
	m.add_streetlight(600, 4, Vector3(300.0, 0.0, 10.0))
	assert_eq(m.block_streetlight_ids(3), [], "the old block let it go")
	assert_eq(m.block_streetlight_ids(4), [600], "the new block has it once")
