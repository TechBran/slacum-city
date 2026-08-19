#!/usr/bin/env python3
"""Turn `tools/playtest.gd` run files into the markdown tables of doc 92.

The harness owns the measuring; this owns the presenting. Keeping the two apart
means a re-run per merge is two commands and a diff, and that no number in
`docs/design/92-balance-report.md` is typed by hand:

    ~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" \\
        -s res://tools/playtest.gd -- --days=14 --mode=fine
    python3 tools/playtest_report.py build/playtest --mode fine

Options:
    <dir>              directory of run JSONs        (default build/playtest)
    --mode fine|coarse which runs to read            (default fine)
    --days N           filter to a horizon           (default: all present)
    --section all|headline|daily|events|reasons|compare
"""

from __future__ import annotations

import argparse
import json
import pathlib
import statistics
import sys

# Report order, not alphabetical: control first, then the three players.
STRATEGY_ORDER = ["do_nothing", "greedy_growth", "infrastructure_first", "balanced"]

# Doc 03 §2.12 anchors the harness is a regression suite for.
DOC03_FOUNDING_GROSS = 839.349412
DOC03_FOUNDING_EXPENSE = 520.576566
DOC03_FOUNDING_NET = 318.772846
DOC03_STARTER_BASE_TAX = 686.0


def load_runs(directory: pathlib.Path, mode: str, days: int | None) -> list[dict]:
    runs = []
    for path in sorted(directory.glob("*.json")):
        with path.open() as handle:
            doc = json.load(handle)
        if doc.get("schema_version") != 1:
            print(f"skipping {path.name}: schema_version "
                  f"{doc.get('schema_version')} != 1", file=sys.stderr)
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


def headline(runs: list[dict]) -> str:
    lines = [
        "| strategy | seed | treasury d14 | peak | net $/gh | pop | happiness "
        "| stability | level | dark % | placed | upgraded |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for doc in runs:
        s = doc["summary"]
        lines.append(
            f"| {doc['run']['strategy']} | {doc['run']['seed']} "
            f"| {money(s['treasury_end'])} | {money(s['treasury_max'])} "
            f"| {s['net_mean_per_hour']:,.0f} | {s['population_end']:,} "
            f"| {s['happiness_end']:.1f} | {s['stability_end']:.4f} "
            f"| {s['city_level_end']} | {100 * s['unserved_share']:.2f} "
            f"| {s['placed']} | {s['upgraded']} |")
    lines.append("")
    lines.append("| strategy (mean of seeds) | treasury d14 | net $/gh | pop "
                 "| happiness | stability | dark % | placed | upgraded |")
    lines.append("|---|---|---|---|---|---|---|---|---|")
    for strategy, docs in by_strategy(runs).items():
        summaries = [d["summary"] for d in docs]
        lines.append(
            f"| **{strategy}** | {money(mean(s['treasury_end'] for s in summaries))} "
            f"| {mean(s['net_mean_per_hour'] for s in summaries):,.0f} "
            f"| {mean(s['population_end'] for s in summaries):,.0f} "
            f"| {mean(s['happiness_end'] for s in summaries):.1f} "
            f"| {mean(s['stability_end'] for s in summaries):.4f} "
            f"| {100 * mean(s['unserved_share'] for s in summaries):.2f} "
            f"| {mean(s['placed'] for s in summaries):.0f} "
            f"| {mean(s['upgraded'] for s in summaries):.0f} |")
    return "\n".join(lines)


def daily(runs: list[dict], field: str = "treasury") -> str:
    grouped = by_strategy(runs)
    strategies = list(grouped)
    lines = ["| day | " + " | ".join(strategies) + " |",
             "|---" * (len(strategies) + 1) + "|"]
    days = [row["day"] for row in runs[0]["summary"]["day_rows"]]
    for day in days:
        cells = []
        for strategy in strategies:
            values = []
            for doc in grouped[strategy]:
                for row in doc["summary"]["day_rows"]:
                    if row["day"] == day:
                        values.append(row[field])
            value = mean(values)
            cells.append(money(value) if field == "treasury" else f"{value:,.2f}")
        lines.append(f"| {day} | " + " | ".join(cells) + " |")
    return "\n".join(lines)


def events(runs: list[dict]) -> str:
    watch = ["PowerComponentFailed", "BuildingPowerChanged:DARK", "BlockDarkChanged",
             "city_level_changed", "building_completed", "credit_line_engaged",
             "deferred_liability_accrued"]
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
    for key in shared:
        a, b = fine[key]["summary"], coarse[key]["summary"]
        value_a = a["treasury_end"] + a["construction_spend"]
        value_b = b["treasury_end"] + b["construction_spend"]
        edge = (value_b - value_a) / max(1.0, abs(value_a))
        lines.append(
            f"| {key[0]} | {key[1]} | {money(value_a)} | {money(value_b)} "
            f"| {100 * edge:+.1f}% "
            f"| {a['population_end']:,} / {b['population_end']:,} "
            f"| {a['stability_end']:.4f} / {b['stability_end']:.4f} "
            f"| {100 * a['unserved_share']:.2f} / {100 * b['unserved_share']:.2f} |")
    return "\n".join(lines)


def anchors(runs: list[dict]) -> str:
    """The doc 03 §2.12 regression line, measured."""
    control = [d for d in runs if d["run"]["strategy"] == "do_nothing"]
    if not control:
        return "_no do_nothing run to anchor against_"
    first = control[0]["samples"][1]
    return "\n".join([
        "| doc 03 §2.12 founding line | published | measured (hour 1, do_nothing) | drift |",
        "|---|---|---|---|",
        f"| gross revenue $/gh | {DOC03_FOUNDING_GROSS:,.3f} | {first['revenue']:,.3f} "
        f"| {100 * (first['revenue'] / DOC03_FOUNDING_GROSS - 1):+.2f}% |",
        f"| expense $/gh | {DOC03_FOUNDING_EXPENSE:,.3f} | {first['expenses']:,.3f} "
        f"| {100 * (first['expenses'] / DOC03_FOUNDING_EXPENSE - 1):+.2f}% |",
        f"| net $/gh | {DOC03_FOUNDING_NET:,.3f} | {first['net']:,.3f} "
        f"| {100 * (first['net'] / DOC03_FOUNDING_NET - 1):+.2f}% |",
    ])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("directory", nargs="?", default="build/playtest")
    parser.add_argument("--mode", default="fine", choices=["fine", "coarse"])
    parser.add_argument("--days", type=int, default=None)
    parser.add_argument("--section", default="all",
                        choices=["all", "headline", "daily", "events", "reasons",
                                 "compare", "anchors"])
    args = parser.parse_args()

    directory = pathlib.Path(args.directory)
    if not directory.is_dir():
        print(f"no such directory: {directory}", file=sys.stderr)
        return 2
    runs = load_runs(directory, args.mode, args.days)
    if not runs:
        print(f"no {args.mode} runs in {directory}", file=sys.stderr)
        return 1

    sections = {
        "headline": lambda: headline(runs),
        "daily": lambda: daily(runs),
        "events": lambda: events(runs),
        "reasons": lambda: reasons(runs),
        "compare": lambda: compare(directory, args.days),
        "anchors": lambda: anchors(runs),
    }
    wanted = list(sections) if args.section == "all" else [args.section]
    for name in wanted:
        print(f"\n### {name}\n")
        print(sections[name]())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
