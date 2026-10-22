-- Chaîne J5 complète depuis la colle (§9, §14.1) : tours roulés par le conducteur simulé, calibration
-- automatique, export du tour, validation du setup proposé, coût par frame, reconnaissance.
local T = require('t')
local Config = require('src/config')
local CarModel = require('src/car_model')
local Sim = require('src/laptime_sim')
local SetupSpace = require('src/setup_space')
local Fake = require('fakehost')

local tests = {}

local function boot(carId, trackId, opts)
  opts = opts or {}
  opts.car = require('fixtures/cars/' .. carId)
  opts.track = require('fixtures/tracks/' .. trackId)
  local h = Fake.new(opts)
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  h.texts = {}
  local function capture(text) h.texts[#h.texts + 1] = text end
  local text, wrapped, colored = h.ui.text, h.ui.textWrapped, h.ui.textColored
  h.ui.text = function(s) capture(s); return text(s) end
  h.ui.textWrapped = function(s) capture(s); return wrapped(s) end
  h.ui.textColored = function(s, c) capture(s); return colored(s, c) end
  return h, app
end

-- Une frame de jeu : le conducteur simulé avance (si profile ; la voiture quitte alors les stands),
-- puis l'app tourne.
local function frames(h, n, profile)
  for _ = 1, n do
    if profile then
      h.car.isInPit, h.car.isInPitlane = false, false
      Fake.drive(h, profile, 1 / 60)
    end
    h.sim.time = h.sim.time + 1000 / 60
    h.texts = {}
    script.SETUPLAB__UPDATE(1 / 60)
    script.SETUPLAB__MAIN(1 / 60)
  end
end

local function waitFor(h, predicate, profile, maxFrames)
  for i = 1, maxFrames or 40000 do
    frames(h, 1, profile)
    if predicate() then return i end
  end
  return nil
end

local function shown(h, pattern)
  for _, text in ipairs(h.texts) do
    if text:find(pattern, 1, true) then return text end
  end
  return nil
end

-- Profil « réel » : le setup de la découverte (écarts deltas, composé slot, carburant fuel, 30 L par
-- défaut) simulé avec des facteurs vrais, pneus à température (ou dans l'état donné par tyres :
-- tyreTemp, tyreKm, hotPressureF/R).
local function trueProfile(app, factors, deltas, tyres, slot, fuel)
  local d = app.discovery
  local setup = app.physicalSetup(d, deltas, slot)
  setup.fuel = fuel or 30
  local conditions = { airTemp = d.conditions.airTemp, roadGrip = d.conditions.roadGrip, surfaceGrip = d.conditions.surfaceGrip,
    factors = factors }
  for key, value in pairs(tyres or {}) do conditions[key] = value end
  local eff = assert(CarModel.configure(d.carBase, setup, conditions))
  local result, buf = Sim.run(d.trackModel, eff, nil)
  local profile = { p = {}, v = {}, time = result.time }
  for k = 1, d.trackModel.n do profile.p[k], profile.v[k] = d.trackModel.p[k], buf.v[k] end
  profile.p[#profile.p + 1], profile.v[#profile.v + 1] = 1, buf.v[1]
  return profile, eff
end

-- Pneus de l'hôte à leur température de fonctionnement et à la pression à chaud du modèle, pour le
-- setup monté (écarts deltas, composé slot) : dans AC, les pressions suivent le setup chargé.
local function warmTyres(h, app, deltas, slot, fuel)
  local d = app.discovery
  local setup = app.physicalSetup(d, deltas, slot)
  local compound = d.carBase.compounds[setup.compound]
  local temp = CarModel.operatingTemp(compound.front)
  for w = 0, 3 do
    h.car.wheels[w].tyreCoreTemperature = temp
    local cold = w < 2 and setup.pressureF or setup.pressureR
    h.car.wheels[w].tyrePressure = CarModel.hotPressure(cold, d.conditions.airTemp, temp)
    h.car.wheels[w].tyreVirtualKM = 0.5
  end
  h.car.fuel = fuel or 30
end

tests['M01 tour roulé -> enregistré -> calibration automatique'] = function()
  local h, app = boot('lamborghini_huracan_gt3_evo2', 'monza')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  warmTyres(h, app)
  local truth = { mu = 0.95, power = 0.97, drag = 1.04, lift = 1.0, brake = 1.0 }
  local profile = trueProfile(app, truth)
  -- tour de sortie (non enregistré), puis un tour complet
  T.ok(waitFor(h, function() return app.recorder.laps.last ~= nil end, profile), 'tour enregistré')
  local lap = app.recorder.laps.last
  T.ok(lap.valid, tostring(lap.reason))
  T.eq(lap.signature, app.discovery.signature, 'tour rattaché au setup de la découverte')
  T.ok(app.calibration ~= nil, 'calibration automatique lancée (calibrationAuto)')
  T.ok(waitFor(h, function() return app.calibration.state ~= 'running' end, profile), 'calibration terminée')
  local r = app.calibration.result
  T.ok(r, tostring(app.calibration.error))
  T.ok(r.usable, tostring(r.reason))
  T.near(r.factors.mu, truth.mu, 0.04, 'adhérence retrouvée par la chaîne réelle (enregistrement, abscisse, conditions)')
  T.near(r.factors.power, truth.power, 0.04)
  T.ok(math.abs(r.runs[1].timeError) < 0.005, 'écart de temps ' .. r.runs[1].timeError)
  T.ok(app.usableFactors()[app.discovery.compoundIndex] == r.factors, 'facteurs transmis au calcul de setup (par composé)')
  T.eq(app.perf.errors, 0)
  frames(h, 1, profile)
  T.ok(shown(h, 'Calibration utilisable'), 'affichée')
  T.ok(shown(h, 'Meilleur tour, setup de la découverte'))
end

tests['M02 export du tour enregistré'] = function()
  local h, app = boot('lamborghini_huracan_gt3_evo2', 'monza')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  warmTyres(h, app)
  local profile = trueProfile(app, CarModel.defaultFactors())
  T.ok(waitFor(h, function() return app.recorder.laps.last ~= nil end, profile))
  h.click = 'Copier le tour enregistré'
  frames(h, 1, profile)
  T.ok(h.clipboard, tostring(app.ui.message))
  T.contains(h.clipboard, 'Temps officiel')
  T.contains(h.clipboard, 'FRONT_BIAS=', 'setup en clair')
  T.contains(h.clipboard, 's_m;v_kmh;gaz;frein;rapport;regime')
  T.contains(h.clipboard, 'Modèle (setup de la découverte')
  T.ok(waitFor(h, function() return app.calibration and app.calibration.state ~= 'running' end, profile))
  h.click = 'Copier le tour enregistré'
  frames(h, 1, profile)
  T.contains(h.clipboard, 'Calibration : mu=')
  T.contains(h.clipboard, 'setup de la découverte : mesuré')
  local rows = 0
  for _ in h.clipboard:gmatch('\n%d+;') do rows = rows + 1 end
  T.ok(rows > 1000, rows .. ' points')
end

tests['M03 validation du setup proposé (§14.1) et calibration sur deux setups'] = function()
  local h, app = boot('lamborghini_huracan_gt3_evo2', 'monza')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  warmTyres(h, app)
  local truth = { mu = 0.96, power = 0.98, drag = 1.02, lift = 1.0, brake = 1.0 }
  local origin = trueProfile(app, truth)
  T.ok(waitFor(h, function() return app.recorder.laps.last ~= nil end, origin), 'tour avec le setup d\'origine')
  T.ok(waitFor(h, function() return app.calibration and app.calibration.state ~= 'running' end, origin))
  -- calcul et enregistrement du setup qualification, composé monté imposé (même composé : une seule
  -- calibration couvre les deux setups ; le changement de composé est l'objet de M10)
  app.settings.optBudgetEvalsQ = 120
  app.settings.compoundChoice = app.discovery.compoundIndex
  h.click = 'Calculer le setup tour rapide'
  T.ok(waitFor(h, function() return app.quali and app.quali.state == 'done' end, origin), tostring(app.quali and app.quali.error))
  h.click = 'Enregistrer le setup tour rapide'
  frames(h, 1, origin)
  T.ok(app.quali.saved and app.quali.saved.ok, tostring(app.ui.message))
  T.ok(app.proposals.quali and app.knownSetups[app.proposals.quali], 'setup proposé connu')
  -- Vincent charge le fichier : les crans du jeu prennent les valeurs proposées
  local Util = require('src/util')
  local written = Util.parseIni(h.written[app.quali.saved.path])
  for _, sp in ipairs(h.spinners) do
    local value = tonumber(Util.iniGet(written, sp.name, 'VALUE'))
    if value then sp.value = value end
  end
  h.car.compoundIndex = tonumber(Util.iniGet(written, 'TYRES', 'VALUE'))
  -- et ajoute du carburant pour ses tours (le cran FUEL ne fait pas partie de la signature) ; dans AC,
  -- la voiture repart avec la charge du cran FUEL
  local fuel = 30
  for _, sp in ipairs(h.spinners) do
    if sp.name == 'FUEL' then
      sp.value = math.min(sp.max, sp.value + 5)
      fuel = sp.value
    end
  end
  warmTyres(h, app, app.quali.result.deltas, app.quali.result.compound.slot, fuel)
  local proposed = trueProfile(app, truth, app.quali.result.deltas, nil, app.quali.result.compound.slot, fuel)
  local before = app.recorder.finished
  T.ok(waitFor(h, function() return app.recorder.finished >= before + 2 end, proposed), 'tours avec le setup proposé')
  T.eq(app.recorder.laps.last.signature, app.proposals.quali, 'tour rattaché au setup proposé')
  T.ok(waitFor(h, function() return app.calibration.state ~= 'running' end, proposed))
  T.eq(app.calibration.runs, 2, 'calibration sur les deux setups')
  T.ok(app.quali.result.calibrated, 'setup calculé avec la calibration utilisable')
  -- validation (§14.1) : gain prévu par le modèle de la décision, dans les conditions mesurées des tours
  T.ok(waitFor(h, function() return app.validations.quali and app.validations.quali.state ~= 'running' end, proposed), 'validation')
  local v = app.validations.quali
  T.eq(v.state, 'done', tostring(v.error))
  T.ok(v.calibrated, 'modèle calibré')
  T.ok(math.abs(v.fuelO - v.fuelP) > 1, 'charges de carburant différentes, prises en compte')
  T.near(v.measured, app.recorder.laps.best[app.discovery.signature].time - app.recorder.laps.best[app.proposals.quali].time, 1e-9)
  -- modèle calibré sur ces tours (même vérité) : le gain prévu reproduit le gain mesuré
  T.near(v.predicted, v.measured, 0.15, 'gain prévu ' .. v.predicted .. ' contre mesuré ' .. v.measured)
  frames(h, 1, proposed)
  local line = shown(h, 'Setup tour rapide — Validé en jeu')
  T.ok(line, 'validation affichée, verdict conforme')
  T.ok(v.conforming and v.tolerance >= Config.K.validateTolAbs)
  T.contains(line, 'gain prévu ' .. Util.fmt(v.predicted, 3) .. ' s')
  T.contains(line, 'pris en compte')
  -- la validation est propre au genre : rien pour la course, qui n'a pas de setup proposé ; l'intention
  -- « valider la course » ne relance pas celle de la qualification
  T.eq(app.validations.race, nil)
  local done = app.validations.quali
  app.ui.message = nil
  app.handleIntents({ validate = 'race' })
  T.contains(app.ui.message or '', 'tour propre')
  T.ok(app.validations.quali == done, 'validation de la qualification inchangée')
  T.eq(app.validations.race, nil)
  T.eq(app.perf.errors, 0)
end

tests['M10 composé changé par le calcul (D18) : fichier, signature, calibration par composé (§9.2)'] = function()
  local h, app = boot('lamborghini_huracan_gt3_evo2', 'monza')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  warmTyres(h, app)
  local truth = { mu = 0.96, power = 0.98, drag = 1.02, lift = 1.0, brake = 1.0 }
  local origin = trueProfile(app, truth)
  T.ok(waitFor(h, function() return app.recorder.laps.last ~= nil end, origin))
  T.ok(waitFor(h, function() return app.calibration and app.calibration.state ~= 'running' end, origin))
  local medium = app.discovery.compoundIndex
  T.ok(app.calibrations[medium] and app.calibrations[medium].result.usable, 'calibration du composé monté')
  -- choix automatique : le composé tendre est plus rapide sur un tour
  app.settings.optBudgetEvalsQ = 120
  h.click = 'Calculer le setup tour rapide'
  T.ok(waitFor(h, function() return app.quali and app.quali.state == 'done' end, origin), tostring(app.quali and app.quali.error))
  local r = app.quali.result
  T.ok(r.compound.changed, 'composé changé : ' .. tostring(r.compound.name))
  T.ok(#r.compound.comparison >= 3, 'composés comparés')
  T.no(r.calibrated, 'tendre non calibré (§9.2)')
  T.contains(r.calibrationNote, 'composé monté appliquée')
  T.ok(r.timeProposed < r.timeCurrent, 'gain avec le composé')
  h.click = 'Enregistrer le setup tour rapide'
  frames(h, 1, origin)
  T.ok(app.quali.saved and app.quali.saved.ok, tostring(app.ui.message))
  local Util = require('src/util')
  local written = Util.parseIni(h.written[app.quali.saved.path])
  T.eq(tonumber(Util.iniGet(written, 'TYRES', 'VALUE')), r.compound.index, '[TYRES] du fichier')
  -- le composé ne change pas en douce : composé monté changé depuis la découverte -> découverte relancée
  -- avant tout calcul (décision du 20/10/2026) ; ici le calcul en attente est annulé
  h.car.compoundIndex = r.compound.index
  h.click = 'Calculer le setup tour rapide'
  frames(h, 1, origin)
  T.contains(app.ui.message, 'composé de pneus')
  T.ok(app.pendingComputes.quali, 'calcul en attente de la découverte')
  h.click = 'Annuler le calcul'
  frames(h, 1, origin)
  T.eq(app.pendingComputes.quali, nil)
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end, origin), 'nouvelle découverte, composé monté')
  -- Vincent charge le fichier proposé
  for _, sp in ipairs(h.spinners) do
    local value = tonumber(Util.iniGet(written, sp.name, 'VALUE'))
    if value then sp.value = value end
  end
  warmTyres(h, app, r.deltas, r.compound.slot)
  -- tours sur le tendre : rattachés au setup proposé, calibration propre à ce composé
  local proposed = trueProfile(app, truth, r.deltas, nil, r.compound.slot)
  local before = app.recorder.finished
  T.ok(waitFor(h, function() return app.recorder.finished >= before + 2 end, proposed))
  T.eq(app.recorder.laps.last.signature, app.proposals.quali, 'signature avec le composé')
  T.ok(waitFor(h, function() return app.calibrations[r.compound.index] and app.calibrations[r.compound.index].state ~= 'running' end,
    proposed), 'calibration du tendre')
  T.eq(app.calibrations[r.compound.index].runs, 1, 'seulement les tours sur le tendre')
  T.ok(app.calibrations[medium].result, 'calibration du Medium conservée')
  T.ok(waitFor(h, function() return app.validations.quali and app.validations.quali.state ~= 'running' end, proposed), 'validation')
  T.eq(app.validations.quali.state, 'done', tostring(app.validations.quali.error))
  T.ok(app.validations.quali.compoundChanged)
  T.ok(app.validations.quali.calibrated, 'décision prise avec la calibration du composé monté')
  T.eq(app.perf.errors, 0)
end

tests['M04 coût par frame pendant l\'enregistrement'] = function()
  local h, app = boot('urd_px1_aura', 'ks_red_bull_ring-layout_gp')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' and app.report ~= nil end))
  local profile = trueProfile(app, CarModel.defaultFactors())
  frames(h, 600, profile)
  app.settings.calibrationAuto = false
  -- moyenne vraie sur toutes les frames (la moyenne glissante de l'app dépend de l'instant d'arrêt :
  -- juste après un passage de ligne, elle porte encore sa pointe)
  local sum = 0
  for _ = 1, 9000 do
    frames(h, 1, profile)
    sum = sum + app.perf.lastMs
  end
  T.ok(sum / 9000 < 0.3, 'coût moyen ' .. sum / 9000 .. ' ms (§14.3)')
  T.ok(app.recorder.finished >= 1)
  -- calibration automatique active : la frame du passage de la ligne reste légère (le travail lourd
  -- est dans la tâche découpée). Plusieurs passages, médiane ; surcoût hors tranche de calcul mesuré à
  -- part (la tranche, elle, est bornée par sliceBudgetMs)
  app.settings.calibrationAuto = true
  local frameMs, extraMs = {}, {}
  local finished = app.recorder.finished
  local stats = app.scheduler.stats
  for _ = 1, 20000 do
    h.car.isInPit, h.car.isInPitlane = false, false
    Fake.drive(h, profile, 1 / 60)
    h.sim.time = h.sim.time + 1000 / 60
    collectgarbage('step', 0)
    local slices = stats.slices
    local started = PY.clock()
    script.SETUPLAB__UPDATE(1 / 60)
    local ms = (PY.clock() - started) * 1000
    if app.recorder.finished ~= finished then
      finished = app.recorder.finished
      frameMs[#frameMs + 1] = ms
      extraMs[#extraMs + 1] = ms - (stats.slices ~= slices and stats.lastSliceMs or 0)
    end
  end
  table.sort(frameMs)
  table.sort(extraMs)
  local median = frameMs[math.ceil(#frameMs / 2)]
  local extra = extraMs[math.ceil(#extraMs / 2)]
  PY.note('M04', string.format('%d passages de ligne : frame médiane %.2f ms (max %.2f), dont hors tranche de calcul %.2f ms',
    #frameMs, median, frameMs[#frameMs], extra))
  T.ok(#frameMs >= 3, #frameMs .. ' passages')
  T.ok(median < 3, 'frame du passage de ligne ' .. median .. ' ms (§14.3 : < 3 ms)')
  T.ok(extra < 1, 'surcoût du passage de ligne hors tranche ' .. extra .. ' ms')
  T.ok(app.calibration ~= nil, 'calibration lancée')
end

tests['M05 circuit sans ligne IA : reconnaissance sur le premier tour'] = function()
  local h, app = boot('lamborghini_huracan_gt3_evo2', 'spa', { missing = { 'ac.hasTrackSpline' } })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  T.eq(app.discovery.trackModel, nil, 'sans ligne IA, pas de modèle')
  T.ok(app.qualiBlocker() ~= nil)
  -- sans ligne IA, splinePosition reste à 0 ; un tour roulé à vitesse constante suffit à reconstituer
  -- la géométrie (distance parcourue)
  local profile = { p = { 0, 1 }, v = { 45, 45 }, noProgress = true }
  T.ok(waitFor(h, function() return app.reconnaissance ~= nil end, profile), 'reconnaissance')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end, profile))
  local tm = app.discovery.trackModel
  T.ok(tm, tostring(app.discovery.trackModelReason))
  T.eq(tm.source, 'reconnaissance')
  T.ok(tm.confidence < 1, 'confiance abaissée (largeurs inconnues)')
  T.ok(app.discovery.simCurrent and app.discovery.simCurrent.time, 'simulation possible')
  T.ok(waitFor(h, function() return app.report ~= nil end, profile, 3000), 'rapport J0 construit')
  T.contains(app.report, 'reconnaissance')
  -- tours suivants : progression refaite par les positions, profil mesuré exploitable
  local real = trueProfile(app, CarModel.defaultFactors())
  real.noProgress = true
  local before = app.recorder.finished
  T.ok(waitFor(h, function() return app.recorder.finished >= before + 2 end, real), 'tours après la reconnaissance')
  T.ok(waitFor(h, function() return app.calibration and app.calibration.state ~= 'running' end, real), 'calibration')
  local r = app.calibration.result
  T.ok(r, tostring(app.calibration.error))
  PY.note('M05', string.format('calibration sur circuit reconstitué : écart %.2f %%, RMS %.2f %%', r.worstTimeError * 100,
    r.worstRms * 100))
  T.ok(r.worstRms < Config.K.calibMaxRms, 'profil exploitable : RMS ' .. r.worstRms)
  T.eq(app.perf.errors, 0)
  T.ok(Config.version)
end

tests['M07 calibration dans les conditions réelles du tour (pneus froids et usés)'] = function()
  local h, app = boot('lamborghini_huracan_gt3_evo2', 'monza')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  local d = app.discovery
  local compound = d.carBase.compounds[CarModel.defaultSetup(d.carBase).compound]
  local tyres = { tyreTemp = CarModel.operatingTemp(compound.front) - 35, tyreKm = 12 }
  local setup = SetupSpace.apply(d.space, CarModel.defaultSetup(d.carBase), {})
  -- pressions à chaud réelles plus hautes que la loi des gaz ne le prévoit (+4 psi)
  tyres.hotPressureF = CarModel.hotPressure(setup.pressureF, d.conditions.airTemp, tyres.tyreTemp) + 4
  tyres.hotPressureR = CarModel.hotPressure(setup.pressureR, d.conditions.airTemp, tyres.tyreTemp) + 4
  -- l'état des pneus change vraiment l'adhérence du modèle (sinon le test ne prouverait rien)
  local warm = assert(CarModel.configure(d.carBase, setup, { airTemp = d.conditions.airTemp }))
  local warmF = warm.dF
  local cold = assert(CarModel.configure(d.carBase, setup, { airTemp = d.conditions.airTemp, tyreTemp = tyres.tyreTemp,
    tyreKm = tyres.tyreKm, hotPressureF = tyres.hotPressureF, hotPressureR = tyres.hotPressureR }))
  T.ok(cold.dF / warmF < 0.95, 'pneus froids et usés : adhérence ×' .. cold.dF / warmF)
  local formula = assert(CarModel.configure(d.carBase, setup, { airTemp = d.conditions.airTemp, tyreTemp = tyres.tyreTemp,
    tyreKm = tyres.tyreKm }))
  T.ok(math.abs(cold.dF / formula.dF - 1) > 0.015, 'pressions mesurées : adhérence ×' .. cold.dF / formula.dF)
  for w = 0, 3 do
    h.car.wheels[w].tyreCoreTemperature = tyres.tyreTemp
    h.car.wheels[w].tyrePressure = w < 2 and tyres.hotPressureF or tyres.hotPressureR
    h.car.wheels[w].tyreVirtualKM = tyres.tyreKm
  end
  h.car.fuel = 30
  local truth = { mu = 0.97, power = 0.98, drag = 1.0, lift = 1.0, brake = 1.0 }
  local profile = trueProfile(app, truth, nil, tyres)
  T.ok(waitFor(h, function() return app.recorder.laps.last ~= nil end, profile), 'tour enregistré')
  T.ok(waitFor(h, function() return app.calibration and app.calibration.state ~= 'running' end, profile))
  local r = app.calibration.result
  PY.note('M07', string.format('kμ %.3f (vrai %.3f), état des pneus ×%.3f', r.factors.mu, truth.mu, cold.dF / warmF))
  T.near(r.factors.mu, truth.mu, 0.012, 'état des pneus non absorbé par kμ')
end

tests['M11 setup course depuis l\'app : mesures du tour, fichier, validation (J6)'] = function()
  local h, app = boot('lamborghini_huracan_gt3_evo2', 'monza')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  warmTyres(h, app)
  -- usure réelle : 6 km virtuels par tour, lus pendant le tour
  local kmPerLap = 6
  local profile = trueProfile(app, CarModel.defaultFactors())
  local lapsBefore = h.car.lapCount
  T.ok(waitFor(h, function()
    for w = 0, 3 do h.car.wheels[w].tyreVirtualKM = (h.driver and h.driver.p or 0) * kmPerLap + (h.car.lapCount - lapsBefore) * kmPerLap end
    return app.recorder.laps.last ~= nil
  end, profile), 'tour de référence')
  T.ok(app.recorder.laps.last.valid, tostring(app.recorder.laps.last.reason))
  app.settings.optBudgetEvalsC, app.settings.raceLaps = 40, 12
  h.click = 'Calculer le setup course'
  T.ok(waitFor(h, function() return app.race and app.race.state ~= 'running' end, profile), 'calcul course')
  T.eq(app.race.state, 'done', tostring(app.race.error))
  local r = app.race.result
  T.eq(r.race.fuelSource, 'mesure', 'consommation mesurée sur le tour')
  T.eq(r.race.kmSource, 'mesure')
  T.near(r.race.kmPerLapF, kmPerLap, 0.2, 'km virtuels par tour mesurés')
  T.eq(r.race.laps, 12)
  frames(h, 1, profile)
  T.ok(shown(h, 'Objectif estimé'), 'résultat affiché (tuiles)')
  T.ok(shown(h, 'Course : 12 tours'))
  h.click = 'Enregistrer le setup course'
  frames(h, 1, profile)
  T.ok(app.race.saved and app.race.saved.ok, tostring(app.ui.message))
  T.ok(app.race.saved.path:find(Config.exportRacePrefix, 1, true), app.race.saved.path)
  local Util = require('src/util')
  local written = Util.parseIni(h.written[app.race.saved.path])
  local fuel = tonumber(Util.iniGet(written, 'FUEL', 'VALUE'))
  T.ok(fuel and fuel >= 12 * r.race.fuelPerLap * 1.03 - 1, 'carburant de course écrit : ' .. tostring(fuel))
  T.ok(app.proposals.race and app.knownSetups[app.proposals.race].label:find('course', 1, true), 'setup course connu (validation)')
  T.eq(app.perf.errors, 0)
end

tests['M08 inerte en replay : aucun tour enregistré'] = function()
  local h, app = boot('lamborghini_huracan_gt3_evo2', 'monza')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  local profile = trueProfile(app, CarModel.defaultFactors())
  -- replay déclenché en plein tour enregistré : abandon dès la frame (le contexte n'est relu qu'à 1 Hz)
  T.ok(waitFor(h, function() return app.recorder.state == 'enregistrement' and app.recorder.n > 300 end, profile))
  h.sim.isReplayActive = true
  frames(h, 1, profile)
  T.eq(app.recorder.state, 'attente', 'tour abandonné')
  frames(h, 12000, profile)
  T.ok(app.inert, 'app inerte en replay')
  T.eq(app.recorder.finished, 0, 'aucun tour enregistré pendant le replay')
  T.eq(app.recorder.n, 0, 'aucun échantillon')
  T.eq(app.perf.errors, 0)
end

tests['M09 crans mal formés et carburant : tours toujours rattachés au setup'] = function()
  local h, app = boot('lamborghini_huracan_gt3_evo2', 'monza')
  -- un cran sans valeur finie (écarté à la découverte comme en roulant)
  h.spinners[#h.spinners + 1] = { name = 'BROKEN', label = 'BROKEN', value = 0 / 0, min = 0, max = 1, step = 1, units = '' }
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  warmTyres(h, app)
  local profile = trueProfile(app, CarModel.defaultFactors())
  T.ok(waitFor(h, function() return app.recorder.laps.last ~= nil end, profile))
  T.eq(app.recorder.laps.last.signature, app.discovery.signature, 'même signature malgré le cran mal formé')
  -- carburant ajouté entre deux tours : même setup
  for _, sp in ipairs(h.spinners) do
    if sp.name == 'FUEL' then sp.value = math.min(sp.max, sp.value + 10) end
  end
  local before = app.recorder.finished
  T.ok(waitFor(h, function() return app.recorder.finished >= before + 2 end, profile))
  T.eq(app.recorder.laps.last.signature, app.discovery.signature, 'carburant hors signature')
  T.ok(app.recorder.laps.last.valid, tostring(app.recorder.laps.last.reason))
  T.eq(app.perf.errors, 0)
end

tests['M13 pneus arrière en surchauffe sur le tour : signalé, pression arrière jamais abaissée (§10.6)'] = function()
  local h, app = boot('lamborghini_huracan_gt3_evo2', 'monza')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  warmTyres(h, app)
  -- arrière à 130 °C (fenêtre du composé : jusqu'à 112 °C environ), intérieur nettement plus chaud
  for w = 2, 3 do
    h.car.wheels[w].tyreCoreTemperature = 130
    h.car.wheels[w].tyreInsideTemperature, h.car.wheels[w].tyreOutsideTemperature = 140, 120
  end
  local profile = trueProfile(app, CarModel.defaultFactors())
  T.ok(waitFor(h, function() return app.recorder.laps.last ~= nil end, profile), 'tour enregistré')
  T.ok(app.recorder.laps.last.valid, tostring(app.recorder.laps.last.reason))
  app.settings.optBudgetEvalsQ = 120
  h.click = 'Calculer le setup tour rapide'
  T.ok(waitFor(h, function() return app.quali and app.quali.state ~= 'running' end, profile))
  T.eq(app.quali.state, 'done', tostring(app.quali.error))
  local r = app.quali.result
  T.eq(r.tyres.R.state, 'surchauffe')
  T.ok((r.deltas.pressureR or 0) >= 0, 'pression arrière jamais abaissée')
  T.ok(r.tyres.R.spread and r.tyres.R.spread > 12, 'écart intérieur − extérieur mesuré')
  T.contains(r.tyres.R.camberGuard, 'jamais plus négatif')
  frames(h, 1, profile)
  T.ok(shown(h, 'Pneus arrière en surchauffe'), 'surchauffe affichée, section fermée comprise')
  -- détail des pneus : section « Pneus et composé », fermée d'office ; dépliée
  h.openSections = true
  frames(h, 1, profile)
  h.openSections = nil
  T.ok(shown(h, 'Intérieur − extérieur'), 'écart de température affiché')
end

tests['M12 composé illisible : calcul refusé, aucune erreur ; pneus pluie montés sur le sec : calcul accepté'] = function()
  -- index du composé illisible : calcul bloqué ; les tours valides ne lèvent aucune erreur (clé −1)
  local h, app = boot('lamborghini_huracan_gt3_evo2', 'monza')
  h.car.compoundIndex = 0 / 0
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  T.contains(app.qualiBlocker(), 'composé monté illisible')
  warmTyres(h, app)
  local profile = trueProfile(app, CarModel.defaultFactors())
  local before = app.recorder.finished
  T.ok(waitFor(h, function() return app.recorder.finished >= before + 2 end, profile), 'tours enregistrés')
  T.eq(app.perf.errors, 0, 'aucune erreur à chaque tour valide')
  -- pneus pluie montés sur piste sèche : calcul accepté (D16 amendé le 21/10/2026), un composé sec est
  -- proposé (un pneu pluie n'est jamais choisi d'office sur le sec)
  local h2, app2 = boot('lamborghini_huracan_gt3_evo2', 'monza')
  T.ok(waitFor(h2, function() return app2.discoveryState == 'done' end))
  local c = app2.discovery.carBase.compounds[app2.discovery.compoundSlot]
  c.name, c.short = 'Wet', 'W'
  T.eq(app2.qualiBlocker(), nil, 'plus de refus')
  app2.settings.optBudgetEvalsQ = 60
  h2.click = 'Calculer le setup tour rapide'
  T.ok(waitFor(h2, function() return app2.quali and app2.quali.state ~= 'running' end))
  T.eq(app2.quali.state, 'done', tostring(app2.quali.error))
  T.ok(app2.quali.result.compound.changed, 'composé sec proposé')
  T.ok(app2.quali.result.compound.name ~= 'Wet')
  c.name, c.short = 'Slick Medium', 'M'
end

tests['M06 voiture illisible : mode mesure uniquement (§9.4)'] = function()
  -- profil « réel » calculé avec les fichiers de la voiture, puis app lancée sans pouvoir les lire
  local Util = require('src/util')
  local Datasource = require('src/datasource')
  local TrackModel = require('src/track_model')
  local S = Util.syncContext()
  local ref = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  local raw = Datasource.sampleTrack(ref, 1, S)
  Datasource.probeBank(ref, raw, S)
  local track = assert(TrackModel.build(raw, Datasource.readTrackFiles(ref, S), 2))
  local base = CarModel.build(Datasource.readCar(ref, 0, S), nil)
  local eff = assert(CarModel.configure(base, CarModel.defaultSetup(base), { airTemp = 25 }))
  local result, buf = Sim.run(track, eff, nil)
  local profile = { p = {}, v = {}, ay = {} }
  for k = 1, track.n do profile.p[k], profile.v[k], profile.ay[k] = track.p[k], buf.v[k], buf.ayReq[k] end
  profile.p[#profile.p + 1], profile.v[#profile.v + 1], profile.ay[#profile.ay + 1] = 1, buf.v[1], buf.ayReq[1]
  local h, app = boot('lamborghini_huracan_gt3_evo2', 'monza', { carDataError = true, lutError = true, rawForm = 'aucun' })
  h.car.mass = eff.mass
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  T.ok(app.discovery.carBase == nil or #app.discovery.carBaseMissing > 0, 'voiture illisible')
  T.ok(app.qualiBlocker() ~= nil, 'pas de calcul de setup')
  T.ok(waitFor(h, function() return app.measureOnly and app.measureOnly.state ~= 'running' end, profile), 'estimation')
  local m = app.measureOnly
  T.eq(m.state, 'done', tostring(m.reason))
  T.ok(m.estimate, tostring(m.reason))
  T.ok(m.simTime, tostring(m.reason))
  PY.note('M06', string.format('tour simulé %.2f s contre %.2f s mesuré (modèle complet %.2f s)', m.simTime, m.lapTime, result.time))
  T.ok(math.abs(m.simTime - m.lapTime) / m.lapTime < 0.05, 'tour simulé ' .. m.simTime .. ' contre ' .. m.lapTime)
  frames(h, 1, profile)
  T.ok(shown(h, 'Mode mesure uniquement'), 'affiché')
  T.ok(app.qualiBlocker() ~= nil, 'toujours pas de calcul de setup (A18)')
  -- estimation interrompue par une nouvelle découverte : jamais figée « en cours », reprise au tour suivant
  app.measureOnly = nil
  T.ok(waitFor(h, function() return app.measureOnly and app.measureOnly.state == 'running' end, profile), 'nouvelle estimation')
  app.handleIntents({ rediscover = true })
  T.eq(app.measureOnly.state, 'failed')
  T.contains(app.measureOnly.reason, 'interrompue')
  T.eq(app.perf.errors, 0)
end

-- Chargement par le bouton (au stand, après le délai minimal de confirmation, horloge réelle).
local function loadByButton(h, app, label)
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  frames(h, 1)
  h.click = 'Charger le setup ' .. label .. ' dans la voiture'
  frames(h, 1)
  T.ok(app.loadArm, tostring(app.ui.message))
  local started = app.clock()
  while app.clock() - started < Config.K.loadConfirmMinSeconds + 0.1 do frames(h, 1) end
  h.click = 'Confirmer le chargement (' .. label .. ')'
  frames(h, 1)
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'constat du chargement')
  T.ok(app.loadTest and app.loadTest.ok, tostring(app.loadTest and app.loadTest.reason))
end

tests['M15 validation après chargement et nouvelle découverte : origine du setup proposé conservée (§14.1)'] = function()
  local h, app = boot('lamborghini_huracan_gt3_evo2', 'monza')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  warmTyres(h, app)
  local truth = { mu = 0.96, power = 0.98, drag = 1.02, lift = 1.0, brake = 1.0 }
  local origin = trueProfile(app, truth)
  local originSignature = app.discovery.signature
  T.ok(waitFor(h, function() return app.recorder.laps.last ~= nil end, origin), 'tour avec le setup d\'origine')
  T.ok(waitFor(h, function() return app.calibration and app.calibration.state ~= 'running' end, origin))
  app.settings.optBudgetEvalsQ = 120
  app.settings.compoundChoice = app.discovery.compoundIndex
  h.click = 'Calculer le setup tour rapide'
  T.ok(waitFor(h, function() return app.quali and app.quali.state == 'done' end, origin), tostring(app.quali and app.quali.error))
  h.click = 'Enregistrer le setup tour rapide'
  frames(h, 1, origin)
  T.ok(app.quali.saved and app.quali.saved.ok, tostring(app.ui.message))
  T.eq(app.proposalOrigins.quali, originSignature)
  -- chargement par le bouton, puis nouvelle découverte : elle porte maintenant sur le setup proposé
  loadByButton(h, app, 'tour rapide')
  h.click = 'Relancer la découverte'
  frames(h, 1)
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  T.eq(app.discovery.signature, app.proposals.quali, 'découverte sur le setup chargé')
  T.eq(app.proposalOrigins.quali, originSignature, 'origine conservée')
  local fuel = 30
  for _, sp in ipairs(h.spinners) do
    if sp.name == 'FUEL' then fuel = sp.value end
  end
  warmTyres(h, app, nil, nil, fuel)
  local proposed = trueProfile(app, truth, nil, nil, nil, fuel)
  local before = app.recorder.finished
  T.ok(waitFor(h, function() return app.recorder.finished >= before + 2 end, proposed), 'tours avec le setup proposé')
  T.ok(waitFor(h, function() return app.validations.quali and app.validations.quali.state ~= 'running' end, proposed), 'validation')
  local v = app.validations.quali
  T.eq(v.state, 'done', tostring(v.error))
  T.near(v.measured, app.recorder.laps.best[originSignature].time - app.recorder.laps.best[app.proposals.quali].time, 1e-9)
  T.eq(app.perf.errors, 0)
end

-- Rapport de Vincent (20/10/2026) : en essai et en journée circuit, calcul refusé dès que la piste se
-- gommait ou chauffait. Séance d'essai avec voitures IA, piste qui évolue à chaque tour : découverte,
-- tours, calcul, enregistrement et chargement s'enchaînent sans aucun refus.
tests['M16 essai et journée circuit : piste qui évolue à chaque tour, aucun refus (rapport du 20/10/2026)'] = function()
  local h, app = boot('lamborghini_huracan_gt3_evo2', 'monza')
  h.sim.raceSessionType, h.sim.carsCount = 1, 30
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  warmTyres(h, app)
  local profile = trueProfile(app, { mu = 0.97, power = 0.99, drag = 1.01, lift = 1.0, brake = 1.0 })
  local refusals = {}
  local function lap()
    local before = app.recorder.finished
    T.ok(waitFor(h, function() return app.recorder.finished > before end, profile), 'tour')
    -- la piste se gomme (voitures IA) et chauffe : bien au-delà des anciens paliers
    h.sim.roadGrip = math.min(1, h.sim.roadGrip + 0.006)
    h.sim.roadTemperature = h.sim.roadTemperature + 0.8
    h.sim.ambientTemperature = h.sim.ambientTemperature + 0.4
    local message = app.ui.message or ''
    if message:find('impossible', 1, true) then refusals[#refusals + 1] = message end
    frames(h, 1, profile)
    local blocked = shown(h, 'Calcul indisponible')
    if blocked then refusals[#refusals + 1] = blocked end
  end
  for _ = 1, 3 do lap() end
  T.eq(app.discoveryState, 'done', 'aucune relance pour une piste qui évolue')
  app.settings.optBudgetEvalsQ = 100
  h.click = 'Calculer le setup tour rapide'
  T.ok(waitFor(h, function() return app.quali and app.quali.state ~= 'running' end, profile))
  T.eq(app.quali.state, 'done', tostring(app.quali.error))
  T.near(app.quali.conditions.roadGrip, h.sim.roadGrip, 1e-9, 'calcul fait avec la piste du moment')
  for _ = 1, 3 do lap() end
  frames(h, 61, profile)
  T.contains(app.quali.stale or '', 'piste', 'résultat signalé périmé, sans blocage')
  T.eq(app.qualiBlocker(), nil)
  h.click = 'Enregistrer le setup tour rapide'
  frames(h, 1, profile)
  T.ok(app.quali.saved and app.quali.saved.ok, tostring(app.ui.message))
  loadByButton(h, app, 'tour rapide')
  -- course : aucune course au programme d'un essai, durée supposée et signalée
  app.settings.optBudgetEvalsC = 30
  h.tab, h.click = 'Course', 'Calculer le setup course'
  frames(h, 1)
  h.tab = nil
  T.ok(waitFor(h, function() return app.race and app.race.state ~= 'running' end), 'calcul course après la redécouverte')
  T.eq(app.race.state, 'done', tostring(app.race.error))
  T.eq(#refusals, 0, table.concat(refusals, ' | '))
  T.eq(app.perf.errors, 0)
end

return tests
