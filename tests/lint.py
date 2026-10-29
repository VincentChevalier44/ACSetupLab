"""Linter strict de SetupLab (§0.4, §16) : analyse des portées Lua via luaparser.

Règles :
- globales autorisées selon le rôle du fichier (colle, noyau pur, entrées/sorties, interface) ;
- interdits partout : os, web, io (hors colle), load/loadstring/dofile/loadfile, debug, print… ;
- graphe des require conforme à D5 (le noyau pur ne dépend que du noyau pur) ;
- fonctions d'écriture réservées à certains fichiers ; fonctions qui modifieraient le setup
  en cours (D8) interdites partout ;
- variables locales inutilisées (préfixe « _ » pour les ignorer) ;
- règles textuelles : pas de TODO/FIXME/XXX, pas de tabulation, pas d'espace final,
  lignes de 140 caractères au plus, fin de fichier par un saut de ligne.
"""
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).parent / '_vendor'))
from luaparser import ast  # noqa: E402
from luaparser.astnodes import Node  # noqa: E402

APP = Path(__file__).resolve().parents[1]

STANDARD = {
    'require', 'type', 'tostring', 'tonumber', 'pairs', 'ipairs', 'next', 'pcall', 'xpcall', 'error',
    'assert', 'select', 'unpack', 'setmetatable', 'getmetatable', 'rawget', 'rawset', 'rawequal',
    'math', 'string', 'table', 'coroutine',
}
FORBIDDEN = {
    'os', 'web', 'load', 'loadstring', 'dofile', 'loadfile', 'debug', 'setfenv', 'getfenv', 'print',
    'collectgarbage', 'module', 'package', 'jit',
}
CSP_GLOBALS = {'ac', 'physics', 'io', 'ui', 'vec2', 'vec3', 'rgbm', 'script', '_G'}

# Rôles (D5). Le noyau pur ne lit aucune API ; les modules d'E/S reçoivent l'hôte injecté.
CORE = {'util', 'config', 'track_model', 'car_model', 'setup_space', 'laptime_sim', 'stint_sim', 'ers', 'ers_plan', 'explain',
        'optimizer', 'calibration', 'i18n', 'lang_en'}
IO = {'caps', 'datasource', 'recorder', 'exporter', 'store'}
UI = {'ui', 'skin'}

# Fonctions d'écriture : seulement là où le PDR les place. D8 amendé le 22/10/2026 (décision de Vincent) : Corbeille
# et renommage des fichiers écrits par SetupLab, depuis l'exporteur seulement ; suppression définitive jamais.
WRITE_API = {
    'save': {'exporter', 'store'}, 'saveAsync': {'exporter', 'store'}, 'createDir': {'exporter'},
    'createFileDir': {'exporter'}, 'deleteFile': set(), 'deleteDir': set(), 'move': {'exporter'},
    'copyFile': set(), 'replaceFile': set(), 'recycle': {'exporter'}, 'setAndSave': set(),
    'setClipboardText': {'SetupLab', 'exporter'}, 'setActiveSetupName': set(), 'refreshSetups': {'exporter'},
}
# D8 : ne jamais modifier le setup en cours par cran ni l'enregistrer par-dessus un fichier.
NEVER = {'setSetupSpinnerValue', 'saveCurrentSetup', 'resetSetupToDefault', 'setPitstopSpinnerValue', 'setTyresCompound',
         'setCarFuel'}
# D8 amendé le 20/10/2026 (décision de Vincent) : chargement d'un setup écrit par SetupLab, seulement
# depuis l'exporteur (gardes, copie de sauvegarde et confirmation dans la colle).
LOAD_API = {'loadSetup': {'exporter'}}

TEXT_FORBIDDEN = re.compile(r'\b(TODO|FIXME|XXX)\b')
MAX_LINE = 140


def module_name(path):
    return path.stem


def role(path):
    name = module_name(path)
    if path.parent == APP and name == 'SetupLab':
        return 'glue'
    if name in CORE:
        return 'core'
    if name in IO:
        return 'io'
    if name in UI:
        return 'ui'
    return 'unknown'


def allowed_requires(path):
    r = role(path)
    if r == 'glue':
        return None  # tout module de src/ et ffi
    if r == 'core':
        return CORE
    if r == 'io':
        return CORE
    if r == 'ui':
        return CORE | {'caps'} | UI
    return set()


class Checker:
    def __init__(self, path, text=None):
        self.path = path
        self.text = text
        self.module = module_name(path)
        self.role = role(path)
        self.scopes = [{}]
        self.errors = []
        self.allowed = set(STANDARD)
        if self.role == 'glue':
            self.allowed |= CSP_GLOBALS | {'SETUPLAB'}

    def report(self, node, message):
        token = getattr(node, '_first_token', None)
        line = getattr(token, 'line', 0) if token is not None else 0
        self.errors.append(f'{self.path.relative_to(APP).as_posix()}:{line}: {message}')

    # Portées -----------------------------------------------------------------
    def declare(self, node):
        if type(node).__name__ == 'Name':
            self.scopes[-1][node.id] = [node, 0]

    def name(self, node, write=False):
        for scope in reversed(self.scopes):
            if node.id in scope:
                if not write:
                    scope[node.id][1] += 1
                return
        if node.id in FORBIDDEN:
            self.report(node, 'forbidden global: ' + node.id)
        elif write and not (self.role == 'glue' and node.id == 'SETUPLAB'):
            self.report(node, 'global write: ' + node.id)
        elif not write and node.id not in self.allowed:
            self.report(node, 'global read: ' + node.id)

    def end_scope(self):
        for name, (node, reads) in self.scopes.pop().items():
            if reads == 0 and not name.startswith('_') and name != 'self':
                self.report(node, 'unused local: ' + name)

    def block(self, node):
        self.scopes.append({})
        self.visit(node)
        self.end_scope()

    # Règles d'appel -------------------------------------------------------------
    def check_field(self, node, field):
        if field in NEVER or (field in LOAD_API and self.module not in LOAD_API[field]):
            self.report(node, 'forbidden setup mutation (D8): ' + field)
        elif field in WRITE_API and self.module not in WRITE_API[field]:
            self.report(node, 'write API outside allowed module: ' + field)

    # Les API sont souvent atteintes par nom en texte (Util.get(host.ac, 'loadSetup'),
    # host.io['save'], Caps.resolve(host, 'ac.saveCurrentSetup')) : toute chaîne littérale égale
    # à un nom interdit, ou finissant par « .nom », est contrôlée comme un accès de champ.
    # Exception : caps.lua, registre qui cite ces noms pour constater leur présence sans les appeler
    # (le banc vérifie qu'aucune fonction d'écriture n'est appelée pendant la découverte).
    def check_string(self, node):
        if self.module == 'caps':
            return
        value = node.s
        if isinstance(value, bytes):
            value = value.decode('utf-8', 'replace')
        name = value.rsplit('.', 1)[-1] if ' ' not in value else value
        if name in NEVER or name in WRITE_API or name in LOAD_API:
            self.check_field(node, name)

    def check_require(self, node):
        if len(node.args) != 1 or type(node.args[0]).__name__ != 'String':
            self.report(node, 'dynamic require forbidden')
            return
        value = node.args[0].s
        if isinstance(value, bytes):
            value = value.decode()
        if value == 'ffi' and self.role == 'glue':
            return
        if not value.startswith('src/') or '..' in value:
            self.report(node, 'external require: ' + value)
            return
        allowed = allowed_requires(self.path)
        target = value[4:]
        if allowed is not None and target not in allowed:
            self.report(node, f'require not allowed for role {self.role}: {value}')

    # Parcours ------------------------------------------------------------------
    def visit(self, node, write=False):
        if isinstance(node, list):
            for item in node:
                self.visit(item)
            return
        if not isinstance(node, Node):
            return
        kind = type(node).__name__
        if kind == 'Name':
            self.name(node, write)
            return
        if kind == 'String':
            self.check_string(node)
            return
        if kind == 'Index':
            # seule exception à l'interdiction d'os (accord de Vincent du 29/10/2026) : os.preciseClock, lu dans la colle
            if (self.role == 'glue' and type(node.value).__name__ == 'Name' and node.value.id == 'os'
                    and not str(node.notation).endswith('SQUARE') and type(node.idx).__name__ == 'Name'
                    and node.idx.id == 'preciseClock' and not write):
                return
            self.visit(node.value)
            if str(node.notation).endswith('SQUARE'):
                self.visit(node.idx)
            elif type(node.idx).__name__ == 'Name':
                self.check_field(node, node.idx.id)
            return
        if kind == 'Field':
            if node.between_brackets:
                self.visit(node.key)
            self.visit(node.value)
            return
        if kind == 'Invoke':
            self.visit(node.source)
            if type(node.func).__name__ == 'Name':
                self.check_field(node, node.func.id)
            self.visit(node.args)
            return
        if kind == 'Call':
            if type(node.func).__name__ == 'Name' and node.func.id == 'require':
                self.check_require(node)
            self.visit(node.func)
            self.visit(node.args)
            return
        if kind == 'LocalAssign':
            self.visit(node.values)
            for target in node.targets:
                self.declare(target)
            return
        if kind == 'Assign':
            self.visit(node.values)
            for target in node.targets:
                self.visit(target, True)
            return
        if kind in {'LocalFunction', 'Function', 'AnonymousFunction', 'Method'}:
            if kind == 'LocalFunction':
                self.declare(node.name)
            elif kind == 'Function':
                self.visit(node.name, True)
            elif kind == 'Method':
                self.visit(node.source)
            self.scopes.append({})
            if kind == 'Method':
                self.scopes[-1]['self'] = [node, 1]
            for arg in node.args:
                self.declare(arg)
            self.visit(node.body)
            self.end_scope()
            return
        if kind == 'Fornum':
            self.visit(node.start)
            self.visit(node.stop)
            self.visit(node.step)
            self.scopes.append({})
            self.declare(node.target)
            self.visit(node.body)
            self.end_scope()
            return
        if kind == 'Forin':
            self.visit(node.iter)
            self.scopes.append({})
            for target in node.targets:
                self.declare(target)
            self.visit(node.body)
            self.end_scope()
            return
        if kind == 'While':
            self.visit(node.test)
            self.block(node.body)
            return
        if kind == 'Repeat':
            self.scopes.append({})
            self.visit(node.body)
            self.visit(node.test)
            self.end_scope()
            return
        if kind in {'If', 'ElseIf'}:
            self.visit(node.test)
            self.block(node.body)
            self.visit(node.orelse)
            return
        if kind in {'Else', 'Do'}:
            self.block(node.body)
            return
        for key, value in vars(node).items():
            if not key.startswith('_') and key != 'comments':
                self.visit(value)

    def check_text(self, text):
        if not text.endswith('\n'):
            self.errors.append(f'{self.path.name}: missing final newline')
        for number, line in enumerate(text.split('\n'), 1):
            if '\t' in line:
                self.errors.append(f'{self.path.name}:{number}: tab character')
            if line != line.rstrip():
                self.errors.append(f'{self.path.name}:{number}: trailing whitespace')
            # dictionnaire généré de l'interface anglaise (tests/tools/gen_lang.py) : lignes longues permises
            if len(line) > MAX_LINE and self.path.name != 'lang_en.lua':
                self.errors.append(f'{self.path.name}:{number}: line longer than {MAX_LINE}')
            if TEXT_FORBIDDEN.search(line):
                self.errors.append(f'{self.path.name}:{number}: TODO/FIXME/XXX forbidden (§0.2)')

    def run(self):
        text = self.text if self.text is not None else self.path.read_text(encoding='utf-8')
        if self.role == 'unknown':
            self.errors.append(f'{self.path.name}: module without role (update tests/lint.py)')
        self.check_text(text)
        try:
            tree = ast.parse(text)
        except Exception as exc:  # erreur de syntaxe
            self.errors.append(f'{self.path.name}: syntax error: {exc}')
            return self.errors
        self.visit(tree)
        self.end_scope()
        return self.errors


def app_files():
    return [APP / 'SetupLab.lua', *sorted((APP / 'src').glob('*.lua'))]


def run():
    files = app_files()
    errors = [error for file in files for error in Checker(file).run()]
    return files, errors


def main():
    files, errors = run()
    for error in errors:
        print(error)
    print(f'{len(files)} fichiers Lua, {len(errors)} erreurs de lint')
    raise SystemExit(bool(errors))


if __name__ == '__main__':
    main()
