class_name ConstructionRigMesh
extends RefCounted
## Procedural bodies for the LIVING CONSTRUCTION layer (doc 11 §2.16): the
## tracked excavator, the rigid tipper (dump truck), and the yard props that
## grow with it — material heaps, bundle stacks and the barricade bay that
## fences the work zone off from the footway.
##
## Same gray-box language as `VehicleMesh` and `ConstructionSiteView.PropMesh`:
## one surface, one material, colour baked per vertex, winding CLOCKWISE (each
## triangle is emitted with its geometric cross product pointing AGAINST the
## outward normal, exactly as `tools/gen_graybox.gd` does).
##
## THREE CHANNELS ride the vertex, and they are what let an articulated machine
## cost ONE draw call:
##
## * **COLOR** — the part tint, multiplied by the MultiMesh instance colour
##   (the machine's paint). Painted panels are authored near-white so the paint
##   IS the colour; steelwork, glass and rubber are authored dark enough that
##   the paint on them never reads as a colour of its own.
##   **The tint constants below are authored as sRGB and converted to LINEAR
##   once, in `_push`** — see `_linear`, which is the only seam in this file.
## * **UV** — the surface coordinate, projected in METRES and divided by
##   `PropSurface.tile_m()`, so a 0.14 m bed rib and a 4.6 m track frame carry
##   the same grain and the same baked AO band pitch as every other prop in the
##   city. Continuous across a box's four flanks, so no seam shows at a corner.
## * **UV2 = (JOINT, SURFACE)** — the two integers `game/shaders/
##   construction_rig.gdshader` switches on.
##   * `UV2.x` is the JOINT this vertex belongs to, 0…4. The shader walks the
##     chain in the vertex stage (see `JOINT_*` below), so boom/arm/bucket
##     articulation is four floats of INSTANCE_CUSTOM rather than four extra
##     MultiMeshes. Joints are strictly nested: a vertex on joint `j` is moved
##     by every rotation from `j` down to 1.
##   * `UV2.y` is the SURFACE code: `SURF_STEEL` (the machine, on the steel
##     page), `SURF_STOCK` (anything that is material rather than machine, on
##     the stock page), `SURF_GLASS` (cab glazing), `SURF_BEACON` (the amber
##     sweep) or `SURF_HEADLAMP` (the lamp lenses). Both pages are fetched
##     unconditionally in the fragment stage and selected by code, so there is
##     no texture read inside divergent control flow.
##
## LOCAL SPACE: **+X is forward**, Y up, origin on the ground under the machine
## — the convention `VehicleMesh` and both sim feeds use (heading 0 = +X), so a
## view's only rotation is a yaw.
##
## The yard props (`pile_heap`, `pile_stack`, `barrier_bay`) carry joint 0 and
## are drawn with plain `PropSurface` materials; they are in this file because
## they share the builder, not because they share the shader.

# ------------------------------------------------------------------- codes

## Kinematic chain. `JOINT_BASE` never moves; every other joint is rotated by
## its own angle AND by every angle below it, which is what makes the cascade
## in the vertex shader a real forward-kinematic chain.
const JOINT_BASE := 0.0
const JOINT_1 := 1.0
const JOINT_2 := 2.0
const JOINT_3 := 3.0
const JOINT_4 := 4.0

const SURF_STEEL := 0.0
const SURF_STOCK := 1.0
const SURF_GLASS := 2.0
## The amber rotating beacon — sweeps day and night, driven by `anim_time` and
## the per-machine hash in the instance colour's alpha.
const SURF_BEACON := 3.0
## Head and tail lamps — steady, driven by the tipper's lamp channel.
const SURF_HEADLAMP := 4.0

# ---- excavator ------------------------------------------------------------

## Slew ring height. The house turns about +Y here; the pivot's XZ is the
## machine centreline, so only the Y term needs saying.
const EXC_SLEW_Y := 1.06
## Boom foot, in house space (= local space, the house pivot being on the axis).
const EXC_BOOM_PIVOT := Vector3(1.35, 1.62, 0.0)
## Boom tip / arm foot, at rest.
const EXC_ARM_PIVOT := Vector3(5.05, 2.52, 0.0)
## Arm tip / bucket pin, at rest.
const EXC_BUCKET_PIVOT := Vector3(6.48, 0.96, 0.0)
## Working envelopes, radians, rest pose = 0. The view normalises an angle into
## 0…1 across these before it writes INSTANCE_CUSTOM, and the shader maps it
## back with the same pair — one source of truth, in GDScript.
const EXC_SLEW_RANGE := Vector2(-1.15, 1.15)
const EXC_BOOM_RANGE := Vector2(-0.30, 0.34)
const EXC_ARM_RANGE := Vector2(-0.46, 0.46)
const EXC_BUCKET_RANGE := Vector2(-0.75, 0.62)
## Rotation axis per joint: 1 = yaw about +Y, 0 = pitch about +Z. Packed as a
## vec4 uniform in joint order 1…4.
const EXC_AXES := Color(1.0, 0.0, 0.0, 0.0)

# ---- dump truck -----------------------------------------------------------

## Tipping hinge, at the rear of the chassis. Positive rotation about +Z lifts
## the front of the bed, which is what a rear-discharge tipper does.
const TIP_HINGE := Vector3(-3.42, 1.02, 0.0)
const TIP_RANGE := Vector2(0.0, 0.92)
## Bed floor, the plane the load is squashed towards as it empties.
const TIP_LOAD_FLOOR_Y := 1.20
const TIP_AXES := Color(0.0, 0.0, 0.0, 0.0)

# ---- shared tints ---------------------------------------------------------
#
# ALL AUTHORED sRGB, ALL CONVERTED ONCE IN `_push` (report 98 RR-95, closing the
# `awaiting_consumer` half of doc 91 `A91-D-36`). A vertex COLOR takes no sRGB
# decode — the same rule that made a MultiMesh instance colour render two stops
# light (RR-91) — so every hex below was being used as if it were already
# linear.
#
# **The CONSTANTS stay sRGB and are NOT converted in place, and that is the
# decision.** Three of them are DUAL-USE: `SAND`, `GRAVEL` and `REBAR` are read
# by `ConstructionActivity._stock_linear` as MultiMesh instance TINTS for the
# yard heaps, where that class already applies `srgb_to_linear()` once at
# `_init`. Converting the constant here would convert them TWICE on that path —
# a heap of gravel at linear 0.049 instead of 0.223, i.e. black — while fixing
# nothing the mesh half needed. Converting at the WRITE instead lets each
# consumer decode once, from one authored source of truth.

## Painted plant panels are authored WHITE: the instance colour is the paint.
## (White is a fixed point of the decode, so this row is the one the conversion
## cannot move — which is why the "panels are the paint" contract survives it.)
const PAINT := Color(1.0, 1.0, 1.0)
const STEEL := Color(0.46, 0.48, 0.50)
## **Re-judged 2026-09-01 against the screenshot pair, `#1D2022` → `#424548`
## (report 98 RR-95).** This is the track frame, the chassis rail, the exhaust
## stack, the grille and the lightbar housing — every dark structural face on
## the layer. Decoded from its authored `0.115` it lands at linear **0.0125**,
## and the shaded carriageway at Z0 sits near **0.02** (report 98 RR-90's
## measurement): the undercarriage stopped being an object standing on the road
## and became a hole cut in it, the whole track band flat black with the grouser
## line gone. That is RR-91's `CIV_PAINT[3]` failure one layer down. `0.260`
## decodes to **0.055** — a genuinely dark part, half the `0.115` it used to
## render at, and 2.7× the road it stands on.
const DARK := Color(0.260, 0.272, 0.284)
## **Re-judged with `DARK`, `#161618` → `#333336`.** Rubber, and the same
## constant as `VehicleMesh.TYRE` because it is the same material on the same
## street; the two are kept identical by hand and `tests/test_construction_living.gd`
## asserts it. Authored `0.085` decodes to **0.0069** — blacker than fresh
## asphalt, which took the tread ribs off the `dark` atlas cell with it (a ±20 %
## value pattern on an invisible value is an invisible pattern). `0.200` decodes
## to **0.033**: still 2.6× darker than the `0.085` it was rendering at, and
## still above the carriageway, so the wheel line survives a night frame.
const TYRE := Color(0.200, 0.200, 0.210)
const GLASS := Color(0.145, 0.175, 0.225)
const CHROME := Color(0.68, 0.70, 0.73)
const GREASE := Color(0.22, 0.20, 0.18)
const AMBER := Color(1.0, 0.62, 0.10)
const RUST := Color(0.42, 0.28, 0.18)
## Yard materials — the three the site consumes, and the barricade's two.
const SAND := Color(0.70, 0.59, 0.38)
const GRAVEL := Color(0.52, 0.51, 0.49)
const REBAR := Color(0.44, 0.40, 0.36)
const TIMBER := Color(0.61, 0.50, 0.34)
const BARRIER_WHITE := Color(0.86, 0.86, 0.84)
const BARRIER_ORANGE := Color(0.91, 0.45, 0.16)
const CONE_ORANGE := Color(0.93, 0.38, 0.10)

var uv_tile_m := 2.0

var _verts := PackedVector3Array()
var _norms := PackedVector3Array()
var _cols := PackedColorArray()
var _uvs := PackedVector2Array()
var _uv2s := PackedVector2Array()
var _idx := PackedInt32Array()


# ------------------------------------------------------------------ builder

func is_empty() -> bool:
	return _idx.is_empty()


func tri_count() -> int:
	return _idx.size() / 3


func vertex_count() -> int:
	return _verts.size()


## Highest joint index any vertex carries — the chain depth the shader has to
## walk for this body.
func max_joint() -> int:
	var top := 0
	for uv2: Vector2 in _uv2s:
		top = maxi(top, int(round(uv2.x)))
	return top


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
	arrays[Mesh.ARRAY_TEX_UV2] = _uv2s
	arrays[Mesh.ARRAY_INDEX] = _idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if material != null:
		mesh.surface_set_material(0, material)
	return mesh


## The local bounding box, for the caller's `custom_aabb` maths.
func bounds() -> AABB:
	if _verts.is_empty():
		return AABB()
	var lo := _verts[0]
	var hi := _verts[0]
	for p: Vector3 in _verts:
		lo = Vector3(minf(lo.x, p.x), minf(lo.y, p.y), minf(lo.z, p.z))
		hi = Vector3(maxf(hi.x, p.x), maxf(hi.y, p.y), maxf(hi.z, p.z))
	return AABB(lo, hi - lo)


## Axis-aligned box. 12 triangles.
func add_box(centre: Vector3, size: Vector3, color: Color, joint: float,
		surf: float = SURF_STEEL) -> void:
	var h := size * 0.5
	var x := Vector3(h.x, 0.0, 0.0)
	var y := Vector3(0.0, h.y, 0.0)
	var z := Vector3(0.0, 0.0, h.z)
	_quad(centre + x - y - z, centre + x + y - z, centre + x + y + z,
			centre + x - y + z, Vector3.RIGHT, color, joint, surf)
	_quad(centre - x - y + z, centre - x + y + z, centre - x + y - z,
			centre - x - y - z, Vector3.LEFT, color, joint, surf)
	_quad(centre - x + y - z, centre - x + y + z, centre + x + y + z,
			centre + x + y - z, Vector3.UP, color, joint, surf)
	_quad(centre - x - y + z, centre - x - y - z, centre + x - y - z,
			centre + x - y + z, Vector3.DOWN, color, joint, surf)
	_quad(centre - x - y + z, centre + x - y + z, centre + x + y + z,
			centre - x + y + z, Vector3.BACK, color, joint, surf)
	_quad(centre + x - y - z, centre - x - y - z, centre - x + y - z,
			centre + x + y - z, Vector3.FORWARD, color, joint, surf)


## Square-section beam between two points — booms, arms, rams, rails, legs.
func add_beam(a: Vector3, b: Vector3, thickness: float, color: Color,
		joint: float, surf: float = SURF_STEEL) -> void:
	add_taper(a, b, thickness, thickness, color, joint, surf)


## The same beam with a different section at each end, which is what makes a
## boom read as a boom rather than as a stick.
func add_taper(a: Vector3, b: Vector3, thick_a: float, thick_b: float,
		color: Color, joint: float, surf: float = SURF_STEEL) -> void:
	var d := b - a
	var length := d.length()
	if length < 0.0001 or thick_a <= 0.0 or thick_b <= 0.0:
		return
	var f := d / length
	var ref := Vector3.UP if absf(f.dot(Vector3.UP)) < 0.985 else Vector3.RIGHT
	var r := f.cross(ref).normalized()
	var u := r.cross(f).normalized()
	var ra := r * (thick_a * 0.5)
	var ua := u * (thick_a * 0.5)
	var rb := r * (thick_b * 0.5)
	var ub := u * (thick_b * 0.5)
	var a0 := a - ra - ua
	var a1 := a + ra - ua
	var a2 := a + ra + ua
	var a3 := a - ra + ua
	var b0 := b - rb - ub
	var b1 := b + rb - ub
	var b2 := b + rb + ub
	var b3 := b - rb + ub
	_quad(a0, a1, b1, b0, -u, color, joint, surf)
	_quad(a1, a2, b2, b1, r, color, joint, surf)
	_quad(a2, a3, b3, b2, u, color, joint, surf)
	_quad(a3, a0, b0, b3, -r, color, joint, surf)
	_quad(a3, a2, a1, a0, -f, color, joint, surf)
	_quad(b0, b1, b2, b3, f, color, joint, surf)


## A CONVEX profile in the XY plane, wound counter-clockwise, extruded along Z.
## The track frames and the tipper's tailgate chamfer are built this way — a
## silhouette with an angle in it costs the same as a box and reads as plant
## rather than as a crate.
func add_extrusion(profile: PackedVector2Array, z0: float, z1: float,
		color: Color, joint: float, surf: float = SURF_STEEL) -> void:
	var n := profile.size()
	if n < 3:
		return
	# Callers mirror props by negating both z bounds; normalise so the caps
	# always face the way this function says they do.
	var back := maxf(z0, z1)
	var front := minf(z0, z1)
	for i in n:
		var a: Vector2 = profile[i]
		var b: Vector2 = profile[(i + 1) % n]
		var e := b - a
		if e.length() < 0.0001:
			continue
		var nrm := Vector3(e.y, -e.x, 0.0).normalized()
		_quad(Vector3(a.x, a.y, front), Vector3(b.x, b.y, front),
				Vector3(b.x, b.y, back), Vector3(a.x, a.y, back), nrm, color, joint, surf)
	var p0 := profile[0]
	for i in range(1, n - 1):
		var pi: Vector2 = profile[i]
		var pj: Vector2 = profile[i + 1]
		_tri(Vector3(p0.x, p0.y, back), Vector3(pi.x, pi.y, back),
				Vector3(pj.x, pj.y, back), Vector3.BACK, color, joint, surf)
		_tri(Vector3(p0.x, p0.y, front), Vector3(pj.x, pj.y, front),
				Vector3(pi.x, pi.y, front), Vector3.FORWARD, color, joint, surf)


## An N-sided heap standing on the ground, radius jittered off `seed_value` so
## a row of stockpiles is a row of DIFFERENT stockpiles. Authored at unit size
## (1 m base, 1 m tall) — the instance transform is what sizes it.
func add_heap(sides: int, seed_value: int, color: Color, joint: float,
		surf: float = SURF_STOCK) -> void:
	var n := maxi(5, sides)
	var apex := Vector3(0.0, 1.0, 0.0)
	var ring: Array[Vector3] = []
	for i in n:
		var t := TAU * float(i) / float(n)
		var jitter := 0.80 + 0.34 * _hash01(seed_value, i * 7 + 3)
		ring.append(Vector3(cos(t) * 0.5 * jitter, 0.0, sin(t) * 0.5 * jitter))
	# A rounded shoulder rather than a cone point: heaps slump.
	var shoulder: Array[Vector3] = []
	for i in n:
		shoulder.append(Vector3(ring[i].x * 0.44, 0.62, ring[i].z * 0.44))
	# Normals are taken from the heap's own radial direction rather than from a
	# cross product: a slumped skirt is not planar, and the radial normal is
	# both correct enough and immune to the winding of the ring.
	for i in n:
		var j := (i + 1) % n
		var mid := (ring[i] + ring[j]) * 0.5
		var out := Vector3(mid.x, 0.0, mid.z).normalized()
		_quad(ring[i], ring[j], shoulder[j], shoulder[i],
				(out + Vector3.UP * 0.55).normalized(), color, joint, surf)
		var top_mid := (shoulder[i] + shoulder[j]) * 0.5
		var top_out := Vector3(top_mid.x, 0.0, top_mid.z).normalized()
		_tri(shoulder[i], shoulder[j], apex,
				(top_out + Vector3.UP * 1.8).normalized(), color, joint, surf)


# ------------------------------------------------------------- the machines

## The tracked hydraulic excavator — 440 tris, five joints. Rest pose has the
## boom part-raised and the bucket level, so a machine with no animation driven
## into it still looks parked rather than folded.
static func excavator() -> ConstructionRigMesh:
	var m := ConstructionRigMesh.new()

	# ---- joint 0: undercarriage ---------------------------------------
	# Track frames as an extruded hexagon: flat run on the ground, both ends
	# ramped. That single angle is the whole difference between "plant" and
	# "box on wheels" at the city camera.
	var track := PackedVector2Array([
		Vector2(-2.30, 0.16), Vector2(-1.86, 0.00), Vector2(1.86, 0.00),
		Vector2(2.30, 0.16), Vector2(2.30, 0.78), Vector2(-2.30, 0.78)])
	for sz: float in [1.0, -1.0]:
		var z := sz * 1.14
		m.add_extrusion(track, z - 0.27, z + 0.27, DARK, JOINT_BASE)
		# Idler and sprocket, proud of the frame at each end.
		m.add_box(Vector3(2.04, 0.40, z), Vector3(0.46, 0.62, 0.60), GREASE, JOINT_BASE)
		m.add_box(Vector3(-2.04, 0.40, z), Vector3(0.46, 0.62, 0.60), GREASE, JOINT_BASE)
		# Grouser band: one plate reading the tread line along the ground run.
		m.add_box(Vector3(0.0, 0.07, z), Vector3(3.90, 0.14, 0.64), STEEL, JOINT_BASE)
	# Car body and slew ring between the tracks.
	m.add_box(Vector3(0.0, 0.72, 0.0), Vector3(3.30, 0.46, 1.70), STEEL, JOINT_BASE)
	m.add_box(Vector3(0.0, 0.99, 0.0), Vector3(1.90, 0.16, 1.90), GREASE, JOINT_BASE)
	# Dozer blade at the front — small machines carry one and it fills the
	# silhouette where the tracks would otherwise just stop.
	m.add_extrusion(PackedVector2Array([
			Vector2(2.28, 0.02), Vector2(2.68, 0.02), Vector2(2.68, 0.56),
			Vector2(2.28, 0.70)]), -1.42, 1.42, PAINT, JOINT_BASE)

	# ---- joint 1: house (slews about +Y at EXC_SLEW_Y) -----------------
	# Counterweight: a chamfered slab, the mass that makes a machine read heavy.
	m.add_extrusion(PackedVector2Array([
			Vector2(-2.62, 1.18), Vector2(-1.05, 1.10), Vector2(-1.05, 2.42),
			Vector2(-2.40, 2.42), Vector2(-2.62, 2.10)]), -1.18, 1.18, PAINT, JOINT_1)
	# Engine deck, exhaust stack and the walkway rail.
	m.add_box(Vector3(-0.25, 1.66, -0.02), Vector3(1.90, 0.98, 2.24), PAINT, JOINT_1)
	m.add_box(Vector3(-0.55, 2.28, -0.72), Vector3(0.22, 0.32, 0.22), DARK, JOINT_1)
	m.add_beam(Vector3(0.62, 2.16, 1.06), Vector3(-1.02, 2.16, 1.06), 0.07,
			CHROME, JOINT_1)
	m.add_beam(Vector3(0.62, 2.16, -1.06), Vector3(-1.02, 2.16, -1.06), 0.07,
			CHROME, JOINT_1)
	# Cab, offset to the left of the boom the way a real machine puts it, with
	# glazing on the two faces the city camera ever sees.
	m.add_box(Vector3(0.86, 1.90, 0.66), Vector3(1.46, 1.64, 1.20), PAINT, JOINT_1)
	m.add_box(Vector3(1.60, 1.92, 0.66), Vector3(0.06, 1.30, 1.06), GLASS,
			JOINT_1, SURF_GLASS)
	m.add_box(Vector3(0.86, 1.98, 1.29), Vector3(1.22, 1.10, 0.06), GLASS,
			JOINT_1, SURF_GLASS)
	# Amber beacon on the cab roof.
	m.add_box(Vector3(0.34, 2.80, 0.66), Vector3(0.20, 0.24, 0.20), AMBER,
			JOINT_1, SURF_BEACON)
	# Boom foot bracket.
	m.add_box(Vector3(1.30, 1.62, -0.30), Vector3(0.74, 0.86, 0.92), STEEL, JOINT_1)
	# Boom ram: body on the house, so it swings with the machine.
	m.add_taper(Vector3(1.05, 1.34, -0.30), Vector3(2.62, 2.16, -0.30), 0.30, 0.24,
			STEEL, JOINT_1)

	# ---- joint 2: boom (pitches about +Z at EXC_BOOM_PIVOT) ------------
	var knee := Vector3(3.30, 3.44, 0.0)
	m.add_taper(EXC_BOOM_PIVOT, knee, 0.62, 0.50, PAINT, JOINT_2)
	m.add_taper(knee, EXC_ARM_PIVOT, 0.50, 0.40, PAINT, JOINT_2)
	# Arm ram, mounted on the boom's back — the give-away that this is a
	# hydraulic machine and not a crane.
	m.add_taper(Vector3(2.55, 3.10, 0.0), Vector3(4.32, 3.06, 0.0), 0.26, 0.21,
			STEEL, JOINT_2)

	# ---- joint 3: arm / dipper ----------------------------------------
	m.add_taper(EXC_ARM_PIVOT, EXC_BUCKET_PIVOT, 0.44, 0.30, PAINT, JOINT_3)
	# Bucket ram and its link, so the wrist is not a bare pin.
	m.add_taper(Vector3(5.24, 2.86, 0.0), Vector3(6.14, 1.44, 0.0), 0.20, 0.16,
			STEEL, JOINT_3)
	m.add_beam(Vector3(6.14, 1.44, 0.0), Vector3(6.36, 1.16, 0.0), 0.12,
			CHROME, JOINT_3)

	# ---- joint 4: bucket ----------------------------------------------
	# An open scoop: back plate, floor, two cheeks, three teeth.
	var b := EXC_BUCKET_PIVOT
	m.add_box(b + Vector3(0.06, -0.42, 0.0), Vector3(0.14, 0.86, 1.10), STEEL, JOINT_4)
	m.add_box(b + Vector3(0.48, -0.80, 0.0), Vector3(0.94, 0.13, 1.10), STEEL, JOINT_4)
	for sz2: float in [1.0, -1.0]:
		m.add_extrusion(PackedVector2Array([
				Vector2(b.x - 0.02, b.y - 0.86), Vector2(b.x + 0.96, b.y - 0.86),
				Vector2(b.x + 0.96, b.y - 0.62), Vector2(b.x - 0.02, b.y + 0.02)]),
				sz2 * 0.49, sz2 * 0.55, STEEL, JOINT_4)
	for i in 3:
		var tz := (float(i) - 1.0) * 0.34
		m.add_taper(b + Vector3(0.94, -0.80, tz), b + Vector3(1.18, -0.86, tz),
				0.16, 0.09, CHROME, JOINT_4)
	return m


## The rigid tipper — 432 tris, two joints plus the load carrier. Six wheels,
## a real gap between cab and body, and a bed that hinges at the rear.
static func dump_truck() -> ConstructionRigMesh:
	var m := ConstructionRigMesh.new()

	# ---- joint 0: chassis, cab, wheels ---------------------------------
	# Steer axle forward, tandem drive at the rear: the wheel line is what says
	# "heavy" before any other detail lands.
	for sz: float in [1.0, -1.0]:
		var z := sz * 1.06
		m.add_box(Vector3(2.42, 0.52, z), Vector3(1.08, 1.04, 0.34), TYRE, JOINT_BASE)
		m.add_box(Vector3(-1.86, 0.54, z), Vector3(1.12, 1.08, 0.36), TYRE, JOINT_BASE)
		m.add_box(Vector3(-3.06, 0.54, z), Vector3(1.12, 1.08, 0.36), TYRE, JOINT_BASE)
	m.add_box(Vector3(-0.30, 0.90, 0.0), Vector3(7.10, 0.30, 1.86), DARK, JOINT_BASE)
	# Cab: stepped nose, raked screen, a working mirror line.
	m.add_box(Vector3(2.62, 1.78, 0.0), Vector3(2.02, 1.56, 2.32), PAINT, JOINT_BASE)
	m.add_box(Vector3(3.58, 1.10, 0.0), Vector3(0.36, 0.92, 2.30), PAINT, JOINT_BASE)
	m.add_box(Vector3(3.66, 2.02, 0.0), Vector3(0.10, 0.94, 2.18), GLASS,
			JOINT_BASE, SURF_GLASS)
	m.add_box(Vector3(2.60, 2.06, 1.17), Vector3(1.36, 0.86, 0.06), GLASS,
			JOINT_BASE, SURF_GLASS)
	m.add_box(Vector3(2.60, 2.06, -1.17), Vector3(1.36, 0.86, 0.06), GLASS,
			JOINT_BASE, SURF_GLASS)
	# Grille, bumper and the headlamp pair.
	m.add_box(Vector3(3.74, 1.28, 0.0), Vector3(0.10, 0.52, 1.92), DARK, JOINT_BASE)
	m.add_box(Vector3(3.80, 0.68, 0.0), Vector3(0.22, 0.34, 2.34), STEEL, JOINT_BASE)
	for sz3: float in [1.0, -1.0]:
		m.add_box(Vector3(3.78, 1.02, sz3 * 0.88), Vector3(0.10, 0.26, 0.42),
				Color.WHITE, JOINT_BASE, SURF_HEADLAMP)
	# Tail lamps, on the same channel as the heads: a truck reversing towards a
	# tip point at 03:00 is the one place this layer is read at all after dark.
	for sz5: float in [1.0, -1.0]:
		m.add_box(Vector3(-3.72, 1.18, sz5 * 0.92), Vector3(0.09, 0.30, 0.36),
				Color.WHITE, JOINT_BASE, SURF_HEADLAMP)
	# Cab-roof beacon bar and the exhaust stack behind the cab.
	m.add_box(Vector3(2.62, 2.62, 0.0), Vector3(0.34, 0.16, 1.24), AMBER,
			JOINT_BASE, SURF_BEACON)
	m.add_beam(Vector3(1.48, 1.06, 1.02), Vector3(1.48, 2.86, 1.02), 0.15,
			CHROME, JOINT_BASE)
	# Tipping ram, folded under the bed's front edge.
	m.add_taper(Vector3(-2.90, 1.02, 0.0), Vector3(-1.30, 1.30, 0.0), 0.26, 0.19,
			CHROME, JOINT_BASE)

	# ---- joint 1: the bed (hinges about +Z at TIP_HINGE) ---------------
	m.add_box(Vector3(-0.62, 1.13, 0.0), Vector3(5.62, 0.14, 2.34), STEEL, JOINT_1)
	for sz4: float in [1.0, -1.0]:
		var zw := sz4 * 1.17
		m.add_box(Vector3(-0.62, 1.68, zw), Vector3(5.62, 0.98, 0.12), PAINT, JOINT_1)
		for i in 4:
			var rx := -3.00 + float(i) * 1.58
			m.add_box(Vector3(rx, 1.68, zw + sz4 * 0.08),
					Vector3(0.13, 0.98, 0.06), STEEL, JOINT_1)
	# Headboard, raised into a cab guard, and the tailgate.
	m.add_box(Vector3(2.16, 1.86, 0.0), Vector3(0.16, 1.34, 2.34), PAINT, JOINT_1)
	m.add_box(Vector3(2.16, 2.62, 0.0), Vector3(0.12, 0.42, 2.10), STEEL, JOINT_1)
	m.add_box(Vector3(-3.36, 1.66, 0.0), Vector3(0.14, 0.94, 2.34), PAINT, JOINT_1)

	# ---- joint 2: the load (rides the bed, squashed by the fill) -------
	# Authored FULL; `TIP_LOAD_FLOOR_Y` is the plane the shader squashes it to
	# as the fill drops, so an empty truck draws the same triangles flat on the
	# bed floor instead of needing a second body.
	m.add_extrusion(PackedVector2Array([
			Vector2(-3.20, TIP_LOAD_FLOOR_Y), Vector2(1.96, TIP_LOAD_FLOOR_Y),
			Vector2(1.42, TIP_LOAD_FLOOR_Y + 0.74),
			Vector2(-2.64, TIP_LOAD_FLOOR_Y + 0.74)]),
			-1.06, 1.06, GRAVEL, JOINT_2, SURF_STOCK)
	return m


# --------------------------------------------------------------- yard props

## One material heap, unit-sized (1 m × 1 m base, 1 m tall, base on Y = 0) so
## the instance transform is the whole of its size and its colour is the whole
## of which material it is. `variant` only reshuffles the skirt.
static func pile_heap(variant: int = 0) -> ConstructionRigMesh:
	var m := ConstructionRigMesh.new()
	m.add_heap(9, 101 + variant * 37, Color.WHITE, JOINT_BASE, SURF_STOCK)
	return m


## Bundled stock — rebar, section steel, banded timber. Unit-sized like the
## heap; three courses so the stack reads as SOMETHING COUNTED rather than as a
## slab, which is what separates a delivery from a lump of ground.
static func pile_stack() -> ConstructionRigMesh:
	var m := ConstructionRigMesh.new()
	var courses := [
		{"y": 0.14, "w": 1.00, "d": 1.00, "c": Color.WHITE},
		{"y": 0.44, "w": 0.82, "d": 0.86, "c": Color(0.88, 0.88, 0.88)},
		{"y": 0.72, "w": 0.54, "d": 0.70, "c": Color(0.78, 0.78, 0.78)},
	]
	for row: Dictionary in courses:
		var y := float(row["y"])
		var w := float(row["w"])
		var d := float(row["d"])
		m.add_box(Vector3(0.0, y, 0.0), Vector3(w, 0.26, d), row["c"],
				JOINT_BASE, SURF_STOCK)
		# Two banding straps per course.
		for sx: float in [1.0, -1.0]:
			m.add_box(Vector3(sx * w * 0.28, y, 0.0), Vector3(0.05, 0.29, d + 0.02),
					Color(0.42, 0.42, 0.44), JOINT_BASE, SURF_STEEL)
	return m


## One bay of the work-zone fence: an A-frame barricade with two reflective
## rails and a traffic cone standing off each end. 2.4 m of footway, authored
## about the origin with +X along the run.
static func barrier_bay() -> ConstructionRigMesh:
	var m := ConstructionRigMesh.new()
	var half := 1.06
	for sx: float in [1.0, -1.0]:
		# A-frame legs, splayed so the bay stands up on its own.
		m.add_beam(Vector3(sx * half, 0.0, 0.30), Vector3(sx * half, 0.98, 0.0),
				0.07, BARRIER_WHITE, JOINT_BASE)
		m.add_beam(Vector3(sx * half, 0.0, -0.30), Vector3(sx * half, 0.98, 0.0),
				0.07, BARRIER_WHITE, JOINT_BASE)
	# Two rails, banded by alternating the vertex colour along the run.
	for level in 2:
		var y := 0.56 + float(level) * 0.36
		for i in 4:
			var x0 := lerpf(-half, half, float(i) / 4.0)
			var x1 := lerpf(-half, half, float(i + 1) / 4.0)
			var band := (i + level) % 2 == 0
			m.add_box(Vector3((x0 + x1) * 0.5, y, 0.0),
					Vector3(x1 - x0, 0.17, 0.06),
					BARRIER_ORANGE if band else BARRIER_WHITE, JOINT_BASE)
	# A cone off each end: square base plus a tapered body with a white sleeve.
	for sx2: float in [1.0, -1.0]:
		var c := Vector3(sx2 * (half + 0.44), 0.0, 0.0)
		m.add_box(c + Vector3(0.0, 0.03, 0.0), Vector3(0.40, 0.06, 0.40),
				CONE_ORANGE, JOINT_BASE)
		m.add_taper(c + Vector3(0.0, 0.05, 0.0), c + Vector3(0.0, 0.36, 0.0),
				0.26, 0.15, CONE_ORANGE, JOINT_BASE)
		m.add_taper(c + Vector3(0.0, 0.36, 0.0), c + Vector3(0.0, 0.50, 0.0),
				0.15, 0.09, BARRIER_WHITE, JOINT_BASE)
		m.add_taper(c + Vector3(0.0, 0.50, 0.0), c + Vector3(0.0, 0.66, 0.0),
				0.09, 0.05, CONE_ORANGE, JOINT_BASE)
	return m


# ------------------------------------------------------------------ helpers

## Deterministic per-mesh jitter — the same heap on every run and every device.
static func _hash01(value: int, salt: int) -> float:
	var h: int = absi((value * 73856093) ^ (salt * 19349663)) % 100003
	return float(h) / 100003.0


## THE COLOUR SEAM, and the only one in this file (report 98 RR-95).
##
## A vertex COLOR is handed to the shader exactly as written and used as a
## LINEAR value — a `source_color` uniform and `StandardMaterial3D.albedo_color`
## are decoded for free, and neither a MultiMesh instance colour (RR-91) nor a
## vertex colour is. Every tint above is authored the way a painter authors one,
## in sRGB, so it is decoded HERE: once per vertex at BUILD time, never per
## frame, and never at the constant (see the block above the tints for why).
##
## Alpha is untouched by `srgb_to_linear`, which this layer depends on:
## `construction_rig.gdshader` reads `COLOR.a` as the per-machine hash.
static func _linear(color: Color) -> Color:
	return color.srgb_to_linear()


func _push(p: Vector3, n: Vector3, color: Color, joint: float, surf: float) -> int:
	_verts.push_back(p)
	_norms.push_back(n)
	_cols.push_back(_linear(color))
	_uvs.push_back(_tiled_uv(p, n))
	_uv2s.push_back(Vector2(joint, surf))
	return _verts.size() - 1


## Metres along the face divided by the page pitch — the same projection
## `ConstructionSiteView.PropMesh` uses, so plant, hoarding and crane share one
## physical grain.
func _tiled_uv(p: Vector3, n: Vector3) -> Vector2:
	var t := maxf(uv_tile_m, 0.01)
	if absf(n.y) > 0.5:
		return Vector2(p.x / t, p.z / t)
	if absf(n.x) >= absf(n.z):
		return Vector2(p.z / t, -p.y / t)
	return Vector2(p.x / t, -p.y / t)


func _quad(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: Vector3,
		color: Color, joint: float, surf: float) -> void:
	var i0 := _push(p0, n, color, joint, surf)
	var i1 := _push(p1, n, color, joint, surf)
	var i2 := _push(p2, n, color, joint, surf)
	var i3 := _push(p3, n, color, joint, surf)
	_wind(i0, i1, i2, p0, p1, p2, n)
	_wind(i0, i2, i3, p0, p2, p3, n)


func _tri(p0: Vector3, p1: Vector3, p2: Vector3, n: Vector3, color: Color,
		joint: float, surf: float) -> void:
	var i0 := _push(p0, n, color, joint, surf)
	var i1 := _push(p1, n, color, joint, surf)
	var i2 := _push(p2, n, color, joint, surf)
	_wind(i0, i1, i2, p0, p1, p2, n)


## Godot's front faces are CLOCKWISE: emit against the outward normal.
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
