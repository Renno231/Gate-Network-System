local gns, clientEnv, selfPath = ...
checkArg(1, gns, 'table')
local mainWindow = clientEnv.mainWindow
local database = clientEnv.database
local unicode = require"unicode"
local computer = require"computer"
local yawl = require("yawl-e")
local event = require"event"
local serialization = require"serialization"
local gui = yawl.widget

local currenttab = mainWindow:tab("Dialing")
local nearbyList = gui.SortedList(currenttab, 3, 4, 25, 5, 0)
nearbyList:backgroundColor(0x333333)
nearbyList:foregroundColor(0xffffff)
nearbyList:maximumSelectedValues(1)
local gateConnections = clientEnv.gateconnections
nearbyList:list(gateConnections)
nearbyList:format(function(connection)
    return string.format("%s (%ss)", connection:label(), math.floor(computer.uptime() - connection.lastActive) )
end)

local yOffset = nearbyList:y()+nearbyList:height()+2

local databaseList = gui.SortedList(currenttab, nearbyList:x(), yOffset+2, nearbyList:width(), 9, 0)
databaseList:list(database)

-- local testinput = gui.TextInput(currenttab, 15, 25, "")
-- testinput:size(15,1)
-- testinput:backgroundColor(0x333333)
-- testinput:cursorBlinks(true)
-- testinput._debug = clientEnv.bottomText

local databaseListFormatStr = "%-1s | %+8s"
databaseList:backgroundColor(0x333333)
databaseList:foregroundColor(0xffffff)
databaseList:filter(function(filterValue, toFilter) return (toFilter.Name or toFilter):lower():match(filterValue) or table.concat(toFilter.Address.MW, " "):lower():match(filterValue) end)
databaseList:format(function(value)
    return string.format(databaseListFormatStr, value.Name, table.concat(value.Address.MW, ", ") )
end)
databaseList:maximumSelectedValues(1)
--make custom callback so only 1 is selectable (or modify SortedList.lua)

local output = gui.OutputQueue(currenttab, 32, 4, 45, 18, 0x333333)
output:pushPrefix(function(self, str)
    return "["..os.date("%H:%M", computer.uptime()).."] " .. str
end)
local defaultOutputTable = output:list()
output:push("Thank you for using Gate Network System by Renno231. If you have any issues, feel free to (thoroughly) report them on the GitHub respository. As for questions, please first refer to the Wiki tab below.")
-- output:numbered(true)
-- put button for detailed view
gui.TextLabel(currenttab, nearbyList:x(), nearbyList:y()-1, "▌Nearby Gates")
gui.TextLabel(currenttab, nearbyList:x(), yOffset,        "▌Database Gates")
local processLabel = gui.TextLabel(currenttab, output:x(), output:y()-1,     "▌Connection Feedback    Line Numbers: ")
local linesButton = gui.ToggleSwitch(currenttab, processLabel:x()+processLabel:width() + 1, output:y()-1, 3, 1)
linesButton:speed(3)
linesButton:callback(function(self, _, eventName, ...) 
    if eventName=="touch" then 
        output:numbered(not self:toggle())
    end 
end)

nearbyList:callback(function(self, _, eventName, ...)
    local previousSelection = self:getSelection()[1]
    local prevConnection = previousSelection and self:value(previousSelection)
    if prevConnection and prevConnection._optionFrame then
        prevConnection._optionFrame:visible(false)
        prevConnection._optionFrame:enabled(false)
        if prevConnection._guiHeader then
            prevConnection._guiHeader:visible(false)
        end
        output:height(18)
    end
    self:defaultCallback(_, eventName, ...)
    local selection = self:getSelection()[1]
    -- clientEnv.bottomText:text(#selection, selection[1])
    local connection = selection and self:value(selection)
    output:list(connection and connection._log or defaultOutputTable)
    if connection and connection._optionFrame then
        connection._optionFrame:visible(true)
        connection._optionFrame:enabled(true)
        if connection._guiHeader then
            prevConnection._guiHeader:visible(true)
            output:height(12)
        end
    end
end)

-- not quite ready for this
-- nearbyList:format(function(value)
--     return string.format(databaseListFormatStr, value.Name, table.concat(value.Address.MW, ", ") )
-- end)

local connectionLog = function(self, value)
    local prev = output:list()
    output:list(self._log)
    output:push(value)
    output:list(prev)
end

local function setupConnection(connection)
    connection:log("Connection established.")
    connection:looping(true):next(function(self, packet)
        if packet.payload.data then 
            self:log(packet.payload.data)
            clientEnv.bottomText:text(#self._log, packet.payload.data)
        end
    end)
    
    local controlFrame = connection._optionFrame
    local selection = nearbyList:getSelection()[1]
    local isSelected = selection and nearbyList:value(selection)
    output:height(not isSelected and 18 or 12)
    if not isSelected then
        controlFrame:visible(false)
        controlFrame:enabled(false)
    end
    -- controlFrame:weld(output, 0, function() return output:height()+1 end)
    -- local line = (unicode.charAt(controlFrame.Borders.THINNER_EDGE_LINE, 5)):rep(controlFrame:width())

    controlFrame:y(output:y() + 13)
    -- gui.TextLabel(controlFrame, 1, 1, line, 0)
    connection._guiHeader = gui.TextLabel(currenttab, controlFrame:x(), controlFrame:y()-1, "▌CONNECTION CONTROL PANEL")
    connection._guiHeader:weld(controlFrame, 0, -1)
    controlFrame:height(5)
    
    --[[
    idea for how this could work
    controls:
        Terminate Connection (button)
        Block Connection (button)
        Import DHD (must be close to the server and have no outgoing wormhole)
        Toggle Iris (requires an IDC to be visible)
        Send IDC (buttton, with a dropdown with a list of IDCs from the address)
        Request Address
        Dial Time (slider, determines the dial duration in seconds, min 0 max 300)
        Check Status (button)
            requests gate-status, energy, max energy, iris state, iris durability, opened time, JSG version, gate type                                                                                
    ]]
end

clientEnv.gatenetConnectionListener = event.listen("gatenet_connection", function(_, receiver, sender, port, distance, packet, handshakeValidated)
    local succ, err = pcall(function() 
    local generator = clientEnv.gatenetstack.generateConnection(sender, port, packet)
    if handshakeValidated then
        local connection = generator()
        connection._log = {}
        connection.log = connectionLog
        table.insert(gateConnections, connection)
        local optionFrame = gui.Frame(currenttab, output:x(), output:y()+output:height())
        optionFrame:size(output:width(), 1)
        optionFrame:backgroundColor(output:backgroundColor())
        optionFrame:visible(false)
        optionFrame:enabled(false)
        connection._optionFrame = optionFrame
        if clientEnv.settings.autoAcceptNewServers then
            setupConnection(connection) -- modifies the connection for actual use and integration into the UI
        else
            connection:log("Connection pending...")
            
            local acceptor = gui.TextButton(optionFrame, 1, 1, nil, 1, "[ ACCEPT ]", 0)
            acceptor:backgroundColor(0x00ff00)
            acceptor:callback(function(self, _, eventName, ...) 
                if eventName=="touch" then 
                    optionFrame:clearChildren()
                    setupConnection(connection)
                end
            end)
            local reject = gui.TextButton(optionFrame, acceptor:width() + 2, 1, nil, 1, "[ REJECT ]", 0)
            reject:backgroundColor(0xff0000)
            local rejectionCB = function(self, _, eventName, ...) 
                if eventName=="touch" then 
                    connection:cancel(true)
                    nearbyList:select(nearbyList:getSelection()[1], false)
                    for i,v in ipairs (gateConnections) do
                        if v == connection then
                            table.remove(gateConnections, i)
                            break
                        end
                    end
                    optionFrame:clearChildren()
                    output:list(defaultOutputTable)
                end
            end
            reject:callback(rejectionCB)
            local block = gui.TextButton(optionFrame, reject:x() + reject:width() + 2, 1, nil, 1, "[ BLOCK ]", 0)
            block:backgroundColor(0xff0000)
            block:callback(function(self, _, eventName, ...) 
                if eventName=="touch" then 
                    rejectionCB(nil, nil, "touch")
                    clientEnv.gatenetstack.block(connection.destination)
                end
            end)

        end
        --[[would need to do some checking to make sure there are no duplicates and that its is actually a gate
            which begs the question, what makes a gate a "gate"? that it has addresses? But anyone get those addresses and spoof them to a client
            I suppose we cannot know for usre unless we do the enhanced security handshake which ensures both devices has the right information to identify and authenicate
            themselves to eachother, even then it's not guaranteed  since someone could tamper with a server
                one possible way around that is having the server calculate a checksum of its GNS files each time it runs 
                (and on server setup, it would relay this checksum to client that initiated the setup for comparison)
                so a secured client could know if a server has potentially been tampered with
                this is A LOT of extra work though
        ]]
        -- any new gate would have to be manually accepted by the player unless settings.autoAcceptNewServers
        -- if it doesn't contain an address at first and doesn't try to initiate any further security protocols, it's not a server
        -- servers at some point must provide a valid stargate address
    end
    end)
    if not succ then output:push(err) end
end)

local dialButton = gui.TextButton(currenttab, nearbyList:x(), nearbyList:y()+nearbyList:height(), nil, 1, "[DIAL]", 0)
dialButton:backgroundColor(0x00ff00)

local scanButton = gui.TextButton(currenttab, dialButton:x()+dialButton:width()+2, dialButton:y(), nil, 1, "[ SCAN ]", 0)
scanButton:backgroundColor(0xffff00)
scanButton:callback(function(self, _, eventName, ...) 
    if eventName=="touch" then 
        clientEnv.gatenetstack.initiateHandshake(1, "hello", 5)
        output:push("Initiated network handshake.")
        self:enabled(false)
        event.timer(1, function() if not gns.clientActive then return false end self:enabled(true) end)
    end 
end)

local closeButton = gui.TextButton(currenttab, scanButton:x()+scanButton:width()+2, scanButton:y(), nil, 1, "[CLOSE]", 0)
closeButton:backgroundColor(0xff0000)
-- make a scrolling frame undeer these buttons that when clicked it drops down with the rest of the command buttons
--[[
    ideas:
        could have toggle-button for showing detailed view of gateConnections that shows last-issued command how long it's been since then
            if done, should consider welding objects together and making a temporary text label that informs user how to scroll horizontally
        nearby gates is a list of simple connection objects that store a promise from gatenet and an internal feedback log
                { connection = gatenet_promise, _log = {table of feedback}, log = func() which inserts into _log  }
                note: to get proper line wrapping when calling log: temporarily set the output queue objects list to the connections _log table before push(value) and restore it back to the list it was before
            display of the process would be like "Gate 1: Dial Gate 2" (all commands to a server share the same "process" and the name changes as new commands of that connection are issued)
            on "Scan":

        buttons for controlling processes like:
            Terminate -- issues termination packet
            Log -- saves the whole contents of the current processes output queue
]]