class_name QualityApplier
extends RefCounted
## Doc 11 §2.13b — the ENGINE-SIDE half of a graphics preset, and the reason
## "High is Balanced with more cars" was true for three waves.
##
## THE DEFECT THIS FILE EXISTS TO CLOSE (report 98 RR-98, audit P1). Every
## preset row in `data/render.json` authored `render_scale`, `msaa`, `fxaa`,
## `shadow_splits`, `shadow_atlas`, `shadow_max_m`, `glow_levels`,
## `glow_hdr_*` and `env_adjustments`, and **not one of them reached the
## engine**. `render_scale` was read in exactly one place — `SettingsModel`,
## to SORT the graphics rows cheapest-first — so the number that decided the
## order of the menu was the number that did nothing when you picked a row.
## `msaa` and `screen_space_aa` appeared nowhere in the tree at all. The
## `EnvironmentController` read glow from `presets["balanced"]` with the name
## hard-coded, so all three presets shared Balanced's bloom whichever one was
## live. What actually separated High from Balanced was the vehicle caps, the
## particle counts and `far_cull_m`: cars, rain and draw distance. Hence the
## audit's sentence.
##
## The same hole swallowed the governor's most valuable rung. §2.13's ladder
## drops `render_scale` by 0.05 per step down to a 0.60 floor — the one knob
## that buys back fill on a fragment-bound phone — and `Main` routed `knobs`
## to `CityView` and `PowerInfraView` only, so rungs 1 and 4 moved a number in
## a dictionary and nothing else. A Fold that thermal-throttled shed draw
## distance and then dropped a whole preset, having never once tried the cheap
## fix of rendering fewer pixels.
##
## THE SHAPE. Resolution is PURE and the writes are separate:
##
##     var q := QualityApplier.resolve(render_data, "high", governor.knobs())
##     QualityApplier.apply_viewport(get_viewport(), q)   # scale / MSAA / FXAA
##     environment_controller.apply_quality(q)            # glow / shadows / moon
##
## `resolve()` touches no engine object, which is what lets every preset's
## whole engine-side answer be asserted headlessly (`test_render_polish.gd`,
## `test_no_inert_preset_key`). The two appliers are split because doc 11 and
## `EnvironmentController`'s own contract say every write to the
## `WorldEnvironment`, the sun and the sky belongs to ONE file; this one would
## be the second.
##
## WHICH LADDER RUNGS THIS FILE OWNS. Two of the five: `render_scale`, whose
## owner is the viewport, and `street_lights`, whose owner is `StreetlightView`
## and which is resolved here so the preset's ceiling and the governor's step
## meet in one place. `far_cull_m` belongs to `RenderStateModel`,
## `particle_ratio` to `WeatherFX`, and `preset_drop` re-enters through
## `resolve()`'s `preset_name` argument. Passing the whole `knobs` dictionary in
## and taking two keys out of it keeps the call site honest — the shell hands
## over what the governor said and this file decides what of it is its business.
##
## Both overrides may only ever LOWER the preset's value. A knob left over from
## a preset the player has since raised must not drag the new one anywhere.
##
## WHAT IS DELIBERATELY NOT HERE. `shadows` false does not disable the sun's
## shadow: `EnvironmentController.apply()` re-derives `_sun.shadow_enabled`
## every frame from the sun's elevation and the storm, and a knob written once
## at preset time would be overwritten on the next frame. It is resolved into
## `shadows_allowed` and ANDed there instead, so the preset gate and the
## per-frame gate compose instead of racing (report 98 RR-98).

## Godot's `Viewport.msaa_3d` values, keyed by the sample count a preset
## authors. A row asking for a count that does not exist gets the nearest one
## BELOW it, never above — a preset is a ceiling, and a typo must not make a
## phone slower than the row it named.
const MSAA_BY_SAMPLES := {0: 0, 1: 0, 2: 1, 4: 2, 8: 3}

## `Environment.GLOW_BLEND_MODE_*` by the string `data/render.json` authors.
const GLOW_BLEND_MODES := {
	"additive": 0,
	"screen": 1,
	"softlight": 2,
	"replace": 3,
	"mix": 4,
}

## Godot's `DirectionalLight3D.directional_shadow_mode` by authored split count.
## 3 is not a mode Godot has; it rounds DOWN to 2 for the same reason MSAA does.
const SHADOW_MODE_BY_SPLITS := {0: 0, 1: 0, 2: 1, 3: 1, 4: 2}

## Godot's glow has exactly 7 levels (0..6). `glow_levels` authors the 1-based
## mip numbers doc 11 §2.4 talks in, so the array `[2, 3, 4]` lights levels
## 1, 2 and 3 of the engine's array.
const GLOW_LEVEL_COUNT := 7

## The floor and ceiling `scaling_3d_scale` is clamped into. The floor is the
## governor ladder's own (`governor.knobs[0].floor`); the ceiling is 1.0
## because this project has no supersampling budget on any device it ships to.
const RENDER_SCALE_MIN := 0.60
const RENDER_SCALE_MAX := 1.0

## Godot's directional shadow atlas is square and a power of two. 0 in the
## table means "this preset draws no directional shadow", and the atlas is
## dropped to the smallest legal size rather than to 0 — allocating 0 is an
## engine error, and a preset with `shadows: false` never samples it anyway.
const SHADOW_ATLAS_MIN := 256


## The whole engine-side answer for one preset, as plain data.
##
## `knobs` is `PerfGovernor.knobs()` or `{}`. Only `render_scale` and
## `street_lights` are read from it, and only downward: a knob equal to the
## preset's own ceiling resolves to the preset's own value, so a governor that
## has never fired is byte-identical to no governor at all.
static func resolve(render_data: Dictionary, preset_name: String,
		knobs: Dictionary = {}) -> Dictionary:
	var presets: Dictionary = render_data.get("presets", {})
	var row: Dictionary = presets.get(preset_name, presets.get("balanced", {}))

	var scale := float(row.get("render_scale", 1.0))
	if knobs.has("render_scale"):
		# The governor may only ever LOWER it. A stale knob from a preset the
		# player has since raised must not drag the new preset up or down.
		scale = minf(scale, float(knobs["render_scale"]))
	scale = clampf(scale, RENDER_SCALE_MIN, RENDER_SCALE_MAX)

	# Ladder rung 4, and it takes the same "may only ever LOWER it" rule rung 1
	# takes, for the same reason: a knob left over from a richer preset must
	# not raise the one the player has since chosen.
	var lamps := int(row.get("street_lights", 12))
	if knobs.has("street_lights"):
		lamps = mini(lamps, int(knobs["street_lights"]))

	var shadows := bool(row.get("shadows", true))
	var splits := int(row.get("shadow_splits", 2))
	var atlas := int(row.get("shadow_atlas", 2048))

	var out := {
		"preset": preset_name,
		"render_scale": scale,
		"scaling_3d_mode": 0,                      # BILINEAR; no FSR budget
		"msaa_3d": _msaa_mode(int(row.get("msaa", 0))),
		"screen_space_aa": 1 if bool(row.get("fxaa", false)) else 0,
		# The preset's HALF of the sun-shadow gate. See the class doc: the
		# other half is per-frame and lives in EnvironmentController.
		"shadows_allowed": shadows,
		"shadow_mode": _shadow_mode(splits),
		"shadow_atlas": maxi(SHADOW_ATLAS_MIN, atlas) if shadows \
				else SHADOW_ATLAS_MIN,
		"shadow_max_m": float(row.get("shadow_max_m", 150.0)),
		"glow_levels": _glow_level_weights(row.get("glow_levels", [])),
		"glow_intensity": float(row.get("glow_intensity", 0.9)),
		"glow_strength": float(row.get("glow_strength", 1.0)),
		"glow_bloom": float(row.get("glow_bloom", 0.05)),
		"glow_blend": _glow_blend(String(row.get("glow_blend", "screen"))),
		"glow_hdr_threshold_day": float(row.get("glow_hdr_threshold_day", 1.05)),
		"glow_hdr_threshold_night": float(row.get("glow_hdr_threshold_night", 0.78)),
		"glow_hdr_scale": float(row.get("glow_hdr_scale", 2.0)),
		"env_adjustments": bool(row.get("env_adjustments", true)),
		"moon": bool(row.get("moon", true)),
		"far_cull_m": float(row.get("far_cull_m", 1200.0)),
		"street_lights": maxi(0, lamps),
	}
	return out


## §2.13's viewport half: the framebuffer the 3D world is drawn into, and the
## two anti-aliasing paths that sit on it. The 2D/UI layer is NOT scaled — it
## draws at the window's own resolution — which is exactly why `render_scale`
## is the cheapest millisecond in the project and why shipping it inert cost so
## much: a 0.85 Balanced frame is 72 % of the fill of the 1.0 one it was
## actually rendering, with a UI that stays sharp either way.
static func apply_viewport(viewport: Viewport, resolved: Dictionary) -> void:
	if viewport == null:
		return
	viewport.scaling_3d_mode = \
			int(resolved.get("scaling_3d_mode", 0)) as Viewport.Scaling3DMode
	viewport.scaling_3d_scale = float(resolved.get("render_scale", 1.0))
	viewport.msaa_3d = int(resolved.get("msaa_3d", 0)) as Viewport.MSAA
	viewport.screen_space_aa = \
			int(resolved.get("screen_space_aa", 0)) as Viewport.ScreenSpaceAA
	# The directional shadow atlas is a RENDERING SERVER global, not a viewport
	# property: one atlas serves every directional light in the process. 16-bit
	# depth is left off — the Fold showed peter-panning on the 4096 atlas at
	# 16 bits and the memory saved is 8 MB on a 420 MB budget.
	RenderingServer.directional_shadow_atlas_set_size(
			int(resolved.get("shadow_atlas", SHADOW_ATLAS_MIN)), false)


## The engine's `msaa_3d` for an authored sample count, rounding DOWN.
static func _msaa_mode(samples: int) -> int:
	var best := 0
	for s: int in MSAA_BY_SAMPLES:
		if s <= samples:
			best = maxi(best, int(MSAA_BY_SAMPLES[s]))
	return best


static func _shadow_mode(splits: int) -> int:
	if SHADOW_MODE_BY_SPLITS.has(splits):
		return int(SHADOW_MODE_BY_SPLITS[splits])
	return 2 if splits > 4 else 0


static func _glow_blend(name: String) -> int:
	return int(GLOW_BLEND_MODES.get(name, 1))


## `[2, 3, 4]` -> `[0, 1, 1, 1, 0, 0, 0]`, the per-level intensity array
## `Environment.set_glow_level` takes. Authored levels are 1-based (doc 11
## §2.4 counts mips from 1) and out-of-range entries are dropped rather than
## clamped: a typo must not silently light level 6, the most expensive one.
static func _glow_level_weights(levels: Variant) -> Array[float]:
	var out: Array[float] = []
	out.resize(GLOW_LEVEL_COUNT)
	out.fill(0.0)
	if levels is not Array:
		return out
	for entry: Variant in levels as Array:
		var idx := int(entry) - 1
		if idx >= 0 and idx < GLOW_LEVEL_COUNT:
			out[idx] = 1.0
	return out
