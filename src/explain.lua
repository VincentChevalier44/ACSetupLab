-- SetupLab — explications des réglages proposés (§12.2). Noyau pur (D5).
--
-- Une phrase courte en français par réglage : sens du changement, raison tirée du circuit ou de la
-- simulation (part du tour concernée, équilibre, pression à chaud, vitesse de pointe…), gain. Les
-- métriques « avant / après » viennent de la simulation du setup proposé avec et sans ce réglage.

local Util = require('src/util')
local Config = require('src/config')
local L = require('src/i18n')

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

-- Mots des phrases, en français et en anglais (décision de Vincent du 26/10/2026 : toute l'application traduite) ;
-- la phrase anglaise est apprise par la traduction (i18n.remember) : elle s'affiche si l'anglais est choisi.
local WORDS = {
  fr = {
    step = ' cran', steps = ' crans', gain = ' ; gain %s s', negligible = ' ; effet seul négligeable, utile avec les autres réglages',
    cost = ' ; coût %s s seul, compensé par les autres réglages', balanceSame = 'équilibre inchangé', balance = 'équilibre %s -> %s (%s)',
    neutral = 'plus neutre', under = 'plus sous-vireur', over = 'plus survireur', top = 'pointe %s -> %s km/h',
    fast = '%s du tour en virages rapides', downforce = 'plus d\'appui', power = '%s du tour à pleine charge', drag = 'moins de traînée',
    gearing = 'étagement adapté au circuit', rearLock = 'blocage de l\'arrière en premier %s -> %s du freinage',
    moreFront = 'plus de freinage à l\'avant', moreRear = 'plus de freinage à l\'arrière', brake = '%s du tour au freinage',
    torque = 'couple limitant à haute vitesse', modulation = 'marge de dosage sans ABS', hot = ' : à chaud %s -> %s psi',
    ideal = ' (idéale %s)', closer = ' : pression à chaud plus proche de l\'idéale',
    corner = 'plus d\'adhérence en virage, un peu moins au freinage et en traction',
    traction = 'plus d\'adhérence au freinage et en traction, un peu moins en virage',
    roll = 'répartition de la raideur au roulis (équilibre)', inside = 'motricité de la roue intérieure en sortie de virage lent',
    slow = '%s du tour en virages lents', yaw = 'moins de sous-virage en sortie de virage (moment de lacet du blocage)',
    rod = ' mm : appui et assiette (repère de hauteur vérifié au stand)',
    damper = ' : variation de charge des pneus sur la rugosité mesurée, plateforme aéro',
  },
  en = {
    step = ' step', steps = ' steps', gain = '; gain %s s', negligible = '; negligible effect alone, useful with the other settings',
    cost = '; costs %s s alone, made up for by the other settings', balanceSame = 'balance unchanged', balance = 'balance %s -> %s (%s)',
    neutral = 'more neutral', under = 'more understeer', over = 'more oversteer', top = 'top speed %s -> %s km/h',
    fast = '%s of the lap in fast corners', downforce = 'more downforce', power = '%s of the lap at full throttle', drag = 'less drag',
    gearing = 'gearing suited to the track', rearLock = 'rear locking first %s -> %s of braking',
    moreFront = 'more braking at the front', moreRear = 'more braking at the rear', brake = '%s of the lap under braking',
    torque = 'torque-limited at high speed', modulation = 'modulation margin without ABS', hot = ': hot %s -> %s psi',
    ideal = ' (ideal %s)', closer = ': hot pressure closer to the ideal',
    corner = 'more grip in corners, a little less under braking and traction',
    traction = 'more grip under braking and traction, a little less in corners',
    roll = 'roll stiffness distribution (balance)', inside = 'inside wheel traction out of slow corners',
    slow = '%s of the lap in slow corners', yaw = 'less understeer on corner exit (locking yaw moment)',
    rod = ' mm: downforce and rake (height reference checked in the pits)',
    damper = ': tyre load variation over the measured roughness, aero platform',
  },
}

local function signed(W, clicks)
  return (clicks > 0 and '+' or '') .. clicks .. (math.abs(clicks) > 1 and W.steps or W.step)
end

local function gainText(W, contribution)
  if contribution == nil then return '' end
  if contribution >= 0.0005 then return W.gain:format(fmt(contribution, 2)) end
  if contribution > -0.0005 then return W.negligible end
  return W.cost:format(fmt(-contribution, 2))
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

local function balanceWord(W, before, after)
  if before == nil or after == nil then return '' end
  local move = after - before
  if math.abs(move) < 0.002 then return W.balanceSame end
  return W.balance:format(fmt(before, 3), fmt(after, 3), math.abs(after - 1) < math.abs(before - 1) and W.neutral
    or (after < 1 and W.under or W.over))
end

local function sentence(W, label, c, ctx)
  local kind = c.var.kind
  local before, after, stats = ctx and ctx.before or {}, ctx and ctx.after or {}, ctx and ctx.stats or {}
  local gain = gainText(W, c.contribution)
  local topSpeed = before.vMax and after.vMax and W.top:format(fmt(before.vMax * 3.6, 0), fmt(after.vMax * 3.6, 0)) or nil
  local balance = before.balance and after.balance and balanceWord(W, before.balance, after.balance) or nil
  local sep = W == WORDS.en and ': ' or ' : '
  if kind == 'wing' then
    if c.clicks > 0 then
      return label .. ' ' .. signed(W, c.clicks) .. sep .. join({ part(stats.fast and W.fast:format(pct(stats.fast)), stats.fast),
        W.downforce, balance }) .. gain
    end
    return label .. ' ' .. signed(W, c.clicks) .. sep .. join({ part(stats.power and W.power:format(pct(stats.power)), stats.power),
      W.drag, topSpeed }) .. gain
  elseif kind == 'gear' or kind == 'final' then
    return label .. ' ' .. fmt(c.from, 3) .. ' -> ' .. fmt(c.to, 3) .. sep .. join({ topSpeed, W.gearing }) .. gain
  elseif kind == 'brakeBias' then
    return label .. ' ' .. fmt(c.from * 100, 1) .. ' -> ' .. fmt(c.to * 100, 1) .. ' %' .. sep .. join({
      part(before.rearLock and after.rearLock and W.rearLock:format(pct(before.rearLock), pct(after.rearLock)), before.rearLock),
      c.to > c.from and W.moreFront or W.moreRear }) .. gain
  elseif kind == 'brakePower' then
    return label .. ' ' .. fmt(c.from * 100, 0) .. ' -> ' .. fmt(c.to * 100, 0) .. ' %' .. sep .. join({
      part(stats.brake and W.brake:format(pct(stats.brake)), stats.brake), c.clicks > 0 and W.torque or W.modulation }) .. gain
  elseif kind == 'pressure' then
    return label .. ' ' .. fmt(c.from, 1) .. ' -> ' .. fmt(c.to, 1) .. ' psi' .. (before.hot and after.hot
      and (W.hot:format(fmt(before.hot, 1), fmt(after.hot, 1)) .. (after.ideal and W.ideal:format(fmt(after.ideal, 1)) or ''))
      or W.closer) .. gain
  elseif kind == 'camber' then
    return label .. ' ' .. fmt(c.from, 1) .. ' -> ' .. fmt(c.to, 1) .. '°' .. sep .. join({ c.to < c.from and W.corner or W.traction,
      balance }) .. gain
  elseif kind == 'arb' or kind == 'spring' or kind == 'heave' then
    return label .. ' ' .. signed(W, c.clicks) .. sep .. (balance or W.roll) .. gain
  elseif kind == 'diffPower' then
    return label .. ' ' .. fmt(c.from * 100, 0) .. ' -> ' .. fmt(c.to * 100, 0) .. ' %' .. sep .. (c.clicks > 0
      and join({ W.inside, part(stats.slow and W.slow:format(pct(stats.slow)), stats.slow) }) or W.yaw) .. gain
  elseif kind == 'rod' then
    return label .. ' ' .. fmt(c.from * 1000, 1) .. ' -> ' .. fmt(c.to * 1000, 1) .. W.rod .. gain
  elseif kind == 'damperSlow' or kind == 'damperFast' or kind == 'bumpStop' or kind == 'packer' then
    return label .. ' ' .. signed(W, c.clicks) .. W.damper .. gain
  elseif kind == 'limiter' then
    return label .. ' ' .. fmt(c.from * 100, 0) .. ' -> ' .. fmt(c.to * 100, 0) .. ' %' .. gain
  end
  return label .. sep .. fmt(c.from, 3) .. ' -> ' .. fmt(c.to, 3) .. gain
end

-- Phrase d'un changement, en français puis en anglais (aussi apprise par la traduction). c : { var = { kind,
-- label }, clicks, from, to, contribution } ; ctx : { stats (trackStats), before, after (métriques sans / avec le
-- réglage : balance, rearLock, vMax, hot, ideal) }.
function M.change(c, ctx)
  local label = c.var.label
  local fr = sentence(WORDS.fr, label, c, ctx)
  local en = sentence(WORDS.en, L.en(label), c, ctx)
  L.remember(fr, en)
  return fr, en
end

return M
