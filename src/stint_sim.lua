-- SetupLab — simulation de relais (§8.7). Noyau pur (D5).
--
-- Tour par tour sur un relais de N tours :
-- - carburant décroissant (masse) ;
-- - usure : km virtuels par essieu et WEAR_CURVE de chaque essieu, d'où la perte d'adhérence et le
--   déséquilibre induit quand les deux essieux ne s'usent pas pareil ;
-- - trafic : sur une fraction des tours, derrière une autre voiture, traînée réduite par l'aspiration
--   (hypothèse H6) et appui réduit par l'air sale (hypothèse H7) ; DRS dans ses zones sur ces tours-là
--   seulement (§8.9 : moins d'une seconde derrière la voiture qui précède).
-- Température des pneus : plateau de PERFORMANCE_CURVE, sans dérive le long du relais (arbitrage
-- A19 : aucun modèle thermique prédictif vérifiable hors jeu ; même hypothèse qu'en qualification).
--
-- Deux usages :
-- - relais exact (tous les tours), pour le résultat affiché : temps total, tour moyen, dégradation,
--   tour critique, équilibre au premier et au dernier tour ;
-- - relais échantillonné, pour l'optimiseur (coût, §8.8) : quelques tours simulés (premier, dernier,
--   milieu, niveaux d'usure extrêmes) ; le niveau d'usure de chaque essieu à chaque tour est connu
--   d'avance (km virtuels du plan, WEAR_CURVE), et le temps au tour est ajusté en fonction linéaire du
--   carburant et de ces niveaux, puis sommé sur les N tours : les cassures de la courbe d'usure sont
--   suivies sans être échantillonnées une à une.

local Util = require('src/util')
local Config = require('src/config')
local CarModel = require('src/car_model')
local Sim = require('src/laptime_sim')

local K = Config.K

local M = {}

local floor, max, min, abs = math.floor, math.max, math.min, math.abs

-- Plan du relais, indépendant du setup. args : { laps, fuelStart (L), fuelPerLap (L), kmPerLapF,
-- kmPerLapR, km0F?, km0R? (km virtuels au départ, 0 : pneus neufs), trafficFraction (0–1),
-- slipstreamDrag, dirtyAirLift (réductions relatives dans le trafic), drs? (DRS dans le trafic) }.
function M.plan(args)
  return {
    laps = max(1, floor(args.laps)), fuelStart = max(0, args.fuelStart or 0), fuelPerLap = max(0, args.fuelPerLap or 0),
    kmPerLapF = max(0, args.kmPerLapF or 0), kmPerLapR = max(0, args.kmPerLapR or 0),
    km0F = max(0, args.km0F or 0), km0R = max(0, args.km0R or 0),
    trafficFraction = Util.clamp(args.trafficFraction or 0, 0, 1),
    slipstreamDrag = Util.clamp(args.slipstreamDrag or 0, 0, 0.9), dirtyAirLift = Util.clamp(args.dirtyAirLift or 0, 0, 0.9),
    drs = args.drs == true,
  }
end

-- Carburant moyen pendant le tour k (1..N) et km virtuels moyens de chaque essieu.
function M.lapFuel(plan, k)
  return max(0, plan.fuelStart - (k - 0.5) * plan.fuelPerLap)
end

function M.lapKm(plan, k)
  return plan.km0F + (k - 0.5) * plan.kmPerLapF, plan.km0R + (k - 0.5) * plan.kmPerLapR
end

-- Niveau d'adhérence d'usure (WEAR_CURVE, %) de chaque essieu à chaque tour du relais : connu d'avance,
-- indépendant du setup (km virtuels par tour fixés par le plan).
local function wearLevels(plan, compound, levelF, levelR)
  for k = 1, plan.laps do
    local kmF, kmR = M.lapKm(plan, k)
    levelF[k] = compound.front.wear and Util.lutEval(compound.front.wear, kmF) or 100
    levelR[k] = compound.rear.wear and Util.lutEval(compound.rear.wear, kmR) or 100
  end
  for k = plan.laps + 1, #levelF do levelF[k], levelR[k] = nil, nil end
end

-- Tours simulés pour un composé : 1, N, le tour du milieu (pénalités, trafic, robustesse), puis les
-- tours aux niveaux d'usure extrêmes (avant, arrière, et leur écart), K.raceMaxSamples au plus.
-- Renvoie la liste croissante et l'indice du tour du milieu.
function M.sampleLaps(plan, levelF, levelR)
  local N = plan.laps
  local mid = floor((N + 1) / 2)
  local samples = {}
  if N <= K.raceMaxSamples then
    for k = 1, N do samples[k] = k end
  else
    local chosen = { [1] = true, [N] = true, [mid] = true }
    local count = mid == 1 and 2 or 3
    local function extreme(score)
      local best, at = -math.huge, nil
      for k = 1, N do
        local s = score(k)
        if not chosen[k] and s > best + 1e-12 then best, at = s, k end
      end
      return at
    end
    local picks = {
      function(k) return -levelF[k] end, function(k) return levelF[k] end,
      function(k) return -levelR[k] end, function(k) return levelR[k] end,
      function(k) return abs(levelF[k] - levelR[k]) end,
    }
    for _, score in ipairs(picks) do
      if count >= K.raceMaxSamples then break end
      local k = extreme(score)
      if k then
        chosen[k] = true
        count = count + 1
      end
    end
    for k = 1, N do
      if chosen[k] then samples[#samples + 1] = k end
    end
  end
  local middle = 1
  for i, k in ipairs(samples) do
    if k == mid then middle = i end
  end
  return samples, middle
end

-- Moindres carrés : y ≈ Σ c_j·x_j (colonnes cols, lignes rows). Renvoie les coefficients, ou nil.
local function leastSquares(cols, y, rows)
  local m = #cols
  local A, b = {}, {}
  for i = 1, m do
    A[i], b[i] = {}, 0
    for r = 1, rows do b[i] = b[i] + cols[i][r] * y[r] end
    for j = 1, m do
      local s = 0
      for r = 1, rows do s = s + cols[i][r] * cols[j][r] end
      A[i][j] = s
    end
  end
  for c = 1, m do
    local pivot = c
    for r = c + 1, m do
      if abs(A[r][c]) > abs(A[pivot][c]) then pivot = r end
    end
    if abs(A[pivot][c]) < 1e-12 * max(1, abs(A[1][1])) then return nil end
    A[c], A[pivot], b[c], b[pivot] = A[pivot], A[c], b[pivot], b[c]
    for r = c + 1, m do
      local f = A[r][c] / A[c][c]
      for j = c, m do A[r][j] = A[r][j] - f * A[c][j] end
      b[r] = b[r] - f * b[c]
    end
  end
  local x = {}
  for r = m, 1, -1 do
    local s = b[r]
    for j = r + 1, m do s = s - A[r][j] * x[j] end
    x[r] = s / A[r][r]
  end
  return x
end

-- Somme des temps des N tours d'après les tours simulés : temps ajusté (moindres carrés) en fonction
-- linéaire du carburant et des niveaux d'usure avant et arrière, connus à chaque tour ; une variable
-- constante sur le relais, ou confondue avec une autre, est retirée. Repli : interpolation linéaire en
-- numéro de tour si l'ajustement est impossible.
local function stintTotal(ev)
  local plan, samples, times = ev.plan, ev.samples, ev.sampleTimes
  local N = plan.laps
  if #samples == N then
    local total = 0
    for i = 1, N do total = total + times[i] end
    return total
  end
  local fit = ev.fit
  if fit.columns then
    local cols = fit.sampleCols
    local coef = leastSquares(cols, times, #samples)
    if coef then
      local total = 0
      for k = 1, N do
        local t = 0
        for j, column in ipairs(fit.columns) do t = t + coef[j] * column[k] end
        total = total + t
      end
      return total
    end
  end
  local total = 0
  for i = 1, #samples - 1 do
    local k1, k2, t1, t2 = samples[i], samples[i + 1], times[i], times[i + 1]
    for k = k1, k2 - 1 do total = total + t1 + (t2 - t1) * (k - k1) / (k2 - k1) end
  end
  return total + times[#samples]
end

-- Colonnes de l'ajustement (constante, carburant, usure avant, usure arrière) sur les N tours et sur les
-- tours simulés ; variables constantes ou confondues retirées, au plus autant que de tours simulés.
local function buildFit(ev)
  local plan, samples = ev.plan, ev.samples
  local N = plan.laps
  local function varies(list)
    for k = 2, N do
      if abs(list[k] - list[1]) > 1e-9 then return true end
    end
    return false
  end
  local ones, fuel = {}, {}
  for k = 1, N do ones[k], fuel[k] = 1, M.lapFuel(plan, k) end
  local columns = { ones }
  if varies(fuel) then columns[#columns + 1] = fuel end
  local lf, lr = ev.levelF, ev.levelR
  local sameAxles = true
  for k = 1, N do
    if abs(lf[k] - lr[k]) > 1e-9 then sameAxles = false end
  end
  if varies(lf) then columns[#columns + 1] = lf end
  if not sameAxles and varies(lr) then columns[#columns + 1] = lr end
  while #columns > #samples do columns[#columns] = nil end
  local sampleCols = {}
  for j, column in ipairs(columns) do
    sampleCols[j] = {}
    for i, k in ipairs(samples) do sampleCols[j][i] = column[k] end
  end
  ev.fit = { columns = columns, sampleCols = sampleCols }
end

-- Évaluateur réutilisable (tables et tampons gardés d'un appel à l'autre). args : { base, track,
-- conditions (copiées), factors?, plan, compound (position), weights, tick? }.
function M.newEvaluator(args)
  local ev = {
    base = args.base, track = args.track, plan = args.plan, weights = args.weights, tick = args.tick,
    buf = Sim.new(args.track), conditions = {}, sampleTimes = {}, levelF = {}, levelR = {},
  }
  for key, value in pairs(args.conditions or {}) do ev.conditions[key] = value end
  ev.simOpts = { tick = args.tick }
  M.setFactors(ev, args.factors)
  M.setCompound(ev, args.compound)
  return ev
end

-- Facteurs du modèle et facteurs dans le trafic (traînée et appui réduits).
function M.setFactors(ev, factors)
  local f = factors or CarModel.defaultFactors()
  ev.factors = f
  ev.trafficFactors = {
    mu = f.mu, power = f.power, brake = f.brake,
    drag = f.drag * (1 - ev.plan.slipstreamDrag), lift = f.lift * (1 - ev.plan.dirtyAirLift),
  }
end

function M.setCompound(ev, slot)
  ev.compound = slot
  local compound = ev.base.compounds[slot] or ev.base.compounds[1]
  wearLevels(ev.plan, compound, ev.levelF, ev.levelR)
  ev.samples, ev.middle = M.sampleLaps(ev.plan, ev.levelF, ev.levelR)
  buildFit(ev)
end

-- Un tour du relais (k) avec un setup physique ; factors : facteurs à appliquer (trafic, robustesse) ;
-- drs : DRS dans ses zones (tour en trafic).
local function lapRun(ev, setup, k, factors, drs)
  local c = ev.conditions
  c.tyreKmF, c.tyreKmR = M.lapKm(ev.plan, k)
  c.factors = factors or ev.factors
  c.drs = drs == true
  setup.compound = ev.compound
  setup.fuel = M.lapFuel(ev.plan, k)
  local eff = CarModel.configure(ev.base, setup, c, ev.tick, ev.eff)
  if eff == nil then return nil end
  ev.eff = eff
  if eff.belowMinHeight then return nil end
  return Sim.run(ev.track, eff, ev.buf, ev.simOpts)
end
M.lapRun = lapRun

-- Relais échantillonné (optimiseur). Renvoie J (s/tour) et le détail { mean, traffic, balance,
-- stability, middleTime }, ou math.huge si le setup n'est pas simulable. extraFactors : facteurs
-- perturbés (robustesse) appliqués au seul tour du milieu.
function M.evaluate(ev, setup, extraFactors)
  local plan, samples, times = ev.plan, ev.samples, ev.sampleTimes
  local N = plan.laps
  if extraFactors then
    local r = lapRun(ev, setup, samples[ev.middle], extraFactors)
    return r and r.time or math.huge
  end
  local balance, stability, middleTime, middleLock = 0, 0, 0, 0
  for i, k in ipairs(samples) do
    local r = lapRun(ev, setup, k, nil)
    if r == nil then return math.huge, nil end
    times[i] = r.time
    if i == ev.middle then
      balance, stability = Sim.penalties(r)
      middleTime, middleLock = r.time, r.rearFirstShare
    end
  end
  local mean = stintTotal(ev) / N
  local traffic, trafficLock = 0, 0
  if plan.trafficFraction > 0 then
    local r = lapRun(ev, setup, samples[ev.middle], ev.trafficFactors, plan.drs)
    if r == nil then return math.huge, nil end
    -- P_trafic (§10.2), sur la fraction de tours en trafic : écart du tour en trafic au tour en air libre
    -- (négatif : bonus d'aspiration ; positif : setup dépendant de l'air propre), plus la stabilité au
    -- freinage dans l'air sale (blocage de l'arrière en plus de l'air libre, même barème que P_stabilité)
    trafficLock = plan.trafficFraction * K.rearLockPenaltySec * max(0, r.rearFirstShare - middleLock)
    traffic = plan.trafficFraction * (r.time - middleTime) + trafficLock
  end
  local w = ev.weights
  local J = mean + w.traffic * traffic + w.bal * balance + w.stab * K.raceStabFactor * stability
  return J, { mean = mean, traffic = traffic, trafficLock = trafficLock, balance = balance, stability = stability,
    middleTime = middleTime }
end

-- Relais exact (tous les tours, air libre), pour le résultat affiché.
function M.runExact(ev, setup)
  local plan = ev.plan
  local laps = {}
  local total, best = 0, math.huge
  local first, last = nil, nil
  for k = 1, plan.laps do
    local r = lapRun(ev, setup, k, nil)
    if r == nil then return nil end
    laps[k] = r.time
    total = total + r.time
    best = min(best, r.time)
    if k == 1 then first = r.balanceMean end
    last = r.balanceMean
  end
  -- dégradation : pente des temps au tour (moindres carrés), en % du meilleur tour par tour
  local n = plan.laps
  local slope = 0
  if n >= 2 then
    local mk, mt = (n + 1) / 2, total / n
    local num, den = 0, 0
    for k = 1, n do
      num = num + (k - mk) * (laps[k] - mt)
      den = den + (k - mk) * (k - mk)
    end
    slope = den > 0 and num / den or 0
  end
  -- tour critique : premier tour plus lent que le meilleur de K.raceCriticalLoss
  local critical = nil
  for k = 1, n do
    if laps[k] > best + K.raceCriticalLoss then
      critical = k
      break
    end
  end
  return {
    laps = laps, total = total, mean = total / n, best = best, degradationPct = slope / max(1, best) * 100,
    critical = critical, balanceFirst = first, balanceLast = last,
    fuelStart = plan.fuelStart, fuelEnd = max(0, plan.fuelStart - n * plan.fuelPerLap),
  }
end

return M
