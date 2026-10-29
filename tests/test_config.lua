-- Tests du module src/config (schéma unique §15, modulation §10.2).
local T = require('t')
local Config = require('src/config')
local Util = require('src/util')

local tests = {}

tests['C01 schéma complet et défauts valides'] = function()
  local expected = { 'enabled', 'frameGuardMs', 'sliceBudgetMs', 'ds', 'optBudgetEvalsQ', 'optBudgetEvalsC',
    'fuelMarginPct', 'fuelQualiLaps', 'perfStab', 'wBal', 'wStab', 'wTraffic', 'wRob', 'drsTrafficPct',
    'driverMarginPct', 'calibrationAuto', 'language', 'debugLog' }
  for _, key in ipairs(expected) do T.ok(Config.byKey[key], 'réglage §15 présent : ' .. key) end
  local seen = {}
  for _, def in ipairs(Config.settings) do
    T.no(seen[def.key], 'clé unique : ' .. def.key)
    seen[def.key] = true
    T.ok(type(def.label) == 'string' and #def.label > 0, 'libellé : ' .. def.key)
    local value, fix = Config.validateOne(def, def.default)
    T.eq(value, def.default, 'défaut valide : ' .. def.key)
    T.eq(fix, nil)
    if def.kind == 'number' or def.kind == 'integer' then
      T.ok(def.min < def.max, 'bornes ordonnées : ' .. def.key)
    end
  end
  local d = Config.defaults()
  T.eq(d.perfStab, 0.6, 'D15 : perfStab = 0,6')
  T.eq(d.ds, 2, '§6 : ds = 2 m')
  T.eq(d.sliceBudgetMs, 2)
  T.eq(d.frameGuardMs, 4)
  T.eq(d.optBudgetEvalsQ, 1200)
  T.eq(d.optBudgetEvalsC, 400)
  T.eq(d.fuelMarginPct, 3)
  T.eq(d.drsTrafficPct, 30)
  T.eq(d.driverMarginPct, 0)
end

tests['C02 validation : types, non finis, bornes, entiers, énumérations'] = function()
  local v, fixes = Config.validate({
    enabled = 'oui', ds = 0 / 0, sliceBudgetMs = 100, perfStab = -2, optBudgetEvalsQ = 1234.6,
    language = 'de', debugLog = true, wBal = math.huge, inconnu = 5,
  })
  T.eq(v.enabled, true, 'type invalide -> défaut')
  T.eq(v.ds, 2, 'NaN -> défaut')
  T.eq(v.sliceBudgetMs, 8, 'borné au maximum')
  T.eq(v.perfStab, 0, 'borné au minimum')
  T.eq(v.optBudgetEvalsQ, 1235, 'arrondi entier')
  T.eq(v.language, 'en', 'énumération : valeur inconnue -> défaut (anglais)')
  T.eq(v.debugLog, true)
  T.eq(v.wBal, 1, 'infini -> défaut')
  T.eq(v.inconnu, nil, 'clé inconnue ignorée')
  T.ok(#fixes >= 6, 'corrections listées')
  local all = Config.validate(nil)
  T.eq(all.enabled, true)
  local again = Config.validate(v)
  for _, def in ipairs(Config.settings) do T.eq(again[def.key], v[def.key], 'idempotent : ' .. def.key) end
end

tests['C03 modulation des pénalités par perfStab (§10.2)'] = function()
  local s = Config.defaults()
  s.perfStab = 1
  T.near(Config.penaltyWeights(s).scale, 0.4, 1e-12, 'temps pur : 40 %')
  s.perfStab = 0
  T.near(Config.penaltyWeights(s).scale, 2.0, 1e-12, 'stabilité d\'abord : 200 %')
  s.perfStab = 0.6
  local w = Config.penaltyWeights(s)
  T.near(w.scale, 1.04, 1e-12, 'défaut 0,6')
  s.wBal, s.wRob = 2, 0.5
  w = Config.penaltyWeights(s)
  T.near(w.bal, 2.08, 1e-12)
  T.near(w.rob, 0.52, 1e-12)
  s.perfStab = 7
  T.near(Config.penaltyWeights(s).scale, 0.4, 1e-12, 'perfStab borné')
end

tests['C04 constantes internes finies et cohérentes'] = function()
  -- constantes numériques, listes et tables de bornes : toutes finies et positives
  local function check(key, value)
    if type(value) == 'boolean' or type(value) == 'string' then return end  -- ensembles et listes de noms
    if type(value) == 'table' then
      local count = 0
      for k, item in pairs(value) do
        count = count + 1
        check(key .. '.' .. tostring(k), item)
      end
      T.ok(count > 0, 'constante non vide : ' .. key)
    else
      T.ok(Util.isFinite(value), 'constante finie : ' .. key)
      T.ok(value >= 0, 'constante positive : ' .. key)
    end
  end
  for key, value in pairs(Config.K) do check(key, value) end
  for key, bounds in pairs(Config.K.calibBounds) do
    T.ok(bounds[1] < 1 and bounds[2] >= 1, key .. ' : 1 dans les bornes de calibration')
  end
  local K = Config.K
  T.eq(K.logCapacity, 200, '§16.4 : journal de 200 lignes')
  T.eq(K.dtMax, 0.25, '§5 : dt borné à 0,25 s')
  T.eq(K.trackMinLength, 200)
  T.eq(K.trackMaxLength, 75000)
  T.eq(K.trackLengthTolSim, 0.005, '§7.4 : ±0,5 %')
  T.ok(K.trackMinLength < K.trackMaxLength)
  T.ok(K.slowFpsSliceFactor > 0 and K.slowFpsSliceFactor <= 1)
end

return tests
