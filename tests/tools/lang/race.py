# Affinage pendant une séance de course (demande de Vincent du 05/11/2026) : fenêtre en piste, tours en trafic comptés
# pour la course, départ du setup en place, rien de chargé avant l'arrivée, setup proposé à l'arrivée.
EN = {
    # enregistreur, garde du chargement
    "tour après l'arrivée": 'lap after the finish',
    "course en cours : rien n'est chargé avant l'arrivée": 'race in progress: nothing is loaded before the finish',
    # tours de course analysés
    '%s tour%s de course analysé%s': '{1} race lap{2} analysed',
    '%s tour%s de course analysé%s (dont %s en trafic)': '{1} race lap{2} analysed ({4} in traffic)',
    'Tour de course compté, en trafic (%s s) : %s.': 'Race lap counted, in traffic (%s s): %s.',
    'Tour de course compté, avec incident (%s, %s s) : %s.': 'Race lap counted, with an incident (%s, %s s): %s.',
    '%s tour%s de course analysé%s (dont %s)': '{1} race lap{2} analysed ({4})',
    '%s en trafic': '%s in traffic',
    '%s avec incident': '%s with an incident',
    '%s en trafic, %s avec incident': '%s in traffic, %s with an incident',
    'valide pour la course seulement (%s)': 'valid for the race only (%s)',
    'trafic': 'traffic',
    # annonces à l'écran
    'SetupLab : setup %s v%s pour votre prochaine course': 'SetupLab: %s setup v%s for your next race',
    "Gain prévu %s s, d'après %s. Dans SetupLab, onglet COURSE : trier ses réglages (« Modifier… ») et Valider ; ou Recommencer.":
        'Predicted gain %s s, based on %s. In SetupLab, RACE tab: sort its settings ("Modify…") and Validate; or Start over.',
    "J'ai le minimum d'informations ; je continue d'analyser vos tours de course. Le setup vous sera proposé à l'arrivée, pour votre prochaine course.":
        'I have the minimum information; I keep analysing your race laps. The setup will be offered to you at the finish, for '
        'your next race.',
    " (provisoire) : analyse de vos tours de course jusqu'à l'arrivée": ' (provisional): your race laps are analysed until the finish',
    # Valider, Essayer, lancement
    "Course en cours : rien n'est chargé avant l'arrivée ; elle servira à votre prochaine course.":
        'Race in progress: nothing is loaded before the finish; it will be used for your next race.',
    "v%s : pas d'essai pendant la course (rien n'est chargé avant l'arrivée) ; validez-la pour votre prochaine course.":
        'v%s: no trial during the race (nothing is loaded before the finish); validate it for your next race.',
    "Affinage course lancé : SetupLab analyse vos tours de course (trafic et incidents compris) et calcule le setup à l'arrivée, pour votre prochaine course. Rien n'est chargé pendant la course.":
        'Race refinement started: SetupLab analyses your race laps (traffic and incidents included) and computes the setup at '
        'the finish, for your next race. Nothing is loaded during the race.',
    # versions
    'Valider%s · pour la prochaine course': 'Validate%s · for the next race',
    'Valider · pour la prochaine course': 'Validate · for the next race',
    'Valider pour la prochaine course': 'Validate for the next race',
    "Enregistre tout de suite %s.ini (réglages gardés), pour votre prochaine course : rien n'est chargé pendant la course. Il devient le setup de référence de la course sur ce circuit, gardé en mémoire.":
        'Saves %s.ini right away (kept settings), for your next race: nothing is loaded during the race. It becomes the race '
        'reference setup on this track, kept in memory.',
    "SetupLab continue d'analyser vos tours de course (%s) ; elle vous sera proposée à l'arrivée, pour votre prochaine course. Rien n'est chargé pendant la course.":
        'SetupLab keeps analysing your race laps (%s); it will be offered to you at the finish, for your next race. Nothing is '
        'loaded during the race.',
    # ligne « Actif » de l'en-tête
    "Actif : v%s en préparation (%s, %s) — proposée à l'arrivée.": 'Active: v%s in preparation (%s, %s) — offered at the finish.',
    'Actif : v%s pour votre prochaine course (%s) — à valider, ou recommencer.':
        'Active: v%s for your next race (%s) — validate it, or start over.',
    'Actif : v%s validée (%s) — pour votre prochaine course.': 'Active: v%s validated (%s) — for your next race.',
    # carte d'étape
    'Séance de course · Affiner pendant la course': 'Race session · Refine during the race',
    'Affiner pendant la course': 'Refine during the race',
    "SetupLab part du setup qui est dans la voiture et analyse vos tours de course, trafic et incidents compris. Il calcule le setup à l'arrivée, d'après toute la course, pour votre prochaine course. Rien n'est chargé pendant la course.":
        'SetupLab starts from the setup in the car and analyses your race laps, traffic and incidents included. It computes the '
        'setup at the finish, from the whole race, for your next race. Nothing is loaded during the race.',
    "SetupLab part du setup qui est dans la voiture et analyse vos tours de course, trafic et incidents compris. Il calcule le setup à l'arrivée, d'après toute la course, pour votre prochaine course. Rien n'est chargé pendant la course. À faire : %s.":
        'SetupLab starts from the setup in the car and analyses your race laps, traffic and incidents included. It computes the '
        'setup at the finish, from the whole race, for your next race. Nothing is loaded during the race. To do: %s.',
    "Lance l'affinage du setup de course sur cette course : un setup proposé à l'arrivée, d'après vos tours de course.":
        'Starts refining the race setup on this race: a setup offered at the finish, based on your race laps.',
    "Enregistrée : %s, pour votre prochaine course. Continuer l'affinage, ou la figer ?":
        'Saved: %s, for your next race. Carry on refining, or lock it?',
    'Course · v%s provisoire': 'Race · v%s provisional',
    'v%s provisoire': 'v%s provisional',
    "Gain prévu %s s, d'après %s. SetupLab la recalcule à l'arrivée, d'après toute la course, pour votre prochaine course. Rien n'est chargé pendant la course.":
        'Predicted gain %s s, based on %s. SetupLab computes it again at the finish, from the whole race, for your next race. '
        'Nothing is loaded during the race.',
    'Course terminée · %s pour votre prochaine course': 'Race finished · %s for your next race',
    '%s pour votre prochaine course': '%s for your next race',
    "Gain prévu %s s, d'après %s. Pour refuser un réglage : « Modifier… » ; puis Valider : le fichier est enregistré pour votre prochaine course.":
        'Predicted gain %s s, based on %s. To refuse one setting: "Modify…"; then Validate: the file is saved for your next race.',
    'v%s validée · pour votre prochaine course': 'v%s validated · for your next race',
    'pour votre prochaine course': 'for your next race',
    "Enregistrée : %s. Rien n'est chargé pendant la course : chargez-la au stand avant votre prochaine course.":
        'Saved: %s. Nothing is loaded during the race: load it in the pits before your next race.',
    'Course · analyse de vos tours': 'Race · analysing your laps',
    'analyse de vos tours': 'analysing your laps',
    # overlay
    "Proposée à l'arrivée, pour votre prochaine course.": 'Offered at the finish, for your next race.',
    'v%s : %s s prévu, onglet COURSE : Valider pour votre prochaine course':
        'v%s: %s s predicted, RACE tab: Validate for your next race',
    "proposée à l'arrivée": 'offered at the finish',
    'onglet COURSE : Valider': 'RACE tab: Validate',
    "v%s vous sera proposée à l'arrivée, pour votre prochaine course.": 'v%s will be offered to you at the finish, for your next race.',
    'Course terminée : onglet COURSE, validez v%s pour votre prochaine course.':
        'Race finished: RACE tab, validate v%s for your next race.',
    # calcul à l'arrivée
    "analyse de vos tours de course : le setup sera calculé à l'arrivée":
        'analysing your race laps: the setup will be computed at the finish',
    'arrivée : enregistrement de votre dernier tour, puis calcul du setup':
        'finish: recording your last lap, then computing the setup',
    'SetupLab actif : départ de la course choisi': 'SetupLab active: race start chosen',
    "Setup changé dans le menu de setup : SetupLab le relit, l'affinage de la course part de lui.":
        'Setup changed in the setup menu: SetupLab reads it again, the race refinement starts from it.',
    'Séance de course : setup changé dans le menu de setup, nouvelle découverte':
        'Race session: setup changed in the setup menu, new discovery',
    # arrivée : calcul du setup de course
    'Course terminée · calcul du setup de course': 'Race finished · computing the race setup',
    'calcul du setup de course': 'computing the race setup',
    "SetupLab calcule le setup de cette course, d'après %s : %s %. Il vous sera annoncé dès qu'il est prêt, pour votre prochaine course.":
        'SetupLab is computing the setup of this race, based on {1}: {2} %. It will be announced as soon as it is ready, for '
        'your next race.',
    "SetupLab calcule le setup de cette course : %s %. Il vous sera annoncé dès qu'il est prêt, pour votre prochaine course.":
        'SetupLab is computing the setup of this race: %s %. It will be announced as soon as it is ready, for your next race.',
    "calcul du setup de course à l'arrivée": 'race setup computed at the finish',
    "Calcul de l'affinage": 'Refinement computation',
    # journal
    'Séance de course : avant le départ': 'Race session: before the start',
    'Séance de course : course lancée': 'Race session: race started',
    'Séance de course : arrivée': 'Race session: finished',
    # fenêtre en piste
    'SetupLab est ouvert dans le menu de setup ; cette fenêtre reprend en piste.':
        'SetupLab is open in the setup menu; this window takes over on track.',
    'Enregistré pour votre prochaine course : %s': 'Saved for your next race: %s',
    # panneau de course (rendu de repli)
    'Le setup de course part du setup en place': 'The race setup starts from the setup in the car',
    "Course en cours : le setup de course part du setup qui est dans la voiture et vos tours de course, trafic compris, donnent le rythme ; rien n'est chargé avant l'arrivée.":
        'Race in progress: the race setup starts from the setup in the car and your race laps, traffic included, give the '
        'pace; nothing is loaded before the finish.',
    "Séance de course : le setup de course part du setup qui est dans la voiture (ou de la qualification de votre choix, avant le départ) et vos tours de course, trafic compris, donnent le rythme.":
        'Race session: the race setup starts from the setup in the car (or from the qualifying version of your choice, '
        'before the start) and your race laps, traffic included, give the pace.',
    # aide intégrée
    'Pendant une course': 'During a race',
    "Sur la grille : « SetupLab Track » (barre d'apps CSP), onglet COURSE, « Affiner pendant la course ». SetupLab part du setup en place et analyse vos tours, trafic compris ; il propose le setup à l'arrivée, pour la prochaine course.":
        'On the grid: "SetupLab Track" (CSP app bar), RACE tab, "Refine during the race". SetupLab starts from the setup in the '
        'car and analyses your laps, traffic included; it offers the setup at the finish, for the next race.',
    "Pendant une course (départ sur la grille) : ouvrez « SetupLab Track » depuis la barre d'apps de CSP ; onglet COURSE, « Affiner pendant la course ». SetupLab part du setup qui est dans la voiture et analyse vos tours de course, trafic compris (jamais pour la calibration). Rien n'est chargé pendant la course ; à l'arrivée, il vous propose le setup de cette course : validez-le pour la prochaine.":
        'During a race (start on the grid): open "SetupLab Track" from the CSP app bar; RACE tab, "Refine during the race". '
        'SetupLab starts from the setup in the car and analyses your race laps, traffic included (never for the calibration). '
        'Nothing is loaded during the race; at the finish, it offers you the setup of this race: validate it for the next one.',
}
