class_name UIRoot
extends CanvasLayer
## The UI scaffold of doc 12 §4.1 — SafeArea, the layer stack, the Android back
## stack, the one Theme, and the switchboard the screens hang off.
##
##     UIRoot (CanvasLayer, layer=10)
##     └── SafeArea (MarginContainer)
##         ├── MarkerLayer (Control, PASS)   projected world pins + selection ring
##         ├── HUDLayer    (CityHUD, IGNORE) TopBar / LeftRail / OverlayRail / AlertStack
##         ├── PanelLayer  (Control, IGNORE) BuildingPanel, AlertsCenter,
##         │                                  IncidentDrawer, (LandPanel…)
##         ├── SheetLayer  (Control, IGNORE) BuildSheet, PlacementBar, UnitPicker
##         ├── TitleLayer  (Control, STOP while the front door is up) TitleScreen
##         ├── ModalLayer  (Control, STOP when populated) SettingsSheet, SaveLoadSheet,
##         │                                              PauseMenu, CityDashboard,
##         │                                              AwayReport
##         └── CoachLayer  (Control, STOP when hard-gated)
##     └── ToastLayer (CanvasLayer, layer=20)
##
## `TitleLayer` sits **above the city deck and below the modals**, which is what
## S0 actually is: the front door covers the HUD, the panels and the sheets, and
## SETTINGS opened *from* the door covers the door. It is also the one screen
## this class never opens on its own — see `present_title()`.
##
## The screens own their own logic; this class only brings them up with one
## shared `UIConfig`, routes the few cross-screen intents (HUD ☰ → pause menu,
## pause menu → settings / saves) and **re-emits** everything the shell needs on
## its own signals, so `game/main.gd` connects to one object rather than six.
##
## Container `Control`s are `mouse_filter = IGNORE`; only leaf widgets and modal
## scrims are `STOP`. That is what guarantees an unconsumed touch falls through
## to `TouchRouter._unhandled_input` → `GestureRecognizer` → `CameraState`, and
## it is why the camera never has to inspect UI rects.
##
## All layout maths that can be expressed without a Node lives in the static
## functions below, so the breakpoint solver and the back stack are headless.
##
## The offsets baked into `game/ui/ui_root.tscn` are editor-time scaffolding that
## mirror the §2.3 geometry table; the HUD work in P1-32 re-derives every rect
## from `data/ui.json.layout` at runtime, so no tunable is owned by the scene.

const CANVAS_LAYER_UI := 10
const CANVAS_LAYER_TOAST := 20
const BACK_TO_MINIMISE_WINDOW_S := 2.0

## Android's density model: 160 dpi == 1 dp per px.
const DP_BASE_DPI := 160.0
const CONTENT_SCALE_MIN := 1.0
const CONTENT_SCALE_MAX := 4.0

enum Breakpoint { COMPACT, REGULAR, WIDE }

## Back-stack verdicts, in doc 12 §2.2 priority order.
## S10's `state` row (PA-14). Spelled once, here, because three files address it.
const PERMISSION_ROW := "notification_permission"

const BACK_CLOSE_MODAL := &"close_modal"
## S0 is up. Not a rung of its own — it *removes* rungs: there is no city behind
## the front door, so sheet / panel / placement / selection cannot exist and back
## goes straight to the minimise pair. A modal opened FROM the title (S9) still
## wins, which is why this sits below `BACK_CLOSE_MODAL` and not above it.
const BACK_CLOSE_SHEET := &"close_sheet"
const BACK_CLOSE_PANEL := &"close_panel"
const BACK_CANCEL_PLACEMENT := &"cancel_placement"
const BACK_DESELECT := &"deselect"
const BACK_PROMPT_MINIMISE := &"prompt_minimise"
const BACK_MINIMISE := &"minimise"

signal back_requested(action: StringName)
signal breakpoint_changed(bp: Breakpoint)
signal safe_area_changed(rect: Rect2i)
signal ui_coverage_changed(coverage01: float)

## Re-emitted from the screens below, so `game/main.gd` connects to one object
## instead of six. Nothing here decides anything — the root is a switchboard.
signal overlay_changed(mode: StringName, index: int)   ## → doc 11 render mode
signal focus_requested(world_pos: Vector3)             ## alert tap → camera jump
signal settings_changed(key: StringName, value: Variant)
## PA-14: a `state` row was tapped — `notification_permission` today. Separate
## from `settings_changed` because nothing changed: the shell is being asked to
## do whatever the platform's current answer allows.
signal settings_action(key: StringName, action: StringName)
## The player answered the `POST_NOTIFICATIONS` rationale (doc 13 §2.7 steps
## 4–5). BACK does not emit this: a dismissal that was not an answer must not
## spend one of Android's two chances.
signal permission_answered(accepted: bool)
## PA-58: the player tapped the follow chip's ✕. The shell stops following.
signal follow_cancelled
signal save_slot_action(action: StringName, slot: int, result: Dictionary)
signal save_loaded(slot: int)                          ## the sim was replaced
signal pause_intent(paused: bool)                      ## → `set_paused` (doc 01)
signal quit_requested                                  ## save, then close the app
signal alerts_unread_changed(count: int)

## Wave-2 screens (S6/S7/S8/S11). Same contract: the root decides nothing, it
## routes the intent and re-emits it once, so `game/main.gd` still connects to
## one object.
signal dispatch_requested(unit_id: int, incident_id: int)   ## → cmd_dispatch_unit
signal incident_action(action: StringName, incident_id: int, value: Variant)
## Doc 05 §2.12's tactical pair, ALREADY ISSUED by the drawer (doc 93 §J1) — the
## same contract S4's `land_purchased` keeps. The shell listens only to re-read
## the city; nothing downstream has to run the command.
signal water_main_action(incident_id: int, edge_id: String, action: StringName,
		result: Dictionary)
signal handle_now_requested(incident_id: int)          ## away report → the incident
signal tax_applied(level: int, rate: float)            ## the sim already applied it
signal deeplink_requested(target: String)              ## dashboard row → overlay/…
signal away_dismissed

## Wave-3 screen (S12). The coach layer asks for the two things only the shell
## can do — move the camera, cook the tutorial transformer — and says when the
## tutorial ends. Everything the root can serve itself (open a sheet, open the
## drawer) it serves before re-emitting, so a shell that connects nothing still
## gets a tutorial that walks its own UI steps.
signal onboarding_action(action: StringName, payload: Dictionary)
signal onboarding_finished(skipped: bool)

## S4 (doc 12 §2.8). The sim has already answered by the time these fire — the
## shell re-reads it for the camera, the render state and the HUD.
signal land_purchased(block_id: String, result: Dictionary)
signal land_developed(block_id: String, result: Dictionary)
signal land_fix_requested(fix_target: Dictionary)
## S3's door, the one PA-23 gave the placement bar (Wave 18). Same `{kind, id,
## params}` payload and the same shell handler as the two panels' — a refusal
## that names a target the router can act on is the same event wherever it is
## raised, and placement is the first screen a new player ever gets one on.
signal build_fix_requested(fix_target: Dictionary)
## S18's three verbs (doc 12 §2.25, Wave 25 — RR-206/RR-207). `action` is
## `repair`, `upgrade` or `demolish`, and `result` is the sim's own
## `{ok, reason_code, payload}` — one signal for three verbs, because the shell
## does exactly one thing with all three: re-read the city. It replaces S5's
## retired `grid_upgraded` / `grid_demolished` (doc 12 D-115).
signal grid_action(action: StringName, component_id: String, result: Dictionary)
## A transformer was SELECTED — by a tap on its pad, by the one-row POWER
## summary on a building panel, or by a `Fix this →` on a `POWER_CAPACITY` row.
## The shell highlights the pad in the world (`PowerInfraView.set_selected`) and
## stamps `selected_entity_id`. `component_id` is `""` when the selection was
## cleared, or when an UNSERVED building's row was tapped and there is nothing to
## open — one signal, so the shell has one place to clear the highlight.
signal transformer_selected(component_id: String)
## A row of S18's customer list was tapped: go and look at that building.
signal transformer_customer_selected(sim_id: String, world_pos: Vector3)
## §2.13's progression moment: the city level moved, and this is the one place
## that knows it before the alert row does.
signal city_level_changed(level: int, unlocked: PackedStringArray)

## S0 (doc 12 §2.2). The front door's three intents. The root serves what it owns
## — `title_settings` opens S9 over the title before re-emitting — and leaves the
## other two to the shell, because only the shell holds the sim and the save
## service. **Nothing here dismisses the title**: a restore that fails must leave
## the player looking at the door, so `dismiss_title()` is the shell's call.
signal title_continue(slot: int)
## `slot` is the slot the OUTGOING city was preserved into, or −1 when nothing
## was preserved (`TitleModel.confirm_new_game`). It is NOT the new city's home:
## the autosave rotation is always the live city's, which is the whole reason the
## confirmation exists.
##
## `difficulty` is doc 03 §2.9's preset the new city is FOUNDED on — the shell
## passes it straight to `CitySim.found_with_difficulty()` before it captures the
## founding state. It rides this signal rather than being read back off the view
## because doc 93 §K1 makes it a one-shot: after the founding tick there is no
## second chance to ask, and no setter to ask with.
signal title_new_game(slot: int, difficulty: String)
signal title_settings

@export var apply_content_scale: bool = true

var config: UIConfig
var theme_resource: Theme

var safe_area: MarginContainer
var marker_layer: Control
var hud_layer: Control
var panel_layer: Control
var sheet_layer: Control
var modal_layer: Control
var coach_layer: Control
var title_layer: Control
var veil_layer: Control
var toast_layer: CanvasLayer

## The screens this scaffold carries. Bound in `_bind_nodes()`; any of them may
## be null in a trimmed scene, and every call site here checks.
var hud: CityHUD
var overlay_rail: OverlayRail
var alerts_center: AlertsCenter
var event_log: EventLog
## S16 (doc 12 §2.22). Third chip of the bottom-right rail and a side panel
## behind it, brought up with the shared config and NO provider — `game/main.gd`
## owns the sim, so it calls `bind_construction()` once it has one, and until it
## does this screen is an empty queue with no chip on screen at all.
var construction_queue: ConstructionQueueSheet
var settings_sheet: SettingsSheet
var permission_sheet: PermissionSheet
## S14 (doc 12 §2.19). Brought up with the shared config like every other
## screen and with NO model — `game/main.gd` owns the sim, so it calls
## `setup(cfg, GoalsModel.new(sim, cfg, controller))` once it has one.
var goals_sheet: GoalsSheet
## S17 (doc 12 §2.24) — doc 07 §2.7.7's preparation window (99-PA PA-26).
var storm_prep_sheet: StormPrepSheet
var save_load_sheet: SaveLoadSheet
var pause_menu: PauseMenu
var incident_drawer: IncidentDrawer
var unit_picker: UnitPickerSheet
var city_dashboard: CityDashboard
var away_report: AwayReportSheet
var build_sheet: BuildSheet
var onboarding: OnboardingFlow
## S5 (doc 12 §2.9). **Bound but never `setup()` here** — `game/main.gd` owns
## its controller and calls `setup()` itself. The root holds the reference only
## so it can wire S5's one door into S18 (`power_row_opened`), which is a
## panel-to-panel route on one layer and has no business travelling out to the
## shell and back (Wave 25, doc 12 D-115).
var building_panel: BuildingPanel
var land_panel: LandPanel
## S18 — the transformer panel (doc 12 §2.25, Wave 25). BUILT rather than
## authored, for the follow chip's reason and one more: the whole surface is one
## `_build_static()`, so a scene tree could only ever be a second description of
## it to keep in step by hand.
var transformer_panel: TransformerPanel
var toast_view: ToastView
## S0. Present in every mount and **closed in every one of them** — only
## `present_title()` opens it, and only `game/main.gd` calls that.
var title_screen: TitleScreen
## S15. Its own layer, above the coach layer: a half-restored city is not a city,
## and nothing — not even the tutorial — draws over the veil that says so.
var loading_veil: LoadingVeil
## Wave 17 (doc 12 §2.23): the right-edge tilt slider, on `HUDLayer`. It drives
## `camera_state`'s manual pitch axis and nothing else; the shell binds the
## camera with `bind_camera()` and the slider stays hidden until it has one.
var tilt_slider: TiltSlider
var follow_chip: FollowChip
## The camera this deck talks to — the tilt slider's axis, and (doc 12 §3.2 /
## D-9's moment) the `camera` block of the `ui` save section. Null in a mount
## that never bound one, in which case neither exists.
var camera_state: CameraState

## Doc 12 §2.14's one vibrator. Owned here because three screens fire cues and
## two settings rows gate them; a per-screen instance would be a per-screen
## opinion about what the player asked for.
var haptics: Haptics

## Wave 14's payday model. It has no screen of its own — a collect is felt on
## the HUD chip, the toast surface, the coach mark and the Economy ledger, four
## surfaces this root already owns — so it is a model held here rather than a
## screen node, and `feed_events()` is the only thing that drives it.
var street: StreetModel

var current_breakpoint: Breakpoint = Breakpoint.REGULAR
var drawer_w_dp: int = 300

## Back-stack context, written by the screens as they open and close.
var placement_active := false
var selected_entity_id := ""

var _last_back_ms := -1.0e9

## What the ghost was over when the player pressed PLACE. `BuildController`
## clears itself on a successful commit, so the observation the onboarding model
## needs (which archetype, which tile) has to be remembered one signal earlier.
var _pending_place: Dictionary = {}
var _last_build_category := ""
## Doc 06's policy wire — see `bind_dispatch_policy`.
var _dispatch_command := Callable()
var _dispatch_values: Dictionary = {}
## Doc 10's auto-repair wire — see `bind_road_policy`.
var _road_command := Callable()
var _road_values: Dictionary = {}
## Doc 06 §2.11's recall wire — see `bind_recall`.
var _recall_command := Callable()
## The city level the last batch reported, so §2.13's moment fires once.
var _city_level := -1
## Doc 07 §2.4's flood, once. See `_check_flood`.
var _flood_toast_shown := false


## Config is loaded here rather than in `_ready()` because a parent's
## `_enter_tree` runs *before* its children's: by the time a screen's `_ready()`
## fires it can call `UIRoot.config_from(self)` and share this one parse instead
## of opening `data/ui.json` five more times.
func _enter_tree() -> void:
	_load_config()


func _ready() -> void:
	initialize()


## Walks up to the owning `UIRoot` and returns its parsed config, or null if
## there is none yet — in which case the caller loads its own.
static func config_from(node: Node) -> UIConfig:
	var current: Node = node.get_parent() if node != null else null
	while current != null:
		var root := current as UIRoot
		if root != null and root.config != null:
			return root.config
		current = current.get_parent()
	return null


## Bring-up, split out of `_ready()` and idempotent: a headless test never
## reaches an idle frame, so `_ready` never fires there and the screens hanging
## off this scaffold would bind against a null config. Callers that mount the
## scene by hand call this once after `add_child()`.
func initialize() -> void:
	layer = CANVAS_LAYER_UI
	_bind_nodes()
	_load_config()
	if haptics == null:
		haptics = Haptics.new(config)
	else:
		haptics.setup(config)
	_apply_content_scale()
	rebuild_theme()
	_recompute_layout()
	bring_up_screens()
	var window := get_window()
	if window != null and not window.size_changed.is_connected(_recompute_layout):
		window.size_changed.connect(_recompute_layout)


func _load_config() -> void:
	if config != null:
		return
	config = UIConfig.load_from_files()
	if not config.is_valid():
		for message: String in config.errors:
			push_error("UIRoot: %s" % message)


func _bind_nodes() -> void:
	safe_area = get_node_or_null("SafeArea") as MarginContainer
	if safe_area == null:
		return
	marker_layer = safe_area.get_node_or_null("MarkerLayer") as Control
	hud_layer = safe_area.get_node_or_null("HUDLayer") as Control
	panel_layer = safe_area.get_node_or_null("PanelLayer") as Control
	sheet_layer = safe_area.get_node_or_null("SheetLayer") as Control
	modal_layer = safe_area.get_node_or_null("ModalLayer") as Control
	coach_layer = safe_area.get_node_or_null("CoachLayer") as Control
	title_layer = safe_area.get_node_or_null("TitleLayer") as Control
	veil_layer = safe_area.get_node_or_null("VeilLayer") as Control
	toast_layer = get_node_or_null("ToastLayer") as CanvasLayer

	hud = hud_layer as CityHUD
	overlay_rail = safe_area.get_node_or_null("HUDLayer/OverlayRail") as OverlayRail
	alerts_center = safe_area.get_node_or_null("PanelLayer/AlertsCenter") as AlertsCenter
	event_log = safe_area.get_node_or_null("PanelLayer/EventLog") as EventLog
	construction_queue = safe_area.get_node_or_null(
			"PanelLayer/ConstructionQueue") as ConstructionQueueSheet
	settings_sheet = safe_area.get_node_or_null("ModalLayer/SettingsSheet") as SettingsSheet
	# PA-14's rationale modal is the one screen this scaffold BUILDS rather than
	# finds: it is Android-only and it opens at most twice in the life of an
	# install, so it is created on the modal layer here instead of costing every
	# mount a node it will never show. It still joins the back stack for free —
	# `_has_open_child` walks the layer and asks anything with `is_open()`.
	permission_sheet = modal_layer.get_node_or_null("PermissionSheet") as PermissionSheet \
			if modal_layer != null else null
	if permission_sheet == null and modal_layer != null:
		permission_sheet = PermissionSheet.new()
		permission_sheet.name = "PermissionSheet"
		modal_layer.add_child(permission_sheet)
	goals_sheet = safe_area.get_node_or_null("ModalLayer/GoalsSheet") as GoalsSheet
	storm_prep_sheet = safe_area.get_node_or_null(
			"ModalLayer/StormPrepSheet") as StormPrepSheet
	save_load_sheet = safe_area.get_node_or_null("ModalLayer/SaveLoadSheet") as SaveLoadSheet
	pause_menu = safe_area.get_node_or_null("ModalLayer/PauseMenu") as PauseMenu
	incident_drawer = safe_area.get_node_or_null(
			"PanelLayer/IncidentDrawer") as IncidentDrawer
	unit_picker = safe_area.get_node_or_null("SheetLayer/UnitPicker") as UnitPickerSheet
	city_dashboard = safe_area.get_node_or_null(
			"ModalLayer/CityDashboard") as CityDashboard
	away_report = safe_area.get_node_or_null("ModalLayer/AwayReport") as AwayReportSheet
	build_sheet = safe_area.get_node_or_null("SheetLayer/BuildSheet") as BuildSheet
	onboarding = safe_area.get_node_or_null("CoachLayer/Onboarding") as OnboardingFlow
	building_panel = safe_area.get_node_or_null(
			"PanelLayer/BuildingPanel") as BuildingPanel
	land_panel = safe_area.get_node_or_null("PanelLayer/LandPanel") as LandPanel
	transformer_panel = panel_layer.get_node_or_null("TransformerPanel") as TransformerPanel \
			if panel_layer != null else null
	if transformer_panel == null and panel_layer != null:
		transformer_panel = TransformerPanel.new()
		transformer_panel.name = "TransformerPanel"
		panel_layer.add_child(transformer_panel)
	title_screen = safe_area.get_node_or_null("TitleLayer/TitleScreen") as TitleScreen
	loading_veil = safe_area.get_node_or_null("VeilLayer/LoadingVeil") as LoadingVeil
	tilt_slider = safe_area.get_node_or_null("HUDLayer/TiltSlider") as TiltSlider
	# PA-58's follow chip, built rather than authored for the same reason the
	# permission modal is: it is absent for whole sessions, and a HUD element
	# that is usually not there should not cost every mount a node.
	follow_chip = hud_layer.get_node_or_null("FollowChip") as FollowChip \
			if hud_layer != null else null
	if follow_chip == null and hud_layer != null:
		follow_chip = FollowChip.new()
		follow_chip.name = "FollowChip"
		hud_layer.add_child(follow_chip)
	toast_view = get_node_or_null("ToastLayer/ToastAnchor/Toast") as ToastView


# ---------------------------------------------------------------------------
# Screens — one bring-up, one switchboard (doc 12 §4.1)
# ---------------------------------------------------------------------------

## Sets up every screen this scaffold owns with the shared config and wires the
## cross-screen routes. Idempotent: a screen that already has a config keeps it,
## and every connection is guarded, so `game/main.gd` may call it again after
## injecting its own models.
func bring_up_screens() -> void:
	if hud != null and hud.model == null:
		hud.setup(config)
	if overlay_rail != null and overlay_rail.model == null:
		overlay_rail.setup(config)
	if alerts_center != null and alerts_center.model == null:
		alerts_center.setup(config)
	if event_log != null and event_log.model == null:
		event_log.setup(config)
	# S16 comes up with the shared config and a model whose provider is unbound,
	# which is an empty queue — so a mount that never calls `bind_construction()`
	# shows exactly what a city with nothing under way shows, and no chip.
	if construction_queue != null and construction_queue.config == null:
		construction_queue.setup(config)
	if settings_sheet != null and settings_sheet.model == null:
		settings_sheet.setup(config)
	if permission_sheet != null and permission_sheet.config == null:
		permission_sheet.setup(config)
	# S14 comes up with the config alone and no model, for the same reason the
	# build sheet does: `game/main.gd` owns the sim, and `setup()` is idempotent.
	if goals_sheet != null and goals_sheet.config == null:
		goals_sheet.setup(config)
	# S17 comes up with the shared config and a model whose provider is unbound,
	# which reads as "no storm pending" — so a mount that never calls
	# `bind_storm_prep()` shows a sheet that cannot be opened onto nothing.
	if storm_prep_sheet != null and storm_prep_sheet.config == null:
		storm_prep_sheet.setup(config)
	if save_load_sheet != null and save_load_sheet.model == null:
		save_load_sheet.setup(config)
	if pause_menu != null and pause_menu.config == null:
		pause_menu.setup(config)
	if incident_drawer != null and incident_drawer.model == null:
		incident_drawer.setup(config)
	if unit_picker != null and unit_picker.model == null:
		unit_picker.setup(config)
	if city_dashboard != null and city_dashboard.model == null:
		city_dashboard.setup(config)
	if away_report != null and away_report.model == null:
		away_report.setup(config)
	# The build sheet is brought up with the shared config like every other
	# screen, but WITHOUT a controller: `game/main.gd` owns that and calls
	# `setup(cfg, controller)` again once it has one (the call is idempotent). The
	# root does this because `_ready()` never fires in a headless mount — the same
	# reason `initialize()` exists — and a sheet with no config cannot even open.
	if build_sheet != null and build_sheet.config == null:
		build_sheet.setup(config)
	if onboarding != null and onboarding.model == null:
		onboarding.setup(config)
	# S4 comes up with the config alone and no model, for the same reason the
	# build sheet does: `game/main.gd` owns the sim, and `setup()` is idempotent.
	if land_panel != null and land_panel.config == null:
		land_panel.setup(config)
	# S18 on the same terms as S4: the config alone, and no model until
	# `game/main.gd` hands it the sim. `setup()` is idempotent.
	if transformer_panel != null and transformer_panel.config == null:
		transformer_panel.setup(config)
	if toast_view != null and toast_view.config == null:
		toast_view.setup(config)
	# S0 comes up like everything else — with the shared config, and CLOSED. A
	# headless mount that never calls `present_title()` therefore never sees a
	# front door, which is the contract `tests/test_tutorial_flow.gd` and
	# `tools/ui_preview.gd` depend on.
	if title_screen != null and title_screen.config == null:
		title_screen.setup(config)
	# S15 comes up on the same terms as S0: with the shared config, and CLOSED. A
	# mount that never calls `present_veil_load()` never sees a veil, which is what
	# lets the other 53 preview states measure the deck rather than measure this.
	if loading_veil != null and loading_veil.config == null:
		loading_veil.setup(config)
	# Wave 17's tilt slider comes up with the config and NO camera, like the build
	# sheet comes up with no controller: it stays hidden until `bind_camera()`.
	if tilt_slider != null and tilt_slider.config == null:
		tilt_slider.setup(config, camera_state)
	if follow_chip != null and follow_chip.config == null:
		follow_chip.setup(config)
	# §2.14: the two screens that fire their own cues share the root's one gate.
	# The other three cues (dispatch, escalate, relight) are events rather than
	# taps, so they are fired here, where the sim batch arrives.
	if build_sheet != null:
		build_sheet.haptics = haptics
	if land_panel != null:
		land_panel.haptics = haptics
	if transformer_panel != null:
		transformer_panel.haptics = haptics
	if street == null:
		street = StreetModel.new(config)
	_connect_screens()


func _connect_screens() -> void:
	if hud != null:
		_connect(hud.menu_requested, _on_menu_requested)
		_connect(hud.chip_activated, _on_chip_activated)
	if incident_drawer != null:
		_connect(incident_drawer.focus_requested, _on_focus_requested)
		_connect(incident_drawer.dispatch_requested, _on_assign_requested)
		_connect(incident_drawer.acknowledge_requested, _on_acknowledge_requested)
		_connect(incident_drawer.pin_requested, _on_pin_requested)
		_connect(incident_drawer.main_action_taken, _on_main_action_taken)
		_connect(incident_drawer.recall_requested, _on_recall_requested)
	if unit_picker != null:
		_connect(unit_picker.dispatch_requested, _on_dispatch_requested)
	if city_dashboard != null:
		_connect(city_dashboard.deeplink_requested, _on_deeplink_requested)
		_connect(city_dashboard.tax_applied, _on_tax_applied)
	if away_report != null:
		_connect(away_report.handle_now_requested, _on_handle_now_requested)
		_connect(away_report.dismissed, _on_away_dismissed)
	if overlay_rail != null:
		_connect(overlay_rail.overlay_changed, _on_overlay_changed)
	if alerts_center != null:
		_connect(alerts_center.focus_requested, _on_focus_requested)
		_connect(alerts_center.unread_changed, _on_unread_changed)
	if event_log != null:
		_connect(event_log.focus_requested, _on_focus_requested)
	if construction_queue != null:
		_connect(construction_queue.focus_requested, _on_focus_requested)
		_connect(construction_queue.rushed, report_rush)
	if settings_sheet != null:
		_connect(settings_sheet.settings_changed, _on_settings_changed)
		_connect(settings_sheet.settings_action, _on_settings_action)
		_connect(settings_sheet.saves_requested, _on_saves_requested)
	if permission_sheet != null:
		_connect(permission_sheet.answered, permission_answered.emit)
	if follow_chip != null:
		_connect(follow_chip.dismissed, follow_cancelled.emit)
	if save_load_sheet != null:
		_connect(save_load_sheet.slot_action, _on_slot_action)
		_connect(save_load_sheet.loaded, _on_save_loaded)
	if pause_menu != null:
		_connect(pause_menu.settings_requested, _on_settings_requested)
		_connect(pause_menu.save_requested, _on_saves_requested)
		_connect(pause_menu.pause_intent, _on_pause_intent)
		_connect(pause_menu.quit_requested, _on_quit_requested)
	# S12's observations. Every one of these is a signal the screens already
	# emitted for their own reasons; the onboarding model is a new listener, not
	# a new event source (doc 12 §2.17 — the tutorial watches, it never drives).
	if build_sheet != null:
		_connect(build_sheet.sheet_toggled, _on_build_sheet_toggled)
		_connect(build_sheet.placement_changed, _on_build_placement_changed)
		_connect(build_sheet.placement_committed, _on_build_placement_committed)
		_connect(build_sheet.fix_requested, _on_build_fix_requested)
	if incident_drawer != null:
		_connect(incident_drawer.drawer_toggled, _on_drawer_toggled)
	if onboarding != null:
		_connect(onboarding.action_requested, _on_onboarding_action)
		_connect(onboarding.finished, _on_onboarding_finished)
	if building_panel != null:
		_connect(building_panel.power_row_opened, _on_power_row_opened)
	if transformer_panel != null:
		_connect(transformer_panel.repaired, _on_transformer_repaired)
		_connect(transformer_panel.upgraded, _on_transformer_upgraded)
		_connect(transformer_panel.demolished, _on_transformer_demolished)
		_connect(transformer_panel.customer_selected, _on_transformer_customer)
		_connect(transformer_panel.closed, _on_transformer_closed)
	if land_panel != null:
		_connect(land_panel.purchased, _on_land_purchased)
		_connect(land_panel.developed, _on_land_developed)
		_connect(land_panel.fix_requested, _on_land_fix_requested)
	if goals_sheet != null:
		_connect(goals_sheet.sheet_toggled, _on_goals_sheet_toggled)
	if hud != null:
		_connect(hud.toast_requested, _on_toast_requested)
	if title_screen != null:
		_connect(title_screen.continue_requested, _on_title_continue)
		_connect(title_screen.new_game_requested, _on_title_new_game)
		_connect(title_screen.settings_requested, _on_title_settings)


static func _connect(source: Signal, target: Callable) -> void:
	if not source.is_connected(target):
		source.connect(target)


func _on_menu_requested() -> void:
	if pause_menu != null:
		pause_menu.toggle()


func _on_overlay_changed(mode: StringName, index: int) -> void:
	overlay_changed.emit(mode, index)


func _on_focus_requested(world_pos: Vector3) -> void:
	focus_requested.emit(world_pos)


func _on_unread_changed(count: int) -> void:
	alerts_unread_changed.emit(count)


## S12's reset (doc 12 §2.17). `replay_tutorial` is a door, not a preference:
## switching it on forgets the tutorial, starts it again and switches itself back
## off, so the row can never persist as a permanent "on".
const SETTING_REPLAY_TUTORIAL := &"replay_tutorial"


func _on_settings_changed(key: StringName, value: Variant) -> void:
	if key == SETTING_REPLAY_TUTORIAL and bool(value):
		_replay_tutorial()
	# §2.14's two rows reach the vibrator here rather than through the shell, so
	# the gate is live the instant the row is tapped rather than one frame and
	# one `game/main.gd` branch later.
	if haptics != null:
		haptics.apply_setting(key, value)
	if tilt_slider != null:
		tilt_slider.apply_setting(key, value)
	_write_dispatch_policy(key, value)
	_write_road_policy(key, value)
	# PA-58: the two camera rows reach `CameraState` here rather than through the
	# shell, on the same reasoning §2.14's haptics rows do — the gesture is live
	# on the next touch, not one `game/main.gd` branch later.
	_apply_camera_setting(key, value)
	# PA-15: a device-scoped row is committed to `user://settings.cfg` on the tap
	# that changed it, not at some later save. The player who turns notifications
	# off and immediately swipes the app away has been heard.
	if settings_sheet != null and settings_sheet.model != null \
			and settings_sheet.model.is_device_scoped(String(key)):
		settings_sheet.model.save_device()
	settings_changed.emit(key, value)


func _on_settings_action(key: StringName, action: StringName) -> void:
	settings_action.emit(key, action)


# ---------------------------------------------------------------------------
# POST_NOTIFICATIONS (PA-14 · A91-D-69) — doc 13 §2.7 steps 3–6
# ---------------------------------------------------------------------------

## The rationale modal. Returns false when there is nothing to show — no reason
## token, or a mount with no modal layer — so the shell can tell "declined" from
## "never asked" without reading the sheet.
func present_permission_rationale(reason: String) -> bool:
	if permission_sheet == null or reason == "":
		return false
	permission_sheet.present(reason)
	return true


func permission_rationale_open() -> bool:
	return permission_sheet != null and permission_sheet.is_open()


## S10's row (doc 13 §2.7 step 6), fed from `PermissionFlow.settings_row_state()`
## — `on` | `off` | `blocked` | `unavailable`. The shell reports it; this screen
## never asks the platform anything, exactly like doc 03 §2.9's difficulty line.
func set_permission_state(token: String) -> void:
	if settings_sheet == null or settings_sheet.model == null:
		return
	if not settings_sheet.model.has_key(PERMISSION_ROW):
		return
	settings_sheet.model.set_value(PERMISSION_ROW, token)
	settings_sheet.refresh_values()


func permission_state() -> String:
	if settings_sheet == null or settings_sheet.model == null:
		return ""
	return str(settings_sheet.model.value(PERMISSION_ROW))


## Read `user://settings.cfg` and apply it over the rows (PA-15). `game/main.gd`
## calls this once, BEFORE the title door — the door is a screen the player can
## read, so the text scale that lets them read it has to be in place already.
## Returns the keys the file was carrying that no row will take.
func load_device_settings(path: String = "") -> PackedStringArray:
	if settings_sheet == null or settings_sheet.model == null:
		return PackedStringArray()
	var dropped := settings_sheet.model.load_device(path)
	settings_sheet.refresh_values()
	_apply_device_side_effects()
	return dropped


## New City (doc 12 §2.19): the city-scoped rows go back to their data defaults —
## a new city has not seen the tutorial — and the device-scoped ones do not move,
## because they never belonged to the city that was just replaced. Restoring an
## EMPTY ui block is exactly that statement, since `SettingsModel.restore_state`
## re-applies the device copy last.
func reset_ui_state_for_new_city() -> void:
	restore_ui_state({})


## The two rows whose effect lives outside the model. Both are idempotent, and
## both are the same call `_on_settings_changed` would have made had the value
## arrived from a tap rather than from the file.
func _apply_device_side_effects() -> void:
	if settings_sheet == null or settings_sheet.model == null:
		return
	var model := settings_sheet.model
	if haptics != null:
		for key: StringName in [Haptics.SETTING_LEVEL, Haptics.SETTING_REDUCE_MOTION]:
			if model.has_key(String(key)):
				haptics.apply_setting(key, model.value(String(key)))
	rebuild_theme(model.theme_opts())


# ---------------------------------------------------------------------------
# The camera (doc 12 §2.16 / §2.23 / §3.2) — the deck's one handle on it
# ---------------------------------------------------------------------------

## The shell's `CameraState`. Two things hang off it and neither exists without
## it: the tilt slider (its axis) and the `camera` block of the `ui` save
## section. `game/main.gd` calls this once, after the camera is built; a headless
## mount that wants the slider on screen binds a fresh `CameraState`.
func bind_camera(camera: CameraState) -> void:
	camera_state = camera
	if tilt_slider != null:
		if tilt_slider.config == null:
			tilt_slider.setup(config, camera)
		else:
			tilt_slider.bind_camera(camera)
	solve_tilt_slider()
	# PA-58: the two §2.13 rows the camera answers to. A camera bound after the
	# rows were restored would otherwise boot on `CameraState.setup()`'s data
	# default and quietly ignore the player's choice until they tapped the row.
	_apply_camera_settings()


## Push `rotation_mode` and `invert_pan` at the bound camera (PA-58). Both were
## authored in `data/ui.json.defaults` with no row and no reader; the rows exist
## now, and this is the one place their values reach `CameraState`.
func _apply_camera_settings() -> void:
	if settings_sheet == null or settings_sheet.model == null:
		return
	for key: String in ["rotation_mode", "invert_pan"]:
		if settings_sheet.model.has_key(key):
			_apply_camera_setting(StringName(key), settings_sheet.model.value(key))


func _apply_camera_setting(key: StringName, value: Variant) -> void:
	if camera_state == null:
		return
	match key:
		&"rotation_mode":
			camera_state.rotation_mode = CameraState.rotation_mode_from_string(str(value))
		&"invert_pan":
			camera_state.invert_pan = bool(value)


# ---------------------------------------------------------------------------
# Follow mode (PA-58) — doc 12 §2.6 step 6's chip
# ---------------------------------------------------------------------------

## Raise the chip. `unit_name` is already formatted by the shell, so this class
## holds no naming rule — the same contract `set_city_difficulty` has.
func present_follow_chip(unit_name: String) -> void:
	if follow_chip != null:
		follow_chip.show_for(unit_name)
		solve_follow_chip()


## Where the chip sits, solved rather than authored (PA-58).
##
## Its first draft carried a hard-coded 316 dp bottom offset that read well at
## 360 × 800 and landed **inside the top bar** at 880 × 400, where the whole safe
## area is 400 dp tall — six `overlapping_targets` findings, all of them against
## chips the player needs more than this one. So the slot is measured off the
## thing it has to clear: doc 12's left rail, at whatever offsets
## `solve_rail_stack()` last gave it.
##
## The one collider a slot above the rail still has is the overlay strip, which
## reaches 300 dp up the same column — so the chip yields while the strip is open,
## on the tilt slider's ruling (§2.23) that a target under a panel is worse than
## no target at all.
func solve_follow_chip() -> void:
	if follow_chip == null or config == null:
		return
	var layout := config.layout()
	var gap := UIConfig.get_num(layout, "touch_spacing_min_dp", 8.0)
	var touch_min := float(ThemeBuilder.touch_min_dp(config, _text_scale(), _larger_targets()))
	var slot := UIWidgets.rail_slot(FollowChip.FALLBACK_RAIL_SLOT, layout, touch_min)
	var bottom := -float(slot["bottom"])
	var rail := hud.get_node_or_null("LeftRail") as Control if hud != null else null
	if rail != null and rail.offset_top < 0.0:
		bottom = rail.offset_top - gap
	var host_w := safe_area.size.x if safe_area != null and safe_area.size.x > 1.0 \
			else float(_safe_area_rect().size.x)
	follow_chip.place(bottom, touch_min,
			minf(FollowChip.MAX_WIDTH_DP,
					maxf(touch_min, host_w - FollowChip.LEFT_INSET_DP * 2.0)))
	follow_chip.set_yielded(overlay_rail != null and overlay_rail.is_open())


func dismiss_follow_chip() -> void:
	if follow_chip != null:
		follow_chip.hide_chip()


func follow_chip_shown() -> bool:
	return follow_chip != null and follow_chip.is_shown()


## Doc 12 §2.23's band: the right-edge column lives between the TOP BAR's bottom
## and the corner rail's reservation (the drawer handle keeps the edge from
## `drawer_handle_center_from_bottom_dp ± handle_h/2`), never in the whole safe
## area — a naively centred column lands on the handle at every landscape box.
## Both ends are MEASURED off the laid-out tree where one exists (the bar wraps
## to two rows on a near-square display, D-51) and fall back to the authored
## numbers where it does not. The slider yields the edge outright while any
## `PanelLayer` surface is up: those are right-edge panels, and a thumb drawn
## under a sheet is a target nobody can reach.
##
## Cheap and idempotent like `solve_rail_stack()`: a few reads and a `set_band`
## whose offsets early-return when nothing moved.
func solve_tilt_slider() -> void:
	if tilt_slider == null or config == null or safe_area == null:
		return
	var layout := config.layout()
	var gap := UIConfig.get_num(layout, "touch_spacing_min_dp", 8.0)
	var touch_min := float(ThemeBuilder.touch_min_dp(config, _text_scale(), _larger_targets()))
	var host_h := safe_area.size.y
	if host_h <= 1.0:
		host_h = float(_safe_area_rect().size.y)
	# The top bar's FIRST row's bottom edge, not the whole bar's: §2.4's solver
	# reserves the clock column on every wrapped row (`avail = W − clock_w −
	# 16`), so the right edge under row 0 is free even when the chips wrap to a
	# second row (D-51) — and on a 400 dp landscape box that difference is the
	# whole column. The clock chip is as tall as its row, so it is the measure.
	var top := UIConfig.get_num(layout, "top_bar_h_dp", 48.0)
	var top_bar := hud.get_node_or_null("TopBar") as Control if hud != null else null
	if top_bar != null and top_bar.visible:
		var row_h := top
		var clock := hud.clock_chip() if hud.has_method("clock_chip") else null
		if clock != null and clock.visible:
			row_h = maxf(row_h, maxf(clock.size.y, clock.get_combined_minimum_size().y))
		top = maxf(top, top_bar.offset_top + row_h)
	# **The other right-edge occupant** (Wave 18). §2.4's banner stack is as wide
	# as the display allows, so its `VIEW` — a 48 dp target that grows with A3 —
	# lands *in this column* whenever a banner is up on a box narrow enough that
	# the banner reaches the edge. The measurement is `banner_band_top()`'s; what
	# is here is the reading of the tree it is measured off.
	var host_w := safe_area.size.x
	if host_w <= 1.0:
		host_w = float(_safe_area_rect().size.x)
	var banners: Array[Rect2] = []
	var stack := hud.get_node_or_null("AlertStack") as Control if hud != null else null
	if stack != null and stack.visible:
		for child in stack.get_children():
			var banner := child as Control
			if banner == null or not banner.visible:
				continue
			banners.append(Rect2(stack.position + banner.position, banner.size))
	top = UIRoot.banner_band_top(top, banners, host_w, touch_min)
	# The corner rail's reservation: the drawer handle's authored slot, or its
	# laid-out top when the tree has one (A3 may have grown it).
	var handle_raw: Variant = layout.get("drawer_handle_dp", [44, 160])
	var handle_h := float((handle_raw as Array)[1]) \
			if handle_raw is Array and (handle_raw as Array).size() >= 2 else 160.0
	var reserve := UIConfig.get_num(layout, "drawer_handle_center_from_bottom_dp", 140.0) \
			+ maxf(handle_h, touch_min) * 0.5
	if incident_drawer != null and incident_drawer.has_method("corner_rail_entry"):
		var entry: Dictionary = incident_drawer.call("corner_rail_entry")
		var handle := entry.get("control") as Control
		if handle != null and handle.size.y > 1.0 and handle.position.y > 1.0:
			reserve = maxf(reserve, host_h - handle.position.y)
	tilt_slider.set_band(top + gap, host_h - reserve - gap)
	var yielding := false
	if panel_layer != null and panel_layer.visible:
		for child in panel_layer.get_children():
			if child.has_method("is_open") and bool(child.call("is_open")):
				yielding = true
				break
	tilt_slider.set_yielding(yielding)


## Where §2.23's band starts once §2.4's banner stack is counted: `bar_bottom`,
## or the bottom of the LOWEST banner that actually reaches the right-edge
## column, whichever is further down. Pure, because the rule is the testable
## half and reading the tree is not — a headless mount lays nothing out, so the
## caller above hands this an empty array there and the authored band survives
## unchanged (`tests/test_ui_tilt.gd::_authored_band`).
##
## **Two conditions, and the second is the one that matters** (Wave 18). A
## banner whose right edge stops short of `host_w − touch_min` is not in this
## column and may not move it: at 794 dp the stack is `alert_dp`'s 400 wide and
## centred, so the band is exactly what Wave 17 solved. At 412 dp with 130 %
## text and larger targets it is 388 wide and its `VIEW` covered 1,155 px² of
## the thumb, which is the finding this exists for.
static func banner_band_top(bar_bottom: float, banners: Array[Rect2],
		host_w: float, touch_min: float) -> float:
	var top := bar_bottom
	for rect: Rect2 in banners:
		if rect.size.y <= 1.0 or rect.size.x <= 1.0:
			continue
		if rect.end.x <= host_w - touch_min:
			continue
		top = maxf(top, rect.end.y)
	return top


# ---------------------------------------------------------------------------
# Auto-response policies (doc 12 §2.13, doc 91 D-11)
#
# The rows are `data/ui.json.settings.rows` entries carrying `policy: dispatch`;
# the values are doc 06's, held by `DispatchPolicy` inside the sim. This root
# owns neither — it owns the wire between them, which is one injected Callable
# and one seeding pass, exactly like `bind_tax`.
# ---------------------------------------------------------------------------

## `Callable(key: String, value: Variant) -> Dictionary` — the shell hands over
## `CitySim.cmd_set_dispatch_policy`. `values` is the sim's live policy block
## (`DispatchPolicy.serialize()`), which **wins over the data defaults and over a
## restored `ui.settings` block**: the policy lives in the city's save, not in
## the UI's, and a stale UI copy must never be able to re-write it.
func bind_dispatch_policy(command: Callable, values: Dictionary = {}) -> void:
	_dispatch_command = command
	_dispatch_values = values.duplicate()
	_seed_dispatch_rows()


## Doc 03 §2.9's preset, for S9's read-only city block. Called by the shell with
## `CitySim.difficulty_preset()` after a boot or a load, and by the front door
## when NEW CITY founds one. There is no setter behind it: doc 93 §K1 makes the
## preset a property of a city, so the settings sheet REPORTS it and nothing in
## `ui/` can change it.
func set_city_difficulty(preset: String) -> void:
	if settings_sheet == null or settings_sheet.model == null:
		return
	settings_sheet.model.set_city_difficulty(preset)
	settings_sheet.refresh_city()


func _seed_dispatch_rows() -> void:
	if settings_sheet == null or settings_sheet.model == null or _dispatch_values.is_empty():
		return
	for key: String in settings_sheet.model.policy_keys(SettingsModel.POLICY_DISPATCH):
		if _dispatch_values.has(key):
			settings_sheet.model.set_value(key, _dispatch_values[key])
	settings_sheet.refresh_values()


func _write_dispatch_policy(key: StringName, value: Variant) -> void:
	if settings_sheet == null or settings_sheet.model == null:
		return
	if settings_sheet.model.policy_of(String(key)) != SettingsModel.POLICY_DISPATCH:
		return
	_dispatch_values[String(key)] = value
	if _dispatch_command.is_valid():
		_dispatch_command.call(String(key), value)


## The policy block as the rows currently read it — what the shell writes back
## into a save, and what `tests/test_ui_land.gd` asserts against the sim.
func dispatch_policy_values() -> Dictionary:
	return _dispatch_values.duplicate()


# ---------------------------------------------------------------------------
# Automatic road repair (doc 10 §2.13, doc 93 §J3, feeder-water open q1)
#
# The same wire as the dispatch one above with a single difference:
# `cmd_set_auto_repair_policy(threshold, daily_cap)` takes the PAIR, so a change
# to either row writes both. That is the command's shape, not a UI choice — the
# policy is one decision with two numbers in it.
# ---------------------------------------------------------------------------

const ROAD_KEY_THRESHOLD := "auto_repair_threshold"
const ROAD_KEY_DAILY_CAP := "auto_repair_daily_cap"

## `Callable(threshold: float, daily_cap: int) -> Dictionary` — the shell hands
## over `CitySim.cmd_set_auto_repair_policy`. `values` is the live policy
## (`RoadNetwork.auto_repair_threshold` / `auto_repair_daily_cap`), which wins
## over the data defaults and over a restored `ui.settings` block for exactly the
## reason the dispatch block gives: the policy lives in the city's save.
func bind_road_policy(command: Callable, values: Dictionary = {}) -> void:
	_road_command = command
	_road_values = values.duplicate()
	_seed_road_rows()


func _seed_road_rows() -> void:
	if settings_sheet == null or settings_sheet.model == null or _road_values.is_empty():
		return
	for key: String in settings_sheet.model.policy_keys(SettingsModel.POLICY_ROADS):
		if _road_values.has(key):
			settings_sheet.model.set_value(key, _road_values[key])
	settings_sheet.refresh_values()


## Writes the PAIR. A row that moved to a rung the command refuses is put back to
## what the sim still holds, so the control can never read a value the city does
## not have (the `E_BAD_THRESHOLD` case; the refusal itself is the sheet's).
func _write_road_policy(key: StringName, value: Variant) -> void:
	if settings_sheet == null or settings_sheet.model == null:
		return
	if settings_sheet.model.policy_of(String(key)) != SettingsModel.POLICY_ROADS:
		return
	var model := settings_sheet.model
	var wanted := {
		ROAD_KEY_THRESHOLD: model.value_num(ROAD_KEY_THRESHOLD),
		ROAD_KEY_DAILY_CAP: int(round(model.value_num(ROAD_KEY_DAILY_CAP))),
	}
	wanted[String(key)] = value
	if not _road_command.is_valid():
		_road_values = wanted
		return
	var result: Dictionary = _road_command.call(float(wanted[ROAD_KEY_THRESHOLD]),
			int(wanted[ROAD_KEY_DAILY_CAP]))
	if not bool(result.get("ok", false)):
		for name: String in [ROAD_KEY_THRESHOLD, ROAD_KEY_DAILY_CAP]:
			if _road_values.has(name):
				model.set_value(name, _road_values[name])
		settings_sheet.refresh_values()
		push_toast(_refusal_text(result), HudModel.STATE_WARNING)
		return
	_road_values = wanted


## The road policy as the rows currently read it — what a shell writes back.
func road_policy_values() -> Dictionary:
	return _road_values.duplicate()


# ---------------------------------------------------------------------------
# Recall (doc 06 §2.11, doc 12 §2.6, doc 91 A91-D-24)
# ---------------------------------------------------------------------------

## `Callable(unit_id: int) -> Dictionary` — the shell hands over
## `CitySim.cmd_recall_unit`. Without it the drawer draws no recall chip at all,
## exactly as it draws no valve without a `WaterActions` (D-43).
func bind_recall(command: Callable) -> void:
	_recall_command = command
	if incident_drawer != null:
		incident_drawer.set_recall_enabled(command.is_valid())


## The drawer asked; the sim rules. A refusal is the formatter's sentence in a
## toast (A14) and the chip stays where it is — the unit is still out.
func _on_recall_requested(unit_id: int, incident_id: int) -> void:
	if not _recall_command.is_valid():
		return
	var result: Dictionary = _recall_command.call(unit_id)
	var ok := bool(result.get("ok", false))
	if incident_drawer != null:
		# Both ways: on `ok` the row lets the unit go, and on a refusal the chip
		# comes back live — a control the player tapped and that did nothing must
		# not stay dead until the next refresh.
		incident_drawer.report_recall(unit_id, incident_id, ok)
	if ok:
		push_toast(UIWidgets.t_args(config, "ui_drawer_recalled", {"unit": unit_id}))
	else:
		push_toast(_refusal_text(result), HudModel.STATE_WARNING)
	incident_action.emit(&"recall", incident_id, unit_id)


## One sim verdict → one sentence, through §2.7's formatter (A14). Used by every
## door on this root that issues a command itself rather than handing it up.
## `body` already carries `{remedy}` interpolated, which is why the toast is one
## string and not two.
func _refusal_text(result: Dictionary) -> String:
	var row := RequirementFormatter.new(config).from_result(result)
	return str(row.get("body", "")) if not row.is_empty() else ""


func _replay_tutorial() -> void:
	reset_onboarding()
	if settings_sheet != null:
		settings_sheet.close()
		var block := settings_sheet.capture_state()
		block[String(SETTING_REPLAY_TUTORIAL)] = false
		settings_sheet.apply_state(block)
	start_onboarding()


func _on_settings_requested() -> void:
	if settings_sheet != null:
		settings_sheet.open()


func _on_saves_requested() -> void:
	if save_load_sheet != null:
		save_load_sheet.open()


func _on_slot_action(action: StringName, slot: int, result: Dictionary) -> void:
	save_slot_action.emit(action, slot, result)


func _on_save_loaded(slot: int) -> void:
	save_loaded.emit(slot)


func _on_pause_intent(paused: bool) -> void:
	pause_intent.emit(paused)


func _on_quit_requested() -> void:
	quit_requested.emit()


# ---------------------------------------------------------------------------
# Wave-2 routes (S6 → S7, HUD chip → S8, S11 → S6)
# ---------------------------------------------------------------------------

## §2.4's chip is "read-only + rare" and its one action is §2.10's: open the
## dashboard on that vital's band.
##
## The goal chip is the ONE exception, and it is an exception on purpose: it is
## not a reading of a vital, it is the entry to S14, and the dashboard has no
## band to scroll to for it (doc 12 §2.19).
func _on_chip_activated(chip_id: StringName) -> void:
	if chip_id == StringName(HudModel.CHIP_GOALS):
		open_goals()
		return
	if city_dashboard != null:
		city_dashboard.open_for_chip(chip_id)


## §2.6's ASSIGN. The drawer knows the incident, the picker knows the units, and
## the root is the only thing that knows both exist.
func _on_assign_requested(incident_id: int) -> void:
	if unit_picker == null or incident_drawer == null:
		return
	var row := incident_drawer.model.row(incident_id)
	if row.is_empty():
		return
	unit_picker.open_for(row)


func _on_dispatch_requested(unit_id: int, incident_id: int) -> void:
	dispatch_requested.emit(unit_id, incident_id)


func _on_acknowledge_requested(incident_id: int) -> void:
	incident_action.emit(&"acknowledge", incident_id, true)


func _on_pin_requested(incident_id: int, pinned: bool) -> void:
	incident_action.emit(&"pin", incident_id, pinned)


func _on_main_action_taken(incident_id: int, edge_id: String, action: StringName,
		result: Dictionary) -> void:
	water_main_action.emit(incident_id, edge_id, action, result)


## §2.10's deep links. `drawer` is a cross-screen route the root can serve on its
## own; an overlay is the shell's, because only the shell owns the render mode.
func _on_deeplink_requested(target: String) -> void:
	if target == "drawer":
		if city_dashboard != null:
			city_dashboard.close()
		if incident_drawer != null:
			incident_drawer.open()
		return
	if target == "event_log":
		if city_dashboard != null:
			city_dashboard.close()
		if event_log != null:
			event_log.open()
		return
	deeplink_requested.emit(target)


func _on_tax_applied(level: int, rate: float) -> void:
	tax_applied.emit(level, rate)


## §2.12: HANDLE NOW "dismisses the report, jumps the camera, opens the drawer and
## preselects the incident". The sheet dismissed itself; the other three are here,
## except the camera jump, which is one `focus_requested` the shell already
## listens to.
func _on_handle_now_requested(incident_id: int) -> void:
	if incident_drawer != null:
		incident_drawer.open()
		var payload := incident_drawer.model.focus_payload(incident_id)
		incident_drawer.model.select(incident_id)
		incident_drawer.refresh()
		if not payload.is_empty() and bool(payload["has_focus"]):
			focus_requested.emit(payload["world_pos"] as Vector3)
	handle_now_requested.emit(incident_id)


func _on_away_dismissed() -> void:
	away_dismissed.emit()


## Binds `game/save_service.gd` (and the live sim it captures) to the two screens
## that read slots — S9's save sheet, which also writes them, and S0's front
## door, which only ever reads. Both stay `Object`: `ui/` never depends on either
## type.
func bind_save_service(service: Object, sim: Object = null) -> void:
	if save_load_sheet != null:
		save_load_sheet.bind_service(service, sim)
	if title_screen != null:
		title_screen.bind_service(service)


# ---------------------------------------------------------------------------
# S0 — the front door (doc 12 §2.2)
#
# Four calls and three signals. The root owns the *routing* and nothing else: it
# opens S9 over the title for `title_settings`, because it is the only object
# that knows both screens exist (§4.1), and it re-emits the other two because
# only `game/main.gd` holds the sim, the save service and the boot order.
#
# `game/main.gd`, in full — three edits.
#
#     # --- (1) `_ready()`: the door comes first on a PLAIN launch -------------
#     crash_sentinel = CrashSentinel.new()
#     # `DevArgs.user_args()`, not `OS.` — doc 13 D-20: on device the export
#     # template drops `--esa command_line_params` before `OS` ever sees it, and
#     # `DevArgs` merges the plugin's reading of the launching Intent with the
#     # engine's list. Off device the two answers are identical.
#     var user_args := DevArgs.user_args()
#     var unclean := crash_sentinel.boot()      # ONE call: it writes a breadcrumb
#     # Every real device launch has no user args and gets the door. Dev and
#     # screenshot runs go straight to the city so nothing that scripts this
#     # shell has to learn a new step; `--title` asks for it explicitly, and a
#     # crash recovery skips it because the player is owed their city, not a menu.
#     _want_title = not unclean and not user_args.has("--resume") \
#             and (user_args.is_empty() or user_args.has("--title"))
#     if unclean:
#         ...                                   # unchanged
#     elif not _want_title and (user_args.is_empty() or user_args.has("--resume")):
#         _resumed_slot = save_service.load_latest(sim_host.sim)
#
#     # --- (2) `_wire_ui_screens()` tail: onboarding moves behind NEW CITY ----
#     root.set_onboarding_world_resolver(_coach_world_rect)   # unchanged
#     root.onboarding_action.connect(_on_coach_action)        # unchanged
#     var tutorial_regions := {...}                           # unchanged
#     if root.onboarding != null and root.onboarding.model != null:
#         root.onboarding.model.set_regions(tutorial_regions)
#     if _want_title:
#         root.title_continue.connect(_on_title_continue)
#         root.title_new_game.connect(_on_title_new_game)
#         sim_host.paused = true          # the city does not run behind the door
#         root.present_title()
#     elif _resumed_slot < 0:
#         root.start_onboarding(tutorial_regions)
#
#     # --- (3) the two handlers ----------------------------------------------
#     func _on_title_continue(slot: int) -> void:
#         var ok := slot >= 0 and save_service.load_slot(sim_host.sim, slot)
#         if not ok:
#             ok = save_service.load_latest(sim_host.sim) >= 0
#         if not ok:
#             # The one case the door has to survive: a corrupt save leaves the
#             # player looking at the door, not at an empty city.
#             ui_root.push_toast(UIWidgets.t(ui_root.config, "ui_saves_failed"),
#                     HudModel.STATE_CRITICAL)
#             ui_root.refresh_title()
#             return
#         _resumed_slot = slot
#         _on_ui_save_loaded(slot)        # re-seeds every view from the new sim
#         ui_root.set_city_level(sim_host.sim.progression.city_level)
#         ui_root.dismiss_title()
#         sim_host.paused = false
#
#     ## `slot` is where the OUTGOING city was preserved, or −1. The archive is
#     ## three published SaveService calls and no new API, and it is EXACT because
#     ## save→load→advance identity is exact (doc 93 §E2): capture the founding
#     ## city this boot already built, restore the old one over it, write that to
#     ## the free slot, then put the founding city back.
#     func _on_title_new_game(slot: int) -> void:
#         if slot >= 0:
#             var founding: Dictionary = sim_host.sim.canonical_capture()
#             var from := save_service.latest_slot()
#             if from >= 0 and save_service.load_slot(sim_host.sim, from):
#                 save_service.save_slot(sim_host.sim, slot)
#             sim_host.sim.restore_state(founding)
#             _resync_world_views()
#         _resumed_slot = -1
#         ui_root.dismiss_title()
#         sim_host.paused = false
#         ui_root.start_onboarding({
#             "tutorial_lot_a": sim_host.sim.loader.resolve_tag("tutorial_lot_a")["tile_global"],
#             "tutorial_lot_b": sim_host.sim.loader.resolve_tag("tutorial_lot_b")["tile_global"]})
#         # The new city owns the autosave rotation from here; stake it now so a
#         # kill before the first interval does not lose the founding.
#         save_service.autosave(sim_host.sim)
#
# `title_settings` needs no shell handler at all: the root has already opened the
# settings sheet by the time it fires.
#
# `tools/flow_test.gd` and `tools/onboarding_preview.gd` instantiate
# `game/main.tscn` as a CHILD of their own scene and pass their own user args, so
# the rule above already keeps the door out of their way — except on a bare run
# with no args, where one `_ui.dismiss_title()` in their `_arm()` settles it.
# `tests/test_tutorial_flow.gd` and `tools/ui_preview.gd` mount `ui_root.tscn`
# directly and never call `present_title()`, so they cannot see one at all.
# ---------------------------------------------------------------------------

## Raises the front door. The ONLY way it ever appears — no `ui/` file calls
## this, so a mount that does not ask for a title does not get one. Returns false
## when the scene carries no title screen (a trimmed deck).
func present_title() -> bool:
	if title_screen == null:
		return false
	title_screen.open()
	return true


## Puts it away. The shell's call, and deliberately not the view's: only the
## shell knows whether the restore behind CONTINUE actually succeeded, and a
## failed one has to leave the player looking at the door.
func dismiss_title() -> void:
	if title_screen != null:
		title_screen.close()


## Is a full-screen surface over the city? Two lanes grew this function in the
## same wave — the permission flow's (`_has_open_child(modal_layer)`) and this
## one — and `git` text-merged BOTH copies in without reporting a conflict, so
## the tree only failed at import. This is the survivor because it is the
## superset: both callers (the permission prompt and the quality governor) want
## the title door and the loading veil counted as well.
##
## Every child of `ModalLayer` is one by
## construction (§2.2: the layer is STOP when populated), and the title door and
## the loading veil are their own layers with the same property. The renderer's
## quality governor asks this every frame: a frame drawn under a sheet measures
## the sheet, not the world, and acting on it resizes the 3D render target while
## a panel is composited over it (report 98 RR-154).
func modal_open() -> bool:
	if title_open() or veil_open():
		return true
	if modal_layer == null:
		return false
	for child in modal_layer.get_children():
		var control := child as Control
		if control != null and control.visible:
			return true
	return false


func title_open() -> bool:
	return title_screen != null and title_screen.is_open()


## Re-reads the slots behind CONTINUE. Cheap — `list_slots()` reads headers — so
## the shell may call it after any save.
func refresh_title() -> void:
	if title_screen != null:
		title_screen.refresh()


func _on_title_continue(slot: int) -> void:
	title_continue.emit(slot)


func _on_title_new_game(slot: int, difficulty: String) -> void:
	# A new city has never seen the tutorial, whatever the previous one did.
	reset_onboarding()
	# S9 shows the preset read-only (doc 03 §2.9), and the city that is about to
	# be founded is the one it should show — not the one the process booted on.
	set_city_difficulty(difficulty)
	title_new_game.emit(slot, difficulty)


func _on_title_settings() -> void:
	if settings_sheet != null:
		settings_sheet.open()
	title_settings.emit()


# ---------------------------------------------------------------------------
# S15 — the loading veil (doc 13 §2.9 / §2.9.1, doc 91 §20.2 item 19)
# ---------------------------------------------------------------------------

## Raises the veil over a stepped restore. Like the front door, the ONLY way it
## ever appears — nothing in `ui/` calls it.
##
## `city` is what the player calls the thing being opened; the shell supplies it,
## because `ui/` has no slot list and `sim/` has no name for a city. `total_steps`
## is `RestoreCursor.step_count()`. Returns false when the scene carries no veil.
func present_veil_load(city: String, total_steps: int) -> bool:
	if loading_veil == null:
		return false
	loading_veil.present_load(city, total_steps)
	return true


## `RestoreCursor.completed()`, once per stepped frame.
func advance_veil_load(completed: int) -> void:
	if loading_veil != null:
		loading_veil.advance_load(completed)


## Doc 13 §2.9's catch-up messaging. `hours` is the game time about to run and
## `total_steps` the planner's tick count; answers false — and takes the veil
## down — when the absence is beneath `data/ui.json.veil.min_steps`.
func present_veil_catchup(hours: int, total_steps: int,
		capped: bool = false, cap_real_hours: int = 12) -> bool:
	if loading_veil == null:
		return false
	return loading_veil.present_catchup(hours, total_steps, capped, cap_real_hours)


func advance_veil_catchup(completed: int) -> void:
	if loading_veil != null:
		loading_veil.advance_catchup(completed)


## Down. Idempotent, and safe to call on a path that never raised one — which is
## what the corrupt-save fallback needs.
func dismiss_veil() -> void:
	if loading_veil != null:
		loading_veil.dismiss()


func veil_open() -> bool:
	return loading_veil != null and loading_veil.is_open()


## What the player calls a save slot — `Autosave`, `Slot 2` — for the veil's
## `Opening {city}…`. S8's model already owns the answer and the string table it
## comes from; this exists so `game/main.gd` reaches through one object for it
## rather than three. `""` when there is no save sheet to ask, which
## `VeilModel` renders as `Opening your city…`.
func slot_title(slot: int) -> String:
	if save_load_sheet == null or save_load_sheet.model == null:
		return ""
	return save_load_sheet.model.slot_title(slot)


## Pipes one `SimEventBus.drain()` batch into the feeds that eat sim events —
## the alerts centre (§2.15), the incident drawer (§2.6) and, while it is
## running, the onboarding step machine (§2.17). The shell calls this once from
## its tick handler; nothing else in `ui/` sees a sim event.
func feed_events(batch: Array) -> void:
	var raised: Array[Dictionary] = []
	if alerts_center != null:
		raised = alerts_center.feed_batch(batch)
	# S13: the same batch, a different reading of it. The alerts centre keeps
	# the ones that need doing; the log keeps all of them, in order.
	if event_log != null:
		event_log.feed_batch(batch)
	if incident_drawer != null:
		incident_drawer.feed_batch(batch)
	_cue_events(raised)
	_check_city_level(batch)
	_check_flood(batch)
	_check_goal_events(batch)
	_check_street(batch)
	_check_construction(batch)
	if onboarding == null or not onboarding.is_active():
		return
	for entry: Variant in batch:
		if not (entry is Dictionary):
			continue
		var event: Dictionary = entry
		onboarding.feed({"kind": OnboardingModel.OBS_SIM_EVENT,
				"event": str(event.get("type", "")), "payload": event})


## §2.14's two event cues, fired from the rows the §2.13 gate actually raised —
## at most one of each per batch, because a batch that carries eight failures is
## one thing that happened, not eight.
const CUE_NOTIFY_IDS := {
	"power_restored": Haptics.CUE_POWER_RESTORED,
	"load_shed_ended": Haptics.CUE_POWER_RESTORED,
}


func _cue_events(raised: Array) -> void:
	if haptics == null or raised.is_empty():
		return
	var escalated := false
	var relit := false
	for entry: Variant in raised:
		var row: Dictionary = entry
		if not escalated and str(row.get("class", "")) == "p1":
			escalated = true
		var notify_id := str(row.get("notify_id", ""))
		if not relit and CUE_NOTIFY_IDS.has(notify_id):
			relit = true
	if escalated:
		haptics.fire(Haptics.CUE_ESCALATE)
	if relit:
		haptics.fire(Haptics.CUE_POWER_RESTORED)


## Doc 12 §2.13's progression moment. `city_level_changed` used to reach the
## player as one alert row among twenty and nothing else, which is a progression
## ladder with no rung: this raises the toast **and** marks the build cards the
## level just unlocked so the reward is visible on the thing that was rewarded.
##
## **And since Wave 22 it says what it paid** (99-PA PA-44). The celebration
## grant is now the largest single receipt of a session — $215,000 at the first
## rung and $5,000,000 at the last — and until this wave no foreground surface
## carried the amount: the toast said *"new buildings unlocked"* while the money
## landed silently in a log line. The figure comes off the sim's own
## `level_up_grant_paid` events **in the same batch** rather than from a second
## read of `data/economy.json`, because a toast that predicted a payment could
## be right about the table and wrong about the city.
##
## It is ONE toast, not two, and that is the point: doc 12 §2.15's toasts replace
## each other, so a separate grant toast would have eaten the level-up toast a
## frame later and the rung would have gone unnamed. The money is felt on the
## §2.21 payday surfaces instead — the treasury chip flashes and the coin cue
## sounds through `data/audio.json`'s existing `level_fanfare` rule.
##
## Guarded on the level itself rather than on the event, so a replayed batch, a
## save reload or a doubled feed cannot celebrate twice.
func _check_city_level(batch: Array) -> void:
	# Grants first, because the toast below needs them and both events arrive in
	# the same batch: `CitySim.publish_progression` emits `city_level_changed`
	# and then pays, on the one call. A rung with no grant row leaves the
	# dictionary empty and the toast falls back to its old copy.
	var grant_by_level: Dictionary = {}
	for entry: Variant in batch:
		if not (entry is Dictionary):
			continue
		var paid: Dictionary = entry
		if StringName(str(paid.get("type", ""))) != &"level_up_grant_paid":
			continue
		var paid_level := int(paid.get("city_level", 0))
		grant_by_level[paid_level] = int(grant_by_level.get(paid_level, 0)) \
				+ int(paid.get("amount", 0))
	for entry: Variant in batch:
		if not (entry is Dictionary):
			continue
		var event: Dictionary = entry
		if StringName(str(event.get("type", ""))) != &"city_level_changed":
			continue
		var level := int(event.get("to", event.get("level", 0)))
		if level <= _city_level:
			continue
		var first_reading := _city_level < 0
		_city_level = level
		if first_reading:
			continue  # attaching to a city already at level N is not a level-up
		var unlocked: PackedStringArray = []
		if build_sheet != null:
			unlocked = build_sheet.reveal_unlocked(level)
		var grant := int(grant_by_level.get(level, 0))
		if grant > 0:
			push_toast(UIWidgets.t_args(config, "ui_toast_city_level_grant",
					{"level": level, "amount": HudModel.money_exact(grant)}),
					HudModel.STATE_NORMAL)
			# §2.21's payday surfaces, spent on the largest receipt in the game.
			# The chip pulse is the only thing that makes a treasury jump of
			# $5,000,000 legible on a bar the eye is not looking at.
			if hud != null:
				hud.flash_chip(StringName(HudModel.CHIP_TREASURY),
						street.chip_flash_s() if street != null else 0.9)
		else:
			push_toast(UIWidgets.t_args(config, "ui_toast_city_level",
					{"level": level}), HudModel.STATE_NORMAL)
		city_level_changed.emit(level, unlocked)
		grant_by_level.erase(level)
	# A GRANT WITH NO LEVEL CHANGE STILL HAPPENED TO THE PLAYER (Wave 22 verify
	# pass, 2026-09-04). Every surface above hangs on `city_level_changed`, and
	# doc 93 §G1's composed level is `max(population ladder, goals.earned_level)`
	# — so a player who grew into level 3 by POPULATION and then completes
	# curriculum rungs 1, 2 and 3 is paid three grants while the composed level
	# never moves, and the money lands with no toast, no chip flash and no
	# fanfare. Measured on that arc: $205,000 arriving in total silence. The
	# receipt is owed to the player who earned it, whichever ladder moved.
	for paid_level: Variant in grant_by_level:
		var amount := int(grant_by_level[paid_level])
		if amount <= 0:
			continue
		push_toast(UIWidgets.t_args(config, "ui_toast_city_level_grant",
				{"level": int(paid_level), "amount": HudModel.money_exact(amount)}),
				HudModel.STATE_NORMAL)
		if hud != null:
			hud.flash_chip(StringName(HudModel.CHIP_TREASURY),
					street.chip_flash_s() if street != null else 0.9)


## Doc 07 §2.4's flood, the first time a player meets one (defect A91-D-26).
##
## The alerts centre and the log both carry every band crossing from here on;
## this is the one line that says *look at the street*, and it fires **once per
## session** for the same reason §2.13's level-up toast does: a storm crosses
## the same band on twenty land blocks inside a minute, and twenty toasts is
## twenty times nothing. `standing_water` is the floor — 100 mm is where doc 07
## starts stalling vehicles — so the 40 mm nuisance band, which the renderer
## draws and nothing narrates, never raises one.
##
## Guarded on a flag rather than on the event, so a replayed batch, a save
## reload or a doubled feed cannot toast twice.
const FLOOD_TOAST_BANDS := ["standing_water", "flooded", "impassable"]


func _check_flood(batch: Array) -> void:
	if _flood_toast_shown:
		return
	for entry: Variant in batch:
		if not (entry is Dictionary):
			continue
		var event: Dictionary = entry
		if StringName(str(event.get("type", ""))) != &"flood_level_changed":
			continue
		if not FLOOD_TOAST_BANDS.has(str(event.get("band", ""))):
			continue
		_flood_toast_shown = true
		push_toast(UIWidgets.t_args(config, "ui_toast_flood",
				{"depth": int(roundf(float(event.get("depth_mm", 0.0))))}),
				HudModel.STATE_WARNING)
		return


# ---------------------------------------------------------------------------
# Wave 14 — the payday (doc 12 §2.21)
#
# **Nothing to connect.** Every one of the four surfaces is already downstream
# of `feed_events()`, which `game/main.gd` already calls once per tick, so the
# bounty half of this needs no shell change at all: a crew that answered a call
# while the player was looking somewhere else now pulses the treasury chip,
# sounds a coin and says what it was worth, and the money finally appears in the
# Economy tab's own column.
#
# The tap half needs the shell, because only the shell owns the tap: see
# `report_collect()` below and `BuildController.pick_at_ground`.
# ---------------------------------------------------------------------------

func _check_street(batch: Array) -> void:
	if street == null:
		return
	for entry: Variant in batch:
		if not (entry is Dictionary):
			continue
		var event: Dictionary = entry
		match StringName(str(event.get("type", ""))):
			StreetModel.EVENT_INCIDENT_RESOLVED:
				_spend_feedback(street.bounty_feedback(event), HudModel.STATE_NORMAL)
			StreetModel.EVENT_COLLECTED:
				# The collect the player made reaches this root through
				# `report_collect()`; this arm is for one that happened without
				# a tap. **`by_player` defaults to TRUE, and the default is the
				# safe direction**: a sim that never stamps the field leaves an
				# auto-collect out of the ledger's street line, where the other
				# default would count the player's own tap twice and print it.
				if not bool(event.get("by_player", true)):
					_spend_feedback(street.collect_feedback(
							{"ok": true, "payload": event}), HudModel.STATE_NORMAL)
			StreetModel.EVENT_SPAWNED:
				_raise_street_coach(event)
			StreetModel.EVENT_HOUR_SETTLED:
				street.close_hour()
				_push_side_revenue()


## The one-time discovery mark (§2.17's machinery, not §2.17's curriculum). The
## model decides whether this is the first opportunity a save has ever seen; the
## tutorial's own claim on the screen is checked here, because only this root
## knows whether a step is up.
func _raise_street_coach(event: Dictionary) -> void:
	if onboarding == null:
		return
	var request := street.note_spawn(event, onboarding.is_active())
	if request.is_empty():
		return
	onboarding.show_notice(str(request["text"]), request["world_pos"] as Vector3,
			bool(request["has_pos"]), float(request["ttl_s"]))


## Whatever `StreetModel` said should be felt, spent on the surfaces that can
## feel it. Returns the toast copy — `""` when there was nothing to say — so the
## shell and the tests can read what the player was told.
func _spend_feedback(feedback: Dictionary, state: StringName) -> String:
	if feedback.is_empty():
		return ""
	var chip := str(feedback.get("flash_chip", ""))
	if chip != "" and hud != null:
		# The record may name its own flash length (S16's rush does, from
		# `data/ui.json.construction`); the payday's does not and takes §2.21's.
		hud.flash_chip(StringName(chip), float(feedback.get("flash_s",
				street.chip_flash_s() if street != null else 0.9)))
	var cue := StringName(str(feedback.get("haptic", "")))
	if cue != &"" and haptics != null:
		haptics.fire(cue)
	var toast := str(feedback.get("toast", ""))
	if toast != "":
		push_toast(toast, state if bool(feedback.get("ok", false))
				else HudModel.STATE_WARNING)
	return toast


## The two ledger lines doc 03 does not settle. Pushed on the hour boundary and
## on a restore, which are the only two moments the CLOSED hour's tally can
## change — a deposit lands in the hour still running and moves no ledger row.
func _push_side_revenue() -> void:
	if city_dashboard == null or city_dashboard.model == null:
		return
	city_dashboard.model.budget.feed_side_revenue(street.side_revenue())


## **The tap that collected something.** `result` is
## `BuildController.collect_opportunity()`'s record and `pick` is the row
## `pick_at_ground` resolved.
##
## Returns `StreetModel`'s feedback record — `{ok, amount, toast, cue, …}` —
## rather than the toast copy the other `report_*` calls return, for one reason:
## the shell keeps exactly one job out of this, and it needs an answer to do it.
## `AudioService` belongs to `game/` and `ui/` has never held one, so the shell
## reads `cue` and calls `audio.ui_cue(AudioService.UI_CASH)`, exactly as it
## already does for `UI_CONFIRM` on every other command result. It must not read
## `ok` for that: a build whose sim has no collect verb yet refuses with
## `E_NO_COMMAND`, and the honest sound for a feature that is not there is
## silence rather than a rejection buzz.
##
## Called once per collect, never speculatively: the record it returns is also
## what moves the street line of the ledger.
func report_collect(result: Dictionary, pick: Dictionary = {}) -> Dictionary:
	if street == null:
		return {}
	var feedback := street.collect_feedback(result, pick)
	# A collect is also the best possible end to the mark that pointed at it:
	# the player did the thing, so the sentence has done its work.
	if bool(feedback.get("ok", false)) and onboarding != null \
			and onboarding.notice_active():
		onboarding.dismiss_notice()
	feedback["toast_shown"] = _spend_feedback(feedback, HudModel.STATE_NORMAL)
	return feedback


# ---------------------------------------------------------------------------
# Wave 17 — S16, the construction queue (doc 12 §2.22)
#
# **One shell call, and the rest was already wired.** `bind_construction()`
# hands over the seam's two doors and a treasury reading; the camera jump rides
# `set_incident_locator()`, which the shell already makes; the cue rides
# `data/audio.json`, which the shell already feeds; and the toast and the chip
# pulse ride `feed_events()`, which the shell already calls once per tick.
# ---------------------------------------------------------------------------

## The seam, bound. `provider` answers `CitySim.construction_overview()`,
## `rush_command` is `CitySim.cmd_rush_construction`, and `treasury` reads the
## balance so an unaffordable rush can be shown DISABLED WITH ITS PRICE rather
## than hidden. Every one of the three may be left unbound and the screen then
## behaves exactly as a city with nothing under way does.
func bind_construction(provider: Callable, rush_command: Callable = Callable(),
		treasury: Callable = Callable()) -> void:
	if construction_queue == null or construction_queue.model == null:
		return
	construction_queue.model.set_provider(provider)
	if rush_command.is_valid():
		construction_queue.model.set_rush(rush_command)
	if treasury.is_valid():
		construction_queue.model.set_treasury(treasury)
	construction_queue.refresh()


## Re-reads the provider: the chip's badge while the panel is shut, the bars and
## the ETAs while it is open. Rides the shell's 1 Hz HUD cadence, like the goal
## chip and the land panel.
func refresh_construction() -> void:
	if construction_queue != null:
		construction_queue.refresh()


func open_construction_queue() -> void:
	if construction_queue != null:
		construction_queue.open()


func construction_queue_open() -> bool:
	return construction_queue != null and construction_queue.is_open()


## The player pressed RUSH and the door answered. A refusal is a sentence, never
## a silence — the one exception is a build whose sim has no rush verb at all,
## which says nothing for §2.21's reason: there is no story to tell a player
## about a feature that is not there.
##
## **An accepted rush does NOTHING here.** The spend — the toast, the chip
## pulse, the haptic and (through `data/audio.json`) the cue — is felt from the
## bus, in `_check_construction()`, so a rush that lands from anywhere — this
## button, S5's inline one, a later automation, a replayed batch — is felt
## exactly once and identically. Buzzing here as well would be the same beat
## twice, a tick apart (doc 98 RR-113).
##
## Public, because S5's `BuildingPanel.rushed` carries the same answer through
## `game/main.gd` and a refusal has to read identically on both doors.
func report_rush(_job_id: int, result: Dictionary) -> void:
	if bool(result.get("ok", false)):
		return
	if str(result.get("err", "")) == String(BuildController.E_NO_COMMAND):
		return
	if haptics != null:
		haptics.fire(Haptics.CUE_BLOCKED)
	# The seam names its refusal `err`; §2.7's formatter reads `reason_code`.
	# Translated at THIS door rather than in the model, because the contract's
	# spelling is the contract's and a model that renamed it would be publishing
	# a second one.
	var sentence := _refusal_text({"ok": false,
			"reason_code": StringName(str(result.get("err", ""))), "payload": {}})
	if sentence == "":
		sentence = UIWidgets.t(config, "ui_queue_rush_refused",
				"That could not be rushed.")
	push_toast(sentence, HudModel.STATE_WARNING)


## §2.22's cue: one sentence and one chip flash for a rush that was paid for.
## The sound is a `data/audio.json` rule on the event itself, so nothing here
## plays it — `AudioService.feed_batch()` already has this batch.
func _check_construction(batch: Array) -> void:
	if construction_queue == null or construction_queue.model == null:
		return
	var model := construction_queue.model
	for entry: Variant in batch:
		if not (entry is Dictionary):
			continue
		var event: Dictionary = entry
		if StringName(str(event.get("type", ""))) != ConstructionQueueModel.EVENT_RUSHED:
			continue
		_spend_feedback(model.rush_feedback(event), HudModel.STATE_NORMAL)
		construction_queue.refresh()


## The projector a street coach mark points with — see
## `OnboardingFlow.set_world_point_projector`.
func set_onboarding_world_projector(projector: Callable) -> void:
	if onboarding != null:
		onboarding.set_world_point_projector(projector)


## S14 — the goals seam (doc 12 §2.19).
##
## Four calls, and only the first is mandatory. `game/main.gd` hands the sheet a
## `GoalsModel` once, then calls `refresh_goals()` on its HUD cadence; everything
## else — the chip, the pulse, the level-up toast — happens here, off the sim
## batch this root is already being fed.
##
##     # --- bring-up, beside the build sheet's -----------------------------
##     root.goals_sheet.setup(root.config,
##             GoalsModel.new(sim_host.sim, root.config, build_controller))
##
##     # --- on the HUD cadence ---------------------------------------------
##     ui_root.refresh_goals()
##
## Nothing to connect: `feed_events` already sees `goal_progress`,
## `goal_completed` and `city_level_objectives_met`, and the chip tap is routed
## by `_on_chip_activated`.
signal goal_level_reached(level: int, title: String)


## Re-reads the curriculum into the chip and, when it is up, the sheet.
## Cheap — a five-row objective list — so the shell may call it every frame.
func refresh_goals() -> void:
	if goals_sheet == null or goals_sheet.model == null:
		return
	if hud != null and hud.model != null:
		hud.model.ingest_goals(goals_sheet.model.chip_view())
		hud.rebuild_chips()
	if goals_sheet.is_open():
		goals_sheet.refresh()


## **S17's one shell call** (99-PA PA-26). Same shape as `bind_construction`:
## the screen is built against a CONTRACT — a provider and a door, both
## Callables — so it can be laid out, measured and photographed by
## `tools/ui_preview.gd` against a fixture, and the shell decides nothing about
## what a preparation action costs or whether the window is open.
func bind_storm_prep(provider: Callable, door: Callable = Callable()) -> void:
	if storm_prep_sheet == null or storm_prep_sheet.model == null:
		return
	storm_prep_sheet.model.provider = provider
	if door.is_valid():
		storm_prep_sheet.model.door = door
	storm_prep_sheet.refresh()


## Opened from the `weather_warning` alert, which is the only place a player can
## learn a storm is coming — doc 07 F7 makes that notification CRITICAL and
## exempt from every rate limit, so it is the one alert that is always there to
## be tapped.
func open_storm_prep() -> void:
	if storm_prep_sheet != null:
		storm_prep_sheet.open()


func close_storm_prep() -> void:
	if storm_prep_sheet != null:
		storm_prep_sheet.close()


func storm_prep_open() -> bool:
	return storm_prep_sheet != null and storm_prep_sheet.is_open()


## Re-reads the provider while the sheet is up. Rides the shell's 1 Hz HUD
## cadence like the goal chip and the construction queue — the countdown is the
## point of the screen and a countdown that only moves on a tap is a label.
func refresh_storm_prep() -> void:
	if storm_prep_sheet != null and storm_prep_sheet.is_open():
		storm_prep_sheet.refresh()


func open_goals() -> void:
	if goals_sheet != null:
		goals_sheet.open()


func close_goals() -> void:
	if goals_sheet != null:
		goals_sheet.close()


func goals_open() -> bool:
	return goals_sheet != null and goals_sheet.is_open()


func _on_goals_sheet_toggled(open: bool) -> void:
	if not open:
		return
	feed_onboarding({"kind": OnboardingModel.OBS_UI_OPENED,
			"path": OnboardingFlow.SCREEN_GOALS_SHEET})


## Doc 09 §2.14's moments, read off the same batch everything else is.
##
## `goal_completed` pulses the row that just landed; `city_level_objectives_met`
## is the celebration — a toast naming the level and what it is called, and the
## sheet already knows what it unlocked because the reward card is a READ.
## Guarded on nothing: the sim emits each of these exactly once.
func _check_goal_events(batch: Array) -> void:
	if goals_sheet == null:
		return
	for entry: Variant in batch:
		if not (entry is Dictionary):
			continue
		var event: Dictionary = entry
		match StringName(str(event.get("type", ""))):
			&"goal_completed":
				goals_sheet.celebrate(str(event.get("goal_id", "")))
			&"city_level_objectives_met":
				var level := int(event.get("level", 0))
				var title := ""
				if goals_sheet.model != null:
					title = str(goals_sheet.model.level_preview(level).get("title", ""))
				push_toast(UIWidgets.t_args(config, "ui_toast_goal_level",
						{"level": level, "title": title}, ""), HudModel.STATE_NORMAL)
				if haptics != null:
					haptics.fire(Haptics.CUE_POWER_RESTORED)
				goal_level_reached.emit(level, title)


## The city level this root believes the city is at; `-1` before the first
## `city_level_changed` reading. The shell seeds it on boot so a resumed city
## does not celebrate the level it already had (`set_city_level`).
func city_level() -> int:
	return _city_level


func set_city_level(level: int) -> void:
	_city_level = level


## §2.15's toast surface. One line, bottom-centre, newest replaces.
func push_toast(text: String, state: StringName = &"") -> void:
	if toast_view != null:
		toast_view.show_toast(text, state)


func _on_toast_requested(text: String, state: StringName) -> void:
	push_toast(text, state)


# ---------------------------------------------------------------------------
# S4 land panel (doc 12 §2.8)
# ---------------------------------------------------------------------------

## The shell's tap seam: `BuildController.pick_at_ground` said `block`, and this
## opens S4 on it. Returns whether the panel took the tap, so the caller can fall
## through to its own deselect when it did not.
func show_land_block(block_id: String) -> bool:
	if land_panel == null or land_panel.model == null:
		return false
	land_panel.show_block(block_id)
	return land_panel.is_open()


func close_land_panel() -> void:
	if land_panel != null:
		land_panel.close()


# ---------------------------------------------------------------------------
# S18 transformer panel (doc 12 §2.25, Wave 25 — RR-207)
# ---------------------------------------------------------------------------

## The shell's tap seam, one kind up from `show_land_block`:
## `BuildController.pick_at_ground` said `component`, and this opens S18 on it.
## Returns whether the panel took the tap, so the caller can fall through to its
## own deselect when it did not — a build whose `TransformerPanel` has no model
## must deselect exactly as it does today rather than eat the tap.
func show_transformer(component_id: String) -> bool:
	if transformer_panel == null:
		return false
	if transformer_panel.model == null:
		transformer_panel.model = _transformer_model()
	if transformer_panel.model == null:
		return false
	transformer_panel.show_component(component_id)
	return transformer_panel.is_open()


## S18's model, resolved from the controller a sibling screen is already holding
## — the same argument `bind_water_actions`' resolver makes one section down, and
## for the same reason.
##
## `bring_up_screens()` builds every screen against one shared `UIConfig` and NO
## sim; the shell builds the `BuildController` afterwards and hands it to S5 and
## to the build sheet. Without this, S18 would be a screen the shipped game could
## never open — `show_transformer` would return `false` for ever because nothing
## in the boot sequence had a reason to hand it a model, and the defect would look
## exactly like a tap that does nothing, which is the defect this wave exists to
## remove. A shell that binds explicitly still wins (it sets `model` first); a
## fixture mount with no controller anywhere stays inert, which is correct.
func _transformer_model() -> TransformerPanelModel:
	var controller: BuildController = null
	if building_panel != null and building_panel.controller != null:
		controller = building_panel.controller
	elif build_sheet != null and build_sheet.controller != null:
		controller = build_sheet.controller
	if controller == null or controller.sim == null:
		return null
	return TransformerPanelModel.new(controller.sim, controller.power, config,
			controller.tile_m)


func close_transformer_panel() -> void:
	if transformer_panel != null:
		transformer_panel.close()


## S5's one-row POWER summary was tapped, or a `POWER_CAPACITY` row's
## `Fix this →` was. **Served here rather than re-emitted**, because both panels
## are on this root's own `PanelLayer` and the route is one line — the shell has
## no decision to make about it. The shell is still TOLD, through
## `transformer_selected`, because it owns the world highlight and the selection
## id.
##
## An UNSERVED building fires this with an empty id: the panel that would be
## opened does not exist, so the answer is to close whatever is open and clear
## the selection, which is exactly what a tap on empty ground does.
func _on_power_row_opened(component_id: String, _sim_id: String) -> void:
	if component_id == "" or not show_transformer(component_id):
		transformer_selected.emit("")
		return
	transformer_selected.emit(component_id)


func _on_transformer_repaired(component_id: String, result: Dictionary) -> void:
	grid_action.emit(&"repair", component_id, result)


## The two S5 signals this root raises on the panel's behalf — see
## `BuildingPanel.grid_upgraded`'s docstring. A shell binding `grid_action`
## instead should also drop these two (report 98 §68.1 snippet 3); until it does,
## both fire and both say the same thing, which is `_refresh_hud()`.
func _on_transformer_upgraded(component_id: String, result: Dictionary) -> void:
	grid_action.emit(&"upgrade", component_id, result)
	if building_panel != null:
		building_panel.grid_upgraded.emit(component_id, result)


func _on_transformer_demolished(component_id: String, result: Dictionary) -> void:
	grid_action.emit(&"demolish", component_id, result)
	if building_panel != null:
		building_panel.grid_demolished.emit(component_id, result)


func _on_transformer_customer(sim_id: String, world_pos: Vector3) -> void:
	transformer_customer_selected.emit(sim_id, world_pos)


## The panel closed — by the ✕, by a sibling opening over it, or by the REMOVE
## row taking its subject out of the city. The world highlight goes with it, or
## the player is left with a glowing pad and no panel.
func _on_transformer_closed() -> void:
	transformer_selected.emit("")


## Re-reads the selected transformer. Called on the shell's HUD cadence, like
## `refresh_land_panel`, so a crew's progress bar and its ETA move while the
## panel is open and the load meter tracks the evening peak.
func refresh_transformer_panel() -> void:
	if transformer_panel != null and transformer_panel.is_open():
		transformer_panel.refresh()


## Re-reads the selected block. Cheap, and the shell calls it on its HUD cadence
## so a development phase's bar and ETA move while the panel is open.
func refresh_land_panel() -> void:
	if land_panel != null and land_panel.is_open():
		land_panel.refresh()


func _on_land_purchased(result: Dictionary) -> void:
	if build_sheet != null:
		build_sheet.rebuild_cards()  # new ground can change what is affordable
	land_purchased.emit(land_panel.selected_id() if land_panel != null else "", result)


func _on_land_developed(result: Dictionary) -> void:
	land_developed.emit(land_panel.selected_id() if land_panel != null else "", result)


func _on_land_fix_requested(fix_target: Dictionary) -> void:
	land_fix_requested.emit(fix_target)


## The placement bar's door (PA-23). Re-emitted rather than served here, for the
## reason `land_fix_requested` is: the target is a place on the map and this root
## does not own the map. **A door with nothing behind it is the same defect PA-05
## filed one layer down**, so `tests/test_build_controller.gd` asserts this wire
## and not merely the button.
func _on_build_fix_requested(fix_target: Dictionary) -> void:
	build_fix_requested.emit(fix_target)


func set_sim_clock(minute_of_day: int, day_index: int = 0) -> void:
	if alerts_center != null:
		alerts_center.set_clock(minute_of_day, day_index)
	if event_log != null:
		event_log.set_clock(minute_of_day, day_index)


## `Callable(kind: StringName, id: Variant) -> Vector3` — how an alert's entity
## id becomes a camera target. Supplied by the shell, which owns the map.
func set_alert_locator(locator: Callable) -> void:
	if alerts_center != null:
		alerts_center.set_locator(locator)
	if event_log != null:
		event_log.set_locator(locator)


# ---------------------------------------------------------------------------
# Wave-2 shell seams. Every one of these takes plain data or an injected
# Callable: `ui/` still holds no sim reference, and `game/main.gd` still talks to
# one object.
# ---------------------------------------------------------------------------

## Doc 06's `IncidentSystem.snapshot()` and its clock (game-hours). One call per
## HUD refresh keeps the escalation countdowns moving; without it the drawer
## still lists everything the events created, just without a clock.
func refresh_incidents(snapshot_rows: Array, now_h: float = -1.0) -> void:
	if incident_drawer == null:
		return
	_resolve_water_actions()
	if now_h >= 0.0:
		incident_drawer.set_now_h(now_h)
	incident_drawer.refresh_from(snapshot_rows)


## Hands the drawer doc 05 §2.12's isolate/restore pair (doc 93 §J1). The shell
## may call this explicitly; it does not have to, because `_resolve_water_actions`
## below finds the same object on its own.
func bind_water_actions(actions: WaterActions) -> void:
	if incident_drawer != null:
		incident_drawer.bind_water(actions)


## The drawer's water binding, resolved from the build sheet's controller.
##
## `bring_up_screens()` builds every screen against one shared `UIConfig` and no
## sim; the shell builds the `BuildController` afterwards and hands it to the
## build sheet. Rather than add a second shell call for one binding, the root
## takes the object the sheet is already holding, the first time it feeds a
## snapshot — the root is a switchboard and this is a wire, not a decision. A
## shell that binds explicitly wins; a fixture mount with no build sheet stays
## exactly as it was, and the drawer simply draws no valve.
func _resolve_water_actions() -> void:
	if incident_drawer == null or incident_drawer.water != null:
		return
	if build_sheet == null or build_sheet.controller == null:
		return
	incident_drawer.bind_water(build_sheet.controller.water)


## `Callable(kind: StringName, id) -> Vector3`, called as `(&"tile", Vector2i)`.
## The same shape `set_alert_locator` takes, so one shell function serves both —
## and S16's rows take it on the same call, which is why "tap the row, look at
## the site" needed no new line in `game/main.gd` at all.
func set_incident_locator(locator: Callable) -> void:
	if incident_drawer != null:
		incident_drawer.set_locator(locator)
	if construction_queue != null:
		construction_queue.set_locator(locator)


## Where the drawer's `Nearest` sort measures from — the camera focus.
func set_incident_reference(world_pos: Vector3) -> void:
	if incident_drawer != null:
		incident_drawer.set_reference(world_pos)


## `Callable(incident_id: int) -> Array[Dictionary]` — see `UnitPickerModel` for
## the row shape.
func set_unit_provider(provider: Callable) -> void:
	if unit_picker != null:
		unit_picker.set_provider(provider)


## The shell's verdict on a `dispatch_requested`. Returns the toast copy.
##
## `result` is the whole `CommandQueue` answer and is optional (Wave 18, PA-52):
## `ok` alone cannot tell the picker WHICH of doc 06's three dispatch refusals it
## is reporting, and the three have three different next moves. Additive, so
## every existing caller compiles unchanged.
func report_dispatch_result(unit_id: int, ok: bool,
		result: Dictionary = {}) -> String:
	feed_onboarding({"kind": OnboardingModel.OBS_COMMAND, "command": "dispatch_unit",
			"ok": ok, "unit_id": unit_id})
	if haptics != null:
		haptics.fire(Haptics.CUE_DISPATCH if ok else Haptics.CUE_BLOCKED)
	return unit_picker.report_result(unit_id, ok, result) \
			if unit_picker != null else ""


# ---------------------------------------------------------------------------
# S12 — the onboarding seam (doc 12 §2.17)
#
# Four calls and two signals, all of them optional. `game/main.gd` wires it in
# `_wire_ui_screens()` and its `_process`; nothing else changes:
#
#     # --- bring-up, after the other screens are bound -----------------------
#     var sim := sim_host.sim
#     root.set_onboarding_world_resolver(_coach_world_rect)
#     root.onboarding_action.connect(_on_coach_action)
#     if _is_new_city:                       # never on a loaded save: the `ui`
#         root.start_onboarding({            # section resumes that one itself
#             "tutorial_lot_a": sim.loader.resolve_tag("tutorial_lot_a")["tile_global"],
#             "tutorial_lot_b": sim.loader.resolve_tag("tutorial_lot_b")["tile_global"],
#         })
#
#     # --- per frame: the only observation the root cannot make for itself ---
#     func _process(_dt: float) -> void:
#         ui_root.feed_onboarding({"kind": "camera", "focus": camera_state.focus,
#                 "zoom_t": camera_state.zoom_t})
#
#     # --- the two requests only the shell can serve -------------------------
#     func _on_coach_action(action: StringName, payload: Dictionary) -> void:
#         match action:
#             &"focus_camera":
#                 var tile: Vector2i = sim.loader.resolve_tag(
#                         str(payload["tag"]))["tile_global"]
#                 camera_state.focus_on(Vector3(tile.x * 8.0, 0.0, tile.y * 8.0))
#             &"trigger_tutorial_incident":
#                 sim.trigger_tutorial_transformer_failure()
#             &"suppress_director":
#                 # §2.17's budget is REAL seconds, doc 07's hold is game time.
#                 sim.suppress_director(float(payload.get("seconds", 300.0))
#                         * SimHost.GAME_MS_PER_REAL_MS)
#             &"release_director":
#                 sim.release_director()
#
#     # --- world tag → screen rectangle for the cutout -----------------------
#     func _coach_world_rect(tag: String) -> Variant:
#         var tile: Vector2i = sim.loader.resolve_tag(tag).get("tile_global",
#                 Vector2i.ZERO)
#         var answer := camera_state.project_to_screen(
#                 Vector3(tile.x * 8.0 + 4.0, 0.0, tile.y * 8.0 + 4.0),
#                 Vector2(get_viewport().get_visible_rect().size))
#         return null if bool(answer["behind"]) else answer["position"]
#
# `tools/onboarding_preview.gd` is a working copy of exactly this wiring, over
# `game/main.tscn`, and is how the coach marks were screenshotted.
#
# Sim events, the build sheet, the incident drawer and the dispatch verdict all
# feed themselves through calls `game/main.gd` already makes (`feed_events`,
# `report_dispatch_result`) — there is nothing to add for those.
# ---------------------------------------------------------------------------

## Starts the scripted first fifteen minutes. `regions` maps the doc 09 §2.9.7
## tutorial tags the step table names to world tiles, e.g.
##
##     ui_root.start_onboarding({
##         "tutorial_lot_a": sim.loader.resolve_tag("tutorial_lot_a")["tile_global"],
##         "tutorial_lot_b": sim.loader.resolve_tag("tutorial_lot_b")["tile_global"]})
##
## Returns false when there is no coach layer, or when this city has already been
## through the tutorial — §2.17's "never shows again once done".
func start_onboarding(regions: Dictionary = {}) -> bool:
	if onboarding == null:
		return false
	return onboarding.start(regions)


## One observation into the step machine; see `OnboardingModel` for the shapes.
## Safe to call always — it is a no-op when the tutorial is not running, which is
## what lets the shell feed the camera every frame without a guard of its own.
func feed_onboarding(observation: Dictionary) -> bool:
	if onboarding == null or not onboarding.is_active():
		return false
	return onboarding.feed(observation)


## How a world tag becomes a screen rectangle for the cutout:
## `Callable(tag: String) -> Variant` returning a `Rect2`, a `Vector2` screen
## point, or null. Only the shell can project world → screen (doc 11 owns the
## camera), so only the shell supplies this.
func set_onboarding_world_resolver(resolver: Callable) -> void:
	if onboarding != null:
		onboarding.set_world_resolver(resolver)


func onboarding_active() -> bool:
	return onboarding != null and onboarding.is_active()


## Settings ▸ Replay tutorial, and the shell's own "start a new city" path.
func reset_onboarding() -> void:
	if onboarding != null:
		onboarding.reset()


## The root serves what it owns and re-emits everything else. `focus_camera` and
## `trigger_tutorial_incident` are the shell's, because `ui/` holds no sim and no
## camera; the three menu actions are the root's, because it is the only object
## that knows all the screens exist (§4.1).
func _on_onboarding_action(action: StringName, payload: Dictionary) -> void:
	match action:
		OnboardingModel.ACTION_OPEN_BUILD_SHEET:
			if build_sheet != null and not build_sheet.is_open():
				build_sheet.open()
		OnboardingModel.ACTION_OPEN_BUILD_CATEGORY:
			if build_sheet != null:
				if not build_sheet.is_open():
					build_sheet.open()
				build_sheet.select_category(str(payload.get("category", "")))
		OnboardingModel.ACTION_OPEN_INCIDENT_DRAWER:
			if incident_drawer != null and not incident_drawer.is_open():
				incident_drawer.open()
	onboarding_action.emit(action, payload)


func _on_onboarding_finished(was_skipped: bool) -> void:
	# A discovery mark the tutorial was standing on is owed, not lost: the first
	# collectable a player ever sees is worth explaining late, and skipping the
	# tutorial is exactly the case where nothing else has explained it.
	if street != null and onboarding != null:
		var owed := street.take_pending()
		if not owed.is_empty():
			onboarding.show_notice(str(owed["text"]), owed["world_pos"] as Vector3,
					bool(owed["has_pos"]), float(owed["ttl_s"]))
	onboarding_finished.emit(was_skipped)


func _on_build_sheet_toggled(open: bool) -> void:
	if not open:
		return
	feed_onboarding({"kind": OnboardingModel.OBS_UI_OPENED,
			"path": OnboardingFlow.SCREEN_BUILD_SHEET})


func _on_drawer_toggled(open: bool) -> void:
	if not open:
		return
	feed_onboarding({"kind": OnboardingModel.OBS_UI_OPENED,
			"path": OnboardingFlow.SCREEN_INCIDENT_DRAWER})


## Every ghost move. Two observations come out of it: what the preflight said
## (§2.17's `E_UNSERVED` wall is a *verdict*, never a refused command — the PLACE
## button is disabled before the player can press it), and a memo of what is
## about to be placed, for the commit below.
func _on_build_placement_changed() -> void:
	if build_sheet == null or build_sheet.controller == null:
		return
	var controller := build_sheet.controller
	if not controller.is_placing() or not controller.has_origin:
		return
	_pending_place = {
		"archetype": controller.archetype,
		"component_kind": controller.component_kind,
		"tile": controller.origin,
	}
	var verdict := controller.verdict()
	var code := str(verdict.get("code", ""))
	if code != "":
		feed_onboarding({"kind": OnboardingModel.OBS_VERDICT, "code": code,
				"tile": controller.origin})


func _on_build_placement_committed(result: Dictionary) -> void:
	var kind := str(_pending_place.get("component_kind", ""))
	feed_onboarding({
		"kind": OnboardingModel.OBS_COMMAND,
		"command": "place_grid_component" if kind != "" else "place_building",
		"ok": bool(result.get("ok", false)),
		"archetype": str(_pending_place.get("archetype", "")),
		"tile": _pending_place.get("tile", Vector2i.ZERO),
	})


## The one thing the coach layer cannot learn from a signal: the build sheet has
## no `category_changed`, and §2.17's `unserved_wall` step lets a player who
## works out the fix on their own skip ahead by opening the GRID tab. Polled only
## while the tutorial is running, and never otherwise.
func _process(_delta: float) -> void:
	_update_ui_coverage()
	solve_rail_stack()
	solve_tilt_slider()
	solve_follow_chip()
	if onboarding == null or not onboarding.is_active() or build_sheet == null:
		return
	var category := build_sheet.active_category() if build_sheet.is_open() else ""
	if category == _last_build_category:
		return
	_last_build_category = category
	if category != "":
		feed_onboarding({"kind": OnboardingModel.OBS_UI_OPENED,
				"path": OnboardingFlow.SCREEN_BUILD_CATEGORY + category})


## §2.3's LEFT rail, solved in one pass like D-46 solves the right one.
##
## Its three members are not siblings — the BUILD FAB is on `SheetLayer` and the
## other two on `HUDLayer` — so nobody could walk a parent to find them and each
## file placed its own control against its own measurement. Two of those
## measurements were taken at different moments and disagreed (see
## `UIWidgets.solve_rail_stack` for the 93-against-73 arithmetic), which is a
## stack only by coincidence. This is the one place that owns the pitch.
##
## Idempotent and cheap: three minimum-size reads, and `Control.set_offset()`
## early-returns on an unchanged value, so a frame in which nothing moved costs
## nothing. Called from `_process`, from `_recompute_layout` and at the end of
## `force_layout`, because a headless mount never gets a frame.
func solve_rail_stack() -> void:
	if config == null:
		return
	var entries: Array = []
	for screen: Node in [build_sheet, overlay_rail, hud]:
		if screen == null or not screen.has_method("rail_entry"):
			continue
		var entry: Dictionary = screen.call("rail_entry")
		if entry.get("control") != null:
			entries.append(entry)
	if entries.is_empty():
		return
	var pitch := UIWidgets.solve_rail_stack(entries, config.layout(),
			float(ThemeBuilder.touch_min_dp(config, _text_scale(), _larger_targets())))
	if hud != null:
		hud.set_rail_pitch(pitch)


func _text_scale() -> float:
	return UIConfig.get_num(config.section("defaults"), "text_scale", 1.0)


func _larger_targets() -> bool:
	return bool(config.section("defaults").get("larger_touch_targets", false))


## How much of the safe area a sheet, panel or modal currently covers, 0..1.
## `game/audio/audio_service.gd` uses it for the interior muffle (doc 11
## §2.15.1): over half the screen and the city is heard through the sheet.
## Recomputed per frame over <= 12 Controls — far cheaper than remembering to
## emit from all eight screen-toggle handlers and missing the ninth.
func _update_ui_coverage() -> void:
	if safe_area == null:
		return
	var area := safe_area.get_global_rect()
	if area.get_area() <= 0.0:
		return
	var covered := 0.0
	for layer: Control in [modal_layer, sheet_layer, panel_layer]:
		if layer == null or not layer.visible:
			continue
		for child: Node in layer.get_children():
			var panel := child as Control
			if panel != null and panel.visible:
				covered += panel.get_global_rect().intersection(area).get_area()
	var coverage := clampf(covered / area.get_area(), 0.0, 1.0)
	if is_equal_approx(coverage, _last_coverage):
		return
	_last_coverage = coverage
	ui_coverage_changed.emit(coverage)


## `CitySim.cmd_set_tax_level` itself plus the detent it sits on.
func bind_tax(command: Callable, level: int, level_count: int, rate: float) -> void:
	if city_dashboard != null:
		city_dashboard.bind_tax(command, level, level_count, rate)


## Doc 03's settle snapshot, or the `economy_hour_settled` bus event.
func feed_settlement(snapshot: Dictionary) -> void:
	if city_dashboard != null:
		city_dashboard.feed_settlement(snapshot)


## One settled game-hour into the dashboard's ring (§2.10's sparklines).
func sample_history(row: Dictionary) -> void:
	if city_dashboard != null:
		city_dashboard.sample(row)


## The same plain snapshot `CityHUD.refresh()` takes, for the dashboard's bands.
func refresh_dashboard(snapshot: Dictionary) -> void:
	if city_dashboard != null:
		city_dashboard.refresh(snapshot)


## §2.10's Infrastructure tab: `{power, feeders, transformers, water}`.
func feed_infrastructure(snapshot: Dictionary) -> void:
	if city_dashboard != null:
		city_dashboard.feed_infrastructure(snapshot)


## §2.10's Response tab: `{units, stats, open}`.
func feed_response(snapshot: Dictionary) -> void:
	if city_dashboard != null:
		city_dashboard.feed_response(snapshot)


## §2.5's OverlayLegend aggregate lines, per mode: `[{label, value, state?}]`.
func feed_overlay_summary(mode: StringName, lines: Array) -> void:
	if overlay_rail != null:
		overlay_rail.set_summary_lines(mode, lines)


## The POWER overlay's three §2.5 aggregate lines, from `PowerActions.
## grid_reading()` (Wave 17, doc 12 §2.10 D-72).
##
## **On the legend and not the dashboard**, and the argument is §2.5's own: the
## dashboard's Infrastructure tab already lists every feeder and every
## transformer, which is the reference reading — a table you go and consult. This
## is the ORIENTING reading, and it belongs where the player is when the question
## occurs to them, which is standing in the power overlay looking at a red
## transformer. §2.5 allows exactly 1–3 aggregate lines on the legend card and
## `OverlayModel.summary_lines` drops the rest, so it is three:
##
##   1. the pool — demand of supply, and what is spare;
##   2. the WIRES — how many transformers and feeders are at WARNING or worse,
##      which is the line this wave exists for. Every `POWER_CAPACITY` blocker on
##      every city audited bound at a transformer while the pool sat at 6–56 % of
##      supply, so a reading that showed only line 1 told the player to buy a
##      power station, and a power station cleared nothing;
##   3. what is being held dark right now, when anything is.
##
## Static, and handed the config rather than reading `self`, so `tools/
## ui_preview.gd` photographs the shipping lines rather than a fixture of them.
static func power_summary_lines(reading: Dictionary, cfg: UIConfig) -> Array:
	if not bool(reading.get("available", false)):
		return []
	var lines: Array = [
		{"id": "pool", "label": UIWidgets.t(cfg, "ui_overlay_summary_power_pool"),
				"value": "%s / %s" % [reading["demand_text"], reading["supply_text"]],
				"state": HudModel.STATE_NORMAL if float(reading["load_ratio"]) < 0.9
						else HudModel.STATE_WARNING},
		{"id": "wires", "label": UIWidgets.t(cfg, "ui_overlay_summary_power_wires"),
				"value": "%d / %d" % [int(reading["transformers_warning"])
						+ int(reading["feeders_warning"]),
						int(reading["transformers"]) + int(reading["feeders"])],
				"state": reading["state"]},
	]
	if float(reading["shed_kw"]) > 0.0:
		lines.append({"id": "shed",
				"label": UIWidgets.t(cfg, "ui_overlay_summary_power_shed"),
				"value": str(reading["shed_text"]), "state": HudModel.STATE_CRITICAL})
	else:
		lines.append({"id": "wall", "label": UIWidgets.t(cfg, "ui_overlay_summary_power_wall"),
				"value": UIWidgets.t(cfg, str(reading["wall_key"])),
				"state": HudModel.STATE_NORMAL})
	return lines


## `{power01, water01}` on `[0, 1]` for the ⚡/💧 chips (§2.4 P3/P4) and for the
## dashboard bands that show the same two readings.
func ingest_service(snapshot: Dictionary) -> void:
	if hud != null:
		hud.ingest_service(snapshot)
	if city_dashboard != null:
		city_dashboard.ingest_service(snapshot)


## The resume handshake (§2.12). Returns `""` when the report opened, and the
## toast copy when the absence was too short and too quiet for a modal.
func present_away_report(input: Dictionary) -> String:
	return away_report.present(input) if away_report != null else ""


## The `ui` save section this scaffold owns today (doc 12 §3.2): the overlay
## choice, the settings block, the onboarding block, the street tally and —
## since Wave 17 (D-68) — the `camera` block: `{focus_x, focus_z, zoom_t,
## yaw_deg, pitch_mode, pitch_bias}`, written only when a camera is bound. The
## selection key joins them as that system lands.
func capture_ui_state() -> Dictionary:
	var out: Dictionary = {"section_version": 1}
	if overlay_rail != null:
		out.merge(overlay_rail.capture_state(), true)
	if settings_sheet != null:
		out["settings"] = settings_sheet.capture_state()
	if onboarding != null:
		out["onboarding"] = onboarding.capture_state()
	if street != null:
		out["street"] = street.capture_state()
	if camera_state != null:
		out["camera"] = camera_state.to_dict()
	return out


func restore_ui_state(state: Dictionary) -> void:
	if overlay_rail != null:
		overlay_rail.restore_state(state)
	# The camera comes back where the player left it, pitch included — through
	# `CameraState.from_dict`, which validates the band (§3.2: a save may not
	# resurrect an angle the data no longer allows). A save with no block, or a
	# mount with no camera, leaves the camera exactly where it is.
	if camera_state != null:
		var block: Variant = state.get("camera", {})
		if block is Dictionary and not (block as Dictionary).is_empty():
			camera_state.from_dict(block)
			if tilt_slider != null:
				tilt_slider.bind_camera(camera_state)
	if settings_sheet != null:
		var block: Variant = state.get("settings", {})
		settings_sheet.apply_state(block if block is Dictionary else {})
		# §2.13's auto-response rows are a VIEW of doc 06's policy, which lives in
		# the city's own save. A restored `ui.settings` block may carry a stale
		# copy of them; the sim's values win, always.
		_seed_dispatch_rows()
		if haptics != null:
			for key: StringName in [Haptics.SETTING_LEVEL, Haptics.SETTING_REDUCE_MOTION]:
				if settings_sheet.model.has_key(String(key)):
					haptics.apply_setting(key, settings_sheet.model.value(String(key)))
	if onboarding != null:
		var coach: Variant = state.get("onboarding", {})
		onboarding.restore_state(coach if coach is Dictionary else {})
	if street != null:
		var payday: Variant = state.get("street", {})
		street.restore_state(payday if payday is Dictionary else {})
		_push_side_revenue()


## doc 12 §2.1: `Control` coordinates are dp on every device, matching Android's
## own model, so the 48 dp gate means the same thing everywhere.
func _apply_content_scale() -> void:
	if not apply_content_scale:
		return
	var window := get_window()
	if window == null:
		return
	window.content_scale_factor = clampf(
			DisplayServer.screen_get_dpi(0) / DP_BASE_DPI, CONTENT_SCALE_MIN, CONTENT_SCALE_MAX)


## Rebuilds the single Theme from `data/ui.json` for the current accessibility
## settings and applies it at the root (doc 12 §4.3 — no per-node overrides).
func rebuild_theme(opts: Dictionary = {}) -> Theme:
	if config == null:
		config = UIConfig.load_from_files()
	theme_resource = ThemeBuilder.build(config, opts)
	if safe_area != null:
		safe_area.theme = theme_resource
	return theme_resource


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_GO_BACK_REQUEST:
			handle_back()
		NOTIFICATION_WM_SIZE_CHANGED:
			_recompute_layout()


# ---------------------------------------------------------------------------
# Safe area and breakpoints
# ---------------------------------------------------------------------------

func _recompute_layout() -> void:
	if safe_area == null or config == null:
		return
	var layout := config.layout()
	var rect := _safe_area_rect()
	var bleed := int(UIConfig.get_num(layout, "safe_area_bleed_dp", 4.0))
	var window := get_window()
	var win: Vector2i = window.size if window != null else Vector2i(rect.size)
	safe_area.add_theme_constant_override("margin_left", rect.position.x + bleed)
	safe_area.add_theme_constant_override("margin_top", rect.position.y + bleed)
	safe_area.add_theme_constant_override("margin_right",
			maxi(0, win.x - rect.end.x) + bleed)
	safe_area.add_theme_constant_override("margin_bottom",
			maxi(0, win.y - rect.end.y) + bleed)
	safe_area_changed.emit(rect)

	var width_dp := float(rect.size.x)
	var bp := UIRoot.breakpoint_for(width_dp, layout)
	drawer_w_dp = UIRoot.drawer_width_dp(width_dp, layout)
	if bp != current_breakpoint:
		current_breakpoint = bp
		breakpoint_changed.emit(bp)
	solve_rail_stack()
	solve_tilt_slider()
	solve_follow_chip()


## Replaces `DisplayServer.get_display_safe_area()` when it is set. A desktop
## display server answers that call with the *screen's* work area — origin at the
## developer's dock, size of the whole monitor — which is not a phone's cutout and
## which shifted every rectangle `tools/ui_preview.gd` measures by the width of
## whatever panel happened to be open. Harnesses and tests set a device box here;
## the game never touches it.
var safe_area_override := Rect2i()
var _last_coverage := -1.0


## Lays the whole deck out at a device box **without a rendered frame**.
##
## Godot queues a `Container`'s re-sort through the message queue, and a headless
## run — `tests/run_tests.gd` does everything inside `_initialize()` — never
## flushes one, so every `Control` in a mounted scene keeps a size of zero. That
## makes the defects this pass is about (text that does not fit, targets that
## collide, a bar that runs off the edge) invisible to the suite. This drives the
## same two notifications the engine would, top down, so `tests/test_ui_audit.gd`
## can measure the deck at four widths in the same second.
##
## Not used by the game: `main.tscn` gets frames.
func force_layout(box: Vector2i) -> void:
	safe_area_override = Rect2i(Vector2i.ZERO, box)
	if safe_area == null:
		return
	_recompute_layout()
	safe_area.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	safe_area.size = Vector2(box)
	UIRoot.sort_tree(safe_area)
	# After the sort, not before: the rail's pitch is a MEASUREMENT, and a
	# headless mount has none until the tree has been laid out once. The tilt
	# slider's band is measured the same way (the top bar's wrapped height).
	solve_rail_stack()
	solve_tilt_slider()
	solve_follow_chip()
	UIRoot.sort_tree(safe_area)


## One layout pass over a subtree, in tree order. Public so a harness can re-run
## it after opening a screen.
static func sort_tree(node: Node) -> void:
	var control := node as Control
	if control != null:
		control.notification(Control.NOTIFICATION_RESIZED)
	if node is Container:
		node.notification(Container.NOTIFICATION_SORT_CHILDREN)
	for child in node.get_children():
		UIRoot.sort_tree(child)


func _safe_area_rect() -> Rect2i:
	if safe_area_override.size.x > 0 and safe_area_override.size.y > 0:
		return safe_area_override
	var rect := DisplayServer.get_display_safe_area()
	if rect.size.x <= 0 or rect.size.y <= 0:
		var window := get_window()
		var size: Vector2i = window.size if window != null else Vector2i(880, 400)
		rect = Rect2i(Vector2i.ZERO, size)
	return rect


## COMPACT < 700 dp · REGULAR 700–899 · WIDE ≥ 900 (doc 12 §2.1).
static func breakpoint_for(width_dp: float, layout: Dictionary) -> Breakpoint:
	var bps: Variant = layout.get("breakpoints_dp", {})
	var block: Dictionary = bps if bps is Dictionary else {}
	var compact_max := UIConfig.get_num(block, "compact_max", 699.0)
	var regular_max := UIConfig.get_num(block, "regular_max", 899.0)
	if width_dp <= compact_max:
		return Breakpoint.COMPACT
	if width_dp <= regular_max:
		return Breakpoint.REGULAR
	return Breakpoint.WIDE


## `drawer_w = clamp(round(0.34 * W), 260, 340)` (doc 12 §2.1).
static func drawer_width_dp(width_dp: float, layout: Dictionary) -> int:
	var ratio := UIConfig.get_num(layout, "drawer_w_ratio", 0.34)
	var lo := UIConfig.get_num(layout, "drawer_w_min_dp", 260.0)
	var hi := UIConfig.get_num(layout, "drawer_w_max_dp", 340.0)
	return int(clampf(round(ratio * width_dp), lo, hi))


# ---------------------------------------------------------------------------
# Android back stack (doc 12 §2.2) — one place, one order
# ---------------------------------------------------------------------------

## Pure resolver so the order is testable without a scene tree. `ctx` keys:
## `modal_open`, `title_open`, `sheet_open`, `panel_open`, `placement_active`,
## `has_selection`, `back_pressed_recently`.
##
## `title_open` is the one entry that removes rungs rather than adding one. At
## the front door there is no city: no sheet can be up, no panel, no placement
## and no selection, so back means "leave the app" and takes the same two-press
## minimise pair it takes in an idle city. A modal opened FROM the title — S9 is
## the only one — still closes first, which is why the check sits second.
static func resolve_back(ctx: Dictionary) -> StringName:
	if bool(ctx.get("modal_open", false)):
		return BACK_CLOSE_MODAL
	if bool(ctx.get("title_open", false)):
		return BACK_MINIMISE if bool(ctx.get("back_pressed_recently", false)) \
				else BACK_PROMPT_MINIMISE
	if bool(ctx.get("sheet_open", false)):
		return BACK_CLOSE_SHEET
	if bool(ctx.get("panel_open", false)):
		return BACK_CLOSE_PANEL
	if bool(ctx.get("placement_active", false)):
		return BACK_CANCEL_PLACEMENT
	if bool(ctx.get("has_selection", false)):
		return BACK_DESELECT
	if bool(ctx.get("back_pressed_recently", false)):
		return BACK_MINIMISE
	return BACK_PROMPT_MINIMISE


func back_context(now_ms: float) -> Dictionary:
	return {
		"modal_open": _has_open_child(modal_layer),
		"title_open": title_open(),
		"sheet_open": _has_open_child(sheet_layer),
		"panel_open": _has_open_child(panel_layer),
		"placement_active": placement_active,
		"has_selection": selected_entity_id != "",
		"back_pressed_recently":
			(now_ms - _last_back_ms) <= BACK_TO_MINIMISE_WINDOW_S * 1000.0,
	}


## Resolves one back press and emits `back_requested`. Screens listen and do the
## closing; this class only owns the order.
func handle_back(now_ms: float = -1.0) -> StringName:
	var t := now_ms if now_ms >= 0.0 else float(Time.get_ticks_msec())
	var action := UIRoot.resolve_back(back_context(t))
	_last_back_ms = t
	if action == BACK_CLOSE_MODAL:
		_close_last(modal_layer)
	elif action == BACK_CLOSE_SHEET:
		_close_last(sheet_layer)
	elif action == BACK_CLOSE_PANEL:
		_close_last(panel_layer)
	elif action == BACK_CANCEL_PLACEMENT:
		placement_active = false
	elif action == BACK_DESELECT:
		selected_entity_id = ""
	back_requested.emit(action)
	return action


## Is anything on this layer actually open?
##
## Two kinds of child live on a layer. A **transient** one is pushed when it
## opens and freed when it closes, so its mere presence means "open" — that was
## the P1-30 scaffold's only case. A **persistent** screen (`BuildSheet`,
## `BuildingPanel`, P1-33/P1-34) is authored into `ui_root.tscn` and is always
## present, because its FAB has to stay on screen while the sheet itself is shut;
## it answers `is_open()` for itself. Anything else counts as open while visible.
static func _has_open_child(node: Node) -> bool:
	if node == null:
		return false
	for child in node.get_children():
		if child.has_method("is_open"):
			if bool(child.call("is_open")):
				return true
			continue
		var control := child as Control
		if control == null or control.visible:
			return true
	return false


## Closes the topmost open child: a persistent screen is told to `close()`, a
## transient one is popped and freed. Returns true when something closed.
static func _close_last(node: Node) -> bool:
	if node == null:
		return false
	for i in range(node.get_child_count() - 1, -1, -1):
		var child := node.get_child(i)
		if child.has_method("is_open"):
			if not bool(child.call("is_open")):
				continue
			if child.has_method("close"):
				child.call("close")
				return true
			continue
		var control := child as Control
		if control != null and not control.visible:
			continue
		node.remove_child(child)
		child.queue_free()
		return true
	return false
