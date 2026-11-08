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
event.listen("interrupted", function()
    gns.isRepeating = false
    gns.clientActive = false
    if package.loaded.loom then package.loaded.loom.stop() end
    for i,_ in pairs (package.loaded) do if i:match("^loom") then package.loaded[i] = nil end end
    package.loaded.ecc = nil
    return false
end)

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
clientEnv.gateconnections = {} -- open gate connections, nearest first once scanned

local modem = component.modem
local readFile = gns.utility.readFile
local writeFile = gns.utility.writeFile

-- The vault also holds pinned gate keys, signed gate entries and private network memberships.
local vaultState = clientVault.state
vaultState.pins, vaultState.book, vaultState.networks = vaultState.pins or {}, vaultState.book or {}, vaultState.networks or {}
local database = vaultState.database
clientEnv.database = database
clientEnv.vault = clientVault

local settingsPath = gns.path.clientDirectory .. "settings.lua"
-- Client settings, changed on the Settings screen or with set. Unknown or mistyped saved values
-- are ignored.
local settings = {
    fastDial = true, -- press the gate's DHD instead of spinning the ring
    autoLogToDatabase = true, -- add gates learned from scans to the address book
    nearbyScanRate = 30, -- seconds between automatic scans for gates; 0 turns them off
    modemRange = 400, -- wireless strength in blocks (16 to 400)
    autoAcceptShared = false, -- take gates shared by other devices without asking
    chatBlacklist = {}, -- device fingerprint -> true: their chat and shares are dropped
    layout = "auto", -- "auto", "compact" (80x25) or "wide" (160x50)
}
clientEnv.settings = settings

local function applySettings()
    settings.modemRange = math.min(math.max(math.floor(tonumber(settings.modemRange) or 400), 16), 400)
    settings.nearbyScanRate = math.min(math.max(math.floor(tonumber(settings.nearbyScanRate) or 0), 0), 600)
    if settings.layout ~= "compact" and settings.layout ~= "wide" then settings.layout = "auto" end
    if modem.setStrength then modem.setStrength(settings.modemRange) end
end
function clientEnv.saveSettings()
    applySettings()
    writeFile(settingsPath, "return " .. serialization.serialize(settings, math.huge))
end
readFile(settingsPath, function(saved)
    if type(saved) ~= "table" then return end
    for name, value in pairs(saved) do
        if settings[name] ~= nil and type(settings[name]) == type(value) then settings[name] = value end
    end
end)
clientEnv.saveSettings()

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

-- Edits are saved to the vault a few seconds after the last one (a save encrypts the whole
-- vault, so a burst of edits costs one), and when the client closes.
local dirty = false
function clientEnv.changed() dirty = true end
local saveTimer = event.timer(5, function()
    if not dirty then return end
    dirty = false
    local saved, err = clientVault:save()
    if not saved then clientEnv.log("Vault not saved: " .. tostring(err)) end
end, math.huge)

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

---------------------------------------------------------------------------- chat
-- The peer service runs while the client is open, so chat lines and shared gates arrive whatever
-- screen is showing. Entries: {time, text, who, mine}; notes have no who.
local peer = dofile(gns.path.gns .. "peer.lua")
local entries = dofile(gns.path.gns .. "entries.lua")
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
function chat.accept(share)
    pcall(entries.mergeAll, vaultState.book, share.signed, nil)
    local added, codes = 0, 0
    for _, row in ipairs(share.rows) do
        local mw, existing = table.concat(row.Address.MW, ","), nil
        for _, known in ipairs(database) do
            if known.Name == row.Name and table.concat((known.Address or {}).MW or {}, ",") == mw then existing = known break end
        end
        if existing then
            existing.IDCs = existing.IDCs or {}
            for _, code in ipairs(row.IDCs) do
                local have = false
                for _, c in ipairs(existing.IDCs) do if c == code then have = true break end end
                if not have then existing.IDCs[#existing.IDCs + 1] = code codes = codes + 1 end
            end
        else
            database[#database + 1] = row
            added, codes = added + 1, codes + #row.IDCs
        end
    end
    clientVault:save()
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
        local share = {from = from, rows = rows, signed = signed}
        if settings.autoAcceptShared then
            chat.show(("%s shared %d gates%s; %d added to the address book."):format(chat.label(from), #rows,
                chat.hasIDCs(share) and " with IDCs" or "", (chat.accept(share))))
        else
            chat.pending[#chat.pending + 1] = share
            if clientEnv.screen ~= "chat" then chat.unread = chat.unread + 1 end
            chat.show(("%s shared %d gates%s. Accept or refuse them under Shared With You."):format(chat.label(from), #rows,
                chat.hasIDCs(share) and " with their IDCs" or ""))
        end
    end,
})

---------------------------------------------------------------------------- commands
-- The command bar: ; focuses it. Commands are separated by ;, words by spaces. Each screen adds
-- its own: clientEnv.command(names, usage, fn(args, line)); fn returns the text to report.
local commands, commandOrder = {}, {}
function clientEnv.command(names, usage, fn)
    local spec = {names = names, usage = usage, fn = fn}
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
    if spec then return spec.usage .. (#spec.names > 1 and ("  (also " .. table.concat(spec.names, ", ", 2) .. ")") or "") end
    local names = {}
    for _, s in ipairs(commandOrder) do names[#names + 1] = s.names[1] end
    return "Commands: " .. table.concat(names, ", ") .. ". help <command> shows one. Gates are numbers in the address book or names (_ for spaces)."
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
    local field, choice
    local function finish(fn)
        local result
        if field then result = field:text() elseif choice then result = opts.options.list[choice] end
        close()
        if fn then
            local ok, err = pcall(fn, result)
            if not ok then clientEnv.log("Error: " .. tostring(err)) end
        end
    end
    local y = 4 + #lines
    if opts.text then
        field = ui.Field(frame, 3, y, w - 4, {text = tostring(opts.text), mask = opts.mask, submit = function() finish(confirm) end})
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

---------------------------------------------------------------------------- the shell
local SCREENS = {
    {"dial", "DIAL", "Dial"}, {"gates", "GATES", "Address book"}, {"chat", "CHAT", "Chat & share"},
    {"networks", "NETWORKS", "Networks"}, {"settings", "SETTINGS", "Settings"}, {"guide", "GUIDE", "Guide"},
}
local frames, screenInfo = {}, {}
clientEnv.screen = "dial"
-- Shows a screen and puts the focus on its first control.
function clientEnv.show(name)
    if not frames[name] then return end
    clientEnv.screen = name
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
clientEnv.command({"go", "screen"}, "go <dial|gates|chat|networks|settings|guide or 1-6>: show a screen", function(args)
    local want = args[1] and args[1]:lower()
    for i, s in ipairs(SCREENS) do
        if want == s[1] or want == tostring(i) or (want and s[1]:sub(1, #want) == want) then clientEnv.show(s[1]) return end
    end
    return "No screen " .. tostring(args[1]) .. "."
end)

-- The role this device holds in a network it belongs to.
local networks = dofile(gns.path.gns .. "networks.lua")
function clientEnv.roleOf(net)
    return networks.check(net.network, net.revoked, net.membership, vaultState.identity.public) or "revoked"
end
-- The gate to dial from: the one chosen, else the nearest open one.
function clientEnv.fromGate()
    local list = clientEnv.gateconnections
    for _, c in ipairs(list) do if c == clientEnv.from then return c end end
    local best
    for _, c in ipairs(list) do
        if not best or (c.distance or math.huge) < (best.distance or math.huge) then best = c end
    end
    return best
end

local interfacePath = gns.path.clientDirectory .. "interface/"
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
    local navW = wide and 20 or 15

    -- Top bar: the screen's name; on the right the dialing gate's network and role, and the time.
    ui.Paint(shell, 1, 1, W, 1, function(self)
        self:fill(1, 1, W, 1, C.side)
        self:text(2, 1, "◆ GNS", C.amber, C.side)
        for _, s in ipairs(SCREENS) do if s[1] == clientEnv.screen then self:text(9, 1, s[3], C.dim, C.side) end end
        local x = W - 6 - (gns.isRepeating and 10 or 0)
        self:text(x, 1, os.date("%H:%M"), C.dim, C.side)
        local from = clientEnv.fromGate()
        if from then
            local tag, colour, name = "public", C.dim, from.name
            if from.net then tag, colour, name = clientEnv.roleOf(from.net), C.amber, from.net.name or from.name end
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

    -- Side bar: the screens, then this device.
    ui.Paint(shell, 1, 2, navW, H - 2, function(self) self:fill(1, 1, navW, H - 2, C.side) end)
    local pitch = wide and 4 or 3
    for i, s in ipairs(SCREENS) do
        local y = 3 + (i - 1) * pitch
        local b = ui.Button(shell, 1, y, navW - 1, 3, "", function()
            return s[1] == clientEnv.screen and C.head or C.side
        end, C.dim, function() clientEnv.show(s[1]) end, {around = C.side})
        b.isNav = true
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
        if wide then
            local y = H - 11
            self:text(3, y, "THIS DEVICE", C.faint, C.side)
            self:text(3, y + 1, ui.pad(deviceName, navW - 4), C.text, C.side)
            self:text(3, y + 2, clientVault:fingerprint():sub(1, 13), C.amber, C.side)
            self:text(3, y + 4, "●", dot, C.side)
            self:text(5, y + 4, ("%d gate%s in range"):format(open, open == 1 and "" or "s"), C.dim, C.side)
            local found = #chat.devices
            self:text(3, y + 5, "●", found > 0 and C.green or C.faint, C.side)
            self:text(5, y + 5, ("%d device%s found"):format(found, found == 1 and "" or "s"), C.dim, C.side)
        else
            self:text(2, H - 2, "●", dot, C.side)
            self:text(4, H - 2, ("%d in range"):format(open), C.dim, C.side)
        end
    end)

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
    local hint = wide and "Press ; for commands (help lists them)  ·  arrows, Tab, Enter move and press  ·  1-6 screens"
        or "; commands · arrows Tab Enter · 1-6 screens"
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

    -- The screens.
    local R = {x = navW + 3, y = 3, w = W - navW - (wide and 4 or 3), h = H - 4}
    for _, s in ipairs(SCREENS) do
        local frame = loom.widget.Frame(shell, R.x, R.y)
        frame:size(R.w, R.h)
        frame:backgroundColor(C.page)
        frame:visible(false)
        -- Only the shown screen takes touches: a frame passes a touch to the last child under
        -- it, hidden or not, and all six screens cover the same cells.
        frame.checkCollision = function(self, x, y)
            return self:visible() and loom.widget.Frame.checkCollision(self, x, y)
        end
        frames[s[1]] = frame
        local path = interfacePath .. s[1] .. ".lua"
        local loaded, err = loadfile(path)
        local ok, info = false, err
        if loaded then ok, info = pcall(loaded, gns, clientEnv, path, frame, {w = R.w, h = R.h, wide = wide}) end
        if ok then
            screenInfo[s[1]] = type(info) == "table" and info or {}
        else
            ui.Paint(frame, 1, 1, R.w, R.h, function(self)
                for i, line in ipairs(ui.wrap("This screen failed to load: " .. tostring(info), R.w - 4)) do
                    self:text(3, i + 1, line, C.red, C.page)
                end
            end)
        end
    end
    clientEnv.show(clientEnv.screen)
    return root
end

-- Keys no control used: 1-6 screens, ; the command bar, Q quit.
loom.onKey(function(char, code)
    if code == 1 then -- Escape: drop the focus (closes nothing)
        local f = loom.focused()
        if f then f:blur() end
        return
    end
    if ui.modalOpen() then return end
    if char == 59 then clientEnv.commandBar:focus() return end
    local n = char - 48
    if SCREENS[n] then clientEnv.show(SCREENS[n][1]) return end
    if char == 113 or char == 81 then gns.clientActive = false loom.stop() end
end)

-- Changing the layout builds the screens again at the new size.
local rebuild = false
function clientEnv.relayout()
    rebuild = true
    loom.stop()
end

clientEnv.log("GNS client ready. Press ; for commands; SCAN finds the gates in range.")
while gns.clientActive do
    rebuild = false
    component.gpu.freeAllBuffers()
    ui.setLayout(settings.layout)
    build()
    loom.run(root, 0.5)
    for _, fn in ipairs(clientEnv.onClose) do pcall(fn) end
    root:Destroy(true) -- a root frame's Destroy also unregisters its screen event listeners
    if not rebuild then break end
end

loom.onKey(nil)
event.cancel(saveTimer)
pcall(clientEnv.peer.stop)
for _, connection in ipairs(clientEnv.gateconnections) do pcall(connection.proxy.close, connection.proxy) end
local saved, saveError = clientVault:save()
clientVault:lock()
component.gpu.freeAllBuffers()
component.gpu.setBackground(0x000000)
component.gpu.setForeground(0xFFFFFF)
local maxW, maxH = component.gpu.maxResolution()
component.gpu.setResolution(maxW, maxH)
term.clear()
print(saved and "Closed GNS client" or ("Closed GNS client, but the vault was not saved: " .. tostring(saveError)))
