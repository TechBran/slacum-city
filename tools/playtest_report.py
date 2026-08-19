#!/usr/bin/env python3
"""Turn `tools/playtest.gd` run files into the markdown tables of doc 92.

The harness owns the measuring; this owns the presenting. Keeping the two apart
means a re-run per merge is two commands and a diff, and that no number in
`docs/design/92-balance-report.md` is typed by hand:

    ~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \\
        -s res://tools/playtest.gd -- --days=21 --mode=coarse
    python3 tools/playtest_report.py build/playtest --mode coarse

Options:
    <dir>              directory of run JSONs        (default build/playtest)
    --mode fine|coarse which runs to read            (default coarse)
    --days N           filter to a horizon           (default: all present)
    --section all|headline|daily|net|maintenance|verbs|events|reasons
               |compare|anchors
"""

from __future__ import annotations

import argparse
import json
import pathlib
import statistics
import sys

SCHEMA_VERSION = 2

# Report order, not alphabetical: control, the three play styles, then the two
# single-variable variants of `balanced`.
STRATEGY_ORDER = [
    "do_nothing", "greedy_growth", "infrastructure_first", "balanced",
    "tax_squeezer", "disaster_neglect",
]

# Doc 03 §2.12's published founding ledger, and doc 93 §E2's AS-INTEGRATED
# replacement for it. §E2 is binding until docs 03/09 refresh their worked
# examples, so both are printed and the drift is measured against §E2.
DOC03_FOUNDING_GROSS = 839.349412
DOC03_FOUNDING_EXPENSE = 520.576566
DOC03_FOUNDING_NET = 318.772846
DOC93_E2_FOUNDING_NET = 345.0          # "≈ +$345/gh"
DOC93_E2_FOUNDING_DAY_NET = 8350.0     # "≈ +$8,350"
DOC03_STARTER_BASE_TAX = 686.0


def load_runs(directory: pathlib.Path, mode: str, days: int | None) -> list[dict]:
    runs = []
    for path in sorted(directory.glob("*.json")):
        with path.open() as handle:
            doc = json.load(handle)
        if doc.get("schema_version") != SCHEMA_VERSION:
            print(f"skipping {path.name}: schema_version "
                  f"{doc.get('schema_version')} != {SCHEMA_VERSION}", file=sys.stderr)
            continue
        if doc["harness"]["mode"] != mode:
            continue
        if days is not None and doc["harness"]["days"] != days:
            continue
        doc["_path"] = path
        runs.append(doc)
    runs.sort(key=lambda d: (strategy_rank(d["run"]["strategy"]), d["run"]["seed"]))
    return runs


def strategy_rank(strategy: str) -> int:
    return STRATEGY_ORDER.index(strategy) if strategy in STRATEGY_ORDER else 99


def by_strategy(runs: list[dict]) -> dict[str, list[dict]]:
    grouped: dict[str, list[dict]] = {}
    for doc in runs:
        grouped.setdefault(doc["run"]["strategy"], []).append(doc)
    return dict(sorted(grouped.items(), key=lambda kv: strategy_rank(kv[0])))


def money(value: float) -> str:
    return f"${value:,.0f}"


def mean(values) -> float:
    values = list(values)
    return statistics.fmean(values) if values else 0.0


def horizon(runs: list[dict]) -> int:
    return runs[0]["harness"]["days"]


def headline(runs: list[dict]) -> str:
    d = horizon(runs)
    lines = [
        f"| strategy | seed | treasury d{d} | value created | net $/gh | pop "
        "| happiness | stability | level | dark % | placed | upgraded |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for doc in runs:
        s = doc["summary"]
        lines.append(
            f"| {doc['run']['strategy']} | {doc['run']['seed']} "
            f"| {money(s['treasury_end'])} | {money(s['value_created'])} "
            f"| {s['net_mean_per_hour']:,.0f} | {s['population_end']:,} "
            f"| {s['happiness_end']:.1f} | {s['stability_end']:.4f} "
            f"| {s['city_level_end']} | {100 * s['unserved_share']:.2f} "
            f"| {s['placed']} | {s['upgraded']} |")
    lines.append("")
    lines.append(f"| strategy (mean of seeds) | treasury d{d} | value created "
                 "| net $/gh | pop | happiness | stability | dark % | placed "
                 "| upgraded |")
    lines.append("|---|---|---|---|---|---|---|---|---|---|")
    for strategy, docs in by_strategy(runs).items():
        s = [d["summary"] for d in docs]
        lines.append(
            f"| **{strategy}** | {money(mean(r['treasury_end'] for r in s))} "
            f"| {money(mean(r['value_created'] for r in s))} "
            f"| {mean(r['net_mean_per_hour'] for r in s):,.0f} "
            f"| {mean(r['population_end'] for r in s):,.0f} "
            f"| {mean(r['happiness_end'] for r in s):.1f} "
            f"| {mean(r['stability_end'] for r in s):.4f} "
            f"| {100 * mean(r['unserved_share'] for r in s):.2f} "
            f"| {mean(r['placed'] for r in s):.0f} "
            f"| {mean(r['upgraded'] for r in s):.0f} |")
    return "\n".join(lines)


def verbs(runs: list[dict]) -> str:
    """Which doc 93 §B verb each agent actually reached for, and what it cost."""
    lines = ["| strategy (mean of seeds) | transformers | grid $ | repairs "
             "| repair $ | blocks | land $ | demolitions | priority sets "
             "| tax moves | `E_UNSERVED` walls |",
             "|---|---|---|---|---|---|---|---|---|---|---|"]
    for strategy, docs in by_strategy(runs).items():
        s = [d["summary"] for d in docs]
        lines.append(
            f"| {strategy} | {mean(r['grid_placed'] for r in s):.1f} "
            f"| {money(mean(r['grid_spend'] for r in s))} "
            f"| {mean(r['repaired'] for r in s):.1f} "
            f"| {money(mean(r['repair_spend'] for r in s))} "
            f"| {mean(r['blocks_bought'] for r in s):.1f} "
            f"| {money(mean(r['land_spend'] for r in s))} "
            f"| {mean(r['demolished'] for r in s):.1f} "
            f"| {mean(r['priority_sets'] for r in s):.1f} "
            f"| {mean(r['tax_changes'] for r in s):.1f} "
            f"| {mean(r['unserved_walls'] for r in s):.1f} |")
    return "\n".join(lines)


def maintenance(runs: list[dict]) -> str:
    """The neglect channel: does anything actually wear out, and does it bite?"""
    lines = ["| strategy (mean of seeds) | min condition | mean condition end "
             "| damaged end | destroyed end | failed grid components end "
             "| open incidents (mean/hour) | dark % | stability end |",
             "|---|---|---|---|---|---|---|---|---|"]
    for strategy, docs in by_strategy(runs).items():
        s = [d["summary"] for d in docs]
        lines.append(
            f"| {strategy} | {mean(r['min_condition'] for r in s):.3f} "
            f"| {mean(r['mean_condition_end'] for r in s):.3f} "
            f"| {mean(r['damaged_end'] for r in s):.1f} "
            f"| {mean(r['destroyed_end'] for r in s):.1f} "
            f"| {mean(r['failed_components_end'] for r in s):.1f} "
            f"| {mean(r['open_incidents_mean'] for r in s):.2f} "
            f"| {100 * mean(r['unserved_share'] for r in s):.2f} "
            f"| {mean(r['stability_end'] for r in s):.4f} |")
    return "\n".join(lines)


def daily(runs: list[dict], field: str = "treasury", every: int = 1) -> str:
    grouped = by_strategy(runs)
    strategies = list(grouped)
    lines = ["| day | " + " | ".join(strategies) + " |",
             "|---" * (len(strategies) + 1) + "|"]
    days = [row["day"] for row in runs[0]["summary"]["day_rows"]]
    for day in days:
        if day % every != 0 and day != days[-1]:
            continue
        cells = []
        for strategy in strategies:
            values = []
            for doc in grouped[strategy]:
                for row in doc["summary"]["day_rows"]:
                    if row["day"] == day:
                        values.append(row[field])
            value = mean(values)
            if field in ("treasury",):
                cells.append(money(value))
            elif field in ("population", "buildings", "blocks_owned",
                           "damaged_buildings", "failed_components"):
                cells.append(f"{value:,.0f}")
            else:
                cells.append(f"{value:,.2f}")
        lines.append(f"| {day} | " + " | ".join(cells) + " |")
    return "\n".join(lines)


def events(runs: list[dict]) -> str:
    watch = ["PowerComponentFailed", "BuildingPowerChanged:DARK", "BlockDarkChanged",
             "incident_created", "incident_resolved", "incident_failed",
             "power_restored_by_repair", "city_level_changed", "building_completed",
             "credit_line_engaged", "deferred_liability_accrued"]
    lines = ["| strategy | " + " | ".join(watch) + " |",
             "|---" * (len(watch) + 1) + "|"]
    for strategy, docs in by_strategy(runs).items():
        cells = [f"{mean(d['events'].get(key, 0) for d in docs):.1f}" for key in watch]
        lines.append(f"| {strategy} | " + " | ".join(cells) + " |")
    return "\n".join(lines)


def reasons(runs: list[dict]) -> str:
    lines = ["| strategy | command results (mean per run) |", "|---|---|"]
    for strategy, docs in by_strategy(runs).items():
        totals: dict[str, float] = {}
        for doc in docs:
            for code, count in doc["summary"]["reason_codes"].items():
                totals[code] = totals.get(code, 0.0) + count / len(docs)
        rendered = ", ".join(f"`{code}` {value:.0f}"
                             for code, value in sorted(totals.items())) or "—"
        lines.append(f"| {strategy} | {rendered} |")
    return "\n".join(lines)


def compare(directory: pathlib.Path, days: int | None) -> str:
    """Online (fine) against offline catch-up (coarse), same seed and strategy."""
    fine = {(d["run"]["strategy"], d["run"]["seed"]): d
            for d in load_runs(directory, "fine", days)}
    coarse = {(d["run"]["strategy"], d["run"]["seed"]): d
              for d in load_runs(directory, "coarse", days)}
    shared = sorted(set(fine) & set(coarse), key=lambda k: (strategy_rank(k[0]), k[1]))
    if not shared:
        return "_no fine/coarse pair present in this directory_"
    # Spend-everything agents pin the treasury near zero, so a percentage on
    # the balance is noise. `value` = cash + everything the agent turned into
    # buildings, which is the comparable quantity across both paths.
    lines = ["| strategy | seed | value online | value offline | offline edge "
             "| pop on/off | stability on/off | dark % on/off |",
             "|---|---|---|---|---|---|---|---|"]
    edges = []
    for key in shared:
        a, b = fine[key]["summary"], coarse[key]["summary"]
        value_a, value_b = a["value_created"], b["value_created"]
        edge = (value_b - value_a) / max(1.0, abs(value_a))
        edges.append(edge)
        lines.append(
            f"| {key[0]} | {key[1]} | {money(value_a)} | {money(value_b)} "
            f"| {100 * edge:+.1f}% "
            f"| {a['population_end']:,} / {b['population_end']:,} "
            f"| {a['stability_end']:.4f} / {b['stability_end']:.4f} "
            f"| {100 * a['unserved_share']:.2f} / {100 * b['unserved_share']:.2f} |")
    lines.append(f"| **all {len(edges)} pairs** | | | | **mean "
                 f"{100 * mean(edges):+.1f}%, median "
                 f"{100 * statistics.median(edges):+.1f}%, offline ahead in "
                 f"{sum(1 for e in edges if e > 0)} of {len(edges)}** | | | |")
    return "\n".join(lines)


def anchors(runs: list[dict]) -> str:
    """The founding ledger, against doc 03 §2.12 and doc 93 §E2's replacement."""
    control = [d for d in runs if d["run"]["strategy"] == "do_nothing"]
    if not control:
        return "_no do_nothing run to anchor against_"
    first = control[0]["samples"][1]
    day_one = control[0]["summary"]["day_rows"][0]
    day_net = sum(s["net"] for s in control[0]["samples"][1:25])
    return "\n".join([
        "| founding line | doc 03 §2.12 (stub-era) | doc 93 §E2 (as-integrated) "
        "| measured (hour 1, do_nothing) | drift vs §E2 |",
        "|---|---|---|---|---|",
        f"| gross revenue $/gh | {DOC03_FOUNDING_GROSS:,.3f} | — "
        f"| {first['revenue']:,.3f} | — |",
        f"| expense $/gh | {DOC03_FOUNDING_EXPENSE:,.3f} | — "
        f"| {first['expenses']:,.3f} | — |",
        f"| net $/gh | {DOC03_FOUNDING_NET:,.3f} | ≈ {DOC93_E2_FOUNDING_NET:,.0f} "
        f"| {first['net']:,.3f} "
        f"| {100 * (first['net'] / DOC93_E2_FOUNDING_NET - 1):+.2f}% |",
        f"| first game-day net | ≈ 7,650 | ≈ {DOC93_E2_FOUNDING_DAY_NET:,.0f} "
        f"| {day_net:,.0f} "
        f"| {100 * (day_net / DOC93_E2_FOUNDING_DAY_NET - 1):+.2f}% |",
        f"| day-1 mean net $/gh | — | — | {day_one['net_mean_per_hour']:,.3f} | — |",
    ])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("directory", nargs="?", default="build/playtest")
    parser.add_argument("--mode", default="coarse", choices=["fine", "coarse"])
    parser.add_argument("--days", type=int, default=None)
    parser.add_argument("--every", type=int, default=1,
                        help="daily tables: print every Nth game-day")
    parser.add_argument("--section", default="all",
                        choices=["all", "headline", "daily", "net", "population",
                                 "blackout", "maintenance", "verbs", "events",
                                 "reasons", "compare", "anchors"])
    args = parser.parse_args()

    directory = pathlib.Path(args.directory)
    if not directory.is_dir():
        print(f"no such directory: {directory}", file=sys.stderr)
        return 2
    runs = load_runs(directory, args.mode, args.days)
    if not runs and args.section != "compare":
        print(f"no {args.mode} runs in {directory}", file=sys.stderr)
        return 1

    sections = {
        "headline": lambda: headline(runs),
        "anchors": lambda: anchors(runs),
        "daily": lambda: daily(runs, "treasury", args.every),
        "net": lambda: daily(runs, "net_mean_per_hour", args.every),
        "population": lambda: daily(runs, "population", args.every),
        "blackout": lambda: daily(runs, "blackout_minutes", args.every),
        "maintenance": lambda: maintenance(runs),
        "verbs": lambda: verbs(runs),
        "events": lambda: events(runs),
        "reasons": lambda: reasons(runs),
        "compare": lambda: compare(directory, args.days),
    }
    wanted = list(sections) if args.section == "all" else [args.section]
    for name in wanted:
        print(f"\n### {name}\n")
        print(sections[name]())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
