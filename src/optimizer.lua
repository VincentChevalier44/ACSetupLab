-- SetupLab — optimiseur générique en crans (§10.4, §10.5). Noyau pur (D5).
--
-- Problème : dims = { { key, lo, hi }, … } (écarts entiers au setup actuel, 0 ∈ [lo, hi]) ;
-- evaluate(x) -> J (s) ; evaluateCoarse(x) facultatif (recherche grossière moins chère) ;
-- distance(x) -> écart au setup actuel (départage) ; budget (nombre total d'évaluations) ; seed ;
-- robust(x) -> pénalité (s), évaluations consommées : facultatif, appliqué aux meilleurs candidats
-- seulement (§10.2, P_robustesse) ; reserve : évaluations gardées pour la robustesse et la sensibilité.
--
-- 1. Point de départ : setup actuel (x = 0) et départs supplémentaires (heuristiques §10.1).
-- 2. Recherche grossière : suite de Halton à rotation aléatoire (Cranley–Patterson) sur la grille.
-- 3. Raffinement : descente de coordonnées à pas décroissants depuis les meilleurs points (toutes les
--    variables d'un setup AC sont discrètes : la phase Nelder–Mead « sur les variables continues » du
--    §10.4 est donc sans objet, arbitrage A15).
-- 4. Sélection : meilleur J ; à moins de tieSeconds du meilleur, le plus proche du setup actuel.
-- 5. Sensibilité : effet de ±1 cran de chaque variable autour du résultat.
-- L'état (meilleur point, progression) est lisible à tout moment ; annuler la tâche le conserve.

local Util = require('src/util')
local Config = require('src/config')
local CarModel = require('src/car_model')
local Sim = require('src/laptime_sim')
local Space = require('src/setup_space')
local StintSim = require('src/stint_sim')
local ErsPlan = require('src/ers_plan')
local Explain = require('src/explain')

local K = Config.K

local M = {}

local floor, min, max, abs = math.floor, math.min, math.max, math.abs

local PRIMES = { 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97, 101,
  103, 107, 109, 113, 127, 131, 137, 139, 149, 151 }
M.MAX_DIMS = #PRIMES

-- Terme i (≥ 1) de la suite de Van der Corput en base b (radical inverse).
function M.radicalInverse(i, b)
  local f, r = 1, 0
  while i > 0 do
    f = f / b
    r = r + f * (i % b)
    i = floor(i / b)
  end
  return r
end

-- Clé texte d'un point (mémorisation des évaluations).
local function keyOf(x, n)
  local parts = {}
  for d = 1, n do parts[d] = x[d] end
  return table.concat(parts, ',')
end

local function copy(x, n)
  local out = {}
  for d = 1, n do out[d] = x[d] end
  return out
end

-- Nouvel état d'optimisation (partagé avec l'interface).
function M.newState(problem)
  return {
    evaluations = 0, budget = problem.budget, best = nil, bestJ = math.huge, current = nil, currentJ = nil,
    phase = 'départ', done = false, sensitivity = {},
  }
end

-- Lance l'optimisation (dans une tâche découpée : evaluate rend la main via ctx.tick). Renvoie l'état.
function M.run(problem, ctx, state)
  state = state or M.newState(problem)
  local dims = problem.dims
  local n = #dims
  local budget = max(1, floor(problem.budget))
  local rng = Util.rngNew(problem.seed or 1)
  local memo, coarseMemo = {}, {}
  local evaluated = {}
  local tie = problem.tieSeconds or 0.02
  local limit = max(1, budget - (problem.reserve or 0))

  -- La réserve n'est entamée qu'après la recherche (sélection robuste et sensibilité). Le budget est
  -- en évaluations : les phases gardent leurs proportions (la durée se règle par le budget, avant).
  local function exhausted()
    return state.evaluations >= limit
  end

  -- Évaluation fine mémorisée (comptée dans le budget une seule fois par point) ; force : évaluée même
  -- budget épuisé (setup actuel : toujours connu).
  local function fine(x, force)
    local key = keyOf(x, n)
    local cached = memo[key]
    if cached then return cached end
    if exhausted() and not force then return nil end
    state.evaluations = state.evaluations + 1
    local J = problem.evaluate(x)
    if not Util.isFinite(J) then J = math.huge end
    memo[key] = J
    evaluated[#evaluated + 1] = { x = copy(x, n), J = J }
    if J < state.bestJ then
      state.best, state.bestJ = copy(x, n), J
    end
    ctx.tick()
    return J
  end

  local function coarse(x)
    if problem.evaluateCoarse == nil then return fine(x) end
    local key = keyOf(x, n)
    local cached = coarseMemo[key] or memo[key]
    if cached then return cached end
    if exhausted() then return nil end
    state.evaluations = state.evaluations + 1
    local J = problem.evaluateCoarse(x)
    if not Util.isFinite(J) then J = math.huge end
    coarseMemo[key] = J
    ctx.tick()
    return J
  end

  -- 1. Départs
  state.phase = 'départ'
  local zero = {}
  for d = 1, n do zero[d] = 0 end
  state.currentJ = fine(zero, true)
  local starts = { { x = zero, J = state.currentJ } }
  for _, extra in ipairs(problem.starts or {}) do
    local x = {}
    for d = 1, n do x[d] = Util.clamp(floor((extra[d] or 0) + 0.5), dims[d].lo, dims[d].hi) end
    local J = fine(x)
    if J then starts[#starts + 1] = { x = x, J = J } end
  end

  -- 2. Recherche grossière (Halton à rotation aléatoire, dimension par dimension)
  state.phase = 'recherche grossière'
  local shift = {}
  for d = 1, n do shift[d] = Util.rngNext(rng) end
  local coarseCount = n > 0 and floor(limit * (problem.coarseFraction or 0.4)) or 0
  local candidates = {}
  for i = 1, coarseCount do
    if exhausted() then break end
    local x = {}
    for d = 1, n do
      local u = (M.radicalInverse(i, PRIMES[d]) + shift[d]) % 1
      local span = dims[d].hi - dims[d].lo + 1
      x[d] = dims[d].lo + min(span - 1, floor(u * span))
    end
    local J = coarse(x)
    if J then candidates[#candidates + 1] = { x = x, J = J } end
  end
  table.sort(candidates, function(a, b) return a.J < b.J end)

  -- 3. Raffinement : descente de coordonnées depuis les meilleurs départs (réévalués en fin).
  state.phase = 'raffinement'
  local seeds = {}
  for _, s in ipairs(starts) do seeds[#seeds + 1] = s.x end
  local seen = {}
  for _, s in ipairs(seeds) do seen[keyOf(s, n)] = true end
  for _, c in ipairs(candidates) do
    if #seeds >= (problem.topK or 4) + #starts then break end
    local key = keyOf(c.x, n)
    if not seen[key] then
      seen[key] = true
      seeds[#seeds + 1] = c.x
    end
  end
  local order = {}
  for d = 1, n do order[d] = d end
  local optima = {}
  for _, seed in ipairs(seeds) do
    if exhausted() then break end
    local x = copy(seed, n)
    local J = fine(x)
    if J == nil then break end
    for _, step in ipairs(problem.steps or { 4, 2, 1 }) do
      local improved = true
      while improved and not exhausted() do
        improved = false
        for i = n, 2, -1 do
          local j = floor(Util.rngNext(rng) * i) + 1
          order[i], order[j] = order[j], order[i]
        end
        for _, d in ipairs(order) do
          for _, sign in ipairs({ 1, -1 }) do
            local value = x[d] + sign * step
            if value >= dims[d].lo and value <= dims[d].hi then
              local saved = x[d]
              x[d] = value
              local Jn = fine(x)
              if Jn == nil then
                x[d] = saved
                break
              end
              if Jn < J - 1e-9 then
                J = Jn
                improved = true
                break
              end
              x[d] = saved
            end
          end
        end
      end
    end
    optima[#optima + 1] = { x = copy(x, n), J = J }
  end

  -- 4. Sélection avec départage (§10.4) : à moins de tie du meilleur, le plus proche de l'actuel.
  --    Avec robust : pénalité de robustesse ajoutée au setup actuel, aux meilleurs optimums locaux (un
  --    par départ du raffinement : des setups réellement distincts, pas les voisins d'un même point) et
  --    au plus proche de l'actuel parmi les quasi-ex aequo ; la sélection se fait sur ce groupe.
  state.optima = optima
  state.refined = #optima
  state.phase = 'sélection'
  limit = budget
  local pool = evaluated
  if problem.robust then
    table.sort(optima, function(a, b) return a.J < b.J end)
    local group, inGroup = {}, {}
    local function addGroup(e)
      local key = keyOf(e.x, n)
      if e and not inGroup[key] then
        inGroup[key] = true
        group[#group + 1] = e
      end
    end
    for _, e in ipairs(evaluated) do
      if keyOf(e.x, n) == keyOf(zero, n) then addGroup(e) end
    end
    local distinct = 0
    for _, o in ipairs(optima) do
      if distinct >= (problem.robustCount or 3) then break end
      if not inGroup[keyOf(o.x, n)] then
        addGroup(o)
        distinct = distinct + 1
      end
    end
    if problem.distance then
      local closest, closestDist = nil, math.huge
      for _, e in ipairs(evaluated) do
        if e.J <= state.bestJ + tie then
          local dist = problem.distance(e.x)
          if dist < closestDist then closest, closestDist = e, dist end
        end
      end
      if closest then addGroup(closest) end
    end
    -- robustesse seulement si le budget restant la couvre (coût par candidat : problem.robustCost) ;
    -- sinon sélection sans robustesse, signalée (state.robustSkipped)
    if budget - state.evaluations < (problem.robustCost or 0) * (#group + 1) then
      state.robustSkipped = true
      group = {}
    else
      pool = {}
    end
    local bestRobust = math.huge
    for _, e in ipairs(group) do
      local penalty, used = problem.robust(e.x)
      state.evaluations = state.evaluations + (used or 0)
      local J = e.J + (Util.isFinite(penalty) and penalty or math.huge)
      pool[#pool + 1] = { x = e.x, J = J, robustPenalty = penalty }
      if J < bestRobust then bestRobust = J end
      ctx.tick()
    end
    state.bestRobustJ = bestRobust
  end
  local reference = (problem.robust and not state.robustSkipped) and state.bestRobustJ or state.bestJ
  local chosen, chosenJ, chosenDist = nil, math.huge, math.huge
  for _, e in ipairs(pool) do
    if e.J <= reference + tie then
      local dist = problem.distance and problem.distance(e.x) or 0
      if dist < chosenDist - 1e-12 or (abs(dist - chosenDist) <= 1e-12 and e.J < chosenJ) then
        chosen, chosenJ, chosenDist = e.x, e.J, dist
        state.chosenRobustPenalty = e.robustPenalty
      end
    end
  end
  if chosen == nil then chosen, chosenJ = state.best, state.bestJ end
  -- jamais de choix vide : au pire, le setup actuel (toujours évalué)
  if chosen == nil then chosen, chosenJ = zero, state.currentJ end
  state.chosen, state.chosenJ = chosen, chosenJ
  -- J de référence de la sensibilité : temps pénalisé sans robustesse (comparable aux voisins).
  local chosenFine = memo[keyOf(chosen, n)] or chosenJ

  -- 5. Sensibilité : ±1 cran autour du choix (dans le budget restant).
  state.phase = 'sensibilité'
  for d = 1, n do
    local entry = { key = dims[d].key }
    for _, sign in ipairs({ 1, -1 }) do
      local value = chosen[d] + sign
      if value >= dims[d].lo and value <= dims[d].hi then
        local x = copy(chosen, n)
        x[d] = value
        local J = fine(x)
        if J then entry[sign > 0 and 'plus' or 'minus'] = J - chosenFine end
      end
    end
    -- un optimum posé sur la borne du rayon de recherche est « à confirmer » (§0.6)
    entry.atBound = chosen[d] ~= 0 and (chosen[d] == dims[d].lo or chosen[d] == dims[d].hi)
    state.sensitivity[d] = entry
  end
  state.phase = 'terminé'
  state.done = true
  return state
end

-- ---------------------------------------------------------------------------
-- Qualification (§10.2, §10.6) : J_Q = t_tour + w_bal·P_équilibre + w_stab·P_stabilité
-- (+ w_rob·P_robustesse sur les candidats finaux)
-- ---------------------------------------------------------------------------

local FACTOR_KEYS = { 'mu', 'power', 'drag', 'lift', 'brake' }

-- Facteurs du modèle et facteurs perturbés de ±K.robustFactorDelta (robustesse, §10.2).
local function setFactors(p, factors)
  p.factors = factors or CarModel.defaultFactors()
  p.perturbed = {}
  for _, key in ipairs(FACTOR_KEYS) do
    for _, sign in ipairs({ 1, -1 }) do
      local f = {}
      for _, k in ipairs(FACTOR_KEYS) do f[k] = p.factors[k] end
      f[key] = f[key] * (1 + sign * K.robustFactorDelta)
      p.perturbed[#p.perturbed + 1] = f
    end
  end
end

-- Composés comparés (D18) : le composé monté (référence) et, sur piste sèche, tous les composés secs
-- (pluie et intermédiaires jamais choisis d'office sur le sec) ; sur piste mouillée (D16 amendé le
-- 21/10/2026, décision de Vincent), tous les composés (slicks, intermédiaires, pluie), départagés par le
-- modèle mouillé (H25 à H28) et la fenêtre de température mesurée. choice ≥ 0 impose un composé (index
-- CSP), sauf un composé pluie sur le sec. Renvoie la liste des positions, la position imposée (ou nil) et
-- une note.
function M.compoundCandidates(base, currentSlot, choice, wet)
  local list, seen = {}, {}
  local function add(slot)
    if slot and not seen[slot] then
      seen[slot] = true
      list[#list + 1] = slot
    end
  end
  add(currentSlot)
  for i, c in ipairs(base.compounds) do
    if wet or not CarModel.isWetCompound(c) then add(i) end
  end
  if choice and choice >= 0 then
    local slot = CarModel.compoundSlot(base, choice)
    if slot and not wet and CarModel.isWetCompound(base.compounds[slot]) then
      return list, nil, 'composé imposé de pluie refusé sur piste sèche : choix automatique'
    end
    if slot then return list, slot, nil end
    return list, nil, 'composé imposé (index ' .. choice .. ') absent : choix automatique'
  end
  return list, nil, nil
end

-- Facteurs de calibration utilisables d'un composé (index CSP), ou nil.
local function factorsOf(p, slot)
  local byCompound = p.args.factorsByCompound or {}
  local c = p.args.base.compounds[slot]
  return c and byCompound[c.index] or nil
end

-- Choix du composé : chaque candidat est évalué avec le setup actuel (evaluateZero renvoie J), avec
-- les mêmes facteurs pour tous (ceux du composé monté s'il est calibré : un composé non calibré ne
-- doit pas paraître meilleur du seul fait que la calibration réduit l'adhérence), et à la température
-- mesurée sur le composé monté quand un tour l'a relevée (sa courbe PERFORMANCE_CURVE dit ce qu'il y perd).
-- Constat de Vincent du 21/10/2026 : médium à ~90 °C, supersoft écarté d'office « hors de sa fenêtre »
-- alors qu'il y gardait ~97 % de son adhérence, plus que le médium ; plus aucun composé n'est écarté pour
-- sa fenêtre, l'écart est dit (même hypothèse : un autre composé chaufferait autant, à confirmer par un
-- tour). Le meilleur composé (sec sur le sec) est retenu, sauf composé imposé ou lock (raison de garder le
-- composé monté) ; à moins de K.compoundTieSeconds du meilleur, le composé monté est gardé. Facteurs de l'optimisation ensuite :
-- ceux du composé retenu s'il est calibré (§9.2), sinon ceux du composé monté, signalés comme
-- estimation. Renvoie la description du choix (p.setup.compound et p.factors positionnés).
local function chooseCompound(p, evaluateZero, lock)
  local base = p.args.base
  local wetTrack = p.conditions.bucket == 'pluie'
  local candidates, imposed, note = M.compoundCandidates(base, p.currentSlot, p.args.compoundChoice, wetTrack)
  local common = factorsOf(p, p.currentSlot)
  setFactors(p, common)
  local comparison, byslot = {}, {}
  local tF = p.tyres and p.tyres.F and Util.isFinite(p.tyres.F.temp) and p.tyres.F.temp or nil
  local tR = p.tyres and p.tyres.R and Util.isFinite(p.tyres.R.temp) and p.tyres.R.temp or nil
  local savedF, savedR = p.conditions.tyreTempF, p.conditions.tyreTempR
  local atMeasured = tF ~= nil and tR ~= nil
  if atMeasured then p.conditions.tyreTempF, p.conditions.tyreTempR = tF, tR end
  for _, slot in ipairs(candidates) do
    p.setup.compound = slot
    local J = evaluateZero(slot)
    local c = base.compounds[slot]
    -- sur piste mouillée, aucun composé n'est écarté pour son usage (wet : écarté d'office sur le sec)
    local entry = { slot = slot, index = c.index, name = c.name, short = c.short, J = J, use = c.use,
      wet = not wetTrack and CarModel.isWetCompound(c), conflict = slot ~= p.currentSlot and M.windowConflict(p, slot) or nil }
    comparison[#comparison + 1] = entry
    byslot[slot] = entry
  end
  p.conditions.tyreTempF, p.conditions.tyreTempR = savedF, savedR
  local chosen = imposed
  if chosen == nil and lock then
    chosen = p.currentSlot
    note = lock
  elseif chosen == nil then
    local bestJ = math.huge
    local outside = {}
    for _, e in ipairs(comparison) do
      if e.conflict and not e.wet then outside[#outside + 1] = e.conflict end
      if not e.wet and e.J < bestJ then chosen, bestJ = e.slot, e.J end
    end
    local current = byslot[p.currentSlot]
    if chosen == nil or (current and not current.wet and current.J <= bestJ + K.compoundTieSeconds) then
      chosen = p.currentSlot
    end
    if #outside > 0 then
      note = (note and (note .. ' ; ') or '') .. 'comparé(s) à la température mesurée, hors de leur fenêtre (à confirmer '
        .. 'par un tour : une gomme plus tendre peut chauffer davantage) : ' .. table.concat(outside, ' ; ')
    end
  end
  if imposed and byslot[imposed] and byslot[imposed].conflict then
    note = (note and (note .. ' ; ') or '') .. 'composé imposé hors de sa fenêtre — ' .. byslot[imposed].conflict
  end
  -- composé monté en surchauffe, gardé : un composé sec dont la fenêtre contient la température mesurée
  -- est signalé (les composés sont comparés au plateau de leur courbe, A19 : la surchauffe n'y coûte rien)
  if chosen == p.currentSlot then
    local hot = M.axleState(p, 'F', p.currentSlot) == 'surchauffe' or M.axleState(p, 'R', p.currentSlot) == 'surchauffe'
    if hot then
      for _, e in ipairs(comparison) do
        if e.slot ~= p.currentSlot and not e.wet and not e.conflict then
          note = (note and (note .. ' ; ') or '') .. 'composé monté en surchauffe : ' .. tostring(e.short or e.name)
            .. ' dans sa fenêtre à cette température, à essayer'
          break
        end
      end
    end
  end
  p.setup.compound = chosen
  local c = base.compounds[chosen]
  local own = factorsOf(p, chosen)
  setFactors(p, own or common)
  local calibrationNote = nil
  if own == nil and common ~= nil then
    calibrationNote = 'calibration du composé monté appliquée au composé retenu : à confirmer par un tour (§9.2)'
  elseif own == nil and next(p.args.factorsByCompound or {}) ~= nil then
    calibrationNote = 'calibration faite sur un autre composé : non appliquée (§9.2)'
  end
  return {
    measuredTempF = atMeasured and tF or nil, measuredTempR = atMeasured and tR or nil,
    slot = chosen, index = c.index, name = c.name, short = c.short, use = c.use, changed = chosen ~= p.currentSlot,
    imposed = imposed ~= nil, comparison = comparison, note = note, calibrationNote = calibrationNote,
    calibrated = own ~= nil, common = common,
  }
end

-- Carburant de qualification (§10.6), en écart de crans du réglage FUEL : plus petite quantité
-- couvrant tours × consommation par tour × (1 + marge), et au moins K.qualiFuelMinLiters. Tours :
-- fuelQualiLaps, ou K.qualiFuelLaps (sortie, tour lancé, retour) si 0 : le minimum « autorisé » de
-- setup.ini peut être 0 L, qui ne permet pas de rouler. Marge plus large si la consommation vient
-- du modèle non calibré plutôt que de la mesure CSP (prudence §0.6 : jamais de panne sèche).
function M.qualiFuel(space, settings, perLap, measured)
  local var = space.byKey.fuel
  if var == nil or not Util.isFinite(perLap) or perLap <= 0 then return nil end
  local laps = settings.fuelQualiLaps > 0 and settings.fuelQualiLaps or K.qualiFuelLaps
  local margin = measured and K.qualiFuelMarginMeasured or K.qualiFuelMarginModel
  local target = max(K.qualiFuelMinLiters, laps * perLap * (1 + margin))
  for d = var.rangeLo, var.rangeHi do
    local liters = Space.physical(var, d)
    if liters and liters >= target - 1e-9 then return d, liters, target end
  end
  return var.rangeHi, Space.physical(var, var.rangeHi), target
end

-- Prépare le problème. args : { base, space, track, trackCoarse?, conditions, settings, fuelPerLap?
-- (mesuré par CSP), compound (position du composé monté), compoundChoice (index imposé, -1 : choix
-- automatique), factorsByCompound? (index CSP -> facteurs de calibration utilisables), drs? (DRS simulé :
-- voiture et circuit, §8.9), budget, seed? }. En qualification, le DRS sert dans toutes les zones.
function M.prepareQuali(args)
  local p = { args = args, vars = Space.optimizable(args.space), deltas = {}, setup = CarModel.defaultSetup(args.base) }
  p.currentSlot = args.compound or p.setup.compound
  p.setup.compound = p.currentSlot
  p.dims = {}
  for i, var in ipairs(p.vars) do p.dims[i] = { key = var.key, lo = var.lo, hi = var.hi } end
  p.weights = Config.penaltyWeights(args.settings)
  p.conditions = {}
  for key, value in pairs(args.conditions or {}) do p.conditions[key] = value end
  p.conditions.driverMargin = (args.settings.driverMarginPct or 0) / 100
  p.drs = args.drs == true
  p.conditions.drs = p.drs
  -- ERS (§8.9) : plan de déploiement calculé au lancement du calcul
  local ers = args.base.ers
  p.ersSpec = (args.ers == true and ers and ers.usable) and ers or nil
  -- ABS actif (réglage du jeu, sinon electronics.ini) : pas de risque de blocage (H15)
  if args.absActive ~= nil then
    p.conditions.absActive = args.absActive == true
  else
    p.conditions.absActive = args.base.absPresent == true
  end
  -- Pneus mesurés (§8.6) : pression à chaud ancrée sur la mesure de chaque essieu (pneus en température) :
  -- loi des gaz à la température mesurée, plus l'écart mesuré à cette loi (H4 non vérifiée : AC peut
  -- s'en écarter de plusieurs psi). Sans mesure ancrée, recherche réduite sur la pression. Essieu en
  -- surchauffe : pression à froid jamais abaissée (garde-fou, §10.6 « pression qui limite la surchauffe »).
  p.tyres = args.tyres
  local anchored = {}
  for _, axle in ipairs({ 'F', 'R' }) do
    local t = args.tyres and args.tyres[axle]
    if t and t.state ~= 'froid' then
      p.conditions['pressureTemp' .. axle] = t.temp
      if t.offset and math.abs(t.offset) <= K.tyrePressureOffsetMax then
        p.conditions['pressureOffset' .. axle] = t.offset
        anchored[axle] = true
      end
    end
  end
  p.pressureAnchored = anchored
  M.tyreBounds(p)
  p.buf = Sim.new(args.track)
  p.bufCoarse = args.trackCoarse and Sim.new(args.trackCoarse) or nil
  setFactors(p, nil)
  return p
end

-- Évalue le point x (écarts des variables optimisées) sur un circuit : J et résultat de la simulation.
local function evaluateQuali(p, x, track, buf, factors, ctx)
  for i, var in ipairs(p.vars) do p.deltas[var.key] = x[i] end
  p.deltas.fuel = p.fuelDelta
  Space.apply(p.args.space, p.setup, p.deltas)
  p.conditions.factors = factors or p.factors
  local eff = CarModel.configure(p.args.base, p.setup, p.conditions, ctx.tick, p.eff)
  if eff == nil then return math.huge, nil end
  p.eff = eff
  -- §8.5 : hauteur minimale réglementaire, contrainte dure
  if eff.belowMinHeight then return math.huge, nil end
  local result = Sim.run(track, eff, buf, track == p.args.track and p.simOpts or p.simOptsCoarse)
  local balance, stability = Sim.penalties(result)
  return result.time + p.weights.bal * balance + p.weights.stab * stability, result
end

-- Bilan du DRS d'une qualification (§8.9) : temps actuels et proposés avec et sans DRS ; part du gain
-- due au DRS ; avertissement si le setup proposé n'est meilleur qu'avec le DRS (le sens d'EFFECT, H8,
-- n'est pas confirmé). Renvoie nil si une simulation manque.
function M.drsReport(zones, current, proposed, currentNo, proposedNo)
  if not (current and proposed and currentNo and proposedNo) then return nil end
  local gain, gainNo = current.time - proposed.time, currentNo.time - proposedNo.time
  return {
    zones = zones, timeCurrentNoDrs = currentNo.time, timeProposedNoDrs = proposedNo.time, gainNoDrs = gainNo,
    share = gain - gainNo, openTime = proposed.drsTime, vTop = proposed.vTop, vTopOpen = proposed.vTopOpen,
    warning = gainNo < 0 and 'sans DRS, le setup proposé serait plus lent que l\'actuel : gain dépendant de l\'hypothèse '
      .. 'H8 (effet du DRS à confirmer en jeu)' or nil,
  }
end

-- Pression à chaud (même conversion que le modèle) d'un écart d de crans de la pression d'un essieu,
-- avec le composé du calcul (le composé monté, puis le composé retenu).
local function hotPressureOf(p, var, d)
  local compound = p.args.base.compounds[p.setup.compound] or p.args.base.compounds[1]
  local tyre = var.axle == 'F' and compound.front or compound.rear
  local cold = Space.physical(var, d)
  if cold == nil then return nil, tyre end
  local temp = p.conditions['pressureTemp' .. var.axle] or CarModel.runningTemp(tyre, p.conditions)
  return CarModel.hotPressure(cold, p.conditions.airTemp, temp) + (p.conditions['pressureOffset' .. var.axle] or 0), tyre
end

-- Bande admissible des crans de pression (§8.6, §10.6) : la pression à chaud proposée ne s'éloigne jamais
-- de PRESSURE_IDEAL plus que l'actuelle (à K.tyreHotTolerance près). Sans cette contrainte, l'optimiseur
-- se sert de la pression comme d'un réglage d'équilibre (seule une perte d'adhérence est modélisée,
-- pas la chauffe ni l'usure) et l'éloigne de plusieurs psi de l'idéale. Renvoie lo, hi.
function M.pressureBand(p, var, lo, hi)
  local current, tyre = hotPressureOf(p, var, 0)
  if current == nil or tyre.pressureIdeal == nil then return lo, hi end
  local allowed = max(math.abs(current - tyre.pressureIdeal), K.tyreHotTolerance) + 1e-9
  local newLo, newHi = 0, 0
  for d = lo, hi do
    local hot = hotPressureOf(p, var, d)
    if hot and math.abs(hot - tyre.pressureIdeal) <= allowed then
      newLo, newHi = min(newLo, d), max(newHi, d)
    end
  end
  return newLo, newHi
end

-- État d'un essieu contre la fenêtre du composé slot : 'froid', 'fenêtre' ou 'surchauffe', et la fenêtre
-- (lo, hi) ; nil sans température mesurée. La température mesurée avec le composé monté est supposée la
-- même avec un autre composé (à confirmer par un tour).
function M.axleState(p, axle, slot)
  local t = p.tyres and p.tyres[axle]
  local compound = p.args.base.compounds[slot]
  if t == nil or not Util.isFinite(t.temp) or compound == nil then return nil end
  local lo, hi = CarModel.tyreWindow(axle == 'F' and compound.front or compound.rear)
  if hi and (t.tempMax or t.temp) > hi then return 'surchauffe', lo, hi end
  if lo and t.temp < lo then return 'froid', lo, hi end
  return 'fenêtre', lo, hi
end

-- Composé dont la fenêtre exclut la température mesurée d'un essieu en température (avec le composé
-- monté) : raison, ou nil. Sert à écarter un composé non monté (§8.6 : un composé plus tendre retenu
-- au plateau de sa courbe, A19, surchaufferait).
function M.windowConflict(p, slot)
  for _, axle in ipairs({ 'F', 'R' }) do
    local t = p.tyres and p.tyres[axle]
    if t and Util.isFinite(t.temp) and t.state ~= 'froid' then
      local state, lo, hi = M.axleState(p, axle, slot)
      if state and state ~= 'fenêtre' then
        local c = p.args.base.compounds[slot]
        return tostring(c.short or c.name) .. ' : ' .. Util.fmt(t.temp, 0) .. ' °C mesurés ' .. (axle == 'F' and 'à l\'avant'
          or 'à l\'arrière') .. ', fenêtre ' .. Util.fmt(lo, 0) .. '–' .. Util.fmt(hi, 0) .. ' °C ('
          .. (state == 'surchauffe' and 'surchauffe' or 'trop froid') .. ')'
      end
    end
  end
  return nil
end

-- Bornes des crans de pression et de carrossage (§8.6, §10.6) pour le composé du calcul (p.setup.compound),
-- recalculées après le choix du composé : fenêtre et idéale sont celles du composé retenu. Pression :
-- recherche réduite sans mesure ancrée ; essieu en surchauffe, pression à froid jamais abaissée ; bande
-- autour de l'idéale. Carrossage : écart intérieur − extérieur mesuré (le sens des crans est lu sur la
-- conversion). args.pinned (clé de réglage -> vrai) : réglages retouchés par le pilote, figés à leur valeur.
function M.tyreBounds(p)
  local slot = p.setup.compound
  for i, var in ipairs(p.vars) do
    local dim = p.dims[i]
    if var.kind == 'pressure' then
      dim.lo, dim.hi = var.lo, var.hi
      if not p.pressureAnchored[var.axle] then
        dim.lo, dim.hi = max(dim.lo, -K.optRadiusReduced), min(dim.hi, K.optRadiusReduced)
      end
      if M.axleState(p, var.axle, slot) == 'surchauffe' then dim.lo = max(dim.lo, 0) end
      dim.lo, dim.hi = M.pressureBand(p, var, dim.lo, dim.hi)
    elseif var.kind == 'camber' then
      dim.lo, dim.hi = var.lo, var.hi
      local t = p.tyres and p.tyres[var.axle]
      local up = (Space.physical(var, 1) or 0) > (Space.physical(var, 0) or 0)
      if t and t.spread and t.spread > K.camberSpreadMax then
        if up then dim.lo = max(dim.lo, 0) else dim.hi = min(dim.hi, 0) end
      elseif t and t.spread and t.spread < K.camberSpreadMin then
        if up then dim.hi = min(dim.hi, 0) else dim.lo = max(dim.lo, 0) end
      end
    end
  end
  -- réglages retouchés à la main après un chargement (décision de Vincent du 22/10/2026 : « si je le modifie
  -- un petit peu, c'est que je suis plus à l'aise pour conduire ») : gardés à la valeur du pilote
  local pinned = p.args.pinned
  if pinned then
    for i, var in ipairs(p.vars) do
      if pinned[var.key] then p.dims[i].lo, p.dims[i].hi = 0, 0 end
    end
  end
end

-- Pneus, par essieu (§8.6) : température mesurée contre la fenêtre, pression à chaud prévue (setup actuel
-- et proposé, même conversion que le modèle), idéale et mesurée, garde-fou de surchauffe. Renvoie
-- { F, R, measured } (sans tour mesuré : température au plateau, signalée).
function M.tyreReport(p, deltas)
  local args = p.args
  local base = args.base
  local compound = base.compounds[p.setup.compound] or base.compounds[1]
  local out = { measured = p.tyres ~= nil }
  for _, axle in ipairs({ 'F', 'R' }) do
    local tyre = axle == 'F' and compound.front or compound.rear
    local var = args.space.byKey['pressure' .. axle]
    local t = p.tyres and p.tyres[axle] or {}
    local lo, hi = CarModel.tyreWindow(tyre)
    local temp = p.conditions['pressureTemp' .. axle] or CarModel.runningTemp(tyre, p.conditions)
    local offset = p.conditions['pressureOffset' .. axle] or 0
    local function hotOf(d)
      local cold = var and Space.physical(var, d) or nil
      return cold and CarModel.hotPressure(cold, p.conditions.airTemp, temp) + offset or nil
    end
    local camberGuard = nil
    if t.spread and t.spread > K.camberSpreadMax then
      camberGuard = 'intérieur plus chaud de ' .. Util.fmt(t.spread, 0) .. ' °C : carrossage jamais plus négatif'
    elseif t.spread and t.spread < K.camberSpreadMin then
      camberGuard = 'extérieur plus chaud de ' .. Util.fmt(-t.spread, 0) .. ' °C : carrossage jamais moins négatif'
    end
    local state = M.axleState(p, axle, p.setup.compound)
    out[axle] = {
      camberGuard = camberGuard,
      temp = t.temp, tempUsed = temp, measuredTemp = p.conditions['pressureTemp' .. axle] ~= nil, lo = lo, hi = hi,
      state = state, stateMounted = t.state, spread = t.spread, hotMeasured = t.hot, ideal = tyre.pressureIdeal,
      hotCurrent = hotOf(0),
      hotProposed = hotOf(var and deltas[var.key] or 0), offset = p.conditions['pressureOffset' .. axle],
      anchored = p.pressureAnchored and p.pressureAnchored[axle] == true, gasLawGap = t.offset,
      guard = state == 'surchauffe' and 'surchauffe mesurée : pression à froid jamais abaissée' or nil,
    }
  end
  return out
end

-- Réserve (robustesse, sensibilité) d'un budget, plafonnée : un petit budget doit d'abord servir à chercher.
local function reserveOf(budget, n, p)
  return min(3 * n + (K.optRobustCount + 2) * (#p.perturbed + 1) + 2, floor(budget * K.optReserveFraction))
end

-- Copie d'un setup physique (le plan ERS ne doit pas voir les écarts essayés ensuite).
local function copySetup(setup)
  local out = {}
  for key, value in pairs(setup) do out[key] = value end
  return out
end

-- Setup actuel sous la hauteur minimale de la voiture avec ce carburant (MIN_HEIGHT contrôlée au repos par
-- AC ; relecture J6b, M3) : avertissement, ou nil. Le setup actuel n'est jamais refusé pour autant.
function M.minHeightWarning(p, fuel)
  if not Util.isFinite(fuel) then return nil end
  for _, var in ipairs(p.vars) do p.deltas[var.key] = 0 end
  p.deltas.fuel = nil
  local setup = Space.apply(p.args.space, copySetup(p.setup), p.deltas)
  setup.compound, setup.fuel = p.currentSlot, fuel
  local eff = CarModel.configure(p.args.base, setup, p.conditions, nil, nil)
  if eff and eff.currentBelowMinHeight then
    return 'Avec ' .. Util.fmt(fuel, 0) .. ' L, le setup actuel passerait sous la hauteur minimale de la voiture (MIN_HEIGHT '
      .. Util.fmt((p.args.base.minHeight or 0) * 1000, 0) .. ' mm) : hauteur à vérifier au stand avant de sortir.'
  end
  return nil
end

-- Plan ERS du setup physique courant de p (§8.9) : masque de déploiement fixé pour la recherche (le
-- plan est refait pour le setup proposé), report sur le tracé grossier. Renvoie le plan, ou nil.
local function ersPlanFor(p, mode, ctx)
  if p.ersSpec == nil then return nil end
  local conditions = {}
  for key, value in pairs(p.conditions) do conditions[key] = value end
  conditions.ersSpec = nil
  local plan = ErsPlan.plan({ spec = p.ersSpec, base = p.args.base, setup = copySetup(p.setup), conditions = conditions,
    track = p.args.track, mode = mode, tick = ctx.tick })
  return plan
end

-- Bilan ERS d'un calcul (§8.9) : plans du setup actuel et du setup proposé.
function M.ersReport(current, proposed)
  if current == nil or proposed == nil then return nil end
  local function view(plan)
    return {
      timeNone = plan.timeNone, timeDefault = plan.timeDefault, timeOptimized = plan.timeOptimized,
      profileName = plan.profileName, defaultProfile = plan.defaultProfile, bestProfile = plan.bestProfile,
      deployed = plan.summary.deployed, recovered = plan.summary.recovered, socStart = plan.socStart,
      socEnd = plan.summary.socEnd, socMin = plan.summary.socMin, capacity = plan.capacity, maxPerLap = plan.maxPerLap,
      zones = plan.zones, fallbackDefault = plan.fallbackDefault, mode = plan.mode,
    }
  end
  return { current = view(current), proposed = view(proposed) }
end

-- Copie sous-échantillonnée d'un profil de vitesse (affichage, §12.1).
function M.profile(track, buf)
  local out = { s = {}, v = {}, length = track.length }
  local step = max(1, floor(track.n / K.profilePoints))
  for k = 1, track.n, step do
    out.s[#out.s + 1] = track.s[k]
    out.v[#out.v + 1] = buf.v[k]
  end
  return out
end

-- Calcul complet (dans une tâche découpée). Renvoie le résultat, ou nil et la raison ; state
-- (M.newState) est mis à jour en continu et reste lisible si la tâche est annulée.
function M.runQuali(p, ctx, state)
  local args = p.args
  p.simOpts, p.simOptsCoarse = { tick = ctx.tick }, { tick = ctx.tick }
  local n = #p.vars
  local zero = {}
  for i = 1, n do zero[i] = 0 end
  -- Carburant : consommation mesurée par CSP si disponible, sinon celle du modèle au setup actuel
  -- (composé monté, facteurs de sa calibration s'il en a une).
  setFactors(p, factorsOf(p, p.currentSlot))
  local _, first = evaluateQuali(p, zero, args.track, p.buf, nil, ctx)
  if first == nil then return nil, 'setup actuel non simulable' end
  -- la plus grande des deux consommations (CSP et modèle) : une mesure trop basse ou mal interprétée
  -- ne doit jamais réduire le carburant (§0.6)
  local perLap, perLapSource = first.fuel, 'modèle'
  if Util.isFinite(args.fuelPerLap) and args.fuelPerLap > 0 and (perLap == nil or args.fuelPerLap >= perLap) then
    perLap, perLapSource = args.fuelPerLap, 'CSP'
  end
  p.fuelDelta, p.fuelLiters, p.fuelTarget = M.qualiFuel(args.space, args.settings, perLap, perLapSource == 'CSP')
  -- Composé (D18) au carburant de qualification, puis facteurs de l'optimisation.
  state.phase = 'composés'
  p.compound = chooseCompound(p, function() return (evaluateQuali(p, zero, args.track, p.buf, nil, ctx)) end)
  M.tyreBounds(p)
  -- ERS : plan du setup actuel (composé retenu, carburant de qualification), masque fixé pour la recherche
  local ersCurrent = nil
  if p.ersSpec then
    state.phase = 'ERS'
    for _, var in ipairs(p.vars) do p.deltas[var.key] = 0 end
    p.deltas.fuel = p.fuelDelta
    Space.apply(args.space, p.setup, p.deltas)
    ersCurrent = ersPlanFor(p, 'quali', ctx)
    if ersCurrent then
      p.conditions.ersSpec = p.ersSpec
      p.simOpts.ersMask = ersCurrent.mask
      if args.trackCoarse then p.simOptsCoarse.ersMask = ErsPlan.resample(ersCurrent.mask, args.track, args.trackCoarse) end
    end
  end
  -- réserve (robustesse, sensibilité) plafonnée : un petit budget doit d'abord servir à chercher
  local reserve = reserveOf(args.budget, n, p)
  local robustBase = nil
  local problem = {
    dims = p.dims, budget = args.budget, seed = args.seed or K.optSeed, reserve = reserve,
    coarseFraction = K.optCoarseFraction, topK = K.optTopK, tieSeconds = K.optTieSeconds, robustCount = K.optRobustCount,
    robustCost = #p.perturbed + 1,
    evaluate = function(x) return (evaluateQuali(p, x, args.track, p.buf, nil, ctx)) end,
    distance = function(x)
      for i, var in ipairs(p.vars) do p.deltas[var.key] = x[i] end
      return Space.distance(p.vars, p.deltas)
    end,
  }
  -- P_robustesse : perte de temps sous facteurs ±3 %, au-delà de celle du setup actuel.
  problem.robust = function(x)
    local used = 0
    local function losses(point)
      local _, ref = evaluateQuali(p, point, args.track, p.buf, nil, ctx)
      used = used + 1
      local out = {}
      for i, f in ipairs(p.perturbed) do
        local _, r = evaluateQuali(p, point, args.track, p.buf, f, ctx)
        used = used + 1
        out[i] = (r and ref) and (r.time - ref.time) or math.huge
      end
      return out
    end
    if robustBase == nil then robustBase = losses(zero) end
    local mine = losses(x)
    local worst = 0
    for i = 1, #mine do worst = max(worst, mine[i] - robustBase[i]) end
    return p.weights.rob * worst, used
  end
  if args.trackCoarse then
    problem.evaluateCoarse = function(x) return (evaluateQuali(p, x, args.trackCoarse, p.bufCoarse, nil, ctx)) end
  end
  M.run(problem, ctx, state)
  -- Résultat : temps actuels et proposés (sans pénalités), changements et contribution de chacun.
  local chosen = state.chosen
  -- setup actuel : avec le composé monté et les facteurs communs de la comparaison des composés (le
  -- gain affiché comprend le changement de composé)
  local common = p.compound.common or CarModel.defaultFactors()
  p.setup.compound = p.currentSlot
  p.simOpts.recordBalance = true
  local Jc, current = evaluateQuali(p, zero, args.track, p.buf, common, ctx)
  local currentProfile = M.profile(args.track, p.buf)
  -- statistiques du tour et équilibre par virage (explications, §12.1–12.2)
  local stats = Explain.trackStats(args.track, p.buf)
  local cornersCurrent = Explain.cornerBalance(args.track, p.buf)
  p.setup.compound = p.compound.slot
  local Jp, proposed = evaluateQuali(p, chosen, args.track, p.buf, common, ctx)
  local proposedProfile = M.profile(args.track, p.buf)
  local cornersProposed = Explain.cornerBalance(args.track, p.buf)
  p.simOpts.recordBalance = nil
  -- métriques d'un tour simulé pour l'explication d'un réglage
  local function metrics(result, var)
    if result == nil then return {} end
    local out = { balance = result.balanceMean, rearLock = result.rearFirstShare, vMax = result.vMax }
    if var.kind == 'pressure' and p.eff then
      out.hot = var.axle == 'F' and p.eff.hotF or p.eff.hotR
      local tyre = var.axle == 'F' and p.eff.tyreF or p.eff.tyreR
      out.ideal = tyre and tyre.pressureIdeal
    end
    return out
  end
  local afterBase = proposed
  local changes = {}
  for i, var in ipairs(p.vars) do
    if chosen[i] ~= 0 then
      local after = metrics(afterBase, var)
      if var.kind == 'pressure' then
        evaluateQuali(p, chosen, args.track, p.buf, common, ctx)
        after = metrics(afterBase, var)
      end
      local x = {}
      for j = 1, n do x[j] = chosen[j] end
      x[i] = 0
      local Jwithout, without = evaluateQuali(p, x, args.track, p.buf, common, ctx)
      local sens = state.sensitivity[i] or {}
      local change = {
        var = var, clicks = chosen[i], from = Space.physical(var, 0), to = Space.physical(var, chosen[i]),
        contribution = Jwithout - Jp, atBound = sens.atBound == true,
      }
      change.explanation = Explain.change(change, { stats = stats, before = metrics(without, var), after = after })
      changes[#changes + 1] = change
    end
  end
  table.sort(changes, function(a, b) return a.contribution > b.contribution end)
  -- DRS (§8.9) : temps sans DRS, part du gain qui lui revient ; le sens d'EFFECT n'étant pas confirmé
  -- (H8), un setup qui ne serait meilleur qu'avec le DRS est signalé
  local drs = nil
  if p.drs and current and proposed then
    p.conditions.drs = false
    p.setup.compound = p.currentSlot
    local _, currentNo = evaluateQuali(p, zero, args.track, p.buf, common, ctx)
    p.setup.compound = p.compound.slot
    local _, proposedNo = evaluateQuali(p, chosen, args.track, p.buf, common, ctx)
    p.conditions.drs = true
    drs = M.drsReport(p.buf.drsZoneCount, current, proposed, currentNo, proposedNo)
  end
  local deltas = {}
  for i, var in ipairs(p.vars) do deltas[var.key] = chosen[i] end
  if p.fuelDelta then deltas.fuel = p.fuelDelta end
  local fuelVar = args.space.byKey.fuel
  -- ERS : plan refait pour le setup proposé
  local ers = nil
  if ersCurrent then
    for i, var in ipairs(p.vars) do p.deltas[var.key] = chosen[i] end
    p.deltas.fuel = p.fuelDelta
    Space.apply(args.space, p.setup, p.deltas)
    p.setup.compound = p.compound.slot
    ers = M.ersReport(ersCurrent, ersPlanFor(p, 'quali', ctx))
  end
  return {
    deltas = deltas, changes = changes, chosenJ = state.chosenJ, currentJ = Jc, proposedJ = Jp, drs = drs, ers = ers,
    tyres = M.tyreReport(p, deltas), stats = stats, cornersCurrent = cornersCurrent, cornersProposed = cornersProposed,
    minHeightWarning = M.minHeightWarning(p, p.fuelLiters), absActive = p.conditions.absActive,
    timeCurrent = current and current.time, timeProposed = proposed and proposed.time,
    balanceCurrent = current and current.balanceMean, balanceProposed = proposed and proposed.balanceMean,
    rearLockCurrent = current and current.rearFirstShare, rearLockProposed = proposed and proposed.rearFirstShare,
    fuel = { delta = p.fuelDelta, liters = p.fuelLiters, target = p.fuelTarget, perLap = perLap, source = perLapSource,
      from = fuelVar and Space.physical(fuelVar, 0) or nil },
    profileCurrent = currentProfile, profileProposed = proposedProfile,
    evaluations = state.evaluations, budget = args.budget, robustPenalty = state.chosenRobustPenalty,
    refined = state.refined,
    robustSkipped = state.robustSkipped == true,
    calibrated = p.compound.calibrated, calibrationNote = p.compound.calibrationNote, compound = p.compound,
    factorsUsed = p.compound.common,
  }
end


-- ---------------------------------------------------------------------------
-- Course (§10.2, §10.6, §8.7) : J_C = t_relais/N + w_trafic·P_trafic + w_bal·P_équilibre
-- + w_stab·P_stabilité (+ w_rob·P_robustesse sur les candidats finaux), stabilité et robustesse
-- renforcées en course (K.raceStabFactor, K.raceRobFactor)
-- ---------------------------------------------------------------------------

-- Écart de crans du réglage FUEL donnant au moins liters (le plus petit), borné à la plage du cran.
function M.fuelDelta(space, liters)
  local var = space.byKey.fuel
  if var == nil then return nil, nil end
  for d = var.rangeLo, var.rangeHi do
    local value = Space.physical(var, d)
    if value and value >= liters - 1e-9 then return d, value end
  end
  return var.rangeHi, Space.physical(var, var.rangeHi)
end

-- Nombre de tours de la course : réglage, sinon durée réglée, sinon séance de course du week-end
-- (tours, ou durée : ⌈durée / tour prévu⌉ + 1, plus le tour additionnel) ; à défaut, durée supposée
-- (signalée). Données de séance bornées (D11). Renvoie tours, source, supposée.
function M.raceLaps(settings, sessions, lapTime)
  if settings.raceLaps > 0 then return min(settings.raceLaps, K.raceMaxLaps), 'réglage', false end
  local valid = Util.isFinite(lapTime) and lapTime > 0
  local function byTime(minutes, extra)
    return min(K.raceMaxLaps, math.ceil(min(minutes, K.raceMaxMinutes) * 60 / lapTime) + 1 + extra)
  end
  if settings.raceMinutes > 0 and valid then
    return byTime(settings.raceMinutes, 0), 'durée réglée (' .. Util.fmt(settings.raceMinutes, 0) .. ' min)', false
  end
  for _, s in ipairs(sessions or {}) do
    if s.type == K.sessionTypeRace then
      if s.isTimedRace and Util.isFinite(s.durationMinutes) and s.durationMinutes > 0 and valid then
        return byTime(s.durationMinutes, s.hasAdditionalLap and 1 or 0),
          'séance de course (' .. Util.fmt(s.durationMinutes, 0) .. ' min)', false
      elseif Util.isFinite(s.laps) and s.laps > 0 then
        return min(floor(s.laps), K.raceMaxLaps), 'séance de course', false
      end
    end
  end
  return K.raceDefaultLaps, 'supposée : aucune course dans la séance, régler la durée', true
end

-- Prépare le problème. args : ceux de prepareQuali, plus race = { sessions (séances du week-end),
-- fuelPerLapCsp?, fuelPerLapMeasured?, kmPerLapF?, kmPerLapR? (mesurés), lapTimeMeasured? (meilleur tour
-- valide du setup de référence), wearRate? (session), slipstream? (assistance d'aspiration, 0–1) }.
function M.prepareRace(args)
  local p = M.prepareQuali(args)
  p.race = args.race or {}
  p.bufCoarse = nil
  -- en course, le DRS ne sert que sur les tours en trafic (plan du relais)
  p.conditions.drs = false
  return p
end

local function finitePositive(x)
  return Util.isFinite(x) and x > 0
end

-- Plan du relais et carburant de course (§10.6).
-- Consommation par tour : mesurée sur un tour du setup de référence, sinon CSP, sinon modèle (marge
-- supplémentaire) ; jamais sous la valeur CSP ; bornée (D11). Inconnue : carburant actuel conservé.
-- Sans mesure ni CSP, le carburant ne descend jamais sous l'actuel (§0.6). Relais limité par le
-- réservoir (plage du cran FUEL), ou par le carburant actuel si le cran n'est pas réglable.
-- Durée : tour prévu = le plus court du meilleur tour mesuré et du tour simulé (facteurs calibrés).
local function racePlan(p, lapTime, modelPerLap)
  local args, race = p.args, p.race
  if finitePositive(race.lapTimeMeasured) and race.lapTimeMeasured < lapTime then lapTime = race.lapTimeMeasured end
  local laps, lapsSource, assumed = M.raceLaps(args.settings, race.sessions, lapTime)
  local csp = finitePositive(race.fuelPerLapCsp) and race.fuelPerLapCsp or nil
  local perLap, source = nil, nil
  if finitePositive(race.fuelPerLapMeasured) then
    perLap, source = race.fuelPerLapMeasured, 'mesure'
  elseif csp then
    perLap, source = csp, 'CSP'
  elseif finitePositive(modelPerLap) then
    perLap, source = modelPerLap, 'modèle'
  end
  if perLap and csp and csp > perLap then perLap, source = csp, 'CSP (plancher)' end
  if perLap then perLap = min(perLap, K.raceMaxFuelPerLap) end
  local margin = args.settings.fuelMarginPct / 100 + (source == 'modèle' and K.raceFuelMarginModel or 0)
  local var = args.space.byKey.fuel
  local current = p.setup.fuel
  local need = perLap and perLap * (1 + margin) or 0
  local stintLaps = laps
  local fuelDelta, fuelStart, note = nil, current, nil
  if perLap == nil then
    note = 'consommation inconnue : carburant actuel conservé (rouler un tour pour la mesurer)'
  elseif var == nil then
    if need > 0 then stintLaps = Util.clamp(floor(current / need), 1, laps) end
    note = 'carburant non réglable dans le setup : ' .. Util.fmt(laps * need, 1) .. ' L nécessaires'
  else
    local tank = Space.physical(var, var.rangeHi)
    if need > 0 and tank and tank > 0 then stintLaps = Util.clamp(floor(tank / need), 1, laps) end
    local target = stintLaps * need
    if source == 'modèle' and current and current > target then
      target = current
      note = 'consommation estimée par le modèle : carburant jamais réduit sous l\'actuel (§0.6)'
    end
    fuelDelta, fuelStart = M.fuelDelta(args.space, target)
  end
  -- usure : km virtuels par tour mesurés (setup de référence), sinon longueur × taux d'usure (à confirmer)
  local kmF, kmR, kmSource = race.kmPerLapF, race.kmPerLapR, 'mesure'
  if not (Util.isFinite(kmF) and Util.isFinite(kmR) and kmF >= 0 and kmR >= 0) then
    local rate = Util.clamp(Util.finiteOr(race.wearRate, 1), 0, K.maxSessionRate)
    kmF = args.track.length / 1000 * rate * K.raceWearKmPerLapDefault
    kmR, kmSource = kmF, 'longueur × taux d\'usure (à confirmer)'
  end
  local slip = Util.clamp(Util.finiteOr(race.slipstream, 1), 0, 1)
  local plan = StintSim.plan({
    laps = stintLaps, fuelStart = fuelStart, fuelPerLap = perLap or 0, kmPerLapF = kmF, kmPerLapR = kmR,
    trafficFraction = args.settings.drsTrafficPct / 100, slipstreamDrag = K.raceSlipstreamDrag * slip,
    dirtyAirLift = K.raceDirtyAirLift, drs = p.drs,
  })
  local info = {
    laps = laps, lapsSource = lapsSource, assumed = assumed, stintLaps = stintLaps, stops = math.ceil(laps / stintLaps) - 1,
    lapTime = lapTime, fuelStart = fuelStart, fuelDelta = fuelDelta, fuelPerLap = perLap, fuelSource = source or 'inconnue',
    fuelNote = note, margin = margin, kmPerLapF = kmF, kmPerLapR = kmR, kmSource = kmSource,
    trafficFraction = plan.trafficFraction, slipstream = slip, tyreTemp = 'plateau de la courbe de performance (A19)',
    drs = p.drs,
  }
  return plan, info
end

-- Calcul complet (dans une tâche découpée) ; mêmes conventions que runQuali.
function M.runRace(p, ctx, state)
  local args = p.args
  p.simOpts = { tick = ctx.tick }
  local n = #p.vars
  local zero = {}
  for i = 1, n do zero[i] = 0 end
  -- tour du setup actuel (composé monté, carburant actuel, facteurs de sa calibration) : temps prévu et
  -- consommation du modèle
  for _, var in ipairs(p.vars) do p.deltas[var.key] = 0 end
  p.deltas.fuel = nil
  Space.apply(args.space, p.setup, p.deltas)
  p.setup.compound = p.currentSlot
  p.conditions.factors = factorsOf(p, p.currentSlot)
  local eff = CarModel.configure(args.base, p.setup, p.conditions, ctx.tick, nil)
  if eff == nil then return nil, 'setup actuel non simulable' end
  local first = Sim.run(args.track, eff, p.buf, p.simOpts)
  local plan, info = racePlan(p, first.time, first.fuel)
  p.fuelDelta = info.fuelDelta
  -- ERS : plan de course (régime établi) du setup actuel au carburant de course, masque fixé pour le relais
  local ersCurrent = nil
  if p.ersSpec then
    state.phase = 'ERS'
    p.deltas.fuel = p.fuelDelta
    Space.apply(args.space, p.setup, p.deltas)
    ersCurrent = ersPlanFor(p, 'race', ctx)
    if ersCurrent then p.conditions.ersSpec = p.ersSpec end
  end
  local weights = {
    bal = p.weights.bal, stab = p.weights.stab, traffic = p.weights.traffic, rob = p.weights.rob * K.raceRobFactor,
  }
  local ev = StintSim.newEvaluator({ base = args.base, track = args.track, conditions = p.conditions, plan = plan,
    compound = p.currentSlot, weights = weights, tick = ctx.tick })
  local evCoarse = args.trackCoarse and StintSim.newEvaluator({ base = args.base, track = args.trackCoarse,
    conditions = p.conditions, plan = plan, compound = p.currentSlot, weights = weights, tick = ctx.tick }) or nil
  if ersCurrent then
    ev.simOpts.ersMask = ersCurrent.mask
    if evCoarse then evCoarse.simOpts.ersMask = ErsPlan.resample(ersCurrent.mask, args.track, args.trackCoarse) end
  end
  local function apply(x)
    for i, var in ipairs(p.vars) do p.deltas[var.key] = x[i] end
    p.deltas.fuel = p.fuelDelta
    Space.apply(args.space, p.setup, p.deltas)
  end
  local function stint(x, evaluator, extra)
    apply(x)
    return StintSim.evaluate(evaluator, p.setup, extra)
  end
  -- Critère sur le relais exact (tous les tours) : temps moyen exact, plus les pénalités et le trafic de
  -- l'évaluation échantillonnée. Sert à choisir le composé et au contrôle final.
  local function exactJ(x, slot, factors)
    StintSim.setCompound(ev, slot)
    StintSim.setFactors(ev, factors)
    local J, detail = stint(x, ev)
    if detail == nil then return math.huge, nil end
    apply(x)
    local exact = StintSim.runExact(ev, p.setup)
    if exact == nil then return math.huge, nil end
    return J - detail.mean + exact.mean, exact, detail
  end
  -- composé (D18) : comparé sur le relais exact ; sans usure mesurée, le composé monté est gardé (le
  -- choix reposerait sur un taux d'usure supposé, §0.6)
  state.phase = 'composés'
  local lock = info.kmSource ~= 'mesure' and 'usure non mesurée : composé monté conservé (comparatif indicatif)' or nil
  p.compound = chooseCompound(p, function(slot) return (exactJ(zero, slot, p.factors)) end, lock)
  M.tyreBounds(p)
  local common = p.compound.common
  for _, e in ipairs({ ev, evCoarse }) do
    StintSim.setCompound(e, p.compound.slot)
    StintSim.setFactors(e, p.factors)
  end
  local reserve = reserveOf(args.budget, n, p)
  local robustBase = nil
  local problem = {
    dims = p.dims, budget = args.budget, seed = args.seed or K.optSeed, reserve = reserve,
    coarseFraction = K.optCoarseFraction, topK = K.optTopK, tieSeconds = K.optTieSeconds, robustCount = K.optRobustCount,
    robustCost = #p.perturbed + 1,
    evaluate = function(x) return (stint(x, ev)) end,
    distance = function(x)
      for i, var in ipairs(p.vars) do p.deltas[var.key] = x[i] end
      return Space.distance(p.vars, p.deltas)
    end,
  }
  if evCoarse then problem.evaluateCoarse = function(x) return (stint(x, evCoarse)) end end
  -- P_robustesse : perte de temps du tour du milieu de relais sous facteurs ±3 %, au-delà de celle du
  -- setup actuel
  problem.robust = function(x)
    local used = 0
    local function losses(point)
      local ref = stint(point, ev, ev.factors)
      used = used + 1
      local out = {}
      for i, f in ipairs(p.perturbed) do
        out[i] = stint(point, ev, f) - ref
        used = used + 1
      end
      return out
    end
    if robustBase == nil then robustBase = losses(zero) end
    local mine = losses(x)
    local worst = 0
    for i = 1, #mine do worst = max(worst, mine[i] - robustBase[i]) end
    return weights.rob * worst, used
  end
  M.run(problem, ctx, state)
  -- Résultat sur relais exacts, setup actuel (composé monté) et proposé, avec les mêmes facteurs (ceux de
  -- la comparaison des composés) ; contrôle final : jamais plus lent que l'actuel.
  state.phase = 'relais exacts'
  local chosen = state.chosen
  local Jc, stintCurrent = exactJ(zero, p.currentSlot, common)
  local Jp, stintProposed, detail = exactJ(chosen, p.compound.slot, common)
  -- référence du contrôle : setup actuel avec le composé monté, ou avec le composé imposé (choix de
  -- l'utilisateur, respecté)
  local refSlot = p.compound.imposed and p.compound.slot or p.currentSlot
  local Jref = refSlot == p.currentSlot and Jc or exactJ(zero, refSlot, common)
  local fallback = nil
  if not (Jp <= Jref + 1e-9) then
    fallback = 'relais exact du setup proposé (' .. Util.fmt(Jp, 3) .. ') pas meilleur que l\'actuel (' .. Util.fmt(Jref, 3)
      .. ') : setup actuel conservé, carburant de course seulement'
    chosen = zero
    local c = args.base.compounds[refSlot]
    p.compound = { slot = refSlot, index = c.index, name = c.name, short = c.short, changed = refSlot ~= p.currentSlot,
      imposed = p.compound.imposed, comparison = p.compound.comparison, note = fallback,
      calibrationNote = p.compound.calibrationNote, calibrated = p.compound.calibrated, common = common }
    Jp, stintProposed, detail = exactJ(zero, refSlot, common)
  end
  -- profils et équilibre par virage (§12.1) sur le dernier tour échantillonné du relais, setup actuel
  -- (composé monté) puis proposé ; ses statistiques servent aux explications
  StintSim.setFactors(ev, common)
  ev.simOpts.recordBalance = true
  StintSim.setCompound(ev, p.currentSlot)
  stint(zero, ev)
  local profileCurrent = M.profile(args.track, ev.buf)
  local cornersCurrent = Explain.cornerBalance(args.track, ev.buf)
  StintSim.setCompound(ev, p.compound.slot)
  local JpSampled = stint(chosen, ev)
  local profileProposed = M.profile(args.track, ev.buf)
  local cornersProposed = Explain.cornerBalance(args.track, ev.buf)
  ev.simOpts.recordBalance = nil
  local raceStats = Explain.trackStats(args.track, ev.buf)
  local changes = {}
  for i, var in ipairs(p.vars) do
    if chosen[i] ~= 0 then
      local x = {}
      for j = 1, n do x[j] = chosen[j] end
      x[i] = 0
      local Jwithout = stint(x, ev)
      local sens = state.sensitivity[i] or {}
      local change = {
        var = var, clicks = chosen[i], from = Space.physical(var, 0), to = Space.physical(var, chosen[i]),
        contribution = Jwithout - JpSampled, atBound = sens.atBound == true,
      }
      change.explanation = Explain.change(change, { stats = raceStats })
      changes[#changes + 1] = change
    end
  end
  table.sort(changes, function(a, b) return a.contribution > b.contribution end)
  local deltas = {}
  for i, var in ipairs(p.vars) do deltas[var.key] = chosen[i] end
  if p.fuelDelta then deltas.fuel = p.fuelDelta end
  local fuelVar = args.space.byKey.fuel
  info.fuelFrom = fuelVar and Space.physical(fuelVar, 0) or nil
  local ers = nil
  if ersCurrent then
    apply(chosen)
    p.setup.compound = p.compound.slot
    ers = M.ersReport(ersCurrent, ersPlanFor(p, 'race', ctx))
  end
  return {
    deltas = deltas, changes = changes, chosenJ = state.chosenJ, currentJ = Jc, proposedJ = Jp, fallback = fallback,
    tyres = M.tyreReport(p, deltas), ers = ers, minHeightWarning = M.minHeightWarning(p, info.fuelStart),
    absActive = p.conditions.absActive,
    timeCurrent = stintCurrent and stintCurrent.mean, timeProposed = stintProposed and stintProposed.mean,
    stintCurrent = stintCurrent, stintProposed = stintProposed, traffic = detail and detail.traffic, race = info,
    profileCurrent = profileCurrent, profileProposed = profileProposed, cornersCurrent = cornersCurrent,
    cornersProposed = cornersProposed, stats = raceStats,
    evaluations = state.evaluations, budget = args.budget, robustPenalty = state.chosenRobustPenalty,
    refined = state.refined,
    robustSkipped = state.robustSkipped == true, samples = #ev.samples,
    calibrated = p.compound.calibrated, calibrationNote = p.compound.calibrationNote, compound = p.compound,
    factorsUsed = common,
  }
end

return M
