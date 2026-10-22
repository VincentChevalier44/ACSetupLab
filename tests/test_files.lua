-- Fichiers rangés (décision de Vincent du 22/10/2026 : « à partir du moment où on a validé la V1 ou la V2 ou la
-- V3, il faut qu'il ne reste que les fichiers V1, V2, V3, pas les intermédiaires » ; « en plus du nom, le meilleur
-- temps réel qui a été effectué avec ce setup », qualification seulement). Réponses de Vincent : noms
-- « SetupLab_Qualif_v1 », « SetupLab_Course_Pluie_v3 » (nom choisi à la place de SetupLab) ; copies « Avant
-- chargement » seulement si utiles ; « Recommencer » : le fichier part à la Corbeille. Rangement voiture arrêtée,
-- un fichier par image, seulement des fichiers écrits par SetupLab et intacts.
local T = require('t')
local Util = require('src/util')
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
    missing = opts.missing, existing = opts.existing })
  h.sim.raceSessionType = 2
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

local function toe(h)
  for _, sp in ipairs(h.spinners) do
    if sp.name == 'TOE_OUT_LF' or sp.name == 'TOE_OUT_RF' then sp.value = sp.value + sp.step end
  end
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

-- Voiture arrêtée au stand (le conducteur simulé lâche le volant).
local function stop(h)
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  h.driver = nil
end

local function loadAtPit(h, app)
  stop(h)
  frames(h, 1)
  h.click = 'Charger le setup tour rapide dans la voiture'
  frames(h, 1)
  T.ok(app.loadArm, tostring(app.ui.message))
  local started = app.clock()
  while app.clock() - started < Config.K.loadConfirmMinSeconds + 0.1 do frames(h, 1) end
  h.click = 'Confirmer le chargement (tour rapide)'
  frames(h, 1)
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'constat du chargement')
  T.ok(app.loadTest and app.loadTest.ok, tostring(app.loadTest and app.loadTest.reason) .. ' / ' .. tostring(app.ui.message))
end

local function backupsOnDisk(h)
  local list = {}
  for path in pairs(h.written) do
    if path:find(Config.exportBackupPrefix, 1, true) then list[#list + 1] = path end
  end
  return list
end

-- v1 proposée, validée, chargée au stand ; renvoie l'affinage et v1.
local function v1Loaded(h, app)
  h.click = 'Affinage automatique (tour rapide)'
  frames(h, 1)
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end), 'v1')
  h.click = 'Valider v' .. r.version
  frames(h, 1)
  local v1 = r.history[#r.history]
  T.eq(v1.status, 'validée', tostring(app.ui.message))
  loadAtPit(h, app)
  T.ok(waitFor(h, function() return not r.needsDiscovery and app.discoveryState == 'done' and r.phase == 'tours' end))
  return r, v1
end

tests['RG01 noms : genre et pluie dans le nom, nom choisi à la place de SetupLab, temps au tour à la façon d\'AC'] = function()
  T.eq(Util.formatLapFile(101.792), '1.41.792')
  T.eq(Util.formatLapFile(59.9996), '1.00.000', 'arrondi à la milliseconde')
  T.eq(Util.formatLapFile(0), nil)
  T.near(Util.lapFromFileName('SetupLab_Qualif_v2_1.41.792.ini'), 101.792, 1e-9)
  T.near(Util.lapFromFileName('SetupLab_Qualif_v2_1.41.792-2.ini'), 101.792, 1e-9, 'suffixe d\'unicité ignoré')
  T.eq(Util.lapFromFileName('SetupLab_Qualif_v2.ini'), nil)
  T.eq(Util.withLapTime('SetupLab_Qualif_v2.ini', 101.792), 'SetupLab_Qualif_v2_1.41.792')
  T.eq(Util.withLapTime('SetupLab_Qualif_v2_1.41.792-2.ini', 100.5), 'SetupLab_Qualif_v2_1.40.500', 'ancien temps remplacé')
  T.eq(Util.versionInName('SetupLab_Qualif_Pluie_v12_1.40.000.ini', 'Qualif'), 12)
  T.eq(Util.versionInName('Mon_setup_Qualif_v4-2.ini', 'Qualif'), 4)
  T.eq(Util.versionInName('SetupLab_Course_v3.ini', 'Qualif'), nil)
  T.eq(Util.versionInName('SetupLab_Qualif_2026-10-22_13h33m30s.ini', 'Qualif'), nil, 'enregistrement daté : pas une version')
  local h, app = ready()
  T.eq(app.fileBase('quali', 'sec'), 'SetupLab_Qualif')
  T.eq(app.fileBase('race', 'pluie'), 'SetupLab_Course_Pluie')
  app.names.quali, app.names.race = 'Test Setup', 'Spa course'
  T.eq(app.fileBase('quali', 'sec'), 'Test_Setup_Qualif')
  T.eq(app.fileBase('race', 'sec'), 'Spa_course', 'le nom finit déjà par le genre : pas répété')
  app.names.quali = ''
  -- enregistrement à la main : genre et date dans le nom
  h.click = 'Calculer le setup tour rapide'
  frames(h, 1)
  T.ok(waitFor(h, function() return app.quali and app.quali.state == 'done' end))
  h.click = 'Enregistrer le setup tour rapide'
  frames(h, 1)
  T.ok(app.quali.saved.name:find('^SetupLab_Qualif_%d%d%d%d%-'), app.quali.saved.name)
  T.eq(app.perf.errors, 0)
end

tests['RG02 versions numérotées à la suite sur le circuit : v4 déjà dans le dossier, la suivante est v5'] = function()
  local existing = {}
  local h, app = ready({ existing = existing })
  local folder = folderOf(h)
  existing[folder .. '/SetupLab_Qualif_v4_1.40.000.ini'] = true
  existing[folder .. '/SetupLab_Course_v9.ini'] = true
  existing[folder .. '/1.ini'] = true
  h.click = 'Affinage automatique (tour rapide)'
  frames(h, 1)
  local r = app.refine
  T.eq(r.base, 4, 'course et autres fichiers ignorés')
  T.ok(waitFor(h, function() return r.version >= 5 and r.phase == 'tours' end), 'v5')
  frames(h, 1)
  h.click = 'Valider v5'
  frames(h, 1)
  T.eq(r.history[#r.history].file, 'SetupLab_Qualif_v5.ini', tostring(app.ui.message))
  T.ok(h.written[folder .. '/SetupLab_Qualif_v5.ini'])
  T.eq(app.perf.errors, 0)
end

tests['RG03 meilleur tour réel dans le nom (qualification) : renommé voiture arrêtée, tout suit ; jamais en roulant'] = function()
  local h, app = ready()
  local folder = folderOf(h)
  local r, v1 = v1Loaded(h, app)
  local old = v1.file
  T.eq(old, 'SetupLab_Qualif_v1.ini')
  local profile = drivenProfile(h, app)
  T.ok(waitFor(h, function()
    local f = app.recorder.laps.family[v1.family]
    return f ~= nil and f.count >= 1
  end, 120000, profile), 'un tour propre avec v1')
  frames(h, 30, profile)
  T.eq(#h.moves, 0, 'rien en roulant')
  T.ok(#app.fileOps >= 1, 'renommage en attente')
  local best = app.recorder.laps.family[v1.family].best
  stop(h)
  T.ok(waitFor(h, function() return #h.moves >= 1 end, 10), 'renommé voiture arrêtée')
  local name = 'SetupLab_Qualif_v1_' .. Util.formatLapFile(best) .. '.ini'
  T.eq(v1.file, name)
  T.eq(h.moves[1].from, folder .. '/' .. old)
  T.eq(h.moves[1].to, folder .. '/' .. name)
  T.eq(app.written[old], nil)
  T.eq(app.written[name], v1.hash)
  T.eq(app.memory['qualif|sec'].file, name, 'mémoire du circuit')
  T.eq(app.saved.quali.name, name, 'setup à charger')
  T.eq(app.saved.quali.path, folder .. '/' .. name)
  T.eq(app.loaded.quali.name, name, 'setup chargé')
  local stored = Store.get(app.store, Store.entryKey('mem', app.discovery.car.id, 'monza', '-', 'qualif', 'sec'))
  T.eq(stored and stored.file, name, 'mémoire stockée')
  T.ok(Exporter.ownFile({ ac = h.ac, io = h.io }, name, v1.hash), 'toujours reconnu, chargeable')
  T.contains(app.filesNote, name)
  -- même temps (ou plus lent) : rien de plus
  app.queueBestRename({ valid = true, family = v1.family, bucket = 'sec' })
  T.eq(#app.fileOps, 0, 'temps du nom non battu')
  -- course : jamais de temps dans le nom
  app.recorder.laps.family['famille-course'] = { best = 100, count = 1, sum = 100 }
  app.written['SetupLab_Course_v1.ini'] = 'h'
  app.memory['course|sec'] = { group = 'course', bucket = 'sec', file = 'SetupLab_Course_v1.ini', text = 'x', hash = 'h',
    family = 'famille-course' }
  app.queueBestRename({ valid = true, family = 'famille-course', bucket = 'sec' })
  T.eq(#app.fileOps, 0, 'course : pas de renommage')
  app.memory['course|sec'], app.written['SetupLab_Course_v1.ini'] = nil, nil
  T.eq(r.driven, v1.version)
  T.eq(app.perf.errors, 0)
end

tests['RG04 copies « Avant chargement » : seulement si utiles ; à la validation, une copie en double part à la Corbeille'] = function()
  local h, app = ready()
  local folder = folderOf(h)
  local r, v1 = v1Loaded(h, app)
  -- premier chargement : la voiture avait votre setup (pas un fichier gardé) : copie écrite
  T.eq(#backupsOnDisk(h), 1, 'copie du setup de départ')
  T.eq(#app.backups, 1)
  local mine = backupsOnDisk(h)[1]
  -- copie identique à v1 (gardée) : en double
  local dupName = Config.exportBackupPrefix .. 'double.ini'
  h.written[folder .. '/' .. dupName] = v1.text
  app.backups[#app.backups + 1] = { name = dupName, hash = Util.hashString(v1.text), values = app.setupValues(v1.text) }
  -- v2 : autre base, un tour propre, validée en roulant : rien tant que la voiture roule
  toe(h)
  local profile = drivenProfile(h, app)
  T.ok(waitFor(h, function() return r.version >= 2 and r.phase == 'tours' end, nil, profile), 'v2')
  h.click = 'Valider v2'
  frames(h, 1, profile)
  T.eq(r.history[#r.history].status, 'validée', tostring(app.ui.message))
  frames(h, 30, profile)
  T.ok(h.written[folder .. '/' .. dupName], 'rien en roulant')
  stop(h)
  T.ok(waitFor(h, function() return h.written[folder .. '/' .. dupName] == nil end, 10), 'copie en double à la Corbeille')
  T.eq(h.recycled[#h.recycled], folder .. '/' .. dupName)
  T.ok(h.written[mine], 'votre setup de départ reste (il n\'existe nulle part ailleurs)')
  T.contains(app.filesNote, 'copie identique à ' .. v1.file)
  -- chargement de v2 : la voiture avait v1 plus votre pincement (retouche non enregistrée) : copie écrite
  local copies = #backupsOnDisk(h)
  loadAtPit(h, app)
  T.eq(#backupsOnDisk(h), copies + 1, 'votre retouche est sauvegardée')
  local v2 = r.history[#r.history]
  -- v2 rechargée alors qu'elle est déjà dans la voiture, intacte : copie inutile, rien d'écrit
  local writes = h.writeCalls
  h.click = 'Charger le setup tour rapide dans la voiture'
  frames(h, 1)
  T.ok(app.loadArm, tostring(app.ui.message))
  local started = app.clock()
  while app.clock() - started < Config.K.loadConfirmMinSeconds + 0.1 do frames(h, 1) end
  h.click = 'Confirmer le chargement (tour rapide)'
  frames(h, 1)
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'constat du chargement')
  T.eq(h.writeCalls, writes, 'aucune copie inutile')
  T.eq(app.backupsSkipped, 1)
  T.contains(app.ui.message, 'setup précédent déjà enregistré : ' .. v2.file)
  T.eq(app.perf.errors, 0)
end

tests['RG05 sûreté : fichier modifié, gardé ou étranger jamais touché ; un fichier par image ; rien pendant un chargement'] = function()
  local h, app = ready()
  local folder = folderOf(h)
  local r, v1 = v1Loaded(h, app)
  stop(h)
  frames(h, 2)
  local recycled = #h.recycled
  -- fichier gardé (référence de la mémoire) : jamais à la Corbeille
  app.queueFileOp({ op = 'corbeille', name = v1.file, hash = v1.hash, why = 'test' })
  -- fichier étranger (vos setups, ceux du jeu) : jamais, même empreinte connue
  h.written[folder .. '/1.ini'] = 'MIEN'
  app.queueFileOp({ op = 'corbeille', name = '1.ini', hash = Util.hashString('MIEN'), why = 'test' })
  frames(h, 4)
  T.eq(#h.recycled, recycled, 'rien de gardé ni d\'étranger')
  T.ok(h.written[folder .. '/' .. v1.file] and h.written[folder .. '/1.ini'])
  -- deux copies en attente : une par image ; aucune pendant un chargement armé
  local a, b = Config.exportBackupPrefix .. 'a.ini', Config.exportBackupPrefix .. 'b.ini'
  for _, name in ipairs({ a, b }) do
    h.written[folder .. '/' .. name] = 'COPIE ' .. name
    app.backups[#app.backups + 1] = { name = name, hash = Util.hashString('COPIE ' .. name), values = {} }
    app.queueFileOp({ op = 'corbeille', name = name, hash = Util.hashString('COPIE ' .. name), why = 'test' })
  end
  app.loadArm = { kind = 'quali', path = 'x', signature = 'y', untilNow = app.now + 60, frames = 0 }
  script.SETUPLAB__UPDATE(1 / 60)
  T.eq(#h.recycled, recycled, 'chargement armé : rien')
  app.loadArm = nil
  script.SETUPLAB__UPDATE(1 / 60)
  T.eq(#h.recycled, recycled + 1, 'une seule par image')
  script.SETUPLAB__UPDATE(1 / 60)
  T.eq(#h.recycled, recycled + 2)
  -- version non gardée, modifiée entre-temps (enregistrée par-dessus dans le menu d'AC) : laissée telle quelle
  toe(h)
  local profile = drivenProfile(h, app)
  T.ok(waitFor(h, function() return r.version >= 2 and r.phase == 'tours' end, nil, profile), 'v2')
  h.click = 'Valider v2'
  frames(h, 1, profile)
  local v2 = r.history[#r.history]
  local path2 = folder .. '/' .. v2.file
  h.click = 'Recommencer (ne pas garder v2)'
  frames(h, 1, profile)
  h.written[path2] = h.written[path2] .. '\n; retouché'
  stop(h)
  frames(h, 5)
  T.ok(h.written[path2], 'fichier modifié : jamais touché')
  T.eq(#app.fileOps, 0, 'abandonné, dit dans le journal')
  T.eq(app.perf.errors, 0)
end

tests['RG06 io.recycle absente : rien ne part, aucune erreur'] = function()
  local h, app = ready({ missing = { 'io.recycle' } })
  local folder = folderOf(h)
  local r = v1Loaded(h, app)
  toe(h)
  local profile = drivenProfile(h, app)
  T.ok(waitFor(h, function() return r.version >= 2 and r.phase == 'tours' end, nil, profile), 'v2')
  h.click = 'Valider v2'
  frames(h, 1, profile)
  local v2 = r.history[#r.history]
  local name = v2.file
  h.click = 'Recommencer (ne pas garder v2)'
  frames(h, 1, profile)
  stop(h)
  frames(h, 5)
  T.ok(h.written[folder .. '/' .. name], 'fichier resté')
  T.eq(#app.fileOps, 0)
  T.eq(app.perf.errors, 0)
end

return tests
