class_name LandMachineMesh
extends ConstructionRigMesh
## **THE MACHINES THAT WORK ACROSS A BLOCK** (doc 11 §2.19) — the three bodies
## `ConstructionRigMesh` did not have, authored in the same gray-box language and
## driven by the same shader.
##
## Doc 11 §2.16 gave the city an excavator and a tipper: the plant that stands at
## a BUILDING'S FRONTAGE and works one spot. Doc 11 §2.18 gave a developing land
## block its dressing. What neither gave is the thing the player asked for on
## 2026-09-05 — *"construction crews, big bulldozers and things like that, need
## to go to clear the land … we need to actually show MOVEMENT over there"* — a
## machine that crosses the block and leaves the ground changed behind it.
##
## Three bodies, because three verbs:
##
##   `dozer()`   a crawler tractor with a full-width blade. It SWEEPS, and the
##               brush in the strip it has covered is gone (CLEARING).
##   `paver()`   a screed machine. It CRAWLS, and the surface appears BEHIND it
##               (ROAD_INSTALL, and the kerb run in FINAL_DEVELOPMENT).
##   `roller()`  a single-drum compactor. It FOLLOWS, and its drum turns with
##               the distance it has covered.
##
## **They ride `construction_rig.gdshader` unchanged**, in `rig_mode = 0`, and
## each of them spends exactly ONE of that shader's four joints:
##
##   dozer   joint 1 = blade lift, pitching about +Z at `DOZ_BLADE_PIVOT`
##   paver   joint 1 = screed float, pitching about +Z at `PAV_SCREED_PIVOT`
##   roller  joint 1 = drum ROLL, pitching about +Z at `ROL_DRUM_PIVOT` — the
##           drum's axle IS the +Z axis, so the shader's `rot_z` is the drum
##           turning and the range is a whole revolution
##
## Joints 2…4 are given a zero range by the view, so the other three channels of
## `INSTANCE_CUSTOM` cost nothing and the same shader, the same material recipe
## and the same one-draw-call-per-kind bargain carry over whole. Nothing new was
## added to the shader for this wave.
##
## LOCAL SPACE, as everywhere else in this renderer: **+X is forward**, Y up,
## origin on the ground between the tracks — so a view's only rotation is a yaw.
##
## SIZES. A land block is 128 m across and the camera looks at one from about
## 150 m, which is the same call doc 11 §2.16 made for the excavator: these are
## authored at real plant dimensions (a D8-class dozer is 7.4 m over the blade, a
## single-drum roller 5.8 m, a paver 7.0 m) and NOT exaggerated, because at this
## distance the excavator beside them is the scale reference and a dozer drawn
## half again too big would read as a toy next to it.

# ------------------------------------------------------------------- the dozer

## Where the blade hangs off the push arms. Quoted once: the pivot, the geometry
## and the shader uniform all have to agree about it.
const DOZ_BLADE_PIVOT := Vector3(1.62, 1.18, 0.0)
## Blade lift, radians about +Z. Negative is DOWN into the cut — a dozer at work
## spends its cycle just below the datum and lifts to carry the spill over.
const DOZ_BLADE_RANGE := Vector2(-0.30, 0.16)
## All four joints pitch about +Z; 1 in a channel would make it yaw about +Y.
const AXES_PITCH := Color(0.0, 0.0, 0.0, 0.0)
## Crown of the beacon — what a view's custom AABB is sized from.
const DOZ_TOP_M := 3.62
const DOZ_LENGTH_M := 7.40


## The crawler dozer — a tracked tractor with a full-width blade, ~330 tris.
##
## The blade is the whole read. At 150 m a dozer without one is a small
## excavator with no boom; with one it is unmistakably the machine that is
## pushing the scrub off this block, and the 4.6 m width is what makes the strip
## it has cleared legible as a strip.
static func dozer() -> LandMachineMesh:
	var m := LandMachineMesh.new()

	# ---- joint 0: undercarriage, chassis, cab ----------------------------
	# Track frames, the same extruded hexagon language the excavator uses: flat
	# run on the ground, both ends ramped. A dozer's tracks are longer and set
	# wider than an excavator's, which is most of why the two read differently
	# from above.
	var track := PackedVector2Array([
		Vector2(-2.60, 0.20), Vector2(-2.06, 0.00), Vector2(2.06, 0.00),
		Vector2(2.60, 0.20), Vector2(2.60, 0.96), Vector2(-2.60, 0.96)])
	for sz: float in [1.0, -1.0]:
		var z := sz * 1.26
		m.add_extrusion(track, z - 0.32, z + 0.32, DARK, JOINT_BASE)
		m.add_box(Vector3(2.28, 0.48, z), Vector3(0.52, 0.74, 0.70), GREASE, JOINT_BASE)
		m.add_box(Vector3(-2.28, 0.48, z), Vector3(0.52, 0.74, 0.70), GREASE, JOINT_BASE)
		# Grouser band along the ground run — the tread line, one plate.
		m.add_box(Vector3(0.0, 0.08, z), Vector3(4.40, 0.16, 0.74), STEEL, JOINT_BASE)
		# Carrier rollers on top of the frame.
		for i in 2:
			m.add_box(Vector3(-0.85 + float(i) * 1.70, 1.00, z),
					Vector3(0.34, 0.22, 0.52), GREASE, JOINT_BASE)
	# Belly pan between the tracks, then the engine hood forward of the cab.
	m.add_box(Vector3(0.0, 0.80, 0.0), Vector3(4.10, 0.44, 1.90), STEEL, JOINT_BASE)
	m.add_extrusion(PackedVector2Array([
			Vector2(-0.20, 1.06), Vector2(1.92, 1.06), Vector2(1.92, 1.74),
			Vector2(-0.20, 2.02)]), -0.86, 0.86, PAINT, JOINT_BASE)
	# Exhaust stack and pre-cleaner ahead of the screen — the one vertical on a
	# very horizontal machine, and it is what says "tractor" in silhouette.
	m.add_beam(Vector3(1.34, 1.72, 0.44), Vector3(1.34, 2.92, 0.44), 0.17,
			DARK, JOINT_BASE)
	m.add_box(Vector3(1.34, 3.00, 0.44), Vector3(0.30, 0.20, 0.30), DARK, JOINT_BASE)
	# ROPS cab, set well back the way a dozer puts it.
	m.add_box(Vector3(-1.06, 2.06, 0.0), Vector3(2.00, 1.62, 1.76), PAINT, JOINT_BASE)
	m.add_box(Vector3(-0.08, 2.16, 0.0), Vector3(0.08, 1.16, 1.58), GLASS,
			JOINT_BASE, SURF_GLASS)
	m.add_box(Vector3(-1.06, 2.22, 0.88), Vector3(1.72, 1.00, 0.06), GLASS,
			JOINT_BASE, SURF_GLASS)
	m.add_box(Vector3(-1.06, 2.22, -0.88), Vector3(1.72, 1.00, 0.06), GLASS,
			JOINT_BASE, SURF_GLASS)
	# Amber beacon on the ROPS.
	m.add_box(Vector3(-1.06, 3.00, 0.0), Vector3(0.22, 0.26, 0.22), AMBER,
			JOINT_BASE, SURF_BEACON)
	# Rear ripper — three shanks. A dozer that only ever pushes reads as half a
	# machine, and the shanks are what fill the back of the silhouette.
	m.add_box(Vector3(-2.86, 1.10, 0.0), Vector3(0.60, 0.70, 2.00), STEEL, JOINT_BASE)
	for i in 3:
		var rz := (float(i) - 1.0) * 0.78
		m.add_taper(Vector3(-2.94, 1.20, rz), Vector3(-3.30, 0.16, rz),
				0.22, 0.13, STEEL, JOINT_BASE)

	# ---- joint 1: the blade (lifts about +Z at DOZ_BLADE_PIVOT) ----------
	# Push arms first: they run from the track frames forward to the blade, and
	# they swing WITH it, which is what a lift actually looks like.
	for sz2: float in [1.0, -1.0]:
		m.add_taper(Vector3(-0.30, 0.86, sz2 * 1.24), DOZ_BLADE_PIVOT
				+ Vector3(0.30, -0.34, sz2 * 1.24), 0.28, 0.22, STEEL, JOINT_1)
	# The moldboard: a curled plate, extruded across the machine. The CURL is
	# what makes a blade a blade — a flat plate at this size is a fence panel.
	var b := DOZ_BLADE_PIVOT
	m.add_extrusion(PackedVector2Array([
			Vector2(b.x + 0.60, b.y - 1.18), Vector2(b.x + 1.02, b.y - 1.14),
			Vector2(b.x + 1.06, b.y - 0.52), Vector2(b.x + 0.86, b.y + 0.34),
			Vector2(b.x + 0.52, b.y + 0.62), Vector2(b.x + 0.30, b.y + 0.58),
			Vector2(b.x + 0.58, b.y - 0.30)]),
			-2.30, 2.30, PAINT, JOINT_1)
	# Cutting edge and the two end bits, in worn steel rather than paint.
	m.add_box(Vector3(b.x + 0.84, b.y - 1.20, 0.0), Vector3(0.46, 0.16, 4.60),
			CHROME, JOINT_1)
	for sz3: float in [1.0, -1.0]:
		m.add_box(Vector3(b.x + 0.72, b.y - 0.30, sz3 * 2.34),
				Vector3(0.70, 1.86, 0.10), STEEL, JOINT_1)
	# Blade tilt ram, off the hood to the moldboard's back.
	m.add_taper(Vector3(0.30, 1.86, 0.62), Vector3(b.x + 0.36, b.y + 0.30, 0.62),
			0.20, 0.15, CHROME, JOINT_1)
	return m


# ------------------------------------------------------------------- the paver

const PAV_SCREED_PIVOT := Vector3(-1.86, 1.02, 0.0)
## Screed float, radians about +Z. A screed rides the mat and breathes a couple
## of degrees; more than this and it reads as broken rather than as working.
const PAV_SCREED_RANGE := Vector2(-0.09, 0.05)
const PAV_TOP_M := 3.30
const PAV_LENGTH_M := 7.00


## The paver — hopper forward, tracks under, screed trailing, ~300 tris.
##
## It reads by its PROFILE and not by its detail: a wide open hopper at the front
## and a flat plate dragging at the back, with the operator's canopy between
## them. That is the shape of a machine laying a surface, and it is the shape
## that lets the strip appearing behind it be read as its doing.
##
## The same body is the KERB machine in FINAL_DEVELOPMENT. A slipform kerb
## machine really is a paver that extrudes a smaller section, and the view draws
## it at 0.72 scale in the kerb livery rather than authoring a fourth body for
## eight seconds of a phase.
static func paver() -> LandMachineMesh:
	var m := LandMachineMesh.new()

	# ---- joint 0: tracks, body, hopper, canopy ---------------------------
	var crawler := PackedVector2Array([
		Vector2(-1.62, 0.18), Vector2(-1.22, 0.00), Vector2(1.22, 0.00),
		Vector2(1.62, 0.18), Vector2(1.62, 0.72), Vector2(-1.62, 0.72)])
	for sz: float in [1.0, -1.0]:
		var z := sz * 1.12
		m.add_extrusion(crawler, z - 0.26, z + 0.26, DARK, JOINT_BASE)
		m.add_box(Vector3(0.0, 0.07, z), Vector3(2.30, 0.14, 0.58), STEEL, JOINT_BASE)
	# Main frame and the conveyor tunnel running back from the hopper.
	m.add_box(Vector3(0.20, 0.94, 0.0), Vector3(4.20, 0.52, 2.06), PAINT, JOINT_BASE)
	m.add_box(Vector3(0.10, 1.32, 0.0), Vector3(3.20, 0.28, 0.90), DARK, JOINT_BASE)
	# The hopper: two flared wings over the front, which is the one silhouette
	# nothing else on a site has.
	for sz2: float in [1.0, -1.0]:
		m.add_extrusion(PackedVector2Array([
				Vector2(1.72, 1.16), Vector2(3.36, 1.16), Vector2(3.36, 2.06),
				Vector2(1.72, 1.78)]), sz2 * 0.22, sz2 * 1.44, PAINT, JOINT_BASE)
	m.add_box(Vector3(2.54, 1.14, 0.0), Vector3(1.72, 0.14, 0.60), STEEL, JOINT_BASE)
	# Push roller at the very front — what the feed lorry backs onto.
	m.add_extrusion(PackedVector2Array([
			Vector2(3.46, 0.30), Vector2(3.76, 0.30), Vector2(3.76, 0.72),
			Vector2(3.46, 0.72)]), -1.00, 1.00, GREASE, JOINT_BASE)
	# Operator's platform and canopy: two posts and a roof, no glass. A paver
	# cab is open, and the gap under the roof is a strong read at distance.
	m.add_box(Vector3(-0.66, 1.30, 0.0), Vector3(1.30, 0.24, 2.10), STEEL, JOINT_BASE)
	for sz3: float in [1.0, -1.0]:
		m.add_beam(Vector3(-0.30, 1.42, sz3 * 0.94), Vector3(-0.30, 2.72, sz3 * 0.94),
				0.11, STEEL, JOINT_BASE)
		m.add_beam(Vector3(-1.14, 1.42, sz3 * 0.94), Vector3(-1.14, 2.72, sz3 * 0.94),
				0.11, STEEL, JOINT_BASE)
	m.add_box(Vector3(-0.72, 2.80, 0.0), Vector3(1.90, 0.14, 2.30), PAINT, JOINT_BASE)
	m.add_box(Vector3(-0.72, 3.00, 0.0), Vector3(0.24, 0.26, 0.24), AMBER,
			JOINT_BASE, SURF_BEACON)

	# ---- joint 1: the screed (floats about +Z at PAV_SCREED_PIVOT) -------
	var s := PAV_SCREED_PIVOT
	# Tow arms from the frame back to the screed.
	for sz4: float in [1.0, -1.0]:
		m.add_taper(Vector3(0.10, 1.02, sz4 * 0.92), Vector3(s.x + 0.30, s.y, sz4 * 1.06),
				0.20, 0.16, STEEL, JOINT_1)
	# Screed plate and its end gates — full paving width, which is wider than
	# the machine and is what makes the mat behind it look laid rather than
	# driven over.
	m.add_box(Vector3(s.x - 0.34, s.y - 0.62, 0.0), Vector3(1.34, 0.20, 3.20),
			CHROME, JOINT_1)
	m.add_box(Vector3(s.x - 0.34, s.y - 0.14, 0.0), Vector3(1.20, 0.80, 2.96),
			PAINT, JOINT_1)
	for sz5: float in [1.0, -1.0]:
		m.add_box(Vector3(s.x - 0.34, s.y - 0.36, sz5 * 1.56),
				Vector3(1.20, 0.56, 0.10), STEEL, JOINT_1)
	# The walkway the screed men stand on.
	m.add_box(Vector3(s.x - 1.10, s.y + 0.06, 0.0), Vector3(0.62, 0.10, 3.00),
			STEEL, JOINT_1)
	return m


# ------------------------------------------------------------------ the roller

## The drum's axle. `rot_z` about this point IS the drum turning, which is why
## the roller spends its one joint on a full revolution rather than on a hinge.
const ROL_DRUM_PIVOT := Vector3(1.72, 0.82, 0.0)
const ROL_DRUM_R := 0.82
## A whole turn. The view feeds `fract(distance / circumference)` into the
## channel, so the drum turns with the ground it has covered rather than with
## the wall clock — a roller that spins while parked is the tell that a layer is
## animating a number instead of a machine.
const ROL_DRUM_RANGE := Vector2(0.0, TAU)
const ROL_TOP_M := 3.16
const ROL_LENGTH_M := 5.80
## Sides on the drum. Fourteen is where the silhouette stops reading as a
## polygon at 150 m and the lagging bars still catch the light one at a time.
const ROL_DRUM_SIDES := 14


## The single-drum compactor — smooth drum forward, rubber-tyred rear, ~260 tris.
static func roller() -> LandMachineMesh:
	var m := LandMachineMesh.new()

	# ---- joint 0: rear frame, wheels, cab -------------------------------
	for sz: float in [1.0, -1.0]:
		var z := sz * 0.92
		m.add_box(Vector3(-1.66, 0.72, z), Vector3(1.44, 1.44, 0.52), TYRE, JOINT_BASE)
	m.add_box(Vector3(-1.10, 1.16, 0.0), Vector3(2.90, 0.62, 2.06), PAINT, JOINT_BASE)
	# Engine deck behind the operator.
	m.add_extrusion(PackedVector2Array([
			Vector2(-2.70, 1.42), Vector2(-1.30, 1.42), Vector2(-1.30, 2.06),
			Vector2(-2.70, 1.90)]), -0.94, 0.94, PAINT, JOINT_BASE)
	# The articulation hitch: a roller bends in the middle, and the waist is
	# what tells it apart from a tractor at any distance.
	m.add_box(Vector3(0.34, 1.06, 0.0), Vector3(1.36, 0.46, 0.80), STEEL, JOINT_BASE)
	m.add_box(Vector3(0.98, 1.02, 0.0), Vector3(0.30, 0.66, 0.44), GREASE, JOINT_BASE)
	# Drum yoke reaching forward over the axle.
	for sz2: float in [1.0, -1.0]:
		m.add_taper(Vector3(0.62, 1.10, sz2 * 0.34),
				Vector3(ROL_DRUM_PIVOT.x, ROL_DRUM_PIVOT.y, sz2 * 1.16),
				0.30, 0.24, STEEL, JOINT_BASE)
	# ROPS canopy and the beacon.
	for sz3: float in [1.0, -1.0]:
		m.add_beam(Vector3(-0.62, 1.44, sz3 * 0.86), Vector3(-0.62, 2.72, sz3 * 0.86),
				0.10, STEEL, JOINT_BASE)
		m.add_beam(Vector3(-1.62, 1.44, sz3 * 0.86), Vector3(-1.62, 2.72, sz3 * 0.86),
				0.10, STEEL, JOINT_BASE)
	m.add_box(Vector3(-1.12, 2.78, 0.0), Vector3(1.60, 0.12, 2.00), PAINT, JOINT_BASE)
	m.add_box(Vector3(-1.12, 2.98, 0.0), Vector3(0.22, 0.24, 0.22), AMBER,
			JOINT_BASE, SURF_BEACON)
	# Seat and console, so the canopy is not empty at the angle the camera takes.
	m.add_box(Vector3(-1.02, 1.62, 0.0), Vector3(0.50, 0.60, 0.60), DARK, JOINT_BASE)

	# ---- joint 1: the drum (rolls about +Z at ROL_DRUM_PIVOT) ------------
	var p := ROL_DRUM_PIVOT
	var ring := PackedVector2Array()
	for i in ROL_DRUM_SIDES:
		var a := TAU * float(i) / float(ROL_DRUM_SIDES)
		ring.append(Vector2(p.x + cos(a) * ROL_DRUM_R, p.y + sin(a) * ROL_DRUM_R))
	m.add_extrusion(ring, -1.08, 1.08, PAINT, JOINT_1)
	# Lagging bars, four of them, proud of the shell. Nothing else on this
	# machine can show that the drum is turning: a smooth cylinder rotating
	# about its own axis is a still frame.
	for i in 4:
		var a2 := TAU * float(i) / 4.0
		m.add_box(Vector3(p.x + cos(a2) * (ROL_DRUM_R + 0.03),
				p.y + sin(a2) * (ROL_DRUM_R + 0.03), 0.0),
				Vector3(0.16, 0.16, 2.10), DARK, JOINT_1)
	# End plates, so the drum has a rim rather than an open pipe end.
	for sz4: float in [1.0, -1.0]:
		m.add_extrusion(ring, sz4 * 1.08, sz4 * 1.16, STEEL, JOINT_1)
	return m
