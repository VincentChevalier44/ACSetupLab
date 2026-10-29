-- SetupLab actif, nom du setup, valider, écarter, figer, mémoire du circuit (demande de Vincent du
-- 21/10/2026 : « on l'ouvre, on l'active, on roule, il nous propose un setup, on continue, on affine, on
-- valide ou on ne valide pas à chaque étape » ; « un bouton avec un cadenas pour dire ce setup est validé » ;
-- « une mémoire par circuit et par type de séance »). Réponses de Vincent : l'affinage suit la séance
-- (tour rapide en essai et qualification, course en course) ; valider = référence gardée en mémoire,
-- écarter = jamais reproposée, repli sur la référence ; figer = affinage arrêté, setup proposé à chaque
-- visite, déverrouillable ; mémoire par circuit (disposition comprise) et par séance, sec et pluie à part.
-- Décision amendée le même jour (29 fichiers écrits en un quart d'heure) : rien n'est enregistré avant
-- « Valider » ; chaque setup proposé est annoncé une fois à l'écran (AU08 reproduit le constat).
local T = require('t')
local Util = require('src/util')
local Config = require('src/config')
local Exporter = require('src/exporter')
local CarModel = require('src/car_model')
local Sim = require('src/laptime_sim')
local Fake = require('fakehost')

local TRUTH = { mu = 0.96, power = 0.98, drag = 1.02, lift = 1.0, brake = 1.0 }

local tests = {}

local function install(h)
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  app.utcOffset = function() return 7200 end
  app.settings.optBudgetEvalsQ, app.settings.optBudgetEvalsC = 80, 20
  return app
end

local function boot(carId, session, opts)
  local h = Fake.new({ car = require('fixtures/cars/' .. (carId or 'lamborghini_huracan_gt3_evo2')),
    track = require('fixtures/tracks/monza'), missing = opts and opts.missing })
  h.sim.raceSessionType = session or 2
  h.texts = {}
  local function capture(text) h.texts[#h.texts + 1] = text end
  local text, wrapped, colored = h.ui.text, h.ui.textWrapped, h.ui.textColored
  h.ui.text = function(s) capture(s); return text(s) end
  h.ui.textWrapped = function(s) capture(s); return wrapped(s) end
  h.ui.textColored = function(s, c) capture(s); return colored(s, c) end
  return h, install(h)
end

-- Une image ; profile : le conducteur simulé avance (la voiture quitte alors les stands).
local function frames(h, n, profile)
  for _ = 1, n do
    if profile then
      h.car.isInPit, h.car.isInPitlane = false, false
      Fake.drive(h, profile, 1 / 60)
    end
    h.sim.time = h.sim.time + 1000 / 60
    h.texts = {}
    script.SETUPLAB__UPDATE(1 / 60)
    script.SETUPLAB__MAIN(1 / 60)
  end
end

local function waitFor(h, predicate, maxFrames, profile)
  for i = 1, maxFrames or 60000 do
    frames(h, 1, profile)
    if predicate() then return i end
  end
  return nil
end

local function spinner(h, name)
  for _, sp in ipairs(h.spinners) do
    if sp.name == name then return sp end
  end
  return nil
end

-- Pincement changé à la main (réglage non optimisé) : autre base de calcul, donc autre proposition.
local function toe(h)
  for _, sp in ipairs(h.spinners) do
    if sp.name == 'TOE_OUT_LF' or sp.name == 'TOE_OUT_RF' then sp.value = sp.value + sp.step end
  end
end

-- Fichiers de setup écrits (copies de sauvegarde d'avant chargement exclues).
local function setupFiles(h)
  local n = 0
  for path in pairs(h.written) do
    if path:find('/setups/', 1, true) and not path:find(Config.exportBackupPrefix, 1, true) then n = n + 1 end
  end
  return n
end

-- Profil de vitesse « vrai » du setup de la découverte, pneus à température, carburant du réservoir.
local function drivenProfile(h, app)
  local d = app.discovery
  local fuel = spinner(h, 'FUEL') and spinner(h, 'FUEL').value or 30
  local setup = app.physicalSetup(d, nil, nil)
  setup.fuel = fuel
  local compound = d.carBase.compounds[setup.compound]
  local temp = CarModel.operatingTemp(compound.front)
  for w = 0, 3 do
    h.car.wheels[w].tyreCoreTemperature = temp
    h.car.wheels[w].tyrePressure = CarModel.hotPressure(w < 2 and setup.pressureF or setup.pressureR, d.conditions.airTemp, temp)
    h.car.wheels[w].tyreVirtualKM = 0.5
  end
  h.car.fuel = fuel
  local conditions = { airTemp = d.conditions.airTemp, roadGrip = d.conditions.roadGrip, surfaceGrip = d.conditions.surfaceGrip,
    factors = TRUTH }
  local eff = assert(CarModel.configure(d.carBase, setup, conditions))
  local result, buf = Sim.run(d.trackModel, eff, nil)
  local profile = { p = {}, v = {}, time = result.time }
  for k = 1, d.trackModel.n do profile.p[k], profile.v[k] = d.trackModel.p[k], buf.v[k] end
  profile.p[#profile.p + 1], profile.v[#profile.v + 1] = 1, buf.v[1]
  return profile
end

local function shown(h, pattern)
  for _, text in ipairs(h.texts) do
    if text:find(pattern, 1, true) then return text end
  end
  return nil
end

local function ready(carId, session, opts)
  local h, app = boot(carId, session, opts)
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  app.settings.compoundChoice = app.discovery.compoundIndex
  return h, app
end

local function folderOf(h)
  return assert(Exporter.targetFolder({ ac = h.ac, io = h.io }))
end

local function storedKeys(app, suffix)
  local list = {}
  for key in pairs(app.store.entries) do
    if key:sub(1, 4) == 'mem:' and key:sub(-#suffix) == suffix then list[#list + 1] = key end
  end
  return list
end

-- Chargement au stand en deux clics (délai minimal respecté) ; click : bouton qui arme.
local function loadAtPit(h, app, click)
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  h.driver = nil
  frames(h, 1)
  h.click = click
  frames(h, 1)
  T.ok(app.loadArm, tostring(app.ui.message))
  local started = app.clock()
  while app.clock() - started < Config.K.loadConfirmMinSeconds + 0.1 do frames(h, 1) end
  h.click = 'Confirmer le chargement (tour rapide)'
  frames(h, 1)
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'constat du chargement')
  T.ok(app.loadTest and app.loadTest.ok, tostring(app.loadTest and app.loadTest.reason) .. ' / ' .. tostring(app.ui.message))
end

tests['AU01 SetupLab actif : veille au démarrage ; coché : affinage du genre de la séance ; la séance change : il suit'] = function()
  local h, app = ready(nil, 1)
  frames(h, 120)
  T.eq(app.auto, false, 'veille au démarrage')
  T.eq(app.refine, nil, 'rien ne part tout seul')
  T.ok(shown(h, 'En veille'), 'état dit')
  T.eq(next(h.written), nil, 'aucun fichier écrit avant le clic')
  h.click = 'SetupLab actif'
  frames(h, 1)
  T.eq(app.auto, true)
  T.contains(app.ui.message, 'SetupLab actif')
  frames(h, 1)
  T.ok(shown(h, 'Étape 1/4 · Départ'), 'départ à choisir')
  app.handleIntents({ start = 'mine' }) -- 1.5 : point de départ choisi (carte d'étape)
  T.ok(waitFor(h, function() return app.refine and app.refine.active end), 'affinage lancé')
  T.eq(app.refine.kind, 'quali', 'essai : tour rapide')
  T.ok(waitFor(h, function() return app.refine.version >= 1 end), 'v1 proposée')
  T.eq(next(h.written), nil, 'rien d\'écrit avant « Valider »')
  T.eq(#h.messages, 1, 'annoncée une fois à l\'écran')
  T.eq(h.messages[1].title, 'SetupLab : setup tour rapide v1 prêt')
  T.eq(h.messages[1].time, Config.K.alertSeconds)
  frames(h, 1)
  T.ok(shown(h, 'Actif : v1 prête (essai ou journée circuit, sec) — à valider ou recommencer.'), 'état de l\'affinage dit')
  -- nouvelle séance (course) : nouvelle découverte, puis affinage course
  h.sim.raceSessionType, h.sim.currentSessionIndex = 3, 1
  T.ok(waitFor(h, function() return app.refine and app.refine.kind == 'race' and app.refine.active end), 'course affinée')
  frames(h, 1)
  T.ok(shown(h, '(course, sec)'), 'course affinée, dite')
  -- décoché : arrêt, rien de plus
  h.click = 'SetupLab actif'
  frames(h, 1)
  T.eq(app.auto, false)
  T.no(app.refine.active, 'affinage arrêté')
  T.contains(app.ui.message, 'veille')
  local count = 0
  for _ in pairs(h.written) do count = count + 1 end
  frames(h, 600)
  local after = 0
  for _ in pairs(h.written) do after = after + 1 end
  T.eq(after, count, 'plus rien d\'écrit en veille')
  -- arrêter l'affinage met aussi en veille (sinon il repartirait tout seul)
  h.click = 'SetupLab actif'
  frames(h, 1)
  T.ok(waitFor(h, function() return app.refine and app.refine.active end))
  app.handleIntents({ refineStop = true })
  frames(h, 1)
  T.eq(app.auto, false)
  T.contains(app.ui.message, 'SetupLab en veille')
  -- découverte en échec : dit dans la ligne d'état (jamais « en cours »)
  local line = require('src/ui').autoLine({ auto = true, discoveryState = 'failed', discoveryError = 'panne simulée' })
  T.contains(line, 'découverte en échec (panne simulée)')
  T.eq(app.perf.errors, 0)
end

tests['AU02 nom choisi : sans accent ni espace, genre ajouté, versions _v1 ; renommer : nouveau fichier ; chargé au stand'] = function()
  local h, app = ready()
  local folder = folderOf(h)
  h.inputs = { ['Nom du setup (facultatif)'] = 'Mon réglage Monza' }
  frames(h, 1)
  T.eq(app.names.quali, 'Mon réglage Monza')
  frames(h, 1)
  T.ok(shown(h, 'Fichier : Mon_reglage_Monza_Qualif.ini'), 'nom de fichier annoncé, genre ajouté')
  h.click = 'Affinage automatique (tour rapide)'
  frames(h, 1)
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end), 'v1')
  T.eq(r.history[1].file, nil, 'rien d\'écrit avant « Valider »')
  frames(h, 1)
  T.ok(shown(h, 'Fichier : Mon_reglage_Monza_Qualif_v1.ini, à la validation'), 'nom annoncé')
  h.click = 'Valider v1'
  frames(h, 1)
  T.eq(r.history[1].file, 'Mon_reglage_Monza_Qualif_v1.ini')
  T.ok(h.written[folder .. '/Mon_reglage_Monza_Qualif_v1.ini'], 'fichier écrit à la validation')
  h.click = 'Arrêter l\'affinage (tour rapide)'
  frames(h, 1)
  T.no(r.active)
  T.ok(waitFor(h, function() return app.quali and app.quali.state == 'done' end), 'calcul en cours terminé')
  -- renommer : le même setup sous le nouveau nom (nouveau fichier, l'ancien reste) ; le nom finit déjà par le
  -- genre : pas répété
  h.inputs = { ['Nom du setup (facultatif)'] = 'Monza qualif.ini' }
  frames(h, 2)
  T.ok(shown(h, 'Fichier : Monza_qualif.ini'))
  h.click = 'Enregistrer le setup tour rapide'
  frames(h, 1)
  T.eq(app.saved.quali.name, 'Monza_qualif.ini', tostring(app.ui.message))
  T.eq(r.history[1].file, 'Monza_qualif.ini', 'la version suit le nouveau nom')
  T.ok(h.written[folder .. '/Mon_reglage_Monza_Qualif_v1.ini'], 'ancien fichier gardé')
  h.click = 'Enregistrer le setup tour rapide'
  frames(h, 1)
  T.eq(app.saved.quali.name, 'Monza_qualif-2.ini', 'jamais d\'écrasement')
  frames(h, 1)
  T.ok(shown(h, 'Enregistré : Monza_qualif-2.ini'), 'nom réellement écrit affiché')
  -- chargement au stand d'un fichier nommé (reconnu à son empreinte)
  loadAtPit(h, app, 'Charger le setup tour rapide dans la voiture')
  T.ok(h.loadCalls[#h.loadCalls]:find('/Monza_qualif-2.ini', 1, true))
  -- nom vide : nom horodaté
  h.inputs = { ['Nom du setup (facultatif)'] = '  ' }
  frames(h, 1)
  h.click = 'Enregistrer le setup tour rapide'
  frames(h, 1)
  T.ok(app.saved.quali.name:find(Config.exportQualiPrefix, 1, true) == 1, app.saved.quali.name)
  T.eq(Util.fileNameFrom('Été à Spa — œuvre', 40), 'Ete_a_Spa_uvre')
  T.eq(Util.fileNameFrom('../../x', 40), 'x')
  T.eq(app.perf.errors, 0)
end

tests['AU03 valider : enregistrée, référence en mémoire ; écarter : jamais reproposée, rien d\'écrit'] = function()
  local h, app = ready()
  local folder = folderOf(h)
  h.click = 'Affinage automatique (tour rapide)'
  frames(h, 1)
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end), 'v1')
  local v1 = r.history[1]
  T.eq(setupFiles(h), 0, 'rien d\'écrit avant « Valider »')
  frames(h, 1)
  T.ok(shown(h, 'v1 prête : gain prévu'), 'v1 affichée')
  T.ok(shown(h, 'changé'), 'ses réglages changés résumés (1.5 : « Modifier… » pour les refuser un par un)')
  h.click = 'Valider v1'
  frames(h, 1)
  T.eq(v1.status, 'validée')
  T.contains(app.ui.message, 'v1 validée et enregistrée')
  T.eq(setupFiles(h), 1, 'un fichier à la validation')
  T.ok(h.written[folder .. '/' .. v1.file])
  T.eq(app.saved.quali.signature, v1.signature, 'v1 à charger')
  local m = app.memory['qualif|sec']
  T.ok(m and m.file == v1.file and not m.locked, 'référence en mémoire (qualification, sec)')
  T.eq(#storedKeys(app, ':qualif:sec'), 1, 'gardée dans le stockage')
  -- autre base (pincement changé à la main, non optimisé) et un tour propre : autre proposition, v2
  toe(h)
  local profile = drivenProfile(h, app)
  T.ok(waitFor(h, function() return r.version >= 2 and r.phase == 'tours' end, nil, profile), 'v2')
  local v2 = r.history[#r.history]
  T.eq(v2.version, 2)
  T.ok(v2.signature ~= v1.signature)
  T.eq(v2.file, nil, 'v2 proposée, pas enregistrée')
  T.eq(app.saved.quali.signature, v1.signature, 'v1 reste le setup à charger')
  h.click = 'Recommencer (ne pas garder v2)'
  frames(h, 1, profile)
  T.eq(v2.status, 'écartée')
  T.contains(app.ui.message, 'ni réutilisée ni reproposée (jamais enregistrée)')
  T.contains(app.ui.message, 'nouvelle proposition avec vos prochains tours')
  T.contains(app.ui.message, v1.file)
  T.eq(app.saved.quali.signature, v1.signature)
  T.eq(app.proposals.quali, v1.signature, 'setup proposé cohérent (chargement, validation)')
  frames(h, 1, profile)
  T.ok(shown(h, 'v2 non gardée : pas reproposée.'))
  -- mêmes données (calcul forcé pour le banc) : le calcul retrouve v2, notée, jamais reproposée
  r.due = true
  T.ok(waitFor(h, function()
    local last = r.history[#r.history]
    return r.phase == 'tours' and last.note ~= nil and last.note:find('version non gardée', 1, true) ~= nil
  end), 'v2 retrouvée : non reproposée')
  T.eq(r.version, 2)
  -- même base, un tour de plus : nouveau calcul ; v2 jamais reproposée (identique : notée ; sinon une autre
  -- version, avec les données du tour)
  local before = app.quali
  T.ok(waitFor(h, function() return app.quali ~= before and r.phase == 'tours' end, nil, profile), 'calcul après le tour')
  for _, e in ipairs(r.history) do
    if e.version and e ~= v2 then T.ok(e.signature ~= v2.signature, 'v2 reproposée en v' .. e.version) end
  end
  T.eq(setupFiles(h), 1, 'aucun nouveau fichier')
  -- la référence se charge au stand (bouton de la carte d'affinage)
  loadAtPit(h, app, 'Charger le setup tour rapide dans la voiture')
  T.eq(h.loadCalls[#h.loadCalls], folder .. '/' .. v1.file)
  T.eq(app.perf.errors, 0)
end

tests['AU04 cadenas : figé, affinage arrêté ; app relancée : proposé et chargeable ; déverrouiller : reprise'] = function()
  local h, app = ready()
  h.click = 'SetupLab actif'
  frames(h, 1)
  app.handleIntents({ start = 'mine' }) -- 1.5 : point de départ choisi (carte d'étape)
  T.ok(waitFor(h, function() return app.refine and app.refine.version >= 1 and app.refine.phase == 'tours' end), 'v1')
  local v1 = app.refine.history[1]
  h.click = 'Figer v1 (cadenas)'
  frames(h, 1)
  local m = app.memory['qualif|sec']
  T.ok(m and m.locked and m.file == v1.file, 'figé en mémoire')
  T.eq(v1.status, 'validée', 'figer valide aussi')
  T.no(app.refine.active, 'affinage arrêté')
  T.contains(app.ui.message, 'Setup figé')
  frames(h, 600)
  T.no(app.refine.active, 'pas de reprise tant que figé')
  T.ok(shown(h, 'Actif : setup figé pour qualification, sec'))
  T.ok(shown(h, 'qualification · sec : ' .. v1.file .. ' (v1) — figé'), 'mémoire du circuit')
  -- nouveau lancement d'AC (stockage et fichiers gardés) : veille, setup figé proposé et chargeable
  app = install(h)
  T.eq(app.auto, false, 'veille au redémarrage')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  local again = app.memory['qualif|sec']
  T.ok(again and again.locked and again.text, tostring(again and again.problem))
  frames(h, 1)
  T.ok(shown(h, 'Mémoire du circuit'))
  loadAtPit(h, app, 'Charger###memload_qualif_sec')
  T.eq(h.loadCalls[#h.loadCalls], folderOf(h) .. '/' .. v1.file)
  -- actif : rien ne part (figé)
  h.click = 'SetupLab actif'
  frames(h, 600)
  T.no(app.refine and app.refine.active, 'figé : pas d\'affinage')
  -- déverrouiller : l'affinage reprend
  h.click = 'Déverrouiller###memlock_qualif_sec'
  frames(h, 1)
  T.no(app.memory['qualif|sec'].locked)
  T.contains(app.ui.message, 'reprend')
  T.ok(waitFor(h, function() return app.refine and app.refine.active end), 'reprise')
  -- fichier modifié hors de SetupLab : refusé au chargement tout de suite ; dit dans la mémoire à la relecture
  -- suivante (au plus K.memoryRecheck s)
  local path = folderOf(h) .. '/' .. v1.file
  h.written[path] = h.written[path] .. '\n; modifié'
  h.click = 'Arrêter l\'affinage (tour rapide)'
  frames(h, 1)
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  h.click = 'Charger###memload_qualif_sec'
  frames(h, 1)
  T.eq(app.loadArm, nil)
  T.contains(app.ui.message, 'modifié')
  h.sim.time = h.sim.time + (Config.K.memoryRecheck + 1) * 1000
  h.click = 'Relancer la découverte'
  frames(h, 1)
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  T.eq(app.memory['qualif|sec'].problem, 'fichier modifié depuis sa validation')
  T.eq(app.memory['qualif|sec'].text, nil)
  T.eq(app.perf.errors, 0)
end

tests['AU05 mémoire par séance et état de piste : qualification, essai, pluie ; jamais mélangées'] = function()
  local h, app = ready()
  h.click = 'Affinage automatique (tour rapide)'
  frames(h, 1)
  T.ok(waitFor(h, function() return app.refine.version >= 1 and app.refine.phase == 'tours' end))
  h.click = 'Valider v1'
  frames(h, 1)
  T.ok(app.memory['qualif|sec'], 'qualification, sec')
  h.click = 'Arrêter l\'affinage (tour rapide)'
  frames(h, 1)
  -- essai (journée circuit) : autre séance ; la mémoire de la qualification reste
  h.sim.raceSessionType, h.sim.currentSessionIndex = 1, 1
  T.ok(waitFor(h, function() return app.discoveryState == 'running' end), 'nouvelle découverte')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  T.ok(app.memory['qualif|sec'] and app.memory['qualif|sec'].text, 'qualification gardée')
  -- 1.5 : nouvelle séance, nouveau point de départ (carte d'étape)
  app.handleIntents({ start = 'mine' })
  frames(h, 1)
  -- numérotation à la suite sur le circuit (décision de Vincent du 22/10/2026) : SetupLab_Qualif_v1 existe déjà
  T.eq(app.refine.base, 1, 'v1 déjà dans le dossier')
  T.ok(waitFor(h, function() return app.refine.version >= 2 and app.refine.phase == 'tours' end))
  T.eq(app.refine.version, 2)
  h.click = 'Valider v2'
  frames(h, 1)
  T.ok(app.memory['essai|sec'], 'essai, sec')
  -- même setup que v1 (mêmes conditions) : son fichier sert, aucun SetupLab_Qualif_v1-2
  T.no(app.memory['essai|sec'].file:find('-2', 1, true), app.memory['essai|sec'].file)
  T.eq(#storedKeys(app, ':essai:sec'), 1)
  T.eq(#storedKeys(app, ':qualif:sec'), 1)
  -- pluie : setup validé à part
  h.sim.rainWetness, h.sim.rainWater = 1, 0.6
  app.nextContextAt = 0
  frames(h, 1)
  T.eq(app.wet.state, 'pluie')
  h.click = 'Arrêter l\'affinage (tour rapide)'
  frames(h, 1)
  h.click = 'Relancer l\'affinage (tour rapide)'
  frames(h, 1)
  T.ok(waitFor(h, function() return app.refine.version >= 1 and app.refine.phase == 'tours' end), 'v1 pluie')
  T.eq(app.refine.history[#app.refine.history].bucket, 'pluie')
  h.click = 'Valider v' .. app.refine.version
  frames(h, 1)
  T.ok(app.memory['essai|pluie'], 'essai, pluie')
  T.ok(app.memory['essai|sec'].signature ~= app.memory['essai|pluie'].signature, 'sec et pluie à part')
  frames(h, 1)
  T.ok(shown(h, 'essai ou journée circuit · pluie : '))
  T.ok(shown(h, 'qualification · sec : '))
  T.eq(app.perf.errors, 0)
end

-- La boucle réelle : proposée, validée (enregistrée), chargée au stand, roulée, puis écartée après l'essai :
-- la référence d'avant revient (son fichier reste, D8) ; rien n'est proposé à partir d'une version écartée
-- encore dans la voiture.
tests['AU06 validée, essayée, écartée : la référence d\'avant revient ; rien à partir d\'elle tant qu\'elle est montée'] = function()
  local h, app = ready()
  h.click = 'Affinage automatique (tour rapide)'
  frames(h, 1)
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end), 'v1')
  local v1 = r.history[1]
  h.click = 'Valider v1'
  frames(h, 1)
  loadAtPit(h, app, 'Charger le setup tour rapide dans la voiture')
  T.eq(r.driven, 1)
  T.ok(waitFor(h, function() return not r.needsDiscovery and app.discoveryState == 'done' and r.phase == 'tours' end))
  -- autre base (pincement) et un tour propre : v2 proposée, v1 en piste
  toe(h)
  local profile = drivenProfile(h, app)
  T.ok(waitFor(h, function() return r.version >= 2 and r.phase == 'tours' end, nil, profile), 'v2')
  local v2 = r.history[#r.history]
  frames(h, 1, profile)
  T.ok(shown(h, 'v1 : ' .. v1.file .. ' — validée (en piste)'), 'version en piste affichée')
  h.click = 'Valider v2'
  frames(h, 1, profile)
  T.eq(v2.status, 'validée', tostring(app.ui.message))
  T.eq(app.memory['qualif|sec'].signature, v2.signature, 'v2 référence')
  loadAtPit(h, app, 'Charger le setup tour rapide dans la voiture')
  T.eq(r.driven, 2)
  -- essayée, écartée : v1 redevient la référence et le setup à charger ; le fichier de v2 part à la Corbeille,
  -- voiture arrêtée (réponse de Vincent du 22/10/2026), et plus rien ne le désigne
  local writes = h.writeCalls
  local v2file = v2.file
  h.click = 'Recommencer (ne pas garder v2)'
  frames(h, 1)
  T.eq(v2.status, 'écartée', tostring(app.ui.message))
  T.contains(app.ui.message, 'encore dans la voiture')
  T.contains(app.ui.message, 'son fichier ' .. v2file .. ' part à la Corbeille')
  T.ok(waitFor(h, function() return h.written[folderOf(h) .. '/' .. v2file] == nil end, 10), 'à la Corbeille, voiture arrêtée')
  T.eq(h.recycled[#h.recycled], folderOf(h) .. '/' .. v2file)
  T.eq(app.written[v2file], nil, 'plus rien ne le désigne')
  T.eq(v2.file, nil)
  T.ok(h.written[folderOf(h) .. '/' .. v1.file], 'la référence reste')
  T.eq(app.memory['qualif|sec'].signature, v1.signature, 'la référence d\'avant revient')
  T.eq(#storedKeys(app, ':qualif:sec'), 1)
  T.eq(app.saved.quali.signature, v1.signature, 'repli sur la référence')
  -- calcul sur v2 (chargée) : rien de proposé
  T.ok(waitFor(h, function()
    local last = r.history[#r.history]
    return r.phase == 'tours' and last.note ~= nil and last.note:find('version non gardée', 1, true) ~= nil
  end), 'calcul parti de v2 : rien de proposé')
  T.eq(h.writeCalls, writes, 'aucun nouveau fichier')
  T.contains(r.waiting, 'charger au stand le setup validé')
  frames(h, 1)
  T.ok(shown(h, 'v2 non gardée : pas reproposée. Encore dans la voiture'))
  -- la référence se charge : l'affinage repart d'elle
  loadAtPit(h, app, 'Charger le setup tour rapide dans la voiture')
  T.eq(h.loadCalls[#h.loadCalls], folderOf(h) .. '/' .. v1.file)
  T.eq(r.driven, 1)
  T.eq(app.perf.errors, 0)
end

-- Purge du stockage (§13) : un setup figé de la mémoire part en dernier.
tests['AU07 stockage plein : un setup figé de la mémoire part en dernier'] = function()
  local Store = require('src/store')
  local store = { entries = {} }
  Store.put(store, 'mem:car:trk:-:qualif:sec', { file = 'Fige.ini', hash = 12, locked = true }, 1)
  Store.put(store, 'mem:car:trk:-:essai:sec', { file = 'Valide.ini', hash = 13, locked = false }, 2)
  for i = 1, 2000 do
    Store.put(store, 'last:car' .. i .. ':trk:-:quali', { file = string.rep('x', 60), gain = 0.1, time = 90 }, 10 + i)
  end
  local text = Store.purge(store)
  T.ok(#text <= Config.K.storeMaxBytes)
  T.ok(store.entries['mem:car:trk:-:qualif:sec'], 'figé gardé, malgré la date la plus ancienne')
  T.eq(store.entries['mem:car:trk:-:essai:sec'], nil, 'validé non figé : purgé comme les autres')
end

-- Constat de Vincent du 21/10/2026 (DTM à Spa, SetupLab actif, en roulant) : 29 fichiers écrits en un
-- quart d'heure. Désormais : aucun fichier sans « Valider », un calcul par tour propre, une annonce à l'écran
-- par version au plus ; « Valider » écrit un seul fichier.
tests['AU08 DTM, SetupLab actif, carburant qui baisse, 6 tours : aucun fichier sans « Valider », une annonce par version'] = function()
  local h, app = ready('whk_dtm_2026', 1)
  h.click = 'SetupLab actif'
  frames(h, 1)
  app.handleIntents({ start = 'mine' }) -- 1.5 : point de départ choisi (carte d'étape)

  T.ok(waitFor(h, function() return app.refine and app.refine.active and app.refine.phase == 'tours' end), 'premier calcul')
  local profile = drivenProfile(h, app)
  local fuel = spinner(h, 'FUEL')
  local laps, computes, last = app.recorder.finished, 0, app.quali
  for _ = 1, 200000 do
    frames(h, 1, profile)
    if app.recorder.finished > laps then
      laps = app.recorder.finished
      fuel.value = fuel.value - fuel.step -- réservoir
    end
    if app.quali and app.quali ~= last and app.quali.state == 'done' then computes, last = computes + 1, app.quali end
    if app.recorder.finished >= 6 and app.refine.phase == 'tours' then break end
  end
  local r = app.refine
  PY.note('AU08', app.recorder.finished .. ' tours, ' .. computes .. ' calculs, v' .. r.version .. ', '
    .. #(h.messages or {}) .. ' annonce(s)')
  T.ok(app.recorder.finished >= 6, app.recorder.finished .. ' tours')
  T.eq(setupFiles(h), 0, 'aucun fichier de setup sans « Valider »')
  T.ok(computes >= 3, 'un calcul par tour propre : ' .. computes)
  T.ok(computes <= app.recorder.finished + 1, 'jamais deux calculs sur les mêmes données : ' .. computes)
  T.ok(r.version >= 1, 'au moins une version proposée')
  T.ok(#(h.messages or {}) >= 1 and #h.messages <= r.version, 'une annonce par version au plus')
  h.click = 'Valider v' .. r.version
  frames(h, 1, profile)
  T.eq(setupFiles(h), 1, 'un seul fichier, à la validation')
  T.eq(app.perf.errors, 0)
end

-- Vos temps (demande de Vincent du 22/10/2026 : « se baser sur mes temps à moi ») : sur la DTM, la
-- répartition de freinage touchée au volant ne fait pas perdre les tours de la version chargée ; vos temps,
-- l'objectif estimé et le gain réel s'affichent, les temps simulés passent au survol.
tests['AU09 DTM : tours rattachés à la version chargée malgré la répartition de freinage ; vos temps affichés'] = function()
  local h, app = ready('whk_dtm_2026')
  h.click = 'Affinage automatique (tour rapide)'
  frames(h, 1)
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end), 'v1')
  local v1 = r.history[#r.history]
  -- tours avec le setup de départ : objectif estimé sur vos temps
  local profile = drivenProfile(h, app)
  T.ok(waitFor(h, function()
    local f = app.recorder.laps.family[v1.originFamily]
    return f ~= nil and f.count >= 1 and r.phase == 'tours'
  end, nil, profile), 'un tour propre avec le setup de départ')
  frames(h, 1, profile)
  T.ok(shown(h, 'objectif estimé'), 'objectif estimé sur vos temps')
  h.click = 'Valider v' .. r.version
  frames(h, 1, profile)
  local v = r.history[#r.history]
  T.eq(v.status, 'validée', tostring(app.ui.message))
  loadAtPit(h, app, 'Charger le setup tour rapide dans la voiture')
  T.eq(r.driven, v.version)
  T.ok(waitFor(h, function() return not r.needsDiscovery and app.discoveryState == 'done' end))
  -- répartition de freinage touchée (au volant, au stand) : autre signature, même famille
  local bias = spinner(h, 'FRONT_BIAS')
  bias.value = bias.value + bias.step
  profile = drivenProfile(h, app)
  T.ok(waitFor(h, function()
    local f = app.recorder.laps.family[v.family]
    return f ~= nil and f.count >= 2
  end, 120000, profile), 'deux tours valides crédités à v' .. v.version)
  T.eq(app.recorder.laps.best[v.signature], nil, 'signature complète : aucun tour (répartition différente)')
  frames(h, 1, profile)
  T.ok(shown(h, 'Vos temps : v' .. v.version .. ' '), 'vos temps avec la version')
  T.ok(shown(h, '(2 tours)') or shown(h, '(3 tours)'), 'nombre de tours dit')
  T.eq(app.perf.errors, 0)
end

-- Chargement visible (constat de Vincent du 22/10/2026 : « on ne voit pas le bouton de chargement ») : état
-- du stand à côté du bouton, refus dit dessous (pas seulement en haut de la fenêtre), confirmation avec le
-- temps restant, annulation.
tests['AU10 chargement : état du stand et refus sous le bouton, confirmation avec le temps restant, annulation'] = function()
  local h, app = ready()
  h.click = 'Affinage automatique (tour rapide)'
  frames(h, 1)
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end), 'v1')
  frames(h, 1)
  T.ok(shown(h, 'Étape 3/4 · Essayer v1') or shown(h, 'Étape 2/4 · Rouler'), 'étape suivante dite')
  h.click = 'Valider v1'
  frames(h, 1)
  -- au stand, menu de setup fermé
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  h.setupEditable = false
  frames(h, 2)
  T.ok(shown(h, 'Pour charger :'), 'état du stand')
  T.ok(shown(h, 'au stand (oui)'))
  T.ok(shown(h, 'menu de setup ouvert (non)'))
  h.click = 'Charger le setup tour rapide dans la voiture'
  frames(h, 1)
  T.eq(app.loadArm, nil)
  frames(h, 1)
  T.ok(shown(h, 'Chargement impossible : setup non modifiable'), 'refus dit sous le bouton')
  -- menu ouvert : armé, confirmation avec le temps restant ; annuler
  h.setupEditable = nil
  frames(h, 2)
  T.ok(shown(h, 'Prêt à charger :'))
  h.click = 'Charger le setup tour rapide dans la voiture'
  frames(h, 1)
  T.ok(app.loadArm, tostring(app.ui.message))
  frames(h, 1)
  T.ok(shown(h, 'Il reste '), 'temps restant')
  h.click = 'Annuler le chargement (tour rapide)'
  frames(h, 1)
  T.eq(app.loadArm, nil, 'annulé')
  T.contains(app.ui.message, 'Chargement annulé')
  T.eq(#h.loadCalls, 0)
  -- puis chargé pour de bon
  loadAtPit(h, app, 'Charger le setup tour rapide dans la voiture')
  T.eq(#h.loadCalls, 1)
  T.eq(app.perf.errors, 0)
end

-- Vos retouches (décision de Vincent du 22/10/2026 : « s'il a calculé un setup, que je l'ai chargé et que je
-- reviens dans les stands et que je modifie un petit peu le setup, il faut qu'il le prenne en compte ») : le
-- réglage retouché après le chargement reste à votre valeur dans les calculs suivants, jusqu'à les libérer.
tests['AU11 retouche au stand après un chargement : gardée par les calculs suivants ; libérer : de nouveau calculée'] = function()
  local h, app = ready()
  h.click = 'Affinage automatique (tour rapide)'
  frames(h, 1)
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end), 'v1')
  local v1 = r.history[#r.history]
  -- un réglage changé par v1 : celui que le pilote va retoucher
  local change = v1.changeList[1]
  local name = change.var.members[1].name
  h.click = 'Valider v1'
  frames(h, 1)
  h.click = 'Arrêter l\'affinage (tour rapide)'
  frames(h, 1)
  T.ok(waitFor(h, function() return app.quali and app.quali.state ~= 'running' end))
  loadAtPit(h, app, 'Charger le setup tour rapide dans la voiture')
  local sp = spinner(h, name)
  local loaded = sp.value
  -- retouche à la main, au stand : un cran vers le setup d'avant
  local step = (change.clicks > 0) and -sp.step or sp.step
  sp.value = sp.value + step
  h.click = 'Calculer le setup tour rapide'
  frames(h, 1)
  T.ok(waitFor(h, function() return app.quali and app.quali.state ~= 'running' and app.discoveryState == 'done' end), 'calcul')
  T.eq(app.quali.state, 'done', tostring(app.quali.error))
  T.ok(app.pins.quali[name], 'retouche relevée : ' .. name)
  T.eq(app.pins.quali[name].from, loaded)
  T.eq(app.pins.quali[name].value, loaded + step)
  for _, c in ipairs(app.quali.result.changes) do
    T.ok(c.var.key ~= change.var.key, change.var.label .. ' changé malgré la retouche')
  end
  T.eq(app.quali.pinned[1], change.var.label)
  frames(h, 1)
  T.ok(shown(h, 'Vos retouches gardées (tour rapide) : ' .. change.var.label), 'retouches affichées')
  -- libérer : le calcul suivant peut de nouveau le changer
  h.click = 'Libérer vos retouches (tour rapide)'
  frames(h, 1)
  T.eq(next(app.pins.quali), nil)
  T.contains(app.ui.message, 'Retouches libérées')
  h.click = 'Calculer le setup tour rapide'
  frames(h, 1)
  T.ok(waitFor(h, function() return app.quali and app.quali.state ~= 'running' end))
  T.eq(#app.quali.pinned, 0)
  T.eq(app.perf.errors, 0)
end

-- CSP gratuite (0.2.11 ; décision de Vincent du 22/10/2026 : l'app doit fonctionner sans la preview payante).
-- SDK comparé : io.available, ac.getAssists et ac.getSetupTabs y sont absents, comme le champ isTrackOpen. Le
-- cycle complet marche : découverte, calcul, Valider (fichier écrit puis relu), chargement au stand.
tests['AU12 CSP 0.2.11 (gratuite) : sans io.available, getAssists ni getSetupTabs, le cycle complet marche'] = function()
  local h, app = ready(nil, 2, { missing = { 'io.available', 'ac.getAssists', 'ac.getSetupTabs' } })
  T.ok(app.static.ioAvailable and app.static.ioAssumed, 'accès fichiers supposé')
  h.click = 'Affinage automatique (tour rapide)'
  frames(h, 1)
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end), 'v1')
  h.click = 'Valider v1'
  frames(h, 1)
  T.eq(r.history[1].status, 'validée', tostring(app.ui.message))
  T.eq(setupFiles(h), 1, 'fichier écrit et relu')
  loadAtPit(h, app, 'Charger le setup tour rapide dans la voiture')
  T.eq(#h.loadCalls, 1)
  T.eq(app.perf.errors, 0)
end

-- Décision de Vincent du 22/10/2026 : « quand on a appliqué la V1, on retourne en piste pour rouler [...] qu'il donne
-- juste un message en disant j'ai le minimum d'informations et tant que l'utilisateur n'est pas retourné dans les
-- stands, on continue d'analyser les données ». En piste : une annonce « en préparation » par version, mises à jour
-- silencieuses à chaque tour propre ; au stand : « prêt », avec les tours analysés ; de nouveau si elle a changé.
tests['AU13 en piste : « en préparation » une fois, analyse continue ; au stand : « prêt » avec les tours analysés'] = function()
  local h, app = ready()
  h.click = 'Affinage automatique (tour rapide)'
  frames(h, 1)
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end), 'v1')
  T.eq(h.messages[#h.messages].title, 'SetupLab : setup tour rapide v1 prêt', 'calculée au stand : prête tout de suite')
  h.click = 'Valider v1'
  frames(h, 1)
  loadAtPit(h, app, 'Charger le setup tour rapide dans la voiture')
  T.ok(waitFor(h, function() return not r.needsDiscovery and app.discoveryState == 'done' and r.phase == 'tours' end))
  -- en piste avec v1 (autre base : pincement) : v2 en préparation, une seule annonce
  toe(h)
  local profile = drivenProfile(h, app)
  T.ok(waitFor(h, function() return r.version >= 2 and r.phase == 'tours' end, nil, profile), 'v2')
  local v2 = r.history[#r.history]
  T.eq(v2.ready, false, 'provisoire en piste')
  T.eq(h.messages[#h.messages].title, 'SetupLab : setup tour rapide v2 en préparation')
  T.contains(h.messages[#h.messages].description, 'minimum d\'informations')
  T.contains(app.ui.message, 'en préparation')
  frames(h, 1, profile)
  T.ok(shown(h, 'v2 en préparation : gain prévu provisoire'), 'carte : provisoire')
  T.ok(shown(h, 'prête à votre retour au stand'), 'carte : quand')
  h.texts = {}
  script.SETUPLAB__OVERLAY(1 / 60)
  T.ok(shown(h, 'v2 en préparation : '), 'overlay : provisoire')
  -- un autre tour propre : mise à jour silencieuse
  local count = #h.messages
  T.ok(waitFor(h, function() return (v2.updates or 0) >= 1 and r.phase == 'tours' end, 150000, profile), 'v2 mise à jour')
  T.eq(#h.messages, count, 'aucune nouvelle annonce en piste')
  T.eq(v2.ready, false)
  -- retour au stand : prête, avec les tours analysés
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  h.driver = nil
  T.ok(waitFor(h, function() return v2.ready == true end, 600), 'prête au stand')
  T.eq(#h.messages, count + 1)
  T.eq(h.messages[#h.messages].title, 'SetupLab : setup tour rapide v2 prêt')
  T.contains(h.messages[#h.messages].description, 'analysé')
  frames(h, 1)
  T.ok(shown(h, 'v2 prête : gain prévu'), 'carte : prête')
  frames(h, 30)
  T.eq(#h.messages, count + 1, 'une seule annonce au stand')
  -- de nouveau en piste : un nouveau calcul (silencieux) ; au stand suivant, annoncée de nouveau seulement si elle
  -- a changé (même setup recalculé : elle reste prête)
  local updates, lastQ = v2.updates, app.quali
  T.ok(waitFor(h, function() return app.quali ~= lastQ and app.quali.state == 'done' and r.phase == 'tours' end, 150000, profile),
    'nouveau calcul en piste')
  T.eq(#h.messages, count + 1, 'toujours silencieux en piste')
  local changed = v2.updates > updates
  T.eq(v2.ready, not changed, 'provisoire seulement si elle a changé')
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  h.driver = nil
  T.ok(waitFor(h, function() return v2.ready == true end, 600))
  frames(h, 30)
  T.eq(#h.messages, count + (changed and 2 or 1), changed and 'changée : annoncée de nouveau' or 'inchangée : pas de nouvelle annonce')
  PY.note('AU13', 'v2 ' .. (changed and 'changée' or 'inchangée') .. ' au deuxième passage, ' .. #h.messages .. ' annonces')
  T.eq(app.perf.errors, 0)
end


-- Constat de Vincent du 29/10/2026 (KillerOne, Spa, un tour minimum) : « il ne détecte pas quand je fais un tour ».
-- Après le tour propre, l'overlay le dit tout de suite et annonce le calcul ; un calcul sans gain suffisant le dit aussi
-- (overlay et une annonce à l'écran), au lieu de rester muet.
tests['AU14 un tour minimum : tour compté et calcul dits tout de suite ; setup déjà au mieux : dit'] = function()
  local h, app = ready('whk_dtm_2026', 1)
  app.settings.refineMinLaps, app.settings.refineInstantFirst = 1, false
  local K = Config.K
  local minGain = K.refineMinGain
  K.refineMinGain = 1000 -- aucun gain suffisant : le setup actuel est gardé
  app.handleIntents({ start = 'mine' })
  frames(h, 2)
  local r = app.refine
  T.contains(r.waiting, '0/1')
  local profile = drivenProfile(h, app)
  local start = app.recorder.finished
  T.ok(waitFor(h, function() return app.recorder.finished > start end, 120000, profile), 'tour fini')
  T.ok(app.recorder.laps.last.valid, tostring(app.recorder.laps.last.reason))
  local function overlay(text)
    h.texts = {}
    script.SETUPLAB__OVERLAY(1 / 60)
    return shown(h, text)
  end
  frames(h, 1, profile)
  T.ok(overlay('tour propre compté'), 'tour compté, dit dans l\'overlay')
  T.ok(overlay('calcul du setup en cours'), 'calcul en cours, dit dans l\'overlay')
  T.no(overlay('0/1 tour propre'), 'overlay : plus de « 0/1 » une fois le tour compté')
  frames(h, 1, profile)
  T.no(shown(h, '0/1 tour propre'), 'fenêtre : plus de « 0/1 » une fois le tour compté')
  T.ok(waitFor(h, function() return r.phase == 'tours' and r.noGainNoticed end, 60000, profile), 'calcul terminé')
  K.refineMinGain = minGain
  T.contains(r.waiting, 'déjà le meilleur trouvé')
  local found = false
  for _, m in ipairs(h.messages or {}) do found = found or tostring(m.title):find('analysé', 1, true) ~= nil end
  T.ok(found, 'annoncé à l\'écran')
  T.ok(overlay('déjà le meilleur trouvé'), 'dit dans l\'overlay')
  frames(h, 1, profile)
  T.ok(shown(h, 'déjà le meilleur trouvé'), 'dit dans la carte d\'étape')
  T.eq(app.perf.errors, 0)
end

return tests
