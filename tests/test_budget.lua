-- Test du budget de calcul (§14.3), seul dans son fichier : environnement Lua neuf, aucun test mesuré
-- avant lui (tas et état du JIT représentatifs de l'app seule).
local T = require('t')
local Budget = require('budget_common')

local tests = {}

tests['B01 budget total (§14.3) : qualification + course < 90 s réelles sur un circuit de 6 km'] = function()
  local r = Budget.run({ car = 'lamborghini_huracan_gt3_evo2', race = { fuelPerLapCsp = 3, kmPerLapF = 5.8, kmPerLapR = 5.8 } })
  PY.note('B01', 'Huracán, Monza : ' .. r.text)
  -- qualité : la recherche a eu lieu (optimums raffinés, réglages changés), pas seulement la durée
  T.ok(r.refinedQ > 0 and r.refinedC > 0, 'optimums raffinés')
  T.ok(r.changesQ > 0 and r.changesC > 0, 'réglages changés')
  T.ok(r.calmTotal < 90, 'total ≈ ' .. r.calmTotal .. ' s réelles au calme (mesuré ' .. r.total .. ' s, charge ×' .. r.load .. ')')
end

return tests
