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
  -- 1.5.3 : « Essayer » a peut-être déjà chargé l'essai (chargement en cours, ou fait)
  T.ok(app.loadCheck or (app.loadTest and app.loadTest.ok), 'chargement demandé en un clic : ' .. tostring(app.ui.message))
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
  -- 1.5.3 : validée, v1 va dans la voiture ; ici menu de setup fermé : refusé, une autre base reste dans la voiture
  h.setupEditable = false
  h.click = 'Valider v1'
  frames(h, 1)
  T.ok(app.memory['qualif|sec'], 'référence de qualification')
  T.eq(#h.loadCalls, 0, 'menu fermé : rien chargé')
  h.setupEditable = true
  h.click = 'Arrêter l\'affinage (tour rapide)'
  frames(h, 1)
  T.ok(waitFor(h, function() return app.quali == nil or app.quali.state ~= 'running' end))
  app.handleIntents({ raceStart = true })
  T.eq(app.race, nil)
  T.contains(app.ui.message, 'charger d\'abord le setup de qualification validé')
  -- chargée au stand : il manque le nombre de tours
  app.handleIntents({ raceRefLoad = true })
  -- 1.5.3 : « Essayer » a peut-être déjà chargé l'essai (chargement en cours, ou fait)
  T.ok(app.loadCheck or (app.loadTest and app.loadTest.ok), 'chargement demandé en un clic : ' .. tostring(app.ui.message))
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
  -- pages Racing 26 (maquette de Vincent) : libellés en capitales, départs en cartes de choix
  T.ok(shownText(h, 'ÉTAPE 1 / 4') and shownText(h, 'D\'OÙ PART-ON ?'), 'étape 1 : départ à choisir')
  T.ok(shownText(h, 'MON SETUP ACTUEL') and shownText(h, 'SETUP PAR DÉFAUT'), 'deux départs proposés')
  h.click = 'start_mine'
  frames(h, 1)
  T.eq(app.auto, true, 'le choix active SetupLab')
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end), 'v1')
  frames(h, 1)
  T.ok(shownText(h, 'ÉTAPE 3 / 4') and shownText(h, 'ESSAYER V1'), 'étape 3')
  T.ok(shownText(h, 'RÉGLAGES PROPOSÉS'), 'réglages proposés listés')
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
  -- pages Racing 26 : sans qualification validée, la carte « Validez d'abord une qualif » (planche « sans qualif »)
  T.ok(shownText(h, 'VALIDEZ D\'ABORD UNE QUALIF'), 'condition : une qualification validée')
  T.ok(shownText(h, 'au moins une v1'), 'course verrouillée avant une qualification validée')
  -- qualification validée : carte de départ, nombre de tours au curseur (entre « − » et « + »)
  Fake.raceReady(h, app, 10)
  frames(h, 1)
  T.ok(shownText(h, 'DE QUELLE QUALIF PART-ON ?'), 'carte de départ de la course')
  h.sliders = { race_laps = 22 }
  frames(h, 1)
  T.eq(app.raceLaps, 22, tostring(app.ui.message))
  h.click = 'race_laps_plus'
  frames(h, 1)
  T.eq(app.raceLaps, 23, 'un tour de plus')
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
  T.ok(shownText(h, 'STEP 1 / 4') and shownText(h, 'WHERE DO WE START?'), 'interface en anglais')
  T.no(shownText(h, 'ÉTAPE 1'), 'plus de français')
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

-- Thème de l'app (Racing 26 depuis la 1.5.3 ; demande de Vincent du 26/10/2026 : une interface dessinée, pas les
-- contrôles ImGui) : en-tête, onglets dessinés (un clic change d'onglet, seul l'onglet choisi est dessiné), interrupteur
-- « SetupLab actif », sans contrôle ImGui pour les boutons, cases et onglets.
tests['NV10 thème de l\'app : onglets dessinés, interrupteur, boutons du thème'] = function()
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
  T.ok(shownText(h, 'SETUP') and shownText(h, 'LAB'), 'en-tête')
  T.ok(shownText(h, 'QUALIF') and shownText(h, 'AIDE'), 'onglets dessinés')
  T.eq(app.ui.tab, 'Tour rapide', 'onglet par défaut')
  T.ok(shownText(h, 'D\'OÙ PART-ON ?'), 'contenu de l\'onglet QUALIF')
  T.no(shownText(h, 'Mesure et calibration'), 'les autres onglets ne sont pas dessinés')
  h.click = 'tab_Mesure'
  frames(h, 1)
  T.eq(app.ui.tab, 'Mesure', 'un clic change d\'onglet')
  frames(h, 1)
  T.ok(shownText(h, 'Mesure et calibration'), 'contenu de l\'onglet MESURE')
  T.no(shownText(h, 'D\'OÙ PART-ON ?'), 'QUALIF masqué')
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
  T.ok(shownText(h, 'SETUP') and shownText(h, 'LAB'), 'en-tête du thème')
  h.tab = 'Capacités'
  frames(h, 1)
  T.ok(shownText(h, 'Thème de l\'interface : actif'), 'thème actif')
  -- la carte d'étape se montre dans l'onglet de son genre seulement (02/11/2026)
  h.tab = 'Tour rapide'
  frames(h, 1)
  h.tab = nil
  app.handleIntents({ setting = { key = 'language', value = 'en' } })
  frames(h, 1)
  T.ok(shownText(h, 'STEP 1 / 4'), 'texte traduit')
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
  T.eq(app.saved.quali.name, 'SetupLab_Defaut.ini', 'setup à charger')
  -- 1.5.3 (décision de Vincent du 02/11/2026) : le départ choisi va dans la voiture en un clic
  T.ok(app.loadCheck and app.loadCheck.path == folder .. '/SetupLab_Defaut.ini', 'chargé en un clic : ' .. tostring(app.ui.message))
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'chargement constaté')
  T.ok(app.loadTest and app.loadTest.ok, tostring(app.loadTest and app.loadTest.reason))
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

-- Départ de la référence du circuit : proposée après une validation (nouvelle séance), chargée au stand, puis affinée ;
-- figée : « Déverrouiller et reprendre ». Setup par défaut choisi deux fois : un seul fichier.
tests['NV15 départ de la référence (figée ou non) ; setup par défaut réutilisé'] = function()
  local h, app = ready({ skin = true })
  local folder = folderOf(h)
  app.handleIntents({ start = 'mine' })
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end), 'v1')
  app.handleIntents({ refineJudge = { version = r.version, verdict = 'valider' } })
  local e = r.history[#r.history]
  T.eq(e.status, 'validée', tostring(app.ui.message))
  -- 1.5.3 : validée, elle va dans la voiture ; la découverte relancée sur elle se termine d'abord
  T.ok(waitFor(h, function()
    return app.loadCheck == nil and app.discoveryState == 'done' and not (app.refine and app.refine.needsDiscovery)
  end))
  -- changer de départ : la référence est proposée
  h.click = 'start_change'
  frames(h, 1)
  frames(h, 1)
  T.eq(app.start.quali, nil, 'départ à choisir')
  T.ok(shownText(h, 'REPRENDRE MA RÉFÉRENCE') and shownText(h, e.file), 'référence proposée')
  h.click = 'start_reference'
  frames(h, 1)
  T.eq(app.start.quali and app.start.quali.mode, 'reference', tostring(app.ui.message))
  T.eq(app.saved.quali.name, e.file, 'référence à charger')
  if not app.start.quali.ready then
    loadAtPit(h, app)
    T.eq(app.start.quali.ready, true, 'référence dans la voiture')
  end
  -- 1.5.3 : la référence s'est chargée en un clic ; la découverte relancée sur elle se termine d'abord
  T.ok(waitFor(h, function()
    return app.loadCheck == nil and app.discoveryState == 'done' and not (app.refine and app.refine.needsDiscovery)
  end))
  -- figée : déverrouiller et reprendre
  app.handleIntents({ memoryLock = { key = 'qualif|sec', locked = true } })
  T.ok(app.memory['qualif|sec'].locked, 'figée')
  app.handleIntents({ startReset = 'quali' })
  frames(h, 1)
  frames(h, 1)
  T.ok(shownText(h, 'figée (cadenas)'), 'figée dite')
  h.click = 'start_reference'
  frames(h, 1)
  T.no(app.memory['qualif|sec'].locked, 'déverrouillée')
  T.eq(app.start.quali.mode, 'reference')
  frames(h, 120)
  T.ok(app.refine and app.refine.active, 'affinage repris')
  -- setup par défaut deux fois : le même fichier (découverte terminée ; 1.5.3 : le départ se charge en un clic, puis
  -- la découverte est relancée sur lui)
  local function settled()
    return app.loadCheck == nil and app.discoveryState == 'done' and not (app.refine and app.refine.needsDiscovery)
  end
  T.ok(waitFor(h, settled))
  app.handleIntents({ start = 'default' })
  local first = app.start.quali.file
  T.eq(first, 'SetupLab_Defaut.ini', tostring(app.ui.message))
  app.handleIntents({ startReset = 'quali' })
  T.ok(waitFor(h, settled))
  app.handleIntents({ start = 'default' })
  T.eq(app.start.quali and app.start.quali.file, first, 'réutilisé : ' .. tostring(app.ui.message))
  T.no(h.written[folder .. '/SetupLab_Defaut-2.ini'], 'pas de second fichier')
  T.eq(app.perf.errors, 0)
end

-- Premier setup tout de suite (demande de Vincent du 29/10/2026) : case cochée, v1 calculée d'après la voiture et la
-- piste sans attendre de tour ; décochée, la proposition attend le nombre de tours choisi. Réglages en tête de l'onglet.
tests['NV16 premier setup tout de suite, ou après les tours choisis (0 à 10)'] = function()
  local h, app = ready({ skin = true })
  h.tab = 'Réglages'
  frames(h, 1)
  h.tab = nil
  T.ok(shownText(h, 'Premier setup tout de suite'), 'case en tête de l\'onglet RÉGLAGES')
  -- la carte d'étape se montre dans l'onglet de son genre seulement (02/11/2026)
  h.tab = 'Tour rapide'
  frames(h, 1)
  h.tab = nil
  T.eq(app.settings.refineInstantFirst, false, 'décochée par défaut')
  app.handleIntents({ setting = { key = 'refineMinLaps', value = 2 } })
  app.handleIntents({ start = 'mine' })
  local r = app.refine
  frames(h, 600)
  T.eq(r.version, r.base, 'décochée : rien avant les 2 tours')
  T.contains(r.waiting, '0/2')
  frames(h, 1)
  T.ok(shownText(h, 'Quand SetupLab propose un setup »'), 'où le régler, dit dans la carte d\'étape')
  -- cochée : premier setup tout de suite
  app.handleIntents({ setting = { key = 'refineInstantFirst', value = true } })
  app.handleIntents({ startReset = 'quali' })
  app.handleIntents({ start = 'mine' })
  r = app.refine
  T.ok(waitFor(h, function() return r.version > r.base and r.phase == 'tours' end), 'cochée : v1 sans attendre de tour')
  T.eq(app.refineMinReached(r), false, 'la suivante attend les 2 tours')
  T.eq(app.perf.errors, 0)
end

-- Relecture du 29/10/2026 : en séance de course sans qualification validée, « Affiner le tour rapide » (carte d'étape)
-- lance l'affinage du tour rapide, que SetupLab actif ne remplace plus ; une v1 validée débloque la course.
tests['NV17 séance de course sans qualification : affiner le tour rapide, puis la course se débloque'] = function()
  local h, app = ready({ session = 3, skin = true })
  frames(h, 1)
  T.ok(shownText(h, 'COURSE · AVANT LE CALCUL'), 'course : la garde d\'abord, pas de départ à choisir')
  h.click = 'step_quali'
  frames(h, 1)
  T.eq(app.ui.tab, 'Tour rapide', 'vers l\'onglet QUALIF')
  frames(h, 120)
  T.ok(app.refine and app.refine.kind == 'quali' and app.refine.active, 'tour rapide affiné, pas remplacé par la course')
  app.handleIntents({ start = 'mine' })
  local r = app.refine
  T.eq(r.kind, 'quali', 'départ choisi : toujours le tour rapide')
  T.ok(waitFor(h, function() return r.version > r.base and r.phase == 'tours' end), 'v1')
  app.handleIntents({ refineJudge = { version = r.version, verdict = 'valider' } })
  local _, action = app.raceBlocker()
  T.ok(action ~= 'qualif', 'course débloquée : ' .. tostring(action))
  T.eq(app.perf.errors, 0)
end

-- Affinage de la course lancé à la main en séance d'essai, puis retour au tour rapide : chacun reprend ses versions.
tests['NV18 affinage course lancé à la main ; tour rapide repris avec ses versions'] = function()
  local h, app = ready()
  app.handleIntents({ start = 'mine' })
  local q = app.refine
  T.ok(waitFor(h, function() return q.version > q.base and q.phase == 'tours' end), 'v1 tour rapide')
  local count = #q.history
  app.handleIntents({ refineStart = 'race' })
  frames(h, 120)
  T.ok(app.refine.kind == 'race' and app.refine.active, 'course gardée (pas remplacée par le tour rapide)')
  app.handleIntents({ refineStart = 'quali' })
  frames(h, 2)
  T.eq(app.refine, q, 'tour rapide repris')
  T.eq(#q.history, count, 'versions gardées')
  T.eq(app.perf.errors, 0)
end

-- Veille puis actif : l'essai en cours reste ; changer de départ : son fichier part à la Corbeille.
tests['NV19 essai gardé en veille ; nouveau départ : fichier d\'essai à la Corbeille'] = function()
  local h, app = ready()
  local folder = folderOf(h)
  app.handleIntents({ start = 'mine' })
  local r = app.refine
  T.ok(waitFor(h, function() return r.version > r.base and r.phase == 'tours' end), 'v1')
  local e = r.history[#r.history]
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'essayer' } })
  T.eq(e.status, 'essai', tostring(app.ui.message))
  local trial = e.trial.file
  app.handleIntents({ autoToggle = true })
  frames(h, 2)
  app.handleIntents({ autoToggle = true })
  frames(h, 2)
  T.eq(app.refine, r, 'même affinage repris')
  T.eq(e.status, 'essai', 'essai toujours en cours')
  app.handleIntents({ startReset = 'quali' })
  app.handleIntents({ start = 'mine' })
  local queued = h.written[folder .. '/' .. trial] == nil
  for _, op in ipairs(app.fileOps or {}) do queued = queued or op.name == trial end
  T.ok(queued, 'fichier d\'essai abandonné : à la Corbeille')
  T.ok(app.refine ~= r, 'nouvel affinage')
  T.eq(app.perf.errors, 0)
end

-- Figer : la carte d'étape le dit et propose « Déverrouiller » ; figer sans réglage gardé est refusé ; version non
-- gardée encore dans la voiture, sans référence : la carte dit quoi faire.
tests['NV20 setup figé dans la carte ; figer à 0 refusé ; version non gardée dans la voiture'] = function()
  local h, app = ready({ skin = true })
  app.handleIntents({ start = 'mine' })
  local r = app.refine
  T.ok(waitFor(h, function() return r.version > r.base and r.phase == 'tours' end), 'v1')
  local e = r.history[#r.history]
  app.handleIntents({ effect = { version = e.version, key = '*', keep = false } })
  app.handleIntents({ refineLock = e.version })
  T.eq(e.status, nil, 'figer sans réglage gardé : refusé')
  T.contains(app.ui.message, 'aucun réglage gardé')
  app.handleIntents({ effect = { version = e.version, key = '*', keep = true } })
  app.handleIntents({ refineLock = e.version })
  T.eq(e.status, 'validée', tostring(app.ui.message))
  frames(h, 2)
  T.ok(shownText(h, 'SETUP FIGÉ'), 'carte : setup figé')
  h.click = 'step_unlock'
  frames(h, 1)
  T.no(app.memory[app.memoryGroupOf('quali') .. '|sec'].locked, 'déverrouillé depuis la carte')
  T.ok(waitFor(h, function() return app.refine.active end, 600), 'affinage repris')
  T.eq(app.perf.errors, 0)
end

-- Demande de Vincent du 02/11/2026 : setups de qualification faits lors d'une séance précédente (v1, v2, v3, essais
-- compris), AC relancé : la course part de celui qui est dans la voiture, reconnu par ses valeurs (même réenregistré
-- depuis le menu d'AC) ; sinon l'onglet COURSE les liste et dit de charger l'un d'eux depuis le menu d'AC.
tests['NV21 course : setups de qualification d\'une séance précédente reconnus par leurs valeurs'] = function()
  local h, app = ready({ session = 3, skin = true })
  local folder = folderOf(h)
  local d = app.discovery
  local text = d.setup.text
  -- v1 : un autre setup ; v3 d'essai : le setup de la voiture, réenregistré par AC (texte différent, mêmes valeurs)
  local other = text:gsub('(%[ARB_FRONT%]%s*VALUE=)(%-?%d+)', function(a, v) return a .. tostring(tonumber(v) + 1) end, 1)
  h.written[folder .. '/SetupLab_Qualif_v1.ini'] = other
  T.eq(app.raceBlocker(), 'valider d\'abord un setup de tour rapide (qualification) sur ce circuit', 'cache : rien encore')
  app.qualiScan = nil
  local why, action = app.raceBlocker()
  T.eq(action, 'loadfile', tostring(why))
  h.tab = 'Course'
  frames(h, 1)
  T.ok(shownText(h, 'SetupLab_Qualif_v1.ini'), 'setups listés dans l\'onglet COURSE')
  T.ok(shownText(h, 'menu de setup d\'AC'), 'dit de charger depuis le menu d\'AC')
  h.tab = nil
  h.written[folder .. '/SetupLab_Qualif_v3_essai.ini'] = text .. '\n; réenregistré par AC\n'
  app.qualiScan = nil
  why, action = app.raceBlocker()
  T.ok(action ~= 'qualif' and action ~= 'loadfile' and action ~= 'load', 'setup de la voiture reconnu : ' .. tostring(why))
  T.eq(app.qualiInCar().file, 'SetupLab_Qualif_v3_essai.ini')
  -- voiture en mouvement : pas de relecture du dossier, la liste d'avant reste servie
  local before = #app.qualiFiles()
  app.qualiScan.generation = 'forcée'
  h.car.speedMs = 30
  T.eq(#app.qualiFiles(), before, 'liste précédente en roulant')
  T.eq(app.qualiScan.generation, 'forcée', 'pas de relecture en roulant')
  h.car.speedMs = 0
  T.eq(#app.qualiFiles(), before)
  T.ok(app.qualiScan.generation ~= 'forcée', 'relue voiture arrêtée')
  -- calcul de course sans qualification validée en mémoire : il part du setup reconnu dans la voiture
  app.settings.optBudgetEvalsC = 30
  app.handleIntents({ raceLaps = 12 })
  T.eq(app.raceBlocker(), nil, 'garde de course levée')
  app.handleIntents({ raceStart = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  T.eq(app.raceBlocker(), nil, 'garde levée après la découverte')
  app.handleIntents({ raceStart = true })
  T.ok(waitFor(h, function() return app.race and app.race.state ~= 'running' end), 'calcul course')
  T.eq(app.race.state, 'done', tostring(app.race and app.race.error) .. ' ; ' .. tostring(app.ui.message))
  T.eq(app.perf.errors, 0)
end

-- Demande de Vincent du 02/11/2026 : en séance de course, un ancien setup de qualification de SetupLab (v4, séance
-- précédente) chargé depuis le menu d'AC après la découverte est reconnu sans nouvelle découverte, et la v1 de course
-- se calcule tout de suite, sans tour de plus (réglages par défaut : 2 tours, premier setup immédiat décoché).
tests['NV22 séance de course : v4 chargé depuis le menu d\'AC, v1 de course sans tour de plus'] = function()
  local h, app = ready({ session = 3 })
  app.settings.refineMinLaps, app.settings.refineInstantFirst = 2, false
  local folder = folderOf(h)
  local d = app.discovery
  local v4 = d.setup.text:gsub('(%[ARB_FRONT%]%s*VALUE=)(%-?%d+)', function(a, v) return a .. tostring(tonumber(v) + 1) end, 1)
  T.ok(v4 ~= d.setup.text, 'v4 différent du setup de la voiture')
  h.written[folder .. '/SetupLab_Qualif_v4.ini'] = v4
  app.qualiScan = nil
  app.handleIntents({ raceLaps = 12 })
  app.handleIntents({ refineStart = 'race' })
  frames(h, 30)
  local r = app.refine
  T.ok(r and r.kind == 'race' and r.active, 'affinage course')
  local _, action = app.raceBlocker()
  T.eq(action, 'loadfile', 'v4 pas encore dans la voiture')
  T.ok(app.race == nil or app.race.state == nil, 'rien calculé avant le chargement')
  -- chargé depuis le menu d'AC, après la découverte (le menu pose les valeurs du fichier : ici, une barre avant + 1)
  local arb = spinner(h, 'ARB_FRONT')
  arb.value = arb.value + 1
  T.ok(waitFor(h, function() return app.qualiInCar() ~= nil end, 120), 'reconnu sans nouvelle découverte')
  T.eq(app.qualiInCar().file, 'SetupLab_Qualif_v4.ini')
  -- course calculée tout de suite, sans tour
  T.ok(waitFor(h, function() return app.race ~= nil and app.race.state == 'done' and r.phase == 'tours' end),
    'calcul de course : ' .. tostring(r.waiting) .. ' ; ' .. tostring(app.ui.message))
  T.eq(r.minLaps or 0, 0, 'aucun tour roulé')
  -- la suivante attend le minimum (tours avec la version de course)
  local first = false
  for _, e in ipairs(r.history) do first = first or e.version ~= nil end
  if first then T.ok(not app.refineMinReached(r), 'version suivante : minimum de tours') end
  T.eq(app.perf.errors, 0)
end

-- Constat de Vincent du 02/11/2026 : onglet QUALIF, « reprendre » sa v2 validée (affinage du tour rapide actif, qui attend
-- ses tours pour une v3), puis onglet COURSE, 25 tours, calcul de course : la course doit partir de la v2 dans la
-- voiture, sans attendre une v3 (réglages par défaut : 2 tours, premier setup immédiat décoché).
local function nv23(button)
  local h, app = ready({ session = 1, skin = true })
  app.settings.refineMinLaps, app.settings.refineInstantFirst = 2, false
  -- v2 validée en séance d'essai (mémoire « essai » de ce circuit), fichier de SetupLab = setup de la voiture
  local Store, Util = require('src/store'), require('src/util')
  local folder = folderOf(h)
  local d = app.discovery
  local text = h.ac.stringifyCurrentSetup(true, false)
  h.written[folder .. '/SetupLab_Qualif_v2.ini'] = text
  local track, layout = d.trackFiles.fullId:match('^([^/]+)/([^/]+)$')
  if track == nil then track, layout = d.trackFiles.fullId, '-' end
  Store.put(app.store, Store.entryKey('mem', d.car.id, track, layout, 'essai', 'sec'),
    { file = 'SetupLab_Qualif_v2.ini', hash = Util.hashString(text), version = 2, gain = 0, time = 0, locked = false })
  app.memoryFiles = {}
  app.refreshMemory()
  app.qualiScan = nil
  frames(h, 2)
  -- onglet QUALIF : reprendre la référence validée (déjà dans la voiture)
  app.handleIntents({ start = 'reference' })
  frames(h, 30)
  local q = app.refine
  T.ok(q and q.kind == 'quali' and q.active, 'affinage du tour rapide : ' .. tostring(app.ui.message))
  PY.note('NV23 qualif', tostring(q.waiting))
  -- onglet COURSE : 25 tours, puis le bouton
  h.tab = 'Course'
  app.handleIntents({ raceLaps = 25 })
  frames(h, 2)
  local why, action = app.raceBlocker()
  T.eq(why, nil, 'garde de course levée : ' .. tostring(action))
  h.click = button
  frames(h, 1)
  PY.note('NV23 clic', tostring(app.ui.message))
  -- la course devient l'affinage en cours, et dit de quel setup elle part
  local r = app.refine
  T.ok(r and r.kind == 'race' and r.active, 'la course est l\'affinage en cours : ' .. tostring(r and r.kind))
  T.ok(app.refines.quali == q and not q.active, 'tour rapide mis de côté, avec ses versions')
  T.ok(waitFor(h, function() return r.phase == 'calcul' end, 600), 'calcul de course lancé sans tour : ' .. tostring(r.waiting))
  T.contains(r.waiting, 'à partir de SetupLab_Qualif_v2.ini')
  local done = waitFor(h, function() return app.race ~= nil and app.race.state == 'done' end, 60000)
  PY.note('NV23 après', 'race=' .. tostring(app.race and app.race.state) .. ' refine=' .. tostring(r.kind) .. '/'
    .. tostring(r.phase) .. ' attente=' .. tostring(r.waiting))
  T.ok(done, 'calcul de course fait sans v3 : ' .. tostring(r.waiting) .. ' ; ' .. tostring(app.ui.message))
  T.eq(r.minLaps or 0, 0, 'aucun tour roulé')
  -- carte d'étape : la course, pas l'attente d'une v3
  frames(h, 2)
  local v1 = r.history[#r.history]
  T.ok(v1 and v1.version == 1, 'v1 de course proposée, partie de la v2 de qualification')
  T.ok(shownText(h, 'ÉTAPE 3 / 4 · COURSE') and shownText(h, 'ESSAYER V1'), 'carte d\'étape : la v1 de course à essayer')
  -- le tour rapide se reprend avec ses versions
  app.handleIntents({ refineStart = 'quali' })
  frames(h, 2)
  T.eq(app.refine, q, 'tour rapide repris')
  T.eq(app.perf.errors, 0)
  return h, app
end

tests['NV23a qualif v2 reprise, onglet COURSE : « Calculer le setup course » part de la v2'] = function()
  nv23('Calculer le setup course')
end

tests['NV23b qualif v2 reprise, onglet COURSE : « Affinage automatique (course) » part de la v2'] = function()
  nv23('Affinage automatique (course)')
end

-- Constat de Vincent du 02/11/2026 (Monza, séance de qualification, premier setup immédiat coché, 0 tour minimum) :
-- « reprendre » la v2 lance tout de suite le calcul d'une v3 du tour rapide ; le calcul de course demandé ensuite
-- attendait derrière lui. Le calcul du tour rapide est interrompu, la course passe tout de suite ; le tour rapide le
-- refait à sa reprise.
tests['NV23c premier setup immédiat : la v3 du tour rapide en calcul est interrompue, la course passe tout de suite'] = function()
  local h, app = ready({ session = 2, skin = true })
  app.settings.refineMinLaps, app.settings.refineInstantFirst, app.settings.optBudgetEvalsQ = 0, true, 1200
  Fake.raceReady(h, app, 25)
  app.raceLaps = nil
  frames(h, 2)
  app.handleIntents({ start = 'reference' })
  local q = app.refine
  T.ok(waitFor(h, function() return q.phase == 'calcul' and app.quali ~= nil and app.quali.state == 'running' end, 600),
    'v3 du tour rapide en calcul')
  h.tab = 'Course'
  app.handleIntents({ raceLaps = 25 })
  frames(h, 1)
  h.click = 'Calculer le setup course'
  frames(h, 2)
  T.ok(app.quali.state ~= 'running', 'calcul du tour rapide interrompu : ' .. tostring(app.quali.state))
  local r = app.refine
  T.eq(r.kind, 'race', 'la course est l\'affinage en cours')
  local n = waitFor(h, function() return app.race ~= nil and app.race.state == 'done' end, 60000)
  T.ok(n ~= nil and n < 700, 'course calculée sans attendre la v3 : ' .. tostring(n) .. ' images')
  -- tour rapide repris : il refait son calcul
  app.handleIntents({ refineStart = 'quali' })
  T.eq(app.refine, q, 'tour rapide repris')
  T.ok(waitFor(h, function() return app.quali.state == 'running' or app.quali.state == 'done' end, 600),
    'calcul du tour rapide repris : ' .. tostring(app.quali.state))
  T.eq(app.perf.errors, 0)
end

return tests
