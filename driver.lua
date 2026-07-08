--[[
    Devialet IP Control - Control4 DriverWorks driver (SQUELETTE / SKELETON)
    -----------------------------------------------------------------------
    Cible : enceinte Devialet auto-streaming, pilotée en HTTP (IP Control v1),
            feedback temps reel via WebSocket /notifications.

    Ce fichier est un POINT DE DEPART commente, pas un driver certifie.
    Les zones a completer avant soumission sont marquees  -- TODO CERTIF.

    Dependances (a copier dans le .c4z sous drivers-common-public/) :
      - drivers-common-public/module/websocket.lua
      - drivers-common-public/module/metrics.lua
      - drivers-common-public/global/handlers.lua
      - drivers-common-public/global/timer.lua
      - drivers-common-public/global/json.lua   (ou une autre lib JSON)
    Source : https://github.com/snap-one/drivers-common-public
]]

local WebSocket = require('drivers-common-public.module.websocket')
local JSON      = require('drivers-common-public.global.json')

--==========================================================================
-- Etat global du driver
--==========================================================================
local DEV = {
    ip        = nil,          -- adresse IP du speaker (via mDNS/SDDP ou Property)
    port      = 80,           -- port HTTP (txt record mDNS : port=80)
    apiPath   = '/ipcontrol/v1', -- global prefix HTTP (txt record : path=/ipcontrol/v1)
    ws        = nil,          -- objet WebSocket
    connected = false,        -- etat de la connexion WebSocket
    -- Etat courant du device (rempli par les notifications) :
    state = {
        volume   = 0,
        muted    = false,
        playing  = false,
        source   = nil,
        title    = nil,
        artist   = nil,
    },
}

-- Endpoints d'abonnement (SANS le global prefix, commencant par "/").
-- "current" fonctionne pour un speaker unique, que le stereo soit expose
-- comme 1 device ou comme 1 system a 2 devices.
-- TODO CERTIF : valider ces chemins sur le materiel reel (voir doc p.11 et p.117).
local SUBSCRIPTIONS = {
    '/groups/current/sources/current',                              -- source + metadonnees
    '/groups/current/sources/current/soundControl/volume',          -- volume
    '/groups/current/sources/current/playback/position',            -- transport / position
}

--==========================================================================
-- Cycle de vie du driver
--==========================================================================
function OnDriverInit()
    C4:AllowExecute(true)
end

function OnDriverLateInit()
    -- Recuperer l'IP depuis une Property (ou depuis SDDP, voir plus bas)
    DEV.ip = Properties['Device IP Address']
    if (DEV.ip ~= nil and DEV.ip ~= '') then
        StartWebSocket()
        RefreshInitialState()
    else
        C4:UpdateProperty('Connection Status', 'No IP configured')
    end
end

function OnPropertyChanged(strName)
    if (strName == 'Device IP Address') then
        DEV.ip = Properties['Device IP Address']
        RestartWebSocket()
    end
end

function OnDriverDestroyed()
    StopWebSocket()
end

--==========================================================================
-- Couche HTTP (commandes sortantes) via C4:url
--==========================================================================
-- Construit l'URL complete d'un endpoint HTTP
local function apiUrl(endpoint)
    return string.format('http://%s:%d%s%s', DEV.ip, DEV.port, DEV.apiPath, endpoint)
end

-- Envoie une commande POST (corps JSON optionnel) et log la reponse
local function httpPost(endpoint, body)
    if (DEV.ip == nil or DEV.ip == '') then return end
    local url  = apiUrl(endpoint)
    local data = body and JSON:encode(body) or ''
    local headers = { ['Content-Type'] = 'application/json' }

    C4:url()
        :OnDone(function(transfer, responses, errCode, errMsg)
            if (errCode ~= 0) then
                print('[Devialet] POST ' .. endpoint .. ' erreur: ' .. tostring(errMsg))
            end
        end)
        :Post(url, data, headers)
end

-- Lecture ponctuelle d'un endpoint (GET) pour l'init
local function httpGet(endpoint, onResult)
    if (DEV.ip == nil or DEV.ip == '') then return end
    C4:url()
        :OnDone(function(transfer, responses, errCode, errMsg, data)
            if (errCode == 0 and data) then
                local ok, decoded = pcall(function() return JSON:decode(data) end)
                if (ok and onResult) then onResult(decoded) end
            end
        end)
        :Get(apiUrl(endpoint))
end

--==========================================================================
-- WebSocket (/notifications) : feedback temps reel
--==========================================================================
function StartWebSocket()
    if (DEV.ip == nil or DEV.ip == '') then return end

    local wsUrl = string.format('ws://%s:%d%s/notifications', DEV.ip, DEV.port, DEV.apiPath)
    DEV.ws = WebSocket:new(wsUrl)

    DEV.ws:SetEstablishedFunction(function()
        DEV.connected = true
        C4:UpdateProperty('Connection Status', 'Connected')
        SendSubscriptions()          -- s'abonner des que le socket est ouvert
    end)

    DEV.ws:SetProcessMessageFunction(function(strData)
        HandleWebSocketMessage(strData)
    end)

    DEV.ws:SetOfflineFunction(function()
        DEV.connected = false
        C4:UpdateProperty('Connection Status', 'Offline')
        -- Le module gere deja des tentatives ; ici on peut logguer / notifier.
    end)

    DEV.ws:SetClosedByRemoteFunction(function()
        DEV.connected = false
        C4:UpdateProperty('Connection Status', 'Closed by device')
    end)

    DEV.ws:Start()
end

function StopWebSocket()
    if (DEV.ws) then
        DEV.ws:Close()
        DEV.ws:delete()
        DEV.ws = nil
    end
    DEV.connected = false
end

function RestartWebSocket()
    StopWebSocket()
    StartWebSocket()
    RefreshInitialState()
end

-- Envoie le message subscriptionManagement (doc p.11)
function SendSubscriptions()
    if (not DEV.ws or not DEV.connected) then return end
    local msg = {
        messageType = 'subscriptionManagement',
        messageData = { requiredSubscriptions = SUBSCRIPTIONS },
    }
    DEV.ws:Send(JSON:encode(msg))
end

--==========================================================================
-- Traitement des messages entrants du device
--==========================================================================
function HandleWebSocketMessage(strData)
    local ok, msg = pcall(function() return JSON:decode(strData) end)
    if (not ok or type(msg) ~= 'table') then return end

    if (msg.messageType == 'subscriptionManagement') then
        -- Reponse a notre demande d'abonnement (currentSubscriptions / failedSubscriptions)
        if (msg.messageData and msg.messageData.failedSubscriptions) then
            for _, ep in ipairs(msg.messageData.failedSubscriptions) do
                print('[Devialet] Abonnement echoue: ' .. tostring(ep))
            end
        end

    elseif (msg.messageType == 'notification') then
        -- messageData a le MEME format que la reponse GET de l'endpoint 'subscription'
        DispatchNotification(msg.subscription, msg.messageData)
    end
end

-- Route chaque notification vers la mise a jour d'etat + proxy MSP
function DispatchNotification(subscription, data)
    if (data == nil) then return end

    if (subscription == '/groups/current/sources/current/soundControl/volume') then
        DEV.state.volume = data.volume or DEV.state.volume
        -- TODO CERTIF : remonter au proxy audio / slider OS3
        -- C4:SendToProxy(PROXY_BINDING, 'VOLUME_LEVEL_CHANGED', { LEVEL = DEV.state.volume }, 'NOTIFY')

    elseif (subscription == '/groups/current/sources/current') then
        -- Metadonnees et source courante
        DEV.state.source = data.type or data.name
        -- data peut contenir titre/artiste selon la source ; adapter aux champs reels.
        -- TODO CERTIF : mapper vers le Media Service Proxy (titre, artiste, coverArt).

    elseif (subscription == '/groups/current/sources/current/playback/position') then
        -- Etat de lecture / position
        -- TODO CERTIF : remonter PLAY/PAUSE + progression au MSP.
    end
end

-- Lecture initiale de l'etat au demarrage (les notifications arrivent aussi
-- immediatement apres abonnement, mais un GET garantit l'etat avant connexion WS)
function RefreshInitialState()
    httpGet('/groups/current/sources/current/soundControl/volume', function(d)
        if (d and d.volume) then DEV.state.volume = d.volume end
    end)
end

--==========================================================================
-- Commandes recues du systeme Control4 (proxy) -> action HTTP
--==========================================================================
-- idBinding = binding du proxy (media_service / audio). tParams = table de params.
function ReceivedFromProxy(idBinding, strCommand, tParams)
    tParams = tParams or {}

    if (strCommand == 'ON' or strCommand == 'PLAY') then
        httpPost('/groups/current/sources/current/playback/play')

    elseif (strCommand == 'PAUSE') then
        httpPost('/groups/current/sources/current/playback/pause')

    elseif (strCommand == 'SKIP_FWD' or strCommand == 'NEXT') then
        httpPost('/groups/current/sources/current/playback/next')

    elseif (strCommand == 'SKIP_REV' or strCommand == 'PREVIOUS') then
        httpPost('/groups/current/sources/current/playback/previous')

    elseif (strCommand == 'MUTE_ON') then
        httpPost('/groups/current/sources/current/playback/mute')

    elseif (strCommand == 'MUTE_OFF') then
        httpPost('/groups/current/sources/current/playback/unmute')

    elseif (strCommand == 'SET_VOLUME_LEVEL') then
        -- Le proxy OS3 fournit un niveau 0..100 ; adapter a l'echelle Devialet si besoin.
        local level = tonumber(tParams.LEVEL) or 0
        httpPost('/groups/current/sources/current/soundControl/volume', { volume = level })

    elseif (strCommand == 'PULSE_VOL_UP') then
        httpPost('/groups/current/sources/current/soundControl/volumeUp')

    elseif (strCommand == 'PULSE_VOL_DOWN') then
        httpPost('/groups/current/sources/current/soundControl/volumeDown')

    else
        -- TODO CERTIF : completer avec les commandes du Media Service Proxy
        -- (navigation de sources, selection de service, etc.)
        print('[Devialet] Commande proxy non geree: ' .. tostring(strCommand))
    end
end
