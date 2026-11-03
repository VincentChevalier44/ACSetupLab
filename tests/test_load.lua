-- Chargement d'un setup SetupLab dans la voiture (D8 amendé le 20/10/2026, décision de Vincent) :
-- fichier qualification ou course écrit pendant la séance seulement, au stand, voiture arrêtée, menu
-- de setup ouvert, en deux clics, après une copie de sauvegarde du setup en cours ; le setup chargé
-- est constaté par sa signature en direct.
local T = require('t')
local Util = require('src/util')
local Config = require('src/config')
local Fake = require('fakehost')

local tests = {}

local function load(h)
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  -- horloge simulée : 1/60 s par image et 20 µs par lecture (délais de confirmation reproductibles)
  h.clockNow = 0
  app.clock = function()
    h.clockNow = h.clockNow + 2e-5
    return h.clockNow
  end
  h.texts = {}
  local text, wrapped, colored = h.ui.text, h.ui.textWrapped, h.ui.textColored
  h.ui.text = function(s) h.texts[#h.texts + 1] = s; return text(s) end
  h.ui.textWrapped = function(s) h.texts[#h.texts + 1] = s; return wrapped(s) end
  h.ui.textColored = function(s, c) h.texts[#h.texts + 1] = s; return colored(s, c) end
  return app
end

local function frame(h)
  h.texts = {}
  h.clockNow = (h.clockNow or 0) + 1 / 60
  h.sim.time = h.sim.time + 1000 / 60
  script.SETUPLAB__UPDATE(1 / 60)
  script.SETUPLAB__MAIN(1 / 60)
end

local function untilDone(h, app, predicate)
  for _ = 1, 200000 do
    frame(h)
    if predicate(app) then return true end
  end
  return false
end

local function shown(h, fragment)
  for _, text in ipairs(h.texts) do
    if text:find(fragment, 1, true) then return text end
  end
  return nil
end

local function backups(h)
  local n = 0
  for path in pairs(h.written) do
    if path:find(Config.exportBackupPrefix, 1, true) then n = n + 1 end
  end
  return n
end

-- Hôte au stand (voiture arrêtée, setup modifiable) ; setup qualification calculé puis enregistré.
local function ready(opts)
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza'),
    loadNoApply = opts and opts.loadNoApply })
  local app = load(h)
  T.ok(untilDone(h, app, function(a) return a.discoveryState == 'done' end))
  app.settings.optBudgetEvalsQ = 100
  h.click = 'Calculer le setup tour rapide'
  T.ok(untilDone(h, app, function(a) return a.quali and a.quali.state ~= 'running' end))
  T.eq(app.quali.state, 'done', tostring(app.quali.error))
  T.ok(#app.quali.result.changes > 0, 'setup proposé différent du setup actuel')
  h.click = 'Enregistrer le setup tour rapide'
  frame(h)
  T.ok(app.quali.saved and app.quali.saved.ok, 'setup enregistré')
  return h, app
end

-- Un clic sur « Charger » : le chargement part tout de suite (1.5.3, décision de Vincent du 02/11/2026 : plus de
-- confirmation en deux clics).
local function clickLoad(h)
  h.click = 'Charger le setup tour rapide dans la voiture'
  frame(h)
end

tests['J01 chargement nominal : un clic, copie de sauvegarde, setup constaté ; double clic sans effet'] = function()
  local h, app = ready()
  local proposedText = h.written[app.quali.saved.path]
  -- modification non enregistrée dans le menu de setup : elle doit figurer dans la copie de sauvegarde
  local touched = h.spinners[1]
  touched.value = touched.value + (touched.step or 1)
  local original = h.ac.stringifyCurrentSetup(true, false)
  -- l'avertissement est dans l'infobulle du bouton
  h.hover = true
  frame(h)
  T.ok(shown(h, 'remplace le setup en cours dans la voiture'), 'avertissement au survol du bouton')
  h.hover = nil
  clickLoad(h)
  T.eq(#h.loadCalls, 1, 'chargé au premier clic')
  T.eq(h.loadCalls[1], app.quali.saved.path, 'fichier enregistré par SetupLab')
  T.eq(backups(h), 1, 'copie de sauvegarde écrite avant le chargement')
  for path, text in pairs(h.written) do
    if path:find(Config.exportBackupPrefix, 1, true) then
      T.eq(text, original, 'copie identique au setup précédent, modification non enregistrée comprise')
    end
  end
  T.ok(untilDone(h, app, function(a) return a.loadCheck == nil end))
  T.ok(app.loadTest and app.loadTest.ok, tostring(app.loadTest and app.loadTest.reason))
  T.contains(app.ui.message, 'chargé et vérifié')
  T.contains(app.ui.message, Config.exportBackupPrefix)
  T.contains(app.ui.message, 'relancera la découverte')
  -- double clic (le constat peut finir en une image) : le même fichier n'est ni rechargé ni recopié
  clickLoad(h)
  T.eq(#h.loadCalls, 1, 'double clic : un seul chargement')
  T.eq(backups(h), 1, 'double clic : une seule copie')
  T.contains(app.ui.message, 'déjà demandé')
  -- aucun fichier modifié : le fichier chargé est intact, toutes les écritures sont de nouveaux fichiers
  T.eq(h.written[app.quali.saved.path], proposedText)
  local files = 0
  for _ in pairs(h.written) do files = files + 1 end
  T.eq(h.writeCalls, files, 'aucune écriture interdite')
  -- capacité confirmée ; setup changé depuis la découverte : calcul refusé jusqu'à la relance
  T.eq(app.discovery.caps.byId.setup_load.status, 'available')
  -- setup changé depuis la découverte : le calcul relance d'abord la découverte (décision du 20/10/2026)
  h.click = 'Calculer le setup tour rapide'
  frame(h)
  T.ok(app.pendingComputes.quali)
  T.eq(app.discoveryState, 'running')
  T.eq(app.perf.errors, 0)
end

tests['J02 gardes : stand, arrêt, menu de setup, setup imposé, voiture, en ligne, replay, désactivée'] = function()
  local h, app = ready()
  local cases = {
    { 'voiture hors du stand', function() h.car.isInPit = false end, function() h.car.isInPit = true end },
    { 'voiture en mouvement', function() h.car.speedMs = 5 end, function() h.car.speedMs = 0 end },
    { 'ouvrir le menu de setup', function() h.setupEditable = false end, function() h.setupEditable = nil end },
    { 'setup imposé', function() h.sim.fixedSetup = true end, function() h.sim.fixedSetup = false end },
  }
  for _, case in ipairs(cases) do
    -- refus au clic : rien n'est chargé, la raison est dite
    case[2]()
    clickLoad(h)
    T.eq(#h.loadCalls, 0, case[1] .. ' : rien chargé')
    T.contains(app.ui.message, case[1])
    case[3]()
  end
  -- autre voiture que celle du calcul
  local carId = h.carId
  h.carId = 'autre_voiture'
  app.handleIntents({ load = 'quali' })
  T.eq(#h.loadCalls, 0, 'autre voiture : rien chargé')
  h.carId = carId
  -- replay déclenché dans l'image même du clic (contexte relu à 1 Hz seulement)
  for _ = 1, 40 do frame(h) end
  app.nextContextAt = app.now + 30
  h.sim.isReplayActive = true
  app.handleIntents({ load = 'quali' })
  T.eq(#h.loadCalls, 0, 'aucun chargement en replay')
  h.sim.isReplayActive = false
  app.nextContextAt = 0
  frame(h)
  -- application désactivée ; setup imposé illisible
  app.settings.enabled = false
  app.handleIntents({ load = 'quali' })
  T.contains(app.ui.message, 'application désactivée')
  app.settings.enabled = true
  h.sim.fixedSetup = nil
  clickLoad(h)
  T.contains(app.ui.message, 'illisible')
  h.sim.fixedSetup = false
  -- en ligne : inerte, intentions refusées
  app.settings.onlineActive = false -- « Actif en ligne » décoché : pause en ligne
  h.sim.isOnlineRace = true
  T.ok(untilDone(h, app, function(a) return a.inert ~= nil end))
  app.handleIntents({ load = 'quali' })
  T.contains(app.ui.message, 'Indisponible')
  h.sim.isOnlineRace = false
  T.eq(#h.loadCalls, 0, 'aucun chargement')
  T.eq(backups(h), 0, 'aucune copie de sauvegarde')
  T.eq(app.perf.errors, 0)
end

tests['J03 fichier modifié, absent ou étranger ; copie de sauvegarde impossible : aucun chargement'] = function()
  local h, app = ready()
  local path = app.quali.saved.path
  local text = h.written[path]
  -- modifié depuis son écriture : refus au clic, aucune copie écrite
  h.written[path] = text .. '\n; modifié'
  clickLoad(h)
  T.contains(app.ui.message, 'modifié depuis son écriture')
  T.eq(app.loadTest, nil, 'refus avant l\'appel : pas une issue de ac.loadSetup')
  -- absent
  h.written[path] = nil
  clickLoad(h)
  T.contains(app.ui.message, 'introuvable')
  h.written[path] = text
  T.eq(backups(h), 0, 'aucune copie pour un fichier refusé')
  -- copie de sauvegarde impossible : pas de chargement
  h.opts.saveFails = true
  clickLoad(h)
  h.opts.saveFails = nil
  T.contains(app.ui.message, 'copie de sauvegarde du setup en cours impossible')
  T.eq(app.writeTest.ok, false, 'échec de la copie consigné (capacité d\'écriture)')
  T.eq(#h.loadCalls, 0, 'aucun chargement sans copie de sauvegarde')
  -- fichiers étrangers, chemins détournés : refus par l'exporteur (seul module autorisé à charger) ; « écrit
  -- par SetupLab » : nom et empreinte du contenu relevés à l'écriture (1.4.0 : noms choisis par Vincent)
  local Exporter = require('src/exporter')
  local host = { ac = h.ac, io = h.io }
  local folder = assert(Exporter.targetFolder(host))
  local name = path:sub(#folder + 2)
  local prefix = Config.exportQualiPrefix
  local written = { [name] = Util.hashString(text) }
  for _, bad in ipairs({ folder .. '/../autre/' .. name, folder .. '/sous/' .. name, folder .. '/autre.ini',
      folder .. '/' .. Config.exportBackupPrefix .. '1.ini', '/ailleurs/' .. name, folder .. '/' .. name .. '.txt',
      folder .. '/' .. prefix .. 'x/../../autre.ini', folder .. '/' .. prefix .. 'x\\..\\..\\autre.ini',
      folder .. '/' .. prefix .. '..ini', folder .. '/' .. prefix .. 'x/autre.ini' }) do
    h.written[bad] = text
    local r = Exporter.loadIntoCar(host, bad, text, written)
    T.no(r.ok, bad)
  end
  -- nom libre écrit par SetupLab : accepté ; même contenu sous un autre nom, ou empreinte différente : refusé
  local named = folder .. '/Mon_setup_Monza.ini'
  h.written[named] = text
  T.contains(Exporter.loadBlocker(host, named, text, written), 'non écrit par SetupLab')
  T.contains(Exporter.loadBlocker(host, named, text, { ['Mon_setup_Monza.ini'] = Util.hashString(text) + 1 }),
    'non écrit par SetupLab')
  T.contains(Exporter.loadBlocker(host, path, text, nil), 'non écrit par SetupLab')
  h.setupEditable = false
  T.contains(Exporter.loadBlocker(host, named, text, { ['Mon_setup_Monza.ini'] = Util.hashString(text) }), 'menu de setup')
  h.setupEditable = nil
  T.eq(#h.loadCalls, 0, 'aucun chargement')
  -- seconde défense de l'exporteur, au moment de l'appel : menu de setup fermé, setup imposé
  h.setupEditable = false
  local r = Exporter.loadIntoCar(host, path, text, written)
  T.no(r.ok)
  T.contains(r.reason, 'menu de setup')
  h.setupEditable = nil
  h.sim.fixedSetup = true
  r = Exporter.loadIntoCar(host, path, text, written)
  h.sim.fixedSetup = false
  T.no(r.ok)
  T.contains(r.reason, 'imposé')
  h.sim.fixedSetup = nil
  r = Exporter.loadIntoCar(host, path, text, written)
  h.sim.fixedSetup = false
  T.no(r.ok)
  T.contains(r.reason, 'illisible')
  T.eq(#h.loadCalls, 0, 'ac.loadSetup jamais appelée hors des conditions')
  T.eq(app.perf.errors, 0)
end

tests['J04 chargement accepté par le jeu mais setup différent : écart signalé'] = function()
  local h, app = ready({ loadNoApply = true })
  clickLoad(h)
  T.eq(#h.loadCalls, 1)
  -- vérification en cours : aucun autre chargement
  T.ok(app.loadCheck)
  clickLoad(h)
  T.eq(#h.loadCalls, 1)
  T.contains(app.ui.message, 'vérification du chargement précédent en cours')
  for _ = 1, Config.K.loadVerifyFrames + 2 do frame(h) end
  T.eq(app.loadCheck, nil)
  T.eq(app.loadTest.ok, false)
  T.contains(app.ui.message, 'Écart')
  T.contains(app.loadTest.reason, 'écart')
  T.eq(app.discovery.caps.byId.setup_load.status, 'pending')
  T.contains(app.discovery.caps.byId.setup_load.detail, 'différent')
  -- seul le carburant n'est pas appliqué : écart constaté sur FUEL (le constat couvre toutes les sections)
  h.opts.loadNoApply, h.opts.loadSkip = nil, 'FUEL'
  for _, sp in ipairs(h.spinners) do
    if sp.name == 'FUEL' then sp.value = sp.value + 1 end
  end
  clickLoad(h)
  for _ = 1, Config.K.loadVerifyFrames + 2 do frame(h) end
  h.opts.loadSkip, h.opts.loadNoApply = nil, true
  T.eq(app.loadTest.ok, false, 'écart sur le carburant')
  T.contains(app.loadTest.reason, 'FUEL')
  -- chargement refusé par le jeu : raison affichée, rien n'est constaté
  h.opts.loadRefuse = true
  clickLoad(h)
  h.opts.loadRefuse = nil
  T.eq(#h.loadCalls, 3)
  T.eq(app.loadCheck, nil)
  T.contains(app.ui.message, 'refusé le chargement')
  T.eq(app.loadTest.ok, false)
end

tests['J05 deux genres enregistrés : chaque bouton charge son genre ; nouvel enregistrement : le nouveau fichier'] = function()
  local h, app = ready()
  app.settings.optBudgetEvalsC = 20
  Fake.raceReady(h, app, 10)
  h.tab, h.click = 'Course', 'Calculer le setup course'
  T.ok(untilDone(h, app, function(a) return a.race and a.race.state ~= 'running' end))
  T.eq(app.race.state, 'done', tostring(app.race.error))
  h.click = 'Enregistrer le setup course'
  frame(h)
  T.ok(app.race.saved and app.race.saved.ok, 'setup course enregistré')
  h.tab = nil
  -- nouvel enregistrement du tour rapide : c'est ce nouveau fichier qui est chargé
  local before = app.saved.quali.path
  h.sim.systemTime = (h.sim.systemTime or 0) + 60
  h.click = 'Enregistrer le setup tour rapide'
  frame(h)
  frame(h)
  T.ok(app.saved.quali.path ~= before, 'nouveau fichier à charger')
  clickLoad(h)
  T.eq(#h.loadCalls, 1)
  T.eq(h.loadCalls[1], app.saved.quali.path, 'tour rapide : son dernier fichier')
  T.ok(untilDone(h, app, function(a) return a.loadCheck == nil end))
  -- bouton de la course : le setup course
  h.tab, h.click = 'Course', 'Charger le setup course dans la voiture'
  frame(h)
  h.tab = nil
  T.eq(#h.loadCalls, 2)
  T.eq(h.loadCalls[2], app.saved.race.path, 'course : son fichier')
  T.ok(untilDone(h, app, function(a) return a.loadCheck == nil end))
  T.eq(app.perf.errors, 0)
end

tests['J06 setup déjà en place : constat non concluant, capacité non promue'] = function()
  local h, app = ready()
  clickLoad(h)
  T.ok(untilDone(h, app, function(a) return a.loadCheck == nil end))
  T.ok(app.loadTest.ok and app.loadVerified, 'premier chargement vérifié')
  -- second chargement du même fichier, plus tard (pas un double clic) : la voiture a déjà ce setup, rien n'est prouvé
  for _ = 1, Config.K.loadRepeatFrames + 1 do frame(h) end
  clickLoad(h)
  T.eq(#h.loadCalls, 2)
  T.ok(untilDone(h, app, function(a) return a.loadCheck == nil end))
  T.eq(app.loadTest.ok, false)
  T.contains(app.loadTest.reason, 'non concluant')
  T.contains(app.ui.message, 'pas constaté')
  local cap = app.discovery.caps.byId.setup_load
  T.eq(cap.status, 'available', 'le chargement vérifié reste acquis')
  T.contains(cap.detail, 'non concluant')
end

tests['J07 filet d\'exécution : ac.loadSetup appelée hors de l\'exporteur -> erreur'] = function()
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  local ok, err = pcall(h.ac.loadSetup, 'x.ini')
  T.no(ok)
  T.contains(tostring(err), 'hors de src/exporter.lua')
  T.eq(#h.loadCalls, 0)
end

-- Stratégie d'arrêt (demande de Vincent du 02/11/2026, option A) : après le chargement vérifié d'un setup de course, le
-- preset d'arrêt sélectionné prend ses pressions et son composé ; un setup de tour rapide ne la touche pas.
tests['J20 setup de course chargé : stratégie d\'arrêt réglée (pressions, composé) ; tour rapide : intacte'] = function()
  local h, app = ready()
  clickLoad(h)
  T.ok(untilDone(h, app, function(a) return a.loadCheck == nil end), 'chargement constaté')
  T.eq(h.pitCalls, 0, 'tour rapide : stratégie d\'arrêt intacte')
  T.eq(app.discovery.caps.byId.pit_strategy.status, 'pending')
  T.contains(app.discovery.caps.byId.pit_strategy.detail, 'non testé')
  -- même fichier présenté comme setup de course
  local saved = app.saved.quali
  app.saved.race = { path = saved.path, name = saved.name, text = saved.text, signature = saved.signature, hash = saved.hash,
    bucket = saved.bucket, carId = saved.carId }
  app.proposals.race = saved.signature
  local values = app.setupValues(saved.text)
  -- retouche dans le menu de setup : le chargement suivant n'est pas « déjà en place »
  local touched = h.spinners[1]
  touched.value = touched.value + (touched.step or 1)
  -- rechargé plus tard comme setup de course (pas un double clic du même fichier)
  for _ = 1, Config.K.loadRepeatFrames + 1 do frame(h) end
  app.handleIntents({ load = 'race' })
  T.ok(app.loadCheck and app.loadCheck.kind == 'race', tostring(app.ui.message))
  T.ok(untilDone(h, app, function(a) return a.loadCheck == nil end), 'chargement constaté')
  T.ok(h.pitCalls >= 4, 'pressions réglées : ' .. h.pitCalls)
  for _, name in ipairs({ 'PRESSURE_LF', 'PRESSURE_RF', 'PRESSURE_LR', 'PRESSURE_RR' }) do
    T.eq(h.pitstop[name], values[name], name)
  end
  if values.TYRES then T.eq(h.pitstop.COMPOUND, values.TYRES, 'composé') end
  T.eq(h.pitstop.FUEL, 0, 'carburant inchangé')
  local note = assert(app.pitStrategy and app.pitStrategy.note, 'note du menu d\'arrêt')
  T.ok(app.pitStrategy.ok, note)
  T.contains(note, 'Stratégie d\'arrêt (preset sélectionné) mise à jour pour ')
  T.contains(note, 'pressions ')
  if values.TYRES then T.contains(note, '(changement de pneus prévu à l\'arrêt)') end
  T.ok(not note:find('COMPOUND', 1, true), 'gomme nommée : ' .. note)
  T.contains(app.ui.message, 'chargé et vérifié dans la voiture')
  local I18n = require('src/i18n')
  local en = I18n.en(note)
  T.ok(not I18n.looksFrench(en), 'anglais : ' .. en)
  T.contains(en, 'Pit strategy (selected preset) updated')
  -- dite dans l'onglet COURSE
  h.tab = 'Course'
  frame(h)
  T.ok(shown(h, 'Stratégie d\'arrêt (preset sélectionné)'), 'note affichée dans l\'onglet COURSE')
  h.tab = nil
  -- rapport J0 : ce qui a été posé et les réglages lus dans le menu d'arrêt
  local cap = app.discovery.caps.byId.pit_strategy
  T.eq(cap.status, 'available', tostring(cap.detail))
  T.contains(cap.detail, 'menu d\'arrêt : FUEL=fuel, COMPOUND=compound, PRESSURE_LF=pressure')
  T.eq(app.perf.errors, 0)
end

return tests
