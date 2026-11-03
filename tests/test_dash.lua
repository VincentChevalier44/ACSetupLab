-- Pages « Racing 26 » (src/dash.lua, maquette de Vincent ; décision du 03/11/2026 : « tout refaire, puis publier ») : chaque
-- état du parcours dessiné sur les 7 onglets, l'overlay et la fenêtre Debug, étroit et large, en français et en anglais,
-- sans erreur ni identifiant ImGui en double (le faux hôte les refuse) ; les actions gardent leurs identifiants.
local T = require('t')
local Fake = require('fakehost')
local Config = require('src/config')

local tests = {}

local STORE = { en = 'setuplab-store 1|settings#language=s:en', fr = 'setuplab-store 1|settings#language=s:fr' }
local TABS = { 'Tour rapide', 'Course', 'Mémoire', 'Mesure', 'Réglages', 'Capacités', 'Aide' }

local function boot(lang)
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza'),
    skin = true, lang = lang, stored = { ['setuplab:data'] = STORE[lang] } })
  h.sim.raceSessionType = 1
  h.texts = {}
  local text, wrapped, colored = h.ui.text, h.ui.textWrapped, h.ui.textColored
  h.ui.text = function(s) h.texts[#h.texts + 1] = s; return text(s) end
  h.ui.textWrapped = function(s) h.texts[#h.texts + 1] = s; return wrapped(s) end
  h.ui.textColored = function(s, c) h.texts[#h.texts + 1] = s; return colored(s, c) end
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  app.utcOffset = function() return 7200 end
  app.settings.optBudgetEvalsQ, app.settings.optBudgetEvalsC = 60, 20
  app.settings.refineMinLaps = 0
  return h, app
end

local function frames(h, n)
  for _ = 1, n do
    h.sim.time = h.sim.time + 1000 / 60
    h.texts = {}
    script.SETUPLAB__UPDATE(1 / 60)
    script.SETUPLAB__MAIN(1 / 60)
  end
end

local function waitFor(h, predicate, maxFrames)
  for _ = 1, maxFrames or 60000 do
    frames(h, 1)
    if predicate() then return true end
  end
  return false
end

local function pits(h) h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0 end

-- chaque onglet, l'overlay et Debug, à chaque largeur
local function drawAll(h, app, what)
  for _, width in ipairs({ 404, 520, 764 }) do
    h.width = width
    for _, tab in ipairs(TABS) do
      h.tab = tab
      frames(h, 2)
      T.eq(app.ui.tab, tab, what .. ' : onglet ' .. tab)
    end
    h.tab = nil
    h.ids, h.idScope = {}, ''
    script.SETUPLAB__OVERLAY(1 / 60)
    script.SETUPLAB__DEBUG(1 / 60)
  end
  T.eq(app.perf.errors, 0, what .. ' : aucune erreur de dessin')
end

for _, lang in ipairs({ 'fr', 'en' }) do
  tests['DS01 pages Racing 26 (' .. lang .. ') : départ, v1, essai, Modifier ouvert, validée, course'] = function()
    local h, app = boot(lang)
    T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
    pits(h)
    drawAll(h, app, 'départ')
    app.settings.compoundChoice = app.discovery.compoundIndex
    app.handleIntents({ start = { kind = 'quali', mode = 'mine' } })
    local r = app.refine
    T.ok(waitFor(h, function() return r and r.version >= 1 and r.phase == 'tours' end), 'v1')
    pits(h)
    drawAll(h, app, 'v1 proposée')
    local e = r.history[#r.history]
    app.handleIntents({ refineJudge = { version = e.version, verdict = 'essayer' } })
    T.ok(waitFor(h, function() return app.loadCheck == nil end), 'essai chargé')
    app.ui.modify = app.ui.modify or {}
    app.ui.modify['quali_' .. e.version] = true
    drawAll(h, app, 'essai, Modifier ouvert')
    -- Gardé | Refusé : même identifiant et même intention que le bouton ImGui
    local item = e.groups[1].items[1]
    h.tab = 'Tour rapide'
    h.click = 'effect_quali_' .. e.version .. '_' .. item.key
    frames(h, 2)
    T.eq(item.keep, false, 'refusé d\'un clic')
    h.click = 'effect_quali_' .. e.version .. '_' .. item.key
    frames(h, 2)
    T.eq(item.keep, true, 'gardé de nouveau')
    app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
    T.eq(e.status, 'validée', tostring(app.ui.message))
    T.ok(waitFor(h, function() return app.loadCheck == nil end), 'version gardée dans la voiture')
    drawAll(h, app, 'validée, question continuer ou figer')
    -- continuer, puis la course depuis la qualif validée
    h.tab = 'Tour rapide'
    h.click = 'step_continue'
    frames(h, 2)
    T.eq(r.choice, nil, 'continuer l\'affinage : question réglée')
    app.handleIntents({ raceLaps = 12 })
    h.tab = 'Course'
    frames(h, 2)
    drawAll(h, app, 'départ de la course')
    h.tab = 'Course'
    h.click = 'race_from_' .. e.file
    frames(h, 2)
    T.ok(app.refine and app.refine.kind == 'race', 'course partie de la qualif : ' .. tostring(app.ui.message))
    T.ok(waitFor(h, function() return app.race ~= nil and app.race.state == 'done' end), 'calcul de course')
    pits(h)
    drawAll(h, app, 'course en affinage')
    h.tab = nil
  end
end

-- une image de l'overlay
local function overlayFrame(h)
  h.texts = {}
  h.ids, h.idScope = {}, ''
  script.SETUPLAB__OVERLAY(1 / 60)
end

local function shownText(h, needle)
  for _, s in ipairs(h.texts) do
    if type(s) == 'string' and s:find(needle, 1, true) then return true end
  end
  return false
end

-- relecture du 03/11/2026 : un calcul à la main à l'étape 1 montre son résultat ; enregistré, il offre « Charger » (barre
-- verte, même libellé que l'ImGui), qui met le setup dans la voiture ; une version validée hors du stand aussi
tests['DS02 pages Racing 26 : résultat d\'un calcul à la main à l\'étape 1, « Charger » toujours offert'] = function()
  local h, app = boot('fr')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  pits(h)
  app.settings.compoundChoice = app.discovery.compoundIndex
  app.handleIntents({ qualiStart = true })
  T.ok(waitFor(h, function() return app.quali and app.quali.state == 'done' end), 'calcul à la main')
  for _, width in ipairs({ 404, 764 }) do
    h.width, h.tab = width, 'Tour rapide'
    frames(h, 2)
    T.ok(shownText(h, 'D\'OÙ PART-ON ?'), 'étape 1 : choix du départ')
    T.ok(shownText(h, 'RÉGLAGES CHANGÉS'), 'étape 1 : le résultat du calcul à la main est montré (' .. width .. ' px)')
  end
  app.handleIntents({ qualiSave = true })
  T.ok(app.saved and app.saved.quali, 'setup enregistré : ' .. tostring(app.ui.message))
  frames(h, 2)
  T.ok(shownText(h, 'ENREGISTRÉ · PAS ENCORE DANS LA VOITURE'), 'barre de chargement')
  h.click = 'Charger le setup tour rapide dans la voiture'
  frames(h, 1)
  T.ok(app.loadCheck or (app.loadTest and app.loadTest.ok), 'chargement demandé en un clic : ' .. tostring(app.ui.message))
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'constat du chargement')
  T.ok(app.loadTest and app.loadTest.ok, tostring(app.loadTest and app.loadTest.reason))
  frames(h, 2)
  T.no(shownText(h, 'ENREGISTRÉ · PAS ENCORE DANS LA VOITURE'), 'dans la voiture : plus de barre de chargement')
  T.eq(app.perf.errors, 0, 'aucune erreur de dessin')
  h.tab = nil
end

-- Barre de l'overlay (demande de Vincent du 03/11/2026 : titre coupé par la barre de CSP ; cadenas pour figer l'overlay à
-- un endroit précis, réduire, fermer) : la barre de CSP retirée, la barre SetupLab dessinée ; cadenas (position et taille
-- figées), glisser la barre (déplace, sauf verrouillé), réduire (hauteur de la barre) puis déplier (hauteur d'avant),
-- fermer ; cadenas et réduit gardés d'une séance à l'autre.
tests['DS03 barre de l\'overlay : cadenas, glisser, réduire, fermer, gardés'] = function()
  local h, app = boot('fr')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  local w = h.appWindow
  overlayFrame(h)
  T.ok(shownText(h, 'SETUP') and shownText(h, 'LAB'), 'barre : nom')
  T.ok(shownText(h, 'EN VEILLE'), 'barre : état')
  T.ok(shownText(h, 'Cochez « SetupLab actif »'), 'corps : la phrase de la veille')
  T.eq(w.moves + w.resizes, 0, 'rien ne bouge tout seul')
  -- glisser la barre : la fenêtre suit
  h.itemActive, h.mouseDelta = true, { x = 12, y = -4 }
  overlayFrame(h)
  h.itemActive, h.mouseDelta = nil, nil
  T.eq(w.x, 112)
  T.eq(w.y, 76, 'glisser la barre déplace l\'overlay')
  -- cadenas : position et taille figées, glisser ne bouge plus rien
  h.click = 'overlay_lock'
  overlayFrame(h)
  T.eq(app.settings.overlayLocked, true, 'cadenas fermé')
  overlayFrame(h)
  w.x, w.y, w.w = 300, 300, 500
  overlayFrame(h)
  T.eq(w.x, 112)
  T.eq(w.y, 76, 'verrouillé : remis à sa place')
  T.eq(w.w, 420, 'verrouillé : taille gardée')
  h.itemActive, h.mouseDelta = true, { x = 40, y = 40 }
  overlayFrame(h)
  h.itemActive, h.mouseDelta = nil, nil
  T.eq(w.x, 112, 'verrouillé : glisser ne déplace pas')
  -- réduire : la barre seule (avec l'état) ; déplier : la hauteur d'avant
  h.click = 'overlay_mini'
  overlayFrame(h)
  T.eq(app.settings.overlayMini, true, 'réduit')
  overlayFrame(h)
  T.eq(w.h, 30, 'réduit : hauteur de la barre')
  T.ok(shownText(h, 'EN VEILLE'), 'réduit : la barre reste')
  T.no(shownText(h, 'Cochez « SetupLab actif »'), 'réduit : plus de corps')
  h.click = 'overlay_mini'
  overlayFrame(h)
  overlayFrame(h)
  T.eq(app.settings.overlayMini, false)
  T.eq(w.h, 230, 'déplié : la hauteur d\'avant')
  -- gardés d'une séance à l'autre (réglages modifiables)
  local saved = false
  for _, key in ipairs(Config.EDITABLE) do if key == 'overlayLocked' then saved = true end end
  T.ok(saved, 'cadenas gardé avec les réglages')
  -- déverrouiller, puis fermer
  h.click = 'overlay_lock'
  overlayFrame(h)
  T.eq(app.settings.overlayLocked, false, 'cadenas ouvert')
  h.click = 'overlay_close'
  overlayFrame(h)
  T.eq(w.visible, false, 'fermé (la barre d\'apps de CSP le rouvre)')
  -- en veille (session en ligne) aussi, la barre répond
  T.eq(app.perf.errors, 0, 'aucune erreur de dessin')
end

-- Sans accès aux fenêtres d'app (CSP qui ne le permet pas) : la barre est dessinée, sans Fermer ; rien ne casse.
tests['DS04 barre de l\'overlay sans accès aux fenêtres d\'app'] = function()
  local h, app = boot('en')
  h.ac.getAppWindows, h.ac.accessAppWindow = nil, nil
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  overlayFrame(h)
  T.ok(shownText(h, 'STANDBY'), 'barre en anglais : état')
  T.no(h.ids and h.ids['overlay_close'], 'pas de bouton Fermer')
  h.click = 'overlay_lock'
  overlayFrame(h)
  T.eq(app.settings.overlayLocked, true, 'cadenas : préférence gardée même sans accès')
  T.eq(app.perf.errors, 0)
end

-- Constat de Vincent du 03/11/2026 : parti de son setup (ou du setup par défaut), tour propre fait, rien dans l'overlay
-- alors que v1 était prête. Aucune version de SetupLab dans la voiture : la version proposée s'annonce quand même, avec
-- ce qu'il faut faire (rentrer au stand, « Essayer ») ; avant elle, ce qu'il reste à faire.
tests['DS05 overlay : v1 annoncée quand la voiture a votre setup ou celui par défaut'] = function()
  for _, mode in ipairs({ 'mine', 'default' }) do
    local h, app = boot('fr')
    T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
    pits(h)
    app.settings.compoundChoice = app.discovery.compoundIndex
    app.settings.refineMinLaps = 1
    app.handleIntents({ start = { kind = 'quali', mode = mode } })
    T.ok(waitFor(h, function() return app.loadCheck == nil end), mode .. ' : départ dans la voiture')
    local r = app.refine
    T.ok(r and r.active, mode .. ' : affinage lancé')
    if r.version == 0 and r.waiting then
      overlayFrame(h)
      T.ok(shownText(h, r.waiting), mode .. ' : ce qu\'il reste à faire est affiché')
    end
    app.settings.refineMinLaps = 0
    T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end), mode .. ' : v1')
    overlayFrame(h)
    T.ok(shownText(h, 'V1 PRÊTE'), mode .. ' : v1 annoncée dans l\'overlay')
    T.ok(shownText(h, 'Rentrez au stand'), mode .. ' : ce qu\'il faut faire')
    T.eq(app.perf.errors, 0, mode .. ' : aucune erreur de dessin')
  end
end

-- Constat de Vincent du 03/11/2026 : qualif v1 chargée, affinage de course lancé, « À faire : saisir le nombre de tours »
-- mais aucune saisie sur la page COURSE. Le nombre de tours est sous la carte d'étape pendant l'affinage de course.
tests['DS06 course : nombre de tours saisissable pendant l\'affinage de course'] = function()
  local h, app = boot('fr')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  pits(h)
  app.settings.compoundChoice = app.discovery.compoundIndex
  app.handleIntents({ start = { kind = 'quali', mode = 'mine' } })
  local r = app.refine
  T.ok(waitFor(h, function() return r and r.version >= 1 and r.phase == 'tours' end), 'v1')
  local e = r.history[#r.history]
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'v1 validée dans la voiture')
  app.raceLaps = nil
  app.handleIntents({ refineStart = 'race' })
  local rr = app.refine
  T.ok(rr and rr.active and rr.kind == 'race', 'affinage de course lancé : ' .. tostring(app.ui.message))
  h.tab = 'Course'
  frames(h, 2)
  T.ok(shownText(h, 'TOURS DE LA COURSE'), 'le nombre de tours est sur la page')
  h.click = 'race_laps_plus'
  frames(h, 2)
  T.eq(app.raceLaps, 1, 'le + règle le nombre de tours')
  h.click = 'race_laps_plus'
  frames(h, 2)
  T.eq(app.raceLaps, 2)
  h.width = 404
  frames(h, 2)
  T.ok(shownText(h, 'TOURS DE LA COURSE'), 'en étroit aussi')
  T.eq(app.perf.errors, 0, 'aucune erreur de dessin')
  h.tab = nil
end

-- Demande de Vincent du 03/11/2026 : « Réglages du setup » (onglet RÉGLAGES) se replie, fermé par défaut.
tests['DS07 réglages : tableau des réglages du setup repliable, fermé par défaut'] = function()
  local h, app = boot('fr')
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  h.tab = 'Réglages'
  frames(h, 2)
  T.ok(shownText(h, 'RÉGLAGES DU SETUP'), 'en-tête')
  T.no(shownText(h, 'Survol d\'une ligne'), 'fermé par défaut')
  T.no(h.ids and h.ids['status_1'], 'lignes absentes')
  h.click = 'setup_status_toggle'
  frames(h, 2)
  T.ok(shownText(h, 'Survol d\'une ligne'), 'ouvert d\'un clic')
  h.click = 'setup_status_toggle'
  frames(h, 2)
  T.no(shownText(h, 'Survol d\'une ligne'), 'refermé')
  T.eq(app.perf.errors, 0)
  h.tab = nil
end

return tests
