# Relecture adversariale — jalon J6 (§0.4, §18)

Le 20/10/2026, un relecteur indépendant a relu le J6 en lecture seule, avec ses propres sondes : correction du composé de pneus, simulation de relais, optimisation course, données de séance. Le conseiller avait relu la conception avant le code.

Tous les constats sont traités. Une campagne de mutations contrôle les corrections (voir la fin du document).

## Constats

| # | Gravité | Constat | Résolution | Test |
|---|---|---|---|---|
| B1 | Bloquant | Le relais échantillonné ignorait le dernier point de WEAR_CURVE et arrondissait chaque cassure à un tour. Sur les vraies courbes de la Huracán : jusqu'à 1 s/tour d'écart au relais exact, toujours optimiste ; choix du composé inversé dans 8 cas sur 21 ; résultat course possible **plus lent que l'actuel** (+0,48 s/tour). | Le niveau d'usure de chaque essieu à chaque tour est connu d'avance (km du plan, WEAR_CURVE) : le temps au tour est **ajusté** par moindres carrés en fonction du carburant et de ces niveaux sur 5 tours simulés, puis sommé sur les N tours. Écart maximal mesuré : 0,03 s/tour sur les vraies courbes (contre 0,53 s pour un échantillonnage par cassures). Le **composé est choisi sur le relais exact**. **Contrôle final** : si le relais exact du setup proposé n'est pas meilleur que celui de l'actuel, le setup actuel est conservé (carburant de course seulement), avec la raison. | L02, L03, L09 |
| B2 | Bloquant (conditionnel) | Sans consommation connue (pas de `CONSUMPTION`, CSP à 0 au stand), le carburant de course tombait au minimum du cran : 62 → 5 L écrits dans le fichier. Un taux de session lu à 0 avait le même effet. | Consommation inconnue : carburant actuel conservé, raison affichée. Consommation du modèle seule : jamais sous le carburant actuel. Taux de consommation de la session : ne réduit jamais la consommation (échelle non confirmée). | L05 |
| M1 | Majeur | Course à la durée : tours comptés sur le tour du modèle non calibré (trop lent : panne sèche possible). | Tour prévu = le plus court du meilleur tour mesuré et du tour simulé avec les facteurs calibrés. | L04, M11 |
| M2 | Majeur | Sans cran FUEL réglable : relais calculé sur le réservoir plein alors que la voiture part avec le carburant actuel (à sec au tour 10 sur 30, tours suivants simulés à vide). | Relais limité par le carburant actuel ; « carburant non réglable dans le setup : X L nécessaires ». | L06 |
| M3 | Majeur | Composé changé (et `[TYRES]` écrit) sur une usure par défaut non confirmée (1 km virtuel par km). | Sans km virtuels mesurés, le composé monté est gardé ; le comparatif reste affiché à titre indicatif. | L09 |
| M4 | Majeur | Échelle de `fuelConsumptionRate` non confirmée (SDK : « 0…1 ») : risque de diviser la consommation. | Le taux ne réduit jamais la consommation (`max(1, taux)`) tant que l'échelle n'est pas confirmée en jeu (rapport J0). | L05 |
| M5 | Majeur | Index du composé illisible : erreur à chaque tour valide (`app.calibrations[nil]`), calcul non bloqué. | Clé −1 ; calcul bloqué (« composé monté illisible »). | M12 |
| M6 | Majeur | Pneus pluie montés, ou composé pluie imposé : calcul accepté (D16). | Pneus pluie montés : calcul bloqué. Composé pluie imposé : refusé, choix automatique, raison affichée. | M12, Q10 |
| M7 | Majeur | Le test du trafic passait par égalité ; la note H7 annonçait un effet « vérifié ». | P_trafic gagne le terme de **stabilité au freinage dans l'air sale** demandé par le §10.2 (aggravation du blocage de l'arrière). Test discriminant sur ce terme. Note H7 corrigée : le trafic favorise l'aileron dans P_trafic, mais l'optimum bouge peu (≈ 0,05 s sur ±4 crans). | L07 |
| m1 | Mineur | Pénalités évaluées en début de relais (tour « du milieu » mal choisi). | Le vrai tour du milieu est toujours simulé. | L01 |
| m2 | Mineur | Consommation CSP lue à la découverte, souvent 0 au stand. | Relue au lancement du calcul. | — |
| m3 | Mineur | Source « mesure » affichée quand le plancher CSP l'emporte. | « CSP (plancher) ». | L05 |
| m4 | Mineur | Tours et durée de séance non bornés (D11). | Bornés à 500 tours et 24 h. | L04 |
| m5 | Mineur | Temps actuel calculé avec les facteurs du composé retenu. | Comparaisons (composés, actuel et proposé, contrôle final) avec un **même jeu de facteurs** : la calibration du composé monté. Un composé non calibré ne paraît plus meilleur du seul fait que la calibration réduit l'adhérence. | Q10 |
| m6 | Mineur | Travail hors budget non signalé (comparaison des composés, relais exacts). | Phases « composés » et « relais exacts » affichées dans la progression. | — |
| m7 | Mineur | Composé de qualification comparé au carburant actuel. | Règle de carburant d'abord, puis comparaison des composés. | — |
| m8 | Mineur | Consommations aberrantes non bornées. | Bornée à 30 L/tour. | — |
| m9 | Mineur | Identifiants de tests en double (C01–C04, K01). | Suite du relais renommée L01–L10, budget B01. | — |

Points vérifiés sans défaut par le relecteur :
- interpolation, somme sur N tours, comparabilité actuel / proposé ;
- priorités de consommation, réservoir et arrêts ;
- usure par essieu, mesure de l'usure sans changement de pneus ;
- correspondance index CSP / position, signature, refus des changements de composé, `[TYRES]` seulement s'il change ;
- calibration par composé, validation avec composé changé ;
- rendus de main partout ; D8 respecté.

## Budget (§14.3)

Qualification (4 000) et course (600 relais, 5 tours simulés par relais) : **≈ 81 s réelles** à Monza, sous les 90 s.

## Mutations

Chaque garde-fou du J6 est annulé dans une copie isolée de l'app, et au moins un test doit échouer : **22 sur 22 détectées**.

| Mutation | Test qui échoue |
|---|---|
| composé retrouvé par sa position | Q09 |
| pneus pluie comparés et choisissables ; pluie imposée acceptée ; temps actuel avec le composé retenu | Q10 |
| composé changé sans usure mesurée ; contrôle final absent | L09 |
| carburant sous la valeur CSP ; réduit sans mesure ; réservoir ignoré ; taux de consommation ignoré | L05 |
| carburant actuel ignoré sans cran FUEL | L06 |
| séance de course non filtrée ; tours de séance non bornés | L04 |
| ajustement carburant et usure absent | L02, L03 |
| stabilité au freinage dans le trafic absente | L07 |
| usure par essieu ignorée | L10 |
| changement de pneus mesuré comme usure | R11 |
| signature sans composé | Q09 |
| changement de composé non détecté ; `[TYRES]` non écrit | M10 |
| composé illisible non bloqué ; pneus pluie montés non bloqués | M12 |

La clé −1 des calibrations quand le composé est illisible est une défense redondante : le filtre des tours retenus écarte déjà ce cas (mutation sans effet observable, retirée de la campagne).
