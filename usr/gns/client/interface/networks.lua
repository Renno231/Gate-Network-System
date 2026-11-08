-- Networks tab: found private networks, invite members, add connected gates, revoke memberships
-- and push network changes to the network's gates. Widget callbacks cannot wait, so every
-- network step continues in a callback.
--
-- vaultState.networks[id] = {name, network, revoked, membership, issued = {{name, member, role,
-- serial, revoked}}}. handshake.open uses only network, revoked and membership.
local gns, clientEnv, selfPath = ...
checkArg(1, gns, 'table')
local mainWindow = clientEnv.mainWindow
local computer = require("computer")
local yawl = require("yawl-e")
local event = require("event")
local networks = dofile(gns.path.gns .. "networks.lua")
local invite = dofile(gns.path.gns .. "invite.lua")
local fingerprint = dofile(gns.path.gns .. "vault.lua").fingerprint
local gui = yawl.widget

local vaultState = clientEnv.vault.state
local identity = vaultState.identity
local gateConnections = clientEnv.gateconnections

local currenttab = mainWindow:tab("Networks")

local rows = {} -- vaultState.networks as a list, for the network list
local members = {} -- the selected network's issued memberships

local netList = gui.SortedList(currenttab, 3, 4, 25, 5, 0)
netList:backgroundColor(0x333333)
netList:foregroundColor(0xffffff)
netList:maximumSelectedValues(1)
netList:list(rows)

local function roleOf(net)
    return networks.check(net.network, net.revoked, net.membership, identity.public) or "revoked"
end
netList:format(function(net) return ("%s (%s)"):format(net.name, roleOf(net)) end)

local memberList = gui.SortedList(currenttab, 3, 16, 25, 6, 0)
memberList:backgroundColor(0x333333)
memberList:foregroundColor(0xffffff)
memberList:maximumSelectedValues(1)
memberList:list(members)
memberList:format(function(m)
    return ("%s %s%s"):format(m.name, m.role, m.revoked and " revoked" or "")
end)

local output = gui.OutputQueue(currenttab, 32, 4, 45, 18, 0x333333)
output:pushPrefix(function(self, str)
    return "[" .. os.date("%H:%M", computer.uptime()) .. "] " .. str
end)
output:push("Private networks admit only their members. Found one with NEW, then INVITE members and ADD GATE for each of your gates. A gate's owner first types trust " .. clientEnv.vault:fingerprint() .. " on the gate.")
gui.TextLabel(currenttab, netList:x(), netList:y() - 1, "▌Networks")
gui.TextLabel(currenttab, memberList:x(), memberList:y() - 1, "▌Members")
gui.TextLabel(currenttab, output:x(), output:y() - 1, "▌Network Feedback")

local function selected(list)
    local selection = list:getSelection()[1]
    return selection and list:value(selection)
end

local function showMembers()
    local net = selected(netList)
    for i = #members, 1, -1 do members[i] = nil end
    memberList:clearSelection()
    for _, m in ipairs(net and net.issued or {}) do members[#members + 1] = m end
end

local function refresh()
    local current = selected(netList)
    for i = #rows, 1, -1 do rows[i] = nil end
    netList:clearSelection()
    for _, net in pairs(vaultState.networks) do
        net.issued = net.issued or {}
        net.name = net.name or net.network.id
        rows[#rows + 1] = net
        if net == current then netList:select(#rows, true) end
    end
    showMembers()
end
refresh()

netList:callback(function(self, _, eventName, ...)
    self:defaultCallback(_, eventName, ...)
    showMembers()
    local net = selected(self)
    if net and eventName == "touch" then
        output:push(("%s: founder %s, you are %s, %d issued."):format(net.name,
            fingerprint(net.network.founder), roleOf(net), #net.issued))
    end
end)

local function save()
    local saved, err = clientEnv.vault:save()
    if not saved then output:push("Vault not saved: " .. tostring(err)) end
end

-- Network work never waits: each step hands its result to a callback. guard reports a
-- callback's error in the feedback box instead of losing it in the event handler.
local function guard(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then output:push("Error: " .. tostring(err)) end
    end
end

-- Opens the prompt interface (one at a time). confirm gets the typed text or chosen value.
local function ask(message, args, confirm, deny)
    if clientEnv.loadedInterfaces.prompt then return false end
    args[1], args[2], args[3] = message, confirm, deny
    clientEnv.loadInterface("prompt", args)
    return true
end

-- The selected network, if this device may sign for it (founder or admin).
local function administered()
    local net = selected(netList)
    if not net then output:push("Select a network first.") return nil end
    if roleOf(net) ~= "admin" or not networks.authority(net.network, identity.public) then
        output:push("Only the founder and admins of " .. net.name .. " can do that.")
        return nil
    end
    return net
end

local function button(x, y, text, color, action)
    local b = gui.TextButton(currenttab, x, y, nil, 1, text, 0)
    b:backgroundColor(color)
    b:callback(function(self, _, eventName)
        if eventName == "touch" then action(self) end
    end)
    return b
end

local y1 = netList:y() + netList:height() + 1
local y2, y3 = y1 + 2, y1 + 4

-- NEW: found a network; the founder holds an admin membership like any other admin.
button(3, y1, "[NEW]", 0x00ff00, function()
    ask("Name the new network", {textInput = {width = 24}}, guard(function(name)
        if not name or name == "" then return end
        local network = networks.create(identity)
        local net = {name = name:sub(1, 24), network = network, issued = {},
            membership = networks.issue(identity, network, identity.public, "admin")}
        vaultState.networks[network.id] = net
        refresh()
        save()
        output:push(("Founded %s. Gate owners type trust %s before you add their gates."):format(net.name, clientEnv.vault:fingerprint()))
    end))
end)

-- JOIN: ask the invitation an admin is hosting nearby.
local joining = false
button(9, y1, "[JOIN]", 0x00ffff, function()
    if joining then output:push("Still waiting for the admin.") return end
    ask("Your name in the network", {textInput = {width = 24}}, guard(function(name)
        if not name or name == "" then return end
        joining = true
        output:push("Asking for an invitation; the admin has to accept.")
        invite.join(identity, name:sub(1, 24), 120, guard(function(grant, role)
            joining = false
            if not grant then output:push("Not joined: " .. tostring(role)) return end
            local net = vaultState.networks[grant.network.id] or {issued = {}}
            net.name, net.network, net.revoked, net.membership = tostring(grant.name):sub(1, 24), grant.network, grant.revoked, grant.membership
            vaultState.networks[grant.network.id] = net
            refresh()
            save()
            output:push(("Joined %s as %s. Founder %s: check it matches the founder's device."):format(net.name, role, fingerprint(grant.network.founder)))
        end))
    end))
end)

-- INVITE: host an invitation for the selected network until STOP. Each request is answered in
-- a prompt: CONFIRM accepts with the chosen role, CANCEL denies. A timer offers the next
-- queued request whenever no prompt is open.
local host, hostNet, queue, timer = nil, nil, {}, nil

local function accept(request, role)
    local net = hostNet
    if role == "admin" then
        local admins = {table.unpack(net.network.admins)}
        admins[#admins + 1] = request.key
        net.network = networks.setAdmins(identity, net.network, admins)
    end
    local m = networks.issue(identity, net.network, request.key, role)
    net.issued[#net.issued + 1] = {name = request.name, member = request.key, role = role, serial = m.serial}
    host.accept(request, {name = net.name, network = net.network, revoked = net.revoked, membership = m})
    showMembers()
    save()
    output:push(("Accepted %s as %s."):format(request.name, role))
    if role == "admin" then output:push("The admin list changed: PUSH it to the network's gates.") end
end

local function nextRequest()
    local request = queue[1]
    if not host or not request or clientEnv.loadedInterfaces.prompt then return end
    table.remove(queue, 1)
    local roles = {"user", "moderator"}
    if hostNet.network.founder == identity.public then roles[3] = "admin" end
    local who = fingerprint(request.key)
    output:push(("%s %s asks to join %s."):format(request.name, who, hostNet.name))
    ask(request.name:sub(1, 16) .. " " .. who, {dropdown = {list = roles, index = 1}},
        guard(function(role) accept(request, role or "user") end),
        function()
            host.deny(request)
            output:push("Denied " .. request.name .. ".")
        end)
end

button(16, y1, "[INVITE]", 0xffff00, function(self)
    if host then
        event.cancel(timer)
        host.stop()
        host, hostNet, queue = nil, nil, {}
        self:text("[INVITE]")
        output:push("Invitation closed.")
        return
    end
    local net = administered()
    if not net then return end
    host, hostNet = invite.host(net, function(request) queue[#queue + 1] = request end), net
    timer = event.timer(0.5, guard(nextRequest), math.huge)
    self:text("[ STOP ]")
    output:push("Inviting to " .. net.name .. ". Members press JOIN on their device.")
end)

-- ADD GATE: issue a gate membership to a connected public gate and have it join. The gate must
-- trust this network's founder. The gate then serves only members, so it is closed here; SCAN
-- on the Dialing tab opens it again as a member.
button(3, y2, "[ADD GATE]", 0x00ff00, function()
    local net = administered()
    if not net then return end
    local names, byName = {}, {}
    for _, connection in ipairs(gateConnections) do
        if not connection.net then
            local label = connection.name .. " " .. connection.address:sub(1, 4)
            names[#names + 1], byName[label] = label, connection
        end
    end
    if #names == 0 then output:push("No public gate connected: SCAN on the Dialing tab first.") return end
    ask("Add which gate to " .. net.name .. "?", {dropdown = {list = names, index = 1}}, guard(function(label)
        local connection = byName[label]
        if not connection then return end
        local m = networks.issue(identity, net.network, connection.key, "gate")
        connection.proxy:async(guard(function(ok, err)
            if ok ~= true then output:push("Not added: " .. tostring(err)) return end
            net.issued[#net.issued + 1] = {name = connection.name, member = connection.key, role = "gate", serial = m.serial}
            for i, c in ipairs(gateConnections) do
                if c == connection then table.remove(gateConnections, i) break end
            end
            pcall(connection.proxy.close, connection.proxy)
            showMembers()
            save()
            output:push(connection.name .. " joined " .. net.name .. ". SCAN again to open it as a member.")
        end)).join(net.network, m)
    end))
end)

-- REVOKE: add the selected member's serial to the network's signed revocation list. A revoked
-- admin also leaves the admin list. PUSH sends the change to the gates.
button(14, y2, "[REVOKE]", 0xff0000, function()
    local net = administered()
    if not net then return end
    local m = selected(memberList)
    if not m or m.revoked then output:push("Select a member to revoke.") return end
    ask("Revoke " .. m.name .. " (" .. m.role .. ")?", {}, guard(function()
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
        output:push(("Revoked %s. PUSH to tell the gates."):format(m.name))
    end))
end)

-- PUSH: give every connected gate of the selected network its newest network record and
-- revocation list. Gates also pass them on to each other when they sync.
button(3, y3, "[PUSH]", 0xffff00, function()
    local net = selected(netList)
    if not net then output:push("Select a network first.") return end
    local waiting, sent, failed = 1, 0, 0
    local function done()
        waiting = waiting - 1
        if waiting > 0 then return end
        output:push(("Pushed %s to %d gates%s."):format(net.name, sent, failed > 0 and (", " .. failed .. " failed") or ""))
    end
    for _, connection in ipairs(gateConnections) do
        if connection.net and connection.net.network.id == net.network.id then
            waiting = waiting + 1
            connection.proxy:async(guard(function(ok, err)
                if ok == true then
                    sent = sent + 1
                else
                    failed = failed + 1
                    output:push(connection.name .. ": " .. tostring(err))
                end
                done()
            end)).network({network = net.network, revoked = net.revoked})
        end
    end
    done()
end)

-- LEAVE: forget the selected network on this device.
button(10, y3, "[LEAVE]", 0xff0000, function()
    local net = selected(netList)
    if not net then output:push("Select a network first.") return end
    ask("Forget " .. net.name .. " on this device?", {}, guard(function()
        vaultState.networks[net.network.id] = nil
        refresh()
        save()
        output:push("Left " .. net.name .. ".")
    end))
end)
