-- SetupLab — plan de déploiement de l'ERS (§8.9). Noyau pur (D5).
--
-- 1. Tour sans déploiement : profil de vitesse, zones d'accélération, énergie récupérable.
-- 2. Stratégie par défaut de la voiture : profil du cockpit (ctrl_ers_N), batterie rejouée le long du
--    tour (charge jamais négative, limite par tour), tour resimulé.
-- 3. Options par zone : part de la zone déployée depuis son début (¼, ½, ¾, toute), ou le déploiement
--    effectif du profil par défaut dans la zone ; gain et énergie de chacune par simulation.
-- 4. Programmation dynamique sur la charge de la batterie (Ers.optimize) ; qualification : batterie
--    pleine au départ (supposé, signalé) ; course : régime établi (charge finale ≥ charge de départ) ;
--    en course, la stratégie de la voiture et les profils sont évalués eux aussi en régime établi.
-- 5. Tour resimulé avec le masque retenu, batterie rejouée sur ce tour (le masque effectif est celui
--    que la batterie permet) ; le résultat retenu est le meilleur du plan et de la stratégie par défaut
--    (§14.3 : jamais moins bien que la voiture).

local Config = require('src/config')
local CarModel = require('src/car_model')
local Sim = require('src/laptime_sim')
local Ers = require('src/ers')

local K = Config.K

local M = {}

local max, min, ceil = math.max, math.min, math.ceil

M.FRACTIONS = { 0.25, 0.5, 0.75, 1 }
M.RACE_START_LEVELS = 8

local function zeros(n, out)
  out = out or {}
  for k = 1, n do out[k] = 0 end
  return out
end

-- Récupération entre la fin de la zone j et le début de la suivante (bouclage du tour).
local function recoveries(track, runs, rec)
  local n = track.n
  local out = {}
  for j, run in ipairs(runs) do
    local nextRun = runs[j % #runs + 1]
    local sum, k = 0, run.last % n + 1
    while k ~= nextRun.first do
      sum = sum + rec[k]
      k = k % n + 1
    end
    out[j] = sum
  end
  return out
end

-- Énergie demandée par un masque sur une zone (kJ).
local function zoneEnergy(run, mask, arrays, n)
  local e, k = 0, run.first
  for _ = 1, run.count do
    e = e + mask[k] * arrays.pFull[k] * arrays.dt[k]
    k = k % n + 1
  end
  return e
end

-- Rejoue la batterie sur le profil d'un tour simulé et resimule avec le masque effectif ; deux passes
-- (le profil change avec le déploiement). steady (course) : tours rejoués en enchaînant la charge de fin
-- de tour jusqu'au régime établi (une stratégie qui vide la batterie n'est évaluée qu'une fois vide).
-- Renvoie le résultat, le masque effectif, le bilan et la charge de départ du tour retenu.
local function settle(ctx, mask, soc0, steady)
  local track, n = ctx.track, ctx.track.n
  local effective = {}
  for k = 1, n do effective[k] = mask[k] end
  local result, summary = nil, nil
  local laps = steady and K.ersSteadyLaps or 2
  for _ = 1, laps do
    result = Sim.run(track, ctx.eff, ctx.work, { tick = ctx.tick, ersMask = effective })
    local arrays = Ers.arrays(ctx.spec, ctx.eff, track, ctx.work, ctx.arraysWork)
    local out = {}
    summary = Ers.replay(n, ctx.start, mask, arrays.pFull, arrays.dt, arrays.rec,
      { capacity = ctx.capacity, maxPerLap = ctx.maxPerLap, soc0 = soc0 }, out)
    effective = out
    if steady then
      local drift = summary.socEnd - soc0
      soc0 = summary.socEnd
      if math.abs(drift) <= K.ersSteadyTolerance then break end
    end
  end
  result = Sim.run(track, ctx.eff, ctx.work, { tick = ctx.tick, ersMask = effective })
  return result, effective, summary, steady and soc0 or nil
end

-- Plan ERS d'un setup. args : { spec (Ers.read), base, setup, conditions, track, mode ('quali' |
-- 'race'), tick? }. Renvoie le plan, ou nil et la raison.
function M.plan(args)
  local spec, track = args.spec, args.track
  if not (spec and spec.usable) then return nil, spec and spec.reason or 'pas d\'ERS' end
  local conditions = {}
  for key, value in pairs(args.conditions or {}) do conditions[key] = value end
  conditions.ersSpec = spec
  local eff = CarModel.configure(args.base, args.setup, conditions, args.tick)
  if eff == nil or not eff.ersOn then return nil, 'setup non simulable' end
  local n = track.n
  local tick = args.tick or function() end
  local ctx = { spec = spec, eff = eff, track = track, tick = tick, work = Sim.new(track), arraysWork = {},
    capacity = eff.ersCapacity, maxPerLap = eff.ersMaxPerLap }
  if not (ctx.capacity > 0 and ctx.maxPerLap > 0) then return nil, 'batterie de capacité nulle (DISCHARGE_TIME, couple)' end
  -- 1. tour sans déploiement
  local baseBuf = Sim.new(track)
  local none = Sim.run(track, eff, baseBuf, { tick = tick, ersMask = zeros(n) })
  ctx.start = none.kMin
  local arrays = Ers.arrays(spec, eff, track, baseBuf, {})
  local runs = Ers.runs(track, baseBuf, ctx.start)
  if #runs == 0 then return nil, 'aucune zone d\'accélération' end
  local recovery = recoveries(track, runs, arrays.rec)
  local race = args.mode == 'race'
  -- 2. stratégie par défaut (profil du cockpit), batterie pleine en qualification ; en course, charge de
  -- départ au milieu (régime établi recherché par le plan)
  local soc0 = race and ctx.capacity / 2 or ctx.capacity
  local defaultMask = Ers.profileMask(spec, spec.defaultProfile, eff, track, baseBuf, {})
  local defaultResult, defaultEffective, defaultSummary, defaultStart = settle(ctx, defaultMask, soc0, race)
  -- 3. options par zone
  local mask = zeros(n)
  local stages = {}
  for j, run in ipairs(runs) do
    tick()
    local options = { { gain = 0, energy = 0 } }
    for _, fraction in ipairs(M.FRACTIONS) do
      local count = max(1, ceil(fraction * run.count))
      local k = run.first
      for _ = 1, count do
        mask[k] = 1
        k = k % n + 1
      end
      local r = Sim.run(track, eff, ctx.work, { tick = tick, ersMask = mask })
      options[#options + 1] = { gain = none.time - r.time, energy = zoneEnergy(run, mask, arrays, n), fraction = fraction }
      zeros(n, mask)
    end
    local k = run.first
    for _ = 1, run.count do
      mask[k] = defaultEffective[k]
      k = k % n + 1
    end
    local r = Sim.run(track, eff, ctx.work, { tick = tick, ersMask = mask })
    options[#options + 1] = { gain = none.time - r.time, energy = zoneEnergy(run, mask, arrays, n), profile = true }
    zeros(n, mask)
    stages[j] = { options = options, recovery = recovery[j] }
  end
  -- 4. programmation dynamique : pas d'énergie fixe, arrondi au plus proche (la batterie est rejouée
  -- ensuite sur le tour retenu, qui fait foi)
  local levels = min(K.ersMaxLevels, max(10, ceil(ctx.capacity / K.ersEnergyStep)))
  local dLevels = min(K.ersMaxLevels, max(10, ceil(ctx.maxPerLap / K.ersEnergyStep)))
  local function dp(start, endMin)
    return Ers.optimize(stages, { capacity = ctx.capacity, maxPerLap = ctx.maxPerLap, soc0 = start, socEndMin = endMin,
      levels = levels, dLevels = dLevels, nearest = true, tick = tick })
  end
  local best, choice, socStart = nil, nil, soc0
  if race then
    for level = 0, M.RACE_START_LEVELS do
      local start = ctx.capacity * level / M.RACE_START_LEVELS
      local gain, c = dp(start, start)
      if gain and (best == nil or gain > best) then best, choice, socStart = gain, c, start end
    end
  else
    best, choice = dp(soc0, nil)
  end
  -- 5. masque retenu, tour resimulé, batterie rejouée ; meilleur du plan et de la stratégie par défaut
  local zones = {}
  if choice then
    for j, run in ipairs(runs) do
      local option = stages[j].options[choice[j]]
      local k = run.first
      local count = option.fraction and max(1, ceil(option.fraction * run.count)) or run.count
      for i = 1, run.count do
        if option.profile then
          mask[k] = defaultEffective[k]
        elseif option.fraction and i <= count then
          mask[k] = 1
        end
        k = k % n + 1
      end
      if option.fraction or option.profile then
        zones[#zones + 1] = { s0 = track.s[run.first], s1 = track.s[run.last], fraction = option.fraction,
          profile = option.profile == true, gain = option.gain, energy = option.energy }
      end
    end
  end
  local planResult, planEffective, planSummary = settle(ctx, mask, socStart)
  local useDefault = planResult.time > defaultResult.time
  local plan = {
    timeNone = none.time, timeDefault = defaultResult.time,
    timeOptimized = useDefault and defaultResult.time or planResult.time,
    mask = useDefault and defaultEffective or planEffective,
    summary = useDefault and defaultSummary or planSummary, defaultSummary = defaultSummary,
    zones = zones, fallbackDefault = useDefault, socStart = useDefault and (defaultStart or soc0) or socStart,
    capacity = ctx.capacity, maxPerLap = ctx.maxPerLap, mode = race and 'race' or 'quali',
    defaultProfile = spec.defaultProfile, profileName = spec.profiles[spec.defaultProfile]
      and spec.profiles[spec.defaultProfile].name or nil,
    predictedGain = best,
  }
  -- profils du cockpit comparés (stratégie de la voiture, batterie rejouée)
  plan.profiles = {}
  for index, profile in pairs(spec.profiles) do
    tick()
    local pmask = Ers.profileMask(spec, index, eff, track, baseBuf, {})
    local r, _, summary = settle(ctx, pmask, soc0, race)
    plan.profiles[#plan.profiles + 1] = { index = index, name = profile.name, time = r.time, deployed = summary.deployed,
      recovered = summary.recovered }
  end
  table.sort(plan.profiles, function(a, b) return a.index < b.index end)
  local bestProfile = nil
  for _, p in ipairs(plan.profiles) do
    if bestProfile == nil or p.time < bestProfile.time then bestProfile = p end
  end
  plan.bestProfile = bestProfile
  return plan
end

-- Masque d'un tracé reporté sur un autre (même circuit, pas différent : point le plus proche en s).
function M.resample(mask, from, to, out)
  out = out or {}
  local j = 1
  for k = 1, to.n do
    local s = to.s[k]
    while j < from.n and from.s[j + 1] <= s do j = j + 1 end
    local a, b = j, min(j + 1, from.n)
    out[k] = (math.abs(from.s[b] - s) < math.abs(from.s[a] - s)) and mask[b] or mask[a]
  end
  return out
end

return M
