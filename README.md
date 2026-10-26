# SetupLab — setup generator for Assetto Corsa

**Version 1.0 — beta 1.5** (`1.0.0-beta.1.5`) · Lua app for Custom Shaders Patch (free version 0.2.11 or newer) · MIT licence

SetupLab computes, for every car and track, a **qualifying** setup (practice, track day, hotlap, time attack, qualifying) and a **race** setup (full stint). It explains every setting, fits its model to your own laps, and refines the setup while you drive: it proposes a version, you try it in the pits, keep or refuse each of its effects, and validate it.

The app is in **English by default**, with a full **French** translation (one click on the EN/FR badge).

📖 **User guide: [`docs/notice.html`](docs/notice.html)** (open it in a browser; it is also in the app archive, with the French version `docs/notice.fr.html`).

---

## Contents

- [Features](#features)
- [Installation](#installation)
- [Quick start](#quick-start)
- [What SetupLab never does](#what-setuplab-never-does)
- [Beta status and known limitations](#beta-status-and-known-limitations)
- [Development](#development)
- [Project structure](#project-structure)
- [Licence](#licence)

## Features

- **Qualifying and race setups** computed from the car's data files (tyres, aero, engine, gearbox, brakes, suspension, differential, DRS, ERS) and the track's AI line (curvature, slope, camber, DRS zones).
- **Every setting explained**: one sentence per proposed setting, its gain, the balance per corner; every untouched setting with its reason. Help on hover for every button and every app setting.
- **Built up step by step**: each proposed version is tried as a whole in the pits, then each effect (aero, tyres, geometry, suspension, transmission, brakes, engine, aids) is kept or refused with one click; the validated version holds only the kept effects. Refused effects keep their old value in the next computations.
- **A guided flow**: a "Step N/4" card always at the top (Drive, Try, Sort the effects, Validate) with the button for the next step.
- **Your times first**: your best lap (or average lap for the race), the estimated target and the real gain of each version. The model is calibrated on your laps.
- **Refinement while you drive**: tick **SetupLab active** and drive. A proposal only comes after a minimum of clean laps and minutes with the current setup (both adjustable). On track, SetupLab says once that it has the minimum information and keeps analysing; the version is ready when you return to the pits.
- **Race setup from your qualifying setup**: the race computation starts from the validated qualifying setup, loaded in the car, for the number of laps you enter.
- **In-game overlay**: while driving, whether the setup on track is better or worse than the previous one on your laps, the settings that changed most with their predicted gain, and what is left before the next proposal.
- **Track memory**: the validated or locked setup is kept per car, track, session (practice, qualifying, race) and track state (dry, wet), and offered on the next visit.
- **Rain** (CSP weather, Pure included): compound choice (slicks, intermediates, wets), pressures, wing, stricter driving aids; separate wet calibration.
- **Clear file names in the chosen language**: `SetupLab_Quali_v1.ini`, `SetupLab_Race_Wet_v3.ini`… (`SetupLab_Qualif_v1.ini`, `SetupLab_Course_Pluie_v3.ini` in French), numbered in sequence on the track; your best real lap with a qualifying version is added to its name. Only the versions you keep remain: trial files, versions not kept and useless copies go to the Recycle Bin.

## Installation

Requirements: Assetto Corsa with **Custom Shaders Patch 0.2.11** (the free version installed by Content Manager) or newer, previews included; offline mode.

1. Download the latest `SetupLab-….zip` from the [Releases](https://github.com/VincentChevalier44/ACSetupLab/releases).
2. Extract it into `assettocorsa/apps/lua/`: the archive already contains the `SetupLab/` folder. In the end, `assettocorsa/apps/lua/SetupLab/` holds `SetupLab.lua` and `manifest.ini` (no `SetupLab` folder inside another `SetupLab`). To update, replace the files: your settings and track memory are kept by CSP, outside this folder.
3. In game, open **SetupLab** from the app bar or the setup screen. Two more windows exist: **SetupLab Overlay** (on track) and **SetupLab Debug** (diagnostics).

## Quick start

1. Start an offline session (practice, track day, qualifying or race). Open SetupLab **with the car in the pits** and wait for "Discovery finished".
2. Tick **SetupLab active**, then drive clean laps.
3. When a version is ready, it is announced at the top of the screen. In the pits: **Try v1** writes the trial file, then **Load** and **Confirm** put it in the car.
4. Drive with it, then keep or refuse each effect and click **Validate v1**. Load the validated version and carry on: the refinement continues from it.
5. For the race, the RACE tab shows what is needed: a validated qualifying setup, loaded in the car, and the race lap count.

Every button, tab and setting is described in the [user guide](docs/notice.html).

## What SetupLab never does

- It never changes the content of a file or the game physics, and never overwrites a setup: each save is a **new file** in the car and track setups folder.
- It only writes **on your click**: "Try", "Save", "Validate", "Lock", plus a backup copy of the current setup just before a load, when useful.
- It never touches your own files. It only tidies files it wrote, intact (recognised by name and content fingerprint), with the car stopped: to the **Windows Recycle Bin** for sorted trial files, versions you do not keep and redundant backup copies; it **renames** a kept qualifying version to add your best lap. With CSP 0.2.11, the Recycle Bin is not yet available to apps: these files are deleted permanently.
- The car setup only changes on your explicit request: in the pits, car stopped, setup menu open, in two clicks, after a backup copy; only a file written by SetupLab can be loaded.
- No network access, no `os.*`, `loadstring` or `dofile`.
- It is inactive online and in replays.
- It trusts no data it reads (car files, game state, storage): everything is bounded and validated.

## Beta status and known limitations

This beta is built and checked on an **offline test bench** (over 300 tests: models, optimiser, interface, translation, loading, persistence, fuzzing). It has been tried in game on the DTM 2026 (WHK), but most of it has not yet been seen in game on other cars. To be confirmed in game:

- how closely the simulated lap matches AC (target: lap time within 2 %); until calibration reaches its thresholds, gains are indicative and the app says so;
- the rain model, which relies on assumptions: your wet laps calibrate it;
- the new 1.5 interface (tabs, step card, effect buttons).

Some settings are deliberately kept, with their reason shown: toe, coast and preload differential, packers, springs and dampers until a valid dry lap has measured the track roughness, ride height without a discovery in the pits, settings defined by a car's script (unknown effect).

The J0 report and the copied lap (DIAGNOSTICS and MEASURE tabs), meant for development, are in French. The source code comments are in French.

Feedback is welcome in the [Issues](https://github.com/VincentChevalier44/ACSetupLab/issues). For a problem, attach the report from the **DIAGNOSTICS** tab ("Copy the J0 report").

## Development

### Offline test bench

The bench loads `SetupLab.lua` **as is** into LuaJIT 2.1 (CSP's engine) through `lupa`, with a simulated CSP host (`tests/fakehost.lua`). State objects raise an error on an unknown field, like a CSP FFI structure; any undeclared global is an error.

Requirements: Python 3, preferably in a virtual environment (commands use `python -I`, which ignores user-installed packages):

```
python -m venv .venv
.venv\Scripts\activate
python -m pip install -r tests/requirements.txt
```

Data sets: the tests use cars and tracks from the game (Kunos and mod data files). **They are not published in this repository**: generate them from your own installation (with the repository placed in `assettocorsa/apps/lua/SetupLab/`):

```
python -I tests/tools/make_fixtures.py [assettocorsa_root]
```

| Type | Sets |
|---|---|
| Cars | `formula_k` (Kunos SDK), `lamborghini_huracan_gt3_evo2`, `urd_px1_aura` (URD mod, ERS), `whk_dtm_2026` (WHK mod, DRS) |
| Tracks (AI line `fast_lane.ai`) | Spa, Monza, Red Bull Ring GP, Nordschleife |

A missing car or track is skipped; the tests that use it fail.

```
python -I tests/run_tests.py              # linter and its self-tests, then every suite
python -I tests/run_tests.py --filter AU  # only the tests whose name contains "AU"
python -I tests/run_tests.py --soak       # + endurance: 1,000 chained discoveries
python -I tests/lint.py                   # linter only
python -I tests/package.py                # distribution archive dist/SetupLab-<version>.zip
```

Results are written to `tests/results.json`. Timing tests (budget per frame) measure in real time: a busy machine (Assetto Corsa running at the same time, for example) can make them fail.

### Translation

The source texts are French; the English interface comes from a dictionary in `tests/tools/lang/*.py`, generated into `src/lang_en.lua`:

```
python -I tests/tools/gen_lang.py         # regenerate src/lang_en.lua (the bench fails if it is out of date)
python -I tests/tools/extract_keys.py --missing   # French texts of the code with no translation yet
```

`tests/test_i18n.lua` replays the main flows in English, with every tooltip and section open, and fails on any French text left.

### Rules enforced by the linter

- only the glue (`SetupLab.lua`) reads CSP globals; modules receive the host as a parameter;
- the pure core only depends on the pure core;
- `os`, `load`, `loadstring` and `dofile` are forbidden;
- `ac.setSetupSpinnerValue` and `ac.saveCurrentSetup` are forbidden everywhere, `ac.loadSetup` everywhere except in `src/exporter.lua`;
- no unused local variable, no TODO, lines of at most 140 characters.

## Project structure

```
SetupLab.lua         CSP glue: injected host, callbacks, safeguards, background tasks, persistence, refinement
manifest.ini         CSP app manifest
icon.png
src/util.lua         pure core: maths, LUTs, INI, RNG, log, scheduler, dates, file names
src/config.lua       single schema of the settings, their help, internal constants
src/i18n.lua         interface language: translation of displayed texts
src/lang_en.lua      English dictionary (generated)
src/caps.lua         CSP capabilities, precise clock, local time, J0 report
src/datasource.lua   car / track / session / setup reading -> pure tables
src/track_model.lua  track model
src/car_model.lua    car model: tyres (dry and wet), aero, engine, brakes, suspension
src/laptime_sim.lua  quasi-static lap simulation
src/ers.lua          ERS: reading, battery, dynamic programming
src/ers_plan.lua     ERS: zones, options, steady state
src/setup_space.lua  setup steps <-> physical values, file rendering
src/optimizer.lua    optimiser, qualifying and race, compound choice
src/stint_sim.lua    stint simulation: fuel, wear, traffic
src/explain.lua      setting explanations (both languages), balance per corner
src/recorder.lua     lap recorder, your times per setup, export
src/calibration.lua  calibration, "measure only" mode
src/exporter.lua     writing new files, loading into the car
src/store.lua        validated persistence (settings, calibrations, track memory)
src/ui.lua           windows (read-only view of the state)
docs/                user guide (English and French)
tests/               offline bench, linter, dictionary, data set generator (never distributed)
```

## Licence

[MIT](LICENSE) © 2026 VincentChevalier44 (Vincent Chevalier).

Assetto Corsa is a trademark of Kunos Simulazioni. SetupLab is an independent project, not affiliated with Kunos Simulazioni or the authors of Custom Shaders Patch.
