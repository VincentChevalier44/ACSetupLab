-- Test du calcul sur un circuit de 20 km avec ERS (hors du cadre du §14.3, circuit de 6 km), seul dans son
-- fichier : URD sur la Nordschleife. Attendu : aucun échec, recherche complète (optimums raffinés,
-- réglages changés) ; la durée est seulement relevée (préparation ERS en régime établi comprise, A13).
local T = require('t')
local Budget = require('budget_common')

local tests = {}

tests['B04 URD avec ERS sur la Nordschleife : calcul complet sans échec, durée relevée'] = function()
  local r = Budget.run({ car = 'urd_px1_aura', track = 'ks_nordschleife-nordschleife', hostOpts = { kers = true }, ers = true,
    race = { fuelPerLapCsp = 9, kmPerLapF = 20, kmPerLapR = 20 } })
  PY.note('B04', 'URD avec ERS, Nordschleife : ' .. r.text)
  T.ok(r.refinedQ > 0 and r.refinedC > 0, 'optimums raffinés')
  T.ok(r.changesQ > 0 and r.changesC > 0, 'réglages changés')
end

return tests
