-- SetupLab — modèle du circuit (§7) : abscisse curviligne à pas constant, courbure, pente, dévers,
-- largeur, grip de surface, segments, bosses, zones DRS, confiance. Noyau pur (D5) : consomme la
-- ligne échantillonnée par datasource et renvoie des tableaux.
--
-- Sortie (§7.4) : { ds, n, s[], p[] (progression de la ligne IA), x[], y[], z[], kappa[], theta[],
-- kappaV[], phi[], width[], surf[], segments[], bumps[], drsZones[], length, closed, confidence,
-- source, warnings[] }.
--
-- Conventions (§6) : plan horizontal (x, z), y vers le haut. Pour une tangente t, la normale
-- n = (−t.z, t.x) ; une courbure κ > 0 signifie que la trajectoire tourne vers n. Le dévers
-- phi > 0 signifie que le côté n est plus bas : le dévers « vers l'intérieur » du virage vaut
-- donc phi · signe(κ). Ces conventions ne dépendent pas de l'orientation gauche/droite d'AC.

local Util = require('src/util')
local Config = require('src/config')
local K = Config.K

local M = {}

local sqrt, abs, floor, max, min, atan = math.sqrt, math.abs, math.floor, math.max, math.min, math.atan

local TICK_POINTS = 256

-- Abscisses cumulées de la polyligne brute (3D) et longueur de la corde de fermeture.
local function cumulative(raw, tick)
  local S = { 0 }
  for i = 2, raw.n do
    if i % TICK_POINTS == 0 then tick() end
    local dx, dy, dz = raw.x[i] - raw.x[i - 1], raw.y[i] - raw.y[i - 1], raw.z[i] - raw.z[i - 1]
    S[i] = S[i - 1] + sqrt(dx * dx + dy * dy + dz * dz)
  end
  local dx, dy, dz = raw.x[1] - raw.x[raw.n], raw.y[1] - raw.y[raw.n], raw.z[1] - raw.z[raw.n]
  return S, sqrt(dx * dx + dy * dy + dz * dz)
end

-- Ré-échantillonne x, y, z, progression, largeur et dévers à pas constant.
local function resample(raw, S, total, closed, ds, tick)
  local N = max(K.trackMinSamples, floor(total / ds + 0.5))
  if not closed then N = N + 1 end
  local step = closed and total / N or total / (N - 1)
  local t = {
    n = N, ds = step, s = {}, p = {}, x = {}, y = {}, z = {}, width = {}, bankN = {},
    widthMissing = 0, hasBank = raw.bankN ~= nil,
  }
  local hasP = raw.p ~= nil
  local j = 1
  for k = 1, N do
    if k % TICK_POINTS == 0 then tick() end
    local s = (k - 1) * step
    while j < raw.n and S[j + 1] <= s do j = j + 1 end
    local a, b, sa, sb = j, j + 1, S[j], S[j + 1]
    if b > raw.n then
      b, sb = 1, total
    end
    local f = 0
    if sb > sa then f = Util.clamp((s - sa) / (sb - sa), 0, 1) end
    t.s[k] = s
    t.x[k] = raw.x[a] + (raw.x[b] - raw.x[a]) * f
    t.y[k] = raw.y[a] + (raw.y[b] - raw.y[a]) * f
    t.z[k] = raw.z[a] + (raw.z[b] - raw.z[a]) * f
    if hasP then
      local pb = b == 1 and 1 or raw.p[b]
      t.p[k] = raw.p[a] + (pb - raw.p[a]) * f
    else
      t.p[k] = s / total
    end
    local la, lb, ra, rb = raw.left[a], raw.left[b], raw.right[a], raw.right[b]
    if la and lb and ra and rb and la >= 0 and lb >= 0 and ra >= 0 and rb >= 0 then
      t.width[k] = (la + ra) + ((lb + rb) - (la + ra)) * f
    else
      t.width[k] = K.trackDefaultWidth
      t.widthMissing = t.widthMissing + 1
    end
    if t.hasBank then
      t.bankN[k] = raw.bankN[a] + (raw.bankN[b] - raw.bankN[a]) * f
    else
      t.bankN[k] = 0
    end
  end
  return t
end

-- Indice voisin avec bouclage (circuit fermé) ou bornage (tracé ouvert).
local function neighbour(k, offset, N, closed)
  local i = k + offset
  if closed then return (i - 1) % N + 1 end
  return Util.clamp(i, 1, N)
end

-- Lissage gaussien d'un tableau (noyau tronqué à 3 σ, poids renormalisés aux bords d'un tracé ouvert).
local function gaussian(values, N, sigmaPts, closed, tick)
  local out = {}
  if sigmaPts < 0.5 then
    for k = 1, N do out[k] = values[k] end
    return out
  end
  local half = floor(3 * sigmaPts + 0.5)
  local weights = {}
  for o = -half, half do weights[o + half + 1] = math.exp(-0.5 * (o / sigmaPts) ^ 2) end
  for k = 1, N do
    if k % TICK_POINTS == 0 then tick() end
    local acc, wsum = 0, 0
    for o = -half, half do
      local i = k + o
      local w = weights[o + half + 1]
      if closed then
        i = (i - 1) % N + 1
        acc = acc + values[i] * w
        wsum = wsum + w
      elseif i >= 1 and i <= N then
        acc = acc + values[i] * w
        wsum = wsum + w
      end
    end
    out[k] = acc / wsum
  end
  return out
end

-- Courbure signée (plan horizontal) par le cercle passant par trois points espacés de m pas
-- (courbure de Menger) : base large, donc peu sensible au bruit des positions.
local function curvature(t, closed, tick)
  local N, m = t.n, max(1, floor(K.curvatureBaseM / t.ds + 0.5))
  local kappa = {}
  for k = 1, N do
    if k % TICK_POINTS == 0 then tick() end
    local a, c = neighbour(k, -m, N, closed), neighbour(k, m, N, closed)
    local ax, az, bx, bz, cx, cz = t.x[a], t.z[a], t.x[k], t.z[k], t.x[c], t.z[c]
    local abx, abz, bcx, bcz, acx, acz = bx - ax, bz - az, cx - bx, cz - bz, cx - ax, cz - az
    local cross = abx * bcz - abz * bcx
    local denom = sqrt((abx * abx + abz * abz) * (bcx * bcx + bcz * bcz) * (acx * acx + acz * acz))
    kappa[k] = denom > 1e-9 and 2 * cross / denom or 0
  end
  return kappa
end

-- Pente longitudinale (rad) sur une base de ±m pas (base réduite aux bords d'un tracé ouvert,
-- distance horizontale mesurée sur les points effectivement utilisés).
local function slope(t, closed, tick)
  local N, m = t.n, max(1, floor(K.slopeBaseM / t.ds + 0.5))
  local theta = {}
  for k = 1, N do
    if k % TICK_POINTS == 0 then tick() end
    local a, c = neighbour(k, -m, N, closed), neighbour(k, m, N, closed)
    local dx, dz = t.x[c] - t.x[a], t.z[c] - t.z[a]
    local h = sqrt(dx * dx + dz * dz)
    theta[k] = h > 1e-6 and atan((t.y[c] - t.y[a]) / h) or 0
  end
  return theta
end

-- Courbure verticale d²y/ds² (crêtes < 0, compressions > 0), sur une base symétrique : près des
-- extrémités d'un tracé ouvert, la base est réduite (et nulle au premier et au dernier point).
local function verticalCurvature(t, closed, tick)
  local N, m = t.n, max(1, floor(K.slopeBaseM / t.ds + 0.5))
  local out = {}
  for k = 1, N do
    if k % TICK_POINTS == 0 then tick() end
    local mk = closed and m or min(m, k - 1, N - k)
    if mk < 1 then
      out[k] = 0
    else
      local h = mk * t.ds
      out[k] = (t.y[neighbour(k, mk, N, closed)] - 2 * t.y[k] + t.y[neighbour(k, -mk, N, closed)]) / (h * h)
    end
  end
  return out
end

-- Regroupe une suite d'états en tronçons { state, j0, j1 } (indices dans l'ordre de parcours).
local function runs(state, N)
  local list, j0 = {}, 1
  for j = 2, N + 1 do
    if j > N or state[j] ~= state[j0] then
      list[#list + 1] = { state = state[j0], j0 = j0, j1 = j - 1 }
      j0 = j
    end
  end
  return list
end

local function runLength(run)
  return run.j1 - run.j0 + 1
end

-- Fusionne les tronçons adjacents de même état.
local function mergeEqual(list)
  local out = {}
  for _, run in ipairs(list) do
    local last = out[#out]
    if last and last.state == run.state then
      last.j1 = run.j1
    else
      out[#out + 1] = run
    end
  end
  return out
end

-- Point de départ de la segmentation d'un circuit fermé : milieu de la plus longue suite de points
-- en ligne droite (|κ| < cornerKappaOut). Le résultat ne dépend ainsi pas de la position de la ligne
-- d'arrivée : l'hystérésis démarre en ligne droite et aucun virage n'est coupé en deux.
local function segmentationStart(t, tick)
  local N, bestStart, bestLen = t.n, 1, 0
  local first = nil
  for k = 1, N do
    if abs(t.kappa[k]) >= K.cornerKappaOut then
      first = k
      break
    end
  end
  if first == nil then return 1 end
  local runStart, runLen = nil, 0
  for step = 1, N do
    if step % TICK_POINTS == 0 then tick() end
    local k = (first + step - 1) % N + 1
    if abs(t.kappa[k]) < K.cornerKappaOut then
      if runStart == nil then runStart = k end
      runLen = runLen + 1
      if runLen > bestLen then bestStart, bestLen = runStart, runLen end
    else
      runStart, runLen = nil, 0
    end
  end
  if bestLen == 0 then return 1 end
  return (bestStart + floor(bestLen / 2) - 1) % N + 1
end

-- Segmentation (§7.3). État signé par point : 0 ligne droite, +1 / −1 virage selon le sens, avec
-- hystérésis sur |κ|. Les fragments de virage trop courts (bruit) redeviennent ligne droite ; une
-- ligne droite courte entre deux virages de même sens est absorbée (double apex). Chicane : deux
-- virages serrés de sens opposés, adjacents ou séparés d'une ligne droite courte.
function M.segment(t, closed, tick)
  tick = tick or function() end
  local N = t.n
  local start = closed and segmentationStart(t, tick) or 1
  local order, state, current = {}, {}, 0
  for j = 1, N do
    if j % TICK_POINTS == 0 then tick() end
    local k = (start + j - 2) % N + 1
    order[j] = k
    local kap = t.kappa[k]
    local a, dir = abs(kap), kap >= 0 and 1 or -1
    if current ~= 0 and a < K.cornerKappaOut then
      current = 0
    elseif a >= K.cornerKappaIn then
      current = dir
    end
    state[j] = current
  end
  local minCorner = max(1, floor(K.minCornerM / t.ds + 0.5))
  local minStraight = max(1, floor(K.minSegmentM / t.ds + 0.5))
  local list = runs(state, N)
  tick()
  for _, run in ipairs(list) do
    if run.state ~= 0 and runLength(run) < minCorner then run.state = 0 end
  end
  list = mergeEqual(list)
  for i = 2, #list - 1 do
    local prev, run, nextRun = list[i - 1], list[i], list[i + 1]
    if run.state == 0 and runLength(run) < minStraight and prev.state ~= 0 and prev.state == nextRun.state then
      run.state = prev.state
    end
  end
  list = mergeEqual(list)
  -- Circuit fermé : le premier et le dernier tronçon sont les deux moitiés de la même ligne droite.
  if closed and #list > 1 and list[1].state == list[#list].state then
    local last = table.remove(list)
    list[1].j0 = last.j0 - N
  end
  tick()
  local segments = {}
  local visited = 0
  for _, run in ipairs(list) do
    local apex, apexK = nil, -1
    local includesLast = false
    for j = run.j0, run.j1 do
      visited = visited + 1
      if visited % TICK_POINTS == 0 then tick() end
      local k = order[(j - 1) % N + 1]
      if k == N then includesLast = true end
      local a = abs(t.kappa[k])
      if a > apexK then apex, apexK = k, a end
    end
    local count = runLength(run)
    local i0 = order[(run.j0 - 1) % N + 1]
    -- Tracé ouvert : N points pour N − 1 intervalles ; le dernier point ne porte pas d'intervalle.
    local intervals = (not closed and includesLast) and count - 1 or count
    segments[#segments + 1] = {
      kind = run.state == 0 and 'straight' or 'corner',
      i0 = i0, i1 = order[(run.j1 - 1) % N + 1], count = count,
      s0 = t.s[i0], length = intervals * t.ds,
      apex = apex, radius = apexK > 0 and 1 / apexK or math.huge,
      dir = run.state ~= 0 and run.state or (t.kappa[apex] >= 0 and 1 or -1),
      chicane = false,
    }
  end
  local count = #segments
  local function tight(seg)
    return seg.kind == 'corner' and seg.radius <= K.chicaneMaxRadius
  end
  for i = 1, count do
    local seg = segments[i]
    local nextSeg = segments[i + 1]
    if closed and nextSeg == nil and count > 2 then nextSeg = segments[1] end
    if nextSeg and tight(seg) then
      local other, gap = nextSeg, 0
      if nextSeg.kind == 'straight' and nextSeg.length <= K.chicaneGapM then
        other = segments[i + 2] or (closed and segments[(i + 1) % count + 1]) or nil
        gap = nextSeg.length
      end
      if other and other ~= seg and tight(other) and other.dir ~= seg.dir
        and seg.length + gap + other.length <= K.chicaneMaxLength then
        seg.chicane, other.chicane = true, true
      end
    end
  end
  return segments
end

-- Bosses et compressions (§7.3) : tronçons où |κV| dépasse le seuil (crête : κV < 0).
local function bumps(t, tick)
  local list, current = {}, nil
  for k = 1, t.n do
    if k % TICK_POINTS == 0 then tick() end
    local kv = t.kappaV[k]
    local kind = kv <= -K.bumpKappaV and 'crête' or (kv >= K.bumpKappaV and 'compression' or nil)
    if kind and current and current.kind == kind and current.i1 == k - 1 then
      current.i1 = k
      if abs(kv) > abs(current.peak) then current.peak = kv end
    elseif kind then
      current = { kind = kind, i0 = k, i1 = k, peak = kv }
      list[#list + 1] = current
    end
  end
  for _, b in ipairs(list) do
    b.s0, b.length = t.s[b.i0], (b.i1 - b.i0 + 1) * t.ds
  end
  return list
end

-- Abscisse d'une progression p (0–1) de la ligne IA, par dichotomie sur t.p (croissant).
function M.sAtProgress(t, p)
  local P = t.p
  if p <= P[1] then return t.s[1] end
  if p >= P[t.n] then
    if not t.closed then return t.s[t.n] end
    local span = 1 - P[t.n]
    local f = span > 0 and (p - P[t.n]) / span or 0
    return t.s[t.n] + f * (t.length - t.s[t.n])
  end
  local lo, hi = 1, t.n
  while hi - lo > 1 do
    local mid = floor((lo + hi) / 2)
    if P[mid] <= p then lo = mid else hi = mid end
  end
  local span = P[hi] - P[lo]
  local f = span > 0 and (p - P[lo]) / span or 0
  return t.s[lo] + f * (t.s[hi] - t.s[lo])
end

-- Zones DRS en abscisse (drs_zones.ini : progressions 0–1 de la ligne IA, fin < début si la zone
-- boucle).
function M.drsZones(ini, t)
  local zones = {}
  if ini == nil then return zones end
  for _, section in ipairs(ini.order) do
    if section:find('^ZONE_') then
      local start = Util.iniNumber(ini, section, 'START', nil)
      local finish = Util.iniNumber(ini, section, 'END', nil)
      local detection = Util.iniNumber(ini, section, 'DETECTION', nil)
      if start and finish and start >= 0 and start <= 1 and finish >= 0 and finish <= 1 then
        local s0, s1 = M.sAtProgress(t, start), M.sAtProgress(t, finish)
        zones[#zones + 1] = {
          name = section, start = s0, finish = s1,
          detection = detection and detection >= 0 and detection <= 1 and M.sAtProgress(t, detection) or nil,
          length = (s1 - s0) % t.length,
        }
      end
    end
  end
  return zones
end

-- Grip de la chaussée (surfaces.ini) : surface valide de type route/asphalte la plus adhérente.
function M.surfaceGrip(ini)
  if ini == nil then return 1, 'défaut' end
  local best, bestAny = nil, nil
  for _, section in ipairs(ini.order) do
    local friction = Util.iniNumber(ini, section, 'FRICTION', nil)
    local valid = Util.iniNumber(ini, section, 'IS_VALID_TRACK', 1) == 1
    local key = (Util.iniGet(ini, section, 'KEY') or ''):upper()
    if friction and valid and friction > 0 and friction <= 2 then
      if key:find('ROAD') or key:find('ASPHALT') or key:find('TRACK') then
        if best == nil or friction > best then best = friction end
      end
      if bestAny == nil or friction > bestAny then bestAny = friction end
    end
  end
  if best then return best, 'surfaces.ini (route)' end
  if bestAny then return bestAny, 'surfaces.ini (surface valide)' end
  return 1, 'défaut'
end

-- Pas effectif : le pas demandé, augmenté sur les longs circuits pour tenir le budget (§8.8).
function M.effectiveStep(length, ds)
  return min(max(ds, length / K.trackAutoMaxPoints), max(ds, K.trackAutoMaxDs))
end

-- Construit le modèle du circuit. raw : sortie de Datasource.sampleTrack (et probeBank) ; files :
-- sortie de Datasource.readTrackFiles (facultatif) ; ds : pas souhaité (m).
function M.build(raw, files, ds, tick)
  tick = tick or function() end
  if raw == nil or not raw.ok or raw.n < K.trackMinSamples then
    return nil, 'géométrie indisponible : ' .. tostring(raw and raw.reason)
  end
  local warnings = {}
  local confidence = 1
  local S, chord = cumulative(raw, tick)
  local closed = raw.open ~= true
  -- Un circuit déclaré fermé dont la ligne ne se referme pas est traité comme un tracé ouvert
  -- (drapeau isTrackOpen illisible ou faux) : jamais de corde fictive de plusieurs centaines de mètres.
  if closed and chord > K.trackMaxClosureM then
    closed = false
    confidence = confidence - 0.2
    warnings[#warnings + 1] = 'ligne non refermée (' .. Util.fmt(chord, 0) .. ' m) : tracé traité comme ouvert'
  end
  local total = S[raw.n] + (closed and chord or 0)
  if total < K.trackMinLength or total > K.trackMaxLength then
    return nil, 'longueur hors plage : ' .. Util.fmt(total, 0) .. ' m'
  end
  local step = M.effectiveStep(total, ds)
  local t = resample(raw, S, total, closed, step, tick)
  t.closed, t.length, t.source, t.dsRequested = closed, total, raw.source or 'ligne IA', ds
  t.kappa = gaussian(curvature(t, closed, tick), t.n, K.curvatureSmoothM / t.ds, closed, tick)
  t.theta = gaussian(slope(t, closed, tick), t.n, K.slopeSmoothM / t.ds, closed, tick)
  t.kappaV = gaussian(verticalCurvature(t, closed, tick), t.n, K.slopeSmoothM / t.ds, closed, tick)
  t.phi = gaussian(t.bankN, t.n, K.bankSmoothM / t.ds, closed, tick)
  t.bankN = nil
  t.surfaceGrip, t.surfaceSource = M.surfaceGrip(files and files.ini and files.ini['surfaces.ini'])
  t.surf = {}
  for k = 1, t.n do
    if k % TICK_POINTS == 0 then tick() end
    t.kappa[k] = Util.clamp(t.kappa[k], -K.kappaMax, K.kappaMax)
    t.phi[k] = Util.clamp(t.phi[k], -K.bankMax, K.bankMax)
    t.surf[k] = t.surfaceGrip
  end
  t.segments = M.segment(t, closed, tick)
  t.bumps = bumps(t, tick)
  t.drsZones = M.drsZones(files and files.ini and files.ini['drs_zones.ini'], t)
  -- Cohérence et confiance (§7.4, arbitrage A3).
  if raw.lengthSim and raw.lengthSim > 0 then
    t.lengthError = (total - raw.lengthSim) / raw.lengthSim
    if abs(t.lengthError) > K.trackLengthTolSim then
      confidence = confidence - 0.3
      warnings[#warnings + 1] = 'longueur ' .. Util.fmt(t.lengthError * 100, 2) .. ' % de la ligne IA'
    end
  end
  if files and files.declared then
    t.declaredError = (total - files.declared) / files.declared
    if abs(t.declaredError) > K.trackLengthTolDeclared then
      confidence = confidence - 0.1
      warnings[#warnings + 1] = 'longueur ' .. Util.fmt(t.declaredError * 100, 2) .. ' % de la longueur déclarée'
    end
  end
  t.hasWidth = t.widthMissing <= t.n * K.trackMaxWidthMissing
  if not t.hasWidth then
    confidence = confidence - 0.15
    warnings[#warnings + 1] = 'largeurs inconnues sur ' .. t.widthMissing .. ' points'
  elseif t.widthMissing > 0 then
    warnings[#warnings + 1] = 'largeur prise par défaut sur ' .. t.widthMissing .. ' points'
  end
  if not t.hasBank then
    confidence = confidence - 0.1
    warnings[#warnings + 1] = 'dévers inconnu (pris nul)'
  end
  if (raw.failures or 0) > 0 then
    confidence = confidence - min(0.3, raw.failures / raw.n * 30)
    warnings[#warnings + 1] = raw.failures .. ' points de ligne IA invalides'
  end
  t.confidence = Util.clamp(confidence, 0, 1)
  t.warnings = warnings
  local corners, straights, minRadius = 0, 0, math.huge
  for _, seg in ipairs(t.segments) do
    if seg.kind == 'corner' then
      corners = corners + 1
      minRadius = min(minRadius, seg.radius)
    else
      straights = straights + 1
    end
  end
  t.cornerCount, t.straightCount, t.minRadius = corners, straights, minRadius
  return t, nil
end

-- Indice du point le plus proche d'une abscisse s (bouclage si fermé).
function M.indexAt(t, s)
  local k = floor(s / t.ds + 0.5) + 1
  if t.closed then return (k - 1) % t.n + 1 end
  return Util.clamp(k, 1, t.n)
end

-- Annote les segments avec la simulation (§7.3) : vitesse d'apex et classe.
function M.annotate(t, sim)
  for _, seg in ipairs(t.segments) do
    if seg.kind == 'corner' then
      local vmin, at = math.huge, seg.apex
      for i = seg.i0, seg.i0 + seg.count - 1 do
        local idx = (i - 1) % t.n + 1
        if sim.v[idx] < vmin then vmin, at = sim.v[idx], idx end
      end
      seg.vApex, seg.apexSim = vmin, at
      local kmh = vmin * 3.6
      seg.class = kmh < K.slowCornerKmh and 'lent' or (kmh > K.fastCornerKmh and 'rapide' or 'moyen')
    end
  end
  return t
end

-- Répartition du tour par classe (§10.1 : aileron selon la part de virages rapides et de lignes droites).
function M.mix(t)
  local m = { straight = 0, lent = 0, moyen = 0, rapide = 0 }
  for _, seg in ipairs(t.segments) do
    local key = seg.kind == 'straight' and 'straight' or (seg.class or 'moyen')
    m[key] = m[key] + seg.length
  end
  for key, value in pairs(m) do m[key] = value / t.length end
  return m
end

return M
