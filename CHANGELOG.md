# Journal des versions

## 1.0.0-beta.1.4 — 22/10/2026 — bêta 1.4 : analyse jusqu'au retour au stand

Demande de Vincent : « qu'il donne juste un message en disant j'ai le minimum d'informations et tant que l'utilisateur n'est pas retourné dans les stands, on continue d'analyser les données. Ce qui donnera plus de pertinence ».
- **En piste**, une version proposée reste provisoire : une seule annonce par version, « vN en préparation » (« J'ai le minimum d'informations ; je continue d'analyser vos tours »), puis chaque tour propre la recalcule sans nouvelle annonce.
- **Au stand** (ou dans la voie des stands), elle est annoncée prête, « vN prêt », avec le nombre de tours propres analysés. Un calcul en cours à l'entrée au stand est annoncé à sa fin. Recalculée en piste et changée depuis : annoncée de nouveau au stand suivant ; même setup recalculé : elle reste prête, sans nouvelle annonce.
- Carte d'affinage, ligne d'état de « SetupLab actif » et overlay : « en préparation (provisoire), N tours analysés, prête au retour au stand ». « Valider » reste possible à tout moment.
- **Tests** : AU13 (v1 validée et chargée, v2 en préparation en piste, mise à jour silencieuse, prête au stand, deuxième passage).

## 1.0.0-beta.1.3 — 22/10/2026 — bêta 1.3 : overlay en jeu

Demande de Vincent : « un petit overlay qui va permettre d'avoir une petite synthèse des réglages qui ont été changés, de voir directement s'il y a un gain ou s'il y a une perte au niveau de chaque réglage », « si le setup est mieux ou moins bien ». Ses réponses : overlay compact ; gain prévu chiffré par réglage.
- **Fenêtre « SetupLab Overlay »** (`[WINDOW_2]`, `FLAGS=MAIN,NO_BACKGROUND,FADING`, comme la fenêtre de drapeaux d'ACAdvancedIA vue en jeu) avec un fond translucide dessiné par l'app : le setup de SetupLab en piste (version roulée de l'affinage, sinon référence de la mémoire chargée), le verdict sur vos tours (meilleur tour en qualification, moyenne en course, avec et avant : « Mieux de … » en vert, « Moins bien de … » en rouge, flèche de CSP), le dernier tour, les quatre réglages changés au plus grand gain prévu (ancienne › nouvelle valeur, gain prévu signé, « ? » en limite de plage), les autres sur une ligne, et la version suivante prête.
- Le verdict est réel (setup entier) ; le gain par réglage est celui du modèle, dit dans l'overlay et la notice.
- **Tests** : OV01, OV02.

## 1.0.0-beta.1.2 — 22/10/2026 — bêta 1.2 : compatible avec la CSP gratuite (0.2.11)

Demande de Vincent : l'app doit fonctionner avec la version gratuite de Custom Shaders Patch, pas seulement avec la preview payante.
- **CSP 0.2.11** (version publique recommandée, installée par Content Manager) : son SDK Lua, comparé fonction par fonction à celui de la 0.3.0-preview675, ne contient pas `io.available`, `ac.getAssists` ni `ac.getSetupTabs` (ni le champ `isTrackOpen`). Sans `io.available`, l'app refusait d'écrire tout fichier (ni « Valider », ni chargement possible) : désormais, quand la fonction est absente, l'écriture est tentée et le fichier relu fait foi ; une fonction présente qui répond « non » ou échoue bloque toujours l'écriture. Les trois autres manques étaient déjà sans effet bloquant (aides du jeu et onglets masqués non lus).
- **Prérequis** : « CSP 0.2.11 ou plus récent » dans le README et la notice.
- **Installation** : l'archive contient le dossier `SetupLab/` ; la bêta 1 disait de la décompresser dans `apps/lua/SetupLab/`, ce qui donnait `SetupLab/SetupLab/` et une app introuvable. Il faut la décompresser dans `apps/lua/` (README, notice).
- **Tests** : AU12 (CSP 0.2.11 simulée : découverte, calcul, Valider, chargement).

Demande de Vincent (« il faut qu'il ne reste que les fichiers V1, V2, V3, pas les intermédiaires » ; « on a du mal à les différencier » ; « en plus du nom, le meilleur temps réel qui a été effectué avec ce setup », qualification seulement). Ses réponses : noms « Qualif / Course », copies « seulement si utiles », « Recommencer » met le fichier à la Corbeille, le tout dans la bêta 1.2.
- **Noms** : `<nom ou SetupLab>_<Qualif|Course>[_Pluie]_vN.ini` (le genre n'est pas répété si le nom choisi finit par lui) ; enregistrement à la main `…_Qualif_<date>.ini`. Numéros de version continus sur le circuit : le plus grand `_vN` du genre déjà dans le dossier (`io.scanDir`), plus de `_v1-2`.
- **Meilleur tour dans le nom** (qualification) : une version gardée (validée, référence de la mémoire) est renommée `…_v2_1.41.792.ini` quand votre meilleur tour réel avec elle (famille de setup, même état de piste) bat le temps de son nom ; versions, mémoire du circuit (stockée), setup à charger et setup chargé suivent le nouveau nom.
- **Copies « Avant chargement »** : plus de copie quand la voiture a déjà un setup gardé de SetupLab, intact (hors carburant, répartition de freinage et aides) ; à chaque validation, les copies du lancement identiques à un fichier gardé partent à la Corbeille, celles qui contiennent autre chose restent.
- **Recommencer** : le fichier de la version, écrit à sa validation, part à la Corbeille (un fichier enregistré à la main reste).
- **Sûreté** : seulement des fichiers écrits par SetupLab pendant ce lancement, intacts (empreinte), jamais un fichier gardé ni le setup à charger, gardes revérifiées au moment d'agir ; un fichier par image, voiture arrêtée, aucun chargement armé ou en cours (jamais d'à-coup en roulant) ; `io.recycle` et `io.move` seulement dans `exporter.lua` (linter) ; suppression définitive (`io.deleteFile`) jamais. Avant CSP 0.3, `io.recycle` supprime définitivement (SDK).
- **Renommé puis AC quitté** avant que CSP n'écrive le stockage (quelques secondes) : à la visite suivante, la mémoire du circuit retrouve le fichier par son nom sans temps au tour et l'empreinte de son contenu, puis le stocke sous son nouveau nom (relecture du 22/10/2026).
- Limite connue : une répartition de freinage changée au stand n'est pas gardée dans une copie « Avant chargement » (réglage changé en roulant, ignoré comme le carburant) ; elle est gardée comme retouche par les calculs suivants.
- **Tests** : RG01 à RG07 (noms, numérotation, meilleur tour, copies, sûreté, `io.recycle` absente, renommage puis AC quitté) ; AU02, AU05, AU06, Q14, PL02 et F05 suivent les nouveaux noms et la Corbeille.

## 1.0.0-beta.1 — 22/10/2026 — première bêta publique (v1.0, bêta 1)

Première version publiée sur GitHub (décision de Vincent : « on la présentera comme la version bêta numéro un, v1.0 »). Elle reprend tout le développement interne ci-dessous (versions 0.1.0 à 1.7.0), dont :
- setups de **tour rapide** et de **course** calculés et expliqués réglage par réglage, modèle calibré sur vos tours ;
- **affinage pendant que vous roulez** : case « SetupLab actif », versions proposées et annoncées à l'écran, **Valider** (enregistre), **Charger** au stand en deux clics, **Recommencer (ne pas garder)**, **Figer (cadenas)** ; rien n'est enregistré sans votre validation ;
- **vos temps** (meilleur tour, moyenne, objectif estimé, gain réel) et **vos retouches** au stand gardées ;
- **mémoire du circuit** par séance et état de piste ; **pluie** (CSP, Pure) ; nom de setup au choix.

Nouveau dans cette version :
- **Notice d'utilisation** au format HTML5 : `docs/notice.html`, aussi dans l'archive.
- **Dépôt public** : les jeux de données des tests (voitures et circuits du jeu, de Kunos et de mods) et les bibliothèques Python du banc ne sont pas publiés ; `tests/run_tests.py` dit comment générer les jeux de données (`tests/tools/make_fixtures.py`, qui ignore désormais une voiture ou un circuit absent), le README comment installer `lupa` et `luaparser`.
- `tests/package.py` accepte un numéro de pré-version (`1.0.0-beta.1`) et les pages HTML de `docs/`.

## Historique de développement (versions internes, avant la bêta publique)

### Interne 1.7.0 — 22/10/2026 — « Recommencer » ; vos retouches au stand gardées (demandes de Vincent)
- **« Recommencer (ne pas garder vN) »** remplace « Écarter vN » (demande de Vincent : « plus parlant pour les gens… ne pas conserver cette version, ne pas la réutiliser… on aura un bouton recommencer et un bouton valider »). Même effet : la version n'est ni gardée ni réutilisée, jamais reproposée ; SetupLab repart de votre setup actuel et propose autre chose avec vos prochains tours ; validée puis essayée, la référence d'avant revient (son fichier reste). Historique : « non gardée ».
- **Vos retouches au stand gardées** (demande de Vincent : « s'il a calculé un setup, que je l'ai chargé et que je reviens dans les stands et que je modifie un petit peu le setup, il faut qu'il le prenne en compte… c'est que je suis plus à l'aise pour conduire ») : après un chargement par SetupLab, tout réglage que vous modifiez à la main (répartition de freinage comprise, carburant exclu) est relevé à la découverte suivante et **gardé à votre valeur** par les calculs suivants (affinage et calcul à la main) ; un composé changé à la main est gardé aussi (en choix automatique). Ligne « Vos retouches gardées : … » dans l'onglet, bouton « Libérer vos retouches » pour les rendre au calcul. Vos temps avec le setup retouché comptent comme setup de départ du calcul suivant.
- **Tests** : AU11 (retouche après chargement : gardée, affichée, libérée) ; AU03, AU06 et fuzz F05 aux nouveaux libellés.

### Interne 1.6.0 — 22/10/2026 — boutons plus visibles ; vos vrais temps (demandes de Vincent)
Retour de Vincent après essai : « on ne voit pas le bouton de chargement… il faut que ce soit plus visible au niveau des boutons qu'on comprenne mieux comment ça fonctionne » ; « les temps qu'il affiche ce ne sont que les temps prévus… ce serait bien qu'il puisse avoir les temps réels que moi j'ai faits ».
- **Étape suivante en couleur** : « Valider vN » en bleu, « Charger … dans la voiture » et « Confirmer le chargement » en vert, en pleine largeur ; « Écarter vN » en rouge quand la version est plus lente en réalité. Chaque version affiche ses étapes (1. Proposée · 2. Validée (enregistrée) · 3. Chargée au stand · 4. Roulée : faites en vert, la suivante en bleu) et une ligne « Étape suivante : … ».
- **Chargement visible** : le fichier à charger et l'état du stand sont affichés à côté du bouton (au stand, voiture arrêtée, menu de setup ouvert : oui / non) ; un refus ou un délai écoulé s'affiche sous le bouton (plus seulement en haut de la fenêtre) ; la confirmation donne le temps restant ; « Annuler le chargement ».
- **Vos temps** : tuiles « Votre meilleur tour » (« Votre tour moyen » en course) et « Objectif estimé » (votre temps moins le gain prévu) ; historique de l'affinage : « Vos tours », « Gain prévu », « Gain réel » (vos temps avant, moins vos temps avec la version) ; pour la version en piste : vos temps avec elle contre ceux d'avant, et si elle est plus lente en réalité (au moins 2 tours de chaque côté, écart au-delà de 0,15 s), proposition de l'écarter. Les temps simulés par le modèle passent au survol. Le modèle reste calé sur vos tours (calibration).
- **Tours rattachés malgré les réglages faits en roulant** : vos temps sont rangés par « famille » de setup, sans le carburant ni la répartition de freinage ; sur la DTM, un tour avec la répartition touchée au volant compte pour la version chargée.
- **« Valider en jeu » devient « Mesurer le gain réel »**, pour ne plus le confondre avec « Valider vN ».
- **Tests** : AU09 (DTM : répartition de freinage changée, tours crédités à la version chargée, vos temps affichés), AU10 (état du stand et refus sous le bouton, temps restant, annulation) ; AF01, M11, I-tests et fuzz mis à jour.

### Interne 1.5.0 — 21/10/2026 — rien n'est enregistré avant « Valider » ; annonce à l'écran (décision de Vincent)
Constat de Vincent : affinage lancé en roulant (DTM à Spa), **29 fichiers** écrits en un quart d'heure. Sa décision : « il ne faut pas qu'il enregistre automatiquement au fur et à mesure des tours. Il analyse les données… il me propose un setup que moi je valide et que j'utilise ou pas. Et ensuite on continue » ; et « une petite alerte pendant que je suis en train de jouer ». Elle remplace la réponse « Sauvegarde = automatique » du mode affinage.
- **Aucun fichier sans clic** : l'affinage n'écrit plus rien tout seul. Chaque setup proposé est une **version en attente** (vN), avec son gain prévu et ses réglages dans la carte d'affinage. **Valider vN** l'enregistre (un fichier : nom choisi `…_vN`, sinon daté), en fait le setup de référence de la séance et le setup à charger au stand ; **Écarter vN** : jamais reproposée, rien d'écrit ; **Figer vN** : validée et verrouillée. Une version validée, essayée puis écartée : la référence d'avant revient (son fichier reste, rien n'est effacé, D8). Seuls « Enregistrer », « Valider », « Figer » et la copie de sauvegarde d'avant un chargement écrivent un fichier.
- **Annonce à l'écran** : une version prête s'affiche une fois, pendant la conduite, dans les messages d'AC en haut de l'écran (`ac.setMessage`, 8 s) : « SetupLab : setup tour rapide v3 prêt — gain prévu … ». Tant qu'elle attend votre avis, elle est mise à jour à chaque tour propre (même numéro, sans nouvelle annonce).
- **Un calcul par donnée nouvelle** : un tour propre (ou N tours selon le réglage), un chargement dans la voiture, ou un nouvel essai après un refus ; jamais deux calculs sur les mêmes données (avant : un calcul toutes les 15 à 30 s, chacun un fichier). Un setup n'est proposé que s'il gagne au moins 0,05 s au tour.
- **Heure des noms de fichiers** : les fichiers écrits en jeu finissaient par « UTC » (heure locale illisible) ; nouvel essai de lecture de l'heure de Windows. Si un nom finit encore par « UTC », l'onglet Capacités en donne la raison.
- **Tests** : AU08 reproduit le constat (DTM, SetupLab actif, carburant qui baisse, 6 tours : aucun fichier, une annonce ; « Valider » : un fichier) ; AF01 à AF05 et AU01 à AU06 réécrits (version en attente, validation qui écrit, référence d'avant rendue après un essai).

### Interne 1.4.0 — 21/10/2026 — SetupLab actif, nom du setup, valider / écarter / figer, mémoire du circuit (décisions de Vincent)
Demande de Vincent : « on l'ouvre, on l'active, on roule, il nous propose un setup, on continue, on roule, on affine le setup, on valide ou on ne valide pas à chaque étape » ; « un bouton avec un cadenas pour dire ce setup est validé » ; « une mémoire par circuit et par type de circuit, et par type de séance ». Réponses de Vincent : l'affinage suit la séance ; valider = référence, écarter = jamais reproposée ; le cadenas fige et mémorise ; mémoire par circuit et par séance.
- **SetupLab actif** (case à cocher en haut de la fenêtre) : coché, SetupLab affine tout seul le setup de la séance (tour rapide en essai, journée circuit, hotlap, time attack et qualification ; course en séance de course), dès la fin de la découverte ; à la séance suivante (essai → qualification → course), l'affinage suit. Décoché, ou « Arrêter l'affinage » : en veille, rien n'est calculé ni enregistré tout seul (les tours restent analysés). Pour ce lancement d'AC : jamais actif tout seul au démarrage (aucun fichier écrit avant votre clic). Une ligne dit l'état (veille, affinage en cours, setup figé).
- **Nom du setup** (champ dans chaque onglet) : les fichiers prennent ce nom (accents et espaces retirés ; versions de l'affinage `_v1`, `_v2`…), jamais d'écrasement (`-2`, `-3`…). Renommer : changer le nom puis « Enregistrer » écrit le même setup sous le nouveau nom ; l'ancien fichier reste (aucun fichier n'est renommé ni effacé, D8). Sans nom : `SetupLab_…_date_heure.ini`, comme avant.
- **Valider / Écarter** chaque version de l'affinage : validée, elle devient le setup de référence de la séance et de l'état de piste, gardé en mémoire ; écartée, elle n'est jamais reproposée (un calcul qui la retrouve ne l'enregistre pas) et le setup à charger redevient la référence. L'affinage part toujours du setup monté : une version validée se charge au stand pour repartir d'elle. Historique : colonne « Avis ».
- **Figer (cadenas)** : la version est validée et verrouillée, gardée en mémoire et proposée à chaque visite ; l'affinage automatique s'arrête pour cette séance et cet état de piste. « Déverrouiller » le relance.
- **Mémoire du circuit** : setup validé par voiture, circuit (disposition comprise), séance (essai ou journée circuit, qualification, course) et état de piste (sec, pluie), gardé d'un lancement d'AC à l'autre (nom du fichier et empreinte de son contenu). Carte « Mémoire du circuit » dans chaque onglet : figé ou validé, **Charger** au stand (deux clics, copie de sauvegarde), **Figer** ou **Déverrouiller**. Fichier absent ou modifié hors de SetupLab : dit, jamais chargé.
- **Chargement** (D8 amendé) : « écrit par SetupLab » se prouve désormais par le nom et l'empreinte du contenu relevés à l'écriture ou gardés en mémoire (noms choisis) ; un fichier étranger, même au bon nom, reste refusé.
- **Affinage** : un setup déjà enregistré avant l'affinage (autre séance, calcul à la main) devient une version à juger, sans nouveau fichier. La version en piste reste jugeable (« Valider v1 (en piste) ») quand une plus récente arrive. Une version écartée encore dans la voiture : rien n'est enregistré à partir d'elle, la carte dit de charger la référence au stand.
- **Stockage** : un setup figé de la mémoire part en dernier si le stockage est plein ; un fichier de la mémoire est relu au plus toutes les 120 s (sur la DTM, une découverte par calcul), le chargement revérifiant toujours son contenu exact.
- **Tests** : AU01 à AU07 (activation et séance, nom et renommage, valider / écarter et repli, cadenas et mémoire après relance de l'app, mémoire par séance et par état de piste, version en piste jugée puis écartée dans la voiture, purge du stockage) ; J03 (empreinte) ; fuzz F05 étendu aux nouveaux boutons.

### Interne 1.3.0 — 21/10/2026 — setups pluie ; affinage en continu (décisions de Vincent)
- **Pluie** (D16 amendé, décision de Vincent : « il faut que ce soit compatible avec la pluie et qu'on puisse calculer les setups avec la pluie ») :
  - plus aucun refus : piste mouillée, pneus pluie montés sur le sec ;
  - état de la piste « sec » ou « pluie » avec hystérésis (0,15 pour entrer, 0,05 pour sortir), figé au lancement de chaque calcul ; la pluie de Pure arrive par les conditions de CSP, lues telles quelles ;
  - tours rangés par setup et par état de piste : calibration pluie à part (stockée sous une autre clé, celle du sec inchangée), validation, mesures de course et état des pneus jamais mélangés ; eau sous les pneus mesurée à chaque tour (`waterThickness`) ;
  - modèle mouillé (hypothèses H25 à H28, à confirmer en jeu, calibrées par vos tours mouillés) : film d'eau selon le pneu (slick, à rainures, pluie), aquaplanage au-delà de ce que les rainures évacuent (`TREAD_DEPTH` × `TREAD_COVER`), en v², pneus plus froids (pression à froid relevée pour viser l'idéale à chaud) ; tous les réglages modélisés en tiennent compte (aileron, barres, ressorts, freinage, différentiel, rapports…) ;
  - composé : sur le mouillé, slicks, intermédiaires et pluie comparés ; DTM à Monza au banc : humide sans eau stagnante → intermédiaire, trempée → pluie, sèche → slick ;
  - aides : règle « plus d'antipatinage, plus d'ABS » (réglage « Pluie : niveaux d'aide en plus », 2 par défaut), sens lu dans la table de chaque voiture, écrites dans le fichier quand la section y est, jamais un refus ; ABS relevé pris en compte (H15) ; aides du jeu coupées : signalé ;
  - fichiers `SetupLab_TourRapide_Pluie_…` et `SetupLab_Race_Pluie_…` ; résultat signalé « calculé ailleurs » si la piste sèche ou mouille, ou si l'eau change de 25 points ;
  - interface : alerte « Setup pluie » toujours visible, section Pluie (eau retenue, hypothèses, aides avant → après), usage de chaque composé dans le comparatif, colonne Pluie dans le statut des réglages (modélisé, règle, inchangé avec la raison), composé et aides compris.
- **Affinage en continu** (décision de Vincent : « même si on fait un demi-tour ou un tour, il va calculer automatiquement directement ») : un nouveau calcul dès la fin du précédent et des tâches en cours, sans attendre de tour ; chaque tour roulé affine la calibration du calcul suivant. Réglage « Affinage : tours propres avant un nouveau calcul » (0 = en continu, par défaut). Calcul refusé : nouvel essai après 10 s, ou au tour propre suivant (jamais à chaque image).
- **Choix du composé** (constat de Vincent : « j'étais en médium, il ne m'a pas passé en supersoft ») : un composé n'est plus écarté d'office « hors de sa fenêtre » à la température mesurée sur le composé monté ; chaque composé est comparé à cette température (sa courbe dit ce qu'il y perd) et la sortie de fenêtre est dite. DTM, médium à 90 °C : le supersoft (≈ 97,5 % de son adhérence à 90 °C) est désormais proposé (W07) ; W05 réécrit.
- **Couverture du setup** (demande de Vincent : « qu'il agisse absolument sur tout ») : sous le tableau des réglages, nombre de réglages optimisés, à venir (ressorts et amortisseurs après un tour valide sur le sec, hauteur de caisse au stand) et conservés, la raison de chacun au survol.
- **Ligne d'état** : une découverte en cours ou en échec passe avant « piste mouillée ».
- **Faux hôte du banc** : une section fermée d'office n'est plus rendue (comme en jeu : son contenu ne coûte rien) ; `h.openSections` la déplie pour un test. Sans cela, le coût hors calcul mesuré par A02 (0,30 ms) comptait des listes que le jeu ne dessine pas. I03, I10, I13, M13, N13, PL07 et PL08 déplient les sections qu'ils vérifient. Fuzz F05 : séquence forcée protégée des clics au hasard ; D08 : `[ABS]` et `[TRACTION_CONTROL]` dans le fichier, comme chez AC.
- **Tests** : PL01 à PL08 (hystérésis, tours rangés par état, calibration pluie, eau mesurée, modèle mouillé, choix du composé selon la piste, règle des aides, aides écrites et chargement vérifié, statut pluie de chaque réglage de la DTM, interface sous la pluie à 360 et 900 px), AF05 (affinage en continu, nouvel essai après le délai) ; Q05, M12 et A11 réécrits (pluie acceptée) ; AF01, AF02, AF04 sur 2 tours explicitement.
- **Non vu en jeu** : le modèle pluie repose sur des hypothèses (la physique pluie de CSP n'est pas documentée) ; vos premiers tours mouillés le calibrent (le mode affinage s'y prête).

### Interne 1.2.0 — 21/10/2026 — mode affinage et tableau de bord (demandes de Vincent)
- **Mode affinage** (demande de Vincent : « on lance l'analyse, au fur et à mesure que l'utilisateur fait des tours, il analyse, on enregistre le setup, on continue, on peaufine, jusqu'à trouver le meilleur setup ») ; décisions de Vincent :
  - enregistrement automatique de chaque setup amélioré (v1, v2…), nouveau fichier horodaté, jamais d'écrasement ; un setup identique au dernier enregistré n'est pas réenregistré (« identique à v2 ») ;
  - chargement proposé au stand, dans la carte d'affinage, en deux clics avec copie de sauvegarde, comme avant (CSP ne charge un setup que menu de setup ouvert) ; après un chargement vérifié, nouvelle découverte aussitôt, voiture au stand (repère de hauteur, A25), une fois les tâches en cours terminées (une calibration n'est pas perdue) ;
  - nouveau calcul après 2 tours propres avec le même setup (`K.refineLaps`), comptés depuis la fin du calcul précédent ; un calcul lancé à la main est attendu, jamais annulé ;
  - jamais d'arrêt tout seul : bouton « Arrêter l'affinage », puis « Relancer l'affinage » ; voiture ou circuit changé : affinage oublié.
  - jamais muet : la carte donne la phase (tours propres comptés, calcul, découverte) et la raison d'une attente ; un calcul refusé (setup encore modifié pendant la découverte, carburant qui baisse…) est repris au tour propre suivant ;
  - piloté par la boucle de calcul : il avance fenêtre masquée ; état dans `app.refine`, à l'abri des remises à zéro de la découverte ; historique des versions (prévu, gain, meilleur tour roulé).
  - calcul dû lancé seulement ordonnanceur libre : la calibration (et la validation) lancée par le tour qui vient de finir aboutit avant ; sinon, sur la DTM (carburant changé à chaque relais, donc découverte relancée), chaque cycle annulait sa calibration et calculait sur les anciens facteurs (relecture du 21/10/2026, AF02) ; rien de plus sur l'image du passage de ligne.
  - limite connue : une découverte relancée en piste ne vérifie pas le repère de hauteur (A25, stand seulement) ; sur une voiture dont le carburant est un cran du setup (DTM), la hauteur de caisse n'est alors plus optimisée à partir de v2, sauf après un chargement au stand (découverte refaite au stand).
- **Tableau de bord** (demande de Vincent : « épurée, dense, condensée, bien organisée », responsive ; maquette choisie par Vincent) :
  - bandeau : voiture · circuit en titre (identifiants et version au survol), état, séance, données et confiance du modèle ;
  - chiffres clés en tuiles (actuel, proposé, gain et son %, modèle ; mesure : dernier tour, meilleur, tours, calibration ; capacités : comptes par état), autant par ligne que la largeur le permet, phrase complète au survol ; toujours visibles sous les tuiles : part du gain « à confirmer », modèle non calibré, surchauffe des pneus ;
  - tableau compact des réglages proposés (actuel, proposé, crans, gain ; 3 colonnes sous 430 px), explication au survol du réglage ;
  - boutons Enregistrer, Charger, Valider sur une ligne (à la ligne si la place manque), issues en dessous ; confirmation du chargement toujours à un autre endroit que « Charger » ;
  - détails en sections repliables (relais et carburant, pneus et composé, ERS, DRS, facteurs de calibration, statut des réglages, capacités) ;
  - fenêtre large (≈ 740 px et plus) : réglages à gauche, graphiques à droite, chacun défilant ; sinon graphiques dans une section repliée. Taille par défaut de la fenêtre : 780 × 760.
  - polices de CSP (petite pour le secondaire, titre pour les chiffres), couleurs par état, infobulles bornées en largeur ; chaque fonction ImGui facultative passe par `Util.call` ou un test de présence.
- **Faux hôte du banc** : sections, fenêtres enfants (largeur réduite à celle du volet), colonnes, infobulles, polices, dessins ; un identifiant ImGui en double dans un même onglet est une erreur (en jeu, l'un des deux boutons ne réagirait plus) ; largeur de fenêtre réglable ; rien n'est survolé sauf `h.hover` : un texte d'infobulle n'est pas « affiché ».
- **Tests** : AF01 à AF04 (boucle complète avec chargement au stand et deux tours propres, carburant qui baisse et setup changé pendant la découverte, calibration non annulée, fenêtre masquée, arrêt et relance), I13 (tous les onglets à 360, 520, 730 et 900 px, sans doublon d'identifiant), I03 et I10 mis à jour (explication et phrase complète au survol, gain en % visible), M11 (résultat course lu sur les tuiles).
- **Non vu en jeu** : tuiles, sections, volets côte à côte et boucle d'affinage ne sont validés qu'au banc ; les dessins (tuiles, barre de la carte) suivent la convention des graphiques existants (`ui.getCursor()` puis `ui.draw*`), à vérifier à l'œil.

### Interne 1.1.1 — 21/10/2026 — enregistrer autant de fois que voulu (constat de Vincent)
- **Constat de Vincent en jeu** (DTM) : « si je refais une analyse et que je veux réenregistrer, il ne fait rien du tout ».
  - cause reproduite au banc : l'enregistrement était refusé dès qu'un cran avait changé entre le calcul et le clic (répartition de freinage touchée au volant, carburant) ; le refus n'était dit que dans le bandeau en haut de la fenêtre, invisible quand elle défile jusqu'au bouton, et la ligne « Enregistré : … » disparaissait ;
  - aucun fichier écrit par l'app ce jour-là dans le dossier des setups : la cause exacte en jeu n'est pas prouvée, mais tout refus ou erreur est désormais affiché sous le bouton.
- **Enregistrement jamais refusé pour un setup changé depuis le calcul** (demande de Vincent : relancer et enregistrer autant de fois que voulu) : le fichier est construit sur le setup du calcul (texte relu à la découverte), avec les changements proposés ; il est donc toujours le setup simulé. Le changement est signalé (« le fichier reprend le setup du calcul »). Signature du setup proposé tirée du fichier écrit (chargement, validation).
- **Autant d'enregistrements que de clics**, après chaque nouveau calcul ou pour le même résultat : un nouveau fichier à chaque fois (suffixe -2, -3… dans la même seconde), jamais d'écrasement (D8).
- **Heure dans le nom** (demande de Vincent : « le renommer avec l'heure pour bien les différencier ») : heure locale, `SetupLab_TourRapide_2026-10-21_14h32m05s.ini` ; aussi pour la course, la copie de test et la copie de sauvegarde avant chargement. Heure lue par FFI (GetLocalTime et GetSystemTime de kernel32, lecture seule, comme l'horloge A2 ; `os.date` reste interdit, `ac.getTimeZoneOffset` est le fuseau du circuit). Sans elle : heure UTC, dite dans le nom (`…_12h32m05sUTC.ini`). Fenêtre debug : fuseau retenu.
- **Issue sous le bouton** « Enregistrer le setup … » : nom du fichier (et nombre de fichiers pour ce calcul), ou raison du refus, ou erreur interne. Une erreur interne pendant le traitement d'un clic est affichée et comptée, au lieu d'être seulement journalisée.
- **Tests** : Q05 réécrit (setup changé après le calcul : fichier du calcul, changement dit), Q14 (DTM : deux enregistrements du même calcul, carburant et répartition changés, nouveau calcul, enregistrement, panne simulée puis reprise, nom UTC de repli), K03b (fuseau : banc Windows et FFI simulée), U12 (inverse de la date civile, nom horodaté).

### Interne 1.1.0 — 20/10/2026 — décisions de Vincent : chargement, budget, essai et journée circuit
- **Essai et journée circuit** (constat de Vincent en jeu : « calcul refusé ») :
  - cause : conditions de piste mémorisées par paliers (2 °C, 0,01 d'adhérence) ; au premier palier franchi (piste qui se gomme, qui chauffe, température oscillant autour d'une limite), tous les calculs étaient refusés jusqu'à une relance manuelle de la découverte ;
  - désormais (A30) : chaque calcul relit l'adhérence et les températures au lancement (copie propre au calcul) ; un résultat dépassé est signalé « calculé dans d'autres conditions », sans blocage ; un changement pendant le calcul est retenu ;
  - nouvelle séance (type, numéro) : nouvelle découverte automatique, une fois la séance confirmée, annoncée ; les setups enregistrés restent chargeables ; tout l'état d'un calcul est pris au même instant, au démarrage de sa tâche ;
  - setup modifié dans le menu puis « Calculer » : découverte relancée, puis calcul automatique ; clic pendant une découverte : le calcul la suit ;
  - test M16 : séance d'essai avec 30 voitures, piste qui évolue à chaque tour, découverte, tours, calcul, enregistrement, chargement et calcul course sans aucun refus.
- **Onglets par usage** (décision de Vincent) : onglet « Tour rapide » (essai, journée circuit, hotlap, time attack, qualification ; fichiers `SetupLab_TourRapide_…`) et onglet « Course » (relais, carburant, usure, trafic). Le bandeau nomme la séance détectée et l'onglet à utiliser ; AC ne distingue pas une journée circuit d'un essai. Test I12 : chaque type de séance de CSP (indéfini, essai, qualification, course, hotlap, time attack, drift, drag) et la journée circuit (essai, 30 voitures IA, voiture en piste) : calcul disponible, bouton présent, aucun refus affiché.
- **Découverte en échec** : « Calcul indisponible » donne la raison exacte de l'échec et un bouton de relance (onglets Tour rapide et Course), au lieu de « découverte non terminée » (I11).
- **Chargement dans la voiture** (D8 amendé par Vincent) : bouton « Charger le setup … dans la voiture » dans les onglets Tour rapide et Course.
  - seulement le dernier setup enregistré par SetupLab, au stand, voiture arrêtée, menu de setup ouvert, setup non imposé, même voiture, ni en ligne ni en replay ;
  - confirmation par un second clic, entre 0,5 et 6 s ; copie de sauvegarde du setup en cours (`SetupLab_Avant_chargement_…`) juste avant, sinon rien n'est chargé ;
  - constat section par section (carburant et composé compris) : « chargé et vérifié », « écart » ou « non concluant » ; capacité `setup_load` dans le rapport J0 ;
  - `ac.loadSetup` appelée seulement par `src/exporter.lua` (linter, filet d'exécution du banc) ; quatre autres fonctions qui modifient la voiture interdites partout.
- **Budget par défaut 1 200 / 400** (A13 tranchée) : pire cas (DTM, Monza) 65 s brutes au lieu de 81 à 97 s, pour −0,017 s/tour en course ; URD avec ERS −0,067 s en qualification ; Nordschleife plus touchée (monter les budgets dans Réglages sur les longs circuits).
- **Validation en jeu** : le setup d'origine reste celui à partir duquel le setup proposé a été calculé, même après un chargement et une nouvelle découverte (sans cela, la validation ne démarrait plus).
- **Relectures adversariales** du chargement (1 majeur, 10 mineurs) et des nouveaux comportements : `docs/RELECTURE_1_1.md`.
- **Tests** : J01 à J07 (chargement), M15 (validation après rechargement), M16 (essai), Q13 (calcul en attente), Z01 à Z10 (séances, conditions, calcul en attente : scénarios de la relecture), A17 et D13 réécrits, A20 ; outil de mutation sensible aussi au code de sortie du banc (échecs du linter).

### Interne 1.0.0 — 20/10/2026 — jalon J8 (revue adversariale, fuzz, §16, empaquetage)
- **Relecture adversariale J7 et J8** (`docs/RELECTURE_J8.md`) : 2 bloquants, 4 majeurs et 11 mineurs, traités ou consignés.
- **Calcul reproductible** (§10.5) : le budget est le budget réglé, sans aucune décision prise sur une horloge. Un arrêt de la recherche au temps, puis un budget ramené d'après le coût mesuré, essayés pendant le J8, ont été retirés : ils rendaient le résultat dépendant de la charge de la machine, et l'arrêt pouvait sauter le raffinement (setup actuel proposé) ou laisser la recherche sans évaluation. Le setup actuel est toujours évalué, le choix n'est jamais vide ; « recherche incomplète » s'affiche quand aucun optimum n'a été raffiné.
- **Durée de calcul** (§14.3) :
  - construction du modèle deux fois plus rapide : accélération latérale maximale résolue par fausse position (plus précise que l'ancienne dichotomie, toujours tenable), tables d'adhérence calculées jusqu'à la vitesse que la simulation peut atteindre ;
  - pas de recherche grossière quand son pas n'est pas assez plus grand que le pas fin (longs circuits) ;
  - rendus de main plus fréquents (simulation, construction du modèle, rapport J0) ;
  - frame du passage de ligne : le travail de fin de tour est retiré de la tranche de calcul de la frame (plancher 0,25 ms) ; frame médiane mesurée de 1,96 à 2,58 ms (M04, A20) ;
  - mesuré aux budgets par défaut, ramené au calme : Huracán ≈ 49 à 67 s, URD avec ERS ≈ 65 à 76 s, DTM pire cas ≈ 76 à 86 s. Durées brutes du pire cas, passages lancés machine calme : 81 à 97 s, donc le §14.3 n'est pas démontré de façon robuste pour le DTM (A13 en attente) ; durée estimée affichée honnêtement (fréquence d'images et tranche réelles), en orange au-delà de 40 s / 45 s.
- **Persistance durcie** : bornes du producteur, aucun facteur en butée repris, empreinte des fichiers de la voiture et version du modèle (D9), seuls les réglages de l'interface conservés, sérialisation au flush, rien d'écrit en ligne ou en replay.
- **Validation en jeu par genre** (qualification, course), verdict conforme ou écart sous tolérance.
- **Onglet Course** : gain en %, profil de vitesse et équilibre par virage. Explications sans chiffre inventé.
- **Voiture sans `aero.ini`** : modèle déclaré incomplet, calcul refusé avec la raison (§16.7).
- **Calibration** : constat du J8, un long virage raté pousse l'appui en butée ; la calibration se déclare alors inutilisable (aucune fausse confiance). Le test V03 affirmait le contraire grâce à l'imprécision de l'ancienne dichotomie.
- **Fuzz** : stockage (F04), app entière sous hôte dégradé avec clics au hasard (F05), voiture sans `aero.ini` (F06).
- **Banc** : budgets B01 à B04 avec contrôle de la qualité et charge de la machine mesurée ; reproductibilité avec deux horloges (Q11) ; I07 à I10, D16, O10, S14, S15.
- **Empaquetage** : `tests/package.py` construit `dist/SetupLab-1.0.0.zip` à partir d'une liste blanche, sans le banc d'essai (données de mods tiers), avec son empreinte SHA-256.

### Interne 0.6.0 — 20/10/2026 — jalon J7 (interface complète, persistance, explications, validation en jeu)
- **Interface** (§12.1, arbitrage A29) :
  - onglets Qualification, Course, Mesure, Réglages, Capacités ;
  - bandeau : voiture, circuit, source des données, confiance du modèle (celle du dernier calcul), état des calculs ;
  - graphique d'équilibre par virage (setup actuel et proposé) à côté du profil de vitesse ;
  - réglages de l'app modifiables par curseurs (tours et durée de course, composé imposé, marges, performance ↔ stabilité, DRS en trafic, budgets, calibration automatique), validés puis conservés d'une séance à l'autre ;
  - avertissements : ABS coupé (H15), setup actuel sous la hauteur minimale avec le carburant prévu.
- **Explications** (§12.2, `src/explain.lua`) : une phrase par réglage proposé, tirée de la simulation :
  - part du tour concernée (virages rapides, lents, pleine charge, freinage) ;
  - vitesse de pointe avant / après ;
  - équilibre avant / après ;
  - pression à chaud contre l'idéale ;
  - blocage de l'arrière au freinage ;
  - gain, ou coût compensé par les autres réglages.
- **Persistance** (§13, arbitrage A28, `src/store.lua`) :
  - une valeur `ac.storage` sur une ligne, sans caractère de contrôle, relue sans exécuter de code ; schéma par genre d'entrée, chaque champ validé à la lecture et à l'écriture ; version du format ; 64 Ko au plus, purge des entrées les moins récemment utilisées ;
  - conservés : réglages de l'app ; par voiture, circuit **et disposition** : calibration par composé (reprise si la piste est à 10 °C près, sinon ignorée avec la raison), rugosité de la piste, derniers setups enregistrés (rappelés avant le calcul) ;
  - capacité « Stockage persistant » à confirmer tant que rien n'a été relu d'une séance précédente.
- **Validation en jeu** (§14.1) : bouton « Valider en jeu » : protocole affiché (tour de référence, chargement du setup proposé, tour propre), puis gain prévu contre gain mesuré.
- **Banc** : suites `test_store` (Y01–Y03) et `test_interface` (I01–I06) ; 24 mutations sur 24 détectées avec les corrections de la relecture J6b.

### Interne 0.5.0 — 20/10/2026 — jalon J6b (DRS, ERS, tous les réglages du setup)
- **Relecture adversariale J6b** (`docs/RELECTURE_J6B.md`) : 1 bloquant, 3 majeurs et 9 mineurs, traités ou documentés :
  - **B1** : un composé plus tendre n'est plus retenu d'office quand la température mesurée l'exclut de sa fenêtre ; bornes de pression recalculées pour le composé retenu (garde-fou de surchauffe compris) ;
  - **M1** : butées et course avant butée conservées tant que H16 n'est pas confirmée ; course de suspension relevée dans le rapport J0 ;
  - **M3** : hauteur statique corrigée du carburant, des ressorts et de la pression ; `MIN_HEIGHT` avec 1 mm de marge ; setup actuel jamais refusé, avertissement s'il passe sous la limite ;
  - mineurs : ABS relu au lancement, roue aberrante sans ancrage, surchauffe sur la roue la plus chaude, rugosité bornée et jamais favorable, fenêtres de ligne droite à rapport constant, carrossage `SHOW_CLICKS=2`, affichages et documentation corrigés ;
  - **M2** (budget dans le pire cas) : voir 1.0.0.
- **DRS à deux états** (§8.9, arbitrage A22, hypothèses H8 et H9) :
  - `drs.ini` lu : aile mobile `[WING_n]`, `EFFECT` (part de l'aile retirée volet ouvert, H8), `LIMIT_G` (H9) ; clés au sens non établi (`IGNORE_ZONES`, `DRS_ZONES` ≠ 1) : DRS non simulé, raison affichée ;
  - tables volet ouvert (traînée, adhérence latérale, vitesse de pointe) ; dans les zones de `drs_zones.ini` (bouclage de la ligne compris), vitesse limite relevée, volet ouvert en accélération seulement, refermé au freinage et au-delà de `LIMIT_G` ;
  - qualification : DRS dans toutes les zones, temps sans DRS, part du gain due au DRS, avertissement si le setup proposé n'est meilleur qu'avec le DRS ; course : DRS sur les tours en trafic seulement ;
  - activation à la découverte (aile, `drsPresent`, zones du circuit), sinon la raison ; rapport J0 complété ;
  - **mesure de l'effet réel** : l'enregistreur relève l'état du volet à chaque échantillon et, à chaque ouverture, les coefficients `cl` et `cd` de l'aile avant et après ; les rapports ouvert/fermé s'affichent dans le tour copié (à comparer à 1 − EFFECT) ; un tour roulé volet ouvert est simulé avec le DRS (calibration, validation) ;
  - nouvelle suite `test_drs` (G01–G09) ; 13 mutations sur 13 détectées.
- **ERS** (§8.9, arbitrage A27, hypothèses H21 à H24) :
  - `ers.ini` et profils du cockpit `ctrl_ers_N` / `ctrl_ers_front_N` lus ; MGU-K par la boîte, moteurs avant bornés par l'adhérence de l'avant ; batterie (capacité, limite par tour) ; récupération au freinage et au lever de pied ;
  - stratégie de déploiement optimisée par programmation dynamique sur la charge de la batterie, zone par zone ; batterie rejouée le long du tour (jamais négative, limite par tour) ; jamais moins bien que le profil de la voiture ;
  - qualification batterie pleine ; course en régime établi, profils de la voiture évalués de même ;
  - profils du cockpit comparés, le meilleur recommandé ; zones de déploiement et bilan d'énergie affichés ;
  - setup : plan du setup actuel pendant la recherche, refait pour le setup proposé ;
  - enregistreur : déploiement, énergie et charge relevés ; calibration d'un tour roulé avec l'ERS simulée avec son déploiement réel ;
  - nouveaux modules `src/ers.lua` et `src/ers_plan.lua` ; suites `test_ers` (N01–N13) et `test_budget_ers` (B02 : ≈ 80 s à Monza avec l'URD).
- **Tous les réglages du setup pris en compte** (§10.3, arbitrage A23, demande de Vincent) :
  - chaque cran a un statut affiché (« Réglages du setup » dans la fenêtre, rapport J0) : optimisé, ou conservé avec sa raison ;
  - nouveaux réglages optimisés : carrossage, puissance de freinage (risque de blocage sans ABS, H15), différentiel en accélération (moment de lacet en sortie de virage, H20), hauteur de caisse une fois le repère vérifié au stand (A25), ressorts, pilonnage, amortisseurs, butées et course avant butée une fois la rugosité de la piste mesurée (A26) ;
  - conservés avec leur raison : pincement, différentiel au lâcher et précharge, répartition 4×4, écopes de frein, réglages scriptés de la voiture, aides électroniques et cartographies, carburant (règle) ;
  - garde-fou général : un réglage n'est optimisé que si son effet et sa contrepartie sont modélisés ; optimum intérieur ou butée expliquée, vérifié par balayage sur les quatre voitures du banc ;
  - 20 mutations sur 20 détectées.
- **Pressions et surchauffe** (§8.6, §10.6, arbitrage A24, demande de Vincent) :
  - pression à chaud ancrée sur la mesure du dernier tour valide (température de chaque essieu, écart mesuré à la loi des gaz, qui peut atteindre plusieurs psi) ; sans mesure, recherche réduite ;
  - pression à chaud proposée jamais plus loin de l'idéale que l'actuelle (l'optimiseur s'en servait comme réglage d'équilibre) ;
  - essieu en surchauffe : pression à froid jamais abaissée, avertissement ; carrossage borné par l'écart de température intérieur − extérieur ;
  - affichage par essieu : température contre fenêtre, pressions à chaud prévues, idéale et mesurée.
- **Suspension** (A26, hypothèses H16 à H19) : écrasement sous l'appui arrêté par les butées ; variation de charge des pneus sur la rugosité de la piste (quart de véhicule) ; perte d'adhérence par la sensibilité à la charge ; raideur du pneu fonction de la pression ; rugosité mesurée par l'enregistreur sur les charges de roue en ligne droite.
- **Budget** (A13) : valeurs par défaut ramenées à 2 500 évaluations en qualification et 450 relais en course : même gain qu'à 4 000 / 600 à 0,02 s près, ≈ 72 s au total à Monza pour la Huracán (cas facile ; le pire cas dépassait 90 s, corrigé en 1.0.0).
- **Découverte** : rendus de main dans la construction du modèle de voiture et de l'espace de setup (les blocs dépassaient 1 ms avec tous les crans et l'ERS ; A02 : 99e centile 2,55 ms).
- **Banc** : suites `test_tyres` (W01–W06), `test_ride` (H01–H03), `test_suspension` (X01–X09), `test_budget` (B01 seul dans son environnement) ; P07 (chaque cran a un statut), M13 (surchauffe de bout en bout) ; V03 place le virage raté dans la plus longue zone lente du profil ; V09 compte les intervalles au-delà de 3 ms au lieu d'un maximum isolé.


### Interne 0.4.0 — 20/10/2026 — jalon J6 (relais et setup de course)
- **Composé de pneus (D18, arbitrage A20)** — correctif d'un défaut des J4 et J5 : la simulation du setup actuel, la qualification et la calibration utilisaient le composé par défaut du fichier, pas celui monté sur la voiture.
  - le composé monté est retrouvé par son index CSP, pas par sa position dans `tyres.ini` ; absent ou illisible : calcul refusé ; pneus pluie montés : calcul refusé (D16) ;
  - une seule fonction construit le setup physique (simulation, optimisation, calibration, validation) ;
  - le composé entre dans la signature du setup ; un changement de composé depuis la découverte bloque le calcul et l'enregistrement ;
  - **choix automatique** en qualification et en course : composé monté et composés secs comparés au setup actuel, pneus pluie et intermédiaires jamais choisis d'office (D16), composé monté gardé à 0,05 s près ; composé imposable (`compoundChoice`) ;
  - le fichier exporté change `[TYRES] VALUE=` seulement si le composé change ;
  - **calibration par composé** (§9.2) : l'optimiseur n'applique que les facteurs du composé retenu, sinon il le signale ;
  - validation (§14.1) indépendante de la calibration : gain prévu par le modèle de la décision, dans les conditions mesurées de chaque tour (carburant compris), contre gain mesuré.
- **Simulation de relais** (`src/stint_sim.lua`, §8.7) :
  - carburant décroissant, usure par essieu (WEAR_CURVE, km virtuels) avec le déséquilibre induit, trafic (aspiration H6, air sale H7) ;
  - relais exact pour le résultat : temps total, tour moyen, dégradation en %/tour, tour critique, équilibre au premier et au dernier tour ;
  - relais évalué par l'optimiseur sur 5 tours simulés : le niveau d'usure de chaque essieu à chaque tour étant connu d'avance, le temps au tour est ajusté sur le carburant et ces niveaux, puis sommé sur les N tours (écart au relais exact ≤ 0,03 s/tour sur les vraies courbes de la Huracán ; arbitrage A21).
- **Setup de course** (`Optimizer.runRace`, §10.2, §10.6) :
  - J_C = tour moyen du relais + w_trafic·P_trafic + pénalités d'équilibre et de stabilité (stabilité et robustesse renforcées en course) ; P_trafic comprend la stabilité au freinage dans l'air sale ;
  - composé choisi sur le relais exact, avec les mêmes facteurs pour tous ; sans usure mesurée, composé monté conservé ;
  - contrôle final sur relais exacts : jamais de setup proposé plus lent que l'actuel (sinon setup actuel conservé, carburant de course seulement) ;
  - nombre de tours : réglages (`raceLaps`, `raceMinutes`), sinon séance de course du week-end (tours, ou durée avec tour additionnel), sinon durée supposée et signalée ;
  - carburant : consommation mesurée sur un tour du setup de référence, sinon CSP (relue au lancement), sinon modèle (marge supplémentaire, jamais sous le carburant actuel), jamais sous la valeur CSP ; consommation inconnue : carburant actuel conservé ; marge `fuelMarginPct` ; relais limité par le réservoir, ou par le carburant actuel si le cran FUEL n'est pas réglable ; arrêts annoncés ;
  - course à la durée : tours comptés sur le plus court du meilleur tour mesuré et du tour calibré ; données de séance bornées ;
  - usure : km virtuels par tour mesurés pendant le tour par l'enregistreur, sinon longueur × taux d'usure de la session (à confirmer) ;
  - bouton **« Calculer le setup course »** avec durée estimée, progression et annulation ; **« Enregistrer le setup course »** : nouveau fichier `SetupLab_Race_<horodatage>.ini`.
- **Thermique (arbitrage A19)** : pas de modèle thermique prédictif ; température des pneus au plateau de PERFORMANCE_CURVE en qualification comme en course, source affichée.
- **Données** : séances du week-end, assistance d'aspiration, taux de consommation de la session appliqué au modèle ; rapport J0 complété (composé monté, taux, aspiration, séances) pour confirmer les échelles en jeu.
- **Budget (§14.3)** : qualification et course ≈ 81 s réelles à Monza aux budgets par défaut (4 000 et 600).
- **Relecture adversariale J6** : 2 bloquants, 7 majeurs et 9 mineurs, tous traités ; 22 mutations sur 22 détectées (`docs/RELECTURE_J6.md`) ; les deux bloquants : relais échantillonné qui se trompait de composé (résultat possible plus lent que l'actuel), et carburant de course au minimum du cran sans consommation connue.
- **Banc** :
  - un environnement Lua neuf par fichier de tests : suites isolées, mesures de temps représentatives de l'app seule ;
  - nouvelle suite `test_stint` (L01–L10, B01) ; Q09, Q10, R11, M10, M11, M12 ; M04 sur plusieurs passages de ligne (médiane, surcoût hors tranche de calcul 0,2 ms) ; V09 sur la distribution des intervalles entre rendus de main ;
  - endurance étendue à 16 calculs course, dont 4 annulés.

### Interne 0.3.0 — 20/10/2026 — jalon J5 (mesure et calibration)
- **Enregistreur de tours** (`src/recorder.lua`, §9.1) :
  - lecture seule à 30 Hz, découpage par le compteur de tours d'AC ;
  - temps officiel `previousLapTimeMs` retenu seulement s'il recoupe l'une de trois références : chrono du tour d'AC la frame d'avant, maximum de ce chrono pendant le tour, durée en temps de simulation. Ainsi, peu importe qu'AC remette son chrono à zéro avant ou après l'incrément du compteur, et les pauses sont exclues. Attente d'1 s au plus en cas de mise à jour tardive ;
  - origine de la ligne IA et ligne de chronométrage pouvant différer : écarts mesurés en tenant compte du bouclage ;
  - le tour commencé en cours de route (app ouverte, sortie des stands, départ arrêté) n'est jamais enregistré ;
  - un tour est rejeté, avec sa raison affichée, s'il est invalidé par AC, s'il passe par la voie des stands, en cas de sortie de piste, de trou de couverture ou de recul (retour au stand, téléportation), si le setup est illisible ou change en roulant, si la répartition de freinage change, si le temps officiel ne recoupe pas le chrono, ou si la mémoire est pleine ;
  - signature du setup : crans assainis comme à la découverte, carburant exclu (il est mesuré à part) ;
  - conservation : le dernier tour et le meilleur tour valide de chaque setup ; le setup de la découverte et le setup proposé ne sont jamais évincés ; positions gardées seulement sans ligne IA ;
  - inerte en ligne et en replay dès la frame où le mode change ; aucun échantillon pendant une pause.
- **Export du tour** (« Copier le tour enregistré ») : en-tête (temps officiel, masse et centre de gravité CSP, carburant, pneus, turbo, setup, conditions), puis un point tous les 5 m.
- **Calibration** (`src/calibration.lua`, §9.2, §9.3 bis, §14.1) :
  - 5 facteurs bornés, recalés sur un ou plusieurs tours, chacun dans ses conditions réelles : températures et km des pneus, pressions à chaud mesurées, carburant moyen, piste ;
  - descente de coordonnées puis Levenberg–Marquardt, avec perte de Huber (arbitrage A17) ;
  - facteurs non identifiables détectés et laissés à 1 ;
  - facteur en butée : calibration non utilisée ;
  - écart par tour et écart « modèle idéal / tour réel » affichés ;
  - calibration automatique après chaque tour valide (`calibrationAuto`) ;
  - les facteurs ne passent au calcul de setup que si les seuils du §14.3 sont tenus.
- **Validation du setup proposé** (§14.1) : une fois le fichier `SetupLab_Quali_…` chargé, ses tours sont reconnus et l'app calibre sur les deux setups. Elle affiche ensuite le gain mesuré à côté du gain prévu. Ce dernier est simulé dans les conditions mesurées de chaque tour : carburant (le setup qualification part avec 3 tours d'essence), pneus et piste.
- **Reconnaissance du circuit** (A14) : sans ligne IA, le premier tour valide fournit la géométrie (largeurs inconnues, confiance abaissée), puis la découverte est relancée.
- **Mode « mesure uniquement »** (§9.4, arbitrage A18) : pour une voiture dont les données sont illisibles, un modèle est estimé sur le tour (puissance, traînée, adhérence, appui, boîte) et son tour simulé est affiché. Aucun calcul de setup dans ce mode : aucun cran n'y est convertible.
- **Correctifs** :
  - le test d'identifiabilité comparait, sur une borne, le point à lui-même, et masquait une butée en « non identifié » ;
  - le rapport J0 plantait sur un circuit reconstitué ;
  - le modèle de voiture accepte les pressions à chaud mesurées.
- **Relecture adversariale J5** : 1 bloquant (conditionnel), 6 majeurs et 9 mineurs, tous traités ; plus 3 points de la revue finale (`docs/RELECTURE_J5.md`). Les principaux :
  - ligne de chronométrage décalée de l'origine de la ligne IA : tours faussement rejetés ;
  - signature illisible qui faisait échouer chaque frame ;
  - préparation de la calibration hors tâche découpée (jusqu'à 37 ms) ;
  - progression inexploitable sur un circuit reconstitué ;
  - carburant dans la signature ;
  - temps officiel non recoupé.
- **Banc** (143 tests, 0 échec ; 28 mutations sur 28 détectées) :
  - nouvelles suites `test_recorder` (R01–R10), `test_calibration` (V01–V09) et `test_measure` (M01–M09) ;
  - conducteur simulé dans l'hôte : progression, vitesse, accélérations, pédales, boîte, tours et temps officiel ; ligne de chronométrage décalée, temps officiel tardif ou faux, chrono remis à zéro avant ou après le compteur, pause, absence de ligne IA ;
  - découpage de la calibration mesuré sur la Nordschleife (4 setups, 12 400 échantillons par tour) : 0,9 ms au plus entre deux rendus de main ;
  - tours « mesurés » volontairement hors du modèle : abscisse décalée, bruit, autre récupération du carrossage, autre temps de passage de rapport, virages ratés ;
  - endurance étendue à 24 tours enregistrés ;
  - mesure d'allocation de S09 sur la meilleure de 3 séries (méthode A16).
- **Limite** : la calibration n'a été validée que sur des tours simulés. Sa fidélité à AC (§14.3) reste à établir sur de vrais tours (protocole `docs/API_NOTES.md` §6).

### Interne 0.2.0 — 19/10/2026 — jalons J2, J3 et J4 (qualification)
- **DRS et ERS** : présence fournie par AC (`drsPresent`, `kersPresent`), et non plus « `drs.ini` lu ». Aile mobile désignée par une section `[WING_n]` de `drs.ini`. `EFFECT=0` ou fichier vide signifient « pas de DRS ». États en direct relevés (`drsAvailable`, `drsActive`) ainsi que les ailes (`cd`, `cl`, incidence). L'ancien `kers.ini` est lu aussi. « À confirmer » jusqu'au J6b (§8.9).
- **J2, modèle de circuit** (`src/track_model.lua`) :
  - abscisse à pas constant, avec `ds` automatique jusqu'à 5 m sur les longs circuits ;
  - courbure validée contre le rayon de `fast_lane.ai` ;
  - pente, courbure verticale (crêtes et compressions) ;
  - dévers sondé par la normale de surface de `raycastTrack` ;
  - segments (virages, lignes droites, chicanes) indépendants de la ligne d'arrivée ;
  - zones DRS, grip de surface, confiance.
- **J3, modèle de voiture et simulation** (`src/car_model.lua`, `src/laptime_sim.lua`) :
  - tables de performance par vitesse et charge normale ;
  - pneus Kunos (sensibilité à la charge, carrossage, pression, température, usure) ;
  - aéro avec contrôleurs de vitesse et écrasement ;
  - décollement de roue, freinage (répartition, couple), motricité FWD / RWD / AWD, turbo ;
  - force motrice par rapport à vitesse exacte ;
  - simulation quasi statique (vitesse limite, passes arrière et avant, ellipse d'adhérence, temps de passage de rapport, carburant).

  Le tour du setup actuel est simulé à la découverte ; son **profil de vitesse** est affiché.
- **J4, qualification** (`src/setup_space.lua`, `src/optimizer.lua`). Réglages non optimisés au J4, avec leur raison affichée : carrossage, ressorts, différentiel, puissance de freinage, hauteur de caisse.
  - correspondance cran → grandeur physique, vérifiable en jeu, à confirmer par le tableau du rapport J0 (le banc ne prouve que l'accord de deux implémentations de la même hypothèse) ;
  - optimiseur reproductible : Halton, descente de coordonnées, robustesse ±3 %, départage par la distance au setup actuel, sensibilités ;
  - carburant de qualification sûr ;
  - bouton **« Calculer le setup qualification »**, avec durée estimée, progression et annulation ;
  - résultat avec gain par réglage et réglages « à confirmer » ;
  - **« Enregistrer le setup qualification »** : nouveau fichier `SetupLab_Quali_<horodatage>.ini`, où seuls les `VALUE` proposés changent. Refus si le setup du jeu a changé depuis le calcul. Le setup actuel n'est jamais modifié (D8).
- **Prudence** :
  - la découverte survit à une erreur du modèle de voiture (D7), et le rapport J0 reste disponible ;
  - le calcul est refusé si le setup du jeu a changé depuis la découverte ;
  - la durée estimée tient compte de la tranche réduite sous 60 images/s ;
  - les réglages en butée ne sont pas chiffrés comme gain ;
  - carburant : la plus grande des consommations (CSP, modèle) ;
  - réserve de budget plafonnée à 30 %, robustesse signalée quand le budget ne la couvre pas.
- **Essai de fumée** sur les 11 voitures installées à données ouvertes (Monza) : aucune erreur, temps plausibles, fichiers rendus valides.
- **Endurance** (§14.2) : 1 000 découvertes enchaînées (+ 608 Kio), puis 40 calculs qualification dont 10 annulés en cours (+ 249 Kio), aucune erreur. Banc : 115 tests, 0 échec.
- **Relectures adversariales J2 et J3** : tous les constats sont traités (`docs/RELECTURE_J2_J3.md`) ; 25 mutations sur 25 détectées.
- **Banc** : nouvelles suites `test_track`, `test_sim`, `test_space`, `test_optimizer` et `test_quali` ; jeux de données étendus (rayon, vitesse et dévers de `fast_lane.ai`, Nordschleife).

### Interne 0.1.1 — 19/10/2026 — écriture des setups vérifiable en jeu
- **Correction** : « Écriture directe du setup : indisponible » s'affichait à tort. La capacité dépendait de la vérification complète de l'encodage des crans, et l'app n'avait jamais tenté d'écrire. Les deux notions sont désormais séparées (arbitrage A12) :
  - `setup_write` mesure seulement la capacité d'écrire ;
  - `setup_encoding` détermine les réglages que l'export pourra modifier.
- Nouveau bouton **« Enregistrer une copie du setup actuel »**. Il produit un nouveau fichier `SetupLab_Test_<horodatage UTC>.ini` dans `setups/<voiture>/<circuit>/` :
  - copie exacte du setup courant, relu au moment du clic ;
  - jamais d'écrasement (suffixes -2, -3…) ;
  - écriture sûre, relue et comparée ;
  - liste des setups d'AC rafraîchie.

  La capacité passe à « disponible », avec le chemin, et le rapport J0 est mis à jour.
- Nouveau module `src/exporter.lua`, seul module autorisé à écrire (avec `store` au J7).
- Banc :
  - 68 tests (+ `test_exporter.lua`, + A18) ;
  - 16 mutations sur 16 détectées ;
  - toujours aucune écriture pendant la découverte.

### Interne 0.1.0 — 19/10/2026 — jalons J0 + J1

### J0 : découverte de l'API (non clos : observations en jeu en attente)
- Lecture du SDK CSP installé (0.3.0-preview675). Signatures, unités et contrats consignés dans `docs/API_NOTES.md`, avec numéros de ligne.
- Panneau « Capacités » : 23 capacités évaluées (disponible, à confirmer, indisponible, sans objet), chacune avec sa raison.
- Rapport J0 copiable dans le presse-papiers. Il contient :
  - les fonctions présentes ;
  - les fichiers voiture lus ;
  - les LUT et rapports de boîte ;
  - le format brut des INI CSP ;
  - le tableau complet des crans de setup, comparé au contenu du fichier ;
  - l'état physique courant ;
  - les longueurs et la géométrie du circuit ;
  - la session ;
  - la télémétrie champ par champ ;
  - le coût des tranches.
- Arbitrages A1 à A9 et incohérence de budget de calcul (§5 des notes) à trancher avant J3.

### J1 : socle
- `util` :
  - maths protégées ;
  - LUT ;
  - analyseurs INI, LUT et RTO bornés ;
  - RNG déterministe ;
  - journal circulaire de 200 lignes à débit limité ;
  - ordonnanceur coopératif à coroutines avec **rendu de main prédictif** ;
  - dates sans `os.*`.
- `config` : schéma unique des réglages du §15, validation (type, finitude, bornes) et modulation des pénalités par le curseur Performance ↔ Stabilité (§10.2).
- `caps` : détection des fonctions (cdata compris), horloge QueryPerformanceCounter, évaluation des capacités, rapport.
- `datasource` : lecture protégée de la voiture (`data.acd` compris, via CSP), du circuit (ligne IA), de la session et du setup. Les données sont copiées en tables pures, bornées.
- Colle :
  - hôte injecté ;
  - inerte en ligne et en replay ;
  - détection de contexte à 1 Hz ;
  - garde de frame ;
  - tranches de 2 ms, réduites sous 60 images/s ;
  - rechargement propre.
- Banc hors jeu :
  - 62 tests ;
  - linter strict, avec 26 auto-tests prouvant qu'il détecte chaque violation, accès par nom en texte compris ;
  - fuzz ;
  - endurance de 1 000 découvertes sans croissance mémoire ;
  - jeux de données réels (4 voitures, 3 circuits).

### Relecture adversariale J0 + J1 (`docs/RELECTURE_J0_J1.md`)
- Double point d'entrée de la boucle (`[SIM_CALLBACKS] UPDATE` et `script.update`), verrouillé sur une seule source par frame (A10).
- Analyses de texte en temps linéaire. Une ligne de 40 000 espaces gelait le jeu plusieurs secondes.
- Cohérence crans ↔ fichier stricte : tout réglage modifiable absent du fichier est « à confirmer ».
- Garde en ligne / replay prudente : un drapeau illisible rend l'app inerte.
- Conditions de session par paliers : les résultats sont marqués périmés.
- Divers :
  - rapport repris après un replay ;
  - liste de fichiers vide ;
  - circuit ouvert ;
  - rapports de boîte indexés ;
  - poids des appels CSP dans le repli sans horloge ;
  - constantes déplacées dans `Config.K`.
- Linter : contrôle des accès par nom en texte (D8, écritures).
- Campagne de mutations : 11 corrections sur 11 protégées par un test qui échoue si on les annule.
