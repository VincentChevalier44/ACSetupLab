# SetupLab — PDR v0.2 (DÉCISIONS PRISES, prêt pour relecture finale)

**Application Lua CSP pour Assetto Corsa — setup qualification et setup course calculés automatiquement pour n'importe quel couple voiture × circuit**
Auteur : Vincent Chevalier (LHK Informatique) · Date : 19/10/2026 · Statut : **tous les points ouverts tranchés (§20), à relire avant verrouillage** · Nom définitif : **SetupLab** · Remplace : `SetupLab_PDR_v0.1.md`
Langue du document : français. Identifiants de code : anglais. Commentaires de code et textes d'interface : français.

---

## 0. Mode d'emploi pour l'agent codeur (lire en premier)

1. Ce document est la **seule source de vérité**. Toute valeur chiffrée est une valeur de départ **réglable** (dans `config.lua`, jamais en dur dans la logique).
2. **Aucun code à trou, aucun `TODO`, aucun stub.** Si une fonction CSP est inconnue, on la détecte au Jalon 0 et on désactive proprement la capacité ; on n'invente jamais une signature.
3. **Jalon 0 obligatoire avant tout code de calcul** (§3.3) : lire le SDK Lua CSP installé chez Vincent (`<assettocorsa>/extension/internal/lua-sdk/`), consigner les signatures réelles dans `docs/API_NOTES.md`. Si inaccessible, demander à Vincent ; ne pas deviner.
4. **Qualité exigée** : relecture adversariale à chaque jalon, linter strict, batterie de tests hors jeu, revue de robustesse. Rien n'est « terminé » sans ces trois éléments.
5. **Contraintes de contexte** : travailler module par module, livrer par jalons (§18).
6. Quand une valeur n'est pas définie ici, appliquer le comportement le plus **prudent** (ne rien écrire, garder le setup actuel) et le consigner dans le journal.

---

## 1. Objectif, périmètre, non-objectifs

### 1.1 Objectif
Quand Vincent ouvre un circuit avec une voiture (n'importe laquelle, d'origine ou mod), l'application :
1. **analyse le circuit** (géométrie, courbures, pentes, dévers, longueurs de lignes droites, zones de freinage, surfaces) ;
2. **analyse la voiture** (masse, répartition, moteur, boîte, pneus, aéro, freinage, suspensions, plages de réglages autorisées) ;
3. **calcule mathématiquement** le temps au tour et son comportement (équilibre, usure, température des pneus) pour un setup donné ;
4. **cherche automatiquement** le meilleur setup, en deux variantes : **Qualification** (un tour lancé) et **Course** (un relais complet) ;
5. **propose le résultat**, le montre (réglage par réglage, avec l'explication) et permet de l'enregistrer comme fichier de setup utilisable dans Assetto Corsa / Content Manager.

### 1.2 Périmètre
Solo hors ligne en v1 ; toutes voitures et tous circuits dont les données sont lisibles (§3.2). Compatible Content Manager + CSP + Pure.

### 1.3 Non-objectifs
Multijoueur en ligne (app **inerte**) · pilotage de la voiture · modification de la physique · garantie d'un « setup parfait » (le résultat est une **recommandation calculée**, validée en jeu, §14) · réglages de pilotage (assistances) · réseau, fichiers hors dossiers autorisés.

### 1.4 Limite honnête du modèle
La physique d'Assetto Corsa (modèle de pneus thermique, suspension, aérodynamique par éléments) est plus riche qu'un modèle mathématique de laboratoire. Le moteur de calcul est donc un **modèle simplifié mais calibré**, et il est **corrigé par des mesures en jeu** (§9). Le critère de réussite est mesurable (§14.3), pas absolu.

---

## 2. Décisions verrouillées (issues du cadrage du 19/10/2026)

| # | Décision |
|---|---|
| D1 | **Forme : app Lua CSP en jeu** (barre d'apps), fenêtre principale + fenêtre debug. Choix de Vincent. |
| D2 | **Données voiture : lecture des fichiers + mesure en jeu** (calibration par tour roulé). |
| D3 | **Méthode : simulation de tour + optimisation** (heuristiques d'ingénieur pour le point de départ, §10.1). |
| D4 | **Deux sorties : Qualification et Course.** Différences : charge d'essence, usure/températures des pneus, trafic/dépassements, longueur de course/relais. |
| D5 | **Noyau pur** : le moteur de calcul ne lit jamais `ac.*`/`physics.*` ; il consomme des tables de données et renvoie des tables. Seuls `datasource.lua`, `recorder.lua` et `exporter.lua` touchent l'API CSP. Conséquence : tout le moteur est testable hors jeu. |
| D6 | Le calcul est **asynchrone** (découpé en tranches de temps, jamais de gel du jeu) et **annulable**. |
| D7 | Toute fonction CSP est appelée via `pcall` et « sonde-testée » au démarrage ; échec = capacité `unavailable`, interface grisée avec la raison. |
| D8 | Le setup actuel de Vincent n'est **jamais écrasé** : la sortie est un **nouveau fichier de setup nommé** (§12.3). **1.4.0 (Vincent, 21/10/2026)** : nom choisi possible ; renommer = nouveau fichier, l'ancien reste ; un fichier chargeable se reconnaît à son nom et à l'empreinte de son contenu — voir `API_NOTES.md`, A32. **Bêta 1.2 (Vincent, 22/10/2026)** : « il ne reste que les fichiers V1, V2, V3 » : les fichiers écrits par SetupLab pendant le lancement, intacts, peuvent partir à la Corbeille (version non gardée, copie de sauvegarde en double) ou être renommés (meilleur tour réel d'une version de qualification gardée), voiture arrêtée, depuis l'exporteur seulement ; jamais un fichier gardé ni un fichier de Vincent — voir A37. |
| D9 | Les résultats sont **mis en cache** par couple (voiture, circuit, version des données) dans `ac.storage` ou un fichier autorisé (§13). |
| D10 | Aucun appel réseau, aucun `loadstring`/`load` de texte externe non filtré. |
| D11 | Les entrées fournies par l'utilisateur et les fichiers de données sont traités comme **non fiables** (validation, bornes, tailles). |
| D12 | **Nom définitif : SetupLab.** |
| D13 | **Voitures à DRS et ERS : prises en charge complètes dès la v1** (choix de Vincent, qui joue souvent avec des formules) : DRS par zones, ERS avec bilan d'énergie et stratégie de déploiement/récupération optimisée (§8.9). Jalon dédié (§18, J6b). Si les fichiers `drs.ini`/`ers.ini` d'une voiture sont illisibles, ces modules se désactivent pour cette voiture avec avertissement. |
| D14 | **Tour de référence optionnel**, avec indicateur de confiance affiché : sans tour de référence le calcul se fait sur les données seules (confiance basse) ; avec un tour, calibration complète (§9). |
| D15 | **Objectif équilibré et réglable** : curseur « Performance ↔ Stabilité » dans l'UI (défaut sur compromis, valeur initiale `perfStab = 0,6`) qui pondère les pénalités de §10.2. Conçu pour une conduite au volant Fanatec. |
| D16 | **Pluie et piste mouillée hors v1.** L'app détecte la pluie/piste mouillée (Pure, grip) et affiche « calcul valable à sec uniquement » ; aucun setup pluie n'est généré. **Amendé par Vincent le 21/10/2026 (version 1.3.0) : setups pluie** — voir `API_NOTES.md`, A31 et H25 à H28. |
| D17 | **Export du setup** : écriture directe du fichier si la capacité existe (Jalon 0) ; sinon presse-papiers + chemin cible (§12.3). |
| D18 | **Composé de pneus choisi par l'app, modifiable** : l'optimiseur compare les composés disponibles (surtout en course via le relais simulé) ; l'utilisateur peut en imposer un. |
| D19 | **Cache par voiture × circuit (disposition) × conditions**, interne à l'app. L'export de partage entre PC est hors v1 (backlog). |
| D20 | **Réglages verrouillés ou masqués** par la voiture (`setup.ini`) : jamais modifiés ; si le setup est entièrement verrouillé, l'app l'indique et ne calcule que l'information (équilibre, plan de carburant). |
| D21 | **Écartés volontairement** (gadgets) : partage en ligne de setups, comparaison avec d'autres pilotes, note de style de conduite, voix/sons, export de télémétrie, graphiques décoratifs. |

---

## 3. Environnement et API

### 3.1 Installation
Dossier `assettocorsa/apps/lua/SetupLab/`. `manifest.ini` : `[ABOUT]`, `[CORE]` `LAZY = NONE`, sections `[WINDOW_...]` (principale, debug), `[SIM_CALLBACKS]` `UPDATE = <fonction globale>`. **Valider la syntaxe contre le manifest d'une app Lua déjà installée** avant de figer. Fonctions globales préfixées `SETUPLAB__`.

### 3.2 Tableau de vérité de l'API (à confirmer au Jalon 0 — rien n'est supposé acquis)

| Besoin | Piste probable | Statut |
|---|---|---|
| Lire les fichiers de données de la voiture (`car.ini`, `engine.ini`, `power.lut`, `drivetrain.ini`, `tyres.ini`, `aero.ini`, `brakes.ini`, `suspensions.ini`, `setup.ini`, `*.lut`), y compris quand ils sont dans `data.acd` | `ac.INIConfig.carData(...)` / lecteurs de LUT du SDK | **À confirmer** (existence, signature, LUT) |
| Lire les fichiers du circuit (`surfaces.ini`, `data/` du circuit, ligne `fast_lane.ai`) | `ac.INIConfig.load`, lecture binaire éventuelle | **À confirmer** |
| Géométrie : position/orientation de la voiture, `splinePosition`, altitude, rayons vers la piste | `ac.getCar(i)`, `physics.raycastTrack`, utilitaires `ac.worldCoordinateToTrack`… | **À confirmer** |
| Télémétrie en jeu (vitesse, g latéral/longitudinal, charges de roue, températures et pressions de pneus, glissement, régime, rapport, carburant) | `ac.getCar(0)` (champs) | **À confirmer champ par champ** |
| Lire le setup courant / les plages / appliquer un setup | `ac.getCarPhysics`, API de setup du SDK, ou fichier `.ini` de setup | **À confirmer** |
| Écrire un fichier de setup dans `Documents\Assetto Corsa\setups\<voiture>\<circuit>\` | `io.*` ou `ac.INIConfig:save` selon les droits de l'app | **À confirmer** — sinon : affichage + presse-papiers (§12.3) |
| Pilotage de session (type, durée, nb de tours, météo, température de piste/air) | `ac.getSim()`, `ac.getSession()`, `ac.getTrackConditions()`… | **À confirmer** |

Règle : toute capacité manquante dégrade proprement la fonction (jamais d'invention). Le livrable minimal viable (§18, Jalon 3) est : **calcul du setup + affichage détaillé + export copiable**, même si l'écriture directe du fichier est impossible.

### 3.3 Jalon 0 — découverte (livrable : `docs/API_NOTES.md` + panneau « Capacités »)
Pour chaque ligne du tableau §3.2 : nom exact, signature, plage, unité, comportement observé sur au moins **trois voitures** (une d'origine à data chiffré, un mod à data ouvert, une F1/formule à aéro complexe) et **deux circuits**. Panneau « Capacités » : liste des fonctions disponibles, version CSP, fichiers lisibles/illisibles pour la voiture et le circuit courants, droits d'écriture.

---

## 4. Architecture

```
apps/lua/SetupLab/
  manifest.ini
  SetupLab.lua           -- colle AC : callbacks, fenêtres, garde-fous globaux
  src/util.lua           -- maths, interpolation, LUT, filtres, RNG déterministe
  src/config.lua         -- schéma unique : défauts, bornes, libellés, validation
  src/caps.lua           -- détection/sondage des capacités CSP (pcall)
  src/datasource.lua     -- lecture voiture/circuit/session -> tables pures (SEUL accès fichiers/API en lecture)
  src/track_model.lua    -- circuit : abscisse s, courbure, pente, dévers, segments, zones de freinage
  src/car_model.lua      -- voiture : masse, moteur, boîte, pneus, aéro, freins, suspension -> paramètres de calcul
  src/setup_space.lua    -- espace des réglages : plages, pas, dépendances, mapping vers les paramètres de calcul
  src/laptime_sim.lua    -- simulation de tour (point matériel amélioré, §8)
  src/stint_sim.lua      -- simulation de relais : carburant, usure, température des pneus (§8.7)
  src/optimizer.lua      -- recherche du meilleur setup (§10)
  src/calibration.lua    -- recalage du modèle sur les tours mesurés (§9)
  src/recorder.lua       -- enregistrement de la télémétrie d'un tour (§9.1)
  src/exporter.lua       -- écriture/affichage des setups (§12)
  src/store.lua          -- cache et persistance (§13)
  src/ui.lua             -- fenêtres ImGui générées depuis le schéma
  docs/API_NOTES.md, README.md, CHANGELOG.md
tests/                   -- banc d'essai hors jeu (lupa) + linter strict + jeux de données de référence
```

Contrats de données : tables réutilisées lorsque c'est dans la boucle chaude ; le calcul d'optimisation tolère l'allocation mais est borné (§10.5).

---

## 5. Boucle d'exécution

1. **Garde** : si app désactivée, session en ligne, replay → aucune action. `dt` borné `]0 ; 0,25]`.
2. **Détection de contexte (1 Hz)** : voiture, circuit, type de session, conditions (température d'air/piste, météo Pure, grip du circuit). Tout changement invalide le calcul en cours et marque les résultats comme périmés.
3. **Tâches de fond (UPDATE)** : un ordonnanceur coopératif exécute des **tranches de calcul de ≤ 2 ms par frame** (budget configurable, §15), dans l'ordre : lecture des données → modèle circuit → modèle voiture → calibration → optimisation Q → optimisation C → export.
4. **Enregistreur (si actif)** : échantillonne la télémétrie à fréquence fixe (§9.1) ; arrêt automatique à la fin du tour.
5. **UI** : lecture seule de l'état (pas de calcul dans le rendu).

Le jeu ne doit **jamais** baisser en dessous de 60 images/s à cause de l'app (triple 4K, grilles de 40 à 70 voitures) : les calculs sont suspendus si le temps de frame dépasse `frameGuardMs` (§15).

---

## 6. Conventions
Unités SI en interne (m, s, kg, N, rad, Pa, K) ; km/h, °C, bar uniquement dans l'UI et les fichiers. Abscisse curviligne `s` en mètres le long de la ligne de référence, ré-échantillonnée à pas constant `ds` (défaut 2 m, configurable 1–5 m). Angles en radians. Repère local : X droite, Y haut, Z avant (à confirmer par calibration comme dans le PDR HumanAI).

---

## 7. Modèle du circuit (`track_model.lua`)

### 7.1 Sources de géométrie (par ordre de préférence, choisies au Jalon 0)
1. **Ligne de référence** lisible directement (fichier `fast_lane.ai` ou équivalent) → positions, largeurs, éventuellement vitesses/courbures.
2. **Reconnaissance** : enregistrement de la trajectoire d'un tour (joueur, ou voiture IA observée) → positions (x, y, z) et `splinePosition`.
3. **Sondage** : rayons verticaux vers la piste pour l'altitude, le dévers et la largeur.
Le modèle conserve la **source** et un **indice de confiance** (0..1) affichés à l'utilisateur.

### 7.2 Grandeurs calculées (par point d'abscisse `s`)
Cap, **courbure** `κ(s)` (lissée par spline cubique, bornée pour éliminer le bruit), **pente longitudinale** `θ(s)`, **dévers latéral** `φ(s)`, **largeur utile**, **type de surface** (asphalte, vibreur, herbe…) et son grip relatif (`surfaces.ini`).

### 7.3 Segmentation
Découpage en **segments** : lignes droites (κ < seuil), freinages (décélération d'après la simulation), virages (lents < 80 km/h, moyens, rapides > 160 km/h), chicanes, sauts/bosses (variation d'altitude brusque). Chaque segment porte : longueur, vitesse d'apex, durée, type. Ces segments servent à pondérer l'objectif (§10.2) et à expliquer les réglages (§12.2).

### 7.4 Sorties
`trackModel = { ds, n, s[], kappa[], theta[], phi[], surf[], segments[], length, confidence, source }`. Cohérence : longueur totale ± 0,5 % de la longueur déclarée ; sinon avertissement et confiance abaissée.

---

## 8. Modèle de la voiture et simulation de tour

### 8.1 Paramètres lus (si disponibles)
Masse à vide, répartition avant/arrière, hauteur du CG, empattement, voies · courbe de couple/puissance (`power.lut`), ratios de boîte, rapport final, différentiel, rendement de transmission · pneus par composé (`tyres.ini` : rayon, rigidité, coefficients d'adhérence `DY_REF`/`DX_REF`, sensibilité à la charge, plage de température idéale, usure) · aéro (`aero.ini` : surfaces, CL/CD, répartition, effet du réglage d'aileron) · freins (couple maxi, répartition) · suspension (raideurs, barres antiroulis, hauteur de caisse, carrossage, pincement).
Chaque paramètre a une **source** (`file`, `measured`, `default`) ; les valeurs par défaut sont signalées dans l'UI (« estimé »). Voiture dont les données sont illisibles : mode **mesure uniquement** (§9.4) ou refus avec explication.

### 8.2 Modèle de calcul
Point matériel étendu (**quasi-statique**, un intégrateur le long de `s`) :
1. **Vitesse limite de virage** `v_lim(s)` : solution de `m·v²·κ = Σ F_lat(charges)` avec :
   - charges verticales par essieu = poids ± transfert de charge (CG, voies) ± **appui aérodynamique** `½ρ·CL·A·v²` répartie selon l'équilibre aéro ;
   - adhérence latérale par pneu `μ(Fz, T, usure)·Fz` avec sensibilité à la charge (`μ` décroît avec `Fz`) ;
   - dévers et pente appliqués à `κ`/`g`.
2. **Passe arrière** (freinage) : à partir des apex, vitesse maximale permettant de freiner jusqu'à `v_lim` en tenant compte du cercle d'adhérence, de la répartition de freinage, de l'aéro, de la traînée, de la pente.
3. **Passe avant** (accélération) : puissance à la roue (moteur, rapport optimal, patinage via adhérence longitudinale de l'essieu moteur, traînée, pente).
4. **Vitesse finale** `v(s) = min(passe avant, passe arrière, v_lim)` ; temps `t = ∫ ds / v`.
5. **Rapport engagé** choisi pour maximiser la puissance ; patinage et limiteur de régime pris en compte ; **temps de changement de rapport** (coupure de couple, lu dans la voiture ou mesuré) ajouté à chaque montée/descente, ce qui influence le choix des ratios.

### 8.3 Équilibre (sous-virage/survirage)
Indicateur d'équilibre par segment de virage : rapport entre la capacité latérale disponible à l'avant et à l'arrière (`E = Fy_max,av·b / Fy_max,ar·a`, normalisé). `E ≈ 1` = neutre ; l'optimiseur pénalise un écart structurel (§10.2) car un temps théorique excellent avec une voiture instable est inutilisable.

### 8.4 Stabilité
Marge de stabilité (freinage, entrée de virage, motricité) : pénalité si la répartition de freinage verrouille l'essieu arrière avant l'avant, si le différentiel rend la motricité instable, si l'aileron est incompatible avec la hauteur de caisse choisie.

### 8.5 Hauteur de caisse et effet de sol
Pour les voitures concernées (formules, GT à fond plat) : le modèle aéro lit les LUT de hauteur/inclinaison ; les butées de hauteur minimale (touche-fond) sont une **contrainte dure** de l'espace de réglage.

### 8.6 Pneus (température et pression)
Modèle thermique simplifié : équilibre entre échauffement (glissement × charge) et refroidissement (vitesse) ; la fenêtre de température idéale du composé fixe l'optimum de pression et de carrossage. La pression à chaud est **prédite** et le réglage de pression à froid est déduit pour l'atteindre (§10.3).

### 8.7 Simulation de relais (`stint_sim.lua`)
Pour la course : tour par tour, sur `N` tours ou une durée : **consommation de carburant** (masse décroissante), **usure** (perte d'adhérence cumulée), **dérive de température/pression**, **déséquilibre induit**. Sortie : temps total du relais, temps du tour moyen, dégradation en %/tour, tour critique.

### 8.8 Précision et coût
`ds = 2 m` → ~3 000 points pour 6 km ; une simulation de tour doit coûter **< 25 ms** (équivalent LuaJIT, mesuré au banc) et une simulation de relais < 400 ms. Pistes très longues (Nordschleife ~20 km) : `ds` automatique plus grand (jusqu'à 5 m) pour tenir le budget.

---

### 8.9 DRS et ERS (D13)
**DRS** : zones de détection et d'activation lues dans les données du circuit (`drs_zones.ini`) et les paramètres de la voiture (`drs.ini` : effet sur traînée et appui). Simulation en deux états : fermé/ouvert ; en **qualification** le DRS est considéré disponible dans toutes les zones, en **course** il l'est dans les zones où une voiture se trouve à moins de 1 s devant (fraction de tours en trafic réglable, `drsTrafficPct`, défaut 30 %) ; le setup course pondère donc un gain de vitesse de pointe seulement sur cette fraction.
**ERS / KERS** : lu dans `ers.ini` et les contrôleurs d'énergie : puissance de déploiement maxi, puissance de récupération, capacité de batterie, rendement, modes de déploiement/récupération, éventuel MGU-H et frein moteur. Modèle : **bilan d'énergie par tour** (récupération au freinage et en levé-de-pied, déploiement en accélération) ; **stratégie de déploiement optimisée par programmation dynamique le long de l'abscisse `s`** sous contrainte `énergie déployée ≤ énergie récupérée + budget de tour` ; en course, répartition du déploiement sur le relais (attaque/défense, tours critiques). Les modes/cartographies exposés par la voiture deviennent des variables de §10.3 (jamais d'invention d'un réglage absent).
**Validation obligatoire** : simulation comparée à un tour réel d'au moins deux formules (une avec DRS seul, une avec ERS) avant de déclarer la capacité disponible (§14.3).

---

## 9. Calibration par mesure en jeu

### 9.1 Enregistreur (`recorder.lua`)
Enregistre un tour complet (démarrage à la ligne, arrêt à la fin) à 30 Hz : `s`, vitesse, accélérations, charge de roue, température/pression de pneus, régime, rapport, gaz/frein, volant, carburant, temps. Mémoire bornée (≤ 40 000 échantillons). Tour invalide (sortie de piste, retour aux stands) : rejeté avec raison.

### 9.2 Calibration (`calibration.lua`)
Recale quelques **facteurs scalaires globaux et bornés** pour que la simulation reproduise le tour mesuré :
- facteur d'adhérence (pneus) `kμ ∈ [0,7 ; 1,3]` ;
- facteur de puissance effective `kP ∈ [0,85 ; 1,05]` ;
- facteur de traînée `kD ∈ [0,8 ; 1,2]` ;
- facteur d'appui `kL ∈ [0,7 ; 1,3]` (si voiture à aéro) ;
- facteur de freinage `kB ∈ [0,8 ; 1,2]`.
Méthode : moindres carrés sur le profil de vitesse `v(s)` et le temps au tour, par descente de coordonnées avec bornes ; critère de qualité = erreur relative sur le temps au tour et RMS du profil de vitesse (§14.3). Les facteurs sont sauvegardés par (voiture, circuit, composé, setup de référence).

### 9.3 Utilisation en deux temps
1. **Tour de référence** avec le setup actuel (obligatoire pour une calibration fine) ; si Vincent ne veut pas rouler, le calcul se fait sur les données seules (confiance **basse**, indiquée).
2. **Tour de validation** avec le setup proposé : l'app compare le temps/prédiction et **affine** (boucle d'amélioration : le modèle apprend de l'écart).

### 9.3 bis Niveau du pilote
La calibration sur le meilleur tour de Vincent intègre sa façon de conduire, pas celle d'un pilote parfait : le modèle peut donc sous-estimer l'adhérence exploitable. Le facteur `kμ` est calculé sur le **meilleur tour valide**, et l'app affiche l'écart « modèle idéal / tour réel » pour que Vincent sache s'il reste de la marge ; un réglage `driverMargin` (défaut 0 %) permet de forcer un modèle plus optimiste.

### 9.4 Mode « mesure uniquement » (données voiture illisibles)
L'app estime les paramètres de la voiture à partir de l'enregistrement : masse apparente et puissance (équation de mouvement en ligne droite), adhérence maximale (g latéral maximal soutenu), traînée (décélération en roue libre), appui (variation du g latéral avec la vitesse). Moins précis ; confiance basse ; réglages limités aux grandeurs identifiables (aileron, pressions, répartition de frein, différentiel).

---

## 10. Optimisation du setup

### 10.1 Point de départ (heuristiques d'ingénieur)
Avant toute recherche numérique, générer un setup « raisonnable » à partir de règles : aileron selon la proportion de virages rapides/lignes droites, hauteur de caisse minimale hors touche-fond, répartition de freinage selon la charge dynamique, ratios de boîte alignés sur la vitesse maxi estimée du circuit, pressions au centre de la fenêtre thermique du composé. Ce point de départ est lui-même évalué par le simulateur.

### 10.2 Fonction objectif
Les poids `w_bal`, `w_stab`, `w_rob`, `w_trafic` sont modulés par le curseur `perfStab ∈ [0 ; 1]` (D15) : `w_* = w_*_base · lerp(0,4 ; 2,0 ; perfStab_stab)` où `perfStab_stab = 1 − perfStab` ; à `perfStab = 1` (temps pur) les pénalités tombent à 40 % de leur valeur de base, à `perfStab = 0` (stabilité d'abord) elles montent à 200 %.

**Qualification** : `J_Q = t_tour(s, setup, T_pneus_Q, carburant_Q) + w_bal·P_équilibre + w_stab·P_stabilité + w_rob·P_robustesse`.
**Course** : `J_C = t_relais(setup, N tours, carburant_C, usure) / N + w_bal·P_équilibre + w_stab·P_stabilité + w_trafic·P_trafic + w_rob·P_robustesse`.
- `P_équilibre`, `P_stabilité` : §8.3–8.4.
- `P_trafic` (course) : bonus d'aspiration et de stabilité au freinage (ailerons un peu plus chargés, répartition de freinage plus stable, hauteur de caisse un peu plus haute) et pénalité d'un setup dépendant de l'air propre.
- `P_robustesse` : écart de temps lorsque les facteurs calibrés varient de ±3 % (un setup fragile aux erreurs du modèle est pénalisé) ; objectif : un setup qui reste bon si le modèle se trompe un peu.

### 10.3 Variables d'optimisation
Lues dans `setup.ini` de la voiture (plages, pas, valeurs par défaut) : aileron avant/arrière, hauteur de caisse, raideurs, barres antiroulis, carrossage, pincement, amortisseurs, répartition de freinage, pression de frein, **pressions des pneus** (déduites de la température visée), différentiel (précharge, puissance, relâché), **ratios de boîte / rapport final**, **carburant** (course), composé de pneus (D18), **ABS, antipatinage et cartographie moteur** lorsqu'ils font partie du setup de la voiture, **modes ERS** (D13). Les réglages verrouillés ou masqués par la voiture sont exclus (D20). Le réglage non présent dans `setup.ini` n'est pas touché. Les dépendances et contraintes (touche-fond, étendue des clics) sont dans `setup_space.lua`.

### 10.4 Algorithme
1. **Recherche grossière** : échantillonnage de type Sobol sur les variables à fort impact (aéro, ratios, hauteur, pressions, freinage), sélection des `K` meilleurs points.
2. **Raffinement** : descente de coordonnées avec pas décroissants autour des meilleurs points, puis Nelder–Mead restreint sur les variables continues ; arrondi au pas discret de chaque variable.
3. **Analyse de sensibilité** : pour chaque variable retenue, effet sur le temps (affiché à l'utilisateur) et indicateur de confiance.
4. **Sélection finale** : meilleur `J` après vérification des contraintes dures ; en cas d'égalité (écart < 0,02 s), préférer le setup le plus proche du setup actuel.

### 10.5 Budget, annulation et reproductibilité
Budget configurable (`optBudgetEvals`, défaut 4 000 évaluations de tour en qualification, 600 évaluations de relais en course) ; temps total de calcul affiché ; progression en pourcentage ; **annulation immédiate** à tout moment ; graine fixe (reproductible) ; meilleur résultat intermédiaire toujours disponible.

### 10.6 Spécificités qualification vs course

| Aspect | Qualification | Course |
|---|---|---|
| Carburant | Quasi minimal autorisé (paramétrable) | Calculé pour la durée/les tours + marge `fuelMarginPct` |
| Pneus | Température de pointe sur un tour, pression à chaud optimale en un tour | Régularité sur le relais, pression qui limite la surchauffe, composé choisi par le simulateur de relais |
| Aéro | Compromis temps pur | Léger surplus d'appui/stabilité pour le trafic et les dépassements |
| Freinage | Répartition maximale performance | Répartition plus stable, usure des freins ménagée |
| Boîte | Rapports alignés sur la vitesse de pointe de l'air propre | Rapports tenant compte de l'aspiration (vitesse de pointe supérieure) |
| Robustesse | Moins critique | Plus critique (mille tours possibles, erreurs de modèle accumulées) |

---

## 11. Données de session
Température d'air et de piste, humidité/pluie (Pure), grip du circuit, vent si disponible, durée ou nombre de tours (saisis par l'utilisateur ou lus de la session), carburant au départ. **Pluie/piste mouillée** : hors v1 (D16). L'app détecte l'état (Pure, grip du circuit, pneus pluie sélectionnés) et affiche « calcul valable à sec uniquement » ; aucun setup n'est généré dans ces conditions.

---

## 12. Sorties

### 12.1 Fenêtre principale
Bandeau : voiture, circuit, source des données, confiance du modèle (calibré / non calibré), statut du calcul. Deux onglets : **Qualification** et **Course**. Chaque onglet : gain estimé vs setup actuel (en secondes et en %), liste des réglages (valeur actuelle → proposée) triés par impact, graphiques (vitesse simulée le long du tour, équilibre par virage), bouton **Recalculer**, bouton **Enregistrer le setup**, bouton **Valider en jeu** (§14).

### 12.2 Explication
Chaque réglage proposé porte une explication courte en français (« Aileron arrière +2 : 38 % du tour en virages rapides, gain 0,18 s »).

### 12.3 Export du setup
(D17)
1. **Écriture directe** d'un fichier `.ini` au format de setup d'AC dans `Documents\Assetto Corsa\setups\<voiture>\<circuit>\` (nom : `SetupLab_Quali_<date>.ini`, `SetupLab_Race_<date>.ini`) si la capacité d'écriture existe (Jalon 0).
2. Sinon : affichage complet + **copie dans le presse-papiers** du contenu du fichier + chemin cible, que Vincent colle dans un fichier.
Le setup actuel n'est jamais modifié (D8). Validation du fichier avant écriture (toutes les valeurs dans les plages de `setup.ini`).

---

## 13. Persistance
`ac.storage` ou fichier autorisé ; préfixe `setuplab:` ; `schemaVersion` avec migration. Cache : (voiture, circuit **et sa disposition**, composé, conditions) → modèle circuit, facteurs de calibration, derniers setups. Validation à la lecture **et** à l'écriture (type, finitude, bornes). Taille maxi du cache (ex. 5 Mo) avec purge LRU. Aucune confiance dans le contenu stocké.

---

## 14. Validation et critères de réussite

### 14.1 Validation en jeu (boucle)
1. Tour de référence → calibration.
2. Calcul du setup proposé.
3. Tour avec le setup proposé → comparaison entre le gain prédit et le gain réel ; affichage ; ré-optimisation possible avec le modèle affiné.

### 14.2 Banc d'essai hors jeu
Jeux de données de référence (voitures et circuits d'exemple) ; simulateur validé sur des cas analytiques connus (virage à rayon constant, ligne droite avec traînée, freinage à décélération limite) ; tests de non-régression chiffrés ; fuzz sur les fichiers de données (valeurs absurdes, LUT vides, `NaN`) ; soak (1 000 calculs enchaînés sans fuite).

### 14.3 Critères d'acceptation (v1)
- Après calibration, **erreur du temps au tour simulé ≤ 2 %** du temps mesuré, et RMS du profil de vitesse ≤ 6 % de la vitesse maxi, sur au moins 3 couples voiture × circuit.
- Le setup proposé n'est **pas plus lent** que le setup d'origine du constructeur sur ≥ 90 % des couples testés (mesure en jeu, 3 tours consécutifs par setup).
- Aucun réglage hors plage, aucun fichier de setup invalide.
- **DRS/ERS** : sur deux formules (DRS seul, puis DRS+ERS), erreur du temps au tour simulé ≤ 3 % après calibration ; le bilan d'énergie simulé respecte la batterie (jamais d'énergie déployée > énergie disponible) ; la stratégie de déploiement optimisée est ≥ à la stratégie par défaut de la voiture dans la simulation.
- **Aucun gel du jeu** : coût moyen de l'app < 0,3 ms/frame hors calcul ; pendant un calcul, pic < 3 ms/frame ; 60 images/s tenus en triple 4K.
- Temps de calcul total (qualification + course) < 90 s sur circuit de 6 km.

---

## 15. Réglages de l'app (schéma dans `config.lua`)
`enabled` · `frameGuardMs` (4) · `sliceBudgetMs` (2) · `ds` (2 m) · `optBudgetEvals` Q/C · `fuelMarginPct` (3 %) · `fuelQuali` (minimum) · `weights` (`w_bal`, `w_stab`, `w_trafic`, `w_rob`) · `calibrationAuto` (oui) · `language` · `debugLog`. Toutes les valeurs sont validées (§13).

---

## 16. Sécurité et robustesse
1. Une seule table globale `SETUPLAB` + callbacks `SETUPLAB__*` ; mode strict (globales interdites) en développement.
2. Interdiction de `os.*`, `web.*`, `loadstring`, `dofile` ; `io.*` limité aux chemins validés (§12.3).
3. Validation de toutes les entrées numériques (finitude, bornes) ; dénominateurs bornés (`max(ε, …)`), aucune division par zéro.
4. Mémoire bornée partout (échantillons, cache, journal circulaire 200 lignes).
5. Chaque tâche sous `pcall` ; erreur d'une tâche → arrêt de la tâche, message, aucune corruption d'état.
6. Détection de conflit : si un autre outil modifie le setup en parallèle, avertissement.
7. Scénarios adversariaux : fichiers de données absents/chiffrés/corrompus · LUT vides · `NaN` · circuit sans ligne de référence · circuit < 500 m ou > 25 km · voiture sans `aero.ini` · changement de voiture pendant un calcul · calibration divergente (facteurs aux bornes) → refus d'afficher une fausse confiance · stockage corrompu · annulation répétée · rechargement du script en cours de calcul.

---

## 17. Journalisation
Niveaux ERROR/WARN/INFO/DEBUG, débit limité, journal circulaire. Journalisés : source de chaque paramètre, facteurs de calibration, résultat de l'optimisation (valeurs `J`, nb d'évaluations, durée), erreurs de lecture de fichier. Aucune écriture fichier hors export.

---

## 18. Jalons de livraison

| Jalon | Contenu | Sortie |
|---|---|---|
| **J0** | Découverte API (§3.3), `API_NOTES.md`, panneau Capacités ; test de lecture de data voiture/circuit sur 3 voitures et 2 circuits | Rapport + capacités |
| **J1** | `util`, `config`, `caps`, `datasource`, banc d'essai + linter | Tests verts |
| **J2** | `track_model` (géométrie, courbure, segments) + enregistreur de reconnaissance | Circuit validé sur 2 pistes |
| **J3** | `car_model` + `laptime_sim` (point matériel étendu) + affichage du profil de vitesse | Simulation validée hors jeu |
| **J4** | `setup_space` + `optimizer` (qualification) + export du setup (écriture ou presse-papiers) | Premier setup utilisable |
| **J5** | `recorder` + `calibration` (+ mode mesure uniquement) | Erreur ≤ 2 % |
| **J6** | `stint_sim` + optimisation course (carburant, usure, trafic) | Setup course |
| **J6b** | DRS (zones, deux états) puis ERS (bilan d'énergie, programmation dynamique du déploiement), validation sur deux formules | Setup F1 |
| **J7** | UI complète + persistance + explications + boucle de validation en jeu | Revue UI |
| **J8** | Revue adversariale, fuzz, §16, correctifs, README, `CHANGELOG`, packaging | v1.0.0 |

À chaque jalon : relecture adversariale écrite, tests exécutés (journal joint), mise à jour de `API_NOTES.md`.

---

## 19. Risques

| Risque | Gravité | Parade |
|---|---|---|
| Fichiers de données illisibles pour certaines voitures (chiffrés) | Haute | `ac.INIConfig.carData` si présent ; sinon mode mesure uniquement (§9.4) |
| Impossibilité d'écrire un fichier de setup depuis Lua | Moyenne | Presse-papiers + chemin cible (§12.3) |
| Modèle trop éloigné de la physique d'AC | Haute | Calibration obligatoire, boucle de validation, indicateur de confiance honnête |
| Coût CPU en triple 4K avec 40–70 voitures | Haute | Tranches ≤ 2 ms, `frameGuardMs`, calcul suspendu si frame lente |
| Géométrie de piste imprécise | Moyenne | Plusieurs sources, confiance affichée, reconnaissance par tour |
| Setup « optimal » inconduisible | Moyenne | Pénalités équilibre/stabilité/robustesse |
| Voitures à aéro complexe, DRS et ERS (F1) | Haute | Modèle d'aéro par LUT ; DRS deux états ; ERS par bilan d'énergie ; jalon dédié J6b ; désactivation par voiture si fichiers illisibles |
| Changement de conditions (météo Pure, température) | Moyenne | Cache par conditions, recalcul proposé |

---

## 20. Points ouverts — tous tranchés (19/10/2026)

| # | Point | Décision | Réf. |
|---|---|---|---|
| 1 | Nom de l'application | **SetupLab** | D12 |
| 2 | Voitures concernées / DRS-ERS | **Toutes les voitures lisibles ; DRS et ERS complets dès la v1** | D13 |
| 3 | Écriture du fichier de setup | **Écriture directe si possible, sinon presse-papiers + chemin cible** | D17 |
| 4 | Tour de référence | **Optionnel, confiance affichée** | D14 |
| 5 | Pluie | **Livrée en 1.3.0** (D16 amendé le 21/10/2026) | D16, A31 |
| 6 | Objectif prioritaire | **Équilibré, curseur Performance ↔ Stabilité** | D15 |
| 7 | Composé de pneus | **Choisi par l'app, modifiable** | D18 |
| 8 | Mémoire par circuit | **Cache interne par voiture × circuit × conditions ; export de partage hors v1** | D19 |

**Backlog v1.1** : pluie et piste mouillée (livrée en 1.3.0) · export/import de partage entre PC · réglages ERS tour par tour en direct pendant la course.

---

## 21. Sources
- Wiki et SDK Lua CSP : https://github.com/ac-custom-shaders-patch/acc-lua-sdk
- Documentation CSP : https://cup.acstuff.club/docs/csp/
- Format des données de voiture d'Assetto Corsa (fichiers `.ini`/`.lut`/`data.acd`) : à documenter au Jalon 0 depuis l'installation de Vincent.
