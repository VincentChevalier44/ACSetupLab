-- Tests du calcul qualification (J4, §10.2, §10.6, §12.3) : noyau (optimizer.runQuali) puis chaîne
-- complète depuis la colle (lancement, progression, annulation, enregistrement, refus).
local T = require('t')
local Util = require('src/util')
local Config = require('src/config')
local Datasource = require('src/datasource')
local TrackModel = require('src/track_model')
local CarModel = require('src/car_model')
local Space = require('src/setup_space')
local Optimizer = require('src/optimizer')
local Fake = require('fakehost')

local SYNC = Util.syncContext()
local tests = {}

local function prepare(carId, trackId, budget, opts)
  opts = opts or {}
  opts.car = require('fixtures/cars/' .. carId)
  opts.track = require('fixtures/tracks/' .. trackId)
  local h = Fake.new(opts)
  local car = Datasource.readCar(h, 0, SYNC)
  local state = Datasource.readCarState(h, 0)
  local setup = Datasource.readSetup(h, SYNC)
  local raw = Datasource.sampleTrack(h, 1, SYNC)
  Datasource.probeBank(h, raw, SYNC)
  local files = Datasource.readTrackFiles(h, SYNC)
  local track = assert(TrackModel.build(raw, files, 2))
  local coarse = assert(TrackModel.build(raw, files, 4))
  local base = CarModel.build(car, nil)
  local space = Space.build({ setupIni = car.ini['setup.ini'], spinners = setup.spinners, ratios = car.ratios })
  Space.verify(space, state, base)
  Space.attach(space, base)
  local settings = Config.defaults()
  local p = Optimizer.prepareQuali({
    base = base, space = space, track = track, trackCoarse = coarse, settings = settings, budget = budget,
    conditions = { airTemp = 24, roadGrip = 0.98, surfaceGrip = track.surfaceGrip },
  })
  return { h = h, p = p, space = space, setup = setup, base = base }
end

tests['Q01 calcul qualification : jamais pire que l\'actuel, budget, grille, réglages autorisés'] = function()
  local r = prepare('lamborghini_huracan_gt3_evo2', 'monza', 260)
  local state = Optimizer.newState({ budget = 260 })
  local result = assert(Optimizer.runQuali(r.p, SYNC, state))
  T.ok(state.done)
  T.ok(result.proposedJ <= result.currentJ + 1e-9, 'critère : proposé ' .. result.proposedJ .. ' / actuel ' .. result.currentJ)
  T.ok(state.evaluations <= 260 + 60, 'budget tenu : ' .. state.evaluations)
  local allowed = {}
  for _, var in ipairs(Space.optimizable(r.space)) do allowed[var.key] = true end
  for key, d in pairs(result.deltas) do
    if d ~= 0 then T.ok(allowed[key] or key == 'fuel', key .. ' modifié alors que non optimisable') end
  end
  local values, errors = Space.values(r.space, result.deltas, { fuel = true })
  T.eq(#errors, 0, table.concat(errors, ' ; '))
  for name, v in pairs(values) do
    local m = r.space.members[name]
    T.ok(v >= m.min and v <= m.max and (v - m.min) % m.step == 0, name .. ' sur la grille')
  end
  -- la simulation a bien roulé avec le carburant de qualification, pas avec celui du setup actuel
  T.near(r.p.setup.fuel, result.fuel.liters, 1e-9, 'masse simulée au carburant de qualification')
  -- carburant de qualification : règle des tours au lieu du plein par défaut
  T.ok(result.fuel.liters and result.fuel.liters >= result.fuel.target - 1e-9, 'carburant couvre la cible')
  T.ok(result.fuel.liters < result.fuel.from, 'moins de carburant qu\'au setup actuel')
  T.eq(result.fuel.source, 'modèle', 'consommation CSP absente hors jeu')
  T.ok(#result.profileCurrent.v > 100 and #result.profileProposed.v == #result.profileCurrent.v)
  for _, c in ipairs(result.changes) do
    T.ok(Util.isFinite(c.contribution), c.var.key .. ' : contribution finie')
    T.ok(c.clicks ~= 0)
  end
end

tests['Q02 reproductible (graine fixe, §10.5)'] = function()
  local function run()
    local r = prepare('urd_px1_aura', 'monza', 150)
    local state = Optimizer.newState({ budget = 150 })
    local result = assert(Optimizer.runQuali(r.p, SYNC, state))
    local keys = {}
    for key, d in pairs(result.deltas) do keys[#keys + 1] = key .. '=' .. d end
    table.sort(keys)
    return table.concat(keys, ','), result.proposedJ
  end
  local a, ja = run()
  local b, jb = run()
  T.eq(a, b)
  T.eq(ja, jb)
end

tests['Q03 carburant de qualification : règle des tours, plancher de setup.ini'] = function()
  local r = prepare('formula_k', 'monza', 50)
  local settings = Config.defaults()
  local K = Config.K
  local d, liters, target = Optimizer.qualiFuel(r.space, settings, 1.7, true)
  T.near(target, K.qualiFuelLaps * 1.7 * (1 + K.qualiFuelMarginMeasured), 1e-12, 'formula_k : minimum 0 L, plancher en tours')
  T.ok(liters >= target and liters < target + 1 + 1e-9, 'cran juste au-dessus : ' .. liters)
  T.ok(d ~= nil)
  local _, _, targetModel = Optimizer.qualiFuel(r.space, settings, 1.7, false)
  T.ok(targetModel > target, 'marge plus large sans mesure CSP')
  local _, _, tiny = Optimizer.qualiFuel(r.space, settings, 0.1, true)
  T.eq(tiny, K.qualiFuelMinLiters, 'jamais sous le plancher absolu')
  settings.fuelQualiLaps = 5
  local _, _, target5 = Optimizer.qualiFuel(r.space, settings, 1.7, true)
  T.near(target5, 5 * 1.7 * (1 + K.qualiFuelMarginMeasured), 1e-12)
  T.eq(Optimizer.qualiFuel(r.space, settings, 0), nil, 'consommation inconnue : carburant inchangé')
end

-- Chaîne complète depuis la colle ------------------------------------------------------------

local function boot(carId, trackId, opts)
  opts = opts or {}
  opts.car = require('fixtures/cars/' .. carId)
  opts.track = require('fixtures/tracks/' .. trackId)
  local h = Fake.new(opts)
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  return h, rawget(_G, 'SETUPLAB').app
end

local function frames(h, n)
  for _ = 1, n do
    h.sim.time = h.sim.time + 16.7
    script.SETUPLAB__UPDATE(0.0167)
    script.SETUPLAB__MAIN(0.0167)
  end
end

local function waitFor(h, predicate, maxFrames)
  for i = 1, maxFrames or 20000 do
    frames(h, 1)
    if predicate() then return i end
  end
  return nil
end

tests['Q04 colle : profil du setup actuel, calcul, progression, enregistrement'] = function()
  local h, app = boot('lamborghini_huracan_gt3_evo2', 'monza')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  local d = app.discovery
  T.ok(d.simCurrent and d.simCurrent.time and d.simCurrent.time > 90, 'tour simulé du setup actuel')
  T.ok(d.simCurrent.evalMs and d.simCurrent.evalMs > 0, 'coût mesuré d\'une évaluation')
  T.eq(app.qualiBlocker(), nil)
  frames(h, 1)
  T.ok(h.strokes > 0 and h.pathPoints > 100, 'profil de vitesse tracé')
  app.settings.optBudgetEvalsQ = 120
  h.click = 'Calculer le setup tour rapide'
  frames(h, 2)
  T.eq(app.quali.state, 'running')
  T.ok(waitFor(h, function() return h.progress ~= nil end, 50), 'barre de progression')
  -- tranches pendant le calcul (charge réelle en jeu) : budget de 2 ms tenu (A8, A16)
  local samples, last = {}, app.scheduler.stats.slices
  T.ok(waitFor(h, function()
    local st = app.scheduler.stats
    if st.slices ~= last then
      last = st.slices
      samples[#samples + 1] = st.lastSliceMs
    end
    return app.quali.state ~= 'running'
  end), 'calcul terminé')
  table.sort(samples)
  local p90 = samples[math.ceil(#samples * 0.9)]
  PY.note('Q04', string.format('%d tranches pendant le calcul : p50 %.3f p90 %.3f max %.3f ms', #samples,
    samples[math.ceil(#samples * 0.5)], p90, samples[#samples]))
  T.ok(#samples > 20 and p90 <= 2.3, '90e centile des tranches ' .. tostring(p90) .. ' ms')
  T.eq(app.quali.state, 'done', tostring(app.quali.error))
  T.eq(app.perf.errors, 0)
  local before = h.writeCalls
  h.click = 'Enregistrer le setup tour rapide'
  frames(h, 1)
  T.ok(app.quali.saved and app.quali.saved.ok, tostring(app.ui.message))
  T.ok(app.quali.saved.path:find(Config.exportQualiPrefix, 1, true), app.quali.saved.path)
  T.eq(h.writeCalls, before + 1, 'une seule écriture : le nouveau fichier (D8)')
  local files = 0
  for _ in pairs(h.written) do files = files + 1 end
  T.eq(files, 1, 'aucun autre fichier touché')
  -- le fichier écrit : seuls les VALUE proposés changent
  local written = Util.parseIni(h.written[app.quali.saved.path])
  local current = Util.parseIni(h.ac.stringifyCurrentSetup(true, false))
  local changed = 0
  for _, section in ipairs(current.order) do
    local a, b = Util.iniGet(current, section, 'VALUE'), Util.iniGet(written, section, 'VALUE')
    if a ~= b then
      changed = changed + 1
      if section == 'TYRES' then
        -- composé choisi par l'app (D18) : seulement s'il change, à l'index retenu
        T.ok(app.quali.result.compound.changed, 'composé modifié sans changement retenu')
        T.eq(tonumber(b), app.quali.result.compound.index)
      else
        T.ok(d.space.members[section] ~= nil, section .. ' modifié mais absent de l\'espace')
      end
    end
  end
  T.ok(changed >= 1, changed .. ' réglages modifiés (carburant compris)')
end

tests['Q05 colle : setup du jeu changé après le calcul -> fichier du calcul, dit ; annulation'] = function()
  local h, app = boot('urd_px1_aura', 'monza')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  app.settings.optBudgetEvalsQ = 80
  h.click = 'Calculer le setup tour rapide'
  T.ok(waitFor(h, function() return app.quali and app.quali.state == 'done' end), tostring(app.quali and app.quali.error))
  -- Vincent touche un cran après le calcul (au volant, ou dans le menu de setup) : décision du 21/10/2026,
  -- l'enregistrement n'est plus refusé, le fichier reste le setup du calcul
  local d = app.discovery
  local bias = d.space.members.FRONT_BIAS
  local values = Space.values(d.space, app.quali.result.deltas, { fuel = true })
  local expected = values.FRONT_BIAS or bias.current
  for _, sp in ipairs(h.spinners) do
    if sp.name == 'FRONT_BIAS' then sp.value = sp.value + (sp.value + sp.step <= sp.max and sp.step or -sp.step) end
  end
  h.click = 'Enregistrer le setup tour rapide'
  frames(h, 1)
  T.ok(app.quali.saved and app.quali.saved.ok, tostring(app.ui.message))
  T.contains(app.ui.message, 'a changé depuis le calcul (FRONT_BIAS)')
  T.contains(app.quali.saveStatus.text, 'le fichier reprend le setup du calcul')
  local written = Util.parseIni(h.written[app.quali.saved.path])
  T.eq(tonumber(Util.iniGet(written, 'FRONT_BIAS', 'VALUE')), expected, 'répartition du calcul, pas celle touchée depuis')
  -- annulation en cours de calcul : état conservé, aucune erreur
  app.settings.optBudgetEvalsQ = 5000
  h.click = 'Relancer la découverte'
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  h.click = 'Calculer le setup tour rapide'
  frames(h, 30)
  T.eq(app.quali.state, 'running')
  h.click = 'Annuler le calcul'
  frames(h, 2)
  T.eq(app.quali.state, 'cancelled')
  T.ok(app.quali.opt.evaluations > 0 and app.quali.opt.evaluations < 5000)
  T.eq(app.perf.errors, 0)
  -- piste mouillée : calcul accepté, setup pluie (D16 amendé le 21/10/2026, décision de Vincent)
  h.sim.rainWetness = 0.5
  app.nextContextAt = 0
  frames(h, 2)
  T.eq(app.qualiBlocker(), nil, 'pluie : plus de refus')
  T.eq(app.wet.state, 'pluie')
end

tests['Q06 robustesse de la colle : modèle de voiture en erreur, setup changé avant le calcul'] = function()
  local CarModelMod = require('src/car_model')
  local original = CarModelMod.build
  CarModelMod.build = function() error('voiture inattendue (simulé)') end
  local ok, err = pcall(function()
    local h, app = boot('formula_k', 'monza')
    T.ok(waitFor(h, function() return app.discoveryState == 'done' and app.report ~= nil end), 'découverte et rapport malgré l\'erreur')
    T.contains(app.qualiBlocker(), 'erreur')
    T.contains(app.report, 'Circuit')
  end)
  CarModelMod.build = original
  assert(ok, err)
  -- setup touché entre la découverte et le lancement : calcul refusé
  local h, app = boot('urd_px1_aura', 'monza')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  for _, sp in ipairs(h.spinners) do
    if sp.name == 'PRESSURE_LF' then sp.value = sp.value + sp.step end
  end
  local old, pressure = app.discovery, nil
  for _, sp in ipairs(h.spinners) do
    if sp.name == 'PRESSURE_LF' then pressure = sp.value end
  end
  app.settings.optBudgetEvalsQ = 60
  h.click = 'Calculer le setup tour rapide'
  frames(h, 2)
  -- décision de Vincent du 20/10/2026 : découverte relancée sur le setup en cours, puis calcul
  T.contains(app.ui.message, 'depuis la découverte')
  T.ok(app.pendingComputes.quali)
  T.ok(waitFor(h, function() return app.quali and app.quali.state ~= 'running' end), 'calcul lancé après la découverte')
  T.eq(app.quali.state, 'done', tostring(app.quali.error))
  T.ok(app.quali.discovery ~= old, 'calcul fait sur la nouvelle découverte')
  T.eq(app.quali.discovery.space.members.PRESSURE_LF.current, pressure, 'setup modifié pris en compte')
end

tests['Q07 durée estimée sous 60 images/s, consommation retenue'] = function()
  local Ui = require('src/ui')
  local app = { settings = Config.defaults(), discovery = { simCurrent = { evalMs = 2 } }, context = { fps = 60 } }
  local at60 = Ui.estimateSeconds(app, 4000)
  T.near(at60, 4000 * 2 * Config.K.optEstimateFactor / (2 * 60), 1e-9)
  app.context.fps = 30
  local at30 = Ui.estimateSeconds(app, 4000)
  T.near(at30 / at60, 2 / Config.K.slowFpsSliceFactor, 1e-9, 'tranche réduite et moitié moins d\'images')
  -- coût avec le DRS en qualification (m8) ; durée bornée par la durée visée (arrêt au temps)
  app.context.fps = 60
  app.evalCost = function(kind) return kind == 'quali' and 4 or 2 end
  T.near(Ui.estimateSeconds(app, 4000, 1, 'quali') / at60, 2, 1e-9)
  local longText, long = Ui.durationText(Ui.estimateSeconds(app, 4000, 1, 'quali'), Config.K.computeTargetQ)
  T.ok(long, 'au-delà de la durée indicative')
  T.contains(longText, 'baisser le budget')
  T.contains(longText, 'estimée ≈ ' .. Util.fmt(Ui.estimateSeconds(app, 4000, 1, 'quali'), 0) .. ' s')
  local shortText, short = Ui.durationText(10, Config.K.computeTargetQ)
  T.no(short)
  T.contains(shortText, 'estimée ≈ 10 s')
  T.contains(Ui.durationText(10, Config.K.computeTargetQ, true), 'tranche de calcul est réduite')
  app.evalCost = nil
  -- consommation : la plus grande de la mesure CSP et du modèle
  local low = prepare('lamborghini_huracan_gt3_evo2', 'monza', 20)
  low.p.args.fuelPerLap = 0.1
  local rLow = assert(Optimizer.runQuali(low.p, SYNC, Optimizer.newState({ budget = 20 })))
  T.eq(rLow.fuel.source, 'modèle', 'mesure CSP trop basse ignorée')
  local high = prepare('lamborghini_huracan_gt3_evo2', 'monza', 20)
  high.p.args.fuelPerLap = 9
  local rHigh = assert(Optimizer.runQuali(high.p, SYNC, Optimizer.newState({ budget = 20 })))
  T.eq(rHigh.fuel.source, 'CSP')
  T.near(rHigh.fuel.perLap, 9, 1e-12)
end

tests['Q08 petit budget : la recherche a lieu, robustesse signalée si non couverte'] = function()
  local r = prepare('whk_dtm_2026', 'monza', 100)
  local state = Optimizer.newState({ budget = 100 })
  local result = assert(Optimizer.runQuali(r.p, SYNC, state))
  T.ok(state.evaluations <= 100, 'budget tenu : ' .. state.evaluations)
  T.ok(state.evaluations >= 60, 'la recherche a consommé le budget : ' .. state.evaluations)
  T.ok(result.robustSkipped, 'robustesse non couverte par 100 évaluations : signalée')
  T.ok(result.proposedJ <= result.currentJ + 1e-9)
end

tests['Q09 composé monté (D18) : retrouvé par son index, absent -> calcul refusé'] = function()
  -- composé monté différent du composé par défaut (tendre, index 0) : le setup actuel est simulé avec lui
  local h, app = boot('lamborghini_huracan_gt3_evo2', 'monza')
  h.car.compoundIndex = 0
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  local d = app.discovery
  T.eq(d.compoundIndex, 0)
  T.eq(d.carBase.compounds[d.compoundSlot].index, 0)
  local h2, app2 = boot('lamborghini_huracan_gt3_evo2', 'monza')
  T.ok(waitFor(h2, function() return app2.discoveryState == 'done' end))
  T.ok(d.simCurrent.time < app2.discovery.simCurrent.time - 0.05,
    'tendre ' .. d.simCurrent.time .. ' contre medium ' .. app2.discovery.simCurrent.time)
  T.ok(d.signature ~= app2.discovery.signature, 'le composé fait partie de la signature')
  -- composé monté absent de tyres.ini : calcul refusé (prudence §0.6)
  local h3, app3 = boot('lamborghini_huracan_gt3_evo2', 'monza')
  h3.car.compoundIndex = 7
  T.ok(waitFor(h3, function() return app3.discoveryState == 'done' end))
  T.contains(app3.qualiBlocker(), 'composé monté')
  -- correspondance par index, pas par position (un composé invalide écarté décale les positions)
  local base = { compounds = { { index = 0 }, { index = 2 } } }
  T.eq(CarModel.compoundSlot(base, 2), 2)
  T.eq(CarModel.compoundSlot(base, 1), nil)
end

tests['Q10 choix du composé : pluie jamais choisie d\'office, composé imposé respecté'] = function()
  local r = prepare('lamborghini_huracan_gt3_evo2', 'monza', 80)
  T.ok(CarModel.isWetCompound({ name = 'Wet', short = 'W' }))
  T.ok(CarModel.isWetCompound({ name = 'Intermediate', short = 'I' }))
  T.no(CarModel.isWetCompound({ name = 'Slick Soft', short = 'S' }))
  -- pneu pluie fictif, plus adhérent que tous les slicks (DY_REF de mod)
  local soft = r.base.compounds[1]
  local wet = { index = 3, name = 'Wet', short = 'W', front = {}, rear = {} }
  for key, value in pairs(soft.front) do wet.front[key] = value end
  for key, value in pairs(soft.rear) do wet.rear[key] = value end
  wet.front.dyRef, wet.rear.dyRef = soft.front.dyRef * 1.3, soft.rear.dyRef * 1.3
  r.base.compounds[#r.base.compounds + 1] = wet
  local auto = assert(Optimizer.runQuali(r.p, SYNC, Optimizer.newState({ budget = 80 })))
  T.ok(auto.compound.name ~= 'Wet', 'choix automatique : ' .. tostring(auto.compound.name))
  -- pneu pluie ni comparé ni choisi (D16) : seulement s'il est monté ou imposé
  for _, e in ipairs(auto.compound.comparison) do T.ok(e.name ~= 'Wet', 'pneu pluie hors comparatif') end
  T.eq(auto.compound.name, 'Slick Soft', 'le slick le plus adhérent en qualification')
  -- composé imposé de pluie : refusé (D16), choix automatique
  local wetImposed = prepare('lamborghini_huracan_gt3_evo2', 'monza', 80)
  wetImposed.base.compounds[#wetImposed.base.compounds + 1] = wet
  wetImposed.p.args.compoundChoice = 3
  local rw = assert(Optimizer.runQuali(wetImposed.p, SYNC, Optimizer.newState({ budget = 80 })))
  T.ok(rw.compound.name ~= 'Wet')
  T.contains(rw.compound.note, 'pluie')
  -- composé imposé (index CSP) : respecté
  local imposed = prepare('lamborghini_huracan_gt3_evo2', 'monza', 80)
  imposed.base.compounds[#imposed.base.compounds + 1] = wet
  imposed.p.args.compoundChoice = 2
  local hard = assert(Optimizer.runQuali(imposed.p, SYNC, Optimizer.newState({ budget = 80 })))
  T.eq(hard.compound.index, 2)
  T.ok(hard.compound.imposed)
  T.ok(hard.compound.changed)
  -- temps « actuel » : setup actuel avec le composé monté (au carburant de qualification), pas le dur
  local setup = CarModel.defaultSetup(imposed.base)
  Space.apply(imposed.space, setup, { fuel = hard.fuel.delta })
  local eff = assert(CarModel.configure(imposed.base, setup, imposed.p.conditions))
  local Sim = require('src/laptime_sim')
  T.near(hard.timeCurrent, Sim.run(imposed.p.args.track, eff, nil).time, 1e-6, 'tour actuel avec le composé monté')
  -- composé imposé absent : choix automatique, avec la raison
  local missing = prepare('lamborghini_huracan_gt3_evo2', 'monza', 80)
  missing.p.args.compoundChoice = 9
  local m = assert(Optimizer.runQuali(missing.p, SYNC, Optimizer.newState({ budget = 80 })))
  T.contains(m.compound.note, 'absent')
end

tests['Q11 reproductible quelle que soit l\'horloge (§10.5) : même setup en qualification et en course'] = function()
  -- contexte à horloge lente : l'horloge avance d'1 ms à chaque appel (machine chargée) ; le résultat ne
  -- doit dépendre d'aucune mesure de temps
  local clock = 0
  local slow = { tick = function() end, now = function() clock = clock + 0.001; return clock end }
  local function quali(ctx)
    local w = prepare('lamborghini_huracan_gt3_evo2', 'monza', 150)
    return assert(Optimizer.runQuali(w.p, ctx, Optimizer.newState({ budget = 150 })))
  end
  local function race(ctx)
    local w = prepare('lamborghini_huracan_gt3_evo2', 'monza', 20)
    local settings = Config.defaults()
    settings.raceLaps = 12
    local args = {}
    for key, value in pairs(w.p.args) do args[key] = value end
    args.settings, args.budget = settings, 20
    args.race = { fuelPerLapCsp = 3, kmPerLapF = 5.8, kmPerLapR = 5.8 }
    return assert(Optimizer.runRace(Optimizer.prepareRace(args), ctx, Optimizer.newState({ budget = 20 })))
  end
  for kind, run in pairs({ quali = quali, race = race }) do
    local a, b = run(SYNC), run(slow)
    T.eq(a.evaluations, b.evaluations, kind .. ' : évaluations')
    T.eq(a.timeProposed, b.timeProposed, kind .. ' : temps proposé')
    for key, value in pairs(a.deltas) do T.eq(b.deltas[key], value, kind .. ' : ' .. key) end
    for key, value in pairs(b.deltas) do T.eq(a.deltas[key], value, kind .. ' : ' .. key) end
  end
end

tests['Q12 setup actuel toujours évalué, recherche incomplète signalée'] = function()
  local w = prepare('lamborghini_huracan_gt3_evo2', 'monza', 1)
  local r = assert(Optimizer.runQuali(w.p, SYNC, Optimizer.newState({ budget = 1 })))
  T.eq(#r.changes, 0)
  T.ok(r.timeProposed <= r.timeCurrent + 1e-9)
  T.eq(r.refined, 0, 'aucun optimum raffiné : l\'interface affiche « recherche incomplète »')
  -- budget normal : des optimums raffinés
  local w2 = prepare('lamborghini_huracan_gt3_evo2', 'monza', 120)
  local r2 = assert(Optimizer.runQuali(w2.p, SYNC, Optimizer.newState({ budget = 120 })))
  T.ok(r2.refined > 0)
end

tests['Q13 calcul en attente de la découverte : annulé, mode inerte, setup encore modifié'] = function()
  local h, app = boot('lamborghini_huracan_gt3_evo2', 'monza')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  app.settings.optBudgetEvalsQ = 60
  local function touch()
    for _, sp in ipairs(h.spinners) do
      if sp.name == 'PRESSURE_LF' then sp.value = sp.value + sp.step end
    end
  end
  -- annulé pendant la découverte : aucun calcul ensuite
  touch()
  h.click = 'Calculer le setup tour rapide'
  frames(h, 1)
  T.ok(app.pendingComputes.quali)
  h.click = 'Annuler le calcul'
  frames(h, 1)
  T.eq(next(app.pendingComputes), nil, 'calcul en attente annulé')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  frames(h, 5)
  T.eq(app.quali, nil, 'aucun calcul après la découverte')
  -- mode inerte pendant l'attente : calcul abandonné
  touch()
  h.click = 'Calculer le setup tour rapide'
  frames(h, 1)
  T.ok(app.pendingComputes.quali)
  h.sim.isOnlineRace = true
  app.nextContextAt = 0
  frames(h, 1)
  T.eq(next(app.pendingComputes), nil, 'en ligne : calcul en attente abandonné')
  h.sim.isOnlineRace = false
  app.nextContextAt = 0
  T.ok(waitFor(h, function() return app.discoveryState == 'done' and app.inert == nil end))
  frames(h, 5)
  T.eq(app.quali, nil)
  -- setup encore modifié pendant la découverte : pas de nouvelle relance en boucle, message
  touch()
  h.click = 'Calculer le setup tour rapide'
  frames(h, 1)
  T.eq(app.discoveryState, 'running')
  -- boucle de calcul seule jusqu'à la fin de la découverte, setup modifié avant que l'interface ne
  -- lance le calcul en attente
  for _ = 1, 40000 do
    h.sim.time = h.sim.time + 1000 / 60
    script.SETUPLAB__UPDATE(1 / 60)
    if app.discoveryState ~= 'running' then break end
  end
  T.ok(app.pendingComputes.quali)
  touch()
  frames(h, 1)
  T.eq(next(app.pendingComputes), nil)
  T.eq(app.quali, nil)
  T.contains(app.ui.message, 'encore modifié')
  for i = 1, 4 do
    app.nextContextAt = 0
    frames(h, 1)
    T.eq(app.discoveryState, 'done', 'pas de relance en boucle (relecture ' .. i .. ')')
  end
  -- clic pendant une découverte : le calcul la suit
  h.click = 'Relancer la découverte'
  frames(h, 1)
  h.click = 'Calculer le setup tour rapide'
  frames(h, 1)
  T.ok(app.pendingComputes.quali)
  T.ok(waitFor(h, function() return app.quali and app.quali.state == 'done' end), 'calcul après la découverte')
  T.eq(app.perf.errors, 0)
end

-- Constat de Vincent du 21/10/2026 (DTM, Spa) : « si je refais une analyse et que je veux réenregistrer, il
-- ne fait rien du tout ». Répartition de freinage touchée au volant ou carburant changé entre le calcul et
-- le clic : refus, dit seulement en haut de la fenêtre. Désormais : autant de fichiers que de clics, à
-- l'heure locale, issue affichée sous le bouton.
tests['Q14 recalculer et enregistrer autant de fois que voulu : heure locale, issue sous le bouton'] = function()
  local Exporter = require('src/exporter')
  local h, app = boot('whk_dtm_2026', 'monza')
  app.utcOffset = function() return 7200 end -- Paris, heure d'été
  local shown = {}
  local colored = h.ui.textColored
  h.ui.textColored = function(s, c)
    shown[#shown + 1] = s
    return colored(s, c)
  end
  local function under(fragment)
    for _, s in ipairs(shown) do
      if s:find(fragment, 1, true) then return s end
    end
    return nil
  end
  local function setSpinner(name, delta)
    for _, sp in ipairs(h.spinners) do
      if sp.name == name then sp.value = sp.value + delta * sp.step end
    end
  end
  local function save()
    h.click = 'Enregistrer le setup tour rapide'
    frames(h, 1)
    shown = {}
    frames(h, 1)
  end
  local function compute()
    h.click = 'Calculer le setup tour rapide'
    T.ok(waitFor(h, function()
      return app.quali and app.quali.state ~= 'running' and not app.pendingComputes.quali and app.discoveryState ~= 'running'
    end), 'calcul terminé')
    T.eq(app.quali.state, 'done', tostring(app.quali.error))
  end
  local function files()
    local list = {}
    for path in pairs(h.written) do
      if path:find(Config.exportQualiPrefix, 1, true) then list[#list + 1] = path:match('[^/]+$') end
    end
    table.sort(list)
    return list
  end
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  app.settings.optBudgetEvalsQ = 60
  compute()
  save()
  T.eq(app.quali.saved.name, 'SetupLab_Qualif_2026-10-19_02h00m00s.ini', 'heure locale dans le nom')
  T.ok(under('Enregistré : SetupLab_Qualif_2026-10-19_02h00m00s.ini'), 'issue affichée sous le bouton')
  -- même résultat, même seconde : un autre fichier
  save()
  T.eq(app.quali.saved.name, 'SetupLab_Qualif_2026-10-19_02h00m00s-2.ini')
  T.ok(under('(2 fichiers pour ce calcul)'))
  -- en piste : carburant consommé, répartition touchée au volant ; nouveau calcul (découverte relancée)
  h.sim.systemTime = h.sim.systemTime + 75
  setSpinner('FUEL', -5)
  setSpinner('FRONT_BIAS', 1)
  compute()
  T.contains(app.ui.message, 'découverte relancée')
  local d = app.quali.discovery
  local values = Space.values(d.space, app.quali.result.deltas, { fuel = true })
  local bias = values.FRONT_BIAS or d.space.members.FRONT_BIAS.current
  -- encore touchés entre la fin du calcul et le clic : enregistré quand même, sur le setup du calcul
  setSpinner('FRONT_BIAS', -1)
  setSpinner('FUEL', -1)
  save()
  T.ok(app.quali.saved and app.quali.saved.ok, tostring(app.ui.message))
  T.eq(app.quali.saved.name, 'SetupLab_Qualif_2026-10-19_02h01m15s.ini')
  T.ok(under('Enregistré : SetupLab_Qualif_2026-10-19_02h01m15s.ini'), 'nouveau calcul : compteur repart à 1')
  T.contains(app.quali.saveStatus.text, 'a changé depuis le calcul')
  local written = Util.parseIni(h.written[app.quali.saved.path])
  T.eq(tonumber(Util.iniGet(written, 'FRONT_BIAS', 'VALUE')), bias, 'répartition du calcul')
  T.eq(tonumber(Util.iniGet(written, 'FUEL', 'VALUE')), values.FUEL or d.space.members.FUEL.current, 'carburant du calcul')
  T.eq(#files(), 3, table.concat(files(), ', '))
  -- le dernier fichier reste chargeable (signature du fichier écrit)
  T.eq(app.saved.quali.name, app.quali.saved.name)
  T.eq(app.saved.quali.signature, app.proposals.quali)
  -- erreur interne pendant l'enregistrement : dite sous le bouton, puis un nouveau clic réussit
  local writeNew = Exporter.writeNew
  Exporter.writeNew = function() error('panne simulée') end
  local okRun, errRun = pcall(save)
  Exporter.writeNew = writeNew
  assert(okRun, errRun)
  T.ok(under('erreur interne'), 'erreur affichée sous le bouton')
  T.eq(app.perf.errors, 1)
  h.sim.systemTime = h.sim.systemTime + 1
  app.nextContextAt = 0
  save()
  T.ok(app.quali.saved.ok and under('Enregistré : SetupLab_Qualif_2026-10-19_02h01m16s.ini'))
  T.eq(#files(), 4)
  -- sans heure locale : UTC, dit dans le nom
  app.utcOffset = nil
  h.sim.systemTime = h.sim.systemTime + 1
  app.nextContextAt = 0
  save()
  T.eq(app.quali.saved.name, 'SetupLab_Qualif_2026-10-19_00h01m17sUTC.ini')
end

return tests
