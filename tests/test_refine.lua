-- Mode affinage (demande de Vincent du 21/10/2026) : « on lance l'analyse, au fur et à mesure des tours
-- elle analyse, on enregistre le setup, on continue, on peaufine, jusqu'à trouver le meilleur setup ».
-- Décisions de Vincent : chargement proposé au stand en deux clics, jamais d'arrêt tout seul ; nouveau calcul
-- en continu (« même si on fait un demi-tour ou un tour, il va calculer automatiquement directement »), dès
-- qu'il y a des données nouvelles (un tour propre, ou N tours propres selon le réglage « Affinage : tours
-- propres avant un nouveau calcul » ; un chargement ; un nouvel essai après un refus). Décision amendée le
-- même jour (29 fichiers écrits en un quart d'heure) : rien n'est enregistré avant « Valider » ; chaque
-- setup proposé est une version en attente, annoncée une fois à l'écran (ac.setMessage).
local T = require('t')
local Config = require('src/config')
local CarModel = require('src/car_model')
local Sim = require('src/laptime_sim')
local Fake = require('fakehost')

local tests = {}

local TRUTH = { mu = 0.96, power = 0.98, drag = 1.02, lift = 1.0, brake = 1.0 }

local function boot(carId, trackId)
  local h = Fake.new({ car = require('fixtures/cars/' .. carId), track = require('fixtures/tracks/' .. trackId) })
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  app.utcOffset = function() return 7200 end
  h.texts = {}
  local function capture(text) h.texts[#h.texts + 1] = text end
  local text, wrapped, colored = h.ui.text, h.ui.textWrapped, h.ui.textColored
  h.ui.text = function(s) capture(s); return text(s) end
  h.ui.textWrapped = function(s) capture(s); return wrapped(s) end
  h.ui.textColored = function(s, c) capture(s); return colored(s, c) end
  return h, app
end

-- Une image : le conducteur simulé avance (si profile ; la voiture quitte alors les stands), puis l'app ;
-- hidden : fenêtre principale masquée (seule la boucle de calcul tourne).
local function frames(h, n, profile, hidden)
  for _ = 1, n do
    if profile then
      h.car.isInPit, h.car.isInPitlane = false, false
      Fake.drive(h, profile, 1 / 60)
    end
    h.sim.time = h.sim.time + 1000 / 60
    h.texts = {}
    script.SETUPLAB__UPDATE(1 / 60)
    if not hidden then script.SETUPLAB__MAIN(1 / 60) end
  end
end

local function waitFor(h, predicate, profile, maxFrames, hidden)
  for i = 1, maxFrames or 60000 do
    frames(h, 1, profile, hidden)
    if predicate() then return i end
  end
  return nil
end

local function shown(h, pattern)
  for _, text in ipairs(h.texts) do
    if text:find(pattern, 1, true) then return text end
  end
  return nil
end

local function spinner(h, name)
  for _, sp in ipairs(h.spinners) do
    if sp.name == name then return sp end
  end
  return nil
end

local function files(h)
  local n = 0
  for path in pairs(h.written) do
    if path:find(Config.exportQualiPrefix, 1, true) then n = n + 1 end
  end
  return n
end

-- Profil de vitesse « vrai » du setup de la découverte, pneus à température, carburant du réservoir.
local function drivenProfile(h, app)
  local d = app.discovery
  local fuel = spinner(h, 'FUEL') and spinner(h, 'FUEL').value or 30
  local setup = app.physicalSetup(d, nil, nil)
  setup.fuel = fuel
  local compound = d.carBase.compounds[setup.compound]
  local temp = CarModel.operatingTemp(compound.front)
  for w = 0, 3 do
    h.car.wheels[w].tyreCoreTemperature = temp
    h.car.wheels[w].tyrePressure = CarModel.hotPressure(w < 2 and setup.pressureF or setup.pressureR, d.conditions.airTemp, temp)
    h.car.wheels[w].tyreVirtualKM = 0.5
  end
  h.car.fuel = fuel
  local conditions = { airTemp = d.conditions.airTemp, roadGrip = d.conditions.roadGrip, surfaceGrip = d.conditions.surfaceGrip,
    factors = TRUTH }
  local eff = assert(CarModel.configure(d.carBase, setup, conditions))
  local result, buf = Sim.run(d.trackModel, eff, nil)
  local profile = { p = {}, v = {}, time = result.time }
  for k = 1, d.trackModel.n do profile.p[k], profile.v[k] = d.trackModel.p[k], buf.v[k] end
  profile.p[#profile.p + 1], profile.v[#profile.v + 1] = 1, buf.v[1]
  return profile
end

-- Chargement par le bouton de la carte d'affinage (au stand, délai minimal de confirmation respecté).
local function loadByButton(h, app)
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  h.driver = nil
  frames(h, 1)
  h.click = 'Charger le setup tour rapide dans la voiture'
  frames(h, 1)
  T.ok(app.loadArm, tostring(app.ui.message))
  local started = app.clock()
  while app.clock() - started < Config.K.loadConfirmMinSeconds + 0.1 do frames(h, 1) end
  h.click = 'Confirmer le chargement (tour rapide)'
  frames(h, 1)
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'constat du chargement')
  T.ok(app.loadTest and app.loadTest.ok, tostring(app.loadTest and app.loadTest.reason))
end

local function ready(carId)
  local h, app = boot(carId or 'lamborghini_huracan_gt3_evo2', 'monza')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  app.settings.optBudgetEvalsQ = 80
  app.settings.compoundChoice = app.discovery.compoundIndex
  return h, app
end

tests['AF01 boucle : v1 annoncée sans fichier, validée (un fichier), chargée, calcul sur elle, 2 tours, nouveau calcul'] = function()
  local h, app = ready()
  app.settings.refineLaps = 2
  h.click = 'Affinage automatique (tour rapide)'
  frames(h, 1)
  local r = app.refine
  T.ok(r and r.active, tostring(app.ui.message))
  T.eq(r.phase, 'calcul', 'premier calcul lancé tout de suite')
  T.ok(waitFor(h, function() return r.phase == 'tours' end), 'premier calcul terminé')
  T.eq(r.version, 1, tostring(r.waiting) .. ' / ' .. tostring(r.history[1] and r.history[1].note))
  T.eq(files(h), 0, 'rien d\'écrit avant la validation')
  T.eq(app.saved.quali, nil)
  T.eq(#(h.messages or {}), 1, 'v1 annoncée à l\'écran')
  T.contains(h.messages[1].title, 'v1 prêt')
  frames(h, 1)
  T.ok(shown(h, 'v1 prête : gain prévu'), 'carte : version en attente')
  T.ok(shown(h, 'v1 attend votre avis ; nouvelle analyse après 2 tours propres (0 / 2).'), 'carte : phase')
  -- même données : pas de nouveau calcul
  local computed = app.quali
  frames(h, 600)
  T.eq(app.quali, computed, 'pas de calcul sans données nouvelles')
  h.click = 'Valider v1'
  frames(h, 1)
  T.eq(files(h), 1, 'v1 enregistrée à la validation')
  T.eq(app.saved.quali.name, r.history[1].file)
  frames(h, 1)
  T.ok(shown(h, 'v1 : ' .. r.history[1].file .. ' — validée'), 'carte : version validée')
  T.ok(shown(h, 'Étape suivante : la charger au stand'), 'carte : étape suivante dite')
  T.ok(shown(h, 'À charger : ' .. r.history[1].file), 'carte : fichier à charger')
  -- chargement au stand : nouvelle découverte tout de suite, sur v1, puis un calcul sur elle
  loadByButton(h, app)
  T.ok(waitFor(h, function() return not r.needsDiscovery and app.discoveryState == 'done' end), 'découverte après chargement')
  T.eq(app.discovery.signature, app.saved.quali.signature, 'découverte sur v1')
  T.eq(r.driven, 1)
  T.ok(waitFor(h, function()
    return r.phase == 'tours' and app.quali and app.quali.discovery.signature == app.saved.quali.signature
  end), 'calcul sur v1, sans attendre de tour')
  -- tour de sortie (non compté), puis deux tours propres avec v1 : nouveau calcul
  local profile = drivenProfile(h, app)
  local lapsBefore = app.recorder.finished
  T.ok(waitFor(h, function() return r.phase == 'calcul' end, profile), 'calcul dû')
  T.ok(app.recorder.finished - lapsBefore >= 2, 'après deux tours')
  T.ok(waitFor(h, function() return r.phase == 'tours' end, profile), 'troisième calcul terminé')
  T.eq(files(h), 1, 'toujours un seul fichier : rien d\'écrit sans validation')
  T.ok(#h.messages <= r.version, 'une annonce par version au plus')
  T.eq(r.laps, 0, 'tours comptés depuis la fin du calcul')
  T.ok(app.calibration and app.calibration.result, 'calibration faite sur les tours')
  T.eq(app.perf.errors, 0)
end

-- Jamais muet : carburant consommé à chaque tour (setup changé, nouvelle découverte en piste), setup
-- encore changé pendant la découverte : la raison est affichée et le calcul repris au tour suivant.
tests['AF02 carburant qui baisse, setup changé pendant la découverte : dit, repris au tour suivant'] = function()
  local h, app = ready('whk_dtm_2026')
  app.settings.refineLaps = 2
  h.click = 'Affinage automatique (tour rapide)'
  frames(h, 1)
  local r = app.refine
  T.ok(waitFor(h, function() return r.phase == 'tours' end), 'premier calcul')
  local profile = drivenProfile(h, app)
  local fuel = spinner(h, 'FUEL')
  local seen = app.recorder.finished
  local bumped = false
  -- fenêtre masquée (boucle de calcul seule) : le carburant change entre la fin de la découverte
  -- relancée par le calcul et le lancement du calcul qui l'attendait
  local function step()
    frames(h, 1, profile, true)
    if app.recorder.finished > seen then
      seen = app.recorder.finished
      fuel.value = fuel.value - fuel.step -- réservoir
    end
    if not bumped and r.phase == 'calcul' and app.discoveryState == 'done' and app.pendingComputes.quali then
      fuel.value, bumped = fuel.value - fuel.step, true
    end
    return r.waiting ~= nil
  end
  local found = false
  for _ = 1, 60000 do
    if step() then
      found = true
      break
    end
  end
  T.ok(found, 'raison d\'attente affichée')
  T.contains(r.waiting, 'encore modifié')
  T.contains(r.waiting, 'nouvel essai au prochain tour propre')
  T.ok(r.retry)
  frames(h, 1, profile)
  T.ok(shown(h, r.waiting), 'raison visible dans la carte')
  -- le tour propre suivant (un seul) relance le calcul, qui aboutit ; carburant qui baisse : nouvelle
  -- découverte en piste à chaque calcul, sans blocage
  local laps = app.recorder.finished
  T.ok(waitFor(h, function() return r.phase == 'calcul' end, profile), 'nouvel essai')
  T.eq(app.recorder.finished - laps, 1, 'au tour suivant')
  local before = app.quali
  T.ok(waitFor(h, function() return r.phase == 'tours' and app.quali ~= before and app.quali.state == 'done' end, profile),
    'calcul abouti')
  T.eq(r.waiting, nil)
  T.eq(files(h), 0, 'rien d\'écrit sans validation')
  -- la calibration lancée par le tour qui déclenche le calcul n'est pas annulée par la découverte relancée
  -- (carburant changé) : elle aboutit, et le calcul s'en sert (relecture du 21/10/2026)
  T.ok(app.calibration and app.calibration.state == 'done' and app.calibration.result,
    'calibration ' .. tostring(app.calibration and app.calibration.state) .. ' : ' .. tostring(app.calibration and app.calibration.error))
  T.ok(app.quali.result.calibrated, 'dernier calcul fait avec la calibration des tours')
  T.eq(app.perf.errors, 0)
end

-- Fenêtre masquée en roulant : seule la boucle de calcul tourne ; l'affinage avance quand même.
tests['AF03 fenêtre masquée : calcul en attente de la découverte, puis version proposée (rien d\'écrit)'] = function()
  local h, app = ready()
  local pressure = spinner(h, 'PRESSURE_LF')
  pressure.value = pressure.value + pressure.step -- setup touché : nouvelle découverte avant le calcul
  app.handleIntents({ refineStart = 'quali' })
  local r = app.refine
  T.eq(r.phase, 'calcul')
  T.ok(app.pendingComputes.quali, 'calcul en attente de la découverte')
  T.ok(waitFor(h, function() return r.phase == 'tours' end, nil, 60000, true), 'abouti sans la fenêtre')
  T.eq(r.version, 1, tostring(r.waiting))
  T.eq(files(h), 0)
  T.eq(#h.messages, 1, 'annoncée à l\'écran, fenêtre masquée comprise')
  T.eq(app.discovery.space.members.PRESSURE_LF.current, pressure.value, 'calcul sur le setup en cours')
  T.eq(app.perf.errors, 0)
end

tests['AF04 arrêt : plus aucun calcul ; relance possible ; nouveau circuit : affinage oublié'] = function()
  local h, app = ready()
  app.settings.refineLaps = 2
  h.click = 'Affinage automatique (tour rapide)'
  frames(h, 1)
  local r = app.refine
  T.ok(waitFor(h, function() return r.phase == 'tours' end))
  h.click = 'Arrêter l\'affinage (tour rapide)'
  frames(h, 1)
  T.no(r.active)
  T.contains(app.ui.message, 'Affinage arrêté')
  local profile = drivenProfile(h, app)
  local before = app.recorder.finished
  T.ok(waitFor(h, function() return app.recorder.finished >= before + 3 end, profile), 'tours après l\'arrêt')
  T.eq(#r.history, 1, 'aucun calcul après l\'arrêt')
  T.eq(app.quali.state, 'done')
  frames(h, 1, profile)
  T.ok(shown(h, 'Affinage tour rapide (arrêté) — v1'))
  h.click = 'Relancer l\'affinage (tour rapide)'
  frames(h, 1, profile)
  T.ok(app.refine.active and app.refine ~= r, 'relancé')
  h.trackId = 'autre'
  app.contextKey = 'autre'
  app.nextContextAt = 0
  frames(h, 1)
  T.eq(app.refine, nil, 'contexte changé : affinage oublié')
end

-- En continu (décision de Vincent du 21/10/2026) : un nouveau calcul dès qu'il y a des données nouvelles (à
-- chaque tour propre), jamais deux fois sur les mêmes ; la version en attente est mise à jour, sans nouvelle
-- annonce ; un calcul refusé est réessayé après K.refineRetryDelay secondes (jamais à chaque image).
tests['AF05 en continu : un calcul par tour propre, jamais sur les mêmes données ; refus : nouvel essai après le délai'] = function()
  local h, app = ready()
  T.eq(app.settings.refineLaps, 0, 'en continu par défaut')
  h.click = 'Affinage automatique (tour rapide)'
  frames(h, 1)
  local r = app.refine
  T.ok(waitFor(h, function() return #r.history >= 1 and r.phase == 'tours' end), 'premier calcul')
  local computed = app.quali
  frames(h, 600)
  T.eq(app.quali, computed, 'mêmes données : pas de nouveau calcul')
  T.eq(app.recorder.finished, 0, 'aucun tour roulé')
  -- un tour propre : nouveau calcul ; la version en attente reste la même, sans nouvelle annonce
  local profile = drivenProfile(h, app)
  T.ok(waitFor(h, function() return app.quali ~= computed and r.phase == 'tours' end, profile), 'calcul après un tour')
  T.ok(app.recorder.finished >= 1)
  T.eq(files(h), 0, 'rien d\'écrit')
  T.ok(#(h.messages or {}) <= r.version, 'une annonce par version au plus')
  -- calcul refusé : nouvel essai seulement après le délai
  app.discoveryState, app.discoveryError = 'failed', 'panne simulée'
  T.ok(waitFor(h, function() return r.waiting ~= nil end, profile, 30000), 'refus dit')
  T.contains(r.waiting, 'panne simulée')
  T.contains(r.waiting, 'nouvel essai dans ' .. Config.K.refineRetryDelay .. ' s')
  local count = #r.history
  local nextAt = r.nextAt
  frames(h, 60 * (Config.K.refineRetryDelay - 2))
  T.eq(r.nextAt, nextAt, 'aucun essai avant le délai')
  frames(h, 60 * 3)
  T.ok(r.nextAt > nextAt, 'nouvel essai après le délai')
  T.eq(#r.history, count)
  frames(h, 1)
  T.ok(shown(h, 'Nouvel essai dans') or shown(h, 'nouvel essai dans'), 'attente dite dans la carte')
  T.eq(app.perf.errors, 0)
end

return tests
