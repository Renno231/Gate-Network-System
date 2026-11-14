-- gns help, passwd, autorun, update, uninstall and floppy (usr/bin/gns.lua lists them); gns.lua
-- runs this file with its arguments.
local shell = require("shell")
local fs = require("filesystem")
local component = require("component")
local args, options = shell.parse(...)
local command = args[1]

local gnsPath = "/usr/gns/"
local clientPath = gnsPath .. "client/client.lua"
-- What GNS writes at run time, under /usr: this computer's keys, gates, address book backups,
-- state and history. A floppy
-- never carries it and gns uninstall keeps it, unless --all.
local DATA = {"gns/client/vault", "gns/client/database", "gns/client/settings.lua", "gns/client/backups",
    "gns/server/settings.lua", "gns/server/state", "gns/server/state.log", "gns/server/update.log"}
local COMMANDS = {passwd = true, autorun = true, update = true, uninstall = true, floppy = true}

if command == "help" or (command and not COMMANDS[command]) then
    print("gns                 the gate (with a stargate) in the background, then the client")
    print("gns gate            the gate server's console")
    print("gns client          run only the client")
    print("gns passwd          change the client vault's password")
    print("gns autorun on|off  start gns when the computer boots")
    print("gns update          install the newest GNS from GitHub")
    print("gns uninstall       remove GNS but keep the vault, settings and gate state")
    print("gns uninstall --all remove those too")
    print("gns floppy DEST     write GNS to DEST/gns.bundle for bundle unpack elsewhere")
    print("gns floppy DEST --os  make an installer floppy with QuickOS and GNS (mkinstaller's")
    print("                    --os, --skip, --name, --first, --auto and --label pass through)")
    print("gns floppy ... --gate  only the gate server: no client or loom")
    print("gns floppy ... --own   gates installed from it are this device's (--silent: and silent)")
    print("gns floppy ... --unregistered  the first client to set a gate up owns it")
    print("                    (without either, every gate installed from it is public)")
    print("gns help            this list")
    return
end

-- The bundle carries this computer's GNS, loom and ecc, never its vault, address book,
-- settings or gate state: those hold this computer's own keys and gates. With --os, mkinstaller
-- packs QuickOS beside it and leaves everything GNS installs (excluded files too) out of the OS.
if command == "floppy" then
    if not args[2] then
        io.stderr:write("Usage: gns floppy DEST [--gate] [--own [--silent] | --unregistered] [--os[=GROUP,...]]\n")
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
    local exclude = {table.unpack(DATA)}
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
    -- --own: the owner's key and player name ride in server/owner.lua, which a gate takes once.
    -- No wake key: each gate makes its own. A tablet has no disk drive: in a charger beside a
    -- computer case with one, the computer boots from the tablet's own drive, and --own takes
    -- the tablet's key. --unregistered: the first client to set a gate up owns it. Without
    -- either, a gate installed from the floppy is public.
    local ownerPath = gnsPath .. "server/owner.lua"
    if options.own and options.unregistered then
        io.stderr:write("--own and --unregistered: choose one.\n")
        return
    end
    if options.silent and not options.own then
        io.stderr:write("--silent goes with --own (a gate set up from a tablet takes its network profile's).\n")
        return
    end
    if options.unregistered then
        local file = assert(io.open(ownerPath, "w"))
        file:write("return {unregistered = true}")
        file:close()
        print("Gates installed from it are unregistered: the first client to set one up owns it.")
    end
    if options.own then
        local vaultPath = gnsPath .. "client/vault"
        local vault = dofile(gnsPath .. "vault.lua")
        if not vault.exists(vaultPath) then
            io.stderr:write("--own needs this device's GNS vault: run gns once first.\n")
            return
        end
        local term = require("term")
        io.write("GNS password: ")
        local password = (term.read(nil, nil, nil, "*") or ""):gsub("\n$", "")
        local opened, reason = vault.open(vaultPath, password)
        if not opened then
            io.stderr:write(tostring(reason) .. "\n")
            return
        end
        local key = opened:publicKey()
        opened:lock()
        io.write("Owner's player name: ")
        local player = (term.read() or ""):gsub("%s+$", "")
        if player == "" then
            io.stderr:write("No player name given.\n")
            return
        end
        local file = assert(io.open(ownerPath, "w"))
        file:write("return " .. require("serialization").serialize({owner = key, ownerName = player, silent = options.silent or nil}))
        file:close()
        print(("Gates installed from it will belong to %s (%s)%s."):format(player, vault.fingerprint(key),
            options.silent and " and be silent" or ""))
    end
    -- An installer floppy also turns gns autorun on at the computer's first boot (usr/gns/autorun-rc.lua).
    local enable
    if options.os then
        paths[#paths + 1], enable = {"gns/autorun-rc.lua", "etc/rc.d/gns-autorun.lua"}, {"gns-autorun"}
    end
    local file = assert(io.open(cfgPath, "w"))
    file:write(require("serialization").serialize({name = "gns", hostname = true, paths = paths, exclude = exclude, enable = enable}))
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
        if fs.exists(ownerPath) then fs.remove(ownerPath) end
        if not fs.exists(done) then
            io.stderr:write("Could not make the installer floppy at " .. dest .. ".\n")
            return
        end
        print("Boot an empty computer from it to install QuickOS and GNS" .. (gate and " (the gate server)." or "."))
        return
    end
    shell.execute("bundle", nil, "pack", "/usr", "--out=" .. out)
    fs.remove(cfgPath)
    if fs.exists(ownerPath) then fs.remove(ownerPath) end
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
    -- Run here, not through the shell, so a failed install (install.lua says why, then exits 1)
    -- is not followed by the restart hint.
    local run, reason = loadfile(installer)
    local ok, why = false, reason
    if run then ok, why = pcall(run, not fs.exists(clientPath) and "gate" or nil) end -- a gate server's install stays one
    fs.remove(installer)
    if not ok then
        if type(why) ~= "table" then io.stderr:write(tostring(why) .. "\n") end
        return
    end
    print("Restart gns to run the new version.")
    return
end

-- Autorun is a gns line in /home/.shrc: the file's other lines, and whether it has that one.
local rcPath = "/home/.shrc"
local function readRc()
    local lines, present = {}, false
    local file = io.open(rcPath)
    if file then
        for l in file:lines() do
            if l == "gns" then present = true else lines[#lines + 1] = l end
        end
        file:close()
    end
    return lines, present
end
local function writeRc(lines)
    local file = assert(io.open(rcPath, "w"))
    file:write(table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
    file:close()
end

if command == "autorun" then
    local lines, present = readRc()
    if args[2] == "on" then lines[#lines + 1] = "gns" elseif args[2] ~= "off" then
        print("gns autorun is " .. (present and "on" or "off") .. "; use gns autorun on|off")
        return
    end
    writeRc(lines)
    print("gns autorun " .. args[2])
    return
end

if command == "uninstall" then
    if options.all then
        io.write("This also deletes the vault (this computer's identity and address book), settings and gate state.\nType yes to go on: ")
        if io.read() ~= "yes" then print("Nothing was removed.") return end
    end
    local keep = {}
    if not options.all then
        for _, path in ipairs(DATA) do keep["/usr/" .. path] = true end
    end
    local removed = 0
    -- Removes path, except what is kept; true when nothing of it is left.
    local function remove(path)
        if keep[path] then return false end
        if not fs.exists(path) then return true end
        if fs.isDirectory(path) then
            local gone = true
            for name in fs.list(path) do
                gone = remove(fs.concat(path, name)) and gone
            end
            if gone then fs.remove(path) end
            return gone
        end
        fs.remove(path)
        removed = removed + 1
        return true
    end
    remove("/usr/gns")
    remove("/usr/bin/gns.lua")
    local lines, present = readRc()
    if present then writeRc(lines) end
    print(("Removed %d files of GNS. %sThe loom and ecc libraries stay."):format(removed,
        options.all and "" or "The vault, settings and gate state stay for a reinstall. "))
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
