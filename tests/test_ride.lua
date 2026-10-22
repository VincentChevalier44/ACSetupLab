-- Tests du repère de hauteur de l'aéro (hauteur de caisse, §8.5) : hauteur au sol relevée au stand contre
-- le modèle, repère vérifié, corrigé par la mesure ou non vérifié ; hauteur de caisse optimisable ensuite.
local T = require('t')
local Util = require('src/util')
local Config = require('src/config')
local Datasource = require('src/datasource')
local CarModel = require('src/car_model')
local Space = require('src/setup_space')
local Fake = require('fakehost')

local SYNC = Util.syncContext()
local tests = {}

local function load(carId)
  local h = Fake.new({ car = require('fixtures/cars/' .. carId), track = require('fixtures/tracks/monza') })
  local car = Datasource.readCar(h, 0, SYNC)
  local state = Datasource.readCarState(h, 0)
  local base = CarModel.build(car, state)
  return { h = h, car = car, state = state, base = base }
end

-- Hauteur au sol du modèle, à l'arrêt, pour une aile.
local function modelHeight(base, w)
  local share = Util.clamp((w.z + base.wheelbase * base.cgFront) / base.wheelbase, 0, 1)
  return base.rideHeightR + (base.rideHeightF - base.rideHeightR) * share
end

-- Ailes en direct cohérentes avec le modèle, plus un décalage par aile.
local function liveWings(r, offsets)
  local list = {}
  for i = 0, #r.base.wings - 1 do list[i + 1] = { 0.1, -0.2, 3, 3, 0.5 } end
  for _, w in ipairs(r.base.wings) do
    list[w.index + 1][5] = modelHeight(r.base, w) + (offsets[w.index] or 0)
  end
  r.h.physicsState.wings = Fake.wings(list)
  r.state = Datasource.readCarState(r.h, 0)
end

tests['H01 repère vérifié, corrigé par la mesure, ou non vérifié'] = function()
  local r = load('lamborghini_huracan_gt3_evo2')
  -- au stand, hauteurs cohérentes à 2 mm près : vérifié
  liveWings(r, { [1] = 0.002, [3] = -0.001 })
  local f = CarModel.verifyRideFrame(r.base, r.state)
  T.eq(f.status, 'vérifié', tostring(f.reason))
  T.eq(#f.rows, 2, 'ailes à LUT de hauteur : splitter et diffuseur')
  -- décalage constant de 4 cm (hauteur de l'aile au-dessus de la référence) : corrigé
  liveWings(r, { [1] = 0.04, [3] = 0.03 })
  f = CarModel.verifyRideFrame(r.base, r.state)
  T.eq(f.status, 'corrigé')
  T.near(f.offsets[1], 0.04, 1e-6)
  T.near(f.offsets[3], 0.03, 1e-6)
  -- écart incohérent : non retenu
  liveWings(r, { [1] = 0.5 })
  f = CarModel.verifyRideFrame(r.base, r.state)
  T.eq(f.status, 'écart')
  -- hors des stands : à refaire au stand
  liveWings(r, {})
  r.state.flags.isInPit = false
  f = CarModel.verifyRideFrame(r.base, r.state)
  T.eq(f.status, 'non vérifié')
  T.contains(f.reason, 'au stand')
  -- aile non lue (le jeu en expose moins que aero.ini)
  r.h.physicsState.wings = Fake.wings({ { 0.4, 0, 0, 0, 0.3 } })
  r.state = Datasource.readCarState(r.h, 0)
  T.eq(CarModel.verifyRideFrame(r.base, r.state).status, 'non vérifié')
end

tests['H02 repère corrigé : la hauteur des ailes du modèle suit la mesure'] = function()
  local r = load('lamborghini_huracan_gt3_evo2')
  local s = CarModel.defaultSetup(r.base)
  local plain = assert(CarModel.configure(r.base, s, { airTemp = 24 }))
  local dragPlain = plain.drag[31]
  r.base.wingHeightOffset = { [1] = 0.04, [3] = 0.03 }
  local shifted = assert(CarModel.configure(r.base, s, { airTemp = 24 }))
  r.base.wingHeightOffset = nil
  T.ok(math.abs(shifted.lift[31] - plain.lift[31]) > 1, 'appui modifié par le repère')
  T.ok(dragPlain > 0)
end

tests['H03 colle : hauteur de caisse optimisable une fois le repère vérifié au stand'] = function()
  local opts = { car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') }
  local function boot(prepare)
    local h = Fake.new(opts)
    if prepare then prepare(h) end
    Fake.install(h)
    assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
    local app = rawget(_G, 'SETUPLAB').app
    for _ = 1, 40000 do
      h.sim.time = h.sim.time + 1000 / 60
      script.SETUPLAB__UPDATE(1 / 60)
      script.SETUPLAB__MAIN(1 / 60)
      if app.discoveryState == 'done' then break end
    end
    return app
  end
  -- hôte par défaut : ailes en direct incomplètes -> repère non vérifié, hauteur conservée
  local app = boot()
  T.eq(app.discovery.rideFrame.status, 'non vérifié')
  T.eq(app.discovery.space.byKey.rodF.class, Space.EXCLUDED)
  T.eq(app.discovery.caps.byId.ride_frame.status, 'pending')
  -- ailes en direct cohérentes (décalage de 3 cm) : repère corrigé, hauteur optimisable
  local r = load('lamborghini_huracan_gt3_evo2')
  local list = {}
  for i = 0, #r.base.wings - 1 do list[i + 1] = { 0.1, -0.2, 3, 3, 0.5 } end
  for _, w in ipairs(r.base.wings) do list[w.index + 1][5] = modelHeight(r.base, w) + 0.03 end
  local app2 = boot(function(h) h.physicsState.wings = Fake.wings(list) end)
  T.eq(app2.discovery.rideFrame.status, 'corrigé')
  T.eq(app2.discovery.space.byKey.rodF.class, Space.REDUCED)
  local listed = false
  for _, var in ipairs(app2.discovery.optimizable) do listed = listed or var.key == 'rodF' end
  T.ok(listed, 'hauteur avant optimisable')
  T.ok(app2.discovery.carBase.wingHeightOffset, 'repère corrigé appliqué au modèle')
  T.contains(app2.discovery.caps.byId.ride_frame.detail, 'optimisable')
  -- un seul point statique ne vérifie ni la pente ni les unités de LUT_GH : à confirmer (§0.6)
  T.eq(app2.discovery.caps.byId.ride_frame.status, 'pending')
  T.contains(app2.discovery.caps.byId.ride_frame.detail, 'à confirmer')
end

tests['H04 hauteur statique : carburant, pression et ressorts ; MIN_HEIGHT avec marge ; « sans objet » au stand seulement'] = function()
  local r = load('lamborghini_huracan_gt3_evo2')
  local Setup = Datasource.readSetup(r.h, SYNC)
  local space = Space.build({ setupIni = r.car.ini['setup.ini'], spinners = Setup.spinners, ratios = r.car.ratios })
  Space.attach(space, r.base)
  local b = r.base
  T.ok(Util.isFinite(b.rideRefFuel), 'carburant de la mesure relevé')
  local function ride(change)
    local s = Space.apply(space, CarModel.defaultSetup(b), {})
    s.fuel = b.rideRefFuel
    for key, value in pairs(change or {}) do s[key] = value end
    return assert(CarModel.configure(b, s, { airTemp = 25 }))
  end
  local ref = ride()
  T.near(ref.rideF, b.rideHeightF, 1e-9, 'setup de la mesure : hauteur mesurée')
  T.near(ref.rideR, b.rideHeightR, 1e-9)
  -- 60 L de plus : plus bas, d'environ m·g·part / raideur
  local heavy = ride({ fuel = b.rideRefFuel + 60 })
  local dropF = b.rideHeightF - heavy.rideF
  PY.note('H04', string.format('+60 L : avant %.2f mm, arrière %.2f mm plus bas', dropF * 1000, (b.rideHeightR - heavy.rideR) * 1000))
  T.ok(dropF > 0.0005 and dropF < 0.01, 'écrasement ' .. dropF)
  T.ok(heavy.rideR < b.rideHeightR)
  -- pression à froid plus basse : pneu moins raide, plus bas
  local soft = ride({ pressureF = Space.apply(space, CarModel.defaultSetup(b), {}).pressureF - 3 })
  T.ok(soft.rideF < ref.rideF and soft.rideR == ref.rideR)
  -- MIN_HEIGHT (55 mm) : la tige qui descend l'avant à moins de 56 mm (marge 1 mm) est refusée...
  local rod0 = Space.apply(space, CarModel.defaultSetup(b), {}).rodF
  local low = ride({ rodF = rod0 - (b.rideHeightF - b.minHeight) + 0.0005 })
  T.ok(low.rideF > b.minHeight and low.rideF < b.minHeight + Config.K.minHeightMargin)
  T.ok(low.belowMinHeight, 'sous la marge et plus bas que le setup actuel')
  -- ... mais le setup actuel n'est jamais refusé : avec beaucoup de carburant il passe sous MIN_HEIGHT,
  -- c'est signalé
  local saved = b.rideHeightF
  b.rideHeightF = b.minHeight + 0.0008
  local full = ride({ fuel = b.rideRefFuel + 80 })
  T.no(full.belowMinHeight, 'setup actuel jamais refusé')
  T.ok(full.currentBelowMinHeight, 'setup actuel sous MIN_HEIGHT avec ce carburant : signalé')
  b.rideHeightF = saved
  -- voiture sans aile à effet de sol : hauteur de référence mesurée au stand seulement
  local bare = {}
  for key, value in pairs(b) do bare[key] = value end
  bare.wings = {}
  T.eq(CarModel.verifyRideFrame(bare, r.state).status, 'sans objet')
  r.state.flags.isInPit = false
  local away = CarModel.verifyRideFrame(bare, r.state)
  T.eq(away.status, 'non vérifié')
  T.contains(away.reason, 'au stand')
  r.state.flags.isInPit = true
end

return tests
