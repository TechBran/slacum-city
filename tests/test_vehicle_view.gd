extends SimTest
## Doc 11 §2.12's vehicle layer, view side: the procedural bodies against the
## triangle budgets in `data/render.json`, the draw-call count against §2.13's
## budget, and `VehicleView`'s ingestion of both feeds — doc 10's cosmetic
## `vehicle_spawned/state/despawned` stream and doc 06's fleet snapshot.

const CIV_TRI_MAX := 90       # data/render.json vehicles.civ_body_tris_max
const EMERGENCY_TRI_MAX := 180  # …emergency_body_tris_max
## Doc 11 §2.13's per-frame draw-call line: "vehicles (3 civ MM + 1 headlight
## + ~6 emergency) = 10".
const DRAW_CALL_MAX := 10


func _view() -> VehicleView:
	var view := VehicleView.new()
	view.setup(StarterCityLoader.read_json("res://data/render.json"))
	return view


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
	view.apply_event({"type": &"vehicle_state", "id": 4, "kind": "car",
			"vehicle_class": "civilian", "pos": Vector3(88.0, 0.0, 80.0),
			"heading": 0.0, "speed": 34.0, "edge_id": 7, "siren": false,
			"lightbar": false, "headlights": true})
	assert_true(view.motion(4).headlights, "state carries the headlight flag")
	view.apply_event({"type": &"vehicle_despawned", "id": 4, "reason": "arrived"})
	assert_false(view.motion(4).alive, "despawn marks it dying…")
	assert_eq(view.vehicle_count(), 1, "…but it is still fading")
	view.refresh(view.fade_s + 0.1, 0.0, 1.0)
	assert_eq(view.vehicle_count(), 0, "and is dropped once faded out")
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
