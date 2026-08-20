// Distress plume for a transformer in trouble (doc 04 §2.6's thermal band and
// §2.5's failure, drawn). Smoke AND sparks out of ONE MultiMesh and one draw
// call, which is the whole reason this is `blend_premul_alpha` rather than two
// passes: with premultiplied alpha a fragment that writes ALBEDO and leaves
// ALPHA at 0 is purely ADDITIVE (a spark) and one that writes `colour * a` with
// ALPHA = a blends normally (smoke). Two blend modes, one pipeline state.
//
// No GPUParticles3D anywhere in here, and that is deliberate. A particle system
// per troubled transformer is one node, one process callback and one draw call
// EACH, on a layer whose whole budget is a couple of calls; and its state would
// be wall-clock-driven, so two runs of the same save would not look the same.
// Every puff below is a pure function of `sc_time` and a per-instance phase the
// model derives from the component id — capped, deterministic, and free to
// simulate because nothing is simulated.
//
// INSTANCE_CUSTOM, §2.6's channel roles:
//   .r  severity   the pad's ramped 0..1 smoke (PowerInfraModel.smoke)
//   .g  size       billboard metres at birth
//   .b  packed     kind + 112 * overlay_state — 0 smoke, 1 spark
//   .a  anim phase this billboard's slot in the loop, 0..1
shader_type spatial;
render_mode blend_premul_alpha, unshaded, depth_draw_never, cull_disabled,
		shadows_disabled, fog_disabled;

global uniform float sc_night;
global uniform float sc_time;
global uniform int sc_overlay_mode;

// Both values are LIGHTER than a photograph of transformer smoke, and measured
// rather than chosen: at the first pass (0.161 night / 0.478 day) the plume was
// invisible in BOTH shots. Premultiplied alpha writes `colour · a` and takes
// `1 − a` of the background, so a dark plume over a dark night sky is a change
// of two per cent — and by day a 0.478 grey at 0.42 coverage landed within four
// per cent of the asphalt it was standing over. A plume has to be lighter than
// what is behind it or it is not a plume; a real one is, because it scatters.
uniform vec3 smoke_color: source_color = vec3(0.298, 0.286, 0.271);
// Smoke is lighter still where the sun hits it; one lerp on sc_night is the
// whole of the day/night answer for a puff.
uniform vec3 smoke_day_color: source_color = vec3(0.620, 0.604, 0.580);
uniform float smoke_alpha = 0.58;
uniform float smoke_rate_hz = 0.34;
uniform float rise_m = 5.40;
uniform float drift_m = 1.30;
uniform float grow = 2.60;
// The hot core: the first fifth of a puff's life carries ember light when the
// transformer is bad enough to be throwing it.
uniform vec3 ember_color: source_color = vec3(1.0, 0.451, 0.157);
uniform float ember_nits = 1.90;

uniform vec3 spark_color: source_color = vec3(1.0, 0.827, 0.545);
uniform float spark_nits = 5.50;
uniform float spark_rate_hz = 0.55;
// A spark is a FLASH: visible for 7 % of its loop, and nothing at all for the
// rest. `PowerInfraModel` gives adjacent sparks incommensurable phases, so the
// eye reads intermittent arcing rather than a metronome.
uniform float spark_duty = 0.07;

const int OVERLAY_MODE_POWER = 1;
const float OVERLAY_STRIDE = 112.0;

varying flat vec4 v_custom;
varying flat float v_kind;
varying float v_life;
varying float v_gate;

float overlay_of(float packed) {
	return mod(floor(packed / OVERLAY_STRIDE), 4.0);
}

// A cheap deterministic 0..1 from the phase, for per-puff drift direction.
float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	return fract(p * (p + p));
}

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	float severity = INSTANCE_CUSTOM.r;
	float size = INSTANCE_CUSTOM.g;
	float packed = INSTANCE_CUSTOM.b;
	float phase = INSTANCE_CUSTOM.a;
	v_kind = mod(packed, OVERLAY_STRIDE);

	float rate = mix(smoke_rate_hz, spark_rate_hz, v_kind);
	float life = fract(sc_time * rate + phase);
	v_life = life;

	// Smoke lives its whole loop; a spark exists for `spark_duty` of it.
	float alive = mix(1.0, step(life, spark_duty), v_kind);
	v_gate = severity * alive;

	float angle = hash11(phase + 7.13) * 6.283185;
	float scale = mix(mix(1.0, grow, life), 0.35 + 0.65 * (1.0 - life / spark_duty),
			v_kind);

	mat4 model = MODEL_MATRIX;
	model[3].y += rise_m * life * mix(1.0, 0.22, v_kind);
	model[3].x += drift_m * life * cos(angle) * (1.0 - v_kind);
	model[3].z += drift_m * life * sin(angle) * (1.0 - v_kind);

	// Per-instance billboard — the same construction `lamp.gdshader` uses: face
	// the camera, keep the instance's world position, take the scale from here.
	float s = size * scale;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			INV_VIEW_MATRIX[0] * s,
			INV_VIEW_MATRIX[1] * s,
			INV_VIEW_MATRIX[2],
			model[3]);

	// A dead puff collapses to a point BEFORE rasterisation, so a city with no
	// trouble in it pays nothing at all for this buffer beyond the draw call —
	// and `PowerInfraView` hides the node entirely when the roster is empty, so
	// it usually does not pay that either.
	VERTEX *= step(0.003, v_gate);
}

void fragment() {
	vec2 uv = UV - vec2(0.5);
	float d = length(uv) * 2.0;
	float disc = pow(clamp(1.0 - d, 0.0, 1.0), 1.5);

	// ── smoke ────────────────────────────────────────────────────────────
	// Fades in over the first 12 % of the puff and thins out across the rest,
	// so the column has a dense root and a ragged head.
	float smoke_env = smoothstep(0.0, 0.12, v_life) * pow(1.0 - v_life, 1.4);
	float smoke_a = smoke_alpha * disc * smoke_env * v_gate;
	vec3 smoke_rgb = mix(smoke_color, smoke_day_color, 1.0 - sc_night);
	// Ember light in the root of the plume, and only when it is BAD. The gate is
	// 1.8·severity − 0.9, so it is dead through TROUBLED (0.42) and through a
	// FAILED unit's smoulder (0.16) and only opens near SEVERE. That separation
	// is the whole point of having four looks: TROUBLED is a grey wisp you have
	// time to act on, SEVERE has fire in it, and if both carried embers a player
	// could not tell them apart at a glance.
	float ember = pow(clamp(1.0 - v_life * 5.0, 0.0, 1.0), 2.0)
			* clamp(v_gate * 1.8 - 0.9, 0.0, 1.0);
	vec3 smoke_col = smoke_rgb * smoke_a + ember_color * ember * ember_nits * disc;

	// ── spark ────────────────────────────────────────────────────────────
	// Pure additive: ALPHA stays 0 for this branch's contribution.
	float spark_env = pow(clamp(1.0 - v_life / spark_duty, 0.0, 1.0), 1.6);
	vec3 spark_col = spark_color * spark_nits * disc * disc * spark_env * v_gate;

	float is_spark = v_kind;
	vec3 rgb = mix(smoke_col, spark_col, is_spark);
	float a = mix(smoke_a, 0.0, is_spark);

	// Under any overlay the world greys back; a plume is world, not data. In
	// POWER mode it keeps its full weight, because "which transformer is
	// smoking" is exactly the question that mode is asked.
	float wash = float(sc_overlay_mode > 0 && sc_overlay_mode != OVERLAY_MODE_POWER);
	float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
	rgb = mix(rgb, vec3(luma) * 0.6, wash * 0.55);
	a *= mix(1.0, 0.5, wash);

	ALBEDO = rgb;
	ALPHA = a;
}
