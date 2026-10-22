-- SetupLab — espace de setup (§10.3) : correspondance entre les crans du menu de setup (CSP) et les
-- grandeurs physiques du modèle, variables d'optimisation, vérification en jeu, rendu du fichier.
-- Noyau pur (D5).
--
-- Principes :
-- - l'optimiseur raisonne en crans (écart entier au cran actuel) ; la conversion vers le physique ne
--   sert qu'au modèle. Une erreur d'unité fausse la prédiction, jamais le fichier produit ;
-- - réglages groupés par essieu (gauche et droite reçoivent le même écart de crans : une asymétrie
--   existante est conservée) ;
-- - un réglage n'est optimisé que si son effet est modélisé et sa conversion vérifiée ou déduite ;
--   verrouillé, masqué ou non modélisé, il n'est jamais touché (D20, §0.6).
--
-- Unités des crans (API_NOTES §3, établies sur les voitures de test) : SPRING_RATE N/mm, ARB N/m,
-- ROD_LENGTH 0,1 mm, CAMBER dixièmes de degré, PRESSURE psi, FRONT_BIAS / BRAKE_POWER_MULT /
-- DIFF_POWER / ENGINE_LIMITER %, WING degrés, FUEL litres, GEAR_n / FINAL_GEAR_RATIO : rang dans le .rto.
-- Les réglages à SHOW_CLICKS=2 sont stockés en numéro de cran depuis MIN.

local Util = require('src/util')
local Config = require('src/config')
local K = Config.K

local M = {}

local floor, abs, max, min = math.floor, math.abs, math.max, math.min

-- Classes de confiance (§0.6, arbitrage A13) : rayon de recherche en crans autour du setup actuel.
M.LARGE, M.REDUCED, M.EXCLUDED, M.UNMODELLED = 'large', 'réduit', 'exclu', 'non modélisé'

-- Règles par nom de section : kind, essieu, facteur vers l'unité SI, classe de confiance, libellé.
local AXLE = { F = 'F', R = 'R' }
local function wheelAxle(name, prefix)
  local side, axle = name:match('^' .. prefix .. '_([LR])([FR])$')
  if side then return AXLE[axle] end
  return nil
end

local LABELS = {
  wing = 'Aileron', pressure = 'Pression', camber = 'Carrossage', spring = 'Ressort', heave = 'Ressort de pilonnage',
  rod = 'Hauteur de caisse', arb = 'Barre antiroulis', brakeBias = 'Répartition de freinage',
  brakePower = 'Puissance de freinage', diffPower = 'Différentiel (accélération)', fuel = 'Carburant',
  gear = 'Rapport', final = 'Rapport final', limiter = 'Limiteur de régime',
  damperSlow = 'Amortisseurs lents', damperFast = 'Amortisseurs rapides', bumpStop = 'Raideur de butée',
  packer = 'Course avant butée', toe = 'Pincement', diffCoast = 'Différentiel (lâcher)', diffPreload = 'Différentiel (précharge)',
}
local AXLE_LABEL = { F = ' avant', R = ' arrière' }

-- Raisons des réglages conservés (affichées, §10.3 : chaque réglage du setup a un statut).
M.KEPT = {
  roughness = 'conservé : rugosité de la piste à mesurer (rouler un tour valide avec ce setup, lignes droites comprises)',
  toe = 'conservé : son bénéfice (inscription, stabilité) est transitoire, hors du modèle quasi statique, et l\'angle '
    .. 'ne se déduit pas du cran (géométrie de direction inconnue)',
  diffCoast = 'conservé : effet au lever de pied et en entrée de virage (transitoire), non modélisé',
  diffPreload = 'conservé : effet à faible couple (épingles, transitoires), non modélisé',
  awd = 'conservé : sous-virage en sortie dû au couple transmis à l\'avant, non modélisé',
  brakeDuct = 'conservé : température des freins non modélisée',
  script = 'conservé : réglage défini par le script de la voiture (script.lua), effet inconnu',
  electronic = 'conservé : aide électronique, effet non modélisé',
  engineMap = 'conservé : cartographie moteur, courbes par cartographie non lues',
  heaveDamper = 'conservé : amortisseur de pilonnage du setup non relié au modèle (celui du fichier sert, H18)',
  packer = 'conservé : H16 à confirmer (course avant butée comptée depuis l\'assiette statique ou depuis la détente : '
    .. 'la course de suspension relevée au stand, rapport J0, tranchera) ; sous H16, aucun effet modélisé',
  unknown = 'conservé : réglage non reconnu par SetupLab',
}

-- Renvoie la description d'une section : kind, key (variable, réglages groupés par essieu), facteur vers
-- l'unité SI, classe de confiance et raison. Toute section reçoit une règle : un réglage non optimisé
-- est conservé avec sa raison.
function M.classify(name)
  local index = tonumber(name:match('^WING_(%d+)$'))
  if index then return { kind = 'wing', key = 'wing' .. index, index = index, factor = 1, class = M.LARGE } end
  local axle = wheelAxle(name, 'PRESSURE')
  if axle then return { kind = 'pressure', key = 'pressure' .. axle, axle = axle, factor = 1, class = M.LARGE } end
  -- Carrossage : latéral (roue extérieure ouverte par le roulis) contre longitudinal (carrossage
  -- statique) ; recherche réduite et garde-fou de l'écart de température intérieur − extérieur mesuré.
  axle = wheelAxle(name, 'CAMBER')
  if axle then return { kind = 'camber', key = 'camber' .. axle, axle = axle, factor = 1, class = M.REDUCED } end
  -- Ressorts, pilonnage, amortisseurs, butées, course avant butée : plateforme aéro contre variation de
  -- charge sur la rugosité de la piste (H16 à H19). Sans rugosité mesurée, seule la plateforme serait
  -- modélisée et l'optimiseur raidirait tout (relecture J3, M4) : conservés jusqu'à la mesure.
  local noCounterpart = M.KEPT.roughness
  axle = wheelAxle(name, 'SPRING_RATE')
  if axle then
    return { kind = 'spring', key = 'spring' .. axle, axle = axle, factor = 1000, class = M.EXCLUDED, reason = noCounterpart }
  end
  local heave = name:match('^SPRING_RATE_H([FR])$')
  if heave then
    return { kind = 'heave', key = 'heave' .. heave, axle = heave, factor = 1000, class = M.EXCLUDED, reason = noCounterpart }
  end
  -- Hauteur de caisse : le repère des LUT aéro de hauteur (LUT_GH) n'est pas vérifié contre la hauteur
  -- mesurée, et l'appui peut chuter de plusieurs secondes par centimètre près de la falaise
  -- (relecture J3, M6) : non optimisée avant la vérification en jeu (J5).
  axle = wheelAxle(name, 'ROD_LENGTH') or name:match('^ROD_LENGTH_H([FR])$')
  if axle then
    return { kind = 'rod', key = 'rod' .. axle, axle = axle, factor = 1e-4, class = M.EXCLUDED,
      reason = 'non optimisé : repère de hauteur de l\'aéro non vérifié (J5)' }
  end
  -- Amortisseurs (N·s/m) : compression et détente groupées par essieu (en linéaire, seule leur moyenne
  -- compte), lents et rapides séparés. Butées (N/mm) et course avant butée (mm).
  axle = wheelAxle(name, 'DAMP_BUMP') or wheelAxle(name, 'DAMP_REBOUND')
  if axle then
    return { kind = 'damperSlow', key = 'damperSlow' .. axle, axle = axle, factor = 1, class = M.EXCLUDED,
      reason = M.KEPT.roughness }
  end
  axle = wheelAxle(name, 'DAMP_FAST_BUMP') or wheelAxle(name, 'DAMP_FAST_REBOUND')
  if axle then
    return { kind = 'damperFast', key = 'damperFast' .. axle, axle = axle, factor = 1, class = M.EXCLUDED,
      reason = M.KEPT.roughness }
  end
  if name:match('^DAMP_[%u_]+_H[FR]$') then
    return { kind = 'heaveDamper', key = name, factor = 1, class = M.EXCLUDED, reason = M.KEPT.heaveDamper }
  end
  axle = wheelAxle(name, 'BUMP_STOP_RATE')
  if axle then
    return { kind = 'bumpStop', key = 'bumpStop' .. axle, axle = axle, factor = 1000, class = M.EXCLUDED,
      reason = M.KEPT.packer }
  end
  axle = wheelAxle(name, 'PACKER_RANGE')
  if axle then
    return { kind = 'packer', key = 'packer' .. axle, axle = axle, factor = 0.001, class = M.EXCLUDED,
      reason = M.KEPT.packer }
  end
  -- Pincement (0,01 mm de longueur du bras de direction).
  axle = wheelAxle(name, 'TOE_OUT')
  if axle then return { kind = 'toe', key = 'toe' .. axle, axle = axle, factor = 1e-5, class = M.EXCLUDED, reason = M.KEPT.toe } end
  if name == 'ARB_FRONT' then return { kind = 'arb', key = 'arbF', axle = 'F', factor = 1, class = M.REDUCED } end
  if name == 'ARB_REAR' then return { kind = 'arb', key = 'arbR', axle = 'R', factor = 1, class = M.REDUCED } end
  if name == 'FRONT_BIAS' then return { kind = 'brakeBias', key = 'brakeBias', factor = 0.01, class = M.LARGE } end
  -- Puissance de freinage : gain à haute vitesse si le couple limite, risque de blocage sans ABS (H15).
  if name == 'BRAKE_POWER_MULT' then return { kind = 'brakePower', key = 'brakePower', factor = 0.01, class = M.REDUCED } end
  -- Différentiel en accélération : motricité de la roue intérieure contre moment de lacet sous-vireur
  -- en sortie de virage (H20).
  if name == 'DIFF_POWER' or name == 'REAR_DIFF_POWER' then
    return { kind = 'diffPower', key = 'diffPower', factor = 0.01, class = M.REDUCED }
  end
  if name == 'DIFF_COAST' or name == 'REAR_DIFF_COAST' then
    return { kind = 'diffCoast', key = 'diffCoast', factor = 0.01, class = M.EXCLUDED, reason = M.KEPT.diffCoast }
  end
  if name == 'DIFF_PRELOAD' or name == 'REAR_DIFF_PRELOAD' then
    return { kind = 'diffPreload', key = 'diffPreload', factor = 1, class = M.EXCLUDED, reason = M.KEPT.diffPreload }
  end
  if name:match('^AWD_') or name:match('^CENTER_DIFF_') or name:match('^FRONT_DIFF_') then
    return { kind = 'awd', key = name, factor = 1, class = M.EXCLUDED, reason = M.KEPT.awd }
  end
  if name == 'ENGINE_LIMITER' then return { kind = 'limiter', key = 'limiter', factor = 0.01, class = M.LARGE } end
  if name == 'FUEL' then
    return { kind = 'fuel', key = 'fuel', factor = 1, class = M.EXCLUDED, reason = 'fixé par la règle de carburant' }
  end
  local gear = tonumber(name:match('^GEAR_(%d+)$'))
  if gear then return { kind = 'gear', key = 'gear' .. gear, gear = gear, factor = 1, class = M.LARGE } end
  if name == 'FINAL_GEAR_RATIO' then return { kind = 'final', key = 'final', factor = 1, class = M.LARGE } end
  if name:match('^BRAKE_DUCT') then
    return { kind = 'brakeDuct', key = name, factor = 1, class = M.EXCLUDED, reason = M.KEPT.brakeDuct }
  end
  if name:match('^CUSTOM_SCRIPT_ITEM') then
    return { kind = 'script', key = name, factor = 1, class = M.EXCLUDED, reason = M.KEPT.script }
  end
  if name:match('^ABS') or name:match('TRACTION_CONTROL') or name:match('^TC') or name:match('^ESC') then
    return { kind = 'electronic', key = name, factor = 1, class = M.EXCLUDED, reason = M.KEPT.electronic }
  end
  if name:match('MAP') or name:match('^ERS') or name:match('^MGU') or name:match('^KERS') then
    return { kind = 'engineMap', key = name, factor = 1, class = M.EXCLUDED, reason = M.KEPT.engineMap }
  end
  return { kind = 'unknown', key = name, factor = 1, class = M.UNMODELLED, reason = M.KEPT.unknown }
end

-- Valeur dans l'unité de setup.ini d'un cran CSP (avant facteur SI).
local function setupUnits(member, value)
  if member.showClicks == 2 then value = member.iniMin + value * member.iniStep end
  if member.kind == 'camber' then return value * (member.displayMultiplier or 0.1) end
  return value
end

-- Valeur physique (SI, degrés pour aileron et carrossage, psi pour la pression) d'un cran.
local function physicalOf(member, value)
  if member.kind == 'gear' or member.kind == 'final' then
    local entry = member.rto and member.rto[floor(value + 0.5) + 1]
    return entry and entry.ratio or nil
  end
  return setupUnits(member, value) * member.factor
end
M.physicalOf = physicalOf

-- Construit l'espace. args : { setupIni (car.ini['setup.ini']), spinners (Datasource.readSetup), ratios
-- (car.ratios), hiddenTabs (ensemble de noms d'onglets masqués, facultatif), tick? (rendu coopératif) }.
function M.build(args)
  local space = { vars = {}, skipped = {}, members = {}, byKey = {} }
  local setupIni = args.setupIni
  for count, sp in ipairs(args.spinners or {}) do
    if args.tick and count % 16 == 0 then args.tick() end
    local rule = M.classify(sp.name)
    local section = setupIni and setupIni.sections[sp.name]
    local function skip(reason)
      space.skipped[#space.skipped + 1] = { name = sp.name, label = sp.label, reason = reason }
    end
    if sp.readOnly == true or sp.visible == false then
      skip('verrouillé ou masqué (D20)')
    elseif section and args.hiddenTabs and args.hiddenTabs[Util.iniGet(setupIni, sp.name, 'TAB') or ''] then
      skip('onglet masqué (D20)')
    else
      local step = sp.step and sp.step > 0 and sp.step or 1
      local member = {
        name = sp.name, label = sp.label, kind = rule.kind, factor = rule.factor,
        min = sp.min, max = sp.max, step = step, current = sp.value,
        showClicks = Util.iniNumber(setupIni, sp.name, 'SHOW_CLICKS', sp.showClicksMode or 0),
        iniMin = Util.iniNumber(setupIni, sp.name, 'MIN', nil), iniStep = Util.iniNumber(setupIni, sp.name, 'STEP', nil),
        displayMultiplier = sp.displayMultiplier,
      }
      local problem = nil
      if (sp.value - sp.min) % step ~= 0 or sp.value < sp.min or sp.value > sp.max then
        problem = 'cran actuel hors grille'
      elseif member.showClicks == 2 and (member.iniMin == nil or member.iniStep == nil) then
        problem = 'MIN/STEP absents de setup.ini'
      elseif rule.kind == 'gear' or rule.kind == 'final' then
        local rtoName = Util.iniGet(setupIni, sp.name, 'RATIOS')
        member.rto = rtoName and args.ratios and args.ratios[rtoName:lower()] or nil
        if member.rto == nil or #member.rto ~= sp.max - sp.min + 1 then
          problem = 'fichier de rapports illisible ou incohérent'
        end
      end
      if problem then
        skip(problem)
      else
        local var = space.byKey[rule.key]
        if var == nil then
          var = {
            key = rule.key, kind = rule.kind, axle = rule.axle, index = rule.index, gear = rule.gear,
            class = rule.class, reason = rule.reason, members = {}, status = 'déduit',
            label = LABELS[rule.kind] and (LABELS[rule.kind] .. (rule.axle and AXLE_LABEL[rule.axle] or '')
              .. (rule.gear and (' ' .. rule.gear) or '') .. (rule.kind == 'wing' and (' ' .. sp.label) or ''))
              or (sp.label and sp.label ~= '' and sp.label or sp.name),
          }
          space.byKey[rule.key] = var
          space.vars[#space.vars + 1] = var
        end
        var.members[#var.members + 1] = member
        space.members[sp.name] = member
      end
    end
  end
  for _, var in ipairs(space.vars) do M.bounds(var) end
  return space
end

-- Bornes de l'écart (en crans) admissibles pour tous les membres, limitées par le rayon de recherche.
function M.bounds(var)
  local lo, hi = -math.huge, math.huge
  for _, m in ipairs(var.members) do
    lo = max(lo, -floor((m.current - m.min) / m.step + 1e-9))
    hi = min(hi, floor((m.max - m.current) / m.step + 1e-9))
  end
  var.rangeLo, var.rangeHi = lo, hi
  local radius = 0
  if var.class == M.LARGE then radius = K.optRadiusLarge elseif var.class == M.REDUCED then radius = K.optRadiusReduced end
  var.lo, var.hi = max(lo, -radius), min(hi, radius)
  if var.lo > var.hi then var.lo, var.hi = 0, 0 end
  return var
end

-- Rend optimisables (classe cls) les variables d'un genre exclu jusque-là, une fois la condition qui les
-- bloquait levée (repère vérifié, mesure faite) ; note : raison affichée en complément.
function M.release(space, kind, cls, note)
  for _, var in ipairs(space.vars) do
    if var.kind == kind and var.class == M.EXCLUDED then
      var.class, var.reason, var.note = cls, nil, note
      M.bounds(var)
    end
  end
end

-- Statut de chaque réglage du setup (§10.3) : optimisé (rayon de recherche en crans), conservé (raison)
-- ou non touché (verrouillé, masqué, cran incohérent). Renvoie la liste { label, names, status, detail }.
function M.statusRows(space)
  local rows = {}
  for _, var in ipairs(space.vars) do
    local names = {}
    for _, m in ipairs(var.members) do names[#names + 1] = m.name end
    local open = var.class == M.LARGE or var.class == M.REDUCED
    local optimized = open and var.status ~= 'écart' and var.hi > var.lo
    local detail
    if optimized then
      detail = (var.class == M.LARGE and 'recherche large' or 'recherche réduite') .. ' : ' .. var.lo .. ' à +' .. var.hi .. ' crans'
        .. (var.note and (' ; ' .. var.note) or '')
      if var.kind == 'pressure' then
        detail = detail .. ' au plus ; restreinte au lancement du calcul (pression à chaud jamais plus loin de l\'idéale, '
          .. 'jamais abaissée en surchauffe, recherche réduite sans mesure)'
      elseif var.kind == 'camber' then
        detail = detail .. ' au plus ; restreinte au lancement du calcul selon l\'écart intérieur − extérieur mesuré'
      end
    elseif open and var.status == 'écart' then
      detail = 'conservé : conversion contredite par la mesure en jeu'
    elseif open then
      detail = 'conservé : aucune marge de réglage'
    else
      detail = var.reason or 'conservé'
    end
    local wetShort, wet = M.wetStatus(var.kind, optimized)
    rows[#rows + 1] = { key = var.key, label = var.label, names = names, status = optimized and 'optimisé' or 'conservé',
      detail = detail, wetShort = wetShort, wet = wet }
  end
  for _, s in ipairs(space.skipped) do
    rows[#rows + 1] = { label = s.label or s.name, names = { s.name }, status = 'non touché', detail = s.reason,
      wetShort = 'non touché', wet = 'non touché sous la pluie non plus : ' .. tostring(s.reason) }
  end
  return rows
end

-- Statut d'un réglage sur piste mouillée (D16 amendé le 21/10/2026, décision de Vincent : « vérifie que tous
-- les paramètres sont pris en compte ») : mot court et phrase. Optimisé : avec l'adhérence mouillée (H25 à
-- H27) ; règle (carburant, aides) ; ou inchangé, avec la raison.
local WET_RULES = {
  fuel = { 'règle', 'règle de carburant, la même que sur le sec' },
  electronic = { 'règle', 'règle pluie des aides : niveaux plus stricts (réglage « Pluie : niveaux d\'aide en plus »)' },
  engineMap = { 'inchangé', 'cartographie moteur non modélisée : à adoucir au volant si la motricité manque' },
  toe = { 'inchangé', 'pincement : effet transitoire non modélisé, sur le mouillé comme sur le sec' },
  diffCoast = { 'inchangé', 'différentiel au lâcher : effet transitoire non modélisé' },
  diffPreload = { 'inchangé', 'précharge du différentiel : effet à faible couple non modélisé' },
  awd = { 'inchangé', 'répartition 4×4 non modélisée' },
  brakeDuct = { 'inchangé', 'température des freins non modélisée (freins plus froids sous la pluie)' },
  script = { 'inchangé', 'réglage du script de la voiture : effet inconnu' },
  unknown = { 'inchangé', 'réglage inconnu' },
}
function M.wetStatus(kind, optimized)
  local rule = WET_RULES[kind]
  if rule then return rule[1], rule[2] end
  if not optimized then return 'inchangé', 'conservé pour la même raison que sur le sec' end
  if kind == 'pressure' then
    return 'modélisé', 'optimisé : pneus plus froids sur le mouillé (H27), pression à chaud visée à l\'idéale'
  end
  if kind == 'rod' then
    return 'modélisé', 'optimisé avec l\'adhérence mouillée (H25 à H27) ; l\'aquaplanage selon la hauteur de caisse n\'est '
      .. 'pas modélisé'
  end
  return 'modélisé', 'optimisé avec l\'adhérence mouillée (H25 à H27) : film d\'eau, aquaplanage, pneus plus froids'
end

-- Règle pluie des aides au pilotage (D16 amendé le 21/10/2026, décision de Vincent : « plus de TC, plus d'ABS »
-- sous la pluie). Aides au pilote, effet non modélisé (seul l'ABS compte : il supprime le risque de
-- blocage H15) : steps niveaux vers une coupure plus précoce, sens lu dans la table de la voiture ; aide
-- coupée : mise au steps-ième niveau à partir du plus permissif. aids : CarModel.readAid ; current :
-- niveaux du fichier de setup ({ ABS = n, TRACTION_CONTROL = n }, absent du fichier : nil). Renvoie, par
-- section, { section, from, to, slipFrom, slipTo, note } (to nil : inchangé, note : raison).
function M.aidsPlan(aids, current, steps, wet)
  local plan = {}
  for _, key in ipairs({ 'tc', 'abs' }) do
    local a = aids and aids[key]
    local section = key == 'tc' and 'TRACTION_CONTROL' or 'ABS'
    local from = current and current[section]
    local entry = { section = section, from = from }
    plan[section] = entry
    if not wet then
      entry.note = 'piste sèche : inchangé'
    elseif a == nil or not a.present then
      entry.note = 'absent de cette voiture'
    elseif from == nil then
      entry.note = 'niveau absent du fichier de setup : à régler au volant'
    elseif (steps or 0) <= 0 then
      entry.note = 'réglage « Pluie : niveaux d\'aide en plus » à 0'
    else
      local n = a.count
      local level = floor(from + 0.5)
      local target
      if level <= 0 then
        target = a.stricterUp and steps or (n - steps + 1)
      else
        target = level + (a.stricterUp and steps or -steps)
      end
      target = math.max(1, math.min(n, target))
      if target == level then
        entry.note = 'déjà au niveau le plus strict'
      else
        entry.to = target
        entry.slipFrom = level > 0 and a.levels and a.levels[level] or nil
        entry.slipTo = a.levels and a.levels[target] or nil
      end
    end
  end
  return plan
end

-- Remplace les VALUE de sections facultatives (aides au pilotage) : une section absente du texte, ou sans
-- VALUE, est ignorée ; jamais un refus d'enregistrement. Renvoie le texte et la liste des sections remplacées.
function M.renderOptional(text, values)
  local present = {}
  local current = nil
  for line in (text:gsub('\r\n', '\n') .. '\n'):gmatch('([^\n]*)\n') do
    local name = line:match('^%s*%[([^%]]+)%]%s*$')
    if name then
      current = name
    elseif current and line:match('^%s*VALUE%s*=') then
      present[current] = true
    end
  end
  local subset, applied = {}, {}
  local names = {}
  for name in pairs(values) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    if present[name] then
      subset[name] = values[name]
      applied[#applied + 1] = name
    end
  end
  if #applied == 0 then return text, applied end
  local out = M.render(text, subset)
  if out == nil then return text, {} end
  return out, applied
end

-- Variables optimisables (classe large ou réduite, effet modélisé, conversion non contredite).
function M.optimizable(space)
  local list = {}
  for _, var in ipairs(space.vars) do
    if (var.class == M.LARGE or var.class == M.REDUCED) and var.status ~= 'écart' and var.hi > var.lo then
      list[#list + 1] = var
    end
  end
  return list
end

-- Valeur physique moyenne d'une variable pour un écart d de crans.
function M.physical(var, d)
  local sum, count = 0, 0
  for _, m in ipairs(var.members) do
    local value = physicalOf(m, m.current + d * m.step)
    if value == nil then return nil end
    sum, count = sum + value, count + 1
  end
  return count > 0 and sum / count or nil
end

-- Écrit dans setup (format CarModel.defaultSetup) la valeur physique de chaque variable : écart
-- deltas[key] (0 si absent) pour les variables optimisées, cran actuel pour les autres.
function M.apply(space, setup, deltas)
  for _, var in ipairs(space.vars) do
    local value = M.physical(var, deltas and deltas[var.key] or 0)
    if value ~= nil then
      local kind, axle = var.kind, var.axle
      if kind == 'wing' then
        setup.wingAngles[var.index] = value
      elseif kind == 'pressure' or kind == 'camber' or kind == 'spring' or kind == 'heave' or kind == 'rod' or kind == 'arb'
        or kind == 'bumpStop' or kind == 'packer' then
        setup[kind .. axle] = value
      elseif kind == 'damperSlow' or kind == 'damperFast' then
        setup[(kind == 'damperSlow' and 'dampSlow' or 'dampFast') .. axle] = value
      elseif kind == 'brakeBias' or kind == 'brakePower' or kind == 'diffPower' or kind == 'fuel' then
        setup[kind] = value
      elseif kind == 'limiter' then
        setup.limiterPct = value
      elseif kind == 'gear' then
        setup.gears[var.gear] = value
      elseif kind == 'final' then
        setup.final = value
      end
    end
  end
  return setup
end

-- Référence de la hauteur de caisse : la hauteur (mesurée en jeu, ou par défaut) correspond aux tiges du
-- setup courant, pas à ROD_LENGTH de suspensions.ini ; ressorts et pressions de ce setup servent à
-- corriger la hauteur statique d'un autre setup (écrasement au repos).
function M.attach(space, base)
  for _, axle in ipairs({ 'F', 'R' }) do
    local var = space.byKey['rod' .. axle]
    if var then base['rodRef' .. axle] = M.physical(var, 0) end
  end
  base.rideRef = M.apply(space, { wingAngles = {}, gears = {} }, {})
  return base
end

-- Vérification en jeu (§10.3, point 3 de la revue) : valeur déduite contre valeur mesurée par CSP.
-- state : Datasource.readCarState ; base : CarModel (limiteur). Statut : vérifié, écart (variable
-- exclue) ou déduit (rien de mesurable). Renvoie la liste des lignes du tableau du rapport J0.
local WHEELS = { F = { 1, 2 }, R = { 3, 4 } }
function M.verify(space, state, base)
  local rows = {}
  if state == nil or not state.ok then return rows end
  local values = state.values
  for _, var in ipairs(space.vars) do
    local predicted = M.physical(var, 0)
    local measured, tol = nil, nil
    if var.kind == 'pressure' then
      local sum, n = 0, 0
      for _, w in ipairs(WHEELS[var.axle]) do
        local p = state.wheels[w] and state.wheels[w].tyreStaticPressure
        if p then sum, n = sum + p, n + 1 end
      end
      if n > 0 then measured, tol = sum / n, K.verifyTolPressure end
    elseif var.kind == 'brakeBias' then
      measured, tol = values.brakeBias, K.verifyTolFraction
    elseif var.kind == 'diffPower' then
      measured, tol = values.differentialPower, K.verifyTolFraction
    elseif var.kind == 'gear' then
      measured, tol = state.gearRatios[var.gear + 2], K.verifyTolRatio
    elseif var.kind == 'final' then
      measured, tol = state.finalRatio, K.verifyTolRatio
    elseif var.kind == 'wing' and state.flags.isInPit then
      local w = state.wings[var.index + 1]
      measured, tol = w and w.angle, K.verifyTolAngle
    elseif var.kind == 'limiter' and base and base.limiter then
      measured, tol = values.rpmLimiter and values.rpmLimiter / base.limiter, K.verifyTolFraction
    end
    if measured ~= nil and predicted ~= nil then
      if abs(measured - predicted) <= tol then
        var.status = 'vérifié'
      else
        var.status = 'écart'
        var.reason = 'déduit ' .. Util.fmt(predicted, 4) .. ', mesuré ' .. Util.fmt(measured, 4) .. ' : non optimisé'
      end
    end
    rows[#rows + 1] = { key = var.key, label = var.label, current = var.members[1].current, predicted = predicted,
      measured = measured, status = var.status }
  end
  return rows
end

-- Valeurs de crans à écrire (section -> valeur) pour des écarts donnés ; contrôle de bornes et de grille.
-- allowed : clés fixées par une règle (carburant de qualification) bien que non optimisables.
function M.values(space, deltas, allowed)
  local out, errors = {}, {}
  for _, var in ipairs(space.vars) do
    local d = deltas[var.key] or 0
    if d ~= 0 then
      if var.class ~= M.LARGE and var.class ~= M.REDUCED and not (allowed and allowed[var.key]) then
        errors[#errors + 1] = var.key .. ' : réglage non optimisable'
      end
      for _, m in ipairs(var.members) do
        local v = m.current + d * m.step
        if v < m.min or v > m.max or (v - m.min) % m.step ~= 0 or v ~= floor(v) then
          errors[#errors + 1] = m.name .. ' : ' .. tostring(v) .. ' hors plage ou hors grille'
        else
          out[m.name] = v
        end
      end
    end
  end
  return out, errors
end

-- Nom de section du fichier de setup : CSP écrit parfois INTERNAL_GEAR_n / FINAL_RATIO au lieu des
-- noms de setup.ini (constaté au J0).
local ALIASES = { FINAL_GEAR_RATIO = { 'FINAL_RATIO' } }
local function candidates(name)
  local list = { name }
  local gear = name:match('^GEAR_(%d+)$')
  if gear then list[2] = 'INTERNAL_GEAR_' .. gear end
  for _, alias in ipairs(ALIASES[name] or {}) do list[#list + 1] = alias end
  return list
end

-- Remplace les VALUE des sections modifiées dans le texte du setup courant (relu au moment du clic,
-- D8 : le setup courant n'est pas modifié, seul ce texte l'est). Tout le reste est conservé tel quel.
-- Renvoie le texte, ou nil et la liste des erreurs (section introuvable : refus explicite).
function M.render(currentText, values)
  if type(currentText) ~= 'string' or currentText == '' then return nil, { 'setup courant illisible' } end
  local lines = {}
  for line in (currentText:gsub('\r\n', '\n') .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = line end
  local sectionAt = {}
  local current = nil
  for i, line in ipairs(lines) do
    local name = line:match('^%s*%[([^%]]+)%]%s*$')
    if name then
      current = name
    elseif current and line:match('^%s*VALUE%s*=') then
      sectionAt[current] = i
    end
  end
  local errors = {}
  local names = {}
  for name in pairs(values) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local done = false
    for _, section in ipairs(candidates(name)) do
      local i = sectionAt[section]
      if i and not done then
        lines[i] = 'VALUE=' .. string.format('%d', values[name])
        done = true
      end
    end
    if not done then errors[#errors + 1] = name .. ' : section absente du setup courant' end
  end
  if #errors > 0 then return nil, errors end
  if lines[#lines] == '' then lines[#lines] = nil end
  return table.concat(lines, '\n') .. '\n', nil
end

-- Distance au setup actuel (somme des écarts relatifs au rayon de chaque variable), pour départager
-- deux setups de temps égal (§10.4).
function M.distance(vars, deltas)
  local sum = 0
  for _, var in ipairs(vars) do
    local span = max(1, var.hi - var.lo)
    sum = sum + abs(deltas[var.key] or 0) / span
  end
  return sum
end

return M
