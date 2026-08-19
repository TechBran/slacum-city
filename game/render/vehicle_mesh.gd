class_name VehicleMesh
extends RefCounted
## Procedural low-poly vehicle bodies — the gray-box language of
## `game/meshes/generated` and `ConstructionSiteView.PropMesh`, one surface and
## one material per body, colour baked per vertex.
##
## Two channels ride the mesh:
##
## * **COLOR** — the part tint. The paint proper arrives as the MultiMesh
##   INSTANCE colour and multiplies into this, so painted panels are authored
##   WHITE and everything else (tyres, glass, trim) is authored dark enough
##   that the paint tint on it never reads as a colour of its own.
## * **UV.y** — the part ROLE, which `game/shaders/vehicle.gdshader` switches
##   on: `0` body, `0.25` headlight, `0.5` taillight, `0.75` lightbar red half,
##   `1.0` lightbar blue half. Light quads take their colour from shader
##   uniforms, so they are immune to the paint and every department can flash
##   its own pair (red/blue for police and medical, amber/amber for utility).
##   The meshes are untextured, so UV is free to carry data.
##
## Winding matches `tools/gen_graybox.gd` and `ConstructionSiteView.PropMesh` —
## Godot's front faces are CLOCKWISE, so each triangle is emitted with its
## geometric cross product pointing AGAINST the outward normal.
##
## LOCAL SPACE: **+X is forward**, Y up, origin on the road surface midway
## between the axles. That matches the sim's heading convention (0 rad = +X),
## so the view's only rotation is a yaw.
##
## Triangle budgets are doc 11 §11's (`data/render.json`): civilian bodies
## ≤ `civ_body_tris_max` (90), emergency ≤ `emergency_body_tris_max` (180).
## `tests/test_vehicle_view.gd` asserts every factory stays inside them.

const ROLE_BODY := 0.0
const ROLE_HEADLIGHT := 0.25
const ROLE_TAILLIGHT := 0.5
const ROLE_BAR_A := 0.75
const ROLE_BAR_B := 1.0

# Shared part tints. Painted panels are WHITE — the instance colour is the
# paint. Everything else is dark enough to survive being multiplied by it.
const PAINT := Color(1.0, 1.0, 1.0)
const TYRE := Color(0.085, 0.085, 0.095)
const GLASS := Color(0.145, 0.175, 0.225)
const TRIM := Color(0.30, 0.32, 0.34)
const DARK := Color(0.115, 0.125, 0.135)
const CHROME := Color(0.62, 0.65, 0.68)

var _verts := PackedVector3Array()
var _norms := PackedVector3Array()
var _cols := PackedColorArray()
var _uvs := PackedVector2Array()
var _idx := PackedInt32Array()


# ------------------------------------------------------------------ builder

func is_empty() -> bool:
	return _idx.is_empty()


func tri_count() -> int:
	return _idx.size() / 3


## Axis-aligned box, `centre` at its middle. 12 triangles.
func add_box(centre: Vector3, size: Vector3, color: Color,
		role: float = ROLE_BODY) -> void:
	var h := size * 0.5
	var x := Vector3(h.x, 0.0, 0.0)
	var y := Vector3(0.0, h.y, 0.0)
	var z := Vector3(0.0, 0.0, h.z)
	_quad(centre + x - y - z, centre + x + y - z, centre + x + y + z,
			centre + x - y + z, Vector3.RIGHT, color, role)
	_quad(centre - x - y + z, centre - x + y + z, centre - x + y - z,
			centre - x - y - z, Vector3.LEFT, color, role)
	_quad(centre - x + y - z, centre - x + y + z, centre + x + y + z,
			centre + x + y - z, Vector3.UP, color, role)
	_quad(centre - x - y + z, centre - x - y - z, centre + x - y - z,
			centre + x - y + z, Vector3.DOWN, color, role)
	_quad(centre - x - y + z, centre + x - y + z, centre + x + y + z,
			centre - x + y + z, Vector3.BACK, color, role)
	_quad(centre + x - y - z, centre - x - y - z, centre - x + y - z,
			centre + x + y - z, Vector3.FORWARD, color, role)


## Four wheels as boxes, mirrored on both axes. 48 triangles — most of a
## civilian body's budget, and worth it: nothing else reads as "vehicle" from
## a 45° city camera the way a wheel line does.
func add_wheels(axle_x: float, half_track: float, radius: float,
		width: float, length_scale: float = 2.0) -> void:
	for sx in [1.0, -1.0]:
		for sz in [1.0, -1.0]:
			add_box(Vector3(sx * axle_x, radius, sz * half_track),
					Vector3(radius * length_scale, radius * 2.0, width), TYRE)


## Flat quad from four corners. 2 triangles — how every light surface is made.
func add_quad(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
		normal: Vector3, color: Color, role: float = ROLE_BODY) -> void:
	_quad(p0, p1, p2, p3, normal, color, role)


## Upright quad on the +X (front) or -X (rear) face at `x`, spanning `z` and
## `y` — headlight and taillight bands.
func add_face_quad(x: float, z_half: float, y0: float, y1: float,
		color: Color, role: float, facing_forward: bool) -> void:
	var n := Vector3.RIGHT if facing_forward else Vector3.LEFT
	_quad(Vector3(x, y0, -z_half), Vector3(x, y1, -z_half),
			Vector3(x, y1, z_half), Vector3(x, y0, z_half), n, color, role)


## Horizontal quad at height `y` spanning [x0,x1] × [z0,z1] — lightbar tops,
## roof panels, side stripes laid flat.
func add_top_quad(y: float, x0: float, x1: float, z0: float, z1: float,
		color: Color, role: float = ROLE_BODY) -> void:
	_quad(Vector3(x0, y, z0), Vector3(x0, y, z1), Vector3(x1, y, z1),
			Vector3(x1, y, z0), Vector3.UP, color, role)


## Vertical quad on both flanks at |z| = `z_half` — lightbar sides (so the bar
## still flashes when the camera drops to its 34° floor) and body stripes.
func add_side_quads(z_half: float, x0: float, x1: float, y0: float, y1: float,
		color: Color, role: float = ROLE_BODY) -> void:
	_quad(Vector3(x0, y0, z_half), Vector3(x1, y0, z_half),
			Vector3(x1, y1, z_half), Vector3(x0, y1, z_half), Vector3.BACK,
			color, role)
	_quad(Vector3(x0, y0, -z_half), Vector3(x1, y0, -z_half),
			Vector3(x1, y1, -z_half), Vector3(x0, y1, -z_half), Vector3.FORWARD,
			color, role)


## A quad with explicit UVs — the headlight ground cone, the one mesh whose UV
## is a real texture coordinate rather than a role code.
func add_quad_uv(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
		normal: Vector3, color: Color, uv0: Vector2, uv1: Vector2,
		uv2: Vector2, uv3: Vector2) -> void:
	var i0 := _push(p0, normal, color, uv0)
	var i1 := _push(p1, normal, color, uv1)
	var i2 := _push(p2, normal, color, uv2)
	var i3 := _push(p3, normal, color, uv3)
	_wind(i0, i1, i2, p0, p1, p2, normal)
	_wind(i0, i2, i3, p0, p2, p3, normal)


func to_mesh(material: Material = null) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if _idx.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _verts
	arrays[Mesh.ARRAY_NORMAL] = _norms
	arrays[Mesh.ARRAY_COLOR] = _cols
	arrays[Mesh.ARRAY_TEX_UV] = _uvs
	arrays[Mesh.ARRAY_INDEX] = _idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if material != null:
		mesh.surface_set_material(0, material)
	return mesh


# ------------------------------------------------------------- the fleet

## Doc 10's three civilian kinds plus the four department bodies the incident
## fleet is drawn with. Every factory returns a fresh builder; the view turns
## them into meshes once at setup.
static func factory(key: String) -> VehicleMesh:
	match key:
		"van": return van()
		"truck": return truck()
		"police": return police()
		"fire": return fire_engine()
		"ambulance": return ambulance()
		"utility": return utility_truck()
		_: return car()


## Front of each body, used to plant the headlight cone at the nose.
static func nose_x(key: String) -> float:
	match key:
		"van", "ambulance": return 2.65
		"truck", "fire", "utility": return 3.40
		"police": return 2.32
		_: return 2.15


# ---- civilian -------------------------------------------------------------

## 84 tris. Three-box saloon. Two rules earn their triangles at this camera:
## the wheels must stand PROUD of the body (below its sill and outside its
## flanks) or the car reads as a bar of soap, and the greenhouse is painted
## with dark glass bands laid on it rather than being one grey block — from a
## 45° camera you are mostly looking at the roof, and a grey roof looks wrong
## on every car in the city at once.
static func car() -> VehicleMesh:
	var m := VehicleMesh.new()
	m.add_wheels(1.36, 0.80, 0.32, 0.28)
	m.add_box(Vector3(0.0, 0.66, 0.0), Vector3(4.30, 0.72, 1.78), PAINT)
	m.add_box(Vector3(-0.20, 1.24, 0.0), Vector3(2.20, 0.44, 1.56), PAINT)
	m.add_side_quads(0.782, -1.28, 0.88, 1.05, 1.38, GLASS)
	# Raked windscreen and backlight — the dark bands that read as a car from
	# above, where the roof is most of what the camera can see.
	m.add_quad(Vector3(0.90, 1.46, -0.72), Vector3(1.42, 1.02, -0.80),
			Vector3(1.42, 1.02, 0.80), Vector3(0.90, 1.46, 0.72),
			Vector3(0.44, 0.52, 0.0).normalized(), GLASS)
	m.add_quad(Vector3(-1.30, 1.46, -0.72), Vector3(-1.82, 1.02, -0.80),
			Vector3(-1.82, 1.02, 0.80), Vector3(-1.30, 1.46, 0.72),
			Vector3(-0.44, 0.52, 0.0).normalized(), GLASS)
	m.add_face_quad(2.152, 0.72, 0.50, 0.76, PAINT, ROLE_HEADLIGHT, true)
	m.add_face_quad(-2.152, 0.72, 0.54, 0.80, PAINT, ROLE_TAILLIGHT, false)
	return m


## 82 tris. Panel van: tall cargo box, stepped nose, raked screen.
static func van() -> VehicleMesh:
	var m := VehicleMesh.new()
	m.add_wheels(1.72, 0.84, 0.36, 0.30)
	m.add_box(Vector3(-0.55, 1.32, 0.0), Vector3(3.90, 1.76, 1.90), PAINT)
	m.add_box(Vector3(1.75, 0.97, 0.0), Vector3(1.80, 1.06, 1.84), PAINT)
	m.add_quad(Vector3(1.42, 1.82, -0.86), Vector3(2.62, 1.06, -0.88),
			Vector3(2.62, 1.06, 0.88), Vector3(1.42, 1.82, 0.86),
			Vector3(0.76, 1.20, 0.0).normalized(), GLASS)
	m.add_side_quads(0.922, 1.02, 2.40, 1.02, 1.40, GLASS)
	m.add_face_quad(2.652, 0.84, 0.56, 0.82, PAINT, ROLE_HEADLIGHT, true)
	m.add_face_quad(-2.502, 0.90, 0.70, 0.98, PAINT, ROLE_TAILLIGHT, false)
	return m


## 82 tris. Rigid box truck: cab forward, cargo body behind, a real gap between
## them so the silhouette is not one long brick.
static func truck() -> VehicleMesh:
	var m := VehicleMesh.new()
	m.add_wheels(2.38, 0.92, 0.44, 0.34)
	m.add_box(Vector3(2.35, 1.60, 0.0), Vector3(2.10, 1.76, 2.06), PAINT)
	m.add_box(Vector3(-1.50, 1.92, 0.0), Vector3(4.40, 1.84, 2.08), PAINT)
	m.add_face_quad(3.402, 0.84, 1.66, 2.28, GLASS, ROLE_BODY, true)
	m.add_side_quads(1.032, 1.55, 3.28, 1.66, 2.22, GLASS)
	m.add_face_quad(3.402, 0.90, 0.80, 1.06, PAINT, ROLE_HEADLIGHT, true)
	m.add_face_quad(-3.702, 0.96, 1.10, 1.36, PAINT, ROLE_TAILLIGHT, false)
	return m


# ---- emergency ------------------------------------------------------------

## 120 tris. Patrol car: saloon body, push bar, roof light bar with a red half
## and a blue half readable from above AND from the camera's 34° pitch floor.
static func police() -> VehicleMesh:
	var m := car()
	m.add_side_quads(0.892, -1.16, 0.86, 0.42, 0.90, DARK)   # door panel
	m.add_box(Vector3(2.26, 0.70, 0.0), Vector3(0.14, 0.68, 1.56), CHROME)
	_lightbar(m, 0.05, 1.52, 0.32, 1.32)
	return m


## 118 tris. Pump: truck body, ladder along the roof, locker line, cab bar.
static func fire_engine() -> VehicleMesh:
	var m := truck()
	m.add_box(Vector3(-1.50, 2.92, 0.0), Vector3(4.60, 0.16, 0.34), CHROME)
	m.add_side_quads(1.052, -3.60, 0.62, 1.16, 1.60, CHROME)  # locker line
	_lightbar(m, 2.35, 2.55, 0.36, 1.62)
	return m


## 106 tris. Ambulance: van body, belt stripe, bar over the cab.
static func ambulance() -> VehicleMesh:
	var m := van()
	m.add_side_quads(0.952, -2.45, 1.20, 0.96, 1.30, Color(0.46, 0.13, 0.11))
	_lightbar(m, 1.70, 1.57, 0.30, 1.36)
	return m


## 118 tris. Service truck: flat rack over the bed, amber beacon bar.
static func utility_truck() -> VehicleMesh:
	var m := truck()
	m.add_box(Vector3(-1.50, 2.90, 0.0), Vector3(4.20, 0.14, 1.94), TRIM)
	m.add_side_quads(1.052, -3.60, 0.62, 1.16, 1.50, Color(0.32, 0.25, 0.10))
	_lightbar(m, 2.35, 2.55, 0.32, 1.58)
	return m


## The bar itself: a dark housing plus four emissive faces — top and outboard
## flank per half — so the flash reads at every camera pitch. 20 tris.
static func _lightbar(m: VehicleMesh, x: float, y: float, half_len: float,
		width: float) -> void:
	var half_w := width * 0.5
	m.add_box(Vector3(x, y, 0.0), Vector3(half_len * 2.0, 0.13, width), DARK)
	var top := y + 0.066
	m.add_top_quad(top, x - half_len, x + half_len, -half_w, 0.0,
			PAINT, ROLE_BAR_A)
	m.add_top_quad(top, x - half_len, x + half_len, 0.0, half_w,
			PAINT, ROLE_BAR_B)
	m.add_quad(Vector3(x - half_len, y - 0.05, -half_w - 0.002),
			Vector3(x + half_len, y - 0.05, -half_w - 0.002),
			Vector3(x + half_len, y + 0.05, -half_w - 0.002),
			Vector3(x - half_len, y + 0.05, -half_w - 0.002),
			Vector3.FORWARD, PAINT, ROLE_BAR_A)
	m.add_quad(Vector3(x - half_len, y - 0.05, half_w + 0.002),
			Vector3(x + half_len, y - 0.05, half_w + 0.002),
			Vector3(x + half_len, y + 0.05, half_w + 0.002),
			Vector3(x - half_len, y + 0.05, half_w + 0.002),
			Vector3.BACK, PAINT, ROLE_BAR_B)


# ---- the headlight ground cone -------------------------------------------

## Doc 11 §2.12's `MM_headlights`: ONE flat additive trapezoid per lit vehicle,
## laid on the road ahead of the nose. UV is a real coordinate here —
## `u` across the beam, `v` along it — so the shader can taper it.
static func headlight_cone(length_m: float, near_half: float,
		far_half: float, y: float) -> ArrayMesh:
	var m := VehicleMesh.new()
	m.add_quad_uv(
			Vector3(0.0, y, -near_half), Vector3(length_m, y, -far_half),
			Vector3(length_m, y, far_half), Vector3(0.0, y, near_half),
			Vector3.UP, Color.WHITE,
			Vector2(0.0, 0.0), Vector2(0.0, 1.0),
			Vector2(1.0, 1.0), Vector2(1.0, 0.0))
	return m.to_mesh()


# ------------------------------------------------------------------ internals

func _push(p: Vector3, n: Vector3, color: Color, uv: Vector2) -> int:
	_verts.push_back(p)
	_norms.push_back(n)
	_cols.push_back(color)
	_uvs.push_back(uv)
	return _verts.size() - 1


func _quad(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: Vector3,
		color: Color, role: float) -> void:
	var uv := Vector2(0.0, role)
	var i0 := _push(p0, n, color, uv)
	var i1 := _push(p1, n, color, uv)
	var i2 := _push(p2, n, color, uv)
	var i3 := _push(p3, n, color, uv)
	_wind(i0, i1, i2, p0, p1, p2, n)
	_wind(i0, i2, i3, p0, p2, p3, n)


func _wind(i0: int, i1: int, i2: int, p0: Vector3, p1: Vector3, p2: Vector3,
		n: Vector3) -> void:
	if (p1 - p0).cross(p2 - p0).dot(n) > 0.0:
		_idx.push_back(i0)
		_idx.push_back(i2)
		_idx.push_back(i1)
	else:
		_idx.push_back(i0)
		_idx.push_back(i1)
		_idx.push_back(i2)
