extends SceneTree
## Read a generation file and print the parts of its body a human needs to read
## — the save-section versions, the curriculum block, the treasury block and any
## grant ledger. Wave 24 wrote it to answer ONE question on the player's own
## city: *what has this city already been paid, and what does the back-pay owe
## it?* (doc 92 §63.5).
##
##   ~/.local/bin/godot --headless --path . -s res://tools/dump_save.gd \
##       -- --file=/abs/path/gen_000291.sav [--keys=city,economy] [--raw]
##
## Read-only. It never opens `user://` and never writes.

func _initialize() -> void:
	var path := ""
	var raw := false
	var keys: Array[String] = []
	for arg_variant: Variant in OS.get_cmdline_user_args():
		var arg := String(arg_variant)
		if arg.begins_with("--file="):
			path = arg.substr(7)
		elif arg.begins_with("--keys="):
			for part in arg.substr(7).split(","):
				keys.append(String(part))
		elif arg == "--raw":
			raw = true
	if path == "":
		printerr("dump_save: --file=PATH is required")
		quit(2)
		return
	var file := FileAccess.open_compressed(path, FileAccess.READ,
			FileAccess.COMPRESSION_ZSTD)
	if file == null:
		printerr("dump_save: cannot open %s (%d)" % [path, FileAccess.get_open_error()])
		quit(2)
		return
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		printerr("dump_save: body is not a JSON object")
		quit(2)
		return
	var envelope: Dictionary = parsed
	if raw:
		print(text)
		quit(0)
		return
	print("--- envelope keys: %s" % str(envelope.keys()))
	for key: Variant in envelope:
		var section: Variant = envelope[key]
		if not (section is Dictionary):
			print("%s = %s" % [str(key), str(section)])
			continue
		var block: Dictionary = section
		print("[%s] section_version=%s  keys=%d"
				% [str(key), str(block.get("section_version", "?")),
				block.keys().size()])
	var city: Dictionary = envelope.get("city", {})
	print("")
	print("--- city.goals: %s" % JSON.stringify(city.get("goals", {})))
	print("--- city.progression: %s" % JSON.stringify(city.get("progression", {})))
	var economy: Dictionary = city.get("economy", {})
	if economy.is_empty():
		economy = envelope.get("economy", {})
	print("--- economy: %s" % JSON.stringify(economy).substr(0, 2000))
	for key: String in keys:
		print("--- %s: %s" % [key, JSON.stringify(city.get(key, envelope.get(key, null)))
				.substr(0, 4000)])
	quit(0)
