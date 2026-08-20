class_name UserDirIsolation
extends RefCounted
## Per-process `user://`, decided by the runner instead of by the invocation.
##
## **The fault this closes.** `user://` is keyed on `application/config/name`,
## which every worktree and every checkout of this project shares, so two agents
## running tests in two worktrees both write
## `~/.local/share/godot/app_userdata/Slacum City/saves` — and the save-service
## tests write real generations into real slots. Measured 2026-08-20: with a
## sibling suite running, `test_save_service.gd` failed
## `test_a_ruined_generation_falls_through_to_the_one_behind_it` and *aborted*
## `test_a_pinned_checkpoint_is_never_swept` on a missing manifest key. The
## documented workaround was an environment variable on the command line, which
## is not a fix — it is a thing to forget.
##
## **The mechanism, and why it works after boot.** Both switches below are
## re-read by `OS.get_user_data_dir()` on EVERY call — measured on 4.7.2, which
## is the whole reason this can live in `_initialize()` rather than in a shell:
##
##   * `application/config/use_custom_user_dir` + `custom_user_dir_name` supply
##     the per-process NAME, and work on every platform.
##   * `XDG_DATA_HOME` moves the ROOT (Linux/BSD; ignored elsewhere), so a run
##     nobody asked to keep never touches the developer's real `~/.local/share`.
##
## Both are applied. Either alone keeps two runs apart; together they also keep
## the artefacts out of the way. **Godot creates the user directory exactly once,
## at boot**, so the new one has to be made here — without the `mkdir` every
## `FileAccess.open("user://…", WRITE)` returns `ERR_FILE_CANT_OPEN` (7), which
## is a far more confusing failure than the collision it replaces.
##
## Two environment variables, both optional:
##   `SLACUM_TEST_USER_DIR`       pin the root instead of using the temp dir
##                                (an `XDG_DATA_HOME` the caller already set is
##                                honoured the same way — the per-process
##                                directory is made underneath it, so two runs
##                                sharing one root are still safe)
##   `SLACUM_TEST_KEEP_USER_DIR`  any non-empty value: do not sweep it at exit
##
## Lives in `tests/` and not in `sim/`: it touches `OS`, `DirAccess` and
## `ProjectSettings`, none of which `sim/` may see (constitution §3). It is not
## named `test_*.gd`, so the runner's own discovery walk never picks it up.

## Pin the isolation root — for reading a failing run's saves afterwards.
const USER_DIR_ENV := "SLACUM_TEST_USER_DIR"
## Keep the isolation root at exit rather than sweeping it.
const KEEP_ENV := "SLACUM_TEST_KEEP_USER_DIR"
## Every directory this class creates or removes carries this in its name. The
## sweep refuses to touch a path that does not, which is the guard that keeps a
## mis-set `SLACUM_TEST_USER_DIR` from deleting somebody's home directory.
const DIR_MARK := "slacum-suite-"

var root := ""
var user_dir := ""


## Point `user://` at a directory no other process shares, and return self so a
## caller can `UserDirIsolation.new().begin()` in one line.
func begin() -> UserDirIsolation:
	var dir_name := DIR_MARK + str(OS.get_process_id())
	var pinned := OS.get_environment(USER_DIR_ENV)
	var inherited := OS.get_environment("XDG_DATA_HOME")
	if pinned != "":
		root = pinned
	elif inherited != "":
		# The caller already isolated by hand (the pre-Wave-12 invocation).
		# Honour it as the ROOT and still take a private directory underneath.
		root = inherited
	else:
		# One shared parent under the temp dir, one private child per process:
		# `/tmp/slacum-suite/slacum-suite-<pid>`. Only the child is swept, so two
		# concurrent runs never race on the parent.
		root = OS.get_temp_dir().path_join("slacum-suite")
	DirAccess.make_dir_recursive_absolute(root)
	OS.set_environment("XDG_DATA_HOME", root)
	ProjectSettings.set_setting("application/config/use_custom_user_dir", true)
	ProjectSettings.set_setting("application/config/custom_user_dir_name", dir_name)
	user_dir = OS.get_user_data_dir()
	# A crashed earlier run that happened to hold this pid must not seed this one.
	remove_tree(user_dir)
	DirAccess.make_dir_recursive_absolute(user_dir)
	return self


## Remove the private directory. The shared parent is left alone — a sibling run
## may be inside it.
func end() -> void:
	if OS.get_environment(KEEP_ENV) != "":
		print("kept %s (%s is set)" % [user_dir, KEEP_ENV])
		return
	remove_tree(user_dir)


## Recursive delete, with the one guard that matters: a path this class did not
## name is left alone. `SLACUM_TEST_USER_DIR=$HOME` must cost a printed refusal,
## not a home directory.
static func remove_tree(path: String) -> void:
	if path == "" or not path.contains(DIR_MARK):
		printerr("user-dir isolation: refusing to remove %s — not a %s* path"
				% [path, DIR_MARK])
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var child := path.path_join(entry)
		if dir.current_is_dir():
			remove_tree(child)
		else:
			DirAccess.remove_absolute(child)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)
