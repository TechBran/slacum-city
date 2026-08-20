# 12 — UI/UX, Camera & Onboarding

**Status:** Draft v1 — subordinate to `00-constitution.md` (LOCKED).
**Covers spec:** §24.1 (camera), §26 (overlays), §40 (UI), §41 (onboarding), §49 (accessibility & mobile UX), §21.2 (WHILE YOU WERE AWAY), §22 (notification controls).
**Owns:** everything under `ui/`, the camera rig under `game/camera/`, and the tutorial director.

---

## 1. Overview & Goals

SLACUM CITY's UI is an **operations console**, not a storefront: the player must read city state fast, find the failure, and act on it with one thumb while the city is on fire. Three goals judge every decision below. **(1) Read the crisis in under 3 seconds** — from a cold open, the worst thing happening must be visible in the HUD (severity chip + map pin) with nothing opened. **(2) Act within two taps of seeing it** — incident → assign unit is exactly two taps; jump-to-worst-emergency is one (spec §49). **(3) Explain causality** — Core Rule 12 is a UI responsibility, discharged by the cascade card, the overlay state language, and requirement-failure messaging, which together make invisible dependency edges visible.

Architectural stance (constitution §3): **`ui/` is a dumb view over pure logic.** Everything expressible without a `Node` — gesture recognition, camera math, sort orders, layout solving, string formatting, the onboarding state machine, the in-app alert gate — lives in `ui/logic/` as `RefCounted` classes with headless tests; `Control` nodes only bind those classes to pixels. UI never mutates sim state; it emits **commands** (§4.4) and reads **snapshots/events**. MVP non-goals: portrait, tablet layouts, controller/keyboard input, and localization beyond the externalized English string table `data/strings.en.json` this doc owns (§3.1, report 98 G-8).

---

## 2. Mechanics

### 2.1 Units, reference device, breakpoints

**UI unit = 1 dp** (Android density-independent pixel) everywhere in this doc and in `data/ui.json`. Godot config: `stretch/mode = "disabled"`, `stretch/aspect = "expand"`, orientation `sensor_landscape`; at startup `UIRoot._ready()` sets `get_window().content_scale_factor = clamp(DisplayServer.screen_get_dpi(0) / 160.0, 1.0, 4.0)`, so `Control` coordinates are dp on every device, matching Android's own model. **Reference layout box: 880 × 400 dp** (1080×2400 px at density 2.75 → 873×393 dp). **Guaranteed-safe minimum: 640 × 340 dp** — nothing may clip, overlap or become unreachable at or above that size. `SafeArea` is a `MarginContainer` whose margins come from `DisplayServer.get_display_safe_area()` in dp plus a 4 dp bleed, recomputed on `NOTIFICATION_WM_SIZE_CHANGED`; nothing interactive sits outside it.

| Breakpoint | Effective width W (dp) | Rules |
|---|---|---|
| `COMPACT` | < 700 | Building panel becomes a bottom sheet; drawer width 260; top-bar collapse aggressive |
| `REGULAR` | 700 – 899 | Reference layout |
| `WIDE` | ≥ 900 | Drawer 340 dp; top bar never collapses |

Drawer width formula: `drawer_w = clamp(round(0.34 * W), 260, 340)`.

### 2.2 Screen map

| # | Screen / surface | Node | Presentation | Entry | Exit |
|---|---|---|---|---|---|
| S0 | **Title / front door** | `TitleScreen` | full, own `TitleLayer` | app start (shell calls `UIRoot.present_title()`) | CONTINUE / NEW CITY, dismissed by the shell |
| S1 | **City view + HUD** | `CityHUD` | persistent | default | — |
| S2 | Build menu | `BuildSheet` | bottom sheet 200 dp | Build FAB | back / card pick |
| S3 | Placement mode | `PlacementBar` | 56 dp bar + 3D ghost | card pick | Confirm / Cancel |
| S4 | Land purchase | `LandPanel` | side panel 300 dp | Build ▸ Land tab ▸ tap block | Purchase / back |
| S5 | Building panel | `BuildingPanel` | side 300 dp (sheet on COMPACT) | tap building | back / tap map |
| S6 | Incident drawer | `IncidentDrawer` | right drawer, see 2.6 | handle / badge | handle / back |
| S7 | Unit picker | `UnitPickerSheet` | bottom sheet 240 dp | Assign | pick / back |
| S8 | City dashboard | `DashboardModal` | full-screen modal | tap any stat chip | back |
| S9 | Settings | `SettingsModal` | full-screen modal | Dashboard ▸ gear | back |
| S10 | Notifications settings | `NotifSettings` | page inside S9 | Settings ▸ Notifications | back |
| S11 | **WHILE YOU WERE AWAY** | `AwayReport` | full-screen modal | resume, see 2.12 | Dismiss / Handle now |
| S12 | Onboarding coach layer | `CoachLayer` | overlay above all | new save | step 11 done / skip |
| S13 | Event log | `EventLogModal` | full-screen modal | Away report ▸ See all | back |
| S14 | **Goals** | `GoalsSheet` | full-screen modal | the goal chip (§2.4), or the tutorial's last step | back |

Android **Back** is a stack: `ModalLayer` → `SheetLayer` → `PanelLayer` → placement cancel → deselect → "Press back again to minimise" (2 s window). Handled in one place: `UIRoot._notification(NOTIFICATION_WM_GO_BACK_REQUEST)`. **S0 removes rungs rather than adding one**: while the title is up there is no city behind it, so the four middle rungs cannot apply and back goes straight to the minimise pair — but `ModalLayer` still wins, or back at the settings sheet opened from the title would quit the game.

### 2.3 HUD layout (reference box 880 × 400 dp)

```
┌──────────────────────────────────────────────────────────────────┐
│ [$8.42M][⚠7][⚡91%][💧97%][👥184,291][+$138K/d][Stab: Mod]  ⛈ 06:12│ ← TopBar h=48
├──────────────────────────────────────────────────────────────────┤
│ ┌─Legend─┐                                                  ╔═══╗│
│ │ power  │                                                  ║ I ║│ ← drawer handle
│ │ ● norm │            3D CITY VIEW                          ║ N ║│   44×160, centre y=H-140
│ │ ▲ warn │        (incident pins projected here)            ║ 7 ║│
│ └────────┘                                                  ╚═══╝│
│                                                                  │
│  ( ⏱ )                                                           │ ← speed, 56
│  ( ◈ )                                                     ( ➤ ) │ ← overlays 56 / jump-to-worst 56
│  (BUILD)                                                         │ ← FAB 64
└──────────────────────────────────────────────────────────────────┘
```

Exact geometry (all inside `SafeArea`, origin top-left, H = safe height, W = safe width):

| Element | Rect (x, y, w, h) dp | Frequency class |
|---|---|---|
| `TopBar` | (0, 0, W, 48) | read-only + rare |
| Stat chips | left-aligned from x=8, gap 6, h=48 | rare tap → S8 |
| Clock+weather chip | right-aligned, w=132, h=48 | rare |
| `OverlayLegend` | (12, 60, 200, auto ≤ 180) | occasional |
| Build FAB | (12, H−76, 64, 64) | **frequent** |
| Overlay button | (16, H−140, 56, 56) | frequent |
| Speed button | (16, H−204, 56, 56) | occasional |
| Jump-to-worst | (W−72, H−72, 56, 56) | **frequent** |
| Drawer handle | (W−44, H−220, 44, 160) | **frequent** |
| Alert banner stack | (W/2−200, 56, 400, 44 each, max 2) | notification |
| Toast | (W/2−160, H−60, 320, 40) | notification |

**Thumb-reach model (landscape, two-handed).** Thumb pivots at `PL=(28, H−28)` and `PR=(W−28, H−28)`; classify by Euclidean distance from the nearer pivot to the control's centre, `d = |centre − pivot|`. `d ≤ 110 dp` = **frequent** — Build FAB (centre `(44, H−44)`, `d = √(16²+16²) = 22.6`), Jump-to-worst (centre `(W−44, H−44)`, `d = √(16²+16²) = 22.6`), Overlay button (centre `(44, H−112)`, `d = √(16²+84²) = 85.5`), drawer handle (centre `(W−22, H−140)`, `d = √(6²+112²) = 112.2`, boundary accepted), placement Confirm/Cancel, unit-picker row hit areas. `110 < d ≤ 165 dp` = **occasional** — speed button (centre `(44, H−176)`, `d = √(16²+148²) = 148.9`), legend collapse, build-sheet tabs. `d > 165 dp` = **rare only**, and must also be index-finger reachable at a screen edge; the top bar (d ≈ 340) qualifies as rare, edge-anchored, 48 dp tall. Hard rule: **no destructive or time-critical action may live outside the ≤165 dp zones.**

### 2.4 Stat chips (spec §40.1)

Priority order (1 = never dropped). Each chip: icon glyph + value, `h=48`, tap opens S8 scrolled to that section, long-press shows a 24 h sparkline popover.

| P | Chip | Full w | Compact w | Value format | State thresholds |
|---|---|---|---|---|---|
| 1 | Treasury | 104 | 72 | `$8.42M` | `< 0` → CRITICAL; projected-insolvent-in-24 h → WARNING |
| 2 | Active incidents | 64 | 48 | `7` + worst-tier badge | badge = `max(tier)` over active incidents (doc 06: `tier = clamp(floor(severity),1,5)`) |
| 3 | Grid health | 80 | 56 | `91%` | ≥95 NORMAL, 85–94 WARNING, 60–84 CRITICAL, <60 CRITICAL+pulse |
| 4 | Water health | 80 | 56 | `97%` | same as grid |
| 5 | Population | 104 | 64 | `184,291` | Δ<−0.5%/day → WARNING |
| 6 | Net income | 96 | 64 | `+$138K/d` | `<0` → WARNING, `<−5%` treasury/day → CRITICAL |
| 7 | Stability | 112 | 64 | word + 4-seg bar | doc 09 publishes `city_stability ∈ [0,1]`; the UI displays `round(100·s)` and bands it ≥75 High, 50–74 Moderate, 25–49 Low, <25 Critical. The conversion happens once, in the chip |
| 8 | Weather | (in clock chip) | icon only | `⛈ 06:12` + `Storm 0:42` countdown when a forecast warning is live | forecast warning → WARNING pulse |

**Collapse algorithm** (`TopBarLayoutSolver`, pure, headless-tested):

```
avail = W - clock_w - 16                 # 8 dp margin each side
mode[i] = FULL for all chips
loop:
  need = sum(width(i, mode[i])) + 6*(count_visible-1)
  if need <= avail: break
  j = lowest-priority chip with mode == FULL      # demote before hiding
  if j exists: mode[j] = COMPACT; continue
  k = lowest-priority chip with mode == COMPACT and priority > 4
  if k exists: mode[k] = HIDDEN; continue
  break                                            # P1–P4 are never hidden
```

Worked example, W = 640 (COMPACT), clock_w = 100 → avail = 524.
FULL widths P1..P7 = 104+64+80+80+104+96+112 = 640 + gaps 36 = 676 > 524.
Demote P7→64 (628), P6→64 (596), P5→64 (556), P4→56 (532), P3→56 (508 ≤ 524 ✓).
Result: all seven chips visible, P3–P7 compact. Net income and Stability keep their icon + numeric value at 64 dp; nothing is hidden at 640 dp.

**The eighth chip, and why it is not in the table above (Wave 9).** §2.19's goal
chip — `◎ L2 · 2/3` — rides the same bar and the same solver, but it is **not a
row of `layout.chip_priority`**. The seven above are permanent instruments; the
goal chip is a teaching surface that RETIRES the moment doc 09 §2.14's
curriculum is finished. Making it a permanent row would cost the reference
layout a demotion for the whole life of every city, including the ones it can no
longer teach anything, and this section's own claim — *"W = 880 keeps all chips
FULL"* — would stop being true for everybody.

So `HudModel` inserts it at `layout.goal_chip_index` (1, immediately after the
treasury) **while `goals_visible`**, and widens §2.4's never-hidden prefix by one
so the same four readings stay protected. Its widths are 104 / 56 (`◎ L2 · 2/3`
full, `2/3` compact — the compact form keeps the fraction, because the fraction
is what moves). Its tap is the one exception to "tap opens S8": it opens S14,
because there is no dashboard band for a goal.

With the chip up the reference box demotes the two lowest-priority chips to
COMPACT (need 786 against avail 732) and still shows every reading on one row;
at 1,280 dp everything is FULL. Both are asserted in
`tests/test_ui_goals.gd`.

Number formatting (`NumberFormat`, pure): `money(n)` → `$8,420` below 10K, `$842K` below 10⁶, `$8.42M` below 10⁹, else `$8.42B`, always 3 significant digits above 10K and negatives as `−$1.2M`; `rate(per_game_hour)` displays per day as `value * 24` with a `+`/`−` prefix and `/d` suffix; `eta(sec)` is `m:ss` under an hour and `h:mm` above; `pop(n)` is thousands-grouped with `,`.

### 2.5 Overlay system (spec §26)

Six overlays, **mutually exclusive** in MVP: `NONE, POWER, WATER, POLICE, FIRE, TRAFFIC` (`CONSTRUCTION` deferred).

**Toggle UX.** Tapping the Overlay button raises `OverlayStrip`: six 64 × 56 dp chips sliding up from the button, anchored bottom-left at x-offset 80 so the thumb doesn't cover them. The strip is *sticky* (open until dismissed or an overlay is chosen), so switching overlays while diagnosing a cascade is one tap each; the active chip is filled and carries a check glyph. Long-pressing the Overlay button toggles `NONE` ↔ last-used overlay (fast A/B compare). The choice persists in the save.

**What renders.** Entering any overlay de-emphasises the world (post-process `saturation → 0.25`, `exposure ×0.70`, over 0.18 s), then draws:

| Overlay | Geometry drawn | Per-element state readout |
|---|---|---|
| POWER | plants, substations, transformers, transmission + distribution edges, animated flow dashes (speed ∝ load/capacity), outage polygons (block fill at 25 % alpha) | node ring = state; edge = state pattern; label `load/cap` above threshold |
| WATER | the five `water_facility` variants (source, treatment, pump, tank, booster — §2.7), mains, pressure zones (fill tinted by pressure) | pump/tank state ring; zone label `psi` band |
| POLICE | stations, coverage discs, unit dots (available/en-route/on-scene), crime heat (hex bins, 32 m) | station ring = free-unit ratio; heat 5-step ramp |
| FIRE | stations, coverage discs, engine dots, hydrant effectiveness ring per block, fire-risk hex bins | hydrant ring = water-pressure-derived state |
| TRAFFIC | road edges coloured by congestion, closure markers, flood markers, active emergency routes drawn as bright polylines | edge width ∝ congestion, pattern by state |

**Constitution-compliant state language** (spec §13.5). There are exactly **four** data states. Every state carries **hue + glyph + line pattern + motion**, so colour is never load-bearing:

| State | Hex | Rel. luminance | Glyph | Line pattern | Motion |
|---|---|---|---|---|---|
| NORMAL | `#33C27A` | 0.39 | `●` filled circle | solid | none |
| WARNING | `#F2B13C` | 0.50 | `▲` triangle | dash 8/6 | slow flow |
| CRITICAL | `#E5533D` | 0.23 | `◆` diamond | dash 4/4 | pulse 1.2 Hz |
| OFFLINE | `#5A6270` | 0.13 | `✕` cross | dot 2/6 | none |

All pairwise luminance gaps among the four states are ≥ 0.10, so the set survives full grayscale.

**Selection is not a fifth state (report 98 C-64).** These four are exactly doc 11's per-instance `overlay_state`, packed into 2 bits of the instance custom data (packing constant 112 — doc 11 owns it, this doc never restates the bit layout). A selection is transient and single-valued, so it is drawn by the UI layer instead: `MarkerLayer` (§2.15) strokes a `#4FA8FF` ring, glyph `◎`, solid 3 dp, breathing at 0.6 Hz, around the selected entity's projected footprint. It never occupies an `overlay_state` slot, never reaches the instance buffer, and is never persisted per building — the save carries at most one selected entity id. Its tunables live under `data/ui.json.selection_ring`, not under `state_*`. Colourblind palette variants (`deuteran`, `protan`, `tritan`) swap **hex only** — glyphs and patterns are identical across variants, which is what actually guarantees readability.

**Legend card** (`OverlayLegend`, top-left, 200 dp): overlay name, the 4 state rows (swatch + glyph + label), plus 1–3 overlay-specific aggregate lines (e.g. POWER: `Generation 42.1 / 51.0 MW`, `Feeders overloaded: 2`). Collapsible to a 32 dp pill; collapse state persists per overlay.

### 2.6 Incident drawer & dispatch UX (spec §40.2)

**Handle (collapsed).** 44 × 160 dp tab on the right edge centred at `y = H−140`, showing total count, worst-tier colour fill, worst-tier digit, and a thin escalation bar for the incident nearest its next tier. Pulses at 1.2 Hz while any T4/T5 incident is unassigned. (Throughout this doc `T1…T5` is shorthand for doc 06's derived `tier`.) **Expanded**: slides in to `drawer_w` in 0.22 s `ease_out_cubic`, occupying `y ∈ [48, H]`, never covering the left rail or FAB. While open the camera's usable viewport is `[0, W−drawer_w]` and every `focus_on()` offsets by `−drawer_w/2` in screen space so a jumped-to incident lands centred in the *visible* area.

**Sort orders.** Segmented control at the drawer top: `Priority` (default) | `Nearest` | `Newest` | `Unassigned`.
`Priority` comparator (`IncidentSorter`, pure):

```
key(i) = ( -tier,                           # T5 first
           t_next_tier_h,                   # soonest to escalate first (INF when HELD)
           -waiting_s,                       # longest wait first
           id )                              # stable tiebreak
unassigned incidents sort before assigned ones of equal tier
```

**Row** — 72 dp tall, full drawer width:

```
┌──────────────────────────────────────────────┐
│ ┏━━┓  Transformer failure          02:41 ⏱   │
│ ┃T4┃  Harbour District · 3 blocks dark       │  72 dp
│ ┗━━┛  ▓▓▓▓▓▓▓░░░ T5 in 1:12       [ASSIGN]   │
└──────────────────────────────────────────────┘
```

Severity badge 40 × 40 dp = fill colour + **tier digit** + glyph. Doc 06 makes `severity` a continuous float in `[1.0, 5.0]` with `tier = clamp(floor(severity), 1, 5)`; the UI shows the tier digit everywhere and never a float — that digit is the primary redundancy channel, making a marker readable with zero colour vision. The **escalation bar** is doc 06's "clock the player can read": `fill = severity − tier` (fraction of the way to the next tier), countdown
`t_next_tier_h = (tier + 1 − severity) / (esc_rate · max(0, 1 − assist_ratio))`.
When `assist_ratio ≥ 1` the denominator is 0: the bar freezes, turns NORMAL green, its glyph becomes `●` and the label reads **`HELD`** — the clearest possible signal that enough units are on scene. Below 25 % of remaining time (or under 0.25 tiers to go) the bar takes CRITICAL styling. Tier badges carry their own glyph set for A5 redundancy — `T1 ▪`, `T2 ▴`, `T3 ▴▴`, `T4 ◆`, `T5 ✶` (pulsing ring at 1.2 Hz) — over `palette.tier1…tier5`; the digit alone is sufficient, the glyph and colour are reinforcement. Assigned units render as 24 dp chips replacing the ASSIGN button (tap → `Recall`). Row tap anywhere but ASSIGN → `camera.focus_on(incident.pos, dist=90 m)` **and** selects the incident (pin gets the SELECTED ring); the drawer stays open.

**Assign-unit flow** (spec requirement: tap incident → unit picker sorted by ETA):

1. Tap `ASSIGN` → `UnitPickerSheet` rises from the bottom (240 dp, full width, over the drawer).
2. Header: incident title, `Required: 1× Utility Truck`, `Optional: 1× Heavy Repair`, and a primary **`AUTO — best available`** button (dispatches the top-ranked eligible unit).
3. Rows (56 dp), **sorted by ETA ascending**, ineligible units last and dimmed:

   | col | content |
   |---|---|
   | icon | department + type glyph |
   | name | `Utility 1 · Public Works Yard` |
   | ETA | `0:48` (bold, mono) — from doc 06 |
   | status | `Available` / `Returning (frees 1:10)` / `On scene @ Incident #14` |
   | tag | `REQUIRED` / `OPTIONAL` / `WRONG TYPE` |

   Rank key: `(not eligible, status_rank, eta_seconds, id)` where `status_rank = 0 Available, 1 Returning, 2 Reassignable-busy`.
4. Tap a row → issues `dispatch_unit`, sheet closes in 0.15 s, toast `Utility 1 dispatched — ETA 0:48` with a 5 s **UNDO** (issues `recall_unit`).
5. **All units busy:** the sheet shows a full-width state card — `No unit free. Queue position 2. Soonest: Utility 2 in 1:40.` — with `Queue anyway` (registers intent; auto-dispatches the moment a unit frees) and `Buy a unit` (deep-links to Build ▸ Civic).
6. After a successful dispatch the camera offers **follow mode**: a 32 dp chip `Following Utility 1 ✕`. Any manual pan cancels follow.

**Alternate dispatch entries** (same command, same picker): tap an incident **map pin** → 200 dp mini-card with `Assign` / `Details`; or tap a **unit** → unit panel → `Send to…` → tap an incident pin.

### 2.7 Build menu, placement mode & requirement messaging

**Build sheet (S2).** Bottom sheet 200 dp; 40 dp tab bar `Residential · Commercial · Industrial · Civic · Utility · Roads · Land`, below it a horizontally scrolling row of 96 × 120 dp cards (silhouette thumbnail, name, cost `$12.4K`, and a 3-icon micro-row `⚡2.4 kW · 💧0.8 m³/h · ▦2×2`). Unaffordable cards show cost in CRITICAL colour but stay tappable so the requirement panel can explain why; locked cards show a lock glyph and reveal the unlock condition on tap. Costs, kW and m³/h on the card face are read from the archetype table, never authored here (doc 03 owns cost, doc 02 owns `base_kw` and water demand).

**One card per placeable thing, including `water_facility` variants (report 98 C-35).** A card maps 1:1 to a `place_building` payload, so an archetype that carries a `variant` discriminator contributes one card *per variant* — a gravity tank and a treatment plant are different buildings to the player and must not hide behind one card with a hidden dropdown. The Utility tab therefore lists **eight** cards:

| Tab | Card | `place_building` payload | Notes |
|---|---|---|---|
| Utility | Substation | `{type_id:"substation"}` | doc 04 owns capacity |
| Utility | Power Plant | `{type_id:"power_facility"}` | |
| Utility | Power Line | `place_path{kind:"power_line"}` | drag-path, §2.7 below |
| Utility | Water Source | `{type_id:"water_facility", variant:"source"}` | intake |
| Utility | Treatment Plant | `{type_id:"water_facility", variant:"treatment"}` | |
| Utility | Pump Station | `{type_id:"water_facility", variant:"pump"}` | |
| Utility | Storage Tank | `{type_id:"water_facility", variant:"tank"}` | lowest draw of the five |
| Utility | Booster | `{type_id:"water_facility", variant:"booster"}` | |
| Utility | Water Main | `place_path{kind:"water_main"}` | drag-path |

Each variant card renders **its own** footprint, `base_kw` and capacity in the micro-row — the five differ, which is the whole point of the variant split — and each carries its own five-level pip row in the building panel (Core Rule 5 holds per variant). Doc 02 owns the variant list and the building shell; doc 05 owns the per-variant numbers; this doc owns only the card layout and the ordering above. Transformers are grid components, not buildings (doc 04): they never appear as a build card and are never placed through `place_building`.

**Placement mode (S3).** Selecting a card collapses the sheet to a 56 dp `PlacementBar`:

```
[ ✕ ]  House · $12.4K   ⚠ 2 issues   [ ↻ ]   [ ✔ PLACE ]
  48         flexible       tap→expand   56        64
```

Ghost = translucent instance of the real mesh snapped to the 8 m tile grid (constitution §6) with a footprint decal, anchored at the touch point **+64 dp upward in screen space** so the building is never under the thumb (a 2 dp leader line connects touch to footprint). **Placement is never committed on finger-up** — the player must tap `✔ PLACE` (bottom-right, 64 dp, frequent zone), because misplacement in a city builder is expensive. Validity tint, re-evaluated at 10 Hz while dragging:

  | Verdict | Tint | Footprint decal | Bar state |
  |---|---|---|---|
  | `VALID` | `#33C27A` @35 % | solid green outline | `✔ PLACE` enabled |
  | `WARN` (placeable, a soft requirement unmet) | `#F2B13C` @35 % | dashed amber | `✔ PLACE` enabled + `⚠ n issues` |
  | `BLOCKED` (hard: occupied / off-grid / not owned / no road) | `#E5533D` @35 % | red hatched 45° | `✔ PLACE` disabled, haptic `error` |

Rotation: `↻` steps 90°, and a two-finger twist in placement mode rotates the **ghost**, not the camera. Roads / power lines / water mains use **drag-path** placement: press a start tile, drag, and an L-shaped (Manhattan, longest-leg-first) preview follows with live cost and segment count in the bar; `✔` commits the whole path as one command. Report 98 C-41 ruled this the primary interaction (undergrounding and wind exposure are only real decisions if the player chooses the route) and added one assist: a `Route along roads` button in the `PlacementBar` fills the path automatically between the two endpoints, after which the player still presses `✔` — the confirm step is never skipped.

**Requirement failure messaging (spec §9.4).** One formatter, `RequirementFormatter`, used identically by placement, by the building panel's upgrade block, and by the land-development panel.

Template: `"{subject} insufficient: {have} {unit} available / {need} {unit} required{at_clause}. {remedy}"`

Worked examples:

| Requirement | Rendered string |
|---|---|
| power capacity | `Electrical capacity insufficient: 1.8 MW available / 2.4 MW required at Substation A. Upgrade Substation A, or add a second feeder.` |
| water pressure | `Water pressure insufficient: 38 psi at this block / 55 psi required. Add a pumping station or a storage tank in Harbour District.` |
| road access | `No road access: nearest road is 3 tiles away. Build a road to this parcel.` |
| **avenue gate (L4/L5)** | `Avenue access insufficient: nearest avenue 7 tiles from the access tile / 4 tiles required for Level 4. Upgrade this block's boundary road to an AVENUE, or build one within 4 tiles.` |
| construction crews | `No construction crew free: 2 / 2 crews busy. Next crew free in 4:12, or build a Construction Yard.` |
| fire coverage | `Fire coverage missing: nearest station 780 m (max 500 m for Level 3+). Build a fire station in this district.` |
| city level | `City level too low: Level 3 required, you are Level 2. Reach 25,000 population.` |
| treasury | `Insufficient funds: $8.4K available / $12.4K required.` |

The avenue row is the **13th** failure code (report 98 C-62): doc 02's upgrade precondition check #13 `E_AVENUE` — a hard gate, not a soft modifier — fires whenever a building would pass Level 3 without an `AVENUE` within 4 tiles of its access tile (doc 10 owns the class semantics, doc 09's starter blocks all carry boundary avenues, so the gate never fires during onboarding). It is the one requirement whose `fix_target_id` is a *road tile* rather than a building, so `Fix this →` focuses the nearest upgradeable boundary segment and opens the road panel with the STREET→AVENUE action preselected.

Rules: at most **3** failure chips in the bar; `⚠ n issues` expands the full list in a 200 dp popover. Every failure row carries a **`Fix this →`** affordance that closes the sheet, `camera.focus_on()`s the blocking entity and opens its panel — the single most important teaching device in the game, turning an abstract denial into a navigable dependency edge.

### 2.8 Land purchase flow (S4)

1. Build ▸ `Land` tab auto-enables a land overlay: owned blocks unshaded; purchasable blocks (adjacent to owned, spec §7.1) outlined in the selection-ring blue (`palette.selected`, §2.5) with a floating price tag; non-adjacent blocks greyed with a chain glyph and tooltip `Not adjacent to your city`.
2. Tap a block → `LandPanel` (300 dp): header `Block E4 · 16×16 tiles · 128 m`; `Price $84,000 · Development $31,000 · Development time 3h 20m`; **risk profile** as icon + 5-segment bar + word (`Flood ▮▮▮▯▯ Elevated`, `Pollution ▮▯▯▯▯ Low`, `Wildfire ▮▮▯▯▯ Moderate`, each risk type with its own icon); **advantages** (`Waterfront +18% land value`, `Existing road stub`); `Buildable tiles 214 / 256`.
3. `PURCHASE` → `buy_land`. On success the block flips to owned-undeveloped and the primary button becomes `DEVELOP`.
4. `DEVELOP` → `develop_land`. The panel becomes a 6-step progress list (Survey → Clearing → Grading → Roads → Utility corridor → Final, spec §7.3) with per-step bars and the assigned crew; it is closable and the progress reappears in S8's construction section.

### 2.9 Building panel (S5, spec §40.4)

Side panel 300 dp (bottom sheet 200 dp on COMPACT), top to bottom: **(1) Header** name, archetype icon, `L1 L2 ▮L3▮ L4 L5` level pips, condition ring. **(2) Vitals** 2×3 grid — `Occupants 340`, `Jobs 0`, `Tax +$1,240/d`, `Power 210 kW`, `Water 6.2 m³/h`, `Condition 87%`. **(3) Risk** `Fire risk ▮▮▮▯▯ Elevated` (🔥), `Crime risk ▮▮▯▯▯ Moderate` (🛡) — icon + bar + word, never colour alone. **(4) Service coverage** four 40 dp tiles (Power/Water/Police/Fire) with the §2.5 state glyph + ring colour and a one-line reason on tap (`Fed by Substation A · feeder 78 % loaded`). **(5) Upgrade block** `Upgrade to Level 4` · cost · time · the **requirement checklist** (each line `✓`/`✗` + the §2.7 formatter string); `UPGRADE` is disabled while any `✗` remains and its subtitle names the first blocker. **(6) Actions** `Repair` (condition < 90 %), `Priority` (shed tier, doc 04), `Demolish` (hold-to-confirm 800 ms, `DangerButton`).

### 2.10 City dashboard (S8, spec §40.3)

Full-screen modal, four tabs. **Overview** reproduces the spec §40.3 block verbatim in layout — each row a 48 dp band with label, value, state glyph, and a 64 × 24 dp sparkline of the last 24 game-hours (hourly samples from the sim ring buffer); tapping a row deep-links (Grid → power overlay + close; Active incidents → drawer). **Economy**: revenue/expense breakdown (per-day), 7-day treasury chart, tax-rate control (doc 03 exposes `set_tax_rate`). **Infrastructure**: power gen/cap/load + worst 5 feeders, water supply/demand + worst 5 zones, condition histogram. **Response**: per-department unit roster with status, rolling-24 h average response time, incident throughput, and the **auto-response policy editor** (spec §21.3, §2.13). Gear icon top-right → S9.

### 2.11 Pause & speed controls (spec §49)

Doc 01 locks `speed ∈ {1, 2, 3}` with `paused` as a **separate bool**, so the control is a 56 dp left-rail button expanding upward into four targets: `⏸` (toggles `paused`) and `▶ 1×`, `▶▶ 2×`, `▶▶▶ 3×`. The multiplier applies to the constitution's 1 real s = 1 game min mapping; 3× = 3 game-minutes per real second. The button face shows `⏸` while paused, otherwise the current multiplier.

Pause freezes the sim clock only — camera, overlays, panels and build preview stay live, and state-mutating commands are **allowed** while paused, taking effect on the next tick (planning while paused gains nothing because the clock is stopped). Placement mode, dashboard and drawer never auto-pause. Doc 01's `auto_speed_reset_on_critical` (default on) **resets speed to 1× and never force-pauses** — pausing the player mid-crisis is worse than the crisis — so the UI raises the alert banner and drops to 1× without touching `paused`. A save that was paused resumes unpaused at its stored speed.

### 2.12 WHILE YOU WERE AWAY (S11, spec §21.2)

**Trigger:** shown on resume when `real_elapsed_seconds ≥ 120` (= 2 game-hours) **or** any P1/P2 event occurred offline. Below the threshold with no notable events, a toast (`Away 4m · +$3.1K`) replaces it.

Layout, top to bottom: **(1) Header** `WHILE YOU WERE AWAY` + `6h 14m of city time` + the day/night band of the away period. **(2) Needs you now** — only if non-empty, rendered first in CRITICAL styling, up to 3 unresolved incidents as §2.6 rows, each with a **`HANDLE NOW`** button that dismisses the report, jumps the camera, opens the drawer and preselects the incident; this is the primary CTA. **(3) Ledger** `Taxes +$412K · Expenses −$274K · Net +$138K · Treasury $8.42M`. **(4) City change** `Population 182,904 → 184,291 (+1,387)`, `Buildings completed 3`, `Land developed 1 block`, `Stability 71 → 68`. **(5) Timeline** — horizontal strip spanning the away period, each event a tick coloured + digit-badged by peak tier over day/night shading; max 8 labelled entries chosen by `(-peak_tier, -duration_h)`, `See all (23) →` opens S13. **(6) Auto-response log** — what the player's policies did (`Auto-dispatched Engine 1 to structure fire (resolved 12m)`, `Auto-repair skipped: cost $48K over your $25K threshold`), which is what makes the offline sim feel authored rather than arbitrary (Risk 5 mitigation). **(7) Footer** `DISMISS` and `EDIT AUTO-RESPONSE`. The report is always dismissible in one tap and never blocks a critical action.

### 2.13 Settings (S9) & notification settings (S10)

**S9 pages:** Gameplay · Notifications · Accessibility · Graphics · Audio · Data & Saves · About.

- *Gameplay:* difficulty (Casual/Standard/Hard, spec §35 — changing mid-city warns and is one-way downward), `auto_speed_reset_on_critical`, camera rotation mode (`free / snap45 / snap90 / locked`, default `snap45`), invert pan (off), follow dispatched unit (on), confirm before demolish (on).
- *Auto-response policies* (spec §21.3) live on the Response dashboard tab and are mirrored here: auto-dispatch nearest fire unit (on), auto-dispatch police for tier ≥ T3 (on), utility restoration priority list (drag-reorder: Hospital → Water → Fire station → Residential → Commercial → Industrial), reserve N fire engines (default 1), auto-repair cost ceiling (default $25,000, slider $0–$250K), never spend emergency contractor funds (on).

**S10 notification settings** (spec §22, §49 "clear notification controls"): master push toggle (on); per-priority toggles over doc 08's four classes — **P1 Critical** on with sound+vibrate, **P2 Important** on and silent, **P3 Routine** **off** by default, **P4** present but disabled and greyed with the reason `Not in this build`; doc 08's per-event-type list (18 types, grouped by system, each showing its class); quiet hours; digest mode; and one control this doc actually owns — **in-app banners** (on, independent of push).

**Ownership split (report 98 C-71) — three layers, one owner each.**

| Layer | Owner | File | Contents |
|---|---|---|---|
| Push **policy** | **doc 08** | `data/notifications.json` | the four classes P1–P4 (P4 ships disabled), event→class mapping (18 events), push budgets, quiet hours, coalescing |
| Push **platform** | **doc 13** | `data/android.json` | Android channels (mapped to P1/P2/P3), `AlarmManager`, permission flow, scheduling mechanics; consumes doc 08's plan |
| **In-app** banner/toast gate | **this doc** | `data/ui.json` → `in_app_alerts` | the foreground surface only |

This doc no longer owns `data/notifications.json` in any form — its former block (priority classes, `event_priority`, `quiet_hours_default`, `default_enabled`) is **deleted**; read those from doc 08. S10 is a *view* that writes doc 08's and doc 13's values and must not re-implement them; where they disagree, doc 08 wins on policy and doc 13 on platform.

**In-app gate** (`InAppAlertGate`, pure, headless-tested — foreground banners and toasts only, **never push**): token bucket per class, `capacity = refill_per_real_hour = {P1: 6, P2: 3, P3: 1}`, a shared `global_max_per_hour = 3` over P2+P3 combined (P1 is exempt because it is `never_drop`), plus a 600 s per-event-type cooldown. A class with an empty bucket degrades to a toast — **except** P1, which always shows a banner but coalesces: a P1 within 300 s of the previous one replaces it in place with an updated title (`2 critical incidents in Harbour District`). Quiet hours are **not** consulted here: an in-app banner only exists while the player is looking at the app.

**These rates are ~3× doc 08's push budgets, and that is correct (report 98 C-72).** Doc 08 allows P2 three times per *six* hours with a global 8/day; this gate allows P2 three times per *hour*. A push spends attention the player did not offer and is budgeted for a whole day; an in-app banner costs a glance the player is already giving. The two must never be merged, averaged or cross-checked, which is exactly why the constants sit under the key `in_app_alerts` and the class is named `InAppAlertGate` — any code path that reads an in-app number to decide a push (or the reverse) is a bug, asserted by test 17.

### 2.14 Haptics (spec §49, optional)

Setting `haptics = off / light / full` (default `light`); Godot `Input.vibrate_handheld(ms)`. Durations in ms as `light / full`: button press `0 / 8`, placement snapped to a new tile `0 / 5`, placement verdict → BLOCKED `20 / 30`, dispatch confirmed `12 / 20`, incident escalated or new S4+ `40 / 40` (pattern 20‑60‑20), power restored `30 / 60`, rotation snap `0 / 8`.

### 2.15 Alerts, toasts & world markers

**Alert banner**: 400 × 44 dp under the top bar, max 2 stacked, 6 s auto-dismiss (P1 sticky until tapped); severity badge + one line + optional `VIEW` (jump + select). **Toast**: 320 × 40 dp bottom-centre, 2.5 s, max 1 (newest replaces), optional UNDO. **World markers** (`MarkerLayer`, a `Control` under the HUD): incident pins are pooled `Control`s positioned each frame from `Camera3D.unproject_position(pos)` — 48 dp tap target, 32 dp visual (tier colour + tier digit + glyph) with a 2 dp stem to the ground point. `MarkerLayer` also draws the **selection ring** (§2.5, C-64) — one ring at most, around whatever is currently selected — for the same reason: selection is a view concern, so it is projected UI geometry, never a per-instance building `overlay_state`. Off-screen incidents clamp to the rect `(12, 60, W−12−drawer_w, H−70)` and render as a 32 dp arrow with the tier digit and a distance label. Two pins within 40 dp cluster into a badge showing count + worst tier digit; tapping it zooms one step and de-clusters.

### 2.16 Touch camera controls

**Rig.** `CameraRig (Node3D)` at `focus` on the ground plane `y=0` → `Yaw` → `Pitch` → `Camera3D` at local `(0, 0, dist)`. State is exactly `focus: Vector3 (y=0)`, `zoom_t ∈ [0,1]`, `yaw: float (rad)`; everything else is derived.

**Split of ownership with doc 11 (report 98 C-63) — reference, never restate.** This doc owns the **interaction range**: `D_MIN = 18 m`, `D_MAX = 420 m`, `pitch 34° → 62°`, and the curves below; they were derived against thumb reach, the city diagonal and the "one intersection fills the screen" read, and they stand. Doc 11 owns the **projection constants** — vertical FOV, near and far planes — because its draw-call and culling budgets are computed against them. All six live in **one file, `data/render.json`** (doc 11's). `data/ui.json.camera` carries the interaction range and **references** the projection constants by name; it must never carry its own `fov_deg`, `near_m` or `far_m` — the earlier copies (45° / 1 m / 2000 m) are deleted, not overridden. Any figure below that depends on the projection is derived at read time from `data/render.json` (`fov_deg 40`, `near_m 1`, `far_m 1600` at the time of writing) and is annotated as such. LOD-tier consequences at `D_MAX` are doc 11's to re-derive (report R-17); this doc makes no tier claims.

**Zoom curve (geometric — constant perceived zoom rate):**

```
dist(t)  = D_MIN * pow(D_MAX / D_MIN, t)        D_MIN = 18 m, D_MAX = 420 m
t(dist)  = log(dist / D_MIN) / log(D_MAX / D_MIN)
pitch(t) = 34° + 28° * smoothstep(0, 1, t)      # 34° up close, 62° top-down far
```

**Worked examples — regenerated against doc 11's projection (C-63).** Ground coverage is derived, not authored: with vertical FOV `f = 40°` and the reference aspect `880/400 = 2.2`, the half-angles are `v = 20°` and `h = atan(2.2·tan20°) = atan(0.8007) = 38.69°`. For a camera at distance `D` and pitch `p`, height `y = D·sin p`; the far and near screen edges hit the ground at `y/tan(p−20°)` and `y/tan(p+20°)` from the nadir, and the width through the focus point is `2·D·tan(38.69°) = 1.6015·D`. Land block = 128 m, tile = 8 m (constitution §6).

| `t` | `dist(t)` | `pitch(t)` | Camera height `y` | Ground depth (far − near) | Ground width at focus | Reads as |
|---|---|---|---|---|---|---|
| 0.00 | 18.0 m | 34.00° | 18·sin34 = 10.1 m | 10.1/tan14 − 10.1/tan54 = 40.4 − 7.3 = **33.1 m** | 1.6015·18 = **28.8 m** | 3.6 × 4.1 tiles — one intersection and its corner lots |
| 0.42 | 18·23.333^0.42 = **67.6 m** | 34+28·smoothstep(0.42) = 34+28·0.3810 = **44.67°** | 47.5 m | 103.4 − 22.6 = **80.8 m** | **108.3 m** | 0.85 × 0.63 land blocks — default new-city framing |
| 0.50 | 18·√23.333 = 86.9 m | 48.00° | 64.6 m | 121.5 − 26.1 = **95.4 m** | **139.2 m** | ≈ one land block |
| 1.00 | 420.0 m | 62.00° | 370.8 m | 411.8 − 52.1 = **359.7 m** | **672.6 m** | 5.3 × 2.8 land blocks |

Two corrections fall out of this pass. The old text put the default zoom at "dist 71 m"; the curve gives `18 · (420/18)^0.42 = 18 · e^(0.42·ln 23.3333) = 18 · e^1.3230 = 18 · 3.755 = 67.6 m` — 67.6 m is normative and 71 m was never on the curve. And max zoom shows **≈5×3 land blocks (673 × 360 m)**, not the "≈5×5" previously claimed: at 62° pitch the frame is far wider than it is deep, so the city reads as a band, not a square.

**Effective zoom-out limit** so a small city never floats in an empty void:
`D_MAX_eff = clamp(city_diagonal_m * 1.6, 120, 420)`, recomputed when owned land changes.

**Pan — exact 1:1 world lock.** On finger-down, ray-cast the touch to `y=0` and store `anchor`; every frame `focus += (anchor − ray_to_ground(touch_pos))`, so the anchor stays glued under the finger. Guard: if the ray is near-parallel to the ground (`|ray.y| < 0.08`), clamp the intersection distance to `dist * 4`.

**Momentum.** While dragging keep `v = 0.6*v + 0.4*(Δfocus/Δt)` (m/s, ground plane). On release, if `|v| ≥ 3.0 m/s`, clamp `|v| ≤ 220 m/s` and integrate `focus += v*dt; v *= exp(−K*dt)` with `K = 6.0 s⁻¹`, stopping below 0.5 m/s. Half-life `ln2/6 = 0.116 s`; a 60 m/s fling coasts `60/6 = 10 m`. Any new touch cancels momentum immediately.

**Bounds & rubber band.** `focus` clamps to the owned-land AABB expanded by 2 land blocks (256 m). Over-bound displacement is multiplied by `0.35` while dragging; on release a critically damped spring `a = −ω²(x − x_clamped) − 2ωv`, `ω = 12 rad/s`, returns it in ≈ 0.35 s.

**Pinch zoom.** Engages when `|span − span_at_touch_down| > 24 dp`; per frame `dist = clamp(dist * (span_prev/span_now), D_MIN, D_MAX_eff)`. Then re-anchor: translate `focus` (same math as pan) so the ground point under the pinch centroid at engage time returns to the centroid's current screen position — pinch feels like grabbing the map.

**Two-finger twist rotate.** Engages when `|angle(f1→f2)_now − angle_at_engage| > 8°`, then `yaw += Δangle` per frame (1:1 with the fingers). Pinch, twist and centroid-pan run **concurrently** once each independently crosses its threshold (full RST manipulation). On release with `rotation_mode = snap45`, tween `yaw` to the nearest 45° over 0.25 s `ease_out_back(0.8)` + snap haptic; `snap90` uses 90°, `free` leaves it, `locked` disables twist and shows a `Rotation locked` toast on first attempt.

**Tap-select vs drag disambiguation** (`GestureRecognizer`, pure state machine; all thresholds in dp/ms):

| Constant | Value |
|---|---|
| `TAP_SLOP` | 8 dp |
| `TAP_MAX_MS` | 220 ms |
| `LONGPRESS_MS` | 450 ms |
| `LONGPRESS_SLOP` | 10 dp |
| `DOUBLE_TAP_MS` | 260 ms |
| `DOUBLE_TAP_SLOP` | 24 dp |
| `DRAG_START_SLOP` | 8 dp |
| `PINCH_SPAN_SLOP` | 24 dp |
| `TWIST_DEADZONE` | 8° |
| `MULTI_SUPPRESS_MS` | 80 ms |

```
IDLE
 └─(down f0)→ PENDING
      ├─ up  ≤220ms & travel ≤8dp  → TAP        (→ pick & select)
      │     └─ if a TAP occurred ≤260ms ago and ≤24dp away → DOUBLE_TAP
      ├─ held ≥450ms & travel ≤10dp → LONG_PRESS (→ quick-action menu)
      ├─ travel >8dp                → PAN
      └─ (down f1 within 80ms)      → MULTI (suppresses the pending tap)
PAN ──(down f1)→ MULTI ; ──(up)→ MOMENTUM → IDLE
MULTI: pan(centroid) always; + ZOOM after 24dp span change; + ROTATE after 8° twist
       ──(one finger up)→ PAN (re-anchor to remaining finger, no jump)
       ──(all up)→ MOMENTUM → IDLE
```

`DOUBLE_TAP` → `zoom_t −= 0.18` (clamped ≥ 0) anchored at the tap point, tween 0.28 s; two-finger tap → `zoom_t += 0.18`. `TAP` picking order: UI `Control`s consume first via normal Godot propagation (the camera only listens in `_unhandled_input`), then world marker pins, then a 3D physics ray on layer `pickable` (buildings, roads, utility nodes, land blocks) — nearest hit wins, ties break to the smaller footprint. `LONG_PRESS` on a building opens radial quick actions (Upgrade / Repair / Priority / Demolish, 56 dp each); on empty ground it offers `Place here` into the last-used build category.

**Camera jumps.** `focus_on(pos, dist_target, opts)`:
```
d = |pos - focus|
if d <= 400 m or reduce_motion:  single tween 0.45 s, ease_out_cubic (0.0 s if reduce_motion → hard cut + 0.12 s crossfade)
else: arc — zoom_t rises to min(1, max(t_now, t_target) + 0.25) at midpoint, 0.75 s total, ease_in_out_cubic
```
Drawer-aware: when the drawer is open, the target screen point is `(W−drawer_w)/2` rather than `W/2`, implemented by offsetting `focus` along the camera's screen-right vector by `drawer_w/2 * m_per_dp(dist)`.

**Follow mode.** `focus = lerp(focus, unit.pos, 1 - exp(-8*dt))`. Cancelled by any `PAN`, by tapping the follow chip, or when the unit goes off-duty.

### 2.17 Onboarding — exact sequence (spec §41 steps 1–11)

**Framework.** `OnboardingDirector` (pure, `ui/logic/`) is a step machine driven by sim + UI events; `CoachLayer` renders it. Every step is data in `data/onboarding.json` with fields `id, trigger, coach_text (≤90 chars), target (ui node path | world entity selector), gate (soft|hard), completion, hint_after_s, autohelp_after_s, sim_overrides`.

**Coach mark rendering.** Full-screen dim `#000000 @ 0.55` with a rounded-rect cutout (8 dp pad, 12 dp radius) around the target, animated 0.2 s; bubble ≤ 240 dp wide with 14 dp body text, an arrow at the cutout, and `Skip tutorial` (text, left) plus `Got it` on informational steps. A `hard` gate swallows touches outside the cutout with a 6 dp shake; a `soft` gate passes everything through and re-anchors when the player returns. After `hint_after_s = 25` an animated arrow + 1.2 Hz pulse is added; after `autohelp_after_s = 60` a `Show me` button performs the camera move and opens the required menu — never the final commit, the player always presses the last button.

**Global tutorial guarantees:** the Disaster Director is **suppressed** for the whole tutorial and 300 real seconds after (`director.suppress_until`), RNG incident spawning is off, and the scripted incident is the only one that exists; construction times are overridden per step. Skipping (bubble Skip, or Settings ▸ Gameplay) marks all steps complete, grants nothing, and lifts suppression after 300 s.

| # | Step id | Trigger | Coach text | Gate | Completion condition | Overrides |
|---|---|---|---|---|---|---|
| 0 | `intro_flyover` | new save created | *(no bubble)* 6 s night flyover of the starter city; title card `You built it. Now keep it alive.`; `SKIP` top-right | soft | flyover ends or skipped | camera scripted path |
| 1 | `city_given` | step 0 done | `This is your city. It runs whether you watch it or not.` | soft | `Got it` tapped, or 6 s | speed forced 1× |
| 2 | `build_house` | step 1 done | `Tap BUILD and place a house on the marked lot.` | hard on Build FAB → Residential tab → House card; soft during placement | `place_building{type:"house"}` accepted on a tile inside `tutorial_lot_A` | only `tutorial_lot_A` tiles are VALID; build time → 20 real s; cost waived to $0 |
| 3 | `confirm_power` | house construction completes | `The house has no feeder. Open the POWER overlay and run a line from Substation A.` | hard on Overlay button → POWER chip; soft on placement | house `power_state == POWERED` | line cost $500; only the corridor tiles VALID |
| 4 | `confirm_water` | step 3 done | `Same for water. Connect the main from the tank.` | hard on Build ▸ Utility ▸ Water main | house `water_state == SUPPLIED` | main cost $500 |
| 5 | `review_ledger` | step 4 done **and** next economy tick (game-hour boundary) | `Your city just earned money. Tap TREASURY to see where it comes from.` | hard on Treasury chip → Dashboard ▸ Economy | Dashboard Economy tab opened for ≥ 2 s | — |
| 6 | `service_building` | step 5 (`review_ledger`) done | `Place a Fire Station. Coverage is not optional.` | hard on Build ▸ Civic ▸ Fire Station | `place_building{type:"fire_station"}` accepted in `tutorial_lot_B` | build time → 25 real s; cost waived |
| 7 | `first_incident` | fire station operational **+ 8 real s** | *(no bubble; alert banner + auto-open drawer)* `Transformer T-04 has failed. Three blocks are dark.` | soft | drawer open with the incident row visible | scripted incident, see below |
| 8 | `dispatch` | step 7 shown | `Tap the incident, then ASSIGN the crew with the shortest ETA.` | hard on row → ASSIGN → unit row | `dispatch_unit` accepted for the scripted incident | only `Utility 1` eligible; ETA 0:48 |
| 9 | `repair` | unit arrives on scene | *(no bubble)* progress ring on the incident; on resolve, the district **relights** — bloom + audio sting + camera holds 2 s | soft | incident `status == RESOLVED` | repair duration 30 real s |
| 9b | `cascade_card` | step 9 done | *(card)* `WHY IT HAPPENED` — a 5-node chain: `Transformer T-04 failed → 6 buildings lost power → street lights off → pump P-2 lost pressure → Harbour stability −6` | soft | `Got it` | — |
| 10 | `upgrade` | step 9b done | `Bigger buildings earn more — and demand more. Upgrade your house.` | hard on the tutorial house → Upgrade | `upgrade_building` accepted | headroom tuned so the upgrade **passes** but the panel shows post-upgrade feeder load 92 % with a WARNING glyph |
| 11 | `buy_land` | step 10 upgrade completes, **or** 60 real s after it starts | `Room to grow. Buy the block to the east.` | hard on Build ▸ Land ▸ block `E4` | `buy_land{block:"E4"}` accepted | price reduced to $1 for the tutorial block |
| — | `outro` | step 11 done | card: `You built it. Now keep it alive.` + a checkpoint save tagged `onboarding_complete` | soft | `Got it` | director suppressed 300 more s |

**Step 5 is a reading step, not a collecting step (report 98 C-59).** Revenue **auto-accrues**; there is no tap-to-collect affordance anywhere in the game, and `economy.manual_collection` no longer exists in doc 03 or in this doc — the branch, the `collect_revenue` command, the conditional coach target and the flag itself are **deleted**, not disabled. The spec §41.5 wording ("collect taxes") is a ruled and approved deviation: tap-to-collect is a chore mechanic from the exact genre spec §2.2 rejects, and a city that only earns while you watch it contradicts the premise that it runs whether you watch it or not. The step therefore teaches where money *comes from* — the Economy tab's revenue/expense breakdown — which is the knowledge the player actually needs at step 10 when an upgrade raises both. The step id is `review_ledger`; the former id `taxes` is retired.

**Controlled first incident script** (`TUT_TRANSFORMER_FAIL`, injected via `IncidentSystem.spawn_scripted()` — never from the `incidents` RNG stream):

```
type              : transformer_failure
severity          : 3
position          : transformer T-04 (starter city, Harbour block B2 — doc 09)
required_units    : [ utility_truck × 1 ]
optional_units    : [ ]
esc_rate override : tuned so tier 3 → tier 4 takes 180 real s unattended
                    (Casual: esc_rate forced to 0 — the incident never escalates)
on_escalate       : spawn structure_fire (severity 2) at the nearest residential building
immediate effects : 6 buildings → UNPOWERED
                    street lighting in B2 → off   (the signature blackout visual)
                    water pump P-2 → offline → Harbour pressure 100% → 60%
                    Harbour district stability −1.0 / real minute while unresolved
notification      : P1 (banner + push if backgrounded)
resolution reward : none (tutorial); repair cost waived
```

This script is the thesis statement of the game in 90 seconds: one component fails, four other systems degrade, the player dispatches a finite crew, and the lights come back on.

### 2.18 Accessibility checklist (spec §49) — every row is a release gate

| # | Requirement | Pass criterion | Verified by |
|---|---|---|---|
| A1 | Readable text | Body ≥ 14 dp, labels ≥ 12 dp, no text below 12 dp anywhere | lint test over the Theme |
| A2 | Text scale | 85 / 100 / 115 / 130 / 150 %; layout survives 150 % at 640×340 dp with no clipping or overlap | layout snapshot tests at 5 scales × 3 widths |
| A3 | Touch targets | **min 48 × 48 dp** for every interactive `Control`; `larger_touch_targets` setting raises to 56 dp | automated tree walk asserting `size.x ≥ 48 and size.y ≥ 48` on anything with a `pressed` signal |
| A4 | Target spacing | ≥ 8 dp between adjacent independent targets | same tree walk |
| A5 | Colour + icon redundancy | every state/severity carries a distinct glyph **and** (for lines) a distinct dash pattern; severity markers carry a numeric digit | palette unit test asserts glyph uniqueness + pairwise luminance Δ ≥ 0.10 |
| A6 | Colourblind palettes | `default / deuteran / protan / tritan` swap hex only | manual + simulated-vision screenshots |
| A7 | Contrast | text vs its background ≥ 4.5:1; large text and non-text state indicators ≥ 3:1 | contrast unit test over Theme colour pairs |
| A8 | Reduce motion | disables camera arcs, pulse animations, parallax, screen shake; keeps state colour/glyph | setting honoured by `Anim.play()` wrapper |
| A9 | Haptics | fully optional, 3 levels, default light | setting |
| A10 | Pause / slow | pause + **1× / 2× / 3×** always reachable in ≤ 2 taps (report 98 C-65 — doc 01 locks `speed ∈ {1,2,3}`; the "4×" in the earlier draft was an internal contradiction with §2.11, not a second requirement). No sub-1× slow motion ships in MVP; spec §49 is met by explicit pause with 1× as the floor | UI test: one tap raises the speed rail, the second selects any of the four targets |
| A11 | One-tap emergency | jump-to-worst button always present when incidents > 0 | UI test |
| A12 | Notification control | per-priority + per-type toggles, quiet hours, rate cap | S10 |
| A13 | Graphics/battery | Performance / Balanced / High + `battery_saver` (30 FPS cap, weather VFX off, night lights simplified) | settings |
| A14 | No colour-only errors | every blocked action states its reason in words (§2.7 formatter) | copy review |
| A15 | Screen reader labels | every interactive Control sets `tooltip_text` used as the accessibility name | tree walk asserts non-empty |

### 2.19 S14 — the goals sheet (Wave 9)

Doc 09 §2.14 gives every city level an objective list. This is where the player
reads it, and after the HUD it is the screen they open most.

**Entry.** §2.4's goal chip, and nothing else. It is a full-screen modal on
`ModalLayer` with the S9 contract: the scrim is the only `STOP` control while it
is up, Android BACK closes it first (§2.2), and opening it closes its siblings.

**Layout**, top to bottom, all built in code from `GoalsModel`'s plain data:

```
 ┌──────────────────────────────────────────┐
 │ Goals                                  ✕ │   header
 ├──────────────────────────────────────────┤
 │  L3   The budget                         │   badge (display type) + name
 │  Every building you own costs money…     │   one sentence of intent
 │  Teaches: apartments, the tax slider…    │   one sentence of scope, muted
 │  ▓▓▓▓▓▓░░░░░░            2 of 4 done     │   the level bar
 ├──────────────────────────────────────────┤
 │  ✓  Build an apartment block             │
 │  ○  Set the tax rate                 0/1 │   mark · sentence · bar · counter
 │  ○  Get happiness to 70        ▓▓▓░ 66/70│
 │  Or grow to 1,600 residents — the level  │   the §2.11 backstop, greyed
 │  arrives either way.                     │
 ├──────────────────────────────────────────┤
 │  REACHING LEVEL 4 UNLOCKS                │   the payoff, in its own card
 │   · High-rise · Upgrades to level 4      │
 │   · 6 more blocks to buy                 │
 │  Then: When it goes wrong                │   the next level, named
 │  ✓0  ✓1  ✓2  ○3  ○4  ○5                  │   the arc, as a strip
 └──────────────────────────────────────────┘
```

Six decisions worth recording:

1. **The counter is a fraction, right-aligned**, so the eye runs down a column
   of numbers rather than hunting for each one at the end of its line. A
   finished row shows a tick and **no** counter — `1/1` is noise.
2. **The mark is a glyph, not a colour** (A5): `✓` / `○`, with the palette's
   state colour as the redundant channel.
3. **The reward card is READ, never authored.** "Level 3 unlocks High-rises" is
   `min_city_level` on doc 02's build card, the building level doc 02's upgrade
   ladder opens at that rung, and the count of doc 09 blocks gated on it. A
   retune of any of the three moves this card with it and cannot leave it lying.
   `data/ui.json.goals.max_reward_rows` caps it so a rich rung cannot push the
   objectives off a 360 dp display.

   **Wave 10 is the proof that it reads.** Doc 02 §2.14 added a sixth building
   rung and doc 09 §2.11 a seventh city level; **not one line of this sheet's
   copy was touched**, and the cards moved anyway:

   | city level | reward card, before Wave 10 | reward card, after |
   |---|---|---|
   | 3 | High-Rise · Upgrades to level 4 | *unchanged* |
   | 4 | Data Center · Upgrades to level 5 | *unchanged rows*, but the rung now also opens `house` and `store` L6 |
   | **5** | **empty — "Nothing new to build"** | **Upgrades to level 6** |
   | **6** | *did not exist* | **"Nothing new to build. The city is yours to run."** |

   The last row is not a regression and it is not the hole level 5 had. Rung 6
   is the TOP of doc 09 §2.11's ladder, so there is nothing above it to unlock,
   and `ui_goals_reward_none` is the graduation sentence this sheet has always
   used for exactly that state — the same copy decision 6 makes on the finished
   card. What made level 5's empty card a defect was that it sat in the MIDDLE
   of a ladder that went on without it. (There is no land line on it either;
   doc 09 §2.8.3 is the arithmetic that says why there is no ring 3 to gate.)

   The one code change the sheet needed was a bound: `unlocked_upgrade_level`
   scanned rungs `2..5` with a literal, and now scans to each archetype's OWN
   top rung, which is 5 or 6 (doc 02 §2.14). A literal there would have made the
   tower tier invisible on the very card that announces it.
4. **The backstop is shown, greyed.** §2.11's population rung is the other route
   up (doc 09 §2.14.1), and hiding it would make the sheet look like a gate when
   it is a shortcut.
5. **The strip starts at level 0** — doc 12 §2.17's tutorial. A strip that starts
   at 1 reads as though the player has not begun.
6. **The finished state is a payoff card, not an empty list**: badge, a sentence
   naming what they ran, and the strip full of ticks. The chip is gone from the
   bar by then.

**Moments.** `goal_completed` pulses the row that landed for
`layout.unlock_pulse_s`, once, and A8 suppresses the motion entirely under
`reduce_motion` — the tick and the toast still say what happened.
`city_level_objectives_met` raises §2.15's toast (`ui_toast_goal_level`) and
§2.14's `power_restored` haptic cue.

**The handoff.** §2.17's tutorial gains a twelfth step, `next_goals`: a soft
coach mark on the goal chip, satisfied by opening this sheet **or** by
acknowledging the card. The tutorial used to end at `payoff` and leave the player
in a running city with nothing to aim at.

---

## 3. Data Schema

### 3.1 `data/` files owned by this doc

- `data/ui.json` — layout, breakpoints, palette, selection ring, gesture constants, camera **interaction** constants, formatting rules, and the `in_app_alerts` gate.
- `data/onboarding.json` — the step table of §2.17 plus the scripted incident.
- `data/strings.en.json` — **every display string in the game** (report 98 G-8).

Two files this doc used to claim and no longer does: `data/notifications.json` is **doc 08's** (push classes, event→class mapping, budgets, quiet hours — C-71) and the camera's projection constants live in **doc 11's** `data/render.json` (C-63). Neither is duplicated here.

**`data/strings.en.json` (G-8).** One flat string table, **English only in MVP** — no plural rules, no gender, no RTL, no runtime locale switch; the file exists so that no display copy is ever compiled into a `.tscn` or a `.gd`, which is the precondition for localisation later, not localisation itself. Two key families, both mandatory:

| Key form | Used by | Example |
|---|---|---|
| `ui_<screen>_<element>` | every `Control` label, button, tab, empty state, tooltip and formatter template | `ui_build_tab_utility`, `ui_placement_confirm`, `ui_requirement_e_avenue`, `ui_away_header` |
| `n_<event>_title` / `n_<event>_body` | notification and alert-banner copy, keyed by doc 08's event id — its convention, adopted verbatim so a push and its in-app banner can never drift | `n_outage_major_title`, `n_outage_major_body` |

`<screen>` is the §2.2 surface in lower snake case (`hud`, `build`, `placement`, `land`, `building`, `drawer`, `picker`, `dashboard`, `settings`, `away`, `coach`, `requirement`, `toast`). Values may contain `{named}` placeholders only — never positional `%s` — and `RequirementFormatter` (§2.7) resolves its 13 templates from `ui_requirement_<code_lowercase>`, so the sim's failure code is the only thing crossing the layer boundary and copy edits need no code change. Lookup is `Str.t(key, args := {})`; a missing key returns the key itself in a debug build and is a **test failure** (test 21), never a silent blank. This table also carries the notification copy that doc 13's platform layer renders; doc 13 reads the `n_*` keys rather than authoring its own file, so there is exactly one place a title is written.

```json
{
  "ui_hud_build_fab": "BUILD",
  "ui_build_tab_utility": "Utility",
  "ui_build_card_water_facility_tank": "Storage Tank",
  "ui_placement_confirm": "PLACE",
  "ui_requirement_e_avenue": "Avenue access insufficient: nearest avenue {have} tiles from the access tile / {need} tiles required for Level {level}. Upgrade this block's boundary road to an AVENUE, or build one within {need} tiles.",
  "ui_requirement_funds": "Insufficient funds: {have} available / {need} required.",
  "ui_drawer_held": "HELD",
  "ui_away_header": "WHILE YOU WERE AWAY",
  "n_outage_major_title": "{count} blocks are dark",
  "n_outage_major_body": "{district} lost power at {time}. {units} crews are responding."
}
```

`data/onboarding.json` step shape:

```json
{
  "id": "build_house",
  "trigger": { "kind": "step_done", "step": "city_given" },
  "coach_text": "Tap BUILD and place a house on the marked lot.",
  "target": [
    { "kind": "ui", "path": "HUD/LeftRail/BuildFAB" },
    { "kind": "ui", "path": "SheetLayer/BuildSheet/Tabs/Residential" },
    { "kind": "ui", "path": "SheetLayer/BuildSheet/Cards/house" }
  ],
  "gate": "hard",
  "completion": { "kind": "command_accepted", "command": "place_building",
                  "match": { "type_id": "house", "region": "tutorial_lot_A" } },
  "hint_after_s": 25,
  "autohelp_after_s": 60,
  "sim_overrides": { "build_time_s": 20, "cost_override": 0,
                     "valid_region": "tutorial_lot_A" }
}
```

Trigger kinds: `new_save`, `step_done`, `sim_event` (`{event, filter}`), `delay_after` (`{step, seconds}`), `economy_tick`, `command_accepted`.
Completion kinds: `command_accepted`, `sim_event`, `ui_opened` (`{path, min_seconds}`), `ack`, `timeout`.

### 3.2 Save-file section `ui`

```json
"ui": {
  "section_version": 1,
  "camera": {"focus_x":512.0,"focus_z":384.0,"zoom_t":0.42,"yaw_deg":45.0},
  "overlay": "power", "overlay_legend_collapsed": {"power":false,"water":true},
  "selected_entity_id": "",
  "speed": 1, "drawer_open": false, "incident_sort": "priority",
  "onboarding": {"active":false,"current_step":"","skipped":false,
                 "completed":["intro_flyover","city_given","build_house","confirm_power",
                              "confirm_water","review_ledger","..."],
                 "director_suppress_until_min":1284},
  "seen_tips": ["overlay_first_use","escalation_bar","rotation_locked"],
  "settings": {"text_scale":1.0,"colorblind":"default","reduce_motion":false,
    "larger_touch_targets":false,"haptics":"light","rotation_mode":"snap45","invert_pan":false,
    "follow_dispatched_unit":true,"auto_speed_reset_on_critical":true,"graphics":"balanced","battery_saver":false,
    "in_app_banners": true},
  "in_app_buckets": {"p1":6.0,"p2":3.0,"p3":1.0,"global_p2p3":3.0,"last_fire_min":{}}
}
```

**`section_version`, not `schema_version` (report 98 C-25).** `schema_version` exists exactly once per save, on the envelope (constitution §9); every section — including this one — versions itself with `section_version`, so a section-level migration can never be mistaken for an envelope-level one. One-word change, no behaviour change.

**What left this section (C-71/C-72).** Push preferences — master toggle, per-class P1–P4 toggles, per-event-type toggles, quiet hours, digest — are doc 08's policy and persist in doc 08's `notifications` save section; the S10 screen edits them there. What remains here is the single control this doc owns (`in_app_banners`) plus the in-app token buckets, renamed `notif_buckets` → **`in_app_buckets`** with an explicit `global_p2p3` counter so no reader can mistake them for push budgets. `selected_entity_id` is new and carries the §2.5 selection ring — at most one, because selection is single-valued.

Device-scoped preferences (`text_scale`, `colorblind`, `reduce_motion`, `larger_touch_targets`, `haptics`, `graphics`, `battery_saver`) are also written to `user://settings.cfg` per constitution §2 so they survive city deletion and checkpoint rollback; the copy above is the per-city snapshot, and on load `settings.cfg` wins for those keys.

Migration policy: unknown settings keys are dropped, missing keys take defaults from `data/ui.json` — a settings change must never invalidate a city (constitution §9).

---

## 4. Sim API Sketch

### 4.1 Node architecture (`ui/`)

```
UIRoot (CanvasLayer, layer=10)              # owns SafeArea, back-stack, theme scaling
└── SafeArea (MarginContainer)
    ├── MarkerLayer      (Control, mouse_filter=PASS)   # projected world pins
    ├── HUDLayer         (Control, IGNORE)
    │   ├── TopBar (HBoxContainer)  ├── LeftRail (VBoxContainer)
    │   ├── RightRail (Control)     └── AlertStack (VBoxContainer)
    ├── PanelLayer       (Control, IGNORE)  # BuildingPanel, LandPanel, IncidentDrawer
    ├── SheetLayer       (Control, IGNORE)  # BuildSheet, UnitPickerSheet, PlacementBar
    ├── ModalLayer       (Control, STOP when populated)  # Dashboard, Settings, AwayReport
    └── CoachLayer       (Control, STOP when hard-gated) # onboarding dim + cutout
ToastLayer (CanvasLayer, layer=20)
```

Rule: container `Control`s are `mouse_filter = IGNORE`; only leaf interactive widgets and modal scrims are `STOP`. This guarantees unconsumed touches fall through to `TouchRouter._unhandled_input`, which feeds `GestureRecognizer` → `CameraController`. The camera never inspects UI rects.

### 4.2 Pure logic classes (`ui/logic/`, `RefCounted`, headless-testable)

`GestureRecognizer` · `CameraController` · `TopBarLayoutSolver` · `IncidentSorter` · `UnitPickerSorter` · `RequirementFormatter` · `NumberFormat` · `OnboardingDirector` · `InAppAlertGate` (was `NotificationGate` — renamed per C-71 so the in-app surface can never be read as push) · `MarkerProjector` (clamping/clustering math) · `ThemeScaler` · `Str` (string-table lookup, G-8).

### 4.3 One Theme resource

`ui/theme/slacum_theme.tres` is the **only** `Theme` in the project. Zero per-node style overrides are permitted (enforced by a headless lint test walking `ui/**.tscn` for `theme_override_*` properties).

- Base font 14 dp. Type scale: `Display 28 / Title 20 / Body 14 / Label 12 / Numeric 16 (tabular mono)`.
- Type variations (`theme_type_variation`): `StatChip`, `PrimaryFAB`, `RailButton`, `SeverityBadge`, `SheetPanel`, `SidePanel`, `DrawerRow`, `DangerButton`, `GhostButton`, `TabButton`, `LegendRow`, `CoachBubble`, `ToastPanel`, `AlertBanner`.
- Colour tokens live in the Theme as named colours and are **generated at boot** from `data/ui.json.palette[colorblind_variant]` — the `.tres` ships the default variant.
- Text scale: `ThemeScaler.build(base_theme, scale)` returns a duplicated Theme with all font sizes and all `*_minimum_size`/`margin`/`separation` constants multiplied by `scale` (rounded to whole dp, min 1). Applied to `UIRoot.theme`. Touch minimums are `ceil(48 * max(1.0, scale))` when `larger_touch_targets` is off, `ceil(56 * ...)` when on.

### 4.4 UI event → sim command mapping

All commands go through one funnel: `SimBridge.submit(cmd: Dictionary) -> CommandResult { ok, reason_code, payload }`. The UI **never** predicts success; it renders optimistic UI only after `ok == true`.

| UI event | Command | Payload | Owner doc | Failure surface |
|---|---|---|---|---|
| Placement `✔ PLACE` | `place_building` | `{type_id, variant?, tile_x, tile_z, rot90}` — `variant` is required for `water_facility` (`source\|treatment\|pump\|tank\|booster`, C-35) and absent for every other archetype | 02 buildings | PlacementBar issue chips (§2.7) |
| Road/line drag commit | `place_path` | `{kind: road\|power_line\|water_main, tiles[]}` | 10 / 04 / 05 | PlacementBar chips |
| Building panel `UPGRADE` | `upgrade_building` | `{building_id}` | 02 | requirement checklist rows |
| Building panel `REPAIR` | `repair_entity` | `{entity_id}` | 04 / 05 | toast + reason |
| Building panel `DEMOLISH` (hold 800 ms) | `demolish_building` | `{building_id}` | 02 / 03 | toast |
| Building panel `PRIORITY` | `set_load_priority` | `{building_id, tier}` | 04 power | toast |
| Land panel `PURCHASE` | `buy_land` | `{block_id}` | 03 economy | inline reason on the button |
| Land panel `DEVELOP` | `start_development_phase` | `{block_id, phase}` | 03 cost / 09 phase→crew mapping | inline reason |
| Unit picker row / `AUTO` | `dispatch_unit` | `{unit_id, incident_id}` | 06 dispatch | sheet inline error + haptic |
| Unit chip `RECALL` / toast UNDO | `recall_unit` | `{unit_id}` | 06 | toast |
| Unit picker `Queue anyway` | `queue_incident` | `{incident_id}` | 06 | toast |
| Drawer row swipe → `Acknowledge` | `acknowledge_incident` | `{incident_id}` | 06 incidents | — |
| Speed control | `set_speed` | `{multiplier: 1\|2\|3}` | 01 time | — |
| Pause toggle | `set_paused` | `{paused: bool}` | 01 time | — |
| Policy editor | `set_auto_policy` | `{key, value}` | 08 offline/persistence | — |
| Construction queue reorder | `reorder_project` | `{project_id, index}` | 02 owns `ConstructionQueue.reorder` / 06 owns the crews as units (report G-2) | toast |
| Cancel a project | `cancel_project` | `{project_id}` | 02 | confirm dialog |

Read side — the queries this doc requires (constitution §3 snapshot/query model):

```
Snapshot.city_stats()        -> {population, treasury, net_income_per_hour,
                                 grid_health_pct, water_health_pct,
                                 stability_score, active_incident_count,
                                 worst_incident_severity, weather_id, forecast_warning}
Snapshot.incidents()         -> [{id, type, severity, pos, district_name, waiting_s,
                                  severity(float), tier(int), esc_rate, assist_ratio,
                                  t_next_tier_h, progress,
                                  assigned_unit_ids, required_units, optional_units, status}]
Snapshot.units(dept?)        -> [{id, dept, type, name, home_station, pos, status, assigned_incident}]
DispatchQuery.eta_seconds(unit_id, incident_id) -> int      # doc 06, must be cheap (cached, ≤2 ms for 40 units)
DispatchQuery.eligibility(unit_id, incident_id) -> REQUIRED|OPTIONAL|INELIGIBLE
Snapshot.building(id)        -> spec §46 Building fields + service_coverage{power,water,police,fire}
BuildQuery.validate_placement(type_id, tile, rot) -> {verdict, failures[{code, subject, have, need, unit, at, remedy_hint, fix_target_id}]}
BuildQuery.validate_upgrade(building_id)          -> same failure shape
LandQuery.block(id)          -> {price, dev_cost, dev_time_min, terrain, risks{...}, adjacency_ok, buildable_tiles}
OverlayQuery.power() / .water() / .police() / .fire() / .traffic() -> render payload (nodes, edges, state enum, labels)
AwayReport.build(from_min, to_min) -> {ledger, deltas, timeline[], unresolved[], auto_actions[]}
```

`failures[].code` is a stable enum of **13** members (report 98 C-62 raised it from 12) so `RequirementFormatter` owns 100 % of the copy — the sim never returns display strings:

| # | Code | Raised by | Class |
|---|---|---|---|
| 1 | `POWER_CAPACITY` | 04 | hard |
| 2 | `WATER_PRESSURE` | 05 | hard |
| 3 | `NO_ROAD` | 02 (via doc 10 `access_quality`) | hard |
| 4 | `NO_CREW` | 02 queue / 06 crews | soft (WARN) |
| 5 | `FIRE_COVERAGE` | 02 | hard at L3+ |
| 6 | `CITY_LEVEL` | 09 progression | hard |
| 7 | `FUNDS` | 03 | hard |
| 8 | `OCCUPIED` | 02 | hard |
| 9 | `NOT_OWNED` | 09 world | hard |
| 10 | `UNDEVELOPED` | 09 world | hard |
| 11 | `TERRAIN` | 09 world | hard |
| 12 | `TECH_LOCK` | 09 progression | hard |
| **13** | **`E_AVENUE`** | **02 upgrade check #13** | **hard, L4/L5 only** |

`E_AVENUE` keeps doc 02's own check name verbatim rather than being re-spelled `AVENUE_REQUIRED`, so the two docs cannot drift apart on the identifier; its payload is `{have: <tiles to nearest avenue>, need: 4, unit: "tiles", at: <access tile>, fix_target_id: <road segment id>}`. Every code resolves its copy through `ui_requirement_<code_lowercase>` in `data/strings.en.json` (§3.1).

### 4.5 Events consumed from the sim bus

`incident_created`, `incident_escalated`, `incident_resolved`, `unit_dispatched`, `unit_arrived`, `unit_freed`, `power_restored`, `power_lost`, `construction_completed`, `land_developed`, `treasury_threshold`, `weather_warning`, `weather_changed`, `day_phase_changed`, `city_level_up`.
Each maps to: a marker update, an optional in-app alert banner (via `InAppAlertGate`, §2.13), an optional **push** — which this doc only *requests*; doc 08 decides class and budget and doc 13 delivers it — and an optional `OnboardingDirector` trigger.

---

## 5. Cross-System Interfaces

**Doc numbering is the on-disk filename set and nothing else (report 98 Ruling Zero).** The titles below are the canonical ones from report §0; where this doc previously used a shorter or older title for a neighbour (doc 08 "offline & persistence", doc 09 "map, terrain & starter city"), the canonical title replaces it.

| Doc | I read / need | I provide |
|---|---|---|
| **01 time model & tick scheduler** | `GameClock` game-minutes, day phase, current speed multiplier (`{1,2,3}`), tick cadences | `set_speed`, `set_paused`; auto-pause requests |
| **02 buildings, upgrades & construction projects** | building snapshot, `validate_placement`, `validate_upgrade` failure payloads incl. `E_AVENUE`, the `water_facility` variant list, level meshes for the ghost, `ConstructionQueue` stages | `place_building{type_id, variant?}`, `upgrade_building`, `demolish_building`, `cancel_project`, `reorder_project` |
| **03 economy, taxes, land market & difficulty** | treasury, net income per game-hour, revenue/expense breakdown, 7-day series, land price + development cost, `set_tax_rate`. **Revenue auto-accrues** — there is no collection command and no `manual_collection` flag (C-59) | dashboard Economy tab, `buy_land`, `start_development_phase` |
| **04 electrical grid** | `OverlayQuery.power()` (nodes, edges, load/cap, state enum), feeder headroom for the upgrade panel, shed tiers, `POWER_CAPACITY` failure payloads, `block_dark` events | `place_path{power_line}`, `repair_entity`, `set_load_priority` |
| **05 water system** | `OverlayQuery.water()`, pressure per zone, per-variant capacity/`base_kw` for the five `water_facility` cards, hydrant effectiveness for the fire overlay, `WATER_PRESSURE` failures | `place_path{water_main}`, `repair_entity` |
| **06 incidents, dispatch & emergency fleets** | incident snapshot incl. `severity`/`tier`/`esc_rate`/`assist_ratio`/`progress` (the UI derives `t_next_tier_h` itself), cascade edge list for the "why it happened" card, `spawn_scripted()`, unit roster + status, construction crews, **`eta_seconds()` and `eligibility()`**, queue positions, soonest-free time | `dispatch_unit`, `recall_unit`, `queue_incident`, `acknowledge_incident`, `reorder_project` |
| **07 weather & disaster director** | current weather id, forecast warning + countdown, `precip01`, `director.suppress_until` hook for onboarding | suppression request during and after the tutorial |
| **08 persistence, offline policy & notification policy** | `AwayReport.build()`, the event-history ring buffer, auto-response policy storage, the `ui` save section ladder, and — sole owner since C-71 — the push classes P1–P4, the 18-event class map, push budgets, quiet hours and coalescing in `data/notifications.json`, plus the `is_resync` flag that tells the UI not to animate a catch-up | S11 report layout, policy editor, `set_auto_policy`, push *requests* (never push decisions) |
| **09 map, land, districts, population & stability, starter city** | named entities the tutorial references: `tutorial_lot_A`, `tutorial_lot_B`, transformer `T-04`, pump `P-2`, `Utility 1`, block `E4`, Substation A; land-block adjacency; population, city level and `city_stability` (published on `[0,1]`, displayed here ×100 — §2.4) | — (this doc *consumes* those names; doc 09 must define them) |
| **10 roads, routing & traffic** | road graph for drag-path preview, per-edge congestion (TRAFFIC overlay), closures and flooded segments, emergency route polylines, `STREET`/`AVENUE` class per segment for the `E_AVENUE` fix-target | `place_path{road}` |
| **11 rendering & performance** | `Camera3D` ownership handshake, the **projection constants** (`fov_deg`, `near_m`, `far_m`) in `data/render.json` (C-63), the 2-bit `overlay_state` packing this doc feeds four values into (C-64), `unproject_position` for markers, overlay geometry draw budget, post-process saturation/exposure hooks, LOD state for the placement ghost | camera **interaction** state (`focus`, `zoom_t`, `yaw`, derived pitch) and the `D_MIN 18` / `D_MAX 420` / pitch `34→62` range, overlay mode, reduce-motion and graphics-preset settings |
| **13 android integration & export** | notification **platform** only — channels mapped to P1/P2/P3, `AlarmManager`, permission flow (C-71) — plus `get_display_safe_area()`, back-button lifecycle, resume elapsed-time handoff | S10 settings writes, the `n_<event>_title/_body` copy from `data/strings.en.json` (G-8), and the in-app/push boundary (`InAppAlertGate` never pushes) |

Two interfaces are **blocking** for this doc and must exist before the vertical slice: `DispatchQuery.eta_seconds()` (doc 06) and the structured `failures[]` payload (docs 02/04/05). Without them the two-tap dispatch flow and the §2.7 messaging cannot be built.

*(Canonical roster, report 98 §0 — the on-disk filenames, and no other map: 01 time model & tick scheduler, 02 buildings/upgrades/construction, 03 economy/taxes/land market/difficulty, 04 electrical grid, 05 water system, 06 incidents/dispatch/fleets, 07 weather & disaster director, 08 persistence/offline/notification policy, 09 map/land/districts/population/stability/starter city, 10 roads/routing/traffic, 11 rendering & performance, 12 this doc — UI/UX, camera input & onboarding, 13 Android integration & export.)*

---

## 6. MVP Cut

**In the vertical slice:**
S1 city HUD (all 7 chips + clock/weather), S2 build sheet (Residential/Civic/Utility/Roads/Land tabs), S3 placement with validity + requirement chips, S4 land purchase + development, S5 building panel with upgrade checklist, S6 incident drawer, S7 unit picker with ETA sort, S8 dashboard Overview + Response tabs, S9 settings (Gameplay/Accessibility/Notifications/Graphics), S11 away report, S12 onboarding steps 0–11.
Overlays: POWER, WATER, FIRE, POLICE (TRAFFIC if doc 10 exposes per-edge congestion in time).
Camera: pan, pinch, twist+snap45, momentum, bounds, double-tap, jump, follow.
Accessibility: A1, A3, A4, A5, A7, A10, A11, A14 — hard gates for the slice.

All eight Utility build cards including the five `water_facility` variants (C-35); `data/strings.en.json` complete for every shipped screen, English only (G-8); the 13-code `RequirementFormatter` including `E_AVENUE` (C-62).

**Deferred:** TRAFFIC and CONSTRUCTION overlays and multi-overlay stacking; S13 full event log (the away report shows the top 8); Dashboard Economy/Infrastructure charts beyond raw numbers; colourblind palette variants A6 (the default palette is already glyph-redundant), text scale A2 beyond 100/130 %, screen-reader labels A15; manual camera pitch, bookmarks, mini-map; radial long-press quick actions (long-press falls back to opening the panel); cluster de-clustering animation (clusters snap); haptics beyond `light`; any second locale. Digest mode and quiet hours are **not this doc's to defer** — they are doc 08 policy surfaced by S10 (C-71); if doc 08 ships them disabled, S10 greys them with doc 08's reason string.

---

## 7. Test Plan

Headless (`tests/ui/`), no scene tree — these exercise `ui/logic/` classes with synthetic input:

1. **`test_gesture_tap_vs_drag`** — 6 dp travel in 180 ms → `TAP`; 9 dp in 180 ms → `PAN`; 6 dp in 260 ms → `PAN`; never both.
2. **`test_gesture_longpress`** — 460 ms at 9 dp travel → `LONG_PRESS`; at 11 dp → `PAN`, no long press.
3. **`test_gesture_double_tap`** — 200 ms / 20 dp apart → `DOUBLE_TAP`; 300 ms apart or 30 dp apart → two `TAP`s.
4. **`test_gesture_multi_arbitration`** — a second finger 60 ms after the first suppresses the pending tap; 30 dp span change engages ZOOM; 10° twist engages ROTATE; both run concurrently; lifting one finger returns to `PAN` with `|Δfocus| < 0.01 m` on the transition frame.
5. **`test_camera_zoom_curve`** — `dist(0)=18`, `dist(0.42)=67.6±0.1` (the default framing, recomputed under C-63 — **not** the retired 71 m), `dist(0.5)=86.9±0.1`, `dist(1)=420`; `t(dist(x))==x` over 100 samples; `pitch(0)=34°`, `pitch(0.42)=44.67°±0.01`, `pitch(0.5)=48°`, `pitch(1)=62°`, monotonic.
5b. **`test_camera_constants_are_not_restated`** — reads both files: `data/ui.json.camera` contains `dist_min_m`/`dist_max_m`/`pitch_*_deg` and contains **no** `fov_deg`, `near_m` or `far_m` key; `data/render.json` contains all three; the §2.16 coverage table regenerates from the two files combined (ground width at `t=1` = `1.6015·420 = 672.6 ± 0.5 m` at aspect 2.2). If doc 11 retunes FOV, this test fails loudly instead of leaving a stale table (C-63).
6. **`test_camera_pan_world_lock`** — over 50 random (yaw, zoom_t, touch) triples, the anchor ground point re-projects to the new touch position within 0.5 dp after a synthetic drag.
7. **`test_camera_momentum_decay`** — from 60 m/s, coast distance 10.0 ± 0.2 m, stopped within 1.0 s; a new touch zeroes velocity in the same frame.
8. **`test_camera_bounds_rubberband`** — over-bound drag displaces 0.35×; the spring settles within 0.40 s with ≤ 1 % overshoot.
9. **`test_camera_rotation_snap`** — 37° → 45°, 68° → 90°; `free` never snaps; `locked` ignores twist entirely.
10. **`test_topbar_collapse`** — the §2.4 worked example (W=640) reproduces exactly; W=880 keeps all chips FULL; P1–P4 never HIDDEN at any width ≥ 480; deterministic, ≤ 14 iterations.
11. **`test_incident_sort`** — T5-unassigned ≺ T5-assigned ≺ T4; ties order by `t_next_tier_h` (HELD incidents last within their tier) then `waiting_s`; strict weak ordering under a 1000-list fuzz.
11b. **`test_escalation_readout`** — `t_next_tier_h` matches doc 06's worked example (tier-3 fire, `assist_ratio = 0.626` → escalation at 37 % rate); `assist_ratio ≥ 1` yields the `HELD` state with a frozen bar and NORMAL styling, never a divide-by-zero.
12. **`test_unit_picker_sort`** — ETA ascending; `Available` outranks `Returning` at equal ETA; `INELIGIBLE` last; `AUTO` == `rows[0]`.
13. **`test_requirement_formatter`** — all **13** `failure.code` enums (the 12 originals plus `E_AVENUE`, C-62) yield a non-empty string containing `have` and `need` and a `fix_target` route; `E_AVENUE` specifically renders `have` in tiles, `need == 4`, names the target level, and routes `fix_target_id` to a **road segment** rather than a building; unknown codes degrade to a generic string, never crash; every template resolves from `data/strings.en.json` and none is inline in code.
14. **`test_number_format`** — `money`: `8420→"$8,420"`, `842000→"$842K"`, `8_420_000→"$8.42M"`, `-1_200_000→"−$1.2M"`; `rate(5750)=="+$138K/d"`; `eta(48)=="0:48"`, `eta(3720)=="1:02"`.
15. **`test_onboarding_sequence`** — a scripted event log advances steps 0→11 in order, never out of order; the scripted incident spawns exactly once at step 7; director suppression holds throughout and clears 300 s after step 11; `skip()` completes all and grants nothing.
16. **`test_onboarding_hard_gate`** — a `command_accepted` failing the step's `match` filter (wrong `type_id`, tile outside `tutorial_lot_A`) does not complete the step.
17. **`test_in_app_alert_gate`** (was `test_notification_gate`) — 5 P2 in one real hour → 3 banners delivered, 2 degraded to toasts, bucket refills after an hour; 4 mixed P2+P3 in one hour → 3 delivered on the shared `global_max_per_hour`; 7 P1 in one hour → all 7 shown (P1 is `never_drop` and exempt from the global cap), with any pair inside 300 s coalescing into one updated banner; 600 s per-type cooldown respected; the gate never reads doc 08's push budgets and emits no push (asserted by a null `INotificationSink`), and quiet hours are never consulted — C-71/C-72.
18. **`test_marker_projection`** — off-screen positions clamp inside the marker rect; the rect shrinks by `drawer_w` when the drawer is open; 30 dp apart clusters, 50 dp does not.
19. **`test_theme_lint`** — no `theme_override_*` in any `ui/**.tscn`; every interactive Control has `custom_minimum_size ≥ 48 dp` on both axes and non-empty `tooltip_text`.
20. **`test_palette_a11y`** — pairwise relative-luminance Δ ≥ 0.10 across the four states; glyphs and dash patterns unique; every Theme text/background pair ≥ 4.5:1 (≥ 3:1 for `Title`+); `state_glyphs`, `state_dash` and `state_pulse_hz` each have **exactly four** keys and no `selected` member — the selection ring is validated separately from `selection_ring` (C-64).
21. **`test_string_table`** (G-8) — every `Str.t()` key referenced anywhere in `ui/**` exists in `data/strings.en.json`; every key matches `^(ui_[a-z0-9_]+|n_[a-z0-9_]+_(title|body))$`; every `n_<event>_*` event id exists in doc 08's event→class map and vice versa (no orphan copy, no uncopied event); no value contains a positional `%s`; no `.tscn` or `.gd` under `ui/` carries a literal display string (lint walk, same pass as test 19).
22. **`test_build_card_variants`** (C-35) — the Utility tab emits exactly the eight cards of §2.7; the five `water_facility` cards produce payloads differing only in `variant`; every non-`water_facility` card omits `variant` entirely; a card's micro-row values equal the archetype table's row for that variant (no hardcoded kW).
23. **`test_onboarding_no_manual_collection`** (C-59) — step 5 is `review_ledger`, completes on the Economy tab being open ≥ 2 s, and the step machine exposes no `collect_revenue` path; the string `manual_collection` appears nowhere in `ui/` or `data/`.

24. **`test_ui_goals`** (§2.19, Wave 9) — the chip reads `L<level> · <done>/<total>` and **retires** when doc 09 §2.14's curriculum is finished; the bar is untouched until a curriculum is fed (test 10's `W = 880 keeps all chips FULL` still holds for a HUD with no goals model), and with the chip up P1–P4 *and the chip itself* survive every width from 480 to 1200 dp; every objective row resolves its copy and reads as a fraction, in the units the population chip uses; the reward card equals the set of build cards whose `min_city_level` is exactly that rung; a finished objective shows a tick and no counter; the row set rebuilds when a level lands; tapping the chip opens S14 and not S8; and `city_level_objectives_met` raises the toast. The sheet is swept by `tools/ui_preview.gd --screen=goals|goals_late|goals_done` at all five device boxes, at 100 % and at 130 % + larger targets, with zero findings of its own.

25. **`test_path_tool`** (§2.7's drag-path, Wave 10) — `PathTool.l_path()` is an L, Manhattan, longest leg first, ordered from the anchor, corner emitted once, ties to X; the roster is six cards on the two tabs §2.7 files them under, each quoting a **per-tile** price read from `CostCurves` and none of them locked; the two category literals and the three road-class integers equal `BuildController`'s and doc 10's; a ghost move never pins the anchor and `START` does; the run's verdict, its price and its refusal are the owning command's own `preview = true` answer; a run that overlaps existing road is billed for the fresh tiles only and the ghost's `billable` flags say which; the sweep is capped at `placement.max_run_tiles` by truncating the far end; `↺` unpins without dropping the card; `Remove` quotes a refund and credits the treasury by exactly what it quoted; and `PathGhostView` draws one slab per tile in the same four §2.5 tints the box ghost uses.

26. **`test_build_controller`'s actions block** (§2.9 item 6, Wave 10) — the repair row is absent at condition 1.00 and priced by doc 03 §2.5 below it, the panel charges exactly what it printed and then shows `E_JOB_IN_FLIGHT` in words; `Fix this →` on `E_CONDITION` buys the repair and hands the camera router nothing; the priority row is doc 04's own class roster and a tap moves the sim's shed tier; `DEMOLISH` fires on a full 800 ms hold and on nothing shorter, credits the quoted refund, and closes the panel. The run flow is asserted through the sheet the player touches: one `is_placing()` for both tools, the two-step bar, and a world drag that draws without committing on finger-up.

Manual/device checklist (not automated): thumb-reach on a 6.1" and a 6.8" device, notch/cutout safe area on a punch-hole and a notched device, one-handed reachability of jump-to-worst, 150 % text scale at 640 dp, and the step-9 relight moment reading as a payoff.

---

## 8. Tunables

Ships as three files — `data/ui.json`, `data/onboarding.json`, `data/strings.en.json` — presented here as one block keyed by file name. Two blocks that used to appear here are **gone, not deprecated**: `data/notifications.json` (push classes, event map, budgets, quiet hours) is doc 08's, and the camera projection constants `fov_deg` / `near_m` / `far_m` are doc 11's in `data/render.json`. Look there; do not re-add them here.

```json
{
"data/ui.json": {
  "layout": {
    "reference_box_dp": [880,400], "min_safe_box_dp": [640,340], "safe_area_bleed_dp": 4,
    "breakpoints_dp": {"compact_max":699,"regular_max":899},
    "top_bar_h_dp": 48, "chip_gap_dp": 6, "clock_chip_w_dp": 132, "chip_never_hidden_count": 4,
    "chip_priority": ["treasury","incidents","grid","water","population","net_income","stability"],
    "chip_widths_full_dp": {"treasury":104,"incidents":64,"grid":80,"water":80,"population":104,"net_income":96,"stability":112},
    "chip_widths_compact_dp": {"treasury":72,"incidents":48,"grid":56,"water":56,"population":64,"net_income":64,"stability":64},
    "fab_d_dp": 64, "rail_button_d_dp": 56, "rail_gap_dp": 8, "rail_margin_dp": 12,
    "drawer_w_ratio": 0.34, "drawer_w_min_dp": 260, "drawer_w_max_dp": 340,
    "drawer_row_h_dp": 72, "drawer_handle_dp": [44,160], "drawer_handle_center_from_bottom_dp": 140,
    "side_panel_w_dp": 300, "bottom_sheet_h_dp": 200, "unit_picker_h_dp": 240, "unit_row_h_dp": 56,
    "placement_bar_h_dp": 56, "placement_ghost_finger_offset_dp": 64, "build_card_dp": [96,120],
    "legend_w_dp": 200, "legend_max_h_dp": 180,
    "alert_dp": [400,44], "alert_max_stack": 2, "alert_ttl_s": 6.0,
    "toast_dp": [320,40], "toast_ttl_s": 2.5, "toast_undo_s": 5.0,
    "marker_tap_dp": 48, "marker_visual_dp": 32, "marker_cluster_dp": 40, "marker_rect_inset_dp": [12,60,12,70],
    "thumb_pivot_inset_dp": 28, "thumb_frequent_r_dp": 110, "thumb_occasional_r_dp": 165,
    "touch_target_min_dp": 48, "touch_target_large_dp": 56, "touch_spacing_min_dp": 8,
    "sheet_anim_s": 0.22, "drawer_anim_s": 0.22, "coach_cutout_anim_s": 0.20, "hold_to_confirm_ms": 800
  },
  "type_scale_dp": {"display":28,"title":20,"body":14,"label":12,"numeric":16},
  "text_scale_options": [0.85,1.0,1.15,1.30,1.50],
  "palette": {
    "default": {"normal":"#33C27A","warning":"#F2B13C","critical":"#E5533D","offline":"#5A6270","selected":"#4FA8FF",
                "tier1":"#7FB2D9","tier2":"#E3C64A","tier3":"#EE8C36","tier4":"#E5533D","tier5":"#FF3B6B",
                "bg":"#0E1116","surface":"#161B22","surface_alt":"#1E242D","text":"#E6EAF0","text_dim":"#9AA3B0","accent":"#4FA8FF"},
    "deuteran": {"normal":"#3AA6FF","warning":"#F2C43C","critical":"#D6453B","offline":"#5A6270","selected":"#B36BFF"},
    "protan":   {"normal":"#3AA6FF","warning":"#EFD24A","critical":"#C8452F","offline":"#5A6270","selected":"#B36BFF"},
    "tritan":   {"normal":"#2FBF9E","warning":"#F07C9B","critical":"#D6453B","offline":"#5A6270","selected":"#3AA6FF"}
  },
  "_comment_states": "Exactly four data states — these four ARE doc 11's 2-bit overlay_state (C-64). SELECTED is not one of them.",
  "state_glyphs": {"normal":"circle_filled","warning":"triangle","critical":"diamond","offline":"cross"},
  "state_dash":   {"normal":[1,0],"warning":[8,6],"critical":[4,4],"offline":[2,6]},
  "state_pulse_hz": {"normal":0.0,"warning":0.0,"critical":1.2,"offline":0.0},
  "state_luminance_min_delta": 0.10,
  "selection_ring": {"color_token":"selected","glyph":"ring","width_dp":3,"pulse_hz":0.6,
                     "layer":"MarkerLayer","max_concurrent":1, "is_overlay_state": false},
  "overlay": {
    "modes": ["none","power","water","police","fire","traffic"],
    "desaturate": 0.25, "exposure": 0.70, "transition_s": 0.18,
    "strip_chip_dp": [64,56], "strip_x_offset_dp": 80,
    "outage_fill_alpha": 0.25, "coverage_disc_alpha": 0.18, "flow_dash_speed_m_s": 14.0, "heat_bin_m": 32.0
  },
  "camera": {
    "_comment": "Interaction range only (C-63). Projection constants fov_deg/near_m/far_m live in data/render.json (doc 11) and are read from there; they must never be added to this block.",
    "projection_from": "data/render.json",
    "dist_min_m": 18.0, "dist_max_m": 420.0, "dist_max_city_factor": 1.6, "dist_max_city_min_m": 120.0,
    "pitch_near_deg": 34.0, "pitch_far_deg": 62.0,
    "default_zoom_t": 0.42, "default_zoom_dist_m_derived": 67.6, "default_yaw_deg": 45.0, "bounds_pad_blocks": 2,
    "rubber_band": 0.35, "spring_omega": 12.0,
    "momentum_min_start_m_s": 3.0, "momentum_max_m_s": 220.0, "momentum_decay_k": 6.0,
    "momentum_stop_m_s": 0.5, "velocity_ema_alpha": 0.4, "ray_parallel_eps": 0.08,
    "double_tap_zoom_delta_t": 0.18, "double_tap_tween_s": 0.28,
    "jump_tween_s": 0.45, "jump_arc_threshold_m": 400.0, "jump_arc_tween_s": 0.75, "jump_arc_zoom_bump_t": 0.25,
    "follow_lerp_k": 8.0, "rotation_mode_default": "snap45", "rotation_snap_deg": 45.0, "rotation_snap_tween_s": 0.25
  },
  "gestures_dp_ms": {
    "tap_slop_dp": 8, "tap_max_ms": 220, "longpress_ms": 450, "longpress_slop_dp": 10,
    "double_tap_ms": 260, "double_tap_slop_dp": 24, "drag_start_slop_dp": 8,
    "pinch_span_slop_dp": 24, "twist_deadzone_deg": 8.0, "multi_suppress_ms": 80
  },
  "placement": {"validity_tint_alpha": 0.35, "revalidate_hz": 10, "max_issue_chips": 3, "commit_requires_button": true, "max_run_tiles": 48},
  "thresholds": {
    "grid_normal_pct": 95, "grid_warning_pct": 85, "grid_critical_pct": 60,
    "water_normal_pct": 95, "water_warning_pct": 85, "water_critical_pct": 60,
    "stability_high": 75, "stability_moderate": 50, "stability_low": 25,
    "population_decline_warn_pct_per_day": -0.5, "escalation_bar_critical_remaining_tiers": 0.25, "escalation_bar_held_when_assist_ratio_ge": 1.0
  },
  "speed": {"options": [1,2,3], "default": 1, "paused_is_separate_flag": true, "resume_unpaused": true, "auto_speed_reset_on_critical": true},
  "away_report": {"min_real_seconds": 120, "max_timeline_entries": 8, "max_unresolved_shown": 3},
  "in_app_alerts": {
    "_comment": "FOREGROUND banners and toasts ONLY (C-71/C-72). These are ~3x doc 08's PUSH budgets in data/notifications.json and that is deliberate: an in-app banner costs a glance the player is already giving. Never read these to decide a push, or a push budget to decide a banner.",
    "classes": {
      "p1": {"bucket_capacity":6,"refill_per_real_hour":6,"never_drop":true,"exempt_from_global":true,
             "coalesce_window_s":300,"surface":"banner"},
      "p2": {"bucket_capacity":3,"refill_per_real_hour":3,"never_drop":false,"exempt_from_global":false,
             "coalesce_window_s":0,"surface":"banner","degrade_to":"toast"},
      "p3": {"bucket_capacity":1,"refill_per_real_hour":1,"never_drop":false,"exempt_from_global":false,
             "coalesce_window_s":0,"surface":"banner","degrade_to":"toast"}
    },
    "global_max_per_hour": 3, "global_applies_to": ["p2","p3"], "per_type_cooldown_s": 600,
    "consults_quiet_hours": false, "may_emit_push": false,
    "class_map_from": "data/notifications.json", "enabled_default": true
  },
  "haptics_ms": {
    "light": {"button":0,"snap_tile":0,"blocked":20,"dispatch":12,"escalate":40,"power_restored":30,"rotation_snap":0},
    "full":  {"button":8,"snap_tile":5,"blocked":30,"dispatch":20,"escalate":40,"power_restored":60,"rotation_snap":8}
  },
  "defaults": {"text_scale":1.0,"colorblind":"default","reduce_motion":false,"larger_touch_targets":false,
               "haptics":"light","invert_pan":false,"follow_dispatched_unit":true,"graphics":"balanced","battery_saver":false}
},

"data/onboarding.json": {
  "global": {
    "hint_after_s": 25, "autohelp_after_s": 60, "dim_alpha": 0.55, "cutout_pad_dp": 8, "cutout_radius_dp": 12,
    "bubble_max_w_dp": 240, "coach_text_max_chars": 90,
    "director_suppressed_during": true, "director_suppress_after_s": 300, "skip_grants_nothing": true
  },
  "step_overrides": {
    "build_house":      {"build_time_s":20,"cost_override":0,"valid_region":"tutorial_lot_A"},
    "confirm_power":    {"cost_override":500,"valid_region":"tutorial_power_corridor"},
    "confirm_water":    {"cost_override":500,"valid_region":"tutorial_water_corridor"},
    "service_building": {"build_time_s":25,"cost_override":0,"valid_region":"tutorial_lot_B"},
    "dispatch":         {"eligible_units":["utility_1"],"forced_eta_s":48},
    "repair":           {"repair_time_s":30},
    "upgrade":          {"post_upgrade_feeder_load_pct":92},
    "buy_land":         {"block_id":"E4","price_override":1}
  },
  "scripted_incident": {
    "id": "TUT_TRANSFORMER_FAIL", "type": "transformer_failure", "severity": 3,
    "anchor_entity": "T-04", "delay_after_step_s": 8,
    "required_units": [{"type":"utility_truck","count":1}],
    "tier3_to_tier4_seconds_unattended": 180, "escalation_disabled_on_casual": true,
    "on_escalate": {"spawn":"structure_fire","severity":2,"target":"nearest_residential"},
    "effects": {"unpower_buildings_in":"B2","street_lights_off_in":"B2","pump_offline":"P-2",
                "pressure_pct_after":60,"district_stability_per_real_min":-1.0},
    "notification_priority": "p1", "repair_cost_waived": true
  }
},

"data/strings.en.json": {
  "_comment": "G-8: every display string in the game, English only in MVP. Keys are ui_<screen>_<element> or n_<event>_title/_body (doc 08's event ids). Full table is authored alongside the screens; the entries below fix the conventions and the load-bearing templates.",
  "ui_hud_build_fab": "BUILD",
  "ui_hud_jump_to_worst": "Jump to worst incident",
  "ui_build_tab_utility": "Utility",
  "ui_build_card_water_facility_source": "Water Source",
  "ui_build_card_water_facility_treatment": "Treatment Plant",
  "ui_build_card_water_facility_pump": "Pump Station",
  "ui_build_card_water_facility_tank": "Storage Tank",
  "ui_build_card_water_facility_booster": "Booster",
  "ui_placement_confirm": "PLACE",
  "ui_placement_issues": "{n} issues",
  "ui_requirement_power_capacity": "Electrical capacity insufficient: {have} available / {need} required at {at}. {remedy}",
  "ui_requirement_water_pressure": "Water pressure insufficient: {have} at this block / {need} required. {remedy}",
  "ui_requirement_no_road": "No road access: nearest road is {have} tiles away. Build a road to this parcel.",
  "ui_requirement_no_crew": "No construction crew free: {have} / {need} crews busy. {remedy}",
  "ui_requirement_fire_coverage": "Fire coverage missing: nearest station {have} (max {need} for Level 3+). {remedy}",
  "ui_requirement_city_level": "City level too low: Level {need} required, you are Level {have}. {remedy}",
  "ui_requirement_funds": "Insufficient funds: {have} available / {need} required.",
  "ui_requirement_occupied": "Tile occupied: {have} is already built on. Demolish it or choose another tile.",
  "ui_requirement_not_owned": "Block not owned: buy {at} first.",
  "ui_requirement_undeveloped": "Block not developed: run the 6 development phases on {at} first.",
  "ui_requirement_terrain": "Terrain unsuitable: {have}. Choose flatter or drier ground.",
  "ui_requirement_tech_lock": "Not unlocked yet: {remedy}",
  "ui_requirement_e_avenue": "Avenue access insufficient: nearest avenue {have} tiles from the access tile / {need} tiles required for Level {level}. Upgrade this block's boundary road to an AVENUE, or build one within {need} tiles.",
  "ui_drawer_held": "HELD",
  "ui_drawer_assign": "ASSIGN",
  "ui_picker_auto": "AUTO — best available",
  "ui_away_header": "WHILE YOU WERE AWAY",
  "ui_away_handle_now": "HANDLE NOW",
  "ui_coach_skip": "Skip tutorial",
  "ui_coach_review_ledger": "Your city just earned money. Tap TREASURY to see where it comes from.",
  "ui_settings_in_app_banners": "In-app banners",
  "n_outage_major_title": "{count} blocks are dark",
  "n_outage_major_body": "{district} lost power at {time}. {units} crews are responding."
}
}
```

---

## 9. Conflicts & Open Questions

### Conflicts / deviations to flag

1. **~~Spec §41 step 5 "Collect taxes" may not be a tap.~~ RULED — report 98 C-59.** Auto-accrual is approved, the spec §41.5 deviation is signed off, and `economy.manual_collection` is deleted from doc 03 and from this doc. Onboarding step 5 is `review_ledger` (§2.17) with no branch and no `collect_revenue` command. Nothing remains open here.
2. **Constitution §11 art direction vs. UI luminance.** Neo-noir dark chrome (`bg #0E1116`) plus A7 (4.5:1 text contrast) constrains how dim HUD surfaces can be. Resolved in favour of contrast: surfaces `#161B22`, text `#E6EAF0` (≈ 13:1). If art wants dimmer, A7 wins.
3. **Speed control now follows doc 01, not my first draft.** Doc 01 locks `speed ∈ {1,2,3}` with `paused` separate and forbids force-pausing on critical events; §2.11 and the tunables were rewritten to match. Spec §49's "pause/slow-speed controls" is still met (explicit pause exists, 1× is the floor) but there is **no slow-motion below 1×** — flagging in case "slow speed" was meant literally.
4. **Commands are accepted while paused** — a rules decision touching doc 01. I assert it is correct (the clock is stopped, so nothing is gained) but doc 01 may disagree.
5. **~~Command ownership overlap.~~ RULED — report 98 G-2.** Doc 06 owns crews as dispatchable units; doc 02 owns the project record and publishes `ConstructionQueue.submit/reorder/cancel`; doc 09 owns the land-development phase→crew mapping. That is exactly the split §4.4 assumed, now normative rather than assumed.
6. **~~`content_scale_mode = disabled` + `content_scale_factor`.~~ RULED — report 98 C-69.** The 3D scene renders into a `SubViewport` sized `viewport_px × render_scale`, composited under the UI `CanvasLayer`; UI stays dp-exact for the 48 dp gate and doc 11 keeps `render_scale`. **The `Camera3D` handshake is also settled (C-63):** this doc owns camera state, input and the interaction range (`D_MIN 18`, `D_MAX 420`, pitch `34→62`); doc 11 owns the node, the projection constants in `data/render.json`, culling and LOD. Neither restates the other's numbers, and test 5b enforces it.
7. **`data/strings.en.json` vs `data/notifications_text.json` — a tension inside report 98 itself.** C-71 assigns notification copy to a doc-13 file `data/notifications_text.json`; G-8 assigns this doc `data/strings.en.json` keyed with `n_<event>_title` / `n_<event>_body`, which is the same copy. I have applied **G-8** (it is the ruling that names an owner for the string table as a whole, and splitting copy across two files by delivery channel is exactly how a push and its in-app banner drift apart): all display copy including `n_*` lives in this doc's table, and doc 13 reads those keys. Flagged for the overseer — a one-line correction to C-71 would close it.

### Open questions for the overseer

1. **Severity readout resolved against doc 06** (continuous `severity`, derived integer `tier`): the UI prints the **tier digit** and never the float. Remaining question — should the drawer row also expose the fractional part (e.g. a hairline sub-tick at `severity − tier`) for expert players, or is the escalation bar enough? I have chosen the bar only.
2. **Does `DispatchQuery.eta_seconds()` exist cheaply?** The unit picker needs ETA for up to ~40 units within one frame. If routing cost makes that impossible, I need a cached/estimated ETA (straight-line × congestion factor) with a "refining…" state — please confirm which doc 06 will deliver.
3. ~~**Is there a manual "collect" affordance at all?**~~ **Closed by C-59: no.** Revenue auto-accrues; no collect affordance exists anywhere in the UI.
4. ~~**Does the player draw power lines and water mains tile-by-tile?**~~ **Closed by C-41: yes — player-drawn, with an auto-route assist.** Drag-path placement stays the primary interaction; a `Route along roads` button fills the path and the player still presses `✔`. Doc 04's open question 9 is closed with it, and onboarding steps 3–4 stand as written.
5. **Land purchase currency:** confirm no premium currency gates land in MVP (constitution §7 says no premium currency in MVP — I have assumed treasury only).
6. **Tutorial skippability on a fresh install:** should the skip button appear at step 0, or only after step 2? Skipping immediately means a player can reach an unsuppressed director with zero knowledge. I default to skippable from step 0 with a 300 s grace, but a "skip only after step 2" rule is defensible.
7. **Named tutorial entities** (`tutorial_lot_A`, `tutorial_lot_B`, `T-04`, `P-2`, `Utility 1`, block `E4`, Substation A) must be stable ids in doc 09's starter city. Please confirm doc 09 will guarantee them, or give me a tagging mechanism instead of hardcoded ids.
8. **Traffic overlay in MVP** depends on whether doc 10 exposes per-edge congestion in the slice. Currently listed as conditional.

---

## Amendments applied (report 98)

Every row of report 98 §12's worklist for doc 12, plus the Ruling Zero pass. Deleted material is deleted, not commented out; each deletion leaves a pointer to the owning doc.

| Ruling | What changed here |
|---|---|
| **Ruling Zero** | §5's cross-system table now uses the canonical on-disk titles (08 → *persistence, offline policy & notification policy*; 09 → *map, land, districts, population & stability, starter city*; 10 → *roads, routing & traffic*; 06 → *incidents, dispatch & emergency fleets*; 13 → *Android integration & export*), and the roster footnote restates report §0 verbatim. Doc 12 already referenced neighbours by on-disk number, so no number moved — only stale titles and stale ownership claims. |
| **C-25** | §3.2 save section: `"schema_version": 1` → `"section_version": 1`, with a note that `schema_version` exists only on the envelope. |
| **C-35** | §2.7 gained the Utility-tab card table: `water_facility` contributes **five** cards (source / treatment / pump / tank / booster), each with its own footprint, `base_kw` and level pips; §4.4's `place_building` payload gained `variant?`; §2.5's WATER overlay row now names the five variants; new test 22. |
| **C-59** | Manual tax collection **deleted**. Onboarding step 5 is `review_ledger` (was `taxes`) with no branch; the `economy.manual_collection` conditional, the `collect_revenue` command and the flag are gone from §2.17, §5 and §9; §9 conflict 1 and open question 3 are marked ruled; new test 23 asserts the string appears nowhere. |
| **C-62** | §4.4's `failures[].code` enum grew from 12 to **13** with `E_AVENUE` (doc 02 check #13, name carried verbatim), tabulated with its raiser and hard/soft class; §2.7 gained the `RequirementFormatter` string and the road-segment `fix_target_id` rule; test 13's expectation moved 12 → 13. |
| **C-63** | Interaction ranges kept (`D_MIN 18`, `D_MAX 420`, pitch `34→62`). Projection constants `fov_deg 45` / `near_m 1` / `far_m 2000` **deleted** from §2.16 and from `data/ui.json.camera` → doc 11's `data/render.json` (`fov_deg 40`, `near_m 1`, `far_m 1600`), referenced not restated. §2.16's worked example is fully regenerated as a four-row table with the derivation stated above it; default zoom corrected 71 m → **67.6 m**; max-zoom framing corrected "≈5×5 blocks" → **673 × 360 m ≈ 5.3 × 2.8 blocks**. Test 5 gained the 0.42 expectations; new test 5b fails if either file restates the other's constants. |
| **C-64** | §2.5's state table is **four** rows; SELECTED is removed from it and re-specified as a `MarkerLayer` ring (§2.15) that never enters doc 11's 2-bit `overlay_state`; `state_glyphs` / `state_dash` / `state_pulse_hz` lost their `selected` member in favour of a `selection_ring` block; the save section carries one `selected_entity_id`; test 20 asserts exactly four keys. |
| **C-65** | A10 corrected to **pause + 1× / 2× / 3×** in ≤ 2 taps, matching §2.11 and doc 01's `speed ∈ {1,2,3}`; the row gained a verification method and an explicit "no sub-1× slow motion in MVP" reading. |
| **C-71 / C-72** | `data/notifications.json` **deleted** from §3.1 and from §8 → doc 08 owns push policy, doc 13 owns the platform. §2.13 replaced the old two-way split with the three-layer ownership table. The in-app constants moved into `data/ui.json` under **`in_app_alerts`** (P1 6/h, P2 3/h, P3 1/h, `global_max_per_hour 3` over P2+P3 only, 600 s per-type cooldown, 300 s P1 coalesce, `consults_quiet_hours: false`, `may_emit_push: false`); `NotificationGate` → `InAppAlertGate`; save key `notif_buckets` → `in_app_buckets`; push preferences left the `ui` save section; test 17 renamed and rewritten to assert the two budget systems never touch. |
| **G-8** | This doc now owns **`data/strings.en.json`** — §3.1 specifies the two key families (`ui_<screen>_<element>`, `n_<event>_title` / `n_<event>_body` on doc 08's event ids), the `{named}`-placeholder rule, the `Str.t()` lookup with missing-key-is-a-test-failure, and English-only MVP; §8 ships the file with all 13 requirement templates; new test 21 lints key coverage and forbids literal display strings under `ui/`. |
| *(consequential)* | C-41 recorded in §2.7 (player-drawn paths with a `Route along roads` assist) and §9 OQ4 closed; C-69 and G-2 recorded in §9 conflicts 6 and 5; doc 09's `city_stability ∈ [0,1]` display conversion stated once in the §2.4 chip row (C-56); §2.3's thumb-reach distances recomputed from the stated rects (Jump-to-worst 17.0 → **22.6**, Overlay 84.9 → **85.5**, Speed 148.6 → **148.9**) — all still inside their zones, so no layout moved. |

---

## Phase-1 implementation deltas (UI completeness pass)

Everything below is **new data or new behaviour shipping in the Phase-1 slice**, recorded here so the doc stays truthful (repo rule: code and doc move together). Nothing above was deleted or renumbered.

| # | Delta | Where | Why |
|---|---|---|---|
| D-1 | **The top bar may wrap to a second row.** `data/ui.json.layout.top_bar_max_rows: 2`. §2.4's demotion phase runs first, unchanged; when everything-compact still overflows, the bar **wraps before it hides**, and P5–P7 drop only once the last row is full. `top_bar_max_rows: 1` restores the single-row solver byte-for-byte. | §2.4, `HudModel.solve_top_bar` | The solver budgets each chip at a fixed width; on the Fold 6 inner display (2160 × 1856 px, ≈1:1 → ~794 × 924 dp) the four never-hidden chips plus a measured value string overflow one 48 dp row, and A1/A2 forbid clipping. A wrapped chip is readable; a hidden one is gone. |
| D-2 | **Measured widths feed the solver.** `solve_top_bar(w, clock_w, min_widths, max_rows)` takes `{chip_id: {full, compact}}` measured by the view against the live Theme; a chip's effective width is `max(doc budget, measured)`. | §2.4 | `Moderate 68 ▲` measures 123 dp against a 112 dp budget, so the stability chip clipped at every width. The budget is now a floor, not a ceiling, and a text-scale change re-measures for free (A2). |
| D-3 | **The clock chip's budget includes the pause-menu button.** The top bar gained a 48 dp `☰` at its right end — the pause menu's entry point, in the "rare" reach zone of §2.3 — so `avail = W − (clock_w + menu_w + gap) − 16`. | §2.3, §2.4 | A single-scene game still needs one always-reachable, never-time-critical way into pause / save / settings / quit. |
| D-4 | **`overlay.enabled_modes`** lists the overlays whose sim has landed (`["none", "power"]` today). A listed-but-disabled overlay renders greyed with `ui_overlay_disabled` instead of disappearing (A14). `overlay.shader_global: "sc_overlay_mode"`, and the value written is the mode's **index into `overlay.modes`** (none 0 … traffic 5). | §2.5 | The console must not change shape as docs 05/06/10 arrive, and doc 11 needs one stated wire format for the global. The per-instance 2-bit `overlay_state` stays doc 11's and is never written from `ui/` (C-64). |
| D-5 | **`data/ui.json.alerts`** — the alerts-centre feed: `max_entries`, chip/panel/row sizes, and an ordered `events` rule list mapping a sim-bus event (with an optional `match` block) to `{notify_id, class, state, key, coalesce_by, args}`. Copy resolves from `n_<notify_id>_title` / `_body`. | §2.15, §4.5 | doc 08's `data/notifications.json` event→class map does not exist yet; this block is an explicit **stand-in to be replaced wholesale, never merged** (stated in its own comment). Class and surface budgets still come from `in_app_alerts` (C-71/C-72). |
| D-6 | **A body sentence whose data the sim did not supply is dropped**, never rendered with a `{placeholder}` in it. | §3.1 | `n_outage_major_body` names responding crews; doc 06 is not in the slice. Dropping the sentence keeps the doc's copy intact and the screen honest. |
| D-7 | **`data/ui.json.settings`** — S9's rows as data (`kind`, `options`/`options_from`, `default`/`default_from`). `options_from: "render_presets"` resolves against doc 11's `data/render.json.presets`, ordered cheapest-first by `render_scale`. Each row is one 48 dp target that cycles its value. | §2.13 | The graphics list can then never name a preset the renderer does not have, and a phone gets buttons rather than dropdowns (A3). Phase-1 pages only: Graphics, Autosave, Sound (placeholder), the two accessibility switches, In-app banners, Text size, About. |
| D-8 | **`data/ui.json.save_slots`** (`count`, `row_h_dp`, `autosave_slot`) and **`pause_menu`** (`actions`, `button_w_dp`). Save/load talks to `game/save_service.gd` **duck-typed** (`save_slot`/`load_slot`/`list_slots`/`delete_slot`/`autosave`), and every destructive action — overwrite, load, delete — passes a confirmation; saving into an empty slot does not. | new §2.2 surfaces | `ui/` must not depend on a `game/` type, and nothing that can destroy a city may happen on one tap. QUIT is emitted as an intent ("save, then close") — a view never calls `get_tree().quit()`. |
| D-9 | **`ui` save section, partial.** `UIRoot.capture_ui_state()` / `restore_ui_state()` carry `section_version`, `overlay`, `overlay_last` and `settings` today; camera, selection, drawer and onboarding keys join them as those systems land. A restore routes through the same enabled/validation gates, so a save cannot resurrect an overlay whose system was pulled, or a settings value that no longer exists. | §3.2 | C-25's section versioning and §3.2's migration policy ("unknown keys dropped, missing keys default"). |

### Wave-4 UX sweep deltas

Found by walking every screen at 360 / 412 / 794 / 880 dp and at 130 % text — the suite had only ever measured the 880 dp reference box, and every screen fits at 880 dp. `tools/ui_preview.gd --audit` is the pass that finds these; `tests/test_ui_audit.gd` and `tests/test_ui_strings.gd` are the gates that keep them fixed.

| # | Delta | Where | Why |
|---|---|---|---|
| D-10 | **Plural forms.** A template may carry a `<key>_one` variant, chosen when its count argument is exactly 1; the count is the template's only numeric placeholder, or the argument named by a sibling `<key>_plural` entry. `UIConfig.t()` applies it; `tests/test_ui_strings.gd` holds the file to it. | §3.1 | §3.1's own worked defect, `1 blocks are dark`. English needs two forms and no more, so the base key stays the plural (0 and 2+ take it) and exactly one variant exists. |
| D-11 | **Nothing in `ui/` clips its own text by default.** `UIWidgets.button()` / `label()` leave `clip_text` off; `UIWidgets.elide(control, floor_dp)` is the explicit opt-in and always supplies a minimum width. | §4.3, A1/A2 | Godot reports a minimum width of **0** for a clipping `Button` and **1 px** for a clipping `Label` — clipping is a promise that the copy needs no room. Beside an `EXPAND_FILL` sibling those controls were not shortened, they were erased: the dashboard's axis figures and the economy tab's totals were laid out one pixel wide, and `GOT IT` rendered as `GOT I` because its 48 dp *touch* floor was narrower than its label. |
| D-12 | **The clock chip and the ☰ button live inside top-bar row 0**, not beside the whole chip column. | §2.4, D-1/D-3 | `_pack_rows` is written against "row 0 shares its line with the clock; wrapped rows span the bar", and the scene could not express it — the chip column's width was its *widest* row, so a second row solved against the full bar made the bar ~200 dp wider than a 412 dp phone. `grow_horizontal = BOTH` then centred the overflow and pushed the ☰ — the only way into pause / save / settings — off the right edge. |
| D-13 | **`chip_never_hidden_count` yields to A1/A3.** When even one row cannot hold P1–P4 plus the clock column, `solve_top_bar` keeps hiding below the floor (down to the treasury chip) rather than overflowing. | §2.4 | At 130 % text with larger touch targets on a 360 dp phone, four chips plus the clock physically do not fit. A chip pushed off the display is hidden *and* has taken the ☰ with it; a hidden chip is one tap away in the dashboard (§2.10). |
| D-14 | **The build sheet's category row scrolls horizontally** (a `TabScroll` built in code), with the ✕ pinned outside it. | §2.7 | Six categories plus GRID at 96 dp is a 768 dp row. The sheet's minimum became the row's, the sheet grew wider than the display and centred, and `Residential`, `Grid` and the ✕ went off screen — GRID being where §2.17 step 6 sends the player. |
| D-15 | **A right-edge panel takes the whole display when the strip beside it would be too thin to use.** `UIWidgets.side_panel_width(host, content, ratio, min, max, gutter)`, applied by the drawer, the alerts feed and the building panel. | §2.1, §2.6 | `clamp(0.34·W, 260, 340)` on a 412 dp phone leaves a 48 dp ribbon of half-drawn HUD chips down the left edge, which reads as a rendering fault. The formula also has to lose to the panel's own contents — four sort segments reading `Priority \| Nearest \| Newest \| Unassigned` need the width those words need. |
| D-16 | **Edge affordances yield their edge.** The BUILD FAB hides while the build sheet, the placement bar or the unit picker is up; the alerts chip and the drawer handle hide while any other surface on `PanelLayer` is open. | §2.2, §2.6 | Each pair shares a corner and the same layer, so neither was occluded — they collided, with overlapping tap targets. `UIWidgets.close_siblings()` already guarantees one *surface* at a time; this extends it to the affordances. |
| D-17 | **Three rows re-flow to two lines**: the unit picker's row (name + ETA / status + tag), the save slot's row (description / SAVE · LOAD · DELETE), and the placement bar's copy (summary / verdict). | §2.6, §2.7 | Four columns on a 412 dp phone gave the unit's own name 47 px of a 73 px word, the slot's name 18 px, and the placement verdict 49 px of a sentence. Every one of those is the thing the row exists to say. |
| D-18 | **One money convention per surface.** `HudModel.money_exact()` / `money_signed()` group every digit for a **column** of figures; `money()`'s three-significant-digit ladder stays for fixed-width chips. `percent_text()` is the single percentage formatter (U+2212 on a negative, `—` for no reading). The economy tab's total line is the settled **hour**, like the lines above it. | §2.4, §2.10 | The ledger printed `$12.5K` directly above `$4,120`, and the total line mixed a per-hour gross with a per-day net. The chart axis printed `-3%` with an ASCII hyphen under a `−$1.2M` with the real minus sign. |
| D-19 | **`UIRoot.safe_area_override` and `UIRoot.force_layout(box)`** — a device box for a harness or a test, and one synchronous layout pass. Never used by the game. | §2.1 | A desktop display server answers `get_display_safe_area()` with the screen's work area, which shifted every measured rectangle by the width of the developer's dock; and a headless run (`tests/run_tests.gd` does everything inside `_initialize()`) never flushes a `Container`'s queued sort, so every laid-out size is zero. |

### Wave-6 deltas — S4, the auto-response rows, haptics, the level-up moment

The four rows doc 91 §15 ranked 5 and 16. Every one of them was a subsystem that
was fully built and had no surface; none of them needed a line of new
simulation.

| # | Delta | Where | Why |
|---|---|---|---|
| D-20 | **S4 ships** (§2.8): `ui/land_panel.gd` on `PanelLayer` + `ui/land_panel_model.gd` headless behind it, entered from `BuildController.pick_at_ground()`. The panel is the doc's flow verbatim — price, risks, advantages, buildable tiles, `PURCHASE`, then `DEVELOP`, then the six-step progress list with a live bar, a crew and an ETA. | §2.8, §2.2 | Doc 91 D-5: `cmd_buy_block` / `cmd_start_development` were built and tested and reachable from nowhere, so the city could not grow past its founding blocks by any player action. |
| D-21 | **The tap seam resolves land, not just buildings.** `BuildController.pick_at_ground(point)` returns `{kind: building\|block\|none, id, tile, block}`; a miss that lands in a block S4 has something to offer for yields that block. Buildings still win, and owned-and-developed ground still deselects. | §2.8, §2.16 | The old seam was `sim_id_at_ground()` and `""` meant "deselect", which is the mechanical reason land was untouchable: the one screen that could sell it had no way to open. |
| D-22 | **§2.8's `advantages` are derived, not authored.** Each row re-prices the block with one `land_price_inputs` term neutralised and reports the difference, so `Waterfront +18 %` is the price function's own answer and a retune of `data/economy.json` moves the panel the same hour. `data/ui.json.land` owns only which risks get a row, the five bands, the glyphs and the 1 % noise floor. | §2.8, §3.1 | Doc 03 owns the coefficients; a second copy in `ui/` would drift on the first balance pass. |
| D-23 | **§2.13's auto-response rows ship** as seven `data/ui.json.settings.rows` entries carrying `policy: "dispatch"`. Their defaults resolve from **doc 06's** `data/dispatch.json.policy_defaults` (`UIConfig.dispatch_data()`), their values go to `CitySim.cmd_set_dispatch_policy` through `UIRoot.bind_dispatch_policy(command, values)`, and the live sim seeds the rows — a restored `ui.settings` block can never overwrite the city's own policy. | §2.13, doc 91 D-11 | `DispatchPolicy` had no UI at all, so `auto_dispatch_*` was stuck at whatever the file booted with. The utility restoration **order** is still absent: it is a drag-reorder list, not a 48 dp cycling target. |
| D-24 | **§2.14 haptics ship**, routed through one `ui/haptics.gd`. Seven cues, three levels, durations read from `data/ui.json.haptics_ms`; `UIRoot` owns the single instance and the two settings rows reach it directly. **`reduce_motion` suppresses haptics** (A8 — a vibration is motion) *without* changing the `haptics` row, so switching it back off restores the player's choice. The `escalate` pattern is one pulse: `Input.vibrate_handheld` takes a duration and no pattern. | §2.14, §2.18 | `data/ui.json` carried the table and nothing in `ui/` or `game/` called a vibrator. One gate rather than seven call sites is what makes the accessibility rule enforceable. |
| D-25 | **The toast surface exists.** `ui/toast_view.gd` on the scaffold's `ToastLayer`, 320 × 40 dp bottom-centre, `toast_ttl_s`, newest replaces, `MOUSE_FILTER_IGNORE`. `CityHUD.toast_requested` carries the §2.13 gate's degraded banners to it. | §2.15, §2.13 | The in-app gate had *budgeted* toasts since Wave 2 and `active_toast()` was read by nothing but a test — a degraded alert was measured and then shown to nobody. |
| D-26 | **The city-level moment** (§2.13's payoff): `UIRoot.feed_events` watches `city_level_changed`, raises the toast, and calls `BuildSheet.reveal_unlocked(level)` — the cards whose `min_city_level` is exactly that level pulse once (`layout.unlock_pulse_s`), and the sheet switches to their category. Held while the sheet is closed and spent on the next open. Guarded on the level, so a replayed batch or a reload cannot celebrate twice; suppressed under `reduce_motion`, where the toast alone does the work. | §2.13, §2.15 | The event landed as one alert row among twenty: a progression ladder whose reward was invisible on the thing that was rewarded. |
| D-27 | **`PanelLayer` is enforced, not merely observed.** `BuildingPanel.show_building` now calls `UIWidgets.close_siblings()` like every other surface on that layer. | §2.2, D-16 | Two 300 dp panels on the same layer and the same right edge do not occlude — they collide, and so do their tap targets. |

**Still open against this doc** *(updated Wave 6, 2026-08-19)*: §2.10's condition histogram is not built; the Response tab's auto-response editor is not on the *tab* — the seven policies ship as S9 rows instead (Wave-6 D-23), and the utility restoration **order** is still absent because it is a drag-reorder list rather than a cycling target; S10's notification rows are still doc 08's and doc 13's to land; §2.5's POLICE and FIRE rows draw the per-BUILDING coverage state, not yet the coverage discs, unit dots or heat bins. Closed since the Wave-3 note: the overlay legend is now the separate top-left `OverlayLegend` card (`ui/overlay_legend.gd`) and the strip carries only chips and its refusal notice; S13 (event log) shipped in Wave 4; the dashboard ships all four tabs, Infrastructure reading `PowerGrid.feeder_rows/transformer_rows/capacity_summary` and doc 05's §5.8 zones, Response reading doc 06's roster plus `DispatchSystem.stats`; POLICE and FIRE are live on doc 02 §2.9's coverage field (C-51), so `overlay.enabled_modes` now lists all six. **S0 shipped in Wave 7** (`ui/title_screen.gd` + `ui/title_model.gd` on `SafeArea/TitleLayer`, between `SheetLayer` and `ModalLayer` so the door covers the deck and a modal covers the door): the game name over the launcher icon's own skyline, CONTINUE carrying the newest save's day / population / treasury, NEW CITY with the slot confirmation doc 93 §E2 rules, and SETTINGS opening S9 over the title. The back stack takes a `title_open` context rather than a new rung — at the front door there is no city, so the sheet / panel / placement / selection rungs cannot exist and back is the two-press minimise pair. Also shipped earlier: `sc_overlay_mode` is read by the building shader (Wave 2), S6 incident drawer, S7 unit picker, S8 dashboard, S11 away report, and S12 onboarding (Wave 2–3).

**One §2.5 colour correction, Wave 5.** `building.gdshader` shipped OFFLINE as a dark red (`#66120E`), which is not the `#5A6270` this section's state table publishes and reads as an emergency where the honest meaning is "nothing reaches here". The four building-overlay hues are now resolved from `data/ui.json.overlay.building_state_paint` against the **same** `palette[variant]` the legend rows are painted from (`OverlayModel.building_state_paint`, applied by `CityView.set_overlay_palette`), which also closes the A6 gap where a colourblind player got a colourblind legend beside a trichromat city — the road bands already followed the palette and the buildings did not. NORMAL still deliberately borrows `text_dim` rather than the legend's green: a city where every healthy building glows is a city where nothing reads.

### Wave-10 deltas — the run tools and the actions row (2026-08-20)

Doc 92 §17.6 and doc 93 §G2 recorded three shipped, tested sim verbs with **no
player surface**: `cmd_place_road`, `cmd_place_water_main` and
`cmd_repair_building`. Auditing the same seam turned up three more —
`cmd_upgrade_road`, `cmd_demolish_road`, `cmd_set_priority` and
`cmd_demolish_building` — so this wave closes §2.7's *drag-path* half and §2.9's
*item 6* whole. Nothing here needed a line of new simulation.

| # | Delta | Where | Why |
|---|---|---|---|
| D-28 | **§2.7's drag-path placement ships.** `ui/path_tool.gd` (headless, `RefCounted`) owns a second placement state machine — `enter → aim → begin_run → draw → commit` — beside `BuildController`'s footprint one. `ui/build_sheet.gd` merges both rosters into one card list and routes a card tap to whichever tool owns it; `is_placing()` answers for both, so the shell asks one question. The run geometry is the doc's own: **L-shaped, Manhattan, longest leg first**, ties to X. | §2.7 | Roads and mains are runs, not footprints: doc 10 §2.13 and doc 05 §6 both take a tile LIST and bill per tile, and a footprint ghost cannot express that. |
| D-29 | **The ROADS tab exists**, carrying `Street`, `Avenue`, `Widen` (STREET→AVENUE) and `Remove`; the two water-main tiers sit on `Utility`/`infrastructure` beside the pumps they feed, exactly as §2.7's card table files them. A run card quotes a **per-tile** price (`$1,800/tile`), because a run has no total until the player has drawn one. | §2.7 | The doc's own tab list names `Roads`; `BuildController.CATEGORY_ORDER` gained it last, for the same reason `infrastructure` is late — it is the tab you go to once something else has said `NO_ROAD` / `E_AVENUE` / `E_NOT_CONNECTED`. |
| D-30 | **The bar's primary button is two-step on a run tool**: `START` pins the anchor, `PLACE` lays the run, and the tool re-arms to AIMING after a commit so a grid is several sweeps and not several trips to the sheet. The **left** button carries the third verb rather than the bar growing a fourth control: while a run is being drawn it reads `↺` and unpins the anchor; everywhere else it is `CANCEL`. | §2.7, A1/A2 | A ghost move arrives identically from a tap and from a desktop hover, so a move may never pin a start tile. And four controls measure 139 + 73 + 73 + 119 = **404 dp** on a 360 dp display at 130 % text with larger targets — `--audit --strict` put CANCEL 43 dp off the left edge and PLACE 44 dp off the right. Three measure 265 dp. |
| D-31 | **Drag-to-draw is the accelerator, not the mechanism.** `game/touch_input.gd` gained a `world_drag_router`: a single-finger stroke is offered to the shell before it becomes a camera pan, anchored on the recognizer's **finger-down** point (§2.16), and the run stays on finger-up because §2.7's "placement is never committed on finger-up" holds for runs too. Two fingers are never routed — pinch and twist stay the camera's, so a player can frame the shot they are drawing into. | §2.7, §2.16 | The tap flow works with no shell change at all; the drag is two lines of wiring on top and degrades to the tap flow when it is absent. |
| D-32 | **The run ghost dims what it is not being billed for.** `game/ui/path_ghost_view.gd` is one MultiMesh bucket of flat tile slabs, tinted by §2.7's verdict ladder, with the anchor tile drawn taller and every tile the command will pass over at 32 % alpha. | §2.7, doc 11 §2.4 | Doc 10 §2.13 keeps build, upgrade and demolish as three verbs and each ignores what the other two own — a build sweep across three tiles of existing street is billed for five of the eight the thumb crossed, and the player has to see that before they commit. |
| D-33 | **§2.9 item 6 ships**: `Repair` (cost + the condition it will restore to), `Priority` (doc 04 §2.4's four shed tiers as a segmented row), `Demolish` (hold-to-confirm, `layout.hold_to_confirm_ms` = 800, `DangerButton`, quoting the refund and any construction job it will cancel). All three ask their command with `preview = true` and shape the answer; none of them holds a rule. | §2.9 | Three shipped verbs whose only door was a scripted agent. The repair one is the loop the whole maintenance economy hangs off. |
| D-34 | **The repair threshold moves from "condition < 90 %" to "any damage".** The row is drawn whenever `cmd_repair_building(preview)` has a price to quote and hidden when it answers `E_NOT_DAMAGED`. | §2.9 item 6 | Doc 02's upgrade gate is `MIN_CONDITION_TO_UPGRADE`, and a player held at 85 % by that gate must be able to answer it — an affordance that hid above 90 % would hide exactly when the checklist starts asking for it. |
| D-35 | **`E_CONDITION`'s `Fix this →` buys the repair.** `RequirementFormatter.FIX_REPAIR` is a fix kind whose answer is a purchase rather than a place, and `BuildingPanel` performs it in place instead of emitting it to the camera router. | §2.7, §2.9 | Every other fix kind answers *where do I go?*; this one answers *what do I buy?* Its target was the building the player already had open, so the affordance focused the camera on the thing under their thumb and did nothing. |
| D-36 | **Wear is visible on the building.** `RenderStateModel` derives `damage` from `condition` when a view or an event omits it, and takes a `{render_id: condition}` feed (`ingest_conditions`). | §2.9, doc 11 §2.10 | Doc 02 §2.6 decays condition continuously and fires exactly ONE event, at the auto-damage threshold, carrying `{building, cause}` and no numbers — so `building.gdshader`'s soot ramp and its `damage_dim_gain` were dead channels and "which building needs a repair?" had no answer in the world. |

**Preview states added** (`tools/ui_preview.gd`): `build_roads`, `path_aiming`,
`path_ok`, `path_blocked`, `path_refund`, `building_repairable`. All six are
clean under `--audit --strict` at 360×800, 412×915, 794×924, 880×400 and
1280×720, and carry no finding of their own at 130 % text with larger targets.
