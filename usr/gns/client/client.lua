local gns = ... -- expects a table

if type(gns) == "table" then
    if type(gns.utility)~= "table" then
        error"Gate Network System utilities are missing"
    end
    if type(gns.path)~= "table" then
        error"Gate Network System path information is missing"
    end
    -- could do more checks
else
    error("Gate Network System environment not loaded")
end
-- Shared with the screens (interface/*.lua). onClose: functions run when the screens are taken
-- down (their timers), so nothing keeps running after them.
local clientEnv = {onClose = {}}

local event = require"event"
-- One listener across client runs (package.loaded is the OS's, not this run's): the last run's
-- is replaced.
local INTERRUPTED = "gns.interrupted"
if package.loaded[INTERRUPTED] then event.ignore("interrupted", package.loaded[INTERRUPTED]) end
package.loaded[INTERRUPTED] = function()
    gns.isRepeating = false
    gns.clientActive = false
    if package.loaded.loom then package.loaded.loom.stop() end
    for i,_ in pairs (package.loaded) do if i:match("^loom") then package.loaded[i] = nil end end
    package.loaded.ecc = nil
    package.loaded[INTERRUPTED] = nil
    return false
end
event.listen("interrupted", package.loaded[INTERRUPTED])

-- Unlock the vault (identity key and address book) before the GUI takes the screen.
-- The password is typed in the terminal, before the GUI takes the screen.
local vault = dofile(require("filesystem").concat(gns.path.gns, "vault.lua"))
local function unlockVault()
    local fs, term = require("filesystem"), require("term")
    local vaultPath = fs.concat(gns.path.clientDirectory, "vault")
    local function ask(prompt)
        io.write(prompt)
        local line = term.read(nil, nil, nil, "*")
        return line and (line:gsub("\n$", ""))
    end
    if vault.exists(vaultPath) then
        for _ = 1, 3 do
            local password = ask("GNS password: ")
            if not password then return nil end
            print("Unlocking...")
            local opened, reason = vault.open(vaultPath, password)
            if opened then return opened end
            print(reason)
        end
        return nil
    end
    print("First run: choose a password for this device's GNS vault.")
    print("It protects this device's identity key and address book.")
    local password
    repeat
        password = ask("New password: ")
        if not password then return nil end
        local again = ask("Repeat password: ")
        if not again then return nil end
        if password == "" or password ~= again then
            print(password == "" and "The password cannot be empty." or "The passwords do not match.")
            password = nil
        end
    until password
    -- Move an existing plaintext address book into the vault.
    local plainPath = fs.concat(gns.path.clientDirectory, "database/current.lua")
    local database = gns.utility.readFile(plainPath)
    print("Creating vault...")
    local created, reason = vault.create(vaultPath, password, {database = type(database) == "table" and database or {}})
    if not created then
        print("Could not create the vault: " .. tostring(reason))
        return nil
    end
    if fs.exists(plainPath) then fs.remove(plainPath) end
    print("Device fingerprint: " .. created:fingerprint())
    return created
end
local clientVault = unlockVault()
if not clientVault then
    gns.isRepeating = false
    gns.clientActive = false
    print("GNS client locked.")
    return
end
-- Unlocked: a player is using the client, so a gate on this computer neither sleeps nor restarts
-- under them (gate.lua). A client left at its password prompt (gns autorun at boot) holds nothing
-- to lose, and an unattended gate still sleeps. gns.lua clears it when the client ends.
if package.loaded["gns.here"] then package.loaded["gns.here"].client = true end

local loom = require("loom")
local ui = dofile(gns.path.clientDirectory .. "ui.lua")
local C = ui.C
local term = require("term")
local computer = require("computer")
local serialization = require("serialization")
local unicode = require("unicode")
local component = require("component")
require("ecc") -- loaded once here for the screens' network work (about 105 KB at most)
clientEnv.ui = ui
clientEnv.gateconnections = {} -- the gates in range this device opened, nearest first
clientEnv.link = dofile(gns.path.gns .. "link.lua") -- gate commands as single messages
-- The client's tnet endpoints and connections. Closed when the client quits, or by QuickOS when
-- it crashes; a gate running on this computer has its own.
clientEnv.bucket = require("tnet").bucket("gns.client")

local modem = component.modem
local readFile = gns.utility.readFile
local writeFile = gns.utility.writeFile

-- The vault also holds pinned gate keys, the gates' own signed entries (book), the grants this
-- device holds and has issued, its proofs, and what it knows of the gates it may use (access[gate key] =
-- {name, modem, port, wake, owner, role}: how to reach and wake them).
local vaultState = clientVault.state
vaultState.pins, vaultState.book = vaultState.pins or {}, vaultState.book or {}
vaultState.proofs = vaultState.proofs or {} -- this device's gate.open proof per gate modem (handshake.lua)
vaultState.grants, vaultState.issued, vaultState.access = vaultState.grants or {}, vaultState.issued or {}, vaultState.access or {}
vaultState.networks = nil -- founder networks are gone: grants replaced them
local database = vaultState.database
clientEnv.database = database
clientEnv.vault = clientVault

-- A gate row keeps each galaxy's address as one string of glyph names, comma separated: r.MW,
-- r.PG, r.UN (absent when unknown). Three lists per gate held about twice the memory, and a
-- tablet holds the whole book; a list is made only where one is used.
local GALAXIES = {"MW", "PG", "UN"}
-- The row's address in one galaxy, as a new list.
local function glyphs(r, galaxy)
    local out, s = {}, r and r[galaxy]
    if type(s) == "string" then for g in s:gmatch("[^,]+") do out[#out + 1] = g end end
    return out
end
clientEnv.glyphs = glyphs
-- All three, as the gate's dial and energy calls, routes and shares take them.
function clientEnv.address(r) return {MW = glyphs(r, "MW"), PG = glyphs(r, "PG"), UN = glyphs(r, "UN")} end
-- Sets the row's addresses from lists of glyph names by galaxy, or, with galaxy, that galaxy's
-- from one list.
function clientEnv.setAddress(r, address, galaxy)
    for _, g in ipairs(galaxy and {galaxy} or GALAXIES) do
        local list = galaxy and address or address and address[g]
        r[g] = type(list) == "table" and #list > 0 and table.concat(list, ",") or nil
    end
    return r
end
-- Whether the row's address in galaxy and list (glyph names) start with the same six glyphs:
-- the same gate.
function clientEnv.sameSix(r, galaxy, list)
    local s = r and r[galaxy]
    if type(s) ~= "string" or type(list) ~= "table" or #list < 6 then return false end
    local six = table.concat(list, ",", 1, 6)
    return s:sub(1, #six) == six and (#s == #six or s:byte(#six + 1) == 44) -- 44: ","
end
-- A row as books saved before kept it, and shares still send it: Address = {MW = {...}, ...}.
function clientEnv.flatten(r)
    local a = r.Address
    r.Address = nil
    return type(a) == "table" and clientEnv.setAddress(r, a) or r
end
for _, r in ipairs(database) do clientEnv.flatten(r) end

local settingsPath = gns.path.clientDirectory .. "settings.lua"
-- Client settings, changed on the Settings screen or with set. Unknown or mistyped saved values
-- are ignored.
local settings = {
    fastDial = true, -- press the gate's DHD instead of spinning the ring
    dialSpeed = 0, -- seconds a whole dial takes, spread over the glyphs (GDS's speed); 0: fastest
    autoLogToDatabase = true, -- add gates learned from scans to the address book
    nearbyScanRate = 0, -- seconds between automatic scans for gates; 0 (off, as on GDS): at start and on SCAN
    modemRange = 400, -- wireless strength in blocks (16 to 400)
    autoAcceptShared = false, -- take gates shared by other devices without asking
    chatBlacklist = {}, -- device fingerprint -> true: their chat and shares are dropped
    layout = "auto", -- "auto", "compact" (80x25) or "wide" (160x50)
    -- Show gate addresses and IDCs. A client on a gate's own computer (a kiosk) hides them; only
    -- its OC users, the owner and admins, can type there to change it.
    showCodes = not component.isAvailable("stargate"),
    port = 160, -- the modem port of the gates this device uses (a network's base layer)
    tabletSleep = 5, -- minutes without a key or touch before a tablet saves and shuts down; 0: never
    profile = "", -- the network profile in use (its name), or "" for every gate
}
clientEnv.settings = settings

local function applySettings()
    settings.modemRange = math.min(math.max(math.floor(tonumber(settings.modemRange) or 400), 16), 400)
    settings.nearbyScanRate = math.min(math.max(math.floor(tonumber(settings.nearbyScanRate) or 0), 0), 600)
    if settings.layout ~= "compact" and settings.layout ~= "wide" then settings.layout = "auto" end
    settings.port = math.min(math.max(math.floor(tonumber(settings.port) or 160), 1), 65535)
    settings.tabletSleep = math.min(math.max(math.floor(tonumber(settings.tabletSleep) or 5), 0), 600)
    settings.dialSpeed = math.min(math.max(math.floor(tonumber(settings.dialSpeed) or 0), 0), 120)
    if modem.setStrength then modem.setStrength(settings.modemRange) end
end
function clientEnv.saveSettings()
    applySettings()
    local ok, why = writeFile(settingsPath, "return " .. serialization.serialize(settings, math.huge))
    if not ok and clientEnv.log then clientEnv.log("Settings not saved: " .. tostring(why)) end
    return ok, why
end
readFile(settingsPath, function(saved)
    if type(saved) ~= "table" then return end
    for name, value in pairs(saved) do
        if settings[name] ~= nil and type(settings[name]) == type(value) then settings[name] = value end
    end
end)
clientEnv.saveSettings()

-- Network profiles: a name, a port and the gates that belong to it (row.Profiles[name]), kept in
-- the vault. The client listens on every profile's port as well as its own, so one device takes
-- part in several networks; with a profile in use (settings.profile) the address book and Dial
-- show only its gates. Profiles grant nothing: grants and roles stay as they are.
vaultState.profiles = vaultState.profiles or {}
function clientEnv.profile()
    for _, p in ipairs(vaultState.profiles) do if p.name == settings.profile then return p end end
end
function clientEnv.inProfile(r)
    local p = clientEnv.profile()
    return not p or (r.Profiles or {})[p.name] == true
end
function clientEnv.ports()
    local ports = {[settings.port] = true}
    for _, p in ipairs(vaultState.profiles) do ports[p.port] = true end
    return ports
end
function clientEnv.listen()
    for port in pairs(clientEnv.ports()) do
        if not modem.isOpen(port) then pcall(modem.open, port) end
    end
end
-- A gate reached on a profile's port belongs to that profile.
function clientEnv.joinByPort(r, port)
    for _, p in ipairs(vaultState.profiles) do
        if p.port == port then
            r.Profiles = r.Profiles or {}
            r.Profiles[p.name] = true
        end
    end
end

---------------------------------------------------------------------------- activity
-- One activity log for everything the client does; the latest line also shows in the bottom bar.
local activity = {}
clientEnv.activity = activity
local toast = {text = "", at = 0}
function clientEnv.log(text)
    text = tostring(text)
    activity[#activity + 1] = {time = os.date("%H:%M"), text = text}
    if #activity > 200 then table.remove(activity, 1) end
    toast.text, toast.at = text, computer.uptime()
    loom.invalidate()
end
ui.onError = function(err) clientEnv.log("Error: " .. tostring(err)) end

-- Edits are saved to the vault 5 s after the first one (a save encrypts the whole vault, so a
-- burst of edits costs one), and when the client closes. Nothing runs while nothing changes.
local saveTimer
function clientEnv.changed()
    if saveTimer then return end
    saveTimer = event.timer(5, function()
        saveTimer = nil
        local saved, err = clientVault:save()
        if not saved then clientEnv.log("Vault not saved: " .. tostring(err)) end
    end)
end

-- Address book entries by number (their place in the book) or name: a name may be cut short,
-- with _ for spaces. Returns the row and its number.
function clientEnv.findEntry(selector)
    if selector == nil then return nil end
    local n = math.tointeger(tonumber(selector))
    if n then return database[n], database[n] and n end
    local want = tostring(selector):gsub("_", " "):lower()
    for i, row in ipairs(database) do
        if tostring(row.Name):lower() == want then return row, i end
    end
    for i, row in ipairs(database) do
        if tostring(row.Name):lower():sub(1, #want) == want then return row, i end
    end
end

-- Where a gate is, from its Location {dimension, x, y, z}: "dim 0 · 120 64 -300", or nil.
function clientEnv.place(row)
    local l = type(row.Location) == "table" and row.Location
    if not l or l.dimension == nil then return nil end
    local s = "dim " .. tostring(l.dimension)
    if l.x then s = s .. " · " .. tostring(l.x) .. " " .. tostring(l.y) .. " " .. tostring(l.z) end
    return s
end
-- What the address book's search looks in: name, galaxy, location, and the glyphs of each
-- address where addresses are shown on this device.
function clientEnv.searchText(r)
    local hay = tostring(r.Name) .. " " .. tostring(r.Type) .. " " .. (clientEnv.place(r) or "")
    if settings.showCodes then
        for _, galaxy in ipairs({"MW", "PG", "UN"}) do
            if r[galaxy] then hay = hay .. " " .. r[galaxy]:gsub(",", " ") end
        end
    end
    return hay:lower()
end

---------------------------------------------------------------------------- chat
-- The peer service runs while the client is open, so chat lines and shared gates arrive whatever
-- screen is showing. Entries: {time, text, who, mine}; notes have no who.
local handshake = dofile(gns.path.gns .. "handshake.lua")
local peer = loadfile(gns.path.gns .. "peer.lua")(handshake, vault.fingerprint)
local entries = dofile(gns.path.gns .. "entries.lua")
-- One copy each of the stateless modules, for the screens too.
clientEnv.vaultModule, clientEnv.entries, clientEnv.handshake = vault, entries, handshake
vaultState.peerPins = vaultState.peerPins or {}
local chat = {lines = {}, pending = {}, devices = {}, unread = 0} -- pending: shares waiting for an answer
clientEnv.chat = chat
local function addLine(entry)
    entry.time = os.date("%H:%M")
    chat.lines[#chat.lines + 1] = entry
    if #chat.lines > 200 then table.remove(chat.lines, 1) end
    if entry.who and not entry.mine and clientEnv.screen ~= "chat" then chat.unread = chat.unread + 1 end
    loom.invalidate()
end
function chat.show(text) addLine({text = tostring(text)}) end
function chat.say(who, text, mine) addLine({who = who, text = tostring(text), mine = mine}) end
function chat.label(from)
    return ("%s (%s)"):format(from.name, from.fingerprint:sub(1, 13))
end
function chat.hasIDCs(share)
    for _, row in ipairs(share.rows) do if #row.IDCs > 0 then return true end end
    return false
end
-- Adds a share's rows to the address book and keeps the signed gate entries that verify. A gate
-- already there gains any shared IDCs it lacks. Returns the rows added and the IDCs added.
local function first6(list) list = list or {} return table.concat(list, ",", 1, math.min(6, #list)) end
function chat.accept(share)
    -- Only the signed entries of the shared rows' gates: the rest would cost a verify each.
    local wanted, signed = {}, {}
    for _, row in ipairs(share.rows) do if row.key then wanted[row.key] = true end end
    for _, e in ipairs(type(share.signed) == "table" and share.signed or {}) do
        if type(e) == "table" and wanted[e.key] then signed[#signed + 1] = e end
    end
    pcall(entries.mergeAll, vaultState.book, signed, nil)
    local added, codes = 0, 0
    for _, row in ipairs(share.rows) do
        -- The sender names the gate's key; a row is "signed by its gate" only if the gate's own
        -- signed entry for that key holds the same address in every galaxy the row gives.
        local entry = row.key and vaultState.book[row.key]
        local same = entry ~= nil
        for kind, glyphs in pairs(same and row.Address or {}) do
            same = same and first6(glyphs) == first6((entry.address or {})[kind])
        end
        if not same then row.key = nil end
        clientEnv.flatten(row)
        local existing
        for _, known in ipairs(database) do
            if known.Name == row.Name and known.MW == row.MW then existing = known break end
        end
        if existing then
            existing.IDCs = existing.IDCs or {}
            for _, code in ipairs(row.IDCs) do
                local have = false
                for _, c in ipairs(existing.IDCs) do if c == code then have = true break end end
                if not have then existing.IDCs[#existing.IDCs + 1] = code codes = codes + 1 end
            end
        else
            local p = clientEnv.profile and clientEnv.profile()
            row.Profiles = p and {[p.name] = true} or nil
            database[#database + 1] = row
            added, codes = added + 1, codes + #row.IDCs
        end
    end
    local saved, err = clientVault:save()
    if not saved then clientEnv.log("Vault not saved: " .. tostring(err)) end
    return added, codes
end
local hostnameFile = io.open("/etc/hostname")
local deviceName = hostnameFile and hostnameFile:read("*l") or modem.address:sub(1, 8)
if hostnameFile then hostnameFile:close() end
clientEnv.deviceName = deviceName
clientEnv.peer = peer.start(vaultState.identity, vaultState.peerPins, deviceName, {
    chat = function(from, line)
        if settings.chatBlacklist[from.fingerprint] then return end
        chat.say(chat.label(from), line)
    end,
    share = function(from, rows, signed)
        if settings.chatBlacklist[from.fingerprint] or #rows == 0 then return end
        -- Only well-formed entries, copied: a share is kept until it is answered.
        -- Only one entry per shared row's gate: the rest would never be used.
        local kept, wanted = {}, {}
        for _, row in ipairs(rows) do if row.key then wanted[row.key] = true end end
        for _, e in ipairs(signed) do
            e = entries.clean(e)
            if e and wanted[e.key] then wanted[e.key] = nil kept[#kept + 1] = e end
        end
        local share = {from = from, rows = rows, signed = kept}
        if settings.autoAcceptShared then
            chat.show(("%s shared %d gates%s; %d added to the address book."):format(chat.label(from), #rows,
                chat.hasIDCs(share) and " with IDCs" or "", (chat.accept(share))))
        else
            -- At most 20 shares and 100 gates wait, the newest kept: memory is small.
            chat.pending[#chat.pending + 1] = share
            local waiting = 0
            for _, s in ipairs(chat.pending) do waiting = waiting + #s.rows end
            while #chat.pending > 20 or waiting > 100 do waiting = waiting - #table.remove(chat.pending, 1).rows end
            if clientEnv.screen ~= "chat" then chat.unread = chat.unread + 1 end
            chat.show(("%s shared %d gates%s. Accept or refuse them under Shared With You."):format(chat.label(from), #rows,
                chat.hasIDCs(share) and " with their IDCs" or ""))
        end
    end,
}, clientEnv.bucket)

---------------------------------------------------------------------------- player and alarms
-- The player using the device: OC names them in every key and touch event. A gate registered
-- from here makes them its OC user.
clientEnv.player = vaultState.player
local function noticePlayer(name)
    if type(name) == "string" and name ~= "" and name ~= clientEnv.player then
        clientEnv.player, vaultState.player = name, name
        clientEnv.changed()
    end
end
-- The IDC a gate row sends for the player using the device: their own (PlayerIDCs[player],
-- for a device several players share), else the row's first IDC; nil if it has none.
function clientEnv.idcFor(r)
    local own = r and r.PlayerIDCs and clientEnv.player and r.PlayerIDCs[clientEnv.player]
    if math.tointeger(own) then return own end
    for _, code in ipairs(r and r.IDCs or {}) do if math.tointeger(code) then return code end end
end
-- Power saving, as on GDS: a tablet shuts down after settings.tabletSleep minutes without a key
-- or touch, once the vault is saved. A computer that is not a tablet never does.
local lastInput = computer.uptime()
-- Nobody at the client: no key or touch for IDLE seconds. Its scans, cost checks and status polls
-- only keep the screen current for whoever reads it, so they wait (dial.lua) for the next key or
-- touch; a dial going on keeps its polls. A player reading the screen touches it within minutes.
local IDLE = 5 * 60
function clientEnv.idle() return computer.uptime() - lastInput >= IDLE end
local onTablet = component.isAvailable("tablet")
-- The screens loaded beside Dial: name → the module its file returned (see "the screens").
local loaded = {}
-- A screen still at work while not shown (Access inviting or joining): a tablet stays on for it,
-- as players may still be on their way.
local function busy()
    for _, m in pairs(loaded) do if m.busy and m.busy() then return true end end
end
local sleepTimer = event.timer(15, function()
    local minutes = settings.tabletSleep
    if busy() then lastInput = computer.uptime() end
    if not onTablet or minutes <= 0 or computer.uptime() - lastInput < minutes * 60 then return end
    local saved, err = clientVault:save()
    if not saved then clientEnv.log("Not shutting down: the vault was not saved: " .. tostring(err)) lastInput = computer.uptime() return end
    computer.shutdown()
end, math.huge)
local function onKey(_, _, _, _, player) lastInput = computer.uptime() noticePlayer(player) end
local function onTouch(_, _, _, _, _, player) lastInput = computer.uptime() noticePlayer(player) end
event.listen("key_down", onKey)
event.listen("touch", onTouch)

clientEnv.listen()

---------------------------------------------------------------------------- commands
-- The command bar: ; focuses it. Commands are separated by ;, words by spaces. Each screen adds
-- its own: clientEnv.command(names, usage, fn(args, line)); fn returns the text to report. A
-- screen that loads on demand names a command by its first name only: its names are in COMMANDS.
local COMMANDS = {
    gates = {{"new"}, {"add", "address"}, {"idc"}, {"import"}, {"loc", "location"}, {"gen", "generate"}, {"rename", "rn"},
        {"delete", "del", "remove", "rmv"}, {"swap"}, {"move", "mv"}, {"edit"}},
    chat = {{"find"}, {"say"}, {"share"}, {"block"}, {"accept"}, {"refuse"}},
    access = {{"grants"}, {"invite"}, {"join"}, {"cut"}},
    settings = {{"set", "s"}, {"get", "g"}, {"backup"}, {"backups"}, {"restore"}, {"profile", "pf"}},
}
local namesOf = {}
for _, list in pairs(COMMANDS) do for _, names in ipairs(list) do namesOf[names[1]] = names end end
local commands, commandOrder = {}, {}
function clientEnv.command(names, usage, fn, screen)
    if type(names) == "string" then names = namesOf[names] end
    local spec = {names = names, usage = usage, fn = fn, screen = screen}
    local old = commands[names[1]]
    for _, name in ipairs(names) do commands[name] = spec end
    for i, s in ipairs(commandOrder) do -- screens built again (a new layout) replace their commands
        if s == old then commandOrder[i] = spec return end
    end
    commandOrder[#commandOrder + 1] = spec
end
local history = {}
local function runCommands(line)
    for chunk in line:gmatch("[^;]+") do
        local args = {}
        for word in chunk:gmatch("%S+") do args[#args + 1] = word end
        if #args > 0 then
            clientEnv.log("> " .. table.concat(args, " "))
            local spec = commands[args[1]:lower()]
            if not spec then
                clientEnv.log("  Unknown command " .. args[1] .. ". Type help for the list.")
            else
                local ok, result = pcall(spec.fn, {table.unpack(args, 2)}, chunk)
                if not ok then result = "Error: " .. tostring(result) end
                if result then clientEnv.log("  " .. tostring(result)) end
            end
        end
    end
end
clientEnv.runCommands = runCommands
clientEnv.command({"help", "cmds", "?"}, "help [command]: the commands, or how to use one", function(args)
    local spec = args[1] and commands[args[1]:lower()]
    if spec and spec.screen then -- not loaded: the usage is in the screen's file
        clientEnv.loadInterface(spec.screen)
        local screen = spec.screen
        spec = commands[args[1]:lower()]
        clientEnv.closeInterface(screen)
    end
    if spec and spec.usage then return spec.usage .. (#spec.names > 1 and ("  (also " .. table.concat(spec.names, ", ", 2) .. ")") or "") end
    local names = {}
    for _, s in ipairs(commandOrder) do names[#names + 1] = s.names[1] end
    return "Commands: " .. table.concat(names, ", ") .. ". help <command> shows one. Gates are numbers in the address book or names (_ for spaces)."
end)
-- Keys that changed since they were pinned: name (lower case) -> {name, pins, address}. A gate
-- or device that was reinstalled has a new key; trust drops the old pin so the next SCAN or FIND
-- pins the new one.
local changedKeys = {}
function clientEnv.keyChanged(name, pins, address)
    changedKeys[(tostring(name):gsub("_", " "):lower())] = {name = name, pins = pins, address = address}
end
clientEnv.command({"trust"}, "trust <name>: accept the new key of a reinstalled gate or device (SCAN or FIND named it)", function(args)
    local word = table.concat(args, " "):gsub("_", " "):lower()
    local k = changedKeys[word]
    if not k then return "No changed key for " .. (args[1] and word or "that") .. ": SCAN or FIND names the gate or device first." end
    changedKeys[word] = nil
    k.pins[k.address] = nil
    clientEnv.changed()
    return ("Dropped the old key of %s; the next SCAN or FIND accepts its new one."):format(k.name)
end)
clientEnv.command({"clear", "c", "cls"}, "clear: empty the activity log", function()
    for i = #activity, 1, -1 do activity[i] = nil end
end)
clientEnv.command({"quit", "q", "exit"}, "quit: close the client", function()
    gns.clientActive = false
    loom.stop()
end)

---------------------------------------------------------------------------- dialogs
-- ask(message, opts, confirm, deny): a dialog with CONFIRM and CANCEL. opts.text = initial text
-- for a field, opts.options = {list, index} for a choice; confirm gets the text or choice.
-- One at a time; returns false if one is already open.
local root, shell -- this build's root frame and the frame with everything but dialogs
function clientEnv.ask(message, opts, confirm, deny)
    opts = opts or {}
    if ui.modalOpen() then return false end
    local w = math.min(ui.W - 4, math.max(44, unicode.len(message) + 6))
    local lines = ui.wrap(message, w - 4)
    local extra = (opts.text or opts.options) and 2 or 0
    local h = 5 + #lines + extra
    local frame, close = ui.modal(root, shell, w, h, opts.title or "CONFIRM")
    ui.Paint(frame, 1, 3, w, #lines, function(self)
        for i, line in ipairs(lines) do self:text(3, i, line, C.text, C.card) end
    end)
    local field, choice, done
    local function finish(fn)
        if done then return end
        done = true
        local result
        if field then result = field:text() elseif choice then result = opts.options.list[choice] end
        close()
        if fn then
            local ok, err = pcall(fn, result, choice) -- choice: which option, as labels may repeat
            if not ok then clientEnv.log("Error: " .. tostring(err)) end
        end
    end
    local y = 4 + #lines
    if opts.text then
        field = ui.Field(frame, 3, y, w - 4, {text = tostring(opts.text), mask = opts.mask, submit = function()
            -- After loom's submit returns: closing destroys the field, which submit still uses.
            event.timer(0, function() finish(confirm) end)
        end})
    elseif opts.options then
        choice = opts.options.index or 1
        local n = #opts.options.list
        ui.chooser(frame, 3, y, w - 4, function() return tostring(opts.options.list[choice]) end,
            function() choice = (choice - 2) % n + 1 end, function() choice = choice % n + 1 end)
    end
    local bw = math.min(14, (w - 7) // 2)
    local ok = ui.Button(frame, w // 2 - bw - 1, h - 1, bw, 1, "CONFIRM", C.green, C.black, function() finish(confirm) end)
    ui.Button(frame, w // 2 + 2, h - 1, bw, 1, "CANCEL", C.raised, C.text, function() finish(deny) end)
    ui.focusSoon(field or ok)
    return true
end

-- The whole activity log in a dialog, newest at the bottom, each entry wrapped (keeping a command
-- result's indent): L, or the log command. The compact layout has no room for the Activity card,
-- and the bottom bar shows only the latest line.
function clientEnv.showLog()
    if ui.modalOpen() then return false end
    local w, h = math.min(ui.W - 4, 110), math.min(ui.H - 2, 34)
    local width = w - 12
    local frame, close = ui.modal(root, shell, w, h, "ACTIVITY")
    local rows, count, newest = {}, -1, nil
    local function items()
        -- Wraps again only when the log has changed.
        if count ~= #activity or newest ~= activity[#activity] then
            count, newest = #activity, activity[#activity]
            rows = {}
            for i, a in ipairs(activity) do
                local indent, text = a.text:match("^(%s*)(.*)$")
                for j, line in ipairs(ui.wrap(text, width - #indent)) do
                    rows[#rows + 1] = {j == 1 and a.time or "", indent .. line, i == #activity}
                end
            end
        end
        return rows
    end
    local list = ui.List(frame, 2, 3, w - 2, h - 5, {items = items, scrollOnly = true, empty = "Nothing yet.",
        cells = function(r) return {{1, r[1], C.faint}, {8, r[2], r[3] and C.text or C.dim}} end})
    list._scroll = math.huge
    ui.Button(frame, w - 11, h - 1, 10, 1, "CLOSE", C.raised, C.text, close)
    ui.Paint(frame, 3, h - 1, w - 16, 1, function(self)
        self:text(1, 1, ui.pad("Up and Down or the wheel scroll · Tab, Enter: CLOSE", w - 16), C.faint, C.card)
    end)
    ui.focusSoon(list)
    return true
end
clientEnv.command({"log", "activity"}, "log: the whole activity log (or press L)", function()
    clientEnv.showLog()
end)

---------------------------------------------------------------------------- the shell
local SCREENS = {
    {"dial", "DIAL", "Dial"}, {"gates", "GATES", "Address book"}, {"chat", "CHAT", "Chat & share"},
    {"access", "ACCESS", "Access & grants"}, {"settings", "SETTINGS", "Settings"}, {"guide", "GUIDE", "Guide"},
}
local frames, screenInfo = {}, {} -- Dial's and the shown screen's
clientEnv.screen = "dial"
local interfacePath = gns.path.clientDirectory .. "interface/"
local R -- this build's screen area

---------------------------------------------------------------------------- the screens
-- Dial is always loaded. The other screens load when opened and unload when left, and a command
-- of theirs loads its screen just to run (COMMANDS routes it), so the screens nobody uses take no
-- memory. A screen's file runs with (gns, clientEnv, path): its top level holds its logic and
-- commands, and it returns {build = function(frame, R) → {first, shown}, busy, close}. A busy
-- screen stays loaded when left, until it is not; close undoes what it set up, when it unloads.
function clientEnv.loadInterface(name)
    if loaded[name] then return loaded[name] end
    local path = interfacePath .. name .. ".lua"
    local chunk, err = loadfile(path)
    if not chunk then return nil, err end
    local ok, m = pcall(chunk, gns, clientEnv, path)
    if not ok then return nil, m end
    loaded[name] = m
    return m
end
local function stub(screen, names)
    clientEnv.command(names, nil, function(args, line)
        local m, err = clientEnv.loadInterface(screen)
        if not m then error(err, 0) end
        local spec = commands[names[1]]
        if spec.screen then error(screen .. ".lua has no command " .. names[1], 0) end
        local ok, result = pcall(spec.fn, args, line)
        clientEnv.closeInterface(screen)
        if not ok then error(result, 0) end
        return result
    end, screen)
end
function clientEnv.closeInterface(name)
    local m = loaded[name]
    if not m or name == clientEnv.screen or (m.busy and m.busy()) then return end
    loaded[name] = nil
    if m.close then pcall(m.close) end
    for _, names in ipairs(COMMANDS[name] or {}) do stub(name, names) end
end
for _, s in ipairs({"gates", "chat", "access", "settings"}) do
    for _, names in ipairs(COMMANDS[s]) do stub(s, names) end
end
-- SHARE on Gates opens Chat's share dialog.
function clientEnv.openShare(rows)
    local m = clientEnv.loadInterface("chat")
    if m then m.openShare(rows) end
    clientEnv.closeInterface("chat")
end
-- The home gate: one gate of the address book (home on Dial dials it with its IDC).
function clientEnv.setHome(r)
    for _, x in ipairs(clientEnv.database) do x.home = nil end
    if r then r.home = true end
    clientEnv.changed()
    loom.invalidate()
end

-- A screen's frame, built by run(frame); a screen that fails shows why.
local function screenFrame(run)
    local frame = loom.widget.Frame(shell, R.x, R.y)
    frame:size(R.w, R.h)
    frame:backgroundColor(C.page)
    frame:visible(false)
    local ok, info = pcall(run, frame)
    if not ok then
        ui.Paint(frame, 1, 1, R.w, R.h, function(self)
            for i, line in ipairs(ui.wrap("This screen failed to load: " .. tostring(info), R.w - 4)) do
                self:text(3, i + 1, line, C.red, C.page)
            end
        end)
    end
    return frame, ok and type(info) == "table" and info or {}
end

-- Shows a screen and puts the focus on its first control. The screen left is dropped.
local SCREEN = {}
for _, s in ipairs(SCREENS) do SCREEN[s[1]] = true end
function clientEnv.show(name)
    if not SCREEN[name] then return end
    local old = clientEnv.screen
    clientEnv.screen = name
    -- A screen left closes while its widgets still stand (Destroy empties them).
    for n in pairs(loaded) do clientEnv.closeInterface(n) end
    if old ~= name and old ~= "dial" and frames[old] then
        frames[old]:Destroy(true)
        frames[old], screenInfo[old] = nil, nil
    end
    if not frames[name] then
        frames[name], screenInfo[name] = screenFrame(function(frame)
            local m, err = clientEnv.loadInterface(name)
            if not m then error(err, 0) end
            return m.build(frame, {w = R.w, h = R.h, wide = ui.wide})
        end)
    end
    for n, f in pairs(frames) do f:visible(n == name) f:enabled(n == name) end
    if name == "chat" then chat.unread = 0 end
    local first = screenInfo[name] and screenInfo[name].first
    if first then
        local w = type(first) == "function" and first() or first
        if w and w.focus then w:focus() end
    elseif loom.focused() then loom.focused():blur() end
    if screenInfo[name] and screenInfo[name].shown then screenInfo[name].shown() end
    loom.invalidate()
end
clientEnv.command({"go", "screen"}, "go <dial|gates|chat|access|settings|guide or 1-6>: show a screen", function(args)
    local want = args[1] and args[1]:lower()
    for i, s in ipairs(SCREENS) do
        if want == s[1] or want == tostring(i) or (want and s[1]:sub(1, #want) == want) then clientEnv.show(s[1]) return end
    end
    return "No screen " .. tostring(args[1]) .. "."
end)

-- The gate to dial from: the one chosen, else the nearest one that is not the destination (the
-- nearest of all when the destination is the only gate in range).
function clientEnv.fromGate()
    local list, dest = clientEnv.gateconnections, clientEnv.dest
    for _, c in ipairs(list) do if c == clientEnv.from then return c end end
    local best, other
    for _, c in ipairs(list) do
        local d = c.distance or math.huge
        if not best or d < (best.distance or math.huge) then best = c end
        local isDest = dest and ((dest.key and c.key == dest.key) or c.name == dest.Name)
        if not isDest and (not other or d < (other.distance or math.huge)) then other = c end
    end
    return other or best
end

local function build()
    for k in pairs(frames) do frames[k] = nil end
    for k in pairs(screenInfo) do screenInfo[k] = nil end
    clientEnv.onClose = {}
    local wide, W, H = ui.wide, ui.W, ui.H
    root = loom.widget.Frame()
    root:size(W, H)
    root:backgroundColor(C.page)
    shell = loom.widget.Frame(root, 1, 1)
    shell:size(W, H)
    shell:backgroundColor(C.page)
    clientEnv.root, clientEnv.shell = root, shell
    local navW = 20

    -- Top bar: on a computer the screen's name, on a tablet the screens as tabs (below); on the
    -- right the dialing gate's network and role, and the time.
    ui.Paint(shell, 1, 1, W, 1, function(self)
        self:fill(1, 1, W, 1, C.side)
        self:text(2, 1, wide and "◆ GNS" or "◆", C.amber, C.side)
        if wide then
            for _, s in ipairs(SCREENS) do if s[1] == clientEnv.screen then self:text(9, 1, s[3], C.dim, C.side) end end
        end
        local x = W - 6 - (gns.isRepeating and 10 or 0)
        -- The time, or under a fifth of this device's charge left, the charge in red.
        local most = computer.maxEnergy()
        local charge = most > 0 and computer.energy() / most or 1
        if charge < 0.2 then self:text(x, 1, ("▮%3d%%"):format(math.floor(charge * 100)), C.red, C.side)
        else self:text(x, 1, os.date("%H:%M"), C.dim, C.side) end
        local from = clientEnv.fromGate()
        if from and (wide or not gns.isRepeating) then
            local tag, colour, name = from.tag, from.tag == "public" and C.dim or C.amber, from.name
            if not wide and tag == "unregistered" then tag = "unreg" end
            x = x - unicode.len(tag) - 4
            self:tag(x, 1, tag, colour, C.side)
            if wide then
                name = ui.pad(name, 24):gsub("%s+$", "")
                self:text(x - unicode.len(name) - 1, 1, name, C.dim, C.side)
            end
        end
    end)
    if gns.isRepeating then
        ui.Button(shell, W - 9, 1, 9, 1, "RELOAD", C.red, C.black, function()
            gns.clientActive = false
            loom.stop()
        end, {around = C.side})
    end

    if wide then
        -- Side bar: the screens, then this device.
        ui.Paint(shell, 1, 2, navW, H - 2, function(self) self:fill(1, 1, navW, H - 2, C.side) end)
        local pitch = 4
        for i, s in ipairs(SCREENS) do
            local y = 3 + (i - 1) * pitch
            local b = ui.Button(shell, 1, y, navW - 1, 3, "", function()
                return s[1] == clientEnv.screen and C.head or C.side
            end, C.dim, function() clientEnv.show(s[1]) end, {around = C.side})
            b.draw = function(self)
                if not self:visible() then return end
                local here = s[1] == clientEnv.screen
                local bg = self:focused() and C.hover or (here and C.head or C.side)
                local gpu = require("loom.gpu")
                gpu.setBackground(bg)
                self:_gpufill(self:absX(), y, navW - 1, 3, " ")
                gpu.setForeground(C.faint)
                self:_gpuset(3, y + 1, tostring(i))
                gpu.setForeground((here or self:focused()) and C.text or C.dim)
                self:_gpuset(6, y + 1, s[2])
                if s[1] == "chat" and chat.unread > 0 then
                    gpu.setForeground(C.amber)
                    self:_gpuset(6 + unicode.len(s[2]) + 2, y + 1, "●" .. chat.unread)
                end
                if here then
                    gpu.setForeground(C.amber)
                    for r = y, y + 2 do self:_gpuset(1, r, "▌") end
                end
                return true
            end
        end
        ui.Paint(shell, 1, 1, navW, H - 1, function(self)
            local open = #clientEnv.gateconnections
            local dot = open > 0 and C.green or C.faint
            local y = H - 11
            self:text(3, y, "THIS DEVICE", C.faint, C.side)
            self:text(3, y + 1, ui.pad(deviceName, navW - 4), C.text, C.side)
            self:text(3, y + 2, clientVault:fingerprint():sub(1, 13), C.amber, C.side)
            self:text(3, y + 4, "●", dot, C.side)
            self:text(5, y + 4, ("%d gate%s in range"):format(open, open == 1 and "" or "s"), C.dim, C.side)
            local found = #chat.devices
            self:text(3, y + 5, "●", found > 0 and C.green or C.faint, C.side)
            self:text(5, y + 5, ("%d device%s found"):format(found, found == 1 and "" or "s"), C.dim, C.side)
        end)
    else
        -- On a tablet the screens are tabs along the top bar; the screen shown joins the page.
        local x = 4
        for i, s in ipairs(SCREENS) do
            local tx, w = x, unicode.len(s[2]) + 4
            local b = ui.Button(shell, tx, 1, w, 1, "", C.side, C.dim, function() clientEnv.show(s[1]) end, {around = C.side})
            b.draw = function(self)
                if not self:visible() then return end
                local here = s[1] == clientEnv.screen
                local gpu = require("loom.gpu")
                gpu.setBackground(self:focused() and C.hover or (here and C.page or C.side))
                self:_gpufill(tx, 1, w, 1, " ")
                local unread = s[1] == "chat" and chat.unread > 0
                gpu.setForeground(unread and C.amber or C.faint)
                self:_gpuset(tx + 1, 1, unread and "●" or tostring(i))
                gpu.setForeground(here and C.amber or (self:focused() and C.text or C.dim))
                self:_gpuset(tx + 3, 1, s[2])
                return true
            end
            x = x + w
        end
    end

    -- Bottom bar: the command bar, and this device's fingerprint.
    local print = "Device " .. clientVault:fingerprint()
    local cmdW = W - unicode.len(print) - 6
    ui.Paint(shell, 1, H, W, 1, function(self)
        self:fill(1, 1, W, 1, C.side)
        self:text(2, 1, ";", C.amber, C.side)
        self:text(W - unicode.len(print), 1, print, C.faint, C.side)
    end)
    -- Enter runs the line and leaves the bar, so number keys switch screens again.
    local cmd
    cmd = ui.Field(shell, 4, H, cmdW, {around = C.side, submit = function(line)
        cmd:text("")
        if line:match("%S") then
            if history[#history] ~= line then history[#history + 1] = line end
            if #history > 50 then table.remove(history, 1) end
        end
        runCommands(line)
    end})
    cmd:backgroundColor(C.side)
    local hint = wide and "Press ; for commands (help lists them)  ·  arrows, Tab, Enter move and press  ·  1-6 screens  ·  L log"
        or "; commands · Tab Enter · 1-6 screens · L log"
    -- The latest activity shows for 8 seconds, then the key hint.
    local placeholderDraw = cmd.draw
    cmd.draw = function(self)
        local recent = toast.text ~= "" and computer.uptime() - toast.at < 8
        self:placeholder(recent and toast.text or hint, recent and C.amber or C.faint)
        if recent then loom.invalidate(8 - (computer.uptime() - toast.at)) end
        return placeholderDraw(self)
    end
    -- Up and Down go through earlier commands.
    local at = nil
    local fieldKey = cmd._key
    cmd._key = function(self, char, code, ctrl, player)
        if code == 200 or code == 208 then
            if #history == 0 then return true end
            at = at or (#history + 1)
            at = math.max(1, math.min(#history + 1, at + (code == 200 and -1 or 1)))
            self:text(history[at] or "")
            return true
        end
        if code == 28 or code == 156 then at = nil end
        return fieldKey(self, char, code, ctrl, player)
    end
    clientEnv.commandBar = cmd
    -- Prefills the command bar (for edit) and starts typing there.
    -- (After the running command's Enter has left the bar.)
    function clientEnv.prefill(text)
        event.timer(0, function()
            cmd:text(text)
            cmd:focus()
            loom.invalidate()
        end)
    end

    -- Dial, built with every layout; show builds the screen in use.
    R = wide and {x = navW + 3, y = 3, w = W - navW - 4, h = H - 4} or {x = 2, y = 3, w = W - 2, h = H - 4}
    local path = interfacePath .. "dial.lua"
    frames.dial, screenInfo.dial = screenFrame(function(frame)
        return assert(loadfile(path))(gns, clientEnv, path, frame, {w = R.w, h = R.h, wide = wide})
    end)
    clientEnv.show(clientEnv.screen)
    return root
end

-- Keys no control used: 1-6 screens, ; the command bar, L the activity log, Q quit.
loom.onKey(function(char, code, player)
    if ui.keyBeforeFocus(char, code, player) then return end
    if code == 1 then -- Escape: drop the focus (closes nothing)
        local f = loom.focused()
        if f then f:blur() end
        return
    end
    if ui.modalOpen() then return end
    if char == 59 then clientEnv.commandBar:focus() return end
    local n = char - 48
    if SCREENS[n] then clientEnv.show(SCREENS[n][1]) return end
    if char == 108 or char == 76 then clientEnv.showLog() return end
    if char == 113 or char == 81 then gns.clientActive = false loom.stop() end
end)

-- Changing the layout builds the screens again at the new size.
local rebuild = false
function clientEnv.relayout()
    rebuild = true
    loom.stop()
end

-- Undoes what this client run set up on the computer. In the client's bucket, so it runs when
-- the client quits and, through QuickOS, when it crashes: a crashed client's listeners and timers
-- would otherwise stay, and the next client on this computer would run beside them.
local built = false -- root is up: its onClose hooks and listeners are still to undo
local function closeClient()
    if built then
        built = false
        for _, fn in ipairs(clientEnv.onClose) do pcall(fn) end
        pcall(root.Destroy, root, true) -- a root frame's Destroy also unregisters its screen event listeners
    end
    for name, m in pairs(loaded) do
        loaded[name] = nil
        if m.close then pcall(m.close) end
    end
    loom.onKey(nil)
    if saveTimer then event.cancel(saveTimer) end
    event.cancel(sleepTimer)
    event.ignore("key_down", onKey)
    event.ignore("touch", onTouch)
    pcall(clientEnv.peer.stop)
    clientEnv.link.stop()
    local saved, saveError = clientVault:save()
    clientVault:lock()
    component.gpu.freeAllBuffers()
    component.gpu.setBackground(0x000000)
    component.gpu.setForeground(0xFFFFFF)
    local maxW, maxH = component.gpu.maxResolution()
    component.gpu.setResolution(maxW, maxH)
    term.clear()
    print(saved and "Closed GNS client" or ("Closed GNS client, but the vault was not saved: " .. tostring(saveError)))
end
clientEnv.bucket:add({close = closeClient})

-- The session: gns.lua runs it once this file has finished. A file still running keeps all of its
-- code loaded and whatever its locals last held, so the setup above is freed while the client runs.
return function()
    clientEnv.log("GNS client ready. Press ; for commands; SCAN finds the gates in range.")
    while gns.clientActive do
        rebuild = false
        component.gpu.freeAllBuffers()
        ui.setLayout(settings.layout)
        build()
        built = true
        loom.run(root, 0.5)
        built = false
        for _, fn in ipairs(clientEnv.onClose) do pcall(fn) end
        root:Destroy(true)
        if not rebuild then break end
    end
    clientEnv.bucket:close()
end
