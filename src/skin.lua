-- SetupLab — thème SuperHUD (décision de Vincent du 26/10/2026 : « il faut vraiment reprendre la même interface, les
-- mêmes couleurs, le même fond… le même thème que SuperHUD »). Les contrôles sont dessinés comme dans la fenêtre de
-- configuration de SuperHUD (src/settings.lua) : texte Segoe UI (DWrite), fond anthracite uni, boutons plats arrondis
-- (bleu quand actifs, texte sombre), interrupteurs à pastille, onglets en capitales soulignés de bleu, titres de
-- section gris. SuperHUD n'a aucun dégradé : des aplats seulement. Actif si l'hôte a DWrite et les boutons invisibles
-- (CSP 0.2.11 et plus récent) ; sinon l'interface garde les contrôles ImGui.
local Util = require('src/util')

local M = {}

-- Palette de SuperHUD (src/settings.lua, src/view.lua).
M.COLORS = {
  blue = { 0.20, 0.59, 1, 1 }, light = { 0.92, 0.94, 0.96, 1 }, grey = { 0.58, 0.63, 0.65, 1 },
  bg = { 0.08, 0.085, 0.087, 0.98 }, field = { 0.15, 0.16, 0.17, 1 }, hover = { 0.22, 0.25, 0.28, 1 },
  dark = { 0.02, 0.07, 0.12, 1 }, line = { 0.22, 0.24, 0.26, 1 }, rowHover = { 0.16, 0.19, 0.22, 1 },
  switchOff = { 0.25, 0.28, 0.30, 1 }, knobOn = { 0.03, 0.09, 0.15, 1 }, panel = { 0.105, 0.111, 0.117, 0.96 },
  panelLine = { 0.2, 0.27, 0.35, 0.6 },
  go = { 0.12, 0.52, 0.28, 1 }, goHover = { 0.16, 0.63, 0.35, 1 }, danger = { 0.6, 0.18, 0.15, 1 },
  dangerHover = { 0.72, 0.23, 0.2, 1 }, blueHover = { 0.30, 0.66, 1, 1 },
}

-- Tailles de texte (px) : comme SuperHUD (textes 12-13, titres de section 11, titres en gras).
M.SIZE = { main = 13, small = 11, title = 16, button = 12, header = 24, tab = 13 }
local BOLD = 'Segoe UI;Weight=Bold'
local REGULAR = 'Segoe UI'

function M.available(ui)
  for _, name in ipairs({ 'dwriteText', 'dwriteTextWrapped', 'dwriteDrawText', 'measureDWriteText', 'invisibleButton',
    'itemRectMin', 'itemRectMax', 'itemHovered', 'itemActive', 'drawRectFilled', 'pushDWriteFont', 'popDWriteFont' }) do
    if type(Util.get(ui, name)) ~= 'function' then return false end
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
-- translate : traduction du texte visible (identité en français).
function M.new(real, rgbm, vec2, translate)
  local S = { real = real }
  local c = {}
  for k, v in pairs(M.COLORS) do c[k] = rgbm(v[1], v[2], v[3], v[4]) end
  S.colors = c
  local pa, pb, ps = vec2(0, 0), vec2(0, 0), vec2(0, 0)
  -- police courante : poussée par withFont (ui.pushFont) : Small, Title, sinon texte normal
  local fontNames = {}
  for name, value in pairs(type(real.Font) == 'table' and real.Font or {}) do fontNames[value] = name end
  local stack = {}
  local function current()
    local name = stack[#stack]
    if name == 'Small' or name == 'Tiny' then return M.SIZE.small, false end
    if name == 'Title' or name == 'Huge' then return M.SIZE.title, true end
    return M.SIZE.main, false
  end
  function S.pushFont(font)
    stack[#stack + 1] = fontNames[font] or 'Main'
    return true
  end
  function S.popFont()
    stack[#stack] = nil
  end
  local function withWeight(bold, fn)
    real.pushDWriteFont(bold and BOLD or REGULAR)
    local ok, a, b = pcall(fn)
    real.popDWriteFont()
    if not ok then error(a, 0) end
    return a, b
  end
  S.withWeight = withWeight

  -- Texte (avance le curseur comme ui.text) : couleur donnée, sinon texte clair ; wrap : retour à la ligne.
  function S.textAs(text, color, wrap, size, bold)
    local s, b = current()
    size, bold = size or s, (bold == nil) and b or bold
    text = translate(tostring(text))
    withWeight(bold, function()
      if wrap then real.dwriteTextWrapped(text, size, color or c.light) else real.dwriteText(text, size, color or c.light) end
    end)
  end
  function S.text(text) S.textAs(text, nil, false) end
  function S.textColored(text, color) S.textAs(text, color, false) end
  function S.textWrapped(text) S.textAs(text, nil, true) end
  function S.drawText(text, pos, color)
    local size, bold = current()
    withWeight(bold, function() real.dwriteDrawText(translate(tostring(text)), size, pos, color or c.light) end)
  end
  function S.measureText(text)
    local size, bold = current()
    return withWeight(bold, function() return real.measureDWriteText(translate(split(tostring(text))), size) end)
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

  -- Bouton plat (SuperHUD) : FIELD, survol plus clair ; primary : bleu, texte sombre ; go : vert ; danger : rouge.
  -- size : nil (largeur du libellé), x < 0 (toute la largeur), x > 0 (largeur donnée) ; y > 0 : hauteur.
  function S.button(label, size, style)
    local visible, id = split(label)
    visible = translate(visible)
    local fs = M.SIZE.button
    return withWeight(false, function()
      local m = real.measureDWriteText(visible, fs)
      local w, h = m.x + 20, 26
      if size ~= nil and type(size) ~= 'number' then
        if size.x and size.x < 0 then w = math.max(w, real.availableSpaceX()) elseif size.x and size.x > 0 then w = size.x end
        if size.y and size.y > 0 then h = size.y end
      end
      ps.x, ps.y = w, h
      local clicked = real.invisibleButton('###' .. id, ps)
      local hovered, active = real.itemHovered(), real.itemActive()
      local a, b = real.itemRectMin(), real.itemRectMax()
      local bg, fg
      if style == 'primary' then
        bg, fg = (hovered or active) and c.blueHover or c.blue, c.dark
      elseif style == 'go' then
        bg, fg = (hovered or active) and c.goHover or c.go, c.light
      elseif style == 'danger' then
        bg, fg = (hovered or active) and c.dangerHover or c.danger, c.light
      else
        bg, fg = (hovered or active) and c.hover or c.field, c.light
      end
      real.drawRectFilled(a, b, bg, 3)
      local text, tm = fit(visible, fs, math.max(10, (b.x - a.x) - 18))
      pa.x, pa.y = a.x + math.max(9, ((b.x - a.x) - tm.x) / 2), a.y + ((b.y - a.y) - tm.y) / 2
      real.dwriteDrawText(text, fs, pa, fg)
      return clicked
    end)
  end

  -- Interrupteur (SuperHUD) : libellé, pastille bleue quand actif ; renvoie vrai au clic (comme ui.checkbox).
  function S.checkbox(label, value)
    local visible, id = split(label)
    visible = translate(visible)
    local fs = M.SIZE.main
    return withWeight(false, function()
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
    end)
  end

  -- Badge (SuperHUD « FR ») : rectangle bleu, texte sombre ; renvoie vrai au clic.
  function S.badge(label)
    local visible, id = split(label)
    return withWeight(true, function()
      local m = real.measureDWriteText(visible, 10)
      ps.x, ps.y = m.x + 14, 19
      local clicked = real.invisibleButton('###' .. id, ps)
      local hovered = real.itemHovered()
      local a, b = real.itemRectMin(), real.itemRectMax()
      real.drawRectFilled(a, b, hovered and c.blueHover or c.blue, 2)
      pa.x, pa.y = a.x + 7, a.y + (19 - m.y) / 2
      real.dwriteDrawText(visible, 10, pa, c.dark)
      return clicked
    end)
  end
  return S
end

return M
