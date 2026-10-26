# Changelog

## 1.0.0-beta.1.5 — 2026-10-26 — beta 1.5: effects one by one, race from qualifying, new interface, English

- **Minimum before a proposal**: two new settings, minimum clean laps (2 by default) and minimum driving minutes (0 by default) with the setup currently in the car; both must be reached, and they are counted again after each load. Progress is shown in the step card and the overlay.
- **Race setup from the qualifying setup**: the race computation now waits for a validated qualifying setup on the track (otherwise the practice one), loaded in the car, and for the race lap count. The RACE tab shows the three conditions, a button to load the qualifying setup and a lap slider; the lap count is kept per car and track.
- **Effects validated one by one**: "Try vN" writes the whole proposed setup into a trial file to load in the pits; after driving, each effect group (aero, tyres, geometry, suspension, transmission, brakes, engine, aids, other) is kept or refused with one click; "Validate vN (k/n effects)" saves only the kept effects. Refused effects keep their old value in the next computations ("Release your changes" frees them). Everything kept: the trial file is renamed into the version; otherwise the trial file goes to the Recycle Bin. No new proposal while a trial is waiting to be sorted.
- **New interface** in the style of SuperHUD: SETUPLAB header with version, EN/FR badge and "SetupLab active"; uppercase tabs (QUALIFYING, RACE, MEMORY, MEASURE, SETTINGS, DIAGNOSTICS, HELP) with the active tab underlined in blue; a "Step N/4" card always at the top with the button for the next step; more compact content; a HELP tab.
- **English and French**: English by default, French with one click. Everything is translated: menus, buttons, messages, on-screen announcements, hover help, overlay and debug window. Help on hover for every app setting. Setting explanations are written in both languages.
- **File names follow the language**: `SetupLab_Quali_v1.ini`, `_Race`, `_Wet`, `_trial`, `SetupLab_Before_load_…` in English; the French names are unchanged. Version numbers continue across both languages; existing files are still recognised.
- **Documentation**: user guide in English (`docs/notice.html`) and French (`docs/notice.fr.html`), both in the archive; README and changelog in English.
- **Tests**: over 300, including the full flow replayed in English with every tooltip open (no French text may remain), the cost of the English interface, the effect buttons, the race panel, the language badge and the English file names.

## 1.0.0-beta.1.4 — 2026-10-22 — beta 1.4: analysis until you return to the pits

- On track, a proposed version stays provisional: one announcement per version, "vN in preparation" ("I have the minimum information; I keep analysing your laps"), then each clean lap updates it without a new announcement.
- In the pits, it is announced as ready, with the number of clean laps analysed.

## 1.0.0-beta.1.3 — 2026-10-22 — beta 1.3: in-game overlay

- New "SetupLab Overlay" window: whether the setup on track is better or worse than the previous one on your laps, your last lap, the settings that changed most with their predicted gain, and the next version when ready.

## 1.0.0-beta.1.2 — 2026-10-22 — beta 1.2: works with the free CSP (0.2.11)

- Runs on Custom Shaders Patch 0.2.11 (the free version installed by Content Manager), not only on the paid previews.
- Installation fixed: extract the archive into `apps/lua/`.
- Tidy files: clear names (`SetupLab_Qualif_v1.ini`, `SetupLab_Course_Pluie_v3.ini`), version numbers continuous on the track, your best real lap added to the name of a kept qualifying version, unkept versions and redundant backup copies sent to the Recycle Bin.

## 1.0.0-beta.1 — 2026-10-22 — first public beta

- Qualifying and race setups computed and explained setting by setting, model calibrated on your laps.
- Refinement while you drive ("SetupLab active"), versions announced on screen, validation before any file is written, loading in the pits in two clicks, "Start over", "Lock".
- Your times (best lap, average, estimated target, real gain) and your own changes in the pits kept.
- Track memory per session and track state; rain (CSP, Pure); custom setup names.
- User guide in HTML.

The detailed development history before the public beta (internal versions 0.1.0 to 1.7.0) is kept outside this repository.
