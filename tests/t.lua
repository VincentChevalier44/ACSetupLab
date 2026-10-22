-- Assertions du banc d'essai SetupLab.
local T = {}

local function show(v)
  if type(v) == 'string' then return string.format('%q', v) end
  return tostring(v)
end

function T.eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'valeurs différentes') .. ' : obtenu ' .. show(actual) .. ', attendu ' .. show(expected), 2)
  end
end

function T.near(actual, expected, tolerance, message)
  if type(actual) ~= 'number' or actual ~= actual or math.abs(actual - expected) > tolerance then
    error((message or 'écart hors tolérance') .. ' : obtenu ' .. show(actual) .. ', attendu ' .. show(expected)
      .. ' ± ' .. show(tolerance), 2)
  end
end

function T.ok(value, message)
  if not value then error(message or 'condition fausse', 2) end
end

function T.no(value, message)
  if value then error((message or 'condition vraie inattendue') .. ' : ' .. show(value), 2) end
end

function T.raises(fn, pattern, message)
  local ok, err = pcall(fn)
  if ok then error((message or 'erreur attendue') .. ' : aucune erreur', 2) end
  if pattern and not tostring(err):find(pattern) then
    error((message or 'erreur inattendue') .. ' : ' .. tostring(err), 2)
  end
end

function T.contains(text, fragment, message)
  if type(text) ~= 'string' or not text:find(fragment, 1, true) then
    error((message or 'fragment absent') .. ' : ' .. show(fragment), 2)
  end
end

function T.finite(x, message)
  if type(x) ~= 'number' or x ~= x or x == math.huge or x == -math.huge then
    error((message or 'nombre non fini') .. ' : ' .. show(x), 2)
  end
end

return T
