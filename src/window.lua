-- Fenêtre « SetupLab Overlay » (demande de Vincent du 03/11/2026 : le titre était coupé par la barre de CSP ; une barre
-- SetupLab avec un cadenas pour figer l'overlay à un endroit précis, réduire, fermer). La barre de CSP est retirée
-- (manifest : NO_TITLE_BAR) ; ce module agit sur la fenêtre par l'accès aux fenêtres d'app de CSP (ac.getAppWindows,
-- ac.accessAppWindow), lu à travers l'hôte : position et taille gardées quand le cadenas est fermé, hauteur de la barre
-- quand l'overlay est réduit, déplacement en glissant la barre, fermeture (rouverte depuis la barre d'apps de CSP).
-- Sans cet accès (CSP qui ne le permet pas), rien ne bouge : la barre reste dessinée, sans le bouton Fermer.
local Util = require('src/util')

local M = {}

M.TITLE = 'SetupLab Overlay'   -- NAME de la fenêtre dans manifest.ini
M.FULL_H = 230                 -- hauteur rendue en dépliant, faute de mieux (taille du manifest)
M.RETRY_FRAMES = 120           -- fenêtre introuvable : nouvelle recherche après ces images

-- appel d'une méthode de l'accès à la fenêtre (un argument au plus), protégé : fonctions C en jeu
local function call(object, method, arg)
  if object == nil then return false, nil end
  return pcall(function() return object[method](object, arg) end)
end

-- Accès à la fenêtre de l'overlay, cherché par son titre (état : table gardée par l'interface) ; nil si absent.
function M.find(host, state)
  if state.accessor then return state.accessor end
  state.wait = (state.wait or 0) - 1
  if state.wait > 0 then return nil end
  state.wait = M.RETRY_FRAMES
  local ac = host and host.ac
  local okL, list = pcall(function() return ac.getAppWindows() end)
  if not (okL and type(list) == 'table') then return nil end
  for _, w in ipairs(list) do
    if type(w) == 'table' and w.title == M.TITLE and type(w.name) == 'string' then
      local okA, accessor = pcall(function() return ac.accessAppWindow(w.name) end)
      local okV, valid = call(okA and accessor or nil, 'valid')
      if okV and valid then state.accessor = accessor end
      break
    end
  end
  return state.accessor
end

-- Une image de l'overlay. opts : locked (cadenas fermé), mini (réduit), barH (hauteur de la barre), dx, dy
-- (glissement de la barre, en pixels).
function M.frame(host, state, opts)
  local a = state.accessor
  if a == nil then return end
  local okP, pos = call(a, 'position')
  local okS, size = call(a, 'size')
  if not (okP and okS and pos and size) then return end
  local px, py, sx, sy = tonumber(pos.x), tonumber(pos.y), tonumber(size.x), tonumber(size.y)
  if not (Util.isFinite(px) and Util.isFinite(py) and Util.isFinite(sx) and Util.isFinite(sy)) then return end
  -- réduit : la barre seule ; déplié : la hauteur d'avant
  if opts.mini then
    if not state.wasMini and sy > opts.barH + 2 then state.fullH = sy end
    if math.abs(sy - opts.barH) > 1 then
      call(a, 'resize', host.vec2(sx, opts.barH))
      sy = opts.barH
    end
  elseif state.wasMini then
    sy = (state.lockSize and state.lockSize.y) or state.fullH or M.FULL_H
    call(a, 'resize', host.vec2(sx, sy))
  end
  state.wasMini = opts.mini == true
  if opts.locked then
    -- cadenas fermé : la position (et la taille dépliée) de l'instant du verrouillage
    if state.lockPos == nil then state.lockPos = { x = px, y = py } end
    if state.lockSize == nil and not opts.mini then state.lockSize = { x = sx, y = sy } end
    if math.abs(px - state.lockPos.x) > 0.5 or math.abs(py - state.lockPos.y) > 0.5 then
      call(a, 'move', host.vec2(state.lockPos.x, state.lockPos.y))
    end
    local ls = state.lockSize
    if ls and not opts.mini and (math.abs(sx - ls.x) > 0.5 or math.abs(sy - ls.y) > 0.5) then
      call(a, 'resize', host.vec2(ls.x, ls.y))
    elseif ls and opts.mini and math.abs(sx - ls.x) > 0.5 then
      call(a, 'resize', host.vec2(ls.x, opts.barH))
    end
  else
    state.lockPos, state.lockSize = nil, nil
    local dx, dy = tonumber(opts.dx) or 0, tonumber(opts.dy) or 0
    if (dx ~= 0 or dy ~= 0) and Util.isFinite(dx) and Util.isFinite(dy) then call(a, 'move', host.vec2(px + dx, py + dy)) end
  end
end

-- Fermer : la fenêtre est cachée ; la barre d'apps de CSP la rouvre.
function M.close(state)
  return (call(state.accessor, 'setVisible', false))
end

return M
