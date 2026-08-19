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
//   UV2             = the surface atlas cell + the face's own [0,1] coordinate
//                     (see the texture pass below).
//   INSTANCE_CUSTOM = (per-vehicle hash 0..1, lamp intensity 0..1, lightbar
//                      phase or -1, fade 0..1).
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

// ═════════ BEGIN texture pass — tools/gen_textures.py vehicle_atlas ═════════
// Self-contained: set tex_mix = 0.0 and the untextured layer comes back byte
// for byte (`mix(vec4(1,1,1,0), tex, 0.0)` is exactly white with no shine, and
// `is_glass` is multiplied by tex_mix too).
//
// The atlas is 2x2 MATERIAL cells — (0,0) paint, (1,0) glass, (0,1) dark /
// rubber, (1,1) department livery. `VehicleMesh` writes UV2 = cell + the face's
// own inset [0,1] coordinate, so a cell is never tiled and `floor(UV2)` IS the
// cell index. That is the one thing the shader needs to know which surface it
// is standing on, and it costs no extra interpolator and no extra fetch.
//
// RGB is authored near-white on the paint, dark and livery cells because COLOR
// is still the colour: the page carries metallic fleck, tread ribs, battenburg
// blocks and the emblem roundel as VALUE. Glass is the exception and is
// authored as the real thing — a baked sky-to-cabin reflection gradient — so it
// takes only `glass_paint_bleed` of the body paint, or every fire engine would
// have red windows.
//
// A = the shine mask, same contract as the façade pages: it drives ROUGHNESS
// and SPECULAR, which is what separates wet-looking glass from matte rubber
// inside one draw call.
uniform sampler2D body_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float tex_mix = 1.0;
uniform vec2 atlas_cells = vec2(2.0, 2.0);
// Glass is glossy, not mirrored: at 0.10/0.90 the raked windscreen picked up a
// full sun specular from the city camera's own pitch band and read as a silver
// wedge on every car at once.
uniform float glass_roughness = 0.22;
uniform float glass_specular = 0.70;
uniform float body_specular = 0.50;
uniform float glass_paint_bleed = 0.25;
// Per-vehicle tone, off INSTANCE_CUSTOM.r. Two cars sharing a paint entry are
// still not the same car: one is a shade lighter and a hair warmer. Small on
// purpose — this is a fleet of the same ten paints, not a rainbow.
uniform float paint_tone_gain = 0.09;
uniform float paint_hue_gain = 0.035;
// ═════════ END texture pass ═══════════════════════════════════════════════

varying vec4 v_data;
varying float v_role;
varying vec2 v_uv2;

void vertex() {
	v_data = INSTANCE_CUSTOM;
	v_role = UV.y;
	v_uv2 = UV2;
}

void fragment() {
	// ═════════ BEGIN texture pass — surface sample ════════════════════════
	// One fetch for the whole layer. `floor` is safe because VehicleMesh insets
	// every face inside its cell, so an interpolated UV2 never reaches the
	// boundary and the cell index is constant across a face.
	vec4 surf = mix(vec4(1.0, 1.0, 1.0, 0.0),
			texture(body_tex, v_uv2 / atlas_cells), tex_mix);
	vec2 cell = floor(v_uv2);
	float is_glass = step(0.5, cell.x) * (1.0 - step(0.5, cell.y)) * tex_mix;
	float shine = surf.a;
	// Per-vehicle tone/hue skew — the "no two cars the same" term.
	float jitter = clamp(v_data.r, 0.0, 1.0) - 0.5;
	vec3 tone = vec3(1.0 + jitter * (paint_tone_gain + paint_hue_gain),
			1.0 + jitter * paint_tone_gain,
			1.0 + jitter * (paint_tone_gain - paint_hue_gain));
	vec3 painted = COLOR.rgb * surf.rgb * mix(vec3(1.0), tone, tex_mix);
	// Glass takes the page and only a bleed of the paint.
	vec3 glazed = surf.rgb * mix(vec3(1.0), COLOR.rgb, glass_paint_bleed);
	vec3 albedo = mix(painted, glazed, is_glass);
	// ═════════ END texture pass ═══════════════════════════════════════════
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
	// texture pass: shine = 0 restores the flat 0.52 / 0.08 pair the untextured
	// layer shipped with, and SPECULAR is Godot's own 0.5 default at that point.
	ROUGHNESS = mix(body_roughness, glass_roughness, shine);
	SPECULAR = mix(0.5, mix(body_specular, glass_specular, shine), tex_mix);
	METALLIC = body_metallic * (1.0 - is_glass);
}
