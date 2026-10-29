-- Tests du module src/datasource (lecture -> tables pures, D5/D11).
local T = require('t')
local Util = require('src/util')
local Config = require('src/config')
local Datasource = require('src/datasource')
local Fake = require('fakehost')

local K = Config.K
local SYNC = Util.syncContext()
local tests = {}

local function host(carId, trackId, opts)
  opts = opts or {}
  opts.car = require('fixtures/cars/' .. carId)
  opts.track = require('fixtures/tracks/' .. trackId)
  return Fake.new(opts)
end

local function compact(value)
  return (value:gsub('%s*,%s*', ','))
end

tests['D01 voiture GT3 ouverte (Huracán) : INI, LUT, rapports'] = function()
  local h = host('lamborghini_huracan_gt3_evo2', 'spa')
  local car = Datasource.readCar(h, 0, SYNC)
  T.eq(car.id, 'lamborghini_huracan_gt3_evo2')
  T.ok(car.safeId)
  T.ok(type(car.name) == 'string' and #car.name > 0)
  for _, name in ipairs({ 'car.ini', 'engine.ini', 'drivetrain.ini', 'tyres.ini', 'aero.ini', 'brakes.ini',
    'suspensions.ini', 'setup.ini' }) do
    T.eq(car.iniStatus[name], 'ok', name)
  end
  T.eq(Util.iniNumber(car.ini['car.ini'], 'BASIC', 'TOTALMASS', 0), 1334)
  T.eq(compact(Util.iniGet(car.ini['car.ini'], 'BASIC', 'INERTIA')), '1.80,1.00,3.79')
  T.eq(Util.iniGet(car.ini['drivetrain.ini'], 'TRACTION', 'TYPE'), 'RWD')
  T.eq(Util.iniNumber(car.ini['suspensions.ini'], 'BASIC', 'WHEELBASE', 0), 2.62)
  T.eq(Util.iniNumber(car.ini['tyres.ini'], 'FRONT', 'DY_REF', 0), 1.58)
  T.eq(car.lutStatus['power.lut'], 'ok')
  T.ok(car.luts['power.lut'].n >= 20)
  T.ok(car.luts['slicksgt3s_front.lut'] ~= nil, 'courbe d\'usure du composé tendre')
  T.ok(car.luts['tcurve_slicksgt3s.lut'] ~= nil, 'courbe de température')
  T.eq(car.ratioStatus['final.rto'], 'ok')
  T.ok(#car.ratios['final.rto'] >= 10)
  T.eq(#car.ratioOrder, 7, '6 rapports + couple final')
  T.eq(car.rawPathForm, 'absolu')
  T.eq(car.rawProbe.absolu, 'ok')
  T.ok(#car.rawSample > 0, 'échantillon du format brut CSP')
  T.eq(h.writeCalls, 0)
end

tests['D02 voiture du SDK Kunos (formula_k) et formule ERS (URD)'] = function()
  local k = Datasource.readCar(host('formula_k', 'monza'), 0, SYNC)
  T.eq(k.iniStatus['tyres.ini'], 'ok')
  T.eq(k.iniStatus['aero.ini'], 'ok')
  T.ok(Util.iniGet(k.ini['aero.ini'], 'WING_1', 'LUT_AOA_CL') ~= nil)
  T.ok(k.luts['power.lut'] ~= nil)
  local u = Datasource.readCar(host('urd_px1_aura', 'monza'), 0, SYNC)
  T.eq(u.iniStatus['ers.ini'], 'ok')
  T.eq(u.iniStatus['ctrl_ers_0.ini'], 'ok', 'contrôleurs ERS lus')
  T.ok(u.luts['kers_torque_rwd.lut'] ~= nil)
  T.ok(#u.iniOrder <= K.maxCarIniFiles)
  local d = Datasource.readCar(host('whk_dtm_2026', 'monza'), 0, SYNC)
  T.eq(d.iniStatus['drs.ini'], 'ok')
  T.eq(Util.iniGet(d.ini['drs.ini'], 'WING_4', 'EFFECT'), '0.50')
end

tests['D03 format CSP : listes découpées ou chaîne unique -> même table pure'] = function()
  local a = Datasource.readCar(host('lamborghini_huracan_gt3_evo2', 'spa', { iniMode = 'split' }), 0, SYNC)
  local b = Datasource.readCar(host('lamborghini_huracan_gt3_evo2', 'spa', { iniMode = 'single' }), 0, SYNC)
  local compared = 0
  for name, data in pairs(a.ini) do
    for _, section in ipairs(data.order) do
      for key, value in pairs(data.sections[section]) do
        T.eq(compact(value), compact(Util.iniGet(b.ini[name], section, key)), name .. ' ' .. section .. ' ' .. key)
        compared = compared + 1
      end
    end
  end
  T.ok(compared > 300)
end

tests['D04 data.acd illisible, liste de fichiers absente'] = function()
  local h = host('lamborghini_huracan_gt3_evo2', 'spa', { carDataError = true })
  local car = Datasource.readCar(h, 0, SYNC)
  T.eq(next(car.ini), nil, 'aucun INI')
  for _, name in ipairs(car.iniOrder) do T.ok(car.iniStatus[name]:find('^erreur'), name) end
  T.eq(#car.lutOrder, 0)
  local h2 = host('lamborghini_huracan_gt3_evo2', 'spa', { missing = { 'ac.getCarDataFiles' } })
  local car2 = Datasource.readCar(h2, 0, SYNC)
  T.eq(car2.dataFiles, nil)
  T.eq(car2.dataFilesReason, 'absent')
  T.eq(#car2.iniOrder, #Datasource.CAR_INI_FILES, 'liste de base utilisée')
  T.eq(car2.iniStatus['ers.ini'], 'vide')
  T.eq(car2.iniStatus['car.ini'], 'ok')
  -- Constat n° 4 : en cas d'échec, CSP renvoie une liste vide (SDK 3237) : liste de base, pas zéro fichier.
  local hEmpty = host('lamborghini_huracan_gt3_evo2', 'spa')
  hEmpty.ac.getCarDataFiles = function() return {} end
  local empty = Datasource.readCar(hEmpty, 0, SYNC)
  T.eq(empty.dataFiles, nil)
  T.ok(empty.dataFilesReason:find('liste vide'))
  T.eq(#empty.iniOrder, #Datasource.CAR_INI_FILES)
  T.eq(empty.iniStatus['car.ini'], 'ok')
  local h3 = host('lamborghini_huracan_gt3_evo2', 'spa', { missing = { 'ac.getCarID' } })
  local car3 = Datasource.readCar(h3, 0, SYNC)
  T.no(car3.safeId)
  T.eq(car3.ratioStatus['final.rto'], 'échec : nom refusé', 'chemin brut refusé sans identifiant sûr')
end

tests['D05 lecture brute : forme de chemin, repli texte des LUT'] = function()
  local rel = Datasource.readCar(host('lamborghini_huracan_gt3_evo2', 'spa', { rawForm = 'relatif' }), 0, SYNC)
  T.eq(rel.rawPathForm, 'relatif')
  T.eq(rel.rawProbe.absolu, 'vide')
  T.eq(rel.ratioStatus['final.rto'], 'ok')
  local none = Datasource.readCar(host('lamborghini_huracan_gt3_evo2', 'spa', { rawForm = 'aucun' }), 0, SYNC)
  T.eq(none.rawPathForm, nil)
  for _, name in ipairs(none.ratioOrder) do T.eq(none.ratioStatus[name], 'échec : illisible', name) end
  T.eq(none.lutStatus['power.lut'], 'ok', 'LUT via ac.DataLUT11 malgré tout')
  local fallback = Datasource.readCar(host('lamborghini_huracan_gt3_evo2', 'spa', { lutError = true }), 0, SYNC)
  T.eq(fallback.lutStatus['power.lut'], 'ok (texte brut)')
  T.ok(fallback.luts['power.lut'].n >= 20)
  local nothing = Datasource.readCar(host('lamborghini_huracan_gt3_evo2', 'spa', { lutError = true, rawForm = 'aucun' }),
    0, SYNC)
  T.ok(nothing.lutStatus['power.lut']:find('^échec'))
  T.eq(nothing.luts['power.lut'], nil)
end

tests['D06 normalisation bornée et types inattendus'] = function()
  local sections = {}
  for i = 1, 2000 do sections['S' .. i] = { K = { '1' } } end
  local big = Datasource.normalizeSections(sections)
  T.eq(#big.order, K.maxIniSections)
  T.ok(big.truncated)
  local keys = {}
  for i = 1, 1000 do keys['K' .. i] = { tostring(i) } end
  local wide = Datasource.normalizeSections({ A = keys })
  local count = 0
  for _ in pairs(wide.sections.A) do count = count + 1 end
  T.eq(count, K.maxIniKeys)
  local weird = Datasource.normalizeSections({
    A = { N = 5, B = true, NAN = 0 / 0, T = { 'a', 3, {}, 0 / 0 }, F = function() end, [1] = { 'x' },
      LONG = { string.rep('v', 5000) } },
    [5] = {}, B = 'pas une table',
  })
  T.eq(weird.sections.A.N, '5')
  T.eq(weird.sections.A.B, '1')
  T.eq(weird.sections.A.NAN, nil)
  T.eq(weird.sections.A.T, 'a,3')
  T.eq(weird.sections.A.F, nil)
  T.eq(#weird.sections.A.LONG, K.maxValueChars)
  T.eq(weird.sections.B, nil)
  T.eq(#weird.order, 1)
  T.eq(#Datasource.normalizeSections(nil).order, 0)
  T.eq(#Datasource.normalizeSections('x').order, 0)
end

tests['D07 état physique et télémétrie (structures strictes, tableau cdata)'] = function()
  local h = host('lamborghini_huracan_gt3_evo2', 'spa')
  local st = Datasource.readCarState(h, 0)
  T.ok(st.ok)
  T.eq(st.values.mass, 1334)
  -- l'hôte simulé applique les crans à l'état du jeu (FRONT_BIAS 66 %, pression 31 psi, rapports d'usine)
  T.eq(st.values.brakeBias, 0.66)
  T.eq(st.wheels[1].camber, -3.1)
  T.eq(st.wheels[4].tyreStaticPressure, 31)
  T.eq(st.gearRatioCount, 8, 'longueur via __len du tableau cdata')
  T.eq(st.gearRatios[3], 2.6428)
  -- Constat n° 12 : un rapport illisible ne décale pas les suivants.
  local holed = host('lamborghini_huracan_gt3_evo2', 'spa')
  rawset(holed.physicsState, 'gearRatios', Fake.array({ -3.8, 0, 0 / 0, 2.0, 1.56 }))
  local hs = Datasource.readCarState(holed, 0)
  T.eq(hs.gearRatioCount, 5)
  T.eq(hs.gearRatios[3], nil)
  T.eq(hs.gearRatios[4], 2.0, 'rapport à sa place')
  T.eq(hs.gearRatios[5], 1.56)
  T.eq(st.finalRatio, 3.9166)
  T.eq(st.rideHeight[2], 0.075)
  T.eq(st.flags.drsPresent, false)
  rawset(h.car, 'brakeBias', nil)
  T.eq(Datasource.readCarState(h, 0).values.brakeBias, nil, 'champ absent de cette version de CSP')
  local tel = Datasource.telemetryCheck(h, 0)
  T.eq(#tel.missing, 0)
  T.eq(tel.ok, #tel.fields)
  rawset(h.car, 'speedMs', nil)
  T.eq(Datasource.telemetryCheck(h, 0).missing[1], 'speedMs')
  local broken = host('lamborghini_huracan_gt3_evo2', 'spa', { throwing = { 'ac.getCar', 'ac.getCarPhysics' } })
  T.no(Datasource.readCarState(broken, 0).ok)
  T.ok(Datasource.telemetryCheck(broken, 0).reason)
end

tests['D08 setup : crans, contenu, comparaison d\'encodage'] = function()
  local h = host('lamborghini_huracan_gt3_evo2', 'spa')
  local s = Datasource.readSetup(h, SYNC)
  T.ok(#s.spinners > 30, #s.spinners .. ' crans')
  T.ok(s.file ~= nil)
  T.ok(s.comparison.consistent)
  T.eq(s.comparison.matched, #s.spinners)
  -- le composé ([TYRES]) et les niveaux d'aide ([ABS], [TRACTION_CONTROL]) sont des sections du fichier sans
  -- cran CSP, comme dans les setups d'AC
  T.eq(table.concat(s.comparison.fileOnly, ','), 'TYRES,ABS,TRACTION_CONTROL')
  T.eq(s.editable, true)
  T.eq(s.legal, 'legal')
  local gear, camber
  for _, sp in ipairs(s.spinners) do
    if sp.name == 'FINAL_GEAR_RATIO' then gear = sp end
    if sp.name == 'CAMBER_LF' then camber = sp end
    for _, key in ipairs({ 'min', 'max', 'step', 'value' }) do
      T.eq(math.floor(sp[key]), sp[key], 'cran entier (SDK 4145) : ' .. sp.name .. '.' .. key)
    end
  end
  T.ok(gear and #gear.items >= 10, 'items du couple final')
  T.eq(camber.displayMultiplier, 0.1, 'carrossage en dixièmes de degré')
  -- Constat n° 3 : noms de boîte décalés entre crans et fichier -> réglages modifiables non vérifiés.
  local g = Datasource.readSetup(host('lamborghini_huracan_gt3_evo2', 'spa', { gearNames = 'internal' }), SYNC)
  T.no(g.comparison.consistent, 'absents modifiables : cohérence non établie')
  T.eq(#g.comparison.mismatched, 0)
  T.eq(#g.comparison.missingEditable, 7, '6 rapports + couple final')
  T.ok(#g.comparison.fileOnly >= 7, 'INTERNAL_GEAR_n / FINAL_RATIO côté fichier')
  local hro = host('lamborghini_huracan_gt3_evo2', 'spa', { gearNames = 'internal' })
  for _, sp in ipairs(hro.spinners) do
    if sp.items then sp.readOnly = true end
  end
  T.ok(Datasource.readSetup(hro, SYNC).comparison.consistent, 'absents verrouillés : sans effet sur la cohérence')
  local m = Datasource.readSetup(host('lamborghini_huracan_gt3_evo2', 'spa', { setupMismatch = 'WING_2' }), SYNC)
  T.no(m.comparison.consistent)
  T.eq(m.comparison.mismatched[1].name, 'WING_2')
  local none = Datasource.readSetup(host('lamborghini_huracan_gt3_evo2', 'spa', { missing = { 'ac.getSetupSpinners' } }),
    SYNC)
  T.eq(none.spinnerReason, 'absent')
  T.no(none.comparison.consistent)
  local broken = Datasource.readSetup(host('lamborghini_huracan_gt3_evo2', 'spa',
    { throwing = { 'ac.stringifyCurrentSetup', 'ac.getCarSetupState', 'ac.getSetupTabs' } }), SYNC)
  T.ok(broken.textReason:find('erreur simulée'))
  T.eq(broken.file, nil)
  T.eq(#broken.comparison.missing, #broken.spinners)
  T.eq(Datasource.copySpinner({ name = 'X' }), nil, 'cran incomplet ignoré')
  T.eq(Datasource.copySpinner(Fake.strict({ name = 'X', min = 0, max = 1, value = 0 }, 's')).label, 'X')
end

tests['D09 circuit : échantillonnage de la ligne IA (Spa, Monza, Red Bull Ring)'] = function()
  for _, case in ipairs({ { 'spa', 50, 6000 }, { 'monza', 0, 5000 }, { 'ks_red_bull_ring-layout_gp', 30, 4000 } }) do
    local h = host('lamborghini_huracan_gt3_evo2', case[1])
    local t = Datasource.sampleTrack(h, 2, SYNC)
    T.ok(t.ok, case[1] .. ' : ' .. tostring(t.reason))
    T.eq(t.n, math.floor(t.lengthSim / 2 + 0.5))
    T.ok(t.lengthSim > case[3])
    T.near(t.lengthModel / t.lengthSim, 1, K.trackLengthTolSim, case[1] .. ' longueur')
    T.ok(t.altitudeMax - t.altitudeMin >= case[2], case[1] .. ' dénivelé')
    T.ok(t.widthMean > 6 and t.widthMean < 30, case[1] .. ' largeur ' .. t.widthMean)
    T.eq(t.failures, 0)
    T.eq(t.sideFailures, 0)
  end
  local coarse = Datasource.sampleTrack(host('lamborghini_huracan_gt3_evo2', 'monza'), 5, SYNC)
  T.eq(coarse.n, math.floor(coarse.lengthSim / 5 + 0.5))
  -- Constat n° 11 : circuit ouvert (A-B) échantillonné jusqu'à l'arrivée, polyligne non fermée ; dernier point juste
  -- avant p = 1 (relecture du 29/10/2026 : p = 1 pourrait revenir au départ), à quelques millimètres de l'arrivée.
  local hOpen = host('lamborghini_huracan_gt3_evo2', 'ks_red_bull_ring-layout_gp')
  hOpen.sim.isTrackOpen = true
  local open = Datasource.sampleTrack(hOpen, 5, SYNC)
  local x1, _, z1 = Fake.sampleTrack(hOpen.track, 1)
  T.near(open.x[open.n], x1, 0.05, 'dernier point = arrivée (p = 1 − 1e-6)')
  T.near(open.z[open.n], z1, 0.05)
  T.near(open.lengthModel / open.lengthSim, 1, K.trackLengthTolSim, 'longueur d\'un tracé ouvert')
end

tests['D10 circuit : cas dégradés'] = function()
  T.eq(Datasource.sampleTrack(host('formula_k', 'spa', { noSpline = true }), 2, SYNC).reason, 'aucune ligne IA (fast_lane)')
  T.ok(Datasource.sampleTrack(host('formula_k', 'spa', { trackLength = 150 }), 2, SYNC).reason:find('hors plage'))
  T.ok(Datasource.sampleTrack(host('formula_k', 'spa', { trackLength = 80000 }), 2, SYNC).reason:find('hors plage'))
  local h = host('formula_k', 'monza', { throwing = { 'ac.trackProgressToWorldCoordinate' } })
  local t = Datasource.sampleTrack(h, 2, SYNC)
  T.no(t.ok)
  T.ok(t.reason:find('interrompu'))
  local sides = Datasource.sampleTrack(host('formula_k', 'monza', { throwing = { 'ac.getTrackAISplineSides' } }), 2, SYNC)
  T.ok(sides.ok)
  T.eq(sides.sideFailures, sides.n)
  T.eq(sides.widthMean, nil)
  local partial = host('formula_k', 'monza')
  local original = partial.ac.trackProgressToWorldCoordinate
  partial.ac.trackProgressToWorldCoordinate = function(p)
    if p > 0.5 and p < 0.503 then return { x = 0 / 0, y = 0, z = 0 } end
    return original(p)
  end
  local pt = Datasource.sampleTrack(partial, 2, SYNC)
  T.ok(pt.ok, 'moins de 1 % de points invalides tolérés')
  T.ok(pt.failures > 0)
  T.eq(Datasource.sampleTrack(host('formula_k', 'monza', { missing = { 'ac.getSim' } }), 2, SYNC).lengthSim, nil)
end

tests['D11 longueur déclarée (ui_track.json)'] = function()
  local cases = {
    { '"length": "7004"', 7004 }, { '"length": "7.004 km"', 7004 }, { '"length":"4,3 km"', 4300 },
    { '"length": "5,793"', 5793 }, { '"length": "5,793 m"', 5793 }, { '"length": "3.4 miles"', 3.4 * 1609.344 },
    { '"length": 4326', 4326 }, { '"length": "20.832km"', 20832 }, { '"length": ""', nil }, { '"length": "abc"', nil },
    { '"length": "1e9"', nil }, { 'pas de json', nil }, { '"length": "50 m"', nil },
  }
  for _, c in ipairs(cases) do
    local value = Datasource.parseDeclaredLength(c[1])
    if c[2] == nil then
      T.eq(value, nil, c[1])
    else
      T.near(value, c[2], 1e-6, c[1])
    end
  end
  T.eq(Datasource.parseDeclaredLength(nil), nil)
end

tests['D12 fichiers du circuit et identifiants'] = function()
  local f = Datasource.readTrackFiles(host('formula_k', 'spa'), SYNC)
  T.eq(f.id, 'spa')
  T.eq(f.fullId, 'spa')
  T.eq(f.iniStatus['surfaces.ini'], 'ok')
  T.eq(f.iniStatus['drs_zones.ini'], 'ok')
  T.eq(f.declared, 7004)
  local r = Datasource.readTrackFiles(host('formula_k', 'ks_red_bull_ring-layout_gp'), SYNC)
  T.eq(r.fullId, 'ks_red_bull_ring/layout_gp')
  T.eq(r.layout, 'layout_gp')
  T.eq(r.declared, 4326)
  local noIo = Datasource.readTrackFiles(host('formula_k', 'spa', { missing = { 'io.load' } }), SYNC)
  T.eq(noIo.declaredReason, 'io.load absent')
  local noTrack = Datasource.readTrackFiles(host('formula_k', 'spa', { throwing = { 'ac.INIConfig.trackData' } }), SYNC)
  T.ok(noTrack.iniStatus['surfaces.ini']:find('^erreur'))
end

tests['D13 session, conditions et contexte'] = function()
  local h = host('formula_k', 'spa')
  local s = Datasource.readSession(h)
  T.ok(s.ok)
  T.eq(s.values.ambientTemperature, 24)
  T.eq(s.session.durationMinutes, 15)
  T.eq(s.assists.tyresWear, 1)
  T.no(s.wet)
  local c = Datasource.readContext(h)
  T.ok(c.ok)
  T.eq(c.key, 'formula_k|spa')
  T.no(c.online)
  T.no(c.replay)
  h.sim.rainWetness = 0.3
  T.ok(Datasource.readSession(h).wet)
  T.ok(Datasource.readContext(h).wet)
  h.sim.isOnlineRace = true
  T.ok(Datasource.readContext(h).online)
  h.sim.isOnlineRace = false
  h.sim.isAltOnlineRace = true
  T.ok(Datasource.readContext(h).online, 'alt-online aussi inerte')
  h.sim.isAltOnlineRace = false
  h.sim.isReplayOnlyMode = true
  T.ok(Datasource.readContext(h).replay)
  local broken = host('formula_k', 'spa', { throwing = { 'ac.getSim' } })
  T.no(Datasource.readContext(broken).ok)
  T.no(Datasource.readSession(broken).ok)
  -- Constat n° 8 : drapeau illisible = inerte ; drapeau numérique (uint8_t) accepté.
  local unreadable = host('formula_k', 'spa')
  rawset(unreadable.sim, 'isAltOnlineRace', nil)
  local cu = Datasource.readContext(unreadable)
  T.no(cu.ok)
  T.eq(cu.reason, 'drapeau illisible : isAltOnlineRace')
  local numeric = host('formula_k', 'spa')
  rawset(numeric.sim, 'isOnlineRace', 1)
  rawset(numeric.sim, 'isReplayActive', 0)
  local cn = Datasource.readContext(numeric)
  T.ok(cn.ok)
  T.ok(cn.online)
  T.no(cn.replay)
  -- Clé de séance (décision de Vincent du 20/10/2026) : type et numéro de séance seulement ; la piste
  -- qui évolue (températures, adhérence) et la pluie n'en font pas partie ; séance illisible : pas de clé.
  local cond = host('formula_k', 'spa')
  local k0 = Datasource.readContext(cond).conditionsKey
  T.ok(k0)
  cond.sim.ambientTemperature, cond.sim.roadTemperature, cond.sim.roadGrip = 5, 50, 0.9
  T.eq(Datasource.readContext(cond).conditionsKey, k0, 'piste qui évolue : même séance')
  cond.sim.rainWetness = 0.9
  T.eq(Datasource.readContext(cond).conditionsKey, k0, 'pluie : même séance (refus du calcul à part, D16)')
  cond.sim.rainWetness = 0
  cond.sim.raceSessionType = 3
  T.ok(Datasource.readContext(cond).conditionsKey ~= k0, 'type de séance')
  cond.sim.raceSessionType, cond.sim.currentSessionIndex = 2, 1
  T.ok(Datasource.readContext(cond).conditionsKey ~= k0, 'numéro de séance')
  rawset(cond.sim, 'currentSessionIndex', nil)
  T.eq(Datasource.readContext(cond).conditionsKey, nil, 'séance illisible : pas de clé')
  T.eq(Datasource.readContext(cond).key, 'formula_k|spa', 'identité inchangée')
  local anonymous = host('formula_k', 'spa', { missing = { 'ac.getCarID' } })
  local ca = Datasource.readContext(anonymous)
  T.no(ca.ok)
  T.eq(ca.reason, 'voiture ou circuit non identifié')
end

-- Signalé par Vincent : le DRS ne se résume pas à « drs.ini lu ». AC lit drs.ini (sections WING_n) et
-- en déduit drsPresent ; l'ERS peut venir de ers.ini ou de l'ancien kers.ini.
tests['D15 DRS et ERS : définition AC, états en direct, ailes'] = function()
  local dtm = Datasource.readCar(host('whk_dtm_2026', 'monza'), 0, SYNC)
  T.eq(#dtm.drsInfo.wings, 1)
  local w = dtm.drsInfo.wings[1]
  T.eq(w.index, 4)
  T.eq(w.aeroName, 'DRS', 'aile désignée retrouvée dans aero.ini')
  T.eq(w.keys.EFFECT, '0.50')
  T.eq(w.aeroAngle, 4)
  local hur = Datasource.readCar(host('lamborghini_huracan_gt3_evo2', 'monza'), 0, SYNC)
  T.eq(#hur.drsInfo.wings, 0, 'drs.ini vide : aucune aile mobile')
  T.eq(hur.drsInfo.status, 'vide')
  local urd = Datasource.readCar(host('urd_px1_aura', 'monza'), 0, SYNC)
  T.eq(urd.ersInfo.files[1], 'ers.ini')
  T.eq(urd.ersInfo.maxKjPerLap, 5000)
  T.ok(urd.ersInfo.controllers >= 12, 'ctrl_ers_* et ctrl_ers_front_*')
  T.ok(urd.ersInfo.mguh)
  T.ok(urd.ersInfo.frontMotors)
  T.ok(table.concat(Datasource.CAR_INI_FILES, ' '):find('kers.ini', 1, true), 'ancien format KERS lu aussi')
  local h = host('whk_dtm_2026', 'monza', { drs = true })
  h.car.drsAvailable, h.car.drsActive = true, true
  local st = Datasource.readCarState(h, 0)
  T.eq(st.flags.drsPresent, true)
  T.eq(st.flags.drsAvailable, true)
  T.eq(st.flags.drsActive, true)
  T.eq(#st.wings, 3, 'ailes en direct (cdata indexé à partir de 0)')
  T.near(st.wings[2].cl, 0.46, 1e-6)
  T.near(st.wings[3].groundHeight, 0.9, 1e-6)
  T.eq(st.wingHeightUnit, nil, 'hauteurs en mètres')
  -- CSP 0.3.1-preview2 : hauteurs au sol en millimètres, ramenées en mètres
  local w = h.physicsState.wings.v
  for i = 0, 2 do w[i].groundHeight = w[i].groundHeight * 1000 end
  local mm = Datasource.readCarState(h, 0)
  T.eq(mm.wingHeightUnit, 'mm')
  T.near(mm.wings[3].groundHeight, 0.9, 1e-4)
  T.near(mm.wings[2].groundHeight, 0.06, 1e-4)
end

tests['D14 sonde raycast'] = function()
  local r = Datasource.probeRaycast(host('formula_k', 'spa'), 0)
  T.ok(r.ok)
  T.near(r.distance, K.raycastHeight + 0.3, 1e-6)
  T.eq(Datasource.probeRaycast(host('formula_k', 'spa', { missing = { 'physics.raycastTrack' } }), 0).reason, 'absent')
  T.eq(Datasource.probeRaycast(host('formula_k', 'spa', { missing = { 'vec3' } }), 0).reason, 'vec3 indisponible')
  T.eq(Datasource.probeRaycast(host('formula_k', 'spa', { throwing = { 'ac.getCar' } }), 0).reason,
    'position de la voiture illisible')
end

tests['D16 empreinte des fichiers de la voiture (D9) : stable, sensible au contenu'] = function()
  local function print(mutate)
    local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
    if mutate then mutate(h) end
    return Datasource.fingerprint(Datasource.readCar(h, 0, SYNC))
  end
  local a, b = print(), print()
  T.eq(a, b, 'mêmes fichiers, même empreinte')
  T.ok(a > 0 and a < 2147483647)
  local changed = print(function(h) h.files['tyres.ini'] = h.files['tyres.ini']:gsub('PRESSURE_IDEAL=26', 'PRESSURE_IDEAL=27', 1) end)
  T.ok(changed ~= a, 'une valeur changée change l\'empreinte')
  local dropped = print(function(h) h.files['ers.ini'] = nil; h.files['aero.ini'] = h.files['aero.ini'] .. '\n[EXTRA]\nX=1\n' end)
  T.ok(dropped ~= a)
end

return tests
