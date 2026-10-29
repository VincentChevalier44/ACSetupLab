"""Banc d'essai hors jeu de SetupLab (§0.4, §14.2).

LuaJIT 2.1 via lupa (le même moteur que CSP), mode strict des globales, linter et ses
auto-tests, suites tests/test_*.lua, endurance optionnelle (--soak).
Aucun fichier du jeu n'est modifié ; seul tests/results.json est écrit.

Usage : python -I tests/run_tests.py [--soak] [--filter TEXTE]
"""
from pathlib import Path
import argparse
import datetime
import json
import sys
import time

TESTS = Path(__file__).resolve().parent
APP = TESTS.parent
sys.path.insert(0, str(TESTS / '_vendor'))
sys.path.insert(0, str(TESTS))

from lupa.luajit21 import LuaRuntime  # noqa: E402
import lint  # noqa: E402

NOTES = {}  # mesures informatives remontées par les tests (PY.note)
TEST_GLOBALS = ['ac', 'physics', 'io', 'ui', 'vec2', 'vec3', 'rgbm', 'script', 'SETUPLAB', 'PY']


def lint_self_tests():
    """Le linter doit détecter chaque violation : un linter qui laisse tout passer ne prouve rien."""
    cases = [
        ('src/util.lua', 'local M = {}\nM.x = ac.getCar(0)\nreturn M\n', 'global read: ac'),
        ('src/datasource.lua', 'local t = os.time()\nreturn t\n', 'forbidden global: os'),
        # os.preciseClock : permis dans la colle seulement (accord de Vincent du 29/10/2026) ; os.time reste interdit
        ('src/caps.lua', 'local c = os.preciseClock\nreturn c\n', 'forbidden global: os'),
        ('SetupLab.lua', 'local t = os.time()\nreturn t\n', 'forbidden global: os'),
        ('src/caps.lua', 'local f = loadstring("x")\nreturn f\n', 'forbidden global: loadstring'),
        ('src/util.lua', 'x = 1\n', 'global write: x'),
        ('src/util.lua', 'local y = 1\n', 'unused local: y'),
        ('src/util.lua', 'local function f(a) return 1 end\nreturn f\n', 'unused local: a'),
        ('src/datasource.lua', "local U = require('src/ui')\nreturn U\n", 'require not allowed'),
        ('src/util.lua', "local D = require('src/datasource')\nreturn D\n", 'require not allowed'),
        ('src/caps.lua', "local x = require('socket')\nreturn x\n", 'external require'),
        ('src/caps.lua', 'local n = "x"\nlocal x = require(n)\nreturn x\n', 'dynamic require'),
        ('src/datasource.lua', 'local M = {}\nfunction M.f(h) return h.io.save("a", "b") end\nreturn M\n',
         'write API outside allowed module: save'),
        ('SetupLab.lua', 'local h = {}\nh.ac.setSetupSpinnerValue("WING_1", 3)\n', 'forbidden setup mutation'),
        ('src/ui.lua', 'local M = {}\nfunction M.f(h) h.ac:loadSetup("x") end\nreturn M\n', 'forbidden setup mutation'),
        ('src/util.lua', '-- TODO plus tard\nreturn {}\n', 'TODO/FIXME/XXX'),
        ('src/util.lua', 'local M = {}\n\treturn M\n', 'tab character'),
        ('src/util.lua', 'return {} \n', 'trailing whitespace'),
        ('src/util.lua', 'return {', 'syntax error'),
        ('src/nouveau.lua', 'return {}\n', 'module without role'),
        ('src/util.lua', 'local p = print\nreturn p\n', 'forbidden global: print'),
        ('src/util.lua', 'function globale() end\n', 'global write: globale'),
        # Accès par nom en texte (relecture adversariale J0+J1, constat n° 5).
        ('src/datasource.lua', "local M = {}\nfunction M.f(U, h) return U.call(U.get(h.ac, 'setSetupSpinnerValue')) end\n"
         "return M\n", 'forbidden setup mutation'),
        ('src/datasource.lua', "local M = {}\nfunction M.f(h) return h.ac['loadSetup'] end\nreturn M\n",
         'forbidden setup mutation'),
        ('src/datasource.lua', "local M = {}\nfunction M.f(U, h) return U.get(h.io, 'save') end\nreturn M\n",
         'write API outside allowed module: save'),
        ('src/ui.lua', "local M = {}\nfunction M.f(C, h) return C.resolve(h, 'ac.saveCurrentSetup') end\nreturn M\n",
         'forbidden setup mutation'),
        # D8 amendé : ac.loadSetup seulement dans l'exporteur ; les deux autres restent interdites partout.
        ('SetupLab.lua', "local U, h = {}, {}\nU.call(U.get(h.ac, 'loadSetup'), 'x')\n", 'forbidden setup mutation'),
        ('src/exporter.lua', "local M = {}\nfunction M.f(U, h) return U.call(U.get(h.ac, 'setSetupSpinnerValue')) end\n"
         "return M\n", 'forbidden setup mutation'),
        ('src/exporter.lua', "local M = {}\nfunction M.f(h) h.ac.saveCurrentSetup('x') end\nreturn M\n",
         'forbidden setup mutation'),
        ('SetupLab.lua', "local h = {}\nh.ac.resetSetupToDefault()\n", 'forbidden setup mutation'),
        ('src/ui.lua', "local M = {}\nfunction M.f(U, h) return U.get(h.physics, 'setCarFuel') end\nreturn M\n",
         'forbidden setup mutation'),
    ]
    failures = []
    for rel, text, expected in cases:
        errors = lint.Checker(APP / rel, text).run()
        if not any(expected in e for e in errors):
            failures.append(f'{rel}: « {expected} » non détecté ; erreurs : {errors}')
    clean = "local Util = require('src/util')\nlocal M = {}\nfunction M.f(x) return Util.clamp(x, 0, 1) end\nreturn M\n"
    errors = lint.Checker(APP / 'src/caps.lua', clean).run()
    if errors:
        failures.append(f'faux positifs sur un module propre : {errors}')
    loader = "local M = {}\nfunction M.f(U, h, p) return U.call(U.get(h.ac, 'loadSetup'), p) end\nreturn M\n"
    errors = lint.Checker(APP / 'src/exporter.lua', loader).run()
    if errors:
        failures.append(f'ac.loadSetup refusé dans l\'exporteur (D8 amendé) : {errors}')
    glue = "local Util = require('src/util')\nlocal ok, ffi = pcall(require, 'ffi')\n" \
           "SETUPLAB = { u = Util, f = ok and ffi }\nfunction script.SETUPLAB__UPDATE(dt) return ac, dt end\n"
    errors = lint.Checker(APP / 'SetupLab.lua', glue).run()
    if errors:
        failures.append(f'faux positifs sur la colle : {errors}')
    return len(cases) + 2, failures


def epoch_cases():
    out = []
    for t in [0, 951782400, 1709251199, 1792368000, 4102444800, 1234567890, 2147483647, -86400, 1583020799]:
        d = datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc) + datetime.timedelta(seconds=t)
        out.append([t, d.year, d.month, d.day, d.hour, d.minute, d.second])
    return out


def runtime():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(
        "local app, tests = ...\n"
        "package.path = app .. '/?.lua;' .. tests .. '/?.lua;' .. package.path\n"
        "pcall(require, 'table.new')  -- comme CSP : table.new disponible",
        APP.as_posix(), TESTS.as_posix())
    g = lua.globals()
    def note(key, text):
        NOTES[str(key)] = str(text)
        print(f'NOTE {key} : {text}', flush=True)
    py = lua.table_from({'appDir': APP.as_posix(), 'clock': time.perf_counter, 'note': note})
    py['epochCases'] = lua.table_from(epoch_cases(), recursive=True)
    g.PY = py
    lua.execute(
        "local allowed = {}\n"
        "for _, name in ipairs({...}) do allowed[name] = true end\n"
        "setmetatable(_G, {\n"
        "  __index = function(_, k) error('undeclared global read: ' .. tostring(k), 2) end,\n"
        "  __newindex = function(t, k, v)\n"
        "    if allowed[k] then rawset(t, k, v) else error('undeclared global write: ' .. tostring(k), 2) end\n"
        "  end,\n"
        "})", *TEST_GLOBALS)
    return lua


def main():
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    parser = argparse.ArgumentParser()
    parser.add_argument('--soak', action='store_true', help='endurance : 1 000 découvertes enchaînées')
    parser.add_argument('--filter', default='', help='ne lance que les tests dont le nom contient ce texte')
    args = parser.parse_args()
    results = {'date': datetime.datetime.now().isoformat(timespec='seconds'), 'tests': {}}

    files, lint_errors = lint.run()
    # dictionnaire anglais à jour (tests/tools/gen_lang.py)
    import importlib.util
    spec = importlib.util.spec_from_file_location('gen_lang', TESTS / 'tools' / 'gen_lang.py')
    gen_lang = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gen_lang)
    lint_errors = list(lint_errors) + gen_lang.stale()
    results['lint'] = {'files': len(files), 'errors': lint_errors}
    for error in lint_errors:
        print(f'LINT {error}')
    count, self_failures = lint_self_tests()
    results['lintSelfTests'] = {'cases': count, 'failures': self_failures}
    for failure in self_failures:
        print(f'LINT-SELF {failure}')
    print(f'lint : {len(files)} fichiers, {len(lint_errors)} erreurs ; auto-tests du linter : '
          f'{count - len(self_failures)}/{count}', flush=True)

    # données de référence (voitures et circuits du jeu) : non publiées avec le code (contenu de Kunos et des
    # moddeurs), à générer depuis sa propre installation d'AC
    if not (TESTS / 'fixtures' / 'cars').is_dir():
        print('Données de référence absentes (tests/fixtures/ : voitures et circuits du jeu, non publiés).\n'
              'Les générer depuis votre installation : python -I tests/tools/make_fixtures.py <racine assettocorsa>')
        sys.exit(2)

    results['luajit'] = runtime().eval('jit.version')

    def fresh():
        # Un environnement Lua neuf par fichier de tests : suites isolées les unes des autres, et tas,
        # ramasse-miettes et traces JIT représentatifs de l'app seule (les mesures de temps n'héritent
        # pas des jeux de données et des traces de toutes les suites précédentes).
        lua = runtime()
        load = lua.eval("function(path) local chunk = assert(loadfile(path)); return chunk() end")
        protect = lua.eval("function(fn) local ok, err = xpcall(fn, debug.traceback); return ok, tostring(err) end")
        return load, protect

    for file in sorted(TESTS.glob('test_*.lua')):
        load, protect = fresh()
        suite = load(file.as_posix())
        for name in sorted(suite.keys()):
            if args.filter and args.filter not in name:
                continue
            started = time.perf_counter()
            ok, err = protect(suite[name])
            seconds = round(time.perf_counter() - started, 4)
            entry = {'ok': bool(ok), 'seconds': seconds, 'suite': file.stem}
            if ok:
                print(f'PASS {name} ({seconds:.3f} s)', flush=True)
            else:
                entry['error'] = str(err)
                print(f'FAIL {name}\n{err}', flush=True)
            results['tests'][name] = entry

    if args.soak:
        load, _ = fresh()
        soak = load((TESTS / 'soak.lua').as_posix())
        started = time.perf_counter()
        try:
            value = soak(1000)
            summary = {k: value[k] for k in value.keys()}
            results['soak'] = {'ok': True, **summary}
            print(f'SOAK {json.dumps(summary, ensure_ascii=False)}', flush=True)
        except Exception as exc:  # erreur Lua remontée par lupa
            results['soak'] = {'ok': False, 'error': str(exc), 'seconds': time.perf_counter() - started}
            print(f'SOAK ÉCHEC {exc}', flush=True)

    failures = sum(not t['ok'] for t in results['tests'].values())
    failures += len(lint_errors) + len(self_failures)
    if 'soak' in results and not results['soak']['ok']:
        failures += 1
    results['notes'] = NOTES
    results['summary'] = {'tests': len(results['tests']), 'failures': failures}
    (TESTS / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
    print(f'{len(results["tests"])} tests, {failures} échecs (lint compris)', flush=True)
    raise SystemExit(1 if failures else 0)


if __name__ == '__main__':
    main()
