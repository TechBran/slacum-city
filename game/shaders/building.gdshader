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
// identity) and takes the finished branch below UNCHANGED, bit for bit: the
// window-hash contract mirrored by `RenderStateModel.hash21` /
// `lit_window_count` must not move. The branch is deliberate — it is cheaper
// than blending both looks on every fragment of every finished building, and it
// is coherent (whole instances take the same side).
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

varying vec4 v_custom;
varying vec2 v_uv2;
varying vec4 v_color;
// .x = clamped model-space height, .y = perimeter coord, .z = normal.y
varying vec3 v_build;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

// §2.6 unpack: packed = variant + 16*stage + 112*overlay.
float stage_of(float packed) {
	return mod(floor(packed / 16.0), 7.0);
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
}

void fragment() {
	float packed = v_custom.b;
	float variant = mod(packed, 16.0);
	float stage = stage_of(packed);

	if (stage < 0.5) {
		// ------------------------------------ finished building (unchanged)
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
			EMISSION = window_color * lit * vary * flk * window_nits
					* (1.0 - 0.6 * v_custom.g);
		}
		ALBEDO = base_albedo * v_color.rgb;                       // baked vertex AO
		// Per-building facade variation: variant shifts tone slightly so a block
		// of identical archetypes never reads as copy-paste.
		float tint = (variant / 15.0 - 0.5) * 0.16;
		ALBEDO *= vec3(1.0 + tint, 1.0 + tint * 0.8, 1.0 + tint * 0.55);
		ALBEDO *= mix(vec3(1.0), soot_color, v_custom.g * 0.8);   // damage soot
		ROUGHNESS = 0.85;
		SPECULAR = 0.35;
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
}
