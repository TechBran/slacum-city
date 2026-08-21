#!/usr/bin/env python3
"""Generate the procedural soundscape for SLACUM CITY.

Source of truth: `docs/design/11-rendering-performance.md` §2.15 (audio is doc
11's, from Phase 2: `game/audio/`, `data/audio.json`, and the event-hook table
with the *beat* each sound is authored against).  Nothing here is sampled and
nothing is downloaded — every asset is synthesised from numpy, so the whole set
is reproducible from this file alone and the repo carries ~3 MB of WAV instead
of a licence trail.

Two ideas carry the whole file
------------------------------

**1. Loops are built in the frequency domain, so they are seamless by
construction.**  A loop is `N` samples of white noise pushed through `rfft`,
multiplied by a spectral shape, and pushed back through `irfft`.  That product
is *periodic with period N* — the filter wraps around the buffer exactly the
way playback does — so `x[N-1] → x[0]` is an ordinary sample step and not a
click.  Every periodic component added on top (LFOs, hum partials, distant
tones, the site loop's ticks) is snapped to an integer number of cycles per
buffer, and transients are stamped in with modulo indexing.  No cross-fade, no
tapering, no "close enough".  `verify_loop()` then *measures* the seam against
the buffer's own median sample step and the manifest records the ratio, so a
future edit that breaks periodicity fails `tests/test_audio_model.gd` instead
of shipping a tick every four seconds.

**2. The beats are the doc's, not the mixer's.**  `blackout_whomp` puts its two
envelope stutters at 0.09 s and 0.17 s and reaches the silence floor at 1.20 s;
`relight_hum` runs 3.15 s with its swell peak — and the 1.35x inrush overshoot
— at 1.10 s.  Those are §2.15's numbers verbatim, which is what makes the
power-down/relight ceremony read as one audiovisual event rather than a sound
laid over an animation.

Usage
-----
    python3 tools/gen_audio.py                     # write game/audio/generated/
    python3 tools/gen_audio.py --check             # rebuild in memory, verify only
    python3 tools/gen_audio.py --out /tmp/audio    # elsewhere
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import sys
import zlib

import numpy as np

# Per-asset sample rate. A bed whose content stops at 460 Hz spends three
# quarters of its bytes on empty spectrum at 44.1 kHz, and those bytes are worth
# far more as *loop length* — a short loop is the one flaw a listener reliably
# notices in ambience. So each asset declares the rate its own bandwidth needs
# (`SPECS`), and the budget it saves is spent making the beds long enough not to
# read as a pattern. Godot stores `mix_rate` per AudioStreamWAV and resamples at
# playback, so this costs nothing at runtime.
SR_FULL = 44100
SR_HALF = 22050
SR = SR_FULL          # the rate currently being built; `main()` sets it per asset
BIT_DEPTH = 16
# Raised 4.0 -> 4.5 MiB by the Audio-2 ruling that also relaxed the under-8 s
# loop brief. The extra half-megabyte is spent entirely on loop LENGTH (7.5 ->
# 12 s on the three atmospheric beds) plus the storm wind bed, and it is paid
# for in part by filing `siren_pass` at the half rate — its top partial is the
# 7th of a 960 Hz wail (6.7 kHz), which sits a long way inside 11 kHz.
TOTAL_BUDGET_BYTES = 4608 * 1024

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(os.path.dirname(HERE), "game", "audio", "generated")


# ---------------------------------------------------------------------------
# Deterministic noise + spectral shaping
# ---------------------------------------------------------------------------

def rng(name: str) -> np.random.Generator:
    """One named stream per noise layer (constitution §3's rule, applied to art).

    `crc32` is stable across platforms and python builds and `default_rng`'s
    PCG64 stream is covered by numpy's compatibility guarantee, so two machines
    generate byte-identical WAVs.
    """
    return np.random.default_rng(zlib.crc32(name.encode("utf-8")) & 0xFFFFFFFF)


def bins(n: int) -> np.ndarray:
    return np.fft.rfftfreq(n, 1.0 / SR)


def circ_noise(n: int, name: str, shape) -> np.ndarray:
    """White noise shaped by `shape(freq_hz) -> amplitude`, **circularly**.

    Because the filtering is a multiply in the DFT domain, the result is exactly
    periodic over `n` samples: this is the one primitive that makes every loop
    in the set seamless without a cross-fade.
    """
    spec = np.fft.rfft(rng(name).standard_normal(n))
    out = np.fft.irfft(spec * shape(bins(n)), n)
    return out - out.mean()


def lp(f: np.ndarray, fc: float, order: float = 2.0) -> np.ndarray:
    """Butterworth-ish lowpass magnitude, -6*order dB/oct above `fc`."""
    return 1.0 / np.sqrt(1.0 + (f / max(fc, 1e-6)) ** (2.0 * order))


def hp(f: np.ndarray, fc: float, order: float = 2.0) -> np.ndarray:
    x = (np.maximum(f, 0.0) / max(fc, 1e-6)) ** order
    return x / np.sqrt(1.0 + x * x)


def bp(f: np.ndarray, fc: float, width_oct: float = 1.0) -> np.ndarray:
    """Log-Gaussian band. Smooth everywhere, so it never rings on a transient."""
    x = np.log2(np.maximum(f, 1e-3) / fc) / max(width_oct, 1e-3)
    return np.exp(-0.5 * x * x)


def tilt(f: np.ndarray, slope_db_oct: float, pivot: float = 1000.0) -> np.ndarray:
    return 10.0 ** (slope_db_oct * np.log2(np.maximum(f, 1e-3) / pivot) / 20.0)


# ---------------------------------------------------------------------------
# Time-domain helpers
# ---------------------------------------------------------------------------

def times(seconds: float) -> tuple[int, np.ndarray]:
    n = int(round(seconds * SR))
    return n, np.arange(n) / SR


def ad(t: np.ndarray, attack: float, decay: float, hold: float = 0.0) -> np.ndarray:
    """Attack (linear, click-free) then exponential decay with `decay` as tau."""
    a = np.clip(t / max(attack, 1e-5), 0.0, 1.0)
    rest = np.maximum(t - attack - hold, 0.0)
    return a * np.exp(-rest / max(decay, 1e-5))


def fade_out(t: np.ndarray, start: float, end: float) -> np.ndarray:
    """Raised-cosine tail so a one-shot ends on true digital silence."""
    x = np.clip((t - start) / max(end - start, 1e-5), 0.0, 1.0)
    return 0.5 + 0.5 * np.cos(np.pi * x)


def partial_stack(t: np.ndarray, f0: float, ratios, amps, decays,
                  attack: float = 0.004) -> np.ndarray:
    """Inharmonic partial set — the difference between a bell and a beep."""
    out = np.zeros_like(t)
    for ratio, amp, dec in zip(ratios, amps, decays):
        out += amp * np.sin(2.0 * np.pi * f0 * ratio * t) * ad(t, attack, dec)
    return out


def stamp(buf: np.ndarray, at_s: float, chunk: np.ndarray, gain: float = 1.0) -> None:
    """Add `chunk` at `at_s`, wrapping modulo the buffer.

    Wrapping is what lets a rhythmic loop put a tick near the very end: the tail
    lands back at the head exactly as playback would replay it, so the loop stays
    periodic. For one-shots nothing ever reaches the end, so it never wraps.
    """
    n = buf.size
    idx = (int(round(at_s * SR)) + np.arange(chunk.size)) % n
    np.add.at(buf, idx, chunk * gain)


def bin_lock(freq: float, seconds: float) -> float:
    """Snap a frequency to a whole number of cycles per loop (>= 1 cycle)."""
    return max(1.0, round(freq * seconds)) / seconds


def lfo(t: np.ndarray, seconds: float, cycles: int, phase: float = 0.0) -> np.ndarray:
    return np.sin(2.0 * np.pi * cycles * t / seconds + phase)


def dc_kill(x: np.ndarray) -> np.ndarray:
    return x - x.mean()


# The four cycle counts every bed modulates on, and the phases that go with
# them. Both halves are load-bearing and both were chosen against a *judged*
# defect, not a guess:
#
# **No one-cycle term.** The first pass used cycles (1, 3, 5, 7) with the
# one-cycle LFO carrying half the depth. That gives each buffer exactly one big
# swell, always at the same place — and a swell at a fixed place is a LANDMARK.
# A seamless loop with a landmark still reads as a loop: the judging pass heard
# "the initial gust at the start of each loop acts as a clear marker for the
# start of the pattern" on the beds built that way, which is the criticism that
# actually matters once the seam itself is clean. Starting at two cycles and
# weighting the four terms comparably leaves an envelope that wanders instead of
# breathing, with no single gesture long enough to be recognised.
#
# **Phases put t=0 in the MIDDLE of the swing.** Searched, not picked: these
# four put the composite at -0.016 of a ±0.82 range at t=0 — dead centre. The
# loop point therefore lands on an ordinary moment rather than on the crest, so
# there is nothing distinctive happening at the one instant a listener has been
# trained by every other game to listen for.
WANDER_CYCLES = (2, 3, 5, 7)
WANDER_WEIGHTS = (0.34, 0.27, 0.22, 0.17)
WANDER_PHASES = (4.1333, 1.6658, 5.9090, 0.4949)


def wander(t: np.ndarray, seconds: float) -> np.ndarray:
    """Landmark-free slow modulation, roughly ±0.8, exactly periodic over `t`."""
    out = np.zeros_like(t)
    for cycles, weight, phase in zip(WANDER_CYCLES, WANDER_WEIGHTS, WANDER_PHASES):
        out += weight * lfo(t, seconds, cycles, phase)
    return out


# ---------------------------------------------------------------------------
# UI — three blips that have to survive being heard ten thousand times
# ---------------------------------------------------------------------------

def build_ui_tap() -> np.ndarray:
    n, t = times(0.085)
    body = (0.72 * np.sin(2 * np.pi * 1420 * t)
            + 0.28 * np.sin(2 * np.pi * 2130 * t)) * ad(t, 0.0015, 0.016)
    click = circ_noise(n, "ui_tap/click", lambda f: bp(f, 2800, 1.1)) * ad(t, 0.0004, 0.004)
    return (0.85 * body + 0.45 * click) * fade_out(t, 0.070, 0.085)


def build_ui_confirm() -> np.ndarray:
    n, t = times(0.30)
    out = np.zeros(n)
    # A rising fifth: G5 -> D6. Two notes, the second overlapping the first's tail.
    for at, freq, amp in ((0.0, 784.0, 0.62), (0.085, 1174.7, 0.75)):
        seg = np.maximum(t - at, 0.0)
        live = (t >= at).astype(float)
        tone = (np.sin(2 * np.pi * freq * seg)
                + 0.22 * np.sin(2 * np.pi * 3 * freq * seg)
                + 0.08 * np.sin(2 * np.pi * 5 * freq * seg))
        out += amp * live * tone * ad(seg, 0.005, 0.075)
    air = circ_noise(n, "ui_confirm/air", lambda f: bp(f, 5200, 1.3)) * ad(t, 0.003, 0.030)
    return (out + 0.10 * air) * fade_out(t, 0.26, 0.30)


def build_ui_deny() -> np.ndarray:
    n, t = times(0.24)
    # A short downward glide with odd harmonics only — reads as "no" without
    # being a harsh buzzer, and the two amplitude gates give it the stutter.
    freq = 340.0 * np.exp(-t / 0.42)
    phase = 2 * np.pi * np.cumsum(freq) / SR
    tone = (np.sin(phase) + 0.34 * np.sin(3 * phase) + 0.13 * np.sin(5 * phase))
    gate = 1.0 - 0.55 * (np.sin(2 * np.pi * 26.0 * t) > 0.0)
    body = tone * gate * ad(t, 0.004, 0.085)
    low = circ_noise(n, "ui_deny/low", lambda f: lp(f, 420, 2)) * ad(t, 0.002, 0.05)
    return (0.80 * body + 0.22 * low) * fade_out(t, 0.20, 0.24)


# ---------------------------------------------------------------------------
# Money and construction
# ---------------------------------------------------------------------------

def build_purchase() -> np.ndarray:
    """Cash-register-ish: mechanical chunk, metallic ching, drawer slide."""
    n, t = times(0.70)
    out = np.zeros(n)
    chunk = circ_noise(n, "purchase/chunk", lambda f: lp(f, 320, 2) * hp(f, 60, 1))
    out += 0.85 * chunk * ad(t, 0.001, 0.030)
    seg = np.maximum(t - 0.045, 0.0)
    live = (t >= 0.045).astype(float)
    ching = partial_stack(seg, 1150.0,
                          ratios=(1.0, 2.76, 5.40, 8.93),
                          amps=(1.0, 0.55, 0.28, 0.12),
                          decays=(0.22, 0.15, 0.09, 0.06), attack=0.0012)
    out += 0.55 * live * ching
    drawer = circ_noise(n, "purchase/drawer", lambda f: bp(f, 900, 1.5) * lp(f, 4000, 2))
    slide = np.clip((t - 0.13) / 0.16, 0.0, 1.0) * np.clip((0.36 - t) / 0.10, 0.0, 1.0)
    out += 0.16 * drawer * slide
    tick = circ_noise(n, "purchase/tick", lambda f: bp(f, 2400, 1.0))
    out += 0.18 * tick * ad(np.maximum(t - 0.42, 0.0), 0.0006, 0.010) * (t >= 0.42)
    return out * fade_out(t, 0.60, 0.70)


def build_cash() -> np.ndarray:
    """Coins landing in a palm: three struck discs over a short note rustle.

    Deliberately **not** `purchase`. That one is a till drawer closing on a
    decision made from a menu — it has a mechanism in it, and it takes 0.70 s to
    say so. This is money arriving from something the player touched on the
    street, or a bounty landing while they were looking elsewhere, so it is
    faster, higher and mechanism-free: the whole event is over in 0.34 s and the
    ear reads it as "that paid" rather than as "that was bought".

    The partial ratios are struck-disc ratios, not harmonics — that is the whole
    difference between a coin and a bell — and each disc carries its own 5 kHz
    strike transient, which is what makes it metal rather than a sine.
    """
    n, t = times(0.55)
    out = np.zeros(n)
    for at, f0, amp, dec in ((0.000, 2240.0, 0.80, 0.20),
                             (0.058, 2980.0, 0.66, 0.16),
                             (0.132, 1830.0, 0.58, 0.26)):
        seg = np.maximum(t - at, 0.0)
        live = (t >= at).astype(float)
        out += amp * live * partial_stack(
            seg, f0,
            ratios=(1.0, 1.59, 2.14, 3.41, 4.72),
            amps=(1.0, 0.62, 0.44, 0.22, 0.11),
            decays=(dec, dec * 0.70, dec * 0.52, dec * 0.34, dec * 0.22),
            attack=0.0008)
        strike = circ_noise(n, "cash/strike%d" % int(round(at * 1000)),
                            lambda f: bp(f, 5200, 1.4))
        out += 0.32 * amp * live * strike * ad(seg, 0.0004, 0.006)
    rustle = circ_noise(n, "cash/rustle", lambda f: bp(f, 1500, 2.0) * lp(f, 6000, 2))
    out += 0.13 * rustle * np.clip((t - 0.02) / 0.05, 0.0, 1.0) \
        * np.clip((0.34 - t) / 0.14, 0.0, 1.0)
    return out * fade_out(t, 0.44, 0.55)


def build_construct_stage() -> np.ndarray:
    """One construction stage tick. Deliberately almost subliminal."""
    n, t = times(0.13)
    wood = np.sin(2 * np.pi * 620 * t) * ad(t, 0.0008, 0.014)
    tap = circ_noise(n, "stage/tap", lambda f: bp(f, 1800, 1.2)) * ad(t, 0.0005, 0.008)
    return (0.55 * wood + 0.55 * tap) * fade_out(t, 0.10, 0.13)


def build_construct_complete() -> np.ndarray:
    """Three-note bell arpeggio: E5 - A5 - E6, struck, not played."""
    n, t = times(1.30)
    out = np.zeros(n)
    for at, freq, amp, dec in ((0.000, 659.3, 0.70, 0.42),
                               (0.085, 880.0, 0.78, 0.50),
                               (0.170, 1318.5, 0.62, 0.62)):
        seg = np.maximum(t - at, 0.0)
        live = (t >= at).astype(float)
        out += amp * live * partial_stack(
            seg, freq,
            ratios=(1.0, 2.01, 3.02, 4.98),
            amps=(1.0, 0.42, 0.20, 0.09),
            decays=(dec, dec * 0.62, dec * 0.40, dec * 0.26), attack=0.003)
    air = circ_noise(n, "complete/air", lambda f: bp(f, 3400, 1.6))
    out += 0.09 * air * ad(t, 0.006, 0.28)
    return out * fade_out(t, 1.10, 1.30)


# ---------------------------------------------------------------------------
# Power — doc 11 §2.15's two ceremonies, authored against its beats
# ---------------------------------------------------------------------------

def build_blackout_whomp() -> np.ndarray:
    """Mains hum cuts. Stutters at 0.09 s / 0.17 s, silence floor at 1.20 s."""
    n, t = times(1.40)
    glide = 60.0 * np.exp(-t / 0.30) + 11.0 * np.exp(-t / 1.10)
    phase = 2 * np.pi * np.cumsum(glide) / SR
    hum = (np.sin(phase) + 0.48 * np.sin(2 * phase) + 0.18 * np.sin(3 * phase))
    amp = np.exp(-t / 0.40)
    for at in (0.09, 0.17):                      # §2.15: the envelope's two dips
        amp = amp * (1.0 - 0.88 * np.exp(-((t - at) / 0.0115) ** 2))
    body = hum * amp
    clunk = circ_noise(n, "whomp/clunk", lambda f: lp(f, 260, 2) * hp(f, 45, 1))
    body += 0.55 * clunk * ad(t, 0.0012, 0.035)
    rumble = circ_noise(n, "whomp/rumble", lambda f: lp(f, 95, 2))
    body += 0.42 * rumble * np.clip(1.0 - t / 1.20, 0.0, 1.0) ** 2   # silence at 1.20 s
    return dc_kill(body) * fade_out(t, 1.15, 1.38)


def build_relight_hum() -> np.ndarray:
    """Transformer swell. duration_s = 3.15, peak at 1.10 s, 1.35x inrush.

    Two envelopes, not one. The *sub* — the core loading, an octave under the
    mains — comes up early and slowly (exponent < 1), so the first 0.7 s has
    real mass in it and the swell reads as a city grid rather than a cupboard
    transformer. The harmonic stack rides `rise` instead of being flat, so the
    tone opens from a near-pure low hum into the full buzzing stack as it takes
    load: brightness follows current, which is what an energising transformer
    actually does and what makes the peak feel earned.
    """
    n, t = times(3.15)
    peak_at = 1.10
    rise = np.clip(t / peak_at, 0.0, 1.0) ** 1.45
    settle = 0.55 + 0.45 * np.exp(-np.maximum(t - peak_at, 0.0) / 0.42)
    inrush = 1.0 + 0.35 * np.exp(-((t - peak_at) / 0.135) ** 2)      # the 1.35x
    amp = rise * settle * inrush
    freq = 60.0 - 3.0 * np.exp(-t / 0.55)        # settles onto the mains as it loads
    phase = 2 * np.pi * np.cumsum(freq) / SR
    hum = np.sin(phase) + rise * (0.62 * np.sin(2 * phase)
                                  + 0.30 * np.sin(3 * phase)
                                  + 0.12 * np.sin(4 * phase))
    sub_env = np.clip(t / (peak_at * 1.25), 0.0, 1.0) ** 0.55 * settle
    sub = np.sin(0.5 * phase) + 0.35 * np.sin(1.5 * phase)
    shimmer = circ_noise(n, "relight/shimmer", lambda f: bp(f, 2400, 1.1))
    body = hum * amp + 0.62 * sub * sub_env + 0.16 * shimmer * (amp ** 2)
    click = circ_noise(n, "relight/contactor", lambda f: bp(f, 1400, 1.4))
    body += 0.30 * click * ad(t, 0.001, 0.018)   # the contactor closing at t=0
    return dc_kill(body) * fade_out(t, 2.55, 3.15)


# ---------------------------------------------------------------------------
# Weather
# ---------------------------------------------------------------------------

def build_thunder_crack() -> np.ndarray:
    """Near strike: the shock arrives before the rumble has time to smear."""
    n, t = times(1.90)
    crack = circ_noise(n, "thunder/crack", lambda f: hp(f, 1400, 1.5) * lp(f, 9000, 1))
    body = 0.95 * crack * ad(t, 0.0018, 0.055)
    mid = circ_noise(n, "thunder/mid", lambda f: bp(f, 320, 1.6))
    body += 0.70 * mid * ad(t, 0.004, 0.30)
    low = circ_noise(n, "thunder/low", lambda f: lp(f, 85, 2))
    am = 1.0 + 0.30 * np.sin(2 * np.pi * 5.5 * t) * np.exp(-t / 0.7)
    body += 0.85 * low * ad(t, 0.010, 0.55) * am
    return dc_kill(body) * fade_out(t, 1.55, 1.90)


def build_thunder_rumble() -> np.ndarray:
    """Distant strike: four smeared bursts, no attack left in any of them."""
    n, t = times(3.00)
    body = np.zeros(n)
    for at, amp, fc, dec in ((0.00, 1.00, 190, 0.85),
                             (0.42, 0.72, 150, 0.95),
                             (1.05, 0.85, 120, 1.10),
                             (1.85, 0.48, 95, 0.90)):
        seg = np.maximum(t - at, 0.0)
        live = (t >= at).astype(float)
        layer = circ_noise(n, "rumble/%d" % int(at * 1000), lambda f, fc=fc: lp(f, fc, 2))
        body += amp * live * layer * ad(seg, 0.070, dec)
    body *= 1.0 + 0.22 * np.sin(2 * np.pi * 3.1 * t) + 0.12 * np.sin(2 * np.pi * 6.7 * t)
    return dc_kill(body) * fade_out(t, 2.45, 3.00)


## Every bed's modulation uses COPRIME cycle counts (1, 3, 5, 7…). Their least
## common multiple is the whole buffer, so the texture never repeats *inside* the
## loop and the ear has nothing shorter than the whole buffer to lock onto.
##
## **12 s, not 7.5** (Audio-2 ruling). 7.5 s was chosen against a 4 MB budget and
## an "under 8 s" brief; both were relaxed, and the honest truth is that a
## seamless loop is still a loop — the ear locks onto the *gust pattern*, not
## onto a click. 12 s pushes the shortest recognisable gesture (the one-cycle
## LFO) past the ~8 s window in which a listener reliably matches two textures,
## and it is the single highest-value place the extra bytes could go.
LOOP_SECONDS = 12.0
## The storm bed is deliberately NOT `LOOP_SECONDS`. It plays *underneath* the
## wind bed, and 10 against 12 is coprime in seconds: the pair realigns only
## every 60 s, so a storm that lasts a minute never repeats the same combination
## twice. Two loops of the same length would have been one 12 s loop with extra
## steps.
STORM_LOOP_SECONDS = 10.0
## Rain droplets per second of buffer. See `build_rain_loop`.
DROPS_PER_SECOND = 40.0 / 7.5


def build_rain_loop() -> np.ndarray:
    """Seamless rain bed: hiss + road wash + sparse droplets, all circular."""
    seconds = LOOP_SECONDS
    n, t = times(seconds)
    hiss = circ_noise(n, "rain/hiss",
                      lambda f: hp(f, 380, 1) * lp(f, 7500, 1) * (1.0 + 0.7 * bp(f, 2400, 1.5)))
    # The road wash was judged "a little woolly in the lower mids" at bp(300)
    # ×0.40. Moved up to 420 Hz and trimmed to 0.27: the weight is still there —
    # rain on tarmac is not all sizzle — but the 200-400 Hz band it was piling
    # into now belongs to the storm bed, which is the layer that should own it.
    wash = circ_noise(n, "rain/wash", lambda f: bp(f, 420, 1.15) * lp(f, 1150, 2))
    body = 0.85 * hiss + 0.27 * wash
    body *= 1.0 + 0.16 * wander(t, seconds)
    # Droplets, stamped modulo the buffer so one near the end wraps cleanly, and
    # placed by STRATIFIED sampling: one per 1/count slot, jittered inside it.
    # Uniform draws clump, and a clump that happens to land near t=0 is heard as
    # the loop "restarting with a flourish" every cycle even though the waveform
    # is perfectly continuous there. Stratifying keeps the density even across
    # the seam, so there is nothing periodic for the ear to lock onto.
    drop_rng = rng("rain/drops")
    kn, kt = times(0.012)
    # Density, not count: 5.33 droplets a second was the level judged right at
    # 7.5 s, and a longer buffer must sound identical, not rainier.
    count = int(round(DROPS_PER_SECOND * seconds))
    for i in range(count):
        kernel = (np.fft.irfft(np.fft.rfft(rng("rain/drop%d" % i).standard_normal(kn))
                               * bp(bins(kn), 3200 * (0.7 + 0.6 * drop_rng.random()), 0.9), kn)
                  * ad(kt, 0.0004, 0.0035))
        at = (i + float(drop_rng.random())) * seconds / count
        stamp(body, at, kernel, 0.20 + 0.16 * float(drop_rng.random()))
    return dc_kill(body)


def build_wind_loop() -> np.ndarray:
    """Seamless wind bed: gusting band-noise with one faint edge whistle."""
    seconds = LOOP_SECONDS
    n, t = times(seconds)
    band = circ_noise(n, "wind/band", lambda f: bp(f, 430, 1.5) * lp(f, 1800, 2))
    low = circ_noise(n, "wind/low", lambda f: lp(f, 160, 2))
    gust = np.clip(0.58 + 0.52 * wander(t, seconds), 0.12, 1.0)
    whistle = (np.sin(2 * np.pi * bin_lock(1180.0, seconds) * t)
               * (0.5 + 0.5 * lfo(t, seconds, 7, 0.4)))
    body = (0.9 * band + 0.5 * low) * gust + 0.035 * whistle * gust
    return dc_kill(body)


def build_storm_wind() -> np.ndarray:
    """The bed that goes UNDER the wind bed once a storm is really blowing.

    `wind_loop` is wind heard in the open: a mid band that gusts. What a storm
    adds is not more of that — it is *pressure*. Three things this bed has that
    the plain wind bed deliberately does not:

    * **A sub-100 Hz buffet.** Filed at 22.05 kHz precisely because there is
      nothing above 2 kHz in it worth a byte.
    * **Slow, deep gusting.** The envelope swings 0.18 -> 1.0 (against the wind
      bed's 0.12 -> 1.0 on a much flatter shape) and rides one, two and three
      cycles per buffer, so the surges are ten-second events rather than the
      wind bed's per-second flutter. Layered on top of a bed whose gusts are
      already moving, that is what reads as weather rather than as noise.
    * **Rattle.** Sparse, stratified band-noise taps — sheet metal and loose
      fittings answering the gusts — stamped modulo the buffer and *amplitude-
      keyed to the gust envelope*, so they only happen when the wind is up.

    Layering rather than replacing is the point: at full storm both beds run,
    and the crossfade the mix does is between "windy" and "windy plus weight".
    """
    seconds = STORM_LOOP_SECONDS
    n, t = times(seconds)
    buffet = circ_noise(n, "storm/buffet", lambda f: lp(f, 78, 2) * hp(f, 22, 1))
    roar = circ_noise(n, "storm/roar", lambda f: bp(f, 240, 1.7) * lp(f, 1100, 2))
    # Spray: wind-driven water off roofs and road. It is only ~9% of the level,
    # but it is the layer that keeps the bed from being a pure sub — and it is
    # what makes the rattles below read as part of the texture rather than as
    # isolated transients on an otherwise glassy buffer.
    spray = circ_noise(n, "storm/spray", lambda f: bp(f, 1500, 1.7) * lp(f, 4200, 2))
    gust = np.clip(0.56 + 0.56 * wander(t, seconds), 0.18, 1.0)
    body = (1.00 * buffet + 0.46 * roar) * gust + 0.30 * spray * gust ** 2
    rattle_rng = rng("storm/rattles")
    kn, kt = times(0.055)
    count = 9
    for i in range(count):
        fc = 900.0 * (0.75 + 0.7 * float(rattle_rng.random()))
        noise = np.fft.irfft(np.fft.rfft(rng("storm/rattle%d" % i).standard_normal(kn))
                             * bp(bins(kn), fc, 0.8), kn)
        kernel = noise * ad(kt, 0.0012, 0.011)
        at = (i + float(rattle_rng.random())) * seconds / count
        # Keyed to the gust: a rattle in a lull would read as a foley mistake.
        strength = float(np.interp(at, t, gust))
        stamp(body, at, kernel, 0.16 * strength ** 2)
    return dc_kill(body)


# ---------------------------------------------------------------------------
# Ambience beds
# ---------------------------------------------------------------------------

def build_amb_city_day() -> np.ndarray:
    """Daytime city: traffic bed, a little air, three faint distant tones."""
    seconds = LOOP_SECONDS
    n, t = times(seconds)
    traffic = circ_noise(n, "amb_day/traffic",
                         lambda f: hp(f, 50, 2) * lp(f, 950, 1.3) * (1.0 + 0.45 * bp(f, 175, 1.0)))
    air = circ_noise(n, "amb_day/air", lambda f: bp(f, 2600, 1.7))
    body = 0.95 * traffic + 0.055 * air
    for freq, amp, cyc in ((92.0, 0.030, 2), (138.0, 0.022, 3), (207.0, 0.014, 5)):
        f = bin_lock(freq, seconds)
        body += amp * np.sin(2 * np.pi * f * t) * (0.6 + 0.4 * lfo(t, seconds, cyc, 0.7))
    body *= 1.0 + 0.13 * wander(t, seconds)
    return dc_kill(body)


def build_amb_city_night() -> np.ndarray:
    """Night bed: the same city with the mid gone, plus a 100 Hz mains hum."""
    seconds = LOOP_SECONDS
    n, t = times(seconds)
    bed = circ_noise(n, "amb_night/bed",
                     lambda f: hp(f, 40, 2) * lp(f, 460, 1.4) * (1.0 + 0.35 * bp(f, 110, 1.0)))
    air = circ_noise(n, "amb_night/air", lambda f: bp(f, 3000, 1.8))
    body = 0.95 * bed + 0.022 * air
    mains = bin_lock(100.0, seconds)
    body += 0.045 * np.sin(2 * np.pi * mains * t) + 0.014 * np.sin(2 * np.pi * 2 * mains * t)
    body += (0.010 * np.sin(2 * np.pi * bin_lock(330.0, seconds) * t)
             * (0.5 + 0.5 * lfo(t, seconds, 3)))
    body *= 1.0 + 0.09 * wander(t, seconds)
    return dc_kill(body)


def build_site_loop() -> np.ndarray:
    """Construction site: idling motor plus twelve rhythmic mechanical ticks.

    A crane loop is *supposed* to be periodic — that is what makes it read as
    machinery — so the ticks stay on a strict grid. The variety comes from the
    three-tick pattern (heavy / light / light) sitting on twelve beats, which is
    long enough that the ear hears work rather than a metronome.
    """
    seconds = 6.0
    n, t = times(seconds)
    f0 = bin_lock(52.0, seconds)
    motor = sum(np.sin(2 * np.pi * f0 * k * t) / (k ** 1.4) for k in (1, 2, 3, 4, 6))
    motor *= 0.78 + 0.22 * lfo(t, seconds, 8, 0.3)
    hydraulic = circ_noise(n, "site/hyd", lambda f: bp(f, 620, 1.6) * lp(f, 2200, 2))
    body = 0.30 * motor + 0.14 * hydraulic * (0.6 + 0.4 * lfo(t, seconds, 3))
    kn, kt = times(0.10)
    beats = 12
    for i in range(beats):
        heavy = (i % 3) == 0
        fc = 780.0 if heavy else 1650.0
        noise = np.fft.irfft(np.fft.rfft(rng("site/tick%d" % i).standard_normal(kn))
                             * bp(bins(kn), fc, 1.1), kn)
        ring = np.sin(2 * np.pi * (380.0 if heavy else 910.0) * kt)
        kernel = (0.7 * noise + 0.5 * ring) * ad(kt, 0.0008, 0.018 if heavy else 0.008)
        stamp(body, i * seconds / beats, kernel, 0.62 if heavy else 0.34)
    return dc_kill(body)


# ---------------------------------------------------------------------------
# Incidents and progression
# ---------------------------------------------------------------------------

def build_alert_low() -> np.ndarray:
    """Routine incident: a muted descending minor third. Informative, not loud."""
    n, t = times(0.90)
    out = np.zeros(n)
    for at, freq in ((0.00, 587.3), (0.20, 493.9)):
        seg = np.maximum(t - at, 0.0)
        live = (t >= at).astype(float)
        tone = np.sin(2 * np.pi * freq * seg) + 0.24 * np.sin(2 * np.pi * 3 * freq * seg)
        out += 0.62 * live * tone * ad(seg, 0.018, 0.20)
    return out * fade_out(t, 0.70, 0.90)


def build_alert_high() -> np.ndarray:
    """Critical incident: three pulses, a beating detune, a brighter partial."""
    n, t = times(1.15)
    out = np.zeros(n)
    for at, amp in ((0.00, 0.85), (0.215, 0.90), (0.430, 1.00)):
        seg = np.maximum(t - at, 0.0)
        live = (t >= at).astype(float)
        tone = (np.sin(2 * np.pi * 740.0 * seg) + np.sin(2 * np.pi * 746.0 * seg)
                + 0.42 * np.sin(2 * np.pi * 1109.0 * seg)
                + 0.16 * np.sin(2 * np.pi * 1480.0 * seg))
        out += 0.42 * amp * live * tone * ad(seg, 0.006, 0.115)
    low = circ_noise(n, "alert_high/low", lambda f: lp(f, 180, 2))
    out += 0.25 * low * ad(t, 0.004, 0.16)
    return out * fade_out(t, 0.92, 1.15)


def build_siren_pass() -> np.ndarray:
    """One unit going past: a wail, a bell-curve level, and a doppler bend."""
    n, t = times(3.00)
    centre = 1.50
    doppler = 1.0 - 0.065 * np.tanh((t - centre) / 0.42)
    wail = 620.0 + 340.0 * (0.5 - 0.5 * np.cos(2 * np.pi * 0.85 * t))
    phase = 2 * np.pi * np.cumsum(wail * doppler) / SR
    tone = (np.sin(phase) + 0.38 * np.sin(3 * phase) + 0.16 * np.sin(5 * phase)
            + 0.07 * np.sin(7 * phase))
    level = np.exp(-((t - centre) / 0.88) ** 2)
    road = circ_noise(n, "siren/road", lambda f: lp(f, 700, 1.6) * hp(f, 70, 1))
    body = 0.72 * tone * level + 0.22 * road * level
    return dc_kill(body) * fade_out(t, 2.70, 3.00)


def build_level_fanfare() -> np.ndarray:
    """City level up. Four notes and a held chord — short enough to stay welcome."""
    n, t = times(2.00)
    out = np.zeros(n)

    def brass(seg: np.ndarray, freq: float, dec: float) -> np.ndarray:
        v = np.zeros_like(seg)
        for k in range(1, 7):
            v += np.sin(2 * np.pi * freq * k * seg) / (k ** 1.5)
        return v * ad(seg, 0.030, dec)

    for at, freq, amp, dec in ((0.00, 523.3, 0.50, 0.28),
                               (0.130, 659.3, 0.52, 0.28),
                               (0.260, 784.0, 0.56, 0.30),
                               (0.420, 1046.5, 0.62, 0.85)):
        seg = np.maximum(t - at, 0.0)
        out += amp * (t >= at) * brass(seg, freq, dec)
    chord_at = 0.42
    seg = np.maximum(t - chord_at, 0.0)
    for freq, amp in ((261.6, 0.30), (392.0, 0.22), (523.3, 0.18)):
        out += amp * (t >= chord_at) * np.sin(2 * np.pi * freq * seg) * ad(seg, 0.055, 0.75)
    air = circ_noise(n, "fanfare/air", lambda f: bp(f, 4200, 1.6))
    out += 0.06 * air * ad(t, 0.010, 0.30)
    return out * fade_out(t, 1.65, 2.00)


# ---------------------------------------------------------------------------
# The set
# ---------------------------------------------------------------------------
# `peak` is the authored mix level: the WAV already carries the relative balance
# so `data/audio.json` only ever needs a trim, never a rescue.
#
# `rate` is chosen per asset from its own bandwidth. `verify_bandwidth()` then
# measures the rendered spectrum and fails anything pushed against its own
# Nyquist, so a future edit that adds sparkle to a half-rate bed is caught here
# rather than shipping as aliasing.

SPECS = [
    # name,                builder,                  peak, loop,  rate
    ("ui_tap",             build_ui_tap,             0.34, False, SR_FULL),
    ("ui_confirm",         build_ui_confirm,         0.46, False, SR_FULL),
    ("ui_deny",            build_ui_deny,            0.42, False, SR_HALF),
    ("purchase",           build_purchase,           0.62, False, SR_FULL),
    # Wave 14's payday. FULL rate on purpose: the disc partials run to 4.72 ×
    # 2.98 kHz = 14.1 kHz, which is the top half of the band and the whole
    # reason a coin reads as a coin.
    ("cash",               build_cash,               0.56, False, SR_FULL),
    ("construct_stage",    build_construct_stage,    0.26, False, SR_FULL),
    ("construct_complete", build_construct_complete, 0.58, False, SR_FULL),
    ("blackout_whomp",     build_blackout_whomp,     0.88, False, SR_HALF),
    ("relight_hum",        build_relight_hum,        0.70, False, SR_HALF),
    ("thunder_crack",      build_thunder_crack,      0.92, False, SR_FULL),
    ("thunder_rumble",     build_thunder_rumble,     0.74, False, SR_HALF),
    # rain_loop stays at the FULL rate: measured, 6.0% of its energy sits in the
    # top band at 22.05 kHz, because rain genuinely *is* hiss out past 7 kHz.
    # Halving its rate would have bought 0.5 MB by dulling the one asset whose
    # whole character is brightness.
    ("rain_loop",          build_rain_loop,          0.52, True,  SR_FULL),
    ("wind_loop",          build_wind_loop,          0.46, True,  SR_HALF),
    ("storm_wind",         build_storm_wind,         0.58, True,  SR_HALF),
    ("amb_city_day",       build_amb_city_day,       0.40, True,  SR_HALF),
    ("amb_city_night",     build_amb_city_night,     0.30, True,  SR_HALF),
    # 6 s, deliberately, while the atmospheric beds went to 12: a crane loop is
    # SUPPOSED to be periodic — that is what makes it read as machinery — so the
    # extra bytes would buy nothing an ear could use.
    ("site_loop",          build_site_loop,          0.44, True,  SR_HALF),
    ("alert_low",          build_alert_low,          0.50, False, SR_HALF),
    ("alert_high",         build_alert_high,         0.68, False, SR_FULL),
    ("siren_pass",         build_siren_pass,         0.64, False, SR_HALF),
    ("level_fanfare",      build_level_fanfare,      0.58, False, SR_FULL),
]


# ---------------------------------------------------------------------------
# Verification, encoding, IO
# ---------------------------------------------------------------------------

def verify_loop(x: np.ndarray) -> dict:
    """Measure the loop point against the buffer's own sample-step statistics.

    A seam is only audible when the step across it is unlike every other step in
    the buffer, so the honest metric is a *ratio*, not an absolute. Two orders:
    `ratio` on the sample step (a click) and `ratio_d2` on the change in step
    (a discontinuity in slope, which reads as a thump).
    """
    step = np.abs(np.diff(x))
    typical = float(np.median(step)) or 1e-12
    seam = float(abs(x[0] - x[-1]))
    d_head = x[1] - x[0]
    d_seam = x[0] - x[-1]
    d_tail = x[-1] - x[-2]
    curve = np.abs(np.diff(np.diff(x)))
    typical_d2 = float(np.median(curve)) or 1e-12
    seam_d2 = float(max(abs(d_head - d_seam), abs(d_seam - d_tail)))
    return {
        "seam_delta": seam,
        "seam_ratio": seam / typical,
        "seam_ratio_d2": seam_d2 / typical_d2,
    }


def verify_bandwidth(x: np.ndarray) -> float:
    """Fraction of energy in the top 15% of the band, up to Nyquist.

    An asset filed under a rate its content does not fit shows up here twice
    over: as the content itself crowding Nyquist, and as any alias folded back
    down from a sinusoid synthesised above it.
    """
    spec = np.abs(np.fft.rfft(x)) ** 2
    total = float(spec.sum()) or 1e-12
    return float(spec[int(0.85 * (spec.size - 1)):].sum()) / total


def to_pcm16(x: np.ndarray, peak: float) -> np.ndarray:
    x = np.asarray(x, dtype=np.float64)
    top = float(np.max(np.abs(x)))
    if top > 0.0:
        x = x * (peak / top)
    x = np.clip(x, -1.0, 1.0)
    return np.round(x * 32767.0).astype("<i2")


def wav_bytes(pcm: np.ndarray, loop: bool, rate: int) -> bytes:
    """RIFF/WAVE, mono 16-bit, with a `smpl` chunk on loops.

    Godot's WAV importer defaults `edit/loop_mode` to "Detect From WAV", so the
    `smpl` chunk below is what makes a bed loop with no `.import` edit and no
    runtime patching — the asset carries its own loop, which is the only place
    that fact cannot drift away from the samples it describes.
    """
    data = pcm.tobytes()
    fmt = struct.pack("<4sIHHIIHH", b"fmt ", 16, 1, 1, rate, rate * 2, 2, BIT_DEPTH)
    chunks = [fmt, struct.pack("<4sI", b"data", len(data)) + data]
    if len(data) % 2:
        chunks[-1] += b"\x00"
    if loop:
        smpl = struct.pack("<4sIIIIIIIII", b"smpl", 36 + 24, 0, 0,
                           int(round(1e9 / rate)), 60, 0, 0, 0, 1) + struct.pack("<I", 0)
        smpl += struct.pack("<IIIIII", 0, 0, 0, pcm.size - 1, 0, 0)
        chunks.append(smpl)
    body = b"WAVE" + b"".join(chunks)
    return struct.pack("<4sI", b"RIFF", len(body)) + body


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=DEFAULT_OUT)
    parser.add_argument("--check", action="store_true",
                        help="build and verify without writing anything")
    args = parser.parse_args(argv)

    global SR
    entries = []
    total = 0
    problems = []
    for name, builder, peak, loop, rate in SPECS:
        SR = rate                      # every helper below builds at this asset's rate
        raw = builder()
        pcm = to_pcm16(raw, peak)
        blob = wav_bytes(pcm, loop, rate)
        total += len(blob)
        top_energy = verify_bandwidth(pcm / 32767.0)
        # Only a REDUCED rate can be the wrong choice. A full-rate asset with
        # energy near 20 kHz is just broadband — there is no higher rate to move
        # it to, and nobody can hear it there anyway.
        if rate < SR_FULL and top_energy > 0.01:
            problems.append("%s: %.2f%% of its energy is against Nyquist at %d Hz — "
                            "file it at %d Hz" % (name, 100.0 * top_energy, rate, SR_FULL))
        entry = {
            "name": name,
            "file": "%s.wav" % name,
            "samples": int(pcm.size),
            "sample_rate": rate,
            "seconds": round(pcm.size / rate, 6),
            "bytes": len(blob),
            "loop": bool(loop),
            "top_band_energy": round(top_energy, 8),
            "peak": round(float(np.max(np.abs(pcm)) / 32767.0), 6),
            "rms": round(float(np.sqrt(np.mean((pcm / 32767.0) ** 2))), 6),
        }
        if loop:
            # Verified on the *encoded* samples: quantisation is the last thing
            # that touches the seam, so it is the thing that has to be measured.
            entry.update({k: round(v, 6) for k, v in verify_loop(pcm / 32767.0).items()})
            if entry["seam_ratio"] > 8.0 or entry["seam_ratio_d2"] > 8.0:
                problems.append("%s: loop seam is discontinuous (%.2f / %.2f)"
                                % (name, entry["seam_ratio"], entry["seam_ratio_d2"]))
        else:
            head = float(abs(pcm[0]) / 32767.0)
            tail = float(abs(pcm[-1]) / 32767.0)
            entry["head"] = round(head, 6)
            entry["tail"] = round(tail, 6)
            if tail > 0.002 or head > 0.02:
                problems.append("%s: one-shot does not start/end at silence "
                                "(head %.4f, tail %.4f)" % (name, head, tail))
        if entry["peak"] < 0.05:
            problems.append("%s: silent asset" % name)
        entries.append((entry, blob))

    if total > TOTAL_BUDGET_BYTES:
        problems.append("total %d bytes exceeds the %d byte budget"
                        % (total, TOTAL_BUDGET_BYTES))

    manifest = {
        "_comment": ("Generated by tools/gen_audio.py — do not hand-edit. "
                     "doc 11 §2.15 owns audio; tests/test_audio_model.gd reads "
                     "this manifest for the size budget and the loop-seam proof."),
        "generator": "tools/gen_audio.py",
        "sample_rates": sorted({int(spec[4]) for spec in SPECS}),
        "bit_depth": BIT_DEPTH,
        "channels": 1,
        "total_bytes": total,
        "budget_bytes": TOTAL_BUDGET_BYTES,
        "assets": [e for e, _ in entries],
    }

    for e, _ in entries:
        print("%-20s %7.3f s %6d Hz %8d B %s"
              % (e["name"], e["seconds"], e["sample_rate"], e["bytes"],
                 "loop" if e["loop"] else ""))
    print("-" * 52)
    print("%-20s %7.3f s %8d B  (%.1f%% of budget)"
          % ("TOTAL", sum(e["seconds"] for e, _ in entries), total,
             100.0 * total / TOTAL_BUDGET_BYTES))
    for e, _ in entries:
        if e["loop"]:
            print("  loop seam %-16s ratio %.2f  slope-ratio %.2f"
                  % (e["name"], e["seam_ratio"], e["seam_ratio_d2"]))

    if problems:
        for p in problems:
            print("FAIL " + p, file=sys.stderr)
        return 1

    if args.check:
        print("check only — nothing written")
        return 0

    os.makedirs(args.out, exist_ok=True)
    for entry, blob in entries:
        with open(os.path.join(args.out, entry["file"]), "wb") as handle:
            handle.write(blob)
    with open(os.path.join(args.out, "manifest.json"), "w") as handle:
        json.dump(manifest, handle, indent="\t", sort_keys=False)
        handle.write("\n")
    print("wrote %d assets + manifest.json to %s" % (len(entries), args.out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
