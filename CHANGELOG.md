# Changelog

## 1.0.0-beta.1.5.8 — 2026-11-05 — beta 1.5.8: repository renamed SetupLab

Why this update: the GitHub repository is now named **SetupLab** (it was ACSetupLab). SetupLab now uses the new addresses directly, without going through GitHub's redirects. Nothing else changes. From 1.5.4, click **Update** in the SetupLab window; from 1.5.2 or older, delete the old `SetupLab` folder first, then extract the archive (see the README).

- In-game update: SetupLab reads the latest version at `github.com/VincentChevalier44/SetupLab` and downloads from there. The version file (`update.txt`) keeps a line with the old address for the versions 1.5.4 to 1.5.7 already installed, so they still find this update.
- Links in the app (HELP tab), the README and the user guide point to `github.com/VincentChevalier44/SetupLab`. The online user guide is now at `vincentchevalier44.github.io/SetupLab/notice.html` (the old address no longer works).
- Offline test bench: 422 tests.

## 1.0.0-beta.1.5.7 — 2026-11-05 — beta 1.5.7: online mode, race setup refined during the race

Why this update: SetupLab paused online; and in a race you start on the grid, without the setup menu, so SetupLab could not be used there, and the RACE tab needed a validated SetupLab qualifying setup first. Now SetupLab works online exactly as offline, and the race itself is analysed lap after lap: SetupLab offers a race setup at the finish, for your next race. From 1.5.4, click **Update** in the SetupLab window; from 1.5.2 or older, delete the old `SetupLab` folder first, then extract the archive (see the README).

Online mode:

- **SetupLab works online exactly as offline**, in every session, race included: same steps, versions, files, announcements and loads. Nothing is sent to the server. A setup imposed by the server is not loaded, as offline.
- New setting **Active online** (SETTINGS tab), ticked by default. Untick it if a league's rules forbid apps: SetupLab then pauses online. While it is paused for that reason, an **Enable SetupLab online** button appears under the pause banner, on every tab.
- **Traffic filter, online and offline (AI cars included)**: outside a race session, a lap with another car less than 40 m ahead or 8 m behind for more than 2 s in total is not counted (slipstream, blocking): it no longer skews the calibration or the clean-lap count. The J0 report shows the online state and the number of laps rejected for traffic.

Race setup refined during the race:

- **New window "SetupLab Track"**, opened from the CSP app bar while driving: the same interface as the setup-menu window. When the setup-menu window is shown, it gives way and shows a single line, so a click is never handled twice.
- **RACE tab, in a race session: "Refine during the race"** (or SetupLab Active) starts from the setup in the car, without a SetupLab qualifying setup. The lap count is read from the session (estimated from the duration and the simulated lap time for a timed race); a count you set during the race is kept until the next session. Outside a race session, the race still starts from a validated qualifying setup.
- **Race laps in traffic count for the race**: in a race session, a lap driven close to another car is kept and marked "in traffic". It counts for the race refinement (pace, fuel use, wear, tyres) and in the lap counts shown ("12 race laps analysed (9 in traffic)"), never for the calibration, the qualifying lap or the best lap of a setup. Outside a race session, such a lap is still rejected. The lap after the chequered flag does not count.
- **Nothing is loaded once the race has started**, pit stop included: no "Try", no "Load", "Start over" does not put a setup back, and "Validate" only saves the file, for your next race (it becomes the race reference on this track). Before the start, nothing changes: you can still start from the qualifying version of your choice and try the race v1 in the pits.
- **Laps with a driving incident count for the race too**: in a race session, a lap with an off-track, a cut, a spin, a big slide, a wheel lock-up, an impact or invalidated by AC is kept and marked (it counts for the race refinement, never for the calibration or the qualifying lap). A lap through the pit lane, or after the car was reset to the track, is still rejected. Outside a race session, nothing changes.
- **The race setup is computed once, at the finish**: during the race session SetupLab only analyses your laps (no computation slowing the game down); a few seconds after your own chequered flag (not the leader's), once your last lap is recorded, it computes the setup from the whole race and announces it once: "race setup vN for your next race", with the laps analysed. Exceptions: the "Compute the race setup" button, and, before the start, starting from a SetupLab qualifying version (its race v1 is computed at once so you can try it in the pits). The overlay says the same. The start and the finish of the race are written to the log.
- **The setup you load counts**: in a race session, a setup loaded or changed in AC's setup menu (car stopped) is read again on its own after about 1.5 s and becomes the base of the race refinement, whatever it is. Fuel and brake bias do not count. Outside a race session, nothing changes.
- **After your flag, the computation runs at full speed**: below 60 frames per second SetupLab normally keeps a quarter of its share of each frame, which made the race computation take 5 to 10 minutes; after your finish it uses its full share (about 1 to 2 minutes; the cool-down lap may be slightly less smooth meanwhile). The step card shows "Race finished · computing the race setup" with its progress, and the bottom panel says "Refinement computation" instead of "Manual computation".
- **Choosing a race start turns SetupLab on**: "Refine during the race", "Start from qualifying vN" and "Resume my race vN" switch the Active toggle on, like choosing a qualifying start.
- In-app help and user guide: new "During a race" section.
- Offline test bench: 421 tests. Tried in game: the online mode, and a full race refined from the grid (setup loaded from AC's menu, laps in traffic and with incidents counted, race setup computed at the finish, validated and loaded after the race).
- DIAGNOSTICS tab: the pit strategy line is translated into English again after a race setup is loaded.

## 1.0.0-beta.1.5.6 — 2026-11-03 — beta 1.5.6: no longer inactive with the free CSP 0.2.11

Why this update: with Custom Shaders Patch 0.2.11 (the free version installed by Content Manager), SetupLab stayed inactive and showed "Context unreadable: flag unreadable: isAltOnlineRace" ([issue #1](https://github.com/VincentChevalier44/SetupLab/issues/1)). This CSP does not have that flag at all. From 1.5.4, click **Update** in the SetupLab window; from 1.5.2 or older, delete the old `SetupLab` folder first, then extract the archive (see the README).

- CSP 0.2.11: the alt-online flag (`isAltOnlineRace`: a fake online race driven by a New Modes script) does not exist in this CSP, so SetupLab now reads it as "not an alt-online race" instead of staying inactive. Such a race needs a newer CSP, which has the flag. The three other safety flags (online race, replay, replay-only mode) exist in 0.2.11 and still make SetupLab inactive when they cannot be read.
- Offline test bench: the simulated CSP 0.2.11 now lacks this flag, like the real one (checked against the 0.2.11 SDK), and the full cycle runs on it: discovery, computation, Validate, load in the pits.

## 1.0.0-beta.1.5.5 — 2026-11-03 — beta 1.5.5: overlay bar (lock, reduce, close), version announced from your own setup, local time in file names

Why this update: CSP's title bar cut the top of the overlay, which could not be locked in place; starting from your own setup or the default one, the overlay did not say when v1 was ready; saved file names were in UTC with CSP 0.3.1 and newer; a race refinement waiting for its number of laps had nowhere to enter it; the overlay showed during replays. From 1.5.4, click **Update** in the SetupLab window; from 1.5.2 or older, delete the old `SetupLab` folder first, then extract the archive (see the README).

- RACE tab: the number of race laps can be set under the step card while the race refinement runs (it was only in the start card, so a race refinement waiting for its laps had nowhere to enter them).
- SETTINGS tab: the "Setup settings" table folds, closed by default (click its header).
- In-game overlay: nothing is shown during a replay.
- In-game overlay: new SetupLab bar instead of CSP's title bar, which cut the top of the overlay. It shows the setup on track (or SetupLab's state) and three buttons: a padlock that locks the overlay in place (position and size), reduce (the bar alone, with the gap on your laps) and close (the CSP app bar opens it again). Drag the bar to move the overlay. The padlock and the reduced state are kept from one session to the next. AC must be restarted once for the window to lose CSP's title bar.
- In-game overlay: a proposed version is announced ("v1 ready", predicted gain, "back to the pits: Try v1") even when the car still has your own setup or the default one. Before it, the overlay shows what is left to do (for example the clean laps still needed).
- Saved file names use your local time again with CSP 0.3.1 and newer: CSP now blocks the Windows call SetupLab used, so the local time is read through Lua's `os.date` (read only). They were in UTC.
- Debug window: only the visible log lines are drawn, the others only count for the height.
- Without the "Racing 26" theme (fallback display): coloured buttons keep readable text when pressed (contrast of at least 5:1), with the theme's colours.

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
