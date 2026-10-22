# Relecture adversariale — jalon J5 (§0.4, §18)

Le 20/10/2026, un relecteur indépendant a relu le J5 en lecture seule : enregistreur, calibration, mode « mesure uniquement », colle, interface. Il a utilisé ses propres sondes, dont un hôte simulé dont la ligne de chronométrage est décalée de l'origine de la ligne IA.

Tous les constats sont traités. Une campagne de mutations contrôle les corrections (voir la fin du document).

## Constats

| # | Gravité | Constat | Résolution | Test |
|---|---|---|---|---|
| 1 | Bloquant (si l'origine de la ligne IA s'écarte de la ligne de chronométrage) | Le contrôle de couverture ne tenait pas compte du bouclage de la progression. Quand `splinePosition` ne repasse pas à 0 dans la frame où `lapCount` augmente, l'écart mesuré valait presque un tour : à ±3 m de décalage, aucun tour n'était valide. Le banc ne le voyait pas, car l'hôte simulé faisait les deux à la fois. | Écarts mesurés jusqu'à la ligne la plus proche, bouclage compris (`min(p, 1 − p)`). Un départ arrêté (premier échantillon sous 5 m/s) est rejeté. L'hôte simulé place la ligne de chronométrage où l'on veut. | R06 (−10 à +10 m) |
| 2 | Majeur | Avec une signature de setup nil (crans illisibles, D7), `laps.best[nil]` levait une erreur avant la mise à jour du compteur : le tour était recopié et l'erreur se répétait à chaque frame. | Le compteur avance avant toute autre opération. Un tour sans signature lisible est rejeté (« setup illisible »), jamais retenu comme meilleur tour. | R07 |
| 3 | Majeur | Au passage de la ligne, `startCalibration` préparait les profils mesurés (tri, abscisses) et les tampons de simulation hors de la tâche découpée : 3 à 37 ms selon le circuit et le nombre de setups (D6, §14.3). | Le passage de ligne ne fait que choisir les tours ; profils et tampons sont préparés dans la tâche « calibration », qui rend la main tous les 500 échantillons. Tri par progression en temps quasi linéaire (`Util.progressOrder`). Mesuré : frame du passage de ligne à 2,3 ms, tranche de calcul de 2 ms comprise. | M04 |
| 4 | Majeur | Sur un circuit reconstitué (sans ligne IA), la calibration, l'estimation et l'export utilisaient `splinePosition`, que le code lui-même tient pour inexploitable dans ce cas. | Les positions sont conservées sans ligne IA ; la progression de chaque tour est refaite par la distance parcourue, normalisée. L'hôte simulé laisse `splinePosition` à 0 sans ligne IA. | M05 (calibration après reconnaissance : RMS 0,10 %) |
| 5 | Majeur | Le cran FUEL faisait partie de la signature. Le setup qualification part avec 3 tours de carburant ; en en remettant pour ses essais, Vincent aurait rendu ses tours « setup inconnu », et la validation ne se serait jamais affichée. | FUEL exclu de la signature (`K.signatureIgnored`). Le carburant de chaque tour est mesuré à part. | M03, M09 |
| 6 | Majeur | Signature calculée différemment à la découverte (crans assainis par `copySpinner`) et en roulant (crans bruts) : un seul cran mal formé, et aucun tour n'était rattaché. | Les deux signatures passent par `Datasource.copySpinner`. | M09 (cran sans valeur finie) |
| 7 | Majeur | Temps officiel lu dans la frame du passage, sans recoupement : une mise à jour tardive de `previousLapTimeMs` aurait donné au tour le temps du précédent. Un temps nul était accepté, puis divisé. | Le temps officiel est retenu seulement s'il recoupe à 0,1 s près l'une de trois références (voir la revue finale). En attendant, la valeur est relue pendant 1 s au plus ; ensuite, rejet avec les valeurs en cause. Un temps nul ou négatif ne passe jamais. | R09 (mise à jour retardée de 3 frames, temps faux de 2 s, pause de 10 s) |
| m1 | Mineur | Estimation du mode « mesure uniquement » non découpée (3 à 7 ms). | Rendu de main tous les 500 échantillons. | — |
| m2 | Mineur | Mode « mesure uniquement » relancé à chaque tour valide, sur le dernier tour. | Seul un tour plus rapide que celui de l'estimation en cours la relance (§9.3 bis). | — |
| m3 | Mineur | Éviction « premier entré, premier sorti » des meilleurs tours : la référence de la découverte partait la première. | Le setup de la découverte et le setup proposé ne sont jamais évincés (`rec.protected`). | — |
| m4 | Mineur | Carburant et km pneus illisibles enregistrés à 0, puis pris pour des mesures. | Carburant et km absents s'ils manquent à un seul échantillon ; le modèle garde alors sa valeur par défaut. | — |
| m5 | Mineur | En entrant en replay, jusqu'à 1 s de frames était enregistrée (contexte relu à 1 Hz), et l'enregistreur n'était jamais remis à zéro. | Drapeaux en ligne et replay lus à chaque frame ; le tour en cours est abandonné. Pas d'échantillon pendant une pause. | M08 (replay en plein tour) |
| m6 | Mineur | Recul de la voiture (téléportation en arrière) non détecté. | Un recul de plus de 50 m invalide le tour. | R10 |
| m7 | Mineur | Reconnaissance jamais retentée après un échec. | Nouvelle tentative au tour valide suivant, 3 au plus par contexte. | — |
| m8 | Mineur | `knownSetups` sans borne (§16.4). | 6 setups au plus ; la référence et le setup proposé sont protégés. | — |
| m9 | Mineur | « Calibration utilisée par le calcul de setup » s'affichait à côté d'un résultat calculé sans elle. | « Calibration utilisable : elle servira au prochain calcul de setup. » | M01 |

Points vérifiés sans défaut :
- aucune écriture ni modification du setup en cours (D8) ; ni `os`, ni `io`, ni réseau dans le code J5 ;
- unités et repères (accélérations en g, psi, °C, km) ;
- calibration déterministe et budget borné ; matrice singulière gérée ;
- facteurs transmis seulement si la calibration est utilisable.

Balayage de 45 cas de butée : aucune fausse confiance.

## Contrôles internes, avant la relecture

- **Identifiabilité.** Sur une borne, le côté bloqué renvoyait au point lui-même : la hausse mesurée était nulle, et un facteur en butée passait pour « non identifié », remis à 1. Désormais, seuls les côtés réellement déplacés comptent. Test V08.
- **Tests trop indulgents.** La première campagne de mutations a montré que 5 tests laissaient passer leur mutation. Ils ont été renforcés :
  - valeurs vraies hors de la grille de la descente ;
  - pressions à chaud réelles différentes de la loi des gaz ;
  - butée avec un ajustement dans les seuils ;
  - abscisse contrôlée sur tous les points ;
  - virage raté long pour éprouver la perte de Huber.

## Revue finale

| # | Constat | Résolution | Test |
|---|---|---|---|
| F1 | Le recoupement du temps officiel supposait qu'AC remet son chrono à zéro dans la frame où le compteur augmente. L'hôte simulé faisait les deux à la fois, comme pour le constat 1. Si le chrono était remis à zéro une frame plus tôt, chaque tour aurait été rejeté. | Trois références, dont une seule doit recouper le temps officiel : le chrono d'AC la frame d'avant ; son maximum pendant le tour, suivi à partir de la frame qui suit le passage ; la durée en temps de simulation. L'hôte simulé reproduit les deux ordres possibles. | R09 (chrono remis à zéro 1 ou 2 frames avant le compteur, ou 1 frame après ; remis à zéro avant et pause pendant le tour, où seul le maximum recoupe) |
| F2 | Le setup qualification part avec 3 tours de carburant. Depuis que FUEL est exclu de la signature, « gain prévu / gain mesuré » comparait des tours à charges différentes à une prévision faite à charge égale : l'effet de la masse, de l'ordre du gain de setup, aurait pu « confirmer » le modèle à tort. | Gain prévu = écart des deux tours simulés par la dernière calibration, chacun avec son carburant, ses pneus et sa piste mesurés. Gain mesuré = écart des temps officiels. Les deux charges de carburant sont affichées. | M03 |
| F3 | Le découpage du travail déplacé dans la tâche « calibration » n'avait pas été mesuré sur le pire cas. | Mesure sur la Nordschleife, 4 setups, 12 414 échantillons par tour : 0,86 ms au plus entre deux rendus de main. | V09 |

Autres vérifications :
- la découverte et la signature en roulant lisent les crans par une seule fonction (`Datasource.readSpinners` : même plafond, même assainissement) ;
- décompte des constats corrigé dans le journal (6 majeurs).

## À vérifier en jeu

Points que le banc ne peut pas trancher :
- décalage réel entre ligne de chronométrage et origine de la ligne IA ;
- moment de la mise à jour de `previousLapTimeMs`, et ordre entre la remise à zéro de `lapTimeMs` et l'incrément de `lapCount` ;
- comportement du cran FUEL quand le carburant baisse en roulant ;
- valeur de `splinePosition` sans ligne IA.

Le premier tour enregistré par Vincent répondra aux deux premiers : il affichera soit « valide », soit la raison du rejet, avec les valeurs en cause.

## Mutations

Chaque garde-fou du J5 est annulé dans une copie isolée de l'app, et au moins un test doit échouer.

| Mutation | Test qui échoue |
|---|---|
| tour partiel enregistré | R01 |
| invalidation AC, voie des stands, répartition de freinage, trou de couverture, setup changé, tour invalide retenu, mémoire pleine ignorés | R02 |
| abscisse p × longueur | V06 |
| pressions à chaud mesurées ignorées | M07 |
| conditions du tour ignorées | M07 |
| Levenberg–Marquardt absent | V01 |
| facteur en butée utilisable | V08 |
| identifiabilité forcée | V04 |
| perte de Huber absente | V03 |
| facteurs non transmis au calcul de setup | M03 |
| enregistrement en replay | M08 |
| relecture 1 à 7, m5 et m6 (correctifs annulés un à un) | R06, R07, M05, M09 et M03, M09, R09, R10, M08 |
| revue finale : maximum du chrono ignoré ; gain prévu sans les conditions mesurées | R09 ; M03 |
| calibration automatique absente | M01 |
