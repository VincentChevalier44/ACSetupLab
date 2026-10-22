-- Pluie (D16 amendé le 21/10/2026, décision de Vincent : « il faut que ce soit compatible avec la pluie et
-- qu'on puisse calculer les setups avec la pluie ») : état de la piste avec hystérésis, tours rangés par
-- état de piste (calibration et validation jamais mélangées), modèle d'adhérence mouillée, choix du
-- composé, aides au pilotage, statut de chaque réglage.
local T = require('t')
local Util = require('src/util')
local Config = require('src/config')
local CarModel = require('src/car_model')
local Sim = require('src/laptime_sim')
local Fake = require('fakehost')

local tests = {}

local TRUTH = { mu = 0.97, power = 0.99, drag = 1.01, lift = 1.0, brake = 1.0 }

local function boot(carId, trackId)
  local h = Fake.new({ car = require('fixtures/cars/' .. (carId or 'lamborghini_huracan_gt3_evo2')),
    track = require('fixtures/tracks/' .. (trackId or 'monza')) })
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  app.utcOffset = function() return 7200 end
  h.texts = {}
  local text, wrapped, colored = h.ui.text, h.ui.textWrapped, h.ui.textColored
  h.ui.text = function(s) h.texts[#h.texts + 1] = s; return text(s) end
  h.ui.textWrapped = function(s) h.texts[#h.texts + 1] = s; return wrapped(s) end
  h.ui.textColored = function(s, c) h.texts[#h.texts + 1] = s; return colored(s, c) end
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

local function waitFor(h, predicate, profile, maxFrames)
  for i = 1, maxFrames or 60000 do
    frames(h, 1, profile)
    if predicate() then return i end
  end
  return nil
end

local function refresh(h, app)
  app.nextContextAt = 0
  frames(h, 1)
end

local function shown(h, fragment)
  for _, text in ipairs(h.texts) do
    if text:find(fragment, 1, true) then return text end
  end
  return nil
end

-- Pluie sur la piste : humidité, eau (0 à 1) et eau sous les pneus (m).
local function rain(h, wetness, water, thickness, intensity)
  h.sim.rainWetness, h.sim.rainWater, h.sim.rainIntensity = wetness, water, intensity or 0
  for w = 0, 3 do h.car.wheels[w].waterThickness = thickness or 0 end
end

-- Profil de vitesse « vrai » du setup de la découverte (pneus à température, carburant du réservoir).
local function drivenProfile(app, conditions)
  local d = app.discovery
  local setup = app.physicalSetup(d, nil, nil)
  setup.fuel = 30
  local c = { airTemp = d.conditions.airTemp, roadGrip = d.conditions.roadGrip, surfaceGrip = d.conditions.surfaceGrip,
    factors = TRUTH }
  for key, value in pairs(conditions or {}) do c[key] = value end
  local eff = assert(CarModel.configure(d.carBase, setup, c))
  local result, buf = Sim.run(d.trackModel, eff, nil)
  local profile = { p = {}, v = {}, time = result.time }
  for k = 1, d.trackModel.n do profile.p[k], profile.v[k] = d.trackModel.p[k], buf.v[k] end
  profile.p[#profile.p + 1], profile.v[#profile.v + 1] = 1, buf.v[1]
  return profile
end

tests['PL01 état de la piste : « pluie » dès 0,15, « sec » sous 0,05 seulement (hystérésis), aucune redécouverte'] = function()
  local h, app = boot()
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  T.eq(app.wet.state, 'sec')
  local steps = { { 0.149, 'sec' }, { 0.151, 'pluie' }, { 0.149, 'pluie' }, { 0.06, 'pluie' }, { 0.151, 'pluie' },
    { 0.049, 'sec' }, { 0.06, 'sec' }, { 0.149, 'sec' } }
  for i, step in ipairs(steps) do
    rain(h, step[1], 0)
    refresh(h, app)
    T.eq(app.wet.state, step[2], 'relecture ' .. i .. ' à ' .. step[1])
    T.eq(app.discoveryState, 'done', 'aucune redécouverte (relecture ' .. i .. ')')
  end
  -- l'eau ou l'intensité de la pluie comptent aussi
  rain(h, 0, 0.2)
  refresh(h, app)
  T.eq(app.wet.state, 'pluie', 'eau sur la piste')
  T.eq(app.perf.errors, 0)
end

tests['PL02 tours rangés par état de piste : calibration pluie sur les seuls tours mouillés, eau mesurée, fichier « Pluie »'] = function()
  local h, app = boot()
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  local d = app.discovery
  local sig = d.signature
  local profile = drivenProfile(app)
  local before = app.recorder.finished
  T.ok(waitFor(h, function() return app.recorder.finished >= before + 2 end, profile), 'tours secs')
  T.ok(waitFor(h, function() return app.calibration and app.calibration.state ~= 'running' end, profile))
  local dry = app.recorder.laps.best[sig]
  T.ok(dry and dry.bucket == 'sec', 'meilleur tour sec')
  T.ok(app.calibrations[d.compoundIndex] and app.calibrations[d.compoundIndex].bucket == 'sec', 'calibration sèche')
  -- la pluie arrive : 1 mm d'eau sous les pneus
  rain(h, 0.9, 0.5, 0.001)
  refresh(h, app)
  T.eq(app.wet.state, 'pluie')
  before = app.recorder.finished
  T.ok(waitFor(h, function() return app.recorder.finished >= before + 2 end, profile), 'tours mouillés')
  local wet = app.recorder.laps.best[sig .. '#pluie']
  T.ok(wet and wet.bucket == 'pluie', 'meilleur tour mouillé rangé à part')
  T.ok(wet.waterMm > 0.9 and wet.waterMm <= 1.0 + 1e-9, 'eau mesurée sous les pneus (mm) : ' .. tostring(wet.waterMm))
  T.eq(app.recorder.laps.best[sig], dry, 'le meilleur tour sec reste le tour sec')
  T.ok(waitFor(h, function()
    local c = app.calibrations[d.compoundIndex .. '#pluie']
    return c and c.state ~= 'running'
  end, profile), 'calibration pluie')
  local cw = app.calibrations[d.compoundIndex .. '#pluie']
  T.eq(cw.bucket, 'pluie')
  T.ok(cw.result and #cw.result.runs >= 1, tostring(cw.error))
  for _, run in ipairs(cw.result.runs) do
    T.eq(run.conditions and run.conditions.bucket or 'pluie', 'pluie', 'aucun tour sec dans la calibration pluie')
  end
  T.ok(app.calibrations[d.compoundIndex].result, 'la calibration sèche est intacte')
  -- calcul sur piste mouillée : état figé au lancement, fichier « Pluie », setup proposé rangé « pluie »
  app.settings.optBudgetEvalsQ = 60
  h.click = 'Calculer le setup tour rapide'
  T.ok(waitFor(h, function() return app.quali and app.quali.state ~= 'running' end))
  T.eq(app.quali.state, 'done', tostring(app.quali.error))
  T.eq(app.quali.conditions.bucket, 'pluie')
  T.near(app.quali.conditions.waterMm, 1.0, 1e-6, 'eau mesurée transmise au calcul')
  h.click = 'Enregistrer le setup tour rapide'
  frames(h, 1)
  T.ok(app.quali.saved and app.quali.saved.ok, tostring(app.ui.message))
  T.ok(app.quali.saved.name:find('^SetupLab_Qualif_Pluie_'), app.quali.saved.name)
  T.eq(app.proposalBuckets.quali, 'pluie')
  -- piste qui sèche : résultat signalé « calculé ailleurs »
  rain(h, 0, 0, 0)
  refresh(h, app)
  refresh(h, app)
  T.eq(app.wet.state, 'sec')
  T.contains(app.quali.stale or '', 'mouillée -> sèche')
  T.eq(app.perf.errors, 0)
end

-- Modèle mouillé (H25 à H28) sur la DTM (pneus pluie et intermédiaires avec TYPE_HINT et rainures) : usage
-- et classe de chaque composé, film d'eau, aquaplanage, pneus plus froids.
local function dtmBase()
  local Util = require('src/util')
  local Datasource = require('src/datasource')
  local h = Fake.new({ car = require('fixtures/cars/whk_dtm_2026'), track = require('fixtures/tracks/monza') })
  local car = Datasource.readCar(h, 0, Util.syncContext())
  return assert(CarModel.build(car, nil)), h
end

local function byUse(base, use)
  for i, c in ipairs(base.compounds) do
    if c.use == use then return c, i end
  end
  return nil
end

tests['PL03 modèle mouillé : usage des composés, film d\'eau, aquaplanage, température (H25 à H28)'] = function()
  local base = dtmBase()
  local slick, inter, wet = byUse(base, 'sec'), byUse(base, 'intermédiaire'), byUse(base, 'pluie')
  T.ok(slick and inter and wet, 'slick, intermédiaire et pluie lus dans tyres.ini')
  T.eq(slick.front.waterClass, 'slick')
  T.eq(inter.front.waterClass, 'treaded')
  T.eq(wet.front.waterClass, 'rain')
  T.eq(slick.front.treadMm, 0)
  T.ok(wet.front.treadMm > inter.front.treadMm and inter.front.treadMm > 0, 'rainures : pluie > intermédiaire > slick')
  T.no(wet.front.treadAssumed, 'TREAD_DEPTH et TREAD_COVER lus')
  T.ok(CarModel.isWetCompound(wet) and CarModel.isWetCompound(inter) and not CarModel.isWetCompound(slick))
  -- un pneu routier à rainures (STREET) reste un pneu sec ; sans TYPE_HINT ni rainures : supposées (H28)
  T.eq(CarModel.compoundUse({ name = 'Street', front = { typeHint = 'STREET' } }), 'sec')
  local guessed = CarModel.waterSpec({ typeHint = '' }, 'pluie')
  T.ok(guessed.treadAssumed and guessed.treadMm > 0 and guessed.waterClass == 'rain')
  -- film d'eau (H25) : le slick perd le plus
  T.eq(CarModel.wetSurfaceFactor(slick.front, 0), 1)
  T.ok(CarModel.wetSurfaceFactor(slick.front, 1) < CarModel.wetSurfaceFactor(inter.front, 1))
  T.ok(CarModel.wetSurfaceFactor(slick.front, 1) < CarModel.wetSurfaceFactor(slick.front, 0.5))
  -- aquaplanage (H26) : rien sous la capacité des rainures ; en v² au-delà ; plancher
  T.eq(CarModel.aquaplaneFactor(wet.front, wet.front.treadMm * 0.9, 80), 1)
  local a30, a60 = CarModel.aquaplaneFactor(slick.front, 2, 30), CarModel.aquaplaneFactor(slick.front, 2, 60)
  T.ok(a60 < a30 and a30 < 1, 'plus vite, moins d\'adhérence')
  T.ok(CarModel.aquaplaneFactor(slick.front, 2, 60) < CarModel.aquaplaneFactor(inter.front, 2, 60))
  T.eq(CarModel.aquaplaneFactor(slick.front, 100, 100), Config.K.aquaFloor)
  T.near(CarModel.waterDepth({ water = 0.5 }), 0.5 * Config.K.wetWaterDepthMax, 1e-12, 'eau supposée sans mesure')
  T.near(CarModel.waterDepth({ water = 0.5, waterMm = 0.7 }), 0.7, 1e-12, 'eau mesurée d\'abord')
  -- température (H27) : plus froid sur le mouillé, jamais au-dessus du plateau
  local dry = CarModel.runningTemp(slick.front, { roadTemp = 15 })
  T.eq(dry, CarModel.operatingTemp(slick.front))
  T.ok(CarModel.runningTemp(slick.front, { roadTemp = 15, wetness = 1 }) < dry)
  T.ok(CarModel.runningTemp(wet.front, { roadTemp = 15, wetness = 1 }) <= CarModel.operatingTemp(wet.front) + 1e-9)
end

-- Choix du composé (D18) selon l'état de la piste, sur la DTM à Monza : sec -> slick ; humide sans eau
-- stagnante -> intermédiaire ; beaucoup d'eau -> pluie.
local function chooseOn(conditions)
  local Util = require('src/util')
  local Datasource = require('src/datasource')
  local TrackModel = require('src/track_model')
  local Space = require('src/setup_space')
  local Optimizer = require('src/optimizer')
  local S = Util.syncContext()
  local h = Fake.new({ car = require('fixtures/cars/whk_dtm_2026'), track = require('fixtures/tracks/monza') })
  local car = Datasource.readCar(h, 0, S)
  local setup = Datasource.readSetup(h, S)
  local raw = Datasource.sampleTrack(h, 1, S)
  Datasource.probeBank(h, raw, S)
  local files = Datasource.readTrackFiles(h, S)
  local track = assert(TrackModel.build(raw, files, 2))
  local base = CarModel.build(car, nil)
  local space = Space.build({ setupIni = car.ini['setup.ini'], spinners = setup.spinners, ratios = car.ratios })
  Space.attach(space, base)
  local c = { airTemp = 16, roadTemp = 15, roadGrip = 1, surfaceGrip = track.surfaceGrip }
  for key, value in pairs(conditions) do c[key] = value end
  local p = Optimizer.prepareQuali({ base = base, space = space, track = track, settings = Config.defaults(), budget = 40,
    conditions = c, compound = CarModel.compoundSlot(base, 1) })
  local r = assert(Optimizer.runQuali(p, S, Optimizer.newState({ budget = 40 })))
  return r, base
end

tests['PL04 composé choisi selon la piste : sec slick, humide intermédiaire, beaucoup d\'eau pluie'] = function()
  local dry = chooseOn({ bucket = 'sec', wetness = 0, water = 0 })
  T.eq(dry.compound.use or 'sec', 'sec', 'sec : ' .. tostring(dry.compound.name))
  local damp = chooseOn({ bucket = 'pluie', wetness = 1, water = 0 })
  local names = {}
  for _, e in ipairs(damp.compound.comparison) do names[#names + 1] = tostring(e.short) .. '=' .. Util.fmt(e.J, 2) end
  PY.note('PL04', 'humide : ' .. table.concat(names, ' ; '))
  T.eq(damp.compound.use, 'intermédiaire', 'humide : ' .. tostring(damp.compound.name) .. ' (' .. table.concat(names, ' ; ') .. ')')
  local soaked = chooseOn({ bucket = 'pluie', wetness = 1, water = 1 })
  names = {}
  for _, e in ipairs(soaked.compound.comparison) do names[#names + 1] = tostring(e.short) .. '=' .. Util.fmt(e.J, 2) end
  PY.note('PL04', 'trempée : ' .. table.concat(names, ' ; '))
  T.eq(soaked.compound.use, 'pluie', 'beaucoup d\'eau : ' .. tostring(soaked.compound.name) .. ' (' .. table.concat(names, ' ; ') .. ')')
  T.ok(soaked.timeProposed > dry.timeProposed + 3, 'tour bien plus lent sous la pluie')
  -- piste mouillée : pneu pluie imposé accepté
  T.eq(#soaked.compound.comparison, #dry.compound.comparison + 2, 'pluie et intermédiaire comparés sous la pluie seulement')
end

-- Aides au pilotage sous la pluie (décision de Vincent : « plus de TC, plus d'ABS ») : sens lu dans la table de
-- chaque voiture (Kunos : niveau 1 le plus strict ; DTM : le dernier), aide coupée, absente, déjà au plus
-- strict, absente du fichier ; écriture facultative (jamais un refus).
tests['PL05 règle des aides : sens par voiture, aide coupée, absente ou hors fichier ; écriture facultative'] = function()
  local Space = require('src/setup_space')
  local Datasource = require('src/datasource')
  local function aidsOf(carId)
    local h = Fake.new({ car = require('fixtures/cars/' .. carId), track = require('fixtures/tracks/monza') })
    return CarModel.build(Datasource.readCar(h, 0, Util.syncContext()), nil).aids
  end
  local hur, dtm = aidsOf('lamborghini_huracan_gt3_evo2'), aidsOf('whk_dtm_2026')
  T.no(hur.tc.stricterUp, 'Huracán (table Kunos) : niveau 1 le plus strict')
  T.ok(dtm.tc.stricterUp, 'DTM : dernier niveau le plus strict')
  T.no(dtm.abs.present, 'DTM : pas d\'ABS')
  local p = Space.aidsPlan(hur, { TRACTION_CONTROL = 4, ABS = 0 }, 2, true)
  T.eq(p.TRACTION_CONTROL.to, 2, 'Huracán : 4 -> 2 (plus strict)')
  T.ok(p.TRACTION_CONTROL.slipTo < p.TRACTION_CONTROL.slipFrom, 'glissement admis plus bas')
  T.eq(p.ABS.to, hur.abs.count - 1, 'ABS coupé : mis au 2e niveau depuis le plus permissif')
  local q = Space.aidsPlan(dtm, { TRACTION_CONTROL = 1 }, 2, true)
  T.eq(q.TRACTION_CONTROL.to, 3, 'DTM : 1 -> 3 (plus strict)')
  T.eq(q.ABS.to, nil)
  T.contains(q.ABS.note, 'absent de cette voiture')
  T.contains(Space.aidsPlan(dtm, { TRACTION_CONTROL = dtm.tc.count }, 2, true).TRACTION_CONTROL.note, 'plus strict')
  T.contains(Space.aidsPlan(dtm, {}, 2, true).TRACTION_CONTROL.note, 'absent du fichier')
  T.contains(Space.aidsPlan(dtm, { TRACTION_CONTROL = 1 }, 2, false).TRACTION_CONTROL.note, 'piste sèche')
  T.contains(Space.aidsPlan(dtm, { TRACTION_CONTROL = 1 }, 0, true).TRACTION_CONTROL.note, 'à 0')
  -- écriture facultative : section présente remplacée, absente ignorée, jamais un refus
  local text = '[TRACTION_CONTROL]\nVALUE=1\n[WING_1]\nVALUE=2\n'
  local out, applied = Space.renderOptional(text, { TRACTION_CONTROL = 3, ABS = 2 })
  T.contains(out, '[TRACTION_CONTROL]\nVALUE=3')
  T.no(out:find('ABS', 1, true), 'ABS absent : ignoré')
  T.eq(#applied, 1)
end

tests['PL06 calcul sous la pluie : aides relevées dans le fichier enregistré, ABS pris en compte, chargement vérifié'] = function()
  local h, app = boot()
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  h.car.tractionControlMode, h.car.absMode = 4, 4
  h.click = 'Relancer la découverte'
  frames(h, 1)
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  rain(h, 1, 0.6)
  refresh(h, app)
  app.settings.optBudgetEvalsQ = 60
  h.click = 'Calculer le setup tour rapide'
  T.ok(waitFor(h, function() return app.quali and app.quali.state ~= 'running' end))
  T.eq(app.quali.state, 'done', tostring(app.quali.error))
  local aids = app.quali.result.aids
  T.eq(aids.TRACTION_CONTROL.from, 4)
  T.eq(aids.TRACTION_CONTROL.to, 2)
  T.eq(aids.ABS.to, 2)
  T.eq(app.quali.result.absActive, true, 'ABS actif : pas de risque de blocage (H15)')
  h.click = 'Enregistrer le setup tour rapide'
  frames(h, 1)
  T.ok(app.quali.saved and app.quali.saved.ok, tostring(app.ui.message))
  local written = h.written[app.quali.saved.path]
  T.contains(written, '[TRACTION_CONTROL]\nVALUE=2')
  T.contains(written, '[ABS]\nVALUE=2')
  -- chargement au stand : constaté, les niveaux d'aide ne comptent pas (les aides du jeu peuvent les remplacer)
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  frames(h, 1)
  h.click = 'Charger le setup tour rapide dans la voiture'
  frames(h, 1)
  T.ok(app.loadArm, tostring(app.ui.message))
  local started = app.clock()
  while app.clock() - started < Config.K.loadConfirmMinSeconds + 0.1 do frames(h, 1) end
  h.click = 'Confirmer le chargement (tour rapide)'
  frames(h, 1)
  T.ok(waitFor(h, function() return app.loadCheck == nil end))
  T.ok(app.loadTest and app.loadTest.ok, tostring(app.loadTest and app.loadTest.reason))
  T.eq(app.perf.errors, 0)
end

-- « Vérifie bien que tous les paramètres soient bien pris en compte » : chaque cran de la DTM a un statut
-- pluie (modélisé, règle, inchangé avec sa raison, non touché).
tests['PL07 chaque réglage de la DTM a un statut pluie, et l\'interface le montre'] = function()
  local Space = require('src/setup_space')
  local h, app = boot('whk_dtm_2026')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  local rows = Space.statusRows(app.discovery.space)
  local seen = {}
  for _, row in ipairs(rows) do
    T.ok(row.wetShort == 'modélisé' or row.wetShort == 'règle' or row.wetShort == 'inchangé' or row.wetShort == 'non touché',
      row.label .. ' : ' .. tostring(row.wetShort))
    T.ok(type(row.wet) == 'string' and #row.wet > 10, row.label .. ' : raison')
    for _, name in ipairs(row.names) do seen[name] = true end
  end
  for _, sp in ipairs(h.spinners) do T.ok(seen[sp.name], sp.name .. ' sans statut') end
  h.tab, h.openSections = 'Réglages', true -- section « Réglages du setup », fermée d'office
  frames(h, 1)
  h.openSections = nil
  T.ok(shown(h, 'Aides (antipatinage, ABS)'), 'aides dans le tableau des réglages')
  T.ok(shown(h, 'Composé de pneus'))
  h.tab = nil
end

-- Interface sous la pluie, fenêtre étroite et large : alerte visible, section Pluie, comparatif avec l'usage
-- des composés, aides ; aucun identifiant ImGui en double (le faux hôte le vérifie).
tests['PL08 interface sous la pluie : alerte, section Pluie, aides, 360 et 900 px'] = function()
  local h, app = boot('whk_dtm_2026')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  rain(h, 1, 1)
  refresh(h, app)
  app.settings.optBudgetEvalsQ = 40
  h.click = 'Calculer le setup tour rapide'
  T.ok(waitFor(h, function() return app.quali and app.quali.state ~= 'running' end))
  T.eq(app.quali.state, 'done', tostring(app.quali.error))
  h.openSections = true -- section « Pneus et composé » (comparatif), fermée d'office
  for _, width in ipairs({ 360, 900 }) do
    h.width = width
    frames(h, 1)
    T.ok(shown(h, 'Setup pluie : composé'), width .. ' px : alerte visible')
    T.ok(shown(h, 'Modèle pluie à confirmer'), width .. ' px : hypothèses dites')
    T.ok(shown(h, 'Antipatinage : '), width .. ' px : règle des aides')
    T.ok(shown(h, '(pluie)') or shown(h, '(intermédiaire)'), width .. ' px : usage des composés comparés')
    T.ok(shown(h, 'Piste mouillée : setups pluie'), width .. ' px : bandeau')
    T.eq(app.perf.errors, 0)
  end
  h.width, h.openSections = 520, nil
end

return tests
