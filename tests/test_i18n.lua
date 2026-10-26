-- Interface en anglais (décision de Vincent du 26/10/2026 : « il faut absolument tout traduire, les menus, toute
-- l'application complète ainsi que les tooltips explicatifs ») : les parcours principaux rejoués en anglais, toutes les
-- infobulles survolées et toutes les sections ouvertes ; chaque texte affiché resté en français est un oubli du
-- dictionnaire (tests/tools/lang_en.py). Aussi : les annonces à l'écran, l'overlay et la fenêtre de diagnostic.
local T = require('t')
local Config = require('src/config')
local L = require('src/i18n')
local CarModel = require('src/car_model')
local Sim = require('src/laptime_sim')
local Fake = require('fakehost')

local TRUTH = { mu = 0.96, power = 0.98, drag = 1.02, lift = 1.0, brake = 1.0 }
local EN_STORE = 'setuplab-store 1|settings#refineMinLaps=0|settings#language=s:en'

local tests = {}

local function boot(carId, session)
  local h = Fake.new({ car = require('fixtures/cars/' .. (carId or 'lamborghini_huracan_gt3_evo2')),
    track = require('fixtures/tracks/monza'), stored = { ['setuplab:data'] = EN_STORE }, lang = 'en' })
  h.sim.raceSessionType = session or 2
  h.hover, h.openSections = true, true
  h.shown = {}
  local function capture(text) h.shown[#h.shown + 1] = text end
  local text, wrapped, colored = h.ui.text, h.ui.textWrapped, h.ui.textColored
  h.ui.text = function(s) capture(s); return text(s) end
  h.ui.textWrapped = function(s) capture(s); return wrapped(s) end
  h.ui.textColored = function(s, c) capture(s); return colored(s, c) end
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  app.utcOffset = function() return 7200 end
  app.settings.optBudgetEvalsQ, app.settings.optBudgetEvalsC = 60, 20
  return h, app
end

local function frames(h, n, profile)
  for _ = 1, n do
    if profile then
      h.car.isInPit, h.car.isInPitlane = false, false
      Fake.drive(h, profile, 1 / 60)
    end
    h.sim.time = h.sim.time + 1000 / 60
    script.SETUPLAB__UPDATE(1 / 60)
    script.SETUPLAB__MAIN(1 / 60)
  end
end

-- Une image de chaque fenêtre (principale, overlay, diagnostic).
local function render(h)
  h.sim.time = h.sim.time + 1000 / 60
  script.SETUPLAB__UPDATE(1 / 60)
  script.SETUPLAB__MAIN(1 / 60)
  script.SETUPLAB__OVERLAY(1 / 60)
  script.SETUPLAB__DEBUG(1 / 60)
end

local function waitFor(h, predicate, maxFrames, profile)
  for i = 1, maxFrames or 60000 do
    frames(h, 1, profile)
    if predicate() then return i end
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

local function stop(h)
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  h.driver = nil
end

local function load(h, app, kind)
  stop(h)
  frames(h, 1)
  app.handleIntents({ loadArm = kind or 'quali' })
  render(h)
  local started = app.clock()
  while app.clock() - started < Config.K.loadConfirmMinSeconds + 0.1 do frames(h, 1) end
  app.handleIntents({ loadConfirm = kind or 'quali' })
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'chargement')
  render(h)
end

local function report(name)
  local list = {}
  for fr, out in pairs(L.misses) do list[#list + 1] = fr .. '  =>  ' .. out end
  table.sort(list)
  PY.note(name, #list .. ' texte(s) non traduit(s)')
  for i = 1, math.min(#list, 8000) do PY.note(name .. ' ' .. i, list[i]) end
  return #list
end

tests['EN01 parcours complet en anglais (affinage, essai, tri, validation, overlay, mémoire, course, réglages)'] = function()
  L.misses = {}
  L.reset()
  local h, app = boot()
  T.eq(app.settings.language, 'en')
  render(h)
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'discovery')
  app.settings.compoundChoice = app.discovery.compoundIndex
  render(h)
  -- affinage, version, essai, tri, validation
  app.handleIntents({ autoToggle = true })
  T.ok(waitFor(h, function() return app.refine and app.refine.version >= 1 and app.refine.phase == 'tours' end), 'v1')
  render(h)
  local r = app.refine
  local e = r.history[#r.history]
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'essayer' } })
  render(h)
  load(h, app)
  T.ok(waitFor(h, function() return not r.needsDiscovery and app.discoveryState == 'done' end))
  local profile = drivenProfile(h, app)
  T.ok(waitFor(h, function()
    local f = app.recorder.laps.family[e.family]
    return f ~= nil and f.count >= 1
  end, 150000, profile), 'a lap with the trial')
  render(h)
  stop(h)
  frames(h, 30)
  render(h)
  if e.groups[1] then app.handleIntents({ effect = { version = e.version, key = e.groups[1].key, keep = false } }) end
  render(h)
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  render(h)
  frames(h, 30)
  render(h)
  load(h, app)
  render(h)
  app.handleIntents({ refineLock = e.version })
  render(h)
  app.handleIntents({ memoryLock = { key = 'qualif|sec', locked = false } })
  render(h)
  -- course : garde, puis calcul
  app.handleIntents({ raceStart = true })
  render(h)
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'discovery before the race')
  Fake.raceReady(h, app, 12)
  app.handleIntents({ raceStart = true })
  T.ok(waitFor(h, function() return app.race and app.race.state ~= 'running' end), 'race')
  render(h)
  app.handleIntents({ raceSave = true })
  render(h)
  -- calcul à la main, enregistrement, mesure, rapport
  app.handleIntents({ qualiStart = true })
  T.ok(waitFor(h, function() return app.quali and app.quali.state ~= 'running' end), 'quali')
  render(h)
  app.handleIntents({ qualiSave = true })
  render(h)
  app.handleIntents({ validate = 'quali' })
  render(h)
  app.handleIntents({ calibrate = true })
  frames(h, 60)
  render(h)
  app.handleIntents({ saveCopy = true })
  render(h)
  -- pluie
  h.sim.rainWetness, h.sim.rainWater = 1, 0.6
  app.nextContextAt = 0
  frames(h, 2)
  app.handleIntents({ qualiStart = true })
  waitFor(h, function() return app.quali and app.quali.state ~= 'running' end)
  render(h)
  h.sim.rainWetness, h.sim.rainWater = 0, 0
  -- en ligne : inerte
  h.sim.isOnlineRace = true
  app.nextContextAt = 0
  frames(h, 2)
  render(h)
  h.sim.isOnlineRace = false
  app.nextContextAt = 0
  frames(h, 2)
  render(h)
  T.eq(app.perf.errors, 0)
  local n = report('EN01')
  L.misses = nil
  T.eq(n, 0, 'tout est traduit')
end

tests['EN02 annonces à l\'écran et séance de course en anglais'] = function()
  L.misses = {}
  L.reset()
  local h, app = boot(nil, 3)
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'discovery')
  app.handleIntents({ autoToggle = true })
  frames(h, 60)
  render(h)
  local h2, app2 = boot()
  T.ok(waitFor(h2, function() return app2.discoveryState == 'done' end))
  app2.handleIntents({ autoToggle = true })
  T.ok(waitFor(h2, function() return app2.refine and app2.refine.version >= 1 end))
  render(h2)
  for _, m in ipairs(h2.messages or {}) do
    if L.looksFrench(m.title) then L.misses[m.title] = m.title end
    if L.looksFrench(m.description) then L.misses[m.description] = m.description end
  end
  -- mises en garde et échecs dits
  app2.discoveryState, app2.discoveryError = 'failed', 'simulated error'
  render(h2)
  T.eq(app.perf.errors + app2.perf.errors, 0)
  local n = report('EN02')
  L.misses = nil
  T.eq(n, 0, 'tout est traduit')
end

return tests
