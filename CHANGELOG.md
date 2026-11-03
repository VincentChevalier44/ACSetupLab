# Changelog

## 1.0.0-beta.1.5.4 — 2026-11-03 — beta 1.5.4: new interface, one click everywhere, a guided flow, race start of your choice, in-game update

Why this update: loading took two clicks, trial files piled up in the setups folder, and the race could not resume after an AC restart. Now each step is one click, only the versions you validate stay, the race starts from the qualifying version you choose, and SetupLab can update itself.

- **Loading in one click**: "Load" puts the setup in the car at once, in the pits; the "Confirm" step is gone. A backup copy of the current setup is still saved just before, when it is useful (not when the car holds a setup SetupLab put in it, unchanged). A double click does not load twice.
- **Choosing your start loads it**: "Resume my reference" or "Car's default setup" puts that setup in the car in the same click.
- **"Try" puts the version in the car**: "Try vN" loads the proposed setup at once, in the pits. Its trial file goes to the Recycle Bin as soon as the load is checked, so only the versions you validate stay in your setups folder.
- **"Start over" puts your previous setup back**: refusing the version that is in the car loads the setup you had before (your reference, or the backup copy made before the trial).
- **"Validate" always puts the kept version in the car**: after the trial with some settings refused, or validated without a trial ("Validate without trying · puts it in the car"). The refinement carries on from it and your laps judge it. If the car is not ready (setup menu closed), the version is still validated and the reason is shown under "Load".
- **After each validation, SetupLab asks**: "Carry on refining" (a new version with your next laps) or "Lock vN". Nothing new is computed until you answer; restarting the refinement counts as carrying on.
- **Race start of your choice**: the RACE tab lists your validated qualifying versions on this track (v1, v2, v3...), including those validated during an earlier AC launch. "Start from qualifying vN" puts it in the car and starts the race refinement in one click. Other SetupLab qualifying files are still recognised when you load them from AC's setup menu.
- **"Resume my race vN"**: a race setup validated earlier goes back into the car and its refinement carries on from it (numbering continues).
- **A SetupLab setup loaded from AC's menu becomes the reference**: when the car holds exactly one of your kept SetupLab files (memory reference or validated version), its differences with the previous setup are no longer taken as your own tweaks. Setting a tweaked value back by hand releases it too, and so does a SetupLab load that changes that setting.
- **Refused aid levels are remembered (wet track)**: an ABS or traction control level you refuse in "Modify…" is no longer proposed by the next versions (until "Release your changes"), and "Validate" puts the kept levels back in the car.
- **In-game update**: once per AC launch, SetupLab reads the latest version number on GitHub (setting "Check for updates at launch", ticked by default). If it is newer, an "Update" button appears at the top of the window, to click in the pits with the car stopped; nothing is downloaded without your click. SetupLab then downloads the release archive, checks its size, SHA-256 fingerprint and content, and replaces the app's files in one go (the previous ones are put back if anything fails). Files of the old version that no longer exist go to the Recycle Bin. CSP then reloads the app, which comes back on standby. No game or personal data is sent; GitHub only sees your IP address, as for any web page. To go from 1.5.2 to 1.5.4, install by hand one last time.
- **Laps with an incident no longer count**: a spin, a big slide of the rear, a wheel lock-up under braking (ABS not working), an impact (damage), a car reset or a track cut now rejects the recorded lap, with its reason shown. Such a lap no longer counts as a clean lap and no longer skews the calibration. The computation engine itself is unchanged.
- **New interface, "Racing 26"**: every page has a new layout.
  - Header with the logo, car and track, session and conditions, pits / track / standby state, language and the Active switch; tabs with counters.
  - Step card: big title, 4 labelled steps, your times, target and predicted delta, one main button, and Start over and Lock as icon buttons (their name shows on hover).
  - Panels: proposed settings (Kept | Refused under "Modify…"), balance by corner speed, hot tyres, simulated speed, versions; start choice cards with the track and conditions; race start card, stint and pit strategy; memory grid; measurement; settings with switches and steppers (no more clipped labels); diagnostics; help; overlay and debug windows.
  - Two columns from 640 px wide, everything stacked below.
  - Near-black background, cut-corner panels, cyan action colour, racing colours (green gain, amber to confirm, red loss). Fonts shipped with the app: Barlow, Barlow Condensed and JetBrains Mono (SIL Open Font License 1.1, in `fonts/`); without them, the app keeps Segoe UI.
- New app logo.

## 1.0.0-beta.1.5.2 — 2026-11-02 — beta 1.5.2: race setup from your qualifying setup, pit strategy, window back

Why this update: some players closed the SetupLab window with its X and could not get it back, even after reinstalling. After loading a qualifying setup, the race setup waited for a new qualifying version or more laps instead of starting from the setup in the car, and the pit stop menu kept its own tyre pressures. **To update, delete the old `SetupLab` folder first**, then extract the new archive (see the README).

- **Race setup from any of your numbered SetupLab qualifying setups**: v1, v2, v3..., trials and best-lap names included, from an earlier session too (AC restarted). The one in the car is recognised by its values, even after AC re-saved it from its menu; otherwise the RACE tab lists them and asks to load one from AC's setup menu.
- **First race version straight away**: with SetupLab active in a race session, the first race version is computed as soon as a SetupLab qualifying setup is in the car, without extra laps (your laps with it were driven in qualifying); the next race versions wait for the minimum of clean laps. A setup loaded from AC's menu after the discovery is recognised at once (the car's setup is re-read in the pits).
- **Race computed from the qualifying setup in the car, even during a qualifying refinement**: "Compute the race setup" while qualifying is being refined makes the race the active refinement; it starts at once from the qualifying setup in the car (v1, v2...), without waiting for a next qualifying version. The step card and the overlay follow the race and name the setup it starts from. Qualifying keeps its versions and can be resumed from the QUALIFYING tab. A qualifying computation in progress (for example with "first setup right away" ticked) is interrupted instead of running first, and redone when qualifying is resumed.
- **Pit strategy**: when SetupLab loads a race setup (two clicks in the pits), the selected quick pit preset gets its tyre pressures and tyres, so a tyre change is planned at the stop; it is also done when that race setup was already in the car. Fuel and repairs are left as you set them. A compound missing from the pit menu is not set, and anything the game refuses is reported (RACE tab and J0 report, with the values read back from the menu). A setup loaded from AC's menu does not change the pit menu.
- **Main window back on the setup screen**: its close button is removed, and its internal name changes so CSP shows it again for players who had closed it (it was saved as closed outside the app folder, so reinstalling did not help). Its position and size reset once.
- Overlay: says where the "SetupLab active" checkbox is (SetupLab window, setup screen).
- New app icon.
- **Your tweaks are measured from the last setup SetupLab loaded**: loading the race setup after a qualifying setup no longer turns every difference between the two into a "tweak" kept by the next qualifying versions.
- **Step card in its own tab**: the step card (Start, Drive, Try, Validate) only shows in the tab it is about (QUALIFYING or RACE), no longer in the other tabs; in a race session the window opens on the RACE tab.
- **Buttons easier to see**: buttons without a colour (Lock, Start over, Validate vN, Validate without trying, Modify...) now have a lighter fill and a thin blue outline, so they no longer look like plain text inside the cards.
- **Journal in CSP's log**: each line of SetupLab's journal is also written to CSP's log (`Documents\Assetto Corsa\logs\custom_shaders_patch.log`, lines `[Lua: App: SetupLab]`), on one line and at the same rate, so a session can still be checked after AC is closed (CSP replaces that file when AC starts again). The lines are in French, like the J0 report.
- Tried in game on CSP 0.3.2-preview2: qualifying versions, race setup from the qualifying setup in the car, pit strategy. 349 offline tests.

## 1.0.0-beta.1.5.1 — 2026-10-29 — beta 1.5.1: clear feedback after each lap, CSP 0.3.1 compatibility

Why this update: in game, after a clean lap, SetupLab looked as if it had not seen the lap. It had counted it and was computing, but said nothing while computing, and nothing at all when the current setup was already the best it could find. Custom Shaders Patch 0.3.1-preview2 also changed two things SetupLab relied on.

- **Clear feedback after each lap**: the overlay, the step card and the window now say "clean lap counted", then "computing the setup; I keep analysing your laps" (in blue) until the version is announced. When your setup is already the best found (possible gain under 0.05 s), it is said, with one on-screen announcement. A lap that is not counted while SetupLab waits for its minimum is announced on screen with its reason (off track, lap invalidated by AC, brake bias changed while driving, pit lane...).
- **CSP 0.3.1-preview2: precise clock**: this CSP blocks the Windows clock SetupLab used to time its computation, which fell back to a fixed amount of work per frame (slower computations, possible small stutters, frame cost shown as 0 ms). SetupLab now uses CSP's own precise clock (`os.preciseClock`) instead; the DIAGNOSTICS tab and the J0 report say which clock is in use.
- **CSP 0.3.1-preview2: wing heights in millimetres**: CSP now reports wing ground heights in millimetres, so the ride-height reference was refused and ride height was never optimised. They are now read correctly, and ride height is optimised again (reduced search).
- With CSP 0.3.1-preview2, local time is not available to apps: saved file names use UTC time (`..._13h31m42sUTC.ini`).
- Tried in game on CSP 0.3.1-preview2. Over 320 offline tests.

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
- **New interface**: SETUPLAB header with version, EN/FR badge and "SetupLab active"; uppercase tabs (QUALIFYING, RACE, MEMORY, MEASURE, SETTINGS, DIAGNOSTICS, HELP) with the active tab underlined in blue; a "Step N/4" card always at the top with the button for the next step; more compact content; a HELP tab.
- **English and French**: English by default, French with one click. Everything is translated: menus, buttons, messages, on-screen announcements, hover help, overlay and debug window. Help on hover for every app setting. Setting explanations are written in both languages.
- **File names follow the language**: `SetupLab_Quali_v1.ini`, `_Race`, `_Wet`, `_trial`, `SetupLab_Before_load_…` in English; the French names are unchanged. Version numbers continue across both languages; existing files are still recognised.
- **Documentation**: user guide in English (`docs/notice.html`) and French (`docs/notice.fr.html`), both in the archive; README and changelog in English.
- **Tried in game.**
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
