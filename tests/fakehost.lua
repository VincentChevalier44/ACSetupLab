-- Hôte CSP simulé pour le banc hors jeu. Reproduit les signatures du SDK local
-- (extension/internal/lua-sdk/ac_apps/lib.lua) relevées au J0, à partir des jeux de données
-- de référence. Ses analyseurs INI/LUT sont indépendants de src/util (validation croisée).
-- Les objets d'état lèvent une erreur sur champ inconnu, comme une structure FFI de CSP.

local ffi = require('ffi')

local F = {}

pcall(ffi.cdef, 'typedef struct { int n; double v[32]; } setuplab_fake_array;')
local FakeArray = ffi.metatype('setuplab_fake_array', {
  __len = function(a) return a.n end,
  __index = function(a, i)
    if type(i) == 'number' and i >= 0 and i < a.n then return a.v[i] end
    error('setuplab_fake_array: index invalide ' .. tostring(i))
  end,
})

local function array(values)
  local a = FakeArray()
  a.n = #values
  for i, v in ipairs(values) do a.v[i - 1] = v end
  return a
end
F.array = array

-- Ailes en direct (ac.StateWingPhysics) : tableau cdata indexé à partir de 0, longueur par #.
pcall(ffi.cdef, [[
  typedef struct { float cd, cl, aoa, angle, groundHeight; } setuplab_fake_wing;
  typedef struct { int n; setuplab_fake_wing v[16]; } setuplab_fake_wings;
]])
local FakeWings = ffi.metatype('setuplab_fake_wings', {
  __len = function(a) return a.n end,
  __index = function(a, i)
    if type(i) == 'number' and i >= 0 and i < a.n then return a.v[i] end
    error('setuplab_fake_wings: index invalide ' .. tostring(i))
  end,
})

function F.wings(list)
  local w = FakeWings()
  w.n = #list
  for i, item in ipairs(list) do
    local slot = w.v[i - 1]
    slot.cd, slot.cl, slot.aoa, slot.angle, slot.groundHeight = item[1], item[2], item[3], item[4], item[5]
  end
  return w
end

-- Table stricte : un champ inconnu lève une erreur (comportement d'une structure FFI).
local function strict(t, name)
  return setmetatable(t, {
    __index = function(_, key) error((name or 'struct') .. ' has no member named ' .. tostring(key), 2) end,
  })
end
F.strict = strict

local function trim(s)
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- INI façon CSP : sections<nom, clés<nom, string[]>>. mode « single » : une seule chaîne par clé.
function F.parseIniCsp(text, mode)
  local sections, current = {}, nil
  text = text:gsub('^\239\187\191', '')
  for raw in (text:gsub('\r', '') .. '\n'):gmatch('(.-)\n') do
    local line = trim(raw)
    local c = line:find(';', 1, true)
    if c then line = trim(line:sub(1, c - 1)) end
    if line:sub(1, 1) == '[' then
      local name = line:match('^%[%s*(.-)%s*%]')
      if name and name ~= '' then
        current = sections[name] or {}
        sections[name] = current
      end
    elseif current and line:sub(1, 1) ~= '/' then
      local eq = line:find('=', 1, true)
      if eq then
        local key, value = trim(line:sub(1, eq - 1)), trim(line:sub(eq + 1))
        if key ~= '' then
          if mode == 'single' then
            current[key] = { value }
          else
            local list = {}
            for item in (value .. ','):gmatch('(.-),') do list[#list + 1] = trim(item) end
            current[key] = list
          end
        end
      end
    end
  end
  return sections
end

local function parseLutPoints(text)
  local xs, ys = {}, {}
  for line in text:gmatch('[^\r\n]+') do
    local a, b = line:match('^%s*([%-%+%d%.eE]+)%s*|%s*([%-%+%d%.eE]+)')
    if a and tonumber(a) and tonumber(b) then
      xs[#xs + 1], ys[#ys + 1] = tonumber(a), tonumber(b)
    end
  end
  return xs, ys
end

local LutHandle = {}
LutHandle.__index = LutHandle
function LutHandle:getPointInput(i)
  return self.xs[i + 1] or (0 / 0)
end
function LutHandle:getPointOutput(i)
  return self.ys[i + 1] or (0 / 0)
end

local function parseRtoLabels(text)
  local labels = {}
  for line in text:gmatch('[^\r\n]+') do
    local label = line:match('^%s*([^|]+)|')
    if label then labels[#labels + 1] = trim(label) end
  end
  return labels
end

-- Ligne IA : points « x y z s gauche droite [vitesse rayon dévers] » ; interpolation linéaire par
-- abscisse. Les trois dernières colonnes (fast_lane.ai) sont des références indépendantes du banc.
function F.buildTrack(fixture)
  local pts = {}
  for line in fixture.points:gmatch('[^\n]+') do
    local p = {}
    for value in line:gmatch('%S+') do p[#p + 1] = tonumber(value) end
    for i = #p + 1, 9 do p[i] = 0 end
    pts[#pts + 1] = p
  end
  local first, last = pts[1], pts[#pts]
  local dx, dy, dz = first[1] - last[1], first[2] - last[2], first[3] - last[3]
  local closing = math.sqrt(dx * dx + dy * dy + dz * dz)
  return { pts = pts, total = last[4] + closing }
end

-- Grille spatiale (cellules de 10 m) des points de la ligne, construite à la demande.
local CELL = 10
local function grid(track)
  if track.grid then return track.grid end
  local g = {}
  for i, p in ipairs(track.pts) do
    local key = math.floor(p[1] / CELL) * 1000003 + math.floor(p[3] / CELL)
    local list = g[key]
    if list == nil then
      list = {}
      g[key] = list
    end
    list[#list + 1] = i
  end
  track.grid = g
  return g
end

-- Sens du virage de référence au point i (signe de la courbure de Menger sur ±8 points, convention
-- de track_model : > 0 vers n = (−t.z, t.x)).
local function turnSign(pts, i)
  local n = #pts
  local a, b, c = pts[(i - 9) % n + 1], pts[i], pts[(i + 7) % n + 1]
  local cross = (b[1] - a[1]) * (c[3] - b[3]) - (b[3] - a[3]) * (c[1] - b[1])
  return cross >= 0 and 1 or -1
end

-- Sol simulé sous (x, z) : plan passant par le point de ligne le plus proche (≤ 20 m). La colonne c de
-- fast_lane.ai est un dévers relatif au virage (> 0 : intérieur plus bas) ; le côté le plus bas est
-- donc celui vers lequel tourne la référence. Renvoie la hauteur et la normale (nx, ny, nz) ; nil
-- hors piste.
function F.groundHeight(track, x, z)
  local g, pts = grid(track), track.pts
  local cx, cz = math.floor(x / CELL), math.floor(z / CELL)
  local best, bestD = nil, 400
  for ix = cx - 2, cx + 2 do
    for iz = cz - 2, cz + 2 do
      local list = g[ix * 1000003 + iz]
      if list then
        for _, i in ipairs(list) do
          local dx, dz = x - pts[i][1], z - pts[i][3]
          local d = dx * dx + dz * dz
          if d < bestD then best, bestD = i, d end
        end
      end
    end
  end
  if best == nil then return nil end
  local n = #pts
  local a, c = pts[best > 1 and best - 1 or n], pts[best < n and best + 1 or 1]
  local tx, tz = c[1] - a[1], c[3] - a[3]
  local len = math.sqrt(tx * tx + tz * tz)
  if len < 1e-9 then return pts[best][2], 0, 1, 0 end
  local nx, nz = -tz / len, tx / len
  local tilt = math.tan(pts[best][9] * turnSign(pts, best))
  local offset = (x - pts[best][1]) * nx + (z - pts[best][3]) * nz
  local norm = math.sqrt(1 + tilt * tilt)
  return pts[best][2] - offset * tilt, tilt * nx / norm, 1 / norm, tilt * nz / norm
end

-- Conducteur simulé : avance la voiture le long de la ligne IA selon un profil de vitesse donné en
-- progression (profile.p croissant de 0 à 1, profile.v en m/s), comme AC le ferait : progression,
-- position, vitesse, accélération longitudinale, pédales, compteur et temps officiel des tours.
-- profile.jumpAt (progression) : téléportation de profile.jump (progression) au passage.
-- profile.ay (facultatif, m/s²) : accélération latérale, interpolée comme la vitesse. Boîte simulée :
-- rapport floor(v/12)+1, régime proportionnel à la vitesse dans chaque rapport.
-- Comportements d'AC à éprouver : profile.lineOffset (progression) décale la ligne de chronométrage
-- de l'origine de la ligne IA ; h.lateLapTimeFrames retarde la mise à jour de previousLapTimeMs ;
-- h.lapTimeError fausse le temps officiel ; profile.noProgress laisse splinePosition à 0 (pas de
-- ligne IA) ; h.paused fige la voiture et le chrono du tour ; h.lateLapCountFrames incrémente le
-- compteur après la remise à zéro du chrono, h.lateTimerResetFrames remet le chrono à zéro après
-- l'incrément du compteur. profile.drs = { wing, zones = { { début, fin } en progression }, cl, cd } :
-- volet ouvert dans les zones (car.drsActive), coefficients de l'aile multipliés par cl et cd.
function F.drive(h, profile, dt)
  local d = h.driver
  if d == nil or d.profile ~= profile then
    d = { profile = profile, p = profile.startP or 0, lapTime = 0, j = 1, v = nil }
    h.driver = d
  end
  local P, V = profile.p, profile.v
  local function valueAt(list, p)
    while d.j < #P and P[d.j + 1] <= p do d.j = d.j + 1 end
    while d.j > 1 and P[d.j] > p do d.j = d.j - 1 end
    local a, b = d.j, math.min(d.j + 1, #P)
    local f = P[b] > P[a] and (p - P[a]) / (P[b] - P[a]) or 0
    return list[a] + (list[b] - list[a]) * math.max(0, math.min(1, f))
  end
  local car = h.car
  if d.pendingCount then
    d.pendingCount = d.pendingCount - 1
    if d.pendingCount <= 0 then
      car.lapCount = car.lapCount + 1
      d.pendingCount = nil
    end
  end
  if d.pendingTime then
    d.pendingTime.frames = d.pendingTime.frames - 1
    if d.pendingTime.frames <= 0 then
      car.previousLapTimeMs = d.pendingTime.value
      d.pendingTime = nil
    end
  end
  if h.paused then
    car.speedMs = 0
    return
  end
  local v = valueAt(V, d.p)
  local ay = profile.ay and valueAt(profile.ay, d.p) or 0
  local before = d.p
  d.p = d.p + v * dt / h.track.total
  if profile.jumpAt and before < profile.jumpAt and d.p >= profile.jumpAt then d.p = d.p + profile.jump end
  d.lapTime = d.lapTime + dt
  -- ligne de chronométrage en progression line (bouclée) : franchie entre before et d.p
  local line = (profile.lineOffset or 0) % 1
  local crossed = (before < line and d.p >= line) or (before < line + 1 and d.p >= line + 1)
  if d.p >= 1 then
    d.p = d.p - 1
    d.j = 1
  end
  if crossed then
    if (h.lateLapCountFrames or 0) > 0 then
      d.pendingCount = h.lateLapCountFrames
    else
      car.lapCount = car.lapCount + 1
    end
    if (h.lateTimerResetFrames or 0) > 0 then d.timerHold = { frames = h.lateTimerResetFrames, value = d.lapTime } end
    local value = math.floor(d.lapTime * 1000 + 0.5) + math.floor((h.lapTimeError or 0) * 1000)
    if (h.lateLapTimeFrames or 0) > 0 then
      d.pendingTime = { value = value, frames = h.lateLapTimeFrames }
    else
      car.previousLapTimeMs = value
    end
    d.lapTime = 0
  end
  local x, y, z = F.sampleTrack(h.track, d.p)
  car.splinePosition = profile.noProgress and 0 or d.p
  car.speedMs, car.lapTimeMs = v, math.floor(d.lapTime * 1000)
  if d.timerHold and not crossed then
    d.timerHold.frames = d.timerHold.frames - 1
    if d.timerHold.frames <= 0 then d.timerHold = nil end
  end
  if d.timerHold then car.lapTimeMs = math.floor((d.timerHold.value + d.lapTime) * 1000) end
  car.position.x, car.position.y, car.position.z = x, y + 0.3, z
  local accel = d.v and (v - d.v) / dt or 0
  d.v = v
  car.acceleration.z = accel / 9.80665
  car.acceleration.x = ay / 9.80665
  car.gas, car.brake = accel > 0.2 and 1 or 0, accel < -2 and 1 or 0
  car.gear = math.max(1, math.min(6, math.floor(v / 12) + 1))
  car.rpm = v * 9000 / (12 * car.gear + 6)
  car.fuel = car.fuel - 0.0005
  local drs = profile.drs
  if drs then
    local open = false
    for _, z in ipairs(drs.zones) do
      if (d.p - z[1]) % 1 <= (z[2] - z[1]) % 1 then open = true end
    end
    car.drsActive = open
    local wing = h.physicsState.wings.v[drs.wing]
    drs.base = drs.base or { cd = wing.cd, cl = wing.cl }
    wing.cd = drs.base.cd * (open and drs.cd or 1)
    wing.cl = drs.base.cl * (open and drs.cl or 1)
  end
end

function F.sampleTrack(track, p)
  local pts, total = track.pts, track.total
  p = p % 1
  local s = p * total
  local n = #pts
  local a, b, t
  if s >= pts[n][4] then
    a, b = pts[n], pts[1]
    t = (s - pts[n][4]) / (total - pts[n][4])
  else
    local lo, hi = 1, n
    while hi - lo > 1 do
      local mid = math.floor((lo + hi) / 2)
      if pts[mid][4] <= s then lo = mid else hi = mid end
    end
    a, b = pts[lo], pts[hi]
    t = (s - a[4]) / math.max(1e-9, b[4] - a[4])
  end
  local function mix(k) return a[k] + (b[k] - a[k]) * t end
  return mix(1), mix(2), mix(3), mix(5), mix(6)
end

local function fileMap(fixture)
  local files = {}
  for name, text in pairs(fixture.files) do files[name:lower()] = text end
  return files
end

local function sortedNames(files)
  local names = {}
  for name in pairs(files) do names[#names + 1] = name end
  table.sort(names)
  return names
end

-- Crans de setup déduits de setup.ini, encodés comme constaté dans les fichiers de setup de Vincent
-- (API_NOTES §3) : entiers ; carrossage en dixièmes de degré (displayMultiplier 0,1) ; réglages à
-- SHOW_CLICKS=2 en numéro de cran depuis MIN ; autres en valeur absolue ; rapports .rto en items.
local function buildSpinners(files, mode)
  local setup = files['setup.ini'] and F.parseIniCsp(files['setup.ini'], mode) or {}
  local names = sortedNames(setup)
  local spinners = {}
  local function add(spinner)
    spinner.visible, spinner.readOnly = true, false
    spinner.defaultValue = spinner.value
    spinners[#spinners + 1] = spinner
  end
  for _, name in ipairs(names) do
    local s = setup[name]
    local first = function(key) return s[key] and tonumber(s[key][1]) or nil end
    local lo, hi, step = first('MIN'), first('MAX'), first('STEP') or 1
    local label = s.NAME and s.NAME[1] or name
    if s.RATIOS then
      local rto = files[(s.RATIOS[1] or ''):lower()]
      local labels = rto and parseRtoLabels(rto) or {}
      if #labels > 0 then
        -- rapport d'usine : ligne du .rto la plus proche de drivetrain.ini (setup réaliste de départ)
        local drivetrain = files['drivetrain.ini'] and F.parseIniCsp(files['drivetrain.ini'], 'split') or {}
        local gears = drivetrain.GEARS or {}
        local key = name == 'FINAL_GEAR_RATIO' and 'FINAL' or name
        local target = gears[key] and tonumber(gears[key][1])
        local value, bestGap, i = 0, math.huge, 0
        for line in rto:gmatch('[^\r\n]+') do
          local ratio = tonumber(line:match('|%s*([%d%.]+)'))
          if ratio then
            if target and math.abs(ratio - target) < bestGap then value, bestGap = i, math.abs(ratio - target) end
            i = i + 1
          end
        end
        add({ name = name, label = label, min = 0, max = #labels - 1, step = 1, value = value, displayMultiplier = 1,
          units = '', items = labels, showClicksMode = 0 })
      end
    elseif lo and hi and hi >= lo and step > 0 then
      local clicksMode = first('SHOW_CLICKS') or 0
      if name:find('^CAMBER_') then
        local a, b = math.floor(lo * 10 + 0.5), math.floor(hi * 10 + 0.5)
        add({ name = name, label = label, min = a, max = b, step = math.max(1, math.floor(step + 0.5)),
          value = math.floor((a + b) / 2), displayMultiplier = 0.1, units = '°', showClicksMode = clicksMode })
      elseif clicksMode == 2 then
        local clicks = math.floor((hi - lo) / step + 0.5)
        add({ name = name, label = label, min = 0, max = clicks, step = 1, value = math.floor(clicks / 2),
          displayMultiplier = 1, units = '', showClicksMode = 2 })
      else
        local a, b, st = math.floor(lo + 0.5), math.floor(hi + 0.5), math.max(1, math.floor(step + 0.5))
        local clicks = math.floor((b - a) / st)
        add({ name = name, label = label, min = a, max = b, step = st, value = a + math.floor(clicks / 2) * st,
          displayMultiplier = 1, units = '', showClicksMode = clicksMode })
      end
    end
  end
  return spinners
end

-- État physique du jeu cohérent avec les crans simulés, calculé ici indépendamment de setup_space
-- (le jeu, lui, applique le setup) : pression statique, répartition, différentiel, rapports, ailes,
-- limiteur. opts.stateMismatch = nom de section : écart volontaire sur ce réglage.
local function applySetupToState(h, files, mode)
  local setup = files['setup.ini'] and F.parseIniCsp(files['setup.ini'], mode) or {}
  local byName = {}
  for _, sp in ipairs(h.spinners) do byName[sp.name] = sp end
  local function spin(name)
    local sp = byName[name]
    if sp == nil then return nil end
    local value = sp.value
    if h.opts.stateMismatch == name then value = value + 3 * (sp.step or 1) end
    if sp.showClicksMode == 2 then
      local s = setup[name]
      return tonumber(s.MIN[1]) + value * tonumber(s.STEP[1])
    end
    return value
  end
  local function ratioOf(name)
    local sp, s = byName[name], setup[name]
    if sp == nil or s == nil or s.RATIOS == nil then return nil end
    local text = files[(s.RATIOS[1] or ''):lower()]
    local i = 0
    for line in (text or ''):gmatch('[^\r\n]+') do
      local ratio = line:match('|%s*([%d%.]+)')
      if ratio then
        if i == sp.value then return tonumber(ratio) end
        i = i + 1
      end
    end
    return nil
  end
  for i, name in ipairs({ 'PRESSURE_LF', 'PRESSURE_RF', 'PRESSURE_LR', 'PRESSURE_RR' }) do
    local p = spin(name)
    if p then h.car.wheels[i - 1].tyreStaticPressure = p end
  end
  local bias = spin('FRONT_BIAS')
  if bias then h.car.brakeBias = bias / 100 end
  local diff = spin('DIFF_POWER') or spin('REAR_DIFF_POWER')
  if diff then h.car.differentialPower = diff / 100 end
  local engine = files['engine.ini'] and F.parseIniCsp(files['engine.ini'], 'split') or {}
  local limiter = engine.ENGINE_DATA and engine.ENGINE_DATA.LIMITER and tonumber(engine.ENGINE_DATA.LIMITER[1])
  local pct = spin('ENGINE_LIMITER')
  if limiter then h.car.rpmLimiter = limiter * (pct or 100) / 100 end
  local ratios = { -3.2, 0 }
  for g = 1, 10 do
    local r = ratioOf('GEAR_' .. g)
    if r == nil then break end
    ratios[#ratios + 1] = r
  end
  if #ratios > 2 then h.physicsState.gearRatios = F.array(ratios) end
  local final = ratioOf('FINAL_GEAR_RATIO')
  if final then h.physicsState.finalRatio = final end
  local wings = h.physicsState.wings
  for w = 0, #wings - 1 do
    local angle = spin('WING_' .. w)
    if angle then wings.v[w].angle = angle end
  end
end

-- Noms de section de la boîte dans le fichier de setup (option gearNames = 'internal' : décalage
-- constaté, INTERNAL_GEAR_n / FINAL_RATIO contre GEAR_n / FINAL_GEAR_RATIO dans setup.ini).
local function fileSection(h, name)
  if h.opts.gearNames ~= 'internal' then return name end
  if name == 'FINAL_GEAR_RATIO' then return 'FINAL_RATIO' end
  local n = name:match('^GEAR_(%d+)$')
  if n then return 'INTERNAL_GEAR_' .. n end
  return name
end

-- modifiedOnly (comme ac.stringifyCurrentSetup) : seulement les crans différents de leur valeur par défaut.
local function stringifySetup(h, modifiedOnly)
  local parts = {}
  for _, sp in ipairs(h.spinners) do
    local value = sp.value
    if h.opts.setupMismatch == sp.name then value = value + (sp.step or 1) end
    if not modifiedOnly or value ~= sp.defaultValue then
      parts[#parts + 1] = '[' .. fileSection(h, sp.name) .. ']\nVALUE=' .. tostring(value) .. '\n'
    end
  end
  -- composé monté : section [TYRES] des fichiers de setup d'AC (h.opts.noTyresSection : absente)
  if not h.opts.noTyresSection and not modifiedOnly then
    parts[#parts + 1] = '[TYRES]\nVALUE=' .. tostring(h.car.compoundIndex) .. '\n'
  end
  -- niveaux d'aide (ABS, antipatinage), comme dans les fichiers de setup d'AC
  if not modifiedOnly then
    if h.aidsInSetup.ABS then parts[#parts + 1] = '[ABS]\nVALUE=' .. tostring(h.car.absMode) .. '\n' end
    if h.aidsInSetup.TRACTION_CONTROL then
      parts[#parts + 1] = '[TRACTION_CONTROL]\nVALUE=' .. tostring(h.car.tractionControlMode) .. '\n'
    end
  end
  parts[#parts + 1] = '[CAR]\nMODEL=' .. h.carId .. '\n'
  parts[#parts + 1] = '[__EXT_PATCH]\nVERSION=0.3.0-preview675\n'
  return table.concat(parts, '\n')
end

local function setPath(h, path, value)
  local parts = {}
  for part in path:gmatch('[^%.]+') do parts[#parts + 1] = part end
  local t = h
  for i = 1, #parts - 1 do t = rawget(t, parts[i]) end
  rawset(t, parts[#parts], value)
end

local function getPath(h, path)
  local t = h
  for part in path:gmatch('[^%.]+') do t = rawget(t, part) end
  return t
end

function F.new(opts)
  opts = opts or {}
  local carFixture = assert(opts.car, 'fixture voiture requise')
  local trackFixture = assert(opts.track, 'fixture circuit requise')
  local files = fileMap(carFixture)
  local track = F.buildTrack(trackFixture)
  local h = {
    opts = opts, carId = carFixture.id, files = files, track = track,
    writeCalls = 0, clipboard = nil, releases = {}, disposed = 0, uiCalls = 0, click = nil, calls = {}, loadCalls = {},
    events = {},  -- journal ordonné des écritures et des chargements (D8 amendé)
  }
  local mode = opts.iniMode or 'split'
  local carIni = files['car.ini'] and F.parseIniCsp(files['car.ini'], 'split') or {}
  -- niveaux d'aide écrits par AC dans le fichier de setup quand la voiture a l'aide (PRESENT=1)
  local electronics = files['electronics.ini'] and F.parseIniCsp(files['electronics.ini'], 'split') or {}
  h.aidsInSetup = {}
  for _, section in ipairs({ 'ABS', 'TRACTION_CONTROL' }) do
    local present = electronics[section] and electronics[section].PRESENT and electronics[section].PRESENT[1]
    h.aidsInSetup[section] = tonumber(present) == 1
  end
  local mass = tonumber(carIni.BASIC and carIni.BASIC.TOTALMASS and carIni.BASIC.TOTALMASS[1]) or 1200
  h.spinners = buildSpinners(files, mode)

  local x0, y0, z0 = F.sampleTrack(track, 0)
  local function wheel(i)
    return strict({
      camber = i < 2 and -3.1 or -2.4, toeIn = 0.05, tyreStaticPressure = 26, tyrePressure = 27.5,
      tyreRadius = 0.34, tyreWidth = 0.31, rimRadius = 0.24, tyreOptimumTemperature = 85,
      tyreCoreTemperature = 60, tyreInsideTemperature = 62, tyreMiddleTemperature = 61, tyreOutsideTemperature = 60,
      load = mass * 9.81 / 4, tyreWear = 0, tyreVirtualKM = 0, tyreLoadedRadius = 0.33, slipRatio = 0, suspensionTravel = 0.0185,
      slipAngle = 0, ndSlip = 0, waterThickness = 0,
    }, 'ac.StateWheel')
  end
  h.car = strict({
    mass = mass, fuel = 30, maxFuel = 120, brakeBias = 0.58, brakesBiasLimitDown = 0.5, brakesBiasLimitUp = 0.8,
    brakesBiasStep = 0.005, differentialPreload = 50, differentialPower = 0.3, differentialCoast = 0.55,
    compoundIndex = 1, absMode = 1, absModes = 12, tractionControlMode = 1, tractionControlModes = 12,
    fuelMap = 0, fuelMaps = 1, aeroLiftFront = -0.8, aeroLiftRear = -1.0, aeroDrag = 0.9, cgHeight = 0.45,
    gearCount = 6, tractionType = 0, enginePosition = 3, rpmLimiter = 8000, rpmMinimum = 1400, minHeight = 0.055,
    ballast = 0, restrictor = 0, kersMaxKJ = opts.kers and 4000 or 0, kersCurrentKJ = 0, mgukDelivery = 0,
    mgukDeliveryCount = opts.kers and 6 or 0, mgukRecovery = 5, caster = 7.0, steerLock = 180, fuelPerLap = 0,
    engineBrakeSettingsCount = 0, currentEngineBrakeSetting = 0,
    physicsAvailable = true, drsPresent = opts.drs == true, kersPresent = opts.kers == true,
    drsAvailable = false, drsActive = false, kersCharging = false, kersInput = 0, kersCharge = 0,
    hasUserBrakeBias = true, extendedPhysics = false, isKunosCar = false, isOpenWheeler = false, isInPit = true,
    isInPitlane = true, adjustableTurbo = false, brakesCockpitBias = true, hasCockpitERSDelivery = false,
    hasCockpitERSRecovery = false, hasCockpitMGUHMode = false, hasEngineBrakeSettings = false,
    speedMs = 0, rpm = 1500, gear = 0, gas = 0, brake = 0, steer = 0, splinePosition = 0, lapTimeMs = 0,
    lapCount = 0, wheelsOutside = 0, isLapValid = true, previousLapTimeMs = 0, bestLapTimeMs = 0, turboBoost = 0,
    acceleration = strict({ x = 0, y = 0, z = 0 }, 'vec3'),
    position = strict({ x = x0, y = y0 + 0.3, z = z0 }, 'vec3'),
    wheels = strict({ [0] = wheel(0), [1] = wheel(1), [2] = wheel(2), [3] = wheel(3) }, 'wheels'),
    rideHeight = strict({ [0] = 0.06, [1] = 0.075 }, 'rideHeight'),
  }, 'ac.StateCar')
  h.physicsState = strict({
    isAvailable = true, gearRatio = 0, finalRatio = 3.9166, airDensity = 1.2,
    gearRatios = array({ -3.818, 0, 2.6428, 2.0, 1.56, 1.2, 1.0312, 0.8857 }),
    wings = F.wings({ { 0.41, 0, 0, 0, 0.3 }, { 0.05, 0.46, 6, 6, 0.06 }, { 0.18, 0.43, 6, 6, 0.9 } }),
  }, 'ac.StateCarPhysics')
  applySetupToState(h, files, mode)
  h.sim = strict({
    time = 1000, systemTime = 1792368000, fps = 120, trackLengthM = opts.trackLength or track.total,
    isTrackOpen = false, isOnlineRace = false, isAltOnlineRace = false, isReplayActive = false,
    isReplayOnlyMode = false, isPaused = false, isInMainMenu = false, raceSessionType = 2, currentSessionIndex = 0,
    sessionsCount = 1, carsCount = 1, ambientTemperature = 24, roadTemperature = 32, roadGrip = 0.98,
    rainIntensity = 0, rainWetness = 0, rainWater = 0, windSpeedKmh = 5, windDirectionDeg = 90, weatherType = 15,
    isWeatherFXActive = true, fixedSetup = false, isTimedRace = false, isSessionStarted = true,
    tyreConsumptionRate = 1, fuelConsumptionRate = 1, mechanicalDamageRate = 1,
  }, 'ac.StateSim')
  h.session = strict({ type = 2, laps = 0, durationMinutes = 15, isTimedRace = true, hasAdditionalLap = false },
    'ac.StateSession')

  local folders = {
    [13] = 'C:/AC/content/cars', [11] = 'C:/Users/pilote/Documents/Assetto Corsa/setups',
    [1028] = 'C:/AC/content/tracks/' .. trackFixture.id .. '/ui',
  }
  local acFolderPrefix = 'C:/AC/content/cars/' .. h.carId .. '/data/'
  local relFolderPrefix = 'content/cars/' .. h.carId .. '/data/'

  local cache = { car = {}, track = {}, lut = {} }
  local trackFiles = {}
  for name, text in pairs(trackFixture.files) do trackFiles[name:lower()] = text end

  h.ac = {
    FolderID = { UserSetups = 11, ContentCars = 13, CurrentTrackLayoutUI = 1028 },
    getPatchVersion = function() return '0.3.0-preview675' end,
    getPatchVersionCode = function() return 4210 end,
    getSim = function() return h.sim end,
    getSession = function(i) if i == 0 then return h.session end return nil end,
    getCar = function(i) if i == 0 then return h.car end return nil end,
    getCarPhysics = function(i) if i == 0 then return h.physicsState end return nil end,
    getCarID = function(i) if i == 0 then return h.carId end return nil end,
    getCarName = function(i) if i == 0 then return carFixture.name end return nil end,
    getCarDataFiles = function() return sortedNames(files) end,
    getFolder = function(id) return folders[id] or '' end,
    readDataFile = function(path)
      h.calls.readDataFile = (h.calls.readDataFile or 0) + 1
      local name = path:match('[^/\\]+$'):lower()
      local form = path:sub(1, #acFolderPrefix) == acFolderPrefix and 'absolu'
        or path:sub(1, #relFolderPrefix) == relFolderPrefix and 'relatif' or 'autre'
      if form == (opts.rawForm or 'absolu') and files[name] then return files[name] end
      return ''
    end,
    -- Analyses mises en cache : CSP analyse en natif, le banc mesure la découpe de SetupLab.
    INIConfig = {
      carData = function(i, name)
        if opts.carDataError then error('data.acd illisible (simulé)') end
        local key = name:lower()
        local text = i == 0 and files[key] or nil
        if text and not cache.car[key] then cache.car[key] = F.parseIniCsp(text, mode) end
        return { sections = text and cache.car[key] or {} }
      end,
      trackData = function(name)
        local key = name:lower()
        local text = trackFiles[key]
        if text and not cache.track[key] then cache.track[key] = F.parseIniCsp(text, mode) end
        return { sections = text and cache.track[key] or {} }
      end,
    },
    DataLUT11 = {
      carData = function(i, name)
        if opts.lutError then error('LUT illisible (simulé)') end
        local key = name:lower()
        local text = i == 0 and files[key] or nil
        if text and not cache.lut[key] then cache.lut[key] = { parseLutPoints(text) } end
        local points = text and cache.lut[key] or { {}, {} }
        return setmetatable({ xs = points[1], ys = points[2] }, LutHandle)
      end,
    },
    getTrackID = function() return trackFixture.id end,
    getTrackLayout = function() return trackFixture.layout end,
    getTrackFullID = function(sep)
      if trackFixture.layout ~= '' then return trackFixture.id .. (sep or '-') .. trackFixture.layout end
      return trackFixture.id
    end,
    getTrackName = function() return trackFixture.name end,
    hasTrackSpline = function() return not opts.noSpline end,
    trackProgressToWorldCoordinate = function(p)
      local x, y, z = F.sampleTrack(track, p)
      return { x = x, y = y, z = z }
    end,
    getTrackAISplineSides = function(p)
      local _, _, _, l, r = F.sampleTrack(track, p)
      return { x = l, y = r }
    end,
    worldCoordinateToTrackProgress = function() return 0 end,
    getSetupSpinners = function() return h.spinners end,
    getSetupTabs = function() return { { name = 'GENERIC', label = 'Generic', visible = true, modified = false } } end,
    stringifyCurrentSetup = function(_, modifiedOnly) return stringifySetup(h, modifiedOnly == true) end,
    isSetupAvailableToEdit = function() return h.setupEditable ~= false end,
    getCarSetupState = function() return 'legal', nil end,
    getAssists = function()
      return { fuelRate = 1, tyresWear = 1, damageRate = 1, tyresBlankets = true, abs = 'factory', tractionControl = 'factory' }
    end,
    getTyresName = function() return 'M' end,
    getTyresLongName = function() return 'Medium' end,
    getCarMaxSpeedWithGear = function() return 280 end,
    onSetupFile = function() return function() end end,
    onLapCompleted = function() return function() end end,
    onRelease = function(fn)
      h.releases[#h.releases + 1] = fn
      return function() h.disposed = h.disposed + 1 end
    end,
    -- ac.storage(clé, défaut) : valeur stockée (get, set), conservée dans h.stored entre deux chargements de l'app
    storage = function(key, default)
      h.stored = h.stored or {}
      return {
        get = function() if h.stored[key] == nil then return default end return h.stored[key] end,
        set = function(_, value) h.stored[key] = value end,
      }
    end,
    setClipboardText = function(text)
      h.clipboard = text
      return true
    end,
    -- messages d'AC en haut de l'écran : relevés dans h.messages
    setMessage = function(title, description, kind, time)
      h.messages = h.messages or {}
      h.messages[#h.messages + 1] = { title = title, description = description, kind = kind, time = time }
    end,
    setSetupSpinnerValue = function() h.writeCalls = h.writeCalls + 1; error('interdit (D8)') end,
    -- ac.loadSetup (D8 amendé) : comme CSP, refusé hors du menu de setup ou setup imposé ; sinon le
    -- fichier écrit est appliqué aux crans et au composé (h.opts.loadNoApply : accepté sans effet ;
    -- h.opts.loadRefuse : refusé par le jeu ; h.opts.loadSkip : section non appliquée).
    loadSetup = function(path)
      -- filet d'exécution (D8 amendé) : la première fonction du dossier de l'app dans la pile, hors
      -- util.lua (Util.call) et hôte simulé, est celle de l'exporteur
      local root = tostring(PY.appDir):gsub('\\', '/')
      for level = 2, 40 do
        local info = debug.getinfo(level, 'S')
        if info == nil then break end
        local src = (info.source or ''):gsub('\\', '/')
        if src:find(root .. '/src/exporter.lua', 1, true) then break end
        if src:find(root, 1, true) and not src:find(root .. '/src/util.lua', 1, true)
            and not src:find(root .. '/tests/fakehost.lua', 1, true) then
          error('ac.loadSetup appelée hors de src/exporter.lua (D8 amendé) : ' .. src)
        end
      end
      h.loadCalls[#h.loadCalls + 1] = path
      h.events[#h.events + 1] = { 'load', path }
      if h.setupEditable == false or h.sim.fixedSetup == true or h.opts.loadRefuse then return false end
      local text = h.written[path]
      if type(text) ~= 'string' then return false end
      if h.opts.loadNoApply then return true end
      for _, sp in ipairs(h.spinners) do
        local name = fileSection(h, sp.name)
        local value = text:match('%[' .. name:gsub('%p', '%%%0') .. '%]%s*VALUE=([%-%d%.]+)')
        if value and name ~= h.opts.loadSkip then sp.value = tonumber(value) end
      end
      local tyres = text:match('%[TYRES%]%s*VALUE=(%d+)')
      if tyres then h.car.compoundIndex = tonumber(tyres) end
      return true
    end,
    saveCurrentSetup = function() h.writeCalls = h.writeCalls + 1; error('interdit (D8)') end,
    resetSetupToDefault = function() h.writeCalls = h.writeCalls + 1; error('interdit (D8)') end,
    setPitstopSpinnerValue = function() h.writeCalls = h.writeCalls + 1; error('interdit (D8)') end,
  }
  h.ac.INIConfig.currentSetup = function() return { sections = F.parseIniCsp(stringifySetup(h), mode) } end
  -- Système de fichiers simulé : les écritures sont enregistrées dans h.written (chemin -> contenu)
  -- et comptées dans h.writeCalls ; suppression définitive et copie restent interdites. Rangement (décision de
  -- Vincent du 22/10/2026) : Corbeille (h.recycled) et renommage (h.moves), comptés dans h.fileOpCalls.
  local function forbiddenWrite()
    h.writeCalls = h.writeCalls + 1
    error('opération interdite (aucune suppression, aucun déplacement)')
  end
  h.written, h.dirs, h.refreshes = {}, {}, 0
  -- stockage de départ du banc (1.5) : minimum avant une proposition à 0 (les tests de l'affinage proposent dès la
  -- découverte ; le minimum a ses propres tests) et interface en français (assertions sur les textes)
  h.stored = opts.stored or { ['setuplab:data'] = 'setuplab-store 1|settings#refineMinLaps=0|settings#language=s:fr' }
  h.recycled, h.moves, h.fileOpCalls = {}, {}, 0
  local function listDir(dir, mask)
    local pattern = '^' .. (mask or '*'):gsub('[%.%-%+%[%]%(%)%%%^%$]', '%%%0'):gsub('%*', '.*'):gsub('%?', '.') .. '$'
    local list, seen = {}, {}
    local function add(path)
      local folder, name = path:match('^(.*)/([^/]+)$')
      if folder == dir and name:match(pattern) and not seen[name] then
        seen[name] = true
        list[#list + 1] = name
      end
    end
    for path in pairs(h.written) do add(path) end
    for path, present in pairs(opts.existing or {}) do
      if present then add(path) end
    end
    table.sort(list)
    return list
  end
  h.io = {
    available = function() return true end,
    load = function(path)
      if h.written[path] then
        if opts.corruptLoad then return h.written[path] .. '#' end
        return h.written[path]
      end
      if path:match('ui_track%.json$') and trackFixture.declared ~= '' then return trackFixture.declared end
      return nil
    end,
    save = function(path, data, ensure)
      h.writeCalls = h.writeCalls + 1
      h.lastEnsure = ensure
      if opts.saveFails == 'error' then error('disque plein (simulé)') end
      if opts.saveFails then return false end
      h.written[path] = data
      h.events[#h.events + 1] = { 'save', path }
      return true
    end,
    createFileDir = function(path)
      local dir = path:match('^(.*)/[^/]*$')
      if h.dirs[dir] then return false end
      h.dirs[dir] = true
      return true
    end,
    isFileNameAcceptable = function(name) return name:find('[<>:"/\\|%?%*]') == nil end,
    fileExists = function(path) return h.written[path] ~= nil or (opts.existing or {})[path] == true end,
    saveAsync = forbiddenWrite, createDir = forbiddenWrite, deleteFile = forbiddenWrite, copyFile = forbiddenWrite,
    recycle = function(path)
      h.fileOpCalls = h.fileOpCalls + 1
      if h.written[path] == nil then return false end
      h.written[path] = nil
      h.recycled[#h.recycled + 1] = path
      h.events[#h.events + 1] = { 'recycle', path }
      return true
    end,
    move = function(from, to, replace)
      h.fileOpCalls = h.fileOpCalls + 1
      if h.written[from] == nil or ((h.written[to] ~= nil or (opts.existing or {})[to]) and replace ~= true) then return false end
      h.written[to], h.written[from] = h.written[from], nil
      h.moves[#h.moves + 1] = { from = from, to = to }
      h.events[#h.events + 1] = { 'move', from, to }
      return true
    end,
    scanDir = function(dir, mask) return listDir(dir, mask) end,
  }
  h.ac.refreshSetups = function()
    h.refreshes = h.refreshes + 1
    return true
  end
  h.physics = {
    setTyresCompound = function() h.writeCalls = h.writeCalls + 1; error('interdit (D8)') end,
    setCarFuel = function() h.writeCalls = h.writeCalls + 1; error('interdit (D8)') end,
    raycastTrack = function(origin, dir, length, point, normal)
      h.raycasts = (h.raycasts or 0) + 1
      if dir.y >= 0 or length <= 0 then return -1 end
      local ground, nx, ny, nz = F.groundHeight(track, origin.x, origin.z)
      if ground == nil then return -1 end
      local d = origin.y - ground
      if d < 0 or d > length then return -1 end
      if point then point.x, point.y, point.z = origin.x, ground, origin.z end
      if normal then normal.x, normal.y, normal.z = nx, ny, nz end
      return d
    end,
  }
  h.vec2 = function(x, y) return { x = x or 0, y = y or 0 } end
  h.vec3 = function(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
  h.rgbm = function(r, g, b, m) return { r = r, g = g, b = b, mult = m } end
  local function uiCall() h.uiCalls = h.uiCalls + 1 end
  h.pathPoints, h.strokes, h.progress = 0, 0, nil
  -- largeur de la zone de contenu (mise en page adaptée à la largeur : h.width), identifiants ImGui
  -- vus pendant l'image : deux boutons (cases, nœuds, onglets, curseurs) de même identifiant dans la même
  -- portée (onglet, nœud, fenêtre enfant) sont une erreur, car en jeu l'un des deux ne réagit plus.
  h.width = opts.width or 520
  h.ids, h.idScope = {}, ''
  local function register(kind, label)
    local id = label:match('###(.*)$') or label
    local key = h.idScope .. '|' .. id
    assert(not h.ids[key], 'identifiant ImGui en double (' .. kind .. ') : ' .. label .. ' dans « ' .. h.idScope .. ' »')
    h.ids[key] = true
  end
  -- clic : libellé complet, ou partie visible (avant « ### »)
  local function clicked(label)
    if h.click ~= nil and (h.click == label or h.click == (label:match('^(.-)###') or label)
        or h.click == (label:match('###(.*)$') or label)) then
      h.click = nil
      return true
    end
    return false
  end
  local function scoped(name, content, ...)
    local saved = h.idScope
    h.idScope = saved .. '/' .. name
    local ok, result = pcall(content, ...)
    h.idScope = saved
    if not ok then error(result, 0) end
    return result
  end
  local function lastFunction(...)
    local found = nil
    for i = 1, select('#', ...) do
      local value = select(i, ...)
      if type(value) == 'function' then found = value end
    end
    return found
  end
  h.ui = {
    text = uiCall, textWrapped = uiCall, textColored = uiCall, separator = uiCall, sameLine = uiCall,
    drawRect = uiCall, dummy = uiCall, newLine = uiCall, drawRectFilled = uiCall, setCursor = uiCall,
    indent = uiCall, unindent = uiCall, columns = uiCall, nextColumn = uiCall, setColumnWidth = uiCall,
    pushTextWrapPosition = uiCall, popTextWrapPosition = uiCall, beginGroup = uiCall, endGroup = uiCall,
    -- texte dessiné (tuiles) : vu comme un texte affiché
    drawText = function(text) return h.ui.text(text) end,
    measureText = function(text) return { x = 7 * #text, y = 14 } end,
    availableSpaceX = function() return h.width end,
    availableSpace = function() return { x = h.width, y = 400 } end,
    windowWidth = function() return h.width + 16 end,
    getCursor = function() return { x = 8, y = 300 } end,
    pathLineTo = function(p)
      assert(type(p.x) == 'number' and type(p.y) == 'number', 'point de tracé invalide')
      h.pathPoints = h.pathPoints + 1
    end,
    pathStroke = function() h.strokes = h.strokes + 1 end,
    progressBar = function(fraction, _, overlay)
      assert(fraction >= 0 and fraction <= 1, 'fraction hors [0 ; 1]')
      h.progress = overlay
    end,
    button = function(label)
      uiCall()
      register('bouton', label)
      return clicked(label)
    end,
    -- infobulles : rien n'est survolé, sauf h.hover (le contenu des infobulles n'est alors vu que dans
    -- ce cas : un texte qui ne s'affiche qu'au survol n'est pas « affiché »)
    itemHovered = function() return h.hover == true end,
    tooltip = function(...)
      local content = lastFunction(...)
      if content then return content() end
    end,
    setTooltip = function(text) return h.ui.text(text) end,
    -- sections repliables : comme en jeu, une section ouverte d'office (DefaultOpen, 0x20) est rendue, une
    -- section fermée ne l'est pas (son contenu ne coûte rien), sauf h.openSections (contenu vérifié par un
    -- test, comme h.hover pour les infobulles)
    treeNode = function(label, flags, content)
      if type(flags) == 'function' then content, flags = flags, 0 end
      uiCall()
      register('nœud', label)
      h.nodes = h.nodes or {}
      h.nodes[#h.nodes + 1] = label:match('^(.-)###') or label
      local open = math.floor((tonumber(flags) or 0) / 0x20) % 2 == 1
      if not (open or h.openSections) then return nil end
      return scoped(label:match('###(.*)$') or label, content)
    end,
    -- fenêtre enfant : largeur disponible réduite à celle du volet (size.x > 0), ou au reste de la ligne
    childWindow = function(id, size, ...)
      uiCall()
      register('fenêtre enfant', id)
      local content = lastFunction(...)
      if content == nil then return nil end
      local saved = h.width
      if type(size) == 'table' and size.x and size.x > 0 then
        h.width, h.lastChildWidth = size.x, size.x
      else
        h.width = saved - (h.lastChildWidth or 0) - 8
      end
      local ok, result = pcall(scoped, id, content)
      h.width = saved
      if not ok then error(result, 0) end
      return result
    end,
    -- onglets : tous affichés (h.tab nil), ou le seul onglet h.tab ; libellés vus dans h.tabs
    tabBar = function(_, flags, content)
      if type(flags) == 'function' then content = flags end
      h.tabs = {}
      return content()
    end,
    tabItem = function(label, flags, content)
      if type(flags) == 'function' then content = flags end
      register('onglet', label)
      local visible, id = label:match('^(.-)###(.*)$')
      h.tabs[#h.tabs + 1] = visible or label
      if h.tab == nil or h.tab == label or h.tab == visible or h.tab == id then return scoped(id or label, content) end
    end,
    -- curseur : h.sliders[libellé] remplace la valeur (une fois)
    slider = function(label, value)
      uiCall()
      register('curseur', label)
      local visible, id = label:match('^(.-)###(.*)$')
      for _, key in ipairs({ label, visible or label, id or label }) do
        local wanted = h.sliders and h.sliders[key]
        if wanted ~= nil then
          h.sliders[key] = nil
          return wanted, true
        end
      end
      return value, false
    end,
    checkbox = function(label)
      uiCall()
      register('case', label)
      return clicked(label)
    end,
    -- saisie : h.inputs[libellé visible] = texte tapé (rendu une fois, comme une frappe validée)
    inputText = function(label, str)
      uiCall()
      register('saisie', label)
      local visible, id = label:match('^(.-)###(.*)$')
      for _, key in ipairs({ visible or label, id or label }) do
        local wanted = h.inputs and h.inputs[key]
        if wanted ~= nil then
          h.inputs[key] = nil
          return wanted, true, false
        end
      end
      return str, false, false
    end,
    setNextItemWidth = function() uiCall() end,
  }
  h.ffi = ffi

  for _, path in ipairs(opts.missing or {}) do setPath(h, path, nil) end
  for _, path in ipairs(opts.throwing or {}) do
    if getPath(h, path) ~= nil then setPath(h, path, function() error('erreur simulée : ' .. path) end) end
  end
  return h
end

-- Installe l'hôte comme globales CSP (pour charger SetupLab.lua tel quel).
function F.install(h)
  rawset(_G, 'ac', h.ac)
  rawset(_G, 'physics', h.physics)
  rawset(_G, 'io', h.io)
  rawset(_G, 'ui', h.ui)
  rawset(_G, 'vec2', h.vec2)
  rawset(_G, 'vec3', h.vec3)
  rawset(_G, 'rgbm', h.rgbm)
  -- chaque fenêtre dessinée repart d'une liste d'identifiants vide (une image, une fenêtre)
  local script = setmetatable({}, { __newindex = function(s, name, fn)
    if type(fn) == 'function' and (name == 'SETUPLAB__MAIN' or name == 'SETUPLAB__DEBUG') then
      local draw = fn
      fn = function(...)
        h.ids, h.idScope = {}, ''
        return draw(...)
      end
    end
    rawset(s, name, fn)
  end })
  rawset(_G, 'script', script)
end

-- Garde de course (1.5, décision de Vincent du 26/10/2026) : référence de qualification validée de ce circuit (fichier
-- écrit par SetupLab, mémoire stockée), montée dans la voiture (setup en cours), nombre de tours saisi. Après la
-- découverte.
function F.raceReady(h, app, laps)
  local Store = require('src/store')
  local Util = require('src/util')
  local Exporter = require('src/exporter')
  local folder = assert(Exporter.targetFolder({ ac = h.ac, io = h.io }))
  local text = h.ac.stringifyCurrentSetup(true, false)
  -- setup chargé par SetupLab : il devient la référence (même fichier)
  local loaded = app.loaded and app.loaded.quali
  local name = loaded and loaded.name or 'SetupLab_Qualif_v1.ini'
  text = h.written[folder .. '/' .. name] or text
  h.written[folder .. '/' .. name] = text
  local d = assert(app.discovery, 'découverte d\'abord')
  local track, layout = d.trackFiles.fullId:match('^([^/]+)/([^/]+)$')
  if track == nil then track, layout = d.trackFiles.fullId, '-' end
  local bucket = app.wet and app.wet.state or 'sec'
  Store.put(app.store, Store.entryKey('mem', d.car.id, track, layout, 'qualif', bucket),
    { file = name, hash = Util.hashString(text), version = 1, gain = 0, time = 0, locked = false })
  Store.put(app.store, Store.entryKey('rlaps', d.car.id, track, layout), { laps = laps or 20 })
  app.raceLaps = laps or 20
  app.memoryFiles = {}
  app.refreshMemory()
end

return F
