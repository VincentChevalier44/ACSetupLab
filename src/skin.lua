-- SetupLab — thème « Racing 26 » (refonte de Vincent du 02/11/2026, canevas Design « SetupLab 2026 — Refonte UI »). Il
-- remplace le thème de la 1.5. Fond quasi noir, panneaux anthracite à coin coupé, cyan d'action, couleurs de
-- course (meilleur tour violet, gain vert, à confirmer ambre, perte rouge). Polices livrées avec l'app (fonts/, licence
-- OFL) : Barlow pour le texte, Barlow Condensed (italique très gras) pour les titres, les boutons et les onglets,
-- JetBrains Mono pour les valeurs. Boutons en parallélogramme, onglets inclinés, barre d'étapes en segments inclinés.
-- Polices absentes : Segoe UI. Actif si l'hôte a DWrite et les boutons invisibles (CSP 0.2.11 et plus récent) ; sinon
-- l'interface garde les contrôles ImGui.
local Util = require('src/util')
local Caps = require('src/caps')

local M = {}

local function hex(h, a)
  local r, g, b = h:match('^#(%x%x)(%x%x)(%x%x)$')
  return { tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255, a or 1 }
end

-- Jetons du kit Racing 26 (clés historiques gardées : blue = cyan d'action, light = texte, grey = libellé…).
M.COLORS = {
  bg = hex('#0A0B0E', 0.98), panel = hex('#111318', 0.98), clear = { 0, 0, 0, 0 },
  rowHover = hex('#1B1F26'), line = hex('#23272E'),
  raised = hex('#22262E'), raisedHover = hex('#2C313B'), outline = hex('#3A404C'),
  light = hex('#EEF0F3'), grey = hex('#8D94A0'),
  blue = hex('#18C5FF'), blueHover = hex('#6FDBFF'), blueSoft = hex('#6FDBFF'), dark = hex('#031820'),
  select = hex('#06222D'),
  go = hex('#2EE07F'), goHover = hex('#5CEB9C'), goText = hex('#04170D'),
  danger = hex('#FF5A4E'), dangerHover = hex('#FF7A70'), dangerText = hex('#240604'),
  switchOff = hex('#2A2E36'), knobOn = hex('#031820'), segmentOff = hex('#2A2E36'),
  -- pages Racing 26 (src/dash.lua) : contrôle, texte secondaire, filets, aplats de statut (kit de la maquette)
  control = hex('#1D2027'), controlHover = hex('#272B34'), soft = hex('#C9CDD3'), dim = hex('#5C626C'), tabIdle = hex('#9AA1AC'),
  rowLine = hex('#1A1D23'), trackBg = hex('#181B21'), band = hex('#3A2A12'), okBg = hex('#0E2A1B'), okInk = hex('#9FD9B8'),
  warn = hex('#FFC23D'), warnBg = hex('#2E2410'), warnInk = hex('#E6C98A'), warnText = hex('#FFE3A3'), badBg = hex('#3A1614'),
  badInk = hex('#FFB4AD'), errBg = hex('#2A1412'), bar = hex('#15181D'), tile = hex('#17191E'), selLine = hex('#0E4258'),
  best = hex('#B26CFF'), fast = hex('#8C7BFF'), langBg = hex('#1B1E24'), langLine = hex('#343943'), pillGo = hex('#0E251C'),
  pillRec = hex('#310B11'), pillIdle = hex('#1B1D21'), rec = hex('#FF6B72'), stripe = hex('#118EB8'), keepBg = hex('#173E2A'),
  overlayBg = hex('#090A0D', 0.88), logoDim = hex('#9A9A9A'), helpLast = hex('#0C1D25'),
}

-- Tailles de texte (px).
M.SIZE = { main = 13, small = 11, title = 22, button = 14, header = 26, tab = 14 }
M.BUTTON_PAD = 30
M.CUT, M.SLANT, M.TAB_SLANT = 10, 9, 7

-- Polices : dossier relatif au dossier de l'app (CSP 0.1.80 et plus récent), ou Segoe UI sans les fichiers.
local FAMILIES = {
  text = { 'Barlow:%s/barlow;Weight=Regular', 'Segoe UI' },
  bold = { 'Barlow:%s/barlow;Weight=SemiBold', 'Segoe UI;Weight=Bold' },
  display = { 'Barlow Condensed:%s/barlowcondensed;Weight=Black;Style=Italic', 'Segoe UI;Weight=Black;Style=Italic' },
  button = { 'Barlow Condensed:%s/barlowcondensed;Weight=UltraBold;Style=Italic', 'Segoe UI;Weight=Bold;Style=Italic' },
  tab = { 'Barlow Condensed:%s/barlowcondensed;Weight=Bold', 'Segoe UI;Weight=Bold' },
  section = { 'Barlow Condensed:%s/barlowcondensed;Weight=Bold', 'Segoe UI;Weight=Bold' },
  label = { 'Barlow Condensed:%s/barlowcondensed;Weight=SemiBold', 'Segoe UI;Weight=SemiBold' },
  mono = { 'JetBrains Mono:%s/jetbrainsmono;Weight=Medium', 'Consolas' },
}
function M.fonts(dir)
  local out = {}
  for role, f in pairs(FAMILIES) do out[role] = dir and f[1]:format(dir) or f[2] end
  return out
end

-- ffi : pour reconnaître une fonction C de CSP (cdata) comme appelable.
function M.available(ui, ffi)
  for _, name in ipairs({ 'dwriteText', 'dwriteTextWrapped', 'dwriteDrawText', 'measureDWriteText', 'invisibleButton',
    'itemRectMin', 'itemRectMax', 'itemHovered', 'itemActive', 'drawRectFilled', 'pushDWriteFont', 'popDWriteFont' }) do
    if not Caps.isCallable(Util.get(ui, name), ffi) then return false, name end
  end
  return true
end

-- Libellé visible et identifiant (« visible###id ») d'un libellé ImGui.
local function split(label)
  local visible, id = label:match('^(.-)###(.*)$')
  if visible == nil then return label, label end
  return visible, id
end
M.split = split

-- Habillage d'un ui réel : renvoie les fonctions qui remplacent celles de l'ui (texte, boutons, cases, mesures).
-- translate : traduction du texte visible (identité en français). fontDir : dossier des polices (relatif à l'app), ou nil.
function M.new(real, rgbm, vec2, translate, fontDir)
  local S = { real = real }
  local c = {}
  for k, v in pairs(M.COLORS) do c[k] = rgbm(v[1], v[2], v[3], v[4]) end
  S.colors = c
  local fonts = M.fonts(fontDir)
  S.fontDir = fontDir
  local pa, pb, ps = vec2(0, 0), vec2(0, 0), vec2(0, 0)
  local q1, q2, q3, q4 = vec2(0, 0), vec2(0, 0), vec2(0, 0), vec2(0, 0)
  -- police courante : poussée par withFont (ui.pushFont) : Small, Title, sinon texte normal
  local fontNames = {}
  for name, value in pairs(type(real.Font) == 'table' and real.Font or {}) do fontNames[value] = name end
  local stack = {}
  local function current()
    local name = stack[#stack]
    if name == 'Small' or name == 'Tiny' then return M.SIZE.small, false, nil end
    if name == 'Title' or name == 'Huge' then return M.SIZE.title, true, 'display' end
    return M.SIZE.main, false, nil
  end
  function S.pushFont(font)
    stack[#stack + 1] = fontNames[font] or 'Main'
    return true
  end
  function S.popFont()
    stack[#stack] = nil
  end
  local function withRole(role, fn)
    real.pushDWriteFont(fonts[role] or fonts.text)
    local ok, a, b = pcall(fn)
    real.popDWriteFont()
    if not ok then error(a, 0) end
    return a, b
  end
  S.withRole = withRole
  -- chemin chaud (chaque texte de chaque image) : appel direct sous la police, sans fermeture créée (S.call pour l'interface)
  local function roleCall(role, fn, ...)
    real.pushDWriteFont(fonts[role] or fonts.text)
    local ok, a, b = pcall(fn, ...)
    real.popDWriteFont()
    if not ok then error(a, 0) end
    return a, b
  end

  -- Formes : quadrilatère (parallélogramme), sinon rectangle ; panneau à coin coupé (deux rectangles et un triangle).
  local function quad(x1, y1, x2, y2, x3, y3, x4, y4, color)
    q1.x, q1.y, q2.x, q2.y, q3.x, q3.y, q4.x, q4.y = x1, y1, x2, y2, x3, y3, x4, y4
    if not Util.call(real.drawQuadFilled, q1, q2, q3, q4, color) then
      pa.x, pa.y = math.min(x1, x4), y1
      pb.x, pb.y = math.max(x2, x3), y3
      real.drawRectFilled(pa, pb, color, 0)
    end
  end
  S.quad = quad
  -- parallélogramme penché à droite (le haut décalé de slant px)
  function S.slanted(x1, y1, x2, y2, slant, color)
    quad(x1 + slant, y1, x2, y1, x2 - slant, y2, x1, y2, color)
  end
  function S.panel(x1, y1, x2, y2, color, cut)
    cut = math.min(cut or M.CUT, (x2 - x1) / 2, (y2 - y1) / 2)
    pa.x, pa.y, pb.x, pb.y = x1, y1, x2 - cut, y2
    real.drawRectFilled(pa, pb, color, 0)
    pa.x, pa.y, pb.x, pb.y = x2 - cut, y1 + cut, x2, y2
    real.drawRectFilled(pa, pb, color, 0)
    q1.x, q1.y, q2.x, q2.y, q3.x, q3.y = x2 - cut, y1, x2, y1 + cut, x2 - cut, y1 + cut
    Util.call(real.drawTriangleFilled, q1, q2, q3, color)
  end
  -- barre d'étapes : n segments inclinés, les filled premiers en couleur
  function S.segments(x, y, w, h, n, filled, on, off)
    local gap = 4
    local each = (w - gap * (n - 1)) / n
    for i = 1, n do
      local x1 = x + (i - 1) * (each + gap)
      S.slanted(x1, y, x1 + each, y + h, 2, i <= filled and on or (off or c.segmentOff))
    end
  end

  -- Texte (avance le curseur comme ui.text) : couleur donnée, sinon texte clair ; wrap : retour à la ligne.
  function S.textAs(text, color, wrap, size, bold, role)
    local s, b, r = current()
    size, bold = size or s, (bold == nil) and b or bold
    role = role or r or (bold and 'bold' or 'text')
    roleCall(role, wrap and real.dwriteTextWrapped or real.dwriteText, translate(tostring(text)), size, color or c.light)
  end
  function S.text(text) S.textAs(text, nil, false) end
  function S.textColored(text, color) S.textAs(text, color, false) end
  function S.textWrapped(text) S.textAs(text, nil, true) end
  S.call = roleCall
  function S.drawText(text, pos, color)
    local size, bold, role = current()
    roleCall(role or (bold and 'bold' or 'text'), real.dwriteDrawText, translate(tostring(text)), size, pos, color or c.light)
  end
  function S.measureText(text)
    local size, bold, role = current()
    return roleCall(role or (bold and 'bold' or 'text'), real.measureDWriteText, translate(split(tostring(text))), size)
  end

  -- Texte coupé avec « … » pour tenir dans w px.
  local function fit(text, size, w)
    local m = real.measureDWriteText(text, size)
    if m.x <= w then return text, m end
    local chars = {}
    for ch in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do chars[#chars + 1] = ch end
    local lo, hi = 0, #chars
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if real.measureDWriteText(table.concat(chars, '', 1, mid) .. '…', size).x <= w then lo = mid else hi = mid - 1 end
    end
    local out = table.concat(chars, '', 1, lo) .. '…'
    return out, real.measureDWriteText(out, size)
  end
  -- texte (déjà traduit) coupé pour tenir dans w px, mesuré dans la police du rôle
  function S.fitIn(role, text, size, w)
    return (roleCall(role, fit, text, size, w))
  end
  -- largeur d'un bouton du thème (libellé traduit, police des boutons) : pour placer le suivant sur la même ligne
  function S.buttonWidth(label)
    local visible = translate((split(label)))
    local m = roleCall('button', real.measureDWriteText, visible, M.SIZE.button)
    return (m and m.x or 0) + M.BUTTON_PAD
  end

  -- Bouton Racing 26 : parallélogramme, Barlow Condensed italique très gras. primary : cyan, texte sombre ; go : vert ;
  -- danger : rouge. Neutre : aplat plus clair que les panneaux, cerné d'un filet (cyan au survol) : un bouton ne se
  -- confond pas avec le texte (constat de Vincent du 02/11/2026). size : nil (largeur du libellé), x < 0 (toute la
  -- largeur), x > 0 (largeur donnée) ; y > 0 : hauteur.
  local function drawButton(visible, id, size, style)
    local fs = M.SIZE.button
    local m = real.measureDWriteText(visible, fs)
    local w, h = m.x + M.BUTTON_PAD, 30
    if size ~= nil and type(size) ~= 'number' then
      if size.x and size.x < 0 then w = math.max(w, real.availableSpaceX()) elseif size.x and size.x > 0 then w = size.x end
      if size.y and size.y > 0 then h = size.y end
    end
    ps.x, ps.y = w, h
    local clicked = real.invisibleButton('###' .. id, ps)
    local hovered, active = real.itemHovered(), real.itemActive()
    local a, b = real.itemRectMin(), real.itemRectMax()
    local hot = hovered or active
    local bg, fg, border
    if style == 'primary' then
      bg, fg = hot and c.blueHover or c.blue, c.dark
    elseif style == 'go' then
      bg, fg = hot and c.goHover or c.go, c.goText
    elseif style == 'danger' then
      bg, fg = hot and c.dangerHover or c.danger, c.dangerText
    else
      bg, fg, border = hot and c.raisedHover or c.raised, c.light, hot and c.blue or c.outline
    end
    local slant = math.min(M.SLANT, (b.y - a.y) / 3)
    if border then
      S.slanted(a.x, a.y, b.x, b.y, slant, border)
      S.slanted(a.x + 1, a.y + 1, b.x - 1, b.y - 1, slant, bg)
    else
      S.slanted(a.x, a.y, b.x, b.y, slant, bg)
    end
    -- libellé qui tient : sa mesure sert telle quelle (une seule mesure par image)
    local room = math.max(10, (b.x - a.x) - 24)
    local text, tm = visible, m
    if m.x > room then text, tm = fit(visible, fs, room) end
    pa.x, pa.y = a.x + math.max(12, ((b.x - a.x) - tm.x) / 2), a.y + ((b.y - a.y) - tm.y) / 2
    real.dwriteDrawText(text, fs, pa, fg)
    return clicked
  end

  -- Bouton Racing 26 : parallélogramme, Barlow Condensed italique très gras. primary : cyan, texte sombre ; go : vert ;
  -- danger : rouge. Neutre : aplat plus clair que les panneaux, cerné d'un filet (cyan au survol) : un bouton ne se
  -- confond pas avec le texte (constat de Vincent du 02/11/2026). size : nil (largeur du libellé), x < 0 (toute la
  -- largeur), x > 0 (largeur donnée) ; y > 0 : hauteur.
  function S.button(label, size, style)
    local visible, id = split(label)
    return (roleCall('button', drawButton, translate(visible), id, size, style))
  end

  local function drawCheckbox(visible, id, value)
    local fs = M.SIZE.main
    local m = real.measureDWriteText(visible, fs)
    local w, h = m.x + 60, 26
    ps.x, ps.y = w, h
    local clicked = real.invisibleButton('###' .. id, ps)
    local hovered = real.itemHovered()
    local a = real.itemRectMin()
    if hovered then
      pb.x, pb.y = a.x + w, a.y + h
      real.drawRectFilled(a, pb, c.rowHover, 2)
    end
    pa.x, pa.y = a.x + 6, a.y + (h - m.y) / 2
    real.dwriteDrawText(visible, fs, pa, value and c.light or c.grey)
    local x, y = a.x + w - 39, a.y + (h - 15) / 2
    pa.x, pa.y = x, y
    pb.x, pb.y = x + 30, y + 15
    real.drawRectFilled(pa, pb, value and c.blue or c.switchOff, 8)
    pa.x, pa.y = x + 8 + (value and 14 or 0), y + 7.5
    Util.call(real.drawCircleFilled, pa, 5, value and c.knobOn or c.grey, 24)
    return clicked
  end

  -- Interrupteur : libellé, pastille cyan quand actif ; renvoie vrai au clic (comme ui.checkbox).
  function S.checkbox(label, value)
    local visible, id = split(label)
    return (roleCall('tab', drawCheckbox, translate(visible), id, value))
  end

  local function drawBadge(visible, id)
    local m = real.measureDWriteText(visible, 11)
    ps.x, ps.y = m.x + 18, 20
    local clicked = real.invisibleButton('###' .. id, ps)
    local hovered = real.itemHovered()
    local a, b = real.itemRectMin(), real.itemRectMax()
    S.slanted(a.x, a.y, b.x, b.y, 5, hovered and c.blueHover or c.blue)
    pa.x, pa.y = a.x + 9, a.y + (20 - m.y) / 2
    real.dwriteDrawText(visible, 11, pa, c.dark)
    return clicked
  end

  -- Badge (langue) : petit parallélogramme cyan, texte sombre ; renvoie vrai au clic.
  function S.badge(label)
    local visible, id = split(label)
    return (roleCall('tab', drawBadge, visible, id))
  end
  return S
end

return M
