// Streetlight lamp billboard (doc 11 §2.10 #2). Unshaded additive; the only
// streetlight element rendered at FAR. INSTANCE_CUSTOM.r = lit ramp (model's
// per-lamp cur, blackout-aware); brightness gated by sc_night.
//
// `smear_mode = 1.0` turns the same buffer into §2.9's MM_wetsmear: the lamp
// billboards mirrored below y = 0, Y-scaled by the view, alpha 0.35·sc_wetness
// with a vertical gradient. Doc 11 is explicit that the smear buffer IS the
// lamp buffer with a mirror transform, so it is the same shader with one
// uniform rather than a second copy that can drift.
//
// ── the daylight fix ──────────────────────────────────────────────────────
// `fog_disabled` is load-bearing, not tidiness. Godot applies depth fog to
// transparent materials as `mix(color, fog_rgb, fog_a)`, and on an ADDITIVE
// pass that mix ADDS the fog colour: every lamp quad drew a flat fog-grey
// 1.6 m square along every road in broad daylight, exactly where a lamp is
// supposed to contribute nothing at all. Killing fog on the pass fixes the
// colour; the vertex gate below stops the quad from being rasterised at all
// while sc_night is low, so the daytime cost is zero rather than "invisible".
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled;

global uniform float sc_night;
global uniform float sc_wetness;

uniform vec3 lamp_color: source_color = vec3(1.0, 0.851, 0.627);
uniform float lamp_energy = 2.6;
// Hard day gate: nothing of the lamp exists below `night_lo`, and it fades in
// over [night_lo, night_hi] so dusk is a ramp and not a pop. sc_night is
// authored (§2.8) and sits at ~0.02 at midday — well under the floor.
uniform float night_lo = 0.08;
uniform float night_hi = 0.26;
uniform float smear_mode = 0.0;
uniform float smear_alpha = 0.35;
uniform float smear_min_wetness = 0.05;
// The smear rides `lamp_energy`, which is calibrated for a 1.6 m halo, not for
// a column eight metres tall. Without this it reads as a lit bar bolted to the
// pole rather than light bleeding up off a wet road.
uniform float smear_energy_scale = 0.42;

varying float v_lit;
varying float v_gate;

void vertex() {
	v_lit = INSTANCE_CUSTOM.r;
	float night_gate = smoothstep(night_lo, night_hi, sc_night);
	float wet_gate = mix(1.0,
			smoothstep(smear_min_wetness, smear_min_wetness + 0.10, sc_wetness),
			smear_mode);
	v_gate = night_gate * wet_gate * v_lit;
	// Per-instance billboard: face the camera, keep instance position/scale.
	mat4 model = MODEL_MATRIX;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			INV_VIEW_MATRIX[0] * length(model[0].xyz),
			INV_VIEW_MATRIX[1] * length(model[1].xyz),
			INV_VIEW_MATRIX[2],
			model[3]);
	// The gate collapses the quad to a degenerate point in DAYLIGHT, so the
	// rasteriser never sees it: no fragments, no blend, no fill cost for ~14
	// hours of every game day.
	VERTEX *= step(0.002, v_gate);
}

void fragment() {
	vec2 uv = UV;
	float d = length(uv - vec2(0.5)) * 2.0;
	float halo = pow(clamp(1.0 - d, 0.0, 1.0), 1.6);
	// Smear: horizontal falloff only, faded out along the streak.
	float across = pow(clamp(1.0 - abs(uv.x - 0.5) * 2.0, 0.0, 1.0), 2.2);
	float along = pow(clamp(1.0 - uv.y, 0.0, 1.0), 1.6);
	float smear = across * along * smear_alpha * smear_energy_scale * sc_wetness;
	float shape = mix(halo, smear, smear_mode);
	ALBEDO = lamp_color * shape * lamp_energy * v_gate;
}
