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
| S15 | **Loading veil** | `LoadingVeil` | full, own `VeilLayer` **above everything** | a stepped restore or an offline catch-up (shell calls `UIRoot.present_veil_load()`) | the shell, when the slicer is done |
| S16 | **Construction queue** | `ConstructionQueueSheet` | side panel 320 dp on `PanelLayer`, plus a corner-rail chip that exists only while something is building | the `⚒ n` chip — rung 3 of the bottom-right rail (§2.3, §2.22) | ✕ / back / a sibling panel opening |

**S0 carries a fourth control, and it is not a door** (2026-08-20, doc 03 §2.9,
doc 93 §K1). Directly under NEW CITY sits a 48 dp chip that cycles the four
difficulty presets and wraps — `New city: Standard` → `Hard` → `Crisis` →
`Casual` — with the line *"A city keeps the difficulty it was founded on."*
beneath it. It rides `new_game_requested(slot, difficulty)` and
`UIRoot.title_new_game(slot, difficulty)` to `CitySim.found_with_difficulty()`.

**Why it is on the door and not inside the NEW CITY confirmation.** A first
launch has nothing to confirm — this screen map starts that city immediately, and
`tests/test_ui_title.gd::test_a_first_launch_starts_without_a_question` holds it
to that — so a chip behind the confirm panel would be invisible to precisely the
player who has never chosen a difficulty. The confirmation still *reads it back*
(`Founded on Crisis.`) before the choice becomes permanent, which is the last
moment it can be undone. The chip is visible while CONTINUE is too, and the copy
answers that by naming what it is for ("New city: …") rather than by hiding.

**S15 is a veil and not a screen, and the difference is that it has no targets
at all.** Every other surface in this map ends in a `Button`; this one is a
scrim, a card, two labels and a bar. That is a requirement rather than a
simplification: doc 08 §2.15.2's contract for a stepped restore is that nothing
may tick, render against or query the sim between steps, and a control the
player could press during a half-restored city is precisely the thing that
breaks it. Its scrim swallows input and offers none, and Back does not reach it
— there is nothing to go back to while the city is half in memory. See §2.20.

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
| Alerts chip | (W−128, H−140, 72, 48) — rung 1 of the corner rail (D-37) | frequent |
| Event-log chip | (W−128, H−196, 72, 48) — rung 2 of the corner rail (D-37) | occasional |
| Queue chip `⚒ n` | (W−128, H−252, 72, 48) — rung 3 of the corner rail, **present only while something is building** (§2.22, D-66); wraps into a second column when the rail runs out of height (D-67) | rare — centre `(W−92, H−228)`, `d = √(64²+200²) = 210` from `PR`, edge-anchored; the verb it leads to is also on S5, one tap from the building itself |
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

**The solver has a SECOND axis, and it is why D-1's wrap is safe on a short
display** *(Wave 12, doc 91 A91-D-23)*. The algorithm above solves width and has
no opinion about how tall its answer is. At 880 × 400 dp — this document's own
reference box — with 130 % text and larger touch targets a chip measures
**100 dp**, two rows plus their separation is **208**, and the bar ran from
y 4 to y 212 of a 392 dp safe area, straight through the top slot of §2.3's left
rail at y 89. That is **156 `overlapping_targets` findings across the whole
deck**, every state, at one box.

So `solve_top_bar` takes a height budget and a row height and reserves
`row_h` per wrapped row:

```
rows_fit  = max(1, floor((budget + gap) / (row_h + gap)))     # never zero
max_rows  = min(layout.top_bar_max_rows, rows_fit)
```

and everything the rows can no longer hold goes down §2.4's existing ladder —
demote, then hide, then the D-13b floors. A budget of `< 0` is *unbounded* and
reproduces the solver above exactly, which is what every model-level test asks
for. The view's budget is the room above the rail: `H − rail_reserve − 8`, where
`rail_reserve` is `UIWidgets.rail_slot()`'s own arithmetic for the highest of
§2.3's three slots.

**And the bar yields the rail's COLUMN when even one row will not clear it.**
The budget alone cannot save that box, because the arithmetic has no answer:
`100 (one row) + 8 + 12 (rail margin) + 3 × 93 (rail slots) + 2 × 8 (rail gaps)`
= **407 dp against 392 of safe area**. One of the two has to move. It is the bar:
§2.3 classes the rail's three controls *frequent* and *occasional* and pins them
to the thumb, while the top bar is *rare*, edge-anchored, and merely has to be
legible. So `HudModel.top_bar_left_inset()` steps the whole bar right of the rail
column — `rail_column_w + 8`, **113 dp** at that box — whenever
`row_h + 8 > rail_top`. It returns **0 at every supported box at 100 %**, so the
reference layout does not move, and doc 12 test 10's *"W = 880 keeps all chips
FULL"* is asserted against the vertical solve as well as the horizontal one.

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

**The unit chips ship in Wave 12, with two deviations and a reason for each** *(doc 91 A91-D-24 — `cmd_recall_unit` had no caller anywhere in the repository)*. They are **48 dp**, not 24, because A3 outranks a dimension; and they live in the actions row **beside** ASSIGN rather than replacing it, because a `Button` inside a `Button` cannot be hit (which is why the actions row is below the 72 dp band at all) and because sending a *second* unit to a fire that already has one is a verb doc 06 supports and a player wants. A chip exists exactly when doc 06 §2.11 allows a recall and needs no second query to know it: a row's `assigned` list *is* the sim's `inc.assigned` map, which only ever holds units that were dispatched and not yet released. The sim still rules — the chip stands down on tap, `CitySim.cmd_recall_unit` answers, and a refusal comes back as §2.7's formatter sentence in a toast (A14). The actions row became an `HFlowContainer` in the same change, for D-47's reason one screen over — with one difference worth stating, because it changes the reference box: the drawer is `clamp(0.34·W, 260, 340)` dp **whatever the display is**, so there is no width at which the sum fits. At 100 % a water row's four controls already measure 348 dp against a 300 dp panel, and `_apply_panel_width` answered that by *widening the drawer*. The row now wraps downward instead, which is the axis the drawer already scrolls on, and the drawer keeps the width this section gives it.

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
| Utility | Power Line | `place_path{kind:"power_line"}` | drag-path, §2.7 below. **Shipped Wave 11 as TWO cards** — `Feeder` and `Heavy Feeder`, one per conductor class doc 04 §6 offers — reaching `cmd_route_feeder`. A class is a capacity (1,200 / 3,000 kW) and a price ($110 / $210 per tile), which is a choice, and §2.7 has no control for a per-card enum: two rows, exactly as `Street`/`Avenue` and `Water Main`/`Trunk Main` spell the same shape. |
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

- *Gameplay:* ~~difficulty (Casual/Standard/Hard, spec §35 — changing mid-city warns and is one-way downward)~~ **difficulty is READ-ONLY here (2026-08-20, doc 93 §K1)**, `auto_speed_reset_on_critical`, camera rotation mode (`free / snap45 / snap90 / locked`, default `snap45`), invert pan (off), follow dispatched unit (on), confirm before demolish (on).

> **The difficulty row is a sentence, not a control.** Doc 03 §2.9 authors four
> presets (Casual / Standard / Hard / **Crisis** — this row said three); doc 93
> §K1 rules that a city is FOUNDED on one and keeps it for life, so there is no
> `cmd_set_difficulty` for a control to write to. S9 therefore renders a **city
> block** above About — `SettingsModel.city_rows()`, one read-only line, *"Difficulty:
> Standard — set when this city was founded."* — fed by `UIRoot.set_city_difficulty()`
> from `CitySim.difficulty_preset()`. It has no `key`, no row in
> `data/ui.json.settings.rows`, no default and no `set_value` path, because it is a
> property of the CITY and not a preference of the app. It is absent entirely
> until a city is bound, since S9 can be opened over the title door. The choice
> lives on S0 — see §2.2.
- *Auto-response policies* (spec §21.3) live on the Response dashboard tab and are mirrored here: auto-dispatch nearest fire unit (on), auto-dispatch police for tier ≥ T3 (on), utility restoration priority list (drag-reorder: Hospital → Water → Fire station → Residential → Commercial → Industrial), reserve N fire engines (default 1), auto-repair cost ceiling (default $25,000, slider $0–$250K), never spend emergency contractor funds (on).
- *Automatic road repair* (doc 10 §2.13, doc 93 §J3 — **Wave 12**): `Repair roads below` (condition threshold) and `Road repair budget` (daily cap). Two rows, one `policy: "roads"` family, and the mechanism is the dispatch family's with **one** difference that belongs to the command rather than to this screen: `RoadNetwork.cmd_set_auto_repair_policy(threshold, daily_cap)` takes the pair, so a change to either row writes both. The threshold row's ladder is doc 10's own `auto_repair_thresholds`, read through `UIConfig.road_condition()` — a control may not offer a rung whose command answers `E_BAD_THRESHOLD`. Both bottom rungs are STATES rather than quantities (`Never`, `No budget`), which is what the new row field `zero_key` is for: `$0` and `0 %` are both true and neither says *switched off*. This is the only player say over road condition, because doc 93 §J3 rules the per-tile repair verb the policy's job.

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

**A2 and A3 are swept together for the first time at 2026-08-20, at more than one
box and on both axes, and they fail (doc 91 §19).** The instrument is the one this section
already implies: `tools/ui_preview.gd --screen=all --audit --strict` over all 49
named states, at the five device boxes `tests/test_ui_audit.gd` already knows —
360×800, 412×915, 794×924, 880×400, 1280×720 — and then at a sixth this document
names and nothing tests (see below). (Those 49 cover fourteen of §2.2's fifteen
screens: **S13's panel has no preview state**, doc 91 A91-D-28.) At **100 % text
and default targets it is clean at all five** — 245 state-sweeps, zero findings,
exit 0 five times, which also closes doc 91's D-12 and D-13. Re-run at **`--text-scale=1.3
--large-targets`** it **exits 1 at every box**, with three distinct causes:

| Cause | Boxes | Scale of it | Filed |
|---|---|---|---|
| The right-edge chip column does not re-flow: `AlertsCenter/Chip`, `EventLog/Chip` and `IncidentDrawer/Handle` overlap each other once A3 inflates them to 89 × 100 px | **all five** | 36 of 49 states, 73 findings per box | A91-D-21 — **fixed by D-46** |
| Controls land **outside the viewport** — `SettingsSheet/…/Close "✕"` and `SaveLoadSheet/…/Close "✕"` at 360×800, `PauseMenu/…/SAVE & QUIT` and `TitleScreen/…/START NEW` at 880×400 | 360×800, 880×400 | 9 findings | A91-D-22 — **fixed by D-47 (the sheets) and D-52 (the two centred cards)** |
| The HUD top bar does not yield to the rails: `LeftRail/SpeedButton` and `OverlayRail/Button` over `TopBar/Chips/Row` | 880×400 — §2.3's own reference box — and worse at 640×340 | **all 49 states**, 147 findings | A91-D-23 — **fixed by D-51** |

**All three are closed as of Wave 12** and the sweep is zero findings at all five
boxes on both settings; the numbers above are kept as the filing, not as a
current state. ~~The paragraph below about 640 × 340 still stands — that box is
A91-D-29 and nothing has measured it since.~~ **A91-D-29 is closed as of Wave 13
(D-54 … D-58): 640 × 340 is a row of `tests/test_ui_audit.gd::BOXES`, and the
sweep is 55 states × six boxes × three text scales — 990 state-sweeps — at zero
findings.** See the table at the end of this section.

**Wave 13 found the cause under all of it, and it is one line** (D-54).
`ThemeBuilder.build()` sized a button's vertical content margins from a touch
minimum that was *already* multiplied by the text scale, and then handed the
finished theme to `scale_theme()`, which multiplies every content margin again.
So a `StatChip` at 130 % with larger touch targets measured **100 dp against an
A3 floor of 73** — a 37 % overshoot on every themed button in the deck, on both
axes, compounding at 150 % to 32 dp of pure surplus per control. Every A2/A3
defect this section has ever filed is that number arriving somewhere it did not
fit: the chips that measured 89 × 100 in the first row of the table above, the
94 dp drawer handle, the 407-against-392 top-bar arithmetic of D-51. The three
fixes those numbers bought are all still correct and all still shipped — a
solved rail is better than an authored one at any scale — but they were solving
for a control that should never have been that size. Building the base theme at
1.0 and letting the scaler scale it exactly once is a **no-op at 100 %** (the
two figures agree there, which is why the reference layout does not move) and
takes the whole-deck finding count from **408 to 8** before any other change in
this wave.

The second row is the one that matters most for A3 specifically: **a player who
turns large touch targets on, on a 360 dp phone, cannot close the settings sheet
with its button** (Android Back still works, which is the only reason it is not a
hard lock), and a new player on a folded Fold cannot press START NEW.

**The gate exists and is the wrong shape.** The suite is not blind to A2:
`tests/test_ui_audit.gd::test_every_surface_fits_the_narrowest_display_at_130_percent_text`
mounts the deck at `(1.3, true)` and asserts
`get_combined_minimum_size().x <= 360.0` over the `SURFACES` list. That is **one
axis, one box, and full-width panels only** — and every failure above is an
overlap or a Y-axis overflow, which a width check on one display cannot express.
Widening it to loop `BOXES` (plus 640 × 340) and to carry `UIAudit`'s overlap and
offscreen checks is ranked first-equal in doc 91 §20.2.

~~**A2's own geometry — 640 × 340 dp — is `data/ui.json.layout.min_safe_box_dp`,
this document's declared floor, and it is in no `BOXES` list in this
repository.**~~ **It is a row of `BOXES` as of Wave 13** (D-58), added in the
same commit as the layout fixes, which is what the filing asked for. The
first-measurement figures, kept as the filing:

* ~~**At 100 %** the box is *not* clean:
  `TitleLayer/TitleScreen/…/Confirm_cancel "CANCEL"` lays out at y 318.5 with
  height 96 against a 340-tall viewport — **26 dp off the bottom, at default text
  scale.**~~ **Closed by D-52** (the centred card scrolls and is capped), and
  re-measured at Wave 13's fork: 100 % is clean at 640 × 340 with 0 findings
  across all 53 states before this wave changed anything. The 96 dp CANCEL was
  the double-scale (D-54); at the same box and scale it is **73 dp** now.
* ~~**At 150 % + `larger_touch_targets`** — **all 49 states are dirty**, with 228
  overlaps and **72 offscreen** findings. `HUDLayer/LeftRail/SpeedButton` lays out
  at **y −70 … 56 against a 340-tall box in every state.**~~ Re-measured at Wave
  13's fork the same arm is **209 findings across 53 states**; D-54 alone takes it
  to **2**, and D-55 takes it to **0**. `SpeedButton` is 84 × 84 at that box and
  scale, in its slot, with 8 dp of clear air above the overlay button (D-59).
  A10's "pause + 1× / 2× / 3× in ≤ 2 taps" is no longer standing on a
  half-clipped target.

**The whole deck, six boxes × three text scales, before → after Wave 13**
(`tools/ui_preview.gd --screen=all --audit --strict`; 53 states per cell at the
fork, 55 after — S15 is two new states):

| box | 100 % | 130 % + larger | 150 % + larger |
|---|---|---|---|
| 360 × 800 | 0 → **0** | 0 → **0** | **25 → 0** |
| 412 × 915 | 0 → **0** | 0 → **0** | **8 → 0** |
| **640 × 340** *(`min_safe_box_dp`)* | 0 → **0** | **3 → 0** | **209 → 0** |
| 794 × 924 (Fold inner) | 0 → **0** | 0 → **0** | 0 → **0** |
| 880 × 400 (reference) | 0 → **0** | 0 → **0** | **162 → 0** |
| 1280 × 720 | 0 → **0** | 0 → **0** | **1 → 0** |

**408 → 0.** The 100 % row does not move by a single finding, which is the check
that says D-54 is a bug fix rather than a redesign. Of the 408, **400 are
D-54's** — the one line. The 8 that survived it are four separate defects, each
of which the double-scale had been hiding behind a bigger number:

| survivor | box · scale | findings | fix |
|---|---|---|---|
| `SettingsSheet/…/Close "✕"` at y −1.5 and `…/Saves "MANAGE SAVES"` 1.5 dp past the bottom — 164 dp of About block sitting OUTSIDE the sheet's own scroller, and a full-rect panel grows through both edges rather than clipping | 640 × 340 · 130 % and 150 % | 4 | **D-55** |
| `LandPanel/…/ActionButton "PURCHASE $12,600"` at x −11 — a two-column `GridContainer` asks for the sum of its columns and the panel is `clamp(0.34·W, 260, 340)` whatever the display is | 360 × 800 · 150 % | 2 | **D-56** |
| `CoachMark/…/Ack "GOT IT"` at x 246 … 364 of a 352 dp safe area — `Skip tutorial` (202 dp) + `GOT IT` (118 dp) in an `HBox` | 360 × 800 · 150 % | 2 | **D-57** |
| *(surfaced by D-57)* the same `Ack` 64 dp below the display once the row wrapped: a flow container's minimum **height** is a function of its width, and the bubble measured itself before its width was decided | 360 × 800 · 150 % | 1 | **D-57** |

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

### 2.20 S15 — the loading veil (Wave 13)

Doc 13 §2.9 has written `veil.show()` in its pseudocode since the section was
drafted, and doc 13 §2.9.1 added a second `veil.show()` in front of it for the
restore. **Both slicers were built and neither had a surface**: `RestoreCursor`
cuts a restore into eleven resumable steps and `CatchUpPlanner.plan()` cuts an
absence into boundary-aligned segments, and what the player saw was the title
door left up on purpose (report 98 §24) — which covers CONTINUE and covers
nothing else. Not a resume, not a slot load from S8, not the catch-up that
follows any of them. Doc 91 §20.2 item 19.

**Entry.** The shell, and only the shell: `UIRoot.present_veil_load(city,
steps)` and `UIRoot.present_veil_catchup(hours, steps)`. Like S0, nothing in
`ui/` raises it, so a headless mount that does not ask does not get one.

> **The catch-up half draws now (Wave 14).** This section shipped against a
> `_on_app_resumed` that spent the whole absence in one synchronous `for` loop,
> so `present_veil_catchup` put a truthful sentence and a truthful bar on screen
> and the player saw **one frame of it**. The shell now steps a `CatchUpCursor`
> (doc 13 §2.9, report 98 §29 RR-73) and calls `advance_veil_catchup()` once per
> frame, so the bar this screen was built for finally moves. **Nothing in `ui/`
> changed** — the model, the copy and the fraction were right; the thing feeding
> them was not. Doc 91 A91-D-31 is closed by that change and this screen is what
> made the defect visible in the first place.

**Presentation.** Its own `VeilLayer`, the last child of the safe area and
therefore above every other layer including the coach marks. A scrim at **0.92**
alpha — heavier than the 0.55 every modal uses, because there is no city behind
this one worth reading — and a centred card:

```
 ┌──────────────────────────────────────────┐
 │              Opening Autosave…           │   the phase, in one sentence
 │  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░             │   the slicer's own index
 │              Step 7 of 11                │   the UNIT, named
 └──────────────────────────────────────────┘
```

Five decisions worth recording:

1. **It has no tap targets, and that is a requirement.** Doc 08 §2.15.2: nothing
   may tick, render against or query the sim between restore steps. A control the
   player could press during a half-restored city is the one thing that breaks
   the guarantee this screen exists to make, so the scrim is `MOUSE_FILTER_STOP`
   and there is nothing else to touch. It is also why S15 costs the A3/A15 tree
   walk exactly nothing: a surface with no `Button` has no floor to miss and no
   accessibility name to forget.
2. **A stepped bar, where doc 13 §2.9.1 asked for a spinner — and the doc's
   argument is honoured rather than overruled.** That section's objection is that
   `cursor.completed() / cursor.step_count()` is "honest about how many steps have
   run and dishonest about how much time is left" (`roads_graph` alone is 37 % of
   the work and one step of eleven). The answer here is to **name the unit**:
   `Step 7 of 11` sits under the bar and the bar means what the line says. A
   spinner would also be the one animation in the deck that A8's `reduce_motion`
   would have to suppress — and a loading screen whose animation has been
   suppressed is indistinguishable from a hung one, which is the failure doc 13
   §2.9.1 is trying to avoid in the first place. A stepped bar has no motion to
   suppress. **Deviation from doc 13 §2.9.1, recorded here and there.**
3. **The catch-up phase is a different sentence and a truthful bar.** `Your city
   ran {hours} hours`, with `ui_veil_catchup_one` for the singular (§3.1's plural
   rule), and here `steps_done / steps_total` *is* proportional to time, which is
   §2.9's own argument. Doc 01's 12-real-hour cap gets a line of its own —
   `ui_veil_catchup_capped` — because A14 says a refusal is stated in words.
4. **A short absence gets no veil; a short load does.** `data/ui.json.veil.
   min_steps` is doc 13's `catchup_veil_min_steps = 5`, and a catch-up beneath it
   is refused (and takes a showing veil down with it, which is the sequence a
   returning player actually produces). A **restore** is never refused however few
   steps it has: doc 13 §2.9.1's own per-step table runs from 0.2 ms to 76.5 ms,
   so "few steps" does not mean "fast", and the one-step cursor
   `SaveService.begin_load_slot()` returns for a legacy file is the slowest load
   in the project rather than the quickest.
5. **The city has a name because the shell supplies one.** `ui/` has no slot list
   and `sim/` has no name for a city, so the shell passes S8's own slot title
   (`Autosave`, `Slot 2`) and an unnamed load falls back to `Opening your city…`.

**Preview states**: `veil_load` (mid-restore, step 7 of 11 — the frame doc 13
§2.9.1's arithmetic is written about) and `veil_catchup` (the C-19 cap exactly:
720 coarse game-hours, capped, so it is also the only state that shows the capped
line). Both added in the same commit as the screen, which is A91-D-28's lesson
applied on the way in rather than a wave late.

### 2.21 The tap and the payday (Wave 14)

The 2026-08-21 playtest asked for one thing this doc owns: "there's not a lot of
downtime of absolutely nothing to do… these things just pop up periodically, so
a user scrubbing around their town can actually see them and give them money."
Doc 06 spawns the things and doc 11 draws them. This section is everything
between a finger landing on one and the player believing they got paid.

**The pick gets a zeroth arm.** §2.8's seam — `BuildController.pick_at_ground` —
answered `building → block → none` in that order, decided by which tile the
point fell in. A street opportunity is not on the grid: it is a 32 dp character
standing on a tile some house already owns, so a tile-decided pick hands every
tap on a loose dog to the building panel behind it. The new order is

```
opportunity (within tap_radius_m)  →  building  →  block  →  none
```

and three things about it are deliberate:

1. **It outranks the building, and the asymmetry is the argument.** Everything
   below it on the list is a thing the player BUILT and can find again in a
   second; the dog is leaving. Losing the house for one tap costs nothing.
2. **It is a radius from the tapped POINT, not a tile test**, because the thing
   being picked is not on a grid. `data/ui.json.street.tap_dp` is 48 — §2.1's
   touch target — and the shell converts it to metres at the CURRENT zoom
   (`BuildController.set_tap_radius_from(CameraState.m_per_dp(viewport))`).
   Measured on a 412 × 915 dp display (doc 92 §38.3), that same 48 dp is
   **0.69 m** of ground at `zoom_t = 0`, **2.58 m** at the default 0.42 and
   **16.04 m** at full zoom-out — a factor of 23. A radius authored in metres is
   therefore wrong at one end of the range by more than an order of magnitude:
   2.58 m is **7.7 dp** of screen zoomed out — a sixth of a touch target, a pick
   nobody can make — and 16.04 m is **exactly two tiles** at the default zoom.
3. **The query is the SIM's roster, never the render view.** `sim.street.
   opportunity_near(point, radius)`. A pick that asked the renderer would be
   picking what is drawn rather than what exists, which is the same class of
   defect as a UI that predicts success (§4.4).

Both seams degrade rather than fail: `tap_radius_m` starts at 0, so a shell that
never wires the conversion picks exactly as it did before, and a sim with no
`street` member or no `cmd_collect_opportunity` refuses with `E_NO_COMMAND` —
which the payday reads as *say nothing*, because there is no story to tell a
player about a feature that is not there.

**The payday is one beat with two doors.** A collect the player tapped for and a
bounty a crew earned while they were looking somewhere else are the same event
to a player: money arrived. Both resolve to

| surface | what happens | owner |
| --- | --- | --- |
| audio | the `cash` cue — three struck discs over a note rustle, 0.55 s, UI bus, never attenuated | `data/audio.json`, `tools/gen_audio.py` |
| HUD | the treasury chip pulses at §2.5's `state_pulse_hz.critical` for `street.chip_flash_s` | `HudModel.flash_chip` |
| world | the floating `+$` | doc 11 |
| copy | a toast — on the bounty half above `street.toast_min`, and on a collect only under A8 | §2.15's surface |
| ledger | a revenue row | §2.10's Economy tab |

**`incident_resolved` has carried `reward` since doc 06 shipped and nothing has
ever sounded it, toasted it or counted it.** That is the whole reason the
automatic dispatch the player asked to be paid for felt like it paid nothing: it
was already paying, silently, which is indistinguishable from not paying. The
audio half needs no shell change at all — a `data/audio.json` rule matching
`range: {reward: {min: 1}}` — and the other three come off the batch `UIRoot.
feed_events()` is already given.

Copy is the player's own sentence where they wrote one: `Crime stopped — +$120
bounty` for crime, `{kind} cleared — {amount} bounty` for everything else, with
`{kind}` resolved from the drawer's own `ui_incident_kind_*` table so a fire is
named here exactly as it is named there. Below `street.toast_min` there is no
sentence — the coin and the chip still fire, because they cost no attention, and
a toast that interrupts for a $12 fender-bender teaches the player to ignore the
next one.

**A8.** The floating `+$` is motion and `reduce_motion` takes it away, so the
collect raises `ui_street_collected` instead. The payday is never silent for an
accessibility setting.

**Discovery is a NOTICE, not a tutorial step.** The first opportunity a save
ever sees raises one coach mark — `Something's happening on Main St — tap it.` —
through §2.17's machinery and none of its curriculum. `OnboardingFlow.
show_notice()` borrows the dim, the cutout and the 240 dp bubble; it has no step
counter, no `Skip tutorial`, no advance condition and no row in
`data/ui.json.onboarding.steps`. The reason is a gate: the balance suite counts
the tutorial's steps, and a curriculum whose length depended on what the
director happened to spawn would not be a curriculum. A live step always wins,
and a notice raised during one is *owed* rather than dropped — it goes up when
the tutorial finishes, including when it is skipped, which is exactly the case
where nothing else has explained anything. The one-shot flag rides in §3.2's
`ui` section; the coordinates deliberately do not, because a mark restored a day
later would point at a street that emptied hours ago.

**The ledger line nobody could see.** A bounty is `Treasury.credit(amount,
&"incident", …)` — a DIRECT credit that does not pass
`EconomySystem.settle_hour` — so **no row of §2.10's Economy tab has ever
contained one, and its NET was short by exactly that much on every hour a crew
answered a call.** A collected opportunity is expected to arrive by the same
door (doc 06's roster is not landed at this fork), which is why it gets a row of
its own here rather than being folded into the bounty line. `data/ui.json.budget.revenue_keys` now carries
`bounties` and `street`, and until doc 03 settles them `StreetModel` tallies the
two off the bus per game-hour and `BudgetModel.feed_side_revenue()` renders
them. The rule that retires it: **a key the settle snapshot carries is taken
from the snapshot, always** — so the day doc 03 publishes `revenue.bounties` the
sim's number wins with no edit here and no chance of counting a dollar twice.
The tally window is the hour that CLOSED, not the one running, because the
column is headed "Revenue, last settled hour" and it has to mean that.

**Preview states**: `street_coach` (the discovery mark over a fixed world point)
and `economy_street` (the ledger with a policed city's real income in it —
one resolved fire outweighs every non-tax line on that screen combined —
doc 92 §38.1). Both
added in the same commit as the surface, per A91-D-28.

---

### 2.22 S16 — the construction queue (Wave 17)

The sim has had a construction queue since doc 02 shipped — jobs, crews,
progress, an ETA in game minutes — and until this wave **nothing on screen
showed any of it.** A player who placed a fire station learned when it was
finished by noticing the crane had gone. §4.4's table listed `reorder_project`
and `cancel_project` with no door, and doc 91 A91-D-49 is the row for that.
This section is the surface: what the city is building, how far along each
project is, when it lands, and what it costs to make it land now.

**The seam, verbatim.** Both halves of this wave were built against one
contract and this screen reads *nothing else*:

```
CitySim.construction_overview() -> Array[Dictionary]      # one row per IN-FLIGHT project,
    {job_id: int, source: StringName, title_key: String,  # sorted eta ascending, uncrewed last
     ref: String, tile: Vector2i, level_from: int, level_to: int,
     progress01: float, eta_gm: float (-1 = nothing working it),
     crews: int, rushable: bool, rush_cost: int (0 when not rushable)}
CitySim.cmd_rush_construction(job_id: Variant) -> {ok, err, cost}   # int(str(job_id)) at the door
event &"construction_rushed" {job: int, cost: int, source: StringName}  # through the normal batch
```

`ConstructionQueueModel.ROW_KEYS` is that row, field for field, and
`tests/test_ui_construction_queue.gd` holds it there. The model is handed **two
`Callable`s and a treasury reading** (`UIRoot.bind_construction(provider,
rush, treasury)`) rather than a sim, for two reasons: `tools/ui_preview.gd`
has to reach a queue with three mixed rows and one nobody is working, on
demand, and a live city puts those hours apart; and it is what let this half
be built and swept before the sim half existed. Every one of the three may be
left unbound and the screen then shows what a city with nothing under way
shows — nothing, and no chip.

**The screen.** A side panel on `PanelLayer` — the incident drawer's shape,
not a modal, because **tapping a row focuses the camera on the site** and a
scrim would have to be dismissed before the player could see the thing they
asked to look at (§2.6 settled this one screen over). One row per project:

| line | reads | from |
| --- | --- | --- |
| head | what is being built — `title_key` resolved, or *Project* if the key is not in the table | `title_key` |
| kind | *Upgrade · Level 2 → 3*, *New building*, *Land development* — the level climb only when `level_from/level_to` is one, never `Level 0 → 0` | `source`, `level_*` |
| bar | a `MeterBar` (§2.6's held-clock widget, S14's level bar) with the percentage beside it; **hatched and amber when nothing is working it** (A5: never the colour alone) | `progress01` |
| ETA | *about 1h 36m left* — game time, through the one `UIWidgets.duration_text()` S4's phases also use — or, said out loud, ***Nothing is working on this yet.*** | `eta_gm`, `crews` |
| crews | *2 crews* / *No crew* | `crews` |
| verb | `RUSH $1,240` — the price ON the face; **disabled with the price still on it** when the treasury is short; absent, not blank, when the seam says it cannot be rushed | `rushable`, `rush_cost`, the treasury reading |

The row head is the whole tap target and the verb is a sibling
`HFlowContainer` below it (D-47's shape): two 48 dp targets cannot share a
line in a 320 dp column at 150 % text, and a flow container drops the verb to
its own line rather than widening the panel. Rows sort **ETA ascending with
the unworked last**, and the model sorts again what the sim already sorted —
`ui/` cannot hold a `Callable` to its promise, and a fixture that arrives
unsorted would put the thing that lands next halfway down a scrolling list.
Under the title one line reads *4 under way · 1 waiting for a crew*, and the
second half exists only when something is actually waiting.

**`0:00` is the one thing this screen may never print.** `eta_gm = -1` is a
*state* — nothing is working this — and a clock that reads zero says the
opposite: *finishing now*. The model treats the contract's two ways of saying
it as one fact that has to agree before a sentence is written: a job with no
crew is unworked whatever number came with it, and a job with `-1` is unworked
however many crews it claims. Report 98 RR-112 is the ruling.

**The entry point, argued from §2.3.** The top bar is full — D-65 is the story
of two chips landing at x = −121 in the audit box — so the door is a
**corner-rail chip, `⚒ n`, on rung 3 of the bottom-right rail** above the
alerts and event-log chips, and it **exists only while something is building**
(doc 93 §AB3). Three things about that are deliberate:

1. **Rung 3, not rung 2.** By the rail's own ordering rule the log is the
   least urgent of the chips and should take the rung furthest from the thumb
   — and the queue, which carries a live count and leads to a paid verb,
   outranks it. Rung 2 was declined anyway, because D-46's rail *closes gaps*:
   a queue chip that appeared at rung 2 would push the log chip up when the
   player placed something and drop it back when a project finished on its
   own — a control moving under the thumb for a reason that is not the
   player's (D-59's argument, the other corner). At rung 3 **nothing that
   exists today moves** when the chip comes or goes. The cost is reach: rung 3's
   centre is `(W−92, H−228)`, `d = 210` from the right pivot — §2.3's *rare*
   band, edge-anchored — where rung 2 would have been `157.6` (*occasional*).
   It is paid because the chip is a *glance* surface (the count is the
   reading) and the verb it leads to is **also one tap from the building
   itself** on S5, which is in the frequent zone of whatever the player is
   looking at. Re-open: an on-device playtest that reaches for the queue more
   than for the log.
2. **The rail wraps before it overflows** (D-67, doc 93 §AB2, report 98
   RR-111). At 640 × 340 with 150 % text and larger targets the chips measure
   92 dp and rung 3 would have started **48 dp above the display** (its top
   edge at window `y −48` of a 340 dp box).
   `UIWidgets.solve_corner_rail()` now takes the safe area's height and fits
   `floor((H − margin + gap) / (pitch + gap))` chips per column — **2** there,
   **5** at the 880 × 400 reference box — and starts a second column, one
   chip-width plus a gap further in, for the ones that would not fit. D-1's
   rule for the top bar, applied to the other corner: *wrap before you
   overflow, and never hide a door to make room.* `host_h = 0` is the old
   unbounded column byte for byte, and the reference box does not move.
3. **No dashboard row this wave.** §2.10's Overview is a full-screen modal
   behind a *rare* tap; the queue's reading is a count and a verb, and the chip
   gives both from the HUD. A row there would be a second door to the same
   panel with nothing the chip does not already say. Re-open when the
   Overview grows a "what is happening" block — it is a one-line
   `DashboardModel` read of the same model.

**S5 joins up.** A picked building whose `ref` the seam names shows the same
row inline — kind and level climb, the bar, the ETA sentence, the crews and
`RUSH $n` — in a bounded `Progress` block built in code **directly under the
level pips and above the upgrade block**: while a project is in flight, *when
does this land* outranks *what comes after it*, and the UPGRADE button below
is disabled for the duration anyway. It is the **same `ConstructionQueueModel`
instance** the panel holds (`BuildingPanel.bind_construction(model)`), so the
two can never publish different numbers for one project; a building the seam
does not name simply has no block — no crash, no empty bar, no `0:00`. The
lookup is `row_for_ref()`, the contract's own field, and two projects on one
ref answer the soonest, because that is the bar that is moving.

**A rush is one tap, and the price is the confirmation** — doc 93 §AB1 has the
ruling and the threshold. The one line worth repeating here: the verb is a
separate 48 dp target in its own row *below* the row head, and the row head's
own tap does something harmless, so a mis-tap on the row costs nothing and
only the face that carries the price spends.

**The cue** (D-62's shape, backwards). `construction_rushed` on the bus is
worth: the **`purchase`** cue — the deck's spend sound, the one
`building_placed_sim` already uses, never `cash`, because a player who hears a
till when their balance *drops* learns the wrong thing about their own
treasury; the treasury chip's pulse for `construction.chip_flash_s`
(deliberately `street.chip_flash_s`'s number); **one toast** — *Upgrade rushed
— −$1,240*; and a haptic, unlike a bounty, because the player's own thumb is on
the button. It is felt **from the bus, once**: the door's accepted answer adds
nothing, so a rush from the queue, from S5, from a later automation or a
replayed batch is felt identically, and a refusal is §2.7's formatter over
`err` as a toast — except `E_NO_COMMAND`, which is silence for §2.21's reason.
The completion the rush causes is **not** sounded here; it arrives a moment
later on `building_completed` and rings `construct_complete` exactly as an
unrushed one does, which is the whole point of a rush firing the same events a
natural finish fires. **No first-rush notice.** D-63's machinery would carry
one, but a notice costs a `ui` save-section flag (§3.2's ladder, doc 08's
migration) for a sentence the button already says on its face; the price *is*
the lesson.

**What is left to the sim half — deferral rows, never guesses.**

| awaiting_consumer | what this screen does meanwhile | closes when |
| --- | --- | --- |
| `source` spelling for a land development — the contract says `block`, `ConstructionQueue.KINDS` says `development` | both resolve (`ui_queue_source_block` / `_development`, one label); the other is dead copy the orphan check tolerates because the model splices the family | the sim half ships one and the other key is deleted |
| `title_key` for a non-building project (a block's grading phase, a road run) | an unresolved key renders as *Project*, never as the raw key (`UIAudit.raw_string_key` would call that a defect) | the sim half names the keys it sends, from `ui_land_phase_*` / `ui_build_card_*` |
| a solvency floor the affordability rule could read (doc 93 §AB1) | disabled-with-price at `rush_cost > balance`, which is where the door refuses | doc 03 publishes one on the seam |
| the four `game/main.gd` lines (bind the seam, bind S5, the 1 Hz `refresh_construction()`, S5's `rushed` → `report_rush`) | the harness wires the same seam with a fixture provider; the shell shows no chip until the lead lands them | the lead merges |

**Preview states** (`tools/ui_preview.gd`, same commit, A91-D-28's lesson):
`queue` — the mixed list the panel is written for; `queue_uncrewed` — the row
that says so in words; `queue_empty` — the panel with the last project gone
out from under it, which is reachable; `building_upgrading` — the same facts
inline on S5. The fixture is bound on **every** screen, not only these four,
because the chip changes the rail's solve behind every screen and has to be
measured beside all of them. The deck is **61** states. The harness also
gained a guard this wave — `--screen=<one>` used to audit on its first frame,
before any sibling chip had run the `_process` that yields the edge, and
reported **46** overlaps across three states × six boxes on a tree the sweep
called clean in all eighteen cells (A91-D-50, RR-113; doc 92 §46.3's table).

---

### 2.23 The tilt axis and the right-edge slider (Wave 17)

**The ask (2026-08-21):** *"we need to be able to look up at the buildings — the
high rise is really tall; if you zoom in you're pretty much just looking at the
ground… on the right side of the screen a tilt slider, vertically: all the way
down, all the way up, the slider sits in the middle, up and down motion."*

**1. The axis.** §2.16's rig is `{focus, zoom_t, yaw}` with pitch DERIVED from the
zoom (`pitch(t) = 34° + 28°·smoothstep(t)`). Wave 17 adds a fourth, manual axis
that **composes with that curve rather than replacing it**:

    pitch = lerp(pitch(t), target, |bias| · reach(t))
    bias ∈ [−1, +1]   +1 → pitch_manual_min_deg (12°, up the facades)
                      −1 → pitch_manual_max_deg (78°, top-down)
    reach(t) = lerp(near, far, smoothstep(t))   — the zoom coupling, doc 92 §47

`bias = 0` is **AUTO**: the composed pitch is the curve's own answer to the bit,
so a player who never touches the control has the camera that shipped before this
wave. 12° and not 10°, because `18·sin 10° = 3.1 m` puts a D_MIN camera inside the
3.5 m ground floor of doc 11 §2.6's shortest archetype and `18·sin 12° = 3.74 m`
clears it. 78° and not 90°, because at 90° yaw stops meaning anything and the
twist gesture becomes a spin about nothing.

**2. Two ways in, one axis.** The slider column, and a **two-finger tilt** (§2.16's
MULTI state gains a third arm): 24 dp of vertical centroid travel with the span
still inside half the pinch slop, the bearing inside half the twist deadzone, and
the travel at least 1.5× more vertical than horizontal. It takes the whole stroke
when it engages and can never engage after a pinch or a twist has — the
discrimination table is in `ui/gesture_recognizer.gd::_emit_multi`. Both routes
share the axis's feel with the pan: rubber band past the ends, a closed-form fling
on release, a critically damped return, and a **double action home to AUTO**
(double-tap on the column; A8 `reduce_motion` cuts the ease).

**3. The column.** Right edge, **one 48 dp touch column**, vertically centred in
the band left between the top bar's first row and the corner rail's reservation —
not in the whole safe area, because the incident drawer's handle owns the edge
from 60 to 220 dp above the bottom and a naively centred column lands on it at
every landscape box. `tilt_slider_h_dp` (240) when there is room, the band when
there is less, and it **stands down entirely** below `tilt_slider_min_h_dp` (96),
which is what happens at the 640 × 340 floor box. It **yields the edge** while any
`PanelLayer` surface is open. The thumb rests on the middle detent, is an A3
target that grows with the larger-targets setting, and carries `ui_tilt_thumb`;
the column carries `ui_tilt_slider`. After `tilt_slider_fade_after_s` (2 s) of
stillness the whole column ghosts to `tilt_slider_ghost_alpha` (0.35) and any
touch wakes it — the A8 reading is that a ghost is a **state**, not an animation,
so `reduce_motion` keeps the ghost and cuts the 0.25 s fade to a cut. Preview
states: `tilt_rest`, `tilt_drag`.

**4. The horizon, and the taps that now miss.** At the floor the top of the frame
is 8° above the horizon, so a tap up there has **no ground under it at any
distance**. `CameraState.ground_hit()` answers `{hit, position, reason, distance}`
(`ground` / `above_horizon` / `grazing`); `screen_to_ground()` is unchanged and
still answers the clamped point for pan, pinch and the anchor lock, which have
always wanted it. Placement, picking, the path ghost and tap-to-focus branch on
`hit` (report 98 RR-116). §2.21's 48 dp tap radius is unaffected by tilt:
`m_per_dp()` is measured across screen-right, which is parallel to the ground at
every pitch. The other axis is not, and is published as `m_per_dp_depth()` =
`m_per_dp / sin(pitch)` — a world circle projects to an ellipse that keeps its
metres and loses screen height as the camera tilts, so a tilt can only make a
radius pick more conservative.

**5. What the tilt reveals.** The sky (doc 11 §2.8) is now something a player can
look at, and the world's 896 m edge is something they can look over: the gradient
sky's horizon haze is drawn in the same fog tint the far city fogs toward, which
seats the edge (measured: a ≤ 17/255 per-channel step across the seam, report 98
RR-114).

**6. Persistence.** D-68: the `camera` block of the `ui` save section —
`{focus_x, focus_z, zoom_t, yaw_deg, pitch_mode, pitch_bias}`. `pitch_mode` is the
word (`auto` / `manual`) and is written because a save carrying only the number
could not tell AUTO from a bias that happened to land on the curve. Restore
re-composes the bias against the band **this build** authors, so retuning the band
retunes every restored city rather than leaving old saves pointing where the data
no longer allows.

## 3. Data Schema

### 3.1 `data/` files owned by this doc

- `data/ui.json` — layout, breakpoints, palette, selection ring, gesture constants, camera **interaction** constants, formatting rules, and the `in_app_alerts` gate.
- `data/onboarding.json` — the step table of §2.17 plus the scripted incident.
- `data/strings.en.json` — **every display string in the game** (report 98 G-8).

Two files this doc used to claim and no longer does: `data/notifications.json` is **doc 08's** (push classes, event→class mapping, budgets, quiet hours — C-71) and the camera's projection constants live in **doc 11's** `data/render.json` (C-63). Neither is duplicated here.

**Three files this doc READS and never writes**, all for the same reason and all through `UIConfig`: a settings row that carries `policy:` must default to what the owning system actually boots with, and offer only the rungs that system will accept. `data/render.json` supplies the graphics presets, `data/dispatch.json.policy_defaults` supplies §2.13's auto-response defaults (D-11), and — Wave 12 — `data/roads.json.condition` supplies the auto-repair threshold **ladder** as well as both defaults (D-50). Absence of any of the three is not an error here; the rows fall back to their own `default`. A second copy of any of those numbers in `data/ui.json` would be a bug, and is what these accessors exist to prevent.

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
  "street": {"coached":true,"coach_pending":false,
             "live":{"bounties":0.0,"street":0.0},
             "settled":{"bounties":1840.0,"street":260.0}},
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

**`street` (Wave 14, §2.21).** Two things, for two different reasons. `coached` / `coach_pending` are the one-shot discovery flag — a lesson taught twice is a lesson nobody trusts, and a mark the tutorial was standing on is owed rather than lost. **The mark's coordinates are deliberately NOT here**: restored a day later they would point at a street that emptied hours ago, and a mark that points at nothing is worse than one that centres. `live` / `settled` are the per-game-hour tally the Economy tab's two unsettled revenue lines are drawn from; they ride along because a save taken mid-hour and restored would otherwise print a ledger line for money the restored city no longer remembers earning. Both halves retire the day doc 03 settles `revenue.bounties` — the tally is ignored for any key the settle snapshot carries.

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
| Unit chip `RECALL` / toast UNDO | `recall_unit` | `{unit_id}` | 06 | toast — §2.7's formatter over `E_UNIT_NOT_DEPLOYED` / `E_UNKNOWN_UNIT`. **The chip ships in Wave 12 (D-48); the toast UNDO does not** — §2.6 step 4's five-second undo wants a toast that carries an action, which `ToastView` has no shape for |
| Settings row `Repair roads below` / `Road repair budget` | `set_auto_repair_policy` | `{threshold, daily_cap}` — **the pair**, always | 10 roads | toast over `E_BAD_THRESHOLD`, and the row goes back to what the city holds |
| Unit picker `Queue anyway` | `queue_incident` | `{incident_id}` | 06 | toast |
| Drawer row swipe → `Acknowledge` | `acknowledge_incident` | `{incident_id}` | 06 incidents | — |
| Speed control | `set_speed` | `{multiplier: 1\|2\|3}` | 01 time | — |
| Pause toggle | `set_paused` | `{paused: bool}` | 01 time | — |
| Policy editor | `set_auto_policy` | `{key, value}` | 08 offline/persistence | — |
| Construction queue reorder | `reorder_project` | `{project_id, index}` | 02 owns `ConstructionQueue.reorder` / 06 owns the crews as units (report G-2) | toast |
| Cancel a project | `cancel_project` | `{project_id}` | 02 | confirm dialog |
| Queue row `RUSH $n` / S5 `RUSH $n` | `cmd_rush_construction` | `{job_id}` — coerced `int(str(job_id))` at the door (the Wave-14 String-id lesson) | 02 owns the queue / 03 owns the price (`rush_cost` is quoted by `construction_overview()`, never computed here) | the price is the confirmation (doc 93 §AB1); a refusal is §2.7's formatter over `err` as a toast, and `E_NO_COMMAND` is silence |

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

`incident_created`, `incident_escalated`, `incident_resolved`, `unit_dispatched`, `unit_arrived`, `unit_freed`, `power_restored`, `power_lost`, `construction_completed`, `land_developed`, `treasury_threshold`, `weather_warning`, `weather_changed`, `day_phase_changed`, `city_level_up`, **`level_up_grant_paid`** *(report 98 RR-79 — LOG ONLY, no push: `city_level_up` already wakes the player for that rung and a second push would be the game repeating itself, but a payment belongs in the money ledger where it can be found again an hour later)*, and — Wave 17, §2.22 — **`construction_rushed`** `{job, cost, source}`: the spend cue (`purchase`, a `data/audio.json` rule), the treasury chip's pulse and one toast, felt from the bus so that a rush from any door is felt exactly once; the completion it causes rides the existing `building_completed` untouched.
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

**Deferred:** the CONSTRUCTION overlay and multi-overlay stacking *(this line also read "**TRAFFIC and** CONSTRUCTION overlays" until 2026-08-21. **TRAFFIC shipped in Wave 5** — `data/ui.json.overlay.enabled_modes` carries all six and `OverlayModel` has a `MODE_*` for each, which §2.5's row has said for waves — and this list was never struck. Corrected by doc 91 §20.5's marker sweep, on the rule that a stale DEFERRED entry makes finished work look like scope nobody took)*; S13 full event log (the away report shows the top 8); Dashboard Economy/Infrastructure charts beyond raw numbers; colourblind palette variants A6 (the default palette is already glyph-redundant), text scale A2 beyond 100/130 %, screen-reader labels A15; manual camera pitch, bookmarks, mini-map; radial long-press quick actions (long-press falls back to opening the panel); cluster de-clustering animation (clusters snap); haptics beyond `light`; any second locale. Digest mode and quiet hours are **not this doc's to defer** — they are doc 08 policy surfaced by S10 (C-71); if doc 08 ships them disabled, S10 greys them with doc 08's reason string.

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
10. **`test_topbar_collapse`** — the §2.4 worked example (W=640) reproduces exactly; W=880 keeps all chips FULL; P1–P4 never HIDDEN at any width ≥ 480; deterministic, ≤ 14 iterations. **Strengthened by D-13b:** the below-480 sweep now checks **every packed row against its own line** (row 0 gets `avail`, wrapped rows get `avail_rest`) instead of the widest row against the whole bar, which is what let a 20 dp overflow report as fitting; the treasury chip is asserted to survive exactly where row 0 has room for it, and to be droppable where it does not. `W = 880 keeps all chips FULL` is untouched — the third hide tier cannot fire while anything fits. **Strengthened again by D-51 (Wave 12):** the solver's second axis gets its own five tests — `rows_within` reserves one row of height per wrapped row and never returns zero, an unbounded budget is byte-for-byte the doc's own solver, a 100 dp budget at the reference box gives one row with P1 still on it, `top_bar_left_inset()` is 0 whenever the bar clears §2.3's rail and `rail_column_w + 8` when it does not, and `W = 880 keeps all chips FULL` is re-asserted *against the vertical solve* rather than beside it.
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

25. **`test_path_tool`** (§2.7's drag-path, Wave 10) — `PathTool.l_path()` is an L, Manhattan, longest leg first, ordered from the anchor, corner emitted once, ties to X; the roster is eight cards on the two tabs §2.7 files them under (four road verbs, two main tiers and doc 04 §6's two conductor classes), each quoting a **per-tile** price read from `CostCurves` and none of them locked; the two category literals and the three road-class integers equal `BuildController`'s and doc 10's; a ghost move never pins the anchor and `START` does; the run's verdict, its price and its refusal are the owning command's own `preview = true` answer; a run that overlaps existing road is billed for the fresh tiles only and the ghost's `billable` flags say which; the sweep is capped at `placement.max_run_tiles` by truncating the far end; `↺` unpins without dropping the card; `Remove` quotes a refund and credits the treasury by exactly what it quoted; and `PathGhostView` draws one slab per tile in the same four §2.5 tints the box ghost uses.

26. **`test_build_controller`'s actions block** (§2.9 item 6, Wave 10) — the repair row is absent at condition 1.00 and priced by doc 03 §2.5 below it, the panel charges exactly what it printed and then shows `E_JOB_IN_FLIGHT` in words; `Fix this →` on `E_CONDITION` buys the repair and hands the camera router nothing; the priority row is doc 04's own class roster and a tap moves the sim's shed tier; `DEMOLISH` fires on a full 800 ms hold and on nothing shorter, credits the quoted refund, and closes the panel. The run flow is asserted through the sheet the player touches: one `is_placing()` for both tools, the two-step bar, and a world drag that draws without committing on finger-up.

27. **`test_ui_audit`'s corner-rail and sheet-wrap block** (D-37/D-38, Wave 11) — `UIWidgets.corner_slot()` reproduces the scene's authored offsets at 100 % text with 48 dp targets (alerts bottom 92, event log bottom 148, both 48 tall) and keeps exactly one `rail_gap_dp` of clear air between two 100 dp chips at 130 % with larger targets, with both chips clear of the column the tab reserved; all three affordances actually answer `corner_rail_entry()` with the index the rail expects (an affordance that forgets it is one the solver cannot see, and it lands back on top of its neighbour with nothing failing); and every settings row and every save-slot action group is a `FlowContainer`, so a row that does not fit wraps instead of widening its sheet. The geometry half is asserted on the **solver**, not on measured pixels, because a headless run has no text metrics — the pixel-accurate pass is `tools/ui_preview.gd --screen=all --audit`, whose whole-deck score is now **zero findings at 360×800, 412×915, 794×924 and 1280×720, at 100 % and at 130 % + larger targets**.

28. **`test_ui_scaffold`'s theme-scale block** (D-54, Wave 13) — a themed button's content margins are its **own** padding times the text scale, once, at 130 % and 150 % on both touch settings and across `Button` / `StatChip` / `RailButton` / `PrimaryFAB`; what the theme alone makes a `StatChip` measure clears A3's floor with **at most 4 dp of rounding slack** rather than the 22 dp a second multiplication costs; and the whole thing is byte-identical at 100 %, which is the assertion that says the reference layout did not move. The old theme fails it with `a StatChip's own box is 95 dp against an A3 floor of 73`.

29. **`test_ui_audit`'s left-rail block** (D-59, Wave 13) — `UIWidgets.solve_rail_stack()` gives the whole column **one** pitch (the tallest member's) with exactly `rail_gap_dp` between slots and every slot the same height; a stack of 48 dp members still keeps `fab_d_dp`'s floor and the bottom rung still sits one `rail_margin_dp` off the safe area, so the 100 % layout is unchanged; and all three members — on two different layers, in three different files — actually answer `rail_entry()` with the index the solver expects. The mirror of test 27's corner-rail assertion, and for the same reason: a member that forgets to join goes back to placing itself, with nothing failing.

30. **`test_veil_model`** (§2.20, D-60, Wave 13) — the phase machine, the copy and the fraction, headless: a cursor with no steps reads 0 rather than dividing; a step count past the total cannot overfill the bar; a late `advance_load` from the frame the catch-up started cannot rewind the bar the catch-up now drives; an absence beneath `veil.min_steps` is refused **and takes a showing veil down with it**, which is the sequence a returning player produces; `ui_veil_catchup_one` is picked for one hour and not for two; a capped absence says so; `finish()` is idempotent; and a second load behind the same veil starts from zero. The pixel-accurate pass is `tools/ui_preview.gd --screen=veil_load|veil_catchup`.

31. **`test_ui_construction_queue`** (§2.22, D-66/D-67, Wave 17) — the UI half of the construction seam, proved against the CONTRACT through the two `Callable`s and the treasury reading the model takes: `ROW_KEYS` is the contract's twelve fields verbatim and `KNOWN_SOURCES` equals `ConstructionQueue.KINDS` plus the contract's `block`, so a field or a kind one side ships and the other does not fails a test rather than rendering grey; rows sort ETA-ascending with the unworked last and ties on `job_id`; an unworked project — `eta_gm < 0` **or** no crew, whichever the seam sent — reads as a sentence and never as `0:00` or `0m`; the ETA reads in game time through the one `UIWidgets.duration_text()` S4 also uses, and the old `ui_land_time_*` keys are gone; the level line prints only for a level change; the rush price is on the face, DISABLED with the price when the treasury is short and absent when the seam says not rushable, with the tooltip naming both numbers; the door coerces a String id and answers verbatim, and no door is `E_NO_COMMAND`; a rush on the bus is one toast and one chip flash and the door's accepted answer adds nothing, while a refusal is a sentence and `E_NO_COMMAND` is silence; the mounted chip hides at zero, badges the count, is rung 3 of the corner rail, yields to a sibling panel and to Android BACK; a row tap focuses the site through the injected locator; pressing RUSH removes the row without freeing the button mid-signal; S5 shows the same row inline directly under the level pips and only while it exists; and `data/ui.json.construction` holds no price. 22 tests. The pixel pass is `tools/ui_preview.gd --screen=queue|queue_uncrewed|queue_empty|building_upgrading`, and the corner rail's wrap point is pinned in `test_ui_audit`.

Manual/device checklist (not automated): thumb-reach on a 6.1" and a 6.8" device, notch/cutout safe area on a punch-hole and a notched device, one-handed reachability of jump-to-worst, ~~150 % text scale at 640 dp~~ (**automated as of Wave 13's D-58** — 640 × 340 is a `BOXES` row and the sweep runs it at 100 / 130 / 150 %), and the step-9 relight moment reading as a payoff.

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
  "construction": {
    "_comment": "S16 (§2.22) — PRESENTATION ONLY. Not one number here is a price, a duration or a rate; those are doc 03's and reach the screen through construction_overview()'s rush_cost and eta_gm. chip_flash_s is deliberately street.chip_flash_s: a dollar leaving and a dollar arriving must not feel like two mechanisms.",
    "row_h_dp": 96, "panel_w_dp": 320, "chip_w_dp": 72, "bar_h_dp": 6, "chip_flash_s": 0.9
  },
  "veil": {
    "_comment": "S15 (§2.20). min_steps is doc 13's own catchup_veil_min_steps: an offline catch-up worth fewer steps than this gets no veil. A stepped RESTORE always gets one whatever its step count — doc 13 §2.9.1's per-step table runs 0.2 ms to 76.5 ms, so few steps does not mean fast.",
    "min_steps": 5, "card_w_dp": 320, "bar_h_dp": 8
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
  "_comment_street": "§2.21. Four numbers, and every one is about the finger or the screen: no reward, spawn rate or lifetime is authored here or anywhere else in ui/. `tap_dp` is §2.1's touch target, converted to a world RADIUS at the current zoom (doc 92 §35.3 has the metres). `toast_min` is the dollar floor below which a bounty pays, sounds and pulses the chip and says nothing.",
  "street": {"tap_dp": 48.0, "coach_ttl_s": 14.0, "chip_flash_s": 0.9, "toast_min": 25},
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
| D-13b | **A row is solved against ITS OWN line, and the last chip may go too.** `solve_top_bar` keeps hiding while any packed row exceeds the line it is on, down to and including the treasury chip; `CityHUD._clock_width_dp` reserves the clock and ☰ column at their **combined minimum size**, not at the `custom_minimum_size` they were asked for. | §2.4, D-13 | D-13 was one rung short and the goals wave filed it. Two independent leaks. (a) The hide loop stopped as soon as `_pack_rows` had nothing left OVER — but that function gives an over-wide chip its own row rather than dropping it, so the loop exited with the treasury chip alone in a row it is wider than. At 360 dp / 130 % / larger targets the treasury chip measures **143 dp** against row 0's **103** (`360 − 241 − 16`), and it cannot be demoted out of trouble either, because `$8.42M` is its compact string as well as its full one. (b) The ☰ measures **85 dp** against the 48–64 it was asked for, so the column reserved for it was an underestimate before the packing even started. Measured before: treasury at x = **−9**, ☰ ending at **369** of 360, and the wrapped goals chip at −9 with them. Swept over the whole deck — `tools/ui_preview.gd --screen=all --size=360x800 --text-scale=1.3 --large-targets --audit` — the box carried **129 `offscreen` findings on the top bar** (☰ 43, treasury 43, goals chip 32, incidents chip 11) and now carries **zero**; every other finding in that sweep is identical on both sides. |
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

**Still open against this doc** *(re-swept 2026-08-21 at the Wave-13 fork; four items, down from five)*: §2.10's condition histogram is not built (`grep -rn histogram ui/` returns one comment in `ui/city_dashboard.gd:397` saying where it would go); the Response tab's auto-response editor is not on the *tab* — the seven policies ship as S9 rows instead (Wave-6 D-23); the utility restoration **order** is still absent because it is a drag-reorder list rather than a cycling target; §2.5's POLICE and FIRE rows draw the per-BUILDING coverage state, not yet the coverage discs, unit dots or heat bins. ~~S10's notification rows are still doc 08's and doc 13's to land~~ — **CLOSED 2026-08-21 (shipped Waves 10–12, never struck here).** The five rows are in `data/ui.json.settings.rows` (`notifications_enabled`, `notify_p1_critical`, `notify_p2_important`, `notify_p3_routine`, `quiet_hours_allow_critical`), inside S9's sheet exactly as §2.2 specifies, and `game/main.gd:1254` writes them through `NotificationRouter.apply_settings(model.capture_state())` — so they are a *view* of doc 08's policy rather than a second copy, with the row key equal to the class id lowercased so the two data files cannot drift. §2.13 carries the full row. *(The 2026-08-19 wording is kept above so the sweep's provenance is readable.)* Closed since the Wave-3 note: the overlay legend is now the separate top-left `OverlayLegend` card (`ui/overlay_legend.gd`) and the strip carries only chips and its refusal notice; S13 (event log) shipped in Wave 4; the dashboard ships all four tabs, Infrastructure reading `PowerGrid.feeder_rows/transformer_rows/capacity_summary` and doc 05's §5.8 zones, Response reading doc 06's roster plus `DispatchSystem.stats`; POLICE and FIRE are live on doc 02 §2.9's coverage field (C-51), so `overlay.enabled_modes` now lists all six. **S0 shipped in Wave 7** (`ui/title_screen.gd` + `ui/title_model.gd` on `SafeArea/TitleLayer`, between `SheetLayer` and `ModalLayer` so the door covers the deck and a modal covers the door): the game name over the launcher icon's own skyline, CONTINUE carrying the newest save's day / population / treasury, NEW CITY with the slot confirmation doc 93 §E2 rules, and SETTINGS opening S9 over the title. The back stack takes a `title_open` context rather than a new rung — at the front door there is no city, so the sheet / panel / placement / selection rungs cannot exist and back is the two-press minimise pair. Also shipped earlier: `sc_overlay_mode` is read by the building shader (Wave 2), S6 incident drawer, S7 unit picker, S8 dashboard, S11 away report, and S12 onboarding (Wave 2–3).

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

### Wave-11 deltas — the last two verb families get their doors (2026-08-20)

Wave 10 left three shipped sim verbs with no surface and one open question about
where a fourth belongs. All four are answered here (doc 93 §J1–§J3, measured in
doc 92 §28), and — as in Wave 10 — **not one line of new simulation** was needed:
one read-only field on `IncidentSystem.snapshot()` is the whole of the `sim/`
diff, and it publishes something `incident_created` already carried.

| # | Delta | Where | Why |
|---|---|---|---|
| D-37 | **§2.7's card table gains the `Power Line` row it has always had.** `cmd_route_feeder` reaches the drag-path tool as two cards on `infrastructure` — `Feeder` (class 1) and `Heavy Feeder` (class 2) — quoting doc 03 §2.13(b)'s per-tile price and doc 04 §2.2's plate in the micro row. The roster is read from `data/grid_components.json.routable.feeder.conductor_classes`, so a class this build does not ship never gets a card. | §2.7 | Doc 92 §25.7 deferred it as a *balance* change, not a UI one — §17.3 names the 2 × 1,200 kW feeder ceiling as the late game's binding constraint. §27 is the pass it asked for. The tab is `infrastructure` and not `roads` because §2.7 files a run card by what it is made of: a feeder belongs beside the transformer it roots, exactly as a main belongs beside the pump it feeds. |
| D-38 | **One run card does not use §2.7's L.** `PathTool` gained a per-card `geometry` key; the two feeder cards declare `assist`, which fills the run from `CitySim.suggest_feeder_route` (doc 04 §4 / report 98 C-41) instead of `l_path`. Every other card is unchanged. | §2.7 | `cmd_route_feeder` requires every tile to be on land that is owned and READY, and a straight Chebyshev line between two owned blocks routinely crosses one the city does not own — doc 04 records that as the whole of seed 4242's late-game routing failure. The assist returns the shortest *legal* run, which on a per-tile price is also the cheapest, and falls back to the straight line when there is none. The ghost still draws exactly the tiles the commit will lay, which is the rule that matters. **Measured** on the founding city, workstation, 200 ghost moves: a feeder recompute (BFS + the command's preview) costs **0.697 ms** against an L card's **0.108 ms** — 6.4×, but it rides the ghost's revalidation rate, not the frame, and doc 11 §2.13's Fold table gives the CPU 8× headroom. |
| D-39 | **`E_NO_SLOT` routes `Fix this →` to a building.** The run tool lifts `substation` out of the command's own quote into `fix_target_id`. | §2.7, §4.4 | The sim names the object its refusal is about; *which* of a payload's ids the camera should chase is a UI decision, so it is made in `ui/`. Without it the deepest refusal in the power chain pointed at nothing. |
| D-40 | **`E_NOT_CONNECTED`'s copy stops naming roads.** One template, three run verbs: it now reads *"this run has to start on something already built"* with the three networks in the remedy. | §3.1 | The string was written when `cmd_place_road` was the only caller. `cmd_place_water_main` has shared it since Wave 10 and `cmd_route_feeder` shares it now, so a main that started nowhere was being told to find a road. |
| D-41 | **S5 grows a water-node block** (doc 05 §6, doc 93 §J1): below §2.9 item 6's actions row, one row per doc-05 node the tapped `water_facility` shell hosts, each carrying §2.9's own `L1 L2 ▮L3▮` strip, the node's kW and state, and one button quoting `cmd_upgrade_water_component(preview = true)` with the whole gate under it. Drawn **only** where a building hosts a node, which is nowhere else in the city. | §2.9 | A water site is already a building and already has a panel; the shell's `UPGRADE` buys doc 02's floorspace and this buys doc 05's supply. And the block is a LIST because `WTR-1` hosts three nodes — a panel that showed one would be lying about the other two. |
| D-42 | **S6's expanded row grows a fourth action on exactly one kind of incident** (doc 05 §2.12, doc 93 §J1): `ISOLATE` while the main is live, `RESTORE` once it is valved out — one control in two moods, beside `ASSIGN`, on a row whose `target_ref` is a `water_segment` the sim still has. | §2.6 | §2.12's pair is a trade taken under time pressure about a MAIN, and a main has no footprint, no panel and no way to be selected. The only place one is ever named to the player is the break itself. **This is the screen the deferred "water-node panel" turned out to be**, and it is why no such panel was built. |
| D-43 | **The drawer's water binding resolves itself.** `UIRoot` takes `WaterActions` off `build_sheet.controller` the first time the shell feeds an incident snapshot; `bind_water_actions()` exists for a shell that would rather be explicit. | §4.4 | `bring_up_screens()` builds every screen against one `UIConfig` and no sim, and the shell builds the controller afterwards. One wire between two children the root already holds is the root's job; a second shell call for one binding is not. A mount with no build sheet simply draws no valve. |
| D-44 | **`RequirementFormatter` gains seven codes** — `E_CLASS_UNAVAILABLE`, `E_DISCONTINUOUS`, `E_NO_SLOT`, `E_UNKNOWN_NODE`, `E_NOT_UPGRADEABLE`, `E_UNKNOWN_MAIN`, `E_NOT_ISOLATED` — with `E_NO_SLOT` fixing to a BUILDING and the two "already in that state" rows filed INFO rather than BLOCKED. | §2.7, §4.4 | Every refusal the two new surfaces can raise is a sentence, or the door is not a door. `test_every_requirement_placeholder_has_a_supplier` holds the templates to the formatter's arguments. |
| D-45 | **A tab lists footprints before runs.** `BuildController._card_less` gained a clause above the refund one: a card carrying a `path_verb` sorts after one that does not, and each kind is then sorted by its own price. | §2.7 | §2.7's "then cost" was written before a run card existed, and a run's `cost` is a price PER TILE. Sorted together, `Feeder` at $110/tile leads the INFRASTRUCTURE tab and `Transformer` at $500 falls to **fourth** — on the tab a player reaches by `E_UNSERVED`, whose answer *is* the transformer (doc 93 §A: "`cmd_place_grid_component` is THE game"). The Wave-10 mains had already put `Water Main` above it; the feeder cards made the defect impossible to miss. Ordering by a number that means two different things is not an ordering. |

**Preview states added** (`tools/ui_preview.gd`): `path_feeder`, `building_water`,
`drawer_water`. All three are clean under `--audit --strict` at 360×800, 412×915,
794×924, 880×400 and 1280×720 — 46 states per box, **zero findings at every one**
— and carry no finding of their own at 130 % text with larger targets, where the
box's own pre-existing bottom-right chip overlaps (doc 91 D-12's family) are
unchanged at 78 findings across the deck on both sides.

**What Wave 11 did NOT add, and ruled instead.** `RoadNetwork.cmd_road_repair`
gets no card: doc 93 §J3 and doc 10 §2.13 rule road condition the automatic
repair policy's job, partly *because* this doc has no road-condition overlay and
a `Repair` run ghost could not say which tiles it was billing for. What that
leaves open is a settings row for the policy's two dials, which §2.13's sheet
already has the `policy:` mechanism for.

### Wave-11 deltas — the bottom-right corner, and the two sheets that outgrew the phone (2026-08-20)

Both of these had been in every `--audit` sweep since the accessibility settings
were first swept, and both are the same shape of bug D-13b was: **a container
asked for more width than the display has, and `grow_horizontal = BOTH` centred
the overflow rather than clipping it.** The sweep that found them is
`tools/ui_preview.gd --screen=all --audit` at each supported box, run twice —
once at 100 % text and once at 130 % with larger touch targets.

| # | Delta | Where | Why |
|---|---|---|---|
| D-46 | **The bottom-right corner is a solved rail, not three authored offset pairs.** `UIWidgets.corner_slot()` / `UIWidgets.solve_corner_rail()`, the mirror of D-13's left-hand `rail_slot()`. The incident drawer's **handle is the tab and keeps the edge** (D-16's priority, made explicit: it is a bookmark on the display's border and reads as one only there); the alerts chip takes the first rung of the column beside it and the event-log chip the second, each slot as tall as the chips measure and `rail_gap_dp` apart. Membership is duck-typed like `close_siblings()` — a screen joins by answering `corner_rail_entry()` with `{control, index}` — so a hidden affordance is skipped and the ones above it close the gap. New tunable `layout.corner_rail_margin_dp` (92). | §2.3, §2.6, D-16 | Three affordances, three files, three hard-coded offset pairs sized for a 48 dp target. At 130 % text with larger targets the chips measure **100 dp** tall against a 56 dp pitch and the handle **94 dp** wide against a 56 dp reserve, so the alerts chip covered **1 848 px²** of the event-log chip (**3 872 px²** on the first frame, before the old per-frame reposition had run) and the handle covered **2 736 px²** of the log chip. That is **73 `overlapping_targets` findings on every box — 360, 412, 794, 880 and 1280 alike — across 36 of the 50 preview screens**: every screen where the HUD is behind whatever is open. At 100 % with 48 dp targets the solver reproduces the scene's authored offsets *exactly* (−92 / −140 / −56 / −128 and −148 / −196), which is why the reference box did not move. |
| D-47 | **A sheet row wraps rather than widening its sheet.** The settings row and the save slot's action group are `HFlowContainer`s, not `HBox`es. A flow container asks for its **widest child**; an `HBox` asks for the **sum**, and a full-screen modal on `ModalLayer` grows *both ways* from its anchored rect when its minimum exceeds it. | §2.2, §2.13, D-11/D-17 | `Emergency contractors` (201 dp) beside its value chip (183 dp) made a **392 dp** settings row → a 400 dp row list → a **420 dp sheet** centred on a 360 dp phone at x = −20, so the sheet's own ✕ ended at **380 dp of 360** and `MANAGE SAVES` was laid out 400 dp wide starting 20 dp off the left edge. The save sheet reached the same 420 dp by a different road: `SAVE · LOAD · DELETE` measure 110 + 120 + 134 = **380 dp** of `HBox`. Wrapping costs nothing at the reference box — at 880 dp both rows still lay out on one line with the label expanding and the value flush right — and it is the only fix that scales, because the widths are the player's text-size setting and will keep growing. |

**Measured, whole-deck, before → after** (`--screen=all --audit`, every finding
of every kind, 50 screens per cell):

| box | 100 % | 130 % + larger targets |
|---|---|---|
| 360 × 800 | 0 → 0 | **76 → 0** |
| 412 × 915 | 0 → 0 | **73 → 0** |
| 794 × 924 (Fold inner) | 0 → 0 | **73 → 0** |
| 880 × 400 (reference) | 0 → 0 | 226 → **153** |
| 1280 × 720 | 0 → 0 | **73 → 0** |

The 153 that remain are all on the 400 dp-**tall** landscape box and none of them
is a corner-rail or sheet finding: 147 are top-bar chips overlapping between
wrapped rows (`Chip_water` 96, `Chip_treasury` 49, `Chip_grid` 2 — D-1's second
row solved against a bar that is only 392 dp tall), and 6 are the title screen's
button row, the pause menu's `SAVE & QUIT` and an alert banner's `VIEW` running
off the bottom. Both are §2.4's and §2.19's to answer and are recorded here as
the next wave's work, not fixed by this one.

### Wave-12 deltas — the last doors, and the last accessibility corner (2026-08-20)

Two shipped sim verbs had no player surface at all (doc 91 A91-D-24, doc 10
§2.13's open question), and the 130 % sweep had one box left that was not clean
(A91-D-21's siblings A91-D-22 and A91-D-23). Both halves are closed here. The
deck stands at **52** named states, and the sweep is **zero findings at all
five boxes on both accessibility settings** for the first time.

| # | Delta | Where | Why |
|---|---|---|---|
| D-48 | **§2.6's assigned-unit chips ship, so `cmd_recall_unit` has a door.** One 48 dp chip per unit in the drawer's actions row, tapping it emits `recall_requested(unit_id, incident_id)`; `UIRoot.bind_recall()` is the one wire and without it the chips are not drawn. The actions row became an `HFlowContainer` in the same change. | §2.6, doc 06 §2.11 | Doc 91 A91-D-24: `CitySim.cmd_recall_unit` had **zero callers anywhere in the repository** — not a door, not a harness, not even a test, because the one test that exercises recall calls `DispatchSystem` directly. A player who sent an engine to the wrong fire could not take it back, and the two-line wrapper that would let them was already written. |
| D-49 | **A recall that cannot happen is refused, in words.** `DispatchSystem.cmd_recall_unit` accepts `RESPONDING` and `ON_SCENE` and answers `E_UNIT_NOT_DEPLOYED` (carrying the status) for everything else; `RequirementFormatter` gained that code plus `E_UNKNOWN_UNIT` and `E_BAD_THRESHOLD`. | doc 06 §2.11, §2.7 | `FleetSystem.recall()` had always no-opped on `IDLE`/`OFFLINE`, so the command answered `ok` for doing nothing. Invisible while the verb had no caller; a lie the moment it had one. |
| D-50 | **§2.13 grows doc 10's two auto-repair dials** (`policy: "roads"`), and `CitySim` grows the wrapper they bind to. The threshold ladder is `data/roads.json`'s own; a change writes the PAIR. New row field `zero_key` for a ladder whose bottom rung is a state. | §2.13, doc 10 §2.13, doc 93 §J3 | The last doorless verb after D-48. Doc 93 §J3 rules road condition the *policy's* job rather than a per-tile verb, which makes these two dials the entire player say over it — and doc 10's own §9.4 question 5 asked for a dial precisely so the default would stop being a permanent ruling. |
| D-51 | **§2.4's solver has a second axis.** `solve_top_bar` takes a height budget and a row height and reserves one row of height per wrapped row; `HudModel.top_bar_left_inset()` steps the bar right of §2.3's rail column when even one row will not clear it. Both pure, both headless-tested; an unbounded budget reproduces the old solver exactly. | §2.4, D-1, A91-D-23 | The bar solved width and had no opinion about height. At 880 × 400 / 130 % / larger targets two 100 dp rows ran to y 212 through a rail that starts at y 89: **156 `overlapping_targets` findings, every state, at this document's own reference box.** The arithmetic has no answer that keeps both in the column (407 dp wanted, 392 available), so the bar yields — it is the *rare* affordance and the rail carries the frequent ones. |
| D-52 | **A centred card never outgrows the display.** `UIWidgets.wrap_in_scroller()` + `UIWidgets.card_height()`, applied to S0's panel and the pause menu: the body scrolls and the card is capped at `H − 2 × 8`. | §2.2, §2.11, A91-D-22/D-29 | The full-rect modals (S8/S9/S14) already had the scroller pattern; the two CENTRED cards did not, and a `CenterContainer` lays a child out at exactly its minimum — so a 449 dp card on a 400 dp box hung off both ends. `SETTINGS` at y 353…449, the confirmation's `CANCEL` at y 430…526, `SAVE & QUIT` at y 324…420. |
| D-53 | **The sweep instrument gained `--rects=SUBSTRING`** and two bindings it was missing (`bind_recall`, `bind_road_policy`). | tools | An overlap finding names two rects; *fixing* one needs the rects of everything else in that column, which only a laid-out tree has. And a preview that does not bind what `game/main.gd` binds photographs a deck the shipped game does not have. |

**Preview states added** (`tools/ui_preview.gd`): none — D-48's chips ride
`drawer_expanded` and `drawer_water`, whose fixture incidents already carry
assigned units, and D-50's rows ride `settings`.

**Measured, whole-deck, before → after** (`--screen=all --audit`, every finding
of every kind, 52 states per cell):

| box | 100 % | 130 % + larger targets |
|---|---|---|
| 360 × 800 | 0 → 0 | 0 → 0 |
| 412 × 915 | 0 → 0 | 0 → 0 |
| 794 × 924 (Fold inner) | 0 → 0 | 0 → 0 |
| 880 × 400 (reference) | 0 → 0 | **162 → 0** |
| 1280 × 720 | 0 → 0 | 0 → 0 |

The 162 are the 153 the Wave-11 note recorded plus the two states the deck has
gained since: 156 top-bar overlaps (`Chip_water` 102, `Chip_treasury` 52,
`Chip_grid` 2) and the same 6 offscreen controls. **The Wave-11 note's
characterisation of those 147 was wrong and is corrected here**: they are not
chips overlapping *each other* between wrapped rows — the rows are a
`VBoxContainer` and cannot — they are chips overlapping `LeftRail/SpeedButton`
and `OverlayRail/Button`, which is what A91-D-23 filed and what D-51 fixes. **A2 and A3 are now green at every box the
project tests.** What is still not measured is A2's own stated geometry — 150 %
at 640 × 340 — which is A91-D-29 and is not this wave's.

### Wave-13 deltas — the accessibility root fix, and the veil (2026-08-20)

| id | change | doc ref | why |
|---|---|---|---|
| D-54 | **A themed button's padding is scaled exactly once.** `ThemeBuilder.build()` passes `touch_min_dp(cfg, 1.0, larger)` into `_button()` instead of the already-scaled figure. One line, and a no-op at `text_scale == 1.0` — the two numbers agree there, which is why no screenshot in the repository moves. | §4.3, A2, A3 | **The root cause under every A2/A3 defect this document has ever filed.** `_button()` derived `pad_v` from a touch minimum that had already been multiplied by the text scale, and `scale_theme()` then multiplied every content margin again. At 130 % with larger targets a `StatChip` measured **100 dp against an A3 floor of 73**; at 150 %, **117 against 84**. That 37 % surplus on every themed button is the 89 × 100 chip of A91-D-21, the 94 dp handle of D-46 and the 407-against-392 top bar of D-51. Whole deck, six boxes × three scales: **408 findings → 8**, with the 100 % row unchanged at zero. Gated by `test_ui_scaffold.gd::test_a_button_stylebox_is_scaled_exactly_once`, which fails on the old theme with `a StatChip's own box is 95 dp against an A3 floor of 73`. |
| D-55 | **A full-rect modal's CONTENT scrolls; only its chrome does not.** `UIWidgets.scroll_into()`, applied to S9's About block: the header and `MANAGE SAVES` stay put and the About text joins the rows inside the scroller. | §2.2, §2.13, D-47/D-52 | The full-rect sibling of D-52. A panel anchored to the display with `grow_* = BOTH` does not clip when its minimum exceeds its rect — it grows through **both** edges. S9's body is `Header + Scroll + About + Saves` and only the rows were inside the scroller, so 164 dp of plain About text made a 343 dp body against 284 dp of panel: the sheet's own ✕ at **y −1.5** and `MANAGE SAVES` 1.5 dp past the bottom, at 640 × 340 / 130 %, and 29 dp / 29 dp at 150 %. |
| D-56 | **§2.8's facts block is one column of wrapping rows, not two rigid ones.** `GridContainer.columns = 1` with an `HFlowContainer` per fact. | §2.8, D-47 | D-47's rule, third instance. A two-column grid asks for the sum of its two widest columns and the land panel is `clamp(0.34·W, 260, 340)` dp *whatever the display is*, so there is no width at which the sum fits. At 150 % `Time to develop` (188 dp) beside `18 of 24 tiles` (151 dp) made a 347 dp grid against 328 dp of interior and put `PURCHASE $12,600` at **x −11** on a 360 dp phone. |
| D-57 | **§2.17's coach bubble wraps its buttons, and measures itself twice.** The button row is an `HFlowContainer`, and `_layout_bubble()` re-reads the bubble's minimum height after `sort_tree` has laid the row out at the width it just chose. | §2.17, D-47 | D-47's rule, fourth instance, plus the defect the fix surfaces. `Skip tutorial` (202 dp) + `GOT IT` (118 dp) in an `HBox` is a 336 dp row, a 360 dp bubble and a 352 dp safe area: `GOT IT` at x 246 … **364**. Wrapping fixes the width and breaks the height, because **a flow container's minimum height is a function of its width** and the bubble's width is derived from its own minimum — measured once, the two-line row is placed as a one-line row and `GOT IT` lands 64 dp below the display. |
| D-58 | **640 × 340 dp is a gate box.** `tests/test_ui_audit.gd::BOXES` and `tools/ui_preview.gd`'s sweep list both carry `data/ui.json.layout.min_safe_box_dp`, added in the same commit as D-55 … D-57. | §2.18 A2, A91-D-29 | The project authored its own minimum safe box and then tested every box except that one. A requirement whose own geometry nothing runs is not a gate — which is how a 26 dp overflow on the title screen's CANCEL survived three waves of green sweeps. |
| D-59 | **§2.3's LEFT rail is one solved stack, like D-46's right one.** `UIWidgets.solve_rail_stack()` computes **one pitch** for the whole column and places every member; `UIRoot` owns the call, because the three members are not siblings (the FAB is on `SheetLayer`) and nobody could find them by walking a parent. Membership is duck-typed — a screen joins by answering `rail_entry()`. | §2.3, D-46, D-51 | Three files placed three controls against three separate measurements, and two of them were taken at different moments: `OverlayRail._build_button()` places inside `setup()`, before the theme has propagated and before anything is laid out, so it read its own `custom_minimum_size` — **73 dp** at 880 × 400 / 130 % — while `CityHUD.refresh()` re-places the speed rail every frame and read the laid-out **93**. Two pitches, one column: the overlay button at y 210 … 303 and the speed rail at y 89 … 182, **28 dp of gap where `rail_gap_dp` says 8**, and `HudModel.top_bar_left_inset()` solving the bar against a rail top no button actually had. Indices are fixed and gaps are not closed: the FAB hides during placement, and a rail button that slid down to take its slot would move under the player's thumb mid-gesture. |
| D-60 | **S15, the loading veil, ships** — `ui/veil_model.gd` (headless) + `ui/loading_veil.gd` (code-built) on a new `VeilLayer`, with `UIRoot.present_veil_load/…_catchup/dismiss_veil` and two preview states. §2.20 has the screen. | §2.2, §2.20, doc 13 §2.9/§2.9.1 | Doc 13 has assumed a veil since it was written; the restore is eleven resumable steps and the catch-up has always been sliceable, and **both levers were built with neither having a surface**. The title door standing in for it covered CONTINUE and nothing else. One deviation, argued in §2.20 item 2: doc 13 §2.9.1 asks for a spinner over the restore and this is a stepped bar with its unit named under it. |

| D-61 | **The pick's zeroth arm: a street opportunity outranks a building, by a RADIUS.** `BuildController.pick_at_ground` gained `PICK_OPPORTUNITY` in front of §2.8's three answers; the radius is `data/ui.json.street.tap_dp` (48) converted at the current zoom by `set_tap_radius_from(CameraState.m_per_dp(viewport))`, and the roster asked is the **sim's** (`sim.street.opportunity_near`), never the render view. §2.21 has the argument. | §2.8, §2.16, §2.21 | A collectable is a 32 dp character standing on a tile some house already owns, so a tile-decided pick hands every tap on one to the building panel behind it — the player's finger is on the animal and the game opens a building. Everything else on the pick list is a thing they built and can find again in a second; this one is leaving. A fixed metre radius could not work at both ends of a 5 m-to-100 m zoom range, which is why the conversion is the shell's per tap. |
| D-62 | **The payday is one cue, one chip and one sentence, whatever door it came through.** `AudioService.UI_CASH` + a `data/audio.json` rule on `incident_resolved` with `range: {reward: {min: 1}}`, both resolving to the `cash` cue; `HudModel.flash_chip()` for the treasury chip's deposit pulse; `ui_bounty_toast*` for the copy. | §2.4, §2.5, §2.14, §2.15, §2.21 | **`incident_resolved` has carried `reward` since doc 06 shipped and nothing had ever sounded it, toasted it or counted it.** The automatic dispatch the 2026-08-21 playtest asked to be paid for was already paying, silently, which a player cannot tell apart from not paying. §2.5's chip pulse was a STATE (the grid is below 60 %); this is the other kind — a chip that pulses because something happened to it — and it reuses the same `chip["pulse"]` → `meta` → 1.2 Hz alpha path, so A8's suppression covers both without a second branch. |
| D-63 | **A one-shot NOTICE is not a tutorial step.** `OnboardingFlow.show_notice()` borrows §2.17's mark — the dim, the cutout, the 240 dp bubble — with no step counter, no `Skip tutorial` (`CoachMark` reads `show_skip`, defaulting true), no advance condition and no row in `data/ui.json.onboarding.steps`. A live step always wins; a notice raised during one is owed and goes up when the tutorial finishes, skipped included. | §2.17, §2.21, §3.2 | The balance suite counts the tutorial's steps (gate 21). A curriculum whose length depended on what the director happened to spawn would not be a curriculum — and a mark that offered to `Skip tutorial` would be offering to skip something that is not running, or on a graduated player something that no longer exists. |
| D-64 | **The Economy ledger may carry a revenue line doc 03 does not settle**, through `BudgetModel.feed_side_revenue()`; a key the settle snapshot **does** carry is taken from the snapshot, always. `data/ui.json.budget.revenue_keys` gained `bounties` and `street`. | §2.10, §2.21, doc 03 §2.4 | A bounty is `Treasury.credit(amount, &"incident", …)` — a direct credit that never passes `EconomySystem.settle_hour` — so **no row of this ledger has ever contained one and its NET was short by exactly that much on every hour a crew answered a call.** A row the column shows but the total does not contain would be a second, worse defect, so the side total moves `gross` and `net` too. The precedence rule is what retires this: the day doc 03 publishes `revenue.bounties`, the sim's number wins with no edit here and no chance of double-counting. |
| D-65 | **The chip solve re-runs when the HUD's own rect changes.** `CityHUD._notification(NOTIFICATION_RESIZED)` queues one deferred `refresh(_last_snapshot)`; `tests/test_hud_model.gd::test_resize_re_solves_the_chip_rows` pins it. | §2.4 | Wave 15's merge found the treasury and goals chips at x = −121.5 and −11.5 in the 880 × 400 audit box (a finding both Wave-15 render branches proved **pre-existing at the Wave-14 merge**, against item 27's zero-findings claim). The solve is priced against the width `refresh()` ran at, and `refresh()` arrives on the SIM cadence — so any width change between ticks kept the stale answer: the harness resizing after its one boot refresh, a desktop drag, and on the reference device **the Fold folding or unfolding while paused**. Wave 14's chip set (payday, stability) pushed the full row past the audit box's width, and D-12's own mechanism finished the job: a row solved wider than the new box is centred whole by `grow_horizontal`, off the left edge. The defect was never the solver's arithmetic — it was that nothing owned re-running it; now the view does. Item 27's whole-deck claim is re-measured true at this fork: `--screen=all --audit --strict`, exit 0. |
| D-73 | **The repair row leaves the private stock, and the one refusal a player must never read.** `BuildController.repair_view` folds `E_OWNER_MAINTAINED` into "nothing to buy" beside `E_NOT_DAMAGED`, so a house draws no REPAIR row at any condition; `RequirementFormatter.format` accepts a `fix_kind` override and `_check_params` uses it to drop `Fix this →` from `E_CONDITION` on private stock, where the remedy is not a purchase; `ui_requirement_e_condition_remedy` becomes true of both parties; three `ui_requirement_e_owner_maintained_*` strings exist so the code can never print itself; `ui_settings_auto_repair_cost_cap_hint` names the assets the city actually repairs; `tools/ui_preview.gd`'s `building_repairable` state and four `test_build_controller.gd` cases move from `H-001` onto `POL-1`. `RenderStateModel` grows a `building_repaired` branch that clears the soot and the WARNING tint. And the Economy tab's `ui_budget_expense_building_maint` row is relabelled **`Building upkeep` -> `Building services`**. | §2.9 item 6, §2.15, §2.19, A8, doc 02 §2.6a, doc 93 §Y1/§Y3a | The 2026-09-01 playtest: *"we shouldn't have to interrupt the gameplay to repair buildings because nothing actually happened."* Measured (doc 92 §43.1): the REPAIR row was drawn on **260 private and 21 civic** buildings in one 21-game-day `balanced` city and on **98 / 10** in a `curriculum` one, because `repair_view` drew it for anything under condition 1.00 — while `data/notifications.json` has no building condition binding at all, so the interruption was never an alert to silence, it was an affordance to stop drawing. After the ruling it is **0 private** on every strategy. The `fix_kind` override is the second half: `E_CONDITION` still blocks an upgrade on a worn house, and a `Fix this →` that buys a repair the sim now refuses would be PA-24's failure shape in a new place — a button that cannot work, on a row that reads as if it can. `building_repaired` had been emitted since doc 02 §2.6 shipped and consumed by nothing, so a repaired building kept its soot; §2.6a makes that visible rather than rare, because a private building damaged by an incident now un-damages itself with no player action and nothing else was coming to clear it. **The relabel is the cheapest row here and possibly the most useful**: `Building upkeep` sits directly above the REPAIR button in the player's mental model and reads as *the city paying a landlord's repair bill*, which is exactly the misreading that sent this wave's own first draft down a blind alley for half a day (doc 92 §43.8). The line is the city's cost of SERVING those buildings and the label now says so. |

| D-76 | **`degenerate_label` joins the audit, and the goals sheet's standing line gets its own row.** `UIAudit.KIND_DEGENERATE_LABEL`: a visible wrapping `Label` laid out narrower than one em of its own font; `tests/test_ui_audit.gd` pins it. `ui/goals_sheet.gd` moves `Standing` out of the head HBox onto a wrap + `EXPAND_FILL` row on `Intent`'s terms. | §2.19, §7 item 27 | The 2026-09-01 production audit found the standing line rendering **one character per line, 1 px wide and 1,101 px tall**, on every box — with the objectives pushed 540 dp down the sheet — and every prior `--audit --strict` sweep had called the screen clean, because no check measured a label against its own font: an HBox hands a non-expanding wrapping label its minimum width, one glyph, and `clipped_text` cannot see a label that is not clipping but stacking. Measured after: `Standing` 800×20 at 880×400; whole deck exit 0 with the new kind armed. |
| D-77 | **Two capped-catch-up surfaces that could not tell the truth, and one that could not fire at all.** `ui_veil_catchup_capped` had "12 hours" written into the string; it now takes `{hours}`, and `VeilModel.begin_catchup` / `LoadingVeil.present_catchup` / `UIRoot.present_veil_catchup` take a `cap_real_hours` (defaulting to 12, so no existing caller changes). `ui/away_model.gd`'s `capped_text` is reachable at last: the shell's report dictionary now carries `capped` and `cap_game_hours` straight out of the plan. | §2.12, §2.20, doc 08 §2.12, doc 13 §2.9 | Wave 17 implemented doc 08 §2.12's NORMATIVE `max_coarse_hours` clamp (report 98 §48, RR-133), which ships at **360 game-hours = 6 real hours** — so the veil's "12 hours" became a sentence the game does not mean, and a player told the wrong number about their own missing time has been lied to in exactly the place A14 says a refusal must be stated in words. The away line was worse: `capped_text` has existed since S12 and `game/main.gd`'s `present_away_report` dictionary **had no `capped` key at all**, so the branch was dead from the day it was written and no `--audit` sweep could ever have seen it — a screenshot of a line that never renders looks exactly like a line with nothing to say. `tests/test_catchup_clamp.gd` pins both surfaces against the cap that was actually applied. |

| D-70 | **The building panel names the wire.** A POWER section under the water block (`ui/power_actions.gd` headless, rendered by `ui/building_panel.gd::_render_power`): one row per hop of `PowerGrid.service_path()` — transformer, feeder, substation — each with its id, how many buildings hang off it, what it carries **now**, what it carries **at the day's peak**, the spare capacity **in words**, §5.10's band, and its own `UPGRADE` button with the price on its face. Under them, the next level's headroom answer, whether or not it refuses. | §2.9, doc 04 §2.2 | The user, twice: *"feeders adding extra power to a building is not clear and I'm not sure it actually works"*, and *"how the transformers feed power … doesn't seem to be working well at all."* Both were true readings of a panel that had a `⚡ 98 kW` vital and no way to find out what that 98 kW came through. The section is a LIST OF HOPS rather than a summary because the answer to a full grid is different at every hop — a bigger transformer, heavier copper, a bigger substation — and a player who cannot see which hop is full cannot pick. The peak column is the other half: doc 01's residential channel swings 0.67 → 1.46 across a day, so "62 kW spare" read at 05:00 is not a fact about the evening. |
| D-71 | **`Fix this →` on a `POWER_CAPACITY` row performs a PURCHASE, in place.** `RequirementFormatter.FIX_POWER` (new fix kind; the row moved off `FIX_BUILDING`), answered by `BuildingPanel._on_fix_pressed` rather than emitted to the shell's camera router, and completed by a **two-tap confirm strip**: the first tap quotes `CitySim.cmd_fix_power_capacity(preview)`, the second buys it. The strip names the action, the component and the price, and says so when one purchase clears only part of it. | §2.7, §2.9 | The lead's reproduction: `POWER_CAPACITY`'s fix kind was `FIX_BUILDING`, and `game/main.gd`'s router answers that kind by focusing the camera on the building — **the building the player already has open**. §2.7 calls this row "the single most important teaching device in the game" and on the one requirement the player meets most often it moved nothing (A91-D-54). The one-tap door already existed underneath (`cmd_route_feeder`) and was reachable only from the BUILD sheet's drag cards, which is not where a refusal is read. Other `FIX_BUILDING` kinds keep focus-only **deliberately**: `E_STATE` and `E_NO_SLOT` name a DIFFERENT building than the one on screen (the failed shell, the full substation), so a camera move is the whole of the useful answer. |
| D-72 | **A grid reading on the §2.5 legend card**, not the dashboard: `UIRoot.power_summary_lines()` builds §2.5's three aggregate lines from `PowerActions.grid_reading()` — the pool (demand of supply, spare), the **wires** (how many transformers and feeders are at WARNING or worse), and either what is being held dark or which half of the grid is the wall. Preview state `overlay_power`. | §2.5, §2.10 | §2.10's Infrastructure tab already lists every feeder and transformer — that is the REFERENCE reading, a table you go and consult. This is the ORIENTING one, and it belongs where the player is when the question occurs to them, which is standing in the power overlay looking at a red transformer. The second line is why the row exists at all: on every city audited this wave the pool had headroom (starter **6 %**, benchmark **56 %**) and the transformers were the wall (**1 of 1** and **140 of 140** blockers bound at a transformer), so a reading that showed supply against demand alone told the player to buy a power station — and a power station cleared nothing. |

**Preview states added** (`tools/ui_preview.gd`): `veil_load`, `veil_catchup` —
S15's two phases, added in the same commit as the screen (A91-D-28's lesson) —
and, at Wave 14, `street_coach` and `economy_street` (D-61 … D-64), on the same
terms. The deck is 55 states, then **57**. Both new states are **clean at all six
`BOXES` × both accessibility settings** — 24 sweeps, `--audit --strict`, exit 0.

At Wave 17, three more on the same terms (D-70 … D-72): `building_power` and
`building_power_fix` — the POWER section with the wire in good shape and with the
next level refused, the second one found rather than fabricated (the harness asks
`cmd_upgrade_building(preview)` for the first building the shipped city actually
refuses on power) — and `overlay_power`, the §2.5 legend card carrying the grid
reading. **The deck is 60 states**, and the whole sweep is clean:
`--screen=all --size=412x915 --audit --strict` → 60 states, 60 clean, 0 findings,
exit 0.

**Measured, whole-deck, before → after** (`--screen=all --audit --strict`, every
finding of every kind, **six** boxes × **three** text scales; 53 states per cell
at the fork, 55 after): the table is in §2.18. **408 → 0**, with the 100 % row
unchanged at zero on every box — including 640 × 340, which no `BOXES` list in
this repository contained until D-58.

### Wave-17 deltas — the queue surface (2026-09-01)

| id | change | doc ref | why |
|---|---|---|---|
| D-66 | **S16, the construction queue, ships** — `ui/construction_queue_model.gd` (headless: the contract row verbatim, the sort, the words, the affordability reading, the rush door, the spend record) + `ui/construction_queue_sheet.gd` (code-built rows on a `PanelLayer` side panel, a `⚒ n` chip on rung 3 of the corner rail) + S5's inline `Progress` block + `data/audio.json`'s `construction_rushed → purchase` rule + four preview states. `UIRoot.bind_construction(provider, rush, treasury)` is the one shell call; the camera jump rides `set_incident_locator()`, the cue rides `data/audio.json` and the toast/pulse ride `feed_events()`, all of which the shell already makes. §2.22 has the screen; doc 93 §AB1 the one-tap ruling; doc 91 A91-D-49 the defect. | §2.2, §2.3, §2.22, §4.4, §4.5 | The sim has carried jobs, crews, progress and ETAs since doc 02 shipped and nothing on screen showed any of it. Built against the seam CONTRACT through a provider `Callable`, hash-neutral by construction: all four `profile_sim` baselines are byte-identical at this fork (`a27da24a…` / `7745cb25…`, `7c99720f…` / `d8e88896…`). The three `ui_land_time_*` keys became the neutral `ui_time_*` and their arithmetic moved to `UIWidgets.duration_text()` — one span, two screens, one place to drift. |
| D-67 | **The corner rail wraps before it overflows, and three findings from building on it.** (a) `UIWidgets.solve_corner_rail()` takes `host_h` and `corner_rail_capacity()` fits `floor((H − margin + gap)/(pitch + gap))` chips per column before starting a second one; `0` is the old column byte for byte. (b) `tools/ui_preview.gd --screen=<one>` now waits two whole frames, not just the settle window. (c) `UIWidgets.release_children()` — detach now, free at frame end — for a list rebuilt from inside its own child's signal. | §2.3, §2.22, D-46, doc 93 §AB2, report 98 RR-111/RR-113 | (a) At 640 × 340 with 150 % text and larger targets a chip measures 92 dp and rung 3 would have been placed with its top edge at window `y −48` — **48 dp above the display** — and the queue chip is that rung. Measured, not assumed: `tests/test_ui_audit.gd::test_the_corner_rail_wraps_before_it_overflows` pins 2 per column there and 5 at the reference box. (b) A parent's `_process` runs before its children's and the first frame's `delta` carries the boot, so a single-state audit measured a deck no chip had processed: three states × six boxes reported **46** `overlapping_targets` — every finding of that one kind — on a tree `--screen=all` called clean in all eighteen sweep cells; after the guard, **0** in all eighteen single-state runs. Doc 92 §46.3 has the table. (c) The RUSH press removes the row it sits in, and `clear_children()`'s immediate `free()` on the emitting button is an engine error and a potential crash. It surfaces as ENGINE OUTPUT and not as a failed assertion, which is the part worth writing down: with `clear_children()` restored, test 31 still passes 22/22 while the run prints `Object … was freed or unreferenced while a signal is being emitted from it`; with `release_children()` that line is gone. A green suite is not the whole of the evidence — the log is. |

### Wave-17 deltas — the camera learns to look up (2026-09-01)

| id | change | doc ref | why |
|---|---|---|---|
| D-68 | **The camera joins the `ui` save section**, through `UIRoot.bind_camera()` + `CameraState.to_dict/from_dict`: `camera = {focus_x, focus_z, zoom_t, yaw_deg, pitch_mode, pitch_bias}`, written only when a camera is bound and validated against **this build's** band on the way back in. | §2.16, §2.23, §3.2, D-9 | D-9 has owed the camera keys since §3.2 was written; the manual pitch axis is what made the debt visible, because a player who leans the camera and quits now loses a *pose they chose* rather than a default they never noticed. `pitch_mode` is a word and not just a number because AUTO is a promise about what the next pinch does, not a value: a save carrying `pitch_bias = 0.0` alone cannot say whether the player was in AUTO or had parked the lean on the curve. The re-composition on restore is the same argument as D-16's stand-down — data may retune between builds, and a save may not resurrect an angle the band no longer allows. |
| D-69 | **The right-edge tilt column, and the third arm of the MULTI gesture** — `ui/tilt_slider.gd` on `HUDLayer`, solved by `UIRoot.solve_tilt_slider()` into the band between the top bar's first row and the corner rail's reservation; `GestureRecognizer`'s `tilt_begin/tilt/tilt_end` and `TouchInput`'s handling of them. Preview states `tilt_rest`, `tilt_drag`. §2.23 has the screen. | §2.3, §2.16, §2.18 A3/A8, §2.23 | The user asked for the control by name and by geometry ("on the right side of the screen… vertically… sits in the middle"), and a camera axis with only a gesture would be an axis most players never discover — the pinch is learned, a two-finger vertical drag is not. Two things the solve is deliberately not: it is **not centred in the safe area** (the drawer handle owns 60…220 dp of that edge, and a naively centred column lands on it at every landscape box), and it is **not a control that shrinks below a usable one** — under 96 dp of band it stands down entirely, D-16's rule, because at 640 × 340 the honest answer is that this edge has no room and the two-finger gesture is still there. |

**Preview states added** (`tools/ui_preview.gd`): `tilt_rest`, `tilt_drag` —
the resting (ghosted, thumb on the detent) and mid-drag faces, added in the
same commit as the control (A91-D-28's lesson). The deck is **59** states.
Swept at five boxes — 412×915, 640×340, 794×924, 880×400, 1280×720 — plus
360×800 at 130 % with large targets: `--screen=all --audit --strict`, **exit 0**
at every one. At 640 × 340 the column stands down and the sweep is clean
because there is nothing there to find, which is the intended answer.

### Wave-17 deltas — the refresh row (2026-09-01)

| id | change | doc ref | why |
|---|---|---|---|
| D-75 | **S9 gains one 48 dp cycling row, `Refresh rate` — Auto / 60 / 120 / Off**, immediately under Graphics. `data/ui.json.settings.rows.refresh_rate` is a `choice` whose ladder is `options_from: "refresh_modes"` → `data/render.json.refresh.settings_modes` and whose default is `defaults.refresh_rate` (`auto`); `value_text_from: "refresh"` resolves `ui_settings_value_refresh_*` with no branch in `SettingsModel.value_text()`. Device-scoped, beside the preset it modulates. `ui/settings_model.gd` gains one option source and nothing else; the sheet is untouched, because a row is data. | §2.13, §3.2, doc 13 §2.8, report 98 RR-126 | **The game caps its frame rate and had never told the screen.** On the reference device — a Fold 6 with a 1–120 Hz LTPO inner panel — the platform then infers a mode from the app's observed cadence and re-derives it whenever the cadence changes, which is what the player reports as bands *"only in the sub menus"*: a sheet opening over a still world is a workload step with no camera motion to hide the re-time (doc 93 §AE). The row exists for two reasons and one of them is not a preference: **Off is the A/B's control arm**, the shipped behaviour, selectable without a second binary, and Auto is what a player who never opens this screen gets. `90` is on the `--refresh=` lever and deliberately **not** on this ladder — the reference panel has no 90 Hz mode to land on, and a row offering a mode the phone cannot enter is a control that lies (the same rule §2.13's road-repair ladder already follows). |

**One row, and it is a real one.** `refresh_rate` writes no sim state and takes no
`policy`: it is a device preference like `graphics`, and the shell hands its value
to `RefreshPin.set_mode()` the way it hands `auto_quality` to
`PerfGovernor.enabled`. Round-tripped and migration-tested in
`tests/test_ui_settings.gd` (`…_round_trips_and_refuses_a_mode_the_pin_would_not_take`):
a saved `"240"` from a build whose ladder was longer is **dropped for its
default**, which is §3.2's promise applied to a row that did not exist last wave.

### Wave-17 deltas — the render fork: one dev arm and one preset that changed what it draws (2026-09-01)

*No screen, no string and no sheet moved. Three things a UI reader still has to
know, because one is a lever the lead pulls from a shell argument and the other
two change what the Graphics row's values LOOK like — one of them for the first
time.*

| id | change | doc ref | why |
|---|---|---|---|
| D-74 | **`--road-tint=K` joins `--road-detail=` and `--pad-shadows=` in `Main._apply_render_ab_args`** (the lead's file; the two-line snippet is in the Wave-17 branch report, anchored on the `--pad-shadows=` arm). It multiplies doc 11 §2.1.2's carriageway tint by `K` in linear via `RoadSurfaceView.set_tint_gain(k)` — one uniform, live, no rebuild, byte-identical at `1.0`. **It is an A/B ARM, not a setting**: no settings row, no persisted key, no string, and it must never grow one — the ruling it feeds is DEVICE-GATED and not taken (doc 93 §X3, report 98 RR-97). **And the Graphics row's `Performance` value now draws a contact shadow under every building** (doc 11 §2.11's `MM_blob`, report 98 RR-96): the settings description strings are unchanged, because none of them promised "no shadows" — `ui_settings_value_graphics_performance` is one word — but a screenshot of that preset taken before this wave is no longer a picture of it. `tools/profile_frame --blob=0\|1` is the A/B. | doc 11 §2.1.2 / §2.11, doc 93 §X2 / §X3 | A dev arm that lives only in the shell is invisible to this document's reader unless it is recorded here, and a preset whose look changed without a string changing is exactly the kind of drift §2.18's screenshot rows exist to catch. |
| D-74b | **The Graphics row now changes the picture.** Doc 11 §2.13b, report 98 RR-98: twenty-two engine-side keys in every preset — `render_scale`, `msaa`, `fxaa`, the shadow atlas, split count and distance, the glow ladder and its HDR thresholds, `env_adjustments` — were authored and read by nothing, so picking `High` bought more cars, more rain and more draw distance and **nothing else**. `render_scale` was read once in the whole tree, by `SettingsModel`, to SORT this row's values cheapest-first: the number that decided the order of the options was the number that did nothing when you chose one. They are live now. **No string, no key and no layout moved** — `ui_settings_value_graphics_*` are unchanged and were never wrong, because none of them promised a resolution — but the 3D framebuffer is now 1344×756 at `Performance` and 1920×1080 at `High` on a 1080p device, `Performance` renders with FXAA and no sun shadow, `High` with 2× MSAA and four shadow splits, and **a screenshot of any of the three taken before this wave is no longer a picture of it**. §2.18's screenshot rows are the ones that go stale. The A/B is `tools/profile_frame --no-quality`, which reproduces the old frame exactly. | doc 11 §2.13b, doc 93 §X5 | A settings row whose values were visually indistinguishable is a row that lied to the player by omission, and the fix changes what three of this document's screens show without changing a single string — which is precisely the drift §2.18 exists to catch. |

---

### Wave 18 delta — the ruin's row on S5 (2026-09-02)

*One row, on the one screen a player looks at when they are looking at rubble.
Rulings: doc 93 §AN6/§AN7. Verb: report 98 RR-155/157. Price: doc 92 §54.*

| id | change | doc ref | why |
|---|---|---|---|
| D-86 | **S5 draws a destroyed building's own block, and it is the only action that building gets.** `BuildController.restore_view()` (asking `CitySim.cmd_restore_building(…, true)`, so this file authors no gate) → `BuildingPanel._render_restore`: a note that says what happened in the terms the model holds — *"Destroyed 2h 30m ago. Rebuilds at level 3, condition as new."* — and one **primary 48 dp button, `RESTORE · $1,220`, with the price on its face**. **No confirm dialog** (§AB's precedent). Unaffordable does not blank it: the build-card pattern applies and the button goes disabled **with the price still showing** and the formatter's sentence under it. **The block draws what the sim will ACCEPT and hides what it refuses.** `REPAIR` and `DEMOLISH` both answer `E_STATE` on a ruin — the first because a ruin is not `active` or `damaged` (and on private stock `E_OWNER_MAINTAINED` fires first and hid the row entirely, so before this wave a burnt-out house's panel offered **no action at all**), the second because doc 02 §2.12 routes a ruin to `cmd_clear_rubble`, **which has no door either** and is A91-D-99's remaining half. Neither is drawn: a dead button beside the live one is the state this row exists to remove. `PRIORITY` stays, because `cmd_set_priority` ACCEPTS a ruin — the tier lives on the grid service record, which a destruction does not detach, and the tier set now is the one the restored building comes back with. Under the primary button, when the city has more than one ruin, a ghost **`RESTORE ALL 12 · $84,200`** with a note saying how far the money reaches — it stays LIVE below full affordability because the verb buys cheapest-first and stops at the wall. Preview states `building_destroyed` and `building_destroyed_broke`, same commit. | §2.9 item 6, doc 02 §2.12, doc 93 §AN6 | The player, on their own city, 2026-09-02: *"When buildings are destroyed, we should have a ONE BUTTON CLICK to just pay a fee and restore the building. That's it. I have many buildings that are destroyed that I can't actually fix even if I upgrade power."* They were right, and the reason is doc 91 A91-D-99: `Building.order_rebuild` had a model, a doc and a price and **no caller anywhere in the project**. The ruin was already selectable — the tiles stay stamped, so `pick_at_ground` resolves it and `building_view()` has no state guard — and the panel already opened. What it drew was a dead `REPAIR` with an `E_STATE` sentence, or nothing. **`RESTORE ALL` lives on the ruin's own panel and not on the dashboard on purpose:** a player looking at one ruin is exactly the player who has a dozen, and this is the moment they learn the city can come back in one tap. The dashboard's Upkeep band is the citywide home and is a deferral row below, because a sibling lane owns that file this wave. |

**What the row deliberately does NOT say.** The **cause** of the destruction —
which fire, which collapse. `Building.serialize()` is inside doc 08's save body
and inside `CitySim.state_hash()`, so persisting a cause field would move every
determinism baseline in the project on a **surface** change, and this is a
player-verb lane that moves none. The row therefore states the facts the model
actually holds: that it is down, how long it has been down, and the level it
comes back at. The fire itself is already published, with its cause, in §2.13's
event log at the hour it happened.

**What is left to a sibling — a deferral row, never a guess.**

| awaiting_consumer | what this screen does meanwhile | closes when |
| --- | --- | --- |
| the CITYWIDE `Restore all destroyed (N) · $Y` affordance, in `ui/city_dashboard.gd`'s **Upkeep band** — the surface a player checks *without* having tapped a ruin first | S5 carries the same offer on every ruin's own panel, so the verb is reachable from the moment the player looks at any one of them; the sim side is **shipped and tested** (`CitySim.cmd_restore_all_destroyed(preview)` answers `{count, cost, rows}` sorted cheapest-first, and `BuildController.restore_all_destroyed()` is the door) | the dashboard lane merges — this wave does not edit `ui/city_dashboard.gd`, which it does not own |
| a lifetime `Restores` row on the Economy ledger beside `Repairs` | the charge is visible in the treasury and in the hourly budget view under its own `&"restore"` category | doc 03 publishes the `ledger_totals` key, together with A91-D-37's `&"incident"` arm — one `state_hash` re-record for both, not two (doc 91 A91-D-100) |

**One string changed for a player-facing reason.** `ui_queue_source_rebuild`
reads **"Restore"**, not "Rebuild": the queue row and the button the player
pressed have to say the same word. `rebuild` stays the sim's job kind — the code
word and the player's word are allowed to differ; two *player* words for one
thing are not.

**The deck is 69 states**, the two new ones included; `--screen=all --audit
--strict` reads clean in every cell.
