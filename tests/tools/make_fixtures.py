"""Génère les jeux de données de référence du banc hors jeu (§14.2) depuis l'installation AC.

Lecture seule de l'installation. Seules des voitures à données ouvertes (dossier data/) sont
utilisées : les fichiers data.acd ne sont jamais lus ni déchiffrés.

Sorties (tests/fixtures/) :
- cars/<id>.lua   : { id, name, files = { ['nom'] = [[texte brut]] } } (INI, LUT, RTO)
- tracks/<id>.lua : { id, layout, name, declared = 'texte ui_track.json', points = 'x y z s g d\\n…',
                      files = { ['surfaces.ini'] = …, ['drs_zones.ini'] = … } }
  où g/d sont les distances aux bords gauche/droit, puis v la vitesse de l'IA (m/s), r le rayon (m) et
  c le dévers (rad), lus dans fast_lane.ai (format v7). v, r et c servent de références indépendantes.

Usage : python -I tests/tools/make_fixtures.py [racine_assettocorsa]
"""
from pathlib import Path
import json
import struct
import sys

APP = Path(__file__).resolve().parents[2]
OUT = APP / 'tests' / 'fixtures'

CARS = [
    ('formula_k', 'sdk/dev/content/cars/formula_k/data'),
    ('lamborghini_huracan_gt3_evo2', 'content/cars/lamborghini_huracan_gt3_evo2/data'),
    ('urd_px1_aura', 'content/cars/urd_px1_aura/data'),
    ('whk_dtm_2026', 'content/cars/whk_dtm_2026/data'),
]
TRACKS = [
    # (identifiant fixture, dossier circuit, disposition ou '')
    ('spa', 'spa', ''),
    ('monza', 'monza', ''),
    ('ks_red_bull_ring-layout_gp', 'ks_red_bull_ring', 'layout_gp'),
    ('ks_nordschleife-nordschleife', 'ks_nordschleife', 'nordschleife'),
]
# Fichiers INI purement visuels ou sonores : inutiles au calcul.
SKIP_INI = {
    'ambient_shadows.ini', 'analog_instruments.ini', 'blurred_objects.ini', 'cameras.ini', 'colliders.ini',
    'dash_cam.ini', 'digital_instruments.ini', 'driver3d.ini', 'flame_presets.ini', 'flames.ini',
    'lights.ini', 'lods.ini', 'mirrors.ini', 'proview_nodes.ini', 'sounds.ini', 'suspension_graphics.ini',
    'wing_animations.ini', 'digital_panels.ini', 'extension.ini',
}


def long_string(data: bytes) -> bytes:
    level = 0
    while (b']' + b'=' * level + b']') in data:
        level += 1
    eq = b'=' * level
    return b'[' + eq + b'[\n' + data + b']' + eq + b']'


def lua_key(name: str) -> bytes:
    return b"['" + name.encode('ascii') + b"']"


def car_fixture(root: Path, car_id: str, rel: str) -> bytes:
    folder = root / rel
    files = {}
    for path in sorted(folder.iterdir()):
        name = path.name.lower()
        # Noms en minuscules (AC ignore la casse sous Windows) ; premier fichier conservé.
        if not path.is_file() or name in files or not name.isascii():
            continue
        if name.endswith('.ini') and name not in SKIP_INI and 'copy' not in name and "'" not in name:
            files[name] = path.read_bytes()
        elif name.endswith('.lut') or name.endswith('.rto'):
            files[name] = path.read_bytes()
    ui = folder.parent / 'ui' / 'ui_car.json'
    display = car_id
    if ui.exists():
        try:
            display = json.loads(ui.read_text(encoding='utf-8-sig', errors='replace')).get('name', car_id)
        except json.JSONDecodeError:
            pass
    parts = [b'-- Jeu de donnees genere par tests/tools/make_fixtures.py (ne pas modifier a la main).\n',
             b'return {\n', b"  id = '" + car_id.encode() + b"',\n",
             b'  name = ' + long_string(display.encode('utf-8')) + b',\n', b'  files = {\n']
    for name, data in files.items():
        parts.append(b'    ' + lua_key(name) + b' = ' + long_string(data) + b',\n')
    parts.append(b'  },\n}\n')
    return b''.join(parts)


def read_fast_lane(path: Path):
    data = path.read_bytes()
    version, count, _lap, _samples = struct.unpack_from('<4i', data, 0)
    if version != 7:
        raise ValueError(f'{path}: version fast_lane {version} non gérée')
    offset = 16
    points = []
    for _ in range(count):
        x, y, z, s, _id = struct.unpack_from('<4fi', data, offset)
        offset += 20
        points.append([x, y, z, s, -1.0, -1.0, 0.0, 0.0, 0.0])
    (extra,) = struct.unpack_from('<i', data, offset)
    offset += 4
    if extra == count:
        for i in range(count):
            values = struct.unpack_from('<18f', data, offset + 72 * i)
            points[i][4], points[i][5] = values[5], values[6]
            # références indépendantes du banc : vitesse IA (m/s), rayon (m), dévers (rad)
            points[i][6], points[i][7], points[i][8] = values[0], values[4], values[7]
    return points


def track_fixture(root: Path, fixture_id: str, track: str, layout: str) -> bytes:
    base = root / 'content' / 'tracks' / track
    layout_dir = base / layout if layout else base
    points = read_fast_lane(layout_dir / 'ai' / 'fast_lane.ai')
    ui = base / 'ui' / layout / 'ui_track.json' if layout else base / 'ui' / 'ui_track.json'
    declared = ui.read_bytes() if ui.exists() else b''
    name = fixture_id
    if declared:
        try:
            name = json.loads(declared.decode('utf-8-sig', errors='replace')).get('name', fixture_id)
        except json.JSONDecodeError:
            pass
    lines = '\n'.join(f'{p[0]:.2f} {p[1]:.2f} {p[2]:.2f} {p[3]:.2f} {p[4]:.2f} {p[5]:.2f} {p[6]:.2f} {p[7]:.1f} {p[8]:.4f}'
                      for p in points)
    parts = [b'-- Jeu de donnees genere par tests/tools/make_fixtures.py (ne pas modifier a la main).\n',
             b'return {\n', b"  id = '" + track.encode() + b"',\n", b"  layout = '" + layout.encode() + b"',\n",
             b'  name = ' + long_string(name.encode('utf-8')) + b',\n',
             b'  declared = ' + long_string(declared) + b',\n',
             b'  points = ' + long_string(lines.encode('ascii')) + b',\n', b'  files = {\n']
    for file in ('surfaces.ini', 'drs_zones.ini'):
        path = layout_dir / 'data' / file
        if path.exists():
            parts.append(b'    ' + lua_key(file) + b' = ' + long_string(path.read_bytes()) + b',\n')
    parts.append(b'  },\n}\n')
    return b''.join(parts)


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else APP.parents[2]
    (OUT / 'cars').mkdir(parents=True, exist_ok=True)
    (OUT / 'tracks').mkdir(parents=True, exist_ok=True)
    for car_id, rel in CARS:
        if not (root / rel).is_dir():
            print(f'voiture {car_id} absente ({rel}) : ignorée (les tests qui l\'utilisent échoueront)')
            continue
        blob = car_fixture(root, car_id, rel)
        (OUT / 'cars' / f'{car_id}.lua').write_bytes(blob)
        print(f'voiture {car_id}: {len(blob)} octets')
    for fixture_id, track, layout in TRACKS:
        if not (root / 'content' / 'tracks' / track).is_dir():
            print(f'circuit {fixture_id} absent : ignoré (les tests qui l\'utilisent échoueront)')
            continue
        blob = track_fixture(root, fixture_id, track, layout)
        (OUT / 'tracks' / f'{fixture_id}.lua').write_bytes(blob)
        print(f'circuit {fixture_id}: {len(blob)} octets')


if __name__ == '__main__':
    main()
