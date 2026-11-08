-- Dialing tab: find nearby gates (disco), open them (gate.open), pull their signed address books
-- and dial. Widget callbacks cannot wait, so every network step continues in a callback.
local gns, clientEnv, selfPath = ...
checkArg(1, gns, 'table')
local mainWindow = clientEnv.mainWindow
local database = clientEnv.database
local computer = require"computer"
local yawl = require("yawl-e")
local api = require("api")
local disco = require("disco")
local event = require("event")
local handshake = dofile(gns.path.gns .. "handshake.lua")
local entries = dofile(gns.path.gns .. "entries.lua")
local gui = yawl.widget

local vaultState = clientEnv.vault.state
local identity = vaultState.identity

local currenttab = mainWindow:tab("Dialing")
local nearbyList = gui.SortedList(currenttab, 3, 4, 25, 5, 0)
nearbyList:backgroundColor(0x333333)
nearbyList:foregroundColor(0xffffff)
nearbyList:maximumSelectedValues(1)
local gateConnections = clientEnv.gateconnections
nearbyList:list(gateConnections)
nearbyList:format(function(connection)
    return string.format("%s (%ss)", connection.name, math.floor(computer.uptime() - connection.lastActive))
end)

local yOffset = nearbyList:y() + nearbyList:height() + 2

local databaseList = gui.SortedList(currenttab, nearbyList:x(), yOffset + 2, nearbyList:width(), 9, 0)
databaseList:list(database)
databaseList:backgroundColor(0x333333)
databaseList:foregroundColor(0xffffff)
databaseList:filter(function(filterValue, toFilter) return (toFilter.Name or toFilter):lower():match(filterValue) or table.concat(toFilter.Address.MW, " "):lower():match(filterValue) end)
databaseList:format(function(value)
    return string.format("%-1s | %+8s", value.Name, table.concat(value.Address.MW, ", "))
end)
databaseList:maximumSelectedValues(1)

local output = gui.OutputQueue(currenttab, 32, 4, 45, 18, 0x333333)
output:pushPrefix(function(self, str)
    return "[" .. os.date("%H:%M", computer.uptime()) .. "] " .. str
end)
local defaultOutputTable = output:list()
output:push("Thank you for using Gate Network System by Renno231. If you have any issues, feel free to (thoroughly) report them on the GitHub respository. As for questions, please first refer to the Wiki tab below.")
gui.TextLabel(currenttab, nearbyList:x(), nearbyList:y() - 1, "▌Nearby Gates")
gui.TextLabel(currenttab, nearbyList:x(), yOffset, "▌Database Gates")
local processLabel = gui.TextLabel(currenttab, output:x(), output:y() - 1, "▌Connection Feedback    Line Numbers: ")
local linesButton = gui.ToggleSwitch(currenttab, processLabel:x() + processLabel:width() + 1, output:y() - 1, 3, 1)
linesButton:speed(3)
linesButton:callback(function(self, _, eventName, ...)
    if eventName == "touch" then
        output:numbered(not self:toggle())
    end
end)

-- Each connection keeps its own feedback log; selecting it shows that log.
nearbyList:callback(function(self, _, eventName, ...)
    self:defaultCallback(_, eventName, ...)
    local selection = self:getSelection()[1]
    local connection = selection and self:value(selection)
    output:list(connection and connection._log or defaultOutputTable)
end)

local function log(connection, text)
    local previous = output:list()
    output:list(connection._log)
    output:push(text)
    output:list(previous)
end

local function selected(list)
    local selection = list:getSelection()[1]
    return selection and list:value(selection)
end

-- Adds or updates the database row for a signed gate entry (rows are matched by gate key).
local function record(e)
    local address = {MW = e.address.MW or {}, PG = e.address.PG or {}, UN = e.address.UN or {}}
    for _, row in ipairs(database) do
        if row.key == e.key then
            row.Name, row.Type, row.Address, row.retired = e.name, e.type, address, e.retired
            return
        end
    end
    database[#database + 1] = {key = e.key, Name = e.name, Type = e.type, Address = address}
end

-- Network work never waits: each step hands its result to a callback. guard reports a
-- callback's error in the feedback box instead of losing it in the event handler.
local busy = false -- a scan is running
local function guard(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            output:push("Error: " .. tostring(err))
            busy = false
        end
    end
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
                name = address:sub(1, 8), lastActive = computer.uptime(), _log = {}})
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
            log(connection, "Address book refused: " .. tostring(list))
            return callback(0)
        end
        local taken, refused = entries.mergeAll(vaultState.book, list, connection.net and connection.net.network.id)
        for _, r in ipairs(refused) do log(connection, "Refused entry " .. tostring(r[1] and r[1].name) .. ": " .. r[2]) end
        if clientEnv.settings.autoLogToDatabase then
            for _, e in pairs(vaultState.book) do record(e) end
        end
        local own = vaultState.book[connection.key]
        if own then connection.name = own.name end
        callback(taken)
    end)).entries()
end

local function findConnection(address)
    for i, connection in ipairs(gateConnections) do
        if connection.address == address then return connection, i end
    end
end

local dialButton = gui.TextButton(currenttab, nearbyList:x(), nearbyList:y() + nearbyList:height(), nil, 1, "[DIAL]", 0)
dialButton:backgroundColor(0x00ff00)
dialButton:callback(function(self, _, eventName, ...)
    if eventName ~= "touch" then return end
    local connection, destination = selected(nearbyList), selected(databaseList)
    if not connection or not destination then
        output:push("Select a nearby gate to dial from and a database gate to dial.")
        return
    end
    connection.lastActive = computer.uptime()
    -- A dial speed under 25 s presses the gate's DHD; the row's first IDC goes once open.
    local idc
    for _, code in pairs(destination.IDCs or {}) do
        if math.tointeger(code) then idc = code break end
    end
    local opts = {fast = (tonumber(clientEnv.settings.dialSpeed) or 25) < 25, idc = idc}
    connection.proxy:async(guard(function(ok, result)
        if ok ~= true then
            log(connection, "Dial refused: " .. tostring(result))
            return
        end
        log(connection, ("Dialing %s: %d glyphs%s, %d RF, open for %d s%s."):format(destination.Name,
            result.glyphs, result.from > 1 and (" from glyph " .. result.from) or "", result.open,
            result.seconds, result.fast and ", DHD" or ""))
        -- Follow the gate until the dial ends: report each change of its dial state.
        local last, polls = "dialing", 0
        local timer
        timer = event.timer(1, guard(function()
            polls = polls + 1
            connection.proxy:async(guard(function(got, status)
                if got ~= true then return end
                if status.lastDial ~= last then
                    last = status.lastDial
                    log(connection, "Gate: " .. tostring(last))
                end
                -- Done when the gate stops dialing, unless an IDC answer is still to come.
                local ended = not status.dialing and not (idc and last == "open")
                if ended or polls >= 60 then event.cancel(timer) end
            end)).status()
        end), math.huge)
    end)).dial(destination.Address, opts)
end)


-- Under the feedback box: stops the selected gate's dial or closes its outgoing wormhole.
local disengageButton = gui.TextButton(currenttab, output:x(), output:y() + output:height() + 1, nil, 1, "[DISENGAGE]", 0)
disengageButton:backgroundColor(0xff8800)
disengageButton:callback(function(self, _, eventName, ...)
    if eventName ~= "touch" then return end
    local connection = selected(nearbyList)
    if not connection then
        output:push("Select a nearby gate to disengage.")
        return
    end
    connection.lastActive = computer.uptime()
    connection.proxy:async(guard(function(ok, result)
        log(connection, ok == true and ("Disengage: " .. tostring(result)) or ("Disengage refused: " .. tostring(result)))
    end)).closeWormhole()
end)

local scanButton = gui.TextButton(currenttab, dialButton:x() + dialButton:width() + 2, dialButton:y(), nil, 1, "[ SCAN ]", 0)
scanButton:backgroundColor(0xffff00)
scanButton:callback(function(self, _, eventName, ...)
    if eventName ~= "touch" then return end
    if busy then return end
    busy = true
    output:push("Scanning for gates...")
    disco.findAsync("gns", 2, guard(function(found)
        local waiting, opened, learned = 1, 0, 0
        local function done()
            waiting = waiting - 1
            if waiting > 0 then return end
            output:push(("Found %d gates, opened %d, %d new address book entries."):format(#found, opened, learned))
            local saved, err = clientEnv.vault:save()
            if not saved then output:push("Vault not saved: " .. tostring(err)) end
            busy = false
        end
        for _, host in ipairs(found) do
            if not findConnection(host.address) then
                waiting = waiting + 1
                openGate(host.address, guard(function(connection, reason)
                    if not connection then
                        output:push(("%s: %s"):format(host.name, reason))
                        return done()
                    end
                    pull(connection, guard(function(taken)
                        learned, opened = learned + taken, opened + 1
                        gateConnections[#gateConnections + 1] = connection
                        log(connection, ("Connected to %s (%s)."):format(connection.name, connection.net and "private" or "public"))
                        done()
                    end))
                end))
            end
        end
        done()
    end))
end)

local closeButton = gui.TextButton(currenttab, scanButton:x() + scanButton:width() + 2, scanButton:y(), nil, 1, "[CLOSE]", 0)
closeButton:backgroundColor(0xff0000)
closeButton:callback(function(self, _, eventName, ...)
    if eventName ~= "touch" then return end
    local connection = selected(nearbyList)
    if not connection then return end
    local _, index = findConnection(connection.address)
    nearbyList:select(nearbyList:getSelection()[1], false)
    table.remove(gateConnections, index)
    pcall(connection.proxy.close, connection.proxy)
    output:list(defaultOutputTable)
    output:push("Closed " .. connection.name .. ".")
end)
