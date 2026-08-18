@tool
extends SceneTree
class_name GrayboxGenerator
## Procedural gray-box mesh generator (doc 11 §2.14, §3.2, §3.3).
##
##   ~/.local/bin/godot --headless --path "<repo>" -s res://tools/gen_graybox.gd
##   ... -s res://tools/gen_graybox.gd -- --force     # regenerate even if up to date
##
## Reads data/building_shapes.json (massing) + data/render.json §8 `lod`
## (tri budgets, LOD1 keep fraction, tall-archetype list) and writes
## game/meshes/generated/<archetype>_L<level>_lod<n>.res + manifest.json.
##
## Deterministic by construction: no RNG, no wall clock, no dictionary-order
## dependence. Re-running with unchanged input reproduces every mesh hash in
## the manifest (tests/test_graybox_gen.gd asserts it).
##
## Every geometry constant lives in the two data files; this script holds
## rules, not numbers (constitution §2, §12).

const SHAPES_PATH := "res://data/building_shapes.json"
const RENDER_PATH := "res://data/render.json"
const OUT_DIR := "res://game/meshes/generated"
const MANIFEST_NAME := "manifest.json"
const FAR_MESH_NAME := "far_unit_box"

# Godot renders triangles with CLOCKWISE winding as front faces.
const WINDING_CLOCKWISE := true


# --------------------------------------------------------------- entry point

func _initialize() -> void:
	var force := false
	for arg in OS.get_cmdline_user_args():
		if arg == "--force":
			force = true
	var result := generate(SHAPES_PATH, RENDER_PATH, OUT_DIR, force)
	for line in result.get("log", []) as Array:
		print(line)
	if result.get("errors", []).is_empty():
		print("gen_graybox: OK  meshes=%d tris_lod0_max=%d tris_lod1_max=%d"
				% [result.get("mesh_count", 0), result.get("max_lod0", 0), result.get("max_lod1", 0)])
		quit(0)
	else:
		for e in result["errors"]:
			printerr("gen_graybox: " + str(e))
		quit(1)


# ------------------------------------------------------------------ public API

static func load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


static func file_sha1(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA1)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


## Full run. Returns {log, errors, entries, mesh_count, max_lod0, max_lod1, skipped}.
static func generate(shapes_path: String, render_path: String, out_dir: String,
		force: bool = false) -> Dictionary:
	var out := {"log": [], "errors": [], "entries": [], "mesh_count": 0,
			"max_lod0": 0, "max_lod1": 0, "skipped": false}
	var shapes := load_json(shapes_path)
	var render := load_json(render_path)
	if shapes.is_empty():
		out["errors"].append("cannot read " + shapes_path)
		return out
	if render.is_empty():
		out["errors"].append("cannot read " + render_path)
		return out

	var src_hash := file_sha1(shapes_path)
	var gen_version := int(shapes.get("generator_version", 1))
	var manifest_path := out_dir + "/" + MANIFEST_NAME
	if not force and FileAccess.file_exists(manifest_path):
		var old := load_json(manifest_path)
		if String(old.get("generated_from_hash", "")) == src_hash \
				and int(old.get("generator_version", -1)) == gen_version:
			out["skipped"] = true
			out["log"].append("gen_graybox: up to date (hash %s, version %d)"
					% [src_hash.substr(0, 12), gen_version])
			out["entries"] = old.get("meshes", [])
			out["mesh_count"] = out["entries"].size()
			return out

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))

	var built := build_all(shapes, render)
	out["errors"].append_array(built["errors"])
	if not built["errors"].is_empty():
		return out

	var entries: Array = []
	for item in built["meshes"]:
		var mesh: ArrayMesh = item["mesh"]
		var path: String = out_dir + "/" + String(item["name"]) + ".res"
		var err := ResourceSaver.save(mesh, path)
		if err != OK:
			out["errors"].append("save failed (%d): %s" % [err, path])
			continue
		var entry: Dictionary = item["meta"].duplicate()
		entry["path"] = path
		entries.append(entry)
		out["max_lod0"] = maxi(out["max_lod0"], int(entry["tris"]) if int(entry["lod"]) == 0 else 0)
		out["max_lod1"] = maxi(out["max_lod1"], int(entry["tris"]) if int(entry["lod"]) == 1 else 0)

	var manifest := {
		"generated_from_hash": src_hash,
		"generator_version": gen_version,
		"generator": "tools/gen_graybox.gd",
		"source": shapes_path,
		"archetype_count": (shapes.get("archetypes", []) as Array).size(),
		"meshes": entries,
	}
	var mf := FileAccess.open(manifest_path, FileAccess.WRITE)
	if mf == null:
		out["errors"].append("cannot write " + manifest_path)
		return out
	mf.store_string(JSON.stringify(manifest, " ", true) + "\n")
	mf.close()

	out["entries"] = entries
	out["mesh_count"] = entries.size()
	out["log"].append("gen_graybox: wrote %d meshes + manifest to %s" % [entries.size(), out_dir])
	return out


## Builds every mesh in memory (no disk writes). Returns
## {meshes: [{name, mesh, meta}], errors: [String]}.
static func build_all(shapes: Dictionary, render: Dictionary) -> Dictionary:
	var lod_cfg: Dictionary = render.get("lod", {})
	var budget0 := int(lod_cfg.get("tri_budget_lod0", 320))
	var budget0_tall := int(lod_cfg.get("tri_budget_lod0_tall", 420))
	var budget1 := int(lod_cfg.get("tri_budget_lod1", 96))
	var ratio_max := float(lod_cfg.get("lod1_ratio_max", 0.40))
	var tall: Array = lod_cfg.get("tall_archetypes", [])

	var meshes: Array = []
	var errors: Array = []

	for arch_v in shapes.get("archetypes", []) as Array:
		var arch: Dictionary = arch_v
		var is_tall := tall.has(String(arch.get("doc11_id", ""))) or tall.has(String(arch.get("id", "")))
		var b0 := budget0_tall if is_tall else budget0
		for level_v in arch.get("levels", []) as Array:
			var level: Dictionary = level_v
			for lod in [0, 1]:
				var built := build_level_mesh(shapes, arch, level, lod, lod_cfg)
				var meta: Dictionary = built["meta"]
				var tris := int(meta["tris"])
				var name := "%s_L%d_lod%d" % [String(arch["id"]), int(level["level"]), lod]
				if lod == 0 and tris > b0:
					errors.append("%s: LOD0 %d tris > budget %d" % [name, tris, b0])
				if lod == 1:
					if tris > budget1:
						errors.append("%s: LOD1 %d tris > budget %d" % [name, tris, budget1])
					var prev: Dictionary = meshes[meshes.size() - 1]
					var t0 := int((prev["meta"] as Dictionary)["tris"])
					if float(tris) > ratio_max * float(t0):
						errors.append("%s: LOD1 %d tris > %.2f x LOD0 %d"
								% [name, tris, ratio_max, t0])
				var mesh: ArrayMesh = built["mesh"]
				# Deterministic sub-resource id: Godot otherwise derives it from the
				# save path, which would make "byte-identical across generations"
				# (§7.1 test 1) depend on where the file happens to be written.
				mesh.resource_name = name
				mesh.resource_scene_unique_id = name
				meshes.append({"name": name, "mesh": mesh, "meta": meta})

	var far := build_far_box(shapes)
	var far_mesh: ArrayMesh = far["mesh"]
	far_mesh.resource_name = FAR_MESH_NAME
	far_mesh.resource_scene_unique_id = FAR_MESH_NAME
	meshes.append({"name": FAR_MESH_NAME, "mesh": far_mesh, "meta": far["meta"]})
	if int(far["meta"]["tris"]) != int((shapes.get("far_mesh", {}) as Dictionary).get("tris", 12)):
		errors.append("far_unit_box: %d tris, expected %s"
				% [int(far["meta"]["tris"]), str((shapes.get("far_mesh", {}) as Dictionary).get("tris", 12))])
	return {"meshes": meshes, "errors": errors}


# ------------------------------------------------------------ level assembly

## Resolves the authored blocks + roof props + cumulative level markers for one
## (archetype, level, lod) and emits the ArrayMesh plus its manifest metadata.
static func build_level_mesh(shapes: Dictionary, arch: Dictionary, level: Dictionary,
		lod: int, lod_cfg: Dictionary = {}) -> Dictionary:
	var floor_h := float(shapes.get("floor_height_m", 3.5))
	var tile_m := float(shapes.get("tile_m", 8.0))
	var spacing := float(shapes.get("window_spacing_x_m", 3.2))
	var ao_cfg: Dictionary = shapes.get("ao", {})
	var lod1_cfg: Dictionary = shapes.get("lod1", {})

	var blocks: Array = []
	for b in level.get("blocks", []) as Array:
		blocks.append(b)
	var props: Array = []
	for p in level.get("roof_props", []) as Array:
		props.append(p)
	props.append_array(marker_props(shapes, blocks, int(level["level"])))

	var lod1_volume_keep := float(lod_cfg.get("lod1_volume_keep_frac", 0.15))
	var ao_band := true
	if lod == 1:
		ao_band = bool(lod1_cfg.get("ao_band_split", false))
		var kept := _lod1_blocks(blocks, lod1_volume_keep, floor_h, tile_m)
		var sig: Array = []
		for p in props:
			if bool((p as Dictionary).get("lod1", false)):
				sig.append(p)
		if sig.is_empty() and not props.is_empty() and bool(lod1_cfg.get("merged_prop_box", true)):
			sig = [_merged_prop_box(props, tile_m)]
		blocks = kept
		props = sig

	var mb := MeshBuf.new()
	var rects := _block_rects(blocks, floor_h, tile_m)
	var fx := float((level["footprint_tiles"] as Array)[0])
	var fz := float((level["footprint_tiles"] as Array)[1])
	var ox := -fx * tile_m * 0.5
	var oz := -fz * tile_m * 0.5

	for bi in blocks.size():
		var b: Dictionary = blocks[bi]
		var y0 := _block_y0(b, floor_h)
		var y1 := _block_y1(b, floor_h)
		var x0 := ox + float((b["pos_t"] as Array)[0]) * tile_m
		var z0 := oz + float((b["pos_t"] as Array)[1]) * tile_m
		var x1 := x0 + float((b["size_t"] as Array)[0]) * tile_m
		var z1 := z0 + float((b["size_t"] as Array)[1]) * tile_m
		_emit_box(mb, x0, z0, x1, z1, y0, y1, String(b.get("window", "none")) == "grid",
				ao_cfg, ao_band, bool(b.get("overhang", false)), -1.0, rects, bi)

	for p_v in props:
		_emit_prop(mb, p_v, ox, oz, tile_m, ao_cfg, ao_band, rects, shapes)

	var mesh := mb.to_mesh()
	var height := mb.max_y
	var floors := int(level.get("floors", 0))
	var cols_rows := _window_grid(level, floor_h, tile_m, spacing)
	var meta := {
		"archetype": String(arch["id"]),
		"doc11_id": String(arch.get("doc11_id", "")),
		"family": String(arch.get("family", "")),
		"roof_signature": String(arch.get("roof_signature", "")),
		"level": int(level["level"]),
		"lod": lod,
		"tris": mb.tri_count(),
		"vertices": mb.verts.size(),
		"floors": floors,
		"height_m": snappedf(height, 0.0001),
		"roof_extra_m": snappedf(height - float(floors) * floor_h, 0.0001),
		"aabb": [snappedf(fx * tile_m, 0.0001), snappedf(height, 0.0001),
				snappedf(fz * tile_m, 0.0001)],
		"footprint_tiles": [int(fx), int(fz)],
		"window_cols": cols_rows[0],
		"window_rows": cols_rows[1],
		"windowless": cols_rows[0] == 0,
		"silhouette_descriptor": "0x%06X" % silhouette_descriptor(shapes, arch, level),
		"mesh_hash": mb.data_hash(),
	}
	return {"mesh": mesh, "meta": meta}


static func build_far_box(shapes: Dictionary) -> Dictionary:
	## Shared LOD2 box: unit footprint, y in [0,1], scaled per instance by the
	## transform to (fx*8, height_m, fz*8) — doc 11 §2.14.
	var mb := MeshBuf.new()
	var ao_cfg: Dictionary = {"default": 1.0, "facade_base": 1.0, "facade_band_m": 1.0,
			"overhang_underside": 1.0, "inner_corner": 1.0, "inner_corner_dist_m": 0.0,
			"roof_prop_contact": 1.0, "roof_prop_contact_m": 0.0}
	_emit_box(mb, -0.5, -0.5, 0.5, 0.5, 0.0, 1.0, false, ao_cfg, false, true, -1.0, [], -1)
	var meta := {
		"archetype": FAR_MESH_NAME, "doc11_id": "shared_far_box", "family": "",
		"roof_signature": "unit_box", "level": 0, "lod": 2,
		"tris": mb.tri_count(), "vertices": mb.verts.size(), "floors": 0,
		"height_m": 1.0, "roof_extra_m": 0.0, "aabb": [1.0, 1.0, 1.0],
		"footprint_tiles": [1, 1], "window_cols": 0, "window_rows": 0,
		"windowless": true, "silhouette_descriptor": "0x000000",
		"mesh_hash": mb.data_hash(),
	}
	return {"mesh": mb.to_mesh(), "meta": meta}


# ---------------------------------------------------------------- level markers

## Cumulative level markers (§2.14), sized proportionally to the top block so a
## house does not grow a skyscraper mast. Config lives in building_shapes.json.
static func marker_props(shapes: Dictionary, blocks: Array, level: int) -> Array:
	var cfg: Dictionary = shapes.get("level_markers", {})
	var floor_h := float(shapes.get("floor_height_m", 3.5))
	if cfg.is_empty() or blocks.is_empty():
		return []
	var top: Dictionary = blocks[0]
	for b_v in blocks:
		var b: Dictionary = b_v
		if bool(b.get("decor", false)):
			continue
		if _block_y1(b, floor_h) > _block_y1(top, floor_h):
			top = b
	var ty := _block_y1(top, floor_h)
	var x := float((top["pos_t"] as Array)[0])
	var z := float((top["pos_t"] as Array)[1])
	var w := float((top["size_t"] as Array)[0])
	var d := float((top["size_t"] as Array)[1])
	var tile_m := float(shapes.get("tile_m", 8.0))

	var out: Array = []
	var box_cfg: Dictionary = cfg.get("rooftop_box", {})
	if level >= int(box_cfg.get("from_level", 99)):
		var off: Array = box_cfg.get("offset_frac", [0.55, 0.15])
		out.append({"type": "box",
				"pos_t": [x + w * float(off[0]), z + d * float(off[1])],
				"size_t": [w * float(box_cfg.get("size_frac", 0.3)),
						d * float(box_cfg.get("size_frac", 0.3))],
				"base_m": ty,
				"height_m": clampf(ty * float(box_cfg.get("height_frac", 0.06)),
						float(box_cfg.get("height_min_m", 2.0)),
						float(box_cfg.get("height_max_m", 4.0)))})
	var crown_h := 0.0
	var crown_cfg: Dictionary = cfg.get("crown_band", {})
	if level >= int(crown_cfg.get("from_level", 99)):
		var inset := float(crown_cfg.get("inset_m", 0.5)) / tile_m
		crown_h = clampf(ty * float(crown_cfg.get("height_frac", 0.02)),
				float(crown_cfg.get("height_min_m", 0.8)),
				float(crown_cfg.get("height_max_m", 2.5)))
		out.append({"type": "box", "pos_t": [x + inset, z + inset],
				"size_t": [maxf(0.1, w - 2.0 * inset), maxf(0.1, d - 2.0 * inset)],
				"base_m": ty, "height_m": crown_h})
		var m_cfg: Dictionary = cfg.get("masts", {})
		var mh := clampf(ty * float(m_cfg.get("height_frac", 0.10)),
				float(m_cfg.get("height_min_m", 3.0)), float(m_cfg.get("height_max_m", 9.0)))
		var pos_frac: Array = m_cfg.get("pos_frac", [])
		for i in mini(int(m_cfg.get("count", 2)), pos_frac.size()):
			var pf: Array = pos_frac[i]
			out.append({"type": "mast",
					"pos_t": [x + w * float(pf[0]), z + d * float(pf[1])],
					"base_m": ty + crown_h, "height_m": mh,
					"width_m": float(m_cfg.get("width_m", 0.5))})
	var spire_cfg: Dictionary = cfg.get("spire", {})
	if level >= int(spire_cfg.get("from_level", 99)):
		var sh := clampf(ty * float(spire_cfg.get("height_frac", 0.18)),
				float(spire_cfg.get("height_min_m", 4.5)),
				float(spire_cfg.get("height_max_m", 14.0)))
		out.append({"type": "mast", "pos_t": [x + w * 0.5, z + d * 0.5],
				"base_m": ty + crown_h, "height_m": sh,
				"width_m": float(spire_cfg.get("width_m", 0.6)),
				"beacon": true, "beacon_m": float(spire_cfg.get("beacon_m", 0.6))})
	return out


# ------------------------------------------------------------ silhouette bits

## 24-bit descriptor, §2.14: [height:4][aspect:3][roof:4][setback:2][mast:2]
## [props:3][notch:3][windowless:1][footprint:2].
static func silhouette_descriptor(shapes: Dictionary, arch: Dictionary,
		level: Dictionary) -> int:
	var sil: Dictionary = shapes.get("silhouette", {})
	var floor_h := float(shapes.get("floor_height_m", 3.5))
	var tile_m := float(shapes.get("tile_m", 8.0))
	var blocks: Array = level.get("blocks", [])
	var props: Array = []
	props.append_array(level.get("roof_props", []))
	props.append_array(marker_props(shapes, blocks, int(level["level"])))

	var height := 0.0
	for b_v in blocks:
		height = maxf(height, _block_y1(b_v, floor_h))
	for p_v in props:
		var p: Dictionary = p_v
		var top := float(p.get("base_m", 0.0)) + float(p.get("height_m", 0.0))
		if bool(p.get("beacon", false)):
			top += float(p.get("beacon_m", 0.6))
		height = maxf(height, top)

	var fx := int((level["footprint_tiles"] as Array)[0])
	var fz := int((level["footprint_tiles"] as Array)[1])
	var slender := height / (tile_m * float(maxi(fx, fz)))

	var setbacks := 0
	for b_v in blocks:
		var b: Dictionary = b_v
		if not bool(b.get("decor", false)) and _block_y0(b, floor_h) > 0.01:
			setbacks += 1
	var masts := 0
	var notch := 0
	var flag_cfg: Dictionary = sil.get("notch_flag_bits", {})
	for p_v in props:
		var p: Dictionary = p_v
		var t := String(p.get("type", ""))
		if t == "mast":
			masts += 1
		if bool(p.get("overhang", false)):
			notch |= int(flag_cfg.get("overhang_or_canopy", 1))
		if t == "notch" or t == "pad":
			notch |= int(flag_cfg.get("notch_or_apron", 2))
		if t == "fence":
			notch |= int(flag_cfg.get("fenced_yard", 4))
	for b_v in blocks:
		if bool((b_v as Dictionary).get("overhang", false)):
			notch |= int(flag_cfg.get("overhang_or_canopy", 1))
	var windowless := 1
	for b_v in blocks:
		if String((b_v as Dictionary).get("window", "none")) == "grid":
			windowless = 0
			break

	var h_bucket := _bucket(height, sil.get("height_buckets_m", []))
	var a_bucket := _bucket(slender, sil.get("slenderness_buckets", []))
	var roof_id := int((sil.get("roof_signature_id", {}) as Dictionary)
			.get(String(arch.get("roof_signature", "")), 0))

	return (h_bucket << 20) | (a_bucket << 17) | (roof_id << 13) \
			| (mini(3, setbacks) << 11) | (mini(3, masts) << 9) \
			| (mini(7, props.size()) << 6) | (notch << 3) \
			| (windowless << 2) | mini(3, maxi(fx, fz) - 1)


static func _bucket(value: float, thresholds: Array) -> int:
	var n := 0
	for t in thresholds:
		if float(t) < value:
			n += 1
	return n


# ------------------------------------------------------------------ geometry

static func _block_y0(b: Dictionary, floor_h: float) -> float:
	if b.has("base_m"):
		return float(b["base_m"])
	return float(b.get("base_floor", 0)) * floor_h


static func _block_y1(b: Dictionary, floor_h: float) -> float:
	var y0 := _block_y0(b, floor_h)
	if b.has("height_m"):
		return y0 + float(b["height_m"])
	return y0 + float(b.get("floors", 1)) * floor_h


static func _block_volume(b: Dictionary, floor_h: float, tile_m: float) -> float:
	var size: Array = b["size_t"]
	return float(size[0]) * float(size[1]) * tile_m * tile_m \
			* (_block_y1(b, floor_h) - _block_y0(b, floor_h))


static func _lod1_blocks(blocks: Array, keep_frac: float, floor_h: float,
		tile_m: float) -> Array:
	var total := 0.0
	for b_v in blocks:
		if not bool((b_v as Dictionary).get("decor", false)):
			total += _block_volume(b_v, floor_h, tile_m)
	var kept: Array = []
	var best: Dictionary = {}
	var best_vol := -1.0
	for b_v in blocks:
		var b: Dictionary = b_v
		var vol := _block_volume(b, floor_h, tile_m)
		if vol > best_vol:
			best_vol = vol
			best = b
		if bool(b.get("decor", false)):
			continue
		if vol >= keep_frac * total:
			kept.append(b)
	if kept.is_empty() and not best.is_empty():
		kept.append(best)
	return kept


static func _merged_prop_box(props: Array, tile_m: float) -> Dictionary:
	var x0 := INF
	var z0 := INF
	var x1 := -INF
	var z1 := -INF
	var y0 := INF
	var y1 := -INF
	for p_v in props:
		var p: Dictionary = p_v
		var px := float((p["pos_t"] as Array)[0])
		var pz := float((p["pos_t"] as Array)[1])
		var sw := 0.0
		var sd := 0.0
		if p.has("size_t"):
			sw = float((p["size_t"] as Array)[0])
			sd = float((p["size_t"] as Array)[1])
		elif p.has("width_m"):
			sw = float(p["width_m"]) / tile_m
			sd = sw
			px -= sw * 0.5
			pz -= sd * 0.5
		x0 = minf(x0, px)
		z0 = minf(z0, pz)
		x1 = maxf(x1, px + sw)
		z1 = maxf(z1, pz + sd)
		var b := float(p.get("base_m", 0.0))
		y0 = minf(y0, b)
		y1 = maxf(y1, b + float(p.get("height_m", 0.0)))
	return {"type": "box", "pos_t": [x0, z0], "size_t": [maxf(0.05, x1 - x0), maxf(0.05, z1 - z0)],
			"base_m": y0, "height_m": maxf(0.1, y1 - y0)}


static func _block_rects(blocks: Array, floor_h: float, tile_m: float) -> Array:
	var out: Array = []
	for b_v in blocks:
		var b: Dictionary = b_v
		var pos: Array = b["pos_t"]
		var size: Array = b["size_t"]
		out.append({"index": out.size(),
				"x0": float(pos[0]) * tile_m, "z0": float(pos[1]) * tile_m,
				"x1": (float(pos[0]) + float(size[0])) * tile_m,
				"z1": (float(pos[1]) + float(size[1])) * tile_m,
				"y0": _block_y0(b, floor_h), "y1": _block_y1(b, floor_h)})
	return out


static func _window_grid(level: Dictionary, floor_h: float, tile_m: float,
		spacing: float) -> Array:
	# the block carrying the most façade area is the one whose grid the per-mesh
	# uniforms describe (doc 11 §2.14 sets them per mesh, not per block)
	var best: Dictionary = {}
	var best_area := -1.0
	for b_v in level.get("blocks", []) as Array:
		var b: Dictionary = b_v
		if String(b.get("window", "none")) != "grid":
			continue
		var size_t: Array = b["size_t"]
		var h := _block_y1(b, floor_h) - _block_y0(b, floor_h)
		var area := maxf(float(size_t[0]), float(size_t[1])) * tile_m * h
		if area > best_area:
			best_area = area
			best = b
	if best.is_empty():
		return [0, 0]
	var size: Array = best["size_t"]
	var width_m := maxf(float(size[0]), float(size[1])) * tile_m
	var cols := maxi(1, int(round(width_m / spacing)))
	var rows := int(best.get("floors", 0))
	if rows <= 0:
		rows = maxi(1, int(round((_block_y1(best, floor_h) - _block_y0(best, floor_h)) / floor_h)))
	return [cols, rows]


# ----------------------------------------------------------------- emitters

static func _emit_prop(mb: MeshBuf, p_v: Variant, ox: float, oz: float, tile_m: float,
		ao_cfg: Dictionary, ao_band: bool, rects: Array, shapes: Dictionary) -> void:
	var p: Dictionary = p_v
	var type := String(p.get("type", "box"))
	var pos: Array = p["pos_t"]
	var base := float(p.get("base_m", 0.0))
	var h := float(p.get("height_m", 0.0))
	var px := ox + float(pos[0]) * tile_m
	var pz := oz + float(pos[1]) * tile_m

	match type:
		"box", "notch", "sign_band":
			var size: Array = p["size_t"]
			_emit_box(mb, px, pz, px + float(size[0]) * tile_m, pz + float(size[1]) * tile_m,
					base, base + h, false, ao_cfg, ao_band,
					bool(p.get("overhang", false)), base, rects, -1)
		"gable":
			var gs: Array = p["size_t"]
			_emit_gable(mb, px, pz, px + float(gs[0]) * tile_m, pz + float(gs[1]) * tile_m,
					base, h, ao_cfg)
		"mast":
			var w := float(p.get("width_m", 0.6))
			_emit_mast(mb, px, pz, base, h, w, ao_cfg)
			if bool(p.get("beacon", false)):
				var bm := float(p.get("beacon_m", 0.6))
				_emit_box(mb, px - bm * 0.5, pz - bm * 0.5, px + bm * 0.5, pz + bm * 0.5,
						base + h, base + h + bm, false, ao_cfg, false, false, base + h, [], -1)
		"octprism":
			var os_: Array = p["size_t"]
			_emit_octprism(mb, px, pz, px + float(os_[0]) * tile_m,
					pz + float(os_[1]) * tile_m, base, base + h, ao_cfg, ao_band)
		"fence":
			var fs: Array = p["size_t"]
			_emit_fence(mb, px, pz, px + float(fs[0]) * tile_m, pz + float(fs[1]) * tile_m,
					base, base + h, ao_cfg)
		"pad":
			var ps: Array = p["size_t"]
			_emit_pad(mb, px, pz, px + float(ps[0]) * tile_m, pz + float(ps[1]) * tile_m,
					base, ao_cfg)
		_:
			push_warning("gen_graybox: unknown prop type " + type)


static func _emit_box(mb: MeshBuf, x0: float, z0: float, x1: float, z1: float,
		y0: float, y1: float, window_grid: bool, ao_cfg: Dictionary, ao_band: bool,
		overhang: bool, prop_base: float, rects: Array, owner_index: int) -> void:
	var band := float(ao_cfg.get("facade_band_m", 3.0))
	var split := ao_band and y0 < band and band < y1
	# side faces: (normal, corner order counter-clockwise seen from outside)
	var faces := [
		{"n": Vector3(0, 0, 1), "a": Vector3(x1, 0, z1), "b": Vector3(x0, 0, z1)},
		{"n": Vector3(0, 0, -1), "a": Vector3(x0, 0, z0), "b": Vector3(x1, 0, z0)},
		{"n": Vector3(1, 0, 0), "a": Vector3(x1, 0, z0), "b": Vector3(x1, 0, z1)},
		{"n": Vector3(-1, 0, 0), "a": Vector3(x0, 0, z1), "b": Vector3(x0, 0, z0)},
	]
	for f_v in faces:
		var f: Dictionary = f_v
		var a: Vector3 = f["a"]
		var b: Vector3 = f["b"]
		var n: Vector3 = f["n"]
		var segs := [[y0, y1]]
		if split:
			segs = [[y0, band], [band, y1]]
		for seg_v in segs:
			var seg: Array = seg_v
			var sy0 := float(seg[0])
			var sy1 := float(seg[1])
			var v0 := Vector3(a.x, sy0, a.z)
			var v1 := Vector3(b.x, sy0, b.z)
			var v2 := Vector3(b.x, sy1, b.z)
			var v3 := Vector3(a.x, sy1, a.z)
			var t0 := (sy0 - y0) / maxf(0.0001, y1 - y0)
			var t1 := (sy1 - y0) / maxf(0.0001, y1 - y0)
			var uv2: Array = [Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1)]
			if window_grid:
				uv2 = [Vector2(0.0, t0), Vector2(1.0, t0), Vector2(1.0, t1), Vector2(0.0, t1)]
			var uv: Array = [Vector2(0.0, 1.0 - t0), Vector2(1.0, 1.0 - t0),
					Vector2(1.0, 1.0 - t1), Vector2(0.0, 1.0 - t1)]
			var cols: Array = [
				_ao(v0, n, ao_cfg, prop_base, rects, owner_index),
				_ao(v1, n, ao_cfg, prop_base, rects, owner_index),
				_ao(v2, n, ao_cfg, prop_base, rects, owner_index),
				_ao(v3, n, ao_cfg, prop_base, rects, owner_index)]
			mb.add_quad(v0, v1, v2, v3, n, uv, uv2, cols)
	# top
	var top_n := Vector3(0, 1, 0)
	var ao_top := float(ao_cfg.get("default", 1.0))
	mb.add_quad(Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1),
			Vector3(x0, y1, z1), top_n,
			[Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)],
			[Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1)],
			[ao_top, ao_top, ao_top, ao_top])
	if overhang:
		var bot_n := Vector3(0, -1, 0)
		var ao_bot := float(ao_cfg.get("overhang_underside", 0.45))
		mb.add_quad(Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y0, z0),
				Vector3(x0, y0, z0), bot_n,
				[Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)],
				[Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1)],
				[ao_bot, ao_bot, ao_bot, ao_bot])


static func _emit_gable(mb: MeshBuf, x0: float, z0: float, x1: float, z1: float,
		base: float, ridge_h: float, ao_cfg: Dictionary) -> void:
	var top := base + ridge_h
	var uv_neg: Array = [Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1)]
	var one := float(ao_cfg.get("default", 1.0))
	var contact := float(ao_cfg.get("roof_prop_contact", 0.65))
	if absf(x1 - x0) >= absf(z1 - z0):
		var zm := (z0 + z1) * 0.5
		# two slopes along X
		mb.add_quad(Vector3(x0, base, z1), Vector3(x1, base, z1), Vector3(x1, top, zm),
				Vector3(x0, top, zm), Vector3(0.0, z1 - zm, ridge_h).normalized(),
				[Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)], uv_neg,
				[contact, contact, one, one])
		mb.add_quad(Vector3(x1, base, z0), Vector3(x0, base, z0), Vector3(x0, top, zm),
				Vector3(x1, top, zm), Vector3(0.0, zm - z0, -ridge_h).normalized(),
				[Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)], uv_neg,
				[contact, contact, one, one])
		# gable end triangles
		mb.add_tri(Vector3(x0, base, z0), Vector3(x0, base, z1), Vector3(x0, top, zm),
				Vector3(-1, 0, 0), [Vector2(0, 1), Vector2(1, 1), Vector2(0.5, 0)],
				[Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1)], [contact, contact, one])
		mb.add_tri(Vector3(x1, base, z1), Vector3(x1, base, z0), Vector3(x1, top, zm),
				Vector3(1, 0, 0), [Vector2(0, 1), Vector2(1, 1), Vector2(0.5, 0)],
				[Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1)], [contact, contact, one])
	else:
		var xm := (x0 + x1) * 0.5
		mb.add_quad(Vector3(x1, base, z0), Vector3(x1, base, z1), Vector3(xm, top, z1),
				Vector3(xm, top, z0), Vector3(ridge_h, x1 - xm, 0.0).normalized(),
				[Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)], uv_neg,
				[contact, contact, one, one])
		mb.add_quad(Vector3(x0, base, z1), Vector3(x0, base, z0), Vector3(xm, top, z0),
				Vector3(xm, top, z1), Vector3(-ridge_h, xm - x0, 0.0).normalized(),
				[Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)], uv_neg,
				[contact, contact, one, one])
		mb.add_tri(Vector3(x1, base, z0), Vector3(x0, base, z0), Vector3(xm, top, z0),
				Vector3(0, 0, -1), [Vector2(0, 1), Vector2(1, 1), Vector2(0.5, 0)],
				[Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1)], [contact, contact, one])
		mb.add_tri(Vector3(x0, base, z1), Vector3(x1, base, z1), Vector3(xm, top, z1),
				Vector3(0, 0, 1), [Vector2(0, 1), Vector2(1, 1), Vector2(0.5, 0)],
				[Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1)], [contact, contact, one])


static func _emit_mast(mb: MeshBuf, cx: float, cz: float, base: float, h: float,
		w: float, ao_cfg: Dictionary) -> void:
	var top := base + h
	var half := w * 0.5
	var uv: Array = [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
	var uv_neg: Array = [Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1)]
	var contact := float(ao_cfg.get("roof_prop_contact", 0.65))
	var one := float(ao_cfg.get("default", 1.0))
	mb.add_quad(Vector3(cx - half, base, cz), Vector3(cx + half, base, cz),
			Vector3(cx + half, top, cz), Vector3(cx - half, top, cz),
			Vector3(0, 0, 1), uv, uv_neg, [contact, contact, one, one])
	mb.add_quad(Vector3(cx, base, cz - half), Vector3(cx, base, cz + half),
			Vector3(cx, top, cz + half), Vector3(cx, top, cz - half),
			Vector3(1, 0, 0), uv, uv_neg, [contact, contact, one, one])


static func _emit_octprism(mb: MeshBuf, x0: float, z0: float, x1: float, z1: float,
		y0: float, y1: float, ao_cfg: Dictionary, ao_band: bool) -> void:
	var cx := (x0 + x1) * 0.5
	var cz := (z0 + z1) * 0.5
	var rx := (x1 - x0) * 0.5
	var rz := (z1 - z0) * 0.5
	var band := float(ao_cfg.get("facade_band_m", 3.0))
	var split := ao_band and y0 < band and band < y1
	var ring: Array = []
	for i in 8:
		var ang := TAU * (float(i) + 0.5) / 8.0
		ring.append(Vector2(cx + rx * cos(ang), cz + rz * sin(ang)))
	for i in 8:
		var p0: Vector2 = ring[i]
		var p1: Vector2 = ring[(i + 1) % 8]
		var n := Vector3(((p0.x + p1.x) * 0.5) - cx, 0.0, ((p0.y + p1.y) * 0.5) - cz).normalized()
		var segs := [[y0, y1]]
		if split:
			segs = [[y0, band], [band, y1]]
		for seg_v in segs:
			var seg: Array = seg_v
			var sy0 := float(seg[0])
			var sy1 := float(seg[1])
			var v0 := Vector3(p1.x, sy0, p1.y)
			var v1 := Vector3(p0.x, sy0, p0.y)
			var v2 := Vector3(p0.x, sy1, p0.y)
			var v3 := Vector3(p1.x, sy1, p1.y)
			mb.add_quad(v0, v1, v2, v3, n,
					[Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)],
					[Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1)],
					[_ao(v0, n, ao_cfg, y0, [], -1), _ao(v1, n, ao_cfg, y0, [], -1),
					_ao(v2, n, ao_cfg, y0, [], -1), _ao(v3, n, ao_cfg, y0, [], -1)])
	var one := float(ao_cfg.get("default", 1.0))
	for i in range(1, 7):
		var a: Vector2 = ring[0]
		var b: Vector2 = ring[i]
		var c: Vector2 = ring[i + 1]
		mb.add_tri(Vector3(a.x, y1, a.y), Vector3(b.x, y1, b.y), Vector3(c.x, y1, c.y),
				Vector3(0, 1, 0), [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1)],
				[Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1)], [one, one, one])


static func _emit_fence(mb: MeshBuf, x0: float, z0: float, x1: float, z1: float,
		y0: float, y1: float, ao_cfg: Dictionary) -> void:
	var uv: Array = [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
	var uv_neg: Array = [Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1)]
	var faces := [
		[Vector3(x1, y0, z1), Vector3(x0, y0, z1), Vector3(0, 0, 1)],
		[Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(0, 0, -1)],
		[Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(1, 0, 0)],
		[Vector3(x0, y0, z1), Vector3(x0, y0, z0), Vector3(-1, 0, 0)],
	]
	for f_v in faces:
		var f: Array = f_v
		var a: Vector3 = f[0]
		var b: Vector3 = f[1]
		var n: Vector3 = f[2]
		var v2 := Vector3(b.x, y1, b.z)
		var v3 := Vector3(a.x, y1, a.z)
		mb.add_quad(a, b, v2, v3, n, uv, uv_neg,
				[_ao(a, n, ao_cfg, -1.0, [], -1), _ao(b, n, ao_cfg, -1.0, [], -1),
				_ao(v2, n, ao_cfg, -1.0, [], -1), _ao(v3, n, ao_cfg, -1.0, [], -1)])


static func _emit_pad(mb: MeshBuf, x0: float, z0: float, x1: float, z1: float,
		y: float, ao_cfg: Dictionary) -> void:
	var one := float(ao_cfg.get("default", 1.0))
	mb.add_quad(Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1),
			Vector3(x0, y, z1), Vector3(0, 1, 0),
			[Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)],
			[Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1), Vector2(-1, -1)],
			[one, one, one, one])


## Baked vertex-colour AO (§2.14 table).
static func _ao(p: Vector3, n: Vector3, ao_cfg: Dictionary, prop_base: float,
		rects: Array, owner_index: int) -> float:
	if n.y > 0.5:
		return float(ao_cfg.get("default", 1.0))
	if n.y < -0.5:
		return float(ao_cfg.get("overhang_underside", 0.45))
	var band := float(ao_cfg.get("facade_band_m", 3.0))
	var base := float(ao_cfg.get("facade_base", 0.55))
	var a := lerpf(base, float(ao_cfg.get("default", 1.0)), clampf(p.y / maxf(0.001, band), 0.0, 1.0))
	if prop_base >= 0.0 and (p.y - prop_base) <= float(ao_cfg.get("roof_prop_contact_m", 0.5)):
		a = minf(a, float(ao_cfg.get("roof_prop_contact", 0.65)))
	var dist := float(ao_cfg.get("inner_corner_dist_m", 1.0))
	for r_v in rects:
		var r: Dictionary = r_v
		if int(r["index"]) == owner_index:
			continue
		if p.y < float(r["y0"]) - dist or p.y > float(r["y1"]) + dist:
			continue
		var dx := maxf(maxf(float(r["x0"]) - p.x, p.x - float(r["x1"])), 0.0)
		var dz := maxf(maxf(float(r["z0"]) - p.z, p.z - float(r["z1"])), 0.0)
		if sqrt(dx * dx + dz * dz) <= dist:
			a = minf(a, float(ao_cfg.get("inner_corner", 0.70)))
			break
	return a


# ------------------------------------------------------------------- MeshBuf

class MeshBuf extends RefCounted:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var uv1 := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var idx := PackedInt32Array()
	var max_y := 0.0

	func _push(p: Vector3, n: Vector3, uv: Vector2, w: Vector2, ao: float) -> int:
		verts.push_back(p)
		norms.push_back(n)
		uv1.push_back(uv)
		uv2.push_back(w)
		cols.push_back(Color(ao, ao, ao, 1.0))
		max_y = maxf(max_y, p.y)
		return verts.size() - 1

	## p0..p3 counter-clockwise as seen from +n; emitted with Godot's clockwise
	## front-face winding.
	func add_quad(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: Vector3,
			uv: Array, w: Array, ao: Array) -> void:
		var i0 := _push(p0, n, uv[0], w[0], float(ao[0]))
		var i1 := _push(p1, n, uv[1], w[1], float(ao[1]))
		var i2 := _push(p2, n, uv[2], w[2], float(ao[2]))
		var i3 := _push(p3, n, uv[3], w[3], float(ao[3]))
		_tri(i0, i1, i2, p0, p1, p2, n)
		_tri(i0, i2, i3, p0, p2, p3, n)

	func add_tri(p0: Vector3, p1: Vector3, p2: Vector3, n: Vector3,
			uv: Array, w: Array, ao: Array) -> void:
		var i0 := _push(p0, n, uv[0], w[0], float(ao[0]))
		var i1 := _push(p1, n, uv[1], w[1], float(ao[1]))
		var i2 := _push(p2, n, uv[2], w[2], float(ao[2]))
		_tri(i0, i1, i2, p0, p1, p2, n)

	func _tri(i0: int, i1: int, i2: int, p0: Vector3, p1: Vector3, p2: Vector3,
			n: Vector3) -> void:
		var facing := (p1 - p0).cross(p2 - p0).dot(n)
		# Godot front faces are clockwise, i.e. the geometric cross product of the
		# emitted order points AGAINST the outward normal.
		if facing > 0.0:
			idx.push_back(i0)
			idx.push_back(i2)
			idx.push_back(i1)
		else:
			idx.push_back(i0)
			idx.push_back(i1)
			idx.push_back(i2)

	func tri_count() -> int:
		return idx.size() / 3

	func to_mesh() -> ArrayMesh:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = norms
		arrays[Mesh.ARRAY_COLOR] = cols
		arrays[Mesh.ARRAY_TEX_UV] = uv1
		arrays[Mesh.ARRAY_TEX_UV2] = uv2
		arrays[Mesh.ARRAY_INDEX] = idx
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		return mesh

	## Stable content hash over every vertex attribute and index — the manifest's
	## determinism guarantee (§7.1 test 1) without depending on container format.
	func data_hash() -> String:
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_SHA1)
		var buf := PackedFloat32Array()
		for i in verts.size():
			var v := verts[i]
			var n := norms[i]
			var c := cols[i]
			var a := uv1[i]
			var b := uv2[i]
			buf.append_array(PackedFloat32Array([v.x, v.y, v.z, n.x, n.y, n.z,
					c.r, c.g, c.b, a.x, a.y, b.x, b.y]))
		ctx.update(buf.to_byte_array())
		ctx.update(idx.to_byte_array())
		return ctx.finish().hex_encode()
