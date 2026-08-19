// Building window shader (doc 11 §2.6). One of exactly two building shaders
// in the game. INSTANCE_CUSTOM: .r emissive_scale (the fraction of windows
// lit), .g damage, .b packed variant/stage/overlay, .a anim_phase.
// UV2 = (-1,-1) on non-façade surfaces, else [0,1]² across the façade.
// Vertex COLOR carries baked AO (§2.14).
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

global uniform float sc_night;
global uniform float sc_time;

uniform float window_cols = 4.0;
uniform float window_rows = 3.0;
uniform vec3 window_color: source_color = vec3(1.0, 0.808, 0.541);
uniform float window_nits = 3.2;
uniform vec3 base_albedo: source_color = vec3(0.60, 0.585, 0.565);
uniform vec3 soot_color: source_color = vec3(0.278, 0.263, 0.239);
uniform float near_flicker = 1.0;
uniform float day_gate = 0.06;

// ═════════ BEGIN texture pass — tools/gen_textures.py ═════════════════════
// Self-contained block: delete it and set tex_mix = 0.0 to get the untextured
// gray-box back byte for byte. Facade pages are a seamless 2×2 grid of window
// BAYS, so one texture bay lands exactly on one emissive cell — the glow comes
// up inside the drawn pane instead of over the whole wall. RGB = albedo with
// the shading already baked in (reveals, sills, mullion drop shadows); A =
// shine mask (glass / polished metal), which drives ROUGHNESS, SPECULAR and
// the emissive shape. No normal map: at 18–420 m it would not pay for itself.
uniform sampler2D facade_tex: source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D roof_tex: source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float tex_mix = 1.0;          // 0 → untextured fallback, 1 → textured
uniform float roof_tile_m = 4.0;      // metres per roof-page repeat
uniform vec2 bay_m = vec2(3.2, 3.5);  // bay size for surfaces without UV2
uniform float wall_roughness = 0.85;
uniform float glass_roughness = 0.16;
uniform float wall_specular = 0.35;
uniform float glass_specular = 0.62;
// Light spilling from a lit pane onto the wall around it. Night only, and it
// multiplies the SAME per-cell `lit`, so §2.6's "emissive_scale is the fraction
// of windows lit" is untouched — this only softens the edge of a lit cell so a
// tower does not read as a black slab with stickers on it.
uniform float night_spill = 0.05;
// A lit interior at midday is dimmer than the sunlit wall in front of it.
// `window_nits` is calibrated for night, and at full strength in daylight the
// §2.6 day_gate windows punch through glow_hdr_threshold and read as white
// stickers. This scales brightness only — `day_gate` still decides *how many*
// cells are lit, so lit_window_count is unaffected.
uniform float day_nits_scale = 0.30;
// ═════════ END texture pass ═══════════════════════════════════════════════

// `flat`, and it is load-bearing. INSTANCE_CUSTOM is constant over an
// instance, but interpolating it still walks the value by a fraction of an
// ulp — and `variant * 37.0` inside hash21 amplifies that into a *different
// hash per pixel*, which is why the untextured build dithered every lit
// window into salt-and-pepper instead of filling it. Flat interpolation makes
// `variant` exactly integral, so the shader finally computes the same
// per-cell hash that RenderStateModel.lit_window_count mirrors (§2.6).
varying flat vec4 v_custom;
varying vec2 v_uv2;
varying vec4 v_color;
// ═════════ BEGIN texture pass — model-space varyings ══════════════════════
varying vec3 v_local;    // model-space position: metres, y = 0 at the pad
varying vec3 v_lnormal;  // model-space normal: picks the projection plane
// ═════════ END texture pass ═══════════════════════════════════════════════

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	v_uv2 = UV2;
	v_color = COLOR;
	// ═════════ BEGIN texture pass ═════════════════════════════════════════
	v_local = VERTEX;
	v_lnormal = NORMAL;
	// ═════════ END texture pass ═══════════════════════════════════════════
}

void fragment() {
	float packed = v_custom.b;
	float variant = mod(packed, 16.0);

	// ═════════ BEGIN texture pass — surface sample ════════════════════════
	// Both pages are sampled unconditionally and blended by normal: a
	// texture() inside divergent control flow has undefined derivatives on
	// tiled mobile GPUs, and the façade/roof split falls exactly on the
	// geometry edges where that would bite.
	float is_roof = step(0.5, abs(v_lnormal.y));
	float has_uv2 = step(0.0, v_uv2.x);
	// Façade bay coordinate == the emissive cell coordinate, by construction.
	vec2 bay_uv2 = v_uv2 * vec2(window_cols, window_rows);
	// Surfaces the gray-box left without a window grid — gable ends, the
	// windowless data-center walls, roof-prop sides — get a model-space planar
	// projection at the same bay size, so scale still matches.
	float pick_z = step(abs(v_lnormal.z), abs(v_lnormal.x));
	vec2 bay_planar = vec2(mix(v_local.x, v_local.z, pick_z) / bay_m.x,
			v_local.y / bay_m.y);
	vec2 bay = mix(bay_planar, bay_uv2, has_uv2);
	// variant shifts the façade by a whole bay: different neighbours, and the
	// emissive-cell alignment survives exactly.
	float bay_shift = mod(variant, 2.0);
	// 2.0 - bay.y flips v (image origin is top-left) and pins bay row 0 — the
	// ground floor — to the page's bottom half, which is what lets the
	// storefront page put shopfront glazing under the sign band.
	vec4 facade_s = texture(facade_tex,
			vec2(bay.x + bay_shift, 2.0 - bay.y) * 0.5);
	vec4 roof_s = texture(roof_tex, v_local.xz / roof_tile_m);
	vec4 surf = mix(facade_s, roof_s, is_roof);
	float shine = surf.a * tex_mix;
	// ═════════ END texture pass ═══════════════════════════════════════════

	if (v_uv2.x < 0.0) {
		EMISSION = vec3(0.0);
	} else {
		vec2 cell = floor(v_uv2 * vec2(window_cols, window_rows));
		float h = hash21(cell + vec2(variant * 37.0, variant * 11.0));
		float gate = mix(day_gate, 1.0, sc_night);
		float e = v_custom.r * gate;
		float lit = step(1.0 - e, h);          // emissive_scale IS the lit fraction
		float vary = 0.35 + 0.65 * hash21(cell + 91.0);
		float flk = 1.0 - near_flicker * 0.25
				* step(0.985, hash21(cell + floor(sc_time * 3.0)));
		// texture pass: confine the glow to the drawn pane, spill a little onto
		// the wall at night, and pull the daytime interiors down out of the
		// bloom. tex_mix = 0 → pane = 1.0 and nits = window_nits, the old look.
		float pane = mix(1.0, shine + night_spill * sc_night * (1.0 - shine),
				tex_mix);
		float nits = window_nits
				* mix(1.0, mix(day_nits_scale, 1.0, sc_night), tex_mix);
		EMISSION = window_color * lit * vary * flk * nits
				* (1.0 - 0.6 * v_custom.g) * pane;
	}
	// texture pass: tex_mix = 0 restores `base_albedo` exactly.
	ALBEDO = mix(base_albedo, surf.rgb, tex_mix) * v_color.rgb;  // baked vertex AO
	// Per-building facade variation: variant shifts tone slightly so a block
	// of identical archetypes never reads as copy-paste.
	float tint = (variant / 15.0 - 0.5) * 0.16;
	ALBEDO *= vec3(1.0 + tint, 1.0 + tint * 0.8, 1.0 + tint * 0.55);
	ALBEDO *= mix(vec3(1.0), soot_color, v_custom.g * 0.8);   // damage soot
	// texture pass: shine = 0 gives the old flat 0.85 / 0.35 pair.
	ROUGHNESS = mix(wall_roughness, glass_roughness, shine);
	SPECULAR = mix(wall_specular, glass_specular, shine);
}
