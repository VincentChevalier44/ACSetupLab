-- Tests de src/car_model et src/laptime_sim (J3, §8.1 à §8.6, §14.2).
-- Les cas analytiques prouvent la cohérence interne du modèle, pas sa fidélité à AC : celle-ci
-- relève de la calibration en jeu (J5, §14.3).
local T = require('t')
local Util = require('src/util')
local Config = require('src/config')
local Datasource = require('src/datasource')
local TrackModel = require('src/track_model')
local CarModel = require('src/car_model')
local Sim = require('src/laptime_sim')
local Fake = require('fakehost')

local K = Config.K
local G = 9.80665
local SYNC = Util.syncContext()
local tests = {}

-- ---------------------------------------------------------------------------
-- Voiture et circuits synthétiques
-- ---------------------------------------------------------------------------

-- Pneu idéal : μ constant (sans sensibilité à la charge, carrossage, pression, température, usure).
local function tyre(mu)
  return {
    radius = 0.3, dyRef = mu, dxRef = mu, dcamber0 = 0, dcamber1 = 0, pressureDGain = 0, rr0 = 0, rr1 = 0,
    deformCamber = 0, pressureStatic = 26,
  }
end

-- opts : mu, torque (N·m constant) ou power (W constant), cd (traînée, m²), cgHeight, bias
local function syntheticCar(opts)
  local torque
  if opts.power then
    local xs, ys = {}, {}
    for rpm = 250, 20000, 250 do
      xs[#xs + 1], ys[#ys + 1] = rpm, opts.power / (rpm * 2 * math.pi / 60)
    end
    torque = Util.lutNew(xs, ys)
  else
    torque = Util.lutNew({ 0, 20000 }, { opts.torque or 400, opts.torque or 400 })
  end
  local wings = {}
  if opts.cd then
    wings[1] = { index = 0, name = 'BODY', area = 1, z = 0, cd = Util.lutNew({ -10, 10 }, { opts.cd, opts.cd }),
      clGain = 1, cdGain = 1, angle = 0 }
  end
  local base = CarModel.fromParams({
    massDry = 1000, cgFront = 0.5, wheelbase = 2.6, trackF = 1.6, trackR = 1.6, cgHeight = opts.cgHeight or 0.3,
    compounds = { { index = 0, name = 'test', front = tyre(opts.mu or 1.2), rear = tyre(opts.mu or 1.2) } },
    torque = torque, limiter = 20000, rpmMin = 250, gears = { 1 }, final = 4, shiftUpTime = 0,
    brakeFront = opts.bias or 0.6, fuelDefault = 0, wings = wings,
  })
  local setup = CarModel.defaultSetup(base)
  return base, setup
end

local function configure(base, setup, conditions)
  local eff, why = CarModel.configure(base, setup, conditions or { airTemp = 20 })
  assert(eff, why)
  return eff
end

-- Ligne synthétique : liste de points { x, y, z } (largeurs 6 m), dévers bankN facultatif.
local function rawFrom(points, open, bank)
  local raw = { ok = true, n = #points, x = {}, y = {}, z = {}, left = {}, right = {}, open = open, failures = 0 }
  if bank then raw.bankN = {} end
  for i, p in ipairs(points) do
    raw.x[i], raw.y[i], raw.z[i], raw.left[i], raw.right[i] = p[1], p[2], p[3], 6, 6
    if bank then raw.bankN[i] = bank end
  end
  return raw
end

local function circle(radius, step)
  local pts, n = {}, math.floor(2 * math.pi * radius / step)
  for i = 0, n - 1 do
    local a = 2 * math.pi * i / n
    pts[#pts + 1] = { radius * math.sin(a), 0, radius * (1 - math.cos(a)) }
  end
  return pts
end

-- Ligne droite de longueur L suivie (facultatif) d'un arc de rayon R sur une longueur arc.
local function straightThenArc(L, R, arc)
  local pts, x, z, heading = {}, 0, 0, 0
  for _ = 1, L do
    x = x + 1
    pts[#pts + 1] = { x, 0, z }
  end
  for _ = 1, arc or 0 do
    heading = heading + 1 / R
    x, z = x + math.cos(heading), z + math.sin(heading)
    pts[#pts + 1] = { x, 0, z }
  end
  return pts
end

-- ---------------------------------------------------------------------------
-- Voitures et circuits réels
-- ---------------------------------------------------------------------------

local cache = {}
local function real(carId, trackId)
  local key = carId .. '@' .. trackId
  if cache[key] then return cache[key] end
  local h = Fake.new({ car = require('fixtures/cars/' .. carId), track = require('fixtures/tracks/' .. trackId) })
  local raw = Datasource.sampleTrack(h, 1, SYNC)
  Datasource.probeBank(h, raw, SYNC)
  local track = assert(TrackModel.build(raw, Datasource.readTrackFiles(h, SYNC), 2))
  local base, missing = CarModel.build(Datasource.readCar(h, 0, SYNC), nil)
  local entry = { h = h, track = track, base = base, missing = missing, buf = Sim.new(track) }
  function entry.lap(mod, conditions)
    local setup = CarModel.defaultSetup(base)
    if mod then mod(setup) end
    local eff = configure(base, setup, conditions or { airTemp = 25 })
    local result = Sim.run(track, eff, entry.buf)
    return result, eff
  end
  cache[key] = entry
  return entry
end

-- ---------------------------------------------------------------------------
-- Cas analytiques (§14.2)
-- ---------------------------------------------------------------------------

tests['S01 virage à rayon constant sans appui : v = √(μ·g·R)'] = function()
  for _, case in ipairs({ { 1.2, 100 }, { 0.9, 90 }, { 1.6, 250 } }) do
    local mu, R = case[1], case[2]
    local base, setup = syntheticCar({ mu = mu })
    local track = assert(TrackModel.build(rawFrom(circle(R, 1)), nil, 2))
    local result, buf = Sim.run(track, configure(base, setup), nil)
    local expected = math.sqrt(mu * G * R)
    for k = 1, track.n, 17 do T.near(buf.v[k], expected, expected * 0.002, 'vitesse en virage') end
    T.near(result.time, track.length / expected, track.length / expected * 0.003, 'temps au tour')
    T.eq(result.shifts, 0)
  end
end

tests['S02 dévers vers l\'intérieur et vers l\'extérieur : v² = gR(μ + tan φ) / (1 − μ·tan φ)'] = function()
  local mu, R, phi = 1.2, 100, 0.15
  local base, setup = syntheticCar({ mu = mu })
  local eff = configure(base, setup)
  local flat = assert(TrackModel.build(rawFrom(circle(R, 1)), nil, 2))
  local sign = flat.kappa[1] > 0 and 1 or -1
  local speeds = {}
  for _, inward in ipairs({ phi, -phi }) do
    local track = assert(TrackModel.build(rawFrom(circle(R, 1), false, inward * sign), nil, 2))
    T.near(track.phi[10] * (track.kappa[10] > 0 and 1 or -1), inward, 1e-9, 'convention du dévers intérieur')
    local _, buf = Sim.run(track, eff, nil)
    local t = math.tan(inward)
    local expected = math.sqrt(G * R * (mu + t) / (1 - mu * t))
    T.near(buf.v[25], expected, expected * 0.003, 'dévers ' .. inward)
    speeds[#speeds + 1] = buf.v[25]
  end
  local _, flatBuf = Sim.run(flat, eff, nil)
  T.ok(speeds[1] > flatBuf.v[25] and flatBuf.v[25] > speeds[2], 'intérieur > plat > extérieur')
end

tests['S03 vitesse de pointe limitée par la traînée'] = function()
  -- couple constant : F = T·rapport·η/R = ½ρ·Cx·A·v²
  local base, setup = syntheticCar({ torque = 400, cd = 0.8 })
  local eff = configure(base, setup, { airTemp = 20 })
  local rho = 101325 / (287.05 * 293.15)
  local force = 400 * 4 * K.drivetrainEfficiency / 0.3
  local expected = math.sqrt(2 * force / (rho * 0.8))
  T.near(eff.topSpeed, expected, expected * 0.003, 'couple constant')
  -- puissance constante : P·η = ½ρ·Cx·A·v³
  local baseP, setupP = syntheticCar({ power = 300000, cd = 0.8 })
  local effP = configure(baseP, setupP, { airTemp = 20 })
  local expectedP = (2 * 300000 * K.drivetrainEfficiency / (rho * 0.8)) ^ (1 / 3)
  T.near(effP.topSpeed, expectedP, expectedP * 0.005, 'puissance constante')
  -- sur une longue ligne droite, la simulation s'en approche sans la dépasser
  local track = assert(TrackModel.build(rawFrom(straightThenArc(8000), true), nil, 2))
  local result = Sim.run(track, effP, nil, { startSpeed = 0 })
  T.ok(result.vMax <= effP.topSpeed + 1e-6)
  T.ok(result.vMax > 0.97 * effP.topSpeed, 'vitesse atteinte ' .. result.vMax)
  -- l'air chaud est moins dense : vitesse de pointe plus élevée
  T.ok(configure(baseP, setupP, { airTemp = 40 }).topSpeed > effP.topSpeed)
end

tests['S04 freinage à décélération limite : d = (v1² − v2²) / (2·μ·g)'] = function()
  local mu, R, h = 1.2, 50, 0.3
  local bias = 0.5 + mu * h / 2.6   -- répartition idéale : les deux essieux saturent ensemble
  local base, setup = syntheticCar({ mu = mu, cgHeight = h, bias = bias })
  local track = assert(TrackModel.build(rawFrom(straightThenArc(1500, R, 120), true), nil, 2))
  local result, buf = Sim.run(track, configure(base, setup), nil, { startSpeed = 0 })
  T.near(result.rearFirstShare, 0, 0.05)
  local vArc = math.sqrt(mu * G * R)
  local arcStart = TrackModel.indexAt(track, 1500)
  for _, d in ipairs({ 100, 200, 400 }) do
    local k = TrackModel.indexAt(track, 1500 - d)
    local expected = math.sqrt(vArc * vArc + 2 * mu * G * d)
    T.near(buf.vb[k], expected, expected * 0.02, 'freinage sur ' .. d .. ' m')
  end
  T.near(buf.v[arcStart + 30], vArc, vArc * 0.01)
  -- répartition trop arrière : l'arrière sature d'abord, décélération moindre, signalé
  local baseR, setupR = syntheticCar({ mu = mu, cgHeight = h, bias = 0.4 })
  local resultR, bufR = Sim.run(track, configure(baseR, setupR), nil, { startSpeed = 0 })
  T.ok(resultR.rearFirstShare > 0.9, 'blocage arrière signalé')
  local k = TrackModel.indexAt(track, 1300)
  T.ok(bufR.vb[k] < buf.vb[k], 'freinage plus long')
  -- freinage limité par le couple : ce n'est pas un blocage arrière (constat mineur de la relecture J3)
  local baseT, setupT = syntheticCar({ mu = mu, cgHeight = h, bias = 0.4 })
  baseT.brakeTorque = 300
  local resultT = Sim.run(track, configure(baseT, setupT), nil, { startSpeed = 0 })
  T.near(resultT.rearFirstShare, 0, 1e-9, 'couple limitant : aucun blocage compté')
end

tests['S05 raccord de fin de tour et continuité du profil'] = function()
  for _, id in ipairs({ 'spa', 'monza' }) do
    local r = real('lamborghini_huracan_gt3_evo2', id)
    local result = r.lap()
    local v, N = r.buf.v, r.track.n
    local worst = 0
    for k = 1, N - 1 do worst = math.max(worst, math.abs(v[k + 1] - v[k])) end
    T.ok(math.abs(v[1] - v[N]) <= worst + 1e-9, id .. ' : saut au raccord ' .. math.abs(v[1] - v[N]))
    T.ok(worst < 1.5, id .. ' : saut maximal ' .. worst .. ' m/s entre deux points')
    T.near(r.buf.vf[result.kMin], r.buf.vLim[result.kMin], 1e-9, 'départ au minimum de v_lim')
    for k = 1, N do
      T.ok(v[k] <= r.buf.vLim[k] + 1e-9 and v[k] > 0, 'v ≤ v_lim')
    end
  end
end

-- ---------------------------------------------------------------------------
-- Voitures réelles
-- ---------------------------------------------------------------------------

tests['S06 voitures réelles : grandeurs plausibles (non calibrées)'] = function()
  -- Bornes larges : le modèle non calibré n'est pas fidèle (§1.4) ; ces bornes attrapent les erreurs
  -- d'unité et de signe, pas l'imprécision.
  local cases = {
    { 'lamborghini_huracan_gt3_evo2', 'spa', 130, 160 }, { 'lamborghini_huracan_gt3_evo2', 'monza', 100, 125 },
    { 'formula_k', 'spa', 125, 165 }, { 'urd_px1_aura', 'spa', 110, 140 }, { 'whk_dtm_2026', 'monza', 95, 120 },
  }
  for _, case in ipairs(cases) do
    local r = real(case[1], case[2])
    T.eq(#r.missing, 0, case[1] .. ' : paramètres manquants ' .. table.concat(r.missing, ','))
    local result, eff = r.lap()
    local name = case[1] .. ' @ ' .. case[2]
    T.ok(result.time > case[3] and result.time < case[4], name .. ' : ' .. result.time .. ' s')
    T.ok(result.vMax <= eff.topSpeed + 1e-6, name .. ' : vitesse de pointe')
    T.ok(result.vMin * 3.6 > 45 and result.vMin * 3.6 < 90, name .. ' : vitesse mini ' .. result.vMin * 3.6)
    T.ok(result.shifts >= r.track.cornerCount * 0.5 and result.shifts <= r.track.cornerCount * 4,
      name .. ' : ' .. result.shifts .. ' montées de rapport')
    T.ok(result.fuel and result.fuel > 0.3 and result.fuel < 6, name .. ' : carburant ' .. tostring(result.fuel) .. ' L')
    local g0 = eff.ay[K.normalLoadNominal][1] / G
    T.ok(g0 > 1.0 and g0 < 2.5, name .. ' : adhérence latérale mécanique ' .. g0 .. ' g')
    T.ok(eff.brake[K.normalLoadNominal][1] / G > 1.0, name .. ' : freinage')
  end
end

tests['S07 minima de vitesse aux virages lents de la ligne IA'] = function()
  -- La vitesse enregistrée dans fast_lane.ai vient d'un tour lent et inconnu : seules les positions des
  -- ralentissements dans les virages serrés sont comparables.
  for _, case in ipairs({ { 'lamborghini_huracan_gt3_evo2', 'spa' }, { 'formula_k', 'monza' },
    { 'urd_px1_aura', 'ks_red_bull_ring-layout_gp' } }) do
    local r = real(case[1], case[2])
    local result = r.lap()
    TrackModel.annotate(r.track, r.buf)
    local pts, track = r.h.track.pts, r.track
    local function aiSpeedAt(s)
      local k = TrackModel.indexAt(track, s)
      local sr = track.p[k] * r.h.track.total
      local lo, hi = 1, #pts
      while hi - lo > 1 do
        local mid = math.floor((lo + hi) / 2)
        if pts[mid][4] <= sr then lo = mid else hi = mid end
      end
      return pts[lo][7]
    end
    local checked = 0
    for _, seg in ipairs(track.segments) do
      if seg.kind == 'corner' and seg.radius <= 50 and seg.vApex < 0.6 * result.vMax then
        local sSim = track.s[seg.apexSim]
        local best, bestD = math.huge, nil
        for d = -150, 150, 2 do
          local value = aiSpeedAt((sSim + d) % track.length)
          if value < best then best, bestD = value, d end
        end
        T.ok(math.abs(bestD) <= 45, case[2] .. ' : virage s = ' .. sSim .. ', minimum IA à ' .. bestD .. ' m')
        checked = checked + 1
      end
    end
    T.ok(checked >= 3, case[2] .. ' : ' .. checked .. ' virages lents comparés')
  end
end

tests['S08 sensibilités : sens physique des réglages'] = function()
  local r = real('lamborghini_huracan_gt3_evo2', 'spa')
  local base = r.base
  local ref, effRef = r.lap()
  -- aileron arrière : plus d'appui et de traînée, vitesse de pointe plus basse
  local rear
  for _, w in ipairs(base.wings) do
    if w.cl and w.name:upper():find('REAR') then rear = w end
  end
  T.ok(rear, 'aileron arrière identifié')
  local _, effWing = r.lap(function(s) s.wingAngles[rear.index] = rear.angle + 4 end)
  local i200 = math.floor(200 / 3.6 / effRef.dv) + 1
  T.ok(effWing.lift[i200] > effRef.lift[i200] and effWing.drag[i200] > effRef.drag[i200], 'aileron : appui et traînée')
  T.ok(effWing.topSpeed < effRef.topSpeed, 'aileron : vitesse de pointe')
  -- carburant : plus lourd, plus lent
  T.ok(r.lap(function(s) s.fuel = s.fuel + 40 end).time > ref.time + 0.2, 'carburant')
  -- répartition de freinage : optimum intérieur, blocage arrière signalé en dessous
  local times, shares = {}, {}
  for i, bias in ipairs({ 0.5, 0.6, 0.7 }) do
    local result = r.lap(function(s) s.brakeBias = bias end)
    times[i], shares[i] = result.time, result.rearFirstShare
  end
  T.ok(times[2] < times[1] and times[2] < times[3], 'répartition : optimum intérieur')
  T.ok(shares[1] > 0.3 and shares[3] < 0.05, 'blocage arrière à 50 % (' .. shares[1] .. '), pas à 70 %')
  -- pression : optimum à la pression à froid qui donne la pression idéale à chaud
  local c = base.compounds[CarModel.defaultSetup(base).compound]
  local ideal = CarModel.coldPressureFor(c.front.pressureIdeal, 25, CarModel.operatingTemp(c.front))
  local function withPressure(p)
    return r.lap(function(s) s.pressureF, s.pressureR = p, p end).time
  end
  local best = withPressure(ideal)
  T.ok(best < withPressure(ideal - 2) and best < withPressure(ideal + 2), 'pression : optimum au centre')
  T.near(CarModel.hotPressure(ideal, 25, CarModel.operatingTemp(c.front)), c.front.pressureIdeal, 1e-9)
  -- carrossage : l'effet ne s'inverse pas au-delà du sommet de la parabole Kunos
  local times6 = r.lap(function(s) s.camberF = -6 end).time
  local times45 = r.lap(function(s) s.camberF = -4.5 end).time
  T.ok(times6 >= times45 - 1e-6, 'carrossage extrême jamais récompensé')
  -- barre avant : la voiture sous-vire (E < 1) ; assouplir l'avant rapproche E de 1
  local soft = r.lap(function(s) s.arbF = s.arbF * 0.5 end)
  T.ok(ref.balanceMean < 1 and soft.balanceMean > ref.balanceMean, 'barre avant et équilibre')
  -- facteurs de calibration : adhérence et puissance en plus, plus rapide
  local factors = CarModel.defaultFactors()
  factors.mu = 1.05
  T.ok(r.lap(nil, { airTemp = 25, factors = factors }).time < ref.time - 1, 'facteur d\'adhérence')
end

tests['S09 coût, allocations et découpage (§8.8, D6)'] = function()
  local r = real('lamborghini_huracan_gt3_evo2', 'spa')
  local setup = CarModel.defaultSetup(r.base)
  for _ = 1, 5 do Sim.run(r.track, configure(r.base, setup), r.buf) end
  local started = PY.clock()
  for _ = 1, 20 do Sim.run(r.track, configure(r.base, setup), r.buf) end
  local ms = (PY.clock() - started) * 1000 / 20
  PY.note('S09', string.format('configuration + tour à Spa (%d points) : %.2f ms', r.track.n, ms))
  T.ok(ms < 8, 'évaluation complète ' .. ms .. ' ms (§8.8 : < 25 ms)')
  local eff = configure(r.base, setup)
  -- meilleure de 3 séries (méthode A16) : dans le banc complet, une trace JIT recompilée en cours de
  -- série alloue une fois ; le régime établi, lui, ne doit rien allouer
  local kb = math.huge
  for _ = 1, 3 do
    collectgarbage('collect')
    collectgarbage('stop')
    local before = collectgarbage('count')
    for _ = 1, 20 do Sim.run(r.track, eff, r.buf) end
    kb = math.min(kb, (collectgarbage('count') - before) / 20)
    collectgarbage('restart')
  end
  T.ok(kb < 2, 'tampons réutilisés : ' .. kb .. ' Ko alloués par tour simulé')
  -- configure réutilise ses tables (optimiseur : des milliers d'appels, A16)
  -- (régime établi : la compilation JIT des premiers appels alloue, puis plus rien ; meilleure de 3 séries)
  local reuse = configure(r.base, setup)
  local conditions = { airTemp = 25 }
  local function allocated()
    local best = math.huge
    for _ = 1, 3 do
      collectgarbage('collect')
      collectgarbage('stop')
      local beforeCfg = collectgarbage('count')
      for _ = 1, 20 do CarModel.configure(r.base, setup, conditions, nil, reuse) end
      best = math.min(best, (collectgarbage('count') - beforeCfg) / 20)
      collectgarbage('restart')
    end
    return best
  end
  -- interpréteur (aucune trace compilée) : ce que le code alloue vraiment par appel, sans dépendre des
  -- choix du compilateur
  CarModel.configure(r.base, setup, conditions, nil, reuse)
  jit.off()
  local kbInterp = allocated()
  jit.on()
  T.ok(kbInterp < 0.1, 'configuration sans allocation (interpréteur) : ' .. kbInterp .. ' Ko par appel')
  -- pas de mesure avec le JIT : il ne fait qu'éliminer des allocations, et ses traces compilées sont des
  -- objets du tas dont la compilation se poursuit au gré de l'exécution (échec rare au banc complet du
  -- 20/10/2026 : 1,67 Ko par appel, tout en traces)
  local fresh = configure(r.base, setup, conditions)
  T.near(reuse.topSpeed, fresh.topSpeed, 1e-9, 'réutilisation sans effet sur le résultat')
  T.near(Sim.run(r.track, reuse, r.buf).time, Sim.run(r.track, fresh, r.buf).time, 1e-9)
  local ticks = 0
  Sim.run(r.track, eff, r.buf, { tick = function() ticks = ticks + 1 end })
  T.ok(ticks >= 3 * math.floor(r.track.n / K.simTickPoints), 'simulation découpée : ' .. ticks .. ' rendus')
  local configTicks = 0
  CarModel.configure(r.base, setup, { airTemp = 25 }, function() configTicks = configTicks + 1 end)
  T.ok(configTicks >= 5, 'configuration découpée : ' .. configTicks .. ' rendus')
end

tests['S11 transmission, turbo, hauteur minimale (voitures réelles)'] = function()
  -- formula_k : AWD, FRONT_SHARE=35 écrit en %, turbo réglable du cockpit à 0,7 (H5)
  local fk = real('formula_k', 'spa')
  T.eq(fk.base.traction, 'AWD')
  T.near(fk.base.awdFrontShare, 0.35, 1e-12, 'FRONT_SHARE en % converti')
  T.near(fk.base.diff.power, 0.40, 1e-12, 'différentiel arrière de [AWD]')
  T.near(fk.base.turbos[1].boost, 1.8 * 0.7, 1e-12, 'WASTEGATE × DEFAULT_TURBO_ADJUSTMENT')
  local _, effFk = fk.lap()
  T.ok(effFk.tractionCap[K.normalLoadNominal][26] / G > 1.3, 'motricité AWD à 50 m/s')
  -- BASEY (Kunos : « Wheel Radius + BASEY = CoG ») : CG sous l'axe de roue pour BASEY < 0
  T.ok(fk.base.cgHeight < fk.base.compounds[1].front.radius, 'h_cg = R + BASEY')
  -- aucune voiture de test sous sa hauteur minimale réglementaire avec le setup par défaut
  for _, id in ipairs({ 'formula_k', 'lamborghini_huracan_gt3_evo2', 'whk_dtm_2026', 'urd_px1_aura' }) do
    local r = real(id, 'spa')
    local _, eff = r.lap()
    T.no(eff.belowMinHeight, id .. ' : hauteur par défaut ≥ MIN_HEIGHT')
  end
  -- traction avant synthétique : la motricité suit l'essieu avant
  local base, setup = syntheticCar({})
  base.traction = 'FWD'
  local fwd = configure(base, setup)
  base.traction = 'RWD'
  local rwd = configure(base, setup)
  T.ok(fwd.tractionCap[2][10] < rwd.tractionCap[2][10], 'en accélération, la charge passe à l\'arrière')
end

tests['S12 décollement de roue et renversement'] = function()
  -- CG très haut sur voies étroites : sans appui, ay ≤ g·t / (2h) (renversement statique)
  local base, setup = syntheticCar({ mu = 2.0, cgHeight = 1.2 })
  local eff = configure(base, setup)
  local rollover = G * 1.6 / (2 * 1.2)
  T.ok(eff.ay[K.normalLoadNominal][1] <= rollover * 1.001, 'renversement : ' .. eff.ay[K.normalLoadNominal][1])
  -- toute la raideur au roulis à l'avant, μ constant : la roue intérieure avant décolle ; l'essieu ne
  -- peut pas porter plus que sa charge, donc ay ≤ μ·g (sans borne, la roue extérieure porterait plus)
  -- transferts : borne au décollement, moment conservé, renversement au-delà
  local e = { mass = 1000, cgHeight = 0.6, rollShareF = 0.95, trackF = 1.6, trackR = 1.5 }
  local FzF, FzR = 4900, 4900
  for _, ay in ipairs({ 2, 6, 10, 12.5 }) do
    local dF, dR = CarModel.lateralTransfers(e, ay, FzF, FzR)
    T.ok(dF <= FzF / 2 + 1e-9 and dR <= FzR / 2 + 1e-9, 'aucune roue ne porte plus que son essieu (ay ' .. ay .. ')')
    T.near(dF * 1.6 + dR * 1.5, 1000 * ay * 0.6, 1e-6, 'moment de roulis conservé')
  end
  -- l'avant (95 % de la raideur) décolle au-delà de 3 920 / (0,95 × 600) ≈ 6,9 m/s² ; renversement au-delà
  -- de (3 920 + 3 675) / 600 ≈ 12,7 m/s²
  T.ok(CarModel.lateralTransfers(e, 6, FzF, FzR) < FzF / 2, 'pas encore de décollement à 6 m/s²')
  T.near(CarModel.lateralTransfers(e, 10, FzF, FzR), FzF / 2, 1e-9, 'avant décollé à 10 m/s²')
  T.eq(CarModel.lateralTransfers(e, 13, FzF, FzR), nil, 'renversement')
  local baseL, setupL = syntheticCar({ mu = 1.2, cgHeight = 0.6 })
  setupL.arbF, setupL.arbR, setupL.springF, setupL.springR = 1e8, 0, 20000, 20000
  local effL = configure(baseL, setupL)
  T.ok(effL.ay[K.normalLoadNominal][1] <= 1.2 * G * 1.001, 'décollement : ' .. effL.ay[K.normalLoadNominal][1] / G .. ' g')
  T.ok(effL.ay[K.normalLoadNominal][1] >= 1.2 * G * 0.9, 'l\'arrière reprend le moment en excès')
  -- barre antiroulis avant de la DTM sur toute sa plage : pas d'inversion du temps (constat M1)
  local r = real('whk_dtm_2026', 'spa')
  local times = {}
  for i, arb in ipairs({ 20000, 46000, 72000, 98000, 124000, 150000 }) do
    times[i] = r.lap(function(s) s.arbF = arb end).time
  end
  local changes = 0
  for i = 3, #times do
    if (times[i] - times[i - 1]) * (times[i - 1] - times[i - 2]) < -1e-6 then changes = changes + 1 end
  end
  T.ok(changes <= 1, 'barre avant : ' .. changes .. ' inversions (' .. table.concat(times, ' ; ') .. ')')
end

tests['S13 rapport final : temps régulier (pas de dents de scie)'] = function()
  local r = real('lamborghini_huracan_gt3_evo2', 'spa')
  local base = r.base
  local times = {}
  for i = -20, 20 do
    times[#times + 1] = r.lap(function(s) s.final = base.final * (1 + i * 0.005) end).time
  end
  -- tendance quadratique (moindres carrés) ; les ondulations résiduelles viennent du nombre entier de
  -- passages de rapport (effet réel, sous le seuil de départage de §10.4)
  local n, sx, sx2, sx3, sx4, sy, sxy, sx2y = #times, 0, 0, 0, 0, 0, 0, 0
  for i, y in ipairs(times) do
    local x = i - 21
    sx, sx2, sx3, sx4 = sx + x, sx2 + x * x, sx3 + x ^ 3, sx4 + x ^ 4
    sy, sxy, sx2y = sy + y, sxy + x * y, sx2y + x * x * y
  end
  -- résolution du système normal 3×3 (Cramer)
  local function det(a, b, c, d, e, f, g, h, k) return a * (e * k - f * h) - b * (d * k - f * g) + c * (d * h - e * g) end
  local D = det(n, sx, sx2, sx, sx2, sx3, sx2, sx3, sx4)
  local c0 = det(sy, sx, sx2, sxy, sx2, sx3, sx2y, sx3, sx4) / D
  local c1 = det(n, sy, sx2, sx, sxy, sx3, sx2, sx2y, sx4) / D
  local c2 = det(n, sx, sy, sx, sx2, sxy, sx2, sx3, sx2y) / D
  local residual, worst = 0, 0
  for i, y in ipairs(times) do
    local x = i - 21
    residual = math.max(residual, math.abs(y - (c0 + c1 * x + c2 * x * x)))
    if i > 1 then worst = math.max(worst, math.abs(y - times[i - 1])) end
  end
  PY.note('S13', string.format('écart maximal à la tendance %.3f s, saut maximal %.3f s', residual, worst))
  T.ok(residual < 0.05, 'ondulation ' .. residual .. ' s autour de la tendance')
  T.ok(worst < 0.05, 'saut maximal ' .. worst .. ' s pour 0,5 % de rapport')
end

tests['S10 données absurdes : refus motivé ou résultat fini'] = function()
  local base, setup = syntheticCar({})
  local noTyres = CarModel.fromParams({ compounds = {}, torque = base.torque, gears = { 1 } })
  local eff, why = CarModel.configure(noTyres, CarModel.defaultSetup(noTyres), {})
  T.eq(eff, nil)
  T.contains(why, 'pneus')
  local noEngine = CarModel.fromParams({ compounds = base.compounds, gears = { 1 } })
  eff, why = CarModel.configure(noEngine, CarModel.defaultSetup(noEngine), {})
  T.eq(eff, nil)
  T.contains(why, 'moteur')
  -- valeurs extrêmes mais finies : la simulation reste finie
  local track = assert(TrackModel.build(rawFrom(circle(80, 1)), nil, 2))
  local rng = Util.rngNew(20261019)
  for _ = 1, 40 do
    local t = tyre(Util.rngRange(rng, 0.3, 4))
    t.fz0 = Util.rngRange(rng, 1, 20000)
    t.lsExpY = Util.rngRange(rng, 0.1, 1.5)
    t.dcamber0 = Util.rngRange(rng, -5, 5)
    t.dcamber1 = Util.rngRange(rng, -50, 50)
    local p = CarModel.fromParams({
      massDry = Util.rngRange(rng, 300, 3000), cgHeight = Util.rngRange(rng, 0, 1.5), cgFront = Util.rngRange(rng, 0, 1),
      compounds = { { index = 0, name = 'x', front = t, rear = t } }, torque = base.torque, gears = { Util.rngRange(rng, 0.5, 5) },
      final = Util.rngRange(rng, 1, 8), springF = Util.rngRange(rng, 0, 1e6), arbF = Util.rngRange(rng, 0, 1e6),
    })
    local s = CarModel.defaultSetup(p)
    s.camberF, s.brakeBias, s.fuel = Util.rngRange(rng, -10, 10), Util.rngRange(rng, -1, 2), Util.rngRange(rng, -50, 200)
    local e = CarModel.configure(p, s, { airTemp = Util.rngRange(rng, -20, 60) })
    if e then
      local result, buf = Sim.run(track, e, nil)
      T.ok(Util.isFinite(result.time) and result.time > 0, 'temps fini')
      for k = 1, track.n, 50 do T.ok(Util.isFinite(buf.v[k]), 'vitesse finie') end
    end
  end
  T.ok(setup.fuel == 0)
end

tests['S14 accélération latérale maximale : tenable, à la tolérance près, quel que soit le départ'] = function()
  local rng = Util.rngNew(99)
  local checked, worst = 0, 0
  for _, id in ipairs({ 'formula_k', 'lamborghini_huracan_gt3_evo2', 'urd_px1_aura', 'whk_dtm_2026' }) do
    local w = real(id, 'monza')
    local s = CarModel.defaultSetup(w.base)
    local eff = assert(CarModel.configure(w.base, s, { airTemp = 25, roadGrip = 0.98 }))
    for _ = 1, 150 do
      local n = 0.3 + 2.2 * Util.rngNext(rng)
      local v = Util.rngNext(rng) * eff.topSpeed
      local i = math.floor(v / eff.dv) + 1
      local FzF = eff.mass * G * n * eff.b / eff.wheelbase + math.max(0, eff.liftFront[i])
      local FzR = eff.mass * G * n * eff.a / eff.wheelbase + math.max(0, eff.lift[i] - eff.liftFront[i])
      -- référence : dichotomie fine (48 pas)
      local lo, hi = 0, K.ayMaxG * G
      for _ = 1, 48 do
        local mid = 0.5 * (lo + hi)
        local g = CarModel.lateralMargin(eff, mid, FzF, FzR)
        if g and g >= 0 then lo = mid else hi = mid end
      end
      -- sans départ (false), départs bas, proches, hauts
      for _, guess in ipairs({ false, 0, lo * 0.5, lo * 0.999, lo * 1.001, lo * 2, K.ayMaxG * G }) do
        local ay = CarModel.solveLateral(eff, FzF, FzR, guess or nil)
        local g = CarModel.lateralMargin(eff, ay, FzF, FzR)
        T.ok(g and g >= 0, id .. ' : valeur tenable')
        T.ok(ay <= lo + 1e-9 and lo - ay <= K.lateralTolerance + 1e-9, id .. ' : ' .. ay .. ' contre ' .. lo)
        worst = math.max(worst, lo - ay)
        checked = checked + 1
      end
    end
  end
  PY.note('S14', string.format('%d résolutions, écart maximal à la limite %.5f m/s² (tolérance %.4f)', checked, worst,
    Config.K.lateralTolerance))
end

tests['S15 tables exactes jusqu\'à la plus haute vitesse simulée (volet ouvert compris)'] = function()
  local worst = math.huge
  for _, id in ipairs({ 'formula_k', 'lamborghini_huracan_gt3_evo2', 'urd_px1_aura', 'whk_dtm_2026' }) do
    for _, trackId in ipairs({ 'monza', 'spa' }) do
      local w = real(id, trackId)
      for _, drs in ipairs({ false, true }) do
        local s = CarModel.defaultSetup(w.base)
        local eff = assert(CarModel.configure(w.base, s, { airTemp = 25, roadGrip = 0.98, drs = drs }))
        local r = Sim.run(w.track, eff, w.buf, {})
        -- lecture interpolée entre les lignes i et i + 1 : la plus haute vitesse doit rester sous la ligne
        -- exacte la plus haute
        local margin = (eff.tableReach - 1) * eff.dv - math.max(r.vMax, r.vTopOpen or 0)
        worst = math.min(worst, margin)
        T.ok(margin >= 0, id .. ' / ' .. trackId .. ' DRS ' .. tostring(drs) .. ' : ' .. margin)
      end
    end
  end
  PY.note('S15', string.format('marge minimale entre la plus haute vitesse simulée et la dernière ligne exacte : %.2f m/s', worst))
end

return tests
