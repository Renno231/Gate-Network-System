local shell = require("shell")
local filesystem = require("filesystem")
local component = require("component")
local args, options = shell.parse(...)
local fs = require"filesystem"
local io = require"io"

local optionsCount, argsCount = 0,0
for _,_ in pairs (options) do optionsCount=optionsCount+1 end
for _,_ in pairs (args) do argsCount=argsCount+1 end
if options.repeating and options.forcerun == nil then options.forcerun = true end

if (optionsCount == 0 and argsCount == 0) or options.forcerun == true then
    local gnsPath = "/usr/gns/gatenet.lua"
    local function findFile(fileName, startDir)
        checkArg(1, fileName, "string")
        startDir = startDir or "/" -- Default start directory is root
        
        local dirsToVisit = startDir:find(":") and string.gmatch(startDir, "[^:]+") or {startDir}
        while #dirsToVisit > 0 do
            local currentDir = table.remove(dirsToVisit, 1) -- Get and remove the first element
            if fs.exists(fs.concat(currentDir, fileName)) then
                return fs.concat(currentDir, fileName)
            end
            for entry in fs.list(currentDir) do
                local fullPath = fs.concat(currentDir, entry)
                if fs.isDirectory(fullPath) then
                    table.insert(dirsToVisit, fullPath) -- Add directory to the list to visit
                else
                    -- Check if the file matches the fileName with any extension
                    if entry == fileName or entry:match("^" .. fileName .. "%..+$") then
                        return fullPath
                    end
                end
            end
        end
        
        return false, "file not found"
    end

    if not fs.exists(gnsPath) then
        gnsPath = findFile("gatenet.lua", "/usr")
        
        if not gnsPath then
            gnsPath = findFile("gatenet.lua") --more expensive search
            if not gnsPath then
                error("Gate Network System unable to locate critical networking files.")
            end
        end
    end
    local gatenet = dofile(gnsPath)
    if type(gatenet) ~= "table" then
        error("Gate Network System network stack 'gatenet' failed to load")
    end
    gnsPath = fs.path(gnsPath) -- loaded network stack, now convert to parent directory
    local serverPath, clientPath = gnsPath.."server/server.lua", gnsPath.."client/client.lua"
    local hasServer = fs.exists(serverPath)
    local hasClient = fs.exists(clientPath)
    if not (hasServer and hasClient) then
        error("Gate Network System unable to locate server or client.")
    end
    local function strsplit(inputstr, sep)
        local t={}
        for str in string.gmatch(inputstr, "([^"..(sep or "%s").."]+)") do
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
        checkArg(contents, "function", "string", "nil")
        local file = io.open(path, "w")
        --recordToOutput("settings file"..tostring(file))
        if contents then 
            if type(contents) == "function" then
                contents(file)
            else
                file:write(contents)
            end 
        end
        file:close()
    end
    
    local environment = {path = {server = serverPath, serverDirectory = fs.path(serverPath), client = clientPath, clientDirectory = fs.path(clientPath), gns = gnsPath},
                        hasServer = hasServer, hasClient = hasClient, 
                        utility = {findFile = findFile, readFile = readFile, writeFile = writeFile, strsplit = strsplit},
                        gatenet = gatenet,
                        isRepeating = options.repeating,
                        clientActive = hasClient,
                        serverActive = hasServer
                        }
    -- could build in options for automatic re-run since the environment table is shared
    -- could even do something like environment.clientActive so that the loop that keeps the client alive can be determined by this value
    -- could also have options like "gds --client" that skips running the server if there is one and vice versa
    local runs = 1
    
    while (environment.isRepeating == nil and runs == 1) or environment.isRepeating == true do
        local gnsStarted, gnsError = loadfile(hasServer and serverPath or clientPath)(environment) --pass through environment
        runs = runs + 1
        if environment.isRepeating then
            os.sleep(1)
            print("Re-running GNS... ("..tostring(runs)..")")
            if hasClient then 
                environment.clientActive = hasClient 
                for i,_ in pairs (package.loaded) do if i:match("yawl") then package.loaded[i] = nil end end
                package.loaded.ecc = nil
            end
        end
    end
end