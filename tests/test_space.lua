-- Tests de src/setup_space (J4, §10.3) : classement des réglages, conversions cran -> physique,
-- vérification contre l'état du jeu (hôte simulé cohérent, avec écart volontaire), rendu du fichier.
local T = require('t')
local Util = require('src/util')
local Datasource = require('src/datasource')
local CarModel = require('src/car_model')
local Space = require('src/setup_space')
local Fake = require('fakehost')

local SYNC = Util.syncContext()
local tests = {}

local function load(carId, opts)
  opts = opts or {}
  opts.car = require('fixtures/cars/' .. carId)
  opts.track = require('fixtures/tracks/monza')
  local h = Fake.new(opts)
  local car = Datasource.readCar(h, 0, SYNC)
  local setup = Datasource.readSetup(h, SYNC)
  local state = Datasource.readCarState(h, 0)
  local space = Space.build({ setupIni = car.ini['setup.ini'], spinners = setup.spinners, ratios = car.ratios })
  return { h = h, car = car, setup = setup, state = state, space = space }
end

local function skippedReason(space, name)
  for _, s in ipairs(space.skipped) do
    if s.name == name then return s.reason end
  end
  return nil
end

tests['P01 classement des sections de setup.ini'] = function()
  local cases = {
    { 'WING_2', 'wing', Space.LARGE }, { 'PRESSURE_LF', 'pressure', Space.LARGE }, { 'CAMBER_RR', 'camber', Space.REDUCED },
    { 'SPRING_RATE_LR', 'spring', Space.EXCLUDED }, { 'SPRING_RATE_HF', 'heave', Space.EXCLUDED },
    { 'ROD_LENGTH_HF', 'rod', Space.EXCLUDED }, { 'ARB_REAR', 'arb', Space.REDUCED }, { 'FRONT_BIAS', 'brakeBias', Space.LARGE },
    { 'REAR_DIFF_POWER', 'diffPower', Space.REDUCED }, { 'FUEL', 'fuel', Space.EXCLUDED }, { 'GEAR_7', 'gear', Space.LARGE },
    { 'BRAKE_POWER_MULT', 'brakePower', Space.REDUCED },
    { 'FINAL_GEAR_RATIO', 'final', Space.LARGE }, { 'ENGINE_LIMITER', 'limiter', Space.LARGE },
  }
  for _, c in ipairs(cases) do
    local rule = Space.classify(c[1])
    T.ok(rule, c[1])
    T.eq(rule.kind, c[2], c[1])
    T.eq(rule.class, c[3], c[1])
  end
  -- toute section reçoit une règle : réglage conservé avec sa raison (§10.3)
  local kept = {
    { 'DAMP_BUMP_LF', 'damperSlow', 'damperSlowF' }, { 'DAMP_REBOUND_RF', 'damperSlow', 'damperSlowF' },
    { 'DAMP_FAST_REBOUND_LR', 'damperFast', 'damperFastR' }, { 'BUMP_STOP_RATE_LF', 'bumpStop', 'bumpStopF' },
    { 'PACKER_RANGE_RR', 'packer', 'packerR' }, { 'TOE_OUT_RR', 'toe', 'toeR' }, { 'DIFF_COAST', 'diffCoast', 'diffCoast' },
    { 'DIFF_PRELOAD', 'diffPreload', 'diffPreload' }, { 'CUSTOM_SCRIPT_ITEM_3', 'script', 'CUSTOM_SCRIPT_ITEM_3' },
    { 'BRAKE_DUCT_F', 'brakeDuct', 'BRAKE_DUCT_F' }, { 'AWD_FRONT_TORQUE_DISTRIBUTION', 'awd', 'AWD_FRONT_TORQUE_DISTRIBUTION' },
    { 'CENTER_DIFF_PRELOAD', 'awd', 'CENTER_DIFF_PRELOAD' }, { 'DAMP_BUMP_HF', 'heaveDamper', 'DAMP_BUMP_HF' },
    { 'ABS', 'electronic', 'ABS' }, { 'TRACTION_CONTROL', 'electronic', 'TRACTION_CONTROL' }, { 'FUEL_MAP', 'engineMap', 'FUEL_MAP' },
    { 'MYSTERE', 'unknown', 'MYSTERE' },
  }
  for _, c in ipairs(kept) do
    local rule = Space.classify(c[1])
    T.eq(rule.kind, c[2], c[1])
    T.eq(rule.key, c[3], c[1])
    T.ok(rule.class ~= Space.LARGE and rule.class ~= Space.REDUCED, c[1] .. ' : conservé')
    T.ok(rule.reason and rule.reason ~= '', c[1] .. ' : raison')
  end
  T.contains(Space.classify('TOE_OUT_LF').reason, 'transitoire')
  T.contains(Space.classify('CUSTOM_SCRIPT_ITEM_0').reason, 'script')
end

tests['P02 espace des quatre voitures : groupes, exclusions, bornes'] = function()
  for _, carId in ipairs({ 'formula_k', 'lamborghini_huracan_gt3_evo2', 'whk_dtm_2026', 'urd_px1_aura' }) do
    local r = load(carId)
    local space = r.space
    T.ok(space.byKey.pressureF and #space.byKey.pressureF.members == 2, carId .. ' : pression avant groupée')
    T.ok(space.byKey.brakeBias, carId .. ' : répartition')
    T.ok(space.byKey.gear1 and space.byKey.final, carId .. ' : boîte')
    T.eq(space.byKey.camberF.class, Space.REDUCED)
    T.eq(skippedReason(space, 'DAMP_BUMP_LF'), nil)
    T.eq(#space.byKey.damperSlowF.members, 4, carId .. ' : compression et détente avant groupées')
    for _, var in ipairs(space.vars) do
      T.ok(var.lo <= 0 and var.hi >= 0, carId .. ' ' .. var.key .. ' : 0 dans les bornes')
      T.ok(var.lo >= var.rangeLo and var.hi <= var.rangeHi, carId .. ' ' .. var.key .. ' : bornes dans la plage')
      local radius = var.class == Space.LARGE and 6 or 3
      if var.class == Space.LARGE or var.class == Space.REDUCED then
        T.ok(var.hi - var.lo <= 2 * radius, carId .. ' ' .. var.key .. ' : rayon')
      end
    end
    -- hauteur de caisse : non optimisée au J4 (repère des LUT aéro non vérifié)
    T.eq(space.byKey.rodF.class, Space.EXCLUDED, carId .. ' : hauteur de caisse')
    T.contains(space.byKey.rodF.reason, 'non vérifié')
  end
  local fk = load('formula_k').space
  T.ok(fk.byKey.heaveF, 'formula_k : ressort de pilonnage avant')
  T.ok(fk.byKey.diffPower, 'formula_k : REAR_DIFF_POWER')
  local dtm = load('whk_dtm_2026').space
  T.contains(dtm.byKey.CUSTOM_SCRIPT_ITEM_1.reason, 'script')
end

tests['P07 chaque cran du setup a un statut et une raison (§10.3), sur les quatre voitures'] = function()
  for _, carId in ipairs({ 'formula_k', 'lamborghini_huracan_gt3_evo2', 'whk_dtm_2026', 'urd_px1_aura' }) do
    local r = load(carId)
    local rows = Space.statusRows(r.space)
    local seen = {}
    for _, row in ipairs(rows) do
      T.ok(row.status == 'optimisé' or row.status == 'conservé' or row.status == 'non touché', carId .. ' ' .. row.label)
      T.ok(row.detail and row.detail ~= '', carId .. ' ' .. row.label .. ' : raison')
      T.ok(row.label and row.label ~= '', carId .. ' : libellé')
      for _, name in ipairs(row.names) do
        T.eq(seen[name], nil, carId .. ' ' .. name .. ' listé deux fois')
        seen[name] = true
      end
    end
    local missing = {}
    for _, sp in ipairs(r.setup.spinners) do
      if not seen[sp.name] then missing[#missing + 1] = sp.name end
    end
    T.eq(#missing, 0, carId .. ' : crans sans statut : ' .. table.concat(missing, ', '))
    PY.note('P07', carId .. ' : ' .. #r.setup.spinners .. ' crans, ' .. #rows .. ' lignes de statut')
  end
end

tests['P03 conversions cran -> grandeur physique'] = function()
  local r = load('lamborghini_huracan_gt3_evo2')
  local s = r.space
  local function member(name) return s.members[name] end
  -- pression : psi ; carrossage : dixièmes de degré ; ressort : N/mm -> N/m
  T.near(Space.physicalOf(member('PRESSURE_LF'), 27), 27, 1e-12)
  T.near(Space.physicalOf(member('CAMBER_LF'), -35), -3.5, 1e-12)
  T.near(Space.physicalOf(member('SPRING_RATE_LF'), 120), 120000, 1e-9)
  -- SHOW_CLICKS=2 : numéro de cran depuis MIN (ARB_FRONT 19000..154000 pas 9000 ; ROD 0..500 pas 10, 0,1 mm)
  T.near(Space.physicalOf(member('ARB_FRONT'), 3), 19000 + 3 * 9000, 1e-9)
  T.near(Space.physicalOf(member('ROD_LENGTH_LF'), 4), 40 * 1e-4, 1e-12)
  T.near(Space.physicalOf(member('FRONT_BIAS'), 62), 0.62, 1e-12)
  -- carrossage à SHOW_CLICKS=2 : cran depuis MIN (setup.ini en dixièmes de degré), puis 0,1° par unité
  local clicked = {}
  for key, value in pairs(member('CAMBER_LF')) do clicked[key] = value end
  clicked.showClicks, clicked.iniMin, clicked.iniStep = 2, -50, 1
  T.near(Space.physicalOf(clicked, 5), -4.5, 1e-12)
  -- rapports : rang dans le fichier .rto
  local g1 = member('GEAR_1')
  T.near(Space.physicalOf(g1, 0), g1.rto[1].ratio, 1e-12)
  T.near(Space.physicalOf(g1, 2), g1.rto[3].ratio, 1e-12)
  -- les valeurs d'usine converties tombent dans les plages de setup.ini (cohérence des unités)
  local base = CarModel.build(r.car, nil)
  local springLo, springHi = Space.physicalOf(member('SPRING_RATE_LF'), member('SPRING_RATE_LF').min),
    Space.physicalOf(member('SPRING_RATE_LF'), member('SPRING_RATE_LF').max)
  T.ok(base.springF >= springLo and base.springF <= springHi, 'ressort d\'usine dans la plage : ' .. base.springF)
  local arbLo, arbHi = Space.physicalOf(member('ARB_FRONT'), member('ARB_FRONT').min),
    Space.physicalOf(member('ARB_FRONT'), member('ARB_FRONT').max)
  T.ok(base.arbF >= arbLo and base.arbF <= arbHi, 'barre d\'usine dans la plage : ' .. base.arbF)
end

tests['P04 application au setup physique du modèle'] = function()
  local r = load('lamborghini_huracan_gt3_evo2')
  local base = CarModel.build(r.car, nil)
  local gearsBefore = { unpack(base.gears) }
  local setup = Space.apply(r.space, CarModel.defaultSetup(base), { pressureF = 2, brakeBias = -3, gear2 = 1, wing2 = 1 })
  local s = r.space.byKey
  T.near(setup.pressureF, Space.physical(s.pressureF, 2), 1e-12)
  T.near(setup.pressureF - Space.physical(s.pressureF, 0), 2, 1e-12, '+2 crans de 1 psi')
  T.near(setup.brakeBias, Space.physical(s.brakeBias, 0) - 0.03, 1e-12)
  T.near(setup.gears[2], s.gear2.members[1].rto[s.gear2.members[1].current + 2].ratio, 1e-12)
  T.near(setup.wingAngles[2], Space.physical(s.wing2, 0) + 1, 1e-12)
  for i, g in ipairs(gearsBefore) do T.eq(base.gears[i], g, 'rapports d\'usine non modifiés') end
  Space.attach(r.space, base)
  T.near(base.rodRefF, Space.physical(s.rodF, 0), 1e-12, 'référence de hauteur = tiges du setup courant')
  local eff = assert(CarModel.configure(base, setup, { airTemp = 25 }))
  T.near(eff.rideF, base.rideHeightF, 1e-12, 'tige inchangée : hauteur de référence')
end

tests['P05 vérification contre l\'état du jeu, écart volontaire exclu'] = function()
  local r = load('lamborghini_huracan_gt3_evo2')
  local base = CarModel.build(r.car, r.state)
  local rows = Space.verify(r.space, r.state, base)
  T.ok(#rows >= 10)
  local s = r.space.byKey
  for _, key in ipairs({ 'pressureF', 'pressureR', 'brakeBias', 'diffPower', 'gear1', 'gear6', 'final', 'wing2', 'limiter' }) do
    T.eq(s[key].status, 'vérifié', key)
  end
  T.eq(s.springF.status, 'déduit', 'ressort : rien de mesurable')
  local listed = {}
  for _, var in ipairs(Space.optimizable(r.space)) do listed[var.key] = true end
  T.ok(listed.brakeBias and listed.pressureF and listed.arbF and listed.wing2 and listed.gear3)
  T.ok(listed.camberF and listed.brakePower and listed.diffPower, 'carrossage, freinage, différentiel optimisés (contreparties)')
  for _, key in ipairs({ 'rodF', 'springF', 'damperSlowF', 'fuel', 'toeF', 'diffCoast' }) do
    T.ok(not listed[key], key .. ' conservé')
  end
  -- écart volontaire : la répartition simulée ne correspond plus au cran
  local bad = load('lamborghini_huracan_gt3_evo2', { stateMismatch = 'FRONT_BIAS' })
  Space.verify(bad.space, bad.state, base)
  T.eq(bad.space.byKey.brakeBias.status, 'écart')
  T.contains(bad.space.byKey.brakeBias.reason, 'non optimisé')
  for _, var in ipairs(Space.optimizable(bad.space)) do T.ok(var.key ~= 'brakeBias', 'réglage en écart exclu') end
  -- D20 : un cran verrouillé n'entre jamais dans l'espace
  local spinners = {}
  for i, sp in ipairs(r.setup.spinners) do
    spinners[i] = sp
    if sp.name == 'FRONT_BIAS' then
      spinners[i] = setmetatable({ readOnly = true }, { __index = sp })
    end
  end
  local locked = Space.build({ setupIni = r.car.ini['setup.ini'], spinners = spinners, ratios = r.car.ratios })
  T.eq(locked.byKey.brakeBias, nil)
  T.contains(skippedReason(locked, 'FRONT_BIAS'), 'D20')
end

tests['P06 rendu du fichier : seuls les VALUE modifiés, contrôles de grille'] = function()
  local r = load('lamborghini_huracan_gt3_evo2')
  local values, errors = Space.values(r.space, { pressureF = 2, gear3 = 1, brakeBias = 4 })
  T.eq(#errors, 0)
  local text = assert(Space.render(r.setup.text, values))
  local out = Util.parseIni(text)
  local before = Util.parseIni(r.setup.text)
  for _, section in ipairs(before.order) do
    local old = Util.iniGet(before, section, 'VALUE')
    local new = Util.iniGet(out, section, 'VALUE')
    if values[section] then
      T.eq(tonumber(new), values[section], section .. ' modifié')
    else
      T.eq(new, old, section .. ' inchangé')
    end
  end
  T.eq(Util.iniGet(out, 'CAR', 'MODEL'), r.h.carId, 'métadonnées conservées')
  T.eq(tonumber(Util.iniGet(out, 'PRESSURE_LF', 'VALUE')), r.space.members.PRESSURE_LF.current + 2)
  T.eq(tonumber(Util.iniGet(out, 'PRESSURE_RF', 'VALUE')), r.space.members.PRESSURE_RF.current + 2)
  -- hors plage, hors grille, non optimisable : refus
  local _, bad = Space.values(r.space, { pressureF = 1000 })
  T.ok(#bad == 2, 'deux roues hors plage')
  local _, notOpt = Space.values(r.space, { springF = 1 })
  T.contains(notOpt[1], 'non optimisable')
  -- CSP qui écrit INTERNAL_GEAR_n / FINAL_RATIO : la boîte est écrite sous ces noms
  local internal = load('lamborghini_huracan_gt3_evo2', { gearNames = 'internal' })
  local v2 = Space.values(internal.space, { gear3 = 1, final = 1 })
  local t2 = assert(Space.render(internal.setup.text, v2))
  local p2 = Util.parseIni(t2)
  T.eq(tonumber(Util.iniGet(p2, 'INTERNAL_GEAR_3', 'VALUE')), v2.GEAR_3)
  T.eq(tonumber(Util.iniGet(p2, 'FINAL_RATIO', 'VALUE')), v2.FINAL_GEAR_RATIO)
  -- section introuvable : refus explicite, jamais d'oubli silencieux
  local missing, why = Space.render('[CAR]\nMODEL=x\n', { GEAR_1 = 2 })
  T.eq(missing, nil)
  T.contains(why[1], 'absente')
  T.eq(Space.render('', {}), nil)
end

return tests
