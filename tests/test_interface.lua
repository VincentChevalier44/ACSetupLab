-- Tests du J7 (§12, §13) : onglets et bandeau, réglages modifiés et conservés d'une séance à l'autre,
-- explications par réglage, équilibre par virage, calibration reprise d'une séance précédente,
-- validation en jeu.
local T = require('t')
local Config = require('src/config')
local Store = require('src/store')
local Fake = require('fakehost')

local tests = {}

-- Charge l'app sur un hôte (neuf, ou existant : rechargement du script avec le même stockage).
local function load(h)
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  h.texts = {}
  local text, wrapped, colored = h.ui.text, h.ui.textWrapped, h.ui.textColored
  if not h.captured then
    h.ui.text = function(s) h.texts[#h.texts + 1] = s; return text(s) end
    h.ui.textWrapped = function(s) h.texts[#h.texts + 1] = s; return wrapped(s) end
    h.ui.textColored = function(s, c) h.texts[#h.texts + 1] = s; return colored(s, c) end
    h.captured = true
  end
  return app
end

local function frame(h)
  h.texts = {}
  h.sim.time = h.sim.time + 1000 / 60
  script.SETUPLAB__UPDATE(1 / 60)
  script.SETUPLAB__MAIN(1 / 60)
end

local function untilDone(h, app, predicate)
  for _ = 1, 200000 do
    frame(h)
    if predicate(app) then return true end
  end
  return false
end

local function shown(h, fragment)
  for _, text in ipairs(h.texts) do
    if text:find(fragment, 1, true) then return text end
  end
  return nil
end

-- Entrée de calibration ou de rugosité telle que l'app l'écrit : empreinte des fichiers de la voiture
-- et version du modèle (D9).
local function produced(h, fields)
  local Datasource = require('src/datasource')
  local out = { data = Datasource.fingerprint(Datasource.readCar(h, 0, require('src/util').syncContext())),
    model = Config.K.modelVersion, stamp = 1792000000 }
  for key, value in pairs(fields) do out[key] = value end
  return out
end

local function newHost()
  return Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
end

tests['I01 onglets et bandeau (§12.1)'] = function()
  local h = newHost()
  local app = load(h)
  T.ok(untilDone(h, app, function(a) return a.discoveryState == 'done' end))
  frame(h)
  T.eq(table.concat(h.tabs, ','), 'QUALIF,COURSE,MÉMOIRE,MESURE,RÉGLAGES,DIAGNOSTIC,AIDE')
  T.ok(shown(h, 'Données : fichiers de la voiture ; modèle non calibré'), 'bandeau')
  -- un seul onglet affiché : le reste ne l'est pas
  h.tab = 'Course'
  frame(h)
  T.ok(shown(h, 'Course'))
  T.no(shown(h, 'Mesure et calibration'), 'onglet Mesure masqué')
  h.tab = nil
end

tests['I02 réglages modifiés, enregistrés, relus au chargement suivant (§13)'] = function()
  local h = newHost()
  h.stored = {} -- stockage vide au départ (ce test lit ce qui est écrit)
  local app = load(h)
  T.ok(untilDone(h, app, function(a) return a.discoveryState == 'done' end))
  local label
  for _, def in ipairs(Config.settings) do
    if def.key == 'refineMinLaps' then label = def.label end
  end
  h.sliders = { [label] = 7 }
  frame(h)
  T.eq(app.settings.refineMinLaps, 7)
  -- écrit au rythme du contexte (1 Hz)
  for _ = 1, 90 do frame(h) end
  T.contains(h.stored[Store.KEY] or '', 'settings#refineMinLaps=7')
  -- valeur hors bornes : ramenée dans les bornes
  h.sliders = { [label] = 100000 }
  frame(h)
  T.eq(app.settings.refineMinLaps, 20)
  h.sliders = { [label] = 7 }
  frame(h)
  for _ = 1, 90 do frame(h) end
  -- rechargement du script (nouvelle séance) : réglage relu ; persistance confirmée dans les capacités
  T.eq(app.discovery.caps.byId.storage.status, 'pending', 'rien de relu à la première séance')
  local again = load(h)
  T.eq(again.settings.refineMinLaps, 7)
  T.ok(untilDone(h, again, function(a) return a.discoveryState == 'done' end))
  T.eq(again.discovery.caps.byId.storage.status, 'available')
  T.contains(again.discovery.caps.byId.storage.detail, 'relue')
  -- stockage corrompu : réglages par défaut, aucune erreur
  h.stored[Store.KEY] = 'setuplab-store 1|settings#refineMinLaps=abc|settings#perfStab=99'
  local third = load(h)
  T.eq(third.settings.refineMinLaps, 2)
  T.eq(third.settings.perfStab, 0.6)
  T.ok(untilDone(h, third, function(a) return a.discoveryState == 'done' end))
  T.eq(third.perf.errors, 0)
  -- réglages non modifiables dans l'interface : jamais relus (un stockage ne désactive pas l'app et ne
  -- change pas la tranche de calcul)
  h.stored[Store.KEY] = 'setuplab-store 1|settings#enabled=false|settings#sliceBudgetMs=0.25|settings#refineMinLaps=12'
  local fourth = load(h)
  T.eq(fourth.settings.enabled, true)
  T.eq(fourth.settings.sliceBudgetMs, Config.defaults().sliceBudgetMs)
  T.eq(fourth.settings.refineMinLaps, 12)
end

tests['I03 explication par réglage (§12.2), équilibre par virage (§12.1)'] = function()
  local h = newHost()
  local app = load(h)
  T.ok(untilDone(h, app, function(a) return a.discoveryState == 'done' end))
  app.settings.optBudgetEvalsQ = 150
  h.click = 'Calculer le setup tour rapide'
  T.ok(untilDone(h, app, function(a) return a.quali and a.quali.state ~= 'running' end))
  T.eq(app.quali.state, 'done', tostring(app.quali.error))
  local r = app.quali.result
  T.ok(#r.changes > 0, 'des réglages changent')
  for _, c in ipairs(r.changes) do
    T.ok(c.explanation and c.explanation:find(c.var.label, 1, true) == 1, 'explication : ' .. tostring(c.explanation))
    T.ok(c.explanation:find('gain', 1, true) or c.explanation:find('coût', 1, true), c.explanation)
  end
  PY.note('I03', r.changes[1].explanation)
  T.ok(#r.cornersCurrent > 3 and #r.cornersProposed > 3, 'virages')
  for _, c in ipairs(r.cornersCurrent) do T.ok(c.balance > 0.5 and c.balance < 2 and c.s >= 0) end
  T.ok(r.stats.power > 0 and r.stats.fast >= 0)
  frame(h)
  -- tableau des réglages : l'explication s'affiche au survol du réglage (infobulle, tableau de bord du 21/10/2026)
  T.no(shown(h, r.changes[1].explanation), 'explication masquée hors survol')
  h.hover = true
  frame(h)
  h.hover = nil
  T.ok(shown(h, r.changes[1].explanation), 'explication affichée au survol')
  -- graphiques : section « Graphiques », fermée d'office en fenêtre étroite ; dépliée
  T.no(shown(h, 'Équilibre par virage'), 'section fermée : rien à dessiner')
  h.openSections = true
  frame(h)
  h.openSections = nil
  T.ok(shown(h, 'Équilibre par virage'), 'graphique d\'équilibre')
end

tests['I04 calibration d\'une séance précédente : reprise si la piste est comparable, sinon ignorée'] = function()
  local h = newHost()
  local entries = {}
  local key = Store.entryKey('cal', h.carId, 'monza', '-', 1)
  entries[key] = produced(h, { mu = 0.96, power = 0.98, drag = 1.02, lift = 1, brake = 1, roadTemp = 32, id_mu = true })
  h.stored = { [Store.KEY] = Store.serialize(entries) }
  local app = load(h)
  T.ok(untilDone(h, app, function(a) return a.discoveryState == 'done' end))
  local c = app.calibrations[app.discovery.compoundIndex]
  T.ok(c and c.result and c.result.stored, 'calibration reprise')
  T.near(c.result.factors.mu, 0.96, 1e-12)
  T.ok(c.result.identified.mu and not c.result.identified.power, 'facteurs identifiés relus')
  frame(h)
  T.ok(shown(h, 'modèle non calibré (calibration disponible)'), 'avant tout calcul')
  h.tab = 'Mesure'
  frame(h)
  T.ok(shown(h, 'Calibration reprise d\'une séance précédente'))
  h.tab = nil
  -- composé monté imposé : la calibration reprise est celle du composé du calcul
  app.settings.optBudgetEvalsQ = 40
  app.settings.compoundChoice = app.discovery.compoundIndex
  h.click = 'Calculer le setup tour rapide'
  T.ok(untilDone(h, app, function(a) return a.quali and a.quali.state ~= 'running' end))
  T.ok(app.quali.result.calibrated, 'calcul avec la calibration reprise')
  frame(h)
  T.ok(shown(h, 'modèle calibré ;'), 'bandeau aligné sur le calcul')
  -- dernier calcul terminé non calibré (course, plus récent) : le bandeau suit le dernier
  h.tab = 'Capacités'
  app.race = { state = 'done', result = { calibrated = false }, doneAt = (app.quali.doneAt or 0) + 1 }
  frame(h)
  T.ok(shown(h, 'modèle non calibré ;'), 'confiance du dernier calcul')
  app.race, h.tab = nil, nil
  -- piste à 15 °C de plus : ignorée, raison affichée
  local h2 = newHost()
  entries[key].roadTemp = 17
  h2.stored = { [Store.KEY] = Store.serialize(entries) }
  local app2 = load(h2)
  T.ok(untilDone(h2, app2, function(a) return a.discoveryState == 'done' end))
  T.eq(app2.calibrations[app2.discovery.compoundIndex], nil)
  T.contains(app2.storeNote, 'ignorée')
  h2.tab = 'Mesure'
  frame(h2)
  T.ok(shown(h2, 'Calibration d\'une séance précédente ignorée'))
  h2.tab = nil
  -- circuit avec disposition (« ks_red_bull_ring/layout_gp ») : la disposition fait partie de la clé (§13)
  local h3 = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'),
    track = require('fixtures/tracks/ks_red_bull_ring-layout_gp') })
  local layoutKey = Store.entryKey('cal', h3.carId, 'ks_red_bull_ring', 'layout_gp', 1)
  T.ok(layoutKey, 'clé avec disposition')
  entries = { [layoutKey] = produced(h3, { mu = 0.95, power = 1, drag = 1, lift = 1, brake = 1, roadTemp = 32 }) }
  h3.stored = { [Store.KEY] = Store.serialize(entries) }
  local app3 = load(h3)
  T.ok(untilDone(h3, app3, function(a) return a.discoveryState == 'done' end))
  local c3 = app3.calibrations[app3.discovery.compoundIndex]
  T.ok(c3 and c3.result and c3.result.stored, 'calibration reprise sur la disposition')
  T.near(c3.result.factors.mu, 0.95, 1e-12)
end

tests['I06 ABS relu au lancement du calcul (coupé en roulant après la découverte)'] = function()
  local h = newHost()
  local app = load(h)
  T.ok(untilDone(h, app, function(a) return a.discoveryState == 'done' end))
  app.settings.optBudgetEvalsQ = 40
  h.click = 'Calculer le setup tour rapide'
  T.ok(untilDone(h, app, function(a) return a.quali and a.quali.state ~= 'running' end))
  T.eq(app.quali.result.absActive, true)
  h.car.absMode = 0
  h.click = 'Calculer le setup tour rapide'
  frame(h)
  T.ok(untilDone(h, app, function(a) return a.quali and a.quali.state ~= 'running' end))
  T.eq(app.quali.result.absActive, false, 'ABS coupé après la découverte')
  frame(h)
  T.ok(shown(h, 'ABS coupé'))
  h.car.absMode = 1
end

tests['I05 valider en jeu sans tours : protocole affiché'] = function()
  local h = newHost()
  local app = load(h)
  T.ok(untilDone(h, app, function(a) return a.discoveryState == 'done' end))
  app.settings.optBudgetEvalsQ = 40
  h.click = 'Calculer le setup tour rapide'
  T.ok(untilDone(h, app, function(a) return a.quali and a.quali.state ~= 'running' end))
  h.click = 'Mesurer le gain réel'
  frame(h)
  T.contains(app.ui.message, 'tour propre avec le setup d\'origine')
  -- setup enregistré : rappelé à la séance suivante (§13)
  h.click = 'Enregistrer le setup tour rapide'
  frame(h)
  T.ok(app.quali.saved and app.quali.saved.ok, tostring(app.quali.saved and app.quali.saved.reason))
  for _ = 1, 90 do frame(h) end
  local again = load(h)
  T.ok(untilDone(h, again, function(a) return a.discoveryState == 'done' end))
  frame(h)
  T.ok(shown(h, 'Dernier setup tour rapide enregistré : ' .. app.quali.saved.name), 'rappel du dernier setup')
end

tests['I07 données stockées conformes au schéma mais douteuses : ignorées avec la raison (D9, D11)'] = function()
  local function boot(fields, roughFields)
    local h = newHost()
    local entries = {}
    entries[Store.entryKey('cal', h.carId, 'monza', '-', 1)] = produced(h, fields)
    if roughFields then entries[Store.entryKey('rough', h.carId, 'monza', '-')] = produced(h, roughFields) end
    h.stored = { [Store.KEY] = Store.serialize(entries) }
    local app = load(h)
    T.ok(untilDone(h, app, function(a) return a.discoveryState == 'done' end))
    return app
  end
  local good = { mu = 0.96, power = 0.98, drag = 1.02, lift = 1, brake = 1, roadTemp = 32 }
  local function with(change)
    local out = {}
    for key, value in pairs(good) do out[key] = value end
    for key, value in pairs(change) do out[key] = value end
    return out
  end
  -- facteur en butée de la calibration (puissance 1,05) : jamais présenté comme calibré
  local a = boot(with({ power = 1.05 }))
  T.eq(a.calibrations[a.discovery.compoundIndex], nil)
  T.contains(a.storeNote, 'facteur en butée')
  -- hors des bornes du producteur (puissance 2,5) : refusé dès la lecture
  local b = boot(with({ power = 2.5 }))
  T.eq(b.calibrations[b.discovery.compoundIndex], nil)
  -- autre version du modèle, autres fichiers de la voiture, température de piste inconnue
  local c = boot(with({ model = Config.K.modelVersion + 1 }))
  T.contains(c.storeNote, 'modèle')
  local d = boot(with({ data = 12345 }))
  T.contains(d.storeNote, 'fichiers de la voiture')
  local e = boot(with({ roadTemp = false }))
  T.contains(e.storeNote, 'température de piste inconnue')
  -- rugosité : avant et arrière incohérents (facteur 10) -> suspension conservée, raison
  local f = boot(good, { G0 = 2e-5, front = 1e-5, rear = 1e-4, speed = 50 })
  T.eq(f.discovery.conditions.roughness, nil)
  T.contains(f.storeNote, 'incohérents')
  T.eq(f.discovery.space.byKey.springF.class, require('src/setup_space').EXCLUDED)
  -- rugosité plausible et cohérente : reprise
  local g = boot(good, { G0 = 2e-5, front = 1.8e-5, rear = 2.2e-5, speed = 50 })
  T.near(g.discovery.conditions.roughness, 2e-5, 1e-15)
end

tests['I08 validation par genre (§14.1) : setups proposés distincts, verdict sous tolérance'] = function()
  local Ui = require('src/ui')
  local text, color = Ui.validationText({ state = 'done', predicted = 0.8, measured = 0.05, tolerance = 0.24, conforming = false })
  T.contains(text, 'Écart en jeu')
  T.contains(text, 'recalibrer')
  T.eq(color, 'pending')
  text, color = Ui.validationText({ state = 'done', predicted = 0.8, measured = 0.7, tolerance = 0.24, conforming = true })
  T.contains(text, 'Validé en jeu')
  T.eq(color, 'available')
  T.eq(Ui.validationText(nil), nil)
  local Calibration = require('src/calibration')
  local ok, tol = Calibration.verdict(0.8, 0.05)
  T.no(ok, '0,80 s prévu, 0,05 s mesuré : écart')
  T.near(tol, 0.24, 1e-12)
  T.ok((Calibration.verdict(0.8, 0.62)), 'à 30 % près')
  T.ok((Calibration.verdict(0.1, 0.24)), 'à 0,15 s près')
  T.no((Calibration.verdict(0.1, 0.26)))
  T.no((Calibration.verdict(0.5, -0.1)), 'mesuré négatif')
  -- qualification puis course enregistrées : deux setups proposés, aucune validation partagée
  local h = newHost()
  local app = load(h)
  T.ok(untilDone(h, app, function(a) return a.discoveryState == 'done' end))
  app.settings.optBudgetEvalsQ, app.settings.optBudgetEvalsC = 100, 20
  Fake.raceReady(h, app, 10)
  for _, kind in ipairs({ 'quali', 'race' }) do
    h.click = kind == 'race' and 'Calculer le setup course' or 'Calculer le setup tour rapide'
    T.ok(untilDone(h, app, function(a) return a[kind] and a[kind].state ~= 'running' end))
    T.eq(app[kind].state, 'done', tostring(app[kind].error))
    h.click = kind == 'race' and 'Enregistrer le setup course' or 'Enregistrer le setup tour rapide'
    frame(h)
    T.ok(app.proposals[kind], kind .. ' : setup proposé')
  end
  T.ok(app.proposals.quali ~= app.proposals.race, 'deux setups distincts')
  h.click = 'Mesurer le gain réel (course)'
  frame(h)
  T.contains(app.ui.message, 'tour propre')
  T.eq(app.validations.quali, nil)
  T.eq(app.validations.race, nil)
end

tests['I09 mode inerte (en ligne, replay) : aucune intention exécutée, rien d\'écrit'] = function()
  local h = newHost()
  h.stored = {} -- stockage vide au départ (ce test lit ce qui est écrit)
  local app = load(h)
  T.ok(untilDone(h, app, function(a) return a.discoveryState == 'done' end))
  h.sim.isOnlineRace = true
  T.ok(untilDone(h, app, function(a) return a.inert ~= nil end), 'inerte en ligne')
  local label
  for _, def in ipairs(Config.settings) do
    if def.key == 'refineMinLaps' then label = def.label end
  end
  h.sliders = { [label] = 13 }
  frame(h)
  T.no(app.settings.refineMinLaps == 13, 'réglage non modifié en ligne')
  -- réglage modifié juste avant le passage en ligne (écriture en attente) : rien n'est écrit en ligne
  h.sim.isOnlineRace = false
  T.ok(untilDone(h, app, function(a) return a.inert == nil end))
  app.nextContextAt = app.now + 30
  h.sliders = { [label] = 11 }
  frame(h)
  T.eq(app.settings.refineMinLaps, 11)
  h.sim.isOnlineRace = true
  T.ok(untilDone(h, app, function(a) return a.inert ~= nil end))
  app.nextContextAt = 0
  for _, button in ipairs({ 'Calibrer maintenant', 'Mesurer le gain réel', 'Copier le tour enregistré' }) do
    h.click = button
    frame(h)
  end
  for _ = 1, 90 do frame(h) end
  T.eq(h.stored and h.stored[Store.KEY], nil, 'aucune écriture du stockage en ligne')
  h.sim.isOnlineRace = false
end

tests['I10 onglet Course : gain en %, profils et équilibre par virage ; explications sans chiffre inventé'] = function()
  local h = newHost()
  local app = load(h)
  T.ok(untilDone(h, app, function(a) return a.discoveryState == 'done' end))
  app.settings.optBudgetEvalsC = 30
  Fake.raceReady(h, app, 10)
  h.click = 'Calculer le setup course'
  T.ok(untilDone(h, app, function(a) return a.race and a.race.state ~= 'running' end))
  T.eq(app.race.state, 'done', tostring(app.race.error))
  local r = app.race.result
  T.ok(r.profileCurrent and r.profileProposed and #r.cornersCurrent > 0 and #r.cornersProposed > 0)
  h.tab = 'Course'
  frame(h)
  -- gain en % visible (étiquette de la tuile), la phrase complète au survol
  local pct = shown(h, 'Gain par tour · ')
  T.ok(pct and pct:find(' %', 1, true), 'gain en % : ' .. tostring(pct))
  T.no(shown(h, 's par tour, '), 'phrase complète masquée hors survol')
  h.hover = true
  frame(h)
  h.hover = nil
  T.ok(shown(h, 's par tour, '), 'phrase complète au survol')
  h.openSections = true
  frame(h)
  h.openSections = nil
  T.ok(shown(h, 'Équilibre par virage'))
  h.tab = nil
  for _, c in ipairs(r.changes) do
    T.ok(c.explanation:find(c.var.label, 1, true) == 1, c.explanation)
    T.no(c.explanation:find('—', 1, true), 'aucune valeur manquante affichée : ' .. c.explanation)
    T.no(c.explanation:find('0 % -> 0 %', 1, true), c.explanation)
    T.no(c.explanation:find(' :  ;', 1, true), 'clause vide : ' .. c.explanation)
  end
end

tests['I11 onglets par usage et séance détectée (décision du 20/10/2026) ; découverte en échec : raison et relance'] = function()
  local Ui = require('src/ui')
  T.contains(Ui.sessionLine({ sessionType = 1 }), 'essai ou journée circuit — onglet Tour rapide')
  T.contains(Ui.sessionLine({ sessionType = 4 }), 'hotlap — onglet Tour rapide')
  T.contains(Ui.sessionLine({ sessionType = 5 }), 'time attack — onglet Tour rapide')
  T.contains(Ui.sessionLine({ sessionType = 2 }), 'qualification — onglet Tour rapide')
  T.contains(Ui.sessionLine({ sessionType = 3 }), 'onglet Course')
  T.eq(Ui.sessionLine({ sessionType = 0 }), nil)
  T.eq(Ui.sessionLine(nil), nil)
  local h = newHost()
  h.sim.raceSessionType = 1
  local app = load(h)
  T.ok(untilDone(h, app, function(a) return a.discoveryState == 'done' end))
  frame(h)
  T.ok(shown(h, 'Séance : essai ou journée circuit — onglet Tour rapide'), 'bandeau : séance détectée')
  T.ok(shown(h, 'Tour rapide : essai, journée circuit, hotlap, time attack, qualification'), 'onglet Tour rapide')
  -- découverte en échec : la raison exacte et un bouton de relance, jamais « non terminée »
  app.discoveryState, app.discoveryError = 'failed', 'erreur simulée'
  T.contains(app.qualiBlocker(), 'découverte en échec (erreur simulée)')
  frame(h)
  T.ok(shown(h, 'Calcul indisponible : découverte en échec (erreur simulée)'))
  h.tab = 'Course'
  frame(h)
  T.ok(shown(h, 'Calcul indisponible : découverte en échec (erreur simulée)'), 'onglet Course : raison')
  h.click = 'Relancer la découverte (course)'
  frame(h)
  T.eq(app.discoveryState, 'running', 'relance depuis l\'onglet Course')
  h.tab = nil
  T.ok(untilDone(h, app, function(a) return a.discoveryState == 'done' end))
  app.discoveryState, app.discoveryError = 'failed', 'erreur simulée'
  -- bouton de l'onglet Tour rapide lui-même (l'onglet Capacités en a un aussi)
  h.tab = 'Tour rapide'
  frame(h)
  h.click = 'Relancer la découverte'
  frame(h)
  h.tab = nil
  T.eq(app.discoveryState, 'running', 'relance depuis l\'onglet')
  T.ok(untilDone(h, app, function(a) return a.discoveryState == 'done' end))
  T.eq(app.qualiBlocker(), nil)
end

-- Rapport de Vincent (20/10/2026) : « pas de calcul en journée circuit ». Chaque type de séance de CSP,
-- et la journée circuit (essai avec voitures IA, voiture en piste) : calcul disponible, bouton présent.
tests['I12 tous les types de séance (essai, journée circuit, qualification, course, hotlap, time attack, drift, drag)'] = function()
  local cases = { { 0, 1, true }, { 1, 1, true }, { 1, 30, false }, { 2, 1, true }, { 3, 1, true }, { 4, 1, false },
    { 5, 1, false }, { 6, 1, true }, { 7, 1, true } }
  for _, case in ipairs(cases) do
    local label = 'type ' .. case[1] .. ', ' .. case[2] .. ' voiture(s), ' .. (case[3] and 'stand' or 'piste')
    local h = newHost()
    h.sim.raceSessionType, h.sim.carsCount = case[1], case[2]
    h.car.isInPit, h.car.isInPitlane = case[3], case[3]
    local app = load(h)
    local buttons = {}
    local button = h.ui.button
    h.ui.button = function(s)
      buttons[s:match('^(.-)###') or s] = true
      return button(s)
    end
    T.ok(untilDone(h, app, function(a) return a.discoveryState == 'done' end), label .. ' : découverte')
    buttons = {}
    frame(h)
    T.eq(app.inert, nil, label .. ' : pas inerte')
    T.eq(app.qualiBlocker(), nil, label .. ' : calcul disponible')
    T.ok(buttons['Calculer le setup tour rapide'], label .. ' : bouton présent')
    T.no(shown(h, 'Calcul indisponible'), label .. ' : aucun refus affiché')
  end
end

-- Tableau de bord (demande de Vincent du 21/10/2026 : interface épurée, dense, adaptée à la largeur) :
-- chaque onglet dessiné à 360, 520, 730 et 900 px avec résultats tour rapide et course, affinage actif et
-- chargement armé ; aucune erreur, aucun identifiant ImGui en double (le faux hôte le vérifie), volets
-- côte à côte seulement en fenêtre large, tableau des réglages réduit en fenêtre étroite.
tests['I13 tableau de bord : 360, 520, 730 et 900 px, tous les onglets, aucun identifiant en double'] = function()
  local h = newHost()
  local app = load(h)
  T.ok(untilDone(h, app, function(a) return a.discoveryState == 'done' end))
  app.settings.optBudgetEvalsQ, app.settings.optBudgetEvalsC = 60, 20
  Fake.raceReady(h, app, 10)
  h.click = 'Calculer le setup tour rapide'
  T.ok(untilDone(h, app, function(a) return a.quali and a.quali.state ~= 'running' end))
  h.click = 'Calculer le setup course'
  T.ok(untilDone(h, app, function(a) return a.race and a.race.state ~= 'running' end))
  T.eq(app.race.state, 'done', tostring(app.race.error))
  h.click = 'Enregistrer le setup tour rapide'
  frame(h)
  h.click = 'Enregistrer le setup course'
  frame(h)
  T.ok(app.saved.quali and app.saved.race, 'deux setups enregistrés')
  -- affinage course actif (sa carte porte le chargement course), chargement tour rapide armé
  app.refine = { kind = 'race', active = true, phase = 'tours', version = 1, laps = 1, history = {
    { version = 1, file = app.saved.race.name, signature = app.saved.race.signature, timeCurrent = 120, timeProposed = 119.5,
      gain = 0.5, changes = 2 },
    { timeCurrent = 119.5, timeProposed = 119.5, gain = 0, changes = 0, note = 'setup actuel conservé : le meilleur trouvé' },
  } }
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  h.click = 'Charger le setup tour rapide dans la voiture'
  frame(h)
  T.ok(app.loadArm and app.loadArm.kind == 'quali', tostring(app.ui.message))
  h.hover, h.openSections = true, true -- infobulles et sections fermées comprises
  for _, width in ipairs({ 360, 520, 730, 900 }) do
    h.width, h.nodes = width, {}
    frame(h)
    T.eq(app.perf.errors, 0, width .. ' px : ' .. tostring(app.ui.message))
    T.ok(shown(h, 'Remplace le setup en cours'), width .. ' px : avertissement du chargement armé')
    T.ok(shown(h, 'Affinage course — v1'), width .. ' px : carte d\'affinage')
    T.ok(shown(h, 'Tour moyen du relais'), width .. ' px : résultat course')
    T.ok(shown(h, 'Tour prévu : actuel'), width .. ' px : résultat tour rapide')
    local plots = 0
    for _, label in ipairs(h.nodes) do
      if label == 'Graphiques' then plots = plots + 1 end
    end
    T.eq(plots, width >= Config.K.uiWide and 0 or 2, width .. ' px : graphiques à droite en fenêtre large, repliés sinon')
    T.eq(shown(h, 'Crans') ~= nil, width >= Config.K.uiNarrow, width .. ' px : colonne des crans seulement si la place le permet')
  end
  h.width, h.hover, h.openSections = 520, nil, nil
end

return tests
