// The footway (doc 11 §2.1.2). One MultiMesh of unit boxes, scaled per
// instance into kerb runs and corner squares by `RoadSurfaceView`.
//
// Every strip is a box with an arbitrary non-uniform scale, so the mesh's own
// UVs are useless — a 160 m run and a 1.4 m corner would carry the same 0..1
// and the concrete grain would stretch 100:1 between them. The projection is
// therefore WORLD-space and picked per fragment: horizontal on the walking
// surface, vertical on the kerb face. Branchless, because the choice has to be
// made before the ONE texture fetch this shader is allowed (doc 11 §2.6: no
// `texture()` inside divergent control flow).
//
// What makes a kerb read as a kerb, in order of how much each is worth:
//   1. the LIP. 15 cm of vertical face between the gutter and the footway,
//      dark where it meets the road and catching a highlight along its top
//      arris. Without it a footway is a paler rectangle painted on the road.
//   2. SLAB JOINTS on a 1.2 m world grid, so the strip has a pitch the eye can
//      measure the street against — and because the grid is world-space, two
//      strips that meet at a corner share their joints instead of arguing.
//   3. a NIGHT FLOOR between the terrain's and the carriageway's. Concrete is
//      the brightest thing on a night street; matching it to the asphalt would
//      erase the very kerb line this pass exists to draw.
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

global uniform float sc_wetness;
global uniform float sc_night;
global uniform int sc_overlay_mode;

uniform sampler2D page: source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float has_page = 1.0;
uniform vec3 tint: source_color = vec3(0.61, 0.61, 0.58);
uniform vec3 kerb_tint: source_color = vec3(0.56, 0.55, 0.52);
uniform float page_tile_m = 4.0;

uniform float top_y = 0.25;
uniform float asphalt_y = 0.10;
uniform float joint_period_m = 1.20;
uniform float joint_darken = 0.30;
uniform float kerb_dark = 0.72;
uniform float kerb_edge_gain = 0.16;

uniform float dry_roughness = 0.93;
uniform float dry_specular = 0.30;
uniform float wet_roughness = 0.18;
uniform float wet_specular = 0.85;
uniform float wet_albedo_mult = 0.62;

uniform vec3 night_color: source_color = vec3(0.42, 0.53, 0.72);
uniform float night_albedo_lift = 0.22;
uniform float night_glow = 0.030;
uniform float night_glow_wet_mult = 0.55;
uniform float overlay_desaturate = 0.55;

varying vec3 v_world;
varying vec3 v_nrm;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float band(float d, float hw, float aa) {
	return 1.0 - smoothstep(hw - aa, hw + aa, abs(d));
}

void fragment() {
	float up = step(0.7, abs(v_nrm.y));
	// Vertical faces project along whichever horizontal axis they do NOT face.
	vec2 uv_side = vec2(v_world.x * abs(v_nrm.z) + v_world.z * abs(v_nrm.x), -v_world.y);
	vec2 uv = mix(uv_side, v_world.xz, up);
	vec3 surface = texture(page, uv / max(page_tile_m, 0.01)).rgb;

	vec3 base = mix(kerb_tint, tint, up) * mix(vec3(1.0), surface, has_page);

	// Slab joints, world-aligned so neighbouring strips agree.
	vec2 jd = abs(fract(v_world.xz / joint_period_m + 0.5) - 0.5) * joint_period_m;
	float aa_j = max(fwidth(v_world.x) * 0.75, 0.0008);
	float joint = max(band(jd.x, 0.022, aa_j), band(jd.y, 0.022, aa_j));
	base *= 1.0 - joint * joint_darken * up;

	// The lip: dark at the gutter, bright along the top arris.
	float side = 1.0 - up;
	float t = clamp((v_world.y - asphalt_y) / max(top_y - asphalt_y, 0.001), 0.0, 1.0);
	base *= mix(1.0, mix(kerb_dark, 1.0, smoothstep(0.0, 0.5, t)), side);
	base += side * kerb_edge_gain * smoothstep(0.84, 1.0, t);

	base *= mix(1.0, wet_albedo_mult, sc_wetness);
	base += night_color * (night_albedo_lift * sc_night);

	ALBEDO = base;
	EMISSION = night_color * (night_glow * sc_night
			* mix(1.0, night_glow_wet_mult, sc_wetness));
	ROUGHNESS = mix(dry_roughness, wet_roughness, sc_wetness);
	SPECULAR = mix(dry_specular, wet_specular, sc_wetness);

	if (sc_overlay_mode > 0) {
		float luma = dot(ALBEDO, vec3(0.2126, 0.7152, 0.0722));
		ALBEDO = mix(ALBEDO, vec3(luma), overlay_desaturate);
		float glow_luma = dot(EMISSION, vec3(0.2126, 0.7152, 0.0722));
		EMISSION = mix(EMISSION, vec3(glow_luma), overlay_desaturate);
	}
}
