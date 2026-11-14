-- Dial's admin features, loaded when used (dial.lua's part): a gate's console and log, setting up
-- an unregistered gate, pushing GNS files to a gate. Returns its functions.
local api = ...
local gns = api.gns
local clientEnv = api.clientEnv
local ui = api.ui
local C = api.C
local log = api.log
local guard = api.guard
local isAdmin = api.isAdmin
local handshake = api.handshake
local identity = api.identity
local remember = api.remember
local closeConnection = api.closeConnection
local findGate = api.findGate
local gateOrFrom = api.gateOrFrom
local loom = require("loom")
local event = require("event")
local fs = require("filesystem")

local gateLog
-- The gate console of a gate whose network this device administers: the commands the gate's
-- owner types at the gate computer, run remotely.
local function remote(connection, line, out)
    connection.proxy:async(guard(function(ok, lines)
        if ok ~= true then out("Refused: " .. tostring(lines)) return end
        for _, l in ipairs(lines) do out(l) end
        loom.invalidate()
    end)).console(line)
end

local function console(connection)
    if not connection then return "No gate in range." end
    if ui.modalOpen() then return end
    local W, H = ui.W, ui.H
    local w, h = math.min(W - 4, 110), math.min(H - 4, 34)
    local box, close = ui.modal(clientEnv.root, clientEnv.shell, w, h, "CONSOLE · " .. connection.name)
    local lines = {"Remote console of " .. connection.name .. ". Type help for its commands, exit to close."}
    local list = ui.List(box, 2, 3, w - 2, h - 5, {items = lines, scrollOnly = true,
        cells = function(item) return {{1, item, item:sub(1, 6) == "gate> " and C.amber or C.text}} end})
    local function out(text)
        lines[#lines + 1] = text
        if #lines > 300 then table.remove(lines, 1) end
        list._scroll = math.huge
    end
    local field = ui.Field(box, 3, h - 1, w - 16, {clear = true, placeholder = "gate> command", submit = function(text)
        if not text:match("%S") then return end
        if text == "exit" or text == "quit" then event.timer(0, close) return end -- after submit, which uses the field
        out("gate> " .. text)
        remote(connection, text, out)
    end})
    ui.Button(box, w - 11, h - 1, 10, 1, "CLOSE", C.raised, C.text, close)
    ui.Button(box, w - 19, h - 1, 7, 1, "LOG", C.blue, C.black, function()
        close()
        gateLog(connection)
    end)
    ui.focusSoon(field)
end

-- The gate log (admins): what happened at the gate, newest first, each entry wrapped.
function gateLog(connection)
    if not connection then return "No gate in range." end
    if not isAdmin(connection) then return "The gate log needs the admin role." end
    connection.proxy:async(guard(function(ok, entries)
        if ok ~= true then log(connection.name .. ": no gate log: " .. tostring(entries)) return end
        if ui.modalOpen() then return end
        local w, h = math.min(ui.W - 4, 110), math.min(ui.H - 2, 34)
        local box, close = ui.modal(clientEnv.root, clientEnv.shell, w, h, "GATE LOG · " .. connection.name)
        local rows = {}
        for _, e in ipairs(entries) do
            for j, line in ipairs(ui.wrap(tostring(e[2]), w - 14)) do rows[#rows + 1] = {j == 1 and tostring(e[1]) or "", line} end
        end
        local list = ui.List(box, 2, 3, w - 2, h - 5, {items = rows, scrollOnly = true, empty = "Nothing logged yet.",
            cells = function(r) return {{1, r[1], C.faint}, {11, r[2], C.text}} end})
        ui.Paint(box, 3, h - 1, w - 16, 1, function(self)
            self:text(1, 1, ui.pad(("%d entries, newest first · Tab, Enter: CLOSE"):format(#entries), w - 16), C.faint, C.card)
        end)
        ui.Button(box, w - 11, h - 1, 10, 1, "CLOSE", C.raised, C.text, close)
        ui.focusSoon(list)
    end)).gatelog()
    return ("Reading %s's gate log..."):format(connection.name)
end

-- Registers an unregistered gate to this device: its key becomes the owner, the player its OC
-- user, and a new wake key starts it from now on.
local function setup(c)
    if not c then return "No gate in range." end
    if c.registered then return c.name .. " already has an owner." end
    local player = clientEnv.player
    if not player then return "Press a key on this device first, so OC names the player." end
    local wake = handshake.wakeKey()
    c.proxy:async(guard(function(ok, result)
        if ok ~= true then log(c.name .. ": not set up: " .. tostring(result)) return end
        c.role, c.registered, c.owner, c.tag = "owner", true, identity.public, "owner"
        remember(c, wake)
        local saved, err = clientEnv.vault:save()
        if not saved then log("Vault not saved: " .. tostring(err)) end
        log(("%s is yours: %s is its OC user, and this device holds its wake key."):format(c.name, player))
    end)).register(player, wake)
    return ("Setting up %s for %s..."):format(c.name, player)
end

-- Remote update: this device's gate-side GNS files (or the paths given, under /usr), pushed to
-- a gate this device administers. A gate that starts gns at boot restarts on them.
local function gateFiles()
    local parts = dofile(gns.path.gns .. "parts.lua")
    local skip = {["gns/server/settings.lua"] = true}
    local function clientOnly(path)
        for _, p in ipairs(parts.client) do
            if path == p or path:sub(1, #p + 1) == p .. "/" then return true end
        end
    end
    local list = {}
    local function walk(dir)
        for name in fs.list("/usr/" .. dir) do
            local path = dir .. name
            if name:sub(-1) == "/" then walk(path)
            elseif path:sub(-4) == ".lua" and not skip[path] and not clientOnly(path) then list[#list + 1] = path end
        end
    end
    walk("gns/")
    list[#list + 1] = "bin/gns.lua"
    return list
end

local function update(c, paths)
    if not c then return "No gate in range." end
    if not isAdmin(c) then return c.name .. ": updates need the admin role." end
    paths = #paths > 0 and paths or gateFiles()
    local files = {}
    for _, path in ipairs(paths) do
        local file = io.open("/usr/" .. path, "rb")
        if not file then return "No file /usr/" .. path .. " here." end
        files[#files + 1] = {path, file:read("*a")}
        file:close()
    end
    -- In parts of about 32 KB, each its own call well inside the 10 s an RPC may take; the gate
    -- swaps the files in with the last part (a whole push in one took 5 s on an unloaded server).
    local parts, size = {{}}, 0
    for _, f in ipairs(files) do
        if size > 0 and size + #f[2] > 32768 then parts[#parts + 1], size = {}, 0 end
        table.insert(parts[#parts], f)
        size = size + #f[2]
    end
    local function send(i)
        c.proxy:async(guard(function(ok, count, restart)
            if ok ~= true then log(c.name .. ": update refused: " .. tostring(count)) return end
            if i < #parts then send(i + 1) return end
            log(("%s: %d files updated%s."):format(c.name, count, restart and "; it restarts once idle" or ""))
            if restart then closeConnection(c) end
        end)).update(parts[i], i, #parts)
    end
    send(1)
    return ("Pushing %d files to %s..."):format(#files, c.name)
end

return {remote = remote, console = console, gateLog = gateLog, setup = setup, update = update,
    ssh = function(args)
    local c = args[1] and findGate(args[1])
    local rest = 2
    if not c then c, rest = clientEnv.fromGate(), 1 end
    if not c then return "No gate in range." end
    if not isAdmin(c) then return c.name .. ": the console needs the admin role."  end
    if #args < rest then return console(c) end
    local line = table.concat(args, " ", rest)
    remote(c, line, function(text) log("  " .. c.name .. ": " .. text) end)
    return c.name .. "> " .. line
    end,
    setupCommand = function(args)
    local c, named = gateOrFrom(args[1])
    if named and not c then return "No gate " .. args[1] .. " in range." end
    return setup(c)
    end,
    gatelog = function(args)
    local c = gateOrFrom(args[1])
    if not c then return args[1] and ("No gate " .. args[1] .. " in range.") or "No gate in range." end
    return gateLog(c)
    end,
    updateCommand = function(args)
    local c, rest = args[1] and findGate(args[1]), 2
    if not c then c, rest = clientEnv.fromGate(), 1 end
    return update(c, {table.unpack(args, rest)})
    end}
