// THE BUILDING CONTACT SHADOW (doc 11 §2.11's `MM_blob`) — one dark decal per
// building, on the tier where the sun casts none.
//
// WHY IT EXISTS. `presets.performance.shadows` is `false`: no directional
// shadow, no splits, no atlas. Without a replacement every block in the city
// FLOATS — the same failure report 98 RR-90 photographed one scale down, where
// `vehicle_shadows` had taken a crook's contact shadow away and left him
// printed on the pavement. §2.11 has carried the answer since the preset table
// was written (`data/render.json`'s `blob_shadow.enabled_presets`) and nothing
// drew it. This is that layer.
//
// WHY IT IS NOT A MODE ON `street_fx.gdshader`, which is the other place a blob
// shadow lives. Three reasons, in the order they decide it:
//
//   1. **The buffer is the wrong shape.** The fx buffer is rewritten EVERY
//      FRAME from `StreetLifeModel.refresh` — it is a pool of at most
//      `max_live * 3` rows describing objects that are walking. A building
//      decal is STATIC: it moves when a building is built, upgraded or
//      demolished and at no other time. Putting ~1,500 static rows through a
//      per-frame pool would pay the whole city's transform arithmetic on every
//      frame to write the same numbers back.
//   2. **The fill cost is not comparable.** That shader is one 0.7 m disc under
//      a person; this is a 16 m footprint under a tower, and it runs on the
//      LOWEST tier, at `render_scale` 0.70, on a fragment-bound phone. Its one
//      unconditional `texture(glyph_page, …)` fetch — correct there, where five
//      of six modes want the page — would be paid by every fragment of every
//      building decal in the frame for nothing. There is no fetch here at all.
//   3. **The two layers have two different GATES and always did.** `blob_shadow`
//      is one block with two consumers: `enabled_presets` is this decal's,
//      `body_alpha` / `body_m` / `body_lift_m` belong to §2.17's bodies, whose
//      on/off is the preset's `vehicle_shadows` INVERTED. Sharing a shader
//      would not merge the gates; it would only make the split harder to read.
//
// So: ONE dedicated `MultiMeshInstance3D` for the whole city — not one per
// NEAR/MEDIUM chunk, which is what §2.11 priced and which measured 36 draw
// calls at Z0 on the bench city (report 98 RR-96) — under RR-83's rule
// (`node.visible = n > 0`), stride 12: no instance colour, no custom data,
// because every value below is either a uniform or the `sc_night` global.
//
// THE FALLOFF IS A BOX, NOT A DISC, and that is the one art decision in the
// file. §2.11 says "radial-gradient quad", and a radial gradient under a
// RECTANGULAR footprint leaves the four corners of the building unshaded and
// puts penumbra where the wall is — a tower standing in a circle of grey. The
// mask is therefore the CHEBYSHEV distance `max(|u|,|v|)`, which is solid over
// a rectangle and ramps outward from its edge. `blob_core` is authored as
// `1 / footprint_scale`, so the solid region is EXACTLY the footprint and the
// ramp is EXACTLY the 15 % margin the quad was scaled up by: the penumbra is
// the overhang and nothing else has to be tuned.
//
// The building itself is opaque and writes depth, so the part of the decal
// under the footprint is depth-tested away and what a player actually sees is
// the ramp — which is what a contact shadow IS.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled,
		shadows_disabled;

global uniform float sc_night;

// BLACK, for the reason report 98 RR-90 had to photograph twice: a `blend_mix`
// pass mixes the ground TOWARDS this colour rather than multiplying by it, so
// only black turns the blend into a multiply — the ground keeps `(1 − a)` of
// whatever it was, and one decal darkens a pale lot and a dark one by the same
// FRACTION. A sky-grey shadow is lighter than the surface it is cast on.
uniform vec3 blob_color : source_color = vec3(0.0, 0.0, 0.0);
// §2.11's authored `alpha`, 0.35. Different from §2.17's `body_alpha` on
// purpose and the block says why: 0.35 under a 12 m mass that blocks the sky is
// a shadow; 0.35 under a 0.7 m disc on a shaded carriageway was nothing.
uniform float blob_alpha = 0.35;
// §2.11's `alpha · (1 − sc_night · 0.6)`. A contact shadow needs a sun; by
// 03:00 the only light on the lot is a lamp thirty metres away, and a decal
// that stayed at full strength would read as a stain.
uniform float night_fade = 0.6;
// `1 / footprint_scale` — see the header. Solid inside, ramp outside.
uniform float blob_core = 0.87;


void fragment() {
	// The quad's own 0..1 frame, remapped to 0 at the centre and 1 at the edge.
	vec2 q = abs(UV - vec2(0.5)) * 2.0;
	float d = max(q.x, q.y);
	ALBEDO = blob_color;
	ALPHA = (1.0 - smoothstep(blob_core, 1.0, d)) * blob_alpha
			* (1.0 - clamp(sc_night, 0.0, 1.0) * night_fade);
}
