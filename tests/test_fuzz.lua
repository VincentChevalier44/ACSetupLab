-- Fuzz (§14.2) : textes et structures aléatoires, hôte dégradé au hasard. Graines fixes.
local T = require('t')
local Util = require('src/util')
local Config = require('src/config')
local Caps = require('src/caps')
local Datasource = require('src/datasource')
local Fake = require('fakehost')

local K = Config.K
local SYNC = Util.syncContext()
local tests = {}

local ALPHABET = '[]=;/|,.-+eE0123456789 \t\r\nABCDEFGHIJKLMNOPQRSTUVWXYZ_()km"length:'

local function randomText(rng, maxLength)
  local n = math.floor(Util.rngNext(rng) * maxLength)
  local parts = {}
  local structured = Util.rngNext(rng) < 0.7
  for i = 1, n do
    if structured then
      local k = math.floor(Util.rngNext(rng) * #ALPHABET) + 1
      parts[i] = ALPHABET:sub(k, k)
    else
      parts[i] = string.char(math.floor(Util.rngNext(rng) * 256))
    end
  end
  return table.concat(parts)
end

tests['F01 analyseurs de texte sur entrées aléatoires'] = function()
  local rng = Util.rngNew(20261019)
  for _ = 1, 1500 do
    local text = randomText(rng, 1500)
    local ini = Util.parseIni(text, { maxBytes = 4096, maxSections = 32, maxKeys = 16, maxValueChars = 64 })
    T.ok(#ini.order <= 32)
    for _, name in ipairs(ini.order) do
      for _, value in pairs(ini.sections[name]) do T.ok(#value <= 64) end
    end
    local lut = Util.parseLutText(text, 64)
    if lut then
      T.ok(lut.n <= 64)
      for i = 2, lut.n do T.ok(lut.x[i] > lut.x[i - 1], 'abscisses strictement croissantes') end
      T.finite(Util.lutEval(lut, Util.rngRange(rng, -1e6, 1e6)))
    end
    for _, r in ipairs(Util.parseRto(text, 16)) do T.ok(r.ratio > 0 and r.ratio < 100) end
    local value = Datasource.parseDeclaredLength(text)
    T.ok(value == nil or (value >= 100 and value <= 100000))
    local n = Util.parseNumber(text:sub(1, 40))
    T.ok(n == nil or Util.isFinite(n))
    Util.parseNumberList(text:sub(1, 200))
  end
end

local function randomValue(rng, depth)
  local r = Util.rngNext(rng)
  if r < 0.2 then return randomText(rng, 30) end
  if r < 0.35 then return Util.rngRange(rng, -1e6, 1e6) end
  if r < 0.4 then return 0 / 0 end
  if r < 0.45 then return Util.rngNext(rng) < 0.5 end
  if r < 0.5 then return function() end end
  if depth <= 0 then return nil end
  local t = {}
  for i = 1, math.floor(Util.rngNext(rng) * 6) do
    local key = Util.rngNext(rng) < 0.7 and randomText(rng, 12) or i
    t[key] = randomValue(rng, depth - 1)
  end
  return t
end

tests['F02 normalisation de structures aléatoires'] = function()
  local rng = Util.rngNew(7)
  for _ = 1, 800 do
    local out = Datasource.normalizeSections(randomValue(rng, 3))
    T.ok(#out.order <= K.maxIniSections)
    for _, name in ipairs(out.order) do
      for key, value in pairs(out.sections[name]) do
        T.eq(type(key), 'string')
        T.eq(type(value), 'string')
        T.ok(#value <= K.maxValueChars)
      end
    end
    Datasource.describeRaw(randomValue(rng, 2), 'BASIC', 6)
  end
end

local CARS = { 'formula_k', 'lamborghini_huracan_gt3_evo2', 'urd_px1_aura', 'whk_dtm_2026' }
local TRACKS = { 'spa', 'monza', 'ks_red_bull_ring-layout_gp' }
local PATHS = {
  'ac.getCarDataFiles', 'ac.INIConfig.carData', 'ac.INIConfig.trackData', 'ac.DataLUT11.carData', 'ac.readDataFile',
  'ac.getFolder', 'ac.getSetupSpinners', 'ac.stringifyCurrentSetup', 'ac.getCarPhysics', 'ac.getCar', 'ac.getSession',
  'ac.trackProgressToWorldCoordinate', 'ac.getTrackAISplineSides', 'ac.hasTrackSpline', 'ac.getAssists',
  'physics.raycastTrack', 'io.load', 'io.available', 'ac.getTrackName', 'ac.getCarName', 'ac.isSetupAvailableToEdit',
}
local CAR_FIELDS = { 'mass', 'fuel', 'brakeBias', 'wheels', 'rideHeight', 'speedMs', 'position', 'drsPresent', 'kersPresent' }
local SIM_FIELDS = { 'trackLengthM', 'ambientTemperature', 'roadTemperature', 'rainWetness', 'fixedSetup', 'fps' }

tests['F03 hôte dégradé au hasard : découverte complète sans erreur'] = function()
  local rng = Util.rngNew(424242)
  local allowed = { available = true, pending = true, unavailable = true, na = true }
  local function pick(list) return list[math.floor(Util.rngNext(rng) * #list) + 1] end
  for _ = 1, 60 do
    local missing, throwing = {}, {}
    for _, path in ipairs(PATHS) do
      local r = Util.rngNext(rng)
      if r < 0.12 then missing[#missing + 1] = path elseif r < 0.24 then throwing[#throwing + 1] = path end
    end
    local h = Fake.new({
      car = require('fixtures/cars/' .. pick(CARS)), track = require('fixtures/tracks/' .. pick(TRACKS)),
      missing = missing, throwing = throwing, iniMode = Util.rngNext(rng) < 0.5 and 'single' or 'split',
      rawForm = pick({ 'absolu', 'relatif', 'aucun' }), setupMismatch = Util.rngNext(rng) < 0.2 and 'FUEL' or nil,
      drs = Util.rngNext(rng) < 0.3, kers = Util.rngNext(rng) < 0.3,
    })
    for _, field in ipairs(CAR_FIELDS) do
      if Util.rngNext(rng) < 0.15 then rawset(h.car, field, nil) end
    end
    for _, field in ipairs(SIM_FIELDS) do
      local r = Util.rngNext(rng)
      if r < 0.1 then rawset(h.sim, field, nil) elseif r < 0.2 then rawset(h.sim, field, 0 / 0) end
    end
    local static = Caps.probeStatic(h)
    local d = { static = static, clockOk = false, clockReason = 'fuzz' }
    d.session = Datasource.readSession(h)
    d.context = Datasource.readContext(h)
    d.car = Datasource.readCar(h, 0, SYNC)
    d.carState = Datasource.readCarState(h, 0)
    d.telemetry = Datasource.telemetryCheck(h, 0)
    d.setup = Datasource.readSetup(h, SYNC)
    d.trackFiles = Datasource.readTrackFiles(h, SYNC)
    d.track = Datasource.sampleTrack(h, 2 + Util.rngNext(rng) * 3, SYNC)
    d.raycast = Datasource.probeRaycast(h, 0)
    d.caps = Caps.evaluate(static, d)
    for _, entry in ipairs(d.caps.list) do
      T.ok(allowed[entry.status], 'statut connu : ' .. tostring(entry.status))
      T.eq(type(entry.detail), 'string')
    end
    local report = Caps.buildReport({ appVersion = 'x', milestone = 'y', date = 'z' }, d, {})
    T.ok(#report > 100 and #report <= K.maxReportChars + 64)
    T.eq(h.writeCalls, 0)
  end
end

-- Texte stocké aléatoire (§13, §16.7 « stockage corrompu ») : enregistrements composés de pièces
-- plausibles (genres, champs, valeurs dans et hors bornes, chaînes piégées) puis abîmés au hasard ; aucune
-- erreur, chaque champ relu respecte son schéma, et le texte réécrit est relu à l'identique.
local STORE_KEYS = { 'settings', 'cal:car:monza:-:1', 'cal:car:ks_red_bull_ring:layout_gp:0', 'rough:car:spa:-',
  'last:car:monza:-:quali', 'frame:car', 'cal:../x:1', 'x();os.exit()', '' }
local STORE_FIELDS = { 'refineMinLaps', 'perfStab', 'calibrationAuto', 'mu', 'power', 'drag', 'lift', 'brake', 'roadTemp', 'G0',
  'front', 'speed', 'file', 'gain', 'stamp', 'inconnu', '' }
local STORE_VALUES = { '25', '0.6', '-1', '1e9', 'nan', 'inf', 'true', 'false', '0.97', '1.0e-5', 's:SetupLab_Quali.ini',
  's:../../evil.lua', 's:', 'abc', '' }
tests['F04 stockage : texte aléatoire relu sans erreur, champs conformes au schéma'] = function()
  local Store = require('src/store')
  local rng = Util.rngNew(1313)
  local function pick(list) return list[math.floor(Util.rngNext(rng) * #list) + 1] end
  local function text()
    local records = { Util.rngNext(rng) < 0.9 and 'setuplab-store 1' or pick({ 'setuplab-store 9', 'junk', '' }) }
    for i = 1, math.floor(Util.rngNext(rng) * 40) do
      local value = pick(STORE_VALUES)
      if Util.rngNext(rng) < 0.3 then value = tostring((Util.rngNext(rng) - 0.5) * 10 ^ math.floor(Util.rngNext(rng) * 8 - 4)) end
      records[i + 1] = pick(STORE_KEYS) .. '#' .. pick(STORE_FIELDS) .. '=' .. value
    end
    local out = table.concat(records, '|')
    -- dégâts au hasard : caractères remplacés ou insérés
    for _ = 1, math.floor(Util.rngNext(rng) * 4) do
      local at = math.floor(Util.rngNext(rng) * (#out + 1))
      out = out:sub(1, at) .. string.char(math.floor(Util.rngNext(rng) * 256)) .. out:sub(at + 2)
    end
    return out
  end
  local kept = 0
  for _ = 1, 3000 do
    local entries = Store.parse(text())
    for key, fields in pairs(entries) do
      T.ok(key:match('^[%w_:%-%.]+$'), 'clé ' .. key)
      for field, value in pairs(fields) do
        kept = kept + 1
        if field ~= 'stamp' then
          local store = { entries = {} }
          T.ok(Store.put(store, key, { [field] = value }), 'champ relu valide : ' .. key .. '#' .. field)
        end
      end
    end
    local again = Store.parse(Store.serialize(entries))
    T.eq(Store.serialize(again), Store.serialize(entries), 'aller-retour stable')
  end
  PY.note('F04', kept .. ' champs valides relus sur 3000 textes aléatoires')
  T.ok(kept > 1000, 'le générateur produit aussi des champs valides')
end

-- L'app entière sous hôte dégradé, stockage corrompu et clics au hasard (§16.5, §16.7) : aucune erreur
-- de tâche ni de rendu, aucune écriture interdite (D8).
local BUTTONS = { 'Calculer le setup tour rapide', 'Annuler le calcul', 'Calculer le setup course', 'Annuler le calcul course',
  'Enregistrer le setup tour rapide', 'Enregistrer le setup course', 'Mesurer le gain réel', 'Mesurer le gain réel (course)',
  'Relancer la découverte', 'Copier le rapport J0', 'Calibrer maintenant', 'Copier le tour enregistré',
  'Afficher les réglages', 'Afficher le détail des capacités', 'Calibration automatique',
  'Charger le setup tour rapide dans la voiture', 'Confirmer le chargement (tour rapide)',
  'Charger le setup course dans la voiture', 'Confirmer le chargement (course)',
  -- 1.4.0 : SetupLab actif, valider, écarter, figer, mémoire du circuit
  'SetupLab actif', 'Valider v1', 'Recommencer (ne pas garder v1)', 'Figer v1 (cadenas)', 'Valider v2',
  'Recommencer (ne pas garder v2)', 'Libérer vos retouches (tour rapide)',
  'Affinage automatique (tour rapide)', 'Affinage automatique (course)', 'Charger###memload_qualif_sec',
  'Figer (cadenas)###memlock_qualif_sec', 'Déverrouiller###memlock_qualif_sec', 'Confirmer le chargement (tour rapide)' }
local TABS = { 'Tour rapide', 'Course', 'Mesure', 'Réglages', 'Capacités' }
tests['F05 app entière : hôte dégradé, stockage corrompu, clics au hasard'] = function()
  local rng = Util.rngNew(8080)
  local function pick(list) return list[math.floor(Util.rngNext(rng) * #list) + 1] end
  local labels = {}
  for _, def in ipairs(Config.settings) do labels[#labels + 1] = def end
  local seen = { discovery = 0, quali = 0, race = 0, cancelled = 0, loads = 0 }
  for round = 1, 10 do
    local missing, throwing = {}, {}
    for _, path in ipairs(PATHS) do
      local r = Util.rngNext(rng)
      if r < 0.06 then missing[#missing + 1] = path elseif r < 0.12 then throwing[#throwing + 1] = path end
    end
    local h = Fake.new({
      car = require('fixtures/cars/' .. pick(CARS)), track = require('fixtures/tracks/' .. pick(TRACKS)),
      missing = missing, throwing = throwing, drs = Util.rngNext(rng) < 0.3, kers = Util.rngNext(rng) < 0.3,
    })
    local Store = require('src/store')
    local junk = {}
    for i = 1, math.floor(Util.rngNext(rng) * 200) do
      junk[i] = string.char(32 + math.floor(Util.rngNext(rng) * 95))
    end
    h.stored = { [Store.KEY] = (Util.rngNext(rng) < 0.5 and 'setuplab-store 1|' or '') .. table.concat(junk) }
    Fake.install(h)
    assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
    local app = rawget(_G, 'SETUPLAB').app
    -- budgets courts : les calculs lancés au hasard aboutissent quelle que soit la vitesse de la machine
    app.settings.optBudgetEvalsQ, app.settings.optBudgetEvalsC = 100, 20
    for frame = 1, 6000 do
      -- séquence de chargement forcée (D8 amendé), sans clic au hasard au milieu : calcul tour rapide à petit
      -- budget (un curseur tiré au hasard a pu le monter), enregistrer, armer, attendre le délai minimal (sans
      -- horloge précise : images affichées), confirmer. Fenêtre calme dès le calcul : un clic au hasard
      -- (annuler, relancer la découverte) le perdrait, et la séquence dépendrait du tirage.
      local quiet = frame >= 4700 and frame <= 5450
      if not quiet and Util.rngNext(rng) < 0.01 then h.click = pick(BUTTONS) end
      -- calculs lancés à coup sûr (le hasard seul les annule souvent)
      if frame == 3000 then h.tab, h.click = nil, 'Calculer le setup course' end
      -- avant la séquence forcée : SetupLab en veille et affinage arrêté (par l'interface), sinon l'affinage
      -- remplacerait le setup à charger
      if frame == 4690 and app.auto then h.tab, h.click = nil, 'SetupLab actif' end
      if frame == 4695 and app.refine and app.refine.active then
        h.tab, h.click = nil, 'Arrêter l\'affinage (' .. (app.refine.kind == 'race' and 'course' or 'tour rapide') .. ')'
      end
      if frame == 4700 then
        app.settings.optBudgetEvalsQ = 100
        h.tab, h.click = nil, 'Calculer le setup tour rapide'
      end
      if frame == 5390 then app.clock = nil end
      if frame == 5400 then h.tab, h.click = nil, 'Enregistrer le setup tour rapide' end
      if frame == 5402 then h.tab, h.click = nil, 'Charger le setup tour rapide dans la voiture' end
      if frame == 5402 + Config.K.loadConfirmMinFrames + 5 then h.tab, h.click = nil, 'Confirmer le chargement (tour rapide)' end
      if not quiet and Util.rngNext(rng) < 0.02 then h.tab = Util.rngNext(rng) < 0.3 and nil or pick(TABS) end
      if Util.rngNext(rng) < 0.005 then
        local def = pick(labels)
        if def.min then
          h.sliders = { [def.label] = def.min + (def.max - def.min) * (Util.rngNext(rng) * 1.4 - 0.2) }
        end
      end
      h.sim.time = h.sim.time + 1000 / 60
      script.SETUPLAB__UPDATE(1 / 60)
      script.SETUPLAB__MAIN(1 / 60)
      local _ = frame
    end
    if app.discoveryState == 'done' then seen.discovery = seen.discovery + 1 end
    for _, kind in ipairs({ 'quali', 'race' }) do
      if app[kind] and app[kind].state == 'done' then seen[kind] = seen[kind] + 1 end
      if app[kind] and app[kind].state == 'cancelled' then seen.cancelled = seen.cancelled + 1 end
    end
    T.eq(app.perf.errors, 0, 'tour ' .. round .. ' : erreurs de rendu ou de tâche')
    -- seules écritures permises : de nouveaux fichiers de setup (export, D8) ; aucun appel interdit
    local saved = 0
    for path in pairs(h.written) do
      saved = saved + 1
      T.ok(path:find('/setups/', 1, true) and path:match('%.ini$'), 'fichier écrit hors des setups : ' .. path)
    end
    -- rangement (D8 amendé le 22/10/2026) : un fichier parti à la Corbeille avait été écrit
    T.eq(h.writeCalls, saved + #h.recycled, 'aucune écriture interdite (D8)')
    -- chargements (D8 amendé) : seulement un setup qualification ou course écrit par SetupLab (aucun nom
    -- choisi ici : préfixe SetupLab), chacun précédé d'une copie de sauvegarde du setup en cours
    local copies = 0
    for path in pairs(h.written) do
      if path:find(Config.fileWords.fr.backup, 1, true) or path:find(Config.fileWords.en.backup, 1, true) then copies = copies + 1 end
    end
    -- noms dans l'une ou l'autre langue (stockage corrompu : réglages par défaut, anglais)
    for _, path in ipairs(h.loadCalls) do
      local own = false
      for _, w in pairs(Config.fileWords) do
        own = own or path:find('/SetupLab_' .. w.quali .. '_', 1, true) ~= nil or path:find('/SetupLab_' .. w.race .. '_', 1, true) ~= nil
      end
      T.ok(h.written[path] and own, 'chargement d\'un fichier étranger : ' .. path)
    end
    -- copie inutile quand la voiture roule avec un fichier gardé de SetupLab (réponse de Vincent du 22/10/2026)
    local skipped = app.backupsSkipped or 0
    T.ok(copies + #h.recycled + skipped >= #h.loadCalls, 'copie de sauvegarde avant chaque chargement')
    -- journal ordonné : chaque chargement suit immédiatement l'écriture de sa copie de sauvegarde, sauf copie
    -- inutile (setup en cours déjà enregistré par SetupLab, compté par l'app)
    local without = 0
    for i, event in ipairs(h.events) do
      if event[1] == 'load' then
        local previous = h.events[i - 1]
        if not (previous and previous[1] == 'save' and (previous[2]:find(Config.fileWords.fr.backup, 1, true) or previous[2]:find(Config.fileWords.en.backup, 1, true))) then
          without = without + 1
        end
      end
    end
    T.ok(without <= skipped, 'chargement sans copie de sauvegarde juste avant : ' .. without .. ' pour ' .. skipped .. ' inutiles')
    seen.loads = seen.loads + #h.loadCalls
    for key, def in pairs(Config.validate(app.settings)) do T.eq(app.settings[key], def, 'réglage ' .. key .. ' valide') end
    h.tab, h.sliders, h.click = nil, nil, nil
  end
  PY.note('F05', string.format('10 séances : %d découvertes, %d calculs qualification et %d course terminés, %d annulés, '
    .. '%d chargements', seen.discovery, seen.quali, seen.race, seen.cancelled, seen.loads))
  T.ok(seen.discovery > 0 and seen.quali + seen.race > 0, 'le hasard atteint les calculs')
  T.ok(seen.loads > 0, 'la séquence forcée atteint le chargement')
end

-- §16.7 « voiture sans aero.ini » : AC exige ce fichier ; illisible, le modèle est déclaré incomplet :
-- découverte complète, calcul refusé avec sa raison (mode mesure uniquement), aucune erreur ni écriture.
tests['F06 voiture sans aero.ini : refus motivé, aucune erreur'] = function()
  for _, carId in ipairs(CARS) do
    local h = Fake.new({ car = require('fixtures/cars/' .. carId), track = require('fixtures/tracks/monza') })
    h.files['aero.ini'] = nil
    Fake.install(h)
    assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
    local app = rawget(_G, 'SETUPLAB').app
    for _ = 1, 40000 do
      h.sim.time = h.sim.time + 1000 / 60
      script.SETUPLAB__UPDATE(1 / 60)
      script.SETUPLAB__MAIN(1 / 60)
      if app.discoveryState ~= 'running' and app.discoveryState ~= 'idle' then break end
    end
    T.eq(app.discoveryState, 'done', carId .. ' : ' .. tostring(app.discoveryError))
    local blocker = app.qualiBlocker()
    T.ok(blocker, carId .. ' : calcul refusé')
    local missing = table.concat(app.discovery.carBaseMissing or {}, ', ')
    T.contains(missing, 'aérodynamique')
    T.eq(app.perf.errors, 0, carId .. ' : erreurs')
    T.eq(h.writeCalls, 0)
    PY.note('F06 ' .. carId, 'calcul refusé : ' .. blocker)
  end
end

-- §16.7 « LUT vides » : courbe de puissance vide (moteur inconnu) ou courbe de pneu vide : découverte
-- complète, calcul refusé avec la raison ou modèle de repli, jamais d'erreur.
tests['F07 LUT vides : refus motivé ou repli, aucune erreur'] = function()
  for _, case in ipairs({ { 'power.lut', 'moteur' }, { 'tyres.ini', nil } }) do
    local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
    if case[1] == 'tyres.ini' then
      -- courbes de température des pneus vidées (PERFORMANCE_CURVE pointant vers des fichiers vides)
      local emptied = 0
      for name in pairs(h.files) do
        if name:lower():match('^tcurve.*%.lut$') then
          h.files[name] = ''
          emptied = emptied + 1
        end
      end
      T.ok(emptied >= 3, emptied .. ' courbes de pneus vidées (une par composé)')
    else
      h.files[case[1]] = ''
    end
    Fake.install(h)
    assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
    local app = rawget(_G, 'SETUPLAB').app
    for _ = 1, 40000 do
      h.sim.time = h.sim.time + 1000 / 60
      script.SETUPLAB__UPDATE(1 / 60)
      script.SETUPLAB__MAIN(1 / 60)
      if app.discoveryState ~= 'running' and app.discoveryState ~= 'idle' then break end
    end
    T.eq(app.discoveryState, 'done', case[1] .. ' : ' .. tostring(app.discoveryError))
    local blocker = app.qualiBlocker()
    if case[2] == nil then
      -- repli : courbe illisible, fenêtre de température inconnue (affichée telle quelle, pas de garde inventé)
      local CarModel = require('src/car_model')
      local c = app.discovery.carBase.compounds[1]
      T.eq(c.front.perf, nil)
      T.eq((CarModel.tyreWindow(c.front)), nil, 'fenêtre inconnue')
    end
    if case[2] then
      T.ok(blocker, case[1] .. ' vide : calcul refusé')
      T.contains(blocker .. ' ' .. table.concat(app.discovery.carBaseMissing or {}, ', '), 'torque')
    end
    T.eq(app.perf.errors, 0, case[1] .. ' : erreurs')
    T.eq(h.writeCalls, 0)
    PY.note('F07 ' .. case[1], blocker and ('calcul refusé : ' .. blocker) or 'repli, calcul possible')
  end
end

return tests
