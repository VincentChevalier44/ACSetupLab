-- SetupLab — lecture voiture / circuit / session / setup -> tables pures (D5, §3.2).
-- Seul module de lecture de l'API CSP ; l'hôte (ac, physics, io…) est injecté par la colle.
-- Toute donnée externe est non fiable (D11) : appels protégés, tailles bornées, valeurs validées.
-- Aucune écriture : ni fichier, ni setup, ni presse-papiers.

local Util = require('src/util')
local Config = require('src/config')
local K = Config.K

local M = {}

local floor, min, huge = math.floor, math.min, math.huge

-- ---------------------------------------------------------------------------
-- Accès protégés (un champ absent d'une structure FFI lève une erreur)
-- ---------------------------------------------------------------------------

local get, call = Util.get, Util.call

local function num(object, key)
  local v = get(object, key)
  if type(v) == 'cdata' then v = tonumber(v) end
  if Util.isFinite(v) then return v end
  return nil
end

local function bool(object, key)
  local v = get(object, key)
  if type(v) == 'boolean' then return v end
  if type(v) == 'cdata' then v = tonumber(v) end
  if type(v) == 'number' and v == v then return v ~= 0 end
  return nil
end

local function str(object, key, maxLength)
  local v = get(object, key)
  if type(v) == 'string' then return Util.truncate(v, maxLength or 128) end
  return nil
end

local function length(object)
  local ok, n = pcall(function() return #object end)
  if ok and Util.isFinite(n) and n >= 0 then return floor(n) end
  return 0
end

local function callString(fn, ...)
  local ok, v = call(fn, ...)
  if ok and type(v) == 'string' then return Util.truncate(v, 128) end
  return nil
end

local function folder(ac, folderName)
  local id = get(get(ac, 'FolderID'), folderName)
  if id == nil then return nil end
  local value = callString(get(ac, 'getFolder'), id)
  if value == nil or value == '' then return nil end
  return value
end

-- ---------------------------------------------------------------------------
-- Normalisation des INI renvoyés par ac.INIConfig (sections<nom, clés<nom, string[]>>)
-- ---------------------------------------------------------------------------

local function joinValue(v)
  local kind = type(v)
  if kind == 'string' then return Util.truncate(v, K.maxValueChars) end
  if kind == 'number' then
    if Util.isFinite(v) then return tostring(v) end
    return nil
  end
  if kind == 'boolean' then return v and '1' or '0' end
  if kind == 'table' then
    local parts = {}
    for i = 1, min(#v, 64) do
      local p = v[i]
      if type(p) == 'string' or (type(p) == 'number' and Util.isFinite(p)) then parts[#parts + 1] = tostring(p) end
    end
    return Util.truncate(table.concat(parts, ','), K.maxValueChars)
  end
  return nil
end

-- Copie bornée en table pure { sections = { [SECTION] = { [CLE] = 'texte' } }, order = {...} }.
-- Les listes découpées par CSP sont rejointes par des virgules : le format interne est le même
-- que celui d'un INI analysé depuis un texte (Util.parseIni). tick (facultatif) : par section.
function M.normalizeSections(sections, tick)
  local out = { sections = {}, order = {}, truncated = false }
  if type(sections) ~= 'table' then return out end
  local names = {}
  for name in pairs(sections) do
    if type(name) == 'string' and #name <= 128 then
      if #names >= K.maxIniSections then
        out.truncated = true
        break
      end
      names[#names + 1] = name
    end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    if tick then tick() end
    local source = sections[name]
    if type(source) == 'table' then
      local keys = {}
      for key in pairs(source) do
        if type(key) == 'string' and #key <= 128 then
          if #keys >= K.maxIniKeys then
            out.truncated = true
            break
          end
          keys[#keys + 1] = key
        end
      end
      local target = {}
      for _, key in ipairs(keys) do
        local value = joinValue(source[key])
        if value ~= nil then target[key] = value end
      end
      out.sections[name] = target
      out.order[#out.order + 1] = name
    end
  end
  return out
end

-- Description du format brut d'une section (rapport J0 : forme exacte des valeurs CSP).
function M.describeRaw(sections, sectionName, maxKeys)
  local lines = {}
  local section = type(sections) == 'table' and sections[sectionName] or nil
  if type(section) ~= 'table' then return lines end
  local keys = {}
  for key in pairs(section) do
    if type(key) == 'string' then keys[#keys + 1] = key end
  end
  table.sort(keys)
  for i = 1, min(#keys, maxKeys or 6) do
    local v = section[keys[i]]
    local items = {}
    if type(v) == 'table' then
      for j = 1, min(#v, 6) do items[#items + 1] = tostring(v[j]) end
      lines[#lines + 1] = keys[i] .. ' : table[' .. #v .. '] ' .. table.concat(items, ' ¦ ')
    else
      lines[#lines + 1] = keys[i] .. ' : ' .. type(v) .. ' ' .. tostring(v)
    end
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- Voiture (§8.1)
-- ---------------------------------------------------------------------------

-- Fichiers INI utiles au calcul ; les contrôleurs « ctrl_*.ini » (ERS, freins…) s'y ajoutent.
M.CAR_INI_FILES = {
  'car.ini', 'engine.ini', 'drivetrain.ini', 'tyres.ini', 'aero.ini', 'brakes.ini',
  'suspensions.ini', 'setup.ini', 'electronics.ini', 'drs.ini', 'ers.ini', 'kers.ini', 'fuel_cons.ini',
}

local function copyStrings(list, maxItems)
  local out = {}
  for i = 1, min(length(list), maxItems) do
    local v = get(list, i)
    if type(v) == 'string' and #v <= 128 then out[#out + 1] = v end
  end
  return out
end

-- Liste des INI à lire : la liste de base, filtrée par les fichiers réellement présents
-- quand CSP les fournit, plus les contrôleurs présents.
function M.carIniNames(dataFiles)
  local names, present = {}, nil
  if dataFiles then
    present = {}
    for _, f in ipairs(dataFiles) do present[f:lower()] = f end
  end
  for _, name in ipairs(M.CAR_INI_FILES) do
    if present == nil or present[name] then names[#names + 1] = name end
  end
  if dataFiles then
    local extra = {}
    for _, f in ipairs(dataFiles) do
      local lower = f:lower()
      if lower:find('^ctrl_[%w_%-%.]*%.ini$') then extra[#extra + 1] = lower end
    end
    table.sort(extra)
    for _, f in ipairs(extra) do
      if #names >= K.maxCarIniFiles then break end
      names[#names + 1] = f
    end
  end
  return names
end

-- Noms de LUT référencés par les INI lus (valeurs « *.lut »), sans doublon, bornés.
function M.collectLutNames(ini, tick)
  local seen, names = {}, {}
  local files = {}
  for name in pairs(ini) do files[#files + 1] = name end
  table.sort(files)
  for _, file in ipairs(files) do
    local data = ini[file]
    for _, section in ipairs(data.order) do
      if tick then tick() end
      local keys = {}
      for key in pairs(data.sections[section]) do keys[#keys + 1] = key end
      table.sort(keys)
      for _, key in ipairs(keys) do
        local value = data.sections[section][key]
        local name = type(value) == 'string' and value:lower():match('^%s*(.-%.lut)%s*$') or nil
        if name and Util.isSafeId(name) and not seen[name] then
          if #names >= K.maxLutFiles then return names end
          seen[name] = true
          names[#names + 1] = name
        end
      end
    end
  end
  return names
end

-- Fichiers .rto référencés par setup.ini (clés RATIOS des sections de boîte).
function M.collectRtoNames(setupIni)
  local names, seen = {}, {}
  if setupIni == nil then return names end
  for _, section in ipairs(setupIni.order) do
    local value = setupIni.sections[section].RATIOS
    local name = type(value) == 'string' and value:lower():match('^%s*(.-%.rto)%s*$') or nil
    if name and Util.isSafeId(name) and not seen[name] and #names < K.maxRtoFiles then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  return names
end

-- Points d'une LUT CSP (ac.DataLUT11) recopiés en LUT pure.
local function lutFromHandle(handle, tick)
  local getIn, getOut = get(handle, 'getPointInput'), get(handle, 'getPointOutput')
  if getIn == nil or getOut == nil then return nil, 'format inconnu' end
  local xs, ys = {}, {}
  for i = 0, K.maxLutPoints - 1 do
    if i % 256 == 255 then tick() end
    local okx, x = pcall(getIn, handle, i)
    local oky, y = pcall(getOut, handle, i)
    if not (okx and oky) or not Util.isFinite(x) or not Util.isFinite(y) then break end
    xs[#xs + 1], ys[#ys + 1] = x, y
  end
  local lut = Util.lutNew(xs, ys, K.maxLutPoints)
  if lut == nil then return nil, 'vide' end
  return lut, nil
end

-- Formes de chemin essayées avec ac.readDataFile (forme acceptée : sonde J0).
function M.rawPathCandidates(host, carId, name)
  local list = {}
  local root = folder(host.ac, 'ContentCars')
  if root then list[#list + 1] = { form = 'absolu', path = root .. '/' .. carId .. '/data/' .. name } end
  list[#list + 1] = { form = 'relatif', path = 'content/cars/' .. carId .. '/data/' .. name }
  return list
end

-- Texte brut d'un fichier de données voiture via ac.readDataFile (data.acd compris).
function M.readRaw(host, car, name, tick)
  if not car.safeId or not Util.isSafeId(name) then return nil, 'nom refusé' end
  local readDataFile = get(host.ac, 'readDataFile')
  if readDataFile == nil then return nil, 'ac.readDataFile absent' end
  local candidates = M.rawPathCandidates(host, car.id, name)
  if car.rawPathForm then
    table.sort(candidates, function(a, b) return a.form == car.rawPathForm and b.form ~= car.rawPathForm end)
  end
  for _, candidate in ipairs(candidates) do
    local ok, text = call(readDataFile, candidate.path)
    tick(K.tickWeightApiCall)
    if ok and type(text) == 'string' and #text > 0 then
      car.rawPathForm = car.rawPathForm or candidate.form
      car.rawProbe[candidate.form] = 'ok'
      return Util.truncate(text, K.maxTextBytes), nil
    end
    car.rawProbe[candidate.form] = car.rawProbe[candidate.form] or (ok and 'vide' or ('erreur : ' .. tostring(text)))
  end
  return nil, 'illisible'
end

function M.readCar(host, carIndex, ctx)
  local ac = host.ac
  local car = {
    index = carIndex, id = nil, name = nil, safeId = false,
    dataFiles = nil, dataFilesReason = nil,
    ini = {}, iniStatus = {}, iniOrder = {},
    luts = {}, lutStatus = {}, lutOrder = {},
    ratios = {}, ratioStatus = {}, ratioOrder = {},
    rawPathForm = nil, rawProbe = {}, rawSample = {},
    slowestRead = nil, slowestReadMs = 0,   -- appel CSP le plus long (budget de frame en jeu)
  }
  car.id = callString(get(ac, 'getCarID'), carIndex)
  car.safeId = Util.isSafeId(car.id)
  car.name = callString(get(ac, 'getCarName'), carIndex, true)

  local ok, list = call(get(ac, 'getCarDataFiles'), carIndex)
  if ok and type(list) == 'table' then
    local files = copyStrings(list, K.maxDataFiles)
    if #files > 0 then
      car.dataFiles = files
    else
      car.dataFilesReason = 'liste vide (échec CSP) : liste de base utilisée'
    end
  else
    car.dataFilesReason = ok and 'format inattendu' or list
  end

  local carData = get(get(ac, 'INIConfig'), 'carData')
  for _, name in ipairs(M.carIniNames(car.dataFiles)) do
    ctx.tick()
    car.iniOrder[#car.iniOrder + 1] = name
    local started = ctx.now()
    local okc, cfg = call(carData, carIndex, name)
    local sections = okc and get(cfg, 'sections') or nil
    ctx.tick(K.tickWeightApiCall)
    if started then
      local ms = (ctx.now() - started) * 1000
      if ms > car.slowestReadMs then car.slowestReadMs, car.slowestRead = ms, name end
    end
    if not okc then
      car.iniStatus[name] = 'erreur : ' .. tostring(cfg)
    else
      local okn, data = pcall(M.normalizeSections, sections, ctx.tick)
      if not okn then
        car.iniStatus[name] = 'erreur : format'
      elseif #data.order == 0 then
        car.iniStatus[name] = 'vide'
      else
        car.ini[name] = data
        car.iniStatus[name] = data.truncated and 'ok (tronqué)' or 'ok'
        if name == 'car.ini' then
          local okd, lines = pcall(M.describeRaw, sections, 'BASIC', 6)
          if okd then car.rawSample = lines end
        end
      end
    end
  end

  local lutLoader = get(get(ac, 'DataLUT11'), 'carData')
  for _, name in ipairs(M.collectLutNames(car.ini, ctx.tick)) do
    ctx.tick()
    car.lutOrder[#car.lutOrder + 1] = name
    local started = ctx.now()
    local okl, handle = call(lutLoader, carIndex, name)
    ctx.tick(K.tickWeightApiCall)
    if started then
      local ms = (ctx.now() - started) * 1000
      if ms > car.slowestReadMs then car.slowestReadMs, car.slowestRead = ms, name end
    end
    local lut, reason = nil, nil
    if okl and handle ~= nil then
      lut, reason = lutFromHandle(handle, ctx.tick)
    else
      reason = okl and 'nil' or handle
    end
    if lut == nil then
      local text, why = M.readRaw(host, car, name, ctx.tick)
      if text then
        lut = Util.parseLutText(text, K.maxLutPoints, ctx.tick)
        reason = lut and nil or 'texte illisible'
      else
        reason = tostring(reason) .. ', brut : ' .. tostring(why)
      end
      if lut then car.lutStatus[name] = 'ok (texte brut)' end
    else
      car.lutStatus[name] = 'ok'
    end
    if lut then
      car.luts[name] = lut
    else
      car.lutStatus[name] = 'échec : ' .. tostring(reason)
    end
  end

  for _, name in ipairs(M.collectRtoNames(car.ini['setup.ini'])) do
    ctx.tick()
    car.ratioOrder[#car.ratioOrder + 1] = name
    local text, why = M.readRaw(host, car, name, ctx.tick)
    if text then
      local entries = Util.parseRto(text, K.maxRtoEntries, ctx.tick)
      if #entries > 0 then
        car.ratios[name] = entries
        car.ratioStatus[name] = 'ok'
      else
        car.ratioStatus[name] = 'vide'
      end
    else
      car.ratioStatus[name] = 'échec : ' .. tostring(why)
    end
  end
  car.drsInfo = M.describeDrs(car)
  car.ersInfo = M.describeErs(car)
  return car
end

-- DRS tel que le définit AC (chaînes de acs.exe, API_NOTES §3) : drs.ini désigne l'aile mobile par une
-- section WING_n (clés lues par AC : EFFECT, DRS_ZONES, IGNORE_ZONES, DEACTIVATION, LIMIT_G…). La
-- présence effective est donnée par AC lui-même (car.drsPresent).
function M.describeDrs(car)
  local d = { status = car.iniStatus['drs.ini'] or 'absent', wings = {} }
  local drs, aero = car.ini['drs.ini'], car.ini['aero.ini']
  if drs == nil then return d end
  for _, section in ipairs(drs.order) do
    local index = tonumber(section:match('^WING_(%d+)$'))
    if index then
      local keys, names = drs.sections[section], {}
      for key in pairs(keys) do names[#names + 1] = key end
      table.sort(names)
      local pairsText = {}
      for _, key in ipairs(names) do pairsText[#pairsText + 1] = key .. '=' .. keys[key] end
      d.wings[#d.wings + 1] = {
        index = index, section = section, keys = keys, text = table.concat(pairsText, ', '),
        aeroName = Util.iniGet(aero, section, 'NAME'), aeroAngle = Util.iniNumber(aero, section, 'ANGLE', nil),
      }
    end
  end
  return d
end

-- ERS / KERS : AC lit ers.ini (KINETIC, HEAT, FRONT_MOTORS + contrôleurs ctrl_ers_*.ini) ou l'ancien
-- kers.ini.
function M.describeErs(car)
  local e = { files = {}, controllers = 0 }
  for _, name in ipairs({ 'ers.ini', 'kers.ini' }) do
    if car.ini[name] then e.files[#e.files + 1] = name end
  end
  for name in pairs(car.ini) do
    if name:find('^ctrl_ers_') then e.controllers = e.controllers + 1 end
  end
  e.maxKjPerLap = Util.iniNumber(car.ini['ers.ini'], 'KINETIC', 'MAX_KJ_PER_LAP', nil)
  e.mguh = car.ini['ers.ini'] ~= nil and car.ini['ers.ini'].sections.HEAT ~= nil
  e.frontMotors = car.ini['ers.ini'] ~= nil and car.ini['ers.ini'].sections.FRONT_MOTORS ~= nil
  return e
end

-- État physique courant (preuves de conversion crans -> grandeurs, sondes J0, lecture seule).
M.CAR_STATE_NUMBERS = {
  'mass', 'fuel', 'maxFuel', 'brakeBias', 'brakesBiasLimitDown', 'brakesBiasLimitUp', 'brakesBiasStep',
  'differentialPreload', 'differentialPower', 'differentialCoast', 'compoundIndex', 'absMode', 'absModes',
  'tractionControlMode', 'tractionControlModes', 'fuelMap', 'fuelMaps', 'aeroLiftFront', 'aeroLiftRear',
  'aeroDrag', 'cgHeight', 'gearCount', 'tractionType', 'enginePosition', 'rpmLimiter', 'rpmMinimum',
  'minHeight', 'ballast', 'restrictor', 'kersMaxKJ', 'kersCurrentKJ', 'mgukDelivery', 'mgukDeliveryCount',
  'mgukRecovery', 'caster', 'steerLock', 'fuelPerLap', 'engineBrakeSettingsCount', 'currentEngineBrakeSetting',
}
M.CAR_STATE_FLAGS = {
  'physicsAvailable', 'drsPresent', 'drsAvailable', 'drsActive', 'kersPresent', 'kersCharging', 'hasUserBrakeBias',
  'extendedPhysics', 'isKunosCar', 'isOpenWheeler', 'isInPit', 'isInPitlane', 'adjustableTurbo', 'brakesCockpitBias',
  'hasCockpitERSDelivery', 'hasCockpitERSRecovery', 'hasCockpitMGUHMode', 'hasEngineBrakeSettings',
}
M.WHEEL_NUMBERS = {
  'camber', 'toeIn', 'tyreStaticPressure', 'tyrePressure', 'tyreRadius', 'tyreWidth', 'rimRadius',
  'tyreOptimumTemperature', 'tyreCoreTemperature', 'load', 'tyreWear', 'tyreVirtualKM', 'tyreLoadedRadius',
  'suspensionTravel',
}

function M.readCarState(host, carIndex)
  local ac = host.ac
  local state = {
    ok = false, values = {}, flags = {}, wheels = {}, rideHeight = {}, gearRatios = {}, gearRatioCount = 0, finalRatio = nil,
    wings = {},
  }
  local ok, car = call(get(ac, 'getCar'), carIndex)
  if not ok or car == nil then
    state.reason = ok and 'voiture absente' or car
    return state
  end
  for _, key in ipairs(M.CAR_STATE_NUMBERS) do state.values[key] = num(car, key) end
  for _, key in ipairs(M.CAR_STATE_FLAGS) do state.flags[key] = bool(car, key) end
  local wheels = get(car, 'wheels')
  for i = 0, 3 do
    local wheel = get(wheels, i)
    local w = {}
    for _, key in ipairs(M.WHEEL_NUMBERS) do w[key] = num(wheel, key) end
    state.wheels[i + 1] = w
  end
  local rh = get(car, 'rideHeight')
  state.rideHeight = { num(rh, 0), num(rh, 1) }
  local okp, physics = call(get(ac, 'getCarPhysics'), carIndex)
  if okp and physics ~= nil then
    state.physicsAvailable = bool(physics, 'isAvailable')
    state.finalRatio = num(physics, 'finalRatio')
    state.gearRatio = num(physics, 'gearRatio')
    local ratios = get(physics, 'gearRatios')
    state.gearRatioCount = min(length(ratios), K.maxGearRatios)
    for i = 0, state.gearRatioCount - 1 do
      state.gearRatios[i + 1] = num(ratios, i)
    end
    -- Ailes en direct (ac.StateWingPhysics) : base de la mesure de l'effet du DRS (§8.9).
    local wings = get(physics, 'wings')
    local highest = 0
    for i = 0, min(length(wings), K.maxWings) - 1 do
      local wing = get(wings, i)
      state.wings[i + 1] = {
        cd = num(wing, 'cd'), cl = num(wing, 'cl'), aoa = num(wing, 'aoa'), angle = num(wing, 'angle'),
        groundHeight = num(wing, 'groundHeight'),
      }
      local h = state.wings[i + 1].groundHeight
      if h and h > highest then highest = h end
    end
    -- hauteur au sol en millimètres (CSP 0.3.1-preview2, rapport J0 du 29/10/2026 : 64,11 pour 64 mm) : aucune aile
    -- n'est à plus de 3 m du sol, les hauteurs sont alors ramenées en mètres
    if highest > 3 then
      state.wingHeightUnit = 'mm'
      for _, w in ipairs(state.wings) do
        if w.groundHeight then w.groundHeight = w.groundHeight / 1000 end
      end
    end
  end
  state.ok = true
  return state
end

-- Champs de télémétrie dont l'enregistreur aura besoin (§9.1), vérifiés un par un (§3.2).
M.TELEMETRY_CAR = {
  'speedMs', 'rpm', 'gear', 'gas', 'brake', 'steer', 'fuel', 'splinePosition', 'lapTimeMs', 'lapCount', 'wheelsOutside',
}
M.TELEMETRY_WHEEL = {
  'load', 'tyreCoreTemperature', 'tyreInsideTemperature', 'tyreMiddleTemperature', 'tyreOutsideTemperature',
  'tyrePressure', 'slipRatio', 'slipAngle', 'ndSlip', 'tyreWear',
}

function M.telemetryCheck(host, carIndex)
  local result = { ok = 0, missing = {}, fields = {} }
  local okc, car = call(get(host.ac, 'getCar'), carIndex)
  if not okc or car == nil then
    result.reason = 'ac.getCar indisponible'
    return result
  end
  local function check(label, value)
    local good = value ~= nil
    result.fields[#result.fields + 1] = { name = label, ok = good }
    if good then result.ok = result.ok + 1 else result.missing[#result.missing + 1] = label end
  end
  for _, key in ipairs(M.TELEMETRY_CAR) do check(key, num(car, key)) end
  local acc = get(car, 'acceleration')
  check('acceleration.x', num(acc, 'x'))
  check('acceleration.z', num(acc, 'z'))
  check('isLapValid', type(get(car, 'isLapValid')) == 'boolean' or nil)
  local wheel = get(get(car, 'wheels'), 0)
  for _, key in ipairs(M.TELEMETRY_WHEEL) do check('wheels[0].' .. key, num(wheel, key)) end
  return result
end

-- ---------------------------------------------------------------------------
-- Setup courant (§10.3, §12.3) : crans CSP + contenu exact du fichier de setup
-- ---------------------------------------------------------------------------

local function copyNumberList(list, maxItems)
  local out = {}
  for i = 1, min(length(list), maxItems) do
    local v = get(list, i)
    if Util.isFinite(v) then out[#out + 1] = v end
  end
  return out
end

function M.copySpinner(raw)
  local name = str(raw, 'name', 64)
  local value, lo, hi = num(raw, 'value'), num(raw, 'min'), num(raw, 'max')
  if name == nil or value == nil or lo == nil or hi == nil then return nil end
  local items = get(raw, 'items')
  local itemValues = get(raw, 'itemValues')
  return {
    name = name,
    label = str(raw, 'label', 96) or name,
    min = lo, max = hi, value = value,
    step = num(raw, 'step'),
    displayMultiplier = num(raw, 'displayMultiplier'),
    defaultValue = num(raw, 'defaultValue'),
    showClicksMode = num(raw, 'showClicksMode'),
    visible = bool(raw, 'visible'),
    readOnly = bool(raw, 'readOnly'),
    units = str(raw, 'units', 24),
    items = items ~= nil and copyStrings(items, K.maxSpinnerItems) or nil,
    itemValues = itemValues ~= nil and copyNumberList(itemValues, K.maxSpinnerItems) or nil,
  }
end

-- Vérifie que chaque cran CSP vaut la valeur VALUE du fichier de setup courant (même encodage).
function M.compareSetup(spinners, file, tick)
  local r = {
    total = #spinners, matched = 0, mismatched = {}, missing = {}, missingEditable = {}, fileOnly = {}, consistent = false,
  }
  local named = {}
  for i, sp in ipairs(spinners) do
    if tick and i % 32 == 0 then tick() end
    named[sp.name] = true
    local value = Util.parseNumber(Util.iniGet(file, sp.name, 'VALUE'))
    if value == nil then
      r.missing[#r.missing + 1] = sp.name
      if sp.visible ~= false and sp.readOnly ~= true then r.missingEditable[#r.missingEditable + 1] = sp.name end
    elseif math.abs(value - sp.value) <= K.setupValueTol then
      r.matched = r.matched + 1
    else
      r.mismatched[#r.mismatched + 1] = { name = sp.name, spinner = sp.value, file = value }
    end
  end
  if file then
    for _, section in ipairs(file.order) do
      if not named[section] and file.sections[section].VALUE ~= nil then r.fileOnly[#r.fileOnly + 1] = section end
    end
  end
  r.consistent = r.matched > 0 and #r.mismatched == 0 and #r.missingEditable == 0
  return r
end

-- Crans de setup assainis (copySpinner), plafonnés à K.maxSetupSpinners : la même lecture sert à la
-- découverte et à la signature du setup en roulant (sinon une signature pourrait diverger en silence).
function M.readSpinners(host, tick)
  local ok, list = call(get(host.ac, 'getSetupSpinners'))
  if not ok or type(list) ~= 'table' then return nil, ok and 'format inattendu' or list end
  local spinners = {}
  for i = 1, min(length(list), K.maxSetupSpinners) do
    if tick then tick() end
    local spinner = M.copySpinner(get(list, i))
    if spinner then spinners[#spinners + 1] = spinner end
  end
  return spinners
end

function M.readSetup(host, ctx)
  local ac = host.ac
  local s = { spinners = {}, tabs = {}, text = nil, file = nil }
  local spinners, why = M.readSpinners(host, ctx.tick)
  if spinners then
    s.spinners = spinners
  else
    s.spinnerReason = why
  end

  local okt, text = call(get(ac, 'stringifyCurrentSetup'), true, false)
  if okt and type(text) == 'string' and #text > 0 then
    s.text = Util.truncate(text, K.maxTextBytes)
    s.file = Util.parseIni(s.text, {
      maxBytes = K.maxTextBytes, maxSections = K.maxIniSections, maxKeys = K.maxIniKeys, maxValueChars = K.maxValueChars,
    }, ctx.tick)
  else
    s.textReason = okt and 'vide' or text
  end

  local oke, editable = call(get(ac, 'isSetupAvailableToEdit'))
  if oke and type(editable) == 'boolean' then s.editable = editable end
  local okl, legal, reason = call(get(ac, 'getCarSetupState'))
  if okl and type(legal) == 'string' then
    s.legal = Util.truncate(legal, 16)
    if type(reason) == 'string' then s.illegalReason = Util.truncate(reason, 200) end
  end
  local okb, tabs = call(get(ac, 'getSetupTabs'))
  if okb and type(tabs) == 'table' then
    for i = 1, min(length(tabs), 32) do
      local tab = get(tabs, i)
      s.tabs[#s.tabs + 1] = { name = str(tab, 'name', 64), label = str(tab, 'label', 64), visible = bool(tab, 'visible') }
    end
  end
  ctx.tick()
  s.comparison = M.compareSetup(s.spinners, s.file, ctx.tick)
  return s
end

-- ---------------------------------------------------------------------------
-- Circuit (§7.1) : ligne IA échantillonnée à progression uniforme
-- ---------------------------------------------------------------------------

function M.sampleTrack(host, ds, ctx)
  local ac = host.ac
  local t = {
    ok = false, source = 'ligne IA', n = 0, ds = ds,
    x = {}, y = {}, z = {}, p = {}, left = {}, right = {}, failures = 0, sideFailures = 0,
  }
  local okh, has = call(get(ac, 'hasTrackSpline'))
  if not okh or has ~= true then
    t.reason = okh and 'aucune ligne IA (fast_lane)' or ('ac.hasTrackSpline : ' .. tostring(has))
    return t
  end
  local oks, sim = call(get(ac, 'getSim'))
  t.lengthSim = oks and num(sim, 'trackLengthM') or nil
  t.open = oks and bool(sim, 'isTrackOpen') or nil
  if t.lengthSim == nil or t.lengthSim < K.trackMinLength or t.lengthSim > K.trackMaxLength then
    t.reason = 'longueur de ligne IA hors plage : ' .. Util.fmt(t.lengthSim, 0) .. ' m'
    return t
  end
  local n = Util.clamp(floor(t.lengthSim / ds + 0.5), K.trackMinSamples, K.trackMaxSamples)
  local toWorld = get(ac, 'trackProgressToWorldCoordinate')
  local sides = get(ac, 'getTrackAISplineSides')
  local maxFailures = floor(n * K.trackMaxFailureRatio) + 1
  local span = t.open == true and (n - 1) or n
  for i = 0, n - 1 do
    ctx.tick(2 * K.tickWeightApiCall)
    local p = math.min(i / span, 1 - 1e-6)
    local okp, pos = call(toWorld, p)
    local x, y, z = num(pos, 'x'), num(pos, 'y'), num(pos, 'z')
    if not (okp and x and y and z) then
      t.failures = t.failures + 1
      if t.failures > maxFailures then
        t.reason = 'échantillonnage interrompu : ' .. t.failures .. ' points invalides'
        return t
      end
    else
      local okd, side = call(sides, p)
      local l, r = num(side, 'x'), num(side, 'y')
      if not (okd and l and r and l >= 0 and r >= 0) then
        t.sideFailures = t.sideFailures + 1
        l, r = -1, -1
      end
      local k = t.n + 1
      t.x[k], t.y[k], t.z[k], t.p[k], t.left[k], t.right[k] = x, y, z, p, l, r
      t.n = k
    end
  end
  M.trackStats(t)
  t.ok = t.n >= K.trackMinSamples
  if not t.ok then t.reason = 'trop peu de points valides' end
  return t
end

local function setVec(v, x, y, z)
  v.x, v.y, v.z = x, y, z
end

-- Comble les trous (false) d'une liste par interpolation linéaire entre voisins valides, en bouclant
-- sur un circuit fermé ; sur un tracé ouvert, les extrémités prennent la valeur valide la plus proche.
local function fillGaps(values, n, closed)
  local valid = {}
  for i = 1, n do
    if values[i] ~= false then valid[#valid + 1] = i end
  end
  if #valid == 0 then return false end
  for v = 1, #valid do
    local a = valid[v]
    local b = valid[v + 1]
    local span
    if b then
      span = b - a
    elseif closed then
      b, span = valid[1], valid[1] + n - a
    end
    if b and span > 1 then
      for o = 1, span - 1 do
        local i = (a + o - 1) % n + 1
        values[i] = values[a] + (values[b] - values[a]) * o / span
      end
    end
  end
  if not closed then
    for i = 1, valid[1] - 1 do values[i] = values[valid[1]] end
    for i = valid[#valid] + 1, n do values[i] = values[valid[#valid]] end
  end
  return true
end

-- Dévers par sondage vertical (§7.1, source 3) : un rayon vers le bas sur chaque point de la ligne
-- IA ; la normale de surface renvoyée par physics.raycastTrack, projetée sur la normale horizontale
-- n = (−t.z, t.x) de la ligne, donne bankN = atan(N·n / N.y) : > 0 si le côté n est plus bas
-- (convention de track_model). Les vec3 sont réutilisés (aucune allocation par point).
function M.probeBank(host, t, ctx)
  if not t.ok then
    t.bankReason = 'géométrie du circuit indisponible'
    return t
  end
  local raycast = get(host.physics, 'raycastTrack')
  if raycast == nil then
    t.bankReason = 'physics.raycastTrack indisponible'
    return t
  end
  local okA, origin = call(host.vec3, 0, 0, 0)
  local okB, down = call(host.vec3, 0, -1, 0)
  local okC, hit = call(host.vec3, 0, 0, 0)
  local okD, normal = call(host.vec3, 0, 0, 0)
  if not (okA and okB and okC and okD) then
    t.bankReason = 'vec3 indisponible'
    return t
  end
  local closed = t.open ~= true
  local bank, failed = {}, 0
  local maxFailed = floor(t.n * K.bankMaxFailureRatio)
  for i = 1, t.n do
    ctx.tick(K.tickWeightApiCall)
    local a = i > 1 and i - 1 or (closed and t.n or 1)
    local c = i < t.n and i + 1 or (closed and 1 or t.n)
    local tx, tz = t.x[c] - t.x[a], t.z[c] - t.z[a]
    local len = math.sqrt(tx * tx + tz * tz)
    local value = nil
    if len > 1e-6 then
      local okO = pcall(setVec, origin, t.x[i], t.y[i] + K.raycastHeight, t.z[i])
      local okN = pcall(setVec, normal, 0, 0, 0)
      local okR, d = call(raycast, origin, down, K.raycastLength, hit, normal)
      local nx, ny, nz = num(normal, 'x'), num(normal, 'y'), num(normal, 'z')
      if okO and okN and okR and Util.isFinite(d) and d >= 0 and nx and ny and nz and ny > K.bankMinNormalY then
        value = math.atan((nx * -tz / len + nz * tx / len) / ny)
      end
    end
    if value == nil then
      failed = failed + 1
      if failed > maxFailed then
        t.bankFailures = failed
        t.bankReason = 'sondage du dévers abandonné : plus de ' .. maxFailed .. ' points sans impact sur ' .. t.n
        return t
      end
    end
    bank[i] = value or false
  end
  t.bankFailures = failed
  if not fillGaps(bank, t.n, closed) then
    t.bankReason = 'aucun impact de rayon'
    return t
  end
  t.bankN = bank
  return t
end

-- Longueur de la polyligne (fermée si le circuit est une boucle), altitude et largeur.
function M.trackStats(t)
  local total = 0
  for i = 2, t.n do
    local dx, dy, dz = t.x[i] - t.x[i - 1], t.y[i] - t.y[i - 1], t.z[i] - t.z[i - 1]
    total = total + math.sqrt(dx * dx + dy * dy + dz * dz)
  end
  if t.open ~= true and t.n > 1 then
    local dx, dy, dz = t.x[1] - t.x[t.n], t.y[1] - t.y[t.n], t.z[1] - t.z[t.n]
    total = total + math.sqrt(dx * dx + dy * dy + dz * dz)
  end
  t.lengthModel = total
  local altMin, altMax = huge, -huge
  local wMin, wMax, wSum, wCount = huge, -huge, 0, 0
  for i = 1, t.n do
    altMin, altMax = math.min(altMin, t.y[i]), math.max(altMax, t.y[i])
    if t.left[i] >= 0 then
      local w = t.left[i] + t.right[i]
      wMin, wMax, wSum, wCount = math.min(wMin, w), math.max(wMax, w), wSum + w, wCount + 1
    end
  end
  t.altitudeMin, t.altitudeMax = altMin, altMax
  if wCount > 0 then
    t.widthMin, t.widthMax, t.widthMean = wMin, wMax, wSum / wCount
  end
end

-- Unités reconnues dans ui_track.json (texte libre) ; toute autre forme est refusée.
local LENGTH_UNITS = {
  [''] = 'none', m = 'm', meter = 'm', meters = 'm', metre = 'm', metres = 'm',
  km = 'km', kms = 'km', kilometer = 'km', kilometers = 'km', kilometre = 'km', kilometres = 'km',
  mi = 'mi', mile = 'mi', miles = 'mi',
}

-- Longueur déclarée dans ui_track.json : « 7004 », « 7.004 km », « 4,3 km », « 5.8 miles »…
function M.parseDeclaredLength(text)
  if type(text) ~= 'string' then return nil end
  local raw = text:match('"length"%s*:%s*"([^"]*)"') or text:match('"length"%s*:%s*([%d%.]+)')
  if raw == nil then return nil end
  raw = Util.truncate(raw, 32)
  local intPart, sep, frac, unitText = raw:lower():match('^%s*(%d+)([%.,]?)(%d*)%s*(%a*)%s*$')
  local unit = unitText and LENGTH_UNITS[unitText] or nil
  if intPart == nil or unit == nil then return nil, raw end
  local value = tonumber(intPart .. (frac ~= '' and ('.' .. frac) or ''))
  local miles, km, meters = unit == 'mi', unit == 'km', unit == 'm'
  if sep == ',' and #frac == 3 and meters then value = tonumber(intPart .. frac) end
  if miles then
    value = value * 1609.344
  elseif km or (not meters and value < 100) then
    value = value * 1000
  end
  if not Util.isFinite(value) or value < 100 or value > 100000 then return nil, raw end
  return value, raw
end

M.TRACK_INI_FILES = { 'surfaces.ini', 'drs_zones.ini' }

function M.readTrackFiles(host, ctx)
  local ac = host.ac
  local r = { ini = {}, iniStatus = {}, iniOrder = {} }
  r.id = callString(get(ac, 'getTrackID'))
  r.layout = callString(get(ac, 'getTrackLayout'))
  r.fullId = callString(get(ac, 'getTrackFullID'), '/')
  r.name = callString(get(ac, 'getTrackName'))
  local trackData = get(get(ac, 'INIConfig'), 'trackData')
  for _, name in ipairs(M.TRACK_INI_FILES) do
    ctx.tick()
    r.iniOrder[#r.iniOrder + 1] = name
    local ok, cfg = call(trackData, name)
    if not ok then
      r.iniStatus[name] = 'erreur : ' .. tostring(cfg)
    else
      local okn, data = pcall(M.normalizeSections, get(cfg, 'sections'), ctx.tick)
      if okn and #data.order > 0 then
        r.ini[name] = data
        r.iniStatus[name] = 'ok'
      else
        r.iniStatus[name] = okn and 'absent ou vide' or 'erreur : format'
      end
    end
  end
  local ui = folder(ac, 'CurrentTrackLayoutUI')
  local load = get(host.io, 'load')
  if ui == nil then
    r.declaredReason = 'dossier ui du circuit inconnu'
  elseif load == nil then
    r.declaredReason = 'io.load absent'
  else
    local ok, text = call(load, ui .. '/ui_track.json')
    if ok and type(text) == 'string' then
      r.declared, r.declaredRaw = M.parseDeclaredLength(Util.truncate(text, K.maxTextBytes))
      if r.declared == nil then r.declaredReason = 'longueur absente ou illisible' end
    else
      r.declaredReason = 'ui_track.json illisible'
    end
  end
  return r
end

-- Rayon vertical depuis la position de la voiture (sonde J0 de physics.raycastTrack).
function M.probeRaycast(host, carIndex)
  local r = { ok = false }
  local okc, car = call(get(host.ac, 'getCar'), carIndex)
  local pos = okc and get(car, 'position') or nil
  local x, y, z = num(pos, 'x'), num(pos, 'y'), num(pos, 'z')
  if not (x and y and z) then
    r.reason = 'position de la voiture illisible'
    return r
  end
  local okv, origin = call(host.vec3, x, y + K.raycastHeight, z)
  local okd, dir = call(host.vec3, 0, -1, 0)
  if not (okv and okd) then
    r.reason = 'vec3 indisponible'
    return r
  end
  local ok, distance = call(get(host.physics, 'raycastTrack'), origin, dir, K.raycastLength)
  if ok and Util.isFinite(distance) then
    r.distance = distance
    r.ok = distance >= 0
    if not r.ok then r.reason = 'aucun impact sous la voiture' end
  else
    r.reason = ok and 'résultat non numérique' or distance
  end
  return r
end

-- ---------------------------------------------------------------------------
-- Session et conditions (§11)
-- ---------------------------------------------------------------------------

M.SIM_NUMBERS = {
  'ambientTemperature', 'roadTemperature', 'roadGrip', 'rainIntensity', 'rainWetness', 'rainWater',
  'windSpeedKmh', 'windDirectionDeg', 'trackLengthM', 'carsCount', 'currentSessionIndex', 'sessionsCount',
  'raceSessionType', 'systemTime', 'fps', 'time', 'weatherType', 'tyreConsumptionRate',
  'fuelConsumptionRate', 'mechanicalDamageRate',
}
M.SIM_FLAGS = {
  'isOnlineRace', 'isAltOnlineRace', 'isReplayActive', 'isReplayOnlyMode', 'isPaused', 'isInMainMenu',
  'isWeatherFXActive', 'fixedSetup', 'isTrackOpen', 'isTimedRace', 'isSessionStarted',
}

local function isWet(values)
  return (values.rainWetness or 0) > K.wetThreshold or (values.rainIntensity or 0) > K.wetThreshold
    or (values.rainWater or 0) > K.wetThreshold
end

function M.readSession(host)
  local ac = host.ac
  local s = { ok = false, values = {}, flags = {}, session = {} }
  local ok, sim = call(get(ac, 'getSim'))
  if not ok or sim == nil then
    s.reason = ok and 'état de simulation absent' or sim
    return s
  end
  for _, key in ipairs(M.SIM_NUMBERS) do s.values[key] = num(sim, key) end
  for _, key in ipairs(M.SIM_FLAGS) do s.flags[key] = bool(sim, key) end
  -- séances du week-end (la course n'est pas forcément la séance courante) ; la courante à part
  local function readOne(index)
    local okS, session = call(get(ac, 'getSession'), index)
    if not okS or session == nil then return nil end
    return {
      index = index, type = num(session, 'type'), laps = num(session, 'laps'), durationMinutes = num(session, 'durationMinutes'),
      isTimedRace = bool(session, 'isTimedRace'), hasAdditionalLap = bool(session, 'hasAdditionalLap'),
    }
  end
  s.session = readOne(s.values.currentSessionIndex or 0) or {}
  s.sessions = {}
  local count = s.values.sessionsCount
  if Util.isFinite(count) then
    for i = 0, min(count, K.maxSessions) - 1 do
      local one = readOne(i)
      if one then s.sessions[#s.sessions + 1] = one end
    end
  end
  local okA, assists = call(get(ac, 'getAssists'))
  if okA and type(assists) == 'table' then
    s.assists = {
      fuelRate = num(assists, 'fuelRate'), tyresWear = num(assists, 'tyresWear'),
      damageRate = num(assists, 'damageRate'), tyresBlankets = bool(assists, 'tyresBlankets'),
      slipstream = num(assists, 'slipstream'),
      abs = str(assists, 'abs', 16), tractionControl = str(assists, 'tractionControl', 16),
    }
  end
  s.wet = isWet(s.values)
  s.ok = true
  return s
end

M.CONTEXT_GUARDS = {
  { key = 'isOnlineRace', kind = 'online' }, { key = 'isAltOnlineRace', kind = 'online' },
  { key = 'isReplayActive', kind = 'replay' }, { key = 'isReplayOnlyMode', kind = 'replay' },
}

-- Contexte léger lu à 1 Hz (§5.2). key : identité voiture/circuit (nouvelle découverte si elle
-- change) ; conditionsKey : identité de la séance (type, numéro), nil si l'un est illisible. La piste
-- mouillée n'en fait pas partie (sans hystérésis, une humidité au seuil relancerait la découverte en
-- boucle) : la colle en tire l'état de la piste, avec hystérésis (D16 amendé). Humidité, eau et intensité
-- de la pluie (0 à 1) sont rendues telles quelles. Les températures et l'adhérence de la piste sont rendues
-- telles quelles : la colle compare chaque résultat aux conditions de son calcul (décision de Vincent du
-- 20/10/2026 : signaler, ne pas bloquer). identityOnly : seule l'identité voiture/circuit manque.
function M.readContext(host)
  local ac = host.ac
  local c = { ok = false }
  local ok, sim = call(get(ac, 'getSim'))
  if not ok or sim == nil then
    c.reason = 'ac.getSim indisponible'
    return c
  end
  -- Garde en ligne / replay : un drapeau illisible rend l'app inerte (comportement prudent, §0.6).
  for _, guard in ipairs(M.CONTEXT_GUARDS) do
    local value = bool(sim, guard.key)
    if value == nil then
      c.reason = 'drapeau illisible : ' .. guard.key
      return c
    end
    c[guard.kind] = c[guard.kind] == true or value
  end
  c.paused = bool(sim, 'isPaused') == true
  c.fps = num(sim, 'fps')
  c.time = num(sim, 'time')
  c.systemTime = num(sim, 'systemTime')
  c.sessionType = num(sim, 'raceSessionType')
  c.sessionIndex = num(sim, 'currentSessionIndex')
  c.rainWetness, c.rainIntensity, c.rainWater = num(sim, 'rainWetness'), num(sim, 'rainIntensity'), num(sim, 'rainWater')
  c.wet = isWet({ rainWetness = c.rainWetness, rainIntensity = c.rainIntensity, rainWater = c.rainWater })
  c.airTemp, c.roadTemp, c.roadGrip = num(sim, 'ambientTemperature'), num(sim, 'roadTemperature'), num(sim, 'roadGrip')
  c.carId = callString(get(ac, 'getCarID'), 0)
  c.trackFullId = callString(get(ac, 'getTrackFullID'), '/')
  c.key = tostring(c.carId) .. '|' .. tostring(c.trackFullId)
  c.conditionsKey = (c.sessionType and c.sessionIndex) and (tostring(c.sessionType) .. '|' .. tostring(c.sessionIndex)) or nil
  c.ok = c.carId ~= nil and c.trackFullId ~= nil
  if not c.ok then c.reason, c.identityOnly = 'voiture ou circuit non identifié', true end
  return c
end

-- Empreinte des fichiers de la voiture lus (D9) : contenu normalisé de chaque INI, dans l'ordre de
-- lecture, clés triées. Une calibration ou une rugosité stockée ne vaut que pour les mêmes fichiers (mise
-- à jour du mod : ignorée). Hachage par morceaux, avec rendu de main.
function M.fingerprint(car, tick)
  tick = tick or function() end
  local h = 5381
  for _, name in ipairs(car.iniOrder or {}) do
    local data = car.ini[name]
    if data and data.sections then
      h = (h * 31 + Util.hashString(name)) % 2147483647
      for _, section in ipairs(data.order or {}) do
        local values = data.sections[section] or {}
        local keys = {}
        for key in pairs(values) do keys[#keys + 1] = key end
        table.sort(keys)
        for _, key in ipairs(keys) do
          h = (h * 31 + Util.hashString(section .. '.' .. key .. '=' .. tostring(values[key]))) % 2147483647
        end
        tick()
      end
    end
  end
  return h
end

return M
