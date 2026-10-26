# setup_space.lua (noms des réglages, raisons), store.lua, track_model.lua.
LABELS = {
    'Aileron': 'Wing', 'Pression': 'Pressure', 'Carrossage': 'Camber', 'Ressort': 'Spring',
    'Ressort de pilonnage': 'Heave spring', 'Hauteur de caisse': 'Ride height', 'Barre antiroulis': 'Anti-roll bar',
    'Répartition de freinage': 'Brake bias', 'Puissance de freinage': 'Brake power',
    'Différentiel (accélération)': 'Differential (power)', 'Carburant': 'Fuel', 'Rapport': 'Gear',
    'Rapport final': 'Final drive', 'Limiteur de régime': 'Rev limiter', 'Amortisseurs lents': 'Slow dampers',
    'Amortisseurs rapides': 'Fast dampers', 'Raideur de butée': 'Bump stop rate', 'Course avant butée': 'Packer travel',
    'Pincement': 'Toe', 'Différentiel (lâcher)': 'Differential (coast)', 'Différentiel (précharge)': 'Differential (preload)',
}

EN = {}
for fr, en in LABELS.items():
    EN[fr] = en
    EN[fr + ' avant'] = 'Front ' + en[0].lower() + en[1:]
    EN[fr + ' arrière'] = 'Rear ' + en[0].lower() + en[1:]
EN['Rapport %s'] = 'Gear %s'
EN['Aileron %s'] = 'Wing: %s'

EN.update({
    ' avant': ' front',
    ' arrière': ' rear',
    'réduit': 'reduced',
    'non modélisé': 'not modelled',
    'conservé : rugosité de la piste à mesurer (rouler un tour valide avec ce setup, lignes droites comprises)':
        'kept: track roughness to measure (drive a valid lap with this setup, straights included)',
    "conservé : son bénéfice (inscription, stabilité) est transitoire, hors du modèle quasi statique, et l'angle ne se déduit pas du cran (géométrie de direction inconnue)":
        'kept: its benefit (turn-in, stability) is transient, outside the quasi-static model, and the angle cannot be deduced from the step (steering geometry unknown)',
    'conservé : effet au lever de pied et en entrée de virage (transitoire), non modélisé':
        'kept: effect when lifting and on corner entry (transient), not modelled',
    'conservé : effet à faible couple (épingles, transitoires), non modélisé': 'kept: low-torque effect (hairpins, transients), not modelled',
    "conservé : sous-virage en sortie dû au couple transmis à l'avant, non modélisé":
        'kept: exit understeer from the torque sent to the front, not modelled',
    'conservé : température des freins non modélisée': 'kept: brake temperature not modelled',
    'conservé : réglage défini par le script de la voiture (script.lua), effet inconnu':
        "kept: setting defined by the car's script (script.lua), effect unknown",
    'conservé : aide électronique, effet non modélisé': 'kept: electronic aid, effect not modelled',
    'conservé : cartographie moteur, courbes par cartographie non lues': 'kept: engine map, per-map curves not read',
    'conservé : amortisseur de pilonnage du setup non relié au modèle (celui du fichier sert, H18)':
        "kept: the setup's heave damper is not linked to the model (the file's one is used, H18)",
    "conservé : H16 à confirmer (course avant butée comptée depuis l'assiette statique ou depuis la détente : la course de suspension relevée au stand, rapport J0, tranchera) ; sous H16, aucun effet modélisé":
        'kept: H16 to confirm (packer travel counted from static ride or from full droop: the suspension travel read in the pits, J0 report, will decide); under H16, no effect modelled',
    'conservé : réglage non reconnu par SetupLab': 'kept: setting not recognised by SetupLab',
    "non optimisé : repère de hauteur de l'aéro non vérifié (J5)": 'not optimised: aero height reference not checked (J5)',
    'fixé par la règle de carburant': 'set by the fuel rule',
    'verrouillé ou masqué (D20)': 'locked or hidden (D20)',
    'onglet masqué (D20)': 'tab hidden (D20)',
    'MIN/STEP absents de setup.ini': 'MIN/STEP missing from setup.ini',
    'fichier de rapports illisible ou incohérent': 'gear ratio file unreadable or inconsistent',
    'recherche réduite': 'reduced search',
    '%s : %s à +%s crans%s': '%s: %s to +%s steps%s',
    "%s au plus ; restreinte au lancement du calcul (pression à chaud jamais plus loin de l'idéale, jamais abaissée en surchauffe, recherche réduite sans mesure)":
        '%s at most; narrowed when the computation starts (hot pressure never further from the ideal, never lowered when overheating, reduced search without a measurement)',
    "%s au plus ; restreinte au lancement du calcul selon l'écart intérieur − extérieur mesuré":
        '%s at most; narrowed when the computation starts from the measured inside − outside difference',
    'conservé : conversion contredite par la mesure en jeu': 'kept: conversion contradicted by the in-game measurement',
    'conservé : aucune marge de réglage': 'kept: no adjustment room',
    'conservé': 'kept',
    'optimisé': 'optimised',
    'non touché': 'untouched',
    'non touché sous la pluie non plus : %s': 'untouched in the rain too: %s',
    'règle': 'rule',
    'règle de carburant, la même que sur le sec': 'fuel rule, the same as in the dry',
    "règle pluie des aides : niveaux plus stricts (réglage « Pluie : niveaux d'aide en plus »)":
        'rain rule for the aids: stricter levels ("Rain: extra aid levels" setting)',
    'inchangé': 'unchanged',
    'cartographie moteur non modélisée : à adoucir au volant si la motricité manque':
        'engine map not modelled: soften it from the wheel if traction is lacking',
    'pincement : effet transitoire non modélisé, sur le mouillé comme sur le sec': 'toe: transient effect not modelled, in the wet as in the dry',
    'différentiel au lâcher : effet transitoire non modélisé': 'coast differential: transient effect not modelled',
    'précharge du différentiel : effet à faible couple non modélisé': 'differential preload: low-torque effect not modelled',
    'répartition 4×4 non modélisée': '4×4 split not modelled',
    'température des freins non modélisée (freins plus froids sous la pluie)': 'brake temperature not modelled (cooler brakes in the rain)',
    'réglage du script de la voiture : effet inconnu': "car script setting: effect unknown",
    'réglage inconnu': 'unknown setting',
    'conservé pour la même raison que sur le sec': 'kept for the same reason as in the dry',
    'modélisé': 'modelled',
    "optimisé : pneus plus froids sur le mouillé (H27), pression à chaud visée à l'idéale":
        'optimised: cooler tyres in the wet (H27), hot pressure aimed at the ideal',
    "optimisé avec l'adhérence mouillée (H25 à H27) ; l'aquaplanage selon la hauteur de caisse n'est pas modélisé":
        'optimised with wet grip (H25 to H27); aquaplaning versus ride height is not modelled',
    "optimisé avec l'adhérence mouillée (H25 à H27) : film d'eau, aquaplanage, pneus plus froids":
        'optimised with wet grip (H25 to H27): water film, aquaplaning, cooler tyres',
    'piste sèche : inchangé': 'dry track: unchanged',
    'absent de cette voiture': 'not on this car',
    'niveau absent du fichier de setup : à régler au volant': 'level missing from the setup file: set it from the wheel',
    "réglage « Pluie : niveaux d'aide en plus » à 0": '"Rain: extra aid levels" setting at 0',
    'déjà au niveau le plus strict': 'already at the strictest level',
    'déduit %s, mesuré %s : non optimisé': 'deduced %s, measured %s: not optimised',
    '%s : réglage non optimisable': '%s: setting cannot be optimised',
    '%s : %s hors plage ou hors grille': '%s: %s out of range or off the grid',
    'setup courant illisible': 'current setup unreadable',
    '%s : section absente du setup courant': '%s: section missing from the current setup',
    # store.lua
    'contenu trop volumineux : ignoré': 'content too large: ignored',
    'en-tête absent : contenu ignoré': 'header missing: content ignored',
    "version %s plus récente que l'app : contenu ignoré": 'version %s newer than the app: content ignored',
    'version %s inconnue : contenu ignoré': 'version %s unknown: content ignored',
    '%s ligne(s) rejetée(s)': '%s line(s) rejected',
    # track_model.lua
    'crête': 'crest',
    'défaut': 'default',
    'géométrie indisponible : %s': 'geometry unavailable: %s',
    'ligne non refermée (%s m) : tracé traité comme ouvert': 'line not closed (%s m): layout treated as open',
    'longueur %s % de la ligne IA': 'length %s % of the AI line',
    'longueur %s % de la longueur déclarée': 'length %s % of the declared length',
    'largeurs inconnues sur %s points': 'widths unknown on %s points',
    'largeur prise par défaut sur %s points': 'default width used on %s points',
    'dévers inconnu (pris nul)': 'camber unknown (taken as zero)',
    '%s points de ligne IA invalides': '%s invalid AI line points',
})
