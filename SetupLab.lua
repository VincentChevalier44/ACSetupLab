-- SetupLab — colle CSP : construit l'hôte injecté, enregistre les rappels du manifest,
-- applique les garde-fous globaux (§5, §16) et pilote les tâches de fond (D6).
-- Seul fichier à lire les globales CSP ; les modules reçoivent l'hôte en paramètre (D5).

local Util = require('src/util')
local Config = require('src/config')
local Caps = require('src/caps')
local Datasource = require('src/datasource')
local Ui = require('src/ui')
local Exporter = require('src/exporter')
local TrackModel = require('src/track_model')
local CarModel = require('src/car_model')
local SetupSpace = require('src/setup_space')
local Sim = require('src/laptime_sim')
local Optimizer = require('src/optimizer')
local Recorder = require('src/recorder')
local Store = require('src/store')
local Calibration = require('src/calibration')

local K = Config.K

-- Rechargement du script : l'instance précédente est libérée avant tout (§16.7).
local previous = rawget(_G, 'SETUPLAB')
if type(previous) == 'table' and type(previous.release) == 'function' then pcall(previous.release) end

local okFfi, ffi = pcall(require, 'ffi')

local host = {
  ac = ac, physics = physics, io = io, ui = ui,
  vec2 = vec2, vec3 = vec3, rgbm = rgbm,
  ffi = okFfi and ffi or nil,
}

local app = {
  settings = Config.defaults(),
  log = Util.logNew(K.logCapacity, K.logMinInterval, K.logMaxChars),
  scheduler = Util.schedulerNew(K.unitDecay),
  clock = nil, clockReason = nil,
  utcOffset = nil, utcOffsetReason = nil, -- décalage heure locale - UTC (noms des fichiers enregistrés)
  static = nil,
  context = nil, contextKey = nil, nextContextAt = 0,
  conditionsKey = nil, pendingSessionKey = nil, -- séance de la découverte ; nouvelle séance vue une fois
  inert = nil,
  updateSource = nil, otherSourceCalls = 0,
  discovery = nil, discoveryState = 'idle', discoveryError = nil,
  report = nil, reportTruncated = false,
  writeTest = nil,           -- dernier test d'écriture (copie du setup courant, D17)
  loadArm = nil,             -- chargement dans la voiture armé (premier clic) : genre, fichier, échéance
  loadCheck = nil,           -- chargement demandé : vérification du setup en cours (signature en direct)
  loadTest = nil,            -- issue du dernier appel à ac.loadSetup : vérifié, écart, refus, non concluant
  loadVerified = nil,        -- dernier chargement vérifié (capacité setup_load)
  pendingComputes = {},      -- genres de calcul demandés pendant une découverte (lancés à sa fin)
  saved = {},                -- genre -> dernier setup enregistré : chemin, texte, signature, voiture (chargement)
  refine = nil,              -- mode affinage : genre, phase, tours comptés, versions enregistrées (historique)
  auto = false,              -- SetupLab actif (case à cocher, décision de Vincent du 21/10/2026) : affinage automatique du
                             -- genre de la séance ; pour ce lancement d'AC seulement (rien d'écrit avant le clic)
  names = { quali = '', race = '' }, -- nom choisi pour les fichiers de chaque genre (vide : « SetupLab »)
  backups = {},              -- copies « Avant chargement » écrites pendant ce lancement : nom, empreinte, valeurs
  fileOps = {},              -- rangement des fichiers en attente (voiture arrêtée) : Corbeille, meilleur tour dans le nom
  filesNote = nil,           -- dernier rangement fait (affiché sous le nom du setup)
  written = {},              -- nom de fichier -> empreinte du contenu écrit par SetupLab (chargeable, D8 amendé)
  memory = {},               -- « séance|état » -> setup validé de ce circuit (figé ou non), fichier relu et vérifié
  memoryFiles = {},          -- chemin -> fichier de la mémoire relu (empreinte, texte, signature, instant de la relecture)
  loaded = {},               -- genre -> valeurs du dernier setup chargé par SetupLab (retouches du pilote)
  pins = { quali = {}, race = {} }, -- genre -> cran retouché à la main après un chargement -> { value, from }
  identityMisses = 0,        -- relectures d'affilée sans voiture ni circuit identifiés
  proposalOrigins = {},      -- genre -> signature du setup d'origine du setup proposé (validation, §14.1)
  quali = nil,               -- calcul de qualification : état, progression, résultat (§10.6)
  race = nil,                -- calcul course : état, progression, résultat (§10.6, §8.7)
  recorder = Recorder.new(), -- tours enregistrés (§9.1)
  knownSetups = {},          -- signature des crans -> setup physique connu (découverte, setup proposé)
  knownOrder = {},           -- ordre d'arrivée des setups connus (éviction)
  reconnaissanceTries = 0,   -- reconnaissances tentées dans ce contexte
  proposals = {},            -- genre (quali, race) -> signature du dernier setup enregistré
  calibration = nil,         -- dernière calibration lancée : état, résultat (§9.2)
  calibrations = {},         -- calibration par composé (index CSP) et état de piste (calKey), facteurs (§9.2)
  wet = { state = 'sec' },   -- état de la piste (D16 amendé) : « sec » ou « pluie », avec hystérésis
  proposalBuckets = {},      -- genre -> état de piste du calcul du setup proposé (validation, §14.1)
  validations = {},          -- genre -> validation du setup proposé (§14.1) : gain prévu contre gain mesuré
  liveConditions = {},       -- conditions de piste courantes (contexte, 1 Hz)
  recordContext = {},
  reconnaissance = nil,      -- ligne reconstituée depuis un tour (sans ligne IA, A14)
  measureOnly = nil,         -- mode « mesure uniquement » (§9.4) : modèle estimé sur un tour
  perf = { lastMs = 0, avgMs = 0, maxMs = 0, guardSkips = 0, slowFrames = 0, slowSlices = 0, errors = 0, skipNext = false },
  now = 0,
  released = false,
  disposers = {},
  ui = Ui.new(),
}

local frameCost = 0

-- Persistance (§13) : réglages de l'app relus et validés au chargement (aucune confiance dans le stockage).
app.store = Store.open(host)
do
  local stored = Store.get(app.store, 'settings')
  if stored then
    for _, key in ipairs(Config.EDITABLE) do
      if stored[key] ~= nil then app.settings[key] = stored[key] end
    end
    app.settings = Config.validate(app.settings)
  end
end

-- Horodatage (s) des entrées stockées : temps système du contexte.
local function stamp()
  return app.context and app.context.systemTime or nil
end

-- Clé d'une calibration (§9.2) : index CSP du composé sur piste sèche (clé d'avant la pluie), « index#pluie »
-- sur piste mouillée (D16 amendé le 21/10/2026, décision de Vincent : facteurs propres au mouillé, jamais
-- mélangés avec ceux du sec).
local function calKey(index, bucket)
  if bucket == 'pluie' then return tostring(index) .. '#pluie' end
  return index
end

-- Horodatage des noms de fichiers : heure locale de Windows (demande de Vincent du 21/10/2026 : l'heure
-- de l'enregistrement se lit dans la liste des setups d'AC) ; sans elle, heure universelle, dite dans le
-- nom. Deux enregistrements dans la même seconde : suffixe -2, -3… (Exporter.freeName).
local function fileStamp()
  local t = app.context and app.context.systemTime or 0
  local offset = app.utcOffset and app.utcOffset() or nil
  if offset then return Util.formatFileStamp(t + offset) end
  return Util.formatFileStamp(t) .. 'UTC'
end

-- Séance de la mémoire (décision de Vincent du 21/10/2026 : mémoire par circuit et par type de séance) :
-- « course » pour un setup course ; « qualif » pour un setup tour rapide en qualification ; « essai » sinon
-- (essai ou journée circuit, hotlap, time attack).
local function memoryGroup(kind)
  if kind == 'race' then return 'course' end
  if app.context and app.context.sessionType == K.sessionTypeQuali then return 'qualif' end
  return 'essai'
end

-- Genre affiné quand SetupLab est actif : course en séance de course, tour rapide sinon (décision de Vincent).
local function autoKind()
  return (app.context and app.context.sessionType == K.sessionTypeRace) and 'race' or 'quali'
end

-- Nom de fichier choisi pour un genre (sans accent ni espace) ; '' si aucun.
local function customName(kind)
  return Util.fileNameFrom(app.names[kind], K.nameMaxChars)
end

-- Base des noms de fichiers (décision de Vincent du 22/10/2026 : « on a du mal à les différencier ») : nom
-- choisi, sinon « SetupLab », puis le genre (Qualif, Course ; pas répété si le nom choisi finit déjà par lui)
-- et « Pluie » sous la pluie.
local function fileBase(kind, bucket)
  local custom = customName(kind)
  local genre = Config.fileGenre[kind]
  local base = custom ~= '' and custom or Config.fileDefaultName
  local low = base:lower()
  if not (low == genre:lower() or low:sub(-#genre - 1) == '_' .. genre:lower()) then base = base .. '_' .. genre end
  return base .. (bucket == 'pluie' and ('_' .. Config.fileWet) or '')
end
app.fileBase = fileBase

-- Clés stockées de la voiture et du circuit (disposition comprise) de la découverte.
local function storeKey(kind, d, ...)
  if not (d and d.car and d.trackFiles and type(d.trackFiles.fullId) == 'string') then return nil end
  -- identifiant complet « circuit/disposition » : la disposition est une partie de la clé (§13), « - » sans
  local track, layout = d.trackFiles.fullId:match('^([^/]+)/([^/]+)$')
  if track == nil then track, layout = d.trackFiles.fullId, '-' end
  return Store.entryKey(kind, d.car.id, track, layout, ...)
end

local function log(level, code, message)
  Util.logAdd(app.log, app.now, level, code, message)
end

-- Mémoire du circuit (décision de Vincent du 21/10/2026) : setup validé par voiture, circuit, disposition,
-- séance et état de piste ; figé (cadenas) ou non. Le fichier est désigné par son nom et l'empreinte de son
-- contenu (le dossier se déduit de la voiture et du circuit).
local function memoryPut(m)
  app.memory[m.group .. '|' .. m.bucket] = m
  local key = storeKey('mem', app.discovery, m.group, m.bucket)
  if key == nil then return false end
  return Store.put(app.store, key, { file = m.file, hash = m.hash, version = m.version, gain = m.gain, time = m.time,
    locked = m.locked == true }, stamp())
end

-- Exécute fn sous pcall et ajoute sa durée au coût de la frame courante.
local function measure(fn, ...)
  local started = app.clock and app.clock() or nil
  local ok, err = pcall(fn, ...)
  if started then frameCost = frameCost + (app.clock() - started) * 1000 end
  return ok, err
end

-- ---------------------------------------------------------------------------
-- Découverte J0 : lecture de toutes les sources puis évaluation des capacités
-- ---------------------------------------------------------------------------

-- Signature d'un setup : noms et valeurs des crans, dans l'ordre de CSP (overrides : valeurs
-- remplacées, pour le setup proposé), et composé de pneus (index CSP ; ce n'est pas un cran).
-- Les crans viennent toujours de Datasource.copySpinner (mêmes règles d'assainissement à la
-- découverte et en roulant) ; le carburant n'en fait pas partie (mesuré à part, il change entre deux
-- relais sans changer le setup).
local function signatureOf(spinners, overrides, compoundIndex, ignored)
  ignored = ignored or K.signatureIgnored
  local parts = { 'TYRES=' .. tostring(compoundIndex) }
  for _, sp in ipairs(spinners) do
    if not ignored[sp.name] then
      local value = sp.value
      if overrides and overrides[sp.name] ~= nil then value = overrides[sp.name] end
      parts[#parts + 1] = sp.name .. '=' .. tostring(value)
    end
  end
  return tostring(Util.hashString(table.concat(parts, ';')))
end

-- Composé monté (index CSP), lu en direct ; nil si illisible.
local function liveCompound()
  local ok, car = Util.call(Util.get(host.ac, 'getCar'), 0)
  local index = ok and Util.get(car, 'compoundIndex') or nil
  if type(index) == 'cdata' then index = tonumber(index) end
  if Util.isFinite(index) and index >= 0 and index == math.floor(index) then return index end
  return nil
end

-- Signature du setup du jeu, lue au passage de la ligne seulement, et sa famille (sans les réglages changés
-- en roulant, K.familyIgnored : vos temps par setup) ; nil si les crans sont illisibles.
local function liveSignature()
  local spinners = Datasource.readSpinners(host)
  if spinners == nil or #spinners == 0 then return nil end
  local compound = liveCompound()
  return signatureOf(spinners, nil, compound), signatureOf(spinners, nil, compound, K.familyIgnored)
end

-- Setups connus de la calibration : bornés (K.recorderMaxKnownSetups) ; le setup de la découverte et
-- le setup proposé ne sont jamais évincés, ni de cette liste, ni des meilleurs tours de l'enregistreur.
local function protectedSignatures()
  local list = {}
  if app.discovery and app.discovery.signature then list[app.discovery.signature] = true end
  for _, signature in pairs(app.proposals) do list[signature] = true end
  for _, signature in pairs(app.proposalOrigins) do list[signature] = true end
  return list
end

local function rememberSetup(signature, entry)
  if app.knownSetups[signature] == nil then app.knownOrder[#app.knownOrder + 1] = signature end
  app.knownSetups[signature] = entry
  local protected = protectedSignatures()
  app.recorder.protected = protected
  while #app.knownOrder > K.recorderMaxKnownSetups do
    local evicted = false
    for i, old in ipairs(app.knownOrder) do
      if not protected[old] then
        table.remove(app.knownOrder, i)
        app.knownSetups[old] = nil
        evicted = true
        break
      end
    end
    if not evicted then break end
  end
end

-- Setup physique (une seule définition pour la simulation, l'optimisation et la calibration) : crans
-- de la découverte plus écarts deltas, composé monté (ou slot, position dans d.carBase.compounds).
local function physicalSetup(d, deltas, slot)
  local setup = SetupSpace.apply(d.space, CarModel.defaultSetup(d.carBase), deltas or {})
  setup.compound = slot or d.compoundSlot or setup.compound
  return setup
end
app.physicalSetup = physicalSetup

-- Conditions de calcul (§11) : températures et grip de la session, grip de la chaussée.
local function conditionsOf(d)
  local v = d.session and d.session.values or {}
  local assists = d.session and d.session.assists or {}
  -- taux de consommation et d'usure de la session (1 = normal) : état de simulation, sinon assistances
  local function rate(simValue, assistValue)
    if Util.isFinite(simValue) and simValue >= 0 then return simValue end
    if Util.isFinite(assistValue) and assistValue >= 0 then return assistValue end
    return nil
  end
  -- échelle des taux non confirmée en jeu (le SDK annonce 0…1) : le taux de consommation ne réduit
  -- jamais la consommation du modèle (§0.6, prudence : jamais de panne sèche)
  local fuelRate = rate(v.fuelConsumptionRate, assists.fuelRate)
  return { airTemp = v.ambientTemperature, roadTemp = v.roadTemperature, roadGrip = v.roadGrip,
    surfaceGrip = d.trackModel and d.trackModel.surfaceGrip or 1,
    fuelRate = fuelRate and math.max(1, fuelRate) or nil, wearRate = rate(v.tyreConsumptionRate, assists.tyresWear) }
end

-- Tour simulé avec le setup actuel (§8.2, profil de vitesse du J3) ; mesure le temps de calcul d'une
-- évaluation, hors rendus de main, pour estimer la durée d'un calcul avant son lancement (A13).
local function simulateCurrent(d, ctx)
  local cpu, mark = 0, ctx.now()
  local function tick(weight)
    local now = ctx.now()
    if now and mark then cpu = cpu + (now - mark) end
    ctx.tick(weight)
    mark = ctx.now()
  end
  local setup = physicalSetup(d, nil)
  local eff, why = CarModel.configure(d.carBase, setup, d.conditions, tick)
  if eff == nil then return { reason = why } end
  local result, buf = Sim.run(d.trackModel, eff, nil, { tick = tick })
  local now = ctx.now()
  if now and mark then cpu = cpu + (now - mark) end
  local evalMs = ctx.now() and cpu * 1000 or nil
  -- coût avec le DRS (qualification : volet ouvert dans toutes les zones), pour le budget tenu en temps
  -- et la durée estimée (relecture J6b, m8 : sans lui, sous-estimée de moitié)
  local evalMsDrs = nil
  if d.drs and d.drs.enabled and evalMs then
    local conditions = {}
    for key, value in pairs(d.conditions) do conditions[key] = value end
    conditions.drs = true
    cpu, mark = 0, ctx.now()
    local effDrs = CarModel.configure(d.carBase, setup, conditions, tick)
    if effDrs then Sim.run(d.trackModel, effDrs, nil, { tick = tick }) end
    now = ctx.now()
    if now and mark then cpu = cpu + (now - mark) end
    evalMsDrs = effDrs and cpu * 1000 or nil
  end
  return {
    time = result.time, vMax = result.vMax, vMin = result.vMin, balance = result.balanceMean, fuel = result.fuel,
    profile = Optimizer.profile(d.trackModel, buf), evalMs = evalMs, evalMsDrs = evalMsDrs,
  }
end

-- DRS simulé (§8.9) : aile et EFFECT lisibles (drs.ini), annoncé par AC (drsPresent), zones sur le
-- circuit. Sinon, la raison.
local function drsStatus(d)
  local drs = d.carBase and d.carBase.drs
  if drs == nil then return { enabled = false, reason = 'pas de DRS (drs.ini sans section WING_n)' } end
  local out = { enabled = false, wing = drs.wing, effect = drs.effect, limitG = drs.limitG, notes = drs.notes }
  local zones = d.trackModel and #d.trackModel.drsZones or 0
  if not drs.usable then
    out.reason = drs.reason
  elseif d.carState.ok and d.carState.flags.drsPresent == false then
    out.reason = 'AC n\'annonce pas de DRS pour cette voiture (drsPresent)'
  elseif zones == 0 then
    out.reason = 'aucune zone DRS sur ce circuit'
  else
    out.enabled, out.zones = true, zones
  end
  return out
end

-- ERS simulé (§8.9) : ers.ini lisible et modélisé, ERS annoncé par AC (kersPresent) ; sinon la raison.
local function ersStatus(d)
  local ers = d.carBase and d.carBase.ers
  if ers == nil then return { enabled = false, reason = 'pas d\'ERS (ni ers.ini ni kers.ini)' } end
  if not ers.usable then return { enabled = false, reason = ers.reason, notes = ers.notes } end
  if d.carState.ok and d.carState.flags.kersPresent == false then
    return { enabled = false, reason = 'AC n\'annonce pas d\'ERS pour cette voiture (kersPresent)', notes = ers.notes }
  end
  return { enabled = true, notes = ers.notes }
end

local function discover(ctx)
  local d = { static = app.static, clockOk = app.clock ~= nil, clockReason = app.clockReason, writeTest = app.writeTest,
    loadTest = app.loadTest, loadVerified = app.loadVerified }
  d.session = Datasource.readSession(host)
  ctx.tick()
  d.car = Datasource.readCar(host, 0, ctx)
  d.fingerprint = Datasource.fingerprint(d.car, ctx.tick)
  d.carState = Datasource.readCarState(host, 0)
  ctx.tick()
  d.telemetry = Datasource.telemetryCheck(host, 0)
  ctx.tick()
  d.setup = Datasource.readSetup(host, ctx)
  local compoundIndex = d.carState.ok and d.carState.values.compoundIndex or nil
  if not (Util.isFinite(compoundIndex) and compoundIndex >= 0 and compoundIndex == math.floor(compoundIndex)) then
    compoundIndex = nil
  end
  d.compoundIndex = compoundIndex
  d.signature = signatureOf(d.setup.spinners, nil, compoundIndex)
  d.family = signatureOf(d.setup.spinners, nil, compoundIndex, K.familyIgnored)
  -- Modèle de voiture (paramètres de base) et espace de setup vérifié contre l'état du jeu (§10.3).
  -- D7 : une voiture inattendue ne doit pas faire perdre la découverte ni le rapport J0.
  if d.car then
    local okCar, why = pcall(function()
      -- rendus de main entre les étapes : modèle de voiture (DRS, ERS compris), espace de tous les crans
      d.carBase, d.carBaseMissing = CarModel.build(d.car, d.carState, ctx.tick)
      ctx.tick()
      d.space = SetupSpace.build({ setupIni = d.car.ini['setup.ini'], spinners = d.setup.spinners, ratios = d.car.ratios,
        tick = ctx.tick })
      ctx.tick()
      d.verifyRows = SetupSpace.verify(d.space, d.carState, d.carBase)
      ctx.tick()
      SetupSpace.attach(d.space, d.carBase)
      ctx.tick()
      -- repère de hauteur de l'aéro vérifié au stand : hauteur de caisse optimisable (recherche réduite)
      d.rideFrame = CarModel.verifyRideFrame(d.carBase, d.carState)
      local frame = d.rideFrame.status
      if frame == 'vérifié' or frame == 'corrigé' or frame == 'sans objet' then
        if frame == 'corrigé' then d.carBase.wingHeightOffset = d.rideFrame.offsets end
        SetupSpace.release(d.space, 'rod', SetupSpace.REDUCED, 'repère de hauteur de l\'aéro ' .. frame
          .. (frame == 'corrigé' and ' par la mesure au stand (à confirmer)' or ''))
      end
      d.optimizable = SetupSpace.optimizable(d.space)
      -- composé monté (D18) : retrouvé par son index CSP ; illisible -> composé par défaut, signalé
      if d.compoundIndex ~= nil then
        d.compoundSlot = CarModel.compoundSlot(d.carBase, d.compoundIndex)
        if d.compoundSlot == nil then
          d.compoundProblem = 'composé monté (index ' .. d.compoundIndex .. ') absent ou illisible dans tyres.ini'
        end
      else
        d.compoundAssumed = true
      end
    end)
    if not okCar then
      d.carBase, d.carBaseMissing, d.space, d.verifyRows, d.optimizable = nil, nil, nil, nil, nil
      d.carModelError = Util.truncate(tostring(why), 200)
      log('ERROR', 'car_model', d.carModelError)
    end
    ctx.tick()
  end
  d.trackFiles = Datasource.readTrackFiles(host, ctx)
  d.track = Datasource.sampleTrack(host, app.settings.ds, ctx)
  -- sans ligne IA : ligne reconstituée depuis un tour enregistré (reconnaissance, A14)
  if not d.track.ok and app.reconnaissance and app.reconnaissance.ok then d.track = app.reconnaissance end
  Datasource.probeBank(host, d.track, ctx)
  -- D7 : une erreur du modèle de circuit ne doit pas faire échouer toute la découverte.
  local okModel, model, why = pcall(TrackModel.build, d.track, d.trackFiles, app.settings.ds, ctx.tick)
  if okModel then
    d.trackModel, d.trackModelReason = model, why
  else
    d.trackModel, d.trackModelReason = nil, 'erreur du modèle de circuit : ' .. tostring(model)
  end
  d.raycast = Datasource.probeRaycast(host, 0)
  ctx.tick()
  d.drs = drsStatus(d)
  d.ers = ersStatus(d)
  d.store = { status = app.store.status, loaded = app.store.loaded, reason = app.store.reason }
  if d.trackModel and d.carBase and #d.carBaseMissing == 0 and d.space then
    d.conditions = conditionsOf(d)
    local okSim, sim = pcall(simulateCurrent, d, ctx)
    d.simCurrent = okSim and sim or { reason = 'erreur de simulation : ' .. tostring(sim) }
  end
  d.caps = Caps.evaluate(app.static, d)
  return d
end

-- Rapport J0 construit en tâche découpée (aucun travail long hors tranche).
local function scheduleReport(d)
  local date = app.context and app.context.systemTime and Util.formatDate(app.context.systemTime) or '—'
  local stats = app.scheduler.stats
  local info = {
    appVersion = Config.version, milestone = Config.milestone, date = date, updateSource = app.updateSource,
    perf = {
      slices = stats.slices, maxSliceMs = stats.maxSliceMs, maxUnitMs = stats.maxUnitMs,
      slowSlices = app.perf.slowSlices, avgMs = app.perf.avgMs, clock = app.clock ~= nil,
    },
  }
  local entries = Util.logEntries(app.log)
  Util.schedulerAdd(app.scheduler, 'report', function(ctx)
    local text, truncated = Caps.buildReport(info, d, entries, ctx.tick)
    return { text = text, truncated = truncated }
  end, function(ok, result)
    if ok and app.discovery == d then
      app.report, app.reportTruncated = result.text, result.truncated
    elseif not ok and result ~= 'cancelled' then
      log('ERROR', 'report', result)
    end
  end)
end

-- Données d'une séance précédente (§13), validées et datées : calibration du composé monté (piste à
-- K.storeCalTempTol près), rugosité de la piste, derniers setups enregistrés.
-- Réglages de suspension libérés par la rugosité mesurée (H17) ; butées et course avant butée restent
-- conservées (H16 à confirmer).
local SUSPENSION_KINDS = { 'spring', 'heave', 'damperSlow', 'damperFast' }
-- Raison de ne pas reprendre une entrée stockée par une autre version du modèle ou pour d'autres fichiers
-- de la voiture (D9), ou nil.
local function staleReason(entry, d)
  if entry.model ~= K.modelVersion then return 'modèle de l\'app changé depuis' end
  if entry.data == nil or entry.data ~= d.fingerprint then return 'fichiers de la voiture changés depuis' end
  return nil
end

local function restoreCalibration(d, cal, index, bucket)
  for _, key in ipairs(Calibration.KEYS) do
    if cal[key] == nil then return 'incomplète' end
    -- producteur : une calibration utilisable n'a aucun facteur en butée (D11 : rien d'autre n'est cru)
    local b = K.calibBounds[key]
    if cal[key] <= b[1] + 1e-9 or cal[key] >= b[2] - 1e-9 then return 'facteur en butée' end
  end
  local stale = staleReason(cal, d)
  if stale then return stale end
  local road = d.conditions and d.conditions.roadTemp
  if not Util.isFinite(cal.roadTemp) then return 'température de piste inconnue' end
  if Util.isFinite(road) and math.abs(cal.roadTemp - road) > K.storeCalTempTol then
    return 'piste à ' .. Util.fmt(cal.roadTemp, 0) .. ' °C contre ' .. Util.fmt(road, 0) .. ' °C aujourd\'hui'
  end
  local factors, identified = {}, {}
  for _, key in ipairs(Calibration.KEYS) do factors[key], identified[key] = cal[key], cal['id_' .. key] == true end
  local key = calKey(index, bucket)
  app.calibrations[key] = { state = 'done', compoundIndex = index, bucket = bucket, runs = 0, result = { factors = factors,
    usable = true, stored = true, storedAt = cal.stamp, atBound = {}, identified = identified, runs = {},
    compoundIndex = index } }
  if bucket == app.wet.state then app.calibration = app.calibrations[key] end
  return nil
end

local function restoreRoughness(d, rough)
  local stale = staleReason(rough, d)
  if stale then return stale end
  if not (rough.G0 and rough.G0 > 0 and rough.front and rough.front > 0 and rough.rear and rough.rear > 0) then
    return 'incomplète'
  end
  if math.max(rough.front, rough.rear) / math.min(rough.front, rough.rear) > K.roughConsistency then
    return 'avant et arrière incohérents'
  end
  d.conditions.roughness = rough.G0
  app.roughness = { G0 = rough.G0, front = rough.front, rear = rough.rear, speed = rough.speed, consistent = true,
    stored = true }
  for _, kind in ipairs(SUSPENSION_KINDS) do
    SetupSpace.release(d.space, kind, SetupSpace.REDUCED, 'rugosité mesurée lors d\'une séance précédente')
  end
  d.optimizable = SetupSpace.optimizable(d.space)
  return nil
end

-- Fichier renommé (meilleur tour dans le nom) avant que CSP n'écrive le stockage (AC quitté juste après, relecture
-- du 22/10/2026) : retrouvé par son nom sans temps au tour et, si connue, l'empreinte de son contenu. Renvoie le
-- nouveau nom et le contenu, ou nil.
local function findRenamed(folder, name, hash)
  local ok, list = Util.call(Util.get(host.io, 'scanDir'), folder, '*.ini')
  if not (ok and type(list) == 'table') then return nil end
  local root = Util.fileRoot(name)
  for i = 1, math.min(#list, K.scanMaxFiles) do
    local candidate = list[i]
    if type(candidate) == 'string' and candidate ~= name and Util.fileRoot(candidate) == root then
      if hash == nil then return candidate, nil end
      local okL, text = Util.call(Util.get(host.io, 'load'), folder .. '/' .. candidate)
      if okL and type(text) == 'string' and Util.hashString(text) == hash then return candidate, text end
    end
  end
  return nil
end

local function restoreStored(d)
  local now = stamp()
  local index = d.compoundIndex or -1
  local notes = {}
  local cal = Store.get(app.store, storeKey('cal', d, index), now)
  if cal and app.calibrations[index] == nil then
    local why = restoreCalibration(d, cal, index, 'sec')
    if why then notes[#notes + 1] = 'calibration d\'une séance précédente ignorée (' .. why .. ')' end
  end
  -- calibration sur piste mouillée : clé à part (D16 amendé), même règle de température de piste
  local wetCal = Store.get(app.store, storeKey('calwet', d, index), now)
  if wetCal and app.calibrations[calKey(index, 'pluie')] == nil then
    local why = restoreCalibration(d, wetCal, index, 'pluie')
    if why then notes[#notes + 1] = 'calibration pluie d\'une séance précédente ignorée (' .. why .. ')' end
  end
  local rough = Store.get(app.store, storeKey('rough', d), now)
  if rough and d.conditions and d.space and not d.conditions.roughness then
    local why = restoreRoughness(d, rough)
    if why then notes[#notes + 1] = 'rugosité d\'une séance précédente ignorée (' .. why .. ')' end
  end
  app.storeNote = #notes > 0 and (table.concat(notes, ' ; ') .. '.') or nil
  if app.storeNote then
    app.storeNote = app.storeNote:sub(1, 1):upper() .. app.storeNote:sub(2)
    log('INFO', 'store', app.storeNote)
  end
  -- nombre de tours de la course saisi pour ce circuit
  local rlaps = Store.get(app.store, storeKey('rlaps', d), now)
  app.raceLaps = rlaps and rlaps.laps or nil
  app.lastSaved = {}
  local folder = Exporter.targetFolder(host)
  for _, kind in ipairs({ 'quali', 'race' }) do
    local last = Store.get(app.store, storeKey('last', d, kind), now)
    -- renommé depuis (meilleur tour dans le nom) : le nom affiché suit
    if last and last.file and folder then
      local okE, exists = Util.call(Util.get(host.io, 'fileExists'), folder .. '/' .. last.file)
      local renamed = okE and exists ~= true and findRenamed(folder, last.file, nil)
      if renamed then last.file = renamed end
    end
    app.lastSaved[kind] = last
  end
  if app.refreshMemory then app.refreshMemory() end
end

local function onDiscovered(ok, result, cpuMs)
  if ok then
    result.durationMs = cpuMs
    app.discovery = result
    app.discoveryState = 'done'
    -- setup physique de la découverte, conservé pour la calibration (même voiture, même circuit)
    if result.space and result.carBase and #result.carBaseMissing == 0 then
      local known = app.knownSetups[result.signature] or { label = 'setup de la découverte' }
      known.setup = physicalSetup(result, nil)
      known.compoundIndex = result.compoundIndex
      known.predicted = known.predicted or (result.simCurrent and result.simCurrent.time)
      rememberSetup(result.signature, known)
    end
    app.recorder.protected = protectedSignatures()
    if app.detectPins then app.detectPins(result) end
    restoreStored(result)
    scheduleReport(result)
    local counts = Caps.countByStatus(result.caps)
    log('INFO', 'discovery', 'Découverte terminée : ' .. counts.available .. ' disponibles, ' .. counts.pending
      .. ' à confirmer, ' .. counts.unavailable .. ' indisponibles')
    for _, entry in ipairs(result.caps.list) do
      if entry.status == Caps.UNAVAILABLE then log('WARN', 'cap_' .. entry.id, entry.label .. ' : ' .. entry.detail) end
    end
  elseif result == 'cancelled' then
    app.discoveryState = 'idle'
  else
    app.discoveryState = 'failed'
    app.discoveryError = Util.truncate(tostring(result), 200)
    log('ERROR', 'discovery', app.discoveryError)
  end
end

local function startDiscovery()
  Util.schedulerCancel(app.scheduler)
  app.discovery, app.report, app.discoveryError, app.quali, app.race = nil, nil, nil, nil, nil
  app.discoveryState = 'running'
  app.conditionsKey = app.context and app.context.conditionsKey or nil
  app.pendingSessionKey = nil
  Util.schedulerAdd(app.scheduler, 'discovery', discover, onDiscovered)
end

-- ---------------------------------------------------------------------------
-- Boucle (§5)
-- ---------------------------------------------------------------------------

-- Conditions d'un calcul : copie des conditions de la découverte, températures et adhérence de la piste
-- relues au lancement (valeurs finies seulement). Chaque calcul garde sa propre copie : un calcul en
-- cours ne change jamais de conditions (reproductibilité, §10.5).
local function computeConditions(d)
  local out = {}
  for key, value in pairs(d.conditions or {}) do out[key] = value end
  -- relues à l'instant du lancement (le contexte n'est relu qu'à 1 Hz)
  local c = Datasource.readContext(host)
  if not c.ok then c = app.context or {} end
  for _, key in ipairs({ 'airTemp', 'roadTemp', 'roadGrip' }) do
    if Util.isFinite(c[key]) then out[key] = c[key] end
  end
  -- état de la piste figé au lancement (hystérésis, D16 amendé) ; humidité et eau de la piste ; eau sous
  -- les pneus mesurée sur le dernier tour valide mouillé, sinon estimée par le modèle (H26)
  out.bucket = app.wet.state
  out.wetness = Util.isFinite(c.rainWetness) and Util.clamp(c.rainWetness, 0, 1) or nil
  out.water = Util.isFinite(c.rainWater) and Util.clamp(c.rainWater, 0, 1) or nil
  out.waterMm = nil
  local last = app.recorder.laps.last
  if out.bucket == 'pluie' and last and last.valid and last.bucket == 'pluie' and Util.isFinite(last.waterMm) then
    out.waterMm = last.waterMm
  end
  if out.bucket ~= 'pluie' then out.wetness, out.water = 0, 0 end
  return out
end

-- Écart des conditions de piste actuelles à celles d'un calcul (K.conditionsTempStep, K.conditionsGripStep) :
-- texte, ou nil s'il est en deçà.
local function conditionsDrift(ref)
  local c = app.context
  if not (ref and c) then return nil end
  if ref.bucket and ref.bucket ~= app.wet.state then
    return ref.bucket == 'pluie' and 'piste mouillée -> sèche' or 'piste sèche -> mouillée'
  end
  if ref.bucket == 'pluie' and Util.isFinite(ref.water) and Util.isFinite(c.rainWater)
      and math.abs(c.rainWater - ref.water) >= K.conditionsWaterStep - K.conditionsEps then
    return 'eau sur la piste ' .. Util.fmt(ref.water * 100, 0) .. ' -> ' .. Util.fmt(c.rainWater * 100, 0) .. ' %'
  end
  local function moved(key, step)
    return Util.isFinite(ref[key]) and Util.isFinite(c[key]) and math.abs(c[key] - ref[key]) >= step - K.conditionsEps
  end
  if moved('roadTemp', K.conditionsTempStep) then
    return 'piste ' .. Util.fmt(ref.roadTemp, 1) .. ' -> ' .. Util.fmt(c.roadTemp, 1) .. ' °C'
  end
  if moved('airTemp', K.conditionsTempStep) then
    return 'air ' .. Util.fmt(ref.airTemp, 1) .. ' -> ' .. Util.fmt(c.airTemp, 1) .. ' °C'
  end
  if moved('roadGrip', K.conditionsGripStep) then
    return 'adhérence ' .. Util.fmt(ref.roadGrip * 100, 1) .. ' -> ' .. Util.fmt(c.roadGrip * 100, 1) .. ' %'
  end
  return nil
end

local function refreshContext()
  local c = Datasource.readContext(host)
  -- voiture ou circuit illisible sur une seule relecture : pas de mode inerte (un calcul en cours serait
  -- annulé pour rien) ; les drapeaux en ligne et replay, eux, comptent dès la première relecture
  if not c.ok and c.identityOnly then
    app.identityMisses = app.identityMisses + 1
    if app.identityMisses < K.contextMissesInert then return end
  else
    app.identityMisses = 0
  end
  app.context = c
  local inert = nil
  if not c.ok then
    inert = 'Contexte illisible : ' .. tostring(c.reason)
  elseif c.online then
    inert = 'Session en ligne : SetupLab est inactif.'
  elseif c.replay then
    inert = 'Replay : SetupLab est inactif.'
  end
  if inert ~= app.inert then
    app.inert = inert
    if inert then
      Util.schedulerCancel(app.scheduler)
      app.pendingComputes = {}
      log('INFO', 'inert', inert)
    end
  end
  if inert then return end
  -- état de la piste (D16 amendé) : « pluie » dès K.wetEnter, « sec » sous K.wetExit seulement (hystérésis :
  -- une piste au seuil ne bascule pas d'un mode à l'autre à chaque relecture) ; hors de la clé de séance
  local level = math.max(c.rainWetness or 0, c.rainWater or 0, c.rainIntensity or 0)
  local wet = app.wet
  if wet.state ~= 'pluie' and level >= K.wetEnter then
    wet.state = 'pluie'
    log('INFO', 'wet', 'Piste mouillée : setups pluie (humidité ' .. Util.fmt((c.rainWetness or 0) * 100, 0) .. ' %, eau '
      .. Util.fmt((c.rainWater or 0) * 100, 0) .. ' %)')
  elseif wet.state == 'pluie' and level <= K.wetExit then
    wet.state = 'sec'
    log('INFO', 'wet', 'Piste sèche : setups secs')
  end
  wet.wetness, wet.water, wet.intensity = c.rainWetness, c.rainWater, c.rainIntensity
  app.liveConditions = { airTemp = c.airTemp, roadTemp = c.roadTemp, roadGrip = c.roadGrip, bucket = wet.state,
    wetness = c.rainWetness, water = c.rainWater }
  if c.key ~= app.contextKey then
    if app.contextKey then log('INFO', 'context', 'Voiture ou circuit changé : résultats périmés, nouvelle découverte') end
    app.contextKey = c.key
    app.recorder, app.knownSetups, app.proposals, app.calibration, app.reconnaissance = Recorder.new(), {}, {}, nil, nil
    app.measureOnly, app.knownOrder, app.reconnaissanceTries = nil, {}, 0
    app.calibrations, app.validations = {}, {}
    app.proposalOrigins, app.pendingComputes, app.saved, app.refine = {}, {}, {}, nil
    app.memory, app.memoryFiles = {}, {}
    app.loaded, app.pins = {}, { quali = {}, race = {} }
    app.loadArm, app.loadCheck, app.loadTest, app.loadVerified = nil, nil, nil, nil
    startDiscovery()
  elseif app.discoveryState == 'idle' then
    startDiscovery()
  elseif app.discoveryState == 'done' and app.report == nil and not Util.schedulerBusy(app.scheduler) then
    scheduleReport(app.discovery)
  end
  -- nouvelle séance (type, numéro) : nouvelle découverte, une fois la séance confirmée par deux
  -- relectures du contexte (aucune relance en boucle sur une valeur qui oscille) ; séance illisible :
  -- rien (la dernière lue reste la référence)
  if app.conditionsKey == nil then app.conditionsKey = c.conditionsKey end
  if app.discoveryState ~= 'running' and c.conditionsKey and c.conditionsKey ~= app.conditionsKey then
    if app.pendingSessionKey == c.conditionsKey then
      local lost = {}
      for _, kind in ipairs({ 'quali', 'race' }) do
        local q = app[kind]
        if q and (q.state == 'running' or q.state == 'done') then
          lost[#lost + 1] = (q.state == 'running' and 'calcul ' or 'résultat ') .. (kind == 'race' and 'course' or 'tour rapide')
        end
      end
      app.ui.message = 'Nouvelle séance : nouvelle découverte' .. (#lost > 0 and (' (effacés : ' .. table.concat(lost, ', ')
        .. ' ; les setups enregistrés restent chargeables)') or '') .. '.'
      log('INFO', 'session', app.ui.message)
      -- un chargement armé ne survit pas à un changement de séance
      app.loadArm = nil
      startDiscovery()
    else
      app.pendingSessionKey = c.conditionsKey
    end
  else
    app.pendingSessionKey = nil
  end
  -- résultats calculés dans d'autres conditions de piste : signalés, sans blocage (décision de Vincent
  -- du 20/10/2026) ; un calcul en cours va au bout et son résultat est signalé
  for _, kind in ipairs({ 'quali', 'race' }) do
    local q = app[kind]
    if q and q.conditions then
      local drift = conditionsDrift(q.conditions)
      if q.state == 'running' and drift then q.conditionsChanged = q.conditionsChanged or drift end
      q.stale = nil
      if q.state == 'done' and drift then
        q.stale = 'Calculé dans d\'autres conditions (' .. drift .. ') : recalculer pour les conditions actuelles.'
      elseif q.state == 'done' and q.conditionsChanged then
        q.stale = 'Conditions changées pendant le calcul (' .. q.conditionsChanged .. '), revenues depuis : résultat '
          .. 'valable pour les conditions actuelles.'
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Mesure et calibration (J5, §9)
-- ---------------------------------------------------------------------------

-- Lance la calibration sur le meilleur tour valide de chaque setup connu (§9.2, §14.1).
-- Calibration d'un composé (index CSP ; par défaut le composé monté à la découverte) : facteurs par
-- composé (§9.2), sur le meilleur tour de chaque setup connu monté avec ce composé.
-- bucket : état de la piste des tours (« sec » ou « pluie », l'état actuel par défaut) : jamais de tour
-- sec dans une calibration pluie, ni l'inverse (D16 amendé).
local function startCalibration(compoundIndex, bucket)
  local d = app.discovery
  if not (d and d.trackModel and d.carBase and d.carBaseMissing and #d.carBaseMissing == 0) then return false end
  if compoundIndex == nil then compoundIndex = d.compoundIndex end
  -- composé illisible : clé −1 (jamais d'index nil dans les tables)
  if compoundIndex == nil then compoundIndex = -1 end
  bucket = bucket or app.wet.state
  local key = calKey(compoundIndex, bucket)
  local signatures = {}
  for signature in pairs(app.knownSetups) do signatures[#signatures + 1] = signature end
  table.sort(signatures)
  -- ici, seulement le choix des tours (léger) ; profils mesurés et tampons sont préparés dans la
  -- tâche découpée (tri des échantillons, tampons de simulation : plusieurs ms sur la Nordschleife)
  local chosen = {}
  for _, signature in ipairs(signatures) do
    local known = app.knownSetups[signature]
    local lap = Recorder.best(app.recorder, signature, bucket)
    if lap and known.setup and (known.compoundIndex or -1) == compoundIndex then
      chosen[#chosen + 1] = { lap = lap, known = known, signature = signature }
    end
  end
  if #chosen == 0 then return false end
  Util.schedulerCancel(app.scheduler, 'calibration')
  local prior = app.calibrations[key]
  local c = { state = 'running', runs = #chosen, previous = prior and (prior.result or prior.previous),
    compoundIndex = compoundIndex, bucket = bucket }
  app.calibrations[key] = c
  app.calibration = c
  local track, base = d.trackModel, d.carBase
  Util.schedulerAdd(app.scheduler, 'calibration', function(ctx)
    local runs = {}
    for _, pair in ipairs(chosen) do
      local measured = Calibration.measured(track, pair.lap, ctx.tick)
      if measured then
        local conditions, fuel = Calibration.lapConditions(pair.lap)
        conditions.surfaceGrip = track.surfaceGrip
        conditions.roughness = d.conditions and d.conditions.roughness
        -- tour roulé avec l'ERS : simulé avec son déploiement relevé (sinon la puissance l'absorberait)
        if d.ers and d.ers.enabled and measured.ers then conditions.ersSpec = base.ers end
        local setup = {}
        for key, value in pairs(pair.known.setup) do setup[key] = value end
        if fuel then setup.fuel = fuel end
        runs[#runs + 1] = Calibration.newRun({ track = track, base = base, setup = setup, conditions = conditions,
          measured = measured, label = pair.known.label, signature = pair.signature })
        ctx.tick()
      end
    end
    if #runs == 0 then return nil end
    return Calibration.run(runs, ctx)
  end, function(ok, result)
    if app.calibrations[key] ~= c then return end
    if ok and result == nil then
      c.state, c.error = 'failed', 'aucun tour exploitable'
    elseif ok then
      result.compoundIndex = c.compoundIndex
      c.state, c.result, c.runs = 'done', result, #result.runs
      if result.usable then
        -- conditions des tours calibrés (moyenne), pas celles de la découverte : la piste a pu évoluer
        local function lapMean(key)
          local sum, count = 0, 0
          for _, pair in ipairs(chosen) do
            local value = pair.lap.conditions and pair.lap.conditions[key]
            if Util.isFinite(value) then sum, count = sum + value, count + 1 end
          end
          if count > 0 then return sum / count end
          return d.conditions and d.conditions[key]
        end
        local fields = { airTemp = lapMean('airTemp'), roadTemp = lapMean('roadTemp'),
          laps = #result.runs, data = d.fingerprint, model = K.modelVersion }
        for _, factor in ipairs(Calibration.KEYS) do
          fields[factor], fields['id_' .. factor] = result.factors[factor], result.identified[factor] == true
        end
        Store.put(app.store, storeKey(bucket == 'pluie' and 'calwet' or 'cal', d, compoundIndex), fields, stamp())
      end
      log('INFO', 'calibration', 'Calibration ' .. bucket .. ' sur ' .. c.runs .. ' tour(s) : ' .. (result.usable and 'utilisable' or
        ('non utilisée (' .. tostring(result.reason) .. ')')))
    elseif result == 'cancelled' then
      c.state = 'cancelled'
    else
      c.state, c.error = 'failed', Util.truncate(tostring(result), 200)
      log('ERROR', 'calibration', c.error)
    end
  end)
  return true
end

-- Facteurs utilisables par composé (index CSP -> facteurs) sur un état de piste (l'actuel par défaut) :
-- seulement les calibrations qui tiennent les seuils (§14.3) ; l'optimiseur applique ceux du composé qu'il
-- retient (§9.2).
local function usableFactors(bucket)
  bucket = bucket or app.wet.state
  local map = {}
  for _, c in pairs(app.calibrations) do
    local r = c.result or c.previous
    if r and r.usable and (c.bucket or 'sec') == bucket and c.compoundIndex ~= nil then map[c.compoundIndex] = r.factors end
  end
  return map
end
app.usableFactors = usableFactors

-- Rugosité de la piste (H17) mesurée sur un tour valide du setup de la découverte : ressorts, pilonnage,
-- amortisseurs, butées et course avant butée deviennent optimisables (recherche réduite) si l'avant et
-- l'arrière donnent des rugosités cohérentes.
local function measureRoughness(d, lap)
  if not (d.carBase and d.space and d.conditions and lap.loadSigma) then return end
  local setup = physicalSetup(d, nil)
  -- tâche découpée : une configuration complète ne tient pas dans la frame du passage de ligne
  Util.schedulerAdd(app.scheduler, 'roughness', function(ctx)
    return CarModel.roughness(d.carBase, setup, lap, d.conditions, ctx.tick)
  end, function(ok, r)
    if not ok or r == nil or app.discovery ~= d then return end
    app.roughness = r
    if not r.consistent then
      log('WARN', 'roughness', 'Rugosité incohérente entre l\'avant et l\'arrière : suspension conservée')
      return
    end
    d.conditions.roughness = r.G0
    for _, kind in ipairs(SUSPENSION_KINDS) do
      SetupSpace.release(d.space, kind, SetupSpace.REDUCED, 'rugosité mesurée sur un tour')
    end
    d.optimizable = SetupSpace.optimizable(d.space)
    Store.put(app.store, storeKey('rough', d), { G0 = r.G0, front = r.front, rear = r.rear, speed = r.speed,
      data = d.fingerprint, model = K.modelVersion }, stamp())
    log('INFO', 'roughness', 'Rugosité de la piste mesurée : suspension optimisable')
  end)
end

-- Validation du setup proposé (§14.1) : gain prévu par le modèle qui a servi à la décision (facteurs
-- utilisés par le calcul), dans les conditions mesurées de chacun des deux tours (carburant, pneus,
-- piste), contre le gain mesuré (temps officiels). Indépendante de la calibration, qui est par composé.
-- Validation en jeu (§14.1) du setup proposé de ce genre (quali, race) : gain prévu contre gain mesuré ;
-- verdict conforme à K.validateTolAbs / K.validateTolRel près, sinon écart (recalibrer).
local function startValidation(kind)
  local d = app.discovery
  local signature = app.proposals[kind]
  -- setup d'origine : celui à partir duquel le setup proposé a été calculé, même après un chargement et
  -- une nouvelle découverte sur le setup proposé
  local originSignature = app.proposalOrigins[kind]
  local proposed = signature and app.knownSetups[signature]
  local origin = originSignature and app.knownSetups[originSignature]
  -- tours du même état de piste que le calcul du setup proposé (jamais un tour sec contre un tour mouillé)
  local bucket = app.proposalBuckets[kind] or 'sec'
  local lapO = originSignature and Recorder.best(app.recorder, originSignature, bucket)
  local lapP = signature and Recorder.best(app.recorder, signature, bucket)
  if not (proposed and origin and lapO and lapP and d and d.trackModel and d.carBase and originSignature ~= signature) then
    return false
  end
  local v = { state = 'running', kind = kind }
  app.validations[kind] = v
  Util.schedulerCancel(app.scheduler, 'validation_' .. kind)
  local track, base = d.trackModel, d.carBase
  Util.schedulerAdd(app.scheduler, 'validation_' .. kind, function(ctx)
    local function predict(known, lap)
      local conditions, fuel = Calibration.lapConditions(lap)
      conditions.surfaceGrip = track.surfaceGrip
      conditions.roughness = d.conditions and d.conditions.roughness
      conditions.factors = proposed.factors
      local setup = {}
      for key, value in pairs(known.setup) do setup[key] = value end
      if fuel then setup.fuel = fuel end
      local measured = (d.ers and d.ers.enabled and lap.ersUsed) and Calibration.measured(track, lap, ctx.tick) or nil
      if measured and measured.ers then conditions.ersSpec = base.ers end
      local eff = CarModel.configure(base, setup, conditions, ctx.tick)
      if eff == nil then return nil end
      return Sim.run(track, eff, nil, { tick = ctx.tick, ersMask = measured and measured.ers }).time, setup.fuel
    end
    local tO, fuelO = predict(origin, lapO)
    local tP, fuelP = predict(proposed, lapP)
    if tO == nil or tP == nil then return nil end
    return { predicted = tO - tP, measured = lapO.time - lapP.time, fuelO = fuelO, fuelP = fuelP,
      calibrated = proposed.factors ~= nil, compoundChanged = origin.compoundIndex ~= proposed.compoundIndex }
  end, function(ok, result)
    if app.validations[kind] ~= v then return end
    if ok and result then
      for key, value in pairs(result) do v[key] = value end
      v.state = 'done'
      v.conforming, v.tolerance = Calibration.verdict(v.predicted, v.measured)
      log('INFO', 'validation', 'Validation ' .. kind .. ' : gain prévu ' .. Util.fmt(v.predicted, 3) .. ' s, mesuré '
        .. Util.fmt(v.measured, 3) .. ' s (' .. (v.conforming and 'conforme' or 'écart') .. ')')
    elseif result == 'cancelled' then
      v.state = 'cancelled'
    else
      v.state, v.error = 'failed', ok and 'setup non simulable' or Util.truncate(tostring(result), 200)
    end
  end)
  return true
end

-- Mode « mesure uniquement » (§9.4) : voiture dont les données sont illisibles. Modèle estimé sur le
-- tour (puissance, traînée, adhérence, appui, boîte), simulé pour comparaison. Sans les fichiers de
-- la voiture, aucun réglage n'est convertible en grandeur physique : pas d'optimisation (A18).
local function startMeasureOnly(lap)
  local d = app.discovery
  local c = lap.conditions or {}
  -- sur le meilleur tour seulement (§9.3 bis) : un tour plus lent sous-estimerait l'adhérence
  local current = app.measureOnly
  if current and current.lapTime and current.state ~= 'failed' and current.lapTime <= lap.time then return end
  local m = { state = 'running', lapTime = lap.time }
  app.measureOnly = m
  Util.schedulerCancel(app.scheduler, 'measure')
  Util.schedulerAdd(app.scheduler, 'measure', function(ctx)
    local e, why = Calibration.estimate(lap, { mass = lap.mass, airTemp = c.airTemp, track = d.trackModel }, ctx.tick)
    if e == nil then return { reason = why } end
    local base = Calibration.measuredBase(e, { cgHeight = lap.cgHeight })
    local eff = CarModel.configure(base, CarModel.defaultSetup(base), { airTemp = c.airTemp, roadGrip = c.roadGrip,
      surfaceGrip = d.trackModel.surfaceGrip }, ctx.tick)
    if eff == nil then return { estimate = e, reason = 'modèle estimé inutilisable' } end
    local result = Sim.run(d.trackModel, eff, nil, { tick = ctx.tick })
    return { estimate = e, simTime = result.time }
  end, function(ok, result)
    if app.measureOnly ~= m then return end
    if ok then
      m.state, m.estimate, m.simTime, m.reason = 'done', result.estimate, result.simTime, result.reason
      log('INFO', 'measure_only', 'Mode mesure uniquement : ' .. (result.reason or ('tour simulé ' .. Util.fmt(result.simTime, 3)
        .. ' s contre ' .. Util.fmt(lap.time, 3) .. ' s mesuré')))
    elseif result == 'cancelled' then
      m.state, m.reason = 'failed', 'estimation interrompue : elle reprendra au prochain tour valide'
    else
      m.state, m.reason = 'failed', Util.truncate(tostring(result), 200)
      log('ERROR', 'measure_only', m.reason)
    end
  end)
end

local function onLap(lap)
  log('INFO', 'lap', 'Tour enregistré : ' .. Util.fmt(lap.time, 3) .. ' s, ' .. (lap.valid and 'valide' or
    ('rejeté (' .. tostring(lap.reason) .. ')')))
  if not lap.valid then return end
  -- meilleur tour réel dans le nom des fichiers de qualification (renommés voiture arrêtée)
  if app.queueBestRename then app.queueBestRename(lap) end
  -- affinage : tours propres avec le même setup, comptés depuis la fin du dernier calcul ; version roulée
  local r = app.refine
  if r and r.active then
    -- minimum avant une proposition (décision de Vincent du 26/10/2026) : tours propres avec le setup en cours
    if lap.family ~= nil and lap.family == r.minFamily then
      r.minLaps = (r.minLaps or 0) + 1
    else
      r.minFamily, r.minLaps, r.minTime = lap.family, 1, lap.time or 0
    end
    if r.phase == 'tours' then
      local lapKey = Recorder.bestKey(lap.signature, lap.bucket)
      r.laps = lapKey == r.lapSignature and r.laps + 1 or 1
      r.lapSignature = lapKey
      -- un tour propre apporte des données : nouvel essai tout de suite après un refus
      if r.laps >= app.settings.refineLaps or r.retry then r.due, r.nextAt = true, nil end
    end
    for _, entry in ipairs(r.history) do
      if entry.version and entry.signature == lap.signature then r.driven = entry.version end
    end
  end
  local d = app.discovery
  -- sans ligne IA : premier tour valide -> reconnaissance du circuit, puis nouvelle découverte ;
  -- nouvelle tentative au tour suivant si elle échoue (K.reconnaissanceMaxTries au plus)
  local noLine = d and d.track and (not d.track.ok or d.track.source == 'reconnaissance')
  if noLine and d.trackModel == nil and app.reconnaissanceTries < K.reconnaissanceMaxTries then
    app.reconnaissanceTries = app.reconnaissanceTries + 1
    app.reconnaissance = Recorder.reconnaissance(lap, nil)
    log('INFO', 'reconnaissance', app.reconnaissance.ok and 'Circuit reconstitué depuis le tour enregistré (sans ligne IA)'
      or ('Reconnaissance impossible : ' .. tostring(app.reconnaissance.reason)))
    if app.reconnaissance.ok then startDiscovery() end
    return
  end
  -- circuit reconstitué : la progression d'AC est inexploitable, elle est refaite par les positions
  if d and d.trackModel and d.trackModel.source == 'reconnaissance' and Recorder.progressUnusable(lap) then
    local progress = Recorder.progressFromPositions(lap)
    if progress == nil then return end
    lap.p = progress
  end
  -- voiture illisible : mode « mesure uniquement » (§9.4)
  if d and d.trackModel and (d.carBase == nil or #(d.carBaseMissing or {}) > 0) then
    startMeasureOnly(lap)
    return
  end
  if app.knownSetups[lap.signature] == nil then
    app.ui.message = 'Tour valide avec un setup que l\'app ne connaît pas : relancer la découverte pour l\'utiliser.'
    return
  end
  -- rugosité de la piste : sur piste sèche seulement (l'eau change la charge des roues)
  if d and lap.signature == d.signature and lap.bucket == 'sec' then measureRoughness(d, lap) end
  if app.settings.calibrationAuto then startCalibration(app.knownSetups[lap.signature].compoundIndex, lap.bucket) end
  for kind, signature in pairs(app.proposals) do
    if (lap.signature == signature or lap.signature == app.proposalOrigins[kind])
        and lap.bucket == (app.proposalBuckets[kind] or 'sec') then
      startValidation(kind)
    end
  end
end

-- Enregistrement des tours : à chaque frame, lecture seule, très léger (§9.1).
local function recordFrame()
  local d = app.discovery
  local tm = d and d.trackModel
  local rc = app.recordContext
  -- la couverture se contrôle sur la progression de la ligne IA, absente en reconnaissance
  rc.trackLength = (tm and tm.source ~= 'reconnaissance') and tm.length or nil
  -- positions gardées seulement sans ligne IA (reconnaissance, puis progression des tours suivants)
  rc.keepPositions = d ~= nil and d.track ~= nil and (not d.track.ok or d.track.source == 'reconnaissance')
  rc.conditions = app.liveConditions
  if tm then rc.conditions.surfaceGrip = tm.surfaceGrip end
  -- aile mobile du DRS (mesure de son effet, H8), dès que drs.ini en désigne une
  rc.drsWing = d and d.drs and d.drs.wing or nil
  rc.ers = d ~= nil and d.ers ~= nil and d.ers.enabled == true
  local lap = Recorder.update(app.recorder, host, app.now, liveSignature, rc)
  if lap then onLap(lap) end
end

-- Mode inerte vu dès la frame (le contexte n'est relu qu'à 1 Hz) : en ligne ou en replay, rien n'est
-- enregistré et le tour en cours est abandonné.
local function inertNow(sim)
  if app.inert then return true end
  for _, guard in ipairs(Datasource.CONTEXT_GUARDS) do
    if Util.get(sim, guard.key) == true then return true end
  end
  return false
end

local function update(dt)
  if not app.settings.enabled then return end
  local frameStarted = app.clock and app.clock() or nil
  local okSim, sim = Util.call(Util.get(host.ac, 'getSim'))
  local simTime = okSim and Util.get(sim, 'time') or nil
  if Util.isFinite(simTime) then
    app.now = simTime / 1000
  elseif Util.isFinite(dt) and dt > 0 and dt <= K.dtMax then
    app.now = app.now + dt
  end
  if app.now >= app.nextContextAt then
    app.nextContextAt = app.now + K.contextPeriod
    refreshContext()
    if not app.inert then Store.flush(app.store) end
  end
  if okSim and not inertNow(sim) then
    app.recordContext.paused = Util.get(sim, 'isPaused') == true
    recordFrame()
  elseif app.recorder.state ~= 'attente' then
    Recorder.abort(app.recorder, 'mode inerte')
  end
  if app.auto and app.autoTick then app.autoTick() end
  if app.refine and app.refine.active then app.refineTick() end
  if #app.fileOps > 0 and app.fileOpsTick then
    local okF, errF = pcall(app.fileOpsTick)
    if not okF then
      app.perf.errors = app.perf.errors + 1
      log('ERROR', 'files', errF)
    end
  end
  if app.inert or not Util.schedulerBusy(app.scheduler) then return end
  if app.perf.skipNext then
    app.perf.guardSkips = app.perf.guardSkips + 1
    return
  end
  local budget = app.settings.sliceBudgetMs / 1000
  local quota = K.workQuotaFallback
  local fps = okSim and Util.get(sim, 'fps') or nil
  if Util.isFinite(fps) and fps > 0 and fps < K.fpsTarget then
    budget, quota = budget * K.slowFpsSliceFactor, math.max(1, math.floor(quota * K.slowFpsSliceFactor))
    app.perf.slowFrames = app.perf.slowFrames + 1
  end
  -- travail déjà fait dans cette frame (contexte, stockage, fin de tour) retiré de la tranche : la frame
  -- du passage de ligne reste dans son budget (§14.3). Le résultat ne dépend pas du découpage (Q11).
  if frameStarted then budget = math.max(K.sliceMinMs / 1000, budget - (app.clock() - frameStarted)) end
  local stats = app.scheduler.stats
  if Util.schedulerStep(app.scheduler, app.clock, budget, quota) and stats.lastSliceMs > K.sliceAlertMs then
    app.perf.slowSlices = app.perf.slowSlices + 1
  end
end

-- Capacités et rapport J0 refaits après un test d'écriture ou un chargement.
local function refreshCaps()
  local d = app.discovery
  if d and app.discoveryState == 'done' then
    d.writeTest, d.loadTest, d.loadVerified = app.writeTest, app.loadTest, app.loadVerified
    d.caps = Caps.evaluate(app.static, d)
    app.report = nil
    scheduleReport(d)
  end
end

-- Test d'écriture (D17), sur clic uniquement : copie exacte du setup courant dans un nouveau
-- fichier, relu après écriture. Le résultat met à jour la capacité et le rapport J0.
local function saveCopy()
  if app.inert then
    app.ui.message = 'Enregistrement impossible : ' .. app.inert
    return
  end
  local r = Exporter.saveCopy(host, app.context and app.context.systemTime or 0, nil, fileStamp())
  app.writeTest = r
  if r.ok then
    app.ui.message = 'Copie du setup enregistrée : ' .. r.path .. ' (' .. r.bytes .. ' octets, relue et identique).'
    log('INFO', 'write', 'Test d\'écriture réussi : ' .. r.path)
  else
    app.ui.message = 'Enregistrement impossible : ' .. tostring(r.reason)
    log('WARN', 'write', app.ui.message)
  end
  refreshCaps()
end

-- ---------------------------------------------------------------------------
-- Qualification (J4, §10.6)
-- ---------------------------------------------------------------------------

-- Raison pour laquelle le calcul ne peut pas être lancé, ou nil.
local function qualiBlocker()
  if app.inert then return app.inert end
  if app.discoveryState == 'failed' then
    return 'découverte en échec (' .. tostring(app.discoveryError) .. ') : cliquer « Relancer la découverte » ; si l\'échec '
      .. 'persiste, copier le rapport J0 (onglet Capacités)'
  end
  if app.discoveryState == 'running' then return 'découverte en cours' end
  if app.discoveryState ~= 'done' then return 'découverte en attente du contexte (voiture, circuit, séance)' end
  local d = app.discovery
  if d.trackModel == nil then return 'modèle du circuit indisponible (' .. tostring(d.trackModelReason) .. ')' end
  if d.carModelError then return 'modèle de la voiture en erreur (' .. d.carModelError .. ')' end
  if d.carBase == nil or #d.carBaseMissing > 0 then
    return 'modèle de la voiture incomplet (' .. table.concat(d.carBaseMissing or {}, ', ') .. ')'
  end
  if d.space == nil then return 'espace de setup indisponible' end
  if d.compoundProblem then return d.compoundProblem end
  if d.compoundAssumed then return 'composé monté illisible : relancer la découverte' end
  if d.simCurrent == nil or d.simCurrent.time == nil then
    return 'setup actuel non simulable (' .. tostring(d.simCurrent and d.simCurrent.reason) .. ')'
  end
  if #d.optimizable == 0 then return 'aucun réglage optimisable' end
  return nil
end
app.qualiBlocker = qualiBlocker

-- Setup de course (décision de Vincent du 26/10/2026) : « il faut attendre d'avoir fait un setup de qualification
-- avant, et le setup de course sera calculé sur le rythme sur le setup qui a déjà été fait en qualification et qui est
-- validé » ; « l'utilisateur devra saisir le nombre de tours ». Référence de tour rapide validée de ce circuit et de cet
-- état de piste (qualification, sinon essai), montée dans la voiture (vos tours avec elle donnent le rythme), nombre
-- de tours saisi (gardé par circuit). Renvoie la raison et l'action qui la lève ('qualif', 'load', 'laps'), ou nil.
local function raceReference()
  local bucket = app.wet and app.wet.state or 'sec'
  for _, group in ipairs({ 'qualif', 'essai' }) do
    local m = app.memory[group .. '|' .. bucket]
    if m and m.text and not m.problem then return m, group .. '|' .. bucket end
  end
  return nil, nil
end

local function raceBlocker()
  local m = raceReference()
  if m == nil then return 'valider d\'abord un setup de tour rapide (qualification) sur ce circuit', 'qualif' end
  -- monté dans la voiture : setup de la découverte, ou chargé et vérifié depuis (avant la nouvelle découverte)
  local d = app.discovery
  local loaded = false
  for _, l in pairs(app.loaded) do loaded = loaded or (l.name ~= nil and l.name == m.file) end
  if not (loaded or (d and d.family and m.family and d.family == m.family)) then
    return 'charger d\'abord le setup de qualification validé (' .. tostring(m.file) .. ') : la course part de lui', 'load'
  end
  if not (Util.isFinite(app.raceLaps) and app.raceLaps >= 1) then return 'saisir le nombre de tours de la course', 'laps' end
  return nil, nil
end
app.raceReference, app.raceBlocker = raceReference, raceBlocker

-- Premier réglage dont le cran du jeu diffère de celui de l'espace (setup changé depuis la découverte).
local function changedSetting(d)
  local live = Datasource.readSetup(host, Util.syncContext())
  local liveValues = {}
  for _, sp in ipairs(live.spinners) do liveValues[sp.name] = sp.value end
  for name, member in pairs(d.space.members) do
    if liveValues[name] ~= member.current then return name, live end
  end
  if liveCompound() ~= d.compoundIndex then return 'composé de pneus', live end
  return nil, live
end

-- Calculs de setup : qualification (J4) et course (J6), mêmes garde-fous, même enregistrement.
local COMPUTE = {
  quali = { label = 'tour rapide', budgetKey = 'optBudgetEvalsQ', prefix = Config.exportQualiPrefix,
    prepare = Optimizer.prepareQuali, run = Optimizer.runQuali },
  race = { label = 'course', budgetKey = 'optBudgetEvalsC', prefix = Config.exportRacePrefix,
    prepare = Optimizer.prepareRace, run = Optimizer.runRace },
}

-- Mesures pour la course (§8.7) : séances du week-end, taux d'usure et aspiration de la session, et,
-- sur le meilleur tour valide du setup de la découverte (même composé : la signature le contient),
-- consommation et km virtuels par tour.
local function raceMeasures(d, bucket)
  local session = d.session or {}
  -- consommation CSP relue au lancement : à la découverte, au stand, elle vaut souvent 0 (SDK)
  local live = Datasource.readCarState(host, 0)
  local m = {
    sessions = session.sessions, wearRate = d.conditions and d.conditions.wearRate,
    slipstream = session.assists and session.assists.slipstream,
    fuelPerLapCsp = live.ok and live.values.fuelPerLap or nil,
  }
  local lap = Recorder.best(app.recorder, d.signature, bucket)
  if lap then
    m.lapTimeMeasured = lap.time
    if lap.fuelStart and lap.fuelEnd and lap.fuelStart > lap.fuelEnd then m.fuelPerLapMeasured = lap.fuelStart - lap.fuelEnd end
    local dk = lap.tyreKmDelta
    if dk and dk[1] and dk[2] and dk[3] and dk[4] then m.kmPerLapF, m.kmPerLapR = (dk[1] + dk[2]) / 2, (dk[3] + dk[4]) / 2 end
  end
  return m
end

-- État mesuré des pneus (§8.6) : dernier tour valide du setup de la découverte (pneus les plus proches
-- d'un relais en cours), sinon son meilleur tour, sur le même état de piste ; nil sans tour.
local function tyreStateOf(d, bucket)
  local last = app.recorder.laps.last
  local lap = (last and last.valid and last.signature == d.signature and last.bucket == bucket) and last
    or Recorder.best(app.recorder, d.signature, bucket)
  if lap == nil then return nil end
  return CarModel.tyreState(d.carBase, d.compoundSlot, lap, physicalSetup(d, nil))
end

-- ABS actif selon le jeu (absMode > 0 ; 0 : désactivé), sinon nil (electronics.ini).
-- Coût mesuré d'une évaluation (ms) pour le calcul kind : avec le DRS en qualification s'il est simulé.
function app.evalCost(kind)
  local s = app.discovery and app.discovery.simCurrent
  if s == nil then return nil end
  if kind == 'quali' and s.evalMsDrs then return s.evalMsDrs end
  return s.evalMs
end

local function absActiveOf(d)
  local live = Datasource.readCarState(host, 0)
  local mode = live.ok and live.values.absMode or nil
  if Util.isFinite(mode) then return mode > 0 end
  local abs = d.session and d.session.assists and d.session.assists.abs
  if abs == 'off' then return false end
  if abs == 'on' then return true end
  return nil
end

-- fromPending : calcul lancé à la fin de la découverte qu'il attendait (pas de nouvelle relance).
local function startCompute(kind, fromPending)
  local spec = COMPUTE[kind]
  -- découverte en cours : le calcul la suit (décision de Vincent du 20/10/2026)
  if app.discoveryState == 'running' and not app.inert then
    app.pendingComputes[kind] = true
    app.ui.message = 'Calcul ' .. spec.label .. ' lancé dès la fin de la découverte.'
    return
  end
  local blocker = qualiBlocker()
  if blocker then
    app.ui.message = 'Calcul impossible : ' .. blocker
    return
  end
  local d = app.discovery
  local changed = changedSetting(d)
  if changed then
    if fromPending then
      app.ui.message = 'Setup encore modifié pendant la découverte (' .. changed .. ') : cliquer de nouveau sur Calculer.'
      return
    end
    -- setup modifié depuis la découverte : découverte relancée sur le setup en cours, puis calcul ; les
    -- calculs et résultats de l'ancien setup sont effacés (et dits)
    local lost = {}
    for _, other in ipairs({ 'quali', 'race' }) do
      local o = app[other]
      if o and o.state == 'running' then
        lost[#lost + 1] = 'calcul ' .. COMPUTE[other].label .. ' en cours interrompu'
      elseif o and o.state == 'done' and other ~= kind then
        lost[#lost + 1] = 'résultat ' .. COMPUTE[other].label .. ' de l\'ancien setup effacé'
      end
    end
    app.pendingComputes[kind] = true
    app.ui.message = 'Setup modifié depuis la découverte (' .. changed .. ') : découverte relancée, le calcul ' .. spec.label
      .. ' suivra' .. (#lost > 0 and (' ; ' .. table.concat(lost, ', ')) or '') .. '.'
    log('INFO', kind, app.ui.message)
    startDiscovery()
    return
  end
  if kind == 'race' then
    local why = raceBlocker()
    if why then
      app.ui.message = 'Calcul course impossible : ' .. why .. '.'
      return
    end
  end
  Util.schedulerCancel(app.scheduler, kind)
  local budget = app.settings[spec.budgetKey]
  local q = { kind = kind, state = 'running', discovery = d, opt = Optimizer.newState({ budget = budget }), budget = budget }
  app[kind] = q
  log('INFO', kind, 'Calcul ' .. spec.label .. ' lancé (' .. budget .. ' évaluations)')
  Util.schedulerAdd(app.scheduler, kind, function(ctx)
    -- tout l'état du calcul est pris au même instant, au démarrage de la tâche (elle peut attendre derrière
    -- un autre calcul ; aucune autre tâche ne tourne ensuite avant sa fin) : conditions du moment,
    -- rugosité et espace optimisable cohérents, facteurs, pneus, mesures de course, copie des réglages
    -- (reproductibilité, §10.5)
    local conditions = computeConditions(d)
    q.conditions = conditions
    local settings = {}
    for key, value in pairs(app.settings) do settings[key] = value end
    -- course : nombre de tours saisi pour ce circuit (garde de course)
    if kind == 'race' and Util.isFinite(app.raceLaps) then settings.raceLaps, settings.raceMinutes = app.raceLaps, 0 end
    -- aides au pilotage (règle pluie, D16 amendé) : niveaux du fichier de setup du calcul, aides du jeu
    local file = d.setup and d.setup.file
    local aids = SetupSpace.aidsPlan(d.carBase.aids, {
      ABS = file and Util.iniNumber(file, 'ABS', 'VALUE', nil) or nil,
      TRACTION_CONTROL = file and Util.iniNumber(file, 'TRACTION_CONTROL', 'VALUE', nil) or nil,
    }, settings.wetAidLevels, conditions.bucket == 'pluie')
    local assists = d.session and d.session.assists or {}
    if aids.TRACTION_CONTROL.to and assists.tractionControl == 'off' then
      aids.TRACTION_CONTROL.assistNote = 'antipatinage coupé dans les aides du jeu : le niveau du setup ne s\'applique pas'
    end
    if aids.ABS.to and assists.abs == 'off' then
      aids.ABS.assistNote = 'ABS coupé dans les aides du jeu : le niveau du setup ne s\'applique pas'
    end
    local absActive = absActiveOf(d)
    if aids.ABS.to and assists.abs ~= 'off' then absActive = aids.ABS.to > 0 end
    -- vos retouches au stand (décision de Vincent du 22/10/2026) : jamais changées par le calcul
    local pins = app.pins[kind] or {}
    local pinned, pinnedLabels = {}, {}
    for _, var in ipairs(d.space.vars) do
      for _, member in ipairs(var.members) do
        if pins[member.name] and not pinned[var.key] then
          pinned[var.key] = true
          pinnedLabels[#pinnedLabels + 1] = var.label
        end
      end
    end
    if pins.TYRES and (settings.compoundChoice or -1) < 0 then
      settings.compoundChoice = d.compoundIndex
      pinnedLabels[#pinnedLabels + 1] = 'composé de pneus'
    end
    q.pinned = pinnedLabels
    local args = {
      base = d.carBase, space = d.space, track = d.trackModel, conditions = conditions,
      settings = settings, fuelPerLap = d.carState.ok and d.carState.values.fuelPerLap or nil, budget = budget,
      compound = d.compoundSlot, compoundChoice = settings.compoundChoice, factorsByCompound = usableFactors(conditions.bucket),
      race = kind == 'race' and raceMeasures(d, conditions.bucket) or nil, drs = d.drs and d.drs.enabled,
      tyres = tyreStateOf(d, conditions.bucket),
      absActive = absActive, ers = d.ers and d.ers.enabled, pinned = pinned,
    }
    local trackCoarse = nil
    local coarseDs = math.min(K.trackAutoMaxDs, d.trackModel.ds * K.optCoarseDsFactor)
    -- recherche grossière seulement si son pas est nettement plus grand (Nordschleife : pas fin déjà au
    -- plafond, le tracé grossier coûterait autant sans donner de point sélectionnable)
    if coarseDs >= d.trackModel.ds * K.optCoarseMinRatio then
      trackCoarse = TrackModel.build(d.track, d.trackFiles, coarseDs, ctx.tick)
    end
    args.trackCoarse = trackCoarse
    local problem = spec.prepare(args)
    local result, why = spec.run(problem, ctx, q.opt)
    if result == nil then error(why, 0) end
    result.aids = aids
    return result
  end, function(ok, result, cpuMs)
    if app[kind] ~= q then return end
    if ok then
      q.state, q.result, q.cpuMs, q.doneAt = 'done', result, cpuMs, app.now
      log('INFO', kind, 'Calcul ' .. spec.label .. ' terminé : ' .. Util.fmt(result.timeCurrent, 3) .. ' -> '
        .. Util.fmt(result.timeProposed, 3) .. ' s (' .. result.evaluations .. ' évaluations, '
        .. Util.fmt(cpuMs and cpuMs / 1000, 1) .. ' s de calcul)')
    elseif result == 'cancelled' then
      q.state = 'cancelled'
    else
      q.state, q.error = 'failed', Util.truncate(tostring(result), 200)
      log('ERROR', kind, q.error)
    end
  end)
end

-- Setup proposé d'un calcul terminé, sans rien écrire : texte du fichier (setup du calcul et changements
-- proposés, composé, aides de la règle pluie), signature, état de piste, setup physique (calibration et
-- validation des tours roulés avec lui). Renvoie p, ou nil et la raison.
local function proposalOf(kind)
  local q = app[kind]
  if q == nil or q.state ~= 'done' then return nil, 'aucun setup ' .. COMPUTE[kind].label .. ' calculé' end
  local d = q.discovery
  local values, errors = SetupSpace.values(d.space, q.result.deltas, { fuel = true })
  local compound = q.result.compound
  -- composé (D18) : [TYRES] VALUE=index, seulement s'il change (section absente : refus explicite)
  if compound and compound.changed then values.TYRES = compound.index end
  -- setup du jeu changé depuis le calcul : dit, sans refus (crans illisibles : rien à dire)
  local changed, live = changedSetting(d)
  if #live.spinners == 0 then changed = nil end
  -- texte du setup illisible à la découverte : setup relu, seulement s'il est encore celui du calcul
  local base = d.setup.text
  if base == nil and not changed then base = live.text end
  local text, why = nil, errors
  if #errors == 0 then text, why = SetupSpace.render(base, values) end
  if text == nil then
    return nil, table.concat(why or {}, ' ; ') .. (changed and (' (setup du jeu changé depuis le calcul : ' .. changed .. ')') or '')
  end
  -- signature : crans du calcul et réglages proposés ; famille (vos temps)
  local signature = signatureOf(d.setup.spinners, values, compound and compound.index or d.compoundIndex)
  local family = signatureOf(d.setup.spinners, values, compound and compound.index or d.compoundIndex, K.familyIgnored)
  -- aides au pilotage (règle pluie) : sections facultatives, ignorées si absentes du fichier (jamais un refus)
  local aidValues = {}
  for section, e in pairs(q.result.aids or {}) do
    if e.to then aidValues[section] = e.to end
  end
  if next(aidValues) then text = SetupSpace.renderOptional(text, aidValues) end
  return { q = q, d = d, text = text, baseText = base, signature = signature, family = family, originFamily = d.family,
    changed = changed,
    bucket = q.conditions and q.conditions.bucket or 'sec',
    known = { label = 'setup proposé (' .. COMPUTE[kind].label .. ')', predicted = q.result.timeProposed,
      predictedFrom = q.result.timeCurrent, setup = physicalSetup(d, q.result.deltas, compound and compound.slot),
      compoundIndex = compound and compound.index, factors = q.result.factorsUsed } }
end

-- Enregistrement (D8, D17, §12.3) : nouveau fichier nommé, construit à partir du setup du calcul (texte
-- relu à la découverte) en ne remplaçant que les VALUE des réglages proposés. Constat de Vincent du
-- 21/10/2026 (« il ne fait rien du tout ») : l'enregistrement était refusé dès qu'un cran avait changé
-- depuis le calcul (répartition de freinage touchée au volant, carburant), avec un message en haut de la
-- fenêtre seulement. Désormais jamais refusé pour cela : le fichier est toujours le setup simulé, le
-- changement est dit ; enregistrable autant de fois que voulu (nouveau nom à chaque clic) ; l'issue
-- s'affiche aussi sous le bouton (q.saveStatus). Sans écriture possible : presse-papiers. Seulement sur un
-- clic (« Enregistrer ») : l'affinage n'enregistre qu'à la validation (décision de Vincent du 21/10/2026).
-- Renvoie 'saved' ou 'failed' (nil sans résultat).
local function saveResult(kind)
  local spec = COMPUTE[kind]
  local q = app[kind]
  if q == nil or q.state ~= 'done' then
    app.ui.message = 'Aucun setup ' .. spec.label .. ' calculé.'
    return nil
  end
  local function status(ok, text)
    q.saveStatus = { ok = ok, text = text }
  end
  if app.inert then
    app.ui.message = 'Enregistrement impossible : ' .. app.inert
    status(false, app.ui.message)
    return 'failed'
  end
  local p, why = proposalOf(kind)
  if p == nil then
    app.ui.message = 'Setup non enregistré : ' .. tostring(why)
    status(false, app.ui.message)
    log('WARN', kind .. '_save', app.ui.message)
    return 'failed'
  end
  local d, text, proposedSignature, bucket = p.d, p.text, p.signature, p.bucket
  local note = p.changed and (' Le setup du jeu a changé depuis le calcul (' .. p.changed .. ') : le fichier reprend le '
    .. 'setup du calcul, avec les changements proposés.') or ''
  -- nom choisi (demande de Vincent du 21/10/2026), sinon horodaté ; genre et pluie dans le nom (22/10/2026) ;
  -- jamais d'écrasement (-2, -3…)
  local custom = customName(kind)
  local name = fileBase(kind, bucket) .. (custom ~= '' and '' or ('_' .. fileStamp()))
  local r = Exporter.writeNew(host, name, text)
  -- texte écrit conservé : un chargement dans la voiture exige le fichier relu identique
  local hash = Util.hashString(text)
  if r.ok then
    r.text = text
    app.written[r.name] = hash
  end
  q.saved = r
  -- setup proposé connu : ses tours serviront à la validation et à la calibration (§14.1) ; un autre
  -- setup proposé, ou une autre origine, rend caduque la validation du précédent
  if app.proposals[kind] ~= proposedSignature or app.proposalOrigins[kind] ~= d.signature
      or (app.proposalBuckets[kind] or 'sec') ~= bucket then
    Util.schedulerCancel(app.scheduler, 'validation_' .. kind)
    app.validations[kind] = nil
  end
  app.proposals[kind] = proposedSignature
  app.proposalOrigins[kind] = d.signature
  app.proposalBuckets[kind] = bucket
  -- dernier fichier enregistré, chargeable même après une nouvelle séance (résultats effacés)
  app.saved[kind] = r.ok and { path = r.path, name = r.name, text = text, signature = proposedSignature, hash = hash,
    bucket = bucket, origin = d.signature, carId = d.car and d.car.id } or nil
  rememberSetup(proposedSignature, p.known)
  if r.ok then
    app.ui.message = 'Setup ' .. spec.label .. ' enregistré : ' .. r.path .. ' (relu et identique). Le setup actuel n\'est pas modifié.'
      .. note
    q.saveCount = (q.saveCount or 0) + 1
    status(true, 'Enregistré : ' .. r.name .. (q.saveCount > 1 and (' (' .. q.saveCount .. ' fichiers pour ce calcul)') or '')
      .. note)
    log('INFO', kind .. '_save', app.ui.message)
    local saved = { file = r.name, gain = (q.result.timeCurrent or 0) - (q.result.timeProposed or 0), time = q.result.timeProposed }
    Store.put(app.store, storeKey('last', d, kind), saved, stamp())
    app.lastSaved = app.lastSaved or {}
    app.lastSaved[kind] = saved
    -- même setup qu'une version de l'affinage ou que la référence en mémoire : le nouveau nom les suit
    -- (« renommer » : nouveau fichier, l'ancien reste, D8)
    local r2 = app.refine
    if r2 and r2.kind == kind then
      for _, e in ipairs(r2.history) do
        if e.signature == proposedSignature then
          e.file, e.path, e.text, e.hash, e.ownFile = r.name, r.path, text, hash, false
        end
      end
    end
    local m = app.memory[memoryGroup(kind) .. '|' .. bucket]
    if m and m.signature == proposedSignature then
      m.file, m.path, m.text, m.hash = r.name, r.path, text, hash
      memoryPut(m)
    end
    return 'saved'
  end
  local okC, copied = Util.call(Util.get(host.ac, 'setClipboardText'), text)
  local folder = Exporter.targetFolder(host)
  app.ui.message = 'Écriture impossible (' .. tostring(r.reason) .. ').'
    .. ((okC and copied ~= false) and (' Contenu copié dans le presse-papiers : le coller dans un fichier ' .. name
      .. '.ini' .. (folder and (' du dossier ' .. folder) or '') .. '.') or ' Copie dans le presse-papiers impossible.')
  status(false, app.ui.message)
  log('WARN', kind .. '_save', app.ui.message)
  return 'failed'
end

-- Chargement d'un setup enregistré dans la voiture (D8 amendé le 20/10/2026, décision de Vincent) :
-- seulement le dernier fichier qualification ou course écrit par SetupLab, au stand, voiture arrêtée,
-- menu de setup ouvert, en deux clics, après une copie de sauvegarde du setup en cours ; le setup
-- chargé est ensuite constaté section par section. Gardes revérifiées à l'armement, à chaque image
-- affichée tant que le chargement est armé, et à la confirmation. Renvoie la raison d'un refus, ou nil.
local function loadBlocker(kind)
  if not app.settings.enabled then return 'application désactivée' end
  local okS, sim = Util.call(Util.get(host.ac, 'getSim'))
  -- gardes de l'image (en ligne, replay), pas seulement celles du contexte relu à 1 Hz
  if not okS or inertNow(sim) then return app.inert or 'séance en ligne ou replay' end
  if app.loadCheck then return 'vérification du chargement précédent en cours' end
  local saved = app.saved[kind]
  if not (saved and saved.text and saved.signature == app.proposals[kind]) then
    return 'enregistrer d\'abord le setup ' .. COMPUTE[kind].label
  end
  local okC, car = Util.call(Util.get(host.ac, 'getCar'), 0)
  if not okC or Util.get(car, 'isInPit') ~= true then return 'voiture hors du stand' end
  local speed = Util.get(car, 'speedMs')
  if not Util.isFinite(speed) or math.abs(speed) * 3.6 > K.loadMaxSpeedKmh then return 'voiture en mouvement' end
  local okE, editable = Util.call(Util.get(host.ac, 'isSetupAvailableToEdit'))
  if not (okE and editable == true) then return 'setup non modifiable maintenant : ouvrir le menu de setup au stand' end
  -- setup imposé : refus aussi quand l'état est illisible
  if Util.get(sim, 'fixedSetup') ~= false then return 'setup imposé par la session (ou état illisible)' end
  local okI, carId = Util.call(Util.get(host.ac, 'getCarID'), 0)
  if not (okI and saved.carId and carId == saved.carId) then return 'voiture différente de celle du calcul' end
  return nil
end

-- Valeurs (VALUE) de chaque section d'un setup au format d'AC, hors [CAR] et [__EXT_PATCH] :
-- carburant et composé compris.
local function setupValues(text)
  local ini = Util.parseIni(text)
  local out = {}
  for name, section in pairs(ini.sections) do
    if name ~= 'CAR' and name ~= '__EXT_PATCH' and section.VALUE ~= nil then
      out[name] = Util.parseNumber(section.VALUE) or section.VALUE
    end
  end
  return out
end

-- Le setup en cours a-t-il toutes les valeurs du fichier ? Renvoie vrai, ou faux et la première section
-- différente (nil si le setup en cours est illisible).
local function liveHasValues(target)
  local ok, text = Util.call(Util.get(host.ac, 'stringifyCurrentSetup'), true, false)
  if not (ok and type(text) == 'string') then return false, nil end
  local live = setupValues(text)
  for name, value in pairs(target) do
    -- niveaux d'aide : les aides du jeu peuvent les remplacer, ils ne prouvent rien (règle pluie)
    if name ~= 'ABS' and name ~= 'TRACTION_CONTROL' and live[name] ~= value then return false, name end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Fichiers de SetupLab rangés (décision de Vincent du 22/10/2026 : « à partir du moment où on a validé la V1 ou
-- la V2 ou la V3, il faut qu'il ne reste que les fichiers V1, V2, V3, pas les intermédiaires » ; « le meilleur
-- temps réel qui a été effectué avec ce setup », qualification seulement). Seuls des fichiers que SetupLab a
-- écrits, prouvés par leur nom et l'empreinte de leur contenu, intacts : jamais vos fichiers, jamais un fichier
-- gardé (référence de la mémoire, figée ou non, versions validées, setup à charger). Corbeille de Windows
-- (io.recycle ; avant CSP 0.3, suppression définitive) et renommage (io.move, jamais d'écrasement) : un fichier
-- par image, voiture arrêtée, aucun chargement en cours (jamais d'à-coup en roulant).
-- ---------------------------------------------------------------------------

-- Fichiers gardés de ce circuit : référence de la mémoire, versions validées de l'affinage et référence
-- qu'elles ont remplacée ; kindFilter : 'quali' ou 'race' (tous sinon).
local function keptFiles(kindFilter)
  local list, seen = {}, {}
  local function add(rec, kind)
    if rec and rec.file and rec.text and rec.hash and not seen[rec.file] and app.written[rec.file] == rec.hash
        and (kindFilter == nil or kind == kindFilter) then
      seen[rec.file] = true
      list[#list + 1] = { name = rec.file, text = rec.text, hash = rec.hash, family = rec.family, bucket = rec.bucket,
        kind = kind }
    end
  end
  for _, m in pairs(app.memory) do
    if not m.problem then add(m, m.group == 'course' and 'race' or 'quali') end
  end
  local r = app.refine
  if r then
    for _, e in ipairs(r.history) do
      if e.version and e.status == 'validée' then
        add(e, r.kind)
        if e.replaced then add(e.replaced, e.replaced.group == 'course' and 'race' or 'quali') end
      end
    end
  end
  return list
end

local function isKept(name)
  for _, f in ipairs(keptFiles()) do
    if f.name == name then return true end
  end
  return false
end

-- Deux setups identiques, hors réglages changés en roulant (carburant, répartition de freinage) et aides (le jeu
-- peut les remplacer).
local SAME_IGNORED = { ABS = true, TRACTION_CONTROL = true }
local function sameSetup(a, b)
  for name, value in pairs(a) do
    if not (K.familyIgnored[name] or SAME_IGNORED[name]) then
      local other = b[name]
      if type(value) == 'number' and type(other) == 'number' then
        if math.abs(value - other) > 1e-9 then return false end
      elseif value ~= other then
        return false
      end
    end
  end
  for name in pairs(b) do
    if not (K.familyIgnored[name] or SAME_IGNORED[name]) and a[name] == nil then return false end
  end
  return true
end

-- Le setup en cours est-il déjà un fichier gardé de SetupLab, intact sur le disque ? Son nom, ou nil : une copie
-- de sauvegarde n'apporterait rien (réponse de Vincent : copie « seulement si utile »).
local function liveKeptFile()
  local ok, text = Util.call(Util.get(host.ac, 'stringifyCurrentSetup'), true, false)
  if not (ok and type(text) == 'string') then return nil end
  local folder = Exporter.targetFolder(host)
  if folder == nil then return nil end
  local live = setupValues(text)
  for _, f in ipairs(keptFiles()) do
    if sameSetup(live, setupValues(f.text)) then
      local okL, back = Util.call(Util.get(host.io, 'load'), folder .. '/' .. f.name)
      if okL and back == f.text then return f.name end
    end
  end
  return nil
end

local function queueFileOp(op)
  for _, o in ipairs(app.fileOps) do
    if o.op == op.op and o.name == op.name then
      if op.time and (o.time == nil or op.time < o.time) then o.time = op.time end
      return
    end
  end
  if #app.fileOps < K.fileOpsMax then app.fileOps[#app.fileOps + 1] = op end
end

-- Validation : les copies « Avant chargement » de ce lancement identiques à un fichier gardé partent à la
-- Corbeille ; une copie qui contient autre chose (vos retouches non enregistrées) reste.
local function queueBackupCleanup()
  local kept = keptFiles()
  for _, f in ipairs(kept) do f.values = setupValues(f.text) end
  for _, b in ipairs(app.backups) do
    if not b.queued then
      for _, f in ipairs(kept) do
        if f.name ~= b.name and sameSetup(b.values, f.values) then
          b.queued = true
          queueFileOp({ op = 'corbeille', name = b.name, hash = b.hash, dupOf = f.name, why = 'copie identique à ' .. f.name })
          break
        end
      end
    end
  end
end

-- Meilleur tour réel dans le nom des fichiers gardés de tour rapide de la même famille de setup et du même état
-- de piste, quand il bat le temps déjà dans le nom (renommés voiture arrêtée).
local function queueBestRename(lap)
  if not (lap and lap.valid and lap.family) then return end
  local f = app.recorder.laps.family[Recorder.bestKey(lap.family, lap.bucket)]
  if not (f and Util.isFinite(f.best) and f.best > 0) then return end
  for _, k in ipairs(keptFiles('quali')) do
    if k.family == lap.family and (k.bucket or 'sec') == lap.bucket then
      local named = Util.lapFromFileName(k.name)
      if named == nil or f.best < named - 0.0005 then
        queueFileOp({ op = 'nom', name = k.name, hash = k.hash, time = f.best })
      end
    end
  end
end
app.queueBestRename, app.queueFileOp, app.setupValues = queueBestRename, queueFileOp, setupValues

-- Un fichier parti à la Corbeille : plus rien ne le désigne.
local function forgetFile(name)
  app.written[name] = nil
  for i = #app.backups, 1, -1 do
    if app.backups[i].name == name then table.remove(app.backups, i) end
  end
  local r = app.refine
  if r then
    for _, e in ipairs(r.history) do
      if e.file == name then e.file, e.path, e.recycled = nil, nil, true end
    end
  end
  for kind, last in pairs(app.lastSaved or {}) do
    if last and last.file == name then
      app.lastSaved[kind] = nil
      local key = storeKey('last', app.discovery, kind)
      if key then Store.remove(app.store, key) end
    end
  end
  for path in pairs(app.memoryFiles) do
    if path:sub(-#name - 1) == '/' .. name then app.memoryFiles[path] = nil end
  end
end

-- Un fichier renommé : tout ce qui le désignait suit (versions, mémoire, setup à charger, setup chargé).
local function followRename(old, new, path)
  app.written[new], app.written[old] = app.written[old], nil
  local function move(rec)
    if rec and rec.file == old then rec.file, rec.path = new, path end
  end
  local r = app.refine
  if r then
    for _, e in ipairs(r.history) do
      move(e)
      move(e.replaced)
    end
  end
  for _, m in pairs(app.memory) do
    if m.file == old then
      move(m)
      memoryPut(m)
    end
  end
  for _, saved in pairs(app.saved) do
    if saved.name == old then saved.name, saved.path = new, path end
  end
  for _, loaded in pairs(app.loaded) do
    if loaded.name == old then loaded.name = new end
  end
  for kind, last in pairs(app.lastSaved or {}) do
    if last and last.file == old then
      last.file = new
      local key = storeKey('last', app.discovery, kind)
      if key then Store.put(app.store, key, last, stamp()) end
    end
  end
  for oldPath, cached in pairs(app.memoryFiles) do
    if oldPath:sub(-#old - 1) == '/' .. old then
      app.memoryFiles[oldPath] = nil
      app.memoryFiles[path] = cached
      break
    end
  end
end

local function runFileOp(op)
  -- garde revérifiée au moment d'agir : un fichier devenu gardé (ou à charger) ne part pas ; une copie ne part
  -- que si le fichier qu'elle double est toujours gardé ; seul un fichier gardé est renommé
  if op.op == 'corbeille' then
    -- seulement un fichier écrit par SetupLab pendant ce lancement (version, copie de sauvegarde), même empreinte
    local own = app.written[op.name] ~= nil and app.written[op.name] == op.hash
    for _, b in ipairs(app.backups) do own = own or (b.name == op.name and b.hash == op.hash) end
    local target = false
    for _, saved in pairs(app.saved) do target = target or saved.name == op.name end
    if not own or target or isKept(op.name) or (op.dupOf and not isKept(op.dupOf)) then return end
    local w = Exporter.recycleOwn(host, op.name, op.hash)
    if not w.ok then
      log('INFO', 'files', op.name .. ' laissé tel quel : ' .. tostring(w.reason) .. '.')
      return
    end
    forgetFile(op.name)
    app.filesNote = 'Rangé : ' .. op.name .. ' à la Corbeille (' .. tostring(op.why) .. ').'
  else
    local base = isKept(op.name) and Util.withLapTime(op.name, op.time)
    if not base then return end
    local w = Exporter.renameOwn(host, op.name, op.hash, base)
    if not w.ok then
      log('INFO', 'files', op.name .. ' non renommé : ' .. tostring(w.reason) .. '.')
      return
    end
    followRename(op.name, w.name, w.path)
    app.filesNote = 'Renommé avec votre meilleur tour : ' .. w.name .. '.'
  end
  log('INFO', 'files', app.filesNote)
end

-- À chaque image : un rangement au plus, voiture arrêtée, sans chargement armé ni en cours.
local function fileOpsTick()
  if #app.fileOps == 0 or app.inert or app.loadArm or app.loadCheck or app.perf.skipNext then return end
  local okC, car = Util.call(Util.get(host.ac, 'getCar'), 0)
  local speed = okC and Util.get(car, 'speedMs') or nil
  if not (Util.isFinite(speed) and math.abs(speed) * 3.6 <= K.loadMaxSpeedKmh) then return end
  runFileOp(table.remove(app.fileOps, 1))
end
app.fileOpsTick = fileOpsTick

-- Mémoire du circuit relue à chaque découverte (nouvelle séance, voiture ou circuit) : chaque fichier est
-- relu et comparé à son empreinte ; absent ou modifié : dit, jamais chargé. Sans clé stockable (identifiants
-- refusés) : la mémoire de la séance reste telle quelle. Un fichier est relu au plus toutes les
-- K.memoryRecheck secondes (sur la DTM, une découverte par calcul : six fichiers relus à chaque fois
-- coûteraient ~2 ms sur l'image de fin de découverte) ; le chargement, lui, revérifie toujours le contenu
-- exact (Exporter.loadBlocker).
local function refreshMemory()
  local d = app.discovery
  if not (d and d.setup) then return end
  local folder = Exporter.targetFolder(host)
  for _, g in ipairs(Config.memoryGroups) do
    for _, bucket in ipairs({ 'sec', 'pluie' }) do
      local key = storeKey('mem', d, g.key, bucket)
      local e = key and Store.get(app.store, key, stamp())
      if e and e.file and e.hash then
        local m = { group = g.key, bucket = bucket, file = e.file, hash = e.hash, version = e.version, gain = e.gain,
          time = e.time, locked = e.locked == true, carId = d.car and d.car.id }
        local path = folder and (folder .. '/' .. e.file)
        local cached = path and app.memoryFiles[path]
        local ok, text = false, nil
        if cached and cached.hash == e.hash and app.now - cached.at < K.memoryRecheck then
          ok, text = true, cached.text
        elseif path then
          ok, text = Util.call(Util.get(host.io, 'load'), path)
          if not (ok and type(text) == 'string') then
            local renamed, renamedText = findRenamed(folder, e.file, e.hash)
            if renamed then
              log('INFO', 'memory', 'Fichier de la mémoire retrouvé sous son nouveau nom : ' .. renamed)
              e.file, m.file, m.adopted = renamed, renamed, true
              path, ok, text = folder .. '/' .. renamed, true, renamedText
            end
          end
        end
        if folder == nil then
          m.problem = 'dossier des setups inconnu'
        elseif not (ok and type(text) == 'string') then
          m.problem = 'fichier introuvable'
        elseif Util.hashString(text) ~= e.hash then
          m.problem = 'fichier modifié depuis sa validation'
        elseif cached and cached.text == text then
          m.path, m.text, m.signature, m.family = path, text, cached.signature, cached.family
          app.written[e.file] = e.hash
        else
          local values = setupValues(text)
          m.path, m.text = path, text
          local tyres = Util.isFinite(values.TYRES) and values.TYRES or d.compoundIndex
          m.signature = signatureOf(d.setup.spinners, values, tyres)
          m.family = signatureOf(d.setup.spinners, values, tyres, K.familyIgnored)
          app.written[e.file] = e.hash
          app.memoryFiles[path] = { hash = e.hash, text = text, signature = m.signature, family = m.family, at = app.now }
        end
        app.memory[g.key .. '|' .. bucket] = m
        if m.adopted and m.problem == nil then
          m.adopted = nil
          memoryPut(m)
        end
      elseif key then
        app.memory[g.key .. '|' .. bucket] = nil
      end
    end
  end
end
app.refreshMemory = refreshMemory

-- Setup à charger d'un genre : un setup enregistré (version de l'affinage, setup de la mémoire). Tout change
-- ensemble (fichier, setup proposé, origine, état de piste) : le chargement et la validation (§14.1) restent
-- d'accord ; une autre cible annule la validation en cours et désarme le chargement.
local function setLoadTarget(kind, rec)
  if app.proposals[kind] ~= rec.signature then
    Util.schedulerCancel(app.scheduler, 'validation_' .. kind)
    app.validations[kind] = nil
  end
  local d = app.discovery
  app.saved[kind] = { path = rec.path, name = rec.file, text = rec.text, signature = rec.signature, hash = rec.hash,
    bucket = rec.bucket, origin = rec.origin, carId = rec.carId or (d and d.car and d.car.id) }
  app.proposals[kind], app.proposalOrigins[kind], app.proposalBuckets[kind] = rec.signature, rec.origin, rec.bucket
  if app.loadArm and app.loadArm.kind == kind then app.loadArm = nil end
end

local function armLoad(kind, where)
  local why = loadBlocker(kind) or Exporter.loadBlocker(host, app.saved[kind].path, app.saved[kind].text, app.written)
  if why then
    app.loadArm = nil
    app.ui.message = 'Chargement impossible : ' .. why .. '.'
    -- dit aussi sous le bouton (constat de Vincent du 22/10/2026 : le message du haut n'est pas vu)
    app.loadNote = { kind = kind, text = app.ui.message }
    return
  end
  app.loadNote = nil
  local now = app.clock and app.clock() or nil
  app.loadArm = { kind = kind, path = app.saved[kind].path, signature = app.saved[kind].signature,
    minClock = now and (now + K.loadConfirmMinSeconds), untilClock = now and (now + K.loadConfirmSeconds),
    untilNow = app.now + K.loadConfirmSeconds, frames = 0 }
  -- confirmation et suivi là où le chargement a été demandé (résultat, affinage, ou mémoire du circuit)
  app.loadWhere = where or 'result'
  app.ui.message = 'Confirmer le chargement dans les ' .. K.loadConfirmSeconds .. ' s : il remplace le setup en cours dans '
    .. 'la voiture (modifications non enregistrées comprises) ; une copie du setup actuel est enregistrée juste avant.'
end

local function confirmLoad(kind)
  local arm = app.loadArm
  local saved = app.saved[kind]
  if not (arm and arm.kind == kind and saved and saved.path == arm.path and app.proposals[kind] == arm.signature) then
    app.loadArm = nil
    app.ui.message = 'Chargement non armé : cliquer d\'abord « Charger le setup ' .. COMPUTE[kind].label .. ' dans la voiture ».'
    return
  end
  -- délai minimal : un double-clic ne vaut pas confirmation (le chargement reste armé)
  if (arm.minClock and app.clock and app.clock() < arm.minClock) or (arm.minClock == nil and arm.frames < K.loadConfirmMinFrames) then
    app.ui.message = 'Confirmation trop rapide : lire l\'avertissement, puis confirmer.'
    return
  end
  app.loadArm = nil
  local why = loadBlocker(kind) or Exporter.loadBlocker(host, saved.path, saved.text, app.written)
  if why then
    app.ui.message = 'Chargement impossible : ' .. why .. '.'
    app.loadNote = { kind = kind, text = app.ui.message }
    return
  end
  local target = setupValues(saved.text)
  -- état d'avant l'appel : un setup déjà identique au fichier ne prouve rien (constat non concluant)
  local already = liveHasValues(target)
  -- copie de sauvegarde du setup en cours (nouveau fichier, relu) : le chargement reste réversible ; inutile
  -- quand la voiture roule avec un fichier gardé de SetupLab, intact (réponse de Vincent du 22/10/2026)
  local kept = liveKeptFile()
  local backupNote
  if kept then
    backupNote = 'setup précédent déjà enregistré : ' .. kept
    app.backupsSkipped = (app.backupsSkipped or 0) + 1
  else
    local backup = Exporter.saveCopy(host, app.context and app.context.systemTime or 0, Config.exportBackupPrefix, fileStamp())
    app.writeTest = backup
    if not backup.ok then
      app.ui.message = 'Chargement annulé : copie de sauvegarde du setup en cours impossible (' .. tostring(backup.reason) .. ').'
      log('WARN', 'load', app.ui.message)
      refreshCaps()
      return
    end
    if #app.backups >= K.backupsMax then table.remove(app.backups, 1) end
    app.backups[#app.backups + 1] = { name = backup.name, hash = Util.hashString(backup.text), values = setupValues(backup.text) }
    backupNote = 'setup précédent sauvegardé : ' .. backup.name
  end
  local r = Exporter.loadIntoCar(host, saved.path, saved.text, app.written)
  if not r.ok then
    -- issue de ac.loadSetup (capacité) seulement si la fonction a été appelée
    if r.called then app.loadTest = { ok = false, kind = kind, path = saved.path, reason = r.reason } end
    app.ui.message = 'Chargement impossible : ' .. tostring(r.reason) .. ' (' .. backupNote .. ').'
    app.loadNote = { kind = kind, text = app.ui.message }
    log('WARN', 'load', app.ui.message)
    refreshCaps()
    return
  end
  app.loadCheck = { kind = kind, path = saved.path, target = target, already = already, frames = K.loadVerifyFrames,
    backup = backupNote }
  app.ui.message = 'Chargement demandé : vérification du setup en cours…'
  log('INFO', 'load', 'ac.loadSetup accepté : ' .. saved.path .. ' ; ' .. backupNote)
end

-- À chaque image affichée : échéance et gardes du chargement armé ; constat du setup chargé.
-- Vos retouches (décision de Vincent du 22/10/2026 : « s'il a calculé un setup, que je l'ai chargé et que je
-- reviens dans les stands et que je modifie un petit peu le setup, il faut qu'il le prenne en compte ») : à
-- chaque découverte, un cran différent du dernier setup chargé par SetupLab est une retouche du pilote ; il est
-- gardé (à sa valeur dans la voiture) par les calculs suivants de ce genre, jusqu'à « Libérer vos retouches ».
-- Le carburant n'en est pas une (K.signatureIgnored).
local function detectPins(d)
  if not (d and d.setup and d.space) then return end
  for kind, loaded in pairs(app.loaded) do
    local pins = app.pins[kind]
    for _, sp in ipairs(d.setup.spinners) do
      if d.space.members[sp.name] and not K.signatureIgnored[sp.name] then
        local want = loaded.values[sp.name]
        if pins[sp.name] then
          pins[sp.name].value = sp.value
        elseif type(want) == 'number' and math.abs(sp.value - want) > K.setupValueTol then
          pins[sp.name] = { value = sp.value, from = want }
          log('INFO', 'pins', 'Retouche gardée (' .. kind .. ') : ' .. sp.name .. ' ' .. tostring(want) .. ' -> ' .. tostring(sp.value))
        end
      end
    end
    local tyres = loaded.values.TYRES
    if pins.TYRES == nil and type(tyres) == 'number' and d.compoundIndex and tyres ~= d.compoundIndex then
      pins.TYRES = { value = d.compoundIndex, from = tyres }
    end
  end
end
app.detectPins = detectPins

-- État du stand pour le chargement, montré à côté du bouton « Charger » : au stand, voiture arrêtée, menu de
-- setup ouvert (lu seulement s'il y a un setup à charger).
local function loadReadiness()
  local any = next(app.saved) ~= nil
  for _, m in pairs(app.memory) do any = any or m.text ~= nil end
  if not any then
    app.loadReady = nil
    return
  end
  local okC, car = Util.call(Util.get(host.ac, 'getCar'), 0)
  local speed = okC and Util.get(car, 'speedMs') or nil
  local okE, editable = Util.call(Util.get(host.ac, 'isSetupAvailableToEdit'))
  app.loadReady = { pit = okC and Util.get(car, 'isInPit') == true,
    stopped = Util.isFinite(speed) and math.abs(speed) * 3.6 <= K.loadMaxSpeedKmh, menu = okE and editable == true }
end

local function loadTick()
  local arm = app.loadArm
  if arm then
    arm.frames = arm.frames + 1
    local saved = app.saved[arm.kind]
    local expired = (arm.untilClock and app.clock and app.clock() > arm.untilClock)
      or (arm.untilClock == nil and (arm.frames > K.loadConfirmFrames or app.now > arm.untilNow))
    local why = expired and 'délai de confirmation écoulé' or loadBlocker(arm.kind)
    if why == nil and not (saved and saved.path == arm.path and app.proposals[arm.kind] == arm.signature) then
      why = 'autre setup enregistré'
    end
    if why then
      app.loadArm = nil
      app.ui.message = 'Chargement désarmé : ' .. why .. '.'
      app.loadNote = { kind = arm.kind, text = app.ui.message }
    end
  end
  local check = app.loadCheck
  if check == nil then return end
  local label = COMPUTE[check.kind].label
  local same, section = liveHasValues(check.target)
  if same then
    app.loadCheck = nil
    if check.already then
      app.loadTest = { ok = false, kind = check.kind, path = check.path,
        reason = 'non concluant : le setup en cours était déjà celui du fichier' }
      app.ui.message = 'Setup ' .. label .. ' en place, mais le chargement n\'est pas constaté : la voiture avait déjà ce '
        .. 'setup (' .. check.backup .. ').'
    else
      app.loadTest = { ok = true, kind = check.kind, path = check.path }
      -- setup chargé : vos retouches se mesurent à partir de lui (celles d'avant restent gardées)
      app.loaded[check.kind] = { values = check.target, name = check.path:match('[^/\\]+$') }
      app.loadVerified = app.loadTest
      app.ui.message = 'Setup ' .. label .. ' chargé et vérifié dans la voiture (' .. check.backup
        .. '). Le prochain calcul relancera la découverte sur ce setup ; ses tours servent à la validation.'
      -- affinage : nouvelle découverte tout de suite, voiture au stand ; tours comptés avec ce setup
      local r = app.refine
      if r and r.active and r.kind == check.kind then
        r.needsDiscovery, r.laps, r.lapSignature, r.due, r.nextAt = true, 0, nil, true, nil
        -- minimum avant une proposition : compté de nouveau avec le setup chargé
        r.minLaps, r.minTime, r.minFamily = 0, 0, nil
        for _, entry in ipairs(r.history) do
          if entry.version and app.saved[check.kind] and entry.signature == app.saved[check.kind].signature then
            r.driven = entry.version
          end
        end
        app.ui.message = app.ui.message .. ' Affinage : nouvelle découverte au stand, puis nouveau calcul sur ce setup.'
      end
    end
    log('INFO', 'load', app.ui.message)
    refreshCaps()
    return
  end
  check.frames = check.frames - 1
  if check.frames <= 0 then
    app.loadCheck = nil
    app.loadTest = { ok = false, kind = check.kind, path = check.path,
      reason = 'écart : setup en cours différent du fichier chargé (' .. tostring(section or 'setup illisible') .. ')' }
    app.ui.message = 'Écart : le jeu a accepté le chargement, mais le setup en cours diffère du setup ' .. label .. ' ('
      .. tostring(section or 'setup illisible') .. ') : vérifier dans le menu de setup (' .. check.backup .. ').'
    log('WARN', 'load', app.ui.message)
    refreshCaps()
  end
end

-- Copie du tour enregistré (§9.1) : meilleur tour valide du setup de la découverte, sinon le dernier.
local function copyLap()
  local d = app.discovery
  local lap = (d and Recorder.best(app.recorder, d.signature, app.wet.state)) or app.recorder.laps.last
  if lap == nil or d == nil or d.trackModel == nil then
    app.ui.message = 'Aucun tour enregistré à copier (ou circuit indisponible).'
    return
  end
  local setupText = 'signature ' .. tostring(lap.signature)
  if lap.signature == d.signature then
    local parts = {}
    for _, sp in ipairs(d.setup.spinners) do parts[#parts + 1] = sp.name .. '=' .. tostring(sp.value) end
    setupText = table.concat(parts, ' ')
  end
  local text = Recorder.exportText(lap, { appVersion = Config.version, carId = d.car and d.car.id,
    trackId = d.trackFiles and d.trackFiles.fullId, setupText = setupText,
    modelTime = d.simCurrent and d.simCurrent.time, calibration = app.calibration and app.calibration.result,
    drs = d.drs and d.drs.wing and { measure = Recorder.drsSummary(app.recorder),
      expected = d.drs.effect and 1 - d.drs.effect or nil } or nil },
    function(p) return TrackModel.sAtProgress(d.trackModel, p) end, d.trackModel.length)
  local ok, result = Util.call(Util.get(host.ac, 'setClipboardText'), text)
  if ok and result ~= false then
    app.ui.message = 'Tour copié dans le presse-papiers (' .. #text .. ' caractères) : à coller dans la conversation.'
  else
    app.ui.message = 'Copie impossible : ' .. tostring(ok and 'refusée par CSP' or result)
  end
end

-- ---------------------------------------------------------------------------
-- Affinage (demande de Vincent du 21/10/2026) : « on lance l'analyse, au fur et à mesure des tours elle
-- analyse, on enregistre le setup, on continue, on peaufine, jusqu'à trouver le meilleur setup ».
-- Décision amendée par Vincent le même jour, après 29 fichiers écrits en un quart d'heure : « il ne faut pas
-- qu'il enregistre automatiquement au fur et à mesure des tours… il me propose un setup que moi je valide et
-- que j'utilise ou pas ; et ensuite on continue ». Rien n'est écrit sans un clic : chaque setup proposé est
-- une version en attente (vN), annoncée une fois à l'écran (ac.setMessage) ; « Valider » l'enregistre (nom
-- choisi « _vN », sinon daté) et en fait le setup à charger au stand, en deux clics ; « Écarter » : jamais
-- reproposée. Nouveau calcul dès qu'il y a des données nouvelles (un tour propre, ou N tours propres selon le
-- réglage « Affinage : tours propres avant un nouveau calcul » ; un chargement dans la voiture ; un nouvel essai
-- après un refus), jamais deux fois sur les mêmes données ; jamais d'arrêt tout seul. Piloté par la boucle de
-- calcul (fenêtre masquée comprise) ; l'état vit dans app.refine (une découverte efface app.quali et
-- app.race). Jamais muet : phase et raison d'attente.
-- ---------------------------------------------------------------------------

-- Version de l'affinage d'une signature de setup, ou nil.
local function refineVersionOf(r, signature)
  for _, entry in ipairs(r.history) do
    if entry.version and entry.signature == signature then return entry.version end
  end
  return nil
end

local function refineEntry(r, version)
  for _, e in ipairs(r.history) do
    if e.version == version then return e end
  end
  return nil
end

-- Version en attente de l'avis du pilote (la dernière, ni validée ni écartée), ou nil.
local function refinePending(r)
  local e = refineEntry(r, r.version)
  if e and e.status == nil then return e end
  return nil
end

-- Version prête au retour au stand (décision de Vincent du 22/10/2026 : « qu'il donne juste un message en disant
-- j'ai le minimum d'informations et tant que l'utilisateur n'est pas retourné dans les stands, on continue
-- d'analyser les données ») : en piste, la version en attente reste provisoire et chaque tour propre la met à
-- jour ; elle est annoncée prête au stand (voie des stands comprise), de nouveau si elle a changé depuis.
local function carAtPit()
  local ok, car = Util.call(Util.get(host.ac, 'getCar'), 0)
  if not (ok and car) then return true end
  return Util.get(car, 'isInPit') == true or Util.get(car, 'isInPitlane') == true
end

-- Tours propres analysés pour une version : vos tours avec le setup dont elle part, même état de piste.
local function lapsAnalyzed(e)
  local f = e.originFamily and app.recorder.laps.family[Recorder.bestKey(e.originFamily, e.bucket)]
  return f and f.count or 0
end

local function lapsText(n)
  local s = n > 1 and 's' or ''
  return n .. ' tour' .. s .. ' propre' .. s .. ' analysé' .. s
end

-- Annonce à l'écran (messages d'AC en haut de l'écran) : version prête, au stand.
local function refineAnnounce(r, e)
  if e.ready and e.readyAt == e.updates then return end
  -- déjà annoncée : ses mises à jour en piste restent silencieuses jusqu'au stand suivant
  e.ready, e.readyAt, e.noticed = true, e.updates, true
  local n = lapsAnalyzed(e)
  local title = 'SetupLab : setup ' .. COMPUTE[r.kind].label .. ' v' .. e.version .. ' prêt'
  local text = 'Gain prévu ' .. Util.fmt(e.gain, 2) .. ' s' .. (n > 0 and (', d\'après ' .. lapsText(n)) or '')
    .. '. Dans SetupLab : Valider (enregistre), puis Charger ; ou Recommencer (ne pas la garder).'
  Util.call(Util.get(host.ac, 'setMessage'), title, text, nil, K.alertSeconds)
  log('INFO', 'refine', title .. ' — ' .. text)
end

-- En piste : version provisoire ; une seule annonce par version (le minimum d'informations est là).
local function refinePreparing(r, e)
  -- inchangée depuis son annonce au stand (même setup recalculé) : elle reste prête
  if e.ready and e.readyAt == e.updates then return end
  e.ready = false
  if e.noticed then return end
  e.noticed = true
  local title = 'SetupLab : setup ' .. COMPUTE[r.kind].label .. ' v' .. e.version .. ' en préparation'
  local text = 'J\'ai le minimum d\'informations ; je continue d\'analyser vos tours. Le setup sera prêt à votre retour au stand.'
  Util.call(Util.get(host.ac, 'setMessage'), title, text, nil, K.alertSeconds)
  log('INFO', 'refine', title .. ' — ' .. text)
end

-- Voiture qui roule en piste (minutes de roulage du minimum).
local function carRolling()
  local ok, car = Util.call(Util.get(host.ac, 'getCar'), 0)
  if not (ok and car) then return false end
  if Util.get(car, 'isInPit') == true or Util.get(car, 'isInPitlane') == true then return false end
  local speed = Util.get(car, 'speedMs')
  return Util.isFinite(speed) and math.abs(speed) * 3.6 > K.loadMaxSpeedKmh
end

-- Minimum avant une proposition (décision de Vincent du 26/10/2026 : « combien de minimum de temps ou de tour il faut
-- avant que SetupLab propose un setup ou une modification ») : tours propres et minutes de roulage avec le setup en
-- cours dans la voiture, les deux atteints ; remis à zéro à chaque chargement.
local function refineMinReached(r)
  local laps, minutes = app.settings.refineMinLaps or 0, app.settings.refineMinMinutes or 0
  return (r.minLaps or 0) >= laps and (r.minTime or 0) >= minutes * 60
end

local function refineMinText(r)
  local laps, minutes = app.settings.refineMinLaps or 0, app.settings.refineMinMinutes or 0
  local text = 'minimum avant une proposition : ' .. math.min(r.minLaps or 0, laps) .. '/' .. laps .. ' tour'
    .. (laps > 1 and 's' or '') .. ' propre' .. (laps > 1 and 's' or '')
  if minutes > 0 then
    text = text .. ' · ' .. Util.fmt(math.min((r.minTime or 0) / 60, minutes), 1) .. '/' .. Util.fmt(minutes, 0) .. ' min'
  end
  return text
end
app.refineMinReached, app.refineMinText = refineMinReached, refineMinText

-- Effets d'une version (décision de Vincent du 26/10/2026) : ses réglages changés regroupés (Config.effectGroups),
-- chacun gardé par défaut ; un groupe déjà trié garde son choix quand la version est mise à jour.
local function groupOfKind(kind)
  for _, g in ipairs(Config.effectGroups) do
    if g.kinds and g.kinds[kind] then return g end
  end
  return nil
end

local function effectGroupsOf(e, previous)
  local keep = {}
  for _, g in ipairs(previous or {}) do keep[g.key] = g.keep end
  local byKey, list = {}, {}
  local function add(def, item)
    local g = byKey[def.key]
    if g == nil then
      g = { key = def.key, label = def.label, items = {}, contribution = 0 }
      if keep[def.key] ~= nil then g.keep = keep[def.key] else g.keep = true end
      byKey[def.key] = g
    end
    g.items[#g.items + 1] = item
    g.contribution = g.contribution + (item.contribution or 0)
  end
  local other = Config.effectGroups[#Config.effectGroups]
  for _, c in ipairs(e.changeList or {}) do
    add(groupOfKind(c.var.kind) or other, { change = c, label = c.var.label, contribution = c.contribution or 0 })
  end
  local compound = e.compound
  if compound and compound.changed then
    for _, def in ipairs(Config.effectGroups) do
      if def.compound then add(def, { compound = true, label = 'Composé de pneus', contribution = 0 }) end
    end
  end
  for section, aid in pairs(e.aids or {}) do
    if aid.to then
      for _, def in ipairs(Config.effectGroups) do
        if def.aids then add(def, { aid = section, label = section, from = aid.from, to = aid.to, contribution = 0 }) end
      end
    end
  end
  for _, def in ipairs(Config.effectGroups) do
    if byKey[def.key] then list[#list + 1] = byKey[def.key] end
  end
  return list
end

local function keptCount(e)
  local n, kept = 0, 0
  for _, g in ipairs(e.groups or {}) do
    n = n + 1
    if g.keep then kept = kept + 1 end
  end
  return kept, n
end
app.keptCount = keptCount

-- Setup des seuls effets gardés : texte, signature et famille ; nil et la raison si impossible.
local function keptSetup(e)
  local kept, n = keptCount(e)
  if kept == n then return { text = e.text, signature = e.signature, family = e.family, all = true } end
  local d = e.disc
  if not (d and d.space and e.deltas) then return nil, 'données de la version absentes' end
  local refused = {}
  for _, g in ipairs(e.groups) do
    if not g.keep then
      for _, item in ipairs(g.items) do
        if item.change then refused[item.change.var.key] = true end
        if item.compound then refused.TYRES = true end
        if item.aid then refused['aid:' .. item.aid] = true end
      end
    end
  end
  local deltas = {}
  for key, value in pairs(e.deltas) do
    if not refused[key] then deltas[key] = value end
  end
  local values, errors = SetupSpace.values(d.space, deltas, { fuel = true })
  if #errors > 0 then return nil, table.concat(errors, ' ; ') end
  local compound = e.compound
  local tyres = d.compoundIndex
  if compound and compound.changed and not refused.TYRES then
    values.TYRES = compound.index
    tyres = compound.index
  end
  local text, why = SetupSpace.render(e.baseText, values)
  if text == nil then return nil, table.concat(why or {}, ' ; ') end
  local aidValues = {}
  for section, aid in pairs(e.aids or {}) do
    if aid.to and not refused['aid:' .. section] then aidValues[section] = aid.to end
  end
  if next(aidValues) then text = SetupSpace.renderOptional(text, aidValues) end
  return { text = text, signature = signatureOf(d.setup.spinners, values, tyres),
    family = signatureOf(d.setup.spinners, values, tyres, K.familyIgnored), refused = refused, all = false }
end

-- Effets refusés : gardés à leur ancienne valeur par les calculs suivants (sinon le même changement reviendrait au
-- calcul suivant), jusqu'à « Libérer » ; même mécanisme que vos retouches au stand.
local function pinRefused(kind, e, refused)
  local pins = app.pins[kind]
  for _, var in ipairs(e.disc and e.disc.space and e.disc.space.vars or {}) do
    if refused[var.key] then
      for _, member in ipairs(var.members) do
        pins[member.name] = { value = member.current, from = member.current, refused = true }
      end
    end
  end
  if refused.TYRES and e.disc and e.disc.compoundIndex then
    pins.TYRES = { value = e.disc.compoundIndex, from = e.compound and e.compound.index, refused = true }
  end
end

-- Historique : une seule ligne pour la même note d'affilée ; au-delà de K.refineHistory lignes, les notes
-- partent d'abord, jamais la version en attente.
local function refineNote(r, entry)
  local last = r.history[#r.history]
  if last and last.version == nil and last.note == entry.note then
    last.count = (last.count or 1) + 1
    last.timeCurrent, last.timeProposed, last.gain = entry.timeCurrent, entry.timeProposed, entry.gain
    return
  end
  r.history[#r.history + 1] = entry
end

local function refineTrim(r)
  local pending = refinePending(r)
  while #r.history > K.refineHistory do
    local drop = nil
    for i, e in ipairs(r.history) do
      if drop == nil and e.version == nil then drop = i end
    end
    if drop == nil then
      for i, e in ipairs(r.history) do
        if drop == nil and e ~= pending then drop = i end
      end
    end
    if drop == nil then break end
    table.remove(r.history, drop)
  end
end

-- Lance un calcul (ou le met en attente de la découverte) ; refus : dit, nouvel essai au prochain tour.
local function refineCompute(r)
  r.phase, r.due, r.waiting, r.laps, r.lapSignature = 'calcul', false, nil, 0, nil
  r.before = app[r.kind]
  startCompute(r.kind)
  local q = app[r.kind]
  if app.pendingComputes[r.kind] or (q and q ~= r.before and q.state == 'running') then return end
  r.phase, r.retry = 'tours', true
  r.due, r.nextAt = app.settings.refineLaps <= 0, app.now + K.refineRetryDelay
  r.waiting = 'nouvel essai ' .. (r.due and ('dans ' .. K.refineRetryDelay .. ' s ou ') or '') .. 'au prochain tour propre : '
    .. tostring(app.ui.message or 'calcul refusé')
end

-- Fin du calcul attendu : rien n'est écrit. Un setup proposé meilleur d'au moins K.refineMinGain devient la
-- version vN, en attente de l'avis du pilote, annoncée une fois ; tant qu'elle attend, chaque nouveau calcul la
-- remplace (même numéro, données plus récentes, sans nouvelle annonce). Le calcul suivant attend des données
-- nouvelles (tour propre, chargement, nouvel essai après un refus).
local function refineFinish(r, q)
  r.phase, r.laps, r.lapSignature, r.due = 'tours', 0, nil, false
  if not (q and q ~= r.before and q.state == 'done') then
    local why = app.ui.message or 'calcul non lancé'
    if q and q ~= r.before and q.state == 'failed' then why = 'calcul en échec : ' .. tostring(q.error) end
    if q and q ~= r.before and q.state == 'cancelled' then why = 'calcul annulé' end
    r.retry = true
    r.due, r.nextAt = app.settings.refineLaps <= 0, app.now + K.refineRetryDelay
    r.waiting = 'nouvel essai ' .. (r.due and ('dans ' .. K.refineRetryDelay .. ' s ou ') or '') .. 'au prochain tour propre : '
      .. why
    return
  end
  r.retry, r.waiting, r.nextAt = false, nil, nil
  local result = q.result
  local gain = (result.timeCurrent or 0) - (result.timeProposed or 0)
  local note = { bucket = q.conditions and q.conditions.bucket or 'sec', timeCurrent = result.timeCurrent,
    timeProposed = result.timeProposed, calibrated = result.calibrated, gain = gain, changes = #result.changes }
  local pending = refinePending(r)
  local origin = q.discovery and q.discovery.signature
  local shown = nil
  if origin and r.rejected[origin] then
    -- calcul parti d'une version non gardée encore dans la voiture : rien de proposé
    note.note = 'parti d\'une version non gardée : rien de proposé'
    r.waiting = 'Version non gardée encore dans la voiture : charger la référence (ou un autre setup) au stand.'
  elseif #result.changes == 0 or gain < K.refineMinGain then
    note.note = #result.changes == 0 and 'setup actuel conservé : le meilleur trouvé'
      or ('setup actuel conservé : gain prévu sous ' .. Util.fmt(K.refineMinGain, 2) .. ' s')
  else
    local p, why = proposalOf(r.kind)
    local known = p and refineVersionOf(r, p.signature)
    if p == nil then
      note.note = 'proposition impossible : ' .. tostring(why)
      r.waiting = note.note
    elseif r.rejected[p.signature] then
      note.note = 'identique à une version non gardée : pas reproposée'
    elseif known and not (pending and known == pending.version) then
      local e = refineEntry(r, known)
      note.note = 'identique à v' .. known .. (e and e.status and (' (' .. (e.status == 'écartée' and 'non gardée' or e.status)
        .. ')') or '')
        .. ((e and e.file and r.driven ~= known) and ' : la charger au stand' or '')
    else
      local e = pending
      if e == nil then
        r.version = r.version + 1
        e = { version = r.version, updates = 0 }
        r.history[#r.history + 1] = e
      elseif known == nil then
        e.updates = (e.updates or 0) + 1
      end
      e.signature, e.text, e.known, e.origin = p.signature, p.text, p.known, p.d.signature
      e.family, e.originFamily = p.family, p.originFamily
      e.bucket, e.group, e.carId, e.at = p.bucket, memoryGroup(r.kind), p.d.car and p.d.car.id, app.now
      e.timeCurrent, e.timeProposed, e.calibrated, e.gain = result.timeCurrent, result.timeProposed, result.calibrated, gain
      e.changes, e.changeList, e.refined = #result.changes, result.changes, result.refined
      -- tri effet par effet : deltas, découverte d'origine, composé et aides gardés avec la version (le calcul
      -- suivant remplace app[kind])
      e.deltas, e.disc, e.compound, e.aids, e.baseText = result.deltas, p.d, result.compound, result.aids, p.baseText
      e.groups = effectGroupsOf(e, e.groups)
      -- même setup déjà enregistré à la main : validable sans nouveau fichier
      local saved = app.saved[r.kind]
      if saved and saved.signature == p.signature and saved.text == p.text then
        e.file, e.path, e.hash = saved.name, saved.path, saved.hash
      else
        e.file, e.path, e.hash = nil, nil, nil
      end
      shown = e
      if carAtPit() then refineAnnounce(r, e) else refinePreparing(r, e) end
    end
  end
  if note.note then refineNote(r, note) end
  refineTrim(r)
  app.ui.message = 'Affinage ' .. COMPUTE[r.kind].label .. ' : ' .. (shown and ('v' .. shown.version
    .. (shown.ready and (shown.updates > 0 and ' mise à jour' or ' prête') or ' en préparation') .. ', gain prévu '
    .. Util.fmt(shown.gain, 3) .. ' s' .. (shown.ready and ' : la valider (enregistrée, puis à charger au stand) ou recommencer'
      or ' (provisoire) : analyse de vos tours jusqu\'au retour au stand')) or note.note)
    .. ' ; nouveau calcul ' .. (app.settings.refineLaps > 1 and ('après ' .. app.settings.refineLaps .. ' tours propres.')
      or 'au prochain tour propre.')
  log('INFO', 'refine', app.ui.message)
end

-- À chaque frame (boucle de calcul) : découverte après un chargement, calcul attendu, calcul dû.
local function refineTick()
  local r = app.refine
  if not (r and r.active) or app.inert then return end
  local kind = r.kind
  -- minutes de roulage avec le setup en cours (en piste, voiture qui roule, jeu non en pause)
  local now = app.now
  if r.minClock and now > r.minClock and now - r.minClock < 1 and not app.recordContext.paused and carRolling() then
    r.minTime = (r.minTime or 0) + (now - r.minClock)
  end
  r.minClock = now
  -- progression du minimum toujours à jour (un calcul ou une calibration en cours ne la fige pas)
  if r.phase == 'tours' and not refineMinReached(r) then r.waiting = refineMinText(r) end
  -- retour au stand : la version en préparation est annoncée prête (calcul en cours : à sa fin)
  local pending = refinePending(r)
  if pending and not pending.ready and r.phase ~= 'calcul' and carAtPit() then refineAnnounce(r, pending) end
  -- chargement vérifié : nouvelle découverte au stand (repère de hauteur, A25), une fois les tâches en
  -- cours terminées (une calibration en cours n'est pas perdue)
  if r.needsDiscovery then
    if app.discoveryState == 'running' or Util.schedulerBusy(app.scheduler) then return end
    r.needsDiscovery = false
    startDiscovery()
    return
  end
  if r.phase == 'calcul' then
    if app.pendingComputes[kind] then
      if app.discoveryState == 'running' then return end
      app.pendingComputes[kind] = nil
      if app.discoveryState == 'done' then startCompute(kind, true) end
    end
    local q = app[kind]
    if q and q.state == 'running' then return end
    refineFinish(r, q)
  elseif r.due and (r.nextAt == nil or app.now >= r.nextAt) then
    -- tâches en cours d'abord (calcul lancé à la main, calibration et validation lancées par le tour qui
    -- vient de finir) : une découverte relancée par le calcul les annulerait toutes (relecture du
    -- 21/10/2026 : sur la DTM, carburant changé à chaque relais, chaque cycle perdait sa calibration) ;
    -- et rien de plus sur l'image du passage de ligne (§14.3)
    local q = app[kind]
    if app.pendingComputes[kind] or (q and q.state == 'running') or app.discoveryState == 'running'
        or Util.schedulerBusy(app.scheduler) then
      return
    end
    -- version en essai : rien de nouveau avant son tri (une seule version ouverte à la fois)
    for _, e in ipairs(r.history) do
      if e.version and e.status == 'essai' then
        r.waiting = 'v' .. e.version .. ' en essai : gardez ou refusez ses effets puis validez (ou recommencez)'
        return
      end
    end
    -- minimum avant une proposition ; course : garde (référence de qualification, nombre de tours)
    if not refineMinReached(r) then
      r.waiting = refineMinText(r)
      return
    end
    if kind == 'race' then
      local why = raceBlocker()
      if why then
        r.waiting = 'course : ' .. why
        return
      end
    end
    refineCompute(r)
  end
end
app.refineTick = function()
  local ok, err = pcall(refineTick)
  if not ok then
    app.perf.errors = app.perf.errors + 1
    if app.refine then app.refine.waiting = 'erreur interne : ' .. Util.truncate(tostring(err), 200) end
    log('ERROR', 'refine', err)
  end
end

-- Numéros de version continus sur le circuit (décision de Vincent du 22/10/2026) : le plus grand « _vN » du genre
-- déjà dans le dossier (sec et pluie), sinon 0.
local function lastVersionOnDisk(kind)
  local folder = Exporter.targetFolder(host)
  if folder == nil then return 0 end
  local ok, list = Util.call(Util.get(host.io, 'scanDir'), folder, '*.ini')
  if not (ok and type(list) == 'table') then return 0 end
  local top = 0
  for i = 1, math.min(#list, K.scanMaxFiles) do
    local v = Util.versionInName(list[i], Config.fileGenre[kind])
    if v and v > top then top = v end
  end
  return top
end

local function refineStart(kind)
  local base = lastVersionOnDisk(kind)
  app.refine = { kind = kind, active = true, phase = 'tours', version = base, base = base, laps = 0, history = {},
    rejected = {} }
  local r = app.refine
  -- tours propres déjà roulés avec le setup en cours (avant d'activer l'affinage) : ils comptent pour le minimum
  local d = app.discovery
  local f = d and d.family and app.recorder.laps.family[Recorder.bestKey(d.family, app.wet.state)]
  if f then r.minFamily, r.minLaps, r.minTime = d.family, f.count, f.sum end
  log('INFO', 'refine', 'Affinage ' .. COMPUTE[kind].label .. ' lancé')
  local why = kind == 'race' and raceBlocker() or nil
  if not refineMinReached(r) or why then
    r.due, r.nextAt = true, nil
    r.waiting = why and ('course : ' .. why) or refineMinText(r)
    app.ui.message = 'Affinage ' .. COMPUTE[kind].label .. ' lancé : ' .. r.waiting .. '.'
    return
  end
  refineCompute(r)
  if app.refine.phase == 'calcul' then
    app.ui.message = 'Affinage ' .. COMPUTE[kind].label .. ' lancé : premier calcul, puis un nouveau '
      .. (app.settings.refineLaps > 1 and ('tous les ' .. app.settings.refineLaps .. ' tours propres') or 'à chaque tour propre')
      .. ' ; chaque setup proposé est annoncé à l\'écran, rien n\'est enregistré avant « Valider ».'
  end
end

local function refineStop()
  local r = app.refine
  if not (r and r.active) then return end
  r.active, r.phase, r.due, r.needsDiscovery = false, 'arrêté', false, false
  app.ui.message = 'Affinage arrêté' .. (r.version > (r.base or 0) and (' : dernière version v' .. r.version .. '.') or '.')
  log('INFO', 'refine', app.ui.message)
end

-- ---------------------------------------------------------------------------
-- Valider, écarter, figer ; mémoire du circuit ; SetupLab actif (décisions de Vincent du 21/10/2026 :
-- « on valide ou on ne valide pas à chaque étape », « un bouton avec un cadenas pour dire ce setup est
-- validé », « une mémoire par circuit et par type de séance », « on l'ouvre, on l'active, on roule »).
-- Valider : la version devient le setup de référence de la séance et de l'état de piste, gardé en mémoire.
-- Écarter : jamais reproposée ; le setup à charger redevient la référence. Figer : la référence est
-- verrouillée, l'affinage automatique s'arrête pour cette séance et cet état de piste. L'affinage part
-- toujours du setup monté dans la voiture : une version validée se charge au stand pour repartir d'elle.
-- ---------------------------------------------------------------------------

local function groupLabel(group)
  for _, g in ipairs(Config.memoryGroups) do
    if g.key == group then return g.label end
  end
  return tostring(group)
end

local function memoryTitle(m)
  return groupLabel(m.group) .. ', ' .. (m.bucket == 'pluie' and 'pluie' or 'sec')
end

local function memoryKind(group)
  return group == 'course' and 'race' or 'quali'
end

-- Écrit le fichier d'une version, à sa validation seulement (décision de Vincent du 21/10/2026) : nom choisi
-- (sinon « SetupLab »), genre, pluie, « _vN » (22/10/2026) ; jamais d'écrasement. Elle devient le setup à charger
-- au stand. Renvoie vrai, ou faux et la raison.
local function writeVersion(r, e)
  -- effets gardés (décision de Vincent du 26/10/2026) : la version enregistrée n'a que les groupes gardés
  local kept, why = keptSetup(e)
  if kept == nil then return false, why end
  if e.file and kept.all then
    setLoadTarget(r.kind, e)
    return true
  end
  if app.inert then return false, app.inert end
  local trial = e.trial
  local base = fileBase(r.kind, e.bucket) .. '_v' .. e.version
  local w
  if kept.all and trial and app.written[trial.file] == trial.hash then
    -- tout gardé après l'essai : le fichier d'essai devient la version (renommé, jamais réécrit)
    w = Exporter.renameOwn(host, trial.file, trial.hash, base)
    if w.ok then followRename(trial.file, w.name, w.path) end
  else
    w = Exporter.writeNew(host, base, kept.text)
  end
  if not w.ok then return false, tostring(w.reason) end
  if not kept.all then
    -- version partielle : son contenu et sa famille ; l'essai, encore dans la voiture, n'est plus une base de calcul,
    -- son fichier part à la Corbeille ; effets refusés gardés à leur ancienne valeur
    if trial then
      r.rejected[trial.signature] = true
      queueFileOp({ op = 'corbeille', name = trial.file, hash = trial.hash, why = 'essai de v' .. e.version .. ' trié' })
    end
    pinRefused(r.kind, e, kept.refused)
    e.trialFamily = trial and trial.family or e.trialFamily
    e.text, e.signature, e.family = kept.text, kept.signature, kept.family
  end
  e.trial = nil
  e.file, e.path, e.hash, e.ownFile = w.name, w.path, Util.hashString(kept.text), true
  app.written[w.name] = e.hash
  setLoadTarget(r.kind, e)
  -- tours roulés avec elle : calibration et validation en jeu (§14.1)
  if e.known then rememberSetup(e.signature, e.known) end
  local saved = { file = w.name, gain = e.gain, time = e.timeProposed }
  Store.put(app.store, storeKey('last', app.discovery, r.kind), saved, stamp())
  app.lastSaved = app.lastSaved or {}
  app.lastSaved[r.kind] = saved
  log('INFO', r.kind .. '_save', 'v' .. e.version .. ' validée, enregistrée : ' .. w.path)
  return true
end

-- Version validée : enregistrée, setup à charger, référence en mémoire (une référence figée n'est remplacée
-- qu'après déverrouillage ; la référence remplacée est gardée, rendue si la version est écartée après
-- l'essai). Renvoie l'entrée de la mémoire, ou nil (refus dit).
local function refineValidate(r, e)
  local m = app.memory[e.group .. '|' .. e.bucket]
  local same = m ~= nil and m.signature == e.signature
  if m and m.locked and not same then
    app.ui.message = 'Setup figé pour ' .. memoryTitle(m) .. ' (' .. m.file .. ') : le déverrouiller d\'abord (Mémoire du circuit).'
    return nil
  end
  local ok, why = writeVersion(r, e)
  if not ok then
    app.ui.message = 'v' .. e.version .. ' non validée : écriture impossible (' .. tostring(why) .. ').'
    log('WARN', 'memory', app.ui.message)
    return nil
  end
  e.status = 'validée'
  if m and not same then e.replaced = m end
  local entry = { group = e.group, bucket = e.bucket, file = e.file, hash = e.hash, version = e.version, gain = e.gain,
    time = e.timeProposed, locked = same and m.locked or false, path = e.path, text = e.text, signature = e.signature,
    origin = e.origin, carId = e.carId, family = e.family }
  memoryPut(entry)
  queueBackupCleanup()
  app.ui.message = 'v' .. e.version .. ' validée et enregistrée : ' .. e.file .. ' ; setup de référence (' .. memoryTitle(entry)
    .. ') gardé en mémoire pour ce circuit. ' .. (r.driven == e.version and 'Elle est en piste : l\'affinage repart d\'elle.'
      or 'Au stand, menu de setup ouvert : « Charger » pour l\'essayer ; l\'affinage repartira d\'elle.')
  log('INFO', 'memory', app.ui.message)
  return entry
end

-- Version écartée : jamais reproposée ; le setup à charger redevient la référence (s'il y en a une).
local function refineReject(r, e)
  local key = e.group .. '|' .. e.bucket
  local m = app.memory[key]
  if m and m.locked and m.signature == e.signature then
    app.ui.message = 'v' .. e.version .. ' est le setup figé (' .. memoryTitle(m) .. ') : le déverrouiller d\'abord.'
    return
  end
  e.status = 'écartée'
  r.rejected[e.signature] = true
  -- son fichier, écrit à sa validation, part à la Corbeille voiture arrêtée (réponse de Vincent du 22/10/2026) ;
  -- un fichier enregistré à la main reste
  -- fichier d'essai (version essayée puis refusée en entier) : à la Corbeille aussi
  if e.trial and app.written[e.trial.file] == e.trial.hash then
    queueFileOp({ op = 'corbeille', name = e.trial.file, hash = e.trial.hash, why = 'essai de v' .. e.version .. ' non gardé' })
    if app.saved[r.kind] and app.saved[r.kind].name == e.trial.file then app.saved[r.kind] = nil end
    e.trial = nil
  end
  local recycle = e.file ~= nil and e.ownFile == true and e.hash ~= nil
  if recycle then queueFileOp({ op = 'corbeille', name = e.file, hash = e.hash, why = 'v' .. e.version .. ' non gardée' }) end
  -- référence validée puis écartée (après l'essai) : la référence d'avant revient, sinon plus de référence
  if m and m.signature == e.signature then
    local previous = e.replaced
    if previous and previous.signature and not r.rejected[previous.signature] then
      memoryPut(previous)
      m = previous
    else
      app.memory[key] = nil
      Store.remove(app.store, storeKey('mem', app.discovery, e.group, e.bucket))
      m = nil
    end
  end
  local back = m and m.text and m.signature and not r.rejected[m.signature] and m or nil
  if back then
    setLoadTarget(r.kind, back)
  elseif app.saved[r.kind] and app.saved[r.kind].signature == e.signature then
    app.saved[r.kind] = nil
    if app.loadArm and app.loadArm.kind == r.kind then app.loadArm = nil end
  end
  app.ui.message = 'v' .. e.version .. ' non gardée : ni réutilisée ni reproposée'
    .. (recycle and (' (son fichier ' .. e.file .. ' part à la Corbeille dès que la voiture est arrêtée).')
      or (e.file and (' (son fichier ' .. e.file .. ' reste : enregistré à la main).') or ' (jamais enregistrée).'))
    .. (back and (' Setup de référence à charger au stand : ' .. back.file .. '.') or ' Aucun setup de référence validé.')
    .. (r.driven == e.version and ' Elle est encore dans la voiture.'
      or ' SetupLab repart de votre setup actuel : nouvelle proposition avec vos prochains tours.')
  log('INFO', 'memory', app.ui.message)
end

-- Essayer (décision de Vincent du 26/10/2026 : « il propose un setup, l'utilisateur essaye ce setup ») : le setup
-- proposé entier est écrit dans un fichier d'essai (…_vN_essai), à charger au stand ; après l'essai, chaque effet est
-- gardé ou refusé, puis « Valider » enregistre la version avec les effets gardés.
local function refineTry(r, e)
  if e.status ~= nil and e.status ~= 'essai' then
    app.ui.message = 'v' .. e.version .. ' : déjà ' .. tostring(e.status) .. '.'
    return
  end
  if e.trial == nil then
    if app.inert then
      app.ui.message = 'Essai impossible : ' .. app.inert
      return
    end
    local w = Exporter.writeNew(host, fileBase(r.kind, e.bucket) .. '_v' .. e.version .. '_essai', e.text)
    if not w.ok then
      app.ui.message = 'v' .. e.version .. ' : essai impossible, écriture refusée (' .. tostring(w.reason) .. ').'
      return
    end
    local hash = Util.hashString(e.text)
    app.written[w.name] = hash
    e.trial = { file = w.name, path = w.path, hash = hash, text = e.text, signature = e.signature, family = e.family,
      bucket = e.bucket, origin = e.origin, carId = e.carId }
    if e.known then rememberSetup(e.signature, e.known) end
  end
  e.status = 'essai'
  setLoadTarget(r.kind, e.trial)
  app.ui.message = 'v' .. e.version .. ' en essai : ' .. e.trial.file .. '. Au stand, menu de setup ouvert : « Charger » ; '
    .. 'roulez, puis gardez ou refusez chaque effet et validez.'
  log('INFO', 'refine', app.ui.message)
end

-- Garder ou refuser un effet d'une version en attente ou en essai.
local function effectToggle(version, key, keep)
  local r = app.refine
  local e = r and refineEntry(r, version)
  if not (e and (e.status == nil or e.status == 'essai')) then return end
  for _, g in ipairs(e.groups or {}) do
    if g.key == key then g.keep = keep == true end
  end
  local kept, n = keptCount(e)
  app.ui.message = 'v' .. e.version .. ' : ' .. kept .. ' effet' .. (kept > 1 and 's' or '') .. ' gardé' .. (kept > 1 and 's' or '')
    .. ' sur ' .. n .. '.'
end

local function refineJudge(version, verdict)
  local r = app.refine
  local e = r and refineEntry(r, version)
  if not (e and e.signature and e.text) then
    app.ui.message = 'Version v' .. tostring(version) .. ' introuvable.'
    return
  end
  if verdict == 'valider' then
    local kept = keptCount(e)
    if kept == 0 then
      app.ui.message = 'v' .. e.version .. ' : aucun effet gardé ; « Recommencer » pour ne pas la garder.'
      return
    end
    refineValidate(r, e)
  elseif verdict == 'essayer' then
    refineTry(r, e)
  else
    refineReject(r, e)
  end
end

-- Figer (cadenas) : la référence de la séance et de l'état de piste est verrouillée, gardée en mémoire et
-- proposée au chargement ; l'affinage de ce genre s'arrête.
local function lockEntry(m, kind)
  m.locked = true
  memoryPut(m)
  local r = app.refine
  if r and r.active and r.kind == kind then refineStop() end
  if m.text and m.signature then setLoadTarget(kind, m) end
  app.ui.message = 'Setup figé : ' .. m.file .. ' (' .. memoryTitle(m) .. '), gardé en mémoire pour ce circuit et proposé à '
    .. 'chaque visite. Affinage arrêté pour cette séance ; « Déverrouiller » pour reprendre.'
  log('INFO', 'memory', app.ui.message)
end

local function refineLock(version)
  local r = app.refine
  local e = r and refineEntry(r, version)
  if not (e and e.signature and e.text) then
    app.ui.message = 'Version v' .. tostring(version) .. ' introuvable.'
    return
  end
  if e.status == 'écartée' then
    app.ui.message = 'v' .. version .. ' n\'est pas gardée : rien à figer.'
    return
  end
  local m = refineValidate(r, e)
  if m then lockEntry(m, r.kind) end
end

local function memoryLock(key, locked)
  local m = app.memory[key]
  if m == nil then return end
  if locked then
    lockEntry(m, memoryKind(m.group))
    return
  end
  m.locked = false
  memoryPut(m)
  app.ui.message = 'Setup déverrouillé (' .. memoryTitle(m) .. ') : ' .. (app.auto and 'l\'affinage automatique reprend.'
    or 'cocher « SetupLab actif » pour reprendre l\'affinage automatique.')
  log('INFO', 'memory', app.ui.message)
end

local function memoryLoad(key)
  local m = app.memory[key]
  if not (m and m.text and m.signature) then
    app.ui.message = 'Chargement impossible : ' .. tostring(m and m.problem or 'setup absent de la mémoire') .. '.'
    return
  end
  local kind = memoryKind(m.group)
  setLoadTarget(kind, m)
  armLoad(kind, 'memory')
end

local function autoToggle()
  app.auto = not app.auto
  if app.auto then
    local kind = autoKind()
    app.ui.message = 'SetupLab actif : affinage automatique du setup ' .. COMPUTE[kind].label .. ' (séance : '
      .. groupLabel(memoryGroup(kind)) .. ') dès la fin de la découverte ; chaque setup proposé est annoncé à l\'écran, '
      .. 'rien n\'est enregistré avant « Valider ».'
  else
    local r = app.refine
    if r and r.active then refineStop() end
    app.ui.message = 'SetupLab en veille : rien n\'est calculé ni enregistré tout seul (les tours restent analysés).'
  end
  log('INFO', 'auto', app.ui.message)
end

-- SetupLab actif : affinage du genre de la séance, sauf setup figé pour cette séance et cet état de piste ;
-- nouvelle séance (essai -> qualification -> course) : l'affinage suit le genre.
local function autoTick()
  if not app.auto or app.inert or app.discoveryState ~= 'done' then return end
  local kind = autoKind()
  local r = app.refine
  local m = app.memory[memoryGroup(kind) .. '|' .. app.wet.state]
  if m and m.locked then
    if r and r.active and r.kind == kind then
      refineStop()
      app.ui.message = 'Setup figé pour ' .. memoryTitle(m) .. ' (' .. m.file .. ') : affinage arrêté.'
    end
    return
  end
  if r and r.active and r.kind == kind then return end
  if r and r.active then refineStop() end
  refineStart(kind)
end
app.autoTick = function()
  local ok, err = pcall(autoTick)
  if not ok then
    app.perf.errors = app.perf.errors + 1
    app.auto = false
    app.ui.message = 'SetupLab mis en veille : erreur interne (' .. Util.truncate(tostring(err), 200) .. ').'
    log('ERROR', 'auto', err)
  end
end
app.autoKind, app.memoryGroupOf, app.customName = autoKind, memoryGroup, customName

local function handleIntents(intents)
  loadTick()
  -- calcul en attente de la découverte : lancé à sa fin
  if next(app.pendingComputes) and app.discoveryState ~= 'running' then
    local pending = app.pendingComputes
    app.pendingComputes = {}
    for _, kind in ipairs({ 'quali', 'race' }) do
      if pending[kind] and app.discoveryState == 'done' then
        startCompute(kind, true)
      elseif pending[kind] then
        app.ui.message = 'Calcul ' .. COMPUTE[kind].label .. ' non lancé : découverte interrompue.'
      end
    end
  end
  if intents.rediscover and not app.inert then
    log('INFO', 'rediscover', 'Découverte relancée à la demande')
    startDiscovery()
  end
  if intents.saveCopy then saveCopy() end
  for _, kind in ipairs({ 'quali', 'race' }) do
    if intents[kind .. 'Start'] then startCompute(kind) end
    if intents[kind .. 'Cancel'] and app.pendingComputes[kind] then
      app.pendingComputes[kind] = nil
      log('INFO', kind, 'Calcul ' .. COMPUTE[kind].label .. ' en attente annulé')
    end
    if intents[kind .. 'Cancel'] and app[kind] and app[kind].state == 'running' then
      Util.schedulerCancel(app.scheduler, kind)
      log('INFO', kind, 'Calcul ' .. COMPUTE[kind].label .. ' annulé')
    end
    if intents[kind .. 'Save'] then
      -- une erreur interne se voit sous le bouton, jamais un clic sans effet (constat du 21/10/2026)
      local ok, err = pcall(saveResult, kind)
      if not ok then
        app.perf.errors = app.perf.errors + 1
        app.ui.message = 'Enregistrement interrompu par une erreur interne : ' .. Util.truncate(tostring(err), 200)
        if app[kind] then app[kind].saveStatus = { ok = false, text = app.ui.message } end
        log('ERROR', kind .. '_save', app.ui.message)
      end
    end
  end
  -- nom du setup et case « SetupLab actif » : permis même en mode inerte (rien ne part tant qu'il dure)
  if intents.name then
    app.names[intents.name.kind] = Util.truncate(tostring(intents.name.text), K.nameMaxChars * 4)
  end
  if intents.autoToggle then autoToggle() end
  if app.inert and (intents.calibrate or intents.validate or intents.setting or intents.copyLap or intents.loadArm
      or intents.loadConfirm or intents.refineStart or intents.refineJudge or intents.refineLock or intents.memoryLoad
      or intents.memoryLock) then
    app.ui.message = 'Indisponible : ' .. app.inert
    return
  end
  if intents.refineStop then
    refineStop()
    -- SetupLab actif : arrêter l'affinage le met en veille (sinon il repartirait tout seul)
    if app.auto then
      app.auto = false
      app.ui.message = app.ui.message .. ' SetupLab en veille : cocher « SetupLab actif » pour reprendre.'
    end
  end
  if intents.refineStart then refineStart(intents.refineStart) end
  if intents.refineJudge then refineJudge(intents.refineJudge.version, intents.refineJudge.verdict) end
  if intents.effect then effectToggle(intents.effect.version, intents.effect.key, intents.effect.keep) end
  -- nombre de tours de la course (garde de course), gardé pour ce circuit
  if intents.raceLaps ~= nil then
    local n = tonumber(intents.raceLaps)
    if n and n >= 1 and n <= K.raceMaxLaps and n == math.floor(n) then
      app.raceLaps = n
      local key = storeKey('rlaps', app.discovery)
      if key then Store.put(app.store, key, { laps = n }, stamp()) end
      app.ui.message = 'Course : ' .. n .. ' tours, gardés pour ce circuit.'
    else
      app.ui.message = 'Nombre de tours de course refusé : entier de 1 à ' .. K.raceMaxLaps .. '.'
    end
  end
  if intents.raceRefLoad then
    local _, key = raceReference()
    if key then memoryLoad(key) end
  end
  if intents.refineLock then refineLock(intents.refineLock) end
  if intents.memoryLock then memoryLock(intents.memoryLock.key, intents.memoryLock.locked) end
  if intents.memoryLoad then memoryLoad(intents.memoryLoad) end
  if intents.calibrate and not startCalibration() then
    app.ui.message = 'Calibration impossible : aucun tour valide avec un setup connu.'
  end
  if intents.copyLap then copyLap() end
  if intents.pinsClear then
    app.pins[intents.pinsClear] = {}
    app.ui.message = 'Retouches libérées : le prochain calcul peut de nouveau changer tous les réglages.'
    log('INFO', 'pins', app.ui.message)
  end
  if intents.loadDisarm and app.loadArm then
    app.loadArm = nil
    app.ui.message = 'Chargement annulé : le setup en cours n\'a pas changé.'
  end
  if intents.loadArm then armLoad(intents.loadArm) end
  if intents.loadConfirm then confirmLoad(intents.loadConfirm) end
  if intents.setting then
    local key, value = intents.setting.key, intents.setting.value
    for _, def in ipairs(Config.settings) do
      if def.key == key then
        local valid = Config.validateOne(def, value)
        app.settings[key] = valid
        local editable = {}
        for _, name in ipairs(Config.EDITABLE) do editable[name] = app.settings[name] end
        Store.put(app.store, 'settings', editable)
        log('INFO', 'setting', def.label .. ' : ' .. tostring(valid))
      end
    end
  end
  if intents.validate then
    if not startValidation(intents.validate) then
      app.ui.message = 'Validation en jeu (§14.1) : 1. un tour propre avec le setup d\'origine ; 2. enregistrer le setup '
        .. 'proposé puis le charger dans le menu de setup ; 3. un tour propre avec lui. Le gain mesuré est alors comparé au gain prévu.'
    end
  end
  if intents.copyReport then
    if app.report == nil then
      app.ui.message = app.discoveryState == 'done' and 'Rapport en cours de préparation, réessayer dans un instant.'
        or 'Aucun rapport : la découverte n\'est pas terminée.'
    else
      local ok, result = Util.call(Util.get(host.ac, 'setClipboardText'), app.report)
      if ok and result ~= false then
        app.ui.message = 'Rapport copié dans le presse-papiers (' .. #app.report .. ' caractères'
          .. (app.reportTruncated and ', tronqué' or '') .. ').'
      else
        app.ui.message = 'Copie impossible : ' .. tostring(ok and 'refusée par CSP' or result)
        log('WARN', 'clipboard', app.ui.message)
      end
    end
  end
end
app.handleIntents = handleIntents

-- ---------------------------------------------------------------------------
-- Cycle de vie
-- ---------------------------------------------------------------------------

local function release()
  if app.released then return end
  app.released = true
  Util.schedulerCancel(app.scheduler)
  for _, dispose in ipairs(app.disposers) do pcall(dispose) end
  app.disposers = {}
end

SETUPLAB = { app = app, release = release, version = Config.version }

app.clock, app.clockReason = Caps.makeClock(host.ffi)
app.static = Caps.probeStatic(host)
if app.settings.debugLog then app.log.maxLevel = Util.LEVELS.DEBUG end
log('INFO', 'start', Config.appName .. ' ' .. Config.version .. ' démarré ; CSP ' .. tostring(app.static.version)
  .. ' build ' .. tostring(app.static.versionCode))
if app.clock == nil then log('WARN', 'clock', 'Horloge précise indisponible (' .. tostring(app.clockReason) .. ') : repli quota') end
app.utcOffset, app.utcOffsetReason = Caps.makeUtcOffset(host.ffi)
if app.utcOffset == nil then
  log('WARN', 'clock', 'Heure locale indisponible (' .. tostring(app.utcOffsetReason) .. ') : noms de fichiers en UTC')
end
do
  local ok, token = Util.call(Util.get(host.ac, 'onRelease'), release)
  if ok and Caps.isCallable(token, host.ffi) then app.disposers[#app.disposers + 1] = token end
end

-- ---------------------------------------------------------------------------
-- Rappels du manifest (méthodes de la table CSP « script »)
-- ---------------------------------------------------------------------------

-- CSP appelle la boucle soit via [SIM_CALLBACKS] UPDATE (script.SETUPLAB__UPDATE), soit via
-- script.update (convention des apps installées, dont ACAdvancedIA validée en jeu). Les deux sont
-- déclarées ; la première source qui appelle est retenue et l'autre ignorée : exactement une
-- tranche par frame quel que soit le mécanisme. Si la source retenue cesse d'être appelée alors
-- que l'autre continue (K.loopSwitchCalls appels d'affilée), la boucle bascule sur l'autre.
-- La source retenue figure dans la fenêtre debug et le rapport J0.
local function tick(source, dt)
  if app.released then return end
  if app.updateSource ~= source then
    if app.updateSource ~= nil then
      app.otherSourceCalls = app.otherSourceCalls + 1
      if app.otherSourceCalls < K.loopSwitchCalls then return end
    end
    app.updateSource, app.otherSourceCalls = source, 0
    log('INFO', 'loop', 'Boucle de calcul appelée par ' .. source)
  end
  app.otherSourceCalls = 0
  local perf = app.perf
  perf.lastMs = frameCost
  perf.avgMs = Util.ema(perf.avgMs, frameCost, K.perfEmaAlpha)
  if frameCost > perf.maxMs then perf.maxMs = frameCost end
  perf.skipNext = frameCost > app.settings.frameGuardMs
  frameCost = 0
  local ok, err = measure(update, dt)
  if not ok then
    perf.errors = perf.errors + 1
    log('ERROR', 'update', err)
  end
end

function script.SETUPLAB__UPDATE(dt)
  tick('SIM_CALLBACKS UPDATE', dt)
end

function script.update(dt)
  tick('script.update', dt)
end

function script.SETUPLAB__MAIN(_)
  if app.released then return end
  local intents = {}
  local ok, err = measure(Ui.main, host, app, intents)
  if not ok then
    app.perf.errors = app.perf.errors + 1
    log('ERROR', 'ui_main', err)
  end
  local okI, errI = measure(handleIntents, intents)
  -- état du stand après les clics de l'image (un setup validé à l'instant est déjà « à charger »)
  measure(loadReadiness)
  if not okI then
    app.perf.errors = app.perf.errors + 1
    app.ui.message = 'Erreur interne : ' .. Util.truncate(tostring(errI), 200)
    log('ERROR', 'intents', errI)
  end
end

-- Overlay en jeu (bêta 1.3) : verdict sur vos tours, réglages changés et leur gain prévu.
function script.SETUPLAB__OVERLAY(_)
  if app.released then return end
  local ok, err = measure(Ui.overlay, host, app)
  if not ok then
    app.perf.errors = app.perf.errors + 1
    log('ERROR', 'ui_overlay', err)
  end
end

function script.SETUPLAB__DEBUG(_)
  if app.released then return end
  local ok, err = measure(Ui.debug, host, app)
  if not ok then
    app.perf.errors = app.perf.errors + 1
    log('ERROR', 'ui_debug', err)
  end
end
