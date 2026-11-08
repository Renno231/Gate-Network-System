-- Settings screen: the client settings, saved as soon as they change; this device's
-- fingerprint and password; the devices blocked from chat and sharing.
--
-- Commands: set, get.
local gns, clientEnv, _, frame, R = ...
local ui = clientEnv.ui
local C = ui.C
local computer = require("computer")
local vaultModule = dofile(gns.path.gns .. "vault.lua")
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
local function networkCount()
    local n = 0
    for _ in pairs(clientEnv.vault.state.networks) do n = n + 1 end
    return n
end

---------------------------------------------------------------------------- the screen
local aw = wide and 66 or R.w
ui.card(frame, 1, 1, aw, 11, "DIALING AND SCANNING", nil, function(self)
    for i, r in ipairs({{"Fast dial", "press the gate's DHD instead of spinning the ring"},
        {"Learn gates from scans", "add the gates found in range to the address book"},
        {"Take shared gates", "without asking first"}}) do
        local y = i * 2
        self:text(3, y, r[1], C.text, C.card)
        self:text(3, y + 1, ui.pad(r[2], aw - 14), C.faint, C.card)
    end
    self:text(3, 8, "Rescan every", C.text, C.card)
    self:text(3, 9, "Wireless range", C.text, C.card)
    self:text(3, 10, "Layout", C.text, C.card)
end)
local first = ui.toggle(frame, aw - 9, 2, function() return settings.fastDial end, function(v) settings.fastDial = v save() end)
ui.toggle(frame, aw - 9, 4, function() return settings.autoLogToDatabase end, function(v) settings.autoLogToDatabase = v save() end)
ui.toggle(frame, aw - 9, 6, function() return settings.autoAcceptShared end, function(v) settings.autoAcceptShared = v save() end)
local cx = aw - 25
ui.chooser(frame, cx, 8, 24, function() return settings.nearbyScanRate == 0 and "off" or (settings.nearbyScanRate .. " s") end,
    function() step("nearbyScanRate", -10, 0, 600) end, function() step("nearbyScanRate", 10, 0, 600) end)
ui.chooser(frame, cx, 9, 24, function() return settings.modemRange .. " blocks" end,
    function() step("modemRange", -16, 16, 400) end, function() step("modemRange", 16, 16, 400) end)
ui.chooser(frame, cx, 10, 24, function()
    return settings.layout == "auto" and ("auto: " .. (ui.wide and "wide" or "compact")) or settings.layout
end, function() cycleLayout(-1) end, function() cycleLayout(1) end)

local bx, by, bw, bh = 1, 13, R.w, R.h - 12
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
    self:text(16, nameRow + 1, ui.pad(("%d gates, %d networks"):format(#clientEnv.database, networkCount()), bw - 32), C.text, C.card)
    self:text(3, blockedRow, "BLOCKED DEVICES", C.faint, C.card)
end)
ui.Button(frame, bx + bw - 14, by + nameRow - 1, 12, 1, "PASSWORD", C.amber, C.black, changePassword)
local ly = by + blockedRow
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

---------------------------------------------------------------------------- commands
local SWITCHES = {fast = "fastDial", learn = "autoLogToDatabase", take = "autoAcceptShared"}
clientEnv.command({"set", "s"}, "set fast|learn|take on|off, set scan <s>, set range <blocks>, set layout auto|compact|wide", function(args)
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
    elseif what == "layout" then
        for _, l in ipairs(LAYOUTS) do if l == v then setLayout(l) return end end
        return "Usage: set layout auto|compact|wide"
    end
    return "Usage: set fast|learn|take on|off, scan <s>, range <blocks>, layout auto|compact|wide"
end)
clientEnv.command({"get", "g"}, "get range|scan|layout|energy|memory|fingerprint|entries|entry <gate>", function(args)
    local what = (args[1] or ""):lower()
    if what == "range" then return settings.modemRange .. " blocks"
    elseif what == "scan" then return settings.nearbyScanRate == 0 and "off" or (settings.nearbyScanRate .. " s")
    elseif what == "layout" then return settings.layout .. " (now " .. (ui.wide and "wide" or "compact") .. ")"
    elseif what == "fingerprint" then return clientEnv.vault:fingerprint()
    elseif what == "memory" then
        return ("%d KiB free of %d KiB"):format(computer.freeMemory() // 1024, computer.totalMemory() // 1024)
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
        return ("%d %s [%s] %s · IDCs %s · %s"):format(i, r.Name, tostring(r.Type), clientEnv.place(r) or "location unknown",
            #(r.IDCs or {}) > 0 and table.concat(r.IDCs, ", ") or "none", #a > 0 and table.concat(a, ", ") or "no address")
    end
    return "Usage: get range|scan|layout|energy|memory|fingerprint|entries|entry <gate>"
end)

return {first = first}
