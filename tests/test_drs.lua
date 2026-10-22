-- Tests du DRS (J6b, §8.9) : lecture de drs.ini, tables volet ouvert, simulation dans les zones,
-- qualification, course (tours en trafic), mesure de l'effet réel du volet par l'enregistreur (H8).
local T = require('t')
local Util = require('src/util')
local Config = require('src/config')
local Datasource = require('src/datasource')
local TrackModel = require('src/track_model')
local CarModel = require('src/car_model')
local Space = require('src/setup_space')
local Sim = require('src/laptime_sim')
local Optimizer = require('src/optimizer')
local StintSim = require('src/stint_sim')
local Recorder = require('src/recorder')
local Calibration = require('src/calibration')
local Fake = require('fakehost')

local K = Config.K
local SYNC = Util.syncContext()
local tests = {}

local cache = {}
local function world(carId, trackId)
  local key = carId .. '@' .. trackId
  if cache[key] then return cache[key] end
  local h = Fake.new({ car = require('fixtures/cars/' .. carId), track = require('fixtures/tracks/' .. trackId), drs = true })
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

-- Copie de la base avec un autre DRS (LIMIT_G, EFFECT).
local function withDrs(base, patch)
  local copy = {}
  for key, value in pairs(base) do copy[key] = value end
  copy.drs = {}
  for key, value in pairs(base.drs) do copy.drs[key] = value end
  for key, value in pairs(patch) do copy.drs[key] = value end
  return copy
end

local function run(w, base, setup, drs)
  local conditions = { airTemp = CONDITIONS.airTemp, roadGrip = CONDITIONS.roadGrip, drs = drs }
  local eff = assert(CarModel.configure(base, setup, conditions))
  local buf = Sim.new(w.track)
  local result = Sim.run(w.track, eff, buf)
  return result, buf, eff
end

tests['G01 drs.ini : aile mobile et EFFECT ; clés au sens non établi refusées (§0.6)'] = function()
  local w = world('whk_dtm_2026', 'monza')
  local drs = w.base.drs
  T.ok(drs and drs.usable, tostring(drs and drs.reason))
  T.eq(drs.wing, 4)
  T.near(drs.effect, 0.5, 1e-12)
  -- drs.ini vide (GT3) : pas de DRS
  T.eq(world('lamborghini_huracan_gt3_evo2', 'monza').base.drs, nil)
  local function read(text)
    return CarModel.readDrs({ ini = { ['drs.ini'] = Util.parseIni(text) } }, w.base.wings)
  end
  T.contains(read('[WING_4]\nEFFECT=0.0\n').reason, 'EFFECT = 0')
  T.contains(read('[WING_4]\nEFFECT=1.5\n').reason, 'hors de')
  T.contains(read('[WING_4]\nEFFECT=abc\n').reason, 'illisible')
  T.contains(read('[WING_9]\nEFFECT=0.5\n').reason, 'absente')
  T.contains(read('[WING_4]\nEFFECT=0.5\nIGNORE_ZONES=1\n').reason, 'IGNORE_ZONES')
  T.contains(read('[WING_4]\nEFFECT=0.5\nDRS_ZONES=0\n').reason, 'DRS_ZONES')
  T.no(read('[WING_4]\nEFFECT=0.5\nIGNORE_ZONES=1\n').usable)
  local ok = read('[WING_4]\nEFFECT=0.4\nDRS_ZONES=1\nIGNORE_ZONES=0\nLIMIT_G=1.2\nDEACTIVATION=1\nMODE=2\n')
  T.ok(ok.usable, tostring(ok.reason))
  T.near(ok.limitG, 1.2, 1e-12)
  local notes = table.concat(ok.notes, ' ; ')
  T.contains(notes, 'DEACTIVATION')
  T.contains(notes, 'MODE')
  T.eq(read('[HEADER]\nVERSION=1\n'), nil, 'sans section WING_n : pas de DRS')
end

tests['G02 tables volet ouvert : traînée réduite selon H8, vitesse de pointe plus haute, seulement sur demande'] = function()
  local w = world('whk_dtm_2026', 'monza')
  local s = CarModel.defaultSetup(w.base)
  local closed = assert(CarModel.configure(w.base, s, CONDITIONS))
  T.no(closed.drsOn, 'tables volet ouvert seulement sur demande')
  local open = assert(CarModel.configure(w.base, s, { airTemp = 24, roadGrip = 0.98, drs = true }))
  T.ok(open.drsOn)
  for i = 2, open.speedCount do
    T.ok(open.dragOpen[i] < open.drag[i], 'traînée volet ouvert à ' .. (i - 1) * open.dv .. ' m/s')
  end
  T.ok(open.topSpeedOpen > open.topSpeed + 1, 'pointe ' .. open.topSpeed .. ' -> ' .. open.topSpeedOpen)
  -- H8 : EFFECT 0,5 retire la moitié de ce que retire EFFECT 1 (à l'écrasement de la suspension près)
  local full = assert(CarModel.configure(withDrs(w.base, { effect = 1 }), s, { airTemp = 24, roadGrip = 0.98, drs = true }))
  local i = 31
  local half, whole = open.drag[i] - open.dragOpen[i], full.drag[i] - full.dragOpen[i]
  PY.note('G02', string.format('traînée à 60 m/s : %.0f N ; retirée : %.0f N (EFFECT 0,5), %.0f N (EFFECT 1)', open.drag[i], half,
    whole))
  T.near(half / whole, 0.5, 0.05)
  -- voiture sans DRS : demande ignorée
  local gt3 = world('lamborghini_huracan_gt3_evo2', 'monza')
  T.no(assert(CarModel.configure(gt3.base, CarModel.defaultSetup(gt3.base), { airTemp = 24, drs = true })).drsOn)
end

tests['G03 simulation : gain dans les zones seulement, au-delà de la pointe volet fermé, volet fermé au freinage'] = function()
  local w = world('whk_dtm_2026', 'monza')
  local s = CarModel.defaultSetup(w.base)
  local r0, b0 = run(w, w.base, s, false)
  local v0 = {}
  for k = 1, w.track.n do v0[k] = b0.v[k] end
  local r1, b1 = run(w, w.base, s, true)
  PY.note('G03', string.format('Monza : %.3f -> %.3f s ; vitesse maximale %.1f -> %.1f km/h (pointe volet fermé %.1f) ; '
    .. 'volet ouvert %.1f s', r0.time, r1.time, r0.vMax * 3.6, r1.vMax * 3.6, r0.vTop * 3.6, r1.drsTime))
  T.ok(r1.time < r0.time - 0.1, 'gain du DRS')
  -- plafond levé : la vitesse dépasse la vitesse de pointe volet fermé
  T.ok(r1.vMax > r0.vTop + 0.5, 'vitesse maximale ' .. r1.vMax .. ' contre pointe volet fermé ' .. r0.vTop)
  T.ok(r1.drsTime > 0)
  local opened = 0
  for k = 1, w.track.n do
    if b1.drsOpen[k] == 1 then
      opened = opened + 1
      T.eq(b1.drsZone[k], 1, 'volet ouvert hors zone au point ' .. k)
      T.ok(b1.limit[k] ~= Sim.LIMIT.brake, 'volet ouvert au freinage au point ' .. k)
    end
  end
  T.ok(opened > 0)
  -- le profil ne change qu'à partir d'une zone, jusqu'au premier point où la vitesse retombe à la même
  -- limite (virage) : en amont des zones, rien ne bouge
  local dirty = false
  local k = r0.kMin
  for _ = 1, w.track.n do
    if b1.drsZone[k] == 1 then
      dirty = true
    elseif math.abs(b1.v[k] - v0[k]) < 1e-9 and b1.limit[k] == Sim.LIMIT.corner then
      dirty = false
    end
    if b1.drsZone[k] == 0 and math.abs(b1.v[k] - v0[k]) > 1e-6 then
      T.ok(dirty, 'vitesse modifiée en amont d\'une zone au point ' .. k)
    end
    k = k % w.track.n + 1
  end
  -- circuit sans zone : aucun effet
  local saved = w.track.drsZones
  w.track.drsZones = {}
  local r2 = run(w, w.base, s, true)
  w.track.drsZones = saved
  T.near(r2.time, r0.time, 1e-9)
  -- zone qui chevauche la ligne (Red Bull Ring, ZONE_0 de 0,9275 à 0,064)
  local rbr = world('whk_dtm_2026', 'ks_red_bull_ring-layout_gp')
  local buf = Sim.new(rbr.track)
  T.eq(buf.drsZoneCount, 2)
  T.eq(buf.drsZone[1], 1, 'début du tour dans la zone')
  T.eq(buf.drsZone[rbr.track.n], 1, 'fin du tour dans la zone')
end

tests['G04 LIMIT_G (H9) : volet refermé au-delà de l\'accélération latérale donnée'] = function()
  local w = world('whk_dtm_2026', 'spa')
  local s = CarModel.defaultSetup(w.base)
  local r1 = run(w, w.base, s, true)
  local limited = withDrs(w.base, { limitG = 0.3 })
  local r2, b2 = run(w, limited, s, true)
  PY.note('G04', string.format('Spa : volet ouvert %.2f s sans limite, %.2f s sous 0,3 g ; tour %.3f / %.3f s', r1.drsTime, r2.drsTime,
    r1.time, r2.time))
  T.ok(r2.drsTime < r1.drsTime, 'moins de temps volet ouvert')
  T.ok(r2.time >= r1.time - 1e-9, 'moins de gain')
  for k = 1, w.track.n do
    if b2.drsOpen[k] == 1 then T.ok(b2.ayReq[k] <= 0.3 * 9.80665 + 0.05, 'volet ouvert à ' .. b2.ayReq[k] .. ' m/s²') end
  end
end

tests['G05 boîte : le DRS ne paie qu\'avec une boîte assez longue pour dépasser la pointe volet fermé'] = function()
  local w = world('whk_dtm_2026', 'monza')
  local s = CarModel.defaultSetup(w.base)
  local base = assert(CarModel.configure(w.base, s, CONDITIONS))
  local final0 = s.final
  local limiter0 = base.gearVmax[#s.gears] * 3.6
  -- gain du DRS selon la vitesse au limiteur du dernier rapport : sous la pointe volet fermé
  -- (252 km/h), le limiteur empêche de profiter de la traînée réduite en bout de ligne droite
  local function gain(target)
    s.final = final0 * limiter0 / target
    local closed, open = run(w, w.base, s, false), run(w, w.base, s, true)
    return closed.time - open.time
  end
  local short, long = gain(244), gain(276)
  s.final = final0
  PY.note('G05', string.format('gain du DRS : %.3f s avec un limiteur à 244 km/h, %.3f s à 276 km/h', short, long))
  T.ok(long > short + 0.1, 'gain du DRS avec une boîte longue')
  T.ok(short > 0, 'traînée réduite à l\'accélération')
end

tests['G06 qualification : DRS dans toutes les zones, part du gain, avertissement si le gain en dépend'] = function()
  local w = world('whk_dtm_2026', 'monza')
  local settings = Config.defaults()
  local args = { base = w.base, space = w.space, track = w.track, trackCoarse = w.coarse, settings = settings, budget = 160,
    conditions = { airTemp = 24, roadGrip = 0.98, surfaceGrip = w.track.surfaceGrip }, drs = true }
  local r = assert(Optimizer.runQuali(Optimizer.prepareQuali(args), SYNC, Optimizer.newState({ budget = 160 })))
  local drs = r.drs
  T.ok(drs, 'bilan du DRS')
  T.eq(drs.zones, 2)
  T.ok(drs.openTime > 0)
  T.ok(drs.timeProposedNoDrs > r.timeProposed, 'plus lent sans DRS')
  T.near(drs.gainNoDrs + drs.share, r.timeCurrent - r.timeProposed, 1e-9)
  PY.note('G06', string.format('gain %.3f s, dont DRS %.3f s ; pointe %.1f -> %.1f km/h', r.timeCurrent - r.timeProposed, drs.share,
    drs.vTop * 3.6, drs.vTopOpen * 3.6))
  -- sans DRS demandé : pas de bilan
  args.drs = false
  T.eq(assert(Optimizer.runQuali(Optimizer.prepareQuali(args), SYNC, Optimizer.newState({ budget = 40 }))).drs, nil)
  -- avertissement : setup meilleur avec le DRS seulement
  local warned = Optimizer.drsReport(2, { time = 100 }, { time = 99.8, drsTime = 10 }, { time = 101 }, { time = 101.1 })
  T.contains(warned.warning, 'H8')
  T.near(warned.share, 0.3, 1e-9)
  T.eq(Optimizer.drsReport(2, { time = 100 }, { time = 99.8 }, { time = 101 }, { time = 100.9 }).warning, nil)
  T.eq(Optimizer.drsReport(2, { time = 100 }, nil, { time = 101 }, { time = 100.9 }), nil)
end

tests['G07 course : DRS sur les tours en trafic seulement'] = function()
  local w = world('whk_dtm_2026', 'monza')
  local s = Space.apply(w.space, CarModel.defaultSetup(w.base), {})
  local weights = { bal = 0, stab = 0, traffic = 1, rob = 0 }
  local function evaluate(drs)
    local plan = StintSim.plan({ laps = 10, fuelStart = 30, fuelPerLap = 2.5, trafficFraction = 0.3,
      slipstreamDrag = K.raceSlipstreamDrag, dirtyAirLift = K.raceDirtyAirLift, drs = drs })
    local ev = StintSim.newEvaluator({ base = w.base, track = w.track, conditions = CONDITIONS, plan = plan, compound = s.compound,
      weights = weights })
    local _, detail = StintSim.evaluate(ev, s)
    return detail, StintSim.runExact(ev, s)
  end
  local without, exact0 = evaluate(false)
  local with, exact1 = evaluate(true)
  PY.note('G07', string.format('P_trafic %.4f s sans DRS, %.4f s avec', without.traffic, with.traffic))
  T.ok(with.traffic < without.traffic - 0.01, 'DRS dans le trafic')
  T.near(with.mean, without.mean, 1e-9, 'tours en air libre : pas de DRS')
  T.near(exact1.mean, exact0.mean, 1e-9)
  -- optimisation course : tour de référence et relais sans DRS, plan avec DRS
  local p = Optimizer.prepareRace({ base = w.base, space = w.space, track = w.track, settings = Config.defaults(), budget = 20,
    conditions = { airTemp = 24, roadGrip = 0.98 }, drs = true, race = { fuelPerLapCsp = 2.5, kmPerLapF = 5, kmPerLapR = 5 } })
  T.eq(p.conditions.drs, false)
  local r = assert(Optimizer.runRace(p, SYNC, Optimizer.newState({ budget = 20 })))
  T.eq(r.race.drs, true)
end

tests['G08 enregistreur : volet ouvert par tour, mesure de l\'effet réel (cl, cd ouvert / fermé)'] = function()
  local w = world('whk_dtm_2026', 'monza')
  local h = w.h
  h.car.drsPresent = true
  h.car.isInPit, h.car.isInPitlane = false, false
  h.physicsState.wings = Fake.wings({ { 0.4, 0, 0, 0, 0.3 }, { 0.05, -0.4, 6, 6, 0.06 }, { 0.2, -0.5, 6, 6, 0.9 },
    { 0.1, -0.2, 3, 3, 0.5 }, { 0.3, -0.9, 8, 8, 0.8 } })
  local s = CarModel.defaultSetup(w.base)
  local _, buf = run(w, w.base, s, true)
  local profile = { p = {}, v = {} }
  for k = 1, w.track.n do profile.p[k], profile.v[k] = w.track.p[k], buf.v[k] end
  profile.p[#profile.p + 1], profile.v[#profile.v + 1] = 1, buf.v[1]
  -- effet réel simulé : appui de l'aile réduit de 60 %, traînée de 45 % (différent de H8)
  profile.drs = { wing = 4, zones = { { 0.029, 0.152 }, { 0.537, 0.674 } }, cl = 0.4, cd = 0.55 }
  local rec = Recorder.new()
  local context = { trackLength = w.track.length, conditions = { airTemp = 24, roadGrip = 0.98 }, drsWing = 4 }
  local laps, now, start = {}, 0, h.car.lapCount
  h.driver = nil
  while h.car.lapCount < start + 3 or rec.pending do
    Fake.drive(h, profile, 1 / 60)
    now = now + 1 / 60
    local lap = Recorder.update(rec, h, now, function() return 'S1' end, context)
    if lap then laps[#laps + 1] = lap end
  end
  T.ok(#laps >= 2)
  local lap = laps[#laps]
  T.ok(lap.valid, tostring(lap.reason))
  T.ok(lap.drsUsed)
  T.ok(lap.drsShare > 0.1 and lap.drsShare < 0.4, 'part du tour volet ouvert ' .. lap.drsShare)
  local m = Recorder.drsSummary(rec)
  PY.note('G08', string.format('%d bascules ; cl ouvert/fermé %.3f ; cd %.3f ; volet ouvert %.0f %% du tour', m.n, m.cl, m.cd,
    lap.drsShare * 100))
  T.ok(m.n >= 4, 'deux ouvertures par tour')
  T.near(m.cl, 0.4, 1e-3)
  T.near(m.cd, 0.55, 1e-3)
  -- tour mesuré avec DRS : simulé avec DRS (calibration, validation)
  T.ok(Calibration.lapConditions(lap).drs)
  local text = Recorder.exportText(lap, { appVersion = 'test', drs = { measure = m, expected = 0.5 } },
    function(p) return TrackModel.sAtProgress(w.track, p) end, w.track.length)
  T.contains(text, 'bascules mesurées')
  -- saut de vitesse à l'ouverture (première zone) : bascule écartée, seule la seconde zone compte
  local jumpy = { p = profile.p, v = {}, drs = profile.drs }
  for i, p in ipairs(profile.p) do
    jumpy.v[i] = (p >= 0.029 and p <= 0.152) and profile.v[i] + 15 or profile.v[i]
  end
  local rec3 = Recorder.new()
  h.driver = nil
  start = h.car.lapCount
  while h.car.lapCount < start + 3 or rec3.pending do
    Fake.drive(h, jumpy, 1 / 60)
    now = now + 1 / 60
    Recorder.update(rec3, h, now, function() return 'S1' end, context)
  end
  local m3 = Recorder.drsSummary(rec3)
  T.ok(m3.n >= 2 and m3.n <= 3, 'bascules à vitesse voisine seulement : ' .. m3.n)
  T.near(m3.cl, 0.4, 1e-3)
  -- sans aile désignée : rien n'est relevé
  local rec2 = Recorder.new()
  context.drsWing = nil
  h.driver = nil
  start = h.car.lapCount
  local last = nil
  while h.car.lapCount < start + 2 or rec2.pending do
    Fake.drive(h, profile, 1 / 60)
    now = now + 1 / 60
    last = Recorder.update(rec2, h, now, function() return 'S1' end, context) or last
  end
  T.no(last.drsUsed)
  T.eq(Recorder.drsSummary(rec2).n, 0)
  h.physicsState.wings = Fake.wings({ { 0.41, 0, 0, 0, 0.3 }, { 0.05, 0.46, 6, 6, 0.06 }, { 0.18, 0.43, 6, 6, 0.9 } })
  h.car.drsActive, h.driver = false, nil
end

local function boot(carId, trackId, opts)
  opts = opts or {}
  opts.car = require('fixtures/cars/' .. carId)
  opts.track = require('fixtures/tracks/' .. trackId)
  local h = Fake.new(opts)
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  for _ = 1, 40000 do
    h.sim.time = h.sim.time + 1000 / 60
    script.SETUPLAB__UPDATE(1 / 60)
    script.SETUPLAB__MAIN(1 / 60)
    if app.discoveryState == 'done' then break end
  end
  return h, app
end

tests['G09 découverte : DRS simulé si la voiture, AC et le circuit le permettent, sinon la raison'] = function()
  local _, app = boot('whk_dtm_2026', 'monza', { drs = true })
  T.eq(app.discoveryState, 'done')
  local drs = app.discovery.drs
  T.ok(drs.enabled, tostring(drs.reason))
  T.eq(drs.zones, 2)
  T.eq(drs.wing, 4)
  T.contains(app.discovery.caps.byId.drs.detail, 'simulé dans 2 zone(s)')
  -- AC n'annonce pas de DRS
  local _, app2 = boot('whk_dtm_2026', 'monza')
  T.no(app2.discovery.drs.enabled)
  T.contains(app2.discovery.drs.reason, 'drsPresent')
  -- voiture sans DRS
  local _, app3 = boot('lamborghini_huracan_gt3_evo2', 'monza', { drs = true })
  T.no(app3.discovery.drs.enabled)
  T.contains(app3.discovery.drs.reason, 'pas de DRS')
  -- circuit sans zone : Nordschleife de la fixture a une zone ; zones retirées du fichier
  local fixture = require('fixtures/tracks/monza')
  local saved = fixture.files['drs_zones.ini']
  fixture.files['drs_zones.ini'] = nil
  local ok, app4 = pcall(function() return select(2, boot('whk_dtm_2026', 'monza', { drs = true })) end)
  fixture.files['drs_zones.ini'] = saved
  T.ok(ok, tostring(app4))
  T.no(app4.discovery.drs.enabled)
  T.contains(app4.discovery.drs.reason, 'aucune zone')
end

return tests
