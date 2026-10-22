-- Tests de src/recorder (J5, §9.1) avec le conducteur simulé de l'hôte, et de la reconnaissance du
-- circuit depuis un tour enregistré (§7.1 source 2, A14).
local T = require('t')
local Util = require('src/util')
local Config = require('src/config')
local Datasource = require('src/datasource')
local TrackModel = require('src/track_model')
local CarModel = require('src/car_model')
local Sim = require('src/laptime_sim')
local Recorder = require('src/recorder')
local Fake = require('fakehost')

local K = Config.K
local SYNC = Util.syncContext()
local tests = {}

-- Hôte, modèle de circuit et profil de vitesse simulé (progression -> vitesse).
local function setup(trackId)
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/' .. trackId) })
  local raw = Datasource.sampleTrack(h, 1, SYNC)
  Datasource.probeBank(h, raw, SYNC)
  local files = Datasource.readTrackFiles(h, SYNC)
  local track = assert(TrackModel.build(raw, files, 2))
  local base = CarModel.build(Datasource.readCar(h, 0, SYNC), nil)
  local eff = assert(CarModel.configure(base, CarModel.defaultSetup(base), { airTemp = 25 }))
  local result, buf = Sim.run(track, eff, nil)
  local profile = { p = {}, v = {} }
  for k = 1, track.n do profile.p[k], profile.v[k] = track.p[k], buf.v[k] end
  profile.p[#profile.p + 1], profile.v[#profile.v + 1] = 1, buf.v[1]
  return { h = h, track = track, profile = profile, simTime = result.time, raw = raw, files = files }
end

-- Fait rouler n tours (plus la fin du tour de départ) ; hook(i, h) appelé à chaque frame.
local function drive(env, laps, rec, hook, signatureFn)
  local h, dt, now = env.h, 1 / 60, 0
  local finished = {}
  local context = { trackLength = env.track.length, conditions = { airTemp = 25, roadTemp = 32, roadGrip = 0.98 },
    keepPositions = env.keepPositions }
  local startCount = h.car.lapCount
  local frame = 0
  local extra = 0
  -- après le dernier passage de ligne, le temps officiel peut encore être attendu (mise à jour tardive)
  while h.car.lapCount < startCount + laps + 1 or (rec.pending and extra < 120) do
    if h.car.lapCount >= startCount + laps + 1 then extra = extra + 1 end
    frame = frame + 1
    if hook then hook(frame, h, rec) end
    Fake.drive(h, env.profile, dt)
    now = now + dt
    context.paused = h.paused
    local lap = Recorder.update(rec, h, now, signatureFn or function() return 'S1' end, context)
    if lap then finished[#finished + 1] = lap end
    assert(frame < 200000, 'conduite bloquée')
  end
  return finished
end

local cache = {}
local function env(trackId)
  if cache[trackId] == nil then cache[trackId] = setup(trackId) end
  local e = cache[trackId]
  e.h.driver = nil
  e.h.car.isLapValid, e.h.car.isInPitlane, e.h.car.brakeBias = true, false, 0.62
  e.profile.jumpAt, e.profile.jump, e.profile.lineOffset, e.profile.noProgress = nil, nil, nil, nil
  e.profile.startP = nil
  e.h.paused, e.h.lateLapTimeFrames, e.h.lapTimeError = nil, nil, nil
  e.h.lateLapCountFrames, e.h.lateTimerResetFrames = nil, nil
  return e
end

tests['R01 tours enregistrés : tour partiel ignoré, temps officiel, 30 Hz, couverture'] = function()
  local e = env('monza')
  local rec = Recorder.new()
  e.profile.startP = 0.4
  local laps = drive(e, 2, rec)
  e.profile.startP = nil
  T.eq(#laps, 2, 'le tour commencé en cours de route n\'est pas enregistré')
  for _, lap in ipairs(laps) do
    T.ok(lap.valid, tostring(lap.reason))
    -- temps officiel d'AC (previousLapTimeMs) ; le conducteur simulé intègre à pas fixe : ≈ tour simulé
    T.near(lap.time, e.simTime, 0.25, 'temps officiel ≈ tour simulé')
    T.near(lap.n / lap.time, K.recorderHz, 1.5, 'fréquence d\'échantillonnage')
    T.ok(lap.p[1] < 0.01 and lap.p[lap.n] > 0.99, 'tour complet')
    T.eq(lap.signature, 'S1')
  end
  T.eq(Recorder.best(rec, 'S1'), laps[1].time <= laps[2].time and laps[1] or laps[2])
  T.ok(rec.laps.last == laps[2])
end

tests['R02 tours rejetés avec leur raison'] = function()
  -- événements déclenchés en plein tour enregistré (le tour de départ n'est jamais enregistré)
  local function midLap(rec) return rec.state == 'enregistrement' and rec.n == 1500 end
  local cases = {
    { 'tour invalidé par AC', function(_, h, rec) if midLap(rec) then h.car.isLapValid = false end end },
    { 'voie des stands', function(_, h, rec) if midLap(rec) then h.car.isInPitlane = true end end },
    { 'répartition de freinage', function(_, h, rec) if midLap(rec) then h.car.brakeBias = 0.58 end end },
  }
  for _, case in ipairs(cases) do
    local e = env('monza')
    local rec = Recorder.new()
    local laps = drive(e, 1, rec, case[2])
    T.eq(#laps, 1)
    T.no(laps[1].valid, case[1])
    T.contains(laps[1].reason, case[1])
    T.eq(Recorder.best(rec, 'S1'), nil, 'jamais retenu comme meilleur tour')
  end
  -- téléportation : trou de couverture
  local e = env('monza')
  e.profile.jumpAt, e.profile.jump = 0.5, 0.1
  local rec = Recorder.new()
  local laps = drive(e, 1, rec)
  T.contains(laps[1].reason, 'trou de couverture')
  -- setup changé pendant le tour
  local e2 = env('monza')
  local calls = 0
  local rec2 = Recorder.new()
  local laps2 = drive(e2, 1, rec2, nil, function()
    calls = calls + 1
    return calls <= 1 and 'A' or 'B'
  end)
  T.contains(laps2[#laps2].reason, 'setup modifié')
  -- mémoire pleine
  local e3 = env('monza')
  local rec3 = Recorder.new(500)
  local laps3 = drive(e3, 1, rec3)
  T.contains(laps3[1].reason, 'mémoire pleine')
end

tests['R03 mémoire bornée : dernier tour et meilleur tour par setup'] = function()
  local e = env('ks_red_bull_ring-layout_gp')
  local rec = Recorder.new()
  local n = 0
  local laps = drive(e, 6, rec, nil, function()
    n = n + 1
    return 'S' .. math.floor((n + 1) / 2)
  end)
  T.eq(#laps, 6)
  local kept = 0
  for _ in pairs(rec.laps.best) do kept = kept + 1 end
  T.ok(kept <= K.recorderMaxSignatures, kept .. ' setups conservés')
  T.eq(#rec.laps.order, kept)
  -- tour conservé sans positions (seule la reconnaissance en a besoin)
  T.eq(laps[1].x, nil, 'positions non conservées')
  T.eq(Recorder.reconnaissance(laps[1], nil).ok, false)
  -- le tampon de tour est réutilisé : sa longueur ne croît pas au fil des tours
  local length = #rec.buf.v
  drive(e, 2, rec)
  T.eq(#rec.buf.v, length, 'tampon réutilisé')
end

tests['R04 export du tour : en-tête et un point tous les 5 m'] = function()
  local e = env('monza')
  local rec = Recorder.new()
  local laps = drive(e, 1, rec)
  local lap = laps[1]
  local sAt = function(p) return TrackModel.sAtProgress(e.track, p) end
  local text = Recorder.exportText(lap, { appVersion = Config.version, carId = 'gt3', trackId = 'monza', setupText = 'X=1' }, sAt,
    e.track.length)
  T.contains(text, 'Temps officiel : ' .. Util.fmt(lap.time, 3))
  T.contains(text, 'Masse CSP')
  T.contains(text, 's_m;v_kmh;gaz;frein;rapport;regime')
  local rows = 0
  local lastS = -1
  for line in text:gmatch('[^\n]+') do
    local s, v = line:match('^(%d+);([%d%.]+);')
    if s then
      rows = rows + 1
      T.ok(tonumber(s) > lastS, 'abscisses croissantes')
      lastS = tonumber(s)
      T.ok(tonumber(v) > 30 and tonumber(v) < 400, 'vitesse plausible')
    end
  end
  T.near(rows, e.track.length / K.exportLapStepM, 2)
  -- abscisse par la progression IA (pas p × longueur) : sur la Nordschleife, écart de 0,5 %
  T.eq(type(sAt(0.5)), 'number')
end

tests['R05 reconnaissance : circuit reconstruit depuis un tour enregistré'] = function()
  local e = env('spa')
  local rec = Recorder.new()
  e.keepPositions = true
  local laps = drive(e, 1, rec)
  e.keepPositions = nil
  local raw = Recorder.reconnaissance(laps[1], e.raw.lengthSim)
  T.ok(raw.ok)
  T.eq(raw.source, 'reconnaissance')
  local t = assert(TrackModel.build(raw, e.files, 2))
  T.ok(math.abs(t.length - e.track.length) / e.track.length < K.trackLengthTolSim, 'longueur ' .. t.length)
  T.no(t.hasWidth, 'largeur inconnue en reconnaissance')
  T.ok(t.confidence < 1, 'confiance abaissée')
  -- courbure : virages au même endroit que le modèle construit sur la ligne IA
  T.near(t.cornerCount, e.track.cornerCount, 3)
  T.ok(math.abs(t.minRadius - e.track.minRadius) < 0.2 * e.track.minRadius, 'épingle ' .. t.minRadius)
end

tests['R06 ligne de chronométrage décalée de l\'origine de la ligne IA'] = function()
  for _, meters in ipairs({ -10, -3, -1, 1, 3, 10 }) do
    local e = env('ks_red_bull_ring-layout_gp')
    e.profile.lineOffset = meters / e.h.track.total
    e.profile.startP = 0.5  -- départ à mi-tour : le premier passage de ligne est vu par l'enregistreur
    local rec = Recorder.new()
    local laps = drive(e, 3, rec)
    T.eq(#laps, 3, meters .. ' m')
    for _, lap in ipairs(laps) do
      T.ok(lap.valid, meters .. ' m : ' .. tostring(lap.reason))
      T.near(lap.time, e.simTime, 0.25, meters .. ' m : temps officiel')
    end
  end
end

tests['R07 setup illisible au passage de la ligne : tour rejeté, sans boucle d\'erreurs'] = function()
  local e = env('monza')
  local rec = Recorder.new()
  local laps = drive(e, 3, rec, nil, function() return nil end)
  T.eq(#laps, 3, 'un tour terminé par passage de ligne')
  T.eq(rec.finished, 3)
  for _, lap in ipairs(laps) do
    T.no(lap.valid)
    T.contains(lap.reason, 'setup illisible')
  end
  T.eq(next(rec.laps.best), nil, 'aucun meilleur tour sans signature')
end

tests['R08 compteur de tours remis à zéro ou sautant : aucun tour faux'] = function()
  local e = env('monza')
  local rec = Recorder.new()
  local jumped = false
  local laps = drive(e, 3, rec, function(_, h, r)
    -- en plein tour enregistré : redémarrage de séance (compteur à 0), puis saut de deux tours
    if r.state == 'enregistrement' and r.n == 1500 and not jumped then
      h.car.lapCount = 0
      jumped = true
    end
  end)
  T.ok(jumped)
  for _, lap in ipairs(laps) do
    T.ok(lap.valid or lap.reason ~= nil)
  end
  -- le tour interrompu n'est pas terminé à tort ; le tour suivant, complet, l'est
  local valid = 0
  for _, lap in ipairs(laps) do if lap.valid then valid = valid + 1 end end
  T.ok(valid >= 1, valid .. ' tours valides')
  local e2 = env('monza')
  local rec2 = Recorder.new()
  local skipped = false
  local laps2 = drive(e2, 2, rec2, function(_, h, r)
    if r.state == 'enregistrement' and r.n == 1500 and not skipped then
      h.car.lapCount = h.car.lapCount + 2
      skipped = true
    end
  end)
  for _, lap in ipairs(laps2) do T.ok(lap.n > 1500 or not lap.valid, 'tour coupé par le saut jamais valide') end
end

tests['R09 temps officiel : mise à jour tardive, temps faux, pause'] = function()
  -- previousLapTimeMs mis à jour 3 frames après le passage : temps juste quand même
  local e = env('monza')
  e.h.lateLapTimeFrames = 3
  local rec = Recorder.new()
  local laps = drive(e, 2, rec)
  T.eq(#laps, 2)
  for _, lap in ipairs(laps) do
    T.ok(lap.valid, tostring(lap.reason))
    T.near(lap.time, e.simTime, 0.25, 'temps du bon tour, pas du précédent')
  end
  T.near(laps[2].time - laps[1].time, 0, 0.05)
  -- temps officiel faux de 2 s : rejeté
  local e2 = env('monza')
  e2.h.lapTimeError = 2
  local rec2 = Recorder.new()
  local bad = drive(e2, 1, rec2)
  T.no(bad[1].valid)
  T.contains(bad[1].reason, 'temps officiel incohérent')
  -- pause de 10 s en plein tour : le chrono d'AC s'arrête, le tour reste valide
  local e3 = env('monza')
  local rec3 = Recorder.new()
  local paused = 0
  local laps3 = drive(e3, 1, rec3, function(_, h, r)
    if r.state == 'enregistrement' and r.n >= 1000 and paused < 600 then
      h.paused = true
      paused = paused + 1
    else
      h.paused = nil
    end
  end)
  T.eq(paused, 600)
  T.ok(laps3[1].valid, tostring(laps3[1].reason))
  T.near(laps3[1].time, e3.simTime, 0.25)
  T.near(laps3[1].n / laps3[1].time, K.recorderHz, 1.5, 'aucun échantillon pendant la pause')
  -- ordre du passage côté AC, inconnu : chrono remis à zéro une frame avant l'incrément du compteur,
  -- ou une frame après ; tours valides dans les deux cas
  for _, case in ipairs({ { 'lateLapCountFrames', 1 }, { 'lateTimerResetFrames', 1 }, { 'lateLapCountFrames', 2 } }) do
    local ec = env('monza')
    ec.h[case[1]] = case[2]
    local recc = Recorder.new()
    local lapsc = drive(ec, 2, recc)
    T.eq(#lapsc, 2, case[1])
    for _, lap in ipairs(lapsc) do
      T.ok(lap.valid, case[1] .. ' : ' .. tostring(lap.reason))
      T.near(lap.time, ec.simTime, 0.25, case[1])
    end
  end
  -- chrono remis à zéro avant l'incrément ET pause pendant le tour : seul le maximum du chrono d'AC
  -- recoupe le temps officiel (la frame d'avant vaut ≈ 0, la durée en temps de simulation compte la
  -- pause)
  local e4 = env('monza')
  e4.h.lateLapCountFrames = 1
  local rec4 = Recorder.new()
  local paused4 = 0
  local laps4 = drive(e4, 1, rec4, function(_, h, r)
    if r.state == 'enregistrement' and r.n >= 1000 and paused4 < 600 then
      h.paused = true
      paused4 = paused4 + 1
    else
      h.paused = nil
    end
  end)
  T.ok(laps4[1].valid, tostring(laps4[1].reason))
  T.near(laps4[1].time, e4.simTime, 0.25)
end

tests['R10 recul de la voiture (téléportation en arrière) : tour rejeté'] = function()
  local e = env('monza')
  local done = false
  local rec = Recorder.new()
  local laps = drive(e, 1, rec, function(_, h, r)
    if r.state == 'enregistrement' and r.n == 1500 and not done then
      h.driver.p = h.driver.p - 0.05
      done = true
    end
  end)
  T.no(laps[1].valid)
  T.contains(laps[1].reason, 'recul')
end

tests['R11 km virtuels par tour : mesurés pendant le tour, pas après un changement de pneus'] = function()
  local e = env('monza')
  local rec = Recorder.new()
  -- km virtuels cumulés d'un tour à l'autre (6 par tour), comme dans AC
  local laps = drive(e, 1, rec, function(_, h)
    for w = 0, 3 do h.car.wheels[w].tyreVirtualKM = 10 + (h.car.lapCount + (h.driver and h.driver.p or 0)) * 6 end
  end)
  T.near(laps[1].tyreKmDelta[1], 6, 0.05, 'km parcourus pendant le tour')
  -- pneus changés en plein tour (km qui repartent à zéro) : pas de mesure d'usure
  local e2 = env('monza')
  local rec2 = Recorder.new()
  local laps2 = drive(e2, 1, rec2, function(_, h, r)
    local p = h.driver and h.driver.p or 0
    local km = (r.state == 'enregistrement' and r.n > 1500) and p * 0.1 or 10 + (h.car.lapCount + p) * 6
    for w = 0, 3 do h.car.wheels[w].tyreVirtualKM = km end
  end)
  T.eq(laps2[1].tyreKmDelta[1], nil, 'changement de pneus : aucune mesure')
end

return tests
