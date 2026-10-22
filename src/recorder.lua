-- SetupLab — enregistreur de tours (§9.1). Lecture seule de l'état CSP, à 30 Hz au plus.
--
-- Découpage : le passage de lapCount (compteur d'AC) termine le tour en cours. Le temps officiel
-- previousLapTimeMs n'est retenu que s'il recoupe l'une de trois références : le chrono du tour d'AC
-- (lapTimeMs) relevé la frame d'avant, son maximum pendant le tour (si AC remet le chrono à zéro une
-- frame avant d'incrémenter le compteur), ou la durée en temps de simulation (hors pause). S'il n'est
-- pas encore à jour, il est attendu jusqu'à K.recorderTimeWait. Le premier tour vu en partie (app
-- ouverte en cours de tour, tour de sortie des stands, départ arrêté) n'est jamais enregistré. Un tour
-- est rejeté, avec sa raison, si AC
-- l'invalide, si la voiture passe par la voie des stands ou sort de la piste, si la couverture de la
-- piste a un trou ou recule (retour au stand, téléportation), si la mémoire est pleine, si le setup
-- est illisible ou change pendant le tour, ou si la répartition de freinage change en roulant.
-- L'origine de la ligne IA peut s'écarter de la ligne de chronométrage : les écarts de couverture se
-- mesurent en tenant compte du bouclage de la progression.
--
-- DRS (§8.9, hypothèse H8) : si context.drsWing est donné (index de l'aile mobile, celui d'aero.ini et
-- de getCarPhysics().wings), l'état du volet est relevé à chaque échantillon (tour avec DRS ouvert,
-- part du tour) ; à chaque ouverture, les coefficients cl et cd de l'aile juste avant et juste après
-- sont comparés : c'est la mesure de l'effet réel du volet.
--
-- Rugosité (H17) : en ligne droite (accélérations faibles, vitesse suffisante, sans freiner), la charge de
-- chaque roue est relevée par fenêtres de K.roughWindow échantillons ; la variance autour de la droite de
-- tendance de chaque fenêtre (l'appui croît avec la vitesse) mesure la variation de charge due à la piste.
--
-- ERS (§8.9, hypothèse H24) : si context.ers, le déploiement instantané (kersInput, 0–1) est relevé à
-- chaque échantillon, ainsi que la charge de la batterie (kersCharge) au début et à la fin du tour et
-- l'énergie déployée dans le tour (maximum de kersCurrentKJ) : de quoi simuler le tour mesuré avec son
-- déploiement réel (calibration) et vérifier le bilan d'énergie du modèle.
--
-- Pluie (D16 amendé le 21/10/2026, décision de Vincent) : l'eau sous chaque pneu (waterThickness, m) est
-- relevée à chaque échantillon, moyenne du tour dans lap.waterMm ; l'état de la piste (« sec » ou
-- « pluie », context.conditions.bucket, relevé à la ligne) range le tour : le meilleur tour est gardé par
-- setup ET par état (un tour sec ne sert jamais à calibrer ni à valider un setup pluie, et inversement).
--
-- Mémoire : un seul tampon de tour, réutilisé ; un tour terminé est copié une fois, sans les positions
-- (sauf sans ligne IA). Seuls le dernier tour et le meilleur tour valide de chaque setup et état
-- (K.recorderMaxSignatures au plus) sont conservés ; les setups de rec.protected (setup de la
-- découverte, setup proposé) ne sont jamais évincés.

local Util = require('src/util')
local Config = require('src/config')
local K = Config.K

local M = {}

local get, call = Util.get, Util.call
local floor, max, min, abs = math.floor, math.max, math.min, math.abs

-- Canaux par échantillon (tampon réutilisé) ; ceux conservés dans un tour terminé ; positions.
M.CHANNELS = { 'p', 'v', 'ax', 'ay', 'gas', 'brake', 'gear', 'rpm', 'fuel', 'ers', 'x', 'y', 'z' }
M.KEPT = { 'p', 'v', 'ax', 'ay', 'gas', 'brake', 'gear', 'rpm', 'fuel', 'ers' }
M.POSITIONS = { 'x', 'y', 'z' }

local function num(object, key)
  local v = get(object, key)
  if type(v) == 'cdata' then v = tonumber(v) end
  if Util.isFinite(v) then return v end
  return nil
end

local function bool(object, key)
  local v = get(object, key)
  if type(v) == 'boolean' then return v end
  if type(v) == 'number' or type(v) == 'cdata' then return tonumber(v) ~= 0 end
  return nil
end

-- Distance (en progression) d'une position à la ligne, bouclage compris.
local function toLine(p)
  return min(p, 1 - p)
end

function M.new(capacity)
  local rec = {
    capacity = capacity or K.recorderCapacity, n = 0, buf = {}, state = 'attente',
    lastLapCount = nil, nextSampleAt = nil, lastP = nil, maxGap = 0, invalid = nil, pending = nil,
    signatureStart = nil, sums = nil, laps = { last = nil, best = {}, order = {}, family = {}, familyOrder = {} }, finished = 0,
    protected = {},
    lapTimeRef = nil, lapTimePeak = nil, peakArmed = false, startTime = nil, drsPairs = {}, drsPrev = nil,
    window = { n = 0, v = {}, load = { {}, {}, {}, {} } },
  }
  for _, name in ipairs(M.CHANNELS) do rec.buf[name] = {} end
  return rec
end

-- Abandonne le tour en cours (le prochain passage de ligne en démarrera un nouveau).
function M.abort(rec, reason)
  rec.n, rec.maxGap, rec.lastP, rec.invalid = 0, 0, nil, nil
  rec.state = 'attente'
  rec.abortReason = reason
  rec.drsPrev = nil
end

local function startLap(rec, signature, lapCount, now, family)
  rec.n, rec.maxGap, rec.lastP, rec.invalid = 0, 0, nil, nil
  rec.state = 'enregistrement'
  rec.signatureStart, rec.familyStart = signature, family
  rec.lapIndex = lapCount
  rec.startTime = now
  -- maximum du chrono d'AC : suivi à partir de la frame suivante (la valeur de la frame du passage peut
  -- encore être celle du tour précédent)
  rec.lapTimePeak, rec.peakArmed = nil, false
  rec.window.n = 0
  rec.sums = { tyreTemp = { 0, 0, 0, 0 }, pressure = { 0, 0, 0, 0 }, km = { 0, 0, 0, 0 }, count = 0, kmCount = 0,
    tyreIn = { 0, 0, 0, 0 }, tyreOut = { 0, 0, 0, 0 }, sideCount = 0, water = 0, waterCount = 0,
    loadSS = { 0, 0, 0, 0 }, loadDof = 0, roughV = 0, roughN = 0, roughWindows = 0,
    ersSamples = 0, ersKjMax = nil, ersChargeFirst = nil, ersChargeLast = nil,
    kmFirst = {}, kmLast = {}, biasMin = math.huge, biasMax = -math.huge, boostMax = 0, fuelMissing = 0, drsOpen = 0 }
end

-- Copie du tour terminé (tableaux exacts, sans la réserve du tampon) ; positions seulement si
-- keepPositions (pas de ligne IA).
-- table.new (LuaJIT, fourni par CSP) : tableaux pré-alloués, la copie du passage de ligne reste légère
-- (pas d'agrandissements successifs) ; sinon tableau ordinaire.
local tableNew = rawget(table, 'new')

local function copyChannels(rec, lap, names)
  for _, name in ipairs(names) do
    local src = rec.buf[name]
    local dst = tableNew and tableNew(rec.n, 0) or {}
    for i = 1, rec.n do dst[i] = src[i] end
    lap[name] = dst
  end
end

local function copyLap(rec, keepPositions)
  local lap = { n = rec.n }
  copyChannels(rec, lap, M.KEPT)
  if keepPositions then copyChannels(rec, lap, M.POSITIONS) end
  return lap
end

-- Clé du meilleur tour : la signature du setup sur piste sèche (inchangée), suivie de « #pluie » sur
-- piste mouillée.
function M.bestKey(signature, bucket)
  if bucket == 'pluie' then return tostring(signature) .. '#pluie' end
  return signature
end

local function keep(rec, lap)
  local laps = rec.laps
  laps.last = lap
  if not lap.valid then return end
  local key = M.bestKey(lap.signature, lap.bucket)
  local best = laps.best[key]
  if best == nil then
    laps.order[#laps.order + 1] = key
    if #laps.order > K.recorderMaxSignatures then
      for i, old in ipairs(laps.order) do
        if not rec.protected[tostring(old):match('^(.-)#pluie$') or old] then
          table.remove(laps.order, i)
          laps.best[old] = nil
          break
        end
      end
    end
  end
  if best == nil or lap.time < best.time then laps.best[key] = lap end
  -- vos temps par « famille » de setup (sans les réglages changés en roulant : carburant, répartition de
  -- freinage) : meilleur tour, nombre de tours valides et somme des temps (moyenne de course)
  if lap.family == nil then return end
  local fkey = M.bestKey(lap.family, lap.bucket)
  local f = laps.family[fkey]
  if f == nil then
    f = { best = lap.time, count = 0, sum = 0 }
    laps.family[fkey] = f
    laps.familyOrder[#laps.familyOrder + 1] = fkey
    if #laps.familyOrder > K.recorderMaxSignatures then laps.family[table.remove(laps.familyOrder, 1)] = nil end
  end
  f.count, f.sum = f.count + 1, f.sum + lap.time
  if lap.time < f.best then f.best = lap.time end
end

-- Tour terminé, avant le temps officiel : copie, validité (hors temps), conditions moyennes.
local function buildLap(rec, signatureEnd, context)
  local s = rec.sums
  local lap = copyLap(rec, context.keepPositions)
  lap.signature, lap.family = rec.signatureStart, rec.familyStart
  lap.lapCount = rec.lapIndex
  local reason = rec.invalid
  if reason == nil and (rec.signatureStart == nil or signatureEnd == nil) then reason = 'setup illisible' end
  if reason == nil and signatureEnd ~= rec.signatureStart then reason = 'setup modifié pendant le tour' end
  if reason == nil and s.biasMax - s.biasMin > K.recorderBiasTolerance then
    reason = 'répartition de freinage modifiée en roulant'
  end
  if reason == nil and rec.n < K.recorderMinSamples then reason = 'trop peu d\'échantillons' end
  if reason == nil and lap.v[1] < K.recorderMinStartSpeed then reason = 'départ arrêté' end
  -- couverture : écarts entre échantillons, et entre la ligne et le premier / dernier échantillon
  local gap = max(rec.maxGap, rec.lastP and toLine(rec.lastP) or 1, rec.n > 0 and toLine(lap.p[1]) or 1)
  if reason == nil and gap * (context.trackLength or 0) > K.recorderMaxGapM then
    reason = 'trou de couverture de ' .. Util.fmt(gap * (context.trackLength or 0), 0) .. ' m (retour au stand ?)'
  end
  lap.reason = reason
  local count = max(1, s.count)
  lap.tyreTemp, lap.pressure, lap.tyreKm = {}, {}, {}
  -- températures intérieure et extérieure : seulement si elles ont été lues à chaque échantillon
  if s.sideCount == s.count and s.count > 0 then lap.tyreTempIn, lap.tyreTempOut = {}, {} end
  for w = 1, 4 do
    lap.tyreTemp[w], lap.pressure[w] = s.tyreTemp[w] / count, s.pressure[w] / count
    if lap.tyreTempIn then lap.tyreTempIn[w], lap.tyreTempOut[w] = s.tyreIn[w] / count, s.tyreOut[w] / count end
    -- km virtuels : seulement s'ils ont été lus à chaque échantillon
    lap.tyreKm[w] = s.kmCount == s.count and s.count > 0 and s.km[w] / count or nil
  end
  -- km virtuels parcourus pendant le tour (usure du relais, §8.7) ; une baisse signale un changement
  -- de pneus pendant le tour : pas de mesure
  lap.tyreKmDelta = {}
  for w = 1, 4 do
    local delta = s.kmCount == s.count and s.kmFirst[w] and s.kmLast[w] and s.kmLast[w] - s.kmFirst[w] or nil
    lap.tyreKmDelta[w] = delta and delta >= 0 and delta or nil
  end
  lap.boostMax = s.boostMax
  -- variation de charge en ligne droite (rugosité) : écart type par roue, vitesse moyenne
  if s.roughWindows >= K.roughMinWindows and s.loadDof > 0 then
    lap.loadSigma = {}
    for w = 1, 4 do lap.loadSigma[w] = math.sqrt(s.loadSS[w] / s.loadDof) end
    lap.roughSpeed, lap.roughWindows = s.roughV / s.roughN, s.roughWindows
  end
  lap.drsUsed, lap.drsShare = s.drsOpen > 0, s.count > 0 and s.drsOpen / s.count or 0
  lap.ersUsed = s.ersSamples > 0
  lap.ersDeployedKj, lap.ersChargeStart, lap.ersChargeEnd = s.ersKjMax, s.ersChargeFirst, s.ersChargeLast
  -- carburant : seulement s'il a été lu à chaque échantillon
  if s.fuelMissing == 0 and rec.n > 0 then lap.fuelStart, lap.fuelEnd = lap.fuel[1], lap.fuel[lap.n] end
  lap.mass, lap.cgHeight = context.mass, context.cgHeight
  lap.conditions = context.conditions
  lap.bucket = context.conditions and context.conditions.bucket == 'pluie' and 'pluie' or 'sec'
  -- eau sous les pneus (mm), seulement si elle a été lue à chaque échantillon
  lap.waterMm = s.waterCount == s.count and s.count > 0 and s.water / s.count * 1000 or nil
  return lap
end

-- Conclut un tour en attente de son temps officiel.
local function finalize(rec, timeSec, timeReason)
  local lap = rec.pending.lap
  rec.pending = nil
  lap.time = timeSec
  lap.reason = lap.reason or timeReason
  lap.valid = lap.reason == nil
  rec.finished = rec.finished + 1
  keep(rec, lap)
  return lap
end

-- Temps officiel : retenu s'il recoupe l'une des références relevées au passage de la ligne.
local function resolvePending(rec, car, now)
  local p = rec.pending
  local ms = num(car, 'previousLapTimeMs')
  local official = ms and ms > 0 and ms / 1000 or nil
  if official then
    for _, reference in ipairs(p.references) do
      if abs(official - reference) <= K.recorderTimeTolerance then return finalize(rec, official, nil) end
    end
  end
  if now >= p.deadline then
    local list = {}
    for _, reference in ipairs(p.references) do list[#list + 1] = Util.fmt(reference, 3) end
    return finalize(rec, official, 'temps officiel incohérent (' .. Util.fmt(official, 3) .. ' s contre '
      .. table.concat(list, ' / ') .. ' s chronométrés)')
  end
  return nil
end

-- Fenêtre de ligne droite pleine : variance de la charge de chaque roue autour de sa droite de tendance.
local function closeWindow(rec)
  local win, s = rec.window, rec.sums
  local n = win.n
  local mx = (n + 1) / 2
  local sxx = 0
  for j = 1, n do sxx = sxx + (j - mx) ^ 2 end
  for w = 1, 4 do
    local y = win.load[w]
    local my = 0
    for j = 1, n do my = my + y[j] end
    my = my / n
    local sxy = 0
    for j = 1, n do sxy = sxy + (j - mx) * (y[j] - my) end
    local b = sxy / sxx
    local ss = 0
    for j = 1, n do ss = ss + (y[j] - my - b * (j - mx)) ^ 2 end
    s.loadSS[w] = s.loadSS[w] + ss
  end
  for j = 1, n do s.roughV = s.roughV + win.v[j] end
  s.loadDof, s.roughN, s.roughWindows = s.loadDof + n - 2, s.roughN + n, s.roughWindows + 1
  win.n = 0
end

-- Bascule du volet DRS (fermé puis ouvert) : rapports des coefficients de l'aile ouvert / fermé, si les
-- deux échantillons sont à vitesse voisine.
local function drsSample(rec, open, cd, cl, v)
  local prev = rec.drsPrev
  if prev and not prev.open and open and cd and cl and prev.cd and prev.cl and abs(prev.cl) > 1e-6
    and abs(prev.cd) > 1e-6 and abs(v - prev.v) <= K.drsProbeMaxDv and #rec.drsPairs < K.drsProbeMax then
    rec.drsPairs[#rec.drsPairs + 1] = { cl = cl / prev.cl, cd = cd / prev.cd, v = v }
  end
  rec.drsPrev = { open = open, cd = cd, cl = cl, v = v }
end

-- À appeler à chaque frame (lecture seule). now : temps de simulation (s). signatureFn : signature
-- des crans de setup (nil si illisible), appelée seulement au passage de la ligne. context :
-- { trackLength, conditions (températures, grip), keepPositions, paused }. Renvoie le tour terminé
-- (temps officiel confirmé), s'il y en a un.
function M.update(rec, host, now, signatureFn, context)
  local ok, car = call(get(host.ac, 'getCar'), 0)
  if not ok or car == nil then return nil end
  local lapCount = num(car, 'lapCount')
  if lapCount == nil then return nil end
  local lapTimeMs = num(car, 'lapTimeMs')
  if lapTimeMs and rec.peakArmed then rec.lapTimePeak = max(rec.lapTimePeak or 0, lapTimeMs) end
  local finished = nil
  if rec.lastLapCount ~= nil and lapCount ~= rec.lastLapCount then
    local previous = rec.lastLapCount
    rec.lastLapCount = lapCount
    local signature, family = nil, nil
    if signatureFn then signature, family = signatureFn() end
    if rec.state == 'enregistrement' and lapCount == previous + 1 then
      if rec.pending then finished = finalize(rec, nil, 'temps officiel non confirmé') end
      context.mass, context.cgHeight = num(car, 'mass'), num(car, 'cgHeight')
      local lap = buildLap(rec, signature, context)
      -- références : chrono d'AC la frame d'avant et son maximum pendant le tour (pauses exclues),
      -- durée en temps de simulation (pauses comprises)
      local references = {}
      if rec.lapTimeRef then references[#references + 1] = rec.lapTimeRef / 1000 end
      if rec.lapTimePeak then references[#references + 1] = rec.lapTimePeak / 1000 end
      if rec.startTime then references[#references + 1] = now - rec.startTime end
      rec.pending = { lap = lap, references = references, deadline = now + K.recorderTimeWait }
    end
    startLap(rec, signature, lapCount, now, family)
  elseif rec.lastLapCount == nil then
    rec.lastLapCount = lapCount
  end
  rec.lapTimeRef = lapTimeMs
  rec.peakArmed = rec.state == 'enregistrement'
  if rec.pending then finished = resolvePending(rec, car, now) or finished end
  if rec.state ~= 'enregistrement' then return finished end
  -- invalidation (la première raison est conservée)
  if rec.invalid == nil then
    if bool(car, 'isLapValid') == false then
      rec.invalid = 'tour invalidé par AC'
    elseif bool(car, 'isInPitlane') == true then
      rec.invalid = 'passage par la voie des stands'
    elseif (num(car, 'wheelsOutside') or 0) > K.maxWheelsOutside then
      rec.invalid = 'sortie de piste'
    end
  end
  if context.paused then return finished end
  -- échéancier cumulé : à 60 images/s, un échantillon toutes les deux images exactement (une simple
  -- comparaison à 1/30 s en sauterait une de temps en temps, par arrondi)
  if rec.nextSampleAt and now < rec.nextSampleAt - 1e-4 then return finished end
  rec.nextSampleAt = (rec.nextSampleAt or now) + 1 / K.recorderHz
  if rec.nextSampleAt < now then rec.nextSampleAt = now end
  if rec.n >= rec.capacity then
    rec.invalid = rec.invalid or 'mémoire pleine'
    return finished
  end
  local p = num(car, 'splinePosition')
  local v = num(car, 'speedMs')
  if p == nil or v == nil then return finished end
  if rec.lastP then
    local d = p - rec.lastP
    if d < -0.5 then d = d + 1 elseif d > 0.5 then d = d - 1 end
    if d < 0 then
      local back = -d * (context.trackLength or 0)
      if back > K.recorderMaxGapM then rec.invalid = rec.invalid or ('recul de ' .. Util.fmt(back, 0) .. ' m (téléportation ?)') end
      d = 0
    end
    rec.maxGap = max(rec.maxGap, d)
  end
  rec.lastP = p
  local i = rec.n + 1
  rec.n = i
  local b = rec.buf
  local acc, pos = get(car, 'acceleration'), get(car, 'position')
  b.p[i], b.v[i] = p, v
  b.ax[i], b.ay[i] = (num(acc, 'z') or 0) * 9.80665, (num(acc, 'x') or 0) * 9.80665
  b.gas[i], b.brake[i], b.gear[i], b.rpm[i] = num(car, 'gas') or 0, num(car, 'brake') or 0, num(car, 'gear') or 0,
    num(car, 'rpm') or 0
  local s = rec.sums
  b.ers[i] = 0
  if context.ers then
    local input, kj, charge = num(car, 'kersInput'), num(car, 'kersCurrentKJ'), num(car, 'kersCharge')
    if input then
      b.ers[i] = Util.clamp(input, 0, 1)
      if input > 0 then s.ersSamples = s.ersSamples + 1 end
    end
    if kj then s.ersKjMax = max(s.ersKjMax or 0, kj) end
    if charge then
      s.ersChargeFirst = s.ersChargeFirst or charge
      s.ersChargeLast = charge
    end
  end
  local fuel = num(car, 'fuel')
  if fuel == nil then s.fuelMissing = s.fuelMissing + 1 end
  b.fuel[i] = fuel or 0
  b.x[i], b.y[i], b.z[i] = num(pos, 'x') or 0, num(pos, 'y') or 0, num(pos, 'z') or 0
  local bias = num(car, 'brakeBias') or 0
  local boost = num(car, 'turboBoost') or 0
  s.biasMin, s.biasMax = min(s.biasMin, bias), max(s.biasMax, bias)
  s.boostMax = max(s.boostMax, boost)
  local wheels = get(car, 'wheels')
  local win = rec.window
  local straight = abs(b.ay[i]) < K.roughMaxAy and abs(b.ax[i]) < K.roughMaxAx and v > K.roughMinSpeed and b.brake[i] < 0.05
  -- rapport constant dans la fenêtre : un passage de rapport la recommence
  if straight and win.n > 0 and b.gear[i] ~= win.gear then win.n = 0 end
  local kmOk, sideOk, water, waterOk = true, true, 0, true
  for w = 1, 4 do
    local wheel = get(wheels, w - 1)
    s.tyreTemp[w] = s.tyreTemp[w] + (num(wheel, 'tyreCoreTemperature') or 0)
    local thickness = num(wheel, 'waterThickness')
    if thickness and thickness >= 0 then water = water + thickness / 4 else waterOk = false end
    local load = num(wheel, 'load')
    if straight and load then win.load[w][win.n + 1] = load else straight = false end
    local inside, outside = num(wheel, 'tyreInsideTemperature'), num(wheel, 'tyreOutsideTemperature')
    if inside and outside then
      s.tyreIn[w], s.tyreOut[w] = s.tyreIn[w] + inside, s.tyreOut[w] + outside
    else
      sideOk = false
    end
    s.pressure[w] = s.pressure[w] + (num(wheel, 'tyrePressure') or 0)
    local km = num(wheel, 'tyreVirtualKM')
    if km == nil then
      kmOk = false
    else
      s.km[w] = s.km[w] + km
      if s.kmFirst[w] == nil then s.kmFirst[w] = km end
      s.kmLast[w] = km
    end
  end
  if kmOk then s.kmCount = s.kmCount + 1 end
  if sideOk then s.sideCount = s.sideCount + 1 end
  if waterOk then s.water, s.waterCount = s.water + water, s.waterCount + 1 end
  if straight then
    win.n = win.n + 1
    win.v[win.n] = v
    if win.n == 1 then win.gear = b.gear[i] end
    if win.n >= K.roughWindow then closeWindow(rec) end
  else
    win.n = 0
  end
  s.count = s.count + 1
  if context.drsWing then
    local open = bool(car, 'drsActive')
    if open ~= nil then
      if open then s.drsOpen = s.drsOpen + 1 end
      local okp, physics = call(get(host.ac, 'getCarPhysics'), 0)
      local wing = okp and get(get(physics, 'wings'), context.drsWing) or nil
      drsSample(rec, open, num(wing, 'cd'), num(wing, 'cl'), v)
    end
  end
  return finished
end

local function median(list)
  if #list == 0 then return nil end
  table.sort(list)
  local m = (#list + 1) / 2
  return (list[floor(m)] + list[math.ceil(m)]) / 2
end

-- Mesure de l'effet du volet DRS : nombre de bascules, médianes des rapports cl et cd ouvert / fermé.
function M.drsSummary(rec)
  local cl, cd = {}, {}
  for i, pair in ipairs(rec.drsPairs) do cl[i], cd[i] = pair.cl, pair.cd end
  return { n = #rec.drsPairs, cl = median(cl), cd = median(cd) }
end

-- Meilleur tour valide pour une signature de setup sur un état de piste (« sec » par défaut), ou nil.
function M.best(rec, signature, bucket)
  return rec.laps.best[M.bestKey(signature, bucket)]
end

-- Progression d'un tour reconstituée par la distance parcourue depuis la ligne, normalisée (sans
-- ligne IA, splinePosition n'est pas exploitable). Renvoie un tableau, ou nil sans positions.
function M.progressFromPositions(lap)
  if lap.x == nil or lap.n < 2 then return nil end
  local p, total = { 0 }, 0
  for i = 2, lap.n do
    local dx, dy, dz = lap.x[i] - lap.x[i - 1], lap.y[i] - lap.y[i - 1], lap.z[i] - lap.z[i - 1]
    total = total + math.sqrt(dx * dx + dy * dy + dz * dz)
    p[i] = total
  end
  if total <= 0 then return nil end
  for i = 1, lap.n do p[i] = p[i] / total end
  return p
end

-- Vrai si la progression d'AC d'un tour est inexploitable (constante ou presque).
function M.progressUnusable(lap)
  local lo, hi = math.huge, -math.huge
  for i = 1, lap.n do lo, hi = min(lo, lap.p[i]), max(hi, lap.p[i]) end
  return hi - lo < 0.5
end

-- Ré-échantillonne un tour sur un pas d'abscisse ds (m) : s via la progression IA (sAtProgress),
-- interpolation linéaire. Renvoie { s, v, gas, brake, gear, rpm } triés par s.
function M.resample(lap, sAt, length, ds)
  local order = Util.progressOrder(lap.p, lap.n)
  local S = {}
  for k, i in ipairs(order) do S[k] = sAt(lap.p[i]) end
  local out = { s = {}, v = {}, gas = {}, brake = {}, gear = {}, rpm = {} }
  local j = 1
  local count = floor(length / ds)
  for k = 0, count - 1 do
    local s = k * ds
    while j < #order and S[j + 1] < s do j = j + 1 end
    local a, b = order[j], order[min(j + 1, #order)]
    local sa, sb = S[j], S[min(j + 1, #order)]
    local f = sb > sa and Util.clamp((s - sa) / (sb - sa), 0, 1) or 0
    out.s[k + 1] = s
    for _, name in ipairs({ 'v', 'gas', 'brake', 'rpm' }) do
      out[name][k + 1] = lap[name][a] + (lap[name][b] - lap[name][a]) * f
    end
    out.gear[k + 1] = f < 0.5 and lap.gear[a] or lap.gear[b]
  end
  return out
end

-- Texte compact d'un tour (§9.1), à coller dans la conversation de développement : en-tête (temps
-- officiel, masse, carburant, pneus, turbo, setup, conditions, calibration) puis un point tous les
-- K.exportLapStepM m.
function M.exportText(lap, info, sAt, length)
  local lines = {}
  local function out(text) lines[#lines + 1] = text end
  local wheels = { 'AVG', 'AVD', 'ARG', 'ARD' }
  out('SetupLab ' .. tostring(info.appVersion) .. ' — tour enregistré')
  out('Voiture : ' .. tostring(info.carId) .. ' ; circuit : ' .. tostring(info.trackId) .. ' ; longueur ' .. Util.fmt(length, 1)
    .. ' m')
  out('Temps officiel : ' .. Util.fmt(lap.time, 3) .. ' s ; valide : ' .. tostring(lap.valid)
    .. (lap.reason and (' (' .. lap.reason .. ')') or '') .. ' ; échantillons ' .. lap.n)
  out('Masse CSP : ' .. Util.fmt(lap.mass, 1) .. ' kg ; CG : ' .. Util.fmt(lap.cgHeight, 3) .. ' m ; carburant '
    .. Util.fmt(lap.fuelStart, 2) .. ' -> ' .. Util.fmt(lap.fuelEnd, 2) .. ' L ; turbo max ' .. Util.fmt(lap.boostMax, 3))
  local tyres = {}
  for w = 1, 4 do
    tyres[#tyres + 1] = wheels[w] .. ' ' .. Util.fmt(lap.tyreTemp[w], 1) .. ' °C ' .. Util.fmt(lap.pressure[w], 2) .. ' psi '
      .. Util.fmt(lap.tyreKm[w], 2) .. ' km'
  end
  out('Pneus (moyenne du tour, cœur) : ' .. table.concat(tyres, ' ; '))
  if lap.ersUsed or lap.ersDeployedKj then
    out('ERS : déploiement relevé sur ' .. Util.fmt(lap.ersUsed and 1 or 0, 0) .. ' tour ; énergie déployée '
      .. Util.fmt(lap.ersDeployedKj, 0) .. ' kJ ; charge ' .. Util.fmt(lap.ersChargeStart, 3) .. ' -> '
      .. Util.fmt(lap.ersChargeEnd, 3))
  end
  if info.drs then
    local m = info.drs.measure or {}
    out('DRS : ouvert ' .. Util.fmt((lap.drsShare or 0) * 100, 1) .. ' % du tour ; bascules mesurées ' .. tostring(m.n or 0)
      .. ' ; cl ouvert/fermé ' .. Util.fmt(m.cl, 3) .. ' ; cd ouvert/fermé ' .. Util.fmt(m.cd, 3) .. ' (H8 : '
      .. Util.fmt(info.drs.expected, 3) .. ')')
  end
  local c = lap.conditions or {}
  out('Conditions : air ' .. Util.fmt(c.airTemp, 1) .. ' °C ; piste ' .. Util.fmt(c.roadTemp, 1) .. ' °C ; grip '
    .. Util.fmt(c.roadGrip, 3))
  out('Setup : ' .. tostring(info.setupText or lap.signature))
  if info.modelTime then out('Modèle (setup de la découverte, facteurs à 1) : ' .. Util.fmt(info.modelTime, 3) .. ' s') end
  local cal = info.calibration
  if cal then
    local parts = {}
    for _, key in ipairs({ 'mu', 'power', 'drag', 'lift', 'brake' }) do
      parts[#parts + 1] = key .. '=' .. Util.fmt(cal.factors[key], 3) .. (cal.atBound[key] and ' (butée)' or '')
        .. (cal.identified[key] and '' or ' (non identifié)')
    end
    out('Calibration : ' .. table.concat(parts, ' ; ') .. ' ; utilisable ' .. tostring(cal.usable)
      .. (cal.reason and (' (' .. cal.reason .. ')') or ''))
    for _, one in ipairs(cal.runs) do
      out('  ' .. tostring(one.label) .. ' : mesuré ' .. Util.fmt(one.measuredTime, 3) .. ' s ; calibré ' .. Util.fmt(one.simTime, 3)
        .. ' s (' .. Util.fmt(one.timeError * 100, 2) .. ' %, RMS ' .. Util.fmt(one.rms * 100, 2) .. ' %) ; idéal '
        .. Util.fmt(one.idealTime, 3) .. ' s')
    end
  end
  out('s_m;v_kmh;gaz;frein;rapport;regime')
  local r = M.resample(lap, sAt, length, K.exportLapStepM)
  for k = 1, #r.s do
    out(string.format('%.0f;%.1f;%.2f;%.2f;%d;%.0f', r.s[k], r.v[k] * 3.6, r.gas[k], r.brake[k], r.gear[k], r.rpm[k]))
  end
  return table.concat(lines, '\n') .. '\n'
end

-- Ligne IA reconstituée depuis un tour (reconnaissance, §7.1 source 2 ; arbitrage A14) : positions
-- triées par progression, sans largeur (inconnue). Format de Datasource.sampleTrack. Si la
-- progression d'AC est inexploitable, elle est remplacée par la distance parcourue depuis la ligne.
function M.reconnaissance(lap, lengthSim)
  if lap.x == nil then return { ok = false, source = 'reconnaissance', reason = 'positions non conservées' } end
  local progress = lap.p
  if M.progressUnusable(lap) then
    progress = M.progressFromPositions(lap)
    if progress == nil then return { ok = false, source = 'reconnaissance', reason = 'tour immobile' } end
  end
  local order = Util.progressOrder(progress, lap.n)
  local raw = { ok = true, source = 'reconnaissance', n = 0, x = {}, y = {}, z = {}, p = {}, left = {}, right = {},
    failures = 0, sideFailures = 0, lengthSim = lengthSim }
  local lastP = -1
  for _, i in ipairs(order) do
    if progress[i] - lastP > 1e-6 then
      local k = raw.n + 1
      raw.n = k
      raw.x[k], raw.y[k], raw.z[k], raw.p[k], raw.left[k], raw.right[k] = lap.x[i], lap.y[i], lap.z[i], progress[i], -1, -1
      lastP = progress[i]
    end
  end
  if raw.n < K.trackMinSamples then
    raw.ok = false
    raw.reason = 'tour trop court pour la reconnaissance'
  end
  return raw
end

return M
