class_name StreetLifeMesh
extends ConstructionRigMesh
## The bodies of the STREET LIFE layer (doc 11 §2.17): **the crook, the dog and
## the goat**, plus the flat quad every marker, label, puff and sparkle in the
## layer is drawn on.
##
## IT EXTENDS `ConstructionRigMesh` ON PURPOSE, and the inheritance is the
## interesting decision in the file. That class is not "the excavator" — it is
## this project's **gray-box body language**: `add_box`, `add_beam`, `add_taper`
## and `add_extrusion`, emitting clockwise-wound triangles that carry the part
## tint in `COLOR`, a metres-based surface coordinate in `UV`, and
## `UV2 = (JOINT, SURFACE)`. A pedestrian and a tracked excavator are the same
## problem — a jointed body that has to cost one draw call — so they are the
## same builder, and a change to the packing moves both shaders together instead
## of letting one drift. What this subclass adds is its own joint ceiling, its
## own surface codes, and three static factories.
##
## THE JOINT MODEL IS NOT THE EXCAVATOR'S, and that is the second decision.
## `construction_rig.gdshader` walks a strictly NESTED chain — joint 3 is moved
## by joints 2 and 1 as well, which is what a boom-arm-bucket is. A limbed animal
## is the opposite shape: four legs, a neck and a tail all hang off ONE body and
## none of them moves any other. So `street_life.gdshader` gives every joint its
## own pivot and applies exactly one rotation per vertex, and the wiring lives in
## two small uniform arrays this file publishes alongside each body:
##
##   `rig_pivot[j]` = (pivot.xyz, axis)   axis 0 = pitch about +Z,
##                                             1 = yaw about +Y,
##                                             2 = roll about +X
##   `rig_sel[j]`   = the INSTANCE_CUSTOM channel mask, times the gain
##
## `rig_sel` earns its keep on the quadrupeds: a trot is the two DIAGONAL legs
## swinging together and the other two swinging against them, so all four legs
## ride channel 0 and the second diagonal simply carries gain −1. Four legs, a
## head and a tail — six moving parts — off THREE animated floats.
##
## THE FOUR CHANNELS, identical for all three bodies so the view has one
## animator and not three:
##
##   `.r` LIMB   legs (both bipedal, all four quadrupedal)
##   `.g` HEAD   the crook's furtive yaw; the dog's bob; the goat's browse-dip
##   `.b` EXTRA  the crook's arms; the animals' tails
##   `.a` FX     0 normal → 1 gone. Shrinks the body about its own feet and, when
##               the instance colour's alpha says this was a COLLECT rather than
##               an EXPIRE, lifts and flashes it.
##
## Every channel is authored 0…1 and mapped through `chan_min` / `chan_range`,
## the same normalisation the construction rig uses, so the working envelope of
## a walk cycle is stated once in GDScript and never twice.
##
## LOCAL SPACE: **+X is forward**, Y up, origin between the feet on the ground —
## the convention `VehicleMesh`, `ConstructionRigMesh` and both sim feeds share,
## so a view's only rotation is a yaw.

# ------------------------------------------------------------------- joints

const J_BODY := 0.0
const J_1 := 1.0
const J_2 := 2.0
const J_3 := 3.0
const J_4 := 4.0
const J_5 := 5.0
const J_6 := 6.0
## Ceiling for `rig_pivot` / `rig_sel`. Eight is one more than the fullest body
## here (the quadrupeds' seven) and the number the shader declares.
const JOINT_SLOTS := 8

# ------------------------------------------------------------------ surfaces

## Coat, cloth, hide — whatever the instance colour paints.
const SURF_COAT := 0.0
## Boots, hooves, muzzles, the shadow inside a hood: authored dark and NOT
## repainted by the instance colour, so a pale goat still has black hooves.
const SURF_DARK := 1.0
## Eyes and the swag bag's clasp — the one thing on these bodies that catches a
## light after dark.
const SURF_GLINT := 2.0

# ------------------------------------------------------------- shared tints

## Painted like the plant: near-white takes the instance colour whole.
const COAT := Color(1.0, 1.0, 1.0)
const CLOTH_DARK := Color(0.34, 0.35, 0.40)
const SHADOW := Color(0.055, 0.055, 0.065)
const BOOT := Color(0.10, 0.10, 0.11)
const SKIN := Color(0.62, 0.47, 0.38)
const SWAG := Color(0.78, 0.74, 0.62)
const GLINT := Color(0.95, 0.93, 0.80)
const HORN := Color(0.74, 0.70, 0.60)
const NOSE := Color(0.13, 0.12, 0.12)


# ------------------------------------------------------------------ the rig

## The pivot/axis table for a body, padded to `JOINT_SLOTS` — the array the view
## hands `street_life.gdshader` as `rig_pivot`.
static func _pivots(rows: Array) -> PackedVector4Array:
	var out := PackedVector4Array()
	out.resize(JOINT_SLOTS)
	for i in JOINT_SLOTS:
		out[i] = Vector4(0.0, 0.0, 0.0, 0.0)
	for i in mini(rows.size(), JOINT_SLOTS):
		out[i] = rows[i]
	return out


## The channel-mask table, padded the same way — `rig_sel`. Joint 0 is always
## the still body, so its mask is all zeros and its vertices never rotate.
static func _sel(rows: Array) -> PackedVector4Array:
	var out := PackedVector4Array()
	out.resize(JOINT_SLOTS)
	for i in JOINT_SLOTS:
		out[i] = Vector4(0.0, 0.0, 0.0, 0.0)
	for i in mini(rows.size(), JOINT_SLOTS):
		out[i] = rows[i]
	return out


## Pitch about +Z — the axis every leg, arm and neck here swings on.
const AXIS_PITCH := 0.0
## Yaw about +Y — a head turning, a tail wagging.
const AXIS_YAW := 1.0
## Roll about +X — nothing uses it yet; the shader carries it because a limb
## that splays is one uniform away and not one shader away.
const AXIS_ROLL := 2.0

## Channel masks, ready to be scaled by a gain.
const CH_LIMB := Vector4(1.0, 0.0, 0.0, 0.0)
const CH_HEAD := Vector4(0.0, 1.0, 0.0, 0.0)
const CH_EXTRA := Vector4(0.0, 0.0, 1.0, 0.0)

## Working envelopes, radians. Authored SYMMETRIC about zero so a `gain` of −1
## is a true mirror — an asymmetric range would give a trotting dog a limp.
const LIMB_RANGE := Vector2(-0.62, 0.62)
const HEAD_RANGE := Vector2(-0.62, 0.62)
const EXTRA_RANGE := Vector2(-0.72, 0.72)
## The FX channel passes through untouched: 0 is a body standing there, 1 is a
## body that has finished leaving.
const FX_RANGE := Vector2(0.0, 1.0)


## `(chan_min, chan_range)` for `street_life.gdshader`, in channel order.
static func channel_ranges() -> Array[Vector4]:
	return [
		Vector4(LIMB_RANGE.x, HEAD_RANGE.x, EXTRA_RANGE.x, FX_RANGE.x),
		Vector4(LIMB_RANGE.y - LIMB_RANGE.x, HEAD_RANGE.y - HEAD_RANGE.x,
				EXTRA_RANGE.y - EXTRA_RANGE.x, FX_RANGE.y - FX_RANGE.x),
	]


# ------------------------------------------------------------------ the crook

## Hip height, shoulder height and the half-track the legs and arms stand on —
## quoted once here because the pivots, the geometry and the view's stride
## length all have to agree about them.
const CROOK_HIP_Y := 0.92
const CROOK_SHOULDER_Y := 1.56
const CROOK_NECK_Y := 1.50
const CROOK_LEG_HALF_Z := 0.115
const CROOK_ARM_HALF_Z := 0.215
## Crown of the hood. The marker hangs off this.
const CROOK_TOP_M := 1.92


## The crook — a hooded figure with a swag bag, ~200 tris, six joints.
##
## The whole design brief is ONE READ AT THIRTY SCREEN PIXELS. At Z1 a 1.8 m
## body is 30 px tall on a 1080-line frame, so nothing below the level of
## SILHOUETTE survives: the pass is a pointed cowl leaning forward, a hunched
## back, and a pale sack swinging off one hand against a dark body. A face, a
## belt or a pocket would be sub-pixel and would only cost triangles. What the
## bag buys is the verb — a hooded figure standing on a pavement is a pedestrian;
## a hooded figure carrying a sack is a burglary in progress.
static func crook() -> StreetLifeMesh:
	var m := StreetLifeMesh.new()

	# ---- joint 0: pelvis, torso, the body the rest hangs off --------------
	m.add_box(Vector3(0.0, CROOK_HIP_Y + 0.10, 0.0), Vector3(0.30, 0.26, 0.42),
			CLOTH_DARK, J_BODY)
	# Waist and chest, the chest both wider and deeper: the hoodie's bulk is
	# what separates this silhouette from a lamp post at distance.
	m.add_box(Vector3(-0.01, 1.20, 0.0), Vector3(0.32, 0.30, 0.44), COAT, J_BODY)
	m.add_box(Vector3(-0.02, 1.44, 0.0), Vector3(0.38, 0.30, 0.52), COAT, J_BODY)
	# Shoulder yoke, so the arms leave something rather than the air.
	m.add_box(Vector3(-0.02, CROOK_SHOULDER_Y, 0.0), Vector3(0.34, 0.16, 0.56),
			COAT, J_BODY)

	# ---- joints 1 & 2: the legs -------------------------------------------
	for sz: float in [1.0, -1.0]:
		var z := sz * CROOK_LEG_HALF_Z
		var joint := J_1 if sz > 0.0 else J_2
		m.add_taper(Vector3(0.0, CROOK_HIP_Y, z), Vector3(0.0, 0.11, z),
				0.19, 0.14, CLOTH_DARK, joint)
		m.add_box(Vector3(0.04, 0.05, z), Vector3(0.28, 0.10, 0.15), BOOT,
				joint, SURF_DARK)

	# ---- joints 3 & 4: the arms -------------------------------------------
	# Both arms hang forward-ish at rest; the swing is the animation.
	for sz2: float in [1.0, -1.0]:
		var z2 := sz2 * CROOK_ARM_HALF_Z
		var joint2 := J_3 if sz2 > 0.0 else J_4
		m.add_taper(Vector3(0.0, CROOK_SHOULDER_Y, z2),
				Vector3(0.10, 1.10, z2 * 0.92), 0.15, 0.11, COAT, joint2)
		m.add_box(Vector3(0.12, 1.05, z2 * 0.92), Vector3(0.11, 0.11, 0.11),
				SKIN, joint2)
	# The swag: a bulging sack on the LEFT hand (joint 3), pale against a dark
	# body. One box, and it is the whole story of the prop.
	m.add_box(Vector3(0.19, 0.90, CROOK_ARM_HALF_Z * 0.92 + 0.05),
			Vector3(0.26, 0.30, 0.24), SWAG, J_3)
	m.add_box(Vector3(0.19, 1.04, CROOK_ARM_HALF_Z * 0.92 + 0.05),
			Vector3(0.10, 0.06, 0.10), GLINT, J_3, SURF_GLINT)

	# ---- joint 5: head and hood -------------------------------------------
	# A cowl, not a ball: the profile leans FORWARD off the neck and comes to a
	# point, which is the one shape that says "hood" at thirty pixels.
	m.add_box(Vector3(0.0, 1.62, 0.0), Vector3(0.22, 0.22, 0.24), SKIN, J_5)
	m.add_extrusion(PackedVector2Array([
			Vector2(-0.20, CROOK_NECK_Y), Vector2(0.14, CROOK_NECK_Y + 0.02),
			Vector2(0.25, 1.70), Vector2(0.09, CROOK_TOP_M),
			Vector2(-0.19, 1.88)]), -0.19, 0.19, COAT, J_5)
	# The shadow inside the opening. Authored near-black on the DARK surface, so
	# no coat colour ever lights the face up.
	m.add_box(Vector3(0.17, 1.64, 0.0), Vector3(0.07, 0.18, 0.20), SHADOW,
			J_5, SURF_DARK)
	m.add_box(Vector3(0.21, 1.66, 0.0), Vector3(0.03, 0.05, 0.15), GLINT,
			J_5, SURF_GLINT)
	return m


## The crook's rig table. Legs mirror on channel 0, arms on channel 2, and the
## head takes channel 1 as a YAW — a thief checks over their shoulder, and a
## head that turns is worth more here than a head that nods.
static func crook_pivots() -> PackedVector4Array:
	return _pivots([
		Vector4(0.0, 0.0, 0.0, AXIS_PITCH),
		Vector4(0.0, CROOK_HIP_Y, CROOK_LEG_HALF_Z, AXIS_PITCH),
		Vector4(0.0, CROOK_HIP_Y, -CROOK_LEG_HALF_Z, AXIS_PITCH),
		Vector4(0.0, CROOK_SHOULDER_Y, CROOK_ARM_HALF_Z, AXIS_PITCH),
		Vector4(0.0, CROOK_SHOULDER_Y, -CROOK_ARM_HALF_Z, AXIS_PITCH),
		Vector4(0.0, CROOK_NECK_Y, 0.0, AXIS_YAW),
	])


static func crook_sel() -> PackedVector4Array:
	return _sel([
		Vector4.ZERO,
		CH_LIMB, -CH_LIMB,
		CH_EXTRA * 0.85, -CH_EXTRA * 0.85,
		CH_HEAD,
	])


# ---------------------------------------------------------------- quadrupeds

const DOG_TOP_M := 0.86
const GOAT_TOP_M := 1.06


## The dog — a stray on a trot, ~190 tris, seven joints.
##
## Deep chest, level back, low head carriage, and a tail that stands off the
## rump: the four proportions that separate a dog from a goat at any distance
## where neither has a face. The legs are a thigh taper plus a dark paw box, so
## the foot is a value contrast rather than eight more triangles.
static func dog() -> StreetLifeMesh:
	return _quadruped({
		"chest": Vector3(0.13, 0.47, 0.0), "chest_size": Vector3(0.40, 0.34, 0.30),
		"rump": Vector3(-0.21, 0.46, 0.0), "rump_size": Vector3(0.36, 0.30, 0.27),
		"neck_a": Vector3(0.26, 0.52, 0.0), "neck_b": Vector3(0.42, 0.63, 0.0),
		"neck_t": Vector2(0.21, 0.16),
		"head": Vector3(0.47, 0.66, 0.0), "head_size": Vector3(0.22, 0.18, 0.16),
		"muzzle": Vector3(0.60, 0.62, 0.0), "muzzle_size": Vector3(0.15, 0.10, 0.10),
		"ear_a": Vector3(0.42, 0.74, 0.07), "ear_b": Vector3(0.38, 0.86, 0.09),
		"ear_t": Vector2(0.09, 0.04), "ear_color": COAT,
		"horns": false, "beard": false,
		"hip_y": 0.42, "foot_y": 0.05, "leg_t": Vector2(0.11, 0.08),
		"fore_x": 0.21, "hind_x": -0.25, "leg_half_z": 0.105,
		"paw_size": Vector3(0.15, 0.09, 0.11),
		"tail_a": Vector3(-0.36, 0.54, 0.0), "tail_b": Vector3(-0.56, 0.70, 0.0),
		"tail_t": Vector2(0.09, 0.05),
	})


## The goat — ~215 tris, seven joints. Blockier body, horns swept back off the
## poll, a beard, and a stubby tail carried UP. The beard is four triangles of
## taper and it is the single detail that makes the animal name itself.
static func goat() -> StreetLifeMesh:
	return _quadruped({
		"chest": Vector3(0.08, 0.55, 0.0), "chest_size": Vector3(0.44, 0.36, 0.34),
		"rump": Vector3(-0.26, 0.55, 0.0), "rump_size": Vector3(0.40, 0.36, 0.33),
		"neck_a": Vector3(0.26, 0.62, 0.0), "neck_b": Vector3(0.40, 0.74, 0.0),
		"neck_t": Vector2(0.22, 0.17),
		"head": Vector3(0.47, 0.77, 0.0), "head_size": Vector3(0.24, 0.19, 0.17),
		"muzzle": Vector3(0.61, 0.72, 0.0), "muzzle_size": Vector3(0.16, 0.12, 0.12),
		"ear_a": Vector3(0.42, 0.84, 0.09), "ear_b": Vector3(0.34, 0.88, 0.20),
		"ear_t": Vector2(0.08, 0.05), "ear_color": COAT,
		"horns": true, "beard": true,
		"hip_y": 0.50, "foot_y": 0.06, "leg_t": Vector2(0.12, 0.09),
		"fore_x": 0.20, "hind_x": -0.28, "leg_half_z": 0.115,
		"paw_size": Vector3(0.14, 0.11, 0.12),
		"tail_a": Vector3(-0.42, 0.62, 0.0), "tail_b": Vector3(-0.52, 0.76, 0.0),
		"tail_t": Vector2(0.10, 0.06),
	})


## One four-legged body from a table of proportions. Both animals go through
## here because they are the same rig with different numbers, and two hand-built
## copies would drift the moment the joint layout moved.
static func _quadruped(p: Dictionary) -> StreetLifeMesh:
	var m := StreetLifeMesh.new()
	var hip_y: float = p["hip_y"]
	var foot_y: float = p["foot_y"]
	var leg_t: Vector2 = p["leg_t"]
	var half_z: float = p["leg_half_z"]
	var paw: Vector3 = p["paw_size"]

	# ---- joint 0: barrel --------------------------------------------------
	m.add_box(p["chest"], p["chest_size"], COAT, J_BODY)
	m.add_box(p["rump"], p["rump_size"], COAT, J_BODY)

	# ---- joints 1..4: the legs, DIAGONALS paired --------------------------
	# Fore-left and hind-right share channel 0 at gain +1; the other diagonal
	# carries −1. That IS a trot, and it costs one animated float.
	var legs := [
		{"j": J_1, "x": float(p["fore_x"]), "z": half_z},
		{"j": J_2, "x": float(p["hind_x"]), "z": -half_z},
		{"j": J_3, "x": float(p["fore_x"]), "z": -half_z},
		{"j": J_4, "x": float(p["hind_x"]), "z": half_z},
	]
	for leg: Dictionary in legs:
		var lx: float = leg["x"]
		var lz: float = leg["z"]
		m.add_taper(Vector3(lx, hip_y, lz), Vector3(lx, foot_y + 0.02, lz),
				leg_t.x, leg_t.y, COAT, leg["j"])
		# The paw/hoof sits ON the ground, not through it: its centre is half its
		# own height, not half the ankle's. The first pass took `foot_y * 0.5`
		# and put a goat's hooves 25 mm under the pavement.
		m.add_box(Vector3(lx + 0.01, paw.y * 0.5, lz), paw, BOOT,
				leg["j"], SURF_DARK)

	# ---- joint 5: neck and head -------------------------------------------
	m.add_taper(p["neck_a"], p["neck_b"], float((p["neck_t"] as Vector2).x),
			float((p["neck_t"] as Vector2).y), COAT, J_5)
	m.add_box(p["head"], p["head_size"], COAT, J_5)
	m.add_box(p["muzzle"], p["muzzle_size"], NOSE, J_5, SURF_DARK)
	var ear_a: Vector3 = p["ear_a"]
	var ear_b: Vector3 = p["ear_b"]
	var ear_t: Vector2 = p["ear_t"]
	for sz: float in [1.0, -1.0]:
		m.add_taper(Vector3(ear_a.x, ear_a.y, ear_a.z * sz),
				Vector3(ear_b.x, ear_b.y, ear_b.z * sz), ear_t.x, ear_t.y,
				p["ear_color"], J_5)
	if bool(p["horns"]):
		# Swept back and out off the poll, in two segments so the sweep is a
		# curve rather than a spike.
		for sz2: float in [1.0, -1.0]:
			var h0 := Vector3(0.44, 0.88, 0.055 * sz2)
			var h1 := Vector3(0.34, 0.99, 0.085 * sz2)
			var h2 := Vector3(0.22, 1.00, 0.115 * sz2)
			m.add_taper(h0, h1, 0.055, 0.042, HORN, J_5)
			m.add_taper(h1, h2, 0.042, 0.026, HORN, J_5)
	if bool(p["beard"]):
		m.add_taper(Vector3(0.55, 0.68, 0.0), Vector3(0.52, 0.52, 0.0),
				0.09, 0.05, COAT, J_5)

	# ---- joint 6: tail ----------------------------------------------------
	m.add_taper(p["tail_a"], p["tail_b"], float((p["tail_t"] as Vector2).x),
			float((p["tail_t"] as Vector2).y), COAT, J_6)
	return m


## The quadruped rig table. Fore-left / hind-right ride channel 0 at +1, the
## other diagonal at −1; the neck pitches on channel 1 (a bob, or a browse-dip
## deep enough to put a goat's muzzle on the kerb), the tail yaws on channel 2.
static func quadruped_pivots(fore_x: float, hind_x: float, half_z: float,
		hip_y: float, neck: Vector3, tail: Vector3) -> PackedVector4Array:
	return _pivots([
		Vector4(0.0, 0.0, 0.0, AXIS_PITCH),
		Vector4(fore_x, hip_y, half_z, AXIS_PITCH),
		Vector4(hind_x, hip_y, -half_z, AXIS_PITCH),
		Vector4(fore_x, hip_y, -half_z, AXIS_PITCH),
		Vector4(hind_x, hip_y, half_z, AXIS_PITCH),
		Vector4(neck.x, neck.y, neck.z, AXIS_PITCH),
		Vector4(tail.x, tail.y, tail.z, AXIS_YAW),
	])


static func quadruped_sel() -> PackedVector4Array:
	return _sel([
		Vector4.ZERO,
		CH_LIMB, CH_LIMB, -CH_LIMB, -CH_LIMB,
		CH_HEAD, CH_EXTRA,
	])


## The pivot arguments each animal's table needs, so the view never restates a
## number the body was built from.
static func dog_rig() -> PackedVector4Array:
	return quadruped_pivots(0.21, -0.25, 0.105, 0.42,
			Vector3(0.26, 0.52, 0.0), Vector3(-0.36, 0.54, 0.0))


static func goat_rig() -> PackedVector4Array:
	return quadruped_pivots(0.20, -0.28, 0.115, 0.50,
			Vector3(0.26, 0.62, 0.0), Vector3(-0.42, 0.62, 0.0))


# ------------------------------------------------------------ the flat quad

## The one quad every marker, floating label, poof puff, ring and sparkle in
## this layer is drawn on — 2 triangles, unit-sized in XY about its own centre,
## `UV` running 0…1 across it. `street_fx.gdshader` turns it to face the camera
## and decides what it IS from `INSTANCE_CUSTOM.r`.
##
## Built by hand rather than through the box builder above for one reason: the
## builder projects `UV` from METRES so a hoarding and a crane share a grain,
## and a glyph needs its own 0…1 frame instead.
static func billboard_quad() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var verts := PackedVector3Array([
		Vector3(-0.5, -0.5, 0.0), Vector3(0.5, -0.5, 0.0),
		Vector3(0.5, 0.5, 0.0), Vector3(-0.5, 0.5, 0.0)])
	var norms := PackedVector3Array([
		Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK])
	# v grows DOWN the quad, matching the atlas page's own top-left origin, so a
	# glyph is not upside down and no flip has to be remembered in the shader.
	var uvs := PackedVector2Array([
		Vector2(0.0, 1.0), Vector2(1.0, 1.0), Vector2(1.0, 0.0), Vector2(0.0, 0.0)])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
