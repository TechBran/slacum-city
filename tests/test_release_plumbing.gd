extends SimTest
## Doc 13 §2.7 / §2.10 / §2.12 — the release contract, checked without building.
##
## `tools/make_release.sh` verifies the *artefacts*: it opens the keystore, reads
## the permissions back out of the AAB and the APK, and checks every LOAD segment
## for 16 KB alignment. That takes two Gradle builds and about a minute, and it
## needs signing secrets in the environment, so it cannot run in this suite.
##
## What can run here is everything the artefacts are made **from**: the presets,
## the version arithmetic, the plugin's manifest, and the promise that no secret
## has crept into a committed file. Those are exactly the things a hurried commit
## breaks, and each of them fails a store submission hours after the fact — a
## version code that did not increment, an INTERNET permission that changes the
## Data Safety declaration, a keystore path pasted into a preset.
##
## The two halves meet at the permission list: it is written down once in doc 13
## §2.7, declared in the plugin's `AndroidManifest.xml`, asserted here against
## that file, and asserted again by `make_release.sh` against the built binary.

const PROJECT_GODOT := "res://project.godot"
const PRESETS := "res://export_presets.cfg"
const PLUGIN_MANIFEST := "res://android/plugins/slacum_native/src/main/AndroidManifest.xml"
const MAKE_RELEASE := "res://tools/make_release.sh"
const SETUP_ANDROID := "res://tools/setup_android.sh"
const STORE_ASSETS := "res://tools/gen_store_assets.py"
const AAB_BADGING := "res://tools/aab_badging.py"
## The tracked plugin binary. It is packaged VERBATIM by the exporter, so a
## symbol that is not in this file is a symbol no APK can call.
const PLUGIN_AAR := "res://android/plugins/slacum_native.aar"
const PLUGIN_SOURCE := ("res://android/plugins/slacum_native/src/main/java/"
		+ "com/slacumcity/nativeplugin/SlacumNative.kt")
const REFRESH_PIN := "res://game/render/refresh_pin.gd"
## Where the `.class` files sit inside the AAR, and inside the jar inside it.
const AAR_CLASSES_JAR := "classes.jar"
const PLUGIN_CLASS := "com/slacumcity/nativeplugin/SlacumNative.class"

## The pinned set is DERIVED from the Kotlin's own `@UsedByGodot` annotations
## rather than hand-listed, so a method added to the plugin is pinned by being
## written. These four are the sentinels: a source-parse fault that returned an
## empty list would otherwise make the whole gate vacuous, which is the failure
## mode the suite has already been bitten by once (`test_ui_strings`'s
## `alerts.events`). One per capability, oldest to newest.
const SENTINEL_SYMBOLS: Array[String] = [
	"elapsed_realtime_ms",
	"thermal_status",
	"launch_args",
	"set_frame_rate",
	# Wave 18, PA-14: the `POST_NOTIFICATIONS` flow got its first GDScript caller
	# this wave, which makes these three load-bearing for the first time — until
	# now no code path reached them, so a stale AAR that had dropped one would
	# have failed nothing. They are named individually rather than left to the
	# `declared` sweep because THIS list is what survives a parse fault.
	"permission_state",
	"request_notification_permission",
	"open_app_notification_settings",
]

## doc 13 §2.7, and this list is the whole release manifest.
const EXPECTED_PERMISSIONS: Array[String] = [
	"android.permission.POST_NOTIFICATIONS",
	"android.permission.RECEIVE_BOOT_COMPLETED",
	"android.permission.VIBRATE",
	"android.permission.WAKE_LOCK",
]

## Every one of these would change the Play Data Safety answer, the store
## listing's eligibility, or both.
const FORBIDDEN_PERMISSIONS: Array[String] = [
	"android.permission.INTERNET",
	"android.permission.SCHEDULE_EXACT_ALARM",
	"android.permission.USE_EXACT_ALARM",
	"android.permission.ACCESS_NETWORK_STATE",
	"android.permission.QUERY_ALL_PACKAGES",
	"android.permission.FOREGROUND_SERVICE",
	"com.google.android.gms.permission.AD_ID",
]


static func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func _presets() -> String:
	return _read(PRESETS)


## Every `key=value` occurrence in export_presets.cfg, as strings.
static func _values(text: String, key: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for line: String in text.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with(key + "="):
			out.append(trimmed.substr(key.length() + 1).strip_edges().trim_prefix("\"")
					.trim_suffix("\""))
	return out


func _project_version() -> String:
	for line: String in _read(PROJECT_GODOT).split("\n"):
		if line.begins_with("config/version="):
			return line.substr("config/version=".length()).strip_edges().trim_prefix("\"") \
					.trim_suffix("\"")
	return ""


# ===========================================================================
# Version
# ===========================================================================

func test_the_version_code_is_the_documented_function_of_the_version_name() -> void:
	# doc 13 §2.10: major*10000 + minor*100 + patch. It is a formula rather than
	# a number so that two people bumping two files can never disagree, and so
	# that a code can never go backwards — which Play refuses, permanently.
	var version := _project_version()
	assert_ne(version, "", "project.godot carries application/config/version")
	var parts := version.split(".")
	assert_eq(parts.size(), 3, "semantic version: %s" % version)
	var expected := int(parts[0]) * 10000 + int(parts[1]) * 100 + int(parts[2])

	var names := _values(_presets(), "version/name")
	var codes := _values(_presets(), "version/code")
	assert_true(names.size() >= 3, "one preset per output (debug, AAB, test APK)")
	assert_eq(names.size(), codes.size())
	for i in names.size():
		assert_eq(names[i], version,
				"preset %d's version/name matches project.godot" % i)
		assert_eq(int(codes[i]), expected,
				"preset %d's version/code is %d" % [i, expected])


func test_this_release_is_0_4_0() -> void:
	# Pinned deliberately: the release plumbing landed at 0.4.0 / 400, and a
	# silent revert of either is the kind of thing that is only noticed by a
	# rejected upload.
	assert_eq(_project_version(), "0.4.0")
	for code: String in _values(_presets(), "version/code"):
		assert_eq(int(code), 400)


# ===========================================================================
# Presets
# ===========================================================================

func test_three_presets_one_per_output() -> void:
	var text := _presets()
	var names := _values(text, "name")
	assert_true(names.has("Android"), "the debug APK the dev loop installs")
	assert_true(names.has("Android Play AAB"), "the bundle Play accepts")
	assert_true(names.has("Android Test APK"),
			"a release-signed APK: every perf and battery number is measured on "
			+ "release code, never on a debug build")
	var paths := _values(text, "export_path")
	assert_true(paths.has("build/slacum-debug.apk"))
	assert_true(paths.has("build/slacum-release.aab"))
	assert_true(paths.has("build/slacum-release.apk"))
	# Exactly one bundle: `export_format=1` is AAB, 0 is APK.
	var formats := _values(text, "gradle_build/export_format")
	var bundles := 0
	for value: String in formats:
		if int(value) == 1:
			bundles += 1
	assert_eq(bundles, 1, "one preset produces a bundle, and it is the AAB one")


func test_every_preset_ships_the_plugin_and_the_gradle_build() -> void:
	# A plugin that is present but not listed is silently left OUT of the build
	# (doc 13 §10.2 — it happened once and the APK simply had no plugin in it).
	# Without the plugin there are no notifications, no channels and no alarms,
	# and nothing about the build would say so.
	var text := _presets()
	var enabled := _values(text, "plugins/SlacumNative")
	assert_eq(enabled.size(), 3, "every preset names the plugin")
	for value: String in enabled:
		assert_eq(value, "true")
	for value: String in _values(text, "gradle_build/use_gradle_build"):
		assert_eq(value, "true", "the plugin requires the Gradle template")
	for value: String in _values(text, "gradle_build/min_sdk"):
		assert_eq(int(value), 29, "minSdk 29 — addThermalStatusListener's floor")
	for value: String in _values(text, "package/signed"):
		assert_eq(value, "true")


func test_arm64_only_on_every_preset() -> void:
	# Play has required 64-bit since 2019 and every Vulkan-capable Android 10+
	# device is arm64, so armeabi-v7a is ~35 MB of payload for nobody.
	var text := _presets()
	for key: String in ["architectures/armeabi-v7a", "architectures/x86",
			"architectures/x86_64"]:
		for value: String in _values(text, key):
			assert_eq(value, "false", "%s is off" % key)
	for value: String in _values(text, "architectures/arm64-v8a"):
		assert_eq(value, "true")


func test_no_secret_can_live_in_a_committed_file() -> void:
	# Godot 4.7 has no keystore fields in the preset at all, which is the
	# strongest possible version of this rule: there is no field to leak through.
	# The assertion stands anyway, because a future engine could add them back.
	var text := _presets()
	for key: String in ["keystore/release", "keystore/release_user",
			"keystore/release_password", "keystore/debug_password"]:
		assert_false(text.contains(key + "=\"") and not text.contains(key + "=\"\""),
				"%s carries no value in a committed file" % key)
	var script := _read(MAKE_RELEASE)
	assert_true(script.contains("GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD"),
			"the release script reads the password from the environment")
	assert_false(script.contains("GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD=\""),
			"…and never assigns one")
	# A keystore inside the working tree is a compromised keystore, whatever
	# .gitignore says about it today.
	assert_eq(str(_files_matching("res://", ".keystore")), "[]",
			"no keystore anywhere in the repository")
	assert_eq(str(_files_matching("res://", ".jks")), "[]")


static func _files_matching(root: String, suffix: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := root.path_join(entry)
		if dir.current_is_dir():
			if entry != "." and entry != ".." and entry != ".godot":
				out.append_array(_files_matching(full, suffix))
		elif entry.ends_with(suffix):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return out


# ===========================================================================
# The plugin manifest — doc 13 §2.7's four permissions
# ===========================================================================

func test_the_plugin_declares_exactly_the_four_permissions() -> void:
	var manifest := _read(PLUGIN_MANIFEST)
	assert_ne(manifest, "", "the plugin ships its own manifest")
	var declared: Array[String] = []
	var regex := RegEx.new()
	regex.compile("<uses-permission[^>]*android:name=\"([^\"]+)\"")
	for match in regex.search_all(manifest):
		declared.append(match.get_string(1))
	declared.sort()
	var expected := EXPECTED_PERMISSIONS.duplicate()
	expected.sort()
	assert_eq(declared, expected, "the release manifest is these four and no more")


## doc 13 §2.7's four, as `export_presets.cfg` spells them.
## `"permissions/" + PERMISSION.to_lower()` is the exporter's own option key, and
## all four are in Godot 4.7.2's built-in table, so none of them needs
## `custom_permissions`.
const EXPECTED_PRESET_PERMISSION_KEYS: Array[String] = [
	"permissions/post_notifications",
	"permissions/receive_boot_completed",
	"permissions/vibrate",
	"permissions/wake_lock",
]


func test_every_preset_requests_exactly_the_four_permissions() -> void:
	# THE SECOND SOURCE, and the gate this file did not have for it.
	# `test_the_plugin_declares_exactly_the_four_permissions` checks what the
	# plugin manifest AUTHORS; nothing checked what a preset REQUESTS. Both reach
	# the APK — measured on four locally built debug APKs, `aapt2 dump
	# permissions`: AAR-only → 4, preset-only → 4, both → 4, NEITHER → 0 with the
	# plugin and both receivers still merged (report 98 §29 RR-70). That last row
	# is the reading the 2026-08-21 Fold session took off the phone, and its cause
	# was a stale AAR, not the preset.
	# So the preset flags are redundancy, not the fix: with them a stale or
	# hand-edited AAR degrades from "silently drops a runtime permission" to
	# "nothing at all". Nothing headless can catch a stale binary — this catches
	# the second source going missing, which is the half that CAN be caught here.
	var text := _presets()
	for key: String in EXPECTED_PRESET_PERMISSION_KEYS:
		var values := _values(text, key)
		assert_eq(values.size(), 3,
				"%s is set on all three presets — the debug APK is the one the dev "
				% key + "loop installs, and an untested permission set is not a test")
		for value: String in values:
			assert_eq(value, "true", "%s is requested, not merely present" % key)
	# …and nothing else is. A fifth permission cannot arrive without renaming it
	# here, which is the same promise `custom_permissions` already carries.
	var requested: Array[String] = []
	for line: String in text.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with("permissions/") and trimmed.ends_with("=true"):
			var key := trimmed.substr(0, trimmed.length() - 5)
			if not requested.has(key):
				requested.append(key)
	requested.sort()
	var expected := EXPECTED_PRESET_PERMISSION_KEYS.duplicate()
	expected.sort()
	assert_eq(requested, expected, "the presets request these four and no others")


func test_the_forbidden_permissions_are_absent() -> void:
	# INTERNET is the load-bearing one: its absence is the entire reason the Play
	# Data Safety form can say "no data collected". The two exact-alarm
	# permissions are Play-restricted to alarm clocks and calendars, and asking
	# for either risks the listing — which is why every alarm in this game is
	# inexact and why the copy never states a time.
	var manifest := _read(PLUGIN_MANIFEST)
	for permission: String in FORBIDDEN_PERMISSIONS:
		assert_false(manifest.contains("\"%s\"" % permission),
				"%s is not declared" % permission)
	# …and no preset smuggles one in through custom_permissions either.
	for value: String in _values(_presets(), "permissions/custom_permissions"):
		assert_eq(value, "PackedStringArray()",
				"presets add no permissions of their own")


func test_the_plugin_registers_itself_and_its_two_receivers() -> void:
	var manifest := _read(PLUGIN_MANIFEST)
	assert_true(manifest.contains("org.godotengine.plugin.v2.SlacumNative"),
			"v2 meta-data registration — the .gdap does not do this")
	assert_true(manifest.contains("com.slacumcity.nativeplugin.AlarmReceiver"),
			"the receiver that posts a scheduled notification with the app dead")
	assert_true(manifest.contains("com.slacumcity.nativeplugin.BootReceiver"),
			"…and the one that re-arms the schedule after a reboot")
	assert_true(manifest.contains("android.intent.action.BOOT_COMPLETED"))
	assert_false(manifest.contains("android:exported=\"true\""),
			"nothing outside the package may fire a Slacum notification")


# ===========================================================================
# The scripts
# ===========================================================================

func test_the_release_tooling_is_present_and_documented() -> void:
	for path: String in [MAKE_RELEASE, SETUP_ANDROID, STORE_ASSETS, AAB_BADGING]:
		assert_true(FileAccess.file_exists(path), "%s exists" % path)
		assert_true(_read(path).length() > 400, "%s is not a stub" % path)
	var script := _read(MAKE_RELEASE)
	for gate: String in ["16 KB", "aapt2", "sha256", "version code",
			"--init-keystore"]:
		assert_true(script.contains(gate),
				"tools/make_release.sh still covers: %s" % gate)


## The device tooling's own footgun, found on hardware 2026-08-21. It gets a test
## because it cost a session, left no trace in any output, and reads as a
## hardware problem rather than a script problem.
##
##     printf '%s' "$big" | grep -q PATTERN     # under set -o pipefail
##
## reports FAILURE when the pattern MATCHES. `grep -q` exits at the first hit,
## the writer takes SIGPIPE and dies 141, and `pipefail` promotes the writer's
## status over grep's success. It only fires once the data outgrows the 64 KB
## pipe buffer, so it passes every small-input test and fails on every real
## `dumpsys window` (~200 KB) — which is how `run_matrix.sh` came to print
## "REFUSING TO RUN: the phone is LOCKED" on an unlocked, awake, focused phone
## 100 % of the time, and `cap_pose.sh` came to stamp good captures
## CONTAMINATED at random.
##
## Safe forms this must NOT flag: `grep -q PATTERN FILE` (no pipe at all) and
## `grep -q PATTERN <<<"$var"` (a herestring, which bash backs with a temp file).
## The `||` in `a || grep -q b` is also not a pipe, and a naive `| *grep -q`
## search does flag it — hence the lookarounds.
func test_no_shell_tool_pipes_into_grep_q_under_pipefail() -> void:
	var pipe_into_grep_q := RegEx.new()
	# A single `|` — not `||`, not `|&` — then `grep -q`.
	pipe_into_grep_q.compile("(?<!\\|)\\|(?![|&])\\s*grep\\s+-q")

	var dir := DirAccess.open("res://tools")
	assert_true(dir != null, "res://tools is readable")
	var checked := 0
	for name: String in dir.get_files():
		if not name.ends_with(".sh"):
			continue
		var text := _read("res://tools/%s" % name)
		if not text.contains("pipefail"):
			continue
		checked += 1
		var line_no := 0
		for line: String in text.split("\n"):
			line_no += 1
			var trimmed := line.strip_edges()
			# Comments are where this bug is *explained*, so they must be exempt
			# or the documentation trips its own test.
			if trimmed.begins_with("#"):
				continue
			assert_true(pipe_into_grep_q.search(line) == null,
					("tools/%s:%d pipes into `grep -q` under `pipefail`; "
					+ "grep -q exits early, the writer takes SIGPIPE (141), and "
					+ "pipefail reports a MATCH as a failure. Use bash `==`, a "
					+ "herestring, or `grep -c` and compare.")
					% [name, line_no])
	assert_true(checked >= 2,
			"at least the two device tools were scanned (got %d)" % checked)


func test_the_shell_still_refuses_to_die_on_the_back_button() -> void:
	# Not release plumbing as such, but the one project setting whose loss would
	# make every notification and every autosave in this document pointless: with
	# quit_on_go_back on, the back button destroys the process before the pause
	# sequence has saved anything (doc 13 §2.2).
	var project := _read(PROJECT_GODOT)
	assert_true(project.contains("config/quit_on_go_back=false"))
	assert_true(project.contains("window/energy_saving/keep_screen_on=true"))
	assert_true(project.contains("frame_pacing/android/enable_frame_pacing=true"))



# ===========================================================================
# The plugin binary — the stale-AAR gate
# ===========================================================================

## Byte search over a `PackedByteArray`. `find()` on the first byte then a
## comparison, rather than a decode: a `.class` file is not text and
## `get_string_from_utf8()` on one is a lie that happens to be searchable.
static func _bytes_contain(haystack: PackedByteArray, needle: String) -> bool:
	var pattern := needle.to_ascii_buffer()
	var size := pattern.size()
	if size == 0 or haystack.size() < size:
		return false
	var at := haystack.find(pattern[0], 0)
	while at >= 0 and at + size <= haystack.size():
		var hit := true
		for i in range(1, size):
			if haystack[at + i] != pattern[i]:
				hit = false
				break
		if hit:
			return true
		at = haystack.find(pattern[0], at + 1)
	return false


## The AAR's `SlacumNative.class`, or an empty array with the reason logged.
## Two nested zips: the AAR holds `classes.jar` and the jar holds the classes.
## `ZIPReader` only opens a path, so the inner jar is spilled to `user://` —
## which the runner has already moved to a per-process directory (RR-57).
func _plugin_class_bytes() -> PackedByteArray:
	var aar := ZIPReader.new()
	if aar.open(ProjectSettings.globalize_path(PLUGIN_AAR)) != OK:
		return PackedByteArray()
	var jar_bytes := aar.read_file(AAR_CLASSES_JAR)
	aar.close()
	if jar_bytes.is_empty():
		return PackedByteArray()
	var spill := "user://slacum_native_classes.jar"
	var out := FileAccess.open(spill, FileAccess.WRITE)
	if out == null:
		return PackedByteArray()
	out.store_buffer(jar_bytes)
	out.close()
	var jar := ZIPReader.new()
	if jar.open(ProjectSettings.globalize_path(spill)) != OK:
		return PackedByteArray()
	var class_bytes := jar.read_file(PLUGIN_CLASS)
	jar.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(spill))
	return class_bytes


## Every `@UsedByGodot` method the plugin declares, read out of the Kotlin.
## That annotation is the whole contract: it is what makes a method visible to
## `Engine.get_singleton("SlacumNative")`, so it is exactly the set the AAR owes.
func _used_by_godot() -> Array[String]:
	var kotlin := _read(PLUGIN_SOURCE)
	var declaration := RegEx.new()
	declaration.compile("@UsedByGodot\\s+fun\\s+([a-zA-Z_][a-zA-Z0-9_]*)\\s*\\(")
	var out: Array[String] = []
	for match in declaration.search_all(kotlin):
		var name := match.get_string(1)
		if not out.has(name):
			out.append(name)
	return out


func test_the_tracked_aar_carries_every_symbol_the_plugin_declares() -> void:
	# This is the ONLY check in the repository that can tell a stale
	# `slacum_native.aar` from a fresh one, and a stale one is invisible in every
	# other way: the export succeeds, the APK installs, the game runs, and each
	# `has_method()` guard in `game/android_native.gd` quietly answers false. It
	# is what `.gitignore`'s own note about this file promises and what
	# `tools/run_matrix.sh step_build_check` does on device, one layer earlier.
	assert_true(FileAccess.file_exists(PLUGIN_AAR),
			"the plugin AAR is TRACKED (see .gitignore); tools/build_native_plugin.sh "
			+ "regenerates it and it is committed WITH the Kotlin change")
	var declared := _used_by_godot()
	assert_true(declared.size() >= 16,
			"the Kotlin still declares its entry points with @UsedByGodot (got %d)"
			% declared.size())
	for sentinel: String in SENTINEL_SYMBOLS:
		assert_true(declared.has(sentinel),
				"%s is still an @UsedByGodot entry point" % sentinel)
	var bytes := _plugin_class_bytes()
	assert_true(bytes.size() > 4096,
			"SlacumNative.class read out of the AAR (got %d bytes)" % bytes.size())
	for symbol: String in declared:
		# A method name survives Kotlin compilation into the class file's constant
		# pool verbatim, which is what makes this checkable with no device, no dex
		# tool and no JVM.
		assert_true(_bytes_contain(bytes, symbol),
				("`%s` is compiled into android/plugins/slacum_native.aar. "
				+ "If this fails the AAR is older than the Kotlin beside it: run "
				+ "tools/build_native_plugin.sh and commit the result.") % symbol)
	# The negative control. Without it a scan that matched everything — a decode
	# fault, an empty needle, a wrong-file read — would pass this test silently.
	assert_false(_bytes_contain(bytes, "set_frame_rate_that_never_shipped"),
			"the byte scan can still say no")


func test_every_symbol_the_bridge_probes_for_is_one_the_plugin_declares() -> void:
	# `AndroidNative` probes the plugin BY NAME through `has_method("…")` so that
	# an older AAR degrades instead of throwing. That guard is also a place a typo
	# can hide for ever: a misspelt probe answers false on every device and looks
	# exactly like an old build. Nothing checked the spelling until now.
	var bridge := _read("res://game/android_native.gd")
	var probe := RegEx.new()
	probe.compile("has_method\\(\"([a-z_]+)\"\\)")
	var probed: Array[String] = []
	for match in probe.search_all(bridge):
		var name := match.get_string(1)
		if not probed.has(name):
			probed.append(name)
	assert_true(probed.size() >= 12, "the bridge still probes by name (got %d)"
			% probed.size())
	var declared := _used_by_godot()
	for name: String in probed:
		assert_true(declared.has(name),
				("game/android_native.gd probes for `%s`; SlacumNative.kt declares "
				+ "no such @UsedByGodot method, so that probe can only ever "
				+ "answer false") % name)


# ===========================================================================
# The refresh pin — the rule that lives in two languages
# ===========================================================================

## `RefreshPin.choose_refresh_hz()` is the rule and the suite tests it;
## `SlacumNative.modeFor()` is a Kotlin mirror of it, because the real chooser
## has to run against a `Display.Mode` that only exists on a device. Two copies
## of a rule drift, so this is the seam that says so out loud: neither copy may
## exist without naming the other, and the ordered clauses have to be present in
## the Kotlin in the order the GDScript tests assert them.
##
## What this can prove: that the mirror is still declared, still points at its
## source, and still spells the three clauses in order. What it cannot prove is
## that the Kotlin arithmetic agrees — only a device can, and report 98 §46's
## protocol is where that is read (`REFRESH … panel=` against `dumpsys display`).
func test_the_kotlin_mode_chooser_still_declares_itself_a_mirror() -> void:
	var kotlin := _read(PLUGIN_SOURCE)
	assert_ne(kotlin, "", "the plugin source is where the mirror lives")
	assert_true(kotlin.contains("RefreshPin.choose_refresh_hz()"),
			"the Kotlin names the GDScript rule it mirrors")
	assert_true(kotlin.contains("private fun modeFor("),
			"…and still has a chooser to mirror it with")
	var gdscript := _read(REFRESH_PIN)
	assert_true(gdscript.contains("SlacumNative.modeFor()"),
			"and the GDScript names the Kotlin copy back, so neither can be "
			+ "deleted or moved without the other showing up in the diff")
	# The three clauses, in order, in both files.
	for phrases: Array in [
			["integer multiple", "at or above", "fastest"],
	]:
		var at := -1
		for phrase: String in phrases:
			var next := kotlin.findn(phrase, at + 1)
			assert_true(next > at,
					"the Kotlin still states '%s' after the clause before it" % phrase)
			at = next
		at = -1
		for phrase: String in phrases:
			var next := gdscript.findn(phrase, at + 1)
			assert_true(next > at,
					"the GDScript still states '%s' in the same order" % phrase)
			at = next


func test_the_frame_rate_vote_is_version_guarded_with_a_stated_fallback() -> void:
	# minSdk is 29 and `Surface.setFrameRate` is API 30, so the guard is not
	# optional — an unguarded call is a `NoSuchMethodError` on the one tier the
	# device matrix calls "min spec" (doc 13 §7, tier C, API 29).
	var kotlin := _read(PLUGIN_SOURCE)
	assert_true(kotlin.contains("Build.VERSION_CODES.R"),
			"the API-30 floor is named")
	assert_true(kotlin.contains("FRAME_RATE_COMPATIBILITY_FIXED_SOURCE"),
			"content that has capped itself declares a FIXED source rate")
	assert_true(kotlin.contains("preferredDisplayModeId"),
			"…and the window is told which mode to sit in")
	var gradle := _read("res://android/plugins/slacum_native/build.gradle")
	assert_true(gradle.contains("minSdk 29"),
			"the guard is against THIS floor; if the floor moves the guard is dead code")
