-- GNS gate: a controller for its clients. Commands come as single modem messages (link.lua), as
-- in GDS; console, update and gatelog, too big for one message, over QuickOS api. The gate keeps
-- its settings, its own key pair and signed entry, its owner's key, the grants it has cut off and
-- the OC users of its computer; never other gates' entries (the address book lives on clients).
-- See docs/design/networks.md. Every function except open needs a device that has passed open
-- (handshake.lua: over link the gate keeps what each modem proved), and a role:
--   user   dial, close their own dial, the iris (on a registered gate, only with ownership or
--          a grant: not the public's), status, energy, GDO, signed pass, routes and dial-back
--   admin  also the console, the gate log, cutting off users, scheduled dials and remote updates
--          (a gate with an internet card also updates itself from GitHub every 2 hours)
--   owner  also cutting off admins
-- An unregistered gate, or a public one, gives everyone the user role; a registered private
-- gate gives roles only to its owner and to holders of the owner's grants. Anyone may hand a
-- gate a signed route (a relaying gate has no role of its own): the route's signer needs one.
local api = require("api")
local component = require("component")
local computer = require("computer")
local ecc = require("ecc")
local event = require("event")
local fs = require("filesystem")
local serialization = require("serialization")
local sides = require("sides")
local handshake = dofile("/usr/gns/handshake.lua")
local entries = dofile("/usr/gns/entries.lua")
local grants = dofile("/usr/gns/grants.lua")
local route = dofile("/usr/gns/route.lua")
local dialing = dofile("/usr/gns/dialing.lua")
local link = dofile("/usr/gns/link.lua")
local replace = dofile("/usr/gns/vault.lua").replace

local gate = {}

local TYPE, RANK = dialing.TYPE, grants.RANK
local ROUTE_WAIT = 60 -- seconds a route waits for the gate to be free, and for its wormhole to open
-- The gate log (gatelog, for admins): what happened at the gate, newest LOG_KEEP entries, in its
-- own file beside the state so it never fills the disk. Entries collect in memory and are written
-- in one open at most every LOG_FLUSH seconds, and when the gate stops, sleeps or restarts.
local LOG_KEEP, LOG_FLUSH = 500, 10
local SELF_UPDATE = 2 * 60 * 60 -- seconds between a gate's checks for a newer GNS on GitHub
local INSTALLER = "https://raw.githubusercontent.com/Renno231/Gate-Network-System/main/install.lua"

-- The gate's saved state: key pair (made on first run), its signed entry and sequence number,
-- owner (key and player), wake key, cut-off grant serials (cut, cutSeq), the admins it made OC
-- users ({[name] = serial}), scheduled routes, the last address dialed by hand on the DHD
-- and irisAsleep (the iris was shut for sleep). Gate computers start unattended, so the file
-- is not password-protected; the computer itself has to be kept out of reach.
function gate.load(path)
    local file = io.open(path, "rb") or io.open(path .. ".new", "rb") -- .new: cut off mid-replace
    local state = file and serialization.unserialize(file:read("*a"))
    if file then file:close() end
    if type(state) ~= "table" or type(state.identity) ~= "table" then
        local private, public = ecc.keypair()
        state = {identity = {private = tostring(private), public = tostring(public)}, seq = 0}
    end
    if state.book then -- a state from before owners and grants: only the key pair and entry carry over
        state.entry = state.book[state.identity.public]
        state.book, state.pins, state.net, state.trust = nil, nil, nil, nil
    end
    state.cut, state.cutSeq = state.cut or {}, state.cutSeq or 0
    state.admins, state.schedules = state.admins or {}, state.schedules or {}
    state.path = path
    return state
end

function gate.save(state)
    local path = state.path
    state.path = nil
    local data = serialization.serialize(state)
    state.path = path
    -- A short write would cost the gate its key pair and owner on the next start, so a full disk
    -- keeps the old state (vault.replace) and the save fails.
    assert(replace(path, data))
end

-- The gate's own address in every galaxy form JSG gives: {MW = {...}, PG = {...}, UN = {...}}.
local function addressOf(stargate)
    local address = {}
    for jsgName, glyphs in pairs(stargate.stargateAddress or {}) do
        if TYPE[jsgName] then address[TYPE[jsgName]] = glyphs end
    end
    return address
end

-- Signs the gate's entry again when its name, type, dimension or address changed. Returns it.
local function publish(state, stargate, settings)
    local fields = {name = settings.name, type = TYPE[stargate.getGateType()] or "MW", dim = settings.dim or 0,
        address = addressOf(stargate)}
    local own = state.entry
    if own then
        fields.seq, fields.key = own.seq, own.key
        if entries.signedBytes(fields) == entries.signedBytes(own) then return own end
    end
    state.seq = math.max(state.seq, own and own.seq or 0) + 1
    fields.seq = state.seq
    state.entry = entries.sign(state.identity, fields)
    gate.save(state)
    return state.entry
end

-- Starts the gate. stargate is the JSG stargate component (or a stand-in with the same
-- methods); dhd is the DHD component or nil; settings = {name, dim, port, kawoosh, idcs,
-- public, sleep, alarm, redstoneWake}, read live. Returns a node with the endpoint, the state,
-- the dialer, applyWake() and stop(). node.console(line, out), when set (server.lua), runs a
-- console command for an admin's console call.
function gate.start(state, stargate, settings, dhd)
    local sessions = setmetatable({}, {__mode = "k"}) -- tnet connection → {key, role, name, grant, cutSeq}
    -- Over link: modem address → its session, and → the proofs it last sent and was sent
    -- (handshake.lua), so opening again costs no signature check. At most MAX_DEVICES each.
    local devices, proofs, MAX_DEVICES = {}, {}, 128
    local caller -- {address, modem = {address}} while a link call is served
    -- Whether t holds MAX_DEVICES entries and not address.
    local function full(t, address)
        if t[address] then return false end
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n >= MAX_DEVICES
    end
    local function sessionOf()
        if caller then return devices[caller.address] end
        local conn = api.caller()
        return sessions[conn] or (conn and devices[conn.address])
    end
    local identity = state.identity
    local port = settings.port or handshake.PORT
    local modem = component.modem
    publish(state, stargate, settings)
    local dialer = dialing.new(stargate, dhd, settings)
    local node
    local lastUse, pending, alarm = computer.uptime(), 0, false
    local publicQueued = 0 -- routes queued by signers with no grant here (a public gate's)
    -- Every timer of this node goes through timer: once node.stop runs, each one drops the next
    -- time it fires, so a stopped gate dials, restarts and updates nothing more.
    local stopped = false
    local function timer(interval, fn, times)
        return event.timer(interval, function(...)
            if stopped then return false end
            return fn(...)
        end, times)
    end

    local history, historyDirty = {}, false
    local historyPath = state.path .. ".log"
    do
        local file = io.open(historyPath, "rb") or io.open(historyPath .. ".new", "rb") -- .new: cut off mid-replace
        local saved = file and serialization.unserialize(file:read("*a"))
        if file then file:close() end
        if type(saved) == "table" then history = saved end
    end
    local function record(text)
        history[#history + 1] = {os.date("%d %H:%M"), tostring(text)}
        while #history > LOG_KEEP do table.remove(history, 1) end
        historyDirty = true
    end
    local function flushHistory()
        if not historyDirty then return end
        historyDirty = false
        replace(historyPath, serialization.serialize(history)) -- a full disk keeps the old log
    end
    local historyTimer = timer(LOG_FLUSH, flushHistory, math.huge)
    -- The newest count entries (all when nil), newest first.
    local function newest(count)
        count = math.max(1, math.min(math.tointeger(tonumber(count)) or LOG_KEEP, LOG_KEEP))
        local out = {}
        for i = #history, math.max(1, #history - count + 1), -1 do out[#out + 1] = history[i] end
        return out
    end
    local function who(session) return session.name or "a public user" end
    local function addressText(address)
        local own = TYPE[stargate.getGateType()] or "MW"
        local glyphs = type(address) == "table" and (address[own] or address.MW or address.PG or address.UN) or {}
        return table.concat(type(glyphs) == "table" and glyphs or {}, ", ")
    end

    local function note(text)
        local log = dialer.log
        log[#log + 1] = text
        if #log > 20 then table.remove(log, 1) end
        record(text)
    end
    local function save() gate.save(state) end

    -- The wake triggers: the wake key on the modem (any message starting with it, so a tnet
    -- connection made with it wakes the gate too), and with a redstone card a wake threshold, so
    -- the DHD's signal on an incoming wormhole starts the computer.
    local function applyWake()
        if state.wake then pcall(modem.setWakeMessage, state.wake, true) end
        if component.isAvailable("redstone") then
            local threshold = settings.redstoneWake == false and 0 or math.tointeger(settings.redstoneWake) or 1
            pcall(component.redstone.setWakeThreshold, threshold)
        end
    end
    applyWake()

    -- Off-world activation: an incoming wormhole raises the alarm until a known IDC or a pass
    -- lets someone through, or it closes. The redstone output (settings.alarm: a side, or "all")
    -- drives the base's lights or doors; admin tablets in range hear a broadcast.
    local function setAlarm(on)
        if alarm == on then return end
        alarm = on
        local side = settings.alarm
        if side ~= nil and component.isAvailable("redstone") then
            local rs = component.redstone
            if side == "all" then
                for s = 0, 5 do pcall(rs.setOutput, s, on and 15 or 0) end
            else
                pcall(rs.setOutput, math.tointeger(sides[side]) or math.tointeger(side) or 0, on and 15 or 0)
            end
        end
        if on then
            note("off-world activation")
            pcall(modem.broadcast, port, "gns-alarm", settings.name or "?")
        end
    end
    dialer.on.incoming = function()
        record("incoming wormhole")
        setAlarm(true)
    end
    dialer.on.admitted = function(name)
        record(tostring(name or "a traveller") .. " let through the iris")
        setAlarm(false)
    end
    dialer.on.closed = function()
        record("wormhole closed")
        setAlarm(false)
    end
    if dialer.incoming then setAlarm(true) end -- woken by the DHD: the wormhole is already open
    -- A player dialed out by hand on the DHD: the gate keeps the address, so the devices that
    -- open it can save it to their address book.
    dialer.on.handDialed = function(address)
        state.handDialed = {address = address, time = os.date("%H:%M")}
        local _, glyphs = next(address)
        record("dialed by hand at the DHD: " .. table.concat(glyphs or {}, ", "))
        save()
    end
    dialer.adopt()
    -- Shut for the sleep (below): open again unless a wormhole is coming in, which waits for its IDC.
    -- While a wormhole forms JSG says only "unstable", not which way it goes, so that waits (at
    -- most 30 s) until it says; an incoming one keeps the iris shut (dialing.lua admits it).
    if state.irisAsleep then
        state.irisAsleep = nil
        save()
        local deadline = computer.uptime() + 30
        local function wake()
            local gateState, outgoing = stargate.getGateStatus()
            if gateState == "unstable" then return computer.uptime() < deadline end
            if gateState ~= "incoming" and not (gateState == "open" and not outgoing) then pcall(dialer.iris, "OPENED") end
            return false
        end
        if wake() then timer(0.25, wake, math.huge) end
    end

    local function status()
        local s = dialer.status()
        s.name, s.registered, s.public, s.alarm = settings.name, state.owner ~= nil, settings.public == true, alarm
        s.handDialed = state.handDialed
        s.seq = state.entry and state.entry.seq -- clients take a newer signed entry (a rename) when it changes
        return s
    end

    -- The role key has here, its player name when the role comes from ownership or a grant (nil
    -- for the public's user role), and the grant; or nil and the reason.
    local function roleFor(key, list)
        if state.owner and key == state.owner then return "owner", state.ownerName end
        local reason = "private gate"
        if state.owner and type(list) == "table" then
            -- A real list passes at its first good grant (one or two signatures; a cut-off grant
            -- costs none), so three signature checks a call bound what forged grants cost.
            local budget = {n = 3}
            for i = 1, math.min(#list, grants.MAX) do
                local role, why = grants.check(list[i], state.owner, identity.public, key, state.cut, budget)
                if role then return role, list[i].name, list[i] end
                reason = why
            end
        end
        if not state.owner or settings.public then return "user" end
        return nil, reason
    end

    -- The owner and each admin are OC users of the gate computer, so only they type at it. OC adds
    -- only a player who is online, so it is tried again each time they open the gate.
    local function isUser(name)
        for _, u in ipairs({computer.users()}) do if u == name then return true end end
        return false
    end
    local function addAdmin(name, serial)
        if state.admins[name] == serial or name == state.ownerName then return end
        pcall(computer.addUser, name)
        if not isUser(name) then return end
        state.admins[name] = serial
        save()
    end

    -- Wraps fn so it runs only for an opened connection whose role is at least minRole (nil:
    -- any opened connection). A grant cut off after the connection opened ends its role; the
    -- connection stays, as a guest refused for that reason. Each call counts as use for sleep,
    -- except a passive one (status, cost): a client in range polls those for every gate it lists.
    -- With settings.localOnly only a device on this computer (a client calling from one of its own
    -- cards, link.lua's local delivery) may use the gate; others keep only the calls marked
    -- travel: status, cost and the GDO pass, so travellers still get through the iris.
    local function opened(minRole, fn, passive, travel)
        return function(...)
            if stopped then error("the gate is stopped", 0) end
            local session = sessionOf()
            if not session then error("call open first", 0) end
            if settings.localOnly and not travel then
                local conn = caller or api.caller()
                if not (conn and component.list("modem")[conn.address]) then
                    error("this gate takes commands only from its own computer", 0)
                end
            end
            if session.grant and session.cutSeq ~= state.cutSeq then
                local role, why = grants.check(session.grant, state.owner, identity.public, session.key, state.cut)
                if not role then
                    session.role, session.name, session.grant, session.refused = nil, nil, nil, why
                else
                    session.cutSeq = state.cutSeq
                end
            end
            -- The public's user role ends once the gate is registered or made private.
            if session.role and not session.name and state.owner and not settings.public then
                session.role, session.refused = nil, "private gate"
            end
            if minRole then
                if not session.role then error(session.refused or "private gate", 0) end
                if RANK[session.role] < RANK[minRole] then error("needs the " .. minRole .. " role", 0) end
            end
            if not passive then lastUse = computer.uptime() end
            return fn(session, ...)
        end
    end

    ------------------------------------------------------------------------ routes
    local recent = {} -- route id .. hop → when it was taken here (a relaying gate may deliver one twice)
    local pins, ownProofs = {}, {} -- the gate keys seen, and this gate's proofs, by far gate modem

    -- Free: idle, no dial of GNS's own, and no player dialing at the DHD (dialer.handBusy).
    local function gateFree()
        if stargate.getGateStatus() ~= "idle" then return false end
        return not dialer.status().dialing and not dialer.handBusy()
    end

    -- Waits (on timers) until test() holds or seconds pass; then calls done(held).
    local function waitFor(test, seconds, done)
        local deadline = computer.uptime() + seconds
        local id
        id = timer(0.5, function()
            local ok, held = pcall(test)
            held = ok and held
            if held or computer.uptime() >= deadline then
                event.cancel(id)
                done(held)
            end
        end, math.huge)
    end

    -- Hands route r, from hop at, to the gate at the far end of this gate's open wormhole. A hop
    -- that names its gate's key (the client knew it) goes only to the gate proving that key, so no
    -- other device sees the route and its IDCs; a hop without one is offered to each GNS gate in
    -- range, and only the gate the previous hop dialed takes it (its queue checks the address).
    -- Over link.lua: each message is sent again until answered, so the relay's losses across the
    -- wormhole cost time, not the route. Gates are tried one at a time: a first open's signature
    -- checks hold this computer for seconds.
    -- The far iris may still be shut, waiting for the hop's IDC, and no message crosses it: ask
    -- again every 2 s while the wormhole stays open, up to RELAY_TRIES times.
    local RELAY_TRIES = 10
    local function relay(r, at, tries)
        tries = tries or 1
        local want = r.hops[at].gate
        local found = {}
        link.hello({[port] = true, [handshake.PORT] = true}, 2, function(address, p, _, hello)
            if not component.list("modem")[address] then found[#found + 1] = {address = address, port = p, name = hello.name} end
        end, function()
            local s, outgoing = stargate.getGateStatus()
            if #found == 0 and tries < RELAY_TRIES and s == "open" and outgoing then return relay(r, at, tries + 1) end
            local i = 0
            local function try()
                i = i + 1
                local host = found[i]
                if not host then
                    note(("route: no gate past the wormhole took hop %d"):format(at))
                    return
                end
                local proxy = link.proxy(host.address, host.port)
                handshake.openAsync(proxy, identity, pins, nil, function(reply, why)
                    if not reply then note(("route: %s: %s"):format(tostring(host.name), tostring(why))) return try() end
                    if want and reply.key ~= want then
                        note(("route: %s is not the gate hop %d names"):format(tostring(host.name), at))
                        return try()
                    end
                    proxy:async(function(ok, err)
                        if ok ~= true then note(("route: %s refused hop %d: %s"):format(tostring(host.name), at, tostring(err))) return try() end
                        note("route passed on to " .. tostring(reply.status and reply.status.name or host.name))
                    end).queue(r, at)
                end, ownProofs)
            end
            try()
        end)
    end

    -- Carries out hop at of route r: after its delay (and once the gate is free), dials it with
    -- its IDC; with hops left, passes the route on once the wormhole is open.
    local function run(r, at, public)
        local hop = r.hops[at]
        pending = pending + 1
        if public then publicQueued = publicQueued + 1 end
        timer(math.max(hop.delay, 0.05), function()
            waitFor(gateFree, ROUTE_WAIT, function(free)
                pending = pending - 1
                if public then publicQueued = publicQueued - 1 end
                if not free then note("route: the gate stayed busy") return end
                local ok, result = pcall(dialer.dial, hop.address, {fast = true, idc = hop.idc})
                if not ok then note("route: " .. tostring(result)) return end
                dialer.by = r.key
                if at < #r.hops then
                    pending = pending + 1
                    waitFor(function()
                        local s, outgoing = stargate.getGateStatus()
                        return s == "open" and outgoing and not dialer.status().dialing
                    end, ROUTE_WAIT, function(open)
                        pending = pending - 1
                        if open then relay(r, at + 1) else note("route: the wormhole did not open") end
                    end)
                end
            end)
        end)
    end

    -- Scheduled routes repeat every r.every seconds while the gate is up.
    local nextRun = {}
    for _, s in ipairs(state.schedules) do nextRun[s] = computer.uptime() + s.every end
    -- A schedule whose signer is no longer an admin here (its grant was cut off) is dropped: by
    -- the cut, and checked again each time one comes due. due(s): only those due now.
    local function dropStale(due)
        local dropped = 0
        for i = #state.schedules, 1, -1 do
            local s = state.schedules[i]
            if not due or due(s) then
                local role = roleFor(s.route.key, s.route.grants)
                if not role or RANK[role] < RANK.admin then
                    table.remove(state.schedules, i)
                    nextRun[s] = nil
                    dropped = dropped + 1
                end
            end
        end
        if dropped > 0 then
            save()
            record(("%d scheduled dial%s dropped: the signer is no longer an admin here"):format(dropped, dropped == 1 and "" or "s"))
        end
    end
    local scheduleTimer = timer(1, function()
        local now = computer.uptime()
        local function due(s)
            nextRun[s] = nextRun[s] or now + s.every
            return now >= nextRun[s]
        end
        dropStale(due)
        for _, s in ipairs(state.schedules) do
            if due(s) then
                nextRun[s] = now + s.every
                run(s.route, 1)
            end
        end
    end, math.huge)

    ------------------------------------------------------------------------ sleeping
    -- A gate with a wake key shuts down after settings.sleep idle minutes; a wake message or the
    -- DHD's redstone starts it again. Scheduled dials keep it up.
    -- A client running on this computer (gns.lua marks it): the gate neither sleeps nor restarts
    -- under the player using it.
    local function clientHere()
        local here = package.loaded["gns.here"]
        return here and here.client
    end
    local sleepTimer = timer(10, function()
        local minutes = tonumber(settings.sleep) or 0
        if minutes <= 0 or not state.wake or #state.schedules > 0 or settings.room then return end
        if pending > 0 or not gateFree() or alarm or clientHere() then lastUse = computer.uptime() return end
        if computer.uptime() - lastUse >= minutes * 60 then
            note("sleeping")
            -- Asleep the gate cannot check an IDC, so with IDCs set its iris stays shut until it wakes.
            -- An iris already shut (by hand) stays shut on waking: irisAsleep is only for one shut here.
            if next(settings.idcs or {}) and select(2, pcall(stargate.getIrisState)) == "OPENED"
                and pcall(dialer.iris, "CLOSED") then state.irisAsleep = true end
            save()
            flushHistory()
            computer.shutdown()
        end
    end, math.huge)

    ------------------------------------------------------------------------ remote update
    local DATA = {["gns/server/settings.lua"] = true, ["gns/client/settings.lua"] = true}
    local function updatable(path)
        return type(path) == "string" and not path:find("%.%.") and not DATA[path]
            and (path == "bin/gns.lua" or path:match("^gns/[%w_%-/]+%.lua$") ~= nil)
    end
    local function autorun()
        local file = io.open("/home/.shrc")
        if not file then return false end
        local on = false
        for line in file:lines() do on = on or line == "gns" end
        file:close()
        return on
    end

    -- A restart for new GNS files waits until the gate is idle: a restart mid-wormhole would shut
    -- the iris on travellers already let through and drop the dial's timers.
    -- The push in progress: {session, paths (written as .new), seen, part (the last taken)}.
    local staged
    local function dropStaged()
        if staged then for _, path in ipairs(staged.paths) do fs.remove(path .. ".new") end end
        staged = nil
    end
    local restarting = false
    local function restartWhenIdle()
        if restarting then return end
        restarting = true
        timer(2, function()
            if pending > 0 or not gateFree() or clientHere() then return end
            flushHistory()
            computer.shutdown(true)
        end, math.huge)
    end

    -- A gate with an internet card updates itself from GitHub, as GDS gates did: on start and
    -- every SELF_UPDATE seconds it runs GNS's installer (which downloads only what changed and
    -- replaces nothing until all of it has arrived) in a thread of its own, and restarts when
    -- that installed anything. A gate without one is updated by an admin's push (update).
    local updating = false
    local function installed()
        local file = io.open("/usr/gns/installed.lua", "rb")
        if not file then return nil end
        local text = file:read("*a")
        file:close()
        return text
    end
    -- Real time in milliseconds: the modification time of a file just written (OC has no clock).
    local function realNow()
        local file = io.open("/tmp/gns-now", "w")
        if not file then return nil end
        file:write("t")
        file:close()
        return fs.lastModified("/tmp/gns-now")
    end
    local function selfUpdate()
        if updating or not component.isAvailable("internet") then return end
        updating = true
        state.updateChecked = realNow()
        pcall(save)
        require("thread").create(function()
            local shell, temp, before = require("shell"), "/tmp/gns-install.lua", installed()
            if fs.exists(temp) then fs.remove(temp) end
            shell.execute("wget -fq " .. INSTALLER .. " " .. temp)
            if fs.exists(temp) then
                shell.execute(temp .. (fs.exists("/usr/gns/client/client.lua") and "" or " gate"))
                fs.remove(temp)
            end
            updating = false
            if stopped or installed() == before then return end
            local restart = autorun()
            note("updated GNS from GitHub" .. (restart and "; it restarts once idle" or "; restart gns to run it"))
            record("updated GNS from GitHub")
            if restart then restartWhenIdle() end
        end):detach()
    end
    local updateTimer = timer(SELF_UPDATE, selfUpdate, math.huge)
    timer(5, function()
        local now, last = realNow(), tonumber(state.updateChecked)
        if now and last and now >= last and now - last < SELF_UPDATE * 1000 then return end
        selfUpdate()
    end)

    ------------------------------------------------------------------------ the endpoint
    -- The caller's own dial, still live: GNS dialing it, or its outgoing wormhole open.
    local timedDial -- the dial whose close timer runs (dial's closeAfter); a later dial replaces it
    local function ownDial(session)
        if dialer.by ~= session.key then return false end
        local s = dialer.status()
        return s.dialing or (s.state == "open" and s.outgoing == true)
    end

    local lib = {
        open = {function(request)
            if stopped then error("the gate is stopped", 0) end
            local conn = caller or api.caller()
            -- A device opening again with the proof it sent before (link.lua keeps it): the same
            -- answer, with no signature check or signing.
            local kept = caller and proofs[conn.address]
            local reply, reason
            if kept and type(request) == "table" and kept.key == request.key and kept.nonce == request.nonce
                and kept.sig == request.sig and kept.modem == conn.modem.address then
                reply = {key = identity.public, sig = kept.reply}
            else
                reply, reason = handshake.accept(identity, conn, request)
                if not reply then error(reason, 0) end
                if caller then
                    if full(proofs, conn.address) then proofs = {} end -- each signs once more
                    proofs[conn.address] = {key = request.key, nonce = request.nonce, sig = request.sig,
                        modem = conn.modem.address, reply = reply.sig}
                end
            end
            local role, name, g = roleFor(request.key, request.grants)
            local session = {key = request.key, role = role, name = name, grant = g, cutSeq = state.cutSeq,
                refused = not role and name or nil}
            if caller then
                if full(devices, conn.address) then devices = {} end -- each opens again on "call open first"
                devices[conn.address] = session
            else
                sessions[conn] = session
            end
            reply.role, reply.owner, reply.registered = role, state.owner, state.owner ~= nil
            if role then
                reply.status, reply.entry = status(), state.entry
                if name then reply.wake = state.wake end
                if role == "admin" then addAdmin(name, g.serial) end
                if role == "owner" and not isUser(name) then pcall(computer.addUser, name) end
            else
                reply.refused = name
            end
            -- A refused device's client opens again at each rescan: only an opened one is use.
            if role then lastUse = computer.uptime() end
            return reply
        end, "Proves both sides' keys; returns the caller's role (from ownership, a grant or a public gate), the gate's status and entry"},

        register = {opened("user", function(session, player, wake)
            if state.owner then error("this gate already has an owner", 0) end
            if type(player) ~= "string" or #player == 0 or #player > 32 then error("bad player name", 0) end
            if type(wake) ~= "string" or #wake < 8 or #wake > 64 then error("bad wake key", 0) end
            state.owner, state.ownerName, state.wake = session.key, player, wake
            pcall(computer.addUser, player)
            applyWake()
            save()
            session.role, session.name = "owner", player
            record(player .. " registered the gate as its owner")
            return true
        end), "Makes the caller the owner of an unregistered gate: player becomes its OC user, wake its wake key"},

        status = {opened("user", function() return status() end, true, true), "The gate's name, type, state, iris, energy, TPS and last dial"},

        dial = {opened("user", function(session, address, opts)
            opts = type(opts) == "table" and opts or {}
            -- Dialing over an open outgoing wormhole closes it: the same rule as closeWormhole.
            local gateState, outgoing = stargate.getGateStatus()
            -- A dial that waited for the gate goes out from idle only, never over a new wormhole.
            if opts.wait and gateState ~= "idle" then error("already dialing", 0) end
            if gateState == "open" and outgoing and RANK[session.role] < RANK.admin and dialer.by ~= session.key then
                error("the gate is open to another player's dial: only who dialed, or an admin, can close it", 0)
            end
            local ok, result = pcall(dialer.dial, address, {fast = opts.fast == true, idc = math.tointeger(opts.idc), speed = tonumber(opts.speed)})
            if not ok then
                -- The client stops its own dial and dials again, unless it is to the same gate;
                -- another player's it waits out.
                local busy = result == "already dialing" or result == "already dialing it"
                if busy and ownDial(session) then
                    error(result == "already dialing it" and "your dial is in progress to it" or "your dial is in progress", 0)
                end
                if busy then result = "already dialing" end
                -- D2: a client waiting for the gate asks again each second; only other refusals are history.
                if result ~= "already dialing" and result ~= "already open to it" then
                    record(("%s was refused a dial to %s: %s"):format(who(session), addressText(address), tostring(result)))
                end
                error(result, 0)
            end
            dialer.by = session.key
            record(("%s dialed %s"):format(who(session), addressText(address)))
            -- closeAfter: the wormhole closes that many seconds after it opens, unless closed or
            -- dialed over meanwhile (GDS's close timer).
            local after = math.tointeger(tonumber(opts.closeAfter))
            if after and after > 0 then
                local mine = {}
                timedDial = mine
                waitFor(function()
                    local s, out = stargate.getGateStatus()
                    return timedDial ~= mine or (s == "open" and out)
                end, 120 + (tonumber(opts.speed) or 0) + 10, function(open)
                    if not open or timedDial ~= mine then return end
                    timer(after, function()
                        local s, out = stargate.getGateStatus()
                        if timedDial ~= mine or s ~= "open" or not out then return end
                        timedDial = nil
                        record(("the wormhole closed after %d s, as %s asked"):format(after, who(session)))
                        pcall(dialer.close)
                    end)
                end)
            else
                timedDial = nil
            end
            return result
        end), "Dials an address {MW = {...}, PG = {...}, UN = {...}}; opts {fast, idc, speed, wait (from idle only), closeAfter (seconds open)}. Returns the glyph count, cost and duration"},

        energy = {opened("user", function(_, address)
            return dialer.cost(address)
        end, true, true), "What dialing an address would cost and how long the wormhole could stay open"},

        closeWormhole = {opened("user", function(session)
            if RANK[session.role] < RANK.admin and not ownDial(session) then
                error("only who dialed, or an admin, can close it", 0)
            end
            record(who(session) .. " closed the wormhole")
            return dialer.close()
        end), "Stops a dial in progress or closes the outgoing wormhole (users: their own dial)"},

        sendIdc = {opened("user", function(session, code)
            code = math.tointeger(tonumber(code))
            if not code or code < 0 then error("bad IDC", 0) end
            record(who(session) .. " sent an IDC through the wormhole")
            return dialer.sendCode(code)
        end), "The GDO: sends a numeric IDC through the open outgoing wormhole"},

        challenge = {opened("user", function(session)
            session.challenge = tostring(ecc.random.random()):sub(1, 16)
            return session.challenge
        end, false, true), "A fresh challenge for a signed pass"},

        pass = {opened("user", function(session, sig)
            if not session.name then error("passes are for the owner and grant holders", 0) end
            local challenge = session.challenge
            session.challenge = nil
            -- Over link the device's open already proved its key from its own modem: no signature.
            if caller and sig == nil then
                record(session.name .. " sent a pass")
                return dialer.admit(session.name)
            end
            if not handshake.checkPass(session.key, challenge, identity.public, sig) then
                record(session.name .. " sent a bad pass")
                error("bad pass", 0)
            end
            record(session.name .. " sent a signed pass")
            return dialer.admit(session.name)
        end, false, true), "A signed pass for the incoming wormhole: opens the iris for the owner or a grant holder"},

        -- The iris: anyone who may dial an unregistered gate; on a registered one the owner and
        -- grant holders, not the public a public gate lets dial (they send an IDC instead).
        iris = {opened("user", function(session, want)
            if state.owner and not session.name then error("the iris needs a grant here", 0) end
            local target = ({open = "OPENED", close = "CLOSED"})[want]
            if want ~= nil and not target then error("open or close", 0) end
            local before = stargate.getIrisState()
            local now = dialer.iris(target)
            if now ~= before then
                record(("%s %s the iris"):format(who(session), before == "CLOSED" and "opened" or "closed"))
            end
            return now
        end), "Opens or closes the iris: want \"open\" or \"close\", alone the other way (users)"},

        queue = {opened(nil, function(_, r, at)
            at = math.tointeger(at) or 1
            local ok, why = route.verify(r)
            if not ok then error(why, 0) end
            if at < 1 or at > #r.hops then error("bad route", 0) end
            if at > 1 and not route.names(r.hops[at - 1].address, addressOf(stargate)) then error("not the next gate", 0) end
            if r.hops[at].gate and r.hops[at].gate ~= identity.public then error("not the next gate", 0) end
            local role, name = roleFor(r.key, r.grants)
            if not role then error("the route's signer has no access here", 0) end
            if recent[r.id .. at] then return "already queued" end
            -- Anyone may sign a route for a public gate, with up to an hour's delay: the public
            -- shares 8 places, so it never crowds out the owner's and grant holders' routes.
            if pending >= 24 or (not name and publicQueued >= 8) then error("too many queued dials", 0) end
            local now = computer.uptime()
            for id, at0 in pairs(recent) do if now - at0 > 7200 then recent[id] = nil end end
            if r.every > 0 then
                if RANK[role] < RANK.admin then error("scheduled dials need the admin role", 0) end
                if #state.schedules >= 16 then error("too many scheduled dials", 0) end
                state.schedules[#state.schedules + 1] = {route = r, every = r.every}
                recent[r.id .. at] = now
                save()
                record(("a dial every %d s was scheduled"):format(r.every))
                return "scheduled"
            end
            recent[r.id .. at] = now
            record(("a route was queued (hop %d of %d)"):format(at, #r.hops))
            run(r, at, not name)
            return "queued"
        end), "Takes a signed route: dials its hop after its delay and passes the rest on; every > 0 schedules it (admin)"},

        cut = {opened("admin", function(session, list)
            if type(list) ~= "table" then error("bad list", 0) end
            local count = 0
            for i = 1, math.min(#list, 64) do
                local g = list[i]
                local real = type(g) == "table" and grants.check(g, state.owner, identity.public, g.holder, {})
                if real and not state.cut[g.serial] and (g.role == "user" or session.role == "owner") then
                    state.cut[g.serial] = g.name
                    count = count + 1
                    if g.role == "admin" and state.admins[g.name] == g.serial then
                        pcall(computer.removeUser, g.name)
                        state.admins[g.name] = nil
                    end
                end
            end
            if count > 0 then
                state.cutSeq = state.cutSeq + 1
                dropStale()
                save()
                record(("%s cut off %d grant%s"):format(who(session), count, count == 1 and "" or "s"))
            end
            return count
        end), "Cuts off grants (admins: user grants; the owner: any). Returns how many were new here"},

        console = {opened("admin", function(session, line)
            if not node.console then error("this gate has no console", 0) end
            if type(line) ~= "string" or #line > 256 then error("bad command line", 0) end
            note("console " .. tostring(session.name or "?") .. ": " .. line)
            local lines = {}
            node.console(line, function(text) lines[#lines + 1] = tostring(text) end)
            return lines
        end), "Runs a gate console command (admin); returns its output lines"},

        update = {opened("admin", function(session, files, part, parts)
            -- A push comes in parts (part n of parts; one when absent), each an RPC well inside
            -- TNET's 10 s: each part is written as .new files, and the last swaps them all in.
            part, parts = tonumber(part) or 1, tonumber(parts) or 1
            if part == 1 or (staged and (staged.session ~= session or staged.part ~= part - 1)) then dropStaged() end
            if part > 1 and not staged then error("the push's earlier parts are missing; push again", 0) end
            staged = staged or {session = session, paths = {}, seen = {}}
            staged.part = part
            local written, seen = staged.paths, staged.seen
            if type(files) ~= "table" or #files == 0 or #written + #files > 64 then dropStaged() error("bad file list", 0) end
            for _, f in ipairs(files) do
                if type(f) ~= "table" or not updatable(f[1]) or type(f[2]) ~= "string" then
                    dropStaged()
                    error("not a GNS file: " .. tostring(type(f) == "table" and f[1]), 0)
                end
                if seen[f[1]] then dropStaged() error(f[1] .. " is listed twice", 0) end
                seen[f[1]] = true
            end
            local drop = dropStaged
            for _, f in ipairs(files) do
                local path = "/usr/" .. f[1]
                fs.makeDirectory(fs.path(path))
                local file = io.open(path .. ".new", "wb")
                local wrote = file and file:write(f[2])
                if file then file:close() end
                written[#written + 1] = path
                -- OpenOS drops the last flush's error on close: a full disk shows only in the size.
                if not wrote or fs.size(path .. ".new") ~= #f[2] then
                    drop()
                    error("could not write " .. path .. ": the disk is full; nothing was changed", 0)
                end
            end
            if part < parts then return #files end
            staged = nil
            local failed = {}
            for _, path in ipairs(written) do
                if fs.exists(path) then fs.remove(path) end
                if not fs.rename(path .. ".new", path) then failed[#failed + 1] = path end
            end
            if #failed > 0 then error("could not replace " .. table.concat(failed, ", "), 0) end
            note(("updated %d files (%s)"):format(#written, tostring(session.name)))
            local restart = autorun()
            if restart then restartWhenIdle() end
            return #written, restart
        end), "Writes new GNS files {{path under /usr, contents}, ...} (admin), as part n of parts; restarts the gate once idle when gns autoruns"},

        gatelog = {opened("admin", function(_, count) return newest(count) end),
            "The gate log, newest first: {time, text} entries, count at most 500 (admin)"},
    }
    node = {state = state, dialer = dialer, applyWake = applyWake, save = save, status = status, record = record,
        history = newest, endpoint = api.expose(handshake.ENDPOINT, lib, port)}

    ------------------------------------------------------------------------ link
    -- Calls as single modem messages (link.lua). Each answer is kept link.KEEP seconds, so a call
    -- heard again is answered again, never run twice. hello needs no open: it says who the gate is.
    local LINKED = {open = true, register = true, status = true, dial = true, energy = true, closeWormhole = true,
        sendIdc = true, challenge = true, pass = true, iris = true, queue = true, cut = true}
    local answered = {} -- modem .. call id → {at, ok, text}
    -- Devices watching the gate's status: modem → {untilAt, port, via (the card that heard it)}. A call from a device with a role
    -- watches for 60 s; on each change of state the gate sends its whole status to each watcher.
    local watchers, WATCH = {}, 60
    local function onCall(_, to, from, p, _, kind, id, method, payload)
        if kind ~= link.CALL or p ~= port or stopped or type(id) ~= "string" or #id > 32 then return end
        if component.type(to) ~= "modem" then return end
        local now, key = computer.uptime(), from .. id
        local done = answered[key]
        if not done then
            local args, result = link.unpack(payload), nil
            if method == "hello" then
                result = table.pack(true, {name = settings.name, key = identity.public})
            elseif not args then
                result = table.pack(false, "bad call")
            elseif not LINKED[method] then
                result = table.pack(false, "not a call over link: " .. tostring(method))
            else
                caller = {address = from, modem = {address = to}}
                -- api.expose (above) left each lib entry its bare function.
                result = table.pack(pcall(lib[method], table.unpack(args, 1, args.n)))
                caller = nil
            end
            done = {at = now, ok = result[1], text = link.pack(table.unpack(result, 2, result.n))}
            for k, d in pairs(answered) do if now - d.at > link.KEEP then answered[k] = nil end end
            if method ~= "hello" then answered[key] = done end
            local s = devices[from]
            if s and s.role then watchers[from] = {untilAt = now + WATCH, port = p, via = to} end
        end
        if not pcall(link.send, to, from, p, link.REPLY, id, done.ok, done.text) then
            pcall(link.send, to, from, p, link.REPLY, id, false, link.pack("the answer is too big for a modem message"))
        end
    end
    event.listen("modem_message", onCall)
    -- What a watcher sees change: not energy, TPS or the seconds open, which move all the time.
    local function shape(s)
        return table.concat({tostring(s.state), tostring(s.outgoing), tostring(s.iris), tostring(s.irisProblem),
            tostring(s.dialing), tostring(s.lastDial), #(s.glyphs or {}), tostring(s.name), tostring(s.alarm),
            tostring(s.seq), tostring(s.handDialed and s.handDialed.time)}, "|")
    end
    -- status() costs a tick per stargate call, about half a second in all: built every half
    -- second it would leave the computer no time for its signals. So it is built only when
    -- something it shows may have changed: a signal other than a modem message (JSG's gate,
    -- chevron and iris events), the gate's state (one call: JSG ends a failed dial without a
    -- signal), or the dialer's or this gate's own state.
    local signals = 0
    local counter = event.register(nil, function(name)
        if name and name ~= "modem_message" then signals = signals + 1 end
    end, math.huge, math.huge)
    local shown, pushes, checked = nil, 0, nil
    local watchTimer = timer(0.5, function()
        if not next(watchers) then shown, checked = nil, nil return end
        local hand = state.handDialed
        local gateState, outgoing = stargate.getGateStatus()
        local key = table.concat({signals, tostring(gateState), tostring(outgoing), tostring(dialer.state), tostring(dialer.irisProblem), tostring(settings.name),
            tostring(alarm), tostring(state.entry and state.entry.seq), tostring(hand and hand.time)}, "|")
        if key == checked then return end
        checked = key
        local s = status()
        local now, current = computer.uptime(), shape(s)
        if current == shown then return end
        shown, pushes = current, pushes + 1
        local text = link.pack(s)
        for address, w in pairs(watchers) do
            if now > w.untilAt then watchers[address] = nil
            else pcall(link.send, w.via, address, w.port, link.STATUS, pushes, text) end
        end
    end, math.huge)
    record("gate started")

    function node.stop()
        stopped = true
        event.ignore("modem_message", onCall)
        event.cancel(watchTimer)
        event.cancel(counter)
        link.stop()
        node.endpoint:shutdown()
        -- Every connection that opened, even one the endpoint no longer lists.
        for conn in pairs(sessions) do pcall(conn.close, conn) end
        event.cancel(scheduleTimer)
        event.cancel(sleepTimer)
        event.cancel(historyTimer)
        event.cancel(updateTimer)
        flushHistory()
        dialer.stop()
        setAlarm(false)
    end

    -- Signs the gate's entry again after its name or dimension changed.
    function node.publish() return publish(state, stargate, settings) end

    -- A new wake key: holders who have not opened the gate since can no longer wake it.
    function node.newWake()
        state.wake = handshake.wakeKey()
        applyWake()
        save()
        return state.wake
    end

    return node
end

return gate
