-- Bêta 1.5 (demandes de Vincent du 26/10/2026) : minimum avant une proposition (tours propres et minutes), setup de
-- course qui part du setup de qualification validé avec un nombre de tours saisi, effets d'une version gardés ou
-- refusés un par un après un essai complet.
local T = require('t')
local Config = require('src/config')
local Exporter = require('src/exporter')
local Store = require('src/store')
local CarModel = require('src/car_model')
local Sim = require('src/laptime_sim')
local Fake = require('fakehost')

local TRUTH = { mu = 0.96, power = 0.98, drag = 1.02, lift = 1.0, brake = 1.0 }

local tests = {}

local function boot(opts)
  opts = opts or {}
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza'),
    stored = opts.stored, lang = opts.lang, skin = opts.skin, cdata = opts.cdata })
  h.sim.raceSessionType = opts.session or 2
  h.texts = {}
  local function capture(text) h.texts[#h.texts + 1] = text end
  local text, wrapped, colored = h.ui.text, h.ui.textWrapped, h.ui.textColored
  h.ui.text = function(s) capture(s); return text(s) end
  h.ui.textWrapped = function(s) capture(s); return wrapped(s) end
  h.ui.textColored = function(s, c) capture(s); return colored(s, c) end
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  app.utcOffset = function() return 7200 end
  app.settings.optBudgetEvalsQ, app.settings.optBudgetEvalsC = 80, 20
  return h, app
end

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

local function ready(opts)
  local h, app = boot(opts)
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  app.settings.compoundChoice = app.discovery.compoundIndex
  return h, app
end

local function folderOf(h)
  return assert(Exporter.targetFolder({ ac = h.ac, io = h.io }))
end

local function spinner(h, name)
  for _, sp in ipairs(h.spinners) do
    if sp.name == name then return sp end
  end
  return nil
end

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

local function stop(h)
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  h.driver = nil
end

local function loadAtPit(h, app, kind)
  stop(h)
  frames(h, 1)
  h.click = 'Charger le setup ' .. (kind == 'race' and 'course' or 'tour rapide') .. ' dans la voiture'
  frames(h, 1)
  T.ok(app.loadArm, tostring(app.ui.message))
  local started = app.clock()
  while app.clock() - started < Config.K.loadConfirmMinSeconds + 0.1 do frames(h, 1) end
  h.click = 'Confirmer le chargement (' .. (kind == 'race' and 'course' or 'tour rapide') .. ')'
  frames(h, 1)
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'constat du chargement')
  T.ok(app.loadTest and app.loadTest.ok, tostring(app.loadTest and app.loadTest.reason) .. ' / ' .. tostring(app.ui.message))
end

tests['NV01 minimum avant une proposition : tours propres puis minutes, avec le setup en cours'] = function()
  local h, app = ready({ stored = {} })
  T.eq(app.settings.refineMinLaps, 2, 'défaut : deux tours propres')
  h.click = 'Affinage automatique (tour rapide)'
  frames(h, 1)
  local r = app.refine
  T.eq(r.version, 0, 'rien de proposé sans tour')
  T.contains(r.waiting, '0/2 tours propres')
  frames(h, 120)
  T.eq(app.quali, nil, 'aucun calcul avant le minimum')
  local profile = drivenProfile(h, app)
  T.ok(waitFor(h, function() return (r.minLaps or 0) >= 1 end, nil, profile), 'un tour propre')
  T.eq(r.version, 0, 'un tour : toujours rien')
  T.contains(r.waiting, '1/2')
  T.ok(waitFor(h, function() return r.version >= 1 end, nil, profile), 'deux tours : v1')
  T.ok(r.minLaps >= 2)
  -- minutes : seuil en plus (les deux sont requis), compté seulement en roulant
  local h2, app2 = ready({ stored = {} })
  app2.settings.refineMinLaps, app2.settings.refineMinMinutes = 0, 1
  h2.click = 'Affinage automatique (tour rapide)'
  frames(h2, 1)
  local r2 = app2.refine
  frames(h2, 600)
  T.eq(r2.version, 0, 'au stand : le temps ne compte pas')
  T.contains(r2.waiting, '0.0/1 min')
  local p2 = drivenProfile(h2, app2)
  T.ok(waitFor(h2, function() return r2.version >= 1 end, nil, p2), 'une minute de roulage : v1')
  T.ok(r2.minTime >= 60, tostring(r2.minTime))
  T.eq(app.perf.errors + app2.perf.errors, 0)
end

tests['NV02 setup de course : qualification validée, montée dans la voiture, nombre de tours saisi'] = function()
  local h, app = ready()
  app.handleIntents({ raceStart = true })
  T.eq(app.race, nil)
  T.contains(app.ui.message, 'valider d\'abord un setup de tour rapide')
  -- qualification validée (affinage), mais une autre base dans la voiture
  h.click = 'Affinage automatique (tour rapide)'
  frames(h, 1)
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end), 'v1')
  h.click = 'Valider v1'
  frames(h, 1)
  T.ok(app.memory['qualif|sec'], 'référence de qualification')
  h.click = 'Arrêter l\'affinage (tour rapide)'
  frames(h, 1)
  T.ok(waitFor(h, function() return app.quali == nil or app.quali.state ~= 'running' end))
  app.handleIntents({ raceStart = true })
  T.eq(app.race, nil)
  T.contains(app.ui.message, 'charger d\'abord le setup de qualification validé')
  -- chargée au stand : il manque le nombre de tours
  app.handleIntents({ raceRefLoad = true })
  T.ok(app.loadArm, tostring(app.ui.message))
  local started = app.clock()
  while app.clock() - started < Config.K.loadConfirmMinSeconds + 0.1 do frames(h, 1) end
  app.handleIntents({ loadConfirm = 'quali' })
  T.ok(waitFor(h, function() return app.loadCheck == nil end))
  T.ok(app.loadTest and app.loadTest.ok, tostring(app.loadTest and app.loadTest.reason))
  local why, action = app.raceBlocker()
  T.eq(action, 'laps', tostring(why))
  app.handleIntents({ raceLaps = '0' })
  T.contains(app.ui.message, 'refusé')
  app.handleIntents({ raceLaps = '18' })
  T.eq(app.raceLaps, 18)
  local key = Store.entryKey('rlaps', app.discovery.car.id, 'monza', '-')
  T.eq(Store.get(app.store, key).laps, 18, 'gardé pour ce circuit')
  T.eq(app.raceBlocker(), nil)
  app.handleIntents({ raceStart = true })
  T.ok(waitFor(h, function() return app.race and app.race.state ~= 'running' end), 'calcul course')
  T.eq(app.race.state, 'done', tostring(app.race.error))
  T.eq(app.race.result.race.laps, 18, 'tours saisis')
  T.eq(app.perf.errors, 0)
end

tests['NV03 affinage en séance de course : en attente de la garde, sans calcul ni erreur'] = function()
  local h, app = ready({ session = 3 })
  h.click = 'SetupLab actif'
  frames(h, 1)
  app.handleIntents({ start = 'mine' }) -- 1.5 : point de départ choisi (carte d'étape)

  T.ok(waitFor(h, function() return app.refine and app.refine.active end))
  T.eq(app.refine.kind, 'race')
  frames(h, 300)
  T.eq(app.race, nil, 'aucun calcul course sans qualification validée')
  T.contains(app.refine.waiting, 'course : valider d\'abord')
  T.eq(app.perf.errors, 0)
end

tests['NV04 effets un par un : essai complet, un groupe refusé, version avec les seuls effets gardés'] = function()
  local h, app = ready()
  local folder = folderOf(h)
  h.click = 'Affinage automatique (tour rapide)'
  frames(h, 1)
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end), 'v1')
  local e = r.history[#r.history]
  T.ok(#e.groups >= 2, 'au moins deux effets : ' .. #e.groups)
  for _, g in ipairs(e.groups) do T.eq(g.keep, true, 'gardé par défaut : ' .. g.key) end
  -- essai : fichier d'essai, version entière
  app.handleIntents({ refineJudge = { version = 1, verdict = 'essayer' } })
  T.eq(e.status, 'essai', tostring(app.ui.message))
  T.eq(e.trial.file, 'SetupLab_Qualif_v1_essai.ini')
  T.eq(h.written[folder .. '/SetupLab_Qualif_v1_essai.ini'], e.text)
  T.eq(app.memory['qualif|sec'], nil, 'pas encore de référence')
  loadAtPit(h, app)
  T.eq(r.driven, 1, 'essai dans la voiture')
  T.ok(waitFor(h, function() return not r.needsDiscovery and app.discoveryState == 'done' end))
  frames(h, 30)
  T.ok(r.version == 1, 'rien de nouveau pendant l\'essai')
  -- tri : le premier groupe refusé
  local refused = e.groups[1]
  app.handleIntents({ effect = { version = 1, key = refused.key, keep = false } })
  local _, total = app.keptCount(e)
  T.eq(app.keptCount(e), total - #refused.items, 'groupe refusé : tous ses réglages')
  local trialSignature = e.signature
  app.handleIntents({ refineJudge = { version = 1, verdict = 'valider' } })
  T.eq(e.status, 'validée', tostring(app.ui.message))
  T.eq(e.file, 'SetupLab_Qualif_v1.ini')
  T.ok(e.signature ~= trialSignature, 'version partielle : autre setup')
  local final = h.written[folder .. '/SetupLab_Qualif_v1.ini']
  T.ok(final, 'fichier de la version')
  local values = app.setupValues(final)
  for _, item in ipairs(refused.items) do
    if item.change then
      for _, m in ipairs(item.change.var.members) do
        T.eq(values[m.name], m.current, 'effet refusé : ancienne valeur ' .. m.name)
        T.ok(app.pins.quali[m.name] and app.pins.quali[m.name].refused, 'gardé pour la suite : ' .. m.name)
      end
    end
  end
  for _, g in ipairs(e.groups) do
    if g.keep then
      for _, item in ipairs(g.items) do
        if item.change then
          for _, m in ipairs(item.change.var.members) do
            T.ok(values[m.name] ~= m.current, 'effet gardé : nouvelle valeur ' .. m.name)
          end
        end
      end
    end
  end
  T.eq(app.memory['qualif|sec'].file, 'SetupLab_Qualif_v1.ini', 'référence : version partielle')
  T.eq(app.saved.quali.name, 'SetupLab_Qualif_v1.ini', 'à charger')
  T.ok(r.rejected[trialSignature], 'l\'essai n\'est plus une base de calcul')
  stop(h)
  T.ok(waitFor(h, function() return h.written[folder .. '/SetupLab_Qualif_v1_essai.ini'] == nil end, 10), 'essai à la Corbeille')
  T.eq(app.perf.errors, 0)
end

tests['NV05 effets : tout gardé après l\'essai, le fichier d\'essai devient la version (renommé)'] = function()
  local h, app = ready()
  local folder = folderOf(h)
  h.click = 'Affinage automatique (tour rapide)'
  frames(h, 1)
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end), 'v1')
  local e = r.history[#r.history]
  app.handleIntents({ refineJudge = { version = 1, verdict = 'essayer' } })
  local trialText = e.text
  app.handleIntents({ refineJudge = { version = 1, verdict = 'valider' } })
  T.eq(e.status, 'validée', tostring(app.ui.message))
  T.eq(e.file, 'SetupLab_Qualif_v1.ini')
  T.eq(h.written[folder .. '/SetupLab_Qualif_v1.ini'], trialText)
  T.eq(h.written[folder .. '/SetupLab_Qualif_v1_essai.ini'], nil, 'renommé, pas copié')
  T.eq(#h.moves, 1)
  -- aucun effet gardé : refusé, il faut « Recommencer »
  local h2, app2 = ready()
  h2.click = 'Affinage automatique (tour rapide)'
  frames(h2, 1)
  local r2 = app2.refine
  T.ok(waitFor(h2, function() return r2.version >= 1 and r2.phase == 'tours' end))
  local e2 = r2.history[#r2.history]
  for _, g in ipairs(e2.groups) do app2.handleIntents({ effect = { version = 1, key = g.key, keep = false } }) end
  app2.handleIntents({ refineJudge = { version = 1, verdict = 'valider' } })
  T.eq(e2.status, nil)
  T.contains(app2.ui.message, 'aucun réglage gardé')
  T.eq(app.perf.errors + app2.perf.errors, 0)
end

local function shownText(h, needle)
  for _, s in ipairs(h.texts) do
    if type(s) == 'string' and s:find(needle, 1, true) then return true end
  end
  return false
end

-- Interface (demande de Vincent du 26/10/2026) : étape en cours toujours en tête, effets gardés ou refusés d'un clic,
-- « Essayer », puis « Valider vN (k/n effets) » ; mêmes boutons quelle que soit la langue.
tests['NV06 interface : départ, essai, « Modifier… » réglage par réglage, validation'] = function()
  local h, app = ready({ skin = true })
  frames(h, 1)
  T.ok(shownText(h, 'Étape 1/4 · Départ'), 'étape 1 : départ à choisir')
  T.ok(shownText(h, 'Mon setup actuel') and shownText(h, 'Setup par défaut de la voiture'), 'deux départs proposés')
  h.click = 'start_mine'
  frames(h, 1)
  T.eq(app.auto, true, 'le choix active SetupLab')
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end), 'v1')
  frames(h, 1)
  T.ok(shownText(h, 'Étape 3/4 · Essayer v1'), 'étape 3')
  T.ok(shownText(h, 'changé'), 'réglages changés résumés')
  local e = r.history[#r.history]
  local item = e.groups[1].items[1]
  local id = 'effect_quali_1_' .. item.key
  -- détail fermé : pas de bouton par réglage
  h.click = id
  frames(h, 1)
  T.eq(item.keep, true, 'détail fermé : rien à cliquer')
  h.click = 'modify_quali_1'
  frames(h, 1)
  h.click = id
  frames(h, 1)
  T.eq(item.keep, false, 'refusé d\'un clic')
  h.click = id
  frames(h, 1)
  T.eq(item.keep, true, 'gardé de nouveau')
  h.click = 'step_action'
  frames(h, 1)
  T.eq(e.status, 'essai', tostring(app.ui.message))
  frames(h, 1)
  T.ok(shownText(h, 'Fichier d\'essai écrit : au stand'), 'étape 3 : charger l\'essai')
  h.click = id
  frames(h, 1)
  T.eq(item.keep, false, 'refus pendant l\'essai')
  h.click = 'Valider v1'
  frames(h, 1)
  T.eq(e.status, 'validée', tostring(app.ui.message))
  local kept, total = app.keptCount(e)
  T.eq(kept, total - 1, 'un seul réglage refusé')
  T.eq(app.perf.errors, 0)
end

-- Onglet Course : trois conditions dites, nombre de tours au curseur (gardé pour ce circuit).
tests['NV07 interface course : conditions, chargement de la référence, nombre de tours au curseur'] = function()
  local h, app = ready({ skin = true })
  h.tab = 'Course'
  frames(h, 1)
  T.ok(shownText(h, '1. Qualification validée : aucune'), 'condition 1')
  T.ok(shownText(h, 'au moins une v1'), 'course verrouillée avant une qualification validée')
  h.sliders = { race_laps = 22 }
  frames(h, 1)
  T.eq(app.raceLaps, 22, tostring(app.ui.message))
  frames(h, 1)
  T.ok(shownText(h, '3. Tours de la course : 22'), 'tours affichés')
  h.tab = nil
  T.eq(app.perf.errors, 0)
end

-- Langue : badge EN/FR dans l'en-tête, choix dans les réglages ; aide sur chaque réglage modifiable.
tests['NV08 langue au badge, aide de chaque réglage'] = function()
  local h, app = ready({ skin = true })
  T.eq(app.settings.language, 'fr')
  h.click = 'lang_toggle'
  frames(h, 1)
  T.eq(app.settings.language, 'en', 'badge : anglais')
  frames(h, 1)
  T.ok(shownText(h, 'Step 1/4 · Start'), 'interface en anglais')
  T.no(shownText(h, 'Étape 1/4'), 'plus de français')
  h.tab, h.click = 'Réglages', 'lang_fr'
  frames(h, 1)
  h.tab = nil
  T.eq(app.settings.language, 'fr', 'réglages : français')
  for _, key in ipairs(Config.EDITABLE) do
    T.ok(type(Config.help[key]) == 'string' and #Config.help[key] > 20, 'aide du réglage ' .. key)
  end
  T.eq(app.perf.errors, 0)
end

-- Noms des fichiers dans la langue choisie (décision de Vincent du 26/10/2026) : en anglais, Quali / Race / Wet,
-- _trial, Before_load ; numéros de version à la suite des fichiers déjà écrits en français.
tests['NV09 noms de fichiers en anglais, numérotés à la suite des fichiers français'] = function()
  local h, app = ready({ lang = 'en', stored = { ['setuplab:data'] = 'setuplab-store 1|settings#refineMinLaps=0|settings#language=s:en' } })
  T.eq(app.settings.language, 'en')
  local folder = folderOf(h)
  h.written[folder .. '/SetupLab_Qualif_v4.ini'] = h.ac.stringifyCurrentSetup(true, false)
  T.eq(app.fileBase('quali', 'sec'), 'SetupLab_Quali')
  T.eq(app.fileBase('race', 'pluie'), 'SetupLab_Race_Wet')
  app.handleIntents({ refineStart = 'quali' })
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 5 and r.phase == 'tours' end), 'v5 après la v4 française')
  app.handleIntents({ refineJudge = { version = 5, verdict = 'essayer' } })
  local e = r.history[#r.history]
  T.eq(e.trial and e.trial.file, 'SetupLab_Quali_v5_trial.ini', tostring(app.ui.message))
  loadAtPit(h, app)
  local backups = 0
  for path in pairs(h.written) do
    if path:find('/SetupLab_Before_load_', 1, true) then backups = backups + 1 end
    T.no(path:find('Avant_chargement', 1, true), 'pas de nom français : ' .. path)
  end
  T.eq(backups, 1, 'copie de sauvegarde en anglais')
  app.handleIntents({ refineJudge = { version = 5, verdict = 'valider' } })
  T.eq(e.file, 'SetupLab_Quali_v5.ini', tostring(app.ui.message))
  -- un nom choisi qui finit par le genre français : pas de genre en double
  app.handleIntents({ name = { kind = 'quali', text = 'Mon reglage Qualif' } })
  T.eq(app.fileBase('quali', 'sec'), 'Mon_reglage_Qualif')
  T.eq(app.perf.errors, 0)
end

-- Thème SuperHUD (demande de Vincent du 26/10/2026 : « la même interface, les mêmes couleurs, le même fond… que
-- SuperHUD ») : en-tête, onglets dessinés (un clic change d'onglet, seul l'onglet choisi est dessiné), interrupteur
-- « SetupLab actif », sans contrôle ImGui pour les boutons, cases et onglets.
tests['NV10 thème SuperHUD : onglets dessinés, interrupteur, boutons plats'] = function()
  local h, app = ready({ skin = true })
  local imgui = { button = 0, checkbox = 0, tabItem = 0 }
  for name in pairs(imgui) do
    local real = h.ui[name]
    h.ui[name] = function(...)
      imgui[name] = imgui[name] + 1
      return real(...)
    end
  end
  frames(h, 1)
  T.ok(shownText(h, 'SETUPLAB'), 'en-tête')
  T.ok(shownText(h, 'QUALIF') and shownText(h, 'AIDE'), 'onglets dessinés')
  T.eq(app.ui.tab, 'Tour rapide', 'onglet par défaut')
  T.ok(shownText(h, 'Tour rapide : essai'), 'contenu de l\'onglet QUALIF')
  T.no(shownText(h, 'Mesure et calibration'), 'les autres onglets ne sont pas dessinés')
  h.click = 'tab_Mesure'
  frames(h, 1)
  T.eq(app.ui.tab, 'Mesure', 'un clic change d\'onglet')
  frames(h, 1)
  T.ok(shownText(h, 'Mesure et calibration'), 'contenu de l\'onglet MESURE')
  T.no(shownText(h, 'Tour rapide : essai'), 'QUALIF masqué')
  h.click = 'SetupLab actif'
  frames(h, 1)
  T.eq(app.auto, true, 'interrupteur')
  h.click = 'lang_toggle'
  frames(h, 1)
  T.eq(app.settings.language, 'en', 'badge de langue')
  frames(h, 1)
  T.ok(shownText(h, 'MEASURE'), 'onglets en anglais')
  T.eq(imgui.button + imgui.checkbox + imgui.tabItem, 0, 'aucun bouton, case ni onglet ImGui')
  T.eq(app.perf.errors, 0)
end

-- Constat en jeu de Vincent (26/10/2026, capture) : fenêtre transparente, contrôles ImGui. CSP expose une partie de ui
-- en fonctions C (cdata) : le thème doit les reconnaître comme appelables, et la traduction aussi.
tests['NV11 fonctions C de CSP : thème actif, textes traduits'] = function()
  local h, app = ready({ skin = true, cdata = true })
  T.eq(type(h.ui.dwriteText), 'table', 'banc : fonction non Lua')
  frames(h, 1)
  T.ok(shownText(h, 'SETUPLAB'), 'en-tête du thème')
  h.tab = 'Capacités'
  frames(h, 1)
  T.ok(shownText(h, 'Thème SuperHUD : actif'), 'thème actif')
  h.tab = nil
  app.handleIntents({ setting = { key = 'language', value = 'en' } })
  frames(h, 1)
  T.ok(shownText(h, 'Step 1/4 · Start'), 'texte traduit')
  T.eq(app.perf.errors, 0)
end

-- Départ du setup par défaut (demande de Vincent du 26/10/2026) : écrit dans un fichier SetupLab, chargé au stand ;
-- l'affinage attend le chargement ; un setup personnel chargé ensuite depuis AC ne laisse aucune retouche gardée.
tests['NV12 départ : setup par défaut écrit puis chargé ; mon setup sans retouches gardées'] = function()
  local h, app = ready()
  local folder = folderOf(h)
  -- un réglage changé à la main, pour que le setup par défaut diffère du setup en cours
  local arb = spinner(h, 'ARB_FRONT')
  arb.value = arb.value + (arb.value + (arb.step or 1) <= arb.max and (arb.step or 1) or -(arb.step or 1))
  app.handleIntents({ rediscover = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  app.handleIntents({ start = 'default' })
  local s = app.start.quali
  T.eq(s and s.mode, 'default', tostring(app.ui.message))
  T.eq(s.file, 'SetupLab_Defaut.ini')
  T.ok(h.written[folder .. '/SetupLab_Defaut.ini'], 'fichier du setup par défaut')
  T.eq(s.ready, false, 'à charger au stand')
  T.eq(app.saved.quali.name, 'SetupLab_Defaut.ini', 'setup à charger')
  frames(h, 120)
  T.eq(app.refine.version, 0, 'rien de proposé avant le chargement')
  T.contains(app.refine.waiting, 'charger le setup de départ')
  loadAtPit(h, app)
  T.eq(arb.value, arb.defaultValue, 'réglage revenu à sa valeur par défaut')
  T.eq(app.start.quali.ready, true, 'départ dans la voiture')
  -- setup personnel chargé ensuite depuis le menu d'AC, puis « Mon setup actuel » : aucune retouche gardée
  arb.value = arb.value + (arb.value + (arb.step or 1) <= arb.max and (arb.step or 1) or -(arb.step or 1))
  app.handleIntents({ rediscover = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  app.handleIntents({ start = 'mine' })
  T.eq(next(app.pins.quali), nil, 'aucune retouche gardée')
  T.eq(app.start.quali.mode, 'mine')
  T.eq(app.perf.errors, 0)
end

-- « On désactive l'aileron arrière mais on garde le reste » : un réglage refusé seul garde son ancienne valeur, ceux de
-- sa famille gardés prennent la nouvelle ; seul le réglage refusé est gardé pour les calculs suivants.
tests['NV13 un seul réglage refusé : ancienne valeur pour lui, nouvelle pour sa famille'] = function()
  local h, app = ready()
  local folder = folderOf(h)
  app.handleIntents({ start = 'mine' })
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end), 'v1')
  local e = r.history[#r.history]
  local group, refused, kept
  for _, g in ipairs(e.groups) do
    local changes = {}
    for _, item in ipairs(g.items) do
      if item.change then changes[#changes + 1] = item end
    end
    if #changes >= 2 and group == nil then group, refused, kept = g, changes[1], changes[2] end
  end
  T.ok(group, 'une famille avec deux réglages changés')
  app.handleIntents({ effect = { version = e.version, key = refused.key, keep = false } })
  T.eq(group.keep, false, 'famille partiellement gardée')
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.eq(e.status, 'validée', tostring(app.ui.message))
  local values = app.setupValues(h.written[folder .. '/' .. e.file])
  for _, m in ipairs(refused.change.var.members) do
    T.eq(values[m.name], m.current, 'refusé : ancienne valeur ' .. m.name)
    T.ok(app.pins.quali[m.name] and app.pins.quali[m.name].refused, 'refusé gardé pour la suite : ' .. m.name)
  end
  for _, m in ipairs(kept.change.var.members) do
    T.ok(values[m.name] ~= m.current, 'gardé : nouvelle valeur ' .. m.name)
    T.eq(app.pins.quali[m.name], nil, 'gardé : pas figé ' .. m.name)
  end
  T.eq(app.perf.errors, 0)
end

-- Onglet COURSE avant toute qualification validée : verrouillé, avec le chemin vers QUALIF.
tests['NV14 onglet COURSE verrouillé avant une qualification validée'] = function()
  local h, app = ready({ skin = true })
  h.tab = 'Course'
  frames(h, 1)
  T.ok(shownText(h, 'au moins une v1'), 'verrou dit')
  T.no(shownText(h, 'Calculer le setup course'), 'pas de calcul de course')
  h.tab, h.click = nil, 'goto_quali'
  frames(h, 1)
  T.eq(app.ui.tab, 'Tour rapide', 'vers l\'onglet QUALIF')
  T.eq(app.perf.errors, 0)
end

return tests
