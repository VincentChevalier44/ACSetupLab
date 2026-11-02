-- Relecture adversariale de la bêta 1.5.2 (02/11/2026) : course à partir d'un setup de qualification, affinage de la
-- course au-delà de sa v1, relecture du dossier des setups, stratégie d'arrêt. Budgets réalistes là où une v1 au
-- petit budget ne changerait que la répartition de freinage (exclue de la famille des setups).
local T = require('t')
local Config = require('src/config')
local Exporter = require('src/exporter')
local Fake = require('fakehost')

local tests = {}

local function boot(opts)
  opts = opts or {}
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza'),
    stored = opts.stored, skin = opts.skin })
  if opts.noPitApi then h.ac.setPitstopSpinnerValue = nil end
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

local function frames(h, n)
  for _ = 1, n do
    h.sim.time = h.sim.time + 1000 / 60
    h.texts = {}
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

local function ready(opts)
  local h, app = boot(opts)
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  app.settings.compoundChoice = app.discovery.compoundIndex
  return h, app
end

local function folderOf(h)
  return assert(Exporter.targetFolder({ ac = h.ac, io = h.io }))
end

local function otherSetup(text)
  return (text:gsub('(%[ARB_FRONT%]%s*VALUE=)(%-?%d+)', function(x, v) return x .. tostring(tonumber(v) + 1) end, 1))
end

-- chargement par SetupLab, deux clics au stand (issue non vérifiée : setup déjà en place, écart)
local function loadTry(h, app, kind)
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  frames(h, 1)
  app.handleIntents({ loadArm = kind })
  -- 1.5.3 : « Essayer » a peut-être déjà chargé l'essai (chargement en cours, ou fait)
  T.ok((app.loadCheck and app.loadCheck.kind == kind) or (app.loadTest and app.loadTest.ok and app.loadTest.kind == kind),
    'chargement demandé : ' .. tostring(app.ui.message))
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'chargement terminé')
end

-- chargement par SetupLab, deux clics au stand
local function loadVia(h, app, kind)
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  frames(h, 1)
  app.handleIntents({ loadArm = kind })
  -- 1.5.3 : « Essayer » a peut-être déjà chargé l'essai (chargement en cours, ou fait)
  T.ok((app.loadCheck and app.loadCheck.kind == kind) or (app.loadTest and app.loadTest.ok and app.loadTest.kind == kind),
    'chargement demandé : ' .. tostring(app.ui.message))
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'chargement constaté')
  T.ok(app.loadTest and app.loadTest.ok, tostring(app.loadTest and app.loadTest.reason) .. ' / ' .. tostring(app.ui.message))
end

local function lastVersion(r)
  for i = #r.history, 1, -1 do
    if r.history[i].version then return r.history[i] end
  end
  return nil
end

-- Relecture n° 1 : course v1 essayée et chargée par SetupLab, puis validée : l'affinage de la course continue (v2), au
-- lieu d'exiger de nouveau un setup de qualification dans la voiture.
local function raceGoesOn(withMemory)
  local h, app = ready({ session = 3, skin = true })
  app.settings.refineMinLaps, app.settings.refineInstantFirst, app.settings.optBudgetEvalsC = 0, false, 300
  local folder = folderOf(h)
  if withMemory then
    Fake.raceReady(h, app, 12)
  else
    h.written[folder .. '/SetupLab_Qualif_v4.ini'] = h.ac.stringifyCurrentSetup(true, false)
    app.handleIntents({ raceLaps = 12 })
  end
  app.qualiScan = nil
  frames(h, 2)
  T.eq(app.raceBlocker(), nil, 'garde levée au départ')
  app.handleIntents({ refineStart = 'race' })
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end, 60000), 'v1 de course : ' .. tostring(r.waiting))
  local e = lastVersion(r)
  T.ok(e.family ~= e.originFamily, 'v1 de course différente du setup de qualification (budget réaliste)')
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'essayer' } })
  T.eq(e.status, 'essai', tostring(app.ui.message))
  loadVia(h, app, 'race')
  T.ok(waitFor(h, function() return not r.needsDiscovery and app.discoveryState == 'done' end), 'nouvelle découverte')
  frames(h, 30)
  local why, action = app.raceBlocker()
  T.eq(why, nil, 'garde après le chargement de la v1 de course : ' .. tostring(action))
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.eq(e.status, 'validée', tostring(app.ui.message))
  -- 1.5.3 : après la validation, on répond « Continuer l'affinage » (question posée à chaque fois)
  if app.refine and app.refine.choice then app.handleIntents({ refineChoice = { version = app.refine.choice } }) end
  local before = app.race
  r.due, r.nextAt = true, nil
  T.ok(waitFor(h, function() return app.race ~= before end, 600), 'v2 de course calculée : ' .. tostring(r.waiting))
  T.ok(not tostring(r.waiting):find('course : ', 1, true), 'affinage de la course non bloqué : ' .. tostring(r.waiting))
  T.eq(app.perf.errors, 0)
end

tests['RV01 course v1 essayée, chargée, validée : la v2 se calcule (qualification reconnue dans le dossier)'] = function()
  raceGoesOn(false)
end

tests['RV01m course v1 essayée, chargée, validée : la v2 se calcule (qualification validée en mémoire)'] = function()
  raceGoesOn(true)
end

-- Relecture n° 2 : « Calculer le setup course » pendant l'affinage du tour rapide, un affinage de course ayant déjà une
-- version : le clic calcule, sans attendre le minimum de tours.
tests['RV02 calcul de course demandé : un affinage de course repris calcule tout de suite'] = function()
  local h, app = ready({ session = 1, skin = true })
  app.settings.refineMinLaps, app.settings.refineInstantFirst = 2, false
  Fake.raceReady(h, app, 20)
  frames(h, 2)
  app.handleIntents({ refineStart = 'race' })
  local rr = app.refine
  T.ok(waitFor(h, function() return rr.version >= 1 and rr.phase == 'tours' end, 60000), 'v1 de course : ' .. tostring(rr.waiting))
  app.handleIntents({ refineStart = 'quali' })
  frames(h, 5)
  T.eq(app.refine.kind, 'quali')
  local before = app.race
  app.handleIntents({ raceStart = true })
  T.eq(app.refine, rr, 'affinage de course repris')
  T.ok(waitFor(h, function() return app.race ~= before end, 600), 'le clic a lancé un calcul : ' .. tostring(rr.waiting))
  T.eq(app.perf.errors, 0)
end

-- Relecture n° 3 : clé du cache des setups de qualification (même nombre de fichiers, noms de même longueur).
tests['RV03 setups de qualification : liste à jour après un essai remplacé par un autre de même longueur de nom'] = function()
  local h, app = ready({ session = 1 })
  local folder = folderOf(h)
  local text = h.ac.stringifyCurrentSetup(true, false)
  h.written[folder .. '/SetupLab_Qualif_v3_essai.ini'] = text
  app.written['SetupLab_Qualif_v3_essai.ini'] = 'x'
  app.qualiScan = nil
  frames(h, 3)
  T.eq(app.qualiFiles()[1].file, 'SetupLab_Qualif_v3_essai.ini')
  h.written[folder .. '/SetupLab_Qualif_v3_essai.ini'] = nil
  app.written['SetupLab_Qualif_v3_essai.ini'] = nil
  h.written[folder .. '/SetupLab_Qualif_v4_essai.ini'] = text
  app.written['SetupLab_Qualif_v4_essai.ini'] = 'y'
  frames(h, 3)
  local list = app.qualiFiles()
  T.eq(#list, 1)
  T.eq(list[1].file, 'SetupLab_Qualif_v4_essai.ini', 'liste relue')
end

-- Relecture n° 3 et 6 : 50 versions, la plus récente dans la voiture ; les plus récentes d'abord, quelques fichiers lus par
-- image (pas d'à-coup), la plus récente reconnue dès la première image.
tests['RV04 50 versions : les plus récentes gardées, lecture étalée, la v50 reconnue tout de suite'] = function()
  local h, app = ready({ session = 1, skin = true })
  local folder = folderOf(h)
  local text = h.ac.stringifyCurrentSetup(true, false)
  for v = 1, 49 do h.written[folder .. '/SetupLab_Qualif_v' .. v .. '.ini'] = otherSetup(text) end
  h.written[folder .. '/SetupLab_Qualif_v50.ini'] = text
  app.handleIntents({ raceLaps = 12 })
  local load, reads = h.io.load, 0
  h.io.load = function(path, ...)
    if tostring(path):find('SetupLab_Qualif_v', 1, true) then reads = reads + 1 end
    return load(path, ...)
  end
  h.tab = 'Course'
  app.qualiScan = nil
  frames(h, 1)
  T.ok(reads <= Config.K.raceQualiReadsPerFrame, 'lecture étalée : ' .. reads .. ' fichiers sur une image')
  T.eq(app.qualiInCar() and app.qualiInCar().file, 'SetupLab_Qualif_v50.ini', 'la plus récente reconnue tout de suite')
  T.eq(app.raceBlocker(), nil, 'garde levée dès la première image')
  frames(h, 30)
  local list = app.qualiFiles()
  local has = {}
  for _, f in ipairs(list) do has[f.version] = true end
  T.eq(#list, Config.K.raceQualiFilesMax, 'liste bornée')
  T.ok(has[50] and has[11] and not has[10], 'les plus récentes gardées')
  T.eq(list[1].version, 11, 'liste dans l\'ordre des versions')
  h.io.load = load
  T.eq(app.perf.errors, 0)
end

-- Relecture n° 4 : pendant une découverte (relancée par le calcul de course lui-même), la garde garde la qualification
-- reconnue : pas de verrou « qualification d'abord » ni de bouton qui annulerait le calcul en attente.
tests['RV05 pendant une découverte : setup de qualification toujours reconnu'] = function()
  local h, app = ready({ session = 1, skin = true })
  local folder = folderOf(h)
  h.written[folder .. '/SetupLab_Qualif_v4.ini'] = h.ac.stringifyCurrentSetup(true, false)
  app.handleIntents({ raceLaps = 12 })
  app.qualiScan = nil
  frames(h, 3)
  T.eq(app.raceBlocker(), nil, 'avant')
  app.handleIntents({ rediscover = true })
  T.eq(app.discoveryState, 'running')
  local why, action = app.raceBlocker()
  T.eq(why, nil, 'pendant la découverte : ' .. tostring(action))
  h.tab = 'Course'
  frames(h, 1)
  local trap = false
  for _, s in ipairs(h.texts) do trap = trap or (type(s) == 'string' and s:find('au moins une v1', 1, true) ~= nil) end
  T.ok(not trap, 'onglet COURSE non verrouillé pendant la découverte')
  T.eq(app.perf.errors, 0)
end

-- Relecture n° 1 (parcours de Vincent) : QUALIF « reprendre » v2, COURSE, calcul ; v1 de course essayée et chargée : la garde
-- reste levée.
tests['RV06 v2 reprise, course v1 essayée et chargée : garde levée'] = function()
  local h, app = ready({ session = 1, skin = true })
  app.settings.refineMinLaps, app.settings.refineInstantFirst, app.settings.optBudgetEvalsC = 2, false, 300
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
  app.handleIntents({ start = 'reference' })
  frames(h, 30)
  app.handleIntents({ raceLaps = 25 })
  frames(h, 2)
  app.handleIntents({ raceStart = true })
  local r = app.refine
  T.eq(r.kind, 'race')
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end, 60000), 'v1 de course : ' .. tostring(r.waiting))
  local e = lastVersion(r)
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'essayer' } })
  loadVia(h, app, 'race')
  T.ok(waitFor(h, function() return not r.needsDiscovery and app.discoveryState == 'done' end), 'nouvelle découverte')
  frames(h, 2)
  local why, action = app.raceBlocker()
  T.eq(why, nil, 'garde après le chargement de la v1 de course : ' .. tostring(action))
  T.eq(app.perf.errors, 0)
end

-- Relecture n° 8 : aucune qualification dans la voiture : l'affinage de la course dit ce qui manque (et pas « rouler »).
tests['RV07 affinage de course sans qualification dans la voiture : il dit de la charger'] = function()
  local h, app = ready({ session = 3, skin = true })
  app.settings.refineMinLaps, app.settings.refineInstantFirst = 2, false
  local folder = folderOf(h)
  h.written[folder .. '/SetupLab_Qualif_v4.ini'] = otherSetup(h.ac.stringifyCurrentSetup(true, false))
  app.qualiScan = nil
  app.handleIntents({ raceLaps = 12 })
  app.handleIntents({ refineStart = 'race' })
  local r = app.refine
  frames(h, 30)
  T.ok(tostring(r.waiting):find('course : ', 1, true) ~= nil, 'dit la garde : ' .. tostring(r.waiting))
  T.eq(app.perf.errors, 0)
end

-- Relecture n° 9 : crans illisibles : aucun setup de qualification « dans la voiture » par erreur.
tests['RV08 crans illisibles : aucun setup de qualification reconnu à tort'] = function()
  local h, app = ready({ session = 1 })
  local folder = folderOf(h)
  h.written[folder .. '/SetupLab_Qualif_v4.ini'] = otherSetup(h.ac.stringifyCurrentSetup(true, false))
  app.discovery.setup.spinners = {}
  app.qualiScan, app.inCar = nil, nil
  T.eq(#app.qualiFiles(), 0, 'aucune liste sans crans')
  T.eq(app.qualiInCar(), nil)
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Stratégie d'arrêt (relecture du 02/11/2026)

local function spinnerOf(h, name)
  for _, sp in ipairs(h.spinners) do
    if sp.name == name then return sp end
  end
  return nil
end

-- setup de course de SetupLab prêt à charger (comme après « Enregistrer ») ; renvoie son nom
local function raceSaved(h, app, text, name)
  local Util = require('src/util')
  local folder = folderOf(h)
  name = name or 'SetupLab_Course_v1.ini'
  h.written[folder .. '/' .. name] = text
  local hash = Util.hashString(text)
  app.written[name] = hash
  app.saved.race = { path = folder .. '/' .. name, name = name, text = text, signature = 'course-' .. name, hash = hash,
    bucket = 'sec', carId = h.ac.getCarID(0) }
  app.proposals.race = 'course-' .. name
  return name
end

-- setup de la voiture avec des pressions différentes à chaque roue et, si la voiture en a plusieurs, une autre gomme
local function asymmetric(h, app)
  local text = h.ac.stringifyCurrentSetup(true, false)
  local want = {}
  for i, name in ipairs({ 'PRESSURE_LF', 'PRESSURE_RF', 'PRESSURE_LR', 'PRESSURE_RR' }) do
    local sp = assert(spinnerOf(h, name), name)
    want[name] = math.min(sp.max, sp.min + i)
    local n
    text, n = text:gsub('(%[' .. name .. '%]%s*VALUE=)(%-?[%d%.]+)', function(a) return a .. want[name] end, 1)
    T.eq(n, 1, name .. ' dans le setup')
  end
  local compounds = app.discovery.carBase.compounds
  local tyres = (#compounds > 1 and compounds[2].index) or app.discovery.compoundIndex
  local n
  text, n = text:gsub('(%[TYRES%]%s*VALUE=)(%d+)', function(a) return a .. tyres end, 1)
  if n == 0 then text = text .. '\n[TYRES]\nVALUE=' .. tyres .. '\n' end
  return text, want, tyres
end

tests['PV01 stratégie d\'arrêt : chaque roue sa pression, la gomme du setup, relue dans le menu'] = function()
  local h, app = ready({ session = 1 })
  local text, want, tyres = asymmetric(h, app)
  raceSaved(h, app, text)
  loadVia(h, app, 'race')
  for name, v in pairs(want) do T.eq(h.pitstop[name], v, name) end
  T.eq(h.pitstop.COMPOUND, tyres, 'gomme du setup')
  T.eq(h.pitstop.FUEL, 0, 'carburant inchangé')
  T.eq(h.pitPresets[1], 'sélectionné', 'preset sélectionné')
  local pit = assert(app.pitStrategy, 'stratégie d\'arrêt posée')
  T.ok(pit.ok, pit.note)
  T.contains(pit.note, 'SetupLab_Course_v1.ini')
  T.contains(pit.note, 'LF ' .. want.PRESSURE_LF)
  T.contains(pit.note, 'RR ' .. want.PRESSURE_RR)
  T.contains(pit.note, '(changement de pneus prévu à l\'arrêt)')
  T.eq(app.discovery.caps.byId.pit_strategy.status, 'available', app.discovery.caps.byId.pit_strategy.detail)
  T.ok(not app.discovery.caps.byId.pit_strategy.detail:find('. ;', 1, true), 'pas de double ponctuation')
  local I18n = require('src/i18n')
  local en = I18n.en(pit.note)
  T.ok(not I18n.looksFrench(en), 'anglais : ' .. en)
  T.eq(app.perf.errors, 0)
end

tests['PV02 setup de course déjà dans la voiture : stratégie d\'arrêt posée quand même'] = function()
  local h, app = ready({ session = 1 })
  raceSaved(h, app, h.ac.stringifyCurrentSetup(true, false), 'SetupLab_Course_v2.ini')
  loadTry(h, app, 'race')
  T.contains(tostring(app.loadTest and app.loadTest.reason), 'non concluant')
  T.ok(h.pitCalls >= 4, 'menu d\'arrêt réglé : ' .. h.pitCalls)
  T.eq(h.pitstop.PRESSURE_LF, spinnerOf(h, 'PRESSURE_LF').value)
  T.contains(app.pitStrategy.note, 'SetupLab_Course_v2.ini')
  T.eq(app.perf.errors, 0)
end

tests['PV03 chargement de course en écart : menu d\'arrêt intact'] = function()
  local h, app = ready({ session = 1 })
  local text = asymmetric(h, app)
  raceSaved(h, app, text)
  h.opts.loadSkip = 'PRESSURE_LF'
  loadTry(h, app, 'race')
  T.ok(app.loadTest and not app.loadTest.ok, 'écart constaté')
  T.eq(h.pitCalls, 0, 'menu d\'arrêt intact')
  T.eq(app.pitStrategy, nil)
  T.eq(app.perf.errors, 0)
end

tests['PV04 réglages refusés par le jeu : dit, rapport J0 à confirmer'] = function()
  local h, app = ready({ session = 1 })
  local text = asymmetric(h, app)
  raceSaved(h, app, text)
  h.pitRefuse = true
  loadVia(h, app, 'race')
  local pit = assert(app.pitStrategy)
  T.ok(not pit.ok, pit.note)
  T.contains(pit.note, 'refusée par le jeu')
  T.eq(h.pitstop.PRESSURE_LF, 16, 'rien posé')
  T.eq(app.discovery.caps.byId.pit_strategy.status, 'pending')
  local I18n = require('src/i18n')
  T.ok(not I18n.looksFrench(I18n.en(pit.note)), I18n.en(pit.note))
  T.eq(app.perf.errors, 0)
end

tests['PV05 gomme absente du menu d\'arrêt : non posée, pressions posées, dit'] = function()
  local h, app = ready({ session = 1 })
  local text, want = asymmetric(h, app)
  raceSaved(h, app, text)
  h.pitMax = { COMPOUND = -1 }
  loadVia(h, app, 'race')
  local pit = assert(app.pitStrategy)
  T.eq(h.pitstop.COMPOUND, -1, 'gomme non posée (pas bornée)')
  T.eq(h.pitstop.PRESSURE_RF, want.PRESSURE_RF, 'pressions posées')
  T.ok(not pit.ok, pit.note)
  T.contains(pit.note, 'Pneus non posés')
  local I18n = require('src/i18n')
  T.ok(not I18n.looksFrench(I18n.en(pit.note)), I18n.en(pit.note))
  T.eq(app.perf.errors, 0)
end

tests['PV06 réglage du menu d\'arrêt absent de CSP : rapport J0 « indisponible »'] = function()
  local h, app = ready({ session = 1, noPitApi = true })
  T.eq(app.discovery.caps.byId.pit_strategy.status, 'unavailable')
  local text = asymmetric(h, app)
  raceSaved(h, app, text)
  loadVia(h, app, 'race')
  T.eq(h.pitCalls, 0)
  T.contains(app.pitStrategy.note, 'indisponible')
  T.eq(app.perf.errors, 0)
end

tests['PV07 réglage du menu d\'arrêt hors de l\'exporteur : refusé par le banc'] = function()
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  local ok = pcall(h.ac.setPitstopSpinnerValue, 'PRESSURE_LF', 20)
  T.ok(not ok, 'appel hors de l\'exporteur refusé')
  T.eq(h.pitCalls, 0)
end

-- Journal recopié dans le log de CSP (accord de Vincent du 02/11/2026) : relire une séance après coup.
local function lastEntry(app)
  local entries = require('src/util').logEntries(app.log)
  return entries[#entries]
end

local function cspCount(h, fragment)
  local n = 0
  for _, line in ipairs(h.cspLog) do
    if line:find(fragment, 1, true) then n = n + 1 end
  end
  return n
end

tests['LG01 journal recopié dans le log de CSP, ligne pour ligne et au même débit'] = function()
  local Util = require('src/util')
  local h, app = ready()
  local entries = Util.logEntries(app.log)
  T.ok(#entries > 0, 'journal de la découverte')
  T.eq(#h.cspLog, app.log.seq, 'une ligne du log CSP par ligne gardée au journal')
  for i, e in ipairs(entries) do
    T.eq(h.cspLog[#h.cspLog - #entries + i], e.level .. ' ' .. e.code .. ' : ' .. e.text)
  end
  app.handleIntents({ setting = { key = 'refineMinLaps', value = 3 } })
  app.handleIntents({ setting = { key = 'refineMinLaps', value = 4 } })
  T.eq(cspCount(h, 'INFO setting : '), 1, 'même code dans les 2 s : ni au journal ni au log CSP')
  T.eq(#h.cspLog, app.log.seq)
  frames(h, math.ceil(Config.K.logMinInterval * 60) + 5)
  app.handleIntents({ setting = { key = 'refineMinLaps', value = 2 } })
  T.eq(cspCount(h, 'INFO setting : '), 2, 'au-delà de 2 s : de nouveau au journal et au log CSP')
  T.eq(#h.cspLog, app.log.seq)
  T.eq(app.perf.errors, 0)
end

tests['LG02 erreur sur plusieurs lignes : une seule ligne au log CSP ; sans ac.log ou ac.log en erreur, rien ne casse'] = function()
  local h, app = ready()
  local text = h.ui.text
  h.ui.text = function() error('premiere ligne\n  seconde ligne', 0) end
  frames(h, 1)
  h.ui.text = text
  T.eq(app.perf.errors, 1, 'erreur de l\'interface comptée')
  local last = h.cspLog[#h.cspLog]
  T.contains(last, 'ERROR ui_main : ')
  T.contains(last, 'premiere ligne | seconde ligne')
  T.no(last:find('[\r\n]'), 'une seule ligne')
  frames(h, 30)
  T.eq(app.perf.errors, 1, 'l\'interface repart')
  -- ac.log en erreur : le journal continue, l'app aussi
  h.ac.log = function() error('ac.log indisponible') end
  app.handleIntents({ setting = { key = 'refineMinLaps', value = 3 } })
  T.eq(lastEntry(app).code, 'setting')
  frames(h, 30)
  -- ac.log absent (CSP sans cette fonction) : idem
  h.ac.log = nil
  frames(h, math.ceil(Config.K.logMinInterval * 60) + 5)
  app.handleIntents({ setting = { key = 'refineMinLaps', value = 2 } })
  T.eq(lastEntry(app).code, 'setting')
  frames(h, 30)
  T.eq(app.perf.errors, 1)
end

-- Journal de Vincent du 02/11/2026 (Imola) : « Retouche gardée (quali) : CAMBER_LF -23 -> -20 » juste après le chargement
-- de la v1 de course. Les écarts du setup de course au setup de qualification chargé avant lui ne sont pas des retouches
-- du pilote : seules comptent celles faites depuis le dernier setup chargé par SetupLab.
local function pinCount(pins)
  local n = 0
  for _ in pairs(pins or {}) do n = n + 1 end
  return n
end

tests['PN01 setup de course chargé après un setup de qualification : aucune « retouche » de qualif ; les vraies restent'] = function()
  local Util = require('src/util')
  local h, app = ready({ session = 1 })
  local folder = folderOf(h)
  local base = h.ac.stringifyCurrentSetup(true, false)
  local quali = otherSetup(base)
  h.written[folder .. '/SetupLab_Qualif_v2.ini'] = quali
  local hq = Util.hashString(quali)
  app.written['SetupLab_Qualif_v2.ini'] = hq
  app.saved.quali = { path = folder .. '/SetupLab_Qualif_v2.ini', name = 'SetupLab_Qualif_v2.ini', text = quali,
    signature = 'qualif-v2', hash = hq, bucket = 'sec', carId = h.ac.getCarID(0) }
  app.proposals.quali = 'qualif-v2'
  loadVia(h, app, 'quali')
  T.ok(app.loaded.quali, 'qualification chargée')
  -- une vraie retouche du pilote sur la qualification, vue à la découverte suivante
  local sp = assert(spinnerOf(h, 'PRESSURE_LF'))
  sp.value = math.min(sp.max, sp.value + 1)
  app.handleIntents({ rediscover = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  T.eq(pinCount(app.pins.quali), 1, 'retouche du pilote gardée pour la qualification')
  local genuine = app.pins.quali.PRESSURE_LF.value
  -- setup de course : pressions et gomme différentes, plus d'autres crans
  local race = asymmetric(h, app)
  race = otherSetup(otherSetup(race))
  raceSaved(h, app, race)
  loadVia(h, app, 'race')
  app.handleIntents({ rediscover = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte après la course')
  frames(h, 30)
  T.eq(pinCount(app.pins.quali), 1, 'aucune retouche de qualification tirée du setup de course')
  T.eq(app.pins.quali.PRESSURE_LF.value, genuine, 'la vraie retouche garde sa valeur')
  T.eq(pinCount(app.pins.race), 0, 'setup de course tel que chargé : aucune retouche')
  -- retouche faite après le chargement de la course : elle compte pour la course
  local arb = assert(spinnerOf(h, 'ARB_FRONT'))
  arb.value = arb.value > arb.min and arb.value - 1 or arb.value + 1
  app.handleIntents({ rediscover = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte après la retouche')
  T.ok(app.pins.race.ARB_FRONT, 'retouche de la course gardée pour la course')
  T.eq(pinCount(app.pins.quali), 1)
  T.eq(app.perf.errors, 0)
end

-- Carte d'étape dans l'onglet de son genre seulement (constat de Vincent du 02/11/2026 : « Étape 3/4 · Essayer v3 » de
-- la qualification apparaissait aussi dans les onglets COURSE et MÉMOIRE).
local function shown(h, fragment)
  for _, s in ipairs(h.texts) do
    if tostring(s):find(fragment, 1, true) then return true end
  end
  return false
end

local function onTab(h, id)
  h.tab = id
  frames(h, 1)
  h.tab = nil
  frames(h, 1)
end

tests['UI02 carte d\'étape : dans l\'onglet de son genre seulement ; en séance de course, COURSE d\'abord'] = function()
  local h, app = ready({ skin = true })
  frames(h, 1)
  T.eq(app.ui.tab, 'Tour rapide', 'essai : QUALIF d\'abord')
  T.ok(shown(h, 'Étape 1/4 · Départ'), 'QUALIF : carte de départ')
  for _, id in ipairs({ 'Course', 'Mémoire', 'Mesure', 'Réglages', 'Capacités', 'Aide' }) do
    onTab(h, id)
    T.eq(app.ui.tab, id)
    T.no(shown(h, 'Étape 1/4'), 'pas de carte d\'étape de la qualification dans l\'onglet ' .. id)
  end
  onTab(h, 'Tour rapide')
  T.ok(shown(h, 'Étape 1/4 · Départ'), 'de retour dans QUALIF')
  local h2, app2 = ready({ session = 3, skin = true })
  frames(h2, 1)
  T.eq(app2.ui.tab, 'Course', 'course : COURSE d\'abord')
  T.ok(shown(h2, 'Course · avant le calcul'), 'carte de la course dans COURSE')
  onTab(h2, 'Tour rapide')
  T.no(shown(h2, 'Course · avant le calcul'), 'pas dans QUALIF')
  T.eq(app.perf.errors + app2.perf.errors, 0)
end

-- Boutons neutres lisibles (constat de Vincent du 02/11/2026 : Figer, Recommencer, Valider vN « on les confond avec les
-- textes normaux ») : au fond des cartes (field), l'aplat field du bouton ne se voyait pas.
tests['UI01 bouton neutre du thème : aplat plus clair que les cartes, trait bleu ; boutons de couleur inchangés'] = function()
  local Skin = require('src/skin')
  local rects = {}
  local hovered = false
  local function v2(x, y) return { x = x, y = y } end
  local real = {
    pushDWriteFont = function() end, popDWriteFont = function() end, dwriteDrawText = function() end,
    measureDWriteText = function(text, size) return { x = 6 * #text, y = size * 1.3 } end,
    availableSpaceX = function() return 300 end, invisibleButton = function() return false end,
    itemHovered = function() return hovered end, itemActive = function() return false end,
    itemRectMin = function() return v2(10, 20) end, itemRectMax = function() return v2(110, 46) end,
    drawRectFilled = function(a, b, color) rects[#rects + 1] = { ax = a.x, ay = a.y, bx = b.x, by = b.y, color = color } end,
  }
  local S = Skin.new(real, function(r, g, b, m) return { r = r, g = g, b = b, mult = m } end, v2, function(s) return s end)
  local c = S.colors
  S.button('Figer v1 (cadenas)')
  T.eq(#rects, 2, 'trait, puis aplat')
  T.eq(rects[1].color, c.outline)
  T.eq(rects[2].color, c.raised)
  T.ok(rects[2].color.r >= c.field.r + 0.05 and rects[2].color.g >= c.field.g + 0.05, 'aplat plus clair que le fond des cartes')
  T.eq(rects[2].ax, 11)
  T.eq(rects[2].ay, 21)
  T.eq(rects[2].bx, 109)
  T.eq(rects[2].by, 45)
  rects, hovered = {}, true
  S.button('Recommencer (ne pas garder v1)')
  T.eq(rects[1].color, c.blue, 'survol : trait bleu plein')
  T.eq(rects[2].color, c.raisedHover)
  hovered = false
  for style, key in pairs({ primary = 'blue', go = 'go', danger = 'danger' }) do
    rects = {}
    S.button('Action###' .. style, nil, style)
    T.eq(#rects, 1, style .. ' : un seul aplat, comme avant')
    T.eq(rects[1].color, c[key])
  end
end

return tests
