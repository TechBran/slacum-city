extends SceneTree
## Render-frame profiler — doc 11 §2.13's table, measured instead of predicted.
##
## `tools/profile_sim.gd` answers "what does a sim step cost?"; this answers the
## other half: **what does a FRAME cost, at each of §2.5's three camera poses,
## on a real city?** It boots a `CitySim` from a city file (doc 09 §2.13's
## benchmark fixture by default), assembles the same render stack `game/main.gd`
## assembles — `RenderStateModel` + `CityView` + `RoadSurfaceView` +
## `StreetlightView` + `VehicleView` + `EnvironmentController` + `CameraRig`,
## with the lamps placed by `StreetlightPlacer` — parks the camera at
## Z0 / Z1 / Z2 in turn, and reports CPU render time, GPU render time, draw
## calls, primitives and the chunk-tier census at each.
##
## It is a MEASURING instrument (constitution §3): it owns no constant, reads
## every threshold from `data/render.json`, and nothing in `sim/` or `game/`
## imports it.
##
## WHAT IT DELIBERATELY DOES NOT BUILD: the UI `CanvasLayer`. Doc 11 §2.13
## budgets UI separately at ~25 batched CanvasItem calls, and mixing it in would
## make the city's own draw-call figure unreadable. Add 25 to the `dc` column to
## compare against the 320 budget; the table prints both.
##
## Usage (needs a display — this renders):
##   ~/.local/bin/godot --path "/home/bbx/Slacum City game" \
##       -s res://tools/profile_frame.gd -- [options]
##
##   --city=PATH        city file (default res://tests/fixtures/bench_city.json)
##   --preset=NAME      performance | balanced | high      (default balanced)
##   --hour=H           hour of day, 0..24                 (default 21 — night,
##                      the emissive/glow worst case)
##   --poses=z0,z1,z2   which §2.5 poses to measure        (default all three)
##                      A token `t0.65` is a pose at that `zoom_t` (Wave 17: the
##                      tilt screenshots frame a 180 m tower from a zoom the
##                      three named poses do not have)
##   --warmup=N         frames discarded per pose          (default 90)
##   --frames=N         frames measured per pose           (default 180)
##   --resolution=WxH   render size                        (default 1920x1080)
##   --out=FILE         write the run as JSON
##   --shots=DIR        save one PNG per pose into DIR (`<pose>.png`)
##   --focus=TX,TZ      aim the poses at this TILE instead of the city centre
##                      (Z0 sits 18 m off the focus, and the authored centre can
##                      put that camera inside a tower). **GLOBAL tiles.** A city
##                      fixture's building `origin` is CORE-LOCAL and
##                      `StarterCityLoader.core_to_global` adds
##                      `CORE_TILE_OFFSET = 32` to each axis, so aiming at a
##                      building read out of the JSON means `origin + 32`. Wave
##                      18 lost a screenshot to that (report 98 §54.5).
##   --atlas-lod=N      cut the merged MEDIUM atlas from LOD N instead of
##                      `CityView.atlas_lod`. 0 keeps the un-merged tier's
##                      picture exactly; 1 is §2.5's ladder and costs the
##                      commercial banding — the A/B behind that ruling.
##   --no-power-infra   leave the visible power layer (`PowerInfraView`) out.
##                      The A/B behind its §2.13 draw-call claim: the two runs
##                      differ in nothing else, so the `dc` delta IS the layer.
##   --power-distress=F force this fraction of the transformer roster into the
##                      SEVERE band (0..1) before measuring, so the smoke and
##                      spark buffer is exercised rather than assumed absent.
##                      Render-side only — the sim is not touched.
##   --no-lod           draw EVERY chunk at LOD0 — `CityView.lod_enabled = false`,
##                      the showcase's flag of the same name. The reference arm
##                      of the LOD-pop sweep: a pixel diff against the shipped
##                      ladder at Z1 IS the pop, and nothing else differs.
##   --no-merge         draw the pre-D-14 renderer: one MultiMesh per
##                      (chunk, archetype, level) at MEDIUM, instead of the
##                      merged per-archetype atlas. The A/B switch the
##                      §2.13 as-shipped table's before column is measured with,
##                      and — with `--shots` — the one the "no visible pop"
##                      claim is checked with, since the two runs differ in
##                      nothing else.
##   --sites=N          stand N LIVING CONSTRUCTION sites (doc 11 §2.16) on the
##                      N buildings nearest the city centre and drive
##                      `ConstructionVehicleView` every frame, so the layer's
##                      draw-call and frame cost can be A/B'd against
##                      `--sites=0`. It deliberately does NOT build
##                      `ConstructionSiteView`'s hoarding and cranes: those are
##                      four nodes per site and would bury the figure this flag
##                      exists to read.
##   --site-stage=S     stage 1..6 every `--sites` site is held at (default 2)
##   --street-life=N    stand N STREET LIFE opportunities (doc 11 §2.17) on the
##                      road tiles nearest the focus and drive `StreetLifeView`
##                      every frame, so the layer's draw-call and CPU cost can be
##                      A/B'd against `--street-life=0`. The two runs differ in
##                      nothing else, so the `dc` delta IS the layer.
##   --street-collect=F collect one of them every F frames and immediately spawn
##                      a replacement, so the measured frames always carry a
##                      poof and a rising `+$N` (0 = never, the quiet case).
##                      This is the WORST frame the layer has: every marker,
##                      every burst and every label the caps allow, at once.
##   --street-gm=M      PIN the street layer's wander clock to game-minute M
##                      every frame, so two runs put every body in exactly the
##                      same part of its beat. Without it the wander advances
##                      with the real frame delta and a pixel A/B of two
##                      `--shots` runs measures the frame rate, not the change.
##   --traffic=N        stand N CIVILIAN vehicles on the road tiles nearest the
##                      focus, ids chosen so the run walks `VehicleView`'s whole
##                      paint palette once before repeating. The harness builds
##                      no UI layer, so this is the only place the fleet's livery
##                      can be judged with nothing on top of it (A91-D-36).
##   --units=N          the same for EMERGENCY units, one per department in
##                      rotation, all RESPONDING (bars up, lamps on).
##   --anim-step=S      hand the three ANIMATED render layers a FIXED per-frame
##                      delta of S seconds instead of the real one, so their
##                      `anim_time` after N frames is exactly `N·S` and two runs
##                      of the same command put every light bar, every beacon
##                      sweep, every dig cycle and every marker pulse in the
##                      same phase. `--street-gm` pins the street layer's WANDER
##                      and not its `anim_time`, and nothing pinned the other
##                      two at all, so a whole-frame pixel A/B of the vehicle or
##                      construction layer measured the frame rate — two
##                      identical free-running runs differ on 0.28 % of a Z1
##                      frame, peak 154/255, which is the 2.2 Hz light bar and
##                      the beacon sweep (report 98 RR-95). Use 0.016667 for a
##                      60 Hz-shaped beat; -1 (the default) is free-running and
##                      is what every published timing row was measured with.
##   --quiet-layers     build `ConstructionVehicleView` AND `StreetLifeView`
##                      with NOTHING in them — no sites, no opportunities. The
##                      QUIET CITY: the third case, between "the layer is busy"
##                      and "the layer is absent", and the one report 98 RR-83's
##                      corollary is about. A/B it against a run with neither
##                      flag and the `dc` delta is what empty buffers cost.
##   --street-shot-lag=N  collect EVERY live opportunity exactly N frames before
##                      each pose's capture, so `--shots` lands on a chosen
##                      moment of the leaving animation instead of on whatever
##                      `--street-collect`'s rotation happened to leave there.
##                      The A/B instrument for §2.17's crook flee: one run at a
##                      lag inside the dash, one past it at the cuff.
##   --blob=0|1         force doc 11 §2.11's per-building contact decal
##                      (`MM_blob`) on or off, instead of taking it from
##                      `blob_shadow.enabled_presets`. The A/B behind that
##                      layer's draw-call and fill claim — the two runs differ in
##                      nothing else, so the `dc`, `prims` and `rs gpu` deltas
##                      ARE the layer. Default: whatever the JSON says for the
##                      preset under test.
##   --pad-shadows=0|1  whether the transformer pad buffer casts into the sun's
##                      shadow pass (default: whatever `data/render.json`'s
##                      `power_infra.pad_shadows` says). The A/B behind that
##                      knob's shipped default — the two runs differ in nothing
##                      else, so the `rs gpu` delta IS the pad shadow pass.
##   --flood=MM         stand doc 07 §2.4's STANDING WATER MM millimetres deep on
##                      every LOW land block and draw it with `FloodView`
##                      (doc 11 §2.9b). 0 leaves the layer out entirely, which
##                      is the A/B control: the two runs differ in nothing else,
##                      so the `dc` and `rs gpu` deltas ARE the flood layer.
##                      350 is doc 07's impassable band — the worst case, every
##                      road tile on every low block fully covered.
##   --flood-detail=N   force `flood.gdshader`'s fragment ladder to rung N
##                      (2 ripple + puddle noise, 1 puddle noise only, 0 a flat
##                      sheet) instead of the preset's ceiling. Same geometry,
##                      same draw calls, same everything but the fragment
##                      program — which is the A/B the Fold's fragment-bound
##                      frame actually needs.
##   --road-tint=K      multiply §2.1.2's carriageway tint by K, in LINEAR, and
##                      change NOTHING else. The A/B arm behind the street-body
##                      blob's visibility question (report 98 RR-97, doc 93 §X3):
##                      that shadow is a `blend_mix` decal, so it darkens what is
##                      behind it by a FRACTION, and the carriageway sits near
##                      0.02 linear — the lever is the ROAD, not the alpha.
##                      1.0 is the shipped street and is byte-identical to a run
##                      without the flag. NOT A SETTING: the ruling it feeds is
##                      device-gated and is not taken on a desktop.
##   --road-detail=N    force `road_surface.gdshader`'s fragment ladder to rung
##                      N (2 full, 1 no wear, 0 also no zebra) instead of the
##                      preset's ceiling. The A/B behind the asphalt fragment
##                      cost: same geometry, same draw calls, same everything
##                      but the fragment program.
##   --no-quality       do NOT apply doc 11 §2.13b's engine-side preset keys
##                      (`render_scale`, `msaa`, `fxaa`, the shadow atlas, the
##                      sun's split count and distance, glow levels and HDR
##                      thresholds). Every §2.13 row published before Wave 17
##                      was measured this way, because before Wave 17 nothing
##                      in the tree applied them — so this is the flag that
##                      reproduces the old numbers, and a run WITHOUT it is
##                      what the preset the player picked actually costs.
##   --pitch=DEG        PIN the camera pitch to DEG at every pose instead of
##                      taking §2.5's zoom-coupled band (34 deg at Z0 ramping
##                      to 62 at Z2). This is how a MANUAL pitch — a floor the
##                      player holds while zooming out — is measured, since
##                      `CameraState.pitch_deg_at()` is a pure function of
##                      `zoom_t` and has no other expression. Distance, focus
##                      and yaw are unchanged, so a `--pitch=34` Z2 run is the
##                      Z2 pose seen from a camera that is not looking down.
##   --aim=0|1          Wave 18 (doc 98 §54): force the AIM-HEIGHT RAMP off (0) or
##                      on (1). `--aim=0` clamps `aim_up_anchor_ndc` to 0, i.e.
##                      "the pan anchor may not leave the view axis", which is
##                      the pre-Wave-18 rig exactly — the camera looks at the
##                      focus and no bias lifts it. This is the A/B arm doc 92
##                      §53's before/after table is taken with; it changes no
##                      code path, only the authored guard.
##   --pitch-cull=0|1   force §2.5b's pitch-coupled `far_cull_m` off (0) or on
##                      (1), instead of taking it from `lod.pitch_cull`. The
##                      A/B behind that ruling: the two runs differ in nothing
##                      else, so the `dc` delta IS the cull (report 98 RR-98).
##   --far-cull=M       override the preset's `far_cull_m` with M metres. The
##                      one experiment it exists for: a cull ring LARGER than
##                      the city removes nothing, so bringing it inside the
##                      city is the only way to show the tier machinery
##                      responds to it (report 98 RR-98).
##   --far-relief=D     force §2.6b (2)'s day façade relief depth. 0 is the
##                      flat far tier that shipped before Wave 17; the
##                      modulation is zero-mean, so this is a STRUCTURE A/B
##                      that cannot move the tier's level.
##   --far-gain=G       multiply §2.6b's measured per-family FAR palette by G.
##                      The sweep lever the boundary's level was checked with;
##                      the shipped value is identity and the shader carries
##                      why (`far_albedo_gain`).
##   --far-family=0|1   force §2.6b's per-family FAR albedo off (0) or leave it
##                      on (1 / default). 0 puts the pre-Wave-17 neutral grey
##                      back on the far tier and changes nothing else, so a
##                      pixel diff of the two `--shots` is exactly the colour
##                      the tier boundary used to step by.
##   --medium-max=M     force `RenderStateModel.medium_max_m` to M metres,
##                      CLAMPED to the preset's `far_cull_m`. The A/B arm
##                      behind §2.6b's tier-boundary fix: at a value past the
##                      cull ring every visible chunk is drawn by the NEAR
##                      shader with its real façade page, the two runs cull
##                      identically and differ in nothing else, so a pixel
##                      diff of the two `--shots` is exactly the FAR tier's
##                      footprint and the mean |Δ| over it is the size of the
##                      boundary's colour step. Without the clamp the second
##                      run un-culls chunks and measures a bigger city.
##   --site-gm=M        game-minute the construction layer's clock is wound to
##                      before the measured frames (default 900 — a dozen
##                      delivery cadences, so the yards are full and lorries
##                      are on the road; measuring a cold layer would measure
##                      the cheap case and call it the budget)
##   --tilt=DEG|auto    Wave 17 (doc 12 §2.23 / doc 92 §47): park the MANUAL pitch
##                      axis at DEG for every pose, through `CameraState.set_pitch_deg`
##                      — the same composition the slider and the two-finger
##                      gesture drive, so a row here is a pose a player can reach.
##                      `auto` (default) is the curve's own answer, i.e. every row
##                      this harness ever printed before the axis existed. The
##                      row label prints the pitch the rig actually used.
##   --yaw=DEG          the orbit yaw for every pose (default: the authored
##                      `default_yaw_deg`). The tilt screenshots need a facade
##                      square-on, which 45° never is.
##   --sky=gradient|procedural  Wave 17's gradient sky shader (default) or the
##                      engine's `ProceduralSkyMaterial` it replaces. The A/B behind
##                      doc 11 §2.8's sky cost: the two runs differ in nothing
##                      else, so the `rs gpu` delta IS the sky.
##   --quiet            table only
##
## The first pose absorbs shader compilation and the first MultiMesh uploads,
## which is why `--warmup` exists and why the table prints the warm figure only.

const CITY_DEFAULT := "res://tests/fixtures/bench_city.json"
const RENDER_JSON := "res://data/render.json"
const MESH_MANIFEST := "res://game/meshes/generated/manifest.json"

## §2.5's three published poses, as `zoom_t` values `CameraState` maps to
## (D, pitch). The names are doc 11's.
const POSES := {
	"z0": {"zoom_t": 0.0, "label": "Z0  D 18 m / 34°"},
	"z1": {"zoom_t": 0.5, "label": "Z1  D 86.9 m / 48°"},
	"z2": {"zoom_t": 1.0, "label": "Z2  D 420 m / 62°"},
}

## Doc 11 §2.13's non-chunk draw-call terms, for the "predicted" column. The
## harness does not draw the UI, so the comparison has to say so out loud.
const UI_DRAW_CALLS := 25

var _opts: Dictionary = {}
var _render_data: Dictionary = {}
var _sim: CitySim
var _model: RenderStateModel
var _city_view: CityView
var _roads: RoadSurfaceView
var _streetlights: StreetlightView
var _vehicles: VehicleView
var _construction: ConstructionVehicleView
var _street: StreetLifeView
var _flood: FloodView
var _construction_usec := 0
var _street_usec := 0
## Round-robin cursor and id allocator for `--street-collect`.
var _street_ids: Array[int] = []
var _street_tiles: Array[Vector2i] = []
var _street_cursor := 0
var _street_next_id := 1
var _street_frames := 0
var _env: EnvironmentController
var _camera_state: CameraState
var _camera_rig: CameraRig
var _power_infra: PowerInfraView
var _family_of: Dictionary = {}
var _height_of: Dictionary = {}
## Set by `--power-distress=`: the render rows the harness feeds instead of the
## sim's, so the smoke/spark buffer can be measured without cooking the sim.
var _forced_rows: Array = []

## What the viewport actually came up at, as opposed to what `--resolution`
## asked for. Set on the first frame by `_verify_resolution`.
var _measured_resolution := Vector2i.ZERO

var _order: Array = []
## `POSES` plus any `t0.65`-style pose `--poses=` named, keyed like `POSES`.
var _pose_defs: Dictionary = {}
## The label printed per pose, built from the rig at `_apply_pose` so a `--tilt`
## row says what pitch it measured rather than the curve's.
var _labels: Dictionary = {}
var _pose_index := 0
var _frames_seen := 0
var _samples: Array = []
var _results: Array = []
var _started := false


func _initialize() -> void:
	_opts = _parse(OS.get_cmdline_user_args())
	if _opts.has("error"):
		printerr("profile_frame: " + String(_opts["error"]))
		quit(2)
		return
	_render_data = StarterCityLoader.read_json(RENDER_JSON)
	if _render_data.is_empty():
		printerr("profile_frame: cannot read " + RENDER_JSON)
		quit(2)
		return
	if not FileAccess.file_exists(String(_opts["city"])):
		printerr("profile_frame: no such city file " + String(_opts["city"]))
		quit(2)
		return

	_sim = CitySim.new()
	_sim.boot(1337,
			StarterCityLoader.read_json("res://data/time.json"),
			StarterCityLoader.read_json(String(_opts["city"])),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	if not _sim.boot_errors.is_empty():
		for message in _sim.boot_errors:
			printerr("profile_frame: boot error: " + String(message))

	# `--resolution` has to go through the DISPLAY SERVER, not through `root.size`
	# alone. Setting the root Window's `size` in `_initialize` is silently undone
	# by the window that `[display] window/size/viewport_*` already created, so
	# every millisecond ever printed by this harness before 2026-08-20 was
	# measured at the project's 1280×720 while the header said 1920×1080 —
	# checked by dumping `--shots` and reading the PNG's dimensions, which came
	# back 1280×720 whatever `--resolution` asked for. Both calls are made, and
	# `_verify_resolution` on the first measured frame refuses to print a number
	# under a resolution it did not get.
	var size: Vector2i = _opts["resolution"]
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_size(size)
	root.size = size
	# `measure_render_time` is what makes the CPU/GPU columns real rather than
	# an estimate off the frame delta — without it the server returns 0.
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	# Without this every frame reads as exactly one refresh interval and the
	# mean/p95 columns measure the monitor instead of the renderer.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	if not bool(_opts["quiet"]):
		var pitch_note := ""
		if float(_opts["pitch"]) > 0.0:
			pitch_note = ", pitch PINNED %.0f deg" % float(_opts["pitch"])
		print("profile_frame: %s — %d buildings, preset %s, hour %.1f, %dx%d%s" % [
				String(_opts["city"]), _sim.buildings.size(), String(_opts["preset"]),
				float(_opts["hour"]), size.x, size.y, pitch_note])


# ---------------------------------------------------------------- the scene

func _build_scene() -> void:
	var stage := Node3D.new()
	stage.name = "ProfileStage"
	root.add_child(stage)

	# --- environment (sky, sun, moon, fog, glow) -------------------------
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	world_environment.environment = environment
	stage.add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	stage.add_child(sun)
	var moon := DirectionalLight3D.new()
	moon.shadow_enabled = false
	stage.add_child(moon)
	_env = EnvironmentController.new()
	# `--sky=`: the controller swaps the engine sky for the gradient shader in
	# `setup()` unless told to keep it, which is the A/B this flag exists for.
	_env.use_gradient_sky = String(_opts["sky"]) != "procedural"
	stage.add_child(_env)
	_env.world_environment_path = world_environment.get_path()
	_env.sun_path = sun.get_path()
	_env.moon_path = moon.get_path()
	_env.setup(_render_data)

	# --- ground, roads, water -------------------------------------------
	_build_ground(stage)

	# --- the city ---------------------------------------------------------
	# §2.13b: the preset's ENGINE-side half — `render_scale`, MSAA, FXAA, the
	# shadow atlas, glow and the sun's shadow mode. Applied here for the same
	# reason every other preset key is: this harness measures what the game
	# draws, and until Wave 17 the game drew all three presets at scale 1.0
	# with no MSAA and Balanced's bloom, so every published row in §2.13 was
	# measured on a frame no preset actually asks for. `--no-quality`
	# reproduces those rows exactly.
	if not bool(_opts["no_quality"]):
		var q := QualityApplier.resolve(_render_data, String(_opts["preset"]))
		QualityApplier.apply_viewport(root, q)
		_env.apply_quality(q)

	_model = RenderStateModel.new(_render_data, String(_opts["preset"]))
	# §2.6b's A/B arm: push the MEDIUM/FAR boundary past the cull distance and
	# every chunk the camera can see is drawn by the NEAR shader with its real
	# façade page. The two runs differ in NOTHING else, so a pixel diff of the
	# two `--shots` is exactly the FAR tier's footprint and the mean |Δ| over
	# it is the size of the tier-boundary step (report 98 RR-98).
	#
	# CLAMPED TO `far_cull_m`, and the clamp is the whole reason the A/B is
	# legal. `RenderStateModel.raw_tier` tests `medium_max_m` BEFORE
	# `far_cull_m`, so a boundary pushed past the cull distance does not just
	# promote FAR chunks to MEDIUM — it UN-CULLS chunks beyond the cull ring
	# and the second run draws a bigger city than the first. Clamped, the two
	# runs cull identically and differ only in which shader drew what.
	if float(_opts["medium_max"]) > 0.0:
		_model.medium_max_m = minf(float(_opts["medium_max"]), _model.far_cull_m)
	# §2.5b's A/B arm. `--pitch-cull=0` disarms the pitch-coupled cull and
	# leaves `far_cull_m` standing at the preset's authored value, which is what
	# every pose in §2.13 was measured against before this wave.
	if int(_opts["pitch_cull"]) >= 0:
		_model.pitch_cull_enabled = int(_opts["pitch_cull"]) == 1
	# `--far-cull=M` overrides the preset's cull ring outright. It exists for
	# ONE experiment and the doc says so rather than leaving it to be guessed:
	# `far_cull_m` cannot be shown to have leverage on a city SMALLER than the
	# ring, so the only way to prove the tier machinery responds to it at all —
	# and therefore that §2.5b would bite on a city that is big enough — is to
	# bring the ring inside the city and watch the census move (report 98
	# RR-98). It is not a preset knob and nothing in `game/` reads it.
	if float(_opts["far_cull"]) > 0.0:
		_model.far_cull_m = float(_opts["far_cull"])
		_model.preset_far_cull_m = _model.far_cull_m
		_model.active_far_cull_m = _model.far_cull_m
	var manifest: Dictionary = StarterCityLoader.read_json(MESH_MANIFEST)
	for entry in manifest.get("meshes", []):
		_family_of[String(entry["archetype"])] = String(entry.get("family", "residential"))
		if int(entry.get("lod", 0)) == 0:
			_height_of["%s:%d" % [entry["archetype"], int(entry["level"])]] = \
					float(entry.get("height_m", 10.0))
	for id in _sim.buildings.keys():
		_model.add_building(_building_view(String(id)))
	_city_view = CityView.new()
	_city_view.medium_merge_enabled = not bool(_opts["no_merge"])
	_city_view.lod_enabled = not bool(_opts["no_lod"])
	if int(_opts["atlas_lod"]) >= 0:
		_city_view.atlas_lod = int(_opts["atlas_lod"])
	# Set BEFORE `setup`, so the very first `_upload_all` is already on the arm
	# under test and no frame of the other one lands in the warm-up.
	_city_view.blob_override = int(_opts["blob"])
	# §2.6b (2)'s A/B arm: 0 is the flat far tier, the authored row is 0.55.
	_city_view.far_relief_override = float(_opts["far_relief"])
	# §2.6b's A/B arm, set before `setup` for the same reason `blob_override`
	# is: the first `_upload_all` must already be on the arm under test.
	_city_view.far_family_override = int(_opts["far_family"])
	if float(_opts["far_gain"]) >= 0.0:
		_city_view.far_gain_override = float(_opts["far_gain"])
	stage.add_child(_city_view)
	_city_view.setup(_model, _render_data)

	# doc 11 §2.10's art density, off the road graph: one lamp every
	# `road_surface.lamp.spacing_tiles` along a corridor, standing ON the kerb
	# and facing the carriageway. Deliberately NOT doc 04's one-per-road-tile
	# electrical sink.
	var lamps := StreetlightPlacer.place(_sim.world.grid,
			_sim.roads.graph if _sim.roads != null else null, _render_data,
			_sim.world.block_of_tile)
	_streetlights = StreetlightView.new()
	stage.add_child(_streetlights)
	_streetlights.setup(_model, _render_data, lamps)
	# §2.13's `street_lights` — the per-chunk pool/smear cap. Seeded from the
	# preset like every other view's, so the harness measures the fill the
	# preset under test actually asks for (report 98 RR-98).
	_streetlights.set_preset(String(_opts["preset"]), _render_data)

	_vehicles = VehicleView.new()
	stage.add_child(_vehicles)
	_vehicles.setup(_render_data)
	_vehicles.set_preset(String(_opts["preset"]), _render_data)
	if int(_opts["traffic"]) > 0 or int(_opts["units"]) > 0:
		_stand_up_traffic(int(_opts["traffic"]), int(_opts["units"]))

	# --- the visible power layer (doc 04's distribution end, drawn) --------
	# Built exactly the way `game/main.gd` builds it, so the `dc` column below
	# is the shipped shape and not a harness-only arrangement.
	if not bool(_opts["no_power_infra"]):
		_power_infra = PowerInfraView.new()
		stage.add_child(_power_infra)
		_power_infra.setup(_render_data, func(archetype: StringName, level: int) -> float:
				return float(_height_of.get("%s:%d" % [archetype, level], 10.0)))
		_power_infra.set_road_probe(PowerInfraFeed.road_probe(_sim.world))
		_power_infra.sync(_sim, 0.0, Vector3.ZERO)
		if int(_opts["pad_shadows"]) >= 0:
			_power_infra.set_pad_shadows(int(_opts["pad_shadows"]) == 1)
		_force_distress(float(_opts["power_distress"]))
	# `--quiet-layers` builds BOTH optional layers and stands NOTHING in them.
	# That is the case RR-83's corollary is about and the only one that could not
	# be measured before it existed: with `--sites=0` the layer was not built at
	# all, so the harness could price a BUSY construction yard and an ABSENT one
	# and never the third thing a real city spends most of its life in — the
	# layer present, every buffer empty, every node still submitting.
	var quiet_layers := bool(_opts["quiet_layers"])
	if int(_opts["street_life"]) > 0 or quiet_layers:
		# doc 11 §2.17. Same shape as `--sites`: a layer the shell drives, stood
		# up here so the `dc` delta against `--street-life=0` IS the layer.
		_street = StreetLifeView.new()
		stage.add_child(_street)
		_street.setup(_render_data)
		_street.set_preset(String(_opts["preset"]), _render_data)
		_street.set_road_probe(StreetLifeView.road_probe(_sim.world))
		if int(_opts["street_life"]) > 0:
			_stand_up_street_life(int(_opts["street_life"]))
	if int(_opts["sites"]) > 0 or quiet_layers:
		_construction = ConstructionVehicleView.new()
		stage.add_child(_construction)
		_construction.setup(_render_data)
		_construction.set_preset(String(_opts["preset"]), _render_data)
		_construction.set_road_network(_sim.roads)
		if int(_opts["sites"]) > 0:
			_stand_up_sites(int(_opts["sites"]), int(_opts["site_stage"]))

	# --- camera -----------------------------------------------------------
	_camera_state = CameraState.load_from_files()
	# `D_MAX_eff` is derived from the owned-land AABB (doc 12 §2.16), so a rig
	# that never learns the city's extent caps `zoom_t` below 1.0 and Z2 is
	# unreachable — the pose would silently be measured somewhere else.
	var min_xz := Vector2(INF, INF)
	var max_xz := Vector2(-INF, -INF)
	for block_id in _sim.world.block_ids_sorted():
		var block: LandBlock = _sim.world.block(block_id)
		if not block.is_ready():
			continue
		min_xz = Vector2(minf(min_xz.x, block.grid.x * 128.0),
				minf(min_xz.y, block.grid.y * 128.0))
		max_xz = Vector2(maxf(max_xz.x, block.grid.x * 128.0 + 128.0),
				maxf(max_xz.y, block.grid.y * 128.0 + 128.0))
	if min_xz.x < INF:
		_camera_state.set_owned_land_aabb(min_xz, max_xz)
	var centre: Array = (_sim.loader.world_header.get("city_center_tile", [56, 56]) as Array)
	var focus := Vector3(float(centre[0]) * 8.0, 0.0, float(centre[1]) * 8.0)
	var wanted: Vector2 = _opts["focus"]
	if wanted.x >= 0.0:
		focus = Vector3(wanted.x * 8.0, 0.0, wanted.y * 8.0)
	_camera_state.set_focus(focus)
	if is_finite(float(_opts["yaw"])):
		_camera_state.yaw = wrapf(deg_to_rad(float(_opts["yaw"])), -PI, PI)
	# §2.5's pitch is a pure function of `zoom_t` (34 deg at Z0 ramping to 62 at
	# Z2), so a MANUAL pitch — a floor the player holds while zooming out — has
	# no expression in `CameraState` at all. `--pitch=DEG` collapses the band to
	# a single value, which makes `pitch_deg_at(t)` constant and reproduces
	# exactly that: the same three §2.5 poses (same distance, same focus) seen
	# from a camera that is NOT looking as far down as the zoom asks for. This
	# is the harness half of report 98 RR-98's pitch-coupled cull, and it writes
	# to the profiler's own CameraState — nothing under `ui/` is touched.
	var pinned := float(_opts["pitch"])
	if pinned > 0.0:
		_camera_state.pitch_near_deg = pinned
		_camera_state.pitch_far_deg = pinned
	# `--aim=0`: WAVE 18's A/B arm. `aim_up_anchor_ndc = 0` says "the pan anchor
	# may not leave the view AXIS", which is exactly the pre-Wave-18 rig — the
	# camera looks at the focus and the ramp lifts nothing at any bias. It is a
	# clamp on the same authored guard rather than a second code path, so an
	# `--aim=0` row is the old composition measured by the new binary.
	if int(_opts["aim"]) >= 0:
		_camera_state.aim_up_anchor_ndc = 1.0 if int(_opts["aim"]) == 1 else 0.0
	_camera_rig = CameraRig.new()
	stage.add_child(_camera_rig)
	_camera_rig.setup(_camera_state, _render_data)


## The resolution the frame is ACTUALLY being rendered at, read back off the
## live viewport once the window is up. A fill-rate measurement whose pixel
## count is wrong is not a conservative measurement, it is a wrong one — so this
## says so loudly rather than letting the header's `--resolution` stand in for a
## size the window refused.
func _verify_resolution() -> void:
	var wanted: Vector2i = _opts["resolution"]
	var live: Vector2i = root.get_visible_rect().size
	_measured_resolution = live
	if live != wanted:
		printerr(("profile_frame: asked for %dx%d, the viewport is %dx%d — every ms"
				+ " column below is at the SECOND number") % [
				wanted.x, wanted.y, live.x, live.y])


## `--power-distress=F`: push the first `F` of the transformer roster (sorted, so
## the choice is reproducible) into doc 04's SEVERE band, RENDER-SIDE ONLY. The
## grid is not touched, no RNG is drawn and no state hash moves — the harness
## simply hands `PowerInfraView` a different set of read-only rows, which is what
## it would have got had those transformers actually been cooking.
func _force_distress(fraction: float) -> void:
	_forced_rows = []
	if _power_infra == null or fraction <= 0.0:
		return
	var rows: Array = PowerInfraFeed.state(_sim)
	var wanted := int(ceil(float(rows.size()) * fraction))
	for i in rows.size():
		var row: Dictionary = (rows[i] as Dictionary).duplicate()
		if i < wanted:
			row["state"] = "OK"
			row["energized"] = true
			row["load_ratio"] = PowerInfraModel.severe_ratio() + 0.25
			row["temp_c"] = 130.0
		_forced_rows.append(row)
	_power_infra.apply_state(_forced_rows)
	if not bool(_opts["quiet"]):
		print("profile_frame: forced %d/%d transformers into SEVERE"
				% [wanted, rows.size()])
## The N buildings nearest the city centre, turned into construction sites.
## Nearest-first so the sites land inside the camera's own focus and the
## measurement is of a layer that is actually being DRAWN.
func _stand_up_sites(count: int, stage_index: int) -> void:
	var centre_tile: Array = (_sim.loader.world_header.get(
			"city_center_tile", [56, 56]) as Array)
	var centre := Vector3(float(centre_tile[0]) * 8.0, 0.0, float(centre_tile[1]) * 8.0)
	var rows: Array = []
	for id in _sim.buildings.keys():
		var b: Building = _sim.buildings[String(id)]
		var record: Dictionary = _sim.building_record(String(id))  # PA-100
		var size: Vector2i = record["footprint"]
		var pos := Vector3(b.origin.x * 8.0 + size.x * 4.0, 0.0,
				b.origin.y * 8.0 + size.y * 4.0)
		rows.append({"id": b.id, "pos": pos, "size": size,
				"d": pos.distance_to(centre)})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(float(a["d"]) - float(b["d"])) > 0.01:
			return float(a["d"]) < float(b["d"])
		return int(a["id"]) < int(b["id"]))
	for i in mini(count, rows.size()):
		var row: Dictionary = rows[i]
		_construction.add_site(int(row["id"]), row["pos"], row["size"], 18.0)
		_construction.set_stage(int(row["id"]), stage_index)
	# Resolve every route before the first measured frame: the A* is a boot
	# cost, not a frame cost, and budgeting it as one would be a lie.
	for _step in count:
		_construction.refresh(0.0, 0.0, 0.0)
	# Then wind the layer's clock forward past a dozen delivery cadences, so the
	# measured frames have full yards and lorries on the road. A cold layer
	# would measure the cheap case and call it the budget.
	_construction.set_game_minutes(float(_opts["site_gm"]))


## `--traffic=N` / `--units=N`: stand N civilian vehicles and N emergency units
## on the road tiles nearest the focus and hold them there.
##
## The harness has always BUILT `VehicleView` and never fed it, so every picture
## it has ever taken was of an empty street — which is fine for a draw-call table
## and useless for the one thing report 98 A91-D-36 needs, which is a look at the
## LIVERY with no UI `CanvasLayer` over it. The ids are not 1..N: `VehicleView`
## picks a civilian's paint with `hash01(id, 91)`, so a run of consecutive ids
## lands wherever that hash happens to land and a ten-entry palette is judged off
## whichever four it drew. `_paint_ids` solves the hash instead — the lowest id
## that maps to each palette slot, in order — so the row of cars IS the palette,
## once each, left to right, and a screenshot of it is a contact sheet.
func _stand_up_traffic(count: int, units: int) -> void:
	var ranked := _road_tiles_near_focus()
	if ranked.is_empty():
		printerr("profile_frame: --traffic needs a road network")
		return
	var ids := _paint_ids(count)
	# Two tiles apart, not `ranked.size() / count`: the ranking spirals out from
	# the focus, so a proportional step on the benchmark city's 3,000 road tiles
	# puts the second car a kilometre from the first and the picture has one car
	# in it. Sixteen metres is a queue.
	var step := 2
	for i in count:
		var tile: Vector2i = ranked[mini(i * step, ranked.size() - 1)]
		# Heading along the road, taken off the next tile in the ranked run so a
		# car sits in a lane rather than across one.
		var next: Vector2i = ranked[mini(i * step + 1, ranked.size() - 1)]
		var d := next - tile
		var heading := 0.0 if d == Vector2i.ZERO \
				else atan2(float(d.y), float(d.x))
		_vehicles.apply_event({
			"type": "vehicle_spawned", "id": ids[i], "vehicle_class": "civilian",
			"kind": ["car", "car", "van", "car", "truck"][i % 5],
			"pos": Vector3(float(tile.x) * 8.0 + 4.0, 0.0, float(tile.y) * 8.0 + 4.0),
			"heading": heading, "speed": 0.0, "edge_id": -1,
			"headlights": true, "siren": false, "lightbar": false})
	if units <= 0:
		return
	const DEPT_TYPES := ["police_patrol", "fire_engine", "utility_service_truck",
			"water_repair_truck", "construction_crew_vehicle"]
	var states: Array = []
	for i in units:
		var tile: Vector2i = ranked[mini(count * step + i * step + 3, ranked.size() - 1)]
		states.append({
			"id": i + 1, "type": DEPT_TYPES[i % DEPT_TYPES.size()],
			"pos": [tile.x, tile.y], "heading": 0.0, "speed": 0.0,
			"status": "RESPONDING"})
	_vehicles.apply_unit_states(states)


## The lowest vehicle id that lands on each civilian paint slot, in slot order,
## then repeating. Solved rather than assumed — the hash is `VehicleView`'s, and
## a table of ids copied into this harness would rot the day it changes.
func _paint_ids(count: int) -> Array[int]:
	var slots := VehicleView.CIV_PAINT.size()
	var found: Array[int] = []
	found.resize(slots)
	found.fill(-1)
	var left := slots
	var id := 1
	while left > 0 and id < 100000:
		var slot := clampi(int(VehicleMotion.hash01(id, 91) * float(slots)), 0, slots - 1)
		if found[slot] < 0:
			found[slot] = id
			left -= 1
		id += 1
	var out: Array[int] = []
	for i in count:
		var pick: int = found[i % slots]
		# A slot the search never reached (impossible at the shipped palette, but
		# the loop is bounded) falls back to a plain id rather than to -1.
		out.append(pick if pick > 0 else i + 1)
	return out


## Every road tile, ranked by distance from the focus tile — the ordering both
## `--street-life` and `--traffic` place against, so the two layers land on the
## same stretch of street and one screenshot carries both.
func _road_tiles_near_focus() -> Array:
	var centre_tile: Array = (_sim.loader.world_header.get(
			"city_center_tile", [56, 56]) as Array)
	var focus_tile := Vector2(float(centre_tile[0]), float(centre_tile[1]))
	var wanted: Vector2 = _opts["focus"]
	if wanted.x >= 0.0:
		focus_tile = wanted
	var tiles: Array = _sim.roads.graph.road_tiles_sorted() if _sim.roads != null \
			else []
	if tiles.is_empty():
		return []
	var ranked: Array = tiles.duplicate()
	ranked.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := Vector2(float(a.x), float(a.y)).distance_squared_to(focus_tile)
		var db := Vector2(float(b.x), float(b.y)).distance_squared_to(focus_tile)
		if absf(da - db) > 0.01:
			return da < db
		if a.x != b.x:
			return a.x < b.x
		return a.y < b.y)
	return ranked


## The N road tiles nearest the focus, turned into opportunities — one of each
## kind in rotation, so all three bodies AND the stash sparkle are in the frame.
## Nearest-first for the same reason `--sites` is: a layer that is culled is a
## layer whose cost is zero, and measuring that is measuring nothing.
func _stand_up_street_life(count: int) -> void:
	var centre_tile: Array = (_sim.loader.world_header.get(
			"city_center_tile", [56, 56]) as Array)
	var focus_tile := Vector2(float(centre_tile[0]), float(centre_tile[1]))
	var wanted: Vector2 = _opts["focus"]
	if wanted.x >= 0.0:
		focus_tile = wanted
	var tiles: Array = _sim.roads.graph.road_tiles_sorted() if _sim.roads != null \
			else []
	if tiles.is_empty():
		printerr("profile_frame: --street-life needs a road network")
		return
	var ranked: Array = tiles.duplicate()
	ranked.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := Vector2(float(a.x), float(a.y)).distance_squared_to(focus_tile)
		var db := Vector2(float(b.x), float(b.y)).distance_squared_to(focus_tile)
		if absf(da - db) > 0.01:
			return da < db
		if a.x != b.x:
			return a.x < b.x
		return a.y < b.y)
	var kinds := ["crook", "dog", "goat", "valuables"]
	# Spread them a few tiles apart: four opportunities on one junction is not a
	# picture anyone has to draw, and not the one the layer is budgeted for.
	var step := maxi(1, ranked.size() / maxi(count * 3, 1))
	for i in mini(count, ranked.size()):
		var tile: Vector2i = ranked[mini(i * step, ranked.size() - 1)]
		_street_tiles.append(tile)
		_street_ids.append(_street_next_id)
		_street.feed_events([{"type": &"opportunity_spawned",
				"id": _street_next_id, "kind": kinds[i % kinds.size()],
				"tile": tile, "reward": 80 + i * 45}])
		_street_next_id += 1
	# Wind the wander past its own cycle so the measured frames catch bodies
	# mid-stride rather than all standing on their spawn waypoint.
	_street.set_game_minutes(37.0)


## One frame of the layer, plus `--street-collect`'s churn. Collecting and
## immediately respawning is what keeps a poof and a rising label in EVERY
## measured frame — the worst case, rather than the one-in-thirty a real cadence
## would happen to put in front of the camera.
func _drive_street_life(delta: float, camera_pos: Vector3) -> void:
	# `--street-shot-lag`: the whole roster is collected exactly N frames before
	# the capture, so the PNG lands on a chosen moment of the leaving animation.
	# Fired on one frame only — `==`, not `>=` — or every frame after it would
	# re-collect a roster that has already gone and the picture would never move.
	var lag := int(_opts["street_shot_lag"])
	if lag > 0 and _frames_seen == int(_opts["warmup"]) + int(_opts["frames"]) - lag:
		for id: int in _street_ids:
			_street.feed_events([{"type": &"opportunity_collected",
					"id": id, "reward": 120 + id * 20}])
	# `--street-gm=M` PINS the wander clock, which is what makes a street-life
	# screenshot A/B-able at all. Left free-running, the layer's game-minute
	# advances with the real frame delta, so two runs of the same command put the
	# bodies in different parts of their beat and a pixel diff of the two is
	# dominated by that rather than by whatever was being tested. Pinned, the
	# bodies are frozen mid-stride and the only difference between two runs is
	# the change under test.
	var pin := float(_opts["street_gm"])
	if pin >= 0.0:
		_street.set_game_minutes(pin)
	var every := int(_opts["street_collect"])
	if every > 0 and not _street_ids.is_empty():
		_street_frames += 1
		if _street_frames >= every:
			_street_frames = 0
			var slot := _street_cursor % _street_ids.size()
			var going: int = _street_ids[slot]
			var tile: Vector2i = _street_tiles[slot]
			_street.feed_events([{"type": &"opportunity_collected",
					"id": going, "reward": 120 + slot * 60}])
			_street_ids[slot] = _street_next_id
			_street.feed_events([{"type": &"opportunity_spawned",
					"id": _street_next_id,
					"kind": ["crook", "dog", "goat", "valuables"][slot % 4],
					"tile": tile, "reward": 80 + slot * 45}])
			_street_next_id += 1
			_street_cursor += 1
	_street.refresh(delta, _env.last_night, 1.0, -1.0, camera_pos)


func _build_ground(stage: Node3D) -> void:
	var ground := Node3D.new()
	ground.name = "Ground"
	stage.add_child(ground)
	var developed := GroundSurface.material("pavement", Vector2(128.0, 128.0),
			Color(0.52, 0.53, 0.52), 0.90)
	var undeveloped := GroundSurface.material("pavement", Vector2(128.0, 128.0),
			Color(0.40, 0.50, 0.36), 1.00)
	for block_id in _sim.world.block_ids_sorted():
		var block: LandBlock = _sim.world.block(block_id)
		var plane := MeshInstance3D.new()
		var mesh := PlaneMesh.new()
		mesh.size = Vector2(128.0, 128.0)
		plane.mesh = mesh
		plane.material_override = developed if block.is_ready() else undeveloped
		plane.position = Vector3(block.grid.x * 128.0 + 64.0, 0.0, block.grid.y * 128.0 + 64.0)
		ground.add_child(plane)

	# doc 11 §2.1.2's street: asphalt, markings, kerbs and footways off the road
	# GRAPH. Two draw calls city-wide, which is what the `dc` column has to see.
	_roads = RoadSurfaceView.new()
	_roads.name = "RoadSurface"
	ground.add_child(_roads)
	_roads.setup(_render_data)
	_roads.set_preset(String(_opts["preset"]), _render_data)
	if int(_opts["road_detail"]) >= 0:
		# Raise the ceiling first: `set_detail` clamps to it by contract, so a
		# harness asking for rung 2 on a preset capped at 1 must move the cap or
		# it would silently measure rung 1 and print "2".
		_roads.detail_ceiling = clampi(int(_opts["road_detail"]), 0, 2)
		_roads.set_detail(int(_opts["road_detail"]))
	# The look A/B arm. One uniform, no geometry, byte-identical at 1.0.
	if not is_equal_approx(float(_opts["road_tint"]), 1.0):
		_roads.set_tint_gain(float(_opts["road_tint"]))
	_roads.rebuild(_sim.world.grid, _sim.roads.graph if _sim.roads != null else null)

	var water_mm := MultiMesh.new()
	water_mm.transform_format = MultiMesh.TRANSFORM_3D
	var quad := PlaneMesh.new()
	quad.size = Vector2(8.0, 8.0)
	quad.material = GroundSurface.water()
	water_mm.mesh = quad
	water_mm.instance_count = _sim.loader.water_tiles.size()
	var wi := 0
	for pair in _sim.loader.water_tiles:
		var tile := StarterCityLoader.core_to_global(int(pair[0]), int(pair[1]))
		water_mm.set_instance_transform(wi, Transform3D(Basis.IDENTITY,
				Vector3(tile.x * 8.0 + 4.0, 0.08, tile.y * 8.0 + 4.0)))
		wi += 1
	var water_node := MultiMeshInstance3D.new()
	water_node.name = "Water"
	water_node.multimesh = water_mm
	ground.add_child(water_node)

	# doc 11 §2.9b / doc 07 §2.4's standing water. Off unless `--flood=` asks
	# for it, so the run with it and the run without differ in exactly this.
	if float(_opts["flood"]) > 0.0:
		_flood = FloodView.new()
		_flood.name = "Flood"
		ground.add_child(_flood)
		_flood.setup(_render_data, String(_opts["preset"]))
		if int(_opts["flood_detail"]) >= 0:
			# Raise the ceiling first: `set_detail` clamps to it by contract, so
			# a harness asking for rung 2 on a preset capped at 0 must move the
			# cap or it would silently measure rung 0 and print "2".
			_flood.detail_ceiling = clampi(int(_opts["flood_detail"]), 0, 2)
			_flood.set_detail(int(_opts["flood_detail"]))
		_flood.rebuild(_sim.world.grid)
		# Every LOW block, at the asked depth. This is the flood field the sim
		# would produce under sustained rain (doc 07 §2.4: only LOW blocks
		# accumulate) and the worst case the layer can be asked to draw.
		var depths: Dictionary = {}
		for block_id in _sim.world.block_ids_sorted():
			var block: LandBlock = _sim.world.block(String(block_id))
			if String(block.elevation_band()) != "LOW":
				continue
			depths[FloodField.block_key_of(block.grid.x, block.grid.y)] = \
					float(_opts["flood"])
		_flood.prime(depths)
		_flood.snap()
		print("  [flood] %d LOW cells at %.0f mm -> %d tiles, %d draw call(s), detail %d"
				% [depths.size(), float(_opts["flood"]), _flood.drawn_tiles(),
				_flood.draw_calls(), _flood.detail])


func _building_view(sim_id: String) -> Dictionary:
	var b: Building = _sim.buildings.get(sim_id)
	var record: Dictionary = _sim.building_record(sim_id)  # PA-100
	# The BUILT extent, not the record's reservation (Wave 29, doc 02 §2.3a):
	# `record["footprint"]` is the LOT now, and a mesh centred on it would sit
	# half a tile off the ground it stands on. See `construction_preview.gd`.
	var size := _sim.built_of_building(b)
	var centre := Vector3(b.origin.x * 8.0 + size.x * 4.0, 0.0,
			b.origin.y * 8.0 + size.y * 4.0)
	# Wave 31 (RR-254/RR-256): the doc-05 variant picks the SHAPE, and the built
	# extent is the guard that keeps a mesh inside its own ground. The draw-call
	# census below is measured over the buckets that split, so it has to be here.
	var shape := ShapeCatalog.shared().shape_of(
			StringName(b.archetype), StringName(b.variant))
	return {
		"id": b.id,
		"archetype_id": StringName(b.archetype),
		"variant_id": StringName(b.variant),
		"level": maxi(b.level, 1),
		"family": String(_family_of.get(String(shape), "residential")),
		"world_pos": centre,
		"built_tiles": size,
		"block_id": String(record.get("block", "")),
		"transform": Transform3D(Basis.IDENTITY, centre),
		"occ_b": 1.0,
		"powered": true,
		"condition": b.condition,
		"construction_stage": 0,
	}


# ------------------------------------------------------------------ the loop

func _apply_pose(index: int) -> void:
	_pose_index = index
	_frames_seen = 0
	_samples.clear()
	var key := String(_order[index])
	var wanted := float((_pose_defs[key] as Dictionary)["zoom_t"])
	_camera_state.set_zoom_t(wanted)
	if absf(_camera_state.zoom_t - wanted) > 1e-3:
		printerr(("profile_frame: pose %s wanted zoom_t %.2f but the rig clamped to %.2f "
				+ "(D_MAX_eff) — this measurement is NOT at the published pose")
				% [key, wanted, _camera_state.zoom_t])
	# `--tilt=`: the manual axis, through the same call the slider makes. `auto`
	# clears it, so the curve answers alone and the row is the pre-Wave-17 pose.
	var tilt: Variant = _opts["tilt"]
	if tilt is float:
		_camera_state.set_pitch_deg(float(tilt))
		if absf(_camera_state.pitch_deg() - float(tilt)) > 0.05:
			printerr(("profile_frame: pose %s wanted pitch %.1f° but the band at zoom_t"
					+ " %.2f allows %.1f° — this row is at the SECOND number")
					% [key, float(tilt), _camera_state.zoom_t, _camera_state.pitch_deg()])
	else:
		_camera_state.clear_pitch_bias()
	# WAVE 18 (doc 98 §54): the orbit pitch is no longer the angle the frustum
	# wears. A row that printed only `pitch_deg()` would describe a camera aimed
	# somewhere the frame is not, so the label carries the VIEW angle and the
	# aim-height ramp that produced it whenever the ramp is live.
	var aim := _camera_state.aim_height_m()
	var aim_note := "" if aim <= 0.0 \
			else " > view %.1f° aim %.1f m" % [_camera_state.view_pitch_deg(), aim]
	_labels[key] = "%s  D %.0f m / %.0f°%s%s" % [key.to_upper(), _camera_state.distance(),
			_camera_state.pitch_deg(), "" if _camera_state.is_pitch_auto() else "*", aim_note]
	_camera_rig.camera.global_transform = _camera_state.camera_transform()
	# A pose jump re-tiers every chunk, and §2.5 allows at most ONE tier step per
	# `lod_dwell_s`. Leaving that to the warm-up frames is a bug in this harness,
	# not a conservative choice: on the starter city a frame is 0.8 ms, so 90
	# warm-up frames are 72 ms of model time against a 500 ms dwell and the pose
	# is MEASURED MID-TRANSITION — which is how a Z2 row came out "9 NEAR chunks"
	# at a camera 370 m up, where §2.5 says no chunk can be NEAR at all.
	#
	# So the ladder is walked here instead, explicitly: four steps of a full
	# dwell, which is one more than the deepest legal transition (NEAR → MEDIUM →
	# FAR → CULLED). The measured frames then all sit in the steady state, which
	# is what the table claims to report, on a fast city and a slow one alike.
	for _step in 4:
		_model.update_chunk_tiers(_camera_rig.camera.global_position, _model.lod_dwell_s)


func _process(delta: float) -> bool:
	if _sim == null:
		return true
	if not _started:
		# The scene is built on the FIRST frame, not in `_initialize`: nodes are
		# only `get_path()`-addressable once the window's tree is live, and
		# `EnvironmentController` resolves its sun/sky by NodePath.
		_build_scene()
		_verify_resolution()
		_order = _opts["poses"]
		_pose_defs = POSES.duplicate()
		for raw_key in _order:
			var key := String(raw_key)
			if not _pose_defs.has(key):
				var t := clampf(float(key.substr(1)), 0.0, 1.0)
				_pose_defs[key] = {"zoom_t": t, "label": "%s  zoom_t %.2f" % [key, t]}
		_apply_pose(0)
		_started = true
		return false
	var hour := float(_opts["hour"])
	_env.apply(hour, delta)
	var camera_pos := _camera_rig.camera.global_position
	# `--anim-step`: the three layers that keep their OWN `anim_time` (rather
	# than reading the `sc_time` global) take a fixed delta, so the phase of
	# every light bar, beacon, dig cycle and marker pulse is a function of the
	# FRAME COUNT and two runs of one command are comparable pixel for pixel.
	# −1 leaves the real delta in place, which is what every timing row this
	# harness has ever published was measured with.
	var anim_step := float(_opts["anim_step"])
	var anim_delta := anim_step if anim_step >= 0.0 else delta
	# A large dwell so a pose change re-tiers in ONE call: the profiler is not
	# measuring the hysteresis, it is measuring the steady state on either side.
	_city_view.refresh(delta, hour, camera_pos)
	_streetlights.refresh()
	_vehicles.set_focus(_camera_state.focus)
	_vehicles.refresh(anim_delta, _env.last_night, 1.0)
	if _flood != null:
		# Held at its primed depth by the ease's own settle rule, so after the
		# warm-up frames this costs nothing on the CPU and the whole delta the
		# `--flood=` A/B measures is fragment.
		_flood.refresh(delta)
	if _power_infra != null:
		# `refresh`, not `sync`: the harness holds the sim still, and re-polling
		# a frozen grid every frame would measure the poll instead of the layer.
		# `--power-distress` has already put the rows it wants in place.
		_power_infra.refresh(delta, camera_pos)
	# The construction layer is timed on the main thread rather than inferred
	# from the frame delta: `frame_ms` on this harness is presentation-bound on
	# a fast desktop (mean and p95 both sit on the refresh interval), so a
	# sub-millisecond layer is invisible in it. `Time` is a TOOL read — nothing
	# in `sim/` or `game/render/` touches a wall clock.
	_street_usec = 0
	if _street != null:
		var s0 := Time.get_ticks_usec()
		_drive_street_life(anim_delta, camera_pos)
		_street_usec = Time.get_ticks_usec() - s0
	_construction_usec = 0
	if _construction != null:
		var t0 := Time.get_ticks_usec()
		_construction.set_focus(_camera_state.focus)
		_construction.refresh(anim_delta, _env.last_night, 1.0)
		_construction_usec = Time.get_ticks_usec() - t0

	_frames_seen += 1
	if _frames_seen > int(_opts["warmup"]):
		var rid := root.get_viewport_rid()
		_samples.append({
			"frame_ms": delta * 1000.0,
			"cpu_ms": RenderingServer.viewport_get_measured_render_time_cpu(rid),
			"gpu_ms": RenderingServer.viewport_get_measured_render_time_gpu(rid),
			"draw_calls": int(Performance.get_monitor(
					Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			"primitives": int(Performance.get_monitor(
					Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
			"construction_usec": _construction_usec,
			"street_usec": _street_usec,
		})
	if _samples.size() < int(_opts["frames"]):
		return false

	_capture(String(_order[_pose_index]))
	_results.append(_summarise(String(_order[_pose_index])))
	if _pose_index + 1 < _order.size():
		_apply_pose(_pose_index + 1)
		return false
	_report()
	return true


## The measured frame, as a picture. Taken AFTER the last sample of a pose, so
## what lands on disk is the settled steady state the row above it reports —
## the same frame, not a neighbouring one.
func _capture(pose_key: String) -> void:
	var dir := String(_opts["shots"])
	if dir == "":
		return
	DirAccess.make_dir_recursive_absolute(dir)
	var image := root.get_texture().get_image()
	if image == null:
		printerr("profile_frame: no viewport image to capture")
		return
	var path := dir.path_join("%s.png" % pose_key)
	if image.save_png(path) != OK:
		printerr("profile_frame: cannot write " + path)
	elif not bool(_opts["quiet"]):
		print("wrote " + path)


func _summarise(pose_key: String) -> Dictionary:
	var frame := PackedFloat64Array()
	var cpu := 0.0
	var gpu := 0.0
	var draw_calls := 0
	var primitives := 0
	var cons := PackedFloat64Array()
	var street := PackedFloat64Array()
	for s: Dictionary in _samples:
		frame.append(float(s["frame_ms"]))
		cpu += float(s["cpu_ms"])
		gpu += float(s["gpu_ms"])
		draw_calls = maxi(draw_calls, int(s["draw_calls"]))
		primitives = maxi(primitives, int(s["primitives"]))
		cons.append(float(s["construction_usec"]) * 0.001)
		street.append(float(s["street_usec"]) * 0.001)
	cons.sort()
	street.sort()
	var n := maxi(1, frame.size())
	frame.sort()
	var census: Dictionary = _model.tier_census()
	var split: Dictionary = _city_view.perf_stats()
	return {
		"pose": pose_key,
		"label": String(_labels.get(pose_key, (_pose_defs[pose_key] as Dictionary)["label"])),
		"pitch_deg": _camera_state.pitch_deg(),
		"pitch_auto": _camera_state.is_pitch_auto(),
		"zoom_t": _camera_state.zoom_t,
		# §2.5b (render lane, RR-98): read off the model AFTER the pose settled — the
		# pitch the tier pass actually culled against and the cull ring it resolved to.
		"culling_pitch_deg": _model.culling_pitch_deg,
		"active_far_cull_m": _model.active_far_cull_m,
		"preset_far_cull_m": _model.far_cull_m,
		"frame_mean_ms": _mean(frame),
		"frame_p95_ms": frame[clampi(int(ceil(0.95 * float(n))) - 1, 0, n - 1)],
		"frame_max_ms": frame[n - 1],
		"cpu_ms": cpu / float(n),
		"gpu_ms": gpu / float(n),
		"draw_calls": draw_calls,
		"draw_calls_with_ui": draw_calls + UI_DRAW_CALLS,
		"primitives": primitives,
		"bucket_nodes_visible": _city_view.building_draw_calls(),
		# D-14's whole question is WHERE the building calls come from, so the
		# three kinds are reported apart: per-(archetype, level) LOD0 buckets,
		# merged per-archetype MEDIUM nodes, and the shared FAR box per chunk.
		"bucket_calls": int(split.get("bucket_calls", 0)),
		"merged_calls": int(split.get("merged_calls", 0)),
		"far_calls": int(split.get("far_calls", 0)),
		# Doc 11 §2.11's per-building contact shadow. NOT part of
		# `bucket_nodes_visible` — that is building GEOMETRY — and printed on its
		# own line so "+1 city-wide on Performance, zero elsewhere" is a
		# checkable claim and not an assertion (RR-83, RR-96).
		"blob_calls": int(split.get("blob_calls", 0)),
		"blob_enabled": bool(split.get("blob_enabled", false)),
		"chunks": int(census.get("near", 0)) + int(census.get("medium", 0))
				+ int(census.get("far", 0)),
		"near": int(census.get("near", 0)),
		"medium": int(census.get("medium", 0)),
		"far": int(census.get("far", 0)),
		"culled": int(census.get("culled", 0)),
		"instances": _model.building_count(),
		# The visible power layer, counted the way it is budgeted: nodes
		# SUBMITTED, not nodes allocated.
		"power_calls": _power_infra.draw_calls() if _power_infra != null else 0,
		"power_wire_buckets": _power_infra.visible_wire_bucket_count() \
				if _power_infra != null else 0,
		"power_puffs": _power_infra.live_puff_count() if _power_infra != null else 0,
		# Doc 11 §2.16's own budget line, measured rather than inferred.
		"construction_mean_ms": _mean(cons),
		"construction_p95_ms": 0.0 if cons.is_empty() \
				else cons[clampi(int(ceil(0.95 * float(cons.size()))) - 1, 0,
						cons.size() - 1)],
		# Doc 11 §2.17's budget line, measured the same way and for the same
		# reason: `frame_ms` on a fast desktop is presentation-bound, so a
		# sub-millisecond layer is invisible in it.
		"street_mean_ms": _mean(street),
		"street_p95_ms": 0.0 if street.is_empty() \
				else street[clampi(int(ceil(0.95 * float(street.size()))) - 1, 0,
						street.size() - 1)],
		"street_buffers": _street.active_buffers() if _street != null else 0,
		# Blob shadows in the frame. On the fx buffer, so this number is
		# instances and never draw calls -- which is the claim, printed rather
		# than asserted (report 98 RR-90).
		"street_blobs": int((_street.census() as Dictionary).get("blobs", 0)) \
				if _street != null else 0,
		# The non-building draw calls: the term this harness can A/B reliably,
		# because the chunk tier census wobbles between runs and the building
		# buckets wobble with it.
		"non_building_calls": draw_calls - int(split.get("bucket_calls", 0))
				- int(split.get("merged_calls", 0)) - int(split.get("far_calls", 0)),
	}


## Doc 11 §2.13's BUDGET half of a preset row, checked instead of authored.
##
## `gpu_budget_ms`, `cpu_budget_ms`, `chunk_budget`, `near_chunk_max` and
## `vram_budget_mb` were the other half of the audit's inert-knob finding: five
## numbers in every preset row that no file in the tree read. They are not
## knobs — nothing applies a budget — so wiring them was never the answer and
## deleting them would have thrown away the only published statement of what a
## preset is allowed to cost. They are ASSERTIONS, and this is the instrument
## that was already measuring every quantity they bound. Now it says so, per
## pose, with the word OVER wherever the frame does not fit.
##
## `pss_budget_mb` is deliberately not here: process PSS is an Android figure
## and this harness is a desktop one. Its consumer is `tools/perf_rows.py`,
## against `tools/bench_device.sh`'s `meminfo_*` capture.
func _report_budgets(preset_row: Dictionary) -> void:
	var gpu_budget := float(preset_row.get("gpu_budget_ms", 0.0))
	var cpu_budget := float(preset_row.get("cpu_budget_ms", 0.0))
	var chunk_budget := int(preset_row.get("chunk_budget", 0))
	var near_max := int(preset_row.get("near_chunk_max", 0))
	var vram_budget := int(preset_row.get("vram_budget_mb", 0))
	var vram_mb := float(RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_VIDEO_MEM_USED)) / 1048576.0
	var worst: Array[String] = []
	for row: Dictionary in _results:
		var pose := String(row["pose"])
		var chunks := int(row["near"]) + int(row["medium"]) + int(row["far"])
		if gpu_budget > 0.0 and float(row["gpu_ms"]) > gpu_budget:
			worst.append("%s gpu %.2f>%.1f" % [pose, float(row["gpu_ms"]), gpu_budget])
		if cpu_budget > 0.0 and float(row["cpu_ms"]) > cpu_budget:
			worst.append("%s cpu %.2f>%.1f" % [pose, float(row["cpu_ms"]), cpu_budget])
		if chunk_budget > 0 and chunks > chunk_budget:
			worst.append("%s chunks %d>%d" % [pose, chunks, chunk_budget])
		if near_max > 0 and int(row["near"]) > near_max:
			worst.append("%s near %d>%d" % [pose, int(row["near"]), near_max])
	if vram_budget > 0 and vram_mb > float(vram_budget):
		worst.append("vram %.0f>%d MB" % [vram_mb, vram_budget])
	print(("  BUDGETS (doc 11 §2.13, preset `%s`): gpu %.1f ms  cpu %.1f ms"
			+ "  chunks %d  near %d  vram %d MB — measured vram %.0f MB — %s") % [
			String(_opts["preset"]), gpu_budget, cpu_budget, chunk_budget,
			near_max, vram_budget, vram_mb,
			"all within budget" if worst.is_empty() else "OVER: " + ", ".join(worst)])
	# §2.13b: which engine-side preset keys this run actually applied, so a
	# timing row can never again be read as belonging to a preset it was not
	# rendered under.
	#
	# READ BACK OFF THE LIVE OBJECTS, not off `resolve()`. Printing what the
	# resolver returned would prove the resolver runs; the claim that needs
	# proving is that the ENGINE took the value, which is exactly the claim
	# every one of these keys failed for three waves. `scaling_3d_scale`,
	# `msaa_3d` and `screen_space_aa` come off the viewport, the shadow mode
	# and distance off the sun, `adjustments` off the Environment.
	var sun: DirectionalLight3D = _env.get_node_or_null(_env.sun_path)
	var env_res: Environment = (_env.get_node_or_null(
			_env.world_environment_path) as WorldEnvironment).environment
	var mode_names := ["off", "2x", "4x", "8x"]
	print(("  QUALITY (doc 11 §2.13b, read back off the live objects%s):"
			+ " scaling_3d_scale %.2f (3D %dx%d of %dx%d)  msaa_3d %s"
			+ "  screen_space_aa %s  shadow splits-mode %d  shadow_max %.0f m"
			+ "  glow_hdr_scale %.2f  adjustments %s  street_lights %d/chunk") % [
			" — --no-quality, pre-Wave-17 arm" if bool(_opts["no_quality"]) else "",
			root.scaling_3d_scale,
			int(round(float(_measured_resolution.x) * root.scaling_3d_scale)),
			int(round(float(_measured_resolution.y) * root.scaling_3d_scale)),
			_measured_resolution.x, _measured_resolution.y,
			mode_names[clampi(int(root.msaa_3d), 0, 3)],
			"FXAA" if int(root.screen_space_aa) == 1 else "off",
			int(sun.directional_shadow_mode) if sun != null else -1,
			sun.directional_shadow_max_distance if sun != null else -1.0,
			env_res.glow_hdr_scale if env_res != null else -1.0,
			"on" if env_res != null and env_res.adjustment_enabled else "off",
			_streetlights.light_budget if _streetlights != null else -1])


func _non_building_rows() -> Array:
	var out: Array = []
	for row: Dictionary in _results:
		var n := int(row["non_building_calls"])
		out.append("%s %s" % [String(row["pose"]), "n/a" if n < 0 else str(n)])
	return out


static func _mean(values: PackedFloat64Array) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for v in values:
		total += v
	return total / float(values.size())


func _report() -> void:
	var preset_row: Dictionary = (_render_data.get("presets", {}) as Dictionary) \
			.get(String(_opts["preset"]), {})
	var budget := int(preset_row.get("draw_call_budget", 320))
	print("")
	var pad_shadow_state := "n/a"
	if _power_infra != null:
		# -1 means "whatever the JSON says", so the line reports the JSON rather
		# than assuming the shipped default is the one under test.
		var wanted := int(_opts["pad_shadows"])
		var live := wanted == 1 if wanted >= 0 else bool(
				(_render_data.get("power_infra", {}) as Dictionary).get("pad_shadows", true))
		pad_shadow_state = "on" if live else "off"
	var tilt_state := "auto" if not (_opts["tilt"] is float) \
			else "%.0f°" % float(_opts["tilt"])
	print(("=== FRAME COST — %s, preset %s, hour %.1f, %dx%d, road detail %d,"
			+ " pad shadows %s, tilt %s, sky %s ===") % [
			String(_opts["city"]).get_file(), String(_opts["preset"]), float(_opts["hour"]),
			_measured_resolution.x, _measured_resolution.y,
			_roads.detail if _roads != null else -1, pad_shadow_state, tilt_state,
			String(_opts["sky"])])
	var header := "  %-22s %8s %8s %8s %8s %6s %6s %6s %5s %5s %5s %5s %5s %5s %9s" % [
			"pose", "mean ms", "p95 ms", "rs cpu", "rs gpu", "dc", "dc+ui",
			"budget", "buck", "merg", "far#", "near", "med", "far", "prims"]
	print(header)
	print("  " + "-".repeat(header.length()))
	for row: Dictionary in _results:
		print("  %-22s %8.2f %8.2f %8.3f %8.3f %6d %6d %6d %5d %5d %5d %5d %5d %5d %9d" % [
				String(row["label"]), float(row["frame_mean_ms"]), float(row["frame_p95_ms"]),
				float(row["cpu_ms"]), float(row["gpu_ms"]), int(row["draw_calls"]),
				int(row["draw_calls_with_ui"]), budget, int(row["bucket_calls"]),
				int(row["merged_calls"]), int(row["far_calls"]),
				int(row["near"]), int(row["medium"]), int(row["far"]),
				int(row["primitives"])])
	if _opts["tilt"] is float:
		print("  * = the MANUAL pitch axis (doc 12 §2.23) holds this pitch; a row"
				+ " without one is the curve's own answer.")
	print("  `rs cpu` / `rs gpu` are the RenderingServer's own measured times for"
			+ " this viewport. They do NOT sum to `mean ms`: the remainder is"
			+ " main-thread work (the render layer's per-frame GDScript) plus"
			+ " present. On a large city that remainder is the frame.")
	print("  instances resident %d   (preset instance_budget %d)" % [
			_model.building_count(), int(preset_row.get("instance_budget", 0))])
	_report_budgets(preset_row)
	# Doc 11 §2.11's per-building contact shadow, printed on every run whether
	# the preset draws it or not — "zero on the other two presets" is half the
	# claim and an unprinted half is a half nobody re-checks (RR-83, RR-96).
	if not _results.is_empty():
		var blob_on := bool((_results[0] as Dictionary).get("blob_enabled", false))
		var blob_line := "  BLOB SHADOWS (doc 11 §2.11, `enabled_presets`): %s for `%s`" % [
				"ON" if blob_on else "off", String(_opts["preset"])]
		for row: Dictionary in _results:
			blob_line += "   %s %d dc" % [String(row["pose"]), int(row["blob_calls"])]
		print(blob_line)
	if _power_infra != null:
		var power_line := "  power layer (pads / wires / distress) per pose: "
		for row: Dictionary in _results:
			power_line += "%s %d dc (%d wire buckets, %d puffs)   " % [
					String(row["pose"]), int(row["power_calls"]),
					int(row["power_wire_buckets"]), int(row["power_puffs"])]
		print(power_line)
	print("  NOTE: the UI CanvasLayer is not built by this harness; `dc+ui` adds"
			+ " §2.13's %d batched UI calls so the budget column compares." % UI_DRAW_CALLS)
	# The A/B-able draw-call term: total minus the three building terms, whose
	# chunk-tier census wobbles from run to run and swamps a +5 delta. It is
	# only meaningful where the building terms ARE draw calls — i.e. at Z2,
	# where `buck` is 0 and no bucket is re-drawn into a shadow split. At Z0/Z1
	# the bucket count is nodes, not calls, and the subtraction goes negative;
	# those poses are printed as `n/a` rather than as a wrong number.
	print("  non-building draw calls (Z2 only, see _non_building_rows): "
			+ ", ".join(_non_building_rows()))
	# §2.5b's line. Prints the RESOLVED ring per pose, not the authored one:
	# the claim worth checking is that the cull moved, and `= preset` is the
	# honest report when the frustum reaches further than the ring does.
	var cull_bits: Array = []
	for row: Dictionary in _results:
		var active := float(row["active_far_cull_m"])
		var authored := float(row["preset_far_cull_m"])
		cull_bits.append("%s %.0f°→%s" % [String(row["pose"]),
				float(row["pitch_deg"]),
				"%.0f m" % active if active < authored - 0.5 \
						else "%.0f m (= preset, frustum reaches past it)" % active])
	# §2.17b's road-tint arm, printed as the RESOLVED uniform rather than as the
	# requested gain. An A/B arm that silently fails to reach its uniform
	# returns a null result that looks like an answer — which is doc 93 §X3's
	# own binding, applied to §X3's own instrument (report 98 RR-97).
	if _roads != null:
		var t := _roads.tinted_road_color()
		var live := _roads.live_tint_color()
		print(("  ROAD TINT (doc 11 §2.1.2, gain %.2f): resolved (%.4f, %.4f, %.4f)"
				+ "  LIVE MATERIAL (%.4f, %.4f, %.4f)%s")
				% [_roads.tint_gain, t.r, t.g, t.b, live.r, live.g, live.b,
				"" if live.is_equal_approx(t) else "   <-- ARM DID NOT REACH THE UNIFORM"])
	print("  PITCH CULL (doc 11 §2.5b, %s): %s" % [
			"ON" if _model.pitch_cull_enabled else "DISARMED",
			"   ".join(cull_bits)])
	if _flood != null:
		print("  STANDING WATER (doc 07 §2.4 / doc 11 §2.9b): %.0f mm on %d cells"
				% [float(_opts["flood"]), _flood.cell_keys().size()]
				+ " -> %d tiles in ONE MultiMesh, %d draw call(s), fragment rung %d"
				% [_flood.drawn_tiles(), _flood.draw_calls(), _flood.detail])
	if _construction != null:
		var census: Dictionary = _construction.census()
		print(("  LIVING CONSTRUCTION: %d sites at stage %d -> %d excavators,"
				+ " %d lorries, %d heaps, %d stacks, %d barricade bays"
				+ " (%d MultiMeshes, %d routes still queued)") % [
				int(census["sites"]), int(_opts["site_stage"]),
				int(census["excavator"]), int(census["tipper"]), int(census["heap"]),
				int(census["stack"]), int(census["barrier"]),
				_construction.layer_count(), int(census["pending_routes"])])
		for row: Dictionary in _results:
			print("    %s  layer CPU mean %.3f ms, p95 %.3f ms" % [
					String(row["pose"]), float(row["construction_mean_ms"]),
					float(row["construction_p95_ms"])])
	if _street != null:
		var scensus: Dictionary = _street.census()
		print(("  STREET LIFE: %d live (%d crook, %d dog, %d goat) -> %d markers,"
				+ " %d labels, %d bursts, %d fx rows"
				+ " (%d MultiMeshes declared, %d submitting)") % [
				int(scensus["live"]), int(scensus["crook"]), int(scensus["dog"]),
				int(scensus["goat"]), int(scensus["markers"]), int(scensus["labels"]),
				int(scensus["bursts"]), int(scensus["fx"]),
				_street.layer_count(), _street.active_buffers()])
		for row2: Dictionary in _results:
			print("    %s  layer CPU mean %.3f ms, p95 %.3f ms, %d buffers, %d blobs" % [
					String(row2["pose"]), float(row2["street_mean_ms"]),
					float(row2["street_p95_ms"]), int(row2["street_buffers"]),
					int(row2["street_blobs"])])
	var out := String(_opts["out"])
	if out != "":
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f == null:
			printerr("profile_frame: cannot write " + out)
			return
		f.store_string(JSON.stringify({
			"city": String(_opts["city"]), "preset": String(_opts["preset"]),
			"hour": float(_opts["hour"]), "buildings": _sim.buildings.size(),
			"road_detail": _roads.detail if _roads != null else -1,
			"tilt": _opts["tilt"], "sky": String(_opts["sky"]), "aim": int(_opts["aim"]),
			"yaw_deg": float(_opts["yaw"]) if is_finite(float(_opts["yaw"])) else null,
			"resolution": [_measured_resolution.x, _measured_resolution.y],
			"resolution_asked": [(_opts["resolution"] as Vector2i).x,
					(_opts["resolution"] as Vector2i).y],
			"poses": _results,
		}, "  ", true, true))
		f.close()
		print("wrote " + out)


# ------------------------------------------------------------------- options

func _parse(argv: PackedStringArray) -> Dictionary:
	var opts := {
		"city": CITY_DEFAULT, "preset": "balanced", "hour": 21.0,
		"poses": ["z0", "z1", "z2"], "warmup": 90, "frames": 180,
		"resolution": Vector2i(1920, 1080), "out": "", "quiet": false,
		"shots": "", "no_merge": false, "atlas_lod": -1,
		"focus": Vector2(-1.0, -1.0),
		"no_power_infra": false, "power_distress": 0.0,
		"sites": 0, "site_stage": 2, "site_gm": 900.0,
		"street_life": 0, "street_collect": 0, "quiet_layers": false,
			"street_shot_lag": 0, "traffic": 0, "units": 0, "street_gm": -1.0,
		"anim_step": -1.0, "no_lod": false,
		"pad_shadows": -1, "road_detail": -1, "blob": -1, "road_tint": 1.0,
		"flood": 0.0, "flood_detail": -1,
		"tilt": "auto", "sky": "gradient", "yaw": NAN,
		"no_quality": false, "medium_max": -1.0, "far_family": -1,
		"far_gain": -1.0, "far_relief": -1.0, "pitch": -1.0, "pitch_cull": -1, "far_cull": -1.0,
		"aim": -1,
	}
	for raw in argv:
		var arg := String(raw)
		if arg == "--quiet":
			opts["quiet"] = true
		elif arg == "--quiet-layers":
			opts["quiet_layers"] = true
		elif arg == "--no-merge":
			opts["no_merge"] = true
		elif arg == "--no-lod":
			opts["no_lod"] = true
		elif arg == "--no-quality":
			opts["no_quality"] = true
		elif arg.begins_with("--far-relief="):
			opts["far_relief"] = float(arg.trim_prefix("--far-relief="))
		elif arg.begins_with("--far-cull="):
			opts["far_cull"] = float(arg.trim_prefix("--far-cull="))
		elif arg.begins_with("--pitch="):
			opts["pitch"] = float(arg.trim_prefix("--pitch="))
		elif arg.begins_with("--pitch-cull="):
			opts["pitch_cull"] = clampi(int(arg.trim_prefix("--pitch-cull=")), 0, 1)
		elif arg.begins_with("--aim="):
			opts["aim"] = clampi(int(arg.trim_prefix("--aim=")), 0, 1)
		elif arg.begins_with("--medium-max="):
			opts["medium_max"] = float(arg.trim_prefix("--medium-max="))
		elif arg.begins_with("--far-family="):
			opts["far_family"] = int(arg.trim_prefix("--far-family="))
		elif arg.begins_with("--far-gain="):
			opts["far_gain"] = float(arg.trim_prefix("--far-gain="))
		elif arg == "--no-power-infra":
			opts["no_power_infra"] = true
		elif arg.begins_with("--power-distress="):
			opts["power_distress"] = clampf(float(arg.substr(17)), 0.0, 1.0)
		elif arg.begins_with("--pad-shadows="):
			opts["pad_shadows"] = clampi(int(arg.substr(14)), 0, 1)
		elif arg.begins_with("--blob="):
			opts["blob"] = clampi(int(arg.substr(7)), 0, 1)
		elif arg.begins_with("--road-detail="):
			opts["road_detail"] = clampi(int(arg.substr(14)), 0, 2)
		elif arg.begins_with("--road-tint="):
			opts["road_tint"] = clampf(float(arg.substr(12)), 0.05, 8.0)
		elif arg.begins_with("--flood="):
			opts["flood"] = maxf(0.0, float(arg.substr(8)))
		elif arg.begins_with("--flood-detail="):
			opts["flood_detail"] = clampi(int(arg.substr(15)), 0, 2)
		elif arg.begins_with("--sites="):
			opts["sites"] = maxi(0, int(arg.substr(8)))
		elif arg.begins_with("--site-stage="):
			opts["site_stage"] = clampi(int(arg.substr(13)), 1, 6)
		elif arg.begins_with("--site-gm="):
			opts["site_gm"] = maxf(0.0, float(arg.substr(10)))
		elif arg.begins_with("--street-life="):
			opts["street_life"] = maxi(0, int(arg.substr(14)))
		elif arg.begins_with("--street-collect="):
			opts["street_collect"] = maxi(0, int(arg.substr(17)))
		elif arg.begins_with("--street-shot-lag="):
			opts["street_shot_lag"] = maxi(0, int(arg.substr(18)))
		elif arg.begins_with("--street-gm="):
			opts["street_gm"] = float(arg.substr(13))
		elif arg.begins_with("--anim-step="):
			opts["anim_step"] = float(arg.substr(12))
		elif arg.begins_with("--traffic="):
			opts["traffic"] = maxi(0, int(arg.substr(10)))
		elif arg.begins_with("--units="):
			opts["units"] = maxi(0, int(arg.substr(8)))
		elif arg.begins_with("--tilt="):
			var raw_tilt := arg.substr(7).strip_edges().to_lower()
			if raw_tilt == "auto" or raw_tilt == "":
				opts["tilt"] = "auto"
			elif raw_tilt.is_valid_float():
				opts["tilt"] = float(raw_tilt)
			else:
				opts["error"] = "--tilt wants a pitch in degrees, or auto"
		elif arg.begins_with("--yaw="):
			opts["yaw"] = float(arg.substr(6))
		elif arg.begins_with("--sky="):
			var mode := arg.substr(6).strip_edges().to_lower()
			if mode != "gradient" and mode != "procedural":
				opts["error"] = "--sky wants gradient|procedural"
			else:
				opts["sky"] = mode
		elif arg.begins_with("--atlas-lod="):
			opts["atlas_lod"] = int(arg.substr(12))
		elif arg.begins_with("--shots="):
			opts["shots"] = arg.substr(8)
		elif arg.begins_with("--focus="):
			# TILE coordinates. Z0 parks 18 m off the focus, so the default city
			# centre can put the camera INSIDE a tower; aiming at a junction is
			# the only way to review the street surface at that pose.
			var f := arg.substr(8).split(",")
			if f.size() != 2:
				opts["error"] = "--focus wants tile_x,tile_z"
			else:
				opts["focus"] = Vector2(float(f[0]), float(f[1]))
		elif arg.begins_with("--city="):
			opts["city"] = arg.substr(7)
		elif arg.begins_with("--preset="):
			opts["preset"] = arg.substr(9)
		elif arg.begins_with("--hour="):
			opts["hour"] = float(arg.substr(7))
		elif arg.begins_with("--warmup="):
			opts["warmup"] = maxi(0, int(arg.substr(9)))
		elif arg.begins_with("--frames="):
			opts["frames"] = maxi(1, int(arg.substr(9)))
		elif arg.begins_with("--out="):
			opts["out"] = arg.substr(6)
		elif arg.begins_with("--resolution="):
			var parts := arg.substr(13).split("x")
			if parts.size() != 2:
				opts["error"] = "--resolution wants WxH"
			else:
				opts["resolution"] = Vector2i(int(parts[0]), int(parts[1]))
		elif arg.begins_with("--poses="):
			var wanted: Array = []
			for name in arg.substr(8).split(","):
				var key := String(name).strip_edges().to_lower()
				if POSES.has(key):
					wanted.append(key)
				elif key.begins_with("t") and key.substr(1).is_valid_float():
					wanted.append(key)
				else:
					opts["error"] = "unknown pose '%s' (want z0|z1|z2, or t<zoom_t>)" % key
			if not wanted.is_empty():
				opts["poses"] = wanted
		else:
			opts["error"] = "unknown option: " + arg
	return opts
