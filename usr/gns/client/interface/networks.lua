-- Networks screen: found private networks, invite members, add gates in range, revoke
-- memberships and push network changes to the network's gates. Widget callbacks cannot wait,
-- so every network step continues in a callback.
--
-- vaultState.networks[id] = {name, network, revoked, membership, issued = {{name, member, role,
-- serial, revoked}}}. handshake.open uses only network, revoked and membership.
--
-- Commands: net, push.
local gns, clientEnv, _, frame, R = ...
local ui = clientEnv.ui
local C = ui.C
local loom = require("loom")
local event = require("event")
local networks = dofile(gns.path.gns .. "networks.lua")
local invite = dofile(gns.path.gns .. "invite.lua")
local fingerprint = dofile(gns.path.gns .. "vault.lua").fingerprint

local vaultState = clientEnv.vault.state
local identity = vaultState.identity
local connections = clientEnv.gateconnections
local log = clientEnv.log
local roleOf = clientEnv.roleOf
local wide = R.wide
local ROLE_COLOUR = {admin = C.amber, moderator = C.blue, user = C.text, gate = C.green, revoked = C.red}

-- The network shown, kept across layout changes.
local state = clientEnv.netState or {}
clientEnv.netState = state

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

local function list()
    local rows = {}
    for _, net in pairs(vaultState.networks) do
        net.issued = net.issued or {}
        net.name = net.name or net.network.id
        rows[#rows + 1] = net
    end
    table.sort(rows, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return rows
end
local function current()
    local rows = list()
    for _, net in ipairs(rows) do if net == state.net then return net end end
    state.net = rows[1]
    return state.net
end
local function members()
    local net = current()
    if not net then return {} end
    local out = {{name = "you", member = identity.public, role = roleOf(net), you = true}}
    for _, m in ipairs(net.issued) do if m.role ~= "gate" then out[#out + 1] = m end end
    return out
end
local function gates()
    local net = current()
    local out = {}
    for _, m in ipairs(net and net.issued or {}) do if m.role == "gate" then out[#out + 1] = m end end
    return out
end
local function administered()
    local net = current()
    if not net then log("Found or join a network first.") return nil end
    if roleOf(net) ~= "admin" or not networks.authority(net.network, identity.public) then
        log("Only the founder and admins of " .. net.name .. " can do that.")
        return nil
    end
    return net
end

---------------------------------------------------------------------------- actions
local function found()
    clientEnv.ask("Name the new network", {text = "", title = "NEW NETWORK"}, guard(function(name)
        if not name or not name:match("%S") then return end
        local network = networks.create(identity)
        local net = {name = name:sub(1, 24), network = network, issued = {},
            membership = networks.issue(identity, network, identity.public, "admin")}
        vaultState.networks[network.id] = net
        state.net = net
        save()
        log(("Founded %s. Gate owners type trust %s before you add their gates."):format(net.name, clientEnv.vault:fingerprint()))
    end))
end

local joining = false
local function join()
    if joining then log("Still waiting for the admin.") return end
    clientEnv.ask("Your name in the network", {text = clientEnv.deviceName, title = "JOIN"}, guard(function(name)
        if not name or not name:match("%S") then return end
        joining = true
        log("Asking for an invitation nearby; the admin has to accept.")
        invite.join(identity, name:sub(1, 24), 120, guard(function(grant, role)
            joining = false
            if not grant then log("Not joined: " .. tostring(role)) return end
            local net = vaultState.networks[grant.network.id] or {issued = {}}
            net.name, net.network, net.revoked, net.membership = tostring(grant.name):sub(1, 24), grant.network, grant.revoked, grant.membership
            vaultState.networks[grant.network.id] = net
            state.net = net
            save()
            log(("Joined %s as %s. Founder %s: check it matches the founder's device."):format(net.name, role, fingerprint(grant.network.founder)))
            clientEnv.reconnect() -- the network's gates open for members only
        end))
    end))
end

-- An invitation stays open until STOP; each request is answered in a dialog (CONFIRM with the
-- chosen role, or CANCEL). A timer offers the next queued request whenever no dialog is open.
local host, hostNet, queue, timer = nil, nil, {}, nil
local function acceptRequest(request, role)
    local net = hostNet
    if role == "admin" then
        local admins = {table.unpack(net.network.admins)}
        admins[#admins + 1] = request.key
        net.network = networks.setAdmins(identity, net.network, admins)
    end
    local m = networks.issue(identity, net.network, request.key, role)
    net.issued[#net.issued + 1] = {name = request.name, member = request.key, role = role, serial = m.serial}
    host.accept(request, {name = net.name, network = net.network, revoked = net.revoked, membership = m})
    save()
    log(("Accepted %s into %s as %s."):format(request.name, net.name, role))
    if role == "admin" then log("The admin list changed: PUSH it to the network's gates.") end
end
local function nextRequest()
    local request = queue[1]
    if not host or not request or ui.modalOpen() then return end
    table.remove(queue, 1)
    local roles = {"user", "moderator"}
    if hostNet.network.founder == identity.public then roles[3] = "admin" end
    local who = fingerprint(request.key)
    log(("%s %s asks to join %s."):format(request.name, who, hostNet.name))
    clientEnv.ask(("%s (%s) asks to join %s. Their role:"):format(request.name:sub(1, 16), who, hostNet.name),
        {options = {list = roles, index = 1}, title = "JOIN REQUEST"},
        guard(function(role) acceptRequest(request, role or "user") end),
        function()
            host.deny(request)
            log("Denied " .. request.name .. ".")
        end)
end
local function stopInvite()
    if timer then event.cancel(timer) end
    if host then host.stop() end
    host, hostNet, queue, timer = nil, nil, {}, nil
end
clientEnv.onClose[#clientEnv.onClose + 1] = stopInvite
local function toggleInvite()
    if host then
        stopInvite()
        log("Invitation closed.")
        return
    end
    local net = administered()
    if not net then return end
    queue = {}
    host, hostNet = invite.host(net, function(request) queue[#queue + 1] = request loom.invalidate() end), net
    timer = event.timer(0.5, guard(nextRequest), math.huge)
    log("Inviting to " .. net.name .. ". Members choose JOIN on their device.")
end

-- Gives a public gate in range a gate membership and has it join; it must trust this network's
-- founder. It then serves only members, so it is closed here; SCAN opens it again as a member.
local function addGate()
    local net = administered()
    if not net then return end
    local names, byName = {}, {}
    for _, c in ipairs(connections) do
        if not c.net then
            local label = c.name .. " " .. c.address:sub(1, 4)
            names[#names + 1], byName[label] = label, c
        end
    end
    if #names == 0 then log("No public gate in range: SCAN on Dial first.") return end
    clientEnv.ask("Add which gate to " .. net.name .. "?", {options = {list = names, index = 1}, title = "ADD GATE"}, guard(function(label)
        local c = byName[label]
        if not c then return end
        local m = networks.issue(identity, net.network, c.key, "gate")
        c.proxy:async(guard(function(ok, err)
            if ok ~= true then log("Not added: " .. tostring(err)) return end
            net.issued[#net.issued + 1] = {name = c.name, member = c.key, role = "gate", serial = m.serial}
            for i, x in ipairs(connections) do
                if x == c then table.remove(connections, i) break end
            end
            if clientEnv.from == c then clientEnv.from = nil end
            pcall(c.proxy.close, c.proxy)
            save()
            log(c.name .. " joined " .. net.name .. "; opening it again as a member.")
            local busy = clientEnv.scan(false)
            if busy then log(busy .. " SCAN again to open it as a member.") end
        end)).join(net.network, m)
    end))
end

-- Adds a membership's serial to the network's signed revocation list; a revoked admin also
-- leaves the admin list. PUSH sends the change to the gates.
local function revoke(m)
    local net = administered()
    if not net then return end
    if not m or m.you or m.revoked then log("Choose a member to revoke.") return end
    clientEnv.ask("Revoke " .. m.name .. " (" .. m.role .. ")?", {title = "REVOKE"}, guard(function()
        net.revoked = networks.revoke(identity, net.network, net.revoked, {m.serial})
        if net.network.founder == identity.public and networks.authority(net.network, m.member) then
            local admins = {}
            for _, key in ipairs(net.network.admins) do
                if key ~= m.member then admins[#admins + 1] = key end
            end
            net.network = networks.setAdmins(identity, net.network, admins)
        end
        m.revoked = true
        save()
        log(("Revoked %s. PUSH to tell the gates."):format(m.name))
    end))
end

-- Gives every gate in range of the network its newest network record and revocation list.
-- Gates also pass them on to each other when they sync.
local function push()
    local net = current()
    if not net then return "Found or join a network first." end
    local waiting, sent, failed = 1, 0, 0
    local function done()
        waiting = waiting - 1
        if waiting > 0 then return end
        log(("Pushed %s to %d gates%s."):format(net.name, sent, failed > 0 and (", " .. failed .. " failed") or ""))
    end
    for _, c in ipairs(connections) do
        if c.net and c.net.network.id == net.network.id then
            waiting = waiting + 1
            c.proxy:async(guard(function(ok, err)
                if ok == true then sent = sent + 1 else
                    failed = failed + 1
                    log(c.name .. ": " .. tostring(err))
                end
                done()
            end)).network({network = net.network, revoked = net.revoked})
        end
    end
    done()
end

local function leave()
    local net = current()
    if not net then return end
    clientEnv.ask("Forget " .. net.name .. " on this device?", {title = "LEAVE"}, guard(function()
        vaultState.networks[net.network.id] = nil
        if hostNet == net then stopInvite() end
        state.net = nil
        save()
        log("Left " .. net.name .. ".")
    end))
end

---------------------------------------------------------------------------- the screen
local function cycle(step)
    local rows = list()
    if #rows == 0 then return end
    local at = 1
    for i, net in ipairs(rows) do if net == current() then at = i end end
    state.net = rows[(at - 1 + step) % #rows + 1]
end
local x0, w0 = 1, R.w
local function header(self, y)
    local net = current()
    if not net then
        self:text(3, y, ui.pad("No networks yet. NEW founds one; JOIN asks an admin nearby.", w0 - 4), C.faint, C.card)
        return
    end
    local role = roleOf(net)
    local x = self:tag(3, y, role, ROLE_COLOUR[role] or C.text, C.card)
    if net.network.founder == identity.public then x = self:tag(x, y, "founder", C.dim, C.card) end
    self:text(x, y, "founder " .. fingerprint(net.network.founder):sub(1, 13), C.faint, C.card)
    local revoked = net.revoked and net.revoked.serials and #net.revoked.serials or 0
    self:text(3, y + 1, ui.pad(("%d revoked%s"):format(revoked,
        host and hostNet == net and (" · inviting, " .. #queue .. " waiting") or ""), w0 - 4), C.faint, C.card)
end
local inviteLabel = function() return host and "STOP" or "INVITE" end
local inviteColour = function() return host and C.red or C.green end
local first
if wide then
    ui.card(frame, 1, 1, 30, R.h - 2, "MY NETWORKS")
    first = ui.List(frame, 1, 2, 30, R.h - 3, {items = list, pitch = 2, empty = "None yet.",
        cells = function(net) local role = roleOf(net) return {{2, ui.pad(net.name, 17)}, {20, "[" .. role .. "]", ROLE_COLOUR[role]}} end,
        selected = function(net) return net == current() end,
        press = function(net) state.net = net end})
    ui.Button(frame, 1, R.h, 14, 1, "NEW", C.green, C.black, found, {around = C.page})
    ui.Button(frame, 17, R.h, 14, 1, "JOIN", C.amber, C.black, join, {around = C.page})
    x0, w0 = 33, R.w - 32
    ui.card(frame, x0, 1, w0, 4, "NETWORK", function()
        local net = current()
        return net and ("%d members · %d gates"):format(#members(), #gates()) or nil
    end, function(self)
        local net = current()
        if net then self:text(3, 2, ui.pad(net.name, 30), C.amber, C.card) end
        header(self, 3)
    end)
    ui.Button(frame, x0 + w0 - 42, 2, 12, 1, inviteLabel, inviteColour, C.black, toggleInvite)
    ui.Button(frame, x0 + w0 - 28, 2, 12, 1, "PUSH", C.amber, C.black, function() local m = push() if m then log(m) end end)
    ui.Button(frame, x0 + w0 - 14, 2, 12, 1, "LEAVE", C.raised, C.text, leave)
else
    ui.card(frame, 1, 1, R.w, 5, "NETWORK", nil, function(self) header(self, 3) end)
    first = ui.chooser(frame, 2, 2, 30, function() local net = current() return net and net.name or "none" end,
        function() cycle(-1) end, function() cycle(1) end)
    ui.Button(frame, 35, 2, 7, 1, "NEW", C.green, C.black, found)
    ui.Button(frame, 44, 2, 7, 1, "JOIN", C.amber, C.black, join)
    ui.Button(frame, 3, 5, 10, 1, inviteLabel, inviteColour, C.black, toggleInvite)
    ui.Button(frame, 15, 5, 8, 1, "PUSH", C.amber, C.black, function() local m = push() if m then log(m) end end)
    ui.Button(frame, 25, 5, 8, 1, "LEAVE", C.raised, C.text, leave)
end

local my = wide and 6 or 7
local mh = R.h - my - 1
local mw = (w0 - 2) * 3 // 5
local pitch = wide and 2 or 1
ui.card(frame, x0, my, mw, mh, "MEMBERS")
local memberList = ui.List(frame, x0, my + 1, mw, mh - 1, {items = members, pitch = pitch,
    cells = function(m, _, w)
        local role = m.revoked and "revoked" or m.role
        if wide then
            return {{2, ui.pad(m.name, 16)}, {19, fingerprint(m.member):sub(1, 13), C.faint}, {34, "[" .. role .. "]", ROLE_COLOUR[role]}}
        end
        return {{1, ui.pad(m.name, 10)}, {12, fingerprint(m.member):sub(5, 13), C.faint}, {w - 11, "[" .. role .. "]", ROLE_COLOUR[role]}}
    end})
local gx, gw = x0 + mw + 2, w0 - mw - 2
ui.card(frame, gx, my, gw, mh, "GATES")
ui.List(frame, gx, my + 1, gw, mh - 1, {items = gates, pitch = pitch,
    empty = function() return "Gate owners type trust " .. clientEnv.vault:fingerprint() .. " at the gate; then ADD GATE." end,
    cells = function(m, _, w)
        return {{2, ui.pad(m.name, w - 13)}, {w - 10, m.revoked and "[revoked]" or "[member]", m.revoked and C.red or C.green}}
    end})
ui.Button(frame, x0, R.h, mw, 1, "REVOKE", C.red, C.black, function() revoke(memberList:cursorItem()) end, {around = C.page})
ui.Button(frame, gx, R.h, gw, 1, "ADD GATE", C.green, C.black, addGate, {around = C.page})

---------------------------------------------------------------------------- commands
clientEnv.command({"net", "network"}, "net [name]: list your networks, or show one", function(args)
    local rows = list()
    if not args[1] then
        if #rows == 0 then return "No networks yet." end
        local names = {}
        for _, net in ipairs(rows) do names[#names + 1] = net.name .. " [" .. roleOf(net) .. "]" end
        return table.concat(names, ", ")
    end
    local want = table.concat(args, " "):gsub("_", " "):lower()
    for _, net in ipairs(rows) do
        if net.name:lower():sub(1, #want) == want then
            state.net = net
            clientEnv.show("networks")
            return
        end
    end
    return "No network " .. want .. "."
end)
clientEnv.command({"push"}, "push: send the shown network's record and revocations to its gates in range", function() return push() end)

return {first = first}
