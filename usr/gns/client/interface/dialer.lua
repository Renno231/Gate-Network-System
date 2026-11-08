-- Dialing tab: find nearby gates (disco), open them (gate.open), pull their signed address books
-- and dial. Network work runs on threads, because widget callbacks cannot wait.
local gns, clientEnv, selfPath = ...
checkArg(1, gns, 'table')
local mainWindow = clientEnv.mainWindow
local database = clientEnv.database
local computer = require"computer"
local yawl = require("yawl-e")
local api = require("api")
local disco = require("disco")
local thread = require("thread")
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

-- Opens the gate at address: public first, then with each private network membership held.
-- Returns a connection, or nil and the reason.
local function openGate(address)
    local ok, proxy = pcall(api.connect, handshake.ENDPOINT, handshake.PORT, address, nil, 3)
    if not ok then return nil, tostring(proxy) end
    local reply, reason = handshake.open(proxy, identity, vaultState.pins)
    local net
    if not reply and reason == "private gate" then
        for _, membership in pairs(vaultState.networks) do
            reply, reason = handshake.open(proxy, identity, vaultState.pins, membership)
            if reply then net = membership break end
        end
    end
    if not reply then
        proxy:close()
        return nil, reason
    end
    return {proxy = proxy, address = address, key = reply.key, net = net, status = reply.status,
        name = address:sub(1, 8), lastActive = computer.uptime(), _log = {}}
end

-- Pulls the gate's address book into the vault. Returns how many entries were new.
local function pull(connection)
    local ok, list = connection.proxy.entries()
    if ok ~= true then
        log(connection, "Address book refused: " .. tostring(list))
        return 0
    end
    local taken, refused = entries.mergeAll(vaultState.book, list, connection.net and connection.net.network.id)
    for _, r in ipairs(refused) do log(connection, "Refused entry " .. tostring(r[1] and r[1].name) .. ": " .. r[2]) end
    if clientEnv.settings.autoLogToDatabase then
        for _, e in pairs(vaultState.book) do record(e) end
    end
    local own = vaultState.book[connection.key]
    if own then connection.name = own.name end
    return taken
end

local function findConnection(address)
    for i, connection in ipairs(gateConnections) do
        if connection.address == address then return connection, i end
    end
end

local busy = false
local function background(task)
    if busy then return end
    busy = true
    thread.create(function()
        local ok, err = pcall(task)
        if not ok then output:push("Error: " .. tostring(err)) end
        busy = false
    end)
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
    background(function()
        connection.lastActive = computer.uptime()
        local ok, result = connection.proxy.dial(destination.Address)
        if ok == true then
            log(connection, ("Dialing %s (%d glyphs)."):format(destination.Name, result))
        else
            log(connection, "Dial refused: " .. tostring(result))
        end
    end)
end)

local scanButton = gui.TextButton(currenttab, dialButton:x() + dialButton:width() + 2, dialButton:y(), nil, 1, "[ SCAN ]", 0)
scanButton:backgroundColor(0xffff00)
scanButton:callback(function(self, _, eventName, ...)
    if eventName ~= "touch" then return end
    background(function()
        output:push("Scanning for gates...")
        local found, opened, learned = disco.find("gns", 2), 0, 0
        for _, host in ipairs(found) do
            if not findConnection(host.address) then
                local connection, reason = openGate(host.address)
                if connection then
                    learned = learned + pull(connection)
                    gateConnections[#gateConnections + 1] = connection
                    log(connection, ("Connected to %s (%s)."):format(connection.name, connection.net and "private" or "public"))
                    opened = opened + 1
                else
                    output:push(("%s: %s"):format(host.name, reason))
                end
            end
        end
        output:push(("Found %d gates, opened %d, %d new address book entries."):format(#found, opened, learned))
        local saved, err = clientEnv.vault:save()
        if not saved then output:push("Vault not saved: " .. tostring(err)) end
    end)
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
