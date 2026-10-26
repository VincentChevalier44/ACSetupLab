-- Tests d'intégration de la colle SetupLab.lua : chargée telle quelle, avec l'hôte simulé
-- installé comme globales CSP, et pilotée par ses rappels de manifest.
local T = require('t')
local Config = require('src/config')
local Fake = require('fakehost')
local Ui = require('src/ui')

local tests = {}

local function Util_busy(app)
  return #app.scheduler.queue > 0 or app.scheduler.current ~= nil
end

local function boot(carId, trackId, opts)
  opts = opts or {}
  opts.car = require('fixtures/cars/' .. (carId or 'lamborghini_huracan_gt3_evo2'))
  opts.track = require('fixtures/tracks/' .. (trackId or 'spa'))
  local h = Fake.new(opts)
  Fake.install(h)
  local chunk = assert(loadfile(PY.appDir .. '/SetupLab.lua'))
  chunk()
  local S = rawget(_G, 'SETUPLAB')
  return h, S, S.app
end

local function frames(h, n, dtMs)
  dtMs = dtMs or 16.7
  for _ = 1, n do
    h.sim.time = h.sim.time + dtMs
    script.SETUPLAB__UPDATE(dtMs / 1000)
    script.SETUPLAB__MAIN(dtMs / 1000)
    script.SETUPLAB__DEBUG(dtMs / 1000)
  end
end

local function untilDone(h, app, maxFrames)
  for i = 1, maxFrames or 5000 do
    frames(h, 1)
    if app.discoveryState == 'done' and app.report ~= nil then return i end
  end
  return nil
end

tests['A01 découverte complète depuis la colle'] = function()
  local h, S, app = boot()
  T.eq(S.version, require('src/config').version)
  local n = untilDone(h, app)
  T.ok(n, 'découverte terminée')
  T.ok(n > 3, 'répartie sur plusieurs frames (' .. tostring(n) .. ')')
  T.eq(app.perf.errors, 0)
  T.ok(app.report and #app.report > 2000, 'rapport J0 construit')
  T.ok(app.discovery.durationMs > 0, 'durée de calcul mesurée')
  T.contains(app.report, 'Durée de la découverte')
  T.eq(h.writeCalls, 0, 'aucune écriture')
  T.ok(h.uiCalls > 0)
  T.eq(app.discovery.caps.byId.car_ini.status, 'available')
  T.ok(app.clock ~= nil, 'horloge QPC sur le banc')
end

tests['A02 budget : p90 ≤ 2,2 ms, p99 ≤ 3 ms, ≤ 1 % au-delà de 3 ms, hors calcul < 0,3 ms'] = function()
  -- Une découverte de chauffe par hôte est exclue : elle paie l'analyse non mise en cache des INI
  -- simulés (en jeu : coût natif de CSP, mesuré par slowestReadMs et rapporté au J0) et la
  -- compilation JIT. Les tranches mesurées ensuite reflètent la découpe propre à SetupLab.
  -- Un ramasse-miettes complet précède chaque découverte mesurée (hors mesure) : ses pauses dépendent
  -- du tas total, ici gonflé par les jeux de données et l'hôte simulé ; la part de l'app, la quantité
  -- de déchets produite, est bornée par A19. La mesure en temps réel subit la préemption du système
  -- (une itération de deux appels à l'hôte relevée à 3 ms) : meilleure de trois séries, un défaut de
  -- découpage échouerait aux trois.
  local function series()
    local samples = {}
    for _, case in ipairs({ { 'urd_px1_aura', 'spa' }, { 'whk_dtm_2026', 'spa' }, { 'lamborghini_huracan_gt3_evo2', 'monza' } }) do
      local h, _, app = boot(case[1], case[2])
      T.ok(untilDone(h, app), 'découverte de chauffe')
      for _ = 1, 10 do
        collectgarbage('collect')
        h.click = 'Relancer la découverte'
        frames(h, 1)
        local last = app.scheduler.stats.slices
        for _ = 1, 5000 do
          frames(h, 1)
          local st = app.scheduler.stats
          if st.slices ~= last then
            last = st.slices
            samples[#samples + 1] = st.lastSliceMs
          end
          if app.discoveryState == 'done' and app.report ~= nil then break end
        end
      end
      T.eq(app.perf.errors, 0)
    end
    table.sort(samples)
    local over = 0
    for _, v in ipairs(samples) do
      if v > 3 then over = over + 1 end
    end
    local function q(p) return samples[math.ceil(#samples * p)] end
    return { n = #samples, p50 = q(0.5), p90 = q(0.9), p99 = q(0.99), max = samples[#samples], over = over }
  end
  local best
  for round = 1, 3 do
    local r = series()
    PY.note('A02 série ' .. round, string.format('n=%d p50=%.3f p90=%.3f p99=%.3f max=%.3f >3ms=%d', r.n, r.p50, r.p90,
      r.p99, r.max, r.over))
    T.ok(r.n > 150, r.n .. ' tranches mesurées')
    r.pass = r.p90 <= 2.2 and r.p99 <= 3.0 and r.over <= r.n * 0.01
    if best == nil or (r.pass and not best.pass) or (r.pass == best.pass and r.p99 < best.p99) then best = r end
    if r.pass then break end
  end
  T.ok(best.p90 <= 2.2, '90e centile ' .. best.p90 .. ' ms : budget de 2 ms + 10 %')
  T.ok(best.p99 <= 3.0, '99e centile ' .. best.p99 .. ' ms : pic du §14.3')
  T.ok(best.over <= best.n * 0.01, best.over .. ' tranches au-delà de 3 ms sur ' .. best.n)
  local h, _, app = boot()
  T.ok(untilDone(h, app))
  frames(h, 400)
  T.ok(app.perf.avgMs < 0.3, 'coût moyen ' .. app.perf.avgMs .. ' ms (§14.3)')
end

tests['A03 session en ligne : inerte, puis reprise hors ligne'] = function()
  local h, _, app = boot()
  h.sim.isOnlineRace = true
  frames(h, 200)
  T.ok(app.inert and app.inert:find('en ligne'), tostring(app.inert))
  T.eq(app.discoveryState, 'idle')
  T.eq(h.calls.readDataFile, nil, 'aucune lecture de données en ligne')
  h.sim.isOnlineRace = false
  T.ok(untilDone(h, app), 'reprise hors ligne')
  T.eq(app.inert, nil)
end

tests['A04 replay pendant la découverte : annulation puis reprise'] = function()
  local h, _, app = boot()
  frames(h, 1)
  T.eq(app.discoveryState, 'running')
  h.sim.isReplayActive = true
  app.nextContextAt = 0
  frames(h, 1)
  T.ok(app.inert and app.inert:find('Replay'))
  T.eq(app.discoveryState, 'idle')
  T.ok(app.scheduler.stats.cancelled >= 1)
  h.sim.isReplayActive = false
  T.ok(untilDone(h, app))
end

tests['A05 changement de voiture : résultats périmés et nouvelle découverte'] = function()
  local h, _, app = boot()
  T.ok(untilDone(h, app))
  h.carId = 'autre_voiture'
  app.nextContextAt = 0
  frames(h, 1)
  T.eq(app.discoveryState, 'running')
  T.eq(app.discovery, nil, 'anciens résultats effacés')
  T.ok(untilDone(h, app))
  T.eq(app.discovery.car.id, 'autre_voiture')
end

tests['A06 copie du rapport J0 dans le presse-papiers'] = function()
  local h, _, app = boot()
  h.click = 'Copier le rapport J0'
  frames(h, 1)
  T.contains(app.ui.message, 'Aucun rapport')
  T.ok(untilDone(h, app))
  h.click = 'Copier le rapport J0'
  frames(h, 1)
  T.eq(h.clipboard, app.report)
  T.contains(app.ui.message, 'copié')
  h.ac.setClipboardText = function() return false end
  h.click = 'Copier le rapport J0'
  frames(h, 1)
  T.contains(app.ui.message, 'Copie impossible')
end

tests['A07 relance de la découverte à la demande'] = function()
  local h, _, app = boot()
  T.ok(untilDone(h, app))
  local completed = app.scheduler.stats.completed
  h.click = 'Relancer la découverte'
  frames(h, 1)
  T.eq(app.discoveryState, 'running')
  T.ok(untilDone(h, app))
  T.eq(app.scheduler.stats.completed, completed + 2, 'découverte puis rapport')
end

tests['A08 rechargement du script : instance précédente libérée'] = function()
  local h1, S1, app1 = boot()
  frames(h1, 1)
  T.ok(app1.discoveryState == 'running')
  local oldUpdate, oldMain = script.SETUPLAB__UPDATE, script.SETUPLAB__MAIN
  local _, S2 = boot()
  T.ok(app1.released)
  T.eq(h1.disposed, 1, 'rappel onRelease désinscrit')
  T.no(S1 == S2)
  T.eq(rawget(_G, 'SETUPLAB'), S2)
  T.no(#app1.scheduler.queue > 0 or app1.scheduler.current ~= nil)
  local slices, calls = app1.scheduler.stats.slices, h1.uiCalls
  oldUpdate(0.016)
  oldMain(0.016)
  T.eq(app1.scheduler.stats.slices, slices, 'l\'ancienne instance ne calcule plus')
  T.eq(h1.uiCalls, calls, 'ni ne dessine')
end

tests['A09 API défaillante : aucune erreur propagée'] = function()
  local throwing = {}
  local h0 = Fake.new({ car = require('fixtures/cars/formula_k'), track = require('fixtures/tracks/monza') })
  for name, value in pairs(h0.ac) do
    if type(value) == 'function' and name ~= 'getSim' and name ~= 'getCarID' and name ~= 'getTrackFullID' then
      throwing[#throwing + 1] = 'ac.' .. name
    end
  end
  for _, path in ipairs({ 'ac.INIConfig.carData', 'ac.INIConfig.trackData', 'ac.DataLUT11.carData',
    'physics.raycastTrack', 'io.load', 'io.available' }) do
    throwing[#throwing + 1] = path
  end
  local h, _, app = boot('formula_k', 'monza', { throwing = throwing })
  T.ok(untilDone(h, app))
  T.eq(app.perf.errors, 0)
  local counts = require('src/caps').countByStatus(app.discovery.caps)
  T.ok(counts.unavailable >= 5, counts.unavailable .. ' indisponibles')
  local h2, _, app2 = boot('formula_k', 'monza', { throwing = { 'ac.getSim' } })
  frames(h2, 10)
  T.ok(app2.inert and app2.inert:find('Contexte illisible'))
  T.eq(app2.perf.errors, 0)
end

tests['A10 garde de frame et images/s faibles'] = function()
  local h, _, app = boot()
  app.settings.frameGuardMs = 1e-9
  frames(h, 30)
  T.ok(app.perf.guardSkips > 0, 'tranches sautées')
  T.eq(app.discoveryState, 'running', 'calcul suspendu')
  app.settings.frameGuardMs = 4
  h.sim.fps = 30
  T.ok(untilDone(h, app))
  T.ok(app.perf.slowFrames > 0, 'tranches réduites sous 60 images/s')
end

tests['A11 interface : tous les états, aucune écriture'] = function()
  local h, _, app = boot()
  T.ok(untilDone(h, app))
  app.discoveryState, app.discoveryError = 'failed', 'panne simulée'
  frames(h, 1)
  local line, kind = Ui.statusLine(app)
  T.contains(line, 'panne simulée')
  T.eq(kind, 'unavailable')
  h.sim.rainWetness = 0.5
  app.nextContextAt = 0
  frames(h, 1)
  -- découverte en échec : dite d'abord (elle bloque le calcul) ; sinon piste mouillée, setups pluie (D16 amendé)
  T.contains((Ui.statusLine(app)), 'panne simulée')
  app.discoveryState = 'done'
  T.contains((Ui.statusLine(app)), 'Piste mouillée : setups pluie')
  T.eq(select(2, Ui.statusLine({ inert = 'x' })), 'pending')
  T.eq(select(2, Ui.statusLine({ discoveryState = 'idle' })), 'na')
  T.eq(app.perf.errors, 0)
  T.eq(h.writeCalls, 0)
end

tests['A12 dt invalides et application désactivée'] = function()
  local h, _, app = boot()
  for _, dt in ipairs({ 0 / 0, -1, 10, 0, math.huge }) do script.SETUPLAB__UPDATE(dt) end
  script.SETUPLAB__UPDATE(nil)
  T.eq(app.perf.errors, 0)
  local h2, _, app2 = boot()
  app2.settings.enabled = false
  frames(h2, 120)
  T.eq(app2.discoveryState, 'idle')
  T.eq(h2.calls.readDataFile, nil)
  T.ok(h.sim ~= nil)
end

tests['A13 hygiène globale : seule SETUPLAB est créée'] = function()
  rawset(_G, 'SETUPLAB', nil)
  Fake.install(Fake.new({ car = require('fixtures/cars/formula_k'), track = require('fixtures/tracks/monza') }))
  local before = {}
  for k in pairs(_G) do before[k] = true end
  local h = boot()
  frames(h, 5)
  local added = {}
  for k in pairs(_G) do
    if not before[k] then added[#added + 1] = tostring(k) end
  end
  table.sort(added)
  T.eq(table.concat(added, ','), 'SETUPLAB')
  for name, fn in pairs(script) do
    T.ok(name:find('^SETUPLAB__') or name == 'update', 'rappel préfixé (ou script.update de CSP) : ' .. name)
    T.eq(type(fn), 'function')
  end
end

-- Constat n° 1 : CSP peut appeler [SIM_CALLBACKS] UPDATE, script.update, ou les deux.
tests['A14 boucle : une tranche par frame quelle que soit la source'] = function()
  local h, _, app = boot()
  for _ = 1, 20 do
    h.sim.time = h.sim.time + 16.7
    local before = app.scheduler.stats.slices
    script.SETUPLAB__UPDATE(0.0167)
    script.update(0.0167)
    T.ok(app.scheduler.stats.slices - before <= 1, 'deux sources : une seule tranche')
  end
  T.eq(app.updateSource, 'SIM_CALLBACKS UPDATE')
  local h2, _, app2 = boot()
  for _ = 1, 3000 do
    h2.sim.time = h2.sim.time + 16.7
    script.update(0.0167)
    if app2.report then break end
  end
  T.eq(app2.updateSource, 'script.update')
  T.ok(app2.report, 'découverte complète avec script.update seul')
  -- la source retenue cesse d'être appelée : bascule sur l'autre
  local h3, _, app3 = boot()
  h3.sim.time = h3.sim.time + 16.7
  script.SETUPLAB__UPDATE(0.0167)
  T.eq(app3.updateSource, 'SIM_CALLBACKS UPDATE')
  for _ = 1, 40 do
    h3.sim.time = h3.sim.time + 16.7
    script.update(0.0167)
  end
  T.eq(app3.updateSource, 'script.update', 'bascule après arrêt de la source retenue')
  T.ok(h.sim and h2.sim)
end

-- Relecture n° 13 : le déchargement réel passe par le rappel enregistré auprès de ac.onRelease.
tests['A15 déchargement par ac.onRelease'] = function()
  local h, S, app = boot()
  frames(h, 1)
  T.eq(#h.releases, 1)
  h.releases[1]()
  T.ok(app.released)
  T.no(Util_busy(app))
  h.releases[1]()
  T.eq(h.disposed, 1, 'libération idempotente')
  local calls = h.uiCalls
  frames(h, 3)
  T.eq(h.uiCalls, calls, 'plus aucun rendu')
  T.eq(S.app, app)
end

-- Constat n° 7 : un passage en replay pendant la construction du rapport ne le perd pas.
tests['A16 rapport repris après une inertie'] = function()
  local h, _, app = boot()
  for _ = 1, 3000 do
    frames(h, 1)
    if app.discoveryState == 'done' then break end
  end
  if app.report == nil then
    h.sim.isReplayActive = true
    app.nextContextAt = 0
    frames(h, 1)
    T.ok(app.inert)
    h.sim.isReplayActive = false
  end
  T.ok(untilDone(h, app, 400), 'rapport disponible après la sortie du replay')
  -- forçage du cas : rapport perdu alors que la découverte est terminée
  app.report = nil
  app.nextContextAt = 0
  T.ok(untilDone(h, app, 400), 'rapport reconstruit')
end

-- Test d'écriture demandé par Vincent : sur clic uniquement, nouveau fichier, capacité et rapport mis à jour.
tests['A18 bouton « Enregistrer une copie du setup actuel »'] = function()
  local h, _, app = boot()
  T.ok(untilDone(h, app))
  T.eq(h.writeCalls, 0, 'aucune écriture sans clic')
  T.eq(app.discovery.caps.byId.setup_write.status, 'pending')
  h.click = 'Enregistrer une copie du setup actuel'
  frames(h, 1)
  T.ok(app.writeTest and app.writeTest.ok, tostring(app.writeTest and app.writeTest.reason))
  T.eq(h.writeCalls, 1)
  T.eq(h.written[app.writeTest.path], h.ac.stringifyCurrentSetup(true, false))
  T.contains(app.ui.message, 'relue et identique')
  T.eq(app.discovery.caps.byId.setup_write.status, 'available')
  T.ok(untilDone(h, app, 400), 'rapport reconstruit')
  T.contains(app.report, 'confirmée : ' .. app.writeTest.path)
  -- un second clic crée un autre fichier, sans écraser le premier
  local firstPath = app.writeTest.path
  h.click = 'Enregistrer une copie du setup actuel'
  frames(h, 1)
  T.ok(app.writeTest.path ~= firstPath)
  T.eq(h.writeCalls, 2)
  -- le résultat survit à une nouvelle découverte
  h.click = 'Relancer la découverte'
  frames(h, 1)
  T.ok(untilDone(h, app))
  T.eq(app.discovery.caps.byId.setup_write.status, 'available')
  -- en replay : refus, aucune écriture
  h.sim.isReplayActive = true
  app.nextContextAt = 0
  frames(h, 1)
  h.click = 'Enregistrer une copie du setup actuel'
  frames(h, 1)
  T.contains(app.ui.message, 'Enregistrement impossible')
  T.eq(h.writeCalls, 2)
  -- échec d'écriture affiché tel quel
  local h2, _, app2 = boot('formula_k', 'monza', { saveFails = true })
  T.ok(untilDone(h2, app2))
  h2.click = 'Enregistrer une copie du setup actuel'
  frames(h2, 1)
  T.contains(app2.ui.message, 'io.save a refusé l\'écriture')
  T.eq(app2.discovery.caps.byId.setup_write.status, 'unavailable')
  T.eq(app2.perf.errors, 0)
end

-- Constat n° 6, puis décision de Vincent du 20/10/2026 : conditions de piste changées -> résultat
-- signalé périmé, jamais de blocage ; nouvelle séance -> nouvelle découverte automatique.
tests['A17 conditions changées : résultat signalé, calcul toujours possible ; nouvelle séance : redécouverte'] = function()
  local h, _, app = boot()
  T.ok(untilDone(h, app))
  app.settings.optBudgetEvalsQ = 60
  h.click = 'Calculer le setup tour rapide'
  for _ = 1, 20000 do
    frames(h, 1)
    if app.quali and app.quali.state ~= 'running' then break end
  end
  T.eq(app.quali.state, 'done', tostring(app.quali.error))
  T.near(app.quali.conditions.roadTemp, h.sim.roadTemperature, 1e-9, 'conditions du calcul relues au lancement')
  local completed = app.scheduler.stats.completed
  h.sim.roadTemperature = h.sim.roadTemperature + 5
  app.nextContextAt = 0
  frames(h, 1)
  T.contains(app.quali.stale or '', 'Calculé dans d\'autres conditions (piste ')
  T.contains(app.quali.stale, ' °C)')
  T.eq(app.discoveryState, 'done', 'pas de relance pour une évolution de la piste')
  T.eq(app.scheduler.stats.completed, completed)
  T.eq(app.qualiBlocker(), nil, 'calcul toujours possible')
  -- nouveau calcul : conditions du moment, plus de signalement
  h.click = 'Calculer le setup tour rapide'
  for _ = 1, 20000 do
    frames(h, 1)
    if app.quali and app.quali.state ~= 'running' then break end
  end
  T.eq(app.quali.state, 'done')
  T.near(app.quali.conditions.roadTemp, h.sim.roadTemperature, 1e-9)
  app.nextContextAt = 0
  frames(h, 1)
  T.eq(app.quali.stale, nil)
  -- température qui oscille de part et d'autre d'une ancienne limite de palier : rien
  h.sim.roadTemperature = app.quali.conditions.roadTemp + 0.9
  app.nextContextAt = 0
  frames(h, 1)
  h.sim.roadTemperature = app.quali.conditions.roadTemp - 0.9
  app.nextContextAt = 0
  frames(h, 1)
  T.eq(app.quali.stale, nil, 'oscillation sous le seuil : non signalée')
  -- air et adhérence, seuils compris (valeurs du jeu en simple précision : tolérance)
  local ref = app.quali.conditions
  h.sim.roadTemperature, h.sim.ambientTemperature = ref.roadTemp, ref.airTemp + Config.K.conditionsTempStep
  app.nextContextAt = 0
  frames(h, 1)
  T.contains(app.quali.stale or '', '(air ')
  h.sim.ambientTemperature, h.sim.roadGrip = ref.airTemp, ref.roadGrip + Config.K.conditionsGripStep - Config.K.conditionsEps / 10
  app.nextContextAt = 0
  frames(h, 1)
  T.contains(app.quali.stale or '', '(adhérence ')
  T.contains(app.quali.stale, ' %)')
  h.sim.roadGrip = ref.roadGrip
  -- conditions changées pendant le calcul, revenues avant sa fin : le calcul va au bout, signalé
  local reference = app.quali.conditions.roadTemp
  h.click = 'Calculer le setup tour rapide'
  frames(h, 2)
  T.eq(app.quali.state, 'running')
  -- conditions relevées à la première tranche de la tâche (machine chargée : une image sautée, garde-fou §14.3)
  for _ = 1, 600 do
    if app.quali.conditions then break end
    frames(h, 1)
  end
  T.near(app.quali.conditions.roadTemp, reference, 1e-9, 'tâche démarrée avec les conditions du moment')
  h.sim.roadTemperature = reference + 5
  app.nextContextAt = 0
  frames(h, 1)
  T.eq(app.quali.state, 'running', 'le calcul continue')
  h.sim.roadTemperature = reference
  for _ = 1, 20000 do
    frames(h, 1)
    if app.quali.state ~= 'running' then break end
  end
  T.eq(app.quali.state, 'done')
  app.nextContextAt = 0
  frames(h, 1)
  T.contains(app.quali.stale or '', 'Conditions changées pendant le calcul (piste ', 'changement pendant le calcul signalé')
  T.contains(app.quali.stale, 'revenues depuis')
  -- nouvelle séance (numéro) : vue deux fois, puis nouvelle découverte
  h.sim.currentSessionIndex = 1
  app.nextContextAt = 0
  frames(h, 1)
  T.eq(app.discoveryState, 'done', 'séance vue une fois : pas encore de relance')
  app.nextContextAt = 0
  frames(h, 1)
  T.eq(app.discoveryState, 'running', 'séance confirmée : nouvelle découverte')
  T.ok(untilDone(h, app))
  for i = 1, 4 do
    app.nextContextAt = 0
    frames(h, 1)
    T.eq(app.discoveryState, 'done', 'pas de relance en boucle (relecture ' .. i .. ')')
  end
  T.contains(app.ui.message or '', 'Nouvelle séance')
end

-- Pendant de A02 : les pauses du ramasse-miettes croissent avec les déchets produits. Mesure avec
-- le ramasse-miettes arrêté (hôte simulé et rapport compris : 3,3 à 3,9 Mo au J2).
tests['A19 déchets d\'une découverte bornés'] = function()
  for _, case in ipairs({ { 'urd_px1_aura', 'spa' }, { 'lamborghini_huracan_gt3_evo2', 'monza' } }) do
    local h, _, app = boot(case[1], case[2])
    T.ok(untilDone(h, app))
    collectgarbage('collect')
    collectgarbage('stop')
    local before = collectgarbage('count')
    h.click = 'Relancer la découverte'
    frames(h, 1)
    local done = untilDone(h, app)
    local kb = collectgarbage('count') - before
    collectgarbage('restart')
    T.ok(done)
    PY.note('A19 ' .. case[1], string.format('%.0f Ko par découverte', kb))
    T.ok(kb < 6000, case[1] .. ' : ' .. kb .. ' Ko alloués par découverte')
  end
end

tests['A20 travail de la frame retiré de la tranche (passage de ligne, §14.3)'] = function()
  local h, _, app = boot()
  local Recorder, Util, Config = require('src/recorder'), require('src/util'), require('src/config')
  -- découverte lancée (horloge réelle), puis horloge simulée
  for _ = 1, 100 do
    if Util_busy(app) then break end
    frames(h, 1)
  end
  -- horloge simulée : 20 µs par lecture ; l'enregistrement de la frame coûte 0, 1,5 puis 1,9 ms
  local now, read = 0, 2e-5
  app.clock = function()
    now = now + read
    return now
  end
  -- une frame de transition : le coût de la frame d'avant, mesuré à l'horloge réelle (premier affichage de
  -- l'interface, compilation), ne doit pas déclencher la garde de frame pendant la mesure
  frames(h, 1)
  local recordUpdate, step = Recorder.update, Util.schedulerStep
  local recordCost, budgets = 0, {}
  Recorder.update = function(...)
    now = now + recordCost
    return recordUpdate(...)
  end
  Util.schedulerStep = function(s, clock, budget, quota)
    budgets[#budgets + 1] = budget
    return step(s, clock, budget, quota)
  end
  local ok, err = pcall(function()
    local slice = app.settings.sliceBudgetMs / 1000
    for _, case in ipairs({ { 0, slice - read }, { 1.5e-3, slice - read - 1.5e-3 }, { 1.9e-3, Config.K.sliceMinMs / 1000 } }) do
      T.ok(Util_busy(app), 'calcul en cours')
      recordCost, budgets, app.perf.skipNext = case[1], {}, false
      frames(h, 1)
      T.eq(#budgets, 1, 'une tranche')
      T.near(budgets[1], case[2], 1e-5, 'tranche ' .. tostring(budgets[1]) .. ' s après ' .. case[1] .. ' s de travail')
    end
  end)
  Recorder.update, Util.schedulerStep = recordUpdate, step
  T.ok(ok, tostring(err))
end

return tests
