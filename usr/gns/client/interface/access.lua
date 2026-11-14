-- Access screen: the gates this device may use, the grants it holds and the grants it issued.
-- SET UP makes an unregistered gate this device's; INVITE hands players nearby a grant (as the
-- owner, or as an admin for the owner whose admin grant this device holds); JOIN asks for one;
-- CUT OFF ends a grant this device issued, at every gate it covers that this device opens.
-- See docs/design/networks.md. Widget callbacks cannot wait, so each step continues in a
-- callback.
--
-- vaultState.grants: the grants held. vaultState.issued: {grant, scope, cut}.
-- vaultState.access[gate key] = {name, modem, port, wake, owner, role}.
--
-- Commands: grants, invite, join, cut.
local gns, clientEnv = ...
local ui = clientEnv.ui
local C = ui.C
local loom = require("loom")
local event = require("event")
local grants = dofile(gns.path.gns .. "grants.lua")
local invite = loadfile(gns.path.gns .. "invite.lua")(grants)
local fingerprint = clientEnv.vaultModule.fingerprint

local vaultState = clientEnv.vault.state
local identity = vaultState.identity
local log = clientEnv.log
local ROLE_COLOUR = {owner = C.amber, admin = C.blue, user = C.text, cut = C.red}

local function save()
    local saved, err = clientEnv.vault:save()
    if not saved then log("Vault not saved: " .. tostring(err)) end
end
local function guard(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then log("Error: " .. tostring(err)) end
    end
end
local function short(key) return fingerprint(key):sub(1, 13) end
local function gateName(key)
    local a = vaultState.access[key]
    return a and a.name or short(key)
end
-- "Abydos", or "every gate of GNS-1a2b-3c4d" (yours: "every gate you own").
local function scopeOf(g)
    if g.gate ~= "" then return gateName(g.gate) end
    return g.owner == identity.public and "every gate you own" or ("every gate of " .. short(g.owner))
end

---------------------------------------------------------------------------- lists
local function gateRows()
    local rows = {}
    for key, a in pairs(vaultState.access) do rows[#rows + 1] = {key = key, a = a} end
    table.sort(rows, function(x, y) return tostring(x.a.name) < tostring(y.a.name) end)
    return rows
end
local function inRange(key)
    for _, c in ipairs(clientEnv.gateconnections) do if c.key == key then return true end end
end
local function issuedRows() return vaultState.issued end

-- Who this device can issue grants as: the owner of the gates it set up, and an admin for each
-- owner whose admin grant it holds. Each with the roles it may give and the gates it covers.
local function issuers()
    local list, owned = {}, {}
    for key, a in pairs(vaultState.access) do if a.owner == identity.public then owned[#owned + 1] = key end end
    if #owned > 0 then list[1] = {label = "the owner", owner = identity.public, roles = {"user", "admin"}, gates = owned} end
    for _, g in ipairs(vaultState.grants) do
        if g.role == "admin" then
            local covered = {}
            for key, a in pairs(vaultState.access) do
                if a.owner == g.owner and (g.gate == "" or g.gate == key) then covered[#covered + 1] = key end
            end
            list[#list + 1] = {label = "admin for " .. short(g.owner), owner = g.owner, by = g, roles = {"user"}, gates = covered}
        end
    end
    return list
end

---------------------------------------------------------------------------- actions
-- The newest log line when SET UP, INVITE or JOIN was last pressed: lines after it are that
-- action's answer, shown on the ACCESS card.
local noteAfter
local function pressed()
    local a = clientEnv.activity
    noteAfter = a[#a] or false
end
local function setUp()
    pressed()
    clientEnv.runCommands("setup")
end

-- An invitation stays open until STOP; each request is answered in dialogs (the role, then the
-- gates), or refused with CANCEL. A timer offers the next queued request once the last one is
-- answered and no dialog is open: between a request's two dialogs none is.
local host, as, queue, timer, answering = nil, nil, {}, nil, nil
local function accept(as, request, role, scope)
    answering = nil
    local gateKey = scope ~= "all" and scope or ""
    local g = grants.issue(identity, as.owner, gateKey, request.key, request.name, role, as.by)
    local gates = {}
    for _, key in ipairs(as.gates) do
        local a = vaultState.access[key]
        if a and (gateKey == "" or key == gateKey) then
            gates[key] = {name = a.name, modem = a.modem, port = a.port, wake = a.wake, silent = a.silent}
        end
    end
    vaultState.issued[#vaultState.issued + 1] = {grant = g, cut = false}
    request.host.accept(request, {grant = g, gates = gates})
    save()
    log(("Granted %s the %s role at %s."):format(request.name, role, scopeOf(g)))
end
local function invitation() return host end
local function nextRequest()
    local request = queue[1]
    if not host or not request or answering or ui.modalOpen() then return end
    table.remove(queue, 1)
    answering = request
    local as, host = as, host -- this invitation, even if it stops before the answer
    local who = short(request.key)
    log(("%s (%s) asks for access."):format(request.name, who))
    local function deny()
        answering = nil
        host.deny(request)
        log("Refused " .. request.name .. ".")
    end
    clientEnv.ask(("%s (%s) asks for access. Their role:"):format(request.name:sub(1, 20), who),
        {options = {list = as.roles, index = 1}, title = "ACCESS REQUEST"}, guard(function(role)
            role = role or "user"
            local names, keys = {}, {}
            if as.by == nil or as.by.gate == "" then names[1], keys[1] = "every gate", "all" end
            for _, key in ipairs(as.gates) do
                names[#names + 1], keys[#keys + 1] = gateName(key), key
            end
            event.timer(0, guard(function()
                local open = clientEnv.ask("Which gates?", {options = {list = names, index = 1}, title = "ACCESS REQUEST"}, guard(function(_, i)
                    if keys[i] then return accept(as, request, role, keys[i]) end
                    deny()
                end), deny)
                -- Another dialog opened first: offer this request again once it closes.
                if open == false then
                    answering = nil
                    if invitation() == host then table.insert(queue, 1, request) end
                end
            end))
        end), deny)
end
local function stopInvite()
    if timer then event.cancel(timer) end
    if host then host.stop() end
    host, as, queue, timer, answering = nil, nil, {}, nil, nil
end
local function startInvite(issuer)
    queue, as = {}, issuer
    local this
    this = invite.host(function(request)
        request.host = this
        -- A device asking again (with another key) replaces its waiting request: invite.lua caps
        -- distinct devices, so the queue stays as short.
        for i, waiting in ipairs(queue) do
            if waiting.address == request.address then table.remove(queue, i) break end
        end
        queue[#queue + 1] = request
        loom.invalidate()
    end, clientEnv.bucket)
    host = this
    timer = event.timer(0.5, guard(nextRequest), math.huge)
    log(("Inviting as %s. Players choose JOIN on their device."):format(issuer.label))
end
local function toggleInvite()
    pressed()
    if host then
        stopInvite()
        log("Invitation closed.")
        return
    end
    local list = issuers()
    if #list == 0 then log("SET UP a gate first, or hold an admin grant.") return end
    if #list == 1 then return startInvite(list[1]) end
    local labels = {}
    for i, x in ipairs(list) do labels[i] = x.label end
    clientEnv.ask("Invite as", {options = {list = labels, index = 1}, title = "INVITE"}, guard(function(_, i)
        if list[i] then return startInvite(list[i]) end
    end))
end

-- Keeps a grant from an invitation, and how to reach and wake the gates it covers.
local function keep(offer, role)
    local g = offer.grant
    local have = false
    for i, held in ipairs(vaultState.grants) do
        if held.serial == g.serial then vaultState.grants[i], have = g, true end
    end
    if not have then vaultState.grants[#vaultState.grants + 1] = g end
    for key, info in pairs(offer.gates) do
        -- Only gates the grant covers, and never one this device already reaches under another
        -- owner: an invitation cannot repoint them.
        local a = type(key) == "string" and vaultState.access[key] or {}
        if type(key) == "string" and #key == 22 and type(info) == "table" and (g.gate == "" or g.gate == key)
            and (a.owner == nil or a.owner == g.owner) then
            a.name, a.modem, a.owner, a.role = tostring(info.name or a.name), info.modem or a.modem, g.owner, role
            a.port = math.tointeger(info.port) or a.port
            a.wake = type(info.wake) == "string" and info.wake or a.wake
            a.silent = info.silent == true or nil
            vaultState.access[key] = a
        end
    end
    save()
end
local joining, closed = false, false
local function join()
    pressed()
    if joining then log("Still waiting for an answer.") return end
    local function ask(name)
        if not name or not name:match("%S") then return end
        joining = true
        log("Asking for an invitation nearby as " .. name .. "; the owner or admin has to accept.")
        invite.join(identity, name:sub(1, 32), 120, guard(function(offer, role)
            joining = false
            if not offer then log("No grant: " .. tostring(role)) return end
            keep(offer, role)
            log(("Granted the %s role at %s, signed by %s."):format(role, scopeOf(offer.grant), short(offer.grant.signer)))
            clientEnv.reconnect()
        end), function() return not closed end, clientEnv.bucket)
    end
    if clientEnv.player then return ask(clientEnv.player) end
    clientEnv.ask("Your player name", {text = "", title = "JOIN"}, guard(ask))
end

local function cutOff(issued)
    if not issued then log("Choose a grant you issued.") return end
    if issued.cut then log("That grant is already cut off.") return end
    local g = issued.grant
    clientEnv.ask(("Cut off %s (%s at %s)?"):format(g.name, g.role, scopeOf(g)), {title = "CUT OFF"}, guard(function()
        issued.cut = true
        save()
        log(("Cut off %s. Each gate it covers learns it when this device next opens it."):format(g.name))
        clientEnv.pushCuts()
    end))
end

---------------------------------------------------------------------------- the screen
local M = {}
function M.build(frame, R)
    local wide = R.wide
    local view = clientEnv.accessView or "gates" -- compact: which list shows
    local VIEWS = {"gates", "held", "issued"}
    local TITLE = {gates = "GATES", held = "GRANTS HELD", issued = "GRANTS ISSUED"}
    local function header(self)
        local owned, admin = 0, 0
        for _, a in pairs(vaultState.access) do
            if a.role == "owner" then owned = owned + 1 elseif a.role == "admin" then admin = admin + 1 end
        end
        self:text(3, 2, ui.pad(("You: %s · %s"):format(tostring(clientEnv.player or "player unknown"), short(identity.public)), R.w - 4), C.amber, C.card)
        local line = ("%d %s owned, admin at %d, %d grants held, %d issued"):format(owned, owned == 1 and "gate" or "gates", admin, #vaultState.grants, #vaultState.issued)
        if host then line = line .. (" · inviting as %s, %d waiting"):format(as.label, #queue) end
        self:text(3, 3, ui.pad(line, R.w - 4), C.faint, C.card)
        -- What SET UP would do to the gate picked on Dial, or the answer to the last button.
        local a = clientEnv.activity
        local note, colour = nil, C.text
        if noteAfter ~= nil and a[#a] ~= noteAfter then
            note = a[#a].text
        else
            local c = clientEnv.fromGate()
            colour = C.dim
            if not c then note = "SET UP: pick a gate in range on Dial first."
            elseif c.public then note = ("SET UP: %s is public; nobody can claim it."):format(c.name)
            elseif c.registered then note = ("SET UP: %s already has an owner."):format(c.name)
            else note, colour = ("SET UP makes %s yours (the gate picked on Dial)."):format(c.name), C.amber end
        end
        local lines = ui.wrap(note, R.w - 4)
        for i = 1, 2 do self:text(3, 3 + i, ui.pad(lines[i] or "", R.w - 4), colour, C.card) end
    end

    local inviteLabel = function() return host and "STOP" or "INVITE" end
    local inviteColour = function() return host and C.red or C.green end
    ui.card(frame, 1, 1, R.w, 6, "ACCESS", nil, header)
    local bx = R.w - (wide and 54 or 44)
    local first = ui.Button(frame, bx, 2, wide and 12 or 9, 1, "SET UP", C.amber, C.black, setUp)
    ui.Button(frame, bx + (wide and 14 or 11), 2, wide and 12 or 9, 1, inviteLabel, inviteColour, C.black, toggleInvite)
    ui.Button(frame, bx + (wide and 28 or 22), 2, wide and 12 or 9, 1, "JOIN", C.blue, C.black, join)

    local gateCells = function(row, _, w)
        local a = row.a
        return {{2, ui.pad(tostring(a.name), w - 26)}, {w - 23, "[" .. tostring(a.role) .. "]", ROLE_COLOUR[a.role] or C.text},
            {w - 13, a.wake and "wake" or "", C.dim}, {w - 7, inRange(row.key) and "near" or "", C.green}}
    end
    local heldCells = function(g, _, w)
        local by = g.signer ~= g.owner and ("  by " .. short(g.signer)) or "" -- an admin signed it
        return {{2, ui.pad(scopeOf(g) .. by, w - 12)}, {w - 9, "[" .. g.role .. "]", ROLE_COLOUR[g.role]}}
    end
    local issuedCells = function(x, _, w)
        local g = x.grant
        local role = x.cut and "cut" or g.role
        return {{2, ui.pad(g.name, 16)}, {19, ui.pad(scopeOf(g), w - 30)}, {w - 9, "[" .. role .. "]", ROLE_COLOUR[role]}}
    end
    local issuedList
    local ly, lh = 8, R.h - 9
    if wide then
        local w3 = (R.w - 4) // 3
        ui.card(frame, 1, ly, w3, lh, "GATES", function() return #gateRows() .. "" end)
        ui.List(frame, 1, ly + 1, w3, lh - 1, {items = gateRows, cells = gateCells,
            empty = "None yet. SET UP a gate in range, or JOIN to be granted one."})
        ui.card(frame, w3 + 3, ly, w3, lh, "GRANTS HELD", function() return #vaultState.grants .. "" end)
        ui.List(frame, w3 + 3, ly + 1, w3, lh - 1, {items = function() return vaultState.grants end, cells = heldCells,
            empty = "None. JOIN while an owner or admin nearby invites."})
        ui.card(frame, 2 * w3 + 5, ly, R.w - 2 * w3 - 4, lh, "GRANTS ISSUED", function() return #vaultState.issued .. "" end)
        issuedList = ui.List(frame, 2 * w3 + 5, ly + 1, R.w - 2 * w3 - 4, lh - 1, {items = issuedRows, cells = issuedCells,
            empty = "None. INVITE hands players nearby a grant."})
        ui.Button(frame, 2 * w3 + 5, R.h, R.w - 2 * w3 - 4, 1, "CUT OFF", C.red, C.black, function() cutOff(issuedList:cursorItem()) end, {around = C.page})
    else
        ui.card(frame, 1, ly, R.w, lh, "", nil)
        ui.chooser(frame, 2, ly, 26, function() return TITLE[view] end, function()
            for i, v in ipairs(VIEWS) do if v == view then view = VIEWS[(i - 2) % 3 + 1] break end end
            clientEnv.accessView = view
        end, function()
            for i, v in ipairs(VIEWS) do if v == view then view = VIEWS[i % 3 + 1] break end end
            clientEnv.accessView = view
        end, {around = C.head})
        issuedList = ui.List(frame, 1, ly + 1, R.w, lh - 1, {
            items = function()
                if view == "gates" then return gateRows() elseif view == "held" then return vaultState.grants end
                return issuedRows()
            end,
            cells = function(item, i, w)
                if view == "gates" then return gateCells(item, i, w) elseif view == "held" then return heldCells(item, i, w) end
                return issuedCells(item, i, w)
            end,
            empty = function()
                return ({gates = "None yet: SET UP or JOIN.", held = "None: JOIN to be granted.", issued = "None: INVITE grants."})[view]
            end})
        ui.Button(frame, R.w - 12, R.h, 12, 1, "CUT OFF", C.red, C.black, function()
            if view ~= "issued" then log("Choose GRANTS ISSUED first.") return end
            cutOff(issuedList:cursorItem())
        end, {around = C.page})
    end
    return {first = first}
end

---------------------------------------------------------------------------- commands
clientEnv.command("grants", "grants: the grants this device holds and has issued", function()
    local held, issued = {}, {}
    for _, g in ipairs(vaultState.grants) do held[#held + 1] = g.role .. " at " .. scopeOf(g) .. (g.signer ~= g.owner and (" (by " .. short(g.signer) .. ")") or "") end
    for _, x in ipairs(vaultState.issued) do
        issued[#issued + 1] = x.grant.name .. " " .. (x.cut and "cut off" or x.grant.role)
    end
    return ("Held: %s. Issued: %s."):format(#held > 0 and table.concat(held, ", ") or "none", #issued > 0 and table.concat(issued, ", ") or "none")
end)
clientEnv.command("invite", "invite: start or stop handing out grants to players nearby", function() toggleInvite() end)
clientEnv.command("join", "join: ask an owner or admin nearby for a grant", function() join() end)
clientEnv.command("cut", "cut <name>: cut off a grant you issued", function(args)
    local want = table.concat(args, " "):lower()
    for _, x in ipairs(vaultState.issued) do
        if not x.cut and x.grant.name:lower() == want then return cutOff(x) end
    end
    return "No grant issued to " .. want .. " that is not cut off."
end)

-- Inviting or joining goes on when the player leaves the screen (client.lua keeps it loaded, and
-- a tablet on): players may still be on their way to JOIN.
function M.busy() return host ~= nil or joining end
function M.close()
    stopInvite()
    closed = true
end
return M
