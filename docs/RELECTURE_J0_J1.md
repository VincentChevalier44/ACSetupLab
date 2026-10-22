# Relecture adversariale — jalons J0 + J1 (§0.4, §18)

Le 19/10/2026, un relecteur indépendant a relu SetupLab 0.1.0 en lecture seule. Il a vérifié les appels CSP contre `lib.lua` et lancé ses propres sondes.

**Conformité au SDK** : aucun écart de signature, d'ordre d'arguments, d'indexation ou d'unité sur les fonctions et champs utilisés. Les lignes du SDK concernées sont listées dans `API_NOTES.md` §1.

Les 14 constats ci-dessous ont tous été traités. Une campagne de mutations a contrôlé chaque correction : on annule la correction dans une copie isolée, et le test indiqué doit échouer. **11 mutations sur 11 ont été détectées.**

| # | Gravité | Constat | Résolution | Test |
|---|---|---|---|---|
| 1 | Majeur | Boucle non validée. Aucune app installée n'utilise `[SIM_CALLBACKS]` ; ACAdvancedIA, validée en jeu, définit aussi `script.update`. | Les deux points d'entrée sont déclarés. La boucle se verrouille sur la première source qui l'appelle, et bascule si celle-ci se tait pendant 30 appels de l'autre. Exactement une tranche par frame. La source retenue figure dans la fenêtre debug et dans le rapport J0 (arbitrage A10). | A14 |
| 2 | Majeur | `trim` quadratique : 40 000 espaces gelaient le jeu de 3,9 à 6,9 s. | `trim` linéaire par recherches simples. La correction proposée (`^%s*(.*%S)`) restait quadratique sur une chaîne faite uniquement de blancs, comme les motifs `^%s*([^|]+)|…` sur une ligne sans `|`. Les analyseurs INI, LUT et RTO découpent donc par recherche en texte brut, et les lignes sont bornées à 4 096 caractères. | U16 (< 50 ms par cas pathologique) |
| 3 | Majeur | Cohérence crans ↔ fichier vraie malgré des crans absents du fichier, par exemple `GEAR_n` contre `INTERNAL_GEAR_n`. | Un réglage visible et modifiable absent du fichier empêche la cohérence : statut « à confirmer », et pas d'écriture directe. L'hôte simulé reproduit désormais les encodages constatés : crans entiers, carrossage en dixièmes, numéros de cran, noms de boîte décalés. | D08, K06 |
| 4 | Majeur | Une liste de fichiers vide, cas d'échec documenté du SDK, menait à zéro INI lu. | Liste vide traitée comme inconnue : la liste de base est utilisée. | D04 |
| 5 | Majeur | Le linter ne voyait pas les accès par nom en texte (`Util.get(h.ac, 'loadSetup')`, `h.io['save']`…). | Toute chaîne littérale égale à un nom interdit, ou finissant par `.nom`, est contrôlée. Seule exception : le registre `caps.lua`. | 4 auto-tests du linter (26/26) |
| 6 | Majeur | Le contexte se réduisait à voiture et circuit (§5.2). | Une clé de conditions par paliers (session, pluie, ±2 °C air et piste, grip à 1 %) marque les résultats « périmés » sans relancer. Un changement de voiture ou de circuit relance la découverte. | D13, A17 |
| 7 | Mineur | Rapport perdu après un replay survenu pendant sa construction. | Rapport reprogrammé dès que le contexte le permet. | A16 |
| 8 | Mineur | Garde en ligne / replay en échec ouvert : un drapeau illisible laissait l'app active. | Drapeau illisible : app inerte (§0.6). Un nombre différent de zéro (`uint8_t`) vaut vrai. | D13 |
| 9 | Mineur | Repli sans horloge : le quota comptait les `tick`, pas les coûts. | Un appel CSP pèse `tickWeightApiCall` (25) dans le quota. | U17 |
| 10 | Mineur | Unités longues sans point de rendu (lecture des LUT, repli texte). | Un `tick` tous les 256 points de LUT et après chaque appel CSP ; `tick` tous les 64 lignes dans `parseLutText` et `parseRto`. | Mesures A02 |
| 11 | Mineur | Circuit ouvert (A-B) : `p = i/n` n'atteignait jamais 1. | `p = i/(n−1)` pour un tracé ouvert. | D09 |
| 12 | Mineur | Un rapport de boîte illisible décalait les suivants. | Indexation par position et nombre de rapports conservé. | D07 |
| 13 | Mineur | Le banc surestimait ce qu'il prouve. | Ajout du test du chemin réel de déchargement (`ac.onRelease`, A15). A02 documente l'exclusion de la découverte de chauffe. Le coût de la première découverte, de l'appel CSP le plus long et des tranches au-delà de 3 ms est mesuré **en jeu** et rapporté au J0. Le coût de l'interface n'est mesuré qu'avec une interface simulée. | A02, A15 |
| 14 | Mineur | Valeurs chiffrées en dur (§0.1). | Déplacées dans `Config.K` : seuils du circuit, lissage, longueur du journal, nombre de rapports. Les limites de format du texte sont regroupées dans `Util.LIMITS` (ce ne sont pas des valeurs du PDR). | — |
| hors code | — | README et CHANGELOG présentaient le J0 comme clos. | Corrigé : lecture du SDK et outil de découverte livrés, **observations en jeu en attente**. | — |

## Mesures après correction (banc hors jeu, LuaJIT 2.1)

- **Tests** : 62, 0 échec. Linter : 0 erreur ; auto-tests du linter : 26/26.
- **Tranches** (A02) : médiane 2,0 ms, 99ᵉ centile 2,05 à 2,3 ms, au plus 1 % au-delà de 3 ms, découverte de chauffe exclue. Un à-coup isolé du système a été observé une fois (pic de 25 ms) : c'est un bruit de la machine, absent sur 10 exécutions répétées.
- **Endurance** : 1 000 découvertes enchaînées, sans croissance mémoire significative (moins de 2 Mio).
- Journal des tests joint : `tests/results.json`.
