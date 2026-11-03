-- Relecture adversariale n° 4 (scratch du relecteur).
local T = require('t')
local Fake = require('fakehost')

local tests = {}

local function boot(opts)
  opts = opts or {}
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  h.sim.raceSessionType = opts.session or 1
  h.opts.applyAids = opts.applyAids
  h.texts, h.buttons = {}, {}
  local function capture(text) h.texts[#h.texts + 1] = text end
  local text, wrapped, colored, button = h.ui.text, h.ui.textWrapped, h.ui.textColored, h.ui.button
  h.ui.text = function(s) capture(s); return text(s) end
  h.ui.textWrapped = function(s) capture(s); return wrapped(s) end
  h.ui.textColored = function(s, c) capture(s); return colored(s, c) end
  h.ui.button = function(label, ...) h.buttons[#h.buttons + 1] = label; return button(label, ...) end
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  app.utcOffset = function() return 7200 end
  app.settings.optBudgetEvalsQ, app.settings.optBudgetEvalsC = 80, 20
  return h, app
end

local function frames(h, n)
  for _ = 1, n do
    h.sim.time = h.sim.time + 1000 / 60
    h.texts, h.buttons = {}, {}
    script.SETUPLAB__UPDATE(1 / 60)
    script.SETUPLAB__MAIN(1 / 60)
  end
end

local function waitFor(h, predicate, maxFrames)
  for i = 1, maxFrames or 60000 do
    frames(h, 1)
    if predicate() then return i end
  end
  return nil
end

local function settled(h, app)
  return waitFor(h, function()
    return app.loadCheck == nil and app.discoveryState == 'done' and not (app.refine and app.refine.needsDiscovery)
  end)
end

local function entry(r, v)
  for i = #r.history, 1, -1 do
    if r.history[i].version == v then return r.history[i] end
  end
end

local function shown(h, fragment)
  for _, s in ipairs(h.texts) do
    if tostring(s):find(fragment, 1, true) then return true end
  end
  return false
end

local function hasButton(h, fragment)
  for _, s in ipairs(h.buttons) do
    if tostring(s):find(fragment, 1, true) then return true end
  end
  return false
end

local function v1Ready(opts)
  local h, app = boot(opts)
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  app.settings.compoundChoice = app.discovery.compoundIndex
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  app.handleIntents({ start = { kind = 'quali', mode = 'mine' } })
  local r = app.refine
  T.ok(waitFor(h, function() return r and r.version >= 1 and r.phase == 'tours' end), 'v1')
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  frames(h, 2)
  return h, app, r, entry(r, r.version)
end

-- A. Pluie, aides refusées seulement : « Valider » recharge la version gardée ; le jeu (comme CSP) remet les niveaux
-- du fichier. Le chargement est-il traité comme réel (nouvelle découverte), ou « non concluant » ?
tests['LR04 aides seules refusées : rechargement à la validation'] = function()
  local h, app = boot({ applyAids = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  h.car.tractionControlMode, h.car.absMode = 4, 4
  app.handleIntents({ rediscover = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  h.sim.rainWetness, h.sim.rainWater = 1, 0.6
  app.nextContextAt = 0
  frames(h, 2)
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  app.settings.compoundChoice = app.discovery.compoundIndex
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  app.handleIntents({ start = { kind = 'quali', mode = 'mine' } })
  local r = app.refine
  T.ok(waitFor(h, function() return r and r.version >= 1 and r.phase == 'tours' end), 'v1')
  frames(h, 2)
  local e = entry(r, r.version)
  local aidItems = {}
  for _, g in ipairs(e.groups or {}) do
    for _, item in ipairs(g.items) do
      if item.aid then aidItems[#aidItems + 1] = item end
    end
  end
  T.ok(#aidItems > 0, 'une aide changée')
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'essayer' } })
  T.ok(settled(h, app))
  PY.note('R4A essai', 'driven=' .. tostring(r.driven) .. ' ABS voiture=' .. tostring(h.car.absMode) .. ' TC voiture='
    .. tostring(h.car.tractionControlMode) .. ' ABS découverte=' .. tostring(app.setupValues(app.discovery.setup.text).ABS))
  for _, item in ipairs(aidItems) do
    app.handleIntents({ effect = { version = e.version, key = item.key, keep = false } })
  end
  local loads = #h.loadCalls
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.eq(e.status, 'validée', tostring(app.ui.message))
  T.ok(settled(h, app))
  PY.note('R4A après validation', 'chargements=' .. (#h.loadCalls - loads) .. ' ABS voiture=' .. tostring(h.car.absMode)
    .. ' ABS découverte=' .. tostring(app.setupValues(app.discovery.setup.text).ABS) .. ' loadTest.ok='
    .. tostring(app.loadTest and app.loadTest.ok) .. ' reason=' .. tostring(app.loadTest and app.loadTest.reason))
  PY.note('R4A message', tostring(app.ui.message))
  app.handleIntents({ refineChoice = { version = e.version } })
  r.forceNext, r.due, r.nextAt = true, true, nil
  local n0 = #r.history
  waitFor(h, function() return r.version >= 2 or #r.history > n0 end, 20000)
  local v2 = entry(r, 2)
  if v2 then
    local s = {}
    for _, g in ipairs(v2.groups or {}) do
      for _, item in ipairs(g.items) do
        if item.aid then s[#s + 1] = item.key .. ' ' .. tostring(item.from) .. '->' .. tostring(item.to) end
      end
    end
    PY.note('R4A v2', 'ABS v2=' .. tostring(app.setupValues(v2.text).ABS) .. ' TC v2=' .. tostring(app.setupValues(v2.text).TRACTION_CONTROL)
      .. ' aides : ' .. table.concat(s, ', ') .. ' ; ABS voiture=' .. tostring(h.car.absMode))
  else
    PY.note('R4A v2', 'pas de v2 : ' .. tostring(r.history[#r.history].note) .. ' / ' .. tostring(r.waiting))
  end
  T.eq(app.loadTest and app.loadTest.ok, true, 'chargement de la version gardée constaté')
  T.eq(app.setupValues(app.discovery.setup.text).ABS, h.car.absMode, 'découverte sur les niveaux de la voiture')
end

-- B. Essai écrit (chargement refusé hors du stand), puis la référence de la mémoire est chargée : le bloc de version
-- dit « à charger au stand » mais le bouton vert charge la référence ; « Essayer v2 » a disparu.
tests['LR05 essai dont le fichier reste, cible de chargement changée : bouton Essayer absent'] = function()
  local h, app, r, e = v1Ready()
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'essayer' } })
  T.ok(settled(h, app))
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.ok(settled(h, app))
  app.handleIntents({ refineChoice = { version = e.version } })
  r.forceNext = true
  T.ok(waitFor(h, function() return r.version >= 2 and r.phase == 'tours' end), 'v2')
  local e2 = entry(r, 2)
  -- hors du stand : l'essai est écrit, le chargement refusé
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = false, false, 30
  app.handleIntents({ refineJudge = { version = 2, verdict = 'essayer' } })
  T.eq(e2.status, 'essai')
  T.ok(e2.trial and app.written[e2.trial.file] == e2.trial.hash, 'fichier d\'essai écrit')
  -- au stand : la référence (v1) de la mémoire est rechargée depuis l'onglet Mémoire
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  frames(h, 2)
  local key = e.group .. '|' .. e.bucket
  app.handleIntents({ memoryLoad = key })
  T.ok(settled(h, app))
  frames(h, 30)
  PY.note('R4B état', 'driven=' .. tostring(r.driven) .. ' saved=' .. tostring(app.saved.quali and app.saved.quali.name)
    .. ' essai=' .. tostring(e2.trial and e2.trial.file) .. ' fichier là=' .. tostring(e2.trial and app.written[e2.trial.file] == e2.trial.hash))
  h.tab = nil
  frames(h, 1)
  local texts = {}
  for _, s in ipairs(h.texts) do
    if tostring(s):find('v2', 1, true) or tostring(s):find('charger', 1, true) or tostring(s):find('Charger', 1, true) then
      texts[#texts + 1] = tostring(s)
    end
  end
  PY.note('R4B textes', table.concat(texts, ' | '))
  local b = {}
  for _, s in ipairs(h.buttons) do b[#b + 1] = tostring(s) end
  PY.note('R4B boutons', table.concat(b, ' | '))
  T.ok(hasButton(h, 'Essayer v2'), 'un moyen de remettre v2 dans la voiture')
end

-- C. Essai chargé depuis le menu d'AC (le fichier …_essai est dans le dossier) : retouches fantômes ?
tests['LR06 essai chargé depuis le menu d\'AC : retouches'] = function()
  local h, app, r, e = v1Ready()
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = false, false, 30
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'essayer' } })
  T.eq(e.status, 'essai')
  -- menu d'AC : le fichier d'essai est chargé à la main
  local values = app.setupValues(e.trial.text)
  for _, sp in ipairs(h.spinners) do
    if type(values[sp.name]) == 'number' then sp.value = values[sp.name] end
  end
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  app.handleIntents({ rediscover = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  local n = 0
  local names = {}
  for name in pairs(app.pins.quali) do n = n + 1; names[#names + 1] = name end
  PY.note('R4C retouches', n .. ' : ' .. table.concat(names, ', ') .. ' ; loaded=' .. tostring(app.loaded.quali and app.loaded.quali.name))
  T.eq(n, 0, 'pas de retouche : ce sont les réglages de v1')
end

-- D. « Figer v1 » sur une version déjà validée partielle : un second fichier ?
tests['LR07 Figer une version validée partielle'] = function()
  local h, app, r, e = v1Ready()
  local first
  for _, g in ipairs(e.groups or {}) do
    for _, item in ipairs(g.items) do
      if first == nil and item.key ~= 'brakeBias' then first = item end
    end
  end
  app.handleIntents({ effect = { version = e.version, key = first.key, keep = false } })
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.eq(e.status, 'validée')
  T.ok(settled(h, app))
  local file1 = e.file
  local n1 = 0
  for _ in pairs(h.written) do n1 = n1 + 1 end
  app.handleIntents({ refineLock = e.version })
  T.ok(settled(h, app))
  local n2 = 0
  for _ in pairs(h.written) do n2 = n2 + 1 end
  PY.note('R4D', 'fichier avant=' .. tostring(file1) .. ' après=' .. tostring(e.file) .. ' fichiers ' .. n1 .. ' -> ' .. n2
    .. ' ; message=' .. tostring(app.ui.message))
  T.eq(e.file, file1, 'même fichier')
end

-- A2. Même chose, découverte relancée après la validation (niveaux de la voiture relus) : l'aide refusée revient-elle ?
tests['LR08 aides refusées : reproposées au calcul suivant'] = function()
  local h, app = boot({ applyAids = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  h.car.tractionControlMode, h.car.absMode = 4, 4
  app.handleIntents({ rediscover = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  h.sim.rainWetness, h.sim.rainWater = 1, 0.6
  app.nextContextAt = 0
  frames(h, 2)
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  app.settings.compoundChoice = app.discovery.compoundIndex
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  app.handleIntents({ start = { kind = 'quali', mode = 'mine' } })
  local r = app.refine
  T.ok(waitFor(h, function() return r and r.version >= 1 and r.phase == 'tours' end), 'v1')
  frames(h, 2)
  local e = entry(r, r.version)
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'essayer' } })
  T.ok(settled(h, app))
  for _, g in ipairs(e.groups or {}) do
    for _, item in ipairs(g.items) do
      if item.aid then app.handleIntents({ effect = { version = e.version, key = item.key, keep = false } }) end
    end
  end
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.ok(settled(h, app))
  app.handleIntents({ rediscover = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  app.handleIntents({ refineChoice = { version = e.version } })
  r.forceNext, r.due, r.nextAt = true, true, nil
  local n0 = #r.history
  waitFor(h, function() return r.version >= 2 or #r.history > n0 end, 20000)
  local v2 = entry(r, 2)
  local s = {}
  for _, g in ipairs(v2 and v2.groups or {}) do
    for _, item in ipairs(g.items) do
      if item.aid then s[#s + 1] = item.key .. ' ' .. tostring(item.from) .. '->' .. tostring(item.to) end
    end
  end
  PY.note('R4A2 v2', tostring(v2 and 'v2' or 'pas de v2') .. ' aides : ' .. table.concat(s, ', ') .. ' ; voiture ABS='
    .. tostring(h.car.absMode) .. ' ; pins=' .. tostring(next(app.pins.quali)))
  T.eq(#s, 0, 'niveaux d\'aide refusés : pas reproposés')
end

-- C2. Une version chargée par SetupLab d'abord, puis l'essai de v2 chargé depuis le menu d'AC.
tests['LR10 essai plus dans la voiture, fichier recyclé : deux boutons Essayer'] = function()
  local h, app, r, e = v1Ready()
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'essayer' } })
  T.ok(settled(h, app))
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.ok(settled(h, app))
  app.handleIntents({ refineChoice = { version = e.version } })
  r.forceNext = true
  T.ok(waitFor(h, function() return r.version >= 2 and r.phase == 'tours' end), 'v2')
  local e2 = entry(r, 2)
  app.handleIntents({ refineJudge = { version = 2, verdict = 'essayer' } })
  T.ok(settled(h, app))
  T.eq(r.driven, 2)
  frames(h, 30)
  app.handleIntents({ memoryLoad = e.group .. '|' .. e.bucket })
  T.ok(settled(h, app))
  frames(h, 30)
  PY.note('R4E état', 'driven=' .. tostring(r.driven) .. ' essai=' .. tostring(e2.trial and e2.trial.file) .. ' fichier là='
    .. tostring(e2.trial and app.written[e2.trial.file] == e2.trial.hash) .. ' status=' .. tostring(e2.status))
  h.tab = nil
  frames(h, 1)
  local b = {}
  for _, s in ipairs(h.buttons) do if tostring(s):find('Essayer', 1, true) then b[#b + 1] = tostring(s) end end
  PY.note('R4E boutons', table.concat(b, ' | '))
  T.ok(hasButton(h, 'Essayer v2###step_action'))
  T.ok(hasButton(h, 'Essayer v2'))
  h.click = 'Essayer v2###step_action'
  frames(h, 1)
  T.ok(settled(h, app))
  PY.note('R4E après clic', 'driven=' .. tostring(r.driven) .. ' message=' .. tostring(app.ui.message))
  T.eq(r.driven, 2)
  T.eq(app.perf.errors, 0)
end

return tests
