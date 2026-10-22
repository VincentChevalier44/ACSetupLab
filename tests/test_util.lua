-- Tests du module src/util (noyau pur).
local T = require('t')
local Util = require('src/util')
local Fake = require('fakehost')

local tests = {}

local CAR_FIXTURES = { 'formula_k', 'lamborghini_huracan_gt3_evo2', 'urd_px1_aura', 'whk_dtm_2026' }

tests['U01 nombres : finitude, bornes, division protégée'] = function()
  T.ok(Util.isFinite(1.5))
  T.no(Util.isFinite(0 / 0))
  T.no(Util.isFinite(math.huge))
  T.no(Util.isFinite(-math.huge))
  T.no(Util.isFinite('1'))
  T.eq(Util.clamp(5, 0, 3), 3)
  T.eq(Util.clamp(-1, 0, 3), 0)
  T.near(Util.lerp(0.4, 2.0, 0.5), 1.2, 1e-12)
  T.finite(Util.safeDiv(1, 0))
  T.ok(Util.safeDiv(1, 0) > 0, 'signe conservé (+)')
  T.ok(Util.safeDiv(1, -1e-15) < 0, 'signe conservé (-)')
  T.eq(Util.safeDiv(6, 3), 2)
  T.near(Util.round(2.26, 0.1), 2.3, 1e-12)
  T.eq(Util.finiteOr(0 / 0, 7), 7)
  T.eq(Util.ema(nil, 4, 0.5), 4)
  T.eq(Util.ema(2, 4, 0.5), 3)
  T.eq(Util.ema(2, 4, 3), 4, 'alpha borné à 1')
end

tests['U02 parseNumber : commentaires, espaces, valeurs non finies'] = function()
  T.eq(Util.parseNumber('1334'), 1334)
  T.eq(Util.parseNumber('  -3.5\t\t; degrees'), -3.5)
  T.eq(Util.parseNumber('2.6428\t'), 2.6428)
  T.eq(Util.parseNumber(12), 12)
  T.eq(Util.parseNumber('1e400'), nil)
  T.eq(Util.parseNumber('nan'), nil)
  T.eq(Util.parseNumber('inf'), nil)
  T.eq(Util.parseNumber(''), nil)
  T.eq(Util.parseNumber('abc'), nil)
  T.eq(Util.parseNumber(string.rep('1', 100)), nil, 'chaîne trop longue refusée')
  T.eq(Util.parseNumber(0 / 0), nil)
  T.eq(Util.parseNumber(nil), nil)
end

tests['U03 parseNumberList'] = function()
  local l = Util.parseNumberList('0.0,-0.39,0.285')
  T.eq(#l, 3)
  T.eq(l[2], -0.39)
  T.eq(Util.parseNumberList('1, x, 3'), nil)
  T.eq(Util.parseNumberList(''), nil)
  T.eq(Util.parseNumberList(string.rep('1,', 40), 16), nil, 'trop d\'éléments')
  T.eq(#Util.parseNumberList('1.80,1.00,3.79 ; inertie'), 3)
end

tests['U04 parseIni : sections, commentaires, BOM, CRLF, doublons, bornes'] = function()
  local text = '\239\187\191[HEADER]\r\nVERSION=2 ; commentaire\r\n// séparation\r\n;[CACHEE]\r\n'
    .. '[BASIC]\nTOTALMASS = 1334\n  INERTIA=1.80,1.00,3.79\n\n[BASIC]\nTOTALMASS=1400\nSANS_EGAL\n=vide\n'
  local ini = Util.parseIni(text)
  T.eq(#ini.order, 2)
  T.eq(ini.order[1], 'HEADER')
  T.eq(Util.iniGet(ini, 'HEADER', 'VERSION'), '2')
  T.eq(Util.iniGet(ini, 'BASIC', 'TOTALMASS'), '1400', 'dernière valeur retenue')
  T.eq(Util.iniGet(ini, 'BASIC', 'INERTIA'), '1.80,1.00,3.79')
  T.eq(Util.iniGet(ini, 'CACHEE', 'X'), nil)
  T.eq(Util.iniNumber(ini, 'BASIC', 'TOTALMASS', 0), 1400)
  T.eq(Util.iniNumber(ini, 'BASIC', 'ABSENT', -1), -1)
  T.no(ini.truncated)
  local many = {}
  for i = 1, 50 do many[#many + 1] = '[S' .. i .. ']\nK=1\n' end
  local limited = Util.parseIni(table.concat(many), { maxBytes = 1e6, maxSections = 10, maxKeys = 4, maxValueChars = 8 })
  T.eq(#limited.order, 10)
  T.ok(limited.truncated)
  local keys = Util.parseIni('[A]\nK1=1\nK2=2\nK3=3\nK4=4\nK5=5\nLONG=' .. string.rep('x', 50) .. '\n',
    { maxBytes = 1e6, maxSections = 10, maxKeys = 4, maxValueChars = 8 })
  T.eq(Util.iniGet(keys, 'A', 'K5'), nil, 'clé au-delà de la borne ignorée')
  local bytes = Util.parseIni('[A]\nK=' .. string.rep('y', 100) .. '\n[B]\nK=1\n',
    { maxBytes = 20, maxSections = 10, maxKeys = 10, maxValueChars = 1000 })
  T.eq(bytes.sections.B, nil)
  T.ok(bytes.truncated)
  T.eq(#Util.parseIni(nil).order, 0)
end

-- Recoupement avec l'analyseur indépendant de l'hôte simulé sur tous les INI de référence.
tests['U05 parseIni ≡ analyseur CSP simulé sur les INI de référence'] = function()
  local compared = 0
  for _, id in ipairs(CAR_FIXTURES) do
    local fixture = require('fixtures/cars/' .. id)
    for name, text in pairs(fixture.files) do
      if name:match('%.ini$') then
        local mine = Util.parseIni(text)
        local csp = Fake.parseIniCsp(text, 'split')
        for section, keys in pairs(csp) do
          for key, list in pairs(keys) do
            local joined = table.concat(list, ',')
            local value = Util.iniGet(mine, section, key)
            T.ok(value ~= nil, id .. '/' .. name .. ' [' .. section .. '] ' .. key .. ' absent')
            T.eq((value:gsub('%s*,%s*', ',')), joined, id .. '/' .. name .. ' [' .. section .. '] ' .. key)
            compared = compared + 1
          end
        end
      end
    end
  end
  T.ok(compared > 2000, 'au moins 2000 valeurs comparées (' .. compared .. ')')
end

tests['U06 LUT : tri, doublons, non finis, bornes, recherche dichotomique'] = function()
  local lut = Util.lutNew({ 3, 1, 2, 2, 0 / 0, 5 }, { 30, 10, 20, 99, 1, 50 })
  T.eq(lut.n, 4)
  T.eq(lut.x[1], 1)
  T.eq(lut.y[2], 20, 'premier doublon conservé')
  T.eq(Util.lutEval(lut, 0), 10, 'borné à gauche')
  T.eq(Util.lutEval(lut, 9), 50, 'borné à droite')
  T.eq(Util.lutEval(lut, 2.5), 25)
  T.eq(Util.lutEval(lut, 4), 40)
  T.eq(Util.lutNew({ 0 / 0 }, { 1 }), nil)
  T.eq(Util.lutNew({}, {}), nil)
  local single = Util.lutNew({ 4 }, { 7 })
  T.eq(Util.lutEval(single, -100), 7)
  local x0, x1, y0, y1 = Util.lutRange(lut)
  T.eq(x0, 1)
  T.eq(x1, 5)
  T.eq(y0, 10)
  T.eq(y1, 50)
  -- comparaison avec un parcours linéaire sur des données pseudo-aléatoires
  local rng = Util.rngNew(42)
  local xs, ys = {}, {}
  for i = 1, 300 do
    xs[i] = Util.rngRange(rng, -100, 100)
    ys[i] = Util.rngRange(rng, -5, 5)
  end
  local big = Util.lutNew(xs, ys)
  for _ = 1, 500 do
    local x = Util.rngRange(rng, -120, 120)
    local expected
    if x <= big.x[1] then
      expected = big.y[1]
    elseif x >= big.x[big.n] then
      expected = big.y[big.n]
    else
      for i = 1, big.n - 1 do
        if x >= big.x[i] and x <= big.x[i + 1] then
          expected = big.y[i] + (big.y[i + 1] - big.y[i]) * (x - big.x[i]) / (big.x[i + 1] - big.x[i])
          break
        end
      end
    end
    T.near(Util.lutEval(big, x), expected, 1e-9)
  end
end

tests['U07 parseLutText : fichiers et LUT en ligne'] = function()
  local lut = Util.parseLutText('; puissance\n0|100\n250|130 ; commentaire\n500 | 150 // fin\nmauvais\n750|x\n')
  T.eq(lut.n, 3)
  T.eq(Util.lutEval(lut, 375), 140)
  local inline = Util.parseLutText('(|-0.3=0.0|-0.1=1.0|1=1.0|)')
  T.eq(inline.n, 3)
  T.near(Util.lutEval(inline, -0.2), 0.5, 1e-12)
  T.eq(Util.parseLutText('rien'), nil)
  T.eq(Util.parseLutText(nil), nil)
  local capped = {}
  for i = 1, 100 do capped[#capped + 1] = i .. '|' .. i end
  T.eq(Util.parseLutText(table.concat(capped, '\n'), 10).n, 10)
  local fixture = require('fixtures/cars/lamborghini_huracan_gt3_evo2')
  local power = Util.parseLutText(fixture.files['power.lut'])
  T.ok(power.n >= 20, 'power.lut de la Huracán : ' .. power.n .. ' points')
end

tests['U08 parseRto'] = function()
  local r = Util.parseRto('10//50|5.0000\n12//47|3.9166\n\nmauvais\nx|-1\ny|abc\n')
  T.eq(#r, 2)
  T.eq(r[1].label, '10//50')
  T.eq(r[2].ratio, 3.9166)
  T.eq(#Util.parseRto(nil), 0)
  local fixture = require('fixtures/cars/lamborghini_huracan_gt3_evo2')
  T.ok(#Util.parseRto(fixture.files['final.rto']) >= 10)
end

tests['U09 RNG déterministe et empreintes'] = function()
  local a, b = Util.rngNew(123), Util.rngNew(123)
  local c = Util.rngNew(124)
  local sum, differs = 0, false
  for _ = 1, 10000 do
    local x, y = Util.rngNext(a), Util.rngNext(b)
    T.eq(x, y)
    T.ok(x >= 0 and x < 1)
    if Util.rngNext(c) ~= x then differs = true end
    sum = sum + x
  end
  T.ok(differs)
  T.near(sum / 10000, 0.5, 0.02, 'moyenne uniforme')
  for _, seed in ipairs({ 0, -5, 2147483647, 0 / 0, 1e300 }) do
    local r = Util.rngNew(seed)
    T.ok(r.state >= 1 and r.state < 2147483647, 'graine normalisée : ' .. tostring(seed))
    T.finite(Util.rngNext(r))
  end
  T.eq(Util.hashString('spa|car'), Util.hashString('spa|car'))
  T.ok(Util.hashString('spa|car') ~= Util.hashString('spa|cas'))
  T.ok(Util.hashString('') >= 1)
end

tests['U10 journal circulaire borné et débit limité'] = function()
  local log = Util.logNew(200, 2)
  for i = 1, 450 do Util.logAdd(log, i * 3, 'INFO', 'c' .. i, 'ligne ' .. i) end
  T.eq(log.count, 200)
  local entries = Util.logEntries(log)
  T.eq(#entries, 200)
  T.eq(entries[1].text, 'ligne 251')
  T.eq(entries[200].text, 'ligne 450')
  local limited = Util.logNew(10, 2)
  T.ok(Util.logAdd(limited, 0, 'WARN', 'x', 'a'))
  T.no(Util.logAdd(limited, 1, 'WARN', 'x', 'b'), 'répétition filtrée')
  T.ok(Util.logAdd(limited, 2.5, 'WARN', 'x', 'c'))
  T.eq(limited.dropped, 1)
  T.no(Util.logAdd(limited, 10, 'DEBUG', 'd', 'détail'), 'DEBUG filtré par défaut')
  limited.maxLevel = Util.LEVELS.DEBUG
  T.ok(Util.logAdd(limited, 10, 'DEBUG', 'd', 'détail'))
  local codes = Util.logNew(5, 0)
  for i = 1, 2000 do Util.logAdd(codes, i, 'INFO', 'code' .. i, 'x') end
  T.ok(codes.codes <= 512, 'table des codes bornée')
  local long = Util.logNew(2, 0)
  Util.logAdd(long, 0, 'INFO', 'l', string.rep('z', 5000))
  T.eq(#Util.logEntries(long)[1].text, 400)
end

local function fakeClock()
  local c = { now = 0 }
  c.fn = function() return c.now end
  return c
end

tests['U11 ordonnanceur : tranches, pcall, erreurs, annulation, quota'] = function()
  local s = Util.schedulerNew()
  local clock = fakeClock()
  local steps, done = 0, {}
  Util.schedulerAdd(s, 'a', function(ctx)
    for _ = 1, 20 do
      clock.now = clock.now + 0.0005
      steps = steps + 1
      -- rendre la main à travers un pcall (LuaJIT le permet)
      local ok = pcall(function() ctx.tick() end)
      T.ok(ok)
    end
    return 'fini'
  end, function(ok, value, cpu)
    done.a = { ok, value, cpu }
  end)
  Util.schedulerAdd(s, 'b', function() error('panne simulée') end, function(ok, value) done.b = { ok, value } end)
  Util.schedulerAdd(s, 'c', function(ctx) for _ = 1, 3 do ctx.tick() end end, function(ok, value) done.c = { ok, value } end)
  local slices = 0
  while Util.schedulerBusy(s) and slices < 100 do
    Util.schedulerStep(s, clock.fn, 0.002, 1000)
    slices = slices + 1
  end
  T.eq(steps, 20)
  T.ok(slices >= 6 and slices <= 8, 'tranches de 2 ms : ' .. slices)
  T.eq(done.a[1], true)
  T.eq(done.a[2], 'fini')
  T.near(done.a[3], 10, 1e-6, 'temps CPU cumulé (ms)')
  T.eq(done.b[1], false)
  T.contains(done.b[2], 'panne simulée')
  T.eq(done.c[1], true)
  T.eq(s.stats.failed, 1)
  T.eq(s.stats.completed, 2)
  T.ok(s.stats.maxSliceMs <= 2 + 1e-9, 'rendu prédictif : aucune tranche au-delà du budget')
  T.near(s.stats.maxUnitMs, 0.5, 1e-9)

  -- annulation de la tâche courante et des tâches en attente
  local s2 = Util.schedulerNew()
  local cancelled = {}
  local counter = 0
  Util.schedulerAdd(s2, 'long', function(ctx) while true do counter = counter + 1; ctx.tick() end end,
    function(ok, value) cancelled.long = { ok, value } end)
  Util.schedulerAdd(s2, 'next', function() end, function(ok, value) cancelled.next = { ok, value } end)
  Util.schedulerStep(s2, nil, 0, 5)
  T.eq(counter, 5, 'quota de repli respecté')
  Util.schedulerCancel(s2)
  T.no(Util.schedulerBusy(s2))
  T.eq(cancelled.long[2], 'cancelled')
  T.eq(cancelled.next[2], 'cancelled')
  T.eq(s2.stats.cancelled, 2)
  T.no(Util.schedulerStep(s2, nil, 0, 5), 'plus rien à exécuter')
  -- annulation sélective
  local s3 = Util.schedulerNew()
  Util.schedulerAdd(s3, 'x', function() end)
  Util.schedulerAdd(s3, 'y', function() end)
  Util.schedulerCancel(s3, 'x')
  T.eq(#s3.queue, 1)
  T.eq(s3.queue[1].name, 'y')
  -- contexte synchrone
  local sync = Util.syncContext()
  for _ = 1, 10 do sync.tick() end
end

tests['U15 ordonnanceur : rendu prédictif après une unité longue'] = function()
  local s = Util.schedulerNew(0.5)
  local clock = fakeClock()
  local perSlice, current = {}, 0
  Util.schedulerAdd(s, 'p', function(ctx)
    clock.now = clock.now + 0.0015   -- unité longue (1,5 ms)
    current = current + 1
    ctx.tick()
    for _ = 1, 40 do
      clock.now = clock.now + 0.0001 -- unités courtes (0,1 ms)
      current = current + 1
      ctx.tick()
    end
  end)
  while Util.schedulerBusy(s) do
    current = 0
    Util.schedulerStep(s, clock.fn, 0.002, 1000)
    perSlice[#perSlice + 1] = current
  end
  T.eq(perSlice[1], 1, "après l'unité longue, la main est rendue (1,5 + 1,5 > 2 ms)")
  T.ok(s.stats.maxSliceMs <= 2 + 1e-9)
  T.ok(perSlice[#perSlice - 1] >= 10, "l'estimation décroît : tranches pleines ensuite")
  local ctx = s.ctx
  T.eq(ctx.now(), nil, "pas d'horloge hors tranche")
  T.eq(Util.syncContext().now(), nil)
end

-- Relecture J0+J1, constat n° 2 : avant correction, 40 000 espaces coûtaient 3,9 à 6,9 s (gel).
tests['U16 analyseurs en temps linéaire sur lignes pathologiques'] = function()
  local blanks = string.rep(' ', 40000)
  local cases = {
    { 'trim blancs seuls', function() return Util.trim(blanks) end },
    { 'trim blancs internes', function() return Util.trim('a' .. blanks .. 'b') end },
    { 'parseIni ligne de blancs', function() return Util.parseIni('[A]\n' .. blanks .. 'K' .. blanks .. '=1\n') end },
    { 'parseIni sans égal', function() return Util.parseIni('[A]\n' .. blanks .. 'x' .. blanks .. '\n') end },
    { 'parseRto sans barre', function() return Util.parseRto(blanks .. 'x' .. blanks) end },
    { 'parseRto libellé de blancs', function() return Util.parseRto(blanks .. '|' .. blanks .. '3.5') end },
    { 'parseLutText sans barre', function() return Util.parseLutText(blanks .. '1' .. blanks) end },
    { 'parseLutText en ligne', function() return Util.parseLutText('(' .. string.rep('|' .. blanks, 3) .. ')') end },
    { 'parseNumberList', function() return Util.parseNumberList(string.rep(' 1,', 20000)) end },
  }
  for _, case in ipairs(cases) do
    local started = PY.clock()
    case[2]()
    local ms = (PY.clock() - started) * 1000
    T.ok(ms < 50, case[1] .. ' : ' .. string.format('%.1f', ms) .. ' ms')
  end
  T.eq(Util.trim(blanks), '')
  T.eq(Util.trim(' \t a b \n'), 'a b')
  local ini = Util.parseIni('[A]\nK=' .. string.rep('v', 10000) .. '\n')
  T.ok(ini.truncated, 'ligne bornée signalée')
  T.eq(#Util.parseRto('x' .. string.rep(' ', 100) .. '|' .. string.rep(' ', 100) .. '4.5 ; c\n'), 1)
end

tests['U17 repli sans horloge : poids des unités'] = function()
  local s = Util.schedulerNew()
  local units = 0
  Util.schedulerAdd(s, 'w', function(ctx)
    for _ = 1, 10 do
      units = units + 1
      ctx.tick(25)
    end
  end)
  Util.schedulerStep(s, nil, 0, 100)
  T.eq(units, 4, 'quota de 100 = 4 appels CSP de poids 25')
  Util.schedulerStep(s, nil, 0, 100)
  T.eq(units, 8)
end

tests['U12 dates sans os.* (cas calculés par Python)'] = function()
  for _, case in ipairs(PY.epochCases) do
    local d = Util.civilFromEpoch(case[1])
    T.eq(d.year, case[2], 'année ' .. case[1])
    T.eq(d.month, case[3], 'mois ' .. case[1])
    T.eq(d.day, case[4], 'jour ' .. case[1])
    T.eq(d.hour, case[5], 'heure ' .. case[1])
    T.eq(d.min, case[6], 'minute ' .. case[1])
    T.eq(d.sec, case[7], 'seconde ' .. case[1])
  end
  T.eq(Util.formatStamp(951782400), '20000229-000000')
  -- inverse (décalage de l'heure locale, noms de fichiers)
  for _, case in ipairs(PY.epochCases) do
    T.eq(Util.epochFromCivil(case[2], case[3], case[4], case[5], case[6], case[7]), case[1], 'aller-retour ' .. case[1])
  end
  T.eq(Util.formatFileStamp(951782400 + 14 * 3600 + 32 * 60 + 5), '2000-02-29_14h32m05s')
  T.eq(Util.formatDate(0), '01/01/1970 00:00 UTC')
  T.eq(Util.civilFromEpoch(0 / 0).year, 1970)
end

tests['U13 noms de fichiers et identifiants sûrs'] = function()
  T.eq(Util.sanitizeFileName('SetupLab Quali/../x:y'), 'SetupLab_Quali___x_y', '« .. » réduit à « _ »')
  T.eq(Util.sanitizeFileName('..\\..\\win.ini'), '____win.ini')
  T.eq(Util.sanitizeFileName('.cache'), '_cache')
  T.eq(#Util.sanitizeFileName(string.rep('a', 200)), 64)
  T.eq(Util.sanitizeFileName(nil), '')
  T.ok(Util.isSafeId('ks_red_bull_ring'))
  T.ok(Util.isSafeId('lamborghini_huracan_gt3_evo2'))
  T.no(Util.isSafeId('../cars'))
  T.no(Util.isSafeId('a/b'))
  T.no(Util.isSafeId('a\\b'))
  T.no(Util.isSafeId(''))
  T.no(Util.isSafeId(nil))
  T.no(Util.isSafeId('a..b'))
  T.eq(Util.truncate('abcdef', 3), 'abc')
  T.eq(Util.truncate(nil, 3), '')
  T.eq(Util.trim('  x y \t'), 'x y')
  T.eq(Util.fmt(0 / 0), '—')
  T.eq(Util.fmt(1.234, 1), '1.2')
end

tests['U14 accès protégés aux objets externes'] = function()
  local s = Fake.strict({ a = 1 }, 'struct')
  T.eq(Util.get(s, 'a'), 1)
  T.eq(Util.get(s, 'absent'), nil, 'champ inconnu : nil au lieu d\'une erreur')
  T.eq(Util.get(nil, 'a'), nil)
  T.eq(Util.get(5, 'a'), nil)
  local ok, err = Util.call(nil)
  T.no(ok)
  T.eq(err, 'absent')
  ok, err = Util.call(42)
  T.no(ok)
  T.ok(type(err) == 'string')
  ok, err = Util.call(function() error(string.rep('e', 1000)) end)
  T.no(ok)
  T.ok(#err <= 200, 'message borné')
  local okv, a, b = Util.call(function(x) return x, x * 2 end, 3)
  T.ok(okv)
  T.eq(a, 3)
  T.eq(b, 6)
  local arr = Fake.array({ 1.5, 2.5 })
  T.eq(Util.get(arr, 1), 2.5)
  T.eq(Util.get(arr, 5), nil)
end

return tests
