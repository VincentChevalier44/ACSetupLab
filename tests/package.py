"""Empaquetage de SetupLab (J8) : archive zip de l'app distribuable, sans le banc d'essai.

Le dossier tests/ contient des données de mods tiers (dont un mod commercial) : il n'est JAMAIS
distribué. Le script refuse d'écrire l'archive si un fichier hors de la liste blanche s'y glisse, si la
version du manifeste diffère de celle de config.lua, ou si un fichier distribué contient un appel
interdit (§16.2).

Usage : python -I tests/package.py            -> dist/SetupLab-<version>.zip et son empreinte SHA-256
"""
from pathlib import Path
import hashlib
import re
import sys
import zipfile

APP = Path(__file__).resolve().parent.parent
DIST = APP / 'dist'

# Liste blanche : fichiers et dossiers distribués (tout le reste est exclu).
FILES = ['SetupLab.lua', 'manifest.ini', 'icon.png', 'README.md', 'CHANGELOG.md']
DIRS = {'src': ('.lua',), 'docs': ('.md', '.html')}
# os.preciseClock (horloge officielle de CSP) : seule exception, accord de Vincent du 29/10/2026
FORBIDDEN = re.compile(r'\b(os\.(?!preciseClock\b)\w+|loadstring|dofile|web\.\w+)\s*\(')


def version_of_config():
    text = (APP / 'src' / 'config.lua').read_text(encoding='utf-8')
    m = re.search(r"M\.version = '([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?)'", text)
    if not m:
        sys.exit('version introuvable dans src/config.lua')
    return m.group(1)


def version_of_manifest():
    text = (APP / 'manifest.ini').read_text(encoding='utf-8')
    m = re.search(r'^VERSION=([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?)\s*$', text, re.M)
    if not m:
        sys.exit('VERSION introuvable dans manifest.ini')
    return m.group(1)


def collect():
    out = []
    for name in FILES:
        path = APP / name
        if not path.is_file():
            sys.exit(f'fichier manquant : {name}')
        out.append(path)
    for folder, suffixes in DIRS.items():
        for path in sorted((APP / folder).rglob('*')):
            if path.is_file():
                if path.suffix not in suffixes or '__pycache__' in path.parts:
                    sys.exit(f'fichier inattendu dans {folder}/ : {path.name}')
                out.append(path)
    return out


def main():
    version = version_of_config()
    if version_of_manifest() != version:
        sys.exit(f'versions différentes : config.lua {version}, manifest.ini {version_of_manifest()}')
    files = collect()
    for path in files:
        rel = path.relative_to(APP).as_posix()
        if rel.startswith('tests/') or rel.startswith('dist/'):
            sys.exit(f'refusé : {rel} ne doit jamais être distribué')
        if path.suffix == '.lua':
            text = path.read_text(encoding='utf-8')
            # commentaires retirés avant la recherche d'appels interdits
            code = re.sub(r'--\[\[.*?\]\]', '', text, flags=re.S)
            code = re.sub(r'--[^\n]*', '', code)
            hit = FORBIDDEN.search(code)
            if hit:
                sys.exit(f'appel interdit (§16.2) dans {rel} : {hit.group(0)}')
    DIST.mkdir(exist_ok=True)
    target = DIST / f'SetupLab-{version}.zip'
    if target.exists():
        sys.exit(f'{target.name} existe déjà : jamais d\'écrasement (changer de version)')
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as z:
        for path in files:
            z.write(path, 'SetupLab/' + path.relative_to(APP).as_posix())
    with zipfile.ZipFile(target) as z:
        names = z.namelist()
    if any('/tests/' in n or n.endswith('.py') for n in names):
        target.unlink()
        sys.exit('archive refusée : banc d\'essai présent')
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    (DIST / f'SetupLab-{version}.sha256').write_text(f'{digest}  {target.name}\n', encoding='utf-8')
    print(f'{target} : {len(names)} fichiers, {target.stat().st_size} octets, SHA-256 {digest}')


if __name__ == '__main__':
    main()
