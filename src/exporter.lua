-- SetupLab — écriture des fichiers de setup (§12.3, D8, D17).
-- Seul module (avec store au J7) autorisé à écrire. Règles : un fichier écrit est toujours
-- nouveau (aucun écrasement), et tout fichier écrit est relu et comparé au contenu voulu. L'hôte est
-- injecté par la colle. D8 amendé le 22/10/2026 (décision de Vincent : « il ne reste que les fichiers V1,
-- V2, V3, pas les intermédiaires » ; meilleur tour réel dans le nom) : seul ce module peut aussi mettre à la
-- Corbeille ou renommer un fichier, et seulement un fichier écrit par SetupLab, intact (empreinte).
-- D8 amendé le 20/10/2026 (décision de Vincent) : seul ce module peut charger dans la voiture un
-- setup que SetupLab a écrit (ac.loadSetup), au stand, menu de setup ouvert, après confirmation et copie
-- de sauvegarde du setup en cours (contrôles de la colle). Aucun fichier n'est modifié ;
-- ac.setSetupSpinnerValue et ac.saveCurrentSetup restent interdits. Depuis la 1.4.0 (noms choisis par
-- Vincent, mémoire du circuit), « écrit par SetupLab » se prouve par le nom et l'empreinte du contenu
-- relevés à l'écriture (séance) ou gardés en mémoire, plus par le préfixe du nom.

local Util = require('src/util')
local Config = require('src/config')
local K = Config.K

local M = {}

local get, call = Util.get, Util.call

-- Dossier cible : <setups>/<voiture>/<circuit sans disposition>/ (forme des dossiers existants).
function M.targetFolder(host)
  local ac = host.ac
  local okF, root = call(get(ac, 'getFolder'), get(get(ac, 'FolderID'), 'UserSetups'))
  if not okF or type(root) ~= 'string' or root == '' then return nil, 'dossier des setups inconnu' end
  local okC, carId = call(get(ac, 'getCarID'), 0)
  if not (okC and Util.isSafeId(carId)) then return nil, 'identifiant de voiture refusé : ' .. tostring(carId) end
  local okT, trackId = call(get(ac, 'getTrackID'))
  if not (okT and Util.isSafeId(trackId)) then return nil, 'identifiant de circuit refusé : ' .. tostring(trackId) end
  return root .. '/' .. carId .. '/' .. trackId, nil
end

-- Premier nom libre : base.ini, puis base-2.ini, base-3.ini… (jamais d'écrasement, D8).
function M.freeName(host, folder, base)
  local fileExists = get(host.io, 'fileExists')
  for i = 1, K.exportMaxSuffix do
    local name = i == 1 and (base .. '.ini') or (base .. '-' .. i .. '.ini')
    local ok, taken = call(fileExists, folder .. '/' .. name)
    if not ok then return nil, 'io.fileExists : ' .. tostring(taken) end
    if taken ~= true then return name, nil end
  end
  return nil, 'plus de ' .. K.exportMaxSuffix .. ' fichiers du même nom'
end

-- Écrit text dans un nouveau fichier du dossier des setups, puis le relit.
-- Renvoie { ok, path, name, bytes, reason }.
function M.writeNew(host, base, text)
  local r = { ok = false }
  local io = host.io
  -- io.available (CSP 0.3) : faux ou en erreur, pas d'accès ; absente (CSP 0.2.11, la version gratuite, décision de
  -- Vincent du 22/10/2026 : l'app doit y fonctionner) : écriture tentée, le fichier relu fait foi
  local availableFn = get(io, 'available')
  if availableFn ~= nil then
    local okA, available = call(availableFn)
    if not (okA and available == true) then
      r.reason = 'pas d\'accès fichiers (io.available)'
      return r
    end
  end
  if type(text) ~= 'string' or #text == 0 then
    r.reason = 'contenu vide'
    return r
  end
  if #text > K.maxTextBytes then
    r.reason = 'contenu trop volumineux'
    return r
  end
  local folder, why = M.targetFolder(host)
  if folder == nil then
    r.reason = why
    return r
  end
  local name, whyName = M.freeName(host, folder, Util.sanitizeFileName(base))
  if name == nil then
    r.reason = whyName
    return r
  end
  local okN, acceptable = call(get(io, 'isFileNameAcceptable'), name)
  if okN and acceptable == false then
    r.reason = 'nom refusé par CSP : ' .. name
    return r
  end
  local path = folder .. '/' .. name
  r.path, r.name = path, name
  -- io.createFileDir renvoie false si le dossier existe déjà : seul io.save fait foi.
  local okD, dirError = call(get(io, 'createFileDir'), path)
  if not okD then
    r.reason = 'création du dossier impossible : ' .. tostring(dirError)
    return r
  end
  local okS, saved = call(get(io, 'save'), path, text, true)
  if not okS then
    r.reason = 'io.save : ' .. tostring(saved)
    return r
  end
  if saved ~= true then
    r.reason = 'io.save a refusé l\'écriture'
    return r
  end
  local okL, back = call(get(io, 'load'), path)
  if not okL or back ~= text then
    r.reason = 'relecture différente du contenu écrit'
    return r
  end
  call(get(host.ac, 'refreshSetups'))
  r.ok, r.bytes = true, #text
  return r
end

-- Test d'écriture du J0 (D17) : copie exacte du setup courant, relu au moment du clic.
-- Aucun réglage n'est modifié ; le fichier apparaît dans la liste des setups d'AC.
-- prefix (facultatif) : copie de sauvegarde avant un chargement (Config.exportBackupPrefix) ; stamp
-- (facultatif) : horodatage du nom déjà formé (heure locale), sinon epochSeconds en UTC.
function M.saveCopy(host, epochSeconds, prefix, stamp)
  local okT, text = call(get(host.ac, 'stringifyCurrentSetup'), true, false)
  if not okT or type(text) ~= 'string' or #text == 0 then
    return { ok = false, reason = 'setup courant illisible (ac.stringifyCurrentSetup)' }
  end
  local r = M.writeNew(host, (prefix or Config.exportTestPrefix) .. (stamp or Util.formatStamp(epochSeconds)), text)
  if r.ok then r.text = text end
  return r
end

-- Fichier name du dossier de la voiture et du circuit, écrit par SetupLab et intact (hash : empreinte du
-- contenu écrit) : son chemin et son contenu, ou nil et la raison.
function M.ownFile(host, name, hash)
  local folder, why = M.targetFolder(host)
  if folder == nil then return nil, why end
  if type(name) ~= 'string' or not name:match('%.ini$') or name:find('[/\\]') or name:find('..', 1, true) then
    return nil, 'nom refusé'
  end
  local path = folder .. '/' .. name
  local okL, text = call(get(host.io, 'load'), path)
  if not (okL and type(text) == 'string') then return nil, 'absent' end
  if hash == nil or Util.hashString(text) ~= hash then return nil, 'modifié depuis son écriture' end
  return path, text
end

-- Met à la Corbeille de Windows un fichier écrit par SetupLab, intact (io.recycle ; avant CSP 0.3 : suppression
-- définitive, SDK). Renvoie { ok, reason }.
function M.recycleOwn(host, name, hash)
  local path, text = M.ownFile(host, name, hash)
  if path == nil then return { ok = false, reason = text } end
  local okR, done = call(get(host.io, 'recycle'), path)
  if not (okR and done == true) then return { ok = false, reason = 'io.recycle : ' .. tostring(okR and 'refus' or done) } end
  call(get(host.ac, 'refreshSetups'))
  return { ok = true }
end

-- Renomme un fichier écrit par SetupLab, intact, en base.ini (premier nom libre : jamais d'écrasement), puis
-- relit le nouveau fichier. Renvoie { ok, name, path, reason }.
function M.renameOwn(host, name, hash, base)
  local path, text = M.ownFile(host, name, hash)
  if path == nil then return { ok = false, reason = text } end
  local folder = M.targetFolder(host)
  local newName, why = M.freeName(host, folder, Util.sanitizeFileName(base))
  if newName == nil then return { ok = false, reason = why } end
  local newPath = folder .. '/' .. newName
  local okM, moved = call(get(host.io, 'move'), path, newPath, false)
  if not (okM and moved == true) then return { ok = false, reason = 'io.move : ' .. tostring(okM and 'refus' or moved) } end
  local okL, back = call(get(host.io, 'load'), newPath)
  if not (okL and back == text) then return { ok = false, reason = 'relecture différente après renommage' } end
  call(get(host.ac, 'refreshSetups'))
  return { ok = true, name = newName, path = newPath }
end

-- Raison de refuser le chargement dans la voiture du fichier path, écrit par SetupLab (expected :
-- texte écrit), ou nil : fichier qui n'est pas un setup qualification ou course de SetupLab du dossier
-- de la voiture et du circuit actuels, modifié depuis son écriture, setup non modifiable maintenant
-- (CSP : « seulement depuis le menu de setup ») ou imposé par la session.
-- written : nom de fichier -> empreinte (Util.hashString) du contenu que SetupLab y a écrit.
function M.loadBlocker(host, path, expected, written)
  local folder, why = M.targetFolder(host)
  if folder == nil then return why end
  local name = type(path) == 'string' and path:sub(1, #folder + 1) == folder .. '/' and path:sub(#folder + 2) or nil
  if name == nil or name:find('/', 1, true) or name:find('\\', 1, true) or name:find('..', 1, true) then
    return 'fichier hors du dossier des setups de la voiture et du circuit'
  end
  if not name:match('%.ini$') then return 'fichier non écrit par SetupLab : ' .. name end
  if type(expected) ~= 'string' or #expected == 0 then return 'contenu attendu inconnu' end
  if not (type(written) == 'table' and written[name] ~= nil and written[name] == Util.hashString(expected)) then
    return 'fichier non écrit par SetupLab : ' .. name
  end
  local okL, back = call(get(host.io, 'load'), path)
  if not okL or type(back) ~= 'string' then return 'fichier introuvable ou illisible : ' .. name end
  if back ~= expected then return 'fichier modifié depuis son écriture : ' .. name end
  local okE, editable = call(get(host.ac, 'isSetupAvailableToEdit'))
  if not (okE and editable == true) then return 'setup non modifiable maintenant : ouvrir le menu de setup au stand' end
  -- setup imposé : refus aussi quand l'état est illisible
  local okS, sim = call(get(host.ac, 'getSim'))
  if not okS or get(sim, 'fixedSetup') ~= false then return 'setup imposé par la session (ou état illisible)' end
  return nil
end

-- Charge le fichier dans la voiture après un dernier contrôle (M.loadBlocker). Renvoie { ok, reason,
-- called } ; called : ac.loadSetup a été appelée (son issue compte pour la capacité setup_load).
function M.loadIntoCar(host, path, expected, written)
  local why = M.loadBlocker(host, path, expected, written)
  if why then return { ok = false, reason = why } end
  local okC, loaded = call(get(host.ac, 'loadSetup'), path)
  if not okC then return { ok = false, called = true, reason = 'ac.loadSetup : ' .. Util.truncate(tostring(loaded), 200) } end
  if loaded ~= true then return { ok = false, called = true, reason = 'ac.loadSetup a refusé le chargement' } end
  return { ok = true }
end

return M
