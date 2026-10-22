-- Endurance (§14.2) : 1 000 découvertes enchaînées par la colle, puis des calculs qualification
-- enchaînés (un sur quatre annulé en cours), mémoire stable, aucune erreur.
local Fake = require('fakehost')

return function(iterations)
  iterations = iterations or 1000
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  local frames, completed = 0, 0
  local function frame()
    h.sim.time = h.sim.time + 16.7
    script.SETUPLAB__UPDATE(0.0167)
    script.SETUPLAB__MAIN(0.0167)
    frames = frames + 1
  end
  local memory = {}
  local started = PY.clock()
  for i = 1, iterations do
    while app.discoveryState ~= 'done' or app.report == nil do
      frame()
      assert(frames < iterations * 400, 'découverte bloquée')
    end
    completed = completed + 1
    if i == 10 or i == iterations then
      jit.flush()  -- traces compilées : objets du tas, hors des données de l'app
      collectgarbage('collect')
      collectgarbage('collect')
      memory[#memory + 1] = collectgarbage('count')
    end
    if i < iterations then
      h.click = 'Relancer la découverte'
      frame()
    end
  end
  local seconds = PY.clock() - started
  assert(app.perf.errors == 0, 'erreurs : ' .. app.perf.errors)
  assert(h.writeCalls == 0)
  local growthKb = memory[#memory] - memory[1]
  -- bornes : traces du JIT exclues (jit.flush avant chaque relevé) ; mesuré 35 Kio pour 1 000 découvertes
  assert(growthKb < 256, 'croissance mémoire ' .. growthKb .. ' Kio')
  -- calculs qualification enchaînés
  app.settings.optBudgetEvalsQ = 150
  local qualiRuns, cancelled, qualiMemory = 40, 0, {}
  local qualiStarted = PY.clock()
  for i = 1, qualiRuns do
    h.click = 'Calculer le setup tour rapide'
    frame()
    assert(app.quali and app.quali.state == 'running', 'calcul non lancé : ' .. tostring(app.ui.message))
    if i % 4 == 0 then
      for _ = 1, 20 do frame() end
      h.click = 'Annuler le calcul'
      frame()
      assert(app.quali.state == 'cancelled', 'annulation : ' .. tostring(app.quali.state))
      cancelled = cancelled + 1
    else
      while app.quali.state == 'running' do
        frame()
        assert(frames < iterations * 400 + qualiRuns * 4000, 'calcul bloqué')
      end
      assert(app.quali.state == 'done', 'calcul : ' .. tostring(app.quali.error))
    end
    if i == 8 or i == qualiRuns then
      jit.flush()  -- traces compilées : objets du tas, hors des données de l'app
      collectgarbage('collect')
      collectgarbage('collect')
      qualiMemory[#qualiMemory + 1] = collectgarbage('count')
    end
  end
  assert(app.perf.errors == 0, 'erreurs : ' .. app.perf.errors)
  local qualiGrowthKb = qualiMemory[#qualiMemory] - qualiMemory[1]
  assert(qualiGrowthKb < 64, 'croissance mémoire (tour rapide) ' .. qualiGrowthKb .. ' Kio')
  -- tours enregistrés (J5) : 24 tours roulés par le conducteur simulé, calibration automatique après
  -- chaque tour valide, un tour sur six invalidé, setup changé tous les huit tours (setup inconnu)
  local CarModel = require('src/car_model')
  local SetupSpace = require('src/setup_space')
  local Sim = require('src/laptime_sim')
  local d = app.discovery
  local setup = SetupSpace.apply(d.space, CarModel.defaultSetup(d.carBase), {})
  local eff = assert(CarModel.configure(d.carBase, setup, { airTemp = d.conditions.airTemp,
    factors = { mu = 0.96, power = 0.98, drag = 1.02, lift = 1, brake = 1 } }))
  local _, buf = Sim.run(d.trackModel, eff, nil)
  local profile = { p = {}, v = {} }
  for k = 1, d.trackModel.n do profile.p[k], profile.v[k] = d.trackModel.p[k], buf.v[k] end
  profile.p[#profile.p + 1], profile.v[#profile.v + 1] = 1, buf.v[1]
  local laps, lapMemory = 24, {}
  local lapStarted = PY.clock()
  local startCount = h.car.lapCount
  local calibrations = 0
  local lastFinished = app.recorder.finished
  local changedLap = nil
  while h.car.lapCount < startCount + laps + 1 do
    h.car.isInPit, h.car.isInPitlane = false, false
    local lap = h.car.lapCount - startCount
    h.car.isLapValid = lap % 6 ~= 3 or (h.driver and h.driver.p or 0) < 0.5
    -- un seul changement de cran par tour concerné (S1 puis S2, en alternance) : sinon le cran dérive à
    -- chaque image et crée de nouveaux setups, et la mesure ne compare plus des nombres de tours
    -- conservés égaux
    if lap % 8 == 7 and changedLap ~= lap and h.spinners[1] then
      h.spinners[1].value = h.spinners[1].value + (lap % 16 == 7 and 1 or -1)
      changedLap = lap
    end
    Fake.drive(h, profile, 1 / 30)
    h.sim.time = h.sim.time + 1000 / 30
    script.SETUPLAB__UPDATE(1 / 30)
    script.SETUPLAB__MAIN(1 / 30)
    frames = frames + 1
    if app.recorder.finished ~= lastFinished then
      lastFinished = app.recorder.finished
      if app.calibration and app.calibration.state == 'running' then calibrations = calibrations + 1 end
      -- mesures à nombre de meilleurs tours conservés égal (setups S1 et S2 dès le 8e tour)
      if lastFinished == 12 or lastFinished == laps then
        jit.flush()  -- traces compilées : objets du tas, hors des données de l'app
        collectgarbage('collect')
        collectgarbage('collect')
        lapMemory[#lapMemory + 1] = collectgarbage('count')
      end
    end
  end
  assert(app.perf.errors == 0, 'erreurs : ' .. app.perf.errors)
  assert(h.writeCalls == 0, 'aucune écriture pendant l\'enregistrement')
  local lapGrowthKb = lapMemory[#lapMemory] - lapMemory[1]
  assert(lapGrowthKb < 64, 'croissance mémoire (tours) ' .. lapGrowthKb .. ' Kio')
  assert(calibrations > 0, 'calibrations automatiques')
  -- calculs course enchaînés (J6), un sur quatre annulé en cours ; relance de la découverte d'abord
  -- (le setup a changé pendant la phase précédente)
  h.click = 'Relancer la découverte'
  frame()
  while app.discoveryState ~= 'done' do frame() end
  app.settings.optBudgetEvalsC, app.settings.raceLaps = 30, 10
  local raceRuns, raceCancelled, raceMemory = 16, 0, {}
  local raceStarted = PY.clock()
  for i = 1, raceRuns do
    h.click = 'Calculer le setup course'
    frame()
    assert(app.race and app.race.state == 'running', 'calcul course non lancé : ' .. tostring(app.ui.message))
    if i % 4 == 0 then
      for _ = 1, 20 do frame() end
      h.click = 'Annuler le calcul course'
      frame()
      assert(app.race.state == 'cancelled', 'annulation course : ' .. tostring(app.race.state))
      raceCancelled = raceCancelled + 1
    else
      while app.race.state == 'running' do frame() end
      assert(app.race.state == 'done', 'calcul course : ' .. tostring(app.race.error))
    end
    if i == 4 or i == raceRuns then
      jit.flush()  -- traces compilées : objets du tas, hors des données de l'app
      collectgarbage('collect')
      collectgarbage('collect')
      raceMemory[#raceMemory + 1] = collectgarbage('count')
    end
  end
  assert(app.perf.errors == 0, 'erreurs : ' .. app.perf.errors)
  local raceGrowthKb = raceMemory[#raceMemory] - raceMemory[1]
  assert(raceGrowthKb < 64, 'croissance mémoire (course) ' .. raceGrowthKb .. ' Kio')
  return {
    raceRuns = raceRuns, raceCancelled = raceCancelled, raceGrowthKb = raceGrowthKb, raceSeconds = PY.clock() - raceStarted,
    laps = app.recorder.finished, lapCalibrations = calibrations, lapGrowthKb = lapGrowthKb,
    lapSeconds = PY.clock() - lapStarted,
    iterations = completed, frames = frames, seconds = seconds, memoryAfter10Kb = memory[1],
    memoryEndKb = memory[#memory], growthKb = growthKb, maxSliceMs = app.scheduler.stats.maxSliceMs,
    avgFrameMs = app.perf.avgMs, completedTasks = app.scheduler.stats.completed,
    qualiRuns = qualiRuns, qualiCancelled = cancelled, qualiSeconds = PY.clock() - qualiStarted,
    qualiGrowthKb = qualiGrowthKb, slowSlices = app.perf.slowSlices,
  }
end
