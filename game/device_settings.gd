class_name DeviceSettings
extends RefCounted
## `user://settings.cfg` — the one file that is not in any save slot
## (constitution §2 amendment #3, doc 08 §2.5, report 98 C-03).
##
## Four documents write into it and none of them owns it: doc 08 the notification
## preferences, doc 11 the graphics preset, doc 12 the accessibility rows, doc 13
## the permission-flow bookkeeping. So the file is a **section registry** rather
## than one owner's format, and this class is the whole of the I/O: read one
## section, write one section, and never touch a section that belongs to somebody
## else. `SettingsModel` uses it for `settings`, `PermissionFlow` for
## `permission`, and neither has to know the other exists.
##
## **Why it is not a save section.** The save ladder migrates, rolls back to a
## checkpoint and is deleted with the city. A player who turned notifications off
## must stay off across all three (doc 08 §2.13.4), and a text scale that a
## player needs in order to READ the game must not depend on which slot they are
## in. That is the entire argument, and it is why this file is never versioned
## against the envelope and never repaired by the load gate: a settings key that
## cannot be validated is dropped and its default kept, which is the same
## migration policy doc 12 §3.2 states for the per-city snapshot.
##
## **The write is atomic** — `tmp` then rename, exactly like doc 08's generation
## commit. A settings write happens on every row tap, including the tap the
## player makes on their way out of the app, so a torn file here is not a
## hypothetical; a torn file that came up empty would silently restore the
## notification master switch to ON.
##
## Merge-read-write, never write-whole: `write_section` re-reads the file first,
## so a `permission` write cannot lose a `settings` change made a frame earlier.

const DEFAULT_PATH := "user://settings.cfg"

## Doc 12's rows, by their `data/ui.json` key.
const SECTION_SETTINGS := "settings"
## Doc 13 §3.2 `android.permission` — `asked_count`, `last_asked_unix`,
## `reprompt_count`. Device-scoped for the same reason the rows are: Android's
## two chances are spent per INSTALL, not per city, and a player who deleted a
## city has not earned a third prompt.
const SECTION_PERMISSION := "permission"


## The section as a plain Dictionary, `{}` when the file or the section is
## absent — which is first launch, and is not an error.
static func read_section(path: String, section: String) -> Dictionary:
	var cfg := _open(path)
	var out: Dictionary = {}
	if not cfg.has_section(section):
		return out
	var names: PackedStringArray = cfg.get_section_keys(section)
	var sorted: Array = []
	for name: String in names:
		sorted.append(name)
	sorted.sort()
	for name: Variant in sorted:
		out[str(name)] = cfg.get_value(section, str(name))
	return out


## Replace one section and leave every other one exactly as it was. Keys are
## written in sorted order so the file is byte-stable across runs (constitution
## §5) and a diff of it reads.
static func write_section(path: String, section: String, block: Dictionary) -> bool:
	var cfg := _open(path)
	if cfg.has_section(section):
		cfg.erase_section(section)
	var names: Array = block.keys()
	names.sort()
	for name: Variant in names:
		cfg.set_value(section, str(name), block[name])
	return _commit(cfg, path)


## True when the file exists at all — the "has this device ever answered?" test
## the shell needs before it decides a first launch is a first launch.
static func exists(path: String = DEFAULT_PATH) -> bool:
	return FileAccess.file_exists(path)


static func _open(path: String) -> ConfigFile:
	var cfg := ConfigFile.new()
	# ERR_FILE_NOT_FOUND leaves `cfg` empty, which is exactly first launch. A
	# PARSE error leaves it empty too, and that is deliberate: a settings file
	# somebody hand-edited into nonsense costs the player their preferences, and
	# nothing else — it must never cost them the launch.
	var err := cfg.load(path)
	if err != OK and err != ERR_FILE_NOT_FOUND:
		push_warning("[settings] %s unreadable (%d); starting from defaults" % [path, err])
	return cfg


static func _commit(cfg: ConfigFile, path: String) -> bool:
	var tmp := path + ".tmp"
	var err := cfg.save(tmp)
	if err != OK:
		push_warning("[settings] cannot write %s (%d)" % [tmp, err])
		return false
	var moved := DirAccess.rename_absolute(tmp, path)
	if moved != OK:
		push_warning("[settings] cannot commit %s (%d)" % [path, moved])
		DirAccess.remove_absolute(tmp)
		return false
	return true
