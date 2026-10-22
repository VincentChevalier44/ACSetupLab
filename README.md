# SetupLab — générateur de setups pour Assetto Corsa

**Version 1.0 — bêta 1.3** (`1.0.0-beta.1.3`) · App Lua pour Custom Shaders Patch (version gratuite 0.2.11 ou plus récente) · Licence MIT

SetupLab calcule, pour chaque couple voiture × circuit, un setup de **tour rapide** (essai, journée circuit, hotlap, time attack, qualification) et un setup de **course** (relais). Il explique chaque réglage, se cale sur vos propres tours, et l'affine pendant que vous roulez : il vous propose une version, vous la validez puis l'essayez, ou vous recommencez.

> *English summary — SetupLab is a Custom Shaders Patch (CSP) Lua app for Assetto Corsa. It computes qualifying and race setups for any car × track pair from the car's data files and the track's AI line, calibrates its model on your own laps, and refines the setup while you drive. Every proposal must be validated by you before a file is written; it only loads a setup into the car on an explicit two-click confirmation in the pits. The user interface and documentation are in French. Beta software: not yet verified in game on a wide range of cars.*

📖 **Notice d'utilisation : [`docs/notice.html`](docs/notice.html)** (à ouvrir dans un navigateur ; elle est aussi dans l'archive de l'app).

---

## Sommaire

- [Fonctionnalités](#fonctionnalités)
- [Installation](#installation)
- [Démarrage rapide](#démarrage-rapide)
- [Ce que SetupLab ne fait jamais](#ce-que-setuplab-ne-fait-jamais)
- [État de la bêta et limites connues](#état-de-la-bêta-et-limites-connues)
- [Développement](#développement)
- [Structure du projet](#structure-du-projet)
- [Documentation](#documentation)
- [Licence](#licence)

## Fonctionnalités

- **Setup de tour rapide et de course** calculés à partir des fichiers de la voiture (pneus, aéro, moteur, boîte, freins, suspension, différentiel, DRS, ERS) et de la ligne IA du circuit (courbure, pente, dévers, zones DRS).
- **Chaque réglage expliqué** : une phrase par réglage proposé, son gain, l'équilibre par virage ; chaque réglage non touché l'est avec sa raison.
- **Vos temps d'abord** : votre meilleur tour (ou votre tour moyen en course), l'objectif estimé (votre temps moins le gain prévu) et le gain réel de chaque version. Le modèle est calibré sur vos tours.
- **Affinage pendant que vous roulez** : cochez **SetupLab actif**, roulez. Chaque setup proposé s'annonce à l'écran ; **Valider** l'enregistre, **Charger** le met dans la voiture au stand, **Recommencer** l'abandonne. Rien n'est enregistré sans votre validation.
- **Vos retouches gardées** : un réglage que vous modifiez à la main au stand après un chargement n'est plus changé par les calculs suivants.
- **Overlay en jeu** (fenêtre « SetupLab Overlay ») : en roulant, le setup en piste est-il mieux ou moins bien que celui d'avant, sur vos tours ; les réglages changés qui comptent le plus, avec leur gain prévu ; la version suivante quand elle est prête.
- **Mémoire du circuit** : le setup validé ou figé (cadenas) est gardé par voiture, circuit, séance (essai ou journée circuit, qualification, course) et état de piste (sec, pluie), et proposé à la visite suivante.
- **Pluie** (météo de CSP, Pure compris) : choix du composé (slicks, intermédiaires, pluie), pressions, aileron, aides au pilotage plus strictes ; calibration à part du sec.
- **Composé de pneus** choisi selon la température mesurée de vos pneus, ou imposé.
- **Fichiers clairs** : `SetupLab_Qualif_v1.ini`, `SetupLab_Course_Pluie_v3.ini`… (votre nom à la place de « SetupLab » si vous en choisissez un), numérotés à la suite sur le circuit ; votre meilleur tour réel avec une version de qualification s'ajoute à son nom (`SetupLab_Qualif_v2_1.41.792.ini`). Il ne reste que les versions gardées : les copies inutiles et les versions non gardées partent à la Corbeille.

## Installation

Prérequis : Assetto Corsa avec **Custom Shaders Patch 0.2.11** (la version gratuite, installée par Content Manager) ou plus récent, previews comprises ; en mode hors ligne. SetupLab a été développé avec la 0.3.0-preview675 ; sur la 0.2.11, trois fonctions de CSP manquent et l'app s'en passe (voir `docs/API_NOTES.md`, A36).

1. Télécharger la dernière archive `SetupLab-….zip` dans les [Releases](https://github.com/VincentChevalier44/ACSetupLab/releases) (ou cloner le dépôt).
2. Décompresser l'archive dans `assettocorsa/apps/lua/` : elle contient déjà le dossier `SetupLab/`. Au final, `assettocorsa/apps/lua/SetupLab/` contient `SetupLab.lua` et `manifest.ini` (pas de dossier `SetupLab` dans un autre `SetupLab`). Pour mettre à jour, remplacer les fichiers : vos réglages et la mémoire des circuits sont gardés par CSP, hors de ce dossier.
3. En jeu, ouvrir **SetupLab** depuis la barre d'apps ou l'écran de setup. Une seconde fenêtre, **SetupLab Debug**, montre l'ordonnanceur, le coût par image et le journal.

## Démarrage rapide

1. Lancer une séance hors ligne (essai, journée circuit, qualification ou course). Ouvrir SetupLab **voiture au stand** et attendre « Découverte terminée ».
2. Cocher **SetupLab actif**, puis rouler des tours propres.
3. Quand un setup est prêt, il s'annonce en haut de l'écran : « SetupLab : setup tour rapide v1 prêt ».
4. Au stand, menu de setup ouvert : **Valider v1** (le fichier est enregistré), puis **Charger le setup … dans la voiture** et **Confirmer le chargement**.
5. Rouler avec : SetupLab compare vos temps avec et sans. Puis **Valider**, **Recommencer (ne pas garder)** ou **Figer (cadenas)** les versions suivantes.

Le détail de chaque bouton, des onglets et des réglages est dans la [notice d'utilisation](docs/notice.html).

## Ce que SetupLab ne fait jamais

- Il ne modifie jamais le contenu d'un fichier ni la physique du jeu, et n'écrase jamais un setup : chaque enregistrement est un **nouveau fichier** du dossier des setups de la voiture et du circuit.
- Il n'écrit que **sur votre clic** : « Enregistrer », « Valider », « Figer », plus une copie de sauvegarde du setup en cours juste avant un chargement, quand elle est utile (pas quand la voiture a déjà un setup gardé de SetupLab).
- Il ne touche jamais à vos propres fichiers. Il ne range que les fichiers qu'il a écrits, intacts (reconnus à leur nom et à l'empreinte de leur contenu), voiture arrêtée : à la **Corbeille de Windows**, une version que vous ne gardez pas (« Recommencer ») et, à la validation, les copies « Avant chargement » identiques à un fichier gardé ; il **renomme** une version de qualification gardée pour y mettre votre meilleur tour. Avec CSP 0.2.11, la Corbeille n'existe pas encore pour les apps : ces fichiers sont supprimés définitivement.
- Le setup de la voiture ne change que sur votre demande explicite : au stand, voiture arrêtée, menu de setup ouvert, en deux clics, après une copie de sauvegarde ; seul un fichier écrit par SetupLab (reconnu à son nom et à l'empreinte de son contenu) peut être chargé.
- Aucun accès réseau, aucun `os.*`, `loadstring` ni `dofile`.
- Il est inactif en ligne et en replay.
- Il ne fait confiance à aucune donnée lue (fichiers de la voiture, état du jeu, stockage) : tout est borné et validé.

## État de la bêta et limites connues

Cette première bêta a été construite et vérifiée sur un **banc d'essai hors jeu** (282 tests : modèles, optimiseur, interface, chargement, persistance, fuzz). Elle a été essayée en jeu sur la DTM 2026 (WHK), mais l'essentiel n'a pas encore été vu en jeu sur d'autres voitures. À confirmer en jeu :

- la fidélité du tour simulé à AC (objectif : écart de temps ≤ 2 %) ; tant que la calibration n'atteint pas ses seuils, les gains sont indicatifs et l'app l'affiche ;
- le modèle pluie (hypothèses H25 à H28 de `docs/API_NOTES.md`) : vos tours mouillés le calibrent ;
- l'affichage : couleurs des boutons, tuiles, sections, alerte à l'écran ;
- certains réglages restent volontairement conservés, avec leur raison affichée : pincement, différentiel au lâcher et précharge, butées (hypothèse à confirmer), ressorts et amortisseurs tant qu'un tour valide sur le sec n'a pas mesuré la rugosité, hauteur de caisse sans découverte au stand, réglages définis par le script d'une voiture (effet inconnu).

Vos retours sont les bienvenus dans les [Issues](https://github.com/VincentChevalier44/ACSetupLab/issues). Pour un problème, joindre le rapport de l'onglet **Capacités** (« Copier le rapport J0 »).

## Développement

### Banc d'essai hors jeu

Le banc charge `SetupLab.lua` **tel quel** dans LuaJIT 2.1 (le moteur de CSP) via `lupa`, avec un hôte CSP simulé (`tests/fakehost.lua`). Les objets d'état y lèvent une erreur sur un champ inconnu, comme une structure FFI de CSP ; toute globale non déclarée est une erreur.

Prérequis : Python 3, de préférence dans un environnement virtuel (les commandes utilisent `python -I`, qui ignore les paquets installés pour l'utilisateur) :

```
python -m venv .venv
.venv\Scripts\activate
python -m pip install -r tests/requirements.txt
```

Jeux de données : les tests utilisent des voitures et des circuits du jeu (fichiers de données de Kunos et de mods). **Ils ne sont pas publiés dans ce dépôt** : les générer depuis votre propre installation (le dépôt placé dans `assettocorsa/apps/lua/SetupLab/`) :

```
python -I tests/tools/make_fixtures.py [racine_assettocorsa]
```

| Type | Jeux |
|---|---|
| Voitures | `formula_k` (SDK Kunos), `lamborghini_huracan_gt3_evo2`, `urd_px1_aura` (mod URD, ERS), `whk_dtm_2026` (mod WHK, DRS) |
| Circuits (ligne IA `fast_lane.ai`) | Spa, Monza, Red Bull Ring GP, Nordschleife |

Une voiture ou un circuit absent est ignoré ; les tests qui l'utilisent échouent.

```
python -I tests/run_tests.py            # linter et ses auto-tests, puis toutes les suites
python -I tests/run_tests.py --filter AU  # seulement les tests dont le nom contient « AU »
python -I tests/run_tests.py --soak     # + endurance : 1 000 découvertes enchaînées
python -I tests/lint.py                 # linter seul
python -I tests/package.py              # archive de distribution dist/SetupLab-<version>.zip
```

Les résultats sont écrits dans `tests/results.json`. Les tests de temps (budget par image) mesurent en temps réel : une machine chargée (Assetto Corsa lancé en même temps, par exemple) peut les faire échouer.

`tests/package.py` construit l'archive à partir d'une liste blanche (`SetupLab.lua`, `manifest.ini`, `icon.png`, `README.md`, `CHANGELOG.md`, `src/`, `docs/`), vérifie la version et l'absence d'appels interdits, et n'écrase jamais une archive existante. `tests/` n'est jamais distribué.

### Règles imposées par le linter

- seule la colle (`SetupLab.lua`) lit les globales CSP ; les modules reçoivent l'hôte en paramètre ;
- le noyau pur ne dépend que du noyau pur ;
- `os`, `load`, `loadstring` et `dofile` sont interdits ;
- `ac.setSetupSpinnerValue` et `ac.saveCurrentSetup` sont interdites partout, `ac.loadSetup` partout sauf dans `src/exporter.lua` ;
- aucune variable locale inutilisée, aucun TODO, lignes de 140 caractères au plus.

## Structure du projet

```
SetupLab.lua         colle CSP : hôte injecté, rappels, garde-fous, tâches de fond, persistance, affinage
manifest.ini         manifeste de l'app CSP
icon.png
src/util.lua         noyau pur : maths, LUT, INI, RNG, journal, ordonnanceur, dates, noms de fichiers
src/config.lua       schéma unique des réglages et constantes internes
src/caps.lua         capacités CSP, horloge précise, heure locale, rapport J0
src/datasource.lua   lecture voiture / circuit / session / setup -> tables pures
src/track_model.lua  modèle de circuit
src/car_model.lua    modèle de voiture : pneus (sec et mouillé), aéro, moteur, freins, suspension
src/laptime_sim.lua  simulation de tour quasi statique
src/ers.lua          ERS : lecture, batterie, programmation dynamique
src/ers_plan.lua     ERS : zones, options, régime établi
src/setup_space.lua  crans de setup <-> grandeurs physiques, rendu du fichier
src/optimizer.lua    optimiseur, tour rapide et course, choix du composé
src/stint_sim.lua    simulation de relais : carburant, usure, trafic
src/explain.lua      explications des réglages, équilibre par virage
src/recorder.lua     enregistreur de tours, vos temps par setup, export
src/calibration.lua  calibration, mode « mesure uniquement »
src/exporter.lua     écriture des nouveaux fichiers, chargement dans la voiture
src/store.lua        persistance validée (réglages, calibrations, mémoire du circuit)
src/ui.lua           fenêtres (lecture seule de l'état)
docs/                notice d'utilisation, spécification, notes d'API, relectures
tests/               banc hors jeu, linter, générateur de jeux de données (jamais distribué)
```

## Documentation

| Fichier | Contenu |
|---|---|
| [`docs/notice.html`](docs/notice.html) | Notice d'utilisation (HTML5) |
| [`CHANGELOG.md`](CHANGELOG.md) | Journal des versions, dont l'historique de développement |
| [`docs/SetupLab_PDR_v0.2.md`](docs/SetupLab_PDR_v0.2.md) | Spécification (PDR) et décisions |
| [`docs/API_NOTES.md`](docs/API_NOTES.md) | API CSP constatées, formats, hypothèses (H1 à H28), arbitrages (A1 à A35), protocole en jeu |
| `docs/RELECTURE_*.md` | Relectures adversariales de chaque jalon |

## Licence

[MIT](LICENSE) © 2026 VincentChevalier44 (Vincent Chevalier).

Assetto Corsa est une marque de Kunos Simulazioni. SetupLab est un projet indépendant, sans lien avec Kunos Simulazioni ni avec les auteurs de Custom Shaders Patch.
