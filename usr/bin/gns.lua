-- gns [--client] [--repeating]
-- Runs the GNS gate server on a computer with a stargate, otherwise the client.
local shell = require("shell")
local fs = require("filesystem")
local component = require("component")
local args, options = shell.parse(...)

local gnsPath = "/usr/gns/"
local serverPath, clientPath = gnsPath .. "server/server.lua", gnsPath .. "client/client.lua"
local runServer = component.isAvailable("stargate") and not options.client and fs.exists(serverPath)
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
        for i in pairs(package.loaded) do if i:match("yawl") then package.loaded[i] = nil end end
        package.loaded.ecc = nil
    end
end
