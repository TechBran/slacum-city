# 91 — Completeness audit

**The honest ledger of what "completely built out" still lacks.**

> **CURRENT PROVENANCE — the WAVE-14 MERGE, `bdba0b7`, 2026-08-21, Godot 4.7.2.**
> **Every figure in this box was produced by running something at this commit.
> None of it is carried forward from a branch.**
>
> * **The count is 172 of 190 rows — 90 %**, or **91 %** of the 188 rows not
>   deferred by their own docs. The derivation is the table headed *THE COUNT,
>   RE-DERIVED ROW BY ROW AT THE WAVE-14 MERGE*, immediately before §0.5; it
>   supersedes the three count tables before it, and report 98 **RR-76** carries
>   the figure as the project's single quotable one. The arithmetic from the
>   Wave-13 `188 / 170` is printed there rather than asserted: **+1 basis and +1
>   SHIPPED for doc 11 §2.17, +1 and +1 for doc 12 §2.21, and nothing else moved.**
> * **The suite:** **124 test files / 2,209 tests / 534,614 asserts / 0 failed / 0 silent**, `ALL TESTS PASSED`, exit 0, **32 balance gates**. The Wave-13 line was 120 / 2,096 / 524,684; the four Wave-14 branches added four test files between them.
> * **Determinism, re-measured:** founding `a27da24aaf6e9663…` /
>   `d2dec6727c64001d…`, benchmark `7c99720f5ff14553…` / `8f60accb6d91ad1e…`.
>   **All four differ from all four sets any Wave-14 branch published**, because
>   two of the four branches wrote `sim/` and `data/`. §20.4 has the enumeration.
> * **The one-page answer to "are we done" is §20.4**, re-taken at this merge.
>   §20.5 is the Wave-13 marker sweep and **§20.6 is this edition's.**
>
> **Read the paragraph below before quoting anything above.** Four Wave-14
> branches each wrote a provenance line into this document and each was true
> about its own fork; this box previously *picked one of them* and printed it
> under the heading "CURRENT", so at the merge it named a suite and a determinism
> set that **`bdba0b7` does not produce** — verified by re-running both here.
> That is the RR-76 drift pattern for the fifth time and the second time inside
> the very box RR-76 added to stop it, so it is worth stating as a rule rather
> than as an apology: **a provenance box must be RE-MEASURED at the commit it
> names, and if it cannot be, it must say so instead of inheriting.** Everything
> below this box — the two struck provenance blocks, the three superseded count
> tables, the branch delta boxes in §20.4 — is kept as the record and **must not
> be quoted as current.** A stale header is the reason the Wave-10 pass happened,
> and this box exists so that it cannot be the reason for the next one.
>
> ~~**Superseded — Wave 15 branch fork, kept for the record.** 121 test files /
> 2,124 tests / 532,153 asserts / 0 failed / 0 silent, 30 balance gates;
> determinism founding `32a3e96855218af5…` / `90a41a97eb1e49fb…`, benchmark
> `385dacb23d3ec1b7…` / `e420494749d5c90e…`; the count 170 of 188 at that fork.
> The four digits *that* line carried before it were the pre-Wave-14 set,
> `e8bffba1…` / `08bfdfaa…` / `e760f930…` / `bd2d8f30…`, superseded by doc 92
> §33.1 and report 98 RR-69 a wave earlier and never re-copied. Report 98 RR-77
> carries the enumeration connecting them — the opportunity layer adds exactly
> three keys to the city body and changes no existing value, so stripping them
> reproduces the earlier set to the byte.~~

~~Provenance: written against `6d8c2b1` (post Wave-4), Godot 4.7.2, 1,249 tests +
20 balance gates green.~~ **RE-DERIVED AGAINST TODAY'S TREE — Wave 10, 2026-08-20,
at `a892315`, Godot 4.7.2. The tree this was measured on: 108 test files /
1,890 tests / 502,127 asserts / 0 failed, 28 balance gates. The tree it leaves
behind adds §16's asset matrix and is 109 / 1,909 / 505,294 / 0 failed —
*(and, after A91-D-19 closed on 2026-08-20, **112 / 1,991 / 511,256 / 0 failed
with 29 balance gates**)* —
determinism untouched, because this branch changes no `sim/`, no `data/` and no
`game/`: `profile_sim --hash-only` reports `18e70625e633c254…` / `4c3c52cdb4c5a3cc…`
on the founding city and `d6b2509c179987d3…` / `bf8dc7282758843b…` on the
benchmark city, before and after.** The old provenance line is struck rather than
replaced because it is the reason this pass happened: the header named a
1,249-test tree while HEAD carried 1,890, and a coverage document whose own
provenance is six waves stale cannot be quoted. Companion to doc 93 (rulings
ledger) and doc 92 (balance), which remain the truth about *rules* and *numbers*;
this document is the truth about *coverage* — which paragraph of docs 01–13 has
code behind it, and which does not.

**What the Wave-10 re-audit changed, in one paragraph.** The row basis was
rebuilt from the docs themselves rather than inherited (§0), which found **ten
sections that had no row at all**; **doc 00 was graded for the first time**
(§0.5) — eleven of its twelve LOCKED sections hold, the twelfth fails on one
sentence; every PARTIAL and ABSENT row was re-verified
at HEAD, which moved **fifteen of them up and four of them down**; and four new
matrices were added
because the per-§ grading provably cannot see what they see — the **asset
matrix** (§16, and a test), the **verb matrix** (§17), the **event matrix**
(§18) and the **screen matrix** (§19). §20 is the one-page definition of done
the lead asked for. Eleven new defects are filed in §14.5 under a new `A91-D-nn`
prefix, which is also the answer to the three-id-namespaces problem carried into
this wave as this document's open question 2.

## 0. Method

> **The row basis is now a stated rule with two enumerated lists, and the
> promotion list is CLOSED** — see *THE COUNT, RE-DERIVED ROW BY ROW AT THE
> WAVE-14 MERGE* below, and doc 93 §W1 for the ruling. The paragraph that follows
> is the Wave-10 statement of the same method and is kept because it explains
> where the ten rows came from. **Where the two differ, the rule below wins.**
> *(2026-08-21.)*

**Row basis (re-derived 2026-08-20).** One row per `### 2.N` heading in docs
01–13, counted **from the documents themselves** rather than from the previous
edition of this table — which is the whole reason ten rows appeared. Four are
sections that existed in the docs, existed in the code, and had never been
graded: **doc 02 §2.14** (the sixth rung), **doc 05 §2.14** (the worked
examples), **doc 09 §2.14** (the goal curriculum) and **doc 12 §2.19** (S14).
The other six are doc 11's: its *count* row said 15 while its own *table* had
already grown past that, and the two had not been reconciled in three waves —
re-derived it is 21, being sixteen `### 2.N` headings plus `### 2.10b` plus four
`####` sub-headings promoted to rows of their own (§2.1.1, §2.1.2, §2.1.2a,
§2.10.1) because a wave shipped each as a separate deliverable and the audit's
value is in grading what shipped. Two rows are marked `—` rather than a section
number: cross-cutting findings that belong to a whole document rather than to one
of its subsections. They are counted in the tally like any other row.

A row is graded by reading the section, then finding the code that implements it
and the test that holds it — not by trusting a changelog. Where a row is PARTIAL
or ABSENT the pointer names the specific gap, so the row is actionable without
re-reading the doc. **Nothing in this edition is graded on a pointer that was not
opened at this fork**: a scan of every backticked file path in this document
found exactly one that no longer resolves — `data/difficulty.json`, which is
**A91-D-19** and not a typo.

Two harnesses supplied the behavioural half of the Wave-4 audit; §14 reports what
they found and §15 ranks it. **Four more instruments supplied the Wave-10 half**,
and they are Part II: `tests/test_asset_completeness.gd` (§16, new), the verb
join (§17), the event join (§18) and the ten-sweep screen matrix (§19).

| Harness | What it does | Where |
|---|---|---|
| Tutorial flow test | drives all eleven onboarding steps through the real UI models over a real `CitySim`, then over the real `game/main.tscn` shell | `tests/test_tutorial_flow.gd`, `tools/flow_test.gd` |
| QA soak | a 2-real-hour session at mixed speeds with seeded player verbs, forced storms, save/load cycles and app pause/resume; measures objects, step cost, bus volume and sanity bounds | `tools/qa_soak.gd`, `tests/test_qa_soak.gd` |

### Legend

| Grade | Meaning |
|---|---|
| **SHIPPED** | implemented, reachable in play, covered by a test |
| **PARTIAL** | implemented in part — or implemented in `sim/` but **not reachable by a player**, which for a game is the same thing |
| **ABSENT** | no implementation |
| **IN FLIGHT** | landing in a sibling Wave-5 branch, verified absent from this tree — **retired 2026-08-19**, zero rows carry it; the two that did are re-graded against the tree they landed in |
| **DEFERRED** | the doc itself defers it (not a gap) |

### The count — rebuilt from the docs, 2026-08-20 (`a892315`)

The row basis moved (§0), so the two tables are printed together rather than one
overwriting the other. **Read the left half as the count and the right half as the
delta**; the superseded table is quoted below it verbatim, because a coverage
document whose only value is its record must not quietly restate its own past.

| Doc | Rows | SHIPPED | PARTIAL | ABSENT | DEFERRED | vs. the Wave-4 table |
|---|---|---|---|---|---|---|
| 01 Time & ticks | 12 | 12 | 0 | 0 | 0 | §2.11 ABSENT → SHIPPED (the platform half landed) |
| 02 Buildings | 14 | 13 | 1 | 0 | 0 | +1 row (§2.14, the sixth rung), SHIPPED |
| 03 Economy | 13 | ~~12~~ **13** | ~~**1**~~ **0** | 0 | 0 | ~~**§2.9 SHIPPED → PARTIAL (A91-D-19)**~~ → **SHIPPED again 2026-08-20, A91-D-19 closed** |
| 04 Power grid | 13 | 11 | 1 | 0 | 1 | unchanged |
| 05 Water | 16 | 13 | 2 | 0 | 1 | +1 row (§2.14), PARTIAL (A91-D-25); the verbs row narrows |
| 06 Incidents & dispatch | 13 | 13 | 0 | 0 | 0 | §2.6 and §2.12 PARTIAL → SHIPPED |
| 07 Weather & director | 7 | 6 | **1** | 0 | 0 | **§2.4 SHIPPED → PARTIAL (A91-D-26)** |
| 08 Offline & persistence | 15 | 12 | 2 | 1 | 0 | §2.13 ABSENT → PARTIAL (A91-D-27); **+2 rows 2026-08-20 (§2.14, §2.15 — neither section had ever been counted)**, both SHIPPED |

| 07 Weather & director | 7 | 7 | 0 | 0 | 0 | §2.4 PARTIAL → **SHIPPED again 2026-08-20** — A91-D-26 closed, the flood is drawn, announced and logged (report 98 RR-53) |
| 08 Offline & persistence | 13 | 10 | 2 | 1 | 0 | §2.13 ABSENT → PARTIAL (A91-D-27) |
| 09 Map, land, starter city | 14 | 14 | 0 | 0 | 0 | +1 row (§2.14, the curriculum); the old count's 1 ABSENT was §2.13, **fixed 2026-08-19 in the row and never in the count** |
| 10 Roads & traffic | 15 | 14 | 1 | 0 | 0 | §2.13 PARTIAL → SHIPPED — again, moved in the row and never in the count |
| 11 Rendering & performance | 21 | 21 | 0 | 0 | 0 | +6 rows; §2.13 PARTIAL → SHIPPED (the governor ships) |
| 12 UI/UX | 19 | 17 | 2 | 0 | 0 | +1 row (§2.19); §2.2, §2.5 and §2.13 → SHIPPED; **§2.9 and §2.18 SHIPPED → PARTIAL (A91-D-21/22/23, and §2.9's own pointer)** |
| 13 Android | 13 | 5 | 8 | 0 | 0 | **five ABSENT rows → PARTIAL: the Kotlin notification platform exists** |
| **Total** | **183** | ~~161~~ **162** | ~~19~~ **18** | **1** | **2** | one row moved 2026-08-20 (doc 03 §2.9); the rest of the table stands as re-built |

| **Total** | **185** | **163** | **19** | **1** | **2** | |

*Wave-12 revision (2026-08-20): doc 08 gains §2.14 and §2.15 — the threaded
write and the two deep save/load levers — and both are SHIPPED, so the basis
moves 183 → 185 and SHIPPED 161 → 163 (**88 %**, unchanged to the point). Wave 12
also files one new defect, `A91-D-30`, and it is a determinism defect rather than
a coverage one: it moves no row here because the section it belongs to (doc 08
§2.9) is graded on the load gate, which works, and the fault is in what `roads`
persists.*

> **The superseded table, kept verbatim (as it stood 2026-08-19).** Every number
> in it is against the old row basis and none of them should be quoted after this
> date.
>
> | Doc | Rows | SHIPPED | PARTIAL | ABSENT | IN FLIGHT | DEFERRED |
> |---|---|---|---|---|---|---|
> | 01 Time & ticks | 12 | 11 | 0 | 1 | 0 | 0 |
> | 02 Buildings | 13 | 12 | 1 | 0 | 0 | 0 |
> | 03 Economy | 13 | 13 | 0 | 0 | 0 | 0 |
> | 04 Power grid | 13 | 11 | 1 | 0 | 0 | 1 |
> | 05 Water | 15 | 12 | 2 | 0 | 0 | 1 |
> | 06 Incidents & dispatch | 13 | 11 | 2 | 0 | 0 | 0 |
> | 07 Weather & director | 7 | 7 | 0 | 0 | 0 | 0 |
> | 08 Offline & persistence | 13 | 10 | 1 | 2 | 0 | 0 |
> | 09 Map, land, starter city | 13 | 12 | 0 | 1 | 0 | 0 |
> | 10 Roads & traffic | 15 | 13 | 2 | 0 | 0 | 0 |
> | 11 Rendering & performance | 15 | 14 | 1 | 0 | 0 | 0 |
> | 12 UI/UX | 18 | 16 | 2 | 0 | 0 | 0 |
> | 13 Android | 13 | 5 | 3 | 5 | 0 | 0 |
> | **Total** | **173** | **147** | **15** | **9** | **0** | **2** |

**88 % shipped — 161 of 183, or 89 % of the 181 rows that are not deferred by
their own docs.** The Wave-4 figure was 85 % of a smaller and differently-drawn
population, so the two percentages are **not** comparable and the delta column
above is the honest comparison: **fifteen rows moved up, four moved down, and
ten rows existed in the documents and in the code and had never been counted at
all** — which sums, exactly, to the +14 SHIPPED the two totals differ by.

Two of the fifteen upward moves are worth calling out separately, because they
are not work landing — they are **the count failing to follow its own table**.
Doc 09 §2.13 was fixed on 2026-08-19 and doc 10 §2.13 in Wave 5/10; both rows say
so in their own pointer and neither was ever subtracted from the tally. A count
table that is edited by hand beside a table of rows will drift, which is the
argument for §20.1's last line: *when all four matrices are tests, "done" is a
number the suite prints.*

**Where the remaining 20 sit.** One document holds eight of them and it is the
same one it has always been — **doc 13**, whose eight PARTIALs are now PARTIAL
rather than ABSENT because the Kotlin half landed (`NotificationCenter.kt`,
`AlarmReceiver.kt`, `BootReceiver.kt`, `PermissionFlow`, `NativeNotificationSink`)
and every one of them is now blocked on the same single thing: **a debug build
that carries the plugin, on a device**. The other twelve are spread one and two
at a time, and §20 sizes each.

*Wave-6 revision (2026-08-19): doc 12 §2.8 and §2.14 moved ABSENT → SHIPPED; §2.2
and §2.13 stay PARTIAL on S10 (**S0 shipped in Wave 7** — `ui/title_screen.gd`). Everything below the count table is as
written at `6d8c2b1` unless a row says otherwise.*

*Fold 6 device pass (2026-08-20): **doc 13's row is unchanged at 5 / 3 / 5**, and
that is the finding, not an omission. Five of its rows were re-examined against a
real device (§13) and every one kept its grade — what changed is that they are
now graded on `dumpsys` evidence instead of on code-reading, and §2.7 is sharper
than "ABSENT": `POST_NOTIFICATIONS` ships in the release path and is **missing
from the debug APK under test**. §2.8 gained real evidence (the governor was seen
stepping on device) and still holds PARTIAL, because no thermal step-down was
exercised and battery was never measured.*

*Wave-7 revision (2026-08-19), seven rows and one grade retired. Doc 08 §2.2,
§2.5, §2.7, §2.8, §2.9 and doc 01 §2.10 moved PARTIAL → SHIPPED on the
persistence unification and the `CatchUpPlanner` resume wiring; doc 02 §2.4 moved
IN FLIGHT → SHIPPED and §2.9 IN FLIGHT → PARTIAL, which empties the **IN FLIGHT**
column — the sibling Wave-5 branches it named have all landed or been re-graded
against the tree, so the grade has no rows left and no further use. Each moved
row carries its own dated note; nothing was moved without a named file and a
named test.*

**85 % shipped** (147 of 173, up from 140). Of the 26 rows that are not (two more
are deferred by their own docs, which is not a gap), the weight sits in one place
now rather than two:

* **The Android platform layer** — doc 13's notifications, permissions, signing
  and store assets: 5 ABSENT rows, and the only ones on the critical path to a
  build a stranger can install.
* ~~**Persistence under the shell**~~ — **closed 2026-08-19.** Doc 08's generation
  ladder, retention, migration and corruption gate are no longer reachable from
  nowhere: `game/save_service.gd` is a thin slot API over `SaveManager`, the
  second format is read-only legacy, and the five PARTIAL rows this bullet
  counted are SHIPPED. §8 carries the row-by-row evidence.
* ~~**Player verbs for infrastructure**~~ — **closed.** Water landed in Wave 5B,
  roads in 5A, land in Wave 6 (S4). Exactly as predicted, not one line of new
  simulation was needed for any of the three: a `cmd_*` re-export, a card, and
  in land's case a panel and a tap seam.

### The count, re-graded on the merged tree — 2026-08-20 (`28b9550`), Wave 12

*The table above was graded at `a892315`, with three Wave-10 build branches still
in flight. All three have landed (`3bfa3cd`, `3a025e9`, `0b84eee`, integrated at
`28b9550`). This is the re-grade, and it is deliberately narrow: **only rows
re-measured with a named instrument at this fork appear here**, and the four
matrices (§16–§19) are re-run rather than re-read.*

**The count table's numbers do not move, and that is a result rather than an
omission.** Every row that a Wave-10 branch closed was ALREADY graded SHIPPED in
the table above — the verb doors were counted in advance by their own rows
(doc 05's "Player verbs", doc 12 §2.2/§2.5/§2.13) — and every row still PARTIAL
is PARTIAL for a reason no shipped branch touched. Checked one at a time:

| PARTIAL / ABSENT row | still open at `28b9550`? | how it was checked |
|---|---|---|
| doc 03 §2.9 — difficulty (**A91-D-19**) | **yes** | `data/difficulty.json` and `sim/economy/difficulty.gd` are both absent from the tree; `CitySim` still constructs `Treasury.new(econ_curves.economy_data())` with no difficulty argument |
| doc 07 §2.4 — flooding (**A91-D-26**) | **yes** | `grep -rn flood_level_changed game/ ui/ data/` returns **nothing**. Standing water is still simulated and never drawn, announced or logged |
| doc 08 §2.13 — notification budget state (**A91-D-27**) | **yes** | `game/save_service.gd` still registers exactly three sections (`city`, `ui`, `meta`); `NotificationRouter.serialize()` still has no caller outside `tests/` |
| doc 12 §2.9 — building panel (S5) | **yes** | `grep -rn "E_FIRE_COVERAGE\|E_POLICE_COVERAGE"` over `*.gd` and `*.json` returns **nothing**; the coverage upgrade gates §2.9 promises are still unimplemented. *(The panel DID gain surface this wave — `ui/water_actions.gd`'s node block, doc 93 §J1 — which is why the row is worth re-checking and why it still does not move.)* |
| doc 12 §2.18 — accessibility (**A91-D-21/22/23/29**) | **yes, but two of the four moved** | re-swept; see below |
| doc 05 §2.14 — worked example (**A91-D-25**) | **yes** | doc quote, untouched |

**§17's verb matrix, re-taken — 22 of 23, and the wrapper-less list is EIGHT.**
`cmd_route_feeder` (`ui/path_tool.gd:647`), `cmd_upgrade_water_component`
(`ui/water_actions.gd:216`), `cmd_isolate_water_main` (`:274`) and
`cmd_restore_water_main` (`:280`) all have player doors now; §17.3's in-flight
note called all four correctly. **`cmd_recall_unit` is the last doorless verb and
A91-D-24 is unchanged.** §17.2's list of sub-system verbs with no `CitySim`
wrapper is **wrong by one in this document and in doc 92 §17.6.1**: both count
seven and both omit **`WaterSystem.cmd_install_backup_generator`**
(`sim/water/water_system.gd:1155`), whose only callers anywhere are
`tests/test_water_system.gd:338` and `:355`. With `RoadNetwork.cmd_road_repair`
ruled out of scope by doc 93 §J3, the open count is **seven**, not six. Doc 92
§17.6.2 carries the full re-take. *(Wave 12 update: `cmd_install_backup_generator`
is itself now ruled an interface call rather than an open verb — doc 93 §N3, doc
05 §9 — so the open count is **six**. §17.2's row says so.)*

**§19's screen matrix, re-swept at SIX boxes — and it is 52 states now, not 49.**
`tools/ui_preview.gd::SCREENS` gained `path_feeder`, `building_water` and
`drawer_water` with the Wave-11 doors. `--screen=all --audit --strict` at each
box × three settings:

| box | 100 % | 130 % + large targets | 150 % + large targets |
|---|---|---|---|
| 360 × 800 | **52/52 clean** | **52/52 clean** ✅ *(was: fails)* | 36/52 clean |
| 412 × 915 | **52/52 clean** | **52/52 clean** ✅ | 47/52 clean |
| 794 × 924 | **52/52 clean** | **52/52 clean** ✅ | **52/52 clean** |
| 880 × 400 | **52/52 clean** | 0/52 clean | 0/52 clean |
| 1280 × 720 | **52/52 clean** | **52/52 clean** ✅ | 50/52 clean |
| **640 × 340** *(the min-safe box, A91-D-29)* | **51/52** | 0/52 | 0/52 |

Which moves three defects and closes one:

* **A91-D-21 — CLOSED.** The row's whole claim was *"36 of 49 states report
  `overlapping_targets` in the right-edge chip column"*. At this fork, `grep -c
  "AlertsCenter/Chip\|EventLog/Chip\|IncidentDrawer/Handle"` over the 880 × 400
  a11y sweep — the worst box — returns **0**, and four of the six boxes are
  52/52 clean at 130 % + large targets. The chip column re-flows.
* **A91-D-22 — NARROWED, not closed.** The two findings the row called
  unrecoverable — `SettingsSheet/…/Close "✕"` and `SaveLoadSheet/…/Close "✕"` at
  360 × 800 — are **gone** (that box is now 52/52 clean at 130 %). Five offscreen
  controls remain and all five are at **880 × 400**: `TitleScreen/…/Confirm_start
  "START NEW"`, `Confirm_cancel "CANCEL"`, `Buttons/Action_settings "SETTINGS"`,
  `PauseMenu/…/Action_quit "SAVE & QUIT"` and an alert row's `VIEW`. The row's
  headline — *"a new player on A3, on a folded Fold, cannot press START NEW"* —
  **still holds**, at one box instead of two.
* **A91-D-23 — OPEN and now exactly characterised.** 880 × 400 at 130 % + large
  targets is **0 of 52 states clean, 156 `overlapping_targets` and 6
  `offscreen`**, and the overlaps reduce to **five unique pairs**, all of them
  the top bar's two chip rows over the two rails:
  `TopBar/Chips/Row0/Chip_treasury` and `Row1/Chip_water` and `Row1/Chip_grid`
  over `LeftRail/SpeedButton` and `OverlayRail/Button`. Nothing else. It is one
  container that will not yield height, exactly as the row said.
* **A91-D-29 — OPEN, and smaller.** 640 × 340 at 100 % has **one** dirty state:
  `TitleLayer/…/Confirm_cancel "CANCEL"` at `P (200.0, 318.5) S (240.0, 50.0)`
  against a 340-tall viewport — **28.5 dp past the bottom edge**, where the
  original filing measured y 318.5 with height **96** (74.5 dp past). The
  Wave-10 sheet work shrank the control and did not move it inside. The box is
  still in no `BOXES` list and no test: `tests/test_ui_audit.gd::BOXES` is
  unchanged at five entries.

**A91-D-28 — OPEN, unchanged.** `grep -n "event_log\|EventLog" tools/ui_preview.gd`
still returns nothing; S13's panel has still never been laid out by the sweep.
**A91-D-20 — OPEN, unchanged**: `tests/test_asset_completeness.gd::DEFERRED_BODIES`
is still `["ambulance"]`.

**What the lead should route at integration.** Nothing in the count table, and
two things in the defect table: **A91-D-21 can be struck**, and **A91-D-22
rewritten to the 880 × 400 remainder**. Both are measured above and neither needs
a further run. Everything else on the list is open at this fork on evidence, not
on assumption.

### 19.1 Re-measured at Wave 13 — and the cause under the whole table

*Added 2026-08-20 (doc 12 D-54 … D-60).* Everything above was measured against a
deck whose **every themed button was 37 % too tall**, and the table changes shape
once that is fixed. `ThemeBuilder.build()` sized a button's vertical content
margins from a touch minimum that had already been multiplied by the text scale,
then handed the theme to `scale_theme()`, which multiplies every content margin
again — so a `StatChip` at 130 % with larger targets measured **100 dp against an
A3 floor of 73**, and at 150 % **117 against 84**. Doc 12 D-54 is the one-line
fix and it is a **no-op at `text_scale == 1.0`**, where the two figures agree.

Whole deck, `--screen=all --audit --strict`, every finding of every kind — 53
states per cell at this wave's fork, 55 after (S15 is two new states):

| box | 100 % | 130 % + large | 150 % + large |
|---|---|---|---|
| 360 × 800 | 0 → **0** | 0 → **0** | 25 → **0** |
| 412 × 915 | 0 → **0** | 0 → **0** | 8 → **0** |
| **640 × 340** *(`min_safe_box_dp`)* | 0 → **0** | 3 → **0** | 209 → **0** |
| 794 × 924 (Fold inner) | 0 → **0** | 0 → **0** | 0 → **0** |
| 880 × 400 (reference) | 0 → **0** | 0 → **0** | 162 → **0** |
| 1280 × 720 | 0 → **0** | 0 → **0** | 1 → **0** |

**408 findings → 0, across 990 state-sweeps.** Of the 408, **400 fall to D-54
alone**; the 8 survivors were four separate defects the surplus had been hiding
(doc 12 §2.18 has the breakdown, D-55 … D-57 the fixes). The 100 % row does not
move by a single finding, which is the check that says the root fix is a bug fix
and not a redesign.

Three rows of the §19 table above are therefore restated:

* **A91-D-29 — CLOSED** (see the defect table). 640 × 340 is a row of
  `tests/test_ui_audit.gd::BOXES` and of the preview sweep list, added in the same
  commit as the layout fixes, which is what the filing demanded. Its 100 % half
  had already been cured by Wave 12's D-52 and its 150 % half is D-54 + D-55.
* **A91-D-28 — HALF, and the half that moved is the rule rather than the
  screen.** S13 still has no preview state and the row stands. But its *lesson*
  was applied on the way in this wave: S15 shipped with `veil_load` and
  `veil_catchup` in `SCREENS` and a `SURFACES` row in the suite, in the same
  commit as the screen, so the deck has not gained a second unswept surface.
* The `LeftRail`/`OverlayRail` pitch disagreement that this table's 880 × 400 row
  half-describes had a **second** cause, independent of the top bar and never
  filed: the two rails were placed at two different pitches (93 and 73) because
  one placer measured before layout. Doc 12 **D-59**; it is closed, and the fix is
  the mirror of D-46's corner rail.

### THE COUNT, RE-DERIVED ROW BY ROW AT THE WAVE-13 FORK — 2026-08-21

*Every count table above was edited by hand beside a table of rows — the exact
thing the Wave-10 table's own commentary warned about ("a count table that is
edited by hand beside a table of rows will drift"), and it drifted again, twice,
below. This one is re-derived the way §0 specifies — **from the documents**,
`grep -c "^### 2\.[0-9]" docs/design/*.md`, then every non-SHIPPED row re-verified
against the tree with a named command at this fork. It supersedes both tables
above. **This is the number to quote.***

| Doc | Rows | SHIPPED | PARTIAL | ABSENT | DEFERRED | what moved, and why |
|---|---|---|---|---|---|---|
| 01 Time & ticks | 12 | **12** | 0 | 0 | 0 | unchanged |
| 02 Buildings | 14 | **13** | 1 | 0 | 0 | unchanged. §2.9 re-verified: `grep -rn "E_FIRE_COVERAGE\|E_POLICE_COVERAGE"` over `*.gd` and `*.json` returns **nothing** |
| 03 Economy | 13 | **13** | 0 | 0 | 0 | §2.9 SHIPPED (A91-D-19) — *the row said so and the Total above never folded it in* |
| 04 Power grid | 13 | **11** | 1 | 0 | 1 | unchanged. §2.10 re-verified: `grep -rn fuel sim/power/` returns **nothing** |
| 05 Water | 16 | **14** | 1 | 0 | 1 | **+1 SHIPPED**: the `— Overlay` row moved PARTIAL → SHIPPED in Wave 11 (all six `enabled_modes` live, both answering verbs doored) and the count never followed its own row |
| 06 Incidents & dispatch | **14** | **14** | 0 | 0 | 0 | **basis +1 and +1 SHIPPED** (Wave 15): §2.16, the opportunity layer — `grep -c "^### 2\.[0-9]" docs/design/06-incidents-dispatch.md` reads 14 at this fork |
| 07 Weather & director | 7 | **7** | 0 | 0 | 0 | §2.4 SHIPPED (A91-D-26 closed, RR-53) — *an override row above says so; the main row and the Total never did* |
| 08 Offline & persistence | 15 | **12** | 2 | 1 | 0 | unchanged. All three re-verified below |
| 09 Map, land, starter city | 14 | **14** | 0 | 0 | 0 | unchanged |
| 10 Roads & traffic | 15 | **14** | 1 | 0 | 0 | unchanged. §2.15 re-verified: `game/render/road_overlay_view.gd` ingests `RoadNetwork.snapshot.visible_edges` as a per-edge MultiMesh, not §2.15's polyline |
| 11 Rendering & performance | **22** | **22** | 0 | 0 | 0 | **basis +1** (see below) |
| 12 UI/UX | **20** | **19** | 1 | 0 | 0 | **basis +1** (§2.20, S15) and **+1 SHIPPED** (§2.18, Wave 13) |
| 13 Android | 13 | **5** | 8 | 0 | 0 | unchanged in the count; the *blocker* changed (see below) |
| **Total** | **188** | **170** | **15** | **1** | **2** | **Wave 15: basis +1, SHIPPED +1 — doc 06 §2.16, re-derived here rather than inherited (RR-76)** |

> **90 % shipped — 170 of 188 — or 92 % of the 186 rows that are not deferred by
> their own docs.** *(Wave-15 fork, 2026-08-21. The Wave-13 figure was 169 of 187; doc 06 §2.16 is the one row added and the one row shipped, so the headline percentage is unmoved and the non-deferred share ticks up. RR-76's rule binds this line as much as the one it replaces: it carries its fork because it was computed at one.)*

**Two rows moved because a count table drifted from its own rows, and that is the
third instance of the same fault.** Doc 03 §2.9 (A91-D-19, closed
2026-08-20) and doc 07 §2.4 (A91-D-26, closed 2026-08-20) were both struck in
their rows, and the Wave-12 `185 / 163 / 19 / 1 / 2` Total folded in **neither**
— its own rows sum to 164 SHIPPED with doc 03 corrected and 165 with doc 07
corrected too, so the published headline was two rows behind the table printed
directly above it. It is exactly the §28.2 fault in doc 92, in this document, and
it is the argument for §20.1's last line restated for the third time: *a count
maintained by hand beside a table of rows will drift; when all four matrices are
tests, "done" is a number the suite prints.* **Report 98 RR-76 rules it** — a
derived total is not a source; either it is computed, or it carries the fork it
was computed at — and from here every count table in this document carries its
fork and its date in its own heading.

**The basis moves 185 → 187, in two documents, and every row it gains is a section
that shipped and was never counted.**

* **Doc 11: 21 → 22.** `grep -c "^### 2\.[0-9]" docs/design/11-rendering-performance.md`
  returns **18**, being §2.1–§2.16 plus **§2.9b** (standing water, shipped Wave
  11 — `game/render/flood_view.gd`, `game/shaders/flood.gdshader`,
  `tests/test_flood_view.gd`) and **§2.10b** (the distribution layer, shipped
  Wave 10 — `game/render/power_infra_view.gd`, `tests/test_power_infra.gd`).
  Neither has ever been a printed row of §11's table. Add the four promoted
  `####` deliverables (§2.1.1, §2.1.2, §2.1.2a, §2.10.1) and fold §11's
  **duplicated** `2.10.1` row back into one — it is a second deliverable under
  one heading and is recorded as such in the row's own pointer — and the basis is
  18 + 4 = **22, all SHIPPED**. Net +1 against the published 21.
* **Doc 12: 19 → 20.** **§2.20 — S15, the loading veil** (Wave 13, doc 12 D-60,
  RR-66): `ui/loading_veil.gd` + `ui/veil_model.gd`, driven from
  `game/main.gd:1305/:1312/:1328`, with `tests/test_veil_model.gd`, two states in
  `tools/ui_preview.gd::SCREENS` (`veil_load`, `veil_catchup`) and a `SURFACES`
  row in `tests/test_ui_audit.gd` — the whole of A91-D-28's lesson applied on the
  way in. **SHIPPED.**

**And two rows moved up on work that landed and was never subtracted from the
tally** — doc 05's `— Overlay` (Wave 11) and doc 12 §2.18 (Wave 13, 990
state-sweeps at six boxes × three text scales, 0 findings). With the two
corrections folded and these two moves, `165 → 169` and `17 → 15` reconcile
exactly against a basis of `185 → 187`. Nothing else moved.

**The sixteen rows that are a gap — 15 PARTIAL + 1 ABSENT, every one re-verified
at this fork.** *(The two DEFERRED rows — doc 04 §2.11 black start, doc 05 §2.10
contamination — are deferred by their own docs and are not gaps; §20.4 lists
them with the rest of the deferred surface.)*

| row | grade | the command that says so, run 2026-08-21 |
|---|---|---|
| doc 08 §2.10 — event history rings | **ABSENT** — *the last ABSENT row in the tree* | `ui/event_log_model.gd:28` states it in its own class doc: the ring is session-lifetime and "this class has no `capture_state`". Constitution §9 and doc 91 §0.5 both name it |
| doc 02 §2.9 — service coverage | PARTIAL | `grep -rn "E_FIRE_COVERAGE\|E_POLICE_COVERAGE" --include=*.gd --include=*.json .` → **nothing** |
| doc 12 §2.9 — building panel (S5) | PARTIAL | same grep, same root — the two rows close together |
| doc 04 §2.10 — backup generators | PARTIAL (re-open condition written, doc 93 §N3) | `grep -rn fuel sim/power/` → **nothing** |
| doc 05 §2.14 — worked examples | PARTIAL — **A91-D-25** | a doc quote: §2.14 says `water_demand_commercial = 0.45 at h22`, `data/time.json`'s `[21, 0.65]` / `[23, 0.35]` interpolate to **0.50** |
| doc 08 §2.3 — anti-frustration invariants | PARTIAL | `grep -rln _on_app_resumed tests/` → **nothing**. The planner is tested; `main.gd`'s own body is not |
| doc 08 §2.13 — notification budget state | PARTIAL — **A91-D-27** | `game/save_service.gd:380–382` and `:661–663` register exactly `city`, `ui`, `meta`; `NotificationRouter` appears nowhere in the file |
| doc 10 §2.15 — cosmetic civilian traffic | PARTIAL | `game/render/road_overlay_view.gd:145` ingests `visible_edges` per edge; §2.15 describes a polyline. Cosmetic-only |
| doc 13 §2.4, §2.5, §2.6, §2.7, §2.8, §2.9, §2.11, §2.12 | PARTIAL × 8 | ~~§20.4's device-gated list. **The blocker is no longer "a build that carries the plugin"** — it does, and `GodotPluginRegistry` logs its initialisation on the Fold. It is `export_presets.cfg`'s `permissions/custom_permissions=PackedStringArray()` with zero `permissions/*=true` on all three presets, so the plugin's four `<uses-permission>` elements never reach the APK~~ — **the second half of this cell is FALSE at the Wave-14 merge** and is struck rather than deleted, because it is the third different blocker this row has named in three waves. Wave 14 (RR-70) put all four `permissions/*=true` on all three presets. See the re-derived table below |

**Eight of the sixteen are one document's, and it is the same document it has
always been.** Doc 13 is **half** of everything this project has left, it is one
preset field and one device session away from being *measurable* rather than
guessed at, and no amount of workstation work moves it. §20.4 is written around
that fact.

---

### THE COUNT, RE-DERIVED ROW BY ROW AT THE WAVE-14 MERGE — 2026-08-21 (`bdba0b7`)

*Four Wave-14 branches forked from the Wave-13 commit. Each added rows to Part I
and **none restated the Total** — which is correct, and is RR-55 working as
designed: a total written on one of four siblings is stale before it merges. The
merge is where it gets re-derived, and this is that derivation. It supersedes
the Wave-13 table above, which supersedes the two above it. **This is the number
to quote.***

**The basis rule, stated exactly, because a rule that lives in prose drifts.**

```
rows(doc) = grep -c "^### 2\.[0-9]" docs/design/<doc>.md
          + promoted ####  (an ENUMERATED list, closed — see below)
          + cross-cutting — rows (an ENUMERATED list — see below)
```

The two enumerated lists are the whole of the judgement in this table, so they
are printed rather than described:

* **Promoted `####` rows — four, all doc 11's, and the list is CLOSED**:
  §2.1.1, §2.1.2, §2.1.2a, §2.10.1. They are grandfathered because each is a
  printed, separately-graded row of §11's table and has been for four waves.
  **Nothing is added to this list at this merge, and doc 03 §2.5a is the test
  case that closes it.** §2.5a (state grants, RR-79) is a real shipped
  deliverable with its own constants, its own `assistance` revenue line and its
  own test — and so are doc 11 §2.15.1 and §2.16b, doc 06 §2.6(z), §2.10.1,
  §2.10.2 and §2.13(b), and **fifty-nine** others: `grep -c "^#### 2\."` over
  docs 01–13 returns **63**, of which four are already promoted. There is no
  criterion that admits §2.5a and excludes doc 07
  §2.6.3 or doc 09 §2.9.4, and a basis that grows by whichever sub-heading a wave
  felt proud of is not a basis. **§2.5a is therefore graded inside doc 03 §2.5's
  row, whose pointer names it** — and the honest note is that the four
  grandfathered rows are a historical accident this table declines to repeat, not
  a principle it is applying. When §17's verb matrix becomes a test and "done" is
  a number the suite prints (§20.3), the promotion list should be deleted
  outright and the basis should be the bare `grep`, which sums to **184** across
  the thirteen documents. *(Both sums are reproducible in one line each:
  `grep -c "^### 2\.[0-9]" docs/design/0[1-9]*.md docs/design/1[0-3]*.md` sums to
  **184**, and the same command with `"^#### 2\."` sums to **63** — the size of
  the door a fifth promotion would open.)*
* **Cross-cutting `—` rows — two, both doc 05's**: `— Player verbs` and
  `— Overlay`. Each is printed **twice** in §5's table (a wave re-graded each
  without striking the first) and each is counted **once**.

| Doc | `grep -c "^### 2\.[0-9]"` | +promoted | +`—` | **Rows** | SHIPPED | PARTIAL | ABSENT | DEFERRED | what moved since the Wave-13 table, and why |
|---|---|---|---|---|---|---|---|---|---|
| 01 Time & ticks | 12 | 0 | 0 | 12 | **12** | 0 | 0 | 0 | unchanged |
| 02 Buildings | 14 | 0 | 0 | 14 | **13** | 1 | 0 | 0 | unchanged. §2.9 re-verified below |
| 03 Economy | 13 | 0 | 0 | 13 | **13** | 0 | 0 | 0 | basis unchanged — **§2.5a is a `####` and is graded inside §2.5** (see the rule above). §2.5's pointer now names the two grants |
| 04 Power grid | 13 | 0 | 0 | 13 | **11** | 1 | 0 | 1 | unchanged. §2.10 re-verified below |
| 05 Water | 14 | 0 | 2 | 16 | **14** | 1 | 0 | 1 | unchanged |
| 06 Incidents & dispatch | 14 | 0 | 0 | 14 | **14** | 0 | 0 | 0 | unchanged in the count — **and §6's own table now prints the §2.16 row it was counting.** The Wave-13 table folded §2.16 into the Total from the opportunity-layer branch's note and §6 never gained the row |
| 07 Weather & director | 7 | 0 | 0 | 7 | **7** | 0 | 0 | 0 | unchanged |
| 08 Offline & persistence | 15 | 0 | 0 | 15 | **12** | 2 | 1 | 0 | unchanged in the count; §2.3's *evidence command* changed and is restated below |
| 09 Map, land, starter city | 14 | 0 | 0 | 14 | **14** | 0 | 0 | 0 | unchanged |
| 10 Roads & traffic | 15 | 0 | 0 | 15 | **14** | 1 | 0 | 0 | unchanged |
| 11 Rendering & performance | **19** | 4 | 0 | **23** | **23** | 0 | 0 | 0 | **basis +1, SHIPPED +1** — §2.17 STREET LIFE (Wave 14). The `grep` reads 19 where the Wave-13 table read 18 |
| 12 UI/UX | **21** | 0 | 0 | **21** | **20** | 1 | 0 | 0 | **basis +1, SHIPPED +1** — §2.21 the tap and the payday (Wave 14). §12's table now prints **both** §2.20 and §2.21; it had been stopping at §2.19 while the Total counted §2.20 |
| 13 Android | 13 | 0 | 0 | 13 | **5** | 8 | 0 | 0 | unchanged in the count; **the blocker moved again and is now smaller than the sentence §20.4 carried** — see below |
| **Total** | **184** | **4** | **2** | **190** | **172** | **15** | **1** | **2** | **+2 basis, +2 SHIPPED across two documents and two sibling branches** |

> **172 of 190 rows are SHIPPED — 90 %** — or **91 %** of the 188 rows that are
> not deferred by their own docs. *(Wave-14 merge, `bdba0b7`, 2026-08-21.
> Re-derived at this fork under RR-76, not inherited from any of the four
> branches that fed it.)*

**The reconciliation, shown rather than asserted.** The Wave-13 table published
`188 / 170 / 15 / 1 / 2`, and the arithmetic from there to here is four terms and
no others:

```
basis      188  + 1 (doc 11 §2.17)  + 1 (doc 12 §2.21)                 = 190
SHIPPED    170  + 1 (doc 11 §2.17)  + 1 (doc 12 §2.21)                 = 172
PARTIAL     15  ± 0                                                    =  15
ABSENT       1  ± 0                                                    =   1
DEFERRED     2  ± 0                                                    =   2
check                          172 + 15 + 1 + 2 = 190                  ✔
```

**Doc 06 §2.16 and doc 03 §2.5a are in that arithmetic as zeroes, and both are
worth a sentence** so nobody folds them in a second time. §2.16 (the opportunity
layer) was already counted by the Wave-13 table — its branch's note moved the
basis 187 → 188 and the SHIPPED 169 → 170 — so it adds nothing here; what it
*was* still missing is a printed row in §6, which this pass supplies. §2.5a (the
state grants) adds nothing because it is a `####` under §2.5 and the promotion
list is closed; §2.5's own row now names it, so the deliverable is graded even
though it is not a row.

**And the six Wave-14/15 defect dispositions contribute exactly one row between
them — the `+1 (doc 12 §2.21)` already in the arithmetic above, and nothing
else.** That is a result rather than an omission, and it is worth walking one by
one, because *"six defects were filed and the coverage count moved by one"* is
the sort of sentence a reader should be able to check rather than take:

| defect | disposition | the row it lands on | does it move the count? |
|---|---|---|---|
| `A91-D-33` | ✅ closed (sim half) | doc 06 §2.16 — **already SHIPPED** | no. The row it created was counted by the Wave-13 table |
| `A91-D-34` | ✅ closed | doc 06 §2.7 — SHIPPED | no. A reward curve that paid 2.73× the damage prevented was a *balance* defect against a shipped mechanic |
| `A91-D-35` *(filed as `A91-D-31`)* | ✅ closed | doc 06 §2.13 — SHIPPED | no. The ceiling made §2.13's own published bound binding; the section always claimed it |
| `A91-D-36` | ○ **OPEN**, Low | doc 11 §2.12 / §2.16 — SHIPPED | no, **and this is the only one that needed a decision.** An authored `#F25242` livery arrives in the shader as linear and displays washed out; the layer is implemented, reachable and tested, so the row's grade holds. **A cosmetic defect against a shipped row is a defect, not a downgrade** — otherwise every open Low in the tree would silently deflate the count |
| `A91-D-37` | ◐ **half**-closed | doc 12 §2.21 — **new, SHIPPED** | **yes, +1** — and it is the `+1 (doc 12 §2.21)` already in the arithmetic above, counted once. **The remaining half is `revenue.bounties` / `revenue.street` belonging in `EconomySystem.settle_hour` rather than in a UI tally off the bus** (doc 92 §38's ranked item 0). That is a *provenance* debt, not a coverage one: the money reaches the Economy tab, the tab is right, and the tally is written to stand down the moment doc 03 publishes the keys. §2.21 is SHIPPED and §20.4's backlog carries the rest |
| `A91-D-38` *(filed as `A91-D-33`)* | ✅ closed | doc 03 §2.5 — SHIPPED | no. It made an existing row honest: the money was always being paid, into a ledger with no line for it |

**Four closed, one open and Low, one half — six rows, and a net of +1 to the
count, contributed by the half.** That is the shape a healthy wave produces: defects are found against
things that already shipped, and the count moves only when a *section* does.

**One published percentage was wrong and is corrected here.** The Wave-13
table's headline read *"92 % of the 186 rows that are not deferred"*;
`170 / 186 = 91.4 %`, which is **91 %**. §20.4's own one-paragraph answer had it
right at 91 % on a smaller basis, so the document disagreed with itself by a
point in two adjacent sections. That is the RR-76 fault in its smallest possible
form — a percentage recomputed by hand from a number that had itself moved — and
it is the reason this table prints its arithmetic instead of its conclusion.

**The sixteen gaps, every one re-verified at THIS fork.** Two rows of the
Wave-13 evidence table below have had their command re-run and answer
differently now; both stay PARTIAL and both get a command that is true today.

| row | grade | the command that says so, run 2026-08-21 at `bdba0b7` |
|---|---|---|
| doc 08 §2.10 — event history rings | **ABSENT** — *still the only ABSENT row in the tree* | `grep -c "^func capture_state" ui/event_log_model.gd` → **0**. The file mentions `capture_state` exactly once and it is the class doc at `:28` saying it has none: the ring is session-lifetime, so a resumed city starts its log empty. Constitution §9 and doc 91 §0.5 both name it |
| doc 02 §2.9 — service coverage | PARTIAL | `grep -rn "E_FIRE_COVERAGE\|E_POLICE_COVERAGE" --include=*.gd --include=*.json .` → **nothing** |
| doc 12 §2.9 — building panel (S5) | PARTIAL | same grep, same root — the two rows close together |
| doc 04 §2.10 — backup generators | PARTIAL (re-open condition written, doc 93 §N3) | `grep -rn fuel sim/power/` → **nothing** |
| doc 05 §2.14 — worked examples | PARTIAL — **A91-D-25** | re-read from the store: `data/time.json.curves.water_demand_commercial` holds `[21, 0.65]` and `[23, 0.35]`, which interpolate to **0.50** at h22 against §2.14's stated `0.45` |
| doc 08 §2.3 — anti-frustration invariants | PARTIAL — **and the Wave-13 command for it is now FALSE** | `grep -rln _on_app_resumed tests/` used to return nothing and now returns `tests/test_catchup_cursor.gd`. It is not coverage: that file names the method in two `##` comments and re-implements the loop as its own oracle (`_advance_monolithic`, `:35`). The command that is decisive and stays true: `grep -rn "_on_app_resumed(" tests/` → **nothing** (no test CALLS it) and `grep -rn "res://game/main" tests/` → **nothing** (no test loads the shell scene; `tests/test_tutorial_flow.gd` loads `res://game/ui/ui_root.tscn` and re-implements `main.gd`'s wiring beside it). The invariants and the planner are tested; `main.gd`'s own resume body still is not |
| doc 08 §2.13 — notification budget state | PARTIAL — **A91-D-27** | `grep -n "register_section\|NotificationRouter" game/save_service.gd` → three sections at `:380–382` and `:661–663` (`city`, `ui`, `meta`), and **zero** `NotificationRouter` |
| doc 10 §2.15 — cosmetic civilian traffic | PARTIAL | `game/render/road_overlay_view.gd:145` ingests `visible_edges` per edge; §2.15 describes a polyline. Cosmetic-only |
| doc 13 §2.4, §2.5, §2.6, §2.7, §2.8, §2.9, §2.11, §2.12 | PARTIAL × 8 | **The blocker moved AGAIN in Wave 14 and the Wave-13 sentence for it is now FALSE.** `grep -n "permissions/" export_presets.cfg` returns `post_notifications=true`, `receive_boot_completed=true`, `vibrate=true`, `wake_lock=true` on **all three presets** (`:67–70`, `:138–141`, `:209–212`) — RR-70 put them there, as a second source beside the plugin's own manifest. `permissions/custom_permissions` is still `PackedStringArray()` and no longer needs to be anything else. **What is left is not a preset field and not a build: it is one install and one human tapping ALLOW.** §20.4 device item 1 |

**The two corrections in that table are the finding, not a footnote.** A
PARTIAL row is only as good as the command underneath it, and two of these
commands had gone stale in one wave — one because a sibling branch added a file
that mentions the method (doc 08 §2.3), one because a sibling branch *fixed the
blocker* and nobody re-read the row that named it (doc 13). The first makes a gap
look closed; the second makes a closed gap look open, and it had been telling
every reader of §20.4 to go and fill in a field that Wave 14 already filled.
**Re-run the command; do not re-read the sentence.**

---

## 0.5 Doc 00 — the constitution, checked rather than assumed

*Added 2026-08-20. Doc 00 has no `§2.x` mechanics and therefore no rows in the
tally above — it is a set of LOCKED constraints, and the question a completeness
audit has to ask of it is not "is it implemented" but **"is it still true"**.
Every section was checked against the tree. Doc 00's own header is the standard:
"deviations require explicit overseer approval and must be flagged, never made
silently." Two deviations exist and **both are flagged in the docs that own
them**, which is the outcome the header asks for. One clause is simply unmet.*

| § | Constraint | Status | Evidence |
|---|---|---|---|
| 1 | Product identity, spec §55's fifteen rules constitutional | **HELD** | title, tagline and package id are in `export_presets.cfg` and `game/branding/` |
| 2 | Technology (LOCKED) | **HELD, two flagged deviations** | Godot 4.7.2 ✔, typed GDScript ✔, `minSdk 29` ✔, `com.slacumcity.game` ✔, zstd-compressed JSON saves ✔ (`SaveManager._write_compressed_atomic`), `user://settings.cfg` device-scoped ✔. **`targetSdk` is 36, not 37** — all three presets and `android/build/config.gradle:9` — because the export template pins `compileSdk = 36` and a higher `targetSdk` is a build error; **flagged in doc 13 §10** and aspirational until the template moves. **`debug_plain_mirror` ships `false`** — §2 asks debug builds for a plain `.json` beside each generation; **flagged in doc 08 §2.5** as owed rather than dropped |
| 3 | Architecture (LOCKED): four layers, `sim/` RefCounted-only, no `Node` / `OS` / `Time` / `Input` / `Engine` | **HELD, and mechanised** | `tests/test_no_wallclock_in_sim.gd` is a scan test over `sim/`, so this is the one constitutional clause that cannot rot silently. Events out, commands in, headless sim ✔ |
| 4 | Time model: `tick_index` int64 canonical, `sim_time_minutes` derived and asserted on load, 60× scale, SimTick = 15 game-seconds, game-time cadences | **HELD** | `sim/time/game_clock.gd`, `TickScheduler`, `tests/test_game_clock.gd`, `tests/test_scheduler.gd`. The one coarse path ✔ (`advance_coarse_hours`) |
| 5 | Determinism: one named RNG stream per stochastic system, seven of them, never a global | **HELD, exactly** | `sim/core/rng_streams.gd:8` lists `weather, incidents, crime, failures, director, traffic, misc` — the constitution's seven, no more and no fewer; `tests/test_rng_streams.gd` proves independence and serialize-resume |
| 6 | World units: 1 tile = 8 m, block 16 × 16, chunk == block | **HELD** | `TileGrid`, `CHUNK_M = 128.0` in `city_view.gd:30` |
| 7 | Economy units: whole dollars int64, rates per game-hour | **HELD** | `Treasury.balance: int`, `carry_millidollars` for the sub-dollar remainder |
| 8 | Simulation state truths | **HELD** | aggregate population ✔, real routed emergency vehicles + cosmetic civilian density ✔, first-class `Incident` ✔, utilities as graphs ✔, data-driven cascades ✔, districts ✔ |
| 9 | Save schema ground rules | **ONE CLAUSE UNMET** | `schema_version` / `sim_time_minutes` / `rng_streams` / per-system sections ✔; the migration ladder ✔ (`SaveManager.LADDER`, `tests/test_save_migration.gd` against a byte-for-byte legacy fixture). **"Event history ring buffer persisted for the WHILE YOU WERE AWAY report" is not implemented** — `ui/event_log_model.gd` says in its own class doc that nothing here is persisted. This is doc 08 §2.10, the **last ABSENT row in the tree**, and grading doc 00 is what promotes it from a subsystem gap to a constitutional one |
| 10 | Design-doc contract: nine sections, in order, in every doc 01–13 | **HELD** | all thirteen carry `## 1.` … `## 9.` in order; four carry extras after §9 |
| 11 | Art direction anchors | **HELD** | gray-box + emissive windows + streetlights + blackout ceremony all ship (doc 11 §2.6, §2.7, §2.10) |
| 12 | Development doctrine | **HELD** | the vertical slice runs end to end (`tools/flow_test.gd`, 11/11 steps); 1,890 tests; every balance number in `data/` |

**The reading.** Eleven of twelve sections hold outright, and the twelfth fails on
one sentence. That sentence is worth its own line in §20.2 (item 11) precisely
because it is cheap: the ring exists, the report that wants it exists, and the
save section it would ride is three lines from the `ui` section that already
rides the envelope. **A constitutional clause should not be the cheapest open
item in the project, and this one is.**

## 1. Doc 01 — Time and ticks

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.1 | Units, canonical counter | SHIPPED | `sim/time/game_clock.gd`; `tests/test_game_clock.gd` |
| 2.2 | Calendar derivation | SHIPPED | `GameClock.day_index/minute_of_day`; `test_game_clock.gd` |
| 2.3 | Cadences | SHIPPED | `SimSystem.Cadence`, `TickScheduler`; `test_scheduler.gd` |
| 2.4 | Deterministic phase order | SHIPPED | `TickScheduler._system_less` sorts (phase, id); `test_scheduler.gd` |
| 2.5 | Fine and coarse advance | SHIPPED | `TickScheduler.advance_fine_n/advance_coarse_n`; `test_city_sim.gd` |
| 2.6 | Day/night curves, modifier channels | SHIPPED | `sim/time/day_curve_set.gd`, `modifier_stack.gd`; `test_day_curves.gd` |
| 2.7 | Timers vs work units | SHIPPED | `timer_service.gd`, `work_service.gd`; `test_timer_work.gd` |
| 2.8 | Scheduled events | SHIPPED | `sim/time/scheduled_events.gd` |
| 2.9 | Pause and speed | SHIPPED | `SimHost` accumulator + `CityHUD` speed rail |
| 2.10 | Offline catch-up planner | ~~PARTIAL~~ **SHIPPED 2026-08-19** | `main.gd._on_app_resumed` (line 1232) calls `CatchUpPlanner.plan()` and walks its segments, so the grace window, the 12-hour cap, the head-align and the residual carry all apply on the path the app actually runs. **D-1 closed.** |
| 2.11 | Notification pre-scheduling | ~~ABSENT (platform half)~~ **SHIPPED 2026-08-20** | Both halves exist now. `scheduled_events.gd` carries the `notify` flags per phase, `game/notifications/notification_scheduler.gd` turns the deterministic ones into a plan, `NativeNotificationSink` hands the plan to `SlacumNative`, and `android/plugins/slacum_native/…/NotificationCenter.kt` sets the `AlarmManager` alarm and creates the channel (with `AlarmReceiver.kt` firing it and `BootReceiver.kt` re-arming across a reboot). `main.gd:111–113` wires the router and the sink. What is unproven is the *device*, and that belongs to doc 13 §2.5's row rather than to this one — this row is about whether the pre-schedule exists, and it does. |
| 2.12 | Performance budget | SHIPPED | `tools/profile_sim.gd` per-phase table + `--baseline` identity gate |

## 2. Doc 02 — Buildings

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.1 | Roster & taxonomy | SHIPPED | `BuildingCatalog.ARCHETYPE_COUNT` = 12; `test_building_catalog.gd` |
| 2.2 | Curve family | SHIPPED | `data/buildings.json` generated by `tools/gen_buildings.py`; catalog validates every cell |
| 2.3 | Full stat tables | SHIPPED | 60 rows validated at boot; `test_building_catalog.gd` |
| 2.4 | Coverage reach table | ~~IN FLIGHT~~ **SHIPPED 2026-08-19** | the sibling branch landed. `sim/incidents/coverage_index.gd` is §2.9's formula verbatim and `sim/incidents/city_incident_world.gd:188` reads `coverage_radius_tiles` off the catalog to build its station rows; 12 tests in `tests/test_coverage.gd`, anchored on the doc's own worked example E6 at radius 23. |
| 2.5 | Runtime outputs | SHIPPED | `Building` publishes population/jobs/demand; consumed by `PopulationSystem`, `PowerGrid`, `WaterSystem` |
| 2.6 | Condition & decay | SHIPPED | `Building.decay` + `CitySim.apply_hourly_decay`; `test_building.gd` |
| 2.7 | Fire ignition | SHIPPED | ignition rates in the catalog, dynamics in `sim/incidents/fire_spread.gd` |
| 2.8 | Crime attractiveness | SHIPPED | `crime_weight` column feeds doc 06 generation |
| 2.9 | Service coverage | ~~IN FLIGHT~~ **PARTIAL** | *(re-graded 2026-08-19)* The field itself ships: `CoverageIndex` + `CityIncidentWorld.coverage_police/coverage_fire`, consumed by doc 06's crime generation (`IncidentSystem`, `× (1 + 0.15 · coverage_police)`) and rendered by the POLICE/FIRE overlays, which read `req_police_coverage` / `req_fire_coverage` per building (`main.gd:832`). **Two consumers are still missing**, and grep is the proof: `safety_coverage_factor` is read only by the catalog validator and one test, and §2.9's upgrade gates `E_FIRE_COVERAGE` / `E_POLICE_COVERAGE` do not exist anywhere in the tree — so falling below a requirement costs a player nothing yet. |
| 2.10 | Construction & upgrade timing | SHIPPED | `ConstructionQueue`; `test_construction_stages.gd` |
| 2.11 | Upgrade preconditions | SHIPPED | `BuildController.UPGRADE_CHECKS` + `CitySim.cmd_upgrade_building` |
| 2.12 | Building state machine | SHIPPED | eight states in `Building`; `test_building.gd` |
| 2.13 | Construction projects & queue | SHIPPED | `sim/construction/`; `test_construction_queue.gd` |
| 2.14 | **The sixth rung — the tower tier** | **SHIPPED** *(row added 2026-08-20; the section had never been counted)* | Six of the twelve archetypes carry a level 6 in `data/buildings.json` (house, apartment, store, office, high_rise, data_center) and the other six stop at 5, which `tests/test_asset_completeness.gd::test_01` now holds as a contract in both directions. The rung is drawn (`game/meshes/generated/*_L6_lod{0,1}.res`, the `crown_setback` marker in `data/building_shapes.json`), it is reachable (`GoalSystem`'s `upgrade_to_level` kind, `data/goals.json` level 6), and it is balanced (doc 92 §24, gate 21's 45-game-day horizon). |

## 3. Doc 03 — Economy

~~Doc 92's balance pass 3 walked this document end to end; every row below is
shipped and gated. Listed for completeness rather than for news.~~

**That sentence is why §2.9 was wrong for six waves.** Doc 92 walks the numbers
this doc *authors*; it does not walk the *loaders* that would let a player choose
between them, and a document listed "for completeness rather than for news" is a
document nobody re-reads. §2.9 is now PARTIAL — see **A91-D-19** — and it is the
single largest grade regression this re-audit found.

| § | Subject | Grade | Pointer |
|---|---|---|---|
| 2.1 | Settlement loop | SHIPPED | `EconomySystem.settle_hour`; `test_economy.gd` |
| 2.2 | Tax revenue formula | SHIPPED | `EconomySystem` + `CitySim.cmd_set_tax_level` |
| 2.3 | Capital value & upgrade curve | SHIPPED | `CostCurves` |
| 2.4 | Expense model | SHIPPED | `Treasury` + maintenance fit (Wave 4) |
| 2.5 | Non-tax revenue, repairs, PM — **and, since Wave 14, the two state grants and the `city_services` line** | SHIPPED | `cmd_repair_building`, `CostCurves.repair_cost`. **§2.5a (state grants, RR-79) and §2.5's `city_services` line (RR-78) are graded here** rather than as rows of their own — §2.5a is a `####`, and the promotion list is closed (see the count table's basis rule). Both ship: `CostCurves.founding_assistance_per_hour(day)` and `level_up_grant(level)` off `data/economy.json`'s `FOUNDING_ASSISTANCE_PER_HOUR 172` / `FOUNDING_ASSISTANCE_DAYS 7` / `LEVEL_UP_GRANT_BY_CITY_LEVEL`, booked by `EconomySystem.settle_hour` as the `assistance` and `city_services{dispatch,street}` revenue lines (`sim/economy/economy_system.gd:400`, `:468`, `:499`), with `tests/test_city_services.gd` and doc 03 §7 tests 47–49. Doc 92 §36; doc 93 §R1–§R3; **A91-D-38** and **A91-D-34** are the two defects this work closed |
| 2.6 | Net-income presentation | SHIPPED | `ui/budget_model.gd`, HUD net chip |
| 2.7 | Land purchase price | SHIPPED | `CitySim.land_price_inputs` + `EconomySystem.land_price` |
| 2.8 | Land development phase costs | SHIPPED | `CitySim._development_phase_cost` |
| 2.9 | Difficulty | ~~PARTIAL~~ **SHIPPED 2026-08-20 — A91-D-19 closed** | `data/difficulty.json` + `sim/economy/difficulty.gd` + the founding seam (`CitySim.found_with_difficulty`) + the front-door chip + S9's read-only row + doc 08 city section v6 + doc 92 §29's four-preset measurement + gate 29. The one thing §2.9 asked for that did NOT ship is the one doc 93 §K1 ruled out: mid-city difficulty changes and `save.assisted`. Everything below is the original PARTIAL filing, kept as the record: ~~The pointer this row carried, `data/difficulty.json`, **does not exist**, and it is the only broken file pointer in this entire document. §2.9 asks for one file with four sections × four presets, one loader (`sim/economy/difficulty.gd`), and difficulty changeable at any time with `save.assisted`. What ships: **no file**, **no loader**, and `Treasury.DIFFICULTY_STANDARD` (`sim/economy/treasury.gd:32`) compiled into the class. `CitySim` constructs `Treasury.new(econ_curves.economy_data())` (`sim/city_sim.gd:197`) with **no difficulty argument at all**, so the economic row is permanently `standard` and three of §2.9's four authored presets are unreachable by anything. The other two sections were never centralised either — `data/director.json` still holds `pressure` and `data/incidents.json` still holds `escalation`, each with its own fallback reader, which is exactly the scattering C-17 ruled against; `data/economy.json:166` says the knobs "MOVED" to a file that was never written. `save.assisted` appears nowhere in the tree.~~ |
| 2.10 | Anti-bankruptcy floor | SHIPPED | austerity + credit ladder; the soak's random player was refused `E_AUSTERITY` 47 times |
| 2.11 | Offline income rules | SHIPPED | coarse path settles hourly; `test_city_sim.gd` |
| 2.12 | Treasury pacing | SHIPPED | doc 92 pass 3, `tests/test_balance_gates.gd` |
| 2.13 | Currency ladder | SHIPPED | `CostCurves` is the sole authority |

## 4. Doc 04 — Power grid

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.1 | Topology | SHIPPED | `PowerGrid` feeders/transformers/ties |
| 2.2 | Component stat ladders | SHIPPED | `data/grid_components.json` |
| 2.3 | Demand model | SHIPPED | `CitySim.compose_demands` |
| 2.4 | Load-flow solve, four passes | SHIPPED | `PowerGrid.solve`; `test_power_grid.gd` |
| 2.5 | Overload → protection trips | SHIPPED | `test_power_grid.gd` |
| 2.6 | Heat → failure probability | SHIPPED | `theta_c` / `trip_accum` on every component |
| 2.7 | Weather couplings | SHIPPED | `sim/weather/grid_strike_adapter.gd` |
| 2.8 | Failure types & incidents | SHIPPED | `IncidentSystem.on_power_event`; `test_incidents_transformer_arc.gd` |
| 2.9 | Cascades, ties, N-1 | SHIPPED | `_ties` + `_tag_cascade` |
| 2.10 | Backup generators (fuel) | **PARTIAL** *(re-verified 2026-08-20)* | doc 04 owns the generator; only doc 05's `cmd_install_backup_generator` exists, and *it* is unreachable — no `CitySim` wrapper, so §17.2 lists it among the seven verbs no shell can call. **No fuel model in `PowerGrid`**: grep for `fuel` under `sim/power/` returns nothing at all, and doc 05 has since *retreated* from the model rather than doc 04 adopting it — `water_system.gd:1410` erases `fuel_l` on migration and `water_snapshot.gd:9` says `fuel_hours_left` is "deliberately absent". So the one fuel model in the tree was deleted and the one this row asks for was never written. **Wave 12 rules the consequence rather than leaving it dangling (doc 93 §N3):** `cmd_install_backup_generator` is doc 05's INTERFACE CALL and stays wrapper-less *until doc 04 ships the generator* — as shipped it grants a permanent `coverage_frac` on a dark node for no dollar, so a door on it would sell the benefit with none of the price. This row stays **PARTIAL** and the re-open condition is doc 04 §2.10's capital / tank / burn / refuel. |
| 2.11 | Black start | DEFERRED | deferred by the doc (spec §13.4) |
| 2.12 | Offline catch-up | SHIPPED | `PowerPhaseSystem.advance_coarse` |
| 2.13 | Worked examples | SHIPPED | reproduced in `test_power_grid.gd` |

**Placement scope note.** `data/grid_components.json` states plainly that Wave 1.5
ships placement of *one* component — the transformer — and that
`upgrade_power_component`, `demolish_power_component`, `route_feeder` and
`place_tie` stay unplaceable until their commands land. That is honest, and it is
still a gap: three quarters of doc 04's §4 verb list has no player.

**Visibility gap — CLOSED 2026-08-20.** Every row above graded SHIPPED on the
SIM, and until this date **none of doc 04's distribution end had any
representation on screen.** A transformer is not a building (§2.1: one tile,
`FLAG_OCCUPIED`, no footprint row), so nothing in the renderer was drawing one; a
player could read an overlay tint and an Infrastructure row but could not see
where the transformer serving their block stood, which buildings it fed, or that
it was cooking. The grade was right and the game was still missing the object.
Doc 11 §2.10b now draws the pads, the service drops and the distress, off two new
read-only `PowerGrid` accessors and doc 04's own bands — `tests/test_power_infra.gd`,
+1 draw call at Z2, hash-neutral on both baseline cities. Worth recording as a
class of gap this audit's per-§ grading cannot see: **a subsystem can be fully
shipped and wholly invisible**, and the two facts do not contradict each other.

## 5. Doc 05 — Water

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.1 | The graph | SHIPPED | `WaterTopology`, `WaterNode`, `WaterEdge` |
| 2.2 | Pressure zones | SHIPPED | `PressureZone`; `test_water_system.gd` |
| 2.3 | Per-tile static factor | SHIPPED | `WaterData` |
| 2.4 | Demand aggregation | SHIPPED | `WaterDemandCache`; `test_water_data.gd` |
| 2.5 | Supply chain availability | SHIPPED | `WaterSystem` |
| 2.6 | Power dependency & backup | SHIPPED | `CitySim._water_kw_by_building` |
| 2.7 | Tank drain / refill | SHIPPED | `test_water_system.gd` |
| 2.8 | Pressure factor | SHIPPED | `WaterServiceLedger` |
| 2.9 | Failure model | SHIPPED | `WaterFailureModel`; `test_water_failures.gd` |
| 2.10 | Contamination | DEFERRED | stub by the doc's own wording |
| 2.11 | Effects on buildings/happiness | SHIPPED | `test_water_integration.gd` |
| 2.12 | Repair mechanics | SHIPPED | `WaterRepairJobs` |
| 2.13 | C-34 rescale | SHIPPED | applied; `test_water_data.gd` |
| — | **Player verbs** | **SHIPPED** (Waves 5 / 10 / 11) | `WaterSystem` exposes ten `cmd_*`; `CitySim` re-exports the five a player needs and all five now have surfaces — `cmd_place_water_component` (build sheet, Wave 5), `cmd_place_water_main` (drag-path cards, Wave 10), `cmd_upgrade_water_component` (S5's node block, Wave 11) and `cmd_isolate_water_main` / `cmd_restore_water_main` (S6's row, Wave 11). Original filing: ~~none is re-exported, so `ui/build_controller.gd` cannot see them and no card exists.~~ See **D-4**. |
| — | Overlay | PARTIAL | mode 2 ships (`OverlayModel.MODE_WATER`), but with no verbs the overlay is diagnosis without treatment |
| 2.14 | **Worked examples A–F** | **PARTIAL 2026-08-20 — A91-D-25** *(row added; the section had never been counted)* | The examples reproduce, and `tests/test_water_system.gd` says so — but **one stated input in §2.14 disagrees with the store**. §2.14 quotes `water_demand_commercial = 0.45 at h22`; `data/time.json`'s authored keyframes (`[21, 0.65]`, `[23, 0.35]`) interpolate to **0.50**, and C-33 makes `data/time.json` the store. `tests/test_water_data.gd:51–55` records the disagreement in a comment and asserts the store's 0.50; the worked examples are driven from injected channels so they still pass. A doc quote, not a code bug — and a doc quote that has stood since the R-09/R-10 rescale. |
| — | **Player verbs** *(duplicate of the row above; kept for its record)* | ~~PARTIAL~~ ~~PARTIAL — narrower~~ **SHIPPED 2026-08-20 (Wave 12)** | **The maintenance half got its doors.** This row's remaining gap was *"`cmd_upgrade_water_component`, `cmd_isolate_water_main` and `cmd_restore_water_main` are re-exported by `CitySim` and reached by no surface"*. All three are reached now — `ui/water_actions.gd:216` puts the upgrade on S5's building panel as a node block, and `:274` / `:280` put isolate/restore on S6's expanded drawer row (doc 93 §J1, Wave 11). The water-NODE panel this row asked for was not built and did not need to be: the node hangs off a shell that already has a panel. **This row and the SHIPPED "Player verbs" row above it are the same row graded twice by two waves** — the count table counts it once, and the one above is the current text. Original filing: The row as written is retired: `CitySim` now re-exports six of doc 05's verbs and **three of them have player doors** — `cmd_place_water_component` (the build sheet's infrastructure tab, `ui/build_controller.gd`), `cmd_place_water_main` (the drag-path tool, `ui/path_tool.gd`), and the pump/tank/treatment shells they place are real doc-02 buildings. What is still doorless is the *maintenance* half: `cmd_upgrade_water_component`, `cmd_isolate_water_main` and `cmd_restore_water_main` are re-exported by `CitySim` and reached by no surface — the first is driven by `tools/playtest.gd` and the other two by **nothing at all, not even the harness**. They want a water-NODE panel that doc 12's screen map does not have. See §17 and **D-4**. |
| — | Overlay | ~~PARTIAL~~ **SHIPPED 2026-08-20** | `OverlayModel.MODE_WATER` ships and is no longer diagnosis without treatment: the two verbs that answer a low-pressure zone (place a pump, run a main) both have doors. All **six** of `data/ui.json.overlay.enabled_modes` are live, which also closes doc 12 §2.5's "3 of the doc's modes". |

## 6. Doc 06 — Incidents and dispatch

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.1 | Sub-step integrator | SHIPPED | `IncidentSystem.advance_to` |
| 2.2 | Incident object & FSM | SHIPPED | `Incident`; `test_incidents_core.gd` |
| 2.3 | Severity model | SHIPPED | `test_incidents_core.gd` |
| 2.4 | Escalation math | SHIPPED | `test_incidents_lifecycle.gd` |
| 2.5 | Resolution math | SHIPPED | `test_incidents_lifecycle.gd` |
| 2.6 | Generation | ~~PARTIAL~~ **SHIPPED 2026-08-20** | **D-6 closed and re-measured twice since.** `data/incidents.json`'s `ambient_floor` is a per-channel `max()` under §2.6's generation, and all five generators that can have a candidate source now do (`CityIncidentWorld.water_mains()` and `road_intersections()` were the two that did not — D-17/D-18). Measured, 12 seeds × 28 game-days of `do_nothing`: **6.62 ambient incidents/game-week** against the ≈0.5/week this row was filed for, 318/318 resolved, 0 failed, 0 destroyed (doc 92 §18.6, gate 19). The band itself was re-ruled to 5–8/week in doc 92 §18.7 because the 2–4 was fitted while a third of the generator surface was disconnected. |
| 2.7 | Catalog | SHIPPED | `IncidentCatalog` / `data/incidents.json` |
| 2.8 | Fire spread & suppression | SHIPPED | `sim/incidents/fire_spread.gd` |
| 2.9 | Dispatch priority scoring | SHIPPED | `DispatchSystem` |
| 2.10 | Assignment algorithm | SHIPPED | `DispatchSystem._assign`; `test_incidents_dispatch.gd` |
| 2.11 | Vehicle model & FSM | SHIPPED | `Vehicle`; `test_vehicle_motion.gd` |
| 2.12 | Auto-dispatch policy | ~~PARTIAL~~ **SHIPPED 2026-08-19 (Wave 6), re-verified 2026-08-20** | Seven `policy: "dispatch"` rows in `data/ui.json.settings.rows` (`auto_dispatch_fire/police/utility/water`, `fire_reserve_units`, `auto_repair_cost_cap`, `auto_spend_contractor`), defaulting from `data/dispatch.json.policy_defaults` and writing through `UIRoot.bind_dispatch_policy` → `cmd_set_dispatch_policy` (`main.gd:808`). **D-11 closed.** And the second half of this row's sentence is closed too: **D-2 no longer follows from the default**, because step 9 gained the `any_of` it asked for (doc 12 §2.17). |
| 2.13 | Offline catch-up integration | SHIPPED | `world.offline` gate; `test_incidents_lifecycle.gd` |
| 2.16 | **The opportunity layer — the street events the player TAPS** | **SHIPPED 2026-08-21 (Wave 14)** *(row added at the Wave-14 merge; the Wave-13 Total counted this section from the branch's note and §6 never gained the printed row — the exact drift RR-76 rules against, one table down)* | `sim/street/opportunity_system.gd` + `data/street.json` + `CitySim.cmd_collect_opportunity` (`sim/city_sim.gd:3594`) + `_boot_street`; **17 tests** in `tests/test_street_opportunities.gd`, including the three that make it a *play-NOW* system rather than another accrual — `test_nothing_accrues_while_the_player_is_away` (doc 08 §2.3 rule 9, doc 93 §Q1), `test_the_coarse_path_costs_the_matrix_nothing` and `test_the_layer_moves_nothing_outside_its_own_three_keys`. Its collect verb has a door as of this merge (`ui/build_controller.gd`, doc 12 §2.21) — it was doorless BY DESIGN on the branch that shipped the sim half, and doc 93 §Q3's named self-clearing exemption is what carried it across. Report 98 RR-77; doc 92 §35; doc 93 §Q1–§Q4 |

**A numbering note, so the `grep` basis is not read as a miscount.** Doc 06 has
**no** `### 2.14` and no `### 2.15`: the opportunity layer took `2.16` on its
branch and the two numbers below it were never used. `grep -c "^### 2\.[0-9]"`
therefore reads **14** while the highest index is 16, and both are right. The
numbers are left as they are — renumbering `2.16` would break every reference in
`sim/`, `data/`, docs 03/08/09/11/12, doc 92 §35 and report 98 RR-77 to save
nothing.

## 7. Doc 07 — Weather and the disaster director

| § | Subject | Grade | Pointer |
|---|---|---|---|
| 2.1 | Weather state machine | SHIPPED | `WeatherSystem` + `WeatherTimeline`; `test_weather_system.gd` |
| 2.2 | Effect multiplier table | SHIPPED | `WeatherTables`; `test_weather_integration.gd` |
| 2.3 | Storm cell | SHIPPED | `StormCell` |
| 2.4 | Localized flooding | ~~SHIPPED~~ ~~PARTIAL~~ **SHIPPED 2026-08-20 — A91-D-26 CLOSED** | The simulation half was always exactly as the first grade said: `FloodField` is live and the soak logged 460 `flood_level_changed`. The re-audit's event matrix (§18) asked the next question and the answer was **nothing consumes that event**. It does now, by three routes and on purpose: **drawn** by `game/render/flood_view.gd` (doc 11 §2.9b — one MultiMesh over the flooded block's ROAD tiles, +1 draw call at every pose, +0.15 ms GPU at Z0 in the worst case the layer can be asked for); **logged** at the 100 mm and 200 mm bands plus `road_reopened`; **pushed** as `flood_started` (P2) and `flood_deepening` (P1), with a once-per-session toast on the first band a player meets. The 40 mm nuisance band is drawn and deliberately never narrated — doc 93's event ruling in one line: *narrate the bands that change what the player can do, draw the ones that only change how the street looks.* Hash-neutral: no `sim/`, no `data/weather.json`, both cities' state hashes unchanged. |
| 2.5 | Forecast | SHIPPED | `WeatherForecast`; `test_weather_forecast.gd` |
| 2.6 | Disaster Director v1 | SHIPPED | `DisasterDirector` + `IncidentRequestSink`; `test_weather_director.gd` |
| 2.7 | MVP severe thunderstorm | SHIPPED | `sim/weather/severe_thunderstorm.gd`; `test_weather_lightning.gd` |

## 8. Doc 08 — Offline and persistence

The weakest document in the tree, and the one whose gaps are invisible from
inside the game.

*Re-graded 2026-08-19 (Wave 7). Five rows moved PARTIAL → SHIPPED and three more
had their pointers corrected, almost all for the same reason: the unification
landed and `game/save_service.gd` now rides `sim/persistence/save_manager.gd`
instead of a second format of its own. The pre-unification grades are struck
rather than deleted, because the audit's value is the record of what was actually
wrong.*

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.1 | Division of labour with doc 01 | SHIPPED | respected in `CitySim` |
| 2.2 | Fidelity bands / cap policy | ~~PARTIAL~~ **SHIPPED 2026-08-19** | `main.gd._on_app_resumed` (line 1232) plans the resume through `CatchUpPlanner.plan()` and walks its segments, so the 12-hour cap, the two-minute grace and the residual carry all apply on device. **D-1 closed.** |
| 2.3 | Anti-frustration invariants | ~~PARTIAL~~ **PARTIAL — narrower** | `tests/test_catchup_planner.gd` and `tests/test_qa_soak.gd::test_planned_resume_advances_a_live_city_from_any_tick` now assert against the same planner call the shell makes, so the divergence the row was filed for is gone. What is still untested is `main.gd`'s own body — no headless test drives `_on_app_resumed`. |
| 2.4 | Auto-response during catch-up | SHIPPED | `IncidentWorld.offline` |
| 2.5 | Save file layout | ~~PARTIAL~~ **SHIPPED 2026-08-19** | One format. `SaveService.save_slot` builds three `DictSection`s and commits them through `SaveManager.request_save`; a slot is `user://saves/slot_N/{manifest.json, gen_%06d.sav, quarantine/}`. `tests/test_save_service.gd::test_a_slot_is_a_generation_ladder`. |
| 2.6 | Atomic write protocol | SHIPPED | ~~both writers~~ **the one writer** does temp + rename — `SaveManager._write_compressed_atomic` / `_write_manifest_atomic`, the manifest rename being the commit point |
| 2.7 | Checkpoint cadence & rotation | ~~PARTIAL~~ **SHIPPED 2026-08-19** | `_apply_retention` / `_sweep` run on every shell save, off `data/persistence.json.save` through `SavePolicy` (6 unpinned + 2 pinned; 0/30 min/6 h/24 h/7 d). `save_slot(sim, slot, reason)` carries §2.7's reason, so `pre_migration` / `pre_catchup` pin from the shell. `test_retention_comes_from_data_and_bounds_the_slot`, `test_a_pinned_checkpoint_is_never_swept`. |
| 2.8 | Versioning & migration | ~~PARTIAL~~ **SHIPPED 2026-08-19** | Both levels. Envelope: `SaveManager.CURRENT_SCHEMA_VERSION` + `LADDER`; section: `DictSection.section_version()` with the sim's own `migrate_save_section` hook. Format 1 → 2 is a real migration with a real fixture — `tests/test_save_migration.gd` runs nine tests against `tests/fixtures/legacy_slot_format1.json`, a byte-for-byte capture of a pre-change write that is never regenerated. |
| 2.9 | Load & corruption recovery | ~~PARTIAL~~ **SHIPPED 2026-08-19** | `SaveService.load_slot` is the §2.9 gate: candidate walk, SHA-256, version range, structural repair, quarantine, then the format-1 file as a last pinned candidate. `last_load_recovered` / `last_load_lost_minutes` / `repair_notes` carry the "you lost about N minutes" figure back to the UI. `test_a_ruined_generation_falls_through_to_the_one_behind_it`, `test_delete_takes_the_quarantine_with_it`. |
| 2.10 | Event history rings | **ABSENT** | `ui/event_log_model.gd` keeps a session-lifetime ring in memory; nothing persists it, so the log is empty on every launch |
| 2.11 | WHILE YOU WERE AWAY report | SHIPPED | `AwayModel` + `AwayReportSheet`, driven from `main.gd._on_app_resumed` |
| 2.12 | Performance budget | SHIPPED | soak: a 45-minute absence catches up in **1.04 s** (43 coarse hours) |
| 2.13 | Notification policy | ~~ABSENT~~ **PARTIAL 2026-08-20 — A91-D-27** | The *policy* now reaches the router: S10's five rows ship in `data/ui.json.settings.rows` (`notifications_enabled`, `notify_p1_critical`, `notify_p2_important`, `notify_p3_routine`, `quiet_hours_allow_critical`) and `main.gd:1131` calls `notification_router.apply_settings(model.capture_state())`, so a player's choices are honoured for the session. What is still absent is the *state*: `NotificationRouter.serialize()` / `deserialize()` (`notification_router.gd:634–641`) are complete, tested, and **called by nothing outside `tests/`** — `game/save_service.gd` registers exactly three sections (`city`, `ui`, `meta`) and none of them is the budget. Token ledgers, per-type cooldown keys and quiet-hours state therefore reset on every launch, which means the global cap can be spent twice in a minute across a restart. Doc 13 §2.4/2.5 is the platform half. |
| 2.14 | Threaded write; the load costed | **SHIPPED** *(row added 2026-08-20; the section had never been counted)* | `SaveManager.capture_save` / `commit_save` are the split, `SaveService.async_writes` hands the second half to `WorkerThreadPool`, and `SYNC_REASONS` keeps `pause` / `quit` / the two pins synchronous. `tests/test_save_service.gd`'s async block drives both arms. The section's *refusal* — threading the READ half buys 7 % — is re-measured and still stands at §2.15.2 (28 ms of read against 202 ms of restore). |
| 2.15 | Both halves get their lever | **SHIPPED 2026-08-20** *(row added with the section)* | `SaveSection.finalize()` moves the float canonicalisation onto the write thread (`DictSection.finalizer`, `SaveService._city_finalizer`, `CitySim.encode_captured`); `CitySim.capture_detached()` is what stays on the sim's thread; `CitySim.begin_restore()` returns a `RestoreCursor` of eleven steps and `SaveService.begin_load_slot` / `step_load` are the shell's handle on it. Benchmark city, best of 7: save caller **85.4 → 39.2 ms** async and **125.3 → 106.4** synchronous, restore **396.8 → 202.1**, longest single step **76.5**. Proofs in `tests/test_save_chunked_restore.gd` (16 tests, 146 asserts): byte-identical codec output against a reference walk, stepped ≡ monolithic on both cities and on a mid-storm mid-incident body, save → load → advance through the cursor, and `capture_state()` asserted to hand out no live container. Report 98 §24 RR-49/RR-50; the section cache the brief proposed is refused with measurements at RR-51. **The one thing not shipped is the veil itself** — doc 13 §2.9 has assumed a loading veil since it was written and the shell has never had one; the title door standing in for it is the integration this wave hands over rather than performs. |

~~**And the one nobody has noticed:**~~ **Closed 2026-08-19.** `UIRoot.capture_ui_state()`
/ `restore_ui_state()` implement doc 12 §3.2's `ui` block — overlay choice,
settings, and the onboarding block — and the shell now wires both ends:
`main.gd:683` assigns `save_service.ui_provider = root.capture_ui_state`, and
`main.gd:685` / `main.gd:1013` apply `save_service.last_loaded_ui` once the UI
exists. The section rides the envelope beside `city`
(`tests/test_save_service.gd::test_ui_section_rides_the_envelope`) and survives
the format change (`tests/test_save_migration.gd::test_the_ui_section_survives_the_format_change`),
so a finished tutorial stays finished across a restart. **D-3 closed.**

## 9. Doc 09 — Map, land, starter city

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.1 | Coordinates & extents | SHIPPED | `TileGrid`, 112² tiles |
| 2.2 | Land block schema | SHIPPED | `LandBlock`; `test_world_map.gd` |
| 2.3 | Ownership & development FSM | SHIPPED | `DevelopmentController`; `test_development.gd` |
| 2.4 | Purchase pricing inputs | SHIPPED | `CitySim.land_price_inputs` |
| 2.5 | Adjacency purchase rule | SHIPPED | `WorldMap.purchase_allowed` |
| 2.6 | Districts & city_stability | SHIPPED | `DistrictRegistry`; `test_districts.gd` |
| 2.7 | Elevation | SHIPPED | `LandBlock.elevation_m` |
| 2.8 | The 7×7 world | SHIPPED | `data/world.json` |
| 2.9 | The Starter City | SHIPPED | `StarterCityLoader`; `test_starter_city.gd` |
| 2.10 | Population, occupancy, happiness | SHIPPED | `PopulationSystem`, `HappinessModel`; `test_population.gd` |
| 2.11 | City level & progression | SHIPPED (but see D-7) | `ProgressionSystem` works; the soak's city sat at **level 0 for 12 game-days** and refused 376 upgrades with `E_CITY_LEVEL`. See **D-7**. |
| 2.12 | Lifetime stats | SHIPPED | `StatsRecorder` |
| 2.13 | Benchmark-city fixture | **SHIPPED 2026-08-19** | `tools/gen_bench_city.py` → `tests/fixtures/bench_city.json`, 1,500 buildings. The matrix is measured and two budgets were broken by it — **D-14** (draw calls, **fixed**: Z2 352 → 219 with UI against 320), **D-15** (sim step, open). See **D-8** and doc 11 §2.13's as-shipped table. |
| 2.14 | **The goal curriculum** | **SHIPPED** *(row added 2026-08-20; the section had never been counted)* | `sim/progression/goal_system.gd` (twelve `EVENT_KINDS`, four `STATE_KINDS`, one endurance kind — fourteen of the seventeen used, §17.4), `data/goals.json` (six levels), `ui/goals_model.gd` + `ui/goals_sheet.gd` (S14), the goal chip in the HUD, and the tutorial's twelfth step handing off to it. `tests/test_goals_system.gd` holds `data/goals.json` to the reachable verb set; gate 21 holds the pacing over a 45-game-day horizon; doc 92 §26 measures all six levels completing on all three seeds. §17's verb matrix confirms every objective kind lands on a verb that has a door. |

## 10. Doc 10 — Roads and traffic

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.1 | Units & calibration | SHIPPED | `RoadTunables` |
| 2.2 | Road tiles | SHIPPED | `TileGrid.FLAG_ROAD` |
| 2.3 | Road classes | SHIPPED | `data/roads.json` |
| 2.4 | Graph build | SHIPPED | `RoadGraph`; `test_roads_graph.gd` |
| 2.5 | Incremental rebuild | SHIPPED | `RoadNetwork.edit_tile` + pending-edit queue |
| 2.6 | Cost function | SHIPPED | `RoadCosts`; `test_roads_costs.gd` |
| 2.7 | A* routing | SHIPPED | `RoutePlanner` |
| 2.8 | Closures | SHIPPED | flood closures fired 92× in the soak |
| 2.9 | Reachability & components | SHIPPED | `RoadGraph` |
| 2.10 | Congestion model | SHIPPED | `CongestionModel`; `test_roads_congestion.gd` |
| 2.11 | Traffic accidents (doc 06's) | SHIPPED | routed through `IncidentCatalog` |
| 2.12 | Road condition & damage | SHIPPED | `RoadNetwork._condition` + weather wear |
| 2.13 | **Build, upgrade, demolish** | ~~PARTIAL~~ **SHIPPED (verbs Wave 5, surface Wave 10)** | `CitySim.cmd_place_road` / `cmd_upgrade_road` / `cmd_demolish_road` land in Wave 5; the build sheet's **ROADS tab** and doc 12 §2.7's drag-path tool (`ui/path_tool.gd`) reach all three in Wave 10, with the L-run preview, the live per-tile cost and the fresh-tile billing the doc asks for. Roads are no longer immutable and no longer only doc 09's. See **D-5** and report 98 **RR-30**. |
| 2.14 | Routing performance budget | SHIPPED | `test_roads_graph.gd` bounds the rebuild |
| 2.15 | Cosmetic civilian traffic | **PARTIAL** | `TrafficFeed` ships and drives `VehicleView`; the traffic **overlay** is a per-edge MultiMesh built from `TrafficSnapshot.visible_edges` rather than the polyline doc 10 §2.15 describes. Cosmetic-only difference, called out because the overseer asked. |

## 11. Doc 11 — Rendering and performance

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.1 | Scene architecture | SHIPPED | `game/main.gd` + `game/render/` |
| 2.1.1 | Water | SHIPPED *(row added 2026-08-20)* | `GroundSurface.water()` + `game/shaders/water.gdshader`; two octaves, no reflection probe, constants from `data/render.json.water_surface`; `tests/test_render_polish.gd` tests 22–24, and the night floor in `tests/test_atmosphere_shaders.gd`. |
| 2.1.2 | The street — asphalt, markings, kerbs, footways | SHIPPED (2026-08-20) | `RoadSurfaceView` + `road_surface.gdshader` / `sidewalk.gdshader`, off doc 10's `RoadGraph`; `test_road_surface.gd`. Two draw calls city-wide, zero added texture memory. |
| 2.1.2a | …and its rebuild is a **dirty-tile diff** | SHIPPED (2026-08-20) | Closes §2.1.2's open question 2, and it became urgent the wave a road-drawing tool shipped. **19.7 → 4.87 ms** on the benchmark city, **4.76 → 1.18 ms** on the founding one, picture identical to the instance. `tests/test_road_incremental.gd` property-tests the only contract a stateful diff can have — buffers byte-identical to a from-scratch rebuild after any edit sequence — over 40 × 12 random edits, 24 × 10 against water and the map edge, and a ten-tile drag through the founding city. Report RR-31. |
| 2.2 | Chunk lifecycle & slots | SHIPPED | `CityView` chunk buckets with hysteresis |
| 2.3 | Sim → render data flow | SHIPPED | `main._on_sim_batch` → `RenderStateModel` |
| 2.4 | Global shader parameters | SHIPPED | `sc_overlay_mode`, `sc_wetness`, … |
| 2.5 | Camera & LOD bands | SHIPPED | `CameraState` + `CityView.update_chunk_tiers` |
| 2.6 | MultiMesh + per-instance data | SHIPPED | `test_render_state.gd` |
| 2.7 | THE BLACKOUT | SHIPPED | `BlockDarkChanged` → `StreetlightView`; `--blackout` screenshot arg |
| 2.8 | Sky, day/night, fog, glow | SHIPPED | `EnvironmentController` |
| 2.9 | Weather VFX | SHIPPED | `WeatherFX`; `test_weather_fx.gd` |
| 2.10 | Streetlights | SHIPPED | `StreetlightView`; `test_power_streetlights.gd` |
| 2.10.1 | Lamp placement + the cobra head | SHIPPED (2026-08-20) | `StreetlightPlacer` + `CobraHeadMesh`. Replaces the `(x + z) % 4` parity rule that stood every pole in the carriageway; fixes STREET-1, the ground pool uploaded under the road slab. |
| 2.10.1 | …and lamps are **live on a road edit**, not boot-time | SHIPPED (2026-08-20) | Closes §2.10.1's open question 1. `RenderStateModel.remove_streetlight` is the API that did not exist, `add_streetlight` is idempotent (its unconditional append put one id on a block roster twice — the double-stutter blackout hazard the streets branch filed), and `StreetlightView.apply_lamps` diffs on the PLACEMENT key so a lamp that did not move keeps its id, its `anim_phase` and whatever ramp it is in. `test_road_surface.gd` 18 / 18b, `test_render_state.gd` 19a. |
| 2.11 | Overlay mechanism | SHIPPED | `RenderStateModel.set_overlay_channel` |
| 2.12 | Vehicles | SHIPPED | `VehicleView` + `VehicleMotion` |
| 2.13 | Budgets, device matrix, **adaptive governor** | ~~PARTIAL~~ **SHIPPED 2026-08-20** | All three halves of the row now exist and every one of them has been measured. **The governor**: `game/render/perf_governor.gd` — a `RefCounted` model fed a frame time every frame and a thermal status from `AndroidNative.thermal_status_changed`, answering with knob values the shell applies (`main.gd:340`, `:362`); `tests/test_perf_governor.gd`. It was **observed stepping its ladder on a real Fold 6** (`knob` 0 → 4 in the foreground, `thermal` 0 → 1). **The device matrix**: measured on `tests/fixtures/bench_city.json` and re-measured twice after two instrument faults were found in it (RR-35: the harness was rendering at 1280×720 while every table said 1920×1080, and every published frame was taken at hour 21 with an empty shadow pass — the daylight headroom is 18.1 %, not 31.6 %). **The budgets**: doc 11 §2.13's as-shipped table. What remains open is filed, not ungraded — **D-15** (fine tick 18.0 ms against 8), **D-16** (the NEAR bucket half, Low), and the Fold's presentation-corruption band. |
| 2.14 | Gray-box pipeline | SHIPPED | `tools/gen_graybox.gd` + `game/meshes/generated/manifest.json` |
| 2.15 | Audio | SHIPPED | `game/audio/`; `test_audio_model.gd` |
| 2.16 | LIVING CONSTRUCTION | **SHIPPED 2026-08-20** | `ConstructionRigMesh` + `construction_rig.gdshader` + `ConstructionActivity` + `ConstructionVehicleView`; `test_construction_living.gd` (3,835 asserts). Articulated plant and street-true deliveries for **+5 draw calls** and **0.46 ms** at 20 sites. Closes the "a site is a box that grows" gap left by the crane/hoarding pass. Renderer-local and hash-neutral — proved by an interleaved-lookup test, not by inspection. **Follow-up 2026-08-20:** the hoarding gate now faces the street (§2.16's open question 4) — `add_site` takes an optional frontage side and `site_frontage_changed` carries a late or moved one across, so the two construction layers stop disagreeing three times in four. And §2.16's open question 1, "one-buffer uploads", is **refused with a measurement** (report RR-32): the packed path is 2× slower than the per-instance setters in GDScript at every scale, and the layer's frame was in pose computation, not in uploads. The reductions that were there were taken instead — `_upload` 0.088 → 0.049 ms, layer CPU 0.51 → 0.45 ms. |
| 2.17 | STREET LIFE — the crook, the dog, the goat, the glint | **SHIPPED 2026-08-21** | `StreetLifeMesh` + `street_life.gdshader` + `StreetGlyphAtlas` + `street_fx.gdshader` + `StreetLifeModel` + `StreetLifeView`; `test_street_life.gd` (526 asserts). The layer that answers the playtest note *"there's not a lot of downtime of absolutely nothing to do"*: the sim's opportunity events become bodies that walk a deterministic beat on the **footway** (snapped off doc 10's road class, never a traffic lane), an attention marker that holds an **angular** size — 46 screen px at Z1, 78 at Z0, 12 at Z2 — and a collect moment with a poof and a rising `+$N`. **+4 draw calls at Z0/Z1 and +1 at Z2** against a +6 budget, layer CPU **0.131 ms** mean at five live against 0.3 ms, A/B'd with `profile_frame --street-life=0\|5`. Renderer-local and hash-neutral — proved by an interleaved full-frame test, not by inspection. Two defects were found by SCREENSHOT and could not have been found by assertion: an SDF page hinted `source_color` decodes as sRGB, so every `field > 0.5` test failed and every marker drew as an empty pin; and a label laid out along world +X skews with the camera yaw and puts its middle glyphs behind the marker. Both are pinned in the tests now. |

## 12. Doc 12 — UI/UX

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.1 | Units, breakpoints | SHIPPED | `UIRoot.breakpoint_for`; `test_ui_scaffold.gd` |
| 2.2 | Screen map | ~~PARTIAL~~ **SHIPPED 2026-08-20**, and **sixteen screens as of Wave 13** | **S15, the loading veil, is a new row of doc 12 §2.2 and ships with it** (§2.20, D-60) — its own `VeilLayer` above every other layer, two preview states and a `SURFACES` row, in the same commit as the screen. The sweep now covers **fifteen of sixteen**; S13's panel is still the one it has never opened (A91-D-28). Earlier: **All fifteen screens S0–S14 ship.** The last hole was S10, and it is filled: `data/ui.json.settings.rows` carries five notification rows inside S9's sheet, which is exactly the "page inside S9" presentation §2.2 specifies. S14 (`ui/goals_sheet.gd`) landed in Wave 9 and is the row this table never had. §19's screen matrix walks **fourteen of the fifteen** through 49 named states in `tools/ui_preview.gd` — S13's panel has no state (A91-D-28), which is a hole in the *instrument*, not in the screen map. |
| 2.3 | HUD layout | SHIPPED | `CityHUD`; `test_ui_topbar.gd` |
| 2.4 | Stat chips | SHIPPED | `HudModel`; `test_hud_model.gd` |
| 2.5 | Overlay system | ~~SHIPPED (3 of the doc's modes)~~ **SHIPPED — all six** | `data/ui.json.overlay.enabled_modes` is `["none","power","water","police","fire","traffic"]` and `OverlayModel` carries a `MODE_*` for each; POLICE and FIRE joined when doc 02 §2.9's coverage field got a publisher (`CityIncidentWorld.coverage_police/coverage_fire`). The greying machinery stays, because A14 wants a blocked chip to say why rather than vanish. |
| 2.6 | Incident drawer & dispatch UX | SHIPPED | `IncidentDrawer` + `UnitPickerSheet`; `test_ui_incidents.gd` |
| 2.7 | Build menu, placement, requirements | SHIPPED | `BuildSheet` + `BuildController` + `RequirementFormatter` |
| 2.8 | **Land purchase flow (S4)** | SHIPPED | `ui/land_panel.gd` + `ui/land_panel_model.gd`; entered by `BuildController.pick_at_ground()`; `tests/test_ui_land.gd` (26 tests) drives price, refusals, PURCHASE → DEVELOP and the six-phase list over a real `CitySim`. ~~One line in `game/main.gd` makes it reachable~~ — **landed 2026-08-19**: `main.gd:1348` calls `build_controller.pick_at_ground(ground)` and `sim_id_at_ground` is gone from the tap path (doc 12 Wave-6 D-21). S4 has its door. |
| 2.9 | Building panel (S5) | ~~SHIPPED~~ **PARTIAL** *(grade corrected 2026-08-20 to match its own pointer)* | `BuildingPanel`; upgrade checklist live. ~~Its four coverage tiles list police and fire, which nothing computes~~ — **closed 2026-08-19**: `CoverageIndex` computes both and `CityIncidentWorld.coverage_police/coverage_fire` publish them (doc 02 §2.4/§2.9). What the tiles still cannot show is a *consequence*, because §2.9's `E_FIRE_COVERAGE` / `E_POLICE_COVERAGE` upgrade gates are not implemented — grep finds neither code anywhere in the tree. The row said so and was graded SHIPPED anyway; a panel whose tile promises a `Fix this →` that costs nothing is not a shipped panel. Same root as doc 02 §2.9, and it closes with the same work. |
| 2.10 | City dashboard (S8) | SHIPPED | `CityDashboard`; `test_ui_dashboard.gd` |
| 2.11 | Pause & speed | SHIPPED | HUD rail + `PauseMenu` |
| 2.12 | WHILE YOU WERE AWAY (S11) | SHIPPED | `AwayReportSheet`; `test_ui_away.gd` |
| 2.13 | Settings (S9) & **notification settings (S10)** | ~~PARTIAL~~ **SHIPPED 2026-08-20** | **Twenty-two** rows ship, up from the sixteen this row counted: `graphics`, `autosave_interval_min`, `sound_volume`, `haptics`, `reduce_motion`, `larger_touch_targets`, `in_app_banners`, `text_scale`, `replay_tutorial`, `auto_quality`, the seven `policy: "dispatch"` rows, and **S10's five** — `notifications_enabled`, `notify_p1_critical`, `notify_p2_important`, `notify_p3_routine`, `quiet_hours_allow_critical`. The notification rows are a *view* of doc 08's policy rather than a second copy: the row key **is** the class id lowercased, so `data/ui.json` and `data/notifications.json` cannot drift, and `P4_ambient` has no row because doc 08 ships it disabled and the budget refuses to enable it. `main.gd:1131` writes them through `NotificationRouter.apply_settings`. **Still outstanding, and now the whole of the gap:** the utility restoration *order* is a list with no control. |
| 2.14 | Haptics | SHIPPED | `ui/haptics.gd` — the one vibrator call site; seven cues off `data/ui.json.haptics_ms`, fired by `BuildSheet`, `LandPanel` and `UIRoot.feed_events`/`report_dispatch_result`. `reduce_motion` suppresses it (A8) without clearing the row. `tests/test_ui_haptics.gd` |
| 2.15 | Alerts, toasts, world markers | SHIPPED | `AlertsCenter`; `test_ui_alerts.gd` |
| 2.16 | Touch camera controls | SHIPPED | `TouchInput` → `GestureRecognizer` → `CameraState`; `test_gestures.gd` |
| 2.17 | ~~**Onboarding, eleven steps**~~ **twelve** | SHIPPED | `OnboardingModel` + `OnboardingFlow`; driven end to end by `tests/test_tutorial_flow.gd` and `tools/flow_test.gd`. **Both structural risks are closed. D-2 closed 2026-08-20** and it cost the table row this audit predicted: step 9 `dispatch` now advances on `{"kind":"any_of","conditions":[{command dispatch_unit},{sim_event incident_resolved}]}`, so a player slower than the auto-dispatcher's 62 game-minutes is carried rather than wedged. **D-3 closed 2026-08-19.** A twelfth step, `next_goals`, hands the finished tutorial to S14 — so §2.17's "eleven steps" is superseded by the tree and the section wants the edit. |
| 2.18 | Accessibility checklist | ~~SHIPPED (one regression)~~ ~~PARTIAL~~ **SHIPPED 2026-08-20 (Wave 13)** | **A2 and A3 are green at every box the project runs, and the project now runs the box A2 names.** `tools/ui_preview.gd --screen=all --audit --strict` over **six** boxes × **three** text scales × 55 states — 990 state-sweeps — is **0 findings, exit 0, eighteen times** (§19.1). A91-D-21, A91-D-22, A91-D-23 and A91-D-29 are all closed. The cause under the last of them was one line in `ThemeBuilder` (doc 12 D-54): a button's stylebox padding was scaled twice, so every themed control in the deck was 37 % taller than A3 asks for. **Earlier state: **D-12 and D-13 are both closed and the sweep is clean at 100 %:** `ui/event_log.gd:73–76` now stands its chip down exactly as `ui/alerts_center.gd:221` does, `tests/test_ui_audit.gd::BOXES` gained 1280×720, and re-running `tools/ui_preview.gd --screen=all --audit --strict` at **all five boxes** gives **49 states clean, 0 findings, exit 0 at every one**. **The regression this row now carries is a different and worse one.** §2.18 says every row is a release gate, and A2 (`text_scale`) and A3 (`larger_touch_targets`) are two of them — so the sweep was re-run at `--text-scale=1.3 --large-targets`. **It fails at all five boxes**, with three distinct causes. The suite is not silent on A2 — it has one 130 % assertion — but that assertion is `min_size.x <= 360` on a single box, and every failure here is an overlap or a Y-axis overflow, so it passes while the requirement does not hold. And A2's own stated geometry — **150 % at 640 × 340 dp** — appears in no `BOXES` list in the repository; measured for the first time here it fails at 150 % *and* puts one control off-screen at **100 %** (**A91-D-29**). §19 has the table. |
| 2.19 | **S14 — the goals sheet** | **SHIPPED** *(row added 2026-08-20; the section had never been counted)* | `ui/goals_sheet.gd` + `ui/goals_model.gd` over `sim/progression/goal_system.gd`; entered from the goal chip (§2.4) or from the tutorial's twelfth step; `tests/test_ui_goals.gd`. Three of `tools/ui_preview.gd`'s 49 states are its own (`goals`, `goals_late`, `goals_done`) and all three are clean at 100 % at all five boxes. |
| 2.20 | **S15 — the loading veil** | **SHIPPED 2026-08-21 (Wave 13)** *(row added at the Wave-14 merge; the Wave-13 Total counted this section and §12's table never gained the row)* | `ui/loading_veil.gd` + `ui/veil_model.gd`, driven from `game/main.gd:1305/:1312/:1328`; `tests/test_veil_model.gd`; two `SCREENS` states (`veil_load`, `veil_catchup`) and a `SURFACES` row in `tests/test_ui_audit.gd`, **all in the same commit as the screen** — A91-D-28's lesson applied on the way in. Both halves are real: Wave 13 built the surface and Wave 14's `CatchUpCursor` (**A91-D-31**, report 98 §28 RR-73) gave the catch-up bar something to animate over, without a line changing in `ui/`. Doc 12 D-60; report 98 RR-66 |
| 2.21 | **The tap and the payday** | **SHIPPED 2026-08-21 (Wave 14)** *(row added with the section)* | The half of doc 06 §2.16 that is between a finger landing on an opportunity and the player believing they got paid. **Three seams, and each degrades rather than fails.** *(a)* the pick gets a zeroth arm — `opportunity → building → block → none` in `ui/build_controller.gd:1091`, a radius from the tapped POINT and not a tile test, converted from `data/ui.json.street.tap_dp = 48` to metres at the live zoom by `set_tap_radius_from()` (`game/main.gd:1815`); `tap_radius_m` starts at 0, so an unwired shell picks exactly as it did before. *(b)* the payday is one beat with two doors — `ui/street_model.gd` folds a collect and an `incident_resolved` into `{cue, toast, flash_chip, …}`, so the bounty a crew earned unwatched and the coin the player tapped for are the same event; `HudModel.flash_chip` is the pulse and the `cash` cue is a `data/audio.json` rule, which is why the audio half needed no shell change. *(c)* discovery is a NOTICE and not a curriculum step — `OnboardingFlow.show_notice()` borrows §2.17's dim and bubble and has no step counter, no row in `data/ui.json.onboarding.steps` and no advance condition, because the balance suite counts the tutorial's steps. `tests/test_ui_street.gd`; doc 92 §38; doc 93 §T1–§T3; report 98 RR-84. **This row also closes the remaining half of A91-D-37** — `incident_resolved` has carried `reward` since doc 06 shipped and nothing had ever sounded it, toasted it or counted it |

## 13. Doc 13 — Android integration

> **RE-GRADED 2026-08-20 (Wave 10). Five rows move ABSENT → PARTIAL, and the
> reason is one sentence: the Kotlin notification platform exists now.** The
> block below was written when it did not, and it is kept because its warning is
> the reason this pass happened. What is in the tree at this fork:
> `android/plugins/slacum_native/src/main/java/com/slacumcity/nativeplugin/` holds
> **`SlacumNative.kt`, `NotificationCenter.kt`, `AlarmReceiver.kt` and
> `BootReceiver.kt`** — channels (`createNotificationChannel`, guarded by a
> `getNotificationChannel` existence check), `AlarmManager.setAndAllowWhileIdle`
> scheduling, cancellation, and a reboot registry, because Android drops every
> alarm on restart. The GDScript half is `game/notifications/` (scheduler, router,
> budget, text, `NativeNotificationSink`, `PermissionFlow`), wired at
> `game/main.gd:111–116`. `tests/test_release_plumbing.gd` holds eleven contracts
> over the manifest, the presets and the tooling — including *"the plugin declares
> exactly the four permissions"* and *"the plugin registers itself and its two
> receivers"*.
>
> **Why none of them is SHIPPED.** Every one of the five is now blocked on the
> same single artefact: **a debug build that carries the plugin, installed on a
> device.** The 2026-08-20 Fold session measured `dumpsys package` listing **no
> requested permissions at all** and `dumpsys notification` listing **zero
> channels** — against a debug APK that does not carry the plugin. That is
> evidence about the *build under test*, not about the code, and until a build
> that carries the plugin runs on a phone, "it compiles and its manifest is
> asserted" is precisely PARTIAL and nothing more. **This is the largest single
> block of remaining work in the project (§20) and it is one build away from
> being measurable.**
>
> **That build now exists and has run on the phone — 2026-08-21, third Fold
> session. The 2026-08-20 measurement above is superseded and should not be
> re-quoted.** It was taken against an APK that did not carry the plugin; the
> APK installed on 2026-08-21 does, and the device says so at three levels:
>
> * **The manifest declares exactly the four permissions** — `aapt2 dump
>   permissions` on the installed APK returns `POST_NOTIFICATIONS`,
>   `RECEIVE_BOOT_COMPLETED`, `VIBRATE`, `WAKE_LOCK` and nothing else, which is
>   the contract `tests/test_release_plumbing.gd` asserts, now confirmed against
>   the shipped artifact rather than the source manifest.
> * **The plugin and both receivers are registered** — the manifest carries the
>   `org.godotengine.plugin.v2.SlacumNative` metadata pointing at
>   `com.slacumcity.nativeplugin.SlacumNative`, plus `AlarmReceiver` and
>   `BootReceiver` as declared receivers.
> * **It actually loads at runtime on the Fold** — `logcat` on launch:
>   `GodotPluginRegistry: Initializing Godot plugin SlacumNative` followed by
>   `Completed initialization for Godot plugin SlacumNative`.
>
> **What is still NOT measured, so these rows do not move to SHIPPED here.**
> `dumpsys notification` was not re-read: channels are created lazily by the
> notification platform, so the check has to follow a run that actually reaches
> that code, and the device left the network before it could be taken. The
> honest grade after this session is **PARTIAL with the build blocker removed** —
> the five rows are no longer waiting on an artifact, they are waiting on one
> read of `dumpsys notification` and a permission-request flow driven once by
> hand. That is a ten-minute pass, not a wave.
>
> **RE-MEASURED 2026-08-21 (Wave 14). The three bullets above stand; the note in
> the plugin manifest that contradicted the first one does not.** That note said
> the four `<uses-permission>` elements never reach an APK and that
> `export_presets.cfg` is the only source. Four locally built debug APKs say
> otherwise (`aapt2 dump permissions`, report 98 §29 RR-70):
>
> | plugin AAR declares the four | preset declares the four | APK requests |
> |---|---|---|
> | yes | yes | **4** ← shipped |
> | yes | no | **4** |
> | no | yes | **4** |
> | no | no | **0**, plugin and both receivers still merged |
>
> **Either source suffices, and the failing build had neither.** The bottom row
> is the Fold `dumpsys package` reading reproduced exactly — no requested
> permissions, `componentsDeclared=6`, plugin loading — so the APK on the phone
> was built against an AAR that predated the plugin manifest's permission block.
> That is the **stale-AAR root cause the session immediately before it had just
> diagnosed**, showing up one symptom later and attributed to the wrong file. It
> is why the AAR is tracked now, and it is the second time a stale AAR has cost
> this project a session.
>
> **`export_presets.cfg` carries the four as well from Wave 14, as a second
> source rather than as the fix**: with it, a stale AAR degrades from *silently
> drops a runtime permission* to *nothing at all*.
> `tests/test_release_plumbing.gd::test_every_preset_requests_exactly_the_four_permissions`
> is the headless gate for that half — the file asserted what the plugin manifest
> AUTHORS and had no assertion about what a preset REQUESTS, so the second source
> could go missing in silence.
>
> **What none of this establishes:** the rows below still do not move. Nothing
> measured here shows a system dialog appearing, a `permission_result` arriving
> or a channel being created. It shows that the permission those things need is
> requested by every artefact this repository can build. The remaining work is
> still one device session — one `dumpsys notification` read and one prompt
> driven by hand.

> **Stale, and deliberately not re-graded here (2026-08-19).** Every row below is
> as measured at `6d8c2b1`, and an Android wave has landed since: `game/notifications/`
> (scheduler, router, budget, text, native sink), `game/notifications/permission_flow.gd`,
> `game/crash_sentinel.gd`, `POST_NOTIFICATIONS` in `tools/make_release.sh` and
> `tests/test_release_plumbing.gd`, and doc 13's own §11 recording the build,
> signing and permission verification it ran. Re-grading §2.4–§2.7, §2.11 and
> §2.12 needs the same read-the-code-then-find-the-test pass §0 specifies, on
> five rows, plus a device — **so it is filed rather than guessed at**, and the
> count table above still carries the old grades. Nothing in this table should be
> quoted as current until that pass happens.
>
> **STILL FLAGGED after the Fold-6 attempt (2026-08-20).** A session was opened
> to take exactly this pass. `adb` was polled every 20 seconds for 45 minutes —
> 135 attempts, `adb mdns services` re-run on each, **zero endpoints advertised
> and zero devices authorised** — so all five rows keep their stale grades and
> this note keeps its warning. What the attempt *did* establish without a phone
> is that two of the instruments the re-grade needs do not work:
> `PerfGovernor.perf_line()` is called by nothing, so doc 11 §7.4's
> `grep '^PERF'` collects an empty CSV, and `tools/bench_device.sh` launches with
> the wrong `am` extra (`--es` for a string-ARRAY parameter, and without the
> literal `--` that `OS.get_cmdline_user_args()` requires) and with three
> scenario flags — `--bench=`, `--preset=`, `--city=` — that `game/main.gd` does
> not parse at all. Both faults are recorded in doc 11 §2.13's Fold pass;
> `game/render/perf_telemetry.gd` is the first fix, and
> **`tools/device_runbook.md`** is the session rewritten against the flag
> vocabulary the shipped shell actually has, so the next window is spent
> measuring rather than debugging the harness. Row **2.8** in particular now has
> a live consumer to check — the governor's thermal ladder shipped in Wave 6 —
> and row **2.9** gains a number it did not have: the resume path's ANR
> arithmetic budgets the catch-up and does not budget the LOAD in front of it,
> which `tools/profile_save.gd` measures at **49 ms on the founding city and
> 456 ms on the 1,500-building benchmark, on a workstation** (doc 11 §2.13).
> The re-grade is unblocked the moment a device answers.
>
> **A device answered on 2026-08-20, and four of the five rows are now graded on
> evidence rather than on code-reading.** Galaxy Z Fold 6, Android 16, the
> installed debug build (`versionCode` 400, `minSdk` 29, **`targetSdk` 36**,
> `arm64-v8a`, `DEBUGGABLE`). The instruments were `dumpsys package`,
> `dumpsys notification` and the game's own `PERF` line; the session is written
> up in doc 11 §2.13 ("Fold 6 measured") and the raw captures are in
> `tools/device_results/`. Two device facts do most of the work:
>
> * **`dumpsys package com.slacumcity.game` lists no requested permissions at
>   all** — the `runtime permissions:` block is empty and there is no declared
>   permission section. `POST_NOTIFICATIONS` *is* declared, in
>   `android/plugins/slacum_native/src/main/AndroidManifest.xml`, and
>   `tools/make_release.sh` adds it — **but neither reaches the debug APK the
>   team actually tests on.** That is a sharper finding than "ABSENT": the
>   permission surface exists in the release path and is missing from the build
>   under test, so the permission flow cannot execute on the device anyone is
>   holding.
> * **`dumpsys notification` shows `AppSettings: com.slacumcity.game (10755)`
>   with zero notification channels registered**, after a dozen launches. No
>   channel has ever been created on this device.
>
> One row moves in the other direction. **2.8 is upgraded**, because the thermal
> ladder was observed *consuming* a real signal: the `PERF` line reported
> `thermal=0` and then `thermal=1` (NONE → LIGHT) pushed through
> `AndroidNative.thermal_status_changed`, and the governor was seen stepping its
> ladder (`knob` 0 → 4) in the foreground. `SlacumNative` is therefore alive and
> feeding the governor on device, which is exactly what "nothing consumes the
> thermal ladder" said was missing. The frames were **not** thermally limited —
> `thermal_zone0` sat at 45.7–49.6 °C and drifted *down* — so the ladder was
> responding to frame time, not to heat, and the heat half of the row is still
> unproven. **2.9 stays PARTIAL and gains a device number it did not want:**
> the boot LOAD still cannot be timed on device, because `game/main.gd` set
> `save_service.log_io` ~211 lines *after* the load it was meant to time. Fixed
> in this branch; it needs a build. **2.12 keeps its grade** but `targetSdk` 36
> is now confirmed on the installed artefact.

> **2026-08-21: the premise under rows 2.4–2.7 is now false, and the permission
> gap has a different cause than the one recorded.** The blocker those four rows
> name is "a debug APK that does not carry the plugin". **The installed debug
> APK carries the plugin and the plugin registers**, which the device says
> plainly and which is readable even with the phone locked:
>
> ```
> I GodotPluginRegistry: Initializing Godot plugin SlacumNative
> I GodotPluginRegistry: Completed initialization for Godot plugin SlacumNative
> ```
>
> That is decisive about the manifest, not just about the binary: the
> `org.godotengine.plugin.v2.SlacumNative` meta-data the registry scans for
> exists **only** in `android/plugins/slacum_native/src/main/AndroidManifest.xml`,
> so if the registry found it, that manifest merged. `dumpsys package` agrees on
> the components — `componentsDeclared=6`, covering the activity, the alias and
> the two receivers.
>
> **And yet the same dump lists no requested permissions at all** — zero of
> `POST_NOTIFICATIONS`, `RECEIVE_BOOT_COMPLETED`, `VIBRATE`, `WAKE_LOCK`, with an
> empty `runtime permissions:` block and no declared-permission section. So the
> merge took the plugin's `<application>` children and **did not take its
> `<uses-permission>` elements.** The likely cause is in our own configuration
> rather than in the merger: Godot's Android exporter builds the manifest's
> permission list from the preset, and `export_presets.cfg` has
> `permissions/custom_permissions=PackedStringArray()` with **zero**
> `permissions/*=true` flags on all three presets. **That makes doc 13 §2.6's
> stated rationale — "the plugin declares its own permissions and receivers so
> that manifest merging keeps it self-contained and `export_presets.cfg` needs no
> `custom_permissions` entry" — wrong for permissions and right for receivers.**
>
> > **SUPERSEDED 2026-08-21 (Wave 14, report 98 RR-70) — the paragraph above is
> > the historical record of the Fold session and its DIAGNOSIS was half right.**
> > The premise "the preset declares nothing" was true when it was written and is
> > **false at the Wave-14 merge**: `export_presets.cfg` now carries
> > `permissions/post_notifications=true`, `receive_boot_completed=true`,
> > `vibrate=true` and `wake_lock=true` on all three presets (`:67–70`,
> > `:138–141`, `:209–212`). `custom_permissions` is still — correctly — an empty
> > `PackedStringArray()`, because all four are 4.7.2's own named flags and a
> > custom entry would duplicate them. **And the root cause was not the preset at
> > all**: RR-70 built four APKs from the four combinations and found that
> > *either* source is sufficient and only a build with *neither* declares zero —
> > the failing build had neither, because the tracked AAR was stale. The AAR is
> > tracked and rebuilt now, and the preset is a second, diffable source beside
> > it. **The permission gap is closed as a configuration question; what remains
> > is an install and a human tapping ALLOW** (§20.4 device item 1).
> The fix is one preset field, not a code change, and it is the difference
> between the permission flow being untested and being unrunnable.
>
> **Not yet confirmed**, and it should be before the preset is edited: whether
> the release path (`tools/make_release.sh`, which adds `POST_NOTIFICATIONS`
> itself) produces an APK that *does* carry the four. That is an `aapt2 badging`
> read on a built artefact, needs no device, and settles whether this is a
> debug-only gap or the shipping manifest as well.
>
> **The zero-notification-channels reading was NOT re-confirmed this session and
> must not be quoted from it.** Channels are created when the game runs, and on
> 2026-08-21 the game never ran — a secure lockscreen stopped it 21 ms after
> resume (doc 11 §2.13). Zero channels today is the expected consequence of that,
> not evidence about the code.

| § | Subject | Grade | Pointer / gap |
|---|---|---|---|
| 2.0 | Toolchain | SHIPPED | `android/build/` gradle project, `tools/setup_android.sh` |
| 2.1 | Catch-up on resume, not background sim | SHIPPED | the architecture is right |
| 2.2 | Lifecycle state machine | SHIPPED | `AndroidLifecycle`; `test_android_native.gd` |
| 2.3 | Measuring elapsed real time | SHIPPED | wall/monotonic cross-check + `elapsedRealtime` ceiling |
| 2.4 | **Notification scheduling** | ~~**ABSENT**~~ **PARTIAL 2026-08-20** | ~~no scheduler, no `AlarmManager` bridge, no code path~~ — **all three now exist.** `game/notifications/notification_scheduler.gd` produces the schedule-at-save-time plan, `NativeNotificationSink` hands it across, and `NotificationCenter.kt:233` / `:307` set it with `AlarmManager.setAndAllowWhileIdle(RTC_WAKEUP, …)`; `BootReceiver.kt` re-arms the registry after a restart, which is §2.4's own requirement. **Unproven on device**: the last `dumpsys notification` still shows zero channels, against a debug APK that does not carry the plugin. |
| 2.5 | **Notification platform** | ~~**ABSENT**~~ **PARTIAL 2026-08-20** | ~~no channels, no ids, no delivery~~ — `NotificationCenter.kt` creates channels (existence-checked before create), owns the id base (`data/notifications.json.delivery.id_base`) and delivers through `AlarmReceiver.kt`. `tests/test_release_plumbing.gd::test_the_plugin_registers_itself_and_its_two_receivers` holds the manifest wiring. **Unproven on device**, same single blocker. |
| 2.6 | `SlacumNative` plugin | PARTIAL → **PARTIAL, and its notification surface now exists** | `elapsedRealtime`, `boot_id`, thermal status and sustained performance are **live on device** — `PERF` reported `thermal` 0 → 1 from `AndroidNative.thermal_status_changed`. ~~The doc's notification and permission surface is still not in it~~ — it is, as of this fork: `NotificationCenter.kt` plus the four declared permissions. What has not happened is a device run of that surface. |
| 2.7 | Permissions | ~~**ABSENT in the build under test**~~ **PARTIAL 2026-08-20; cause re-identified 2026-08-21** | The *flow* ships — `game/notifications/permission_flow.gd` is the `POST_NOTIFICATIONS` state machine, wired at `main.gd:114–116` and connected to `AndroidNative.permission_result`. The *declaration* ships in `android/plugins/slacum_native/src/main/AndroidManifest.xml:27` and `tools/make_release.sh:65`. The measured fact is unchanged — `dumpsys package` lists **no** requested permissions — but **the reason given for it was wrong.** It is not that the APK lacks the plugin: the plugin is present and registers, and its receivers merged (`componentsDeclared=6`). The plugin's `<uses-permission>` elements specifically did not survive, and `export_presets.cfg` carries `custom_permissions=PackedStringArray()` with zero `permissions/*=true` on every preset — i.e. **the exporter's permission list is the authority and doc 13 §2.6's "the plugin declares its own permissions so the preset needs no entry" does not hold.** One preset field, then a rebuild, then this row is testable. |
| 2.8 | Battery, frame pacing, thermal | PARTIAL *(evidence upgraded, grade held)* | ~~nothing consumes the thermal ladder~~ is **retired**: the governor was observed stepping on device (`knob` 0 → 4 in the foreground, `preset=balanced`, doc 11 §2.13), and `SlacumNative` fed it a real `thermal` 0 → 1. Still PARTIAL, and deliberately: the Fold never left `thermal=1` / 45.7–49.6 °C and was **cooling**, so **no thermal step-down was ever exercised**, and battery (D-07) was not measured at all |
| 2.9 | Long catch-up without an ANR | PARTIAL | measured at 1.04 s for 43 coarse hours (soak §14.2). ~~The resume path is **D-1**, so the measurement is of the planner, not of the shipped call~~ — **D-1 closed 2026-08-19**, and the shell now makes the same `CatchUpPlanner.plan()` call the measurement was taken against. Still PARTIAL because the number is a workstation number: no on-device ANR run has happened (doc 13 §7 D-15). |
| 2.10 | Export pipeline | SHIPPED | `export_presets.cfg`, gradle v0.3.x |
| 2.11 | Crash reporting | ~~**ABSENT**~~ **PARTIAL 2026-08-20** | ~~nothing~~ — `game/crash_sentinel.gd` ships the breadcrumb: boot writes `user://runtime/session_open.flag`, pause deletes it, and a flag still present at the next boot means the last session did not get that far. No SDK, no `INTERNET` permission, no Data Safety declaration, because nothing is sent. **Deliberately PARTIAL, and the doc says so**: §2.11 ranks a network reporter post-alpha, and the hook point is documented (`breadcrumb_path`) rather than built. What is genuinely missing is the *player's* end of it — the Settings → "Report a problem" share intent the class doc describes has no row in `data/ui.json.settings.rows`. |
| 2.12 | Play Store readiness | ~~**ABSENT**~~ **PARTIAL 2026-08-20** | ~~`export_presets.cfg` has no keystore, no signing config~~ — the **signing pipeline ships**, just not inside the preset, and Godot 4.2+ is the reason: the preset has no keystore fields at all, so `tools/make_release.sh` drives them through `GODOT_ANDROID_KEYSTORE_RELEASE_{PATH,USER,PASSWORD}`, creates the upload keystore with `--init-keystore`, keeps it outside the repo, and **verifies both artefacts are actually signed** (`apksigner` for the APK's v2/v3 block, `jarsigner` for the bundle) because a Godot export reports success either way. All three presets carry `package/signed=true`, `versionCode 400`, `versionName 0.4.0`, arm64-only, and `tests/test_release_plumbing.gd` holds every one of those as an assertion — including that no secret can live in a committed file. **Still ABSENT, and this is now the whole of the row: no store listing assets, no privacy policy, no data-safety form.** A `find` for `*privacy*`, `*store*listing*` and `*data_safety*` returns nothing. |

---

## 14. What the harnesses found

### 14.1 The tutorial flow test — the good news first

The eleven-step tutorial completes, on the real shell, unassisted:

```
flow_test — doc 12 §2.17 over game/main.tscn        (1.0x, 67.7 s wall)
  welcome            0.02 s    look_around        0.00 s    open_build   0.03 s
  place_house        0.02 s    unserved_wall      0.07 s    place_transformer 0.04 s
  blackout           5.94 s    open_drawer        0.02 s    dispatch     0.02 s
  relight           60.92 s    payoff             0.01 s
  steps advanced: 11/11   checks: 13   taps landed: 3/3   failed: 0
```

`blackout` is the step's authored 6 s `on_enter` delay; `relight` is the crew
driving and working. Everything a player does costs under a tenth of a second of
shell time.

Three of three ground taps landed on the intended tile through
`TouchInput.tapped` → `CameraState.screen_to_ground` → the ghost — the screen
projection and the inverse agree. The transformer is repaired, the block
relights, `ui.onboarding.finished` is set.

### 14.2 The QA soak — two real hours

Seed 20250819, city seed 1337, speeds 1/2/3, 2,880 chunks, 286.9 game-hours
(≈12 game-days) including two save/load cycles and an app pause/resume.

| Measurement | Result | Reading |
|---|---|---|
| Script errors | 0 | clean stderr for the whole run |
| ObjectDB, raw slope | +1.65 objects / game-hour | two step jumps, not a drip |
| ObjectDB, **steady slope** | **−0.04 objects / game-hour** | **no in-run leak** |
| Objects retained per save/load | **199, both times** | a replaced `CitySim` is never reclaimed — **D-9** |
| Step cost | mean 1,619 µs/tick, p95 1,748, max 2,025 | ~6.5 ms of sim per real second at 1× |
| Step-cost drift | first decile 1,591 → last decile 1,638 = **1.03×** | flat across 287 game-hours |
| Event bus | 408,979 events, **0 residual after every drain** | clean |
| Bus composition | `vehicle_state` ×326,745 = **80 %** of all traffic | **D-10** |
| Save/load identity | 2/2 hash-identical, 2/2 advance-identical | the constitution §5 guarantee holds mid-session |
| Resume | 45 min away → 10,800 ticks (43 coarse hours) in **1.04 s** | no ANR risk |
| Treasury | $25,334 → $678, min −$14,601 | inside envelope; austerity engaged |
| Happiness / stability | min 66.9 / 0.947 | inside envelope |
| Incidents | **2 created in 287 game-hours** | **D-6** |
| City level | 0 → 0; 376 upgrades refused `E_CITY_LEVEL` | **D-7** |

The first two-hour run also found a defect in *the harness*: an unguarded random
demolisher razed all 34 buildings by the halfway mark, so the second half
measured an empty map. The harness now protects stations and holds a floor of 24
buildings, and raises tax when overdrawn — the minimum judgement a person has.
Recorded because it is the reason the numbers above are trustworthy and the
first run's were not.

### 14.3 The UI audit, re-run

`tools/ui_preview.gd --screen=all --audit --strict` was re-run at four device
boxes as part of this audit rather than trusted from the Wave-4 report:

| Box | Result |
|---|---|
| 360×800 | clean |
| 412×915 | **2 states with `overlapping_targets`**, exit 1 |
| 880×400 | **3 states with `overlapping_targets`**, exit 1 |
| 1280×720 (the project's own viewport) | **3 states**, 24 clean, exit 1 |

Every finding is the same control. See **D-12**.

### 14.4 Screenshots judged

Four shots off `game/main.tscn` and `tools/onboarding_preview.tscn`, at the
default 1280×720 viewport.

* **First boot, welcome card.** The city reads at 06:01 — the darkest minute of
  the founding day. Streetlights are the only light; one apartment block is
  legible and the rest of the frame is near-black, under copy that says "This is
  your city. It runs whether you watch it or not." The textures and the lighting
  are not at fault (the same frame at 13:01 is excellent — brick, window frames,
  shingle, strong shadows); the *clock* is. Doc 09 §2.9 sets the founding time,
  and the tutorial's opening shot is the one frame in the game most worth
  spending daylight on. Not filed as a defect because it is a design call, but
  it is the first impression the game currently makes.
* **Daylight city, 13:01.** Flagship-bar material: the brick and shingle read at
  this zoom, the shadow contact is clean, streetlight poles cast properly.
* **Coach step 9 (`dispatch`), blackout in progress.** The dark block, the lit
  streetlights and the construction fence around the failed transformer read
  exactly as doc 11 §2.7 wants. The bubble is legible over the dark scene.
  One observation: the step's target is the drawer's `Panel`, so if the player
  closes the drawer the cutout resolves to nothing and the coach mark loses its
  highlight with no `autohelp` to recover it — a second face of **D-2**.
* **All three shots** show the clipped event-log chip at the right edge that
  §14.3 measures.

### 14.5 Defect list

Filed, not fixed — these live in files this branch does not own.

**Renumbering, 2026-08-19:** two waves filed a `D-14`/`D-15` pair each and the ids
collided. The **performance** pair (draw calls, sim step cost) keeps **D-14/D-15**;
the **generator** pair (`water_main_break` and `traffic_accident` having no
candidate source, both fixed in Wave 7) becomes **D-17/D-18**, in that order. Every
cross-reference in `docs/` and in code comments was moved with them. Doc 12's own
`D-14…D-18` delta table and doc 13 §7's `D-01…D-16` device matrix are separate
id spaces and are untouched.

**THE THREE ID SPACES ARE FIXED, 2026-08-20 — this document's open question 2,
answered.** The renumbering above was the second collision in two waves and it
happened because three documents number defects `D-nn` in three unrelated
sequences: this one (`D-1…D-18`), doc 12's delta table (`D-14…D-21`) and doc 13
§7's device matrix (`D-01…D-17`). A `D-15` in a commit message is therefore
ambiguous three ways, and one of them is a *performance* defect and another is a
*device* one. **The fix, adopted here and from here on: every new row filed in
this document is prefixed `A91-D-nn`, and the number CONTINUES this document's
own sequence rather than restarting.** So the Wave-10 rows are **A91-D-19
onwards**, D-18 being the last unprefixed one. Restarting at 01 was considered
and rejected: `A91-D-01` sitting beside `D-1` in a commit message is the same
ambiguity in a new coat, and a sequence that never reuses a number inside its own
document costs nothing. The existing `D-1…D-18` rows keep their ids — renaming
them would break every cross-reference in `docs/` and in code comments a third
time, which is exactly the cost this rule exists to stop paying. Doc 12 and doc 13 should
adopt `A12-D-nn` and `A13-D-nn` when they next file, but that is their call and
this document does not make it for them. The rule for a reader: **an unprefixed
`D-nn` is pre-2026-08-20 and belongs to whichever document you found it in; a
prefixed one names its document.**

**AND THE PREFIX WAS NOT ENOUGH — the third and fourth collisions were *inside*
this document's own sequence. 2026-08-21, the Wave-14 merge.** The `A91-` prefix
fixed collisions *between* documents and did nothing about collisions *between
branches*: four siblings forking from one commit each take "the next free
number", and the next free number is the same number for all of them. It
happened twice — **two `A91-D-31`s** (both Wave 13) and **two `A91-D-33`s** (both
Wave 15) — and once more in doc 93's own letter space (**two `G4`s**).

**The rule, adopted here and from here on, stated so the next collision costs a
lookup rather than a debate:**

> **A colliding id stays with the row that CODE already points at** — a file
> under `sim/`, `ui/`, `game/`, `tests/`, `tools/` or `data/`. **The row whose
> references are docs-only takes the next free number** in this document's
> sequence — never a restart, never a reuse. **If neither side has a code
> reference, the id stays with the block whose HEADER claims a contiguous
> range**, and the interloper moves.

A code comment is the reference hardest to keep true and the one a grep-driven
reader trusts most, which is the whole of the reason. Applied: `A91-D-31` keeps
the sliced catch-up and the incident cascade becomes **`A91-D-35`** (the
sequence's one unissued number, so the ledger gains no hole); `A91-D-33` keeps
the opportunity layer and the dispatch ledger becomes **`A91-D-38`**. Both moves
are annotated at their blocks below, both keep their original id in parentheses,
and every reference in the tree was rewritten with them — checked by a validator,
not by eye. Doc 93 §W2 is the ruling; report 98 **RR-94** is binding.

**And the Wave-15 merge produced the fifth, one commit after the rule was
written** — the reward-ledger branch, blind to this repair, filed its
two-price-tables defect as `A91-D-38` at its own fork. By the rule above, verbatim:
neither claimant has a code reference, the id stays with the block whose header
claims the contiguous range (the renumbering table this section publishes), and
the interloper moves — the price-tables row becomes **`A91-D-40`**, annotated at
its block, original id in parentheses. The sequence stands: D-38 dispatch ledger,
D-39 lifetime counter, D-40 price tables.

*The durable fix is smaller than the rule: **a filer on a branch cannot know
which number is free**, so the merge is where an id becomes final. Until the
sequence is issued by something other than a human reading upward — a `make
next-defect-id`, or simply filing as `A91-D-NEXT` and letting the merge stamp
it — this will happen again every time three or more siblings file.*

#### New rows, Wave 10 (2026-08-20) — `A91-D-19` … `A91-D-29`

| # | Severity | Defect |
|---|---|---|
| **A91-D-19** | ~~**High**~~ **FIXED 2026-08-20 (Wave 11)** | **Closed, and closed as the whole section rather than as the cheap half.** `data/difficulty.json` ships with all four sections × four presets; `sim/economy/difficulty.gd` (`class_name Difficulty`) is the one loader and validates every rule of §3.4 — a missing row, a nested table, a knob present on three presets out of four, a non-monotone multiplier, an undeclared direction and a fifth section are each refused by a test in `tests/test_difficulty.gd`. `CitySim.boot()` resolves and pins the preset **before** the treasury is constructed (the founding balance is one of its twelve knobs), and `CitySim.found_with_difficulty()` is the founding seam the title door drives. The scattering is gone in both directions: `data/director.json`'s `_difficulty_fallback` mirror and `data/incidents.json`'s `difficulty_escalation` block are **deleted**, `data/economy.json` lost `OFF_TAU_HOURS`, and `DirectorTables` / `IncidentCatalog` now REFUSE a file that grows one back. The preset is part of the city (doc 08 §2.8 city section **v6**, migrator defaulting an unnamed body to `standard`) and reaches the player at NEW CITY as a cycling chip on the front door, read-only in S9 — `save.assisted` and the mid-city change are **ruled out** in doc 93 §K1 rather than shipped. **The coverage consequence this row named is answered by doc 92 §29**: the default preset is byte-identical on both cities, both paths and all 63 cells of the seven-strategy matrix, and the other three presets are measured for the first time — including one finding (`E_roads_repair` takes `M_repair × M_exp`, so `crisis` founds at −$18.70/gh) which is derived, ranked and deliberately not fixed. Gate 29 pins the ordering. Original filing: ~~`data/difficulty.json` is **not in the tree** — it is the only broken file pointer in this whole document, and `data/economy.json:166` announces that the knobs "MOVED" to it. `sim/economy/difficulty.gd`, the loader §2.9 names, does not exist either. What is actually shipping: `Treasury.DIFFICULTY_STANDARD` (`sim/economy/treasury.gd:32`), a twelve-key dictionary compiled into the class, and `CitySim` calling `Treasury.new(econ_curves.economy_data())` (`sim/city_sim.gd:197`) with **no difficulty argument**, so `_difficulty` is the standard row on every boot forever. §2.9's `casual` / `hard` / `crisis` columns — twelve knobs × three presets, all authored, all in the doc — are **unreachable by any code path**. The other two sections were never centralised: `data/director.json:65-68` still holds `pressure` behind `DisasterDirector.tables.difficulty_fallback()`, `data/incidents.json:389-392` still holds `escalation` behind `IncidentWorld.difficulty_escalation_mult()`, and each has its own reader — three files, three loaders, against §2.9's "one file, one schema, one loader". There is no `cmd_set_difficulty`, no settings row, and `save.assisted` (§2.9's leaderboard flag) appears **nowhere in the tree**. Consequence beyond the missing feature: **every number doc 92 has ever measured was measured on one of four intended difficulties**, and the balance gates are written against it, so this is also a statement about how much of the balance surface is covered. Cheapest honest fix is not the whole section — it is to write `data/difficulty.json` with the four rows §2.9 already tabulates, add the loader, pass it at `city_sim.gd:197`, and leave the *selection UI* for a later wave; that alone makes three quarters of the authored table reachable by a test.~~ *(The lead ruled the whole section rather than the cheap half, and the selection UI shipped with it.)* |
| **A91-D-20** | Low | **A vehicle body ships that no department can ever ask for.** `VehicleMesh.ambulance()` (`game/render/vehicle_mesh.gd:316`) is a complete 4th emergency body; `VehicleView.DEPT_MESH` maps `"medical" → "ambulance"` and `DEPT_PAINT` gives it `#F2F4F6`. **`data/vehicles.json` has no `medical` department** — its five types are police / fire / utility / water / construction — and grep finds `"medical"` in exactly two files, both under `game/render/`, plus `game/showcase.gd`. Doc 06 §6 **defers EMS**, so this is an asset built ahead of a deferred feature rather than a bug; it is filed because the asset matrix (§16) has to join the roster exactly, and `tests/test_asset_completeness.gd::DEFERRED_BODIES` is the constant that has to be deleted on the day a `medical` type is authored. Cost of leaving it: one unreferenced ArrayMesh factory and one atlas cell. |
| **A91-D-21** | ~~High~~ **FIXED 2026-08-20 (doc 12 D-46; the box this row could not close is A91-D-22/D-23, both closed in Wave 12)** | **Closed, and the whole sweep is now green.** D-46 turned the bottom-right corner into a solved rail (`UIWidgets.solve_corner_rail`), which took the 73-per-box chip overlaps to zero at all five boxes; Wave 12's D-51 and D-52 took the two remaining causes at 880 × 400 to zero as well. Re-measured `tools/ui_preview.gd --screen=all --audit` over **52 states × 5 boxes × 2 accessibility settings = 520 state-sweeps**: **0 findings, everywhere.** A2 at 130 % and A3 are green at every box the project tests; A2's *own* box — 150 % at 640 × 340 — is still A91-D-29 and still untested. Original filing: **The accessibility sweep fails at every device box the moment A2 and A3 are on.** Doc 12 §2.18 says *"every row is a release gate"*, and `text_scale` (A2) and `larger_touch_targets` (A3) are two of them. `tools/ui_preview.gd --screen=all --audit --strict --text-scale=1.3 --large-targets` exits **1 at all five boxes** — 360×800, 412×915, 794×924, 880×400 and 1280×720 — against **exit 0 and 49 clean states at every one of them at 100 %**. The dominant cause is one and it is the same at every box: **36 of 49 states report `overlapping_targets` in the right-edge chip column**, where `PanelLayer/AlertsCenter/Chip`, `PanelLayer/EventLog/Chip` and `PanelLayer/IncidentDrawer/Handle` are stacked vertically and **do not re-flow when `larger_touch_targets` inflates them** — at 360×800 the alerts chip grows to 89 × 100 px and covers 3,872 px² of the event-log chip beneath it and 3,800 px² of the drawer handle beside it. D-12's fix (stand a chip down while a sibling PANEL is open) does not help here, because no panel is open: all three chips are legitimately visible at once and simply no longer fit the column they are laid out in. |
| **A91-D-22** | ~~High~~ **FIXED 2026-08-20 (doc 12 D-47 for the sheets, D-52 for the two centred cards)** | **Closed at all five boxes.** The 360 dp half was D-47: a settings row and a save slot's action group became `HFlowContainer`s, so the sheet stopped being wider than the phone and its own ✕ came back on screen. The 880 × 400 half is this wave's and is a different shape — S0's panel and the pause menu are **centred cards in a `CenterContainer`, which lays a child out at exactly its minimum**, so a 449 dp card on a 400 dp box hangs off both ends. `UIWidgets.wrap_in_scroller()` + `UIWidgets.card_height()` give both the goals-sheet pattern: the body scrolls, the card is capped at `H − 16`. Re-measured: **0 `[offscreen]` findings at every box on both settings**, against 9 at filing. Original filing: **At 130 % + large targets, controls go OFF SCREEN, including two a player cannot recover from.** Nine `[offscreen]` findings across the a11y sweep, and the two that matter most are **`ModalLayer/SettingsSheet/Panel/Body/Header/Close "✕"` at 360×800** (rect x 294→380 against a 360-wide viewport) and **`ModalLayer/SaveLoadSheet/…/Close "✕"`** at the same box: **a player who turns on large touch targets on a 360 dp phone cannot close the settings sheet or the save list with the button.** Android Back still dismisses them (`UIRoot._notification(NOTIFICATION_WM_GO_BACK_REQUEST)`), which is the only reason this is not a hard lock. Also offscreen: `SettingsSheet/…/Saves "MANAGE SAVES"` at 360×800, and at 880×400 `PauseMenu/…/Action_quit "SAVE & QUIT"`, `TitleScreen/…/Action_settings "SETTINGS"` (two states), `TitleScreen/…/Confirm_start "START NEW"` and `Confirm_cancel "CANCEL"`, and an alert row's `VIEW`. **A new player on A3, on a folded Fold, cannot press START NEW.** |
| **A91-D-23** | ~~Medium~~ **FIXED 2026-08-20 (Wave 12, doc 12 D-51)** | **Closed, and the fix has two halves because the arithmetic has two.** `HudModel.solve_top_bar` now takes a **height budget and a row height** and reserves one row of height per wrapped row, so the bar never wraps into space it does not have (`rows_within`, pure, headless-tested; an unbounded budget reproduces the old solver byte-for-byte, which is what keeps every model test in `tests/test_ui_topbar.gd` true). That alone does not close it: at 880 × 400 / 130 % / larger targets **one** row is already 100 dp against a rail whose top slot starts at y 89, and `100 + 8 + 12 + 3 × 93 + 2 × 8 = 407 dp against 392 of safe area` — the column cannot hold both. So `HudModel.top_bar_left_inset()` steps the whole bar right of the rail column (113 dp at that box) whenever its first row would reach the rail, and §2.4's demote-then-hide ladder absorbs the width. It returns **0 at every supported box at 100 %**, so the reference layout does not move. Re-measured: `tools/ui_preview.gd --screen=all --audit` at 880 × 400 / `--text-scale=1.3 --large-targets` is **0 findings across all 52 states**, against 156 top-bar overlaps before. Original filing: **The HUD top bar does not re-flow at the landscape box under large targets.** At 880×400 with `--text-scale=1.3 --large-targets`, **all 49 states are dirty** (220 findings, against 73 at the other four boxes): `HUDLayer/LeftRail/SpeedButton` overlaps `HUDLayer/TopBar/Chips/Row` in **98** findings and `HUDLayer/OverlayRail/Button` in **49** — i.e. every state, both rails, every time. 880×400 is doc 12 §2.3's own reference box and the Fold's folded/landscape shape, so this is not an exotic geometry. Separate from A91-D-21 because it is a different layout and a different fix: the chip column is a stacking problem, this is the top bar not yielding height to the rails. |
| **A91-D-24** | ~~Low~~ **FIXED 2026-08-20 (Wave 12, doc 12 D-48/D-49)** | **Closed. It got the door doc 12 §2.6 had specified since the first draft** — *"assigned units render as 24 dp chips replacing the ASSIGN button (tap → `Recall`)"* — with two deviations that are recorded there: the chips are **48 dp** (A3 outranks a dimension) and they sit **beside** ASSIGN rather than replacing it (a `Button` inside a `Button` cannot be hit, and sending a second unit is a verb doc 06 supports). `IncidentDrawer.recall_requested` → `UIRoot.bind_recall()` → `CitySim.cmd_recall_unit`, and `game/main.gd` binds it in one line. The verb also stopped lying while it was being wired: `DispatchSystem.cmd_recall_unit` had answered `ok` for a unit `FleetSystem.recall()` does nothing to, and now refuses `IDLE` / `RETURNING` / `REFIT` / `OFFLINE` with `E_UNIT_NOT_DEPLOYED` carrying the status — `tests/test_incidents_dispatch.gd::test_manual_lock` asserts the second recall of the same unit is refused. Original filing: **`CitySim.cmd_recall_unit` has zero callers anywhere in the repository.** Not a UI door, not `tools/playtest.gd`, not `tools/qa_soak.gd`, not a `GoalSystem` kind — and not a test, because `tests/test_incidents_dispatch.gd:205` exercises recall by calling `system.dispatch.cmd_recall_unit(unit_id)` on the `DispatchSystem` directly and never touches the `CitySim` wrapper (`sim/city_sim.gd:2720-2721`). Doc 06 §2.11 lists recall as a player verb. The consequence is small and exact: a player who dispatches a unit to the wrong incident **cannot take it back**, and the two-line wrapper that would let them is already written. §17 has the matrix. |
| **A91-D-25** | Low | **Doc 05 §2.14 quotes a channel value the store does not hold.** §2.14 states `water_demand_commercial = 0.45 at h22` as a reproducible input; `data/time.json`'s authored keyframes `[21, 0.65]` and `[23, 0.35]` interpolate to **0.50**, and report 98 C-33 makes `data/time.json` the store. `tests/test_water_data.gd:51-55` already records the disagreement in a comment and asserts the store's 0.50; the §2.14 worked examples still pass because they are driven from injected channels rather than from the store. **It is a doc quote, not a code bug** — but it has stood since the R-09/R-10 rescale, and a worked example whose stated input is not the shipped input is a worked example that cannot be used to debug the shipped system. Fix is one number in doc 05, or two keyframes in `data/time.json` if 0.45 was the intent. |
| **A91-D-26** | ~~Medium~~ **✅ CLOSED 2026-08-20** | **Forty-three sim event types reached no consumer at all, and one of them was a whole shipped feature.** §18's event matrix crossed all **121** type names `sim/` produced against `game/main.gd`'s translator, `game/audio/audio_events.gd`, `game/render/*`, `game/notifications/`, `ui/incident_model.gd`, `sim/progression/goal_system.gd`, `data/ui.json.event_log.events` and `data/notifications.json.bindings`. **Forty-three were consumed by nothing in any of them, and twenty more only by `tests/` or `tools/` — so 58 of 121 were wired.** Most are bookkeeping. **`flood_level_changed` was not.** **Resolution (report 98 RR-48, doc 93 §K1).** The matrix was RE-WALKED at HEAD by a scanner that is now `tests/test_event_matrix.gd` rather than a one-off — **138 types, 78 consumed, 60 classified, zero unexplained** — and the re-walk found three things the counted-once version could not. (a) **The list was already stale by three rows**: `grid_feeder_routed`, `grid_node_commissioned` and `grid_node_retired` acquired a `main.gd` arm in Wave 10, the day after this defect was filed, so a feeder re-route already moved pixels. `grid_node_rerated` is the fourth and is classified `player_initiated` — it fires only on an upgrade the player bought, and `PowerInfraView` re-polls topology on its own timer. (b) **The flood is drawn, announced and logged** — see §2.4's row and doc 11 §2.9b. (c) **The genuine remainder was in doc 05, not doc 07**, exactly where §18.2 said it would be: `water_capacity_shortage`, `water_tank_low`, `water_tank_empty`, the three `water_*_failed` and `water_contamination_cleared` were all latched, player-actionable states with no wired sibling, and all seven are now in the log (four of them in the push table too). `water_capacity_shortage` is the one worth reading twice: doc 05 §2.9 says out loud that no repair job exists for it, so it is the only water alert whose answer is BUILD, and it was the quietest thing in the game. Three more asymmetries fell out with them — `road_reopened` (the closure was announced and the reopen was not), `austerity_exited` (the belt tightening was announced and the loosening was not) and `road_condition_critical` (the only warning a player had that a road was about to fail was the road failing). `road_block_stamped` stays classified `covered`: it is the near-twin of `block_roads_stamped` and `road_graph_changed` rebuilds the same street. **The reverse direction is still clean** and is now a test that fails closed (doc 11 §7.3f test 48). |
| **A91-D-27** | Medium | **The notification budget's state resets on every launch.** `NotificationRouter.serialize()` / `deserialize()` (`game/notifications/notification_router.gd:634-641`) are complete, versioned (`section_version: 1`) and tested — and **called by nothing outside `tests/`**. `game/save_service.gd` registers exactly three sections (`CITY_SECTION`, `UI_SECTION`, `META_SECTION`, at `save_service.gd:213-225` and `:361-367`) and the budget is not one of them. Consequence: token ledgers, per-type cooldown keys and quiet-hours state are rebuilt from zero at boot, so doc 08's global cap can be spent twice inside its own window across a restart, and a cooldown a player has already "used up" is silently refunded. This is the narrowed remainder of doc 08 §2.13 — the *policy* half now reaches the router (`main.gd:1131`), only the *state* half does not persist. The fix is the four lines `SaveService.ui_provider` needed. |
| **A91-D-28** | Medium — **the screen is still open; the RULE it implies is now met on the way in** | **S15 shipped with both of its preview states in the same commit as the screen** (`veil_load`, `veil_catchup`, plus a `SURFACES` row in `tests/test_ui_audit.gd`), so the deck did not gain a second surface the sweep cannot see. S13 itself is unchanged and this row stands. Original filing: **S13 has no preview state, so the event log is the one screen the audit has never opened.** `tools/ui_preview.gd::SCREENS` holds 49 named states and `grep -n "event_log\|EventLog" tools/ui_preview.gd` returns **nothing** — there is no branch in `_apply()` that calls `EventLog.open()`, so `PanelLayer/EventLog/Panel` has never been laid out, measured or photographed by the sweep at any box or any accessibility setting. Its **chip** is audited constantly, because the chip is a sibling of every other state — which is exactly how D-12 was found, incidentally, a wave after S13 landed. The panel behind it is unmeasured. Doc 12 §2.2 lists fifteen screens; the sweep covers fourteen, and the claim "all fifteen" should not be made until this is one state and one branch. It is the cheapest row in this table: two lines beside the `alerts` state that sits next to it in `SCREENS`. |
| **A91-D-29** | ~~High~~ **FIXED 2026-08-20 (Wave 13; doc 12 D-54 … D-58)** | **Closed on both halves, and the box is a gate now.** The 100 % half was already cured at this wave's fork by Wave 12's D-52 (a centred card scrolls and is capped) — re-measured, 640 × 340 at 100 % is **0 findings across all 53 states**, and the CANCEL the row measured at 96 dp tall is **73 dp** at that scale. The 150 % half is **D-54**, and the row's own arithmetic is the evidence for it: `SpeedButton` clipped to `y −70 … 56` is a **126 dp** control where A3 asks for 84, because `ThemeBuilder` scaled its stylebox padding twice. One line takes that arm from **209 findings to 2**; **D-55** (the settings sheet's About block moves inside its own scroller) takes it to **0**. And the row's real demand — *"add 640 × 340 to `BOXES` in the same commit that fixes the layout"* — is met: it is a row of `tests/test_ui_audit.gd::BOXES` **and** of the `tools/ui_preview.gd` sweep list, committed with D-55 … D-57. Whole deck at six boxes × three text scales: **408 findings → 0**, with the 100 % row unchanged. Original filing: **A control is off the bottom of the screen at 640 × 340 at DEFAULT text scale — and 640 × 340 is doc 12 §2.18 A2's own reference box, tested by nothing.** `TitleLayer/TitleScreen/Center/Panel/Body/Confirm/Actions/Confirm_cancel "CANCEL"` lays out at y 318.5 with height 96 against a 340-tall viewport: **26 dp past the edge, at 100 %, with large targets off.** It is the CANCEL half of the title screen's *"start a new city and lose this one?"* confirmation — so on that box a player can commit to a destructive action and cannot back out of it with the button. (Android Back still dismisses the confirm, as with A91-D-22, which is the only reason this is not data loss.) **Why nothing caught it, and this is the sharp part:** 640 × 340 is not an invented box. `data/ui.json.layout.min_safe_box_dp` **is `[640, 340]`** — the project authors its own minimum safe box, doc 12 §2.18's A2 names it as the size the layout must survive 150 % at, and **it appears in no `BOXES` list, no sweep and no test**: `tests/test_ui_audit.gd::BOXES` covers 360×800, 412×915, 794×924, 880×400 and 1280×720, and `tools/ui_preview.gd` defaults to 880×400. The one box the data file calls the floor is the one box nothing runs, and it was measured for the first time by this audit. At 150 % + large targets the same box produces 49/49 dirty states, 228 overlaps and 72 offscreen findings, with `HUDLayer/LeftRail/SpeedButton` clipped to y −70 … 56 against a 340-tall box in every state. Add 640 × 340 to `BOXES` in the same commit that fixes the layout, or the box the requirement is written against stays the box nothing runs. |

#### New rows, Wave 12 (2026-08-20) — `A91-D-30`

| # | Severity | Defect |
|---|---|---|
| **A91-D-30** | **High** | **A save taken after the first game-day does not replay bit-identically, and the fault is in `RoadNetwork`, not in serialization.** Founding city, seed 8191, `CitySim.boot_from_files`: a save at 1, 2, 4, 6, 8, 10, 12, 16 or 20 game-hours restores and then advances **identically**; a save at **24 or 30 hours** restores identically — `state_hash()` agrees at rest, the body is byte-identical — and then **diverges within one further game-hour**. The first fields to move are `roads.traffic_feed.vehicles[*].s_m` and `.speed_mpgm` at a relative 2 × 10⁻⁶, immediately followed by `roads.edge_dynamics[*][1]` (smoothed congestion). Both restore paths — the single `restore_state()` call and `begin_restore()`'s eleven steps — land on the *same* wrong city, which places the fault upstream of both: **something derived inside `RoadNetwork` is rebuilt differently by `load_section()` than the live run had it, and it only starts to matter once a day boundary has been crossed.** Predates Wave 12 (reproduced against `28b9550` with the wave's changes stashed) and is therefore not a regression — but it is a violation of constitution §5 and of M1 criterion 8, on the founding city, at a save point a player reaches in one sitting. Leading suspect, **not confirmed**: `_last_hour_sampled` is the one day-scoped member of `RoadNetwork` that `save_section()` does not persist, and `load_section()` hard-codes the `12.0` that its `-1` default produces — but restoring it by hand across the load (and `_mean_congestion` with it) does **not** close the gap. **Why nothing caught it:** every save → load → advance proof in the suite saves inside the first game-day (`tests/test_milestone1.gd` at 2 h). The gate is real; its window is smaller than a day. Fixing it means changing what `roads` persists, i.e. a `SECTION_VERSION` bump and a ladder rung, so it was deliberately left to a wave that is allowed to move the bytes. Full evidence in report 98 §24 RR-52. — **CLOSED 2026-08-20 (Wave 13), and the row above is wrong about where it was.** It was not in `RoadNetwork`. The seed is **one ULP** in `WaterDemandCache`'s three per-zone demand sums: the live run reaches them incrementally (`set_demand` subtracts a building's old contribution and adds its new one, once per changed building per utilities tick) and a restore rebuilds them with a single forward pass in sorted-id order, so a 24-game-hour founding city and its restored twin hold `com_base` values that differ in the last bit *from the moment of the load, before anything advances*. Roads was downstream: the ULP reaches water delivery, delivery reaches building state, and the loudest thing it eventually moves is the cosmetic traffic feed, which is why the first diff pointed there. Proved by an A/B — handing the restored city the live zone sums and changing nothing else closes the gap at every save point tested (2, 26, 50, 74, 120 h). Fixed by persisting them (`water.section_version` 2 → 3); gated by `tests/test_save_determinism_days.gd`. **The row's fingerprint, though, was real and belonged to a SECOND defect**: `RoadGraph.rebuild_all()` builds every node `powered = true` and nothing wrote it back, so a city loaded with a substation down came back with its signals lit and `step()`'s first `refresh_signal_power` dirtied every edge in the city — one extra smoothed congestion pass, `traffic_feed.vehicles[*].s_m` and `.speed_mpgm` first, `edge_dynamics[*][1]` immediately after. It needs a dark signal rather than a day boundary, which is why the 24-hour repro could not see it and the mid-incident fixture could. Both closed. Full evidence in report 98 §26 RR-60 / RR-60b. |

#### New rows, Wave 13 (2026-08-20) — `A91-D-35`

*Filed as `A91-D-31`; **renumbered `A91-D-35` on 2026-08-21** at the Wave-14
merge, because two Wave-13 siblings each filed an `A91-D-31` and the sequence
had one unissued number. The rule, adopted here and from here on: **a colliding
id stays with the row that CODE already points at** — the other `A91-D-31` is
named from `sim/time/catchup_cursor.gd`, `sim/city_sim.gd` and
`tests/test_catchup_cursor.gd` — **and the row whose references are docs-only
takes the next free number.** The five references this move rewrote are doc 91
§20.2 item 4b and §20.2a item 4b, doc 06 §2.13(b)'s Wave-13 heading, doc 92 §32.7
and report 98 RR-62's title.*

| # | Severity | Defect |
|---|---|---|
| **A91-D-35** | ~~**Critical**~~ **✅ CLOSED 2026-08-20 (this wave)** | **The incident roster had no upper bound, and doc 06 §2.13 had costed the whole system against one.** `BalanceGateRig.run("do_nothing", 1337, 120, "crisis")` did not finish: from game-day **104** the open-incident count multiplied ~2.5–2.9 **per game-hour** — 103 → 357 → 832 → 2,424 → 6,389 → 14,671 → 37,631 → **89,055** — at **269 s** of wall clock for the eighth of those game-hours, against §2.13's stated worst case of ≤ 40 active. On device that is an ANR on any long-abandoned save, and gate 29 was already routing around it with a per-preset horizon and a written warning that "a gate that ran into it would hang rather than fail". **Not fire spread and not destroyed buildings** — both were already correct (doc 02 §2.12's `state_fire_mult` is 0 for `destroyed`; a burnt-down `structure_fire` goes `FAILED` and leaves the roster in the same sub-step). The mechanism is `crime`'s own cascade: `on_tier_enter[4]` spawns one child and `on_tier_enter[5]` spawns two, both `scope: "district"`, which needs no entity and therefore consumes nothing — mean offspring **three**, a supercritical branching process. RR-26's terminal rule fired on schedule on every one of them; it bounds an incident's LIFETIME and nothing bounded its FERTILITY. **Closed by doc 06 §2.13(b)** (report 98 RR-62, doc 93 §M1): one roster ceiling that every automatic birth answers to, a generation taper from a knee placed at the worst backlog the doc 92 matrix has ever measured, and a rule that a district-scoped cascade must pass the type's own generator eligibility. Measured after: peak **37** open over 200 game-days on `crisis`, worst game-hour **0.47 s**, whole run **89 s**; the 7×3×21 matrix is byte-identical and both determinism baselines hold. Gate 30 asserts the bound. |

#### New rows, Wave 13 (2026-08-20) — `A91-D-31`

| # | Severity | Defect |
|---|---|---|
| **A91-D-31** | ~~Medium~~ **✅ CLOSED 2026-08-21 (Wave 14)** | **The offline catch-up is not sliced, so doc 13 §2.9's veil has nothing to animate over.** `game/main.gd::_on_app_resumed` walks `CatchUpPlanner.plan()`'s segments in a synchronous `for` loop — `advance_coarse_hours(count)` and `advance_fine_n(count)` back to back — so a 12-real-hour absence runs **720 coarse steps inside one frame**. Doc 13 §2.9 specifies the other shape and has since it was drafted: `while not sim.advance_coarse_sliced(12): veil.set_progress(...); await get_tree().process_frame`, with a 12 ms budget whose stated purpose is "keeping the 30 fps veil animation smooth". **This is not an ANR risk** — §2.9's own argument is that whole coarse steps are atomic and the margin to the 5 s line is 90× — it is a *presentation* defect, and it is only visible now because Wave 13 built the veil the loop was supposed to feed. Today `UIRoot.present_veil_catchup()` puts a truthful sentence and a truthful bar on screen and the loop never yields, so the player sees one frame of it at most. The restore in front of it *is* sliced (`RestoreCursor`, eleven steps) and is where the veil currently earns its keep. Two things are needed: `CitySim.advance_coarse_sliced(budget_ms)` (or the same loop written in the shell over the planner's segments, one segment per frame), and `advance_veil_catchup()` called from inside it. Filed rather than fixed here because `game/main.gd` is the lead's and because a sliced catch-up changes when `_on_sim_batch` sees the offline events — an integration decision, not a UI one. — **CLOSED 2026-08-21 (Wave 14), and the row's own prescription is half right.** `CitySim.begin_catchup(plan) -> CatchUpCursor` ships in `sim/time/catchup_cursor.gd`; the shell integration is an exact snippet against `main.gd`'s existing `_restore_cursor` guard, so the lead still owns the integration decision this row reserved for them. **What did not survive contact with the shipped planner:** `advance_coarse_sliced(budget_ms)` cannot advance a real resume — a returning player's plan carries a fine head-align segment and a 40-tick fine tail (D-1), which a coarse-only entry point has nothing to do with — and the BUDGET cannot live in `sim/` at all, because constitution §5 forbids reading a clock there. So the unit is one coarse hour or one fine tick and the shell spends them against `Time.get_ticks_usec()`, which is `RestoreCursor`'s own contract and doc 13 §2.9's own sentence ("the shell decides the budget"). The 12 ms budget is unchanged in meaning and buys **one** step per frame on every city in the project at the measured 6.3–190 ms per coarse step, which is §2.9's own worst-case row rather than its retired 0.60 ms estimate. Determinism is the part that could have gone wrong and is proved instead: a coarse step reads `ctx.catchup_index` / `ctx.catchup_total`, which index the SEGMENT and not the slice, so the cursor issues `advance_coarse_n(1, true, hours_done_in_segment, segment_hours)` and `catchup_begin()` still fires once per segment. `tests/test_catchup_cursor.gd` proves bit-identity against a verbatim copy of the old shell loop on both cities at 1, 3, 12 and unbounded units per frame, on `state_hash()` **and** on the drained event bus. **And the row was right that the integration is where the decisions are.** Two of them, both in the snippet: `SimHost` must be **paused** for the duration — it is a separate node with its own `_process`, and unpaused it adds `delta × 60` to `clock.residual_game_ms` and spends live fine ticks *between* the slices, which is a different city and not merely untidy — and a player can now background the app *while the veil is up*, so a second resume drains the unfinished cursor on the spot rather than dropping the new absence. Report 98 §28 RR-72. |

#### New rows, Wave 15 (2026-08-21) — `A91-D-33`

| # | Severity | Defect |
|---|---|---|
| **A91-D-33** | ~~**High**~~ **✅ CLOSED 2026-08-21 (this wave), sim half** | **Nothing in the game rewarded LOOKING at the city.** Eleven systems ship; every one of them is something the player SETS UP and then watches settle. A fire answers itself, a tax rate pays on the hour, a block develops over game-days — and all of it pays the same whether or not anybody is watching. The Wave-13 playtest named the consequence exactly: *“there's not a lot of downtime of absolutely nothing to do”* is what the player asked us to fix, and *“we need to have ways where we can make money quickly”* is the shape they asked for. This is a **completeness** defect and not a balance one: the arc had no beat between commitments, so a session was a busy first minute and then a wait, and no amount of retuning `data/economy.json` could put one there. **Closed (sim half) by doc 06 §2.16's opportunity layer**, report 98 RR-77, doc 93 §Q. `sim/street/opportunity_system.gd` spawns three kinds of tappable street offer on a new `street` RNG stream — `petty_crime` weighted by doc 02 §2.9's `coverage_police` (the player's own *“crimes that aren't being picked up by the police station”*), `loose_animal` weighted by residential frontage, and a rare `lost_valuables` — each standing on a kerb tile the renderer's own classification agrees with, each living two to four real minutes, each paying a bounty through doc 03 §2.5's new `street` revenue line. Measured on the founding city: **one offer every 1.763 game-hours** (= 1 min 46 s at 1x, inside the 1–3 real-minute design band), mean bounty **$320.29**, **734 candidate kerb tiles**, and a crook share of **70 % at `coverage_police = 0` against 12 % at `1.0`** — the hook working, not a bias. **What it cost:** exactly three added keys in the city body (`street`, `rng.street`, `treasury.ledger_totals.lifetime_street`), zero changed values anywhere — strip the three and all four determinism digests reproduce the Wave-13 baselines to the byte (RR-77's table) — city section rung **v7**, and `do_nothing` on the 21-game-day matrix reproduces doc 92 §33.4 cell for cell, because the spawner is a fine-path system that draws nothing offline (doc 08 §2.3 rule 9). **What is still open, and it is the OTHER HALF of this wave, not a defect:** the street-life renderer that draws the crook, the dog and the glint, and the tap that reaches `cmd_collect_opportunity` — §17's verb matrix records the verb as doorless-by-design at this fork and doc 93 §Q3's `awaiting_consumer` classification carries the two events until the marker lands. **What is deferred with a reason:** an unanswered crook expires silently (doc 06 §2.16 names `expire_stability_delta` and why v1 does not ship it), no curriculum row uses the `collect_opportunities` evaluator kind (gate 21's fitted targets are untouched; doc 92 §35.4 item 2 names level 4 as where a row would fit), and doc 92 §35.3 ranks the one number the balance agent has to rule on — a **57 % of founding net** collection ceiling that this document's opinion puts nearer 35–40 %. |

#### New rows, Wave 14 (2026-08-21) — `A91-D-36` (STREET LIFE branch)

| # | Severity | Defect |
|---|---|---|
| **A91-D-36** | ~~**Low**~~ **✅ CLOSED 2026-08-21 (Wave 15, street polish)** | **Every authored livery in the renderer is lifted, because a MultiMesh instance colour is LINEAR and nothing on that path converts it.** A shader uniform hinted `source_color` is converted from sRGB for free, and so is `StandardMaterial3D.albedo_color`; **`MultiMesh.set_instance_color` is neither.** So an authored `#F25242` arrives in the shader as linear `(0.95, 0.32, 0.26)` and displays at roughly sRGB `(250, 165, 150)` — the same hue, washed out by about the gamma curve. `VehicleView` (`vehicle_view.gd:580`, `v.paint`) and `ConstructionVehicleView` (`_write`, `pose.tint`) both do this with palettes authored as hex in `data/render.json` and `data/vehicles.json`; the street-life layer did too until this wave, where it was found by a screenshot of a marker that was supposed to be a strong red and came out the colour of a plaster. **Filed rather than fixed**, for one honest reason: on a SHADED surface the lift is much less visible than on an unshaded billboard, the result reads as a deliberately chalky palette rather than as a bug, and re-saturating a shipped fleet and a shipped plant hire is an art call on two layers a street-life branch does not own. Closing it is `Color.srgb_to_linear()` at each palette's read point plus one screenshot pass to re-judge the values — a couple of hours, not a design. Report 98 §31 RR-81; the pattern that made it visible is in `StreetLifeModel.coat_linear`, which converts once at `configure()` and says why. **CLOSED.** `Color.srgb_to_linear()` now sits at both seams — `VehicleView._paint_for` (once per vehicle) and `ConstructionActivity._plant_paint` plus `_stock_linear` (once per site, once at `_init`) — rather than per instance per frame, because the conversion allocates a `Color` and both call sites write one colour per instance per frame. **And the palettes were re-judged with it, which is the half the filing said was the real work.** Screenshots: `profile_frame --traffic=14 --units=4 --sites=2` at Z1, hour 13 and hour 21, bench city, with no UI layer in the frame (the harness gained `--traffic` / `--units` for exactly this — it had always BUILT `VehicleView` and never fed it, so every picture it had ever taken was of an empty street). Four hexes moved because they had been fitted by eye against the lift and, corrected, landed on the value of the asphalt they were driving over: `CIV_PAINT` `#4A5157`→`#5B646C` and `#2C3237`→`#3B434B`; `LIVERY` `#2F6E52`→`#3E8C69` and `#3D6B92`→`#4C82AE`. The other eight civilian paints, both remaining liveries and all six department colours survive the correction unchanged. `StreetLifeView` never had the defect — its model bakes every coat and marker tint at `configure` — which is the audit answer this row asked for. Report 98 §36 RR-91; doc 93 §V4; `tests/test_vehicle_view.gd` and `tests/test_construction_living.gd` pin the seam. **One half deliberately left open and filed with a named consumer:** the same latent lift is on every VERTEX colour in every procedural mesh here, and several of those constants are used both as vertex colours and as instance tints (`ConstructionRigMesh.GRAVEL` is the dump truck's load and the yard's gravel heap), so converting the constant would move the mesh half at the same time and the mesh half has never been judged against a picture. **awaiting_consumer:** the next render pass, over `construction_rig_mesh.gd`, `vehicle_mesh.gd` and `street_life_mesh.gd`, with a screenshot per mesh family. |

#### New rows, Wave 14 (2026-08-21) — `A91-D-32`

| # | Severity | Defect |
|---|---|---|
| **A91-D-32** | ~~**High**~~ **✅ CLOSED 2026-08-21 (this wave)** | **Doc 10's two injected siblings were assigned by nothing, so rain had never slowed traffic and every district read one land-use row.** `RoadNetwork.profile_weights_of` (doc 09 §5.1) and `RoadNetwork.weather_state_of` (doc 07 §5.1) are `Callable` fields declared at the top of `sim/roads/road_network.gd`; **`CitySim` assigned neither, on any path, for the life of the project.** Consequences, both silent: `_profile_weights` answered with `data/roads.json`'s `default_profile_weights` for **every district of every city**, so doc 10 §2.10's four authored 24-entry `tod_curves` were four copies of one curve; and `_weather_state()` answered with the field initialiser `"clear"` **for the life of the process**, so `wx_cong_add`, `wx_slowdown` and `wx_wear_day` were 0.00 always and eleven authored rows of `data/roads.json`'s `weather` table were unreachable by any code path. **This is A91-D-19's shape exactly** — authored data behind a plausible default — and it survived thirteen waves of audit for the same reason: nothing crashes, nothing greps, no test fails, and the profiler shows the code running. The tell was in the tree: `_default_profile_weights_note` said *"Delete the fallback once doc 09 ships the real per-district building mix"*. **Closed by report 98 RR-69 / doc 93 §O.** Doc 09's `DistrictRegistry.profile_weights(id)` now publishes the normalised `Σ(population+jobs)` mix per doc 10 profile (§2.6.1); `CitySim._district_profile_weights` wires it, memoised on `(roster_revision, membership_revision)` rather than given a cadence; `CitySim._road_weather_state` wires `weather.get_state().to_lower()`. Both are injected **before** `bootstrap()`, which also closes RR-61's live-vs-restored `district_id` divergence — filed there as inert *"only because `profile_weights_of` is injected by nothing"*. Measured: the founding city's four districts now want **0.0498 / 0.1347 / 0.1117 / 0.0567** of `D_tod` at 02:30 against one shared 0.0565; heavy rain moves mean `c_e` **0.1250 → 0.3150** at the 18:00 peak and recolours **644 of 644** edges on doc 12's traffic overlay (bench city: **2,794 → 2,973** of 3,092 edges in `gridlock`); a cross-city civilian trip goes **19.32 → 24.96 gm**. One ledger line moved — `E_roads_repair` **158.42 → 183.92 $/gh** — and doc 92 §33 carries the hour-by-hour derivation and the gate re-fit. Four determinism baselines re-recorded. |

#### New rows, Wave 15 (2026-08-21) — `A91-D-38` *(filed as `A91-D-33`)*, `A91-D-34`

*The dispatch-ledger row below was filed as `A91-D-33` and is **renumbered
`A91-D-38` on 2026-08-21** at the Wave-14 merge, under the same rule as
`A91-D-35` above: the other `A91-D-33` — the opportunity layer — is named from
`tests/test_save_migration.gd:345`, and this one was named only from doc 91
§20.4. `A91-D-38` is the next free number; `A91-D-34` … `A91-D-37` are
untouched.*

| # | Severity | Defect |
|---|---|---|
| **A91-D-38** | ~~**High**~~ **✅ CLOSED 2026-08-21 (this wave)** | **Automatic dispatch has been paying the player since Wave 1, into a ledger with no line for it — and doc 03 was carrying a placeholder for the same dollar.** `IncidentSystem._pay_reward` credited `reward_base × tier × speed` on every resolve through `world.credit(…)` → `Treasury.credit(…, &"incident")`, which is a terminal call: `EconomySystem.settle_hour` never saw it, so the budget panel had no row, `data/notifications.json` had no event and the only way to notice the money was to watch the balance change for no printed reason. Doc 03's own half — `POLICE_FINE_PER_RESOLVED_INCIDENT = 350`, numerically identical to `reward_base[crime]` — was metered by `CitySim.HELD_FINE_RATE = 3/350` and printed a flat **$3.00/gh** on every preset at every horizon. **This is A91-D-19's shape again, inverted**: not authored data behind a plausible default, but a live value behind a plausible *placeholder*, and it survived four waves because neither half looked wrong from its own side. Doc 06 filed it as its own §9 open question 6 **in Wave 1** and requested a ruling; doc 93 §N1 point 4 wrote the re-open condition in Wave 11. **Measured before closing** (`tools/measure_founding_ledger.gd --hours=24`, seed 1337, `do_nothing`): **$38.38/gh — $921 across the founding game-day, 12.5 % of that day's whole reported net income**, paid to a city that builds nothing and dispatches nothing. Closed by report 98 RR-77 / doc 93 §P1: `reward_base` moves to `data/economy.json` under C-07's monopoly, the held pair and the `fines` line are retired, and a live `city_services` revenue line replaces them — credited at the resolve, reported at the settlement, and netted out of what the settlement banks so the same dollar is not booked twice. `tests/test_city_services.gd` is the gate; four determinism baselines re-recorded (doc 92 §36.6). |
| **A91-D-34** | ~~**High**~~ **✅ CLOSED 2026-08-21 (this wave)** | **Doc 06's reward curve paid more than the damage it prevented, so letting a fire grow before answering it was the profitable play.** Doc 06 §2.7 grows the payout at `tier_k = 0.35` per tier; doc 02 §2.8's residual-damage curve grows at `0.10` per tier. The two cross on any cheap building around tier 4. Worked on a **house L1** (capital $1,200): a tier-5 fire answered at the target response paid `900 × 2.40 = $2,160` against a prevented loss of `1,200 − 408 = $792` — **2.73×**, or **4.09×** at the best speed bonus. Doc 06's own ruled worked example (tier-3, house L2) sits at a healthy 0.679, which is exactly why nobody looked one tier up: the reference point was fine and the curve was not. **Nothing in the game exploits it today** — no scripted agent works the incident drawer and the player had no reason to — but the money pass was about to make dispatch a visible income stream, which is what turns a latent inversion into a strategy. Closed by report 98 RR-77 item 6: doc 03 clamps every payout at `MORAL_HAZARD_CAP_FRACTION (0.75) × (capital_value(target) − repair_cost(target, residual))`, placed above doc 06's ruled reference (0.679) and strictly under indifference (1.00); where doc 03 prices no capital — road edges, water segments — the clamp is **skipped rather than zeroed** (`prevented_loss_value` returns −1, not 0) and `MORAL_HAZARD_UNPRICED_CEILING = $3,900` holds those three types instead. **Balance gate 31** asserts all three surfaces: the clamp has teeth on a controlled incident, every priced resolve of a 21-game-day city is inside the ceiling, and the published table holds the rest. |

#### New rows, Wave 14 (2026-08-21) — `A91-D-37`

| # | Severity | Defect |
|---|---|---|
| **A91-D-37** | ~~**High**~~ **◐ HALF-CLOSED 2026-08-21 (this wave)** | **Every bounty the city has ever earned was invisible on the one screen that exists to account for money, and the Economy tab's NET was wrong by exactly that much every hour a crew answered a call.** `IncidentSystem._pay_reward` computes a real number — `reward_base × (1 + 0.35·(tier_peak − 1)) × speed_bonus`, so a tier-3 crime answered on target pays **$595** against a `reward_base` of 350, and a tier-3 structure fire pays **$1,530** — and hands it to `CityIncidentWorld.credit`, which is `Treasury.credit(amount, &"incident", reason)`: a **direct credit**. `EconomySystem.settle_hour` never sees it. Its `revenue` block is `{tax, tax_by_class, power_tariff, water_tariff, fines, gross}` and `net = gross − expenses.total`, so on a city with a police fleet out, the line that pays best is missing from the ledger *and* from the total the ledger draws underneath it. **`Treasury` cannot even be asked**: `_note_lifetime` buckets `tax`, `tariff` and `repair` and has no arm for `&"incident"`, so the money exists in `balance` and nowhere else. **Why nothing caught it:** every ledger test asserts that the rows the snapshot carries render correctly, which they do; there is no test anywhere that the rows *are* the city's income, and the one number that would have shown it — a hand-audit of `balance` against `Σ net` — is not something a suite has ever run. It is A91-D-19's shape a third time (after A91-D-32): a plausible, correct-looking path with a whole channel of value outside it. **The player found it from the outside**, on 2026-08-21, in the only terms a player has: *"our automatic dispatch in crime — that should pay us money."* It already did. It has always paid, silently, which is indistinguishable from not paying. **Half-closed here, and the halves are on purpose.** The UI half ships (doc 12 §2.21, D-62/D-64): the coin, the treasury chip's deposit pulse and the `Crime stopped — +$120 bounty` toast make the payment audible, visible and legible the moment it lands, and `data/ui.json.budget.revenue_keys` gained `bounties` and `street` with `BudgetModel.feed_side_revenue()` supplying them from a per-game-hour tally taken off the bus, so the two lines and the NET are right on the screen today. **The sim half is open and belongs to doc 03**: `revenue.bounties` (and `revenue.street`) should be settle-snapshot keys, tallied where the credit is made rather than downstream of a UI that happens to be watching. The UI's tally is written to retire itself — a key the snapshot carries is taken from the snapshot, always, so the day doc 03 publishes one the sim's number wins with no edit in `ui/` and no chance of counting a dollar twice. Until then the ledger is right and its provenance is a layer lower than it should be. |

#### New rows, Wave 15 (2026-08-21) — `A91-D-38`, `A91-D-39` (balance fork)

| # | Severity | Defect |
|---|---|---|
| **A91-D-40** *(filed as `A91-D-38`)* | ~~**High**~~ **✅ CLOSED 2026-08-21 (this wave)** | **The opportunity layer shipped with TWO price tables, and every balance gate read the dead one.** RR-78 moved doc 06's `reward_base` under C-07 and wrote, in the same note, that `data/street.json` *"still carries the LIVE reward columns this table is due to absorb"*. It did — `{base: 260, spread: 90}` / `{150, 60}` / `{420, 180}`, which is what `OpportunitySystem._reward_for` actually paid — while `data/economy.json`'s `city_services.street_payout` carried a placeholder flat table, `petty_crime 180 / stray_animal 120 / abandoned_haul 150`, that nothing read. **Two of those three keys are not live kind ids at all** (`stray_animal` and `abandoned_haul` name nothing in `data/street.json`, which authors `loose_animal` and `lost_valuables`), so the table could not have been read by the spawner even if the spawner had tried. **What it cost is not the dollars — it is that the gate was gating a number the game does not use.** Gate 32 asserted `petty / dispatch_crime ≤ 0.60` off the dead column (`180/350 = 0.514`) where the live one is `305/350 = 0.871`; and it asserted an income-share bound of `0.45 × 180 = $81/gh` where the live worst case is `0.45 × 600 = $270/gh`. Doc 03 §2.5's own published `STREET_MAX_RATE_PER_GAME_HOUR = 0.45` was, separately, **violated by the shipped spawn table by 48 %** from the day it was written (`1/1.5 = 0.667 offers/gh`), and no test anywhere could see that either, because the two files lived in different branches. **This is A91-D-19's shape a fourth time and A91-D-33's a second**: a live value behind a plausible placeholder, surviving because neither half looked wrong from its own side and every test passed. Closed by report 98 RR-85 / doc 93 §U1: the bands move to `data/economy.json` **at the same values**, `reward_city_level_k` moves with them as `STREET_REWARD_CITY_LEVEL_K`, and `OpportunitySystem.FORBIDDEN_KEYS` refuses both back at any depth as a **boot error** — the same guard `IncidentCatalog` puts on `reward_base`. All four `profile_sim` baselines are **bit-identical** across the migration, which is the evidence separating "moved" from "retuned". **The discriminating test is the one that checks ABSENCE** (`tests/test_city_services.gd::test_no_street_price_survives_in_doc_06s_data`): a test asserting doc 03's numbers are present and well-shaped passes identically whether the column is live or dead. |
| **A91-D-39** | ~~**Medium**~~ **✅ CLOSED 2026-08-21 (this wave)** | **`ledger_totals.lifetime_street` read ZERO on every city since the layer shipped, and the save has been carrying that zero forward.** `Treasury.credit_city_service(amount, source)` credits through `credit(amount, &"city_services", …)` and `_note_lifetime` keys on the **category** — it has a `&"street"` arm and nothing ever reached it. Doc 03 §2.5 calls this row *"its own revenue line and its own lifetime counter"*; doc 08 §2.8 cut **city section rung v7** partly for it; A91-D-33's own closing note lists it as one of the three keys the layer added. It counted nothing. **The cash was never wrong** — `credit()` moved the balance, the hourly receipt book tallied, doc 03's `city_services` revenue line printed — which is exactly why it survived: every symptom a wrong ledger normally has was absent. **Why the tests did not catch it:** `tests/test_street_opportunities.gd` asserted the key was PRESENT in the serialised body, and asserted a byte-identity property with the key **erased**; both pass whether the counter counts or not. **A counter that is always zero is worse than a missing one** — a missing one answers *"I don't know"*, a zero one answers *"none"*, and the second is a false claim in a structure the save carries forever. Closed by report 98 RR-88 / doc 93 §U4: the tally is noted by SOURCE alongside the category credit, and the new assertion compares the counter to the bounty rather than to `has()`. `dispatch` is deliberately still uncounted — `_note_lifetime` has no `&"incident"` arm, and **A91-D-37's open sim half is the row that would build one**; inventing a key in `Treasury` would publish a counter doc 03 has not. |

| # | Severity | Defect |
|---|---|---|
| **D-1** | ~~High~~ **FIXED 2026-08-19 (Wave 7)** | **Closed:** `main.gd._on_app_resumed` now calls `CatchUpPlanner.plan(elapsed_ms, residual_game_ms, tick_index)` and walks its segments (`advance_coarse_hours` for `coarse`, `scheduler.advance_fine_n` otherwise), then writes back `new_residual_game_ms` — so every segment lands hour-aligned, and the 12-hour cap, the two-minute grace and the residual carry all apply on device. `tests/test_qa_soak.gd::test_planned_resume_advances_a_live_city_from_any_tick` drives the same call from offsets 0, 1, 137 and 239. Original filing: ~~`game/main.gd:875` resumes with `sim.advance_coarse_hours(int(elapsed/60))`. `TickScheduler.advance_coarse_n` asserts an hour-aligned `tick_index`; a resume from any of the other 239 tick offsets **trips the assertion in a debug build** and, in a release build where `assert` is stripped, fires hourly cadences off-boundary — the exact thing doc 01 §2.4 exists to prevent. It also skips the two-minute grace, the 12-hour cap and the residual carry. `CatchUpPlanner.plan()` already does all four and is called by nothing.~~ |
| **D-2** | ~~High~~ **FIXED 2026-08-20 (verified at `a892315`)** | **Closed, with the exact fix this row proposed and no code at all.** `data/ui.json.onboarding.steps[8].advance` is now `{"kind": "any_of", "conditions": [{"kind": "command", "command": "dispatch_unit"}, {"kind": "sim_event", "event": "incident_resolved"}]}` — so a player slower than the auto-dispatcher's 62 game-minutes is carried past step 9 by the resolution itself instead of finding every `cmd_dispatch_unit` refused `E_UNKNOWN_INCIDENT` with no way out but *Skip tutorial*. `tests/test_tutorial_flow.gd::test_scripted_incident_leaves_a_usable_dispatch_window` is the test that measured it and still guards it. Original filing: The auto-dispatcher takes the scripted transformer job **within the first game-minute** and resolves it at **+62 game-minutes** — 62 real seconds at 1×. A player who takes longer than that to open the drawer and tap ASSIGN finds the incident terminal, every `cmd_dispatch_unit` refused `E_UNKNOWN_INCIDENT`, and the step has no `autohelp` and no `any_of` fallback. The flow then only ends via *Skip tutorial*. Measured by `tests/test_tutorial_flow.gd::test_scripted_incident_leaves_a_usable_dispatch_window`. Cheapest fix: an `any_of` on step 9 that also accepts `sim_event incident_resolved`. |
| **D-3** | ~~High~~ **FIXED 2026-08-19 (Wave 7)** | **Closed, and it cost the two lines this row predicted.** `SaveService` grew a `ui_provider: Callable` and a `last_loaded_ui: Dictionary`; `main.gd:683` assigns `save_service.ui_provider = root.capture_ui_state`, and `main.gd:685` / `main.gd:1013` apply `last_loaded_ui` once the UI exists (a boot restore happens before there is a UI to restore into, which is why the value is held rather than pushed). The `ui` section rides the envelope beside `city` and survives the format-1 migration: `tests/test_save_service.gd::test_ui_section_rides_the_envelope`, `tests/test_save_migration.gd::test_the_ui_section_survives_the_format_change`. Original filing: ~~`UIRoot.capture_ui_state()` / `restore_ui_state()` are complete and tested and **called by nothing outside `tests/`**. `SaveService` persists only `sim.canonical_capture()`. Consequence: the tutorial's finished flag, the settings and the overlay choice **do not survive an app restart** — a returning player is shown the tutorial again, contradicting doc 12 §2.17's "never shows again once done".~~ |
| **D-4** | ~~High~~ **CLOSED (verbs Wave 5, the last three surfaces Wave 11)** | Every doc-05 verb a player needs now has a door. `cmd_place_water_component` reached the infrastructure tab in Wave 5; `cmd_place_water_main` became two drag-path cards in Wave 10; and Wave 11 put `cmd_upgrade_water_component` on the building panel of the shell that hosts the node (one row per node, `WTR-1` hosts three) and `cmd_isolate_water_main` / `cmd_restore_water_main` on the incident drawer's expanded row, as one control in two moods on the one row whose `target_ref` is a water segment. **The water-NODE panel this row and doc 05 §6.1 kept asking for was not built** — doc 93 §J1 rules that the three verbs are two verbs at two moments and that a screen hosting both would be a screen the player has to go and find mid-incident. Original filing: ~~Doc 05's ten `WaterSystem.cmd_*` are not re-exported by `CitySim`, so no build card can exist. The water simulation is fully built and entirely unplayable.~~ |
| **D-5** | ~~High~~ **Closed (Wave 5A + 6; the road SURFACE landed Wave 10)** | Two more verb surfaces with no player: **roads** (verbs Wave 5A, the ROADS tab and the drag-path tool Wave 10 — until then the verbs existed and nothing could call one, which is what doc 92 §17.6 recorded) and **land** (closed Wave 6 — S4 ships as `ui/land_panel.gd`, entered by `BuildController.pick_at_ground`; `cmd_buy_block` is called with `auto_develop = false` so doc 12 §2.8's PURCHASE → DEVELOP is two taps, as written). The `game/main.gd` `_handle_tap → pick_at_ground` routing landed in the Wave-6 integration. |
| **D-6** | ~~Medium~~ **CLOSED** (Wave 6) | Incident pressure at starter-city scale is ~1 per 6 game-days (2 in 287 game-hours). Consistent with doc 02's ignition rates, but it means the drawer, the picker, the fleet and doc 06's whole escalation ladder are almost never seen. Either the rates want a floor at small city sizes, or the Director wants a "something must happen" pacing rule. — **Answered by the first of those: `data/incidents.json` `ambient_floor`, a per-channel `max()`, no `generator_base_rates` row moved. 1.88 → 3.04 ambient incidents/game-week, measured over 336 game-days on each side of the boolean. Doc 92 §18; gate 19.** The true rate was 1.88/week, not the 0.5/week this row reads — 287 game-hours is a 12-game-day sample of a 0.27/day process, so part of the number above is Poisson noise. The finding survives the correction; the measurement did not. |
| **D-7** | ~~Medium~~ **CLOSED** (Wave 6) | The soak's city never left **city level 0** in 12 game-days, so every one of 376 upgrade attempts was refused `E_CITY_LEVEL`. Doc 09 §2.11's thresholds are not reachable by a player who is not optimising, which locks out doc 02 §2.10–2.11 entirely. — **Worse than this row knew: `balanced` ended FIFTY game-days at level 2, and four of the six rungs were unreachable by anything the game can do. Ladder retuned onto doc 92's measured curves and moved into `data/progression.json`: level 1 on game-day 2, level 2 on 11, level 3 on 23. Doc 92 §19; gate 20.** |
| **D-8** | ~~Medium~~ **FIXED 2026-08-19** | ~~No benchmark city fixture~~ `tools/gen_bench_city.py` ships and emits `tests/fixtures/bench_city.json` (1,500 buildings, 6×6 developed core, 3,132 road tiles), byte-identically on a re-run. Consumed by `tools/profile_sim.gd --city=…`, the new `tools/profile_frame.gd`, and `tests/test_bench_city.gd` (doc 11 tests 19 and 26, doc 09 test 40). **The matrix is now measured and it does not pass**: at Z2 the Balanced draw-call budget of 320 is exceeded (352 with UI) because a real mixed block carries ~16 `archetype:level` buckets, not §2.13's assumed ~6 — filed as **D-14**. The sim side is worse: 22.0 ms per fine tick and 259 ms per coarse step on this city — filed as **D-15**. Numbers in doc 11 §2.13's as-shipped table. |
| **D-9** | Medium | Every `CitySim` ever constructed is retained forever — **199 objects per reload measured in-run, 208 per boot measured in isolation** (boot six, release five, the count never falls). Cause: `CitySim._register_systems()` registers twelve phase adapters that each hold a strong `sim: CitySim`, and `sim` holds the scheduler — a reference cycle, and `sim/` is RefCounted-only with no cycle collector. Harmless in the shipped shell (one sim, loads restore in place) and the reason every tool and test run leaks. It becomes a real leak the moment a "New game" or "load into a fresh sim" path appears. Fix: a `CitySim.dispose()` that clears the scheduler's registry, or `WeakRef` in the adapters. |
| **D-10** | ~~Low~~ **FIXED 2026-08-19** | ~~`vehicle_state` is 80 % of all bus traffic~~ The per-vehicle event is gone. `sim/roads/traffic_feed.gd` publishes one packed `traffic_snapshot` per tick (five `Packed*Array` columns, format in `sim/roads/traffic_snapshot.gd`); `vehicle_spawned`/`vehicle_despawned` stay individual. Re-measured on the soak: **55,675 → 18,221 events, 3.05×**, with the same 44,153 poses carried in 6,699 events instead of 44,153 dictionaries. Cadence unchanged at 4 Hz (doc 11 §2.12's Hermite blend depends on it). Save identity proved unchanged by `profile_sim --hash-only --baseline` on both cities. |
| **D-11** | ~~Low~~ **Closed (Wave 6)** | `DispatchPolicy` now has seven S9 rows (`policy: "dispatch"` in `data/ui.json.settings.rows`), defaulting from doc 06's own `data/dispatch.json.policy_defaults` and writing through `cmd_set_dispatch_policy`. The **city's** policy seeds the rows on bind and beats a restored `ui.settings` copy, because the policy lives in the city's save and not the UI's. |
| **D-12** | ~~High~~ **FIXED 2026-08-20 (verified at `a892315`)** | **Closed, and re-measured at five boxes rather than four.** `ui/event_log.gd:73-76` now carries the same `_process` stand-down `ui/alerts_center.gd:221` had — `_chip.visible = not UIWidgets.any_sibling_open(self)` — which is the five-line fix this row named. Re-running `tools/ui_preview.gd --screen=all --audit --strict` at 360×800, 412×915, 794×924, 880×400 and 1280×720 gives **49 states clean and exit 0 at every box**. (The a11y sweep of the same five boxes does *not* pass, for three unrelated reasons — **A91-D-21/22/23** — and that is a different defect, not this one reopening.) Original filing: Re-running `tools/ui_preview.gd --screen=all --audit --strict` finds `overlapping_targets` on `PanelLayer/EventLog/Chip` at **412×915** (2 states), **880×400** (3 states) and **1280×720** (3 states) — the alerts list, the incident drawer's rows and the building panel's `Fix this →` all put a tap target over it. Exit code 1 at every box. Root cause is exact and the fix is already written elsewhere: `ui/alerts_center.gd:221` polls `_chip.visible = not UIWidgets.any_sibling_open(self)` in `_process` — the comment above it says it was added for *this* defect — and `ui/event_log.gd` has no `_process` and never stands its chip down. S13 landed in the same wave as the sweep and did not inherit the fix. |
| **D-14** | ~~High~~ **FIXED 2026-08-19 (MEDIUM half); NEAR half open, Low** | ~~Doc 11 §2.13's per-chunk draw-call model is optimistic by ~1.7× on a mixed city, and the Balanced budget is exceeded at Z2.~~ Was: **352 draw calls with UI against a 320 budget**, from **591 MultiMesh bucket nodes across 36 chunks — 16.4 per chunk**, where §2.13 assumes 8 NEAR / 6 MEDIUM, because `CityView` allocated one bucket per `(chunk, archetype, level)` and a real block holds five archetypes at four levels. **Now: Z2 measures 194 calls, 219 with UI, against 320 — 31.6% headroom.** MEDIUM draws one MultiMesh per `(chunk, ARCHETYPE)` over an `ArrayMesh` of the levels that chunk holds, each vertex tagged with its level in the free `COLOR.a` channel and each instance carrying its level in the packed `.b` at stride 448 — `448 = 16·28` with `28 ≡ 0 (mod 7)`, so §2.6's `variant` and `stage` decoders do not move and only `overlay_of`'s `clamp` became a `mod` (an exact identity on 0..447). The 16 MEDIUM chunks now cost **5.94 building calls each against §2.13's assumed 6**: the model was never wrong, the renderer was, and nothing in the derivation had to be retuned. Doc 11 §2.6 (bucketing rule + the A/B that keeps MEDIUM on LOD0), §2.13 (as-shipped table), §7.2 test 19c (20 tests, `tests/test_render_merge.gd`). Verified pixel-wise against the un-merged renderer: **Z0 and Z1 bit-identical** (0 of 921,600 pixels), Z2 differing on 0.63% of pixels by at most 18/255 — the deliberate `near_flicker = 0` and nothing else — and the blackout and POWER-overlay ceremonies read identically. The starter city is unchanged in every column, because it has nothing to merge. **Residual, filed as D-16:** NEAR still allocates per level and still measures 16.4/chunk against the assumed 8. |
| **D-16** | Low | **The NEAR half of D-14 — a derivation that fails against a measurement that passes.** `CityView` still allocates one MultiMesh per `(chunk, archetype, level)` for NEAR chunks: **16.4 per chunk measured, against §2.13's assumed 8**. Re-run §2.13's Z1 worst case (6 NEAR chunks, the Balanced `near_chunk_max`) with the measured number and it lands at **366 against 320** — `6 × 16.4 × 2 splits = 197` of that is the shadow pass alone, because §2.13 costs every NEAR bucket once per split. But the bench city at Z1 **measures 136 with UI**, because the frustum at `D = 86.9` never actually holds six full dense chunks. Filed Low for exactly that reason, and unlike D-14 (where derivation and measurement failed together) there is nothing here to fix today. The fix is a switch, not a design: the LOD0 level atlas that closes MEDIUM is pixel-exact and already shipping, so extending it to NEAR is `medium_merge_enabled`'s twin plus a `near_flicker = 1` material. Take it the first time a **device** measurement puts a close-zoom pose near the budget, or the first time a pose is found that really does hold six dense NEAR chunks. Doc 11 §2.13, "What is still open". |
| **D-15** | ~~High~~ **COARSE PATH FIXED (Wave 7) · SUB-STEP GUARD TAKEN (Wave 8) · CADENCE PASS TAKEN (Wave 9) · NARROWED (Medium): the fine tick is at 18.0 ms against an 8 ms target and the router put the bench-city COARSE path back over doc 01's 2 s catch-up budget** | ~~The sim step does not scale to the benchmark city.~~ Originally: **22.00 ms per fine tick** and **259.18 ms per coarse step** on `tests/fixtures/bench_city.json`, with the 12 h catch-up at 3.11 s against doc 01's 2 s budget. **The Wave-7 scaling pass closed the coarse half** — interleaved A/B, same session, same workstation, baseline stashed and restored between runs: coarse step **238.6 → 132.8 ms (−44 %)**, **12 h catch-up 2.86 → 1.59 s, inside the 2 s budget**, fine tick 21.80 → 17.49 ms (−20 %). Starter city, same pass: coarse 8.10 → 6.28 ms, fine 1.590 → 1.511 ms. No rule, cadence or tunable moved: `tools/profile_sim.gd --baseline` reports identical `state_hash` on both paths on both cities, and the 26 balance gates are untouched. The wins were all the same shape — *stop re-deriving per building what is constant across the roster*: a cached ascending roster order (`CitySim.roster_ids`), one roster pass for all twelve district service ratios instead of twelve, a columnar fire-candidate seam with the candidate table built only on sub-steps that ignite, memoised building→district, an array-row avenue-gate scan, and `PowerGrid.is_powered` no longer allocating an empty Dictionary per call. Per-phase before/after in doc 11 §2.13's Wave-7 table. **What is left is the fine tick**, and it is no longer a micro-optimization problem: `water` 4.4 ms, `power` 3.8 and `roads` 2.3 are O(buildings) on EVERY SimTick, and `roads_congestion` is a per-game-minute pass the amortized column hides (un-amortized: ordinary tick ≈ 11 ms, minute tick ≈ 38 ms, settled-hour tick ≈ 73 ms). Three costed cadence proposals, none of them taken because each moves a number the gates are written against: **(1) measured, not estimated** — drop the fire-spread breakpoint from `IncidentSystem._next_discontinuity_h()` (line 176) when no `structure_fire` is live. It fires on a 1/12-game-hour grid whether or not anything is burning and is what sets the sub-step count. With the guard in place: **15.7 → 5.1 sub-steps per coarse hour, `incidents` 54.8 → 28.0 ms, coarse step 133.8 → 104.8 ms, 12 h catch-up 1.61 → 1.26 s**; the fine tick does not move (it takes one sub-step per game-minute either way). Both state hashes change, so it needs a save-version bump and a balance-matrix re-run; **(2)** halve the `roads_congestion` cadence, or split its three passes (`congestion.recompute` 4.2 ms, `TrafficSnapshot.rebuild` 4.2, `TrafficFeed.rebalance` 7.1 per game-minute) across the four ticks of the minute so no single frame carries all of it; **(3)** accumulate the per-building power and water service ledgers per game-minute at dt = 1 min instead of per tick at dt = 15 s — the accumulators are already dt-exact, so the hour they settle is unchanged in value but not in float rounding. All three change RNG consumption or float association and therefore break save identity against existing saves. **PROPOSAL 1 IS TAKEN — Wave 8, 2026-08-20.** `IncidentSystem._next_discontinuity_h()` skips the fire-spread breakpoint when the live roster holds no `structure_fire`. Interleaved A/B, three rounds, alternating arms within each round, against a pristine `git show HEAD:` copy rather than a stash: **integrator sub-steps per coarse hour 12.00 → 1.25 on the starter city and 20.67 → 8.75 on the bench city**; **coarse step −25.6 % on the starter (8.58 → 6.28, 8.56 → 6.32, 8.23 → 6.26 ms — every round) and −20.9 % on the bench (159.7 → 127.7, 153.0 → 119.7, 154.1 → 122.0 ms)**; **`incidents` 4.00 → 1.60 ms on the starter and 78.8 → 47.1 ms on the bench**; **12 h catch-up 1.836 → 1.437 s on the bench city, inside doc 01's 2 s budget with 28 % to spare**; **fine tick flat** (+1.4 % starter, +0.5 % bench, both inside this session's noise) — exactly as predicted, because a fine tick already takes at most one sub-step. The predicted figures in this row were 15.7 → 5.1 sub-steps and 133.8 → 104.8 ms: the direction and the mechanism are confirmed, the magnitudes are not comparable because the Wave-8 bench city runs a different incident mix (20.67 sub-steps/hour at HEAD, not 15.7). `max_coarse_hours` is unchanged at 312 — `tests/test_perf_governor.gd` measures 6.21 ms/step against 6.25 before, and both floor to the same cap. **Proposals 2 and 3 are untouched and the fine path with them**, and it now has a second consumer waiting on it: doc 06 §2.10's router seam is complete but its wiring is HELD, because a ~5 ms A\* quote cannot live inside a per-sub-step assignment loop and doc 10's own test already reports *"median P0 expansions 1154 vs trigger 800 → hierarchical routing REQUIRED"*. Full per-phase tables and the router's own measurement in doc 11 §2.13's Wave-8 subsections. **PROPOSALS 2 AND 3 ARE TAKEN — Wave 9, 2026-08-20, and the row NARROWS rather than closes.** `roads_congestion` declares `EVERY_TICK` and picks its pass from `tick_index % 4` (congestion + the `c_day` sample on tick 0, `TrafficSnapshot.rebuild` on tick 1, `TrafficFeed.rebalance` on tick 2); the power and water per-building service ledgers bank once per game-minute at `dt = 1 min` instead of four times at `dt = 15 s`, with the un-banked remainder persisted so save -> load -> advance stays bit-identical. Interleaved A/B, same session, `git stash` for the before arm, on a workstation carrying three other agents' suites: **bench fine tick 19.145 -> 18.011 ms (-5.9 %)**, of which **`water` 4.100 -> 2.451 (-40.2 %)** and **`power` 3.744 -> 3.210 (-14.3 %)**; starter fine tick 1.842 -> 1.817 ms. **Proposal 2 moves no amortized number and was never going to** - the three passes still run once per game-minute each, and what changed is that the worst SimTick of the four now carries one of them instead of all three. The profiler reports a mean, so its only visible signature is `calls/step` 0.25 -> 1.00; the frame-pacing win it was asked for is real and unmeasured by this instrument. **Where the fine tick lands: 18.0 ms against this row's 8 ms target.** What is left is `roads_congestion` 5.4 (a genuine O(edges) sweep once a game-minute), `power` 3.2, `incidents` 2.9, `water` 2.5, `roads` 2.3 - and none of those is a *cadence* mistake any more, so the row narrows to *"the fine tick needs fewer edges and buildings touched per sweep, or GDExtension"*, which is doc 10 §9.3 C-3's ladder rather than a cadence proposal. **And the branch that took them also wired doc 06's router, which moved the COARSE half back out of budget**: bench coarse step 126.41 -> 189.96 ms and 12 h catch-up 1.517 -> 2.280 s against doc 01's 2 s, because the incident phase more than doubles (real A\* quotes in the assignment loop, and 66 % more integrator sub-steps - street-true arrival times are all distinct where Chebyshev ones collided on a grid). **On the REFERENCE city, which is what doc 01 §2.10's `max_coarse_hours` is derived from, the coarse step is flat (6.353 -> 6.690 ms).** The derived cap sits ON its own boundary and this branch measured both sides of it in one session - `tests/test_milestone1.gd` reads 6.42 ms -> **288** on a loaded run and 6.07 ms -> **312** on the full-suite run twenty minutes later, where Wave 8 read 6.21 -> 312. The rule steps at exactly 6.410 ms, so a 5.5 % spread straddles it. The test asserts only the C-21 floor of 72, so nothing breaks on either side; doc 01 §2.10 carries the arithmetic. Filed as the narrowed half of this row; the cheapest lever is quantising arrival times onto the SimTick grid, which is doc 06's call. Full tables in doc 11 §2.13's Wave-9 subsection; rulings in report 98 RR-26/27/28. **THE DIRTY-SET PROPOSAL IS ANSWERED — Wave 10, 2026-08-20, and half of it is REFUSED (report 98 RR-43).** The row's own next step was "fewer edges touched per sweep, or GDExtension". **Fewer edges is impossible and the census proves it: `3,092 of 3,092` edges move on an ordinary pass** — `hour` reaches every edge through `D_tod` and the α-smoother never lands on its target, so a skip-list has nothing to skip and one that skipped anyway would be a different simulation. What IS a dirty set here is over the pass's INPUTS: each edge's road class and district hold still between passes and are the whole of `c_raw`'s shared factor, so the (class, district) pairs are resolved once per graph and priced once per pass. With three whole-graph sweeps removed alongside — `mean_congestion()` folded into the pass that had already written every value it would sum, the district roster memoised on `graph_version`, and `dark_signal_counts_by_edge()` (documented O(dark nodes), actually O(all nodes)) early-outing on a maintained count — **`RoadNetwork.full_pass` measures 7.7568 → 3.5902 ms per game-minute (−53.7 %)**, `roads_congestion` **5.205 → 4.127 ms/tick (−20.7 %)** and the **fine tick 17.20 → 16.06 ms (−6.7 %)** on the bench city; on the starter city `roads_congestion` **0.873 → 0.668 (−23.5 %)**, fine tick **1.801 → 1.592 (−11.6 %)** and coarse step **9.39 → 8.18 (−12.9 %)**. Three interleaved rounds against HEAD, no arm overlapping, **hash-neutral on both cities coarse and fine**. **`roads_congestion` is no longer the fine tick's largest term** — `power` 3.0, `incidents` 2.8, `water` 2.3 and `roads` 2.4 are what is left against the 8 ms target, and none of them is a cadence mistake either. The row stays open at the same narrowed reading, with the dirty-set half of its remedy now closed by measurement. |
| **D-13** | Low | `tests/test_ui_audit.gd::BOXES` covers 360×800, 412×915, 794×924 and 880×400 — **not the project's own `window/size/viewport` of 1280×720**, which is what every screenshot harness and every desktop run renders at. Adding it would have caught D-12 in the suite. |
| **D-17** *(filed as D-14; renumbered 2026-08-19)* | ~~Medium~~ **FIXED 2026-08-19 (Wave 7)** | ~~Doc 06's `water_main_break` generator has no candidate source.~~ `CityIncidentWorld.water_mains()` now joins doc 05's `WaterSystem.mains()` into doc 06's row (`segment_id` → `id`, plus the additive `tile` / `zone_key` columns doc 05 was already holding), filtered to `ok` segments. **C-46 is closed in the same place**: the adapter that supplies the candidates sets `external_main_breaks`, so doc 05's standalone fallback stands down instead of both sides rolling — and the load path latches it, because who rolls is a fact about the program and not about the city. Measured, 12 seeds × 28 game-days of `do_nothing`: **0.00 → 0.60 water_main_break/game-week**, 0 failed. `tests/test_incident_world_join.gd`, `tests/test_water_failures.gd`. |
| **D-18** *(filed as D-15; renumbered 2026-08-19)* | ~~Medium~~ **FIXED 2026-08-19 (Wave 7)** | ~~Doc 06's `traffic_accident` generator has no candidate source.~~ `RoadNetwork.intersections()` publishes every degree-≥3 junction with doc 06 §2.6(e)'s five inputs — both per-node scalars the MAX over incident edges, which is doc 06's own "the collision happens on the worst approach" — and `CityIncidentWorld.road_intersections()` joins it. The write half landed too: `road_close_edge` / `road_set_edge_speed_mult` resolve doc 06's TILE to doc 10's worst EDGE and map the incident onto doc 10's closure-cause table, so the T2/T3/T4 consequence rows and the `on_fail` closure fire for the first time. Measured: **0.00 → 3.60 traffic_accident/game-week** at starter scale (389 junctions), which is *below* doc 06 §2.6(e)'s own worked intent of 0.687/game-day — **and it takes the ambient total past doc 92 §18's ruled 2–4/game-week band, which no floor can subtract from. See gate 19's Wave-7 note and the delivery report's open question 1.** |

---

## 15. Ranked Wave-6 recommendation

Ranked by *player-visible harm per hour of work*, not by size.

| # | Work | Why it is here | Fixes |
|---|---|---|---|
| ~~**1**~~ | ~~**Wire the resume path through `CatchUpPlanner`**~~ **DONE 2026-08-19 (Wave 7)** | `main.gd._on_app_resumed` plans the resume and walks the segments; every one lands hour-aligned, and the cap, the grace window and the residual carry apply on device | D-1 ✔ |
| ~~**2**~~ | ~~**Persist the `ui` block**~~ **DONE 2026-08-19 (Wave 7)** | `SaveService.ui_provider` / `last_loaded_ui`, wired at `main.gd:683` and applied at `main.gd:685` / `1013`; the finished tutorial stays finished across a restart | D-3 ✔ |
| **3** | **Give step 9 an `any_of` fallback** | a table row in `data/ui.json`, no code; today a slow player can wedge the tutorial permanently with no way out but Skip | D-2 |
| **4** | **Stand the event-log chip down when a sibling opens** | five lines copied from `ui/alerts_center.gd:221`; today it takes taps meant for the alerts list and the drawer at three of four device boxes. Add 1280×720 to `test_ui_audit.gd::BOXES` in the same commit | D-12, D-13 |
| **5** | ~~**Land purchase flow (S4) end to end**~~ **DONE (Wave 6)** | `ui/land_panel*.gd`, the `pick_at_ground` seam, four new refusal codes with copy, `tests/test_ui_land.gd`. Outstanding: one `game/main.gd` tap-handler line | D-5, and unblocks D-7 |
| ~~**6**~~ | ~~**Water verbs through `CitySim` + build cards**~~ **DONE, ALL OF IT** (verbs Wave 5, the last card Wave 10, the last three surfaces Wave 11) | `cmd_place_water_component` reached the infrastructure tab in Wave 5; `cmd_place_water_main` had no door until Wave 10's drag-path tool put `Water Main` and `Trunk Main` beside the pumps they feed. Wave 11 closed the rest without building the water-NODE panel this row asked for: **upgrade** is a block on the building panel of the doc-02 shell that hosts the node, **isolate/restore** is one control in two moods on the incident drawer row that names the main. Doc 93 §J1. | D-4 ✔ |
| ~~**7**~~ | ~~**Road build/upgrade/demolish verbs**~~ **DONE** (verbs Wave 5, surface Wave 10) | All three reach the player through the build sheet's ROADS tab and doc 12 §2.7's drag-path tool. Congestion is actionable: `Widen` is `cmd_upgrade_road` and it is also how a player answers doc 02's L4/L5 `E_AVENUE` gate. Report 98 RR-30. | D-5 |
| **8** | **Android notifications (doc 13 §2.4/2.5/2.7 + doc 08 §2.13)** | the entire retention loop of a session-based mobile game. Needs `POST_NOTIFICATIONS`, a channel, an `AlarmManager` bridge in `SlacumNative`, S10's settings rows, and doc 01 §2.11's pre-scheduling to be hooked up | doc 13 §2.4/2.5/2.7, doc 08 §2.13, doc 12 §2.13 |
| **9** | **Police/fire coverage** (already in flight) | `req_police_coverage` / `req_fire_coverage` are authored, validated and read by nobody; the building panel already shows the tiles | doc 02 §2.4/2.9 |
| **10** | **Benchmark city fixture + a measured device matrix** | doc 11's budgets are unverified claims until a 1,500-building city exists. Pairs naturally with the adaptive governor and the thermal ladder, neither of which can be tuned without it | D-8, doc 11 §2.13, doc 13 §2.8 |
| ~~**11**~~ | ~~**Incident pacing pass**~~ — **DONE** (Wave 6, doc 92 §18) | `data/incidents.json` `ambient_floor`: a per-channel `max()` under doc 06 §2.6's generation, no `generator_base_rates` row moved. Measured A/B, 336 game-days each side, 12 seeds: **1.88 → 3.04 ambient incidents/game-week** at starter scale, 100 % resolved, 0 failed, 0 destroyed. It also found **D-17/D-18** (filed then as D-14/D-15). | D-6 |
| ~~**12**~~ | ~~**Progression pacing pass**~~ — **DONE** (Wave 6, doc 92 §19) | doc 09 §2.11's ladder retuned onto doc 92's measured curves and moved into `data/progression.json` (doc 09 §8.2's file, never previously written): `250/1000/4000/12000/30000` → **`200/700/1600/3600/8000`**. `balanced` now reaches level 1 on game-day **2**, level 2 on **11**, level 3 on **23** — where level 3 was previously unreachable in fifty. | D-7 |
| ~~**10**~~ | ~~Benchmark city fixture + a measured device matrix~~ **DONE 2026-08-19** | The fixture, both profilers, the adaptive governor and the thermal ladder all ship. The matrix is measured and **failed in two places** — the successor work was **D-14** (bucket merging, **done the same day**: Z2 352 → 219 with UI, doc 11 §2.6/§2.13) and **D-15** (sim step cost, still open) | D-8 ✔, doc 11 §2.13 ✔, doc 13 §2.8 ✔ |
| **11** | **Incident pacing pass** | a small-city floor or a Director pacing rule so the dispatch loop is part of the game rather than a rare event | D-6 |
| **12** | **Progression pacing pass** | city level 0 for 12 game-days locks out upgrades entirely; retune doc 09 §2.11's thresholds against doc 92's curves | D-7 |
| **13** | **`CitySim.dispose()`** | 210 objects per abandoned sim; cheap now, load-bearing the moment a New Game button exists | D-9 |
| ~~**14**~~ | ~~`vehicle_state` traffic diet~~ **DONE 2026-08-19** | One packed `traffic_snapshot` per tick; bus volume 3.05× smaller, measured on the soak, save identity unchanged | D-10 ✔ |
| **15** | **Release plumbing: signing, store assets, crash reporting** | none of it is hard, all of it is on the critical path to a build anyone outside this repo can install | doc 13 §2.11/2.12 |
| **16** | ~~**Haptics + dispatch-policy settings rows**~~ **DONE (Wave 6)** | `ui/haptics.gd` (one vibrator call site, `reduce_motion`-suppressed), seven `policy: "dispatch"` rows, plus the toast surface and the city-level unlock reveal that §2.13's progression payoff needed | doc 12 §2.14, §2.13, D-11 |

The first four are, together, well under a day's work, and they are the four
that make the game's first ten minutes, its second launch and its tap targets
correct. Everything from (5)–(7) is the same shape of work repeated: subsystems
that are fully simulated and completely untouchable.

*2026-08-19: (1) and (2) are done — the second launch is correct. (3) and (4)
are still open and are still the cheapest player-visible wins in this table.*

*2026-08-20 (Wave 10): (3) and (4) are **both done** — step 9 has its `any_of`
and the event-log chip stands down. Every numbered row in this table is now
either struck or is (8), (9), (13) or (15). The successor list is **§20**, which
is written against the re-derived row basis rather than against this one, and it
is the one a future wave should be held to.*

---

# PART II — THE WAVE-10 MATRICES

*Four sweeps added 2026-08-20. Each exists because the per-§ grading in Part I
provably cannot see what it sees: a row can be SHIPPED and its asset missing
(§16), SHIPPED and its verb unreachable (§17), SHIPPED and its event unheard
(§18), SHIPPED and its screen unusable at a setting the doc calls a release gate
(§19). Doc 04's "a subsystem can be fully shipped and wholly invisible" was the
first instance of that class; these four are the systematic version of it.*

## 16. THE ASSET MATRIX — "textures on everything", counted

**The deliverable is a test, not a table.** `tests/test_asset_completeness.gd`
(19 tests, 3,167 asserts) is a JOIN rather than a depth probe: every roster the
game ships is walked against the asset it must land on, so a thirteenth
archetype, a sixth vehicle type or a seventh texture page arrives in the failure
output on the day it is authored. The tables below are what it asserts, at this
fork, with the numbers it holds.

**It passes at HEAD, and no row is xfail'd.** The two things it disagreed with on
its first run were both faults in the *sweep* rather than in the tree, and §16.4
records them because a matrix that only ever confirms its author is not worth
writing. **One real tree-side gap did surface and it is carried as a named
exemption rather than a failure**: `DEFERRED_BODIES = ["ambulance"]`, because doc
06 §6 defers EMS and the body ships anyway (**A91-D-20**). That constant is the
xfail-with-a-comment, and deleting it is the first line of the commit that
authors a `medical` vehicle type — which is exactly the property an exemption
has to have to be allowed at all.

### 16.1 Buildings — archetype × level × LOD

| Roster | Count | Held by |
|---|---|---|
| Archetypes in `data/buildings.json` | **12** | `test_01`, against `ARCHETYPE_COUNT` |
| Rungs — 6 archetypes × L1–L6, 6 × L1–L5 | **66 cells** | `test_01` asserts the split in **both** directions, so a level 6 appearing on a police station fails as loudly as one vanishing from a house |
| Meshes — every cell at LOD0 **and** LOD1 | **132** | `test_01` (join), `test_02` (loads, one surface, ≥ 3 indices, manifest `tris` == real index count) |
| …plus the shared FAR unit box | **133** | `test_08`: present, on disk, loads, and exactly `data/building_shapes.json.far_mesh.tris` = 12 |
| Triangle budgets | 320 / 420 tall / 96 LOD1 | `test_03`, per cell, message names the cell |
| Façade + roof page per cell | **132 / 132** | `test_04` resolves `archetype_surface` → `family_surface` → `{}` exactly as `CityView._surface_for` does, and fails on the `{}`; then loads the page |
| Window-hash contract fields | **132 / 132** | `test_05`: `window_cols` / `window_rows` / `windowless` present, positive when windowed, **zero** when not |
| FAR family index valid | **132 / 132** | `test_06`: every `family` is in `CityView.FAMILY_ORDER`, because a miss is `maxi(idx, 0)` — a civic tower silently lit with residential window colour at Z2 |
| Footprint: manifest == catalog | **66 / 66** | `test_07` |
| AABB == `height_m` and == footprint × `tile_m` | **66 / 66** | `test_07` |
| LOD1 never taller than LOD0 | **66 / 66** | `test_07` |
| LOD1 keeps roof signature + silhouette descriptor | **66 / 66** | `test_07` |

**The height finding, and why it is not a defect.** Twenty of the 66 cells have a
LOD1 whose `height_m` is *lower* than their LOD0's — `high_rise` L5 is 234.10 m
at LOD0 and 230.64 at LOD1, `data_center` L5 is 19.90 against 15.80. That is
`lod1_volume_keep_frac` doing its job: the LOD1 derivation drops every roof prop
that is not the signature, and a mast goes with them. It is safe **only because
`CityView` builds its `_far_scale` table inside an `if int(entry["lod"]) == 0:`
arm** (`game/render/city_view.gd:191-200`), so the far skyline is scaled by LOD0
heights whatever order the manifest lists rows in. `test_07b` asserts that arm
by source position, because moving the write out of it would make the manifest's
row ORDER decide how tall the city looks — a defect that would ship silently and
be invisible in every headless test.

### 16.2 Everything that is not a building

| Family | Roster | Assets | Held by |
|---|---|---|---|
| Emergency vehicles | 5 types in `data/vehicles.json` → 5 departments | `VehicleView.DEPT_MESH` + `DEPT_PAINT` — **three** distinct bodies, because `water` and `construction` both take the `utility` truck and are told apart by paint (`#2F7F92`, `#E8752A`) | `test_10` |
| Civilian traffic | doc 10 §2.15's 3 kinds | `car` / `van` / `truck` | `test_10` |
| Liveries | the 2×2 `vehicle_atlas.png` | `paint` / `glass` / `dark` / `livery` cells + `vehicle_uv_inset` | `test_11`, which asserts `VehicleMesh.CELL_*` and the manifest **agree**, not just that both exist |
| Construction plant | doc 11 §2.16's 5 factories | excavator, dump truck, pile heap, pile stack, barrier bay | `test_12` |
| Construction surfaces | `steel`, `stock` | `PropSurface.material(…).albedo_texture` non-null | `test_12` |
| Street furniture | the cobra head | `CobraHeadMesh.build()` — one surface, vertex COLOR per vertex, luminaire above grade, arm out over the carriageway | `test_14` |
| Power distribution | pad, service drop, plume | `PowerInfraView.pad_triangle_count()` / `wire_triangle_count()`, part ids in COLOR.a | `test_15` |
| Ground / road / water | `asphalt`, `pavement`, road, canal, district tones | pages on disk; `road_material()` and `water()` are `ShaderMaterial`, **not** the untextured fallback | `test_16` |
| Props | `hoarding`, `steel`, `stock` | declared, resolvable, and each yields a material **with a texture** | `test_13` |
| Shaders | 15 | every one loads as a `Shader` **and** is named by its owning `game/render/*.gd` | `test_17` |
| Texture pages | 18 | on disk, `.import` present (or it never reaches the export), and every façade/roof page **claimed** by an archetype or a family | `test_18` |

**One asset ships that nothing can ask for**: `VehicleMesh.ambulance()`, filed as
**A91-D-20**, listed in the test as `DEFERRED_BODIES` so the roster join stays
exact rather than lenient.

### 16.3 The census, and why it is an assertion

`test_19` asserts ten raw counts — 132 building meshes, 133 manifest rows,
8 façade pages, 4 roof, 2 ground, 3 prop, 1 vehicle atlas, 15 shaders, 5 vehicle
types, 1 deferred body. It is the only test in the file that asserts a *number*
rather than a *rule*, and it is deliberate: **doc 91 §16 quotes those totals, so
the matrix cannot grow without a wave coming here and moving them, and this
document's headline cannot go stale without a red suite.**

### 16.4 What the sweep found on its first run

Two, both in the sweep rather than in the tree, and both worth recording because
they are the shape of thing a matrix is for.

1. **The LOD1 height rule was wrong as first written** (equality), and twenty
   cells said so. The right rule is monotonicity plus the `_far_scale` source
   assertion — which is a *better* test than the one it replaced, because it
   states the invariant that actually holds rather than the one that felt tidy.
2. **The vehicle page group's reader was mis-attributed** to `VehicleMesh` when
   it is `VehicleView` that opens the manifest. The check now demands the reader
   file contain **both** the manifest path and the quoted group name, which is
   the difference between "someone mentions vehicles" and "this file reads that
   group".

## 17. THE VERB MATRIX — every `cmd_*`, and the door it has

**Method.** Every `func cmd_*` under `sim/`, crossed against three questions: is
there a **UI door** (a file under `ui/` or `game/` that calls it on a player's
behalf), a **playtest driver** (`tools/playtest.gd`), and a **goal-kind
evaluator** (`GoalSystem.EVENT_KINDS`, which is what lets `data/goals.json`
*teach* the verb). "Playtest" distinguishes two states the harness itself
distinguishes: **✔** means a strategy actually calls it in a measured run,
**probed** means it is in `KNOWN_VERBS` — recorded so its absence from a report
is visible rather than silent — and no strategy reaches for it.

### 17.1 `CitySim` — the verbs a player's shell can reach

| Verb | UI door | Playtest | Goal kind | Verdict |
|---|---|---|---|---|
| `cmd_place_building` | `ui/build_controller.gd` | ✔ | `build_archetype` | ✅ |
| `cmd_upgrade_building` | `build_controller`, `goals_model` | ✔ | `upgrade_building`, `upgrade_to_level` | ✅ |
| `cmd_demolish_building` | `build_controller`, `building_panel` | ✔ | — | ✅ |
| `cmd_repair_building` | `build_controller`, `building_panel` | ✔ | `repair_buildings` | ✅ |
| `cmd_set_priority` | `build_controller`, `building_panel` | ✔ | — | ✅ |
| `cmd_place_grid_component` | `build_controller` | ✔ | `place_grid_component` | ✅ |
| **`cmd_route_feeder`** | **none** | ✔ (probed; driven through the one-tap `place_grid_component("feeder", …)` door) | — | ⚠️ **doorless** |
| `cmd_place_water_component` | `build_controller` | ✔ | `place_water_component` | ✅ |
| `cmd_place_water_main` | `ui/path_tool.gd` | probed | `place_water_main` (authored, deliberately unused — doc 93 §G9) | ✅ |
| **`cmd_upgrade_water_component`** | **none** | probed | — | ⚠️ **doorless** |
| **`cmd_isolate_water_main`** | **none** | **none** | — | 🚫 **no caller at all** |
| **`cmd_restore_water_main`** | **none** | **none** | — | 🚫 **no caller at all** |
| `cmd_place_road` | `ui/path_tool.gd` | ✔ | `stamp_road_tiles` | ✅ |
| `cmd_upgrade_road` | `ui/path_tool.gd` | probed | — | ✅ |
| `cmd_demolish_road` | `ui/path_tool.gd` | probed | — | ✅ |
| `cmd_dispatch_unit` | `ui/unit_picker.gd` → `ui_root` → `main.gd:1278` | ✔ | — | ✅ |
| ~~**`cmd_recall_unit`**~~ `cmd_recall_unit` | `ui/incident_drawer.gd` → `ui_root.bind_recall` → `main.gd` | — | — | ✅ **Wave 12 (doc 12 D-48)** |
| `cmd_pin_incident` | `ui/incident_drawer.gd` → `main.gd:1284` | — | — | ✅ |
| `cmd_acknowledge_incident` | `ui/incident_drawer.gd` → `main.gd:1286` | — | — | ✅ |
| `cmd_set_dispatch_policy` | `ui/settings_model.gd` → `main.gd:808` | — | — | ✅ |
| `cmd_set_tax_level` | `budget_model`, `city_dashboard` → `main.gd:806` | ✔ | `set_tax_rate` | ✅ |
| `cmd_buy_block` | `ui/land_panel_model.gd` | ✔ | `buy_block` | ✅ |
| `cmd_start_development` | `ui/land_panel_model.gd` | ✔ | `develop_block` | ✅ |
| ~~**`cmd_collect_opportunity`**~~ `cmd_collect_opportunity` | `ui/build_controller.gd:1091` (the pick's zeroth arm) ← `game/main.gd:1815` (`set_tap_radius_from`) | **none** | `collect_opportunities` (authored, deliberately unused — doc 92 §35.4 item 2) | ✅ **Wave-14 merge (doc 12 §2.21)** |

**18 of 23 have a door. Five do not, and three of those five have no caller of
any kind** — `cmd_isolate_water_main`, `cmd_restore_water_main` and
`cmd_recall_unit` are called by no shell, no UI, no harness and no test.
`cmd_recall_unit` is the worst of the three and is its own defect row above,
because even the test that exercises recall reaches past the wrapper and calls
`DispatchSystem` directly — so the verb is not merely undriven, it is unproven.

**As of Wave 12 the count is 23 of 23.** §17.3's two sibling agents landed the
water and feeder doors (22 of 23), and this wave took the last one: doc 12 D-48
gives `cmd_recall_unit` the drawer chip §2.6 always specified, and the wrapper
that "is not merely undriven, it is unproven" is now driven by
`tests/test_ui_incidents.gd` through the whole chain — chip → signal → root →
command — with the refusal path asserted as well as the success one.

**Wave 15 adds a twenty-fourth verb and it arrives doorless BY DESIGN, which is
a state this matrix has not had before.** `cmd_collect_opportunity` (doc 06
§2.16) is the tap that collects a street bounty. Its door is the street-life
marker in `game/render/`, and that is a **sibling branch of the same wave** — the
sim spawner and the renderer were split so the events, the persistence rung and
the determinism accounting could land and be measured independently. So the row
above is not the familiar ⚠️ *"somebody forgot the UI"*; it is *"the UI is the
other half of this delivery"*, and the honest thing is to say which. The count is
therefore **23 of 24 at this fork, 24 of 24 at the merge**, and if the merge
lands without the marker this row becomes an ordinary doorless defect and should
be read as one. The same split is recorded on the event side by doc 93 §Q3's
`awaiting_consumer` classification, which — unlike this table — fails the suite
by itself once the consumer arrives.

> **RE-CENSUSED AT THE WAVE-14 MERGE, 2026-08-21 (`bdba0b7`) — and the count is
> 25 of 25, not 24 of 24.** The prediction above was right about the shape and
> off by one about the size, for a reason worth recording: it was written on a
> fork where `CitySim` carried 24 verbs *including* `cmd_collect_opportunity`,
> and it then quoted "24 of 24" as if the collect verb were the twenty-fourth
> *door* rather than the twenty-fourth *verb*. `grep -c "^func cmd_" sim/city_sim.gd`
> reads **25** at this merge, and a mechanical census — every `cmd_*` on
> `sim/city_sim.gd` crossed against every file under `ui/` and `game/` — finds a
> named caller for **all twenty-five**. `cmd_collect_opportunity`'s door is
> `ui/build_controller.gd`, exactly where §17.3's paragraph said it would be, and
> its shell wiring is one line at `game/main.gd:1815`. **The deferral gate closed
> the way a deferral gate is supposed to**: the sim branch shipped the verb with
> a written, named, self-clearing exemption; the UI branch shipped the door; the
> merge cleared it. Nothing here needed a ruling.
>
> This is also the fourth wave in a row in which this section's number was
> arrived at by hand, and the fourth in which it was quoted wrong somewhere
> downstream before the next audit caught it. §20.2 item 5 — the verb-door test —
> is the last of the four matrices that is not a test, and the census that
> produced this paragraph is eleven lines of Python that a `SimTest` could run in
> milliseconds. **It should be written before the count is quoted a fifth time.**

### 17.2 Sub-system verbs with no `CitySim` wrapper

These are reachable only by their owning system, so no shell and no UI can call
them however many doors get built.

| Verb | Owner | Status |
|---|---|---|
| `cmd_road_repair` | `RoadNetwork:1438` | no `CitySim` wrapper; tested directly — **and ruled** to stay that way (doc 93 §J3 / doc 10 §2.13: road condition is the policy's job, and the policy has a dial as of Wave 12) |
| ~~`cmd_set_auto_repair_policy`~~ | `RoadNetwork:1609` | **Wave 12: wrapped and doored.** `CitySim.cmd_set_auto_repair_policy(threshold, daily_cap)` + `auto_repair_policy()`; two S9 rows carrying `policy: "roads"` (doc 12 D-50). Distinct from `auto_repair_cost_cap`, which is doc 06's dispatch ceiling and always was |
| `cmd_remove_main` | `WaterSystem:1127` | no wrapper |
| `cmd_overhaul_node` | `WaterSystem:1205` | no wrapper |
| `cmd_set_water_restrictions` | `WaterSystem:1218` | no wrapper — doc 05's demand-management verb is unreachable |
| `cmd_set_water_policy` | `WaterSystem:1225` | no wrapper |
| `cmd_deploy_pump_truck` | `WaterSystem:1234` | no wrapper (and a `_zone_key` stub) |
| `cmd_install_backup_generator` | `WaterSystem:1155` | no wrapper; ADDED to this table 2026-08-20 (Wave 12) — the table above shipped with seven rows and this one missing, and doc 92 §17.6.1 copied the seven. **And ruled** the same wave to stay that way *until doc 04 ships the generator*: doc 93 §N3 / doc 05 §9. It is doc 05 handing doc 04 `{kw_required, backup_kw, coverage_frac}`, and doc 04 §12 defers the generator, so a card would sell a free permanent `coverage_frac` with no capital, tank or fuel behind it. Its only callers anywhere in the repository are `tests/test_water_system.gd:338` and `:355` |

*The count, arithmetic shown, because it has been wrong twice. **Eight** rows;
`cmd_road_repair` is **ruled not a player verb** (Wave 11 — doc 93 §J3, doc 10
§2.13); `cmd_set_auto_repair_policy` is **wrapped and doored** (Wave 12 — doc 12
D-50, doc 92 §30); `cmd_install_backup_generator` is **ruled an interface call**
with a written re-open condition (Wave 12 — doc 93 §N3, doc 05 §9). 8 − 3 = the
open count is **five**, and all five are `WaterSystem`'s: `cmd_remove_main`,
`cmd_overhaul_node`, `cmd_set_water_restrictions`, `cmd_set_water_policy`,
`cmd_deploy_pump_truck`. (This line read "seven" until Wave 12, which was correct
at the fork it was written on — before the auto-repair door and before §N3.)*

> **RE-CENSUSED AT THE WAVE-14 MERGE, 2026-08-21 — unchanged, and that is the
> point of re-running it.** Every `func cmd_*` under `sim/` outside
> `sim/city_sim.gd`, crossed against `sim/city_sim.gd` for a wrapper and against
> `ui/` + `game/` for a door: **21 sub-system verbs, 14 wrapped, 7 wrapper-less**
> — the seven are exactly the eight rows above minus `cmd_set_auto_repair_policy`,
> which Wave 12 wrapped. Of the seven, two are ruled (`cmd_road_repair` §J3,
> `cmd_install_backup_generator` §N3) and five are `WaterSystem`'s open set,
> named above. **Three of those five — `cmd_set_water_restrictions`,
> `cmd_overhaul_node`, `cmd_deploy_pump_truck` — are named verbatim in doc 05
> §6's own deferred list, so under §20.1's rule they are not gaps**; the honest
> open count is **two**, `cmd_remove_main` and `cmd_set_water_policy`, and it has
> been two since Wave 12 without anyone ranking it. That correction was made in
> §20.4 at the Wave-13 fork and is repeated here so the two sections cannot drift
> apart, which is precisely how this document's counts have gone wrong every
> other time.

### 17.3 In-flight at this fork

Two sibling agents in **this wave** are building doors for the first two
families above — `cmd_route_feeder` and the water-maintenance verbs
(`cmd_upgrade_water_component` / `cmd_isolate_water_main` /
`cmd_restore_water_main`). **This table is graded at MY fork (`a892315`) and
records what was true there.** If both land, ⚠️/🚫 becomes ✅ on four rows and
"18 of 23" becomes **22 of 23**, with `cmd_recall_unit` the last one standing —
and doc 92 §17.6 should be re-taken from the merged tree rather than from this
section.

> **RESOLVED 2026-08-20 (Wave 12), at `28b9550`.** Both landed. All four rows are
> ✅ and the count **is 22 of 23**, with `cmd_recall_unit` the last one standing
> exactly as predicted — the doors are `ui/path_tool.gd:647` (two feeder cards on
> the drag-path tool) and `ui/water_actions.gd:216 / :274 / :280` (the S5 node
> block and the S6 drawer row). Doc 92 **§17.6.2** is the re-take from the merged
> tree that this section asked for. A91-D-24 is unchanged.

### 17.4 The goal-kind side is complete

`sim/progression/goal_system.gd` implements **seventeen** objective kinds —
twelve `EVENT_KINDS`, four `STATE_KINDS` and one endurance kind
(`survive_no_abandonment`). `data/goals.json` uses **fourteen** of them, and
**every one of the fourteen resolves to an evaluator**: a row naming an unknown
kind is dropped at parse rather than crashing a city, and
`tests/test_goals_system.gd` holds the file to the reachable set. **No goal row
is unteachable.** Three kinds are authored and unused — `place_water_main`
(deliberate, doc 93 §G9: doc 05 §6 already laterals every placed pump, so a main
objective would teach reach the curriculum city does not need),
`reach_stability` and `reach_treasury` (both O(1) scalars the sim already keeps,
both simply not asked for by any of the six levels). Unused is not stranded —
each is one authored row away — but it is worth recording that a third of the
kind table has never been exercised by the shipped curriculum.

## 18. THE EVENT MATRIX — the pump-station bug class, systematized

**Method.** Every event-type name `sim/` produces — both forms, because there are
two: a `bus.emit(&"…")` / `_emit("…")` literal, **and** a `{"type": &"…"}` row on
a command result, which `CitySim` re-emits generically (`publish_progression` at
`:1086`, the construction/repair completion arms at `:3101` and `:3117`, and
eleven `drain_events()` loops). **121 distinct type names across 145 announcement
sites.** Crossed against every consumer in the tree: `game/main.gd`'s
`_on_sim_batch` translator, `game/audio/audio_events.gd`,
`game/render/*` (`weather_fx`, `vehicle_view`, `render_state_model`),
`game/notifications/`, `ui/incident_model.gd`, `sim/progression/goal_system.gd`,
and the two data-driven routers — `data/ui.json.event_log.events` (28 rows) and
`data/notifications.json.bindings` (32 rows).

### 18.1 The one direction that is clean

**Every event type named by a consumer is emitted by `sim/`.** All 28 event-log
rows and all 32 notification bindings resolve, including the ones that come from
non-obvious emitters (`BlockDarkChanged` from `CitySim`, `StreetlightsChanged`
and the five `Power*` / `LoadShed*` types from `PowerGrid`, `city_level_changed`
from `ProgressionSystem`, `block_ready` from `DevelopmentController`). There are
**no consumed-but-never-emitted rows**, which is the failure mode report RR-1
was written for and doc 11 §7.2 test 27 guards on doc 04's side.

### 18.2 The direction that was not — **re-walked and closed 2026-08-20**

The original count, kept because the delta is the finding:

| Bucket | Count (2026-08-20, first walk) | Reading |
|---|---|---|
| Consumed by shell / UI / goals / a data router | **58** | wired |
| Consumed **only** by `tests/` or `tools/` | **20** | measurable, invisible in play |
| Consumed by **nothing at all** | **43** | dead wire |

**And the count after the ruling** (`tests/test_event_matrix.gd`, which is now the
instrument — the numbers below are printed by the suite, not by an author):

| Bucket | Count | Reading |
|---|---|---|
| Types `sim/` emits, seen by the scan | **138** | +17 on the first walk; see below |
| Consumed by shell / UI / goals / a data router | **78** | wired |
| Carrying a written classification in the register | **60** | explained |
| **Unexplained** | **0** | this is the assertion |

Three things the re-walk found that counting once could not.

**(a) The first walk's regex missed a form, and its list was stale by three rows.**
138 against 121 is mostly one line of scanner: `_emit(&"water_freeze_break" if
main.frozen else &"water_main_break", …)` puts a real event type in an `else`
branch, and a scan that takes the FIRST literal after the paren calls
`water_main_break` un-emitted — while two routers are wired to it. The new scan
reads every literal from the call up to the payload dict. Separately,
`grid_feeder_routed`, `grid_node_commissioned` and `grid_node_retired` had
acquired a `main.gd` arm in Wave 10, the day after A91-D-26 was filed. A matrix
that is counted by hand is stale the week after it is counted; that is the
argument for the test, not the numbers.

**(b) The rule, narrowed (doc 93 §K1, report 98 RR-48).** *Every event whose
payload describes a PLAYER-VISIBLE state change must have a consumer or a
written exemption. Everything else carries a one-line classification and no
consumer is expected.* And the sentence that makes it affordable: **a RENDERER
is a consumer.** Doc 07 §2.4's 40 mm nuisance band has `game/render/flood_view.gd`
and nothing else, on purpose — narrate the bands that change what the player can
DO, draw the ones that only change how the street looks.

The register's vocabulary is seven words, and a row must pick one and then say why:

| word | meaning |
|---|---|
| `covered` | a sibling event, a snapshot or a poll that IS wired carries the same player-visible change; the row names which |
| `player_initiated` | the player's own command produced it and the screen that issued it already knows |
| `bookkeeping` | internal accounting or pacing; nothing the player can see changed |
| `invisible_by_design` | a doc forbids surfacing it; the row names the doc |
| `measurement` | a real seam, read by `tests/` or `tools/` only |
| `unreachable` | emitted only into a command result its caller discards, so it never reaches the bus |
| `not_an_event` | the scan matched a `"type":` field that is not an event payload |

**(c) The genuine remainder was in doc 05, not doc 07** — exactly where the first
walk's own last paragraph said it would be. Eleven types were wired in this pass:

| type | where it went | why it was visible |
|---|---|---|
| `flood_level_changed` | renderer + event log ×2 + push ×2 + toast | A91-D-26's headline |
| `road_reopened` | event log + push | the closure was announced; the reopen was not |
| `storm_phase_changed` | event log ×2 (`lead_in`, `ended`) | `weather_changed` says the sky turned; this says the cell carrying the strikes arrived |
| `water_capacity_shortage` | event log + push (P2) | doc 05 §2.9: **no repair job exists** — the only water alert whose answer is BUILD |
| `water_tank_low` | event log | the warning before the one worth waking someone for |
| `water_tank_empty` | event log + push (P1) | a zone living on what it makes |
| `water_pump_failed` / `water_treatment_failed` / `water_source_failed` | event log ×3, push ×3, **one** notify_id | `water_pump_tripped` (a recoverable lockout) was wired; a FAILURE was not |
| `water_contamination_cleared` | event log + push | `water_contamination_started` was wired; the boil notice lifting was not |
| `austerity_exited` | event log | the belt tightening was announced; the loosening was not |
| `relief_grant_awarded` | event log | money arriving in the treasury that nothing mentioned |
| `road_condition_critical` | event log | the only warning that a road was about to fail was the road failing |

Everything else is in the register with a reason. The families and the shape of
their exemptions:

* **The Director (7 rows)** — `director_event_scheduled`, `director_event_started`,
  `director_event_ended`, `director_recovery_mode`, `director_suppressed`,
  `director_scripted_suppression`, `storm_incident_downgraded` — are
  `invisible_by_design`, and it is doc 07 §2.6's rule and not a convenience:
  telling a player the game has decided to go easy on them is the one thing the
  conductor must never do. Each authored event announces itself through its own
  systems.
* **Snapshot-covered (9 rows)** — the fleet four, the two power tie events,
  `CascadeStep`, `power_restored_by_repair`, `congestion_updated`. Every one is
  re-read idempotently every tick by `vehicle_states()`, `traffic_snapshot` or
  `BlockDarkChanged`, so the event cannot be the thing that is missed.
* **Player-initiated (12 rows)** — `cmd_*` results whose issuing screen is
  already showing the outcome. Announcing them would be the game repeating the
  player back at themselves.
* **`road_graph_changed`-covered (5 rows)** — `road_built`, `road_removed`,
  `road_demolished`, `road_upgraded`, `road_block_stamped`. The street surface
  rebuild is the visible half and one event drives it.
* **The scheduler and the ledger (8 rows)** — doc 01's `event_*` plumbing and doc
  03's `treasury_credited` / `deferred_liability_*`. `sim/city_sim.gd:76` already
  said `treasury_credited` was private; the register is where that sentence now
  lives with the others.
* **One `unreachable`** — `building_ignited`. `Building.ignite()` returns it
  inside a command result and its only caller reads `ok` and drops `events`, so
  it has never reached the bus. The fire the player sees is `incident_created`.
* **One `not_an_event`** — `water_works`, a `{"type": "water_works"}` STATION
  roster row the `"type":` arm cannot tell from an event payload. Naming it is
  cheaper and more honest than a cleverer regex.

**A91-D-26 is closed.**

### 18.3 The pump-station rule itself holds

The rule — *every event that creates a `Building` must reach `main.gd`'s
`_on_sim_batch` translator or the building is invisible until relaunch* — was
re-checked exhaustively rather than assumed. **`sim/city_sim.gd` writes
`buildings[…]` at exactly four sites**: `:511` (starter-city boot), `:1022`
(deserialize), `:1248` (`cmd_place_building` → emits `building_placed_sim`) and
`:1981` (`cmd_place_water_component` → emits `water_component_placed`). The two
boot paths are populated by the shell from the roster; **both runtime paths have
a translator arm** (`main.gd:483` and `main.gd:488`). The class of bug is closed
at this fork, and the reason it is worth restating is that the second arm was
added the day before this audit.

**A test for this IS written now** — `tests/test_event_matrix.gd`, doc 11 §7.3f —
and it is written with the caveat this paragraph used to raise, out loud in its
own header. The emit list is enumerable only by scanning `sim/` source with a
regex, and a regex-over-source test **fails open**: it will pass on the day
someone writes `bus.emit(kind_variable, …)`. That is still true and the suite
says so. What the test buys anyway is the direction that matters — **a name the
scan CAN see and that nothing consumes has to be explained in the register
before the suite goes green**, so the matrix cannot go stale between audits the
way it went stale three rows deep in a single wave (§18.2(a)).

And §18.1's direction — every consumed name is emitted — **now fails closed**,
over both routers whole rather than over doc 04's slice: doc 11 §7.2 test 27
kept the narrow version and §7.3f test 48 walks
`data/ui.json.event_log.events` and `data/notifications.json.bindings` entire.
That was §20's "cheap next step" and it is done.

## 19. THE SCREEN MATRIX — 14 of 15 screens, 49 states, 12 sweeps

> **This heading is the Wave-10 reading and is kept as the record. At the
> Wave-14 merge it is 15 of 16 screens, 57 states, 18 sweeps** — the deck grew by
> `veil_load` / `veil_catchup` (Wave 13, S15), four `coach_*` states and
> `street_coach` / `economy_street` (Wave 14, doc 12 D-61 … D-64); count them
> with `sed -n '/^const SCREENS/,/^]/p' tools/ui_preview.gd`. **The one screen
> that has never been opened is still S13** — `grep -c "event_log\|EventLog"
> tools/ui_preview.gd` is **0**, and **A91-D-28 stands.** §19.1 has the Wave-13
> re-measurement; §20.1b clause 5 has the current line. *(Annotated 2026-08-21,
> doc 91 §20.6.)*

**Method.** `tools/ui_preview.gd --screen=all --audit --strict` over
`game/ui/ui_root.tscn`, at **five device boxes** × **two accessibility settings**
(100 % / default targets, and `--text-scale=1.3 --large-targets`), **plus two
more at 640 × 340** — `data/ui.json.layout.min_safe_box_dp`, the box doc 12
§2.18's A2 names and nothing tests, swept at 100 % and at the **150 %** A2
specifies. 49 named
states, covering **fourteen** of doc 12 §2.2's fifteen screens — **S13, the event
log, has no preview state at all** and is filed as **A91-D-28**. Its chip is
swept constantly, as a sibling of every other state; its panel has never been
laid out by this harness.

| Box | 100 %, default targets | scaled + large targets |
|---|---|---|
| 360 × 800 (COMPACT) | **clean, exit 0** | ✗ exit 1 — 36/49 dirty, 73 overlaps, **3 offscreen** |
| 412 × 915 (the Fold's cover panel) | **clean, exit 0** | ✗ exit 1 — 36/49 dirty, 73 overlaps |
| 794 × 924 (the Fold's inner panel) | **clean, exit 0** | ✗ exit 1 — 36/49 dirty, 73 overlaps |
| 880 × 400 (§2.3's reference box) | **clean, exit 0** | ✗ exit 1 — **49/49 dirty**, 220 overlaps, **6 offscreen** |
| 1280 × 720 (the project's own viewport) | **clean, exit 0** | ✗ exit 1 — 36/49 dirty, 73 overlaps |
| **640 × 340 (`min_safe_box_dp`)** | ✗ exit 1 — **1 offscreen** | ✗ exit 1 at **150 %** — **49/49 dirty**, 228 overlaps, **72 offscreen** |

*The last row's right-hand column is the only one taken at **150 %**, because
that is the scale A2 names for that box. Every other right-hand cell is 130 %.*

**The 100 % column is the good news, on the five boxes anyone has ever run**:
245 state-sweeps, zero findings — and the two open defects the Wave-4 sweep left
(**D-12**, **D-13**) are both closed and re-verified here. The sixth box is the
qualifier and it is the last row: at 100 % on `min_safe_box_dp` the sweep is
**not** clean, which is A91-D-29 and is dealt with below.

**The 130 % row is the finding.** Three causes, each its own defect:

| Cause | Where | Row |
|---|---|---|
| The right-edge chip column does not re-flow — `AlertsCenter/Chip`, `EventLog/Chip` and `IncidentDrawer/Handle` overlap once `larger_touch_targets` inflates them | all five boxes, 36 of 49 states | **A91-D-21** |
| Controls land **outside the viewport** — including the settings sheet's ✕ at 360×800 and the title screen's START NEW at 880×400 | 360×800 and 880×400 | **A91-D-22** |
| The HUD top bar does not yield to the rails — `LeftRail/SpeedButton` and `OverlayRail/Button` over `TopBar/Chips/Row` | 880×400, all 49 states | **A91-D-23** |

**Why this was never caught, precisely.** It is *not* that the suite ignores A2
and A3 — `tests/test_ui_audit.gd::test_every_surface_fits_the_narrowest_display_at_130_percent_text`
mounts the deck at `(1.3, true)` and checks it. What that test checks is
**`get_combined_minimum_size().x <= 360.0`**: one axis, one box, and only the
`SURFACES` list of full-width panels. Every defect above is something that check
cannot express —

* **A91-D-21 and A91-D-23 are overlaps**, not widths. Two controls can each fit
  the display and still cover each other.
* **A91-D-22 and A91-D-29 are the Y axis.** `Confirm_cancel` at y 318.5 + 96 on a
  340-tall box, `SpeedButton` at y −70: both fit horizontally, and the assertion
  never looks down.
* **Four of the five boxes are never swept at 130 % at all** — the a11y test
  hard-codes 360 dp, and 640 × 340 is in no list.

So the gate exists, passes, and is the wrong shape: **a width-only check on one
box, guarding a requirement whose failures this wave are all vertical or
positional.** The fix is not "add an a11y test", it is "make the existing one a
loop over `BOXES` and give it the audit's overlap and offscreen checks", which is
what `tools/ui_preview.gd --audit` already implements and the suite does not
call.

**130 % was not the bar, so the bar was measured too.** Doc 12 §2.18's A2
criterion is *"layout survives **150 %** at **640 × 340 dp**"* — and **640 × 340
appears in no `BOXES` list, no sweep and no test in this repository**. Two more
sweeps were run at it, and they are the last two rows of the table above:

* **At 100 %, 640 × 340 is NOT clean.** 48 of 49 states pass and one does not:
  `TitleLayer/TitleScreen/Center/Panel/Body/Confirm/Actions/Confirm_cancel
  "CANCEL"` sits at y 318.5 with a height of 96 against a 340-tall viewport —
  **26 dp off the bottom, at default text scale, on the box `data/ui.json`
  itself calls the minimum safe size.** Filed as **A91-D-29**; it is the only
  base-scale layout defect this audit found and the five-box sweep could not see
  it, because 640 × 340 is not one of the five.
* **At 150 % + large targets it fails completely**: 49 of 49 states dirty, 228
  overlaps and **72 offscreen findings**. The signature is not the chip column
  this time — it is `HUDLayer/LeftRail/SpeedButton` laying out at **y −70 … 56
  against a 340-tall box in every single state**, 70 of its 126 dp clipped off
  the top, and `OverlayRail/Button` overlapping both rows of the top bar's chips
  49 times each. A2's stated criterion is not close to met at A2's own stated
  geometry, and A10's "always reachable in ≤ 2 taps" is left standing on a
  half-clipped target.

So the five 130 % sweeps in the table are a **lower bound on the failure**.
Whoever fixes A91-D-21, A91-D-22 and A91-D-23 should measure at 150 % / 640 × 340
first — it is the geometry the requirement is written against, it is strictly
tighter than anything else measured here, and it is the only one that also
catches A91-D-29.

## 20. THE DEFINITION OF DONE

*The lead asked for a page a future wave can be held against. This is it. It is
deliberately shorter than the four matrices above, because a definition that
needs a page to state is not a definition.*

### 20.1 Done, stated once

> **SLACUM CITY is done when every `### 2.N` of docs 01–13 is SHIPPED — meaning
> implemented, REACHABLE BY A PLAYER, and held by a named test — and when the
> four matrices are green: every roster row has a textured asset (§16), every
> `cmd_*` has a door (§17), every emitted event has a consumer or a written
> reason not to (§18), and every screen passes the audit at every device box at
> BOTH accessibility settings (§19). Anything the docs themselves defer is not a
> gap. Anything else is.**

Five clauses, each already mechanised or one afternoon from being — listed here
with the three standing gates the project has always had, because "done" is all
eight green at once and not five:

| Clause | The gate that measures it | Green today? |
|---|---|---|
| Every §2.N SHIPPED | this document's Part I | ~~161~~ **162 / 183 (88.5 %)** — doc 03 §2.9 closed 2026-08-20 |
| Every roster row has an asset | `tests/test_asset_completeness.gd` | **✅ 19 tests, 3,167 asserts** |
| Every `cmd_*` has a door | §17 (wants a test — see below) | 18 / 23 |
| Every event has a consumer | §18 (wants a test — see below) | 58 / 121 wired, 78 / 121 heard by *something* |
| Every screen clean at every box × both a11y settings | `tools/ui_preview.gd --audit --strict` — the suite's own a11y check is width-only on one box | ~~**5 / 12 sweeps**~~ **10 / 18 sweeps at `28b9550`** (six boxes × 100 % / 130 % / 150 %, 52 states each — see the Wave-12 re-grade after the count table): clean at 100 % on five of six boxes and at 130 % + large targets on four of six. A91-D-21 closed; A91-D-22 narrowed to 880 × 400; A91-D-23 and A91-D-29 open. The instrument still covers 14 / 15 screens (A91-D-28) |
| Determinism | `tools/profile_sim.gd --hash-only --baseline`, both cities, **and `tests/test_save_determinism_days.gd`** | ✅ — and the second instrument is new, because the first one never covered the clause the constitution actually writes. `--hash-only` proves two runs of the same seed agree; §5 also says *the same SAVE plus the same elapsed time*, and until 2026-08-20 every test of that saved inside the first game-day. Three defects were living in that gap (A91-D-30, report 98 §26). **The baseline moves this wave** — three keys were added to the body — and the trajectory is proved unchanged by diffing the canonical body itself: 25 differing lines on each city, every one of them a new key or a `section_version` stamp |

| Every screen clean at every box × both a11y settings | `tools/ui_preview.gd --audit --strict`; the suite's own a11y check now runs **six** boxes including `min_safe_box_dp` (D-58) | ~~**5 / 12 sweeps**~~ ~~**10 / 18 sweeps at `28b9550`**~~ **18 / 18 sweeps at Wave 13** — six boxes × 100 % / 130 % / 150 %, **55 states each, 990 state-sweeps, 0 findings, exit 0 eighteen times** (§19.1). A91-D-21, A91-D-22, A91-D-23 and A91-D-29 all closed. The instrument covers 15 / 16 screens — S15 arrived with its own two states, S13 still has none (A91-D-28). **Deck is 57 states at the Wave-14 shell/UI fork** (doc 12 D-61 … D-64 added `street_coach` and `economy_street`); re-measured there at **412 × 915 / 100 %** and at **640 × 340 / 130 % + large targets**, both **57 / 57 clean, 0 findings, exit 0**, and the two new states alone across all six boxes × both a11y settings — **24 / 24 clean**. The 990-sweep figure above is the Wave-13 reading of a 55-state deck and is dated as such |
| Determinism | `tools/profile_sim.gd --hash-only --baseline`, both cities | ✅ |
| Balance | `tests/test_balance_gates.gd`, ~~28~~ ~~29~~ ~~30~~ **32** gates — re-counted at the Wave-14 merge (`grep -c "^func test_gate_" tests/test_balance_gates.gd` = 32): gate 29 preset ordering (doc 92 §29.6), gate 30 the incident-roster ceiling (§31 / doc 06 §2.13(b)), gate 31 the moral-hazard ceiling and gate 32 the active-play income share (doc 92 §36.3/§36.4) | ✅ |
| Suite | `tests/run_tests.gd` | ✅ ~~109 / 1,909 / 505,294~~ ~~112 files / 1,991 tests / 511,256 asserts~~ ~~117 files / 2,056 tests / 519,294 asserts~~ ~~120 files / 2,096 tests / 524,684 asserts~~ **124 files / 2,209 tests / 534,614 asserts / 0 failed / 0 silent** — re-measured at the **Wave-14 merge** (`bdba0b7`, 2026-08-21), one `tools/run_suite.sh` process, `ALL TESTS PASSED`, exit 0. **+4 files and +113 tests**, of which **100 are the four files the four Wave-14 branches added** (`test_street_opportunities.gd` 17, `test_street_life.gd` 31, `test_ui_street.gd` 46, `test_city_services.gd` 6) and 13 grew inside existing files. `tests/test_save_determinism_days.gd` remains deliberately the most expensive one in the suite — see report 98 §26 RR-60. **§20.1b is the current clause table; this row is kept because it is the only place the suite's whole history is in one line** |

**Two of those clauses have no test yet**, and making them into tests is the
cheapest structural work left in the project: a verb-door test (walk `CitySim`'s
`get_method_list()` for `cmd_*`, assert each is named by a file under `ui/` or
`game/`, with an explicit allow-list for the ones a wave has ruled deliberate)
and an event-consumer test (walk `data/ui.json.event_log.events` and
`data/notifications.json.bindings`, assert every `type` is emitted in `sim/`).
Both are an afternoon. Both would have caught defects this audit found by hand.

#### 20.1a The eight clauses, RE-TAKEN at the Wave-13 fork — 2026-08-21

*The table above accumulated four waves of struck rows and two rows appear in it
twice. This is the same eight clauses, each measured once, at this fork. It
supersedes every row above it.*

| # | Clause | The gate that measures it | Green at this fork? |
|---|---|---|---|
| 1 | Every §2.N SHIPPED | Part I, re-derived row by row | **169 / 187 (90 %)** — 91 % of the 185 non-deferred. 15 PARTIAL, 1 ABSENT. **Eight of the sixteen gaps are doc 13's** |
| 2 | Every roster row has a textured asset | `tests/test_asset_completeness.gd` | ✅ — and the one exemption is named: `DEFERRED_BODIES = ["ambulance"]`, A91-D-20, deleted the day doc 06's EMS lands |
| 3 | Every `cmd_*` has a door | §17 — **still no test**, §20.2 item 5 | **24 / 24 on `CitySim`.** Census run 2026-08-21: every `cmd_*` on `sim/city_sim.gd` is named by a file under `ui/` or `game/`, `cmd_recall_unit` included (A91-D-24 closed; `game/main.gd:914` binds it). **Five sub-system verbs still have no wrapper**, all five `WaterSystem`'s — `cmd_remove_main`, `cmd_overhaul_node`, `cmd_set_water_restrictions`, `cmd_set_water_policy`, `cmd_deploy_pump_truck` (doc 92 §32.6) — plus two ruled deliberate (`cmd_road_repair` §J3, `cmd_install_backup_generator` §N3). **Of the five, three are named in doc 05 §6's own deferred list and are therefore not gaps** (§20.4): the honest open count is **two** |
| 4 | Every event has a consumer or a written reason not to | **`tests/test_event_matrix.gd`** — ✅ **this clause became a test in Wave 11** | ✅ **140 types emitted, 78 consumed by the game, 62 classified, zero unexplained** (printed by the suite at this fork). The exemption register is in the test, so a new unexplained type fails the build |
| 5 | Every screen clean at every box × both a11y settings | `tools/ui_preview.gd --audit --strict`; the suite's own width gate runs six boxes including `min_safe_box_dp` | ✅ **18 / 18 sweeps** — 6 boxes × 3 text scales × **55 states = 990 state-sweeps, 0 findings, exit 0 eighteen times** (§19.1). A91-D-21/22/23/29 all closed. **The instrument covers 15 of 16 screens**: S13's panel still has no preview state (A91-D-28) |
| 6 | Determinism | `tools/profile_sim.gd --hash-only --baseline`, both cities, **and `tests/test_save_determinism_days.gd`** | ✅ founding `32a3e968…` / `90a41a97…`, bench `385dacb2…` / `e4204947…` (Wave 15; the previous set `e8bffba1…` / `08bfdfaa…` / `e760f930…` / `bd2d8f30…` was two waves stale in this row — see the provenance box). The multi-day gate saves at 2 h, 26 h, 50 h and seven game-days on both cities — the window every earlier proof was smaller than |

| 5 | Every screen clean at every box × both a11y settings | `tools/ui_preview.gd --audit --strict`; the suite's own width gate runs six boxes including `min_safe_box_dp` | ✅ **18 / 18 sweeps** — 6 boxes × 3 text scales × **55 states = 990 state-sweeps, 0 findings, exit 0 eighteen times** (§19.1). A91-D-21/22/23/29 all closed. **The instrument covers 15 of 16 screens**: S13's panel still has no preview state (A91-D-28). **57 states at the Wave-14 shell/UI fork** — the deck grew by `street_coach` and `economy_street` (doc 12 D-61 … D-64) and stays clean: 57/57 at 412 × 915 / 100 %, 57/57 at 640 × 340 / 130 % + large, and 24/24 for the two new states across all six boxes × both a11y settings. The 990-sweep figure is Wave 13's, over 55 states, and is dated |
| 6 | Determinism | `tools/profile_sim.gd --hash-only --baseline`, both cities, **and `tests/test_save_determinism_days.gd`** | ✅ founding `e8bffba1…` / `08bfdfaa…`, bench `e760f930…` / `bd2d8f30…`. The multi-day gate saves at 2 h, 26 h, 50 h and seven game-days on both cities — the window every earlier proof was smaller than |
| 7 | Balance | `tests/test_balance_gates.gd` | ✅ **30 gates** (gate 29 = preset ordering §29.6; gate 30 = the incident-roster ceiling, §31 / doc 06 §2.13(b)) |
| 8 | Suite | `tests/run_tests.gd` | ✅ **118 files / 2,083 tests / 522,300 asserts / 0 failed / 0 silent** (2026-08-21, `tools/run_suite.sh`) |

**Two clauses of the eight moved since Wave 12, and both moved the same way:
a matrix became a test.** Clause 4 is `tests/test_event_matrix.gd` and clause 5's
width half is `tests/test_ui_audit.gd::BOXES` with the `min_safe_box_dp` row in
it. **Clause 3 is the last matrix that is still a section**, and §20.2 item 5 has
been the cheapest structural work left in this project for three waves. It is now
also the *only* one, which is a better argument for taking it than any it has had
before: the census in row 3 above was run by hand, and a hand census is exactly
what §16, §18 and §19 each stopped needing the wave they became tests.

#### 20.1b The eight clauses, RE-TAKEN at the WAVE-14 MERGE — 2026-08-21 (`bdba0b7`)

*§20.1a was taken at the Wave-13 fork, and it has since accumulated two duplicate
rows of its own (clauses 5 and 6 each appear twice, the second copy written by a
later branch) — the same palimpsest fault it was created to fix, one wave later.
**This is the same eight clauses, each measured once, at the merge**, and it
supersedes §20.1a and everything above it. Nothing here is inherited: every green
in the last column was produced by running the thing named in the middle one.*

| # | Clause | The gate that measures it | Green at the Wave-14 merge? |
|---|---|---|---|
| 1 | Every §2.N SHIPPED | Part I, re-derived row by row | **172 / 190 (90 %)** — 91 % of the 188 non-deferred. 15 PARTIAL, 1 ABSENT. **Eight of the sixteen gaps are doc 13's**, and doc 13's blocker is now an install rather than a config change |
| 2 | Every roster row has a textured asset | `tests/test_asset_completeness.gd` | ✅ — one written exemption, `DEFERRED_BODIES = ["ambulance"]` (A91-D-20), deleted the day doc 06's EMS lands |
| 3 | Every `cmd_*` has a door | §17 — **still no test**, §20.2 item 5 | ✅ **25 / 25 on `CitySim`** (`grep -c "^func cmd_" sim/city_sim.gd` = 25; every one named by a file under `ui/` or `game/`). **Seven sub-system verbs have no wrapper**: two ruled (`cmd_road_repair` §J3, `cmd_install_backup_generator` §N3) and five `WaterSystem`'s — of which **three are in doc 05 §6's own deferred list and are therefore not gaps**. The honest open count is **two**: `cmd_remove_main`, `cmd_set_water_policy` |
| 4 | Every event has a consumer or a written reason not to | `tests/test_event_matrix.gd` | ✅ **144 types emitted, 82 consumed by the game, 62 classified, zero unexplained** — up from 140 / 78 / 62 at Wave 13, the four new types being the opportunity layer's. **Both `awaiting_consumer` deferral rows deleted themselves at this merge** (`grep -c 'awaiting_consumer:' tests/test_event_matrix.gd` = 0), which is doc 93 §Q3's gate working as written — printed by the suite at this merge. The exemption register is in the test, so a new unexplained type fails the build |
| 5 | Every screen clean at every box × both a11y settings | `tools/ui_preview.gd --audit --strict`; the suite's width gate runs six boxes including `min_safe_box_dp` | ◐ **green on the evidence that exists, and the evidence is not from this fork — said plainly rather than inherited as a ✅.** What **is** measured here: the deck is **57 states** (`sed -n '/^const SCREENS/,/^]/p' tools/ui_preview.gd`, counted — 49 + `veil_load`/`veil_catchup` + four `coach_*` + `street_coach`/`economy_street`), and **the instrument still covers only 15 of 16 screens** — `grep -c "event_log\|EventLog" tools/ui_preview.gd` is **0**, so **A91-D-28 stands.** What is **not** measured here: the sweep itself. `--audit --strict` lays out real `Control`s and needs a display; this is a headless workstation. The standing evidence is Wave 13's **18 / 18 sweeps — 6 boxes × 3 text scales × 55 states = 990 state-sweeps, 0 findings, exit 0** (§19.1), plus the Wave-14 shell branch's partial re-take at the larger deck (**57 / 57** at 412 × 915 / 100 %, **57 / 57** at 640 × 340 / 130 % + large targets, and **24 / 24** for the two new states across all six boxes × both settings — doc 12 D-61 … D-64). **A full 6 × 3 × 57 sweep has never been run on the merged tree**, and the honest reading is that the two new states are swept and the other 55 are green as of Wave 13. **Deferred by this pass with a named clearing condition, house style:** one run of `xvfb-run -a ~/.local/bin/godot --path . -s res://tools/ui_preview.gd -- --screen=all --audit --strict` on a session with a display clears it, and **this row reads *measured* instead of *last known green* the moment it does.** It is the same command §20.4 workstation item 6 wants in CI, so the deferral and the backlog item close together or not at all |
| 6 | Determinism | `tools/profile_sim.gd --hash-only`, both cities, **and `tests/test_save_determinism_days.gd`** | ✅ founding `a27da24aaf6e9663…` / `d2dec6727c64001d…`, bench `7c99720f5ff14553…` / `8f60accb6d91ad1e…` — **re-measured here, and all four differ from all four sets printed in §20.4's branch boxes.** Two of the four merged branches wrote `sim/` and `data/`; see §20.4 |
| 7 | Balance | `tests/test_balance_gates.gd` | ✅ **32 gates** — 30 at Wave 13, plus gate 31 (the moral-hazard ceiling) and gate 32 (the active-play income share), both from Wave 14's money pass. Doc 92 §36.3 / §36.4 |
| 8 | Suite | `tests/run_tests.gd` | ✅ **124 files / 2,209 tests / 534,614 asserts / 0 failed / 0 silent**, `ALL TESTS PASSED`, exit 0 — one `tools/run_suite.sh` process at `bdba0b7`, 2026-08-21. The Wave-13 line read 120 / 2,096 / 524,684; the four new files are `test_street_opportunities.gd`, `test_street_life.gd`, `test_ui_street.gd` and `test_city_services.gd`. `tests/test_save_determinism_days.gd` is still deliberately the most expensive file in the suite (report 98 §26 RR-60) and is most of the wall clock |

**Six of eight are outright green, clause 1 is 90 %, and clause 5 is green on
Wave-13 evidence rather than on a measurement from this fork.** That last
distinction is the one this table exists to make: §20.1a marked clause 5 ✅ and
the ✅ was inherited from a sweep taken two waves and two states ago. **A clause
whose instrument cannot run on the machine doing the audit is not green; it is
*last known green*, and the row must say which.**

The two *structurally* incomplete clauses are not row counts at all: **clause 3
is still a section rather than a test**, and **clause 5's instrument still cannot
see one of sixteen screens** (A91-D-28) and cannot be run headless at all. Both
have been the cheapest work left in this project for four waves running, and the
argument for taking them got one notch stronger this wave rather than weaker: the
clause-3 census above was run by hand for the fifth time, and the number it
produced (**25**) is one larger than the number §17.1's own prose predicted for
the merge (**24**) — not because anything went wrong, but because a hand census
counts what a person remembers to count. *Write the test; add the `xvfb-run`
step.*

### 20.2 Distance to done, ranked and sized

Ranked by *player-visible harm per hour of work*, sized S (< half a day),
M (a day or two), L (a wave).

| # | Work | Size | Closes | Why here |
|---|---|---|---|---|
| ~~1~~ | ~~**Re-flow the right-edge chip column under `larger_touch_targets`**~~ **DONE — closed by `3a025e9`, verified 2026-08-20** | **S** | ~~A91-D-21~~ | ~~36 of 49 states at every box~~ — zero chip-column findings at any of six boxes now; the next item on this list is the one below it |
| ~~2~~ | ~~**Keep sheet/menu/title controls on screen** — at 130 % **and at 100 % on 640 × 340**~~ **DONE 2026-08-20 (Wave 13, doc 12 D-54 … D-57)** | **S** | ~~A91-D-22~~, ~~A91-D-29~~ | ~~a 360 dp player on A3 cannot close settings; a folded-Fold player cannot press START NEW; and on A2's own reference box the title screen's CANCEL is 26 dp off the bottom at default scale~~ — **zero `[offscreen]` findings at six boxes × three text scales.** The root cause turned out to be one line in `ThemeBuilder` (D-54), which is why this was an S that had resisted three waves of S-sized fixes |
| ~~3~~ | ~~**Widen `tests/test_ui_audit.gd`'s a11y check from one axis on one box to `BOXES` + 640 × 340, with overlap and offscreen**~~ **HALF DONE 2026-08-20 (Wave 13, doc 12 D-58)** | **S** | A91-D-21/22/23/29 regressions | **640 × 340 is a `BOXES` row now**, and so is S15's panel in `SURFACES` — the width gate runs the box the requirement is written against. What is still not in the *suite* is the overlap/offscreen half: those are pixel checks and a headless run has no laid-out geometry, so they live in `tools/ui_preview.gd --audit --strict` and want a CI step rather than a test. The remaining work is one line of CI, not one of GDScript |
| ~~4~~ | ~~**`data/difficulty.json` + `sim/economy/difficulty.gd` + pass it at `city_sim.gd:197`**~~ **DONE 2026-08-20** | ~~M~~ | A91-D-19 | ~~three quarters of doc 03 §2.9's authored table is unreachable, and every balance number is measured on one preset~~ — shipped whole (loader, seam, save section v6, front-door chip, gate 29, doc 92 §29). **It left two things behind, and they are new rows rather than leftovers of this one**: doc 92 §29.5(a)'s `E_roads_repair` compounding (`M_repair × M_exp`, 2.00× on crisis) makes the crisis founding city net-negative at hour one, and §29.5(b) — see the row below |
| ~~**4b**~~ | ~~**Bound the incident cascade**~~ **DONE 2026-08-20 (Wave 13)** — a `do_nothing` city's open-incident count multiplied by ~2.5–2.9 **per game-hour** from game-day 104 on `crisis` (103 → 89,055 in eight game-hours, 0.22 s → 269 s of wall per game-hour, no ceiling) | ~~M~~ | **A91-D-35** *(filed as A91-D-31)*, doc 92 §31, doc 06 §2.13(b), report 98 RR-62, doc 93 §M1 | **Closed by a saturation rule, not by a retune.** The mechanism was `crime`'s own cascade — one child at tier 4, two more at tier 5, all `scope: "district"`, mean offspring **three** — and neither of this row's original suspects: a ruin is already not an ignition candidate (doc 02 §2.12) and a burnt-out incident already closes. Doc 06 §2.13(b) makes §2.13's own ≤ 40 binding on every AUTOMATIC birth and tapers ambient generation from a knee placed at the worst backlog the matrix has ever measured (26 against a measured peak of 13). After: peak **37** open over 200 game-days on `crisis`, worst game-hour **0.47 s**, whole run **89 s**; the 7×3×21 matrix is byte-identical, both determinism baselines hold, gate 30 asserts the bound, and `tools/profile_decay.gd` reproduces the curve |
| 5 | **The verb-door test and the event-consumer test** | **S** | §20.1's two untested clauses | the two matrices that found the most, mechanised |

| 4 | **`data/difficulty.json` + `sim/economy/difficulty.gd` + pass it at `city_sim.gd:197`** | **M** | A91-D-19 | three quarters of doc 03 §2.9's authored table is unreachable, and every balance number is measured on one preset |
| 5 | **The verb-door test** and ~~the event-consumer test~~ (✅ **DONE 2026-08-20**: `tests/test_event_matrix.gd`, 6 tests, and the exemption register is in it) | **S** | §20.1's two untested clauses | the two matrices that found the most, mechanised; one of the two now is |
| 6 | **Yield the 880×400 top bar to the rails** | **M** | A91-D-23 | §2.3's own reference box, all 49 states |
| 7 | **A debug build that carries the plugin, on the Fold** | **M** | doc 13 §2.4–§2.9 (5 rows), doc 08 §2.13's platform half | **the single largest block of PARTIAL rows in the project, and it is one build away from being measurable rather than one feature.** *Updated 2026-08-21 (Wave 14): the build the phone got requested no permissions, and the reason was a STALE AAR rather than the preset* — four locally built APKs show either source is sufficient and that only a build with neither declares zero (report 98 §28 RR-69). The AAR is tracked now and `export_presets.cfg` carries the four as a second source, so the permission set survives a stale binary. **The remaining work here is unchanged in size and is now honestly one device session**: one `dumpsys notification` read and one permission prompt driven by hand |
| 8 | ~~**Draw the flood**~~ — ✅ **DONE 2026-08-20.** Not a `WeatherFX` arm and not `sc_wetness`: `game/render/flood_view.gd` + `game/shaders/flood.gdshader`, one MultiMesh over the flooded block's road tiles, **+1 draw call**. Announced in both routers, toasted once, and `road_reopened` got the all-clear it never had. See doc 11 §2.9b, report 98 RR-48 | **M** | A91-D-26's headline, doc 07 §2.4 | was: 460 events a session, drawn by nothing |
| 9 | **Doors for the five doorless verbs** | **M** | A91-D-24, doc 05's verbs row | two sibling agents are on four of the five this wave (`cmd_route_feeder` and the water maintenance trio); `cmd_recall_unit` is the fifth and is two lines |
| 10 | **Persist the notification budget** | **S** | A91-D-27, doc 08 §2.13 | four lines, the same shape `SaveService.ui_provider` took |
| 11 | **Persist the event-log ring** | **S** | doc 08 §2.10 — **the last ABSENT row in the tree, and a constitutional clause** (doc 00 §9, §0.5) | the log is empty on every launch; the ring exists and the report that wants it exists |
| 12 | **`E_FIRE_COVERAGE` / `E_POLICE_COVERAGE` upgrade gates** | **M** | doc 02 §2.9, doc 12 §2.9 | the field, the overlay and the panel tiles all ship; falling below a requirement still costs nothing |
| 13 | **Store listing, privacy policy, data-safety form** | **M** | doc 13 §2.12's remainder | the signing pipeline is done; this is the rest of "a stranger can install it" |
| 14 | **`CitySim.dispose()`** | **S** | D-9 | 199 objects per abandoned sim; load-bearing the day a New Game button exists |
| 15 | **The fine tick, 18.0 ms against 8** | **L** | D-15's narrowed half | no longer a cadence problem — doc 10 §9.3 C-3's ladder or GDExtension |
| 16 | **Doc 05 §2.14's 0.45 / 0.50** | **S** | A91-D-25 | one number in a doc, or two keyframes in `data/time.json` |
| 17 | **A preview state for S13** | **S** | A91-D-28 | two lines in `tools/ui_preview.gd`; today the one screen the sweep cannot see is the one whose chip caused D-12 |
| ~~18~~ | ~~**Find what `roads` restores differently after a day boundary**~~ **DONE 2026-08-20 — and it was not roads.** One ULP in `WaterDemandCache`'s per-zone demand sums, which the live run maintains incrementally and a restore rebuilt from scratch; `water.section_version` 2 → 3 carries them. Roads was the loudest symptom and the wrong suspect. The gate that would have caught it in Wave 5 now exists: `tests/test_save_determinism_days.gd` saves at 2 h, 26 h, 50 h and seven game-days on both cities. See report 98 §26 RR-60 | ~~M~~ | ~~A91-D-30~~ | ~~a determinism violation on the founding city at a save point a player reaches in one sitting~~ — the lesson worth keeping is the method: the first field to MOVE is not the field that is wrong, and the only instrument that separates them is a reflection-walk comparator run *before* the two cities advance (`tools/diff_restore.gd`) |
| 19 | **The loading veil, and the catch-up veil with it** | **S** | doc 13 §2.9 / §2.9.1's own pseudocode | *added 2026-08-20.* Doc 13 has assumed `veil.show()` since it was written and the shell has never had one. The restore is now eleven resumable steps and the catch-up has always been sliceable, so **both levers are built and neither has a surface**; the title door standing in for it (report 98 §24) covers CONTINUE and covers nothing else. One `ColorRect`, one label, one progress bar, and a `SCREENS` entry so the sweep can see it |
| ~~20~~ | ~~**Inject doc 10's two dead siblings — `profile_weights_of` and `weather_state_of`**~~ **DONE 2026-08-21 (Wave 14)** | ~~S~~ | **A91-D-32** | *added and closed in the same wave.* Two `Callable` fields `CitySim` never assigned, each with a plausible default behind it, so doc 09's per-district land-use weights and doc 10 §8's eleven weather rows were authored and unreachable — **rain had never slowed traffic in a shipped build**. Closed by report 98 RR-69: `DistrictRegistry.profile_weights(id)` (doc 09 §2.6.1) and `CitySim._road_weather_state`, both injected before `bootstrap()`. Four determinism baselines re-recorded, four of thirty gates re-fitted with derivations (doc 92 §33), twenty-six untouched |

| 19 | **The loading veil, and the catch-up veil with it** | **S** | doc 13 §2.9 / §2.9.1's own pseudocode | *added 2026-08-20.* Doc 13 has assumed `veil.show()` since it was written and the shell has never had one. The restore is now eleven resumable steps and the catch-up has always been sliceable, so **both levers are built and neither has a surface**; the title door standing in for it (report 98 §24) covers CONTINUE and covers nothing else. One `ColorRect`, one label, one progress bar, and a `SCREENS` entry so the sweep can see it. **Both halves are real as of 2026-08-21 (Wave 14).** Wave 13 built the surface and the catch-up half still drew for one frame, because the shell's resume was a synchronous loop with no frame in it; `CitySim.begin_catchup()` + `CatchUpCursor` closed that (A91-D-31, report 98 §28 RR-72) and nothing in `ui/` had to change to make the bar move |

~~**Items 1–3, 5, 10, 11, 16, 17 and 19 are all S and together are about one day.**~~
**Items 1, 2, 3 and 19 are done as of 2026-08-20 (Wave 13); 5, 10, 11, 16 and 17
remain and are about half a day between them.** They
close five defects, the last ABSENT row in the tree, and both of the definition's
untested clauses. Item 7 is the one that moves the count table most — eight
PARTIAL rows to five SHIPPED and three measured — and it needs a build, not a
feature.

**One lesson from item 2, worth keeping where the ranking is done.** Items 1, 2
and 3 were all sized **S** and item 2 had survived *three* waves of S-sized
fixes — D-46 solved the corner rail, D-47 wrapped the sheet rows, D-51 gave the
top bar a second axis, D-52 capped the centred cards. Every one of those fixes
is correct and every one of them is still shipped. But all four were solving for
a control that was **37 % taller than it was ever meant to be**, because
`ThemeBuilder` scaled its padding twice (doc 12 D-54). The ranking was right
about the size and wrong about the shape: the work was one line, and it was
underneath four rows rather than beside them. *When the same defect class comes
back after a fix, price the next attempt as a search for a common cause, not as
another instance.*

#### 20.2a Every item of §20.2, statused at the Wave-13 fork — 2026-08-21

*The list above has been edited in place across four waves and reads as a
palimpsest. This is its status line, item by item, once. **§20.4's two tables
supersede it** — they split the same work by whether a workstation can close it,
which is the split that actually matters now.*

| # | §20.2 item | Status at this fork |
|---|---|---|
| 1 | Re-flow the right-edge chip column | ✅ **DONE** (Wave 12, D-46). A91-D-21 closed |
| 2 | Keep sheet/menu/title controls on screen | ✅ **DONE** (Wave 13, D-54…D-57). A91-D-22 and A91-D-29 closed |
| 3 | Widen the suite's a11y check | ◐ **HALF.** `640 × 340` is a `BOXES` row and S15 is a `SURFACES` row; the overlap/offscreen half needs laid-out geometry and lives in `tools/ui_preview.gd`. **Remaining work is one line of CI** → §20.4 workstation item 6 |
| 4 | `data/difficulty.json` + the loader + the seam | ✅ **DONE** (Wave 11). A91-D-19 closed; doc 03 §2.9 SHIPPED |
| 4b | Bound the incident cascade | ✅ **DONE** (Wave 13, doc 06 §2.13(b)). A91-D-35 *(filed as A91-D-31)* closed; **gate 30** asserts it |
| 5 | The verb-door test **and** the event-consumer test | ◐ **HALF.** `tests/test_event_matrix.gd` ships (140 / 78 / 62 / 0). The verb-door test is the **last matrix that is not a test** → §20.4 workstation item 4 |
| 6 | Yield the 880 × 400 top bar to the rails | ✅ **DONE** (Wave 12, D-51). A91-D-23 closed |
| 7 | A debug build that carries the plugin, on the Fold | ◐ **PREMISE RETIRED TWICE.** ~~The gap is `export_presets.cfg`'s empty permission list~~ — **that premise died in Wave 14 too** (report 98 RR-70): all four `permissions/*=true` are on all three presets, the AAR is tracked, and the four-APK matrix showed the empty list was never the root cause. **What is left is not a build and not a config: `adb install -r` and a human tapping ALLOW** → §20.4 device item 1. *(Re-checked 2026-08-21 at the Wave-14 merge; this row has now named three different blockers in three waves and is the reason §20.6's headline is about re-running commands rather than re-reading sentences.)* |
| 8 | Draw the flood | ✅ **DONE** (Wave 11, RR-53). A91-D-26 closed; doc 07 §2.4 SHIPPED |
| 9 | Doors for the five doorless verbs | ✅ **DONE on `CitySim` — 24 of 24.** A91-D-24 closed. Of the five sub-system verbs left, **three are deferred by doc 05 §6** and two are open (§20.4) |
| 10 | Persist the notification budget | ○ **OPEN**, S → §20.4 workstation item 2 |
| 11 | Persist the event-log ring | ○ **OPEN**, S — **the last ABSENT row** → §20.4 workstation item 1 |
| 12 | `E_FIRE_COVERAGE` / `E_POLICE_COVERAGE` | ○ **OPEN**, M — two rows, one fix → §20.4 workstation item 3 |
| 13 | Store listing, privacy policy, data-safety form | ○ **OPEN** — not code and not device-gated; three documents and a Console form |
| 14 | `CitySim.dispose()` | ○ **OPEN**, S — filed (D-9), not ranked with the coverage work |
| 15 | The fine tick, 18.0 ms against 8 | ○ **OPEN**, L — D-15's narrowed half; doc 10 §9.3 C-3's ladder or GDExtension |
| 16 | Doc 05 §2.14's 0.45 / 0.50 | ○ **OPEN**, S → §20.4 workstation item 7 |
| 17 | A preview state for S13 | ○ **OPEN**, S — the one screen of sixteen the sweep has never opened → §20.4 workstation item 5 |
| 18 | Find what `roads` restores differently after a day boundary | ✅ **DONE** (Wave 13) — and it was water, not roads. A91-D-30 closed; `tests/test_save_determinism_days.gd` is the gate |
| 19 | The loading veil, and the catch-up veil with it | ✅ **DONE** (Wave 13, RR-66). S15 ships as doc 12 §2.20 with two `SCREENS` states in the same commit |

**Nine of nineteen done, two half, eight open — and the eight are §20.4's
workstation list plus the two filed non-coverage items (14, 15) and the store
paperwork (13).** One item on this list has *changed shape* rather than moved:
item 9's five doorless verbs are two, because three of them are named in doc 05
§6's own deferred list and were never gaps.

### 20.3 What this document is now for

Part I is the row ledger and stays append-only. Part II is the mechanised half,
and the intention is that it **shrinks**: §16 is already a test, and §17 and §18
should become tests rather than sections (§20.2 item 5). When all four matrices
are tests, this document's job is Part I alone, and "done" is a number the suite
prints.

*2026-08-21: three of the four are tests now — §16 was one from the day it was
written, §18 became `tests/test_event_matrix.gd` in Wave 11, and §19's width half
is `tests/test_ui_audit.gd` with `min_safe_box_dp` in its `BOXES`. §17 is the
last section. §20.4 is what this document is for in the meantime.*

---

## 20.4 ARE WE DONE? — the completion statement

> ### ⚠ READ THIS FIRST — the current statement begins at *THE COMPLETION STATEMENT, RE-TAKEN AT THE WAVE-14 MERGE*, below
>
> **The next three blocks are BRANCH boxes.** They were written on three
> different Wave-14 forks, each is true about its own fork, and **none of them is
> true about the merged tree** — they quote three different suite lines, three
> different gate counts and, between them, **four different determinism sets, not
> one of which `bdba0b7` produces.** They are kept because the record of what
> each branch measured is the evidence that the merge had to be re-derived rather
> than picked from. **Quote none of them.** Everything from the merge block
> onward is measured at `bdba0b7`.

*Written 2026-08-21 at the Wave-13 fork, re-derived rather than inherited, and
written to be quoted. Three questions, answered in order: what is done, what
remains and why each remaining item cannot be closed from this workstation, and
what is deferred by design. §20.1's rule governs all three — **anything the docs
themselves defer is not a gap; anything else is.***

**Provenance *(Wave-13 fork — SUPERSEDED, see the merge block below)*.** Godot 4.7.2, headless. The suite at this fork:
**121 files / 2,124 tests / 532,153 asserts / 0 failed / 0 silent**, with
**30 balance gates** inside it. *(Wave 15. Taken in three file-range slices of `tests/run_tests.gd`'s own discovery — same files, same per-file `SimTest` instance, same `begin_test`/`end_test` silent-method guard, three processes instead of one so a 40-minute run fits a budget; each slice carries its own `UserDirIsolation`, which is the isolation the runner's header exists to provide. The Wave-13 line read 118 / 2,083 / 522,300.)* Determinism, re-measured rather than quoted:
founding `32a3e96855218af5…` / `90a41a97eb1e49fb…`, bench `385dacb23d3ec1b7…` /
`e420494749d5c90e…` — re-measured at the Wave-15 fork. **All four MOVED this wave**, and the move is enumerated rather than asserted: doc 06 §2.16's opportunity layer adds exactly three keys to the city body and changes no existing value, so stripping those three reproduces the Wave-14 set (`0b67cd22…` / `4f9f3830…` / `bbe658ae…` / `158501b8…`) to the byte on both cities and both paths — report 98 RR-77's table. *(The set this paragraph carried before today was the pre-Wave-14 one, which had been superseded for a wave; the correction is in the provenance box at the head of this file.)*

> **Wave-15 delta (2026-08-21, the money pass).** The statement above stands
> where it is not superseded, and its numbers move. Measured on this branch,
> Godot 4.7.2, headless: **121 files / 2,114 tests / 528,027 asserts / 0 failed /
> 0 silent**, exit 0, with **32 balance gates** inside it — gate 31 is the
> moral-hazard ceiling and gate 32 is the active-play income share (doc 92
> §36.3/§36.4). One new test file, `tests/test_city_services.gd`, carries doc 03
> §7's new tests 47–49. And the four determinism baselines move **by design** —
> founding `939294ec35f4c5a5…` / `474171a6beeb6dbd…`, bench `d8cd840cdacacf02…`
> / `2404cb0a04ec8860…` — because a ledger line that had never existed now
> settles and two state grants now reach the treasury (doc 92 §36.6).
>
> **Two rows join Part I and both close in the same wave**, which is the shape
> this document keeps producing when a question is asked early and answered late:
> `A91-D-38` (automatic dispatch had been paying since Wave 1 into a ledger with
> no line for it — **$921 on a `do_nothing` city's founding day, 12.5 % of that
> day's reported net**) and `A91-D-34` (doc 06's reward curve paid up to
> **2.73×** the damage it prevented on a cheap building at high tier). The first
> was filed by doc 06 itself, as its own §9 open question 6, **in Wave 1**; doc
> 93 §N1 wrote its re-open condition in Wave 11; report 98 RR-77 rules it here.
> **Doc 06's open-question list is now empty of money questions**, and the row
> count of §20.1 clause 1 is unchanged at 169/187 — this wave shipped no new
> `### 2.N` row, it made an existing one honest.

**Wave-14 amendment, 2026-08-21 (STREET LIFE branch).** Doc 11 gains one row —
**§2.17**, shipped — so the denominator moves from 187 to **188** and the
numerator from 169 to **170**. That arithmetic is **not** restated in the count
table above, and deliberately: three branches forked from this same Wave-13
commit and each adds rows, so any total written from one of them is stale before
it merges. RR-55's rule governs — *a digest published from a branch is a
statement about that branch; quote the fork or quote the merge* — and RR-76's
durable fix is the real answer (when §17's verb doors become a test, "done" is a
number the suite prints). **The lead re-derives the count at the merge; this note
records the row, not the total.** The four determinism baselines are re-measured
rather than quoted and are unchanged — founding `0b67cd2273a5115a…` /
`4f9f383038fbe383…`, bench `bbe658aeeaa9f855…` / `158501b8845b056f…` — which is a
statement about this branch and holds by construction, since it wrote no `sim/`
and touched no `data/` file the sim reads.

---

> ## THE COMPLETION STATEMENT, RE-TAKEN AT THE WAVE-14 MERGE — 2026-08-21 (`bdba0b7`)
>
> **Everything above this line is the record of four branches, each true about
> its own fork and none of them true about the tree.** Four Wave-14 branches
> forked from the Wave-13 commit; each wrote a delta box here; each was right to
> and none restated the total. This block is the merge, and **it supersedes every
> number in every box above it** — including its own predecessor's, which is the
> habit RR-76 exists to enforce.

**Provenance, measured at this fork and not inherited.** Godot 4.7.2, headless,
one `tools/run_suite.sh` process, exit 0. The suite:
**124 test files / 2,209 tests / 534,614 asserts / 0 failed / 0 silent**, `ALL TESTS PASSED`, exit **0**, with **32 balance gates** inside it (`grep -c "^func test_gate_" tests/test_balance_gates.gd` = 32; the last two are Wave 14's `test_gate_31_*` moral-hazard ceiling and `test_gate_32_active_play_pays_more_and_idling_still_pays`).

**The delta is +4 files and +113 tests over the Wave-13 line of 120 / 2,096 / 524,684, and it reconciles exactly against the four files the four branches added** — `tests/test_street_opportunities.gd` (17), `tests/test_street_life.gd` (31), `tests/test_ui_street.gd` (46) and `tests/test_city_services.gd` (6) — **100 of the 113 tests, with the remaining 13 grown inside existing files.** Each branch box above reports a **smaller** suite than this one and none is wrong: they are four different trees. *(One run, one process, not sliced — the Wave-15 box's three-slice note describes a budget workaround, not a property of the suite.)*

**Determinism, re-measured at this fork — and all four baselines MOVED at the
merge, which no branch box above predicts because no branch could.**
`tools/profile_sim.gd --hash-only`, seed 1337:

| city | coarse 24 h | fine 2.0 h |
|---|---|---|
| founding (`CitySim.boot_from_files`) | `a27da24aaf6e9663…` | `d2dec6727c64001d…` |
| `tests/fixtures/bench_city.json` | `7c99720f5ff14553…` | `8f60accb6d91ad1e…` |

**Not one of the four sets printed in the boxes above is this set, and the reason
is arithmetic rather than alarm.** Two of the four Wave-14 branches wrote `sim/`
and `data/` — the opportunity layer added three keys to the city body and a
`street` RNG stream; the money pass gave automatic dispatch a ledger line and
added two state grants — so the merged tree's trajectory is neither branch's.
The branch boxes above quote **four different** founding-coarse digests
(`32a3e968…`, `939294ec…`, `0b67cd22…`, `e8bffba1…`), each published as a
measurement of the branch that wrote it — and **every one of them wrong about
`bdba0b7`**, which is the half this pass verified by re-running.
**That is RR-55 in its purest form**: a digest published from a branch is a
statement about that branch. The one thing a merge must therefore never do is
*pick* one — and the box at the head of this file did exactly that, twice, which
is the RR-76 drift pattern this edition finally stops by making the head box
carry the fork it was measured at.

### What is DONE

> **SLACUM CITY is 90 % shipped: 172 of 190 `### 2.N` rows of docs 01–13 —
> implemented, reachable by a player, and held by a named test — or 91 % of the
> 188 rows that are not deferred by their own docs. Six of the eight clauses of
> §20.1's definition are outright green at this fork and a seventh (the
> accessibility sweep) is *last known green* on Wave-13 evidence, because its
> instrument needs a display and this workstation is headless — §20.1b says which
> is which rather than inheriting a ✅. Clause 1 is 172/190; clause 3 is
> **25 of 25** at the `CitySim` layer, with two sub-system verbs still without a
> wrapper and neither of them ranked. **One row in the entire tree is ABSENT.**
> Half of everything that remains is one document's, and that document needs a
> phone, not a feature — and as of this merge it does not even need a
> configuration change first.**

Row by row, at this merge — the same rows as the count table above, folded to
one line per document:

| Doc | Rows | SHIPPED | the gap, if any |
|---|---|---|---|
| 01 Time & ticks | 12 | **12 — complete** | — |
| 02 Buildings | 14 | 13 | §2.9 service coverage: the field ships, the `E_*_COVERAGE` upgrade gates do not |
| 03 Economy | 13 | **13 — complete** | — |
| 04 Power grid | 13 | 11 | §2.10 backup generators (PARTIAL, re-open condition written §N3); §2.11 black start (DEFERRED by the doc) |
| 05 Water | 16 | 14 | §2.14 a doc quote (A91-D-25); §2.10 contamination (DEFERRED by the doc) |
| 06 Incidents & dispatch | **14** | **14 — complete** | — |
| 07 Weather & director | 7 | **7 — complete** | — |
| 08 Offline & persistence | 15 | 12 | §2.3 (`main.gd`'s resume body untested), §2.13 (A91-D-27), §2.10 **ABSENT** — the event-log ring |
| 09 Map, land, starter city | 14 | **14 — complete** | — |
| 10 Roads & traffic | 15 | 14 | §2.15 the traffic overlay is edges, not polylines — cosmetic |
| 11 Rendering & performance | **23** | **23 — complete** | — *(+§2.17 STREET LIFE, Wave 14)* |
| 12 UI/UX | **21** | **20** | §2.9 building panel — the same root as doc 02 §2.9 *(+§2.20 S15 and +§2.21 the payday, both SHIPPED, both printed for the first time at this merge)* |
| 13 Android | 13 | 5 | eight PARTIAL — seven device-gated, one (§2.12's remainder) three documents and a Console form. The list below |
| **Total** | **190** | **172 (90 %)** | 15 PARTIAL · 1 ABSENT · 2 DEFERRED |

**Six of thirteen documents are complete, and doc 11 is the sixth for the second
wave running** — it gained a row and shipped it in the same wave, which is the
only way a complete document stays complete.

And the four matrices §20.1 adds on top of the rows:

| matrix | at this merge | is it a test? |
|---|---|---|
| every roster row has a textured asset (§16) | ✅ — one written exemption, `DEFERRED_BODIES = ["ambulance"]` (A91-D-20), deleted the day doc 06's EMS lands | ✅ `tests/test_asset_completeness.gd` |
| every `cmd_*` has a door (§17) | ✅ **25 of 25** on `CitySim` — re-censused mechanically at this merge, `cmd_collect_opportunity` included | ❌ **still a section.** §20.2 item 5, and the last of the four |
| every event has a consumer or a written exemption (§18) | ✅ **144 emitted / 82 consumed / 62 classified / zero unexplained**, printed by the suite at this merge (Wave 13 read 140 / 78 / 62; the four new types are the opportunity layer's). **Both `awaiting_consumer` deferral rows deleted themselves at the merge** — `grep -c "awaiting_consumer:" tests/test_event_matrix.gd` is 0 | ✅ `tests/test_event_matrix.gd` |
| every screen clean at every box × both a11y settings (§19) | ◐ **last known green, not measured here.** The deck is **57 states** at this merge (counted). Standing evidence: Wave 13's **990 state-sweeps, 0 findings** over 55 states, plus the Wave-14 shell branch's **57/57** at two boxes and **24/24** for the two new states. `--audit --strict` needs a display; a full 6 × 3 × 57 sweep has never run on the merged tree | ◐ the **width** half is `tests/test_ui_audit.gd::BOXES` (with `min_safe_box_dp`); the overlap/offscreen half needs laid-out geometry and wants an `xvfb-run` CI step |

Determinism holds past a day boundary (`tests/test_save_determinism_days.gd`,
saves at 2 h, 26 h, 50 h and seven game-days on both cities), and the balance
contract is **32 gates** — gate 31 the moral-hazard ceiling and gate 32 the
active-play income share, both added by Wave 14's money pass (doc 92
§36.3/§36.4).

**One line of the superseded block above was arithmetically wrong and is
corrected here rather than repeated.** It read *"92 % of the 186 rows that are
not deferred"*; `170 / 186` is **91.4 %**. The equivalent line now reads
`172 / 188 = 91.5 %` — **91 %** — and it is printed as a division so the next
reader can check it in one step instead of trusting it.

### What REMAINS, and why each item cannot be closed from this workstation

**Eight of the sixteen gaps are doc 13's, and all eight reduce to one sentence:
the code exists, the build exists, the manifest is right, and nobody has run the
notification surface on a phone.**

**The blocker has moved in each of the last three waves and it has now run out of
places to move to. Read the sequence, because it is the shape of this whole
document's remaining work.** Wave 12 said the blocker was *"a debug build that
carries the plugin"*; Wave 13's Fold session refuted that — the APK carries it
and `GodotPluginRegistry` logs `Initializing Godot plugin SlacumNative` — and
named `export_presets.cfg`'s empty permission list instead; **Wave 14 (report 98
RR-70) refuted that in turn, with four APKs built from the four combinations of
{plugin manifest, preset flags} showing that *either* source suffices and only a
build with *neither* declares zero.** The failing build had neither, because the
tracked AAR was stale. Both sources are live now:
`grep -n "permissions/" export_presets.cfg` returns
`post_notifications`, `receive_boot_completed`, `vibrate` and `wake_lock` all
`=true` on all three presets, and `tests/test_release_plumbing.gd` asserts it in
the suite so it cannot quietly revert. `permissions/custom_permissions` is still
`PackedStringArray()` and **should stay that way** — all four are 4.7.2's own
named flags and a custom entry would duplicate them.

**So there is no configuration change left to make.** What is left is an install
and a person: `adb install -r`, then a human tapping ALLOW on a runtime prompt
that no script can tap. Every device item below is written on that basis, and
item 1's step *(a)* — which for two waves told the reader to go and fill in a
preset field — is deleted rather than reworded, because it is done.

| # | What is device-gated | Rows it closes | **The exact command or user action that closes it** |
|---|---|---|---|
| 1 | **The notification flow, end to end** | doc 13 §2.4, §2.5, §2.6, §2.7 (4 rows) + doc 08 §2.13's platform half | ~~*(a)* fill `permissions/custom_permissions` on all three presets~~ — **done in Wave 14 by the flags rather than the custom array (RR-70); there is nothing to edit.** The run, in order: *(a)* `bash tools/build_native_plugin.sh` then `bash tools/setup_android.sh` — the AAR is tracked but an export does not rebuild it, and the templates are gitignored, which is precisely the staleness that cost Wave 13 a session; *(b)* export debug; *(c)* `adb install -r`, then `aapt2 dump permissions` on the artefact **you just installed** — not on one you built earlier, which is RR-70's other lesson; *(d)* **a human taps ALLOW on the runtime prompt** — the one step no script can take; *(e)* `adb shell dumpsys notification \| grep -A20 com.slacumcity.game` for the channels, then background the app and `adb shell dumpsys alarm \| grep slacumcity` for the scheduled alarm — **that grep has never returned anything on real hardware and it is the single most informative command left in this project.** *(No longer a prerequisite, kept because it is free and needs no device: `python3 tools/aab_badging.py build/slacum-release.aab --permissions` on a `tools/make_release.sh` artefact confirms the release path carries the four as well as the debug path. Use that script and not `aapt2 dump permissions`, which doc 13 §7's D-13 row still names for the release AAB and which cannot read an AAB at all — an AAB's manifest is protobuf, not binary XML, which is exactly why `tools/aab_badging.py` exists.)* |
| 2 | **The three-pose day/night matrix** | doc 11 §2.13's device column; doc 13 §2.8's heat half | `bash tools/run_matrix.sh q1` on an unlocked phone — three zooms × hour 13 / hour 21, preset pinned Balanced. `build_check` refuses a build that cannot receive `launch_args`, so the run either measures or says why in one line; `bash tools/run_matrix.sh` with no argument runs the whole session in priority order |
| 3 | **The zebra / flood / pad-shadow A/Bs** | doc 11 §2.1.2's fragment ladder, §2.9b, §2.10b — all three published as workstation numbers | `bash tools/run_matrix.sh zebra flood pads`. The four render levers (`--road-detail`, `--pad-shadows`, `--flood-detail`, `--flood`) exist in `game/` as of the third Fold session and had never been drivable before it |
| 4 | **Tier-C `road_detail`** | doc 11 §2.13's `presets.performance.road_detail = 1`, **marked provisional in `data/render.json`** | the same matrix run on a **tier-C part**, not on the Fold. The zebra loop costs 2.4× every wear term put together on this workstation; the ruling assumes it is worse still at `render_scale` 0.70 on a weaker ALU:bandwidth ratio, and that assumption has never been measured. It is the only *provisional* number in the render presets |
| 5 | **The presentation-corruption ("tearing") A/B** | doc 11 §2.13's open band; the reason `PERF` is not always-on | it rides **real player sessions**, not a matrix: `adb shell run-as com.slacumcity.game touch files/perf_capture.flag` to arm, play, then `rm -f` it and play the same content again. The suspicion is that the per-frame `viewport_set_measure_render_time` GPU timestamp query provokes the swapchain bands — which is unfalsifiable in a 40-second capture and obvious across two sessions. **First command of the next window regardless:** `adb shell run-as com.slacumcity.game rm -f files/perf_capture.flag`, because it was left armed. *(Re-checked 2026-08-21: `tools/run_matrix.sh` now arms and disarms the flag itself — `trap disarm_flag EXIT INT TERM` — so a completed matrix run leaves it clean. The advice stands because the flag was armed by a **hand** session before that trap existed, and nobody has been back to the device since to confirm either way. **Unverifiable from a workstation; costs one command to make moot.**)* |
| 6 | **An on-device ANR run of the long catch-up** | doc 13 §2.9 | background the app for 12 real hours, resume, and read the `PERFIO` load row plus `am` for an ANR. The workstation number (1.04 s for 43 coarse hours) is a workstation number |
| 7 | **Battery** (doc 13 §7 D-07) | doc 13 §2.8's other half | `dumpsys batterystats --reset`, a measured session, `dumpsys batterystats com.slacumcity.game`. Never attempted |
| 8 | **Store listing, privacy policy, data-safety form** | doc 13 §2.12's remainder | not device-gated and not code: a human writes three documents and fills a Console form. The signing pipeline ships and is asserted (`tests/test_release_plumbing.gd`) |

**The other eight gaps are NOT device-gated, and the accounting closes exactly:
six of them are workstation work, and two are already ruled or deliberate.**

The workstation backlog, ranked by player-visible harm per hour, with the size
§20.2 uses. Three of the eight items below are not `§2.N` rows at all — they are
the definition's own clauses and the sweep's own coverage, and they are here
because §20.1 counts them as part of "done":

**Every row carries the command that PROVES it is still open**, re-run at this
merge — because §20.6's headline finding is that two of these evidence commands
had gone stale inside one wave, and a backlog whose entries cannot be re-verified
in one line is a wish list.

| # | Work | Size | Closes | The command that shows it is open — and what closes it |
|---|---|---|---|---|
| 1 | **Persist the event-log ring** — the log is empty on every launch | **S** | **doc 08 §2.10 — the last ABSENT row in the tree**, and a constitution §9 clause | open: `grep -c "^func capture_state" ui/event_log_model.gd` → **0** (the one `capture_state` in that file is the class doc at `:28` saying the class has none). Closes with: a `capture_state`/`restore_state` pair on `EventLogModel` and a fourth `manager.register_section(...)` beside `game/save_service.gd:380–382` and `:661–663` |
| 2 | **Persist the notification budget** — four lines, the shape `SaveService.ui_provider` already took | **S** | doc 08 §2.13; A91-D-27 | open: `grep -c NotificationRouter game/save_service.gd` → **0**, while `game/notifications/notification_router.gd:634–641` already ships a versioned `serialize()`/`deserialize()` pair called by nothing outside `tests/`. Closes with: registering it as a section |
| 3 | **`E_FIRE_COVERAGE` / `E_POLICE_COVERAGE` upgrade gates** — the field, the overlay and the panel tiles all ship; falling below a requirement still costs nothing | **M** | **doc 02 §2.9 and doc 12 §2.9 — two rows, one fix** | open: `grep -rn "E_FIRE_COVERAGE\|E_POLICE_COVERAGE" --include=*.gd --include=*.json .` → **nothing**. Closes with: the two blocker enum values, the check in `cmd_upgrade_building`, and the S5 tile's `Fix this →` finally costing something |
| 4 | **The verb-door test** — the last matrix that is not a test | **S** | §20.1b clause 3 *(not a row)* | open: `grep -rn "get_method_list" tests/` returns four hits and **not one of them is a verb census** — two are the runner's own method discovery (`run_tests.gd:72`, `test_runner_guard.gd:29`) and two are doc 05's (`test_water_failures.gd:244`, `:248`). Closes with: walk `CitySim.get_method_list()` for `cmd_*`, assert each is named by a file under `ui/` or `game/`, with an explicit allow-list. **The eleven-line Python census that produced this pass's 25 / 25 is the whole algorithm** |
| 5 | **A preview state for S13** — two lines beside `alerts` in `SCREENS` | **S** | A91-D-28; the one screen of sixteen the sweep has never opened *(not a row)* | open: `grep -c "event_log\|EventLog" tools/ui_preview.gd` → **0**. Closes with: an `event_log` branch in `_apply()` that calls `EventLog.open()`, and a `SCREENS` entry beside `alerts` |
| 6 | **A CI step for the overlap/offscreen sweep** — a headless run has no laid-out geometry, so this is one line of CI, not one of GDScript | **S** | §20.2 item 3's remaining half *(not a row)* | open: `grep -rn "ui_preview" .github/` → **nothing**. Closes with: `xvfb-run -a ~/.local/bin/godot --path . -s res://tools/ui_preview.gd -- --screen=all --audit --strict` as a CI step. **This is also what would let §20.1b clause 5 read *measured* instead of *last known green*** — and while the CI file is open, `python3 tools/check_doc_refs.py` is one more line and is already green (report 98 RR-94(d)) |
| 7 | **Doc 05 §2.14's 0.45 / 0.50** — one number in a doc, or two keyframes in `data/time.json` | **S** | doc 05 §2.14; A91-D-25 | open: `data/time.json.curves.water_demand_commercial` holds `[21, 0.65]` / `[23, 0.35]` → **0.50** at h22 against §2.14's stated `0.45`. Closes with: **edit the doc**, not the store — `tests/test_water_data.gd:51–55` already asserts the store's 0.50 and C-33 makes `data/time.json` authoritative |
| 8 | **A headless test that drives `main.gd._on_app_resumed`** | **S** | doc 08 §2.3's narrowed remainder | open: no test constructs the shell — `tests/test_catchup_cursor.gd` names the method in two `##` comments and re-implements its loop as an oracle (`_advance_monolithic`, `:35`). Closes with: a test that loads `res://game/main.tscn` — no test loads it today; `tests/test_tutorial_flow.gd` gets as far as `res://game/ui/ui_root.tscn` and hand-copies the wiring — and calls the real `_on_app_resumed` against `CatchUpPlanner`'s own segments |

Seven of those eight are **S**. **Together they are about a day, and they close
the last ABSENT row in the tree, three defects, one clause of the definition of
done and the last unswept screen.** Item 3 is the only M and it is the only one a
player would notice.

**And the two remaining gaps are not backlog at all:**

* **doc 04 §2.10 — backup generators.** Ruled in doc 93 §N3 with a written
  re-open condition: doc 05's `cmd_install_backup_generator` is an interface call
  and stays wrapper-less until doc 04 ships §2.10's capital price, tank, burn rate
  and refuelling. Doc 04 §12 defers the generator; the row is PARTIAL rather than
  DEFERRED only because §2.10 is written as if it ships.
* **doc 10 §2.15 — cosmetic civilian traffic.** The feed ships and drives
  `VehicleView`; the *overlay* is a per-edge MultiMesh rather than §2.15's
  polyline. A deliberate, recorded, cosmetic-only difference.

Two more, filed and deliberately not ranked with them because neither is a
coverage row: **`CitySim.dispose()`** (D-9 — 199 objects per abandoned sim,
load-bearing the day a New Game button exists) and **the fine tick at 18.0 ms
against 8** (D-15's narrowed half — no longer a cadence problem; doc 10 §9.3
C-3's ladder or GDExtension, and an **L**).

### What is DEFERRED BY DESIGN

*Enumerated from the docs' own §6 "MVP Cut → Deferred" lists and nowhere else.
None of it is a gap under §20.1, and none of it is invented here — every entry is
quoted from the document that owns it. Where a §6 list had itself gone stale, the
entry is corrected rather than repeated: see doc 12 and §20.5.*

> **RE-READ AGAINST THE FOUR §6 LISTS AT THE WAVE-14 MERGE, 2026-08-21.** The
> table below stands entry for entry — the four Wave-14 branches deferred nothing
> new and un-deferred nothing — with **three annotations** and **no strikes**:
>
> * **Doc 11 §6 — "decorative pedestrians".** Still deferred, and doc 11 §2.17
>   is **not** it. STREET LIFE draws one body per live `sim/street` opportunity
>   and **zero** when the roster is empty (RR-83); a decorative pedestrian is
>   ambient population with no sim behind it and costs its draw call whether or
>   not anything is happening. Annotated in doc 11 §6 in place, because a
>   deferred line that a new feature merely *resembles* is one wave away from
>   being struck by mistake.
> * **Doc 06 §6 — "pump-truck units", and doc 05 §6's `water_pump_truck`.** The
>   two lists defer the same unit from two sides, which is why
>   `cmd_deploy_pump_truck` is doorless and is **not** a gap. Named here because
>   §17.2's five-row open set is the most-miscounted list in this document and
>   three of its five rows are entries in this table.
> * **`save.assisted` — deferred by RULING rather than by a §6 list, and it is
>   the one item on this page that no `§6` grep will find.** Doc 03 §2.9 asks for
>   difficulty changeable at any time with a `save.assisted` flag; doc 93 §K1
>   ruled the opposite in Wave 11 — *a city is FOUNDED on a difficulty and keeps
>   it for life* — so the flag will never exist and its absence must never be
>   read as an unfinished §2.9. §2.9 is SHIPPED (A91-D-19) **with** that
>   exclusion, and this is the sentence that says so.
>
> **And one distinction worth stating because two different things are called
> "the event log".** Doc 08 §2.10's **event history rings** are a *gap* — the
> single ABSENT row in the tree, a constitution §9 clause, and workstation item 1
> above. Doc 12 §6's **"S13 full event log beyond the away report's top 8"** is
> *deferred*. They are one screen apart and opposite verdicts, and a reader who
> conflates them will either close a real gap on paper or open scope nobody took.

| Doc | Deferred by its own **§6 — MVP Cut** (docs 00 and 93 have no §6; theirs are §7 and §F) |
|---|---|
| **00 Constitution** | premium currency and all monetisation hooks (§7, post-alpha); binary/SQLite saves (post-alpha optimisation) |
| **01 Time & ticks** | weekend curve override tables (mechanism ships, data does not); stadium event templates and venue anchoring; sliceable day-cadence systems; seasonal variation of the daylight curve; per-system RNG-draw accounting tooling |
| **02 Buildings** | archetypes 7/8/10/11/12 (factory, warehouse, hospital, school, stadium); building-specific incidents beyond fire/crime (data-centre cooling, backup-generator dependence); non-square footprints and rotation; land-value / desirability tax modifiers; research unlock preconditions; landmark and premium architecture packs; per-level distinct 3D models |
| **03 Economy** | stadium/event gate revenue, tourism, export contracts; bond issuance and player-chosen debt; **per-district tax rates**; disaster insurance policies; the non-adjacent land premium; all IAP; analytics export beyond the local ring |
| **04 Power grid** | **black start as a player action** *(a counted DEFERRED row, §2.11)*; batteries; solar and wind; underground feeders, flood walls, surge arresters; nuclear, plant L4–5, substation L4–5, transformer L5, **feeder class 3**; `FUEL_SHORTAGE` / `PLANT_FAULT` / `SUB_FLOOD`; **backup generators**; preventive-maintenance jobs; regional imports/exports; tiered `powered_fraction` |
| **05 Water** | **contamination beyond the flag** *(a counted DEFERRED row, §2.10)*; freeze damage & insulation; the `booster` variant, `source: well`, `arterial` mains, facility levels 4–5; `water_pump_truck`, `water_heavy_truck`, `water_flood_response`; **the `water_restrictions` policy and `overhaul_node`**; explicit hydrant placement, per-hydrant flow, player-drawn pressure districts, drought; sewage (never — spec §52) |
| **06 Incidents & dispatch** | **EMS** and every other unit class (ladder, rescue, hazmat, SWAT, mobile transformer, bucket truck, pump truck) and their alarm-level interactions; crew skill and unit damage; fuel as a distinct resource; building-specific incidents; contractor hiring; multi-district alarms and mutual aid; incident chaining across saves; the traffic-accident injury EMS branch. Also **ruled, not deferred**: unpowered stations have no effect on their units (C-52) |
| **07 Weather & director** | `SNOW` / `BLIZZARD` / `FOG` / `EXTREME_COLD` / high-wind states; seasons beyond the four-row multiplier table; multi-cell and per-district weather; weather stations and forecast upgrades; sandbags and storm drains; **the nine pre-costed post-MVP disasters** (flash flood, river flood, blizzard, wildfire, tornado, major blackout, riot, hurricane, earthquake); evacuation; insurance beyond the flat 15 %; hail; Challenge/Crisis scenario exemptions to F9 |
| **08 Offline & persistence** | retention slots D–F; **multiple city slots**; cloud / Play Games saves; emergent risk projection (ships present, `emergent_projection_enabled = false`); the **P4 ambient** notification class (ships present, disabled); report sharing; save export/import; `id_remap` + the Save Repair panel |
| **09 Map, land, starter city** | bridges, islands, satellite and special-zone blocks; **rings 3+ and world growth**; terraforming, land reclamation, block resale; manual district split/merge UI; district specialisations and zoning bonuses; intra-block elevation variation; road classes beyond AVENUE/STREET; demolition of authored starter buildings; a `brownfield` `dev_terrain` key; per-district happiness; explicit migration flows |
| **10 Roads & traffic** | **hierarchical routing** (built, measured and not shipped — RR-27); one-ways, turn restrictions, lane counts; multi-tile arterials; bridges, tunnels, overpasses; `debris` and `police_cordon` closures; evacuation flow; per-district signal timing; pedestrians, transit, parking (spec §52 non-goals); congestion pricing |
| **11 Rendering & performance** | snow / blizzard / fog VFX; `ReflectionProbe` on High (gated on device validation); the remaining three archetypes' detail; the overlay LINE layers; decorative pedestrians; **boot auto-detect of the quality preset** (the table and the governor ship, the detection benchmark does not); cosmetic city themes; headlight cone projection; sub-block ground darkening |
| **12 UI/UX** | the **CONSTRUCTION overlay** and multi-overlay stacking *(its §6 list also named TRAFFIC, which shipped in Wave 5 — struck 2026-08-21 by §20.5)*; the S13 full event log beyond the away report's top 8; dashboard charts beyond raw numbers; colourblind palette variants (A6); **text scale beyond 100/130 %** (A2); screen-reader labels (A15); manual camera pitch, bookmarks, mini-map; radial long-press quick actions; cluster de-clustering animation; haptics beyond `light`; **any second locale** |
| **13 Android** | Google Play Billing and all IAP; ads; cloud save / Play Games Services; achievements and leaderboards; app shortcuts and widgets; deep links beyond the notification payload; a network crash SDK (Sentry is Phase 3); `armeabi-v7a`; Android TV / large-screen optimisation; Play Asset Delivery; **localisation beyond English** |
| **93 Rulings** | multiplayer/social, city trading, seasons/holidays, mod hooks, cloud saves, monetisation (§F) |

**Three entries in that table are worth naming out loud, because they are the
ones most likely to be mistaken for gaps.** **EMS** — doc 06 §6 defers the unit,
which is why `VehicleMesh.ambulance()` is an asset built ahead of a deferred
feature (A91-D-20) and why `tests/test_asset_completeness.gd::DEFERRED_BODIES`
holds `["ambulance"]` rather than failing. **Feeder class 3** — doc 04 §6 defers
the conductor, which is why doc 12's `Power Line` cards read their roster from
`data/grid_components.json` and a class this build does not ship never gets a
card. **Rings 3+** — doc 09 §6 defers world growth, so the 7×7 world is the
world, and nothing that reads "the map is small" is a defect.

**And three of the five doorless verbs are deferred by doc 05's own §6.**
`cmd_set_water_restrictions`, `cmd_overhaul_node` and `cmd_deploy_pump_truck`
are named in that list verbatim (`water_restrictions` policy, `overhaul_node`,
`water_pump_truck`), so under §20.1's rule they are **not gaps**. The honest open
verb count is **two** — `cmd_remove_main` and `cmd_set_water_policy` — and
neither has ever been ranked, because doc 92 §32.6 counted five without checking
them against doc 05 §6. That correction belongs to this pass and is recorded
here rather than in doc 92, because it is a *coverage* correction.

### The one-paragraph answer

> ~~**No, and here is exactly how much.** 169 of 187 documented mechanics are
> shipped, reachable and tested — 90 %, or 91 % of everything the docs have not
> deferred. Six of thirteen design documents are complete. Determinism, balance
> (30 gates), the asset matrix, the event matrix and the accessibility sweep are
> all green, and the suite is green with zero silent tests. **Half of what
> remains is a single document — doc 13 — and it cannot be closed from a
> workstation at all: it needs one `export_presets.cfg` field, a rebuild, and a
> human tapping ALLOW on a phone.** The other half is eight items, seven of them
> under half a day each, that together close the last ABSENT row in the tree,
> three filed defects, one clause of this project's own definition of done, and
> the one screen of sixteen the sweep has never opened. Everything else on
> anyone's list is deferred by the document that owns it, and is enumerated above
> so that nobody has to guess which.~~

**RE-WRITTEN AT THE WAVE-14 MERGE — 2026-08-21 (`bdba0b7`).** *The paragraph
above is struck rather than edited because one of its clauses stopped being true
between the fork it was written on and the merge it was read on, and that is the
single most useful thing this document can demonstrate about itself.*

> **No, and here is exactly how much — 172 of 190 documented mechanics are
> shipped, reachable and tested. 90 %, or 91 % of everything the docs have not
> deferred.** Six of thirteen design documents are complete. Determinism, balance
> (**32** gates), the asset matrix and the event matrix are green **at this
> commit**, and the suite is green with zero silent tests. The accessibility
> sweep is *last known green* — its instrument needs a display, so the standing
> evidence is Wave 13's 990 clean state-sweeps plus a partial re-take of the two
> states Wave 14 added. **Half of what
> remains is a single document — doc 13 — and it still cannot be closed from a
> workstation at all. But it no longer needs a configuration change first:
> Wave 14 put all four permissions on all three export presets and tracked the
> AAR, so what is left is `adb install -r` and a human tapping ALLOW on a
> phone.** The other half is eight items, seven of them under half a day each,
> that together close **the last ABSENT row in the tree**, three filed defects,
> the last of this project's four matrices that is not yet a test, and the one
> screen of sixteen the sweep has never opened. Everything else on anyone's list
> is deferred by the document that owns it — including one item, `save.assisted`,
> that is deferred by a *ruling* (doc 93 §K1) rather than by a §6 list and that
> no grep will find — and all of it is enumerated above so that nobody has to
> guess which.

**The clause that went stale is the one worth reading twice.** The struck
paragraph told its reader that doc 13 *"needs one `export_presets.cfg` field"*.
It did, on the fork it was written on. A sibling branch of the same wave filled
that field, proved with four APKs that the field was never the root cause
anyway (report 98 RR-70), and **nothing rewrote the sentence** — so for one wave
the project's own one-paragraph answer was directing whoever read it to go and
do a piece of work that was already done. That is not a documentation nit: it is
the exact failure mode RR-76 names, arriving through the exact door RR-55 warns
about, in the one paragraph of this document most likely to be quoted without
being re-derived. **Anything in this section that names a command or a field must
be re-run, not re-read, at every merge.**

## 20.5 The marker sweep — TODO / OPEN / IN FLIGHT older than Wave 10

*2026-08-21. Every `### 2.N`-bearing document (00–13) swept for open-state
markers written before Wave 10, checked against what Waves 11–13 verifiably
shipped. **Six markers moved with dated notes — five closed outright and one
halved**; the rest are listed below with why they
stand. The sweep read §6's DEFERRED lists as well as §9's OPEN ones, and the
sixth closure came out of a deferred list — which is the finding worth keeping:
a stale "open" makes work look unfinished, and a stale "deferred" makes finished
work look like scope nobody took.*

**Closed, with the evidence that closed them:**

| Doc | Marker | Closed by |
|---|---|---|
| **10 §9.4 item 5** | *"Auto-repair default: on or off?"* — carried as open since the first draft | **Wave 12's dial.** `cmd_set_auto_repair_policy(threshold, daily_cap)` + `auto_repair_policy()` + two `policy: "roads"` rows in `data/ui.json.settings.rows`. Default stays `0.40 / $25,000` and doc 92 §30.2's control run is byte-identical with the dial in place, while both ends of it move the matrix. §2.13's Wave-12 note had already answered it and §9.4 was never struck |
| **12's "Still open against this doc"** *(in *Phase-1 implementation deltas*, dated Wave 6)* | *"S10's notification rows are still doc 08's and doc 13's to land"* | **Waves 10–12.** Five rows in `data/ui.json.settings.rows`, inside S9's sheet as §2.2 specifies, written through `NotificationRouter.apply_settings` at `game/main.gd:1254`. Four of the five items in that sentence stand and are re-listed with today's date |
| **13 §11.10** | *"Nothing consumes the thermal ladder"* | **Fold session 1 (2026-08-20).** `PerfGovernor` consumed a real `thermal` 0 → 1 and stepped `knob` 0 → 4 on device. The heat half of doc 13 §2.8 is still unproven and says so |
| **13 §11.10** | *"`consume_launch_payload()` has no consumer"* | **HALF.** The warm path is wired — `game/main.gd:129` connects `notification_opened`, `:1473` routes all four payload forms. The cold-start call still has no caller; the bullet is narrowed rather than struck |
| **11 §2.13** | *"Still open after two windows"* — a five-item list | **The third session took `PERFIO`.** The list is superseded by the four-item one at the end of that session and now says so in place |
| **12 §6** | *"Deferred: **TRAFFIC** and CONSTRUCTION overlays"* | **Wave 5.** `data/ui.json.overlay.enabled_modes` carries all six and `OverlayModel` has a `MODE_*` for each; §2.5's row has said so for waves and §6's deferred list was never struck. **A stale DEFERRED entry is worse than a stale OPEN one** — this one would have made a shipped overlay look like scope nobody had taken |

**Left open, and why** — these are the markers a sweep must not close:

* **06 §2.10's heading still says the router wiring is HELD.** The body corrects
  itself four paragraphs down (both Wave-9 rulings landed;
  `sim/city_sim.gd:314` constructs `IncidentSystem` with
  `roads.travel_time_provider()`). The heading is annotated rather than
  rewritten, because its wrong diagnosis is the reason the note is kept.
* **03 §9's `power tariff 93` / `gas fuel 57` — STILL HELD**, pending doc 04's
  RR-10 delivered-MWh restatement. Doc 92 §32.2 confirms both lines are still
  flat placeholders at 21 and 48 game-days on every preset, which is the same
  finding from the other side. **Unverifiable at this fork** — it needs doc 04 to
  publish a number nobody has computed.
* **07 §9 item 8, `elevation_class` per tile or per block.** The flood ships
  per road *tile* and doc 09 carries `elevation_band` per block; the disagreement
  is real, shipped and harmless. Needs a design answer, not a measurement.
* **05 §9 item 9, doc 09's `elev_m(tile)` in metres.** Still open on doc 09's
  side; harmless either way, as the item says.
* **09 §9 item 7, `brownfield` as a request to doc 03.** Six blocks are priced
  as `forest`. Nothing breaks; it is a request across a document boundary and
  doc 03 has not answered it.
* **02 §9 and 06 §9's "Still open — for the overseer" lists**, 10 §9.4 items
  2 / 3 / 4 / 6 / 7 / 10 / 11 / 12, doc 12's *Phase-1 implementation deltas*
  remaining four (the condition histogram, the Response tab's auto-response
  editor, the utility restoration order, and §2.5's coverage discs), and 13
  §11.10's remainder — including its
  **pause-pass policy question**, which is a genuine two-readings decision the
  doc says it does not own. Every one is a **question**, not a stale status: they
  ask for a decision this pass has no evidence to make, and a sweep that closed
  them would be inventing answers. Doc 10 §9.4 item 12 is the one with a
  measurement behind it and it is ranked first in doc 92 §33.4.
* **11 §2.13's device-gated list.** Not stale — **blocked**, which is a different
  status and the sweep must not flatten the two. §20.4's device items 2–5 carry
  each one with the command that closes it.

**Nothing in docs 00–13 carries a literal `TODO` or `TBD`.** `grep -rniE
"TODO|TBD"` over the fourteen documents returns zero hits, which is worth
recording once: this project's open work is in prose and in numbered lists, and
that is why a sweep like this one is a *reading* job rather than a grep job.

## 20.6 The marker sweep, Wave-14 merge — what Waves 13–14 verifiably closed

*2026-08-21, at `bdba0b7`. §20.5 swept markers written **before Wave 10** against
what Waves 11–13 shipped. This is the same job one wave on: every open-state
marker in docs 00–13 **and in this document's own §20.4** that predates Wave 13,
re-read against what Waves 13 and 14 verifiably shipped. **Seven markers closed
— one of them by itself — and one annotated; the rest are listed with why they
stand, and three of those are listed with the command that proves they still
stand**, which §20.5 could not do and is the improvement worth keeping. Every
closure below names the test or the grep that closed it; nothing here is closed
on a changelog.*

**Closed, with the evidence that closed them:**

| Where | Marker | Closed by | The proof |
|---|---|---|---|
| **06 §9 item 9** | *"**Incident cap.** Should there be a hard ceiling on simultaneous active incidents (e.g. 60)…? None added; the damper alone is asymptotically self-limiting but not bounded."* — open since the first draft | **Wave 13's saturation rule**, doc 06 §2.13(b) | `tests/test_balance_gates.gd::test_gate_30_a_decayed_city_roster_is_bounded` runs 200 game-days on `crisis` on purpose. Peak open incidents after the rule: **37**, against the `103 → 89,055`-in-eight-game-hours the question could not see. **Its framing was the one thing it got wrong** — the danger was never city size, it was mean offspring three per incident across eight `spawn_incident` rows. Doc 92 §31; doc 93 §M1; report 98 RR-62; **A91-D-35** |
| **This document, §20.4** | *"it needs one `export_presets.cfg` field, a rebuild, and a human tapping ALLOW"* — the project's most-quotable sentence | **Wave 14, report 98 RR-70** | `grep -n "permissions/" export_presets.cfg` → `post_notifications`, `receive_boot_completed`, `vibrate`, `wake_lock`, all `=true`, on **all three** presets. The field is filled, and RR-70's four-APK matrix showed it was never the root cause: the failing build had a stale AAR *and* an empty preset, and either source alone suffices. **This marker had been telling readers to do work that was already done**, which is why it is §20.6's headline rather than a row |
| **This document, §0** | the doc-13 PARTIAL evidence cell naming the same empty preset | same | struck in place; the re-derived count table carries the true command |
| **This document, §17.1** | *"`cmd_collect_opportunity` … doorless at this fork BY DESIGN … the clause reads 24 of 24 at the merge"* | **the merge itself** | mechanical census: every `func cmd_*` on `sim/city_sim.gd` crossed against every file under `ui/` and `game/` → **25 of 25**, `cmd_collect_opportunity` doored by `ui/build_controller.gd`. The prediction was right about the shape and off by one about the size; the cross-branch deferral gate closed with no ruling needed |
| **This document, §6 and §12** | two tables **counting rows they had never printed** — doc 06 §2.16, doc 12 §2.20 | this pass | the rows are printed now. This is the §28.2/RR-76 fault in its quietest form: not a wrong total, but a total nobody could check against the table under it |
| **`tests/test_event_matrix.gd`** | two `awaiting_consumer` exemption rows — `opportunity_spawned`, `opportunity_expired` — the cross-branch deferral gate doc 93 §Q3 wrote | **the merge**, by the gate's own design | `grep -c 'awaiting_consumer:' tests/test_event_matrix.gd` is **0**: the rows deleted themselves when `game/render/street_life_view.gd` arrived, exactly as §Q3 requires — *"a deferred consumer has to be a commitment, which means naming the wave that owes it and the file that will do the consuming"*, and the test asserts that shape (`:505`). **This is the only marker in the sweep that closed without a human touching it, and it is the model for the rest**: the register is a test, so the exemption could not outlive the branch it was written for |
| **12 §6** *(re-confirmed)* | *"Deferred: TRAFFIC and CONSTRUCTION overlays"* — TRAFFIC struck by §20.5 | Wave 5, struck 2026-08-21 | re-checked at this merge: `data/ui.json.overlay.enabled_modes` still carries all six. No regression |

**Annotated rather than closed — one, and it is the opposite failure:**

* **11 §6 — "decorative pedestrians".** Nothing closed this and nothing should,
  but doc 11 §2.17 now puts characters on the footway and the next sweeper will
  reasonably reach for the strike-through. A note in place says why they are
  different things: §2.17 draws **one body per live `sim/street` opportunity and
  zero when the roster is empty** (RR-83's `node.visible = n > 0`); a decorative
  pedestrian is ambient population with no sim behind it and costs its draw call
  regardless. **§20.5 found that a stale DEFERRED makes finished work look
  untaken; this is the mirror — a deferred line a new feature merely resembles is
  one wave from being closed by mistake, and the cheap fix is a sentence, now.**

**Left open, and why — with a command where one exists:**

* **10 §9.4 item 12 — "the auto-repair quote passes no `M_repair`."** **Verified
  still open**, and this is the item doc 92 §33.4 ranked first: `sim/city_sim.gd:407`
  wires `roads.repair_quote` as `econ_curves.repair_cost_road(road_class,
  damage_fraction)` while `cost_curves.gd:281` declares
  `repair_cost_road(road_class, damage_fraction, m_repair := 1.0)` — the third
  argument is never passed, so C-16's difficulty multiplier sits at its default
  in the quote the auto-repair policy budgets against. One argument, and a
  balance question about whether the *quote* should carry the knob the *charge*
  already carries. Not swept closed, because nothing closed it.
* **13 §11.10 — `consume_launch_payload()` has no cold-start caller.** Still
  **HALF**, as §20.5 left it and as doc 13 restates: the warm path is
  `game/main.gd:129` + `:1473`; `grep -rn consume_launch_payload game/` returns
  **three hits and all three are inside the wrapper itself** —
  `game/android_native.gd:304` declares it, `:305` probes the plugin for it and
  `:307` forwards to it — so nothing in the shell calls it. One call at the end
  of boot, unchanged in size.
* **13 §11.10 — the on-device verification list.** **Blocked, not stale.**
  `dumpsys alarm | grep slacumcity` has still never been read. §20.4 device
  item 1 carries it.
* **13 §11.10 — the pause-pass policy question.** A genuine two-readings
  decision the doc says it does not own. A sweep that closed it would be
  inventing an answer.
* **03 §9 — `power tariff 93` / `gas fuel 57`.** Still held pending doc 04's
  RR-10 delivered-MWh restatement. **Unverifiable at this fork**, exactly as
  §20.5 recorded; doc 92 §32.2 confirms both lines are still flat placeholders.
* **06 §9 items 7 and 8** (fatalities; whether `traffic_accident` needs EMS),
  **07 §9 item 8** (`elevation_class` per tile or per block), **05 §9 item 9**
  (`elev_m(tile)` in metres), **09 §9 item 7** (`brownfield` as a request to doc
  03), **10 §9.4 items 2 / 3 / 4 / 6 / 7 / 10 / 11**, **02 §9 and 06 §9's
  remaining "for the overseer" lists**, and **doc 12's *Phase-1 implementation
  deltas* four** (the condition histogram, the Response tab's auto-response
  editor, the utility restoration order, §2.5's coverage discs). Every one is a
  **question**, not a stale status. §20.5's rule stands verbatim: *they ask for a
  decision this pass has no evidence to make, and a sweep that closed them would
  be inventing answers.*
* **06 §2.10's heading still says the router wiring is HELD.** Already annotated
  in place by an earlier wave and re-checked here; the body corrects itself four
  paragraphs down and the heading is kept because its wrong diagnosis is the
  reason the note exists.

**And the sweep leaves an instrument behind, which §20.5 did not.**
`tools/check_doc_refs.py` is this pass's validator, shipped rather than
described: it resolves every `RR-nn`, `A91-D-nn`, `92 §<n>.<m>`, `93 §<letter>`
and `98 §<n>` in `docs/ sim/ ui/ game/ tests/ tools/ data/ .github/` against the
header that defines it, **and refuses any id assigned twice**. At this merge:
**2,517 references, all resolving, no id assigned twice, exit 0.** It found the
nine bad targets and the three colliding ids this pass fixed, it fails closed
on an injected bad id, and it would have caught every one of them on the day it
was filed. It is a marker sweep the next wave does not have to *read* — §20.4
workstation item 6 has it as one more CI line.

**The literal-marker grep, re-run.** `grep -rniE "TODO|TBD|FIXME"` over docs
00–13 returns **one** hit and it is prose — doc 10 §2.15's *"the fields were not
stubs and they were not TODOs"* — so the §20.5 finding stands: **zero literal
markers in the design documents.** The same grep over `sim/ ui/ game/ tools/
tests/` returns **zero**. Which restates §20.5's real point one wave on: this
project's open work lives in numbered prose, so a marker sweep is a reading job,
and the only defence against a reading job going stale is doing it every merge
and dating what it found.

---

## WAVE 17 — the two defects the cold-launch branch closed (2026-09-01)

Filed in §14.5's `A91-D-nn` sequence and closed in the same wave, with the
evidence each one is closed by. Report 98 §48 carries the rulings; doc 93 §AG
carries the mechanics argument.

| Id | Defect | Sev | Status | Evidence |
|---|---|---|---|---|
| **A91-D-85** | **Core Design Rule 2 is void on a cold launch.** The only `CatchUpPlanner` call in the shell was inside `Main._on_app_resumed`, reachable only from `AndroidLifecycle.resumed`, i.e. only from `NOTIFICATION_APPLICATION_RESUMED` — which a *dead process never receives*. `AndroidLifecycle._paused_wall` was an in-memory member, `-1.0` at every boot and never seeded from disk, and `manifest.active.real_unix` / `manifest.max_seen_unix` were written by two files and read by none. So after a process death, a swipe-away, a low-memory kill, or the title door's CONTINUE — the *default* player launch (doc 12 §2.19) — the city resumed **frozen at the pause**: no catch-up, no veil, no away report. | **P0** | ✅ **CLOSED 2026-09-01** | Doc 13 §3.2's `save.android.last_pause` is written by `game/android/lifecycle_stamp.gd`; `AndroidLifecycle.arm_cold_resume()` seeds a synthetic pause from the loaded generation and `pump_resume()` hands it to the **same** `resumed` signal. `tests/test_cold_launch_catchup.gd` — 10 tests, and the load-bearing one compares a cold-loaded city against an in-process-resumed one on `state_hash()` over the same absence. Report 98 §48 RR-132. |
| **A91-D-86** | **A second absence on top of an unfinished catch-up was drained synchronously, and the pause between them ate the away report's 'before'.** `_on_app_resumed` answered an in-flight cursor with `_catchup_cursor.run()` — up to 720 coarse steps in one frame, `720 × 165 ms = 119 s` of blocked main thread on the benchmark city, an ANR twenty-four times over. `_on_paused` meanwhile committed a mid-absence city and overwrote `_before_snapshot` with it, so the report diffed the city against a half-advanced version of itself; and the unspent plan was lost outright if the process then died. Separately, doc 08 §2.12's NORMATIVE `max_coarse_hours` rule was implemented nowhere (`grep -rn max_coarse_hours sim/ game/ data/` → 0 hits) and `ui/away_model.gd`'s `capped_text` had never been reachable, because the shell's report dictionary carried no `capped` key. | **P1** | ✅ **CLOSED 2026-09-01** | The second absence is queued (`AndroidLifecycle.defer_absence`), the pause is tagged `pause_mid_catchup` and carries the unspent segments in `last_pause.unfinished`, and `CatchUpPlanner.plan_after` puts them back in front of the next plan. `max_coarse_hours` is derived, shipped in `data/persistence.json` and applied in `plan()`; both capped surfaces now quote the cap that was applied. `tests/test_catchup_resume.gd` (13) + `tests/test_catchup_clamp.gd` (15). Report 98 §48 RR-133 / RR-134, doc 93 §AG. |
