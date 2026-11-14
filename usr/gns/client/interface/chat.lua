-- Chat screen: chat with GNS devices nearby and share address book gates with them. The peer
-- service (peer.lua, started by client.lua) receives while the client runs; this screen shows
-- clientEnv.chat and sends. Shared gates wait under Shared With You until accepted, unless
-- Settings takes them without asking; blocked devices are ignored.
--
-- Commands: find, say, share, block, accept, refuse.
local _, clientEnv = ...
local ui = clientEnv.ui
local C = ui.C
local loom = require("loom")
local unicode = require("unicode")
local chat, node, settings = clientEnv.chat, clientEnv.peer, clientEnv.settings
local database, vaultState = clientEnv.database, clientEnv.vault.state
local log = clientEnv.log

local function show(text) chat.show(text) log(text) end

---------------------------------------------------------------------------- devices
local function find()
    if chat.finding then return "Already looking." end
    chat.finding = true
    chat.show("Looking for GNS devices...")
    node.find(function(found, failures)
        chat.finding = false
        local devices = chat.devices
        for i = #devices, 1, -1 do devices[i] = nil end
        for _, d in ipairs(found) do
            if not settings.chatBlacklist[d.fingerprint] then devices[#devices + 1] = d end
        end
        if chat.to then
            local still = false
            for _, d in ipairs(devices) do if d.fingerprint == chat.to.fingerprint then chat.to, still = d, true end end
            if not still then chat.to = nil end
        end
        for _, f in ipairs(failures) do
            if f.reason == "device key changed" then
                clientEnv.keyChanged(f.name, vaultState.peerPins, f.address)
                chat.show(("%s: device key changed. If it was reinstalled, trust %s accepts its new key."):format(f.name, f.name))
            else
                chat.show(("%s: %s"):format(f.name, f.reason))
            end
        end
        clientEnv.changed()
        show(("Found %d devices."):format(#devices))
    end)
end
local function block(fingerprint, name)
    settings.chatBlacklist[fingerprint] = true
    clientEnv.saveSettings()
    local devices = chat.devices
    for i = #devices, 1, -1 do
        if devices[i].fingerprint == fingerprint then table.remove(devices, i) end
    end
    if chat.to and chat.to.fingerprint == fingerprint then chat.to = nil end
    for i = #chat.pending, 1, -1 do
        if chat.pending[i].from.fingerprint == fingerprint then table.remove(chat.pending, i) end
    end
    show(("Blocked %s. Unblock under Settings."):format(name))
end
local function deviceNamed(word)
    if not word then return nil end
    local n = math.tointeger(tonumber(word))
    if n then return chat.devices[n] end
    word = word:gsub("_", " "):lower()
    for _, d in ipairs(chat.devices) do
        if d.name:lower():sub(1, #word) == word or d.fingerprint:lower():sub(1, #word) == word then return d end
    end
end

-- Sends a line to the chosen device, or to every device found.
local function say(line)
    if not line:match("%S") then return end
    line = line:sub(1, node.MAX_TEXT)
    local to = chat.to and {chat.to} or chat.devices
    if #to == 0 then return "No devices to send to: FIND looks for them." end
    chat.say("you" .. (chat.to and (" → " .. chat.to.name) or ""), line, true)
    for _, device in ipairs(to) do
        node.chat(device, line, function(ok, err)
            if not ok then show(("%s did not get it: %s"):format(device.name, tostring(err))) end
        end)
    end
end

-- Shares rows of the address book with a device; their IDCs go only when withIDCs is true.
local function share(device, selected, withIDCs)
    local rows, signed = {}, {}
    for _, row in ipairs(selected) do
        rows[#rows + 1] = {Name = row.Name, Type = row.Type, Address = row.Address, key = row.key, Location = row.Location,
            IDCs = withIDCs and row.IDCs or {}}
        if row.key and vaultState.book[row.key] then signed[#signed + 1] = vaultState.book[row.key] end
    end
    node.share(device, rows, signed, function(ok, result)
        show(ok and ("Shared %d gates%s with %s."):format(result, withIDCs and " and their IDCs" or "", device.name)
            or ("%s did not take the share: %s"):format(device.name, tostring(result)))
    end)
    return ("Sharing %d gates with %s..."):format(#rows, device.name)
end

local function accept(i)
    local s = table.remove(chat.pending, i or 1)
    if not s then return "Nothing is waiting." end
    local added, codes = chat.accept(s)
    return ("Added %d of %d gates from %s%s."):format(added, #s.rows, s.from.name,
        codes > 0 and (" and %d IDCs"):format(codes) or "")
end
local function refuse(i)
    local s = table.remove(chat.pending, i or 1)
    if not s then return "Nothing is waiting." end
    return "Refused the gates from " .. s.from.name .. "."
end

---------------------------------------------------------------------------- share dialog
-- Choose the device, the gates and whether their IDCs go too. selected: rows chosen already.
-- Where addresses are hidden (a kiosk), nothing is shared, as the GATES screen's SHARE.
local HIDDEN = "Addresses and IDCs are hidden on this device (Settings)."
local function openShare(selected)
    if ui.modalOpen() then return end
    if not settings.showCodes then log(HIDDEN) return end
    if #chat.devices == 0 then
        log("No devices to share with yet: looking for them now; share again when they are found.")
        find()
        return
    end
    local chosen = {}
    for _, r in ipairs(selected or {}) do chosen[r] = true end
    local at = 1
    for i, d in ipairs(chat.devices) do if chat.to and d.fingerprint == chat.to.fingerprint then at = i end end
    local withIDCs = false
    local w, h = 64, math.min(ui.H - 2, 22)
    local box, close = ui.modal(clientEnv.root, clientEnv.shell, w, h, "SHARE GATES")
    ui.Paint(box, 3, 3, 10, 1, function(self) self:text(1, 1, "With", C.faint, C.card) end)
    local first = ui.chooser(box, 9, 3, 40, function()
        local d = chat.devices[at]
        return d and (d.name .. " · " .. d.fingerprint:sub(1, 13)) or "nobody"
    end, function() at = (at - 2) % #chat.devices + 1 end, function() at = at % #chat.devices + 1 end)
    ui.Paint(box, 3, 5, w - 4, 1, function(self)
        local n = 0
        for _ in pairs(chosen) do n = n + 1 end
        self:text(1, 1, ("GATES  %d chosen (Enter picks)"):format(n), C.faint, C.card)
    end)
    ui.List(box, 2, 6, w - 2, h - 10, {items = database,
        cells = function(r, i, lw) return {{1, ui.pad(tostring(i), 3), C.faint}, {5, ui.pad(r.Name, lw - 16)},
            {lw - 10, tostring(r.Type or ""), C.dim}, {lw - 5, #(r.IDCs or {}) > 0 and "IDC" or "", C.amber}} end,
        selected = function(r) return chosen[r] end,
        press = function(r) chosen[r] = not chosen[r] or nil end})
    ui.Paint(box, 3, h - 3, 30, 1, function(self)
        self:text(1, 1, "Send their IDCs too", C.text, C.card)
    end)
    ui.toggle(box, 24, h - 3, function() return withIDCs end, function(v) withIDCs = v end)
    ui.Paint(box, 33, h - 3, w - 34, 1, function(self)
        self:text(1, 1, withIDCs and "IDCs open their irises" or "Names and addresses only", C.faint, C.card)
    end)
    ui.Button(box, w // 2 - 15, h - 1, 14, 1, "SHARE", C.green, C.black, function()
        local rows = {}
        for _, r in ipairs(database) do if chosen[r] then rows[#rows + 1] = r end end
        local d = chat.devices[at]
        if #rows == 0 or not d then log("Choose the gates to share.") return end
        close()
        log(share(d, rows, withIDCs))
    end)
    ui.Button(box, w // 2 + 2, h - 1, 14, 1, "CANCEL", C.raised, C.text, close)
    ui.focusSoon(first)
end

---------------------------------------------------------------------------- the screen
local M = {openShare = openShare}
function M.build(frame, R)
    local wide = R.wide
    local lw = wide and 36 or 18
    local pitch = wide and 2 or 1
    ui.card(frame, 1, 1, lw, R.h - 4, "DEVICES", wide and function() return #chat.devices .. " found" end or nil, function(self)
        if not wide then return end
        local d = chat.to
        local dy = R.h - 13
        self:text(3, dy, "CHAT WITH", C.faint, C.card)
        if not d then
            self:text(3, dy + 1, "everyone found", C.amber, C.card)
            self:text(3, dy + 2, ui.pad("Enter on a device chats with it alone.", lw - 4), C.faint, C.card)
            return
        end
        self:text(3, dy + 1, ui.pad(d.name, lw - 4), C.amber, C.card)
        self:text(3, dy + 2, d.fingerprint, C.dim, C.card)
        self:text(3, dy + 4, "Enter on it again: everyone.", C.faint, C.card)
    end)
    local devices = ui.List(frame, 1, 2, lw, wide and (R.h - 18) or (R.h - 6), {items = chat.devices, pitch = pitch,
        empty = "None found yet. FIND looks for GNS devices in range.",
        cells = function(d, _, w)
            if wide then return {{2, ui.pad(d.name, 14)}, {17, d.fingerprint:sub(1, 13), C.faint}} end
            return {{1, ui.pad(d.name, w - 1)}}
        end,
        selected = function(d) return chat.to and chat.to.fingerprint == d.fingerprint end,
        press = function(d)
            chat.to = (not chat.to or chat.to.fingerprint ~= d.fingerprint) and d or nil
        end})
    local bw = (lw - 1) // 2
    ui.Button(frame, 1, R.h - 2, bw, 3, "FIND", C.amber, C.black, function() local m = find() if m then log(m) end end, {around = C.page})
    ui.Button(frame, bw + 3, R.h - 2, lw - bw - 2, 3, "BLOCK", C.red, C.black, function()
        local d = devices:cursorItem()
        if d then block(d.fingerprint, d.name) else log("Choose a device to block.") end
    end, {around = C.page})

    local cx, cw = lw + 3, R.w - lw - 2
    local sw = cw - 18
    ui.card(frame, cx, 1, cw, 5, "SHARED WITH YOU", function() return #chat.pending > 0 and (#chat.pending .. " waiting") or "none waiting" end)
    local pending = ui.List(frame, cx, 2, sw, 4, {items = chat.pending,
        empty = "Gates other devices share appear here.",
        cells = function(s, _, w)
            local names = {}
            for i = 1, math.min(#s.rows, 4) do names[i] = s.rows[i].Name end
            local text = ("%s: %s%s"):format(s.from.name, table.concat(names, ", "), #s.rows > 4 and ", ..." or "")
            local tag = chat.hasIDCs(s) and "[with IDCs]" or ""
            return {{2, ui.pad(text, w - 15)}, {w - 12, tag, C.amber}}
        end})
    local function pendingIndex() local _, i = pending:cursorItem() return chat.pending[i] and i end
    ui.Button(frame, cx + cw - 16, 2, 14, 1, "ACCEPT", C.green, C.black, function()
        if pendingIndex() then log(accept(pendingIndex())) end
    end)
    ui.Button(frame, cx + cw - 16, 3, 14, 1, "REFUSE", C.raised, C.text, function()
        if pendingIndex() then log(refuse(pendingIndex())) end
    end)
    ui.Button(frame, cx + cw - 16, 4, 14, 1, wide and "BLOCK SENDER" or "BLOCK", C.red, C.black, function()
        local i = pendingIndex()
        if i then
            local s = table.remove(chat.pending, i)
            block(s.from.fingerprint, s.from.name)
        end
    end)

    -- Messages as bubbles, newest at the bottom: theirs on the left, yours on the right.
    local top, bottom = 7, R.h - 2
    local function chatNote()
        if chat.to then return wide and (chat.to.name .. " · " .. chat.to.fingerprint:sub(1, 13)) or chat.to.name end
        return #chat.devices > 0 and ("everyone · " .. #chat.devices) or nil
    end
    ui.card(frame, cx, top, cw, bottom - top + 1, function() return "CHAT · " .. (chatNote() or "nobody found yet") end, nil, function(self)
        local rows, room, max = {}, bottom - top - 1, cw - 10
        local i = #chat.lines
        while i >= 1 and #rows < room do
            local e = chat.lines[i]
            local lines = ui.wrap(e.text, e.who and max or (cw - 6))
            local block = {}
            if e.who then
                block[#block + 1] = {kind = "who", e = e}
                for _, l in ipairs(lines) do block[#block + 1] = {kind = "bubble", e = e, text = l} end
            else
                for _, l in ipairs(lines) do block[#block + 1] = {kind = "note", e = e, text = l} end
            end
            block[#block + 1] = {kind = "gap"}
            for j = #block, 1, -1 do table.insert(rows, 1, block[j]) end
            i = i - 1
        end
        while #rows > room do table.remove(rows, 1) end
        for r, row in ipairs(rows) do
            local y = r + 1
            local e = row.e
            if row.kind == "who" then
                local label = e.who .. " · " .. e.time
                self:text(e.mine and (cw - unicode.len(label) - 1) or 3, y, label, C.faint, C.card)
            elseif row.kind == "bubble" then
                local w = unicode.len(row.text) + 2
                self:block(e.mine and (cw - w - 1) or 3, y, w, row.text, e.mine and C.blue or C.raised, e.mine and C.black or C.text)
            elseif row.kind == "note" then
                self:text(3, y, ui.pad(e.time .. "  " .. row.text, cw - 4), C.faint, C.card)
            end
        end
    end)
    ui.Button(frame, cx + cw - 9, top, 9, 1, "SHARE", C.blue, C.black, function() openShare() end, {around = C.head})
    local field = ui.Field(frame, cx, R.h, cw - 11, {clear = true, around = C.page,
        placeholder = "Message · Enter sends", submit = function(text) local m = say(text) if m then log(m) end end})
    ui.Button(frame, cx + cw - 9, R.h, 9, 1, "SEND", C.amber, C.black, function()
        local m = say(field:text())
        field:text("")
        if m then log(m) end
    end, {around = C.page})
    return {first = devices, shown = function() chat.unread = 0 loom.invalidate() end}
end

---------------------------------------------------------------------------- commands
clientEnv.command("find", "find: look for GNS devices in range", function() return find() end)
clientEnv.command("say", "say <text>: chat with the chosen device, or every device found", function(_, line)
    return say(line:match("^%s*%S+%s*(.*)$") or "")
end)
clientEnv.command("share", "share <gate> [gate ...] [idc] [@device]: share gates; idc sends their IDCs too", function(args)
    if not settings.showCodes then return HIDDEN end
    local rows, withIDCs, device = {}, false, chat.to or (#chat.devices == 1 and chat.devices[1]) or nil
    for _, a in ipairs(args) do
        if a:lower() == "idc" or a:lower() == "idcs" then withIDCs = true
        elseif a:sub(1, 1) == "@" then
            device = deviceNamed(a:sub(2))
            if not device then return "No device " .. a:sub(2) .. " found." end
        else
            local r = clientEnv.findEntry(a)
            if not r then return "No gate " .. a .. " in the address book." end
            rows[#rows + 1] = r
        end
    end
    if #rows == 0 then return "Usage: share <gate> [gate ...] [idc] [@device]" end
    if not device then return "Choose a device: share ... @name (find lists them)." end
    return share(device, rows, withIDCs)
end)
clientEnv.command("block", "block <device>: drop a device's chat and shares from now on (Settings unblocks)", function(args)
    local d = deviceNamed(args[1])
    if not d then return "No device " .. tostring(args[1]) .. " found." end
    block(d.fingerprint, d.name)
end)
clientEnv.command("accept", "accept [n]: take the gates shared with you (the first share, or the nth)", function(args)
    return accept(math.tointeger(tonumber(args[1])))
end)
clientEnv.command("refuse", "refuse [n]: refuse gates shared with you", function(args)
    return refuse(math.tointeger(tonumber(args[1])))
end)

return M
