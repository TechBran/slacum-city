// Streetlight lamp billboard (doc 11 §2.10 #2). Unshaded additive; the only
// streetlight element rendered at FAR. INSTANCE_CUSTOM.r = lit ramp (model's
// per-lamp cur, blackout-aware); brightness gated by sc_night.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

global uniform float sc_night;

uniform vec3 lamp_color: source_color = vec3(1.0, 0.851, 0.627);
uniform float lamp_energy = 2.6;

varying float v_lit;

void vertex() {
	v_lit = INSTANCE_CUSTOM.r;
	// Per-instance billboard: face the camera, keep instance position/scale.
	mat4 model = MODEL_MATRIX;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			INV_VIEW_MATRIX[0] * length(model[0].xyz),
			INV_VIEW_MATRIX[1] * length(model[1].xyz),
			INV_VIEW_MATRIX[2],
			model[3]);
}

void fragment() {
	float d = length(UV - vec2(0.5)) * 2.0;
	float halo = pow(clamp(1.0 - d, 0.0, 1.0), 1.6);
	ALBEDO = lamp_color * halo * lamp_energy * v_lit * sc_night;
}
