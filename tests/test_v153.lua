-- Bêta 1.5.3 (décisions de Vincent du 02/11/2026) : chargement en un clic, « Essayer » met la version dans la voiture,
-- l'essai part à la Corbeille une fois chargé (rien ne reste avant « Valider »), « Recommencer » remet le setup d'avant,
-- « Valider » après « Modifier… » met la version gardée dans la voiture.
local T = require('t')
local Config = require('src/config')
local Exporter = require('src/exporter')
local Fake = require('fakehost')

local tests = {}

local function boot(opts)
  opts = opts or {}
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  h.sim.raceSessionType = opts.session or 1
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

local function folderOf(h)
  return assert(Exporter.targetFolder({ ac = h.ac, io = h.io }))
end

local function backups(h)
  local list = {}
  for path in pairs(h.written) do
    if path:find(Config.exportBackupPrefix, 1, true) then list[#list + 1] = path end
  end
  return list
end

local function liveValues(app, h)
  return app.setupValues(h.ac.stringifyCurrentSetup(true, false))
end

local function sameValues(a, b)
  for name, value in pairs(b) do
    if name ~= 'FUEL' and a[name] ~= value then return false, name end
  end
  return true
end

-- Affinage du tour rapide parti du setup de la voiture, v1 proposée, voiture au stand (menu de setup ouvert).
local function v1Ready()
  local h, app = boot()
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  app.settings.compoundChoice = app.discovery.compoundIndex
  app.handleIntents({ start = { kind = 'quali', mode = 'mine' } })
  local r = app.refine
  T.ok(waitFor(h, function() return r and r.version >= 1 and r.phase == 'tours' end), 'v1')
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  frames(h, 2)
  local e
  for i = #r.history, 1, -1 do
    if r.history[i].version then e = r.history[i]; break end
  end
  return h, app, r, e
end

-- « Essayer » : écrit l'essai et le charge ; constat, puis l'essai part à la Corbeille.
local function tryLoaded(h, app, r, e)
  local loads = #h.loadCalls
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'essayer' } })
  T.eq(e.status, 'essai', tostring(app.ui.message))
  T.eq(#h.loadCalls, loads + 1, 'Essayer : chargé en un clic')
  T.eq(h.loadCalls[#h.loadCalls], e.trial.path, 'le fichier d\'essai')
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'chargement constaté')
  T.ok(app.loadTest and app.loadTest.ok, tostring(app.loadTest and app.loadTest.reason))
  T.eq(r.driven, e.version, 'la version en essai est dans la voiture')
  local trialPath = e.trial.path
  T.ok(waitFor(h, function() return h.written[trialPath] == nil end, 120), 'fichier d\'essai à la Corbeille')
  return trialPath
end

tests['TR01 Essayer met la version dans la voiture ; l\'essai part à la Corbeille ; Valider écrit vN'] = function()
  local h, app, r, e = v1Ready()
  local trialPath = tryLoaded(h, app, r, e)
  T.eq(h.recycled[#h.recycled], trialPath, 'Corbeille de Windows')
  T.eq(app.saved.quali, nil, 'plus rien à charger : l\'essai est dans la voiture')
  T.eq(#backups(h), 1, 'copie de sauvegarde de votre setup avant l\'essai')
  T.ok(e.before and e.before.path == backups(h)[1], 'setup d\'avant noté pour « Recommencer »')
  -- validée telle quelle : vN écrite (nouveau fichier), rien d'autre ; la voiture la garde, rien n'est rechargé
  local loads = #h.loadCalls
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.eq(e.status, 'validée', tostring(app.ui.message))
  T.ok(e.file and e.file:find('_v' .. e.version .. '.ini', 1, true), tostring(e.file))
  T.ok(h.written[folderOf(h) .. '/' .. e.file], 'version écrite à la validation')
  T.eq(#h.loadCalls, loads, 'déjà dans la voiture : rien rechargé')
  for path in pairs(h.written) do T.no(path:find('_essai', 1, true), 'aucun fichier d\'essai restant : ' .. path) end
  T.eq(app.perf.errors, 0)
end

tests['TR02 Recommencer : l\'essai refusé cède la place au setup d\'avant (copie de sauvegarde), sans nouvelle copie'] = function()
  local h, app, r, e = v1Ready()
  local before = liveValues(app, h)
  tryLoaded(h, app, r, e)
  T.no(sameValues(liveValues(app, h), before), 'l\'essai a changé le setup')
  local copies = #backups(h)
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'écarter' } })
  T.eq(e.status, 'écartée', tostring(app.ui.message))
  T.eq(h.loadCalls[#h.loadCalls], e.before.path, 'le setup d\'avant est remis dans la voiture')
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'chargement constaté')
  T.ok(app.loadTest and app.loadTest.ok, tostring(app.loadTest and app.loadTest.reason))
  local same, name = sameValues(liveValues(app, h), before)
  T.ok(same, 'votre setup d\'avant, réglage ' .. tostring(name))
  T.eq(#backups(h), copies, 'pas de copie de l\'essai (mis par SetupLab, sans retouche)')
  T.eq(app.perf.errors, 0)
end

tests['TR03 Valider après Modifier… : la version gardée remplace l\'essai dans la voiture'] = function()
  local h, app, r, e = v1Ready()
  tryLoaded(h, app, r, e)
  -- refuser un réglage, en garder au moins un
  local refused
  for _, g in ipairs(e.groups or {}) do
    for _, item in ipairs(g.items) do
      if refused == nil and app.keptCount(e) > 1 then
        refused = item
        app.handleIntents({ effect = { version = e.version, key = item.key, keep = false } })
      end
    end
  end
  T.ok(refused, 'au moins deux réglages changés')
  local loads = #h.loadCalls
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.eq(e.status, 'validée', tostring(app.ui.message))
  T.eq(#h.loadCalls, loads + 1, 'version gardée chargée en un clic')
  T.eq(h.loadCalls[#h.loadCalls], folderOf(h) .. '/' .. e.file)
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'chargement constaté')
  T.ok(app.loadTest and app.loadTest.ok, tostring(app.loadTest and app.loadTest.reason))
  local same, name = sameValues(liveValues(app, h), app.setupValues(e.text))
  T.ok(same, 'la voiture a la version gardée, réglage ' .. tostring(name))
  T.eq(app.perf.errors, 0)
end

tests['TR04 Valider sans essai : la version validée va dans la voiture (accord de Vincent du 02/11/2026)'] = function()
  local h, app, r, e = v1Ready()
  local loads = #h.loadCalls
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.eq(e.status, 'validée', tostring(app.ui.message))
  T.eq(#h.loadCalls, loads + 1, 'chargée en un clic')
  T.eq(h.loadCalls[#h.loadCalls], folderOf(h) .. '/' .. e.file, 'la version validée')
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'chargement constaté')
  T.ok(app.loadTest and app.loadTest.ok, tostring(app.loadTest and app.loadTest.reason))
  T.eq(r.driven, e.version, 'elle est dans la voiture : l\'affinage repart d\'elle')
  T.eq(app.perf.errors, 0)
end

-- Tranche 3 (décision de Vincent du 02/11/2026) : après chaque validation, on demande « Continuer l'affinage » ou
-- « Figer » ; rien de nouveau n'est calculé avant la réponse.
tests['CH01 après la validation : question posée, aucun calcul ; « Continuer » : la version suivante se calcule'] = function()
  local h, app, r, e = v1Ready()
  tryLoaded(h, app, r, e)
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.eq(r.choice, e.version, 'question posée')
  T.contains(r.waiting, 'continuer l\'affinage ou la figer')
  local computed, version = app.quali, r.version
  r.due, r.nextAt, r.forceNext = true, nil, true
  frames(h, 600)
  -- la découverte relancée après le chargement efface le résultat d'avant ; aucun calcul nouveau
  T.ok(app.quali == nil or app.quali == computed, 'aucun calcul avant la réponse')
  T.eq(r.version, version, 'aucune version nouvelle')
  T.ok(r.active, 'affinage toujours actif (en attente de la réponse)')
  app.handleIntents({ refineChoice = { version = e.version } })
  T.eq(r.choice, nil)
  T.contains(app.ui.message, 'il continue à partir de v' .. e.version)
  r.forceNext = true
  T.ok(waitFor(h, function() return app.quali ~= nil and app.quali ~= computed end, 6000), 'nouveau calcul après « Continuer »')
  T.eq(app.perf.errors, 0)
end

tests['CH02 après la validation : « Figer » verrouille la version et arrête l\'affinage'] = function()
  local h, app, r, e = v1Ready()
  tryLoaded(h, app, r, e)
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.eq(r.choice, e.version)
  app.handleIntents({ refineChoice = { version = e.version, lock = true } })
  local m = app.memory[e.group .. '|' .. e.bucket]
  T.ok(m and m.locked and m.signature == e.signature, 'version figée en mémoire')
  T.no(r.active, 'affinage arrêté')
  T.eq(r.choice, nil)
  frames(h, 120)
  T.no(app.refine.active, 'pas de reprise tant que figé')
  T.eq(app.perf.errors, 0)
end

tests['CH03 « Relancer l\'affinage » vaut « Continuer » ; une réponse pour une autre version ne fait rien'] = function()
  local h, app, r, e = v1Ready()
  tryLoaded(h, app, r, e)
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  app.handleIntents({ refineChoice = { version = e.version + 5 } })
  T.eq(r.choice, e.version, 'réponse pour une autre version : ignorée')
  app.handleIntents({ refineStop = true })
  T.no(r.active)
  app.handleIntents({ refineStart = 'quali' })
  T.ok(app.refine == r and r.active, 'affinage repris')
  T.eq(r.choice, nil, 'relancer : continuer')
  frames(h, 2)
  T.eq(app.perf.errors, 0)
end

-- Tranche 4 (décision de Vincent du 02/11/2026) : la course part d'une qualif validée au choix, d'un lancement d'AC à
-- l'autre ; « Reprendre ma course vN ».
local function restart(h)
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  app.utcOffset = function() return 7200 end
  app.settings.optBudgetEvalsQ, app.settings.optBudgetEvalsC = 80, 20
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte au redémarrage')
  return app
end

local function nudge(h, app)
  local sp = h.spinners[1]
  sp.value = sp.value + ((sp.value + (sp.step or 1) <= sp.max) and (sp.step or 1) or -(sp.step or 1))
  app.handleIntents({ rediscover = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  app.qualiScan = nil
end

local function choiceOf(h, app, file)
  local found
  T.ok(waitFor(h, function()
    for _, c in ipairs(app.raceChoices()) do
      if c.file == file then found = c end
    end
    return found ~= nil
  end, 120), 'qualif proposée pour la course : ' .. tostring(file))
  return found
end

tests['RC01 course : partir d\'une qualif validée, en un clic (chargée, puis l\'affinage de la course démarre)'] = function()
  local h, app, r, e = v1Ready()
  tryLoaded(h, app, r, e)
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.eq(e.status, 'validée', tostring(app.ui.message))
  app.handleIntents({ refineChoice = { version = e.version, lock = true } })
  app.handleIntents({ raceLaps = 12 })
  T.ok(waitFor(h, function() return choiceOf(h, app, e.file).inCar end, 600), 'dans la voiture')
  -- une autre base dans la voiture : la qualif validée se charge d'un clic
  nudge(h, app)
  local c = choiceOf(h, app, e.file)
  T.ok(c.loadable and not c.inCar, 'chargeable, pas dans la voiture')
  local loads = #h.loadCalls
  app.handleIntents({ raceFrom = e.file })
  T.eq(#h.loadCalls, loads + 1, 'chargée en un clic')
  T.eq(h.loadCalls[#h.loadCalls], folderOf(h) .. '/' .. e.file)
  T.ok(app.refine and app.refine.active and app.refine.kind == 'race', 'affinage de la course démarré')
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'chargement constaté')
  T.ok(app.loadTest and app.loadTest.ok, tostring(app.loadTest and app.loadTest.reason))
  local rr = app.refine
  -- le calcul de la course part de la qualif chargée (v1 proposée, ou « déjà le meilleur » avec ce petit budget)
  T.ok(waitFor(h, function() return app.race ~= nil and app.race.state == 'done' and rr.phase == 'tours' end, 60000),
    'calcul de course : ' .. tostring(rr.waiting))
  T.eq(app.perf.errors, 0)
end

tests['RC02 qualif validée lors d\'un lancement précédent d\'AC : toujours chargeable par SetupLab pour la course'] = function()
  local h, app, r, e = v1Ready()
  tryLoaded(h, app, r, e)
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  app.handleIntents({ refineChoice = { version = e.version } })
  -- une version validée qui n'est plus la référence de la mémoire (une v2 validée depuis l'a remplacée) : seule la
  -- liste des versions validées la garde
  local Store = require('src/store')
  for key in pairs(app.store.entries) do
    if key:find('^mem:') then Store.remove(app.store, key) end
  end
  frames(h, 70) -- le stockage s'écrit au plus une fois par seconde
  nudge(h, app)
  app = restart(h)
  T.eq(app.written[e.file], e.hash, 'reconnue comme écrite par SetupLab')
  app.handleIntents({ raceLaps = 12 })
  local c = choiceOf(h, app, e.file)
  T.ok(c.loadable, 'chargeable')
  app.handleIntents({ raceFrom = e.file })
  T.eq(h.loadCalls[#h.loadCalls], folderOf(h) .. '/' .. e.file, 'chargée en un clic')
  T.ok(waitFor(h, function() return app.loadCheck == nil end))
  T.ok(app.loadTest and app.loadTest.ok, tostring(app.loadTest and app.loadTest.reason))
  -- fichier modifié depuis : plus proposé au chargement (D8)
  h.written[folderOf(h) .. '/' .. e.file] = h.written[folderOf(h) .. '/' .. e.file] .. '\n; retouche\n'
  nudge(h, app)
  T.no(choiceOf(h, app, e.file).loadable, 'fichier modifié : pas chargeable')
  T.eq(app.perf.errors, 0)
end

tests['RC03 « Reprendre ma course vN » : la course validée revient dans la voiture et son affinage reprend'] = function()
  local h, app = boot({ session = 3 })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  app.settings.refineMinLaps, app.settings.refineInstantFirst, app.settings.optBudgetEvalsC = 0, false, 300
  Fake.raceReady(h, app, 12)
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  frames(h, 2)
  app.handleIntents({ refineStart = 'race' })
  local rr = app.refine
  T.ok(waitFor(h, function() return rr.version >= 1 and rr.phase == 'tours' end, 60000), 'v1 de course : ' .. tostring(rr.waiting))
  local e
  for i = #rr.history, 1, -1 do
    if rr.history[i].version then e = rr.history[i]; break end
  end
  tryLoaded(h, app, rr, e)
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.eq(e.status, 'validée', tostring(app.ui.message))
  local m = app.memory['course|sec']
  T.ok(m and m.file == e.file, 'course validée en mémoire')
  frames(h, 70)
  nudge(h, app)
  app = restart(h)
  app.handleIntents({ raceLaps = 12 })
  T.ok(app.memory['course|sec'] and app.memory['course|sec'].text, 'course validée relue')
  local loads = #h.loadCalls
  app.handleIntents({ raceResume = 'course|sec' })
  T.eq(#h.loadCalls, loads + 1, 'chargée en un clic')
  T.eq(h.loadCalls[#h.loadCalls], folderOf(h) .. '/' .. e.file)
  T.ok(app.refine and app.refine.active and app.refine.kind == 'race', 'affinage de la course repris')
  T.eq(app.refine.base, e.version, 'numérotation à la suite')
  T.ok(waitFor(h, function() return app.loadCheck == nil end))
  T.ok(app.loadTest and app.loadTest.ok, tostring(app.loadTest and app.loadTest.reason))
  T.ok(waitFor(h, function() return app.raceStarted() and app.discoveryState == 'done' end, 1200),
    'course commencée : elle continue depuis la voiture')
  T.eq(app.raceBlocker(), nil, 'rien ne bloque')
  T.eq(app.perf.errors, 0)
end

return tests
