-- Test du budget de calcul avec ERS (§14.3), seul dans son fichier : environnement Lua neuf, aucun test
-- mesuré avant lui (tas et état du JIT représentatifs de l'app seule).
local T = require('t')
local Budget = require('budget_common')

local tests = {}

tests['B02 budget avec ERS (§14.3) : plans de déploiement compris, < 90 s réelles'] = function()
  local r = Budget.run({ car = 'urd_px1_aura', hostOpts = { kers = true }, ers = true,
    race = { fuelPerLapCsp = 2.5, kmPerLapF = 5, kmPerLapR = 5 } })
  PY.note('B02', 'URD avec ERS, Monza : ' .. r.text)
  -- qualité : la recherche a eu lieu (optimums raffinés, réglages changés), pas seulement la durée
  T.ok(r.refinedQ > 0 and r.refinedC > 0, 'optimums raffinés')
  T.ok(r.changesQ > 0 and r.changesC > 0, 'réglages changés')
  T.ok(r.calmTotal < 90, 'total ≈ ' .. r.calmTotal .. ' s réelles au calme (mesuré ' .. r.total .. ' s, charge ×' .. r.load .. ')')
end

return tests
