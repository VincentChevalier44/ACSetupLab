-- Mise à jour en jeu (demande de Vincent du 02/11/2026, bêta 1.5.3) : une seule vérification par lancement, rien sans
-- clic, empreinte et contenu du zip contrôlés, remplacement complet ou rien, fichiers périmés à la Corbeille.
local T = require('t')
local Config = require('src/config')
local Updater = require('src/updater')
local Fake = require('fakehost')

local tests = {}

local APPDIR = 'C:/AC/apps/lua/SetupLab'
local TEMP = 'C:/Users/pilote/AppData/Local/Temp'

local function frames(h, n)
  for _ = 1, n do
    h.sim.time = h.sim.time + 1000 / 60
    script.SETUPLAB__UPDATE(1 / 60)
    script.SETUPLAB__MAIN(1 / 60)
  end
end

-- Réseau, zip et dossiers simulés : chaque archive est une chaîne connue du banc (ses entrées et son empreinte).
local function withNetwork(h)
  h.webCalls, h.zips, h.sha = {}, {}, {}
  h.web = {
    timeouts = function() end,
    get = function(url, headers, callback)
      h.webCalls[#h.webCalls + 1] = { url = url, headers = headers, callback = callback }
    end,
  }
  h.ac.FolderID.ScriptOrigin, h.ac.FolderID.AppDataTemp = 2001, 2002
  local getFolder = h.ac.getFolder
  h.ac.getFolder = function(id)
    if id == 2001 then return APPDIR end
    if id == 2002 then return TEMP end
    return getFolder(id)
  end
  -- en jeu, une partie de l'API de CSP est faite de fonctions C (cdata) : ici des tables appelables, jamais « function »
  local function cfn(fn) return setmetatable({}, { __call = function(_, ...) return fn(...) end }) end
  h.ac.checksumSHA256 = cfn(function(data) return h.sha[data] or string.rep('0', 64) end)
  h.copies, h.copyFails, h.inUse, h.dirsMade = {}, {}, {}, {}
  -- dossiers : ceux de l'app existent ; un fichier ne se copie que dans un dossier existant
  local dirs = { [APPDIR] = true, [APPDIR .. '/src'] = true, [TEMP] = true }
  local function makeDir(path)
    local acc = nil
    for part in path:gmatch('[^/]+') do
      acc = acc and (acc .. '/' .. part) or part
      dirs[acc] = true
    end
  end
  h.io.createDir = cfn(function(path) makeDir(path); h.dirsMade[#h.dirsMade + 1] = path; return true end)
  h.io.dirExists = cfn(function(path) return dirs[path] == true end)
  h.io.fileExists = cfn(function(path) return h.written[path] ~= nil end)
  h.io.fileInUse = cfn(function(path) return h.inUse[path] == true end)
  h.io.copyFile = cfn(function(from, to, failIfExists)
    if h.copyFails[to] or h.written[from] == nil or not dirs[to:match('^(.*)/[^/]*$')] then return false end
    if failIfExists ~= false and h.written[to] ~= nil then return false end
    h.written[to] = h.written[from]
    h.copies[#h.copies + 1] = to
    return true
  end)
  h.io.scanZip = function(data)
    local z = h.zips[data]
    if not z then return {} end
    local names = {}
    for _, e in ipairs(z) do names[#names + 1] = e[1] end
    return names
  end
  h.io.loadFromZip = function(data, entry)
    for _, e in ipairs(h.zips[data] or {}) do
      if e[1] == entry then return e[2] end
    end
    return nil
  end
  h.io.extractFromZipAsync = cfn(function(data, destination, _, callback)
    for _, e in ipairs(h.zips[data] or {}) do
      local path = destination .. '/' .. e[1]
      if e[1]:sub(-1) == '/' then makeDir(path:sub(1, -2)) else makeDir(path:match('^(.*)/[^/]*$')); h.written[path] = e[2] end
    end
    callback(nil)
  end)
  h.restarts = 0
  h.ac.restartApp = cfn(function() h.restarts = h.restarts + 1; return true end)
  h.paused = {}
  h.ac.pauseFilesWatching = cfn(function(pause) h.paused[#h.paused + 1] = pause end)
  -- version installée : ses fichiers et sa liste
  h.written[APPDIR .. '/SetupLab.lua'] = '-- ancienne'
  h.written[APPDIR .. '/manifest.ini'] = '[ABOUT]\nVERSION=' .. Config.version .. '\n'
  h.written[APPDIR .. '/src/util.lua'] = '-- ancienne util'
  h.written[APPDIR .. '/src/vieux.lua'] = '-- module retiré'
  h.written[APPDIR .. '/files.txt'] = 'SetupLab.lua\nmanifest.ini\nsrc/util.lua\nsrc/vieux.lua\nfiles.txt\n'
  return h
end

local function boot(opts)
  opts = opts or {}
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  h.sim.raceSessionType = 1
  if opts.network ~= false then withNetwork(h) end
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  app.utcOffset = function() return 7200 end
  if opts.updateCheck == false then app.settings.updateCheck = false end
  return h, app
end

local NEXT = '9.0.0'

local function infoText(version, sha, size)
  return 'version=' .. version .. '\nurl=' .. Updater.DOWNLOAD_PREFIX .. 'v' .. version .. '/SetupLab-' .. version .. '.zip\n'
    .. 'sha256=' .. sha .. '\nsize=' .. tostring(size) .. '\n'
end

-- Archive de la version suivante : SetupLab.lua, manifest, src/util.lua (src/vieux.lua n'y est plus).
local function newZip(h, opts)
  opts = opts or {}
  local body = 'ZIP-' .. (opts.tag or 'ok')
  h.zips[body] = opts.entries or {
    { 'SetupLab/', '' },
    { 'SetupLab/SetupLab.lua', '-- nouvelle' },
    { 'SetupLab/manifest.ini', '[ABOUT]\nVERSION=' .. (opts.manifestVersion or NEXT) .. '\n' },
    { 'SetupLab/src/util.lua', '-- nouvelle util' },
    { 'SetupLab/files.txt', 'SetupLab.lua\nmanifest.ini\nsrc/util.lua\nfiles.txt\n' },
  }
  local sha = string.rep('ab', 32)
  h.sha[body] = opts.badSha and string.rep('cd', 32) or sha
  return body, sha
end

local function answerInfo(h, text, status)
  local call = h.webCalls[#h.webCalls]
  T.ok(call and call.url == Updater.INFO_URL, 'requête de la version publiée')
  call.callback(nil, { status = status or 200, body = text, headers = {} })
end

local function available(h, app, body, sha)
  frames(h, Config.K.updateCheckFrame + 2)
  T.eq(#h.webCalls, 1, 'une seule requête')
  answerInfo(h, infoText(NEXT, sha, #body))
  frames(h, 1)
  T.eq(app.updater.state, 'available', tostring(app.updater.why))
end

tests['UP01 versions comparées segment par segment ; update.txt contrôlé'] = function()
  T.eq(Updater.compare('1.0.0-beta.1.5.10', '1.0.0-beta.1.5.9'), 1, '1.5.10 après 1.5.9')
  T.eq(Updater.compare('1.0.0-beta.1.5.3', '1.0.0-beta.1.5.3'), 0)
  T.eq(Updater.compare('v1.0.0-beta.1.5.3', '1.0.0-beta.1.5.3'), 0, 'préfixe v')
  T.eq(Updater.compare('1.0.0', '1.0.0-beta.9'), 1, 'la version finale passe devant ses bêtas')
  T.eq(Updater.compare('1.0.0-beta.1.6', '1.0.0-beta.1.5.9'), 1)
  T.eq(Updater.compare('1.0.0-beta.1.5', '1.0.0-beta.1.5.1'), -1)
  T.eq(Updater.compare('n\'importe quoi', '1.0.0'), nil)
  local good = infoText('1.0.0-beta.1.5.4', string.rep('ab', 32), 1234)
  local info = Updater.parseInfo(good)
  T.ok(info and info.version == '1.0.0-beta.1.5.4' and info.size == 1234, 'update.txt lu')
  T.eq(info.page, Updater.PAGE_PREFIX .. 'v1.0.0-beta.1.5.4')
  T.no(Updater.parseInfo(good:gsub('VincentChevalier44', 'autre')), 'autre dépôt refusé')
  T.no(Updater.parseInfo(good:gsub(string.rep('ab', 32), 'zz')), 'empreinte illisible refusée')
  T.no(Updater.parseInfo(good:gsub('size=1234', 'size=99999999')), 'archive trop grande refusée')
  T.no(Updater.parseInfo(string.rep('x', Updater.MAX_INFO + 1)), 'réponse trop longue refusée')
  T.no(Updater.checkZip({ 'SetupLab/SetupLab.lua', 'SetupLab/manifest.ini', 'SetupLab/../x.lua' }, NEXT,
    'VERSION=' .. NEXT), 'chemin remontant refusé')
  T.no(Updater.checkZip({ 'SetupLab/SetupLab.lua', 'autre/manifest.ini' }, NEXT, 'VERSION=' .. NEXT), 'hors du dossier refusé')
  T.no(Updater.checkZip({ 'SetupLab/SetupLab.lua', 'SetupLab/manifest.ini' }, NEXT, 'VERSION=8.0.0'), 'manifeste différent')
  local files = Updater.checkZip({ 'SetupLab/', 'SetupLab/SetupLab.lua', 'SetupLab/manifest.ini', 'SetupLab/src/a.lua' }, NEXT,
    '[ABOUT]\nVERSION=' .. NEXT .. '\n')
  T.eq(files and #files, 3, 'fichiers de l\'archive')
  local raw = ''
  for i = 0, 31 do raw = raw .. string.char(i * 7 % 256) end
  T.eq(#Updater.hexOf(raw), 64, 'octets bruts convertis')
  T.eq(Updater.hexOf(raw):sub(1, 6), '00070e', 'octets bruts en hexadécimal')
  T.eq(Updater.hexOf(Updater.ABC:upper():gsub('(..)', '%1 ')), Updater.ABC, 'majuscules et séparateurs')
  T.eq(Updater.hexOf('abc'), nil, 'trop court')
  T.ok(Updater.selfTest({ checksumSHA256 = function() return Updater.ABC end }), 'auto-test : ok')
  T.no(Updater.selfTest({ checksumSHA256 = function() return string.rep('0', 64) end }), 'auto-test : valeur fausse dite')
  local stale = Updater.staleFiles('SetupLab.lua\nsrc/a.lua\nsrc/b.lua\n../x\n', files)
  T.eq(#stale, 1)
  T.eq(stale[1], 'src/b.lua', 'seul le fichier retiré, chemin sûr')
end

tests['UP02 une seule vérification par lancement, après quelques secondes ; rien d\'écrit ; à jour : rien à l\'écran'] = function()
  local h, app = boot()
  frames(h, Config.K.updateCheckFrame - 10)
  T.eq(#h.webCalls, 0, 'rien au démarrage')
  frames(h, 20)
  T.eq(#h.webCalls, 1, 'une requête')
  T.eq(h.webCalls[1].url, Updater.INFO_URL)
  T.ok(h.webCalls[1].headers['User-Agent']:find('SetupLab', 1, true), 'User-Agent')
  local writes = h.writeCalls
  answerInfo(h, infoText(Config.version, string.rep('ab', 32), 100))
  frames(h, 600)
  T.eq(app.updater.state, 'current')
  T.eq(#h.webCalls, 1, 'plus aucune requête')
  T.eq(h.writeCalls, writes, 'rien d\'écrit')
  T.eq(#h.copies, 0)
  T.eq(app.perf.errors, 0)
end

tests['UP03 plus récente : proposée ; rien sans clic ; au clic, vérifiée, installée, fichiers retirés à la Corbeille'] = function()
  local h, app = boot()
  local body, sha = newZip(h)
  available(h, app, body, sha)
  frames(h, 600)
  T.eq(#h.webCalls, 1, 'rien téléchargé sans clic')
  T.eq(#h.copies, 0, 'rien installé sans clic')
  app.handleIntents({ updateApply = true })
  T.eq(#h.webCalls, 2, 'téléchargement au clic')
  T.eq(h.webCalls[2].url, Updater.DOWNLOAD_PREFIX .. 'v' .. NEXT .. '/SetupLab-' .. NEXT .. '.zip')
  h.webCalls[2].callback(nil, { status = 200, body = body, headers = {} })
  T.eq(app.updater.state, 'done', tostring(app.updater.why))
  T.eq(h.written[APPDIR .. '/SetupLab.lua'], '-- nouvelle')
  T.eq(h.written[APPDIR .. '/src/util.lua'], '-- nouvelle util')
  T.eq(h.copies[#h.copies], APPDIR .. '/SetupLab.lua', 'SetupLab.lua en dernier')
  T.eq(h.paused[1], true, 'surveillance des fichiers de CSP en pause pendant le remplacement')
  T.eq(h.paused[#h.paused], false, 'puis reprise')
  T.eq(h.restarts, 1, 'app redémarrée sur la nouvelle version')
  T.eq(h.written[APPDIR .. '/src/vieux.lua'], nil, 'fichier retiré')
  T.eq(h.recycled[#h.recycled], APPDIR .. '/src/vieux.lua', 'à la Corbeille')
  T.contains(app.ui.message, 'installée')
  T.eq(app.perf.errors, 0)
end

tests['UP04 empreinte, taille ou contenu du zip faux : rien n\'est installé'] = function()
  for _, case in ipairs({ { badSha = true, tag = 'sha' }, { manifestVersion = '8.0.0', tag = 'manifeste' },
    { tag = 'chemin', entries = { { 'SetupLab/SetupLab.lua', 'x' }, { 'SetupLab/manifest.ini', 'VERSION=' .. NEXT },
      { 'SetupLab/../../evil.lua', 'x' } } } }) do
    local h, app = boot()
    local body, sha = newZip(h, case)
    available(h, app, body, sha)
    app.handleIntents({ updateApply = true })
    h.webCalls[2].callback(nil, { status = 200, body = body, headers = {} })
    T.eq(app.updater.state, 'failed', case.tag)
    T.eq(#h.copies, 0, case.tag .. ' : rien copié')
    T.eq(h.written[APPDIR .. '/SetupLab.lua'], '-- ancienne', case.tag .. ' : version installée intacte')
    T.contains(app.ui.message, 'Mise à jour impossible')
  end
  -- taille différente de celle annoncée
  local h, app = boot()
  local body, sha = newZip(h)
  available(h, app, body, sha)
  app.handleIntents({ updateApply = true })
  h.webCalls[2].callback(nil, { status = 200, body = body .. 'x', headers = {} })
  T.eq(app.updater.state, 'failed')
  T.contains(app.updater.why, 'taille')
end

tests['UP05 écriture refusée en cours de remplacement : les fichiers d\'avant sont remis'] = function()
  local h, app = boot()
  local body, sha = newZip(h)
  available(h, app, body, sha)
  h.copyFails[APPDIR .. '/src/util.lua'] = true
  app.handleIntents({ updateApply = true })
  h.webCalls[2].callback(nil, { status = 200, body = body, headers = {} })
  T.eq(app.updater.state, 'failed')
  T.contains(app.updater.why, 'fichiers d\'avant remis')
  T.eq(h.written[APPDIR .. '/SetupLab.lua'], '-- ancienne', 'SetupLab.lua jamais touché')
  T.eq(h.written[APPDIR .. '/manifest.ini'], '[ABOUT]\nVERSION=' .. Config.version .. '\n', 'manifeste remis')
  T.ok(h.written[APPDIR .. '/src/vieux.lua'], 'rien retiré')
end

tests['UP07 dossier de sauvegarde créé ; fichier identique jamais réécrit ; fichier utilisé : rien n\'est écrit'] = function()
  local h, app = boot()
  local body, sha = newZip(h)
  -- manifest.ini de l'archive identique à celui installé ? non (version) ; src/util.lua identique : jamais réécrit
  h.written[APPDIR .. '/src/util.lua'] = '-- nouvelle util'
  available(h, app, body, sha)
  app.handleIntents({ updateApply = true })
  h.webCalls[2].callback(nil, { status = 200, body = body, headers = {} })
  T.eq(app.updater.state, 'done', tostring(app.updater.why))
  for _, path in ipairs(h.copies) do T.ok(path:find('/src/util.lua', 1, true) == nil, 'identique, non réécrit : ' .. path) end
  local backupRoot = false
  for _, d in ipairs(h.dirsMade) do backupRoot = backupRoot or d:sub(-6) == '/avant' end
  T.ok(backupRoot, 'dossier de sauvegarde créé')
  -- fichier utilisé par le jeu : arrêt avant toute écriture dans l'app
  local h2, app2 = boot()
  local body2, sha2 = newZip(h2)
  available(h2, app2, body2, sha2)
  h2.inUse[APPDIR .. '/src/util.lua'] = true
  app2.handleIntents({ updateApply = true })
  h2.webCalls[2].callback(nil, { status = 200, body = body2, headers = {} })
  T.eq(app2.updater.state, 'failed')
  T.contains(app2.updater.why, 'utilisé par le jeu')
  T.eq(h2.written[APPDIR .. '/SetupLab.lua'], '-- ancienne')
  -- en piste : refusé, rien de téléchargé
  local h3, app3 = boot()
  local body3, sha3 = newZip(h3)
  available(h3, app3, body3, sha3)
  h3.car.isInPit, h3.car.isInPitlane, h3.car.speedMs = false, false, 40
  app3.handleIntents({ updateApply = true })
  T.eq(#h3.webCalls, 1, 'rien téléchargé en piste')
  T.contains(app3.ui.message, 'au stand')
end

tests['UP08 échec avant toute écriture (fichier utilisé, voiture sortie du stand) : réessayable, aucune écriture'] = function()
  local h, app = boot()
  local body, sha = newZip(h)
  available(h, app, body, sha)
  h.inUse[APPDIR .. '/src/util.lua'] = true
  app.handleIntents({ updateApply = true })
  h.webCalls[2].callback(nil, { status = 200, body = body, headers = {} })
  T.eq(app.updater.state, 'failed')
  T.no(app.updater.wrote, 'rien écrit dans le dossier de l\'app')
  -- fichier libéré : nouvel essai
  h.inUse[APPDIR .. '/src/util.lua'] = nil
  app.handleIntents({ updateApply = true })
  T.eq(#h.webCalls, 3, 'nouveau téléchargement')
  -- voiture sortie du stand pendant ce téléchargement : rien n'est écrit, toujours réessayable
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = false, false, 40
  h.webCalls[3].callback(nil, { status = 200, body = body, headers = {} })
  T.eq(app.updater.state, 'failed')
  T.contains(app.updater.why, 'sortie du stand')
  T.eq(h.written[APPDIR .. '/SetupLab.lua'], '-- ancienne', 'rien remplacé')
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  app.handleIntents({ updateApply = true })
  T.eq(#h.webCalls, 4)
  h.webCalls[4].callback(nil, { status = 200, body = body, headers = {} })
  T.eq(app.updater.state, 'done', tostring(app.updater.why))
  T.eq(h.written[APPDIR .. '/SetupLab.lua'], '-- nouvelle')
end

tests['UP06 réglage décoché, ou réseau absent : aucune requête'] = function()
  local h, app = boot({ updateCheck = false })
  frames(h, Config.K.updateCheckFrame + 60)
  T.eq(#h.webCalls, 0, 'décoché : aucune requête')
  T.eq(app.updater.state, 'idle')
  local h2, app2 = boot({ network = false })
  frames(h2, Config.K.updateCheckFrame + 60)
  T.eq(app2.updater.state, 'off', 'sans réseau')
  T.eq(app2.perf.errors, 0)
end

return tests
