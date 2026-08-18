extends SimTest
## Doc 01 T-19 / risk R7: sim/ never touches wall clock, OS, engine singletons
## or input. Runs on every commit — determinism is a per-commit gate.

const FORBIDDEN := ["Time.", "OS.", "Engine.", "Input.", "get_ticks_"]


func test_sim_has_no_wallclock_or_engine_access() -> void:
	var scanned := _scan_dir("res://sim")
	assert_true(scanned > 0, "found sim scripts to scan")


func _scan_dir(path: String) -> int:
	var count := 0
	var dir := DirAccess.open(path)
	if dir == null:
		return 0
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := path + "/" + entry
		if dir.current_is_dir():
			count += _scan_dir(full)
		elif entry.ends_with(".gd"):
			count += 1
			var text := FileAccess.get_file_as_string(full)
			var lines := text.split("\n")
			for i in lines.size():
				var line := lines[i]
				var comment_at := line.find("#")
				var code := line.substr(0, comment_at) if comment_at >= 0 else line
				for pattern in FORBIDDEN:
					assert_false(code.contains(pattern),
							"%s:%d contains forbidden '%s'" % [full, i + 1, pattern])
		entry = dir.get_next()
	dir.list_dir_end()
	return count
