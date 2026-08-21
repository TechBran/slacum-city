// STREET LIFE furniture (doc 11 §2.17) — the attention MARKER over a live
// opportunity, the `+$N` LABEL that rises off a collected one, the POOF that
// replaces it, and the SPARKLE over a dropped stash.
//
// SIX EFFECTS, ONE DRAW CALL. Five of them are the same thing: a flat quad
// turned to face the camera, alpha-blended, writing no depth. So they are one
// MultiMesh with a MODE in `INSTANCE_CUSTOM.r` rather than five buffers, five
// materials and five calls — which matters, because the layer's whole budget is
// four calls including the three character bodies.
//
// The sixth is the BLOB SHADOW, and it is on this buffer for the same economics
// even though it is the one quad that does NOT face the camera: it is still a
// flat, alpha-blended, depth-writeless quad, so it costs a `mix` of three basis
// columns in the vertex stage (below) and a mask in the fragment stage instead
// of a whole extra submission. It is drawn only where the preset has switched
// REAL shadows off — `vehicle_shadows`, the one knob — so no body ever has two
// shadows and no body on a phone has none.
//
// INSTANCE_CUSTOM
//   .r MODE   0 marker, 1 puff, 2 ring, 3 glyph, 4 sparkle, 5 BLOB SHADOW
//   .g        modes 0 and 3: the GLYPH index into the atlas page, 0..15
//             modes 1, 2 and 4: PROGRESS / phase, 0..1
//             mode 5: the NIGHT FADE fraction — how much of the shadow is
//             taken away at midnight, because a contact shadow needs a sun
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

// ---- the blob shadow (mode 5) --------------------------------------------
// BLACK, and it took a screenshot to be sure. The first pass authored the
// ambient's own blue-grey (0.055, 0.062, 0.080) on the reasoning that a real
// contact shadow is sky-coloured — but this pass is `blend_mix`, so the value
// is a colour the ground is mixed TOWARDS, not a factor it is multiplied by,
// and the shaded carriageway at Z0 sits near 0.02 linear. The shadow was
// LIGHTER than the road it was cast on and the whole layer was invisible in
// the picture while the census said it was there.
//
// Black makes `blend_mix` a multiply: at alpha a, the ground keeps (1 − a) of
// itself whatever it was, so the same disc darkens dark asphalt and pale
// pavement by the same FRACTION — which is what a shadow does.
uniform vec3 blob_color : source_color = vec3(0.0, 0.0, 0.0);
// A CORE and a RIM, not a falloff from the centre — the second thing the
// screenshot corrected. The first pass used the poof's own
// `pow(1 − r, softness)`, which peaks at a single pixel and is already half
// gone a third of the way out: measured at the shipping size it put 244 pixels
// of real shadow under a body and the picture had nothing in it. A body has an
// AREA of contact, so the disc is solid to `blob_core` and ramps to nothing at
// the rim. Same instruction count, and it is the difference between a contact
// shadow and a smudge.
uniform float blob_core = 0.42;

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
	//
	// EXCEPT mode 5. A blob shadow is a DECAL: it lies on the pavement, and a
	// camera-facing one would stand up like a card the moment the player tilted
	// the view. So the billboard's three basis columns are `mix`ed against the
	// instance's own — three vec4 mixes and no branch, which is the price of
	// keeping the contact shadow on this buffer instead of paying a draw call
	// for a fifth one. The CPU writes a quad already rotated flat (see
	// `StreetLifeModel._emit_blob`), so `is_blob` simply lets that basis through.
	float is_blob = step(4.5, v_mode);
	mat4 model = MODEL_MATRIX;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			mix(INV_VIEW_MATRIX[0] * length(model[0].xyz), model[0], is_blob),
			mix(INV_VIEW_MATRIX[1] * length(model[1].xyz), model[1], is_blob),
			mix(INV_VIEW_MATRIX[2], model[2], is_blob),
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
	float m_spark = step(3.5, v_mode) * (1.0 - step(4.5, v_mode));
	float m_blob = step(4.5, v_mode);

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

	// ---- the blob: a soft dark disc on the pavement ----------------------
	// `r` is the same radial term the puff uses, so the contact shadow costs one
	// `pow` and nothing else. Squared falloff rather than the puff's softer one:
	// a shadow has a core, and a linear ramp reads as a smudge.
	// `.g` carries the NIGHT FADE fraction — a shadow needs the sun, and by
	// 03:00 the only light is a lamp thirty metres away.
	float blob_a = (1.0 - smoothstep(blob_core, 1.0, r))
			* mix(1.0, 1.0 - clamp(v_arg, 0.0, 1.0), clamp(sc_night, 0.0, 1.0));

	// ---- combine, by mask, with no branch -------------------------------
	vec3 rgb = marker_rgb * m_marker
			+ puff_color * (m_puff + m_ring)
			+ mix(label_outline, COLOR.rgb, ink) * m_glyph
			+ sparkle_color * m_spark
			+ blob_color * m_blob;
	float alpha = marker_a * m_marker
			+ puff_a * m_puff
			+ ring_a * m_ring
			+ max(ink, outline) * m_glyph
			+ spark_a * m_spark
			+ blob_a * m_blob;

	// Energy, not a light: this pass is `unshaded`, so lifting ALBEDO above 1
	// is what puts the mark into the glow post-process after dark, exactly the
	// way the lamp billboards do it.
	float energy = mix(marker_energy_day, marker_energy_night, clamp(sc_night, 0.0, 1.0));
	float gain = m_marker * energy
			+ (m_puff + m_ring) * 1.0
			+ m_glyph * label_energy
			+ m_spark * sparkle_energy * mix(0.7, 1.0, clamp(sc_night, 0.0, 1.0))
			// A shadow emits nothing. Its whole job is to take light AWAY, which
			// `blend_mix` does with a near-black albedo and the alpha above.
			+ m_blob * 1.0;

	ALBEDO = rgb * gain;
	ALPHA = clamp(alpha, 0.0, 1.0) * fade;
}
