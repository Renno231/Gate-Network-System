local gns = ... -- expects a table

if type(gns) == "table" then
    if type(gns.utility)~= "table" then
        error"Gate Network System utilities are missing"
    end
    if type(gns.path)~= "table" then
        error"Gate Network System path information is missing"
    end
    -- could do more checks
else
    error("Gate Network System environment not loaded")
end
local clientEnv = {loadedInterfaces = {}} --used for passing things through to interface scripts

local event = require"event"
event.listen("interrupted", function()
    gns.isRepeating = false
    gns.clientActive = false
    for i,_ in pairs (package.loaded) do if i:match("yawl") then package.loaded[i] = nil end end
    package.loaded.ecc = nil
    return false
end)

-- Unlock the vault (identity key and address book) before the GUI takes the screen.
-- The password is typed in the terminal because YAWL-E's TextInput cannot mask input.
local vault = dofile(require("filesystem").concat(gns.path.gns, "vault.lua"))
local function unlockVault()
    local fs, term = require("filesystem"), require("term")
    local vaultPath = fs.concat(gns.path.clientDirectory, "vault")
    local function ask(prompt)
        io.write(prompt)
        local line = term.read(nil, nil, nil, "*")
        return line and (line:gsub("\n$", ""))
    end
    if vault.exists(vaultPath) then
        for _ = 1, 3 do
            local password = ask("GNS password: ")
            if not password then return nil end
            print("Unlocking...")
            local opened, reason = vault.open(vaultPath, password)
            if opened then return opened end
            print(reason)
        end
        return nil
    end
    print("First run: choose a password for this device's GNS vault.")
    print("It protects this device's identity key and address book.")
    local password
    repeat
        password = ask("New password: ")
        if not password then return nil end
        local again = ask("Repeat password: ")
        if not again then return nil end
        if password == "" or password ~= again then
            print(password == "" and "The password cannot be empty." or "The passwords do not match.")
            password = nil
        end
    until password
    -- Move an existing plaintext address book into the vault.
    local plainPath = fs.concat(gns.path.clientDirectory, "database/current.lua")
    local database = gns.utility.readFile(plainPath)
    print("Creating vault...")
    local created, reason = vault.create(vaultPath, password, {database = type(database) == "table" and database or {}})
    if not created then
        print("Could not create the vault: " .. tostring(reason))
        return nil
    end
    if fs.exists(plainPath) then fs.remove(plainPath) end
    print("Device fingerprint: " .. created:fingerprint())
    return created
end
local clientVault = unlockVault()
if not clientVault then
    gns.isRepeating = false
    gns.clientActive = false
    print("GNS client locked.")
    return
end

local yawl = require("yawl-e")
local gui = yawl.widget
local term = require("term")
local os = require("os")
local io = require"io"
local computer = require("computer")
local serialization = require("serialization")
local unicode = require("unicode")
local component = require("component")
local keyboard = require('keyboard')
local fs = require"filesystem"
-- package.loaded.memory = nil
-- local memory = require("memory")
-- memory.setWidth(200)
local ecc = require("ecc") --105kb of memory used at max load
local gatenetstack = gns.gatenet.new()
clientEnv.gatenetstack = gatenetstack
clientEnv.gateconnections = {}
clientEnv.clientconnections = {}

component.gpu.freeAllBuffers()

local root = gui.Frame() -- basis of all UI elements
root:backgroundColor(0x000000) --0x333333)
clientEnv.root = root

-- important tables
local modem = component.modem
local readFile = gns.utility.readFile
local writeFile = gns.utility.writeFile

local database = clientVault.state.database
clientEnv.database = database
clientEnv.vault = clientVault

local settingsPath = gns.path.clientDirectory.."settings.lua"
local settings = { --add a read and save ability
    chatBlacklist = {}; --for blocking specific players
    autoAcceptSyncRequest = false;
    modemRange = 200;
    autoLogToDatabase = true; --for auto query
    nearbyScanRate = 10; -- in seconds, only relevant if the above is true
    outputBufferSize = 120; --need to add scrolling
    dialSpeed = 10;
    lastNearbyEntry = nil; --  ^ same 
    lastUser = nil;
    powerSaving = true;
}
clientEnv.settings = settings
-- strsplit moved to binfile and stored in gns env table

readFile(settingsPath, function(settingsOverride) 
    if type(settingsOverride) == "table" then
        for setting, value in pairs (settingsOverride) do
            if settings[setting]~=nil then
                if type(settings[setting]) == type(value) then
                    settings[setting] = value
                end
            end
        end
        settings.modemRange = math.min(math.max(tonumber(settings.modemRange) or 16, 16), 400)
        modem.setStrength(settings.modemRange)
    end
end)
writeFile(settingsPath, "return " .. serialization.serialize(settings, 100))

local bottomText = gui.TextLabel(root, 1, root:height(), " Press CTRL+C to exit." .. (gns.isRepeating and " Click the red button to reload." or "") .. " Device " .. clientVault:fingerprint(), 0xffffff)
bottomText:width(root:width())
bottomText:backgroundColor(0x333333)
bottomText:autoWidth(false)
clientEnv.bottomText = bottomText

local mainWindow = gui.Window(root, 1, 1, root:width() , root:height() -1)
mainWindow:backgroundColor(0)--0x777777)
mainWindow:foregroundColor(0xffffff)
mainWindow:bordered(true)
mainWindow:tabChars("▌▐")
mainWindow:borderSet(mainWindow.Borders.THINNER_EDGE_LINE)
mainWindow:openTab('Dialing', 2)
mainWindow:openTab('Database', 14)
mainWindow:openTab('Chat & Share', 27)
mainWindow:openTab("Settings", 2, 2)
mainWindow:openTab('Networks', 13, 2)
mainWindow:openTab('Wiki', 26, 2)
mainWindow:maximumScrollY(20)
clientEnv.mainWindow = mainWindow

if gns.isRepeating then
    local exitButton = gui.Button(root, root:width()-5, 2, 4, 2, 0xee0000)
    exitButton:foregroundColor(0x1ca152)
    exitButton:resetTime(0.05)
    exitButton:z(1000)
    exitButton:callback(function(self, _, eventName, uuid, x, y, button, playerName)
        exitButton:defaultCallback(_, eventName, uuid, x, y, button, playerName)
        if eventName=="touch" and button == 0 then
            gns.clientActive = false
        end 
    end)
end

local interfacePath = gns.path.clientDirectory.."interface/"
local interfaceByName = {
    Dialing = "dialer.lua",
    ['Chat & Share'] = "chat_share.lua",
    -- "backup.lua", -- (special)
    -- "encrypter.lua", -- (special)
    -- "serverterminal.lua" -- (special)
}

local function loadInterface(name, ...) -- ... = additional args
    local interfaceScriptPath = interfacePath..(interfaceByName[name] or (name:lower() .. ".lua")) 
    if fs.exists(interfaceScriptPath) and not clientEnv.loadedInterfaces[name] then
        -- bottomText:text("found interface at", interfaceScriptPath)
        local returned = loadfile(interfaceScriptPath) (gns, clientEnv, interfaceScriptPath, ...)
        if returned then 
            clientEnv.loadedInterfaces[name] = returned --could even have a onCloseCallback
        else
            clientEnv.loadedInterfaces[name] = true
        end
    else
        -- bottomText:text(fs.exists(interfaceScriptPath), interfaceScriptPath, not clientEnv.loadedInterfaces[interfaceScriptPath] )
    end
end
local function closeInterface(name) 
    if clientEnv.loadedInterfaces[name] then
        if type(clientEnv.loadedInterfaces[name]) == "table" and clientEnv.loadedInterfaces[name].Destroy then
            clientEnv.loadedInterfaces[name]:Destroy(true)
        end
        clientEnv.loadedInterfaces[name] = nil
    end
end

clientEnv.loadInterface = loadInterface
clientEnv.closeInterface = closeInterface

-- select a tab
mainWindow:selectTab("Database") -- "Dialing")
loadInterface(mainWindow:tab():name())
mainWindow:callback(function(self, _, eventName, uuid, x, y, button, playerName) 
    local previousTab = self:tab()
    self:defaultCallback(_, eventName, uuid, x, y, button, playerName)
    if eventName == "touch" and self:tab() and self:tab() ~= previousTab then
        loadInterface(self:tab():name())
    end
    return true -- important
end)

while gns.clientActive do
    -- memory.track()
    -- bottomText:text(string.format("%.0f kb out of %.0fkb", memory.poll()/1024, maxMemory))
    os.sleep()
    root:draw()
end

local saved, saveError = clientVault:save()
clientVault:lock()
term.clear()
print(saved and "Closed GNS client" or ("Closed GNS client, but the vault was not saved: " .. tostring(saveError)))

root:Destroy(true) --always call that on all Frame without a parent. This is used to unregister the event listeners for screen related events
component.gpu.freeAllBuffers()