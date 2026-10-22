# Relecture adversariale — jalons J7 et J8 (§0.4, §18)

Le 20/10/2026, un relecteur indépendant a relu en lecture seule, avec ses propres sondes :
- l'interface, la persistance, les explications et la validation en jeu (J7) ;
- l'app entière contre le §16 ;
- les corrections de la relecture J6b (solveur latéral, tables jusqu'à la vitesse atteinte, budget).

Tous les constats sont traités ou consignés. Une campagne de mutations contrôle les corrections (voir la fin du document).

**Après cette relecture (version 1.1.0)** : D8 a été amendé par Vincent le 20/10/2026 (chargement d'un setup SetupLab dans la voiture), les budgets par défaut sont passés à 1 200 / 400 (A13 tranchée), et les conditions de piste ne bloquent plus le calcul (A30). Voir `docs/RELECTURE_1_1.md`.

## Constats

| # | Gravité | Constat | Résolution | Test |
|---|---|---|---|---|
| B1 | Bloquant | L'arrêt de la recherche au temps pouvait tomber pendant la phase grossière : pas de raffinement, setup actuel proposé et « le setup actuel est le meilleur trouvé » affiché (URD à Spa : 0 réglage au lieu de 17). | **Arrêt au temps retiré** : le budget est le budget réglé, les phases gardent leurs proportions. « Recherche incomplète » en orange quand aucun optimum n'a été raffiné. Pas de phase grossière quand son pas n'est pas au moins 1,5 fois le pas fin (Nordschleife : elle coûtait autant sans donner de point sélectionnable). | O10, Q12, B01–B04 |
| B2 | Bloquant | Temps de préparation compté deux fois ; plus aucune évaluation, choix vide, erreur (URD avec ERS, Nordschleife, calcul course). | Plus aucune limite de temps. **Le setup actuel est toujours évalué et le choix n'est jamais vide.** Un essai de budget ramené d'après le coût mesuré a aussi été retiré : toute décision prise sur une horloge rend le résultat dépendant de la charge de la machine (§10.5 « reproductible » ; 21 % de gain en moins mesurés en course à 90 % de charge). | O10, Q11 |
| M1 | Majeur | Données stockées reprises au-delà des bornes du producteur : puissance 2,5 affichée « Modèle calibré » ; rugosité 35 fois la borne de plausibilité libérant la suspension. | Bornes du schéma celles du producteur. Calibration reprise seulement sans facteur en butée et avec la température de piste ; facteurs identifiés conservés. Rugosité reprise seulement si l'avant et l'arrière concordent. | I04, I07 |
| M2 | Majeur | Clés sans version des données ni du modèle (D9) : calibration périmée reprise après une mise à jour du mod ou de l'app. | Empreinte des fichiers de la voiture et version du modèle stockées avec chaque calibration et rugosité ; en cas d'écart, entrée ignorée avec la raison. | I07, D16 |
| M3 | Majeur | Une seule validation pour les deux onglets, genre ignoré, « Validé » en vert sans tolérance (0,80 s prévu, 0,05 s mesuré). | Un setup proposé et une validation par genre. Verdict « conforme » à 0,15 s ou 30 % du gain prévu près, sinon « écart : recalibrer, puis recalculer » en orange. | M03, I08 |
| M4 | Majeur | Durée affichée plafonnée à la durée visée, fausse sous 60 images/s et sans horloge. | Durée estimée à la fréquence d'images et à la tranche réelles, jamais plafonnée ; en orange au-delà de la durée indicative, avec l'invitation à baisser le budget. | Q07 |
| m1 | Mineur | Explications en course inventées (« 0 % -> 0 % ») ou vides ; « coût -0.00 s ». | Une clause sans donnée est omise ; effet seul négligeable dit comme tel. | I10 |
| m2 | Mineur | Purge contournable (clé `settings:…`), horodatage non validé, texte de plus de 64 Ko perdu à la séance suivante. | Clé de réglages unique ; horodatage validé ; purge avant chaque écriture (le texte écrit tient toujours sous 64 Ko) ; version 0 refusée. | Y01, Y02 |
| m3 | Mineur | Réglages non modifiables relus du stockage : `enabled=false` désactivait l'app sans recours. | Seuls les réglages modifiables dans l'interface sont conservés et relus. | I02 |
| m4 | Mineur | Sérialisation complète du stockage à chaque frame pendant un curseur (0,55 à 0,96 ms). | Écriture en mémoire ; sérialisation et purge au flush (1 Hz). | Y02 |
| m5 | Mineur | Confiance du bandeau : « calibré » si l'un des deux calculs l'était. | Confiance du dernier calcul terminé. | I04 |
| m6 | Mineur | Onglet Course sans gain en % ni graphiques (§12.1). | Gain en %, profil de vitesse et équilibre par virage, sur le dernier tour échantillonné du relais. | I10 |
| m7 | Mineur | Seuils de virage codés en dur (150 et 90 km/h) au lieu de ceux du §7.3. | Seuils de la configuration (160 et 80 km/h). | — |
| m8 | Mineur | Intentions et écriture du stockage non bloquées en mode inerte. | Réglage, calibration, validation et copie refusés en ligne et en replay ; aucune écriture du stockage. | I09 |
| m9 | Mineur | Erreur d'un onglet rattrapée puis sections redessinées en double. | Erreur laissée à la colle, qui la compte ; pas de repli en double. | — |
| m10 | Mineur | §13 : modèle du circuit non mis en cache, conditions hors de la clé, `schemaVersion` inutilisé. | `schemaVersion` est la version du format. Écarts consignés dans A28 : modèle de circuit reconstruit à chaque découverte (tâche découpée) ; calibration reprise seulement à 10 °C de piste près. | — |
| m11 | Mineur | Derniers setups relus sans horodatage d'usage (ordre de purge). | Relus avec l'horodatage. | — |
| F1 | Banc final | La frame du passage de ligne cumulait le travail de fin de tour (0,5 à 1 ms) et une tranche de calcul complète (2 ms) : environ 3 ms au calme, au-delà sous charge (M04 instable). Défaut d'origine, pas une régression. | Le travail déjà fait dans la frame est retiré de la tranche, avec un plancher de 0,25 ms (une unité de travail au moins). Le résultat du calcul ne dépend pas du découpage (Q11). | A20 (horloge simulée), M04 |
| T | Tests | O10, B01–B03, I03, I04, Y02, F04, I05 passaient malgré les défauts. | B01 à B04 vérifient la qualité (optimums raffinés, réglages changés), pas seulement la durée ; Q11 vérifie la reproductibilité avec deux horloges ; I07 stocke des valeurs conformes au schéma mais douteuses ; I08 couvre la validation par genre ; I10 les explications en course. | — |

**Points vérifiés sans défaut par le relecteur :**
- résolution latérale (écart ≤ 0,00049 m/s², toujours tenable) ;
- tables jusqu'à la vitesse atteinte (aucune lecture au-delà) ;
- `recordBalance` ;
- garde-fous de pression, de surchauffe, de carrossage et de hauteur minimale non contournés ;
- butées conservées (H16) ;
- D8, §16.2 et D10 ;
- `Store.parse` n'exécute aucun code ;
- clés sans collision ;
- signatures ImGui conformes au SDK ;
- composé pluie refusé ;
- ABS relu ;
- archive (`tests/package.py`) ;
- mode inerte du calcul et de l'enregistrement.

## Budget (§14.3), mesures finales

Budgets par défaut 2 500 / 450, Monza. Durées ramenées au calme par une tâche de référence fixe, chronométrée avant et après chaque mesure ; les durées brutes sont entre parenthèses. La machine de développement est souvent chargée par d'autres processus.

| Cas | Total |
|---|---|
| Huracán | ≈ 49 à 67 s |
| URD avec ERS | ≈ 65 à 76 s (78 à 93 s brutes) |
| DTM pire cas (26 réglages, DRS, rugosité, hauteur) | ≈ 76 à 86 s (81 à 97 s brutes) |
| Hors cadre : URD avec ERS sur la Nordschleife (20,8 km) | ≈ 161 à 178 s |

**Mesure d'acceptation, durées brutes, sans correction.** Chaque passage a été lancé après une attente de CPU sous 20 % (trois relevés de suite). La charge remonte ensuite, le banc compris :

| Passage | B03, DTM pire cas | B02, URD avec ERS |
|---|---|---|
| Mesure isolée 1 | 91 s (CPU 36 %) | 79 s (CPU 21 %) |
| Mesure isolée 2 | 81 s (CPU 29 %) | 78 s (CPU 23 %) |
| Banc complet 1 (CPU 14 % au départ, 70 % à la fin) | 93 s | 88 s |
| Banc complet 2 (CPU 28 % au départ, 20 % à la fin) | 97 s | 93 s |

Les nombres d'évaluations sont identiques à chaque passage : le calcul est déterministe, et les écarts de durée viennent de la machine.

La correction par la tâche de référence ramène ces durées à 76 à 86 s pour le DTM et à 65 à 76 s pour l'URD, ce qui donne un banc vert. Cette correction reste une approximation : chronométrée avant et après le calcul, elle ne voit pas une charge qui varie pendant. Un échantillonnage pendant le calcul par une micro-tâche a été essayé puis retiré : une boucle de calcul pur ne subit pas la concurrence de cache et de mémoire, et sous-estime la charge (×1,08 à 74 % de CPU).

**Lecture :** pour le pire cas (DTM), le §14.3 n'est pas démontré de façon robuste sur cette machine. Les durées brutes vont de 81 à 97 s, et une seule sur quatre est sous 90 s. L'URD avec ERS va de 78 à 93 s. En jeu, AC et CSP chargent eux-mêmes la machine. La Huracán (19 réglages) tient largement : 49 à 67 s.

**À valider par Vincent (A13) :**
- garder 2 500 / 450 ;
- ou passer la course à 400 relais : −0,016 s/tour mesuré sur le DTM, rien sur la Huracán. La course pèse environ 58 % du total du DTM, donc −11 % de relais réduit le total d'environ 6 % (5 à 6 s). Le pire passage brut, 97 s, resterait au-dessus de 90 s ;
- ou baisser aussi la qualification. En qualification, 1 200 évaluations donnent le même gain qu'à 2 500 sur le DTM, et 0,02 s de moins sur la Huracán.

## Conformité au §16

| Point | Mise en œuvre | Preuve |
|---|---|---|
| 1. Une seule table globale `SETUPLAB` et les rappels `SETUPLAB__*` ; mode strict en développement | Colle seule au contact des globales CSP ; banc en mode strict (toute globale non déclarée est une erreur) | linter (`tests/lint.py`), toutes les suites |
| 2. Ni `os.*`, ni `web.*`, ni `loadstring`, ni `dofile` ; `io` limité | Interdits par le linter ; `io` seulement dans `exporter.lua` (nouveaux fichiers du dossier des setups, relus après écriture) ; persistance par `ac.storage` ; l'archive refuse tout appel interdit | linter, `tests/package.py`, E01–E05 |
| 3. Entrées numériques validées, dénominateurs bornés | `Util.isFinite`, bornes de chaque grandeur lue ; `max(ε, …)` aux divisions | fuzz F01–F07, S10, D06 |
| 4. Mémoire bornée | Enregistreur (échantillons, 4 setups, 6 setups connus), journal circulaire de 200 lignes, stockage ≤ 64 Ko, rapport borné | R03 (tours conservés par setup), C04 (journal de 200 lignes), Y02 (purge), A19 (déchets d'une découverte), endurance (1 000 découvertes, 4,9 Mo en fin) |
| 5. Chaque tâche sous `pcall` | Ordonnanceur : erreur d'une tâche → tâche en échec, message, état intact | U11, Q06, F05 |
| 6. Détection de conflit | Setup du jeu changé depuis la découverte : calcul et enregistrement refusés | Q05, Q06 |
| 7. Scénarios adversariaux | Voir ci-dessous | — |

**Scénarios adversariaux du §16.7 :**

| Scénario | Comportement | Test |
|---|---|---|
| Fichiers absents, chiffrés, corrompus | `data.acd` illisible : mode « mesure uniquement » ; INI corrompus : bornés, raison | D04, D06, F03 |
| LUT vides | Courbe de puissance vide : calcul refusé, raison ; courbes de pneus vides : fenêtre de température « inconnue », affichée telle quelle | F07, F01 (analyseurs) |
| `NaN` | Valeurs non finies refusées ; valeurs extrêmes mais finies : simulation finie | F01–F03 (`NaN` de l'hôte), S10 |
| Circuit sans ligne de référence | Reconnaissance sur le premier tour | M05 |
| Circuit de moins de 500 m ou de plus de 25 km | Refusé, raison | T10 |
| Voiture sans `aero.ini` | Modèle déclaré incomplet, calcul refusé avec la raison | F06 |
| Changement de voiture pendant un calcul | Résultats périmés, nouvelle découverte | A05 |
| Calibration divergente (facteurs aux bornes) | Déclarée inutilisable, raison affichée (V03 : un long virage raté pousse l'appui en butée) | V03 |
| Stockage corrompu | Champs refusés un par un, réglages par défaut | Y01, I02, I07, F04, F05 |
| Annulation répétée | Annulations en endurance (14 sur 56 calculs) | soak, O05, Q05 |
| Rechargement du script pendant un calcul | Instance précédente libérée | A08 |

## Campagnes de mutations (J7, J8)

| Domaine | Détectées |
|---|---|
| Corrections de la relecture J6b (M1, M3, mineurs), persistance et interface du J7 | 24 / 24 |
| Résolution latérale et tables jusqu'à la vitesse atteinte | 4 / 4 |
| Voiture sans `aero.ini`, copie du tour pré-allouée | 2 / 2 |
| Corrections de la relecture J8 | 19 / 21 |
| Tranche nette du travail de la frame (F1) | 2 / 2 |

Les deux mutations non détectées sont équivalentes, chacune couverte par une seconde défense :
- **Choix vide.** Le garde-fou « choix jamais vide » est retiré, mais le setup actuel est toujours évalué : la sélection a donc toujours un point.
- **Réglages relus par la colle.** La colle relit tous les réglages stockés, mais le schéma du stockage refuse déjà ceux qui ne sont pas modifiables dans l'interface.

Les quatre trous de test révélés par la première passe (validation propre au genre, verdict sous tolérance, rien d'écrit en ligne, bandeau du dernier calcul) sont comblés : M03, I08 (`Calibration.verdict`), I09, I04.
