extends SimTest
## Doc 11 §2.12's vehicle layer, view side: the procedural bodies against the
## triangle budgets in `data/render.json`, the draw-call count against §2.13's
## budget, and `VehicleView`'s ingestion of both feeds — doc 10's cosmetic
## `vehicle_spawned` / `traffic_snapshot` / `vehicle_despawned` stream (doc 91
## D-10's bus diet packed motion into one event per tick) and doc 06's fleet
## snapshot.

const CIV_TRI_MAX := 90       # data/render.json vehicles.civ_body_tris_max
const EMERGENCY_TRI_MAX := 180  # …emergency_body_tris_max
## Doc 11 §2.13's per-frame draw-call line: "vehicles (3 civ MM + 1 headlight
## + ~6 emergency) = 10".
const DRAW_CALL_MAX := 10


func _view() -> VehicleView:
	var view := VehicleView.new()
	view.setup(StarterCityLoader.read_json("res://data/render.json"))
	return view


## Build the packed motion event the sim now publishes, from readable rows.
## The test writes what it means; `TrafficSnapshot` owns the layout.
func _snapshot(rows: Array) -> Dictionary:
	var count := rows.size()
	var ids := PackedInt32Array()
	var edges := PackedInt32Array()
	var kinds := PackedByteArray()
	var flags := PackedByteArray()
	var pose := PackedFloat32Array()
	ids.resize(count)
	edges.resize(count)
	kinds.resize(count)
	flags.resize(count)
	pose.resize(count * TrafficSnapshot.POSE_STRIDE)
	for i in count:
		var row: Dictionary = rows[i]
		ids[i] = int(row.get("id", 0))
		edges[i] = int(row.get("edge_id", -1))
		kinds[i] = TrafficSnapshot.kind_index(String(row.get("kind", "car")))
		flags[i] = (TrafficSnapshot.FLAG_HEADLIGHTS if bool(row.get("headlights", false)) else 0) \
				| (TrafficSnapshot.FLAG_DARK if bool(row.get("dark", false)) else 0)
		var position: Vector3 = row.get("pos", Vector3.ZERO)
		var base := i * TrafficSnapshot.POSE_STRIDE
		pose[base + TrafficSnapshot.POSE_X] = position.x
		pose[base + TrafficSnapshot.POSE_Z] = position.z
		pose[base + TrafficSnapshot.POSE_HEADING] = float(row.get("heading", 0.0))
		pose[base + TrafficSnapshot.POSE_SPEED] = float(row.get("speed", 0.0))
	return TrafficSnapshot.make_vehicle_event(count, ids, edges, kinds, flags, pose)


func _spawn(id: int, kind := "car", pos := Vector3(80.0, 0.0, 80.0),
		heading := 0.0) -> Dictionary:
	return {"type": &"vehicle_spawned", "id": id, "kind": kind,
			"vehicle_class": "civilian", "pos": pos, "heading": heading,
			"speed": 34.0, "edge_id": 7, "siren": false, "lightbar": false,
			"headlights": false}


# ------------------------------------------------------------ mesh budgets

func test_civilian_bodies_fit_the_triangle_budget() -> void:
	for key in ["car", "van", "truck"]:
		var tris := VehicleMesh.factory(key).tri_count()
		assert_true(tris > 0 and tris <= CIV_TRI_MAX,
				"%s body is %d tris, budget %d" % [key, tris, CIV_TRI_MAX])


func test_emergency_bodies_fit_the_triangle_budget() -> void:
	for key in ["police", "fire", "ambulance", "utility"]:
		var tris := VehicleMesh.factory(key).tri_count()
		assert_true(tris > 0 and tris <= EMERGENCY_TRI_MAX,
				"%s body is %d tris, budget %d" % [key, tris, EMERGENCY_TRI_MAX])


## Every department body must actually carry a light bar, or the flashing pass
## has nothing to drive. Roles live in UV.y (the meshes are untextured).
func test_department_bodies_carry_lightbar_roles() -> void:
	for key in ["police", "fire", "ambulance", "utility"]:
		var mesh := VehicleMesh.factory(key).to_mesh()
		var uvs: PackedVector2Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
		var has_a := false
		var has_b := false
		for uv: Vector2 in uvs:
			has_a = has_a or is_equal_approx(uv.y, VehicleMesh.ROLE_BAR_A)
			has_b = has_b or is_equal_approx(uv.y, VehicleMesh.ROLE_BAR_B)
		assert_true(has_a and has_b, "%s has both light-bar halves" % key)


func test_civilian_bodies_carry_head_and_tail_lamp_roles() -> void:
	for key in ["car", "van", "truck"]:
		var mesh := VehicleMesh.factory(key).to_mesh()
		var uvs: PackedVector2Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
		var head := false
		var tail := false
		for uv: Vector2 in uvs:
			head = head or is_equal_approx(uv.y, VehicleMesh.ROLE_HEADLIGHT)
			tail = tail or is_equal_approx(uv.y, VehicleMesh.ROLE_TAILLIGHT)
		assert_true(head and tail, "%s has lamps at both ends" % key)


## Vertex colours are the part tint and the MultiMesh instance colour is the
## paint, so painted panels have to be authored white — otherwise every car in
## the city comes out muddy.
func test_bodies_carry_vertex_colours_for_the_paint_multiply() -> void:
	var arrays := VehicleMesh.car().to_mesh().surface_get_arrays(0)
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	assert_true(colors.size() > 0, "the body ships vertex colours")
	var white := 0
	for c: Color in colors:
		if c.is_equal_approx(VehicleMesh.PAINT):
			white += 1
	assert_true(white > 0, "at least the panels are authored as paint")


func test_bodies_sit_on_the_road_not_in_it() -> void:
	for key in ["car", "van", "truck", "police", "fire", "ambulance", "utility"]:
		var verts: PackedVector3Array = VehicleMesh.factory(key).to_mesh() \
				.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var lowest := 999.0
		for p: Vector3 in verts:
			lowest = minf(lowest, p.y)
		assert_almost_eq(lowest, 0.0, 0.001,
				"%s rests on y=0 so the instance origin is the road surface" % key)


# ------------------------------------------------------------- draw calls

func test_whole_layer_fits_the_draw_call_budget() -> void:
	var view := _view()
	assert_true(view.layer_count() <= DRAW_CALL_MAX,
			"%d draw calls, budget %d" % [view.layer_count(), DRAW_CALL_MAX])
	view.free()


# ------------------------------------------------------- doc 10 civilian feed

func test_spawn_state_despawn_lifecycle() -> void:
	var view := _view()
	view.apply_event(_spawn(4))
	assert_eq(view.vehicle_count(), 1, "a spawn adds one vehicle")
	var v := view.motion(4)
	assert_true(v != null and v.mesh_key == "car", "kind picks the body")
	view.apply_event(_snapshot([{"id": 4, "kind": "car", "edge_id": 7,
			"pos": Vector3(88.0, 0.0, 80.0), "heading": 0.0, "speed": 34.0,
			"headlights": true}]))
	assert_true(view.motion(4).headlights, "the packed flag byte carries headlights")
	assert_eq(view.motion(4).edge_id, 7, "and the edge column lands too")
	view.apply_event({"type": &"vehicle_despawned", "id": 4, "reason": "arrived"})
	assert_false(view.motion(4).alive, "despawn marks it dying…")
	assert_eq(view.vehicle_count(), 1, "…but it is still fading")
	view.refresh(view.fade_s + 0.1, 0.0, 1.0)
	assert_eq(view.vehicle_count(), 0, "and is dropped once faded out")
	view.free()


## Doc 91 D-10: the packed event is also the RESYNC path. `main.gd` rebuilds the
## whole view on save-load, so the first batch after that carries poses for cars
## whose `vehicle_spawned` went to the previous view.
func test_snapshot_row_for_an_unknown_vehicle_seeds_it() -> void:
	var view := _view()
	view.apply_event(_snapshot([
		{"id": 11, "kind": "van", "edge_id": 3, "pos": Vector3(40.0, 0.0, 24.0),
			"heading": 1.5, "speed": 20.0},
		{"id": 12, "kind": "truck", "edge_id": 4, "pos": Vector3(48.0, 0.0, 24.0),
			"heading": 1.5, "speed": 18.0, "headlights": true},
	]))
	assert_eq(view.vehicle_count(), 2, "both rows became vehicles without a spawn event")
	assert_eq(view.motion(11).mesh_key, "van", "the packed kind byte picks the body")
	assert_eq(view.motion(12).mesh_key, "truck")
	assert_false(view.motion(11).headlights)
	assert_true(view.motion(12).headlights, "flags are per row, not per event")
	assert_false(view.motion(12).siren, "civilians carry no siren in the packed format")
	view.free()


## An empty snapshot is not a despawn — the feed simply skips the event when the
## city is asleep, and a stray empty one must not blank the street.
func test_empty_snapshot_changes_nothing() -> void:
	var view := _view()
	view.apply_event(_spawn(9))
	view.apply_event(_snapshot([]))
	assert_eq(view.vehicle_count(), 1)
	assert_true(view.motion(9).alive)
	view.free()


func test_each_kind_lands_on_its_own_body() -> void:
	var view := _view()
	view.apply_event(_spawn(1, "car"))
	view.apply_event(_spawn(2, "van"))
	view.apply_event(_spawn(3, "truck"))
	assert_eq(view.motion(1).mesh_key, "car")
	assert_eq(view.motion(2).mesh_key, "van")
	assert_eq(view.motion(3).mesh_key, "truck")
	view.free()


func test_unknown_events_are_ignored_so_the_shell_can_forward_the_batch() -> void:
	var view := _view()
	view.apply_events([
		{"type": &"BlockDarkChanged", "block_id": "B_00"},
		{"type": &"economy_hour_settled", "net": 12.0},
		_spawn(9),
	])
	assert_eq(view.vehicle_count(), 1, "only the vehicle event was taken")
	view.free()


func test_refresh_moves_traffic_without_any_further_events() -> void:
	var view := _view()
	view.apply_event(_spawn(11, "car", Vector3(80.0, 0.0, 80.0), 0.0))
	var start := view.motion(11).position()
	view.refresh(0.5, 0.0, 1.0)
	var moved := view.motion(11).position().x - start.x
	assert_true(moved > 10.0, "half a game-minute at 34 m/gm moved %f m" % moved)
	view.free()


# ------------------------------------------------------- doc 06 fleet bridge

## Unit ids and civilian ids both start at 1. They must not collide, or a
## police car and a hatchback fight over the same slot.
func test_emergency_keys_never_collide_with_civilian_ids() -> void:
	var view := _view()
	view.apply_event(_spawn(1, "car"))
	view.apply_unit_states([{"id": 1, "type": "police_patrol", "pos": [40, 40],
			"speed": 32.0, "heading": 0.0, "status": "RESPONDING",
			"incident_id": 3, "route_progress": 0.2}])
	assert_eq(view.vehicle_count(), 2, "both are on the road")
	assert_eq(view.motion(1).mesh_key, "car", "civilian id 1 is untouched")
	var unit := view.motion(VehicleView.EMERGENCY_KEY_BASE + 1)
	assert_true(unit != null and unit.mesh_key == "police",
			"unit 1 is drawn as a patrol car")
	view.free()


func test_departments_pick_their_own_body_and_colour() -> void:
	var view := _view()
	view.apply_unit_states([
		{"id": 1, "type": "police_patrol", "pos": [10, 10], "speed": 32.0,
			"heading": 0.0, "status": "RESPONDING"},
		{"id": 2, "type": "fire_engine", "pos": [11, 10], "speed": 26.0,
			"heading": 0.0, "status": "RESPONDING"},
		{"id": 3, "type": "utility_service_truck", "pos": [12, 10], "speed": 24.0,
			"heading": 0.0, "status": "RESPONDING"},
	])
	var base := VehicleView.EMERGENCY_KEY_BASE
	assert_eq(view.motion(base + 1).mesh_key, "police")
	assert_eq(view.motion(base + 2).mesh_key, "fire")
	assert_eq(view.motion(base + 3).mesh_key, "utility")
	assert_eq(view.motion(base + 1).vehicle_class, "police")
	assert_eq(view.motion(base + 2).vehicle_class, "fire")
	assert_ne(view.motion(base + 1).paint, view.motion(base + 2).paint,
			"departments do not share a paint")
	view.free()


## Doc 06 §2.11's FSM in light: only units that are actually out get drawn, a
## responding unit runs siren and bar, an on-scene unit keeps the bar as a
## marker, a returning unit goes quiet.
func test_only_rolling_units_are_drawn_and_their_lights_track_status() -> void:
	var view := _view()
	var base := VehicleView.EMERGENCY_KEY_BASE
	view.apply_unit_states([
		{"id": 1, "type": "police_patrol", "pos": [10, 10], "speed": 32.0,
			"heading": 0.0, "status": "IDLE"},
		{"id": 2, "type": "police_patrol", "pos": [11, 10], "speed": 32.0,
			"heading": 0.0, "status": "RESPONDING"},
		{"id": 3, "type": "fire_engine", "pos": [12, 10], "speed": 0.0,
			"heading": 0.0, "status": "ON_SCENE"},
		{"id": 4, "type": "fire_engine", "pos": [13, 10], "speed": 26.0,
			"heading": 0.0, "status": "RETURNING"},
	])
	assert_eq(view.motion(base + 1), null, "an IDLE unit stays in the station")
	assert_true(view.motion(base + 2).siren, "RESPONDING runs the siren")
	assert_true(view.motion(base + 2).lightbar, "…and the bar")
	assert_false(view.motion(base + 3).siren, "ON_SCENE is parked")
	assert_true(view.motion(base + 3).lightbar, "…but still marks the scene")
	assert_false(view.motion(base + 4).lightbar, "RETURNING goes quiet")
	view.free()


## The fleet publishes TILE positions, so an unchanged pose must not be pushed
## again — re-seeding every frame would pin the dead reckoning at a standstill.
func test_repeated_identical_fleet_snapshots_do_not_stall_the_motion() -> void:
	var view := _view()
	var base := VehicleView.EMERGENCY_KEY_BASE
	var snapshot := [{"id": 5, "type": "police_patrol", "pos": [10, 10],
			"speed": 60.0, "heading": 0.0, "status": "RESPONDING"}]
	view.apply_unit_states(snapshot)
	var start := view.motion(base + 5).position()
	for i in 30:
		view.refresh(1.0 / 30.0, 0.0, 1.0)
		view.apply_unit_states(snapshot)
	var moved := view.motion(base + 5).position().x - start.x
	assert_true(moved > 50.0,
			"a second of unchanged snapshots still rolls the unit: %f m" % moved)
	view.free()


## A unit that goes home leaves the road.
func test_a_unit_that_returns_home_is_retired() -> void:
	var view := _view()
	var base := VehicleView.EMERGENCY_KEY_BASE
	view.apply_unit_states([{"id": 6, "type": "police_patrol", "pos": [10, 10],
			"speed": 32.0, "heading": 0.0, "status": "RETURNING"}])
	assert_true(view.motion(base + 6).alive)
	view.apply_unit_states([{"id": 6, "type": "police_patrol", "pos": [4, 4],
			"speed": 0.0, "heading": 0.0, "status": "IDLE"}])
	assert_false(view.motion(base + 6).alive, "IDLE pulls it off the street")
	view.refresh(view.fade_s + 0.1, 0.0, 1.0)
	assert_eq(view.vehicle_count(), 0)
	view.free()


func test_unit_events_flip_the_lights_without_a_pose() -> void:
	var view := _view()
	var base := VehicleView.EMERGENCY_KEY_BASE
	view.apply_unit_states([{"id": 7, "type": "fire_engine", "pos": [10, 10],
			"speed": 26.0, "heading": 0.0, "status": "RESPONDING"}])
	view.apply_event({"type": &"unit_arrived", "unit_id": 7, "incident_id": 2,
			"role": "suppress"})
	assert_false(view.motion(base + 7).siren, "arrival kills the siren")
	assert_true(view.motion(base + 7).lightbar, "the bar stays up on scene")
	view.apply_event({"type": &"unit_returned", "unit_id": 7, "refit": false})
	assert_false(view.motion(base + 7).lightbar, "going home turns it off")
	view.free()


# ------------------------------------------------------------------- culling

## Doc 11 §2.12's `civ_visible_radius_m` gate. Emergency traffic is deliberately
## kept past it — a unit crossing town is the alive read, not clutter.
func test_distant_civilians_are_culled_but_emergency_units_are_not() -> void:
	var view := _view()
	view.set_focus(Vector3.ZERO)
	view.apply_event(_spawn(21, "car", Vector3(4000.0, 0.0, 0.0)))
	view.apply_unit_states([{"id": 8, "type": "police_patrol", "pos": [60, 0],
			"speed": 32.0, "heading": 0.0, "status": "RESPONDING"}])
	view.refresh(0.5, 1.0, 1.0)
	assert_eq(view.vehicle_count(), 2, "culling never deletes, it only skips")
	assert_true(view.visible_radius > 0.0, "the radius is configured")
	view.free()


func test_clear_empties_the_layer() -> void:
	var view := _view()
	view.apply_event(_spawn(31))
	view.apply_event(_spawn(32, "van"))
	view.clear()
	assert_eq(view.vehicle_count(), 0)
	view.free()


# ------------------------------------------------------- the surface atlas
#
# `tools/gen_textures.py`'s `vehicle_atlas.png`: 2x2 MATERIAL cells addressed by
# UV2 = cell + the face's own inset [0,1] coordinate. The shader derives
# `is_glass` from `floor(UV2)`, so the cell layout, the inset and the page are
# one contract and all three are asserted here.

func _uv2_of(key: String) -> PackedVector2Array:
	return VehicleMesh.factory(key).to_mesh().surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]


func test_every_body_vertex_carries_an_atlas_coordinate() -> void:
	for key in ["car", "van", "truck", "police", "fire", "ambulance", "utility"]:
		var arrays := VehicleMesh.factory(key).to_mesh().surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
		assert_eq(uv2.size(), verts.size(), "%s carries UV2 per vertex" % key)


func test_no_face_ever_leaves_its_atlas_cell() -> void:
	# This is what stops a mip level bleeding the glass gradient into a car door
	# at 200 m. Every UV2 has to sit inside its cell by at least the inset, or
	# `floor(UV2)` also stops being a stable cell index across a face.
	var inset := VehicleMesh.UV_INSET
	for key in ["car", "van", "truck", "police", "fire", "ambulance", "utility"]:
		for uv: Vector2 in _uv2_of(key):
			var frac := Vector2(uv.x - floorf(uv.x), uv.y - floorf(uv.y))
			assert_true(frac.x >= inset - 1e-5 and frac.x <= 1.0 - inset + 1e-5,
					"%s: u %f is outside the %f inset" % [key, uv.x, inset])
			assert_true(frac.y >= inset - 1e-5 and frac.y <= 1.0 - inset + 1e-5,
					"%s: v %f is outside the %f inset" % [key, uv.y, inset])


func test_the_four_cells_land_on_the_parts_they_are_drawn_for() -> void:
	# A civilian car uses paint, glass and rubber and no livery; a patrol car
	# adds the livery band. If the livery cell ever stopped reaching a department
	# body the fleet would silently lose its markings and still pass every other
	# test in this file.
	var seen: Dictionary = {}
	for uv: Vector2 in _uv2_of("car"):
		seen[Vector2(floorf(uv.x), floorf(uv.y))] = true
	assert_true(seen.has(VehicleMesh.CELL_PAINT), "a car is painted")
	assert_true(seen.has(VehicleMesh.CELL_GLASS), "…and glazed")
	assert_true(seen.has(VehicleMesh.CELL_DARK), "…and has tyres")
	assert_false(seen.has(VehicleMesh.CELL_LIVERY), "…and no department livery")
	for key in ["police", "fire", "ambulance", "utility"]:
		var dept: Dictionary = {}
		for uv: Vector2 in _uv2_of(key):
			dept[Vector2(floorf(uv.x), floorf(uv.y))] = true
		assert_true(dept.has(VehicleMesh.CELL_LIVERY),
				"%s wears a livery band" % key)


func test_the_glass_gradient_runs_the_right_way_up() -> void:
	# The glass cell bakes the sky at the top of the page. UV2's v is derived
	# from the FACE's own extent and runs 0 at the top, which is the only reason
	# a raked windscreen and an upright side window both come out with the sky on
	# their upper edge — corner order alone cannot do it, because `add_box` and
	# `add_side_quads` start from different corners.
	var arrays := VehicleMesh.car().to_mesh().surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var top_v := 9.0
	var top_y := -9.0
	var bottom_v := -9.0
	var bottom_y := 9.0
	for i in verts.size():
		if Vector2(floorf(uv2[i].x), floorf(uv2[i].y)) != VehicleMesh.CELL_GLASS:
			continue
		if verts[i].y > top_y:
			top_y = verts[i].y
			top_v = uv2[i].y
		if verts[i].y < bottom_y:
			bottom_y = verts[i].y
			bottom_v = uv2[i].y
	assert_true(top_y > bottom_y, "the car has glass at two heights")
	assert_true(top_v < bottom_v,
			"the highest glass vertex samples v %f, the lowest %f — the sky must "
			% [top_v, bottom_v] + "be on top")


func test_the_shader_still_degrades_to_the_flat_shaded_layer() -> void:
	# A clone with no generated atlas: VehicleView sets tex_mix = 0 and every
	# textured term has to collapse to what the layer shipped with.
	var f := FileAccess.open("res://game/shaders/vehicle.gdshader", FileAccess.READ)
	assert_true(f != null, "shader source readable")
	if f == null:
		return
	var src := f.get_as_text()
	assert_true(src.contains("uniform float tex_mix"), "tex_mix uniform present")
	assert_true(src.contains("mix(vec4(1.0, 1.0, 1.0, 0.0)"),
			"the sample falls back to white with no shine at tex_mix = 0")
	assert_true(src.contains("v_data.r"),
			"the per-vehicle tone rides INSTANCE_CUSTOM.r")
	assert_true(src.contains("float is_glass = step(0.5, cell.x)"),
			"is_glass is derived from the atlas cell, not from a new role")


func test_department_liveries_are_wordless_and_distinct() -> void:
	# Doc 12: no baked text in a texture. The livery cell is VALUE only — the
	# battenburg and the roundel — and the DEPARTMENT is the vertex tint, so
	# these four have to differ or every service vehicle wears the same band.
	var liveries := [VehicleMesh.LIVERY_POLICE, VehicleMesh.LIVERY_FIRE,
			VehicleMesh.LIVERY_MEDICAL, VehicleMesh.LIVERY_UTILITY]
	for i in liveries.size():
		for j in range(i + 1, liveries.size()):
			assert_false((liveries[i] as Color).is_equal_approx(liveries[j]),
					"livery %d and %d are the same colour" % [i, j])
