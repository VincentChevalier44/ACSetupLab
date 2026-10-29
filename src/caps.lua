-- SetupLab — capacités CSP (D7, §3.2, §3.3) : présence des fonctions, évaluation des sondes
-- de découverte, horloge précise, rapport J0. L'hôte est injecté par la colle : aucune globale
-- CSP n'est lue ici, et aucune fonction d'écriture n'est appelée.

local Util = require('src/util')
local Config = require('src/config')
local K = Config.K

local M = {}

M.AVAILABLE = 'available'
M.PENDING = 'pending'
M.UNAVAILABLE = 'unavailable'
M.NA = 'na'

M.STATUS_LABEL = {
  available = 'disponible',
  pending = 'à confirmer',
  unavailable = 'indisponible',
  na = 'sans objet',
}

-- Fonctions lues ou appelées par SetupLab (tableau de vérité §3.2).
M.FUNCTIONS = {
  'ac.getPatchVersion', 'ac.getPatchVersionCode', 'ac.getSim', 'ac.getSession', 'ac.getCar', 'ac.getCarPhysics',
  'ac.getCarID', 'ac.getCarName', 'ac.getCarDataFiles', 'ac.INIConfig.carData', 'ac.INIConfig.trackData',
  'ac.DataLUT11.carData', 'ac.readDataFile', 'ac.getFolder', 'ac.getTrackID', 'ac.getTrackLayout',
  'ac.getTrackFullID', 'ac.getTrackName', 'ac.hasTrackSpline', 'ac.trackProgressToWorldCoordinate',
  'ac.getTrackAISplineSides', 'ac.worldCoordinateToTrackProgress', 'physics.raycastTrack',
  'ac.getSetupSpinners', 'ac.getSetupTabs', 'ac.stringifyCurrentSetup', 'ac.INIConfig.currentSetup',
  'ac.isSetupAvailableToEdit', 'ac.getCarSetupState', 'ac.getAssists', 'ac.getTyresName', 'ac.getTyresLongName',
  'ac.getCarMaxSpeedWithGear', 'ac.onSetupFile', 'ac.onLapCompleted', 'ac.onRelease', 'ac.storage',
  'ac.setClipboardText', 'ac.refreshSetups', 'io.available', 'io.load', 'io.save', 'io.fileExists', 'io.createFileDir',
  'io.isFileNameAcceptable', 'ac.loadSetup', 'ac.setMessage',
}

-- Fonctions présentes dans le SDK mais que SetupLab n'appelle jamais : elles modifieraient
-- le setup en cours (D8). Leur présence est seulement constatée. ac.loadSetup n'en fait plus partie
-- depuis l'amendement de D8 du 20/10/2026 (chargement d'un setup SetupLab, exporter.lua).
M.NEVER_CALLED = { 'ac.setSetupSpinnerValue', 'ac.saveCurrentSetup', 'ac.resetSetupToDefault', 'ac.setPitstopSpinnerValue',
  'physics.setTyresCompound', 'physics.setCarFuel' }

-- Une valeur est appelable si c'est une fonction Lua, une fonction C exposée en cdata
-- (constaté sur cette installation pour certaines fonctions CSP) ou une table à __call.
function M.isCallable(value, ffi)
  local kind = type(value)
  if kind == 'function' then return true end
  if kind == 'table' then
    local mt = getmetatable(value)
    return type(mt) == 'table' and mt.__call ~= nil
  end
  if kind ~= 'cdata' or ffi == nil or value == nil then return false end
  local ok, name = pcall(function() return tostring(ffi.typeof(value)) end)
  return ok and not name:find('[', 1, true) and name:match('%b()%s*>$') ~= nil
end

-- Résout « ac.INIConfig.carData » dans l'hôte injecté, sans lever d'erreur.
function M.resolve(host, path)
  local value = host
  for part in path:gmatch('[^%.]+') do
    value = Util.get(value, part)
    if value == nil then return nil end
  end
  return value
end

-- Horloge précise en secondes : QueryPerformanceCounter par FFI (lecture seule) ; sinon l'horloge officielle de CSP
-- (os.preciseClock, passée par la colle ; accord de Vincent du 29/10/2026 : CSP 0.3.1-preview2 bloque l'appel à
-- kernel32). Renvoie l'horloge, la raison si aucune, et la source.
local function qpcClock(ffi)
  if ffi == nil then return nil, 'FFI indisponible' end
  pcall(ffi.cdef, 'int QueryPerformanceCounter(int64_t*); int QueryPerformanceFrequency(int64_t*);')
  local okC, counter = pcall(function() return ffi.C.QueryPerformanceCounter end)
  local okF, frequency = pcall(function() return ffi.C.QueryPerformanceFrequency end)
  if not (okC and okF) then return nil, 'QueryPerformanceCounter introuvable' end
  local okB, buffer = pcall(ffi.new, 'int64_t[1]')
  if not okB then return nil, 'tampon FFI impossible' end
  local okQ, result = pcall(frequency, buffer)
  local freq = okQ and result ~= 0 and tonumber(buffer[0]) or nil
  if not Util.isFinite(freq) or freq <= 0 then return nil, 'fréquence invalide' end
  local function clock()
    counter(buffer)
    return tonumber(buffer[0]) / freq
  end
  local okA, a = pcall(clock)
  local okZ, z = pcall(clock)
  if not (okA and okZ and Util.isFinite(a) and Util.isFinite(z) and z >= a) then
    return nil, 'lectures incohérentes'
  end
  return clock, nil
end

function M.makeClock(ffi, preciseClock)
  local clock, why = qpcClock(ffi)
  if clock then return clock, nil, 'QueryPerformanceCounter via FFI' end
  if M.isCallable(preciseClock, ffi) then
    local okA, a = pcall(preciseClock)
    local okZ, z = pcall(preciseClock)
    if okA and okZ and Util.isFinite(a) and Util.isFinite(z) and z >= a then
      return function() return preciseClock() end, nil, 'horloge de CSP (os.preciseClock)'
    end
    why = why .. ' ; os.preciseClock incohérente'
  end
  return nil, why, nil
end

-- Décalage de l'heure locale de Windows sur l'heure universelle (s, heure d'été comprise), pour les noms
-- des fichiers enregistrés (os.date interdit, §16.2 ; ac.getTimeZoneOffset est celui du circuit) :
-- GetLocalTime et GetSystemTime de kernel32 lues par FFI, en lecture seule comme l'horloge (A2), écart
-- arrondi au quart d'heure. Renvoie une fonction relue à chaque appel (changement d'heure pendant la
-- séance) qui renvoie le décalage ou nil, ou bien nil et la raison.
function M.makeUtcOffset(ffi)
  if ffi == nil then return nil, 'FFI indisponible' end
  pcall(ffi.cdef, 'typedef struct { uint16_t wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute, wSecond, wMilliseconds; }'
    .. ' SETUPLAB_SYSTEMTIME;')
  pcall(ffi.cdef, 'void GetLocalTime(SETUPLAB_SYSTEMTIME*);')
  pcall(ffi.cdef, 'void GetSystemTime(SETUPLAB_SYSTEMTIME*);')
  local okL, getLocal = pcall(function() return ffi.C.GetLocalTime end)
  local okS, getSystem = pcall(function() return ffi.C.GetSystemTime end)
  if not (okL and okS and getLocal and getSystem) then return nil, 'GetLocalTime introuvable' end
  local okA, localTime = pcall(ffi.new, 'SETUPLAB_SYSTEMTIME[1]')
  local okB, systemTime = pcall(ffi.new, 'SETUPLAB_SYSTEMTIME[1]')
  if not (okA and okB) then return nil, 'tampon FFI impossible' end
  local function epoch(st)
    return Util.epochFromCivil(tonumber(st.wYear), tonumber(st.wMonth), tonumber(st.wDay), tonumber(st.wHour),
      tonumber(st.wMinute), tonumber(st.wSecond))
  end
  -- GetLocalTime peut être déjà déclarée par CSP avec sa propre structure (redéclaration refusée) : l'appel avec
  -- ce tampon échoue alors sur le type ; même disposition en mémoire (8 × uint16) : passé en void*
  local function fill(fn, buffer)
    if pcall(fn, buffer) then return true end
    local okC, raw = pcall(ffi.cast, 'void*', buffer)
    return okC and pcall(fn, raw)
  end
  local function offset()
    if not (fill(getLocal, localTime) and fill(getSystem, systemTime)) then return nil end
    local okE, diff = pcall(function() return epoch(localTime[0]) - epoch(systemTime[0]) end)
    if not (okE and Util.isFinite(diff)) then return nil end
    local rounded = math.floor(diff / K.utcOffsetStep + 0.5) * K.utcOffsetStep
    if math.abs(rounded) > K.utcOffsetMax then return nil end
    return rounded
  end
  if offset() == nil then return nil, 'lectures incohérentes' end
  return offset, nil
end

-- Sondes statiques : présence des fonctions, version, droits d'E/S, dossiers connus.
function M.probeStatic(host)
  local r = { functions = {}, presentCount = 0, missing = {}, neverCalled = {}, folders = {} }
  for _, path in ipairs(M.FUNCTIONS) do
    local ok = M.isCallable(M.resolve(host, path), host.ffi)
    r.functions[#r.functions + 1] = { path = path, ok = ok }
    if ok then r.presentCount = r.presentCount + 1 else r.missing[#r.missing + 1] = path end
  end
  for _, path in ipairs(M.NEVER_CALLED) do
    r.neverCalled[#r.neverCalled + 1] = { path = path, present = M.isCallable(M.resolve(host, path), host.ffi) }
  end
  local okV, version = Util.call(M.resolve(host, 'ac.getPatchVersion'))
  if okV and type(version) == 'string' then r.version = Util.truncate(version, 64) end
  local okN, code = Util.call(M.resolve(host, 'ac.getPatchVersionCode'))
  if okN and Util.isFinite(code) then r.versionCode = code end
  -- io.available absente (CSP 0.2.11, gratuite) : accès supposé, l'écriture relue fait foi (D17)
  local availableFn = M.resolve(host, 'io.available')
  if availableFn == nil then
    r.ioAvailable, r.ioAssumed = true, true
  else
    local okI, io = Util.call(availableFn)
    r.ioAvailable = okI and io == true
  end
  local getFolder = M.resolve(host, 'ac.getFolder')
  for _, name in ipairs({ 'UserSetups', 'ContentCars', 'CurrentTrackLayoutUI' }) do
    local id = M.resolve(host, 'ac.FolderID.' .. name)
    local okF, value = Util.call(getFolder, id)
    if id ~= nil and okF and type(value) == 'string' and value ~= '' then r.folders[name] = Util.truncate(value, 260) end
  end
  return r
end

-- ---------------------------------------------------------------------------
-- Évaluation (pure) des résultats de découverte -> liste des capacités
-- ---------------------------------------------------------------------------

local function relDiff(a, b)
  if not (Util.isFinite(a) and Util.isFinite(b)) or b == 0 then return nil end
  return (a - b) / b
end

local function countStatus(order, status)
  local ok, failures = 0, {}
  for _, name in ipairs(order) do
    local s = status[name] or ''
    if s:sub(1, 2) == 'ok' then ok = ok + 1 else failures[#failures + 1] = name .. ' (' .. s .. ')' end
  end
  return ok, failures
end

local function listText(items, maxItems)
  local shown = {}
  for i = 1, math.min(#items, maxItems or 6) do shown[i] = items[i] end
  local text = table.concat(shown, ', ')
  if #items > #shown then text = text .. ', …' end
  return text
end

function M.evaluate(static, d)
  local caps = { list = {}, byId = {} }
  local function add(id, label, status, detail)
    local entry = { id = id, label = label, status = status, detail = detail or '' }
    caps.list[#caps.list + 1] = entry
    caps.byId[id] = entry
  end
  static = static or {}
  local functions, missing = static.functions or {}, static.missing or {}
  local car, setup, track, files = d.car, d.setup, d.track, d.trackFiles
  local session, state = d.session, d.carState

  if static.version or static.versionCode then
    add('csp', 'Version CSP', M.AVAILABLE, tostring(static.version) .. ' (build ' .. tostring(static.versionCode) .. ')')
  else
    add('csp', 'Version CSP', M.PENDING, 'version non lue')
  end
  add('functions', 'Fonctions CSP utilisées', #functions > 0 and #missing == 0 and M.AVAILABLE or M.PENDING,
    (static.presentCount or 0) .. '/' .. #functions .. ' présentes'
    .. (#missing > 0 and (' ; absentes : ' .. listText(missing, 8)) or ''))

  -- Données voiture
  if car then
    local okIni, failIni = countStatus(car.iniOrder, car.iniStatus)
    if car.iniStatus['car.ini'] and car.iniStatus['car.ini']:sub(1, 2) == 'ok' and car.ini['tyres.ini'] then
      add('car_ini', 'Fichiers INI de la voiture', M.AVAILABLE, okIni .. '/' .. #car.iniOrder .. ' lus'
        .. (#failIni > 0 and (' ; non lus : ' .. listText(failIni)) or ''))
    else
      add('car_ini', 'Fichiers INI de la voiture', M.UNAVAILABLE,
        'car.ini ou tyres.ini illisible : mode « mesure uniquement » (§9.4)')
    end
    add('car_files', 'Liste des fichiers de données', car.dataFiles and M.AVAILABLE or M.PENDING,
      car.dataFiles and (#car.dataFiles .. ' fichiers') or ('liste indisponible : ' .. tostring(car.dataFilesReason)))
    local okLut, failLut = countStatus(car.lutOrder, car.lutStatus)
    local engine = car.ini['engine.ini']
    local powerName = engine and Util.iniGet(engine, 'HEADER', 'POWER_CURVE')
    powerName = type(powerName) == 'string' and powerName:lower() or nil
    if powerName and car.luts[powerName] then
      add('car_lut', 'Courbes (LUT) de la voiture', M.AVAILABLE, okLut .. '/' .. #car.lutOrder .. ' lues'
        .. (#failLut > 0 and (' ; échecs : ' .. listText(failLut)) or ''))
    else
      add('car_lut', 'Courbes (LUT) de la voiture', M.UNAVAILABLE,
        'courbe de puissance non lue (' .. tostring(powerName) .. ')')
    end
    if #car.ratioOrder == 0 then
      add('car_rto', 'Rapports de boîte proposés (.rto)', M.NA, 'aucun fichier .rto référencé par setup.ini')
    else
      local okRto, failRto = countStatus(car.ratioOrder, car.ratioStatus)
      add('car_rto', 'Rapports de boîte proposés (.rto)', okRto > 0 and M.AVAILABLE or M.UNAVAILABLE,
        okRto .. '/' .. #car.ratioOrder .. ' lus, chemin ' .. tostring(car.rawPathForm)
        .. (#failRto > 0 and (' ; échecs : ' .. listText(failRto)) or '')
        .. (okRto == 0 and ' : rapports exclus de l\'optimisation' or ''))
    end
  end

  -- Circuit
  if track then
    if track.ok and track.source == 'reconnaissance' then
      -- sans ligne IA : ligne reconstituée depuis un tour enregistré (§7.1 source 2, A14)
      add('track_spline', 'Géométrie : reconnaissance', M.PENDING, track.n .. ' points tirés d\'un tour enregistré ; '
        .. 'ligne IA absente, largeurs inconnues : confiance abaissée')
    elseif track.ok then
      add('track_spline', 'Géométrie : ligne IA', M.AVAILABLE, track.n .. ' points, pas ' .. Util.fmt(track.ds, 1)
        .. ' m' .. ((track.sideFailures or 0) > 0 and (' ; largeurs manquantes : ' .. track.sideFailures) or ''))
      local dSim = relDiff(track.lengthModel, track.lengthSim)
      local dDecl = files and relDiff(track.lengthModel, files.declared) or nil
      local detail = 'modèle ' .. Util.fmt(track.lengthModel, 0) .. ' m ; ligne IA ' .. Util.fmt(track.lengthSim, 0)
        .. ' m (' .. Util.fmt(dSim and dSim * 100, 2) .. ' %)'
      if files and files.declared then
        detail = detail .. ' ; déclarée ' .. Util.fmt(files.declared, 0) .. ' m (' .. Util.fmt(dDecl and dDecl * 100, 2) .. ' %)'
      end
      local okSim = dSim ~= nil and math.abs(dSim) <= K.trackLengthTolSim
      local okDecl = dDecl == nil or math.abs(dDecl) <= K.trackLengthTolDeclared
      add('track_length', 'Cohérence de longueur', (okSim and okDecl) and M.AVAILABLE or M.PENDING,
        detail .. ((okSim and okDecl) and '' or ' : confiance abaissée'))
    else
      add('track_spline', 'Géométrie : ligne IA', M.UNAVAILABLE, tostring(track.reason)
        .. ' : reconnaissance par tour enregistré nécessaire (§7.1)')
    end
  end
  if d.trackModel then
    local tm = d.trackModel
    add('track_model', 'Modèle du circuit', M.AVAILABLE, Util.fmt(tm.length, 0) .. ' m, ' .. tm.n .. ' points de '
      .. Util.fmt(tm.ds, 2) .. ' m ; ' .. tm.cornerCount .. ' virages (rayon mini ' .. Util.fmt(tm.minRadius, 0)
      .. ' m), ' .. #tm.drsZones .. ' zone(s) DRS ; dévers ' .. (tm.hasBank and 'sondé' or 'inconnu')
      .. ' ; confiance ' .. Util.fmt(tm.confidence * 100, 0) .. ' %'
      .. (#tm.warnings > 0 and (' (' .. table.concat(tm.warnings, ' ; ') .. ')') or ''))
  elseif d.trackModelReason then
    add('track_model', 'Modèle du circuit', M.UNAVAILABLE, tostring(d.trackModelReason))
  end
  if files then
    local surfaces = files.iniStatus['surfaces.ini'] == 'ok'
    local drs = files.ini['drs_zones.ini']
    add('track_data', 'Fichiers du circuit', surfaces and M.AVAILABLE or M.PENDING,
      'surfaces.ini : ' .. tostring(files.iniStatus['surfaces.ini']) .. ' ; drs_zones.ini : '
      .. (drs and (#drs.order .. ' zone(s)') or tostring(files.iniStatus['drs_zones.ini'])))
  end
  if d.raycast then
    add('raycast', 'Sondage vertical (raycast)', d.raycast.ok and M.AVAILABLE or M.PENDING,
      d.raycast.ok and ('sol à ' .. Util.fmt(d.raycast.distance, 2) .. ' m sous l\'origine') or tostring(d.raycast.reason))
  end

  -- Télémétrie
  if d.telemetry then
    local t = d.telemetry
    add('telemetry', 'Télémétrie du joueur', #t.missing == 0 and t.ok > 0 and M.AVAILABLE or M.PENDING,
      t.ok .. '/' .. #t.fields .. ' champs' .. (#t.missing > 0 and (' ; manquants : ' .. listText(t.missing, 8)) or '')
      .. (t.reason and (' ; ' .. t.reason) or ''))
  end

  -- Setup
  if setup then
    local visible, readOnly = 0, 0
    for _, sp in ipairs(setup.spinners) do
      if sp.visible ~= false then visible = visible + 1 end
      if sp.readOnly then readOnly = readOnly + 1 end
    end
    add('setup_read', 'Réglages : crans et plages', #setup.spinners > 0 and M.AVAILABLE or M.UNAVAILABLE,
      #setup.spinners > 0 and (#setup.spinners .. ' réglages, ' .. visible .. ' visibles, ' .. readOnly .. ' verrouillés')
      or ('aucun réglage lu : ' .. tostring(setup.spinnerReason)))
    add('setup_text', 'Contenu du setup courant', setup.file and M.AVAILABLE or M.UNAVAILABLE,
      setup.file and (#setup.file.order .. ' sections') or tostring(setup.textReason))
    local c = setup.comparison
    if c.consistent then
      add('setup_encoding', 'Cohérence crans ↔ fichier', M.AVAILABLE, c.matched .. '/' .. c.total .. ' identiques'
        .. (#c.missing > 0 and (' ; absents du fichier : ' .. listText(c.missing)) or ''))
    elseif #c.mismatched > 0 then
      local first = c.mismatched[1]
      add('setup_encoding', 'Cohérence crans ↔ fichier', M.UNAVAILABLE, #c.mismatched .. ' écart(s), ex. '
        .. first.name .. ' cran ' .. Util.fmt(first.spinner, 3) .. ' / fichier ' .. Util.fmt(first.file, 3)
        .. ' : ces réglages ne seront pas modifiés par l\'export (A12)')
    elseif #c.missingEditable > 0 then
      add('setup_encoding', 'Cohérence crans ↔ fichier', M.PENDING, c.matched .. '/' .. c.total .. ' identiques ; '
        .. #c.missingEditable .. ' réglage(s) modifiable(s) absent(s) du fichier : ' .. listText(c.missingEditable)
        .. ' (appariement des noms à établir ; d\'ici là, non modifiés par l\'export, A12)')
    else
      add('setup_encoding', 'Cohérence crans ↔ fichier', M.PENDING, 'comparaison impossible (crans ou fichier manquants)')
    end
    if d.space then
      local counts = { ['vérifié'] = 0, ['déduit'] = 0, ['écart'] = 0 }
      for _, var in ipairs(d.space.vars) do counts[var.status] = (counts[var.status] or 0) + 1 end
      local optimizable = #d.optimizable
      add('setup_space', 'Espace de setup (§10.3)', optimizable > 0 and M.AVAILABLE or M.UNAVAILABLE,
        optimizable .. ' réglages optimisables ; conversions vérifiées en jeu : ' .. counts['vérifié'] .. ', déduites : '
        .. counts['déduit'] .. ', en écart (exclues) : ' .. counts['écart'] .. ' ; non touchés : ' .. #d.space.skipped)
    end
    if d.rideFrame then
      local f = d.rideFrame
      local rows = {}
      for _, r in ipairs(f.rows) do
        rows[#rows + 1] = 'aile ' .. r.index .. ' : mesurée ' .. Util.fmt(r.measured * 1000, 0) .. ' mm, modèle '
          .. Util.fmt(r.model * 1000, 0) .. ' mm'
      end
      -- corrigé : un seul point statique ne vérifie ni la pente ni les unités de LUT_GH, à confirmer (§0.6)
      local ok = f.status == 'vérifié' or f.status == 'corrigé' or f.status == 'sans objet'
      add('ride_frame', 'Repère de hauteur de l\'aéro (hauteur de caisse)',
        (f.status == 'vérifié' or f.status == 'sans objet') and M.AVAILABLE or M.PENDING,
        f.status .. (f.reason and (' : ' .. f.reason) or '') .. (#rows > 0 and (' ; ' .. table.concat(rows, ' ; ')) or '')
          .. (ok and (' ; hauteur de caisse optimisable (recherche réduite' .. (f.status == 'corrigé' and ', à confirmer)' or ')'))
            or ' ; hauteur de caisse conservée'))
    end
    if d.carBase then
      local missing = d.carBaseMissing or {}
      add('car_model', 'Modèle de la voiture (§8.1)', #missing == 0 and M.AVAILABLE or M.UNAVAILABLE,
        #missing == 0 and (Util.fmt(d.carBase.massDry, 0) .. ' kg sans carburant, CG ' .. Util.fmt(d.carBase.cgHeight, 3)
          .. ' m (' .. tostring(d.carBase.sources.cgHeight) .. '), ' .. #d.carBase.compounds .. ' composé(s), '
          .. #d.carBase.gears .. ' rapports ; modèle non calibré')
        or ('paramètres manquants : ' .. listText(missing)))
    end
    local fixed = session and session.flags and session.flags.fixedSetup == true
    add('setup_state', 'Setup modifiable', (fixed or setup.editable == false) and M.PENDING or M.AVAILABLE,
      'modifiable : ' .. tostring(setup.editable) .. ' ; état : ' .. tostring(setup.legal)
      .. (fixed and ' ; setup imposé par la session : calcul informatif (D20)' or ''))
  end

  -- Écriture de fichiers de setup (D17) : capacité d'entrée/sortie seule, indépendante de
  -- l'encodage des crans (A12). « Disponible » uniquement après une écriture relue avec succès.
  local folderOk = static.folders and static.folders.UserSetups ~= nil
  local writeFns = M.hasAll(static, { 'io.save', 'io.load', 'io.fileExists', 'io.createFileDir' })
  local test = d.writeTest
  if static.ioAvailable and folderOk and writeFns then
    if test and test.ok then
      add('setup_write', 'Écriture de fichiers de setup', M.AVAILABLE, 'confirmée : ' .. tostring(test.path))
    elseif test then
      add('setup_write', 'Écriture de fichiers de setup', M.UNAVAILABLE, 'échec du test d\'écriture : '
        .. tostring(test.reason) .. ' : repli presse-papiers (D17)')
    else
      add('setup_write', 'Écriture de fichiers de setup', M.PENDING,
        'possible, non testée : cliquer « Enregistrer une copie du setup actuel » (dossier '
        .. static.folders.UserSetups .. ')')
    end
  else
    local why = {}
    if not static.ioAvailable then why[#why + 1] = 'pas d\'accès fichiers (io.available)' end
    if not folderOk then why[#why + 1] = 'dossier setups inconnu' end
    if not writeFns then why[#why + 1] = 'fonctions io absentes' end
    add('setup_write', 'Écriture de fichiers de setup', M.UNAVAILABLE, table.concat(why, ', ') .. ' : repli presse-papiers')
  end
  -- Chargement d'un setup SetupLab dans la voiture (D8 amendé) : « disponible » seulement après un
  -- chargement vérifié en jeu (setup en cours devenu identique au fichier) ; dernière issue en détail.
  local load, verified = d and d.loadTest, d and d.loadVerified
  local last = (load and not load.ok) and (' ; dernier essai : ' .. tostring(load.reason)) or ''
  if not M.hasAll(static, { 'ac.loadSetup' }) then
    add('setup_load', 'Chargement dans la voiture', M.UNAVAILABLE, 'ac.loadSetup absente : charger le fichier dans le menu de setup')
  elseif verified then
    add('setup_load', 'Chargement dans la voiture', M.AVAILABLE, 'vérifié : ' .. tostring(verified.path) .. last)
  elseif load then
    add('setup_load', 'Chargement dans la voiture', M.PENDING, 'dernier essai : ' .. tostring(load.reason))
  else
    add('setup_load', 'Chargement dans la voiture', M.PENDING,
      'possible, non testé : au stand, menu de setup ouvert, après l\'enregistrement d\'un setup')
  end
  add('clipboard', 'Presse-papiers', M.hasAll(static, { 'ac.setClipboardText' }) and M.AVAILABLE or M.UNAVAILABLE, '')
  -- persistance (§13) : confirmée quand des entrées d'une séance précédente ont été relues
  local store = d and d.store
  if not M.hasAll(static, { 'ac.storage' }) or (store and store.status ~= 'ouvert') then
    add('storage', 'Stockage persistant', M.UNAVAILABLE, store and tostring(store.reason or '') or '')
  elseif store and (store.loaded or 0) > 0 then
    add('storage', 'Stockage persistant', M.AVAILABLE, store.loaded .. ' entrée(s) relue(s) d\'une séance précédente'
      .. (store.reason and (' ; ' .. store.reason) or ''))
  else
    add('storage', 'Stockage persistant', M.PENDING, 'à confirmer : rien de relu d\'une séance précédente (réglages, '
      .. 'calibrations et rugosité enregistrés ; à vérifier au prochain lancement)')
  end

  -- Session et conditions (§11, D16)
  if session then
    if session.ok then
      local v = session.values
      add('session', 'Données de session', M.AVAILABLE, 'type ' .. tostring(v.raceSessionType) .. ', tours '
        .. tostring(session.session.laps) .. ', durée ' .. tostring(session.session.durationMinutes) .. ' min')
      local temps = Util.isFinite(v.ambientTemperature) and Util.isFinite(v.roadTemperature)
      add('conditions', 'Conditions de piste', temps and M.AVAILABLE or M.PENDING,
        'air ' .. Util.fmt(v.ambientTemperature, 1) .. ' °C, piste ' .. Util.fmt(v.roadTemperature, 1)
        .. ' °C, grip ' .. Util.fmt(v.roadGrip and v.roadGrip * 100, 1) .. ' %'
        .. (session.wet and ' ; piste mouillée : setups pluie (D16 amendé)' or ''))
    else
      add('session', 'Données de session', M.UNAVAILABLE, tostring(session.reason))
    end
  end

  -- DRS / ERS (D13). Présence : AC lui-même (drsPresent, kersPresent). Définition : drs.ini (aile
  -- WING_n), ers.ini ou kers.ini. « À confirmer » jusqu'à la validation du modèle sur deux formules
  -- (§8.9, J6b) : c'est la règle du PDR, pas une donnée manquante.
  if state and state.ok then
    local drs = car and M.describeDrsText(car) or 'données voiture absentes'
    local zones = files and files.ini['drs_zones.ini'] and #files.ini['drs_zones.ini'].order or 0
    local live = 'disponible maintenant : ' .. tostring(state.flags.drsAvailable) .. ', ouvert : '
      .. tostring(state.flags.drsActive)
    local model = d.drs and (d.drs.enabled and ('simulé dans ' .. d.drs.zones .. ' zone(s), EFFECT ' .. Util.fmt(d.drs.effect, 2)
      .. ' (H8 : part de l\'aile retirée volet ouvert)' .. (d.drs.limitG and (', LIMIT_G ' .. Util.fmt(d.drs.limitG, 2)) or ''))
      or ('non simulé : ' .. tostring(d.drs.reason))) or 'modèle non évalué'
    if d.drs and d.drs.notes and #d.drs.notes > 0 then model = model .. ' ; ' .. table.concat(d.drs.notes, ', ') end
    if state.flags.drsPresent then
      add('drs', 'DRS', M.PENDING, 'présent selon AC ; ' .. drs .. ' ; zones du circuit : ' .. zones .. ' ; ' .. live
        .. ' ; modèle : ' .. model .. ' ; à confirmer par des tours réels (§8.9)')
    elseif car and #car.drsInfo.wings > 0 then
      add('drs', 'DRS', M.PENDING, drs .. ', mais AC ne signale pas de DRS (drsPresent = ' .. tostring(state.flags.drsPresent)
        .. ')')
    else
      add('drs', 'DRS', M.NA, 'voiture sans DRS (' .. drs .. ')')
    end
    local ers = car and car.ersInfo or { files = {}, controllers = 0 }
    local ersText = (#ers.files > 0 and table.concat(ers.files, ' + ') or 'ni ers.ini ni kers.ini') .. ', '
      .. ers.controllers .. ' contrôleur(s) ctrl_ers' .. (ers.maxKjPerLap and (', ' .. Util.fmt(ers.maxKjPerLap, 0)
      .. ' kJ par tour') or '') .. (ers.mguh and ', MGU-H' or '') .. (ers.frontMotors and ', moteurs avant' or '')
    local ersModel = d.ers and (d.ers.enabled and 'simulé (H21 à H23 : couple, batterie, récupération)'
      or ('non simulé : ' .. tostring(d.ers.reason))) or 'modèle non évalué'
    if d.ers and d.ers.notes and #d.ers.notes > 0 then ersModel = ersModel .. ' ; ' .. table.concat(d.ers.notes, ', ') end
    if state.flags.kersPresent then
      add('ers', 'ERS / KERS', M.PENDING, 'présent selon AC (' .. Util.fmt(state.values.kersMaxKJ, 0) .. ' kJ) ; '
        .. ersText .. ' ; modèle : ' .. ersModel .. ' ; à confirmer par des tours réels (§8.9)')
    elseif #ers.files > 0 then
      add('ers', 'ERS / KERS', M.PENDING, ersText .. ', mais AC ne signale pas d\'ERS (kersPresent = '
        .. tostring(state.flags.kersPresent) .. ')')
    else
      add('ers', 'ERS / KERS', M.NA, 'voiture sans ERS/KERS')
    end
  end

  add('clock', 'Horloge précise (tranches de calcul)', d.clockOk and M.AVAILABLE or M.PENDING,
    d.clockOk and tostring(d.clockSource or 'QueryPerformanceCounter via FFI')
      or ('repli : quota fixe de travail par frame (' .. tostring(d.clockReason) .. ')'))
  return caps
end

-- Texte court de la définition du DRS (aile, réglages lus dans drs.ini).
function M.describeDrsText(car)
  local info = car.drsInfo
  if info == nil then return 'drs.ini non analysé' end
  if #info.wings == 0 then return 'drs.ini : ' .. tostring(info.status) .. ', aucune section WING_n' end
  local parts = {}
  for _, w in ipairs(info.wings) do
    parts[#parts + 1] = w.section .. (w.aeroName and (' « ' .. w.aeroName .. ' »') or '') .. ' [' .. w.text .. ']'
  end
  return 'aile mobile ' .. table.concat(parts, ' ; ')
end

function M.hasAll(static, paths)
  local present = {}
  for _, f in ipairs(static.functions or {}) do present[f.path] = f.ok end
  for _, path in ipairs(paths) do
    if not present[path] then return false end
  end
  return true
end

function M.countByStatus(caps)
  local counts = { available = 0, pending = 0, unavailable = 0, na = 0 }
  for _, entry in ipairs(caps.list) do counts[entry.status] = (counts[entry.status] or 0) + 1 end
  return counts
end

-- ---------------------------------------------------------------------------
-- Rapport J0 (texte à recoller dans la conversation de développement)
-- ---------------------------------------------------------------------------

local function v2s(v, decimals)
  if v == nil then return '—' end
  if type(v) == 'number' then
    if math.floor(v) == v and math.abs(v) < 1e9 then return tostring(v) end
    return Util.fmt(v, decimals or 4)
  end
  return tostring(v)
end

-- tick (facultatif) est appelé toutes les 8 lignes : le rapport se construit en tâche découpée.
function M.buildReport(info, d, logEntries, tick)
  local lines, size, truncated = {}, 0, false
  local function out(text)
    if truncated then return end
    if tick and #lines % 8 == 7 then tick() end
    text = tostring(text)
    if size + #text + 1 > K.maxReportChars then
      truncated = true
      lines[#lines + 1] = '[rapport tronqué]'
      return
    end
    lines[#lines + 1] = text
    size = size + #text + 1
  end
  local static = d.static or {}
  out('SetupLab ' .. tostring(info.appVersion) .. ' — rapport ' .. tostring(info.milestone))
  out('Date : ' .. tostring(info.date) .. ' ; CSP ' .. tostring(static.version) .. ' build ' .. tostring(static.versionCode)
    .. ' ; accès fichiers : ' .. tostring(static.ioAvailable))
  if d.car then out('Voiture : ' .. tostring(d.car.name) .. ' [' .. tostring(d.car.id) .. ']') end
  if d.trackFiles then
    local f = d.trackFiles
    out('Circuit : ' .. tostring(f.name) .. ' [' .. tostring(f.id) .. ' / ' .. tostring(f.layout) .. '] id complet '
      .. tostring(f.fullId))
  end
  out('Durée de la découverte : ' .. v2s(d.durationMs, 1) .. ' ms de calcul')
  out('Boucle de calcul appelée par : ' .. tostring(info.updateSource or '—'))
  local p = info.perf
  if p then
    out('Tranches : ' .. v2s(p.slices) .. ' ; max ' .. v2s(p.maxSliceMs, 3) .. ' ms ; au-delà de '
      .. v2s(K.sliceAlertMs) .. ' ms : ' .. v2s(p.slowSlices) .. ' ; unité la plus longue ' .. v2s(p.maxUnitMs, 3)
      .. ' ms ; coût moyen par frame ' .. v2s(p.avgMs, 3) .. ' ms ; horloge ' .. (p.clock and 'QPC' or 'quota'))
  end

  out('')
  out('== Capacités ==')
  for _, entry in ipairs((d.caps or { list = {} }).list) do
    out('[' .. M.STATUS_LABEL[entry.status] .. '] ' .. entry.id .. ' — ' .. entry.label .. ' : ' .. entry.detail)
  end

  out('')
  out('== Fonctions CSP ==')
  local missing = {}
  for _, f in ipairs(static.functions or {}) do
    if not f.ok then missing[#missing + 1] = f.path end
  end
  out('Présentes : ' .. tostring(static.presentCount) .. '/' .. #(static.functions or {})
    .. ' ; absentes : ' .. (#missing > 0 and table.concat(missing, ', ') or 'aucune'))
  for _, f in ipairs(static.neverCalled or {}) do
    out('Jamais appelée (D8) : ' .. f.path .. ' présente=' .. tostring(f.present))
  end
  local folderNames = {}
  for name in pairs(static.folders or {}) do folderNames[#folderNames + 1] = name end
  table.sort(folderNames)
  for _, name in ipairs(folderNames) do out('Dossier ' .. name .. ' : ' .. static.folders[name]) end

  if d.car then
    local car = d.car
    out('')
    out('== Données voiture ==')
    out('Fichiers listés : ' .. (car.dataFiles and #car.dataFiles or 0) .. ' ' .. tostring(car.dataFilesReason or ''))
    out('Appel CSP le plus long : ' .. tostring(car.slowestRead) .. ' (' .. v2s(car.slowestReadMs, 3) .. ' ms)')
    for _, name in ipairs(car.iniOrder) do
      local data = car.ini[name]
      out('INI ' .. name .. ' : ' .. tostring(car.iniStatus[name]) .. (data and (' (' .. #data.order .. ' sections)') or ''))
    end
    out('Format brut CSP de car.ini [BASIC] :')
    for _, line in ipairs(car.rawSample) do out('  ' .. line) end
    for _, name in ipairs(car.lutOrder) do
      local lut = car.luts[name]
      local text = 'LUT ' .. name .. ' : ' .. tostring(car.lutStatus[name])
      if lut then
        local x0, x1, y0, y1 = Util.lutRange(lut)
        text = text .. ' ; ' .. lut.n .. ' pts, x ' .. v2s(x0) .. '…' .. v2s(x1) .. ', y ' .. v2s(y0) .. '…' .. v2s(y1)
      end
      out(text)
    end
    local forms = {}
    for form in pairs(car.rawProbe) do forms[#forms + 1] = form end
    table.sort(forms)
    for _, form in ipairs(forms) do out('ac.readDataFile forme ' .. form .. ' : ' .. car.rawProbe[form]) end
    for _, name in ipairs(car.ratioOrder) do
      local entries = car.ratios[name]
      local text = 'RTO ' .. name .. ' : ' .. tostring(car.ratioStatus[name])
      if entries then
        text = text .. ' ; ' .. #entries .. ' rapports ' .. entries[1].label .. '=' .. v2s(entries[1].ratio)
          .. ' … ' .. entries[#entries].label .. '=' .. v2s(entries[#entries].ratio)
      end
      out(text)
    end
    local function iniLine(file, section, key)
      out('  ' .. file .. ' [' .. section .. '] ' .. key .. ' = ' .. tostring(Util.iniGet(car.ini[file], section, key)))
    end
    out('DRS : ' .. M.describeDrsText(car))
    if car.ersInfo then
      out('ERS : fichiers ' .. table.concat(car.ersInfo.files, ', ') .. ' ; contrôleurs ctrl_ers : ' .. car.ersInfo.controllers)
    end
    out('Valeurs de contrôle :')
    iniLine('car.ini', 'BASIC', 'TOTALMASS')
    iniLine('car.ini', 'FUEL', 'MAX_FUEL')
    iniLine('suspensions.ini', 'BASIC', 'WHEELBASE')
    iniLine('suspensions.ini', 'BASIC', 'CG_LOCATION')
    iniLine('suspensions.ini', 'FRONT', 'TRACK')
    iniLine('drivetrain.ini', 'TRACTION', 'TYPE')
    iniLine('drivetrain.ini', 'GEARS', 'COUNT')
    iniLine('tyres.ini', 'COMPOUND_DEFAULT', 'INDEX')
    iniLine('tyres.ini', 'FRONT', 'DY_REF')
    iniLine('brakes.ini', 'DATA', 'MAX_TORQUE')
    iniLine('engine.ini', 'HEADER', 'POWER_CURVE')
  end

  if d.carState then
    local st = d.carState
    out('')
    out('== État physique courant (lecture seule) ==')
    if not st.ok then out('indisponible : ' .. tostring(st.reason)) end
    local keys = {}
    for _, key in ipairs({ 'mass', 'fuel', 'maxFuel', 'brakeBias', 'differentialPreload', 'differentialPower',
      'differentialCoast', 'compoundIndex', 'absMode', 'absModes', 'tractionControlMode', 'tractionControlModes',
      'fuelMap', 'fuelMaps', 'aeroLiftFront', 'aeroLiftRear', 'aeroDrag', 'cgHeight', 'gearCount', 'tractionType',
      'rpmLimiter', 'minHeight', 'kersMaxKJ', 'mgukDeliveryCount', 'caster', 'fuelPerLap' }) do
      keys[#keys + 1] = key .. '=' .. v2s(st.values[key])
    end
    out(table.concat(keys, ' ; '))
    local flags = {}
    for _, key in ipairs({ 'physicsAvailable', 'drsPresent', 'kersPresent', 'extendedPhysics', 'isKunosCar',
      'isOpenWheeler', 'isInPit', 'isInPitlane', 'hasUserBrakeBias' }) do
      flags[#flags + 1] = key .. '=' .. tostring(st.flags[key])
    end
    out(table.concat(flags, ' ; '))
    for i, w in ipairs(st.wheels) do
      out('roue ' .. (i - 1) .. ' : carrossage ' .. v2s(w.camber) .. ' ; pincement ' .. v2s(w.toeIn)
        .. ' ; pression statique ' .. v2s(w.tyreStaticPressure) .. ' ; pression ' .. v2s(w.tyrePressure)
        .. ' ; rayon ' .. v2s(w.tyreRadius) .. ' ; largeur ' .. v2s(w.tyreWidth) .. ' ; T optimale '
        .. v2s(w.tyreOptimumTemperature) .. ' ; charge ' .. v2s(w.load) .. ' ; course de suspension (H16) '
        .. v2s(w.suspensionTravel))
    end
    out('hauteurs de caisse : ' .. v2s(st.rideHeight[1]) .. ' / ' .. v2s(st.rideHeight[2])
      .. ' ; rapport final ' .. v2s(st.finalRatio))
    local ratios = {}
    for i = 1, st.gearRatioCount or #st.gearRatios do ratios[i] = v2s(st.gearRatios[i]) end
    out('rapports engagés : ' .. table.concat(ratios, ' ; '))
    out('DRS : présent=' .. tostring(st.flags.drsPresent) .. ' disponible=' .. tostring(st.flags.drsAvailable)
      .. ' ouvert=' .. tostring(st.flags.drsActive) .. ' ; KERS/ERS : présent=' .. tostring(st.flags.kersPresent)
      .. ' en charge=' .. tostring(st.flags.kersCharging))
    for i, w in ipairs(st.wings) do
      out('aile ' .. (i - 1) .. ' : cd=' .. v2s(w.cd) .. ' cl=' .. v2s(w.cl) .. ' incidence=' .. v2s(w.aoa) .. ' angle='
        .. v2s(w.angle) .. ' hauteur=' .. v2s(w.groundHeight))
    end
  end

  if d.setup then
    local s = d.setup
    out('')
    out('== Setup ==')
    out('modifiable=' .. tostring(s.editable) .. ' ; état=' .. tostring(s.legal) .. ' ' .. tostring(s.illegalReason or '')
      .. ' ; crans=' .. #s.spinners .. ' ; sections fichier=' .. (s.file and #s.file.order or 0))
    out('nom | libellé | min | max | pas | valeur | mult | unités | clics | visible | verrou | défaut | items | fichier')
    for _, sp in ipairs(s.spinners) do
      local items = '—'
      if sp.items and #sp.items > 0 then
        items = #sp.items .. ' [' .. sp.items[1] .. ' … ' .. sp.items[#sp.items] .. ']'
      end
      if sp.itemValues and #sp.itemValues > 0 then
        items = items .. ' valeurs ' .. v2s(sp.itemValues[1]) .. '…' .. v2s(sp.itemValues[#sp.itemValues])
      end
      out(table.concat({ sp.name, sp.label, v2s(sp.min), v2s(sp.max), v2s(sp.step), v2s(sp.value),
        v2s(sp.displayMultiplier), tostring(sp.units or '—'), v2s(sp.showClicksMode), tostring(sp.visible),
        tostring(sp.readOnly), v2s(sp.defaultValue), items,
        tostring(Util.iniGet(s.file, sp.name, 'VALUE')) }, ' | '))
    end
    local c = s.comparison
    out('Comparaison : ' .. c.matched .. '/' .. c.total .. ' identiques ; écarts ' .. #c.mismatched
      .. ' ; absents du fichier ' .. #c.missing .. ' (' .. listText(c.missing, 40) .. ') dont modifiables '
      .. #c.missingEditable .. ' ; sections du fichier sans cran : ' .. listText(c.fileOnly, 40))
    for _, m in ipairs(c.mismatched) do
      out('  écart ' .. m.name .. ' : cran ' .. v2s(m.spinner) .. ' / fichier ' .. v2s(m.file))
    end
  end
  if d.space then
    out('')
    out('== Vérification des conversions crans -> physique (à confirmer en jeu) ==')
    out('réglage | cran actuel | valeur déduite | valeur mesurée par CSP | statut | classe | bornes (crans)')
    for _, row in ipairs(d.verifyRows or {}) do
      local var = d.space.byKey[row.key]
      out(table.concat({ row.key .. ' (' .. row.label .. ')', v2s(row.current), v2s(row.predicted, 5), v2s(row.measured, 5),
        tostring(row.status), tostring(var.class) .. (var.reason and (' : ' .. var.reason) or ''),
        v2s(var.lo) .. '..' .. v2s(var.hi) }, ' | '))
    end
    local skipped = {}
    for _, s in ipairs(d.space.skipped) do skipped[#skipped + 1] = s.name .. ' (' .. s.reason .. ')' end
    out('Non touchés : ' .. table.concat(skipped, ', '))
  end

  if d.track then
    local t = d.track
    out('')
    out('== Circuit ==')
    out('source ' .. t.source .. ' ; ok=' .. tostring(t.ok) .. ' ' .. tostring(t.reason or '') .. ' ; points ' .. t.n
      .. ' ; pas ' .. v2s(t.ds) .. ' ; échecs ' .. v2s(t.failures) .. ' ; largeurs manquantes ' .. v2s(t.sideFailures))
    out('longueurs : modèle ' .. v2s(t.lengthModel, 1) .. ' ; ligne IA ' .. v2s(t.lengthSim, 1) .. ' ; déclarée '
      .. v2s(d.trackFiles and d.trackFiles.declared, 1) .. ' (« ' .. tostring(d.trackFiles and d.trackFiles.declaredRaw)
      .. ' » ' .. tostring(d.trackFiles and d.trackFiles.declaredReason or '') .. ')')
    out('altitude ' .. v2s(t.altitudeMin, 1) .. ' … ' .. v2s(t.altitudeMax, 1) .. ' m ; largeur ' .. v2s(t.widthMin, 1)
      .. ' / ' .. v2s(t.widthMean, 1) .. ' / ' .. v2s(t.widthMax, 1) .. ' m ; boucle fermée ' .. tostring(t.open ~= true))
  end
  if d.trackModel then
    local tm = d.trackModel
    out('modèle : ' .. tm.n .. ' points, pas ' .. v2s(tm.ds, 3) .. ' m, longueur ' .. v2s(tm.length, 1) .. ' m, confiance '
      .. v2s(tm.confidence, 2) .. ', dévers ' .. tostring(tm.hasBank) .. ' (' .. tostring(d.track.bankReason or 'sondé')
      .. '), grip ' .. v2s(tm.surfaceGrip, 3) .. ' (' .. tm.surfaceSource .. ')')
    for i, seg in ipairs(tm.segments) do
      if i > 80 then
        out('  …')
        break
      end
      out('  ' .. seg.kind .. ' s=' .. v2s(seg.s0, 0) .. ' L=' .. v2s(seg.length, 0) .. (seg.kind == 'corner' and
        (' R=' .. v2s(seg.radius, 0) .. ' sens ' .. seg.dir .. (seg.chicane and ' chicane' or '')) or ''))
    end
    for _, z in ipairs(tm.drsZones) do
      out('  zone DRS ' .. z.name .. ' : ' .. v2s(z.start, 0) .. ' → ' .. v2s(z.finish, 0) .. ' m')
    end
  elseif d.trackModelReason then
    out('modèle : indisponible (' .. tostring(d.trackModelReason) .. ')')
  end
  if d.trackFiles then
    for _, name in ipairs(d.trackFiles.iniOrder) do
      out('fichier circuit ' .. name .. ' : ' .. tostring(d.trackFiles.iniStatus[name]))
    end
  end
  if d.raycast then
    out('raycast : ok=' .. tostring(d.raycast.ok) .. ' distance ' .. v2s(d.raycast.distance) .. ' ' .. tostring(d.raycast.reason or ''))
  end

  if d.session then
    local s = d.session
    out('')
    out('== Session ==')
    local values = {}
    for _, key in ipairs({ 'raceSessionType', 'currentSessionIndex', 'carsCount', 'ambientTemperature', 'roadTemperature',
      'roadGrip', 'rainIntensity', 'rainWetness', 'rainWater', 'windSpeedKmh', 'weatherType', 'trackLengthM', 'fps',
      'tyreConsumptionRate', 'fuelConsumptionRate' }) do
      values[#values + 1] = key .. '=' .. v2s(s.values and s.values[key])
    end
    out(table.concat(values, ' ; '))
    local flags = {}
    for _, key in ipairs({ 'isOnlineRace', 'isReplayActive', 'isWeatherFXActive', 'fixedSetup', 'isTrackOpen',
      'isTimedRace' }) do
      flags[#flags + 1] = key .. '=' .. tostring(s.flags and s.flags[key])
    end
    out(table.concat(flags, ' ; '))
    out('session : type=' .. v2s(s.session and s.session.type) .. ' tours=' .. v2s(s.session and s.session.laps)
      .. ' durée=' .. v2s(s.session and s.session.durationMinutes))
    if s.assists then
      out('aides : carburant x' .. v2s(s.assists.fuelRate) .. ' ; usure x' .. v2s(s.assists.tyresWear)
        .. ' ; aspiration x' .. v2s(s.assists.slipstream) .. ' ; couvertures ' .. tostring(s.assists.tyresBlankets)
        .. ' (échelles à confirmer : utilisées par le setup course, J6)')
    end
    for _, one in ipairs(s.sessions or {}) do
      out('séance ' .. v2s(one.index) .. ' : type=' .. v2s(one.type) .. ' tours=' .. v2s(one.laps) .. ' durée=' .. v2s(one.durationMinutes)
        .. ' chronométrée=' .. tostring(one.isTimedRace) .. ' tour additionnel=' .. tostring(one.hasAdditionalLap))
    end
  end
  -- composé monté (D18) : index CSP, position dans tyres.ini, nom
  if d.carBase then
    local slot = d.compoundSlot
    local c = slot and d.carBase.compounds[slot]
    out('composé monté : index ' .. v2s(d.compoundIndex) .. (c and (' = ' .. tostring(c.name) .. ' (' .. tostring(c.short) .. ')') or '')
      .. (d.compoundAssumed and ' — index illisible : composé par défaut' or '')
      .. (d.compoundProblem and (' — ' .. d.compoundProblem) or ''))
  end

  if d.telemetry then
    out('')
    out('== Télémétrie ==')
    local fields = {}
    for _, f in ipairs(d.telemetry.fields) do fields[#fields + 1] = f.name .. (f.ok and '' or ' ✗') end
    out(table.concat(fields, ' ; '))
  end

  out('')
  out('== Journal (avertissements et erreurs) ==')
  for _, e in ipairs(logEntries or {}) do
    if e.level == 'ERROR' or e.level == 'WARN' then
      out(Util.fmt(e.t, 1) .. ' s ' .. e.level .. ' ' .. e.code .. ' : ' .. e.text)
    end
  end
  return table.concat(lines, '\n'), truncated
end

return M
