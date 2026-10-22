-- SetupLab — calibration du modèle sur des tours mesurés (§9.2, §9.3, §9.3 bis, §14.1). Noyau pur.
--
-- Cinq facteurs scalaires bornés (adhérence kμ, puissance kP, traînée kD, appui kL, freinage kB)
-- recalés pour que la simulation reproduise un ou plusieurs tours mesurés, chacun avec son setup et
-- ses conditions réelles (températures et usure des pneus, pressions à chaud, carburant moyen,
-- piste) : sinon kμ absorberait l'état des pneus et fausserait l'optimisation, qui les suppose à
-- température. Objectif : somme sur les tours de (écart de temps relatif)² et (RMS de v(s) / vmax)².
-- Méthode : descente de coordonnées bornée, puis Levenberg–Marquardt borné (arbitrage A17).
--
-- Après la descente : un facteur dont la variation de ±3 % ne change presque pas l'objectif est
-- « non identifié » et remis à 1 (appui d'une voiture sans aéro, freinage limité par le couple) ; un
-- facteur posé sur sa borne signale un modèle hors de son domaine : la calibration n'est alors pas
-- utilisée. Plusieurs tours avec des setups différents : l'écart restant de chaque tour mesure la
-- justesse de la sensibilité du modèle aux réglages (§14.1).

local Util = require('src/util')
local Config = require('src/config')
local CarModel = require('src/car_model')
local Sim = require('src/laptime_sim')
local TrackModel = require('src/track_model')

local K = Config.K

local M = {}

local sqrt, abs, max, min = math.sqrt, math.abs, math.max, math.min

M.KEYS = { 'mu', 'power', 'drag', 'lift', 'brake' }
M.LABELS = { mu = 'adhérence', power = 'puissance', drag = 'traînée', lift = 'appui', brake = 'freinage' }

-- Profil mesuré ramené sur la grille du modèle de circuit (abscisse par la progression IA).
-- lap : { n, p[], v[], time }. Renvoie { v[], vmax, time } ou nil et la raison.
function M.measured(track, lap, tick)
  tick = tick or function() end
  if lap == nil or lap.n < K.recorderMinSamples or not Util.isFinite(lap.time) or lap.time <= 0 then
    return nil, 'tour inutilisable'
  end
  local order = Util.progressOrder(lap.p, lap.n)
  tick()
  local S, V = {}, {}
  for k, i in ipairs(order) do
    S[k], V[k] = TrackModel.sAtProgress(track, lap.p[i]), lap.v[i]
    if k % K.estimateTickSamples == 0 then tick() end
  end
  local out = { v = {}, vmax = 0, time = lap.time }
  -- déploiement de l'ERS relevé (H24), ramené sur la grille : seulement si le tour en a eu
  local E = nil
  if lap.ersUsed and lap.ers then
    E, out.ers = {}, {}
    for k, i in ipairs(order) do E[k] = lap.ers[i] end
  end
  local j, n = 1, #S
  for k = 1, track.n do
    local s = track.s[k]
    while j < n and S[j + 1] < s do j = j + 1 end
    local value
    if s <= S[1] then
      value = V[1]
    elseif s >= S[n] then
      value = V[n]
    else
      local f = S[j + 1] > S[j] and (s - S[j]) / (S[j + 1] - S[j]) or 0
      value = V[j] + (V[j + 1] - V[j]) * Util.clamp(f, 0, 1)
    end
    out.v[k] = value
    if value > out.vmax then out.vmax = value end
    if E then out.ers[k] = (s <= S[1] or s >= S[n]) and E[s <= S[1] and 1 or n] or E[j] end
  end
  return out, nil
end

-- Conditions de simulation d'un tour mesuré (état réel des pneus, piste, carburant moyen).
function M.lapConditions(lap)
  local c = lap.conditions or {}
  local temp = 0
  for w = 1, 4 do temp = temp + (lap.tyreTemp[w] or 0) / 4 end
  local km = 0
  for w = 1, 4 do km = km + (lap.tyreKm[w] or 0) / 4 end
  -- DRS ouvert pendant le tour (enregistré) : simulé dans les zones (§8.9)
  -- piste mouillée (D16 amendé) : humidité et eau du tour, eau mesurée sous les pneus
  local wet = lap.bucket == 'pluie'
  local conditions = {
    airTemp = c.airTemp, roadTemp = c.roadTemp, roadGrip = c.roadGrip, surfaceGrip = c.surfaceGrip,
    tyreTemp = temp > 0 and temp or nil, tyreKm = km, drs = lap.drsUsed == true,
    bucket = wet and 'pluie' or 'sec', wetness = wet and c.wetness or 0, water = wet and c.water or 0,
    waterMm = wet and lap.waterMm or nil,
  }
  if (lap.pressure[1] or 0) > 0 and (lap.pressure[3] or 0) > 0 then
    conditions.hotPressureF = (lap.pressure[1] + lap.pressure[2]) / 2
    conditions.hotPressureR = (lap.pressure[3] + lap.pressure[4]) / 2
  end
  local fuel = nil
  if Util.isFinite(lap.fuelStart) and Util.isFinite(lap.fuelEnd) then fuel = (lap.fuelStart + lap.fuelEnd) / 2 end
  return conditions, fuel
end

-- Une course de calibration. args : { track, base, setup (physique, déjà au carburant du tour),
-- conditions, measured (M.measured), label }. Tour mesuré avec l'ERS (conditions.ersSpec) : simulé avec
-- le déploiement relevé.
function M.newRun(args)
  local ersMask = args.conditions and args.conditions.ersSpec and args.measured and args.measured.ers or nil
  return {
    track = args.track, base = args.base, setup = args.setup, conditions = args.conditions, measured = args.measured,
    label = args.label or 'tour', signature = args.signature, buf = Sim.new(args.track), eff = nil, ersMask = ersMask,
  }
end

-- Écarts d'un tour pour des facteurs donnés : temps relatif, RMS de vitesse relatif, temps simulé.
local function residuals(run, factors, ctx)
  run.conditions.factors = factors
  local eff = CarModel.configure(run.base, run.setup, run.conditions, ctx.tick, run.eff)
  if eff == nil then return math.huge, math.huge, nil end
  run.eff = eff
  local result = Sim.run(run.track, eff, run.buf, { tick = ctx.tick, ersMask = run.ersMask })
  local meas = run.measured
  local v, sum = run.buf.v, 0
  for k = 1, run.track.n do
    local d = v[k] - meas.v[k]
    sum = sum + d * d
  end
  local rms = sqrt(sum / run.track.n) / max(1, meas.vmax)
  return (result.time - meas.time) / meas.time, rms, result.time
end

-- Le facteur d'appui n'a de sens que si la voiture a de l'appui (sinon, non identifiable par
-- construction et laissé à 1).
local function hasAero(runs, ctx)
  for _, run in ipairs(runs) do
    local eff = CarModel.configure(run.base, run.setup, run.conditions, ctx.tick, nil)
    if eff then
      local i = math.floor(K.calibAeroCheckSpeed / eff.dv) + 1
      if (eff.lift[i] or 0) > K.calibMinLiftN then return true end
    end
  end
  return false
end

-- Vecteur des écarts de tous les tours (profil de vitesse point par point, puis temps), pondéré de
-- sorte que sa somme des carrés soit l'objectif. Perte robuste de Huber sur les écarts de vitesse
-- (au-delà de K.calibHuber × vmax, influence linéaire) : un virage raté ne tire pas un facteur
-- jusqu'à sa borne. Renvoie l'objectif robuste.
local function fillResiduals(runs, factors, ctx, out)
  local i, total = 0, 0
  local wv, wt, c = sqrt(K.calibWeightSpeed), sqrt(K.calibWeightTime), K.calibHuber
  for _, run in ipairs(runs) do
    local dt, rms = residuals(run, factors, ctx)
    local meas, v, n = run.measured, run.buf.v, run.track.n
    local norm = 1 / max(1, meas.vmax)
    local scale = wv / sqrt(n)
    if Util.isFinite(dt) and Util.isFinite(rms) then
      local sum = 0
      for k = 1, n do
        i = i + 1
        local r = (v[k] - meas.v[k]) * norm
        local a = abs(r)
        if a > c then r = (r > 0 and 1 or -1) * sqrt(2 * c * a - c * c) end
        out[i] = r * scale
        sum = sum + r * r
      end
      i = i + 1
      out[i] = wt * dt
      total = total + K.calibWeightTime * dt * dt + K.calibWeightSpeed * sum / n
    else
      for _ = 1, n + 1 do
        i = i + 1
        out[i] = 1e3
      end
      total = math.huge
    end
  end
  return total, i
end

-- Résolution de A·x = b (m × m, élimination de Gauss avec pivot partiel). nil si singulière.
local function solve(A, b, m)
  local a, x = {}, {}
  for r = 1, m do
    a[r] = {}
    for c = 1, m do a[r][c] = A[r][c] end
    a[r][m + 1] = b[r]
  end
  for c = 1, m do
    local pivot = c
    for r = c + 1, m do
      if abs(a[r][c]) > abs(a[pivot][c]) then pivot = r end
    end
    if abs(a[pivot][c]) < 1e-300 then return nil end
    a[c], a[pivot] = a[pivot], a[c]
    for r = c + 1, m do
      local f = a[r][c] / a[c][c]
      for k = c, m + 1 do a[r][k] = a[r][k] - f * a[c][k] end
    end
  end
  for r = m, 1, -1 do
    local s = a[r][m + 1]
    for k = r + 1, m do s = s - a[r][k] * x[k] end
    x[r] = s / a[r][r]
  end
  return x
end

-- Calibration (dans une tâche découpée). runs : liste de M.newRun. Renvoie le résultat.
-- Méthode (arbitrage A17) : descente de coordonnées bornée pour dégrossir (§9.2), puis moindres
-- carrés de Levenberg–Marquardt bornés sur le vecteur des écarts. Les facteurs se compensent par
-- paires (adhérence contre appui, puissance avec traînée) : sur ces vallées courbes, la descente de
-- coordonnées seule s'arrête loin de l'optimum (mesuré au banc : appui 1,13 pour 0,92).
function M.run(runs, ctx)
  local evaluations = 0
  local factors = CarModel.defaultFactors()
  local free = {}
  for _, key in ipairs(M.KEYS) do free[key] = true end
  if not hasAero(runs, ctx) then free.lift = false end
  local scratch = {}
  local function objective(f)
    evaluations = evaluations + #runs
    return (fillResiduals(runs, f, ctx, scratch))
  end
  local function descend(f, J)
    for _, step in ipairs(K.calibSteps) do
      local improved = true
      while improved and evaluations < K.calibCoarseEvals do
        improved = false
        for _, key in ipairs(M.KEYS) do
          if free[key] then
            local bounds = K.calibBounds[key]
            for _, sign in ipairs({ 1, -1 }) do
              local saved = f[key]
              local value = Util.clamp(saved + sign * step, bounds[1], bounds[2])
              if value ~= saved then
                f[key] = value
                local Jn = objective(f)
                if Jn < J - 1e-12 then
                  J = Jn
                  improved = true
                  break
                end
                f[key] = saved
              end
            end
          end
        end
      end
    end
    return J
  end
  local r0, r1, cols, trial = {}, {}, {}, {}
  local function levenberg(f, J)
    local keys = {}
    for _, key in ipairs(M.KEYS) do
      if free[key] then keys[#keys + 1] = key end
    end
    local m = #keys
    if m == 0 then return J end
    evaluations = evaluations + #runs
    local N
    J, N = fillResiduals(runs, f, ctx, r0)
    local lambda = K.calibLmLambda
    for _ = 1, K.calibLmIterations do
      if evaluations >= K.calibMaxEvals then break end
      -- jacobien par différences finies (vers l'intérieur des bornes)
      for j, key in ipairs(keys) do
        local bounds = K.calibBounds[key]
        local x0 = f[key]
        local x1 = x0 + K.calibLmStep
        if x1 > bounds[2] then x1 = x0 - K.calibLmStep end
        f[key] = x1
        evaluations = evaluations + #runs
        fillResiduals(runs, f, ctx, r1)
        f[key] = x0
        local col = cols[j] or {}
        cols[j] = col
        local d = x1 - x0
        for i = 1, N do col[i] = (r1[i] - r0[i]) / d end
        ctx.tick()
      end
      local A, g = {}, {}
      for a = 1, m do
        A[a] = {}
        local ca = cols[a]
        local sg = 0
        for i = 1, N do sg = sg + ca[i] * r0[i] end
        g[a] = -sg
        for b = 1, m do
          local cb, s = cols[b], 0
          for i = 1, N do s = s + ca[i] * cb[i] end
          A[a][b] = s
        end
      end
      ctx.tick()
      local accepted, gain = false, 0
      for _ = 1, K.calibLmRetries do
        local Ad = {}
        for a = 1, m do
          Ad[a] = {}
          for b = 1, m do Ad[a][b] = A[a][b] + (a == b and lambda * max(A[a][a], 1e-12) or 0) end
        end
        local delta = solve(Ad, g, m)
        if delta == nil then break end
        for _, key in ipairs(M.KEYS) do trial[key] = f[key] end
        for j, key in ipairs(keys) do
          local bounds = K.calibBounds[key]
          trial[key] = Util.clamp(f[key] + delta[j], bounds[1], bounds[2])
        end
        evaluations = evaluations + #runs
        local Jn = fillResiduals(runs, trial, ctx, r1)
        if Jn < J then
          gain = (J - Jn) / max(J, 1e-30)
          for _, key in ipairs(keys) do f[key] = trial[key] end
          r0, r1 = r1, r0
          J = Jn
          lambda = lambda / 3
          accepted = true
          break
        end
        lambda = lambda * 4
      end
      if not accepted or gain < K.calibLmTolerance then break end
    end
    return J
  end
  local J = levenberg(factors, descend(factors, objective(factors)))
  -- identifiabilité : ±K.calibIdentDelta sur chaque facteur libre
  local identified = {}
  local changed = false
  for _, key in ipairs(M.KEYS) do
    if free[key] then
      -- seuls les côtés réellement déplacés comptent : sur une borne, le côté bloqué serait le
      -- point lui-même (hausse nulle) et masquerait la butée en « non identifié »
      local saved = factors[key]
      local bounds = K.calibBounds[key]
      local rise = math.huge
      for _, sign in ipairs({ 1, -1 }) do
        local value = Util.clamp(saved * (1 + sign * K.calibIdentDelta), bounds[1], bounds[2])
        if value ~= saved then
          factors[key] = value
          rise = min(rise, objective(factors) - J)
        end
      end
      factors[key] = saved
      identified[key] = rise > K.calibIdentThreshold * max(J, K.calibIdentFloor)
      if not identified[key] then
        free[key] = false
        factors[key] = 1
        changed = true
      end
    else
      identified[key] = false
    end
  end
  if changed then J = levenberg(factors, descend(factors, objective(factors))) end
  -- résultats par tour, facteurs à la borne, écart « modèle idéal / tour réel » (§9.3 bis)
  local atBound = {}
  local anyBound = false
  for _, key in ipairs(M.KEYS) do
    local bounds = K.calibBounds[key]
    atBound[key] = free[key] and (abs(factors[key] - bounds[1]) < 1e-9 or abs(factors[key] - bounds[2]) < 1e-9)
    if atBound[key] then anyBound = true end
  end
  local perRun, worstTime, worstRms = {}, 0, 0
  local unit = CarModel.defaultFactors()
  for _, run in ipairs(runs) do
    local dt, rms, simTime = residuals(run, factors, ctx)
    local idealDt, _, idealTime = residuals(run, unit, ctx)
    perRun[#perRun + 1] = { label = run.label, signature = run.signature, fuel = run.setup.fuel, timeError = dt, rms = rms,
      simTime = simTime, measuredTime = run.measured.time, idealTime = idealTime, idealError = idealDt }
    worstTime, worstRms = max(worstTime, abs(dt)), max(worstRms, rms)
  end
  local usable = not anyBound and worstTime <= K.calibMaxTimeError and worstRms <= K.calibMaxRms
  local reason = nil
  if anyBound then
    reason = 'facteur en butée : modèle hors de son domaine'
  elseif worstTime > K.calibMaxTimeError then
    reason = 'écart de temps ' .. Util.fmt(worstTime * 100, 2) .. ' % > ' .. Util.fmt(K.calibMaxTimeError * 100, 0) .. ' %'
  elseif worstRms > K.calibMaxRms then
    reason = 'profil de vitesse : RMS ' .. Util.fmt(worstRms * 100, 1) .. ' % > ' .. Util.fmt(K.calibMaxRms * 100, 0) .. ' %'
  end
  return {
    factors = factors, identified = identified, atBound = atBound, objective = J, runs = perRun,
    worstTimeError = worstTime, worstRms = worstRms, usable = usable, reason = reason, evaluations = evaluations,
  }
end

-- ---------------------------------------------------------------------------
-- Mode « mesure uniquement » (§9.4) : voiture dont les données sont illisibles
-- ---------------------------------------------------------------------------

-- Moindres carrés à deux inconnues : y = a·x1 + b·x2. Renvoie a, b (nil si mal conditionné).
local function fit2(x1, x2, y)
  local s11, s12, s22, s1y, s2y = 0, 0, 0, 0, 0
  for i = 1, #y do
    s11, s12, s22 = s11 + x1[i] * x1[i], s12 + x1[i] * x2[i], s22 + x2[i] * x2[i]
    s1y, s2y = s1y + x1[i] * y[i], s2y + x2[i] * y[i]
  end
  local det = s11 * s22 - s12 * s12
  if abs(det) < 1e-12 * max(1, s11 * s22) then return nil end
  return (s1y * s22 - s2y * s12) / det, (s11 * s2y - s12 * s1y) / det
end

-- Quantile q (0–1) d'une liste (copie triée).
local function quantile(list, q)
  local sorted = {}
  for i, v in ipairs(list) do sorted[i] = v end
  table.sort(sorted)
  return sorted[max(1, math.floor(#sorted * q + 0.5))]
end

-- Enveloppe supérieure d'un ajustement y = a·x1 + b·x2 : les points nettement sous l'ajustement
-- (phases où la voiture n'est pas à sa limite) sont écartés, passe après passe. Renvoie a, b.
local function upperFit(x1, x2, y, passes)
  local a, b = fit2(x1, x2, y)
  for _ = 1, passes do
    if a == nil then return nil end
    local sum = 0
    for i = 1, #y do sum = sum + (y[i] - a * x1[i] - b * x2[i]) ^ 2 end
    local sigma = sqrt(sum / #y)
    local k1, k2, ky = {}, {}, {}
    for i = 1, #y do
      if y[i] - a * x1[i] - b * x2[i] > -sigma then
        k1[#k1 + 1], k2[#k2 + 1], ky[#ky + 1] = x1[i], x2[i], y[i]
      end
    end
    if #ky < K.estimateMinSamples or #ky == #y then break end
    x1, x2, y = k1, k2, ky
    a, b = fit2(x1, x2, y)
  end
  return a, b
end

-- Adhérence et appui depuis les virages : chaque point vérifie ay ≤ μ·(n·g + k·v²), avec égalité aux
-- points pris à la limite. Pour k donné, μ_i = ay/(n·g + k·v²) ; au bon k, tous les points à la
-- limite (à des vitesses différentes) ont le même μ_i, le plus grand. On balaie k et on garde celui
-- qui regroupe le plus de points à moins de K.estimateClusterTol du sommet (quantile élevé, qui
-- écarte quelques points aberrants). Les virages pris avec marge restent dessous sans rien fausser.
-- Renvoie μ, k et le rapport des vitesses extrêmes du groupe retenu (k n'est identifiable que si les
-- points à la limite couvrent des vitesses différentes).
local function lateralFit(nG, v2, ay, kHi, tick)
  local n = #ay
  local mu, work = {}, {}
  local pick = max(1, math.floor(n * K.estimateLateralQuantile + 0.5))
  local best = { count = -1 }
  for step = 0, K.estimateGridSteps do
    tick()
    local k = kHi * step / K.estimateGridSteps
    for i = 1, n do
      local value = ay[i] / (nG[i] + k * v2[i])
      mu[i], work[i] = value, value
    end
    table.sort(work)
    local top = work[pick]
    local floorValue = top * (1 - K.estimateClusterTol)
    local count, vLo, vHi = 0, math.huge, 0
    for i = 1, n do
      if mu[i] >= floorValue then
        count = count + 1
        vLo, vHi = min(vLo, v2[i]), max(vHi, v2[i])
      end
    end
    if count > best.count then best = { count = count, mu = top, k = k, spread = vLo > 0 and sqrt(vHi / vLo) or 1 } end
  end
  return best.mu, best.k, best.spread
end

-- Estimations depuis un tour enregistré (§9.4). info : { mass (CSP), airTemp, track? }.
-- - puissance à la roue et traînée (Cx·S) : pleine charge en ligne droite,
--   m·(a + g·sin θ)·v = P − ½ρ·CxS·v³ ;
-- - adhérence et appui (Cz·S) : g latéral dans les virages, ay ≤ μ·n·g + μ·½ρ·CzS·v²/m, où n est le
--   facteur de charge dû à la pente, au dévers et aux compressions (enveloppe supérieure la plus
--   serrée : les virages pris avec marge restent dessous) ;
-- pente, dévers et compressions sont lus sur le modèle de circuit s'il est fourni ; la puissance est
-- ajustée sur l'enveloppe supérieure (phases de motricité et passages de rapport écartés) ;
-- - freinage maximal : décélération soutenue (informative) ;
-- - boîte : rapport total de chaque vitesse (régime / vitesse), régime maximal.
function M.estimate(lap, info, tick)
  tick = tick or function() end
  local m = info.mass
  if not Util.isFinite(m) or m <= 0 then return nil, 'masse CSP inconnue' end
  local G = 9.80665
  local rho = 101325 / (287.05 * (Util.finiteOr(info.airTemp, 20) + 273.15))
  local track = info.track
  local x1, x2, y = {}, {}, {}
  local l1, l2, ly = {}, {}, {}
  local decel, ratios, rpmTop = {}, {}, 0
  -- g latéral maximal du tour, robuste aux pics (vibreurs) : quantile élevé
  local all = {}
  for i = 1, lap.n do all[i] = abs(lap.ay[i]) end
  local ayMax = lap.n > 0 and quantile(all, K.estimateLateralQuantile) or 0
  for i = 1, lap.n do
    if i % K.estimateTickSamples == 0 then tick() end
    local v, ax, ay = lap.v[i], lap.ax[i], abs(lap.ay[i])
    local grade, nLoad = 0, 1
    if track then
      local k = TrackModel.indexAt(track, TrackModel.sAtProgress(track, lap.p[i]))
      local kap, phi = track.kappa[k], track.phi[k]
      if kap < 0 then phi = -phi end
      grade = math.sin(track.theta[k])
      nLoad = math.cos(track.theta[k]) * math.cos(phi) + v * v * (abs(kap) * math.sin(phi) + track.kappaV[k]) / G
    end
    if v > K.estimateMinSpeed and lap.gas[i] > 0.98 and lap.brake[i] < 0.02 and ay < K.estimateStraightAy then
      x1[#x1 + 1], x2[#x2 + 1], y[#y + 1] = 1, -0.5 * rho * v * v * v, m * (ax + G * grade) * v
    end
    if v > K.estimateMinSpeed and lap.brake[i] < 0.1 and ay > K.estimateCornerFraction * ayMax and nLoad > 0.3 then
      l1[#l1 + 1], l2[#l2 + 1], ly[#ly + 1] = nLoad * G, v * v, ay
    end
    if lap.brake[i] > 0.5 and ax < 0 then decel[#decel + 1] = -ax end
    local gear = lap.gear and lap.gear[i] or 0
    if gear >= 1 and gear <= K.maxGearRatios and v > K.estimateGearMinSpeed and lap.gas[i] > 0.5 and (lap.rpm[i] or 0) > 0 then
      ratios[gear] = ratios[gear] or {}
      ratios[gear][#ratios[gear] + 1] = lap.rpm[i] * 2 * math.pi / 60 / v
    end
    if (lap.rpm and lap.rpm[i] or 0) > rpmTop then rpmTop = lap.rpm[i] end
  end
  if #y < K.estimateMinSamples then return nil, 'pas assez de pleine charge en ligne droite' end
  local power, cdA = upperFit(x1, x2, y, K.estimateEnvelopePasses)
  if power == nil or power <= 0 or cdA <= 0 then return nil, 'puissance ou traînée non identifiables' end
  if #ly < K.estimateMinSamples then return nil, 'pas assez de virages' end
  tick()
  local mu0, kAero, spread = lateralFit(l1, l2, ly, K.estimateMaxClA * 0.5 * rho / m, tick)
  if mu0 == nil or mu0 <= 0 then return nil, 'adhérence latérale non identifiable' end
  local clA = kAero * m / (0.5 * rho)
  -- boîte : rapport total (rad/m) de chaque vitesse assez utilisée, médiane, dans l'ordre des
  -- vitesses (une vitesse jamais engagée, la 1re souvent, est simplement absente du modèle)
  local gearTotals = {}
  for g = 1, K.maxGearRatios do
    local list = ratios[g]
    if list and #list >= K.estimateMinSamples then gearTotals[#gearTotals + 1] = quantile(list, 0.5) end
  end
  if #gearTotals == 0 then return nil, 'boîte non identifiable (régime ou rapport illisibles)' end
  return {
    mass = m, power = power, cdA = cdA, mu = mu0, clA = clA, rho = rho,
    brakeDecel = #decel >= K.estimateMinSamples and quantile(decel, K.estimateLateralQuantile) or nil,
    lateralSamples = #ly, clAIdentified = spread >= K.estimateMinSpeedRatio, gearTotals = gearTotals,
    limiter = rpmTop > 0 and rpmTop or nil,
    samples = #y,
  }, nil
end

-- Modèle de voiture estimé (§9.4) : pneu à μ constant, appui et traînée constants (aile unique),
-- puissance constante sur la plage de régime, boîte estimée sur le tour (rapports totaux, pont à 1)
-- sauf si info.gears est fourni. info : { cgHeight, cgFront?, wheelRadius?, gears?, final?, limiter?,
-- rpmMin? }.
function M.measuredBase(e, info)
  local radius = Util.finiteOr(info.wheelRadius, K.estimateWheelRadius)
  local gears, final = info.gears, info.final
  if gears == nil or #gears == 0 then
    gears, final = {}, 1
    for g, total in ipairs(e.gearTotals or {}) do gears[g] = total * radius end
  end
  local tyre = {
    radius = radius, dyRef = e.mu, dxRef = e.mu, dcamber0 = 0, dcamber1 = 0, pressureDGain = 0, rr0 = 0, rr1 = 0,
    deformCamber = 0, pressureStatic = 26,
  }
  local xs, ys = {}, {}
  local limiter = Util.finiteOr(info.limiter, Util.finiteOr(e.limiter, 8000))
  local rpmMin = Util.finiteOr(info.rpmMin, limiter * K.estimateRpmMinFraction)
  for rpm = math.floor(rpmMin), math.floor(limiter), K.estimateRpmStep do
    xs[#xs + 1], ys[#ys + 1] = rpm, e.power / K.drivetrainEfficiency / (rpm * 2 * math.pi / 60)
  end
  local constant = function(value) return Util.lutNew({ -30, 30 }, { value, value }) end
  local base = CarModel.fromParams({
    massDry = e.mass, cgHeight = info.cgHeight, cgFront = info.cgFront or K.estimateCgFront, limiter = limiter, rpmMin = rpmMin,
    compounds = { { index = 0, name = 'estimé', front = tyre, rear = tyre } }, torque = Util.lutNew(xs, ys),
    gears = gears, final = final, fuelDefault = 0, brakeFront = 0.6,
    wings = { { index = 0, name = 'ESTIMÉ', area = 1, z = 0, cl = constant(e.clA), cd = constant(e.cdA), clGain = 1, cdGain = 1,
      angle = 0 } },
  })
  base.sources = { massDry = 'measured', cgHeight = 'measured', estimated = true }
  return base
end

-- Verdict de la validation en jeu (§14.1) : conforme si le gain mesuré est à K.validateTolAbs ou à
-- K.validateTolRel du gain prévu près (le plus large). Renvoie conforme, tolérance (s).
function M.verdict(predicted, measured)
  local tolerance = math.max(K.validateTolAbs, K.validateTolRel * math.abs(predicted))
  return math.abs(measured - predicted) <= tolerance, tolerance
end

return M
