// Vehicle body (doc 11 §2.12). One material per body kind, one MultiMesh per
// material, everything else per instance.
//
//   COLOR           = vertex part tint x MultiMesh instance colour (the paint).
//                     Painted panels are authored white, so COLOR is the paint;
//                     tyres and glass are authored dark, so the paint tints
//                     them without ever reading as a colour of its own.
//   UV.y            = part ROLE: 0 body, 0.25 headlight, 0.5 taillight,
//                     0.75 lightbar half A, 1.0 lightbar half B. Light surfaces
//                     take their colour from the uniforms below, so they are
//                     immune to the paint and each department flashes its own
//                     pair (red/blue police & medical, amber/amber utility).
//   INSTANCE_CUSTOM = (unused, lamp intensity 0..1, lightbar phase or -1,
//                      fade 0..1).
//
// `anim_time` and `night_amt` are pushed by VehicleView.refresh() rather than
// read from the sc_* globals, so the layer animates correctly even in a scene
// that has no EnvironmentController driving them.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 head_color : source_color = vec3(1.0, 0.94, 0.78);
uniform vec3 tail_color : source_color = vec3(1.0, 0.16, 0.09);
uniform vec3 bar_a_color : source_color = vec3(1.0, 0.16, 0.13);
uniform vec3 bar_b_color : source_color = vec3(0.16, 0.36, 1.0);
uniform float head_energy = 2.4;
uniform float tail_energy = 1.5;
uniform float bar_energy = 3.5;
uniform float bar_hz = 2.2;
uniform float body_roughness = 0.52;
uniform float body_metallic = 0.08;
uniform float anim_time = 0.0;
uniform float night_amt = 0.0;

varying vec4 v_data;
varying float v_role;

void vertex() {
	v_data = INSTANCE_CUSTOM;
	v_role = UV.y;
}

void fragment() {
	vec3 albedo = COLOR.rgb;
	vec3 emission = vec3(0.0);
	float lamps = clamp(v_data.g, 0.0, 1.0);
	float bar_phase = v_data.b;

	if (v_role < 0.125) {
		// Plain painted / trim surface: nothing to do.
	} else if (v_role < 0.375) {
		// Headlight lens: glassy by day, a hot disc once the lamps come on.
		albedo = mix(vec3(0.72, 0.74, 0.76), head_color, lamps);
		emission = head_color * head_energy * lamps;
	} else if (v_role < 0.625) {
		// Taillight lens: always red, emissive only with the lamps.
		albedo = tail_color * 0.42;
		emission = tail_color * tail_energy * lamps;
	} else {
		// Light bar. Two halves alternate at bar_hz; the per-vehicle phase in
		// INSTANCE_CUSTOM.b keeps a convoy out of lockstep, and a negative
		// phase means "this vehicle has no bar running" (parked, or civilian
		// geometry that happens to carry the role).
		float on = step(0.0, bar_phase);
		float t = fract(anim_time * bar_hz + max(bar_phase, 0.0));
		float side = step(0.875, v_role);
		float lit = mix(1.0 - step(0.5, t), step(0.5, t), side);
		// A short double-blip inside each half-cycle reads as a strobe rather
		// than a slow lantern.
		float blip = 0.35 + 0.65 * step(0.5, fract(t * 4.0));
		lit *= mix(1.0, blip, 0.7);
		vec3 c = mix(bar_a_color, bar_b_color, side);
		albedo = mix(c * 0.22, c, lit * on);
		emission = c * bar_energy * lit * on * mix(0.55, 1.0, night_amt);
	}

	ALBEDO = albedo;
	EMISSION = emission;
	ROUGHNESS = body_roughness;
	METALLIC = body_metallic;
}
