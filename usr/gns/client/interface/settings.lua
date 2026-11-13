-- Settings screen: the client settings, saved as soon as they change; this device's
-- fingerprint and password; address book backups; the devices blocked from chat and sharing.
--
-- Commands: set, get, backup, backups, restore, profile.
local gns, clientEnv, _, frame, R = ...
local ui = clientEnv.ui
local C = ui.C
local computer = require("computer")
local vaultModule = clientEnv.vaultModule
local settings = clientEnv.settings
local log = clientEnv.log
local wide = R.wide
local LAYOUTS = {"auto", "compact", "wide"}

local function save() clientEnv.saveSettings() end
local function step(name, by, min, max)
    settings[name] = math.max(min, math.min(max, (settings[name] or 0) + by))
    save()
end
local function setLayout(layout)
    if layout == settings.layout then return end
    settings.layout = layout
    save()
    clientEnv.relayout()
end
local function cycleLayout(by)
    for i, l in ipairs(LAYOUTS) do
        if l == settings.layout then return setLayout(LAYOUTS[(i - 1 + by) % #LAYOUTS + 1]) end
    end
end

-- Asks for the current password, then the new one twice, and re-keys the vault.
local function changePassword()
    clientEnv.ask("Current password", {text = "", mask = "*", title = "PASSWORD"}, function(old)
        if not old then return end
        local opened, reason = vaultModule.open(gns.path.clientDirectory .. "vault", old)
        if not opened then log("Password not changed: " .. tostring(reason)) return end
        opened:lock()
        clientEnv.ask("New password", {text = "", mask = "*", title = "PASSWORD"}, function(new)
            if not new or new == "" then log("The password cannot be empty; nothing changed.") return end
            clientEnv.ask("Repeat the new password", {text = "", mask = "*", title = "PASSWORD"}, function(again)
                if again ~= new then log("The passwords do not match; nothing changed.") return end
                local ok, err = clientEnv.vault:changePassword(new)
                log(ok and "Password changed." or ("Not changed: " .. tostring(err)))
            end)
        end)
    end)
end

local function blocked()
    local list = {}
    for fingerprint in pairs(settings.chatBlacklist) do list[#list + 1] = fingerprint end
    table.sort(list)
    return list
end
-- A new gate port: the client hears that port's off-world alarms and opens its gates. The old
-- port closes, so its network's alarms stop, unless a profile, invitations (invite.PORT, 161),
-- chat (peer.PORT, 162), disco or the gate on this computer still use it.
local function setPort(port)
    local old, modem = settings.port, require("component").modem
    settings.port = port
    save()
    local gate = (package.loaded["gns.here"] or {}).gate
    if old ~= port and not clientEnv.ports()[old] and old ~= 161 and old ~= 162 and old ~= require("disco").port
        and not (gate and gate.port and gate.port() == old) then
        pcall(modem.close, old)
    end
    pcall(modem.open, settings.port)
end

---------------------------------------------------------------------------- the screen
local aw = wide and 66 or R.w
ui.card(frame, 1, 1, aw, 12, "DIALING AND SCANNING", nil, function(self)
    for i, r in ipairs({{"Fast dial", "press the gate's DHD (under 25 s)"},
        {"Learn gates from scans", "add the gates found in range to the address book"},
        {"Take shared gates", "without asking first"}}) do
        local y = i * 2
        self:text(3, y, r[1], C.text, C.card)
        self:text(3, y + 1, ui.pad(r[2], i == 1 and aw - 28 or aw - 14), C.faint, C.card)
    end
    self:text(3, 8, "Rescan every", C.text, C.card)
    self:text(3, 9, "Wireless range", C.text, C.card)
    self:text(3, 10, "Layout", C.text, C.card)
    self:text(3, 11, "Show addresses, IDCs", C.text, C.card)
    self:text(3, 12, "Gate port", C.text, C.card)
end)
local first = ui.toggle(frame, aw - 9, 2, function() return settings.fastDial end, function(v) settings.fastDial = v save() end)
ui.toggle(frame, aw - 9, 4, function() return settings.autoLogToDatabase end, function(v) settings.autoLogToDatabase = v save() end)
ui.toggle(frame, aw - 9, 6, function() return settings.autoAcceptShared end, function(v) settings.autoAcceptShared = v save() end)
local cx = aw - 25
-- How long a whole dial takes, as on GDS: the glyphs are spread over it; 0 is the fastest.
ui.chooser(frame, cx, 3, 24, function() return settings.dialSpeed == 0 and "fastest" or ("dial in " .. settings.dialSpeed .. " s") end,
    function() step("dialSpeed", -5, 0, 120) end, function() step("dialSpeed", 5, 0, 120) end)
ui.chooser(frame, cx, 8, 24, function() return settings.nearbyScanRate == 0 and "off" or (settings.nearbyScanRate .. " s") end,
    function() step("nearbyScanRate", -10, 0, 600) end, function() step("nearbyScanRate", 10, 0, 600) end)
ui.chooser(frame, cx, 9, 24, function() return settings.modemRange .. " blocks" end,
    function() step("modemRange", -16, 16, 400) end, function() step("modemRange", 16, 16, 400) end)
ui.chooser(frame, cx, 10, 24, function()
    return settings.layout == "auto" and ("auto: " .. (ui.wide and "wide" or "compact")) or settings.layout
end, function() cycleLayout(-1) end, function() cycleLayout(1) end)
ui.toggle(frame, aw - 9, 11, function() return settings.showCodes end, function(v) settings.showCodes = v save() end)
ui.chooser(frame, cx, 12, 24, function() return tostring(settings.port) end,
    function() setPort(math.max(1, settings.port - 1)) end, function() setPort(math.min(65535, settings.port + 1)) end)

local bx, by, bw, bh = 1, 14, R.w, R.h - 13
if wide then bx, by, bw, bh = 69, 1, R.w - 68, R.h end
local nameRow = wide and 5 or 3
local blockedRow = nameRow + (wide and 3 or 2)
ui.card(frame, bx, by, bw, bh, "THIS DEVICE", nil, function(self)
    self:text(3, 2, "Fingerprint", C.faint, C.card)
    self:text(16, 2, clientEnv.vault:fingerprint(), C.amber, C.card)
    if wide then self:text(3, 3, "Others see it in chat, shares and invitations.", C.faint, C.card) end
    self:text(3, nameRow, "Name", C.faint, C.card)
    self:text(16, nameRow, ui.pad(clientEnv.deviceName, bw - 32), C.text, C.card)
    self:text(3, nameRow + 1, "Vault", C.faint, C.card)
    self:text(16, nameRow + 1, ui.pad(("%d gates, %d grants held"):format(#clientEnv.database, #clientEnv.vault.state.grants), bw - 32), C.text, C.card)
    self:text(3, blockedRow, "BLOCKED DEVICES", C.faint, C.card)
end)
ui.Button(frame, bx + bw - 14, by + nameRow - 1, 12, 1, "PASSWORD", C.amber, C.black, changePassword)
local ly = by + blockedRow
ui.Button(frame, bx + bw - 14, by + nameRow, 12, 1, "BACKUPS", C.raised, C.text, function() clientEnv.showBackups() end)
ui.Button(frame, bx + bw - 14, by + nameRow + 1, 12, 1, "PROFILES", C.raised, C.text, function() clientEnv.showProfiles() end)
local blockedList = ui.List(frame, bx, ly, bw - 16, bh - blockedRow - 1, {items = blocked,
    empty = "Nobody. BLOCK on Chat stops a device's chat and shares.",
    cells = function(fp) return {{2, fp, C.text}} end})
ui.Button(frame, bx + bw - 14, ly, 12, 1, "UNBLOCK", C.green, C.black, function()
    local fp = blockedList:cursorItem()
    if not fp then return end
    settings.chatBlacklist[fp] = nil
    save()
    log("Unblocked " .. fp .. ".")
end)

---------------------------------------------------------------------------- backups
-- Dated copies of the address book in backups/, sealed under the vault password like the vault
-- itself. Only the newest KEEP are kept, so they never fill the disk. A copy is named
-- book-<yyyymmdd>-<hhmmss>-<nn>-<gates> (nn tells apart copies made in the same second), so
-- listing them reads no file. That date is the world's, which /time set moves back: the copies are
-- ordered by when the disk wrote them.
local fs = require("filesystem")
local BACKUPS, KEEP = gns.path.clientDirectory .. "backups/", 10
local copies -- the list, newest first; read again after a backup
local function backups()
    if copies then return copies end
    copies = {}
    for name in (fs.exists(BACKUPS) and fs.list(BACKUPS) or function() end) do
        local d, t, n = name:match("^book%-(%d%d%d%d%d%d%d%d)%-(%d%d%d%d%d%d)%-%d%d%-(%d+)$")
        if d then
            copies[#copies + 1] = {name = name, gates = tonumber(n), at = fs.lastModified(BACKUPS .. name),
                when = ("%s-%s-%s %s:%s"):format(d:sub(1, 4), d:sub(5, 6), d:sub(7, 8), t:sub(1, 2), t:sub(3, 4))}
        end
    end
    table.sort(copies, function(a, b) if a.at ~= b.at then return a.at > b.at end return a.name > b.name end)
    return copies
end
local function backup()
    fs.makeDirectory(BACKUPS)
    local stamp, taken = os.date("%Y%m%d-%H%M%S"), {}
    for _, c in ipairs(backups()) do taken[c.name:match("^book%-(%d+%-%d+%-%d%d)%-")] = true end
    local seq = 1
    while taken[("%s-%02d"):format(stamp, seq)] and seq < 99 do seq = seq + 1 end
    local name = ("book-%s-%02d-%d"):format(stamp, seq, #clientEnv.database)
    local ok, err = clientEnv.vault:writeCopy(BACKUPS .. name, {database = clientEnv.database})
    copies = nil
    if not ok then return "Backup failed: " .. tostring(err) end
    for i = KEEP + 1, #backups() do fs.remove(BACKUPS .. copies[i].name) end
    copies = nil
    return ("Backed up the address book: %d gates (%d backups kept)."):format(#clientEnv.database, #backups())
end
-- Puts a copy's gates in place of the address book's. A copy made under an older password asks
-- for that password.
local function restore(copy, password)
    local saved, err = clientEnv.vault:readCopy(BACKUPS .. copy.name, password)
    if not saved and err == "older password" then
        clientEnv.ask("This backup was made under an older password. Enter that password.", {text = "", mask = "*", title = "RESTORE"},
            function(old) if old then restore(copy, old) end end)
        return
    end
    if not saved or type(saved.database) ~= "table" then log("Not restored: " .. tostring(err or "damaged backup")) return end
    local database = clientEnv.database
    for i = #database, 1, -1 do database[i] = nil end
    for i, row in ipairs(saved.database) do database[i] = row end
    clientEnv.changed()
    log(("Restored the address book from the backup of %s: %d gates."):format(copy.when, #database))
end
local function askRestore(copy)
    clientEnv.ask(("Replace the address book (%d gates) with the backup of %s (%d gates)?"):format(#clientEnv.database, copy.when, copy.gates),
        {title = "RESTORE"}, function() restore(copy) end)
end
function clientEnv.showBackups()
    if ui.modalOpen() then return end
    copies = nil
    local w, h = math.min(ui.W - 4, 56), math.min(ui.H - 2, 19)
    local box, close = ui.modal(clientEnv.root, clientEnv.shell, w, h, "BACKUPS")
    local list = ui.List(box, 2, 3, w - 2, h - 7, {items = backups, empty = "No backups yet. BACKUP saves one.",
        cells = function(c) return {{2, c.when, C.text}, {20, c.gates .. " gates", C.dim}} end})
    ui.Paint(box, 3, h - 3, w - 4, 1, function(self)
        self:text(1, 1, ui.pad(("The newest %d are kept, encrypted like the vault."):format(KEEP), w - 4), C.faint, C.card)
    end)
    local bw = (w - 10) // 3
    ui.Button(box, 3, h - 1, bw, 1, "BACKUP", C.green, C.black, function() log(backup()) end)
    ui.Button(box, 5 + bw, h - 1, bw, 1, "RESTORE", C.amber, C.black, function()
        local copy = list:cursorItem()
        if not copy then return end
        close()
        askRestore(copy)
    end)
    ui.Button(box, 7 + 2 * bw, h - 1, bw, 1, "CLOSE", C.raised, C.text, close)
    ui.focusSoon(list)
end
clientEnv.command({"backup"}, "backup: save a copy of the address book (the newest " .. KEEP .. " are kept)", function() return backup() end)
clientEnv.command({"backups"}, "backups: the address book backups, newest first", function()
    copies = nil
    local lines = {}
    for i, c in ipairs(backups()) do lines[#lines + 1] = ("%d. %s, %d gates"):format(i, c.when, c.gates) end
    return #lines > 0 and table.concat(lines, "; ") or "No backups yet. backup saves one."
end)
clientEnv.command({"restore"}, "restore <n>: put backup n (from backups) in place of the address book, after asking", function(args)
    copies = nil
    local copy = backups()[math.tointeger(tonumber(args[1])) or 0]
    if not copy then return "Usage: restore <n>, n from backups" end
    askRestore(copy)
end)

---------------------------------------------------------------------------- network profiles
-- A profile is a name, a port and the gates that belong to it (client.lua keeps them in the vault
-- and listens on their ports). Using one shows only its gates in the address book and on Dial.
local profiles = clientEnv.vault.state.profiles
local function profileNamed(name)
    local want = tostring(name or ""):gsub("_", " "):lower()
    for i, p in ipairs(profiles) do if p.name:lower() == want then return p, i end end
end
local function members(p)
    local n = 0
    for _, r in ipairs(clientEnv.database) do if (r.Profiles or {})[p.name] then n = n + 1 end end
    return n
end
local function newProfile(name, port)
    name, port = tostring(name or ""):gsub("_", " "):match("^%s*(.-)%s*$"), math.tointeger(tonumber(port))
    if name == "" or not port or port < 1 or port > 65535 then return "A profile needs a name and a port (1-65535)." end
    if profileNamed(name) then return "There is a profile " .. name .. " already." end
    profiles[#profiles + 1] = {name = name, port = port}
    clientEnv.changed()
    clientEnv.listen()
    return ("Profile %s on port %d. Gates opened on that port join it; profile add puts others in."):format(name, port)
end
local function useProfile(p)
    settings.profile = p and p.name or ""
    save()
    require("loom").invalidate()
    return p and ("Showing %s's %d gates."):format(p.name, members(p)) or "Showing every gate."
end
local function setMember(p, r, on)
    r.Profiles = r.Profiles or {}
    r.Profiles[p.name] = on or nil
    if next(r.Profiles) == nil then r.Profiles = nil end
    clientEnv.changed()
end
local function deleteProfile(p)
    local _, i = profileNamed(p.name)
    if i then table.remove(profiles, i) end
    for _, r in ipairs(clientEnv.database) do
        if r.Profiles then setMember(p, r, false) end
    end
    if settings.profile == p.name then useProfile(nil) end
    clientEnv.changed()
    return "Deleted the profile " .. p.name .. " (its gates stay in the address book)."
end
-- Every gate of the address book, ticked when it belongs to p; Enter or a touch ticks it.
local function profileGates(p)
    local w, h = math.min(ui.W - 4, 56), math.min(ui.H - 2, 21)
    local box, close = ui.modal(clientEnv.root, clientEnv.shell, w, h, "GATES · " .. p.name)
    local list = ui.List(box, 2, 3, w - 2, h - 6, {items = clientEnv.database, empty = "The address book is empty.",
        cells = function(r)
            return {{2, (r.Profiles or {})[p.name] and "■" or "□", C.amber}, {5, ui.pad(r.Name, w - 14)}, {w - 8, tostring(r.Type or ""), C.dim}}
        end,
        press = function(r) setMember(p, r, not (r.Profiles or {})[p.name]) end})
    ui.Paint(box, 3, h - 2, w - 16, 1, function(self)
        self:text(1, 1, ui.pad(("%d gates in %s · Enter ticks one"):format(members(p), p.name), w - 16), C.faint, C.card)
    end)
    ui.Button(box, w - 11, h - 1, 10, 1, "CLOSE", C.raised, C.text, close)
    ui.focusSoon(list)
end
function clientEnv.showProfiles()
    if ui.modalOpen() then return end
    local w, h = math.min(ui.W - 4, 60), math.min(ui.H - 2, 17)
    local box, close = ui.modal(clientEnv.root, clientEnv.shell, w, h, "NETWORK PROFILES")
    local list = ui.List(box, 2, 3, w - 2, h - 7, {items = profiles, empty = "No profiles: every gate shows. NEW makes one.",
        selected = function(p) return p.name == settings.profile end,
        cells = function(p) return {{2, ui.pad(p.name, w - 30)}, {w - 27, "port " .. p.port, C.dim}, {w - 15, members(p) .. " gates", C.dim}} end})
    ui.Paint(box, 3, h - 3, w - 4, 1, function(self)
        local p = clientEnv.profile()
        self:text(1, 1, ui.pad(p and ("Showing only " .. p.name .. "'s gates.") or "Showing every gate. USE shows only a profile's.", w - 4), C.faint, C.card)
    end)
    local bw = (w - 14) // 5
    local function chosen(fn)
        return function()
            local p = list:cursorItem()
            if p then fn(p) end
        end
    end
    ui.Button(box, 3, h - 1, bw, 1, "NEW", C.green, C.black, function()
        close()
        clientEnv.ask("Name of the new profile", {text = "", title = "PROFILE"}, function(name)
            if not name or not name:match("%S") then return end
            clientEnv.ask("Its port (the gates of that network listen on it)", {text = tostring(settings.port), title = "PROFILE"}, function(port)
                if port then log(newProfile(name, port)) end
            end)
        end)
    end)
    ui.Button(box, 5 + bw, h - 1, bw, 1, function()
        local p = list:cursorItem()
        return p and p.name == settings.profile and "ALL" or "USE"
    end, C.amber, C.black, chosen(function(p) log(useProfile(p.name ~= settings.profile and p or nil)) end))
    ui.Button(box, 7 + 2 * bw, h - 1, bw, 1, "GATES", C.raised, C.text, chosen(function(p) close() profileGates(p) end))
    ui.Button(box, 9 + 3 * bw, h - 1, bw, 1, "DELETE", C.red, C.black, chosen(function(p)
        close()
        clientEnv.ask(("Delete the profile %s? Its gates stay in the address book."):format(p.name), {title = "DELETE"},
            function() log(deleteProfile(p)) end)
    end))
    ui.Button(box, 11 + 4 * bw, h - 1, bw, 1, "CLOSE", C.raised, C.text, close)
    ui.focusSoon(list)
end
local PROFILE_USAGE = "Usage: profile new <name> <port> | use <name>|all | add|remove <name> <gate> ... | delete <name>"
clientEnv.command({"profile", "pf"}, "profile: the network profiles; profile new <name> <port>, use <name>|all, add|remove <name> <gate> ..., delete <name>", function(args)
    local word = (args[1] or ""):lower()
    if word == "" then
        local lines = {}
        for _, p in ipairs(profiles) do
            lines[#lines + 1] = ("%s%s: port %d, %d gates"):format(p.name, p.name == settings.profile and " (in use)" or "", p.port, members(p))
        end
        return #lines > 0 and table.concat(lines, "; ") or "No profiles: every gate shows. profile new <name> <port> makes one."
    elseif word == "new" then
        return newProfile(args[2], args[3])
    elseif word == "use" then
        if (args[2] or ""):lower() == "all" then return useProfile(nil) end
        local p = profileNamed(args[2])
        return p and useProfile(p) or ("No profile " .. tostring(args[2]) .. ".")
    end
    local p = profileNamed(args[2])
    if not p then return PROFILE_USAGE end
    if word == "delete" then return deleteProfile(p) end
    if word ~= "add" and word ~= "remove" then return PROFILE_USAGE end
    local done = {}
    for i = 3, #args do
        local r = clientEnv.findEntry(args[i])
        if not r then return "No gate " .. args[i] .. " in the address book." end
        setMember(p, r, word == "add")
        done[#done + 1] = r.Name
    end
    return ("%s %s %s %s: %d gates in it."):format(word == "add" and "Added" or "Removed", table.concat(done, ", "),
        word == "add" and "to" or "from", p.name, members(p))
end)

---------------------------------------------------------------------------- commands
local SWITCHES = {fast = "fastDial", learn = "autoLogToDatabase", take = "autoAcceptShared", codes = "showCodes"}
clientEnv.command({"set", "s"}, "set fast|learn|take|codes on|off, set speed <s>, set sleep <minutes>|off, set scan <s>, set range <blocks>, set port <n>, set layout auto|compact|wide", function(args)
    local what, v = (args[1] or ""):lower(), (args[2] or ""):lower()
    if SWITCHES[what] then
        if v ~= "on" and v ~= "off" then return "Usage: set " .. what .. " on|off" end
        settings[SWITCHES[what]] = v == "on"
        save()
        return what .. " " .. v
    elseif what == "scan" or what == "range" then
        local n = math.tointeger(tonumber(v))
        if not n then return "Usage: set " .. what .. " <number>" end
        local name = what == "scan" and "nearbyScanRate" or "modemRange"
        settings[name] = n
        save()
        if what == "scan" then return settings[name] == 0 and "Automatic scans off." or ("Scanning every " .. settings[name] .. " s.") end
        return "Wireless range " .. settings[name] .. " blocks."
    elseif what == "sleep" then
        local n = v == "off" and 0 or math.tointeger(tonumber(v))
        if not n or n < 0 then return "Usage: set sleep <minutes>|off (a tablet shuts down after that long without input)" end
        settings.tabletSleep = n
        save()
        return n == 0 and "This tablet stays on." or ("A tablet shuts down after %d minute%s without input."):format(n, n == 1 and "" or "s")
    elseif what == "speed" then
        local n = tonumber(v)
        if not n or n < 0 then return "Usage: set speed <seconds> (0: as fast as the gate goes)" end
        settings.dialSpeed = n
        save()
        return settings.dialSpeed == 0 and "Dials go as fast as the gate goes." or ("A whole dial takes " .. settings.dialSpeed .. " s" .. (settings.dialSpeed >= 25 and ", spinning the ring." or "."))
    elseif what == "layout" then
        for _, l in ipairs(LAYOUTS) do if l == v then setLayout(l) return end end
        return "Usage: set layout auto|compact|wide"
    elseif what == "port" then
        local n = math.tointeger(tonumber(v))
        if not n or n < 1 or n > 65535 then return "Usage: set port <1-65535>" end
        setPort(n)
        return "Gate port " .. n .. ". SCAN finds the gates on it."
    end
    return "Usage: set fast|learn|take|codes on|off, speed <s>, sleep <minutes>|off, scan <s>, range <blocks>, port <n>, layout auto|compact|wide"
end)
clientEnv.command({"get", "g"}, "get range|speed|sleep|scan|port|layout|energy|memory|fingerprint|entries|entry <gate>", function(args)
    local what = (args[1] or ""):lower()
    if what == "range" then return settings.modemRange .. " blocks"
    elseif what == "sleep" then return settings.tabletSleep == 0 and "off" or (settings.tabletSleep .. " min" .. (require("component").isAvailable("tablet") and "" or " (not a tablet: stays on)"))
    elseif what == "speed" then return settings.dialSpeed == 0 and "fastest" or (settings.dialSpeed .. " s")
    elseif what == "scan" then return settings.nearbyScanRate == 0 and "off" or (settings.nearbyScanRate .. " s")
    elseif what == "layout" then return settings.layout .. " (now " .. (ui.wide and "wide" or "compact") .. ")"
    elseif what == "port" then return tostring(settings.port)
    elseif what == "fingerprint" then return clientEnv.vault:fingerprint()
    elseif what == "memory" then
        -- OC collects the garbage before every 10th resume, so one reading has up to nine
        -- resumes' garbage in it: the best of a reading a tick for 2 s is what is free after one.
        local best, n = 0, 0
        require("event").timer(0.05, function()
            n, best = n + 1, math.max(best, computer.freeMemory())
            if n == 40 then log(("  %d KiB free of %d KiB"):format(best // 1024, computer.totalMemory() // 1024)) end
        end, 40)
        return "Measuring free memory (2 s)..."
    elseif what == "energy" then
        local c = clientEnv.fromGate()
        local s = c and c.status
        if not s then return "No gate in range." end
        return ("%s: %d RF%s"):format(c.name, math.floor(tonumber(s.energy) or 0), s.capacity and (" of " .. math.floor(s.capacity)) or "")
    elseif what == "entries" then return #clientEnv.database .. " gates"
    elseif what == "entry" then
        local r, i = clientEnv.findEntry(args[2])
        if not r then return "No gate " .. tostring(args[2]) .. "." end
        local a = (r.Address or {})[r.Type or "MW"] or {}
        if not settings.showCodes then return ("%d %s [%s] %s · address and IDCs hidden"):format(i, r.Name, tostring(r.Type), clientEnv.place(r) or "location unknown") end
        return ("%d %s [%s] %s · IDCs %s · %s"):format(i, r.Name, tostring(r.Type), clientEnv.place(r) or "location unknown",
            #(r.IDCs or {}) > 0 and table.concat(r.IDCs, ", ") or "none", #a > 0 and table.concat(a, ", ") or "no address")
    end
    return "Usage: get range|speed|sleep|scan|port|layout|energy|memory|fingerprint|entries|entry <gate>"
end)

return {first = first}
