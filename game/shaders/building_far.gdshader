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
// for a phase to drive — so `.a` carries the building's FAMILY INDEX instead
// (0 residential … 4 civic). That is what buys per-family window colour inside
// a single draw call per chunk. `.r`, `.g` and `.b` are copied across from the
// near buffer untouched, so a chunk crossing the boundary mid-blackout carries
// its exact emissive ramp, damage and construction stage over the swap.
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

global uniform float sc_night;
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
uniform vec3 soot_color: source_color = vec3(0.278, 0.263, 0.239);
uniform float wet_albedo_mult = 0.85;
uniform float wet_roughness = 0.42;
uniform float overlay_desaturate = 0.55;
uniform float overlay_emission_mult = 0.40;

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
	// §2.6's per-family hue, indexed off the channel CityView repurposes.
	int family = int(clamp(v_custom.a, 0.0, 4.0) + 0.5);
	vec3 window_color = window_colors[family];
	EMISSION = window_color * lit * vary * nits * (1.0 - 0.6 * v_custom.g);

	ALBEDO = mix(base_albedo, roof_albedo, is_roof);
	float tint = (variant / 15.0 - 0.5) * 0.16;
	ALBEDO *= vec3(1.0 + tint, 1.0 + tint * 0.8, 1.0 + tint * 0.55);
	ALBEDO *= mix(vec3(1.0), soot_color, v_custom.g * 0.8);
	ALBEDO = mix(ALBEDO, site_albedo, step(0.5, stage));
	ROUGHNESS = 0.88;
	SPECULAR = 0.30;

	// Identity at sc_wetness = 0, same contract as the near shader.
	ALBEDO *= mix(1.0, wet_albedo_mult, sc_wetness);
	ROUGHNESS = mix(ROUGHNESS, wet_roughness, sc_wetness);

	if (sc_overlay_mode > 0) {
		float luma = dot(ALBEDO, vec3(0.2126, 0.7152, 0.0722));
		ALBEDO = mix(ALBEDO, vec3(luma), overlay_desaturate);
		EMISSION *= overlay_emission_mult;
	}
}
