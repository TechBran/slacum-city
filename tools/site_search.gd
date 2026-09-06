extends RefCounted
## **Where a building fits — asked the way `cmd_place_building` answers it**
## (Wave 29 fix, doc 02 §2.3a, RR-239).
##
## Under the lot rule a placement reserves the footprint of the building's FINAL
## form, so a store asks for 2×2 on the day it is founded and a plant for 4×4.
## Every scripted agent and every measuring instrument in the project sized its
## own site search off `catalog.stats(archetype, 1).footprint` — the ground the
## building covers on its FIRST day — and then handed that site to a command that
## reserves more. That search finds sites the command refuses, and the refusal
## does not read as a bug: it reads as `E_FOOTPRINT`, i.e. *"the city ran out of
## room on day 31"*, in a soak's verb mix or a lag measurement's numbers.
##
## `tools/playtest.gd` was fixed in place when the rule landed. Four more copies
## were not — `tools/qa_soak.gd`, `tools/measure_population_lag.gd`,
## `tools/ui_preview.gd` and `tests/test_goals_system.gd` — which is five copies
## of one sentence and therefore five chances to fix it four times. They all call
## here now.
##
## **Instruments only.** This file lives in `tools/`, which `export_presets.cfg`
## excludes from every build, so nothing under `game/` or `ui/` may preload it —
## `game/main.gd`'s dev-only `_place_demo` asks `sim.lot_for(archetype)` inline
## for exactly that reason. Nothing here advances a sim or writes to one.


## The ground `cmd_place_building` will RESERVE for this archetype: its lot, not
## its first day's footprint. One line, and it is the whole of the defect above.
static func reservation(sim: CitySim, archetype: String) -> Vector2i:
	return sim.lot_for(archetype)


## The first buildable, vacant, power-serviceable origin inside the core, scanned
## row-major from `lo` to `hi` — the scan `tests/test_city_commands.gd` has used
## since Wave 3, now sized to the reservation.
##
## Row-major from a fixed corner rather than "somewhere sensible", because two
## runs of the same seed have to place in the same order; `(-1, -1)` when the
## core has no site, which every caller already tests for.
static func serviceable_site(sim: CitySim, archetype: String,
		lo: int = 32, hi: int = 80) -> Vector2i:
	var size := reservation(sim, archetype)
	for z in range(lo, hi):
		for x in range(lo, hi):
			var origin := Vector2i(x, z)
			if sim.world.grid.can_place(origin, size) and sim.grid.would_serve(origin):
				return origin
	return Vector2i(-1, -1)
