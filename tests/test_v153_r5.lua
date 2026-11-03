-- Cinquième relecture (03/11/2026, nuit) : défauts reproduits par le relecteur.
-- Relecture adversariale n° 5 (scratch du relecteur).
local T = require('t')
local Fake = require('fakehost')

local tests = {}

local function boot(opts)
  opts = opts or {}
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  h.sim.raceSessionType = opts.session or 1
  h.opts.applyAids = opts.applyAids
  h.texts, h.buttons = {}, {}
  local function capture(text) h.texts[#h.texts + 1] = text end
  local text, wrapped, colored, button = h.ui.text, h.ui.textWrapped, h.ui.textColored, h.ui.button
  h.ui.text = function(s) capture(s); return text(s) end
  h.ui.textWrapped = function(s) capture(s); return wrapped(s) end
  h.ui.textColored = function(s, c) capture(s); return colored(s, c) end
  h.ui.button = function(label, ...) h.buttons[#h.buttons + 1] = label; return button(label, ...) end
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  app.utcOffset = function() return 7200 end
  app.settings.optBudgetEvalsQ, app.settings.optBudgetEvalsC = 80, 20
  return h, app
end

local function frames(h, n)
  for _ = 1, n do
    h.sim.time = h.sim.time + 1000 / 60
    h.texts, h.buttons = {}, {}
    script.SETUPLAB__UPDATE(1 / 60)
    script.SETUPLAB__MAIN(1 / 60)
  end
end

local function waitFor(h, predicate, maxFrames)
  for i = 1, maxFrames or 60000 do
    frames(h, 1)
    if predicate() then return i end
  end
  return nil
end

local function settled(h, app)
  return waitFor(h, function()
    return app.loadCheck == nil and app.discoveryState == 'done' and not (app.refine and app.refine.needsDiscovery)
  end)
end

local function entry(r, v)
  for i = #r.history, 1, -1 do
    if r.history[i].version == v then return r.history[i] end
  end
end

local function liveValues(app, h)
  return app.setupValues(h.ac.stringifyCurrentSetup(true, false))
end

local function v1Ready(opts)
  local h, app = boot(opts)
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  app.settings.compoundChoice = app.discovery.compoundIndex
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  app.handleIntents({ start = { kind = 'quali', mode = 'mine' } })
  local r = app.refine
  T.ok(waitFor(h, function() return r and r.version >= 1 and r.phase == 'tours' end), 'v1')
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  frames(h, 2)
  return h, app, r, entry(r, r.version)
end

local function pinNames(app)
  local names = {}
  for name in pairs(app.pins.quali) do names[#names + 1] = name end
  table.sort(names)
  return table.concat(names, ',')
end

-- A. Niveau d'aide refusé (pin aid:*) : le détail pluie du résultat suivant affiche-t-il « nil » ?
tests['LR11 aide refusée : détail pluie du calcul suivant'] = function()
  local h, app = boot({ applyAids = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  h.car.tractionControlMode, h.car.absMode = 4, 4
  app.handleIntents({ rediscover = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  h.sim.rainWetness, h.sim.rainWater = 1, 0.6
  app.nextContextAt = 0
  frames(h, 2)
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  app.settings.compoundChoice = app.discovery.compoundIndex
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  app.handleIntents({ start = { kind = 'quali', mode = 'mine' } })
  local r = app.refine
  T.ok(waitFor(h, function() return r and r.version >= 1 and r.phase == 'tours' end), 'v1')
  frames(h, 2)
  local e = entry(r, r.version)
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'essayer' } })
  T.ok(settled(h, app))
  for _, g in ipairs(e.groups or {}) do
    for _, item in ipairs(g.items) do
      if item.aid then app.handleIntents({ effect = { version = e.version, key = item.key, keep = false } }) end
    end
  end
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.ok(settled(h, app))
  app.handleIntents({ refineChoice = { version = e.version } })
  r.forceNext, r.due, r.nextAt = true, true, nil
  local n0 = #r.history
  waitFor(h, function() return (r.version >= 2 or #r.history > n0) and app.quali and app.quali.state == 'done' end, 20000)
  PY.note('R5A pins', pinNames(app))
  local aids = app.quali and app.quali.result and app.quali.result.aids or {}
  for s, a in pairs(aids) do
    PY.note('R5A aide ' .. s, 'from=' .. tostring(a.from) .. ' to=' .. tostring(a.to) .. ' note=' .. tostring(a.note))
  end
  h.openSections = true
  h.tab = nil
  frames(h, 1)
  local bad = {}
  for _, s in ipairs(h.texts) do
    s = tostring(s)
    if s:find('nil', 1, true) then bad[#bad + 1] = s end
  end
  PY.note('R5A textes avec nil', table.concat(bad, ' | '))
  local fr = {}
  for _, s in ipairs(h.texts) do s = tostring(s); if s:find('retouches gardées', 1, true) then fr[#fr + 1] = s end end
  PY.note('R5A ligne FR', table.concat(fr, ' | '))
  h.click = 'English###lang_en'
  frames(h, 2)
  h.openSections = true
  frames(h, 1)
  local en = {}
  for _, s in ipairs(h.texts) do
    s = tostring(s)
    if s:find('kept', 1, true) or s:find('ABS', 1, true) or s:find('raction', 1, true) then en[#en + 1] = s end
  end
  PY.note('R5A EN', table.concat(en, ' | '))
  T.eq(#bad, 0, 'aucun « nil » affiché')
end

-- B. Retouche à la main gardée par v2, essai de v2 chargé depuis le menu d'AC : la retouche reste-t-elle gardée (comme
-- après un chargement par SetupLab) ?
local function tweakThenV2(viaMenu)
  local h, app, r, e = v1Ready()
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'essayer' } })
  T.ok(settled(h, app))
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.ok(settled(h, app))
  frames(h, 30)
  -- retouche à la main
  local live = liveValues(app, h)
  local S
  for _, s in ipairs(h.spinners) do
    if S == nil and app.discovery.space.members[s.name] and s.name ~= 'FUEL' and s.name ~= 'FRONT_BIAS'
        and type(live[s.name]) == 'number' then
      local step = s.step or 1
      if live[s.name] + step <= s.max then S = s end
    end
  end
  T.ok(S, 'un réglage')
  local A = live[S.name]
  S.value = A + (S.step or 1)
  app.handleIntents({ rediscover = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  T.ok(app.pins.quali[S.name], 'retouche gardée')
  app.handleIntents({ refineChoice = { version = e.version } })
  r.forceNext, r.due, r.nextAt = true, true, nil
  T.ok(waitFor(h, function() return r.version >= 2 and r.phase == 'tours' end, 20000), 'v2')
  local e2 = entry(r, 2)
  T.eq(app.setupValues(e2.text)[S.name], S.value, 'v2 garde la retouche')
  if viaMenu then
    h.car.isInPit, h.car.isInPitlane, h.car.speedMs = false, false, 30
    app.handleIntents({ refineJudge = { version = 2, verdict = 'essayer' } })
    T.eq(e2.status, 'essai')
    local values = app.setupValues(e2.trial.text)
    for _, sp in ipairs(h.spinners) do
      if type(values[sp.name]) == 'number' then sp.value = values[sp.name] end
    end
    h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
    app.handleIntents({ rediscover = true })
    T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  else
    h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
    app.handleIntents({ refineJudge = { version = 2, verdict = 'essayer' } })
    T.ok(settled(h, app))
  end
  PY.note('R5B ' .. (viaMenu and 'menu' or 'SetupLab'), 'driven=' .. tostring(r.driven) .. ' pins=' .. pinNames(app)
    .. ' réglage=' .. S.name .. ' loaded=' .. tostring(app.loaded.quali and app.loaded.quali.name))
  -- v3 : la retouche reste-t-elle ?
  app.handleIntents({ refineJudge = { version = 2, verdict = 'valider' } })
  T.ok(settled(h, app))
  app.handleIntents({ refineChoice = { version = 2 } })
  r.forceNext, r.due, r.nextAt = true, true, nil
  local n0 = #r.history
  waitFor(h, function() return r.version >= 3 or #r.history > n0 end, 20000)
  local e3 = entry(r, 3)
  PY.note('R5B ' .. (viaMenu and 'menu' or 'SetupLab') .. ' v3', e3 and (S.name .. ' v3=' .. tostring(app.setupValues(e3.text)[S.name])
    .. ' retouche=' .. tostring(S.value)) or ('pas de v3 : ' .. tostring(r.history[#r.history].note)))
  return app.pins.quali[S.name]
end

tests['LR12 retouche gardée, essai chargé par SetupLab (témoin)'] = function()
  T.ok(tweakThenV2(false), 'retouche toujours gardée')
end

tests['LR13 retouche gardée, essai chargé depuis le menu d\'AC'] = function()
  T.ok(tweakThenV2(true), 'retouche toujours gardée')
end

-- C. Version qui ne change que la répartition de freinage : essai écrit (chargement refusé), puis une découverte
-- quelconque : adoptée comme « dans la voiture » sans avoir été chargée ?
tests['LR14 version répartition seule : essai non chargé adopté'] = function()
  local h, app = boot()
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  app.settings.compoundChoice = app.discovery.compoundIndex
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  app.handleIntents({ start = { kind = 'quali', mode = 'mine' } })
  local d = app.discovery
  for name in pairs(d.space.members) do
    if name ~= 'FRONT_BIAS' then
      local v
      for _, sp in ipairs(d.setup.spinners) do if sp.name == name then v = sp.value end end
      if v then app.pins.quali[name] = { value = v, from = v, refused = true } end
    end
  end
  local r = app.refine
  waitFor(h, function() return r and (r.version >= 1 or #r.history > 0) and r.phase == 'tours' end, 20000)
  local e = entry(r, 1)
  if e == nil then
    PY.note('R5C', 'pas de v1 : ' .. tostring(r.history[#r.history] and r.history[#r.history].note))
    return
  end
  local keys = {}
  for _, g in ipairs(e.groups or {}) do
    for _, item in ipairs(g.items) do keys[#keys + 1] = item.key end
  end
  PY.note('R5C v1', table.concat(keys, ','))
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = false, false, 30
  app.handleIntents({ refineJudge = { version = 1, verdict = 'essayer' } })
  T.eq(e.status, 'essai')
  local bias0 = liveValues(app, h).FRONT_BIAS
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  app.handleIntents({ rediscover = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  frames(h, 5)
  local loads = #h.loadCalls
  PY.note('R5C après découverte', 'driven=' .. tostring(r.driven) .. ' saved=' .. tostring(app.saved.quali and app.saved.quali.name)
    .. ' fichier essai là=' .. tostring(e.trial and app.written[e.trial.file] == e.trial.hash) .. ' voiture FRONT_BIAS='
    .. tostring(bias0) .. ' essai FRONT_BIAS=' .. tostring(app.setupValues(e.trial.text).FRONT_BIAS))
  app.handleIntents({ refineJudge = { version = 1, verdict = 'valider' } })
  T.ok(settled(h, app))
  PY.note('R5C après validation', 'chargements=' .. (#h.loadCalls - loads) .. ' voiture FRONT_BIAS=' .. tostring(liveValues(app, h).FRONT_BIAS)
    .. ' v1 FRONT_BIAS=' .. tostring(app.setupValues(e.text).FRONT_BIAS) .. ' ; ' .. tostring(app.ui.message))
  T.ok(r.driven ~= 1 or liveValues(app, h).FRONT_BIAS == app.setupValues(e.text).FRONT_BIAS, 'dite dans la voiture : elle y est')
end

-- D. « Essayer » pendant une découverte, qui finit avant le constat du chargement (fenêtre non dessinée : le constat
-- n'a lieu que dans MAIN) : l'essai, chargé par SetupLab, est-il bien « dans la voiture » ensuite ?
tests['LR15 essai chargé par SetupLab, découverte finie avant le constat'] = function()
  local h, app, r, e = v1Ready()
  app.handleIntents({ rediscover = true })
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'essayer' } })
  T.ok(app.loadCheck ~= nil, 'chargement demandé')
  local n = 0
  while app.discoveryState ~= 'done' and n < 20000 do
    h.sim.time = h.sim.time + 1000 / 60
    script.SETUPLAB__UPDATE(1 / 60)
    n = n + 1
  end
  PY.note('R5D découverte finie', 'driven=' .. tostring(r.driven) .. ' saved=' .. tostring(app.saved.quali and app.saved.quali.name)
    .. ' loadCheck=' .. tostring(app.loadCheck ~= nil))
  T.ok(settled(h, app))
  frames(h, 30)
  local fileThere = e.trial and app.written[e.trial.file] == e.trial.hash
  h.tab = nil
  frames(h, 1)
  local b = {}
  for _, s in ipairs(h.buttons) do if tostring(s):find('Essayer', 1, true) then b[#b + 1] = tostring(s) end end
  local live, tv = liveValues(app, h), app.setupValues(e.text)
  local same = true
  for k, v in pairs(tv) do if k ~= 'FUEL' and type(v) == 'number' and live[k] ~= v then same = false end end
  PY.note('R5D après constat', 'driven=' .. tostring(r.driven) .. ' status=' .. tostring(e.status) .. ' essai là='
    .. tostring(fileThere) .. ' before=' .. tostring(e.before and e.before.file) .. ' voiture=essai:' .. tostring(same)
    .. ' boutons=' .. table.concat(b, ' | '))
  T.eq(r.driven, e.version, 'essai dans la voiture')
end

return tests
