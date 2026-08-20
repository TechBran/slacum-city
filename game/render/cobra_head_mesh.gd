class_name CobraHeadMesh
extends RefCounted
## The streetlight, as a real light standard (doc 11 §2.10).
##
## What it replaces was a bare 8 m box with a collar. The playtest verdict on it
## was *"they just look like sticks popping out of the ground"*, and the reason
## is that a stick carries none of the three cues that say STREETLIGHT: it does
## not lean over the road, it has no luminaire, and it therefore points at
## nothing. A cobra head is the cheapest shape that carries all three —
##
##   * a **mast** that stands on the footway, not in the carriageway;
##   * an **arm** that curves out over the road, which is the silhouette a
##     player reads at 200 m even when the head itself is two pixels;
##   * a **luminaire** with a pale underside, so the thing the lamp billboard is
##     glowing out of is visibly the thing that would glow.
##
## ONE ArrayMesh for every lamp in the city, instanced per chunk; the arm's
## direction is baked along local **+X** and each instance yaws it toward its own
## roadway. 76 triangles against the box's 34 — paid once, on the mesh every pole
## shares, and still two orders of magnitude under one building.
##
## The base weathering stays vertex colour for the reason it always was: the
## galvanised page is TILED, so grime authored into it would repeat every
## `prop_tile_m` up the shaft and read as a barber's pole.

## Local +X is "toward the road". Every instance transform is a yaw about Y.
const ARM_AXIS := Vector3(1.0, 0.0, 0.0)
## Baked weathering: how far up the shaft road grime reaches, and how dark it
## gets at grade. The collar sits under all of it and is dirtier still.
const GRIME_M := 2.40
const GRIME_FLOOR := 0.52
const COLLAR_M := 0.30
const COLLAR_SCALE := 1.55
const COLLAR_GRIME := 0.86
## The luminaire is PAINTED, not galvanised, and its lens is glass. Both ride
## vertex colour on top of the grime ramp — the same channel, one multiply — so
## the head reads as a fitted object bolted to the mast rather than as more
## mast. (Vertex colour is quantised to RGBA8, so these stay inside [0,1] and
## the contrast is spent on HUE, which survives the quantisation intact.)
const COWL_TINT := Color(0.90, 0.91, 0.94)
const LENS_TINT := Color(1.00, 0.99, 0.93)
const ARM_SEGMENTS := 4

var mast_height := 7.60
var arm_reach := 2.20
var arm_rise := 0.75
var head_length := 1.05
var head_width := 0.40
var head_back := 0.24
var head_front := 0.16
var pole_width := 0.20
var arm_width := 0.14

var _verts := PackedVector3Array()
var _norms := PackedVector3Array()
var _cols := PackedColorArray()
var _uvs := PackedVector2Array()
var _idx := PackedInt32Array()
var _tile := 2.0


## `lamp_cfg` is `data/render.json.road_surface.lamp`; every key is optional.
static func build(lamp_cfg: Dictionary = {}) -> ArrayMesh:
	var b := CobraHeadMesh.new()
	b.mast_height = float(lamp_cfg.get("mast_height_m", b.mast_height))
	b.arm_reach = float(lamp_cfg.get("arm_reach_m", b.arm_reach))
	b.arm_rise = float(lamp_cfg.get("arm_rise_m", b.arm_rise))
	b.head_length = float(lamp_cfg.get("head_length_m", b.head_length))
	b.head_width = float(lamp_cfg.get("head_width_m", b.head_width))
	b.head_back = float(lamp_cfg.get("head_height_back_m", b.head_back))
	b.head_front = float(lamp_cfg.get("head_height_front_m", b.head_front))
	b.pole_width = float(lamp_cfg.get("pole_width_m", b.pole_width))
	return b._build()


## Where the luminaire's centre sits in the pole's own frame — the anchor the
## lamp billboard, the ground pool and the wet smear all hang off, so the glow
## comes out of the head and not out of the top of a stick.
static func head_offset(lamp_cfg: Dictionary = {}) -> Vector3:
	var reach := float(lamp_cfg.get("arm_reach_m", 2.20))
	var length := float(lamp_cfg.get("head_length_m", 1.05))
	var height := float(lamp_cfg.get("head_height_m", 8.35))
	return Vector3(reach - 0.25 + length * 0.5, height - 0.10, 0.0)


func _build() -> ArrayMesh:
	_tile = maxf(PropSurface.tile_m(), 0.01)
	var half := pole_width * 0.5
	var sides: Array[Vector3] = [Vector3(0, 0, 1), Vector3(0, 0, -1),
			Vector3(1, 0, 0), Vector3(-1, 0, 0)]

	# ── mast, in three lifts so the grime ramp has vertices to sit on ──────
	var lifts := [0.0, GRIME_M * 0.5, GRIME_M, mast_height]
	for n: Vector3 in sides:
		var out := n * half
		var side := Vector3(n.z, 0.0, -n.x) * half
		for li in lifts.size() - 1:
			var y0 := float(lifts[li])
			var y1 := float(lifts[li + 1])
			_quad(out - side + Vector3(0.0, y0, 0.0), out + side + Vector3(0.0, y0, 0.0),
					out + side + Vector3(0.0, y1, 0.0), out - side + Vector3(0.0, y1, 0.0),
					n, 1.0)

	# ── base collar ───────────────────────────────────────────────────────
	var cw := half * COLLAR_SCALE
	for n: Vector3 in sides:
		var out := n * cw
		var side := Vector3(n.z, 0.0, -n.x) * cw
		_quad(out - side, out + side, out + side + Vector3(0.0, COLLAR_M, 0.0),
				out - side + Vector3(0.0, COLLAR_M, 0.0), n, COLLAR_GRIME)

	# ── arm: a quarter-ellipse leaving the mast vertically and arriving over
	# the carriageway horizontal. Swept as a square section in the XY plane, so
	# the silhouette is right from the two angles a city-builder camera ever
	# offers (down the street, and across it).
	var ah := arm_width * 0.5
	var pts: Array[Vector3] = []
	for k in ARM_SEGMENTS + 1:
		var t := float(k) / float(ARM_SEGMENTS) * PI * 0.5
		pts.append(Vector3(arm_reach * (1.0 - cos(t)), mast_height + arm_rise * sin(t), 0.0))
	for k in ARM_SEGMENTS:
		var p0: Vector3 = pts[k]
		var p1: Vector3 = pts[k + 1]
		var u := (p1 - p0).normalized()
		var nrm := Vector3(-u.y, u.x, 0.0)
		var z := Vector3(0.0, 0.0, ah)
		var a0 := p0 + nrm * ah
		var a1 := p0 - nrm * ah
		var b0 := p1 + nrm * ah
		var b1 := p1 - nrm * ah
		_quad(a0 - z, a0 + z, b0 + z, b0 - z, nrm, 1.0)
		_quad(a1 + z, a1 - z, b1 - z, b1 + z, -nrm, 1.0)
		_quad(a1 + z, a0 + z, b0 + z, b1 + z, Vector3(0, 0, 1), 1.0)
		_quad(a0 - z, a1 - z, b1 - z, b0 - z, Vector3(0, 0, -1), 1.0)

	# ── luminaire ─────────────────────────────────────────────────────────
	var top: Vector3 = pts[ARM_SEGMENTS]
	var x_b := top.x - 0.25
	var x_f := x_b + head_length
	var y_t := top.y
	var hw := head_width * 0.5
	var y_bb := y_t - head_back
	var y_bf := y_t - head_front
	var t_bl := Vector3(x_b, y_t, -hw)
	var t_br := Vector3(x_b, y_t, hw)
	var t_fl := Vector3(x_f, y_t, -hw)
	var t_fr := Vector3(x_f, y_t, hw)
	var u_bl := Vector3(x_b, y_bb, -hw)
	var u_br := Vector3(x_b, y_bb, hw)
	var u_fl := Vector3(x_f, y_bf, -hw)
	var u_fr := Vector3(x_f, y_bf, hw)
	_quad(t_bl, t_fl, t_fr, t_br, Vector3.UP, 1.0, COWL_TINT)            # cowl
	_quad(u_bl, u_br, u_fr, u_fl, Vector3.DOWN, 1.0, LENS_TINT)          # lens
	_quad(t_br, t_fr, u_fr, u_br, Vector3(0, 0, 1), 1.0, COWL_TINT)
	_quad(t_fl, t_bl, u_bl, u_fl, Vector3(0, 0, -1), 1.0, COWL_TINT)
	_quad(t_bl, t_br, u_br, u_bl, Vector3(-1, 0, 0), 1.0, COWL_TINT)     # back
	_quad(t_fr, t_fl, u_fl, u_fr, Vector3(1, 0, 0), 1.0, LENS_TINT)      # front glass

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _verts
	arrays[Mesh.ARRAY_NORMAL] = _norms
	arrays[Mesh.ARRAY_COLOR] = _cols
	arrays[Mesh.ARRAY_TEX_UV] = _uvs
	arrays[Mesh.ARRAY_INDEX] = _idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _push(p: Vector3, n: Vector3, grime: float, tint: Color) -> int:
	_verts.push_back(p)
	_norms.push_back(n)
	var k := lerpf(GRIME_FLOOR, 1.0, clampf(p.y / maxf(GRIME_M, 0.01), 0.0, 1.0)) * grime
	_cols.push_back(Color(k * tint.r, k * tint.g, k * tint.b, 1.0))
	# Metres along the face and up the shaft: the prop page's own pitch, so a
	# 0.14 m arm and an 8 m mast carry the same grain.
	var u := (p.z if absf(n.x) >= absf(n.z) else p.x) / _tile
	_uvs.push_back(Vector2(u, -p.y / _tile))
	return _verts.size() - 1


## Godot front faces are CLOCKWISE — the rule `gen_graybox.gd` and
## `ConstructionSiteView.PropMesh` both follow.
func _quad(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: Vector3,
		grime: float, tint := Color.WHITE) -> void:
	var i0 := _push(p0, n, grime, tint)
	var i1 := _push(p1, n, grime, tint)
	var i2 := _push(p2, n, grime, tint)
	var i3 := _push(p3, n, grime, tint)
	_idx.append_array(PackedInt32Array([i0, i2, i1]))
	_idx.append_array(PackedInt32Array([i0, i3, i2]))
