-- Tests de src/stint_sim et de l'optimisation course (J6, §8.7, §10.2, §10.6).
local T = require('t')
local Util = require('src/util')
local Config = require('src/config')
local Datasource = require('src/datasource')
local TrackModel = require('src/track_model')
local CarModel = require('src/car_model')
local Space = require('src/setup_space')
local Optimizer = require('src/optimizer')
local StintSim = require('src/stint_sim')
local Fake = require('fakehost')

local K = Config.K
local SYNC = Util.syncContext()
local tests = {}

local cache = {}
local function world(carId, trackId)
  local key = carId .. '@' .. trackId
  if cache[key] then return cache[key] end
  local h = Fake.new({ car = require('fixtures/cars/' .. carId), track = require('fixtures/tracks/' .. trackId) })
  local car = Datasource.readCar(h, 0, SYNC)
  local state = Datasource.readCarState(h, 0)
  local setup = Datasource.readSetup(h, SYNC)
  local raw = Datasource.sampleTrack(h, 1, SYNC)
  Datasource.probeBank(h, raw, SYNC)
  local files = Datasource.readTrackFiles(h, SYNC)
  local track = assert(TrackModel.build(raw, files, 2))
  local coarse = assert(TrackModel.build(raw, files, 4))
  local base = CarModel.build(car, nil)
  local space = Space.build({ setupIni = car.ini['setup.ini'], spinners = setup.spinners, ratios = car.ratios })
  Space.verify(space, state, base)
  Space.attach(space, base)
  cache[key] = { h = h, track = track, coarse = coarse, base = base, space = space }
  return cache[key]
end

local CONDITIONS = { airTemp = 24, roadGrip = 0.98 }
local WEIGHTS = { bal = 1, stab = 1, traffic = 1, rob = 1 }

-- Copie d'un composé avec une courbe d'usure donnée (km -> %).
local function withWear(compound, xs, ys)
  local copy = { index = compound.index, name = compound.name, short = compound.short, front = {}, rear = {} }
  for key, value in pairs(compound.front) do copy.front[key] = value end
  for key, value in pairs(compound.rear) do copy.rear[key] = value end
  copy.front.wear, copy.rear.wear = Util.lutNew(xs, ys), Util.lutNew(xs, ys)
  return copy
end

tests['L01 plan du relais : carburant décroissant, km linéaires, échantillons'] = function()
  local plan = StintSim.plan({ laps = 20, fuelStart = 60, fuelPerLap = 2.8, kmPerLapF = 5, kmPerLapR = 6, trafficFraction = 0.3,
    slipstreamDrag = 0.15, dirtyAirLift = 0.1 })
  T.near(StintSim.lapFuel(plan, 1), 60 - 1.4, 1e-12)
  T.near(StintSim.lapFuel(plan, 20), 60 - 19.5 * 2.8, 1e-12)
  local f, r = StintSim.lapKm(plan, 3)
  T.near(f, 12.5, 1e-12)
  T.near(r, 15, 1e-12)
  -- carburant jamais négatif
  T.eq(StintSim.lapFuel(StintSim.plan({ laps = 5, fuelStart = 1, fuelPerLap = 3 }), 5), 0)
  -- échantillons : 1, N, le vrai tour du milieu, puis les niveaux d'usure extrêmes
  local w = world('lamborghini_huracan_gt3_evo2', 'monza')
  local compound = withWear(w.base.compounds[1], { 0, 40, 60, 200 }, { 100, 100, 90, 85 })
  local ev = StintSim.newEvaluator({ base = { compounds = { compound } }, track = w.track, conditions = CONDITIONS,
    plan = StintSim.plan({ laps = 20, kmPerLapF = 5, kmPerLapR = 5 }), compound = 1, weights = WEIGHTS })
  local samples, middle = ev.samples, ev.middle
  T.eq(samples[1], 1)
  T.eq(samples[#samples], 20)
  T.eq(samples[middle], 10, 'vrai tour du milieu')
  T.ok(#samples <= K.raceMaxSamples)
  T.near(ev.levelF[1], 100, 1e-9)
  T.near(ev.levelF[20], 100 - (97.5 - 60) / 140 * 5 - 10, 1e-9, 'niveau d\'usure connu à chaque tour')
  -- relais court : tous les tours
  local short = StintSim.plan({ laps = 3 })
  T.eq(#(StintSim.sampleLaps(short, { 100, 100, 100 }, { 100, 100, 100 })), 3)
end

tests['L02 relais échantillonné contre relais exact : falaise d\'usure, même classement'] = function()
  local w = world('lamborghini_huracan_gt3_evo2', 'monza')
  -- courbe d'usure qui chute brutalement en plein relais (falaise entre 50 et 56 km)
  local base = {}
  for key, value in pairs(w.base) do base[key] = value end
  base.compounds = { withWear(w.base.compounds[2], { 0, 2, 50, 56, 300 }, { 98, 100, 99, 88, 84 }) }
  local plan = StintSim.plan({ laps = 22, fuelStart = 70, fuelPerLap = 2.9, kmPerLapF = 5.8, kmPerLapR = 5.8,
    trafficFraction = 0 })
  local ev = StintSim.newEvaluator({ base = base, track = w.track, conditions = CONDITIONS, plan = plan, compound = 1,
    weights = { bal = 0, stab = 0, traffic = 0, rob = 0 } })
  local function setupWith(wing)
    local s = CarModel.defaultSetup(base)
    s.compound = 1
    for _, wg in ipairs(base.wings) do
      if wg.name:upper():find('REAR') then s.wingAngles[wg.index] = wg.angle + wing end
    end
    return s
  end
  local results = {}
  for _, wing in ipairs({ -3, 0, 3 }) do
    local sampled = StintSim.evaluate(ev, setupWith(wing))
    local exact = StintSim.runExact(ev, setupWith(wing))
    PY.note('L02', string.format('aileron %+d : échantillonné %.3f s/tour, exact %.3f s/tour (écart %.3f s), tour critique %s',
      wing, sampled, exact.mean, sampled - exact.mean, tostring(exact.critical)))
    T.ok(math.abs(sampled - exact.mean) < K.compoundTieSeconds, 'écart ' .. (sampled - exact.mean) .. ' s/tour')
    results[#results + 1] = { sampled = sampled, exact = exact.mean }
  end
  -- même classement des setups dans les deux calculs (hors égalité : moins de 0,02 s/tour d'écart exact)
  for i = 1, #results do
    for j = i + 1, #results do
      if math.abs(results[i].exact - results[j].exact) > 0.02 then
        T.eq(results[i].sampled < results[j].sampled, results[i].exact < results[j].exact, 'classement ' .. i .. '/' .. j)
      end
    end
  end
  -- la falaise se voit : tour critique et dégradation
  local exact = StintSim.runExact(ev, setupWith(0))
  T.ok(exact.critical and exact.critical >= 8 and exact.critical <= 11, 'tour critique ' .. tostring(exact.critical))
  T.ok(exact.degradationPct > 0, 'dégradation positive')
end

tests['L03 vraies courbes d\'usure (Huracán) : relais échantillonné à moins de 0,05 s/tour du relais exact'] = function()
  local w = world('lamborghini_huracan_gt3_evo2', 'monza')
  local s = Space.apply(w.space, CarModel.defaultSetup(w.base), {})
  local worst = 0
  for _, case in ipairs({ { 2, 20 }, { 3, 30 }, { 5.7, 30 }, { 5.8, 30 }, { 6, 12 }, { 8, 20 } }) do
    local plan = StintSim.plan({ laps = case[2], fuelStart = case[2] * 3, fuelPerLap = 3, kmPerLapF = case[1], kmPerLapR = case[1] })
    for slot = 1, #w.base.compounds do
      local ev = StintSim.newEvaluator({ base = w.base, track = w.track, conditions = CONDITIONS, plan = plan, compound = slot,
        weights = { bal = 0, stab = 0, traffic = 0, rob = 0 } })
      local sampled = StintSim.evaluate(ev, s)
      worst = math.max(worst, math.abs(sampled - StintSim.runExact(ev, s).mean))
    end
  end
  PY.note('L03', string.format('écart maximal %.3f s/tour (18 relais, 3 composés)', worst))
  T.ok(worst < K.compoundTieSeconds, 'écart maximal ' .. worst .. ' s/tour')
end

tests['L04 nombre de tours de la course : réglages, séance, supposé, bornes'] = function()
  local settings = Config.defaults()
  local laps, source, assumed = Optimizer.raceLaps(settings, {}, 100)
  T.eq(laps, K.raceDefaultLaps)
  T.ok(assumed)
  T.contains(source, 'supposée')
  -- séance de course du week-end (la séance d'essais chronométrée qui précède n'est pas la course)
  local sessions = { { type = 1, laps = 0, durationMinutes = 30, isTimedRace = true }, { type = K.sessionTypeRace, laps = 25 } }
  laps, source, assumed = Optimizer.raceLaps(settings, sessions, 100)
  T.eq(laps, 25)
  T.no(assumed)
  -- course à la durée : ⌈durée / tour⌉ + 1, plus le tour additionnel
  sessions = { { type = K.sessionTypeRace, isTimedRace = true, durationMinutes = 30, laps = 0, hasAdditionalLap = true } }
  laps = Optimizer.raceLaps(settings, sessions, 107)
  T.eq(laps, math.ceil(1800 / 107) + 1 + 1)
  -- données de séance aberrantes : bornées (D11)
  T.eq((Optimizer.raceLaps(settings, { { type = K.sessionTypeRace, laps = 1e9 } }, 100)), K.raceMaxLaps)
  T.eq((Optimizer.raceLaps(settings, { { type = K.sessionTypeRace, isTimedRace = true, durationMinutes = 1e9 } }, 100)),
    K.raceMaxLaps)
  -- réglages prioritaires
  settings.raceMinutes = 10
  T.eq((Optimizer.raceLaps(settings, sessions, 100)), 7)
  settings.raceLaps = 12
  T.eq((Optimizer.raceLaps(settings, sessions, 100)), 12)
end

-- Problème course prêt à lancer.
local function prepareRace(w, budget, race, settingsPatch, extra)
  local settings = Config.defaults()
  for key, value in pairs(settingsPatch or {}) do settings[key] = value end
  local args = {
    base = w.base, space = w.space, track = w.track, trackCoarse = w.coarse, settings = settings, budget = budget,
    conditions = { airTemp = 24, roadGrip = 0.98, surfaceGrip = w.track.surfaceGrip }, race = race or {},
  }
  for key, value in pairs(extra or {}) do args[key] = value end
  return Optimizer.prepareRace(args)
end

local MEASURED = { kmPerLapF = 5.8, kmPerLapR = 5.8 }

tests['L05 carburant de course : mesure, CSP, modèle ; réservoir, arrêts ; prudence sans mesure'] = function()
  local w = world('lamborghini_huracan_gt3_evo2', 'monza')
  local function run(race, patch, extra)
    for key, value in pairs(MEASURED) do if race[key] == nil then race[key] = value end end
    local p = prepareRace(w, 40, race, patch, extra)
    return assert(Optimizer.runRace(p, SYNC, Optimizer.newState({ budget = 40 }))), p
  end
  -- consommation mesurée : prioritaire, jamais sous la valeur CSP
  local r = run({ fuelPerLapMeasured = 3.1, fuelPerLapCsp = 2.9 }, { raceLaps = 10 })
  T.eq(r.race.fuelSource, 'mesure')
  T.near(r.race.fuelPerLap, 3.1, 1e-9)
  T.ok(r.race.fuelStart >= 10 * 3.1 * 1.03 - 1e-9, 'carburant pour 10 tours + 3 % : ' .. r.race.fuelStart)
  T.ok(r.race.fuelStart < 10 * 3.1 * 1.03 + 1.01, 'au cran près')
  r = run({ fuelPerLapMeasured = 2.5, fuelPerLapCsp = 2.9 }, { raceLaps = 10 })
  T.near(r.race.fuelPerLap, 2.9, 1e-9, 'jamais sous la consommation CSP')
  T.eq(r.race.fuelSource, 'CSP (plancher)')
  -- modèle seul : marge supplémentaire, jamais sous le carburant actuel
  r = run({}, { raceLaps = 3 })
  T.eq(r.race.fuelSource, 'modèle')
  T.near(r.race.margin, 0.03 + K.raceFuelMarginModel, 1e-12)
  T.ok(r.race.fuelStart >= r.race.fuelFrom - 1e-9, 'sans mesure : carburant jamais réduit (' .. r.race.fuelStart .. ')')
  -- consommation inconnue (modèle sans CONSUMPTION, CSP à 0) : carburant actuel conservé, raison affichée
  local saved = w.base.fuelConsumption
  w.base.fuelConsumption = nil
  r = run({ fuelPerLapCsp = 0 }, { raceLaps = 20 })
  w.base.fuelConsumption = saved
  T.eq(r.deltas.fuel, nil, 'carburant inchangé')
  T.contains(r.race.fuelNote, 'consommation inconnue')
  -- course plus longue que le réservoir : relais limité, arrêts annoncés
  r = run({ fuelPerLapCsp = 3 }, { raceLaps = 60 })
  local tank = Space.physical(w.space.byKey.fuel, w.space.byKey.fuel.rangeHi)
  T.eq(r.race.stintLaps, math.floor(tank / (3 * 1.03)))
  T.eq(r.race.stops, math.ceil(60 / r.race.stintLaps) - 1)
  T.ok(r.race.fuelStart <= tank + 1e-9)
  -- le taux de consommation de la session multiplie la consommation du modèle
  local setup = CarModel.defaultSetup(w.base)
  local e1 = assert(CarModel.configure(w.base, setup, { airTemp = 24 }))
  local c1 = e1.consumption
  local e2 = assert(CarModel.configure(w.base, setup, { airTemp = 24, fuelRate = 2 }))
  T.near(e2.consumption, 2 * c1, 1e-12)
end

tests['L06 cran FUEL absent : relais limité par le carburant actuel'] = function()
  local w = world('lamborghini_huracan_gt3_evo2', 'monza')
  local space = {}
  for key, value in pairs(w.space) do space[key] = value end
  space.byKey = {}
  for key, value in pairs(w.space.byKey) do if key ~= 'fuel' then space.byKey[key] = value end end
  local wNoFuel = { base = w.base, space = space, track = w.track, coarse = w.coarse }
  local p = prepareRace(wNoFuel, 30, { fuelPerLapCsp = 3, kmPerLapF = 5.8, kmPerLapR = 5.8 }, { raceLaps = 30 })
  local r = assert(Optimizer.runRace(p, SYNC, Optimizer.newState({ budget = 30 })))
  local current = Space.apply(w.space, CarModel.defaultSetup(w.base), {}).fuel
  T.eq(r.race.stintLaps, math.floor(current / (3 * 1.03)), 'relais limité par ' .. current .. ' L')
  T.ok(r.race.stops >= 1)
  T.contains(r.race.fuelNote, 'non réglable')
  T.eq(r.deltas.fuel, nil)
end

tests['L07 trafic : P_trafic favorise l\'aileron et la stabilité au freinage dans l\'air sale'] = function()
  local w = world('lamborghini_huracan_gt3_evo2', 'spa')
  local plan = StintSim.plan({ laps = 3, fuelStart = 30, fuelPerLap = 3, trafficFraction = 0.3,
    slipstreamDrag = K.raceSlipstreamDrag, dirtyAirLift = K.raceDirtyAirLift })
  local ev = StintSim.newEvaluator({ base = w.base, track = w.track, conditions = CONDITIONS, plan = plan,
    compound = CarModel.defaultSetup(w.base).compound, weights = WEIGHTS })
  local rearWing = nil
  for _, wg in ipairs(w.base.wings) do if wg.name:upper():find('REAR') then rearWing = wg end end
  local previous = nil
  for wing = -4, 4, 2 do
    local s = CarModel.defaultSetup(w.base)
    s.wingAngles[rearWing.index] = rearWing.angle + wing
    local _, detail = StintSim.evaluate(ev, s)
    PY.note('L07', string.format('aileron %+d : P_trafic %.4f s', wing, detail.traffic))
    -- à 0,5 ms/tour près (égalité numérique)
    if previous then T.ok(detail.traffic <= previous + 5e-4, 'plus d\'aileron : pénalité ' .. detail.traffic .. ' > ' .. previous) end
    previous = detail.traffic
  end
  -- répartition de freinage près du seuil de blocage de l'arrière (0,55 sur cette voiture) : l'air sale
  -- l'aggrave (moins d'appui sur l'arrière), P_trafic le pénalise ; répartition d'origine : aucun blocage
  local stable = CarModel.defaultSetup(w.base)
  local rearward = CarModel.defaultSetup(w.base)
  rearward.brakeBias = 0.55
  local _, dStable = StintSim.evaluate(ev, stable)
  local _, dRear = StintSim.evaluate(ev, rearward)
  PY.note('L07', string.format('répartition %.2f : stabilité au freinage dans le trafic %.4f s ; 0,55 : %.4f s', stable.brakeBias,
    dStable.trafficLock, dRear.trafficLock))
  T.eq(dStable.trafficLock, 0, 'répartition d\'origine : aucun blocage aggravé')
  T.ok(dRear.trafficLock > 0.005, 'freinage instable dans le trafic pénalisé')
end

tests['L08 calcul course : jamais pire que l\'actuel au relais exact, carburant écrit, budget'] = function()
  local w = world('lamborghini_huracan_gt3_evo2', 'monza')
  local p = prepareRace(w, 160, { fuelPerLapCsp = 3, kmPerLapF = 5.8, kmPerLapR = 5.8 }, { raceLaps = 15 })
  local state = Optimizer.newState({ budget = 160 })
  local started = PY.clock()
  local r = assert(Optimizer.runRace(p, SYNC, state))
  local seconds = PY.clock() - started
  PY.note('L08', string.format('%d relais évalués (%d tours simulés par relais) en %.1f s ; tour moyen %.3f -> %.3f s',
    state.evaluations, r.samples, seconds, r.timeCurrent, r.timeProposed))
  T.ok(r.proposedJ <= r.currentJ + 1e-9, 'critère exact proposé ' .. r.proposedJ .. ' / actuel ' .. r.currentJ)
  T.ok(state.evaluations <= 160 + 40, 'budget ' .. state.evaluations)
  T.eq(#r.stintProposed.laps, 15)
  T.eq(r.race.stintLaps, 15)
  T.eq(r.race.kmSource, 'mesure')
  T.ok(r.deltas.fuel ~= nil, 'carburant de course dans les écarts')
  local values, errors = Space.values(w.space, r.deltas, { fuel = true })
  T.eq(#errors, 0, table.concat(errors, ' ; '))
  T.ok(values.FUEL ~= nil, 'carburant écrit')
  T.ok(r.stintProposed.balanceFirst and r.stintProposed.balanceLast, 'équilibre au premier et au dernier tour')
end

tests['L09 composé de course : relais exact, usure mesurée seulement, garde-fou final'] = function()
  local w = world('lamborghini_huracan_gt3_evo2', 'monza')
  -- courbes d'usure : le tendre chute vite, le dur tient le relais
  local base = {}
  for key, value in pairs(w.base) do base[key] = value end
  base.compounds = {
    withWear(w.base.compounds[1], { 0, 10, 20, 200 }, { 100, 100, 86, 80 }),
    withWear(w.base.compounds[2], { 0, 60, 200 }, { 100, 99, 95 }),
    withWear(w.base.compounds[3], { 0, 150, 300 }, { 99.5, 99.5, 97 }),
  }
  local wLong = { track = w.track, coarse = w.coarse, base = base, space = w.space }
  local p = prepareRace(wLong, 30, { fuelPerLapCsp = 3, kmPerLapF = 5.8, kmPerLapR = 5.8 }, { raceLaps = 25 })
  local r = assert(Optimizer.runRace(p, SYNC, Optimizer.newState({ budget = 30 })))
  local parts = {}
  for _, e in ipairs(r.compound.comparison) do parts[#parts + 1] = e.name .. ' ' .. Util.fmt(e.J, 3) end
  PY.note('L09', 'composés (relais exact) : ' .. table.concat(parts, ' ; ') .. ' -> ' .. tostring(r.compound.name))
  T.ok(r.compound.name ~= 'Slick Soft', 'le tendre s\'effondre sur 25 tours : ' .. tostring(r.compound.name))
  -- relais court (2 tours) : le tendre redevient le meilleur
  local pShort = prepareRace(wLong, 30, { fuelPerLapCsp = 3, kmPerLapF = 5.8, kmPerLapR = 5.8 }, { raceLaps = 2 })
  T.eq(assert(Optimizer.runRace(pShort, SYNC, Optimizer.newState({ budget = 30 }))).compound.name, 'Slick Soft')
  -- usure non mesurée : composé monté conservé (le choix reposerait sur un taux supposé)
  local pGuess = prepareRace(wLong, 30, { fuelPerLapCsp = 3 }, { raceLaps = 25 })
  local guess = assert(Optimizer.runRace(pGuess, SYNC, Optimizer.newState({ budget = 30 })))
  T.no(guess.compound.changed, 'composé monté conservé sans usure mesurée')
  T.contains(guess.compound.note, 'usure non mesurée')
  -- garde-fou : si le relais exact du setup proposé est plus lent que l'actuel, setup actuel conservé
  local exactOrig = StintSim.runExact
  local baseline = Space.apply(w.space, CarModel.defaultSetup(base), {})
  StintSim.runExact = function(ev, setup)
    local out = exactOrig(ev, setup)
    local same = setup.compound == baseline.compound and setup.brakeBias == baseline.brakeBias
    for index, angle in pairs(baseline.wingAngles) do same = same and setup.wingAngles[index] == angle end
    for i, ratio in ipairs(baseline.gears) do same = same and setup.gears[i] == ratio end
    if out and not same then out.mean = out.mean + 5 end
    return out
  end
  local pGuard = prepareRace(wLong, 60, { fuelPerLapCsp = 3, kmPerLapF = 5.8, kmPerLapR = 5.8 }, { raceLaps = 25 })
  local ok, guarded = pcall(Optimizer.runRace, pGuard, SYNC, Optimizer.newState({ budget = 60 }))
  StintSim.runExact = exactOrig
  T.ok(ok, tostring(guarded))
  T.ok(guarded.fallback, 'garde-fou déclenché')
  T.eq(#guarded.changes, 0, 'aucun changement proposé')
  T.no(guarded.compound.changed)
  T.ok(guarded.deltas.fuel ~= nil, 'carburant de course seulement')
end

tests['L10 déséquilibre induit : l\'essieu qui s\'use le plus perd son adhérence'] = function()
  local w = world('lamborghini_huracan_gt3_evo2', 'monza')
  local base = {}
  for key, value in pairs(w.base) do base[key] = value end
  base.compounds = { withWear(w.base.compounds[2], { 0, 300 }, { 100, 85 }) }
  local function run(kmF, kmR)
    local plan = StintSim.plan({ laps = 20, fuelStart = 0, fuelPerLap = 0, kmPerLapF = kmF, kmPerLapR = kmR })
    local ev = StintSim.newEvaluator({ base = base, track = w.track, conditions = CONDITIONS, plan = plan, compound = 1,
      weights = WEIGHTS })
    return assert(StintSim.runExact(ev, CarModel.defaultSetup(base)))
  end
  -- avant usé deux fois plus vite : la voiture devient sous-vireuse (équilibre en baisse)
  local front = run(10, 5)
  local rear = run(5, 10)
  PY.note('L10', string.format('avant usé : équilibre %.3f -> %.3f ; arrière usé : %.3f -> %.3f', front.balanceFirst,
    front.balanceLast, rear.balanceFirst, rear.balanceLast))
  T.ok(front.balanceLast < front.balanceFirst - 1e-3, 'avant usé : sous-virage croissant')
  T.ok(rear.balanceLast > rear.balanceFirst + 1e-3, 'arrière usé : survirage croissant')
end

return tests
