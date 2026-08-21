// STREET LIFE furniture (doc 11 §2.17) — the attention MARKER over a live
// opportunity, the `+$N` LABEL that rises off a collected one, the POOF that
// replaces it, and the SPARKLE over a dropped stash.
//
// FOUR EFFECTS, ONE DRAW CALL. Every one of them is the same thing: a flat quad
// turned to face the camera, alpha-blended, writing no depth. So they are one
// MultiMesh with a MODE in `INSTANCE_CUSTOM.r` rather than four buffers, four
// materials and four calls — which matters, because the layer's whole budget is
// four calls including the three character bodies.
//
// INSTANCE_CUSTOM
//   .r MODE   0 marker, 1 puff, 2 ring, 3 glyph, 4 sparkle
//   .g        modes 0 and 3: the GLYPH index into the atlas page, 0..15
//             modes 1, 2 and 4: PROGRESS / phase, 0..1
//   .b FADE   0..1, the distance gate and the fade-out, multiplied into alpha
//   .a        modes 0, 1, 2 and 4: PHASE, 0..1, hashed off the opportunity id —
//             the marker's pulse offset and the sparkle's spin, so five markers
//             on one street never breathe in lockstep
//             mode 3: the glyph's SLOT in its label, `i − (n−1)/2`. A glyph has
//             no use for a phase and a label needs a layout, so the channel is
//             re-read rather than a fifth one being invented; nothing in the
//             FRAGMENT stage reads `.a` on mode 3, and nothing in the VERTEX
//             stage reads it on any other mode
//
// INSTANCE COLOR is the tint; its alpha is a second alpha multiplier the view
// uses for the label's own rise-and-fade curve.
//
// THE PAGE. `StreetGlyphAtlas` builds a 256 × 20 strip of sixteen SIGNED
// DISTANCE FIELDS — the ten digits, `+`, `$`, `!`, `k`, a paw and a bell. A
// distance field is not decoration here: the marker has to be readable while
// the player scrubs the city at Z1 (a 1 m mark is 17 screen px) and stay clean
// at Z0 (82 px), and `smoothstep` across the 0.5 contour reconstructs a hard
// edge at BOTH without a mipmap chain or a second authored size. The same field
// gives the labels a dark outline for free, at a second contour.
//
// ONE `texture()` CALL, unconditional, outside every branch. The mode dispatch
// below is arithmetic on already-fetched values for exactly that reason: a
// fetch inside divergent control flow is a mobile-driver hazard and this
// renderer has none.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled,
		shadows_disabled;

global uniform float sc_night;

// NOT `source_color`, and that is a bug this pass paid for. The page is a
// DISTANCE FIELD, i.e. data — hinting it as colour makes the sampler decode it
// as sRGB, and 0.561 (the field just inside a contour) comes back as 0.275.
// Every `field > 0.5` test then fails and every mark on every marker vanishes,
// while the labels keep drawing because their OUTLINE contour sits at 0.16 and
// survives the decode. The symptom was a perfect empty pin.
uniform sampler2D glyph_page : filter_linear, repeat_disable;
uniform float glyph_cells = 16.0;
// Texels per authored cell in the page, so the shader can size its own
// antialiasing band in the field's units rather than guessing.
uniform float glyph_spread = 2.0;
// LABEL layout, in quad WIDTHS. A `+$120` is five instances that all share one
// world origin and step apart along the quad's own local +X — which, after the
// billboard below, is SCREEN right. Laying the run out in world space instead
// (the first pass did) makes the number lie along world +X, so it foreshortens
// and skews with the camera yaw and reads as a number written on the road.
uniform float glyph_pitch = 0.825;

// ---- the marker ----------------------------------------------------------
// The chip is a rounded box in the quad's upper reach with a tail below it —
// a map pin. Everything is in 0..1 quad coordinates with v growing DOWN, so
// "the point" is at the BOTTOM and lands on the thing being marked.
uniform vec2 chip_centre = vec2(0.5, 0.38);
uniform vec2 chip_half = vec2(0.33, 0.26);
uniform float chip_radius = 0.15;
uniform float chip_tail_y = 0.97;
uniform float chip_tail_half = 0.20;
uniform vec3 chip_rim : source_color = vec3(0.06, 0.06, 0.08);
uniform float chip_rim_w = 0.045;
// Emission gain at midnight vs. midday. A marker has to survive a lit street at
// noon AND not become a flare at 02:00, so the night arm is the SMALLER lift
// and the glow threshold does the rest.
uniform float marker_energy_day = 1.00;
uniform float marker_energy_night = 1.45;
uniform float pulse_hz = 0.62;
uniform float pulse_depth = 0.20;
uniform float anim_time = 0.0;

// ---- labels --------------------------------------------------------------
uniform vec3 label_outline : source_color = vec3(0.04, 0.05, 0.06);
uniform float label_outline_w = 0.10;
uniform float label_energy = 1.35;

// ---- poof and sparkle ----------------------------------------------------
uniform vec3 puff_color : source_color = vec3(0.90, 0.88, 0.82);
uniform float puff_softness = 2.2;
uniform float ring_width = 0.16;
uniform vec3 sparkle_color : source_color = vec3(1.0, 0.93, 0.62);
uniform float sparkle_energy = 2.1;

varying flat float v_mode;
varying flat float v_arg;
varying flat float v_fade;
varying flat float v_phase;


void vertex() {
	v_mode = INSTANCE_CUSTOM.r;
	v_arg = INSTANCE_CUSTOM.g;
	v_fade = INSTANCE_CUSTOM.b;
	v_phase = INSTANCE_CUSTOM.a;
	// Per-instance billboard, the same construction `lamp.gdshader` uses: face
	// the camera, keep the instance's own position and scale.
	mat4 model = MODEL_MATRIX;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			INV_VIEW_MATRIX[0] * length(model[0].xyz),
			INV_VIEW_MATRIX[1] * length(model[1].xyz),
			INV_VIEW_MATRIX[2],
			model[3]);
	// Screen-aligned label layout. For mode 3 the phase channel carries the
	// glyph's SLOT — `i − (n−1)/2`, so a five-glyph run steps −2, −1, 0, 1, 2 —
	// and local +X is screen right by the time the billboard above is done.
	float is_glyph = step(2.5, v_mode) * (1.0 - step(3.5, v_mode));
	VERTEX.x += v_phase * glyph_pitch * is_glyph;
	// A faded-out instance is collapsed to a point so the rasteriser never sees
	// it: no fragments, no blend, no fill cost for a marker three districts
	// away that the CPU has not got round to retiring yet.
	VERTEX *= step(0.002, v_fade * clamp(COLOR.a, 0.0, 1.0));
}


// Signed distance to a rounded box, in the quad's own 0..1 frame.
float sd_round_box(vec2 p, vec2 centre, vec2 half_size, float r) {
	vec2 q = abs(p - centre) - (half_size - vec2(r));
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}


// The pin's tail: an isoceles triangle hanging off the chip to the point at
// `chip_tail_y`. Two half-planes and a cap — exact inside, a slight
// over-estimate outside, which is all a fill and a rim need.
float sd_tail(vec2 p) {
	float span = chip_tail_y - chip_centre.y;
	float t = clamp((p.y - chip_centre.y) / max(span, 0.0001), 0.0, 1.0);
	float half_w = mix(chip_tail_half, 0.0, t);
	float dx = abs(p.x - chip_centre.x) - half_w;
	float dy = max(chip_centre.y - p.y, p.y - chip_tail_y);
	return max(dx * 0.86, dy);
}


void fragment() {
	vec2 uv = UV;
	float fade = clamp(v_fade, 0.0, 1.0) * clamp(COLOR.a, 0.0, 1.0);

	// ---- the one fetch, hoisted above every branch ----------------------
	// Modes 0 and 3 want the glyph; 1, 2 and 4 do not, and they still pay for
	// it. That is deliberate: one unconditional fetch on a quad this small is
	// cheaper than the divergence, and it is the rule this renderer keeps.
	float glyph = clamp(floor(v_arg + 0.5), 0.0, glyph_cells - 1.0);
	// Marker glyphs sit inside the chip; label glyphs fill their own quad.
	float is_marker = 1.0 - step(0.5, v_mode);
	vec2 inner = mix(uv, (uv - chip_centre) / (chip_half * 1.42) + vec2(0.5),
			is_marker);
	vec2 cell = vec2((glyph + clamp(inner.x, 0.0, 1.0)) / glyph_cells,
			clamp(inner.y, 0.0, 1.0));
	float field = texture(glyph_page, cell).r;
	// Inside the glyph, and the antialiasing band, in the field's own units.
	float band = max(fwidth(field), 0.0015);
	float ink = smoothstep(0.5 - band, 0.5 + band, field);
	// A glyph clipped to its own cell: the marker's inner frame runs outside
	// 0..1 at the chip's corners and would otherwise smear the neighbouring
	// glyph across them.
	vec2 in_cell = step(vec2(0.0), inner) * step(inner, vec2(1.0));
	ink *= in_cell.x * in_cell.y;
	float outline = smoothstep(0.5 - label_outline_w - band,
			0.5 - label_outline_w + band, field) * in_cell.x * in_cell.y;

	// ---- mode masks -----------------------------------------------------
	float m_marker = is_marker;
	float m_puff = step(0.5, v_mode) * (1.0 - step(1.5, v_mode));
	float m_ring = step(1.5, v_mode) * (1.0 - step(2.5, v_mode));
	float m_glyph = step(2.5, v_mode) * (1.0 - step(3.5, v_mode));
	float m_spark = step(3.5, v_mode);

	// ---- the marker: a pin, a rim, and the mark inside it ---------------
	float d_chip = min(sd_round_box(uv, chip_centre, chip_half, chip_radius),
			sd_tail(uv));
	float chip_band = max(fwidth(d_chip), 0.001);
	float chip_fill = 1.0 - smoothstep(-chip_band, chip_band, d_chip);
	float chip_edge = 1.0 - smoothstep(-chip_band, chip_band, d_chip + chip_rim_w);
	// Slow breath, per-instance phase. Brightness only — the marker's SIZE is
	// the shell's tap target and the CPU owns it, so nothing here may move it.
	float pulse = 1.0 + pulse_depth * sin(TAU * (anim_time * pulse_hz + v_phase));
	vec3 marker_rgb = mix(chip_rim, COLOR.rgb * pulse, chip_edge);
	marker_rgb = mix(marker_rgb, vec3(1.0) * pulse, ink * chip_edge);
	float marker_a = chip_fill;

	// ---- the poof: a soft puff and an expanding ring --------------------
	float r = length(uv - vec2(0.5)) * 2.0;
	float prog = clamp(v_arg, 0.0, 1.0);
	float puff_a = pow(clamp(1.0 - r, 0.0, 1.0), puff_softness)
			* (1.0 - smoothstep(0.35, 1.0, prog));
	float ring_r = mix(0.15, 1.0, prog);
	float ring_a = (1.0 - smoothstep(0.0, ring_width, abs(r - ring_r)))
			* (1.0 - prog) * (1.0 - prog);

	// ---- the sparkle: a four-point star over a dropped stash -------------
	vec2 s = (uv - vec2(0.5)) * 2.0;
	float spin = TAU * (v_phase + anim_time * 0.11);
	vec2 sr = vec2(s.x * cos(spin) - s.y * sin(spin),
			s.x * sin(spin) + s.y * cos(spin));
	float star = pow(clamp(1.0 - min(abs(sr.x), abs(sr.y)) * 6.0, 0.0, 1.0), 1.6)
			* pow(clamp(1.0 - r, 0.0, 1.0), 1.1);
	float twinkle = 0.55 + 0.45 * sin(TAU * (anim_time * 1.7 + v_phase));
	float spark_a = clamp(star * twinkle + pow(clamp(1.0 - r, 0.0, 1.0), 4.0),
			0.0, 1.0);

	// ---- combine, by mask, with no branch -------------------------------
	vec3 rgb = marker_rgb * m_marker
			+ puff_color * (m_puff + m_ring)
			+ mix(label_outline, COLOR.rgb, ink) * m_glyph
			+ sparkle_color * m_spark;
	float alpha = marker_a * m_marker
			+ puff_a * m_puff
			+ ring_a * m_ring
			+ max(ink, outline) * m_glyph
			+ spark_a * m_spark;

	// Energy, not a light: this pass is `unshaded`, so lifting ALBEDO above 1
	// is what puts the mark into the glow post-process after dark, exactly the
	// way the lamp billboards do it.
	float energy = mix(marker_energy_day, marker_energy_night, clamp(sc_night, 0.0, 1.0));
	float gain = m_marker * energy
			+ (m_puff + m_ring) * 1.0
			+ m_glyph * label_energy
			+ m_spark * sparkle_energy * mix(0.7, 1.0, clamp(sc_night, 0.0, 1.0));

	ALBEDO = rgb * gain;
	ALPHA = clamp(alpha, 0.0, 1.0) * fade;
}
