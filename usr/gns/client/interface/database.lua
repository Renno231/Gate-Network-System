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

local currenttab = mainWindow:tab("Database")

local databaseList = gui.SortedList(currenttab, 3, 6, 25, 15, 0)
databaseList:backgroundColor(0x333333)
databaseList:foregroundColor(0xffffff)
databaseList:list(database)
databaseList:numbered(true)
databaseList:maximumSelectedValues(1)
databaseList:filter(function(filterValue, toFilter) return (toFilter.Name or toFilter):lower():match(filterValue) or table.concat(toFilter.Address.MW, " "):lower():match(filterValue) end)
databaseList:format(function(value) 
    local returnStr = "%-25s | %+8s"
    returnStr = string.format(returnStr, value.Name, table.concat(value.Address.MW, ", ") )
    return returnStr 
end)

local dbTabHeader = gui.TextLabel(currenttab, databaseList:x(), databaseList:y()-2, "▌DATABASE GATES", 0xffffff)--            ▌Editor & Info", 0xffffff)

-- databaseList:lockPropagationOnCallback(false)
local entryInfo = gui.ScrollFrame(currenttab, 30, 4) --gui.ScrollFrame(currenttab, 30, 5)
entryInfo:size(47 , 19)
local infoHeader = gui.TextLabel(currenttab, entryInfo:x(), entryInfo:y()-1, "▌INFORMATION", 0xffffff)--            ▌Editor & Info", 0xffffff)

-- entryInfo:size(45, 25)
entryInfo:backgroundColor(0x333333)
entryInfo:foregroundColor(0xffffff)
entryInfo:maximumScrollY(25)
entryInfo:minimumScrollY(0)

local newEntryButton = gui.TextButton(currenttab, databaseList:x()+1, databaseList:y()-1, nil, 1, "[ NEW ]", 0)
newEntryButton:backgroundColor(0x00ff00)
newEntryButton:callback(function(self, _, eventName, uuid, x, y, button, playerName)
    if eventName == "touch" then
        local newEntryIndex = databaseList:getSelection()[1]
        local newEntry = {UUID="",IDCs={},Address={MW={},UN={},PG={}},Name="Untitled",Type="MW"};
        if newEntryIndex then
            table.insert(database, newEntryIndex, newEntry)
        else
            table.insert(database, newEntry)
        end
    end
end)

local deleteEntryButton = gui.TextButton(currenttab, newEntryButton:x()+newEntryButton:width()+1, databaseList:y()-1, nil, 1, "[ DELETE ]", 0)
deleteEntryButton:backgroundColor(0xff0000)
deleteEntryButton:callback(function(self, _, eventName, uuid, x, y, button, playerName)
    if eventName == "touch" then
        local selection = databaseList:getSelection()[1]
        local entry = databaseList:value(selection)
        local msg = string.format("DELETE ENTRY %s?", entry.Name or "Untitled")
        clientEnv.loadInterface("prompt", {msg, 
        function()
            local newselection = databaseList._shown[selection - databaseList:absY() + 1 + (databaseList:bordered() and -1 or 0)]
            table.remove(database, selection)
            -- local succ, err = pcall(function() 
                databaseList:callback()(databaseList, nil, "touch", nil, 1, newselection or (self:absY() + selection), 0, "deleted the thing")
            -- end)
        end,} )
        return true
    end
end)

local moveUpButton = gui.TextButton(currenttab, deleteEntryButton:x()+deleteEntryButton:width()+2, databaseList:y()-1, nil, 1, "⬆", 0)
moveUpButton:foregroundColor(0xffffff)
moveUpButton:callback(function(self, _, eventName, uuid, x, y, button, playerName, down, increment)
    if eventName == "touch" then
        local selection = databaseList:getSelection()[1]
        if selection and ((down == nil and (selection > 1)) or (down and (selection < #databaseList:list()))) then
            local currentGlyph = databaseList:value(selection)
            local newSelection = math.min(math.max(1, selection - (increment or 1)), #databaseList:list())
            local newGlyph = databaseList:value(newSelection)
            databaseList:value(selection, newGlyph)
            databaseList:value(newSelection, currentGlyph)
            databaseList:select(selection, false)
            databaseList:select(newSelection, true)
        end
        return true
    end
end)

local moveDownButton = gui.TextButton(currenttab, moveUpButton:x()+moveUpButton:width()+1, databaseList:y()-1, nil, 1, "⬇", 0)
moveDownButton:foregroundColor(0xffffff)

moveDownButton:callback(function(self, _, eventName, uuid, x, y, button, playerName)
    if eventName == "touch" then
        return moveUpButton:callback()(self, 'nil', "touch", nil, nil, nil, nil, nil, true, -1)
    end
end)

-- local nameEditor = gui.TextButton(currenttab, infoHeader:x()+infoHeader:width()+2, infoHeader:y(), nil, 1, "[EDIT]", 0)
-- nameEditor:backgroundColor(0xaaaa00)
-- nameEditor:callback(function(self, _, eventName, uuid, x, y, button, playerName)
--     local selection = databaseList:getSelection()[1]
--     local entry = databaseList:value(selection)
--     if eventName == "touch" and entry then
--         clientEnv.loadInterface("entryeditor", entry)
--     end
-- end)


local optionalButtons = {deleteEntryButton, moveUpButton, moveDownButton}
local function optionalButtonState(value)
    if value == nil then return end
    for i,v in ipairs(optionalButtons) do v:enabled(value) v:visible(value) end
end
optionalButtonState(false)

local gatetypeName = {MW = "MILKYWAY", PG = "PEGASUS", UN = "UNIVERSE"}
local function generateInfo(entry)
    --[[
        put the buttons to edit HERE
        can modify prompt to work with text inputs too
            name: textinput
            network: dropdown (Default, ...)
            idc: textinput
            gate-type: dropdown (MW, PG, UN)
    ]]
    if entry == nil then return end
    local selection = databaseList:getSelection()[1]
    local entry = databaseList:value(selection)

    local nameHeader = gui.TextLabel(entryInfo, 2, 1, "Name: " .. entry.Name, 0xffffff)
    local nameEditor = gui.TextButton(entryInfo, unicode.len(nameHeader:text())+4, 1, nil, 1, "[EDIT]", 0)
    nameEditor:backgroundColor(0xaaaa00)
    nameEditor:callback(function(self, _, eventName, uuid, x, y, button, playerName)
        if eventName == "touch" and entry then
            clientEnv.loadInterface("prompt", {string.format("EDITING ENTRY %s NAME", entry.Name), 
            function(newName)
                entry.Name = newName
                nameHeader:text("Name: " .. entry.Name)
                self:x(unicode.len(nameHeader:text())+4)
            end, textInput = {width = 25, text = entry.Name}} ) --textInputWidth = 25, textInputText = entry.Name} )
        end
    end)

    local gateTypeHeader = gui.TextLabel(entryInfo, 2, 3, "Type: " .. gatetypeName[entry.Type] .. " ("..entry.Type..")", 0xffffff)
    local gateTypeEditor = gui.TextButton(entryInfo, unicode.len(gateTypeHeader:text())+4, gateTypeHeader:y(), nil, 1, "[EDIT]", 0)
    gateTypeEditor:backgroundColor(0xaaaa00)
    gateTypeEditor:callback(function(self, _, eventName, uuid, x, y, button, playerName)
        if eventName == "touch" and entry then
            clientEnv.loadInterface("prompt", {string.format("EDITING ENTRY %s TYPE", entry.Name), 
            function(newGateType)
                if newGateType == nil then return end
                entry.Type = newGateType
                gateTypeHeader:text("Type: " .. gatetypeName[entry.Type] .. " ("..entry.Type..")")
                self:x(unicode.len(gateTypeHeader:text())+4)
            end, dropdown = {list = {"MW","PG","UN"}, index = (entry.Type == "MW" and 1) or (entry.Type == "PG" and 2) or 3}} )
        end
    end)

    local addressInfoList = {}
    local addressHeader = gui.TextLabel(entryInfo, 2, 5, "GATE ADDRESS", 0xffffff)
    local gateAddressEditor = gui.TextButton(entryInfo, addressHeader:x()+unicode.len(addressHeader:text())+1, addressHeader:y(), nil, 1, "[EDIT]", 0)
    gateAddressEditor:backgroundColor(0xaaaa00)
    
    local function showAddress()
        for i,v in ipairs (addressInfoList) do
            v:Destroy(true)
            addressInfoList[i] = nil
        end
        local infox = 2
        for addressType, address in pairs (entry.Address) do
            if addressType == "MW" then infox = 2 elseif addressType == "PG" then infox = 22 else infox = 36 end 
            table.insert(addressInfoList, gui.TextLabel(entryInfo, infox, 7, "▌ "..gatetypeName[addressType], 0xffffff) )
            for glyphI, glyph in ipairs (address) do
                table.insert(addressInfoList, gui.TextLabel(entryInfo, infox, 7 + glyphI, string.format("%s %s", glyphI, glyph)) )
            end
            -- infox = infox + 16
        end
        -- local succ, err = pcall(function()
        entry.Location = entry.Location or {}
        local dim, x, y, z = entry.Location.dimension, entry.Location.x, entry.Location.y, entry.Location.z
            local positionInfo = string.format("dim: %s (x: %s, y: %s, z: %s)", dim or "?", x or "?", y or "?", z or "?")
            table.insert(addressInfoList, gui.TextLabel(entryInfo, 3, gateAddressEditor:y()+1, positionInfo))
        -- end)
        -- if not succ then require"component".ocelot.log(err) end
    end
    showAddress()
    gateAddressEditor:callback(function(self, _, eventName, uuid, x, y, button, playerName)
        if eventName == "touch" and entry then
            clientEnv.loadInterface("entryeditor", entry, function(editedEntry)
                --adjust the list of stuff below
                entry.Address = editedEntry.Address
                entry.Location = editedEntry.Location
                clientEnv.bottomText:text(entry.Location.dimension, entry.Location.x, entry.Location.y, entry.Location.z)
                showAddress()
            end)
        end
    end)
end

databaseList:callback(function(self, _, eventName, uuid, x, y, button, playerName)
    if eventName == "touch" then
        -- clientEnv.bottomText:text('huh', eventName,"|", uuid,".", x, y, button, playerName)
        local index = self._shown[y - self:absY() + 1 + (self:bordered() and -1 or 0)]
        if index == nil then 
            self:clearSelection()
            optionalButtonState(false)
            entryInfo:clearChildren()
            return true
        end
        -- require"component".ocelot.log(string.format("%s %s %s", index, x, y))
        local selection = self:getSelection()[1]
        local hasCleared = false
        if (selection and button == 1 and index == selection) or (selection and button == 0 and index ~= selection) or playerName == "deleted the thing" then
            hasCleared = true
            entryInfo:clearChildren()
            optionalButtonState(false)
        end
        if button == 0 then
            self:clearSelection()
        end
        if index then
            self:select(index, button == 0) 
            if button == 0 and (hasCleared or selection == nil ) then
                generateInfo(self:value(index))
                optionalButtonState(true)
            end
        end
        return true
    elseif eventName == "scroll" then
        if self:maximumSelectedValues() == 1 and require"keyboard".isControlDown() then
            local selected = self:getSelection()[1]
            if selected and self:value(selected-button)~=nil then
                self:select(selected, false)
                self:select(selected-button, true)
                entryInfo:clearChildren()
                generateInfo(self:value(selected-button))
            end
        end
        local oldScroll = self:scroll(-button)
        return oldScroll~=self:scroll()
    end
end)