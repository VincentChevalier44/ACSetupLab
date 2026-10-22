# Relecture adversariale — jalon J6b (§0.4, §18)

Le 20/10/2026, un relecteur indépendant a relu en lecture seule, avec ses propres sondes, la première partie du J6b :
- le DRS ;
- la couverture de tous les réglages du setup ;
- les pressions et la surchauffe ;
- la suspension ;
- la hauteur de caisse.

L'ERS, terminé pendant la relecture, a sa propre campagne de mutations (14 sur 14).

Tous les constats sont traités ou documentés. Des campagnes de mutations contrôlent les corrections (voir la fin du document).

## Constats

| # | Gravité | Constat | Résolution | Test |
|---|---|---|---|---|
| B1 | Bloquant | Le choix automatique du composé contournait le garde-fou de surchauffe : Medium monté à 100 °C (dans sa fenêtre), le Soft (fenêtre 60–95 °C) était retenu, comparé au plateau de sa courbe (A19). Pression arrière abaissée ; bilan affiché contre la fenêtre du Soft mais avec l'état du Medium, sans avertissement. | Un composé non monté dont la fenêtre exclut la température mesurée (pneus en température) est **écarté**, avec la raison. Composé imposé hors de sa fenêtre : gardé, signalé. Composé monté en surchauffe : un composé sec dont la fenêtre contient la mesure est proposé à l'essai. **Bornes de pression recalculées pour le composé retenu** (garde-fou de surchauffe, bande autour de son idéale), en qualification comme en course. Bilan des pneus contre la fenêtre du composé retenu. | W05 |
| M1 | Majeur | H16 (`PACKER_RANGE` compté depuis l'assiette statique) douteuse : l'écrasement statique fait 45 à 55 % de la course ; sous H16, butées et course avant butée n'ont aucun effet modélisé mais s'affichaient « optimisé ». | **Butées et course avant butée conservées** (raison : H16 à confirmer) ; course de suspension au repos (`wheels[n].suspensionTravel`) relevée dans le rapport J0 pour trancher. Raison du pilonnage corrigée. | X07 |
| M2 | Majeur | Budget du §14.3 dépassé dans le pire cas (DTM, DRS, rugosité, hauteur : 98 à 118 s). B01 ne couvrait que le cas facile. | Coût de la construction du modèle divisé par deux. **Arrêt de la recherche au temps** de calcul mesuré (durées visées 40 s et 45 s). Nouveaux tests B03 (pire cas) et B02 (ERS). Détail plus bas. | B01–B03, O10, S14, S15 |
| M3 | Majeur | Hauteur de caisse : `MIN_HEIGHT` contrôlée sur une hauteur statique qui ignorait le carburant et la pression ; « sans objet » libérait la hauteur sans mesure au stand. | Hauteur statique corrigée de l'écrasement au repos (masse avec carburant, ressorts, pneu à sa pression à froid). Marge de 1 mm. Setup refusé s'il passe sous la limite en étant plus bas que l'actuel au même carburant. Le setup actuel n'est jamais refusé ; avertissement s'il passe sous `MIN_HEIGHT` avec le carburant prévu. Hauteur de référence mesurée au stand dans tous les cas, repère non repris d'une séance précédente. | H04, H03 |
| m1 | Mineur | Calibration : une seule ouverture du DRS suffit à simuler le tour avec le DRS dans toutes les zones. | **Reporté** : l'état du volet par zone est déjà relevé par l'enregistreur ; la calibration par zone attend des tours réels (§8.9). | — |
| m2 | Mineur | ABS : mode lu à la découverte seulement ; repli sur `PRESENT` sans `ACTIVE`. | `absMode` relu au lancement du calcul ; repli sur l'aide de réalisme, puis `PRESENT` et `ACTIVE` ; « ABS coupé » affiché. | I06 |
| m3 | Mineur | Moyenne gauche / droite sans contrôle : une roue aberrante désancrait ou faussait l'essieu. | Écart de plus de 2 psi ou de 15 °C : essieu non ancré, raison. Surchauffe jugée sur la roue la plus chaude. | W06 |
| m4 | Mineur | Rugosité : aucune borne sur G0 ; fenêtres de ligne droite à cheval sur un passage de rapport ; `LS_EXPY` > 1 faisait de la rugosité un gain d'adhérence. | G0 au-delà de la classe C de l'ISO 8608 : non plausible. Fenêtre recommencée à chaque passage de rapport. Facteur borné à 1. | X10 |
| m5 | Mineur | Cycle de vie de la rugosité : réglages laissés libérés après un tour incohérent ; G0 remplacé sans moyenne ; rugosité perdue à une nouvelle découverte. | **En partie** : rugosité conservée d'une séance à l'autre et reprise à la découverte (§13). La moyenne sur plusieurs tours reste à faire, après des tours réels. | I02 (persistance) |
| m6 | Mineur | Affichage : bornes de pression annoncées au lieu des bornes réelles ; butées « optimisé » ; repère « corrigé » présenté comme disponible. | Pressions et carrossage : « restreinte au lancement du calcul », avec la règle. Butées conservées (M1). Repère corrigé : capacité « à confirmer ». | H03, X07 |
| m7 | Mineur | Documentation trop affirmative : A13 « ≈ 72 s », A23 « optimum intérieur », A24 « jamais dégonflées », A26 « butée acceptée si… ». | A13, A23, A24, A25, A26 et H16 amendés (voir `API_NOTES.md`). | — |
| m8 | Mineur | Durée estimée sous-estimée d'un facteur 1,5 à 2 (mesurée sans DRS ni rugosité). | Coût d'une évaluation avec le DRS mesuré à la découverte ; durée affichée à la fréquence d'images et à la tranche réelles, en orange au-delà de la durée indicative. | Q07 |
| m9 | Mineur | Défauts latents : carrossage à `SHOW_CLICKS=2` converti à 1° par cran au lieu de 0,1° ; `ROD_LENGTH_H[FR]` groupé avec les tiges de coin. | Carrossage corrigé. Groupement des tiges de pilonnage **noté** : juste quand le ressort de pilonnage est seul sur l'essieu, ce qui est le cas des voitures connues. | P03 |

## Constats du J8 sur ces corrections

**Calibration V03.** Le test affirmait qu'un long virage raté (−25 % sur 300 m) ne mettait jamais l'appui en butée, grâce à la perte de Huber. C'était faux.
- L'appui restait à 1,000 seulement à cause de la quantification de l'ancienne dichotomie latérale : pas de 0,0012 m/s², qui figeait ce facteur.
- Avec une résolution fine (24 ou 32 pas de dichotomie, ou le nouveau solveur), l'appui part en butée (1,300).
- La calibration se déclare alors **inutilisable**, raison affichée : aucune fausse confiance (§16.7). Le test vérifie désormais cette propriété.

## Budget (§14.3)

**Coût.** La construction du modèle passe de 2,0 à 1,0 ms avec DRS sur le DTM, et de 1,1 à 0,5 ms sans. Deux changements :
- Accélération latérale maximale résolue par fausse position (variante d'Illinois) avec départ voisin, à la place d'une dichotomie à 16 pas. Elle est plus précise (0,0005 m/s² contre 0,0012 m/s²) et le résultat est toujours tenable (S14).
- Tables d'adhérence calculées jusqu'à la plus haute vitesse que la simulation peut atteindre (vitesse de pointe, volet ouvert compris) au lieu de 106 m/s pour toutes les voitures. Le résultat est identique sur toutes les vitesses atteintes (S15). Les temps au tour bougent de 1,3 ms au plus.

**Ni arrêt au temps ni budget ramené.** Les deux ont été essayés, puis retirés après la relecture J8 :
- un arrêt pendant la phase grossière sautait le raffinement et proposait le setup actuel ;
- le temps de préparation comptait deux fois et pouvait faire planter le calcul ;
- toute décision prise sur une horloge rend le résultat dépendant de la charge de la machine, contre le §10.5 (graine fixe, reproductible).

Le budget est le budget réglé ; la durée estimée s'affiche sans plafond.

**Mesures** (Monza, valeurs par défaut, ramenées au calme) :

| Cas | Total |
|---|---|
| B01 : Huracán, 19 réglages | ≈ 61 à 67 s |
| B02 : URD avec ERS | ≈ 71 à 89 s, à la limite |
| B03 : DTM, 26 réglages, DRS, rugosité, hauteur | ≈ 77 à 86 s |
| B04 : URD avec ERS, Nordschleife (20,8 km, hors du §14.3) | ≈ 175 à 178 s |

**Qualité selon le budget** (sonde) :

| Voiture | Qualification | Course |
|---|---|---|
| DTM | gain identique de 1 200 à 2 500 évaluations | 250 relais : −0,07 s/tour ; 350 : −0,02 s/tour ; 400 : −0,016 s/tour ; référence 450 |
| Huracán | 1 200 évaluations : −0,02 s | 250 relais : −0,12 s/tour ; 350 : −0,04 s/tour ; 400 : identique |

**À valider par Vincent (A13) :** garder 2 500 / 450, ou passer la course à 400 relais pour donner de la marge à l'URD avec ERS (mesuré : −0,016 s/tour sur le DTM, sans effet sur la Huracán).

## Campagnes de mutations

| Domaine | Détectées |
|---|---|
| DRS | 13 / 13 |
| Couverture du setup | 20 / 20 |
| ERS | 14 / 14 |
| Corrections B1 (composé, bornes de pression) | 6 / 6 |
| Corrections M1, M3, mineurs, persistance et interface (J7) | 24 / 24 |
| Résolution latérale et tables jusqu'à la vitesse atteinte | 4 / 4 |
| Arrêt au temps (retiré ensuite, voir Budget) | 5 / 5 |

## Points vérifiés sans défaut par le relecteur
- H20 : bras de levier du différentiel, optimum intérieur ; quart de véhicule (fonction de transfert, densité spectrale, unités) ; facteurs des crans de suspension sur les quatre voitures ; sens du garde-fou de carrossage.
- Pression sur le composé monté : la surchauffe donne bien `lo ≥ 0`, préservé par la bande.
- H15 : risque de blocage nul avec ABS, `absMode = 0` = ABS coupé.
- DRS :
  - zones bouclées sur la ligne ;
  - volet ouvert en accélération seulement ;
  - `LIMIT_G` appliqué ;
  - `drsReport` complet ;
  - DRS en course sur le tour en trafic seulement.
- `configure` sans allocation avec DRS et rugosité ; rendus de main sous 0,8 ms à Spa et sur la Nordschleife.
- Tâches découpées : la rugosité est mesurée dans une tâche ; un calcul en cours n'est pas perturbé par une libération.
- D8 inchangé.
