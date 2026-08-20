// Streetlight ground pool (doc 11 §2.10 #3): a fake downward light disc with
// radial falloff — replaces the dynamic light for 95% of streetlights.
// INSTANCE_CUSTOM.r = lit ramp; sc_wetness widens and brightens it.
//
// `fog_disabled` + the vertex day gate are the same fix lamp.gdshader carries:
// depth fog mixed into an ADDITIVE pass adds fog-grey, which drew a flat
// 12 m square of haze on the road under every pole at noon. See lamp.gdshader
// for the full note.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, fog_disabled;

global uniform float sc_night;
global uniform float sc_wetness;

uniform vec3 pool_color: source_color = vec3(1.0, 0.851, 0.627);
uniform float pool_energy = 0.58;
uniform float night_lo = 0.08;
uniform float night_hi = 0.26;
// ── the street-grid read (report NIGHT-1) ─────────────────────────────────
// The 6 m disc lit a circle under each pole and nothing between them: at the
// authored 32 m spacing that is 12 m of light and 20 m of black, so the street
// read as a row of dots rather than as a NETWORK. `pool_scale` widens the disc
// in the vertex stage — the mesh, the buffer and the per-chunk AABB are all
// unchanged — and `pool_falloff` is left at the square law, because the rim is
// what the eye reads as the DISC and softening it turned each pole into a
// visible circle rather than into more street.
//
// 1.35 is a CEILING, not a taste: at Z2 the camera is 371 m up and a pool
// subtends radius_m / dist × 1031 px, so every metre of radius is ~19 px of
// soft disc laid over the skyline. Past ~10 m the marketed frame stops being
// a city at night and becomes bokeh — which is why the rest of the street read
// is spent on the ground's own night floor (data/render.json `ground`) and not
// on making these bigger still.
//
// This is the half of the night floor that IS blackout-aware: `v_lit` is the
// model's per-lamp ramp, so a dark block loses its ribbon while the moonlit
// ground floor underneath it stays — which is exactly the contrast the
// ceremony needs, and the reason the ground's own lift is kept modest.
uniform float pool_scale = 1.35;
uniform float pool_falloff = 2.0;

varying float v_lit;
varying float v_gate;

void vertex() {
	v_lit = INSTANCE_CUSTOM.r;
	v_gate = smoothstep(night_lo, night_hi, sc_night) * v_lit;
	VERTEX.xz *= pool_scale * (1.0 + 0.5 * sc_wetness);
	// Daylight: collapse the disc so no fragment is ever shaded (see lamp).
	VERTEX *= step(0.002, v_gate);
}

void fragment() {
	float d = length(UV - vec2(0.5)) * 2.0;
	float falloff = pow(clamp(1.0 - d, 0.0, 1.0), pool_falloff);
	ALBEDO = pool_color * falloff * pool_energy * v_gate
			* (1.0 + 0.6 * sc_wetness);
}
