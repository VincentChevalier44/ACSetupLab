-- SetupLab — simulation de tour quasi statique (§8.2). Noyau pur (D5).
--
-- Entrées : modèle du circuit (track_model) et voiture configurée (car_model.configure).
-- 1. v_lim(s) : plus grande vitesse telle que l'accélération latérale requise, corrigée du dévers,
--    tienne dans la capacité des pneus à la charge normale du point (pente, dévers, compression) ;
--    bornée par la vitesse de pointe (traînée).
-- 2. Passe arrière : freinage jusqu'à v_lim, adhérence restante d'après l'ellipse d'adhérence,
--    répartition de freinage (tables de car_model), traînée, roulement, pente.
-- 3. Passe avant : force motrice au rapport optimal, motricité de l'essieu moteur (roue intérieure
--    limitée selon le blocage du différentiel), coupure de couple à chaque montée de rapport ; en
--    virage, le différentiel bloqué crée un moment de lacet sous-vireur que l'avant doit compenser avec
--    sa marge latérale (H20).
-- 4. v = min(avant, arrière) ; temps = Σ ds / v moyen.
-- DRS (§8.9, voiture configurée avec conditions.drs) : dans les zones du circuit, la vitesse limite est
-- la plus grande des deux états du volet (ouvert : moins d'appui, moins de traînée, vitesse de pointe
-- plus haute) ; le volet n'est ouvert qu'en accélération (passe avant), à une vitesse que l'adhérence
-- volet ouvert permet, et sous LIMIT_G s'il est donné (H9) ; il est fermé au freinage. Approximation :
-- volet ouvert, la marge d'adhérence combinée et la motricité restent celles du volet fermé (zones en
-- ligne droite, appui faible à basse vitesse).
-- Circuit fermé : les passes partent du minimum global de v_lim (raccord de fin de tour exact).
-- Les tampons sont réutilisés d'une évaluation à l'autre (aucune allocation par point).

local Config = require('src/config')
local K = Config.K

local M = {}

local floor, sqrt, abs, min, max, cos, sin = math.floor, math.sqrt, math.abs, math.min, math.max, math.cos, math.sin
local G = 9.80665

-- Codes du facteur limitant, par point.
M.LIMIT = { corner = 1, brake = 2, traction = 3, power = 4, shift = 5 }

-- Tampons d'une simulation pour un circuit donné : profils réutilisés d'une évaluation à l'autre et
-- géométrie précalculée une fois (courbure absolue, dévers vers l'intérieur, trigonométrie).
function M.new(track)
  local n = track.n
  local s = { n = n, track = track }
  for _, name in ipairs({ 'vLim', 'vf', 'vb', 'v', 'limit', 'nLoad', 'ayReq', 'powerLimited', 'shifting',
    'kap', 'cphi', 'sphi', 'cth', 'sth', 'kv', 'drsZone', 'vOpen', 'drsOpen', 'balance' }) do
    local list = {}
    for k = 1, n do list[k] = 0 end
    s[name] = list
  end
  for k = 1, n do
    local kap, phiIn = track.kappa[k], track.phi[k]
    if kap < 0 then phiIn = -phiIn end
    s.kap[k] = abs(kap)
    s.cphi[k], s.sphi[k] = cos(phiIn), sin(phiIn)
    s.cth[k], s.sth[k] = cos(track.theta[k]), sin(track.theta[k])
    s.kv[k] = track.kappaV[k]
  end
  -- zones DRS (abscisses de début et longueur ; une zone peut chevaucher la ligne)
  s.drsZoneCount = 0
  for _, z in ipairs(track.drsZones or {}) do
    if z.length > 0 then
      s.drsZoneCount = s.drsZoneCount + 1
      for k = 1, n do
        if (track.s[k] - z.start) % track.length <= z.length then s.drsZone[k] = 1 end
      end
    end
  end
  return s
end

-- Interpolation bilinéaire dans une table [charge][vitesse] de car_model ; en charge, extrapolation
-- linéaire au-delà de la table (crêtes et compressions), charge bornée à [K.loadClampMin ; K.loadClampMax].
local function lookup2(tab, eff, v, n)
  local fi = v / eff.dv
  local i = floor(fi)
  local last = eff.speedCount - 2
  if i > last then
    i, fi = last, last + 1
  elseif i < 0 then
    i, fi = 0, 0
  end
  local ti = fi - i
  if n < K.loadClampMin then n = K.loadClampMin elseif n > K.loadClampMax then n = K.loadClampMax end
  local fj = (n - eff.loadMin) / eff.loadStep
  local j = floor(fj)
  local lastJ = #eff.loads - 2
  if j > lastJ then j = lastJ elseif j < 0 then j = 0 end
  local tj = fj - j
  local r0, r1 = tab[j + 1], tab[j + 2]
  local a = r0[i + 1] + (r0[i + 2] - r0[i + 1]) * ti
  local b = r1[i + 1] + (r1[i + 2] - r1[i + 1]) * ti
  local value = a + (b - a) * tj
  return value > 0 and value or 0
end

-- Interpolation linéaire dans une table [vitesse] de car_model.
local function lookup1(tab, eff, v)
  local fi = v / eff.dv
  local i = floor(fi)
  local last = eff.speedCount - 2
  if i > last then
    i, fi = last, last + 1
  elseif i < 0 then
    i, fi = 0, 0
  end
  return tab[i + 1] + (tab[i + 2] - tab[i + 1]) * (fi - i)
end

-- Force motrice du rapport g à la vitesse exacte v (table du rapport) ; nulle au-delà de son limiteur.
local function forceIn(eff, g, v)
  if v > eff.gearVmax[g] then return 0 end
  local fi = v / eff.dv
  local i = floor(fi)
  local last = eff.speedCount - 2
  if i > last then
    i, fi = last, last + 1
  elseif i < 0 then
    i, fi = 0, 0
  end
  local tab = eff.gearForce[g]
  return tab[i + 1] + (tab[i + 2] - tab[i + 1]) * (fi - i)
end

-- Force de l'ERS (MGU-K) à plein déploiement au rapport g et à la vitesse v ; nulle au-delà du limiteur.
local function ersIn(eff, g, v)
  if v > eff.gearVmax[g] then return 0 end
  local tab = eff.ersGearForce[g]
  if tab == nil then return 0 end
  local fi = v / eff.dv
  local i = floor(fi)
  local last = eff.speedCount - 2
  if i > last then
    i, fi = last, last + 1
  elseif i < 0 then
    i, fi = 0, 0
  end
  return tab[i + 1] + (tab[i + 2] - tab[i + 1]) * (fi - i)
end

-- Rapport donnant la plus grande force à la vitesse exacte v.
local function bestGear(eff, v)
  local best, gear = 0, eff.gearCount
  for g = 1, eff.gearCount do
    local f = forceIn(eff, g, v)
    if f > best then best, gear = f, g end
  end
  return gear
end

-- Rapport engagé avec hystérésis : on monte dès que le rapport supérieur donne plus de force ; on ne
-- redescend que si la vitesse passe nettement sous la plage du rapport courant (la coupure de couple
-- d'une montée ne doit pas provoquer de rétrogradation). Renvoie le rapport et vrai en cas de montée.
local function nextGear(eff, gearNow, v)
  local g = bestGear(eff, v)
  if g > gearNow then return g, true end
  if g < gearNow and v < eff.gearMinSpeed[gearNow] - K.shiftHysteresis then return g, false end
  return gearNow, false
end

-- Vitesse limite en virage au point k (point fixe décroissant depuis la vitesse de pointe). Charge
-- normale relative n (1 = poids sur sol plat) : pente, dévers vers l'intérieur, compression. ayTab :
-- table d'adhérence latérale (volet DRS fermé ou ouvert).
local function cornerLimit(buf, eff, k, vTop, ayTab)
  local kap = buf.kap[k]
  if kap < 1e-6 then return vTop end
  local cphi, sphi, cth, kv = buf.cphi[k], buf.sphi[k], buf.cth[k], buf.kv[k]
  local v = vTop
  for _ = 1, K.vLimIterations do
    local n = cth * cphi + v * v * (kap * sphi + kv) / G
    if n <= 0.05 then n = 0.05 end
    local cap = lookup2(ayTab, eff, v, n)
    local denom = kap * cphi
    local nextV = denom > 1e-9 and sqrt(max(0, (cap + G * cth * sphi) / denom)) or vTop
    if nextV > vTop then nextV = vTop end
    if abs(nextV - v) < K.vLimTolerance then return min(v, nextV) end
    v = nextV
  end
  return v
end

-- Vitesse à laquelle l'accélération latérale demandée atteint aLim au point k (dévers compris).
local function lateralSpeed(buf, k, aLim)
  local denom = buf.kap[k] * buf.cphi[k]
  if denom <= 1e-9 then return math.huge end
  return sqrt(max(0, (aLim + G * buf.cth[k] * buf.sphi[k]) / denom))
end

-- Adhérence longitudinale restante (ellipse) au point k pour la vitesse v. Renvoie le facteur,
-- la charge normale, l'accélération latérale demandée et la capacité latérale.
local function remaining(buf, eff, k, v)
  local v2, cphi, sphi, cth = v * v, buf.cphi[k], buf.sphi[k], buf.cth[k]
  local kap = buf.kap[k]
  local n = cth * cphi + v2 * (kap * sphi + buf.kv[k]) / G
  local ay = abs(v2 * kap * cphi - G * cth * sphi)
  if n <= 0.05 then n = 0.05 end
  local cap = lookup2(eff.ay, eff, v, n)
  local r = cap > 1e-9 and ay / cap or 1
  if r >= 1 then return 0, n, ay, cap end
  return sqrt(1 - r * r), n, ay, cap
end

-- Simulation complète. opts : { startSpeed = vitesse de départ d'un tracé ouvert (m/s),
-- tick = rendu coopératif, ersMask = déploiement de l'ERS par point (0–1, voiture configurée avec un
-- plan ERS) }. Renvoie un résumé ; les profils restent dans buf.
function M.run(track, eff, buf, opts)
  opts = opts or {}
  local tick = opts.tick or function() end
  local N, ds, mass = track.n, track.ds, eff.mass
  if buf == nil or buf.track ~= track then buf = M.new(track) end
  local sth = buf.sth
  local vLim, vf, vb, v, limit = buf.vLim, buf.vf, buf.vb, buf.v, buf.limit
  local vTop = min(eff.topSpeed, (eff.speedCount - 1) * eff.dv)
  local drs = eff.drsOn == true and buf.drsZoneCount > 0
  local zone, vOpen, drsOpen = buf.drsZone, buf.vOpen, buf.drsOpen
  local vTopOpen = drs and min(eff.topSpeedOpen, (eff.speedCount - 1) * eff.dv) or 0
  local limitG = drs and eff.drsLimitG and eff.drsLimitG * G or nil
  local ersMask = eff.ersOn and opts.ersMask or nil
  -- équilibre par point (tracé par virage, §12.1) : seulement à la demande, hors boucle de l'optimiseur
  local recordBalance = opts.recordBalance == true
  local kMin, vMin = 1, math.huge
  for k = 1, N do
    if k % K.simTickPoints == 0 then tick() end
    local value = cornerLimit(buf, eff, k, vTop, eff.ay)
    local open = 0
    if drs and zone[k] == 1 then
      open = cornerLimit(buf, eff, k, vTopOpen, eff.ayOpen)
      if limitG then open = min(open, lateralSpeed(buf, k, limitG)) end
      if open > value then value = open end
    end
    vOpen[k] = open
    drsOpen[k] = 0
    vLim[k] = value
    if value < vMin then kMin, vMin = k, value end
  end
  local closed = track.closed
  -- Passe arrière (freinage), en remontant le tracé.
  local count = closed and N or N - 1
  local k1 = closed and kMin or N
  vb[k1] = vLim[k1]
  for step = 1, count do
    if step % K.simTickPoints == 0 then tick() end
    local k = k1 - 1
    if k < 1 then k = N end
    local speed = vb[k1]
    local comb, n = remaining(buf, eff, k1, speed)
    local resist = (lookup1(eff.drag, eff, speed) + lookup1(eff.rollRes, eff, speed)) / mass
    local decel = lookup2(eff.brake, eff, speed, n) * comb + resist + G * sth[k1]
    if decel < 0 then decel = 0 end
    local value = sqrt(speed * speed + 2 * decel * ds)
    if value > vLim[k] then value = vLim[k] end
    vb[k] = value
    k1 = k
  end
  -- Passe avant (accélération).
  local k0 = closed and kMin or 1
  local start = closed and vLim[kMin] or min(opts.startSpeed or 0, vLim[1])
  vf[k0] = start
  local shiftTimer, gearNow = 0, bestGear(eff, start)
  local powerLimited, shifting = buf.powerLimited, buf.shifting
  powerLimited[k0], shifting[k0] = 0, 0
  for step = 1, count do
    if step % K.simTickPoints == 0 then tick() end
    local k = k0 + 1
    if k > N then k = 1 end
    local speed = vf[k0]
    local comb, n, ay, cap = remaining(buf, eff, k0, speed)
    local drag
    if drs and vOpen[k0] > 0 and speed <= vOpen[k0] + 1e-9 then
      drag = lookup1(eff.dragOpen, eff, speed)
      drsOpen[k0] = 1
    else
      drag = lookup1(eff.drag, eff, speed)
      drsOpen[k0] = 0
    end
    local resist = drag + lookup1(eff.rollRes, eff, speed)
    local up
    gearNow, up = nextGear(eff, gearNow, speed)
    if up and speed > 1 then shiftTimer = eff.shiftUpTime end
    local engine = forceIn(eff, gearNow, speed)
    local dt = ds / max(speed, 1)
    local cut = 0
    if shiftTimer > 0 then
      cut = min(1, shiftTimer / dt)
      shiftTimer = shiftTimer - dt
    end
    shifting[k0] = cut
    -- Roue intérieure : la charge transférée réduit la motricité d'un différentiel ouvert.
    local inner = 1 - (1 - eff.diffPower) * min(1, lookup1(eff.diffTransfer, eff, speed) * ay)
    local grip = lookup2(eff.tractionCap, eff, speed, n) * mass * comb * max(0, inner)
    -- H20 : différentiel bloqué en virage : la force motrice transférée à la roue intérieure (blocage ×
    -- force) crée un moment de lacet sous-vireur ; l'avant le compense avec sa marge latérale restante
    if eff.diffYawK and ay > 0 and cap > 0 then
      local yaw = max(0, 1 - ay / cap) * mass * cap * eff.diffYawK
      if yaw < grip then grip = yaw end
    end
    -- ERS : MGU-K par la boîte (coupé pendant le passage de rapport), moteurs avant bornés par
    -- l'adhérence longitudinale restante de l'avant (H21)
    local push = engine * (1 - cut)
    local front = 0
    local u = ersMask and ersMask[k0] or 0
    if u > 0 then
      push = push + u * ersIn(eff, gearNow, speed) * (1 - cut)
      front = min(u * lookup1(eff.ersFront, eff, speed), lookup2(eff.ersFrontCap, eff, speed, n) * mass * comb)
    end
    local drive = min(push, grip) + front
    powerLimited[k0] = push <= grip and 1 or 0
    local acc = (drive - resist) / mass - G * sth[k0]
    local value = speed * speed + 2 * acc * ds
    value = value > 0 and sqrt(value) or 0
    if value > vLim[k] then value = vLim[k] end
    vf[k] = value
    k0 = k
  end
  if not closed then
    vb[N] = vLim[N]
    powerLimited[N] = powerLimited[N - 1]
    shifting[N] = 0
  end
  -- Profil final, temps, facteurs limitants, indicateurs.
  local time, fuel, rearFirstDist, brakeDist, drsTime = 0, 0, 0, 0, 0
  local balanceSum, balanceAbs, cornerTime = 0, 0, 0
  local shifts, vMax = 0, 0
  local gearFinal = bestGear(eff, v[1] or 0)
  local target = math.log(K.balanceTarget)
  for k = 1, N do
    local value = min(vf[k], vb[k])
    v[k] = value
    if value > vMax then vMax = value end
  end
  local segments = closed and N or N - 1
  for k = 1, segments do
    if k % K.simTickPoints == 0 then tick() end
    local k2 = k < N and k + 1 or 1
    local speed = v[k]
    local dt = 2 * ds / max(K.simMinSpeed, speed + v[k2])
    time = time + dt
    local _, n, ay = remaining(buf, eff, k, speed)
    buf.nLoad[k], buf.ayReq[k] = n, ay
    local code
    if vb[k] < vf[k] - 1e-6 then
      code = M.LIMIT.brake
      brakeDist = brakeDist + ds
      if lookup2(eff.rearFirst, eff, speed, n) > 0.5 then rearFirstDist = rearFirstDist + ds end
    elseif vLim[k] - speed < K.cornerSpeedTol then
      code = M.LIMIT.corner
      local balance = lookup2(eff.balance, eff, speed, n)
      if recordBalance then buf.balance[k] = balance end
      local d = math.log(max(1e-3, balance)) - target
      balanceSum = balanceSum + d * dt
      balanceAbs = balanceAbs + d * d * dt
      cornerTime = cornerTime + dt
    elseif shifting[k] > 0 then
      code = M.LIMIT.shift
    elseif powerLimited[k] == 1 then
      code = M.LIMIT.power
    else
      code = M.LIMIT.traction
    end
    limit[k] = code
    if recordBalance and code ~= M.LIMIT.corner then buf.balance[k] = 0 end
    -- volet ouvert : décidé en accélération, refermé au freinage
    if drsOpen[k] == 1 and code == M.LIMIT.brake then drsOpen[k] = 0 end
    if drsOpen[k] == 1 then drsTime = drsTime + dt end
    local up
    gearFinal, up = nextGear(eff, gearFinal, speed)
    if up then shifts = shifts + 1 end
    -- Carburant (formule Kunos) : gaz plein en accélération, d'entretien en virage, nul au freinage.
    if eff.consumption then
      local throttle = 0
      if code == M.LIMIT.power or code == M.LIMIT.traction then
        throttle = 1
      elseif code == M.LIMIT.corner then
        local need = lookup1(eff.drag, eff, speed) + lookup1(eff.rollRes, eff, speed) + mass * G * sth[k]
        throttle = max(0, min(1, need / max(1, lookup1(eff.force, eff, speed))))
      end
      fuel = fuel + lookup1(eff.rpm, eff, speed) * throttle * eff.consumption / 1000 * dt
    end
  end
  if not closed then
    limit[N] = limit[N - 1]
    drsOpen[N] = 0
  end
  return {
    time = time, vMax = vMax, vMin = vMin, kMin = kMin, vTop = vTop, shifts = shifts,
    drs = drs, drsTime = drsTime, vTopOpen = drs and vTopOpen or nil,
    fuel = eff.consumption and fuel or nil,
    balanceMean = cornerTime > 0 and math.exp(balanceSum / cornerTime + target) or 1,
    balanceRms = cornerTime > 0 and sqrt(balanceAbs / cornerTime) or 0,
    cornerTime = cornerTime,
    rearFirstShare = brakeDist > 0 and rearFirstDist / brakeDist or 0,
    bottoming = eff.bottoming, belowMinHeight = eff.belowMinHeight, brakeLockRisk = eff.brakeLockRisk or 0,
    currentBelowMinHeight = eff.currentBelowMinHeight,
  }, buf
end

-- Pénalités en secondes (§10.2, §8.3, §8.4), pondérées ensuite par Config.penaltyWeights.
function M.penalties(result)
  local balance = K.balancePenaltySec * (result.balanceRms / math.log(1 + K.balanceTolerance)) ^ 2
  local stability = K.rearLockPenaltySec * result.rearFirstShare + (result.bottoming and K.bottomingPenaltySec or 0)
    + K.brakeLockPenaltySec * (result.brakeLockRisk or 0)
  return balance, stability
end

return M
