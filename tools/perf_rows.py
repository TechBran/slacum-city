#!/usr/bin/env python3
"""Turn `PERF`/`PERFIO` logcat captures into the columns doc 11 §2.13 asks for.

`bench_device.sh`'s own `summarise_perf` answers "is the capture armed and how
bad is the worst frame" in one line, which is the right shape for a pre-flight.
This one answers the different question a TABLE needs: the median of every
column, per capture, with the warm-up dropped — so a row can be pasted into
doc 11 without hand-arithmetic in the middle of a device window.

Steady state is `t >= STEADY` seconds, matching the 2026-08-20 session's own
rule: before that the shader cache is still filling and the city is still
streaming in, and those frames are not the pose.

Usage: perf_rows.py <capture.txt> [more.txt ...]
"""
import re
import statistics
import sys

STEADY = 12.0
# Values are not all numeric — `preset=balanced` is the one that matters for a
# table row, and a numbers-only pattern silently reports it as "?".
NUM = re.compile(r"(\w+)=([^\s]+)")


def rows(path):
    perf, io, contaminated = [], [], False
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if "CONTAMINATED" in line:
                contaminated = True
            if "PERFIO" in line:
                io.append(dict(NUM.findall(line)))
            elif " PERF " in line or line.lstrip().startswith("PERF "):
                f = dict(NUM.findall(line))
                if "fps" in f and "t" in f:
                    perf.append(f)
    return perf, io, contaminated


def med(vals):
    return statistics.median(vals) if vals else float("nan")


def summarise(path):
    perf, io, contaminated = rows(path)
    steady = [f for f in perf if float(f.get("t", 0)) >= STEADY] or perf
    label = path.split("/")[-1].replace("log_", "").replace(".txt", "")

    if not perf:
        print("%-18s NO PERF LINES — capture unarmed, or the app never ran "
              "(lockscreen: Godot gets OnStop ~20 ms after OnResume)" % label)
    else:
        g = lambda k: [float(f[k]) for f in steady if k in f]
        i = lambda k: [int(float(f[k])) for f in steady if k in f]
        dcs = i("dc")
        print("%-18s n=%-3d fps=%-5.1f p95=%-5.1f cpu=%-4.2f gpu=%-5.1f "
              "dc=%d/%d prim=%d vram=%s chunks=%s near=%s inst=%s "
              "preset=%s knob=%s thermal=%s%s"
              % (label, len(steady), med(g("fps")), med(g("p95")),
                 med(g("cpu")), med(g("gpu_est")),
                 int(med(dcs)) if dcs else -1, max(dcs) if dcs else -1,
                 int(med(i("prim"))) if i("prim") else -1,
                 int(med(i("vram"))) if i("vram") else -1,
                 int(med(i("chunks"))) if i("chunks") else -1,
                 int(med(i("near"))) if i("near") else -1,
                 int(med(i("inst"))) if i("inst") else -1,
                 sorted({f.get("preset", "?") for f in steady}) if False else
                 (steady[0].get("preset", "?")),
                 sorted({int(float(f.get("knob", 0))) for f in steady}),
                 max(i("thermal")) if i("thermal") else -1,
                 "  ** CONTAMINATED **" if contaminated else ""))
    for r in io:
        print("    PERFIO %s" % " ".join("%s=%s" % kv for kv in r.items()))


if __name__ == "__main__":
    for p in sys.argv[1:]:
        try:
            summarise(p)
        except FileNotFoundError:
            print("%-18s (missing)" % p)
