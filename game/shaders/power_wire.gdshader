// Service drops — the wire from a pad-mounted transformer to each building it
// feeds (doc 04 §2.1's attachment, drawn). NEAR tier only; `PowerInfraView`
// submits a chunk's wire bucket only while that bucket's own AABB is inside
// `fade_end_m` of the camera, and every wire in it is fully faded out at that
// range, so the gate cannot pop.
//
// ── one instance is one whole span ────────────────────────────────────────
// The mesh is a flat 8-segment strip in [0,1] × {0,1} and this shader turns it
// into a CAMERA-FACING RIBBON along the span: 16 triangles per wire, no tube,
// no winding to get wrong, and a round cross-section that comes out of the
// fragment stage for free. The alternative — one instance per segment of a
// tessellated tube — would have been 8× the instances and 3× the triangles for
// a cable that is three pixels wide.
//
// Three things the ribbon buys that a static mesh could not:
//   * **Catenary sag** as a vertex function of `t`, so a rebuilt roster never
//     rebuilds geometry — only the instance transform moves.
//   * **A constant minimum screen width.** `min_px` holds the wire at ~1.4 px
//     however far away it is, which is the whole difference between a cable and
//     a crawling line of aliasing artefacts.
//   * **A fade that costs nothing when it is over.** At `fade_end_m` the ribbon
//     collapses to zero width — degenerate triangles, no fragments at all.
//
// INSTANCE_CUSTOM, §2.6's channel roles:
//   .r  heat        the SOURCE pad's 0..1 heat — a run off a cooking
//                   transformer warms along its whole length
//   .g  sag         metres of droop at mid-span (the vertex stage's only
//                   geometric input beyond the transform)
//   .b  packed      distress + 112 * overlay_state, `power_pad.gdshader`'s
//                   packing exactly
//   .a  anim phase  the pad's, shared, so one pad's fan animates as one thing
//
// The instance basis is (X = span vector, Y = up × radius, Z = side × radius);
// only column X and the origin are read here, and the radius comes off column
// Y's length, so the CPU side sets one transform and nothing else.
shader_type spatial;
render_mode world_vertex_coords, unshaded, blend_mix, depth_draw_never,
		shadows_disabled, cull_disabled;

global uniform float sc_night;
global uniform float sc_time;
global uniform int sc_overlay_mode;

// A service triplex is black polyethylene. `night_color` is not "the same thing
// darker": at night a cable is lit only by the streetlight under it and reads
// as a slightly WARM near-black, and going pure black instead makes every wire
// vanish the moment the sun sets — which is exactly when a player is looking at
// the power layer.
uniform vec3 wire_color: source_color = vec3(0.078, 0.086, 0.098);
uniform vec3 wire_night_color: source_color = vec3(0.129, 0.118, 0.106);
uniform float wire_alpha = 0.88;
// Metres of radius. 0.045 is a 90 mm cable, which is heavy for a triplex and
// deliberate: at Z0 the honest 20 mm is one pixel and reads as a scratch.
uniform float min_px = 1.35;
// World metres covered by ONE screen pixel at one metre of depth:
// `2·tan(fov_y/2) / viewport_height`. `PowerInfraView` computes it from the
// authored FOV and the live render height and pushes it on change.
//
// It is deliberately NOT derived in-shader from `PROJECTION_MATRIX[1][1]` and
// `VIEWPORT_SIZE.y`. BOTH of those COMPILE in a spatial vertex shader and
// neither carries a usable value there on Forward Mobile — the product came out
// at zero, took the `max(1.0, …)` guard, and widened every service drop to
// ~130 m of near-opaque black: a full-screen wash at any close zoom. Measured,
// not theorised — the A/B is `tools/power_infra_preview.tscn --zoom=0.22` with
// and without `--no-wires`, and again with `wire_min_px` forced to 0.
uniform float world_per_px_at_1m = 0.00101;
// A hard ceiling on the widening, in metres. Belt and braces after the above:
// whatever this shader is handed, a service drop can never be wider than a
// hand-span, so no future plumbing mistake can paint the screen again.
uniform float max_radius_m = 0.30;
uniform float fade_begin_m = 55.0;
uniform float fade_end_m = 110.0;
// Heat tint: a wire off a SEVERE transformer picks up the fins' orange NEAR THE
// PAD and is a plain cable by the time it reaches the wall. Both halves of that
// sentence are load-bearing. 0.55 flat (the first pass) painted a bright orange
// line all the way across the frame — the single most conspicuous thing in a
// night shot, and untrue: a service drop does not glow. Tapering by `(1 − t)²`
// keeps the one thing the tint is FOR, which is connecting the wire a player is
// looking at to the transformer it comes from.
uniform vec3 heat_color: source_color = vec3(1.0, 0.392, 0.145);
uniform float heat_tint = 0.18;

// ═════════ BEGIN overlay pass — sc_overlay_mode (doc 12 §2.5) ═════════════
uniform vec3 overlay_normal_color: source_color = vec3(0.404, 0.463, 0.541);
uniform vec3 overlay_warning_color: source_color = vec3(0.949, 0.694, 0.235);
uniform vec3 overlay_critical_color: source_color = vec3(0.898, 0.325, 0.239);
uniform vec3 overlay_offline_color: source_color = vec3(0.400, 0.070, 0.055);
uniform float overlay_critical_hz = 1.2;
uniform float overlay_offline_hz = 0.35;
// In POWER mode the wire stops being subtle. It is the only thing on screen
// that says WHICH transformer feeds WHICH building, and a 1.4 px dark thread
// under the grey wash says it to nobody.
uniform float overlay_px_gain = 2.30;
uniform float overlay_alpha = 0.96;
const int OVERLAY_MODE_POWER = 1;
const float OVERLAY_STRIDE = 112.0;
// ═════════ END overlay pass ═══════════════════════════════════════════════

varying flat vec4 v_custom;
varying float v_side;      // −1 .. +1 across the ribbon: the round cross-section
varying float v_fade;
varying float v_t;         // 0 at the pad, 1 at the wall — the heat taper

float overlay_of(float packed) {
	return mod(floor(packed / OVERLAY_STRIDE), 4.0);
}

float distress_of(float packed) {
	return mod(packed, OVERLAY_STRIDE);
}

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	float t = UV.x;
	float side = UV.y * 2.0 - 1.0;
	v_side = side;
	v_t = t;

	vec3 span = MODEL_MATRIX[0].xyz;
	float r0 = length(MODEL_MATRIX[1].xyz);
	float sag = v_custom.g;

	// Parabolic droop — the small-sag reading of a catenary, and exact enough
	// that the difference over a 30 m service drop is under a centimetre.
	// `tangent` is its analytic derivative, so the ribbon stays square to the
	// wire through the curve instead of shearing at the ends.
	vec3 centre = MODEL_MATRIX[3].xyz + span * t;
	centre.y -= sag * 4.0 * t * (1.0 - t);
	vec3 tangent = normalize(span + vec3(0.0, -sag * 4.0 * (1.0 - 2.0 * t), 0.0));

	vec3 to_cam = CAMERA_POSITION_WORLD - centre;
	float d = length(to_cam);
	to_cam /= max(d, 0.0001);
	vec3 side_dir = normalize(cross(tangent, to_cam));

	// World metres per screen pixel at this depth — linear in depth under a
	// perspective projection, which is the whole of the arithmetic.
	float wpp = d * world_per_px_at_1m;
	float px = mix(min_px, min_px * overlay_px_gain,
			float(sc_overlay_mode == OVERLAY_MODE_POWER));
	v_fade = 1.0 - smoothstep(fade_begin_m, fade_end_m, d);
	float r = min(max(r0, px * wpp), max_radius_m) * v_fade;

	VERTEX = centre + side_dir * r * side;
	NORMAL = normalize(cross(side_dir, tangent));
}

void fragment() {
	// Round cross-section, and the anti-aliasing with it: `shade` darkens the
	// silhouette toward the edges the way a cylinder does, and the same term
	// feathers the last pixel so a 1.4 px wire has no stairs on it.
	float u = abs(v_side);
	float shade = sqrt(max(0.0, 1.0 - u * u));
	float edge = smoothstep(1.0, 0.68, u);

	float packed = v_custom.b;
	float heat = v_custom.r;
	vec3 base = mix(wire_color, wire_night_color, sc_night);
	float near_pad = pow(1.0 - v_t, 3.0);
	base = mix(base, heat_color, heat * heat * heat_tint * near_pad);
	vec3 col = base * (0.55 + 0.45 * shade);
	float alpha = wire_alpha * edge * v_fade;

	// Every other overlay greys the world back (§2.5's de-emphasis) and a wire
	// is part of the world: under WATER or FIRE it desaturates and thins out
	// with everything else rather than staying the one saturated thread on
	// screen. Mode 0 skips the whole block.
	if (sc_overlay_mode > 0 && sc_overlay_mode != OVERLAY_MODE_POWER) {
		float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
		col = mix(col, vec3(luma), 0.55);
		alpha *= 0.45;
	}

	if (sc_overlay_mode == OVERLAY_MODE_POWER) {
		float state = overlay_of(packed);
		float distress = distress_of(packed);
		float own = step(0.5, distress) + step(1.5, distress) + step(3.5, distress);
		state = max(state, min(own, 3.0));
		vec3 tint = overlay_normal_color;
		tint = mix(tint, overlay_warning_color, step(0.5, state));
		tint = mix(tint, overlay_critical_color, step(1.5, state));
		tint = mix(tint, overlay_offline_color, step(2.5, state));
		float hz = mix(overlay_critical_hz, overlay_offline_hz, step(2.5, state));
		float pulse = 0.5 + 0.5 * sin(sc_time * 6.283185 * hz);
		float lively = step(1.5, state);
		col = tint * (0.70 + 0.30 * shade) * (1.0 + lively * 0.45 * pulse);
		alpha = overlay_alpha * edge * v_fade;
	}

	ALBEDO = col;
	ALPHA = alpha;
}
