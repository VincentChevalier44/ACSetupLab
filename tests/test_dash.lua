-- Pages « Racing 26 » (src/dash.lua, maquette de Vincent ; décision du 03/11/2026 : « tout refaire, puis publier ») : chaque
-- état du parcours dessiné sur les 7 onglets, l'overlay et la fenêtre Debug, étroit et large, en français et en anglais,
-- sans erreur ni identifiant ImGui en double (le faux hôte les refuse) ; les actions gardent leurs identifiants.
local T = require('t')
local Fake = require('fakehost')

local tests = {}

local STORE = { en = 'setuplab-store 1|settings#language=s:en', fr = 'setuplab-store 1|settings#language=s:fr' }
local TABS = { 'Tour rapide', 'Course', 'Mémoire', 'Mesure', 'Réglages', 'Capacités', 'Aide' }

local function boot(lang)
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza'),
    skin = true, lang = lang, stored = { ['setuplab:data'] = STORE[lang] } })
  h.sim.raceSessionType = 1
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  app.utcOffset = function() return 7200 end
  app.settings.optBudgetEvalsQ, app.settings.optBudgetEvalsC = 60, 20
  app.settings.refineMinLaps = 0
  return h, app
end

local function frames(h, n)
  for _ = 1, n do
    h.sim.time = h.sim.time + 1000 / 60
    script.SETUPLAB__UPDATE(1 / 60)
    script.SETUPLAB__MAIN(1 / 60)
  end
end

local function waitFor(h, predicate, maxFrames)
  for _ = 1, maxFrames or 60000 do
    frames(h, 1)
    if predicate() then return true end
  end
  return false
end

local function pits(h) h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0 end

-- chaque onglet, l'overlay et Debug, à chaque largeur
local function drawAll(h, app, what)
  for _, width in ipairs({ 404, 520, 764 }) do
    h.width = width
    for _, tab in ipairs(TABS) do
      h.tab = tab
      frames(h, 2)
      T.eq(app.ui.tab, tab, what .. ' : onglet ' .. tab)
    end
    h.tab = nil
    h.ids, h.idScope = {}, ''
    script.SETUPLAB__OVERLAY(1 / 60)
    script.SETUPLAB__DEBUG(1 / 60)
  end
  T.eq(app.perf.errors, 0, what .. ' : aucune erreur de dessin')
end

for _, lang in ipairs({ 'fr', 'en' }) do
  tests['DS01 pages Racing 26 (' .. lang .. ') : départ, v1, essai, Modifier ouvert, validée, course'] = function()
    local h, app = boot(lang)
    T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
    pits(h)
    drawAll(h, app, 'départ')
    app.settings.compoundChoice = app.discovery.compoundIndex
    app.handleIntents({ start = { kind = 'quali', mode = 'mine' } })
    local r = app.refine
    T.ok(waitFor(h, function() return r and r.version >= 1 and r.phase == 'tours' end), 'v1')
    pits(h)
    drawAll(h, app, 'v1 proposée')
    local e = r.history[#r.history]
    app.handleIntents({ refineJudge = { version = e.version, verdict = 'essayer' } })
    T.ok(waitFor(h, function() return app.loadCheck == nil end), 'essai chargé')
    app.ui.modify = app.ui.modify or {}
    app.ui.modify['quali_' .. e.version] = true
    drawAll(h, app, 'essai, Modifier ouvert')
    -- Gardé | Refusé : même identifiant et même intention que le bouton ImGui
    local item = e.groups[1].items[1]
    h.tab = 'Tour rapide'
    h.click = 'effect_quali_' .. e.version .. '_' .. item.key
    frames(h, 2)
    T.eq(item.keep, false, 'refusé d\'un clic')
    h.click = 'effect_quali_' .. e.version .. '_' .. item.key
    frames(h, 2)
    T.eq(item.keep, true, 'gardé de nouveau')
    app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
    T.eq(e.status, 'validée', tostring(app.ui.message))
    T.ok(waitFor(h, function() return app.loadCheck == nil end), 'version gardée dans la voiture')
    drawAll(h, app, 'validée, question continuer ou figer')
    -- continuer, puis la course depuis la qualif validée
    h.tab = 'Tour rapide'
    h.click = 'step_continue'
    frames(h, 2)
    T.eq(r.choice, nil, 'continuer l\'affinage : question réglée')
    app.handleIntents({ raceLaps = 12 })
    h.tab = 'Course'
    frames(h, 2)
    drawAll(h, app, 'départ de la course')
    h.tab = 'Course'
    h.click = 'race_from_' .. e.file
    frames(h, 2)
    T.ok(app.refine and app.refine.kind == 'race', 'course partie de la qualif : ' .. tostring(app.ui.message))
    T.ok(waitFor(h, function() return app.race ~= nil and app.race.state == 'done' end), 'calcul de course')
    pits(h)
    drawAll(h, app, 'course en affinage')
    h.tab = nil
  end
end

return tests
