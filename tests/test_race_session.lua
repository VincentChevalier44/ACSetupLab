-- Affinage pendant une séance de course (demande de Vincent du 05/11/2026 : « quand on fait des courses, on arrive sur la
-- partie et on est directement positionné sur la grille… quand on arrive en course, on doit pouvoir mettre le menu course
-- et cliquer sur Affiner au fur et à mesure des tours et à la fin de la course on propose un setup adapté »). Ses deux
-- choix du même jour : les tours en trafic comptent pour la course (jamais pour la calibration ni le tour rapide) ; en
-- séance de course, l'affinage part du setup en place, sans qualification de SetupLab. Rien n'est chargé avant l'arrivée,
-- arrêt au stand compris ; la version reste provisoire pendant la course et elle est annoncée une fois, à l'arrivée. Une
-- fenêtre en piste (« SetupLab Track ») reprend l'interface ; une seule des deux fenêtres dessine à chaque image.
local T = require('t')
local Config = require('src/config')
local Exporter = require('src/exporter')
local CarModel = require('src/car_model')
local Sim = require('src/laptime_sim')
local L = require('src/i18n')
local Fake = require('fakehost')

local TRUTH = { mu = 0.96, power = 0.98, drag = 1.02, lift = 1.0, brake = 1.0 }
local EN_STORE = 'setuplab-store 1|settings#refineMinLaps=0|settings#language=s:en'

local tests = {}

-- Séance de course (session 3 : grille, course de 14 tours) ou autre séance ; window : fenêtre dessinée à chaque image
-- (« main » : menu de setup, « track » : en piste).
local function boot(opts)
  opts = opts or {}
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza'),
    skin = opts.skin, lang = opts.lang, stored = opts.lang == 'en' and { ['setuplab:data'] = EN_STORE } or nil })
  local session = opts.session or 3
  h.sim.raceSessionType = session
  h.session.type = session
  h.session.laps = opts.laps or 14
  h.session.isTimedRace = opts.timed == true
  h.session.durationMinutes = opts.minutes or 0
  rawset(h.car, 'isRaceFinished', false)
  rawset(h.sim, 'isSessionFinished', false)
  if session == 3 then
    -- sur la grille : hors des stands, arrêtée
    h.car.isInPit, h.car.isInPitlane, h.car.speedMs = false, false, 0
  end
  h.texts = {}
  local function capture(text) h.texts[#h.texts + 1] = text end
  local text, wrapped, colored = h.ui.text, h.ui.textWrapped, h.ui.textColored
  h.ui.text = function(s) capture(s); return text(s) end
  h.ui.textWrapped = function(s) capture(s); return wrapped(s) end
  h.ui.textColored = function(s, c) capture(s); return colored(s, c) end
  h.window = opts.window or 'main'
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  app.utcOffset = function() return 7200 end
  app.settings.optBudgetEvalsQ, app.settings.optBudgetEvalsC = 80, 300
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
    if h.window == 'main' then script.SETUPLAB__MAIN(1 / 60) else script.SETUPLAB__TRACK(1 / 60) end
  end
end

local function waitFor(h, predicate, maxFrames, profile)
  for i = 1, maxFrames or 60000 do
    frames(h, 1, profile)
    if predicate() then return i end
  end
  return nil
end

local function ready(opts)
  local h, app = boot(opts)
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  app.settings.compoundChoice = app.discovery.compoundIndex
  return h, app
end

local function shown(h, fragment)
  for _, s in ipairs(h.texts) do
    if tostring(s):find(fragment, 1, true) then return s end
  end
  return nil
end

local function messagesWith(h, fragment)
  local n = 0
  for _, m in ipairs(h.messages or {}) do
    if tostring(m.title):find(fragment, 1, true) then n = n + 1 end
  end
  return n
end

local function cspHas(h, fragment)
  for _, line in ipairs(h.cspLog or {}) do
    if tostring(line):find(fragment, 1, true) then return true end
  end
  return false
end

local function lastVersion(r)
  for i = #r.history, 1, -1 do
    if r.history[i].version then return r.history[i] end
  end
  return nil
end

local function folderOf(h)
  return assert(Exporter.targetFolder({ ac = h.ac, io = h.io }))
end

local function filesLike(h, fragment)
  local n = 0
  for path in pairs(h.written) do
    if path:find(fragment, 1, true) then n = n + 1 end
  end
  return n
end

local function spinner(h, name)
  for _, sp in ipairs(h.spinners) do
    if sp.name == name then return sp end
  end
  return nil
end

-- Profil de vitesse « vrai » du setup de la découverte (comme test_auto).
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

-- Course en cours, première version de course calculée d'un clic (« Calculer le setup course » : un calcul tout de suite,
-- même pendant la course ; sans ce clic, le setup se calcule à l'arrivée) : sur la grille.
local function racePending(opts)
  local h, app = ready(opts)
  app.settings.refineMinLaps, app.settings.refineMinMinutes, app.settings.refineInstantFirst = 0, 0, false
  app.handleIntents({ refineStart = 'race' })
  local r = app.refine
  T.ok(r and r.active and r.kind == 'race', 'affinage de la course lancé : ' .. tostring(app.ui.message))
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end, 60000), 'v1 de course : ' .. tostring(r.waiting))
  local e = lastVersion(r)
  T.ok(e and e.status == nil, 'v1 en attente')
  return h, app, r, e
end

tests['RS10 sur la grille, sans qualification : la course part du setup en place ; tours de la séance ; ailleurs, inchangé'] =
function()
  local h, app = ready()
  T.eq(app.raceLaps, 14, 'tours lus dans la séance de course')
  T.eq(app.raceBlocker(), nil, 'séance de course : le setup en place suffit')
  local _, action = app.raceQualiBase()
  T.eq(action, 'qualif', 'aucune qualification de SetupLab (elle n\'est plus exigée en course)')
  T.ok(app.raceRunning(), 'course en cours (grille)')
  -- carte d'étape : « Affiner pendant la course », sans calcul forcé sur zéro tour de course
  local model = app.ui and require('src/ui').stepModel(app, 'Course')
  T.ok(model and model.sessionStart, 'carte de la séance de course')
  T.eq(select(2, model.actions[1].label:match('^(.-)###(.*)$')), 'step_race_session')
  -- minimum de deux tours propres (réglage par défaut ; le banc démarre à zéro)
  app.settings.refineMinLaps, app.settings.refineInstantFirst = 2, false
  h.click = 'step_race_session'
  frames(h, 1)
  local r = app.refine
  T.ok(r and r.active and r.kind == 'race', 'clic : affinage de la course lancé')
  T.eq(r.forceNext, nil, 'pas de calcul forcé sur zéro tour de course')
  frames(h, 30)
  T.eq(r.phase, 'tours', 'il analyse, sans calcul : ' .. tostring(r.waiting))
  T.ok(tostring(r.waiting):find('calculé à l\'arrivée', 1, true), tostring(r.waiting))
  T.ok(app.auto, 'le départ de la course choisi active SetupLab')
  T.eq(app.perf.errors, 0)
  -- saisi pendant la course : gardé jusqu'à la séance suivante (pas remplacé par celui de la séance à la découverte)
  app.handleIntents({ raceLaps = 20 })
  T.eq(app.raceLaps, 20)
  -- course au temps : tours estimés d'après la durée et le tour simulé
  local h2, app2 = ready({ timed = true, laps = 0, minutes = 20 })
  local lap = app2.discovery.simCurrent.time
  T.eq(app2.raceLaps, math.ceil(20 * 60 / lap), 'course au temps : estimée')
  -- séance d'essai : la règle du 26/10 reste (qualification de SetupLab d'abord)
  local h3, app3 = ready({ session = 1 })
  local _, action3 = app3.raceBlocker()
  T.eq(action3, 'qualif', 'hors séance de course : qualification exigée')
  T.no(app3.raceRunning())
  T.eq(app2.perf.errors + app3.perf.errors, 0)
  local _ = h2, h3
end

tests['RS11 pendant la course : provisoire, rien d\'annoncé ni chargé au stand ; à l\'arrivée, une seule annonce'] = function()
  local h, app, r, e = racePending({ skin = true })
  T.eq(e.ready, false, 'sur la grille : provisoire')
  T.eq(messagesWith(h, 'en préparation'), 1, 'une annonce « en préparation »')
  local prep = h.messages[#h.messages]
  T.ok(tostring(prep.description):find('arrivée', 1, true), 'texte de course : ' .. tostring(prep.description))
  local loads = #h.loadCalls
  -- arrêt au stand pendant la course : menu modifiable selon le jeu, rien n'est annoncé prêt ni chargé
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  frames(h, 120)
  T.eq(messagesWith(h, 'prêt'), 0, 'aucune annonce « prêt » au stand pendant la course')
  T.eq(e.ready, false)
  T.ok(tostring(app.loadBlocker('race')):find('course en cours', 1, true), tostring(app.loadBlocker('race')))
  -- Essayer : refusé avant toute écriture
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'essayer' } })
  T.eq(e.status, nil, 'pas d\'essai pendant la course : ' .. tostring(app.ui.message))
  T.eq(filesLike(h, '_essai'), 0, 'aucun fichier d\'essai')
  T.ok(tostring(app.ui.message):find('pendant la course', 1, true), tostring(app.ui.message))
  -- interface : ni Essayer ni Charger
  h.tab = 'Course'
  frames(h, 2)
  T.no(shown(h, 'ESSAYER V' .. e.version), 'pas de bouton Essayer')
  T.ok(shown(h, 'pour votre prochaine course') or shown(h, 'POUR LA PROCHAINE COURSE'), 'texte de course affiché')
  T.eq(#h.loadCalls, loads, 'aucun ac.loadSetup pendant la course')
  -- arrivée : une seule annonce, « pour votre prochaine course »
  h.car.isInPit, h.car.isInPitlane = false, false
  h.car.isRaceFinished = true
  frames(h, 60)
  T.eq(messagesWith(h, 'pour votre prochaine course'), 1, 'annonce à l\'arrivée')
  T.eq(e.ready, true)
  local last = h.messages[#h.messages]
  T.ok(tostring(last.description):find('tour', 1, true) and tostring(last.description):find('COURSE', 1, true),
    tostring(last.description))
  frames(h, 120)
  T.eq(messagesWith(h, 'pour votre prochaine course'), 1, 'une seule fois')
  -- le tour du drapeau, compté juste après l'annonce, met la version à jour (nouveau calcul) : pas de seconde annonce
  e.updates = (e.updates or 0) + 1
  app.refineAnnounce(r, e)
  T.eq(messagesWith(h, 'pour votre prochaine course'), 1, 'mise à jour après l\'arrivée : sans nouveau message')
  T.eq(e.readyAt, e.updates, 'version à jour, toujours prête')
  T.ok(cspHas(h, 'Séance de course : course lancée'), 'départ au journal')
  T.ok(cspHas(h, 'Séance de course : arrivée'), 'arrivée au journal')
  local model = require('src/ui').stepModel(app, 'Course')
  T.eq(model.step, 4)
  T.eq(select(2, model.actions[1].label:match('^(.-)###(.*)$')), 'step_action')
  T.eq(model.actions[1].intent.refineJudge.verdict, 'valider', 'à l\'arrivée : Valider')
  T.no(app.raceRunning())
  T.eq(app.perf.errors, 0)
  local _ = r
end

tests['RS12 Valider pendant la course : fichier écrit pour la prochaine course, rien dans la voiture'] = function()
  local h, app, r, e = racePending({ skin = true })
  h.tab = 'Course'
  local loads = #h.loadCalls
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  frames(h, 2)
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.eq(e.status, 'validée', tostring(app.ui.message))
  T.ok(h.written[folderOf(h) .. '/' .. tostring(e.file)] ~= nil, 'fichier écrit : ' .. tostring(e.file))
  T.eq(#h.loadCalls, loads, 'aucun ac.loadSetup')
  T.eq(app.loadCheck, nil, 'aucun chargement en cours')
  T.ok(tostring(app.ui.message):find('prochaine course', 1, true), tostring(app.ui.message))
  T.eq(r.choice, e.version, 'question posée : continuer ou figer')
  local model = require('src/ui').stepModel(app, 'Course')
  T.ok(model.text:find('prochaine course', 1, true), model.text)
  T.no(model.pendingLoad, 'rien à charger pendant la course')
  -- le bouton « Charger » n'est pas proposé (carte d'étape, barre de chargement) ; un clic de chargement est refusé
  frames(h, 2)
  T.ok(shown(h, 'POUR VOTRE PROCHAINE COURSE') or shown(h, 'pour votre prochaine course'), 'carte d\'étape de course')
  T.no(shown(h, 'CHARGER LE SETUP COURSE'), 'aucun bouton « Charger » pendant la course')
  T.no(shown(h, 'PAS ENCORE DANS LA VOITURE'), 'aucune barre de chargement pendant la course')
  -- « Continuer l'affinage » : la carte n'a plus d'action ; toujours aucun bouton « Charger » pendant la course
  app.handleIntents({ refineChoice = { version = e.version } })
  frames(h, 2)
  T.no(shown(h, 'CHARGER LE SETUP COURSE'), 'après « Continuer » : aucun bouton « Charger »')
  app.handleIntents({ load = 'race' })
  T.eq(#h.loadCalls, loads, 'chargement refusé')
  -- mémoire : la course validée est la référence de ce circuit pour la prochaine course
  T.ok(app.memory['course|sec'] and app.memory['course|sec'].file == e.file, 'référence de course en mémoire')
  -- après l'arrivée, le chargement redevient possible au stand
  h.car.isRaceFinished = true
  frames(h, 2)
  T.eq(app.loadBlocker('race'), nil, 'après l\'arrivée : chargeable au stand')
  T.eq(app.perf.errors, 0)
end

tests['RS13 fenêtre en piste : elle dessine et traite les clics ; elle laisse la main à la fenêtre du menu de setup'] = function()
  local h, app = ready({ window = 'track' })
  frames(h, 2)
  T.no(shown(h, 'cette fenêtre reprend en piste'), 'seule en piste : interface complète')
  T.ok(#h.texts > 10, 'interface dessinée : ' .. #h.texts .. ' textes')
  -- un clic dans la fenêtre en piste est traité
  h.click = 'step_race_session'
  frames(h, 1)
  T.ok(app.refine and app.refine.active and app.refine.kind == 'race', 'clic traité par la fenêtre en piste')
  -- les deux fenêtres à la même image : celle du menu de setup garde la main
  h.sim.time = h.sim.time + 1000 / 60
  script.SETUPLAB__UPDATE(1 / 60)
  script.SETUPLAB__MAIN(1 / 60)
  h.texts = {}
  script.SETUPLAB__TRACK(1 / 60)
  T.ok(shown(h, 'cette fenêtre reprend en piste'), 'fenêtre en piste : une ligne seulement')
  T.ok(#h.texts <= 2, 'rien d\'autre : ' .. #h.texts .. ' textes')
  -- dans l'ordre inverse, à l'image suivante, toujours une seule
  h.sim.time = h.sim.time + 1000 / 60
  script.SETUPLAB__UPDATE(1 / 60)
  h.texts = {}
  script.SETUPLAB__TRACK(1 / 60)
  T.ok(shown(h, 'cette fenêtre reprend en piste'), 'menu de setup dessiné à l\'image d\'avant')
  -- menu de setup refermé : la fenêtre en piste reprend
  frames(h, 3)
  T.no(shown(h, 'cette fenêtre reprend en piste'), 'reprise en piste')
  T.eq(app.perf.errors, 0)
end

tests['RS14 tours de course en trafic : comptés pour l\'affinage de la course, jamais pour la calibration'] = function()
  local h, app = ready()
  app.settings.refineMinLaps, app.settings.refineMinMinutes = 2, 0
  app.handleIntents({ refineStart = 'race', raceSession = true })
  local r = app.refine
  h.sim.carsCount = 2
  h.others = { Fake.otherCar(0.5) }
  local profile = drivenProfile(h, app)
  local length = app.discovery.trackModel.length
  for _ = 1, 150000 do
    h.others[1].splinePosition = (h.car.splinePosition + 20 / length) % 1
    -- consommation : environ 3 L par tour
    h.car.fuel = h.car.fuel - 0.0005
    frames(h, 1, profile)
    if app.recorder.finished >= 2 then break end
  end
  T.eq(app.recorder.finished, 2, 'deux tours de course')
  T.eq(app.trafficRejects or 0, 0, 'aucun tour rejeté pour trafic en course')
  local last = app.recorder.laps.last
  T.ok(last.valid and last.traffic, 'dernier tour : en trafic, valide : ' .. tostring(last.reason))
  T.eq(next(app.recorder.laps.best), nil, 'aucun meilleur tour de setup (calibration, tour rapide)')
  T.eq(app.calibration, nil, 'aucune calibration lancée sur un tour en trafic')
  T.eq(app.roughness, nil, 'aucune rugosité mesurée sur un tour en trafic')
  T.eq(r.minLaps, 2, 'comptés pour le minimum de la course')
  -- pendant la course : aucun calcul (constat de Vincent du 05/11/2026 : « le calcul, il est à la fin de la course »)
  frames(h, 120)
  T.eq(app.race, nil, 'aucun calcul pendant la course')
  T.ok(tostring(r.waiting):find('calculé à l\'arrivée', 1, true), tostring(r.waiting))
  -- arrivée : calcul une fois le dernier tour enregistré, puis une seule annonce
  h.car.speedMs = 0
  h.car.isRaceFinished = true
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end, 60000), 'v1 de course à l\'arrivée : '
    .. tostring(r.waiting))
  T.eq(messagesWith(h, 'pour votre prochaine course'), 1, 'annoncée une fois à l\'arrivée')
  local e = lastVersion(r)
  local line = require('src/ui').raceLapsLine(app, e)
  T.ok(line:find('dont 2 en trafic', 1, true), line)
  -- consommation mesurée sur le tour de course en trafic (aucun tour libre)
  local plan = e.view and e.view.race
  T.ok(plan ~= nil, 'plan de course de la v1')
  T.eq(plan.fuelSource, 'mesure', 'consommation mesurée sur un tour en trafic : ' .. tostring(plan.fuelSource))
  T.ok(math.abs(plan.fuelPerLap - last.fuelStart + last.fuelEnd) < 0.05, 'litres par tour du dernier tour : '
    .. tostring(plan.fuelPerLap))
  -- même roulage en essai : tours rejetés pour trafic, rien de compté (règle du 03/11 inchangée)
  local h2, app2 = ready({ session = 1 })
  h2.sim.carsCount = 2
  h2.others = { Fake.otherCar(0.5) }
  local profile2 = drivenProfile(h2, app2)
  for _ = 1, 150000 do
    h2.others[1].splinePosition = (h2.car.splinePosition + 20 / length) % 1
    frames(h2, 1, profile2)
    if app2.recorder.finished >= 1 then break end
  end
  T.eq(app2.trafficRejects, 1, 'hors course : rejeté pour trafic')
  T.eq(app.perf.errors + app2.perf.errors, 0)
end

-- Avant le départ (séance de course pas encore commencée), rien ne change : la course part de la qualification de votre
-- choix et sa v1 s'essaie au stand (parcours de la 1.5.2) ; la carte de la séance est là aussi. Départ donné : plus rien
-- ne se charge avant l'arrivée.
tests['RS15 avant le départ : qualif au choix, v1 de course essayée au stand ; course lancée : plus rien ne se charge'] =
function()
  local h, app = ready({ skin = true })
  h.sim.isSessionStarted = false
  frames(h, 2)
  T.no(app.raceRunning(), 'avant le départ : course pas lancée')
  T.ok(app.raceIn(), 'séance de course')
  Fake.raceReady(h, app, 12)
  h.tab = 'Course'
  frames(h, 2)
  T.ok(shown(h, 'AFFINER PENDANT LA COURSE'), 'carte de la séance')
  T.ok(shown(h, 'DE QUELLE QUALIF PART-ON ?'), 'qualifications au choix avant le départ')
  app.settings.refineMinLaps, app.settings.refineInstantFirst = 2, false
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  app.handleIntents({ refineStart = 'race' })
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end, 60000), 'v1 : ' .. tostring(r.waiting))
  local e = lastVersion(r)
  T.eq(e.ready, true, 'au stand avant le départ : prête')
  local loads = #h.loadCalls
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'essayer' } })
  T.eq(e.status, 'essai', tostring(app.ui.message))
  T.eq(#h.loadCalls, loads + 1, 'avant le départ : chargée au stand')
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'chargement constaté')
  -- départ donné : plus rien ne se charge
  h.sim.isSessionStarted = true
  frames(h, 2)
  T.ok(app.raceRunning(), 'course lancée')
  T.ok(tostring(app.loadBlocker('race')):find('course en cours', 1, true), tostring(app.loadBlocker('race')))
  T.eq(app.perf.errors, 0)
end

-- Arrivée (relecture du 05/11/2026) : celle de votre voiture ; la séance peut finir avec la voiture de tête, avant vous.
-- La fin de séance ne sert que si le champ de la voiture manque.
tests['RS16 arrivée : celle de votre voiture ; la fin de séance seulement si ce champ manque'] = function()
  local h, app = ready()
  h.sim.isSessionFinished = true
  T.no(app.raceOver(), 'séance finie par la voiture de tête : votre course continue')
  T.ok(app.raceRunning(), 'course toujours lancée')
  h.car.isRaceFinished = true
  T.ok(app.raceOver(), 'votre drapeau')
  rawset(h.car, 'isRaceFinished', nil)
  T.ok(app.raceOver(), 'champ de la voiture illisible : fin de la séance')
  h.sim.isSessionFinished = false
  T.no(app.raceOver())
  T.eq(app.perf.errors, 0)
end

-- Constat de Vincent du 05/11/2026, au menu de setup avant le départ, son setup chargé : « Affiner pendant la course »
-- lançait un calcul (premier setup tout de suite coché) et l'interrupteur restait en veille. Le clic active SetupLab ;
-- aucun calcul avant l'arrivée ; à l'arrivée, le calcul, puis une seule annonce.
tests['RS17 avant le départ, depuis votre setup : SetupLab activé, aucun calcul avant l\'arrivée, puis une annonce'] =
function()
  local h, app = ready({ skin = true })
  h.sim.isSessionStarted = false
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  app.settings.refineMinLaps, app.settings.refineInstantFirst = 0, true
  app.auto = false
  h.tab = 'Course'
  h.click = 'step_race_session'
  frames(h, 1)
  local r = app.refine
  T.ok(r and r.active and r.kind == 'race', 'affinage de la course lancé')
  T.ok(app.auto, 'interrupteur ACTIF allumé')
  frames(h, 300)
  T.eq(app.race, nil, 'aucun calcul avant le départ depuis votre setup')
  T.ok(tostring(r.waiting):find('calculé à l\'arrivée', 1, true), tostring(r.waiting))
  h.sim.isSessionStarted = true
  h.car.isInPit, h.car.isInPitlane = false, false
  frames(h, 300)
  T.eq(app.race, nil, 'aucun calcul pendant la course')
  h.car.isRaceFinished = true
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end, 60000), 'v1 à l\'arrivée : ' .. tostring(r.waiting))
  T.eq(messagesWith(h, 'pour votre prochaine course'), 1, 'une annonce à l\'arrivée')
  T.eq(app.perf.errors, 0)
end

-- Constat de Vincent du 05/11/2026 (capture : « NEW BASE 1.29.490 » chargé depuis le menu d'AC, SetupLab restait sur le
-- setup du lancement) : en séance de course, un setup chargé depuis le menu d'AC, voiture arrêtée, est relu tout seul et
-- devient la base de l'affinage. Hors séance de course, rien ne change.
tests['RS18 séance de course : un setup chargé depuis le menu d\'AC devient la base, relu tout seul'] = function()
  local h, app = ready({ skin = true })
  h.sim.isSessionStarted = false
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  app.handleIntents({ refineStart = 'race', raceSession = true })
  frames(h, 10)
  local before = app.discovery.family
  -- chargé depuis le menu d'AC : une barre avant + 1
  local arb = spinner(h, 'ARB_FRONT')
  arb.value = arb.value + 1
  T.ok(waitFor(h, function() return app.discoveryState == 'done' and app.discovery and app.discovery.family ~= before end, 3000),
    'setup relu tout seul')
  T.ok(cspHas(h, 'setup changé dans le menu de setup'), 'dit au journal')
  T.ok(app.refine and app.refine.active and app.refine.kind == 'race', 'l\'affinage de la course continue')
  frames(h, 300)
  local after = app.discovery
  T.ok(after.family ~= before, 'base : le setup chargé')
  T.eq(app.discovery, after, 'une seule nouvelle découverte (setup stable)')
  -- hors séance de course : rien de relu tout seul
  local h2, app2 = ready({ session = 1 })
  local d2 = app2.discovery
  local arb2 = spinner(h2, 'ARB_FRONT')
  arb2.value = arb2.value + 1
  frames(h2, 600)
  T.eq(app2.discovery, d2, 'hors course : pas de nouvelle découverte')
  T.eq(app.perf.errors + app2.perf.errors, 0)
end

-- Constat de Vincent du 05/11/2026 : revenu au stand après ses huit tours, « il ne m'affiche absolument rien, il ne m'a rien
-- calculé ». Après l'arrivée : calcul à pleine part même sous 60 images/s, et la carte d'étape dit le calcul et sa
-- progression ; le panneau du bas, « Calcul de l'affinage ».
tests['RS19 après l\'arrivée : calcul à pleine part sous 60 images/s, carte « calcul du setup de course » et progression'] =
function()
  local h, app = ready({ skin = true })
  app.settings.refineMinLaps, app.settings.optBudgetEvalsC = 0, 400
  app.handleIntents({ refineStart = 'race', raceSession = true })
  local r = app.refine
  h.sim.fps = 40
  -- pendant la course, sous 60 images/s : tranche réduite (rien ne calcule encore, découverte faite)
  h.car.isRaceFinished = true
  T.ok(waitFor(h, function() return r.phase == 'calcul' and app.race and app.race.state == 'running' end, 2000),
    'calcul lancé à l\'arrivée : ' .. tostring(r.waiting))
  local slow = app.perf.slowFrames
  h.tab = 'Course'
  frames(h, 5)
  T.eq(app.perf.slowFrames, slow, 'après l\'arrivée : pleine part, même à 40 images/s')
  T.ok(shown(h, 'CALCUL DU SETUP DE COURSE'), 'carte : calcul du setup de course')
  T.ok(shown(h, 'SetupLab calcule le setup de cette course'), 'carte : progression')
  T.ok(shown(h, 'CALCUL DE L\'AFFINAGE'), 'panneau du bas : calcul de l\'affinage')
  T.no(shown(h, 'CALCUL À LA MAIN'), 'pas « calcul à la main »')
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end, 60000), 'v1 à l\'arrivée')
  T.eq(app.perf.errors, 0)
  -- avant l'arrivée, même cadence : tranche réduite
  local h2, app2 = ready()
  app2.settings.refineMinLaps = 0
  h2.sim.fps = 40
  app2.handleIntents({ refineStart = 'race' })
  T.ok(waitFor(h2, function() return app2.race and app2.race.state == 'running' end, 2000), 'calcul forcé pendant la course')
  local slow2 = app2.perf.slowFrames
  frames(h2, 5)
  T.ok(app2.perf.slowFrames > slow2, 'pendant la course : tranche réduite sous 60 images/s')
  T.eq(app2.perf.errors, 0)
end

-- Interface en anglais (langue par défaut) : chaque état de la course rendu, onglets, overlay ; aucun texte resté en
-- français.
tests['EN04 séance de course en anglais : départ, provisoire, validée, arrivée, fenêtre en piste'] = function()
  L.misses, L.unmatched = {}, {}
  L.reset()
  local TABS = { 'Tour rapide', 'Course', 'Mémoire', 'Mesure', 'Réglages', 'Capacités', 'Aide' }
  local function render(h)
    h.sim.time = h.sim.time + 1000 / 60
    script.SETUPLAB__UPDATE(1 / 60)
    for _, tab in ipairs(TABS) do
      h.tab = tab
      script.SETUPLAB__MAIN(1 / 60)
    end
    h.tab = nil
    script.SETUPLAB__OVERLAY(1 / 60)
    frames(h, 2)
  end
  local h, app = ready({ skin = true, lang = 'en' })
  h.hover, h.openSections = true, true
  render(h)
  local h2, app2, r2, e2 = racePending({ skin = true, lang = 'en' })
  h2.hover, h2.openSections = true, true
  render(h2)
  h2.car.isInPit, h2.car.isInPitlane, h2.car.speedMs = true, true, 0
  app2.handleIntents({ refineJudge = { version = e2.version, verdict = 'essayer' } })
  render(h2)
  h2.car.isRaceFinished = true
  render(h2)
  app2.handleIntents({ refineJudge = { version = e2.version, verdict = 'valider' } })
  render(h2)
  local h3, app3, _, e3 = racePending({ skin = true, lang = 'en' })
  h3.hover, h3.openSections = true, true
  app3.handleIntents({ refineJudge = { version = e3.version, verdict = 'valider' } })
  render(h3)
  -- fenêtre en piste qui laisse la main
  script.SETUPLAB__MAIN(1 / 60)
  script.SETUPLAB__TRACK(1 / 60)
  -- rendu de repli (sans le thème) : départ de la course, puis version provisoire
  local h4, app4 = ready({ lang = 'en' })
  h4.hover, h4.openSections = true, true
  render(h4)
  local h5, app5 = racePending({ lang = 'en' })
  h5.hover, h5.openSections = true, true
  render(h5)
  T.eq(app4.perf.errors + app5.perf.errors, 0)
  for _, hh in ipairs({ h, h2, h3, h4, h5 }) do
    for _, m in ipairs(hh.messages or {}) do
      if L.looksFrench(m.title) then L.misses[m.title] = m.title end
      if L.looksFrench(m.description) then L.misses[m.description] = m.description end
    end
  end
  for _, msg in ipairs({ app.ui.message, app2.ui.message, app3.ui.message }) do
    if msg then
      L.set('en')
      local out = L.t(msg)
      if L.looksFrench(out) then L.misses[msg] = out end
    end
  end
  local list = {}
  for fr, out in pairs(L.misses) do list[#list + 1] = fr .. '  =>  ' .. out end
  table.sort(list)
  for i = 1, math.min(#list, 400) do PY.note('EN04 ' .. i, list[i]) end
  L.misses, L.unmatched = nil, nil
  T.eq(app.perf.errors + app2.perf.errors + app3.perf.errors, 0)
  T.eq(#list, 0, 'tout est traduit')
  local _ = r2
end

return tests
