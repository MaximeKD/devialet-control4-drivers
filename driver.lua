--[[
    Devialet IP Control - Control4 DriverWorks driver
    -----------------------------------------------------------------------
    v0.4 : CABLAGE DU MEDIA SERVICE PROXY (MSP)
      - Commandes de transport recues du Navigator (RFP.PLAY/PAUSE/...) -> HTTP Devialet
      - Etat Devialet (via WebSocket) -> pousse vers l'UI :
          UPDATE_MEDIA_INFO (titre/artiste/album/pochette),
          ProgressChanged (position), DashboardChanged (boutons transport)
      Interface MSP alignee sur l'exemple officiel "MSP By Numbers / 2-NowPlaying".

    v0.3 : resolution du system leader (stereo) + routage des commandes.
    v0.2 : infrastructure debug + proprietes de statut.

    NON couvert (TODO, exemples MSP By Numbers suivants) :
      - Navigation/browse des services (List + DATA_RECEIVED), file d'attente (queue)
      - Icones reelles (placeholders ici)
      - Mapping exact des champs metadata Devialet (a confirmer sur un GET reel)

    Dependances (drivers-common-public/) : websocket, metrics, handlers, timer, json.
]]

local WebSocket = require('drivers-common-public.module.websocket')
local JSON      = require('drivers-common-public.global.json')

local PROXY_MSP = 5001   -- proxybindingid du Media Service Proxy

--==========================================================================
-- [1] Infrastructure de DEBUG
--==========================================================================
local LOG = { NONE = 0, ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4, TRACE = 5 }
local SUBSYS = {
    GEN='GEN', HTTP='HTTP', WS='WS', SUB='SUB', PROXY='PROXY', NOTIF='NOTIF', TOPO='TOPO', MSP='MSP',
}
local gDebug = { print=false, log=false, level=LOG.NONE, subsystems={ALL=true}, autoOffMins=180 }
local DEBUG_TIMER = nil

local function emit(text)
    if (gDebug.print) then print(text) end
    if (gDebug.log) then local ok = pcall(function() C4:DebugLog(text) end); if (not ok) then print(text) end end
end
local function Log(level, subsys, msg)
    if (level > gDebug.level) then return end
    if (not gDebug.subsystems.ALL and not gDebug.subsystems[subsys]) then return end
    local names = {[1]='ERROR',[2]='WARN',[3]='INFO',[4]='DEBUG',[5]='TRACE'}
    emit(string.format('[Devialet][%s][%s] %s', names[level] or '?', subsys, tostring(msg)))
end
local function LogError(s,m) Log(LOG.ERROR,s,m) end
local function LogWarn (s,m) Log(LOG.WARN, s,m) end
local function LogInfo (s,m) Log(LOG.INFO, s,m) end
local function LogDebug(s,m) Log(LOG.DEBUG,s,m) end
local function LogTrace(s,m) Log(LOG.TRACE,s,m) end

--==========================================================================
-- [2] Etat global du driver
--==========================================================================
local DEV = {
    ip=nil, port=80, apiPath='/ipcontrol/v1',
    deviceId=nil, systemId=nil, isLeader=false, leaderId=nil, leaderHost=nil,
    ws=nil, connected=false, lastNotif='never',
    state = { volume=0, muted=false, playing=false, source=nil,
              title=nil, artist=nil, album=nil,
              coverArtPresent=false, coverArtUrl=nil, availableOps={},
              length=0, offset=0 },
}

local SUBSCRIPTIONS = {
    '/groups/current/sources/current',
    '/groups/current/sources/current/soundControl/volume',
    '/groups/current/sources/current/playback/position',
}

local function TargetHost() return DEV.leaderHost or DEV.ip end

--==========================================================================
-- [3] Proprietes de STATUT
--==========================================================================
local function SetOperationalStatus(status)
    C4:UpdateProperty('Operational Status', status)
    LogInfo(SUBSYS.GEN, 'Operational Status -> ' .. status)
end
local function UpdateInternalState()
    local s = DEV.state
    C4:UpdateProperty('Internal State', string.format(
        'entry=%s leaderHost=%s isLeader=%s system=%s | connected=%s | vol=%s mute=%s play=%s src=%s | %s - %s | lastNotif=%s',
        tostring(DEV.ip), tostring(DEV.leaderHost), tostring(DEV.isLeader), tostring(DEV.systemId),
        tostring(DEV.connected), tostring(s.volume), tostring(s.muted), tostring(s.playing),
        tostring(s.source), tostring(s.artist), tostring(s.title), tostring(DEV.lastNotif)))
end

--==========================================================================
-- [4] Application des Properties de debug
--==========================================================================
local function ApplyDebugMode(mode)
    mode = mode or 'Off'
    gDebug.print = (mode=='Print' or mode=='Print and Log')
    gDebug.log   = (mode=='Log'   or mode=='Print and Log')
    if (DEBUG_TIMER) then DEBUG_TIMER = C4:KillTimer(DEBUG_TIMER) end
    if (mode ~= 'Off') then
        DEBUG_TIMER = C4:SetTimer(gDebug.autoOffMins*60*1000, function()
            LogInfo(SUBSYS.GEN,'Auto-off du debug'); C4:UpdateProperty('Debug Mode','Off'); ApplyDebugMode('Off')
        end)
    end
    LogInfo(SUBSYS.GEN, 'Debug Mode = ' .. mode)
end
local function ApplyDebugLevel(s) gDebug.level = tonumber(string.match(tostring(s), '%d')) or 0 end
local function ApplyDebugSubsystems(str)
    str = tostring(str or 'ALL'); gDebug.subsystems = {}
    if (str=='' or str:upper()=='ALL') then gDebug.subsystems.ALL=true; return end
    for t in string.gmatch(str,'([^,%s]+)') do gDebug.subsystems[t:upper()]=true end
end

--==========================================================================
-- [5] Couche HTTP (ciblage du leader)
--==========================================================================
local function buildUrl(host, endpoint)
    return string.format('http://%s:%d%s%s', host, DEV.port, DEV.apiPath, endpoint)
end
local function httpGetHost(host, endpoint, onResult)
    if (host==nil or host=='') then return end
    LogDebug(SUBSYS.HTTP, 'GET ' .. buildUrl(host, endpoint))
    C4:url():OnDone(function(t, r, errCode, errMsg, data)
        if (errCode==0 and data) then
            local ok, dec = pcall(function() return JSON:decode(data) end)
            if (ok and onResult) then onResult(dec) end
        else LogError(SUBSYS.HTTP, 'GET '..endpoint..' err: '..tostring(errMsg)) end
    end):Get(buildUrl(host, endpoint))
end
local function isDispatchForbidden(data)
    return type(data)=='string' and string.find(data,'DispatchForbidden') ~= nil
end
local function httpPost(endpoint, body)
    local host = TargetHost()
    if (host==nil or host=='') then LogWarn(SUBSYS.HTTP,'POST ignore: pas d IP'); return end
    local url = buildUrl(host, endpoint)
    local data = body and JSON:encode(body) or ''
    LogDebug(SUBSYS.HTTP, 'POST '..url..'  body='..data)
    C4:url():OnDone(function(t, r, errCode, errMsg, resp)
        if (errCode~=0) then LogError(SUBSYS.HTTP,'POST '..endpoint..' err: '..tostring(errMsg)); SetOperationalStatus('HTTP error')
        elseif (isDispatchForbidden(resp)) then LogWarn(SUBSYS.TOPO,'DispatchForbidden sur '..endpoint..' -> re-resolution'); ResolveLeader()
        else LogTrace(SUBSYS.HTTP,'POST '..endpoint..' OK') end
    end):Post(url, data, { ['Content-Type']='application/json' })
end
local function httpGet(endpoint, onResult) httpGetHost(TargetHost(), endpoint, onResult) end

--==========================================================================
-- [6] Resolution du SYSTEM LEADER (stereo)
--==========================================================================
function ResolveLeader(onDone)
    if (DEV.ip==nil or DEV.ip=='') then if (onDone) then onDone(false) end; return end
    httpGetHost(DEV.ip, '/devices/current', function(dev)
        DEV.deviceId=dev.deviceId; DEV.systemId=dev.systemId; DEV.isLeader=(dev.isSystemLeader==true)
        if (DEV.isLeader or DEV.systemId==nil) then
            DEV.leaderId=DEV.deviceId; DEV.leaderHost=DEV.ip
            LogInfo(SUBSYS.TOPO,'Point d entree = leader (role='..tostring(dev.role)..')')
            UpdateInternalState(); if (onDone) then onDone(true) end; return
        end
        httpGetHost(DEV.ip, '/systems/'..DEV.systemId, function(sys)
            for _, d in ipairs(sys.devices or {}) do
                if (d.isSystemLeader==true) then
                    DEV.leaderId=d.deviceId
                    LogInfo(SUBSYS.TOPO,'Leader = '..tostring(d.deviceName)..' (role='..tostring(d.role)..')')
                end
            end
            -- Decouverte mDNS/SDDP ecartee : pas de resolution auto de l'IP du leader.
            -- L'installateur pointe le driver sur l'IP du leader (stable).
            DEV.leaderHost=nil
            SetOperationalStatus('Configurer l IP du system leader')
            UpdateInternalState(); if (onDone) then onDone(false) end
        end)
    end)
end

--==========================================================================
-- [7] Cycle de vie
--==========================================================================
function OnDriverInit() C4:AllowExecute(true) end

local function ConnectFlow()
    SetOperationalStatus('Connecting')
    ResolveLeader(function(ok)
        if (ok and TargetHost()) then StartWebSocket(); RefreshInitialState() end
    end)
end

function OnDriverLateInit()
    ApplyDebugMode(Properties['Debug Mode'])
    ApplyDebugLevel(Properties['Debug Level'])
    ApplyDebugSubsystems(Properties['Debug Subsystems'])
    C4:UpdateProperty('Driver Version', '0.4.3')
    LogInfo(SUBSYS.GEN, 'OnDriverLateInit')
    DEV.ip = Properties['Device IP Address']
    if (DEV.ip~=nil and DEV.ip~='') then ConnectFlow() else SetOperationalStatus('No IP configured') end
    UpdateInternalState()
end

function OnPropertyChanged(strName)
    local val = Properties[strName]
    LogDebug(SUBSYS.GEN, 'OnPropertyChanged: '..tostring(strName))
    if (strName=='Device IP Address') then DEV.ip=val; DEV.leaderHost=nil; RestartWebSocket()
    elseif (strName=='Debug Mode') then ApplyDebugMode(val)
    elseif (strName=='Debug Level') then ApplyDebugLevel(val)
    elseif (strName=='Debug Subsystems') then ApplyDebugSubsystems(val) end
end

function OnDriverDestroyed()
    if (DEBUG_TIMER) then DEBUG_TIMER = C4:KillTimer(DEBUG_TIMER) end
    StopWebSocket()
end

--==========================================================================
-- [8] WebSocket (/notifications) vers le leader
--==========================================================================
function StartWebSocket()
    local host = TargetHost(); if (host==nil or host=='') then return end
    local wsUrl = string.format('ws://%s:%d%s/notifications', host, DEV.port, DEV.apiPath)
    LogInfo(SUBSYS.WS, 'Ouverture WebSocket: '..wsUrl)
    DEV.ws = WebSocket:new(wsUrl)
    DEV.ws:SetEstablishedFunction(function()
        DEV.connected=true; SetOperationalStatus('Online'); LogInfo(SUBSYS.WS,'WebSocket etablie')
        SendSubscriptions(); UpdateInternalState()
    end)
    DEV.ws:SetProcessMessageFunction(function(s) LogTrace(SUBSYS.WS,'RX: '..tostring(s)); HandleWebSocketMessage(s) end)
    DEV.ws:SetOfflineFunction(function() DEV.connected=false; SetOperationalStatus('Offline'); LogWarn(SUBSYS.WS,'offline'); UpdateInternalState() end)
    DEV.ws:SetClosedByRemoteFunction(function() DEV.connected=false; SetOperationalStatus('Closed by device'); LogWarn(SUBSYS.WS,'fermee par le device'); UpdateInternalState() end)
    DEV.ws:Start()
end
function StopWebSocket()
    if (DEV.ws) then LogInfo(SUBSYS.WS,'Fermeture WebSocket'); DEV.ws:Close(); DEV.ws:delete(); DEV.ws=nil end
    DEV.connected=false
end
function RestartWebSocket()
    StopWebSocket()
    if (DEV.ip~=nil and DEV.ip~='') then ConnectFlow() else SetOperationalStatus('No IP configured') end
end
function SendSubscriptions()
    if (not DEV.ws or not DEV.connected) then return end
    LogDebug(SUBSYS.SUB, 'Envoi abonnements ('..#SUBSCRIPTIONS..')')
    DEV.ws:Send(JSON:encode({ messageType='subscriptionManagement',
        messageData={ requiredSubscriptions=SUBSCRIPTIONS } }))
end

--==========================================================================
-- [9] Messages entrants du device -> etat -> MSP
--==========================================================================
function HandleWebSocketMessage(strData)
    local ok, msg = pcall(function() return JSON:decode(strData) end)
    if (not ok or type(msg)~='table') then LogWarn(SUBSYS.NOTIF,'Message non JSON ignore'); return end
    if (msg.messageType=='subscriptionManagement') then
        if (msg.messageData and msg.messageData.failedSubscriptions) then
            for _, ep in ipairs(msg.messageData.failedSubscriptions) do LogError(SUBSYS.SUB,'Abonnement echoue: '..tostring(ep)) end
        end
        LogInfo(SUBSYS.SUB,'Abonnements confirmes')
    elseif (msg.messageType=='notification') then
        DEV.lastNotif = tostring(os.date('%Y-%m-%d %H:%M:%S'))
        DispatchNotification(msg.subscription, msg.messageData)
    end
end

function DispatchNotification(subscription, data)
    if (data==nil) then return end
    LogDebug(SUBSYS.NOTIF, 'Notification: '..tostring(subscription))

    if (subscription=='/groups/current/sources/current/soundControl/volume') then
        DEV.state.volume = data.volume or DEV.state.volume
        -- Volume : gere cote endpoint audio (AUDIO_VOLUME), pas via le dashboard MSP.

    elseif (subscription=='/groups/current/sources/current') then
        -- Format reel confirme (Spotify + optique) :
        --   metadata.{title,artist,album,coverArtDataPresent,coverArtUrl,duration(ms)},
        --   playingState, muteState, source.{type,subType}, availableOperations[].
        local meta = data.metadata or {}
        DEV.state.title           = meta.title  or ''
        DEV.state.artist          = meta.artist or ''
        DEV.state.album           = meta.album  or ''
        DEV.state.coverArtPresent = (meta.coverArtDataPresent == true)
        DEV.state.coverArtUrl     = meta.coverArtUrl        -- URL externe (services streaming)
        if (tonumber(meta.duration)) then
            DEV.state.length = math.floor(tonumber(meta.duration) / 1000)  -- ms -> s
        end
        DEV.state.source       = data.source and data.source.type or DEV.state.source
        DEV.state.availableOps = data.availableOperations or {}
        if (data.playingState ~= nil) then DEV.state.playing = (data.playingState == 'playing') end
        if (data.muteState  ~= nil) then DEV.state.muted   = (data.muteState  == 'muted') end
        UpdateMediaInfo()
        UpdateProgress()
        UpdateDashboard()

    elseif (subscription=='/groups/current/sources/current/playback/position') then
        -- Format reel confirme : { position: <ms> }. La duree vient de metadata.duration.
        if (tonumber(data.position)) then
            DEV.state.offset = math.floor(tonumber(data.position) / 1000)  -- ms -> s
        end
        UpdateProgress()
    end
    UpdateInternalState()
end

function RefreshInitialState()
    httpGet('/groups/current/sources/current/soundControl/volume', function(d)
        if (d and d.volume) then DEV.state.volume=d.volume; UpdateInternalState() end
    end)
    httpGet('/groups/current/sources/current', function(d)
        if (d) then DispatchNotification('/groups/current/sources/current', d) end
    end)
end

--==========================================================================
-- [10] MEDIA SERVICE PROXY : notifications sortantes vers le Navigator
--   (forme alignee sur l'exemple officiel "MSP By Numbers / 2-NowPlaying")
--==========================================================================
-- Serialiseur minimal table plate -> XML (<k>v</k>), pour SEND_EVENT.
local function xmlFlat(t)
    local out = {}
    for k, v in pairs(t) do out[#out+1] = string.format('<%s>%s</%s>', k, tostring(v), k) end
    return table.concat(out)
end

-- Envoi d'un evenement asynchrone au(x) Navigator(s) : DashboardChanged, ProgressChanged...
local function SendEvent(name, argsTable)
    local data = (type(argsTable)=='table') and xmlFlat(argsTable) or tostring(argsTable)
    C4:SendToProxy(PROXY_MSP, 'SEND_EVENT', { NAVID=nil, ROOMS=nil, NAME=name, EVTARGS=data }, 'COMMAND')
end

-- Metadonnees de la piste en cours (barre + ecran Now Playing).
function UpdateMediaInfo()
    local s = DEV.state
    -- Pochette : 1) URL externe (Spotify, etc.) ; 2) endpoint coverArt du device ; 3) rien.
    local imageUrl = ''
    if (s.coverArtUrl and s.coverArtUrl ~= '') then
        imageUrl = s.coverArtUrl
    elseif (s.coverArtPresent and TargetHost()) then
        imageUrl = buildUrl(TargetHost(), '/groups/current/sources/current/coverArt')
    end
    local args = {
        TITLE   = s.title  or '',
        ARTIST  = s.artist or '',
        ALBUM   = s.album  or '',
        IMAGEURL= imageUrl,
    }
    LogDebug(SUBSYS.MSP, 'UPDATE_MEDIA_INFO '..tostring(s.artist)..' - '..tostring(s.title))
    C4:SendToProxy(PROXY_MSP, 'UPDATE_MEDIA_INFO', args, 'COMMAND', true)
end

-- Formate des secondes en m:ss
local function ConvertTime(sec)
    sec = math.max(math.floor(tonumber(sec) or 0), 0)
    return string.format('%d:%02d', math.floor(sec/60), sec % 60)
end

-- Barre de progression.
function UpdateProgress()
    local s = DEV.state
    local remaining = math.max((s.length or 0) - (s.offset or 0), 0)
    SendEvent('ProgressChanged', {
        length = s.length or 0,
        offset = s.offset or 0,
        label  = ConvertTime(s.offset) .. ' / -' .. ConvertTime(remaining),
    })
end

-- Boutons de transport, pilotes par availableOperations de la source courante.
-- (vide pour l'optique -> aucun bouton ; pause/next/previous/seek pour Spotify)
function UpdateDashboard()
    local ops = {}
    for _, op in ipairs(DEV.state.availableOps or {}) do ops[op] = true end
    local items = {}
    -- play/pause selon l'etat courant et la capacite
    if (DEV.state.playing and ops.pause) then items[#items+1] = 'Pause'
    elseif (not DEV.state.playing and (ops.play or ops.pause)) then items[#items+1] = 'Play' end
    if (ops.previous) then items[#items+1] = 'SkipRev' end
    if (ops.next)     then items[#items+1] = 'SkipFwd' end
    SendEvent('DashboardChanged', { Items = table.concat(items, ' ') })
end

--==========================================================================
-- [11] MEDIA SERVICE PROXY : commandes entrantes (Navigator -> driver)
--==========================================================================
RFP = {}   -- table de dispatch, cle = nom de commande MSP

-- Transport : on envoie a Devialet PUIS on rafraichit l'UI.
function RFP.PLAY()     httpPost('/groups/current/sources/current/playback/play');     DEV.state.playing=true;  UpdateDashboard() end
function RFP.PAUSE()    httpPost('/groups/current/sources/current/playback/pause');    DEV.state.playing=false; UpdateDashboard() end
function RFP.STOP()     httpPost('/groups/current/sources/current/playback/pause');    DEV.state.playing=false; UpdateDashboard() end
function RFP.SKIP_FWD() httpPost('/groups/current/sources/current/playback/next') end
function RFP.SKIP_REV() httpPost('/groups/current/sources/current/playback/previous') end

-- Cycle de vie cote Navigator / rafraichissements demandes par l'UI.
function RFP.DEVICE_SELECTED()   UpdateMediaInfo(); UpdateProgress(); UpdateDashboard() end
function RFP.DEVICE_DESELECTED() end
function RFP.GetDashboard()      UpdateDashboard(); UpdateProgress() end
function RFP.GetQueue()          UpdateDashboard() end  -- TODO : UpdateQueue() (exemple MSP suivant)

-- Volume/mute : arrivent generalement via l'endpoint audio ; geres ici par securite.
function RFP.SET_VOLUME_LEVEL(tParams)
    httpPost('/groups/current/sources/current/soundControl/volume', { volume = tonumber((tParams or {}).LEVEL) or 0 })
end
function RFP.PULSE_VOL_UP()   httpPost('/groups/current/sources/current/soundControl/volumeUp') end
function RFP.PULSE_VOL_DOWN() httpPost('/groups/current/sources/current/soundControl/volumeDown') end
function RFP.MUTE_ON()  httpPost('/groups/current/sources/current/playback/mute') end
function RFP.MUTE_OFF() httpPost('/groups/current/sources/current/playback/unmute') end

function ReceivedFromProxy(idBinding, strCommand, tParams)
    strCommand = strCommand or ''
    tParams = tParams or {}
    LogDebug(SUBSYS.PROXY, 'Commande: '..strCommand)
    if (RFP[strCommand]) then
        RFP[strCommand](tParams)
    else
        LogWarn(SUBSYS.PROXY, 'Commande proxy non geree: '..strCommand)
    end
end
