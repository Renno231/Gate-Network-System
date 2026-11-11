-- GNS gate server: serves this computer's stargate to GNS clients, announces it on disco, and
-- gives the gate's owner and admins a console (or the gate room display). Started by
-- /usr/bin/gns. The gate itself runs on timers and listeners; only the console holds the
-- terminal. With gns.background it starts the gate and returns, so the client can run on the
-- same computer; run again, it opens the console on the running gate instead of starting another.
local gns = ...
if type(gns) ~= "table" or type(gns.path) ~= "table" or type(gns.utility) ~= "table" then
    error("Gate Network System environment not loaded")
end
local component = require("component")
local computer = require("computer")
local disco = require("disco")
local serialization = require("serialization")
local term = require("term")
local unicode = require("unicode")

-- package.loaded is the computer's, shared by every program on it: here.gate is the running
-- gate, here.client is set while the client runs (gns.lua).
local here = package.loaded["gns.here"] or {}
package.loaded["gns.here"] = here
if here.gate then
    if not gns.background then here.gate.console(false) end
    return
end

local gate = dofile(gns.path.gns .. "gate.lua")
local handshake = dofile(gns.path.gns .. "handshake.lua")
local fingerprint = dofile(gns.path.gns .. "vault.lua").fingerprint

-- gns.stargate and gns.dhd: stand-ins for tests.
local stargate = gns.stargate or component.stargate
local dhd = gns.dhd or (component.isAvailable("dhd") and component.dhd or nil)

-- settings.lua: the gate's published name and dimension, kawoosh avoidance (on unless false),
-- the IDCs that open the iris ({[code] = name}), port, public, sleep (idle minutes before it
-- shuts down; 0 never), alarm, redstoneWake, room (start in gate room mode) and localOnly (only
-- the client on this computer controls the gate).
local settingsPath = gns.path.serverDirectory .. "settings.lua"
local settings = gns.utility.readFile(settingsPath)
if type(settings) ~= "table" then
    local file = io.open("/etc/hostname")
    settings = {name = file and file:read("*l") or "Gate", dim = 0}
    if file then file:close() end
end
-- A signed entry's name has 1 to 32 bytes: a longer hostname is cut at a whole character.
if type(settings.name) ~= "string" or #settings.name == 0 then settings.name = "Gate" end
while #settings.name > 32 do settings.name = unicode.sub(settings.name, 1, -2) end
settings.idcs = type(settings.idcs) == "table" and settings.idcs or {}
if settings.kawoosh == nil then settings.kawoosh = true end
if settings.sleep == nil then settings.sleep = 5 end
-- Returns true, or nil and why (a full disk keeps the old file).
local function saveSettings()
    return gns.utility.writeFile(settingsPath, "return " .. serialization.serialize(settings))
end

-- owner.lua, from a floppy made with gns floppy --own: {owner, ownerName}. An unregistered gate
-- takes it once, as if that device had set it up, and makes its own wake key (the owner's device
-- gets it the first time it opens the gate).
local state = gate.load(gns.path.serverDirectory .. "state")
local ownerPath = gns.path.serverDirectory .. "owner.lua"
local given = gns.utility.readFile(ownerPath)
if type(given) == "table" and not state.owner and type(given.owner) == "string" and #given.owner == 22
    and type(given.ownerName) == "string" and #given.ownerName > 0 then
    state.owner, state.ownerName, state.wake = given.owner, given.ownerName, handshake.wakeKey()
    pcall(computer.addUser, given.ownerName)
    gate.save(state)
end
if given ~= nil then require("filesystem").remove(ownerPath) end
saveSettings()

local node = gate.start(state, stargate, settings, dhd)
disco.offer("gns", settings.port or handshake.PORT)

-- The console commands (console.lua); admins run the same ones remotely.
local run = dofile(gns.path.gns .. "console.lua").new(node, settings, saveSettings, dhd, stargate)
node.console = run
local room = dofile(gns.path.serverDirectory .. "room.lua")
local entry = {}
local function stop()
    if here.gate ~= entry then return end
    here.gate = nil
    disco.withdraw("gns")
    node.stop()
    print("GNS gate stopped.")
end
local owned -- the console was opened by the gns that started the gate: quit stops the gate
local commands = {} -- only at the gate computer itself
commands.help = function()
    run("help", print)
    print(("%-22s %s"):format("room [on|off]", "the gate room display; on: start in it"))
    print(("%-22s %s"):format("clear", "clear the screen"))
    print(("%-22s %s"):format("quit", owned and "stop the gate" or "leave the console; the gate runs on"))
    print(("%-22s %s"):format("stop", "stop the gate"))
end
commands.clear = function() term.clear() end
commands.room = function(argument)
    if argument == "on" or argument == "off" then
        settings.room = argument == "on"
        saveSettings()
        print("Gate room mode at start " .. argument)
        if argument == "off" then return end
    end
    room.run(node, settings)
end
for name, command in pairs(gns.commands or {}) do commands[name] = command end -- from test stand-ins

local function loop()
    if settings.room then room.run(node, settings) end
    while here.gate == entry do
        io.write("gate> ")
        local line = io.read()
        if not line or line == "quit" then
            if owned then stop() end
            return
        end
        local name, argument = line:match("^%s*(%S+)%s*(.-)%s*$")
        local command = name and commands[name]
        if name == "stop" then
            stop()
        elseif command then
            local ok, err = pcall(command, argument)
            if not ok then print("Error: " .. tostring(err)) end
        else
            run(line, print)
        end
    end
end

-- own: quit and Ctrl+Alt+C stop the gate (it was started with this console), or its timers and
-- endpoint would go on serving behind the shell. Otherwise they leave the console.
function entry.console(own)
    owned = own
    print(("GNS gate %s"):format(settings.name))
    print(state.owner and ("Owner %s (%s)%s"):format(tostring(state.ownerName), fingerprint(state.owner), settings.public and ", public" or "")
        or "Not registered: the first client to set it up becomes its owner.")
    print("Modem " .. component.modem.address .. ", port " .. (settings.port or handshake.PORT))
    print("Device " .. fingerprint(state.identity.public))
    print("Type help for commands.")
    local ok, err = pcall(loop)
    if own then stop() end
    if not ok and err ~= "interrupted" then error(err, 0) end
end
here.gate = entry

if gns.background then
    print(("GNS gate %s runs in the background; gns gate opens its console."):format(settings.name))
    return
end
entry.console(true)
