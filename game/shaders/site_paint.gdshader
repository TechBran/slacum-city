// Where a source can legally go, drawn on the ground (doc 12 §2.7 D-130).
//
// Wave 28's `BuildController.placement_sites()` answers "where CAN this go" as
// a SET of verified footprint origins, and Wave 28's placement bar printed the
// count. This is the other half: the set, on the ground, under the refused
// ghost. One translucent MultiMesh of 8 m tile quads a hand above the surface —
// `game/render/site_paint_view.gd` builds it from `BuildSheet.site_paint()` and
// hides the node outright when the window found nothing, so the layer costs
// **+1 draw call while a blocked ghost is being placed and +0 the rest of the
// time**. Doc 12 §2.5 mode 5's road overlay is the same shape one file over;
// this one draws a MARK as well, because a placement tile has to say what KIND
// of site it is and there is no road under it to carry a hatch.
//
// Per-instance inputs, all written by that view:
//   COLOR.rgb  the state hue out of data/ui.json's palette (linear at the
//              write, RR-91), so the colourblind variants carry
//   COLOR.a    the distance fade: alpha_near at the ghost, alpha_far at the
//              edge of the window that was scanned
//   CUSTOM.x   glyph index into data/ui.json.state_glyphs order:
//              0 circle_filled (a clean site), 1 triangle (a site doc 93 §BD9
//              warns about), 2 diamond, 3 cross — the legend's own vocabulary,
//              never a fifth mark
//   CUSTOM.y   1.0 on the site the bar's sentence NAMES ("the nearest is N
//              tiles away"), which draws the ring
//   CUSTOM.z   glyph radius, tile fraction
//   CUSTOM.w   unused
//
// **Colour is never load-bearing** (constitution §11 / A5). Three channels say
// the same thing: hue, the mark, and the alpha ramp — and the mark alone
// survives greyscale, which is the one that matters, because the difference
// between a site that will run and a site on a full pole-top is the difference
// between spending $45,858 well and spending it on a pump at power_fraction
// 0.00 (A91-D-153).
//
// Nothing here reads a clock. The paint is a pure function of the window that
// was scanned and the tile the ghost is standing on, so two devices showing the
// same placement show the same ground.
shader_type spatial;
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never, shadows_disabled;

// How bright the tile is BETWEEN the mark and the edge. 1.0 would be a flat
// wash with no mark at all; 0.0 would be a floating glyph on nothing, which
// reads as decoration rather than as "this square of ground".
uniform float wash_floor = 0.34;
// Smoothing half-width of every contour, in tile fractions. One number for the
// mark, the ring and the border, so they can never anti-alias differently.
uniform float glyph_edge = 0.05;
uniform float ring_radius = 0.42;
uniform float ring_width = 0.05;

varying vec4 v_paint;    // rgb hue, a fade alpha
varying vec4 v_shape;    // x glyph index, y nearest flag, z glyph radius

void vertex() {
	v_paint = COLOR;
	v_shape = INSTANCE_CUSTOM;
}

// The four marks of data/ui.json.state_glyphs, as fields rather than as a
// texture page: `p` is centred on the tile and runs -0.5..0.5 on both axes.
// A page would be a second material and a second upload for four shapes that
// are three lines of algebra each.
float mark(vec2 p, int glyph, float r, float e) {
	if (glyph == 1) {
		// triangle, point up: three half-planes, the widest of which is the
		// signed distance to the shape.
		float d = max(max(-p.y - r * 0.55, p.y * 0.5 + p.x * 0.866 - r * 0.5),
				p.y * 0.5 - p.x * 0.866 - r * 0.5);
		return 1.0 - smoothstep(-e, e, d);
	}
	if (glyph == 2) {
		// diamond
		return 1.0 - smoothstep(r - e, r + e, abs(p.x) + abs(p.y));
	}
	if (glyph == 3) {
		// cross: two rotated bars
		vec2 q = vec2(p.x + p.y, p.x - p.y) * 0.7071;
		float bar = min(max(abs(q.x) - r, abs(q.y) - r * 0.26),
				max(abs(q.y) - r, abs(q.x) - r * 0.26));
		return 1.0 - smoothstep(-e, e, bar);
	}
	// circle_filled
	return 1.0 - smoothstep(r - e, r + e, length(p));
}

void fragment() {
	vec2 p = UV - vec2(0.5);
	int glyph = int(v_shape.x + 0.5);
	float radius = max(v_shape.z, 0.02);
	float e = max(glyph_edge, 0.001);

	float g = mark(p, glyph, radius, e);
	// The border: a one-tile outline so a lit tile reads as a TILE — the unit
	// the tap lands on — and not as a soft blob that could be anywhere.
	float edge = max(abs(p.x), abs(p.y));
	float border = smoothstep(0.5 - 0.055 - e, 0.5 - 0.055 + e, edge)
			* (1.0 - smoothstep(0.5 - e, 0.5 + e, edge));
	// The ring goes only on the site the bar's sentence names, so "the nearest
	// is N tiles away" points at something.
	float ring = step(0.5, v_shape.y)
			* (smoothstep(ring_radius - ring_width - e, ring_radius - ring_width + e,
					length(p))
			* (1.0 - smoothstep(ring_radius + ring_width - e,
					ring_radius + ring_width + e, length(p))));

	float ink = clamp(max(max(g, border), ring), 0.0, 1.0);
	ALBEDO = v_paint.rgb;
	ALPHA = v_paint.a * mix(wash_floor, 1.0, ink);
}
