-- SetupLab — utilitaires purs : maths, interpolation, LUT, analyse de texte,
-- RNG déterministe, filtres, journal circulaire, ordonnanceur coopératif, dates.
-- Aucun accès à l'API CSP (D5) : tout ce module est testable hors jeu.

local M = {}

local floor, min, max, huge = math.floor, math.min, math.max, math.huge

M.EPS = 1e-9

-- Limites de format des données externes (D11). Ce ne sont pas des valeurs du PDR : elles
-- bornent le coût et la mémoire des analyses de texte, quelle que soit la taille des fichiers.
M.LIMITS = {
  lineChars = 4096,   -- une ligne plus longue est tronquée avant analyse
  numberChars = 64,   -- texte d'un nombre
  idChars = 128,      -- identifiant de contenu AC
  fileNameChars = 64, -- nom de fichier produit
  rtoLabelChars = 32, -- libellé d'un rapport de boîte
}

-- ---------------------------------------------------------------------------
-- Nombres
-- ---------------------------------------------------------------------------

function M.isFinite(x)
  return type(x) == 'number' and x == x and x > -huge and x < huge
end

function M.finiteOr(x, fallback)
  if M.isFinite(x) then return x end
  return fallback
end

function M.clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

function M.lerp(a, b, t)
  return a + (b - a) * t
end

-- Division protégée (§16.3) : le dénominateur est éloigné de zéro en gardant son signe.
function M.safeDiv(a, b, eps)
  eps = eps or M.EPS
  if b >= 0 and b < eps then
    b = eps
  elseif b < 0 and b > -eps then
    b = -eps
  end
  return a / b
end

function M.round(x, step)
  step = step or 1
  return floor(x / step + 0.5) * step
end

-- Filtre exponentiel du premier ordre ; alpha borné dans [0 ; 1].
function M.ema(previous, value, alpha)
  if not M.isFinite(previous) then return value end
  alpha = M.clamp(alpha, 0, 1)
  return previous + (value - previous) * alpha
end

-- ---------------------------------------------------------------------------
-- Accès protégés aux objets externes (D7) : lire un champ absent d'une structure FFI
-- lève une erreur, appeler une valeur non appelable aussi.
-- ---------------------------------------------------------------------------

local function index(object, key)
  return object[key]
end

function M.get(object, key)
  if object == nil then return nil end
  local ok, value = pcall(index, object, key)
  if ok then return value end
  return nil
end

-- Renvoie (true, r1, r2) ou (false, message borné).
function M.call(fn, ...)
  if fn == nil then return false, 'absent' end
  local ok, a, b = pcall(fn, ...)
  if not ok then return false, M.truncate(tostring(a), 200) end
  return true, a, b
end

-- ---------------------------------------------------------------------------
-- Chaînes
-- ---------------------------------------------------------------------------

-- Supprime les blancs en tête et en fin, en temps linéaire (aucun motif à retour arrière :
-- une ligne de milliers d'espaces ne doit pas geler le jeu, D6).
function M.trim(s)
  local first = s:find('%S')
  if first == nil then return '' end
  local last = s:find('%S%s*$', first)
  return s:sub(first, last)
end

-- Découpe en deux autour de la première occurrence (texte brut) du séparateur.
local function splitOnce(s, separator)
  local at = s:find(separator, 1, true)
  if at == nil then return nil, nil end
  return s:sub(1, at - 1), s:sub(at + #separator)
end

-- Retire un commentaire de fin de ligne introduit par marker (texte brut).
local function stripComment(s, marker)
  local at = s:find(marker, 1, true)
  if at then return s:sub(1, at - 1) end
  return s
end

-- Ligne bornée avant toute analyse.
local function boundedLine(raw)
  if #raw > M.LIMITS.lineChars then return raw:sub(1, M.LIMITS.lineChars), true end
  return raw, false
end

-- Tronque une chaîne à n octets (les données externes sont bornées, D11).
function M.truncate(s, n)
  if type(s) ~= 'string' then return '' end
  if #s <= n then return s end
  return s:sub(1, n)
end

-- Nom de fichier sûr : lettres, chiffres, « _ », « - », « . » ; pas de « .. ».
function M.sanitizeFileName(s, maxLength)
  if type(s) ~= 'string' then return '' end
  local r = s:gsub('[^%w_%-%.]', '_')
  r = r:gsub('%.%.+', '_')
  r = r:gsub('^%.', '_')
  return M.truncate(r, maxLength or M.LIMITS.fileNameChars)
end

-- Nom de fichier tiré d'un nom saisi (décision de Vincent du 21/10/2026 : nommer le setup) : accents
-- retirés, extension .ini retirée, espaces et autres caractères remplacés par « _ » (sans doublon, ni en tête
-- ni en fin) ; au plus maxLength caractères ; '' si rien ne reste.
local ACCENTS = {}
for from, to in pairs({ ['à'] = 'a', ['â'] = 'a', ['ä'] = 'a', ['ç'] = 'c', ['è'] = 'e', ['é'] = 'e', ['ê'] = 'e', ['ë'] = 'e',
    ['î'] = 'i', ['ï'] = 'i', ['ô'] = 'o', ['ö'] = 'o', ['ù'] = 'u', ['û'] = 'u', ['ü'] = 'u', ['ÿ'] = 'y',
    ['À'] = 'A', ['Â'] = 'A', ['Ä'] = 'A', ['Ç'] = 'C', ['È'] = 'E', ['É'] = 'E', ['Ê'] = 'E', ['Ë'] = 'E',
    ['Î'] = 'I', ['Ï'] = 'I', ['Ô'] = 'O', ['Ö'] = 'O', ['Ù'] = 'U', ['Û'] = 'U', ['Ü'] = 'U' }) do
  ACCENTS[from] = to
end
function M.fileNameFrom(s, maxLength)
  if type(s) ~= 'string' then return '' end
  local r = s:gsub('[\195][\128-\191]', function(c) return ACCENTS[c] or '_' end)
  r = r:gsub('%s*%.[iI][nN][iI]%s*$', '')
  r = M.sanitizeFileName(r, 1000)
  r = r:gsub('_+', '_'):gsub('^[_%.%-]+', ''):gsub('[_%.%-]+$', '')
  r = M.truncate(r, maxLength or M.LIMITS.fileNameChars)
  return (r:gsub('[_%.%-]+$', ''))
end

-- Identifiant de contenu AC (dossier voiture/circuit) : refuse tout séparateur de chemin.
function M.isSafeId(s)
  return type(s) == 'string' and #s > 0 and #s <= M.LIMITS.idChars and s:find('^[%w_%-%.]+$') ~= nil
    and s:find('..', 1, true) == nil
end

-- Formatage tolérant des nombres pour l'interface et le rapport.
function M.fmt(x, decimals)
  if not M.isFinite(x) then return '—' end
  return string.format('%.' .. (decimals or 2) .. 'f', x)
end

-- ---------------------------------------------------------------------------
-- Analyse de valeurs textuelles (fichiers AC)
-- ---------------------------------------------------------------------------

-- Nombre fini depuis une valeur INI ; tout commentaire « ; » final est ignoré.
function M.parseNumber(s)
  if type(s) == 'number' then
    if M.isFinite(s) then return s end
    return nil
  end
  if type(s) ~= 'string' or #s > M.LIMITS.lineChars then return nil end
  s = M.trim(stripComment(s, ';'))
  if #s > M.LIMITS.numberChars then return nil end
  local n = tonumber(s)
  if M.isFinite(n) then return n end
  return nil
end

-- Liste de nombres « a, b, c » ; nil si un élément n'est pas un nombre fini.
function M.parseNumberList(s, maxItems)
  if type(s) ~= 'string' then return nil end
  local out = {}
  s = stripComment(M.truncate(s, M.LIMITS.lineChars), ';')
  for item in (s .. ','):gmatch('([^,]*),') do
    if #out >= (maxItems or 16) then return nil end
    local n = M.parseNumber(item)
    if n == nil then return nil end
    out[#out + 1] = n
  end
  if #out == 0 then return nil end
  return out
end

M.INI_LIMITS = { maxBytes = 524288, maxSections = 1024, maxKeys = 256, maxValueChars = 1024 }

-- Analyse un texte INI au format AC : sections [NOM], lignes CLE=VALEUR, commentaires « ; »
-- et lignes de séparation « // ». Les dépassements de bornes sont tronqués et signalés.
-- tick (facultatif) est appelé toutes les 64 lignes pour les tâches découpées.
function M.parseIni(text, limits, tick)
  local out = { sections = {}, order = {}, keyCount = {}, truncated = false }
  if type(text) ~= 'string' then return out end
  limits = limits or M.INI_LIMITS
  if #text > limits.maxBytes then
    text = text:sub(1, limits.maxBytes)
    out.truncated = true
  end
  if text:sub(1, 3) == '\239\187\191' then text = text:sub(4) end
  local current, currentName = nil, nil
  local lines = 0
  for raw in text:gmatch('[^\r\n]+') do
    lines = lines + 1
    if tick and lines % 64 == 0 then tick() end
    local bounded, cut = boundedLine(raw)
    if cut then out.truncated = true end
    local line = M.trim(bounded)
    local first = line:sub(1, 1)
    if line ~= '' and first ~= ';' and first ~= '/' then
      local close = first == '[' and line:find(']', 2, true) or nil
      local name = close and close > 2 and line:sub(2, close - 1) or nil
      if name then
        name = M.trim(name)
        current, currentName = out.sections[name], name
        if current == nil then
          if #out.order >= limits.maxSections then
            out.truncated = true
            current, currentName = nil, nil
          else
            current = {}
            out.sections[name] = current
            out.order[#out.order + 1] = name
            out.keyCount[name] = 0
          end
        end
      elseif current then
        local key, value = splitOnce(line, '=')
        if key then
          key = M.trim(key)
          value = M.trim(stripComment(value, ';'))
          if #value > limits.maxValueChars then
            value = value:sub(1, limits.maxValueChars)
            out.truncated = true
          end
          if current[key] == nil then
            if out.keyCount[currentName] >= limits.maxKeys then
              out.truncated = true
              key = nil
            else
              out.keyCount[currentName] = out.keyCount[currentName] + 1
            end
          end
          if key and key ~= '' then current[key] = value end
        end
      end
    end
  end
  return out
end

-- Valeur d'une table INI normalisée { sections = {...} } ; nil si absente.
function M.iniGet(ini, section, key)
  if type(ini) ~= 'table' or type(ini.sections) ~= 'table' then return nil end
  local s = ini.sections[section]
  if type(s) ~= 'table' then return nil end
  return s[key]
end

function M.iniNumber(ini, section, key, fallback)
  local n = M.parseNumber(M.iniGet(ini, section, key))
  if n == nil then return fallback end
  return n
end

-- ---------------------------------------------------------------------------
-- Tables de correspondance (LUT)
-- ---------------------------------------------------------------------------

-- Construit une LUT triée depuis des listes x/y : points non finis ignorés, abscisses
-- dupliquées fusionnées (premier point conservé). Renvoie nil si aucun point valide.
function M.lutNew(xs, ys, maxPoints)
  local pts = {}
  local n = min(#xs, #ys, maxPoints or 4096)
  for i = 1, n do
    local x, y = xs[i], ys[i]
    if M.isFinite(x) and M.isFinite(y) then pts[#pts + 1] = { x, y, i } end
  end
  if #pts == 0 then return nil end
  table.sort(pts, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[3] < b[3]
  end)
  local lut = { x = {}, y = {}, n = 0 }
  for i = 1, #pts do
    local p = pts[i]
    if lut.n == 0 or p[1] > lut.x[lut.n] then
      lut.n = lut.n + 1
      lut.x[lut.n] = p[1]
      lut.y[lut.n] = p[2]
    end
  end
  return lut
end

-- Interpolation linéaire, bornée aux extrémités (comportement des LUT d'AC).
function M.lutEval(lut, x)
  local n = lut.n
  local xs, ys = lut.x, lut.y
  if n == 1 or x <= xs[1] then return ys[1] end
  if x >= xs[n] then return ys[n] end
  local lo, hi = 1, n
  while hi - lo > 1 do
    local mid = floor((lo + hi) / 2)
    if xs[mid] <= x then lo = mid else hi = mid end
  end
  local t = (x - xs[lo]) / (xs[hi] - xs[lo])
  return ys[lo] + (ys[hi] - ys[lo]) * t
end

function M.lutRange(lut)
  local ymin, ymax = huge, -huge
  for i = 1, lut.n do
    ymin = min(ymin, lut.y[i])
    ymax = max(ymax, lut.y[i])
  end
  return lut.x[1], lut.x[lut.n], ymin, ymax
end

-- Analyse une LUT texte : fichier « x|y » par ligne, ou forme en ligne « (|x=y|x=y|) ».
-- tick (facultatif) est appelé toutes les 64 lignes.
function M.parseLutText(text, maxPoints, tick)
  if type(text) ~= 'string' then return nil end
  maxPoints = maxPoints or 4096
  local xs, ys = {}, {}
  local inline = text:match('^%s*%((.*)%)%s*$')
  if inline then
    for pair in (M.truncate(inline, M.LIMITS.lineChars * 4) .. '|'):gmatch('([^|]*)|') do
      if #xs >= maxPoints then break end
      local a, b = splitOnce(pair, '=')
      if a then
        xs[#xs + 1] = M.parseNumber(a) or (0 / 0)
        ys[#ys + 1] = M.parseNumber(b) or (0 / 0)
      end
    end
  else
    local lines = 0
    for line in text:gmatch('[^\r\n]+') do
      if #xs >= maxPoints then break end
      lines = lines + 1
      if tick and lines % 64 == 0 then tick() end
      local clean = stripComment(stripComment((boundedLine(line)), ';'), '//')
      local a, rest = splitOnce(clean, '|')
      local b = rest and splitOnce(rest .. '|', '|') or nil
      if a then
        xs[#xs + 1] = M.parseNumber(a) or (0 / 0)
        ys[#ys + 1] = M.parseNumber(b) or (0 / 0)
      end
    end
  end
  return M.lutNew(xs, ys, maxPoints)
end

-- Fichier de rapports de boîte .rto : lignes « libellé|rapport ». tick : toutes les 64 lignes.
function M.parseRto(text, maxEntries, tick)
  local out = {}
  if type(text) ~= 'string' then return out end
  local lines = 0
  for line in text:gmatch('[^\r\n]+') do
    if #out >= (maxEntries or 256) then break end
    lines = lines + 1
    if tick and lines % 64 == 0 then tick() end
    local label, rest = splitOnce((boundedLine(line)), '|')
    local value = rest and splitOnce(stripComment(rest, ';') .. '|', '|') or nil
    local ratio = M.parseNumber(value)
    label = label and M.trim(label) or ''
    if label ~= '' and ratio and ratio > 0 and ratio < 100 then
      out[#out + 1] = { label = M.truncate(label, M.LIMITS.rtoLabelChars), ratio = ratio }
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Générateur pseudo-aléatoire déterministe (Park–Miller, exact en double précision)
-- ---------------------------------------------------------------------------

local RNG_M, RNG_A = 2147483647, 16807

function M.rngNew(seed)
  local s = floor(M.finiteOr(seed, 1)) % RNG_M
  if s <= 0 then s = s + RNG_M - 1 end
  return { state = s }
end

-- Valeur uniforme dans [0 ; 1[.
function M.rngNext(r)
  r.state = (r.state * RNG_A) % RNG_M
  return (r.state - 1) / (RNG_M - 1)
end

function M.rngRange(r, a, b)
  return a + (b - a) * M.rngNext(r)
end

-- Ordre des indices 1..n par valeur croissante de keys. Pour des échantillons presque triés (un tour
-- enregistré : progression croissante, sauf quelques points autour de la ligne), le tri par
-- insertion coûte O(n) ; au-delà de 8·n déplacements, repli sur table.sort.
function M.progressOrder(keys, n)
  local order = {}
  for i = 1, n do order[i] = i end
  local moves, limit = 0, 8 * n + 64
  for i = 2, n do
    local item = order[i]
    local key = keys[item]
    local j = i - 1
    while j >= 1 and keys[order[j]] > key do
      order[j + 1] = order[j]
      j = j - 1
      moves = moves + 1
    end
    order[j + 1] = item
    if moves > limit then
      for k = 1, n do order[k] = k end
      table.sort(order, function(a, b) return keys[a] < keys[b] end)
      return order
    end
  end
  return order
end

-- Empreinte stable d'une chaîne (graine reproductible par contexte).
function M.hashString(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % RNG_M end
  if h == 0 then h = 1 end
  return h
end

-- ---------------------------------------------------------------------------
-- Journal circulaire borné, débit limité par code (§16.4, §17)
-- ---------------------------------------------------------------------------

M.LEVELS = { ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4 }

function M.logNew(capacity, minInterval, maxChars)
  return {
    lines = {}, head = 0, count = 0, seq = 0, dropped = 0,
    capacity = capacity, minInterval = minInterval, maxChars = maxChars or 400,
    lastByCode = {}, codes = 0, maxLevel = M.LEVELS.INFO,
  }
end

function M.logAdd(log, now, level, code, message)
  local rank = M.LEVELS[level] or M.LEVELS.INFO
  if rank > log.maxLevel then return false end
  local last = log.lastByCode[code]
  if last and now - last < log.minInterval then
    log.dropped = log.dropped + 1
    return false
  end
  if last == nil then
    log.codes = log.codes + 1
    if log.codes > 512 then
      log.lastByCode, log.codes = {}, 1
    end
  end
  log.lastByCode[code] = now
  log.head = log.head % log.capacity + 1
  log.lines[log.head] = { t = now, level = level, code = code, text = M.truncate(tostring(message), log.maxChars) }
  log.count = min(log.count + 1, log.capacity)
  log.seq = log.seq + 1
  return true
end

-- Entrées du plus ancien au plus récent.
function M.logEntries(log)
  local out = {}
  local start = log.head - log.count
  for i = 1, log.count do
    local index = (start + i - 1) % log.capacity + 1
    out[i] = log.lines[index]
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Ordonnanceur coopératif (D6, §5.3)
-- Chaque tâche est une coroutine ; ses boucles appellent ctx.tick(), qui rend la main
-- lorsque la tranche de temps est épuisée. Le rendu est prédictif : la durée d'une unité
-- de travail (maximum observé entre deux tick, avec décroissance unitDecay) est estimée,
-- et la main est rendue avant d'entamer une unité qui dépasserait l'échéance.
-- Sans horloge précise, un quota fixe d'unités de travail sert de repli.
-- L'annulation abandonne la coroutine.
-- ---------------------------------------------------------------------------

function M.schedulerNew(unitDecay)
  local s = {
    queue = {}, current = nil, clock = nil, deadline = 0, quotaLeft = 0,
    lastTick = 0, unit = 0, unitDecay = unitDecay or 0.9,
    stats = { slices = 0, completed = 0, failed = 0, cancelled = 0, lastSliceMs = 0, maxSliceMs = 0, maxUnitMs = 0 },
  }
  -- weight (facultatif) : coût relatif de l'unité qui vient de finir, utilisé par le repli
  -- sans horloge (un appel CSP pèse plus lourd qu'un calcul élémentaire).
  local function tick(weight)
    local clock = s.clock
    if clock then
      local now = clock()
      local unit = now - s.lastTick
      s.lastTick = now
      s.unit = max(unit, s.unit * s.unitDecay)
      if unit * 1000 > s.stats.maxUnitMs then s.stats.maxUnitMs = unit * 1000 end
      if now + s.unit >= s.deadline then coroutine.yield() end
    else
      s.quotaLeft = s.quotaLeft - (weight or 1)
      if s.quotaLeft <= 0 then coroutine.yield() end
    end
  end
  -- Horloge en secondes pendant une tranche (nil hors tranche ou sans horloge).
  local function now()
    if s.clock then return s.clock() end
    return nil
  end
  s.ctx = { tick = tick, now = now }
  return s
end

-- Contexte synchrone (tests et usages hors ordonnanceur) : tick() ne rend jamais la main.
function M.syncContext()
  return { tick = function() end, now = function() return nil end }
end

function M.schedulerAdd(s, name, fn, onDone)
  s.queue[#s.queue + 1] = { name = name, fn = fn, onDone = onDone }
end

function M.schedulerBusy(s)
  return s.current ~= nil or #s.queue > 0
end

local function finish(s, task, ok, value)
  s.current = nil
  if ok then
    s.stats.completed = s.stats.completed + 1
  elseif value == 'cancelled' then
    s.stats.cancelled = s.stats.cancelled + 1
  else
    s.stats.failed = s.stats.failed + 1
  end
  if task.onDone then pcall(task.onDone, ok, value, task.cpuMs) end
end

-- Exécute une tranche. clock : fonction en secondes ou nil ; budget en secondes ;
-- quota : unités de travail si l'horloge manque. Renvoie true si une tâche a tourné.
-- onDone(ok, résultat, cpuMs) reçoit le temps de calcul cumulé de la tâche (0 sans horloge).
function M.schedulerStep(s, clock, budget, quota)
  if s.current == nil and #s.queue == 0 then return false end
  s.clock = clock
  local started = clock and clock() or nil
  s.deadline = started and (started + budget) or 0
  s.quotaLeft = quota
  local ran = false
  while true do
    local task = s.current
    if task == nil then
      task = table.remove(s.queue, 1)
      if task == nil then break end
      s.current = task
      task.cpuMs = 0
      s.unit = 0
      task.co = coroutine.create(function() return task.fn(s.ctx) end)
    end
    ran = true
    local resumedAt = clock and clock() or nil
    s.lastTick = resumedAt or 0
    local ok, result = coroutine.resume(task.co)
    if resumedAt then task.cpuMs = task.cpuMs + (clock() - resumedAt) * 1000 end
    if not ok then
      task.error = tostring(result)
      finish(s, task, false, task.error)
    elseif coroutine.status(task.co) == 'dead' then
      finish(s, task, true, result)
    else
      break
    end
    if clock then
      if clock() + s.unit >= s.deadline then break end
    elseif s.quotaLeft <= 0 then
      break
    end
  end
  s.clock = nil
  s.stats.slices = s.stats.slices + 1
  if started then
    local ms = (clock() - started) * 1000
    s.stats.lastSliceMs = ms
    if ms > s.stats.maxSliceMs then s.stats.maxSliceMs = ms end
  end
  return ran
end

-- Annule la tâche courante et les tâches en attente (toutes si name est nil).
function M.schedulerCancel(s, name)
  local kept = {}
  for _, task in ipairs(s.queue) do
    if name == nil or task.name == name then
      s.stats.cancelled = s.stats.cancelled + 1
      if task.onDone then pcall(task.onDone, false, 'cancelled') end
    else
      kept[#kept + 1] = task
    end
  end
  s.queue = kept
  local current = s.current
  if current and (name == nil or current.name == name) then
    finish(s, current, false, 'cancelled')
  end
end

-- ---------------------------------------------------------------------------
-- Dates (sans os.*, §16.2) : horodatage Unix UTC -> date civile (algorithme de Hinnant)
-- ---------------------------------------------------------------------------

function M.civilFromEpoch(t)
  t = floor(M.finiteOr(t, 0))
  local days = floor(t / 86400)
  local secs = t - days * 86400
  local z = days + 719468
  local era = floor(z / 146097)
  local doe = z - era * 146097
  local yoe = floor((doe - floor(doe / 1460) + floor(doe / 36524) - floor(doe / 146096)) / 365)
  local doy = doe - (365 * yoe + floor(yoe / 4) - floor(yoe / 100))
  local mp = floor((5 * doy + 2) / 153)
  local day = doy - floor((153 * mp + 2) / 5) + 1
  local month = mp < 10 and mp + 3 or mp - 9
  local year = yoe + era * 400
  if month <= 2 then year = year + 1 end
  return {
    year = year, month = month, day = day,
    hour = floor(secs / 3600), min = floor((secs % 3600) / 60), sec = secs % 60,
  }
end

-- Inverse de civilFromEpoch (algorithme de Hinnant) : date civile -> horodatage (s).
function M.epochFromCivil(year, month, day, hour, min, sec)
  local y = month <= 2 and year - 1 or year
  local era = floor(y / 400)
  local yoe = y - era * 400
  local mp = month > 2 and month - 3 or month + 9
  local doy = floor((153 * mp + 2) / 5) + day - 1
  local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
  return (era * 146097 + doe - 719468) * 86400 + (hour or 0) * 3600 + (min or 0) * 60 + (sec or 0)
end

-- « AAAAMMJJ-HHMMSS » en temps universel.
function M.formatStamp(t)
  local d = M.civilFromEpoch(t)
  return string.format('%04d%02d%02d-%02d%02d%02d', d.year, d.month, d.day, d.hour, d.min, d.sec)
end

-- « AAAA-MM-JJ_HHhMMmSSs » : horodatage des noms de fichiers, lisible dans la liste des setups d'AC
-- (t déjà corrigé du fuseau par l'appelant).
function M.formatFileStamp(t)
  local d = M.civilFromEpoch(t)
  return string.format('%04d-%02d-%02d_%02dh%02dm%02ds', d.year, d.month, d.day, d.hour, d.min, d.sec)
end

-- « JJ/MM/AAAA HH:MM UTC » pour l'affichage.
function M.formatDate(t)
  local d = M.civilFromEpoch(t)
  return string.format('%02d/%02d/%04d %02d:%02d UTC', d.day, d.month, d.year, d.hour, d.min)
end

return M
