-- SetupLab — schéma unique des réglages (§15) et constantes internes.
-- Toute valeur chiffrée du PDR est une valeur de départ réglable ici, jamais en dur ailleurs (§0.1).

local Util = require('src/util')

local M = {}

M.appName = 'SetupLab'
-- Première bêta publique (décision de Vincent du 22/10/2026 : « on la présentera comme la version bêta numéro
-- un, v1.0 ») ; les versions 1.0.0 à 1.7.0 d'avant étaient internes (CHANGELOG.md).
M.version = '1.0.0-beta.1.5'
M.milestone = 'J0 à J8 (qualification, course, mesure, DRS, ERS, interface, persistance), chargement dans la voiture, affinage, pluie, '
  .. 'activation, mémoire du circuit, validation avant enregistrement, vos temps réels, vos retouches gardées'
M.schemaVersion = 1   -- version du format de stockage (§13) ; une version plus récente est ignorée

-- Réglages modifiables dans l'interface (§11), seuls conservés d'une séance à l'autre (§13) : les autres
-- (app active, tranche de calcul, garde de frame…) gardent leur valeur par défaut, un stockage ne peut
-- donc ni désactiver l'app ni casser le budget de frame.
-- 1.5 (décision de Vincent du 26/10/2026) : le nombre de tours de course se saisit dans l'onglet Course et se garde
-- par circuit (plus de réglage global) ; minimum avant une proposition ; langue.
M.EDITABLE = { 'compoundChoice', 'fuelMarginPct', 'fuelQualiLaps', 'perfStab', 'drsTrafficPct',
  'driverMarginPct', 'optBudgetEvalsQ', 'optBudgetEvalsC', 'calibrationAuto', 'wetAidLevels', 'refineLaps',
  'refineMinLaps', 'refineMinMinutes', 'language' }

-- Noms des fichiers de setup produits (§12.3) ; l'horodatage est ajouté au préfixe : heure locale de
-- Windows (demande de Vincent du 21/10/2026), sinon UTC dit dans le nom. Décision de Vincent du 22/10/2026
-- (« on a du mal à les différencier ») : nom choisi, sinon « SetupLab », puis le genre (Qualif, Course) et
-- « Pluie » sous la pluie ; versions « _vN », numérotées à la suite sur le circuit.
M.exportTestPrefix = 'SetupLab_Test_'
M.fileDefaultName = 'SetupLab'
M.fileGenre = { quali = 'Qualif', race = 'Course' }
M.fileWet = 'Pluie'
M.exportQualiPrefix = M.fileDefaultName .. '_' .. M.fileGenre.quali .. '_'
M.exportRacePrefix = M.fileDefaultName .. '_' .. M.fileGenre.race .. '_'
-- Copie du setup en cours écrite juste avant un chargement dans la voiture (réversibilité).
M.exportBackupPrefix = 'SetupLab_Avant_chargement_'

-- Mots des noms de fichiers dans la langue choisie (décision de Vincent du 26/10/2026 : « le setup s'enregistre en
-- français quand on a la langue française et en anglais quand on a la langue anglaise ») ; les fichiers déjà écrits
-- dans l'autre langue restent reconnus (numéros de version, mémoire du circuit, rangement).
M.fileWords = {
  fr = { quali = 'Qualif', race = 'Course', wet = 'Pluie', trial = 'essai', backup = M.exportBackupPrefix,
    default = 'SetupLab_Defaut' },
  en = { quali = 'Quali', race = 'Race', wet = 'Wet', trial = 'trial', backup = 'SetupLab_Before_load_',
    default = 'SetupLab_Default' },
}
function M.fileWordsFor(lang)
  return M.fileWords[lang == 'fr' and 'fr' or 'en']
end

-- Effets d'un setup proposé, validés un par un (décision de Vincent du 26/10/2026 : « au lieu de valider une fois
-- globalement le setup, il va le valider un par un chaque effet ») : groupes de réglages par genre de variable
-- (setup_space). Le composé de pneus va avec les pneus, les aides de la règle pluie avec les aides.
M.effectGroups = {
  { key = 'aero', label = 'Aéro', kinds = { wing = true } },
  { key = 'tyres', label = 'Pneus', kinds = { pressure = true }, compound = true },
  { key = 'geometry', label = 'Géométrie', kinds = { camber = true, toe = true } },
  { key = 'suspension', label = 'Suspension', kinds = { arb = true, spring = true, heave = true, rod = true, damperSlow = true,
    damperFast = true, heaveDamper = true, bumpStop = true, packer = true } },
  { key = 'transmission', label = 'Transmission', kinds = { gear = true, final = true, diffPower = true, diffCoast = true,
    diffPreload = true, awd = true } },
  { key = 'brakes', label = 'Freins', kinds = { brakeBias = true, brakePower = true, brakeDuct = true } },
  { key = 'engine', label = 'Moteur', kinds = { limiter = true, engineMap = true } },
  { key = 'aids', label = 'Aides au pilotage', aids = true },
  { key = 'other', label = 'Autres réglages', other = true },
}

-- Mémoire du circuit (décision de Vincent du 21/10/2026 : « une mémoire par circuit et par type de séance ») :
-- setup validé par voiture, circuit, disposition, séance et état de piste. AC ne distingue pas une journée
-- circuit d'un essai ; hotlap et time attack comptent comme essai.
M.memoryGroups = {
  { key = 'essai', label = 'essai ou journée circuit', kind = 'quali' },
  { key = 'qualif', label = 'qualification', kind = 'quali' },
  { key = 'course', label = 'course', kind = 'race' },
}

-- Réglages utilisateur (§15). kind : boolean | number | integer | enum.
M.settings = {
  { key = 'enabled', kind = 'boolean', default = true, label = 'Application active' },
  { key = 'frameGuardMs', kind = 'number', default = 4, min = 1, max = 20, label = 'Coût maximal de l\'app par frame (ms)' },
  { key = 'sliceBudgetMs', kind = 'number', default = 2, min = 0.25, max = 8, label = 'Tranche de calcul par frame (ms)' },
  { key = 'ds', kind = 'number', default = 2, min = 1, max = 5, label = 'Pas d\'échantillonnage du circuit (m)' },
  -- budgets par défaut 1 200 / 400 : A13 tranchée par Vincent le 20/10/2026 (§14.3 sur le pire cas)
  { key = 'optBudgetEvalsQ', kind = 'integer', default = 1200, min = 100, max = 50000,
    label = 'Budget qualification (évaluations de tour)' },
  { key = 'optBudgetEvalsC', kind = 'integer', default = 400, min = 20, max = 10000, label = 'Budget course (évaluations de relais)' },
  { key = 'fuelMarginPct', kind = 'number', default = 3, min = 0, max = 20, label = 'Marge de carburant en course (%)' },
  { key = 'fuelQualiLaps', kind = 'number', default = 0, min = 0, max = 5,
    label = 'Carburant en qualification (tours ; 0 = minimum autorisé)' },
  { key = 'perfStab', kind = 'number', default = 0.6, min = 0, max = 1, label = 'Performance ↔ Stabilité' },
  { key = 'wBal', kind = 'number', default = 1, min = 0, max = 10, label = 'Poids de base : équilibre' },
  { key = 'wStab', kind = 'number', default = 1, min = 0, max = 10, label = 'Poids de base : stabilité' },
  { key = 'wTraffic', kind = 'number', default = 1, min = 0, max = 10, label = 'Poids de base : trafic' },
  { key = 'wRob', kind = 'number', default = 1, min = 0, max = 10, label = 'Poids de base : robustesse' },
  { key = 'drsTrafficPct', kind = 'number', default = 30, min = 0, max = 100, label = 'Tours en trafic avec DRS en course (%)' },
  { key = 'raceLaps', kind = 'integer', default = 0, min = 0, max = 500,
    label = 'Tours de course (0 = d\'après la session, sinon la durée)' },
  { key = 'raceMinutes', kind = 'number', default = 0, min = 0, max = 1440,
    label = 'Durée de course en minutes (0 = d\'après la session)' },
  { key = 'compoundChoice', kind = 'integer', default = -1, min = -1, max = 15,
    label = 'Composé de pneus imposé (index ; -1 = choix automatique)' },
  { key = 'driverMarginPct', kind = 'number', default = 0, min = 0, max = 10, label = 'Marge pilote : modèle plus optimiste (%)' },
  { key = 'calibrationAuto', kind = 'boolean', default = true, label = 'Calibration automatique' },
  -- règle pluie des aides (D16 amendé le 21/10/2026, décision de Vincent : « plus de TC, plus d'ABS »)
  { key = 'wetAidLevels', kind = 'integer', default = 2, min = 0, max = 5,
    label = 'Pluie : niveaux d\'aide en plus (antipatinage, ABS)' },
  -- affinage (décision de Vincent du 21/10/2026, amendée le même jour) : en continu par défaut, un nouveau
  -- calcul dès la fin du précédent, sans attendre de tour
  { key = 'refineLaps', kind = 'integer', default = 0, min = 0, max = 5,
    label = 'Affinage : tours propres avant un nouveau calcul (0 = en continu)' },
  -- minimum avant une proposition (décision de Vincent du 26/10/2026 : « combien de minimum de temps ou de tour il
  -- faut avant que SetupLab propose un setup ») : les deux, avec le setup en cours dans la voiture
  { key = 'refineMinLaps', kind = 'integer', default = 2, min = 0, max = 20,
    label = 'Affinage : tours propres minimum avant une proposition' },
  { key = 'refineMinMinutes', kind = 'number', default = 0, min = 0, max = 60,
    label = 'Affinage : minutes de roulage minimum avant une proposition (0 = sans)' },
  -- langue (décision de Vincent du 26/10/2026 : anglais par défaut, français au choix)
  { key = 'language', kind = 'enum', values = { 'en', 'fr' }, default = 'en', label = 'Langue' },
  { key = 'debugLog', kind = 'boolean', default = false, label = 'Journal détaillé (DEBUG)' },
}

M.byKey = {}
for _, def in ipairs(M.settings) do M.byKey[def.key] = def end

-- Aide de chaque réglage modifiable (décision de Vincent du 26/10/2026 : « des explications absolument sur chaque
-- paramètre »), au survol dans l'onglet Réglages ; traduite comme le reste de l'interface.
M.help = {
  compoundChoice = 'Composé de pneus imposé au calcul, par son numéro dans la voiture (0 = le premier). -1 : SetupLab choisit '
    .. 'lui-même le composé le plus rapide pour la température de piste mesurée.',
  fuelMarginPct = 'Carburant ajouté en course en plus de la consommation prévue, en pourcentage. Plus de marge : moins de '
    .. 'risque de panne sèche, voiture un peu plus lourde.',
  fuelQualiLaps = 'Tours de carburant embarqués pour un setup de tour rapide (0 = la règle par défaut : tour de sortie, '
    .. 'tour lancé et tour de rentrée).',
  perfStab = 'Équilibre recherché par le calcul : vers 0, le setup le plus rapide possible ; vers 1, un setup plus stable et '
    .. 'plus facile à piloter, au prix d\'un peu de temps.',
  drsTrafficPct = 'Part des tours de course où vous pensez être dans la fenêtre du DRS (trafic). Sert au réglage d\'aileron '
    .. 'et de rapports en course.',
  driverMarginPct = 'Rend le modèle plus optimiste sur votre pilotage, en pourcentage d\'adhérence. À laisser à 0 tant que le '
    .. 'modèle est calibré sur vos tours.',
  optBudgetEvalsQ = 'Nombre de setups essayés par le calcul de tour rapide. Plus : un meilleur résultat, un calcul plus long '
    .. '(il tourne en tâche de fond, sans à-coup).',
  optBudgetEvalsC = 'Nombre de relais simulés par le calcul de course. Plus : un meilleur résultat, un calcul plus long.',
  calibrationAuto = 'Après chaque tour propre, SetupLab ajuste son modèle de la voiture sur vos temps réels (adhérence, '
    .. 'puissance, traînée, appui, freinage). À laisser coché.',
  wetAidLevels = 'Sous la pluie, nombre de crans d\'antipatinage et d\'ABS ajoutés aux aides du setup. 0 : aides inchangées.',
  refineLaps = 'Pendant l\'affinage, nombre de tours propres entre deux calculs. 0 : un nouveau calcul à chaque tour propre.',
  refineMinLaps = 'Nombre minimum de tours propres avec le setup actuellement dans la voiture avant que SetupLab propose un '
    .. 'setup ou une modification. Compté de nouveau après chaque chargement.',
  refineMinMinutes = 'Durée minimum de roulage, en minutes, avec le setup actuellement dans la voiture avant une proposition '
    .. '(en piste, voiture en mouvement). 0 : pas de durée minimum. Les tours et la durée doivent être atteints tous les deux.',
  language = 'Langue de toute l\'application : menus, messages, aides et overlay.',
}

-- Constantes internes (réglables ici uniquement).
M.K = {
  -- Boucle d'exécution (§5)
  dtMax = 0.25,               -- borne haute de dt (s)
  contextPeriod = 1.0,        -- détection de contexte (s)
  fpsTarget = 60,             -- en dessous, la tranche est réduite
  slowFpsSliceFactor = 0.25,  -- fraction de tranche conservée sous fpsTarget
  workQuotaFallback = 200,    -- unités de travail par tranche sans horloge précise
  sliceMinMs = 0.25,          -- tranche minimale quand la frame a déjà travaillé (fin de tour) : une unité au moins
  -- chargement d'un setup SetupLab dans la voiture (D8 amendé le 20/10/2026, décision de Vincent)
  loadConfirmSeconds = 6,     -- délai pour confirmer le chargement après le premier clic…
  loadConfirmFrames = 360,    -- … ou, sans horloge précise, nombre d'images affichées
  loadConfirmMinSeconds = 0.5, -- délai minimal avant la confirmation (un double-clic ne confirme pas)…
  loadConfirmMinFrames = 30,  -- … ou, sans horloge précise, images affichées
  loadVerifyFrames = 120,     -- images pour constater le setup chargé (signature en direct)
  loadMaxSpeedKmh = 1,        -- voiture considérée arrêtée au stand
  loopSwitchCalls = 30,       -- appels d'affilée de l'autre source avant bascule de la boucle
  unitDecay = 0.9,            -- décroissance de l'estimation d'une unité de travail (rendu prédictif)
  sliceAlertMs = 3,           -- §14.3 : pic toléré par frame pendant un calcul (compteur de dépassements)
  tickWeightApiCall = 25,     -- poids d'un appel CSP dans le quota de repli sans horloge
  perfEmaAlpha = 0.05,        -- lissage du coût moyen par frame

  -- Journal (§16.4, §17)
  logCapacity = 200,
  logMinInterval = 2.0,       -- un même code n'est pas répété plus souvent (s)
  logMaxChars = 400,          -- longueur maximale d'une ligne de journal

  -- Données non fiables (D11)
  maxIniBytes = 524288,
  maxIniSections = 1024,
  maxIniKeys = 256,
  maxValueChars = 1024,
  maxLutPoints = 4096,
  storeMaxBytes = 64 * 1024,  -- §13 : taille maximale du stockage (purge LRU au-delà) ; une seule ligne d'un fichier
                              -- de configuration de CSP : bien en deçà des 5 Mo cités en exemple par le PDR
  storeMaxString = 120,       -- chaîne stockée au plus (caractères sûrs seulement)
  storeCalTempTol = 10,       -- calibration reprise d'une séance précédente : piste à 10 °C près
  minHeightMargin = 0.001,    -- marge sur MIN_HEIGHT (m) : hauteur statique prévue, pas mesurée
  modelVersion = 2,           -- version du modèle : une calibration ou une rugosité stockée par une autre est ignorée
  validateTolAbs = 0.15,      -- §14.1 : gain mesuré conforme au prévu à 0,15 s près…
  validateTolRel = 0.3,       -- … ou à 30 % du gain prévu (le plus large des deux)
  tyreLrPressureMax = 2,      -- écart gauche / droite de pression à chaud (psi) au-delà duquel l'essieu n'est pas ancré
  tyreLrTempMax = 15,         -- écart gauche / droite de température (°C) au-delà duquel l'essieu n'est pas ancré
  roughMaxG0 = 256e-6,        -- rugosité plausible au plus (m³, classe C de l'ISO 8608 : au-delà, pas un circuit)
  maxLutFiles = 160,
  maxRtoEntries = 256,
  maxRtoFiles = 24,
  maxCarIniFiles = 64,
  maxDataFiles = 1024,
  maxTextBytes = 262144,      -- setup courant, ui_track.json
  maxSetupSpinners = 512,
  maxSpinnerItems = 256,
  maxGearRatios = 16,
  maxWings = 16,
  maxReportChars = 120000,
  exportMaxSuffix = 99,       -- suffixes -2…-99 essayés avant de renoncer (jamais d'écrasement)
  fileOpsMax = 64,            -- rangement des fichiers (Corbeille, meilleur tour dans le nom) : opérations en attente
  backupsMax = 64,            -- copies « Avant chargement » de la séance suivies (rangement à la validation)
  scanMaxFiles = 2000,        -- fichiers du dossier lus pour numéroter les versions à la suite
  refineRetryDelay = 10,      -- affinage en continu : délai avant un nouvel essai après un calcul refusé (s)
  refineMinGain = 0.05,       -- affinage : gain prévu (s) à partir duquel un setup est proposé (en dessous : conservé)
  alertSeconds = 8,           -- affinage : durée de l'annonce à l'écran d'une version prête (ac.setMessage, s)
  refineHistory = 12,         -- affinage : calculs gardés dans l'historique affiché
  utcOffsetStep = 900,        -- décalage heure locale - UTC arrondi au quart d'heure (s)
  utcOffsetMax = 14 * 3600,   -- décalage au-delà : lecture de l'heure locale rejetée (s)

  -- Circuit (§7)
  trackMinLength = 500,       -- m
  trackMaxLength = 25000,     -- m
  trackMinSamples = 16,
  trackMaxSamples = 25000,
  trackMaxFailureRatio = 0.01,    -- points invalides tolérés lors de l'échantillonnage
  trackLengthTolSim = 0.005,      -- ±0,5 % vs longueur de la ligne IA (§7.4)
  trackLengthTolDeclared = 0.02,  -- ±2 % vs ui_track.json, informatif (arbitrage API_NOTES)
  trackDefaultWidth = 12,     -- largeur prise si la ligne IA ne la donne pas (m)
  curvatureBaseM = 4,         -- base du cercle à trois points pour la courbure (m)
  curvatureSmoothM = 2,       -- écart type du lissage gaussien de la courbure (m)
  kappaMax = 1 / 6,           -- courbure maximale admise (rayon 6 m)
  slopeBaseM = 10,            -- base de la pente et de la courbure verticale (m)
  slopeSmoothM = 8,           -- lissage de la pente (m)
  bankSmoothM = 8,            -- lissage du dévers (m)
  bankMax = 0.6,              -- dévers maximal admis (rad)
  bankMaxFailureRatio = 0.1,  -- au-delà de 10 % de sondages sans impact, dévers abandonné
  bankMinNormalY = 0.5,       -- normale de surface plus inclinée (> 60°) : impact rejeté (mur, bordure)
  cornerKappaIn = 1 / 400,    -- entrée en virage : rayon < 400 m (hystérésis)
  cornerKappaOut = 1 / 700,   -- sortie de virage : rayon > 700 m
  minCornerM = 12,            -- fragment de virage plus court : bruit
  minSegmentM = 25,           -- ligne droite plus courte entre deux virages de même sens : double apex
  chicaneGapM = 40,           -- ligne droite plus courte entre deux sens opposés : chicane
  chicaneMaxRadius = 100,     -- chicane : virages de rayon inférieur à 100 m…
  chicaneMaxLength = 250,     -- … sur une longueur totale de 250 m au plus
  bumpKappaV = 0.0015,        -- crête/compression : |d²y/ds²| > 0,0015 m⁻¹ (± 0,75 g de charge à 70 m/s)
  trackAutoMaxPoints = 4000,  -- au-delà, le pas est augmenté (§8.8)…
  trackAutoMaxDs = 5,         -- … jusqu'à 5 m
  trackMaxClosureM = 25,      -- circuit « fermé » dont la ligne ne se referme pas : traité comme ouvert
  trackMaxWidthMissing = 0.1, -- part de points sans largeur au-delà de laquelle les largeurs sont inconnues
  slowCornerKmh = 80,         -- §7.3 : virage lent sous 80 km/h
  fastCornerKmh = 160,        -- §7.3 : virage rapide au-delà de 160 km/h

  -- Voiture (§8.1 à §8.6)
  maxCompounds = 16,
  fuelDensity = 0.75,         -- kg/L
  defaultRideHeightF = 0.05,  -- hauteur de caisse prise hors jeu, avant (m)
  defaultRideHeightR = 0.06,  -- arrière (m)
  minDynamicRideHeight = 0.005,   -- en dessous, talonnage signalé (m)
  rideHeightMargin = 0.005,   -- hauteur par défaut hors jeu : au moins MIN_HEIGHT + 5 mm
  tyreDefaultHotTemp = 85,    -- température de fonctionnement sans courbe de performance (°C)
  tyreWindowGrip = 0.98,      -- fenêtre de température : adhérence ≥ 98 % du pic de PERFORMANCE_CURVE
  tyrePressureOffsetMax = 15, -- écart mesuré à la loi des gaz au-delà duquel la mesure est jugée aberrante (psi)
  tyreHotTolerance = 0.5,     -- pression à chaud : jamais plus loin de l'idéale que l'actuelle, à 0,5 psi près
  -- Suspension et rugosité de la piste (H16 à H19)
  roughN0 = 0.1,              -- fréquence spatiale de référence du profil de route (cycles/m, ISO 8608)
  roughBandLo = 1.5,          -- bande de la variation de charge (Hz) : les fenêtres de mesure retirent la tendance
  roughBandHi = 50,
  roughFreqPoints = 40,       -- points de l'intégrale en fréquence (pas logarithmique)
  damperSwitchHz = 5,         -- amortissement lent sous 5 Hz (caisse), rapide au-dessus (roue)
  minDamping = 500,           -- amortissement minimal par roue (N·s/m), garde-fou d'un fichier à 0
  roughGripMin = 0.9,         -- perte d'adhérence par variation de charge bornée à 10 %
  roughWindow = 15,           -- fenêtre de mesure de la variation de charge (échantillons, 0,5 s à 30 Hz)
  roughMaxAy = 1.5,           -- ligne droite : accélération latérale sous 1,5 m/s²
  roughMaxAx = 2.5,           -- ... longitudinale sous 2,5 m/s²
  roughMinSpeed = 25,         -- ... vitesse au-dessus de 25 m/s
  roughMinWindows = 6,        -- fenêtres de ligne droite au moins pour mesurer la rugosité
  roughConsistency = 4,       -- rugosités avant et arrière cohérentes à un facteur 4 près
  -- ERS (H21 à H23)
  ersLevels = 40,             -- niveaux par défaut de la programmation dynamique (tests)
  ersEnergyStep = 50,         -- plan : pas d'énergie de la programmation dynamique (kJ)
  ersMaxLevels = 300,         -- plan : niveaux au plus par dimension (charge, énergie déployée)
  ersSteadyLaps = 6,          -- course : tours rejoués au plus pour le régime établi d'un profil
  ersSteadyTolerance = 1,     -- régime établi : charge de fin de tour stable à 1 kJ près
  rideFrameTol = 0.005,       -- repère de hauteur de l'aéro vérifié à 5 mm près (hauteur au sol relevée au stand)
  rideFrameMaxOffset = 0.15,  -- au-delà de 15 cm d'écart, la mesure est jugée incohérente (aile mal appariée)
  camberSpreadMax = 12,       -- intérieur plus chaud que l'extérieur de plus de 12 °C : carrossage jamais plus négatif
  camberSpreadMin = 0,        -- extérieur plus chaud que l'intérieur : carrossage jamais moins négatif
  brakeLockSpeed = 20,        -- H15 : vitesse de contrôle du risque de blocage sans ABS (m/s, sans appui)
  brakeLockMargin = 0.3,      -- H15 : couple de freinage toléré au-delà de l'adhérence à cette vitesse (+30 %)
  brakeLockPenaltySec = 0.5,  -- H15 : pénalité de stabilité par unité d'excès de couple au-delà de la marge
  qualiTyreKm = 1,            -- qualification : pic de WEAR_CURVE dans le premier km virtuel
  camberRecovery = 0.5,       -- part du roulis compensée par la cinématique (non lue dans les fichiers)
  drivetrainEfficiency = 0.9, -- rendement de transmission (calibré au J5)
  aeroIterations = 3,         -- itérations appui ↔ écrasement de la suspension
  ayMaxG = 8,                 -- borne de recherche de l'accélération latérale (g)
  lateralTolerance = 0.0005,  -- résolution de l'accélération latérale maximale (m/s²)
  lateralBracket = 0.25,      -- premier pas de l'encadrement autour de la valeur voisine (m/s²)
  lateralMaxIterations = 60,  -- garde de la résolution (fausse position, repli dichotomie)
  longitudinalIterations = 6, -- point fixe transfert de charge longitudinal
  speedStep = 2,              -- pas des tables de performance (m/s ; 1 m/s : temps au tour à 0,03 % près)
  speedMax = 105,             -- vitesse maximale tabulée (m/s, 378 km/h)
  normalLoads = { 0.4, 1.0, 1.6, 2.2 },  -- facteurs de charge normale, régulièrement espacés (crêtes, compressions)
  normalLoadNominal = 2,      -- indice de 1,0 dans normalLoads
  loadClampMin = 0.05,        -- charge normale bornée (extrapolation linéaire hors table)
  loadClampMax = 3.0,

  -- Simulation de tour (§8.2) et pénalités (§10.2), en secondes avant pondération
  vLimIterations = 20,        -- point fixe de la vitesse limite en virage
  vLimTolerance = 0.01,       -- convergence de la vitesse limite (m/s)
  shiftHysteresis = 3,        -- rétrogradation seulement 3 m/s sous la plage du rapport engagé
  simTickPoints = 256,        -- points simulés entre deux rendus de main (DRS : deux vitesses limites par point)
  simMinSpeed = 0.5,          -- vitesse plancher de l'intégration du temps (m/s)
  cornerSpeedTol = 0.3,       -- écart à v_lim sous lequel un point est limité par le virage (m/s)
  balanceTarget = 0.97,       -- équilibre visé : très léger sous-virage (E < 1)
  balanceTolerance = 0.10,    -- écart d'équilibre de 10 % (moyenne quadratique) = balancePenaltySec
  balancePenaltySec = 0.3,
  rearLockPenaltySec = 0.5,   -- freinage entièrement sous blocage arrière prioritaire
  bottomingPenaltySec = 1.0,  -- talonnage prévu

  -- Espace de setup et optimiseur (§10.3 à §10.5, arbitrage A13)
  optRadiusLarge = 6,         -- rayon de recherche (crans) : aileron, pressions, freinage, boîte
  optRadiusReduced = 3,       -- rayon réduit : ressorts, barres, différentiel, puissance de freinage
  optCoarseFraction = 0.4,    -- part du budget pour la recherche grossière
  optCoarseDsFactor = 2,      -- recherche grossière sur un pas de circuit 2× plus grand (≤ trackAutoMaxDs)
  optTopK = 4,                -- meilleurs points grossiers raffinés
  optTieSeconds = 0.02,       -- §10.4 : écart sous lequel le setup le plus proche de l'actuel l'emporte
  optSeed = 20261019,         -- graine fixe (reproductibilité, §10.5)
  optRobustCount = 3,         -- optimums locaux distincts soumis au test de robustesse
  optReserveFraction = 0.3,   -- part maximale du budget réservée à la robustesse et à la sensibilité
  robustFactorDelta = 0.03,   -- §10.2 : facteurs calibrés perturbés de ±3 %
  profilePoints = 240,        -- points du profil de vitesse affiché
  plotHeight = 120,           -- hauteur du graphique de vitesse (px)
  -- tableau de bord (demande de Vincent du 21/10/2026 : interface épurée, dense, adaptée à la largeur)
  uiWide = 720,               -- largeur à partir de laquelle réglages et graphiques sont côte à côte (px)
  uiNarrow = 420,             -- largeur sous laquelle le tableau des réglages passe à 3 colonnes (px)
  uiLeftShare = 0.62,         -- part de la largeur du volet gauche (réglages) : ≥ uiNarrow dès uiWide
  uiPaneMinHeight = 260,      -- hauteur minimale des volets côte à côte (px)
  uiTileMin = 112,            -- largeur minimale d'une tuile de chiffre clé (px)
  uiTileHeight = 50,          -- hauteur d'une tuile (px)
  uiGap = 6,                  -- espace entre tuiles (px)
  uiIndent = 10,              -- retrait des sections repliables et des cartes (px)
  uiTooltipWidth = 380,       -- largeur des infobulles avant retour à la ligne (px)
  uiButtonPad = 18,           -- marge d'un bouton autour de son libellé (px), pour aller à la ligne
  uiHistoryRows = 5,          -- versions d'affinage affichées
  uiIconSize = 14,            -- icône (cadenas) devant un bouton ou une ligne (px)
  uiBigButtonHeight = 30,     -- bouton de l'étape suivante (valider, charger, confirmer), pleine largeur (px)
  optEstimateFactor = 0.8,    -- coût moyen d'une évaluation / coût d'un tour complet (recherche grossière moins chère)
  computeTargetQ = 40,        -- §14.3 : durée indicative du calcul qualification (s à 60 images/s ; affichage)
  computeTargetC = 45,        -- §14.3 : durée indicative du calcul course (total < 90 s ; affichage)
  optCoarseMinRatio = 1.5,    -- recherche grossière seulement si son pas est au moins 1,5 fois le pas fin
  verifyTolPressure = 0.3,    -- vérification en jeu : psi
  verifyTolFraction = 0.006,  -- vérification en jeu : fractions (répartition, différentiel, limiteur)
  verifyTolRatio = 0.002,     -- vérification en jeu : rapports de boîte
  verifyTolAngle = 0.05,      -- vérification en jeu : angle d'aileron (°)
  qualiFuelLaps = 3,          -- carburant de qualification si fuelQualiLaps = 0 : sortie, tour lancé, retour
  qualiFuelMarginModel = 0.3, -- marge si la consommation vient du modèle non calibré
  qualiFuelMarginMeasured = 0.1,  -- marge si la consommation est mesurée par CSP
  qualiFuelMinLiters = 3,     -- jamais moins de 3 L en qualification

  -- Composés de pneus (D16, D18)
  wetCompoundPatterns = { 'wet', 'rain', 'pluie', 'inter', 'pioggia', 'regen' },  -- jamais choisis automatiquement
  wetCompoundShortNames = { 'W', 'I', 'IM', 'INT', 'WT' },
  compoundTieSeconds = 0.05,  -- à moins de 0,05 s, le composé monté est gardé
  maxSessionRate = 10,        -- taux de consommation ou d'usure de la session : borne (donnée non fiable)

  -- Course et relais (§8.7, §10.6)
  raceDefaultLaps = 20,       -- durée supposée (signalée) si ni la session ni les réglages ne la donnent
  sessionTypeRace = 3,        -- ac.SessionType.Race (SDK)
  sessionTypeQuali = 2,       -- ac.SessionType.Qualify (SDK)
  nameMaxChars = 40,          -- nom de setup choisi : caractères gardés (sans accent ni espace)
  memoryRecheck = 120,        -- mémoire du circuit : un fichier relu au plus toutes les … s (le chargement revérifie)
  maxSessions = 16,           -- séances du week-end lues au plus
  raceFuelMarginModel = 0.1,  -- marge supplémentaire si la consommation vient du modèle non calibré
  raceMaxSamples = 5,         -- tours simulés par relais évalué (début, milieu, fin, usure extrême) ; temps
                              -- ajusté sur carburant et niveaux d'usure (écart au relais exact ≈ 0,04 s/tour)
  raceMaxLaps = 500,          -- borne des tours de course (données de séance non fiables, D11)
  raceMaxMinutes = 1440,      -- borne de la durée de course
  raceMaxFuelPerLap = 30,     -- borne de la consommation par tour (L)
  raceWearKmPerLapDefault = 1,  -- km virtuels par km parcouru sans mesure (taux d'usure 100 %), à confirmer
  raceSlipstreamDrag = 0.15,  -- H6 : traînée réduite de 15 % dans l'aspiration (à 100 % d'aspiration)
  raceDirtyAirLift = 0.1,     -- H7 : appui réduit de 10 % dans l'air sale
  raceStabFactor = 1.5,       -- §10.6 : stabilité plus critique en course
  raceRobFactor = 1.5,        -- §10.6 : robustesse plus critique en course
  raceCriticalLoss = 0.5,     -- tour critique : premier tour plus lent de 0,5 s que le meilleur tour du relais

  -- Enregistreur et calibration (§9)
  recorderHz = 30,            -- §9.1 : fréquence d'échantillonnage
  recorderCapacity = 40000,   -- §9.1 : échantillons au plus par tour
  recorderMinSamples = 100,   -- tour trop court en dessous
  recorderMaxGapM = 50,       -- trou de couverture au-delà duquel le tour est rejeté (m)
  recorderMaxSignatures = 4,  -- setups distincts dont le meilleur tour est conservé
  recorderBiasTolerance = 0.002,  -- variation de répartition de freinage tolérée pendant un tour
  maxWheelsOutside = 2,       -- plus de 2 roues hors piste : sortie
  exportLapStepM = 5,         -- pas du tour exporté (m)
  recorderMinStartSpeed = 5,  -- premier échantillon plus lent : départ arrêté (m/s)
  recorderTimeTolerance = 0.1,  -- écart toléré entre temps officiel et chrono relevé avant la ligne (s)
  recorderTimeWait = 1,       -- attente maximale d'un temps officiel à jour (s)
  recorderMaxKnownSetups = 6, -- setups connus (calibration) conservés au plus
  drsProbeMax = 40,           -- bascules du volet DRS mesurées au plus (H8)
  drsProbeMaxDv = 2,          -- écart de vitesse toléré entre les deux échantillons d'une bascule (m/s)
  signatureIgnored = { FUEL = true },  -- crans hors signature (le carburant est mesuré à part)
  -- vos temps par setup (demande de Vincent du 22/10/2026 : « se baser sur mes temps à moi ») : réglages qu'on
  -- change en roulant, hors de la « famille » du setup (sur la DTM, la répartition de freinage au volant)
  familyIgnored = { FUEL = true, FRONT_BIAS = true },
  reconnaissanceMaxTries = 3, -- reconnaissances tentées au plus par contexte
  estimateTickSamples = 500,  -- §9.4 : rendu de main tous les 500 échantillons
  calibBounds = {             -- §9.2 : bornes des facteurs
    mu = { 0.7, 1.3 }, power = { 0.85, 1.05 }, drag = { 0.8, 1.2 }, lift = { 0.7, 1.3 }, brake = { 0.8, 1.2 },
  },
  calibSteps = { 0.08, 0.04, 0.02 },  -- pas décroissants de la descente de coordonnées (dégrossissage)
  calibCoarseEvals = 120,     -- tours simulés au plus pendant la descente
  calibMaxEvals = 400,        -- tours simulés au plus par calibration
  calibLmIterations = 15,     -- itérations de Levenberg–Marquardt
  calibLmStep = 0.01,         -- pas des différences finies du jacobien
  calibLmLambda = 0.001,      -- amortissement initial
  calibLmRetries = 6,         -- essais d'amortissement par itération
  calibLmTolerance = 0.0001,  -- gain relatif minimal pour continuer
  calibWeightTime = 0.2,      -- poids de l'écart de temps relatif² : faible, car redondant avec le
                              -- profil (t = ∫ds/v) et non robuste (un incident forcerait les facteurs)
  calibWeightSpeed = 1,       -- poids du RMS relatif de v(s)²
  calibHuber = 0.03,          -- perte de Huber : écart de vitesse (fraction de vmax) au-delà duquel l'influence est linéaire
  calibIdentDelta = 0.03,     -- variation d'un facteur pour juger de son identifiabilité
  calibIdentThreshold = 0.05, -- hausse relative minimale de l'objectif pour qu'un facteur soit identifié
  calibIdentFloor = 1e-6,     -- plancher de l'objectif dans ce test
  calibAeroCheckSpeed = 55,   -- vitesse du contrôle d'appui (m/s)
  calibMinLiftN = 300,        -- en dessous, voiture sans appui : facteur d'appui laissé à 1
  calibMaxTimeError = 0.02,   -- §14.3 : écart de temps au tour ≤ 2 %
  calibMaxRms = 0.06,         -- §14.3 : RMS du profil de vitesse ≤ 6 % de vmax
  estimateMinSpeed = 15,      -- §9.4 : échantillons retenus au-delà de 15 m/s
  estimateStraightAy = 2,     -- ligne droite : |ay| < 2 m/s²
  estimateLateralQuantile = 0.99,  -- sommet latéral et décélération : 99e centile (points aberrants écartés)
  estimateGridSteps = 80,     -- pas du balayage de l'appui
  estimateMaxClA = 8,         -- appui Cz·S balayé jusqu'à 8 m²
  estimateClusterTol = 0.02,  -- points à la limite : à moins de 2 % du sommet
  estimateMinSpeedRatio = 1.5,  -- appui identifiable si les points à la limite couvrent ce rapport de vitesses
  estimateCornerFraction = 0.5,    -- virage : g latéral au-delà de la moitié du maximum du tour
  estimateMinSamples = 20,    -- échantillons minimum par estimation
  estimateRpmStep = 250,      -- pas de la courbe de couple estimée (tr/min)
  estimateEnvelopePasses = 6, -- passes d'enveloppe supérieure des ajustements
  estimateCgFront = 0.45,     -- répartition avant prise sans charges de roue mesurables
  estimateWheelRadius = 0.33, -- rayon de roue nominal du modèle estimé (m)
  estimateGearMinSpeed = 5,   -- rapports de boîte : échantillons au-delà de 5 m/s
  estimateRpmMinFraction = 0.4,  -- régime bas de la courbe estimée : 40 % du régime maximal

  -- Conditions (D16 amendé le 21/10/2026, décision de Vincent : setups pluie)
  wetThreshold = 0.05,        -- humidité, eau ou pluie au-delà : piste dite mouillée (rapport J0)
  wetEnter = 0.15,            -- état « pluie » dès que humidité, eau ou pluie atteint ce niveau (0 à 1)
  wetExit = 0.05,             -- retour à l'état « sec » seulement sous ce niveau (hystérésis)
  conditionsWaterStep = 0.25, -- écart d'eau sur la piste (0 à 1) qui rend un résultat pluie « calculé ailleurs »
  -- Adhérence sur piste mouillée : hypothèses H25 à H28, à confirmer en jeu (la physique pluie de CSP n'est
  -- pas documentée) ; les tours mouillés les calibrent (facteurs par composé, propres au mouillé, §9.2)
  wetSurfaceLoss = { slick = 0.30, treaded = 0.10, rain = 0.12 }, -- H25 : perte d'adhérence, piste humide (humidité 1)
  wetWaterDepthMax = 3.0,     -- H26 : eau sous les pneus (mm) supposée à eau = 1, sans mesure
  aquaGain = 0.12,            -- H26 : perte d'adhérence par mm d'eau au-delà des rainures, à aquaRefSpeed
  aquaRefSpeed = 55,          -- H26 : vitesse de référence de l'aquaplanage (m/s ; la perte croît en v²)
  aquaFloor = 0.35,           -- H26 : adhérence restante en aquaplanage, au plus bas (fraction)
  wetTyreRise = 30,           -- H27 : pneu sur piste mouillée sans mesure : piste + cette valeur (°C), au plus son plateau
  -- H28 : rainures supposées sans TREAD_DEPTH / TREAD_COVER (profondeur m, part de creux)
  wetTreadDefaults = { slick = { 0, 0 }, treaded = { 0.004, 0.20 }, rain = { 0.008, 0.35 } },
  conditionsTempStep = 2,     -- écart de température (°C) à celle du calcul à partir duquel son résultat est périmé
  conditionsGripStep = 0.01,  -- écart d'adhérence de la piste (0–1), même usage
  conditionsEps = 1e-4,       -- tolérance de comparaison à ces seuils (valeurs du jeu en simple précision)
  contextMissesInert = 2,     -- relectures d'affilée sans voiture ni circuit identifiés avant le mode inerte

  -- Sondes J0
  setupValueTol = 1e-6,
  raycastHeight = 2.0,        -- départ du rayon au-dessus de la voiture (m)
  raycastLength = 10.0,       -- longueur du rayon (m)

  -- Modulation des pénalités par le curseur Performance ↔ Stabilité (§10.2)
  penaltyScaleAtPerf = 0.4,   -- perfStab = 1 : 40 % des poids de base
  penaltyScaleAtStab = 2.0,   -- perfStab = 0 : 200 % des poids de base
}

-- Valide une valeur : type, finitude, bornes. Renvoie la valeur retenue et la correction faite.
function M.validateOne(def, value)
  if def.kind == 'boolean' then
    if type(value) == 'boolean' then return value, nil end
    return def.default, 'type'
  elseif def.kind == 'enum' then
    for _, allowed in ipairs(def.values) do
      if value == allowed then return value, nil end
    end
    return def.default, 'valeur'
  end
  if not Util.isFinite(value) then return def.default, 'invalide' end
  if def.kind == 'integer' then value = math.floor(value + 0.5) end
  if value < def.min then return def.min, 'min' end
  if value > def.max then return def.max, 'max' end
  return value, nil
end

-- Valide un jeu complet de réglages (entrée non fiable). Renvoie une nouvelle table
-- et la liste des corrections appliquées.
function M.validate(input)
  local out, fixes = {}, {}
  for _, def in ipairs(M.settings) do
    local value = nil
    if type(input) == 'table' then value = input[def.key] end
    local valid, fix = M.validateOne(def, value)
    out[def.key] = valid
    if fix and value ~= nil then fixes[#fixes + 1] = def.key .. ':' .. fix end
  end
  return out, fixes
end

function M.defaults()
  return (M.validate({}))
end

-- Poids effectifs des pénalités (§10.2) : w = w_base · lerp(0,4 ; 2,0 ; 1 − perfStab).
function M.penaltyWeights(settings)
  local stab = 1 - Util.clamp(settings.perfStab, 0, 1)
  local scale = Util.lerp(M.K.penaltyScaleAtPerf, M.K.penaltyScaleAtStab, stab)
  return {
    scale = scale,
    bal = settings.wBal * scale,
    stab = settings.wStab * scale,
    traffic = settings.wTraffic * scale,
    rob = settings.wRob * scale,
  }
end

return M
