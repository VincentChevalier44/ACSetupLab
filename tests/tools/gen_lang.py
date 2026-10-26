"""Génère src/lang_en.lua (dictionnaire français -> anglais de l'interface) depuis tests/tools/lang_en.py.

Usage : python -I tests/tools/gen_lang.py
Les clés sont les textes français du code ; « %s » marque un trou (nombre, nom de fichier, phrase imbriquée). Une
valeur anglaise peut réordonner les trous avec « {1} », « {2} »… Chaînes longues Lua [==[ ]==] : aucun échappement.
"""
import importlib.util
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = HERE.parent.parent


def load():
    spec = importlib.util.spec_from_file_location('lang_en', HERE / 'lang_en.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.EN


def check(en):
    problems = []
    for fr, value in en.items():
        if ']==]' in fr or ']==]' in value:
            problems.append(f'délimiteur interdit : {fr!r}')
        holes = fr.count('%s')
        if '{1}' in value:
            # trous omis permis (marques du pluriel français) ; jamais un trou qui n'existe pas
            for n in re.findall(r'{(\d)}', value):
                if int(n) > holes:
                    problems.append(f'trou {{{n}}} inexistant : {fr!r}')
        elif value.count('%s') != holes:
            problems.append(f'trous différents ({holes} / {value.count("%s")}) : {fr!r}')
        if fr.startswith('\n') or value.startswith('\n'):
            problems.append(f'saut de ligne en tête : {fr!r}')
    return problems


def render(en):
    lines = ['-- Généré par tests/tools/gen_lang.py depuis tests/tools/lang_en.py : ne pas modifier à la main.',
             '-- Interface en anglais (décision de Vincent du 26/10/2026) : texte français du code -> texte anglais.',
             'return {']
    for fr in sorted(en):
        lines.append('  [ [==[%s]==] ] = [==[%s]==],' % (fr, en[fr]))
    lines.append('}')
    return '\n'.join(lines) + '\n'


def stale():
    """Problèmes du dictionnaire, ou src/lang_en.lua différent de ce qu'il doit être (banc : jamais livré périmé)."""
    en = load()
    problems = check(en)
    target = APP / 'src' / 'lang_en.lua'
    current = target.read_text(encoding='utf-8') if target.exists() else ''
    if current.replace('\r\n', '\n') != render(en):
        problems.append('src/lang_en.lua périmé : lancer python -I tests/tools/gen_lang.py')
    return problems


def main():
    en = load()
    problems = check(en)
    if problems:
        print('\n'.join(problems))
        sys.exit(1)
    (APP / 'src' / 'lang_en.lua').write_text(render(en), encoding='utf-8')
    print(len(en), 'entrées')


if __name__ == '__main__':
    main()
