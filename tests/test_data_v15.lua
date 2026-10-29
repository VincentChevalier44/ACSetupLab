-- Relecture adversariale des données du 29/10/2026 : voitures et circuits de mods (identifiants avec espaces ou
-- accents, grip des surfaces, bornes des circuits et des pneus).
local T = require('t')
local Util = require('src/util')
local TrackModel = require('src/track_model')
local Datasource = require('src/datasource')
local Config = require('src/config')

local tests = {}

tests['DV01 identifiants de mods : espaces, accents, parenthèses acceptés ; chemins et séparateurs refusés'] = function()
  for _, ok in ipairs({ 'citroën ds3 (wrc)', 'circuit de nürburg', 'east course', 'rss_formula_hybrid_2023', 'power curve.lut' }) do
    T.ok(Util.isSafeId(ok), ok)
  end
  for _, bad in ipairs({ '../x', 'a/b', 'a\b', 'a|b', 'a#b', 'a:b', 'a=b', '..', '.hidden', 'trail ', '', 'a\nb' }) do
    T.no(Util.isSafeId(bad), bad)
  end
  local ini = Util.parseIni('[HEADER]\nPOWER_CURVE=power curve.lut\n')
  local names = Datasource.collectLutNames({ ['engine.ini'] = ini })
  T.eq(names[1], 'power curve.lut', 'LUT au nom avec espace lue')
end

tests['DV02 grip de surface : asphalte reconnu, voie des stands et herbe écartées'] = function()
  local function grip(text) return TrackModel.surfaceGrip(Util.parseIni(text)) end
  local g, why = grip('[SURFACE_0]\nKEY=MONZA-ASPH\nFRICTION=0.99\nIS_VALID_TRACK=1\n[SURFACE_1]\nKEY=PITLANE\nFRICTION=1.05\n'
    .. 'IS_VALID_TRACK=1\n')
  T.eq(g, 0.99, 'asphalte, pas la voie des stands')
  T.contains(why, 'route')
  g = grip('[SURFACE_0]\nKEY=GRASS\nFRICTION=0.6\nIS_VALID_TRACK=1\n')
  T.eq(g, 1, 'herbe seule : défaut')
  g = grip('[SURFACE_0]\nKEY=TRM-NRM\nFRICTION=0.98\nIS_VALID_TRACK=1\n[SURFACE_1]\nKEY=KERB\nFRICTION=0.92\nIS_VALID_TRACK=1\n')
  T.eq(g, 0.98, 'nom inconnu : la surface valide la plus adhérente')
end

tests['DV03 bornes : karting dès 200 m, grands circuits jusqu\'à 75 km'] = function()
  local K = Config.K
  T.ok(K.trackMinLength <= 200 and K.trackMaxLength >= 75000)
  T.ok(K.curvatureBaseM >= 8, 'courbure peu sensible au bruit d\'une ligne IA de mod')
end

return tests
