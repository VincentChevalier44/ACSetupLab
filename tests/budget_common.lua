-- Mesure commune des tests de budget (§14.3) : chaque test reste seul dans son fichier (environnement
-- Lua neuf, tas et état du JIT représentatifs de l'app seule) et passe par ici.
--
-- Comme la colle : tracé grossier construit dans la tâche (même règle de pas), préparation, puis calcul
-- au budget réglé (déterministe, §10.5). Temps réel = temps du calcul / (tranche × 60 images/s).
--
-- Charge de la machine : d'autres processus peuvent ralentir le banc. Une tâche de référence fixe
-- (modèle et tour de la Huracán à Monza) est chronométrée avant et après le calcul : son minimum approche
-- la vitesse de la machine au calme, sa médiane la vitesse sous la charge du moment ; le temps mesuré est
-- ramené au calme par ce rapport (les deux valeurs sont relevées). Approximation : une charge qui varie
-- pendant le calcul lui échappe ; la mesure d'acceptation du §14.3 est faite machine calme (RELECTURE_J8).
local Util = require('src/util')
local Config = require('src/config')
local Datasource = require('src/datasource')
local TrackModel = require('src/track_model')
local CarModel = require('src/car_model')
local Space = require('src/setup_space')
local Optimizer = require('src/optimizer')
local Fake = require('fakehost')

local K = Config.K
local SYNC = Util.syncContext()
local M = {}

local reference = nil

-- Rapport (≥ 1) entre la durée médiane et la durée minimale de la tâche de référence, sur 25 mesures.
local function loadFactor()
  local Sim = require('src/laptime_sim')
  if reference == nil then
    local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
    local raw = Datasource.sampleTrack(h, 1, SYNC)
    Datasource.probeBank(h, raw, SYNC)
    local track = assert(TrackModel.build(raw, Datasource.readTrackFiles(h, SYNC), 2))
    local base = CarModel.build(Datasource.readCar(h, 0, SYNC), nil)
    reference = { track = track, base = base, setup = CarModel.defaultSetup(base), buf = Sim.new(track) }
  end
  local times = {}
  local eff = nil
  for i = 1, 28 do
    local started = PY.clock()
    eff = CarModel.configure(reference.base, reference.setup, { airTemp = 24 }, nil, eff)
    Sim.run(reference.track, eff, reference.buf, {})
    if i > 3 then times[#times + 1] = PY.clock() - started end
  end
  table.sort(times)
  return times[math.ceil(#times / 2)] / times[1]
end

-- opts : { car, track = 'monza', hostOpts?, drs?, ers?, roughness?, release? (genres de réglages libérés),
-- race = { fuelPerLapCsp, kmPerLapF, kmPerLapR } }.
function M.run(opts)
  local hostOpts = { car = require('fixtures/cars/' .. opts.car), track = require('fixtures/tracks/' .. (opts.track or 'monza')) }
  for key, value in pairs(opts.hostOpts or {}) do hostOpts[key] = value end
  local h = Fake.new(hostOpts)
  local car = Datasource.readCar(h, 0, SYNC)
  local state = Datasource.readCarState(h, 0)
  local setup = Datasource.readSetup(h, SYNC)
  local raw = Datasource.sampleTrack(h, 1, SYNC)
  Datasource.probeBank(h, raw, SYNC)
  local files = Datasource.readTrackFiles(h, SYNC)
  local track = assert(TrackModel.build(raw, files, Config.defaults().ds))
  local base = CarModel.build(car, nil)
  local space = Space.build({ setupIni = car.ini['setup.ini'], spinners = setup.spinners, ratios = car.ratios })
  Space.verify(space, state, base)
  Space.attach(space, base)
  for _, kind in ipairs(opts.release or {}) do Space.release(space, kind, Space.REDUCED, 'test de budget') end
  local settings = Config.defaults()
  local conditions = { airTemp = 24, roadGrip = 0.98, surfaceGrip = track.surfaceGrip, roughness = opts.roughness }
  local loadBefore = loadFactor()
  -- une « tâche » : tracé grossier, préparation, calcul
  local function task(kind)
    collectgarbage('collect')
    local started = PY.clock()
    local coarse = nil
    local coarseDs = math.min(K.trackAutoMaxDs, track.ds * K.optCoarseDsFactor)
    if coarseDs >= track.ds * K.optCoarseMinRatio then coarse = assert(TrackModel.build(raw, files, coarseDs)) end
    local budget = kind == 'race' and settings.optBudgetEvalsC or settings.optBudgetEvalsQ
    local s = Optimizer.newState({ budget = budget })
    local args = { base = base, space = space, track = track, trackCoarse = coarse, settings = settings, budget = budget,
      conditions = conditions, drs = opts.drs, ers = opts.ers, race = kind == 'race' and opts.race or nil }
    local r
    if kind == 'race' then
      r = assert(Optimizer.runRace(Optimizer.prepareRace(args), SYNC, s))
    else
      r = assert(Optimizer.runQuali(Optimizer.prepareQuali(args), SYNC, s))
    end
    return r, s, PY.clock() - started
  end
  local rq, sq, quali = task('quali')
  settings.raceLaps = 20
  local rr, sr, race = task('race')
  local load = (loadBefore + loadFactor()) / 2
  local perSecond = settings.sliceBudgetMs / 1000 * K.fpsTarget
  local out = {
    variables = #Space.optimizable(space), evalQ = sq.evaluations, evalC = sr.evaluations, quali = quali, race = race,
    realQ = quali / perSecond, realC = race / perSecond, gainQ = rq.timeCurrent - rq.timeProposed,
    gainC = rr.timeCurrent - rr.timeProposed, changesQ = #rq.changes, changesC = #rr.changes, refinedQ = rq.refined,
    refinedC = rr.refined, drsUsable = base.drs and base.drs.usable,
    trackDs = track.ds,
  }
  out.total = out.realQ + out.realC
  -- ramené au calme (charge de la machine pendant la mesure)
  out.load = load
  out.calmTotal = out.total / load
  out.text = string.format('%d variables, pas %.2f m ; qualification %d évaluations, %.1f s de calcul (≈ %.0f s réelles), '
    .. '%d réglages, gain %.3f s ; course %d relais, %.1f s (≈ %.0f s réelles), %d réglages, gain %.3f s/tour ; total ≈ %.0f s, '
    .. 'charge ×%.2f, ≈ %.0f s au calme',
    out.variables, track.ds, sq.evaluations, quali, out.realQ, out.changesQ, out.gainQ, sr.evaluations, race, out.realC,
    out.changesC, out.gainC, out.total, load, out.calmTotal)
  return out
end

return M
