# Mise à jour en jeu (src/updater.lua, colle et interface ; bêta 1.5.3, demande de Vincent du 02/11/2026).
EN = {
    'Mise à jour disponible : %s (installée : %s)': 'Update available: %s (installed: %s)',
    'Mettre à jour': 'Update',
    "Télécharge l'archive de la version %s sur GitHub, vérifie sa taille et son empreinte SHA-256, puis remplace les fichiers de l'app (les fichiers d'avant sont remis en cas d'échec). CSP recharge alors SetupLab, qui revient en veille ; vos réglages, votre mémoire et vos setups sont gardés.":
        "Downloads the version %s archive from GitHub, checks its size and SHA-256 fingerprint, then replaces the app's files (the previous files are put back if anything fails). CSP then reloads SetupLab, which comes back on standby; your settings, memory and setups are kept.",
    'Mise à jour en cours : téléchargement…': 'Updating: downloading…',
    'Mise à jour en cours : installation…': 'Updating: installing…',
    'Mise à jour installée : CSP recharge SetupLab.': 'Update installed: CSP reloads SetupLab.',
    'Mise à jour impossible : %s.': 'Update impossible: %s.',
    'Installez-la à la main depuis %s': 'Install it by hand from %s',
    'Copier le lien': 'Copy the link',
    'Vérifier les mises à jour au lancement (GitHub)': 'Check for updates at launch (GitHub)',
    "Coché : une fois par lancement d'AC, SetupLab lit sur GitHub le numéro de la dernière version publiée. Plus récente : un bouton « Mettre à jour » apparaît ; rien n'est téléchargé ni installé sans votre clic. Aucune donnée de jeu ni personnelle n'est envoyée ; GitHub voit seulement votre adresse IP, comme pour toute page web.":
        'Ticked: once per AC launch, SetupLab reads the number of the latest published version on GitHub. If it is newer, an "Update" button appears; nothing is downloaded or installed without your click. No game or personal data is sent; GitHub only sees your IP address, as for any web page.',
    'Mise à jour %s installée : CSP recharge SetupLab, qui revient en veille.':
        'Update %s installed: CSP reloads SetupLab, which comes back on standby.',
    'Lien de la page de la mise à jour copié.': 'Link to the update page copied.',
    'Copie du lien impossible.': 'Cannot copy the link.',
    "Recherche d'une mise à jour (GitHub)": 'Checking for an update (GitHub)',
    'Mise à jour disponible : %s': 'Update available: %s',
    'SetupLab est à jour (%s)': 'SetupLab is up to date (%s)',
    'Mise à jour non vérifiée : %s': 'Update not checked: %s',
    'Mise à jour vers %s : téléchargement': 'Update to %s: downloading',
    'dossiers inconnus': 'unknown folders',
    'téléchargement impossible (%s)': 'download impossible (%s)',
    'taille du téléchargement inattendue': 'unexpected download size',
    "empreinte SHA-256 différente, rien n'est installé": 'different SHA-256 fingerprint, nothing is installed',
    'archive illisible': 'unreadable archive',
    'archive trop grande': 'archive too large',
    'fichier hors du dossier SetupLab': 'file outside the SetupLab folder',
    "chemin refusé dans l'archive": 'path refused in the archive',
    'archive incomplète': 'incomplete archive',
    'version du manifeste différente': 'different manifest version',
    'extraction impossible (%s)': 'extraction impossible (%s)',
    'extraction refusée': 'extraction refused',
    'requête refusée': 'request refused',
    'copie de sauvegarde impossible (%s)': 'backup copy impossible (%s)',
    "écriture refusée dans le dossier de l'app (%s), fichiers d'avant remis":
        "writing refused in the app folder (%s), previous files put back",
    'réponse illisible': 'unreadable response',
    'version illisible': 'unreadable version',
    'adresse du téléchargement inattendue': 'unexpected download address',
    'empreinte SHA-256 illisible': 'unreadable SHA-256 fingerprint',
    'taille illisible': 'unreadable size',
    'sans réponse': 'no response',
    'EN VEILLE': 'STANDBY',
    'Mise à jour : au stand, voiture arrêtée (CSP recharge SetupLab juste après).':
        'Update: in the pits, car stopped (CSP reloads SetupLab right after).',
    'Réessayer': 'Try again',
    'Mise à jour impossible : %s. Réinstallez SetupLab à la main depuis %s.':
        'Update impossible: %s. Reinstall SetupLab by hand from %s.',
    "écriture refusée dans le dossier de l'app (%s), installation mélangée":
        'writing refused in the app folder (%s), mixed installation',
    'contrôle des fichiers impossible': 'cannot check the files',
    'fichier utilisé par le jeu (%s)': 'file in use by the game (%s)',
    'dossier de sauvegarde impossible': 'cannot create the backup folder',
    "dossier de l'app inattendu": 'unexpected app folder',
    'extraction incomplète (%s)': 'incomplete extraction (%s)',
    'voiture replacée sur la piste': 'car reset on track',
    'choc (dégâts)': 'impact (damage)',
    'coupe de piste': 'track cut',
    'tête-à-queue': 'spin',
    'blocage de roue': 'wheel lock-up',
    'grosse glissade': 'big slide',
    'AU STAND': 'IN THE PITS',
    'EN PISTE': 'ON TRACK',
    'Empreinte SHA-256 de CSP : ok': 'CSP SHA-256 fingerprint: ok',
    'Empreinte SHA-256 de CSP : valeur inattendue (%s)': 'CSP SHA-256 fingerprint: unexpected value (%s)',
    # aide intégrée (onglet AIDE)
    '1. Départ : choisissez de quel setup partir : votre setup actuel (celui qui est dans la voiture, le vôtre ou celui par défaut), le setup par défaut de la voiture, ou votre référence validée sur ce circuit. Le choix active SetupLab et met ce setup dans la voiture.':
        "1. Start: choose which setup to start from: your current setup (the one in the car, yours or the default one), the car's default setup, or your validated reference on this track. Choosing activates SetupLab and puts that setup in the car.",
    "3. Essayer : « Essayer vN » met la version dans la voiture, en un clic, au stand ; son fichier d'essai part à la Corbeille. Roulez avec. « Recommencer » remet le setup d'avant.":
        '3. Try: "Try vN" puts the version in the car, in one click, in the pits; its trial file goes to the Recycle Bin. Drive with it. "Start over" puts the previous setup back.',
    "4. Valider : « Valider vN » la garde telle quelle ; « Modifier… » pour refuser un réglage précis (par exemple l'aileron arrière) et garder le reste, la version gardée allant dans la voiture. Elle devient votre référence pour ce circuit. SetupLab demande ensuite, à chaque fois : continuer l'affinage (à partir d'elle) ou la figer.":
        '4. Validate: "Validate vN" keeps it as it is; "Modify…" to refuse one particular setting (for example the rear wing) and keep the rest, the kept version going into the car. It becomes your reference for this track. SetupLab then asks, every time: carry on refining (from it) or lock it.',
    "Le setup de course part d'une de vos qualifs validées sur ce circuit (v1, v2…, même d'un lancement d'AC précédent) : « Partir de la qualif vN » la met dans la voiture et lance l'affinage de la course, en un clic ; « Reprendre ma course vN » reprend une course validée. Saisissez le nombre de tours de la course (onglet COURSE).":
        'The race setup starts from one of your validated qualifying versions on this track (v1, v2…, including from an earlier AC launch): "Start from qualifying vN" puts it in the car and starts the race refinement, in one click; "Resume my race vN" resumes a validated race. Enter the number of race laps (RACE tab).',
    'Mise à jour': 'Update',
    "Une fois par lancement d'AC, SetupLab regarde sur GitHub si une version plus récente est publiée (réglage dans l'onglet RÉGLAGES). Si oui, « Mettre à jour », en haut de la fenêtre, l'installe en un clic, après avoir vérifié l'archive ; CSP recharge alors SetupLab. Aucune donnée de jeu ni personnelle n'est envoyée ; GitHub voit seulement votre adresse IP, comme pour toute page web.":
        'Once per AC launch, SetupLab checks on GitHub whether a newer version is published (setting in the SETTINGS tab). If so, "Update", at the top of the window, installs it in one click, after checking the archive; CSP then reloads SetupLab. No game or personal data is sent; GitHub only sees your IP address, as for any web page.',
}
