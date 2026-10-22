-- Séances, conditions de piste, calcul en attente, origine de la validation (version 1.1.0) : scénarios
-- de la relecture adversariale ciblée (docs/RELECTURE_1_1.md), chacun vérifiant le comportement attendu.
local T = require('t')
local Util = require('src/util')
local Config = require('src/config')
local CarModel = require('src/car_model')
local Sim = require('src/laptime_sim')
local Space = require('src/setup_space')
local Fake = require('fakehost')

local tests = {}

local function boot(carId, trackId, opts)
  opts = opts or {}
  opts.car = require('fixtures/cars/' .. (carId or 'lamborghini_huracan_gt3_evo2'))
  opts.track = require('fixtures/tracks/' .. (trackId or 'monza'))
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
  local button = h.ui.button
  h.ui.button = function(s) capture('[' .. s .. ']'); return button(s) end
  return h, app
end

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
  for i = 1, maxFrames or 60000 do
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

local function trueProfile(app, factors)
  local d = app.discovery
  local setup = app.physicalSetup(d, nil, nil)
  setup.fuel = 30
  local conditions = { airTemp = d.conditions.airTemp, roadGrip = d.conditions.roadGrip, surfaceGrip = d.conditions.surfaceGrip,
    factors = factors }
  local eff = assert(CarModel.configure(d.carBase, setup, conditions))
  local result, buf = Sim.run(d.trackModel, eff, nil)
  local profile = { p = {}, v = {}, time = result.time }
  for k = 1, d.trackModel.n do profile.p[k], profile.v[k] = d.trackModel.p[k], buf.v[k] end
  profile.p[#profile.p + 1], profile.v[#profile.v + 1] = 1, buf.v[1]
  return profile
end

local function touch(h)
  for _, sp in ipairs(h.spinners) do
    if sp.name == 'PRESSURE_LF' then sp.value = sp.value + sp.step end
  end
end

local function refresh(h, n)
  for _ = 1, n or 1 do
    rawget(_G, 'SETUPLAB').app.nextContextAt = 0
    frames(h, 1)
  end
end

local function queueNames(app)
  local names = {}
  if app.scheduler.current then names[#names + 1] = '*' .. app.scheduler.current.name end
  for _, task in ipairs(app.scheduler.queue) do names[#names + 1] = task.name end
  return table.concat(names, ',')
end

local SUSP = { 'springF', 'springR', 'heaveF', 'heaveR', 'damperSlowF', 'damperSlowR', 'damperFastF', 'damperFastR' }
local function suspDeltas(r)
  local parts = {}
  for _, key in ipairs(SUSP) do
    if r.deltas[key] ~= nil then parts[#parts + 1] = key .. '=' .. tostring(r.deltas[key]) end
  end
  return table.concat(parts, ' ')
end

-- 1. Rugosité appliquée à la découverte entre le clic (conditions copiées) et le prepare (espace lu) :
-- attendu, un calcul dont la rugosité et l'espace optimisable sont cohérents.
tests['Z01 rugosité et espace optimisable pris au même instant (calcul en attente derrière un autre)'] = function()
  local h, app = boot()
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  local d = app.discovery
  T.eq(d.space.byKey.springF.class, Space.EXCLUDED, 'avant mesure')
  local tm = d.trackModel
  local profile = { p = {}, v = {} }
  for k = 1, tm.n do profile.p[k], profile.v[k] = tm.p[k], 55 end
  profile.p[#profile.p + 1], profile.v[#profile.v + 1] = 1, 55
  local rng = Util.rngNew(3)
  local function frame(drive)
    if drive then
      h.car.isInPit, h.car.isInPitlane = false, false
      Fake.drive(h, profile, 1 / 60)
      for wh = 0, 3 do
        local g = -6
        for _ = 1, 12 do g = g + Util.rngRange(rng, 0, 1) end
        h.car.wheels[wh].load = 3500 + 200 * g
      end
    end
    h.sim.time = h.sim.time + 1000 / 60
    h.texts = {}
    script.SETUPLAB__UPDATE(1 / 60)
    script.SETUPLAB__MAIN(1 / 60)
  end
  app.settings.optBudgetEvalsC, app.settings.optBudgetEvalsQ = 400, 200
  local launched, done = false, false
  for _ = 1, 60 * 600 do
    local before = app.recorder.finished
    frame(true)
    if not launched and app.recorder.state == 'enregistrement' and not app.recorder.invalid and h.driver.p > 0.85 then
      app.handleIntents({ raceStart = true })
      launched = true
    end
    if app.recorder.finished > before then
      local last = app.recorder.laps.last
      if launched and last.valid and app.race and app.race.state == 'running' then
        done = true
        break
      end
      if launched and app.race and app.race.state == 'running' then app.handleIntents({ raceCancel = true }) end
      launched = false
    end
  end
  T.ok(done, 'précondition : tour valide terminé pendant le calcul course')
  local queue = queueNames(app)
  T.ok(queue:find('roughness', 1, true), 'précondition : rugosité en attente : ' .. queue)
  -- clic « Calculer qualification » : conditions copiées sans rugosité, suspension encore exclue
  app.handleIntents({ qualiStart = true })
  T.eq(app.quali.state, 'running')
  T.eq(app.quali.conditions, nil, 'état du calcul pris au démarrage de la tâche, pas au clic')
  T.eq(d.space.byKey.springF.class, Space.EXCLUDED, 'précondition : suspension exclue au clic')
  app.handleIntents({ raceCancel = true })
  app.settings.sliceBudgetMs = 8
  for _ = 1, 200000 do
    frame(false)
    if app.quali.state ~= 'running' then break end
  end
  T.eq(app.quali.state, 'done', tostring(app.quali.error))
  local r1, c1 = app.quali.result, app.quali.conditions
  T.ok(d.conditions.roughness and d.conditions.roughness > 0, 'rugosité appliquée à la découverte')
  T.eq(d.space.byKey.springF.class, Space.REDUCED, 'suspension libérée avant le prepare')
  -- calcul cohérent (rugosité copiée), pour comparaison
  app.handleIntents({ qualiStart = true })
  for _ = 1, 200000 do
    frame(false)
    if app.quali.state ~= 'running' then break end
  end
  local r2, c2 = app.quali.result, app.quali.conditions
  PY.note('Z', 'PROBE1 rugosité copiée : ' .. tostring(c1.roughness) .. ' / ' .. tostring(c2.roughness))
  PY.note('Z', 'PROBE1 incohérent : ' .. suspDeltas(r1) .. ' ; tour ' .. tostring(r1.timeProposed))
  PY.note('Z', 'PROBE1 cohérent   : ' .. suspDeltas(r2) .. ' ; tour ' .. tostring(r2.timeProposed))
  T.ok(c1.roughness ~= nil, 'suspension libérée au prepare, rugosité nulle dans les conditions du calcul')
end

-- 2. Deux calculs demandés pendant la découverte : attendu, les deux lancés à sa fin.
tests['Z02 deux calculs demandés pendant la découverte : les deux lancés à sa fin'] = function()
  local h, app = boot()
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  app.settings.optBudgetEvalsQ, app.settings.optBudgetEvalsC = 60, 20
  touch(h)
  app.handleIntents({ qualiStart = true })
  T.ok(app.pendingComputes.quali)
  T.eq(app.discoveryState, 'running')
  app.handleIntents({ raceStart = true })
  PY.note('Z', 'PROBE2 message : ' .. tostring(app.ui.message) .. ' ; attente ' .. tostring(next(app.pendingComputes)))
  T.ok(waitFor(h, function() return app.race and app.race.state ~= 'running' end))
  T.ok(waitFor(h, function() return app.quali ~= nil and app.quali.state ~= 'running' end, nil, 20000),
    'demande qualification perdue sans message')
end

-- 3a. Calcul course en cours effacé par un clic qualification après modification du setup : attendu,
-- un message qui le dit.
tests['Z03 calcul en cours interrompu par une redécouverte : dit dans le message'] = function()
  local h, app = boot()
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  app.settings.optBudgetEvalsC = 400
  app.handleIntents({ raceStart = true })
  frames(h, 5)
  T.eq(app.race.state, 'running')
  touch(h)
  app.handleIntents({ qualiStart = true })
  PY.note('Z', 'PROBE3a message : ' .. tostring(app.ui.message))
  T.eq(app.race, nil, 'calcul course effacé')
  T.ok(app.ui.message:find('course', 1, true), 'message muet sur le calcul course en cours effacé')
end

-- 3b. Séance changée pendant une validation (état fabriqué : setup proposé X, même tour que A) :
-- attendu, une validation qui ne reste pas « en cours ».
tests['Z04 nouvelle séance pendant une validation : validation non figée « en cours »'] = function()
  local h, app = boot()
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  local d = app.discovery
  local profile = trueProfile(app, CarModel.defaultFactors())
  T.ok(waitFor(h, function() return app.recorder.laps.last ~= nil end, profile))
  T.ok(app.recorder.laps.last.valid, tostring(app.recorder.laps.last.reason))
  local A = d.signature
  local known = {}
  for k, v in pairs(app.knownSetups[A]) do known[k] = v end
  known.label = 'setup proposé (qualification)'
  app.knownSetups.X = known
  app.recorder.laps.best.X = app.recorder.laps.best[A]
  app.proposals.quali, app.proposalOrigins.quali = 'X', A
  app.settings.optBudgetEvalsQ = 400
  app.handleIntents({ qualiStart = true })
  app.handleIntents({ validate = 'quali' })
  local v = app.validations.quali
  T.eq(v.state, 'running')
  h.sim.currentSessionIndex = 1
  refresh(h, 2)
  T.eq(app.discoveryState, 'running', 'nouvelle séance : redécouverte')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  frames(h, 600)
  PY.note('Z', 'PROBE3b validation ' .. tostring(v.state) .. ' ; quali ' .. tostring(app.quali) .. ' ; message ' .. tostring(app.ui.message))
  T.ok(v.state ~= 'running', 'validation annulée restée « en cours »')
end

-- 4. Nouveau setup proposé après un verdict (verdict fabriqué, état de fin de M13) : attendu, aucun
-- verdict affiché pour un setup jamais roulé.
tests['Z05 nouvel enregistrement : verdict de validation du setup précédent effacé'] = function()
  local h, app = boot()
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  app.settings.optBudgetEvalsQ = 60
  h.click = 'Calculer le setup tour rapide'
  T.ok(waitFor(h, function() return app.quali and app.quali.state ~= 'running' end))
  h.click = 'Enregistrer le setup tour rapide'
  frames(h, 1)
  local P1 = app.proposals.quali
  T.ok(P1)
  app.validations.quali = { state = 'done', kind = 'quali', predicted = 0.5, measured = 0.48, conforming = true, tolerance = 0.1,
    fuelO = 30, fuelP = 30, calibrated = false }
  app.settings.optBudgetEvalsQ = 300
  app.settings.driverMarginPct = 3
  h.click = 'Calculer le setup tour rapide'
  T.ok(waitFor(h, function() return app.quali and app.quali.state ~= 'running' end))
  h.click = 'Enregistrer le setup tour rapide'
  frames(h, 1)
  local P2 = app.proposals.quali
  frames(h, 1)
  PY.note('Z', 'PROBE4 P1 ' .. tostring(P1) .. ' P2 ' .. tostring(P2) .. ' ; affiché : ' .. tostring(shown(h, 'Validé en jeu')))
  T.ok(P2 ~= P1, 'précondition : nouveau setup proposé')
  T.no(shown(h, 'Validé en jeu'), 'verdict de P1 affiché pour P2')
end

-- 5. Calibration stockée : attendu, la température de piste des tours calibrés.
tests['Z06 calibration stockée avec la température des tours calibrés'] = function()
  local h, app = boot()
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  local discoveryRoad = app.discovery.conditions.roadTemp
  local profile = trueProfile(app, { mu = 0.97, power = 0.99, drag = 1.01, lift = 1.0, brake = 1.0 })
  h.sim.roadTemperature = discoveryRoad + 15
  T.ok(waitFor(h, function()
    if app.calibration and app.calibration.state == 'done' and app.calibration.result.usable then return true end
    return app.recorder.finished >= 4
  end, profile))
  local stored = nil
  for key, entry in pairs(app.store.entries) do
    if key:find('cal', 1, true) == 1 then stored = entry.roadTemp end
  end
  local lapRoad = app.recorder.laps.last.conditions and app.recorder.laps.last.conditions.roadTemp
  PY.note('Z', 'PROBE5 découverte ' .. tostring(discoveryRoad) .. ' ; tour ' .. tostring(lapRoad) .. ' ; stockée ' .. tostring(stored))
  T.ok(stored, 'précondition : calibration stockée')
  T.near(stored, lapRoad, 1, 'température de la découverte stockée avec la calibration')
end

-- 6. Seuil d'adhérence (0,01) : attendu, un écart d'un point signalé (valeurs float32 d'une structure
-- FFI, et cas 0,93 -> 0,94 en double).
tests['Z07 seuils d\'écart des conditions atteints en simple précision'] = function()
  local ffi = require('ffi')
  local function f32(x) return tonumber(ffi.new('float[1]', x)[0]) end
  local h, app = boot()
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  h.sim.roadGrip = f32(0.95)
  refresh(h)
  app.settings.optBudgetEvalsQ = 60
  h.click = 'Calculer le setup tour rapide'
  T.ok(waitFor(h, function() return app.quali and app.quali.state ~= 'running' end))
  h.sim.roadGrip = f32(0.96)
  refresh(h)
  local s1 = app.quali.stale
  app.quali.conditions.roadGrip, h.sim.roadGrip = 0.95, 0.96
  refresh(h)
  local s2 = app.quali.stale
  app.quali.conditions.roadGrip, h.sim.roadGrip = 0.93, 0.94
  refresh(h)
  local s3 = app.quali.stale
  PY.note('Z', 'PROBE6 f32 0,95 -> 0,96 : ' .. tostring(s1) .. ' ; double 0,95 -> 0,96 : ' .. tostring(s2) .. ' ; double 0,93 -> 0,94 : '
    .. tostring(s3))
  T.ok(s1 and s3, 'écart d\'un point d\'adhérence non signalé')
end

-- 7. Identifiant de voiture illisible sur une seule relecture : attendu, calcul en cours conservé.
tests['Z08 voiture illisible sur une relecture : calcul conservé'] = function()
  local h, app = boot()
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  app.settings.optBudgetEvalsQ = 400
  h.click = 'Calculer le setup tour rapide'
  frames(h, 3)
  T.eq(app.quali.state, 'running')
  local original = ac.getCarID
  ac.getCarID = function() return nil end
  refresh(h)
  ac.getCarID = original
  refresh(h)
  frames(h, 120)
  PY.note('Z', 'PROBE7 état du calcul : ' .. tostring(app.quali and app.quali.state) .. ' ; inerte ' .. tostring(app.inert))
  T.ok(app.quali.state ~= 'cancelled', 'calcul annulé par une seule relecture illisible')
end

-- 8. Humidité autour du seuil (± 0,001) : attendu, au plus une redécouverte, résultat conservé.
tests['Z09 humidité autour du seuil : aucune redécouverte en boucle'] = function()
  local h, app = boot()
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  app.settings.optBudgetEvalsQ = 60
  h.click = 'Calculer le setup tour rapide'
  T.ok(waitFor(h, function() return app.quali and app.quali.state ~= 'running' end))
  h.click = 'Enregistrer le setup tour rapide'
  frames(h, 1)
  T.ok(app.quali.saved and app.quali.saved.ok)
  local count = 0
  for i = 1, 4 do
    h.sim.rainWetness = (i % 2 == 1) and (Config.K.wetThreshold + 0.001) or (Config.K.wetThreshold - 0.001)
    refresh(h, 2)
    if app.discoveryState == 'running' then count = count + 1 end
    T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  end
  PY.note('Z', 'PROBE8 redécouvertes : ' .. count .. ' ; résultat qualification ' .. tostring(app.quali))
  T.ok(count <= 1, '' .. count .. ' redécouvertes pour une humidité qui oscille autour du seuil')
end

-- 9. Week-end : setup qualification enregistré en essai, puis séance de qualification : attendu, le
-- bouton « Charger » toujours là.
tests['Z10 nouvelle séance : setup enregistré toujours chargeable'] = function()
  local h, app = boot()
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  app.settings.optBudgetEvalsQ = 60
  h.click = 'Calculer le setup tour rapide'
  T.ok(waitFor(h, function() return app.quali and app.quali.state ~= 'running' end))
  h.click = 'Enregistrer le setup tour rapide'
  frames(h, 1)
  T.ok(app.quali.saved and app.quali.saved.ok)
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  frames(h, 1)
  T.ok(shown(h, 'Charger le setup tour rapide dans la voiture'), 'précondition : bouton présent')
  h.click = 'Charger le setup tour rapide dans la voiture'
  frames(h, 1)
  T.ok(app.loadArm, tostring(app.ui.message))
  h.sim.currentSessionIndex, h.sim.raceSessionType = 1, 2
  refresh(h, 2)
  T.eq(app.discoveryState, 'running')
  local disarm = app.ui.message
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  frames(h, 2)
  PY.note('Z', 'PROBE9 message au désarmement : ' .. tostring(disarm) .. ' ; bouton : '
    .. tostring(shown(h, 'Charger le setup tour rapide dans la voiture')) .. ' ; fichier '
    .. tostring(app.lastSaved and app.lastSaved.quali and app.lastSaved.quali.file))
  T.ok(shown(h, 'Charger le setup tour rapide dans la voiture'), 'bouton Charger perdu après la nouvelle séance')
  -- et le chargement s'arme (le setup enregistré ne dépend pas du résultat effacé)
  h.click = 'Charger le setup tour rapide dans la voiture'
  frames(h, 1)
  T.ok(app.loadArm, 'chargement armé après la nouvelle séance : ' .. tostring(app.ui.message))
end

return tests
