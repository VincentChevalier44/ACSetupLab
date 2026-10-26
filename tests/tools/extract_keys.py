"""Clés du dictionnaire anglais tirées du code : chaque chaîne de concaténation Lua qui contient du texte français
devient un modèle (« %s » à la place de chaque morceau calculé) ; les textes simples, des clés exactes.

Usage : python -I tests/tools/extract_keys.py [--missing]
  sans option : toutes les clés, par module ; --missing : celles absentes de tests/tools/lang_en.py.
"""
import importlib.util
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = HERE.parent.parent

FRENCH_CHARS = re.compile('[àâäçéèêëîïôöùûüœÀÂÉÈÊÎÔÙÛÇ«»]')
FRENCH_WORDS = re.compile(r"\b(le|la|les|des|du|de|et|un|une|pour|avec|sur|au|aux|est|pas|ou|dans|votre|vos|en|à|non|"
                          r"tour|tours|réglage|réglages|calcul|setup|piste|voiture|pneus|essai|course|sec|pluie|oui|"
                          r"Calcul|Tour|Setup|Piste|Voiture|Pneus|Essai|Course|Réglages|Mesure|Composé|Moteur|Freins|"
                          r"Carburant|Aéro|Aides|Autres|Suspension|Transmission|Géométrie|inchangé|conservé|optimisé|"
                          r"modélisé|règle|choisi|disponible|indisponible|Disponible|Indisponible|Langue|Relancer|Copier|"
                          r"Annuler|Charger|Valider|Essayer|Figer|Déverrouiller|Libérer|Recommencer|Arrêter|Confirmer|"
                          r"Enregistrer|Calibrer|Mesurer|Rouler|Gardé|Refusé|actif|arrêté|analysé|prête|prêt)\b")
SPEC = re.compile(r'%[-+#0]*\d*(?:\.\d+)?[dfisxgq]')
BOUNDARY = {',', '=', 'and', 'or', 'then', 'do', 'return', 'local', 'if', 'elseif', 'else', 'end', '==', '~=', '<', '>', '<=',
            '>=', 'not', 'function', 'while', 'for', 'in', 'repeat', 'until', ';'}
OPEN = {'(': ')', '{': '}', '[': ']'}


def tokenize(src):
    tokens, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c in ' \t\r\n':
            i += 1
        elif src.startswith('--', i):
            m = re.match(r'--\[(=*)\[', src[i:])
            if m:
                end = src.index(']' + m.group(1) + ']', i)
                i = end + len(m.group(1)) + 2
            else:
                j = src.find('\n', i)
                i = n if j < 0 else j
        elif c in '\'"':
            j, buf = i + 1, []
            while src[j] != c:
                if src[j] == '\\':
                    e = src[j + 1]
                    buf.append({'n': '\n', 't': '\t', '\\': '\\', "'": "'", '"': '"'}.get(e, e))
                    j += 2
                else:
                    buf.append(src[j])
                    j += 1
            tokens.append(('str', ''.join(buf)))
            i = j + 1
        elif c == '[' and re.match(r'\[=*\[', src[i:]):
            m = re.match(r'\[(=*)\[', src[i:])
            start = i + len(m.group(0))
            end = src.index(']' + m.group(1) + ']', start)
            text = src[start:end]
            if text.startswith('\n'):
                text = text[1:]
            tokens.append(('str', text))
            i = end + len(m.group(1)) + 2
        elif c.isalpha() or c == '_':
            m = re.match(r'[A-Za-z_][A-Za-z_0-9]*', src[i:])
            tokens.append(('name', m.group(0)))
            i += len(m.group(0))
        elif c.isdigit():
            m = re.match(r'0x[0-9a-fA-F]+|\d+(\.\d+)?([eE][-+]?\d+)?', src[i:])
            tokens.append(('num', m.group(0)))
            i += len(m.group(0))
        else:
            for op in ('...', '..', '==', '~=', '<=', '>=', '::'):
                if src.startswith(op, i):
                    tokens.append(('op', op))
                    i += len(op)
                    break
            else:
                tokens.append(('op', c))
                i += 1
    return tokens


def looks_french(s):
    return bool(FRENCH_CHARS.search(s) or FRENCH_WORDS.search(s))


def chains(tokens):
    """Chaînes de concaténation : listes de segments (chaque segment : liste de jetons)."""
    out = []
    stack = [[[[]]]]  # par profondeur : chaîne courante = liste de segments

    def finish(level):
        chain = level[-1]
        segs = [s for s in chain if s]
        if segs:
            out.append(segs)
        level[-1] = [[]]

    for kind, value in tokens:
        level = stack[-1]
        if kind == 'op' and value in OPEN:
            level[-1][-1].append((kind, value))
            stack.append([[[]]])
        elif kind == 'op' and value in (')', '}', ']'):
            finish(stack[-1])
            if len(stack) > 1:
                stack.pop()
            stack[-1][-1][-1].append((kind, value))
        elif kind == 'op' and value == '..':
            level[-1].append([])
        elif (kind in ('op', 'name') and value in BOUNDARY):
            finish(level)
        else:
            # deux expressions juxtaposées : nouvelle instruction (« x = 'a' .. b  log() »)
            seg = level[-1][-1]
            if kind == 'name' and seg and (seg[-1][0] in ('str', 'num', 'name') or seg[-1][1] in (')', ']', '}')):
                finish(level)
            level[-1][-1].append((kind, value))
    for level in stack:
        finish(level)
    return out


def template(segs):
    parts, french = [], False
    for seg in segs:
        if len(seg) == 1 and seg[0][0] == 'str':
            text = seg[0][1]
            french = french or looks_french(text)
            parts.append(text.replace('%s', '\x00'))
        else:
            parts.append('\x00')
    if not french:
        return None
    key = ''.join(parts)
    key = SPEC.sub('%s', key.replace('\x00', '%s'))
    key = re.sub(r'(%s)+', '%s', key)
    key = key.lstrip('\n')
    if key.strip() in ('', '%s'):
        return None
    return key


def keys_of(path):
    seen, order = set(), []
    for segs in chains(tokenize(path.read_text(encoding='utf-8'))):
        k = template(segs)
        if k and k not in seen:
            seen.add(k)
            order.append(k)
    return order


def files():
    return [APP / 'SetupLab.lua', *sorted(p for p in (APP / 'src').glob('*.lua') if p.name != 'lang_en.lua')]


def known():
    spec = importlib.util.spec_from_file_location('lang_en', HERE / 'lang_en.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.EN


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    missing = '--missing' in sys.argv
    en = known() if missing else {}
    total = 0
    for path in files():
        keys = [k for k in keys_of(path) if k not in en]
        if not keys:
            continue
        print('    # ' + '-' * 20 + ' ' + path.name)
        for k in keys:
            print('    %r: %r,' % (k, ''))
        total += len(keys)
    print('# total', total, file=sys.stderr)


if __name__ == '__main__':
    main()
