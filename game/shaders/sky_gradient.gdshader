shader_type sky;
// THE SKY — doc 11 §2.8 (Wave 17). A clean gradient and nothing else: zenith to
// horizon in one power curve, a haze band at the horizon in the FOG tint so the
// far city seats into it, and the ground hemisphere below the horizon on that
// same tint. No sun disc, no scattering, no clouds. The flagship read is the
// skyline against a clean gradient, and the Fold is fragment-bound (doc 11
// §2.13): every term here is one mix or one pow per sky pixel, and the sky is
// only the pixels the city does not cover — which, until the manual pitch axis
// (doc 12 §2.23) let the horizon into the frame, was none of them.
//
// Colours arrive as `source_color`, i.e. authored sRGB from data/render.json's
// day/night keys, linearised on upload — the convention the ProceduralSkyMaterial
// this replaces used for the same keys.
//
// `render_mode` deliberately requests NO half- or quarter-res pass: those exist
// for expensive scattering and cost a second draw, and this shader is cheaper
// than the resolve would be.

uniform vec3 zenith_color : source_color = vec3(0.29, 0.47, 0.72);
uniform vec3 horizon_color : source_color = vec3(0.62, 0.75, 0.86);
uniform vec3 haze_color : source_color = vec3(0.56, 0.64, 0.72);
uniform vec3 ground_color : source_color = vec3(0.30, 0.32, 0.36);
// How fast the zenith takes over above the horizon: t = elevation^curve.
// Below 1 the horizon colour reaches high; 0.55 keeps a broad warm band at dawn.
uniform float zenith_curve : hint_range(0.1, 2.0) = 0.55;
// sin(elevation) over which the haze band fades into the open sky. 0.08 is
// about 4.6° — the band the far city's fogged roofs are silhouetted against.
uniform float haze_height : hint_range(0.0, 0.5) = 0.08;
// How much of the horizon line is haze rather than the authored horizon tint.
uniform float haze_strength : hint_range(0.0, 1.0) = 0.8;
// sin(depression) over which the ground hemisphere falls from the haze to
// `ground_color`. Large, so the sliver a grazing camera sees is haze-coloured.
uniform float ground_falloff : hint_range(0.01, 1.0) = 0.35;
// Lightning's sky pop (doc 11 §2.9) rides this, like the old energy_multiplier.
uniform float energy : hint_range(0.0, 16.0) = 1.0;

void sky() {
	float y = EYEDIR.y;
	vec3 col;
	if (y >= 0.0) {
		float t = pow(y, zenith_curve);
		col = mix(horizon_color, zenith_color, t);
		float haze = 1.0 - smoothstep(0.0, haze_height, y);
		col = mix(col, haze_color, haze * haze_strength);
	} else {
		float g = smoothstep(0.0, ground_falloff, -y);
		col = mix(haze_color, ground_color, g);
	}
	COLOR = col * energy;
}
