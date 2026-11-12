-- Dial screen: finds the gates in range on this device's ports (link.lua's hello), wakes the
-- sleeping ones it holds wake keys for, opens each as it answers (gate.open with the grants held),
-- keeps each gate's own signed entry in the address book and dials. Every gate command is one
-- message, sent again until the gate answers; nothing stays connected. The stargate is drawn from
-- the dialing gate's own status, which the gate sends as it changes. Widget callbacks cannot
-- wait, so every network step continues in a callback.
--
-- Commands: d / dial, close / x, iris / i, scan, from / f, ssh, setup, gdo, back, route, home,
-- energy, schedule, update, gatelog, save, glyphs.
local gns, clientEnv, _, frame, R = ...
local ui = clientEnv.ui
local C = ui.C
local loom = require("loom")
local computer = require("computer")
local unicode = require("unicode")
local event = require("event")
local component = require("component")
local fs = require("filesystem")
local handshake = dofile(gns.path.gns .. "handshake.lua")
local entries = clientEnv.entries
local dialing = dofile(gns.path.gns .. "dialing.lua")
local route = dofile(gns.path.gns .. "route.lua")
local fingerprint = clientEnv.vaultModule.fingerprint

local database = clientEnv.database
local vaultState = clientEnv.vault.state
local identity = vaultState.identity
local connections = clientEnv.gateconnections
local link = clientEnv.link
local log = clientEnv.log
local settings = clientEnv.settings
local wide = R.wide
local GALAXY = {MW = "Milky Way", PG = "Pegasus", UN = "Universe"}

-- State kept across layout changes (the screen is built again, clientEnv stays).
local dial = clientEnv.dialState or {busy = false, sinceScan = 0}
clientEnv.dialState = dial

local function guard(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then log("Error: " .. tostring(err)) end
    end
end

---------------------------------------------------------------------------- gates in range
-- Adds or updates the address book row for a signed gate entry (rows are matched by gate key).
local function record(e)
    local address = {MW = e.address.MW or {}, PG = e.address.PG or {}, UN = e.address.UN or {}}
    for _, row in ipairs(database) do
        if row.key == e.key then
            row.Name, row.Type, row.Address, row.retired = e.name, e.type, address, e.retired
            if e.dim and type(row.Location) ~= "table" then row.Location = {dimension = e.dim} end
            return row
        end
    end
    local row = {key = e.key, Name = e.name, Type = e.type, Address = address, IDCs = {},
        Location = e.dim and {dimension = e.dim} or nil}
    database[#database + 1] = row
    return row
end

local function findConnection(address)
    for i, connection in ipairs(connections) do
        if connection.address == address then return connection, i end
    end
end
-- How far a gate is: "this computer" for the gate whose modem is one of this computer's own
-- cards (it answered by local delivery, link.lua), else its distance with unit, else nil.
local function away(c, unit)
    if component.list("modem")[c.address] then return "this computer" end
    return c.distance and (math.floor(c.distance) .. unit) or nil
end
local function byDistance(a, b) return (a.distance or math.huge) < (b.distance or math.huge) end
local function isAdmin(c) return c and (c.role == "admin" or c.role == "owner") end

-- The grants to show a gate: those of its owner when it is known, else all of them; those for
-- this gate (gate: its key, when known) or every gate first, since a gate reads at most 16, and
-- admin grants before user ones, since the gate takes the first good grant.
local function grantsFor(owner, gate)
    local list = {}
    local function add(first, admin)
        for _, g in ipairs(vaultState.grants) do
            if #list >= 16 then return end
            local covers = gate ~= nil and (g.gate == gate or g.gate == "")
            if (not owner or g.owner == owner) and covers == first and (g.role == "admin") == admin then list[#list + 1] = g end
        end
    end
    add(true, true)
    add(true, false)
    add(false, true)
    add(false, false)
    return list
end
local function accessByModem(address)
    for key, a in pairs(vaultState.access) do
        if a.modem == address then return a, key end
    end
end

-- Keeps what opening a gate told this device: its entry, and for a gate where it holds a named
-- role (owner or grant) how to reach and wake it. Returns true for a gate new to the book.
local function remember(c, wake)
    local e, new = c.entry, false
    if type(e) == "table" and e.key == c.key then
        new = vaultState.book[c.key] == nil
        pcall(entries.merge, vaultState.book, e)
        local own = vaultState.book[c.key]
        if own then
            c.name = own.name
            local row = settings.autoLogToDatabase and record(own)
            if row then clientEnv.joinByPort(row, c.port) end
        end
    end
    if c.tag == "public" or c.tag == "unregistered" then return new end
    local a = vaultState.access[c.key] or {}
    a.name, a.modem, a.port, a.owner, a.role = c.name, c.address, c.port, c.owner, c.role
    a.wake = wake or a.wake
    vaultState.access[c.key] = a
    clientEnv.changed()
    return new
end

-- Grants this device cut off reach every gate they cover that it administers: on each open.
local function pushCuts(c)
    if not isAdmin(c) then return end
    local list = {}
    for _, issued in ipairs(vaultState.issued) do
        local g = issued.grant
        if issued.cut and g.owner == c.owner and (g.gate == "" or g.gate == c.key) and (c.role == "owner" or g.role == "user") then
            list[#list + 1] = g
        end
    end
    if #list == 0 then return end
    c.proxy:async(guard(function(ok, count)
        if ok ~= true then log(c.name .. ": cut-offs refused: " .. tostring(count)) return end
        if count > 0 then log(("%s: %d grant%s cut off."):format(c.name, count, count == 1 and "" or "s")) end
    end)).cut(list)
end
clientEnv.pushCuts = function() for _, c in ipairs(connections) do pushCuts(c) end end

-- Opens the gate at address on port with the grants held: one message (link.lua), and a gate
-- this device opened before costs no signature on either side. Calls callback(connection), or
-- callback(nil, reason) when the gate refused this device (a private gate) or did not answer. c:
-- the connection to bring up to date in place (new grants, a gate that restarted or was renamed).
local function openGate(address, port, callback, c)
    c = c or {address = address, port = port}
    -- A gate that restarted answers "call open first": the proxy opens it again, then calls again.
    c.proxy = c.proxy or link.proxy(address, port, function(done)
        openGate(address, port, guard(function(x) done(x ~= nil) end), c)
    end, clientEnv.bucket)
    local known, gateKey = accessByModem(address)
    handshake.openAsync(c.proxy, identity, vaultState.pins, {grants = grantsFor(known and known.owner, gateKey)}, guard(function(reply, reason, newKey)
        if not reply then return callback(nil, reason, newKey) end
        if not reply.role then return callback(nil, tostring(reply.refused or "private gate")) end
        c.key, c.role, c.owner, c.registered, c.entry = reply.key, reply.role, reply.owner, reply.registered, reply.entry
        c.status, c.heard = reply.status, computer.uptime()
        c.name = reply.status and reply.status.name or c.name or address:sub(1, 8)
        -- What the top bar shows: the role from ownership or a grant, else how the gate is open.
        c.tag = not reply.registered and "unregistered" or (reply.wake and reply.role) or "public"
        c.new = remember(c, reply.wake)
        pushCuts(c)
        callback(c)
    end), vaultState.proofs)
end

-- Wakes the gates this device holds wake keys for that are not open here (only: just the modems
-- in that set): a message to each gate's own modem (never a broadcast). Returns how many.
local function wakeKnown(only)
    local modem, sent = component.modem, 0
    for _, a in pairs(vaultState.access) do
        if a.wake and a.modem and (not only or only[a.modem]) and clientEnv.ports()[a.port or 160] and not findConnection(a.modem) then
            if pcall(modem.send, a.modem, a.port or 160, a.wake) then sent = sent + 1 end
        end
    end
    return sent
end

-- Asks the gates in range who they are and opens each as it answers. Another SCAN meanwhile
-- just asks again. quiet (the automatic rescan) reports only when it opened a gate. A scan asked
-- for wakes the known gates first, drops the gates that no longer answer (asleep or gone; it
-- wakes those it may) and looks again once the woken ones have had time to start.
local wakeTimer
local poll -- below: a scan polls the gates already open
-- A dial waiting for its gate (waitToDial, below): dropped with its gate's connection too.
local queued
local function dropQueued(connection)
    if queued and (not connection or queued.gate == connection) then event.cancel(queued.timer) queued = nil end
end
local opening = {} -- modem → true while its open is under way

local function forget(c)
    local _, index = findConnection(c.address)
    if index then table.remove(connections, index) end
    if clientEnv.from == c then clientEnv.from = nil end
    dropQueued(c)
end

local function scan(quiet)
    dial.sinceScan = 0
    local woken = 0
    if not quiet then
        woken = wakeKnown()
        log(woken > 0 and ("Waking %d gate%s; scanning..."):format(woken, woken == 1 and "" or "s") or "Scanning for gates...")
    end
    local seen, found, waiting, opened, refused, new = {}, 0, 1, 0, 0, 0
    local function done()
        waiting = waiting - 1
        if waiting > 0 then return end
        if woken > 0 then
            if wakeTimer then event.cancel(wakeTimer) end
            wakeTimer = event.timer(15, guard(function() wakeTimer = nil scan(true) end))
        end
        if quiet and opened == 0 then return end
        log(("Found %d gates, opened %d, %d new%s."):format(found, opened, new, refused > 0 and (", " .. refused .. " private") or ""))
        local saved, err = clientEnv.vault:save()
        if not saved then log("Vault not saved: " .. tostring(err)) end
    end
    link.hello(clientEnv.ports(), 2, guard(function(address, port, distance)
        if seen[address] then return end
        seen[address], found = true, found + 1
        local known = findConnection(address)
        if known then
            known.distance = distance
            poll(known) -- a renamed gate shows its new name
            return
        end
        if opening[address] then return end
        opening[address], waiting = true, waiting + 1
        openGate(address, port, guard(function(connection, reason)
            opening[address] = nil
            if not connection then
                refused = refused + 1
                local a = accessByModem(address)
                local name = a and a.name or address:sub(1, 8)
                if reason == "gate key changed" then
                    clientEnv.keyChanged(name, vaultState.pins, address)
                    log(("%s: gate key changed. If it was reinstalled, trust %s accepts its new key."):format(name, name))
                elseif not quiet then
                    log(("%s: %s"):format(name, reason))
                end
                return done()
            end
            connection.distance = distance
            if not findConnection(address) then
                opened = opened + 1
                if connection.new then new = new + 1 end
                connections[#connections + 1] = connection
                log(("Connected to %s (%s)."):format(connection.name, connection.tag))
            end
            table.sort(connections, byDistance)
            loom.invalidate()
            done()
        end))
    end), guard(function()
        if not quiet then
            -- A gate open here that no longer answers went to sleep or away: drop it, and wake it
            -- if this device holds its wake key.
            local gone = {}
            for i = #connections, 1, -1 do
                local c = connections[i]
                if not seen[c.address] then
                    forget(c)
                    gone[c.address] = true
                end
            end
            local more = next(gone) and wakeKnown(gone) or 0
            if more > 0 then
                woken = woken + more
                log(("Waking %d more gate%s."):format(more, more == 1 and "" or "s"))
            end
        end
        done()
    end))
end
clientEnv.scan = scan
clientEnv.onClose[#clientEnv.onClose + 1] = function() if wakeTimer then event.cancel(wakeTimer) end end

-- Opens every gate again, so each holds the grants held now (after joining, say).
function clientEnv.reconnect()
    for _, c in ipairs(connections) do
        openGate(c.address, c.port, guard(function(x, reason)
            if not x then forget(c) log(c.name .. ": " .. tostring(reason)) end
            loom.invalidate()
        end), c)
    end
    scan(false)
end

local function closeConnection(connection)
    forget(connection)
    log("Closed " .. connection.name .. ".")
end
local function silent(result) return tostring(result):match("^Timeout") ~= nil end

---------------------------------------------------------------------------- what to dial
local function row() -- the destination row
    if clientEnv.dest and clientEnv.dest.typed then return clientEnv.dest end -- glyphs tapped in, not in the book
    for _, r in ipairs(database) do if r == clientEnv.dest then return r end end
    clientEnv.dest = database[1]
    return clientEnv.dest
end
local function galaxyOf(connection)
    local s = connection and connection.status
    return s and dialing.TYPE[s.type] or "MW"
end
-- The glyphs a dial from connection's galaxy engages: six and the point of origin (all eight
-- from another galaxy, as the gate works out).
local function plannedGlyphs(connection, r)
    local galaxy = galaxyOf(connection)
    local address = r and r.Address and r.Address[galaxy] or {}
    local list = {}
    for i = 1, math.min(6, #address) do list[i] = address[i] end
    if #list > 0 then list[#list + 1] = dialing.ORIGIN[galaxy] end
    return list
end

-- A gate in range by selector: an address book entry (number or name) that is one of them,
-- or the start of a gate's name.
local function findGate(selector)
    if not selector then return nil end
    local entry = clientEnv.findEntry(selector)
    if entry then
        for _, c in ipairs(connections) do
            if (entry.key and c.key == entry.key) or c.name == entry.Name then return c end
        end
    end
    local want = tostring(selector):gsub("_", " "):lower()
    for _, c in ipairs(connections) do
        if c.name:lower():sub(1, #want) == want then return c end
    end
end
-- The nearest gate in range other than the destination r.
local function nearest(r)
    local best
    for _, c in ipairs(connections) do
        local isDestination = r and ((r.key and c.key == r.key) or c.name == r.Name)
        if not isDestination and (not best or byDistance(c, best)) then best = c end
    end
    return best
end

---------------------------------------------------------------------------- status
-- A gate's status: the gate sends it to this device as it changes (it watches the gates it
-- sent a call in the last minute), and poll asks for it when none came for maxAge seconds (a
-- message lost, or the watch to renew). While a dial this client started is followed, each change
-- of its dial state goes to the activity log.
local function took(connection, s)
    connection.heard = computer.uptime()
    -- The gate signed a newer entry (renamed, moved): open it again to take it.
    if s.seq and connection.entry and s.seq > (tonumber(connection.entry.seq) or 0) and not connection.renewing then
        connection.renewing = true
        openGate(connection.address, connection.port, guard(function() connection.renewing = nil loom.invalidate() end), connection)
    end
    local hand, before = s.handDialed, connection.status and connection.status.handDialed
    if type(hand) == "table" and connection.status and (not before or before.time ~= hand.time) then
        clientEnv.noticeHandDial(connection, hand)
    end
    connection.status = s
    local f = connection.follow
    if f then
        f.at = f.at or computer.uptime()
        local old = computer.uptime() - f.at > 120
        if f.start and not s.dialing then
            -- A route dials once the gate is free: until it starts, the last dial's state is old news.
            if old then connection.follow = nil end
        else
            f.start = nil
            if s.lastDial ~= f.last then
                f.last = s.lastDial
                log(connection.name .. ": " .. tostring(f.last))
            end
            if (not s.dialing and not (f.idc and f.last == "open")) or old then connection.follow = nil end
        end
    end
    loom.invalidate()
end
link.onStatus = function(address, s)
    local c = findConnection(address)
    if c then pcall(took, c, s) end
end

function poll(connection, maxAge)
    local now = computer.uptime()
    if maxAge and connection.heard and now - connection.heard < maxAge then return end
    if connection.polling and now - connection.polling < link.WAIT + 1 then return end
    connection.polling = now
    connection.proxy:async(guard(function(ok, s)
        connection.polling = false
        if ok == true and type(s) == "table" then return took(connection, s) end
        -- Sent again for link.WAIT seconds without an answer: the gate is asleep or gone.
        if silent(s) and findConnection(connection.address) then
            forget(connection)
            log(connection.name .. " does not answer; SCAN finds it again.")
            loom.invalidate()
        end
    end)).status()
end
-- What the chosen dial would cost (the gate's energy check), for the destination card; asked
-- again when the gate or destination changes and every ten seconds.
local cost = {}
local function checkCost(c, r)
    if not c or not r or (cost.asking and computer.uptime() - cost.asking < 10) then return end
    cost.asking = computer.uptime()
    c.proxy:async(guard(function(ok, result)
        cost.asking = false
        cost.from, cost.dest, cost.at = c, r, computer.uptime()
        cost.result, cost.error = ok == true and result or nil, ok ~= true and tostring(result) or nil
        loom.invalidate()
    end)).energy(r.Address)
end
local function costText(c, r)
    if cost.from ~= c or cost.dest ~= r then return "" end
    if cost.error then return "Cannot dial: " .. cost.error end
    local x = cost.result
    if not x then return "" end
    local k = function(n) n = tonumber(n) or 0 return n >= 1e4 and ("%dk"):format(n // 1000) or tostring(math.floor(n)) end
    if not x.canOpen then return ("Not enough power: %s RF to open, %s stored"):format(k(x.open), k(x.energy)) end
    return ("%s RF to open · %s RF/t open · %d s on stored power"):format(k(x.open), k(x.keepAlive), x.seconds)
end

local ticks = 0
local statusTimer = event.timer(0.5, guard(function()
    ticks = ticks + 1
    local c = clientEnv.fromGate()
    -- The gate sends its changes; a poll covers one lost (3 s while a dial goes on, 5 s while a
    -- wormhole is open, for its time left) and renews the watch (20 s).
    local s = c and c.status or {}
    if c then poll(c, (c.follow or s.dialing) and 3 or s.state == "open" and 5 or 20) end
    local r = row()
    if c and r and (cost.from ~= c or cost.dest ~= r or computer.uptime() - (cost.at or 0) > 10) then checkCost(c, r) end
    if ticks % 2 == 0 then
        local rate = tonumber(clientEnv.settings.nearbyScanRate) or 0
        dial.sinceScan = dial.sinceScan + 1
        if rate > 0 and dial.sinceScan >= rate then scan(true) end
    end
end), math.huge)
clientEnv.onClose[#clientEnv.onClose + 1] = function() event.cancel(statusTimer) end

---------------------------------------------------------------------------- actions
local function doDial(connection, r, idc, onBusy, waited, after)
    if not connection then return "No gate in range to dial from. SCAN looks for gates." end
    if not r then return "Choose a gate to dial." end
    idc = idc or clientEnv.idcFor(r)
    clientEnv.from, clientEnv.dest = connection, r
    local opts = {fast = clientEnv.settings.fastDial ~= false, idc = idc, speed = clientEnv.settings.dialSpeed, wait = waited,
        closeAfter = after}
    connection.proxy:async(guard(function(ok, result)
        if ok ~= true then
            if onBusy and (result == "incoming wormhole" or result == "already dialing" or result == "your dial is in progress"
                or result == "your dial is in progress to it") then
                return onBusy(result)
            end
            if result == "already open to it" then log(connection.name .. " is already open to " .. r.Name .. ".") return end
            log(connection.name .. ": dial refused: " .. tostring(result))
            return
        end
        log(("Dialing %s from %s: %d glyphs%s, %d RF, open for %d s%s."):format(r.Name, connection.name,
            result.glyphs, result.from > 1 and (" from glyph " .. result.from) or "", result.open,
            result.seconds, result.fast and ", DHD" or ""))
        connection.follow = {last = "dialing", idc = idc}
        poll(connection)
    end)).dial(r.Address, opts)
    return ("Dialing %s from %s%s%s..."):format(r.Name, connection.name,
        idc and (settings.showCodes and (" with IDC " .. idc) or " with IDC") or "",
        after and (", closing %d s after it opens"):format(after) or "")
end
-- DIAL while the gate is busy, as GDS did. Over the gate's open outgoing wormhole the gate
-- itself closes it and dials. When the gate refuses for an incoming wormhole or a dial in
-- progress (this device's own, to another gate, is stopped first), the dial waits and goes out
-- once the gate is idle, within five minutes; DISENGAGE at that gate or another DIAL drops it.
clientEnv.onClose[#clientEnv.onClose + 1] = dropQueued
local disengage
-- stopOwn: the wait began by stopping this device's own dial, which the gate cannot stop in the
-- 3 s its wormhole is forming (JSG's kawoosh): once open it is closed then.
local function waitToDial(c, r, idc, deadline, stopOwn, after)
    dropQueued()
    local q = {gate = c}
    queued = q
    q.timer = event.timer(1, guard(function()
        c = findConnection(c.address) or c -- reconnected meanwhile: the new connection
        q.gate = c
        poll(c, 3)
        local now = c.status or {}
        if queued ~= q then return false end
        if not now.dialing and now.state == "idle" then
            dropQueued()
            -- Another player may have dialed first: then wait again, to the same deadline. The
            -- dial logs itself once it goes out (not each retry, as while a player presses DHD glyphs).
            doDial(c, r, idc, function() waitToDial(c, r, idc, deadline, false, after) end, true, after)
        elseif stopOwn and now.state == "open" and now.outgoing then
            stopOwn = false -- once: a later wormhole is not this dial's
            c.proxy:async(guard(function(ok, result)
                log(c.name .. (ok == true and (": " .. tostring(result)) or (": disengage refused: " .. tostring(result))))
                poll(c)
            end)).closeWormhole()
        elseif computer.uptime() >= deadline then
            dropQueued()
            log(("%s stayed busy: %s was not dialed."):format(c.name, r.Name))
        end
    end), math.huge)
end
local function dialWhenFree(c, r, idc, after)
    dropQueued()
    if not c or not r then return doDial(c, r, idc, nil, nil, after) end
    local deadline = computer.uptime() + 300
    return doDial(c, r, idc, function(why)
        if why == "your dial is in progress to it" then log("Already dialing " .. r.Name .. ".") return end
        if why == "your dial is in progress" then disengage(c) end
        waitToDial(c, r, idc, deadline, why == "your dial is in progress", after)
        log((why == "incoming wormhole" and "%s has an incoming wormhole: dialing %s once it closes."
            or why == "your dial is in progress" and "%s: stopping your dial, then dialing %s."
            or "%s is busy: dialing %s once it is free."):format(c.name, r.Name))
    end, nil, after)
end
function disengage(connection)
    if queued and queued.gate == connection then dropQueued() end
    if not connection then return "No gate in range." end
    connection.proxy:async(guard(function(ok, result)
        log(connection.name .. (ok == true and (": " .. tostring(result)) or (": disengage refused: " .. tostring(result))))
        poll(connection)
    end)).closeWormhole()
end
-- want: "open", "close" or nil (the other way).
local function iris(connection, want)
    if not connection then return "No gate in range." end
    connection.proxy:async(guard(function(ok, result)
        log(connection.name .. (ok == true and (": iris " .. tostring(result)) or (": iris refused: " .. tostring(result))))
        poll(connection)
    end)).iris(want)
end

-- The gate console of a gate whose network this device administers: the commands the gate's
-- owner types at the gate computer, run remotely.
local function remote(connection, line, out)
    connection.proxy:async(guard(function(ok, lines)
        if ok ~= true then out("Refused: " .. tostring(lines)) return end
        for _, l in ipairs(lines) do out(l) end
        loom.invalidate()
    end)).console(line)
end
local function console(connection)
    if not connection then return "No gate in range." end
    if ui.modalOpen() then return end
    local W, H = ui.W, ui.H
    local w, h = math.min(W - 4, 110), math.min(H - 4, 34)
    local box, close = ui.modal(clientEnv.root, clientEnv.shell, w, h, "CONSOLE · " .. connection.name)
    local lines = {"Remote console of " .. connection.name .. ". Type help for its commands, exit to close."}
    local list = ui.List(box, 2, 3, w - 2, h - 5, {items = lines, scrollOnly = true,
        cells = function(item) return {{1, item, item:sub(1, 6) == "gate> " and C.amber or C.text}} end})
    local function out(text)
        lines[#lines + 1] = text
        if #lines > 300 then table.remove(lines, 1) end
        list._scroll = math.huge
    end
    local field = ui.Field(box, 3, h - 1, w - 16, {clear = true, placeholder = "gate> command", submit = function(text)
        if not text:match("%S") then return end
        if text == "exit" or text == "quit" then event.timer(0, close) return end -- after submit, which uses the field
        out("gate> " .. text)
        remote(connection, text, out)
    end})
    ui.Button(box, w - 11, h - 1, 10, 1, "CLOSE", C.raised, C.text, close)
    ui.Button(box, w - 19, h - 1, 7, 1, "LOG", C.blue, C.black, function()
        close()
        clientEnv.gateLog(connection)
    end)
    ui.focusSoon(field)
end
local function say(message) if message then log(message) end end

-- The gate log (admins): what happened at the gate, newest first, each entry wrapped.
function clientEnv.gateLog(connection)
    if not connection then return "No gate in range." end
    if not isAdmin(connection) then return "The gate log needs the admin role." end
    connection.proxy:async(guard(function(ok, entries)
        if ok ~= true then log(connection.name .. ": no gate log: " .. tostring(entries)) return end
        if ui.modalOpen() then return end
        local w, h = math.min(ui.W - 4, 110), math.min(ui.H - 2, 34)
        local box, close = ui.modal(clientEnv.root, clientEnv.shell, w, h, "GATE LOG · " .. connection.name)
        local rows = {}
        for _, e in ipairs(entries) do
            for j, line in ipairs(ui.wrap(tostring(e[2]), w - 14)) do rows[#rows + 1] = {j == 1 and tostring(e[1]) or "", line} end
        end
        local list = ui.List(box, 2, 3, w - 2, h - 5, {items = rows, scrollOnly = true, empty = "Nothing logged yet.",
            cells = function(r) return {{1, r[1], C.faint}, {11, r[2], C.text}} end})
        ui.Paint(box, 3, h - 1, w - 16, 1, function(self)
            self:text(1, 1, ui.pad(("%d entries, newest first · Tab, Enter: CLOSE"):format(#entries), w - 16), C.faint, C.card)
        end)
        ui.Button(box, w - 11, h - 1, 10, 1, "CLOSE", C.raised, C.text, close)
        ui.focusSoon(list)
    end)).gatelog()
    return ("Reading %s's gate log..."):format(connection.name)
end

-- Registers an unregistered gate to this device: its key becomes the owner, the player its OC
-- user, and a new wake key starts it from now on.
local function setup(c)
    if not c then return "No gate in range." end
    if c.registered then return c.name .. " already has an owner." end
    local player = clientEnv.player
    if not player then return "Press a key on this device first, so OC names the player." end
    local wake = handshake.wakeKey()
    c.proxy:async(guard(function(ok, result)
        if ok ~= true then log(c.name .. ": not set up: " .. tostring(result)) return end
        c.role, c.registered, c.owner, c.tag = "owner", true, identity.public, "owner"
        remember(c, wake)
        local saved, err = clientEnv.vault:save()
        if not saved then log("Vault not saved: " .. tostring(err)) end
        log(("%s is yours: %s is its OC user, and this device holds its wake key."):format(c.name, player))
    end)).register(player, wake)
    return ("Setting up %s for %s..."):format(c.name, player)
end

-- The book row of the gate c's wormhole reaches, from c's own status: its dial's target (whoever
-- dialed it), or the glyphs a hand dial engaged. A gate the book lacks: a row of just those
-- glyphs, with no IDC (not the book's). A status naming no glyphs: the chosen row.
-- The book row of the gate c's wormhole reaches. The book may hold a gate twice (imported, then
-- scanned): of its rows, prefer (else the chosen row) wins.
local function reachedRow(c, prefer)
    local s = c.status or {}
    local glyphs = type(s.target) == "table" and #s.target > 0 and s.target or s.glyphs
    if type(glyphs) ~= "table" or #glyphs < 6 then return row() end
    local galaxy, chosen, first = galaxyOf(c), prefer or row(), nil
    for _, r in ipairs(database) do
        local a = r.Address and r.Address[galaxy]
        local same = type(a) == "table" and #a >= 6
        for i = 1, 6 do same = same and a[i] == glyphs[i] end
        if same and r == chosen then return r end
        if same then first = first or r end
    end
    return first or {IDCs = {}, Address = {[galaxy] = glyphs}}
end

-- Calls done(open) once c's outgoing wormhole is open (to want's gate, when given), or once the
-- dial can no longer open: DIAL waits up to 300 s for a busy gate, and the gate gives a dial 120 s
-- plus its speed.
local waiting = {}
clientEnv.onClose[#clientEnv.onClose + 1] = function() for id in pairs(waiting) do event.cancel(id) end end
local function waitOpen(c, done, want)
    local deadline, id = computer.uptime() + 300 + 120 + (clientEnv.settings.dialSpeed or 0) + 10, nil
    id = event.timer(1, guard(function()
        poll(c, 3)
        local s = c.status or {}
        local open = s.state == "open" and s.outgoing and not s.dialing and (not want or reachedRow(c, want) == want)
        if open or computer.uptime() >= deadline then
            event.cancel(id)
            waiting[id] = nil
            done(open)
        end
    end), math.huge)
    waiting[id] = true
end

-- Whether gate connection x is the gate of row r: by its key, else (a row added by hand) by the
-- address x publishes, the first six glyphs of a galaxy both have. nil when neither tells.
local function isRow(x, r)
    if not r then return nil end
    if r.key then return x.key == r.key end
    local own = x.entry and x.entry.address
    if type(own) ~= "table" or type(r.Address) ~= "table" then return nil end
    for kind, glyphs in pairs(r.Address) do
        local mine = own[kind]
        if type(glyphs) == "table" and type(mine) == "table" and #glyphs >= 6 and #mine >= 6 then
            local same = true
            for i = 1, 6 do if glyphs[i] ~= mine[i] then same = false break end end
            if same then return true end
        end
    end
    return false
end

-- The gate at the far end of c's open outgoing wormhole (OC modem messages cross it): r's gate
-- (by key or published address), else the gate with an incoming wormhole. A gate a scan already
-- opened through the wormhole counts too. Calls done(connection) as soon as r's gate answers and
-- opens, or done(nil, why).
local function reachFar(c, r, done)
    for _, x in ipairs(connections) do
        if x ~= c and isRow(x, r) then return done(x) end
    end
    local waiting, best, why, finished, seen = 1, nil, "no GNS gate answers through the wormhole", false, {}
    local function finish(x)
        if finished then return end
        if x then finished = true return done(x) end
        waiting = waiting - 1
        if waiting > 0 then return end
        finished = true
        if best then done(best) else done(nil, why) end
    end
    link.hello(clientEnv.ports(), 2, guard(function(address, port)
        if finished or seen[address] or address == c.address or findConnection(address) then return end
        seen[address], waiting = true, waiting + 1
        openGate(address, port, guard(function(x, reason)
            if not x then why = address:sub(1, 8) .. ": " .. tostring(reason) return finish() end
            local s = x.status or {}
            local named = isRow(x, r)
            if named then return finish(x) end
            if named == nil and s.state == "open" and not s.outgoing then best = best or x end
            finish()
        end))
    end), guard(function() finish() end))
end

-- The IDC a gate row sends for the player pressing: theirs, else the row's first; or nil.
local idcOf = clientEnv.idcFor
local function rowOf(c)
    for _, r in ipairs(database) do if c.key and r.key == c.key then return r end end
end

-- GDO: through c's open outgoing wormhole, a signed pass to a GNS gate that knows this device,
-- else a numeric IDC (code, or the destination's first one).
local function gdo(c, code)
    if not c then return "No gate in range." end
    local s = c.status or {}
    if not (s.state == "open" and s.outgoing) then return c.name .. " has no open outgoing wormhole." end
    local r = reachedRow(c) -- the gate the wormhole reaches, not the row chosen since
    local function numeric(why)
        local idc = code or idcOf(r)
        if not idc then log("GDO: " .. (why or "no IDC for " .. (r and r.Name or "the far gate"))) return end
        c.proxy:async(guard(function(ok, result)
            log(ok == true and ("GDO: IDC sent to " .. tostring(r and r.Name or "the far gate") .. ".") or ("GDO refused: " .. tostring(result)))
            -- The far gate's answer comes back to c as its dial state: follow it to the log.
            if ok == true then c.follow = {last = "open", idc = idc} poll(c) end
        end)).sendIdc(idc)
    end
    if code then numeric() return "GDO: sending IDC..." end
    reachFar(c, r, function(far)
        if not far then return numeric() end
        -- The far gate's open proved this device's key from its modem: the pass is one message.
        far.proxy:async(guard(function(passed, result)
            if passed == true then log("GDO: " .. far.name .. " took your signed pass; its iris opens.") return end
            log(far.name .. ": pass refused: " .. tostring(result))
            numeric()
        end)).pass()
    end)
    return "GDO: sending your pass..."
end

-- Dial-back: once c's outgoing wormhole is open, the far gate is handed a signed route back to
-- c (with c's IDC) to dial after delay seconds, and c's side is closed so it is free.
local function dialBack(c, delay, want)
    if not c then return "No gate in range." end
    local own = c.entry and c.entry.address
    if not own then return c.name .. " has not published its address." end
    local back = rowOf(c)
    waitOpen(c, function(open)
        if not open then log("Dial-back: the wormhole from " .. c.name .. " did not open.") return end
        -- Far answers are often lost past about 10 blocks from the gate: try up to 3 times.
        local tries, reached = 1, nil
        function reached(far, why)
            if not far and tries < 3 then
                tries = tries + 1
                return reachFar(c, reachedRow(c, want), reached)
            end
            if not far then log("Dial-back: " .. tostring(why)) return end
            local r = route.sign(identity, {{address = own, idc = idcOf(back), delay = delay}}, 0, grantsFor(far.owner, far.key))
            -- The far gate holds the route until it is free, so this side closes at once, without
            -- waiting for its answer: that answer crosses the wormhole and can be lost.
            far.proxy:async(guard(function(ok, result)
                if ok ~= true and not tostring(result):find("^Timeout") then
                    log(far.name .. ": dial-back refused: " .. tostring(result))
                end
            end)).queue(r, 1)
            log(("Asked %s to dial %s back in %d s; closing this side."):format(far.name, c.name, delay))
            disengage(c)
        end
        reachFar(c, reachedRow(c, want), reached)
    end, want)
    return ("Dial-back to %s once the wormhole is open..."):format(c.name)
end

-- The grants for every gate of a route: c's and those of the gate each later hop starts from,
-- each gate's best first, taken in turn, since a gate reads at most 16.
local function routeGrants(c, rows)
    local lists = {grantsFor(c.owner, c.key)}
    for i = 1, #rows - 1 do
        local key = type(rows[i].key) == "string" and #rows[i].key == 22 and rows[i].key or nil
        local a = key and vaultState.access[key]
        lists[#lists + 1] = grantsFor(a and a.owner, key)
    end
    local out, seen = {}, {}
    for n = 1, 16 do
        for _, list in ipairs(lists) do
            local g = list[n]
            if g and not seen[g] and #out < 16 then seen[g] = true out[#out + 1] = g end
        end
    end
    return out
end

-- Hands c a signed route: it dials rows[1], the gate there dials rows[2] once free, and so on.
-- every > 0 repeats it (a scheduled dial, admins only).
local function sendRoute(c, rows, every)
    if not c then return "No gate in range." end
    local hops = {}
    -- Each later hop names the gate that carries it out when its key is known (a row signed by
    -- its gate): relaying gates hand the route only to it. The first needs none: c proved its key.
    for i, r in ipairs(rows) do
        local by = i > 1 and rows[i - 1].key or nil
        hops[i] = {address = r.Address, idc = idcOf(r), delay = 0, gate = type(by) == "string" and #by == 22 and by or nil}
    end
    if #hops == 0 or #hops > route.MAX_HOPS then return "A route has 1 to " .. route.MAX_HOPS .. " gates." end
    local signed = route.sign(identity, hops, every or 0, routeGrants(c, rows))
    c.proxy:async(guard(function(ok, result)
        if ok ~= true then log(c.name .. ": route refused: " .. tostring(result)) return end
        log(("%s: route %s (%d hop%s)."):format(c.name, tostring(result), #hops, #hops == 1 and "" or "s"))
        if not every or every == 0 then c.follow = {last = "dialing", start = true} poll(c) end
    end)).queue(signed, 1)
    return ("Sending %s a route of %d hop%s..."):format(c.name, #hops, #hops == 1 and "" or "s")
end

-- Remote update: this device's gate-side GNS files (or the paths given, under /usr), pushed to
-- a gate this device administers. A gate that starts gns at boot restarts on them.
local function gateFiles()
    local parts = dofile(gns.path.gns .. "parts.lua")
    local skip = {["gns/server/settings.lua"] = true}
    local function clientOnly(path)
        for _, p in ipairs(parts.client) do
            if path == p or path:sub(1, #p + 1) == p .. "/" then return true end
        end
    end
    local list = {}
    local function walk(dir)
        for name in fs.list("/usr/" .. dir) do
            local path = dir .. name
            if name:sub(-1) == "/" then walk(path)
            elseif path:sub(-4) == ".lua" and not skip[path] and not clientOnly(path) then list[#list + 1] = path end
        end
    end
    walk("gns/")
    list[#list + 1] = "bin/gns.lua"
    return list
end
local function update(c, paths)
    if not c then return "No gate in range." end
    if not isAdmin(c) then return c.name .. ": updates need the admin role." end
    paths = #paths > 0 and paths or gateFiles()
    local files = {}
    for _, path in ipairs(paths) do
        local file = io.open("/usr/" .. path, "rb")
        if not file then return "No file /usr/" .. path .. " here." end
        files[#files + 1] = {path, file:read("*a")}
        file:close()
    end
    -- In parts of about 32 KB, each its own call well inside the 10 s an RPC may take; the gate
    -- swaps the files in with the last part (a whole push in one took 5 s on an unloaded server).
    local parts, size = {{}}, 0
    for _, f in ipairs(files) do
        if size > 0 and size + #f[2] > 32768 then parts[#parts + 1], size = {}, 0 end
        table.insert(parts[#parts], f)
        size = size + #f[2]
    end
    local function send(i)
        c.proxy:async(guard(function(ok, count, restart)
            if ok ~= true then log(c.name .. ": update refused: " .. tostring(count)) return end
            if i < #parts then send(i + 1) return end
            log(("%s: %d files updated%s."):format(c.name, count, restart and "; it restarts once idle" or ""))
            if restart then closeConnection(c) end
        end)).update(parts[i], i, #parts)
    end
    send(1)
    return ("Pushing %d files to %s..."):format(#files, c.name)
end

---------------------------------------------------------------------------- commands
-- A gate's last address dialed by hand on its DHD (status.handDialed), and saving it.
local function samePlace(a, b)
    local n = math.min(type(a) == "table" and #a or 0, type(b) == "table" and #b or 0)
    if n < 6 then return false end
    for i = 1, n do if a[i] ~= b[i] then return false end end
    return true
end
local function inBook(hand)
    for galaxy, glyphs in pairs(hand.address) do
        for _, r in ipairs(database) do
            if samePlace(r.Address and r.Address[galaxy], glyphs) then return r end
        end
    end
end
function clientEnv.noticeHandDial(c, hand)
    if type(hand.address) ~= "table" or inBook(hand) then return end
    log(("%s was dialed by hand at %s: save [name] keeps the address."):format(c.name, tostring(hand.time)))
end
local function saveHandDial(c, name)
    local hand = c.status and c.status.handDialed
    if type(hand) ~= "table" or type(hand.address) ~= "table" then return c.name .. " has not been dialed by hand." end
    local known = inBook(hand)
    if known then return ("%s's last hand dial is %s, already in the address book."):format(c.name, known.Name) end
    local galaxy, glyphs = next(hand.address)
    if not GALAXY[galaxy] or type(glyphs) ~= "table" then return c.name .. " sent a bad address." end
    local address = {MW = {}, PG = {}, UN = {}}
    for i, glyph in ipairs(glyphs) do address[galaxy][i] = tostring(glyph) end
    local p = clientEnv.profile()
    database[#database + 1] = {Name = name, Type = galaxy, Address = address, IDCs = {}, Profiles = p and {[p.name] = true} or nil}
    clientEnv.changed()
    loom.invalidate()
    if not settings.showCodes then return ("Saved %s as gate %d (addresses are hidden on this device)."):format(name, #database) end
    return ("Saved %s as gate %d: %s."):format(name, #database, table.concat(glyphs, ", "))
end

local function gateOrFrom(selector)
    if selector then return findGate(selector), true end
    return clientEnv.fromGate()
end
clientEnv.command({"dial", "d"}, "d [from] <to> [idc] [Ns]: dial a gate (by number or name); with one gate, from the nearest gate in range; with none, the chosen ones; Ns (30s) closes the wormhole N seconds after it opens", function(args)
    local after = args[#args] and math.tointeger(tonumber(args[#args]:match("^(%d+)s$")))
    if after then table.remove(args) end
    if #args == 0 then return dialWhenFree(clientEnv.fromGate(), row(), nil, after) end
    if #args == 1 then
        local r = clientEnv.findEntry(args[1])
        if not r then return "No gate " .. args[1] .. " in the address book." end
        return dialWhenFree(nearest(r), r, nil, after)
    end
    local from = findGate(args[1])
    if not from then return "No gate " .. args[1] .. " in range." end
    local r = clientEnv.findEntry(args[2])
    if not r then return "No gate " .. args[2] .. " in the address book." end
    return dialWhenFree(from, r, math.tointeger(tonumber(args[3])), after)
end)
clientEnv.command({"close", "x"}, "close [gate]: stop dialing or close the outgoing wormhole", function(args)
    local c, named = gateOrFrom(args[1])
    if named and not c then return "No gate " .. args[1] .. " in range." end
    return disengage(c)
end)
clientEnv.command({"iris", "i"}, "iris [gate] [open|close]: open or close a gate's iris (alone: the other way)", function(args)
    local want = (args[#args] == "open" or args[#args] == "close") and table.remove(args) or nil
    local c, named = gateOrFrom(args[1])
    if named and not c then return "No gate " .. args[1] .. " in range." end
    return iris(c, want)
end)
clientEnv.command({"scan"}, "scan: look for gates in range", function() return scan(false) end)
clientEnv.command({"from", "f"}, "from [gate]: choose the gate to dial from; alone, list the gates in range", function(args)
    if not args[1] then
        if #connections == 0 then return "No gates in range." end
        local list = {}
        for _, c in ipairs(connections) do
            list[#list + 1] = c.name .. (away(c, " m") and (" " .. away(c, " m")) or "")
        end
        return "In range: " .. table.concat(list, ", ")
    end
    local c = findGate(args[1])
    if not c then return "No gate " .. args[1] .. " in range." end
    clientEnv.from = c
    poll(c)
    return "Dialing from " .. c.name .. "."
end)
clientEnv.command({"ssh", "console"}, "ssh [gate] [command]: a gate's console, for its owner and admins; with a command, run just that", function(args)
    local c = args[1] and findGate(args[1])
    local rest = 2
    if not c then c, rest = clientEnv.fromGate(), 1 end
    if not c then return "No gate in range." end
    if not isAdmin(c) then return c.name .. ": the console needs the admin role."  end
    if #args < rest then return console(c) end
    local line = table.concat(args, " ", rest)
    remote(c, line, function(text) log("  " .. c.name .. ": " .. text) end)
    return c.name .. "> " .. line
end)

clientEnv.command({"setup"}, "setup [gate]: make an unregistered gate yours (you own it; your player is its OC user)", function(args)
    local c, named = gateOrFrom(args[1])
    if named and not c then return "No gate " .. args[1] .. " in range." end
    return setup(c)
end)
clientEnv.command({"gdo"}, "gdo [idc]: through the open wormhole, your signed pass to a GNS gate, or an IDC (the destination's, or this one)", function(args)
    return gdo(clientEnv.fromGate(), math.tointeger(tonumber(args[1])))
end)
clientEnv.command({"back"}, "back [seconds]: once the wormhole is open, the far gate dials this one back after that long (5 s)", function(args)
    return dialBack(clientEnv.fromGate(), math.tointeger(tonumber(args[1])) or 5)
end)
clientEnv.command({"route"}, "route <gate> <gate> ...: the dialing gate dials the first, which dials the next once free, and so on", function(args)
    local rows = {}
    for _, a in ipairs(args) do
        local r = clientEnv.findEntry(a)
        if not r then return "No gate " .. a .. " in the address book." end
        rows[#rows + 1] = r
    end
    return sendRoute(clientEnv.fromGate(), rows)
end)
clientEnv.command({"home"}, "home [back [seconds]] | home set <gate> | home none: dial the home gate with its IDC; back: home dials you back", function(args)
    local word = (args[1] or ""):lower()
    if word == "set" then
        local r = clientEnv.findEntry(args[2])
        if not r then return "No gate " .. tostring(args[2]) .. " in the address book." end
        clientEnv.setHome(r)
        return r.Name .. " is the home gate."
    elseif word == "none" then
        clientEnv.setHome(nil)
        return "No home gate."
    end
    local home
    for _, r in ipairs(database) do if r.home then home = r end end
    if not home then return "No home gate: home set <gate>, or HOME on Gates." end
    local c = nearest(home)
    local said = dialWhenFree(c, home) -- a busy gate: it waits, as DIAL does
    if not c then return said end
    if word == "back" then
        dialBack(c, math.tointeger(tonumber(args[2])) or 5, home)
    elseif not idcOf(home) and home.key then
        waitOpen(c, function(open) if open then say(gdo(c)) end end, home)
    end
    return said
end)
clientEnv.command({"gatelog"}, "gatelog [gate]: what happened at a gate, newest first (admins; also LOG in the console)", function(args)
    local c = gateOrFrom(args[1])
    if not c then return args[1] and ("No gate " .. args[1] .. " in range.") or "No gate in range." end
    return clientEnv.gateLog(c)
end)
clientEnv.command({"save"}, "save [name]: add the address last dialed by hand at the dialing gate's DHD to the address book", function(args)
    local c = clientEnv.fromGate()
    if not c then return "No gate in range." end
    if args[1] then return saveHandDial(c, table.concat(args, " ")) end
    local hand = c.status and c.status.handDialed
    if type(hand) ~= "table" then return c.name .. " has not been dialed by hand." end
    if inBook(hand) then return saveHandDial(c, "") end
    clientEnv.ask("Name for the gate dialed by hand at " .. c.name, {text = c.name .. " dial " .. tostring(hand.time), title = "SAVE"}, guard(function(name)
        if name and name:match("%S") then log(saveHandDial(c, name)) end
    end))
end)
clientEnv.command({"energy", "e"}, "energy [gate]: what dialing it from the dialing gate costs, and how long the wormhole can stay open", function(args)
    local c = clientEnv.fromGate()
    local r = args[1] and clientEnv.findEntry(args[1]) or row()
    if not c then return "No gate in range." end
    if not r then return "Choose a gate to dial." end
    c.proxy:async(guard(function(ok, x)
        if ok ~= true then log(("%s to %s: %s"):format(c.name, r.Name, tostring(x))) return end
        cost.from, cost.dest, cost.at, cost.result, cost.error = c, r, computer.uptime(), x, nil
        log(("%s to %s: %d glyphs. %s."):format(c.name, r.Name, x.glyphs, costText(c, r)))
    end)).energy(r.Address)
end)
clientEnv.command({"schedule"}, "schedule <minutes> <gate> | schedule [remove <n>]: the dialing gate dials a gate every so often (admins)", function(args)
    local c = clientEnv.fromGate()
    if not c then return "No gate in range." end
    local minutes = math.tointeger(tonumber(args[1]))
    if minutes and args[2] then
        local r = clientEnv.findEntry(args[2])
        if not r then return "No gate " .. args[2] .. " in the address book." end
        if minutes < 1 then return "At least every minute." end
        return sendRoute(c, {r}, minutes * 60)
    end
    if not isAdmin(c) then return c.name .. ": scheduled dials need the admin role." end
    remote(c, "schedule " .. table.concat(args, " "), function(text) log("  " .. c.name .. ": " .. text) end)
end)
clientEnv.command({"update"}, "update [gate] [path ...]: push this device's GNS gate files (or those paths under /usr) to a gate you administer", function(args)
    local c, rest = args[1] and findGate(args[1]), 2
    if not c then c, rest = clientEnv.fromGate(), 1 end
    return update(c, {table.unpack(args, rest)})
end)

---------------------------------------------------------------------------- the screen
-- What the drawn gate shows, from the dialing gate's status.
local function gateLook()
    local c = clientEnv.fromGate()
    local s = c and c.status
    if not s then return "idle", {}, "MW", 0, 7 end
    local total = math.max(#(s.target or {}), #plannedGlyphs(c, row()), 1)
    local engaged = #(s.glyphs or {})
    local state = "idle"
    if s.state == "open" then
        state = s.iris == "CLOSED" and "iris" or "open"
        engaged = total
    elseif s.dialing or engaged > 0 or s.state == "dialing" then
        state = "dial"
    end
    return state, ui.litChevrons(math.min(engaged, total), total), galaxyOf(c), engaged, total
end
-- The dialing gate's iris: its state and type, for the drawn gate.
local function irisLook()
    local c = clientEnv.fromGate()
    local s = c and c.status
    if s then return s.iris, s.irisType end
end
local function headline()
    local c = clientEnv.fromGate()
    local state, _, _, engaged, total = gateLook()
    local r = row()
    local name = r and r.Name or "?"
    if not c then return "NO GATE", "No gate in range: SCAN looks for gates. Press ; for commands.", C.dim end
    local s = c.status or {}
    if state == "iris" then
        local shield = s.irisType == "SHIELD"
        return shield and "SHIELD UP" or "IRIS CLOSED",
            (s.outgoing and ("Wormhole to " .. name) or "Incoming wormhole") .. (shield and " · shield up" or " · iris closed"), C.red
    elseif state == "open" then
        return "WORMHOLE OPEN", s.outgoing and ("Wormhole open to " .. name) or "Incoming wormhole", C.sky
    elseif state == "dial" then
        return engaged == 0 and "DIALING" or (engaged >= total and ("CHEVRON " .. total .. " LOCKED") or ("CHEVRON " .. engaged .. " ENGAGED")),
            ("Dialing · chevron %d of %d engaged"):format(engaged, total), C.amber
    end
    local price = wide and "" or costText(c, r)
    return "READY", ("Ready · %s to %s, %d glyphs%s"):format(c.name, name, #plannedGlyphs(c, r), price ~= "" and (" · " .. price) or ""), C.dim
end
local function chips(self, x, y, w, pitch, h)
    local c = clientEnv.fromGate()
    local s = c and c.status
    local glyphs = (s and s.target and #s.target > 0 and (s.dialing or s.state == "open")) and s.target or plannedGlyphs(c, row())
    local state, _, _, engaged = gateLook()
    for i = 1, math.min(#glyphs, w // pitch) do
        local gx = x + (i - 1) * pitch
        local on, nextUp = i <= engaged or state == "open" or state == "iris", state == "dial" and i == engaged + 1
        local bg = on and C.amber or (nextUp and C.raised or C.card)
        self:fill(gx, y, pitch - 1, h, bg)
        self:text(gx + 1, y, tostring(i), on and C.black or C.faint, bg)
        local name = glyphs[i] == "Point of Origin" and "Origin" or (settings.showCodes and glyphs[i] or "·")
        self:text(gx, y + h - 1, ui.center(name, pitch - 1), on and C.black or (nextUp and C.amber or C.dim), bg)
    end
end
local function energy(s)
    local e, cap = tonumber(s.energy) or 0, tonumber(s.capacity)
    local text = e >= 1e6 and ("%.1fM RF"):format(e / 1e6) or (e >= 1e3 and ("%dk RF"):format(e // 1000) or (math.floor(e) .. " RF"))
    return text, cap and cap > 0 and e / cap or nil
end
local function fromNote()
    local c = clientEnv.fromGate()
    if not c then return "none in range" end
    return "[" .. c.tag .. "]"
end
local function cycle(step)
    if #connections == 0 then return end
    local at = 1
    for i, c in ipairs(connections) do if c == clientEnv.fromGate() then at = i end end
    clientEnv.from = connections[(at - 1 + step) % #connections + 1]
    poll(clientEnv.from)
end
local function fromName() local c = clientEnv.fromGate() return c and c.name or "no gate" end

-- The address book, searched by name, type or location, and by glyph where addresses are shown.
local search = ""
-- A gate's address on one line: each glyph's first three letters (a Universe glyph's number).
local function shortAddress(r)
    local out = {}
    for i, g in ipairs((r.Address or {})[r.Type or "MW"] or {}) do
        out[i] = tostring(g):match("^Glyph (%d+)$") or unicode.sub(tostring(g), 1, 3)
    end
    return #out > 0 and table.concat(out, " ") or "no address"
end
local function bookItems()
    local list, want = {}, search:lower()
    for i, r in ipairs(database) do
        local hay = clientEnv.inProfile(r) and clientEnv.searchText(r)
        if hay and (want == "" or hay:find(want, 1, true)) then list[#list + 1] = {r = r, i = i} end
    end
    return list
end
-- "142 gates", or with a profile in use "Profile · 12 gates".
local function bookNote()
    local p = clientEnv.profile()
    if not p then return #database .. " gates" end
    return ("%s · %d gates"):format(p.name, #bookItems())
end
local function bookList(x, y, w, h, columns, pitch)
    return ui.List(frame, x, y, w, h, {items = bookItems, pitch = pitch, empty = "No gates yet. SCAN learns the gates in range; Gates adds your own.",
        cells = columns, selected = function(item) return item.r == row() end,
        press = function(item) clientEnv.dest = item.r end})
end
local function dialLabel()
    local state = gateLook()
    if state == "dial" then return "DIALING…" end
    if state == "open" or state == "iris" then return "CONNECTED" end
    local r = row()
    return "DIAL  " .. (r and r.Name or "")
end

local first
if wide then
    local gw = ui.gateSize(22)
    ui.Gate(frame, 1 + (71 - gw) // 2, 1, 22, gateLook, C.page, irisLook)
    ui.Paint(frame, 1, 38, 71, 8, function(self)
        local big, detail, colour = headline()
        self:fill(1, 1, 71, 8, C.page)
        self:big(36, 1, big, colour, C.page)
        self:text(1, 5, ui.center(detail, 71), C.dim, C.page)
        chips(self, 2, 7, 71, 10, 2)
    end)
    local rx, rw = 75, R.w - 75
    ui.card(frame, rx, 1, rw, 5, "FROM", fromNote, function(self)
        local c = clientEnv.fromGate()
        local s = c and c.status
        if not s then
            self:text(3, 3, "SCAN looks for gates in range.", C.faint, C.card)
            return
        end
        local galaxy = GALAXY[galaxyOf(c)]
        self:text(3, 3, ui.pad(("%s · %s%s"):format(galaxy, tostring(s.state), away(c, " blocks away") and (" · " .. away(c, " blocks away")) or ""), rw - 4), C.dim, C.card)
        local text, fraction = energy(s)
        self:text(3, 4, "Energy", C.faint, C.card)
        if fraction then self:bar(11, 4, 32, fraction, C.amber, C.card) end
        self:text(fraction and 45 or 11, 4, text, C.text, C.card)
        self:text(3, 5, "Iris", C.faint, C.card)
        self:text(11, 5, tostring(s.iris), s.iris == "CLOSED" and C.red or C.green, C.card)
        if s.irisProblem then
            self:text(23, 5, ui.pad(s.irisProblem, rw - 24), C.red, C.card)
        else
            self:text(23, 5, ("Server %.1f TPS"):format(tonumber(s.tps) or 0), C.dim, C.card)
        end
    end)
    local left = ui.chooser(frame, rx + 1, 2, 22, fromName, function() cycle(-1) end, function() cycle(1) end)
    first = left
    ui.Button(frame, rx + 24, 2, 7, 1, "SCAN", C.amber, C.black, function() say(scan(false)) end)
    ui.Button(frame, rx + 33, 2, 7, 1, "CLOSE", C.raised, C.text, function()
        local c = clientEnv.fromGate()
        if c then closeConnection(c) end
    end)
    ui.Button(frame, rx + 42, 2, 9, 1, "CONSOLE", function() return isAdmin(clientEnv.fromGate()) and C.blue or C.raised end,
        function() return isAdmin(clientEnv.fromGate()) and C.black or C.faint end, function()
            local c = clientEnv.fromGate()
            if isAdmin(c) then console(c) else log("The console needs the admin role.") end
        end)
    ui.Button(frame, rx + 53, 2, 6, 1, "GDO", C.amber, C.black, function() say(gdo(clientEnv.fromGate())) end)

    ui.card(frame, rx, 7, rw, 8, "DESTINATION", function() local r = row() return r and ("[" .. tostring(r.Type or "MW") .. "]") end, function(self)
        local r = row()
        if not r then self:text(3, 3, "No gates in the address book yet.", C.faint, C.card) return end
        self:text(3, 2, r.Name, C.amber, C.card)
        local place = (GALAXY[r.Type] or tostring(r.Type or "")) .. (clientEnv.place(r) and (" · " .. clientEnv.place(r)) or "")
        self:text(5 + unicode.len(r.Name), 2, ui.pad(place, rw - 8 - unicode.len(r.Name)), C.dim, C.card)
        local codes = #(r.IDCs or {}) > 0 and (settings.showCodes and ("IDC " .. table.concat(r.IDCs, ", ")) or "IDC hidden") or "No IDC"
        local signed = r.key and vaultState.book[r.key] and ("signed by its gate, " .. fingerprint(r.key):sub(1, 13)) or "added by hand"
        self:text(3, 3, ui.pad(codes .. " · " .. signed .. (r.home and " · home" or ""), rw - 4), C.faint, C.card)
        self:text(3, 4, ui.pad(costText(clientEnv.fromGate(), r), rw - 4), cost.error or (cost.result and not cost.result.canOpen) and C.red or C.dim, C.card)
        if not settings.showCodes then self:text(3, 5, "Address hidden on this device.", C.faint, C.card) return end
        -- Four to a row, each row's blocks sharing its width (so the last row's are wider).
        local glyphs = plannedGlyphs(clientEnv.fromGate(), r)
        for i, glyph in ipairs(glyphs) do
            local rowStart = (i - 1) // 4 * 4
            local n = math.min(4, #glyphs - rowStart)
            local bw = (rw - 4 - (n - 1)) // n
            self:block(3 + (i - 1 - rowStart) * (bw + 1), 5 + (i - 1) // 4 * 2, bw, glyph, C.raised, C.text)
        end
    end)
    ui.card(frame, rx, 16, rw, 13, "ADDRESS BOOK", bookNote)
    ui.Field(frame, rx + 1, 17, rw - 12, {placeholder = "⌕ search gates", changed = function(t) search = t end})
    ui.Button(frame, rx + rw - 10, 17, 9, 1, "GLYPHS", C.raised, C.text, function() clientEnv.showGlyphs() end)
    bookList(rx, 18, rw, 11, function(item, _, w)
        local r = item.r
        return {{1, ui.pad(tostring(item.i), 3), C.faint}, {5, ui.pad(r.Name, 20)}, {26, tostring(r.Type or ""), C.dim},
            {30, ui.pad(clientEnv.place(r) or "", w - 40), C.faint}, {w - 8, settings.showCodes and #(r.IDCs or {}) > 0 and "[IDC]" or (r.home and "[⌂]" or ""), C.amber}}
    end)
    ui.Button(frame, rx, 30, rw, 3, dialLabel, C.green, C.black, function()
        say(dialWhenFree(clientEnv.fromGate(), row()))
    end, {around = C.page})
    local half = (rw - 2) // 2
    ui.Button(frame, rx, 34, half, 3, "DISENGAGE", C.red, C.black, function() say(disengage(clientEnv.fromGate())) end, {around = C.page})
    ui.Button(frame, rx + half + 2, 34, rw - half - 2, 3, "IRIS", C.blue, C.black, function() say(iris(clientEnv.fromGate())) end, {around = C.page})
    ui.card(frame, rx, 38, rw, 9, "ACTIVITY", nil, function(self)
        -- The newest lines, wrapped (keeping a command result's indent), the newest brightest.
        local a, rows, width = clientEnv.activity, {}, rw - 11
        local i = #a
        while i >= 1 and #rows < 8 do
            local indent, text = a[i].text:match("^(%s*)(.*)$")
            local lines = ui.wrap(text, width - #indent)
            for j = #lines, 1, -1 do
                table.insert(rows, 1, {j == 1 and a[i].time or "", indent .. lines[j], i == #a and C.text or C.dim})
            end
            i = i - 1
        end
        while #rows > 8 do table.remove(rows, 1) end
        for r = 1, 8 do
            local row = rows[r] or {"", ""}
            self:text(3, r + 1, ui.pad(row[1], 7) .. ui.pad(row[2], width), row[3] or C.dim, C.card)
        end
    end)
else
    local gw = ui.gateSize(7)
    ui.Gate(frame, 1 + (26 - gw) // 2, 1, 7, gateLook, C.page, irisLook)
    ui.Paint(frame, 1, 15, R.w, 3, function(self)
        local _, detail, colour = headline()
        self:fill(1, 1, R.w, 3, C.page)
        self:text(1, 1, ui.pad(detail, R.w), colour, C.page)
        chips(self, 1, 2, R.w, 9, 2)
    end)
    local rx, rw = 28, R.w - 27
    ui.card(frame, rx, 1, rw, 4, "FROM", nil, function(self)
        local c = clientEnv.fromGate()
        local s = c and c.status
        if not s then self:text(3, 3, "SCAN looks for gates.", C.faint, C.card) return end
        self:text(3, 3, GALAXY[galaxyOf(c)] .. " · iris ", C.dim, C.card)
        local x = 3 + unicode.len(GALAXY[galaxyOf(c)]) + 8
        self:text(x, 3, tostring(s.iris), s.iris == "CLOSED" and C.red or C.green, C.card)
        if s.irisProblem then
            local after = x + unicode.len(tostring(s.iris)) + 1
            self:text(after, 3, ui.pad(s.irisProblem, rw - after - 1), C.red, C.card)
        end
        local text, fraction = energy(s)
        if fraction then self:bar(3, 4, 8, fraction, C.amber, C.card) end
        self:text(fraction and 12 or 3, 4, ui.pad(text .. "  " .. fromNote(), rw - (fraction and 13 or 4)), C.text, C.card)
    end)
    ui.Button(frame, rx + rw - 13, 1, 6, 1, "SSH", function() return isAdmin(clientEnv.fromGate()) and C.blue or C.head end,
        function() return isAdmin(clientEnv.fromGate()) and C.black or C.faint end, function()
            local c = clientEnv.fromGate()
            if isAdmin(c) then console(c) else log("The console needs the admin role.") end
        end, {around = C.head})
    ui.Button(frame, rx + rw - 6, 1, 6, 1, "SCAN", C.amber, C.black, function() say(scan(false)) end, {around = C.head})
    first = ui.chooser(frame, rx + 1, 2, rw - 7, fromName, function() cycle(-1) end, function() cycle(1) end)
    ui.Button(frame, rx + rw - 4, 2, 3, 1, "✕", C.raised, C.red, function()
        local c = clientEnv.fromGate()
        if c then closeConnection(c) end
    end)
    ui.card(frame, rx, 6, rw, 8, "TO", bookNote)
    ui.Field(frame, rx + 1, 7, rw - 11, {placeholder = "⌕ search", changed = function(t) search = t end})
    ui.Button(frame, rx + rw - 9, 7, 8, 1, "GLYPHS", C.raised, C.text, function() clientEnv.showGlyphs() end)
    -- With addresses shown, each gate takes two lines: its address goes under its name.
    bookList(rx, 8, rw, 6, function(item, _, w)
        local r = item.r
        local cells = {{1, ui.pad(tostring(item.i), 3), C.faint, 0}, {4, ui.pad(r.Name, w - 13), C.text, 0}, {w - 8, tostring(r.Type or ""), C.dim, 0},
            {w - 4, settings.showCodes and #(r.IDCs or {}) > 0 and "IDC" or (r.home and "⌂" or ""), C.amber, 0}}
        if settings.showCodes then cells[#cells + 1] = {2, ui.pad(shortAddress(r), w - 3), C.faint, 1} end
        return cells
    end, function() return settings.showCodes and 2 or 1 end)
    local third = R.w // 3
    ui.Button(frame, 1, 19, third, 3, dialLabel, C.green, C.black, function()
        say(dialWhenFree(clientEnv.fromGate(), row()))
    end, {around = C.page})
    ui.Button(frame, third + 2, 19, third - 1, 3, "DISENGAGE", C.red, C.black, function() say(disengage(clientEnv.fromGate())) end, {around = C.page})
    ui.Button(frame, 2 * third + 2, 19, R.w - 2 * third - 2, 3, "IRIS", C.blue, C.black, function() say(iris(clientEnv.fromGate())) end, {around = C.page})
end

---------------------------------------------------------------------------- glyph touch view
-- The dialing gate's galaxy glyphs as buttons, like a DHD: tapping one adds it to the address
-- (a glyph once, at most eight), RESET starts over as on AGS, DIAL dials the address and SAVE
-- adds it to the address book. GLYPHS on Dial, or the glyphs command.
function clientEnv.showGlyphs()
    if ui.modalOpen() then return end
    local c = clientEnv.fromGate()
    local galaxy = galaxyOf(c)
    local glyphs = (clientEnv.GLYPHS or {})[galaxy] or {}
    local typed = {}
    local cell = galaxy == "UN" and 10 or 18
    local w = math.min(ui.W - 4, 2 + ((ui.W - 8) // cell) * cell + 2)
    local columns = (w - 4) // cell
    local rows = (#glyphs + columns - 1) // columns
    local pitch = rows * 2 + 8 <= ui.H - 2 and 2 or 1 -- a blank line between rows where they fit
    local h = math.min(ui.H - 2, rows * pitch + 8)
    local box, close = ui.modal(clientEnv.root, clientEnv.shell, w, h, ("GLYPHS · %s · %s"):format(c and c.name or "no gate", GALAXY[galaxy]))
    local function has(g) for _, t in ipairs(typed) do if t == g then return true end end end
    for i, g in ipairs(glyphs) do
        local x, y = 3 + ((i - 1) % columns) * cell, 3 + ((i - 1) // columns) * pitch
        ui.Button(box, x, y, cell - 1, 1, g, function() return has(g) and C.amber or C.raised end,
            function() return has(g) and C.black or C.text end, function()
                if has(g) or #typed >= 8 then return end
                typed[#typed + 1] = g
            end)
    end
    ui.Paint(box, 3, h - 4, w - 4, 2, function(self)
        self:text(1, 1, ui.pad(#typed == 0 and "Tap the glyphs of the address, as on a DHD." or table.concat(typed, " · "), w - 4), C.amber, C.card)
        self:text(1, 2, ui.pad(("%d of 6 to 8 glyphs; the point of origin is added when it dials"):format(#typed), w - 4), C.faint, C.card)
    end)
    local function typedRow(name)
        return {Name = name, Type = galaxy, IDCs = {}, Address = {MW = {}, PG = {}, UN = {}, [galaxy] = {table.unpack(typed)}}}
    end
    local bw = (w - 12) // 4
    ui.Button(box, 3, h - 1, bw, 1, "RESET", C.raised, C.text, function() typed = {} end)
    ui.Button(box, 5 + bw, h - 1, bw, 1, "DIAL", C.green, C.black, function()
        if #typed < 6 then log("An address has 6 to 8 glyphs.") return end
        close()
        local r = typedRow(table.concat(typed, " "))
        r.typed = true
        say(dialWhenFree(c, r))
    end)
    ui.Button(box, 7 + 2 * bw, h - 1, bw, 1, "SAVE", C.amber, C.black, function()
        if #typed < 6 then log("An address has 6 to 8 glyphs.") return end
        local r = typedRow("")
        close()
        clientEnv.ask("Name of the gate at this address", {text = "", title = "SAVE"}, function(name)
            if not name or not name:match("%S") then return end
            r.Name = name
            local p = clientEnv.profile()
            if p then r.Profiles = {[p.name] = true} end
            database[#database + 1] = r
            clientEnv.changed()
            log(("Added %s as gate %d: %s."):format(name, #database, table.concat(r.Address[galaxy], ", ")))
        end)
    end)
    ui.Button(box, 9 + 3 * bw, h - 1, bw, 1, "CLOSE", C.raised, C.text, close)
end
clientEnv.command({"glyphs"}, "glyphs: the dialing gate's glyphs as buttons, to dial or save an address by touch", function()
    clientEnv.showGlyphs()
end)

-- The first time the client opens, wake the known gates and look for gates straight away.
if not dial.scanned then
    dial.scanned = true
    scan(false)
end

return {first = first}
