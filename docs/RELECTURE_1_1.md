# Relectures adversariales — version 1.1.0

Après la 1.0.0, Vincent a pris plusieurs décisions le 20/10/2026 :
- **Budget de calcul (A13) :** 1 200 évaluations en qualification et 400 relais en course.
- **Chargement dans la voiture :** D8 est amendé pour permettre de charger le setup proposé.
- **Après un constat en jeu** (« calcul refusé » en essai et en journée circuit) :
  - une piste qui évolue ne bloque plus le calcul ;
  - un calcul déjà lancé va au bout, et son résultat est signalé ;
  - un setup modifié ou une nouvelle séance relance la découverte toute seule (A30).

Deux relecteurs indépendants ont relu ces changements en lecture seule, avec leurs propres sondes. Tous les constats sont traités ou consignés.

## 1. Chargement dans la voiture (D8 amendé)

| # | Gravité | Constat | Résolution | Test |
|---|---|---|---|---|
| 1 | Majeur | Constat sans preuve : sans état relevé avant l'appel, un setup déjà identique au fichier donnait « chargé et vérifié » et « disponible ». Le carburant n'entrait pas dans la signature comparée. | État relevé avant l'appel. Constat section par section, carburant et composé compris, contre `ac.stringifyCurrentSetup(true, false)` ; « non concluant » si rien n'a changé, et la capacité n'est pas promue. | J06, J04 (écart sur FUEL seul) |
| 2 | Mineur | La garde `fixedSetup` laissait passer un état illisible. | `fixedSetup` doit être lisible et faux, dans la colle comme dans l'exporteur. | J02, J03 |
| 3 | Mineur | Le mode inerte n'était vu qu'à 1 Hz, et pas du tout avec « Application active » décochée. | Drapeaux en ligne et replay lus à chaque image ; application active exigée. | J02 |
| 4 | Mineur | Sans horloge précise, fenêtre masquée, l'armement ne périmait jamais. | Échéance de repli sur le temps de jeu. | J02 |
| 5 | Mineur | Un double-clic valait confirmation. | Délai minimal de 0,5 s ; bouton de confirmation placé sous l'avertissement. | J01 |
| 6 | Mineur | Un second chargement pendant la vérification écrasait le constat du premier. | Refus tant qu'une vérification est en cours. | J04 |
| 7 | Mineur | Capacité J0 mal tenue : les refus de garde écrasaient le dernier essai, une copie ratée n'était pas consignée. | `loadTest` réservé aux issues de `ac.loadSetup`. Dernier chargement vérifié gardé à part. Copie ratée consignée dans le test d'écriture. | J03, J06 |
| 8 | Mineur | Messages inexacts : pas de raison au désarmement, délai non annoncé, mot « écart » absent. | Raison donnée au désarmement, délai annoncé, « écart » dans la raison et le message. | J02, J04 |
| 9 | Mineur | Linter : `ac.resetSetupToDefault`, `ac.setPitstopSpinnerValue`, `physics.setTyresCompound` et `physics.setCarFuel` non interdits ; `caps.lua` exempté. | Les quatre fonctions sont interdites partout (auto-tests). Filet d'exécution du banc : l'hôte simulé lève une erreur si `ac.loadSetup` n'est pas appelée par l'exporteur. L'exemption de `caps.lua` (registre) est consignée dans API_NOTES. | J07, auto-tests du linter |
| 10 | Mineur | Tests complaisants : arguments de `stringifyCurrentSetup` ignorés, F05 sans aucun chargement. | L'hôte respecte `modifiedOnly`. J01 modifie un cran sans l'enregistrer. F05 suit une séquence forcée, avec un journal ordonné : chaque chargement suit immédiatement sa copie de sauvegarde. | J01, F05 |
| 11 | Mineur | État de chargement conservé après un changement de voiture. | Remise à zéro au changement de voiture ou de circuit. | — |
| 12 | Cosmétique | `3.6` et `200` écrits en dur. | Convention existante du code, conservée. | — |

**Trous révélés par les mutations, comblés :**
- un nom au bon préfixe qui sort du dossier (`SetupLab_Quali_x/autre.ini`) ;
- les secondes défenses de l'exporteur (menu de setup fermé, setup imposé) ;
- l'outil de mutation ignorait les échecs des auto-tests du linter : il lit désormais aussi le code de sortie du banc.

## 2. Conditions de piste, nouvelle séance, calcul en attente, origine de la validation

Aucun bloquant. Le constat de Vincent est réglé : aucune sonde ne montre de refus quand la piste évolue.

| # | Gravité | Constat | Résolution | Test |
|---|---|---|---|---|
| 1 | Majeur | Photo partielle : conditions prises au clic, espace optimisable lu au démarrage de la tâche. Un calcul en attente derrière un autre pouvait optimiser la suspension avec une rugosité nulle (garde-fou A23). | Tout l'état du calcul est pris au même instant, au démarrage de la tâche : conditions, rugosité et espace, facteurs, pneus, mesures de course, copie des réglages. Aucune autre tâche ne tourne ensuite avant sa fin. | Z01 |
| 2 | Majeur | Banc rouge : D13 et M10 décrivaient encore l'ancien comportement. | D13 vérifie la nouvelle clé de séance. M10 attend la relance, puis annule le calcul en attente. | D13, M10 |
| 3 | Majeur | Une nouvelle séance effaçait le résultat et, avec lui, le setup enregistré : le bouton « Charger » disparaissait. | Dernier enregistrement gardé par genre (fichier, texte, signature, voiture), chargeable après une nouvelle séance ; un chargement armé est désarmé au changement de séance. | Z10 |
| 4 | Majeur | Une seule place d'attente : deux demandes pendant une découverte, la première perdue. | Attente par genre ; les deux calculs sont lancés à la fin de la découverte. | Z02 |
| 5 | Majeur | Après l'enregistrement d'un nouveau setup proposé, le verdict de validation du précédent restait affiché. | Validation annulée et effacée quand le setup proposé ou son origine change. | Z05 |
| 6 | Majeur | Tests incapables de voir une relance en boucle : le mutant du relecteur survivait. | A17 et Q13 relisent le contexte quatre fois après la découverte. Le mutant est détecté. | A17, Q13 |
| 7 | Mineur | Calcul en cours effacé sans le dire ; changement de séance silencieux. | Le message nomme les calculs interrompus et les résultats effacés. Une nouvelle séance est annoncée. | Z03, A17 |
| 8 | Mineur | Validation ou mesure seule annulée restée « en cours ». | État final posé (annulée ou interrompue). | Z04 |
| 9 | Mineur | Calibration stockée avec la température de la découverte, et non celle des tours. | Moyenne des conditions des tours calibrés. | Z06 |
| 10 | Mineur | Seuil sans tolérance : un point d'adhérence exact n'était pas signalé en simple précision. | Tolérance `K.conditionsEps`. | Z07, A17 |
| 11 | Mineur | Conditions revenues après un changement pendant le calcul : le texte appelait à recalculer. | Texte distinct : « conditions changées pendant le calcul, revenues depuis : résultat valable ». | A17 |
| 12 | Mineur | Pluie dans la clé de séance, sans hystérésis : redécouverte en boucle au seuil. | Pluie retirée de la clé ; le calcul la refuse à part (D16). | Z09, D13 |
| 13 | Mineur | Composante de séance illisible : deux redécouvertes. | Pas de clé si la séance est illisible ; la dernière lue reste la référence. | D13 |
| 14 | Mineur | Une seule relecture sans voiture ni circuit identifiés rendait l'app inerte et annulait le calcul. | Deux relectures d'affilée exigées pour l'identité ; immédiat pour les drapeaux en ligne et replay. | Z08 |
| 15 | Mineur | Couverture : M13 en double ; A17 limité à la piste ; M14 aveugle au texte « Calcul indisponible ». | M13 et M14 renumérotés M15 et M16. A17 couvre l'air, l'adhérence, les textes et les unités. M16 relève aussi les refus affichés. Les sondes sont devenues les tests Z01 à Z10. | — |
| 16 | Mineur | Commentaire « au-delà » contraire au code (`>=`) ; ligne du CHANGELOG annonçant un correctif inexistant. | Commentaire corrigé ; ligne retirée. | — |

**Limites connues de l'hôte simulé :**
- valeurs en double précision ;
- aucun trafic IA simulé (`carsCount` sans effet) ;
- application immédiate de `ac.loadSetup`.

Le premier essai en jeu dira ce qu'il en est.

## Mesures du banc corrigées (banc complet du 20/10/2026)

- **S09, allocations de `configure`.** Un échec rare (1,67 Ko par appel) venait des traces compilées par le JIT, qui sont des objets du tas. Sans JIT, `configure` n'alloue rien en régime établi. Le test mesure désormais dans l'interpréteur, ce qui reflète le code et non les choix du compilateur. Le JIT ne fait qu'éliminer des allocations.
- **Endurance, croissance mémoire.** Les relevés variaient de 284 à 591 Kio. Deux causes, aucune fuite :
  - le cran du setup changeait à chaque image au lieu d'une fois par tour, si bien que la mesure ne comparait plus des nombres égaux de tours conservés ;
  - les traces du JIT étaient comptées dans le tas.

  Désormais, le cran change une fois par tour et le cache du JIT est vidé avant chaque relevé. Mesures : 0,16 Kio sur les tours, moins de 1 Kio par phase de calculs, 35 à 48 Kio pour 1 000 découvertes. Les bornes sont resserrées de 512 et 2 048 Kio à 64 Kio, et à 256 Kio pour les découvertes.

## Budget (A13), mesures à 1 200 / 400

Monza, durée brute puis ramenée au calme. Le gain est comparé à celui obtenu avec 2 500 / 450.

| Cas | Passe 1 | Gain qualification | Gain course |
|---|---|---|---|
| Huracán | 46 s / 35 s | −0,020 s | identique |
| URD avec ERS | 64 s / 47 s | −0,067 s | +0,008 s/tour |
| DTM, pire cas | 65 s / 56 s | identique | −0,017 s/tour |
| Nordschleife (hors §14.3) | 159 s / 131 s | −0,45 s | −1,14 s/tour |

Passe 2, banc complet final (253 tests sur 253, durée brute puis ramenée au calme) :

| Cas | Durée |
|---|---|
| Huracán | 48 s / 42 s |
| URD avec ERS | 63 s / 56 s |
| DTM, pire cas | 73 s / 67 s |
| Nordschleife | 147 s / 133 s |

Les gains sont identiques à la passe 1, puisque le calcul est déterministe.

## Campagnes de mutations (1.1.0)

| Domaine | Détectées |
|---|---|
| Chargement : gardes, confirmation, copie, relecture, constat, linter | 20 / 21 (1 équivalente) |
| Conditions, relance, calcul en attente, origine, corrections de la relecture du chargement | 27 / 28 (1 équivalente) |
| Corrections de la relecture des conditions (dont le mutant de relance en boucle du relecteur) | 16 / 16 (deux trous comblés : Z10 arme le chargement après la nouvelle séance, M06 interrompt une estimation) |
| Onglets par usage, découverte en échec (bouton de relance dans les deux onglets), matrice des types de séance (I12) | 6 / 6 |

**Les deux mutations équivalentes :**
- **Confirmation sans armement du même genre :** le chemin du fichier suffit à distinguer les genres.
- **Mode inerte qui garderait le calcul en attente :** l'attente est vidée avant tout lancement, et un lancement en mode inerte est refusé.
