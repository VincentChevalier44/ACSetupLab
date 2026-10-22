-- Tests des pneus mesurés (§8.6, §10.6 « pression qui limite la surchauffe ») : fenêtre de température,
-- état mesuré par essieu, pression à chaud à la température mesurée, garde-fou de surchauffe.
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

local cache = {}
local function world(carId, trackId)
  local key = carId .. '@' .. trackId
  if cache[key] then return cache[key] end
  local h = Fake.new({ car = require('fixtures/cars/' .. carId), track = require('fixtures/tracks/' .. trackId) })
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
  cache[key] = { h = h, track = track, coarse = coarse, base = base, space = space }
  return cache[key]
end

local function slotNamed(base, name)
  for i, c in ipairs(base.compounds) do
    if c.name == name then return i end
  end
  error('composé absent : ' .. name)
end

tests['W01 fenêtre de température : adhérence ≥ 98 % du pic de PERFORMANCE_CURVE'] = function()
  local w = world('lamborghini_huracan_gt3_evo2', 'monza')
  local hard = w.base.compounds[slotNamed(w.base, 'Slick Hard')]
  local lo, hi = CarModel.tyreWindow(hard.front)
  T.near(lo, 70 + 10 / 3, 1e-9)
  T.near(hi, 105 + 20 / 3, 1e-9)
  local medium = w.base.compounds[slotNamed(w.base, 'Slick Medium')]
  lo, hi = CarModel.tyreWindow(medium.front)
  T.near(lo, 70, 1e-9)
  T.near(hi, 95 + 20 / 3, 1e-9)
  T.ok(CarModel.operatingTemp(medium.front) > lo and CarModel.operatingTemp(medium.front) < hi, 'plateau dans la fenêtre')
  T.eq(CarModel.tyreWindow({}), nil, 'sans courbe : pas de fenêtre')
end

-- Tour enregistré factice (moyennes par roue : AVG, AVD, ARG, ARD).
local function lapWith(core, pressure, inside, outside)
  return { tyreTemp = core, pressure = pressure, tyreTempIn = inside, tyreTempOut = outside, conditions = { airTemp = 25 } }
end

tests['W02 état mesuré par essieu : froid, fenêtre, surchauffe ; écart intérieur − extérieur ; loi des gaz'] = function()
  local w = world('lamborghini_huracan_gt3_evo2', 'monza')
  local slot = slotNamed(w.base, 'Slick Medium')
  local setup = Space.apply(w.space, CarModel.defaultSetup(w.base), {})
  local lap = lapWith({ 95, 95, 120, 118 }, { 27.6, 27.4, 29.2, 28.8 }, { 100, 100, 128, 126 }, { 90, 90, 112, 110 })
  local s = assert(CarModel.tyreState(w.base, slot, lap, setup))
  T.eq(s.F.state, 'fenêtre')
  T.eq(s.R.state, 'surchauffe')
  T.near(s.F.temp, 95, 1e-12)
  T.near(s.R.temp, 119, 1e-12)
  T.near(s.F.spread, 10, 1e-12)
  T.near(s.R.spread, 16, 1e-12)
  T.near(s.F.hot, 27.5, 1e-12)
  T.near(s.F.offset, 27.5 - CarModel.hotPressure(setup.pressureF, 25, 95), 1e-9)
  T.near(s.R.cold, setup.pressureR, 1e-12)
  local cold = assert(CarModel.tyreState(w.base, slot, lapWith({ 55, 55, 60, 60 }, { 26, 26, 26, 26 }), setup))
  T.eq(cold.F.state, 'froid')
  T.eq(cold.F.spread, nil, 'températures latérales absentes')
  T.eq(CarModel.tyreState(w.base, slot, { tyreTemp = { 0, 0, 0, 0 }, pressure = { 0, 0, 0, 0 } }, setup), nil, 'aucune mesure')
end

tests['W03 pression à chaud déduite à la température mesurée, écart à la loi des gaz compris'] = function()
  local w = world('lamborghini_huracan_gt3_evo2', 'monza')
  local tyre = w.base.compounds[CarModel.defaultSetup(w.base).compound].front
  local ideal, air = tyre.pressureIdeal, 25
  local plateau = CarModel.operatingTemp(tyre)
  -- pression à froid qui donne l'idéale à chaud : à 110 °C mesurés, et au plateau
  local function coldFor(temp, offset)
    local lo, hi = 10, 40
    for _ = 1, 60 do
      local mid = (lo + hi) / 2
      if CarModel.hotPressure(mid, air, temp) + (offset or 0) < ideal then lo = mid else hi = mid end
    end
    return (lo + hi) / 2
  end
  local function grip(cold, conditions)
    local s = CarModel.defaultSetup(w.base)
    s.pressureF = cold
    local c = { airTemp = air }
    for key, value in pairs(conditions) do c[key] = value end
    return assert(CarModel.configure(w.base, s, c)).dF
  end
  local hotCase = { pressureTempF = 110 }
  T.ok(grip(coldFor(110), hotCase) > grip(coldFor(plateau), hotCase) + 1e-6, 'idéale atteinte à la température mesurée')
  T.ok(coldFor(110) < coldFor(plateau), 'pneus plus chauds : pression à froid plus basse')
  -- écart mesuré de +1 psi à la loi des gaz : la pression à froid optimale baisse
  local offsetCase = { pressureTempF = 110, pressureOffsetF = 1 }
  T.ok(grip(coldFor(110, 1), offsetCase) > grip(coldFor(110), offsetCase) + 1e-6)
  T.ok(coldFor(110, 1) < coldFor(110))
end

tests['W04 optimiseur : essieu en surchauffe jamais dégonflé, conversion mesurée, bilan par essieu'] = function()
  local w = world('lamborghini_huracan_gt3_evo2', 'monza')
  local setup = Space.apply(w.space, CarModel.defaultSetup(w.base), {})
  local lap = lapWith({ 95, 95, 125, 125 }, { 27.6, 27.6, 30, 30 }, { 100, 100, 130, 130 }, { 90, 90, 120, 120 })
  local tyres = assert(CarModel.tyreState(w.base, setup.compound, lap, setup))
  T.eq(tyres.R.state, 'surchauffe')
  local settings = Config.defaults()
  local args = { base = w.base, space = w.space, track = w.track, trackCoarse = w.coarse, settings = settings, budget = 200,
    conditions = { airTemp = 25, roadGrip = 0.98, surfaceGrip = w.track.surfaceGrip }, tyres = tyres }
  local p = Optimizer.prepareQuali(args)
  for i, var in ipairs(p.vars) do
    if var.key == 'pressureR' then T.eq(p.dims[i].lo, 0, 'pression arrière jamais abaissée') end
    if var.key == 'pressureF' then T.ok(p.dims[i].lo < 0, 'pression avant libre') end
  end
  T.near(p.conditions.pressureTempF, 95, 1e-12)
  T.near(p.conditions.pressureTempR, 125, 1e-12)
  -- carrossage : arrière intérieur plus chaud de 10 °C (sous le seuil) : libre ; avec 20 °C, jamais plus
  -- négatif ; extérieur plus chaud à l'avant, jamais moins négatif
  local hotInside = lapWith({ 95, 95, 100, 100 }, { 27.6, 27.6, 28, 28 }, { 90, 90, 110, 110 }, { 100, 100, 90, 90 })
  local guarded = assert(CarModel.tyreState(w.base, setup.compound, hotInside, setup))
  local pg = Optimizer.prepareQuali({ base = w.base, space = w.space, track = w.track, settings = settings, budget = 10,
    conditions = { airTemp = 25 }, tyres = guarded })
  for i, var in ipairs(pg.vars) do
    if var.kind == 'camber' then
      local up = Space.physical(var, 1) > Space.physical(var, 0)
      local moreNegative = up and pg.dims[i].lo or -pg.dims[i].hi
      local lessNegative = up and pg.dims[i].hi or -pg.dims[i].lo
      if var.axle == 'R' then
        T.eq(moreNegative, 0, 'arrière : jamais plus négatif')
        T.ok(lessNegative > 0, 'arrière : moins négatif permis')
      else
        T.eq(lessNegative, 0, 'avant : jamais moins négatif')
        T.ok(moreNegative < 0, 'avant : plus négatif permis')
      end
    end
  end
  -- écart à la loi des gaz de plusieurs psi : la mesure ancre quand même la conversion
  T.ok(math.abs(tyres.F.offset) > 3, 'écart mesuré ' .. tyres.F.offset)
  T.near(p.conditions.pressureOffsetF, tyres.F.offset, 1e-12)
  local r = assert(Optimizer.runQuali(p, SYNC, Optimizer.newState({ budget = 200 })))
  T.ok((r.deltas.pressureR or 0) >= 0)
  T.ok(r.tyres.measured)
  T.eq(r.tyres.R.state, 'surchauffe')
  T.contains(r.tyres.R.guard, 'jamais abaissée')
  T.ok(r.tyres.F.measuredTemp)
  PY.note('W04', string.format('avant : %.1f °C, %.2f -> %.2f psi à chaud (idéale %.2f) ; arrière : %.1f °C, %.2f -> %.2f psi',
    r.tyres.F.temp, r.tyres.F.hotCurrent, r.tyres.F.hotProposed, r.tyres.F.ideal, r.tyres.R.temp, r.tyres.R.hotCurrent,
    r.tyres.R.hotProposed))
  -- jamais plus loin de l'idéale que l'actuelle (à 0,5 psi près) : la pression ne sert pas de réglage d'équilibre
  for _, axle in ipairs({ 'F', 'R' }) do
    local e = r.tyres[axle]
    T.ok(math.abs(e.hotProposed - e.ideal) <= math.max(math.abs(e.hotCurrent - e.ideal), Config.K.tyreHotTolerance) + 1e-6,
      axle .. ' : ' .. e.hotProposed .. ' psi contre ' .. e.hotCurrent .. ' (idéale ' .. e.ideal .. ')')
  end
  -- pneus froids sur le tour : conversion au plateau, aucun garde-fou
  local coldTyres = assert(CarModel.tyreState(w.base, setup.compound, lapWith({ 50, 50, 50, 50 }, { 25, 25, 25, 25 }), setup))
  local pc = Optimizer.prepareQuali({ base = w.base, space = w.space, track = w.track, settings = settings, budget = 10,
    conditions = { airTemp = 25 }, tyres = coldTyres })
  T.eq(pc.conditions.pressureTempF, nil)
  for i, var in ipairs(pc.vars) do
    if var.kind == 'pressure' then
      T.ok(pc.dims[i].lo < 0)
      T.ok(pc.dims[i].lo >= -Config.K.optRadiusReduced and pc.dims[i].hi <= Config.K.optRadiusReduced, 'recherche réduite sans ancrage')
    end
  end
  -- conversion ancrée, avant à 27,6 psi pour une idéale de 26 : on peut dégonfler vers l'idéale (jusqu'à
  -- 1,6 psi en dessous), jamais regonfler plus loin
  for i, var in ipairs(p.vars) do
    if var.key == 'pressureF' then
      T.ok(p.dims[i].lo < 0, 'vers l\'idéale')
      T.eq(p.dims[i].hi, 0, 'jamais plus loin de l\'idéale')
      local lowest = Optimizer.pressureBand(p, var, p.dims[i].lo - 5, p.dims[i].hi)
      T.eq(lowest, p.dims[i].lo, 'bande stable')
    end
  end
  -- sans tour mesuré : bilan au plateau, signalé
  local none = assert(Optimizer.runQuali(Optimizer.prepareQuali({ base = w.base, space = w.space, track = w.track, settings = settings,
    budget = 20, conditions = { airTemp = 25 } }), SYNC, Optimizer.newState({ budget = 20 })))
  T.no(none.tyres.measured)
  T.eq(none.tyres.F.temp, nil)
end

-- Pneus à temp °C partout, pressions cohérentes avec la loi des gaz (19 psi à froid) : état contre le
-- composé monté (Medium).
local function hotLap(w, temp)
  for _, key in ipairs({ 'pressureF', 'pressureR' }) do
    local var = w.space.byKey[key]
    for _, m in ipairs(var.members) do m.current = 19 end
    Space.bounds(var)
  end
  local setup = Space.apply(w.space, CarModel.defaultSetup(w.base), {})
  local hot = CarModel.hotPressure(setup.pressureF, 25, temp)
  local lap = lapWith({ temp, temp, temp, temp }, { hot, hot, hot, hot })
  return setup, assert(CarModel.tyreState(w.base, setup.compound, lap, setup))
end

tests['W05 choix du composé : fenêtre contre la température mesurée, bornes de pression du composé retenu'] = function()
  local w = world('lamborghini_huracan_gt3_evo2', 'monza')
  local medium, soft = slotNamed(w.base, 'Slick Medium'), slotNamed(w.base, 'Slick Soft')
  local saved = {}
  for _, key in ipairs({ 'pressureF', 'pressureR' }) do
    local var = w.space.byKey[key]
    saved[key] = {}
    for i, m in ipairs(var.members) do saved[key][i] = m.current end
  end
  local function args(tyres, choice, budget)
    local settings = Config.defaults()
    settings.raceLaps = 20
    return { base = w.base, space = w.space, track = w.track, trackCoarse = w.coarse, settings = settings, budget = budget,
      compound = medium, compoundChoice = choice, tyres = tyres,
      conditions = { airTemp = 25, roadGrip = 1, surfaceGrip = w.track.surfaceGrip },
      race = { fuelPerLapCsp = 2.6, kmPerLapF = 5.8, kmPerLapR = 5.8, lapTimeMeasured = 110 } }
  end
  -- 100 °C, Medium dans sa fenêtre : le Soft (60–95 °C) n'est plus écarté d'office (constat de Vincent du
  -- 21/10/2026) : comparé à 100 °C (sa courbe y garde 97 %), dit hors de sa fenêtre ; retenu s'il reste le plus
  -- rapide, sa surchauffe est alors signalée et sa pression jamais abaissée
  local setup, tyres = hotLap(w, 100)
  T.eq(setup.compound, medium)
  T.eq(tyres.F.state, 'fenêtre')
  local q = assert(Optimizer.runQuali(Optimizer.prepareQuali(args(tyres, -1, 200)), SYNC, Optimizer.newState({ budget = 200 })))
  local r = assert(Optimizer.runRace(Optimizer.prepareRace(args(tyres, -1, 30)), SYNC, Optimizer.newState({ budget = 30 })))
  for _, res in ipairs({ q, r }) do
    T.contains(res.compound.note, 'comparé(s) à la température mesurée, hors de leur fenêtre')
    T.contains(res.compound.note, 'S : 100 °C mesurés')
    T.eq(res.compound.measuredTempF, 100)
    for _, axle in ipairs({ 'F', 'R' }) do
      local e = res.tyres[axle]
      if res.compound.slot == soft then
        T.eq(e.state, 'surchauffe', 'Soft retenu à 100 °C : surchauffe signalée')
        T.contains(e.guard, 'jamais abaissée')
      else
        T.ok(e.state == 'fenêtre' or e.state == 'froid', axle .. ' : ' .. tostring(e.state))
        T.ok(100 >= e.lo and 100 <= e.hi, 'fenêtre affichée contenant la mesure')
      end
    end
  end
  PY.note('W05', 'qualification : ' .. q.compound.name .. ' ; ' .. q.compound.note)
  -- Soft imposé à 100 °C : gardé (choix du pilote), signalé ; état et garde-fou contre sa fenêtre ;
  -- pression jamais abaissée
  local qs = assert(Optimizer.runQuali(Optimizer.prepareQuali(args(tyres, 0, 200)), SYNC, Optimizer.newState({ budget = 200 })))
  T.eq(qs.compound.slot, soft)
  T.contains(qs.compound.note, 'composé imposé hors de sa fenêtre')
  for _, axle in ipairs({ 'F', 'R' }) do
    T.eq(qs.tyres[axle].state, 'surchauffe')
    T.contains(qs.tyres[axle].guard, 'jamais abaissée')
    T.ok((qs.deltas['pressure' .. axle] or 0) >= 0, axle .. ' dégonflé en surchauffe')
    T.near(qs.tyres[axle].hi, 95, 0.5)
  end
  local rs = assert(Optimizer.runRace(Optimizer.prepareRace(args(tyres, 0, 30)), SYNC, Optimizer.newState({ budget = 30 })))
  T.eq(rs.compound.slot, soft)
  for _, axle in ipairs({ 'F', 'R' }) do
    T.eq(rs.tyres[axle].state, 'surchauffe')
    T.ok((rs.deltas['pressure' .. axle] or 0) >= 0, 'course : ' .. axle .. ' dégonflé en surchauffe')
  end
  -- idéale propre au composé retenu (Soft à 30 psi, synthétique) : bornes recalculées pour lui, en
  -- qualification comme en course (surchauffe : jamais abaissée ; bande autour de 30 psi : peut monter)
  local softC = w.base.compounds[soft]
  local ideals = { softC.front.pressureIdeal, softC.rear.pressureIdeal }
  softC.front.pressureIdeal, softC.rear.pressureIdeal = 30, 30
  local ok, err = pcall(function()
    for _, kind in ipairs({ 'quali', 'race' }) do
      local pb = kind == 'quali' and Optimizer.prepareQuali(args(tyres, 0, 40)) or Optimizer.prepareRace(args(tyres, 0, 20))
      local run = kind == 'quali' and Optimizer.runQuali or Optimizer.runRace
      assert(run(pb, SYNC, Optimizer.newState({ budget = kind == 'quali' and 40 or 20 })))
      for i, var in ipairs(pb.vars) do
        if var.kind == 'pressure' then
          T.eq(pb.dims[i].lo, 0, kind .. ' : surchauffe du Soft')
          T.ok(pb.dims[i].hi > 0, kind .. ' : bande autour de l\'idéale du Soft')
        end
      end
    end
  end)
  softC.front.pressureIdeal, softC.rear.pressureIdeal = ideals[1], ideals[2]
  if not ok then error(err, 0) end
  -- 105 °C : Medium en surchauffe ; s'il est gardé, le Hard (73–112 °C) est signalé ; jamais le Soft ;
  -- pression jamais abaissée sur le composé retenu s'il surchauffe
  local _, hotTyres = hotLap(w, 105)
  T.eq(hotTyres.F.state, 'surchauffe')
  local qh = assert(Optimizer.runQuali(Optimizer.prepareQuali(args(hotTyres, -1, 200)), SYNC, Optimizer.newState({ budget = 200 })))
  T.ok(qh.compound.slot ~= soft)
  if qh.compound.slot == medium then
    T.contains(qh.compound.note, 'composé monté en surchauffe : H')
    for _, axle in ipairs({ 'F', 'R' }) do T.ok((qh.deltas['pressure' .. axle] or 0) >= 0) end
  end
  for _, axle in ipairs({ 'F', 'R' }) do
    local e = qh.tyres[axle]
    T.eq(e.state, 105 > e.hi and 'surchauffe' or 'fenêtre')
  end
  PY.note('W05', '105 °C : ' .. qh.compound.name .. ' ; ' .. tostring(qh.compound.note))
  for key, values in pairs(saved) do
    local var = w.space.byKey[key]
    for i, m in ipairs(var.members) do m.current = values[i] end
    Space.bounds(var)
  end
end

-- Constat de Vincent du 21/10/2026 (DTM, meilleur temps) : « j'étais en médium, il ne m'a pas passé en
-- supersoft ». Médium à 90 °C mesurés : le supersoft (plateau 52–76 °C, fenêtre jusqu'à ~88 °C) y garde
-- ~97,5 % de son adhérence, plus que le médium ; il est proposé, sa sortie de fenêtre dite.
tests['W07 DTM, médium à 90 °C : supersoft proposé, comparé à la température mesurée'] = function()
  local w = world('whk_dtm_2026', 'monza')
  local medium, supersoft = slotNamed(w.base, 'Sec - Medium'), slotNamed(w.base, 'Sec - Supersoft')
  local setup = Space.apply(w.space, CarModel.defaultSetup(w.base), {})
  setup.compound = medium
  local hot = CarModel.hotPressure(setup.pressureF, 25, 90)
  local tyres = assert(CarModel.tyreState(w.base, medium, lapWith({ 90, 90, 90, 90 }, { hot, hot, hot, hot }), setup))
  T.eq(tyres.F.state, 'fenêtre')
  local settings = Config.defaults()
  local p = Optimizer.prepareQuali({ base = w.base, space = w.space, track = w.track, trackCoarse = w.coarse, settings = settings,
    budget = 60, compound = medium, compoundChoice = -1, tyres = tyres,
    conditions = { airTemp = 25, roadGrip = 1, surfaceGrip = w.track.surfaceGrip } })
  local q = assert(Optimizer.runQuali(p, SYNC, Optimizer.newState({ budget = 60 })))
  local parts = {}
  for _, e in ipairs(q.compound.comparison) do parts[#parts + 1] = tostring(e.short) .. '=' .. Util.fmt(e.J, 2) end
  PY.note('W07', table.concat(parts, ' ; ') .. ' -> ' .. tostring(q.compound.name))
  T.eq(q.compound.slot, supersoft, 'supersoft : ' .. table.concat(parts, ' ; '))
  T.ok(q.compound.changed)
  T.contains(q.compound.note, 'SS : 90 °C mesurés')
end

tests['W06 gauche / droite (D11) : roue aberrante sans ancrage ; surchauffe sur la roue la plus chaude'] = function()
  local w = world('lamborghini_huracan_gt3_evo2', 'monza')
  local setup = Space.apply(w.space, CarModel.defaultSetup(w.base), {})
  -- avant gauche à 8 psi (capteur aberrant) : essieu avant non ancré, raison ; arrière cohérent : ancré
  local odd = assert(CarModel.tyreState(w.base, setup.compound, lapWith({ 95, 95, 95, 95 }, { 8, 27.6, 27.6, 27.8 }), setup))
  T.eq(odd.F.hot, nil)
  T.contains(odd.F.lrNote, 'incohérentes')
  T.ok(odd.R.hot and odd.R.lrNote == nil)
  local p = Optimizer.prepareQuali({ base = w.base, space = w.space, track = w.track, settings = Config.defaults(), budget = 10,
    conditions = { airTemp = 25 }, tyres = odd })
  T.no(p.pressureAnchored.F, 'avant non ancré')
  T.ok(p.pressureAnchored.R, 'arrière ancré')
  -- température : 20 °C d'écart, non ancré ; la roue la plus chaude (105 °C, fenêtre du Medium 70–102 °C)
  -- met l'essieu en surchauffe, même si la moyenne (97,5 °C) est dans la fenêtre
  local hot = assert(CarModel.tyreState(w.base, setup.compound, lapWith({ 85, 105, 95, 95 }, { 27.6, 27.6, 27.6, 27.6 }), setup))
  T.eq(hot.F.hot, nil)
  T.eq(hot.F.state, 'surchauffe')
  T.near(hot.F.tempMax, 105, 1e-12)
  local ph = Optimizer.prepareQuali({ base = w.base, space = w.space, track = w.track, settings = Config.defaults(), budget = 10,
    conditions = { airTemp = 25 }, tyres = hot })
  for i, var in ipairs(ph.vars) do
    if var.key == 'pressureF' then T.eq(ph.dims[i].lo, 0, 'jamais abaissée') end
  end
end

return tests
