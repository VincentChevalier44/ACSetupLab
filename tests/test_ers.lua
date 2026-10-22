-- Tests de src/ers (J6b, §8.9) : lecture d'ers.ini et des profils ctrl_ers, valeur d'un profil, batterie
-- rejouée le long du tour, programmation dynamique du déploiement.
local T = require('t')
local Util = require('src/util')
local Datasource = require('src/datasource')
local Ers = require('src/ers')
local ErsPlan = require('src/ers_plan')
local TrackModel = require('src/track_model')
local CarModel = require('src/car_model')
local Space = require('src/setup_space')
local Sim = require('src/laptime_sim')
local Fake = require('fakehost')

local SYNC = Util.syncContext()
local tests = {}

local function readCar(carId)
  local h = Fake.new({ car = require('fixtures/cars/' .. carId), track = require('fixtures/tracks/monza') })
  return Datasource.readCar(h, 0, SYNC)
end

tests['N01 ers.ini et profils ctrl_ers lus (URD) ; voitures sans ERS ; ancien kers.ini refusé'] = function()
  local car = readCar('urd_px1_aura')
  local spec = assert(Ers.read(car))
  T.ok(spec.usable, tostring(spec.reason))
  T.eq(spec.kinetic.maxKjPerLap, 5000)
  T.near(spec.kinetic.dischargeTime, 40, 1e-12)
  T.near(spec.kinetic.chargeK, 0.00019, 1e-12)
  T.ok(spec.front and spec.front.torque, 'moteurs avant')
  T.near(Util.lutEval(spec.front.torque, 0), 1300, 1e-9)
  T.eq(spec.defaultProfile, 1, 'COCKPIT_CONTROLS DELIVERY_PROFILE')
  for i = 0, 5 do T.ok(spec.profiles[i] and spec.frontProfiles[i], 'profil ' .. i) end
  T.eq(spec.profiles[0].name, 'Charging')
  T.eq(spec.profiles[5].name, 'Hotlap')
  T.eq(#spec.profiles[1].controllers, 5)
  T.eq(spec.profiles[1].unknown[1], 'OVERSTEER_FACTOR', 'entrée inconnue signalée')
  T.eq(Ers.read(readCar('lamborghini_huracan_gt3_evo2')), nil, 'sans ERS')
  local old = Ers.read({ ini = { ['kers.ini'] = Util.parseIni('[KERS]\nMAX_KJ=400\n') }, luts = {} })
  T.no(old.usable)
  T.contains(old.reason, 'kers.ini')
  local empty = Ers.read({ ini = { ['ers.ini'] = Util.parseIni('[KINETIC]\nMAX_KJ_PER_LAP=0\n') }, luts = {} })
  T.no(empty.usable)
end

tests['N02 valeur d\'un profil : ADD puis MULT, bornes, entrées inconnues neutres'] = function()
  local spec = assert(Ers.read(readCar('urd_px1_aura')))
  local p0 = spec.profiles[0]
  -- gaz plein, 200 km/h, 3e : 1 (gaz) × 1 (régime) × vitesse (1 − 0,2·200/280) × rapport 3 (0,5)
  local v = Ers.profileValue(p0, { GAS = 1, RPMS = 4000, SPEED_KMH = 200, GEAR = 3, BRAKE = 0, LATG = 0 })
  T.near(v, (1 - 0.2 * 200 / 280) * 0.5, 1e-9)
  T.eq(Ers.profileValue(p0, { GAS = 0.4, RPMS = 4000, SPEED_KMH = 200, GEAR = 3 }), 0, 'gaz partiel : rien')
  T.eq(Ers.profileValue(p0, { GAS = 1, RPMS = 4000, SPEED_KMH = 320, GEAR = 3 }), 0, 'au-delà de 300 km/h')
  -- marche arrière : la LUT de rapport donne −1, borné à 0
  T.eq(Ers.profileValue(p0, { GAS = 1, RPMS = 4000, SPEED_KMH = 50, GEAR = -1 }), 0)
  local hot = Ers.profileValue(spec.profiles[5], { GAS = 1, RPMS = 4000, SPEED_KMH = 200, GEAR = 6 })
  T.near(hot, 1, 1e-9, 'profil « Hotlap » : plein déploiement')
end

tests['N03 batterie rejouée : vide, limite par tour, récupération plafonnée à la capacité'] = function()
  local n = 10
  local mask, pFull, dt, rec, out = {}, {}, {}, {}, {}
  for k = 1, n do mask[k], pFull[k], dt[k], rec[k] = 1, 100, 0.5, 0, out end
  -- 10 points de 50 kJ demandés, batterie de 120 kJ : 2 points pleins, un partiel, puis rien
  local r = Ers.replay(n, 1, mask, pFull, dt, rec, { capacity = 120, maxPerLap = 1000, soc0 = 120 }, out)
  T.near(r.deployed, 120, 1e-9)
  T.near(out[1], 1, 1e-12)
  T.near(out[3], 0.4, 1e-12)
  T.eq(out[4], 0)
  T.ok(r.limited)
  T.near(r.socMin, 0, 1e-12)
  -- limite par tour avant la batterie
  r = Ers.replay(n, 1, mask, pFull, dt, rec, { capacity = 1000, maxPerLap = 75, soc0 = 1000 }, out)
  T.near(r.deployed, 75, 1e-9)
  -- récupération plafonnée à la capacité, départ ailleurs que le point 1 (bouclage)
  for k = 1, n do mask[k], rec[k] = 0, 30 end
  r = Ers.replay(n, 7, mask, pFull, dt, rec, { capacity = 100, maxPerLap = 1000, soc0 = 50 }, out)
  T.near(r.socEnd, 100, 1e-12)
  T.near(r.recovered, 50, 1e-12)
end

-- Optimum exact par énumération (petits problèmes).
local function brute(stages, opts)
  local best, bestChoice = -math.huge, nil
  local function rec(j, soc, dep, gain, choice)
    if j > #stages then
      if soc >= (opts.socEndMin or 0) - 1e-9 and gain > best then
        best = gain
        bestChoice = { table.unpack and table.unpack(choice) or unpack(choice) }
      end
      return
    end
    for o, option in ipairs(stages[j].options) do
      local s, d = soc - option.energy, dep + option.energy
      if s >= -1e-9 and d <= opts.maxPerLap + 1e-9 then
        choice[j] = o
        rec(j + 1, math.min(opts.capacity, s + stages[j].recovery), d, gain + option.gain, choice)
      end
    end
  end
  rec(1, opts.soc0, 0, 0, {})
  return best, bestChoice
end

tests['N04 programmation dynamique : optimum exact, batterie jamais négative, régime établi'] = function()
  local rng = Util.rngNew(11)
  for trial = 1, 30 do
    local stages = {}
    for j = 1, 5 do
      local options = { { gain = 0, energy = 0 } }
      for o = 1, 3 do
        local energy = 10 * math.floor(Util.rngRange(rng, 1, 8))
        options[#options + 1] = { gain = energy * Util.rngRange(rng, 0.001, 0.004), energy = energy }
      end
      stages[j] = { options = options, recovery = 10 * math.floor(Util.rngRange(rng, 0, 5)) }
    end
    -- grilles alignées sur les énergies (pas de 10 kJ) : la discrétisation est exacte
    local opts = { capacity = 100, maxPerLap = 150, soc0 = 100, levels = 10, dLevels = 15 }
    local gain, choice, socEnd = Ers.optimize(stages, opts)
    local exact = brute(stages, opts)
    T.near(gain, exact, 1e-9, 'essai ' .. trial)
    -- la stratégie retenue respecte batterie et limite par tour
    local soc, dep = opts.soc0, 0
    for j, stage in ipairs(stages) do
      local option = stage.options[choice[j]]
      soc, dep = soc - option.energy, dep + option.energy
      T.ok(soc >= -1e-9, 'batterie jamais négative')
      soc = math.min(opts.capacity, soc + stage.recovery)
    end
    T.ok(dep <= opts.maxPerLap + 1e-9)
    T.near(socEnd, soc, 1e-9)
    -- régime établi : charge finale ≥ charge de départ
    local race = { capacity = 100, maxPerLap = 150, soc0 = 50, levels = 10, dLevels = 15, socEndMin = 50 }
    local g2, _, end2 = Ers.optimize(stages, race)
    if g2 then
      T.ok(end2 >= 50 - 1e-9, 'régime établi')
      T.near(g2, brute(stages, race), 1e-9)
    end
  end
end

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
  local base = CarModel.build(car, nil)
  local space = Space.build({ setupIni = car.ini['setup.ini'], spinners = setup.spinners, ratios = car.ratios })
  Space.verify(space, state, base)
  Space.attach(space, base)
  cache[key] = { h = h, track = track, base = base, space = space }
  return cache[key]
end

local CONDITIONS = { airTemp = 24, roadGrip = 0.98 }

tests['N05 forces de l\'ERS (H21) et batterie (H22) ; simulation avec masque de déploiement'] = function()
  local w = world('urd_px1_aura', 'monza')
  local spec = w.base.ers
  T.ok(spec and spec.usable)
  local s = Space.apply(w.space, CarModel.defaultSetup(w.base), {})
  local eff = assert(CarModel.configure(w.base, s, { airTemp = 24, roadGrip = 0.98, ersSpec = spec }))
  T.ok(eff.ersOn)
  -- MGU-K de l'URD : courbe nulle ; moteurs avant : couple de l'essieu au régime des roues avant
  for g = 1, eff.gearCount do T.eq(eff.ersGearForce[g][31], 0) end
  local radius = eff.compound.front.radius
  local v = 60
  local expected = Util.lutEval(spec.front.torque, v / radius * 60 / (2 * math.pi)) / radius
  T.near(eff.ersFront[31], expected, 1e-6)
  -- capacité : puissance maximale des moteurs avant (sous la pointe) × 40 s
  local pMax = 0
  for i = 1, eff.speedCount do
    local speed = (i - 1) * eff.dv
    if speed <= eff.topSpeed then pMax = math.max(pMax, eff.ersFront[i] * speed) end
  end
  T.near(eff.ersCapacity, pMax * 40 / 1000, 1e-6)
  PY.note('N05', string.format('URD : %.0f N à 60 m/s (%.0f kW), batterie %.0f kJ, %d kJ par tour au plus', eff.ersFront[31],
    eff.ersFront[31] * 60 / 1000, eff.ersCapacity, eff.ersMaxPerLap))
  -- masque nul : tour identique à la voiture sans ERS ; masque plein : plus rapide
  local plain = assert(CarModel.configure(w.base, s, CONDITIONS))
  T.no(plain.ersOn)
  local n = w.track.n
  local zero, one = {}, {}
  for k = 1, n do zero[k], one[k] = 0, 1 end
  local tPlain = Sim.run(w.track, plain, nil).time
  local tZero = Sim.run(w.track, eff, nil, { ersMask = zero }).time
  local tOne = Sim.run(w.track, eff, nil, { ersMask = one }).time
  PY.note('N05', string.format('Monza : %.3f s sans ERS, %.3f s en déploiement permanent', tPlain, tOne))
  T.near(tZero, tPlain, 1e-9)
  T.ok(tOne < tPlain - 0.5, 'déploiement plus rapide')
  -- MGU-K synthétique (200 N·m au vilebrequin, sans moteurs avant) : la force passe par la boîte
  local mguk = { usable = true, notes = {}, profiles = {}, frontProfiles = {}, defaultProfile = 0,
    kinetic = { torque = Util.lutNew({ 0, 20000 }, { 200, 200 }), chargeK = 0.0001, dischargeTime = 30, maxKjPerLap = 2000 } }
  local effK = assert(CarModel.configure(w.base, s, { airTemp = 24, roadGrip = 0.98, ersSpec = mguk }))
  local g = 2
  local total = effK.gears[g] * effK.final
  T.near(effK.ersGearForce[g][11], 200 * total * 0.9 / effK.wheelRadius, 1e-6, 'couple × démultiplication × rendement / rayon')
  T.eq(effK.ersFront[11], 0)
  local tK = Sim.run(w.track, effK, nil, { ersMask = one }).time
  PY.note('N05', string.format('MGU-K de 200 N·m en permanence : %.3f s', tK))
  T.ok(tK < tPlain - 0.2, 'MGU-K plus rapide')
  -- bilan par point : récupération au freinage seulement
  local buf = Sim.new(w.track)
  Sim.run(w.track, eff, buf, { ersMask = zero })
  local arrays = Ers.arrays(spec, eff, w.track, buf, {})
  local recovered = 0
  for k = 1, n do
    if arrays.rec[k] > 0 then T.eq(buf.limit[k], Sim.LIMIT.brake, 'récupération hors freinage au point ' .. k) end
    recovered = recovered + arrays.rec[k]
  end
  PY.note('N05', string.format('énergie récupérable sur un tour : %.0f kJ', recovered))
  T.ok(recovered > 0)
end

tests['N06 plan de qualification : jamais moins bien que la voiture (§14.3), batterie jamais négative'] = function()
  local w = world('urd_px1_aura', 'monza')
  local s = Space.apply(w.space, CarModel.defaultSetup(w.base), {})
  local plan = assert(ErsPlan.plan({ spec = w.base.ers, base = w.base, setup = s, conditions = CONDITIONS, track = w.track,
    mode = 'quali' }))
  PY.note('N06', string.format('sans ERS %.3f s ; profil « %s » %.3f s ; plan %.3f s ; %d zones ; déployé %.0f kJ, récupéré %.0f kJ, '
    .. 'charge %.0f -> %.0f kJ (mini %.0f)', plan.timeNone, tostring(plan.profileName), plan.timeDefault, plan.timeOptimized, #plan.zones,
    plan.summary.deployed, plan.summary.recovered, plan.socStart, plan.summary.socEnd, plan.summary.socMin))
  T.ok(plan.timeOptimized <= plan.timeDefault + 1e-9, 'jamais moins bien que la stratégie de la voiture')
  T.ok(plan.timeOptimized < plan.timeNone, 'gain de l\'ERS')
  -- le profil « Low preserve » bride le déploiement selon le rapport et la vitesse : le plan fait mieux
  T.no(plan.fallbackDefault)
  T.ok(plan.timeOptimized < plan.timeDefault - 0.3, 'plan meilleur que le profil de la voiture')
  T.ok(plan.summary.socMin >= -1e-9, 'batterie jamais négative')
  T.ok(plan.summary.deployed <= plan.maxPerLap + 1e-6, 'limite par tour')
  -- propriété sur tout le profil : la batterie rejouée sur le tour retenu ne descend jamais sous zéro
  local buf = Sim.new(w.track)
  local c = { airTemp = 24, roadGrip = 0.98, ersSpec = w.base.ers }
  local eff = assert(CarModel.configure(w.base, s, c))
  local r = Sim.run(w.track, eff, buf, { ersMask = plan.mask })
  local arrays = Ers.arrays(w.base.ers, eff, w.track, buf, {})
  local out = {}
  local check = Ers.replay(w.track.n, r.kMin, plan.mask, arrays.pFull, arrays.dt, arrays.rec,
    { capacity = plan.capacity, maxPerLap = plan.maxPerLap, soc0 = plan.socStart }, out)
  T.ok(check.socMin >= -1e-9)
  T.ok(#plan.profiles == 6, 'six profils du cockpit comparés')
  T.ok(plan.bestProfile, 'meilleur profil')
end

tests['N07 plan de course : régime établi (charge finale ≥ charge de départ)'] = function()
  local w = world('urd_px1_aura', 'monza')
  local s = Space.apply(w.space, CarModel.defaultSetup(w.base), {})
  local plan = assert(ErsPlan.plan({ spec = w.base.ers, base = w.base, setup = s, conditions = CONDITIONS, track = w.track,
    mode = 'race' }))
  PY.note('N07', string.format('course : plan %.3f s (profil %.3f s), charge %.0f -> %.0f kJ, déployé %.0f kJ', plan.timeOptimized,
    plan.timeDefault, plan.socStart, plan.summary.socEnd, plan.summary.deployed))
  -- régime établi, pour le plan comme pour la stratégie de la voiture retenue à sa place
  T.ok(plan.summary.socEnd >= plan.socStart - 1 - 1e-6, 'régime établi : ' .. plan.summary.socEnd .. ' / ' .. plan.socStart)
  T.ok(plan.timeOptimized <= plan.timeDefault + 1e-9, 'jamais moins bien que la voiture en régime établi')
  T.ok(plan.bestProfile, 'profil recommandé')
end

tests['N08 report d\'un masque sur un tracé de pas différent (recherche grossière)'] = function()
  local from = { n = 5, s = { 0, 2, 4, 6, 8 } }
  local to = { n = 3, s = { 0, 4, 8 } }
  local out = ErsPlan.resample({ 0, 1, 1, 0, 1 }, from, to)
  T.eq(out[1], 0)
  T.eq(out[2], 1)
  T.eq(out[3], 1)
end

local function quali(w, budget, extra)
  local Config = require('src/config')
  local Optimizer = require('src/optimizer')
  local args = { base = w.base, space = w.space, track = w.track, settings = Config.defaults(), budget = budget,
    conditions = { airTemp = 24, roadGrip = 0.98, surfaceGrip = w.track.surfaceGrip } }
  for key, value in pairs(extra or {}) do args[key] = value end
  return args, Optimizer
end

tests['N09 qualification avec ERS : plan du setup actuel pendant la recherche, refait pour le setup proposé'] = function()
  local w = world('urd_px1_aura', 'monza')
  local args, Optimizer = quali(w, 120, { ers = true })
  local r = assert(Optimizer.runQuali(Optimizer.prepareQuali(args), SYNC, Optimizer.newState({ budget = 120 })))
  T.ok(r.ers, 'bilan ERS')
  local cur, prop = r.ers.current, r.ers.proposed
  PY.note('N09', string.format('actuel : sans ERS %.3f, profil %.3f, plan %.3f ; proposé : plan %.3f (tour de la recherche %.3f)',
    cur.timeNone, cur.timeDefault, cur.timeOptimized, prop.timeOptimized, r.timeProposed))
  T.ok(prop.timeOptimized <= prop.timeDefault + 1e-9, 'jamais moins bien que le profil de la voiture')
  T.ok(r.timeCurrent < cur.timeNone - 0.5, 'la recherche simule l\'ERS (masque du plan)')
  T.ok(prop.socMin >= -1e-9)
  -- sans ERS demandé : rien
  local plain = quali(w, 40, {})
  T.eq(assert(Optimizer.runQuali(Optimizer.prepareQuali(plain), SYNC, Optimizer.newState({ budget = 40 }))).ers, nil)
end

tests['N10 course avec ERS : plan en régime établi, appliqué à chaque tour du relais'] = function()
  local w = world('urd_px1_aura', 'monza')
  local Config = require('src/config')
  local Optimizer = require('src/optimizer')
  local settings = Config.defaults()
  settings.raceLaps = 8
  local p = Optimizer.prepareRace({ base = w.base, space = w.space, track = w.track, settings = settings, budget = 30, ers = true,
    conditions = { airTemp = 24, roadGrip = 0.98 }, race = { fuelPerLapCsp = 2.5, kmPerLapF = 5, kmPerLapR = 5 } })
  local r = assert(Optimizer.runRace(p, SYNC, Optimizer.newState({ budget = 30 })))
  T.ok(r.ers and r.ers.proposed)
  local e = r.ers.proposed
  PY.note('N10', string.format('course : plan %.3f s, profil %.3f s, charge %.0f -> %.0f kJ ; relais %.3f s/tour', e.timeOptimized,
    e.timeDefault, e.socStart, e.socEnd, r.timeProposed))
  T.eq(e.mode, 'race')
  T.ok(e.socEnd >= e.socStart - 1 - 1e-6, 'régime établi')
  -- même relais sans ERS : plus lent (le masque du plan sert à chaque tour)
  local p2 = Optimizer.prepareRace({ base = w.base, space = w.space, track = w.track, settings = settings, budget = 30,
    conditions = { airTemp = 24, roadGrip = 0.98 }, race = { fuelPerLapCsp = 2.5, kmPerLapF = 5, kmPerLapR = 5 } })
  local r2 = assert(Optimizer.runRace(p2, SYNC, Optimizer.newState({ budget = 30 })))
  PY.note('N10', string.format('relais actuel : %.3f s/tour avec ERS, %.3f s/tour sans', r.timeCurrent, r2.timeCurrent))
  T.ok(r.timeCurrent < r2.timeCurrent - 0.5, 'relais simulé avec l\'ERS')
end

tests['N11 enregistreur : déploiement relevé (H24), charge et énergie du tour'] = function()
  local Recorder = require('src/recorder')
  local w = world('urd_px1_aura', 'monza')
  local h = w.h
  h.car.kersPresent, h.car.isInPit, h.car.isInPitlane = true, false, false
  local profile = { p = {}, v = {} }
  for k = 1, w.track.n do profile.p[k], profile.v[k] = w.track.p[k], 60 end
  profile.p[#profile.p + 1], profile.v[#profile.v + 1] = 1, 60
  local rec = Recorder.new()
  local context = { trackLength = w.track.length, conditions = { airTemp = 24 }, ers = true }
  local laps, now, start = {}, 0, h.car.lapCount
  h.driver = nil
  while h.car.lapCount < start + 2 or rec.pending do
    Fake.drive(h, profile, 1 / 60)
    now = now + 1 / 60
    local p = h.driver.p
    h.car.kersInput = (p > 0.2 and p < 0.4) and 1 or 0
    h.car.kersCurrentKJ = math.min(2000, p * 3000)
    h.car.kersCharge = 0.8 - 0.2 * p
    local lap = Recorder.update(rec, h, now, function() return 'S1' end, context)
    if lap then laps[#laps + 1] = lap end
  end
  local lap = laps[#laps]
  T.ok(lap.valid, tostring(lap.reason))
  T.ok(lap.ersUsed)
  T.near(lap.ersDeployedKj, 2000, 1e-6)
  T.ok(lap.ersChargeStart > lap.ersChargeEnd)
  local on = 0
  for i = 1, lap.n do on = on + lap.ers[i] end
  T.ok(on / lap.n > 0.15 and on / lap.n < 0.25, 'part du tour en déploiement ' .. on / lap.n)
  -- ramené sur la grille du circuit pour la calibration
  local Calibration = require('src/calibration')
  local m = assert(Calibration.measured(w.track, lap))
  T.ok(m.ers and #m.ers == w.track.n)
  h.car.kersInput, h.car.kersCurrentKJ, h.car.kersCharge, h.driver = 0, 0, 0, nil
end

tests['N12 calibration d\'un tour roulé avec l\'ERS : déploiement relevé simulé, puissance non faussée'] = function()
  local Calibration = require('src/calibration')
  local w = world('urd_px1_aura', 'monza')
  local s = Space.apply(w.space, CarModel.defaultSetup(w.base), {})
  local plan = assert(ErsPlan.plan({ spec = w.base.ers, base = w.base, setup = s, conditions = CONDITIONS, track = w.track,
    mode = 'quali' }))
  -- tour « mesuré » : modèle vrai (facteurs 1) avec le déploiement du plan
  local eff = assert(CarModel.configure(w.base, s, { airTemp = 25, roadGrip = 0.98, ersSpec = w.base.ers }))
  local buf = Sim.new(w.track)
  local truth = Sim.run(w.track, eff, buf, { ersMask = plan.mask })
  local measured = { v = {}, vmax = 0, time = truth.time, ers = plan.mask }
  for k = 1, w.track.n do
    measured.v[k] = buf.v[k]
    measured.vmax = math.max(measured.vmax, buf.v[k])
  end
  local function calibrate(withErs)
    local conditions = { airTemp = 25, roadGrip = 0.98, ersSpec = withErs and w.base.ers or nil }
    return Calibration.run({ Calibration.newRun({ track = w.track, base = w.base, setup = s, conditions = conditions,
      measured = measured }) }, SYNC)
  end
  local good, naive = calibrate(true), calibrate(false)
  PY.note('N12', string.format('puissance calibrée : %.3f avec le déploiement relevé, %.3f sans', good.factors.power,
    naive.factors.power))
  T.near(good.factors.power, 1, 0.01, 'déploiement relevé : puissance juste')
  T.ok(naive.factors.power > good.factors.power + 0.02, 'sans le déploiement, la puissance absorberait l\'ERS')
end

local function boot(carId, trackId, opts)
  opts = opts or {}
  opts.car = require('fixtures/cars/' .. carId)
  opts.track = require('fixtures/tracks/' .. trackId)
  local h = Fake.new(opts)
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  h.texts = {}
  local text, wrapped, colored = h.ui.text, h.ui.textWrapped, h.ui.textColored
  h.ui.text = function(str) h.texts[#h.texts + 1] = str; return text(str) end
  h.ui.textWrapped = function(str) h.texts[#h.texts + 1] = str; return wrapped(str) end
  h.ui.textColored = function(str, c) h.texts[#h.texts + 1] = str; return colored(str, c) end
  local function frame()
    h.texts = {}
    h.sim.time = h.sim.time + 1000 / 60
    script.SETUPLAB__UPDATE(1 / 60)
    script.SETUPLAB__MAIN(1 / 60)
  end
  for _ = 1, 40000 do
    frame()
    if app.discoveryState == 'done' then break end
  end
  return h, app, frame
end

tests['N13 colle : ERS activé si la voiture et AC le permettent ; calcul affiché'] = function()
  local h, app, frame = boot('urd_px1_aura', 'monza', { kers = true })
  T.ok(app.discovery.ers.enabled, tostring(app.discovery.ers.reason))
  T.contains(app.discovery.caps.byId.ers.detail, 'simulé')
  app.settings.optBudgetEvalsQ = 60
  h.click = 'Calculer le setup tour rapide'
  for _ = 1, 200000 do
    frame()
    if app.quali and app.quali.state ~= 'running' then break end
  end
  T.eq(app.quali.state, 'done', tostring(app.quali.error))
  T.ok(app.quali.result.ers, 'plan ERS dans le résultat')
  h.openSections = true -- section « ERS », fermée d'office
  frame()
  h.openSections = nil
  local shown = false
  for _, text in ipairs(h.texts) do shown = shown or text:find('ERS (à confirmer', 1, true) ~= nil end
  T.ok(shown, 'ERS affiché')
  -- AC n'annonce pas d'ERS : non simulé, raison
  local _, app2 = boot('urd_px1_aura', 'monza')
  T.no(app2.discovery.ers.enabled)
  T.contains(app2.discovery.ers.reason, 'kersPresent')
  -- voiture sans ERS
  local _, app3 = boot('lamborghini_huracan_gt3_evo2', 'monza', { kers = true })
  T.no(app3.discovery.ers.enabled)
end

return tests
