// Building window shader (doc 11 §2.6). One of exactly two building shaders
// in the game. INSTANCE_CUSTOM: .r emissive_scale (the fraction of windows
// lit), .g damage, .b packed variant/stage/overlay, .a anim_phase.
// UV2 = (-1,-1) on non-façade surfaces, else [0,1]² across the façade.
// Vertex COLOR carries baked AO (§2.14).
//
// `stage` (0 = finished, 1..6 = construction sixths) also drives the LOOK of a
// building site. The vertex stage clamps every vertex to `stage/6 ·
// build_height_m`, so the shell grows bottom-up and the collapsed upper
// geometry lands exactly on the pour plane, capping the shell — no discard, no
// culling change, early-Z intact. stage 0 clamps against 1e9 (`min` is then the
// identity) and takes the finished branch below UNCHANGED: the window-hash
// contract mirrored by `RenderStateModel.hash21` / `lit_window_count` must not
// move. The stage branch is coherent (stage is per-instance and `flat`, so
// whole instances take one side); the texture fetches stay OUTSIDE it because
// texture() under divergent control flow has undefined derivatives on tiled
// mobile GPUs — both agents' invariants, kept.
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

global uniform float sc_night;
global uniform float sc_time;
// §2.9's wetness integrator and §2.5's overlay mode. Both are project shader
// globals with a 0 default, and BOTH consumers below are written so that
// sc_wetness = 0.0 and sc_overlay_mode = 0 reproduce the pre-atmosphere
// output bit for bit — `mix(a, b, 0.0)` is exactly `a`, and the whole overlay
// block is skipped by a uniform branch. The §2.6 window-hash contract that
// RenderStateModel.lit_window_count mirrors is never touched by either.
global uniform float sc_wetness;
global uniform int sc_overlay_mode;

uniform float window_cols = 4.0;
uniform float window_rows = 3.0;
uniform vec3 window_color: source_color = vec3(1.0, 0.808, 0.541);
uniform float window_nits = 3.2;
uniform vec3 base_albedo: source_color = vec3(0.60, 0.585, 0.565);
uniform vec3 soot_color: source_color = vec3(0.278, 0.263, 0.239);
uniform float near_flicker = 1.0;
uniform float day_gate = 0.06;

// ------------------------------------------------ construction (stage 1..6)
// `build_height_m` is the mesh's own `height_m` from the gray-box manifest,
// pushed per bucket by CityView; everything else is art with a default here and
// an optional `construction` override block in data/render.json.
uniform float build_height_m = 10.0;
uniform vec3 shell_albedo: source_color = vec3(0.38, 0.372, 0.355);
uniform vec3 scaffold_color: source_color = vec3(0.72, 0.63, 0.44);
uniform vec3 work_light_color: source_color = vec3(1.0, 0.66, 0.36);
uniform float work_light_nits = 0.55;
uniform float lift_m = 2.6;             // poured-lift spacing (form-work lines)
uniform float scaffold_period_m = 1.45; // post spacing around the perimeter
uniform float scaffold_duty = 0.42;
uniform float rim_frac = 0.10;          // working band, fraction of built height
uniform float rim_min_m = 0.45;
uniform float rim_max_m = 3.0;
uniform float scaffold_blend = 0.75;
uniform float slab_lighten = 0.12;      // fresh pour reads lighter than the shell
uniform float lift_depth = 0.14;

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

// ═════════ BEGIN atmosphere pass — wetness (doc 11 §2.9) ══════════════════
// The doc's wet-ground cheat #1 is authored for road/ground (albedo ×0.62).
// A façade is not asphalt: it darkens where rain runs down it and picks up a
// sheen, but a 38% darken turns a lit block into a silhouette. These are the
// building-side values — subtle on purpose, and exactly identity at
// sc_wetness = 0.
uniform float wet_albedo_mult = 0.85;   // ~15% darker when fully soaked
uniform float wet_roughness = 0.42;     // walls never go full mirror
uniform float wet_specular = 0.72;
// ═════════ END atmosphere pass ════════════════════════════════════════════

// ═════════ BEGIN overlay pass — sc_overlay_mode (doc 12 §2.5) ═════════════
// The world greys back and the data reads forward. Blend/emission strengths
// are data/render.json's `overlay.desaturate_blend` / `overlay.emission_mult`;
// the four state hues are doc 12 §2.5's constitution-compliant palette, with
// the POWER wash deliberately NOT the green `#33C27A` of the legend — a city
// where every healthy building glows green is a city where nothing reads.
// NORMAL is a cool neutral, and only the three states that mean "look here"
// carry hue.
uniform float overlay_desaturate = 0.55;
uniform float overlay_emission_mult = 0.40;
uniform vec3 overlay_normal_color: source_color = vec3(0.404, 0.463, 0.541);
uniform vec3 overlay_warning_color: source_color = vec3(0.949, 0.694, 0.235);
uniform vec3 overlay_critical_color: source_color = vec3(0.898, 0.325, 0.239);
uniform vec3 overlay_offline_color: source_color = vec3(0.400, 0.070, 0.055);
uniform float overlay_normal_blend = 0.50;
uniform float overlay_data_blend = 0.88;
uniform float overlay_critical_hz = 1.2;   // doc 12 §2.5 CRITICAL motion
uniform float overlay_offline_hz = 0.35;   // slow, "dead" — never confused with it
uniform float overlay_state_emission = 0.55;
// POWER mode reads the service state straight out of the emissive channel,
// which IS the model's powered/backup/dark ladder: RenderStateModel's
// `emissive_target_for` writes `dark_lit` 0.05, `backup_lit` 0.22 and
// `powered_base` 0.55 + occupancy. No second channel, no extra packing bit,
// and it is exactly as day/night-independent as the ladder itself — the
// §2.6 `day_gate` is applied further down, to how many windows light, never
// to `v_custom.r`. A damage-dimmed or condition-critical building lands in
// the middle band and reads WARNING, which is the honest answer.
uniform float power_dark_lo = 0.10;
uniform float power_dark_hi = 0.17;
uniform float power_weak_lo = 0.30;
uniform float power_weak_hi = 0.42;
// WATER mode reads the SAME 2-bit `overlay_state` (C-64) — no second channel,
// no extra packing bit. `RenderStateModel.set_overlay_channel(&"water", …)`
// maps doc 05's per-building service factor onto those two bits while mode 2
// is active and restores each building's own state on the way out, so the two
// modes are one decoder here and the buffer layout §2.6 fixes never moved.
// A mode with no channel published simply shows every building NORMAL under
// the grey wash, which is what "this system has nothing to say" looks like.
const int OVERLAY_MODE_POWER = 1;
const int OVERLAY_MODE_WATER = 2;
// ═════════ END overlay pass ═══════════════════════════════════════════════

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
// .x = clamped model-space height, .y = perimeter coord, .z = normal.y
varying vec3 v_build;
// ═════════ BEGIN texture pass — model-space varyings ══════════════════════
varying vec3 v_local;    // model-space position: metres, y = 0 at the pad
varying vec3 v_lnormal;  // model-space normal: picks the projection plane
// ═════════ END texture pass ═══════════════════════════════════════════════

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

// §2.6 unpack: packed = variant + 16*stage + 112*overlay.
float stage_of(float packed) {
	return mod(floor(packed / 16.0), 7.0);
}

// The 2-bit overlay_state doc 12 §2.5 / report C-64 pack at stride 112:
// 0 NORMAL, 1 WARNING, 2 CRITICAL, 3 OFFLINE.
float overlay_of(float packed) {
	return clamp(floor(packed / 112.0), 0.0, 3.0);
}

// One state 0..3 → the hue it wears, the albedo blend weight, and (through
// `emit_amt`) how much light it carries of its own. Shared by every
// per-building overlay so POWER and WATER cannot drift apart visually: the
// only thing that differs between them is how the state was DERIVED.
//
// Motion is part of the answer, not decoration (doc 12 §2.5, constitution §11:
// colour is never load-bearing). CRITICAL pulses at 1.2 Hz, OFFLINE breathes
// slowly at 0.35 Hz, and the two lower states hold still.
vec4 overlay_paint(float state, out float emit_amt) {
	vec3 tint = overlay_normal_color;
	tint = mix(tint, overlay_warning_color, step(0.5, state));
	tint = mix(tint, overlay_critical_color, step(1.5, state));
	tint = mix(tint, overlay_offline_color, step(2.5, state));
	float is_data = step(0.5, state);
	float hz = mix(overlay_critical_hz, overlay_offline_hz, step(2.5, state));
	float pulse01 = 0.5 + 0.5 * sin(sc_time * 6.283185 * hz);
	float pulse_amt = step(1.5, state) * 0.35 * pulse01;
	float blend = mix(overlay_normal_blend, overlay_data_blend, is_data)
			* (1.0 - pulse_amt);
	// A dark building emits nothing, so the state has to carry its own light or
	// the overlay is unreadable at night — which is exactly when a blackout or a
	// dry main is being diagnosed.
	emit_amt = overlay_state_emission * is_data * (0.65 + 0.35 * pulse01);
	return vec4(tint, blend);
}

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	v_uv2 = UV2;
	v_color = COLOR;
	float stage = stage_of(INSTANCE_CUSTOM.b);
	// stage 0 -> cut = 1e9, i.e. no clamp at all and no vertex moved.
	float cut = build_height_m * stage * (1.0 / 6.0)
			+ (1.0 - step(0.5, stage)) * 1.0e9;
	// A roof or deck pressed onto the pour plane has to shade as the flat slab
	// it now is; a wall cut by the same plane keeps its own normal. A collapsed
	// overhang UNDERSIDE would land coplanar with its own top face, so it sinks
	// 2 cm and the pour cap wins the depth test instead of speckling against it.
	// Both terms vanish at stage 0, where nothing is clamped.
	float clamped = step(cut, VERTEX.y);
	float faces_up = step(0.25, NORMAL.y);
	float faces_down = 1.0 - step(-0.25, NORMAL.y);
	NORMAL = mix(NORMAL, vec3(0.0, 1.0, 0.0), clamped * faces_up);
	VERTEX.y = min(VERTEX.y, cut) - clamped * faces_down * 0.02;
	// x+z is continuous around an axis-aligned perimeter and constant straight
	// up a wall, so one interpolator carries the scaffold-post coordinate.
	v_build = vec3(VERTEX.y, VERTEX.x + VERTEX.z, NORMAL.y);
	// ═════════ BEGIN texture pass ═════════════════════════════════════════
	// Post-clamp on purpose: the varyings describe the geometry actually drawn.
	v_local = VERTEX;
	v_lnormal = NORMAL;
	// ═════════ END texture pass ═══════════════════════════════════════════
}

void fragment() {
	float packed = v_custom.b;
	float variant = mod(packed, 16.0);
	float stage = stage_of(packed);

	// ═════════ BEGIN texture pass — surface sample ════════════════════════
	// Both pages are sampled unconditionally and blended by normal: a
	// texture() inside divergent control flow has undefined derivatives on
	// tiled mobile GPUs, and the façade/roof split falls exactly on the
	// geometry edges where that would bite. (The stage branch below is
	// per-instance-coherent, but the fetches stay out here regardless.)
	float is_roof = step(0.5, abs(v_lnormal.y));
	float has_uv2 = step(0.0, v_uv2.x);
	// The gray-box's second UV2 sentinel (tools/gen_graybox.gd UV2_ROOF_PLANAR,
	// (-1,-2)): "no window grid, and this is a ROOF surface". It marks every
	// roof PROP and every gable — mech boxes, crowns, masts, aprons, gable ends
	// — and it is the fix for the texture pass's open question 3. Without it a
	// prop side fell through to the façade projection and a rooftop chiller came
	// out clad in brick with a sash window sliced across it; a house's gable end
	// grew half a window in the middle of the shingle. `is_roof` already catches
	// their TOPS by normal; this catches their SIDES, which have no normal to
	// tell them apart from a wall.
	//
	// The windowless data-centre walls keep (-1,-1) and keep the façade page,
	// which is right: a blank composite cassette wall IS that building's façade,
	// and `techpanel` is the page that draws it.
	float prop_side = (1.0 - has_uv2) * step(v_uv2.y, -1.5) * (1.0 - is_roof);
	float use_roof = max(is_roof, prop_side);
	// Façade bay coordinate == the emissive cell coordinate, by construction.
	vec2 bay_uv2 = v_uv2 * vec2(window_cols, window_rows);
	// Surfaces the gray-box left without a window grid get a model-space planar
	// projection at the same bay size, so scale still matches.
	float pick_z = step(abs(v_lnormal.z), abs(v_lnormal.x));
	float along_m = mix(v_local.x, v_local.z, pick_z);
	vec2 bay_planar = vec2(along_m / bay_m.x, v_local.y / bay_m.y);
	vec2 bay = mix(bay_planar, bay_uv2, has_uv2);
	// variant shifts the façade by a whole bay: different neighbours, and the
	// emissive-cell alignment survives exactly.
	float bay_shift = mod(variant, 2.0);
	// 2.0 - bay.y flips v (image origin is top-left) and pins bay row 0 — the
	// ground floor — to the page's bottom half, which is what lets the
	// storefront page put shopfront glazing under the sign band.
	vec4 facade_s = texture(facade_tex,
			vec2(bay.x + bay_shift, 2.0 - bay.y) * 0.5);
	// One roof fetch, two projections, chosen branchlessly: XZ for a deck, and
	// (along, up) for a prop's flank. Still exactly TWO texture fetches on the
	// whole building pass — a third sampler for prop sides would have cost the
	// entire city a fetch to dress a handful of rooftop boxes.
	vec2 roof_uv = mix(v_local.xz, vec2(along_m, -v_local.y), prop_side)
			/ roof_tile_m;
	vec4 roof_s = texture(roof_tex, roof_uv);
	vec4 surf = mix(facade_s, roof_s, use_roof);
	float shine = surf.a * tex_mix;
	// ═════════ END texture pass ═══════════════════════════════════════════

	if (stage < 0.5) {
		// ------------------------------------ finished building (textured)
		if (v_uv2.x < 0.0) {
			EMISSION = vec3(0.0);
		} else {
			vec2 cell = floor(v_uv2 * vec2(window_cols, window_rows));
			float h = hash21(cell + vec2(variant * 37.0, variant * 11.0));
			float gate = mix(day_gate, 1.0, sc_night);
			float e = v_custom.r * gate;
			float lit = step(1.0 - e, h);      // emissive_scale IS the lit fraction
			float vary = 0.35 + 0.65 * hash21(cell + 91.0);
			float flk = 1.0 - near_flicker * 0.25
					* step(0.985, hash21(cell + floor(sc_time * 3.0)));
			// texture pass: confine the glow to the drawn pane, spill a little
			// onto the wall at night, and pull the daytime interiors down out of
			// the bloom. tex_mix = 0 → pane = 1.0 and nits = window_nits.
			float pane = mix(1.0, shine + night_spill * sc_night * (1.0 - shine),
					tex_mix);
			float nits = window_nits
					* mix(1.0, mix(day_nits_scale, 1.0, sc_night), tex_mix);
			EMISSION = window_color * lit * vary * flk * nits
					* (1.0 - 0.6 * v_custom.g) * pane;
		}
		// texture pass: tex_mix = 0 restores `base_albedo` exactly.
		ALBEDO = mix(base_albedo, surf.rgb, tex_mix) * v_color.rgb;  // baked AO
		// Per-building facade variation: variant shifts tone slightly so a block
		// of identical archetypes never reads as copy-paste.
		float tint = (variant / 15.0 - 0.5) * 0.16;
		ALBEDO *= vec3(1.0 + tint, 1.0 + tint * 0.8, 1.0 + tint * 0.55);
		ALBEDO *= mix(vec3(1.0), soot_color, v_custom.g * 0.8);   // damage soot
		// texture pass: shine = 0 gives the old flat 0.85 / 0.35 pair.
		ROUGHNESS = mix(wall_roughness, glass_roughness, shine);
		SPECULAR = mix(wall_specular, glass_specular, shine);
	} else {
		// ------------------------------------------ site: stage/6 poured
		float cut = build_height_m * stage * (1.0 / 6.0);
		float y = v_build.x;
		// Decks (slabs, and the roofs pressed onto the pour plane) take the
		// fresh-pour tone and carry neither form lines nor scaffold: flat and
		// AO-free, so surfaces collapsed onto the same plane are shaded
		// identically and their coplanarity cannot speckle.
		float deck = smoothstep(0.35, 0.70, v_build.z);
		float band = clamp(cut * rim_frac, rim_min_m, rim_max_m);
		float rim = (1.0 - deck) * (1.0 - smoothstep(0.0, band, cut - y));
		float post = step(scaffold_duty, fract(v_build.y / scaffold_period_m));
		float lift = (1.0 - deck) * smoothstep(0.88, 1.0, fract(y / lift_m));
		float work = rim * (0.25 + 0.75 * post);   // the working edge + its posts

		vec3 shell = shell_albedo * mix(v_color.rgb, vec3(1.0), deck);
		shell *= 1.0 - lift_depth * lift;          // form-work joints per lift
		shell *= 1.0 + slab_lighten * deck;
		ALBEDO = mix(shell, scaffold_color, scaffold_blend * work);
		// Windows are NEVER lit on a site. At night a couple of work lamps
		// graze the top band; the rest of the shell stays dark.
		float pulse = 0.88 + 0.12 * sin(sc_time * 1.7 + v_custom.a * 6.283185);
		EMISSION = work_light_color * (work_light_nits * sc_night * work * pulse);
		ROUGHNESS = 0.94;
		SPECULAR = 0.18;
	}

	// ═════════ BEGIN atmosphere pass — wet façades (§2.9) ═════════════════
	// Applied to both branches: a construction shell gets rained on too. Every
	// term is an exact identity at sc_wetness = 0, so the dry frame is the
	// frame that shipped. EMISSION is untouched — a wet window is not a
	// brighter window, and lit_window_count must keep mirroring this shader.
	ALBEDO *= mix(1.0, wet_albedo_mult, sc_wetness);
	ROUGHNESS = mix(ROUGHNESS, wet_roughness, sc_wetness);
	SPECULAR = mix(SPECULAR, wet_specular, sc_wetness);
	// ═════════ END atmosphere pass ════════════════════════════════════════

	// ═════════ BEGIN overlay pass — sc_overlay_mode (doc 12 §2.5) ═════════
	// One uniform branch over the whole draw: at mode 0 not a single
	// instruction below executes and the finished-building path is bit-exact.
	if (sc_overlay_mode > 0) {
		// The world greys back (§2.5's de-emphasis) in every mode, including
		// the four that have no data yet — an empty overlay must still look
		// like an overlay, or the player thinks the toggle is broken.
		float luma = dot(ALBEDO, vec3(0.2126, 0.7152, 0.0722));
		ALBEDO = mix(ALBEDO, vec3(luma), overlay_desaturate);
		EMISSION *= overlay_emission_mult;
		if (sc_overlay_mode == OVERLAY_MODE_POWER
				|| sc_overlay_mode == OVERLAY_MODE_WATER) {
			// Both per-building overlays start from the packed 2-bit state
			// (doc 11 owns it: damage → WARNING, destroyed → OFFLINE; under
			// WATER, RenderStateModel has mapped doc 05's service factor onto
			// those same two bits and saved each building's own value).
			float state = overlay_of(packed);
			if (sc_overlay_mode == OVERLAY_MODE_POWER) {
				// POWER also reads the service state off the emissive ladder
				// and takes the WORSE of the two. `max` is correct because
				// 0..3 IS the severity order.
				float e_raw = v_custom.r;
				float dark = 1.0 - smoothstep(power_dark_lo, power_dark_hi, e_raw);
				float weak = (1.0 - dark)
						* (1.0 - smoothstep(power_weak_lo, power_weak_hi, e_raw));
				state = max(state, dark * 3.0 + weak * 1.0);
			}
			float emit_amt;
			vec4 paint = overlay_paint(state, emit_amt);
			ALBEDO = mix(ALBEDO, paint.rgb, paint.w);
			EMISSION += paint.rgb * emit_amt;
		}
	}
	// ═════════ END overlay pass ═══════════════════════════════════════════
}
