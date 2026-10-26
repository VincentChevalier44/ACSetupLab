-- SetupLab — langue de l'interface (décision de Vincent du 26/10/2026 : anglais par défaut, français au choix ;
-- « il faut absolument tout traduire, les menus, toute l'application complète ainsi que les tooltips »).
-- Les textes du code sont écrits en français ; l'anglais vient de src/lang_en.lua : phrases exactes, et modèles à
-- trous « %s » (nombres, noms de fichiers, phrases imbriquées, elles-mêmes traduites) reconnus au moment de
-- l'affichage. Un message déjà affiché change donc de langue avec le réglage. Un texte fait de plusieurs phrases
-- est traduit phrase par phrase si aucun modèle ne le reconnaît en entier. Module pur (aucune API du jeu).
local EN = require('src/lang_en')

local M = { lang = 'en', misses = nil, computed = 0 }

local exact = {}
-- phrases calculées apprises avec leur traduction (explications des réglages) ; bornées
local learned, learnedCount = {}, 0
local LEARNED_MAX = 4000
local byLead, noLead, generic = {}, {}, {}
local cache, cacheSize = {}, 0
-- textes remplis par L.f (nombres qui changent à chaque image) : à part, pour ne pas chasser les traductions du cache
local outputs, outputsSize = {}, 0
local OUTPUTS_MAX = 600
local CACHE_MAX = 3000
local LEAD = 3
local GENERIC = 6

local function escape(s)
  return (s:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0'))
end

do
  local list = {}
  for fr, en in pairs(EN) do
    if fr:find('%s', 1, true) then
      local holes = select(2, fr:gsub('%%s', ''))
      local pattern = '^' .. escape(fr):gsub('%%%%s', '(.-)') .. '$'
      -- morceau fixe le plus long : filtre rapide (recherche simple) avant le motif
      local need = ''
      for chunk in (fr .. '%s'):gmatch('(.-)%%s') do
        if #chunk > #need then need = chunk end
      end
      list[#list + 1] = { pattern = pattern, en = en, lead = fr:match('^(.-)%%s') or '', literal = #fr - 2 * holes, need = need }
      -- le modèle lui-même (L.f traduit le modèle, puis le remplit)
      exact[fr] = en
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
    -- modèles génériques (« %s : %s », « %s (%s) »…) : en dernier recours, après le découpage en phrases
    if p.literal <= GENERIC then
      generic[#generic + 1] = p
    elseif #p.lead >= LEAD then
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

-- Majuscule en tête si le texte français en avait une (« Calcul %s lancé » -> « %s computation started »).
local function capital(fr, out)
  local a, a2, b = fr:byte(1), fr:byte(2) or 0, out:byte(1)
  local upper = (a and a >= 65 and a <= 90) or (a == 195 and a2 >= 128 and a2 <= 158)
  if upper and b and b >= 97 and b <= 122 then return string.char(b - 32) .. out:sub(2) end
  return out
end

-- Reste-t-il du français ? (lettres accentuées, mots courants) : seulement pour signaler un oubli.
local FRENCH_WORDS = { ' le ', ' la ', ' les ', ' des ', ' du ', ' de ', ' et ', ' un ', ' une ', ' pour ', ' avec ', ' sur ',
  ' au ', ' aux ', ' est ', ' pas ', ' ou ', ' dans ', ' votre ', ' vos ', ' avant ', ' tour ', ' tours ', 'meilleur', 'moyenne',
  ' sans ', ' puis ', ' rien ', ' piste', 'qualif ', 'qualif,', 'réglage' }
local function looksFrench(s)
  if type(s) ~= 'string' then return false end
  -- lettres accentuées (pas × ni ÷), œ
  if s:find('\195[\128-\150\152-\182\184-\191]') or s:find('\197[\146\147]') then return true end
  local padded = ' ' .. s:lower() .. ' '
  for _, w in ipairs(FRENCH_WORDS) do
    if padded:find(w, 1, true) then return true end
  end
  return false
end

-- Apprend la traduction d'une phrase calculée (le module qui la calcule la connaît dans les deux langues).
M.looksFrench = looksFrench

local bySentences, full

-- Un trou qui contient une fin de phrase ou de ligne a sans doute avalé du texte d'une autre phrase : le modèle n'est
-- alors retenu qu'en second choix, après le découpage en phrases.
local function whole(c)
  return not (c:find(' ; ', 1, true) or c:find('\n', 1, true) or c:find('. ', 1, true))
end

local function tryPatterns(list, s, depth, strict)
  local first = nil
  for _, p in ipairs(list) do
    if (p.lead == '' or s:sub(1, #p.lead) == p.lead) and (p.need == '' or s:find(p.need, 1, true)) then
      local caps = { s:match(p.pattern) }
      local ok = caps[1] ~= nil
      if ok and strict then
        for _, c in ipairs(caps) do ok = ok and whole(c) end
      end
      if ok then
        for i, c in ipairs(caps) do
          if c ~= '' then caps[i] = full(c, depth + 1) or c end
        end
        local out = capital(s, fill(p.en, caps))
        -- un modèle qui laisse du français : au premier niveau, le suivant peut mieux découper
        if depth > 0 or not looksFrench(out) then return out end
        first = first or out
      end
    end
  end
  return first
end

-- Modèle précis (début du texte d'abord, puis les autres).
local function precise(s, depth, strict)
  local list = #s >= LEAD and byLead[s:sub(1, LEAD)]
  return (list and tryPatterns(list, s, depth, strict)) or tryPatterns(noLead, s, depth, strict)
end

-- Texte fait de plusieurs phrases ou lignes : chacune traduite.
local SEPARATORS = { '\n', '. ', ' ; ', ' — ' }
function bySentences(s, depth)
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
        out[k] = (part ~= '' and full(part, depth + 1)) or part
      end
      return table.concat(out, sep == '. ' and ' ' or (sep == ' ; ' and '; ' or sep))
    end
  end
  return nil
end

-- Texte entier : phrase exacte, modèle précis aux trous sans fin de phrase, phrase par phrase, modèle précis
-- quelconque, modèle générique (« %s : %s »…), ou nil.
-- Le premier découpage qui ne laisse rien en français est retenu, sinon le premier trouvé.
local STEPS = {
  function(s, depth) return precise(s, depth, true) end,
  function(s, depth) return bySentences(s, depth) end,
  function(s, depth) return precise(s, depth, false) end,
  function(s, depth) return depth <= 4 and tryPatterns(generic, s, depth, false) or nil end,
}
function full(s, depth)
  local e = exact[s] or learned[s]
  if e then return e end
  if depth > 7 or #s < 2 then return nil end
  local first = nil
  for _, step in ipairs(STEPS) do
    local out = step(s, depth)
    if out then
      if depth > 0 or not looksFrench(out) then return out end
      first = first or out
    end
  end
  return first
end

function M.remember(fr, en)
  if type(fr) ~= 'string' or type(en) ~= 'string' or learned[fr] == en then return end
  if learnedCount >= LEARNED_MAX then learned, learnedCount = {}, 0 end
  learned[fr], learnedCount = en, learnedCount + 1
  cache[fr] = nil
end

-- Texte en anglais quelle que soit la langue choisie.
function M.en(s)
  if type(s) ~= 'string' or s == '' then return s end
  return full(s, 0) or s
end

-- Oublie les traductions déjà faites (banc : oublis comptés depuis le début).
function M.reset()
  cache, cacheSize = {}, 0
end

function M.set(lang)
  M.lang = lang == 'fr' and 'fr' or 'en'
end

-- Texte dans la langue choisie (le texte français tel quel en français).
function M.t(s)
  if M.lang ~= 'en' or type(s) ~= 'string' or s == '' then return s end
  local hit = cache[s]
  if hit then return hit end
  if outputs[s] then return s end
  M.computed = M.computed + 1
  if M.recent then M.recent[#M.recent + 1] = s end
  local out = full(s, 0) or s
  if M.misses and not (exact[s] or learned[s]) and looksFrench(out) then M.misses[s] = out end
  -- banc : textes laissés tels quels qui contiennent des mots (à relire : français sans accent ?)
  if M.unmatched and out == s and s:find('%l%l%l%l') then M.unmatched[s] = true end
  if cacheSize >= CACHE_MAX then
    cache, cacheSize = {}, 0
  end
  cache[s], cacheSize = out, cacheSize + 1
  if out ~= s then cache[out], cacheSize = out, cacheSize + 1 end
  return out
end

-- Modèle français traduit puis rempli (string.format).
function M.f(fmt, ...)
  local out = string.format(M.t(fmt), ...)
  if M.lang == 'en' and not outputs[out] then
    if outputsSize >= OUTPUTS_MAX then outputs, outputsSize = {}, 0 end
    outputs[out], outputsSize = true, outputsSize + 1
  end
  return out
end

return M
