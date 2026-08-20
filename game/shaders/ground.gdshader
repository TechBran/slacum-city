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
//
// ── the night floor (report NIGHT-1) ──────────────────────────────────────
// Asphalt is albedo 0.34. Multiplied by a deep-night ambient it is 0, and the
// street grid — the one piece of the city that tells a player where anything
// IS — disappeared between the lamp pools on a real device. Raising ambient
// alone cannot fix a road: albedo is a REFLECTANCE, so a brighter tint on an
// unlit surface is still black. So the surface carries two night terms:
//
//   `night_albedo_lift`  cool lift on the tint, so what light there IS bounces
//                        more of it back — the moonlit half of the read.
//   `night_glow`         a small EMISSION, which is the SKYGLOW a real city
//                        street sits under: sodium and window light scattered
//                        off the haze and landing back on the road. It is the
//                        floor that survives ambient going to zero.
//
// Both ride `sc_night`, so nothing changes by day, and both are authored per
// surface in data/render.json's `ground` block — the ROAD gets roughly twice
// the terrain's, which is what makes the grid read as a network against the
// block interiors instead of washing the whole ground one flat grey.
//
// Deliberately NOT blackout-aware: this is moonlight and citywide skyglow, and
// killing it on a dark block would say the sky went out with the substation.
// A blacked-out block still loses its windows, its lamp billboards and its
// ground pools, which is where the ceremony's contrast actually lives.
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

global uniform float sc_wetness;
global uniform float sc_night;
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

uniform vec3 night_color: source_color = vec3(0.42, 0.53, 0.72);
uniform float night_albedo_lift = 0.0;
uniform float night_glow = 0.0;
// Wet asphalt is a MIRROR, not a diffuser: it throws the skyglow forward
// instead of back at the camera, so the glow floor comes down as the road
// wets and the lamp smear takes over as the read. Same direction the wet
// albedo multiply already goes, and roughly the same size.
uniform float night_glow_wet_mult = 0.55;

void fragment() {
	vec3 surface = texture(page, UV * uv_scale).rgb;
	ALBEDO = tint * mix(vec3(1.0), surface, has_page);
	ALBEDO *= mix(1.0, wet_albedo_mult, sc_wetness);
	ALBEDO += night_color * (night_albedo_lift * sc_night);
	EMISSION = night_color * (night_glow * sc_night
			* mix(1.0, night_glow_wet_mult, sc_wetness));
	ROUGHNESS = mix(dry_roughness, wet_roughness, sc_wetness);
	SPECULAR = mix(dry_specular, wet_specular, sc_wetness);
	if (sc_overlay_mode > 0) {
		float luma = dot(ALBEDO, vec3(0.2126, 0.7152, 0.0722));
		ALBEDO = mix(ALBEDO, vec3(luma), overlay_desaturate);
		// The night floor is part of the surface, so it de-emphasises with it —
		// otherwise a power overlay reads its data against a blue road.
		float glow_luma = dot(EMISSION, vec3(0.2126, 0.7152, 0.0722));
		EMISSION = mix(EMISSION, vec3(glow_luma), overlay_desaturate);
	}
}
