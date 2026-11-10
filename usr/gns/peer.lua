-- GNS peer service: GNS devices near each other chat and share gates. Each client exposes the
-- gns-peer endpoint and offers it on disco. A connection first proves both device keys with the
-- gate.open handshake (handshake.lua), so every chat line and share comes with a verified
-- fingerprint; the name beside it is only what the sender calls itself.
local api = require("api")
local disco = require("disco")
local component = require("component")
local handshake = dofile("/usr/gns/handshake.lua")
local fingerprint = dofile("/usr/gns/vault.lua").fingerprint

local peer = {ENDPOINT = "gns-peer", PORT = 162, MAX_TEXT = 200, MAX_ROWS = 50, MAX_NAME = 24}

local function text(value, max)
    return type(value) == "string" and value:sub(1, max) or nil
end

-- A database row with only the fields GNS uses, or nil when it is not one. IDCs come along only
-- when the sender chose to include them (they open the gate's iris); at most 16, as numbers.
function peer.cleanRow(row)
    if type(row) ~= "table" or not text(row.Name, 32) or type(row.Address) ~= "table" then return nil end
    local address = {}
    for _, kind in ipairs({"MW", "PG", "UN"}) do
        local glyphs, list = row.Address[kind], {}
        if type(glyphs) == "table" then
            for i = 1, math.min(#glyphs, 9) do list[#list + 1] = text(glyphs[i], 32) end
        end
        address[kind] = list
    end
    local idcs = {}
    if type(row.IDCs) == "table" then
        for i = 1, math.min(#row.IDCs, 16) do
            local code = math.tointeger(tonumber(row.IDCs[i]))
            if code and code >= 0 then idcs[#idcs + 1] = code end
        end
    end
    -- Where the gate is: a dimension and, when known, its coordinates, all whole numbers.
    local location
    if type(row.Location) == "table" then
        local function whole(v) v = math.tointeger(tonumber(v)) return v and math.abs(v) < 2^31 and v or nil end
        local l = row.Location
        local dim, x, y, z = whole(l.dimension), whole(l.x), whole(l.y), whole(l.z)
        if dim then location = {dimension = dim} end
        if dim and x and y and z then location.x, location.y, location.z = x, y, z end
    end
    local kind = (row.Type == "PG" or row.Type == "UN") and row.Type or "MW"
    -- A gate key is 22 characters (entries.lua): anything else is not one.
    local key = type(row.key) == "string" and #row.key == 22 and row.key or nil
    return {Name = text(row.Name, 32), Type = kind, Address = address, IDCs = idcs, key = key, Location = location}
end

-- Starts the service. identity = {private, public}; pins maps a peer modem to the device key seen
-- there first; name is what this device calls itself; on = {chat(from, line), share(from, rows,
-- signed)}, where from = {fingerprint, name}. Returns a node: find, chat, share, stop.
function peer.start(identity, pins, name, on)
    local sessions = setmetatable({}, {__mode = "k"}) -- connection → true once opened
    local function from(senderName)
        local conn = api.caller()
        if not sessions[conn] then error("call open first", 0) end
        return {fingerprint = sessions[conn], name = text(senderName, peer.MAX_NAME) or "?"}
    end
    local lib = {
        open = {function(request)
            local conn = api.caller()
            local reply, reason = handshake.accept(identity, conn, request)
            if not reply then error(reason, 0) end
            sessions[conn] = fingerprint(request.key)
            return reply
        end, "Proves both devices' keys"},
        chat = {function(line, senderName)
            on.chat(from(senderName), tostring(line):sub(1, peer.MAX_TEXT))
            return true
        end, "A chat line"},
        share = {function(rows, signed, senderName)
            local sender, clean = from(senderName), {}
            if type(rows) == "table" then
                for i = 1, math.min(#rows, peer.MAX_ROWS) do clean[#clean + 1] = peer.cleanRow(rows[i]) end
            end
            local entries = {}
            if type(signed) == "table" then
                for i = 1, math.min(#signed, peer.MAX_ROWS) do entries[#entries + 1] = signed[i] end
            end
            on.share(sender, clean, entries)
            return #clean
        end, "Offers database rows, with the signed gate entries behind them"},
    }
    local endpoint = api.expose(peer.ENDPOINT, lib, peer.PORT)
    disco.offer(peer.ENDPOINT, peer.PORT)

    local node, open = {}, {} -- open: modem → {proxy, address, fingerprint}
    local own = component.modem.address

    local function connect(address, callback)
        if open[address] then return callback(open[address]) end
        api.connectAsync(peer.ENDPOINT, peer.PORT, address, function(proxy, err)
            if not proxy then return callback(nil, err) end
            handshake.openAsync(proxy, identity, pins, nil, function(reply, reason)
                if not reply then
                    proxy:close()
                    return callback(nil, reason == "gate key changed" and "device key changed" or reason)
                end
                open[address] = {proxy = proxy, address = address, fingerprint = fingerprint(reply.key)}
                callback(open[address])
            end)
        end, nil, 3)
    end

    local function drop(address)
        local device = open[address]
        open[address] = nil
        if device then pcall(device.proxy.close, device.proxy) end
    end

    -- Finds GNS devices on disco and opens each with a fresh handshake. callback(devices,
    -- failures): devices are {address, fingerprint, name}; failures are {name, address, reason}.
    function node.find(callback)
        disco.findAsync(peer.ENDPOINT, 2, function(found)
            local devices, failures, waiting = {}, {}, 1
            local function done()
                waiting = waiting - 1
                if waiting == 0 then callback(devices, failures) end
            end
            for _, host in ipairs(found) do
                if host.address ~= own then
                    waiting = waiting + 1
                    drop(host.address)
                    connect(host.address, function(device, reason)
                        if device then
                            device.name = host.name
                            devices[#devices + 1] = device
                        else
                            failures[#failures + 1] = {name = host.name, address = host.address, reason = tostring(reason)}
                        end
                        done()
                    end)
                end
            end
            done()
        end)
    end

    -- Calls fn on the device's proxy; a device that stopped answering is dropped.
    local function call(device, fn, callback, ...)
        if not device.proxy.connected then
            drop(device.address)
            if callback then callback(false, "no longer connected: FIND again") end
            return
        end
        open[device.address] = open[device.address] or device
        device.proxy:async(function(ok, result)
            if ok ~= true then drop(device.address) end
            if callback then callback(ok == true, result) end
        end)[fn](...)
    end

    node.MAX_TEXT = peer.MAX_TEXT
    function node.chat(device, line, callback) call(device, "chat", callback, line, name) end
    function node.share(device, rows, signed, callback) call(device, "share", callback, rows, signed, name) end

    function node.stop()
        endpoint:shutdown()
        disco.withdraw(peer.ENDPOINT)
        for address in pairs(open) do drop(address) end
    end

    return node
end

return peer
