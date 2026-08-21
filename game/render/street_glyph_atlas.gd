class_name StreetGlyphAtlas
extends RefCounted
## The sixteen marks the STREET LIFE layer (doc 11 §2.17) has to be able to
## draw: the ten digits, `+`, `$`, `!`, `k`, a paw and a bell.
##
## WHY A PAGE AND NOT A `Label3D`. A floating `+$120` is a Node per label, a
## `TextMesh` rebuild per value and a draw call per label — four labels and the
## layer has spent its whole budget on arithmetic nobody reads twice. What this
## builds instead is ONE 256 × 20 page in which every mark is a **signed
## distance field**, so a label is a run of MultiMesh quads sharing one buffer
## and one call, and the marks stay crisp from Z0 (a 1 m glyph is 82 screen px)
## to Z1 (17 px) without a mipmap chain or a second authored size.
##
## WHY AN SDF AND NOT A BITMAP. The marks are authored on a **5 × 7 cell grid**
## — chunky, legible, the shape of a scoreboard — and a bitmap of that grid
## blown up to 26 screen px is a blurry mess under linear filtering and a
## staircase under nearest. The distance field is the same authored shape
## sampled as a *field*: `smoothstep` across the 0.5 contour reconstructs a hard
## edge at any magnification, and the same field gives the outline the labels
## need over a bright roof for free (a second contour at 0.5 − `outline`).
##
## AND WHY IT IS EXACT — the one trap in the file. A glyph is a union of unit
## cells, and the *obvious* field is `min` of each cell's box distance. That is
## wrong, and wrong in a way that shows: at the seam between two touching cells
## both boxes report distance 0, so `min` puts a **contour along every internal
## cell edge** and the digits come out striped like graph paper. The distance to
## a union is the distance to the union's BOUNDARY, so that is what is measured:
## the boundary is extracted as axis-aligned edge segments (a cell edge with ink
## on exactly one side), collinear neighbours are welded into runs, and the sign
## comes from a grid lookup. Exact, seam-free, and ~18 segments a glyph over 320
## texels — a few milliseconds of GDScript for the whole page, once per process.
##
## Deterministic and allocation-once: the page is a `static var`, built on the
## first ask and shared by every material that wants it. Nothing here reads a
## clock, a file or an RNG, so two devices hold byte-identical pages.

# ------------------------------------------------------------------- layout

## Glyph codes. The order IS the atlas column order and the number the view
## writes into `INSTANCE_CUSTOM.g`, so it is a contract with
## `game/shaders/street_fx.gdshader` — append only.
const G_0 := 0
const G_PLUS := 10
const G_CASH := 11
const G_BANG := 12
const G_K := 13
const G_PAW := 14
const G_BELL := 15
const GLYPH_COUNT := 16

## Authored cell grid, per glyph.
const CELL_W := 5
const CELL_H := 7
## Padding around the cell grid, in CELLS, so the field has somewhere to fall
## off before the atlas cell ends. 1.5 either side gives the shader a full
## `SPREAD` of headroom for an outline.
const PAD := 1.5
## Texels per authored cell. Two is enough: the field between two samples is
## very nearly linear, which is the whole reason a distance field survives
## being stored this coarsely.
const PX_PER_CELL := 2

## Atlas cell size, texels.
const CELL_PX_W := int((CELL_W + PAD * 2.0) * PX_PER_CELL)    # 16
const CELL_PX_H := int((CELL_H + PAD * 2.0) * PX_PER_CELL)    # 20
const PAGE_W := CELL_PX_W * GLYPH_COUNT                       # 256
const PAGE_H := CELL_PX_H                                     # 20

## Cells of distance the stored field spans either side of the contour. The
## shader's outline width is quoted as a fraction of this.
const SPREAD := 2.0

## The marks, one string per row, `X` = ink. Five wide, seven tall, every one of
## them — a mark that does not fit the grid is a mark that will not read at 17
## screen px, which is the size that matters.
##
## Plain nested arrays rather than `PackedStringArray`s: a packed-array
## constructor is not a constant expression in GDScript, and this table has to
## be a `const` so nothing can edit the font at runtime.
const GLYPHS := [
	# 0
	[".XXX.", "X...X", "X..XX", "X.X.X", "XX..X", "X...X", ".XXX."],
	# 1
	["..X..", ".XX..", "..X..", "..X..", "..X..", "..X..", ".XXX."],
	# 2
	[".XXX.", "X...X", "....X", "...X.", "..X..", ".X...", "XXXXX"],
	# 3
	["XXXXX", "...X.", "..X..", "...X.", "....X", "X...X", ".XXX."],
	# 4
	["...X.", "..XX.", ".X.X.", "X..X.", "XXXXX", "...X.", "...X."],
	# 5
	["XXXXX", "X....", "XXXX.", "....X", "....X", "X...X", ".XXX."],
	# 6
	["..XX.", ".X...", "X....", "XXXX.", "X...X", "X...X", ".XXX."],
	# 7
	["XXXXX", "....X", "...X.", "..X..", ".X...", ".X...", ".X..."],
	# 8
	[".XXX.", "X...X", "X...X", ".XXX.", "X...X", "X...X", ".XXX."],
	# 9
	[".XXX.", "X...X", "X...X", ".XXXX", "....X", "...X.", ".XX.."],
	# +
	[".....", "..X..", "..X..", "XXXXX", "..X..", "..X..", "....."],
	# $  — the stroke runs the full height, which is what makes it read as money
	#    rather than as an S at marker size.
	["..X..", ".XXXX", "X.X..", ".XXX.", "..X.X", "XXXX.", "..X.."],
	# !
	["..X..", "..X..", "..X..", "..X..", "..X..", ".....", "..X.."],
	# k
	["X....", "X....", "X..X.", "X.X..", "XX...", "X.X..", "X..X."],
	# paw — three toes and a pad. Four toes on a five-cell grid merge into a bar.
	["X.X.X", "X.X.X", ".....", ".XXX.", "XXXXX", "XXXXX", ".XXX."],
	# bell — crown, flared body, rim, clapper.
	["..X..", ".XXX.", ".XXX.", ".XXX.", "XXXXX", ".....", "..X.."],
]

static var _page: ImageTexture = null
static var _build_usec: int = 0


## The shared page. Built once per process; every material that asks gets the
## same `ImageTexture`.
static func page() -> ImageTexture:
	if _page == null:
		_page = _build()
	return _page


## Microseconds the page took to build, for the profiler table and the test
## that keeps it honest. 0 until `page()` has been called once.
static func build_usec() -> int:
	return _build_usec


## Width over height of one atlas cell. A glyph quad has to carry this or the
## digits stretch, and it is stated HERE — where the cell is defined — so the
## label layout and the shader's pitch cannot disagree about it.
static func cell_aspect() -> float:
	return float(CELL_PX_W) / float(CELL_PX_H)


## Where glyph `index` sits in the page, as a `(u0, v0, du, dv)` rectangle in
## 0..1 texture coordinates. The shader is handed `cell_u` (= `du`) and does the
## rest with the index, so this exists for the tests and for anything that wants
## to reason about the page without reading the shader.
static func cell_rect(index: int) -> Rect2:
	var i := clampi(index, 0, GLYPH_COUNT - 1)
	return Rect2(float(i) / float(GLYPH_COUNT), 0.0,
			1.0 / float(GLYPH_COUNT), 1.0)


## The glyph run for a reward, as atlas indices: `+`, `$`, then the digits, with
## anything from 10,000 up abbreviated to thousands and a `k`.
##
## Abbreviating is not cosmetic. A label is a billboard whose width is glyph
## count × pitch, and `+$1250000` at Z0 is a nine-glyph banner three car-lengths
## wide lying across the street it was earned on. Five glyphs is the width the
## art is tuned for and `+$1.2M` would need a decimal point the page does not
## carry, so the ladder stops at `k`.
static func reward_glyphs(amount: int) -> PackedInt32Array:
	var out := PackedInt32Array([G_PLUS, G_CASH])
	var n := maxi(0, amount)
	var suffix := -1
	if n >= 10000:
		n = n / 1000
		suffix = G_K
	for ch in str(n):
		out.push_back(G_0 + (ch.unicode_at(0) - 48))
	if suffix >= 0:
		out.push_back(suffix)
	return out


# ------------------------------------------------------------------ builder

static func _build() -> ImageTexture:
	var t0 := Time.get_ticks_usec()
	var img := Image.create_empty(PAGE_W, PAGE_H, false, Image.FORMAT_RGBA8)
	for g in GLYPH_COUNT:
		var ink := _ink(GLYPHS[g])
		_draw_glyph(img, g, ink, _boundary(ink))
	var tex := ImageTexture.create_from_image(img)
	_build_usec = Time.get_ticks_usec() - t0
	return tex


## The authored grid as a flat occupancy array, row-major, y growing DOWN.
static func _ink(rows: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(CELL_W * CELL_H)
	for y in mini(CELL_H, rows.size()):
		var row: String = rows[y]
		for x in mini(CELL_W, row.length()):
			out[y * CELL_W + x] = 1 if row[x] == "X" else 0
	return out


static func _at(ink: PackedByteArray, x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= CELL_W or y >= CELL_H:
		return false
	return ink[y * CELL_W + x] != 0


## The union's boundary, as axis-aligned segments in cell coordinates, welded
## along their own axis. Encoded `(a, b, c, horizontal)`: a horizontal segment
## lies at `y = c` and spans `x ∈ [a, b]`; a vertical one lies at `x = c` and
## spans `y ∈ [a, b]`.
static func _boundary(ink: PackedByteArray) -> Array[Vector4]:
	var out: Array[Vector4] = []
	# Horizontal edges: every cell edge with ink on exactly one side.
	for y in range(0, CELL_H + 1):
		var run_start := -1
		for x in range(0, CELL_W + 1):
			var edge := x < CELL_W and (_at(ink, x, y - 1) != _at(ink, x, y))
			if edge and run_start < 0:
				run_start = x
			elif not edge and run_start >= 0:
				out.append(Vector4(float(run_start), float(x), float(y), 1.0))
				run_start = -1
	for x in range(0, CELL_W + 1):
		var v_start := -1
		for y in range(0, CELL_H + 1):
			var edge := y < CELL_H and (_at(ink, x - 1, y) != _at(ink, x, y))
			if edge and v_start < 0:
				v_start = y
			elif not edge and v_start >= 0:
				out.append(Vector4(float(v_start), float(y), float(x), 0.0))
				v_start = -1
	return out


static func _draw_glyph(img: Image, index: int, ink: PackedByteArray,
		edges: Array[Vector4]) -> void:
	var ox := index * CELL_PX_W
	var inv := 1.0 / float(PX_PER_CELL)
	for py in CELL_PX_H:
		# Texel centres, converted back into the authored CELL frame.
		var cy := (float(py) + 0.5) * inv - PAD
		for px in CELL_PX_W:
			var cx := (float(px) + 0.5) * inv - PAD
			var d := _distance(edges, cx, cy)
			if _at(ink, int(floorf(cx)), int(floorf(cy))):
				d = -d
			# 0.5 is the contour; inside is above it. Clamped to the spread so
			# the far field is flat and costs no precision.
			var v := clampf(0.5 - d / (2.0 * SPREAD), 0.0, 1.0)
			img.set_pixel(ox + px, py, Color(v, v, v, v))


## Unsigned distance from `(cx, cy)` — in cell units — to the union's boundary.
## Both segment kinds are axis-aligned, so this is one `max` per axis and a
## square root, with no general point-segment projection anywhere.
static func _distance(edges: Array[Vector4], cx: float, cy: float) -> float:
	var best := 1e9
	for e: Vector4 in edges:
		var along := cx if e.w > 0.5 else cy
		var across := absf((cy if e.w > 0.5 else cx) - e.z)
		var off := maxf(maxf(e.x - along, along - e.y), 0.0)
		var d2 := off * off + across * across
		if d2 < best:
			best = d2
	return sqrt(best)
