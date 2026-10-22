-- SetupLab — modèle de la voiture (§8.1 à §8.6). Noyau pur (D5).
--
-- build()      : paramètres de base lus dans les fichiers de la voiture (tables de datasource),
--                chacun avec sa source (file, measured, default) ;
-- fromParams() : même structure depuis des paramètres explicites (cas analytiques, mesure seule) ;
-- defaultSetup(): réglages physiques par défaut des fichiers (valeurs d'usine) ;
-- configure()  : pour un setup physique et des conditions, précalcule les tables de performance
--                que lit la simulation de tour (§8.2) : adhérence latérale, freinage, motricité,
--                force moteur, appui et traînée, en fonction de la vitesse et de la charge normale.
--
-- Modèle de pneu (formules Kunos, API_NOTES §3) : μ(Fz) = DY_REF·(Fz/FZ0)^(LS_EXPY−1) ; carrossage
-- D·(1 − (|γ|·DCAMBER_0 + γ²·DCAMBER_1)) ; pression 1 − PRESSURE_D_GAIN·|P_chaud − P_idéal| ;
-- température : LUT PERFORMANCE_CURVE ; usure : LUT WEAR_CURVE (%). Les écarts au comportement réel
-- d'AC sont absorbés par la calibration (§9) ; ce modèle n'est pas fidèle par construction.

local Util = require('src/util')
local Ers = require('src/ers')
local Config = require('src/config')
local K = Config.K

local M = {}

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local G = 9.80665
local P_ATM_PSI = 14.696

-- ---------------------------------------------------------------------------
-- Lecture des fichiers
-- ---------------------------------------------------------------------------

local function source(sources, key, value, kind)
  sources[key] = kind
  return value
end

local function iniNum(car, file, section, key)
  return Util.iniNumber(car.ini[file], section, key, nil)
end

local function lut(car, name)
  if type(name) ~= 'string' or name == '' then return nil end
  local inline = name:match('^%s*%(.*%)%s*$')
  if inline then return Util.parseLutText(name, K.maxLutPoints) end
  return car.luts[name:lower()]
end

-- Un composé (essieu avant ou arrière) depuis tyres.ini.
local function readTyre(car, section, thermal)
  local function n(key) return iniNum(car, 'tyres.ini', section, key) end
  local t = {
    name = Util.iniGet(car.ini['tyres.ini'], section, 'NAME'),
    short = Util.iniGet(car.ini['tyres.ini'], section, 'SHORT_NAME'),
    radius = n('RADIUS'), width = n('WIDTH'),
    dyRef = n('DY_REF') or n('DY0'), dxRef = n('DX_REF') or n('DX0'),
    fz0 = n('FZ0'), lsExpY = n('LS_EXPY'), lsExpX = n('LS_EXPX'),
    dcamber0 = n('DCAMBER_0') or 0, dcamber1 = n('DCAMBER_1') or 0,
    pressureStatic = n('PRESSURE_STATIC'), pressureIdeal = n('PRESSURE_IDEAL'), pressureDGain = n('PRESSURE_D_GAIN') or 0,
    rr0 = n('ROLLING_RESISTANCE_0') or 0, rr1 = n('ROLLING_RESISTANCE_1') or 0, rate = n('RATE'),
    pressureSpringGain = n('PRESSURE_SPRING_GAIN') or 0,
    -- carrossage apporté par la déformation du pneu à la limite : CAMBER_GAIN × FRICTION_LIMIT_ANGLE (°)
    deformCamber = math.rad((n('CAMBER_GAIN') or 0) * (n('FRICTION_LIMIT_ANGLE') or 0)),
    wear = lut(car, Util.iniGet(car.ini['tyres.ini'], section, 'WEAR_CURVE')),
    perf = lut(car, Util.iniGet(car.ini['tyres.ini'], thermal, 'PERFORMANCE_CURVE')),
    -- pluie (D16 amendé) : type vu par CSP (SLICK par défaut, RACING_TREADED, RAIN…) et rainures (m)
    typeHint = (Util.iniGet(car.ini['tyres.ini'], section, 'TYPE_HINT') or ''):upper():match('^%s*([%w_]*)'),
    treadDepth = n('TREAD_DEPTH'), treadCover = n('TREAD_COVER'),
  }
  -- Données non fiables (D11) : un composé physiquement absurde est écarté.
  if t.radius == nil or t.dyRef == nil or t.radius < 0.15 or t.radius > 1.2 or t.dyRef < 0.3 or t.dyRef > 4 then
    return nil
  end
  if t.fz0 and t.fz0 <= 0 then t.fz0 = nil end
  if t.lsExpY and (t.lsExpY < 0.1 or t.lsExpY > 1.5) then t.lsExpY = nil end
  -- Sommet de la parabole de carrossage : au-delà, la formule Kunos redonnerait de l'adhérence ; l'effet
  -- y est gardé constant (prudence §0.6 : l'optimiseur ne doit pas exploiter cet artefact).
  if t.dcamber0 > 0 and t.dcamber1 < 0 then t.camberPeak = t.dcamber0 / (-2 * t.dcamber1) end
  return t
end

function M.readCompounds(car)
  local list = {}
  local tyres = car.ini['tyres.ini']
  if tyres == nil then return list end
  for i = 0, K.maxCompounds - 1 do
    local suffix = i == 0 and '' or ('_' .. i)
    if tyres.sections['FRONT' .. suffix] == nil then break end
    local front = readTyre(car, 'FRONT' .. suffix, 'THERMAL_FRONT' .. suffix)
    local rear = readTyre(car, 'REAR' .. suffix, 'THERMAL_REAR' .. suffix)
    if front and rear then
      local c = { index = i, name = front.name or ('#' .. i), short = front.short, front = front, rear = rear }
      c.use = M.compoundUse(c)
      M.waterSpec(front, c.use)
      M.waterSpec(rear, c.use)
      list[#list + 1] = c
    end
  end
  return list
end

-- Position dans base.compounds du composé d'index CSP compoundIndex (base 0, ordre de tyres.ini), ou nil.
-- readCompounds écarte les composés invalides : position et index peuvent différer.
function M.compoundSlot(base, compoundIndex)
  if compoundIndex == nil then return nil end
  for i, c in ipairs(base.compounds) do
    if c.index == compoundIndex then return i end
  end
  return nil
end

-- Usage d'un composé (D16 amendé le 21/10/2026, décision de Vincent) : « pluie », « intermédiaire » ou
-- « sec ». Type vu par CSP d'abord (TYPE_HINT=RAIN ou WET : pluie ; RACING_TREADED : intermédiaire ; un
-- pneu routier à rainures, STREET…, reste un pneu sec), sinon le nom du composé.
function M.compoundUse(c)
  local hint = c.front and c.front.typeHint or ''
  if hint == 'RAIN' or hint == 'WET' then return 'pluie' end
  if hint == 'RACING_TREADED' then return 'intermédiaire' end
  if hint ~= '' then return 'sec' end
  local name = ((c.name or '') .. ' ' .. (c.short or '')):lower()
  if name:find('inter', 1, true) then return 'intermédiaire' end
  for _, pattern in ipairs(K.wetCompoundPatterns) do
    if name:find(pattern, 1, true) then return 'pluie' end
  end
  local short = (c.short or ''):upper()
  for _, s in ipairs(K.wetCompoundShortNames) do
    if short == s then return (s == 'W' or s == 'WT') and 'pluie' or 'intermédiaire' end
  end
  return 'sec'
end

-- Composé pluie ou intermédiaire : jamais choisi d'office sur piste sèche, comparé aux autres sur piste
-- mouillée.
function M.isWetCompound(c)
  return (c.use or M.compoundUse(c)) ~= 'sec'
end

-- Comportement d'un pneu dans l'eau (H25, H26, H28) : classe (slick, treaded : à rainures, rain : pluie)
-- et capacité des rainures (profondeur × part de creux, mm) ; valeurs supposées sans TREAD_DEPTH /
-- TREAD_COVER (treadAssumed).
function M.waterSpec(tyre, use)
  local hint = tyre.typeHint or ''
  local class
  if hint == 'SLICK' then
    class = 'slick'
  elseif hint == 'RAIN' or hint == 'WET' or (hint == '' and use == 'pluie') then
    class = 'rain'
  elseif hint ~= '' or use == 'intermédiaire' then
    class = 'treaded'
  else
    class = 'slick'
  end
  local depth, cover = tyre.treadDepth, tyre.treadCover
  tyre.treadAssumed = not (Util.isFinite(depth) and Util.isFinite(cover))
  if tyre.treadAssumed then depth, cover = K.wetTreadDefaults[class][1], K.wetTreadDefaults[class][2] end
  tyre.waterClass = class
  tyre.treadMm = Util.clamp(depth, 0, 0.05) * Util.clamp(cover, 0, 1) * 1000
  return tyre
end

-- H25 : adhérence d'un pneu sur piste humide (film d'eau), humidité wetness de 0 à 1.
function M.wetSurfaceFactor(tyre, wetness)
  if wetness <= 0 then return 1 end
  return 1 - Util.clamp(wetness, 0, 1) * (K.wetSurfaceLoss[tyre.waterClass or 'slick'] or K.wetSurfaceLoss.slick)
end

-- H26 : eau sous les pneus (mm) : mesurée sur un tour mouillé, sinon supposée d'après l'eau de la piste.
function M.waterDepth(conditions)
  if Util.isFinite(conditions.waterMm) then return max(0, conditions.waterMm) end
  return Util.clamp(Util.finiteOr(conditions.water, 0), 0, 1) * K.wetWaterDepthMax
end

-- H26 : aquaplanage : perte d'adhérence en v² au-delà de l'eau que les rainures évacuent.
function M.aquaplaneFactor(tyre, waterMm, v)
  local excess = waterMm - (tyre.treadMm or 0)
  if excess <= 0 then return 1 end
  local s = v / K.aquaRefSpeed
  return max(K.aquaFloor, 1 - K.aquaGain * excess * s * s)
end

-- H27 : température de fonctionnement retenue sans mesure : plateau de la courbe sur piste sèche ; sur
-- piste mouillée, plus froide (piste + K.wetTyreRise, au plus le plateau), selon l'humidité.
function M.runningTemp(tyre, conditions)
  local op = M.operatingTemp(tyre)
  local wetness = Util.clamp(Util.finiteOr(conditions and conditions.wetness, 0), 0, 1)
  if wetness <= 0 then return op end
  local road = Util.finiteOr(conditions.roadTemp, Util.finiteOr(conditions.airTemp, 20))
  return op - wetness * max(0, op - (road + K.wetTyreRise))
end

-- Une aide au pilotage d'electronics.ini (ABS, TRACTION_CONTROL) : présente ou non ; niveaux : limite de
-- glissement de chaque niveau (CURVE : niveau k = ligne k de la table ; 0 coupe l'aide), sinon un seul
-- niveau (SLIP_RATIO_LIMIT). Le sens « plus strict » (coupure plus précoce : glissement admis plus bas)
-- est lu dans la table : il diffère d'une voiture à l'autre (Kunos : niveau 1 le plus strict).
function M.readAid(car, section)
  local a = { section = section, present = iniNum(car, 'electronics.ini', section, 'PRESENT') == 1 }
  if not a.present then return a end
  local curve = lut(car, Util.iniGet(car.ini['electronics.ini'], section, 'CURVE'))
  if curve and curve.n >= 2 then
    a.levels, a.count = {}, curve.n
    for i = 1, curve.n do a.levels[i] = curve.y[i] end
    a.stricterUp = curve.y[curve.n] < curve.y[1]
  else
    a.count, a.stricterUp = 1, true
    a.levels = { iniNum(car, 'electronics.ini', section, 'SLIP_RATIO_LIMIT') }
  end
  return a
end

-- Ailes (aero.ini) et contrôleurs dynamiques en fonction de la vitesse.
function M.readAero(car)
  local aero = car.ini['aero.ini']
  local wings, controllers, ignored = {}, {}, {}
  if aero == nil then return wings, controllers, ignored end
  for _, section in ipairs(aero.order) do
    local index = tonumber(section:match('^WING_(%d+)$'))
    if index then
      local pos = Util.parseNumberList(Util.iniGet(aero, section, 'POSITION') or '', 3) or { 0, 0, 0 }
      local chord = Util.iniNumber(aero, section, 'CHORD', 1)
      local span = Util.iniNumber(aero, section, 'SPAN', 1)
      wings[#wings + 1] = {
        index = index, name = Util.iniGet(aero, section, 'NAME') or section,
        area = chord * span, y = pos[2] or 0, z = pos[3] or 0,
        cl = lut(car, Util.iniGet(aero, section, 'LUT_AOA_CL')), cd = lut(car, Util.iniGet(aero, section, 'LUT_AOA_CD')),
        ghCl = lut(car, Util.iniGet(aero, section, 'LUT_GH_CL')), ghCd = lut(car, Util.iniGet(aero, section, 'LUT_GH_CD')),
        clGain = Util.iniNumber(aero, section, 'CL_GAIN', 1), cdGain = Util.iniNumber(aero, section, 'CD_GAIN', 1),
        angle = Util.iniNumber(aero, section, 'ANGLE', 0),
      }
    elseif section:find('^DYNAMIC_CONTROLLER') then
      local input = (Util.iniGet(aero, section, 'INPUT') or ''):upper()
      local entry = {
        wing = Util.iniNumber(aero, section, 'WING', -1), input = input,
        combinator = (Util.iniGet(aero, section, 'COMBINATOR') or 'ADD'):upper(),
        lut = lut(car, Util.iniGet(aero, section, 'LUT')),
        up = Util.iniNumber(aero, section, 'UP_LIMIT', math.huge), down = Util.iniNumber(aero, section, 'DOWN_LIMIT', -math.huge),
      }
      if input == 'SPEED_KMH' and entry.lut then
        controllers[#controllers + 1] = entry
      else
        ignored[#ignored + 1] = section .. ' (' .. input .. ')'
      end
    end
  end
  return wings, controllers, ignored
end

-- DRS (drs.ini, §8.9) : aile mobile désignée par une section [WING_n], et son EFFECT. Hypothèse H8 :
-- EFFECT est la fraction de la contribution de l'aile (appui et traînée) retirée volet ouvert.
-- Hypothèse H9 : LIMIT_G est l'accélération latérale (g) au-delà de laquelle le volet se referme.
-- Clé dont le sens n'est pas établi (IGNORE_ZONES, DRS_ZONES ≠ 1) : DRS désactivé pour la voiture,
-- avec la raison (§0.6) ; DEACTIVATION et clés inconnues : signalées. Renvoie nil sans section WING_n.
function M.readDrs(car, wings)
  local ini = car.ini['drs.ini']
  if ini == nil then return nil end
  local section = nil
  for _, name in ipairs(ini.order) do
    if section == nil and name:match('^WING_%d+$') then section = name end
  end
  if section == nil then return nil end
  local drs = { wing = tonumber(section:match('(%d+)$')), section = section, notes = {}, usable = false }
  local function value(key)
    for _, name in ipairs(ini.order) do
      local v = Util.iniGet(ini, name, key)
      if v ~= nil then return v end
    end
    return nil
  end
  local known = { EFFECT = true, LIMIT_G = true, DRS_ZONES = true, IGNORE_ZONES = true, DEACTIVATION = true }
  for _, name in ipairs(ini.order) do
    for key in pairs(ini.sections[name] or {}) do
      if not known[key] then drs.notes[#drs.notes + 1] = 'clé ' .. key .. ' non interprétée' end
    end
  end
  table.sort(drs.notes)
  local effect = tonumber(value('EFFECT'))
  local limitG = tonumber(value('LIMIT_G'))
  if limitG and Util.isFinite(limitG) and limitG > 0 then drs.limitG = limitG end
  if value('DEACTIVATION') ~= nil then drs.notes[#drs.notes + 1] = 'DEACTIVATION non modélisé' end
  local wing = nil
  for _, w in ipairs(wings or {}) do
    if w.index == drs.wing then wing = w end
  end
  local ignore, zones = tonumber(value('IGNORE_ZONES')), tonumber(value('DRS_ZONES'))
  if effect == nil or not Util.isFinite(effect) or effect < 0 or effect > 1 then
    drs.reason = 'EFFECT illisible ou hors de [0 ; 1]'
  elseif effect == 0 then
    drs.reason = 'EFFECT = 0 : volet sans effet'
  elseif wing == nil then
    drs.reason = 'aile ' .. section .. ' absente d\'aero.ini'
  elseif value('IGNORE_ZONES') ~= nil and ignore ~= 0 then
    drs.reason = 'IGNORE_ZONES=' .. tostring(value('IGNORE_ZONES')) .. ' : sens non établi, DRS non simulé'
  elseif value('DRS_ZONES') ~= nil and zones ~= 1 then
    drs.reason = 'DRS_ZONES=' .. tostring(value('DRS_ZONES')) .. ' : sens non établi, DRS non simulé'
  else
    drs.usable = true
  end
  drs.effect = effect
  drs.wingName = wing and wing.name or nil
  return drs
end

-- Turbos : pression maximale min(MAX_BOOST, WASTEGATE), atteinte à REFERENCE_RPM. Hypothèse H5 : un
-- turbo réglable du cockpit (COCKPIT_ADJUSTABLE=1) tourne à DEFAULT_TURBO_ADJUSTMENT (0–1) de cette
-- pression (commentaire Kunos : « DEFAULT turbo adjustment if one or more turbos are cockpit
-- adjustable ») ; à confirmer en jeu par car.turboBoost.
local function readTurbos(car)
  local turbos = {}
  local engine = car.ini['engine.ini']
  if engine == nil then return turbos end
  local adjustment = Util.iniNumber(engine, 'ENGINE_DATA', 'DEFAULT_TURBO_ADJUSTMENT', nil)
    or Util.iniNumber(engine, 'HEADER', 'DEFAULT_TURBO_ADJUSTMENT', 1)
  adjustment = Util.clamp(adjustment, 0, 1)
  for _, section in ipairs(engine.order) do
    if section:find('^TURBO_%d+$') then
      local maxBoost = Util.iniNumber(engine, section, 'MAX_BOOST', 0)
      local wastegate = Util.iniNumber(engine, section, 'WASTEGATE', 0)
      local boost = wastegate > 0 and min(maxBoost, wastegate) or maxBoost
      if Util.iniNumber(engine, section, 'COCKPIT_ADJUSTABLE', 0) == 1 then boost = boost * adjustment end
      turbos[#turbos + 1] = { boost = max(0, boost), refRpm = max(1, Util.iniNumber(engine, section, 'REFERENCE_RPM', 1)) }
    end
  end
  return turbos
end

local function readGears(car)
  local gears = {}
  local count = iniNum(car, 'drivetrain.ini', 'GEARS', 'COUNT') or 0
  for i = 1, min(count, K.maxGearRatios) do
    local ratio = iniNum(car, 'drivetrain.ini', 'GEARS', 'GEAR_' .. i)
    if ratio and ratio > 0 then gears[#gears + 1] = ratio end
  end
  return gears
end

-- Paramètres de base depuis les fichiers (car : sortie de Datasource.readCar ; state : sortie de
-- Datasource.readCarState, facultative ; tick : rendu coopératif, facultatif). Renvoie base, liste des
-- manques.
function M.build(car, state, tick)
  local src, missing = {}, {}
  local p = {}
  local values = state and state.ok and state.values or {}
  -- Hypothèse H1 (documentée) : TOTALMASS inclut le pilote et exclut le carburant (convention Kunos).
  -- La masse CSP en jeu sert de contrôle (rapport J0) et de repli si les fichiers sont illisibles.
  local totalMass = iniNum(car, 'car.ini', 'BASIC', 'TOTALMASS')
  if totalMass then
    p.massDry = source(src, 'massDry', totalMass, 'file')
  elseif values.mass and values.fuel then
    p.massDry = source(src, 'massDry', values.mass - values.fuel * K.fuelDensity, 'measured')
  else
    missing[#missing + 1] = 'masse'
  end
  p.ballast = values.ballast or 0
  p.cgFront = source(src, 'cgFront', iniNum(car, 'suspensions.ini', 'BASIC', 'CG_LOCATION'), 'file')
  p.wheelbase = source(src, 'wheelbase', iniNum(car, 'suspensions.ini', 'BASIC', 'WHEELBASE'), 'file')
  p.trackF = source(src, 'trackF', iniNum(car, 'suspensions.ini', 'FRONT', 'TRACK'), 'file')
  p.trackR = source(src, 'trackR', iniNum(car, 'suspensions.ini', 'REAR', 'TRACK'), 'file')
  p.compounds = M.readCompounds(car)
  p.compoundDefault = iniNum(car, 'tyres.ini', 'COMPOUND_DEFAULT', 'INDEX') or 0
  local first = p.compounds[1]
  if values.cgHeight and values.cgHeight > 0.05 and values.cgHeight < 1.5 then
    p.cgHeight = source(src, 'cgHeight', values.cgHeight, 'measured')
  elseif first and p.cgFront then
    -- BASEY (commentaire Kunos) : « Front Wheel Radius + BASEY = front CoG », d'où h = R + BASEY.
    local hf = first.front.radius + (iniNum(car, 'suspensions.ini', 'FRONT', 'BASEY') or 0)
    local hr = first.rear.radius + (iniNum(car, 'suspensions.ini', 'REAR', 'BASEY') or 0)
    p.cgHeight = source(src, 'cgHeight', p.cgFront * hf + (1 - p.cgFront) * hr, 'default')
  end
  p.wings, p.controllers, p.ignoredControllers = M.readAero(car)
  if tick then tick() end
  p.drs = M.readDrs(car, p.wings)
  p.ers = Ers.read(car)
  if tick then tick() end
  p.torque = lut(car, Util.iniGet(car.ini['engine.ini'], 'HEADER', 'POWER_CURVE'))
  p.limiter = iniNum(car, 'engine.ini', 'ENGINE_DATA', 'LIMITER')
  p.rpmMin = iniNum(car, 'engine.ini', 'ENGINE_DATA', 'MINIMUM') or 1000
  p.turbos = readTurbos(car)
  p.traction = (Util.iniGet(car.ini['drivetrain.ini'], 'TRACTION', 'TYPE') or 'RWD'):upper()
  if p.traction ~= 'RWD' and p.traction ~= 'FWD' and p.traction ~= 'AWD' then
    missing[#missing + 1] = 'transmission ' .. p.traction .. ' non modélisée'
  end
  -- FRONT_SHARE de [AWD] : en % (SDK Kunos, 35) ou en fraction (0,42) selon les voitures.
  local share = iniNum(car, 'drivetrain.ini', 'AWD', 'FRONT_SHARE')
  if share and share > 1 then share = share / 100 end
  p.awdFrontShare = share or 0.4
  p.gears = readGears(car)
  p.final = iniNum(car, 'drivetrain.ini', 'GEARS', 'FINAL')
  p.shiftUpTime = (iniNum(car, 'drivetrain.ini', 'GEARBOX', 'CHANGE_UP_TIME') or 100) / 1000
  -- Différentiel de l'essieu moteur arrière : [DIFFERENTIAL], ou REAR_DIFF_* de [AWD] en transmission intégrale.
  local diffSection, prefix = 'DIFFERENTIAL', ''
  if p.traction == 'AWD' then diffSection, prefix = 'AWD', 'REAR_DIFF_' end
  p.diff = {
    power = iniNum(car, 'drivetrain.ini', diffSection, prefix .. 'POWER') or 0,
    coast = iniNum(car, 'drivetrain.ini', diffSection, prefix .. 'COAST') or 0,
    preload = iniNum(car, 'drivetrain.ini', diffSection, prefix .. 'PRELOAD') or 0,
  }
  p.brakeTorque = iniNum(car, 'brakes.ini', 'DATA', 'MAX_TORQUE')
  p.brakeFront = iniNum(car, 'brakes.ini', 'DATA', 'FRONT_SHARE')
  p.absPresent = iniNum(car, 'electronics.ini', 'ABS', 'PRESENT') == 1
    and iniNum(car, 'electronics.ini', 'ABS', 'ACTIVE') ~= 0
  -- aides au pilotage (règle pluie, D16 amendé) : présence et niveaux
  p.aids = { abs = M.readAid(car, 'ABS'), tc = M.readAid(car, 'TRACTION_CONTROL') }
  p.fuelConsumption = iniNum(car, 'car.ini', 'FUEL', 'CONSUMPTION')
  p.fuelMax = iniNum(car, 'car.ini', 'FUEL', 'MAX_FUEL')
  p.fuelDefault = iniNum(car, 'car.ini', 'FUEL', 'FUEL')
  p.minHeight = iniNum(car, 'car.ini', 'RULES', 'MIN_HEIGHT') or 0
  for _, axle in ipairs({ 'FRONT', 'REAR' }) do
    local key = axle == 'FRONT' and 'F' or 'R'
    p['spring' .. key] = iniNum(car, 'suspensions.ini', axle, 'SPRING_RATE')
    p['rod' .. key] = iniNum(car, 'suspensions.ini', axle, 'ROD_LENGTH') or 0
    p['camber' .. key] = iniNum(car, 'suspensions.ini', axle, 'STATIC_CAMBER') or 0
    p['heave' .. key] = iniNum(car, 'suspensions.ini', 'HEAVE_' .. axle, 'SPRING_RATE') or 0
  end
  -- suspension (H16 à H18) : masse non suspendue, butées, course avant butée, amortisseurs (moyenne
  -- compression / détente ; rapides absents ou nuls : ceux de basse vitesse), amortisseur de pilonnage
  for _, axle in ipairs({ 'FRONT', 'REAR' }) do
    local key = axle == 'FRONT' and 'F' or 'R'
    local function num(section, name) return iniNum(car, 'suspensions.ini', section, name) end
    local function mean2(a, b)
      if a and b then return (a + b) / 2 end
      return a or b
    end
    p['hub' .. key] = num(axle, 'HUB_MASS')
    p['bumpStop' .. key] = num(axle, 'BUMP_STOP_RATE') or 0
    p['packer' .. key] = num(axle, 'PACKER_RANGE')
    p['dampSlow' .. key] = mean2(num(axle, 'DAMP_BUMP'), num(axle, 'DAMP_REBOUND'))
    local fast = mean2(num(axle, 'DAMP_FAST_BUMP'), num(axle, 'DAMP_FAST_REBOUND'))
    p['dampFast' .. key] = (fast and fast > 0) and fast or p['dampSlow' .. key]
    p['heaveDamp' .. key] = mean2(num('HEAVE_' .. axle, 'DAMP_BUMP'), num('HEAVE_' .. axle, 'DAMP_REBOUND')) or 0
  end
  p.arbF = iniNum(car, 'suspensions.ini', 'ARB', 'FRONT') or 0
  p.arbR = iniNum(car, 'suspensions.ini', 'ARB', 'REAR') or 0
  if state and state.ok and state.rideHeight[1] and state.rideHeight[2] then
    p.rideHeightF = source(src, 'rideHeight', state.rideHeight[1], 'measured')
    p.rideHeightR = state.rideHeight[2]
    -- carburant au moment de la mesure : référence de l'écrasement statique (hauteur d'un autre setup)
    p.rideRefFuel = values.fuel
  else
    -- hors jeu : jamais sous la hauteur minimale réglementaire de la voiture
    p.rideHeightF = source(src, 'rideHeight', max(K.defaultRideHeightF, p.minHeight + K.rideHeightMargin), 'default')
    p.rideHeightR = max(K.defaultRideHeightR, p.minHeight + K.rideHeightMargin)
  end
  for _, key in ipairs({ 'cgFront', 'wheelbase', 'trackF', 'trackR', 'cgHeight', 'torque', 'limiter', 'final' }) do
    if p[key] == nil then missing[#missing + 1] = key end
  end
  if #p.compounds == 0 then missing[#missing + 1] = 'pneus' end
  if #p.gears == 0 then missing[#missing + 1] = 'rapports de boîte' end
  -- AC exige aero.ini (au moins la carrosserie) : sans aile lisible, traînée et appui seraient nuls et le
  -- tour simulé sans valeur (§16.7 « voiture sans aero.ini » : refus motivé, pas de fausse confiance)
  if #p.wings == 0 then missing[#missing + 1] = 'aérodynamique (aero.ini illisible ou sans aile)' end
  p.sources = src
  return M.fromParams(p), missing
end

-- Complète et borne une structure de paramètres (fichiers ou explicites).
function M.fromParams(p)
  p.sources = p.sources or {}
  p.massDry = p.massDry or 1000
  p.ballast = p.ballast or 0
  p.cgFront = Util.clamp(p.cgFront or 0.5, 0.2, 0.8)
  p.wheelbase = max(1, p.wheelbase or 2.6)
  p.trackF = max(0.8, p.trackF or 1.6)
  p.trackR = max(0.8, p.trackR or 1.6)
  p.cgHeight = Util.clamp(p.cgHeight or 0.4, 0, 1.5)
  p.wings = p.wings or {}
  p.controllers = p.controllers or {}
  p.ignoredControllers = p.ignoredControllers or {}
  p.turbos = p.turbos or {}
  p.gears = p.gears or {}
  p.diff = p.diff or { power = 0, coast = 0, preload = 0 }
  p.shiftUpTime = p.shiftUpTime or 0.1
  p.limiter = p.limiter or 7000
  p.rpmMin = p.rpmMin or 1000
  p.final = p.final or 3.5
  p.brakeFront = Util.clamp(p.brakeFront or 0.6, 0.3, 0.9)
  p.fuelDefault = p.fuelDefault or 30
  p.fuelMax = p.fuelMax or 100
  p.rideHeightF = p.rideHeightF or K.defaultRideHeightF
  p.rideHeightR = p.rideHeightR or K.defaultRideHeightR
  p.arbF, p.arbR = p.arbF or 0, p.arbR or 0
  p.springF, p.springR = p.springF or 100000, p.springR or 100000
  p.heaveF, p.heaveR = p.heaveF or 0, p.heaveR or 0
  p.rodF, p.rodR = p.rodF or 0, p.rodR or 0
  p.hubF, p.hubR = p.hubF or 30, p.hubR or 30
  p.bumpStopF, p.bumpStopR = p.bumpStopF or 0, p.bumpStopR or 0
  p.heaveDampF, p.heaveDampR = p.heaveDampF or 0, p.heaveDampR or 0
  p.camberF, p.camberR = p.camberF or 0, p.camberR or 0
  p.minHeight = p.minHeight or 0
  p.compoundDefault = p.compoundDefault or 0
  return p
end

-- Réglages physiques d'usine (valeurs des fichiers). Unités SI, carrossage en degrés, pression en psi.
function M.defaultSetup(base)
  local wingAngles = {}
  for _, w in ipairs(base.wings) do wingAngles[w.index] = w.angle end
  local compound = 1
  for i, c in ipairs(base.compounds) do
    if c.index == base.compoundDefault then compound = i end
  end
  local c = base.compounds[compound]
  return {
    wingAngles = wingAngles, compound = compound,
    pressureF = c and c.front.pressureStatic or 26, pressureR = c and c.rear.pressureStatic or 26,
    camberF = base.camberF, camberR = base.camberR,
    springF = base.springF, springR = base.springR, arbF = base.arbF, arbR = base.arbR,
    rodF = base.rodF, rodR = base.rodR,
    bumpStopF = base.bumpStopF, bumpStopR = base.bumpStopR, packerF = base.packerF, packerR = base.packerR,
    dampSlowF = base.dampSlowF, dampSlowR = base.dampSlowR, dampFastF = base.dampFastF, dampFastR = base.dampFastR,
    brakeBias = base.brakeFront, brakePower = 1,
    diffPower = base.diff.power, diffCoast = base.diff.coast, diffPreload = base.diff.preload,
    fuel = base.fuelDefault, gears = { unpack(base.gears) }, final = base.final,
    heaveF = base.heaveF, heaveR = base.heaveR, limiterPct = 1,
  }
end

-- ---------------------------------------------------------------------------
-- Configuration : tables de performance pour un setup et des conditions
-- ---------------------------------------------------------------------------

-- Facteurs de calibration par défaut (§9.2).
local DEFAULT_FACTORS = { mu = 1, power = 1, drag = 1, lift = 1, brake = 1 }
function M.defaultFactors()
  return { mu = 1, power = 1, drag = 1, lift = 1, brake = 1 }
end

local NO_CONDITIONS = {}
local function noop() end

local function airDensity(tempC)
  return 101325 / (287.05 * (Util.finiteOr(tempC, 20) + 273.15))
end

-- Pression à chaud (gaz parfait sur la pression absolue) : pneus gonflés à la température de l'air.
function M.hotPressure(coldPsi, airTempC, tyreTempC)
  return (coldPsi + P_ATM_PSI) * (tyreTempC + 273.15) / (Util.finiteOr(airTempC, 20) + 273.15) - P_ATM_PSI
end

-- Pression à froid donnant une pression à chaud visée.
function M.coldPressureFor(hotPsi, airTempC, tyreTempC)
  return (hotPsi + P_ATM_PSI) * (Util.finiteOr(airTempC, 20) + 273.15) / (tyreTempC + 273.15) - P_ATM_PSI
end

-- Température de fonctionnement retenue : milieu du plateau de la courbe de performance, ou défaut.
function M.operatingTemp(tyre)
  local curve = tyre.perf
  if curve == nil then return K.tyreDefaultHotTemp end
  local best, lo, hi = -math.huge, nil, nil
  for i = 1, curve.n do best = max(best, curve.y[i]) end
  for i = 1, curve.n do
    if curve.y[i] >= best - 1e-6 then
      lo = lo or curve.x[i]
      hi = curve.x[i]
    end
  end
  return lo and (lo + hi) / 2 or K.tyreDefaultHotTemp
end

-- Repère de hauteur de l'aéro (hauteur de caisse, §8.5) : pour chaque aile dotée d'une LUT de hauteur
-- (LUT_GH), hauteur au sol relevée par le jeu voiture à l'arrêt au stand (getCarPhysics().wings[n],
-- même index qu'aero.ini) contre la hauteur du modèle avec le setup courant. Écarts ≤ K.rideFrameTol :
-- repère vérifié ; plus grands mais ≤ K.rideFrameMaxOffset : repère corrigé par la mesure (décalage par
-- aile) ; sinon, ou sans mesure au stand : non vérifié, la hauteur de caisse reste conservée. Sans aile à
-- LUT de hauteur : sans objet (l'appui ne dépend de la hauteur que par l'assiette). Renvoie
-- { status, rows, offsets, reason }.
function M.verifyRideFrame(base, state)
  local out = { status = 'non vérifié', rows = {}, offsets = {} }
  local wings = {}
  for _, w in ipairs(base.wings) do
    if w.ghCl or w.ghCd then wings[#wings + 1] = w end
  end
  if not (state and state.ok) then
    out.reason = 'état du jeu illisible'
    return out
  end
  -- hauteur de caisse de référence mesurée au repos : au stand seulement (en roulant, elle est dynamique)
  if state.flags.isInPit ~= true then
    out.reason = 'mesure à faire voiture arrêtée au stand (relancer la découverte au stand)'
    return out
  end
  if #wings == 0 then
    out.status = 'sans objet'
    return out
  end
  local hF, hR, wheelbase = base.rideHeightF, base.rideHeightR, base.wheelbase
  local worst = 0
  for _, w in ipairs(wings) do
    local live = state.wings[w.index + 1]
    local measured = live and live.groundHeight
    if not Util.isFinite(measured) then
      out.reason = 'hauteur au sol de l\'aile ' .. w.index .. ' non lue'
      return out
    end
    local share = Util.clamp((w.z + wheelbase * base.cgFront) / wheelbase, 0, 1)
    local model = hR + (hF - hR) * share
    out.rows[#out.rows + 1] = { index = w.index, name = w.name, measured = measured, model = model, gap = measured - model }
    worst = max(worst, abs(measured - model))
  end
  if worst <= K.rideFrameTol then
    out.status = 'vérifié'
  elseif worst <= K.rideFrameMaxOffset then
    out.status = 'corrigé'
    for _, row in ipairs(out.rows) do out.offsets[row.index] = row.gap end
  else
    out.status = 'écart'
    out.reason = 'écart de ' .. Util.fmt(worst * 1000, 0) .. ' mm entre la hauteur mesurée et le modèle : aile mal appariée ?'
  end
  return out
end

-- Fenêtre de température d'un pneu : plage autour du plateau de PERFORMANCE_CURVE où l'adhérence reste
-- au moins K.tyreWindowGrip du pic. Renvoie lo, hi (°C), ou nil sans courbe.
function M.tyreWindow(tyre)
  local curve = tyre.perf
  if curve == nil then return nil, nil end
  local best = -math.huge
  for i = 1, curve.n do best = max(best, curve.y[i]) end
  local level, mid = best * K.tyreWindowGrip, M.operatingTemp(tyre)
  local lo, hi = curve.x[1], curve.x[curve.n]
  local upperFound = false
  for i = 1, curve.n - 1 do
    local x0, x1, y0, y1 = curve.x[i], curve.x[i + 1], curve.y[i], curve.y[i + 1]
    if x1 <= mid and y0 < level and y1 >= level then lo = x0 + (level - y0) / (y1 - y0) * (x1 - x0) end
    if not upperFound and x0 >= mid and y0 >= level and y1 < level then
      hi = x0 + (level - y0) / (y1 - y0) * (x1 - x0)
      upperFound = true
    end
  end
  return lo, hi
end

-- État mesuré des pneus par essieu sur un tour enregistré (§8.6, §10.6 : « pression qui limite la
-- surchauffe ») : température cœur moyenne contre la fenêtre (froid, fenêtre, surchauffe), écart de
-- température intérieur − extérieur, pression à chaud mesurée et son écart à la loi des gaz (H4) depuis
-- la pression à froid du setup du tour. setup : setup physique du tour. Renvoie { F, R } ou nil.
function M.tyreState(base, slot, lap, setup)
  local compound = base.compounds[slot] or base.compounds[1]
  if compound == nil or lap == nil or lap.tyreTemp == nil or lap.pressure == nil then return nil end
  local air = lap.conditions and lap.conditions.airTemp
  local out = {}
  for _, axle in ipairs({ 'F', 'R' }) do
    local w1, w2 = axle == 'F' and 1 or 3, axle == 'F' and 2 or 4
    local tyre = axle == 'F' and compound.front or compound.rear
    local temp = ((lap.tyreTemp[w1] or 0) + (lap.tyreTemp[w2] or 0)) / 2
    if not (Util.isFinite(temp) and temp > 0) then return nil end
    local lo, hi = M.tyreWindow(tyre)
    local entry = { temp = temp, lo = lo, hi = hi, ideal = tyre.pressureIdeal, cold = setup and setup['pressure' .. axle] }
    -- surchauffe jugée sur la roue la plus chaude (§0.6 : un circuit dissymétrique chauffe un côté)
    entry.tempMax = max(lap.tyreTemp[w1] or temp, lap.tyreTemp[w2] or temp)
    entry.state = (hi and entry.tempMax > hi) and 'surchauffe' or ((lo and temp < lo) and 'froid' or 'fenêtre')
    local p1, p2 = lap.pressure[w1], lap.pressure[w2]
    if Util.isFinite(p1) and Util.isFinite(p2) and p1 > 0 and p2 > 0 then entry.hot = (p1 + p2) / 2 end
    -- gauche et droite incohérentes (D11) : une roue aberrante ne doit ni ancrer l'essieu sur une moyenne
    -- fausse ni le désancrer ; pression à chaud non retenue (recherche réduite)
    local tempGap = abs((lap.tyreTemp[w1] or temp) - (lap.tyreTemp[w2] or temp))
    if entry.hot and (abs(p1 - p2) > K.tyreLrPressureMax or tempGap > K.tyreLrTempMax) then
      entry.hot = nil
      entry.lrNote = 'gauche / droite incohérentes (' .. Util.fmt(abs(p1 - p2), 1) .. ' psi, ' .. Util.fmt(tempGap, 0)
        .. ' °C d\'écart) : pression non ancrée sur la mesure'
    end
    if entry.hot and entry.cold and Util.isFinite(air) then
      entry.offset = entry.hot - M.hotPressure(entry.cold, air, temp)
    end
    local inside, outside = lap.tyreTempIn, lap.tyreTempOut
    if inside and outside and Util.isFinite(inside[w1]) and Util.isFinite(inside[w2]) and Util.isFinite(outside[w1])
      and Util.isFinite(outside[w2]) then
      entry.spread = (inside[w1] + inside[w2]) / 2 - (outside[w1] + outside[w2]) / 2
    end
    out[axle] = entry
  end
  return out
end

-- Multiplicateur d'adhérence hors charge et hors carrossage dynamique : pression, température, usure.
-- hotPsi : pression à chaud de l'essieu (mesurée, ou déduite par configure) ; temp, km : température et
-- km virtuels de l'essieu (relais, tour mesuré), sinon ceux de conditions.
local function gripMultiplier(tyre, coldPsi, conditions, hotPsi, temp, km)
  temp = temp or conditions.tyreTemp or M.runningTemp(tyre, conditions)
  km = km or conditions.tyreKm
  local m = 1
  if tyre.pressureIdeal and tyre.pressureDGain > 0 then
    local hot = hotPsi or M.hotPressure(coldPsi, conditions.airTemp, temp)
    m = m * max(0.5, 1 - tyre.pressureDGain * abs(hot - tyre.pressureIdeal))
  end
  if tyre.perf then m = m * Util.lutEval(tyre.perf, temp) end
  if tyre.wear then
    -- WEAR_CURVE : % d'adhérence selon les km virtuels. Qualification : pic de la courbe atteint
    -- dans les K.qualiTyreKm premiers km (pneus neufs mis en température) ; relais : km fournis.
    local level
    if km then
      level = Util.lutEval(tyre.wear, km)
    else
      level = Util.lutEval(tyre.wear, 0)
      for i = 1, tyre.wear.n do
        if tyre.wear.x[i] <= K.qualiTyreKm then level = max(level, tyre.wear.y[i]) end
      end
      level = max(level, Util.lutEval(tyre.wear, K.qualiTyreKm))
    end
    m = m * Util.clamp(level / 100, 0.3, 1.2)
  end
  return m
end

-- Coefficient d'adhérence à la charge F (N) : sensibilité à la charge AC.
local function mu(tyre, d, F)
  if F <= 1 or tyre.fz0 == nil then return d end
  return d * (F / tyre.fz0) ^ ((tyre.lsExpY or 1) - 1)
end

-- Facteur de carrossage (formule Kunos), γ en radians.
local function camberFactor(tyre, gammaRad)
  local a = abs(gammaRad)
  if tyre.camberPeak and a > tyre.camberPeak then a = tyre.camberPeak end
  return max(0.5, 1 - (a * tyre.dcamber0 + a * a * tyre.dcamber1))
end

-- Force latérale maximale d'un essieu : charges Fo (extérieur) et Fi (intérieur). Carrossage de chaque
-- roue (convention AC : négatif = haut de roue vers la caisse) : statique γ, plus le roulis de caisse
-- non compensé et la déformation du pneu, qui ouvrent la roue extérieure (vers le positif) et
-- ferment la roue intérieure (vers le négatif).
local function axleLateral(tyre, d, Fo, Fi, gamma, roll)
  local delta = roll + tyre.deformCamber
  local f = 0
  if Fo > 0 then f = f + mu(tyre, d, Fo) * camberFactor(tyre, gamma + delta) * Fo end
  if Fi > 0 then f = f + mu(tyre, d, Fi) * camberFactor(tyre, gamma - delta) * Fi end
  return f
end

-- Force longitudinale maximale d'un essieu en ligne droite (deux roues de charge F/2).
local function axleLongitudinal(tyre, d, F, gammaS)
  if F <= 0 then return 0 end
  return 2 * mu(tyre, d, F / 2) * camberFactor(tyre, gammaS) * F / 2
end

-- Couple moteur à pleine charge (N·m) avec turbo(s) : T·(1 + pression).
local function engineTorque(eff, rpm)
  local torque = Util.lutEval(eff.torque, max(rpm, eff.rpmMin))
  local boost = 0
  for _, turbo in ipairs(eff.turbos) do boost = boost + turbo.boost * min(1, rpm / turbo.refRpm) end
  return torque * (1 + boost)
end

-- Écrasement d'un essieu (m) sous la charge aérodynamique F (N), depuis l'assiette statique (H16) : deux
-- ressorts de coin et ressort de pilonnage jusqu'à la course avant butée (PACKER_RANGE, comptée depuis
-- l'assiette statique), puis butées en plus ; pneus en série. s : eff.suspF / eff.suspR. Renvoie aussi
-- la course de suspension.
local function axleDrop(F, s)
  if F <= 0 then return 0, 0 end
  local k = max(1, s.spring2 + s.heave)
  local x = F / k
  if s.gap and s.gap > 0 and x > s.gap then x = s.gap + (F - k * s.gap) / (k + s.bump2) end
  return x + F / max(1, s.tyre2), x
end
M.axleDrop = axleDrop

-- Intégrale ∫ |H(f)|² / f² df de la variation d'effort vertical du pneu d'un quart de véhicule sur une
-- route d'altitude aléatoire (H17) : masse suspendue ms et non suspendue mu (kg), raideur de suspension k
-- et du pneu kt (N/m), amortissement lent sous K.damperSwitchHz et rapide au-dessus (N·s/m) ; bande
-- [K.roughBandLo ; K.roughBandHi], trapèzes en pas logarithmiques. Variance de l'effort : G0·n0²·v·I.
function M.quarterCarIntegral(ms, mu, k, cSlow, cFast, kt)
  local n, lo, hi = K.roughFreqPoints, K.roughBandLo, K.roughBandHi
  local ratio = (hi / lo) ^ (1 / (n - 1))
  local sum, fPrev, gPrev = 0, nil, nil
  for j = 1, n do
    local f = lo * ratio ^ (j - 1)
    local w = 2 * math.pi * f
    local c = f < K.damperSwitchHz and cSlow or cFast
    -- A = Zs/Zu = (k + iwc) / (k − ms·w² + iwc)
    local nr, ni = k, w * c
    local dr, di = k - ms * w * w, w * c
    local den = dr * dr + di * di
    local ar, ai = (nr * dr + ni * di) / den, (ni * dr - nr * di) / den
    -- D = kt + k − mu·w² + iwc − (k + iwc)·A ; Zu = kt / D ; effort du pneu kt·(1 − Zu)
    local pr, pi = nr * ar - ni * ai, nr * ai + ni * ar
    local Dr, Di = kt + k - mu * w * w - pr, w * c - pi
    local dd = Dr * Dr + Di * Di
    local zr, zi = kt * Dr / dd, -kt * Di / dd
    local fr, fi = kt * (1 - zr), -kt * zi
    local g = (fr * fr + fi * fi) / (f * f)
    if fPrev then sum = sum + 0.5 * (g + gPrev) * (f - fPrev) end
    fPrev, gPrev = f, g
  end
  return sum
end

-- Quart de véhicule d'un essieu (H18), dans la table q (réutilisée) : raideur de coin plus la moitié du
-- pilonnage, butées en plus une fois la course avant butée consommée ; amortisseurs de coin plus la
-- moitié du pilonnage ; pneu à sa raideur à la pression de fonctionnement. Intégrales butées libres et
-- en appui, seulement si la rugosité est connue (coût).
local function quarterCar(q, eff, share, spring, heave, bump, cSlow, cFast, heaveDamp, tyreRate, hub)
  q.ms, q.mu = max(10, eff.mass * share / 2 - hub), hub
  q.k, q.bump, q.kt = max(1000, spring + heave / 2), bump, tyreRate
  q.cSlow = max(K.minDamping, (cSlow or 0) + heaveDamp / 2)
  q.cFast = max(K.minDamping, (cFast or cSlow or 0) + heaveDamp / 2)
  q.static = eff.mass * G * share / 2
  if eff.roughness > 0 then
    q.off = M.quarterCarIntegral(q.ms, q.mu, q.k, q.cSlow, q.cFast, q.kt)
    q.on = M.quarterCarIntegral(q.ms, q.mu, q.k + bump, q.cSlow, q.cFast, q.kt)
  else
    q.off, q.on = 0, 0
  end
  return q
end

-- Pression à chaud d'un essieu : mesurée (calibration), sinon déduite de la pression à froid à la
-- température mesurée de l'essieu (pressureTemp) ou à celle du pneu, plus l'écart mesuré à la loi des gaz.
local function hotOf(conditions, tyre, cold, measured, temp, pressureTemp, offset)
  if measured then return measured end
  temp = pressureTemp or temp or conditions.tyreTemp or M.runningTemp(tyre, conditions)
  return M.hotPressure(cold, conditions.airTemp, temp) + (offset or 0)
end

-- Raideur radiale d'un pneu à sa pression de fonctionnement (PRESSURE_SPRING_GAIN par psi au-dessus de
-- PRESSURE_STATIC), bornée à 30 % de RATE.
local function tyreRateAt(tyre, hot)
  local rate = tyre.rate or 250000
  if tyre.pressureStatic then rate = rate + (tyre.pressureSpringGain or 0) * (hot - tyre.pressureStatic) end
  return max(0.3 * (tyre.rate or 250000), rate)
end

-- Écrasement statique d'un essieu (m) sous sa charge F (N) : ressorts de coin et de pilonnage, pneus à
-- leur pression à froid (voiture au repos) ; pas de butée au repos. Table de travail réutilisée (S09).
local staticSusp = { spring2 = 0, heave = 0, bump2 = 0, tyre2 = 0 }
local function staticDrop(F, spring, heave, tyre, cold)
  staticSusp.spring2, staticSusp.heave = 2 * spring, heave or 0
  staticSusp.tyre2 = 2 * tyreRateAt(tyre, cold)
  return (axleDrop(F, staticSusp))
end

-- Perte d'adhérence d'un essieu par variation de charge (H19) : sensibilité à la charge du pneu
-- (F^LS_EXPY concave), soit 1 + e(e − 1)/2·(σ/F)², à l'appui axleLift de la vitesse v.
local function bumpGripAt(eff, q, tyre, susp, axleLift, v)
  local G0 = eff.roughness
  if G0 <= 0 or tyre.lsExpY == nil then return 1 end
  local _, travel = axleDrop(max(0, axleLift), susp)
  local onPackers = susp.gap and susp.gap > 0 and travel > susp.gap
  local sigma = M.loadSigma(q, G0, v, onPackers)
  local F = q.static + max(0, axleLift) / 2
  local e = tyre.lsExpY
  return Util.clamp(1 + e * (e - 1) / 2 * (sigma / max(1, F)) ^ 2, K.roughGripMin, 1)
end

-- Écart type de l'effort vertical du pneu (N) à la vitesse v, rugosité G0 (m³), butées en appui ou non.
function M.loadSigma(q, G0, v, onPackers)
  return math.sqrt(max(0, G0) * K.roughN0 * K.roughN0 * max(0, v) * (onPackers and q.on or q.off))
end

-- Rugosité de la piste (H17 : G0, densité spectrale du profil de route à K.roughN0, en m³) estimée sur un
-- tour enregistré : écart type de la charge des roues en ligne droite (lap.loadSigma, lap.roughSpeed),
-- contre la réponse du quart de véhicule du setup du tour à cette vitesse, essieu par essieu. Renvoie
-- { G0 (moyenne géométrique), front, rear, speed, consistent } ou nil. tick : rendu coopératif.
function M.roughness(base, setup, lap, conditions, tick)
  if not (lap and lap.loadSigma and Util.isFinite(lap.roughSpeed) and lap.roughSpeed > 0) then return nil end
  local c = {}
  for key, value in pairs(conditions or {}) do c[key] = value end
  c.roughness = 1
  local eff = M.configure(base, setup, c, tick)
  if eff == nil then return nil end
  local v = lap.roughSpeed
  local i = min(eff.speedCount, floor(v / eff.dv) + 1)
  local out = { speed = v }
  for _, axle in ipairs({ 'F', 'R' }) do
    local q, susp = eff['quarter' .. axle], eff['susp' .. axle]
    local axleLift = axle == 'F' and eff.liftFront[i] or eff.lift[i] - eff.liftFront[i]
    local _, travel = axleDrop(max(0, axleLift), susp)
    local integral = (susp.gap and susp.gap > 0 and travel > susp.gap) and q.on or q.off
    local w1, w2 = axle == 'F' and 1 or 3, axle == 'F' and 2 or 4
    local sigma = (lap.loadSigma[w1] + lap.loadSigma[w2]) / 2
    if not (integral > 0 and Util.isFinite(sigma)) then return nil end
    out[axle == 'F' and 'front' or 'rear'] = sigma * sigma / (K.roughN0 * K.roughN0 * v * integral)
  end
  if not (out.front > 0 and out.rear > 0) then return nil end
  out.G0 = math.sqrt(out.front * out.rear)
  out.consistent = max(out.front, out.rear) / min(out.front, out.rear) <= K.roughConsistency
    and max(out.front, out.rear) <= K.roughMaxG0
  return out
end

-- Appui, part avant et traînée à la vitesse v (m/s), avec écrasement de la suspension ; drsOpen :
-- volet DRS ouvert (aile eff.drsWing, contribution réduite de eff.drsEffect, hypothèse H8).
local function aeroAt(eff, v, drsOpen)
  local q = 0.5 * eff.rho * v * v
  local hF, hR = eff.rideF, eff.rideR
  local lift, liftFront, drag = 0, 0, 0
  local kmh = v * 3.6
  for _ = 1, K.aeroIterations do
    lift, liftFront, drag = 0, 0, 0
    local rake = math.deg(math.atan((hR - hF) / eff.wheelbase))
    for _, w in ipairs(eff.wings) do
      local angle = w.angleSetup
      for _, c in ipairs(w.controllers) do
        local value = Util.lutEval(c.lut, kmh)
        angle = c.combinator == 'MULT' and angle * value or angle + value
        angle = Util.clamp(angle, c.down, c.up)
      end
      local aoa = angle + rake
      local share = (w.z + eff.b) / eff.wheelbase
      local h = hR + (hF - hR) * Util.clamp(share, 0, 1) + w.hOffset
      local scale = (drsOpen and w.index == eff.drsWing) and 1 - eff.drsEffect or 1
      local cl = (w.cl and Util.lutEval(w.cl, aoa) or 0) * w.clGain * (w.ghCl and Util.lutEval(w.ghCl, h) or 1) * scale
      local cd = (w.cd and Util.lutEval(w.cd, aoa) or 0) * w.cdGain * (w.ghCd and Util.lutEval(w.ghCd, h) or 1) * scale
      local l = q * cl * w.area * eff.factors.lift
      lift = lift + l
      liftFront = liftFront + l * Util.clamp(share, -0.5, 1.5)
      drag = drag + q * cd * w.area * eff.factors.drag
    end
    -- écrasement : charge aérodynamique par essieu, suspension jusqu'aux butées puis butées, pneus (H16)
    hF = eff.rideF - axleDrop(max(0, liftFront), eff.suspF)
    hR = eff.rideR - axleDrop(max(0, lift - liftFront), eff.suspR)
  end
  return lift, liftFront, drag, hF, hR
end

-- Transferts de charge latéraux (N, par roue) sous l'accélération ay, répartis selon la raideur au
-- roulis et bornés au décollement : un essieu ne transfère pas plus que la moitié de sa charge ; le
-- moment en excès passe sur l'autre essieu. Renvoie nil au-delà du renversement.
function M.lateralTransfers(eff, ay, FzF, FzR)
  local moment = eff.mass * ay * eff.cgHeight
  local capF, capR = FzF / 2 * eff.trackF, FzR / 2 * eff.trackR
  if moment > capF + capR then return nil end
  local mF, mR = moment * eff.rollShareF, moment * (1 - eff.rollShareF)
  if mF > capF then mF, mR = capF, mR + (mF - capF) end
  if mR > capR then mF, mR = mF + (mR - capR), capR end
  return mF / eff.trackF, mR / eff.trackR
end

-- Capacités latérales des deux essieux sous ay (nil : renversement).
local function lateralCapacities(eff, ay, FzF, FzR)
  local dF, dR = M.lateralTransfers(eff, ay, FzF, FzR)
  if dF == nil then return nil end
  local roll = eff.mass * ay * eff.cgHeight / eff.rollStiffness * (1 - K.camberRecovery)
  local capF = axleLateral(eff.tyreF, eff.dF, FzF / 2 + dF, FzF / 2 - dF, eff.camberRadF, roll)
  local capR = axleLateral(eff.tyreR, eff.dR, FzR / 2 + dR, FzR / 2 - dR, eff.camberRadR, roll)
  return capF, capR, dF, dR
end

-- Marge latérale sous ay (N) : la plus petite des réserves des deux essieux, chacun devant fournir sa
-- part m·ay·(bras de levier)/empattement ; ≥ 0 : tenable ; nil : renversement.
local function lateralMargin(eff, ay, FzF, FzR)
  local capF, capR = lateralCapacities(eff, ay, FzF, FzR)
  if capF == nil then return nil end
  local m = eff.mass
  return min(capF - m * ay * eff.b / eff.wheelbase, capR - m * ay * eff.a / eff.wheelbase)
end

-- Plus grande accélération latérale tenable (m/s²), du côté tenable, à K.lateralTolerance près :
-- encadrement autour de guess (valeur de la vitesse voisine), puis fausse position (variante d'Illinois)
-- avec repli sur la dichotomie si l'intervalle ne se resserre pas assez. La marge décroît avec ay.
local function solveLateral(eff, FzF, FzR, guess)
  local top = K.ayMaxG * G
  local x = Util.clamp(guess or 0.5 * top, 0, top)
  local gx = lateralMargin(eff, x, FzF, FzR)
  local step = K.lateralBracket
  local lo, glo, hi, ghi
  if gx and gx >= 0 then
    lo, glo = x, gx
    while hi == nil do
      if lo >= top then return top end
      local y = min(top, lo + step)
      local gy = lateralMargin(eff, y, FzF, FzR)
      if gy and gy >= 0 then lo, glo, step = y, gy, 2 * step else hi, ghi = y, gy end
    end
  else
    hi, ghi = x, gx
    while lo == nil do
      local y = max(0, hi - step)
      local gy = lateralMargin(eff, y, FzF, FzR)
      if (gy and gy >= 0) or y <= 0 then lo, glo = y, max(0, gy or 0) else hi, ghi, step = y, gy, 2 * step end
    end
  end
  local side, width = 0, hi - lo
  for _ = 1, K.lateralMaxIterations do
    if hi - lo <= K.lateralTolerance then break end
    local w = hi - lo
    local y
    if ghi ~= nil and glo - ghi > 0 and w <= 0.5 * width then
      -- fausse position, tenue à l'intérieur de l'intervalle
      y = Util.clamp(lo + glo * w / (glo - ghi), lo + 0.02 * w, hi - 0.02 * w)
    else
      y = lo + 0.5 * w
    end
    width = w
    local gy = lateralMargin(eff, y, FzF, FzR)
    if gy and gy >= 0 then
      lo, glo = y, gy
      if side == 1 and ghi then ghi = 0.5 * ghi end
      side = 1
    else
      hi, ghi = y, gy
      if side == -1 then glo = 0.5 * glo end
      side = -1
    end
  end
  return lo
end

M.lateralMargin, M.solveLateral = lateralMargin, solveLateral

-- Accélération latérale maximale (m/s²) au facteur de charge normale n ; guess : valeur voisine (même
-- charge, vitesse précédente ou volet fermé), point de départ de la résolution.
local function lateralLimit(eff, n, lift, liftFront, guess)
  local m = eff.mass
  local FzF = m * G * n * eff.b / eff.wheelbase + max(0, liftFront)
  local FzR = m * G * n * eff.a / eff.wheelbase + max(0, lift - liftFront)
  -- équilibre (§8.3) à la limite : E = marge avant / marge arrière ; E > 1, l'arrière sature d'abord
  -- (survirage) ; E < 1, sous-virage.
  local ay = solveLateral(eff, FzF, FzR, guess)
  local capF, capR, dF, dR = lateralCapacities(eff, ay, FzF, FzR)
  if capF == nil then capF, capR, dF, dR = 0, 0, 0, 0 end
  local needF = max(1e-6, m * ay * eff.b / eff.wheelbase)
  local needR = max(1e-6, m * ay * eff.a / eff.wheelbase)
  local balance = ay > 0 and capR > 0 and (capF / needF) / (capR / needR) or 1
  return ay, balance, FzF, FzR, dF, dR
end

-- Décélération maximale de freinage (m/s²) avec transfert de charge et répartition imposée.
-- rearFirst : l'essieu arrière atteint sa limite d'adhérence avant l'avant (instabilité, §8.4) ;
-- non compté quand le couple de freinage limite seul.
local function brakeLimit(eff, FzF, FzR)
  local m, h, bias = eff.mass, eff.cgHeight, eff.brakeBias
  local decel, rearFirst = 0, false
  for _ = 1, K.longitudinalIterations do
    local shift = m * decel * h / eff.wheelbase
    local capF = axleLongitudinal(eff.tyreF, eff.dF * eff.longGripF, FzF + shift, eff.camberRadF)
    local capR = axleLongitudinal(eff.tyreR, eff.dR * eff.longGripR, max(0, FzR - shift), eff.camberRadR)
    local byFront, byRear = capF / bias, capR / max(1e-6, 1 - bias)
    rearFirst = byRear < byFront and byRear < eff.brakeForceMax
    decel = min(byFront, byRear, eff.brakeForceMax) / m
  end
  return decel, rearFirst
end

-- Accélération maximale permise par l'adhérence de l'essieu moteur (ligne droite).
local function tractionLimit(eff, FzF, FzR)
  local m, h = eff.mass, eff.cgHeight
  local acc = 0
  for _ = 1, K.longitudinalIterations do
    local shift = m * acc * h / eff.wheelbase
    local capF = axleLongitudinal(eff.tyreF, eff.dF * eff.longGripF, max(0, FzF - shift), eff.camberRadF)
    local capR = axleLongitudinal(eff.tyreR, eff.dR * eff.longGripR, FzR + shift, eff.camberRadR)
    local force
    if eff.traction == 'FWD' then
      force = capF
    elseif eff.traction == 'AWD' then
      local share = Util.clamp(eff.awdFrontShare, 0.05, 0.95)
      force = min(capF / share, capR / (1 - share))
    else
      force = capR
    end
    acc = force / m
  end
  return acc
end

-- Force motrice au rapport g et à la vitesse v (N), sans coupure : la vitesse au limiteur du rapport
-- (eff.gearVmax) est contrôlée à part. Tables continues par rapport : pas de dents de scie quand la
-- vitesse au limiteur d'un rapport franchit un point de la table.
local function gearForce(eff, g, v)
  local total = eff.gears[g] * eff.final
  local rpm = v / eff.wheelRadius * total * 60 / (2 * math.pi)
  return engineTorque(eff, min(rpm, eff.limiter)) * total * K.drivetrainEfficiency * eff.factors.power / eff.wheelRadius
end

-- Force motrice maximale à la vitesse exacte v (meilleur rapport sous son limiteur).
local function envelopeForce(eff, v)
  local best = 0
  for g = 1, eff.gearCount do
    if v <= eff.gearVmax[g] then
      local f = gearForce(eff, g, v)
      if f > best then best = f end
    end
  end
  return best
end

-- Vitesse de pointe : force motrice (au régime exact) = traînée + roulement, par dichotomie dans le
-- premier intervalle de la table où l'accélération devient nulle.
local function topSpeedOf(eff, drag, rr0, rr1)
  local dv, count, force = eff.dv, eff.speedCount, eff.force
  for i = 2, count do
    if force[i] - drag[i] - (rr0 + rr1 * ((i - 1) * dv) ^ 2) <= 0 then
      local lo, hi = (i - 2) * dv, (i - 1) * dv
      for _ = 1, 30 do
        local v = 0.5 * (lo + hi)
        local t = (v - (i - 2) * dv) / dv
        local resist = drag[i - 1] + (drag[i] - drag[i - 1]) * t + rr0 + rr1 * v * v
        if envelopeForce(eff, v) > resist then lo = v else hi = v end
      end
      return lo
    end
  end
  return (count - 1) * dv
end

-- Réutilise (ou crée) un tableau de eff, ou une liste de rows tableaux.
local function array(eff, name)
  local a = eff[name]
  if a == nil then
    a = {}
    eff[name] = a
  end
  return a
end

local function grid(eff, name, rows)
  local a = array(eff, name)
  for j = 1, rows do
    if a[j] == nil then a[j] = {} end
  end
  return a
end


-- Construit les tables de performance. setup : réglages physiques (voir defaultSetup) ;
-- conditions : { airTemp, roadTemp, roadGrip, surfaceGrip, fuelRate?, tyreTemp?, tyreKm?, tyreTempF/R?,
-- tyreKmF/R?, hotPressureF/R?, factors?, driverMargin? } (état des pneus d'un tour mesuré ou d'un tour
-- de relais ; fuelRate : taux de consommation de la session) ;
-- reuse : résultat d'un appel précédent pour la même voiture, dont les tableaux sont réutilisés (aucune
-- allocation par évaluation dans l'optimiseur).
function M.configure(base, setup, conditions, tick, reuse)
  tick = tick or noop
  conditions = conditions or NO_CONDITIONS
  local factors = conditions.factors or DEFAULT_FACTORS
  local compound = base.compounds[setup.compound] or base.compounds[1]
  if compound == nil then return nil, 'aucun composé de pneus lisible' end
  if base.torque == nil or #setup.gears == 0 then return nil, 'moteur ou boîte illisible' end
  local eff = reuse or {}
  eff.factors, eff.compound, eff.tyreF, eff.tyreR = factors, compound, compound.front, compound.rear
  eff.rho = airDensity(conditions.airTemp)
  eff.mass = base.massDry + base.ballast + max(0, setup.fuel) * K.fuelDensity
  eff.wheelbase, eff.trackF, eff.trackR, eff.cgHeight = base.wheelbase, base.trackF, base.trackR, base.cgHeight
  eff.traction, eff.awdFrontShare = base.traction or 'RWD', base.awdFrontShare or 0.4
  eff.torque, eff.rpmMin, eff.limiter = base.torque, base.rpmMin, base.limiter * (setup.limiterPct or 1)
  eff.turbos, eff.gears, eff.gearCount, eff.final = base.turbos, setup.gears, #setup.gears, setup.final
  eff.shiftUpTime = base.shiftUpTime
  eff.brakeBias = Util.clamp(setup.brakeBias, 0.3, 0.95)
  eff.diffPower, eff.diffCoast = Util.clamp(setup.diffPower, 0, 1), Util.clamp(setup.diffCoast, 0, 1)
  eff.diffPreload = max(0, setup.diffPreload or 0)
  -- H20 : moment de lacet du différentiel bloqué, ramené à la marge latérale de l'avant : force motrice
  -- admissible = (1 − ay/capacité)·m·capacité·diffYawK, avec diffYawK = 2·b / (blocage·voie motrice)
  -- (b : bras de levier de l'avant, centre de gravité – essieu arrière)
  local driven = (base.traction or 'RWD') == 'FWD' and base.trackF or base.trackR
  eff.diffYawK = eff.diffPower > 1e-6 and 2 * base.wheelbase * base.cgFront / (eff.diffPower * driven) or nil
  eff.camberRadF, eff.camberRadR = math.rad(setup.camberF), math.rad(setup.camberR)
  eff.a = eff.wheelbase * (1 - base.cgFront)   -- CG -> essieu avant
  eff.b = eff.wheelbase * base.cgFront         -- CG -> essieu arrière
  eff.wheelRadius = (eff.traction == 'FWD' and compound.front.radius or compound.rear.radius)
  local grip = Util.finiteOr(conditions.roadGrip, 1) * Util.finiteOr(conditions.surfaceGrip, 1) * factors.mu
    * (1 + Util.finiteOr(conditions.driverMargin, 0))
  -- pression à chaud de chaque essieu : mesurée (calibration), sinon déduite de la pression à froid
  local hotF = hotOf(conditions, compound.front, setup.pressureF, conditions.hotPressureF, conditions.tyreTempF,
    conditions.pressureTempF, conditions.pressureOffsetF)
  local hotR = hotOf(conditions, compound.rear, setup.pressureR, conditions.hotPressureR, conditions.tyreTempR,
    conditions.pressureTempR, conditions.pressureOffsetR)
  eff.hotF, eff.hotR = hotF, hotR
  -- piste mouillée (H25) : film d'eau, selon la classe du pneu ; l'aquaplanage dépend de la vitesse (plus bas)
  local wetness = Util.clamp(Util.finiteOr(conditions.wetness, 0), 0, 1)
  eff.wetness, eff.waterMm = wetness, wetness > 0 and M.waterDepth(conditions) or 0
  eff.wetF, eff.wetR = M.wetSurfaceFactor(compound.front, wetness), M.wetSurfaceFactor(compound.rear, wetness)
  eff.dF = compound.front.dyRef * grip * eff.wetF * gripMultiplier(compound.front, setup.pressureF, conditions, hotF,
    conditions.tyreTempF, conditions.tyreKmF)
  eff.dR = compound.rear.dyRef * grip * eff.wetR * gripMultiplier(compound.rear, setup.pressureR, conditions, hotR,
    conditions.tyreTempR, conditions.tyreKmR)
  local rateF, rateR = tyreRateAt(compound.front, hotF), tyreRateAt(compound.rear, hotR)
  -- En longitudinal (freinage, motricité), le pneu suit DX_REF au lieu de DY_REF.
  eff.longGripF = (compound.front.dxRef or compound.front.dyRef) / compound.front.dyRef
  eff.longGripR = (compound.rear.dxRef or compound.rear.dyRef) / compound.rear.dyRef
  -- Hypothèse H3 : AC applique MAX_TORQUE × part de l'essieu à chacune de ses deux roues, d'où un
  -- couple total de 2 × MAX_TORQUE, ramené au sol par le rayon de chaque essieu.
  if base.brakeTorque then
    local torque = 2 * base.brakeTorque * (setup.brakePower or 1) * factors.brake
    eff.brakeForceMax = torque * (eff.brakeBias / compound.front.radius + (1 - eff.brakeBias) / compound.rear.radius)
  else
    eff.brakeForceMax = math.huge
  end
  -- Raideur au roulis (§8.3), raideurs à la roue : ressorts k·t²/2 ; barre k·t² (hypothèse H2 : AC
  -- applique k·(course gauche − course droite) à chaque roue).
  local kF = setup.springF * eff.trackF * eff.trackF / 2 + setup.arbF * eff.trackF * eff.trackF
  local kR = setup.springR * eff.trackR * eff.trackR / 2 + setup.arbR * eff.trackR * eff.trackR
  eff.rollStiffness = max(1000, kF + kR)
  eff.rollShareF = Util.clamp(kF / max(1, kF + kR), 0.05, 0.95)
  -- Raideur verticale par essieu (ressorts en série avec le pneu, plus le ressort de pilonnage).
  local heaveF, heaveR = setup.heaveF or base.heaveF or 0, setup.heaveR or base.heaveR or 0
  local bumpF, bumpR = setup.bumpStopF or base.bumpStopF or 0, setup.bumpStopR or base.bumpStopR or 0
  local suspF, suspR = array(eff, 'suspF'), array(eff, 'suspR')
  suspF.spring2, suspF.heave, suspF.bump2, suspF.gap, suspF.tyre2 = 2 * setup.springF, heaveF, 2 * bumpF,
    setup.packerF or base.packerF, 2 * rateF
  suspR.spring2, suspR.heave, suspR.bump2, suspR.gap, suspR.tyre2 = 2 * setup.springR, heaveR, 2 * bumpR,
    setup.packerR or base.packerR, 2 * rateR
  -- variation de charge sur la rugosité de la piste (H17 à H19) : seulement si elle a été mesurée
  eff.roughness = Util.finiteOr(conditions.roughness, 0)
  quarterCar(array(eff, 'quarterF'), eff, eff.b / eff.wheelbase, setup.springF, heaveF, bumpF,
    setup.dampSlowF or base.dampSlowF, setup.dampFastF or base.dampFastF, base.heaveDampF or 0, rateF, base.hubF or 30)
  quarterCar(array(eff, 'quarterR'), eff, eff.a / eff.wheelbase, setup.springR, heaveR, bumpR,
    setup.dampSlowR or base.dampSlowR, setup.dampFastR or base.dampFastR, base.heaveDampR or 0, rateR, base.hubR or 30)
  -- Hauteur de caisse statique : référence (mesurée avec le setup courant, ou par défaut avec les tiges
  -- de suspensions.ini) + écart de longueur de tige par rapport à cette référence.
  eff.rideF = base.rideHeightF + (setup.rodF - (base.rodRefF or base.rodF))
  eff.rideR = base.rideHeightR + (setup.rodR - (base.rodRefR or base.rodR))
  -- Écrasement statique par rapport à la mesure de référence (relecture J6b, M3) : masse (carburant),
  -- ressorts et pression à froid. refAt : hauteur du setup de référence avec la masse de ce setup.
  local refAtF, refAtR = base.rideHeightF, base.rideHeightR
  local ref = base.rideRef
  if ref and Util.isFinite(base.rideRefFuel) and Util.isFinite(base.massDry) then
    local massRef = base.massDry + (base.ballast or 0) + max(0, base.rideRefFuel) * K.fuelDensity
    local shareF, shareR = eff.b / eff.wheelbase, eff.a / eff.wheelbase
    local springRefF, springRefR = ref.springF or base.springF, ref.springR or base.springR
    local heaveRefF, heaveRefR = ref.heaveF or base.heaveF or 0, ref.heaveR or base.heaveR or 0
    local coldRefF, coldRefR = ref.pressureF or setup.pressureF, ref.pressureR or setup.pressureR
    local dropRefF = staticDrop(massRef * G * shareF, springRefF, heaveRefF, compound.front, coldRefF)
    local dropRefR = staticDrop(massRef * G * shareR, springRefR, heaveRefR, compound.rear, coldRefR)
    local loadF, loadR = eff.mass * G * shareF, eff.mass * G * shareR
    eff.rideF = eff.rideF - (staticDrop(loadF, setup.springF, heaveF, compound.front, setup.pressureF) - dropRefF)
    eff.rideR = eff.rideR - (staticDrop(loadR, setup.springR, heaveR, compound.rear, setup.pressureR) - dropRefR)
    refAtF = refAtF - (staticDrop(loadF, springRefF, heaveRefF, compound.front, coldRefF) - dropRefF)
    refAtR = refAtR - (staticDrop(loadR, springRefR, heaveRefR, compound.rear, coldRefR) - dropRefR)
  end
  -- DRS (§8.9) : tables volet ouvert seulement si demandé (qualification, tours en trafic) et utilisable
  local drs = base.drs
  eff.drsOn = conditions.drs == true and drs ~= nil and drs.usable == true
  eff.drsWing, eff.drsEffect = drs and drs.wing or -1, drs and drs.effect or 0
  eff.drsLimitG = drs and drs.limitG or nil
  local wings = array(eff, 'wings')
  for i, w in ipairs(base.wings) do
    local entry = wings[i]
    if entry == nil then
      entry = {}
      wings[i] = entry
    end
    entry.index, entry.area, entry.z, entry.cl, entry.cd, entry.ghCl, entry.ghCd = w.index, w.area, w.z, w.cl, w.cd, w.ghCl, w.ghCd
    entry.clGain, entry.cdGain = w.clGain, w.cdGain
    entry.hOffset = base.wingHeightOffset and base.wingHeightOffset[w.index] or 0
    entry.angleSetup = setup.wingAngles[w.index] or w.angle
    entry.controllers = M.controllersOf(base, w.index)
  end
  for i = #base.wings + 1, #wings do wings[i] = nil end
  -- Vitesses au limiteur de chaque rapport.
  local gearVmax = array(eff, 'gearVmax')
  for g = 1, eff.gearCount do
    gearVmax[g] = eff.limiter * 2 * math.pi / 60 * eff.wheelRadius / (eff.gears[g] * eff.final)
  end
  -- Tables en fonction de la vitesse (pas K.speedStep) et du facteur de charge normale.
  local dv = K.speedStep
  local count = math.ceil(K.speedMax / dv) + 1
  local loads = K.normalLoads
  eff.dv, eff.speedCount, eff.loads = dv, count, loads
  eff.loadMin, eff.loadStep = loads[1], loads[2] - loads[1]   -- charges régulièrement espacées
  -- taux de consommation de la session (0 : aucune consommation ; borné, donnée non fiable D11)
  eff.consumption = base.fuelConsumption and base.fuelConsumption
    * Util.clamp(Util.finiteOr(conditions.fuelRate, 1), 0, K.maxSessionRate) or nil
  local lift, liftFront, drag = array(eff, 'lift'), array(eff, 'liftFront'), array(eff, 'drag')
  local force, gear, rollRes, rpm = array(eff, 'force'), array(eff, 'gear'), array(eff, 'rollRes'), array(eff, 'rpm')
  local rideAtF, rideAtR = array(eff, 'rideAtF'), array(eff, 'rideAtR')
  local gearMinSpeed = array(eff, 'gearMinSpeed')
  local gearForceTab = grid(eff, 'gearForce', eff.gearCount)
  for g = 1, eff.gearCount do gearMinSpeed[g] = math.huge end
  local ay, balance = grid(eff, 'ay', #loads), grid(eff, 'balance', #loads)
  local brake, rearFirst = grid(eff, 'brake', #loads), grid(eff, 'rearFirst', #loads)
  local tractionCap, diffTransfer = grid(eff, 'tractionCap', #loads), array(eff, 'diffTransfer')
  -- ERS (§8.9) : tables seulement si demandé (plan de déploiement fourni) ; capacité longitudinale de
  -- l'essieu avant pour les moteurs avant
  local ersSpec = conditions.ersSpec
  local ersOn = ersSpec ~= nil and ersSpec.usable == true
  local frontCap = ersOn and grid(eff, 'ersFrontCap', #loads) or nil
  local dF0, dR0 = eff.dF, eff.dR
  local bumpGripF, bumpGripR = array(eff, 'bumpGripF'), array(eff, 'bumpGripR')
  local rr0 = 2 * (compound.front.rr0 + compound.rear.rr0)
  local rr1 = 2 * (compound.front.rr1 + compound.rear.rr1)
  local minGear = 1
  -- Première passe, toutes les vitesses : appui, traînée, forces de traction, perte d'adhérence sur la
  -- rugosité ; la vitesse de pointe s'en déduit.
  for i = 1, count do
    if i % 4 == 0 then tick() end
    local v = (i - 1) * dv
    local l, lf, d, hF, hR = aeroAt(eff, v)
    lift[i], liftFront[i], drag[i] = l, lf, d
    rideAtF[i], rideAtR[i] = hF, hR
    -- forces par rapport ; enveloppe monotone (une seule montée par rapport) pour le carburant et
    -- l'hystérésis de rétrogradation
    local best, bestGear = 0, nil
    for g = 1, eff.gearCount do
      local f = gearForce(eff, g, v)
      gearForceTab[g][i] = f
      if g >= minGear and v <= gearVmax[g] and f > best then best, bestGear = f, g end
    end
    if bestGear == nil then
      force[i], gear[i], rpm[i] = 0, eff.gearCount, eff.limiter
    else
      force[i], gear[i] = best, bestGear
      rpm[i] = max(eff.rpmMin, v / eff.wheelRadius * eff.gears[bestGear] * eff.final * 60 / (2 * math.pi))
      for g = minGear, bestGear do
        if gearMinSpeed[g] == math.huge then gearMinSpeed[g] = v end
      end
      minGear = bestGear
    end
    rollRes[i] = rr0 + rr1 * v * v
    bumpGripF[i] = bumpGripAt(eff, eff.quarterF, compound.front, suspF, lf, v)
    bumpGripR[i] = bumpGripAt(eff, eff.quarterR, compound.rear, suspR, l - lf, v)
    -- aquaplanage (H26) : adhérence de chaque essieu selon la vitesse et l'eau au-delà des rainures
    if eff.waterMm > 0 then
      bumpGripF[i] = bumpGripF[i] * M.aquaplaneFactor(compound.front, eff.waterMm, v)
      bumpGripR[i] = bumpGripR[i] * M.aquaplaneFactor(compound.rear, eff.waterMm, v)
    end
  end
  eff.topSpeed = topSpeedOf(eff, drag, rr0, rr1)
  -- DRS ouvert : traînée et appui volet ouvert, vitesse de pointe volet ouvert
  local liftOpen, liftFrontOpen = nil, nil
  if eff.drsOn then
    local dragOpen = array(eff, 'dragOpen')
    liftOpen, liftFrontOpen = array(eff, 'liftOpen'), array(eff, 'liftFrontOpen')
    for i = 1, count do
      if i % 4 == 0 then tick() end
      liftOpen[i], liftFrontOpen[i], dragOpen[i] = aeroAt(eff, (i - 1) * dv, true)
    end
    eff.topSpeedOpen = topSpeedOf(eff, dragOpen, rr0, rr1)
  end
  -- Seconde passe, jusqu'à la vitesse la plus haute que la simulation peut atteindre (vitesse de pointe,
  -- volet ouvert compris : la vitesse limite du tour ne la dépasse jamais) : adhérence latérale,
  -- freinage, motricité. Au-delà, ligne recopiée (jamais lue).
  local reach = min(count, floor(max(eff.topSpeed, eff.topSpeedOpen or 0) / dv) + 2)
  eff.tableReach = reach
  for i = 1, reach do
    if i % 4 == 0 then tick() end
    local l, lf = lift[i], liftFront[i]
    eff.dF, eff.dR = dF0 * bumpGripF[i], dR0 * bumpGripR[i]
    for j = 1, #loads do
      local a, e, FzF, FzR, dF, dR = lateralLimit(eff, loads[j], l, lf, i > 1 and ay[j][i - 1] or nil)
      ay[j][i], balance[j][i] = a, e
      local decel, first = brakeLimit(eff, FzF, FzR)
      brake[j][i], rearFirst[j][i] = decel, first and 1 or 0
      tractionCap[j][i] = tractionLimit(eff, FzF, FzR)
      if frontCap then
        frontCap[j][i] = axleLongitudinal(eff.tyreF, eff.dF * eff.longGripF, FzF, eff.camberRadF) / eff.mass
      end
      if j == K.normalLoadNominal then
        -- transfert de charge relatif de l'essieu moteur par m/s² d'accélération latérale
        local dd, Fz = dR, FzR
        if eff.traction == 'FWD' then dd, Fz = dF, FzF end
        diffTransfer[i] = Util.clamp(dd / max(1, Fz / 2) / max(1e-6, a), 0, 1)
      end
    end
  end
  for i = reach + 1, count do
    for j = 1, #loads do
      ay[j][i], balance[j][i], brake[j][i] = ay[j][reach], balance[j][reach], brake[j][reach]
      rearFirst[j][i], tractionCap[j][i] = rearFirst[j][reach], tractionCap[j][reach]
      if frontCap then frontCap[j][i] = frontCap[j][reach] end
    end
    diffTransfer[i] = diffTransfer[reach]
  end
  eff.dF, eff.dR = dF0, dR0
  if ersOn then Ers.tables(ersSpec, eff) else eff.ersOn = false end
  -- DRS ouvert : adhérence latérale volet ouvert (le freinage et la motricité gardent les tables volet
  -- fermé : le volet se ferme au freinage)
  if eff.drsOn then
    local ayOpen = grid(eff, 'ayOpen', #loads)
    for i = 1, reach do
      if i % 4 == 0 then tick() end
      eff.dF, eff.dR = dF0 * bumpGripF[i], dR0 * bumpGripR[i]
      for j = 1, #loads do ayOpen[j][i] = lateralLimit(eff, loads[j], liftOpen[i], liftFrontOpen[i], ay[j][i]) end
    end
    for i = reach + 1, count do
      for j = 1, #loads do ayOpen[j][i] = ayOpen[j][reach] end
    end
    eff.dF, eff.dR = dF0, dR0
  end
  -- Hauteurs minimales jusqu'à la vitesse de pointe seulement (au-delà, la voiture n'y va pas).
  eff.rideMinF, eff.rideMinR = math.huge, math.huge
  for i = 1, min(count, floor(eff.topSpeed / dv) + 2) do
    eff.rideMinF, eff.rideMinR = min(eff.rideMinF, rideAtF[i]), min(eff.rideMinR, rideAtR[i])
  end
  -- Hypothèse H15 : sans ABS actif, une pédale trop puissante bloque les roues à basse vitesse (sans
  -- appui), faute de marge de dosage. Risque = excès du couple maximal sur le freinage permis par
  -- l'adhérence à K.brakeLockSpeed, au-delà de K.brakeLockMargin (pénalité de stabilité, §8.4).
  eff.brakeLockRisk = 0
  if not conditions.absActive and eff.brakeForceMax < math.huge then
    local i = min(count, floor(K.brakeLockSpeed / dv) + 1)
    local FzF = eff.mass * G * eff.b / eff.wheelbase + max(0, liftFront[i])
    local FzR = eff.mass * G * eff.a / eff.wheelbase + max(0, lift[i] - liftFront[i])
    local torqueLimit = eff.brakeForceMax
    eff.brakeForceMax = math.huge
    local gripDecel = brakeLimit(eff, FzF, FzR)
    eff.brakeForceMax = torqueLimit
    eff.brakeLockRisk = max(0, torqueLimit / max(1, eff.mass * gripDecel) - 1 - K.brakeLockMargin)
  end
  eff.bottoming = min(eff.rideMinF, eff.rideMinR) < K.minDynamicRideHeight
  -- Hauteur minimale (MIN_HEIGHT, contrôlée par AC au repos) avec la marge K.minHeightMargin : un setup est
  -- refusé s'il passe sous elle en étant plus bas que le setup actuel au même carburant (le setup actuel,
  -- accepté par le jeu, n'est jamais refusé ; s'il passe sous la hauteur minimale avec ce carburant, c'est
  -- signalé : currentBelowMinHeight).
  -- (marge seulement sur une hauteur prévue depuis une mesure : la hauteur par défaut hors jeu inclut
  -- déjà K.rideHeightMargin)
  local minH = base.minHeight or 0
  local limit = minH > 0 and minH + (Util.isFinite(base.rideRefFuel) and K.minHeightMargin or 0) or 0
  eff.belowMinHeight = (eff.rideF < limit - 1e-9 and eff.rideF < refAtF - 1e-9)
    or (eff.rideR < limit - 1e-9 and eff.rideR < refAtR - 1e-9)
  eff.currentBelowMinHeight = minH > 0 and min(refAtF, refAtR) < minH - 1e-9
  return eff, nil
end

-- Contrôleurs dynamiques (vitesse) d'une aile, regroupés une fois par voiture.
function M.controllersOf(base, index)
  local cache = base.wingControllers
  if cache == nil then
    cache = {}
    base.wingControllers = cache
  end
  local list = cache[index]
  if list == nil then
    list = {}
    for _, c in ipairs(base.controllers) do
      if c.wing == index then list[#list + 1] = c end
    end
    cache[index] = list
  end
  return list
end

return M
