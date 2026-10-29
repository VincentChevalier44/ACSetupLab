# Changelog

## 1.0.0-beta.1.5 — 2026-10-26 — beta 1.5: guided flow, settings one by one, race after qualifying, new interface, English

- **Guided flow in 4 steps**: Start, Drive, Try, Validate, with the same names everywhere, and one main button at a time.
- **Starting point (step 1)**: "My current setup" (the one in the car: yours or the default one), "Car's default setup" (each setting at its default value, written to `SetupLab_Default.ini` and loaded in the pits; fuel, compound and car-script settings kept) or "Resume my reference" (unlocking it if locked). Choosing activates SetupLab and clears the kept hand changes; nothing is proposed before the starting setup is in the car. "Change the starting point" chooses again.
- **Validate in one click, or modify**: everything is kept by default; "Modify…" lists the changed settings one by one under their family, each kept or refused with one click (for example, refuse the rear wing only).
- **RACE tab locked** until a qualifying version is validated, with a button to the QUALIFYING tab.
- **What SetupLab takes into account**, in the SETTINGS tab: weather and track (air and track temperature, grip, wet), track profile from the simulated lap (slow, medium and fast corners, chicanes, longest straight, share of full throttle, braking, fast and slow corners), settings optimised and kept.

- **When SetupLab proposes a setup**, at the top of the SETTINGS tab: "First setup right away, from the car and the track" (unticked by default; the next versions wait for the minimum), clean laps before a proposal (slider 0 to 10, 2 by default, 0 = right away) and driving minutes (0 by default) with the setup currently in the car; laps and minutes must both be reached, and they are counted again after each load. Progress is shown in the step card and the overlay.
- **Race setup from the qualifying setup**: the race computation now waits for a validated qualifying setup on the track (otherwise the practice one), loaded in the car, and for the race lap count. The RACE tab shows the three conditions, a button to load the qualifying setup and a lap slider; the lap count is kept per car and track.
- **Trial before validation**: "Try vN" writes the proposed setup into a trial file to load in the pits; after driving, "Validate vN" saves the kept settings. Refused settings keep their old value in the next computations ("Release your changes" frees them). Everything kept: the trial file is renamed into the version; otherwise the trial file goes to the Recycle Bin. No new proposal while a trial is waiting.
- **Mod cars and tracks**: folder and file names with spaces, accents or brackets are accepted (car data, memory, saving); karting tracks from 200 m and long tracks up to 75 km (Nordschleife Endurance, Isle of Man); kart tyres; `AWD2` drivetrains; track curvature much less sensitive to a noisy AI line; road surface recognised under common names (ASP, ASPH, TARMAC), pit lane and low-grip surfaces ignored; track grip read from CSP checked (percent scale, out-of-range values ignored and shown); open layouts sampled up to just before the finish; springs and dampers kept when the tyres have no load sensitivity (old `tyres.ini` format).
- **Flow fixes from an adversarial review**: a refinement started by hand from a tab keeps its kind (race in practice, qualifying in a race session); stopping and restarting resumes the same versions; a new starting point sends abandoned trial files to the Recycle Bin; the step card covers a locked setup ("Unlock"), a version not kept still in the car, and a partial validation with the full trial still in the car; "Lock" refuses a version with no kept setting; one primary button at a time; version numbers never reuse a number kept in the track memory.
- **New interface** in the style of SuperHUD: SETUPLAB header with version, EN/FR badge and "SetupLab active"; uppercase tabs (QUALIFYING, RACE, MEMORY, MEASURE, SETTINGS, DIAGNOSTICS, HELP) with the active tab underlined in blue; a "Step N/4" card always at the top with the button for the next step; more compact content; a HELP tab.
- **English and French**: English by default, French with one click. Everything is translated: menus, buttons, messages, on-screen announcements, hover help, overlay and debug window. Help on hover for every app setting. Setting explanations are written in both languages.
- **File names follow the language**: `SetupLab_Quali_v1.ini`, `_Race`, `_Wet`, `_trial`, `SetupLab_Before_load_…` in English; the French names are unchanged. Version numbers continue across both languages; existing files are still recognised.
- **Documentation**: user guide in English (`docs/notice.html`) and French (`docs/notice.fr.html`), both in the archive; README and changelog in English.
- **Tried in game** with the Ferrari 488 GT3 (Kunos) at Spa.
- **Tests**: over 320, including the full flow replayed in English with every tooltip open (no French text may remain), the cost of the English interface, the effect buttons, the race panel, the language badge and the English file names.

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
