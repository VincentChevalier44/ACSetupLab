-- Tests du module src/caps (capacités, horloge, évaluation, rapport J0).
local T = require('t')
local ffi = require('ffi')
local Util = require('src/util')
local Config = require('src/config')
local Caps = require('src/caps')
local Datasource = require('src/datasource')
local Fake = require('fakehost')

local SYNC = Util.syncContext()
local tests = {}

local function host(carId, trackId, opts)
  opts = opts or {}
  opts.car = require('fixtures/cars/' .. carId)
  opts.track = require('fixtures/tracks/' .. trackId)
  return Fake.new(opts)
end

-- Même enchaînement que la découverte de la colle, en synchrone.
local function discover(h)
  local static = Caps.probeStatic(h)
  local d = { static = static, clockOk = true }
  d.session = Datasource.readSession(h)
  d.car = Datasource.readCar(h, 0, SYNC)
  d.carState = Datasource.readCarState(h, 0)
  d.telemetry = Datasource.telemetryCheck(h, 0)
  d.setup = Datasource.readSetup(h, SYNC)
  d.trackFiles = Datasource.readTrackFiles(h, SYNC)
  d.track = Datasource.sampleTrack(h, 2, SYNC)
  d.raycast = Datasource.probeRaycast(h, 0)
  d.caps = Caps.evaluate(static, d)
  return d
end

local function status(d, id)
  local entry = d.caps.byId[id]
  T.ok(entry, 'capacité évaluée : ' .. id)
  return entry.status, entry.detail
end

tests['K01 appelables : fonctions Lua, tables __call, pointeurs de fonction cdata'] = function()
  T.ok(Caps.isCallable(function() end, ffi))
  T.ok(Caps.isCallable(setmetatable({}, { __call = function() end }), ffi))
  T.no(Caps.isCallable({}, ffi))
  local cb = ffi.cast('int (*)(int)', function(x) return x + 1 end)
  T.ok(Caps.isCallable(cb, ffi), 'fonction C exposée en cdata')
  T.no(Caps.isCallable(cb, nil), 'sans FFI : prudence')
  cb:free()
  T.no(Caps.isCallable(Fake.array({ 1 }), ffi), 'structure cdata non appelable')
  T.no(Caps.isCallable(ffi.cast('void *', nil), ffi), 'pointeur nul')
  T.no(Caps.isCallable(ffi.new('int[2]'), ffi), 'tableau cdata')
  T.no(Caps.isCallable(nil, ffi))
  T.no(Caps.isCallable(3, ffi))
  T.no(Caps.isCallable('ac.getCar', ffi))
end

tests['K02 résolution de chemins sans erreur'] = function()
  local h = host('formula_k', 'spa')
  T.eq(type(Caps.resolve(h, 'ac.INIConfig.carData')), 'function')
  T.eq(Caps.resolve(h, 'ac.absent.x'), nil)
  T.eq(Caps.resolve({ ac = { s = Fake.strict({}, 's') } }, 'ac.s.inconnu'), nil, 'champ inconnu d\'une structure')
  T.eq(Caps.resolve(h, 'ac.FolderID.UserSetups'), 11)
end

tests['K03 horloge précise QueryPerformanceCounter'] = function()
  local clock, reason = Caps.makeClock(ffi)
  T.ok(clock, 'horloge disponible sur le banc Windows : ' .. tostring(reason))
  local a = clock()
  local x = 0
  for i = 1, 200000 do x = x + i % 7 end
  local b = clock()
  T.ok(b > a, 'monotone')
  T.ok(b - a < 1, 'ordre de grandeur plausible')
  T.ok(x > 0)
  local again = Caps.makeClock(ffi)
  T.ok(again, 'recréation tolérée (cdef déjà déclaré)')
  local none, why = Caps.makeClock(nil)
  T.eq(none, nil)
  T.eq(why, 'FFI indisponible')
end

tests['K03b heure locale de Windows (noms des fichiers enregistrés)'] = function()
  -- banc Windows : décalage réel, au quart d'heure, recréation tolérée
  local offset, reason = Caps.makeUtcOffset(ffi)
  T.ok(offset, 'heure locale disponible sur le banc Windows : ' .. tostring(reason))
  local value = offset()
  T.ok(value and value % 900 == 0 and math.abs(value) <= 14 * 3600, tostring(value))
  T.ok(Caps.makeUtcOffset(ffi), 'recréation tolérée (cdef déjà déclaré)')
  T.eq(select(2, Caps.makeUtcOffset(nil)), 'FFI indisponible')
  -- FFI simulée : heures lues par GetLocalTime et GetSystemTime
  local times = {}
  local function fill(which)
    return function(buffer)
      local t = times[which]
      local st = buffer[0]
      st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond = t[1], t[2], t[3], t[4], t[5], t[6]
    end
  end
  local fake = { cdef = function() end, new = function() return { [0] = {} } end,
    C = { GetLocalTime = fill('local'), GetSystemTime = fill('system') } }
  local function at(localTime, systemTime)
    times['local'], times.system = localTime, systemTime
    local fn = Caps.makeUtcOffset(fake)
    return fn and fn() or nil
  end
  T.eq(at({ 2026, 10, 21, 14, 32, 5 }, { 2026, 10, 21, 12, 32, 4 }), 7200, 'Paris en été, seconde passée entre les lectures')
  T.eq(at({ 2026, 10, 22, 0, 30, 0 }, { 2026, 10, 21, 22, 30, 0 }), 7200, 'changement de jour')
  T.eq(at({ 2026, 1, 1, 5, 15, 0 }, { 2025, 12, 31, 23, 30, 0 }), 20700, 'Népal, +5 h 45, changement d\'année')
  T.eq(at({ 2026, 3, 1, 19, 0, 0 }, { 2026, 3, 2, 0, 0, 0 }), -18000, 'New York')
  T.eq(at({ 2026, 10, 25, 12, 0, 0 }, { 2026, 10, 23, 12, 0, 0 }), nil, 'écart absurde rejeté')
  local broken = { cdef = function() end, new = function() return { [0] = {} } end, C = {} }
  T.eq(select(2, Caps.makeUtcOffset(broken)), 'GetLocalTime introuvable')
end

tests['K04 sondes statiques'] = function()
  local s = Caps.probeStatic(host('formula_k', 'spa'))
  T.eq(s.presentCount, #Caps.FUNCTIONS)
  T.eq(#s.missing, 0)
  T.eq(s.version, '0.3.0-preview675')
  T.eq(s.versionCode, 4210)
  T.ok(s.ioAvailable)
  T.ok(s.folders.UserSetups:find('setups$'))
  T.ok(s.folders.ContentCars)
  for _, f in ipairs(s.neverCalled) do T.ok(f.present, f.path .. ' constatée') end
  local m = Caps.probeStatic(host('formula_k', 'spa', { missing = { 'ac.getSetupSpinners', 'io.save' },
    throwing = { 'ac.getPatchVersion', 'io.available' } }))
  T.eq(#m.missing, 2)
  T.eq(m.version, nil)
  T.no(m.ioAvailable)
end

tests['K05 évaluation complète : GT3 à Spa'] = function()
  local h = host('lamborghini_huracan_gt3_evo2', 'spa')
  local d = discover(h)
  local expected = {
    csp = 'available', functions = 'available', car_ini = 'available', car_files = 'available', car_lut = 'available',
    car_rto = 'available', track_spline = 'available', track_length = 'available', track_data = 'available',
    raycast = 'available', telemetry = 'available', setup_read = 'available', setup_text = 'available',
    setup_encoding = 'available', setup_state = 'available', setup_write = 'pending', clipboard = 'available',
    storage = 'pending', session = 'available', conditions = 'available', drs = 'na', ers = 'na', clock = 'available',
  }
  for id, want in pairs(expected) do
    local got, detail = status(d, id)
    T.eq(got, want, id .. ' (' .. detail .. ')')
  end
  local _, lengthDetail = status(d, 'track_length')
  T.contains(lengthDetail, 'déclarée 7004 m')
  T.eq(#d.caps.list, 24)
  T.eq(status(d, 'setup_load'), 'pending', 'chargement possible, non testé')
  T.eq(h.writeCalls, 0, 'aucune écriture pendant la découverte')
end

tests['K06 évaluation dégradée : données illisibles, encodage, pluie, DRS/ERS, E/S'] = function()
  local d = discover(host('lamborghini_huracan_gt3_evo2', 'spa', { carDataError = true }))
  T.eq(status(d, 'car_ini'), 'unavailable')
  local _, detail = status(d, 'car_ini')
  T.contains(detail, 'mesure uniquement')
  T.eq(status(d, 'car_lut'), 'unavailable')
  T.eq(status(d, 'car_rto'), 'na')
  d = discover(host('lamborghini_huracan_gt3_evo2', 'spa', { noSpline = true }))
  T.eq(status(d, 'track_spline'), 'unavailable')
  T.eq(d.caps.byId.track_length, nil)
  -- A12 : l'encodage ne conditionne plus la capacité d'écriture, seulement les réglages modifiables.
  d = discover(host('lamborghini_huracan_gt3_evo2', 'spa', { setupMismatch = 'ARB_FRONT' }))
  T.eq(status(d, 'setup_encoding'), 'unavailable')
  local _, encodingDetail = status(d, 'setup_encoding')
  T.contains(encodingDetail, 'ne seront pas modifiés par l\'export')
  T.eq(status(d, 'setup_write'), 'pending', 'écriture indépendante de l\'encodage')
  d = discover(host('lamborghini_huracan_gt3_evo2', 'spa', { gearNames = 'internal' }))
  T.eq(status(d, 'setup_encoding'), 'pending', 'boîte non vérifiée : jamais « disponible »')
  local _, gearDetail = status(d, 'setup_encoding')
  T.contains(gearDetail, 'FINAL_GEAR_RATIO')
  T.eq(status(d, 'setup_write'), 'pending', 'écriture indépendante de l\'encodage')
  local _, untested = status(d, 'setup_write')
  T.contains(untested, 'non testée')
  -- Résultat d'un test d'écriture réel : seul un succès relu rend la capacité « disponible ».
  local hw = host('formula_k', 'spa')
  local dw = discover(hw)
  dw.writeTest = { ok = true, path = 'C:/x/SetupLab_Test.ini' }
  dw.caps = Caps.evaluate(dw.static, dw)
  T.eq(status(dw, 'setup_write'), 'available')
  dw.writeTest = { ok = false, reason = 'io.save a refusé l\'écriture' }
  dw.caps = Caps.evaluate(dw.static, dw)
  T.eq(status(dw, 'setup_write'), 'unavailable')
  local _, failed = status(dw, 'setup_write')
  T.contains(failed, 'io.save a refusé')
  T.contains(failed, 'repli presse-papiers')
  local wet = host('whk_dtm_2026', 'monza', { drs = true, kers = true })
  wet.sim.rainIntensity = 0.4
  wet.sim.fixedSetup = true
  d = discover(wet)
  local _, cond = status(d, 'conditions')
  T.contains(cond, 'D16')
  T.eq(status(d, 'drs'), 'pending', 'DRS jamais « disponible » avant J6b')
  local _, drsDetail = status(d, 'drs')
  T.contains(drsDetail, 'présent selon AC')
  T.contains(drsDetail, 'WING_4 « DRS » [EFFECT=0.50]')
  T.contains(drsDetail, 'zones du circuit : ')
  T.contains(drsDetail, 'ouvert : false')
  T.eq(status(d, 'ers'), 'pending')
  -- drs.ini avec aile mobile, mais AC ne signale pas de DRS : on le dit, sans conclure seul
  local quiet = discover(host('whk_dtm_2026', 'monza', { drs = false }))
  T.eq(status(quiet, 'drs'), 'pending')
  local _, quietDetail = status(quiet, 'drs')
  T.contains(quietDetail, 'AC ne signale pas de DRS')
  T.eq(status(discover(host('lamborghini_huracan_gt3_evo2', 'monza')), 'drs'), 'na', 'drs.ini vide')
  local ers = discover(host('urd_px1_aura', 'monza', { kers = true }))
  local _, ersDetail = status(ers, 'ers')
  T.contains(ersDetail, 'ers.ini')
  T.contains(ersDetail, '5000 kJ par tour')
  T.contains(ersDetail, 'MGU-H')
  T.eq(status(d, 'setup_state'), 'pending')
  local _, fixed = status(d, 'setup_state')
  T.contains(fixed, 'D20')
  local noio = host('formula_k', 'spa')
  noio.io.available = function() return false end
  d = discover(noio)
  T.eq(status(d, 'setup_write'), 'unavailable')
  local _, io = status(d, 'setup_write')
  T.contains(io, 'pas d\'accès fichiers')
  d = discover(host('formula_k', 'spa', { missing = { 'ac.getSetupSpinners' } }))
  T.eq(status(d, 'setup_read'), 'unavailable')
  T.eq(status(d, 'setup_encoding'), 'pending')
  local empty = Caps.evaluate(nil, {})
  T.eq(empty.byId.csp.status, 'pending')
  T.eq(empty.byId.clock.status, 'pending')
end

tests['K07 rapport J0 : contenu, déterminisme, troncature'] = function()
  local d = discover(host('lamborghini_huracan_gt3_evo2', 'spa'))
  local info = { appVersion = Config.version, milestone = Config.milestone, date = '19/10/2026 18:00 UTC' }
  local log = Util.logNew(10, 0)
  Util.logAdd(log, 1, 'WARN', 'w', 'avertissement de test')
  Util.logAdd(log, 2, 'INFO', 'i', 'information non reprise')
  local text, truncated = Caps.buildReport(info, d, Util.logEntries(log))
  T.no(truncated)
  for _, fragment in ipairs({ '== Capacités ==', '== Fonctions CSP ==', '== Données voiture ==', '== Setup ==',
    '== Circuit ==', '== Session ==', '== Télémétrie ==', 'lamborghini_huracan_gt3_evo2', 'TOTALMASS = 1334',
    'Comparaison : ', 'avertissement de test', 'Jamais appelée (D8) : ac.setSetupSpinnerValue' }) do
    T.contains(text, fragment)
  end
  T.no(text:find('information non reprise', 1, true))
  local rows = 0
  for line in text:gmatch('[^\n]+') do
    if line:find(' | ', 1, true) and not line:find('^nom') then rows = rows + 1 end
  end
  T.eq(rows, #d.setup.spinners, 'une ligne par cran')
  T.eq(Caps.buildReport(info, d, Util.logEntries(log)), text, 'déterministe')
  local saved = Config.K.maxReportChars
  Config.K.maxReportChars = 500
  local short, cut = Caps.buildReport(info, d, {})
  Config.K.maxReportChars = saved
  T.ok(cut)
  T.ok(#short <= 520)
  T.contains(short, '[rapport tronqué]')
  local minimal = Caps.buildReport(info, {}, nil)
  T.contains(minimal, 'SetupLab')
end

-- CSP 0.3.1-preview2 bloque QueryPerformanceCounter (rapport J0 du 29/10/2026) : l'horloge officielle de CSP prend le
-- relais (accord de Vincent) ; sans elle, repli sur le quota.
tests['C20 horloge : sans QueryPerformanceCounter, os.preciseClock de CSP'] = function()
  local blocked = { cdef = function() end, C = setmetatable({}, { __index = function() error('symbole bloqué') end }),
    new = function() return {} end }
  local t = 10
  local clock, reason, source = Caps.makeClock(blocked, function() t = t + 0.001; return t end)
  T.ok(clock, tostring(reason))
  T.contains(source, 'os.preciseClock')
  local a, b = clock(), clock()
  T.ok(b > a)
  local none, why = Caps.makeClock(blocked, nil)
  T.eq(none, nil)
  T.contains(why, 'QueryPerformanceCounter introuvable')
end

return tests
