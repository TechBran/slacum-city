// STREET LIFE bodies (doc 11 §2.17) — the crook, the dog and the goat, each
// ONE MultiMesh and therefore ONE draw call however many are loose in the city.
//
// WHY THIS EXISTS, and how it differs from `construction_rig.gdshader`. That
// shader walks a strictly NESTED chain, because a boom carries an arm which
// carries a bucket. An animal is the opposite shape: four legs, a neck and a
// tail all hang off ONE barrel and none of them moves any other. So there is no
// cascade here. Every vertex names its joint in `UV2.x`, that joint names its
// own pivot and axis in `rig_pivot[]` and its own INSTANCE_CUSTOM channel in
// `rig_sel[]`, and the vertex stage applies exactly ONE rotation.
//
// The pay-off is in `rig_sel`. It is a channel MASK times a GAIN, so a trot —
// the two diagonal legs swinging together against the other two — is all four
// legs reading channel 0 with the second diagonal at gain −1. Four legs, a neck
// and a tail: six moving parts, THREE animated floats, one draw call.
//
// VERTEX CHANNELS (written by `StreetLifeMesh`):
//   COLOR  = part tint × the MultiMesh instance colour. Coat parts are authored
//            near-white so the instance colour IS the coat; boots, muzzles and
//            the shadow inside a hood are authored dark on `SURF_DARK` and are
//            deliberately NOT repainted, so a pale goat still has black hooves.
//   UV     = surface coordinate in metres / prop_tile_m (the builder's grain).
//            Unused by this shader — these bodies are flat-shaded by choice; see
//            the note on `tex_mix` below.
//   UV2.x  = JOINT, 0..7. Joint 0 never moves.
//   UV2.y  = SURFACE: 0 coat, 1 dark, 2 glint.
//
// INSTANCE_CUSTOM, the same four for every body so the view has one animator:
//   .r LIMB   legs
//   .g HEAD   the crook's furtive yaw, the animals' neck pitch
//   .b EXTRA  the crook's arms, the animals' tails
//   .a FX     0 = standing there, 1 = gone.
// Each is authored 0..1 and mapped through `chan_min` / `chan_range`, so the
// working envelope of a walk cycle is stated once, in GDScript.
//
// INSTANCE COLOR .a is the FX MODE, not a hash: 1 = this body was COLLECTED
// (it lifts off the pavement and flashes), 0 = it EXPIRED (it just sinks and
// goes). One float, and it is the difference between "you got it" and "you
// missed it" without a second buffer or a second shader.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// ---- the rig -------------------------------------------------------------
// xyz = the joint's rest pivot in body space; w = axis (0 pitch +Z, 1 yaw +Y,
// 2 roll +X).
uniform vec4 rig_pivot[8];
// The INSTANCE_CUSTOM channel mask for this joint, times its gain. All zeros
// (joint 0, and every unused slot) means "never moves".
uniform vec4 rig_sel[8];
uniform vec4 chan_min = vec4(0.0);
uniform vec4 chan_range = vec4(0.0);

// ---- the leaving animation ----------------------------------------------
// Metres a COLLECTED body lifts as it goes. An EXPIRED one takes none of it and
// sinks into its own feet instead, which is the read: nothing was earned.
uniform float fx_lift_m = 0.55;
uniform vec3 fx_flash_color : source_color = vec3(0.72, 0.86, 1.0);
uniform float fx_flash_energy = 2.6;

// ---- surface -------------------------------------------------------------
uniform float body_roughness = 0.82;
uniform float body_specular = 0.42;
uniform float dark_roughness = 0.55;
uniform vec3 glint_color : source_color = vec3(0.95, 0.93, 0.80);
// Glint parts (eyes, the swag clasp) are the only thing on these bodies that
// carries an emission, and only after dark — a crook's eyes under a hood at
// 02:00 is the read; the same glow at noon is a bug.
uniform float glint_energy = 1.5;
uniform float night_amt = 0.0;
// Rim term. A 1.8 m body at Z1 is thirty screen pixels against a pavement of
// almost exactly its own value, and a flat-shaded silhouette that size simply
// disappears. This lifts the grazing edge so the shape keeps an outline against
// the ground it stands on. It is doing the job an outline pass would do, for
// one dot product.
uniform vec3 rim_color : source_color = vec3(1.0, 0.97, 0.90);
uniform float rim_gain = 0.34;
uniform float rim_power = 3.2;

varying flat float v_surf;
varying flat float v_fx;
varying flat float v_flash;


mat3 rot_x(float a) {
	float s = sin(a);
	float c = cos(a);
	return mat3(vec3(1.0, 0.0, 0.0), vec3(0.0, c, s), vec3(0.0, -s, c));
}


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
	vec4 ang = chan_min + clamp(INSTANCE_CUSTOM, vec4(0.0), vec4(1.0)) * chan_range;
	float fx = clamp(ang.a, 0.0, 1.0);
	float flash = clamp(COLOR.a, 0.0, 1.0);
	v_fx = fx;
	v_flash = flash;

	// CLAMPED, not trusted. `tests/test_street_life.gd` asserts no shipped body
	// carries a joint past the array, but an out-of-range index into a uniform
	// array is undefined behaviour rather than an error — it is a driver-
	// dependent garbage read, and the shape of bug that reproduces on one phone.
	int j = clamp(int(UV2.x + 0.5), 0, 7);
	vec4 pivot = rig_pivot[j];
	// One dot product instead of a dynamic index into a vec4 — the mask carries
	// the gain, so a mirrored limb is the same expression with a sign.
	float a = dot(ang, rig_sel[j]);
	mat3 r = pivot.w < 0.5 ? rot_z(a) : (pivot.w < 1.5 ? rot_y(a) : rot_x(a));
	vec3 p = r * (VERTEX - pivot.xyz) + pivot.xyz;
	vec3 n = r * NORMAL;

	// Leaving. Shrinking about the body's OWN ORIGIN — which is on the ground
	// between its feet — is what makes a collect read as a pop upward and an
	// expiry read as sinking into the pavement, from one scalar.
	float shrink = 1.0 - smoothstep(0.05, 1.0, fx);
	p *= shrink;
	p.y += fx * fx_lift_m * flash;
	VERTEX = p;
	NORMAL = normalize(n);
}


void fragment() {
	float is_dark = step(0.5, v_surf) * (1.0 - step(1.5, v_surf));
	float is_glint = step(1.5, v_surf);
	// COLOR is already the part tint TIMES the instance coat. Coat parts are
	// authored near-white so the coat is the colour; boots, muzzles and the
	// shadow inside a hood are authored dark enough that no coat ever lights
	// them up, which is the same bargain the plant shader strikes with steel.
	vec3 albedo = COLOR.rgb;
	vec3 emission = vec3(0.0);

	// The grazing-edge lift. Cheap, and the whole reason a body this small is
	// legible against a pavement of its own value.
	float facing = 1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	albedo += rim_color * rim_gain * pow(facing, rim_power) * (1.0 - is_glint);

	albedo = mix(albedo, glint_color, is_glint);
	emission += glint_color * glint_energy * is_glint * night_amt;

	// The collect flash: white-hot for the fraction of a second the body is
	// leaving, and only when something was actually earned.
	float flash = v_flash * smoothstep(0.0, 0.35, v_fx) * (1.0 - v_fx * 0.55);
	emission += fx_flash_color * fx_flash_energy * flash;

	ALBEDO = albedo;
	EMISSION = emission;
	ROUGHNESS = mix(body_roughness, dark_roughness, is_dark);
	SPECULAR = body_specular;
	METALLIC = 0.0;
}
