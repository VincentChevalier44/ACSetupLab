-- Tests de src/optimizer (J4, §10.4, §10.5) sur des objectifs synthétiques à optimum connu.
local T = require('t')
local Config = require('src/config')
local Util = require('src/util')
local Opt = require('src/optimizer')

local SYNC = Util.syncContext()
local tests = {}

local function dims(n, lo, hi)
  local list = {}
  for d = 1, n do list[d] = { key = 'v' .. d, lo = lo, hi = hi } end
  return list
end

-- Cuvette discrète : Σ w_d (x_d − c_d)², optimum entier c connu.
local function bowl(center, weights)
  return function(x)
    local sum = 0
    for d = 1, #center do sum = sum + weights[d] * (x[d] - center[d]) ^ 2 end
    return sum
  end
end

tests['O01 suite de Halton : valeurs publiées'] = function()
  local base2 = { 0.5, 0.25, 0.75, 0.125, 0.625, 0.375, 0.875 }
  for i, v in ipairs(base2) do T.near(Opt.radicalInverse(i, 2), v, 1e-15, 'base 2, terme ' .. i) end
  local base3 = { 1 / 3, 2 / 3, 1 / 9, 4 / 9, 7 / 9, 2 / 9, 5 / 9, 8 / 9 }
  for i, v in ipairs(base3) do T.near(Opt.radicalInverse(i, 3), v, 1e-15, 'base 3, terme ' .. i) end
  T.near(Opt.radicalInverse(6, 5), 0.24, 1e-15)
  T.near(Opt.radicalInverse(31, 2), 31 / 32, 1e-15)
end

tests['O02 cuvette discrète : optimum exact, budget respecté, grille respectée'] = function()
  local center, weights = { 3, -2, 0, 5, -6, 1 }, { 1, 2, 0.5, 1, 3, 0.2 }
  local f = bowl(center, weights)
  local calls = 0
  local problem = {
    dims = dims(6, -6, 6), budget = 600, seed = 7,
    evaluate = function(x)
      calls = calls + 1
      for d = 1, 6 do
        T.ok(x[d] >= -6 and x[d] <= 6 and x[d] == math.floor(x[d]), 'point sur la grille')
      end
      return f(x)
    end,
  }
  local state = Opt.run(problem, SYNC)
  T.ok(state.done)
  for d = 1, 6 do T.eq(state.chosen[d], center[d], 'optimum, dimension ' .. d) end
  T.eq(state.chosenJ, 0)
  T.ok(calls <= 600 and state.evaluations == calls, 'budget : ' .. calls .. ' évaluations')
  T.ok(state.currentJ == f({ 0, 0, 0, 0, 0, 0 }), 'setup actuel évalué')
end

tests['O03 recherche grossière moins chère, comptée dans le budget'] = function()
  local f = bowl({ 4, -4, 2 }, { 1, 1, 1 })
  local fine, coarse = 0, 0
  local state = Opt.run({
    dims = dims(3, -6, 6), budget = 200, seed = 3,
    evaluate = function(x) fine = fine + 1; return f(x) end,
    evaluateCoarse = function(x) coarse = coarse + 1; return f(x) + 0.1 end,
  }, SYNC)
  T.ok(coarse > 0 and fine > 0)
  T.ok(fine + coarse <= 200, 'budget total ' .. (fine + coarse))
  T.eq(state.evaluations, fine + coarse)
  T.eq(state.chosen[1], 4)
  T.eq(state.chosen[2], -4)
end

tests['O04 reproductible à graine égale'] = function()
  local f = bowl({ 2, -3, 4, 1 }, { 1, 0.3, 2, 1 })
  local function run(seed)
    local seq = {}
    local state = Opt.run({ dims = dims(4, -5, 5), budget = 150, seed = seed,
      evaluate = function(x) seq[#seq + 1] = table.concat(x, ','); return f(x) end }, SYNC)
    return table.concat(seq, ';'), state
  end
  local a, sa = run(11)
  local b, sb = run(11)
  T.eq(a, b, 'même suite d\'évaluations')
  T.eq(table.concat(sa.chosen, ','), table.concat(sb.chosen, ','))
  local c = run(12)
  T.ok(c ~= a, 'une autre graine explore autrement')
end

tests['O05 annulation : meilleur résultat intermédiaire disponible'] = function()
  local f = bowl({ 5, 5, -5 }, { 1, 1, 1 })
  local scheduler = Util.schedulerNew(0.9)
  local state = Opt.newState({ budget = 5000 })
  local evaluations = 0
  Util.schedulerAdd(scheduler, 'opt', function(ctx)
    return Opt.run({ dims = dims(3, -6, 6), budget = 5000, seed = 1,
      evaluate = function(x) evaluations = evaluations + 1; return f(x) end }, ctx, state)
  end)
  for _ = 1, 3 do Util.schedulerStep(scheduler, nil, 0, 20) end
  Util.schedulerCancel(scheduler)
  T.no(state.done, 'calcul interrompu')
  T.ok(evaluations > 0 and evaluations < 200)
  T.ok(state.best ~= nil and Util.isFinite(state.bestJ), 'meilleur intermédiaire')
  T.ok(state.bestJ <= f({ 0, 0, 0 }), 'jamais pire que le setup actuel')
end

tests['O06 départage : à moins de 0,02 s, le setup le plus proche de l\'actuel'] = function()
  local function problem(slope)
    return {
      dims = dims(1, -6, 6), budget = 100, seed = 1, tieSeconds = 0.02,
      evaluate = function(x)
        if x[1] <= 4 then return slope * (4 - x[1]) end
        return 1 + x[1]
      end,
      distance = function(x) return math.abs(x[1]) end,
    }
  end
  local flat = Opt.run(problem(0.004), SYNC)
  T.eq(flat.best[1], 4, 'meilleur temps à +4')
  T.eq(flat.chosen[1], 0, '0,016 s d\'écart : on garde le setup actuel')
  local steep = Opt.run(problem(0.0075), SYNC)
  T.eq(steep.chosen[1], 2, 'le plus proche à moins de 0,02 s du meilleur')
end

tests['O07 sensibilité et optimum en butée « à confirmer »'] = function()
  local state = Opt.run({
    dims = { { key = 'a', lo = -3, hi = 3 }, { key = 'b', lo = -3, hi = 3 } }, budget = 100, seed = 2,
    evaluate = function(x) return (x[1] - 1) ^ 2 - 0.5 * x[2] end,
  }, SYNC)
  T.eq(state.chosen[1], 1)
  T.eq(state.chosen[2], 3, 'meilleur sur la borne')
  T.no(state.sensitivity[1].atBound)
  T.ok(state.sensitivity[2].atBound, 'butée signalée')
  T.near(state.sensitivity[1].plus, 1, 1e-12)
  T.near(state.sensitivity[1].minus, 1, 1e-12)
  T.near(state.sensitivity[2].minus, 0.5, 1e-12)
end

tests['O08 aucun réglage optimisable ; objectif non fini'] = function()
  local n = 0
  local state = Opt.run({ dims = {}, budget = 50, evaluate = function() n = n + 1; return 12.5 end }, SYNC)
  T.eq(n, 1)
  T.eq(#state.chosen, 0)
  T.eq(state.chosenJ, 12.5)
  local nan = Opt.run({ dims = dims(2, -2, 2), budget = 60, seed = 1,
    evaluate = function(x) if x[1] == 1 then return 0 / 0 end return x[1] ^ 2 + x[2] ^ 2 end }, SYNC)
  T.eq(nan.chosen[1], 0)
  T.ok(Util.isFinite(nan.chosenJ))
end

tests['O09 robustesse : un optimum fragile cède la place, budget et réserve tenus'] = function()
  -- deux cuvettes : A (x = 4, J = 0) fragile, B (x = −4, J = 0,1) robuste
  local function f(x) return math.min((x[1] - 4) ^ 2, 0.1 + (x[1] + 4) ^ 2) + 0.01 * x[2] ^ 2 end
  local robustCalls = 0
  local state = Opt.run({
    dims = { { key = 'a', lo = -6, hi = 6 }, { key = 'b', lo = -3, hi = 3 } }, budget = 120, reserve = 40, seed = 5,
    evaluate = f, starts = { { -3, 1 } },
    robust = function(x)
      robustCalls = robustCalls + 1
      return x[1] > 0 and 0.5 or 0, 10
    end,
    robustCount = 3,
  }, SYNC)
  T.eq(state.best[1], 4, 'meilleur temps brut en A')
  T.eq(state.chosen[1], -4, 'choix robuste en B')
  T.ok(robustCalls >= 2 and robustCalls <= 5, robustCalls .. ' candidats examinés')
  T.ok(state.evaluations <= 120 + 10, 'budget : ' .. state.evaluations)
  T.near(state.chosenRobustPenalty, 0, 1e-12)
end

tests['O10 budget minimal : setup actuel toujours évalué, choix jamais vide'] = function()
  local f = bowl({ 3, -2, 0, 5, -6, 1 }, { 1, 2, 0.5, 1, 3, 0.2 })
  -- budget d'une évaluation, réserve plus grande que le budget, recherche grossière réelle
  local coarseCalls = 0
  local tiny = Opt.run({ dims = dims(6, -6, 6), budget = 1, reserve = 40, seed = 3, evaluate = f,
    evaluateCoarse = function(x) coarseCalls = coarseCalls + 1; return f(x) end }, SYNC)
  T.ok(tiny.done)
  T.ok(tiny.currentJ == f({ 0, 0, 0, 0, 0, 0 }), 'setup actuel évalué')
  T.ok(tiny.chosen ~= nil and tiny.chosenJ <= tiny.currentJ)
  T.eq(coarseCalls, 0, 'pas de recherche grossière sans budget')
  -- objectif jamais fini : choix = setup actuel, sans erreur
  local inf = Opt.run({ dims = dims(4, -3, 3), budget = 50, seed = 3, evaluate = function() return math.huge end }, SYNC)
  T.ok(inf.done)
  for d = 1, 4 do T.eq(inf.chosen[d], 0) end
  -- phases proportionnelles : avec un budget réduit, le raffinement a toujours lieu
  local small = Opt.run({ dims = dims(6, -6, 6), budget = 120, reserve = 30, seed = 7, evaluate = f,
    evaluateCoarse = f }, SYNC)
  T.ok(small.refined > 0, 'optimums raffinés')
  T.ok(small.chosenJ < small.currentJ, 'mieux que l\'actuel')
end


return tests
