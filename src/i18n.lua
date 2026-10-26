-- SetupLab — langue de l'interface (décision de Vincent du 26/10/2026 : anglais par défaut, français au choix ;
-- « il faut absolument tout traduire, les menus, toute l'application complète ainsi que les tooltips »).
-- Les textes du code sont écrits en français ; l'anglais vient de src/lang_en.lua : phrases exactes, et modèles à
-- trous « %s » (nombres, noms de fichiers, phrases imbriquées, elles-mêmes traduites) reconnus au moment de
-- l'affichage. Un message déjà affiché change donc de langue avec le réglage. Un texte fait de plusieurs phrases
-- est traduit phrase par phrase si aucun modèle ne le reconnaît en entier. Module pur (aucune API du jeu).
local EN = require('src/lang_en')

local M = { lang = 'en', misses = nil }

local exact = {}
local byLead, noLead = {}, {}
local cache, cacheSize = {}, 0
local CACHE_MAX = 3000
local LEAD = 3

local function escape(s)
  return (s:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0'))
end

do
  local list = {}
  for fr, en in pairs(EN) do
    if fr:find('%s', 1, true) then
      local holes = select(2, fr:gsub('%%s', ''))
      local pattern = '^' .. escape(fr):gsub('%%%%s', '(.-)') .. '$'
      list[#list + 1] = { pattern = pattern, en = en, lead = fr:match('^(.-)%%s') or '', literal = #fr - 2 * holes }
    else
      exact[fr] = en
    end
  end
  -- le modèle le plus précis d'abord (le plus de texte fixe), puis l'ordre alphabétique (résultat stable)
  table.sort(list, function(a, b)
    if a.literal ~= b.literal then return a.literal > b.literal end
    return a.pattern < b.pattern
  end)
  for _, p in ipairs(list) do
    if #p.lead >= LEAD then
      local key = p.lead:sub(1, LEAD)
      byLead[key] = byLead[key] or {}
      byLead[key][#byLead[key] + 1] = p
    else
      noLead[#noLead + 1] = p
    end
  end
end

-- Trous du modèle anglais : « {n} » (ordre libre), sinon « %s » dans l'ordre.
local function fill(en, caps)
  if en:find('{%d}') then
    return (en:gsub('{(%d)}', function(n) return caps[tonumber(n)] or '' end))
  end
  local i = 0
  return (en:gsub('%%s', function()
    i = i + 1
    return caps[i] or ''
  end))
end

local translate

local function tryPatterns(list, s, depth)
  for _, p in ipairs(list) do
    if p.lead == '' or s:sub(1, #p.lead) == p.lead then
      local caps = { s:match(p.pattern) }
      if caps[1] ~= nil then
        for i, c in ipairs(caps) do caps[i] = translate(c, depth + 1) or c end
        return fill(p.en, caps)
      end
    end
  end
  return nil
end

-- Traduction d'un texte entier (phrase exacte ou modèle), ou nil.
function translate(s, depth)
  local e = exact[s]
  if e then return e end
  if depth > 4 or #s < 2 then return nil end
  local list = #s >= LEAD and byLead[s:sub(1, LEAD)]
  return (list and tryPatterns(list, s, depth)) or tryPatterns(noLead, s, depth)
end

-- Texte fait de plusieurs phrases ou lignes : chacune traduite.
local SEPARATORS = { '\n', '. ', ' ; ', ' — ' }
local function bySentences(s, depth)
  for _, sep in ipairs(SEPARATORS) do
    local start, parts = 1, {}
    while true do
      local i, j = s:find(sep, start, true)
      if i == nil then break end
      parts[#parts + 1] = s:sub(start, sep == '. ' and i or (i - 1))
      start = j + 1
    end
    if #parts > 0 then
      parts[#parts + 1] = s:sub(start)
      local out = {}
      for k, part in ipairs(parts) do
        out[k] = translate(part, depth) or (part ~= '' and bySentences(part, depth + 1)) or part
      end
      return table.concat(out, sep == '. ' and ' ' or sep)
    end
  end
  return nil
end

-- Reste-t-il du français ? (lettres accentuées, mots courants) : seulement pour signaler un oubli.
local FRENCH_WORDS = { ' le ', ' la ', ' les ', ' des ', ' du ', ' de ', ' et ', ' un ', ' une ', ' pour ', ' avec ', ' sur ',
  ' au ', ' aux ', ' est ', ' pas ', ' ou ', ' dans ', ' votre ', ' vos ' }
function M.looksFrench(s)
  if type(s) ~= 'string' then return false end
  if s:find('[\195\197]') then return true end
  local padded = ' ' .. s:lower() .. ' '
  for _, w in ipairs(FRENCH_WORDS) do
    if padded:find(w, 1, true) then return true end
  end
  return false
end

function M.set(lang)
  local wanted = lang == 'fr' and 'fr' or 'en'
  if wanted ~= M.lang then M.lang = wanted end
end

-- Texte dans la langue choisie (le texte français tel quel en français).
function M.t(s)
  if M.lang ~= 'en' or type(s) ~= 'string' or s == '' then return s end
  local hit = cache[s]
  if hit then return hit end
  local out = translate(s, 0) or bySentences(s, 0) or s
  if M.misses and M.looksFrench(out) then M.misses[s] = out end
  if cacheSize >= CACHE_MAX then
    cache, cacheSize = {}, 0
  end
  cache[s], cacheSize = out, cacheSize + 1
  return out
end

-- Modèle français traduit puis rempli (string.format).
function M.f(fmt, ...)
  return string.format(M.t(fmt), ...)
end

return M
