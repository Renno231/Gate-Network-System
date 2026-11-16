-- Dial screen: finds the gates in range on this device's ports (link.lua's hello), wakes the
-- sleeping ones it holds wake keys for, opens each as it answers (gate.open with the grants held),
-- keeps each gate's own signed entry in the address book and dials. Every gate command is one
-- message, sent once; nothing stays connected. The stargate is drawn from
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
local handshake = clientEnv.handshake
local entries = clientEnv.entries
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
local TYPE = {MILKYWAY = "MW", PEGASUS = "PG", UNIVERSE = "UN"} -- the stargate's getGateType
local ORIGIN = {MW = "Point of Origin", PG = "Subido", UN = "Glyph 17"}
-- Each galaxy's glyph names, for the glyph touch view and the address book's glyph editor.
local GLYPHS = {
    MW = {"Andromeda", "Aquarius", "Aries", "Auriga", "Bootes", "Cancer", "Canis Minor", "Capricornus", "Centaurus", "Cetus",
        "Corona Australis", "Crater", "Equuleus", "Eridanus", "Gemini", "Hydra", "Leo", "Leo Minor", "Libra", "Lynx",
        "Microscopium", "Monoceros", "Norma", "Orion", "Pegasus", "Perseus", "Pisces", "Piscis Austrinus", "Sagittarius",
        "Scorpius", "Sculptor", "Scutum", "Serpens Caput", "Sextans", "Taurus", "Triangulum", "Virgo"},
    PG = {"Aaxel", "Abrin", "Acjesis", "Aldeni", "Alura", "Amiwill", "Arami", "Avoniv", "Baselai", "Bydo", "Ca Po", "Danami",
        "Dawnre", "Ecrumig", "Elenami", "Gilltin", "Hacemill", "Hamlinto", "Illume", "Laylox", "Lenchan", "Olavii", "Once El",
        "Poco Re", "Ramnon", "Recktic", "Robandus", "Roehi", "Salma", "Sandovi", "Setas", "Sibbron", "Tahnan", "Zamilloz", "Zeo"},
    UN = {},
}
for i = 1, 36 do if i ~= 17 then GLYPHS.UN[#GLYPHS.UN + 1] = "Glyph " .. i end end
clientEnv.GLYPHS = GLYPHS

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
    for _, row in ipairs(database) do
        if row.key == e.key then
            row.Name, row.Type, row.retired = e.name, e.type, e.retired
            clientEnv.setAddress(row, e.address)
            if e.dim and type(row.Location) ~= "table" then row.Location = {dimension = e.dim} end
            return row
        end
    end
    local row = clientEnv.setAddress({key = e.key, Name = e.name, Type = e.type, IDCs = {},
        Location = e.dim and {dimension = e.dim} or nil}, e.address)
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
-- The vault is saved only when this changed something: every open of every gate comes here.
local function remember(c, wake)
    local e, new, changed = c.entry, false, false
    if type(e) == "table" and e.key == c.key then
        new = vaultState.book[c.key] == nil
        local ok, merged = pcall(entries.merge, vaultState.book, e)
        changed = ok and merged ~= nil
        local own = vaultState.book[c.key]
        if own then
            c.name = own.name
            local rows = #database
            local row = settings.autoLogToDatabase and record(own)
            if row then clientEnv.joinByPort(row, c.port) end
            changed = changed or #database ~= rows
        end
    end
    if c.tag ~= "public" and c.tag ~= "unregistered" then
        local a = vaultState.access[c.key] or {}
        wake = wake or a.wake
        if not vaultState.access[c.key] or a.name ~= c.name or a.modem ~= c.address or a.port ~= c.port
            or a.owner ~= c.owner or a.role ~= c.role or a.wake ~= wake or a.silent ~= c.silent then
            a.name, a.modem, a.port, a.owner, a.role, a.wake = c.name, c.address, c.port, c.owner, c.role, wake
            a.silent = c.silent
            vaultState.access[c.key] = a
            changed = true
        end
    end
    if changed then clientEnv.changed() end
    return new
end

-- Grants this device cut off reach every gate they cover that it administers: on each open, the
-- ones that gate has not taken yet (issued.cutAt, by gate key).
local function pushCuts(c)
    if not isAdmin(c) then return end
    local list, sent = {}, {}
    for _, issued in ipairs(vaultState.issued) do
        local g = issued.grant
        if issued.cut and not (issued.cutAt and issued.cutAt[c.key]) and g.owner == c.owner
            and (g.gate == "" or g.gate == c.key) and (c.role == "owner" or g.role == "user") then
            list[#list + 1], sent[#sent + 1] = g, issued
        end
    end
    if #list == 0 then return end
    c.proxy:async(guard(function(ok, count)
        if ok ~= true then log(c.name .. ": cut-offs refused: " .. tostring(count)) return end
        for _, issued in ipairs(sent) do
            issued.cutAt = issued.cutAt or {}
            issued.cutAt[c.key] = true
        end
        clientEnv.changed()
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
    local proof = vaultState.proofs[address]
    handshake.openAsync(c.proxy, identity, vaultState.pins, {grants = grantsFor(known and known.owner, gateKey)}, guard(function(reply, reason, newKey)
        if vaultState.proofs[address] ~= proof then clientEnv.changed() end -- signed a new one
        if not reply then return callback(nil, reason, newKey) end
        if not reply.role then return callback(nil, tostring(reply.refused or "private gate")) end
        c.key, c.role, c.owner, c.registered, c.entry = reply.key, reply.role, reply.owner, reply.registered, reply.entry
        c.public, c.silent = reply.public == true or nil, reply.silent == true or nil
        c.allow = type(reply.allow) == "table" and reply.allow or nil -- the owner's and admins' devices get it
        c.status = reply.status
        c.name = reply.status and reply.status.name or c.name or address:sub(1, 8)
        -- What the top bar shows: the role from ownership or a grant, else how the gate is open.
        c.tag = not reply.registered and "unregistered" or (reply.wake and reply.role) or "public"
        c.new = remember(c, reply.wake)
        pushCuts(c)
        callback(c)
    end), vaultState.proofs)
end

-- Wakes the gates this device holds wake keys for that are not open here and did not answer
-- (answered: the modems that did): a message to each gate's own modem (never a broadcast).
-- Returns how many.
local function wakeKnown(answered)
    local modem, sent = component.modem, 0
    for _, a in pairs(vaultState.access) do
        if a.wake and a.modem and not answered[a.modem] and clientEnv.ports()[a.port or 160] and not findConnection(a.modem) then
            if pcall(modem.send, a.modem, a.port or 160, a.wake) then sent = sent + 1 end
        end
    end
    return sent
end

-- Asks the gates in range who they are and opens each as it answers. Another SCAN meanwhile
-- just asks again. Every scan drops the gates that no longer answer (asleep or gone), wakes the
-- known gates that did not answer and looks again once those have had time to start (that look
-- wakes none: noWake). quiet (the automatic rescan) reports only the gates it opened or
-- dropped.
local wakeTimer
local poll -- below: a scan polls the gates already open
-- A dial waiting for its gate (waitToDial, below): dropped with its gate's connection too.
local queued
local function dropQueued(connection)
    if queued and (not connection or queued.gate == connection) then queued.stop() queued = nil end
end
local opening = {} -- modem → true while its open is under way

-- Drops this connection (not a newer one to the same modem: a gate that moved port, say).
local function forget(c)
    for i, x in ipairs(connections) do
        if x == c then table.remove(connections, i) break end
    end
    if clientEnv.from == c then clientEnv.from = nil end
    dropQueued(c)
end

local function scan(quiet, noWake)
    dial.sinceScan = 0
    local woken = 0
    if not quiet then log("Scanning for gates...") end
    local seen, found, waiting, opened, refused, new = {}, 0, 1, 0, 0, 0
    local function done()
        waiting = waiting - 1
        if waiting > 0 then return end
        if woken > 0 then
            if wakeTimer then event.cancel(wakeTimer) end
            wakeTimer = event.timer(15, guard(function() wakeTimer = nil scan(true, true) end))
        end
        if quiet and opened == 0 then return end
        log(("Found %d gates, opened %d, %d new%s."):format(found, opened, new, refused > 0 and (", " .. refused .. " private") or ""))
    end
    link.hello(clientEnv.ports(), 2, guard(function(address, port, distance, hello)
        if seen[address] then return end
        seen[address], found = true, found + 1
        local known = findConnection(address)
        if known then
            known.distance = distance -- a gate already open is asked nothing more until it is used,
            -- but one renamed or reinstalled since (its hello's name or key) is opened again as new
            local was = known.status and known.status.name
            if not ((hello.key and known.key and hello.key ~= known.key) or (hello.name and was and hello.name ~= was)) then
                return
            end
            forget(known)
        end
        if opening[address] then return end
        opening[address], waiting = true, waiting + 1
        openGate(address, port, guard(function(connection, reason)
            opening[address] = nil
            if not connection then
                refused = refused + 1
                local a = accessByModem(address)
                local name = a and a.name or hello.name or address:sub(1, 8) -- the name its hello gave
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
        -- A silent gate answers no scan: those this device has access to are opened directly, by
        -- their modem (a scan asked for opens those open here again too, to see they are still there).
        local tries = {}
        for _, a in pairs(vaultState.access) do
            if a.silent and a.modem and not seen[a.modem] and not opening[a.modem] and clientEnv.ports()[a.port or 160]
                then
                tries[#tries + 1] = a
            end
        end
        local left = #tries + 1
        local finish
        for _, a in ipairs(tries) do
            local address = a.modem
            opening[address] = true
            openGate(address, a.port or 160, guard(function(connection)
                opening[address] = nil
                if connection then
                    seen[address], found = true, found + 1
                    if not findConnection(address) then
                        opened = opened + 1
                        if connection.new then new = new + 1 end
                        connections[#connections + 1] = connection
                        log(("Connected to %s (%s)."):format(connection.name, connection.tag))
                    end
                    table.sort(connections, byDistance)
                    loom.invalidate()
                end
                finish()
            end), findConnection(address))
        end
        finish = function()
            left = left - 1
            if left > 0 then return end
            -- A gate open here that no longer answers went to sleep or away: drop it, and wake it
            -- if this device holds its wake key.
            for i = #connections, 1, -1 do
                local c = connections[i]
                if not seen[c.address] then
                    forget(c)
                    log(c.name .. " did not answer the scan; dropped.")
                end
            end
            if not noWake then woken = wakeKnown(seen) end
            if woken > 0 and not quiet then log(("Waking %d gate%s that did not answer."):format(woken, woken == 1 and "" or "s")) end
            done()
        end
        finish()
    end))
end
clientEnv.scan = scan
clientEnv.onClose[#clientEnv.onClose + 1] = function() if wakeTimer then event.cancel(wakeTimer) end end

-- Opens every gate again, so each holds the grants held now (after joining, say).
function clientEnv.reconnect()
    for _, c in ipairs(connections) do
        local before = c.tag
        openGate(c.address, c.port, guard(function(x, reason)
            if not x then forget(c) log(c.name .. ": " .. tostring(reason))
            elseif x.tag ~= before then log(("Connected to %s (%s)."):format(x.name, x.tag)) end -- a new role
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
    return s and TYPE[s.type] or "MW"
end
-- The glyphs a dial from connection's galaxy engages: six and the point of origin (all eight
-- from another galaxy, as the gate works out).
local function plannedGlyphs(connection, r)
    local galaxy = galaxyOf(connection)
    local address = clientEnv.glyphs(r, galaxy)
    local list = {}
    for i = 1, math.min(6, #address) do list[i] = address[i] end
    if #list > 0 then list[#list + 1] = ORIGIN[galaxy] end
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
-- A gate's status comes only from a gate this device uses, as on GDS: the open's answer, an ask
-- when a command needs the gate as it is, and while this device uses it (a dial, close, iris,
-- IDC or route sent in the last minute) each change, sent by the gate. Gates merely in range
-- send nothing. While a dial this client started is followed, each change of its dial state
-- goes to the activity log.
local function took(connection, s)
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
        if f.closing then
            -- A close this device asked for: told once the gate has closed it.
            local closed = s.state ~= "open" and s.state ~= "unstable"
            if closed then log(connection.name .. ": closed") end
            if closed or old then connection.follow = nil end
        elseif f.start and not s.dialing then
            -- A route dials once the gate is free: until it starts, the last dial's state is old news.
            if old then connection.follow = nil end
        else
            f.start = nil
            if s.lastDial ~= f.last then
                -- The far gate's IDC answer can replace "open" before this device hears it.
                if s.state == "open" and s.outgoing and not s.dialing and f.last ~= "open" and s.lastDial ~= "open" then
                    log(connection.name .. ": open")
                end
                f.last = s.lastDial
                log(connection.name .. ": " .. tostring(f.last))
            end
            if (not s.dialing and not (f.idc and f.last == "open")) or old then connection.follow = nil end
        end
    end
    -- What waits on this gate's next change (waitToDial, waitOpen).
    for check in pairs(connection.waits or {}) do pcall(check) end
    loom.invalidate()
end
link.onStatus = function(address, s)
    local c = findConnection(address)
    if c then pcall(took, c, s) end
end

-- poll asks the gate for its status now (a gate chosen as FROM). Using a gate starts its watch:
-- the gate sends its status then, and each change while the device's dial lasts.
function poll(connection)
    local now = computer.uptime()
    if connection.polling and now - connection.polling < link.WAIT + 1 then return end
    connection.polling = now
    connection.proxy:async(guard(function(ok, s)
        connection.polling = false
        if ok == true and type(s) == "table" then return took(connection, s) end
        if findConnection(connection.address) ~= connection then return end -- dropped or replaced meanwhile
        forget(connection)
        if silent(s) then
            -- No answer within link.WAIT seconds: the gate is asleep or gone.
            log(connection.name .. " does not answer; SCAN finds it again.")
        else
            -- It answered and refused: this device's grant was cut off or the gate went private.
            log(("%s refuses this device: %s"):format(connection.name, tostring(s)))
        end
        loom.invalidate()
    end)).status()
end
-- Asks c for its status now, then calls after(): for a command that acts on the gate as it is.
local function fresh(c, after)
    c.proxy:async(guard(function(ok, s)
        if ok == true and type(s) == "table" then took(c, s) end
        after()
    end)).status()
end
clientEnv.fresh = fresh
-- What the chosen dial costs, as the energy command last asked it (the gate's energy check, a
-- few stargate calls), for the destination card.
local cost = {}
-- An amount in few characters, rounded down: 950, 1.5k, 12k, 1M, 2.5M (no ".0").
local function short(n)
    if n < 1e3 then return tostring(math.floor(n)) end
    local unit, v = "k", n / 1e3
    if n >= 1e6 then unit, v = "M", n / 1e6 end
    v = v >= 10 and math.floor(v) or math.floor(v * 10) / 10
    return (v == math.floor(v) and ("%d"):format(v) or ("%.1f"):format(v)) .. unit
end
-- How long, as a player reads it: 45 s, 12 min, 1 h 23 min.
local function span(seconds)
    seconds = math.floor(tonumber(seconds) or 0)
    if seconds < 60 then return seconds .. " s" end
    if seconds < 3600 then return seconds // 60 .. " min" end
    local m = seconds % 3600 // 60
    return seconds // 3600 .. " h" .. (m > 0 and (" " .. m .. " min") or "")
end
local function costText(c, r, compact)
    if cost.from ~= c or cost.dest ~= r then return "" end
    if cost.error then return compact and "cannot dial" or ("Cannot dial: " .. cost.error), true end
    local x = cost.result
    if not x then return "" end
    -- The energy now (the gate's status), against the cost asked once (as dialer.cost works it out).
    local energy = tonumber(c.status and c.status.energy) or tonumber(x.energy) or 0
    local open, keepAlive = tonumber(x.open) or 0, tonumber(x.keepAlive) or 0
    if energy < open then return ("Not enough power: %s RF to open, %s stored"):format(short(open), short(energy)), true end
    local lasts = span((energy - open) / math.max(keepAlive, 1) / 20)
    if compact then return ("%s RF · %s open"):format(short(open), lasts) end
    return ("%s RF to open · %s RF/t open · %s on stored power"):format(short(open), short(keepAlive), lasts)
end
-- Asks the dialing gate what dialing r costs (the gate's energy check, a few stargate calls), when
-- a player picks a destination or a gate to dial from: the Ready line and the destination card
-- show it. report: also log it (the energy command).
local function askCost(c, r, report)
    if not c or not r or (cost.from == c and cost.dest == r and not report) then return end
    if r.Name == c.name and not report then return end -- the gate itself: nothing to dial
    cost.from, cost.dest, cost.result, cost.error = c, r, nil, nil
    c.proxy:async(guard(function(ok, x)
        if cost.from ~= c or cost.dest ~= r then return end
        if ok ~= true then
            -- Said in the log too: the tablet's Ready line has room only for "cannot dial".
            cost.error = tostring(x)
            log(("%s to %s: %s"):format(c.name, r.Name, tostring(x)))
            return
        end
        cost.at, cost.result = computer.uptime(), x
        if report then log(("%s to %s: %d glyphs. %s."):format(c.name, r.Name, x.glyphs, (costText(c, r)))) end
    end)).energy(clientEnv.address(r))
end

-- The automatic rescan (Settings; off by default, as on GDS). No gate is asked anything else.
local statusTimer = event.timer(1, guard(function()
    local rate = tonumber(clientEnv.settings.nearbyScanRate) or 0
    dial.sinceScan = dial.sinceScan + 1
    -- Nobody at the client (client.lua): the next key or touch finds a scan due at once.
    if rate > 0 and dial.sinceScan >= rate and not clientEnv.idle() then scan(true) end
end), math.huge)
clientEnv.onClose[#clientEnv.onClose + 1] = function() event.cancel(statusTimer) end

-- Runs check() on each change c sends, until it returns true; give up after seconds: then
-- expired(). Returns the stop function.
local function onChange(c, seconds, check, expired)
    local deadline
    local function stop()
        if c.waits then c.waits[check] = nil end
        event.cancel(deadline)
    end
    c.waits = c.waits or {}
    deadline = event.timer(seconds, guard(function() stop() expired() end))
    c.waits[check] = true
    return stop
end

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
        log(("Dialing %s from %s: %d glyphs%s, %d RF, open for %s%s."):format(r.Name, connection.name,
            result.glyphs, result.from > 1 and (" from glyph " .. result.from) or "", result.open,
            span(result.seconds), result.fast and ", DHD" or ""))
        connection.follow = {last = "dialing", idc = idc} -- the gate sends its changes
    end)).dial(clientEnv.address(r), opts)
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
-- The refused dial started the gate's watch: it sends its changes, up to its idle state.
local function waitToDial(c, r, idc, deadline, stopOwn, after)
    dropQueued()
    local q = {gate = c}
    queued = q
    local function check()
        local now = c.status or {}
        if queued ~= q then return end
        if not now.dialing and now.state == "idle" then
            dropQueued()
            -- Another player may have dialed first: then wait again, to the same deadline. The
            -- dial logs itself once it goes out (not each retry, as while a player presses DHD glyphs).
            doDial(c, r, idc, function() waitToDial(c, r, idc, deadline, false, after) end, true, after)
        elseif stopOwn and now.state == "open" and now.outgoing then
            stopOwn = false -- once: a later wormhole is not this dial's
            c.proxy:async(guard(function(ok, result)
                log(c.name .. (ok == true and (": " .. tostring(result)) or (": disengage refused: " .. tostring(result))))
            end)).closeWormhole()
        end
    end
    q.stop = onChange(c, math.max(0.05, deadline - computer.uptime()), check, function()
        if queued ~= q then return end
        queued = nil
        log(("%s stayed busy: %s was not dialed."):format(c.name, r.Name))
    end)
    check()
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
        -- The gate's status says when the wormhole has closed.
        if ok == true and result == "closing" then connection.follow = {closing = true} end
    end)).closeWormhole()
end
-- What a player calls the iris's state, or the shield's: "iris shut", "shield going up".
local IRIS_WORDS = {
    iris = {OPENED = "open", CLOSED = "shut", OPENING = "opening", CLOSING = "closing"},
    shield = {OPENED = "down", CLOSED = "up", OPENING = "going down", CLOSING = "going up"},
}
local function irisKind(s) return s and s.irisType == "SHIELD" and "shield" or "iris" end
local function irisSays(s, state)
    local what = irisKind(s)
    return what .. " " .. (IRIS_WORDS[what][state] or tostring(state):lower())
end
-- want: "open", "close" or nil (the other way).
local function iris(connection, want)
    if not connection then return "No gate in range." end
    connection.proxy:async(guard(function(ok, result)
        log(connection.name .. ": " .. (ok == true and irisSays(connection.status, result) or (irisKind(connection.status) .. " refused: " .. tostring(result))))
    end)).iris(want)
end

local function say(message) if message then log(message) end end

-- Calls done(open) once c's outgoing wormhole is open (to want's gate, when given), or once the
-- dial can no longer open: DIAL waits up to 300 s for a busy gate, and the gate gives a dial 120 s
-- plus its speed.
-- Driven by the gate's changes (this device's dial: the gate sends them); this device's own dial
-- ending without opening ends the wait. Another player's dial does not: this device's may be
-- queued behind it (DIAL on a busy gate).
local waiting = {}
clientEnv.onClose[#clientEnv.onClose + 1] = function() for stop in pairs(waiting) do stop() end end

---------------------------------------------------------------------------- commands

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
    askCost(c, row())
    return "Dialing from " .. c.name .. "."
end)

clientEnv.command({"energy", "e"}, "energy [gate]: what dialing it from the dialing gate costs, and how long the wormhole can stay open", function(args)
    local c = clientEnv.fromGate()
    local r = args[1] and clientEnv.findEntry(args[1]) or row()
    if not c then return "No gate in range." end
    if not r then return "Choose a gate to dial." end
    askCost(c, r, true)
end)

-- The less used features live in interface/dial/<part>.lua, loaded when used: their code stays
-- only while something of theirs still waits (a console open, a GDO waiting for its wormhole), so a
-- player who never uses them never holds them. api: what of Dial they use.
local api
local function part(name)
    return assert(loadfile(gns.path.clientDirectory .. "interface/dial/" .. name .. ".lua"))(api)
end
local function via(name, fn) return function(...) return part(name)[fn](...) end end
api = {gns = gns, clientEnv = clientEnv, ui = ui, C = C, log = log, say = say, guard = guard, isAdmin = isAdmin,
    handshake = handshake, identity = identity, remember = remember, closeConnection = closeConnection,
    findGate = findGate, gateOrFrom = gateOrFrom, row = row, galaxyOf = galaxyOf, database = database,
    onChange = onChange, connections = connections, link = link, findConnection = findConnection,
    openGate = openGate, fresh = fresh, grantsFor = grantsFor, disengage = disengage, vaultState = vaultState,
    nearest = nearest, dialWhenFree = dialWhenFree, waiting = waiting, GALAXY = GALAXY, GLYPHS = GLYPHS,
    settings = settings, part = part}
function clientEnv.gateLog(connection) return part("admin").gateLog(connection) end
function clientEnv.noticeHandDial(c, hand) return part("handdial").notice(c, hand) end
function clientEnv.showGlyphs() return part("glyphs").show() end

clientEnv.command({"ssh", "console"}, "ssh [gate] [command]: a gate's console, for its owner and admins; with a command, run just that", via("admin", "ssh"))
clientEnv.command({"setup"}, "setup [gate]: make an unregistered gate yours (you own it; your player is its OC user)", via("admin", "setupCommand"))
clientEnv.command({"gatelog"}, "gatelog [gate]: what happened at a gate, newest first (admins; also LOG in the console)", via("admin", "gatelog"))
clientEnv.command({"update"}, "update [gate] [path ...]: push this device's GNS gate files (or those paths under /usr) to a gate you administer", via("admin", "updateCommand"))
clientEnv.command({"gdo"}, "gdo [idc]: through the open wormhole, your signed pass to a GNS gate, or an IDC (the destination's, or this one)", via("travel", "gdoCommand"))
clientEnv.command({"back"}, "back [seconds]: once the wormhole is open, the far gate dials this one back after that long (5 s)", via("travel", "back"))
clientEnv.command({"route"}, "route <gate> <gate> ...: the dialing gate dials the first, which dials the next once free, and so on", via("travel", "route"))
clientEnv.command({"home"}, "home [back [seconds]] | home set <gate> | home none: dial the home gate with its IDC; back: home dials you back", via("travel", "home"))
clientEnv.command({"schedule"}, "schedule <minutes> <gate> | schedule [remove <n>]: the dialing gate dials a gate every so often (admins)", via("travel", "schedule"))
clientEnv.command({"save"}, "save [name]: add the address last dialed by hand at the dialing gate's DHD to the address book", via("handdial", "save"))
clientEnv.command({"glyphs"}, "glyphs: the dialing gate's glyphs as buttons, to dial or save an address by touch", via("glyphs", "show"))

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
    elseif s.dialing and s.iris == "CLOSED" and engaged >= total then
        state = "iris" -- shut as the last chevron locked, for the kawoosh
    elseif s.dialing or engaged > 0 or s.state == "dialing" then
        state = "dial"
    end
    return state, ui.litChevrons(math.min(engaged, total), total), galaxyOf(c), engaged, total, s.spinning == true
end
-- The dialing gate's iris: its state and type, for the drawn gate.
local function irisLook()
    local c = clientEnv.fromGate()
    local s = c and c.status
    if s then return s.iris, s.irisType end
end
-- A lagging server (the gate's TPS probe): its TPS, drawn in red after the dialing line.
local function slow(s)
    local tps = tonumber(s.tps)
    if tps and tps < 18 then return ("%.0f TPS"):format(tps) end
end
-- On a tablet the gate line also says what the iris (or shield) is doing when it is not simply
-- open, or why it cannot be worked; the IRIS button only works it. The computer has an iris card.
local function irisNote(s)
    if wide then return "" end
    if s.irisProblem then return " · " .. irisKind(s) .. ": " .. s.irisProblem, true end
    if s.iris == "CLOSED" or s.iris == "OPENING" or s.iris == "CLOSING" then return " · " .. irisSays(s, s.iris) end
    return ""
end
local function headline()
    local c = clientEnv.fromGate()
    local state, _, _, engaged, total = gateLook()
    local r = row()
    local name = r and r.Name or "?"
    if not c then return "NO GATE", "No gate in range: SCAN looks for gates. Press ; for commands.", C.dim end
    local s = c.status or {}
    local note, problem = irisNote(s)
    if state == "iris" then
        return s.irisType == "SHIELD" and "SHIELD UP" or "IRIS CLOSED",
            ((s.outgoing or s.dialing) and ("Wormhole to " .. name) or "Incoming wormhole") .. " · " .. irisSays(s, "CLOSED"), C.red
    elseif state == "open" then
        return "WORMHOLE OPEN", (s.outgoing and ("Wormhole open to " .. name) or "Incoming wormhole") .. note, problem and C.red or C.sky
    elseif state == "dial" then
        return engaged == 0 and "DIALING" or (engaged >= total and ("CHEVRON " .. total .. " LOCKED") or ("CHEVRON " .. engaged .. " ENGAGED")),
            ("Dialing%s · chevron %d of %d engaged"):format(note, engaged, total), problem and C.red or C.amber, slow(s)
    end
    local price, cannot = "", false
    if not wide then price, cannot = costText(c, r, true) end
    -- On a tablet the glyph row below shows the glyphs: the line keeps its room for the cost.
    local count = wide and (", %d glyphs"):format(#plannedGlyphs(c, r)) or ""
    return "READY", ("Ready%s · %s to %s%s%s"):format(note, c.name, name, count, price ~= "" and (" · " .. price) or ""),
        (problem or cannot) and C.red or (note ~= "" and C.text or C.dim)
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
    return short(e) .. " RF", cap and cap > 0 and e / cap or nil
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
    askCost(clientEnv.from, row())
end
local function fromName() local c = clientEnv.fromGate() return c and c.name or "no gate" end

-- The address book, searched by name, type or location, and by glyph where addresses are shown.
local search = ""
-- A glyph in three letters, its first three (a Universe glyph's number), for the tablet's address
-- line. Worked out once per glyph name: OC's string.match and unicode.sub are slow, and the line
-- draws on every frame.
local SHORT = setmetatable({}, {__index = function(t, g)
    local s = tostring(g)
    s = s:match("^Glyph (%d+)$") or unicode.sub(s, 1, 3)
    t[g] = s
    return s
end})
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
-- Enter in the search: with one gate left, that gate is picked and dialed.
local function dialOnlyMatch()
    local list = bookItems()
    if #list ~= 1 then
        if search ~= "" then log(#list == 0 and "No gate matches." or (#list .. " gates match: type more, or touch one.")) end
        return
    end
    clientEnv.dest = list[1].r
    say(dialWhenFree(clientEnv.fromGate(), list[1].r))
end
local function bookList(x, y, w, h, columns, pitch)
    return ui.List(frame, x, y, w, h, {items = bookItems, pitch = pitch, empty = "No gates yet. SCAN learns the gates in range; Gates adds your own.",
        cells = columns, selected = function(item) return item.r == row() end,
        press = function(item) clientEnv.dest = item.r askCost(clientEnv.fromGate(), item.r) end})
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
        local big, detail, colour, lag = headline()
        self:fill(1, 1, 71, 8, C.page)
        self:big(36, 1, big, colour, C.page)
        local line = lag and (detail .. " · " .. lag) or detail
        self:text(1, 5, ui.center(line, 71), C.dim, C.page)
        if lag then self:text((71 - unicode.len(line)) // 2 + 1 + unicode.len(line) - unicode.len(lag), 5, lag, C.red, C.page) end
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
        local kind = irisKind(s)
        self:text(3, 5, kind == "shield" and "Shield" or "Iris", C.faint, C.card)
        self:text(11, 5, ui.pad(IRIS_WORDS[kind][s.iris] or tostring(s.iris):lower(), 11), s.iris == "CLOSED" and C.red or C.green, C.card)
        if s.irisProblem then
            self:text(23, 5, ui.pad(s.irisProblem, rw - 24), C.red, C.card)
        else
            self:text(23, 5, ui.pad(s.tps and ("Server " .. ("%.1f"):format(tonumber(s.tps) or 0):gsub("%.0$", "") .. " TPS") or "", rw - 24), C.dim, C.card)
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
            if isAdmin(c) then part("admin").console(c) else log("The console needs the admin role.") end
        end)
    ui.Button(frame, rx + 53, 2, 6, 1, "GDO", C.amber, C.black, function() say(part("travel").gdo(clientEnv.fromGate())) end)

    ui.card(frame, rx, 7, rw, 8, "DESTINATION", function() local r = row() return r and ("[" .. tostring(r.Type or "MW") .. "]") end, function(self)
        local r = row()
        if not r then self:text(3, 3, "No gates in the address book yet.", C.faint, C.card) return end
        self:text(3, 2, r.Name, C.amber, C.card)
        local place = (GALAXY[r.Type] or tostring(r.Type or "")) .. (clientEnv.place(r) and (" · " .. clientEnv.place(r)) or "")
        self:text(5 + unicode.len(r.Name), 2, ui.pad(place, rw - 8 - unicode.len(r.Name)), C.dim, C.card)
        local codes = #(r.IDCs or {}) > 0 and (settings.showCodes and ("IDC " .. table.concat(r.IDCs, ", ")) or "IDC hidden") or "No IDC"
        local signed = r.key and vaultState.book[r.key] and ("signed by its gate, " .. fingerprint(r.key):sub(1, 13)) or "added by hand"
        self:text(3, 3, ui.pad(codes .. " · " .. signed .. (r.home and " · home" or ""), rw - 4), C.faint, C.card)
        local price, short = costText(clientEnv.fromGate(), r)
        self:text(3, 4, ui.pad(price, rw - 4), short and C.red or C.dim, C.card)
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
    ui.Field(frame, rx + 1, 17, rw - 12, {placeholder = "⌕ search gates", changed = function(t) search = t end, submit = dialOnlyMatch})
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
    -- The tablet, laid out like GDS's: down the left the address book, one line a gate, and under
    -- it the gates in range (touch one to dial from it); on the right the log, which moves over
    -- for the gate, drawn in braille, while the dialing gate is doing something; along the bottom
    -- SCAN, DIAL, DISENGAGE and IRIS.
    local lw, rx = 25, 28
    local rw = R.w - rx + 1
    ui.Field(frame, 1, 1, lw, {placeholder = "⌕ search", changed = function(t) search = t end, submit = dialOnlyMatch, around = C.page})
    first = bookList(1, 2, lw, 9, function(item, _, w)
        local r = item.r
        return {{1, ui.pad(tostring(item.i), 3), C.faint}, {4, ui.pad(r.Name, w - 11)}, {w - 6, tostring(r.Type or ""), C.dim},
            {w - 3, settings.showCodes and #(r.IDCs or {}) > 0 and "IDC" or (r.home and "⌂" or ""), C.amber}}
    end)

    -- The gates in range; the one dialing is amber.
    ui.Paint(frame, 1, 11, lw, 1, function(self)
        self:fill(1, 1, lw, 1, C.head)
        self:text(1, 1, "▌", C.amber, C.head)
        self:text(3, 1, "IN RANGE  " .. #connections, C.dim, C.head)
    end)
    ui.Button(frame, lw - 10, 11, 5, 1, "SSH", function() return isAdmin(clientEnv.fromGate()) and C.blue or C.head end,
        function() return isAdmin(clientEnv.fromGate()) and C.black or C.faint end, function()
            local c = clientEnv.fromGate()
            if isAdmin(c) then part("admin").console(c) else log("The console needs the admin role.") end
        end, {around = C.head})
    ui.Button(frame, lw - 3, 11, 3, 1, "✕", C.raised, C.red, function()
        local c = clientEnv.fromGate()
        if c then closeConnection(c) end
    end, {around = C.head})
    ui.List(frame, 1, 12, lw, 5, {items = connections, empty = "None yet: SCAN looks for gates.",
        cells = function(c, _, w)
            local far = away(c, " m") or ""
            if far == "this computer" then far = "here" end
            local tag = c.tag == "unregistered" and "unreg" or c.tag or ""
            return {{1, ui.pad(c.name or "?", w - 14)}, {w - 12, ui.pad(far, 5), C.faint}, {w - 6, ui.pad(tag, 6), tag == "public" and C.dim or C.amber}}
        end,
        selected = function(c) return c == clientEnv.fromGate() end,
        press = function(c) clientEnv.from = c poll(c) askCost(c, row()) end})
    -- The dialing gate's energy, and the IRIS button at the end of the line (the gate line says
    -- what the iris is doing).
    ui.Paint(frame, 1, 17, lw - 7, 1, function(self)
        self:fill(1, 1, lw - 7, 1, C.page)
        local c = clientEnv.fromGate()
        local s = c and c.status
        if not s then return end
        local text, fraction = energy(s)
        local x = 1
        if fraction then self:bar(1, 1, 7, fraction, C.amber, C.page) x = 9 end
        self:text(x, 1, ui.pad(text, lw - 7 - x), C.text, C.page)
    end)
    ui.Button(frame, lw - 5, 17, 6, 1, "IRIS", C.blue, C.black, function() say(iris(clientEnv.fromGate())) end, {around = C.page})

    -- One touch to claim the gate picked in range when it is unregistered and it is plain which
    -- network it joins: the profile in use, or the only one, on the gate's port. The gate takes
    -- that profile's settings (silent, who may use each control) and joins its gates.
    local function mainProfile(c)
        if not c or c.registered or c.public then return nil end
        local p, profiles = clientEnv.profile(), clientEnv.vault.state.profiles or {}
        if p and p.port == c.port then return p end
        if #profiles == 1 and profiles[1].port == c.port then return profiles[1] end
    end
    -- A gate this device owns or administers and the profile it is in (the one in use, else its
    -- only one): the gate console commands that give it the profile's settings, when it differs.
    local SAID = {anyone = "anyone", user = "users", admin = "admins", owner = "owner"}
    local function profileChanges(c)
        if not (c and c.allow and isAdmin(c)) then return nil end
        local entry = clientEnv.findEntry(c.name)
        local member = entry and entry.Profiles
        if not member then return nil end
        local p = clientEnv.profile()
        if not (p and member[p.name]) then
            p = nil
            for _, q in ipairs(clientEnv.vault.state.profiles or {}) do
                if member[q.name] then
                    if p then return nil end -- in more than one: which one is the player's to say
                    p = q
                end
            end
        end
        if not p then return nil end
        local lines = {}
        if (c.silent == true) ~= (p.silent == true) then lines[1] = p.silent and "silent on" or "silent off" end
        for _, k in ipairs({"dial", "close", "iris"}) do
            local want = p.allow and p.allow[k] or "user"
            if (c.allow[k] or "user") ~= want then lines[#lines + 1] = ("allow %s %s"):format(k, SAID[want]) end
        end
        if #lines > 0 then return p, lines end
    end
    -- One tap for the gate picked in range: SET UP an unregistered one with its profile, give
    -- one of this device's gates its profile's settings again, or SAVE the address just dialed by
    -- hand at its DHD (not in the book). Yellow text on the page, not a yellow bar: SCAN and the
    -- energy line are yellow right above and below it.
    local function oneTap(c)
        local p = mainProfile(c)
        if p then return ("▸ SET UP %s · %s"):format(c.name, p.name), function() say(part("admin").setup(c, p)) end end
        local q, lines = profileChanges(c)
        if q then return ("▸ APPLY %s to %s"):format(q.name, c.name), function() say(part("admin").apply(c, q, lines)) end end
        local hand = c and c.unsaved and c.status and c.status.handDialed
        if hand and hand.time == c.unsaved then
            return "▸ SAVE hand dial", function() say(part("handdial").save({})) end
        end
    end
    local tap = ui.Button(frame, 1, 18, lw, 1, function()
        local label = oneTap(clientEnv.fromGate())
        return ui.pad(label or "", lw - 2)
    end, C.page, C.amber, function()
        local _, act = oneTap(clientEnv.fromGate())
        if act then act() end
    end, {around = C.page})
    tap:visible(false)
    -- Shown and hidden from a blank cell beside it, which is drawn every frame.
    ui.Paint(frame, lw + 1, 18, 1, 1, function()
        local want = oneTap(clientEnv.fromGate()) ~= nil
        if tap:visible() ~= want then tap:visible(want) loom.invalidate() end
    end)

    -- What is happening, and the destination's address (each glyph's first three letters, amber
    -- as they engage), with GLYPHS (dial by touching glyphs) at the end of it.
    ui.Paint(frame, rx, 1, rw, 1, function(self)
        local _, detail, colour, lag = headline()
        self:text(1, 1, ui.pad(lag and (detail .. " · " .. lag) or detail, rw), colour, C.page)
        local at = lag and unicode.len(detail) + 4
        if at and at + unicode.len(lag) - 1 <= rw then self:text(at, 1, lag, C.red, C.page) end
    end)
    local aw = rw - 9
    ui.Paint(frame, rx, 2, aw, 1, function(self)
        self:fill(1, 1, aw, 1, C.page)
        local c = clientEnv.fromGate()
        local s = c and c.status
        local glyphs = (s and s.target and #s.target > 0 and (s.dialing or s.state == "open")) and s.target or plannedGlyphs(c, row())
        local state, _, _, engaged = gateLook()
        for i = 1, math.min(#glyphs, aw // 4) do
            local on = i <= engaged or state == "open" or state == "iris"
            local fg = on and C.amber or ((state == "dial" and i == engaged + 1) and C.text or C.faint)
            self:text((i - 1) * 4 + 1, 1, ui.pad(settings.showCodes and SHORT[glyphs[i]] or "·", 3), fg, C.page)
        end
    end)
    ui.Button(frame, rx + rw - 8, 2, 8, 1, "GLYPHS", C.raised, C.text, function() clientEnv.showGlyphs() end, {around = C.page})

    -- The log, and beside it the gate while the dialing gate dials, has a wormhole open, or its
    -- iris or shield moves or is shut; a moment after, the log takes the space again. No gate
    -- shows with none in range.
    local gateW = ui.brailleSize(15)
    local gate
    local lastBusy = -math.huge
    local function gateShown()
        local c = clientEnv.fromGate()
        local s = c and c.status
        if not s then return false end
        local now = computer.uptime()
        if gateLook() ~= "idle" or s.iris == "CLOSED" or s.iris == "CLOSING" or s.iris == "OPENING" then
            lastBusy = now
            return true
        end
        if now - lastBusy < 3 then loom.invalidate(3 - (now - lastBusy)) return true end
        gate:idle()
        return false
    end
    ui.Paint(frame, rx, 3, rw, 15, function(self)
        local shown = gateShown()
        gate:visible(shown)
        self:fill(1, 1, rw, 15, C.page)
        local x = shown and gateW + 3 or 1
        local w = rw - x + 1
        -- The newest lines, wrapped (keeping a command result's indent), the newest brightest;
        -- each line's time beside it while the log has the room.
        local timed = w >= 30
        local width = timed and w - 6 or w
        local a, rows = clientEnv.activity, {}
        local i = #a
        while i >= 1 and #rows < 15 do
            local indent, text = a[i].text:match("^(%s*)(.*)$")
            local lines = ui.wrap(text, width - #indent)
            for j = #lines, 1, -1 do
                table.insert(rows, 1, {j == 1 and a[i].time or "", indent .. lines[j], i == #a and C.text or C.dim})
            end
            i = i - 1
        end
        while #rows > 15 do table.remove(rows, 1) end
        for r, line in ipairs(rows) do
            self:text(x, r, (timed and ui.pad(line[1], 6) or "") .. ui.pad(line[2], width), line[3], C.page)
        end
    end)
    gate = ui.BrailleGate(frame, rx, 4, 15, gateLook, C.page, irisLook)
    gate:visible(false)

    -- The three big buttons, the same size; IRIS is the small one on the energy line.
    local bw = (R.w - 4) // 3
    local function at(n) return 1 + (n - 1) * (bw + 2) end
    ui.Button(frame, at(1), 19, bw, 3, "SCAN", C.amber, C.black, function() say(scan(false)) end, {around = C.page})
    ui.Button(frame, at(2), 19, bw, 3, dialLabel, C.green, C.black, function()
        say(dialWhenFree(clientEnv.fromGate(), row()))
    end, {around = C.page})
    ui.Button(frame, at(3), 19, R.w - at(3) + 1, 3, "DISENGAGE", C.red, C.black, function() say(disengage(clientEnv.fromGate())) end, {around = C.page})
end

-- The first time the client opens, wake the known gates and look for gates straight away.
if not dial.scanned then
    dial.scanned = true
    scan(false)
end

return {first = first}
