-- Tests du module src/exporter (écriture de fichiers de setup, D8, D17).
local T = require('t')
local Exporter = require('src/exporter')
local Fake = require('fakehost')

local tests = {}

local SETUPS = 'C:/Users/pilote/Documents/Assetto Corsa/setups'
local EPOCH = 1792368975  -- 19/10/2026 00:16:15 UTC

local function host(carId, trackId, opts)
  opts = opts or {}
  opts.car = require('fixtures/cars/' .. carId)
  opts.track = require('fixtures/tracks/' .. trackId)
  return Fake.new(opts)
end

local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

tests['E01 copie du setup actuel : bon dossier, contenu exact, liste rafraîchie'] = function()
  local h = host('lamborghini_huracan_gt3_evo2', 'ks_red_bull_ring-layout_gp')
  local r = Exporter.saveCopy(h, EPOCH)
  T.ok(r.ok, tostring(r.reason))
  T.eq(r.path, SETUPS .. '/lamborghini_huracan_gt3_evo2/ks_red_bull_ring/SetupLab_Test_20261019-001615.ini',
    'dossier du circuit sans la disposition, comme les dossiers existants')
  T.eq(h.written[r.path], h.ac.stringifyCurrentSetup(true, false), 'copie exacte, aucun réglage modifié')
  T.eq(r.bytes, #h.written[r.path])
  T.eq(h.lastEnsure, true, 'écriture sûre (fichier temporaire puis déplacement)')
  T.eq(h.refreshes, 1, 'liste des setups d\'AC rafraîchie')
  T.eq(h.writeCalls, 1)
end

tests['E02 jamais d\'écrasement : suffixes -2, -3…'] = function()
  local h = host('formula_k', 'spa')
  local first = Exporter.saveCopy(h, EPOCH)
  local original = h.written[first.path]
  local second = Exporter.saveCopy(h, EPOCH)
  local third = Exporter.saveCopy(h, EPOCH)
  T.ok(first.ok and second.ok and third.ok)
  T.ok(second.path:find('SetupLab_Test_20261019%-001615%-2%.ini$'), second.path)
  T.ok(third.path:find('%-3%.ini$'), third.path)
  T.eq(h.written[first.path], original, 'premier fichier intact')
  T.eq(count(h.written), 3)
  local busy = host('formula_k', 'spa', { existing = {} })
  for i = 1, 99 do
    local name = i == 1 and 'SetupLab_Test_20261019-001615.ini' or ('SetupLab_Test_20261019-001615-' .. i .. '.ini')
    busy.opts.existing[SETUPS .. '/formula_k/spa/' .. name] = true
  end
  local full = Exporter.saveCopy(busy, EPOCH)
  T.no(full.ok)
  T.ok(full.reason:find('plus de 99'), full.reason)
  T.eq(busy.writeCalls, 0)
end

tests['E03 identifiants non sûrs refusés'] = function()
  local h = host('formula_k', 'spa')
  h.ac.getCarID = function() return '../../Windows' end
  local r = Exporter.saveCopy(h, EPOCH)
  T.no(r.ok)
  T.ok(r.reason:find('voiture refusé'), r.reason)
  local h2 = host('formula_k', 'spa')
  h2.ac.getTrackID = function() return 'spa/../..' end
  T.ok(Exporter.saveCopy(h2, EPOCH).reason:find('circuit refusé'))
  local h3 = host('formula_k', 'spa')
  h3.ac.getFolder = function() return '' end
  T.eq(Exporter.saveCopy(h3, EPOCH).reason, 'dossier des setups inconnu')
  T.eq(h.writeCalls + h2.writeCalls + h3.writeCalls, 0)
end

tests['E04 échecs d\'écriture et de relecture remontés tels quels'] = function()
  local refused = Exporter.saveCopy(host('formula_k', 'spa', { saveFails = true }), EPOCH)
  T.no(refused.ok)
  T.eq(refused.reason, 'io.save a refusé l\'écriture')
  local thrown = Exporter.saveCopy(host('formula_k', 'spa', { saveFails = 'error' }), EPOCH)
  T.no(thrown.ok)
  T.ok(thrown.reason:find('^io%.save : .*disque plein'), thrown.reason)
  local corrupt = Exporter.saveCopy(host('formula_k', 'spa', { corruptLoad = true }), EPOCH)
  T.no(corrupt.ok)
  T.eq(corrupt.reason, 'relecture différente du contenu écrit')
  T.ok(corrupt.path ~= nil, 'chemin indiqué pour vérification manuelle')
end

tests['E05 sans accès fichiers ou sans setup lisible : aucune écriture'] = function()
  local noio = host('formula_k', 'spa')
  noio.io.available = function() return false end
  local r = Exporter.saveCopy(noio, EPOCH)
  T.no(r.ok)
  T.eq(r.reason, 'pas d\'accès fichiers (io.available)')
  local nosetup = host('formula_k', 'spa', { throwing = { 'ac.stringifyCurrentSetup' } })
  T.ok(Exporter.saveCopy(nosetup, EPOCH).reason:find('setup courant illisible'))
  local badname = host('formula_k', 'spa')
  badname.io.isFileNameAcceptable = function() return false end
  T.ok(Exporter.saveCopy(badname, EPOCH).reason:find('nom refusé par CSP'))
  local nodir = host('formula_k', 'spa', { throwing = { 'io.createFileDir' } })
  T.ok(Exporter.saveCopy(nodir, EPOCH).reason:find('création du dossier impossible'))
  T.eq(noio.writeCalls + nosetup.writeCalls + badname.writeCalls + nodir.writeCalls, 0)
  T.no(Exporter.writeNew(host('formula_k', 'spa'), 'x', '').ok, 'contenu vide refusé')
end

return tests
