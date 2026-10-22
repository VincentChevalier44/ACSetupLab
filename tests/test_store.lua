-- Tests de src/store (J7, §13) : format texte relu sans exécuter de code, validation de chaque champ,
-- versions, purge LRU, ouverture et écriture par ac.storage.
local T = require('t')
local Config = require('src/config')
local Store = require('src/store')
local Fake = require('fakehost')

local K = Config.K
local tests = {}

tests['Y01 format : aller-retour, champs invalides ou piégés rejetés, versions'] = function()
  local entries = {
    settings = { raceLaps = 25, calibrationAuto = false, perfStab = 0.4 },
    ['cal:urd_px1_aura:monza:1'] = { mu = 0.97, power = 1.02, drag = 1.01, lift = 0.95, brake = 1, roadTemp = 31, stamp = 1700000000 },
    ['last:urd_px1_aura:monza:quali'] = { file = 'SetupLab_Quali_20261020-1530.ini', gain = -0.8, stamp = 1700000000 },
  }
  local text = Store.serialize(entries)
  local back, reason = Store.parse(text)
  T.eq(reason, nil)
  T.eq(back.settings.raceLaps, 25)
  T.eq(back.settings.calibrationAuto, false)
  T.near(back['cal:urd_px1_aura:monza:1'].mu, 0.97, 1e-15)
  T.eq(back['last:urd_px1_aura:monza:quali'].file, 'SetupLab_Quali_20261020-1530.ini')
  T.eq(Store.serialize(back), text, 'format stable')
  -- contenu hostile ou corrompu : chaque ligne fautive est rejetée, le reste est gardé
  local hostile = 'setuplab-store 1|'
    .. 'settings:autre#raceLaps=10|'                    -- fausse clé de réglages
    .. 'settings#enabled=false|'                        -- réglage non modifiable dans l'interface
    .. 'settings#raceLaps=9999|'                         -- hors bornes
    .. 'settings#inconnu=3|'                             -- champ inconnu
    .. 'cal:x:y:1#mu=abc|'                               -- type
    .. 'cal:x:y:1#mu=0.98|'                              -- valide
    .. 'cal:x:y:1#power=nan|'                            -- non fini
    .. 'last:x:y:quali#file=s:../../evil.lua|'           -- chaîne hors jeu de caractères
    .. 'last:x:y:quali#file=s:ok_name.ini|'
    .. 'rough:x:y#G0=1e9|'                               -- hors bornes
    .. 'x();os.exit()#mu=1|'                             -- clé illégale
    .. 'drs:x#cl=s:0.5|'                                 -- genre inconnu
    .. 'cal:x:y:2#mu=0.9\n'                               -- caractère de contrôle
  local parsed, why = Store.parse(hostile)
  T.eq(parsed.settings, nil, 'aucun réglage valide')
  T.near(parsed['cal:x:y:1'].mu, 0.98, 1e-15)
  T.eq(parsed['cal:x:y:1'].power, nil)
  T.eq(parsed['last:x:y:quali'].file, 'ok_name.ini')
  T.eq(parsed['rough:x:y'], nil)
  T.eq(parsed['drs:x'], nil)
  T.eq(parsed['cal:x:y:2'], nil, 'caractère de contrôle refusé')
  T.eq(parsed['settings:autre'], nil, 'clé de réglages unique')
  T.eq(next((Store.parse('setuplab-store 0|settings#raceLaps=10'))), nil, 'version 0 inconnue')
  T.contains(why, 'rejetée')
  -- versions et en-tête
  local newer, reasonNewer = Store.parse('setuplab-store 99|settings#raceLaps=10')
  T.eq(next(newer), nil)
  T.contains(reasonNewer, 'plus récente')
  local headless, reasonHeadless = Store.parse('settings#raceLaps=10')
  T.eq(next(headless), nil)
  T.contains(reasonHeadless, 'en-tête')
  T.eq(next((Store.parse(''))), nil, 'vide')
  T.eq(next((Store.parse(nil))), nil, 'absent')
  -- clés d'entrée : identifiants sûrs seulement
  T.eq(Store.entryKey('cal', 'urd_px1_aura', 'monza', 1), 'cal:urd_px1_aura:monza:1')
  T.eq(Store.entryKey('cal', '../x', 'monza', 1), nil)
end

tests['Y02 put / get : validation à l\'écriture, horodatage d\'usage, purge des plus anciennes'] = function()
  local store = { entries = {}, dirty = false }
  T.ok(Store.put(store, 'cal:a:b:1', { mu = 0.9, power = 99, bogus = 1 }, 100))
  local e = Store.get(store, 'cal:a:b:1', 150)
  T.near(e.mu, 0.9, 1e-15)
  T.eq(e.power, nil, 'hors bornes refusé')
  T.eq(e.bogus, nil)
  T.eq(store.entries['cal:a:b:1'].stamp, 150, 'marquée utilisée')
  T.no(Store.put(store, 'cal:a:b:2', { power = 99 }, 100), 'aucun champ valide : rien n\'est écrit')
  Store.put(store, 'rough:x:y', { G0 = 1e-5 }, 1e30)
  T.eq(store.entries['rough:x:y'].stamp, nil, 'horodatage hors bornes non retenu')
  store.entries['rough:x:y'] = nil
  T.ok(Store.put(store, 'settings', { raceLaps = 12, perfStab = 7 }, 100))
  T.eq(store.entries.settings.raceLaps, 12)
  T.eq(store.entries.settings.perfStab, nil, 'réglage hors bornes refusé')
  -- purge : taille maximale réduite, les entrées datées les plus anciennes partent, les réglages restent
  local saved = K.storeMaxBytes
  for i = 1, 40 do Store.put(store, 'rough:car' .. i .. ':track', { G0 = 1e-5, speed = 50 }, 1000 + i) end
  K.storeMaxBytes = 1500
  Store.purge(store)
  K.storeMaxBytes = saved
  T.ok(#Store.serialize(store.entries) <= 1500)
  T.ok(store.entries.settings, 'réglages conservés')
  T.ok(store.entries['rough:car40:track'], 'la plus récente reste')
  T.eq(store.entries['rough:car1:track'], nil, 'la plus ancienne part')
end

tests['Y03 ouverture et écriture par ac.storage ; stockage indisponible signalé'] = function()
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  local store = Store.open(h)
  T.eq(store.status, 'ouvert')
  T.eq(next(store.entries), nil)
  Store.put(store, 'settings', { raceLaps = 30 })
  T.ok(Store.flush(store))
  T.no(Store.flush(store), 'rien à écrire')
  T.contains(h.stored[Store.KEY], 'settings#raceLaps=30')
  T.no(h.stored[Store.KEY]:find('%c'), 'aucun caractère de contrôle')
  local again = Store.open(h)
  T.eq(again.entries.settings.raceLaps, 30, 'relu au chargement suivant')
  -- stockage indisponible : l'app continue sans persistance
  h.ac.storage = nil
  local none = Store.open(h)
  T.eq(none.status, 'indisponible')
  Store.put(none, 'settings', { raceLaps = 5 })
  T.no(Store.flush(none))
end

return tests
