-- GNS gate: serves the gate over QuickOS api, publishes its own signed entry and keeps an
-- address book of other gates' entries. Every function except open needs a connection that
-- has passed gate.open (see handshake.lua). A gate is public until it joins a private network;
-- from then on it serves only that network's members, each within their role.
local api = require("api")
local ecc = require("ecc")
local serialization = require("serialization")
local handshake = dofile("/usr/gns/handshake.lua")
local entries = dofile("/usr/gns/entries.lua")
local networks = dofile("/usr/gns/networks.lua")
local fingerprint = dofile("/usr/gns/vault.lua").fingerprint
local dialing = dofile("/usr/gns/dialing.lua")

local gate = {}

local TYPE = dialing.TYPE

-- The gate's saved state: key pair, entry sequence number, address book, pinned peer keys, the
-- founder fingerprint it trusts (trust) and its private network (net = {network, revoked,
-- membership}). The key pair is made on first run. Gate computers start unattended, so the file
-- is not password-protected; the computer itself has to be kept out of reach.
function gate.load(path)
    local file = io.open(path, "rb")
    local state = file and serialization.unserialize(file:read("*a"))
    if file then file:close() end
    if type(state) ~= "table" or type(state.identity) ~= "table" then
        local private, public = ecc.keypair()
        state = {identity = {private = tostring(private), public = tostring(public)}, seq = 0}
    end
    state.book, state.pins = state.book or {}, state.pins or {}
    state.path = path
    return state
end

function gate.save(state)
    local path = state.path
    state.path = nil
    local file = assert(io.open(path, "wb"))
    file:write(serialization.serialize(state))
    file:close()
    state.path = path
end

local function networkId(state)
    return state.net and state.net.network.id
end

-- Signs the gate's own entry again when its name, type, dimension, address or network changed.
-- Returns the entry.
local function publish(state, stargate, settings)
    local address = {}
    for jsgName, glyphs in pairs(stargate.stargateAddress or {}) do
        if TYPE[jsgName] then address[TYPE[jsgName]] = glyphs end
    end
    local fields = {name = settings.name, type = TYPE[stargate.getGateType()] or "MW",
        dim = settings.dim or 0, address = address, network = networkId(state)}
    local own = state.book[state.identity.public]
    if own then
        fields.seq = own.seq
        fields.key = own.key
        if entries.signedBytes(fields) == entries.signedBytes(own) then return own end
    end
    state.seq = math.max(state.seq, own and own.seq or 0) + 1
    fields.seq = state.seq
    local entry = entries.sign(state.identity, fields)
    state.book[entry.key] = entry
    gate.save(state)
    return entry
end

-- Starts the gate. stargate is the JSG stargate component (or a stand-in with the same
-- methods); dhd is the DHD component or nil; settings = {name, dim, port, kawoosh, idcs}, read
-- live. Returns a node with the endpoint, the state, the dialer, sync(peerModem) and
-- trust(founderFingerprint); call node.stop() to stop.
function gate.start(state, stargate, settings, dhd)
    local sessions = setmetatable({}, {__mode = "k"}) -- connection → {key, role, membership, version}
    local identity = state.identity
    publish(state, stargate, settings)
    local dialer = dialing.new(stargate, dhd, settings)
    local status = dialer.status

    -- Changes whenever the network record or revocation list does, so sessions are checked again.
    local function netVersion()
        local net = state.net
        return net and (net.network.seq .. ":" .. (net.revoked and net.revoked.seq or 0)) or "public"
    end

    -- Wraps a function so it only runs for an opened connection whose role is at least minRole.
    -- On a private gate the caller's membership is checked again after any network change, so a
    -- revocation also ends connections that are already open.
    local function opened(minRole, fn)
        return function(...)
            local conn = api.caller()
            local session = sessions[conn]
            if not session then error("call open first", 0) end
            local version = netVersion()
            if session.version ~= version then
                local role, reason = "user", nil
                if state.net then
                    role, reason = networks.check(state.net.network, state.net.revoked, session.membership, session.key)
                end
                if not role then
                    sessions[conn] = nil
                    error(reason, 0)
                end
                session.role, session.version = role, version
            end
            if networks.RANK[session.role] < networks.RANK[minRole] then
                error("needs the " .. minRole .. " role", 0)
            end
            return fn(session, ...)
        end
    end

    local lib = {
        open = {function(request)
            local conn = api.caller()
            local network = type(request) == "table" and request.network or ""
            if state.net and network ~= state.net.network.id then error("private gate", 0) end
            if not state.net and network ~= "" then error("not in that network", 0) end
            local reply, reason = handshake.accept(identity, conn, request)
            if not reply then error(reason, 0) end
            local role = "user"
            if state.net then
                role, reason = networks.check(state.net.network, state.net.revoked, request.membership, request.key)
                if not role then error(reason, 0) end
                reply.membership = state.net.membership
            end
            sessions[conn] = {key = request.key, role = role, membership = request.membership, version = netVersion()}
            reply.status = status()
            return reply
        end, "Proves both sides' keys (and the caller's membership on a private gate); returns the gate status"},

        status = {opened("user", function() return status() end), "The gate's type, state and iris"},

        dial = {opened("user", function(_, address, opts)
            opts = type(opts) == "table" and opts or {}
            return dialer.dial(address, {fast = opts.fast == true, idc = math.tointeger(opts.idc)})
        end), "Dials an address {MW = {...}, PG = {...}, UN = {...}}; opts {fast, idc}. Returns the glyph count, cost and duration"},

        closeWormhole = {opened("user", function()
            return dialer.close()
        end), "Stops a dial in progress or closes the outgoing wormhole"},

        iris = {opened("moderator", function()
            stargate.toggleIris()
            return stargate.getIrisState()
        end), "Toggles the iris (moderator)"},

        entries = {opened("user", function()
            local list, own = {}, networkId(state)
            for _, e in pairs(state.book) do
                if e.network == nil or e.network == own then list[#list + 1] = e end
            end
            return list
        end), "The gate entries this gate holds, each signed by its own gate"},

        join = {opened("user", function(_, network, membership)
            if state.net then error("already in a network", 0) end
            if not state.trust then error("this gate trusts no founder", 0) end
            if not networks.verifyNetwork(network) or fingerprint(network.founder) ~= state.trust then
                error("not the founder this gate trusts", 0)
            end
            local role, reason = networks.check(network, nil, membership, identity.public)
            if role ~= "gate" then error(reason or "needs a gate membership", 0) end
            state.net = {network = network, membership = membership}
            publish(state, stargate, settings)
            gate.save(state)
            return true
        end), "Joins the private network founded by the key this gate trusts"},

        network = {opened("user", function(_, update)
            if not state.net then error("not in a network", 0) end
            local changed = networks.merge(state.net, update)
            if changed then gate.save(state) end
            return changed
        end), "Takes a newer signed network record or revocation list"},

        networkState = {opened("user", function()
            if not state.net then error("not in a network", 0) end
            return {network = state.net.network, revoked = state.net.revoked}
        end), "The network record and revocation list this gate holds"},
    }
    local node = {state = state, dialer = dialer, endpoint = api.expose(handshake.ENDPOINT, lib, settings.port or handshake.PORT)}

    function node.stop()
        node.endpoint:shutdown()
        dialer.stop()
    end

    -- Set by the gate's owner: the fingerprint of the founder whose network this gate may join.
    function node.trust(founderFingerprint)
        state.trust = founderFingerprint
        gate.save(state)
    end

    -- Pulls the network state (on a private gate) and address book of the gate at peerModem and
    -- keeps what verifies. Returns how many entries were taken and the refused {entry, reason}
    -- pairs, or nil and a reason.
    function node.sync(peerModem)
        local ok, proxy = pcall(api.connect, handshake.ENDPOINT, settings.port or handshake.PORT, peerModem, nil, 5)
        if not ok then return nil, tostring(proxy) end
        local reply, reason = handshake.open(proxy, identity, state.pins, state.net)
        local taken, refused
        if reply then
            if state.net then
                local got, update = proxy.networkState()
                if got == true then networks.merge(state.net, update) end
            end
            local got, list = proxy.entries()
            if got == true then
                taken, refused = entries.mergeAll(state.book, list, networkId(state))
            else
                reason = tostring(list)
            end
        end
        proxy:close()
        if not taken then return nil, reason end
        gate.save(state)
        return taken, refused
    end

    return node
end

return gate
