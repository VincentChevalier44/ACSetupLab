"""Génère src/lang_en.lua (dictionnaire français -> anglais de l'interface) depuis tests/tools/lang_en.py.

Usage : python -I tests/tools/gen_lang.py
Les clés sont les textes français du code ; « %s » marque un trou (nombre, nom de fichier, phrase imbriquée). Une
valeur anglaise peut réordonner les trous avec « {1} », « {2} »… Chaînes longues Lua [==[ ]==] : aucun échappement.
"""
import importlib.util
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
            for n in range(1, holes + 1):
                if '{%d}' % n not in value:
                    problems.append(f'trou {{{n}}} absent : {fr!r}')
        elif value.count('%s') != holes:
            problems.append(f'trous différents ({holes} / {value.count("%s")}) : {fr!r}')
        if fr.startswith('\n') or value.startswith('\n'):
            problems.append(f'saut de ligne en tête : {fr!r}')
    return problems


def main():
    en = load()
    problems = check(en)
    if problems:
        print('\n'.join(problems))
        sys.exit(1)
    lines = ['-- Généré par tests/tools/gen_lang.py depuis tests/tools/lang_en.py : ne pas modifier à la main.',
             '-- Interface en anglais (décision de Vincent du 26/10/2026) : texte français du code -> texte anglais.',
             'return {']
    for fr in sorted(en):
        lines.append('  [ [==[%s]==] ] = [==[%s]==],' % (fr, en[fr]))
    lines.append('}')
    (APP / 'src' / 'lang_en.lua').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print(len(en), 'entrées')


if __name__ == '__main__':
    main()
