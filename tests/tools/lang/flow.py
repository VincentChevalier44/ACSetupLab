# Parcours 1.5 (demande de Vincent du 26/10/2026) : point de départ, 4 étapes, validation en un clic, « Modifier… ».
EN = {
    'choisir le point de départ': 'choose the starting point',
    'charger le setup de départ au stand (%s)': 'load the starting setup in the pits (%s)',
    'valeurs par défaut des réglages illisibles': 'default values of the settings unreadable',
    'v%s : %s réglage%s gardé%s sur %s.': 'v{1}: {2} setting{3} kept out of {5}.',
    'v%s : aucun réglage gardé ; « Recommencer » pour ne pas la garder.': 'v%s: no setting kept; "Start over" to not keep it.',
    'Départ impossible : découverte en cours.': 'Cannot start: discovery in progress.',
    'Setup par défaut impossible : %s.': 'Default setup impossible: %s.',
    'Setup par défaut impossible : écriture refusée (%s).': 'Default setup impossible: write refused (%s).',
    "Départ : setup par défaut de la voiture, écrit dans %s. Au stand, menu de setup ouvert : « Charger » pour le mettre dans la voiture ; l'affinage %s partira de lui.":
        "Start: the car's default setup, written to %s. In the pits, setup menu open: \"Load\" to put it in the car; the %s refinement will start from it.",
    'Départ impossible : aucune référence validée sur ce circuit.': 'Cannot start: no validated reference on this track.',
    ', déjà dans la voiture.': ', already in the car.',
    ". Au stand, menu de setup ouvert : « Charger » pour la mettre dans la voiture ; l'affinage partira d'elle.":
        '. In the pits, setup menu open: "Load" to put it in the car; the refinement will start from it.',
    'Départ : votre référence %s': 'Start: your reference %s',
    "Départ : votre setup actuel (celui qui est dans la voiture). L'affinage %s part de lui.":
        'Start: your current setup (the one in the car). The %s refinement starts from it.',
    'Départ': 'Start',
    'Rouler': 'Drive',
    'Essayer': 'Try',
    'Valider': 'Validate',
    'Recommencer': 'Start over',
    ' · %s gardé%s': ' · {1} kept',
    '%s réglage%s changé%s': '{1} setting{2} changed',
    '%s réglage%s changé%s · %s gardé%s': '{1} setting{2} changed · {4} kept',
    'Modifier…': 'Modify…',
    'Masquer le détail': 'Hide the details',
    'Pour garder la version sauf un ou plusieurs réglages : les refuser un par un (un réglage refusé garde son ancienne valeur, dans cette version et dans les calculs suivants).':
        'To keep the version except one or more settings: refuse them one by one (a refused setting keeps its old value, in this version and in the next computations).',
    'Gardé : ce réglage sera dans la version validée. Un clic pour le refuser.':
        'Kept: this setting will be in the validated version. One click to refuse it.',
    'Refusé : ce réglage garde son ancienne valeur, dans cette version et dans les calculs suivants. Un clic pour le garder.':
        'Refused: this setting keeps its old value, in this version and in the next computations. One click to keep it.',
    'Tout garder': 'Keep everything',
    ' (%s/%s réglages)': ' (%s/%s settings)',
    'Valider sans essai': 'Validate without trying',
    'Valider sans essai (%s/%s réglages)': 'Validate without trying (%s/%s settings)',
    'Valider %s (%s/%s réglages)': 'Validate %s (%s/%s settings)',
    "Enregistre tout de suite %s.ini (réglages gardés), sans l'essayer ; il devient le setup de référence de cette séance, gardé en mémoire pour ce circuit.":
        'Saves %s.ini right away (kept settings), without trying it; it becomes the reference setup for this session, kept in memory for this track.',
    'Roulez au moins un tour propre avec elle, puis validez-la.': 'Drive at least one clean lap with it, then validate it.',
    'Enregistre %s.ini avec les réglages gardés et en fait le setup de référence de cette séance, gardé en mémoire pour ce circuit.':
        'Saves %s.ini with the kept settings and makes it the reference setup for this session, kept in memory for this track.',
    "L'essai complet est encore dans la voiture : charger %s (réglages gardés) au stand.":
        'The full trial is still in the car: load %s (kept settings) in the pits.',
    "Valide (réglages gardés) et verrouille : gardé en mémoire pour ce circuit, cette séance et cet état de piste, proposé à chaque visite ; l'affinage automatique s'arrête. Déverrouillable (onglet Mémoire).":
        'Validates (kept settings) and locks: kept in memory for this track, this session and this track state, offered on every visit; automatic refinement stops. Can be unlocked (MEMORY tab).',
    'Le setup de course se fait après une version de qualification validée (au moins une v1) : onglet QUALIF.':
        'The race setup comes after a validated qualifying version (at least a v1): QUALIFYING tab.',
    "Aller à l'onglet QUALIF": 'Go to the QUALIFYING tab',
    'votre setup actuel': 'your current setup',
    'setup par défaut de la voiture': "the car's default setup",
    'votre référence': 'your reference',
    'Étape 1/4 · Départ': 'Step 1/4 · Start',
    'De quel setup SetupLab part-il ? Il le fait évoluer avec vos tours, version après version (v1, v2…).':
        'Which setup should SetupLab start from? It evolves it with your laps, version after version (v1, v2…).',
    'Reprendre ma référence %s': 'Resume my reference %s',
    'Votre setup validé sur ce circuit : chargé au stand, puis affiné.': 'Your validated setup on this track: loaded in the pits, then refined.',
    'Mon setup actuel': 'My current setup',
    "Le setup qui est dans la voiture : le vôtre (chargé depuis le menu de setup d'AC) ou celui par défaut.":
        "The setup in the car: yours (loaded from AC's setup menu) or the default one.",
    'Setup par défaut de la voiture': "Car's default setup",
    "Le setup d'origine de la voiture : écrit dans un fichier SetupLab, chargé au stand, puis affiné.":
        "The car's original setup: written to a SetupLab file, loaded in the pits, then refined.",
    'Étape 1/4 · Charger le départ': 'Step 1/4 · Load the starting setup',
    'Au stand, menu de setup ouvert : bouton vert « Charger » (onglet %s) pour mettre %s dans la voiture.':
        'In the pits, setup menu open: green "Load" button (%s tab) to put %s in the car.',
    'SetupLab en veille': 'SetupLab on standby',
    "Cochez « SetupLab actif » pour reprendre l'affinage.": 'Tick "SetupLab active" to resume the refinement.',
    'Étape 3/4 · Essayer %s': 'Step 3/4 · Try %s',
    'Étape 4/4 · Valider %s': 'Step 4/4 · Validate %s',
    'Elle vous convient : validez-la. Pour refuser un réglage précis : « Modifier… » (onglet %s).':
        'It suits you: validate it. To refuse one particular setting: "Modify…" (%s tab).',
    'Roulez au moins un tour propre avec elle.': 'Drive at least one clean lap with it.',
    'Étape 2/4 · Rouler': 'Step 2/4 · Drive',
    "v%s en préparation : SetupLab continue d'analyser vos tours ; elle sera prête à votre retour au stand.":
        'v%s in preparation: SetupLab keeps analysing your laps; it will be ready when you return to the pits.',
    "Au stand, bouton vert « Charger », puis roulez : l'affinage repart d'elle (étape 2).":
        'In the pits, green "Load" button, then drive: the refinement continues from it (step 2).',
    'Départ : %s': 'Start: %s',
    'Départ : %s (%s)': 'Start: %s (%s)',
    'Changer de départ': 'Change the starting point',
    "Repartir d'un autre setup : votre setup actuel, celui par défaut de la voiture, ou votre référence.":
        "Start again from another setup: your current setup, the car's default one, or your reference.",
    '1. Départ : choisissez de quel setup partir : votre setup actuel (celui qui est dans la voiture, le vôtre ou celui par défaut), le setup par défaut de la voiture, ou votre référence validée sur ce circuit. Le choix active SetupLab.':
        "1. Start: choose which setup to start from: your current setup (the one in the car, yours or the default one), the car's default setup, or your validated reference on this track. Choosing activates SetupLab.",
    "2. Rouler : après le minimum de tours propres (onglet Réglages), SetupLab propose une version. En piste, il annonce qu'il a le minimum d'informations et continue d'analyser vos tours ; elle est prête à votre retour au stand.":
        '2. Drive: after the minimum clean laps (SETTINGS tab), SetupLab proposes a version. On track, it announces that it has the minimum information and keeps analysing your laps; it is ready when you return to the pits.',
    "3. Essayer : « Essayer vN » écrit la version dans un fichier d'essai ; « Charger » la met dans la voiture. Roulez avec.":
        '3. Try: "Try vN" writes the version into a trial file; "Load" puts it in the car. Drive with it.',
    "4. Valider : « Valider vN » la garde telle quelle ; « Modifier… » pour refuser un réglage précis (par exemple l'aileron arrière) et garder le reste. Elle devient votre référence pour ce circuit ; chargez-la et continuez : SetupLab repart d'elle.":
        '4. Validate: "Validate vN" keeps it as it is; "Modify…" to refuse one particular setting (for example the rear wing) and keep the rest. It becomes your reference for this track; load it and carry on: SetupLab continues from it.',
    "Le setup de course se fait après une version de qualification validée (au moins une v1) : il part d'elle, montée dans la voiture, et vos tours avec elle donnent votre rythme. Saisissez seulement le nombre de tours de la course (onglet COURSE).":
        'The race setup comes after a validated qualifying version (at least a v1): it starts from it, fitted to the car, and your laps with it give your pace. Just enter the number of race laps (RACE tab).',
    'Ce que SetupLab prend en compte': 'What SetupLab takes into account',
    'Météo et piste : air %s °C, piste %s °C, grip %s %, %s ; recalcul quand elles changent.':
        'Weather and track: air %s °C, track %s °C, grip %s %, %s; recomputed when they change.',
    'piste mouillée (eau %s %)': 'wet track (water %s %)',
    'piste sèche': 'dry track',
    'Circuit : %s km, %s virages (%s lents, %s moyens, %s rapides, %s en chicane), plus longue ligne droite %s m.':
        'Track: %s km, %s corners (%s slow, %s medium, %s fast, %s in chicanes), longest straight %s m.',
    "Virage lent : sous %s km/h à l'apex ; rapide : au-delà de %s km/h. Chaque virage est simulé à son rayon, avec la pente et le dévers de la piste.":
        "Slow corner: below %s km/h at the apex; fast: above %s km/h. Each corner is simulated at its radius, with the track's slope and camber.",
    'Part du tour : pleine charge %s %, freinage %s %, virages rapides %s %, virages lents %s %.':
        'Share of the lap: full throttle %s %, braking %s %, fast corners %s %, slow corners %s %.',
    'Voiture : %s réglages optimisés, %s conservés (raison de chacun ci-dessous).':
        'Car: %s settings optimised, %s kept (the reason for each below).',
    'Votre pilotage : modèle %s (calé sur vos tours valides).': 'Your driving: model %s (fitted to your valid laps).',
    "%s est figée (cadenas) : SetupLab ne propose plus rien sur ce circuit. Déverrouillez-la pour la faire évoluer.":
        '%s is locked (padlock): SetupLab no longer proposes anything on this track. Unlock it to keep evolving it.',
    'Déverrouiller et reprendre ma référence': 'Unlock and resume my reference',
    "Retire le cadenas, charge votre référence au stand, puis l'affine.":
        'Removes the padlock, loads your reference in the pits, then refines it.',
    "Premier setup tout de suite, d'après la voiture et la piste": 'First setup right away, from the car and the track',
    'Tours propres avant une proposition (0 = tout de suite)': 'Clean laps before a proposal (0 = right away)',
    'Minutes de roulage avant une proposition (0 = sans)': 'Driving minutes before a proposal (0 = none)',
    "Coché : dès que SetupLab est actif (point de départ choisi), il calcule un premier setup d'après les caractéristiques de la voiture et de la piste, sans attendre de tour. Les versions suivantes attendent le minimum ci-dessous. Décoché : le premier setup attend aussi ce minimum.":
        "Ticked: as soon as SetupLab is active (starting point chosen), it computes a first setup from the car's and the track's characteristics, without waiting for a lap. The next versions wait for the minimum below. Unticked: the first setup waits for that minimum too.",
    'Nombre de tours propres avec le setup actuellement dans la voiture avant que SetupLab propose un setup ou une modification : 0 pour proposer tout de suite, 1, 2, 3… Compté de nouveau après chaque chargement.':
        'Number of clean laps with the setup currently in the car before SetupLab proposes a setup or a change: 0 to propose right away, 1, 2, 3… Counted again after each load.',
    'Quand SetupLab propose un setup': 'When SetupLab proposes a setup',
    ' (réglable : onglet RÉGLAGES, « Quand SetupLab propose un setup »)': ' (adjustable: SETTINGS tab, "When SetupLab proposes a setup")',
    "2. Rouler : après le nombre de tours propres choisi (onglet RÉGLAGES, 0 pour tout de suite ; ou premier setup tout de suite, d'après la voiture et la piste), SetupLab propose une version. En piste, il annonce qu'il a le minimum d'informations et continue d'analyser vos tours ; elle est prête à votre retour au stand.":
        '2. Drive: after the chosen number of clean laps (SETTINGS tab, 0 for right away; or first setup right away, from the car and the track), SetupLab proposes a version. On track, it announces that it has the minimum information and keeps analysing your laps; it is ready when you return to the pits.',
    "Calcule tout de suite et annonce chaque setup amélioré (rien n'est enregistré avant « Valider »), puis recalcule %s, jusqu'à l'arrêt. Le chargement se fait au stand, en deux clics.":
        'Computes right away and announces each improved setup (nothing is saved before "Validate"), then computes again %s, until you stop it. Loading happens in the pits, in two clicks.',
    "Choisissez d'abord le point de départ (carte du haut).": 'Choose the starting point first (card at the top).',
    'Affinage %s repris : v%s et les versions précédentes sont gardées.': '%s refinement resumed: v%s and the previous versions are kept.',
    'Affinage %s repris.': '%s refinement resumed.',
    'Le setup de course se fait après une version de qualification validée (au moins une v1).':
        'The race setup comes after a validated qualifying version (at least a v1).',
    'À faire : %s.': 'To do: %s.',
    'À faire : %s. Le setup de course se fait après une version de qualification validée (au moins une v1).':
        'To do: %s. The race setup comes after a validated qualifying version (at least a v1).',
    'À faire : %s. (onglet COURSE)': 'To do: %s. (RACE tab)',
    'Affiner le tour rapide': 'Refine the qualifying setup',
    "Lance l'affinage du setup de tour rapide (onglet QUALIF), même en séance de course.":
        'Starts refining the qualifying setup (QUALIFYING tab), even in a race session.',
    '%s est figée (cadenas) : SetupLab ne propose plus rien sur ce circuit. Choisir un départ la déverrouille.':
        '%s is locked (padlock): SetupLab no longer proposes anything on this track. Choosing a starting point unlocks it.',
    'Setup figé': 'Setup locked',
    "%s est figé (cadenas) : SetupLab ne propose plus rien pour cette séance. Déverrouillez-le pour reprendre l'affinage.":
        '%s is locked (padlock): SetupLab no longer proposes anything for this session. Unlock it to resume the refinement.',
    'Déverrouiller': 'Unlock',
    'v%s non gardée · encore dans la voiture': 'v%s not kept · still in the car',
    "Au stand, menu de setup d'AC : chargez votre setup d'avant%s, ou changez de départ ci-dessous. SetupLab repart du setup qui sera dans la voiture.":
        "In the pits, AC's setup menu: load your previous setup%s, or change the starting point below. SetupLab continues from the setup that will be in the car.",
    'v%s validée · à charger au stand': 'v%s validated · to load in the pits',
    "L'essai complet est encore dans la voiture : au stand, bouton vert « Charger » (onglet %s) pour mettre v%s (réglages gardés), puis roulez.":
        'The full trial is still in the car: in the pits, green "Load" button (%s tab) to put v%s (kept settings) in the car, then drive.',
    "Le setup dans la voiture n'est pas celui retenu : charger au stand le setup validé (bouton vert « Charger »), ou changer de départ.":
        'The setup in the car is not the one kept: load the validated setup in the pits (green "Load" button), or change the starting point.',
    'Grip de la piste lu dans CSP hors plage (%s) : 100 % pris à la place.': 'Track grip read from CSP out of range (%s): 100 % used instead.',
    'conservé : pneus sans sensibilité à la charge (ancien format de tyres.ini), effet de la rugosité non modélisable':
        'kept: tyres without load sensitivity (old tyres.ini format), effect of the roughness cannot be modelled',
    'tour propre compté : calcul du setup en cours': 'clean lap counted: computing the setup',
    "calcul du setup en cours ; je continue d'analyser vos tours": 'computing the setup; I keep analysing your laps',
    "votre setup actuel est déjà le meilleur trouvé (gain possible sous %s s) : rien à changer pour l'instant ; je continue d'analyser vos tours":
        'your current setup is already the best found (possible gain under %s s): nothing to change for now; I keep analysing your laps',
    'SetupLab : setup %s analysé': 'SetupLab: %s setup analysed',
    "Votre setup actuel est déjà le meilleur trouvé : rien à changer pour l'instant. Je continue d'analyser vos tours.":
        'Your current setup is already the best found: nothing to change for now. I keep analysing your laps.',
    'identique à une version non gardée : pas reproposée ; nouveau calcul au prochain tour propre':
        'same as a version not kept: not proposed again; new computation on the next clean lap',
    'Dernier tour %s : non compté (%s)': 'Last lap %s: not counted (%s)',
    'Dernier tour %s : tour propre compté': 'Last lap %s: clean lap counted',
    'Tour propre compté (%s s) : %s.': 'Clean lap counted (%s s): %s.',
    'SetupLab : tour non compté': 'SetupLab: lap not counted',
    'Tour non compté : %s ; %s.': 'Lap not counted: %s; %s.',
    '%s — dernier tour non compté : %s': '%s — last lap not counted: %s',
    'non valide': 'not valid',
}
