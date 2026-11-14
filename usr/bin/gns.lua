-- gns                 on a computer with a stargate and the client installed, start the gate
--                     server in the background (unless it runs already), then the client; with
--                     a stargate only the gate server, with its console; otherwise the client
-- gns gate            the gate server's console: on the running gate, else it starts the gate
-- gns client          run only the client, even where there is a stargate
-- gns passwd          change the client vault's password
-- gns autorun on|off  start gns when the computer boots (a line in /home/.shrc)
-- gns update          install the newest GNS from GitHub (needs an internet card)
-- gns uninstall       remove GNS, keeping the vault, settings and gate state for a reinstall;
--                     --all deletes those too. The loom and ecc libraries stay.
-- gns floppy DEST     write GNS and its libraries to DEST/gns.bundle (a floppy, say), for
--                     computers without an internet card: bundle unpack /mnt/xxx/gns.bundle
-- gns floppy DEST --os[=GROUP,...] [--skip=PATH,...] [--name=gate-%02d] [--first=N] [--auto=S] [--label=TEXT]
--                     make an installer floppy with QuickOS and GNS for empty computers (mkinstaller)
-- --gate              (with floppy) only the gate server: no client, no loom. A gate server's
--                     own install (install.lua gate) always makes these.
-- --own               (with floppy) gates installed from it are registered to this device: it
--                     asks for the vault password and the owner's player name; --silent too:
--                     they answer only the owner and players with access
-- --unregistered      (with floppy) the first client to set a gate up owns it. Without --own
--                     or --unregistered, gates installed from the floppy are public
-- gns help            this list
-- --repeating reruns the program after it exits (for development).
local shell = require("shell")
local fs = require("filesystem")
local component = require("component")
local args, options = shell.parse(...)
local command = args[1]

local gnsPath = "/usr/gns/"
local serverPath, clientPath = gnsPath .. "server/server.lua", gnsPath .. "client/client.lua"

-- Every command but gate and client (help, passwd, autorun, update, uninstall, floppy) is in
-- manage.lua, so a running gate or client keeps none of their code in memory.
if command and command ~= "gate" and command ~= "client" then
    return assert(loadfile(gnsPath .. "manage.lua"))(...)
end

local hasServer = component.isAvailable("stargate") and fs.exists(serverPath)
local hasClient = fs.exists(clientPath)
local runServer, runClient
if command == "gate" then
    runServer = hasServer
    if not runServer then error("gns gate runs the gate server: it needs a stargate and the gate server's files.") end
elseif command == "client" or options.client then
    runClient = hasClient
else
    runServer, runClient = hasServer, hasClient
end
if not runServer and not runClient then
    error(fs.exists(serverPath) and "This is a gate server's install (no client): it runs gns where there is a stargate."
        or "Gate Network System client not found at " .. clientPath)
end

local function strsplit(inputstr, sep)
    local t = {}
    for str in string.gmatch(inputstr, "([^" .. (sep or "%s") .. "]+)") do
        table.insert(t, str)
    end
    return t
end
local function readFile(path, onReadCallback)
    local file = io.open(path, "r")
    if file == nil then
        -- Cut off mid-replace: the new file was whole (vault.replace checks its size).
        if not fs.exists(path .. ".new") then return end
        fs.rename(path .. ".new", path)
    else
        file:close()
    end
    local fileContents = {dofile(path)}
    return onReadCallback and onReadCallback(table.unpack(fileContents)) or table.unpack(fileContents)
end
-- Settings hold a gate's IDCs and name: a full disk keeps the old file (vault.replace) rather
-- than leave a short one. Returns true, or nil and why.
local function writeFile(path, contents)
    return dofile(gnsPath .. "vault.lua").replace(path, contents or "")
end

local environment = {
    path = {server = serverPath, serverDirectory = fs.path(serverPath), client = clientPath,
        clientDirectory = fs.path(clientPath), gns = gnsPath},
    utility = {readFile = readFile, writeFile = writeFile, strsplit = strsplit},
    isRepeating = options.repeating,
    clientActive = runClient,
    -- The gate starts in the background when the client runs after it (server.lua).
    background = runServer and runClient,
}
-- server.lua's registry of what GNS runs on this computer (package.loaded is the computer's):
-- here.client, set by the client once unlocked, tells the gate a player is using it here.
local here = package.loaded["gns.here"] or {}
package.loaded["gns.here"] = here

local runs = 1
while (environment.isRepeating == nil and runs == 1) or environment.isRepeating == true do
    if runServer then assert(loadfile(serverPath))(environment) end
    if runClient then
        -- client.lua sets up and returns the session (nil when the vault stays locked).
        local ok, err = pcall(function()
            local session = assert(loadfile(clientPath))(environment)
            if session then session() end
        end)
        here.client = nil
        if not ok then error(err, 0) end
    end
    runs = runs + 1
    if environment.isRepeating then
        os.sleep(1)
        print("Re-running GNS... (" .. tostring(runs) .. ")")
        environment.clientActive = runClient
        for i in pairs(package.loaded) do if i:match("^loom") then package.loaded[i] = nil end end
        package.loaded.ecc = nil
    end
end
