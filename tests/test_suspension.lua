-- Tests de la suspension (couverture complète du setup, H16 à H19) : écrasement sous l'appui avec butées,
-- quart de véhicule, perte d'adhérence par variation de charge, rugosité mesurée sur un tour,
-- libération des ressorts, amortisseurs, butées et course avant butée.
local T = require('t')
local Util = require('src/util')
local Config = require('src/config')
local Datasource = require('src/datasource')
local TrackModel = require('src/track_model')
local CarModel = require('src/car_model')
local Space = require('src/setup_space')
local Sim = require('src/laptime_sim')
local Recorder = require('src/recorder')
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
  local base = CarModel.build(car, nil)
  local space = Space.build({ setupIni = car.ini['setup.ini'], spinners = setup.spinners, ratios = car.ratios })
  Space.verify(space, state, base)
  Space.attach(space, base)
  cache[key] = { h = h, track = track, base = base, space = space }
  return cache[key]
end

tests['X01 écrasement sous l\'appui : suspension puis butées, pneus en série (H16)'] = function()
  local s = { spring2 = 200000, heave = 0, bump2 = 400000, gap = 0.01, tyre2 = 600000 }
  local drop, travel = CarModel.axleDrop(1000, s)
  T.near(travel, 1000 / 200000, 1e-12, 'avant la butée : linéaire')
  T.near(drop, 1000 / 200000 + 1000 / 600000, 1e-12, 'pneus en série')
  local _, t2 = CarModel.axleDrop(4000, s)
  T.near(t2, 0.01 + (4000 - 2000) / 600000, 1e-12, 'au-delà de la course : butées en plus')
  T.ok(t2 < 4000 / 200000, 'butées : moins d\'écrasement')
  local noGap = { spring2 = 200000, heave = 50000, bump2 = 400000, gap = nil, tyre2 = 600000 }
  local _, t3 = CarModel.axleDrop(4000, noGap)
  T.near(t3, 4000 / 250000, 1e-12, 'sans course avant butée : ressorts et pilonnage seulement')
  T.eq(select(1, CarModel.axleDrop(-5, s)), 0)
end

tests['X02 quart de véhicule (H17) : pneu et ressort plus raides -> plus de variation de charge ; amortissement optimal intérieur'] = function()
  local I = CarModel.quarterCarIntegral
  local base = I(250, 40, 120000, 8000, 5000, 300000)
  T.ok(base > 0)
  T.ok(I(250, 40, 120000, 8000, 5000, 600000) > base, 'pneu plus raide')
  T.ok(I(250, 40, 240000, 8000, 5000, 300000) > base, 'ressort plus raide')
  T.ok(I(250, 60, 120000, 8000, 5000, 300000) > base, 'masse non suspendue plus lourde')
  -- amortissement de roue : trop faible (résonance) ou trop fort (dur) augmente la variation de charge
  local low, mid, high = I(250, 40, 120000, 8000, 300, 300000), I(250, 40, 120000, 8000, 3000, 300000),
    I(250, 40, 120000, 8000, 60000, 300000)
  PY.note('X02', string.format('amortissement rapide 300 / 3000 / 60000 N·s/m : %.3e / %.3e / %.3e', low, mid, high))
  T.ok(mid < low and mid < high, 'optimum intérieur')
  -- écart type : racine de G0·n0²·v·I
  local q = { off = base, on = 2 * base }
  T.near(CarModel.loadSigma(q, 4e-6, 50, false), math.sqrt(4e-6 * K.roughN0 ^ 2 * 50 * base), 1e-9)
  T.near(CarModel.loadSigma(q, 4e-6, 50, true), math.sqrt(2) * CarModel.loadSigma(q, 4e-6, 50, false), 1e-9)
end

tests['X03 adhérence : perte par variation de charge seulement si la rugosité est connue (H19)'] = function()
  local w = world('lamborghini_huracan_gt3_evo2', 'spa')
  local s = Space.apply(w.space, CarModel.defaultSetup(w.base), {})
  local plain = assert(CarModel.configure(w.base, s, { airTemp = 24 }))
  for i = 1, plain.speedCount do T.eq(plain.bumpGripF[i], 1) end
  T.eq(plain.quarterF.off, 0, 'intégrales non calculées sans rugosité')
  local rough = assert(CarModel.configure(w.base, s, { airTemp = 24, roughness = 16e-6 }))
  local i = 31
  T.ok(rough.bumpGripF[i] < 1 and rough.bumpGripF[i] > K.roughGripMin)
  T.ok(rough.ay[2][i] < plain.ay[2][i], 'adhérence latérale réduite')
  -- ressort avant plus raide : plus de variation de charge, plus de perte
  local stiff = Space.apply(w.space, CarModel.defaultSetup(w.base), { springF = w.space.byKey.springF.rangeHi })
  local r2 = assert(CarModel.configure(w.base, stiff, { airTemp = 24, roughness = 16e-6 }))
  T.ok(r2.bumpGripF[i] < rough.bumpGripF[i], 'ressort raide : plus de perte')
  -- pression plus haute : pneu plus raide (PRESSURE_SPRING_GAIN), plus de variation de charge
  local hard = Space.apply(w.space, CarModel.defaultSetup(w.base), { pressureF = 4 })
  local r3 = assert(CarModel.configure(w.base, hard, { airTemp = 24, roughness = 16e-6 }))
  T.ok(r3.quarterF.kt > rough.quarterF.kt, 'pneu plus raide')
  T.ok(r3.bumpGripF[i] < rough.bumpGripF[i], 'pression haute : plus de perte')
end

tests['X04 rugosité estimée sur un tour : aller-retour exact, cohérence avant / arrière'] = function()
  local w = world('lamborghini_huracan_gt3_evo2', 'spa')
  local s = Space.apply(w.space, CarModel.defaultSetup(w.base), {})
  local G0, v = 9e-6, 55
  local eff = assert(CarModel.configure(w.base, s, { airTemp = 24, roughness = G0 }))
  local function sigma(q) return CarModel.loadSigma(q, G0, v, false) end
  local sf, sr = sigma(eff.quarterF), sigma(eff.quarterR)
  local lap = { loadSigma = { sf, sf, sr, sr }, roughSpeed = v }
  local r = assert(CarModel.roughness(w.base, s, lap, { airTemp = 24 }))
  PY.note('X04', string.format('σ avant %.0f N, arrière %.0f N à %d m/s -> G0 %.3e (vrai %.0e)', sf, sr, v, r.G0, G0))
  T.near(r.G0 / G0, 1, 1e-6)
  T.ok(r.consistent)
  -- avant et arrière incohérents (facteur 25 sur la variance) : signalé
  local bad = assert(CarModel.roughness(w.base, s, { loadSigma = { sf * 5, sf * 5, sr, sr }, roughSpeed = v }, { airTemp = 24 }))
  T.no(bad.consistent)
  T.eq(CarModel.roughness(w.base, s, { roughSpeed = v }, { airTemp = 24 }), nil, 'sans mesure')
end

-- Fait rouler n tours avec du bruit blanc de charge sur les roues (écart type sigma).
local function driveNoisy(h, track, rec, laps, sigma)
  local s = CarModel.defaultSetup(CarModel.build(Datasource.readCar(h, 0, SYNC), nil))
  local _ = s
  local profile = { p = {}, v = {} }
  for k = 1, track.n do profile.p[k], profile.v[k] = track.p[k], 60 end
  profile.p[#profile.p + 1], profile.v[#profile.v + 1] = 1, 60
  local rng = Util.rngNew(7)
  local context = { trackLength = track.length, conditions = { airTemp = 24 } }
  local finished, now, start = {}, 0, h.car.lapCount
  h.driver = nil
  h.car.isInPit, h.car.isInPitlane = false, false
  while h.car.lapCount < start + laps + 1 or rec.pending do
    Fake.drive(h, profile, 1 / 60)
    now = now + 1 / 60
    for wh = 0, 3 do
      -- bruit gaussien approché (somme de 12 uniformes)
      local g = -6
      for _ = 1, 12 do g = g + Util.rngRange(rng, 0, 1) end
      h.car.wheels[wh].load = 3000 + sigma * g
    end
    local lap = Recorder.update(rec, h, now, function() return 'S1' end, context)
    if lap then finished[#finished + 1] = lap end
  end
  return finished
end

tests['X05 enregistreur : variation de charge en ligne droite, tendance retirée'] = function()
  local w = world('lamborghini_huracan_gt3_evo2', 'monza')
  local rec = Recorder.new()
  local laps = driveNoisy(w.h, w.track, rec, 1, 250)
  local lap = laps[#laps]
  T.ok(lap.valid, tostring(lap.reason))
  T.ok(lap.loadSigma, 'mesure faite')
  PY.note('X05', string.format('σ mesuré %.0f / %.0f / %.0f / %.0f N (vrai 250 N, bruit tiré à 60 Hz, lu à 30 Hz) ; %d fenêtres à %.0f m/s',
    lap.loadSigma[1], lap.loadSigma[2], lap.loadSigma[3], lap.loadSigma[4], lap.roughWindows, lap.roughSpeed))
  for wh = 1, 4 do T.near(lap.loadSigma[wh], 250, 25) end
  T.near(lap.roughSpeed, 60, 1e-6)
  -- tendance (appui qui croît) retirée : une rampe pure ne compte pas
  local rec2 = Recorder.new()
  w.h.driver = nil
  local profile = { p = {}, v = {} }
  for k = 1, w.track.n do profile.p[k], profile.v[k] = w.track.p[k], 60 end
  profile.p[#profile.p + 1], profile.v[#profile.v + 1] = 1, 60
  local now, start, last = 0, w.h.car.lapCount, nil
  while w.h.car.lapCount < start + 2 or rec2.pending do
    Fake.drive(w.h, profile, 1 / 60)
    now = now + 1 / 60
    for wh = 0, 3 do w.h.car.wheels[wh].load = 3000 + 400 * now end
    last = Recorder.update(rec2, w.h, now, function() return 'S1' end, { trackLength = w.track.length, conditions = {} }) or last
  end
  T.ok(last.loadSigma and last.loadSigma[1] < 1, 'rampe retirée : ' .. tostring(last.loadSigma and last.loadSigma[1]))
  for wh = 0, 3 do w.h.car.wheels[wh].load = 3000 end
end

tests['X06 ressorts : butée seulement si la voiture reste du même côté de l\'équilibre (§0.6)'] = function()
  for _, carId in ipairs({ 'lamborghini_huracan_gt3_evo2', 'whk_dtm_2026' }) do
    local w = world(carId, 'spa')
    local weights = Config.penaltyWeights(Config.defaults())
    for _, key in ipairs({ 'springF', 'springR' }) do
      local var = w.space.byKey[key]
      -- bornes de la recherche réduite (une fois la rugosité mesurée)
      local lo, hi = math.max(var.rangeLo, -K.optRadiusReduced), math.min(var.rangeHi, K.optRadiusReduced)
      T.ok(hi > lo, key .. ' : plage')
      local best, bestD, balances = math.huge, 0, {}
      for d = lo, hi do
        local s = Space.apply(w.space, CarModel.defaultSetup(w.base), { [key] = d })
        local eff = assert(CarModel.configure(w.base, s, { airTemp = 24, roughness = 8e-6 }))
        local r = Sim.run(w.track, eff, nil)
        local bal, stab = Sim.penalties(r)
        local J = r.time + weights.bal * bal + weights.stab * stab
        balances[d] = r.balanceMean
        if J < best then best, bestD = J, d end
      end
      PY.note('X06', string.format('%s %s : meilleur %+d dans [%d ; %d] ; équilibre %.3f -> %.3f', carId:sub(1, 12), key, bestD, lo,
        hi, balances[0], balances[bestD]))
      if bestD == lo or bestD == hi then
        -- butée : l'équilibre à la butée est toujours du côté de départ (la voiture reste sous- ou
        -- survireuse), sinon l'optimum aurait été intérieur
        T.eq(balances[bestD] < 1, balances[0] < 1, carId .. ' ' .. key .. ' : butée sans changement de côté')
      end
    end
  end
end

tests['X08 puissance de freinage sans ABS : risque de blocage au-delà de la marge (H15)'] = function()
  local w = world('urd_px1_aura', 'spa')
  local function risk(power, abs)
    local s = Space.apply(w.space, CarModel.defaultSetup(w.base), {})
    if power then s.brakePower = power end
    local eff = assert(CarModel.configure(w.base, s, { airTemp = 24, absActive = abs }))
    local r = Sim.run(w.track, eff, nil)
    local _, stab = Sim.penalties(r)
    return eff.brakeLockRisk, stab
  end
  local r0, stab0 = risk(nil, false)
  T.eq(r0, 0, 'setup d\'origine : sous la marge')
  local rHigh, stabHigh = risk(1.6, false)
  PY.note('X08', string.format('risque de blocage %.3f avec 160 %% de puissance, sans ABS', rHigh))
  T.ok(rHigh > 0, 'pédale trop puissante sans ABS')
  T.ok(stabHigh > stab0, 'pénalité de stabilité')
  -- sur un même tour, la pénalité de stabilité compte exactement le risque de blocage
  local result = { rearFirstShare = 0.2, bottoming = false, brakeLockRisk = rHigh, balanceRms = 0 }
  local _, with = Sim.penalties(result)
  result.brakeLockRisk = 0
  local _, without = Sim.penalties(result)
  T.near(with - without, K.brakeLockPenaltySec * rHigh, 1e-12)
  T.eq((risk(1.6, true)), 0, 'ABS actif : aucun risque')
end

tests['X09 différentiel en accélération : optimum intérieur grâce au moment de lacet (H20)'] = function()
  local w = world('whk_dtm_2026', 'spa')
  local weights = Config.penaltyWeights(Config.defaults())
  local var = w.space.byKey.diffPower
  local best, bestD = math.huge, nil
  for d = var.rangeLo, var.rangeHi do
    local s = Space.apply(w.space, CarModel.defaultSetup(w.base), { diffPower = d })
    local r = Sim.run(w.track, assert(CarModel.configure(w.base, s, { airTemp = 24 })), nil)
    local bal, stab = Sim.penalties(r)
    local J = r.time + weights.bal * bal + weights.stab * stab
    if J < best then best, bestD = J, d end
  end
  PY.note('X09', string.format('DTM à Spa : meilleur blocage %+d crans dans [%d ; %d]', bestD, var.rangeLo, var.rangeHi))
  T.ok(bestD > var.rangeLo and bestD < var.rangeHi, 'optimum intérieur')
  local eff = assert(CarModel.configure(w.base, CarModel.defaultSetup(w.base), { airTemp = 24 }))
  T.ok(eff.diffYawK and eff.diffYawK > 0)
end

tests['X07 colle : rugosité mesurée sur un tour -> suspension optimisable, statut affiché'] = function()
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  local function frame(profile, noise, rng)
    if profile then
      h.car.isInPit, h.car.isInPitlane = false, false
      Fake.drive(h, profile, 1 / 60)
      for wh = 0, 3 do
        local g = -6
        for _ = 1, 12 do g = g + Util.rngRange(rng, 0, 1) end
        h.car.wheels[wh].load = 3500 + noise * g
      end
    end
    h.sim.time = h.sim.time + 1000 / 60
    script.SETUPLAB__UPDATE(1 / 60)
    script.SETUPLAB__MAIN(1 / 60)
  end
  for _ = 1, 40000 do
    frame()
    if app.discoveryState == 'done' then break end
  end
  local d = app.discovery
  T.eq(d.space.byKey.springF.class, Space.EXCLUDED, 'avant mesure : conservé')
  T.contains(d.space.byKey.springF.reason, 'rugosité')
  local tm = d.trackModel
  local profile = { p = {}, v = {} }
  for k = 1, tm.n do profile.p[k], profile.v[k] = tm.p[k], 55 end
  profile.p[#profile.p + 1], profile.v[#profile.v + 1] = 1, 55
  local rng = Util.rngNew(3)
  for _ = 1, 60 * 400 do
    frame(profile, 200, rng)
    if app.roughness and d.space.byKey.springF.class ~= Space.EXCLUDED then break end
  end
  T.ok(app.roughness, 'rugosité mesurée')
  PY.note('X07', string.format('G0 %.2e (avant %.2e, arrière %.2e) à %.0f m/s', app.roughness.G0, app.roughness.front,
    app.roughness.rear, app.roughness.speed))
  T.ok(app.roughness.consistent)
  T.eq(d.space.byKey.springF.class, Space.REDUCED)
  T.eq(d.space.byKey.damperSlowF.class, Space.REDUCED)
  T.ok(d.conditions.roughness and d.conditions.roughness > 0)
  local rows = Space.statusRows(d.space)
  local found = false
  for _, row in ipairs(rows) do
    if row.key == 'springF' then found = row.status == 'optimisé' and row.detail:find('rugosité', 1, true) ~= nil end
  end
  T.ok(found, 'statut : optimisé, rugosité mesurée')
  -- butées et course avant butée : conservées tant que H16 n'est pas confirmée (relecture J6b, M1)
  local stops = 0
  for _, var in ipairs(d.space.vars) do
    if var.kind == 'bumpStop' or var.kind == 'packer' then
      stops = stops + 1
      T.eq(var.class, Space.EXCLUDED, var.key)
    end
  end
  T.ok(stops > 0, 'la Huracán a des butées réglables')
  for _, row in ipairs(rows) do
    if row.key == 'packerF' or row.key == 'bumpStopF' then T.contains(row.detail, 'H16') end
  end
  -- course de suspension relevée pour trancher H16 (rapport J0)
  T.contains(app.report or '', 'course de suspension (H16) 0.0185')
end

tests['X10 rugosité (D11) : jamais un gain d\'adhérence (LS_EXPY > 1), G0 plausible, fenêtre à rapport constant'] = function()
  local w = world('lamborghini_huracan_gt3_evo2', 'monza')
  local s = Space.apply(w.space, CarModel.defaultSetup(w.base), {})
  -- pneu synthétique à LS_EXPY = 1,2 (accepté jusqu'à 1,5) : facteur borné à 1
  local base = {}
  for key, value in pairs(w.base) do base[key] = value end
  local c = {}
  for key, value in pairs(w.base.compounds[s.compound]) do c[key] = value end
  local front = {}
  for key, value in pairs(c.front) do front[key] = value end
  front.lsExpY = 1.2
  c.front = front
  base.compounds = {}
  for i, one in ipairs(w.base.compounds) do base.compounds[i] = i == s.compound and c or one end
  local eff = assert(CarModel.configure(base, s, { airTemp = 24, roughness = 64e-6 }))
  for i = 1, eff.speedCount do T.ok(eff.bumpGripF[i] <= 1 + 1e-12, 'adhérence ' .. eff.bumpGripF[i]) end
  -- G0 hors de toute piste (classe D de l'ISO 8608) : non retenu
  local eff0 = assert(CarModel.configure(w.base, s, { airTemp = 24, roughness = 1 }))
  local v = 50
  local i = math.min(eff0.speedCount, math.floor(v / eff0.dv) + 1)
  local sigmas = {}
  for _, axle in ipairs({ 'F', 'R' }) do
    local q = eff0['quarter' .. axle]
    sigmas[axle] = CarModel.loadSigma(q, 1024e-6, v, false)
  end
  local r = assert(CarModel.roughness(w.base, s, { loadSigma = { sigmas.F, sigmas.F, sigmas.R, sigmas.R }, roughSpeed = v },
    { airTemp = 24 }))
  T.no(r.consistent, 'G0 ' .. r.G0 .. ' : pas un circuit')
  local _ = i
  -- enregistreur : un passage de rapport (marche de charge, tangage) recommence la fenêtre de ligne
  -- droite ; charge constante dans chaque rapport : aucune variance
  local rec = Recorder.new()
  w.h.driver = nil
  local profile = { p = {}, v = {} }
  for k = 1, w.track.n do profile.p[k], profile.v[k] = w.track.p[k], 60 end
  profile.p[#profile.p + 1], profile.v[#profile.v + 1] = 1, 60
  local now, start, last, frames = 0, w.h.car.lapCount, nil, 0
  while w.h.car.lapCount < start + 2 or rec.pending do
    Fake.drive(w.h, profile, 1 / 60)
    now, frames = now + 1 / 60, frames + 1
    local gear = (math.floor(frames / 45) % 2 == 0) and 4 or 5
    w.h.car.gear = gear
    for wh = 0, 3 do w.h.car.wheels[wh].load = gear == 5 and 3600 or 3000 end
    last = Recorder.update(rec, w.h, now, function() return 'S1' end, { trackLength = w.track.length, conditions = {} }) or last
  end
  T.ok(last.loadSigma, 'fenêtres à rapport constant')
  T.ok(last.loadSigma[1] < 1, 'marche de charge au passage de rapport exclue : ' .. last.loadSigma[1])
  for wh = 0, 3 do w.h.car.wheels[wh].load = 3000 end
  w.h.driver = nil
end

return tests
