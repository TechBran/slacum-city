// Headlight ground cone (doc 11 §2.12's `MM_headlights`): one flat additive
// trapezoid laid on the road ahead of each lit vehicle, tapering along the
// beam and across it. Unshaded, no depth write, no shadow — the cheapest
// possible "the headlights are on" read, and the whole MultiMesh drops to
// `visible_instance_count = 0` above the night threshold gate in VehicleView.
//
//   UV.x            = across the beam (0 left … 1 right)
//   UV.y            = along the beam  (0 at the lamp … 1 at the far end)
//   INSTANCE_CUSTOM = (unused, lamp intensity 0..1, unused, fade 0..1)
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

uniform vec3 cone_color : source_color = vec3(1.0, 0.94, 0.78);
uniform float cone_energy = 0.85;

varying float v_amt;

void vertex() {
	v_amt = clamp(INSTANCE_CUSTOM.g, 0.0, 1.0) * clamp(INSTANCE_CUSTOM.a, 0.0, 1.0);
}

void fragment() {
	float along = pow(clamp(1.0 - UV.y, 0.0, 1.0), 1.35);
	float across = pow(clamp(1.0 - abs(UV.x - 0.5) * 2.0, 0.0, 1.0), 1.6);
	ALBEDO = cone_color * cone_energy * along * across * v_amt;
}
