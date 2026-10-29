-- Tests du module src/track_model (J2, §7). Références indépendantes : rayon, vitesse et dévers
-- lus dans fast_lane.ai par l'outil de jeux de données (jamais par SetupLab). Alignement par la
-- progression de la ligne IA (t.p), comme en jeu.
local T = require('t')
local Util = require('src/util')
local Config = require('src/config')
local Datasource = require('src/datasource')
local TrackModel = require('src/track_model')
local Fake = require('fakehost')

local K = Config.K
local SYNC = Util.syncContext()
local tests = {}

local function rawOf(trackId, opts)
  local h = Fake.new({ car = require('fixtures/cars/formula_k'), track = require('fixtures/tracks/' .. trackId), missing = opts and opts.missing })
  local raw = Datasource.sampleTrack(h, 1, SYNC)
  Datasource.probeBank(h, raw, SYNC)
  return raw, h, Datasource.readTrackFiles(h, SYNC)
end

local cache = {}
local function build(trackId, ds)
  local key = trackId .. ':' .. tostring(ds)
  if cache[key] then return cache[key].t, cache[key].h, cache[key].raw end
  local raw, h, files = rawOf(trackId)
  local t, why = TrackModel.build(raw, files, ds or 2)
  assert(t, why)
  cache[key] = { t = t, h = h, raw = raw }
  return t, h, raw
end

-- Point de référence (fast_lane) correspondant au point k du modèle.
local function refIndexer(t, h)
  local pts = h.track.pts
  return function(k)
    local s = t.p[k] * h.track.total
    local lo, hi = 1, #pts
    while hi - lo > 1 do
      local mid = math.floor((lo + hi) / 2)
      if pts[mid][4] <= s then lo = mid else hi = mid end
    end
    return pts[lo]
  end
end

-- Rapport κ·R sur les points de référence en virage (R < 250 m).
local function curvatureRatios(t, h)
  local ref, ratios = refIndexer(t, h), {}
  local minOurs, minRef = math.huge, math.huge
  for k = 1, t.n do
    local r = ref(k)[8]
    if r > 1 and r < 250 then
      local ours = math.abs(t.kappa[k])
      ratios[#ratios + 1] = ours * r
      minOurs = math.min(minOurs, 1 / math.max(ours, 1e-9))
      minRef = math.min(minRef, r)
    end
  end
  table.sort(ratios)
  local function q(p) return ratios[math.max(1, math.floor(#ratios * p))] end
  return q(0.1), q(0.5), q(0.9), minOurs, minRef
end

-- Ligne synthétique : liste de points { x, y, z } (largeurs 6 m de chaque côté).
local function rawFrom(points, open)
  local raw = { ok = true, n = #points, x = {}, y = {}, z = {}, left = {}, right = {}, open = open, failures = 0 }
  for i, p in ipairs(points) do
    raw.x[i], raw.y[i], raw.z[i], raw.left[i], raw.right[i] = p[1], p[2], p[3], 6, 6
  end
  return raw
end

-- Cercle parcouru dans un sens (sign = 1) ou dans l'autre (sign = −1, reflet selon z).
local function circle(radius, step, sign)
  local pts, n = {}, math.floor(2 * math.pi * radius / step)
  for i = 0, n - 1 do
    local a = 2 * math.pi * i / n
    pts[#pts + 1] = { radius * math.sin(a), 0, sign * radius * (1 - math.cos(a)) }
  end
  return pts
end

-- Même ligne avec une ligne d'arrivée décalée de off points.
local function rotateRaw(raw, off)
  local out = { ok = true, n = raw.n, open = raw.open, failures = 0, lengthSim = raw.lengthSim, source = raw.source,
    x = {}, y = {}, z = {}, p = {}, left = {}, right = {}, bankN = raw.bankN and {} or nil }
  local p0 = raw.p[off + 1]
  for i = 1, raw.n do
    local j = (i + off - 1) % raw.n + 1
    out.x[i], out.y[i], out.z[i], out.left[i], out.right[i] = raw.x[j], raw.y[j], raw.z[j], raw.left[j], raw.right[j]
    out.p[i] = (raw.p[j] - p0) % 1
    if out.bankN then out.bankN[i] = raw.bankN[j] end
  end
  return out
end

local function signature(t)
  local corners, chicanes = 0, 0
  for _, seg in ipairs(t.segments) do
    if seg.kind == 'corner' then corners = corners + 1 end
    if seg.chicane then chicanes = chicanes + 1 end
  end
  return corners, chicanes
end

tests['T01 longueur, pas constant, pas automatique'] = function()
  for _, id in ipairs({ 'spa', 'monza', 'ks_red_bull_ring-layout_gp' }) do
    local t = build(id)
    T.ok(math.abs(t.lengthError) < 0.001, id .. ' longueur ' .. t.lengthError)
    T.near(t.ds, 2, 0.01, id .. ' pas')
    T.eq(t.n, math.floor(t.length / t.ds + 0.5))
    T.ok(t.closed)
    T.eq(t.confidence, 1, id .. ' confiance')
    local total = 0
    for _, seg in ipairs(t.segments) do total = total + seg.length end
    T.near(total, t.length, 1e-6, id .. ' segments = tour complet')
    T.eq(#t.surf, t.n)
  end
  -- Nordschleife : l'abscisse interne de la ligne IA d'AC dépasse la géométrie de 0,5 % (20 799 m
  -- annoncés pour 20 693 m mesurés) ; la règle ±0,5 % le signale et abaisse la confiance. Le pas
  -- passe automatiquement à 5 m (§8.8).
  local n = build('ks_nordschleife-nordschleife')
  T.ok(n.lengthError < -0.005, 'écart réel signalé ' .. n.lengthError)
  T.ok(n.confidence < 1)
  T.contains(table.concat(n.warnings, ' ; '), 'ligne IA')
  T.near(n.ds, 5, 0.01, 'pas automatique')
  T.ok(n.n <= K.trackAutoMaxPoints + 200)
  T.eq(TrackModel.effectiveStep(6000, 2), 2)
  T.eq(TrackModel.effectiveStep(6000, 4), 4, 'le pas demandé reste un minimum')
end

tests['T02 courbure contre le rayon de référence fast_lane'] = function()
  for _, case in ipairs({ { 'spa', 0.85, 1.15 }, { 'monza', 0.85, 1.15 }, { 'ks_red_bull_ring-layout_gp', 0.85, 1.15 },
    { 'ks_nordschleife-nordschleife', 0.7, 1.3 } }) do
    local t, h = build(case[1])
    local p10, p50, p90, minOurs, minRef = curvatureRatios(t, h)
    T.ok(p50 > 0.93 and p50 < 1.05, case[1] .. ' médiane κR ' .. p50)
    T.ok(p10 >= case[2], case[1] .. ' 10e centile ' .. p10)
    T.ok(p90 <= case[3], case[1] .. ' 90e centile ' .. p90)
    -- garde contre le lissage excessif : épingles au plus 25 % plus larges que la référence
    T.ok(minOurs <= 1.25 * minRef, case[1] .. ' épingle ' .. minOurs .. ' m contre ' .. minRef .. ' m')
    T.ok(minOurs >= 0.85 * minRef, case[1] .. ' épingle trop serrée ' .. minOurs)
  end
end

tests['T03 géométries synthétiques : cercle, sens, ligne droite, S'] = function()
  for _, sign in ipairs({ 1, -1 }) do
    local raw = rawFrom(circle(100, 1, sign))
    local t = assert(TrackModel.build(raw, nil, 2))
    for k = 1, t.n, 37 do
      T.near(math.abs(t.kappa[k]), 0.01, 0.0001, 'rayon 100 m')
      T.eq(t.kappa[k] > 0 and 1 or -1, t.kappa[1] > 0 and 1 or -1, 'signe constant')
    end
    T.near(t.length, 2 * math.pi * 100, 2)
    T.eq(#t.segments, 1, 'cercle : un seul virage')
  end
  local plus = assert(TrackModel.build(rawFrom(circle(100, 1, 1)), nil, 2))
  local minus = assert(TrackModel.build(rawFrom(circle(100, 1, -1)), nil, 2))
  T.ok(plus.kappa[10] * minus.kappa[10] < 0, 'sens opposés : courbures de signes opposés')
  local line = {}
  for i = 0, 800 do line[#line + 1] = { i, 0, 0 } end
  local straight = assert(TrackModel.build(rawFrom(line, true), nil, 2))
  T.ok(not straight.closed)
  for k = 1, straight.n do T.near(straight.kappa[k], 0, 1e-9) end
  T.eq(#straight.segments, 1)
  T.eq(straight.segments[1].kind, 'straight')
  T.near(straight.segments[1].length, 800, 1e-6, 'tracé ouvert : N − 1 intervalles')
  T.near(straight.s[straight.n], 800, 1e-6, 'tracé ouvert : dernier point à l\'arrivée')
  -- S : virage à gauche (R 60 m, 90°) enchaîné d'un virage à droite, entre deux lignes droites
  local pts, x, z, heading = {}, 0, 0, 0
  local function go(len, curv)
    for _ = 1, len do
      heading = heading + curv
      x, z = x + math.cos(heading), z + math.sin(heading)
      pts[#pts + 1] = { x, 0, z }
    end
  end
  go(300, 0)
  go(94, 1 / 60)
  go(94, -1 / 60)
  go(300, 0)
  local s = assert(TrackModel.build(rawFrom(pts, true), nil, 2))
  local corners = {}
  for _, seg in ipairs(s.segments) do
    if seg.kind == 'corner' then corners[#corners + 1] = seg end
  end
  T.eq(#corners, 2, 'S : deux virages distincts')
  T.ok(corners[1].dir ~= corners[2].dir)
  T.ok(corners[1].chicane and corners[2].chicane, 'S serré marqué chicane')
  T.near(corners[1].radius, 60, 6)
  -- même S en grand (R 200 m) : enchaînement rapide, pas une chicane
  pts, x, z, heading = {}, 0, 0, 0
  go(300, 0)
  go(160, 1 / 200)
  go(160, -1 / 200)
  go(300, 0)
  local wide = assert(TrackModel.build(rawFrom(pts, true), nil, 2))
  for _, seg in ipairs(wide.segments) do T.no(seg.chicane, 'S rapide (R 200 m) non marqué chicane') end
end

tests['T04 pente et courbure verticale'] = function()
  local function maxSlope(t)
    local m = 0
    for k = 1, t.n do m = math.max(m, math.abs(t.theta[k])) end
    return m
  end
  T.ok(maxSlope(build('spa')) > 0.12, 'Spa : Raidillon > 12 %')
  T.ok(maxSlope(build('monza')) < 0.05, 'Monza : plat')
  -- rampe ouverte à 10 % : pente constante, aucune courbure verticale fictive aux extrémités
  local ramp = {}
  for i = 0, 1000 do ramp[#ramp + 1] = { i, 0.1 * i, 0 } end
  local t = assert(TrackModel.build(rawFrom(ramp, true), nil, 2))
  for k = 1, t.n do
    T.near(t.theta[k], math.atan(0.1), 1e-6, 'pente')
    T.near(t.kappaV[k], 0, 1e-9, 'courbure verticale au point ' .. k)
  end
  T.eq(#t.bumps, 0)
  -- Spa : compression d'Eau Rouge détectée
  local spa = build('spa')
  local compression = false
  for _, b in ipairs(spa.bumps) do
    if b.kind == 'compression' and b.s0 > 900 and b.s0 < 1300 then compression = true end
  end
  T.ok(compression, 'compression du bas d\'Eau Rouge')
  T.ok(#build('monza').bumps <= #spa.bumps, 'Monza, plate, n\'a pas plus de bosses que Spa')
end

tests['T05 dévers sondé contre le dévers de référence (vers l\'intérieur)'] = function()
  for _, id in ipairs({ 'spa', 'ks_nordschleife-nordschleife' }) do
    local t, h, raw = build(id)
    T.ok(t.hasBank, id)
    T.eq(raw.bankFailures, 0, id .. ' : un rayon sur la ligne, jamais hors piste')
    -- la colonne c de fast_lane est un dévers vers l'intérieur du virage : on compare phi·signe(κ)
    local ref = refIndexer(t, h)
    local sx, sy, sxx, syy, sxy, n = 0, 0, 0, 0, 0, 0
    for k = 1, t.n do
      if math.abs(t.kappa[k]) > K.cornerKappaIn then
        local a, b = t.phi[k] * (t.kappa[k] > 0 and 1 or -1), ref(k)[9]
        sx, sy, sxx, syy, sxy, n = sx + a, sy + b, sxx + a * a, syy + b * b, sxy + a * b, n + 1
      end
    end
    local corr = (n * sxy - sx * sy) / math.sqrt((n * sxx - sx * sx) * (n * syy - sy * sy))
    T.ok(corr > 0.9, id .. ' : corrélation ' .. corr)
  end
  -- Karussell : le virage le plus relevé de la référence est relevé vers l'intérieur dans le modèle
  local t, h = build('ks_nordschleife-nordschleife')
  local ref = refIndexer(t, h)
  local best, at = -1, 1
  for k = 1, t.n do
    if ref(k)[9] > best then best, at = ref(k)[9], k end
  end
  local inward = t.phi[at] * (t.kappa[at] > 0 and 1 or -1)
  T.ok(best > 0.2, 'référence très relevée ' .. best)
  T.ok(inward > 0.6 * best, 'Karussell vers l\'intérieur : ' .. inward .. ' contre ' .. best)
  -- sans raycast : dévers nul, signalé, confiance réduite
  local raw2 = rawOf('monza', { missing = { 'physics.raycastTrack' } })
  T.eq(raw2.bankReason, 'physics.raycastTrack indisponible')
  local t2 = assert(TrackModel.build(raw2, nil, 2))
  T.no(t2.hasBank)
  T.near(t2.confidence, 0.9, 1e-9)
  T.contains(table.concat(t2.warnings, ' '), 'dévers inconnu')
end

tests['T06 segments, chicanes, zones DRS, grip de surface'] = function()
  local spa = build('spa')
  T.ok(spa.cornerCount >= 16 and spa.cornerCount <= 24, 'Spa : ' .. spa.cornerCount .. ' virages')
  T.ok(spa.minRadius > 15 and spa.minRadius < 30, 'La Source ' .. spa.minRadius)
  local spaChicanes = 0
  for _, seg in ipairs(spa.segments) do
    if seg.kind == 'corner' then T.ok(seg.radius < 400, 'rayon d\'un virage ' .. seg.radius) end
    if seg.chicane then
      spaChicanes = spaChicanes + 1
      T.ok(seg.radius <= K.chicaneMaxRadius, 'chicane serrée seulement')
      local lesCombes, busStop = seg.s0 > 2200 and seg.s0 < 2700, seg.s0 > 6500
      T.ok(lesCombes or busStop, 'Spa : chicanes aux Combes et à la Bus Stop seulement (s = ' .. seg.s0 .. ')')
    end
  end
  T.ok(spaChicanes >= 2 and spaChicanes <= 5, 'Spa : chicanes ' .. spaChicanes)
  local monza = build('monza')
  local _, monzaChicanes = signature(monza)
  T.ok(monzaChicanes >= 4 and monzaChicanes <= 6, 'Monza : Rettifilo et Roggia, ' .. monzaChicanes)
  T.eq(#spa.drsZones, 2)
  for _, z in ipairs(spa.drsZones) do
    T.ok(z.start >= 0 and z.start < spa.length and z.finish >= 0 and z.finish < spa.length)
    T.ok(z.length > 300 and z.length < 1500, 'longueur de zone ' .. z.length)
  end
  T.near(spa.surfaceGrip, 0.98, 1e-9)
  T.eq(TrackModel.surfaceGrip(nil), 1)
  local mix = TrackModel.mix(spa)
  T.ok(mix.straight > 0.3 and mix.straight < 0.9, 'part de lignes droites ' .. mix.straight)
  local ring = assert(TrackModel.build(rawFrom(circle(200, 1, 1)), nil, 2))
  local wrap = TrackModel.drsZones(Util.parseIni('[ZONE_0]\nDETECTION=0.95\nSTART=0.98\nEND=0.05\n'), ring)
  T.near(wrap[1].length, 0.07 * ring.length, 0.5, 'zone à cheval sur la ligne')
  T.near(wrap[1].detection, 0.95 * ring.length, 0.5)
end

tests['T07 segmentation indépendante de la ligne d\'arrivée'] = function()
  for _, id in ipairs({ 'spa', 'monza', 'ks_red_bull_ring-layout_gp' }) do
    local t, _, raw = build(id)
    local corners, chicanes = signature(t)
    for _, frac in ipairs({ 0.013, 0.071, 0.137, 0.29, 0.41, 0.58, 0.77, 0.93 }) do
      local rotated = assert(TrackModel.build(rotateRaw(raw, math.floor(raw.n * frac)), nil, 2))
      local c2, ch2 = signature(rotated)
      T.eq(c2, corners, id .. ' : virages, départ décalé de ' .. frac)
      T.eq(ch2, chicanes, id .. ' : chicanes, départ décalé de ' .. frac)
    end
  end
end

tests['T08 cas dégradés : ligne non refermée, largeurs, entrées invalides'] = function()
  T.eq(TrackModel.build(nil, nil, 2), nil)
  local bad, why = TrackModel.build({ ok = false, reason = 'pas de ligne' }, nil, 2)
  T.eq(bad, nil)
  T.contains(why, 'pas de ligne')
  local short = {}
  for i = 0, 100 do short[#short + 1] = { i, 0, 0 } end
  local tiny, whyTiny = TrackModel.build(rawFrom(short, true), nil, 2)
  T.eq(tiny, nil)
  T.contains(whyTiny, 'hors plage')
  -- largeurs : absentes partout, ou sur quelques points seulement
  local raw = rawFrom(circle(200, 2, 1))
  for i = 1, raw.n do raw.left[i] = -1 end
  local noWidth = assert(TrackModel.build(raw, nil, 2))
  T.no(noWidth.hasWidth)
  T.eq(noWidth.width[1], K.trackDefaultWidth)
  local some = rawFrom(circle(200, 2, 1))
  some.left[5] = -1
  local fine = assert(TrackModel.build(some, nil, 2))
  T.ok(fine.hasWidth, 'un point sans largeur ne rend pas toutes les largeurs inconnues')
  T.near(fine.confidence, 0.9, 1e-9, 'seul le dévers inconnu abaisse la confiance')
  -- « fermé » d'après le drapeau, mais la ligne s'arrête 1,2 km avant le départ : traité comme ouvert
  local spaRaw = select(3, build('spa'))
  local cut = { ok = true, n = 0, x = {}, y = {}, z = {}, p = {}, left = {}, right = {}, failures = 0 }
  for i = 1, math.floor(spaRaw.n * 0.8) do
    cut.n = i
    cut.x[i], cut.y[i], cut.z[i], cut.p[i] = spaRaw.x[i], spaRaw.y[i], spaRaw.z[i], spaRaw.p[i]
    cut.left[i], cut.right[i] = spaRaw.left[i], spaRaw.right[i]
  end
  local opened = assert(TrackModel.build(cut, nil, 2))
  T.no(opened.closed)
  T.contains(table.concat(opened.warnings, ' '), 'non refermée')
  T.ok(opened.length < 0.81 * 6944, 'pas de corde fictive : ' .. opened.length)
end

tests['T09 performance et découpage (D6)'] = function()
  local raw = select(3, build('ks_nordschleife-nordschleife'))
  local started = PY.clock()
  local t = assert(TrackModel.build(raw, nil, 2))
  local ms = (PY.clock() - started) * 1000
  T.ok(ms < 150, 'Nordschleife : ' .. ms .. ' ms')
  -- écart maximal entre deux rendus de main, y compris segmentation et fin de construction (après
  -- une construction de chauffe : la première compilation JIT d'une boucle n'est pas prévisible)
  for _, case in ipairs({ { 'ks_nordschleife-nordschleife', 2 }, { 'spa', 1 } }) do
    local r = select(3, build(case[1]))
    TrackModel.build(r, nil, case[2])
    -- meilleure de trois séries : la préemption du système peut allonger un intervalle isolé (A16)
    local worst, ticks = math.huge, 0
    for _ = 1, 3 do
      local last, series = PY.clock(), 0
      ticks = 0
      TrackModel.build(r, nil, case[2], function()
        local now = PY.clock()
        series = math.max(series, now - last)
        last = now
        ticks = ticks + 1
      end)
      worst = math.min(worst, math.max(series, PY.clock() - last))
    end
    T.ok(ticks > 50, case[1] .. ' : ' .. ticks .. ' rendus')
    T.ok(worst * 1000 < 1.0, case[1] .. ' : écart maximal ' .. worst * 1000 .. ' ms')
  end
  T.ok(t.n > 3000)
end

-- Bornes élargies le 29/10/2026 (relecture des données) : karting dès 200 m, grands circuits jusqu'à 75 km.
tests['T10 §16.7 : circuit de moins de 200 m ou de plus de 75 km refusé, raison donnée'] = function()
  local short, why = TrackModel.build(rawFrom(circle(25, 2, 1)), nil, 2)   -- 157 m
  T.eq(short, nil)
  T.contains(why, 'longueur hors plage')
  local long, why2 = TrackModel.build(rawFrom(circle(12800, 25, 1)), nil, 5)   -- 80,4 km
  T.eq(long, nil)
  T.contains(why2, 'longueur hors plage')
  T.ok(TrackModel.build(rawFrom(circle(70, 2, 1)), nil, 2), '440 m (karting) : accepté')
  T.ok(TrackModel.build(rawFrom(circle(4200, 25, 1)), nil, 5), '26,4 km : accepté')
end

return tests
