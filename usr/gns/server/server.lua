-- GNS gate server: serves this computer's stargate to GNS clients and gates, announces it on
-- disco, and gives the gate's owner a console. Started by /usr/bin/gns.
local gns = ...
if type(gns) ~= "table" or type(gns.path) ~= "table" or type(gns.utility) ~= "table" then
    error("Gate Network System environment not loaded")
end
local component = require("component")
local disco = require("disco")
local serialization = require("serialization")
local term = require("term")
local gate = dofile(gns.path.gns .. "gate.lua")
local handshake = dofile(gns.path.gns .. "handshake.lua")
local fingerprint = dofile(gns.path.gns .. "vault.lua").fingerprint

-- gns.stargate and gns.dhd: stand-ins for tests.
local stargate = gns.stargate or component.stargate
local dhd = gns.dhd or (component.isAvailable("dhd") and component.dhd or nil)

-- settings.lua: the gate's published name and dimension, kawoosh avoidance (on unless false)
-- and the IDCs that open the iris for incoming travellers ({[code] = name}).
local settingsPath = gns.path.serverDirectory .. "settings.lua"
local settings = gns.utility.readFile(settingsPath)
if type(settings) ~= "table" then
    local file = io.open("/etc/hostname")
    settings = {name = file and file:read("*l") or "Gate", dim = 0}
    if file then file:close() end
end
settings.idcs = type(settings.idcs) == "table" and settings.idcs or {}
if settings.kawoosh == nil then settings.kawoosh = true end
local function saveSettings()
    gns.utility.writeFile(settingsPath, "return " .. serialization.serialize(settings))
end
saveSettings()

local state = gate.load(gns.path.serverDirectory .. "state")
local node = gate.start(state, stargate, settings, dhd)
disco.offer("gns", handshake.PORT)

print(("GNS gate %s (%s)"):format(settings.name,
    state.net and ("private, founder " .. fingerprint(state.net.network.founder)) or "public"))
print("Modem " .. component.modem.address)
print("Device " .. fingerprint(state.identity.public))
print("Type help for commands.")

-- The console commands (console.lua); admins of the gate's network run the same ones remotely.
local run = dofile(gns.path.gns .. "console.lua").new(node, settings, saveSettings, dhd, stargate)
node.console = run
local commands = {} -- only at the gate computer itself
commands.help = function()
    run("help", print)
    print(("%-22s %s"):format("clear", "clear the screen"))
    print(("%-22s %s"):format("quit", "stop the gate"))
end
commands.clear = function() term.clear() end
for name, command in pairs(gns.commands or {}) do commands[name] = command end -- from test stand-ins

while true do
    io.write("gate> ")
    local line = io.read()
    if not line or line == "quit" then break end
    local name, argument = line:match("^%s*(%S+)%s*(.-)%s*$")
    local command = name and commands[name]
    if command then
        local ok, err = pcall(command, argument)
        if not ok then print("Error: " .. tostring(err)) end
    else
        run(line, print)
    end
end

disco.withdraw("gns")
node.stop()
print("GNS gate stopped.")
