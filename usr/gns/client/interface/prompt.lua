--[[
    special prompt with yes/no buttons with confirmCallback and denyCallback
    optional timeout can be passed
]]
local gns, clientEnv, selfPath, args = ... --t = ...
local message, confirmCallback, denyCallback, timeout = table.unpack(args or {})
checkArg(1, gns, 'table')
checkArg(2, clientEnv, 'table')
checkArg(6, timeout, 'number','nil')

-- local database = clientEnv.database
-- local unicode = require"unicode"
-- local computer = require"computer"
local yawl = require("yawl-e")
-- local event = require"event"
-- local serialization = require"serialization"
local gui = yawl.widget

local mainWindow = clientEnv.mainWindow
mainWindow:enabled(false)
-- local currenttab = mainWindow:tab("Database")
local width, height = 50, 7
local feedbackObject
local buttonYOffset = 2
local promptFrame = gui.ScrollFrame(clientEnv.root, math.floor(0.5 * (clientEnv.root:width() - width) ), math.floor(0.5 * (clientEnv.root:height() - height) ))
if args.textInput then
    height = 9
    feedbackObject = gui.TextInput(promptFrame, 1, 1, args.textInput.text or "")
    feedbackObject:size(args.textInput.width or 25, 1)
    feedbackObject:x(math.floor(0.5* (width - feedbackObject:width() )))
    feedbackObject:backgroundColor(0x009900)
elseif args.dropdown then
    height = 11
    feedbackObject = gui.DropdownList(promptFrame, 1, 2, args.dropdown.width or 15 , 1, 0)
    feedbackObject:backgroundColor(0x333333)
    feedbackObject:list():backgroundColor(0x333333)
    feedbackObject:animatedDrop(true)
    feedbackObject:charSet("+-")
    feedbackObject:listHeight(args.dropdown.height or 3)
    feedbackObject:list():list(args.dropdown.list) --._list = {"Milkyway", "Pegasus", "Universe"}
    feedbackObject:x(math.floor(0.5* (width - feedbackObject:width() )))
    feedbackObject:list():z(5)
    buttonYOffset = 4
    if args.dropdown.index then
        feedbackObject:list():select(args.dropdown.index, true)
    end
end
promptFrame:size(width, height)
promptFrame:z(100)
promptFrame:foregroundColor(0xaaaa00)
promptFrame:backgroundColor(0)
promptFrame:bordered(true)
promptFrame:borderSet(promptFrame.Borders.THINNER_EDGE_LINE)

message = message or "Are you sure you want to continue?"
local messageLabel = gui.TextLabel(promptFrame, math.floor(0.5* (promptFrame:width() - require"unicode".len(message) )), 3, message)
if feedbackObject then feedbackObject:y(messageLabel:y()+2) end
local accept = gui.TextButton(promptFrame, math.floor(0.5*(width - 11)) - 6, (feedbackObject or messageLabel):y()+buttonYOffset, nil, 1, "[ CONFIRM ]", 0)
accept:backgroundColor(0xff0000)

local reject = gui.TextButton(promptFrame, math.floor(0.5*(width - 9)) + 6, accept:y(), nil, 1, "[ CANCEL ]", 0)
reject:backgroundColor(0x00ff00)

local closePrompt = function(callback)
    if callback then
        local feedbackvalue
        if args.textInput then
            feedbackvalue = feedbackObject:text()
        elseif args.dropdown then
            feedbackvalue = feedbackObject:value()
        end 
        local succ, err = pcall(callback, feedbackvalue)
        -- if not succ then clientEnv.bottomText:text(err:sub(15)) end
    end 
    clientEnv.closeInterface("prompt")
    mainWindow:enabled(true)
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

return promptFrame