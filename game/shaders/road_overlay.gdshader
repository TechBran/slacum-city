// Road congestion overlay (doc 12 §2.5 mode 5 · doc 10 §2.15).
//
// Traffic is the one overlay whose data is not per BUILDING: congestion is a
// property of a road EDGE, so this is the only overlay that tints the ground.
// It is a second, translucent MultiMesh of 8 m tile quads laid one hand's
// breadth above the road slabs — `game/render/road_overlay_view.gd` builds it
// from `TrafficSnapshot.visible_edges` and shows it only while mode 5 is live,
// so the road material itself is never touched and a city with the overlay off
// pays nothing but one hidden node.
//
// Per-instance inputs, both written by that view:
//   COLOR.rgb  the band's hue, taken from data/ui.json's palette (so the
//              colourblind variants carry it) and deepened by `darken`
//   COLOR.a    the band's wash alpha — a monotone lightness ramp
//   CUSTOM.x   stripe duty 0..1: the diagonal hatch density
//   CUSTOM.y   pulse Hz, 0 for the bands that hold still
//
// Colour is never load-bearing (constitution §11 / spec §49). Three channels
// carry the same reading here: hue, the alpha ramp, and a diagonal hatch whose
// density rises with congestion — the last of which survives greyscale on its
// own. The two worst bands also pulse, which is motion, not decoration: they
// are the two that mean STOP.
//
// The hatch coordinate is WORLD space, so the stripes run continuously across
// tile seams and a jammed corridor reads as one band rather than as 40 squares.
shader_type spatial;
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never, shadows_disabled;

global uniform float sc_time;
global uniform int sc_overlay_mode;

// The mode's index into data/ui.json.overlay.modes: none 0, power 1, water 2,
// police 3, fire 4, traffic 5. Belt and braces with the view's `visible` flag —
// a stale node can never paint the city while another overlay is up.
const int OVERLAY_MODE_TRAFFIC = 5;

uniform float stripe_period_m = 5.6;
uniform float stripe_scroll_m_s = 1.8;
// How bright the space BETWEEN stripes is, as a fraction of the band's alpha.
// 1.0 would be a flat wash with no pattern at all; 0.0 would be stripes on
// nothing, which reads as damage rather than as data.
uniform float wash_floor = 0.45;

varying vec2 v_world_xz;
varying vec4 v_band;      // rgb hue, a wash alpha
varying vec2 v_shape;     // x stripe duty, y pulse Hz

void vertex() {
	v_world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	v_band = COLOR;
	v_shape = INSTANCE_CUSTOM.xy;
}

void fragment() {
	// x + z is continuous across the whole grid and constant along a 45° line,
	// which is what makes the hatch diagonal without a rotation matrix.
	float coord = (v_world_xz.x + v_world_xz.y - sc_time * stripe_scroll_m_s)
			/ stripe_period_m;
	// duty 0 → step(1.0, fract(…)) is 0 everywhere: a flat wash, no hatch.
	float stripe = step(1.0 - v_shape.x, fract(coord));
	float alpha = v_band.a * mix(wash_floor, 1.0, stripe);
	// pulse_hz 0 leaves the band perfectly still (step is 0, mix picks 1.0).
	float pulse = 0.62 + 0.38 * sin(sc_time * 6.283185 * v_shape.y);
	alpha *= mix(1.0, pulse, step(0.0001, v_shape.y));

	ALBEDO = v_band.rgb;
	ALPHA = sc_overlay_mode == OVERLAY_MODE_TRAFFIC ? alpha : 0.0;
}
