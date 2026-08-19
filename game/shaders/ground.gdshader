// Ground / road surface (doc 11 §2.1, §2.9 wet-ground cheat #1, §2.5 overlay).
//
// This replaces the StandardMaterial3D `GroundSurface` used to hand out. It is
// the same surface — one tiled page, one tint, one roughness — plus the two
// things a StandardMaterial3D structurally cannot do: read a project shader
// global, and therefore respond to weather and to the overlay mode. With
// sc_wetness = 0 and sc_overlay_mode = 0 the output is the flat tinted page
// that shipped.
//
// Wet asphalt is doc 11's single biggest rain read: darker AND glossier, so
// the sun and the lamp pools smear along it. Values are `weather.wet_*` in
// data/render.json, pushed by GroundSurface so the numbers live in one place.
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

global uniform float sc_wetness;
global uniform int sc_overlay_mode;

uniform sampler2D page: source_color, filter_linear_mipmap_anisotropic, repeat_enable;
// 0 → no generated page on this clone: fall back to the flat tint, exactly as
// GroundSurface's untextured path always has.
uniform float has_page = 1.0;
uniform vec3 tint: source_color = vec3(1.0, 1.0, 1.0);
uniform vec2 uv_scale = vec2(1.0, 1.0);

uniform float dry_roughness = 0.92;
uniform float dry_specular = 0.30;
uniform float wet_roughness = 0.18;
uniform float wet_specular = 0.85;
uniform float wet_albedo_mult = 0.62;

uniform float overlay_desaturate = 0.55;

void fragment() {
	vec3 surface = texture(page, UV * uv_scale).rgb;
	ALBEDO = tint * mix(vec3(1.0), surface, has_page);
	ALBEDO *= mix(1.0, wet_albedo_mult, sc_wetness);
	ROUGHNESS = mix(dry_roughness, wet_roughness, sc_wetness);
	SPECULAR = mix(dry_specular, wet_specular, sc_wetness);
	if (sc_overlay_mode > 0) {
		float luma = dot(ALBEDO, vec3(0.2126, 0.7152, 0.0722));
		ALBEDO = mix(ALBEDO, vec3(luma), overlay_desaturate);
	}
}
