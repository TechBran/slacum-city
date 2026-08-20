// Pad-mounted distribution transformer (doc 04 §2.1's `transformer`, doc 11's
// distribution layer). ONE MultiMesh carries every pad in the city — see
// `PowerInfraView._build_pads` for why that is one draw call and not one per
// chunk — so everything that varies between two pads has to arrive in the
// instance buffer or be derived from model-space position here.
//
// INSTANCE_CUSTOM, §2.6's channel roles unchanged:
//   .r  heat        0..1, the fins' glow (PowerInfraModel.glow_target_for)
//   .g  damage      0..1, soot (burn ramp, or plain age under `worn_condition`)
//   .b  packed      distress + 112 * overlay_state — the SAME 112 stride and
//                   the same decoder shape `building.gdshader.overlay_of()`
//                   uses, so the two shaders cannot drift on the field they
//                   share. A pad has no variant / stage / level, so the low
//                   field is the distress band instead.
//   .a  anim phase  PowerInfraModel.phase_for(id) — deterministic per id
//
// Vertex COLOR: .rgb is the part's baked albedo, .a is `part / 8` (see
// `PART_*` below). Eight parts is what an 8-bit vertex-colour channel round
// trips exactly under `floor(a*8 + 0.5)`, which is the same trick the building
// shader's level atlas plays with `COLOR.a`.
//
// UV is metres / `prop_tile_m`, so the galvanised prop page lands at the same
// physical pitch here as it does on a lamp post — a 1.5 m cabinet and an 8 m
// pole carry one grain.
//
// The single `texture()` fetch sits at the TOP of fragment(), outside every
// branch: divergent-control-flow fetches have undefined derivatives on tiled
// mobile GPUs, and this shader's branches are all per-part.
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

global uniform float sc_night;
global uniform float sc_time;
global uniform float sc_wetness;
global uniform int sc_overlay_mode;

uniform sampler2D grain_tex: source_color, filter_linear_mipmap, repeat_enable;
uniform float grain_amount = 0.34;
uniform float base_roughness = 0.62;
uniform float base_metallic = 0.22;

// ── the burn ──────────────────────────────────────────────────────────────
uniform vec3 char_color: source_color = vec3(0.086, 0.075, 0.067);
// Soot climbs. Below `char_floor_m` the concrete apron stays a pad and not a
// scorch mark, which is what makes a burned unit read as "the CABINET went".
uniform float char_floor_m = 0.10;
uniform float char_top_m = 1.10;
uniform float char_roughness = 0.94;

// ── the heat ──────────────────────────────────────────────────────────────
uniform vec3 heat_color: source_color = vec3(1.0, 0.392, 0.145);
// 1.35, not the 2.30 of the first pass, and the fins carry nearly all of it.
// At 2.30 with a 0.28 cabinet share a SEVERE unit read as a moulded plastic
// lantern from twenty metres — the whole box the same flat orange, which is
// neither what hot steel looks like nor what the fins are for. The radiator is
// where the heat leaves a transformer, so the radiator is where it shows.
uniform float heat_nits = 1.35;
uniform float heat_cabinet_share = 0.14;
uniform float heat_lid_share = 0.10;
uniform float heat_flicker_hz = 0.9;

// ── radiator banks ────────────────────────────────────────────────────────
// The fins are SHADED, not modelled: two proud banks per side carry the
// silhouette and this pitch draws the seven fins inside each one. At Z0 a fin
// is ~3 px, which is exactly the scale at which geometry costs and a groove
// term does not.
uniform float fin_pitch_m = 0.135;
uniform float fin_groove = 0.46;

// ── the door ──────────────────────────────────────────────────────────────
uniform vec3 placard_color: source_color = vec3(0.86, 0.83, 0.71);
uniform vec3 seam_color: source_color = vec3(0.129, 0.153, 0.133);
uniform vec4 placard_rect = vec4(-0.20, 0.74, 0.20, 1.12);   // x0, y0, x1, y1

// ═════════ BEGIN overlay pass — sc_overlay_mode (doc 12 §2.5) ═════════════
// The player's ask was that the POWER overlay light up the PHYSICAL network,
// not just the building tints. The palette and the blend weights are
// `building.gdshader`'s, verbatim, so a pad and the building it feeds wear the
// same hue for the same state; the only difference is that a pad in POWER mode
// also carries a floor of emission, because a pad is 1.5 m of dark cabinet and
// the building behind it is forty metres of lit façade.
uniform float overlay_desaturate = 0.55;
uniform float overlay_emission_mult = 0.40;
uniform vec3 overlay_normal_color: source_color = vec3(0.404, 0.463, 0.541);
uniform vec3 overlay_warning_color: source_color = vec3(0.949, 0.694, 0.235);
uniform vec3 overlay_critical_color: source_color = vec3(0.898, 0.325, 0.239);
uniform vec3 overlay_offline_color: source_color = vec3(0.400, 0.070, 0.055);
uniform float overlay_normal_blend = 0.50;
uniform float overlay_data_blend = 0.88;
uniform float overlay_critical_hz = 1.2;
uniform float overlay_offline_hz = 0.35;
uniform float overlay_state_emission = 0.55;
uniform float overlay_pad_emission_floor = 0.30;
const int OVERLAY_MODE_POWER = 1;
const int OVERLAY_MODE_FIRE = 4;
const float OVERLAY_STRIDE = 112.0;
// ═════════ END overlay pass ═══════════════════════════════════════════════

const float PART_PAD = 0.0;
const float PART_CABINET = 1.0;
const float PART_LID = 2.0;
const float PART_FIN = 3.0;
const float PART_BUSHING = 4.0;

// `flat` for the same reason `building.gdshader`'s is: INSTANCE_CUSTOM is
// constant over an instance, but INTERPOLATING it walks the packed integer by
// a fraction of an ulp, and `mod(floor(p / 112.0), 4.0)` on a value that is a
// hair under 112 reads 0 where it should read 1 — the overlay would flicker
// along a triangle edge.
varying flat vec4 v_custom;
varying flat float v_part;
varying vec4 v_color;
varying vec3 v_local;
varying vec3 v_lnormal;

// The two decoders. `overlay_of` is `building.gdshader`'s, character for
// character.
float overlay_of(float packed) {
	return mod(floor(packed / OVERLAY_STRIDE), 4.0);
}

float distress_of(float packed) {
	return mod(packed, OVERLAY_STRIDE);
}

vec4 overlay_paint(float state, out float emit_amt) {
	vec3 tint = overlay_normal_color;
	tint = mix(tint, overlay_warning_color, step(0.5, state));
	tint = mix(tint, overlay_critical_color, step(1.5, state));
	tint = mix(tint, overlay_offline_color, step(2.5, state));
	float is_data = step(0.5, state);
	float hz = mix(overlay_critical_hz, overlay_offline_hz, step(2.5, state));
	float pulse01 = 0.5 + 0.5 * sin(sc_time * 6.283185 * hz);
	float pulse_amt = step(1.5, state) * 0.35 * pulse01;
	float blend = mix(overlay_normal_blend, overlay_data_blend, is_data)
			* (1.0 - pulse_amt);
	emit_amt = overlay_state_emission * is_data * (0.65 + 0.35 * pulse01);
	return vec4(tint, blend);
}

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	v_color = COLOR;
	v_local = VERTEX;
	v_lnormal = NORMAL;
	v_part = floor(COLOR.a * 8.0 + 0.5);
}

void fragment() {
	// ONE fetch, before any branch. Everything below is per-part arithmetic on
	// the result.
	vec3 grain = texture(grain_tex, UV).rgb;
	float page = mix(1.0, dot(grain, vec3(0.3333)) * 2.0, grain_amount);

	float heat = v_custom.r;
	float soot = v_custom.g;
	float packed = v_custom.b;
	float phase = v_custom.a;
	float distress = distress_of(packed);

	vec3 albedo = v_color.rgb * page;
	float rough = base_roughness;
	float metal = base_metallic;
	float ao = 1.0;

	// ── radiator fins ────────────────────────────────────────────────────
	// Grooves run in local Z across the bank's outer face. `w` is 0 at a fin's
	// centre and 1 in the gap between two, so the term is a periodic AO band
	// with a matching roughness break — a cast-iron radiator, not a smooth box.
	float is_fin = step(PART_FIN - 0.5, v_part) * step(v_part, PART_FIN + 0.5);
	float side_face = step(0.5, abs(v_lnormal.x));
	float w = abs(fract(v_local.z / fin_pitch_m) - 0.5) * 2.0;
	float groove = smoothstep(0.55, 1.0, w) * is_fin * side_face;
	ao -= groove * fin_groove;
	rough += groove * 0.18;

	// ── porcelain ────────────────────────────────────────────────────────
	float is_bushing = step(PART_BUSHING - 0.5, v_part) * step(v_part, PART_BUSHING + 0.5);
	rough = mix(rough, 0.22, is_bushing);
	metal = mix(metal, 0.0, is_bushing);

	// ── the door: a centre seam and a warning placard ────────────────────
	// Both are on the CABINET's +Z face only. `PowerInfraModel.yaw_for()` spun
	// that face at the street, so this is the side a player is looking at.
	float is_cabinet = step(PART_CABINET - 0.5, v_part) * step(v_part, PART_CABINET + 0.5);
	float front = step(0.5, v_lnormal.z) * is_cabinet;
	float seam = (1.0 - smoothstep(0.008, 0.026, abs(v_local.x))) * front;
	float placard = front
			* step(placard_rect.x, v_local.x) * step(v_local.x, placard_rect.z)
			* step(placard_rect.y, v_local.y) * step(v_local.y, placard_rect.w);
	// One dark band across the placard's lower third. At the distance a padmount
	// is ever read this IS the text, and it costs a step().
	float legend = placard * step(placard_rect.y + 0.06, v_local.y)
			* step(v_local.y, placard_rect.y + 0.14);
	albedo = mix(albedo, placard_color, placard * 0.92);
	albedo = mix(albedo, seam_color, max(seam, legend) * 0.85);
	rough = mix(rough, 0.80, placard);

	// ── soot ─────────────────────────────────────────────────────────────
	// Climbs from `char_floor_m`, so the concrete apron survives the burn and
	// the cabinet does not.
	float char_mask = smoothstep(char_floor_m, char_top_m, v_local.y);
	float charred = soot * char_mask;
	albedo = mix(albedo, char_color, charred);
	rough = mix(rough, char_roughness, charred);
	metal *= (1.0 - charred * 0.8);

	// ── heat ─────────────────────────────────────────────────────────────
	// The fins carry it, the lid takes a fraction, and the concrete never does.
	// Squared so the NORMAL→WARNING half of the ramp is genuinely faint and the
	// last quarter is what a player's eye catches.
	float flicker = 0.86 + 0.14 * sin(sc_time * 6.283185 * heat_flicker_hz
			+ phase * 6.283185);
	float is_lid = step(PART_LID - 0.5, v_part) * step(v_part, PART_LID + 0.5);
	float heat_mask = is_fin + heat_cabinet_share * is_cabinet
			+ heat_lid_share * is_lid;
	vec3 emission = heat_color * heat * heat * heat_nits * heat_mask * flicker
			* (1.0 - charred);

	// ── weather ──────────────────────────────────────────────────────────
	// Unlike `PropSurface`'s dry props, a padmount stands in the street: it
	// gets as wet as the road it is set beside, and doc 11 §2.9's integrator is
	// already the whole city's answer to how wet that is. Exact identity at
	// sc_wetness = 0.
	albedo *= mix(1.0, 0.84, sc_wetness);
	rough = mix(rough, 0.26, sc_wetness * 0.75);

	ALBEDO = albedo * ao;
	ROUGHNESS = clamp(rough, 0.04, 1.0);
	METALLIC = clamp(metal, 0.0, 1.0);
	SPECULAR = mix(0.5, 0.72, sc_wetness);
	AO = ao;
	AO_LIGHT_AFFECT = 0.85;
	EMISSION = emission;

	// ═════════ BEGIN overlay pass — sc_overlay_mode (doc 12 §2.5) ═════════
	// One uniform branch over the whole draw: at mode 0 nothing below runs and
	// the pad is exactly the pad above.
	if (sc_overlay_mode > 0) {
		float luma = dot(ALBEDO, vec3(0.2126, 0.7152, 0.0722));
		ALBEDO = mix(ALBEDO, vec3(luma), overlay_desaturate);
		EMISSION *= overlay_emission_mult;
		if (sc_overlay_mode >= OVERLAY_MODE_POWER
				&& sc_overlay_mode <= OVERLAY_MODE_FIRE) {
			float state = overlay_of(packed);
			if (sc_overlay_mode == OVERLAY_MODE_POWER) {
				// In POWER mode the pad's own DISTRESS band outranks whatever
				// the channel published, because the pad is the thing the band
				// describes: CLEAN/STRESSED → NORMAL/WARNING, TROUBLED and
				// SEVERE → CRITICAL, DARK and FAILED → OFFLINE. `max` keeps the
				// severity order the channel already uses.
				float own = step(0.5, distress) + step(1.5, distress)
						+ step(3.5, distress);
				state = max(state, min(own, 3.0));
			}
			float emit_amt;
			vec4 paint = overlay_paint(state, emit_amt);
			ALBEDO = mix(ALBEDO, paint.rgb, paint.w);
			// The floor is the difference between "the network is drawn" and
			// "the network is visible": a 1.5 m cabinet under the grey wash
			// disappears into the road without it.
			EMISSION += paint.rgb * (emit_amt + overlay_pad_emission_floor);
		}
	}
	// ═════════ END overlay pass ═══════════════════════════════════════════
}
