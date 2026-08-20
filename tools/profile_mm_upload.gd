extends SceneTree
## The MultiMesh upload A/B (doc 11 §2.13, report RR-32).
##
## The construction branch filed "one `multimesh_set_buffer` per layer per frame
## instead of ~200 `set_instance_*` triples" as the named lever for Fold
## headroom. This is the harness that measured it before it was implemented, and
## it is kept in the tree because the conclusion is a NEGATIVE one and a negative
## result nobody can re-run is an opinion:
##
##   200 instances / frame    setters 0.031 ms   packed 0.061 + 0.003 ms
##   2,000 instances / frame  setters 0.307 ms   packed 0.634 + 0.028 ms
##
## `set_instance_transform` is one binding call around a C++ memcpy of twelve
## floats; packing the same row is twelve scripted `PackedFloat32Array` writes
## plus the basis reads to feed them, and the server-side write is nearly free
## either way. The cost was never the RenderingServer — it was GDScript.
##
## It needs a REAL renderer (a `--headless` run is on the DUMMY driver, where
## neither path does any work), so it is a display-attached tool like
## `tools/profile_frame.gd`. It measures nothing but the upload: one MultiMesh,
## one camera, a wide `custom_aabb`, vsync off.
##
## Usage:
##   ~/.local/bin/godot --path "/home/bbx/Slacum City game" \
##       -s res://tools/profile_mm_upload.gd -- [options]
##
##   --n=N          instances rewritten every frame (default 200)
##   --style=a      per-instance setters   (the shipped path)
##   --style=b      one packed buffer      (the refuted path)
##
## Run one style per process: the point is the whole-frame column, and two
## styles in one frame only splits the GDScript block.

var _mm: MultiMesh
var _node: MultiMeshInstance3D
var _frames := 0
var _usec := 0
var _frame_usec := 0
var _last := 0
var _n := 200
var _style := "a"
var _buf := PackedFloat32Array()


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var a := String(arg)
		if a.begins_with("--n="):
			_n = int(a.substr(4))
		elif a.begins_with("--style="):
			_style = a.substr(8)
	var stage := Node3D.new()
	root.add_child(stage)
	var cam := Camera3D.new()
	cam.position = Vector3(200, 60, 200)
	cam.look_at(Vector3(200, 0, 0))
	stage.add_child(cam)
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.use_custom_data = true
	_mm.mesh = BoxMesh.new()
	_mm.instance_count = _n
	_mm.visible_instance_count = 0
	_node = MultiMeshInstance3D.new()
	_node.multimesh = _mm
	_node.custom_aabb = AABB(Vector3(-500, -10, -500), Vector3(1000, 40, 1000))
	stage.add_child(_node)
	_buf.resize(_n * 20)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	print("instances=%d style=%s" % [_n, _style])


func _process(delta: float) -> bool:
	_frames += 1
	var now := Time.get_ticks_usec()
	if _frames > 120:
		_frame_usec += now - _last
	_last = now
	var t := float(_frames) * 0.01
	var t0 := Time.get_ticks_usec()
	if _style == "a":
		for i in _n:
			var xf := Transform3D(Basis.from_euler(Vector3(0.0, t + float(i), 0.0)),
					Vector3(float(i) * 2.0, 0.0, sin(t + float(i)) * 10.0))
			_mm.set_instance_transform(i, xf)
			_mm.set_instance_color(i, Color(0.2, 0.4, 0.6, 1.0))
			_mm.set_instance_custom_data(i, Color(t, 0.5, 0.25, 1.0))
	else:
		var o := 0
		for i in _n:
			var xf := Transform3D(Basis.from_euler(Vector3(0.0, t + float(i), 0.0)),
					Vector3(float(i) * 2.0, 0.0, sin(t + float(i)) * 10.0))
			var b := xf.basis
			var r0 := b.x
			var r1 := b.y
			var r2 := b.z
			var p := xf.origin
			_buf[o] = r0.x
			_buf[o + 1] = r1.x
			_buf[o + 2] = r2.x
			_buf[o + 3] = p.x
			_buf[o + 4] = r0.y
			_buf[o + 5] = r1.y
			_buf[o + 6] = r2.y
			_buf[o + 7] = p.y
			_buf[o + 8] = r0.z
			_buf[o + 9] = r1.z
			_buf[o + 10] = r2.z
			_buf[o + 11] = p.z
			_buf[o + 12] = 0.2
			_buf[o + 13] = 0.4
			_buf[o + 14] = 0.6
			_buf[o + 15] = 1.0
			_buf[o + 16] = t
			_buf[o + 17] = 0.5
			_buf[o + 18] = 0.25
			_buf[o + 19] = 1.0
			o += 20
		_mm.buffer = _buf
	_mm.visible_instance_count = _n
	if _frames > 120:
		_usec += Time.get_ticks_usec() - t0

	if _frames >= 720:
		var n := 600.0
		print("upload block : %.4f ms/frame" % (_usec / n / 1000.0))
		print("whole frame  : %.4f ms/frame" % (_frame_usec / n / 1000.0))
		print("rs cpu       : %.4f ms" % RenderingServer.viewport_get_measured_render_time_cpu(
				root.get_viewport_rid()))
		print("rs gpu       : %.4f ms" % RenderingServer.viewport_get_measured_render_time_gpu(
				root.get_viewport_rid()))
		quit()
	return false
