-- SetupLab — pages « Racing 26 » (maquette de Vincent, canevas Design « SetupLab 2026 — Refonte UI » ; décision du
-- 03/11/2026 : « tout refaire, puis publier »). Mise en page des planches : en-tête fixe (logo, voiture et circuit, état,
-- langue, interrupteur, onglets), puis la page de l'onglet dans une fenêtre enfant qui défile : ligne d'état, message,
-- carte d'étape, panneaux. Dessin en coordonnées de page (origine : le curseur au début de la page), boutons invisibles
-- placés au curseur. Les données et les actions viennent des modèles de src/ui.lua (stepModel, versionModel…), les
-- mêmes que pour les contrôles ImGui (repli sans DWrite) : mêmes libellés, identifiants et intentions.
-- Largeur : deux colonnes à partir de K.uiDashWide px, tout empilé en dessous (planche « Fenêtre étroite »).
local Util = require('src/util')
local Config = require('src/config')
local L = require('src/i18n')
local Skin = require('src/skin')
local SetupSpace = require('src/setup_space')

local M = {}
local K = Config.K

-- contexte de l'image en cours (une seule fenêtre dessinée à la fois) et vec2 réutilisés (aucune allocation par image)
local X = { host = nil, ui = nil, S = nil, c = nil, app = nil, intents = nil, U = nil, ox = 0, oy = 0 }
local V = nil
local function vec(i, x, y)
  local p = V[i]
  p.x, p.y = x, y
  return p
end

-- ---------------------------------------------------------------------------
-- Texte : capitales (UTF-8), mesures en cache, dessin
-- ---------------------------------------------------------------------------

local UPPER = { ['é'] = 'É', ['è'] = 'È', ['ê'] = 'Ê', ['ë'] = 'Ë', ['à'] = 'À', ['â'] = 'Â', ['ä'] = 'Ä', ['ç'] = 'Ç',
  ['ô'] = 'Ô', ['ö'] = 'Ö', ['û'] = 'Û', ['ù'] = 'Ù', ['ü'] = 'Ü', ['î'] = 'Î', ['ï'] = 'Ï', ['œ'] = 'Œ', ['æ'] = 'Æ' }
local upCache, upCount = {}, 0
-- capitales d'un texte déjà traduit (traduire d'abord : les clés du dictionnaire restent en casse normale)
local function up(s)
  local hit = upCache[s]
  if hit then return hit end
  local out = s:upper():gsub('[\195\197][\128-\191]', UPPER)
  if upCount > 2000 then upCache, upCount = {}, 0 end
  upCache[s], upCount = out, upCount + 1
  return out
end
M.upper = up

-- cache des mesures : rôle → taille → largeur de retour à la ligne (0 : aucune) → texte → { largeur, hauteur } ; aucune
-- chaîne construite par appel
local sizes, wcount = {}, 0
local function measure(role, size, s, wrap)
  local wk = (wrap and wrap > 0) and wrap or 0
  local bySize = sizes[role]
  if bySize == nil then
    bySize = {}
    sizes[role] = bySize
  end
  local byWrap = bySize[size]
  if byWrap == nil then
    byWrap = {}
    bySize[size] = byWrap
  end
  local byText = byWrap[wk]
  if byText == nil then
    byText = {}
    byWrap[wk] = byText
  end
  local hit = byText[s]
  if hit then return hit[1], hit[2] end
  local ok, m = pcall(X.S.call, role, X.ui.measureDWriteText, s, size, wk > 0 and wk or nil)
  local mw, mh = (ok and m and m.x) or (#s * size * 0.5), (ok and m and m.y) or (size * 1.25)
  if wcount > 6000 then sizes, wcount = {}, 0 end
  byText[s], wcount = { mw, mh }, wcount + 1
  return mw, mh
end
M.measure = measure

local function text(role, size, s, x, y, color)
  X.S.call(role, X.ui.dwriteDrawText, s, size, vec(1, X.ox + x, X.oy + y), color or X.c.light)
  return (measure(role, size, s))
end

-- texte qui revient à la ligne dans la largeur w ; renvoie sa hauteur
local function textBox(role, size, s, x, y, w, color, dry)
  local _, h = measure(role, size, s, w)
  if dry then return h end
  local clipped = X.ui.dwriteDrawTextClipped
  if clipped then
    local A = X.ui.Alignment or {}
    X.S.call(role, clipped, s, size, vec(1, X.ox + x, X.oy + y), vec(2, X.ox + x + w, X.oy + y + h + 2), A.Start or -1,
      A.Start or -1, true, color or X.c.light)
  else
    text(role, size, s, x, y, color)
  end
  return h
end

-- texte coupé avec « … » pour tenir dans w
local function fitted(role, size, s, w)
  if measure(role, size, s) <= w then return s end
  return X.S.fitIn(role, s, size, w)
end

-- ---------------------------------------------------------------------------
-- Formes
-- ---------------------------------------------------------------------------

local function rect(x1, y1, x2, y2, color)
  X.ui.drawRectFilled(vec(1, X.ox + x1, X.oy + y1), vec(2, X.ox + x2, X.oy + y2), color, 0)
end
local function panel(x1, y1, x2, y2, color)
  X.S.panel(X.ox + x1, X.oy + y1, X.ox + x2, X.oy + y2, color or X.c.panel)
end
local function slanted(x1, y1, x2, y2, slant, color)
  X.S.slanted(X.ox + x1, X.oy + y1, X.ox + x2, X.oy + y2, slant, color)
end
local function dot(x, y, r, color)
  Util.call(X.ui.drawCircleFilled, vec(1, X.ox + x, X.oy + y), r, color, 16)
end
local function line(x1, y1, x2, y2, color, thickness)
  if not Util.call(X.ui.drawLine, vec(1, X.ox + x1, X.oy + y1), vec(2, X.ox + x2, X.oy + y2), color, thickness or 1) then
    rect(math.min(x1, x2), math.min(y1, y2), math.max(x1, x2) + (thickness or 1), math.max(y1, y2) + (thickness or 1), color)
  end
end

-- libellé de section : Barlow Condensed 600, capitales, gris
local function lab(s, x, y, color, size)
  return text('label', size or 11, up(L.t(s)), x, y, color or X.c.grey)
end

-- ---------------------------------------------------------------------------
-- Boutons
-- ---------------------------------------------------------------------------

local function hovered()
  local ok, h = Util.call(X.ui.itemHovered)
  return ok and h == true
end
local function tip(s)
  if s and hovered() then X.U.tip(X.host, s) end
end
-- infobulle en deux textes traduits chacun (titre d'un bouton à icône, puis son explication)
local function tip2(title, s)
  if not hovered() then return end
  Util.call(X.ui.tooltip, function()
    local pushed = Util.call(X.ui.pushTextWrapPosition, K.uiTooltipWidth)
    X.ui.plainText(title)
    if s then X.ui.plainText(s) end
    if pushed then Util.call(X.ui.popTextWrapPosition) end
  end)
end

-- bouton incliné (parallélogramme 9 px) ; style : 'primary' (cyan, rayures), 'go', 'danger', 'outline', nil (contrôle) ;
-- align : 'left' (libellé à gauche, bouton principal) ; renvoie vrai au clic
local function button(label, x, y, w, h, style, size, align, shown)
  local visible, id = Skin.split(label)
  X.ui.setCursor(vec(1, X.ox + x, X.oy + y))
  local clicked = X.ui.invisibleButton('###' .. id, vec(3, w, h))
  local hot = hovered()
  local c = X.c
  local bg, fg = hot and c.controlHover or c.control, c.light
  if style == 'primary' then
    bg, fg = hot and c.blueHover or c.blue, c.dark
  elseif style == 'go' then
    bg, fg = hot and c.goHover or c.go, c.goText
  elseif style == 'danger' then
    bg, fg = hot and c.dangerHover or c.danger, c.dangerText
  elseif style == 'outline' then
    bg, fg = hot and c.raisedHover or c.select, c.blueSoft
  end
  slanted(x, y, x + w, y + h, 9, bg)
  if style == 'primary' and w >= 120 then
    -- rayures sombres sur la droite (kit Racing 26) : barres de 4 px inclinées, tous les 11 px
    local lean = math.floor(h * 0.53)
    for i = 0, 4 do
      local sx = x + w - 9 - lean - 4 - i * 11
      X.S.quad(X.ox + sx + lean, X.oy + y, X.ox + sx + lean + 4, X.oy + y, X.ox + sx + 4, X.oy + y + h, X.ox + sx, X.oy + y + h,
        c.stripe)
    end
  end
  size = size or 14
  local s = shown or up(L.t(visible))
  local room = w >= 60 and (w - 24) or (w - 6)
  if measure('button', size, s) > room and size > 11 then size = size - 2 end
  s = fitted('button', size, s, room)
  local tw, th = measure('button', size, s)
  local tx = align == 'left' and (x + 22) or (x + (w - tw) / 2)
  text('button', size, s, tx, y + (h - th) / 2, fg)
  return clicked
end

-- bouton carré à icône (Recommencer, Figer) : icône CSP si elle existe, sinon le libellé court
local function iconButton(label, icon, short, x, y, w, h)
  local _, id = Skin.split(label)
  X.ui.setCursor(vec(1, X.ox + x, X.oy + y))
  local clicked = X.ui.invisibleButton('###' .. id, vec(3, w, h))
  local hot = hovered()
  slanted(x, y, x + w, y + h, 9, hot and X.c.controlHover or X.c.control)
  local icons = Util.get(X.ui, 'Icons')
  local glyph = icons and Util.get(icons, icon)
  if glyph and X.ui.drawIcon then
    X.ui.drawIcon(glyph, vec(1, X.ox + x + w / 2 - 8, X.oy + y + h / 2 - 8), vec(2, X.ox + x + w / 2 + 8, X.oy + y + h / 2 + 8),
      X.c.light)
  else
    local tw, th = measure('button', 12, short)
    text('button', 12, short, x + (w - tw) / 2, y + (h - th) / 2, X.c.light)
  end
  return clicked
end

local function apply(intent)
  for k, value in pairs(intent) do X.intents[k] = value end
end

-- ---------------------------------------------------------------------------
-- Éléments du kit
-- ---------------------------------------------------------------------------

-- barre d'étapes : 4 segments inclinés (−20°) et leurs noms ; faites en vert, en cours en cyan, à venir en gris
local STEPS = { 'Départ', 'Rouler', 'Essayer', 'Valider' }
local function stepBar(x, y, w, step, done, labels)
  local gap = 4
  local each = (w - gap * 3) / 4
  for i = 1, 4 do
    local x1 = x + (i - 1) * (each + gap)
    local color = (done or (step and i < step)) and X.c.go or (step == i and X.c.blue or X.c.segmentOff)
    slanted(x1, y, x1 + each, y + 5, 2, color)
    if labels then
      local ink = (done or (step and i < step)) and X.c.go or (step == i and X.c.light or X.c.grey)
      lab(STEPS[i], x1, y + 9, ink, 10)
    end
  end
  return labels and 22 or 5
end

-- pastille de couleur et texte en mono (ligne d'état)
local function chip(x, y, color, name, value)
  dot(x + 3, y + 7, 3, color)
  local w = text('mono', 10.5, up(L.t(name)), x + 12, y, X.c.grey)
  local w2 = text('mono', 10.5, L.t(value), x + 12 + w + 6, y, X.c.light)
  return 12 + w + 6 + w2
end

-- barre de message : filet de 3 px à gauche, fond selon la sorte (info, attention, erreur) ; renvoie sa hauteur
local function messageBar(s, x, y, w, sort, dry)
  local c = X.c
  local bg, edge, ink = c.select, c.blue, c.light
  if sort == 'warn' then
    bg, edge, ink = c.warnBg, c.warn, c.warnText
  elseif sort == 'error' then
    bg, edge, ink = c.errBg, c.danger, c.badInk
  elseif sort == 'go' then
    bg, edge, ink = c.okBg, c.go, c.light
  end
  local h = math.max(24, textBox('text', 12, s, x + 12, y + 5, w - 22, ink, true) + 10)
  if dry then return h end
  rect(x, y, x + w, y + h, bg)
  rect(x, y, x + 3, y + h, edge)
  textBox('text', 12, s, x + 12, y + 5, w - 22, ink)
  return h
end

-- tuile de chrono : libellé, valeur en italique très gras
local function chrono(label, value, x, y, size, color)
  lab(label, x, y)
  text('display', size, value, x, y + 15, color or X.c.light)
end

-- ---------------------------------------------------------------------------
-- En-tête (planche « En-tête + onglets ») : 84 px en large, deux lignes en étroit
-- ---------------------------------------------------------------------------

local SESSION_SHORT = { [1] = 'Essai', [2] = 'Qualification', [3] = 'Course', [4] = 'Hotlap', [5] = 'Time attack', [6] = 'Drift',
  [7] = 'Drag' }

local function versionShort()
  local beta = tostring(Config.version):match('beta%.(.+)$')
  return beta and ('β' .. beta) or tostring(Config.version)
end

-- ligne de séance : « Qualification · sec · air 22 °C · piste 29 °C · grip 98 % »
local function sessionText(app)
  local d = app.discovery
  local parts = {}
  local name = app.context and SESSION_SHORT[app.context.sessionType]
  if name then parts[#parts + 1] = L.t(name) end
  parts[#parts + 1] = L.t(app.wet and app.wet.state == 'pluie' and 'pluie' or 'sec')
  local c = d and d.conditions
  if c and Util.isFinite(c.airTemp) then parts[#parts + 1] = L.f('air %s °C', Util.fmt(c.airTemp, 0)) end
  if c and Util.isFinite(c.roadTemp) then parts[#parts + 1] = L.f('piste %s °C', Util.fmt(c.roadTemp, 0)) end
  if c and Util.isFinite(c.roadGrip) then parts[#parts + 1] = L.f('grip %s %%', Util.fmt(c.roadGrip * 100, 0)) end
  return table.concat(parts, ' · ')
end

local TAB_SHORT = { ['DIAGNOSTIC'] = 'DIAG.', ['DIAGNOSTICS'] = 'DIAG.' }

-- onglets inclinés (−14°) ; l'actif en cyan plein ; petit compteur (version en cours, setups en mémoire) ; renvoie l'onglet
local function tabsRow(tabs, x, y, w, narrow, sups)
  local app = X.app
  local size = narrow and 11.5 or 15
  local pad = narrow and 7 or 14
  local h = narrow and 28 or 34
  -- largeur totale au naturel ; réduite jusqu'à 0,6 (10 px au moins) si elle ne tient pas
  local total = 0
  for _, tab in ipairs(tabs) do
    local visible = up(L.t((Skin.split(tab[1]))))
    if narrow then visible = TAB_SHORT[visible] or visible end
    total = total + measure('button', size, visible) + 2 * pad + 2
  end
  local scale = total > w and math.max(0.6, w / total) or 1
  local fs = math.max(10, math.floor(size * scale * 2) / 2)
  local p = pad * scale
  local cx = x
  for _, tab in ipairs(tabs) do
    local visible, id = Skin.split(tab[1])
    visible = up(L.t(visible))
    if narrow then visible = TAB_SHORT[visible] or visible end
    local tw, th = measure('button', fs, visible)
    local sup = sups[id]
    local sw = sup and (measure('mono', 9, sup) + 8) or 0
    local bw = tw + 2 * p + sw
    X.ui.setCursor(vec(1, X.ox + cx, X.oy + y))
    if X.ui.invisibleButton('###tab_' .. id, vec(3, bw, h)) then app.ui.tab = id end
    local active = app.ui.tab == id
    if active then
      slanted(cx, y, cx + bw, y + h, Skin.TAB_SLANT + 1, X.c.blue)
    elseif hovered() then
      slanted(cx, y, cx + bw, y + h, Skin.TAB_SLANT + 1, X.c.raised)
    end
    text('button', fs, visible, cx + p, y + (h - th) / 2, active and X.c.dark or X.c.tabIdle)
    if sup then
      local sx = cx + p + tw + 4
      rect(sx, y + 8, sx + sw - 4, y + 8 + 13, active and X.c.dark or X.c.select)
      text('mono', 9, sup, sx + 2, y + 9, active and X.c.blue or X.c.blueSoft)
    end
    cx = cx + bw + 2
  end
  return h
end

-- interrupteur « SetupLab actif » (34 × 18) ; text : ACTIF / VEILLE à côté
local function switch(x, y, on, withText)
  local c = X.c
  local w = 34
  local label = L.t(on and 'ACTIF' or 'VEILLE')
  local tw = withText and (measure('section', 12, label) + 7) or 0
  X.ui.setCursor(vec(1, X.ox + x, X.oy + y))
  local clicked = X.ui.invisibleButton('###SetupLab actif', vec(3, w + tw, 18))
  X.ui.drawRectFilled(vec(1, X.ox + x, X.oy + y), vec(2, X.ox + x + w, X.oy + y + 18), on and c.blue or c.switchOff, 9)
  dot(on and (x + 25) or (x + 9), y + 9, 6, on and c.knobOn or c.grey)
  if withText then text('section', 12, label, x + w + 7, y + 2, on and c.light or c.grey) end
  return clicked
end

local function header(tabs, W, narrow)
  local app, c = X.app, X.c
  local d = app.discovery
  local x0 = narrow and 12 or 16
  local logo = narrow and 34 or 42
  local rowH = narrow and 40 or 48
  -- logo, SETUP/LAB, version
  Util.call(X.ui.drawImage, 'icon.png', vec(1, X.ox + x0 - 4, X.oy + (rowH - logo) / 2), vec(2, X.ox + x0 - 4 + logo,
    X.oy + (rowH - logo) / 2 + logo))
  local wordSize = narrow and 20 or 24
  local x = x0 - 4 + logo + (narrow and 4 or 10)
  local wSetup = measure('display', wordSize, 'SETUP')
  local _, wh = measure('display', wordSize, 'SETUPLAB')
  text('display', wordSize, 'SETUP', x, (rowH - wh) / 2, c.light)
  text('display', wordSize, 'LAB', x + wSetup, (rowH - wh) / 2, c.blue)
  X.ui.setCursor(vec(1, X.ox + x, X.oy + (rowH - wh) / 2))
  X.ui.invisibleButton('###brand', vec(3, wSetup + measure('display', wordSize, 'LAB'), wh))
  tip(Config.appName .. ' ' .. Config.version .. (d and d.car and ('\n' .. L.t('Voiture : ') .. tostring(d.car.id)) or '')
    .. (d and d.trackFiles and ('\n' .. L.t('Circuit : ') .. tostring(d.trackFiles.fullId)) or ''))
  x = x + wSetup + measure('display', wordSize, 'LAB') + 8
  local ver = versionShort()
  local vw, vh = measure('mono', narrow and 9.5 or 10, ver)
  local vy = (rowH - vh) / 2 - 1
  X.ui.drawRectFilled(vec(1, X.ox + x, X.oy + vy - 2), vec(2, X.ox + x + vw + 9, X.oy + vy + vh + 2), c.outline, 0)
  X.ui.drawRectFilled(vec(1, X.ox + x + 1, X.oy + vy - 1), vec(2, X.ox + x + vw + 8, X.oy + vy + vh + 1), c.bg, 0)
  text('mono', narrow and 9.5 or 10, ver, x + 4, vy, c.grey)
  x = x + vw + 9 + 12
  -- à droite : état, langue, interrupteur
  local right = W - (narrow and 12 or 14)
  local swText = not narrow
  local tw = swText and (measure('section', 12, L.t(app.auto and 'ACTIF' or 'VEILLE')) + 7) or 0
  local sx = right - (34 + tw)
  if switch(sx, (rowH - 18) / 2, app.auto == true, swText) then X.intents.autoToggle = true end
  tip('Actif : SetupLab affine tout seul le setup de la séance (tour rapide en essai, journée circuit, hotlap et '
    .. 'qualification ; course en course) et annonce chaque proposition ; à vous de l\'essayer, de trier ses réglages et de la '
    .. 'valider. En veille : rien n\'est calculé ni enregistré tout seul. Pour ce lancement d\'AC : jamais actif tout seul au '
    .. 'démarrage.')
  local english = app.settings.language ~= 'fr'
  local langText = english and 'EN' or 'FR'
  local lw = measure('section', 12, langText) + 14
  local lx = sx - 8 - lw
  X.ui.setCursor(vec(1, X.ox + lx, X.oy + (rowH - 24) / 2))
  if X.ui.invisibleButton('###lang_toggle', vec(3, lw, 24)) then
    X.intents.setting = { key = 'language', value = english and 'fr' or 'en' }
  end
  local hot = hovered()
  X.ui.drawRectFilled(vec(1, X.ox + lx, X.oy + (rowH - 24) / 2), vec(2, X.ox + lx + lw, X.oy + (rowH + 24) / 2),
    hot and c.blue or c.langLine, 0)
  X.ui.drawRectFilled(vec(1, X.ox + lx + 1, X.oy + (rowH - 24) / 2 + 1), vec(2, X.ox + lx + lw - 1, X.oy + (rowH + 24) / 2 - 1),
    c.langBg, 0)
  local _, lh = measure('section', 12, langText)
  text('section', 12, langText, lx + 7, (rowH - lh) / 2, c.light)
  tip('Language / Langue : English, Français.')
  -- état : au stand, en piste (enregistrement), en veille
  local atPit = app.carAtPit and app.carAtPit()
  local state = app.auto ~= true and 'EN VEILLE' or (atPit and 'AU STAND' or 'EN PISTE · REC')
  if narrow then state = app.auto ~= true and 'VEILLE' or (atPit and 'STAND' or 'PISTE') end
  local fg = app.auto ~= true and c.tabIdle or (atPit and c.go or c.rec)
  local bg = app.auto ~= true and c.pillIdle or (atPit and c.pillGo or c.pillRec)
  local ps = L.t(state)
  local pw, ph = measure('section', narrow and 11 or 12, ps)
  local px = lx - 8 - (pw + 26)
  rect(px, (rowH - 24) / 2, px + pw + 26, (rowH + 24) / 2, bg)
  dot(px + 12, rowH / 2, 3.5, fg)
  text('section', narrow and 11 or 12, ps, px + 20, (rowH - ph) / 2, fg)
  -- voiture / circuit et séance (entre la version et l'état)
  local carName = d and d.car and tostring(d.car.name) or nil
  local trackName = d and d.trackFiles and tostring(d.trackFiles.name) or nil
  local y2 = rowH
  if not narrow then
    local room = px - 12 - x
    if room > 60 and (carName or trackName) then
      rect(x - 6, 10, x - 5, rowH - 10, c.line)
      local title = (carName or '') .. ((carName and trackName) and '  /  ' or '') .. (trackName or '')
      text('section', 14, fitted('section', 14, title, room), x + 4, 8, c.light)
      text('text', 11.5, fitted('text', 11.5, sessionText(app), room), x + 4, 27, c.grey)
    end
  else
    local title = (carName or '') .. ((carName and trackName) and ' / ' or '') .. (trackName or '')
    local s = title ~= '' and (title .. ' · ' .. sessionText(app)) or sessionText(app)
    text('text', 11, fitted('text', 11, s, W - 2 * x0), x0, y2, c.grey)
    y2 = y2 + 18
  end
  -- onglets et filet cyan
  local sups = {}
  local r = app.refine
  if r and r.kind == 'quali' and (r.version or 0) > (r.base or 0) then sups['Tour rapide'] = 'v' .. r.version end
  if r and r.kind == 'race' and (r.version or 0) > (r.base or 0) then sups['Course'] = 'v' .. r.version end
  local mem = 0
  for _ in pairs(app.memory or {}) do mem = mem + 1 end
  if mem > 0 then sups['Mémoire'] = tostring(mem) end
  local th = tabsRow(tabs, narrow and 8 or 12, y2, W - (narrow and 16 or 24), narrow, sups)
  rect(0, y2 + th, W, y2 + th + 2, c.blue)
  return y2 + th + 2
end
M.header = header

-- ---------------------------------------------------------------------------
-- Ligne d'état et message
-- ---------------------------------------------------------------------------

local STATE_WORDS = { running = 'en cours', done = 'terminé', failed = 'en échec', cancelled = 'annulé' }
local function statusRow(x, y, w)
  local app, c = X.app, X.c
  local d = app.discovery
  local cx = x
  local disc = app.discoveryState
  if disc ~= 'done' then
    cx = cx + chip(cx, y, disc == 'failed' and c.danger or c.warn, 'Découverte',
      disc == 'running' and 'en cours' or (disc == 'failed' and 'en échec' or 'en attente')) + 16
  end
  local source = d and ((d.carBase and d.carBaseMissing and #d.carBaseMissing == 0) and 'fichiers voiture'
    or (app.measureOnly and 'mesure seule' or 'incomplètes')) or '—'
  cx = cx + chip(cx, y, source == 'fichiers voiture' and c.go or c.warn, 'Données', source) + 16
  local model = X.U.modelState(app)
  local modelShort = model == 'non calibré (calibration disponible)' and 'calibration disponible' or model
  cx = cx + chip(cx, y, model == 'calibré' and c.go or c.warn, 'Modèle', modelShort) + 16
  for _, k in ipairs({ 'quali', 'race' }) do
    local q = app[k]
    local st = q and (STATE_WORDS[q.state] or q.state) or 'non lancé'
    local ink = (q and q.state == 'done') and c.go or ((q and q.state == 'running') and c.blue or c.dim)
    local cw = measure('mono', 10.5, up(L.t(k == 'quali' and 'Qualif' or 'Course'))) + measure('mono', 10.5, L.t(st)) + 18
    if cx + cw > x + w then break end
    cx = cx + chip(cx, y, ink, k == 'quali' and 'Qualif' or 'Course', st) + 16
  end
  local perf = app.perf and app.perf.avgMs
  if Util.isFinite(perf) then
    local s = Util.fmt(perf, 1) .. ' ms/frame'
    local pw = measure('mono', 10.5, s)
    if cx + pw < x + w then text('mono', 10.5, s, x + w - pw, y, c.grey) end
  end
  return 18
end

-- mise à jour en jeu : ligne verte avec « Mettre à jour » (mêmes identifiants que les contrôles ImGui)
local function updateRow(x, y, w)
  local u = X.app.updater
  if not u then return 0 end
  local c = X.c
  if u.state == 'available' and u.info then
    local s = L.f('Mise à jour disponible : %s (installée : %s)', tostring(u.info.version), tostring(Config.version))
    local beside = w >= 480
    local th = textBox('bold', 12.5, s, 0, 0, beside and (w - 170) or (w - 24), c.light, true)
    local h = beside and math.max(34, th + 18) or (th + 18 + 32)
    rect(x, y, x + w, y + h, c.okBg)
    rect(x, y, x + 3, y + h, c.go)
    textBox('bold', 12.5, s, x + 12, y + 9, beside and (w - 170) or (w - 24), c.light)
    local bx, by = beside and (x + w - 150) or (x + 12), beside and (y + 4) or (y + th + 14)
    if button('Mettre à jour###update_apply', bx, by, 146, 26, 'go', 13) then X.intents.updateApply = true end
    tip('Au stand, voiture arrêtée : télécharge l\'archive de la version ' .. tostring(u.info.version) .. ' sur GitHub, '
      .. 'vérifie sa taille et son empreinte SHA-256, puis remplace les fichiers de l\'app (les fichiers d\'avant sont remis en '
      .. 'cas d\'échec). CSP recharge alors SetupLab, qui revient en veille ; vos réglages, votre mémoire et vos setups sont '
      .. 'gardés.')
    return h + 8
  elseif u.state == 'downloading' or u.state == 'extracting' then
    return messageBar(L.t('Mise à jour en cours : ' .. (u.state == 'downloading' and 'téléchargement' or 'installation') .. '…'),
      x, y, w, 'info') + 8
  elseif u.state == 'done' then
    return messageBar(L.t('Mise à jour installée : CSP recharge SetupLab.'), x, y, w, 'go') + 8
  elseif u.state == 'failed' then
    local h = messageBar(L.t('Mise à jour impossible : ' .. tostring(u.why) .. '.'), x, y, w, u.mixed and 'error' or 'warn')
    local by = y + h + 6
    local bx = x
    if u.info and not u.wrote then
      if button('Réessayer###update_apply', bx, by, 130, 26, 'go', 13) then X.intents.updateApply = true end
      bx = bx + 138
    end
    if u.info then
      if button('Copier le lien###update_link', bx, by, 150, 26, nil, 13) then X.intents.updateCopyLink = true end
      tip(L.t('Installez-la à la main depuis ') .. tostring(u.info.page))
    end
    return h + (u.info and 40 or 8)
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Données de la page de calcul (qualification ou course)
-- ---------------------------------------------------------------------------

-- version de l'affinage dont parle la carte d'étape
local function focusVersion(model, r)
  if model == nil or r == nil then return nil end
  if r.choice then
    for _, e in ipairs(r.history) do if e.version == r.choice then return e end end
  end
  return model.trial or model.pending or model.keptInCar or model.validated
end

local function bucketOf(app) return app.wet and app.wet.state or 'sec' end

-- vos temps avec le setup en cours (meilleur, ou moyenne en course)
local function mineNow(app, kind)
  local d = app.discovery
  return X.U.realTime(X.U.realLaps(app, d and d.family, bucketOf(app)), kind)
end

-- « 31.0 psi › 29.0 psi » → « 31.0 › 29.0 psi » (même unité des deux côtés)
local function fromTo(a, b)
  if a == nil or a == '' then return tostring(b) end
  local ua = tostring(a):match('^[%-%d%.,]+%s*(.*)$')
  local ub = tostring(b):match('^[%-%d%.,]+%s*(.*)$')
  if ua and ub and ua ~= '' and ua == ub then
    return tostring(a):sub(1, #tostring(a) - #ua):gsub('%s+$', '') .. ' › ' .. tostring(b)
  end
  return tostring(a) .. ' › ' .. tostring(b)
end

-- lignes « réglage, actuel › proposé, delta » d'une version (ses groupes d'effets) ou d'un résultat (ses changements), en
-- cache par version ou résultat et par langue (row.item.keep : état gardé / refusé en direct)
local rowsCache = setmetatable({}, { __mode = 'k' })
local function changeRows(e, r)
  local owner = (e and e.groups) or (r and r.changes)
  if owner == nil then return {} end
  local cached = rowsCache[owner]
  if cached and cached.lang == L.lang then return cached end
  local rows = { lang = L.lang }
  rowsCache[owner] = rows
  if e and e.groups then
    for _, g in ipairs(e.groups) do
      for i, item in ipairs(g.items) do
        local c = item.change
        local row = { group = i == 1 and L.t(g.label) or '', item = item, key = item.key }
        if c then
          row.name = L.t(c.var.label)
          row.from, row.to = X.U.physicalText(c.var.kind, c.from), X.U.physicalText(c.var.kind, c.to)
          row.gain = c.contribution or 0
          row.pending = c.atBound
        elseif item.compound then
          row.name = L.t('Composé de pneus')
          row.from, row.to = '', tostring(e.compound and e.compound.name)
        else
          row.name = L.t(item.label or item.aid or '')
          row.from, row.to = tostring(item.from), tostring(item.to)
        end
        rows[#rows + 1] = row
      end
    end
  elseif r and r.changes then
    for _, c in ipairs(r.changes) do
      rows[#rows + 1] = { group = '', name = L.t(c.var and c.var.label or c.label or ''),
        from = c.var and X.U.physicalText(c.var.kind, c.from) or tostring(c.from),
        to = c.var and X.U.physicalText(c.var.kind, c.to) or tostring(c.to), gain = c.contribution or 0, pending = c.atBound }
    end
  end
  return rows
end

-- réglages optimisés, à venir, conservés (couverture du setup)
local function coverage(app)
  local d = app.discovery
  local space = d and d.space
  if space == nil then return nil end
  if d.dashCoverage == nil then
    local optimized, later, kept = 0, 0, 0
    for _, row in ipairs(SetupSpace.statusRows(space)) do
      if row.status == 'optimisé' then
        optimized = optimized + 1
      elseif row.detail and (row.detail:find('rugosité', 1, true) or row.detail:find('repère de hauteur', 1, true)) then
        later = later + 1
      else
        kept = kept + 1
      end
    end
    d.dashCoverage = { optimized = optimized, later = later, kept = kept }
  end
  return d.dashCoverage
end

-- équilibre par vitesse de virage (virages lents, moyens, rapides : seuils du profil du circuit)
local function balanceBands(corners)
  if corners == nil or #corners == 0 then return nil end
  local out = { { sum = 0, n = 0 }, { sum = 0, n = 0 }, { sum = 0, n = 0 } }
  for _, c in ipairs(corners) do
    local kmh = (c.v or 0) * 3.6
    local band = kmh < K.slowCornerKmh and 1 or (kmh > K.fastCornerKmh and 3 or 2)
    out[band].sum, out[band].n = out[band].sum + c.balance, out[band].n + 1
  end
  for _, b in ipairs(out) do b.value = b.n > 0 and b.sum / b.n or nil end
  return out
end

-- ---------------------------------------------------------------------------
-- Carte d'étape
-- ---------------------------------------------------------------------------

-- actions de la carte : principale (étape) puis secondaires (version) ; chacune { label, intent, style, tip, icon }
local function cardActions(model, vm, kind)
  local app = X.app
  local main, more = nil, {}
  local first = model.actions[1]
  if first then
    main = first
    for i = 2, #model.actions do more[#more + 1] = model.actions[i] end
  elseif app.saved and app.saved[kind] then
    main = { label = X.U.loadLabel(app, kind), intent = { load = kind }, style = 'go', tip = X.U.LOAD_TIP, load = true }
  end
  if vm and vm.actions then
    local verdict = main and main.intent and main.intent.refineJudge and main.intent.refineJudge.verdict
    local a = vm.actions
    if a.try and verdict ~= 'essayer' and main == nil then main = a.try end
    if a.validate and verdict ~= 'valider' then
      local short = a.validate.label:find('sans essai', 1, true) and 'Valider sans essai' or nil
      more[#more + 1] = { label = a.validate.label, intent = a.validate.intent, tip = a.validate.tip, short = short,
        partial = vm.kept < vm.total and (vm.kept .. '/' .. vm.total) or nil }
    end
    if not (model.refine and model.refine.choice) then
      if a.restart then more[#more + 1] = { label = a.restart.label, intent = a.restart.intent, tip = a.restart.tip,
        icon = 'Restart', short = '×' } end
      if a.lock then more[#more + 1] = { label = a.lock.label, intent = a.lock.intent, tip = a.lock.tip, icon = 'Padlock',
        short = 'F' } end
    end
  end
  return main, more
end

-- conditions du chargement (au stand, arrêtée, menu ouvert) et suivi du dernier chargement
local function loadState(kind)
  local app = X.app
  local r = app.loadReady
  local parts = nil
  if r then
    parts = { { L.t('au stand'), r.pit }, { L.t('arrêtée'), r.stopped }, { L.t('menu ouvert'), r.menu } }
  end
  local follow, color = nil, nil
  local check, test = app.loadCheck, app.loadTest
  if check and check.kind == kind then
    follow, color = L.t('Chargement demandé : vérification du setup en cours…'), X.c.grey
  elseif app.loadNote and app.loadNote.kind == kind then
    follow, color = L.t(app.loadNote.text), X.c.danger
  elseif test and test.kind == kind and not test.ok then
    follow, color = L.t('Dernier chargement : ') .. L.t(tostring(test.reason)), X.c.warn
  end
  return parts, follow, color
end

local PICK = {
  start_reference = { tag = 'Recommandé', title = 'Reprendre ma référence' },
  start_mine = { tag = 'Dans la voiture', title = 'Mon setup actuel' },
  start_default = { tag = 'Origine', title = 'Setup par défaut' },
}
-- étape 1 avec des départs à choisir : les cartes de choix portent les boutons
local function hasPicks(model)
  if model.step ~= 1 then return false end
  for _, a in ipairs(model.actions) do
    if PICK[select(2, Skin.split(a.label))] then return true end
  end
  return false
end

local VERBS = { essayer = 'Essayer', valider = 'Valider', ['écarter'] = 'Recommencer' }

-- conditions en pastilles : vert si remplie, ambre sinon ; à la ligne au-delà de maxW ; renvoie la largeur et la hauteur
local function conditions(parts, x, y, maxW)
  local cx, cy, widest = x, y, 0
  for _, part in ipairs(parts) do
    local tw = measure('text', 11, part[1])
    if maxW and cx > x and cx + 10 + tw > x + maxW then
      cx, cy = x, cy + 15
    end
    dot(cx + 3, cy + 7, 3, part[2] and X.c.go or X.c.warn)
    text('text', 11, part[1], cx + 10, cy, part[2] and X.c.go or X.c.warn)
    cx = cx + 10 + tw + 10
    widest = math.max(widest, cx - x)
  end
  return widest, cy - y + 13
end

-- carte d'étape (planches QUALIF) ; dry : hauteur seule ; renvoie la hauteur
local function stepCard(model, kind, x, y, w, wide, dry)
  local app, c = X.app, X.c
  local r = model.refine
  local e = focusVersion(model, r)
  local vm = (e and r) and X.U.versionModel(app, r, e, kind, '') or nil
  local picks = hasPicks(model)
  local main, more = nil, {}
  if not picks then main, more = cardActions(model, vm, kind) end
  local rightW = wide and 250 or 0
  local pad = 16
  local lw = w - 2 * pad - (wide and (rightW + 20) or 0)
  -- colonne gauche
  local title = L.t(model.title)
  local stepLabel = model.step and L.f('Étape %s / 4', model.step) or (model.done and L.t('Validée · 4 / 4') or nil)
  if stepLabel and kind == 'race' then stepLabel = stepLabel .. ' · ' .. L.t('Course') end
  local cy = y + 14
  local function at(dy) cy = cy + dy end
  local titleText = title:gsub('^[^·]+· ', '')
  if stepLabel == nil then titleText = title end
  if picks then titleText = L.t('D\'où part-on ?') end
  local intro = picks and (L.t(model.text) .. ' ' .. L.t('Le choix active SetupLab. Rien n\'est écrit sans votre clic.')) or nil
  local tsize = wide and 34 or 30
  local _, th = measure('display', tsize, up(titleText), lw)
  local textH = picks and 0 or textBox('text', 12.5, L.t(model.text), x + pad, 0, lw, c.soft, true)
  local parts, follow, followColor = loadState(kind)
  local h = 14 + (stepLabel and 15 or 0) + th + 8 + ((model.step or model.done) and 22 + 8 or 0) + textH + 10
  local btnH = 40
  local mainW = main and math.min(lw, math.max(190, measure('button', 16, up(L.t((Skin.split(main.label))))) + 70)) or 0
  if main then h = h + btnH end
  if not wide and #more > 0 then h = h + 6 + 36 end
  if main and main.intent and (main.intent.refineJudge or main.load) and parts then h = h + (wide and 18 or 33) end
  if follow then h = h + 16 end
  if model.start then h = h + 18 end
  local rightH = wide and 14 + 15 + 46 + 12 + 15 + 28 + 14 + 18 or 0
  if picks then
    rightH = wide and (textBox('text', 12.5, intro, 0, 0, rightW, c.soft, true) + 28) or 0
    if not wide then h = h + textBox('text', 12.5, intro, 0, 0, lw, c.soft, true) + 8 end
  elseif not wide then
    h = h + 62
  end
  h = math.max(h + 12, rightH + 14)
  if dry then return h end
  panel(x, y, x + w, y + h)
  if stepLabel then
    lab(stepLabel, x + pad, cy, c.blueSoft)
    at(15)
  end
  if model.start then
    local s = L.t('Départ') .. ' · ' .. L.t(tostring(X.U.START_NAMES[model.start.mode] or model.start.mode))
    local sw = measure('label', 11, up(s))
    local lx = x + pad + lw - sw - measure('label', 11, up(L.t('changer'))) - 8
    if stepLabel then
      lab(s, lx, cy - 15)
      X.ui.setCursor(vec(1, X.ox + lx + sw + 8, X.oy + cy - 16))
      if X.ui.invisibleButton('###start_change', vec(3, measure('label', 11, up(L.t('changer'))), 14)) then
        X.intents.startReset = kind
      end
      lab('changer', lx + sw + 8, cy - 15, hovered() and c.blue or c.light)
      tip('Repartir d\'un autre setup : votre setup actuel, celui par défaut de la voiture, ou votre référence.')
    end
  end
  textBox('display', tsize, up(titleText), x + pad, cy, lw, X.c[model.color] or c.light)
  at(th + 8)
  if model.step or model.done then
    at(stepBar(x + pad, cy, lw, model.step, model.done, true) + 8)
  end
  if not picks then at(textBox('text', 12.5, L.t(model.text), x + pad, cy, lw, c.soft) + 10) end
  -- boutons : principal, puis secondaires (icônes Recommencer et Figer)
  local bx = x + pad
  if main then
    local style = main.style == 'go' and 'go' or (main.load and 'go' or 'primary')
    local mw = wide and mainW or lw
    if button(main.label, bx, cy, mw, btnH, style, 16, 'left') then
      apply(main.intent)
      if main.tab then app.ui.tab = main.tab end
    end
    tip(main.tip)
    bx = bx + mw + 6
  end
  local rowY = cy
  if not wide and main then
    rowY = cy + btnH + 6
    bx = x + pad
  end
  for _, a in ipairs(more) do
    if a.icon then
      if iconButton(a.label, a.icon, a.short, bx, rowY, 40, wide and btnH or 36) then apply(a.intent) end
      tip2((Skin.split(a.label)), a.tip)
      bx = bx + 46
    else
      local vis = up(L.t(a.short or (Skin.split(a.label)))) .. (a.partial and (' · ' .. a.partial) or '')
      local bw = math.min(measure('button', 14, vis) + 36, math.max(120, x + pad + lw - bx - (#more - 1) * 46))
      if not wide then bw = math.max(120, x + pad + lw - bx - 2 * 46) end
      if button(a.label, bx, rowY, bw, wide and btnH or 36, a.style, 14, nil, vis) then
        apply(a.intent)
        if a.tab then app.ui.tab = a.tab end
      end
      tip(a.tip)
      bx = bx + bw + 6
    end
  end
  cy = (not wide and #more > 0) and (rowY + 36) or (main and (cy + btnH) or cy)
  if main and main.intent and (main.intent.refineJudge or main.load) and parts then
    cy = cy + 5
    local verb = main.load and 'Charger' or (VERBS[main.intent.refineJudge.verdict] or 'Charger')
    local lx = x + pad + text('text', 11, L.t(verb) .. L.t(' : '), x + pad, cy, c.grey) + 4
    local _, ch = conditions(parts, lx, cy, x + pad + lw - lx)
    cy = cy + ch
  end
  if follow then text('text', 11, fitted('text', 11, follow, lw), x + pad, cy + 3, followColor or c.grey) end
  if picks then
    -- explication à droite (large) ou dessous (étroit)
    if wide then
      local rx = x + w - pad - rightW
      rect(rx - 18, y + 14, rx - 17, y + h - 14, c.line)
      textBox('text', 12.5, intro, rx, y + 14, rightW, c.soft)
    else
      textBox('text', 12.5, intro, x + pad, cy, lw, c.soft)
    end
    return h
  end
  -- colonne droite : vos temps, objectif, delta, modèle
  local mine = mineNow(app, kind)
  local gain = e and e.gain or nil
  local real = vm and vm.realGain or nil
  local rx = wide and (x + w - pad - rightW) or (x + pad)
  local ry = wide and (y + 14) or (y + h - 62)
  if wide then
    rect(rx - 18, y + 14, rx - 17, y + h - 14, c.line)
    local bestLabel = (vm and vm.tMine) and L.f('Votre meilleur · %s', vm.v) or L.t('Votre meilleur · setup actuel')
    if kind == 'race' then
      bestLabel = (vm and vm.tMine) and L.f('Votre tour moyen · %s', vm.v) or L.t('Votre tour moyen · setup actuel')
    end
    lab(bestLabel, rx, ry)
    local best = (vm and vm.tMine) or mine
    text('display', 42, best and X.U.lapTime(best) or '—', rx, ry + 16, (best and kind ~= 'race') and c.best or c.light)
    local half = (rightW - 10) / 2
    if real then
      chrono('Gain réel', X.U.gainText(real), rx, ry + 72, 24, real > 0 and c.go or c.danger)
      chrono('Prévu', gain and X.U.gainText(gain) or '—', rx + half + 10, ry + 72, 24, c.grey)
    else
      chrono('Objectif', (mine and gain) and X.U.lapTime(mine - gain) or '—', rx, ry + 72, 24, c.best)
      chrono(kind == 'race' and 'Delta / tour' or 'Delta prévu', gain and X.U.gainText(gain) or '—', rx + half + 10, ry + 72, 24,
        (gain and gain > 0) and c.go or c.grey)
    end
    local raceLaps = kind == 'race' and app.raceLaps or nil
    if gain and Util.isFinite(raceLaps) and raceLaps > 0 then
      text('text', 11, L.f('soit %s sur %s tours', X.U.gainText(gain * raceLaps), raceLaps), rx, ry + 116, c.grey)
    end
    local model2 = X.U.modelState(app)
    local my = y + h - 14 - 18
    lab('Modèle', rx, my)
    local ms = up(L.t(model2 == 'non calibré (calibration disponible)' and 'calibration prête' or model2))
    local msw = measure('section', 11.5, ms)
    text('section', 11.5, ms, rx + rightW - msw, my, model2 == 'calibré' and c.go or c.warn)
    local seg = (rightW - 18) / 10
    local filled = model2 == 'calibré' and 10 or (model2 == 'non calibré' and 2 or 6)
    for i = 1, 10 do
      rect(rx + (i - 1) * (seg + 2), my + 15, rx + (i - 1) * (seg + 2) + seg, my + 19, i <= filled and (model2 == 'calibré' and c.go
        or c.warn) or c.segmentOff)
    end
  else
    rect(x + pad, ry - 6, x + w - pad, ry - 5, c.line)
    local third = (w - 2 * pad - 12) / 3
    local best = (vm and vm.tMine) or mine
    chrono(kind == 'race' and 'Moyenne' or 'Meilleur', best and X.U.lapTime(best) or '—', rx, ry, 20,
      (best and kind ~= 'race') and c.best or c.light)
    if real then
      chrono('Gain réel', X.U.gainText(real), rx + third + 6, ry, 20, real > 0 and c.go or c.danger)
      chrono('Prévu', gain and X.U.gainText(gain) or '—', rx + 2 * (third + 6), ry, 20, c.grey)
    else
      chrono('Objectif', (mine and gain) and X.U.lapTime(mine - gain) or '—', rx + third + 6, ry, 20, c.best)
      chrono('Delta', gain and X.U.gainText(gain) or '—', rx + 2 * (third + 6), ry, 20, (gain and gain > 0) and c.go or c.grey)
    end
  end
  return h
end

-- ---------------------------------------------------------------------------
-- Panneaux de la page de calcul
-- ---------------------------------------------------------------------------

-- vos retouches gardées : barre fine avec « Libérer »
local function pinsBar(kind, x, y, w)
  local list = X.U.pinsLabels(X.app, kind)
  if list == nil then return 0 end
  local names = {}
  for i, s in ipairs(list) do names[i] = L.t(s) end
  local labels = table.concat(names, ', ')
  local c = X.c
  rect(x, y, x + w, y + 26, c.bar)
  local s = L.t('Vos retouches : ') .. labels .. L.t(' — les calculs ne les changent plus')
  text('text', 12, fitted('text', 12, s, w - 120), x + 12, y + 6, c.soft)
  if button('Libérer###pins_clear_' .. kind, x + w - 96, y + 2, 92, 22, nil, 12) then X.intents.pinsClear = kind end
  tip('Réglages modifiés à la main depuis le dernier chargement par SetupLab : gardés à votre valeur. Les libérer : le '
    .. 'prochain calcul peut de nouveau tous les changer.')
  return 34
end

-- réglages proposés (ou changés) : groupe, réglage, actuel › proposé, delta ; Gardé / Refusé quand « Modifier… » est ouvert
local function changesPanel(kind, e, r, x, y, w, dry)
  local app, c = X.app, X.c
  local rows = changeRows(e, r)
  if #rows == 0 then return 0 end
  local editable = e and (e.status == nil or e.status == 'essai')
  app.ui.modify = app.ui.modify or {}
  local mkey = e and (kind .. '_' .. e.version) or nil
  local open = editable and app.ui.modify[mkey] == true
  local narrow = w < 360
  local pw0 = w - 28
  local groupW0 = narrow and 0 or 66
  local toggleW0 = open and 124 or 0
  -- une ligne si nom, « à confirmer », valeur et delta tiennent ; sinon valeur et delta sous le nom
  local function twoLines(row)
    if narrow then return true end
    local tagW = row.pending and (measure('label', 9.5, up(L.t('à confirmer'))) + 6) or 0
    return groupW0 + measure('text', 12, row.name) + tagW + measure('mono', 10.5, fromTo(row.from, row.to)) + 58 + toggleW0 + 24 > pw0
  end
  local function heightOf(row)
    if twoLines(row) then return open and 42 or 38 end
    return open and 27 or 23
  end
  local groups = 0
  local rowsH = 0
  for _, row in ipairs(rows) do
    if row.group ~= '' then groups = groups + 1 end
    rowsH = rowsH + heightOf(row)
  end
  local h = 11 + 18 + 6 + rowsH + (narrow and groups * 18 or 0) + 8 + 26
  if dry then return h end
  panel(x, y, x + w, y + h)
  local px, pw = x + 14, w - 28
  local title = e and (e.status == 'validée' and L.f('Gardé dans %s', 'v' .. e.version) or L.t('Réglages proposés'))
    or L.t('Réglages changés')
  local tw = text('section', 14, up(title), px, y + 11, c.light)
  local n = tostring(#rows)
  local nw = measure('mono', 10, n)
  rect(px + tw + 8, y + 12, px + tw + 8 + nw + 10, y + 26, c.blue)
  text('mono', 10, n, px + tw + 13, y + 13, c.dark)
  if editable then
    local label = (open and 'Masquer le détail' or 'Modifier…') .. '###modify_' .. mkey
    local bw = measure('button', 12, up(L.t(open and 'Masquer le détail' or 'Modifier…'))) + 30
    if button(label, px + pw - bw, y + 8, bw, 22, open and 'outline' or nil, 12) then app.ui.modify[mkey] = not open end
    tip('Pour garder la version sauf un ou plusieurs réglages : les refuser un par un (un réglage refusé garde son ancienne '
      .. 'valeur, dans cette version et dans les calculs suivants).')
  else
    local s = up(L.t('Actuel › proposé · delta'))
    lab('Actuel › proposé · delta', px + pw - measure('label', 11, s), y + 14)
  end
  local cy = y + 11 + 18 + 6
  local groupW = narrow and 0 or 66
  local maxGain = 0.001
  for _, row in ipairs(rows) do maxGain = math.max(maxGain, math.abs(row.gain or 0)) end
  local toggleW = open and 124 or 0
  local deltaW = 58
  for _, row in ipairs(rows) do
    row.keep = row.item == nil or row.item.keep == true
    local ink = row.keep and c.light or c.grey
    if row.group ~= '' then
      if narrow then
        lab(row.group, px, cy + 5, c.grey, 10)
        cy = cy + 18
      else
        lab(fitted('label', 10, up(row.group), groupW - 6), px, cy + 6, c.grey, 10)
      end
    end
    local valueS = fromTo(row.from, row.to)
    local vw = measure('mono', 10.5, valueS)
    local tag = row.pending and up(L.t('à confirmer')) or nil
    local tagW = tag and (measure('label', 9.5, tag) + 6) or 0
    local two = twoLines(row)
    local rowH = heightOf(row)
    local nameW = two and (pw - groupW - toggleW - 8 - tagW) or math.max(40, pw - groupW - vw - deltaW - toggleW - 18 - tagW)
    local vy = two and (cy + 19) or cy
    local nameS = fitted('text', 12, row.name, nameW)
    local nw = text('text', 12, nameS, px + groupW, cy + 4, ink)
    if tag then text('label', 9.5, tag, px + groupW + nw + 6, cy + 7, c.warn) end
    local vx = two and (px + groupW) or (px + pw - deltaW - toggleW - vw - 8)
    text('mono', 10.5, valueS, vx, vy + 5, row.keep and c.grey or c.dim)
    -- barre de gain et valeur
    local gx = px + pw - deltaW - toggleW
    local gain = row.gain or 0
    local gs = Util.fmt(math.abs(gain), 3):gsub('^0', '')
    local gw = measure('mono', 11, gs)
    local barW = math.max(2, (deltaW - gw - 8) * math.abs(gain) / maxGain)
    local gc = (not row.keep) and c.dim or (row.pending and c.warn or (gain >= 0 and c.go or c.danger))
    rect(gx, vy + 10, gx + barW, vy + 14, gc)
    text('mono', 11, gs, gx + deltaW - gw, vy + 5, gc)
    if open then
      -- sélecteur Gardé | Refusé (un clic bascule ; même identifiant que le bouton ImGui)
      local tx = px + pw - toggleW + 8
      local half = (toggleW - 8) / 2
      X.ui.setCursor(vec(1, X.ox + tx, X.oy + cy + 2))
      local clicked = X.ui.invisibleButton('###effect_' .. kind .. '_' .. e.version .. '_' .. row.key, vec(3, toggleW - 8, 22))
      local hot = hovered()
      rect(tx, cy + 2, tx + toggleW - 8, cy + 24, hot and c.rowHover or c.bg)
      if row.keep then rect(tx, cy + 2, tx + half, cy + 24, c.keepBg) else rect(tx + half, cy + 2, tx + 2 * half, cy + 24, c.badBg) end
      local ks, rs = up(L.t('Gardé')), up(L.t('Refusé'))
      text('section', 11, ks, tx + (half - measure('section', 11, ks)) / 2, cy + 7, row.keep and c.go or c.grey)
      text('section', 11, rs, tx + half + (half - measure('section', 11, rs)) / 2, cy + 7, row.keep and c.grey or c.badInk)
      if clicked then X.intents.effect = { version = e.version, key = row.key, keep = not row.keep } end
      tip(row.keep and 'Gardé : ce réglage sera dans la version validée. Un clic pour le refuser.'
        or 'Refusé : ce réglage garde son ancienne valeur, dans cette version et dans les calculs suivants. Un clic pour le garder.')
    end
    rect(px, cy + rowH - 1, px + pw, cy + rowH, c.rowLine)
    cy = cy + rowH
  end
  -- pied : couverture du setup, tout garder
  cy = cy + 8
  local cov = coverage(app)
  if cov then
    local fx = px
    fx = fx + text('bold', 11.5, tostring(cov.optimized), fx, cy, c.go) + 4
    fx = fx + text('text', 11.5, L.t('optimisés'), fx, cy, c.grey) + 12
    if cov.later > 0 then
      fx = fx + text('bold', 11.5, tostring(cov.later), fx, cy, c.warn) + 4
      fx = fx + text('text', 11.5, L.t('à venir'), fx, cy, c.grey) + 12
    end
    fx = fx + text('bold', 11.5, tostring(cov.kept), fx, cy, c.light) + 4
    text('text', 11.5, L.t('conservés'), fx, cy, c.grey)
  end
  if open and e then
    local kept = 0
    for _, row in ipairs(rows) do if row.keep then kept = kept + 1 end end
    if kept < #rows and button('Tout garder###keep_all_' .. mkey, px + pw - 120, cy - 4, 120, 22, nil, 12) then
      X.intents.effect = { version = e.version, key = '*', keep = true }
    end
  end
  return h
end

-- équilibre : moyen actuel › proposé, et par vitesse de virage
local function balancePanel(r, x, y, w, dry)
  if r == nil or not Util.isFinite(r.balanceProposed) then return 0 end
  local h = 92
  if dry then return h end
  local c = X.c
  panel(x, y, x + w, y + h)
  lab('Équilibre', x + 14, y + 10)
  local a = text('display', 17, Util.fmt(r.balanceCurrent, 2), x + 14, y + 30, c.grey)
  text('section', 14, '›', x + 14 + a + 5, y + 32, c.blue)
  text('display', 30, Util.fmt(r.balanceProposed, 2), x + 14 + a + 18, y + 22, c.light)
  text('text', 10.5, L.t('1 = neutre'), x + 14, y + h - 22, c.grey)
  local bands = balanceBands(r.cornersProposed)
  local cur = balanceBands(r.cornersCurrent)
  if bands == nil then return h end
  local nx = x + 14 + 104 + 12
  local gx = nx + 52
  local gw = math.max(40, x + w - 14 - 36 - gx)
  local names = { 'Lents', 'Moyens', 'Rapides' }
  for i = 1, 3 do
    local by = y + 12 + (i - 1) * 18
    lab(names[i], nx, by, c.grey, 10)
    rect(gx, by + 1, gx + gw, by + 11, c.trackBg)
    local mid = gx + gw / 2
    rect(mid, by - 1, mid + 1, by + 13, c.dim)
    local function bar(value, top, bottom, color)
      if value == nil then return end
      local span = math.max(-0.5, math.min(0.5, (value - 1) * 4)) * gw
      if span < 0 then rect(mid + span, by + top, mid, by + bottom, color) else rect(mid, by + top, mid + span, by + bottom, color) end
    end
    bar(cur and cur[i].value, 1, 11, c.band)
    bar(bands[i].value, 3, 9, c.go)
    if bands[i].value then
      local s = Util.fmt(bands[i].value, 2)
      text('mono', 10.5, s, x + w - 14 - measure('mono', 10.5, s), by, c.light)
    end
  end
  local ly = y + 12 + 3 * 18
  text('text', 10, '‹ ' .. L.t('sous-vireur'), gx, ly, c.grey)
  local s = L.t('survireur') .. ' ›'
  text('text', 10, s, gx + gw - measure('text', 10, s), ly, c.grey)
  return h
end

-- pneus à chaud (par essieu) : pression actuelle › proposée, température, fenêtre
local function tyresPanel(r, x, y, w, dry)
  local t = r and r.tyres
  if t == nil or t.F == nil or t.R == nil then return 0 end
  local h = 78
  if dry then return h end
  local c = X.c
  panel(x, y, x + w, y + h)
  lab('Pneus à chaud · psi', x + 14, y + 10)
  local name = r.compound and r.compound.name
  if name then
    local s = up(tostring(name))
    text('section', 11.5, s, x + w - 14 - measure('section', 11.5, s), y + 9, c.light)
  end
  local tw = (w - 28 - 6) / 2
  for i, axle in ipairs({ 'F', 'R' }) do
    local e = t[axle]
    local tx = x + 14 + (i - 1) * (tw + 6)
    local ok = e.state ~= 'surchauffe' and e.state ~= 'froid'
    local bg = e.state == 'surchauffe' and c.badBg or (ok and c.okBg or c.warnBg)
    local edge = e.state == 'surchauffe' and c.danger or (ok and c.go or c.warn)
    local ink = e.state == 'surchauffe' and c.badInk or (ok and c.okInk or c.warnInk)
    rect(tx, y + 28, tx + tw, y + h - 10, bg)
    rect(tx, y + 28, tx + tw, y + 31, edge)
    local temp = e.temp and (Util.fmt(e.temp, 0) .. '°') or ''
    lab((axle == 'F' and L.t('Avant') or L.t('Arrière')) .. (temp ~= '' and (' · ' .. temp) or ''), tx + 8, y + 36, ink, 9.5)
    local hot = Util.fmt(e.hotProposed, 1)
    local hw = measure('display', 19, hot)
    text('display', 19, hot, tx + tw - 8 - hw, y + 38, c.light)
    local cur = Util.fmt(e.hotCurrent, 1) .. '›'
    text('mono', 10, cur, tx + tw - 8 - hw - 4 - measure('mono', 10, cur), y + 44, ink)
  end
  return h
end

-- vitesse simulée le long du tour : actuel (gris) et proposé (vert)
local function speedPanel(r, current, x, y, w, h, dry)
  local pc, pp = r and r.profileCurrent or current, r and r.profileProposed
  if pc == nil then return 0 end
  if dry then return h end
  local c = X.c
  panel(x, y, x + w, y + h)
  lab('Vitesse simulée', x + 14, y + 8)
  local lx = x + w - 14
  if pp then
    local s = L.t('proposé')
    lx = lx - measure('text', 10.5, s)
    text('text', 10.5, s, lx, y + 7, c.grey)
    rect(lx - 14, y + 13, lx - 4, y + 15, c.go)
    lx = lx - 22
  end
  local s = L.t('actuel')
  lx = lx - measure('text', 10.5, s)
  text('text', 10.5, s, lx, y + 7, c.grey)
  rect(lx - 14, y + 13, lx - 4, y + 15, c.dim)
  local gx, gy, gw, gh = x + 14, y + 26, w - 28, h - 34
  local vmax = 1
  for _, prof in ipairs(pp and { pc, pp } or { pc }) do
    for i = 1, #prof.v do vmax = math.max(vmax, prof.v[i]) end
  end
  local function plot(profile, color, thick)
    local v, s = profile.v, profile.s
    local n = v and #v or 0
    if n < 2 or s == nil or not Util.isFinite(profile.length) or profile.length <= 0 then return end
    local stepI = math.max(1, math.floor(n / math.max(40, math.floor(gw / 3))))
    local px, py = nil, nil
    for i = 1, n, stepI do
      local qx = gx + s[i] / profile.length * gw
      local qy = gy + gh - (v[i] / vmax) * gh
      if px then line(px, py, qx, qy, color, thick) end
      px, py = qx, qy
    end
  end
  plot(pc, c.dim, 1.4)
  if pp then plot(pp, c.go, 1.6) end
  return h
end

-- versions de l'affinage : tuiles (validée, non gardée, à juger), nom du fichier, arrêt
local function versionsPanel(kind, r, x, y, w, dry)
  local app, c = X.app, X.c
  if r == nil or r.kind ~= kind then return 0 end
  local list = {}
  for i = #r.history, 1, -1 do
    local e = r.history[i]
    if e.version then table.insert(list, 1, e) end
    if #list >= 3 then break end
  end
  local stacked = w - 28 < 470
  local h = (#list > 0 and 54 or 0) + 46 + 14 + (stacked and 36 or 0)
  if dry then return h end
  panel(x, y, x + w, y + h)
  local px, pw = x + 14, w - 28
  local cy = y + 10
  if #list > 0 then
    lab('Versions', px, cy + 6)
    text('text', 11, L.t('prévu / réel'), px, cy + 22, c.grey)
    local tw = (pw - 80 - 6 * (#list - 1)) / #list
    for i, e in ipairs(list) do
      local tx = px + 80 + (i - 1) * (tw + 6)
      local vm = X.U.versionModel(app, r, e, kind, '')
      local status = e.status
      local bg = status == 'validée' and c.okBg or (status == nil and c.select or c.tile)
      rect(tx, cy, tx + tw, cy + 44, bg)
      if status == nil or status == 'essai' then
        X.ui.drawRect(vec(1, X.ox + tx, X.oy + cy), vec(2, X.ox + tx + tw, X.oy + cy + 44), c.blue, 0, 0, 1)
      end
      local vs = 'v' .. e.version
      local vw = text('display', 22, vs, tx + 10, cy + 11, status == 'écartée' and c.grey or c.light)
      local st = status == 'validée' and 'Validée' or (status == 'écartée' and 'Non gardée' or (status == 'essai' and 'En essai'
        or 'À juger'))
      local sc = status == 'validée' and c.go or (status == 'écartée' and c.grey or c.blueSoft)
      text('section', 11, fitted('section', 11, up(L.t(st)), tw - vw - 26), tx + 10 + vw + 10, cy + 9, sc)
      local pred = X.U.gainText(e.gain or 0)
      local realS = vm.realGain and X.U.gainText(vm.realGain) or '—'
      local s = pred .. ' / ' .. realS
      text('mono', 10.5, fitted('mono', 10.5, s, tw - vw - 26), tx + 10 + vw + 10, cy + 25,
        (vm.realGain and vm.realGain < 0) and c.danger or c.soft)
    end
    cy = cy + 54
  end
  -- nom du setup et fichier de la prochaine version, arrêt de l'affinage
  lab('Nom', px, cy + 8)
  local fx = px + 80
  local inputW = stacked and math.min(200, pw - 80) or math.min(170, pw - 80 - 150)
  if X.ui.inputText then
    X.ui.setCursor(vec(1, X.ox + fx, X.oy + cy + 1))
    Util.call(X.ui.setNextItemWidth, inputW)
    local current = app.names and app.names[kind] or ''
    local ok, s, changed = Util.call(X.ui.inputText, 'Nom du setup (facultatif)###name_' .. kind, current, 0x400000)
    if ok and changed and type(s) == 'string' then X.intents.name = { kind = kind, text = s } end
    tip('Accents et espaces retirés ; le genre (Qualif, Course) et « Pluie » s\'ajoutent au nom ; jamais d\'écrasement '
      .. '(-2, -3… si le nom existe). Changer le nom puis « Enregistrer » : le même setup sous le nouveau nom (l\'ancien fichier '
      .. 'reste). Sans nom : SetupLab_….' .. (kind == 'quali' and (' Voiture arrêtée, votre meilleur tour réel avec une version '
        .. 'gardée s\'ajoute à la fin de son nom (ex. _v2_1.41.792).') or ''))
  end
  local base = app.fileBase and app.fileBase(kind, bucketOf(app)) or nil
  local stopLabel = (r.active and 'Arrêter l\'affinage (' or 'Relancer l\'affinage (') .. X.U.KIND[kind].name .. ')'
  local stopW = math.min(220, measure('button', 12.5, up(L.t(stopLabel))) + 30)
  if base then
    local n = r.version
    local last = r.history[#r.history]
    if not (last and last.version == r.version and last.status == nil) then n = r.version + 1 end
    local s = '› ' .. base .. '_v' .. n .. '.ini · ' .. L.t('à la validation')
    if stacked then
      text('mono', 10.5, fitted('mono', 10.5, s, pw), px, cy + 36, c.grey)
    else
      text('mono', 10.5, fitted('mono', 10.5, s, pw - 80 - inputW - stopW - 24), fx + inputW + 10, cy + 8, c.grey)
    end
  end
  local stopY = stacked and (cy + 54) or cy
  if stacked then stopW = math.min(pw, stopW) end
  if button(stopLabel, stacked and px or (px + pw - stopW), stopY, stopW, 28, nil, 12.5) then
    if r.active then X.intents.refineStop = true else X.intents.refineStart = kind end
  end
  if r.active and app.auto then tip('SetupLab actif : l\'arrêt le met aussi en veille.') end
  return h
end

-- calcul à la main (hors affinage) : calculer, progression, enregistrer, mesurer le gain réel (mêmes libellés qu'ImGui)
local function toolsPanel(kind, x, y, w, dry)
  local app, c = X.app, X.c
  local spec = X.U.KIND[kind]
  local q = app[kind]
  local r = app.refine
  local refining = r and r.active and r.kind == kind
  local running = q and q.state == 'running'
  local done = q and q.state == 'done' and q.result
  local labels = { spec.compute }
  if not refining then labels[#labels + 1] = 'Affinage automatique (' .. spec.name .. ')' end
  if done then
    labels[#labels + 1] = spec.saveLabel
    labels[#labels + 1] = spec.validate
  end
  local rowsN, used = 1, 0
  for _, label in ipairs(labels) do
    local bw = measure('button', 12, up(L.t(label))) + 28
    if used > 0 and used + bw > w - 28 then
      rowsN, used = rowsN + 1, 0
    end
    used = used + bw + 6
  end
  local h = 52 + (rowsN - 1) * 30
  if dry then return h end
  panel(x, y, x + w, y + h)
  local px, pw = x + 14, w - 28
  lab('Calcul à la main', px, y + 10)
  local cy = y + 22
  if running then
    local o = q.opt
    local f = Util.clamp(o.evaluations / math.max(1, q.budget), 0, 1)
    rect(px, cy + 4, px + pw - 110, cy + 20, c.trackBg)
    rect(px, cy + 4, px + (pw - 110) * f, cy + 20, c.blue)
    text('mono', 10.5, L.f('%s : %s / %s', L.t(o.phase), o.evaluations, q.budget), px + 6, cy + 5, c.light)
    if button(spec.cancel, px + pw - 100, cy, 100, 24, nil, 12) then X.intents[kind .. 'Cancel'] = true end
    return h
  end
  local bx = px
  local function small(label, intent, style)
    local vis = up(L.t((Skin.split(label))))
    local bw = math.min(pw, measure('button', 12, vis) + 28)
    if bx > px and bx + bw > px + pw then
      bx, cy = px, cy + 30
    end
    if button(label, bx, cy, bw, 24, style, 12) then intent() end
    bx = bx + bw + 6
  end
  small(spec.compute, function() X.intents[kind .. 'Start'] = true end)
  tip('Un calcul complet depuis le setup en cours (' .. app.settings[spec.budgetKey] .. spec.unit .. ').')
  if not refining then
    small('Affinage automatique (' .. spec.name .. ')', function() X.intents.refineStart = kind end, 'outline')
  end
  if done then
    small(spec.saveLabel, function() X.intents[kind .. 'Save'] = true end)
    small(spec.validate, function() X.intents.validate = kind end)
  end
  return h
end

-- ---------------------------------------------------------------------------
-- Étape 1 : choix du départ (planche Q1) ; circuit et conditions
-- ---------------------------------------------------------------------------


local function picksRow(model, kind, x, y, w, wide, dry)
  local list = {}
  for _, a in ipairs(model.actions) do
    local _, id = Skin.split(a.label)
    if PICK[id] then list[#list + 1] = { a = a, id = id } end
  end
  if #list == 0 then return 0 end
  local cols = wide and #list or 1
  local each = (w - 8 * (cols - 1)) / cols
  local h1 = 150
  local rows = math.ceil(#list / cols)
  local h = rows * h1 + (rows - 1) * 8
  if dry then return h end
  local app, c = X.app, X.c
  local d = app.discovery
  for i, item in ipairs(list) do
    local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
    local bx, by = x + col * (each + 8), y + row * (h1 + 8)
    X.ui.setCursor(vec(1, X.ox + bx, X.oy + by))
    local clicked = X.ui.invisibleButton('###' .. item.id, vec(3, each, h1))
    local hot = hovered()
    local rec = item.id == 'start_reference'
    panel(bx, by, bx + each, by + h1, rec and c.select or (hot and c.rowHover or c.panel))
    if rec or hot then
      X.ui.drawRect(vec(1, X.ox + bx, X.oy + by), vec(2, X.ox + bx + each, X.oy + by + h1), rec and c.blue or c.outline, 0, 0, 1)
    end
    local spec = PICK[item.id]
    if rec then
      local s = up(L.t(spec.tag))
      local sw = measure('section', 10.5, s)
      rect(bx + 14, by + 12, bx + 14 + sw + 12, by + 28, c.blue)
      text('section', 10.5, s, bx + 20, by + 14, c.dark)
    else
      lab(spec.tag, bx + 14, by + 14, c.grey, 10)
    end
    local title = up(L.t(spec.title))
    local th = textBox('button', 20, title, bx + 14, by + 34, each - 28, c.light)
    textBox('text', 12, L.t(item.a.tip or ''), bx + 14, by + 34 + th + 6, each - 28, c.soft)
    -- pied : fichier et temps
    rect(bx + 14, by + h1 - 30, bx + each - 14, by + h1 - 29, rec and c.selLine or c.line)
    local file, time = '—', nil
    if item.id == 'start_reference' and model.memory then
      file = tostring(model.memory.file)
      time = model.memory.time
    elseif item.id == 'start_mine' then
      file = (d and d.setup and d.setup.name) or L.t('setup en cours')
      time = mineNow(app, kind)
    elseif item.id == 'start_default' then
      file = L.t('setup d\'origine')
    end
    text('mono', 10.5, fitted('mono', 10.5, file, each - 110), bx + 14, by + h1 - 21, rec and c.blueSoft or c.grey)
    local ts = (Util.isFinite(time) and time > 0) and X.U.lapTime(time) or '—'
    text('button', 15, ts, bx + each - 14 - measure('button', 15, ts), by + h1 - 23, rec and c.best or c.grey)
    if clicked then apply(item.a.intent) end
    tip(item.a.tip)
  end
  return h
end

-- circuit (longueur, virages, ligne droite) et conditions prises en compte (air, piste, grip, état, part du tour)
local function trackPanels(x, y, w, wide, dry)
  local app, c = X.app, X.c
  local d = app.discovery
  local p = d and d.trackProfile
  local cond = d and d.conditions
  if p == nil and cond == nil then return 0 end
  local cols = wide and 2 or 1
  local each = (w - 8 * (cols - 1)) / cols
  local h1 = 176
  local h = cols == 2 and h1 or (2 * h1 + 8)
  if dry then return h end
  -- circuit
  panel(x, y, x + each, y + h1)
  local px = x + 14
  text('section', 14, up(L.t('Circuit')), px, y + 12, c.light)
  lab('ligne IA · fast_lane.ai', px + measure('section', 14, up(L.t('Circuit'))) + 10, y + 14)
  if p then
    lab('Longueur', px, y + 40)
    local lw = text('display', 22, Util.fmt((p.length or 0) / 1000, 2), px, y + 54, c.light)
    text('section', 13, 'km', px + lw + 4, y + 61, c.grey)
    lab('Virages', px, y + 86)
    local vw = text('display', 22, tostring(p.corners), px, y + 100, c.light)
    text('section', 13, L.f(p.chicanes == 1 and '· %s chicane' or '· %s chicanes', p.chicanes), px + vw + 6, y + 107, c.grey)
    local bx = x + each - 14 - 112
    local function n(count, one, many) return L.f(count == 1 and one or many, count) end
    local items = { { c.blue, n(p.lent, '%s lent', '%s lents'), '< ' .. K.slowCornerKmh },
      { c.light, n(p.moyen, '%s moyen', '%s moyens'), '' }, { c.fast, n(p.rapide, '%s rapide', '%s rapides'), '> ' .. K.fastCornerKmh } }
    for i, it in ipairs(items) do
      local iy = y + 44 + (i - 1) * 20
      rect(bx, iy + 4, bx + 7, iy + 11, it[1])
      local iw = text('text', 11.5, it[2], bx + 13, iy, c.light)
      if it[3] ~= '' then text('text', 11.5, it[3], bx + 13 + iw + 6, iy, c.grey) end
    end
    rect(px, y + h1 - 30, x + each - 14, y + h1 - 29, c.line)
    local s = L.t('Plus longue ligne droite')
    local sw = text('text', 11.5, s, px, y + h1 - 22, c.grey)
    text('bold', 11.5, Util.fmt(p.longest, 0) .. ' m', px + sw + 8, y + h1 - 22, c.light)
  end
  -- pris en compte
  local qx = cols == 2 and (x + each + 8) or x
  local qy = cols == 2 and y or (y + h1 + 8)
  panel(qx, qy, qx + each, qy + h1)
  px = qx + 14
  text('section', 14, up(L.t('Pris en compte')), px, qy + 12, c.light)
  local s = up(L.t('recalcul s\'ils changent'))
  lab('recalcul s\'ils changent', qx + each - 14 - measure('label', 11, s), qy + 14)
  local tw = (each - 28 - 15) / 4
  local wet = app.wet and app.wet.state == 'pluie'
  local tilesList = {
    { 'Air', cond and Util.isFinite(cond.airTemp) and (Util.fmt(cond.airTemp, 0) .. '°') or '—' },
    { 'Piste', cond and Util.isFinite(cond.roadTemp) and (Util.fmt(cond.roadTemp, 0) .. '°') or '—' },
    { 'Grip', cond and Util.isFinite(cond.roadGrip) and (Util.fmt(cond.roadGrip * 100, 0) .. '%') or '—' },
    { 'État', L.t(wet and 'Pluie' or 'Sec') },
  }
  for i, t in ipairs(tilesList) do
    local tx = px + (i - 1) * (tw + 5)
    rect(tx, qy + 36, tx + tw, qy + 78, c.tile)
    lab(t[1], tx + 8, qy + 43, c.grey, 9.5)
    text('button', 19, up(t[2]), tx + 8, qy + 56, c.light)
  end
  local stats = p and p.stats
  if stats then
    lab('Part du tour', px, qy + 90)
    local list = { { 'Pleine charge', stats.power }, { 'Freinage', stats.brake }, { 'Virages rapides', stats.fast },
      { 'Virages lents', stats.slow } }
    for i, it in ipairs(list) do
      local ly = qy + 106 + (i - 1) * 16
      text('text', 11.5, L.t(it[1]), px, ly, c.light)
      local bx, bw = px + 100, each - 28 - 100 - 40
      rect(bx, ly + 5, bx + bw, ly + 11, c.trackBg)
      rect(bx, ly + 5, bx + bw * Util.clamp(it[2] or 0, 0, 1), ly + 11, c.light)
      local ps = Util.fmt((it[2] or 0) * 100, 0) .. '%'
      text('mono', 10.5, ps, qx + each - 14 - measure('mono', 10.5, ps), ly + 1, c.light)
    end
  end
  return h
end

-- ---------------------------------------------------------------------------
-- Page d'un calcul (QUALIF ; COURSE après sa planche)
-- ---------------------------------------------------------------------------

local function kindPage(kind, x, y, w)
  local app = X.app
  local wide = w >= K.uiDashWide
  local cy = y
  local model = X.U.stepModel(app, kind == 'race' and 'Course' or 'Tour rapide')
  cy = cy + statusRow(x, cy, w) + 8
  if app.ui.message then cy = cy + messageBar(L.t(app.ui.message), x, cy, w, 'info') + 8 end
  if model then cy = cy + stepCard(model, kind, x, cy, w, wide) + 8 end
  cy = cy + pinsBar(kind, x, cy, w)
  local r = app.refine and app.refine.kind == kind and app.refine or nil
  local q = app[kind]
  local res = q and q.state == 'done' and q.result or nil
  local e = model and focusVersion(model, r) or nil
  if e == nil and r then
    for i = #r.history, 1, -1 do
      if r.history[i].version then
        e = r.history[i]
        break
      end
    end
  end
  if model and model.step == 1 and model.actions[1] then
    cy = cy + picksRow(model, kind, x, cy, w, wide) + 8
    cy = cy + trackPanels(x, cy, w, wide) + 8
  else
    -- résultat du dernier calcul, sinon celui de la version (une découverte efface le résultat après un chargement)
    local result = res or (e and e.view) or nil
    local leftW = wide and math.floor((w - 8) * 0.53) or w
    local rightW = wide and (w - 8 - leftW) or w
    local hL = changesPanel(kind, e, result, x, cy, leftW, true)
    local d = app.discovery
    local current = d and d.simCurrent and d.simCurrent.profile
    local hB = balancePanel(result, 0, 0, rightW, true)
    local hT = tyresPanel(result, 0, 0, rightW, true)
    local mkey = e and (kind .. '_' .. e.version) or nil
    local editing = wide and e and (e.status == nil or e.status == 'essai') and app.ui.modify and app.ui.modify[mkey] == true
    if editing then
      cy = cy + changesPanel(kind, e, result, x, cy, w) + 8
      local half = math.floor((w - 8) / 2)
      local hRow = math.max(hB, hT)
      if hRow > 0 then
        if hB > 0 then balancePanel(result, x, cy, half) end
        if hT > 0 then tyresPanel(result, x + half + 8, cy, w - half - 8) end
        cy = cy + hRow + 8
      end
      local hs = speedPanel(result, current, x, cy, w, 110)
      if hs > 0 then cy = cy + hs + 8 end
    elseif wide and (hL > 0 or hB > 0 or hT > 0) then
      local speedH = math.max(96, hL - hB - hT - ((hB > 0 and 8 or 0) + (hT > 0 and 8 or 0)))
      changesPanel(kind, e, result, x, cy, leftW)
      local ry = cy
      if hB > 0 then ry = ry + balancePanel(result, x + leftW + 8, ry, rightW) + 8 end
      if hT > 0 then ry = ry + tyresPanel(result, x + leftW + 8, ry, rightW) + 8 end
      ry = ry + speedPanel(result, current, x + leftW + 8, ry, rightW, speedH)
      cy = math.max(cy + hL, ry) + 8
    else
      if hL > 0 then cy = cy + changesPanel(kind, e, result, x, cy, w) + 8 end
      if hB > 0 then cy = cy + balancePanel(result, x, cy, w) + 8 end
      if hT > 0 then cy = cy + tyresPanel(result, x, cy, w) + 8 end
      local hs = speedPanel(result, current, x, cy, w, 110)
      if hs > 0 then cy = cy + hs + 8 end
    end
  end
  local hv = versionsPanel(kind, r, x, cy, w)
  if hv > 0 then cy = cy + hv + 8 end
  cy = cy + toolsPanel(kind, x, cy, w) + 8
  return cy - y
end
M.kindPage = kindPage


-- ---------------------------------------------------------------------------
-- Onglet COURSE (planches « sans qualif validée », « départ », « essayer v1 »)
-- ---------------------------------------------------------------------------

-- sans qualification validée : la course part d'elle (mêmes action et identifiant que la carte d'étape de la course)
local NO_QUALI = { title = 'Course · avant le calcul', actions = { { label = 'Affiner le tour rapide###step_quali',
  intent = { refineStart = 'quali' }, tab = 'Tour rapide',
  tip = 'Lance l\'affinage du setup de tour rapide (onglet QUALIF), même en séance de course.' } } }
local function noQualiCard(model, x, y, w, dry)
  local c = X.c
  local h = 150
  if dry then return h end
  panel(x, y, x + w, y + h)
  local px = x + 18
  rect(px, y + 18, px + 4, y + 36, c.warn)
  lab(model.title, px + 12, y + 21, c.warn)
  text('button', 26, up(L.t('Validez d\'abord une qualif')), px, y + 44, c.light)
  textBox('text', 12.5, L.t('La course part d\'un setup de qualification SetupLab validé (au moins une v1). Vos tours avec lui '
    .. 'donnent votre rythme.'), px, y + 78, w - 36, c.soft)
  local bx = px
  for _, a in ipairs(model.actions) do
    local vis = up(L.t((Skin.split(a.label))))
    local bw = measure('button', 14, vis) + 44
    if button(a.label, bx, y + h - 46, bw, 32, 'primary', 14) then
      apply(a.intent)
      if a.tab then X.app.ui.tab = a.tab end
    end
    tip(a.tip)
    bx = bx + bw + 8
  end
  if button('Aller à l\'onglet QUALIF###goto_quali', bx, y + h - 46, 200, 32, nil, 14) then X.app.ui.tab = 'Tour rapide' end
  return h
end

-- départ de la course : qualifs validées au choix, nombre de tours, partir ; ou reprendre une course validée
local function raceStartCard(x, y, w, wide, dry)
  local app, c = X.app, X.c
  local choices = app.raceChoices and app.raceChoices() or {}
  local list = {}
  for _, ch in ipairs(choices) do
    if ch.loadable or ch.inCar then list[#list + 1] = ch end
  end
  local race = app.memory and app.memory['course|' .. bucketOf(app)]
  local resume = race and race.text and not race.problem and race or nil
  local rowH = 40
  local px, pw = x + 16, w - 32
  -- vos setups de qualification du dossier, pas chargeables par SetupLab : à charger depuis le menu de setup d'AC
  local others = nil
  if #list == 0 and app.qualiFiles then
    local names = {}
    for _, f in ipairs(app.qualiFiles()) do names[#names + 1] = f.file end
    if #names > 0 then
      others = L.f('Vos setups de qualification sur ce circuit : %s. Chargez celui de votre choix depuis le menu de setup '
        .. 'd\'AC : SetupLab le reconnaît et la course part de lui.', table.concat(names, ', '))
    end
  end
  local why = app.raceBlocker and app.raceBlocker() or nil
  local whyS = why and (L.t('À faire : ') .. L.t(why) .. '.') or nil
  local othersH = others and (textBox('text', 12, others, 0, 0, pw, c.soft, true) + 8) or 0
  local whyH = whyS and (textBox('text', 11.5, whyS, 0, 0, pw, c.warn, true) + 6) or 0
  local titleH = textBox('display', wide and 30 or 26, up(L.t('De quelle qualif part-on ?')), 0, 0, pw, c.light, true) + 8
  local h = 14 + 15 + titleH + (others and othersH or math.max(1, #list) * (rowH + 4)) + 12 + 40 + (#list > 0 and 52 or 0)
    + whyH + (resume and 70 or 0) + 12
  if dry then return h end
  panel(x, y, x + w, y + h)
  local cy = y + 14
  lab('Étape 1 / 4 · Départ de la course', px, cy, c.blueSoft)
  local s = up(L.t('relais · carburant · usure · trafic'))
  lab('relais · carburant · usure · trafic', px + pw - measure('label', 11, s), cy)
  cy = cy + 15
  cy = cy + textBox('display', wide and 30 or 26, up(L.t('De quelle qualif part-on ?')), px, cy, pw, c.light) + 8
  -- qualifs validées (la sélection : celle dans la voiture, sinon la plus récente)
  app.ui.raceChoice = app.ui.raceChoice or nil
  local selected = nil
  for _, ch in ipairs(list) do
    if ch.file == app.ui.raceChoice then selected = ch end
  end
  if selected == nil then
    for _, ch in ipairs(list) do if ch.inCar and selected == nil then selected = ch end end
  end
  selected = selected or list[1]
  if others then
    cy = cy + textBox('text', 12, others, px, cy, pw, c.soft) + 8
  elseif #list == 0 then
    textBox('text', 12.5, L.t('Aucune qualification validée sur ce circuit : onglet QUALIF.'), px, cy + 10, pw, c.warn)
    cy = cy + rowH + 4
  end
  for _, ch in ipairs(list) do
    local on = selected and selected.file == ch.file
    X.ui.setCursor(vec(1, X.ox + px, X.oy + cy))
    if X.ui.invisibleButton('###race_pick_' .. ch.file, vec(3, pw, rowH)) then app.ui.raceChoice = ch.file end
    local hot = hovered()
    rect(px, cy, px + pw, cy + rowH, on and c.select or (hot and c.rowHover or c.tile))
    if on then X.ui.drawRect(vec(1, X.ox + px, X.oy + cy), vec(2, X.ox + px + pw, X.oy + cy + rowH), c.blue, 0, 0, 1) end
    dot(px + 14, cy + rowH / 2, 5, on and c.blue or c.dim)
    local vw = text('display', 20, 'v' .. tostring(ch.version), px + 28, cy + 9, c.light)
    text('mono', 10.5, fitted('mono', 10.5, ch.file, pw - vw - 190), px + 28 + vw + 12, cy + 7, on and c.blueSoft or c.grey)
    if ch.inCar then lab('dans la voiture', px + 28 + vw + 12, cy + 23, c.go, 10) end
    cy = cy + rowH + 4
  end
  -- nombre de tours : − curseur +
  cy = cy + 8
  lab('Tours de la course', px, cy + 8)
  local laps = app.raceLaps or 0
  local sx = px + 150
  if button('−###race_laps_minus', sx, cy, 30, 28, nil, 16) and laps > 1 then X.intents.raceLaps = laps - 1 end
  if X.ui.slider then
    X.ui.setCursor(vec(1, X.ox + sx + 34, X.oy + cy + 2))
    Util.call(X.ui.setNextItemWidth, 90)
    local ok, value, changed = Util.call(X.ui.slider, '###race_laps', laps, 0, 150, '%.0f', true)
    if ok and changed then
      local n = math.floor((tonumber(value) or 0) + 0.5)
      if n >= 1 and n ~= laps then X.intents.raceLaps = n end
    end
    tip('Nombre de tours de la course à préparer (carburant, usure, relais), gardé pour cette voiture sur ce circuit. '
      .. 'Ctrl + clic pour saisir une valeur au clavier.')
  end
  if button('+###race_laps_plus', sx + 128, cy, 30, 28, nil, 16) then X.intents.raceLaps = math.max(1, laps + 1) end
  local hint = X.U.sessionRaceLaps(app)
  local hs = hint and L.f('prévu par la séance : %s tours · gardé pour ce circuit', hint) or L.t('gardé pour ce circuit')
  text('text', 11, fitted('text', 11, hs, pw - 330), sx + 170, cy + 7, c.grey)
  cy = cy + 40
  -- partir
  if selected then
    local label = 'Partir de la qualif v' .. tostring(selected.version) .. '###race_from_' .. selected.file
    local bw = math.min(pw, 280)
    if button(label, px, cy, bw, 40, 'primary', 16, 'left') then X.intents.raceFrom = selected.file end
    tip('En un clic : ' .. selected.file .. ' va dans la voiture et la v1 de course se calcule.')
    local parts = loadState('quali')
    local tx = px + bw + 14
    text('text', 11.5, fitted('text', 11.5, L.f('En un clic : v%s va dans la voiture et la v1 de course se calcule.',
      selected.version), pw - bw - 14), tx, cy + 4, c.soft)
    if parts then conditions(parts, tx, cy + 22, x + w - 16 - tx) end
    cy = cy + 52
  end
  if whyS then cy = cy + textBox('text', 11.5, whyS, px, cy, pw, c.warn) + 6 end
  if resume then
    rect(px, cy, px + pw, cy + 1, c.line)
    lab('ou', px, cy + 8)
    text('button', 18, up(L.f('Reprendre ma course v%s', tostring(resume.version))), px, cy + 24, c.light)
    text('mono', 10.5, fitted('mono', 10.5, tostring(resume.file), pw - 200), px, cy + 46, c.grey)
    if button('Reprendre v' .. tostring(resume.version) .. '###race_resume', px + pw - 150, cy + 22, 150, 32, 'go', 14) then
      X.intents.raceResume = 'course|' .. bucketOf(app)
    end
    tip(tostring(resume.file) .. ' va dans la voiture et l\'affinage de la course reprend de lui.')
  end
  return h
end

-- stratégie d'arrêt : menu d'arrêt rapide réglé au dernier chargement du setup de course
local function pitPanel(x, y, w, dry)
  local pit = X.app.pitStrategy
  if pit == nil or pit.note == nil then return 0 end
  local c = X.c
  local h = 14 + 16 + textBox('text', 12, L.t(pit.note), 0, 0, w - 28 - 60, c.light, true) + 14
  if dry then return h end
  panel(x, y, x + w, y + h)
  lab('Stratégie d\'arrêt', x + 14, y + 12)
  textBox('text', 12, L.t(pit.note), x + 14, y + 30, w - 28 - 60, pit.ok and c.light or c.warn)
  local s = up(L.t(pit.ok and 'relu' or 'non écrit'))
  text('section', 11, s, x + w - 14 - measure('section', 11, s), y + 12, pit.ok and c.go or c.warn)
  return h
end

-- relais : écart au meilleur tour, tour par tour ; arrêt ; carburant, usure, équilibre
local function stintPanel(r, x, y, w, dry)
  local race, s = r and r.race, r and r.stintProposed
  if race == nil then return 0 end
  local c = X.c
  local chartH = (s and s.laps and #s.laps > 1) and 60 or 0
  local h = 14 + 16 + chartH + 10 + 3 * 18 + 12
  if dry then return h end
  panel(x, y, x + w, y + h)
  local px, pw = x + 14, w - 28
  local title = L.f('Relais · %s tours', race.laps) .. (race.stops > 0 and L.f(' · %s arrêt(s)', race.stops) or '')
  text('section', 13, up(title), px, y + 11, c.light)
  local cy = y + 32
  if chartH > 0 then
    local laps = s.laps
    local worst = 0
    for i = 1, #laps do worst = math.max(worst, laps[i] - s.best) end
    worst = math.max(worst, 0.1)
    local bw = pw / #laps
    for i = 1, #laps do
      local frac = (laps[i] - s.best) / worst
      local bh = math.max(2, frac * (chartH - 14))
      local crit = s.critical and i >= s.critical
      rect(px + (i - 1) * bw + 1, cy + chartH - bh, px + i * bw - 1, cy + chartH, crit and c.warn or c.blue)
    end
    if race.stops > 0 and race.stintLaps and race.stintLaps < #laps then
      local sx = px + race.stintLaps * bw
      rect(sx, cy, sx + 2, cy + chartH, c.light)
      lab(L.f('Stand · T%s', race.stintLaps), sx + 6, cy, c.light, 10)
    end
    text('text', 10, L.t('écart au meilleur tour'), px, cy - 2, c.grey)
    cy = cy + chartH + 10
  end
  local function row(label, value, color)
    lab(label, px, cy + 3, c.grey, 10)
    text('text', 12, fitted('text', 12, value, pw - 96), px + 96, cy, color or c.light)
    cy = cy + 18
  end
  row('Carburant', Util.fmt(race.fuelFrom, 0) .. ' › ' .. Util.fmt(race.fuelStart, 0) .. ' L · ' .. Util.fmt(race.fuelPerLap, 2)
    .. ' L/' .. L.t('tour') .. ' · ' .. L.t('marge') .. ' ' .. Util.fmt(race.margin * 100, 0) .. ' %')
  row('Usure', Util.fmt(race.kmPerLapF, 2) .. ' / ' .. Util.fmt(race.kmPerLapR, 2) .. ' ' .. L.t('km virtuels par tour') .. ' ('
    .. L.t(race.kmSource) .. ')', race.kmSource == 'mesure' and c.light or c.warn)
  if s then
    row('Équilibre', Util.fmt(s.balanceFirst, 2) .. ' ' .. L.t('au T1') .. ' › ' .. Util.fmt(s.balanceLast, 2) .. ' '
      .. L.f('au T%s', race.laps) .. ' · ' .. (s.critical and L.f('tour critique %s', s.critical) or L.t('aucun tour critique')),
      s.critical and c.warn or c.light)
  end
  return h
end

-- pneus (par essieu) et trafic : pression à chaud, température ; tours en trafic, aspiration, effet
local function trafficPanel(r, x, y, w, dry)
  local race, t = r and r.race, r and r.tyres
  if race == nil then return 0 end
  local c = X.c
  local h = 14 + 16 + (t and 54 or 0) + 2 * 18 + 12
  if dry then return h end
  panel(x, y, x + w, y + h)
  local px, pw = x + 14, w - 28
  lab('Pneus · trafic', px, y + 12)
  local name = r.compound and r.compound.name
  if name then
    local s = up(tostring(name))
    text('section', 11.5, s, x + w - 14 - measure('section', 11.5, s), y + 11, c.light)
  end
  local cy = y + 32
  if t and t.F and t.R then
    local tw = (pw - 6) / 2
    for i, axle in ipairs({ 'F', 'R' }) do
      local e = t[axle]
      local tx = px + (i - 1) * (tw + 6)
      rect(tx, cy, tx + tw, cy + 46, c.tile)
      local temp = e.temp and (' · ' .. Util.fmt(e.temp, 0) .. ' °C') or ''
      lab((axle == 'F' and L.t('Avant') or L.t('Arrière')) .. temp, tx + 8, cy + 7, c.grey, 9.5)
      local hot = Util.fmt(e.hotProposed, 1)
      local hw = measure('display', 19, hot)
      text('display', 19, hot, tx + tw - 8 - hw - 24, cy + 20, c.light)
      text('mono', 10, 'psi', tx + tw - 8 - 20, cy + 27, c.grey)
      local cur = Util.fmt(e.hotCurrent, 1) .. '›'
      text('mono', 10, cur, tx + tw - 8 - hw - 28 - measure('mono', 10, cur), cy + 27, c.grey)
    end
    cy = cy + 54
  end
  local function row(label, value)
    lab(label, px, cy + 3, c.grey, 10)
    text('text', 12, fitted('text', 12, value, pw - 120), px + 120, cy, c.light)
    cy = cy + 18
  end
  row('Tours en trafic', Util.fmt(race.trafficFraction * 100, 0) .. ' %')
  row('Aspiration', '×' .. Util.fmt(race.slipstream, 2) .. ' · ' .. L.t('effet') .. ' ' .. Util.fmt(r.traffic or 0, 3) .. ' s/'
    .. L.t('tour'))
  return h
end

local function racePage(x, y, w)
  local app = X.app
  local wide = w >= K.uiDashWide
  local cy = y
  cy = cy + statusRow(x, cy, w) + 8
  if app.ui.message then cy = cy + messageBar(L.t(app.ui.message), x, cy, w, 'info') + 8 end
  local model = X.U.stepModel(app, 'Course')
  local r = app.refine and app.refine.kind == 'race' and app.refine or nil
  local _, action = nil, nil
  if app.raceBlocker then _, action = app.raceBlocker() end
  if action == 'qualif' then
    local card = (model and model.kind == 'race') and model or NO_QUALI
    cy = cy + noQualiCard(card, x, cy, w) + 8
    return cy - y
  end
  if not (r and r.active) then
    cy = cy + raceStartCard(x, cy, w, wide) + 8
  elseif model then
    cy = cy + stepCard(model, 'race', x, cy, w, wide) + 8
  end
  cy = cy + pinsBar('race', x, cy, w)
  local q = app.race
  local res = q and q.state == 'done' and q.result or nil
  local e = model and focusVersion(model, r) or nil
  if e == nil and r then
    for i = #r.history, 1, -1 do
      if r.history[i].version then
        e = r.history[i]
        break
      end
    end
  end
  local result = res or (e and e.view) or nil
  local hp = pitPanel(x, cy, w, true)
  if hp > 0 then cy = cy + pitPanel(x, cy, w) + 8 end
  local hs, ht = stintPanel(result, 0, 0, w, true), trafficPanel(result, 0, 0, w, true)
  if wide and hs > 0 then
    local leftW = math.floor((w - 8) * 0.56)
    local hh = math.max(hs, ht)
    stintPanel(result, x, cy, leftW)
    trafficPanel(result, x + leftW + 8, cy, w - leftW - 8)
    cy = cy + hh + 8
  else
    if hs > 0 then cy = cy + stintPanel(result, x, cy, w) + 8 end
    if ht > 0 then cy = cy + trafficPanel(result, x, cy, w) + 8 end
  end
  local hc = changesPanel('race', e, result, x, cy, w)
  if hc > 0 then cy = cy + hc + 8 end
  if result and result.race then
    text('text', 11.5, L.t('Carburant et réparations de l\'arrêt restent les vôtres.'), x + 2, cy, X.c.grey)
    cy = cy + 22
  end
  local hv = versionsPanel('race', r, x, cy, w)
  if hv > 0 then cy = cy + hv + 8 end
  cy = cy + toolsPanel('race', x, cy, w) + 8
  return cy - y
end
M.racePage = racePage


-- ---------------------------------------------------------------------------
-- Petites commandes : interrupteur de réglage, pas à pas avec curseur, titre de panneau
-- ---------------------------------------------------------------------------

local function panelTitle(s, x, y, right)
  text('section', 14, up(L.t(s)), x, y, X.c.light)
  if right then
    local r = up(L.t(right))
    lab(right, X.cw - 14 - measure('label', 11, r), y + 2)
  end
end

-- interrupteur d'un réglage de l'app (identifiant : son libellé, comme la case ImGui)
local function settingSwitch(def, value, x, y)
  local c = X.c
  X.ui.setCursor(vec(1, X.ox + x, X.oy + y))
  local clicked = X.ui.invisibleButton('###' .. def.label, vec(3, 34, 18))
  X.ui.drawRectFilled(vec(1, X.ox + x, X.oy + y), vec(2, X.ox + x + 34, X.oy + y + 18), value and c.blue or c.switchOff, 9)
  dot(value and (x + 25) or (x + 9), y + 9, 6, value and c.knobOn or c.grey)
  if clicked then X.intents.setting = { key = def.key, value = not value } end
end

-- pas d'un réglage numérique
local function stepOf(def)
  if def.kind == 'integer' then
    local span = (def.max or 1) - (def.min or 0)
    return span > 2000 and 100 or (span > 300 and 10 or 1)
  end
  local span = (def.max or 1) - (def.min or 0)
  return span <= 1 and 0.05 or (span <= 20 and 0.5 or 1)
end

-- − curseur + d'un réglage numérique (curseur : identifiant = son libellé, Ctrl + clic pour saisir)
local function settingStepper(def, value, x, y, w)
  local stepV = stepOf(def)
  local function set(v)
    v = math.max(def.min or v, math.min(def.max or v, v))
    if def.kind == 'integer' then v = math.floor(v + 0.5) else v = math.floor(v / stepV + 0.5) * stepV end
    if v ~= value then X.intents.setting = { key = def.key, value = v } end
  end
  if button('−###dec_' .. def.key, x, y, 26, 24, nil, 15) then set((value or 0) - stepV) end
  if X.ui.slider then
    X.ui.setCursor(vec(1, X.ox + x + 30, X.oy + y))
    Util.call(X.ui.setNextItemWidth, w - 60)
    local ok, nextValue, changed = Util.call(X.ui.slider, '###' .. def.label, value, def.min, def.max,
      def.kind == 'integer' and '%.0f' or '%.2f', def.kind == 'integer' and true or 1)
    if ok and changed and nextValue ~= value then X.intents.setting = { key = def.key, value = nextValue } end
  end
  if button('+###inc_' .. def.key, x + w - 26, y, 26, 24, nil, 15) then set((value or 0) + stepV) end
end

-- une ligne de réglage : libellé à gauche (revient à la ligne), commande à droite ; renvoie sa hauteur
local function settingRow(key, x, y, w, dry)
  local def = Config.byKey[key]
  if def == nil then return 0 end
  local app, c = X.app, X.c
  local ctrlW = def.kind == 'boolean' and 34 or 190
  local lh = textBox('text', 12.5, L.t(def.label), 0, 0, w - ctrlW - 16, c.light, true)
  local h = math.max(26, lh + 6)
  if dry then return h end
  textBox('text', 12.5, L.t(def.label), x, y + 3, w - ctrlW - 16, c.light)
  X.ui.setCursor(vec(1, X.ox + x, X.oy + y))
  X.ui.invisibleButton('###row_' .. key, vec(3, w - ctrlW - 16, h))
  tip(Config.help[key])
  local value = app.settings[key]
  if def.kind == 'boolean' then
    settingSwitch(def, value == true, x + w - 34, y + (h - 18) / 2)
  else
    settingStepper(def, value, x + w - ctrlW, y + (h - 24) / 2, ctrlW)
  end
  rect(x, y + h, x + w, y + h + 1, c.rowLine)
  return h + 1
end

-- panneau de réglages : titre, lignes ; renvoie sa hauteur
local function settingsPanel(title, right, keys, x, y, w, dry)
  local h = 40
  for _, key in ipairs(keys) do h = h + settingRow(key, 0, 0, w - 28, true) end
  h = h + 10
  if dry then return h end
  panel(x, y, x + w, y + h)
  X.cw = x + w
  panelTitle(title, x + 14, y + 12, right)
  local cy = y + 36
  for _, key in ipairs(keys) do cy = cy + settingRow(key, x + 14, cy, w - 28) end
  return h
end

-- ---------------------------------------------------------------------------
-- Onglet MÉMOIRE (planche « setups du circuit »)
-- ---------------------------------------------------------------------------

local MEM_ROWS = {
  { key = 'qualif', title = 'Qualif', sub = 'qualification' },
  { key = 'essai', title = 'Essai', sub = 'essai · journée circuit · hotlap' },
  { key = 'course', title = 'Course', sub = 'relais complet' },
}

-- une case : setup validé, figé, fichier absent ou vide ; boutons Charger, Figer / Déverrouiller (identifiants ImGui)
local function memoryCell(row, bucket, x, y, w, h)
  local app, c = X.app, X.c
  local key = row.key .. '|' .. bucket
  local id = row.key .. '_' .. bucket
  local m = app.memory and app.memory[key]
  rect(x, y, x + w, y + h, m and (m.problem and c.badBg or (m.locked and c.select or c.okBg)) or c.tile)
  local px = x + 12
  if m == nil then
    lab('Vide', px, y + 10, c.grey)
    textBox('text', 11.5, L.t(bucket == 'pluie' and 'Aucun setup validé sur piste mouillée.' or 'Aucun setup validé sur piste sèche.'),
      px, y + 28, w - 24, c.grey)
    return
  end
  local status = m.problem and L.t('Validé · fichier absent') or (L.t(m.locked and 'Figé' or 'Validé')
    .. (m.version and (' · v' .. m.version) or ''))
  lab(status, px, y + 10, m.problem and c.badInk or (m.locked and c.blueSoft or c.go))
  text('mono', 10.5, fitted('mono', 10.5, tostring(m.file), w - 24), px, y + 28, c.soft)
  if m.problem then
    textBox('text', 11, L.t(m.problem), px, y + 46, w - 24, c.badInk)
  else
    local tv = (Util.isFinite(m.time) and m.time > 0) and X.U.lapTime(m.time) or '—'
    local tw = text('display', 20, tv, px, y + 44, row.key == 'course' and c.light or c.best)
    lab(row.key == 'course' and 'votre tour moyen' or (m.locked and 'affinage arrêté' or 'votre meilleur'), px + tw + 8, y + 52,
      c.grey, 10)
  end
  local by = y + h - 32
  local bx = px
  if m.text then
    if button('Charger###memload_' .. id, bx, by, 96, 24, 'go', 12) then X.intents.memoryLoad = key end
    tip(X.U.LOAD_TIP)
    bx = bx + 102
  end
  local lock = (m.locked and 'Déverrouiller' or 'Figer (cadenas)') .. '###memlock_' .. id
  if button(lock, bx, by, m.locked and 120 or 110, 24, nil, 12) then
    X.intents.memoryLock = { key = key, locked = not m.locked }
  end
end

local function memoryPage(x, y, w)
  local app, c = X.app, X.c
  local wide = w >= K.uiDashWide
  local d = app.discovery
  local cy = y
  if app.ui.message then cy = cy + messageBar(L.t(app.ui.message), x, cy, w, 'info') + 8 end
  local intro = L.t('Setups validés ou figés') .. ' · ' .. (d and d.car and tostring(d.car.name) or '') .. ' · '
    .. (d and d.trackFiles and tostring(d.trackFiles.name) or '') .. ' · ' .. L.t('proposés à chaque visite')
  cy = cy + textBox('text', 12, intro, x, cy, w, c.soft) + 10
  -- légende
  local lx = x
  for _, it in ipairs({ { c.go, 'validé' }, { c.blue, 'figé' }, { c.dim, 'vide' } }) do
    rect(lx, cy + 3, lx + 8, cy + 11, it[1])
    lx = lx + 14 + text('text', 11, L.t(it[2]), lx + 12, cy, c.grey) + 14
  end
  cy = cy + 22
  local cellH = 112
  local leftW = wide and 150 or 0
  local colW = wide and (w - leftW - 16) / 2 or w - 28
  local rows = #MEM_ROWS
  local h = 14 + 22 + rows * (wide and (cellH + 8) or (2 * cellH + 26 + 8)) + 6
  panel(x, cy, x + w, cy + h)
  local gy = cy + 14
  if wide then
    lab('Piste sèche', x + 14 + leftW, gy)
    lab('Piste mouillée', x + 14 + leftW + colW + 8, gy)
  end
  gy = gy + 22
  for _, row in ipairs(MEM_ROWS) do
    if wide then
      text('button', 16, up(L.t(row.title)), x + 14, gy + 8, c.light)
      textBox('text', 11, L.t(row.sub), x + 14, gy + 30, leftW - 20, c.grey)
      memoryCell(row, 'sec', x + 14 + leftW, gy, colW - 8, cellH)
      memoryCell(row, 'pluie', x + 14 + leftW + colW, gy, colW - 8, cellH)
      gy = gy + cellH + 8
    else
      text('button', 15, up(L.t(row.title)) .. '  ·  ' .. L.t(row.sub), x + 14, gy, c.light)
      gy = gy + 22
      memoryCell(row, 'sec', x + 14, gy, colW, cellH)
      memoryCell(row, 'pluie', x + 14, gy + cellH + 4, colW, cellH)
      gy = gy + 2 * cellH + 12
    end
  end
  cy = cy + h + 8
  -- pied : conditions du chargement, suivi, rangement des fichiers
  local parts, follow, followColor = loadState('')
  if parts then
    local fx = x + text('text', 11, L.t('Charger') .. L.t(' : '), x, cy, c.grey) + 4
    local cw, ch = conditions(parts, fx, cy, x + w - fx)
    local note = L.t('1 clic · copie de sauvegarde avant si besoin')
    if fx + cw + 8 + measure('text', 11, note) <= x + w then
      text('text', 11, note, fx + cw + 8, cy, c.grey)
      cy = cy + ch + 5
    else
      text('text', 11, fitted('text', 11, note, w), x, cy + ch + 2, c.grey)
      cy = cy + ch + 20
    end
  end
  if app.loadWhere == 'memory' then
    local _, f2, fc2 = loadState(app.lastLoadKind or 'quali')
    follow, followColor = follow or f2, followColor or fc2
  end
  if follow then
    cy = cy + textBox('text', 11.5, follow, x, cy, w, followColor or c.grey) + 6
  end
  local waiting = app.fileOps and #app.fileOps or 0
  if waiting > 0 then
    text('text', 11, L.f('%s fichier(s) à ranger › Corbeille, voiture arrêtée', waiting), x, cy, c.grey)
    cy = cy + 18
  end
  return cy - y
end

-- ---------------------------------------------------------------------------
-- Onglet MESURE (planche « tours & calibration »)
-- ---------------------------------------------------------------------------

local function measurePage(x, y, w)
  local app, c = X.app, X.c
  local wide = w >= K.uiDashWide
  local rec, d = app.recorder, app.discovery
  local cy = y
  if app.ui.message then cy = cy + messageBar(L.t(app.ui.message), x, cy, w, 'info') + 8 end
  if app.storeNote then cy = cy + messageBar(L.t(app.storeNote), x, cy, w, 'warn') + 8 end
  local bucket = bucketOf(app)
  local last = rec and rec.laps.last
  local cal = app.calibration
  local cr = cal and (cal.result or cal.previous)
  local calText, calColor = '—', c.grey
  if cal and cal.state == 'running' then
    calText, calColor = 'en cours', c.warn
  elseif cal and cal.state == 'failed' then
    calText, calColor = 'en échec', c.danger
  elseif cr then
    calText, calColor = cr.usable and 'utilisable' or 'non utilisée', cr.usable and c.go or c.warn
  end
  local own = d and app.recorder and app.recorder.laps.best[(bucket == 'pluie') and (tostring(d.signature) .. '#pluie')
    or d.signature]
  -- tuiles
  local cols = wide and 4 or 2
  local tw = (w - 8 * (cols - 1)) / cols
  local tiles = {
    { last and (last.valid and 'Dernier tour · valide' or 'Dernier tour · rejeté') or 'Dernier tour',
      last and X.U.lapTime(last.time) or '—', last and (last.valid and c.go or c.warn) or c.light },
    { 'Meilleur · setup actuel', own and X.U.lapTime(own.time) or '—', own and c.best or c.light },
    { 'Tours enregistrés', tostring(rec and rec.finished or 0), c.light },
    { 'Calibration', up(L.t(calText)), calColor },
  }
  for i, it in ipairs(tiles) do
    local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
    local tx, ty = x + col * (tw + 8), cy + row * 70
    panel(tx, ty, tx + tw, ty + 62)
    lab(it[1], tx + 12, ty + 10)
    text('display', 24, it[2], tx + 12, ty + 26, it[3])
  end
  cy = cy + math.ceil(#tiles / cols) * 70 + 4
  -- enregistrement en cours, dernier tour rejeté
  if rec then
    local s
    if rec.state == 'enregistrement' then
      s = L.f('Enregistrement du tour en cours : %s points', rec.n) .. (rec.invalid and (' · ' .. L.t('sera rejeté : ')
        .. L.t(tostring(rec.invalid))) or '')
    else
      s = L.t('Enregistrement : en attente du prochain passage de la ligne.')
    end
    cy = cy + messageBar(s, x, cy, w, rec.invalid and 'warn' or 'info') + 8
    if last and not last.valid then
      cy = cy + messageBar(L.t('Dernier tour : ') .. X.U.lapTime(last.time) .. ' — ' .. L.t('rejeté : ') .. L.t(tostring(last.reason)),
        x, cy, w, 'warn') + 8
    end
  end
  -- meilleur tour par setup (réel, prévu) | facteurs du modèle
  local list = {}
  for signature, known in pairs(app.knownSetups or {}) do
    for _, state in ipairs({ 'sec', 'pluie' }) do
      local best = rec and rec.laps.best[state == 'pluie' and (tostring(signature) .. '#pluie') or signature]
      if best then list[#list + 1] = { label = tostring(known.label), wet = state == 'pluie', time = best.time,
        predicted = state == 'sec' and known.predicted or nil } end
    end
  end
  table.sort(list, function(a, b) return a.time < b.time end)
  local leftW = wide and math.floor((w - 8) * 0.55) or w
  local rightW = wide and (w - 8 - leftW) or w
  local hl = 40 + math.max(1, #list) * 24 + 10
  local hr = cr and (40 + #X.U.FACTOR_ORDER * 24 + 30) or 0
  local function bestPanel(px, py, pw)
    panel(px, py, px + pw, py + hl)
    X.cw = px + pw
    panelTitle('Meilleur tour par setup', px + 14, py + 12, 'réel · prévu')
    local ry = py + 38
    if #list == 0 then text('text', 12, L.t('Aucun tour valide pour l\'instant.'), px + 14, ry, c.grey) end
    for _, it in ipairs(list) do
      local name = it.label .. (it.wet and (' · ' .. L.t('mouillée')) or '')
      text('text', 12, fitted('text', 12, name, pw - 28 - 150), px + 14, ry + 3, c.light)
      local rt = X.U.lapTime(it.time)
      text('mono', 11, rt, px + pw - 14 - 150, ry + 4, c.light)
      text('mono', 11, it.predicted and X.U.lapTime(it.predicted) or '—', px + pw - 14 - 70, ry + 4, c.grey)
      rect(px + 14, ry + 22, px + pw - 14, ry + 23, c.rowLine)
      ry = ry + 24
    end
  end
  local function factorsPanel(px, py, pw)
    panel(px, py, px + pw, py + hr)
    X.cw = px + pw
    panelTitle('Facteurs du modèle', px + 14, py + 12, '0.90 · 1.00 · 1.10')
    local ry = py + 38
    for _, key in ipairs(X.U.FACTOR_ORDER) do
      local v = cr.factors[key]
      local state = cr.atBound[key] and 'En butée' or (cr.identified[key] and 'Identifié' or 'Non identifié')
      local sc = cr.atBound[key] and c.warn or (cr.identified[key] and c.go or c.grey)
      text('text', 12, fitted('text', 12, L.t(X.U.FACTOR_LABELS[key]), 90), px + 14, ry + 2, c.light)
      local bx, bw = px + 110, pw - 110 - 14 - 140
      rect(bx, ry + 7, bx + bw, ry + 13, c.trackBg)
      local mid = bx + bw / 2
      rect(mid, ry + 4, mid + 1, ry + 16, c.dim)
      local f = Util.clamp(((v or 1) - 0.9) / 0.2, 0, 1)
      dot(bx + f * bw, ry + 10, 4, sc)
      text('mono', 11, Util.fmt(v, 3), bx + bw + 10, ry + 3, c.light)
      text('section', 10.5, up(L.t(state)), px + pw - 14 - measure('section', 10.5, up(L.t(state))), ry + 4, sc)
      ry = ry + 24
    end
    local d2 = app.discovery
    local index = d2 and d2.compoundIndex or -1
    local current = d2 and app.calibrations and app.calibrations[bucket == 'pluie' and (tostring(index) .. '#pluie') or index]
    if current and current.result and current.result.stored then
      text('text', 11, fitted('text', 11, L.t('Reprise d\'une séance précédente.'), pw - 28), px + 14, ry + 4, c.grey)
    end
  end
  if wide and hr > 0 then
    bestPanel(x, cy, leftW)
    factorsPanel(x + leftW + 8, cy, rightW)
    cy = cy + math.max(hl, hr) + 8
  else
    bestPanel(x, cy, w)
    cy = cy + hl + 8
    if hr > 0 then
      factorsPanel(x, cy, w)
      cy = cy + hr + 8
    end
  end
  -- validation du gain réel
  for _, kind in ipairs({ 'quali', 'race' }) do
    local v = app.validations and app.validations[kind]
    if v and v.state == 'done' then
      local s = X.U.validationText(v)
      cy = cy + messageBar(L.t('Setup ' .. X.U.KIND[kind].name .. ' — ') .. L.t(s), x, cy, w, v.conforming and 'go' or 'warn') + 8
    end
  end
  -- tours de calibration
  if cr and cr.runs and #cr.runs > 0 then
    local hh = 40 + #cr.runs * 24 + 8
    panel(x, cy, x + w, cy + hh)
    X.cw = x + w
    panelTitle('Tours de calibration', x + 14, cy + 12, L.f('écart de temps · seuil %s %% · profil · seuil %s %%',
      Util.fmt(K.calibMaxTimeError * 100, 0), Util.fmt(K.calibMaxRms * 100, 0)))
    local ry = cy + 38
    for _, one in ipairs(cr.runs) do
      local okT, okR = one.timeError <= K.calibMaxTimeError, one.rms <= K.calibMaxRms
      text('text', 12, fitted('text', 12, L.t(tostring(one.label)), 140), x + 14, ry + 2, c.light)
      text('mono', 11, Util.fmt(one.timeError * 100, 2) .. '%', x + 170, ry + 3, okT and c.go or c.warn)
      text('mono', 11, Util.fmt(one.rms * 100, 1) .. '%', x + 250, ry + 3, okR and c.go or c.warn)
      text('text', 11, fitted('text', 11, L.f('idéal %s s plus rapide', Util.fmt(one.measuredTime - one.idealTime, 2)), w - 340),
        x + 330, ry + 3, c.grey)
      ry = ry + 24
    end
    cy = cy + hh + 8
  end
  -- mesure seule (données de la voiture illisibles)
  local mo = app.measureOnly
  if mo then
    local s = L.t('Mode mesure uniquement (§9.4) : données de la voiture illisibles, modèle estimé sur le tour.')
    if mo.reason then s = s .. ' ' .. L.t('Estimation : ') .. L.t(tostring(mo.reason)) end
    cy = cy + messageBar(s, x, cy, w, 'warn') + 8
  end
  if cal and cal.state == 'failed' then
    cy = cy + messageBar(L.t('Calibration en échec : ') .. L.t(tostring(cal.error)), x, cy, w, 'error') + 8
  end
  -- actions
  local bx = x
  if last then
    if button('Calibrer maintenant', bx, cy, 170, 30, 'primary', 13) then X.intents.calibrate = true end
    bx = bx + 178
    if button('Copier le tour enregistré', bx, cy, 210, 30, nil, 13) then X.intents.copyLap = true end
    tip('Copie le tour (temps, profil, setup) dans le presse-papiers, à coller dans la conversation de développement.')
    bx = bx + 218
  end
  local def = Config.byKey.calibrationAuto
  if def then
    local sw = text('text', 12, fitted('text', 12, L.t('Calibration automatique après chaque tour valide'), x + w - bx - 50), bx,
      cy + 7, c.soft)
    settingSwitch(def, app.settings.calibrationAuto == true, bx + sw + 10, cy + 6)
  end
  cy = cy + 40
  return cy - y
end

-- ---------------------------------------------------------------------------
-- Onglet RÉGLAGES (planche « app & prise en compte »)
-- ---------------------------------------------------------------------------

local function setupStatusPanel(x, y, w)
  local app, c = X.app, X.c
  local d = app.discovery
  if not (d and d.space) then return 0 end
  local rows = SetupSpace.statusRows(d.space)
  local optimized = 0
  for _, row in ipairs(rows) do if row.status == 'optimisé' then optimized = optimized + 1 end end
  local extra = 2
  local h = 40 + 22 + (#rows + extra) * 22 + 12
  panel(x, y, x + w, y + h)
  X.cw = x + w
  local s = L.f('%s optimisés · %s conservés', optimized, #rows - optimized)
  panelTitle('Réglages du setup', x + 14, y + 12)
  text('text', 11.5, s, x + w - 14 - measure('text', 11.5, s), y + 12, c.grey)
  local c1, c2 = x + w - 14 - 230, x + w - 14 - 110
  local ry = y + 38
  lab('Réglage', x + 14, ry)
  lab('Sec', c1, ry)
  lab('Pluie', c2, ry)
  ry = ry + 22
  local function line(label, status, statusColor, wet, wetColor, tipText, idx)
    X.ui.setCursor(vec(1, X.ox + x + 14, X.oy + ry))
    X.ui.invisibleButton('###status_' .. idx, vec(3, w - 28, 20))
    tip(tipText)
    text('text', 12, fitted('text', 12, label, c1 - x - 24), x + 14, ry + 2, c.light)
    text('section', 11, up(L.t(status)), c1, ry + 3, statusColor)
    text('section', 11, up(L.t(wet)), c2, ry + 3, wetColor)
    rect(x + 14, ry + 21, x + w - 14, ry + 22, c.rowLine)
    ry = ry + 22
  end
  for i, row in ipairs(rows) do
    local st = row.status
    local sc = st == 'optimisé' and c.go or ((row.detail and (row.detail:find('rugosité', 1, true)
      or row.detail:find('repère de hauteur', 1, true))) and c.warn or c.grey)
    local ws = row.wetShort or '—'
    local wc = ws == 'modélisé' and c.go or (ws == 'règle' and c.blueSoft or c.grey)
    line(L.t(row.label), st, sc, ws, wc, L.t(row.detail) .. ' (' .. table.concat(row.names, ', ') .. ')', i)
  end
  line(L.t('Composé de pneus'), 'choisi', c.go, 'modélisé', c.go, 'D18 : composés secs comparés', #rows + 1)
  line(L.t('Aides (antipatinage, ABS)'), 'conservé', c.grey, 'règle', c.blueSoft, 'Aides au pilote, non modélisées.', #rows + 2)
  return h
end

local function settingsPage(x, y, w)
  local app, c = X.app, X.c
  local wide = w >= K.uiDashWide
  local cy = y
  if app.ui.message then cy = cy + messageBar(L.t(app.ui.message), x, cy, w, 'info') + 8 end
  -- langue
  lab('Langue', x, cy + 8)
  local lx = x + 90
  for _, item in ipairs({ { 'en', 'English' }, { 'fr', 'Français' } }) do
    local on = app.settings.language == item[1]
    if button(item[2] .. '###lang_' .. item[1], lx, cy, 120, 28, on and 'primary' or nil, 13) then
      X.intents.setting = { key = 'language', value = item[1] }
    end
    tip(Config.help.language)
    lx = lx + 128
  end
  cy = cy + 40
  local half = wide and math.floor((w - 8) / 2) or w
  local proposal = { 'refineInstantFirst', 'refineMinLaps', 'refineMinMinutes', 'refineLaps' }
  local compute = { 'optBudgetEvalsQ', 'optBudgetEvalsC' }
  local strategy = { 'perfStab', 'fuelMarginPct', 'fuelQualiLaps', 'drsTrafficPct', 'driverMarginPct', 'compoundChoice',
    'wetAidLevels', 'calibrationAuto', 'updateCheck' }
  local estimate = X.U.estimateSeconds(app, app.settings.optBudgetEvalsQ, X.U.KIND.quali.lapsPerEval, 'quali')
  local dur = estimate and X.U.durationText(estimate, K.computeTargetQ, X.U.slowFrames(app)) or nil
  if wide then
    local h1 = settingsPanel('Quand SetupLab propose', 'setup en piste', proposal, 0, 0, half, true)
    local h2 = settingsPanel('Calcul', nil, compute, 0, 0, half, true)
    local h3 = settingsPanel('Stratégie', 'gardés d\'une séance à l\'autre', strategy, 0, 0, w - half - 8, true)
    settingsPanel('Quand SetupLab propose', 'setup en piste', proposal, x, cy, half)
    settingsPanel('Calcul', nil, compute, x, cy + h1 + 8, half)
    if dur then text('text', 11, fitted('text', 11, L.t(dur), half - 28), x + 14, cy + h1 + 8 + h2 - 4, c.grey) end
    settingsPanel('Stratégie', 'gardés d\'une séance à l\'autre', strategy, x + half + 8, cy, w - half - 8)
    cy = cy + math.max(h1 + 8 + h2 + (dur and 12 or 0), h3) + 8
  else
    cy = cy + settingsPanel('Quand SetupLab propose', 'setup en piste', proposal, x, cy, w) + 8
    cy = cy + settingsPanel('Calcul', nil, compute, x, cy, w) + 8
    if dur then
      text('text', 11, fitted('text', 11, L.t(dur), w), x, cy - 4, c.grey)
      cy = cy + 12
    end
    cy = cy + settingsPanel('Stratégie', 'gardés d\'une séance à l\'autre', strategy, x, cy, w) + 8
  end
  local hs = setupStatusPanel(x, cy, w)
  if hs > 0 then cy = cy + hs + 8 end
  text('text', 11, L.t('Survol d\'une ligne : la raison de son statut.'), x, cy, c.grey)
  return cy + 18 - y
end

-- ---------------------------------------------------------------------------
-- Fenêtre principale
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- Onglet DIAGNOSTIC (planche « capacités CSP »)
-- ---------------------------------------------------------------------------

local CAP_WORDS = { available = 'Disponible', pending = 'À confirmer', unavailable = 'Indisponible', na = 'Sans objet' }

local function diagPage(x, y, w)
  local app, c = X.app, X.c
  local d = app.discovery
  local cy = y
  if app.ui.message then cy = cy + messageBar(L.t(app.ui.message), x, cy, w, 'info') + 8 end
  local colors = { available = c.go, pending = c.warn, unavailable = c.danger, na = c.grey }
  if d and d.caps then
    local counts = X.U.capsCounts(d.caps)
    local cols = w >= K.uiDashWide and 4 or 2
    local tw = (w - 8 * (cols - 1)) / cols
    local list = { { 'Disponibles', counts.available, c.go }, { 'À confirmer', counts.pending, c.warn },
      { 'Indisponibles', counts.unavailable, c.danger }, { 'Sans objet', counts.na, c.grey } }
    for i, it in ipairs(list) do
      local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
      local tx, ty = x + col * (tw + 8), cy + row * 64
      panel(tx, ty, tx + tw, ty + 56)
      lab(it[1], tx + 12, ty + 10, it[3])
      text('display', 24, tostring(it[2]), tx + 12, ty + 24, c.light)
    end
    cy = cy + math.ceil(#list / cols) * 64 + 4
    -- capacités, une par ligne : nom, détail, état (détail au survol s'il est coupé)
    local rows = d.caps.list
    local h = 40 + #rows * 24 + 10
    panel(x, cy, x + w, cy + h)
    X.cw = x + w
    panelTitle('Capacités · découverte J0', x + 14, cy + 12)
    local ry = cy + 38
    local nameW = math.min(230, (w - 28) * 0.38)
    for i, entry in ipairs(rows) do
      X.ui.setCursor(vec(1, X.ox + x + 14, X.oy + ry))
      X.ui.invisibleButton('###cap_' .. i, vec(3, w - 28, 22))
      tip(entry.detail ~= '' and entry.detail or nil)
      text('text', 12, fitted('text', 12, L.t(entry.label), nameW - 8), x + 14, ry + 3, c.light)
      local st = up(L.t(CAP_WORDS[entry.status] or entry.status))
      local sw = measure('section', 11, st)
      text('mono', 10.5, fitted('mono', 10.5, L.t(entry.detail or ''), w - 28 - nameW - sw - 20), x + 14 + nameW, ry + 4, c.grey)
      text('section', 11, st, x + w - 14 - sw, ry + 4, colors[entry.status] or c.grey)
      rect(x + 14, ry + 23, x + w - 14, ry + 24, c.rowLine)
      ry = ry + 24
    end
    cy = cy + h + 8
  else
    cy = cy + messageBar(L.t('Capacités : sondage en attente.'), x, cy, w, 'info') + 8
  end
  -- actions (mêmes libellés que les contrôles ImGui)
  local bx = x
  local actions = { { 'Copier le rapport J0', function() X.intents.copyReport = true end, 'primary',
    'Le rapport J0 se colle tel quel dans la conversation de développement. À faire de préférence depuis l\'écran de setup, '
      .. 'voiture aux stands.' },
    { 'Relancer la découverte', function() X.intents.rediscover = true end },
    { 'Enregistrer une copie du setup actuel', function() X.intents.saveCopy = true end, nil,
      'Test d\'écriture : un nouveau fichier, copie exacte du setup actuel, sans rien modifier ni écraser.' } }
  for _, a in ipairs(actions) do
    local vis = up(L.t(a[1]))
    local bw = measure('button', 13, vis) + 34
    if bx + bw > x + w then
      bx = x
      cy = cy + 36
    end
    if button(a[1], bx, cy, bw, 30, a[3], 13) then a[2]() end
    tip(a[4])
    bx = bx + bw + 8
  end
  cy = cy + 40
  local test = app.writeTest
  local ts = test and (test.ok and (L.t('Test d\'écriture réussi : ') .. tostring(test.path))
    or (L.t('Test d\'écriture en échec : ') .. L.t(tostring(test.reason)))) or L.t('Écriture non testée.')
  dot(x + 4, cy + 7, 3.5, test and (test.ok and c.go or c.danger) or c.dim)
  cy = cy + textBox('text', 11.5, ts, x + 14, cy, w - 14, test and (test.ok and c.light or c.badInk) or c.grey) + 6
  local theme = L.t('Thème de l\'interface : ' .. tostring(X.U.skinStatus or 'non évalué')
    .. (X.S.fontDir and ' ; polices de l\'app' or ' ; polices absentes : Segoe UI'))
  cy = cy + textBox('text', 11.5, theme, x, cy, w, c.grey) + 4
  cy = cy + textBox('mono', 10.5, Config.appName .. ' ' .. Config.version .. ' — ' .. L.t('jalon') .. ' ' .. Config.milestone, x, cy,
    w, c.grey) + 8
  return cy - y
end

-- ---------------------------------------------------------------------------
-- Onglet AIDE (planche « le principe »)
-- ---------------------------------------------------------------------------

local HELP_STEPS = {
  { 'Au stand', 'Départ', 'Votre setup actuel, celui par défaut de la voiture, ou votre référence validée sur ce circuit. Le choix '
    .. 'active SetupLab.' },
  { 'En piste', 'Rouler', 'Après le minimum de tours propres et de minutes, SetupLab a ce qu\'il faut. Il continue d\'analyser : la '
    .. 'version est prête au retour au stand.' },
  { 'Au stand', 'Essayer', '« Essayer vN » met la version dans la voiture, en un clic. Roulez avec : rien n\'est gardé avant '
    .. '« Valider ».' },
  { 'Au stand', 'Valider', '« Valider vN » la garde ; refusez un réglage précis ligne par ligne. Elle devient votre référence : '
    .. 'SetupLab repart d\'elle.' },
}
local HELP_MORE = {
  { 'Course', 'Après un setup de qualif SetupLab (au moins une v1), monté dans la voiture. Saisissez seulement le nombre de tours : '
    .. 'carburant, usure, relais et trafic suivent.' },
  { 'Overlay en jeu', '« SetupLab Overlay » (barre d\'apps CSP) : en roulant, mieux ou moins bien que le setup d\'avant sur vos '
    .. 'tours, et les réglages qui ont changé.' },
  { 'Fichiers', 'SetupLab_Qualif_v1.ini, _Course_Pluie_v3.ini… Essais et versions non gardées partent à la Corbeille. Vos '
    .. 'fichiers ne sont jamais touchés.' },
}

local function helpPage(x, y, w)
  local c = X.c
  local wide = w >= K.uiDashWide
  local cy = y
  -- le principe
  local introW = wide and (w - 12 - 76 - 14 - 150 - 14 - 18) or (w - 28)
  local p1 = L.t('SetupLab calcule un setup pour la voiture et le circuit, puis l\'affine avec vos tours : il apprend votre '
    .. 'pilotage et propose des versions successives (v1, v2, v3…).')
  local p2 = L.t('Rien n\'est enregistré sans votre accord. Le setup de la voiture ne change que sur votre confirmation, au stand.')
  local th = textBox('text', 13, p1, 0, 0, introW, c.light, true) + 6 + textBox('text', 13, p2, 0, 0, introW, c.soft, true)
  local h = wide and math.max(100, th + 24) or (76 + 12 + th + 24)
  panel(x, cy, x + w, cy + h)
  Util.call(X.ui.drawImage, 'icon.png', vec(1, X.ox + x + 12, X.oy + cy + 12), vec(2, X.ox + x + 12 + 76, X.oy + cy + 12 + 76))
  local tx = x + 12 + 76 + 14
  local ty = wide and (cy + (h - 36) / 2) or (cy + 30)
  local lw = text('display', 34, up(L.t('Le')) .. ' ', tx, ty, c.light)
  text('display', 34, up(L.t('principe')), tx + lw, ty, c.blue)
  local px = wide and (tx + 150 + 14) or (x + 14)
  local py = wide and (cy + 12) or (cy + 12 + 76 + 12)
  if wide then rect(px, cy + 12, px + 1, cy + h - 12, c.line) end
  local qx = wide and (px + 18) or px
  local hh = textBox('text', 13, p1, qx, py, introW, c.light)
  textBox('text', 13, p2, qx, py + hh + 6, introW, c.soft)
  cy = cy + h + 8
  -- les 4 étapes
  local cols = wide and 4 or 2
  local sw = (w - 6 * (cols - 1)) / cols
  local stepH = 0
  for _, s in ipairs(HELP_STEPS) do stepH = math.max(stepH, 74 + textBox('text', 12, L.t(s[3]), 0, 0, sw - 26, c.soft, true)) end
  for i, s in ipairs(HELP_STEPS) do
    local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
    local sx, sy = x + col * (sw + 6), cy + row * (stepH + 6)
    panel(sx, sy, sx + sw, sy + stepH, i == 4 and c.helpLast or c.panel)
    text('display', 44, tostring(i), sx + 13, sy + 6, c.blue)
    local ls = up(L.t(s[1]))
    lab(s[1], sx + sw - 13 - measure('label', 11, ls), sy + 30, c.blueSoft)
    text('button', 20, up(L.t(s[2])), sx + 13, sy + 48, c.light)
    textBox('text', 12, L.t(s[3]), sx + 13, sy + 72, sw - 26, c.soft)
  end
  cy = cy + math.ceil(#HELP_STEPS / cols) * (stepH + 6) + 2
  -- course, overlay, fichiers
  local cols2 = wide and 3 or 1
  local mw = (w - 6 * (cols2 - 1)) / cols2
  local moreH = 0
  for _, s in ipairs(HELP_MORE) do moreH = math.max(moreH, 40 + textBox('text', 12, L.t(s[2]), 0, 0, mw - 26, c.soft, true)) end
  for i, s in ipairs(HELP_MORE) do
    local col, row = (i - 1) % cols2, math.floor((i - 1) / cols2)
    local mx, my = x + col * (mw + 6), cy + row * (moreH + 6)
    panel(mx, my, mx + mw, my + moreH)
    rect(mx + 13, my + 14, mx + 17, my + 28, c.blue)
    text('section', 14, up(L.t(s[1])), mx + 24, my + 13, c.light)
    textBox('text', 12, L.t(s[2]), mx + 13, my + 36, mw - 26, c.soft)
  end
  cy = cy + math.ceil(#HELP_MORE / cols2) * (moreH + 6) + 2
  -- mise à jour en jeu (une ligne), notice
  local up2 = L.t('Une fois par lancement d\'AC, SetupLab regarde sur GitHub si une version plus récente est publiée (réglage dans '
    .. 'l\'onglet RÉGLAGES). Si oui, « Mettre à jour », en haut de la fenêtre, l\'installe en un clic (au stand, voiture '
    .. 'arrêtée), après avoir vérifié l\'archive ; CSP recharge alors SetupLab. Aucune donnée de jeu ni personnelle n\'est '
    .. 'envoyée ; GitHub voit seulement votre adresse IP, comme pour toute page web.')
  cy = cy + messageBar(up2, x, cy, w, 'info') + 8
  local nh = 74
  panel(x, cy, x + w, cy + nh)
  lab('Notice complète', x + 16, cy + 12, c.light)
  text('mono', 11, fitted('mono', 11, 'apps/lua/SetupLab/docs/notice.fr.html · notice.html', w - 32), x + 16, cy + 30, c.soft)
  local ls = up(L.t('Problèmes et idées')) .. ' · github.com/VincentChevalier44/ACSetupLab/issues'
  text('section', 11.5, fitted('section', 11.5, ls, w - 32), x + 16, cy + 50, c.blueSoft)
  return cy + nh + 8 - y
end

-- ---------------------------------------------------------------------------
-- Fenêtre « SetupLab Overlay » (planches « en piste — mieux / moins bien », « en veille »)
-- ---------------------------------------------------------------------------

local OVERLAY_ROWS = 4

-- veille, ou aucun setup de SetupLab en piste : logo, titre, phrase
local function overlayIdle(W, H, title, s)
  local c = X.c
  X.S.panel(X.ox, X.oy, X.ox + W, X.oy + H, c.overlayBg, 12)
  rect(0, 0, W - 12, 2, c.dim)
  local logo = math.min(40, H - 24)
  Util.call(X.ui.drawImage, 'icon.png', vec(1, X.ox + 14, X.oy + (H - logo) / 2), vec(2, X.ox + 14 + logo, X.oy + (H + logo) / 2),
    c.logoDim)
  local tx = 14 + logo + 12
  local tw = text('display', 18, up(L.t(title)), tx, 14, c.light)
  dot(tx + tw + 10, 23, 3.5, c.dim)
  textBox('text', 12, L.t(s), tx, 40, W - tx - 14, c.soft)
end

function M.overlay(host, app, U)
  local ui = host.ui
  X.host, X.ui, X.S, X.c, X.app, X.intents, X.U = host, ui, ui.skin, ui.skin.colors, app, {}, U
  if V == nil or V.host ~= host then
    V = { host = host }
    for i = 1, 4 do V[i] = host.vec2(0, 0) end
  end
  local okS, size = Util.call(ui.windowSize)
  if not (okS and size and Util.isFinite(size.x) and Util.isFinite(size.y)) then return false end
  X.ox, X.oy = 0, 0
  local W, H = size.x, size.y
  local c = X.c
  if app.inert then
    overlayIdle(W, H, 'SetupLab en veille', tostring(app.inert))
    return true
  end
  local r = app.refine
  local kind = (r and r.kind) or (app.autoKind and app.autoKind()) or 'quali'
  local e, pending = U.overlaySetup(app, kind)
  if e == nil then
    if not app.auto then
      overlayIdle(W, H, 'SetupLab en veille', 'Cochez « SetupLab actif » dans la fenêtre SetupLab, sur l\'écran de setup.')
    else
      overlayIdle(W, H, 'SetupLab actif', 'Chaque setup proposé s\'annonce ici ; l\'essayer au stand, trier ses réglages, puis le '
        .. 'valider.')
    end
    return true
  end
  -- verdict sur vos tours (le setup entier)
  local mine, before = U.versionLaps(app, e), U.realLaps(app, e.originFamily, e.bucket)
  local tBefore, tMine = U.realTime(before, kind), U.realTime(mine, kind)
  local gain = (tMine and tBefore) and (tBefore - tMine) or nil
  local edge = gain and (gain > 0.0005 and c.go or (gain < -0.0005 and c.danger or c.dim)) or c.blue
  X.S.panel(0, 0, W, H, c.overlayBg, 12)
  rect(0, 0, W - 12, 2, edge)
  local px = 14
  local name = e.version and ('v' .. e.version) or tostring(e.file)
  local sw = text('display', 14, 'SETUP', px, 10, c.light)
  sw = sw + text('display', 14, 'LAB', px + sw, 10, c.blue)
  local where = L.t(kind == 'race' and 'Course' or 'Qualif') .. ' · ' .. L.t(e.bucket == 'pluie' and 'pluie' or 'sec')
  local vs = L.f('%s en piste', name)
  local vw = text('section', 12, up(vs), px + sw + 12, 11, c.blueSoft)
  text('text', 11.5, where, px + sw + 12 + vw + 10, 11, c.grey)
  local cy = 32
  -- à droite : meilleur (ou moyenne) et avant
  local rightW = 118
  if tMine then
    lab(kind == 'race' and 'Moyenne' or 'Meilleur', W - 14 - rightW, cy)
    local ms = X.U.lapTime(tMine)
    text('display', 18, ms, W - 14 - measure('display', 18, ms), cy - 2, kind == 'race' and c.light or c.best)
  end
  if tBefore then
    lab('Avant', W - 14 - rightW, cy + 22)
    local bs = X.U.lapTime(tBefore)
    text('mono', 11, bs, W - 14 - measure('mono', 11, bs), cy + 22, c.grey)
  end
  local verdictW = W - 28 - rightW - 10
  if gain and math.abs(gain) >= 0.0005 then
    local s = up(L.t(gain > 0 and 'Mieux de' or 'Moins bien de')) .. ' ' .. Util.fmt(math.abs(gain), 3) .. ' s'
    text('display', W < 360 and 20 or 26, fitted('display', W < 360 and 20 or 26, s, verdictW), px, cy, gain > 0 and c.go or c.danger)
  elseif gain then
    text('display', 20, up(L.t('Identique au setup d\'avant')), px, cy + 2, c.grey)
  else
    textBox('text', 12, L.f('Un tour propre avec %s : verdict sur vos temps.', name), px, cy + 2, verdictW, c.soft)
  end
  cy = cy + 44
  -- dernier tour
  local last = app.recorder and app.recorder.laps and app.recorder.laps.last
  if last and Util.isFinite(last.time) and last.time > 0 then
    local s = L.t('Dernier tour') .. ' ' .. X.U.lapTime(last.time)
    local color = c.soft
    if not last.valid then
      s = s .. ' · ' .. L.t('non compté') .. ' (' .. L.t(tostring(last.reason or 'non valide')) .. ')'
      color = c.warn
    elseif tMine and last.family == e.family then
      local delta = last.time - tMine
      s = s .. ' (' .. (math.abs(delta) < 0.0005 and L.t('votre meilleur') or (delta >= 0 and '+' or '-') .. Util.fmt(math.abs(delta), 3))
        .. ')'
    end
    text('text', 11.5, fitted('text', 11.5, s, W - 28), px, cy, color)
    cy = cy + 18
  end
  if e.status == 'écartée' then
    text('text', 11.5, fitted('text', 11.5, L.f('%s non gardée : charger la référence au stand.', name), W - 28), px, cy, c.warn)
    cy = cy + 18
  end
  -- réglages changés (gain prévu par le modèle)
  local list = e.fromMemory and {} or U.overlayChanges(e)
  local roomRows = math.max(0, math.floor((H - cy - 8 - (pending and pending ~= e and 34 or 0) - 16) / 19))
  local rows = math.min(#list, OVERLAY_ROWS, roomRows)
  if rows > 0 then rect(px, cy, W - 14, cy + 1, c.line) end
  cy = cy + 4
  for i = 1, rows do
    local ch = list[i]
    local g = ch.contribution or 0
    local gs = (g >= 0 and '-' or '+') .. Util.fmt(math.abs(g), 3):gsub('^0', '')
    local gc = ch.atBound and c.warn or (g >= 0 and c.go or c.danger)
    local gw = measure('mono', 11, gs)
    local vs2 = fromTo(X.U.physicalText(ch.var.kind, ch.from), X.U.physicalText(ch.var.kind, ch.to))
    local v2w = measure('mono', 10.5, vs2)
    local nameW = W - 28 - gw - v2w - 20
    text('text', 12, fitted('text', 12, L.t(ch.var.label) .. (ch.atBound and ' ?' or ''), nameW), px, cy + 1, c.light)
    text('mono', 10.5, vs2, W - 14 - gw - 12 - v2w, cy + 2, c.grey)
    text('mono', 11, gs, W - 14 - gw, cy + 1, gc)
    cy = cy + 19
  end
  if #list > rows and rows > 0 then
    local rest = 0
    for i = rows + 1, #list do rest = rest + (list[i].contribution or 0) end
    local n = #list - rows
    local s = L.f(n > 1 and '+ %s autres réglages' or '+ %s autre réglage', n)
    text('text', 11.5, s, px, cy + 1, c.grey)
    local rs = (rest >= 0 and '-' or '+') .. Util.fmt(math.abs(rest), 3):gsub('^0', '')
    text('mono', 11, rs, W - 14 - measure('mono', 11, rs), cy + 1, rest >= 0 and c.go or c.danger)
    cy = cy + 19
  end
  -- version en préparation, ou prête
  if pending and pending ~= e then
    rect(px, cy + 2, W - 14, cy + 3, c.line)
    local g = pending.gain or 0
    local gs = (g >= 0 and '-' or '+') .. Util.fmt(math.abs(g), 3) .. ' s'
    if pending.ready == false then
      local f = U.realLaps(app, pending.originFamily, pending.bucket)
      local n = f and f.count or 0
      local s = L.f('v%s en préparation', pending.version) .. ' · ' .. gs .. ' ' .. L.t('provisoire')
      text('section', 12, fitted('section', 12, up(s), W - 28), px, cy + 8, c.warn)
      text('text', 11, fitted('text', 11, L.f(n > 1 and '%s tours analysés' or '%s tour analysé', n) .. ' · '
        .. L.t('prête à votre retour au stand'), W - 28), px, cy + 24, c.grey)
    else
      local s = L.f('v%s prête', pending.version) .. ' · ' .. gs .. ' · ' .. L.t('au stand : Essayer, puis Valider')
      text('section', 12, fitted('section', 12, up(s), W - 28), px, cy + 8, c.blueSoft)
    end
  elseif not e.fromMemory and H - cy > 20 then
    text('text', 10.5, fitted('text', 10.5, L.t('Par réglage : gain prévu par le modèle · en haut : vos tours'), W - 28), px, H - 18,
      c.grey)
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Fenêtre « SetupLab Debug » (planche « fenêtre Debug »)
-- ---------------------------------------------------------------------------

local LEVEL_COLORS = { INFO = 'blueSoft', WARN = 'warn', ERROR = 'danger', DEBUG = 'grey' }

function M.debug(host, app, U)
  local ui = host.ui
  X.host, X.ui, X.S, X.c, X.app, X.intents, X.U = host, ui, ui.skin, ui.skin.colors, app, {}, U
  if V == nil or V.host ~= host then
    V = { host = host }
    for i = 1, 4 do V[i] = host.vec2(0, 0) end
  end
  local okC, origin = Util.call(ui.getCursor)
  local okS, size = Util.call(ui.windowSize)
  if not (okC and origin and okS and size and Util.isFinite(size.x)) then return false end
  X.ox, X.oy = origin.x, origin.y
  local W = size.x - 2 * origin.x
  local c = X.c
  rect(-origin.x, -origin.y, size.x - origin.x, size.y - origin.y, c.bg)
  local s, p = app.scheduler.stats, app.perf
  local sw = text('display', 18, 'SETUP', 0, 0, c.light)
  sw = sw + text('display', 18, 'LAB', sw, 0, c.blue)
  text('section', 13, up(L.t('Debug')), sw + 10, 4, c.grey)
  local offset = app.utcOffset and app.utcOffset() or nil
  local info = L.t('horloge') .. ' ' .. (app.clock and tostring(app.clockSource or 'QueryPerformanceCounter')
    or (L.t('repli quota') .. ' (' .. tostring(app.clockReason) .. ')')) .. ' · ' .. L.t('boucle') .. ' '
    .. tostring(app.updateSource or L.t('pas encore appelée')) .. ' · ' .. (offset and (L.t('noms de fichiers') .. ' UTC'
    .. (offset >= 0 and '+' or '-') .. Util.fmt(math.abs(offset) / 3600, 2) .. ' h') or (L.t('noms de fichiers') .. ' UTC'))
  local cy = 26 + textBox('mono', 10.5, info, 0, 26, W, c.grey) + 8
  -- trois panneaux de chiffres
  local cols = W >= 560 and 3 or 1
  local pw = (W - 8 * (cols - 1)) / cols
  local panels = {
    { 'Coût de l\'app par frame', L.f('garde %s ms', app.settings.frameGuardMs or 4), {
      { 'Dernier', Util.fmt(p.lastMs, 2) .. ' ms' }, { 'Moyen', Util.fmt(p.avgMs, 2) .. ' ms' },
      { 'Max', Util.fmt(p.maxMs, 2) .. ' ms' } } },
    { 'Ordonnanceur', nil, {
      { 'Tranches', tostring(s.slices) }, { 'Dernière · max', Util.fmt(s.lastSliceMs, 2) .. ' · ' .. Util.fmt(s.maxSliceMs, 2) .. ' ms' },
      { L.f('Au-delà de %s ms', K.sliceAlertMs), tostring(p.slowSlices) }, { 'Unité max', Util.fmt(s.maxUnitMs, 2) .. ' ms' } } },
    { 'Tâches · garde', nil, {
      { 'Terminées', tostring(s.completed) }, { 'En échec · annulées', s.failed .. ' · ' .. s.cancelled },
      { 'Tranches sautées', tostring(p.guardSkips) },
      { L.f('Réduites (< %s i/s) · erreurs', K.fpsTarget), p.slowFrames .. ' · ' .. p.errors } } },
  }
  local ph = 40 + 4 * 20 + 6
  for i, it in ipairs(panels) do
    local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
    local px, py = col * (pw + 8), cy + row * (ph + 8)
    panel(px, py, px + pw, py + ph)
    lab(it[1], px + 12, py + 10)
    if it[2] then
      local gs = up(L.t(it[2]))
      lab(it[2], px + pw - 12 - measure('label', 11, gs), py + 10)
    end
    local ry = py + 32
    for _, kv in ipairs(it[3]) do
      text('text', 12, fitted('text', 12, L.t(kv[1]), pw - 120), px + 12, ry, c.soft)
      text('mono', 11.5, kv[2], px + pw - 12 - measure('mono', 11.5, kv[2]), ry + 1, c.light)
      ry = ry + 20
    end
  end
  cy = cy + math.ceil(#panels / cols) * (ph + 8)
  -- journal : du plus récent au plus ancien
  local js = L.f('%s/%s lignes · %s répétitions filtrées', app.log.count, app.log.capacity, app.log.dropped)
  lab('Journal', 0, cy + 2)
  text('mono', 10.5, js, W - measure('mono', 10.5, js), cy + 2, c.grey)
  cy = cy + 20
  local entries = Util.logEntries(app.log)
  for i = #entries, 1, -1 do
    local e = entries[i]
    local ts = Util.fmt(e.t, 1) .. ' s'
    text('mono', 10.5, ts, 0, cy + 1, c.grey)
    local lx = 70
    lx = lx + text('section', 10.5, e.level, lx, cy + 1, c[LEVEL_COLORS[e.level] or 'grey']) + 10
    lx = lx + text('mono', 10.5, up(tostring(e.code)), lx, cy + 1, c.soft) + 10
    cy = cy + math.max(16, textBox('text', 11.5, L.t(e.text), lx, cy, W - lx, c.light)) + 4
  end
  ui.setCursor(vec(1, X.ox, X.oy + cy))
  ui.dummy(vec(3, W, 1))
  return true
end

local PAGES = {
  ['Tour rapide'] = function(x, y, w) return kindPage('quali', x, y, w) end,
  ['Course'] = racePage, ['Mémoire'] = memoryPage, ['Mesure'] = measurePage, ['Réglages'] = settingsPage,
  ['Capacités'] = diagPage, ['Aide'] = helpPage,
}

-- host, app, intents : comme M.main de src/ui.lua ; U : src/ui.lua (modèles, aides) ; tabs : onglets { libellé###id, … }
-- (libellés et identifiants)
function M.main(host, app, intents, U, tabs)
  local ui = host.ui
  X.host, X.ui, X.S, X.c, X.app, X.intents, X.U = host, ui, ui.skin, ui.skin.colors, app, intents, U
  if V == nil or V.host ~= host then
    V = { host = host }
    for i = 1, 4 do V[i] = host.vec2(0, 0) end
  end
  app.ui.tab = app.ui.tab or ((app.autoKind and app.autoKind() == 'race') and 'Course' or 'Tour rapide')
  local okC, origin = Util.call(ui.getCursor)
  local okS, size = Util.call(ui.windowSize)
  if not (okC and origin and okS and size and Util.isFinite(size.x) and Util.isFinite(size.y)) then return false end
  X.ox, X.oy = origin.x, origin.y
  local W, H = size.x, size.y
  rect(0, 0, W, H, X.c.bg)
  local narrow = W < K.uiDashWide
  local top = header(tabs, W, narrow)
  -- contenu : fenêtre enfant qui défile sous l'en-tête
  local margin = narrow and 12 or 16
  ui.setCursor(vec(1, X.ox + margin, X.oy + top + 8))
  local body = vec(4, W - 2 * margin + 4, math.max(100, H - top - 12))
  local function content()
    local okB, at = Util.call(ui.getCursor)
    if not (okB and at) then return end
    X.ox, X.oy = at.x, at.y
    local okW, avail = Util.call(ui.availableSpaceX)
    local w = (okW and Util.isFinite(avail) and avail or (W - 2 * margin)) - 4
    local y = updateRow(0, 0, w)
    local tab = app.ui.tab
    y = y + (PAGES[tab] or PAGES['Tour rapide'])(0, y, w)
    ui.setCursor(vec(1, X.ox, X.oy + y))
    ui.dummy(vec(3, w, 1))
  end
  if ui.childWindow then
    ui.childWindow('setuplab_body', body, false, 0, content)
  else
    content()
  end
  return true
end

return M
