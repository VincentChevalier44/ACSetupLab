-- Mise à jour en jeu (demande de Vincent du 02/11/2026, bêta 1.5.3) : au lancement, une seule requête lit la dernière
-- version publiée (fichier update.txt de la branche main du dépôt GitHub) ; plus récente : un bouton « Mettre à jour ».
-- Au clic seulement : téléchargement du zip de la release, taille et empreinte SHA-256 vérifiées, contenu du zip contrôlé
-- (dossier SetupLab/ seulement, aucun chemin remontant, version du manifeste), extraction dans un dossier de travail hors
-- de l'app, copie de sauvegarde des fichiers actuels, puis remplacement de tous les fichiers dans la même image
-- (SetupLab.lua en dernier) : CSP recharge l'app une seule fois, sur des fichiers complets. Un échec avant le
-- remplacement ne touche à rien ; pendant, les fichiers d'avant sont remis. Les fichiers de l'ancienne version absents de
-- la nouvelle (liste files.txt de chaque archive) partent à la Corbeille. Aucune donnée n'est envoyée : une lecture, un
-- téléchargement (GitHub voit l'adresse IP, comme pour toute page web).
-- Hôte injecté (D5) : host.web, host.io, host.ac.
local M = {}

-- Dépôt renommé SetupLab le 05/11/2026 (demande de Vincent : « il faut pas de redirection, il faut tout mettre en mode
-- natif ») : adresses du nouveau nom.
M.INFO_URL = 'https://raw.githubusercontent.com/VincentChevalier44/SetupLab/main/update.txt'
M.DOWNLOAD_PREFIX = 'https://github.com/VincentChevalier44/SetupLab/releases/download/'
M.PAGE_PREFIX = 'https://github.com/VincentChevalier44/SetupLab/releases/tag/'
-- Ancien nom : les versions 1.5.4 à 1.5.7, déjà installées, exigent ce préfixe dans la ligne « url= » de update.txt (elle
-- le garde pour elles) ; la ligne « download= » porte l'adresse du nouveau nom, lue en premier. Le téléchargement se fait
-- toujours à l'adresse du nouveau nom.
M.LEGACY_DOWNLOAD_PREFIX = 'https://github.com/VincentChevalier44/ACSetupLab/releases/download/'
M.ROOT = 'SetupLab/'
M.MAX_INFO = 4096
M.MAX_ZIP = 8 * 1024 * 1024
M.MAX_ENTRIES = 300
local MAIN = 'SetupLab.lua'
local VERSION_PATTERN = '^%d+%.%d+%.%d+[%w%.%-]*$'

-- Appel protégé : une fonction de CSP peut être une fonction C (cdata, pas « function ») ; seule son absence compte.
local function call(fn, ...)
  if fn == nil then return false, 'fonction absente' end
  return pcall(fn, ...)
end

-- Version « 1.0.0-beta.1.5.3 » : nombres principaux, puis segments de préversion (nombres comparés en nombres).
function M.parseVersion(text)
  if type(text) ~= 'string' then return nil end
  text = text:gsub('^v', '')
  if not text:match(VERSION_PATTERN) or #text > 40 then return nil end
  local main, pre = text:match('^([%d%.]+)%-?(.*)$')
  local out = { main = {}, pre = {} }
  for n in main:gmatch('%d+') do out.main[#out.main + 1] = tonumber(n) end
  if #out.main ~= 3 then return nil end
  for token in pre:gmatch('[^%.]+') do out.pre[#out.pre + 1] = tonumber(token) or token end
  return out
end

-- -1, 0 ou 1 (a plus ancienne, égale, plus récente que b) ; nil si l'une est illisible. Une version sans préversion
-- passe devant ses préversions (1.0.0 > 1.0.0-beta.9).
function M.compare(a, b)
  local x, y = M.parseVersion(a), M.parseVersion(b)
  if not (x and y) then return nil end
  for i = 1, 3 do
    if x.main[i] ~= y.main[i] then return x.main[i] > y.main[i] and 1 or -1 end
  end
  if #x.pre == 0 or #y.pre == 0 then
    if #x.pre == #y.pre then return 0 end
    return #x.pre == 0 and 1 or -1
  end
  for i = 1, math.max(#x.pre, #y.pre) do
    local p, q = x.pre[i], y.pre[i]
    if p == nil then return -1 end
    if q == nil then return 1 end
    if p ~= q then
      if type(p) == type(q) then return p > q and 1 or -1 end
      return type(p) == 'number' and -1 or 1
    end
  end
  return 0
end

-- update.txt : lignes « clé=valeur » ; chaque valeur contrôlée (adresse exacte de la release, empreinte, taille).
function M.parseInfo(text)
  if type(text) ~= 'string' or #text > M.MAX_INFO then return nil, 'réponse illisible' end
  local f = {}
  for line in text:gmatch('[^\r\n]+') do
    local key, value = line:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
    if key then f[key] = value end
  end
  local version = f.version
  if M.parseVersion(version) == nil then return nil, 'version illisible' end
  local zip = 'SetupLab-' .. version .. '.zip'
  local path = 'v' .. version .. '/' .. zip
  local url = M.DOWNLOAD_PREFIX .. path
  -- « download= » (nouveau nom) d'abord ; sinon « url= », au nouveau nom ou à l'ancien (même release)
  if f.download ~= nil then
    if f.download ~= url then return nil, 'adresse du téléchargement inattendue' end
  elseif not (f.url == url or f.url == M.LEGACY_DOWNLOAD_PREFIX .. path) then
    return nil, 'adresse du téléchargement inattendue'
  end
  local sha = type(f.sha256) == 'string' and f.sha256:lower() or nil
  if not (sha and #sha == 64 and sha:match('^[0-9a-f]+$')) then return nil, 'empreinte SHA-256 illisible' end
  local size = tonumber(f.size)
  if not (size and size > 0 and size <= M.MAX_ZIP and size == math.floor(size)) then return nil, 'taille illisible' end
  return { version = version, url = url, sha256 = sha, size = size, zip = zip,
    page = M.PAGE_PREFIX .. 'v' .. version }
end

-- Entrées du zip : toutes dans SetupLab/, aucun chemin absolu ni remontant ; SetupLab.lua et manifest.ini présents ;
-- version du manifeste égale à celle annoncée. Renvoie la liste des fichiers (chemins relatifs), ou nil et la raison.
function M.checkZip(entries, version, manifest)
  if type(entries) ~= 'table' or #entries == 0 then return nil, 'archive illisible' end
  if #entries > M.MAX_ENTRIES then return nil, 'archive trop grande' end
  local files, seen = {}, {}
  for _, name in ipairs(entries) do
    if type(name) ~= 'string' or name:sub(1, #M.ROOT) ~= M.ROOT then return nil, 'fichier hors du dossier SetupLab' end
    local rel = name:sub(#M.ROOT + 1)
    if rel:find('..', 1, true) or rel:find('\\', 1, true) or rel:find(':', 1, true) or rel:sub(1, 1) == '/'
        or rel:find('[%c]') then
      return nil, 'chemin refusé dans l\'archive'
    end
    if rel ~= '' and rel:sub(-1) ~= '/' then
      files[#files + 1] = rel
      seen[rel] = true
    end
  end
  if not (seen[MAIN] and seen['manifest.ini']) then return nil, 'archive incomplète' end
  local v = type(manifest) == 'string' and manifest:match('[\r\n]VERSION=([^\r\n]+)') or nil
  if v == nil and type(manifest) == 'string' then v = manifest:match('^VERSION=([^\r\n]+)') end
  if v ~= version then return nil, 'version du manifeste différente' end
  return files
end

-- Fichiers de l'ancienne version absents de la nouvelle (liste files.txt de l'ancienne), chemins sûrs seulement ; sans
-- distinction de casse (Windows : un fichier renommé en changeant de casse est le même fichier).
function M.staleFiles(oldList, newFiles)
  local keep, out = {}, {}
  for _, rel in ipairs(newFiles) do keep[rel:lower()] = true end
  if type(oldList) ~= 'string' then return out end
  for line in oldList:gmatch('[^\r\n]+') do
    local rel = line:match('^%s*(.-)%s*$')
    if rel ~= '' and not keep[rel:lower()] and not rel:find('..', 1, true) and not rel:find('[\\:%c]') and rel:sub(1, 1) ~= '/'
        and rel:lower() ~= MAIN:lower() and rel:lower() ~= 'manifest.ini' then
      out[#out + 1] = rel
    end
  end
  return out
end

-- Empreinte rendue par ac.checksumSHA256 en hexadécimal minuscule : 32 octets bruts convertis, sinon séparateurs retirés.
function M.hexOf(sha)
  if type(sha) ~= 'string' then return nil end
  if #sha == 32 then
    return (sha:gsub('.', function(c) return string.format('%02x', c:byte()) end))
  end
  local hex = sha:lower():gsub('[^0-9a-f]', '')
  if #hex ~= 64 then return nil end
  return hex
end

-- Auto-test de l'empreinte de CSP (SHA-256 de « abc ») : vrai, ou faux et la valeur obtenue (dite au journal).
M.ABC = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
function M.selfTest(ac)
  local ok, sha = call(ac and ac.checksumSHA256, 'abc')
  local hex = ok and M.hexOf(sha) or nil
  return hex == M.ABC, tostring(hex or sha)
end

function M.new()
  return { state = 'idle' }
end

-- Vérification : une seule requête (état « idle » seulement) ; réseau absent ou réponse illisible : rien à l'écran.
function M.check(u, host, current)
  if u.state ~= 'idle' then return false end
  local web = host.web
  if not (web and web.get ~= nil) then
    u.state = 'off'
    return false
  end
  u.state = 'checking'
  call(web.timeouts, 3000, 5000, 5000, 8000)
  local ok = call(web.get, M.INFO_URL, { ['User-Agent'] = 'SetupLab/' .. tostring(current), ['Cache-Control'] = 'no-cache' },
    function(err, response)
      if err or type(response) ~= 'table' or response.status ~= 200 then
        u.state, u.why = 'unreachable', tostring(err or (type(response) == 'table' and response.status) or 'sans réponse')
        return
      end
      local info, why = M.parseInfo(response.body)
      if info == nil then
        u.state, u.why = 'unreachable', why
        return
      end
      local order = M.compare(info.version, current)
      u.latest = info.version
      if order == 1 then
        u.state, u.info = 'available', info
      else
        u.state = 'current'
      end
    end)
  if not ok then u.state, u.why = 'unreachable', 'requête refusée' end
  return true
end

local function dirOf(path)
  return path:match('^(.*)/[^/]*$')
end

-- Crée base et les dossiers de rel ; vrai si le dossier final existe.
local function ensureDirs(io, base, rel)
  call(io.createDir, base)
  local acc = base
  local dir = dirOf(rel)
  for part in (dir or ''):gmatch('[^/]+') do
    acc = acc .. '/' .. part
    call(io.createDir, acc)
  end
  local okD, exists = call(io.dirExists, acc)
  return not okD or exists == true
end

local function fileExists(io, path)
  local ok, exists = call(io.fileExists, path)
  if not ok then return nil end
  return exists == true
end

-- Remplacement, dans la même image : seuls les fichiers qui changent sont écrits (les polices, chargées par DirectWrite,
-- ne sont pas réécrites) ; copie de sauvegarde de chacun, puis copie des nouveaux, SetupLab.lua en dernier. Un échec
-- remet les fichiers d'avant (et retire ceux qui n'existaient pas) ; renvoie vrai, ou faux, la raison et vrai si
-- l'installation est restée mélangée.
local function replaceChanged(io, staging, appFolder, changed, onFirstWrite)
  table.sort(changed, function(a, b)
    if (a == MAIN) ~= (b == MAIN) then return b == MAIN end
    return a < b
  end)
  local backup = staging .. '/avant'
  local saved = {}
  for _, rel in ipairs(changed) do
    local target = appFolder .. '/' .. rel
    local exists = fileExists(io, target)
    if exists == nil then return false, 'contrôle des fichiers impossible' end
    local okU, used = call(io.fileInUse, target)
    if exists and okU and used then return false, 'fichier utilisé par le jeu (' .. rel .. ')' end
    if exists then
      if not ensureDirs(io, backup, rel) then return false, 'dossier de sauvegarde impossible' end
      local okC, copied = call(io.copyFile, target, backup .. '/' .. rel, false)
      if not (okC and copied) then return false, 'copie de sauvegarde impossible (' .. rel .. ')' end
      saved[rel] = true
    end
  end
  local touched = {}
  if #changed > 0 and onFirstWrite then onFirstWrite() end
  for _, rel in ipairs(changed) do
    ensureDirs(io, appFolder, rel)
    touched[#touched + 1] = rel
    local okC, copied = call(io.copyFile, staging .. '/' .. M.ROOT .. rel, appFolder .. '/' .. rel, false)
    if not (okC and copied) then
      local mixed = false
      for _, back in ipairs(touched) do
        local target = appFolder .. '/' .. back
        if saved[back] then
          local okB, restored = call(io.copyFile, backup .. '/' .. back, target, false)
          if not (okB and restored) then
            -- copie refusée : le fichier est peut-être resté intact (la copie a échoué avant d'écrire)
            local okT, now = call(io.load, target)
            local okK, before = call(io.load, backup .. '/' .. back)
            mixed = mixed or not (okT and okK and type(now) == 'string' and now == before)
          end
        elseif fileExists(io, target) then
          local okR, removed = call(io.recycle, target)
          mixed = mixed or not (okR and removed)
        end
      end
      if mixed then return false, 'écriture refusée dans le dossier de l\'app (' .. rel .. '), installation mélangée', true end
      return false, 'écriture refusée dans le dossier de l\'app (' .. rel .. '), fichiers d\'avant remis'
    end
  end
  return true
end

-- Version installée, lue dans le manifeste du dossier de l'app (garde contre un dossier inattendu).
local function installedVersion(io, appFolder)
  local ok, text = call(io.load, appFolder .. '/manifest.ini')
  if not (ok and type(text) == 'string') then return nil end
  return text:match('[\r\n]VERSION=([^\r\n]+)') or text:match('^VERSION=([^\r\n]+)')
end

-- Au clic : téléchargement, contrôles, extraction hors de l'app, vérification des fichiers extraits, remplacement des
-- fichiers qui changent (surveillance des fichiers de CSP en pause), fichiers périmés à la Corbeille, puis redémarrage de
-- l'app. paths = { app = dossier de l'app, temp = dossier temporaire } ; current : version en cours. onDone(ok, message)
-- est appelé à la fin. Un échec avant toute écriture dans l'app peut être retenté.
function M.apply(u, host, paths, current, onDone)
  local retry = u.state == 'failed' and not u.wrote
  if not ((u.state == 'available' or retry) and u.info) then return false end
  local web, io, ac = host.web, host.io, host.ac
  local info = u.info
  local function finish(ok, why, mixed)
    if ok then
      u.state = 'done'
    else
      u.state, u.why, u.mixed = 'failed', why, mixed == true
    end
    if onDone then onDone(ok, why, mixed == true) end
  end
  if not (paths and type(paths.app) == 'string' and paths.app ~= '' and type(paths.temp) == 'string' and paths.temp ~= '') then
    finish(false, 'dossiers inconnus')
    return false
  end
  if installedVersion(io, paths.app) ~= current or not fileExists(io, paths.app .. '/' .. MAIN) then
    finish(false, 'dossier de l\'app inattendu')
    return false
  end
  u.state = 'downloading'
  call(web.timeouts, 4000, 10000, 10000, 60000)
  local ok = call(web.get, info.url, { ['User-Agent'] = 'SetupLab' }, function(err, response)
    if err or type(response) ~= 'table' or response.status ~= 200 or type(response.body) ~= 'string' then
      finish(false, 'téléchargement impossible (' .. tostring(err or (type(response) == 'table' and response.status)) .. ')')
      return
    end
    local body = response.body
    if #body ~= info.size then
      finish(false, 'taille du téléchargement inattendue')
      return
    end
    local okH, sha = call(ac.checksumSHA256, body)
    if not (okH and M.hexOf(sha) == info.sha256) then
      finish(false, 'empreinte SHA-256 différente, rien n\'est installé')
      return
    end
    local okZ, entries = call(io.scanZip, body)
    local okM, manifest = call(io.loadFromZip, body, M.ROOT .. 'manifest.ini')
    local files, why = M.checkZip(okZ and entries or nil, info.version, okM and manifest or nil)
    if files == nil then
      finish(false, why)
      return
    end
    local okO, oldList = call(io.load, paths.app .. '/files.txt')
    local stale = M.staleFiles(okO and oldList or nil, files)
    local staging = paths.temp .. '/SetupLab-update-' .. info.version:gsub('[^%w%.%-]', '_')
    u.state = 'extracting'
    local okX = call(io.extractFromZipAsync, body, staging, nil, function(errX)
      if errX then
        finish(false, 'extraction impossible (' .. tostring(errX) .. ')')
        return
      end
      -- fichiers extraits identiques à l'archive vérifiée ; seuls ceux qui changent seront écrits
      local changed = {}
      for _, rel in ipairs(files) do
        local okS, staged = call(io.load, staging .. '/' .. M.ROOT .. rel)
        local okE, expected = call(io.loadFromZip, body, M.ROOT .. rel)
        if not (okS and okE and type(staged) == 'string' and staged == expected) then
          finish(false, 'extraction incomplète (' .. rel .. ')')
          return
        end
        local okA, current0 = call(io.load, paths.app .. '/' .. rel)
        if not (okA and current0 == staged) then changed[#changed + 1] = rel end
      end
      -- la voiture a pu quitter le stand pendant le téléchargement : rien n'est écrit, la mise à jour reste à refaire
      if paths.canWrite and not paths.canWrite() then
        finish(false, 'voiture sortie du stand pendant le téléchargement : réessayez au stand, voiture arrêtée')
        return
      end
      call(ac.pauseFilesWatching, true)
      local okR, whyR, mixed = replaceChanged(io, staging, paths.app, changed, function() u.wrote = true end)
      if okR then
        for _, rel in ipairs(stale) do
          if fileExists(io, paths.app .. '/' .. rel) then call(io.recycle, paths.app .. '/' .. rel) end
        end
        u.stale, u.changed = #stale, #changed
      end
      call(ac.pauseFilesWatching, false)
      if not okR then
        finish(false, whyR, mixed)
        return
      end
      finish(true, nil)
      -- nouvelle version chargée à l'image suivante (sinon, au prochain passage de la surveillance des fichiers)
      call(ac.restartApp)
    end)
    if not okX then finish(false, 'extraction refusée') end
  end)
  if not ok then finish(false, 'requête refusée') end
  return true
end

return M
