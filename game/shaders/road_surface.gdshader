// The carriageway (doc 11 §2.1.2). One MultiMesh of 8 m slabs; every line of
// paint, every crosswalk and every square metre of wear is computed here.
//
// ── why the paint is a shader and not geometry ────────────────────────────
// A dashed centre line laid as quads is ~2 instances per tile, a crosswalk is
// nine bars per approach, and both have to be re-emitted every time the player
// lays a road. Drawn from WORLD metres instead, the dash phase is continuous
// across a tile seam for free (no per-tile phase to carry, no seam to align),
// a 15 cm line stays 15 cm at Z0 and antialiases itself at Z2 through
// `fwidth`, and the whole road layer stays ONE draw call whatever the city
// does. The cost is this file.
//
// ── the per-instance contract ─────────────────────────────────────────────
// Doc 11 §2.6's `.b`-at-stride-448 packing is the BUILDING bucket's; roads are
// a different bucket with a different question to answer, so they carry their
// own four channels. `RoadSurfaceView` is the only writer and
// `tests/test_road_surface.gd` pins every field:
//
//   .r  neighbour mask   N=1 E=2 S=4 W=8, from the road GRAPH's tile
//                        membership. This is what decides whether a tile is a
//                        run, an elbow, a stub or a junction box.
//   .g  kerb mask        same bit order: which sides carry a footway. A side
//                        with a road neighbour never does, so this is also the
//                        gutter and edge-line mask.
//   .b  packed           cls + 2*pair + 16*crosswalk_mask
//                        cls   0 street, 1 avenue (from the graph EDGE's
//                              class, so a mixed segment renders as the
//                              slowest class it contains)
//                        pair  0 none, else 1=N 2=E 3=S 4=W — the twin half of
//                              a two-tile dual carriageway. The corridor runs
//                              PERPENDICULAR to it.
//                        crosswalk_mask  which sides get a zebra. Never a side
//                              whose neighbour is itself a junction tile,
//                              which is what stops a 2x2 avenue crossing from
//                              painting four zebras into its own middle.
//   .a  wear seed        [0,1) per tile, so no two pours are the same grey.
//
// ── the night floor ───────────────────────────────────────────────────────
// Inherited verbatim from `ground.gdshader` (report NIGHT-1): `night_albedo_lift`
// so what light there is bounces, `night_glow` as the skyglow emission that
// survives ambient reaching zero, `night_glow_wet_mult` because a wet
// carriageway mirrors that glow away from the camera. The paint gets a floor of
// its own on top — real thermoplastic is retroreflective, and at 03:00 the
// yellow line is the single strongest cue that the dark band is a STREET.
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

global uniform float sc_wetness;
global uniform float sc_night;
global uniform int sc_overlay_mode;

uniform sampler2D page: source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float has_page = 1.0;
uniform vec3 tint: source_color = vec3(0.34, 0.34, 0.37);
uniform float page_tile_m = 4.0;
uniform float tile_m = 8.0;

uniform float dry_roughness = 0.85;
uniform float dry_specular = 0.30;
uniform float wet_roughness = 0.18;
uniform float wet_specular = 0.85;
uniform float wet_albedo_mult = 0.62;

uniform vec3 night_color: source_color = vec3(0.42, 0.53, 0.72);
uniform float night_albedo_lift = 0.34;
uniform float night_glow = 0.048;
uniform float night_glow_wet_mult = 0.55;
uniform float overlay_desaturate = 0.55;

// ── footway geometry (the paint has to know where the kerb is) ─────────────
uniform float sidewalk_w_street = 1.40;
uniform float sidewalk_w_avenue = 1.05;

// ── paint ────────────────────────────────────────────────────────────────
uniform vec3 line_yellow: source_color = vec3(0.89, 0.71, 0.22);
uniform vec3 line_white: source_color = vec3(0.84, 0.84, 0.81);
uniform float centre_line_w = 0.16;
uniform float double_gap = 0.12;
uniform float edge_line_w = 0.12;
uniform float edge_line_inset = 0.28;
uniform float dash_mark = 2.40;
uniform float dash_gap = 3.60;
uniform float lane_dash_mark = 3.00;
uniform float lane_dash_gap = 5.00;
uniform float dead_end_stop = 2.50;
uniform float marking_night_glow = 0.075;
uniform float marking_roughness = 0.55;
uniform float marking_wear_loss = 0.35;

uniform float crosswalk_bar = 0.45;
uniform float crosswalk_period = 0.85;
uniform float crosswalk_depth = 1.35;
uniform float crosswalk_inset = 0.35;

// ── the detail ladder ────────────────────────────────────────────────────
// `detail` is a UNIFORM, so every branch on it below is uniform control flow —
// one scalar decision for the whole draw, not per-fragment divergence, and the
// `fwidth()` calls inside those branches are therefore taken in uniform flow,
// which is the case the derivative rules allow. Authored in `data/render.json`
// (`road_surface.detail`, and per preset via `presets.*.road_detail`); the
// governor may lower it and never raise it above the preset's value.
//
//   2  FULL     — everything this file can draw. The shipped look.
//   1  −WEAR    — drops the 11 m hash mottle, the pour joint, the wheel-path
//                 polish and the kerb grime. Every line of PAINT survives,
//                 including the zebra. This is the cheapest cut that does not
//                 change what the street MEANS.
//   0  −ZEBRA   — also drops the four-leg crossing loop (the only loop in the
//                 file). Crossings stop being painted; the carriageway still
//                 reads. Since the junction early-out below, this rung buys far
//                 less than it did: the loop no longer runs on the ~90 % of
//                 carriageway tiles that are not junctions, so the ladder at Z0
//                 is 0.092 ms instead of 0.153 (doc 11 §2.13, RR-38).
//
// Measured cost per level: doc 11 §2.13, "The asphalt fragment ladder".
uniform int detail = 2;

// ── wear ─────────────────────────────────────────────────────────────────
uniform float patch_gain = 0.16;
uniform float patch_scale_m = 11.0;
uniform float seam_darken = 0.16;
uniform float wheel_path_gain = 0.10;
uniform float wheel_path_w = 0.95;
uniform float gutter_m = 0.55;
uniform float gutter_darken = 0.22;
uniform float wear_tile_gain = 0.07;

// `v_pack` is INSTANCE_CUSTOM and is CONSTANT over an instance: flat, exactly
// as doc 11 §2.6 requires of every custom-data varying. Interpolating a bit
// mask would decode to garbage on every fragment but the vertices.
varying flat vec4 v_pack;
varying vec2 v_local;   // metres from the tile centre, model space
varying vec2 v_world;   // world metres (x, z)
varying float v_up;     // 1 on the slab's top face, 0 on its 10 cm edges

void vertex() {
	v_pack = INSTANCE_CUSTOM;
	v_local = VERTEX.xz;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	v_up = step(0.7, abs(NORMAL.y));
}

float hash21(vec2 p) {
	vec2 q = fract(p * vec2(123.34, 456.21));
	q += dot(q, q + 45.32);
	return fract(q.x * q.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// A band of half-width `hw` centred on d = 0, antialiased at the pixel's own
// footprint. `aa` is passed in because the caller already knows the derivative
// of the coordinate it is measuring in.
float band(float d, float hw, float aa) {
	return 1.0 - smoothstep(hw - aa, hw + aa, abs(d));
}

// The mark half of a mark/gap cycle, phase taken off a WORLD coordinate so the
// pattern crosses a tile boundary without a seam.
//
// The `mix` at the end is the band limit, and it is what keeps Z2 still. Once a
// pixel's footprint approaches the dash PERIOD the pattern is past Nyquist, and
// a `fract()` sampled past Nyquist crawls: the marketed skyline frame would
// shimmer along every lane line as the camera moved. Fading to the duty cycle
// is the correct band-limited answer — the average of the pattern over the
// footprint — so a distant lane line resolves to a faint continuous stripe
// instead of to noise. `band()` needs no such term: its smoothstep already
// converges on partial coverage as `aa` grows past the line's half-width.
float dashes(float s, float mark, float gap, float aa) {
	float period = max(mark + gap, 0.01);
	float ph = fract(s / period) * period;
	float d = (1.0 - smoothstep(mark - aa, mark + aa, ph)) * smoothstep(-aa, aa, ph);
	return mix(d, mark / period, clamp(aa * 2.0 / period, 0.0, 1.0));
}

// Distance to the axis-aligned segment u*[lo, hi] through the tile centre.
float seg_dist(vec2 p, vec2 u, float lo, float hi) {
	float t = clamp(dot(p, u), lo, hi);
	return length(p - u * t);
}

void fragment() {
	// ── decode ────────────────────────────────────────────────────────────
	float mask = v_pack.r;
	float kerb = v_pack.g;
	float packed = v_pack.b;
	float wear_seed = v_pack.a;

	float bN = floor(mod(mask, 2.0));
	float bE = floor(mod(mask * 0.5, 2.0));
	float bS = floor(mod(mask * 0.25, 2.0));
	float bW = floor(mod(mask * 0.125, 2.0));
	float kN = floor(mod(kerb, 2.0));
	float kE = floor(mod(kerb * 0.5, 2.0));
	float kS = floor(mod(kerb * 0.25, 2.0));
	float kW = floor(mod(kerb * 0.125, 2.0));

	float cw_mask = floor(packed / 16.0);
	float rest = packed - cw_mask * 16.0;
	float pair = floor(rest * 0.5);
	float cls = rest - pair * 2.0;

	float half_tile = tile_m * 0.5;
	float sw = mix(sidewalk_w_street, sidewalk_w_avenue, cls);

	// ── orientation ───────────────────────────────────────────────────────
	// A paired tile runs perpendicular to its twin; everything else runs along
	// whichever axis carries more neighbours (which also resolves a stub).
	float ns = bN + bS;
	float ew = bE + bW;
	// `pair` is 0 none, 1=N 2=E 3=S 4=W. An N/S twin stacks across Z, so the
	// corridor itself runs along X; `twin_sign` is which way the shared edge
	// lies in the `across` coordinate below.
	float isN = 1.0 - step(0.5, abs(pair - 1.0));
	float isE = 1.0 - step(0.5, abs(pair - 2.0));
	float isS = 1.0 - step(0.5, abs(pair - 3.0));
	float isW = 1.0 - step(0.5, abs(pair - 4.0));
	float is_pair = step(0.5, pair);
	float twin_is_ns = isN + isS;
	float twin_sign = isE + isS - isN - isW;
	float axis_x = mix(step(ns + 0.5, ew), twin_is_ns, is_pair);

	// `across` is the coordinate the lines are offset in, `along` the one the
	// dash phase runs in.
	float across = mix(v_local.x, v_local.y, axis_x);
	float along = mix(v_world.y, v_world.x, axis_x);
	float aa_across = max(fwidth(across) * 0.75, 0.0008);
	float aa_along = max(fwidth(along) * 0.75, 0.0008);

	// The two kerb-bearing sides on the ACROSS axis.
	float kerb_neg = mix(kW, kN, axis_x);
	float kerb_pos = mix(kE, kS, axis_x);

	// ── classify ──────────────────────────────────────────────────────────
	float degree = bN + bE + bS + bW;
	float free = 1.0 - is_pair;
	float is_junction = free * step(2.5, degree);
	float is_two = step(1.5, degree) * step(degree, 2.5);
	float is_elbow = free * is_two * step(0.5, ns) * step(0.5, ew);
	float is_run = free * is_two * (1.0 - is_elbow);
	float is_stub = free * step(0.5, degree) * step(degree, 1.5);

	// ── centre line ───────────────────────────────────────────────────────
	// A run and a stub measure straight across; an elbow measures to the two
	// half-segments that meet at the tile centre; a paired half puts its single
	// solid line just inside the shared edge so the two halves together read as
	// one double-yellow. A junction draws none of it: doc 11 §2.1.2's rule is
	// that no centre line crosses a junction box.
	vec2 uN = vec2(0.0, -1.0);
	vec2 uE = vec2(1.0, 0.0);
	vec2 uS = vec2(0.0, 1.0);
	vec2 uW = vec2(-1.0, 0.0);
	float elbow_d = min(
			min(mix(1e3, seg_dist(v_local, uN, 0.0, half_tile), bN),
				mix(1e3, seg_dist(v_local, uE, 0.0, half_tile), bE)),
			min(mix(1e3, seg_dist(v_local, uS, 0.0, half_tile), bS),
				mix(1e3, seg_dist(v_local, uW, 0.0, half_tile), bW)));
	// The stub's line stops `dead_end_stop` short of the closed end.
	float stub_lo = -(half_tile - dead_end_stop);
	float stub_d = min(
			min(mix(1e3, seg_dist(v_local, uN, stub_lo, half_tile), bN),
				mix(1e3, seg_dist(v_local, uE, stub_lo, half_tile), bE)),
			min(mix(1e3, seg_dist(v_local, uS, stub_lo, half_tile), bS),
				mix(1e3, seg_dist(v_local, uW, stub_lo, half_tile), bW)));

	// Half of the double-yellow: this tile's line sits `0.06 m` inside the
	// shared edge, its twin mirrors it, and together they read as one pair.
	float twin_line = half_tile - 0.06 - centre_line_w * 0.5;

	float half_gap = double_gap * 0.5 + centre_line_w * 0.5;
	float solid_double = max(band(across - half_gap, centre_line_w * 0.5, aa_across),
			band(across + half_gap, centre_line_w * 0.5, aa_across));
	float dashed_single = band(across, centre_line_w * 0.5, aa_across)
			* dashes(along, dash_mark, dash_gap, aa_along);
	// Streets get the dashed single, single-tile avenues the solid double.
	float run_line = mix(dashed_single, solid_double, cls);
	float elbow_line = band(elbow_d, centre_line_w * 0.5, aa_across)
			* mix(dashes(along, dash_mark, dash_gap, aa_along), 1.0, cls);
	float stub_line = band(stub_d, centre_line_w * 0.5, aa_across)
			* mix(dashes(along, dash_mark, dash_gap, aa_along), 1.0, cls);
	float pair_line = band(across - twin_sign * twin_line, centre_line_w * 0.5, aa_across);

	float yellow = max(max(run_line * is_run, elbow_line * is_elbow),
			max(stub_line * is_stub, pair_line * is_pair));

	// ── white paint: lane divider, edge lines, zebra ───────────────────────
	// Only a paired half has two same-direction lanes to divide.
	float lane_div = band(across - twin_sign * sw * 0.5, edge_line_w * 0.5, aa_across)
			* dashes(along, lane_dash_mark, lane_dash_gap, aa_along) * is_pair;

	float edge_at = half_tile - sw - edge_line_inset;
	float edge_line = max(band(across + edge_at, edge_line_w * 0.5, aa_across) * kerb_neg,
			band(across - edge_at, edge_line_w * 0.5, aa_across) * kerb_pos)
			* (1.0 - is_junction);

	// Zebra: bars run WITH the traffic on the leg they cross and repeat across
	// it, clipped to the carriageway so no bar climbs a footway. The whole
	// block — the four leg frames as well as the loop — sits inside the rung,
	// so `detail == 0` does not pay to build the arrays it will not read.
	//
	// ── the junction early-out (doc 11 §2.1.2 and §2.13, report 98 RR-38) ──
	// This loop was the most expensive thing in the file — 0.107–0.109 ms at
	// the Z0 pose, 2.4× every wear term put together — and it paints on
	// JUNCTION tiles only, which are a small minority of the carriageway.
	// `cw_mask` is decoded out of `v_pack.b`, which is `flat`: constant across
	// a primitive, and a derivative quad never spans two primitives, so the
	// four fragments of a quad always agree on this test. The branch is
	// therefore QUAD-UNIFORM, which is the scope the derivative rules are
	// written at — `detail` is a uniform, `cw_mask > 0.5` is per-instance, and
	// the conjunction is uniform over every quad that ever executes it. A tile
	// whose mask is zero produces `zebra = 0.0` either way: `leg[i]` is 0 on
	// every leg, every other factor is finite and in [0, 1], and `max(0, 0·x)`
	// is `0`.
	//
	// ── and the eight derivatives are four ─────────────────────────────────
	// Legs 0/2 differ only in the SIGN of the perpendicular coordinate and
	// legs 1/3 likewise, and `fwidth(-x) == fwidth(x)` bit-for-bit: IEEE
	// negation is exact, `(-a) - (-b)` is exactly `-(a - b)`, and `abs` is
	// exact, so `|dFdx| + |dFdy|` cannot move. The eight calls are therefore
	// four DISTINCT values, taken once at the top of the block and looked up
	// per leg.
	//
	// ── what is NOT done here, and why ─────────────────────────────────────
	// The same argument says legs 0 and 2 share their `dashes()` call and
	// their carriageway clip outright, and 1 and 3 likewise: four `dashes()`
	// could be two. **That version was written, measured and rejected.** At
	// the Z0 pose — the one where a same-build control run is byte-identical,
	// so the instrument has no noise floor at all — folding the shared terms
	// out moved 1 pixel of 2,073,600 at hour 21 and 4 at hour 13, at rungs 1
	// and 2 and never at rung 0. It is the pour-joint scar below in a second
	// place: an algebraically-exact regrouping is not a codegen-exact one, and
	// this file's contract is the picture, not the algebra. The hoist below
	// keeps every surviving expression as the same operations on the same
	// floats in the same order, and IS byte-identical at Z0.
	float zebra = 0.0;
	float outer = half_tile - crosswalk_inset;
	float inner = outer - crosswalk_depth;
	if (detail >= 1 && cw_mask > 0.5) {
		float aa_lx = max(fwidth(v_local.x) * 0.75, 0.0008);
		float aa_ly = max(fwidth(v_local.y) * 0.75, 0.0008);
		float aa_wx = max(fwidth(v_world.x) * 0.75, 0.0008);
		float aa_wy = max(fwidth(v_world.y) * 0.75, 0.0008);
		float perp[4];
		float par_local[4];
		float par_world[4];
		float aa_perp[4];
		float aa_par[4];
		float leg[4];
		perp[0] = -v_local.y; par_local[0] = v_local.x; par_world[0] = v_world.x;
		perp[1] = v_local.x;  par_local[1] = v_local.y; par_world[1] = v_world.y;
		perp[2] = v_local.y;  par_local[2] = v_local.x; par_world[2] = v_world.x;
		perp[3] = -v_local.x; par_local[3] = v_local.y; par_world[3] = v_world.y;
		aa_perp[0] = aa_ly; aa_par[0] = aa_wx;
		aa_perp[1] = aa_lx; aa_par[1] = aa_wy;
		aa_perp[2] = aa_ly; aa_par[2] = aa_wx;
		aa_perp[3] = aa_lx; aa_par[3] = aa_wy;
		leg[0] = floor(mod(cw_mask, 2.0));
		leg[1] = floor(mod(cw_mask * 0.5, 2.0));
		leg[2] = floor(mod(cw_mask * 0.25, 2.0));
		leg[3] = floor(mod(cw_mask * 0.125, 2.0));
		for (int i = 0; i < 4; i++) {
			float aa_p = aa_perp[i];
			float aa_q = aa_par[i];
			float in_band = smoothstep(inner - aa_p, inner + aa_p, perp[i])
					* (1.0 - smoothstep(outer - aa_p, outer + aa_p, perp[i]));
			float in_road = 1.0 - smoothstep(half_tile - sw - aa_p, half_tile - sw + aa_p,
					abs(par_local[i]));
			float bars = dashes(par_world[i], crosswalk_bar, crosswalk_period - crosswalk_bar,
					aa_q);
			zebra = max(zebra, leg[i] * in_band * in_road * bars);
		}
	}

	float white = max(max(lane_div, edge_line), zebra);

	// ── surface ───────────────────────────────────────────────────────────
	// ONE fetch, outside every branch above and below (doc 11 §2.6's rule).
	vec3 surface = texture(page, v_world / max(page_tile_m, 0.01)).rgb;
	vec3 albedo = tint * mix(vec3(1.0), surface, has_page);

	// Everything from here to the paint is WEAR, and it is the `detail >= 2`
	// rung: the hash mottle, the pour joint, the wheel-path polish and the kerb
	// grime. The per-tile trim (`wear_seed`) stays at every rung — it is a
	// varying already in hand and one multiply, so cutting it would buy nothing
	// and would make two adjacent pours the same grey, which is the one wear cue
	// that is visible at Z2.
	float wheel = 0.0;
	// Cuts and patches: an 11 m mottle, so two pours that share a seam are never
	// the same grey. The mottle and the per-tile trim are folded into ONE
	// multiply, exactly as they were before the ladder existed — writing them as
	// two multiplies would introduce the cross term `patch·seed` and move every
	// asphalt pixel by up to 4/255, which is what the A/B caught.
	float patch_term = 0.0;
	if (detail >= 2) {
		patch_term = (vnoise(v_world / max(patch_scale_m, 0.01)) - 0.5) * patch_gain;
	}
	albedo *= 1.0 + patch_term + (wear_seed - 0.5) * wear_tile_gain;
	if (detail >= 2) {
		// The pour joint at every 8 m tile line.
		vec2 seam_d = abs(fract(v_world / tile_m + 0.5) - 0.5) * tile_m;
		float seam_aa = max(fwidth(v_world.x) * 0.75, 0.0008);
		float seam = max(band(seam_d.x, 0.05, seam_aa), band(seam_d.y, 0.05, seam_aa));
		albedo *= 1.0 - seam * seam_darken * v_up;

		// Polished tracks down each lane. `carr_*` is the carriageway this tile
		// actually owns — a paired half owns everything from the shared edge to
		// its one kerb, so both of its lanes sit on the same side of the twin
		// line. `lane_c ± lane_half` are the two lane centres; one broad band
		// each reads as traffic polish at every zoom and costs two `band()`
		// calls.
		float carr_hi = mix(half_tile - sw, half_tile, is_pair * step(0.0, twin_sign));
		float carr_lo = mix(-(half_tile - sw), -half_tile, is_pair * step(twin_sign, 0.0));
		float lane_c = (carr_hi + carr_lo) * 0.5;
		float lane_half = (carr_hi - carr_lo) * 0.25;
		wheel = band(abs(across - lane_c) - lane_half, wheel_path_w * 0.5, aa_across)
				* (1.0 - is_junction);
		albedo *= 1.0 - wheel * wheel_path_gain * v_up;

		// Grime against the kerb.
		float gut_at = half_tile - sw;
		float gutter = max(
				smoothstep(gut_at - gutter_m, gut_at, across) * kerb_pos,
				smoothstep(gut_at - gutter_m, gut_at, -across) * kerb_neg);
		albedo *= 1.0 - gutter * gutter_darken * v_up;
	}

	// ── paint on top ──────────────────────────────────────────────────────
	// Paint wears out of the wheel tracks first, which is the difference
	// between a line that was painted and a decal that was pasted.
	float paint_keep = 1.0 - wheel * marking_wear_loss;
	float y_cov = yellow * v_up * paint_keep;
	float w_cov = white * v_up * paint_keep;
	vec3 paint = mix(line_yellow, line_white, step(y_cov, w_cov));
	float cov = max(y_cov, w_cov);
	albedo = mix(albedo, paint, cov);

	albedo *= mix(1.0, wet_albedo_mult, sc_wetness);
	albedo += night_color * (night_albedo_lift * sc_night);

	ALBEDO = albedo;
	EMISSION = night_color * (night_glow * sc_night
			* mix(1.0, night_glow_wet_mult, sc_wetness))
			+ paint * (marking_night_glow * sc_night * cov);
	ROUGHNESS = mix(mix(dry_roughness, marking_roughness, cov), wet_roughness, sc_wetness);
	SPECULAR = mix(dry_specular, wet_specular, sc_wetness);

	if (sc_overlay_mode > 0) {
		float luma = dot(ALBEDO, vec3(0.2126, 0.7152, 0.0722));
		ALBEDO = mix(ALBEDO, vec3(luma), overlay_desaturate);
		float glow_luma = dot(EMISSION, vec3(0.2126, 0.7152, 0.0722));
		EMISSION = mix(EMISSION, vec3(glow_luma), overlay_desaturate);
	}
}
