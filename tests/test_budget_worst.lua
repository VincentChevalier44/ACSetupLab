-- Test du budget de calcul dans le pire cas (§14.3, relecture J6b M2), seul dans son fichier :
-- environnement Lua neuf, aucun test mesuré avant lui. DTM à Monza, DRS simulé, rugosité mesurée
-- (ressorts, pilonnage, amortisseurs libérés) et hauteur de caisse libérée : le plus de variables et
-- la simulation la plus chère des voitures du banc.
local T = require('t')
local Budget = require('budget_common')

local tests = {}

tests['B03 budget dans le pire cas (§14.3) : DRS, rugosité et hauteur de caisse, < 90 s réelles'] = function()
  local r = Budget.run({ car = 'whk_dtm_2026', drs = true, roughness = 16e-6,
    release = { 'spring', 'heave', 'damperSlow', 'damperFast', 'rod' },
    race = { fuelPerLapCsp = 2.5, kmPerLapF = 5, kmPerLapR = 5 } })
  T.ok(r.drsUsable, 'DTM à DRS')
  PY.note('B03', 'DTM, Monza, DRS, rugosité, hauteur : ' .. r.text)
  -- qualité : la recherche a eu lieu (optimums raffinés, réglages changés), pas seulement la durée
  T.ok(r.refinedQ > 0 and r.refinedC > 0, 'optimums raffinés')
  T.ok(r.changesQ > 0 and r.changesC > 0, 'réglages changés')
  T.ok(r.calmTotal < 90, 'total ≈ ' .. r.calmTotal .. ' s réelles au calme (mesuré ' .. r.total .. ' s, charge ×' .. r.load .. ')')
end

return tests
