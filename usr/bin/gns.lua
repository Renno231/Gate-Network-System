-- gns                 run the gate server on a computer with a stargate, otherwise the client
-- gns client          run the client even where there is a stargate
-- gns passwd          change the client vault's password
-- gns autorun on|off  start gns when the computer boots (a line in /home/.shrc)
-- gns help            this list
-- --repeating reruns the program after it exits (for development).
local shell = require("shell")
local fs = require("filesystem")
local component = require("component")
local args, options = shell.parse(...)
local command = args[1]

local gnsPath = "/usr/gns/"
local serverPath, clientPath = gnsPath .. "server/server.lua", gnsPath .. "client/client.lua"

if command == "help" or (command and command ~= "client" and command ~= "passwd" and command ~= "autorun") then
    print("gns                 run the gate server (with a stargate) or the client")
    print("gns client          run the client")
    print("gns passwd          change the client vault's password")
    print("gns autorun on|off  start gns when the computer boots")
    return
end

if command == "autorun" then
    local rcPath, line = "/home/.shrc", "gns"
    local lines, present = {}, false
    local file = io.open(rcPath)
    if file then
        for l in file:lines() do
            if l == line then present = true else lines[#lines + 1] = l end
        end
        file:close()
    end
    if args[2] == "on" then lines[#lines + 1] = line elseif args[2] ~= "off" then
        print("gns autorun is " .. (present and "on" or "off") .. "; use gns autorun on|off")
        return
    end
    file = assert(io.open(rcPath, "w"))
    file:write(table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
    file:close()
    print("gns autorun " .. args[2])
    return
end

if command == "passwd" then
    local term = require("term")
    local vault = dofile(gnsPath .. "vault.lua")
    local vaultPath = gnsPath .. "client/vault"
    if not vault.exists(vaultPath) then print("No client vault yet: run gns first.") return end
    local function ask(prompt)
        io.write(prompt)
        local l = term.read(nil, nil, nil, "*")
        return l and (l:gsub("\n$", ""))
    end
    local opened, reason = vault.open(vaultPath, ask("Current password: ") or "")
    if not opened then print(reason) return end
    local password = ask("New password: ")
    if not password or password == "" or password ~= ask("Repeat password: ") then
        print("The passwords are empty or do not match; nothing changed.")
        return
    end
    print("Saving...")
    local ok, err = opened:changePassword(password)
    opened:lock()
    print(ok and "Password changed." or ("Not changed: " .. tostring(err)))
    return
end

local runServer = component.isAvailable("stargate") and not options.client and command ~= "client" and fs.exists(serverPath)
if not runServer and not fs.exists(clientPath) then
    error("Gate Network System client not found at " .. clientPath)
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
    if file == nil then return end
    file:close()
    local fileContents = {dofile(path)}
    return onReadCallback and onReadCallback(table.unpack(fileContents)) or table.unpack(fileContents)
end
local function writeFile(path, contents)
    local file = io.open(path, "w")
    if contents then
        if type(contents) == "function" then
            contents(file)
        else
            file:write(contents)
        end
    end
    file:close()
end

local environment = {
    path = {server = serverPath, serverDirectory = fs.path(serverPath), client = clientPath,
        clientDirectory = fs.path(clientPath), gns = gnsPath},
    utility = {readFile = readFile, writeFile = writeFile, strsplit = strsplit},
    isRepeating = options.repeating,
    clientActive = not runServer,
}

local runs = 1
while (environment.isRepeating == nil and runs == 1) or environment.isRepeating == true do
    loadfile(runServer and serverPath or clientPath)(environment)
    runs = runs + 1
    if environment.isRepeating then
        os.sleep(1)
        print("Re-running GNS... (" .. tostring(runs) .. ")")
        environment.clientActive = not runServer
        for i in pairs(package.loaded) do if i:match("^loom") then package.loaded[i] = nil end end
        package.loaded.ecc = nil
    end
end
