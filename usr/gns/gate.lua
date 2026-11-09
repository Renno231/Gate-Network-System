-- GNS gate: a controller for its clients, served over QuickOS api. The gate keeps its settings,
-- its own key pair and signed entry, its owner's key, the grants it has cut off and the OC users
-- of its computer; never other gates' entries (the address book lives on clients). See
-- docs/design/networks.md. Every function except open needs a connection that has passed open
-- (handshake.lua), and a role:
--   user   dial, close their own dial, the iris, status, energy, GDO, signed pass, routes and
--          dial-back
--   admin  also the console, the gate log, cutting off users, scheduled dials and remote updates
--          (a gate with an internet card also updates itself from GitHub every 2 hours)
--   owner  also cutting off admins
-- An unregistered gate, or a public one, gives everyone the user role; a registered private
-- gate gives roles only to its owner and to holders of the owner's grants. Anyone may hand a
-- gate a signed route (a relaying gate has no role of its own): the route's signer needs one.
local api = require("api")
local component = require("component")
local computer = require("computer")
local disco = require("disco")
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
-- users ({[name] = serial}), scheduled routes and the last address dialed by hand on the DHD. Gate computers start unattended, so the file
-- is not password-protected; the computer itself has to be kept out of reach.
function gate.load(path)
    local file = io.open(path, "rb")
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
    local file = assert(io.open(path, "wb"))
    file:write(serialization.serialize(state))
    file:close()
    state.path = path
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
    local sessions = setmetatable({}, {__mode = "k"}) -- connection → {key, role, name, grant, cutSeq}
    local identity = state.identity
    local port = settings.port or handshake.PORT
    local modem = component.modem
    publish(state, stargate, settings)
    local dialer = dialing.new(stargate, dhd, settings)
    local node
    local lastUse, pending, alarm = computer.uptime(), 0, false

    local history, historyDirty = {}, false
    local historyPath = state.path .. ".log"
    do
        local file = io.open(historyPath, "rb")
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
        local file = io.open(historyPath, "wb")
        if file then
            file:write(serialization.serialize(history))
            file:close()
        end
    end
    local historyTimer = event.timer(LOG_FLUSH, flushHistory, math.huge)
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

    local function status()
        local s = dialer.status()
        s.name, s.registered, s.public, s.alarm = settings.name, state.owner ~= nil, settings.public == true, alarm
        s.handDialed = state.handDialed
        return s
    end

    -- The role key has here, its player name when the role comes from ownership or a grant (nil
    -- for the public's user role), and the grant; or nil and the reason.
    local function roleFor(key, list)
        if state.owner and key == state.owner then return "owner", state.ownerName end
        local reason = "private gate"
        if state.owner and type(list) == "table" then
            for i = 1, math.min(#list, grants.MAX) do
                local role, why = grants.check(list[i], state.owner, identity.public, key, state.cut)
                if role then return role, list[i].name, list[i] end
                reason = why
            end
        end
        if not state.owner or settings.public then return "user" end
        return nil, reason
    end

    -- An admin is made an OC user of the gate computer, so they can use it directly.
    local function addAdmin(name, serial)
        if state.admins[name] == serial or name == state.ownerName then return end
        pcall(computer.addUser, name)
        state.admins[name] = serial
        save()
    end

    -- Wraps fn so it runs only for an opened connection whose role is at least minRole (nil:
    -- any opened connection). A grant cut off after the connection opened ends its role; the
    -- connection stays, as a guest refused for that reason.
    local function opened(minRole, fn)
        return function(...)
            local conn = api.caller()
            local session = sessions[conn]
            if not session then error("call open first", 0) end
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
            lastUse = computer.uptime()
            return fn(session, ...)
        end
    end

    ------------------------------------------------------------------------ routes
    local recent = {} -- route ids taken here (a relaying gate may deliver one twice)
    local pins = {}

    local function gateFree()
        local s = stargate.getGateStatus()
        return s == "idle" and not dialer.status().dialing
    end

    -- Waits (on timers) until test() holds or seconds pass; then calls done(held).
    local function waitFor(test, seconds, done)
        local deadline = computer.uptime() + seconds
        local id
        id = event.timer(0.5, function()
            local ok, held = pcall(test)
            held = ok and held
            if held or computer.uptime() >= deadline then
                event.cancel(id)
                done(held)
            end
        end, math.huge)
    end

    -- Hands route r, from hop at, to the gate at the far end of this gate's open wormhole: every
    -- GNS gate disco finds is offered it, and only the one the previous hop named takes it.
    local function relay(r, at)
        disco.findAsync("gns", 2, function(found)
            local own, passed = modem.address, false
            for _, host in ipairs(found) do
                if host.address ~= own then
                    api.connectAsync(handshake.ENDPOINT, (host.services or {}).gns or port, host.address, function(proxy)
                        if not proxy then return end
                        handshake.openAsync(proxy, identity, pins, nil, function(reply)
                            if not reply then proxy:close() return end
                            proxy:async(function(ok, result)
                                proxy:close()
                                if ok == true and not passed then
                                    passed = true
                                    note("route passed on to " .. tostring(reply.status and reply.status.name or host.name))
                                end
                            end).queue(r, at)
                        end)
                    end, nil, 3)
                end
            end
        end)
    end

    -- Carries out hop at of route r: after its delay (and once the gate is free), dials it with
    -- its IDC; with hops left, passes the route on once the wormhole is open.
    local function run(r, at)
        local hop = r.hops[at]
        pending = pending + 1
        event.timer(math.max(hop.delay, 0.05), function()
            waitFor(gateFree, ROUTE_WAIT, function(free)
                pending = pending - 1
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
    local scheduleTimer = event.timer(1, function()
        local now = computer.uptime()
        for _, s in ipairs(state.schedules) do
            nextRun[s] = nextRun[s] or now + s.every
            if now >= nextRun[s] then
                nextRun[s] = now + s.every
                run(s.route, 1)
            end
        end
    end, math.huge)

    ------------------------------------------------------------------------ sleeping
    -- A gate with a wake key shuts down after settings.sleep idle minutes; a wake message or the
    -- DHD's redstone starts it again. Scheduled dials keep it up.
    local sleepTimer = event.timer(10, function()
        local minutes = tonumber(settings.sleep) or 0
        if minutes <= 0 or not state.wake or #state.schedules > 0 or settings.room then return end
        if pending > 0 or stargate.getGateStatus() ~= "idle" or alarm then lastUse = computer.uptime() return end
        if computer.uptime() - lastUse >= minutes * 60 then
            note("sleeping")
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
    local function selfUpdate()
        if updating or not component.isAvailable("internet") then return end
        updating = true
        require("thread").create(function()
            local shell, temp, before = require("shell"), "/tmp/gns-install.lua", installed()
            if fs.exists(temp) then fs.remove(temp) end
            shell.execute("wget -fq " .. INSTALLER .. " " .. temp)
            if fs.exists(temp) then
                shell.execute(temp .. (fs.exists("/usr/gns/client/client.lua") and "" or " gate"))
                fs.remove(temp)
            end
            updating = false
            if installed() == before then return end
            local restart = autorun()
            note("updated GNS from GitHub" .. (restart and "" or "; restart gns to run it"))
            record("updated GNS from GitHub")
            if restart then
                flushHistory()
                computer.shutdown(true)
            end
        end):detach()
    end
    local updateTimer = event.timer(SELF_UPDATE, selfUpdate, math.huge)
    event.timer(5, selfUpdate)

    ------------------------------------------------------------------------ the endpoint
    local lib = {
        open = {function(request)
            local conn = api.caller()
            local reply, reason = handshake.accept(identity, conn, request)
            if not reply then error(reason, 0) end
            local role, name, g = roleFor(request.key, request.grants)
            sessions[conn] = {key = request.key, role = role, name = name, grant = g, cutSeq = state.cutSeq,
                refused = not role and name or nil}
            reply.role, reply.owner, reply.registered = role, state.owner, state.owner ~= nil
            if role then
                reply.status, reply.entry = status(), state.entry
                if name then reply.wake = state.wake end
                if role == "admin" then addAdmin(name, g.serial) end
            else
                reply.refused = name
            end
            lastUse = computer.uptime()
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

        status = {opened("user", function() return status() end), "The gate's name, type, state, iris, energy, TPS and last dial"},

        dial = {opened("user", function(session, address, opts)
            opts = type(opts) == "table" and opts or {}
            -- Dialing over an open outgoing wormhole closes it: the same rule as closeWormhole.
            local gateState, outgoing = stargate.getGateStatus()
            if gateState == "open" and outgoing and RANK[session.role] < RANK.admin and dialer.by ~= session.key then
                error("the gate is open to another player's dial: only who dialed, or an admin, can close it", 0)
            end
            local ok, result = pcall(dialer.dial, address, {fast = opts.fast == true, idc = math.tointeger(opts.idc), speed = tonumber(opts.speed)})
            if not ok then
                -- The client stops its own dial and dials again; another player's it waits out.
                if result == "already dialing" and dialer.by == session.key then error("your dial is in progress", 0) end
                record(("%s was refused a dial to %s: %s"):format(who(session), addressText(address), tostring(result)))
                error(result, 0)
            end
            dialer.by = session.key
            record(("%s dialed %s"):format(who(session), addressText(address)))
            return result
        end), "Dials an address {MW = {...}, PG = {...}, UN = {...}}; opts {fast, idc, speed}. Returns the glyph count, cost and duration"},

        energy = {opened("user", function(_, address)
            return dialer.cost(address)
        end), "What dialing an address would cost and how long the wormhole could stay open"},

        closeWormhole = {opened("user", function(session)
            if RANK[session.role] < RANK.admin and dialer.by ~= session.key then
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
        end), "A fresh challenge for a signed pass"},

        pass = {opened("user", function(session, sig)
            if not session.name then error("passes are for the owner and grant holders", 0) end
            local challenge = session.challenge
            session.challenge = nil
            if not handshake.checkPass(session.key, challenge, identity.public, sig) then
                record(session.name .. " sent a bad pass")
                error("bad pass", 0)
            end
            record(session.name .. " sent a signed pass")
            return dialer.admit(session.name)
        end), "A signed pass for the incoming wormhole: opens the iris for the owner or a grant holder"},

        -- Anyone who may dial here may work the iris, as with GDS's tablets.
        iris = {opened("user", function(session, want)
            local typed, kind = pcall(stargate.getIrisType)
            if typed and kind == "NULL" then error("this gate has no iris", 0) end
            local now = stargate.getIrisState()
            local target = ({open = "OPENED", close = "CLOSED"})[want]
            if want ~= nil and not target then error("open or close", 0) end
            target = target or (now == "CLOSED" and "OPENED" or "CLOSED")
            if now == target then return now end
            if now ~= "OPENED" and now ~= "CLOSED" then error("the iris is moving: " .. tostring(now), 0) end
            stargate.toggleIris()
            record(("%s %s the iris"):format(who(session), target == "OPENED" and "opened" or "closed"))
            return stargate.getIrisState()
        end), "Opens or closes the iris: want \"open\" or \"close\", alone the other way (users)"},

        queue = {opened(nil, function(_, r, at)
            at = math.tointeger(at) or 1
            local ok, why = route.verify(r)
            if not ok then error(why, 0) end
            if at < 1 or at > #r.hops then error("bad route", 0) end
            if at > 1 and not route.names(r.hops[at - 1].address, addressOf(stargate)) then error("not the next gate", 0) end
            local role = roleFor(r.key, r.grants)
            if not role then error("the route's signer has no access here", 0) end
            if recent[r.id .. at] then return "already queued" end
            if r.every > 0 then
                if RANK[role] < RANK.admin then error("scheduled dials need the admin role", 0) end
                if #state.schedules >= 16 then error("too many scheduled dials", 0) end
                state.schedules[#state.schedules + 1] = {route = r, every = r.every}
                recent[r.id .. at] = true
                save()
                record(("a dial every %d s was scheduled"):format(r.every))
                return "scheduled"
            end
            recent[r.id .. at] = true
            record(("a route was queued (hop %d of %d)"):format(at, #r.hops))
            run(r, at)
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

        update = {opened("admin", function(session, files)
            if type(files) ~= "table" or #files == 0 or #files > 64 then error("bad file list", 0) end
            for _, f in ipairs(files) do
                if type(f) ~= "table" or not updatable(f[1]) or type(f[2]) ~= "string" then
                    error("not a GNS file: " .. tostring(type(f) == "table" and f[1]), 0)
                end
            end
            for _, f in ipairs(files) do
                local path = "/usr/" .. f[1]
                fs.makeDirectory(fs.path(path))
                local file = assert(io.open(path, "wb"))
                file:write(f[2])
                file:close()
            end
            note(("updated %d files (%s)"):format(#files, tostring(session.name)))
            local restart = autorun()
            if restart then event.timer(2, function() flushHistory() computer.shutdown(true) end) end
            return #files, restart
        end), "Writes new GNS files {{path under /usr, contents}, ...} (admin); restarts the gate when gns autoruns"},

        gatelog = {opened("admin", function(_, count) return newest(count) end),
            "The gate log, newest first: {time, text} entries, count at most 500 (admin)"},
    }
    node = {state = state, dialer = dialer, applyWake = applyWake, save = save, status = status, record = record,
        history = newest, endpoint = api.expose(handshake.ENDPOINT, lib, port)}
    record("gate started")

    function node.stop()
        node.endpoint:shutdown()
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
