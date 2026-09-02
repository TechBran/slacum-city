// FAR-tier building shader — doc 11 §2.6's second (and last) building shader.
//
// The whole city beyond `medium_max_m` is drawn as ONE MultiMesh per chunk of
// the shared 12-triangle `far_unit_box` (§2.14 LOD2), each instance scaled by
// its transform to `(fx·8, height_m, fz·8)`. That is the entire FAR budget:
// 1 building draw call + 1 ground + 1 lamp = the 3 calls per FAR chunk §2.13
// is costed against.
//
// **Why this is not the near shader with a cheaper mesh.** At 420–1200 m one
// window cell is a fraction of a pixel, so `hash21(cell)` samples white noise
// per pixel and the tower crawls with sampling shimmer as the camera moves —
// the single worst artefact the LOD ladder has to avoid, because Z2 is the
// skyline shot. §2.6 therefore drops the per-window hash for horizontal
// **bands**: `rows = max(2, floor(height_m / floor_height_m))` storey lines,
// lit between `band_lo` and `band_hi` of each storey's height.
//
// **Two deviations from the doc snippet, both measured against the frame.**
//
// 1. *A lit storey is broken into segments, not lit end to end.* The doc's
//    `step(1-e, hash11(storey))` lights the whole perimeter of a storey at
//    once, and rendered next to the MEDIUM chunks in front of it the far city
//    came out as continuous cream chevrons — far BRIGHTER and far more
//    regular than the tier it has to match, so the LOD boundary read as a
//    lighting change. The hash is taken over `(storey, segment)` where a
//    segment is `far_cell_m` (6.4 m, two window bays) of façade. That is not
//    the per-window hash the doc rejected: a 6.4 m segment is ~23 px at 500 m
//    and ~10 px at 1200 m, an order of magnitude above the sub-pixel cell that
//    causes the crawl, and it is what gives a far tower runs of lit floors
//    instead of solid stripes.
//
// 2. *`far_energy_scale` compensates coverage.* A lit BAND covers 100% of its
//    segment's width; a lit near-tier window covers only the pane inside its
//    cell (the texture's shine mask, ~half). Without the scale the far tier
//    emits roughly twice the near tier's radiance per lit storey and the swap
//    pops. This is a brightness scale only — it never changes how many
//    segments light, so the emissive contract is untouched.
//
// `height_m` is read off the instance transform (`length(MODEL_MATRIX[1].xyz)`
// — the unit box is 1 m tall, so the Y column IS the height in metres), which
// is what lets one mesh, one material and one hash rule cover every archetype
// and level in the city without a single per-archetype uniform.
//
// **The `.a` channel means something different here.** §2.6's custom-data
// contract locks `.a` to `anim_phase` for the NEAR/MEDIUM buffers, which the
// model writes. The FAR buffer is not one of those: `CityView._upload_far`
// builds it, this shader is its only reader, and there is no flicker at 500 m
// for a phase to drive — so `.a` carries
//
//     family_index + 8 * chunk_overlay_state
//
// the building's FAMILY INDEX (0 residential … 4 civic), which buys per-family
// window colour inside a single draw call per chunk, plus doc 12 §2.5's overlay
// state AGGREGATED OVER THE CHUNK, which is what lets the far city answer the
// power and water overlays at all. `.r`, `.g` and `.b` are copied across from
// the near buffer untouched, so a chunk crossing the boundary mid-blackout
// carries its exact emissive ramp, damage and construction stage over the swap.
//
// Why not `.g`: it is the damage channel and this shader READS it, for the soot
// multiply and the emissive dim. Packing the overlay there would have traded a
// working damage read for the overlay and turned a burnt-out block clean the
// moment the player opened the power overlay. `.a` was already an integer 0..4
// with the whole float above it free. See `CityView.FAR_OVERLAY_STRIDE`.
//
// **The overlay is per CHUNK, not per building** (`CityView._far_overlay_state`
// carries the reasoning): at 420–1200 m a building is a handful of pixels, and a
// per-building wash reads as coloured noise — the same failure the per-window
// hash was rejected for. The state drawn is the WORST in the chunk, because 0..3
// is the severity order and an overlay exists to point at trouble.
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

global uniform float sc_night;
global uniform float sc_time;
global uniform float sc_wetness;
global uniform int sc_overlay_mode;

// §2.6's five family hues, in the order CityView indexes them.
uniform vec3 window_colors[5]: source_color;
uniform float window_nits_far = 2.4;
uniform float far_energy_scale = 0.62;
uniform float day_gate = 0.06;
uniform float day_nits_scale = 0.30;
uniform float floor_height_m = 3.5;
uniform float far_cell_m = 6.4;
uniform float far_bay_m = 3.2;
uniform float far_mullion_duty = 0.72;
uniform float band_lo = 0.30;
uniform float band_hi = 0.78;

uniform vec3 base_albedo: source_color = vec3(0.34, 0.335, 0.325);
uniform vec3 roof_albedo: source_color = vec3(0.26, 0.258, 0.252);
uniform vec3 site_albedo: source_color = vec3(0.38, 0.372, 0.355);

// ═════════ BEGIN §2.6b — the tier boundary, WAVE 17 (report 98 RR-98) ══════
// **The hard line at `medium_max_m`, and it was a COLOUR-SPACE bug wearing an
// art bug's clothes.** The two `source_color` uniforms above are ONE neutral
// grey for the whole city, and a `source_color` uniform IS sRGB-decoded by the
// engine — measured, not assumed: the same 0.5 in a plain `vec3` and in a
// `source_color` `vec3` renders back 0.7373 and 0.4980, and 0.4980 is
// sRGB(0.214). So what this shader actually painted was
//
//     base_albedo 0.340/0.335/0.325 sRGB  ->  linear (0.0946, 0.0918, 0.0862)
//     roof_albedo 0.260/0.258/0.252 sRGB  ->  linear (0.0550, 0.0541, 0.0517)
//
// — luma 0.092 and 0.054, against a tier in front of it painting
// `mix(base_albedo, facade_tex, tex_mix) * v_color`, i.e. the MEAN OF ITS
// FAÇADE PAGE. Measured over the shipped pages, as the linear this shader
// would see:
//
//     family      wall page  luma    roof page  luma    vs the neutral pair
//     residential brick      0.164   gravel     0.159   wall 1.8x / roof 2.9x too DARK
//     commercial  curtain    0.146   mech       0.257   wall 1.6x / roof 4.8x too DARK
//     industrial  utility    0.207   metal      0.216   wall 2.3x / roof 4.0x too DARK
//     tech        techpanel  0.054   metal      0.216   wall 1.7x too BRIGHT
//     civic       civic      0.296   gravel     0.159   wall 3.2x / roof 2.9x too DARK
//
// So the far city was not "grey" for want of a texture. It was grey AND, for
// four families out of five, **two to five times too dark** — while being
// 1.7x too BRIGHT for the one family whose page is genuinely near-black. At Z2
// the boundary circle crosses the middle of the frame, which is why it read as
// a line drawn across the skyline rather than as haze.
//
// **The fix is agreement, and it needs no fudge.** `CityView` measures each
// page the near tier wears — an 8x8 Lanczos reduction, which is what that page
// looks like once it is a few pixels wide — and hands the five wall/roof pairs
// over IN sRGB, so the engine performs the one and only decode. Measured over
// the 420 m band at Z2 (hour 13, balanced, 22.9 % of the frame), mean linear
// luma against the same band drawn MEDIUM: **-31.1 % before, +1.6 % after**,
// and per-pixel chroma -13.1 % before, +6.3 % after. The gain that would
// level-match the band fits at **0.96**, i.e. identity, so nothing is authored
// — `far_albedo_gain` below stays 1.0 and exists only as a sweep lever.
//
// **Measured, never authored, and that is the ruling.** A hand-written far
// palette is a second copy of the art; this one is read off the page the near
// tier actually wears, so `gen_textures.py` can retint the city and the far
// tier follows on the next boot with nothing to keep in sync.
//
// **A distance fade was rejected**: `Environment.fog_aerial_perspective`
// already greys the far city with range (§2.8), and a second fade in the
// albedo greys the skyline twice — the shot §1's "show the tall skyline" is
// about.
//
// `far_family_mix` is 0 by default, which reproduces the pre-Wave-17 frame
// exactly. `CityView` raises it to 1 only when all five families resolved to a
// page; a clone that has not run `gen_textures.py` keeps the neutral pair and
// still boots (the same contract `tex_mix` has on the near shader).
uniform vec3 far_wall_albedo[5]: source_color;
uniform vec3 far_roof_albedo[5]: source_color;
uniform float far_family_mix = 0.0;
// The sweep lever the level was CHECKED with, at identity because the check
// said identity. `tools/profile_frame.gd --far-gain=G` is its only caller; it
// is deliberately not in `data/render.json`, because a constant of 1.0 that
// nothing varies is the very thing §2.13b spent this wave deleting.
uniform float far_albedo_gain = 1.0;
// ═════════ §2.6b (2) — THE DAY FAÇADE, and why it cannot move the level ════
// The palette fix above made the far city the right COLOUR. It is still the
// wrong SURFACE by day: `ALBEDO` is one flat value per family per face, so a
// tower at 300 m is a coloured slab where the tier in front of it is brick and
// glass. The night path already computes storey bands and bay mullions — for
// `EMISSION` — and this reuses those exact terms on `ALBEDO`, which is the
// audit's own "3.5 m storey-band darkening" and costs three ALU, no texture
// fetch and no draw call.
//
// **It is authored as a ZERO-MEAN modulation, and that is the whole trick.**
// The level match this section just bought (−0.7 % against the same buildings
// drawn by the textured shader) would be thrown away by any pattern whose
// average is not 1. So the term is `1 + depth · (cover − mean_cover)`, where
// `mean_cover = (band_hi − band_lo) · far_mullion_duty` is exactly what the
// sharp pattern integrates to. E[relief] = 1 by construction, at every depth.
//
// **And it self-extinguishes at range with no step.** Both factors are already
// `fwidth`-crossfaded to their own means (the mullion by the block below, the
// storey band here) — so as a bay or a storey approaches a pixel wide, `cover`
// approaches `mean_cover`, the modulation approaches exactly 1.0, and the
// building fades to the flat family colour it would have had anyway. No
// aliasing, no moiré, and no second boundary further out.
uniform float far_relief_depth = 0.0;
// ═════════ END §2.6b (2) ══════════════════════════════════════════════════
// ═════════ END §2.6b ═══════════════════════════════════════════════════════
uniform vec3 soot_color: source_color = vec3(0.278, 0.263, 0.239);
uniform float wet_albedo_mult = 0.85;
uniform float wet_roughness = 0.42;
uniform float overlay_desaturate = 0.55;
uniform float overlay_emission_mult = 0.40;

// ═════════ BEGIN far overlay — doc 12 §2.5, chunk aggregate ════════════════
// The same four hues, the same two motion rates and the same blend weights the
// NEAR shader paints with, so a chunk does not change colour when it crosses
// the LOD boundary — only its granularity does (per building in front, per
// chunk behind). Every value here mirrors a `building.gdshader` uniform.
uniform vec3 overlay_normal_color: source_color = vec3(0.404, 0.463, 0.541);
uniform vec3 overlay_warning_color: source_color = vec3(0.949, 0.694, 0.235);
uniform vec3 overlay_critical_color: source_color = vec3(0.898, 0.325, 0.239);
uniform vec3 overlay_offline_color: source_color = vec3(0.400, 0.070, 0.055);
uniform float overlay_normal_blend = 0.50;
uniform float overlay_data_blend = 0.88;
uniform float overlay_critical_hz = 1.2;
uniform float overlay_offline_hz = 0.35;
uniform float overlay_state_emission = 0.55;
// `family_index + far_overlay_stride * chunk_state` — CityView.FAR_OVERLAY_STRIDE.
uniform float far_overlay_stride = 8.0;
const int OVERLAY_MODE_POWER = 1;
const int OVERLAY_MODE_WATER = 2;
// ═════════ END far overlay ═════════════════════════════════════════════════

// `flat` for the same reason the near shader needs it: interpolating
// INSTANCE_CUSTOM walks `variant` by a fraction of an ulp and the hash below
// multiplies that into a different value per pixel.
varying flat vec4 v_custom;
varying flat float v_rows;
varying flat vec2 v_extent_m;   // (width, depth) of this instance, metres
varying vec3 v_local;
varying vec3 v_lnormal;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	// The unit box is x,z ∈ [-0.5, 0.5], y ∈ [0, 1] (tools/gen_graybox.gd
	// `build_far_box`), so v_local.y IS the normalised height and needs no UV.
	v_local = VERTEX;
	v_lnormal = NORMAL;
	float height_m = length(MODEL_MATRIX[1].xyz);
	v_extent_m = vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[2].xyz));
	v_rows = max(2.0, floor(height_m / max(floor_height_m, 0.01)));
	// Construction sites keep their poured fraction at range too: the box is
	// clamped to stage/6 of its height, matching the near shader's shell.
	float stage = mod(floor(INSTANCE_CUSTOM.b / 16.0), 7.0);
	float keep = mix(1.0, stage * (1.0 / 6.0), step(0.5, stage));
	VERTEX.y *= keep;
}

void fragment() {
	float packed = v_custom.b;
	float variant = mod(packed, 16.0);
	float stage = mod(floor(packed / 16.0), 7.0);
	float is_roof = step(0.5, abs(v_lnormal.y));
	float is_side = 1.0 - is_roof;

	float storey = floor(v_local.y * v_rows);
	float band = fract(v_local.y * v_rows);
	// Metres along whichever wall this fragment is on, so a segment is the same
	// physical size on a 16 m tower face and an 8 m shopfront.
	float use_x = step(abs(v_lnormal.z), abs(v_lnormal.x));
	float along_m = mix((v_local.x + 0.5) * v_extent_m.x,
			(v_local.z + 0.5) * v_extent_m.y, use_x);
	float segment = floor(along_m / max(far_cell_m, 0.5)) + 32.0 * use_x;

	float gate = mix(day_gate, 1.0, sc_night);
	float e = v_custom.r * gate;
	float h = hash21(vec2(segment + variant * 37.0, storey + variant * 11.0));
	float lit = step(band_lo, band) * step(band, band_hi) * step(1.0 - e, h);
	// A site is dark, exactly as in the near shader.
	lit *= is_side * (1.0 - step(0.5, stage));
	// Mullions — the dark strip of wall between two windows — with an ANALYTIC
	// filter instead of a hash. A lit storey at 21:00 has `e ≈ 1`, so nearly
	// every segment lights and the tower would read as one solid stripe per
	// floor; the near tier only escapes that because its texture draws the wall
	// between the panes. The pattern is periodic at `far_bay_m`, and a periodic
	// pattern under minification is exactly the case that moirés — so it is
	// crossfaded to its own MEAN as it approaches a pixel wide. `fwidth(bay)` is
	// bays-per-pixel: below ~0.5 the strip is resolvable and drawn sharp; above
	// it the term becomes the constant `far_mullion_duty`, which is precisely
	// the average the sharp pattern would integrate to. No aliasing at any
	// distance, structure wherever structure is visible.
	float bay = along_m / max(far_bay_m, 0.5);
	float bays_per_px = fwidth(bay);
	float sharp = step(1.0 - far_mullion_duty, fract(bay));
	float mullion = mix(sharp, far_mullion_duty,
			clamp(bays_per_px * 2.0, 0.0, 1.0));
	lit *= mullion;
	float vary = 0.55 + 0.45 * hash21(vec2(storey + 91.0, segment));
	float nits = window_nits_far * far_energy_scale
			* mix(day_nits_scale, 1.0, sc_night);
	// §2.6's per-family hue, indexed off the channel CityView repurposes. The
	// chunk overlay state rides ABOVE the family index in the same float, so
	// take the remainder first — at stride 0 (an older buffer, or a mode with
	// nothing to say) this is exactly the bare index it always was.
	float packed_a = max(v_custom.a, 0.0);
	float fam_raw = far_overlay_stride > 0.5
			? mod(packed_a, far_overlay_stride) : packed_a;
	float chunk_state = far_overlay_stride > 0.5
			? clamp(floor(packed_a / far_overlay_stride), 0.0, 3.0) : 0.0;
	int family = int(clamp(fam_raw, 0.0, 4.0) + 0.5);
	vec3 window_color = window_colors[family];
	EMISSION = window_color * lit * vary * nits * (1.0 - 0.6 * v_custom.g);

	// §2.6b: the family's own pair, blended in from the neutral pair. Both
	// arms are uniform reads and the mix weight is a uniform, so this is two
	// ALU on a tier whose whole point is that it costs nothing.
	vec3 wall_c = mix(base_albedo, far_wall_albedo[family] * far_albedo_gain,
			far_family_mix);
	vec3 roof_c = mix(roof_albedo, far_roof_albedo[family] * far_albedo_gain,
			far_family_mix);
	ALBEDO = mix(wall_c, roof_c, is_roof);
	// §2.6b (2): the day façade. `storey_band` is 1 across the glazed band of
	// a storey and 0 on the spandrel, crossfaded to its own mean as a storey
	// approaches a pixel tall — the same anti-aliasing the mullion takes, for
	// the same reason. `mullion` is reused as computed above.
	float rows_per_px = fwidth(v_local.y * v_rows);
	float storey_sharp = smoothstep(band_lo, band_lo + 0.06, band)
			* (1.0 - smoothstep(band_hi - 0.06, band_hi, band));
	float storey_band = mix(storey_sharp, band_hi - band_lo,
			clamp(rows_per_px * 2.0, 0.0, 1.0));
	float mean_cover = (band_hi - band_lo) * far_mullion_duty;
	float relief = 1.0 + far_relief_depth
			* (storey_band * mullion - mean_cover);
	ALBEDO *= mix(1.0, relief, is_side);
	float tint = (variant / 15.0 - 0.5) * 0.16;
	ALBEDO *= vec3(1.0 + tint, 1.0 + tint * 0.8, 1.0 + tint * 0.55);
	ALBEDO *= mix(vec3(1.0), soot_color, v_custom.g * 0.8);
	ALBEDO = mix(ALBEDO, site_albedo, step(0.5, stage));
	ROUGHNESS = 0.88;
	SPECULAR = 0.30;

	// Identity at sc_wetness = 0, same contract as the near shader.
	ALBEDO *= mix(1.0, wet_albedo_mult, sc_wetness);
	ROUGHNESS = mix(ROUGHNESS, wet_roughness, sc_wetness);

	// One uniform branch over the whole draw: at mode 0 nothing below executes
	// and the frame is bit-exact what it was before the far overlay landed.
	if (sc_overlay_mode > 0) {
		float luma = dot(ALBEDO, vec3(0.2126, 0.7152, 0.0722));
		ALBEDO = mix(ALBEDO, vec3(luma), overlay_desaturate);
		EMISSION *= overlay_emission_mult;
		if (sc_overlay_mode == OVERLAY_MODE_POWER
				|| sc_overlay_mode == OVERLAY_MODE_WATER) {
			// `overlay_paint` from the near shader, inlined: the same tint
			// ladder, the same 1.2 Hz CRITICAL pulse and 0.35 Hz OFFLINE
			// breath, so motion still carries the state when colour cannot
			// (constitution §11).
			vec3 tint = overlay_normal_color;
			tint = mix(tint, overlay_warning_color, step(0.5, chunk_state));
			tint = mix(tint, overlay_critical_color, step(1.5, chunk_state));
			tint = mix(tint, overlay_offline_color, step(2.5, chunk_state));
			float is_data = step(0.5, chunk_state);
			float hz = mix(overlay_critical_hz, overlay_offline_hz,
					step(2.5, chunk_state));
			float pulse01 = 0.5 + 0.5 * sin(sc_time * 6.283185 * hz);
			float pulse_amt = step(1.5, chunk_state) * 0.35 * pulse01;
			float blend = mix(overlay_normal_blend, overlay_data_blend, is_data)
					* (1.0 - pulse_amt);
			ALBEDO = mix(ALBEDO, tint, blend);
			// A dark chunk emits nothing, so the state carries its own light —
			// which is exactly the case a blackout overlay is opened in.
			EMISSION += tint * overlay_state_emission * is_data
					* (0.65 + 0.35 * pulse01);
		}
	}
}
