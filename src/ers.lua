-- SetupLab — ERS (§8.9, D13). Noyau pur (D5).
--
-- Lecture d'ers.ini et des contrôleurs ctrl_ers_N.ini (profils de déploiement du cockpit), bilan
-- d'énergie le long du tour, stratégie de déploiement optimisée par programmation dynamique sur l'état
-- de charge de la batterie, zone d'accélération par zone d'accélération.
--
-- Hypothèses (API_NOTES, à confirmer en jeu) :
-- - H21 : le couple de [KINETIC] TORQUE_CURVE (N·m selon le régime moteur) s'ajoute au vilebrequin et
--   passe par le rapport engagé ; [FRONT_MOTORS] TORQUE_CURVE est le couple total de l'essieu avant
--   selon le régime des roues avant ;
-- - H22 : batterie de capacité P_max × DISCHARGE_TIME (temps pour la vider à pleine puissance) ;
--   MAX_KJ_PER_LAP borne l'énergie déployée par tour ;
-- - H23 : récupération = CHARGE_K × 1000 de la puissance de freinage, plus le couple de COAST_CURVE au
--   lever de pied ;
-- - entrées de contrôleur inconnues de la simulation (OVERSTEER_FACTOR, glissements…) : neutres
--   (multiplication par 1, ajout de 0), signalées.

local Util = require('src/util')
local Config = require('src/config')
local K = Config.K

local M = {}

local floor, max, min = math.floor, math.max, math.min

-- Entrées de contrôleur que la simulation connaît.
M.KNOWN_INPUTS = { GAS = true, RPMS = true, SPEED_KMH = true, GEAR = true, BRAKE = true, LATG = true }

local function lutIn(car, name)
  if type(name) ~= 'string' or name == '' then return nil end
  if name:match('^%s*%(.*%)%s*$') then return Util.parseLutText(name, K.maxLutPoints) end
  return car.luts and car.luts[name:lower()] or nil
end

-- Un profil de contrôleurs (ctrl_ers_N.ini) : nom et liste ordonnée { input, combinator, lut, up, down }.
local function readProfile(car, ini)
  local profile = { name = Util.iniGet(ini, 'HEADER', 'NAME') or '', controllers = {}, unknown = {} }
  for _, section in ipairs(ini.order) do
    if section:find('^CONTROLLER_') then
      local input = (Util.iniGet(ini, section, 'INPUT') or ''):upper()
      local c = {
        input = input, combinator = (Util.iniGet(ini, section, 'COMBINATOR') or 'ADD'):upper(),
        lut = lutIn(car, Util.iniGet(ini, section, 'LUT')),
        up = Util.iniNumber(ini, section, 'UP_LIMIT', math.huge), down = Util.iniNumber(ini, section, 'DOWN_LIMIT', -math.huge),
      }
      if not M.KNOWN_INPUTS[input] then profile.unknown[#profile.unknown + 1] = input end
      profile.controllers[#profile.controllers + 1] = c
    end
  end
  return profile
end

-- Définition de l'ERS d'une voiture (car : sortie de Datasource.readCar). Renvoie nil sans ERS, sinon
-- { usable, reason?, notes, kinetic, front?, profiles, frontProfiles, defaultProfile }.
function M.read(car)
  local ini = car.ini['ers.ini']
  if ini == nil then
    if car.ini['kers.ini'] then
      return { usable = false, reason = 'kers.ini (ancien format) : non modélisé', notes = {}, profiles = {}, frontProfiles = {} }
    end
    return nil
  end
  local function num(section, key) return Util.iniNumber(ini, section, key, nil) end
  local spec = { usable = false, notes = {}, profiles = {}, frontProfiles = {} }
  spec.kinetic = {
    torque = lutIn(car, Util.iniGet(ini, 'KINETIC', 'TORQUE_CURVE')), coast = lutIn(car, Util.iniGet(ini, 'KINETIC', 'COAST_CURVE')),
    chargeK = num('KINETIC', 'CHARGE_K') or 0, dischargeTime = (num('KINETIC', 'DISCHARGE_TIME') or 0) / 1000,
    maxKjPerLap = num('KINETIC', 'MAX_KJ_PER_LAP'),
  }
  if ini.sections.FRONT_MOTORS then
    spec.front = { torque = lutIn(car, Util.iniGet(ini, 'FRONT_MOTORS', 'TORQUE_CURVE')),
      dischargeTime = (num('FRONT_MOTORS', 'DISCHARGE_TIME') or 0) / 1000 }
  end
  if ini.sections.HEAT and (num('HEAT', 'CHARGE_K') or 0) > 0 then
    spec.notes[#spec.notes + 1] = 'MGU-H (charge selon la pression de turbo) non modélisé'
  end
  spec.defaultProfile = num('COCKPIT_CONTROLS', 'DELIVERY_PROFILE') or num('KINETIC', 'DEFAULT_CONTROLLER') or 0
  for name, profileIni in pairs(car.ini) do
    local front, index = name:match('^ctrl_ers_(front_?)(%d+)%.ini$')
    if index == nil then index = name:match('^ctrl_ers_(%d+)%.ini$') end
    if index then
      local list = front and spec.frontProfiles or spec.profiles
      list[tonumber(index)] = readProfile(car, profileIni)
    end
  end
  local k = spec.kinetic
  local hasTorque = false
  for _, curve in ipairs({ k.torque, spec.front and spec.front.torque }) do
    if curve then
      for i = 1, curve.n do hasTorque = hasTorque or curve.y[i] > 0 end
    end
  end
  if not (k.maxKjPerLap and k.maxKjPerLap > 0) then
    spec.reason = 'MAX_KJ_PER_LAP absent ou nul'
  elseif not hasTorque then
    spec.reason = 'aucune courbe de couple non nulle (KINETIC, FRONT_MOTORS)'
  elseif not (k.dischargeTime > 0 or (spec.front and spec.front.dischargeTime > 0)) then
    spec.reason = 'DISCHARGE_TIME absent : capacité de la batterie inconnue'
  elseif spec.profiles[spec.defaultProfile] == nil and next(spec.profiles) ~= nil then
    spec.reason = 'profil de déploiement par défaut (' .. spec.defaultProfile .. ') introuvable'
  else
    spec.usable = true
  end
  return spec
end

-- Valeur d'un profil de contrôleurs (déploiement 0–1) pour des entrées { GAS, RPMS, SPEED_KMH, GEAR,
-- BRAKE, LATG } : départ à 0, ADD ajoute la LUT, MULT multiplie, bornes de chaque contrôleur ; entrée
-- inconnue : neutre.
function M.profileValue(profile, inputs)
  local value = 0
  for _, c in ipairs(profile.controllers) do
    local x = inputs[c.input]
    if x ~= nil and c.lut then
      local y = Util.lutEval(c.lut, x)
      if c.combinator == 'MULT' then value = value * y else value = value + y end
      value = Util.clamp(value, c.down, c.up)
    end
  end
  return Util.clamp(value, 0, 1)
end

-- Rejoue la batterie le long du tour (points start, start+1, … en boucle) : déploiement demandé mask[k]
-- (0–1) à la puissance pleine pFull[k] (kW) pendant dt[k] (s), récupération rec[k] (kJ) ; le
-- déploiement s'arrête quand la batterie est vide ou que la limite par tour est atteinte. out : tableau
-- du déploiement effectif. opts : { capacity, maxPerLap, soc0 } (kJ). Renvoie le bilan
-- { deployed, recovered, socMin, socEnd, limited }.
function M.replay(n, start, mask, pFull, dt, rec, opts, out)
  local soc, deployed, recovered = opts.soc0, 0, 0
  local socMin, limited = soc, false
  local k = start
  for _ = 1, n do
    local want = mask[k] * pFull[k] * dt[k]
    local give = want
    if give > soc then give = soc end
    if deployed + give > opts.maxPerLap then give = max(0, opts.maxPerLap - deployed) end
    if give < want - 1e-9 then limited = true end
    out[k] = want > 0 and mask[k] * give / want or 0
    soc = soc - give
    deployed = deployed + give
    local r = min(rec[k], opts.capacity - soc)
    soc, recovered = soc + r, recovered + r
    if soc < socMin then socMin = soc end
    k = k % n + 1
  end
  return { deployed = deployed, recovered = recovered, socMin = socMin, socEnd = soc, limited = limited }
end

-- Programmation dynamique du déploiement (§8.9) : étapes (zones d'accélération dans l'ordre du tour),
-- chacune avec des options { gain (s), energy (kJ) } (la première : aucun déploiement) et la récupération
-- qui la suit (recovery, kJ). État : charge de la batterie et énergie déjà déployée, discrétisées
-- prudemment (charge arrondie vers le bas, énergie déployée vers le haut), ou au plus proche (nearest :
-- la faisabilité est alors vérifiée en rejouant la batterie sur le tour retenu). Contraintes : charge ≥ 0
-- à chaque étape, ≤ capacité, énergie déployée ≤ maxPerLap. opts : { capacity, maxPerLap, soc0, levels
-- (charge), dLevels? (énergie déployée ; levels par défaut), nearest?, socEndMin? (régime établi en
-- course), tick? }. Renvoie le gain total, l'option retenue par étape et la charge finale, ou nil.
function M.optimize(stages, opts)
  local L = opts.levels or K.ersLevels
  local LD = opts.dLevels or L
  local capStep, dStep = opts.capacity / L, max(1e-9, opts.maxPerLap / LD)
  local NEG = -math.huge
  -- V[s][d] : meilleur gain pour la charge s·capStep et l'énergie déployée d·dStep
  local V = {}
  for s = 0, L do
    V[s] = {}
    for d = 0, LD do V[s][d] = NEG end
  end
  local tick = opts.tick or function() end
  local up = opts.nearest and 0.5 or 1 - 1e-9
  local down = opts.nearest and 0.5 or 1e-9
  local s0 = floor(opts.soc0 / capStep + down)
  V[min(L, max(0, s0))][0] = 0
  local parents = {}
  for j, stage in ipairs(stages) do
    local W, P = {}, {}
    for s = 0, L do
      W[s], P[s] = {}, {}
      for d = 0, LD do W[s][d] = NEG end
    end
    for s = 0, L do
      if s % 16 == 0 then tick() end
      for d = 0, LD do
        local v = V[s][d]
        if v > NEG then
          for o, option in ipairs(stage.options) do
            local soc = s * capStep - option.energy
            local dep = d * dStep + option.energy
            if soc >= -1e-9 and dep <= opts.maxPerLap + 1e-9 then
              local socNext = min(opts.capacity, soc + (stage.recovery or 0))
              local s2 = min(L, floor(socNext / capStep + down))
              local d2 = min(LD, floor(dep / dStep + up))
              local value = v + option.gain
              if value > W[s2][d2] then
                W[s2][d2] = value
                P[s2][d2] = { s = s, d = d, o = o }
              end
            end
          end
        end
      end
    end
    V, parents[j] = W, P
  end
  local best, bs, bd = NEG, nil, nil
  local socMin = opts.socEndMin or 0
  for s = 0, L do
    if s * capStep >= socMin - 1e-9 then
      for d = 0, LD do
        if V[s][d] > best then best, bs, bd = V[s][d], s, d end
      end
    end
  end
  if bs == nil then return nil end
  local choice = {}
  local s, d = bs, bd
  for j = #stages, 1, -1 do
    local p = parents[j][s][d]
    choice[j] = p.o
    s, d = p.s, p.d
  end
  return best, choice, bs * capStep
end


-- ---------------------------------------------------------------------------
-- Physique de l'ERS sur la voiture configurée et sur un tour simulé
-- ---------------------------------------------------------------------------

local G = 9.80665
local RPM = 60 / (2 * math.pi)

-- Forces de l'ERS à plein déploiement (N) sur la grille de vitesses de la voiture configurée (H21) :
-- MGU-K par rapport (couple au régime moteur, à travers la boîte, nul au-delà du limiteur), moteurs avant
-- (couple de l'essieu au régime des roues avant). Tableaux réutilisés dans eff ; capacité de la batterie
-- (H22, kJ) : somme, par système, de la puissance maximale atteinte sous la vitesse de pointe ×
-- DISCHARGE_TIME. Renvoie eff.
function M.tables(spec, eff)
  local count, dv = eff.speedCount, eff.dv
  local gearForce = eff.ersGearForce or {}
  eff.ersGearForce = gearForce
  local front = eff.ersFront or {}
  eff.ersFront = front
  local kinetic, motors = spec.kinetic, spec.front
  local vMax = eff.topSpeed or (count - 1) * dv
  local pK, pF = 0, 0
  for g = 1, eff.gearCount do
    local tab = gearForce[g] or {}
    gearForce[g] = tab
    local total = eff.gears[g] * eff.final
    for i = 1, count do
      local v = (i - 1) * dv
      local rpm = v / eff.wheelRadius * total * RPM
      local force = 0
      if kinetic.torque and rpm <= eff.limiter then
        force = max(0, Util.lutEval(kinetic.torque, rpm)) * total * K.drivetrainEfficiency / eff.wheelRadius
      end
      tab[i] = force
      if v <= vMax and force * v > pK then pK = force * v end
    end
  end
  for g = eff.gearCount + 1, #gearForce do gearForce[g] = nil end
  local radius = eff.compound.front.radius
  for i = 1, count do
    local v = (i - 1) * dv
    local force = 0
    if motors and motors.torque then force = max(0, Util.lutEval(motors.torque, v / radius * RPM)) / radius end
    front[i] = force
    if v <= vMax and force * v > pF then pF = force * v end
  end
  eff.ersCapacity = (pK * kinetic.dischargeTime + pF * (motors and motors.dischargeTime or 0)) / 1000
  eff.ersMaxPerLap = kinetic.maxKjPerLap
  eff.ersEta = Util.clamp(kinetic.chargeK * 1000, 0, 1)
  eff.ersOn = true
  return eff
end

-- Indice de la grille de vitesses et rapport engagé (enveloppe de car_model) à la vitesse v.
local function gearAt(eff, v)
  local i = min(eff.speedCount, floor(v / eff.dv) + 1)
  return i, eff.gear[i] or eff.gearCount
end

-- Force de l'ERS à plein déploiement (N) à la vitesse v, au rapport de l'enveloppe.
function M.forceAt(eff, v)
  local i, g = gearAt(eff, v)
  local tab = eff.ersGearForce[g]
  return (tab and tab[i] or 0) + eff.ersFront[i]
end

-- Bilan d'énergie par point d'un tour simulé (buf de Sim.run) : puissance de l'ERS à plein déploiement
-- (kW), durée du point (s), énergie récupérable (kJ, H23 : CHARGE_K × 1000 de la puissance de freinage,
-- plus COAST_CURVE au régime moteur pendant le freinage). out : { pFull, dt, rec }, réutilisé.
function M.arrays(spec, eff, track, buf, out)
  local n, ds = track.n, track.ds
  out.pFull, out.dt, out.rec = out.pFull or {}, out.dt or {}, out.rec or {}
  local brakeCode = 2
  for k = 1, n do
    local k2 = k < n and k + 1 or 1
    local v, v2 = buf.v[k], buf.v[k2]
    local dt = 2 * ds / max(K.simMinSpeed, v + v2)
    local i, g = gearAt(eff, v)
    out.pFull[k] = M.forceAt(eff, v) * v / 1000
    out.dt[k] = dt
    local rec = 0
    if buf.limit[k] == brakeCode and v > v2 then
      local resist = eff.drag[i] + eff.rollRes[i]
      local brakeForce = max(0, eff.mass * (v * v - v2 * v2) / (2 * ds) - resist)
      rec = eff.ersEta * brakeForce * v * dt
      if spec.kinetic.coast then
        local rpm = min(eff.limiter, v / eff.wheelRadius * eff.gears[g] * eff.final * RPM)
        rec = rec + max(0, Util.lutEval(spec.kinetic.coast, rpm)) * rpm / RPM * dt
      end
    end
    out.rec[k] = rec / 1000
  end
  return out
end

-- Zones d'accélération du tour (passe avant non bridée : puissance, motricité, passage de rapport), dans
-- l'ordre du tour à partir du point start ; une zone s'arrête au premier point limité par un virage ou
-- par le freinage. Renvoie la liste { first, count, last } (indices de points).
function M.runs(track, buf, start)
  local n = track.n
  local list, current = {}, nil
  local k = start
  for _ = 1, n do
    local code = buf.limit[k]
    local accelerating = code == 3 or code == 4 or code == 5
    if accelerating then
      if current == nil then
        current = { first = k, count = 0 }
        list[#list + 1] = current
      end
      current.count = current.count + 1
      current.last = k
    else
      current = nil
    end
    k = k % n + 1
  end
  return list
end

-- Masque de déploiement d'un profil du cockpit (ctrl_ers_N et ctrl_ers_front_N) sur un tour simulé :
-- entrées GAS (1 en accélération), BRAKE, RPMS, SPEED_KMH, GEAR (enveloppe), LATG ; avec deux systèmes,
-- déploiement global pondéré par leurs forces. out : tableau réutilisé.
function M.profileMask(spec, index, eff, track, buf, out)
  local profile, frontProfile = spec.profiles[index], spec.frontProfiles[index]
  local inputs = {}
  for k = 1, track.n do
    local v = buf.v[k]
    local code = buf.limit[k]
    local i, g = gearAt(eff, v)
    inputs.GAS = (code == 3 or code == 4 or code == 5) and 1 or 0
    inputs.BRAKE = code == 2 and 1 or 0
    inputs.RPMS = v / eff.wheelRadius * eff.gears[g] * eff.final * RPM
    inputs.SPEED_KMH, inputs.GEAR, inputs.LATG = v * 3.6, g, (buf.ayReq[k] or 0) / G
    local uK = profile and M.profileValue(profile, inputs) or 0
    local uF = frontProfile and M.profileValue(frontProfile, inputs) or uK
    local fK = eff.ersGearForce[g] and eff.ersGearForce[g][i] or 0
    local fF = eff.ersFront[i]
    out[k] = (fK + fF) > 0 and (uK * fK + uF * fF) / (fK + fF) or 0
  end
  return out
end

return M
