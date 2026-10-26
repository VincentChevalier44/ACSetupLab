-- Tous les réglages de chaque voiture pris en compte (demande de Vincent du 26/10/2026 : « tout ce qui est paramétrable
-- doit absolument être pris en compte ») : chaque réglage du setup des voitures du banc est optimisé, ou conservé avec
-- une raison précise ; aucun n'est « non reconnu ». Le profil du circuit (virages par vitesse, chicanes, lignes droites)
-- est calculé à la découverte.
local T = require('t')
local Fake = require('fakehost')
local SetupSpace = require('src/setup_space')

local tests = {}

tests['CV01 chaque réglage de chaque voiture : optimisé ou conservé avec sa raison, jamais inconnu'] = function()
  for _, car in ipairs({ 'formula_k', 'lamborghini_huracan_gt3_evo2', 'urd_px1_aura', 'whk_dtm_2026' }) do
    local h = Fake.new({ car = require('fixtures/cars/' .. car), track = require('fixtures/tracks/monza') })
    Fake.install(h)
    assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
    local app = rawget(_G, 'SETUPLAB').app
    for _ = 1, 4000 do
      h.sim.time = h.sim.time + 16.7
      script.SETUPLAB__UPDATE(0.0167)
      if app.discoveryState == 'done' then break end
    end
    T.eq(app.discoveryState, 'done', car)
    local rows = SetupSpace.statusRows(app.discovery.space)
    local counts = { optimized = 0, kept = 0 }
    for _, row in ipairs(rows) do
      if row.status == 'optimisé' then
        counts.optimized = counts.optimized + 1
      else
        counts.kept = counts.kept + 1
        T.ok(type(row.detail) == 'string' and #row.detail > 10, car .. ' : raison de ' .. row.label)
        T.no(row.detail:find('non reconnu', 1, true), car .. ' : réglage non reconnu ' .. table.concat(row.names, ','))
      end
    end
    PY.note('CV01 ' .. car, counts.optimized .. ' optimisés, ' .. counts.kept .. ' conservés')
    T.ok(counts.optimized >= 15, car .. ' : au moins 15 réglages optimisés')
    local p = app.discovery.trackProfile
    T.ok(p and p.corners > 0 and p.lent + p.moyen + p.rapide == p.corners and p.longest > 0, car .. ' : profil du circuit')
    T.eq(app.perf.errors, 0)
  end
end

return tests
