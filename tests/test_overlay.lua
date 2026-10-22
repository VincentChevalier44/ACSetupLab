-- Overlay en jeu (bêta 1.3, demande de Vincent du 22/10/2026 : « un petit overlay qui va permettre d'avoir une petite
-- synthèse des réglages qui ont été changés, de voir directement s'il y a un gain ou s'il y a une perte au niveau de
-- chaque réglage », « si le setup est mieux ou moins bien »). Réponses : compact ; gain prévu chiffré par réglage.
-- Le verdict vient de vos tours (le setup entier), le gain par réglage du modèle.
local T = require('t')
local Config = require('src/config')
local CarModel = require('src/car_model')
local Sim = require('src/laptime_sim')
local Fake = require('fakehost')

local TRUTH = { mu = 0.96, power = 0.98, drag = 1.02, lift = 1.0, brake = 1.0 }

local tests = {}

local function boot()
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  h.sim.raceSessionType = 2
  h.texts = {}
  local function capture(text) h.texts[#h.texts + 1] = text end
  local text, wrapped, colored = h.ui.text, h.ui.textWrapped, h.ui.textColored
  h.ui.text = function(s) capture(s); return text(s) end
  h.ui.textWrapped = function(s) capture(s); return wrapped(s) end
  h.ui.textColored = function(s, c) capture(s); return colored(s, c) end
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  app.utcOffset = function() return 7200 end
  app.settings.optBudgetEvalsQ, app.settings.optBudgetEvalsC = 80, 20
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

local function waitFor(h, predicate, maxFrames, profile)
  for i = 1, maxFrames or 60000 do
    frames(h, 1, profile)
    if predicate() then return i end
  end
  return nil
end

-- Une image de l'overlay seul : ses textes.
local function overlay(h)
  h.texts = {}
  script.SETUPLAB__OVERLAY(1 / 60)
  return h.texts
end

local function find(texts, fragment)
  for _, text in ipairs(texts) do
    if text:find(fragment, 1, true) then return text end
  end
  return nil
end

local function spinner(h, name)
  for _, sp in ipairs(h.spinners) do
    if sp.name == name then return sp end
  end
  return nil
end

local function drivenProfile(h, app)
  local d = app.discovery
  local fuel = spinner(h, 'FUEL') and spinner(h, 'FUEL').value or 30
  local setup = app.physicalSetup(d, nil, nil)
  setup.fuel = fuel
  local compound = d.carBase.compounds[setup.compound]
  local temp = CarModel.operatingTemp(compound.front)
  for w = 0, 3 do
    h.car.wheels[w].tyreCoreTemperature = temp
    h.car.wheels[w].tyrePressure = CarModel.hotPressure(w < 2 and setup.pressureF or setup.pressureR, d.conditions.airTemp, temp)
    h.car.wheels[w].tyreVirtualKM = 0.5
  end
  h.car.fuel = fuel
  local conditions = { airTemp = d.conditions.airTemp, roadGrip = d.conditions.roadGrip, surfaceGrip = d.conditions.surfaceGrip,
    factors = TRUTH }
  local eff = assert(CarModel.configure(d.carBase, setup, conditions))
  local result, buf = Sim.run(d.trackModel, eff, nil)
  local profile = { p = {}, v = {}, time = result.time }
  for k = 1, d.trackModel.n do profile.p[k], profile.v[k] = d.trackModel.p[k], buf.v[k] end
  profile.p[#profile.p + 1], profile.v[#profile.v + 1] = 1, buf.v[1]
  return profile
end

local function loadAtPit(h, app)
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  h.driver = nil
  frames(h, 1)
  h.click = 'Charger le setup tour rapide dans la voiture'
  frames(h, 1)
  T.ok(app.loadArm, tostring(app.ui.message))
  local started = app.clock()
  while app.clock() - started < Config.K.loadConfirmMinSeconds + 0.1 do frames(h, 1) end
  h.click = 'Confirmer le chargement (tour rapide)'
  frames(h, 1)
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'constat du chargement')
  T.ok(app.loadTest and app.loadTest.ok, tostring(app.loadTest and app.loadTest.reason) .. ' / ' .. tostring(app.ui.message))
end

tests['OV01 overlay sans setup de SetupLab dans la voiture : dit, sans erreur, même avant la découverte'] = function()
  local h, app = boot()
  local texts = overlay(h)
  T.ok(find(texts, 'aucun setup de SetupLab en piste'), 'dit avant la découverte')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  texts = overlay(h)
  T.ok(find(texts, 'aucun setup de SetupLab en piste'))
  T.ok(find(texts, 'SetupLab actif'), 'que faire')
  T.eq(app.perf.errors, 0)
end

tests['OV02 version roulée : verdict sur vos tours, réglages du plus au moins important avec leur gain prévu'] = function()
  local h, app = boot()
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  app.settings.compoundChoice = app.discovery.compoundIndex
  h.click = 'Affinage automatique (tour rapide)'
  frames(h, 1)
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end), 'v1')
  -- version prête, pas encore dans la voiture : annoncée en bas
  local texts = overlay(h)
  T.ok(find(texts, 'v1 prête : +'), 'version prête annoncée')
  -- un tour avec le setup de départ (« avant »)
  local profile = drivenProfile(h, app)
  T.ok(waitFor(h, function()
    local f = app.recorder.laps.family[r.history[#r.history].originFamily]
    return f ~= nil and f.count >= 1 and r.phase == 'tours'
  end, nil, profile), 'un tour propre avant')
  h.click = 'Valider v' .. r.version
  frames(h, 1, profile)
  local v = r.history[#r.history]
  T.eq(v.status, 'validée', tostring(app.ui.message))
  loadAtPit(h, app)
  T.ok(waitFor(h, function() return not r.needsDiscovery and app.discoveryState == 'done' end))
  profile = drivenProfile(h, app)
  T.ok(waitFor(h, function()
    local f = app.recorder.laps.family[v.family]
    return f ~= nil and f.count >= 1
  end, 120000, profile), 'un tour propre avec v' .. v.version)
  texts = overlay(h)
  T.ok(find(texts, 'SetupLab · v' .. v.version .. ' en piste (Qualif, sec)'), 'version en piste')
  T.ok(find(texts, 'Meilleur ') and find(texts, 'avant '), 'vos temps avec et avant')
  T.ok(find(texts, 'Mieux de ') or find(texts, 'Moins bien de ') or find(texts, 'Identique'), 'verdict')
  T.ok(find(texts, 'Dernier tour '), 'dernier tour')
  -- réglages : le plus important d'abord, quatre au plus, le reste sur une ligne
  local list = {}
  for _, c in ipairs(v.changeList) do list[#list + 1] = c end
  table.sort(list, function(a, b) return math.abs(a.contribution) > math.abs(b.contribution) end)
  T.ok(#list >= 1, 'des réglages changés')
  local firstRow, secondRow = nil, nil
  for i, text in ipairs(texts) do
    if text == list[1].var.label and firstRow == nil then firstRow = i end
    if list[2] and text == list[2].var.label and secondRow == nil then secondRow = i end
  end
  T.ok(firstRow, 'réglage le plus important affiché : ' .. list[1].var.label)
  if list[2] then T.ok(secondRow and secondRow > firstRow, 'ordre du gain prévu') end
  if #list > 4 then
    T.ok(find(texts, '+ ' .. (#list - 4) .. ' autre'), 'le reste regroupé')
    T.no(find(texts, list[5].var.label .. ''), 'cinquième réglage non détaillé')
  end
  T.ok(find(texts, 'Par réglage : gain prévu par le modèle'), 'prévu et réel distingués')
  PY.note('OV02', table.concat(texts, ' | '))
  -- sans affinage : la référence de la mémoire chargée
  app.refine = nil
  texts = overlay(h)
  T.ok(find(texts, 'Setup de la mémoire du circuit : ' .. v.file), tostring(texts[1]))
  T.eq(app.perf.errors, 0)
end

return tests
