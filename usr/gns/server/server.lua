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

local stargate = gns.stargate or component.stargate -- gns.stargate: a stand-in for tests

-- settings.lua: the gate's published name and dimension.
local settingsPath = gns.path.serverDirectory .. "settings.lua"
local settings = gns.utility.readFile(settingsPath)
if type(settings) ~= "table" then
    local file = io.open("/etc/hostname")
    settings = {name = file and file:read("*l") or "Gate", dim = 0}
    if file then file:close() end
end
gns.utility.writeFile(settingsPath, "return " .. serialization.serialize(settings))

local state = gate.load(gns.path.serverDirectory .. "state")
local node = gate.start(state, stargate, settings)
disco.offer("gns", handshake.PORT)

local function networkName()
    return state.net and ("private, founder " .. fingerprint(state.net.network.founder)) or "public"
end

print(("GNS gate %s (%s)"):format(settings.name, networkName()))
print("Modem " .. component.modem.address)
print("Device " .. fingerprint(state.identity.public))
print("Type help for commands.")

local commands = {}
commands.help = function()
    print("status              gate state and network")
    print("book                the gates in this gate's address book")
    print("sync <modem>        pull the address book (and network state) of another gate")
    print("trust <fingerprint> let this gate join the network founded by that key")
    print("clear               clear the screen")
    print("quit                stop the gate")
end
commands.status = function()
    local gateState = stargate.getGateStatus()
    print(("%s, %s, iris %s"):format(settings.name, gateState, tostring(stargate.getIrisState())))
    print("Network: " .. networkName())
    if state.trust then print("Trusts founder " .. state.trust) end
end
commands.book = function()
    local count = 0
    for _, e in pairs(state.book) do
        count = count + 1
        print(("%-16s %s seq %-3d %s%s"):format(e.name, e.type, e.seq, fingerprint(e.key), e.network and " (private)" or ""))
    end
    print(count .. " gates")
end
commands.sync = function(modem)
    local taken, refused = node.sync(modem)
    if not taken then
        print("Sync failed: " .. tostring(refused))
        return
    end
    print(("Synced from %s: %d new, %d refused"):format(modem:sub(1, 8), taken, #refused))
    for _, r in ipairs(refused) do print("Refused " .. tostring(r[1] and r[1].name) .. ": " .. r[2]) end
end
commands.trust = function(founder)
    if not founder:match("^GNS%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x$") then
        print("Usage: trust GNS-xxxx-xxxx-xxxx-xxxx")
        return
    end
    node.trust(founder)
    print("Trusting founder " .. founder)
end
commands.clear = function() term.clear() end

while true do
    io.write("gate> ")
    local line = io.read()
    if not line or line == "quit" then break end
    local name, argument = line:match("^%s*(%S+)%s*(%S*)")
    local command = name and commands[name]
    if command then
        local ok, err = pcall(command, argument)
        if not ok then print("Error: " .. tostring(err)) end
    elseif name then
        print("Unknown command " .. name .. "; type help.")
    end
end

disco.withdraw("gns")
node.endpoint:shutdown()
print("GNS gate stopped.")
