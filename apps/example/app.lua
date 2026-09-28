-- apps/example/app.lua
--
-- This file remains the worked SDK example, and also hosts the physical-phone bridge because
-- fxmanifest.lua already loads it as a shared script before every client script. Keeping the
-- bridge here means the full build can stay isolated on its branch without changing the stock
-- phone's manifest or app registry.
--
-- The physical bridge deliberately reuses the exact NUI callbacks already registered by
-- v-phone. A real handset never gets a second set of game powers: its browser request is routed
-- to the paired FiveM client and executed through the same callback the in-game CEF page uses.

local RES = GetCurrentResourceName()

if IsDuplicityVersion() then
    -- ══════════════════════════════════════════════════════════════
    -- Physical phone bridge - server
    -- ══════════════════════════════════════════════════════════════

    -- FiveM Enhanced currently has a regression where SetHttpHandler's body callback can fail
    -- to fire. The bridge therefore uses GET-only transport and chunks JSON into URL-safe base64
    -- path segments. That keeps the full phone usable without depending on request bodies.
    local PAIR_TTL = 600
    local SESSION_IDLE_TTL = 21600 -- six hours without a handset request
    local REQUEST_TTL_MS = 20000
    local CHUNK_TTL_MS = 30000
    local MAX_EVENT_QUEUE = 256
    local MAX_CHUNKS = 4096
    local MAX_CHUNK_CHARS = 6000

    local pairings = {}        -- code -> { source, identity, expires }
    local pairByPlayer = {}    -- source -> code
    local sessions = {}        -- token -> session
    local sessionByPlayer = {} -- source -> token
    local pending = {}         -- request id -> { source, token, response }
    local chunks = {}          -- token:request -> { total, parts, expires }
    local rate = {}            -- token -> { started, count }

    -- ReaperLink Voice endpoints. A room is keyed by the authoritative v-phone call id.
    -- Physical endpoints use the paired HTTP session; game endpoints use the normal FiveM client.
    local voiceById = {}       -- voice id -> { kind, token/source, callId }
    local voiceRooms = {}      -- call id string -> { [voiceId] = true }
    local voiceSignals = {}    -- physical session token -> { seq, events }
    local gameVoiceBySource = {}
    local mixedMembers = {}    -- call id string -> { [source] = true }
    local updateMixedMode

    math.randomseed(os.time() + GetGameTimer())

    local function htmlEscape(value)
        return tostring(value or '')
            :gsub('&', '&amp;')
            :gsub('<', '&lt;')
            :gsub('>', '&gt;')
            :gsub('"', '&quot;')
            :gsub("'", '&#39;')
    end

    local function send(res, status, contentType, body, extraHeaders)
        local headers = {
            ['Content-Type'] = contentType or 'text/plain; charset=utf-8',
            ['Cache-Control'] = 'no-store, no-cache, must-revalidate',
            ['Pragma'] = 'no-cache',
            ['Referrer-Policy'] = 'no-referrer',
            ['X-Content-Type-Options'] = 'nosniff',
        }
        for k, v in pairs(extraHeaders or {}) do headers[k] = v end
        res.writeHead(status or 200, headers)
        res.send(body or '')
    end

    local function sendJson(res, status, value)
        local ok, encoded = pcall(json.encode, value)
        if not ok then
            encoded = '{"error":"encode"}'
            status = 500
        end
        send(res, status or 200, 'application/json; charset=utf-8', encoded)
    end

    local function page(body)
        return [[<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="referrer" content="no-referrer"><title>ReaperLink</title>
<style>
*{box-sizing:border-box}html,body{margin:0;min-height:100%;background:#0b0b0f;color:#fff;font-family:system-ui,-apple-system,Segoe UI,sans-serif}
body{min-height:100vh;display:grid;place-items:center;padding:20px}
.card{width:min(94vw,430px);background:#18181e;border:1px solid #30303a;border-radius:24px;padding:24px;box-shadow:0 20px 70px #0009}
h1{font-size:25px;margin:0 0 10px}.muted{color:#aaa;line-height:1.45}.ok{color:#66d777}.bad{color:#ff6b6b}
input,button{width:100%;border-radius:14px;padding:15px;font-size:18px}
input{background:#0f0f14;color:#fff;border:1px solid #3b3b45;margin:12px 0;text-align:center;letter-spacing:5px}
button{border:0;background:#0a84ff;color:#fff;font-weight:750;cursor:pointer}
small{display:block;color:#777;margin-top:14px;line-height:1.35}
</style></head><body><main class="card">]] .. body .. [[</main></body></html>]]
    end

    local function sendHtml(res, body, status)
        send(res, status or 200, 'text/html; charset=utf-8', page(body))
    end

    local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    local function b64urlDecode(data)
        data = tostring(data or ''):gsub('-', '+'):gsub('_', '/')
        data = data .. string.rep('=', (4 - (#data % 4)) % 4)
        data = data:gsub('[^' .. B64 .. '=]', '')
        return (data:gsub('.', function(x)
            if x == '=' then return '' end
            local f = B64:find(x, 1, true)
            if not f then return '' end
            local r, n = '', f - 1
            for i = 6, 1, -1 do
                r = r .. ((n % 2 ^ i - n % 2 ^ (i - 1) > 0) and '1' or '0')
            end
            return r
        end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
            if #x ~= 8 then return '' end
            local c = 0
            for i = 1, 8 do
                if x:sub(i, i) == '1' then c = c + 2 ^ (8 - i) end
            end
            return string.char(c)
        end))
    end

    local function randomToken()
        local out = {}
        for i = 1, 8 do
            out[i] = ('%08x'):format(math.random(0, 0x7fffffff))
        end
        return table.concat(out)
    end


    local function randomVoiceId()
        local out = {}
        for i = 1, 3 do out[i] = ('%08x'):format(math.random(0, 0x7fffffff)) end
        return table.concat(out)
    end

    local function reaperLinkPublicBase()
        local base = tostring(GetConvar('reaperlink_public_url', '') or '')
        base = base:gsub('^%s+', '')
        base = base:gsub('%s+$', '')
        base = base:gsub('/+$', '')
        return base
    end


    local function reaperLinkVoiceConfig()
        local stun = tostring(GetConvar('reaperlink_voice_stun', '') or ''):gsub('^%s+', ''):gsub('%s+$', '')
        local turnUrl = tostring(GetConvar('reaperlink_voice_turn_url', '') or ''):gsub('^%s+', ''):gsub('%s+$', '')
        return {
            stun = stun,
            turn = {
                url = turnUrl,
                username = tostring(GetConvar('reaperlink_voice_turn_user', '') or ''),
                credential = tostring(GetConvar('reaperlink_voice_turn_pass', '') or ''),
            },
        }
    end

    local function voiceQueue(token)
        local q = voiceSignals[token]
        if not q then
            q = { seq = 0, events = {} }
            voiceSignals[token] = q
        end
        return q
    end

    local function voicePush(token, event)
        local q = voiceQueue(token)
        q.seq = q.seq + 1
        q.events[#q.events + 1] = { seq = q.seq, event = event }
        if #q.events > 256 then table.remove(q.events, 1) end
    end

    local function endpointSend(endpoint, event)
        if not endpoint or type(event) ~= 'table' then return end
        if endpoint.kind == 'physical' and endpoint.token then
            voicePush(endpoint.token, event)
        elseif endpoint.kind == 'game' and endpoint.source and GetPlayerName(endpoint.source) then
            TriggerClientEvent('v-phone:physical:gameVoiceEvent', endpoint.source, event)
        end
    end

    local function roomHasPhysical(callId)
        local room = voiceRooms[tostring(callId or '')]
        if not room then return false end
        for id in pairs(room) do
            local ep = voiceById[id]
            if ep and ep.kind == 'physical' then return true end
        end
        return false
    end

    local function removeVoiceEndpoint(voiceId, announce, refresh)
        local ep = voiceById[voiceId]
        if not ep then return end
        local key = tostring(ep.callId or '')
        local room = voiceRooms[key]
        if room then
            room[voiceId] = nil
            if announce then
                for peerId in pairs(room) do
                    endpointSend(voiceById[peerId], { type = 'peer-leave', peer = voiceId })
                end
            end
            if next(room) == nil then voiceRooms[key] = nil end
        end
        if ep.kind == 'game' and ep.source and gameVoiceBySource[ep.source] == voiceId then
            gameVoiceBySource[ep.source] = nil
        elseif ep.kind == 'physical' and ep.token then
            local s = sessions[ep.token]
            if s and s.voiceId == voiceId then
                s.voiceId = nil
                s.voiceJoined = false
            end
        end
        voiceById[voiceId] = nil
        if refresh ~= false and updateMixedMode then updateMixedMode(ep.callId) end
    end

    local function voiceLeave(token, announce)
        local s = sessions[token]
        if not s then return end
        local id = s.voiceId
        if id then removeVoiceEndpoint(id, announce, true) end
        s.voiceJoined = false
        s.voiceId = nil
        voiceSignals[token] = nil
    end

    local function newPairCode()
        for _ = 1, 60 do
            local code = tostring(math.random(100000, 999999))
            if not pairings[code] then return code end
        end
        return tostring(math.random(1000000, 9999999))
    end

    local function identityOf(src)
        if Core and Core.GetPlayer then
            local ok, p = pcall(Core.GetPlayer, src)
            if ok and p then
                local id = p.citizenid or p.identifier or p.charid or p.id
                if id ~= nil and tostring(id) ~= '' then return tostring(id) end
            end
        end

        for _, identifier in ipairs(GetPlayerIdentifiers(src) or {}) do
            if identifier:sub(1, 8) == 'license:' then return identifier end
        end
        return ('source:%s'):format(tostring(src))
    end

    local function endSession(token, tellClient)
        local s = sessions[token]
        if not s then return end
        voiceLeave(token, true)
        sessions[token] = nil
        rate[token] = nil

        if sessionByPlayer[s.source] == token then
            sessionByPlayer[s.source] = nil
        end

        for id, req in pairs(pending) do
            if req.token == token then
                sendJson(req.response, 410, { error = 'session-ended' })
                pending[id] = nil
            end
        end

        for key in pairs(chunks) do
            if key:sub(1, #token + 1) == token .. ':' then chunks[key] = nil end
        end

        if tellClient and GetPlayerName(s.source) then
            TriggerClientEvent('v-phone:physical:session', s.source, false)
        end
    end

    local function sessionForToken(token, touch)
        local s = sessions[token]
        if not s then return nil, 'nosession' end
        if not GetPlayerName(s.source) then
            endSession(token, false)
            return nil, 'offline'
        end
        if identityOf(s.source) ~= s.identity then
            endSession(token, true)
            return nil, 'character'
        end
        local now = os.time()
        if now - (s.lastSeen or s.created) > SESSION_IDLE_TTL then
            endSession(token, true)
            return nil, 'expired'
        end
        if touch ~= false then s.lastSeen = now end
        return s
    end


    local function bridgeState(src)
        if type(ReaperLinkCallBridgeState) ~= 'function' then return nil end
        local ok, state = pcall(ReaperLinkCallBridgeState, tonumber(src))
        if not ok or type(state) ~= 'table' or not state.id then return nil end
        return state
    end

    local function sourceHasPhysical(callId, src)
        local room = voiceRooms[tostring(callId or '')]
        if not room then return false end
        for id in pairs(room) do
            local ep = voiceById[id]
            if ep and ep.kind == 'physical' and ep.source == src then return true end
        end
        return false
    end

    local function clearGameEndpoints(callId)
        local room = voiceRooms[tostring(callId or '')]
        if not room then return end
        local ids = {}
        for id in pairs(room) do
            local ep = voiceById[id]
            if ep and ep.kind == 'game' then ids[#ids + 1] = id end
        end
        for _, id in ipairs(ids) do removeVoiceEndpoint(id, true, false) end
    end

    updateMixedMode = function(callId)
        callId = tonumber(callId)
        if not callId then return end
        local key = tostring(callId)
        local previous = mixedMembers[key] or {}
        local room = voiceRooms[key]

        local physicalSource
        if room then
            for id in pairs(room) do
                local ep = voiceById[id]
                if ep and ep.kind == 'physical' then physicalSource = ep.source break end
            end
        end

        if not physicalSource then
            for src in pairs(previous) do
                if GetPlayerName(src) then
                    TriggerClientEvent('v-phone:physical:voiceMode', src, {
                        enabled = false, callId = callId,
                    })
                end
            end
            mixedMembers[key] = nil
            clearGameEndpoints(callId)
            return
        end

        local state = bridgeState(physicalSource)
        if not state or tonumber(state.id) ~= callId then
            for src in pairs(previous) do
                if GetPlayerName(src) then
                    TriggerClientEvent('v-phone:physical:voiceMode', src, {
                        enabled = false, callId = callId,
                    })
                end
            end
            mixedMembers[key] = nil
            clearGameEndpoints(callId)
            return
        end

        local current = {}
        local ice = reaperLinkVoiceConfig()
        for _, raw in ipairs(state.members or {}) do
            local src = tonumber(raw)
            if src and GetPlayerName(src) then
                current[src] = true
                TriggerClientEvent('v-phone:physical:voiceMode', src, {
                    enabled = true,
                    callId = callId,
                    selfPhysical = sourceHasPhysical(callId, src),
                    ice = ice,
                })
            end
        end
        for src in pairs(previous) do
            if not current[src] and GetPlayerName(src) then
                TriggerClientEvent('v-phone:physical:voiceMode', src, {
                    enabled = false, callId = callId,
                })
            end
        end
        mixedMembers[key] = current
    end

    local function createSession(src, identity)
        local old = sessionByPlayer[src]
        if old then endSession(old, true) end

        local token
        repeat token = randomToken() until not sessions[token]

        local now = os.time()
        sessions[token] = {
            source = src,
            identity = identity,
            created = now,
            lastSeen = now,
            seq = 0,
            events = {},
        }
        sessionByPlayer[src] = token
        return token, sessions[token]
    end

    local function allowRequest(token)
        local now = GetGameTimer()
        local r = rate[token]
        if not r or now - r.started >= 10000 then
            rate[token] = { started = now, count = 1 }
            return true
        end
        r.count = r.count + 1
        return r.count <= 120
    end

    local function addMirrorEvent(src, message)
        local token = sessionByPlayer[src]
        if not token then return end
        local s = sessionForToken(token, false)
        if not s or type(message) ~= 'table' then return end

        -- FiveM owns call membership. The browser may only join the active call mirrored
        -- from its paired client; it never chooses an arbitrary voice room.
        if message.action == 'call' then
            local nextCall = type(message.call) == 'table' and message.call or nil
            local nextId = nextCall and nextCall.state == 'active' and tonumber(nextCall.id) or nil
            if s.voiceCallId ~= nextId then
                if s.voiceJoined then voiceLeave(token, true) end
                s.voiceCallId = nextId
            end
        end

        s.seq = s.seq + 1
        s.events[#s.events + 1] = { seq = s.seq, message = message }
        if #s.events > MAX_EVENT_QUEUE then table.remove(s.events, 1) end
    end

    local function mimeFor(path)
        local ext = path:match('%.([%w]+)$')
        ext = ext and ext:lower() or ''
        local map = {
            html = 'text/html; charset=utf-8',
            css = 'text/css; charset=utf-8',
            js = 'application/javascript; charset=utf-8',
            json = 'application/json; charset=utf-8',
            svg = 'image/svg+xml',
            png = 'image/png',
            jpg = 'image/jpeg',
            jpeg = 'image/jpeg',
            webp = 'image/webp',
            gif = 'image/gif',
            wav = 'audio/wav',
            ogg = 'audio/ogg',
            mp3 = 'audio/mpeg',
            webm = 'video/webm',
        }
        return map[ext] or 'application/octet-stream'
    end

    local function safeStaticPath(path)
        if type(path) ~= 'string' or path == '' then return nil end
        if path:find('..', 1, true) or path:find('\\', 1, true) then return nil end
        if path:sub(1, 5) == 'html/' or path:sub(1, 5) == 'apps/' or path:sub(1, 7) == 'sounds/' then
            return path
        end
        return nil
    end

    RegisterNetEvent('v-phone:physical:pairRequest', function()
        local src = source
        if not src or src <= 0 or not GetPlayerName(src) then return end

        local old = pairByPlayer[src]
        if old then pairings[old] = nil end

        local identity = identityOf(src)
        local code = newPairCode()
        pairings[code] = {
            source = src,
            identity = identity,
            expires = os.time() + PAIR_TTL,
        }
        pairByPlayer[src] = code

        local publicBase = reaperLinkPublicBase()
        local pairUrl = publicBase ~= '' and (publicBase .. '/pair/' .. code) or ''
        TriggerClientEvent('v-phone:physical:pairCode', src, code, PAIR_TTL, pairUrl, publicBase ~= '')
        if publicBase == '' then
            print('[ReaperLink] WARNING: reaperlink_public_url is not set. QR pairing cannot be generated.')
        end
        print(('[v-phone] physical pairing code %s created for %s (%d)'):format(
            code, GetPlayerName(src) or 'player', src))
    end)

    RegisterNetEvent('v-phone:physical:nuiReply', function(requestId, result)
        local src = source
        local id = tostring(requestId or '')
        local req = pending[id]
        if not req or req.source ~= src then return end

        local s = sessionForToken(req.token, false)
        pending[id] = nil
        if not s then
            sendJson(req.response, 410, { error = 'session-ended' })
            return
        end
        if result == nil then result = {} end
        sendJson(req.response, 200, result)
    end)

    RegisterNetEvent('v-phone:physical:nuiMessage', function(message)
        addMirrorEvent(source, message)
    end)


    RegisterNetEvent('v-phone:physical:gameVoiceJoin', function(callId)
        local src = source
        callId = tonumber(callId)
        local state = bridgeState(src)
        if not callId or not state or tonumber(state.id) ~= callId or not roomHasPhysical(callId) then
            TriggerClientEvent('v-phone:physical:gameVoiceEvent', src, {
                type = 'error', error = 'voice-room',
            })
            return
        end

        local old = gameVoiceBySource[src]
        if old then removeVoiceEndpoint(old, true, false) end

        local voiceId
        repeat voiceId = randomVoiceId() until not voiceById[voiceId]
        local endpoint = { kind = 'game', source = src, callId = callId }
        voiceById[voiceId] = endpoint
        gameVoiceBySource[src] = voiceId

        local key = tostring(callId)
        local room = voiceRooms[key]
        if not room then room = {}; voiceRooms[key] = room end
        local peers = {}
        for peerId in pairs(room) do peers[#peers + 1] = peerId end
        room[voiceId] = true

        for _, peerId in ipairs(peers) do
            endpointSend(voiceById[peerId], { type = 'peer-join', peer = voiceId })
        end
        TriggerClientEvent('v-phone:physical:gameVoiceEvent', src, {
            type = 'ready', voiceId = voiceId, callId = callId, peers = peers,
        })
        updateMixedMode(callId)
    end)

    RegisterNetEvent('v-phone:physical:gameVoiceSignal', function(peerId, payload)
        local src = source
        local mine = gameVoiceBySource[src]
        local me = mine and voiceById[mine] or nil
        local peer = voiceById[tostring(peerId or '')]
        if not me or me.kind ~= 'game' or me.source ~= src or not peer
            or tostring(peer.callId or '') ~= tostring(me.callId or '') then return end

        local ok, encoded = pcall(json.encode, payload)
        if not ok or type(payload) ~= 'table' or #encoded > 65536 then return end
        endpointSend(peer, { type = 'signal', peer = mine, data = payload })
    end)

    RegisterNetEvent('v-phone:physical:gameVoiceLeave', function(callId)
        local src = source
        local mine = gameVoiceBySource[src]
        local ep = mine and voiceById[mine] or nil
        if ep and (not callId or tonumber(callId) == tonumber(ep.callId)) then
            removeVoiceEndpoint(mine, true, true)
        end
    end)

    AddEventHandler('playerDropped', function()
        local src = source
        local gameVoice = gameVoiceBySource[src]
        if gameVoice then removeVoiceEndpoint(gameVoice, true, true) end
        local code = pairByPlayer[src]
        if code then pairings[code] = nil end
        pairByPlayer[src] = nil

        local token = sessionByPlayer[src]
        if token then endSession(token, false) end
    end)

    AddEventHandler('onResourceStop', function(resource)
        if resource ~= RES then return end
        for token in pairs(sessions) do endSession(token, false) end
    end)

    CreateThread(function()
        while true do
            Wait(30000)
            local now, tick = os.time(), GetGameTimer()

            for code, entry in pairs(pairings) do
                if not entry or entry.expires <= now or not GetPlayerName(entry.source) then
                    if entry and pairByPlayer[entry.source] == code then pairByPlayer[entry.source] = nil end
                    pairings[code] = nil
                end
            end

            for token, s in pairs(sessions) do
                if not s or not GetPlayerName(s.source)
                    or now - (s.lastSeen or s.created) > SESSION_IDLE_TTL
                    or identityOf(s.source) ~= s.identity then
                    endSession(token, s and GetPlayerName(s.source) ~= nil)
                end
            end

            for key, set in pairs(chunks) do
                if not set or set.expires <= tick then chunks[key] = nil end
            end
        end
    end)

    SetHttpHandler(function(req, res)
        local path = tostring(req.path or '/')

        if req.method ~= 'GET' then
            send(res, 405, 'text/plain; charset=utf-8', 'GET only')
            return
        end

        if path == '/' or path == '/physical' or path == '/physical/' then
            local base = '/' .. RES .. '/physical'
            sendHtml(res, ([[
<h1>ReaperLink</h1>
<p class="muted">In FiveM, type <b>/physicalpair</b>. Enter the six-digit code below.</p>
<form id="pair"><input id="code" inputmode="numeric" maxlength="7" placeholder="PAIR CODE" autocomplete="one-time-code"><button type="submit">Pair this phone</button></form>
<p id="status" class="muted"></p>
<small>The code is one-time use and expires after ten minutes. The paired browser only reaches the same v-phone callbacks your character already has.</small>
<script>
document.getElementById('pair').addEventListener('submit',function(e){
  e.preventDefault();
  var c=document.getElementById('code').value.replace(/\D/g,'');
  if(c) location.href=']] .. base .. [[/pair/'+c;
});
</script>]]))
            return
        end

        local pairCode = path:match('^/physical/pair/(%d+)$')
        if pairCode then
            local entry = pairings[pairCode]
            if not entry or entry.expires <= os.time() or not GetPlayerName(entry.source) then
                sendHtml(res, '<h1>Pairing expired</h1><p class="bad">Run <b>/physicalpair</b> again in FiveM.</p>', 403)
                return
            end
            if identityOf(entry.source) ~= entry.identity then
                pairings[pairCode] = nil
                if pairByPlayer[entry.source] == pairCode then pairByPlayer[entry.source] = nil end
                sendHtml(res, '<h1>Character changed</h1><p class="bad">Generate a new pairing code.</p>', 403)
                return
            end

            pairings[pairCode] = nil
            if pairByPlayer[entry.source] == pairCode then pairByPlayer[entry.source] = nil end

            local token = createSession(entry.source, entry.identity)
            TriggerClientEvent('v-phone:physical:session', entry.source, true)

            local location = ('/%s/physical/ui/%s'):format(RES, token)
            send(res, 302, 'text/plain; charset=utf-8', 'Pairing accepted', {
                ['Location'] = location,
            })
            return
        end

        local voiceJoinToken = path:match('^/physical/voice/join/([%w_-]+)$')
        if voiceJoinToken then
            local s = sessionForToken(voiceJoinToken)
            local state = s and bridgeState(s.source) or nil
            if not s or not s.voiceCallId or not state
                or tonumber(state.id) ~= tonumber(s.voiceCallId) then
                sendJson(res, 409, { error = 'no-active-call' })
                return
            end

            if not s.voiceId then
                local id
                repeat id = randomVoiceId() until not voiceById[id]
                s.voiceId = id
                voiceById[id] = {
                    kind = 'physical', token = voiceJoinToken,
                    source = s.source, callId = s.voiceCallId,
                }
            end

            local key = tostring(s.voiceCallId)
            local room = voiceRooms[key]
            if not room then room = {}; voiceRooms[key] = room end
            local peers = {}
            for peerId in pairs(room) do
                if peerId ~= s.voiceId then peers[#peers + 1] = peerId end
            end

            if not room[s.voiceId] then
                room[s.voiceId] = true
                s.voiceJoined = true
                for _, peerId in ipairs(peers) do
                    endpointSend(voiceById[peerId], { type = 'peer-join', peer = s.voiceId })
                end
            end

            local q = voiceQueue(voiceJoinToken)
            updateMixedMode(s.voiceCallId)
            sendJson(res, 200, {
                ok = true, voiceId = s.voiceId, callId = s.voiceCallId,
                peers = peers, seq = q.seq,
            })
            return
        end

        local voiceLeaveToken = path:match('^/physical/voice/leave/([%w_-]+)$')
        if voiceLeaveToken then
            local s = sessionForToken(voiceLeaveToken, false)
            if not s then sendJson(res, 403, { error = 'session' }); return end
            voiceLeave(voiceLeaveToken, true)
            sendJson(res, 200, { ok = true })
            return
        end

        local voicePollToken, voiceAfter = path:match('^/physical/voice/events/([%w_-]+)/(%d+)$')
        if voicePollToken then
            local s = sessionForToken(voicePollToken)
            if not s then sendJson(res, 403, { error = 'session' }); return end
            local q = voiceQueue(voicePollToken)
            local afterSeq = tonumber(voiceAfter) or 0
            local events = {}
            for _, entry in ipairs(q.events) do
                if entry.seq > afterSeq then events[#events + 1] = entry end
            end
            sendJson(res, 200, { ok = true, seq = q.seq, events = events })
            return
        end

        local vt, vr, vi, vn, vp =
            path:match('^/physical/voice/chunk/([%w_-]+)/([%w_-]+)/(%d+)/(%d+)/([%w_-]+)$')
        if vt then
            local s = sessionForToken(vt)
            if not s or not s.voiceJoined then
                sendJson(res, 403, { error = 'voice-session' }); return
            end
            local idx, total = tonumber(vi), tonumber(vn)
            if not idx or not total or idx < 1 or total < 1 or idx > total
                or total > MAX_CHUNKS or #vp > MAX_CHUNK_CHARS then
                sendJson(res, 400, { error = 'chunk' }); return
            end
            local key = 'voice:' .. vt .. ':' .. vr
            local set = chunks[key]
            if not set or set.total ~= total then
                set = { total = total, parts = {}, expires = GetGameTimer() + CHUNK_TTL_MS }
                chunks[key] = set
            end
            set.parts[idx] = vp
            set.expires = GetGameTimer() + CHUNK_TTL_MS
            sendJson(res, 200, { ok = true })
            return
        end

        local vst, vsr, vsp = path:match(
            '^/physical/voice/send/([%w_-]+)/([%w_-]+)/([%w_-]+)$')
        if vst then
            local s = sessionForToken(vst)
            local mine = s and s.voiceId and voiceById[s.voiceId] or nil
            local peer = voiceById[vsp]
            if not s or not s.voiceJoined or not mine or mine.kind ~= 'physical'
                or not peer or tostring(peer.callId or '') ~= tostring(mine.callId or '') then
                sendJson(res, 403, { error = 'voice-peer' }); return
            end

            local key = 'voice:' .. vst .. ':' .. vsr
            local set = chunks[key]
            if not set then sendJson(res, 400, { error = 'missing-chunks' }); return end
            local parts = {}
            for i = 1, set.total do
                if not set.parts[i] then
                    sendJson(res, 400, { error = 'missing-chunk' }); return
                end
                parts[i] = set.parts[i]
            end
            chunks[key] = nil

            local decoded = b64urlDecode(table.concat(parts))
            local ok, payload = pcall(json.decode, decoded)
            if not ok or type(payload) ~= 'table' or #decoded > 65536 then
                sendJson(res, 400, { error = 'signal' }); return
            end
            endpointSend(peer, { type = 'signal', peer = s.voiceId, data = payload })
            sendJson(res, 200, { ok = true })
            return
        end

        local uiToken = path:match('^/physical/ui/([%w_-]+)/*$')
        if uiToken then
            local s = sessionForToken(uiToken)
            if not s then
                sendHtml(res, '<h1>Session ended</h1><p class="bad">Run <b>/physicalpair</b> again.</p>', 403)
                return
            end

            local index = LoadResourceFile(RES, 'html/index.html')
            if not index then
                sendHtml(res, '<h1>Missing UI</h1><p class="bad">html/index.html could not be read.</p>', 500)
                return
            end

            local root = ('/%s/physical'):format(RES)
            local base = ('/%s/physical/files/%s/html/'):format(RES, uiToken)
            local injectHead = ('<base href="%s"><meta name="referrer" content="no-referrer">'):format(base)
            index = index:gsub('<head>', '<head>' .. injectHead, 1)

            local voiceCfg = json.encode(reaperLinkVoiceConfig()):gsub('</', '<\\/')
            local boot = ([[<script>
window.__VPHONE_PHYSICAL__={token:"%s",base:"%s",resource:"%s",voice:%s};
</script><script src="physical.js"></script>
<script src="reaperlink-voice.js"></script>
<script src="sdk.js"></script>]]):format(uiToken, root, RES, voiceCfg)

            index = index:gsub('<script src="sdk%.js"></script>', boot, 1)
            send(res, 200, 'text/html; charset=utf-8', index)
            return
        end

        local staticToken, staticPath = path:match('^/physical/files/([%w_-]+)/(.+)$')
        if staticToken and staticPath then
            local s = sessionForToken(staticToken)
            if not s then
                send(res, 403, 'text/plain; charset=utf-8', 'Session ended')
                return
            end
            staticPath = safeStaticPath(staticPath)
            if not staticPath then
                send(res, 400, 'text/plain; charset=utf-8', 'Bad path')
                return
            end
            local data = LoadResourceFile(RES, staticPath)
            if data == nil then
                send(res, 404, 'text/plain; charset=utf-8', 'Not found')
                return
            end
            send(res, 200, mimeFor(staticPath), data, {
                ['Cache-Control'] = 'private, max-age=300',
            })
            return
        end

        local chunkToken, requestId, chunkIndex, chunkTotal, piece =
            path:match('^/physical/chunk/([%w_-]+)/([%w_-]+)/(%d+)/(%d+)/([%w_-]+)$')
        if chunkToken then
            local s = sessionForToken(chunkToken)
            if not s then
                sendJson(res, 403, { error = 'session' })
                return
            end

            local idx, total = tonumber(chunkIndex), tonumber(chunkTotal)
            if not idx or not total or idx < 1 or total < 1 or idx > total
                or total > MAX_CHUNKS or #piece > MAX_CHUNK_CHARS then
                sendJson(res, 400, { error = 'chunk' })
                return
            end

            local key = chunkToken .. ':' .. requestId
            local set = chunks[key]
            if not set or set.total ~= total then
                set = { total = total, parts = {}, expires = GetGameTimer() + CHUNK_TTL_MS }
                chunks[key] = set
            end
            set.parts[idx] = piece
            set.expires = GetGameTimer() + CHUNK_TTL_MS
            sendJson(res, 200, { ok = true })
            return
        end

        local apiToken, requestId, callbackB64 =
            path:match('^/physical/api/([%w_-]+)/([%w_-]+)/([%w_-]+)$')
        if apiToken then
            local s = sessionForToken(apiToken)
            if not s then
                sendJson(res, 403, { error = 'session' })
                return
            end
            if not allowRequest(apiToken) then
                sendJson(res, 429, { error = 'rate' })
                return
            end
            if pending[requestId] then
                sendJson(res, 409, { error = 'duplicate' })
                return
            end

            local key = apiToken .. ':' .. requestId
            local set = chunks[key]
            if not set then
                sendJson(res, 400, { error = 'missing-body' })
                return
            end

            local pieces = {}
            for i = 1, set.total do
                if not set.parts[i] then
                    sendJson(res, 400, { error = 'missing-chunk', chunk = i })
                    return
                end
                pieces[i] = set.parts[i]
            end
            chunks[key] = nil

            local body = b64urlDecode(table.concat(pieces))
            local callbackName = b64urlDecode(callbackB64)
            if callbackName == '' or #callbackName > 96 then
                sendJson(res, 400, { error = 'callback' })
                return
            end

            local ok, data = pcall(json.decode, body ~= '' and body or '{}')
            if not ok or type(data) ~= 'table' then data = {} end

            pending[requestId] = {
                source = s.source,
                token = apiToken,
                response = res,
            }
            TriggerClientEvent('v-phone:physical:invoke', s.source, requestId, callbackName, data)

            SetTimeout(REQUEST_TTL_MS, function()
                local waiting = pending[requestId]
                if not waiting then return end
                pending[requestId] = nil
                sendJson(waiting.response, 504, { error = 'timeout', callback = callbackName })
            end)
            return
        end

        local eventToken, after = path:match('^/physical/events/([%w_-]+)/(%d+)$')
        if eventToken then
            local s = sessionForToken(eventToken)
            if not s then
                sendJson(res, 403, { error = 'session' })
                return
            end
            local last = tonumber(after) or 0
            local out = {}
            for _, entry in ipairs(s.events) do
                if entry.seq > last then
                    out[#out + 1] = entry
                    if #out >= 64 then break end
                end
            end
            sendJson(res, 200, {
                ok = true,
                seq = s.seq,
                events = out,
                player = GetPlayerName(s.source) or 'player',
            })
            return
        end

        local openToken = path:match('^/physical/open/([%w_-]+)$')
        if openToken then
            local s = sessionForToken(openToken)
            if not s then
                sendJson(res, 403, { error = 'session' })
                return
            end
            TriggerClientEvent('v-phone:physical:open', s.source)
            sendJson(res, 200, { ok = true })
            return
        end

        local disconnectToken = path:match('^/physical/disconnect/([%w_-]+)$')
        if disconnectToken then
            local s = sessionForToken(disconnectToken, false)
            if s then endSession(disconnectToken, true) end
            sendJson(res, 200, { ok = true })
            return
        end

        send(res, 404, 'text/plain; charset=utf-8', 'Not found')
    end)

    print(('[v-phone] physical full bridge ready at /%s/physical'):format(RES))
else
    -- ══════════════════════════════════════════════════════════════
    -- Physical phone bridge - client
    -- ══════════════════════════════════════════════════════════════

    -- This shared script loads BEFORE bridge/client/safety.lua. Capturing RegisterNUICallback
    -- here means the later safety wrapper still does its normal exception/always-answer work,
    -- while every final wrapped callback is also available to the paired physical browser.
    local nativeRegisterNUICallback = RegisterNUICallback
    local physicalCallbacks = {}
    local physicalActive = false

    function RegisterNUICallback(name, handler)
        physicalCallbacks[tostring(name)] = handler
        return nativeRegisterNUICallback(name, handler)
    end

    function PhysicalBridgeActive()
        return physicalActive
    end

    function PhysicalInvokeNuiCallback(name, data, reply)
        local handler = physicalCallbacks[tostring(name or '')]
        if type(handler) ~= 'function' then
            reply({ error = 'no-callback', callback = tostring(name or '') })
            return
        end

        local answered = false
        local function answer(result)
            if answered then return end
            answered = true
            reply(result == nil and {} or result)
        end

        local ok, err = pcall(handler, type(data) == 'table' and data or {}, answer)
        if not ok then
            print(('[v-phone] physical callback %s raised: %s'):format(tostring(name), tostring(err)))
            answer({ error = 'x' })
        end
    end

    -- Mirror the same messages the stock client sends to CEF. When no real handset is paired,
    -- the wrapper is one native call and a boolean check.
    local nativeSendNUIMessage = SendNUIMessage
    function SendNUIMessage(message)
        local result = nativeSendNUIMessage(message)
        if physicalActive and type(message) == 'table' then
            TriggerServerEvent('v-phone:physical:nuiMessage', message)
        end
        return result
    end


    local mixedVoiceCallId = nil
    local mixedVoiceSelfPhysical = false

    function ReaperLinkMixedVoiceActive(callId)
        return mixedVoiceCallId ~= nil and tonumber(callId) == tonumber(mixedVoiceCallId)
    end

    RegisterNetEvent('v-phone:physical:voiceMode', function(data)
        data = type(data) == 'table' and data or {}
        local callId = tonumber(data.callId)
        if data.enabled == true and callId then
            mixedVoiceCallId = callId
            mixedVoiceSelfPhysical = data.selfPhysical == true
            pcall(function() exports['v-voice']:PhoneCallEnd(callId) end)
            if mixedVoiceSelfPhysical then
                nativeSendNUIMessage({ action = 'reaperlink:gameVoiceStop', callId = callId })
            else
                nativeSendNUIMessage({
                    action = 'reaperlink:gameVoiceStart',
                    callId = callId,
                    ice = data.ice,
                })
            end
            return
        end

        if mixedVoiceCallId and (not callId or callId == mixedVoiceCallId) then
            local old = mixedVoiceCallId
            mixedVoiceCallId = nil
            mixedVoiceSelfPhysical = false
            nativeSendNUIMessage({ action = 'reaperlink:gameVoiceStop', callId = old })
            if type(ReaperLinkCallIsActive) == 'function' and ReaperLinkCallIsActive(old) then
                pcall(function() exports['v-voice']:PhoneCallStart(old) end)
            end
        end
    end)

    RegisterNetEvent('v-phone:physical:gameVoiceEvent', function(event)
        if type(event) ~= 'table' then return end
        nativeSendNUIMessage({ action = 'reaperlink:gameVoiceEvent', event = event })
    end)

    RegisterNUICallback('reaperVoiceGameJoin', function(data, cb)
        local callId = tonumber(data and data.callId)
        if not callId or callId ~= mixedVoiceCallId or mixedVoiceSelfPhysical then
            cb({ error = 'voice-mode' }); return
        end
        TriggerServerEvent('v-phone:physical:gameVoiceJoin', callId)
        cb({ ok = true })
    end)

    RegisterNUICallback('reaperVoiceGameSignal', function(data, cb)
        if not mixedVoiceCallId or mixedVoiceSelfPhysical
            or type(data) ~= 'table' or type(data.data) ~= 'table' then
            cb({ error = 'voice-mode' }); return
        end
        TriggerServerEvent('v-phone:physical:gameVoiceSignal',
            tostring(data.peer or ''), data.data)
        cb({ ok = true })
    end)

    RegisterNUICallback('reaperVoiceGameLeave', function(data, cb)
        TriggerServerEvent('v-phone:physical:gameVoiceLeave',
            tonumber(data and data.callId) or mixedVoiceCallId)
        cb({ ok = true })
    end)

    RegisterNUICallback('reaperVoiceGameError', function(data, cb)
        print(('[ReaperLink Voice] game audio error: %s'):format(
            tostring(data and data.error or 'unknown')))
        cb({ ok = true })
    end)

    RegisterCommand('physicalpair', function()
        TriggerServerEvent('v-phone:physical:pairRequest')
    end, false)

    RegisterNetEvent('v-phone:physical:pairCode', function(code, seconds, pairUrl, configured)
        local msg = ('ReaperLink pairing code: %s (valid for %s seconds)'):format(
            tostring(code), tostring(seconds or 600))
        if type(pairUrl) == 'string' and pairUrl ~= '' then
            msg = msg .. (' | %s'):format(pairUrl)
        end
        print(('[ReaperLink] %s'):format(msg))

        if GetResourceState('chat') == 'started' then
            TriggerEvent('chat:addMessage', {
                color = { 200, 205, 212 },
                multiline = true,
                args = { 'ReaperLink', msg }
            })
        end

        CreateThread(function()
            ExecuteCommand('phone open')
            Wait(180)
            nativeSendNUIMessage({
                action = 'reaperlink:pairing',
                code = tostring(code),
                seconds = tonumber(seconds) or 600,
                url = type(pairUrl) == 'string' and pairUrl or '',
                configured = configured == true,
            })
        end)
    end)

    RegisterNetEvent('v-phone:physical:session', function(active)
        physicalActive = active == true
        if not physicalActive then return end

        -- Re-open once after pairing so the new browser receives a complete action=open payload
        -- even when the in-game handset was already open before the session existed.
        CreateThread(function()
            ExecuteCommand('phone close')
            Wait(150)
            ExecuteCommand('phone open')
        end)
    end)

    RegisterNetEvent('v-phone:physical:open', function()
        ExecuteCommand('phone open')
    end)

    RegisterNetEvent('v-phone:physical:invoke', function(requestId, callbackName, data)
        -- The server only emits this event for a validated live physical session. Do not gate
        -- it on the local mirror flag: the first browser callback can arrive in the same few
        -- milliseconds as the session-on event, and event ordering across the HTTP/client paths
        -- should not turn the phone's boot request into a false "session" error.
        if type(PhysicalInvokeNuiCallback) ~= 'function' then
            TriggerServerEvent('v-phone:physical:nuiReply', requestId, { error = 'bridge' })
            return
        end

        PhysicalInvokeNuiCallback(callbackName, data, function(result)
            TriggerServerEvent('v-phone:physical:nuiReply', requestId, result)
        end)
    end)
end

-- ══════════════════════════════════════════════════════════════
-- Original SDK example - still off by default
-- ══════════════════════════════════════════════════════════════
if not (Config and Config.SdkExample) then return end

PhoneApp {
    id       = 'example',
    label    = 'Example',
    icon     = 'note',
    category = 'utilities',
    desc     = 'The worked example: a folder dropped into apps/ and nothing else.',
    developer = 'iFruit SDK',
    version  = '2.0.0',
    accent   = '#0A84FF',
    permissions = { 'storage', 'contacts', 'photos', 'location', 'notifications' },
    features = { 'Persistent data', 'Native pickers', 'Quick actions', 'Live lifecycle' },
    keywords = { 'example', 'sdk', 'developer' },
    optional = true,
}
