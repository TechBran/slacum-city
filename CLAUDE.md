# SLACUM CITY

Persistent urban survival city builder for Android (working spec: `docs/BLACKOUT-spec.md`).
**Read `docs/design/00-constitution.md` first — it locks engine, architecture, time model, units, and determinism rules. It overrides everything else.**

## Stack

- Godot **4.7.2 stable**, typed GDScript, Mobile (Vulkan) renderer. Binary: `~/.local/bin/godot`.
- Android export: SDK at `~/Android/Sdk` (targetSdk 37, minSdk 29), export templates installed for 4.7.2.
- No external plugins; custom minimal test runner.

## Commands

```bash
# Run all headless sim tests (the path has spaces — always quote it):
~/.local/bin/godot --headless --path "/home/bbx/Slacum City game" -s res://tests/run_tests.gd

# Run the game in editor runtime (needs display):
~/.local/bin/godot --path "/home/bbx/Slacum City game"
```

## Layout

- `sim/` — engine-agnostic simulation core (RefCounted only; no Node/Input/OS imports; time & RNG injected).
- `game/` — 3D scenes, rendering, vehicles, weather VFX, camera.
- `ui/` — HUD, overlays, panels.
- `data/` — ALL balance numbers as JSON. No magic numbers in code.
- `tests/` — headless tests; every sim system has them.
- `docs/design/` — numbered subsystem design docs (00 = constitution, 99 = master plan).

## Rules

- Sim never imports scene/rendering code; renderer reads sim via snapshots/events; UI issues commands.
- Deterministic: named RNG streams, injected clock, no wall-clock reads in `sim/`.
- Design docs stay truthful: if code diverges from a doc, update the doc in the same change.
- Tests must pass before any commit.
