-- SetupLab — explications des réglages proposés (§12.2). Noyau pur (D5).
--
-- Une phrase courte en français par réglage : sens du changement, raison tirée du circuit ou de la
-- simulation (part du tour concernée, équilibre, pression à chaud, vitesse de pointe…), gain. Les
-- métriques « avant / après » viennent de la simulation du setup proposé avec et sans ce réglage.

local Util = require('src/util')
local Config = require('src/config')

local M = {}

local fmt = Util.fmt

M.FAST_CORNER = Config.K.fastCornerKmh / 3.6   -- §7.3 : virage rapide
M.SLOW_CORNER = Config.K.slowCornerKmh / 3.6   -- §7.3 : virage lent

-- Part du temps au tour (0–1) par situation, d'après un tour simulé (buf de Sim.run) : virages rapides
-- et lents (limités par l'adhérence), pleine charge, freinage.
function M.trackStats(track, buf)
  local total, fast, slow, power, brake = 0, 0, 0, 0, 0
  local n, ds = track.n, track.ds
  for k = 1, n do
    local v = buf.v[k]
    local v2 = buf.v[k < n and k + 1 or 1]
    local dt = 2 * ds / math.max(0.5, v + v2)
    total = total + dt
    local code = buf.limit[k]
    if code == 1 then
      if v >= M.FAST_CORNER then fast = fast + dt elseif v <= M.SLOW_CORNER then slow = slow + dt end
    elseif code == 4 then
      power = power + dt
    elseif code == 2 then
      brake = brake + dt
    end
  end
  if total <= 0 then total = 1 end
  return { fast = fast / total, slow = slow / total, power = power / total, brake = brake / total }
end

-- Équilibre par virage (§12.1) : points limités par l'adhérence en virage regroupés en virages (suites
-- de points contigus), équilibre moyen pondéré par le temps, abscisse du milieu. Renvoie la liste
-- { s, balance, v } (v : vitesse minimale du virage).
function M.cornerBalance(track, buf)
  local list, current = {}, nil
  local n, ds = track.n, track.ds
  for k = 1, n do
    local v = buf.v[k]
    if buf.limit[k] == 1 and (buf.balance[k] or 0) > 0 then
      local dt = ds / math.max(0.5, v)
      if current == nil then
        current = { s0 = track.s[k], sum = 0, time = 0, v = v }
        list[#list + 1] = current
      end
      current.sum, current.time = current.sum + buf.balance[k] * dt, current.time + dt
      current.s1, current.v = track.s[k], math.min(current.v, v)
    else
      current = nil
    end
  end
  local out = {}
  for _, c in ipairs(list) do out[#out + 1] = { s = (c.s0 + c.s1) / 2, balance = c.sum / c.time, v = c.v } end
  return out
end

local function pct(x) return fmt(x * 100, 0) .. ' %' end

local function signed(clicks)
  return (clicks > 0 and '+' or '') .. clicks .. ' cran' .. (math.abs(clicks) > 1 and 's' or '')
end

local function gainText(contribution)
  if contribution == nil then return '' end
  if contribution >= 0.0005 then return ' ; gain ' .. fmt(contribution, 2) .. ' s' end
  if contribution > -0.0005 then return ' ; effet seul négligeable, utile avec les autres réglages' end
  return ' ; coût ' .. fmt(-contribution, 2) .. ' s seul, compensé par les autres réglages'
end

-- Morceau « libellé valeur » seulement si la valeur est connue (aucun chiffre inventé, relecture J8 m1).
local function part(text, value)
  if value == nil then return nil end
  return text
end

local function join(list)
  local out = {}
  for i = 1, #list do
    if list[i] then out[#out + 1] = list[i] end
  end
  return table.concat(out, ', ')
end

local function balanceWord(before, after)
  if before == nil or after == nil then return '' end
  local move = after - before
  local side = after < 1 and 'sous-vireur' or 'survireur'
  if math.abs(move) < 0.002 then return 'équilibre inchangé' end
  return 'équilibre ' .. fmt(before, 3) .. ' -> ' .. fmt(after, 3) .. ' (' .. (math.abs(after - 1) < math.abs(before - 1)
    and 'plus neutre' or ('plus ' .. side)) .. ')'
end

-- Phrase d'un changement. c : { var = { kind, label }, clicks, from, to, contribution } ; ctx :
-- { stats (trackStats), before, after (métriques sans / avec le réglage : balance, rearLock, vMax,
-- hot, ideal) }.
function M.change(c, ctx)
  local kind, label = c.var.kind, c.var.label
  local before, after, stats = ctx and ctx.before or {}, ctx and ctx.after or {}, ctx and ctx.stats or {}
  local gain = gainText(c.contribution)
  local topSpeed = before.vMax and after.vMax
    and ('pointe ' .. fmt(before.vMax * 3.6, 0) .. ' -> ' .. fmt(after.vMax * 3.6, 0) .. ' km/h') or nil
  local balance = before.balance and after.balance and balanceWord(before.balance, after.balance) or nil
  if kind == 'wing' then
    if c.clicks > 0 then
      return label .. ' ' .. signed(c.clicks) .. ' : ' .. join({ part(stats.fast and (pct(stats.fast)
        .. ' du tour en virages rapides'), stats.fast), 'plus d\'appui', balance }) .. gain
    end
    return label .. ' ' .. signed(c.clicks) .. ' : ' .. join({ part(stats.power and (pct(stats.power)
      .. ' du tour à pleine charge'), stats.power), 'moins de traînée', topSpeed }) .. gain
  elseif kind == 'gear' or kind == 'final' then
    return label .. ' ' .. fmt(c.from, 3) .. ' -> ' .. fmt(c.to, 3) .. ' : ' .. join({ topSpeed, 'étagement adapté au circuit' })
      .. gain
  elseif kind == 'brakeBias' then
    return label .. ' ' .. fmt(c.from * 100, 1) .. ' -> ' .. fmt(c.to * 100, 1) .. ' % : ' .. join({
      part(before.rearLock and after.rearLock and ('blocage de l\'arrière en premier ' .. pct(before.rearLock) .. ' -> '
        .. pct(after.rearLock) .. ' du freinage'), before.rearLock),
      c.to > c.from and 'plus de freinage à l\'avant' or 'plus de freinage à l\'arrière' }) .. gain
  elseif kind == 'brakePower' then
    return label .. ' ' .. fmt(c.from * 100, 0) .. ' -> ' .. fmt(c.to * 100, 0) .. ' % : ' .. join({
      part(stats.brake and (pct(stats.brake) .. ' du tour au freinage'), stats.brake),
      c.clicks > 0 and 'couple limitant à haute vitesse' or 'marge de dosage sans ABS' }) .. gain
  elseif kind == 'pressure' then
    return label .. ' ' .. fmt(c.from, 1) .. ' -> ' .. fmt(c.to, 1) .. ' psi' .. (before.hot and after.hot and (' : à chaud '
      .. fmt(before.hot, 1) .. ' -> ' .. fmt(after.hot, 1) .. ' psi' .. (after.ideal and (' (idéale ' .. fmt(after.ideal, 1)
      .. ')') or '')) or ' : pression à chaud plus proche de l\'idéale') .. gain
  elseif kind == 'camber' then
    return label .. ' ' .. fmt(c.from, 1) .. ' -> ' .. fmt(c.to, 1) .. '° : ' .. join({ c.to < c.from
      and 'plus d\'adhérence en virage, un peu moins au freinage et en traction'
      or 'plus d\'adhérence au freinage et en traction, un peu moins en virage', balance }) .. gain
  elseif kind == 'arb' or kind == 'spring' or kind == 'heave' then
    return label .. ' ' .. signed(c.clicks) .. ' : ' .. (balance or 'répartition de la raideur au roulis (équilibre)') .. gain
  elseif kind == 'diffPower' then
    return label .. ' ' .. fmt(c.from * 100, 0) .. ' -> ' .. fmt(c.to * 100, 0) .. ' % : ' .. (c.clicks > 0
      and join({ 'motricité de la roue intérieure en sortie de virage lent', part(stats.slow and (pct(stats.slow)
        .. ' du tour en virages lents'), stats.slow) })
      or 'moins de sous-virage en sortie de virage (moment de lacet du blocage)') .. gain
  elseif kind == 'rod' then
    return label .. ' ' .. fmt(c.from * 1000, 1) .. ' -> ' .. fmt(c.to * 1000, 1) .. ' mm : appui et assiette (repère de hauteur '
      .. 'vérifié au stand)' .. gain
  elseif kind == 'damperSlow' or kind == 'damperFast' or kind == 'bumpStop' or kind == 'packer' then
    return label .. ' ' .. signed(c.clicks) .. ' : variation de charge des pneus sur la rugosité mesurée, plateforme aéro' .. gain
  elseif kind == 'limiter' then
    return label .. ' ' .. fmt(c.from * 100, 0) .. ' -> ' .. fmt(c.to * 100, 0) .. ' %' .. gain
  end
  return label .. ' : ' .. fmt(c.from, 3) .. ' -> ' .. fmt(c.to, 3) .. gain
end

return M
