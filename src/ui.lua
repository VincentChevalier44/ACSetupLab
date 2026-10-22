-- SetupLab — fenêtres ImGui (§12.1, §3.3 « panneau Capacités »).
-- Rendu en lecture seule de l'état (§5.5) : aucun calcul, aucune écriture. Les clics sont
-- traduits en intentions que la colle exécute après le rendu.
-- Tableau de bord (demande de Vincent du 21/10/2026 : interface épurée, dense, bien organisée, adaptée à
-- la largeur de la fenêtre) : chiffres clés en tuiles, tableaux compacts, détails dans des sections
-- repliables et des infobulles ; fenêtre large : réglages à gauche, graphiques à droite. Toute fonction
-- CSP facultative passe par Util.call ou un test de présence (D7). Un libellé de bouton n'apparaît qu'une
-- fois par onglet : deux boutons de même identifiant ImGui, et l'un des deux ne réagit plus.

local Util = require('src/util')
local Config = require('src/config')
local Caps = require('src/caps')
local SetupSpace = require('src/setup_space')

local M = {}

local K = Config.K

local STATUS_COLOR = {
  available = { 0.35, 0.85, 0.45, 1 },
  pending = { 1.0, 0.75, 0.25, 1 },
  unavailable = { 1.0, 0.35, 0.3, 1 },
  na = { 0.6, 0.6, 0.6, 1 },
  text = { 0.93, 0.94, 0.96, 1 },
  muted = { 0.6, 0.63, 0.68, 1 },
  accent = { 0.42, 0.7, 1.0, 1 },
  tile = { 1, 1, 1, 0.055 },
  -- boutons de l'étape suivante (décision de Vincent du 22/10/2026 : plus visibles)
  primaryButton = { 0.16, 0.42, 0.78, 1 }, primaryButtonHovered = { 0.22, 0.51, 0.9, 1 },
  primaryButtonActive = { 0.12, 0.34, 0.66, 1 },
  goButton = { 0.12, 0.52, 0.28, 1 }, goButtonHovered = { 0.16, 0.63, 0.35, 1 }, goButtonActive = { 0.09, 0.42, 0.22, 1 },
  dangerButton = { 0.6, 0.18, 0.15, 1 }, dangerButtonHovered = { 0.72, 0.23, 0.2, 1 }, dangerButtonActive = { 0.48, 0.14, 0.12, 1 },
}

function M.new()
  return { message = nil, messageAt = 0, colors = nil, point = nil, showCaps = false, vecs = {} }
end

-- Couleurs construites une seule fois (rgbm est fourni par l'hôte).
local function colors(state, host)
  if state.colors then return state.colors end
  local out = {}
  for status, c in pairs(STATUS_COLOR) do
    local ok, value = Util.call(host.rgbm, c[1], c[2], c[3], c[4])
    out[status] = ok and value or nil
  end
  state.colors = out
  return out
end

-- Meilleur tour d'un setup sur un état de piste (clé de l'enregistreur : « signature#pluie » si mouillé).
local function bestLap(app, signature, bucket)
  local best = app.recorder and app.recorder.laps and app.recorder.laps.best
  if best == nil or signature == nil then return nil end
  return best[bucket == 'pluie' and (tostring(signature) .. '#pluie') or signature]
end

-- Vos temps avec un setup (demande de Vincent du 22/10/2026 : « se baser sur mes temps à moi ») : tours
-- valides, même état de piste, par « famille » de setup (sans les réglages changés en roulant : sur la DTM,
-- un tour avec la répartition de freinage touchée au volant compte pour la version chargée). { best, count,
-- sum } ou nil.
local function realLaps(app, family, bucket)
  local fam = app.recorder and app.recorder.laps and app.recorder.laps.family
  if fam == nil or family == nil then return nil end
  return fam[bucket == 'pluie' and (tostring(family) .. '#pluie') or family]
end

-- Temps de référence de vos tours : meilleur tour (tour rapide) ou moyenne (course), ou nil.
local function realTime(stats, kind)
  if stats == nil or (stats.count or 0) == 0 then return nil end
  return kind == 'race' and stats.sum / stats.count or stats.best
end

-- vec2 réutilisable, créé une fois (aucune allocation par image).
local function vec(host, state, name)
  state.vecs = state.vecs or {}
  local v = state.vecs[name]
  if v == nil then
    local ok, made = Util.call(host.vec2, 0, 0)
    v = ok and made or nil
    state.vecs[name] = v
  end
  return v
end

-- ---------------------------------------------------------------------------
-- Éléments du tableau de bord
-- ---------------------------------------------------------------------------

local function colored(host, text, color)
  if color then
    host.ui.textColored(text, color)
  else
    host.ui.text(text)
  end
end

-- Police CSP (ui.Font : Small, Title…) le temps de fn ; sans elle, police courante.
local function withFont(host, name, fn)
  local ui = host.ui
  local fonts = Util.get(ui, 'Font')
  local pushed = false
  if type(fonts) == 'table' and fonts[name] ~= nil then pushed = Util.call(ui.pushFont, fonts[name]) end
  fn()
  if pushed then Util.call(ui.popFont) end
end

-- Texte coloré qui revient à la ligne (couleur du texte poussée) ; sans pushStyleColor : texte coloré.
local function wrapped(host, text, color)
  local ui = host.ui
  local styles = Util.get(ui, 'StyleColor')
  local pushed = color ~= nil and type(styles) == 'table' and styles.Text ~= nil and Util.call(ui.pushStyleColor, styles.Text, color)
  if color ~= nil and not pushed then
    ui.textColored(text, color)
  else
    ui.textWrapped(text)
  end
  if pushed then Util.call(ui.popStyleColor, 1) end
end

-- Texte secondaire, en petit, qui revient à la ligne (fenêtre étroite).
local function small(host, text, color)
  withFont(host, 'Small', function() wrapped(host, text, color) end)
end

-- Infobulle de l'élément précédent, au survol (texte brut : « % » sans danger), largeur bornée.
local function tip(host, text)
  if text == nil or text == '' then return end
  local ui = host.ui
  local okH, hovered = Util.call(ui.itemHovered)
  if not (okH and hovered) then return end
  Util.call(ui.tooltip, function()
    local pushed = Util.call(ui.pushTextWrapPosition, K.uiTooltipWidth)
    ui.text(text)
    if pushed then Util.call(ui.popTextWrapPosition) end
  end)
end

-- Section repliable (en-tête encadré), ouverte d'office si open ; identifiant stable malgré un titre
-- qui change (« ### »), retrait réduit (densité).
local TREE_FRAMED, TREE_OPEN = 0x2, 0x20
local function section(host, title, id, open, fn)
  local ui = host.ui
  if ui.treeNode == nil then
    small(host, title, nil)
    fn()
    return
  end
  local styles = Util.get(ui, 'StyleVar')
  local pushed = type(styles) == 'table' and styles.IndentSpacing ~= nil
    and Util.call(ui.pushStyleVar, styles.IndentSpacing, K.uiIndent)
  ui.treeNode(title .. '###' .. id, TREE_FRAMED + (open and TREE_OPEN or 0), fn)
  if pushed then Util.call(ui.popStyleVar, 1) end
end

-- Tableau compact : colonnes ImGui sans bordure, largeurs en fractions de la largeur disponible ; une
-- cellule est un texte, ou { text, color, tip }. Sans colonnes : cellules sur une ligne.
local function grid(host, id, widths, rows)
  local ui = host.ui
  local hasColumns = ui.columns ~= nil and ui.nextColumn ~= nil
  if hasColumns then
    local okW, avail = Util.call(ui.availableSpaceX)
    ui.columns(#widths, false, id)
    if okW and Util.isFinite(avail) then
      for i = 1, #widths - 1 do Util.call(ui.setColumnWidth, i - 1, widths[i] * avail) end
    end
  end
  for _, row in ipairs(rows) do
    for i, cell in ipairs(row) do
      if type(cell) == 'table' then
        colored(host, cell.text, cell.color)
        tip(host, cell.tip)
      else
        ui.text(cell)
      end
      if hasColumns then
        ui.nextColumn()
      elseif i < #row then
        ui.sameLine()
      end
    end
  end
  if hasColumns then ui.columns(1, false) end
end

-- En-tête de colonne (discret, infobulle facultative).
local function head(palette, text, help)
  return { text = text, color = palette.muted, tip = help }
end

-- Chiffres clés en tuiles : autant par ligne que la largeur le permet, étiquette discrète, valeur en
-- grand (couleur de l'état), infobulle au survol. Sans dessin possible : une ligne par chiffre.
local function tiles(host, state, list, palette)
  local ui = host.ui
  local okW, avail = Util.call(ui.availableSpaceX)
  local okC, cursor = Util.call(ui.getCursor)
  local p, q = vec(host, state, 'tileA'), vec(host, state, 'tileB')
  if not (okW and okC and cursor and Util.isFinite(avail) and p and q) or ui.setCursor == nil or ui.drawText == nil then
    for _, t in ipairs(list) do
      colored(host, t.label .. ' : ' .. t.value, t.color)
      tip(host, t.tip)
    end
    return
  end
  local x0, y0 = cursor.x, cursor.y
  local gap, height = K.uiGap, K.uiTileHeight
  local perRow = math.max(1, math.min(#list, math.floor((avail + gap) / (K.uiTileMin + gap))))
  local width = (avail - gap * (perRow - 1)) / perRow
  for i, t in ipairs(list) do
    local x = x0 + ((i - 1) % perRow) * (width + gap)
    local y = y0 + math.floor((i - 1) / perRow) * (height + gap)
    p.x, p.y = x, y
    ui.setCursor(p)
    q.x, q.y = width, height
    ui.dummy(q)
    tip(host, t.tip)
    q.x, q.y = x + width, y + height
    Util.call(ui.drawRectFilled, p, q, palette.tile, 4)
    p.x, p.y = x + 8, y + 4
    withFont(host, 'Small', function() ui.drawText(t.label, p, palette.muted) end)
    p.x, p.y = x + 8, y + 19
    withFont(host, 'Title', function() ui.drawText(t.value, p, t.color or palette.text) end)
  end
end

-- Élément suivant sur la même ligne s'il y tient (libellé mesuré), sinon à la ligne.
local function nextInline(host, label)
  local ui = host.ui
  ui.sameLine()
  local okR, room = Util.call(ui.availableSpaceX)
  local okM, size = Util.call(ui.measureText, label)
  local need = okM and type(size) ~= 'number' and size and Util.isFinite(size.x) and size.x + K.uiButtonPad or nil
  if okR and need and Util.isFinite(room) and room < need then Util.call(ui.newLine) end
end

-- Bouton d'action (décision de Vincent du 22/10/2026 : « il faut que ce soit plus visible au niveau des
-- boutons ») : l'étape suivante en couleur pleine (primary : valider, enregistrer ; go : charger, confirmer ;
-- danger : écarter une version plus lente), pleine largeur si full. ui.button appelé directement (une erreur,
-- un identifiant en double, se voient) ; seules les couleurs passent par Util.call, autant retirées que posées.
local function actionButton(host, state, palette, label, style, full)
  local ui = host.ui
  local styles = Util.get(ui, 'StyleColor')
  local pushed = 0
  if style and type(styles) == 'table' then
    for _, slot in ipairs({ 'Button', 'ButtonHovered', 'ButtonActive' }) do
      local color = palette[style .. slot]
      if styles[slot] ~= nil and color ~= nil and Util.call(ui.pushStyleColor, styles[slot], color) then pushed = pushed + 1 end
    end
  end
  local size = full and vec(host, state, 'bigButton') or nil
  if size then size.x, size.y = -1, K.uiBigButtonHeight end
  local clicked = ui.button(label, size)
  if pushed > 0 then Util.call(ui.popStyleColor, pushed) end
  return clicked
end

-- Carte : contenu en retrait, barre de couleur à gauche (dessinée après coup, sans rien recouvrir).
local function card(host, state, color, fn)
  local ui = host.ui
  local okA, top = Util.call(ui.getCursor)
  local x, y = okA and top and top.x, okA and top and top.y
  Util.call(ui.indent, K.uiIndent)
  fn()
  Util.call(ui.unindent, K.uiIndent)
  local okB, bottom = Util.call(ui.getCursor)
  local p, q = vec(host, state, 'cardA'), vec(host, state, 'cardB')
  if x and okB and bottom and p and q and Util.isFinite(bottom.y) and bottom.y > y then
    p.x, p.y = x, y
    q.x, q.y = x + 3, bottom.y - 4
    Util.call(ui.drawRectFilled, p, q, color, 1)
  end
end

-- ---------------------------------------------------------------------------
-- Mise en forme
-- ---------------------------------------------------------------------------

-- Temps au tour « m:ss.mmm ».
function M.lapTime(seconds)
  if not Util.isFinite(seconds) then return '—' end
  local m = math.floor(seconds / 60)
  return string.format('%d:%06.3f', m, seconds - 60 * m)
end

-- Valeur physique d'un réglage avec son unité d'affichage.
local UNITS = {
  wing = { 1, '°', 1 }, pressure = { 1, ' psi', 1 }, spring = { 0.001, ' N/mm', 0 }, heave = { 0.001, ' N/mm', 0 },
  arb = { 1, ' N/m', 0 }, rod = { 1000, ' mm', 1 }, camber = { 1, '°', 1 }, brakeBias = { 100, ' %', 1 },
  brakePower = { 100, ' %', 0 }, diffPower = { 100, ' %', 0 }, limiter = { 100, ' %', 0 }, fuel = { 1, ' L', 0 },
  gear = { 1, '', 3 }, final = { 1, '', 3 },
}
function M.physicalText(kind, value)
  local u = UNITS[kind] or { 1, '', 3 }
  return Util.fmt(value and value * u[1], u[3]) .. u[2]
end

-- Écart signé « -0.330 s » (négatif : plus rapide).
local function gainText(gain, suffix)
  return (gain >= 0 and '-' or '+') .. Util.fmt(math.abs(gain), 3) .. ' s' .. (suffix or '')
end

-- Durée réelle estimée d'un calcul (A13) : coût mesuré d'une évaluation, tranche et fréquence d'images.
-- lapsPerEval : tours simulés par évaluation (1 en qualification ; relais échantillonné en course).
function M.estimateSeconds(app, budget, lapsPerEval, kind)
  local evalMs = app.evalCost and app.evalCost(kind or 'quali') or nil
  if evalMs == nil then
    local d = app.discovery
    evalMs = d and d.simCurrent and d.simCurrent.evalMs
  end
  if not Util.isFinite(evalMs) then return nil end
  evalMs = evalMs * (lapsPerEval or 1)
  local fps = app.context and app.context.fps
  if not Util.isFinite(fps) or fps <= 0 then fps = Config.K.fpsTarget end
  -- sous fpsTarget, la tranche est réduite (A4) : le calcul est d'autant plus long
  local slice = app.settings.sliceBudgetMs
  if fps < Config.K.fpsTarget then slice = slice * Config.K.slowFpsSliceFactor end
  local cpuMs = budget * evalMs * Config.K.optEstimateFactor
  return cpuMs / (slice * fps)
end

-- Durée affichée avant le lancement (§14.3) : estimée au budget réglé, à la fréquence d'images et à la
-- tranche réelles, jamais plafonnée (le budget ne dépend jamais du temps : résultat reproductible,
-- §10.5). Renvoie le texte et vrai si la durée dépasse la durée indicative (affichée en orange).
function M.durationText(estimate, target, slow)
  if estimate == nil then return ' (durée estimée après la découverte)', false end
  local text = ', durée estimée ≈ ' .. Util.fmt(estimate, 0) .. ' s'
  local long = estimate > target
  if long then text = text .. ' : plus de ' .. target .. ' s, baisser le budget dans l\'onglet Réglages pour aller plus vite' end
  if slow then text = text .. ' (sous 60 images/s, la tranche de calcul est réduite)' end
  return text, long
end

-- Sous la fréquence d'images visée (tranche de calcul réduite, A4).
function M.slowFrames(app)
  local fps = app.context and app.context.fps
  return Util.isFinite(fps) and fps > 0 and fps < Config.K.fpsTarget or false
end

-- Ligne d'état principale (une seule phrase, la plus importante d'abord).
function M.statusLine(app)
  if app.inert then return app.inert, 'pending' end
  if app.discoveryState == 'running' then return 'Découverte en cours…', 'pending' end
  if app.discoveryState == 'failed' then return 'Découverte interrompue : ' .. tostring(app.discoveryError), 'unavailable' end
  -- piste mouillée (D16 amendé le 21/10/2026) : setups pluie, humidité et eau de la piste
  if app.wet and app.wet.state == 'pluie' then
    return 'Piste mouillée : setups pluie (humidité ' .. Util.fmt((app.wet.wetness or 0) * 100, 0) .. ' %, eau '
      .. Util.fmt((app.wet.water or 0) * 100, 0) .. ' %).', 'pending'
  end
  if app.discoveryState == 'done' then
    return 'Découverte terminée (' .. Util.fmt(app.discovery and app.discovery.durationMs, 1) .. ' ms de calcul).', 'available'
  end
  return 'En attente du contexte voiture/circuit.', 'na'
end

-- Confiance du modèle : celle du dernier calcul terminé (composé retenu calibré ou non), sinon
-- calibration disponible pour un composé. Renvoie « calibré », « non calibré » ou « non calibré
-- (calibration disponible) ».
function M.modelState(app)
  local latest = nil
  for _, q in ipairs({ app.quali, app.race }) do
    if q and q.state == 'done' and q.result and (latest == nil or (q.doneAt or 0) >= (latest.doneAt or 0)) then latest = q end
  end
  if latest then return latest.result.calibrated and 'calibré' or 'non calibré' end
  for _, c in pairs(app.calibrations or {}) do
    local r = c.result or c.previous
    if r and r.usable then return 'non calibré (calibration disponible)' end
  end
  return 'non calibré'
end

-- ---------------------------------------------------------------------------
-- Graphiques
-- ---------------------------------------------------------------------------

-- Profils de vitesse superposés (actuel, proposé) : v(s) normalisé, sans allocation par point.
local function plotProfiles(host, state, profiles, palette)
  local ui = host.ui
  local okW, width = Util.call(ui.availableSpaceX)
  local okC, origin = Util.call(ui.getCursor)
  if not (okW and okC and Util.isFinite(width) and origin) then return end
  width = math.max(100, width - 4)
  local height = Config.K.plotHeight
  if state.point == nil then
    local okP, point = Util.call(host.vec2, 0, 0)
    local okQ, corner = Util.call(host.vec2, 0, 0)
    if not (okP and okQ) then return end
    state.point, state.corner = point, corner
  end
  local point, corner = state.point, state.corner
  local vmax = 1
  for _, pr in ipairs(profiles) do
    for i = 1, #pr.profile.v do vmax = math.max(vmax, pr.profile.v[i]) end
  end
  corner.x, corner.y = origin.x + width, origin.y + height
  ui.drawRect(origin, corner, palette.na)
  for _, pr in ipairs(profiles) do
    local prof = pr.profile
    for i = 1, #prof.v do
      point.x = origin.x + prof.s[i] / prof.length * width
      point.y = origin.y + height - prof.v[i] / vmax * (height - 4)
      ui.pathLineTo(point)
    end
    ui.pathStroke(pr.color, false, 1.5)
  end
  point.x, point.y = width, height
  ui.dummy(point)
  small(host, 'Vitesse simulée le long du tour (0 à ' .. Util.fmt(vmax * 3.6, 0) .. ' km/h)'
    .. (#profiles > 1 and ' : orange = actuel, vert = proposé' or ''), palette.muted)
end

-- Équilibre par virage (§12.1) : une ligne par setup (actuel, proposé), virage par virage le long du
-- tour, autour de l'équilibre neutre (1) ; au-dessus survireur, au-dessous sous-vireur.
local function plotCorners(host, state, series, palette)
  local ui = host.ui
  local okW, width = Util.call(ui.availableSpaceX)
  local okC, origin = Util.call(ui.getCursor)
  if not (okW and okC and Util.isFinite(width) and origin) or state.point == nil then return end
  width = math.max(100, width - 4)
  local height = Config.K.plotHeight
  local point, corner = state.point, state.corner
  local span = 0.05
  for _, s in ipairs(series) do
    for _, c in ipairs(s.corners) do span = math.max(span, math.abs(c.balance - 1)) end
  end
  corner.x, corner.y = origin.x + width, origin.y + height
  ui.drawRect(origin, corner, palette.na)
  point.x, point.y = origin.x, origin.y + height / 2
  ui.pathLineTo(point)
  point.x = origin.x + width
  ui.pathLineTo(point)
  ui.pathStroke(palette.na, false, 1)
  for _, s in ipairs(series) do
    if #s.corners > 0 then
      for _, c in ipairs(s.corners) do
        point.x = origin.x + c.s / s.length * width
        point.y = origin.y + height / 2 - (c.balance - 1) / span * (height / 2 - 4)
        ui.pathLineTo(point)
      end
      ui.pathStroke(s.color, false, 1.5)
    end
  end
  point.x, point.y = width, height
  ui.dummy(point)
  small(host, 'Équilibre par virage (milieu = neutre, au-dessus survireur, au-dessous sous-vireur, ±'
    .. Util.fmt(span, 2) .. ') : orange = actuel, vert = proposé', palette.muted)
end

-- Graphiques d'un résultat : vitesse, puis équilibre par virage.
local function resultPlots(host, app, r, palette)
  if r.profileCurrent and r.profileProposed then
    plotProfiles(host, app.ui, {
      { profile = r.profileCurrent, color = palette.pending }, { profile = r.profileProposed, color = palette.available },
    }, palette)
  end
  if r.cornersCurrent and r.cornersProposed and r.profileCurrent then
    plotCorners(host, app.ui, {
      { corners = r.cornersCurrent, length = r.profileCurrent.length, color = palette.pending },
      { corners = r.cornersProposed, length = r.profileCurrent.length, color = palette.available },
    }, palette)
  end
end

-- ---------------------------------------------------------------------------
-- Détails d'un résultat (sections repliables)
-- ---------------------------------------------------------------------------

-- Composé retenu (D18) : changé ou conservé, imposé, comparatif au setup actuel, notes.
local function compoundLines(host, r, palette)
  local c = r.compound
  if c == nil then return end
  local parts = {}
  for _, e in ipairs(c.comparison) do
    parts[#parts + 1] = tostring(e.short or e.name) .. (e.use and e.use ~= 'sec' and (' (' .. e.use .. ')') or '') .. ' '
      .. Util.fmt(e.J, 2) .. (e.conflict and ' (hors fenêtre)' or '')
  end
  host.ui.textWrapped('Composé : ' .. tostring(c.name) .. ' (' .. (c.changed and 'changé' or 'conservé')
    .. (c.imposed and ', imposé' or '') .. ') ; critère au setup actuel : ' .. table.concat(parts, ' ; ') .. ' s')
  if c.note then wrapped(host, c.note, palette.pending) end
  if c.calibrationNote then wrapped(host, c.calibrationNote, palette.pending) end
end
M.compoundLines = compoundLines

-- Pneus par essieu (§8.6) : température mesurée contre la fenêtre, pressions à chaud prévues, idéale et
-- mesurée (tableau) ; surchauffe signalée (pression jamais abaissée), notes en dessous.
local function tyreLines(host, r, palette)
  local t = r.tyres
  if t == nil then return end
  local rows = { { head(palette, 'Pneus'), head(palette, 'Température'), head(palette, 'Fenêtre'),
    head(palette, 'À chaud (psi)', 'Pression à chaud : setup actuel › proposé'), head(palette, 'Idéale') } }
  local notes = {}
  for _, axle in ipairs({ 'F', 'R' }) do
    local e = t[axle]
    local name = axle == 'F' and 'Pneus avant' or 'Pneus arrière'
    local state = palette[e.state == 'surchauffe' and 'unavailable' or (e.state == 'froid' and 'pending' or 'na')]
    rows[#rows + 1] = {
      { text = axle == 'F' and 'Avant' or 'Arrière', color = state },
      { text = e.temp and (Util.fmt(e.temp, 0) .. ' °C') or (Util.fmt(e.tempUsed, 0) .. ' °C supposés'), color = state },
      e.lo and (Util.fmt(e.lo, 0) .. '–' .. Util.fmt(e.hi, 0) .. ' °C') or 'inconnue',
      Util.fmt(e.hotCurrent, 1) .. ' › ' .. Util.fmt(e.hotProposed, 1),
      { text = Util.fmt(e.ideal, 1), tip = e.hotMeasured and ('Mesurée : ' .. Util.fmt(e.hotMeasured, 1) .. ' psi') or nil },
    }
    if e.gasLawGap and math.abs(e.gasLawGap) > 0.5 then
      notes[#notes + 1] = { name .. ' : pression mesurée ' .. (e.gasLawGap > 0 and 'au-dessus' or 'en dessous') .. ' de la loi des gaz de '
        .. Util.fmt(math.abs(e.gasLawGap), 1) .. ' psi : calcul ancré sur la mesure.' }
    end
    if not e.anchored then
      notes[#notes + 1] = { name .. ' : pression à chaud estimée sans mesure (loi des gaz, H4) : recherche réduite à ±'
        .. Config.K.optRadiusReduced .. ' crans ; rouler un tour en température pour l\'ancrer.', palette.pending }
    end
    if e.spread then
      notes[#notes + 1] = { name .. ' — Intérieur − extérieur : ' .. Util.fmt(e.spread, 1) .. ' °C'
        .. (e.camberGuard and (' ; ' .. e.camberGuard) or '') }
    end
    if e.state == 'froid' then
      notes[#notes + 1] = { name .. ' sous la fenêtre sur le tour mesuré : pression calculée au plateau de la courbe.',
        palette.pending }
    end
  end
  grid(host, 'tyres', { 0.18, 0.22, 0.2, 0.24, 0.16 }, rows)
  for _, note in ipairs(notes) do wrapped(host, note[1], note[2]) end
  if not t.measured then
    wrapped(host, 'Pneus : aucun tour mesuré, température supposée au plateau de la courbe (A19).', palette.pending)
  end
end

-- ERS (§8.9) : stratégie optimisée contre le profil de la voiture, bilan d'énergie, zones de déploiement.
local function ersLines(host, r, palette)
  local e = r.ers and r.ers.proposed
  if e == nil then return end
  wrapped(host, 'ERS (à confirmer, H21 à H23) : stratégie optimisée ' .. M.lapTime(e.timeOptimized) .. ', profil « '
    .. tostring(e.profileName) .. ' » de la voiture ' .. M.lapTime(e.timeDefault) .. ', sans ERS ' .. M.lapTime(e.timeNone),
    palette.pending)
  host.ui.textWrapped('Énergie par tour : déployée ' .. Util.fmt(e.deployed, 0) .. ' kJ (limite ' .. Util.fmt(e.maxPerLap, 0)
    .. '), récupérée ' .. Util.fmt(e.recovered, 0) .. ' kJ ; batterie ' .. Util.fmt(e.socStart, 0) .. ' -> '
    .. Util.fmt(e.socEnd, 0) .. ' kJ sur ' .. Util.fmt(e.capacity, 0)
    .. (e.mode == 'race' and ' (régime établi)' or ' (pleine au départ : supposé)'))
  if e.bestProfile then
    host.ui.text('Meilleur profil du cockpit : ' .. e.bestProfile.index .. ' « ' .. tostring(e.bestProfile.name) .. ' » ('
      .. M.lapTime(e.bestProfile.time) .. ')')
  end
  local parts = {}
  for _, z in ipairs(e.zones) do
    parts[#parts + 1] = Util.fmt(z.s0, 0) .. '–' .. Util.fmt(z.s1, 0) .. ' m'
      .. (z.profile and ' (profil)' or (z.fraction and z.fraction < 1 and (' (' .. Util.fmt(z.fraction * 100, 0) .. ' %)') or ''))
  end
  if #parts > 0 then host.ui.textWrapped('Déployer : ' .. table.concat(parts, ' ; ')) end
  if e.fallbackDefault then small(host, 'Le profil de la voiture fait aussi bien que le plan : profil conservé.', palette.na) end
end

-- DRS simulé (H8) : zones, temps ouvert, vitesse de pointe, part du gain.
local function drsLines(host, r, palette)
  local drs = r.drs
  if drs == nil then return end
  wrapped(host, 'DRS (à confirmer, H8) : ouvert dans ' .. drs.zones .. ' zone(s), ' .. Util.fmt(drs.openTime, 1)
    .. ' s par tour, pointe ' .. Util.fmt(drs.vTop and drs.vTop * 3.6, 0) .. ' -> ' .. Util.fmt(drs.vTopOpen and drs.vTopOpen * 3.6, 0)
    .. ' km/h ; gain sans DRS ' .. Util.fmt(drs.gainNoDrs, 3) .. ' s, dont DRS ' .. Util.fmt(drs.share, 3) .. ' s', palette.pending)
end

-- Relais de course (§8.7) : tours, arrêts, carburant, usure, relais proposé, trafic.
local function raceLines(host, r, palette)
  local race = r.race
  local ui = host.ui
  wrapped(host, 'Course : ' .. race.laps .. ' tours (' .. race.lapsSource .. ') ; relais de ' .. race.stintLaps .. ' tours'
    .. (race.stops > 0 and (', ' .. race.stops .. ' arrêt(s) au stand (réservoir)') or ''),
    palette[race.assumed and 'pending' or 'available'])
  ui.textWrapped('Carburant : ' .. Util.fmt(race.fuelFrom, 0) .. ' -> ' .. Util.fmt(race.fuelStart, 0) .. ' L ('
    .. Util.fmt(race.fuelPerLap, 2) .. ' L/tour, source ' .. race.fuelSource .. ', marge ' .. Util.fmt(race.margin * 100, 0) .. ' %)')
  if race.fuelNote then wrapped(host, race.fuelNote, palette.pending) end
  wrapped(host, 'Usure : ' .. Util.fmt(race.kmPerLapF, 2) .. ' / ' .. Util.fmt(race.kmPerLapR, 2) .. ' km virtuels par tour (avant / '
    .. 'arrière, ' .. race.kmSource .. ') ; température des pneus : ' .. race.tyreTemp,
    palette[race.kmSource == 'mesure' and 'na' or 'pending'])
  local s = r.stintProposed
  if s then
    ui.textWrapped('Relais proposé : ' .. M.lapTime(s.total) .. ' au total, meilleur tour ' .. M.lapTime(s.best) .. ', dégradation '
      .. Util.fmt(s.degradationPct, 2) .. ' %/tour' .. (s.critical and (', tour critique ' .. s.critical) or ', aucun tour critique'))
    ui.textWrapped('Équilibre (1 = neutre) : ' .. Util.fmt(s.balanceFirst, 3) .. ' au premier tour -> ' .. Util.fmt(s.balanceLast, 3)
      .. ' au dernier (usure)')
  end
  ui.textWrapped('Trafic : ' .. Util.fmt(race.trafficFraction * 100, 0) .. ' % des tours (aspiration ×' .. Util.fmt(race.slipstream, 2)
    .. (race.drs and ', DRS dans ses zones (à confirmer, H8)' or '') .. ') ; effet sur le tour moyen ' .. Util.fmt(r.traffic, 3)
    .. ' s')
end

-- Carburant de la règle tour rapide.
local function qualiFuelLines(host, r, palette)
  local f = r.fuel
  host.ui.textWrapped('Carburant (règle tour rapide) : ' .. Util.fmt(f.from, 0) .. ' -> ' .. Util.fmt(f.liters, 0)
    .. ' L (' .. Util.fmt(f.perLap, 2) .. ' L/tour, source ' .. f.source .. ')')
  if f.source ~= 'CSP' then
    wrapped(host, 'Consommation estimée par le modèle (marge de ' .. Util.fmt(Config.K.qualiFuelMarginModel * 100, 0)
      .. ' %) : après un tour en piste, relancer la découverte pour utiliser la mesure du jeu.', palette.pending)
  end
end

-- Piste mouillée (D16 amendé le 21/10/2026, décision de Vincent) : conditions retenues, hypothèses du modèle,
-- règle des aides (avant -> après, ou la raison de ne rien changer).
local AID_NAMES = { TRACTION_CONTROL = 'Antipatinage', ABS = 'ABS' }
local function wetLines(host, q, r, palette)
  local c = q.conditions or {}
  host.ui.textWrapped('Piste : humidité ' .. Util.fmt((c.wetness or 0) * 100, 0) .. ' %, eau ' .. Util.fmt((c.water or 0) * 100, 0)
    .. ' % ; eau sous les pneus ' .. (Util.isFinite(c.waterMm) and (Util.fmt(c.waterMm, 2) .. ' mm, mesurée sur le dernier tour')
    or (Util.fmt((c.water or 0) * Config.K.wetWaterDepthMax, 1) .. ' mm, supposée (H26)')))
  wrapped(host, 'Modèle pluie à confirmer (H25 à H28) : film d\'eau selon le pneu, aquaplanage au-delà de ce que les rainures '
    .. 'évacuent (en v²), pneus plus froids ; vos tours mouillés le calibrent (calibration pluie, à part du sec).', palette.pending)
  for _, section in ipairs({ 'TRACTION_CONTROL', 'ABS' }) do
    local e = r.aids and r.aids[section]
    if e then
      local text = AID_NAMES[section] .. ' : '
      if e.to then
        text = text .. tostring(e.from) .. ' -> ' .. e.to .. ' (règle pluie'
          .. ((e.slipFrom or e.slipTo) and (', glissement admis ' .. Util.fmt(e.slipFrom, 2) .. ' -> ' .. Util.fmt(e.slipTo, 2)) or '')
          .. ')' .. (e.assistNote and (' ; ' .. e.assistNote) or '')
      else
        text = text .. tostring(e.note)
      end
      wrapped(host, text, e.assistNote and palette.pending or nil)
    end
  end
end

-- Sections de détail d'un résultat, repliées (la course ouvre son relais).
local function resultDetails(host, kind, q, r, palette)
  if q.conditions and q.conditions.bucket == 'pluie' then
    section(host, 'Pluie : composé ' .. tostring(r.compound and r.compound.name or '—'), kind .. '_wet', true, function()
      wetLines(host, q, r, palette)
    end)
  end
  if kind == 'race' then
    local race = r.race
    section(host, 'Relais : ' .. race.laps .. ' tours, ' .. race.stops .. ' arrêt(s), départ ' .. Util.fmt(race.fuelStart, 0) .. ' L',
      'race_stint', true, function() raceLines(host, r, palette) end)
  elseif r.fuel and r.fuel.liters then
    section(host, 'Carburant : ' .. Util.fmt(r.fuel.liters, 0) .. ' L', 'quali_fuel', false, function()
      qualiFuelLines(host, r, palette)
    end)
  end
  if r.compound or r.tyres then
    local name = r.compound and r.compound.name
    section(host, 'Pneus et composé' .. (name and (' : ' .. tostring(name)) or ''), kind .. '_tyres', false, function()
      compoundLines(host, r, palette)
      tyreLines(host, r, palette)
    end)
  end
  if r.ers and r.ers.proposed then
    section(host, 'ERS', kind .. '_ers', false, function() ersLines(host, r, palette) end)
  end
  if r.drs then
    section(host, 'DRS', kind .. '_drs', false, function() drsLines(host, r, palette) end)
  end
end

-- Réglages proposés (valeur actuelle › proposée, crans, gain), triés par gain ; explication au survol.
local function changesTable(host, kind, r, palette)
  local ui = host.ui
  if #r.changes == 0 and r.refined == 0 then
    wrapped(host, 'Recherche incomplète : aucun optimum raffiné. Augmenter la tranche de calcul ou le budget, puis relancer.',
      palette.pending)
    return
  elseif #r.changes == 0 then
    ui.text('Aucun réglage à changer : le setup actuel est le meilleur trouvé.')
    return
  end
  local okW, avail = Util.call(ui.availableSpaceX)
  local narrow = okW and Util.isFinite(avail) and avail < K.uiNarrow
  local help = 'Survoler un réglage : son explication, tirée de la simulation.'
  local rows = { narrow and { head(palette, 'Réglage', help), head(palette, 'Actuel › proposé'), head(palette, 'Gain (s)') }
    or { head(palette, 'Réglage', help), head(palette, 'Actuel'), head(palette, 'Proposé'), head(palette, 'Crans'),
      head(palette, 'Gain (s)') } }
  for _, c in ipairs(r.changes) do
    local from, to = M.physicalText(c.var.kind, c.from), M.physicalText(c.var.kind, c.to)
    local clicks = (c.clicks > 0 and '+' or '') .. c.clicks
    local why = c.explanation
    if c.atBound then why = (why and (why .. '\n') or '') .. 'À confirmer : optimum en limite de la plage explorée.' end
    local label = { text = c.var.label, color = c.atBound and palette.pending or nil, tip = why }
    local gain = c.atBound and { text = 'à confirmer', color = palette.pending, tip = 'Optimum en limite de la plage explorée.' }
      or { text = Util.fmt(c.contribution, 3), color = c.contribution > 0 and palette.available or palette.muted }
    if narrow then
      rows[#rows + 1] = { label, from .. ' › ' .. to .. ' (' .. clicks .. ')', gain }
    else
      rows[#rows + 1] = { label, from, { text = to, color = palette.available }, clicks, gain }
    end
  end
  grid(host, 'changes_' .. kind, narrow and { 0.44, 0.38, 0.18 } or { 0.34, 0.19, 0.19, 0.12, 0.16 }, rows)
end

-- ---------------------------------------------------------------------------
-- Enregistrement, chargement, validation
-- ---------------------------------------------------------------------------

local KIND = {
  quali = {
    name = 'tour rapide', intro = 'Tour rapide : essai, journée circuit, hotlap, time attack, qualification',
    compute = 'Calculer le setup tour rapide', cancel = 'Annuler le calcul', rediscover = 'Relancer la découverte',
    saveLabel = 'Enregistrer le setup tour rapide', validate = 'Mesurer le gain réel', budgetKey = 'optBudgetEvalsQ',
    unit = ' évaluations',
    target = 'computeTargetQ', lapsPerEval = 1,
  },
  race = {
    name = 'course', intro = 'Course : relais, carburant, usure, trafic',
    compute = 'Calculer le setup course', cancel = 'Annuler le calcul course', rediscover = 'Relancer la découverte (course)',
    saveLabel = 'Enregistrer le setup course', validate = 'Mesurer le gain réel (course)', budgetKey = 'optBudgetEvalsC',
    unit = ' relais',
    target = 'computeTargetC', lapsPerEval = Config.K.raceMaxSamples + 1,
  },
}

-- Issue du dernier enregistrement de ce calcul (nom du fichier, ou raison du refus), sous le bouton : le
-- message du bandeau n'est plus visible quand la fenêtre défile (constat de Vincent du 21/10/2026).
local function saveLine(host, q, palette)
  local s = q.saveStatus
  if s then wrapped(host, s.text, palette[s.ok and 'available' or 'unavailable']) end
end

-- Chargement du setup enregistré dans la voiture (D8 amendé le 20/10/2026) : deux clics, au stand,
-- menu de setup ouvert ; la colle contrôle les gardes et fait la copie de sauvegarde. Constat de Vincent du
-- 22/10/2026 (« on ne voit pas le bouton de chargement ») : bouton en vert, pleine largeur, l'état du stand
-- à côté (au stand, arrêtée, menu de setup ouvert), le dernier refus dessous ; une fois armé, la
-- confirmation à sa place, en vert, avec le temps restant (loadFollow).
local function loadLabel(app, kind)
  if app.loadArm and app.loadArm.kind == kind then return 'Chargement armé…' end
  return 'Charger le setup ' .. KIND[kind].name .. ' dans la voiture'
end

-- État du stand et dernier refus du chargement de ce genre.
local function loadReadiness(host, app, kind, palette)
  local r = app.loadReady
  if r then
    local ready = r.pit and r.stopped and r.menu
    withFont(host, 'Small', function()
      colored(host, ready and 'Prêt à charger :' or 'Pour charger :', palette[ready and 'available' or 'pending'])
      for _, item in ipairs({ { 'au stand', r.pit }, { 'voiture arrêtée', r.stopped }, { 'menu de setup ouvert', r.menu } }) do
        local text = item[1] .. (item[2] and ' (oui)' or ' (non)')
        nextInline(host, text)
        colored(host, text, palette[item[2] and 'available' or 'pending'])
      end
    end)
  end
  local note = app.loadNote
  if note and note.kind == kind then wrapped(host, note.text, palette.unavailable) end
end

local function loadButton(host, app, intents, kind, palette)
  if not (app.saved and app.saved[kind]) then return end
  if app.loadArm and app.loadArm.kind == kind then return end
  small(host, 'À charger : ' .. tostring(app.saved[kind].name), palette.text)
  loadReadiness(host, app, kind, palette)
  if actionButton(host, app.ui, palette, loadLabel(app, kind), 'go', true) then intents.loadArm = kind end
  tip(host, 'Au stand, voiture arrêtée, menu de setup ouvert : deux clics, après une copie de sauvegarde du setup en cours.')
end

-- where : endroit qui affiche la confirmation et le suivi (« result » : résultat ou affinage ; « memory » :
-- mémoire du circuit), celui où le chargement a été demandé (un seul bouton de confirmation par onglet).
local function loadFollow(host, app, intents, kind, palette, where)
  if not (app.saved and app.saved[kind]) then return end
  if (where or 'result') ~= (app.loadWhere or 'result') then return end
  local arm = app.loadArm
  if arm and arm.kind == kind then
    wrapped(host, 'Remplace le setup en cours dans la voiture, modifications non enregistrées comprises ; une copie du '
      .. 'setup actuel est enregistrée juste avant.', palette.pending)
    if actionButton(host, app.ui, palette, 'Confirmer le chargement (' .. KIND[kind].name .. ')', 'go', true) then
      intents.loadConfirm = kind
    end
    local left = (arm.untilClock and app.clock and (arm.untilClock - app.clock())) or ((arm.untilNow or app.now) - app.now)
    small(host, 'Il reste ' .. Util.fmt(math.max(0, left), 0) .. ' s pour confirmer.', palette.pending)
    if host.ui.button('Annuler le chargement (' .. KIND[kind].name .. ')') then intents.loadDisarm = true end
  elseif where == 'memory' then
    local note = app.loadNote
    if note and note.kind == kind then wrapped(host, note.text, palette.unavailable) end
  end
  local check, test = app.loadCheck, app.loadTest
  if check and check.kind == kind then
    small(host, 'Chargement demandé : vérification du setup en cours…', palette.muted)
  elseif test and test.kind == kind then
    wrapped(host, test.ok and ('Chargé et vérifié dans la voiture : ' .. tostring(test.path))
      or ('Dernier chargement : ' .. tostring(test.reason)), palette[test.ok and 'available' or 'pending'])
  end
end

-- Verdict d'une validation en jeu (§14.1) : conforme sous la tolérance, sinon écart à corriger.
function M.validationText(v)
  if v == nil then return nil end
  if v.state == 'running' then return 'Mesure du gain réel en cours…', 'na' end
  if v.state == 'failed' then return 'Mesure du gain réel impossible : ' .. tostring(v.error), 'unavailable' end
  if v.state ~= 'done' then return nil end
  local numbers = 'gain prévu ' .. Util.fmt(v.predicted, 3) .. ' s, mesuré ' .. Util.fmt(v.measured, 3) .. ' s'
  if v.conforming then
    return 'Validé en jeu : ' .. numbers .. ' (conforme à ' .. Util.fmt(v.tolerance, 2) .. ' s près)', 'available'
  end
  return 'Écart en jeu : ' .. numbers .. ' (au-delà de ' .. Util.fmt(v.tolerance, 2) .. ' s) : recalibrer (onglet Mesure), '
    .. 'puis recalculer le setup', 'pending'
end

-- Boutons d'un résultat : enregistrer (en couleur tant que ce résultat n'est pas enregistré), mesurer le gain
-- réel ; puis le chargement (en vert) ; issues en dessous. refineOwnsLoad : le chargement est dans la carte
-- d'affinage (un seul bouton).
local function actionsRow(host, app, intents, kind, q, palette, refineOwnsLoad)
  local ui = host.ui
  local spec = KIND[kind]
  local saved = app.saved and app.saved[kind]
  local savedHere = q.saved and q.saved.ok and saved and saved.name == q.saved.name
  if actionButton(host, app.ui, palette, spec.saveLabel, (not savedHere and not refineOwnsLoad) and 'primary' or nil, false) then
    intents[kind .. 'Save'] = true
  end
  tip(host, 'Nouveau fichier à chaque clic (nom choisi, sinon …_AAAA-MM-JJ_HHhMMmSSs.ini), autant de fois que voulu ; '
    .. 'le setup actuel n\'est jamais modifié.')
  nextInline(host, spec.validate)
  if ui.button(spec.validate) then intents.validate = kind end
  tip(host, 'Gain réel contre gain prévu (§14.1) : un tour propre avec le setup d\'origine, puis avec le setup proposé chargé.')
  saveLine(host, q, palette)
  if not refineOwnsLoad then
    loadButton(host, app, intents, kind, palette)
    loadFollow(host, app, intents, kind, palette)
  end
  local text, color = M.validationText(app.validations and app.validations[kind])
  if text then wrapped(host, text, palette[color]) end
end

-- Icône de cadenas avant l'élément suivant (si CSP la fournit).
local function padlock(host, locked)
  local ui = host.ui
  local icon = Util.get(Util.get(ui, 'Icons'), locked and 'Padlock' or 'PadlockUnlocked')
  if icon == nil then return end
  if Util.call(ui.icon, icon, K.uiIconSize) then ui.sameLine() end
end

-- ---------------------------------------------------------------------------
-- Affinage (demande de Vincent du 21/10/2026)
-- ---------------------------------------------------------------------------

-- Étapes d'une version, faites en vert, la suivante en bleu (décision de Vincent du 22/10/2026 : « qu'on
-- comprenne mieux comment ça fonctionne »).
local STEPS = { 'Proposée', 'Validée (enregistrée)', 'Chargée au stand', 'Roulée' }
local function stepsLine(host, palette, reached)
  withFont(host, 'Small', function()
    for i, label in ipairs(STEPS) do
      local text = i .. '. ' .. label
      if i > 1 then nextInline(host, text) end
      colored(host, text, palette[i <= reached and 'available' or (i == reached + 1 and 'accent' or 'muted')])
    end
  end)
end

-- Vos temps : « 1:58.432 (4 tours) » (moyenne en course), ou « — ».
local function realText(stats, kind)
  local t = realTime(stats, kind)
  if t == nil then return '—' end
  return M.lapTime(t) .. ' (' .. (kind == 'race' and 'moy. ' or '') .. stats.count .. ' tour' .. (stats.count > 1 and 's' or '') .. ')'
end

-- Une version de l'affinage. En attente (rien d'enregistré avant sa validation) : gain prévu, objectif estimé
-- sur vos temps, réglages, Valider en couleur. Validée : à charger (étape suivante), puis vos temps avec elle
-- contre ceux d'avant ; plus lente en réalité : Écarter en rouge. suffix : libellés de la version en piste
-- quand ce n'est pas la dernière (identifiants ImGui uniques).
local function versionBlock(host, app, intents, r, e, palette, suffix, kind)
  local ui = host.ui
  local v = 'v' .. e.version
  local driven = r.driven == e.version
  local mine, before = realLaps(app, e.family, e.bucket), realLaps(app, e.originFamily, e.bucket)
  local tMine, tBefore = realTime(mine, kind), realTime(before, kind)
  if e.status == 'écartée' then
    small(host, v .. ' non gardée : pas reproposée.' .. (driven and ' Encore dans la voiture : charger la référence au stand.' or ''),
      palette[driven and 'pending' or 'muted'])
    return
  end
  local verdict = nil
  if e.status == nil then
    stepsLine(host, palette, 1)
    wrapped(host, v .. ' prête : gain prévu ' .. Util.fmt(e.gain, 3) .. ' s'
      .. (tBefore and (' ; objectif estimé ' .. M.lapTime(tBefore - e.gain) .. ' (votre ' .. M.lapTime(tBefore)
        .. ' moins le gain prévu)') or ' ; roulez un tour propre pour un objectif sur vos temps')
      .. (e.file and (' — déjà enregistrée : ' .. e.file) or ''), palette.accent)
    small(host, (e.updates or 0) > 0 and ('Mise à jour ' .. e.updates .. ' fois avec vos tours ; la suivante au prochain tour propre.')
      or 'Mise à jour au prochain tour propre, avec les données de ce tour.', palette.muted)
    if e.changeList then
      section(host, 'Réglages de ' .. v, 'version_' .. kind .. '_' .. e.version, true, function()
        changesTable(host, kind .. '_version', { changes = e.changeList, refined = e.refined or 1 }, palette)
      end)
    end
    small(host, 'Étape suivante : Valider (le fichier est enregistré), puis le charger au stand.', palette.accent)
    if actionButton(host, app.ui, palette, 'Valider ' .. v .. suffix, 'primary', true) then
      intents.refineJudge = { version = e.version, verdict = 'valider' }
    end
    tip(host, 'Enregistre le fichier (nom choisi « _v' .. e.version .. ' », sinon daté) et en fait le setup de référence de '
      .. 'cette séance, gardé en mémoire pour ce circuit ; au stand, « Charger » pour l\'essayer.')
  else
    stepsLine(host, palette, driven and ((mine and mine.count > 0) and 4 or 3) or 2)
    wrapped(host, v .. ' : ' .. tostring(e.file) .. ' — ' .. e.status .. (driven and ' (en piste)' or ''),
      palette[driven and 'available' or 'text'])
    if driven or tMine then
      local line = 'Vos temps : ' .. v .. ' ' .. realText(mine, kind) .. ' ; avant ' .. realText(before, kind)
      if tMine and tBefore then
        local diff = tBefore - tMine
        line = line .. ' ; gain réel ' .. gainText(diff) .. ' (prévu ' .. gainText(e.gain) .. ')'
        if mine.count >= 2 and before.count >= 2 and math.abs(diff) > K.validateTolAbs then
          verdict = diff > 0 and 'faster' or 'slower'
        end
      end
      wrapped(host, line, palette[verdict == 'slower' and 'unavailable' or (verdict == 'faster' and 'available' or 'muted')])
      if verdict == 'slower' then
        wrapped(host, v .. ' est plus lente en réalité que votre setup d\'avant : ne pas la garder (Recommencer) ?',
          palette.unavailable)
      end
    end
    if not driven then small(host, 'Étape suivante : la charger au stand (bouton vert ci-dessous).', palette.accent) end
  end
  -- Recommencer (décision de Vincent du 22/10/2026, plus parlant qu'« Écarter ») : ne pas garder cette version,
  -- ne pas la réutiliser ; validée puis essayée : la référence d'avant revient (son fichier reste, D8)
  local lock = 'Figer ' .. v .. suffix .. ' (cadenas)'
  local no = 'Recommencer (ne pas garder ' .. v .. ')' .. suffix
  if actionButton(host, app.ui, palette, no, verdict == 'slower' and 'danger' or nil, false) then
    intents.refineJudge = { version = e.version, verdict = 'écarter' }
  end
  tip(host, e.status == nil and ('Cette version n\'est ni gardée ni réutilisée (rien n\'est enregistré) ; SetupLab repart de '
    .. 'votre setup actuel et propose autre chose avec vos prochains tours.')
    or ('Cette version n\'est plus réutilisée : la référence d\'avant redevient le setup à charger ; son fichier reste '
      .. '(rien n\'est effacé).'))
  nextInline(host, lock)
  padlock(host, true)
  if ui.button(lock) then intents.refineLock = e.version end
  tip(host, 'Setup validé et verrouillé : gardé en mémoire pour ce circuit, cette séance et cet état de piste, proposé à '
    .. 'chaque visite ; l\'affinage automatique s\'arrête. Déverrouillable (Mémoire du circuit).')
end

-- Carte du mode affinage : phase et raison d'attente, dernière version et son chargement au stand,
-- historique (prévu, roulé). Renvoie vrai si la carte affiche le chargement du genre (un seul bouton
-- « Charger » par onglet : identifiant ImGui unique).
local function refineCard(host, app, intents, kind, palette)
  local r = app.refine
  if not (r and r.kind == kind) then return false end
  local ui = host.ui
  local name = KIND[kind].name
  card(host, app.ui, palette[r.active and 'accent' or 'na'], function()
    colored(host, 'Affinage ' .. name .. (r.active and '' or ' (arrêté)') .. (r.version > 0 and (' — v' .. r.version) or ''),
      palette[r.active and 'accent' or 'na'])
    tip(host, 'Un calcul ' .. (app.settings.refineLaps > 1 and ('tous les ' .. app.settings.refineLaps .. ' tours propres')
      or 'à chaque tour propre') .. ' ; chaque setup proposé est annoncé à l\'écran ; rien n\'est enregistré avant « Valider » ; '
      .. 'le charger ensuite au stand pour l\'essayer ; jusqu\'à l\'arrêt.')
    -- version en piste (si ce n'est pas la dernière) et dernière version : à valider, écarter ou figer, puis à
    -- charger (décisions de Vincent du 21/10/2026 : « on valide ou on ne valide pas à chaque étape »)
    local last, inCar = nil, nil
    for _, e in ipairs(r.history) do
      if e.version and e.version == r.version then last = e end
      if e.version and r.driven and e.version == r.driven then inCar = e end
    end
    local pending = last and last.status == nil and last or nil
    if r.active then
      local phase
      if r.needsDiscovery then
        phase = 'Nouvelle découverte au stand, puis nouveau calcul.'
      elseif r.phase == 'calcul' then
        phase = (app.pendingComputes and app.pendingComputes[kind]) and 'Calcul en attente de la découverte…' or 'Calcul en cours…'
      elseif r.nextAt and app.now < r.nextAt then
        phase = 'Nouvel essai dans ' .. Util.fmt(r.nextAt - app.now, 0) .. ' s.'
      elseif r.due then
        phase = 'Nouveau calcul dès la fin des tâches en cours.'
      elseif pending then
        phase = 'v' .. pending.version .. ' attend votre avis ; nouvelle analyse ' .. (app.settings.refineLaps > 1
          and ('après ' .. app.settings.refineLaps .. ' tours propres (' .. r.laps .. ' / ' .. app.settings.refineLaps .. ').')
          or 'au prochain tour propre.')
      elseif app.settings.refineLaps > 1 then
        phase = 'Tours propres : ' .. r.laps .. ' / ' .. app.settings.refineLaps .. ' avant le prochain calcul.'
      else
        phase = 'Nouveau calcul au prochain tour propre (données nouvelles).'
      end
      small(host, phase, palette.muted)
      if r.waiting then wrapped(host, r.waiting, palette.pending) end
    end
    if inCar and inCar ~= last then versionBlock(host, app, intents, r, inCar, palette, ' (en piste)', kind) end
    if last then versionBlock(host, app, intents, r, last, palette, '', kind) end
    if r.active then
      loadButton(host, app, intents, kind, palette)
      loadFollow(host, app, intents, kind, palette)
    end
    if #r.history > 0 then
      -- vos temps d'abord (demande de Vincent du 22/10/2026) ; temps simulés au survol de la version
      local rows = { { head(palette, 'Version'),
        head(palette, 'Vos tours', kind == 'race' and 'Moyenne de vos tours valides avec cette version'
          or 'Votre meilleur tour valide avec cette version'),
        head(palette, 'Gain prévu'),
        head(palette, 'Gain réel', 'Vos temps avec le setup de départ du calcul, moins vos temps avec cette version'),
        head(palette, 'Avis', 'Validée, non gardée ou à juger') } }
      for i = #r.history, math.max(1, #r.history - K.uiHistoryRows + 1), -1 do
        local e = r.history[i]
        local mine = e.version and realLaps(app, e.family, e.bucket) or nil
        local before = e.version and realLaps(app, e.originFamily, e.bucket) or nil
        local tm, tb = realTime(mine, kind), realTime(before, kind)
        rows[#rows + 1] = {
          { text = e.version and ('v' .. e.version) or '—', color = e.version and palette.text or palette.muted,
            tip = (e.file or e.note or '') .. '\nTemps simulés par le modèle (calé sur vos tours) : départ '
              .. M.lapTime(e.timeCurrent) .. ', prévu ' .. M.lapTime(e.timeProposed) },
          { text = e.version and realText(mine, kind) or (e.note or '—'), color = tm and palette.text or palette.muted },
          { text = gainText(e.gain), color = e.gain > 0 and palette.available or palette.muted },
          { text = (tm and tb) and gainText(tb - tm) or '—',
            color = (tm and tb) and palette[(tb - tm) > 0 and 'available' or 'unavailable'] or palette.muted },
          { text = e.status == 'écartée' and 'non gardée' or e.status or (e.version and 'à juger' or (e.count and ('×' .. e.count)
            or '—')),
            color = e.status == 'validée' and palette.available or palette.muted },
        }
      end
      withFont(host, 'Small', function() grid(host, 'refine_' .. kind, { 0.15, 0.24, 0.18, 0.25, 0.18 }, rows) end)
    end
    if r.active then
      if ui.button('Arrêter l\'affinage (' .. name .. ')') then intents.refineStop = true end
      if app.auto then tip(host, 'SetupLab actif : l\'arrêt le met aussi en veille.') end
    elseif ui.button('Relancer l\'affinage (' .. name .. ')') then
      intents.refineStart = kind
    end
  end)
  return r.active
end

-- ---------------------------------------------------------------------------
-- Onglets Tour rapide et Course
-- ---------------------------------------------------------------------------

-- Lancement, attente, progression ou refus du calcul ; bouton d'affinage.
local function computeArea(host, app, intents, kind, palette)
  local ui = host.ui
  local spec = KIND[kind]
  local q = app[kind]
  local blocker = 'colle non prête'
  if app.qualiBlocker then blocker = app.qualiBlocker() end
  -- découverte en cours : le bouton reste, le calcul suivra la découverte
  if app.discoveryState == 'running' and not app.inert then blocker = nil end
  if app.pendingComputes and app.pendingComputes[kind] then
    wrapped(host, 'Calcul ' .. spec.name .. ' lancé dès la fin de la découverte…', palette.pending)
    if ui.button(spec.cancel) then intents[kind .. 'Cancel'] = true end
  elseif q and q.state == 'running' then
    local o = q.opt
    local fraction = Util.clamp(o.evaluations / math.max(1, q.budget), 0, 1)
    local size = vec(host, app.ui, 'bar')
    if size then size.x, size.y = -1, 0 end
    Util.call(ui.progressBar, fraction, size, o.phase .. ' : ' .. o.evaluations .. ' / ' .. q.budget)
    if ui.button(spec.cancel) then intents[kind .. 'Cancel'] = true end
    if o.currentJ and Util.isFinite(o.bestJ) then
      ui.sameLine()
      small(host, 'Meilleur gain provisoire : ' .. Util.fmt(o.currentJ - o.bestJ, 3) .. ' s (critère pénalisé)', palette.muted)
    end
  elseif blocker then
    wrapped(host, 'Calcul indisponible : ' .. blocker, palette.pending)
    if app.discoveryState == 'failed' and ui.button(spec.rediscover) then intents.rediscover = true end
  else
    local budget = app.settings[spec.budgetKey]
    if ui.button(spec.compute) then intents[kind .. 'Start'] = true end
    tip(host, 'Un calcul complet depuis le setup en cours (' .. budget .. spec.unit .. ').')
    if not (app.refine and app.refine.kind == kind) then
      local label = 'Affinage automatique (' .. spec.name .. ')'
      nextInline(host, label)
      if ui.button(label) then intents.refineStart = kind end
      tip(host, 'Calcule tout de suite, enregistre chaque setup amélioré tout seul, puis recalcule '
        .. (app.settings.refineLaps > 0 and ('tous les ' .. app.settings.refineLaps .. ' tour(s) propre(s) avec le même setup')
          or 'en continu (chaque tour roulé affine la calibration)') .. ', jusqu\'à l\'arrêt. Le chargement se fait au stand, '
        .. 'en deux clics.')
    end
    local estimate = M.estimateSeconds(app, budget, spec.lapsPerEval, kind)
    local text, long = M.durationText(estimate, Config.K[spec.target], M.slowFrames(app))
    small(host, budget .. spec.unit .. text, long and palette.pending or palette.muted)
  end
  if q and q.state == 'failed' then
    wrapped(host, 'Calcul en échec : ' .. tostring(q.error), palette.unavailable)
  elseif q and q.state == 'cancelled' then
    small(host, 'Calcul annulé.', palette.na)
  end
  if q and q.state == 'done' and q.stale then wrapped(host, q.stale, palette.pending) end
end

-- Chiffres clés d'un résultat ; la phrase complète au survol.
local function resultTiles(host, app, kind, q, r, palette)
  local gain = (r.timeCurrent or 0) - (r.timeProposed or 0)
  local pct = Util.fmt(math.abs(gain) / math.max(1, r.timeCurrent or 1) * 100, 2) .. ' %'
  local summary
  local pending = 0
  for _, c in ipairs(r.changes) do
    if c.atBound then pending = pending + math.max(0, c.contribution) end
  end
  if kind == 'race' then
    summary = 'Tour moyen du relais : actuel ' .. M.lapTime(r.timeCurrent) .. ' -> proposé ' .. M.lapTime(r.timeProposed)
      .. ' (' .. gainText(gain, ' par tour, ') .. pct .. ')'
  else
    summary = 'Tour prévu : actuel ' .. M.lapTime(r.timeCurrent) .. ' -> proposé ' .. M.lapTime(r.timeProposed)
      .. ' (' .. gainText(gain, ', ') .. pct
      .. (pending > 0 and (', dont ' .. Util.fmt(pending, 3) .. ' s sur des réglages à confirmer') or '') .. ')'
  end
  -- vos temps d'abord (demande de Vincent du 22/10/2026) ; les temps simulés au survol
  local stats = realLaps(app, q.discovery and q.discovery.family, q.conditions and q.conditions.bucket or 'sec')
  local mine = realTime(stats, kind)
  local simulated = 'Temps simulés par le modèle (calé sur vos tours) : ' .. summary
  tiles(host, app.ui, {
    { label = kind == 'race' and 'Votre tour moyen' or 'Votre meilleur tour', value = mine and M.lapTime(mine) or '—',
      tip = (mine and ('Avec le setup actuel : ' .. stats.count .. ' tour(s) valide(s).') or 'Roulez un tour propre avec ce setup.')
        .. '\n' .. simulated },
    { label = 'Objectif estimé', value = mine and M.lapTime(mine - gain) or '—', color = palette.available,
      tip = 'Votre temps moins le gain prévu.\n' .. simulated },
    { label = (kind == 'race' and 'Gain par tour · ' or 'Gain · ') .. pct, value = gainText(gain), tip = summary,
      color = palette[gain > 0 and 'available' or 'na'] },
    { label = 'Modèle', value = r.calibrated and 'calibré' or 'non calibré', color = palette[r.calibrated and 'available' or 'pending'],
      tip = r.calibrated and 'Modèle calibré.' or 'Confiance basse : modèle non calibré (§9). Gains indicatifs, à vérifier en piste.' },
  }, palette)
  if pending > 0 then
    small(host, 'Dont ' .. Util.fmt(pending, 3) .. ' s sur des réglages à confirmer (optimum en limite de la plage explorée).',
      palette.pending)
  end
end

-- Alertes d'un résultat (une ligne chacune, en couleur, toujours visibles).
local function resultWarnings(host, kind, q, r, palette)
  if q.conditions and q.conditions.bucket == 'pluie' then
    small(host, 'Setup pluie : composé ' .. tostring(r.compound and r.compound.name or '—') .. ' ; modèle pluie à confirmer '
      .. '(H25 à H28), détail dans la section Pluie.', palette.pending)
  end
  if r.fallback then wrapped(host, r.fallback, palette.pending) end
  for _, axle in ipairs({ 'F', 'R' }) do
    local e = r.tyres and r.tyres[axle]
    if e and e.state == 'surchauffe' then
      wrapped(host, (axle == 'F' and 'Pneus avant' or 'Pneus arrière') .. ' en surchauffe : pression à froid jamais abaissée '
        .. '(une pression plus basse chauffe davantage, à confirmer) ; surveiller la température au prochain relais.',
        palette.unavailable)
    end
  end
  if not r.calibrated then
    small(host, 'Confiance basse : modèle non calibré (§9). Gains indicatifs, à vérifier en piste.', palette.pending)
  end
  if r.minHeightWarning then wrapped(host, r.minHeightWarning, palette.unavailable) end
  if kind == 'quali' and r.absActive == false then
    wrapped(host, 'ABS coupé : risque de blocage au freinage pris en compte (H15).', palette.pending)
  end
  if r.drs and r.drs.warning then wrapped(host, r.drs.warning, palette.unavailable) end
  if r.robustSkipped then
    wrapped(host, 'Robustesse non évaluée : budget trop petit (§10.2). Augmenter le budget pour la prendre en compte.',
      palette.pending)
  end
end

-- Couverture du setup (demande de Vincent du 21/10/2026 : « il faut qu'il agisse absolument sur tout ») :
-- réglages optimisés, ceux qui le deviennent après un tour valide (rugosité) ou au stand (repère de hauteur),
-- et les autres, conservés avec leur raison (au survol ; détail dans l'onglet Réglages).
local function coverageLine(host, q, palette)
  local space = q.discovery and q.discovery.space
  if space == nil then return end
  local rows = SetupSpace.statusRows(space)
  local optimized, later, kept = 0, {}, {}
  for _, row in ipairs(rows) do
    if row.status == 'optimisé' then
      optimized = optimized + 1
    elseif row.detail and row.detail:find('rugosité', 1, true) then
      later[#later + 1] = row.label .. ' (après un tour valide sur le sec)'
    elseif row.detail and row.detail:find('repère de hauteur', 1, true) then
      later[#later + 1] = row.label .. ' (repère à vérifier voiture arrêtée au stand)'
    else
      kept[#kept + 1] = row.label .. ' : ' .. tostring(row.detail)
    end
  end
  small(host, 'Réglages : ' .. optimized .. ' optimisés' .. (#later > 0 and (', ' .. #later .. ' à venir') or '') .. ', ' .. #kept
    .. ' conservés (raisons au survol, onglet Réglages)', #later > 0 and palette.pending or palette.muted)
  local lines = {}
  for _, text in ipairs(later) do lines[#lines + 1] = 'À venir — ' .. text end
  for _, text in ipairs(kept) do lines[#lines + 1] = 'Conservé — ' .. text end
  tip(host, table.concat(lines, '\n'))
end

-- Mise en page large (réglages à gauche, graphiques à droite, chacun défilant) ou étroite (empilée,
-- graphiques dans une section repliée).
local function panes(host, app, kind, left, right)
  local ui = host.ui
  local okW, avail = Util.call(ui.availableSpaceX)
  local size = vec(host, app.ui, 'pane')
  if okW and Util.isFinite(avail) and avail >= K.uiWide and ui.childWindow and size then
    local okS, space = Util.call(ui.availableSpace)
    local height = okS and space and Util.isFinite(space.y) and space.y or 0
    size.x, size.y = math.floor(avail * K.uiLeftShare), math.max(K.uiPaneMinHeight, height)
    ui.childWindow(kind .. '_left', size, false, 0, left)
    ui.sameLine()
    size.x = 0
    ui.childWindow(kind .. '_right', size, false, 0, right)
  else
    left()
    section(host, 'Graphiques', kind .. '_plots', false, right)
  end
end

-- Vos retouches gardées (décision de Vincent du 22/10/2026) : réglages modifiés à la main depuis le dernier
-- chargement par SetupLab, que les calculs ne changent plus ; « Libérer vos retouches » les rend au calcul.
local function pinsLine(host, app, intents, kind, palette)
  local pins = app.pins and app.pins[kind]
  if pins == nil or next(pins) == nil then return end
  local labels, seen = {}, {}
  local space = app.discovery and app.discovery.space
  for _, var in ipairs(space and space.vars or {}) do
    for _, member in ipairs(var.members) do
      if pins[member.name] and not seen[var.key] then
        seen[var.key] = true
        labels[#labels + 1] = var.label
      end
    end
  end
  if pins.TYRES then labels[#labels + 1] = 'composé de pneus' end
  if #labels == 0 then return end
  wrapped(host, 'Vos retouches gardées (' .. KIND[kind].name .. ') : ' .. table.concat(labels, ', ')
    .. ' — les calculs ne les changent plus.', palette.accent)
  local label = 'Libérer vos retouches (' .. KIND[kind].name .. ')'
  if host.ui.button(label) then intents.pinsClear = kind end
  tip(host, 'Réglages modifiés à la main depuis le dernier chargement par SetupLab : gardés à votre valeur. Les libérer : le '
    .. 'prochain calcul peut de nouveau tous les changer.')
end

-- Mémoire du circuit (décision de Vincent du 21/10/2026) : setup validé par séance et état de piste pour cette
-- voiture sur ce circuit ; chargeable au stand ; figé (cadenas) ou non.
local function memoryCard(host, app, intents, kind, palette)
  local list = {}
  for _, g in ipairs(Config.memoryGroups) do
    if g.kind == kind then
      for _, bucket in ipairs({ 'sec', 'pluie' }) do
        local m = app.memory and app.memory[g.key .. '|' .. bucket]
        if m then
          list[#list + 1] = { key = g.key .. '|' .. bucket, id = g.key .. '_' .. bucket, label = g.label, bucket = bucket, m = m }
        end
      end
    end
  end
  if #list == 0 then return end
  local ui = host.ui
  card(host, app.ui, palette.available, function()
    colored(host, 'Mémoire du circuit', palette.text)
    local loadable = false
    for _, e in ipairs(list) do loadable = loadable or e.m.text ~= nil end
    -- état du stand ici seulement si aucun autre bouton « Charger » n'est affiché dans l'onglet
    if loadable and not (app.saved and app.saved[kind]) then loadReadiness(host, app, '', palette) end
    tip(host, 'Setup validé pour cette voiture sur ce circuit (disposition comprise), par séance et état de piste. Figé : '
      .. 'l\'affinage automatique ne le change plus. Chargement au stand, menu de setup ouvert, en deux clics.')
    for _, e in ipairs(list) do
      local m = e.m
      if m.locked then padlock(host, true) end
      wrapped(host, e.label .. ' · ' .. e.bucket .. ' : ' .. m.file .. (m.version and (' (v' .. m.version .. ')') or '')
        .. (m.locked and ' — figé' or ' — validé') .. (m.problem and (' — ' .. m.problem) or ''),
        palette[m.problem and 'unavailable' or (m.locked and 'available' or 'text')])
      local lock = (m.locked and 'Déverrouiller' or 'Figer (cadenas)') .. '###memlock_' .. e.id
      if m.text then
        if actionButton(host, app.ui, palette, 'Charger###memload_' .. e.id, 'go', false) then intents.memoryLoad = e.key end
        tip(host, 'Au stand, voiture arrêtée, menu de setup ouvert : deux clics, après une copie de sauvegarde du setup en cours.')
        nextInline(host, lock)
      end
      if ui.button(lock) then intents.memoryLock = { key = e.key, locked = not m.locked } end
    end
    loadFollow(host, app, intents, kind, palette, 'memory')
  end)
end

-- Nom du setup (demande de Vincent du 21/10/2026 : « pouvoir le nommer directement ») : fichiers nommés
-- ainsi (versions de l'affinage : _v1, _v2…) ; changer le nom puis « Enregistrer » écrit le même setup sous
-- le nouveau nom (l'ancien fichier reste : aucun fichier n'est renommé ni effacé, D8).
local function nameRow(host, app, intents, kind, palette)
  local ui = host.ui
  if ui.inputText == nil then return end
  Util.call(ui.setNextItemWidth, -1)
  local current = app.names and app.names[kind] or ''
  -- libellé affiché dans le champ vide (ui.InputTextFlags.Placeholder)
  local ok, text, changed = Util.call(ui.inputText, 'Nom du setup (facultatif)###name_' .. kind, current, 0x400000)
  if ok and changed and type(text) == 'string' then intents.name = { kind = kind, text = text } end
  tip(host, 'Accents et espaces retirés du nom de fichier ; jamais d\'écrasement (-2, -3… si le nom existe). Changer le nom '
    .. 'puis « Enregistrer » : le même setup sous le nouveau nom (l\'ancien fichier reste). Sans nom : SetupLab_…_date_heure.ini.')
  local base = app.customName and app.customName(kind) or ''
  if base ~= '' then
    local r = app.refine
    local refining = r and r.active and r.kind == kind
    local n = refining and r.version or 0
    local last = refining and r.history[#r.history]
    if refining and not (last and last.version == r.version and last.status == nil) then n = r.version + 1 end
    small(host, 'Fichier : ' .. base .. (refining and ('_v' .. n .. '.ini, à la validation') or '.ini'), palette.muted)
  end
end

local function kindSection(host, app, intents, kind, palette)
  local spec = KIND[kind]
  local q = app[kind]
  local d = app.discovery
  small(host, spec.intro, palette.muted)
  local refineOwnsLoad = refineCard(host, app, intents, kind, palette)
  pinsLine(host, app, intents, kind, palette)
  memoryCard(host, app, intents, kind, palette)
  computeArea(host, app, intents, kind, palette)
  nameRow(host, app, intents, kind, palette)
  local r = q and q.state == 'done' and q.result or nil
  if r == nil then
    -- dernier setup enregistré : rappelé (§13), et chargeable quand le résultat n'est plus affiché
    local last = app.lastSaved and app.lastSaved[kind]
    if last and last.file then
      small(host, 'Dernier setup ' .. spec.name .. ' enregistré : ' .. last.file .. (last.gain and (' (gain prévu '
        .. Util.fmt(last.gain, 3) .. ' s' .. (kind == 'race' and ' par tour' or '') .. ')') or ''), palette.muted)
    end
    local saved = app.saved and app.saved[kind]
    if saved and not refineOwnsLoad then
      loadButton(host, app, intents, kind, palette)
      loadFollow(host, app, intents, kind, palette)
    end
    local sim = d and d.simCurrent
    if kind == 'quali' and sim and sim.time then
      local model = M.modelState(app)
      local mine = realTime(realLaps(app, d.family, app.wet and app.wet.state or 'sec'), kind)
      tiles(host, app.ui, {
        { label = 'Votre meilleur tour', value = mine and M.lapTime(mine) or '—',
          tip = (mine and 'Votre meilleur tour valide avec le setup actuel.' or 'Roulez un tour propre avec ce setup.')
            .. '\nTour simulé avec le setup actuel : ' .. M.lapTime(sim.time) .. ' ; vitesse maxi '
            .. Util.fmt(sim.vMax * 3.6, 0) .. ' km/h' },
        { label = 'Vitesse maxi', value = Util.fmt(sim.vMax * 3.6, 0) .. ' km/h' },
        { label = 'Modèle', value = model == 'non calibré (calibration disponible)' and 'calibration prête' or model,
          color = palette[model == 'calibré' and 'available' or 'pending'], tip = 'Modèle ' .. model .. '.' },
      }, palette)
      if sim.profile then
        section(host, 'Vitesse simulée', 'quali_current_plot', true, function()
          plotProfiles(host, app.ui, { { profile = sim.profile, color = palette.pending } }, palette)
        end)
      end
    end
    return
  end
  resultTiles(host, app, kind, q, r, palette)
  resultWarnings(host, kind, q, r, palette)
  panes(host, app, kind, function()
    changesTable(host, kind, r, palette)
    coverageLine(host, q, palette)
    if kind == 'quali' then
      small(host, 'Équilibre en virage (1 = neutre, < 1 sous-vireur) : ' .. Util.fmt(r.balanceCurrent, 3) .. ' -> '
        .. Util.fmt(r.balanceProposed, 3), palette.muted)
    end
    actionsRow(host, app, intents, kind, q, palette, refineOwnsLoad)
    resultDetails(host, kind, q, r, palette)
  end, function()
    resultPlots(host, app, r, palette)
  end)
end

-- ---------------------------------------------------------------------------
-- Onglet Mesure (§9.1 à §9.3 bis, §14.1)
-- ---------------------------------------------------------------------------

local FACTOR_LABELS = { mu = 'adhérence', power = 'puissance', drag = 'traînée', lift = 'appui', brake = 'freinage' }
local FACTOR_ORDER = { 'mu', 'power', 'drag', 'lift', 'brake' }

local function measureSection(host, app, intents, palette)
  local ui = host.ui
  local rec = app.recorder
  local d = app.discovery
  small(host, 'Mesure et calibration : tours enregistrés, calibration du modèle, validation en jeu', palette.muted)
  if app.storeNote then wrapped(host, app.storeNote, palette.pending) end
  local bucket = app.wet and app.wet.state or 'sec'
  local index = d and d.compoundIndex or -1
  local current = d and app.calibrations and app.calibrations[bucket == 'pluie' and (tostring(index) .. '#pluie') or index]
  if current and current.result and current.result.stored then
    small(host, 'Calibration reprise d\'une séance précédente (même voiture, circuit, disposition et composé'
      .. (bucket == 'pluie' and ', piste mouillée' or '') .. ').', palette.muted)
  end
  if rec == nil then return end
  local last = rec.laps.last
  local c = app.calibration
  local cr = c and (c.result or c.previous)
  local calText, calColor, calTip = '—', palette.na, 'Calibration : après un tour valide (automatique si réglée).'
  if c and c.state == 'running' then
    calText, calColor, calTip = 'en cours', palette.pending, 'Calibration en cours sur ' .. c.runs .. ' tour(s)…'
  elseif c and c.state == 'failed' then
    calText, calColor, calTip = 'en échec', palette.unavailable, 'Calibration en échec : ' .. tostring(c.error)
  elseif cr then
    calText, calColor = cr.usable and 'utilisable' or 'non utilisée', palette[cr.usable and 'available' or 'pending']
    calTip = cr.usable and 'Elle servira au prochain calcul de setup.' or tostring(cr.reason)
  end
  local own = d and bestLap(app, d.signature, bucket)
  tiles(host, app.ui, {
    { label = 'Dernier tour', value = last and M.lapTime(last.time) or '—',
      color = last and palette[last.valid and 'available' or 'pending'] or nil,
      tip = last and (last.valid and 'Tour valide.' or ('Rejeté : ' .. tostring(last.reason))) or nil },
    { label = 'Meilleur (setup actuel)', value = own and M.lapTime(own.time) or '—' },
    { label = 'Tours enregistrés', value = tostring(rec.finished or 0) },
    { label = 'Calibration', value = calText, color = calColor, tip = calTip },
  }, palette)
  if rec.state == 'enregistrement' then
    small(host, 'Enregistrement du tour en cours : ' .. rec.n .. ' points' .. (rec.invalid and (' (sera rejeté : '
      .. rec.invalid .. ')') or ''), rec.invalid and palette.pending or palette.muted)
  else
    small(host, 'Enregistrement : en attente du prochain passage de la ligne.', palette.muted)
  end
  if last and not last.valid then
    wrapped(host, 'Dernier tour : ' .. M.lapTime(last.time) .. ' — rejeté : ' .. tostring(last.reason), palette.pending)
  end
  for signature, known in pairs(app.knownSetups or {}) do
    for _, state in ipairs({ 'sec', 'pluie' }) do
      local best = bestLap(app, signature, state)
      if best then
        local line = 'Meilleur tour, ' .. tostring(known.label) .. (state == 'pluie' and ', piste mouillée' or '') .. ' : '
          .. M.lapTime(best.time)
        if known.predicted and state == 'sec' then line = line .. ' (prévu ' .. M.lapTime(known.predicted) .. ')' end
        ui.text(line)
      end
    end
  end
  -- validation du setup proposé (§14.1) : gain prévu contre gain mesuré, le prévu étant simulé dans les
  -- conditions mesurées de chaque tour (carburant, pneus, piste) par la dernière calibration ; sinon
  -- l'effet de la charge de carburant se confondrait avec celui du setup
  for _, kind in ipairs({ 'quali', 'race' }) do
    local originSignature = app.proposalOrigins and app.proposalOrigins[kind]
    local origin = originSignature and app.knownSetups[originSignature]
    local signature = app.proposals and app.proposals[kind]
    local proposed = signature and app.knownSetups[signature]
    local name = KIND[kind].name
    local v = app.validations and app.validations[kind]
    if proposed and v and v.state == 'done' then
      local text, color = M.validationText(v)
      wrapped(host, 'Setup ' .. name .. ' — ' .. text .. ' ; carburant ' .. Util.fmt(v.fuelO, 1) .. ' L contre '
        .. Util.fmt(v.fuelP, 1) .. ' L, pris en compte' .. (v.calibrated and '' or ' ; modèle non calibré'), palette[color])
    elseif proposed and origin and bestLap(app, signature, app.proposalBuckets and app.proposalBuckets[kind]) then
      small(host, 'Validation du setup ' .. name .. ' : il faut aussi un tour valide avec le setup d\'origine.', palette.muted)
    elseif proposed and origin then
      small(host, 'Pour valider le setup ' .. name .. ' : le charger dans le menu de setup, puis faire un tour propre (§14.1).',
        palette.muted)
    end
  end
  local mo = app.measureOnly
  if mo then
    ui.text('Mode mesure uniquement (§9.4) : données de la voiture illisibles, modèle estimé sur le tour.')
    if mo.state == 'running' then
      ui.text('Estimation en cours…')
    elseif mo.estimate then
      local e = mo.estimate
      ui.textWrapped('Estimé : puissance à la roue ' .. Util.fmt(e.power / 1000, 0) .. ' kW ; Cx·S ' .. Util.fmt(e.cdA, 2)
        .. ' m² ; adhérence ' .. Util.fmt(e.mu, 2) .. ' ; Cz·S ' .. Util.fmt(e.clA, 2) .. ' m²'
        .. (e.clAIdentified and '' or ' (à confirmer : virages à la limite sur une plage de vitesses trop étroite)') .. ' ; '
        .. #e.gearTotals .. ' rapports')
    end
    if mo.simTime then
      ui.text('Tour simulé ' .. M.lapTime(mo.simTime) .. ' contre ' .. M.lapTime(mo.lapTime) .. ' mesuré.')
    end
    if mo.reason then wrapped(host, 'Estimation : ' .. tostring(mo.reason), palette.pending) end
    ui.textWrapped('Sans les fichiers de la voiture, aucun réglage n\'est convertible : pas de calcul de setup (A18).')
  end
  if c and c.state == 'failed' then wrapped(host, 'Calibration en échec : ' .. tostring(c.error), palette.unavailable) end
  if cr then
    wrapped(host, cr.usable and 'Calibration utilisable : elle servira au prochain calcul de setup.' or
      ('Calibration non utilisée : ' .. tostring(cr.reason) .. '.'), palette[cr.usable and 'available' or 'pending'])
    section(host, 'Facteurs et écarts de la calibration', 'calibration_detail', false, function()
      local rows = { { head(palette, 'Facteur'), head(palette, 'Valeur'), head(palette, 'État') } }
      for _, key in ipairs(FACTOR_ORDER) do
        local state = cr.atBound[key] and 'en butée' or (cr.identified[key] and 'identifié' or 'non identifié')
        rows[#rows + 1] = { FACTOR_LABELS[key], Util.fmt(cr.factors[key], 3),
          { text = state, color = palette[cr.atBound[key] and 'pending' or (cr.identified[key] and 'available' or 'na')] } }
      end
      grid(host, 'factors', { 0.4, 0.25, 0.35 }, rows)
      for _, one in ipairs(cr.runs) do
        small(host, tostring(one.label) .. ' : écart de temps ' .. Util.fmt(one.timeError * 100, 2) .. ' %, profil de vitesse '
          .. Util.fmt(one.rms * 100, 1) .. ' % (seuils ' .. Util.fmt(Config.K.calibMaxTimeError * 100, 0) .. ' % et '
          .. Util.fmt(Config.K.calibMaxRms * 100, 0) .. ' %) ; modèle idéal '
          .. Util.fmt(one.measuredTime - one.idealTime, 2) .. ' s plus rapide que le tour réel', palette.muted)
      end
    end)
  end
  if last then
    if ui.button('Calibrer maintenant') then intents.calibrate = true end
    nextInline(host, 'Copier le tour enregistré')
    if ui.button('Copier le tour enregistré') then intents.copyLap = true end
    tip(host, 'Copie le tour (temps, profil, setup) dans le presse-papiers, à coller dans la conversation de développement.')
  end
end

-- ---------------------------------------------------------------------------
-- Onglet Réglages (§10.3, §11)
-- ---------------------------------------------------------------------------

-- Statut de chaque réglage du setup (§10.3) : optimisé ou conservé, la raison au survol.
local function settingsSection(host, app, palette)
  local d = app.discovery
  if not (d and d.space) then return end
  local rows = SetupSpace.statusRows(d.space)
  local optimized = 0
  for _, row in ipairs(rows) do
    if row.status == 'optimisé' then optimized = optimized + 1 end
  end
  section(host, 'Réglages du setup : ' .. optimized .. ' optimisés, ' .. (#rows - optimized) .. ' conservés', 'setup_status', false,
    function()
      local list = { { head(palette, 'Réglage', 'Survoler un réglage : la raison de son statut.'), head(palette, 'Sec'),
        head(palette, 'Pluie', 'Prise en compte sur piste mouillée : modélisé, règle, ou inchangé (raison au survol).') } }
      for _, row in ipairs(rows) do
        list[#list + 1] = {
          { text = row.label, tip = row.detail .. ' (' .. table.concat(row.names, ', ') .. ')' },
          { text = row.status, color = palette[row.status == 'optimisé' and 'available' or 'na'] },
          { text = row.wetShort or '—', tip = row.wet, color = palette[row.wetShort == 'modélisé' and 'available'
            or (row.wetShort == 'règle' and 'accent' or 'na')] },
        }
      end
      -- hors des crans du setup : composé de pneus et aides au pilotage
      list[#list + 1] = { 'Composé de pneus', { text = 'choisi', color = palette.available, tip = 'D18 : composés secs comparés' },
        { text = 'modélisé', color = palette.available, tip = 'Slicks, intermédiaires et pluie comparés par le modèle mouillé '
          .. '(H25 à H28) et la fenêtre de température mesurée ; jamais un pneu pluie d\'office sur le sec.' } }
      list[#list + 1] = { 'Aides (antipatinage, ABS)', { text = 'conservé', color = palette.na, tip = 'Aides au pilote, non modélisées.' },
        { text = 'règle', color = palette.accent, tip = 'Niveaux plus stricts de ' .. tostring(app.settings.wetAidLevels or 0)
          .. ' cran(s) (réglage « Pluie : niveaux d\'aide en plus ») ; sens lu dans la table de la voiture.' } }
      grid(host, 'setup_status_grid', { 0.44, 0.24, 0.32 }, list)
    end)
end

-- Réglages de l'app modifiables (§11) : curseurs et cases ; une modification devient une intention
-- (la colle valide, applique et enregistre).
M.EDITABLE = Config.EDITABLE

local function settingsEditor(host, app, intents)
  local ui = host.ui
  section(host, 'Réglages de l\'app (conservés d\'une séance à l\'autre)', 'app_settings', true, function()
    for _, key in ipairs(M.EDITABLE) do
      for _, def in ipairs(Config.settings) do
        if def.key == key then
          local value = app.settings[key]
          if def.kind == 'boolean' then
            if ui.checkbox(def.label, value) then intents.setting = { key = key, value = not value } end
          elseif ui.slider then
            local ok, nextValue, changed = Util.call(ui.slider, def.label, value, def.min, def.max,
              def.kind == 'integer' and '%.0f' or '%.2f', def.kind == 'integer' and true or 1)
            if ok and changed and nextValue ~= value then intents.setting = { key = key, value = nextValue } end
          end
        end
      end
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Bandeau et fenêtre principale
-- ---------------------------------------------------------------------------

-- Séance détectée et onglet à utiliser (décision de Vincent du 20/10/2026 : onglets par usage). AC ne
-- distingue pas une journée circuit d'un essai (séance d'essai avec voitures IA).
local SESSION_NAMES = { [1] = 'essai ou journée circuit', [2] = 'qualification', [3] = 'course', [4] = 'hotlap',
  [5] = 'time attack', [6] = 'drift', [7] = 'drag' }
function M.sessionLine(context)
  local name = context and SESSION_NAMES[context.sessionType]
  if name == nil then return nil end
  if context.sessionType == 3 then
    return 'Séance : course — onglet Course (relais) ; onglet Tour rapide pour la qualification'
  end
  if context.sessionType >= 6 then return 'Séance : ' .. name .. ' — calcul pensé pour le chrono : onglet Tour rapide' end
  return 'Séance : ' .. name .. ' — onglet Tour rapide'
end

-- Ligne d'état de « SetupLab actif » (décision de Vincent du 21/10/2026) et sa couleur.
function M.autoLine(app)
  if not app.auto then
    return 'En veille : les tours sont analysés ; cocher « SetupLab actif » pour l\'affinage automatique.', 'muted'
  end
  if app.inert then return 'Actif, en attente : ' .. tostring(app.inert), 'pending' end
  if app.discoveryState == 'failed' then
    return 'Actif, en attente : découverte en échec (' .. tostring(app.discoveryError) .. ').', 'unavailable'
  end
  if app.discoveryState ~= 'done' then return 'Actif : découverte en cours, l\'affinage suivra.', 'pending' end
  local kind = app.autoKind and app.autoKind() or 'quali'
  local group = app.memoryGroupOf and app.memoryGroupOf(kind) or 'essai'
  local bucket = app.wet and app.wet.state or 'sec'
  local label = group
  for _, g in ipairs(Config.memoryGroups) do
    if g.key == group then label = g.label end
  end
  local where = label .. ', ' .. bucket
  local m = app.memory and app.memory[group .. '|' .. bucket]
  if m and m.locked then
    return 'Actif : setup figé pour ' .. where .. ' (' .. m.file .. ') ; « Déverrouiller » pour reprendre l\'affinage.', 'available'
  end
  local r = app.refine
  if r and r.active and r.kind == kind then
    local pending = nil
    for _, e in ipairs(r.history) do
      if e.version and e.version == r.version and e.status == nil then pending = e end
    end
    if pending then
      return 'Actif : v' .. pending.version .. ' prête (' .. where .. ') — à valider ou recommencer.', 'accent'
    end
    local saved = app.saved and app.saved[kind]
    for _, e in ipairs(r.history) do
      if e.version and e.status == 'validée' and r.driven ~= e.version and saved and saved.signature == e.signature then
        return 'Actif : v' .. e.version .. ' validée (' .. where .. ') — à charger au stand.', 'accent'
      end
    end
    return 'Actif : affinage ' .. KIND[kind].name .. ' (' .. where .. ')' .. (r.version > 0 and (', v' .. r.version) or '') .. '.',
      'accent'
  end
  return 'Actif : affinage ' .. KIND[kind].name .. ' au démarrage…', 'pending'
end

-- Bandeau (§12.1) : voiture et circuit en titre, état, séance, source des données, confiance du modèle,
-- statut des calculs ; identifiants et version au survol du titre.
local function header(host, app, intents, palette)
  local d = app.discovery
  local title = {}
  if d and d.car then title[#title + 1] = tostring(d.car.name) end
  if d and d.trackFiles then title[#title + 1] = tostring(d.trackFiles.name) end
  withFont(host, 'Title', function()
    colored(host, #title > 0 and table.concat(title, '  ·  ') or Config.appName, palette.text)
  end)
  tip(host, Config.appName .. ' ' .. Config.version .. ' — jalon ' .. Config.milestone
    .. (d and d.car and ('\nVoiture : ' .. tostring(d.car.id)) or '')
    .. (d and d.trackFiles and ('\nCircuit : ' .. tostring(d.trackFiles.fullId)) or ''))
  -- SetupLab actif (décision de Vincent du 21/10/2026 : « on l'ouvre, on l'active, on roule »)
  if host.ui.checkbox('SetupLab actif', app.auto == true) then intents.autoToggle = true end
  tip(host, 'Actif : SetupLab affine tout seul le setup de la séance (tour rapide en essai, journée circuit, hotlap et '
    .. 'qualification ; course en course), enregistre chaque version améliorée et propose de la charger au stand ; à vous '
    .. 'de la valider, de recommencer ou de la figer. En veille : rien n\'est calculé ni enregistré tout seul. Pour ce '
    .. 'lancement d\'AC : jamais actif tout seul au démarrage.')
  local autoText, autoColor = M.autoLine(app)
  small(host, autoText, palette[autoColor])
  local status, kind = M.statusLine(app)
  small(host, '● ' .. status, palette[kind])
  local session = M.sessionLine(app.context)
  if session then small(host, session, palette.muted) end
  if d then
    local source = (d.carBase and d.carBaseMissing and #d.carBaseMissing == 0) and 'fichiers de la voiture'
      or (app.measureOnly and 'mesure uniquement (§9.4)' or 'données incomplètes')
    local function stateOf(q)
      if q == nil then return 'non lancé' end
      return ({ running = 'en cours', done = 'terminé', failed = 'en échec', cancelled = 'annulé' })[q.state] or q.state
    end
    small(host, 'Données : ' .. source .. ' ; modèle ' .. M.modelState(app) .. ' ; tour rapide ' .. stateOf(app.quali)
      .. ', course ' .. stateOf(app.race), palette.muted)
  end
end

function M.main(host, app, intents)
  local ui = host.ui
  local palette = colors(app.ui, host)
  header(host, app, intents, palette)
  if app.ui.message then wrapped(host, app.ui.message, palette.accent) end
  local tabs = {
    { 'Tour rapide', function() kindSection(host, app, intents, 'quali', palette) end },
    { 'Course', function() kindSection(host, app, intents, 'race', palette) end },
    { 'Mesure', function() measureSection(host, app, intents, palette) end },
    { 'Réglages', function()
      settingsSection(host, app, palette)
      settingsEditor(host, app, intents)
    end },
    { 'Capacités', function() M.capsSection(host, app, intents, palette) end },
  }
  -- onglets (§12.1) ; sans ui.tabBar, sections les unes sous les autres (une erreur dans un onglet n'est
  -- pas rattrapée ici : la colle la compte, sans redessiner les sections en double)
  if ui.tabBar and ui.tabItem then
    ui.tabBar('setuplab_tabs', function()
      for _, tab in ipairs(tabs) do ui.tabItem(tab[1], tab[2]) end
    end)
  else
    for _, tab in ipairs(tabs) do
      tab[2]()
      ui.separator()
    end
  end
end

-- Onglet Capacités : panneau du J0, rapport, test d'écriture.
function M.capsSection(host, app, intents, palette)
  local ui = host.ui
  local d = app.discovery
  if d and d.caps then
    local counts = Caps.countByStatus(d.caps)
    tiles(host, app.ui, {
      { label = 'Disponibles', value = tostring(counts.available), color = palette.available },
      { label = 'À confirmer', value = tostring(counts.pending), color = palette.pending },
      { label = 'Indisponibles', value = tostring(counts.unavailable), color = palette.unavailable },
      { label = 'Sans objet', value = tostring(counts.na), color = palette.na },
    }, palette)
    section(host, 'Détail des capacités', 'caps_detail', false, function()
      local rows = {}
      for _, entry in ipairs(d.caps.list) do
        rows[#rows + 1] = {
          { text = '● ' .. entry.label, color = palette[entry.status], tip = entry.detail ~= '' and entry.detail or nil },
          { text = Caps.STATUS_LABEL[entry.status], color = palette[entry.status] },
        }
      end
      grid(host, 'caps_grid', { 0.66, 0.34 }, rows)
    end)
  else
    small(host, 'Capacités : sondage en attente.', palette.muted)
  end
  if ui.button('Relancer la découverte') then intents.rediscover = true end
  nextInline(host, 'Copier le rapport J0')
  if ui.button('Copier le rapport J0') then intents.copyReport = true end
  tip(host, 'Le rapport J0 se colle tel quel dans la conversation de développement. À faire de préférence depuis l\'écran de '
    .. 'setup, voiture aux stands.')
  nextInline(host, 'Enregistrer une copie du setup actuel')
  if ui.button('Enregistrer une copie du setup actuel') then intents.saveCopy = true end
  tip(host, 'Test d\'écriture : un nouveau fichier, copie exacte du setup actuel, sans rien modifier ni écraser.')
  local test = app.writeTest
  if test then
    wrapped(host, test.ok and ('Test d\'écriture réussi : ' .. tostring(test.path))
      or ('Test d\'écriture en échec : ' .. tostring(test.reason)), palette[test.ok and 'available' or 'unavailable'])
  else
    small(host, 'Écriture non testée.', palette.muted)
  end
  small(host, Config.appName .. ' ' .. Config.version .. ' — jalon ' .. Config.milestone, palette.muted)
end

function M.debug(host, app)
  local ui = host.ui
  local s = app.scheduler.stats
  local p = app.perf
  ui.text('Horloge : ' .. (app.clock and 'QueryPerformanceCounter' or ('repli quota (' .. tostring(app.clockReason) .. ')'))
    .. ' ; boucle : ' .. tostring(app.updateSource or 'pas encore appelée'))
  local offset = app.utcOffset and app.utcOffset() or nil
  ui.text('Heure des noms de fichiers : ' .. (offset and ('locale (UTC' .. (offset >= 0 and '+' or '-')
    .. Util.fmt(math.abs(offset) / 3600, 2) .. ' h)') or ('UTC (' .. tostring(app.utcOffsetReason) .. ')')))
  ui.text('Ordonnanceur : ' .. s.slices .. ' tranches ; dernière ' .. Util.fmt(s.lastSliceMs, 3) .. ' ms ; max '
    .. Util.fmt(s.maxSliceMs, 3) .. ' ms ; au-delà de ' .. Config.K.sliceAlertMs .. ' ms : ' .. p.slowSlices
    .. ' ; unité max ' .. Util.fmt(s.maxUnitMs, 3) .. ' ms')
  ui.text('Tâches : ' .. s.completed .. ' terminées, ' .. s.failed .. ' en échec, ' .. s.cancelled .. ' annulées')
  ui.text('Coût de l\'app par frame : dernier ' .. Util.fmt(p.lastMs, 3) .. ' ms ; moyen ' .. Util.fmt(p.avgMs, 3)
    .. ' ms ; max ' .. Util.fmt(p.maxMs, 3) .. ' ms')
  ui.text('Garde de frame : ' .. p.guardSkips .. ' tranches sautées ; ' .. p.slowFrames .. ' tranches réduites (< '
    .. Config.K.fpsTarget .. ' images/s) ; erreurs ' .. p.errors)
  ui.text('Journal : ' .. app.log.count .. '/' .. app.log.capacity .. ' lignes ; ' .. app.log.dropped .. ' répétitions filtrées')
  ui.separator()
  local entries = Util.logEntries(app.log)
  for i = #entries, 1, -1 do
    local e = entries[i]
    ui.textWrapped(Util.fmt(e.t, 1) .. ' s  ' .. e.level .. '  ' .. e.code .. ' : ' .. e.text)
  end
end

return M
