# Dictionnaire de l'interface : texte français du code -> anglais (décision de Vincent du 26/10/2026).
# « %s » : trou (nombre, nom, phrase imbriquée traduite à son tour) ; « {1} », « {2} » pour changer l'ordre.
# Les entrées sont rangées par module dans tests/tools/lang/*.py (chacun définit un dict EN) ; ce fichier les réunit.
# Généré en src/lang_en.lua par tests/tools/gen_lang.py ; la complétude est vérifiée par tests/test_i18n.lua.
from pathlib import Path

EN = {}
for _part in sorted((Path(__file__).resolve().parent / 'lang').glob('*.py')):
    _scope = {}
    exec(compile(_part.read_text(encoding='utf-8'), str(_part), 'exec'), _scope)
    for _k, _v in _scope['EN'].items():
        if _k in EN and EN[_k] != _v:
            raise ValueError('traduction en double, différente : %r (%s)' % (_k, _part.name))
        EN[_k] = _v
