-- Relecture adversariale n° 3 : scénarios du relecteur (banc seulement).
local T = require('t')
local Exporter = require('src/exporter')
local Fake = require('fakehost')

local tests = {}

local function boot(opts)
  opts = opts or {}
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  h.sim.raceSessionType = opts.session or 1
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

local function liveValues(app, h)
  return app.setupValues(h.ac.stringifyCurrentSetup(true, false))
end

local function v1Ready()
  local h, app = boot()
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  app.settings.compoundChoice = app.discovery.compoundIndex
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  app.handleIntents({ start = { kind = 'quali', mode = 'mine' } })
  local r = app.refine
  T.ok(waitFor(h, function() return r and r.version >= 1 and r.phase == 'tours' end), 'v1')
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  frames(h, 2)
  local e
  for i = #r.history, 1, -1 do
    if r.history[i].version then e = r.history[i]; break end
  end
  return h, app, r, e
end

local function settled(h, app)
  return waitFor(h, function()
    return app.loadCheck == nil and app.discoveryState == 'done' and not (app.refine and app.refine.needsDiscovery)
  end)
end

local function tryLoaded(h, app, r, e)
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'essayer' } })
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'chargement constaté')
  T.eq(r.driven, e.version)
end

local function entry(r, v)
  for i = #r.history, 1, -1 do
    if r.history[i].version == v then return r.history[i] end
  end
end

-- Retouche à la main sur un réglage que la version en attente (calculée avant la retouche) change : « Essayer » met la
-- version dans la voiture ; la retouche est remplacée par SetupLab, mais reste gardée (à la valeur de la version) et ne
-- peut plus être libérée à la main.
tests['LR01 retouche à la main remplacée par une version chargée par SetupLab : libérée'] = function()
  local h, app, r, e = v1Ready()
  tryLoaded(h, app, r, e)
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.ok(settled(h, app))
  app.handleIntents({ refineChoice = { version = e.version } })
  r.forceNext = true
  T.ok(waitFor(h, function() return r.version >= 2 and r.phase == 'tours' end), 'v2')
  local e2 = entry(r, 2)
  local live, v2v = liveValues(app, h), app.setupValues(e2.text)
  local S
  for _, s in ipairs(h.spinners) do
    if S == nil and app.discovery.space.members[s.name] and s.name ~= 'FUEL' and s.name ~= 'FRONT_BIAS'
        and type(v2v[s.name]) == 'number' and math.abs(v2v[s.name] - live[s.name]) > 1e-9 then S = s end
  end
  T.ok(S, 'un réglage changé par v2')
  local A, C = live[S.name], v2v[S.name]
  local step = S.step or 1
  local B
  for _, cand in ipairs({ A + step, A - step, A + 2 * step, A - 2 * step }) do
    if B == nil and cand >= S.min and cand <= S.max and math.abs(cand - C) > 1e-9 then B = cand end
  end
  T.ok(B, 'valeur de retouche')
  S.value = B
  app.handleIntents({ rediscover = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  local pin = app.pins.quali[S.name]
  T.ok(pin, 'retouche gardée')
  PY.note('ADV01 réglage', S.name .. ' A=' .. tostring(A) .. ' B=' .. tostring(B) .. ' C=' .. tostring(C)
    .. ' pin.from=' .. tostring(pin.from) .. ' pin.value=' .. tostring(pin.value))
  T.eq(e2.status, nil, 'v2 toujours en attente')
  T.eq(app.setupValues(e2.text)[S.name], C, 'v2 calculée avant la retouche')
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  app.handleIntents({ refineJudge = { version = 2, verdict = 'essayer' } })
  T.ok(settled(h, app))
  T.eq(r.driven, 2, 'v2 dans la voiture')
  T.eq(liveValues(app, h)[S.name], C, 'la voiture a la valeur de v2')
  local after = app.pins.quali[S.name]
  PY.note('ADV01 après chargement de v2', after and ('pin.from=' .. tostring(after.from) .. ' pin.value=' .. tostring(after.value))
    or 'libérée')
  -- remise à la main à sa valeur d'origine A : libérée ?
  S.value = A
  app.handleIntents({ rediscover = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  local after2 = app.pins.quali[S.name]
  PY.note('ADV01 remise à A', after2 and ('pin.from=' .. tostring(after2.from) .. ' pin.value=' .. tostring(after2.value))
    or 'libérée')
  S.value = C
  app.handleIntents({ rediscover = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end))
  local after3 = app.pins.quali[S.name]
  PY.note('ADV01 remise à C', after3 and ('pin.from=' .. tostring(after3.from) .. ' pin.value=' .. tostring(after3.value))
    or 'libérée')
  T.eq(after, nil, 'SetupLab a remplacé la retouche : plus une retouche')
end

tests['LR02 pluie : niveaux d\'aide refusés puis « Valider » : version gardée rechargée, affinage non bloqué'] = function()
  local h, app = boot()
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
  local aidItems, others = {}, 0
  for _, g in ipairs(e.groups or {}) do
    for _, item in ipairs(g.items) do
      if item.aid then aidItems[#aidItems + 1] = item else others = others + 1 end
    end
  end
  PY.note('ADV05 réglages', #aidItems .. ' aide(s), ' .. others .. ' autre(s) ; bucket ' .. tostring(e.bucket))
  T.ok(#aidItems > 0, 'une aide changée')
  tryLoaded(h, app, r, e)
  T.ok(settled(h, app))
  for _, item in ipairs(aidItems) do
    app.handleIntents({ effect = { version = e.version, key = item.key, keep = false } })
  end
  local loaded = app.loaded.quali and app.loaded.quali.values
  local loads = #h.loadCalls
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.eq(e.status, 'validée', tostring(app.ui.message))
  local kept = app.setupValues(e.text)
  PY.note('ADV05 valeurs', 'TC essai=' .. tostring(loaded and loaded.TRACTION_CONTROL) .. ' gardé=' .. tostring(kept.TRACTION_CONTROL)
    .. ' ABS essai=' .. tostring(loaded and loaded.ABS) .. ' gardé=' .. tostring(kept.ABS))
  PY.note('ADV05 message', tostring(app.ui.message))
  local loadsAfterValidate = #h.loadCalls
  PY.note('ADV05 signatures', 'kept=' .. tostring(e.signature) .. ' trialFamily=' .. tostring(e.trialFamily)
    .. ' rejected[kept]=' .. tostring(r.rejected[e.signature]) .. ' driven=' .. tostring(r.driven) .. ' trialInCar=' .. tostring(e.trialInCar))
  T.ok(settled(h, app))
  app.handleIntents({ refineChoice = { version = e.version } })
  r.forceNext, r.due, r.nextAt = true, true, nil
  local n0 = #r.history
  waitFor(h, function() return r.version >= 2 or #r.history > n0 end, 20000)
  local last = r.history[#r.history]
  PY.note('ADV05 suite', 'version=' .. tostring(r.version) .. ' note=' .. tostring(last.note) .. ' waiting=' .. tostring(r.waiting))
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  app.handleIntents({ load = 'quali' })
  T.ok(settled(h, app))
  PY.note('ADV05 après Charger', 'msg=' .. tostring(app.ui.message) .. ' driven=' .. tostring(r.driven))
  r.forceNext, r.due, r.nextAt = true, true, nil
  local n1 = #r.history
  waitFor(h, function() return r.version >= 2 or #r.history > n1 end, 20000)
  last = r.history[#r.history]
  PY.note('ADV05 suite 2', 'version=' .. tostring(r.version) .. ' note=' .. tostring(last.note) .. ' waiting=' .. tostring(r.waiting))
  T.eq(loadsAfterValidate, loads + 1, 'version gardée (aide d\'avant) rechargée')
  T.no(r.rejected[e.signature], 'la version gardée n\'est pas « non gardée »')
  T.ok(not tostring(last.note or ''):find('non gardée', 1, true), 'affinage non bloqué : ' .. tostring(last.note))
end

tests['LR03 répartition de freinage seule gardée, « Valider sans essai » sans setup mis par SetupLab : chargée'] = function()
  local h, app, r, e = v1Ready()
  local keys = {}
  local hasBias = false
  for _, g in ipairs(e.groups or {}) do
    for _, item in ipairs(g.items) do
      keys[#keys + 1] = tostring(item.key)
      if item.key == 'brakeBias' then hasBias = true end
    end
  end
  PY.note('ADV07 réglages de v1', table.concat(keys, ', ') .. ' ; loaded.quali=' .. tostring(app.loaded.quali))
  T.ok(hasBias, 'v1 change la répartition de freinage')
  for _, g in ipairs(e.groups or {}) do
    for _, item in ipairs(g.items) do
      if item.key ~= 'brakeBias' then app.handleIntents({ effect = { version = e.version, key = item.key, keep = false } }) end
    end
  end
  local before = liveValues(app, h).FRONT_BIAS
  local loads = #h.loadCalls
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.eq(e.status, 'validée', tostring(app.ui.message))
  local kept = app.setupValues(e.text).FRONT_BIAS
  PY.note('ADV07', 'voiture=' .. tostring(before) .. ' gardée=' .. tostring(kept) .. ' chargements=' .. (#h.loadCalls - loads)
    .. ' message=' .. tostring(app.ui.message))
  T.eq(#h.loadCalls, loads + 1, 'la version validée va dans la voiture')
end

return tests
