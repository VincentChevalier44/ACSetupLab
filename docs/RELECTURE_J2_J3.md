# Relecture adversariale — jalons J2, J3 et J4 (§0.4, §18)

Le 19/10/2026, deux relecteurs indépendants ont relu SetupLab, chacun en lecture seule et avec ses propres sondes :

- le premier, le modèle de circuit (J2) ;
- le second, le modèle de voiture et la simulation de tour (J3).

Tous les constats ont été traités. Une campagne de mutations en contrôle les corrections (voir la fin du document).

## J2 — modèle de circuit (13 constats)

| # | Gravité | Constat | Résolution | Test |
|---|---|---|---|---|
| 1 | Majeur | Le dévers du jeu de données était inversé un virage sur deux : la colonne `camber` de `fast_lane.ai` donne le dévers **vers l'intérieur**, pas vers le côté n. T05 vérifiait donc une erreur par une autre (le Karussell sortait relevé vers l'extérieur). | Le sol simulé est incliné vers l'intérieur du virage de référence. T05 compare désormais phi·signe(κ) au dévers de référence, sur Spa et la Nordschleife. Ajout d'une assertion sur le Karussell. | T05 |
| 2 | Majeur | Le sondage du dévers par deux rayons latéraux échouait quand la ligne longe un bord : 9,5 % de points perdus à Spa, pour un seuil de 10 %. Les trous étaient remplis par recopie. | Un seul rayon sur la ligne IA, la normale de surface de `physics.raycastTrack` étant projetée sur la normale horizontale. Les trous sont interpolés en bouclant, et le sondage s'arrête dès que le seuil est dépassé. Résultat : 0 échec à Spa et sur la Nordschleife. | T05 |
| 3 | Majeur | La segmentation dépendait de la position de la ligne d'arrivée : un virage pouvait être coupé en deux, et le nombre de chicanes variait. | La segmentation part du milieu de la plus longue ligne droite ; la droite coupée en deux est réunie. Le test d'invariance tourne la ligne d'arrivée de 8 façons sur 3 circuits. | T07 |
| 4 | Majeur | Trop de virages marqués « chicane » : 12 sur 20 à Spa, dont Eau Rouge et Kemmel. | Une chicane exige deux virages de rayon inférieur à 100 m, de sens opposés, sur 250 m au plus. Spa : seules Les Combes et la Bus Stop sont marquées. Test négatif : un S de 200 m de rayon. | T03, T06 |
| 5 | Mineur | Courbure verticale fausse aux extrémités d'un tracé ouvert (± 1,2 g fictif). | Base symétrique réduite près des bords. Test : rampe à 10 %, κV nulle partout. | T04 |
| 6 | Mineur | Un circuit « fermé » dont la ligne ne se referme pas (drapeau illisible) aurait été refermé par une corde de plusieurs kilomètres. | Au-delà de 25 m de corde, le tracé est traité en ouvert, avec avertissement et confiance abaissée. | T08 |
| 7 | Mineur | D6 : `segment()`, la pente, les bornages et le cumul des abscisses ne rendaient pas la main. Les appels CSP pesaient 1 dans le quota. | Toutes les boucles rendent la main tous les 256 points. Poids `tickWeightApiCall` pour les appels CSP. Écart maximal entre deux rendus inférieur à 1 ms, compilation JIT exclue. | T09 |
| 8 | Mineur | Contrat §7.4 non respecté (`phi`, `surf`, bosses, `ds` automatique). | Ajout de `phi[]`, `surf[]`, `bumps[]` (crêtes et compressions) et `p[]` (progression IA). `ds` automatique jusqu'à 5 m au-delà de 4 000 points. L'enregistreur de reconnaissance est reporté au J5 (A14). | T01, T04 |
| 9 | Mineur | Un seul point sans largeur rendait toutes les largeurs inconnues. | Seuil de 10 % de points manquants ; valeur par défaut point par point. | T08 |
| 10 | Mineur | Correspondance progression ↔ abscisse perdue (zones DRS, références). | `t.p[k]` conservé ; zones DRS converties par dichotomie sur la progression. | T06 |
| 11 | Mineur | Tracé ouvert : la somme des segments valait N·ds au lieu de (N−1)·ds. | Le dernier point ne porte pas d'intervalle. | T01, T03 |
| 12 | Mineur | Une erreur dans `TrackModel.build` faisait échouer toute la découverte. | `pcall` dans la colle ; la raison est affichée. | — |
| 13 | Mineur | Message trompeur quand la géométrie manque. | Raisons distinctes. | T05 |

## J3 — modèle de voiture et simulation de tour (1 bloquant, 6 majeurs, mineurs)

| # | Gravité | Constat | Résolution | Test |
|---|---|---|---|---|
| B1 | Bloquant | AWD : `FRONT_SHARE=35`, écrit en %, était lu comme une fraction (motricité de 0,78 g au lieu de 1,74 g sur `formula_k`). `TYPE=AWD2` tombait sans message dans RWD. | Une valeur supérieure à 1 est divisée par 100. Un type de transmission non modélisé est déclaré manquant, et le calcul est refusé avec sa raison. Le différentiel arrière est lu dans `[AWD]`. | S11 |
| M1 | Majeur | Décollement de roue non traité : la roue extérieure pouvait porter plus que l'essieu, d'où un effet de barre antiroulis non physique (inversions sur la DTM). | Le transfert de chaque essieu est borné à la moitié de sa charge ; l'excédent de moment passe sur l'autre essieu. Au-delà, il y a renversement. | S12 |
| M2 | Majeur | Dents de scie sur les rapports : force motrice tabulée tous les 2 m/s (sauts de 0,28 s pour 0,2 % de pont). | Table continue par rapport, force prise à la vitesse exacte, vitesse de pointe calculée exactement. Ondulation résiduelle de 0,04 s au plus, liée au nombre entier de passages de rapport. | S13 |
| M3 | Majeur | Carrossage : réglage le plus influent, mais orientation de la formule non vérifiée. | Non optimisé au J4 (déjà exclu). Effet borné au sommet de la parabole Kunos. | P01, S08 |
| M4 | Majeur | Ressorts, différentiel et puissance de freinage : effet modélisé sans contrepartie, donc optimum en butée. | Non optimisés au J4, avec leur raison affichée. Barre antiroulis conservée (rayon réduit), car l'équilibre fait contrepoids. | P01, P05 |
| M5 | Majeur | Turbo réglable : `DEFAULT_TURBO_ADJUSTMENT` ignoré (3,8 s par tour sur `formula_k`). | Hypothèse H5 : pression × réglage pour un turbo `COCKPIT_ADJUSTABLE=1`. À confirmer en jeu par `car.turboBoost`. | S11 |
| M6 | Majeur | Hauteurs par défaut hors jeu sous `MIN_HEIGHT` : la GT3 du banc était au bord de la falaise d'appui. | Hauteur par défaut d'au moins `MIN_HEIGHT` + 5 mm. En jeu, la hauteur est mesurée. La hauteur minimale est une contrainte dure de l'optimiseur. | S11 |
| m1 | Mineur | Blocage arrière compté quand le couple de freinage limite seul. | N'est plus compté. | S04 |
| m2 | Mineur | Table de charge normale 0,7–1,3 sans extrapolation, alors que n va de 0,19 à 2,33 à Spa. | Charges 0,4 / 1,0 / 1,6 / 2,2, extrapolation linéaire bornée. | S01, S02 |
| m3 | Mineur | `configure` allouait environ 21 Ko par appel (84 Mo pour 4 000 évaluations). | Tables réutilisées : 0,05 Ko par appel en régime établi. | S09 |
| m4 | Mineur | `BASEY` à l'envers. | Commentaire Kunos : h = R + BASEY. | S11 |
| m5 | Mineur | Vitesse de pointe plafonnée à 104 m/s ; force de freinage ramenée au sol par le seul rayon avant. | Table jusqu'à 106 m/s ; rayon de chaque essieu. | S03 |

## J4 (contrôlé pendant l'intégration)

- **Optimiseur** : la robustesse examinait trois voisins du même optimum. Elle examine désormais des optimums locaux distincts (test O09). La part grossière est calculée sur le budget hors réserve.
- **Interface** : `a and b() or c` masquait le bouton de calcul quand `b()` renvoyait `nil` (test Q04).
- **Carburant de qualification** :
  - consommation du modèle de 0,4 L par tour sur l'URD, soit un risque de panne sèche ;
  - correction : 3 tours, marge de 30 % (modèle) ou de 10 % (mesure CSP), plancher de 3 L ;
  - test : Q03.

## Revue finale (avant livraison)

- La partie « voiture » de la découverte est protégée par `pcall` (Q06). Une voiture chiffrée inattendue ne fait perdre ni la découverte ni le rapport.
- La hauteur de caisse n'est pas optimisée au J4, même mesurée en jeu : le repère d'entrée des LUT aéro de hauteur n'est pas vérifié.
- Durée estimée sous 60 images/s, gain non chiffré pour les réglages en butée, setup vérifié au lancement du calcul, consommation max(CSP, modèle) (Q06, Q07).
- Avec 100 évaluations (le minimum réglable), la réserve consommait tout le budget et la recherche n'avait pas lieu. La réserve est désormais plafonnée à 30 %, et la robustesse est signalée si elle n'est pas couverte (Q08).
- Essai de fumée sur les 11 voitures installées à données ouvertes (Monza) : lecture, modèle, espace de setup, tour simulé, qualification et rendu du fichier, sans aucune erreur.

## Méthode de mesure (A16)

Le banc subit la préemption du système et les pauses du ramasse-miettes, gonflées par le tas des jeux de données. Les tests de durée (A02, T09) retiennent donc la meilleure de trois séries : un défaut de découpage échouerait aux trois. A19 et S09 bornent les déchets produits, la seule part qui dépend de l'app. En jeu, la fenêtre debug compte les tranches de plus de 3 ms.

## Campagne de mutations

Chaque correction a été annulée dans une copie isolée du projet. Le test indiqué dans les tableaux ci-dessus devait alors échouer, alors qu'il passe sur le code corrigé. **25 mutations sur 25 ont été détectées.**

Trois mutations passaient d'abord inaperçues. Les tests concernés ont été renforcés :
- le décollement de roue est désormais testé directement : transfert borné à la moitié de la charge de l'essieu, moment de roulis conservé, renversement (S12) ;
- la simulation utilise bien le carburant de qualification (Q01) ;
- la hauteur minimale réglementaire est contrôlée sur l'essieu avant, qui est l'essieu concerné (S11).
