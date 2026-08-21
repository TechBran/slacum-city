extends SimTest
## STREET LIFE (doc 11 §2.17) — the crook, the dog, the goat, the stash, and the
## furniture that makes them worth tapping.
##
## Seven things are pinned here, and they are the seven that can break:
##
##   1. THE BODIES. Triangle budgets, the joint ceiling the shader declares, and
##      — the one a reviewer would miss — that every joint a MESH uses has a row
##      in the rig table the MATERIAL uploads. A vertex on joint 6 of a body
##      whose table stops at 5 rotates about the origin: the animal draws with a
##      leg through the pavement, and nothing else in the suite would say so.
##   2. THE PAGE. `StreetGlyphAtlas` is a signed distance field built in
##      GDScript at boot, and the seam trap in it is real: `min` of per-cell box
##      distances puts a contour along every internal cell edge and the digits
##      come out striped. `test_the_page_has_no_internal_seams` samples exactly
##      those interiors.
##   3. THE LIFECYCLE. Spawn → a body at the tile. Collected → the marker goes,
##      a burst and a `+$N` take its place, the body leaves, and the record is
##      dropped once both are done. Expired → the same minus the reward, and
##      NO label, because nothing was earned.
##   4. THE WANDER IS DETERMINISTIC. Same id, same elapsed, same pose — through
##      two differently-stepped clocks, which is the shape a save/load and a
##      frame-rate change both take.
##   5. THE KERB. A body on a road tile stands on that tile's FOOTWAY, not in a
##      traffic lane; a body on a lot beside a road stands on the pavement in
##      front of it; with no road probe at all nothing snaps and nothing breaks.
##   6. THE BUDGET. Four MultiMeshes, and the fx pool is big enough for the
##      worst frame the caps allow — every marker, every burst, every label at
##      once — so nothing is ever silently dropped.
##   7. HASH NEUTRALITY. This layer is a pure event CONSUMER, so a full frame of
##      it interleaved into a running sim must leave `state_hash()` bit-
##      identical. If a future change ever makes it read the sim, this goes red.

const RENDER_JSON := "res://data/render.json"
const BODY_SHADER := "res://game/shaders/street_life.gdshader"
const FX_SHADER := "res://game/shaders/street_fx.gdshader"

## Doc 11 §2.17's budgets. A body here is a hero prop at Z0 and a thirty-pixel
## silhouette at Z1, so it is allowed rather more than a car (90) and rather
## less than the plant (520).
const CROOK_TRI_MAX := 260
const DOG_TRI_MAX := 240
const GOAT_TRI_MAX := 280
## Four MultiMeshes: three bodies and one fx buffer.
const DRAW_CALL_MAX := 4

## Doc 11 §2.5's published camera poses, for the marker's angular sizing.
const Z0_M := 18.0
const Z1_M := 86.9
const Z2_M := 420.0
const FOV_DEG := 40.0
const FRAME_H := 1080.0


func _render_data() -> Dictionary:
	return StarterCityLoader.read_json(RENDER_JSON)


func _model() -> StreetLifeModel:
	var doc := _render_data()
	var m := StreetLifeModel.new()
	m.configure(doc.get("street_life", {}), doc.get("road_surface", {}), 8.0)
	return m


## Step the model like a 60 Hz frame loop at 1× speed.
func _step(m: StreetLifeModel, seconds: float,
		camera := Vector3(200.0, 70.0, 200.0)) -> void:
	var frames := int(round(seconds * 60.0))
	for i in maxi(frames, 1):
		m.advance(1.0 / 60.0, 1.0)
		m.refresh(camera)


func _src(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


## Screen pixels a `size_m` billboard covers at `dist_m`, on a 1080-line frame
## with doc 11's 40° vertical FOV.
static func _px(size_m: float, dist_m: float) -> float:
	return size_m / (2.0 * dist_m * tan(deg_to_rad(FOV_DEG) * 0.5)) * FRAME_H


# ---------------------------------------------------------------- 1: bodies

func test_the_bodies_fit_their_triangle_budgets() -> void:
	var crook := StreetLifeMesh.crook()
	var dog := StreetLifeMesh.dog()
	var goat := StreetLifeMesh.goat()
	assert_true(crook.tri_count() > 0, "the crook is not empty")
	assert_true(crook.tri_count() <= CROOK_TRI_MAX,
			"crook %d tris <= %d" % [crook.tri_count(), CROOK_TRI_MAX])
	assert_true(dog.tri_count() <= DOG_TRI_MAX,
			"dog %d tris <= %d" % [dog.tri_count(), DOG_TRI_MAX])
	assert_true(goat.tri_count() <= GOAT_TRI_MAX,
			"goat %d tris <= %d" % [goat.tri_count(), GOAT_TRI_MAX])
	# The whole layer's geometry, for the record the report quotes.
	var total := crook.tri_count() + dog.tri_count() + goat.tri_count()
	assert_true(total <= CROOK_TRI_MAX + DOG_TRI_MAX + GOAT_TRI_MAX,
			"three bodies, %d tris total" % total)


func test_every_joint_a_body_uses_has_a_row_in_its_rig_table() -> void:
	# The defect this catches: a vertex on joint 6 of a body whose pivot table
	# stops at 5 rotates about the WORLD ORIGIN. The animal draws with a leg
	# through the pavement and no other assertion in the suite notices.
	var bodies := [
		{"mesh": StreetLifeMesh.crook(), "pivot": StreetLifeMesh.crook_pivots(),
			"sel": StreetLifeMesh.crook_sel(), "name": "crook"},
		{"mesh": StreetLifeMesh.dog(), "pivot": StreetLifeMesh.dog_rig(),
			"sel": StreetLifeMesh.quadruped_sel(), "name": "dog"},
		{"mesh": StreetLifeMesh.goat(), "pivot": StreetLifeMesh.goat_rig(),
			"sel": StreetLifeMesh.quadruped_sel(), "name": "goat"},
	]
	for row: Dictionary in bodies:
		var mesh: StreetLifeMesh = row["mesh"]
		var pivots: PackedVector4Array = row["pivot"]
		var sel: PackedVector4Array = row["sel"]
		var top := mesh.max_joint()
		assert_true(top >= 1, "%s articulates at all (top joint %d)"
				% [row["name"], top])
		assert_true(top < StreetLifeMesh.JOINT_SLOTS,
				"%s joint %d is inside the shader's %d slots"
				% [row["name"], top, StreetLifeMesh.JOINT_SLOTS])
		assert_eq(pivots.size(), StreetLifeMesh.JOINT_SLOTS,
				"%s pivot table is the shader's array size" % row["name"])
		assert_eq(sel.size(), StreetLifeMesh.JOINT_SLOTS,
				"%s sel table is the shader's array size" % row["name"])
		# Joint 0 is the still body: it must have an all-zero mask or the whole
		# animal swings about its own feet.
		assert_true(sel[0] == Vector4.ZERO,
				"%s joint 0 never moves" % row["name"])
		for j in range(1, top + 1):
			assert_true(sel[j] != Vector4.ZERO,
					"%s joint %d is driven by some channel" % [row["name"], j])
			assert_true(sel[j].w == 0.0,
					"%s joint %d does not drive off the FX channel" % [row["name"], j])


func test_the_quadrupeds_trot_on_diagonals() -> void:
	# A trot is fore-left with hind-right, against fore-right with hind-left.
	# All four legs ride ONE channel and the second diagonal carries gain −1;
	# get the pairing wrong and the animal paces like a camel.
	var sel := StreetLifeMesh.quadruped_sel()
	assert_almost_eq(sel[1].x, sel[2].x, 0.0001, "fore-left and hind-right agree")
	assert_almost_eq(sel[3].x, sel[4].x, 0.0001, "fore-right and hind-left agree")
	assert_almost_eq(sel[1].x, -sel[3].x, 0.0001, "the two diagonals oppose")
	assert_true(absf(sel[1].x) > 0.5, "the legs are actually driven")
	var pivots := StreetLifeMesh.dog_rig()
	assert_true(pivots[1].x > 0.0 and pivots[2].x < 0.0,
			"joint 1 is a FORE leg and joint 2 a HIND one")
	assert_true(pivots[1].z > 0.0 and pivots[2].z < 0.0,
			"and they are on opposite sides — that is what makes it a diagonal")


func test_the_channel_ranges_are_symmetric_so_a_mirror_is_a_mirror() -> void:
	# `gain = −1` is only a true mirror across a range centred on zero. An
	# asymmetric envelope gives a trotting dog a limp.
	var ranges := StreetLifeMesh.channel_ranges()
	var lo: Vector4 = ranges[0]
	var span: Vector4 = ranges[1]
	for i in 3:
		var min_v: float = [lo.x, lo.y, lo.z][i]
		var range_v: float = [span.x, span.y, span.z][i]
		assert_almost_eq(min_v + range_v, -min_v, 0.0001,
				"channel %d is symmetric about zero" % i)
	assert_almost_eq(lo.w, 0.0, 0.0001, "the FX channel starts at 0")
	assert_almost_eq(span.w, 1.0, 0.0001, "and runs to exactly 1")


# ------------------------------------------------------------------ 2: page

func test_the_glyph_page_is_the_size_the_shader_indexes() -> void:
	var page := StreetGlyphAtlas.page()
	assert_true(page != null, "the page builds")
	assert_eq(page.get_width(), StreetGlyphAtlas.CELL_PX_W
			* StreetGlyphAtlas.GLYPH_COUNT, "page width is cells x glyphs")
	assert_eq(page.get_height(), StreetGlyphAtlas.CELL_PX_H, "page height")
	assert_eq(StreetGlyphAtlas.GLYPHS.size(), StreetGlyphAtlas.GLYPH_COUNT,
			"every declared glyph is authored")
	for rows: Array in StreetGlyphAtlas.GLYPHS:
		assert_eq(rows.size(), StreetGlyphAtlas.CELL_H, "7 rows per glyph")
		for row: String in rows:
			assert_eq(row.length(), StreetGlyphAtlas.CELL_W, "5 cells per row")


func test_every_glyph_has_ink_at_the_contour() -> void:
	# A blank cell in the page is a mark that draws as nothing — a `$` marker
	# with no `$` in it. Each glyph must have texels on BOTH sides of the 0.5
	# contour inside its own cell.
	var img := StreetGlyphAtlas.page().get_image()
	for g in StreetGlyphAtlas.GLYPH_COUNT:
		var inside := 0
		var outside := 0
		for py in StreetGlyphAtlas.CELL_PX_H:
			for px in StreetGlyphAtlas.CELL_PX_W:
				var v := img.get_pixel(g * StreetGlyphAtlas.CELL_PX_W + px, py).r
				if v > 0.5:
					inside += 1
				else:
					outside += 1
		assert_true(inside > 8, "glyph %d has a body (%d texels)" % [g, inside])
		assert_true(outside > 8, "glyph %d has a background (%d texels)" % [g, outside])


func test_the_page_has_no_internal_seams() -> void:
	# THE TRAP. The obvious field — `min` over each ink CELL's box distance —
	# reports 0 at the seam between two touching cells, so a contour runs along
	# every internal cell edge and `+` comes out as five separate blocks. The
	# `+` glyph's centre is exactly such a junction: four cells meet there.
	var img := StreetGlyphAtlas.page().get_image()
	var ox := StreetGlyphAtlas.G_PLUS * StreetGlyphAtlas.CELL_PX_W
	var pad := StreetGlyphAtlas.PAD * float(StreetGlyphAtlas.PX_PER_CELL)
	# The centre cell of `+` (cell 2,3) and its four edge-sharing neighbours are
	# all ink; every texel across those seams must read as INSIDE.
	var probes := [Vector2(2.5, 3.5), Vector2(2.5, 3.0), Vector2(2.5, 4.0),
			Vector2(2.0, 3.5), Vector2(3.0, 3.5)]
	for cell: Vector2 in probes:
		var px := int(pad + cell.x * float(StreetGlyphAtlas.PX_PER_CELL))
		var py := int(pad + cell.y * float(StreetGlyphAtlas.PX_PER_CELL))
		var v := img.get_pixel(ox + mini(px, StreetGlyphAtlas.CELL_PX_W - 1),
				mini(py, StreetGlyphAtlas.CELL_PX_H - 1)).r
		assert_true(v > 0.5,
				"`+` is one solid mark at cell %s (field %.3f)" % [cell, v])


func test_rewards_become_the_right_glyph_run() -> void:
	assert_eq(Array(StreetGlyphAtlas.reward_glyphs(120)),
			[StreetGlyphAtlas.G_PLUS, StreetGlyphAtlas.G_CASH, 1, 2, 0],
			"+$120")
	assert_eq(Array(StreetGlyphAtlas.reward_glyphs(0)),
			[StreetGlyphAtlas.G_PLUS, StreetGlyphAtlas.G_CASH, 0], "+$0")
	# Ten thousand and up abbreviates: a nine-glyph banner at Z0 is three car
	# lengths of number lying across the street it was earned on.
	assert_eq(Array(StreetGlyphAtlas.reward_glyphs(12500)),
			[StreetGlyphAtlas.G_PLUS, StreetGlyphAtlas.G_CASH, 1, 2,
			StreetGlyphAtlas.G_K], "+$12k")
	assert_true(StreetGlyphAtlas.reward_glyphs(9999).size() <= 6,
			"no reward makes a label longer than six glyphs")
	assert_true(StreetGlyphAtlas.reward_glyphs(999999).size() <= 6,
			"including a million")


# ------------------------------------------------------------- 3: lifecycle

func test_a_spawn_puts_a_body_on_the_tile() -> void:
	var m := _model()
	m.spawn(41, "crook", Vector2i(30, 44), 120)
	_step(m, 0.05)
	assert_eq(m.body_used[StreetLifeModel.KIND_CROOK], 1, "one crook drawn")
	assert_eq(m.marker_used, 1, "with one marker over him")
	var pose: StreetLifeModel.Pose = m.body_poses[StreetLifeModel.KIND_CROOK][0]
	var centre := Vector3(30.5 * 8.0, 0.0, 44.5 * 8.0)
	var flat := Vector3(pose.origin.x - centre.x, 0.0, pose.origin.z - centre.z)
	assert_true(flat.length() <= m.wander_radius_m + 0.5,
			"he is within the wander radius of his own tile (%.2f m)" % flat.length())
	assert_eq(Array(m.live_ids()), [41], "and the shell can see him")


func test_each_kind_draws_its_own_body_and_the_stash_draws_none() -> void:
	var m := _model()
	m.spawn(1, "crook", Vector2i(10, 10), 50)
	m.spawn(2, "dog", Vector2i(12, 10), 50)
	m.spawn(3, "goat", Vector2i(14, 10), 50)
	m.spawn(4, "valuables", Vector2i(16, 10), 50)
	_step(m, 0.05)
	assert_eq(m.body_used[StreetLifeModel.KIND_CROOK], 1, "a crook")
	assert_eq(m.body_used[StreetLifeModel.KIND_DOG], 1, "a dog")
	assert_eq(m.body_used[StreetLifeModel.KIND_GOAT], 1, "a goat")
	assert_eq(m.body_used[StreetLifeModel.KIND_STASH], 0,
			"a stash is a sparkle, not a fourth MultiMesh")
	assert_eq(m.marker_used, 4, "all four carry a marker")
	# An unknown kind falls through to the stash rather than guessing at a body.
	assert_eq(StreetLifeModel.kind_of("graffiti"), StreetLifeModel.KIND_STASH,
			"an unheard-of kind is a marker, never livestock")
	assert_eq(StreetLifeModel.kind_of("GOAT"), StreetLifeModel.KIND_GOAT,
			"and the names are case-insensitive")


func test_a_collect_bursts_labels_and_takes_the_body_away() -> void:
	var m := _model()
	m.spawn(7, "dog", Vector2i(20, 20), 240)
	_step(m, 0.5)
	assert_eq(m.marker_used, 1, "the marker is up while it is live")
	m.collect(7, 240)
	_step(m, 0.10)
	assert_eq(m.marker_used, 0, "the marker goes the instant it is collected")
	assert_eq(m.burst_used, 1, "a poof takes its place")
	assert_eq(m.label_used, 1, "and a +$N rises off it")
	assert_true(m.body_poses[StreetLifeModel.KIND_DOG][0].custom.a > 0.0,
			"the body is leaving (fx channel is live)")
	assert_almost_eq(m.body_poses[StreetLifeModel.KIND_DOG][0].tint.a, 1.0, 0.0001,
			"and the instance alpha says COLLECT, so the shader flashes it")
	# Six glyphs of `+$240` is five, plus a burst's puffs and its ring.
	assert_true(m.fx_used >= 5, "the label's glyphs are in the buffer")
	_step(m, m.label_s + 0.2)
	assert_eq(m.census()["held"], 0, "and the record is dropped once it is told")
	assert_eq(m.fx_used, 0, "with nothing left in the fx buffer")


func test_an_expiry_deflates_and_pays_nothing() -> void:
	var m := _model()
	m.spawn(8, "goat", Vector2i(20, 22), 300)
	_step(m, 0.5)
	m.expire(8)
	_step(m, 0.10)
	assert_eq(m.marker_used, 0, "the marker goes")
	assert_eq(m.label_used, 0, "and NOTHING was earned, so there is no label")
	assert_eq(m.burst_used, 1, "a smaller, greyer poof still marks the moment")
	var pose: StreetLifeModel.Pose = m.body_poses[StreetLifeModel.KIND_GOAT][0]
	assert_almost_eq(pose.tint.a, 0.0, 0.0001,
			"the instance alpha says EXPIRE, so the shader does not flash it")
	_step(m, m.expire_s + 0.2)
	assert_eq(m.census()["held"], 0, "and it is gone")
	assert_eq(m.body_used[StreetLifeModel.KIND_GOAT], 0, "body and all")


func test_a_collect_on_something_that_already_left_is_ignored() -> void:
	var m := _model()
	m.spawn(9, "crook", Vector2i(20, 24), 100)
	_step(m, 0.2)
	m.expire(9)
	m.collect(9, 999)
	_step(m, 0.10)
	assert_eq(m.label_used, 0, "an expired opportunity cannot be collected after")
	m.collect(404, 999)
	assert_eq(m.census()["held"], 1, "and an unknown id changes nothing")


func test_the_event_feed_reads_the_sims_payload() -> void:
	var m := _model()
	m.feed_events([
		{"type": &"opportunity_spawned", "id": 11, "kind": "crook",
			"tile": Vector2i(33, 41), "reward": 175},
		{"type": &"weather_changed", "state": "rain"},
	])
	_step(m, 0.05)
	assert_eq(m.census()["live"], 1, "the spawn landed and the weather did not")
	m.feed_events([{"type": &"opportunity_collected", "id": 11, "reward": 175}])
	_step(m, 0.05)
	assert_eq(m.label_used, 1, "the collect landed")
	m.feed_events([{"type": &"opportunity_expired", "id": 11}])
	assert_eq(m.census()["live"], 0, "and an expiry after a collect is a no-op")
	# The tile may arrive as any of the three shapes a sim might publish.
	var m2 := _model()
	m2.feed_events([
		{"type": &"opportunity_spawned", "id": 1, "kind": "dog",
			"tile": [12, 13], "reward": 10},
		{"type": &"opportunity_spawned", "id": 2, "kind": "dog",
			"tile": {"x": 14, "y": 15}, "reward": 10},
	])
	_step(m2, 0.05)
	assert_eq(m2.census()["live"], 2, "an array tile and a dictionary tile both read")
	# The ANCHOR, not the body: the body is somewhere on its wander by now, and
	# asserting where a wandering crook happens to be is asserting the gait.
	assert_almost_eq(m2.ops[1].anchor.x, 12.5 * 8.0, 0.0001, "…at the right tile")
	assert_almost_eq(m2.ops[2].anchor.z, 15.5 * 8.0, 0.0001, "…and so is the other")


# ---------------------------------------------------------- 4: the determinism

func test_the_same_id_walks_the_same_path_through_two_clocks() -> void:
	# The shape a save/load takes, and the shape a frame-rate change takes: two
	# runs reaching the same game-minute by different numbers of steps must
	# agree exactly, because the wander is a closed form and not an integration.
	var fast := _model()
	var slow := _model()
	fast.spawn(77, "goat", Vector2i(50, 50), 90)
	slow.spawn(77, "goat", Vector2i(50, 50), 90)
	for i in 120:
		fast.advance(1.0 / 60.0, 1.0)
	for i in 20:
		slow.advance(1.0 / 10.0, 1.0)
	assert_almost_eq(fast.game_minutes(), 2.0, 0.0001, "the 60 Hz clock reached 2.0")
	assert_almost_eq(slow.game_minutes(), 2.0, 0.0001, "and so did the 10 Hz one")
	# Both are asked for the SAME elapsed, which is the claim: the wander is a
	# pure function of `(id, elapsed)`, so nothing about how a clock GOT there
	# can show. (Comparing at the two clocks' own values instead would compare
	# two elapsed times that differ in the last float bit, and a leg boundary
	# landing between them would flip a heading by a whole radian — a real
	# hazard for a test, not for the layer, since a frame is 1/60 of a leg.)
	var a := fast.sample(fast.ops[77], 2.0)
	var b := slow.sample(slow.ops[77], 2.0)
	assert_almost_eq(float(a["pos"].x), float(b["pos"].x), 0.0001, "same x")
	assert_almost_eq(float(a["pos"].z), float(b["pos"].z), 0.0001, "same z")
	assert_almost_eq(float(a["head"]), float(b["head"]), 0.0001, "same heading")
	assert_almost_eq(float(a["limb"]), float(b["limb"]), 0.0001, "same stride")
	assert_almost_eq(float(a["head_t"]), float(b["head_t"]), 0.0001, "same head")
	# And it is defined arbitrarily far ahead, which is what a catch-up needs:
	# there is no accumulator to have drifted over the hours it skipped.
	var far_a := fast.sample(fast.ops[77], 9999.5)
	var far_b := slow.sample(slow.ops[77], 9999.5)
	assert_almost_eq(float(far_a["pos"].x), float(far_b["pos"].x), 0.0001,
			"and at 9,999 game-minutes too")
	# The frame-by-frame walk and a straight JUMP to the same minute agree —
	# which is the save/load case, and the one an integrator would fail. The
	# walked model's clock is pinned to the same 2.0 first, exactly as the view
	# pins it to `GameClock.game_seconds()`: what is being asserted is that no
	# hidden accumulator survived the walk, not that 120 additions of 1/60 land
	# on a float.
	var jumped := _model()
	jumped.spawn(77, "goat", Vector2i(50, 50), 90)
	jumped.set_game_minutes(2.0)
	jumped.refresh(Vector3.INF)
	fast.set_game_minutes(2.0)
	fast.refresh(Vector3.INF)
	assert_almost_eq(jumped.body_world_pos(77).x, fast.body_world_pos(77).x, 0.0001,
			"walked and jumped land on the same slab")
	assert_almost_eq(jumped.body_world_pos(77).z, fast.body_world_pos(77).z, 0.0001,
			"in both axes")


func test_two_ids_walk_different_paths() -> void:
	# Everything is hashed off the id: two crooks on one tile must not pace the
	# same slab in lockstep, or a street with three of them looks like a chorus.
	var m := _model()
	m.spawn(101, "crook", Vector2i(60, 60), 50)
	m.spawn(102, "crook", Vector2i(60, 60), 50)
	var apart := 0.0
	for i in 40:
		m.advance(0.05, 1.0)
		var a := m.sample(m.ops[101], m.game_minutes())
		var b := m.sample(m.ops[102], m.game_minutes())
		apart = maxf(apart, (a["pos"] as Vector3).distance_to(b["pos"]))
	assert_true(apart > 0.6,
			"two crooks on one tile diverge by %.2f m at some point" % apart)
	assert_ne(m.ops[101].move_gm, m.ops[102].move_gm,
			"and their gaits are hashed apart too")


func test_the_wander_stays_inside_its_own_radius() -> void:
	# The player has to be able to look away and come back. A body that drifts
	# is a body they cannot find twice.
	var m := _model()
	m.spawn(55, "dog", Vector2i(70, 70), 50)
	var anchor: Vector3 = m.ops[55].anchor
	var worst := 0.0
	for i in 400:
		m.advance(0.05, 1.0)
		var p: Vector3 = m.sample(m.ops[55], m.game_minutes())["pos"]
		worst = maxf(worst, Vector3(p.x - anchor.x, 0.0, p.z - anchor.z).length())
	assert_true(worst <= m.wander_radius_m + 0.001,
			"never further than %.2f m from the anchor (worst %.2f)"
			% [m.wander_radius_m, worst])
	assert_true(worst > m.wander_radius_m * 0.3,
			"but it does actually move (%.2f m)" % worst)


func test_a_paused_city_is_a_still_city() -> void:
	var m := _model()
	m.spawn(60, "dog", Vector2i(24, 24), 50)
	_step(m, 1.0)
	assert_eq(m.body_used[StreetLifeModel.KIND_DOG], 1,
			"the dog is inside the distance gate, so this is measuring something")
	var before := m.body_world_pos(60)
	for i in 60:
		m.advance(1.0 / 60.0, 0.0)      # gm_per_s = 0: paused
		m.refresh(Vector3(200.0, 70.0, 200.0))
	var after := m.body_world_pos(60)
	assert_almost_eq(before.x, after.x, 0.0001, "the dog did not move while paused")
	assert_almost_eq(before.z, after.z, 0.0001, "in either axis")
	# …but the FX clock did, because a collect is feedback about a tap and not
	# motion in the world.
	m.collect(60, 40)
	for i in 6:
		m.advance(1.0 / 60.0, 0.0)
		m.refresh(Vector3(200.0, 70.0, 200.0))
	assert_eq(m.label_used, 1, "a +$N still rises while the sim is paused")


# ------------------------------------------------------------------ 5: kerbs

func test_a_body_on_a_road_tile_stands_on_the_footway() -> void:
	# A crook loitering in a live traffic lane is a different event.
	var m := _model()
	# A one-tile road running east-west: kerbs on the north and south faces.
	m.set_road_probe(func(t: Vector2i) -> int:
		return TileGrid.ROAD_STREET if t.y == 40 else TileGrid.ROAD_NONE)
	m.spawn(3, "crook", Vector2i(20, 40), 60)
	var op: StreetLifeModel.Op = m.ops[3]
	assert_true(op.snapped, "it snapped to a kerb line")
	assert_almost_eq(op.anchor.y, m.walk_top_m, 0.0001,
			"and stands on top of the kerb, not on the asphalt")
	var centre_z := 40.5 * 8.0
	var out := absf(op.anchor.z - centre_z)
	assert_almost_eq(out, 8.0 * 0.5 - m.walk_width_street_m * 0.5, 0.0001,
			"exactly in the middle of the 1.40 m footway")
	assert_almost_eq(absf(op.along.x), 1.0, 0.0001,
			"and paces ALONG the street, not across it")


func test_a_body_beside_a_road_stands_on_its_pavement() -> void:
	var m := _model()
	m.set_road_probe(func(t: Vector2i) -> int:
		return TileGrid.ROAD_AVENUE if t.x == 31 else TileGrid.ROAD_NONE)
	m.spawn(4, "goat", Vector2i(30, 12), 60)
	var op: StreetLifeModel.Op = m.ops[4]
	assert_true(op.snapped, "the lot next door found the street")
	var centre_x := 30.5 * 8.0
	assert_almost_eq(op.anchor.x - centre_x, 8.0 * 0.5 + m.walk_width_avenue_m * 0.5,
			0.0001, "on the avenue's own 1.05 m footway, across the property line")
	assert_almost_eq(op.anchor.y, m.walk_top_m, 0.0001, "at kerb height")


func test_no_road_probe_is_not_a_crash() -> void:
	# The preview harness has no city. It must still draw.
	var m := _model()
	m.spawn(5, "dog", Vector2i(9, 9), 60)
	_step(m, 0.2)
	var op: StreetLifeModel.Op = m.ops[5]
	assert_false(op.snapped, "nothing snapped")
	assert_almost_eq(op.anchor.y, 0.0, 0.0001, "and it stands on the block")
	assert_eq(m.body_used[StreetLifeModel.KIND_DOG], 1, "and it still draws")


func test_a_snapped_wander_keeps_to_the_pavement() -> void:
	# The kerb ellipse is squashed ACROSS the kerb line. Left circular, a 2.9 m
	# wander round a 1.40 m footway puts the crook in the middle of the road.
	var m := _model()
	m.set_road_probe(func(t: Vector2i) -> int:
		return TileGrid.ROAD_STREET if t.y == 40 else TileGrid.ROAD_NONE)
	m.spawn(6, "crook", Vector2i(20, 40), 60)
	var op: StreetLifeModel.Op = m.ops[6]
	var worst := 0.0
	for i in 400:
		m.advance(0.05, 1.0)
		var p: Vector3 = m.sample(op, m.game_minutes())["pos"]
		worst = maxf(worst, absf(p.z - op.anchor.z))
	var allowed := m.wander_radius_m * m.wander_across
	assert_true(worst <= allowed + 0.001,
			"never more than %.2f m off the kerb line (worst %.2f)" % [allowed, worst])
	assert_true(allowed < 8.0 * 0.5,
			"which is inside the tile, i.e. never in the carriageway")


# ----------------------------------------------------------------- 6: budget

func test_the_layer_costs_four_draw_calls() -> void:
	var view := StreetLifeView.new()
	view.setup(_render_data())
	assert_eq(view.layer_count(), DRAW_CALL_MAX,
			"three bodies and one fx buffer")
	view.feed_events([{"type": &"opportunity_spawned", "id": 1, "kind": "crook",
			"tile": Vector2i(30, 30), "reward": 100}])
	view.refresh(1.0 / 60.0, 0.4, 1.0, -1.0, Vector3(240.0, 70.0, 240.0))
	assert_true(view.active_buffers() <= DRAW_CALL_MAX,
			"and never submits more than it has")
	assert_eq(view.active_buffers(), 2, "one crook and its marker: two buffers")
	var seen: Dictionary = view.census()
	assert_eq(int(seen["mm_crook"]), 1, "one instance in the body buffer")
	assert_true(int(seen["mm_fx"]) >= 1, "and at least the marker in the fx one")
	view.free()


func test_the_fx_pool_survives_the_worst_frame_the_caps_allow() -> void:
	# Every live opportunity collected on the same frame: every marker gone,
	# every burst and every label up at once. Nothing may be silently dropped.
	var m := _model()
	for i in m.max_live:
		m.spawn(i, ["crook", "dog", "goat", "valuables"][i % 4],
				Vector2i(20 + i * 2, 30), 9999)
	_step(m, 0.3)
	assert_eq(m.census()["live"], m.max_live, "the roster is full")
	for i in m.max_live:
		m.collect(i, 9999)
	_step(m, 0.05)
	assert_eq(m.burst_used, m.max_bursts, "bursts run to their own ceiling")
	assert_eq(m.label_used, m.max_labels, "labels too")
	assert_true(m.fx_used <= m.fx_poses.size(),
			"and the pool held them all (%d of %d)" % [m.fx_used, m.fx_poses.size()])
	assert_true(m.fx_poses.size() >= m.max_live * 2
			+ m.max_bursts * (m.puffs_per_burst + 1) + m.max_labels * 8,
			"the pool is sized from the caps, not guessed at")


func test_the_roster_is_capped_and_evicts_the_finished_first() -> void:
	var m := _model()
	for i in m.max_live:
		m.spawn(i, "dog", Vector2i(20 + i, 30), 50)
	m.collect(0, 50)
	m.spawn(999, "goat", Vector2i(60, 60), 50)
	assert_true(m.ops.has(999), "the newest opportunity is never the one dropped")
	assert_false(m.ops.has(0), "the one whose story was already told went instead")
	assert_true(m.ops.size() <= m.max_live, "and the cap holds")


func test_distance_gates_the_bodies_before_the_markers() -> void:
	# A 1.8 m body is six screen pixels at Z2 and not worth a triangle; the
	# MARKER is the thing the player is scrubbing for, so it outlives it.
	var m := _model()
	m.spawn(2, "crook", Vector2i(50, 50), 50)
	var here := Vector3(50.5 * 8.0, 0.0, 50.5 * 8.0)
	m.advance(0.02, 1.0)
	m.refresh(here + Vector3(0.0, m.body_radius_m + 30.0, 0.0))
	assert_eq(m.body_used[StreetLifeModel.KIND_CROOK], 0, "the body is gated out")
	assert_eq(m.marker_used, 1, "the marker is not")
	m.refresh(here + Vector3(0.0, m.visible_radius_m + 30.0, 0.0))
	assert_eq(m.marker_used, 0, "and past the visible radius nothing is drawn")
	assert_eq(m.fx_used, 0, "not even a sparkle")


# --------------------------------------------------------- 7: the marker reads

func test_the_marker_holds_a_screen_size_across_the_zoom_ladder() -> void:
	# THE REQUIREMENT, in numbers: *"a user scrubbing around their town can
	# actually see them"*. The marker takes an ANGULAR size, so it is the same
	# number of screen pixels at Z0 as at Z1, and only the clamps bend that.
	var m := _model()
	var z0 := clampf(m.marker_angular * Z0_M, m.marker_min_m, m.marker_max_m)
	var z1 := clampf(m.marker_angular * Z1_M, m.marker_min_m, m.marker_max_m)
	var z2 := clampf(m.marker_angular * Z2_M, m.marker_min_m, m.marker_max_m)
	assert_true(_px(z1, Z1_M) >= 28.0,
			"Z1 marker is %.0f px tall — legible while scrubbing" % _px(z1, Z1_M))
	assert_true(_px(z0, Z0_M) <= 200.0,
			"Z0 marker is %.0f px — a pin, not a poster" % _px(z0, Z0_M))
	assert_true(_px(z0, Z0_M) >= 40.0, "and still a tap target at Z0")
	assert_true(_px(z2, Z2_M) <= 20.0,
			"Z2 marker is %.0f px — subtle, as the section asks" % _px(z2, Z2_M))
	assert_true(_px(z2, Z2_M) >= 6.0, "but not invisible")


func test_the_marker_position_is_what_the_shell_taps() -> void:
	var m := _model()
	m.spawn(12, "goat", Vector2i(40, 40), 80)
	_step(m, 0.3)
	var marker := m.marker_world_pos(12)
	var body := m.body_world_pos(12)
	assert_true(marker != Vector3.INF, "there is a marker to tap")
	assert_almost_eq(marker.x, body.x, 0.0001, "it is over the body in x")
	assert_almost_eq(marker.z, body.z, 0.0001, "and in z")
	assert_true(marker.y > body.y + StreetLifeMesh.GOAT_TOP_M,
			"and clear of the goat's own horns")
	assert_true(m.marker_radius_m(12) > 0.2, "with a real tap radius")
	m.collect(12, 80)
	_step(m, 0.05)
	assert_eq(m.marker_world_pos(12), Vector3.INF,
			"and nothing to tap once it has been taken")
	assert_eq(m.marker_world_pos(4040), Vector3.INF, "nor for an id we never had")


func test_the_marker_bobs_and_the_pulse_does_not_move_it() -> void:
	# The marker's SIZE is the shell's tap target, so the pulse is a brightness
	# and never a scale. The bob is on the CPU for the same reason: what
	# `marker_world_pos` says is where the thing is drawn.
	var m := _model()
	m.spawn(13, "dog", Vector2i(40, 42), 80)
	var lo := 1e9
	var hi := -1e9
	var sizes: Array[float] = []
	for i in 180:
		m.advance(1.0 / 60.0, 0.0)      # paused: only the FX clock runs
		m.refresh(Vector3(240.0, 70.0, 240.0))
		var p := m.marker_world_pos(13)
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
		sizes.append(m.marker_radius_m(13))
	assert_almost_eq(hi - lo, m.marker_bob_m * 2.0, 0.02,
			"it bobs through the full authored travel")
	for s: float in sizes:
		assert_almost_eq(s, sizes[0], 0.0001, "and never changes size while it does")


func test_the_shaders_keep_this_renderers_rules() -> void:
	var body := _src(BODY_SHADER)
	var fx := _src(FX_SHADER)
	assert_true(body != "" and fx != "", "both shaders are readable")
	# The rig arrays are a CONTRACT with StreetLifeMesh's tables.
	assert_true(body.contains("uniform vec4 rig_pivot[%d];"
			% StreetLifeMesh.JOINT_SLOTS), "the pivot array is the mesh's size")
	assert_true(body.contains("uniform vec4 rig_sel[%d];"
			% StreetLifeMesh.JOINT_SLOTS), "and so is the selector array")
	# `dot(ang, rig_sel[j])` rather than a dynamic index into a vec4 — the mask
	# carries the gain, and no driver has to support dynamic vector indexing.
	assert_true(body.contains("dot(ang, rig_sel[j])"),
			"the channel is selected by a dot product, not a dynamic index")
	# ONE unconditional fetch, the rule the whole renderer keeps. Counted over
	# the CODE, not the file: the header comment explains the rule and would
	# otherwise be counted as a violation of it.
	var code := ""
	for line in fx.split("\n"):
		if not String(line).strip_edges().begins_with("//"):
			code += String(line) + "\n"
	assert_eq(code.count("texture("), 1, "the fx shader fetches exactly once")
	assert_eq(code.count("uniform sampler"), 1, "off exactly one sampler")
	var fetch := code.find("texture(")
	var first_branch := code.find("if (", code.find("void fragment()"))
	assert_true(first_branch < 0 or fetch < first_branch,
			"and the fetch is outside every branch")
	# Faded instances are collapsed in the vertex stage so the rasteriser never
	# sees them — the same gate `lamp.gdshader` uses for its daylight quads.
	assert_true(fx.contains("VERTEX *= step(0.002,"),
			"a faded fx instance costs no fragments")
	assert_true(fx.contains("depth_draw_never"), "and writes no depth")
	assert_true(fx.contains("fog_disabled"),
			"and opts out of fog, which would grey it in daylight")


# ------------------------------------------------------- 8: the hash is sacred

## THE HASH GATE. This layer is a pure event CONSUMER: it takes a drained batch
## and a tile probe and gives back nothing. Nothing here may touch the sim.
##
## The comparison is a clean 6-hour run against the same 6 hours with a full
## frame of this layer — spawns, wanders, collects, expiries and every road
## probe they take — driven at every hour boundary.
func test_a_full_street_life_frame_leaves_the_state_hash_alone() -> void:
	var clean := CitySim.boot_from_files()
	for i in 6:
		clean.advance_hours(1.0)
	var expected := clean.state_hash()

	var live := CitySim.boot_from_files()
	var view := StreetLifeView.new()
	view.setup(_render_data())
	view.set_road_probe(StreetLifeView.road_probe(live.world))
	var tiles: Array = live.roads.graph.road_tiles_sorted()
	assert_true(tiles.size() > 32, "the starter city has streets to stand on")
	var driven := 0
	for i in 6:
		live.advance_hours(1.0)
		for k in 8:
			var t: Vector2i = tiles[(i * 977 + k * 131) % tiles.size()]
			view.feed_events([{"type": &"opportunity_spawned",
					"id": i * 100 + k, "kind": ["crook", "dog", "goat", "cash"][k % 4],
					"tile": t, "reward": 40 + k * 25}])
		for f in 30:
			view.refresh(1.0 / 60.0, 0.5, 1.0,
					float(live.clock.game_seconds()) / 60.0,
					Vector3(float(tiles[0].x) * 8.0, 60.0, float(tiles[0].y) * 8.0))
			driven += 1
		for k2 in 4:
			view.feed_events([{"type": &"opportunity_collected",
					"id": i * 100 + k2, "reward": 40 + k2 * 25}])
			view.feed_events([{"type": &"opportunity_expired",
					"id": i * 100 + k2 + 4}])
	assert_eq(driven, 180, "the probe actually ran")
	assert_eq(live.state_hash(), expected,
			"a street-life frame leaves the simulation bit-identical")
	view.free()


# ------------------------------------------------------- 9: the crook legs it

## THE ORDER OF THE THREE CUES, which is the whole feature. Tap -> the number
## rises AT ONCE and stays where the finger was; the crook RUNS; and only then
## does the poof land, on him, where he was caught.
func test_a_collected_crook_runs_before_he_is_cuffed() -> void:
	var m := _model()
	# A single east-west street: the tile and its E/W neighbours are road, so
	# the body snaps to a kerb and has a line to run down.
	m.set_road_probe(func(tile: Vector2i) -> int:
		return TileGrid.ROAD_STREET if tile.y == 30 else TileGrid.ROAD_NONE)
	m.spawn(5, "crook", Vector2i(30, 30), 240)
	_step(m, 0.4)
	var stood := m.body_world_pos(5)
	m.collect(5, 240)
	var op: StreetLifeModel.Op = m.ops[5]
	assert_true(op.flee_s >= m.flee_s_min and op.flee_s <= m.flee_s_max,
			"the dash is hashed inside the authored range")
	_step(m, op.flee_s * 0.6)
	var running: StreetLifeModel.Pose = m.body_poses[StreetLifeModel.KIND_CROOK][0]
	var ran := Vector2(running.origin.x - stood.x, running.origin.z - stood.z).length()
	assert_true(ran > 0.5, "he has left the spot he was taken on (%.2f m)" % ran)
	assert_almost_eq(running.custom.a, 0.0, 0.0001,
			"and is NOT shrinking yet - the cuff has not landed")
	assert_eq(m.burst_used, 0, "no poof while he is still running")
	assert_eq(m.label_used, 1, "but the +$N is already up, at the tap")
	_step(m, op.flee_s * 0.5 + 0.10)
	assert_eq(m.burst_used, 1, "the poof lands when he is caught")
	assert_true((m.body_poses[StreetLifeModel.KIND_CROOK][0] as StreetLifeModel.Pose)
			.custom.a > 0.0, "and the body is leaving now")


func test_the_crook_runs_along_the_kerb_and_never_across_it() -> void:
	# The street runs east-west, so the flee must be along X. A crook who ran
	# across the kerb would be running into a live traffic lane.
	var m := _model()
	m.set_road_probe(func(tile: Vector2i) -> int:
		return TileGrid.ROAD_STREET if tile.y == 30 else TileGrid.ROAD_NONE)
	var ids := [11, 12, 13, 14]
	for id: int in ids:
		m.spawn(id, "crook", Vector2i(20 + id, 30), 100)
	_step(m, 0.3)
	var signs: Dictionary = {}
	for id2: int in ids:
		m.collect(id2, 100)
		var op: StreetLifeModel.Op = m.ops[id2]
		assert_almost_eq(op.flee_dir.z, 0.0, 0.001,
				"id %d runs along the street, not across it" % id2)
		assert_almost_eq(absf(op.flee_dir.x), 1.0, 0.001, "and at full stride")
		signs[int(signf(op.flee_dir.x))] = true
	assert_eq(signs.size(), 2,
			"four crooks do not all pick the same way out (the sign is hashed)")


func test_an_expiring_crook_does_not_run_and_an_animal_still_bounds() -> void:
	var m := _model()
	m.spawn(21, "crook", Vector2i(30, 30), 100)
	m.spawn(22, "goat", Vector2i(34, 30), 100)
	_step(m, 0.3)
	m.expire(21)
	assert_almost_eq((m.ops[21] as StreetLifeModel.Op).flee_s, 0.0, 0.0001,
			"a crook nobody caught does not run from nobody")
	var goat_at := m.body_world_pos(22)
	m.collect(22, 100)
	assert_almost_eq((m.ops[22] as StreetLifeModel.Op).flee_s, 0.0, 0.0001,
			"and an animal bounds rather than flees")
	_step(m, m.collect_s * 0.5)
	var pose: StreetLifeModel.Pose = m.body_poses[StreetLifeModel.KIND_GOAT][0]
	assert_true(Vector2(pose.origin.x - goat_at.x,
			pose.origin.z - goat_at.z).length() > 0.4, "the goat is bounding away")
	assert_true(pose.custom.a > 0.0, "and shrinking as it goes, from frame one")


# ---------------------------------------------------------- 10: blob shadows

func test_a_blob_shadow_rides_the_fx_buffer_and_costs_no_draw_call() -> void:
	var view := StreetLifeView.new()
	view.setup(_render_data())
	# `balanced` has `vehicle_shadows: false`, so this is the shipping phone
	# case: no real shadow, therefore a blob.
	view.set_preset("balanced", _render_data())
	assert_true(view.model.blob_enabled,
			"blob when real is off - one knob decides both")
	view.feed_events([{"type": &"opportunity_spawned", "id": 1, "kind": "crook",
			"tile": Vector2i(30, 30), "reward": 100}])
	view.refresh(1.0 / 60.0, 0.0, 1.0, -1.0, Vector3(240.0, 20.0, 240.0))
	assert_eq(view.model.blob_used, 1, "one body, one shadow")
	assert_eq(view.active_buffers(), 2,
			"and it is on the fx buffer: still two submitting, not three")
	assert_eq(view.layer_count(), DRAW_CALL_MAX, "and still four buffers in all")
	view.set_preset("high", _render_data())
	assert_false(view.model.blob_enabled,
			"High casts real shadows, so it gets no blob")
	view.refresh(1.0 / 60.0, 0.0, 1.0, -1.0, Vector3(240.0, 20.0, 240.0))
	assert_eq(view.model.blob_used, 0, "and draws none")
	view.free()


func test_the_blob_lies_flat_on_the_ground_the_body_stands_on() -> void:
	var m := _model()
	m.set_blob_shadows(true)
	m.set_road_probe(func(tile: Vector2i) -> int:
		return TileGrid.ROAD_STREET if tile.y == 30 else TileGrid.ROAD_NONE)
	m.spawn(3, "dog", Vector2i(30, 30), 100)
	_step(m, 0.2, Vector3(30.5 * 8.0, 12.0, 31.0 * 8.0))
	assert_eq(m.blob_used, 1, "the dog has a shadow")
	var blob: StreetLifeModel.Pose = _first_fx(m, StreetLifeModel.FX_BLOB)
	assert_true(blob != null, "and it is on the fx buffer as mode 5")
	var op: StreetLifeModel.Op = m.ops[3]
	assert_almost_eq(blob.origin.y, op.anchor.y + m.blob_y_m, 0.0001,
			"it sits just over the ground the body stands on, not over y = 0")
	assert_true(op.anchor.y > 0.2, "which on a kerb is the FOOTWAY, not the road")
	# The quad's own +Y must lie in the ground plane and its +Z point at the
	# sky: that is the -90 degrees about X which turns a billboard into a decal.
	assert_almost_eq((blob.basis * Vector3.UP).y, 0.0, 0.001,
			"the quad is laid flat")
	assert_almost_eq((blob.basis * Vector3.BACK).normalized().y, 1.0, 0.001,
			"facing up")
	assert_almost_eq(blob.tint.a, m.blob_alpha, 0.001,
			"at the authored body alpha")


func test_a_body_in_the_middle_of_a_junction_stands_on_the_asphalt() -> void:
	# Four road neighbours means no kerb anywhere on the tile. Before this the
	# body stood at y = 0, ten centimetres INSIDE the carriageway it was walking
	# on, and its blob shadow was depth-buried under the road it belonged to.
	var m := _model()
	m.set_blob_shadows(true)
	m.set_road_probe(func(_tile: Vector2i) -> int: return TileGrid.ROAD_STREET)
	m.spawn(4, "crook", Vector2i(40, 40), 100)
	var op: StreetLifeModel.Op = m.ops[4]
	assert_false(op.snapped, "there is no kerb to snap to")
	assert_almost_eq(op.anchor.y, m.road_top_m, 0.0001,
			"so it stands on the asphalt top")
	_step(m, 0.2, Vector3(40.5 * 8.0, 12.0, 41.0 * 8.0))
	var blob: StreetLifeModel.Pose = _first_fx(m, StreetLifeModel.FX_BLOB)
	assert_true(blob != null and blob.origin.y > m.road_top_m,
			"and its shadow is over the road, not under it")


func test_the_blob_lets_go_as_a_body_leaves_the_ground() -> void:
	var m := _model()
	m.set_blob_shadows(true)
	m.spawn(6, "goat", Vector2i(30, 34), 100)
	_step(m, 0.3)
	var grounded: StreetLifeModel.Pose = _first_fx(m, StreetLifeModel.FX_BLOB)
	var on_ground: float = grounded.tint.a
	m.collect(6, 100)
	_step(m, m.collect_s * 0.45)
	var airborne: StreetLifeModel.Pose = _first_fx(m, StreetLifeModel.FX_BLOB)
	assert_true(airborne == null or airborne.tint.a < on_ground,
			"a goat mid-bound is not nailed to the pavement by its own shadow")


## The first fx pose carrying this mode code, or null.
func _first_fx(m: StreetLifeModel, mode: float) -> StreetLifeModel.Pose:
	for i in m.fx_used:
		var p: StreetLifeModel.Pose = m.fx_poses[i]
		if absf(p.custom.r - mode) < 0.01:
			return p
	return null


# -------------------------------------------------- 11: born_gm and cold load

func test_a_spawn_carrying_born_gm_anchors_the_wander_to_the_sims_clock() -> void:
	# Two models: one that saw the spawn live, one re-seeding 45 game-minutes
	# later off a save. Same id, same tile, same sim minute -> same pose.
	var live := _model()
	live.set_game_minutes(120.0)
	live.spawn(77, "dog", Vector2i(30, 30), 100)
	live.set_game_minutes(165.0)
	live.refresh(Vector3.INF)
	var live_at := live.body_world_pos(77)

	var loaded := _model()
	loaded.set_game_minutes(165.0)
	loaded.spawn(77, "dog", Vector2i(30, 30), 100, 120.0)
	loaded.refresh(Vector3.INF)
	var loaded_at := loaded.body_world_pos(77)
	assert_almost_eq(loaded_at.x, live_at.x, 0.0001,
			"the re-seeded dog is where the save says, not on its first waypoint")
	assert_almost_eq(loaded_at.z, live_at.z, 0.0001, "in z too")

	# And WITHOUT it the beat restarts, which is the defect the field fixes.
	var naive := _model()
	naive.set_game_minutes(165.0)
	naive.spawn(77, "dog", Vector2i(30, 30), 100)
	naive.refresh(Vector3.INF)
	assert_true(naive.body_world_pos(77).distance_to(live_at) > 0.05,
			"a spawn with no born_gm restarts the wander - the thing it fixes")


func test_seed_roster_replays_the_sims_own_rows() -> void:
	var view := StreetLifeView.new()
	view.setup(_render_data())
	view.set_game_minutes(400.0)
	view.seed_roster([
		{"id": 3, "kind": "petty_crime", "tile_x": 30, "tile_y": 30,
			"reward": 260, "born_gm": 180.0},
		{"id": 4, "kind": "loose_animal", "tile_x": 36, "tile_y": 30,
			"reward": 150, "born_gm": 361.5},
		"not a row",
	])
	view.refresh(1.0 / 60.0, 0.0, 0.0, 400.0, Vector3(240.0, 40.0, 240.0))
	assert_eq(view.live_ids(), [3, 4] as Array[int],
			"both rows are live, ascending, and the junk row was ignored")
	assert_almost_eq((view.model.ops[3] as StreetLifeModel.Op).born_gm, 180.0,
			0.0001, "each body keeps the minute it actually appeared")
	# A row with no `born_gm` (a save written before render q2) is not a crash.
	view.seed_roster([{"id": 9, "kind": "crook", "tile_x": 30, "tile_y": 30,
			"reward": 100}])
	view.refresh(1.0 / 60.0, 0.0, 0.0, 400.0, Vector3(240.0, 40.0, 240.0))
	assert_eq(view.live_ids(), [9] as Array[int], "and it still draws")
	view.free()


func test_the_event_feed_carries_born_gm_through() -> void:
	var m := _model()
	m.set_game_minutes(500.0)
	m.feed_events([{"type": &"opportunity_spawned", "id": 12, "kind": "crook",
			"tile": [30, 30], "reward": 100, "born_gm": 411.25}])
	assert_almost_eq((m.ops[12] as StreetLifeModel.Op).born_gm, 411.25, 0.0001,
			"the payload's spawn minute is the one the wander uses")
	m.feed_events([{"type": &"opportunity_spawned", "id": 13, "kind": "crook",
			"tile": [30, 30], "reward": 100}])
	assert_almost_eq((m.ops[13] as StreetLifeModel.Op).born_gm, 500.0, 0.0001,
			"and a build whose sim predates the field falls back to this clock")
