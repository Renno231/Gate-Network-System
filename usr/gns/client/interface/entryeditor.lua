
--[[
    entry address modification
        (left) a glyph set list for selecting a glyph to add (all glyphs of that type, change-able via dropdown)
        (right) a list on the right that contains the current glyphs of that type for the address
        selecting a glyph from the left-side glyph set list shows an "add" button
        selecting a glyph from the right-side list shows a up and down arrow with an X (delete) button
        clear button (clears right-side list)
        upon changes, a grayed out save and reset button become active (no longer grayed out, double click confirmation)
]]
local gns, clientEnv, selfPath, entry, confirmCallback, denyCallback = ...
checkArg(1, gns, 'table')
checkArg(2, clientEnv, 'table')

-- local database = clientEnv.database
-- local unicode = require"unicode"
-- local computer = require"computer"
local yawl = require("yawl-e")
-- local event = require"event"
local fs = require"filesystem"
local serialization = require"serialization"
local gui = yawl.widget
local keyboard = require"keyboard"

local mainWindow = clientEnv.mainWindow
mainWindow:enabled(false)
mainWindow:visible(false)
-- local currenttab = mainWindow:tab("Database")
local width, height = mainWindow:size() --, 7
local editorFrame = gui.ScrollFrame(clientEnv.root, math.floor(0.5 * (clientEnv.root:width() - width) + 1 ), math.floor(0.5 * (clientEnv.root:height() - height) + 0.5))
editorFrame:size(width, height) -- could do an animated approach
editorFrame:z(100)
editorFrame:maximumScrollY(25)
editorFrame:foregroundColor(0xaaaa00)
editorFrame:backgroundColor(0)
editorFrame:bordered(true)
editorFrame:borderSet(editorFrame.Borders.THINNER_EDGE_LINE)

local accept = gui.TextButton(editorFrame, math.floor(0.5*(width - 11)) - 6, editorFrame:height()-1, nil, 1, "[ SAVE ]", 0)
accept:backgroundColor(0x00ff00)

local reject = gui.TextButton(editorFrame, math.floor(0.5*(width - 9)) + 6, accept:y(), nil, 1, "[ CANCEL ]", 0)
reject:backgroundColor(0xff0000)

local GlyphsMW = {"Andromeda","Aquarius","Aries","Auriga","Bootes","Cancer","Canis Minor","Capricornus","Centaurus","Cetus","Corona Australis","Crater","Equuleus","Eridanus","Gemini","Hydra","Leo","Leo Minor","Libra","Lynx","Microscopium","Monoceros","Norma","Orion","Pegasus","Perseus","Pisces","Piscis Austrinus","Sagittarius","Scorpius","Sculptor","Scutum","Serpens Caput","Sextans","Taurus","Triangulum","Virgo"}
local GlyphsPG = {"Aaxel","Abrin","Acjesis","Aldeni","Alura","Amiwill","Arami","Avoniv","Baselai","Bydo","Ca Po","Danami","Dawnre","Ecrumig","Elenami","Gilltin","Hacemill","Hamlinto","Illume","Laylox","Lenchan","Olavii","Once El","Poco Re","Ramnon","Recktic","Robandus","Roehi","Salma","Sandovi","Setas","Sibbron","Tahnan","Zamilloz","Zeo"}
local GlyphsUN = {} for i = 1,36 do table.insert(GlyphsUN, string.format("Glyph %s", i)) end
local editedEntry = serialization.unserialize(serialization.serialize(entry))

local glyphList = gui.SortedList(editorFrame, accept:x()-(22-accept:width()), 5, 22, 15, 0)
glyphList:backgroundColor(0x333333)
glyphList:foregroundColor(0xffffff)
glyphList:maximumSelectedValues(1)
glyphList:list(GlyphsMW)
glyphList._debug = true

local entryGlyphs = gui.SortedList(editorFrame, glyphList:x()+glyphList:width()+5, glyphList:y(), 22, 15, 0)
entryGlyphs:backgroundColor(0x333333)
entryGlyphs:foregroundColor(0xffffff)
entryGlyphs:maximumSelectedValues(1)
entryGlyphs:list(editedEntry.Address.MW)
entryGlyphs:numbered(true)
entryGlyphs._debug = true

local glyphNameShort = {Milkyway = "MW", Pegasus = "PG", Universe = "UN"}
local glyphSetSelector = gui.DropdownList(editorFrame, accept:x()+3, glyphList:y()-3, 15 , 1, 0)
glyphSetSelector:animatedDrop(true)
glyphSetSelector:backgroundColor(0x333333)
glyphSetSelector:charSet("+-")
glyphSetSelector:listHeight(3)
glyphSetSelector:list():list{"Milkyway", "Pegasus", "Universe"}
glyphSetSelector:list():select(1, true)
glyphSetSelector:list():backgroundColor(0x333333)
glyphSetSelector:z(5)
glyphSetSelector:list():z(5)
glyphSetSelector:list()._debug = true

--gns.utility.strsplit()
local locationInfo = function(str, tbl) 
    tbl = tbl or entry
    return tbl.Location and string.format(str or "%s, %s, %s, %s", tbl.Location.dimension or "?", tbl.Location.x or "?", tbl.Location.y or "?", tbl.Location.z or "?") or ""
end
local coordinateInput = gui.TextInput(editorFrame, 1, accept:y()-2, locationInfo())
coordinateInput:size(25, 1)
coordinateInput:x(math.floor(0.5* (width - coordinateInput:width() - 10 )))
coordinateInput:backgroundColor(0x113355)
local addressGenerator = gui.TextButton(editorFrame, coordinateInput:x()+coordinateInput:width()+1, coordinateInput:y(), nil, 1, "[GENERATE]", 0)
addressGenerator:backgroundColor(0x00ff00)
local posInfo = gui.TextLabel(editorFrame, coordinateInput:x(), addressGenerator:y()-1, locationInfo("dim: %s (x: %s, y: %s, z: %s)"), 0xffffff)

local generatorAPI
addressGenerator:callback(function(self, _, eventName, uuid, x, y, button, playerName)
    if eventName == "touch" then
        local addressInfo = coordinateInput:text()
        local dim, x,y,z = table.unpack(gns.utility.strsplit(addressInfo,","))
        dim, x, y, z = tonumber(dim), tonumber(x),tonumber(y),tonumber(z)
        if (dim and x and y and z) then
            if not generatorAPI then
                local generatorPath = gns.path.gns .. "address.lua"
                if fs.exists(generatorPath) then
                    generatorAPI = dofile(generatorPath)
                end
            end
            if generatorAPI then
                local generatedAddress = generatorAPI.addressFromDimXYZ(dim, x, y, z)
                local glyphSet = glyphSetSelector:value()
                if glyphSet then
                    glyphSet = glyphNameShort[glyphSet]
                    editedEntry.Address = generatedAddress
                    entryGlyphs:list(editedEntry.Address[glyphSet])
                    entryGlyphs:clearSelection()
                end
                
            end
        end
        editedEntry.Location = {dimension = dim, x = x, y = y, z = z}
    end
end)

local __ = glyphSetSelector:list():callback()
glyphSetSelector:list():callback(function(self, _, eventName, uuid, x, y, button, playerName)
    local previousValue = glyphSetSelector:value()
    if __(self, _, eventName, uuid, x, y, button, playerName) then
        local glyphSet = glyphSetSelector:value()
        -- require"component".ocelot.log(string.format("%s %s", glyphSet, previousValue))
        if eventName == "touch" and glyphSet~=nil and glyphSet ~= previousValue then
            entryGlyphs:list(editedEntry.Address[glyphNameShort[glyphSet]] or {})
            glyphList:list((glyphSet == "Milkyway" and GlyphsMW) or (glyphSet == "Pegasus" and GlyphsPG) or GlyphsUN)
            entryGlyphs:clearSelection()
        end
    end
end)

local moveUpButton= gui.TextButton(editorFrame, entryGlyphs:x()-3, entryGlyphs:y()+2, nil, 1, "⬆", 0)
moveUpButton:foregroundColor(0xffffff)
moveUpButton:callback(function(self, _, eventName, uuid, x, y, button, playerName, down, increment)
    if eventName == "touch" then
        local selection = entryGlyphs:getSelection()[1]
        if selection and ((down == nil and (selection > 1)) or (down and (selection < #entryGlyphs:list()))) then
            local currentGlyph = entryGlyphs:value(selection)
            local newSelection = math.min(math.max(1, selection - (increment or 1)), #entryGlyphs:list())
            local newGlyph = entryGlyphs:value(newSelection)
            entryGlyphs:value(selection, newGlyph)
            entryGlyphs:value(newSelection, currentGlyph)
            entryGlyphs:select(selection, false)
            entryGlyphs:select(newSelection, true)
        end
        return true
    end
end)

local moveDownButton= gui.TextButton(editorFrame, moveUpButton:x(), moveUpButton:y()+2, nil, 1, "⬇", 0)
moveDownButton:foregroundColor(0xffffff)
moveDownButton:callback(function(self, _, eventName, uuid, x, y, button, playerName)
    if eventName == "touch" then
        return moveUpButton:callback()(self, 'nil', "touch", nil, nil, nil, nil, nil, true, -1)
    end
end)

local addGlyphButton= gui.TextButton(editorFrame, moveUpButton:x(), moveDownButton:y()+2, nil, 1, "▶", 0)
addGlyphButton:foregroundColor(0xffffff)
addGlyphButton:callback(function(self, _, eventName, uuid, x, y, button, playerName)
    if eventName == "touch" then
        local toAddIndex = glyphList:getSelection()[1]
        local glyphSet = glyphSetSelector:value()
        if toAddIndex and glyphSet then
            local currentAddress = entryGlyphs:list()
            if #currentAddress >= 8 then return true end
            local toAddGlyph = glyphList:value(toAddIndex)
            local duplicate = false
            for i, glyph in ipairs (currentAddress) do
                if glyph == toAddGlyph then
                    duplicate = true
                    break
                end
            end
            if not duplicate then
                local insertionIndex = entryGlyphs:getSelection()[1] or #currentAddress+1
                table.insert(currentAddress, insertionIndex, toAddGlyph)
            end
        end
        return true
    end
end)

local delGlyphButton= gui.TextButton(editorFrame, moveUpButton:x(), addGlyphButton:y()+1, nil, 1, "◀", 0)
delGlyphButton:foregroundColor(0xffffff)
delGlyphButton:callback(function(self, _, eventName, uuid, x, y, button, playerName)
    if eventName == "touch" then
        local toRemoveIndex = entryGlyphs:getSelection()[1] or #entryGlyphs:list()
        if toRemoveIndex > 0 then
            table.remove(entryGlyphs:list(), toRemoveIndex)
            if toRemoveIndex > #entryGlyphs:list() then
                entryGlyphs:select(toRemoveIndex, false)
                if #entryGlyphs:list() > 0 then
                    entryGlyphs:select(toRemoveIndex-1, true)
                end
            end
        end
        return true
    end
end)

local resetAddressButton = gui.TextButton(editorFrame, entryGlyphs:x()+6, entryGlyphs:y()-1, nil, 1, "[RESET]", 0)
-- resetAddressButton:foregroundColor(0xffffff)
resetAddressButton:backgroundColor(0x00aa00)
resetAddressButton:callback(function(self, _, eventName, uuid, x, y, button, playerName)
    if eventName == "touch" then
        local glyphSet = glyphSetSelector:value()
        if glyphSet then
            glyphSet = glyphNameShort[glyphSet]
            editedEntry.Address[glyphSet] = serialization.unserialize(serialization.serialize(entry.Address[glyphSet]))
            entryGlyphs:list(editedEntry.Address[glyphSet])
            entryGlyphs:clearSelection()
        end
        return true
    end
end)

local clearAddressButton = gui.TextButton(editorFrame, resetAddressButton:x()+resetAddressButton:width()+1, resetAddressButton:y(), nil, 1, "[CLEAR]", 0)
clearAddressButton:backgroundColor(0xff0000)
clearAddressButton:callback(function(self, _, eventName, uuid, x, y, button, playerName)
    if eventName == "touch" then
        local glyphSet = glyphSetSelector:value()
        if glyphSet then
            glyphSet = glyphNameShort[glyphSet]
            editedEntry.Address[glyphSet] = {}
            entryGlyphs:list(editedEntry.Address[glyphSet])
            entryGlyphs:clearSelection()
        end
        return true
    end
end)

local closePrompt = function(callback)
    if callback then
        local succ, err = pcall(callback, editedEntry)
        -- if not succ then clientEnv.bottomText:text(err:sub(15)) end
    end 
    clientEnv.closeInterface("entryeditor")
    mainWindow:enabled(true)
    mainWindow:visible(true)
end

accept:callback(function(self, _, eventName, uuid, x, y, button, playerName)
    if eventName == "touch" then
        closePrompt(confirmCallback)
        return true
    end
end)

reject:callback(function(self, _, eventName, uuid, x, y, button, playerName)
    if eventName == "touch" then
        closePrompt(denyCallback)
        return true
    end
end)

clientEnv.bottomText:text(selfPath)

return editorFrame