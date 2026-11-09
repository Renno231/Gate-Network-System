-- gns                 run the gate server on a computer with a stargate, otherwise the client
-- gns client          run the client even where there is a stargate
-- gns passwd          change the client vault's password
-- gns autorun on|off  start gns when the computer boots (a line in /home/.shrc)
-- gns update          install the newest GNS from GitHub (needs an internet card)
-- gns floppy DEST     write GNS and its libraries to DEST/gns.bundle (a floppy, say), for
--                     computers without an internet card: bundle unpack /mnt/xxx/gns.bundle
-- gns floppy DEST --os[=GROUP,...] [--skip=PATH,...] [--name=gate-%02d] [--first=N] [--auto=S] [--label=TEXT]
--                     make an installer floppy with QuickOS and GNS for empty computers (mkinstaller)
-- --gate              (with floppy) only the gate server: no client, no loom. A gate server's
--                     own install (install.lua gate) always makes these.
-- gns help            this list
-- --repeating reruns the program after it exits (for development).
local shell = require("shell")
local fs = require("filesystem")
local component = require("component")
local args, options = shell.parse(...)
local command = args[1]

local gnsPath = "/usr/gns/"
local serverPath, clientPath = gnsPath .. "server/server.lua", gnsPath .. "client/client.lua"

if command == "help" or (command and command ~= "client" and command ~= "passwd" and command ~= "autorun" and command ~= "update" and command ~= "floppy") then
    print("gns                 run the gate server (with a stargate) or the client")
    print("gns client          run the client")
    print("gns passwd          change the client vault's password")
    print("gns autorun on|off  start gns when the computer boots")
    print("gns update          install the newest GNS from GitHub")
    print("gns floppy DEST     write GNS to DEST/gns.bundle for bundle unpack elsewhere")
    print("gns floppy DEST --os  make an installer floppy with QuickOS and GNS (mkinstaller's")
    print("                    --os, --skip, --name, --first, --auto and --label pass through)")
    print("gns floppy ... --gate  only the gate server: no client or loom")
    return
end

-- The bundle carries this computer's GNS, loom and ecc, never its vault, address book,
-- settings or gate state: those hold this computer's own keys and gates. With --os, mkinstaller
-- packs QuickOS beside it and leaves everything GNS installs (excluded files too) out of the OS.
if command == "floppy" then
    if not args[2] then
        io.stderr:write("Usage: gns floppy DEST [--gate] [--os[=GROUP,...]]\n")
        return
    end
    local dest = shell.resolve(args[2])
    local out = fs.concat(dest, "gns.bundle")
    local cfgPath = "/usr/bundle.cfg" -- bundle packs a folder by its bundle.cfg, so one goes in /usr for a moment
    if fs.exists(cfgPath) then
        io.stderr:write(cfgPath .. " is in the way; gns floppy writes its own there while it runs.\n")
        return
    end
    -- Only the loom files the client uses (usr/gns/parts.lua); a gate server's floppy has neither.
    -- Excluded files also stay out of the OS that --os packs.
    local parts = dofile(gnsPath .. "parts.lua")
    local gate = options.gate or not fs.exists(clientPath)
    local paths = {{"gns", "usr/gns"}, {"bin/gns.lua", "usr/bin/gns.lua"}, {"lib/ecc", "usr/lib/ecc"}}
    local exclude = {"gns/client/vault", "gns/client/database", "gns/client/settings.lua", "gns/server/settings.lua", "gns/server/state"}
    if gate then
        for _, part in ipairs(parts.client) do exclude[#exclude + 1] = part end
    end
    if fs.exists("/usr/lib/loom") then
        paths[#paths + 1] = {"lib/loom", "usr/lib/loom"}
        local keep = {}
        for _, path in ipairs(gate and {} or parts.loom) do keep[path] = true end
        local function leaveOut(dir)
            for name in fs.list("/usr/lib/loom/" .. dir) do
                if name:sub(-1) == "/" then leaveOut(dir .. name)
                elseif not keep[dir .. name] then exclude[#exclude + 1] = "lib/loom/" .. dir .. name end
            end
        end
        leaveOut("")
    end
    local file = assert(io.open(cfgPath, "w"))
    file:write(require("serialization").serialize({name = "gns", hostname = true, paths = paths, exclude = exclude}))
    file:close()
    if options.os then
        local argv, done = {dest, "/usr"}, fs.concat(dest, "install.cfg")
        for _, key in ipairs({"os", "skip", "name", "first", "auto", "label"}) do
            local value = options[key]
            if value then argv[#argv + 1] = "--" .. key .. (value == true and "" or "=" .. tostring(value)) end
        end
        if fs.exists(done) then fs.remove(done) end -- mkinstaller writes it last, so it marks a whole floppy
        shell.execute("mkinstaller", nil, table.unpack(argv))
        fs.remove(cfgPath)
        if not fs.exists(done) then
            io.stderr:write("Could not make the installer floppy at " .. dest .. ".\n")
            return
        end
        print("Boot an empty computer from it to install QuickOS and GNS" .. (gate and " (the gate server)." or "."))
        return
    end
    shell.execute("bundle", nil, "pack", "/usr", "--out=" .. out)
    fs.remove(cfgPath)
    -- bundle says why on the screen and removes a bundle it could not finish.
    if not fs.exists(out) then
        io.stderr:write("Could not write GNS to " .. out .. ".\n")
        return
    end
    print(("Wrote %s (%d KB). On a QuickOS computer: bundle unpack %s"):format(out, fs.size(out) // 1024, out))
    return
end

if command == "update" then
    local installer = "/tmp/gns-install.lua"
    if not component.isAvailable("internet") then
        io.stderr:write("Updating GNS needs an internet card.\n")
        return
    end
    if fs.exists(installer) then fs.remove(installer) end
    shell.execute("wget -fq https://raw.githubusercontent.com/Renno231/Gate-Network-System/main/install.lua " .. installer)
    if not fs.exists(installer) then
        io.stderr:write("Could not download the GNS installer.\n")
        return
    end
    shell.execute(installer .. (fs.exists(clientPath) and "" or " gate")) -- a gate server's install stays one
    fs.remove(installer)
    print("Restart gns to run the new version.")
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
