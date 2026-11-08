-- Dial screen: finds the gates in range (disco), opens them (gate.open), pulls their signed
-- address books and dials. The stargate is drawn from the dialing gate's own status. Widget
-- callbacks cannot wait, so every network step continues in a callback.
--
-- Commands: d / dial, close / x, iris / i, scan, from / f, ssh.
local gns, clientEnv, _, frame, R = ...
local ui = clientEnv.ui
local C = ui.C
local loom = require("loom")
local computer = require("computer")
local unicode = require("unicode")
local api = require("api")
local disco = require("disco")
local event = require("event")
local handshake = dofile(gns.path.gns .. "handshake.lua")
local entries = dofile(gns.path.gns .. "entries.lua")
local dialing = dofile(gns.path.gns .. "dialing.lua")
local fingerprint = dofile(gns.path.gns .. "vault.lua").fingerprint

local database = clientEnv.database
local vaultState = clientEnv.vault.state
local identity = vaultState.identity
local connections = clientEnv.gateconnections
local log = clientEnv.log
local wide = R.wide
local GALAXY = {MW = "Milky Way", PG = "Pegasus", UN = "Universe"}

-- State kept across layout changes (the screen is built again, clientEnv stays).
local dial = clientEnv.dialState or {busy = false, sinceScan = 0}
clientEnv.dialState = dial

local function guard(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            log("Error: " .. tostring(err))
            dial.busy = false
        end
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
            return
        end
    end
    database[#database + 1] = {key = e.key, Name = e.name, Type = e.type, Address = address, IDCs = {},
        Location = e.dim and {dimension = e.dim} or nil}
end

-- Opens the gate at address: public first, then with each private network membership held.
-- Calls callback(connection), or callback(nil, reason).
local function openGate(address, callback)
    api.connectAsync(handshake.ENDPOINT, handshake.PORT, address, guard(function(proxy, err)
        if not proxy then return callback(nil, err) end
        local function finish(reply, reason, net)
            if not reply then
                proxy:close()
                return callback(nil, reason)
            end
            callback({proxy = proxy, address = address, key = reply.key, net = net, status = reply.status,
                name = reply.status and reply.status.name or address:sub(1, 8)})
        end
        local nets = {}
        for _, net in pairs(vaultState.networks) do nets[#nets + 1] = net end
        local function try(i, reason)
            local net = nets[i]
            if not net then return finish(nil, reason) end
            handshake.openAsync(proxy, identity, vaultState.pins, net, guard(function(reply, why)
                if reply then return finish(reply, nil, net) end
                try(i + 1, why)
            end))
        end
        handshake.openAsync(proxy, identity, vaultState.pins, nil, guard(function(reply, reason)
            if reply or reason ~= "private gate" then return finish(reply, reason) end
            try(1, reason)
        end))
    end), nil, 3)
end

-- Pulls the gate's address book into the vault. Calls callback(number of new entries).
local function pull(connection, callback)
    connection.proxy:async(guard(function(ok, list)
        if ok ~= true then
            log(connection.name .. ": address book refused: " .. tostring(list))
            return callback(0)
        end
        local taken, refused = entries.mergeAll(vaultState.book, list, connection.net and connection.net.network.id)
        for _, r in ipairs(refused) do log(connection.name .. ": refused entry " .. tostring(r[1] and r[1].name) .. ": " .. r[2]) end
        if clientEnv.settings.autoLogToDatabase then
            for _, e in pairs(vaultState.book) do record(e) end
        end
        local own = vaultState.book[connection.key]
        if own then connection.name = own.name end
        callback(taken)
    end)).entries()
end

local function findConnection(address)
    for i, connection in ipairs(connections) do
        if connection.address == address then return connection, i end
    end
end

local function byDistance(a, b) return (a.distance or math.huge) < (b.distance or math.huge) end

-- Finds gates on disco and opens the ones not yet open. quiet (the automatic rescan) reports
-- only when it opened a gate.
local function scan(quiet)
    if dial.busy then return "A scan is already running." end
    dial.busy, dial.sinceScan = true, 0
    if not quiet then log("Scanning for gates...") end
    disco.findAsync("gns", 2, guard(function(found)
        local waiting, opened, learned = 1, 0, 0
        local function done()
            waiting = waiting - 1
            if waiting > 0 then return end
            table.sort(connections, byDistance)
            dial.busy = false
            loom.invalidate()
            if quiet and opened == 0 then return end
            log(("Found %d gates, opened %d, %d new address book entries."):format(#found, opened, learned))
            local saved, err = clientEnv.vault:save()
            if not saved then log("Vault not saved: " .. tostring(err)) end
        end
        for _, host in ipairs(found) do
            local known = findConnection(host.address)
            if known then
                known.distance = host.distance
            else
                waiting = waiting + 1
                openGate(host.address, guard(function(connection, reason)
                    if not connection then
                        log(("%s: %s"):format(host.name, reason))
                        return done()
                    end
                    connection.distance = host.distance
                    pull(connection, guard(function(taken)
                        learned, opened = learned + taken, opened + 1
                        connections[#connections + 1] = connection
                        log(("Connected to %s (%s)."):format(connection.name, connection.net and "private" or "public"))
                        done()
                    end))
                end))
            end
        end
        done()
    end))
end
clientEnv.scan = scan

-- Closes every gate connection and scans again, so gates open with the memberships held now
-- (after joining a network, say).
function clientEnv.reconnect()
    for i = #connections, 1, -1 do
        pcall(connections[i].proxy.close, connections[i].proxy)
        connections[i] = nil
    end
    clientEnv.from = nil
    dial.busy = false
    scan(false)
end

local function closeConnection(connection)
    local _, index = findConnection(connection.address)
    if index then table.remove(connections, index) end
    if clientEnv.from == connection then clientEnv.from = nil end
    pcall(connection.proxy.close, connection.proxy)
    log("Closed " .. connection.name .. ".")
end

---------------------------------------------------------------------------- what to dial
local function row() -- the destination row
    for _, r in ipairs(database) do if r == clientEnv.dest then return r end end
    clientEnv.dest = database[1]
    return clientEnv.dest
end
local function rowNumber(r)
    for i, x in ipairs(database) do if x == r then return i end end
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
-- The dialing gate's status, every two seconds (twice a second while it dials). While a dial
-- this client started is followed, each change of its dial state goes to the activity log.
local function poll(connection)
    if connection.polling then return end
    connection.polling = true
    connection.proxy:async(guard(function(ok, s)
        connection.polling = false
        if ok ~= true or type(s) ~= "table" then
            connection.lost = (connection.lost or 0) + 1
            if connection.lost >= 3 and not connection.reported then
                connection.reported = true
                log(connection.name .. " does not answer: " .. tostring(s))
            end
            return
        end
        connection.lost, connection.reported = 0, false
        connection.status = s
        local f = connection.follow
        if f then
            if s.lastDial ~= f.last then
                f.last = s.lastDial
                log(connection.name .. ": " .. tostring(f.last))
            end
            f.polls = f.polls + 1
            if (not s.dialing and not (f.idc and f.last == "open")) or f.polls > 240 then connection.follow = nil end
        end
        loom.invalidate()
    end)).status()
end
local ticks = 0
local statusTimer = event.timer(0.5, guard(function()
    ticks = ticks + 1
    local c = clientEnv.fromGate()
    if c and (c.follow or (c.status and c.status.dialing) or ticks % 4 == 0) then poll(c) end
    if ticks % 2 == 0 then
        local rate = tonumber(clientEnv.settings.nearbyScanRate) or 0
        dial.sinceScan = dial.sinceScan + 1
        if rate > 0 and dial.sinceScan >= rate then scan(true) end
    end
end), math.huge)
clientEnv.onClose[#clientEnv.onClose + 1] = function() event.cancel(statusTimer) end

---------------------------------------------------------------------------- actions
local function doDial(connection, r, idc)
    if not connection then return "No gate in range to dial from. SCAN looks for gates." end
    if not r then return "Choose a gate to dial." end
    if not idc then
        for _, code in pairs(r.IDCs or {}) do
            if math.tointeger(code) then idc = code break end
        end
    end
    clientEnv.from, clientEnv.dest = connection, r
    local opts = {fast = clientEnv.settings.fastDial ~= false, idc = idc}
    connection.proxy:async(guard(function(ok, result)
        if ok ~= true then
            log(connection.name .. ": dial refused: " .. tostring(result))
            return
        end
        log(("Dialing %s from %s: %d glyphs%s, %d RF, open for %d s%s."):format(r.Name, connection.name,
            result.glyphs, result.from > 1 and (" from glyph " .. result.from) or "", result.open,
            result.seconds, result.fast and ", DHD" or ""))
        connection.follow = {last = "dialing", polls = 0, idc = idc}
        poll(connection)
    end)).dial(r.Address, opts)
    return ("Dialing %s from %s%s..."):format(r.Name, connection.name, idc and (" with IDC " .. idc) or "")
end
local function disengage(connection)
    if not connection then return "No gate in range." end
    connection.proxy:async(guard(function(ok, result)
        log(connection.name .. (ok == true and (": " .. tostring(result)) or (": disengage refused: " .. tostring(result))))
        poll(connection)
    end)).closeWormhole()
end
local function iris(connection)
    if not connection then return "No gate in range." end
    connection.proxy:async(guard(function(ok, result)
        log(connection.name .. (ok == true and (": iris " .. tostring(result)) or (": iris refused: " .. tostring(result))))
        poll(connection)
    end)).iris()
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
        if text == "exit" or text == "quit" then close() return end
        out("gate> " .. text)
        remote(connection, text, out)
    end})
    ui.Button(box, w - 11, h - 1, 10, 1, "CLOSE", C.raised, C.text, close)
    ui.focusSoon(field)
end
local function say(message) if message then log(message) end end
local function isAdmin(connection)
    return connection and connection.net and clientEnv.roleOf(connection.net) == "admin"
end

---------------------------------------------------------------------------- commands
local function gateOrFrom(selector)
    if selector then return findGate(selector), true end
    return clientEnv.fromGate()
end
clientEnv.command({"dial", "d"}, "d [from] <to> [idc]: dial a gate (by number or name); with one gate, from the nearest gate in range; with none, the chosen ones", function(args)
    if #args == 0 then return doDial(clientEnv.fromGate(), row()) end
    if #args == 1 then
        local r = clientEnv.findEntry(args[1])
        if not r then return "No gate " .. args[1] .. " in the address book." end
        return doDial(nearest(r), r)
    end
    local from = findGate(args[1])
    if not from then return "No gate " .. args[1] .. " in range." end
    local r = clientEnv.findEntry(args[2])
    if not r then return "No gate " .. args[2] .. " in the address book." end
    return doDial(from, r, math.tointeger(tonumber(args[3])))
end)
clientEnv.command({"close", "x"}, "close [gate]: stop dialing or close the outgoing wormhole", function(args)
    local c, named = gateOrFrom(args[1])
    if named and not c then return "No gate " .. args[1] .. " in range." end
    return disengage(c)
end)
clientEnv.command({"iris", "i"}, "iris [gate]: open or close a gate's iris (moderators and admins)", function(args)
    local c, named = gateOrFrom(args[1])
    if named and not c then return "No gate " .. args[1] .. " in range." end
    return iris(c)
end)
clientEnv.command({"scan"}, "scan: look for gates in range", function() return scan(false) end)
clientEnv.command({"from", "f"}, "from [gate]: choose the gate to dial from; alone, list the gates in range", function(args)
    if not args[1] then
        if #connections == 0 then return "No gates in range." end
        local list = {}
        for _, c in ipairs(connections) do
            list[#list + 1] = c.name .. (c.distance and (" " .. math.floor(c.distance) .. " m") or "")
        end
        return "In range: " .. table.concat(list, ", ")
    end
    local c = findGate(args[1])
    if not c then return "No gate " .. args[1] .. " in range." end
    clientEnv.from = c
    poll(c)
    return "Dialing from " .. c.name .. "."
end)
clientEnv.command({"ssh", "console"}, "ssh [gate] [command]: a gate's console, for admins of its network; with a command, run just that", function(args)
    local c = args[1] and findGate(args[1])
    local rest = 2
    if not c then c, rest = clientEnv.fromGate(), 1 end
    if not c then return "No gate in range." end
    if not isAdmin(c) then return c.name .. ": the console needs the admin role in the gate's network." end
    if #args < rest then return console(c) end
    local line = table.concat(args, " ", rest)
    remote(c, line, function(text) log("  " .. c.name .. ": " .. text) end)
    return c.name .. "> " .. line
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
    return "READY", ("Ready · %s to %s, %d glyphs"):format(c.name, name, #plannedGlyphs(c, r)), C.dim
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
        local name = glyphs[i] == "Point of Origin" and "Origin" or glyphs[i]
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
    if c.net then return "[" .. clientEnv.roleOf(c.net) .. "] " .. (c.net.name or "private") end
    return "[public]"
end
local function cycle(step)
    if #connections == 0 then return end
    local at = 1
    for i, c in ipairs(connections) do if c == clientEnv.fromGate() then at = i end end
    clientEnv.from = connections[(at - 1 + step) % #connections + 1]
    poll(clientEnv.from)
end
local function fromName() local c = clientEnv.fromGate() return c and c.name or "no gate" end

-- The address book, searched by name, type or location.
local search = ""
local function bookItems()
    local list, want = {}, search:lower()
    for i, r in ipairs(database) do
        local hay = (tostring(r.Name) .. " " .. tostring(r.Type) .. " " .. (clientEnv.place(r) or "")):lower()
        if want == "" or hay:find(want, 1, true) then list[#list + 1] = {r = r, i = i} end
    end
    return list
end
local function bookList(x, y, w, h, columns)
    return ui.List(frame, x, y, w, h, {items = bookItems, empty = "No gates yet. SCAN learns the gates in range; Gates adds your own.",
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
        self:text(3, 3, ui.pad(("%s · %s%s"):format(galaxy, tostring(s.state), c.distance and (" · " .. math.floor(c.distance) .. " blocks away") or ""), rw - 4), C.dim, C.card)
        local text, fraction = energy(s)
        self:text(3, 4, "Energy", C.faint, C.card)
        if fraction then self:bar(11, 4, 32, fraction, C.amber, C.card) end
        self:text(fraction and 45 or 11, 4, text, C.text, C.card)
        self:text(3, 5, "Iris", C.faint, C.card)
        self:text(11, 5, tostring(s.iris), s.iris == "CLOSED" and C.red or C.green, C.card)
        self:text(23, 5, ("Server %.1f TPS"):format(tonumber(s.tps) or 0), C.dim, C.card)
    end)
    local left = ui.chooser(frame, rx + 1, 2, 26, fromName, function() cycle(-1) end, function() cycle(1) end)
    first = left
    ui.Button(frame, rx + 29, 2, 8, 1, "SCAN", C.amber, C.black, function() say(scan(false)) end)
    ui.Button(frame, rx + 39, 2, 8, 1, "CLOSE", C.raised, C.text, function()
        local c = clientEnv.fromGate()
        if c then closeConnection(c) end
    end)
    ui.Button(frame, rx + 49, 2, 10, 1, "CONSOLE", function() return isAdmin(clientEnv.fromGate()) and C.blue or C.raised end,
        function() return isAdmin(clientEnv.fromGate()) and C.black or C.faint end, function()
            local c = clientEnv.fromGate()
            if isAdmin(c) then console(c) else log("The console needs the admin role in the gate's network.") end
        end)

    ui.card(frame, rx, 7, rw, 8, "DESTINATION", function() local r = row() return r and ("[" .. tostring(r.Type or "MW") .. "]") end, function(self)
        local r = row()
        if not r then self:text(3, 3, "No gates in the address book yet.", C.faint, C.card) return end
        self:text(3, 2, r.Name, C.amber, C.card)
        local place = (GALAXY[r.Type] or tostring(r.Type or "")) .. (clientEnv.place(r) and (" · " .. clientEnv.place(r)) or "")
        self:text(5 + unicode.len(r.Name), 2, ui.pad(place, rw - 8 - unicode.len(r.Name)), C.dim, C.card)
        local codes = #(r.IDCs or {}) > 0 and ("IDC " .. table.concat(r.IDCs, ", ")) or "No IDC"
        local signed = r.key and vaultState.book[r.key] and ("signed by its gate, " .. fingerprint(r.key):sub(1, 13)) or "added by hand"
        self:text(3, 3, ui.pad(codes .. " · " .. signed, rw - 4), C.faint, C.card)
        -- Four to a row, each row's blocks sharing its width (so the last row's are wider).
        local glyphs = plannedGlyphs(clientEnv.fromGate(), r)
        for i, glyph in ipairs(glyphs) do
            local rowStart = (i - 1) // 4 * 4
            local n = math.min(4, #glyphs - rowStart)
            local bw = (rw - 4 - (n - 1)) // n
            self:block(3 + (i - 1 - rowStart) * (bw + 1), 5 + (i - 1) // 4 * 2, bw, glyph, C.raised, C.text)
        end
    end)
    ui.card(frame, rx, 16, rw, 13, "ADDRESS BOOK", function() return #database .. " gates" end)
    ui.Field(frame, rx + 1, 17, rw - 2, {placeholder = "⌕ search gates", changed = function(t) search = t end})
    bookList(rx, 18, rw, 11, function(item, _, w)
        local r = item.r
        return {{1, ui.pad(tostring(item.i), 3), C.faint}, {5, ui.pad(r.Name, 20)}, {26, tostring(r.Type or ""), C.dim},
            {30, ui.pad(clientEnv.place(r) or "", w - 40), C.faint}, {w - 8, #(r.IDCs or {}) > 0 and "[IDC]" or "", C.amber}}
    end)
    ui.Button(frame, rx, 30, rw, 3, dialLabel, C.green, C.black, function()
        local state = gateLook()
        if state == "idle" then say(doDial(clientEnv.fromGate(), row())) else log("The gate is busy; DISENGAGE first.") end
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
        local text, fraction = energy(s)
        if fraction then self:bar(3, 4, 8, fraction, C.amber, C.card) end
        self:text(fraction and 12 or 3, 4, ui.pad(text .. "  " .. fromNote(), rw - (fraction and 13 or 4)), C.text, C.card)
    end)
    ui.Button(frame, rx + rw - 13, 1, 6, 1, "SSH", function() return isAdmin(clientEnv.fromGate()) and C.blue or C.head end,
        function() return isAdmin(clientEnv.fromGate()) and C.black or C.faint end, function()
            local c = clientEnv.fromGate()
            if isAdmin(c) then console(c) else log("The console needs the admin role in the gate's network.") end
        end, {around = C.head})
    ui.Button(frame, rx + rw - 6, 1, 6, 1, "SCAN", C.amber, C.black, function() say(scan(false)) end, {around = C.head})
    first = ui.chooser(frame, rx + 1, 2, rw - 7, fromName, function() cycle(-1) end, function() cycle(1) end)
    ui.Button(frame, rx + rw - 4, 2, 3, 1, "✕", C.raised, C.red, function()
        local c = clientEnv.fromGate()
        if c then closeConnection(c) end
    end)
    ui.card(frame, rx, 6, rw, 8, "TO", function() return #database .. " gates" end)
    ui.Field(frame, rx + 1, 7, rw - 2, {placeholder = "⌕ search", changed = function(t) search = t end})
    bookList(rx, 8, rw, 6, function(item, _, w)
        local r = item.r
        return {{1, ui.pad(tostring(item.i), 3), C.faint}, {4, ui.pad(r.Name, w - 13)}, {w - 8, tostring(r.Type or ""), C.dim},
            {w - 4, #(r.IDCs or {}) > 0 and "IDC" or "", C.amber}}
    end)
    local third = R.w // 3
    ui.Button(frame, 1, 19, third, 3, dialLabel, C.green, C.black, function()
        local state = gateLook()
        if state == "idle" then say(doDial(clientEnv.fromGate(), row())) else log("The gate is busy; DISENGAGE first.") end
    end, {around = C.page})
    ui.Button(frame, third + 2, 19, third - 1, 3, "DISENGAGE", C.red, C.black, function() say(disengage(clientEnv.fromGate())) end, {around = C.page})
    ui.Button(frame, 2 * third + 2, 19, R.w - 2 * third - 2, 3, "IRIS", C.blue, C.black, function() say(iris(clientEnv.fromGate())) end, {around = C.page})
end

-- The first time the client opens, look for gates straight away.
if not dial.scanned then
    dial.scanned = true
    scan(true)
end

return {first = first}
