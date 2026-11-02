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

-- chargement par SetupLab, deux clics au stand
local function loadVia(h, app, kind)
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  frames(h, 1)
  app.handleIntents({ loadArm = kind })
  T.ok(app.loadArm and app.loadArm.kind == kind, 'armé : ' .. tostring(app.ui.message))
  local started = app.clock()
  while app.clock() - started < Config.K.loadConfirmMinSeconds + 0.1 do frames(h, 1) end
  app.handleIntents({ loadConfirm = kind })
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

return tests
