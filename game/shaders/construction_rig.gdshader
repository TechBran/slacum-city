// Articulated construction plant (doc 11 §2.16) — the excavator and the rigid
// tipper, each ONE MultiMesh and therefore ONE draw call however many of them
// are working the city.
//
// WHY THIS EXISTS. A machine that reads as a machine has to move at its
// JOINTS: a boom that lifts, an arm that reaches, a bucket that curls, a bed
// that tips. The obvious ways to get that are a Skeleton3D per machine (a Node
// per bone, per machine — unaffordable at twenty sites) or one MultiMesh per
// part (five draw calls for one excavator). This shader takes the third road:
// the mesh carries its JOINT INDEX per vertex, the chain's rest pivots are
// uniforms, and the per-instance joint ANGLES ride INSTANCE_CUSTOM. The vertex
// stage walks the chain. Twenty excavators and twenty tippers cost two draw
// calls and eight floats each.
//
// VERTEX CHANNELS (written by `ConstructionRigMesh`):
//   COLOR    = part tint x MultiMesh instance colour. RGB is the machine's
//              paint (painted panels are authored white, steel and rubber
//              dark). **A is the per-machine hash 0..1** — the beacon's phase
//              and the paint's tone jitter, so no two machines on one street
//              flash together or wear exactly the same yellow.
//   UV       = surface coordinate in METRES / prop_tile_m, the same physical
//              grain the hoarding, the crane and the lamp posts carry.
//   UV2.x    = JOINT, 0..4. 0 never moves; joint j is rotated by its own angle
//              and by every angle below it.
//   UV2.y    = SURFACE code: 0 steel, 1 stock (material, not machine),
//              2 glass, 3 amber beacon, 4 head/tail lamp.
//
// INSTANCE_CUSTOM, per `rig_mode`:
//   0 (excavator) = (slew, boom, arm, bucket), each 0..1 across `joint_min` ..
//                   `joint_min + joint_range`.
//   1 (tipper)    = (bed tilt 0..1, load fill 0..1, lamp intensity 0..1, 0).
//
// The joint cascade is FORWARD KINEMATICS with rest pivots: rotating about the
// REST pivot of joint j and then applying joint j-1's rotation to the result is
// exactly `M1 * M2 * M3 * M4 * p`, which is why the pivots never have to be
// re-derived per frame and why the CPU side writes nothing but four floats.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// ---- the chain -----------------------------------------------------------
// 1 = the joint yaws about +Y, 0 = it pitches about +Z. Joint order 1..4.
uniform vec4 joint_axis = vec4(1.0, 0.0, 0.0, 0.0);
uniform vec4 joint_min = vec4(0.0);
uniform vec4 joint_range = vec4(0.0);
uniform vec3 pivot_1 = vec3(0.0);
uniform vec3 pivot_2 = vec3(0.0);
uniform vec3 pivot_3 = vec3(0.0);
uniform vec3 pivot_4 = vec3(0.0);
// 0 = excavator (four live joints), 1 = tipper (one, plus a load carrier).
uniform float rig_mode = 0.0;
// Joint index whose vertices are squashed towards `load_floor_y` by the fill,
// or a negative number for a rig that carries nothing. The load is authored
// FULL, so an empty bed costs the same triangles lying flat on its floor.
uniform float load_joint = -1.0;
uniform float load_floor_y = 0.0;

// ---- surface -------------------------------------------------------------
// `tools/gen_textures.py`'s prop pages. BOTH are sampled unconditionally and
// selected by code — a fetch inside divergent control flow is a mobile-driver
// hazard and this layer has none. Set `tex_mix = 0` and the flat-shaded layer
// comes back exactly, which is what a clone with no generated pages gets.
uniform sampler2D steel_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D stock_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float tex_mix = 1.0;
uniform float body_roughness = 0.58;
// Painted plant is PAINT, not bare metal. The first pass ran 0.22 here and the
// liveries came out washed: metallic kills diffuse, so a mid-green machine in
// full sun read as pale sea-green next to a crane that was frankly yellow.
// 0.08 keeps the sky glint along a boom chord and gives the paint back.
uniform float body_metallic = 0.08;
// Material rather than machine: the tipper's load takes THIS, not the paint.
// It rides a uniform because the instance colour has already multiplied into
// COLOR by the time the fragment stage sees it, and a load of gravel that is
// the colour of the lorry is not a load of gravel.
uniform vec3 stock_color : source_color = vec3(0.52, 0.51, 0.49);
uniform float body_specular = 0.50;
uniform float glass_roughness = 0.20;
uniform float glass_specular = 0.72;
uniform vec3 beacon_color : source_color = vec3(1.0, 0.62, 0.10);
uniform vec3 lamp_color : source_color = vec3(1.0, 0.94, 0.78);
uniform float beacon_energy = 3.2;
uniform float beacon_hz = 1.35;
uniform float lamp_energy = 2.2;
// Per-machine tone skew off COLOR.a. Small on purpose: a fleet of the same
// yellow, not a rainbow.
uniform float paint_tone_gain = 0.10;
uniform float paint_hue_gain = 0.03;
uniform float anim_time = 0.0;
uniform float night_amt = 0.0;

varying flat float v_surf;
varying flat float v_lamp;


mat3 rot_y(float a) {
	float s = sin(a);
	float c = cos(a);
	return mat3(vec3(c, 0.0, -s), vec3(0.0, 1.0, 0.0), vec3(s, 0.0, c));
}


mat3 rot_z(float a) {
	float s = sin(a);
	float c = cos(a);
	return mat3(vec3(c, s, 0.0), vec3(-s, c, 0.0), vec3(0.0, 0.0, 1.0));
}


void vertex() {
	v_surf = UV2.y;
	vec4 custom = INSTANCE_CUSTOM;
	float tipper = step(0.5, rig_mode);
	// The tipper spends its second and third channels on the load and the
	// lamps, so only its first channel is an angle.
	vec4 norm = mix(custom, vec4(custom.r, 0.0, 0.0, 0.0), tipper);
	vec4 ang = joint_min + clamp(norm, vec4(0.0), vec4(1.0)) * joint_range;
	v_lamp = custom.b * tipper;

	float j = UV2.x;
	vec3 p = VERTEX;
	vec3 n = NORMAL;
	// The load carrier: squash towards the bed floor, THEN let the chain tip it.
	if (load_joint >= 0.0 && abs(j - load_joint) < 0.5) {
		p.y = load_floor_y + (p.y - load_floor_y) * clamp(custom.g, 0.0, 1.0);
	}
	if (j > 3.5) {
		mat3 r = joint_axis.a > 0.5 ? rot_y(ang.a) : rot_z(ang.a);
		p = r * (p - pivot_4) + pivot_4;
		n = r * n;
	}
	if (j > 2.5) {
		mat3 r = joint_axis.b > 0.5 ? rot_y(ang.b) : rot_z(ang.b);
		p = r * (p - pivot_3) + pivot_3;
		n = r * n;
	}
	if (j > 1.5) {
		mat3 r = joint_axis.g > 0.5 ? rot_y(ang.g) : rot_z(ang.g);
		p = r * (p - pivot_2) + pivot_2;
		n = r * n;
	}
	if (j > 0.5) {
		mat3 r = joint_axis.r > 0.5 ? rot_y(ang.r) : rot_z(ang.r);
		p = r * (p - pivot_1) + pivot_1;
		n = r * n;
	}
	VERTEX = p;
	NORMAL = normalize(n);
}


void fragment() {
	// Two fetches, both unconditional, then choose. Machine on the steel page,
	// material on the stock page — one physical grain across the whole site.
	vec4 steel = texture(steel_tex, UV);
	vec4 stock = texture(stock_tex, UV);
	float is_stock = step(0.5, v_surf) * (1.0 - step(1.5, v_surf));
	float is_glass = step(1.5, v_surf) * (1.0 - step(2.5, v_surf));
	float is_beacon = step(2.5, v_surf) * (1.0 - step(3.5, v_surf));
	float is_lamp = step(3.5, v_surf);
	vec4 page = mix(vec4(1.0, 1.0, 1.0, 0.0), mix(steel, stock, is_stock), tex_mix);
	float shine = page.a;

	// Per-machine paint skew, off the instance hash in COLOR.a.
	float jitter = clamp(COLOR.a, 0.0, 1.0) - 0.5;
	vec3 tone = vec3(1.0 + jitter * (paint_tone_gain + paint_hue_gain),
			1.0 + jitter * paint_tone_gain,
			1.0 + jitter * (paint_tone_gain - paint_hue_gain));
	vec3 albedo = COLOR.rgb * page.rgb * mix(vec3(1.0), tone, tex_mix);
	vec3 emission = vec3(0.0);

	// Material, not machine: the load in the bed is aggregate whatever colour
	// the lorry is painted.
	albedo = mix(albedo, page.rgb * stock_color, is_stock);
	// Glass: the page is a baked sky gradient, so it takes only a bleed of the
	// paint or every cab would be the colour of the machine.
	albedo = mix(albedo, page.rgb * mix(vec3(1.0), COLOR.rgb, 0.22), is_glass);

	// Amber beacon: a slow rotating-mirror sweep, awake day and night — a work
	// site announces itself in daylight too.
	float sweep = fract(anim_time * beacon_hz + clamp(COLOR.a, 0.0, 1.0));
	float flash = smoothstep(0.72, 1.0, 1.0 - abs(sweep - 0.5) * 2.0);
	albedo = mix(albedo, beacon_color * mix(0.30, 1.0, flash), is_beacon);
	emission += beacon_color * beacon_energy * flash * is_beacon
			* mix(0.55, 1.0, night_amt);

	// Head/tail lamps: glassy off, hot once the driver switches them on.
	float lamps = clamp(v_lamp, 0.0, 1.0);
	albedo = mix(albedo, mix(vec3(0.70, 0.72, 0.74), lamp_color, lamps), is_lamp);
	emission += lamp_color * lamp_energy * lamps * is_lamp;

	ALBEDO = albedo;
	EMISSION = emission;
	// shine = 0 (no pages) restores the flat pair the untextured layer ships
	// with, and SPECULAR is Godot's own 0.5 default at that point.
	// Aggregate is the roughest thing on a site and never takes the page's
	// shine mask; glass is the only surface here with any gloss at all.
	ROUGHNESS = mix(mix(mix(body_roughness, glass_roughness, is_glass),
			glass_roughness, shine * (1.0 - is_stock)), 0.98, is_stock);
	SPECULAR = mix(0.5, mix(body_specular, glass_specular, max(is_glass, shine)), tex_mix);
	METALLIC = body_metallic * (1.0 - is_glass) * (1.0 - is_stock)
			* (1.0 - is_beacon) * (1.0 - is_lamp);
}
