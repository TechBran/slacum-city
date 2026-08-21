#!/usr/bin/env python3
"""Cross-reference validator for the four ledger id spaces (report 98 RR-85(d)).

    python3 tools/check_doc_refs.py            # from the repo root
    python3 tools/check_doc_refs.py --verbose  # also print the per-space totals

Walks `docs/ sim/ ui/ game/ tests/ tools/ data/ .github/` and checks that every

    RR-nn                  a `### RR-nn` header in doc 98
    A91-D-nn               a defect row in doc 91 §14.5
    "92 §" <n>[.<m>...]    a `## `/`### `/`#### ` header in doc 92
    "93 §" <letter><n>     a `## `/`### ` header in doc 93
    "98 §" <n>             a `## ` header in doc 98

...and that no header id is assigned twice. Exit 0 when everything resolves.

**Why this exists.** The Wave-14 merge audit found seven bad pointers in a tree
where every branch had obeyed RR-55 and RR-76: five dangling, and — worse — two
that resolved to the *wrong* section, because the money pass was drafted as doc
92 §35 and merged as §36. A dangling pointer is a broken link and a reader
notices. A pointer that resolves to the wrong section is a lie with a footnote,
and nothing but a validator will ever find it.

It also catches the fault under those: a per-line renumbering `sed` moves the
`### ` ruling ids and leaves the `## ` section header behind. Six of doc 93's
section letters and two of doc 98's section numbers were wrong that way, in a
tree whose every cross-reference still resolved.

No dependencies. Reads only; changes nothing.
"""
from __future__ import annotations

import os
import re
import sys

TREES = ("docs", "sim", "ui", "game", "tests", "tools", "data", ".github")
EXT = (".md", ".gd", ".json", ".sh", ".py", ".cfg", ".yml", ".yaml")
SKIP_DIRS = {".git", ".godot", "build", "device_results", "__pycache__"}

DOC91 = "docs/design/91-completeness-audit.md"
DOC92 = "docs/design/92-balance-report.md"
DOC93 = "docs/design/93-mechanics-audit.md"
DOC98 = "docs/design/98-consistency-report.md"

# Ids that are deliberately not headers of their own, with the reason.
# Keep this list SHORT and keep the reason in it: an allow-list without a
# reason is how the thing it guards comes back.
EXEMPT = {
    ("RR", "10a"): "doc 95 sub-labels the two halves of RR-10 (verif F-2/F-3)",
    ("RR", "10b"): "doc 95 sub-labels the two halves of RR-10 (verif F-2/F-3)",
    ("A91-D", "01"): "quoted in §14.5's own prose as the id that was REJECTED",
}


def repo_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(root: str, rel: str) -> str:
    with open(os.path.join(root, rel), encoding="utf-8") as handle:
        return handle.read()


def walk(root: str):
    for tree in TREES:
        base = os.path.join(root, tree)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in filenames:
                if not name.endswith(EXT):
                    continue
                path = os.path.join(dirpath, name)
                try:
                    with open(path, encoding="utf-8", errors="ignore") as handle:
                        yield os.path.relpath(path, root), handle.read()
                except OSError:
                    continue


def duplicates(pattern: str, text: str) -> list[str]:
    seen: dict[str, int] = {}
    for match in re.finditer(pattern, text, re.M):
        seen[match.group(1)] = seen.get(match.group(1), 0) + 1
    return sorted(k for k, v in seen.items() if v > 1)


def main() -> int:
    verbose = "--verbose" in sys.argv or "-v" in sys.argv
    root = repo_root()

    d91, d92, d93, d98 = (read(root, p) for p in (DOC91, DOC92, DOC93, DOC98))

    targets = {
        "RR": set(re.findall(r"^### (RR-[0-9]+[a-z]?)", d98, re.M)),
        "A91-D": set(re.findall(r"^\| \*\*(A91-D-[0-9]+)\*\*", d91, re.M)),
        "92": set(re.findall(r"^#{2,4} ([0-9]+(?:\.[0-9]+)*[a-z]?)(?=[ .]|$)", d92, re.M)),
        "93": set(re.findall(r"^#{2,3} ([A-Z][0-9]*)[.— ]", d93, re.M)),
        "98": set(re.findall(r"^## ([0-9]+[a-z]?)\.", d98, re.M)),
    }

    problems: list[str] = []

    # ---- half one: is any id assigned twice? -------------------------------
    for label, doc, pattern in (
        ("doc 98 RR", d98, r"^### (RR-[0-9]+[a-z]?)"),
        ("doc 98 section", d98, r"^## ([0-9]+[a-z]?)\."),
        ("doc 93 section", d93, r"^#{2,3} ([A-Z][0-9]*)[.— ]"),
        ("doc 92 section", d92, r"^#{2,4} ([0-9]+(?:\.[0-9]+)*[a-z]?)(?=[ .]|$)"),
        ("doc 91 defect", d91, r"^\| \*\*(A91-D-[0-9]+)\*\*"),
    ):
        for dup in duplicates(pattern, doc):
            problems.append("DOUBLE-ASSIGNED  %s %s" % (label, dup))

    # ---- half two: does every reference resolve? ---------------------------
    refs: dict[tuple[str, str], set[str]] = {}
    counts = {k: 0 for k in targets}

    scans = (
        ("RR", r"\bRR-([0-9]+[a-z]?)\b", "RR-%s"),
        ("A91-D", r"\bA91-D-([0-9]+)\b", "A91-D-%s"),
        ("92", r"\b92 §([0-9]+(?:\.[0-9]+)*[a-z]?)", "%s"),
        ("93", r"\b93 §([A-Z][0-9]*)", "%s"),
        ("98", r"\b98 §([0-9]+[a-z]?)", "%s"),
    )

    for path, text in walk(root):
        for space, pattern, fmt in scans:
            for match in re.finditer(pattern, text):
                raw = match.group(1)
                counts[space] += 1
                if (space, raw) in EXEMPT:
                    continue
                if (fmt % raw) not in targets[space]:
                    refs.setdefault((space, raw), set()).add(path)

    shown = {"RR": "RR-%s", "A91-D": "A91-D-%s"}
    for (space, raw), paths in sorted(refs.items()):
        label = shown.get(space, space + " §%s") % raw
        problems.append("DANGLING         %-14s <- %s"
                        % (label, ", ".join(sorted(paths))))

    if verbose or problems:
        print("targets: " + "  ".join("%s=%d" % (k, len(v))
                                      for k, v in sorted(targets.items())))
        print("refs:    " + "  ".join("%s=%d" % (k, v)
                                      for k, v in sorted(counts.items())))

    if problems:
        print("\n%d PROBLEM(S):" % len(problems))
        for line in problems:
            print("  " + line)
        return 1

    print("check_doc_refs: %d references, all resolving; no id assigned twice."
          % sum(counts.values()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
