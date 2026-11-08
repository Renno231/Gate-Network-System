-- GNS gate: serves the gate over QuickOS api, publishes its own signed entry and keeps an
-- address book of other gates' entries. Every function except open needs a connection that
-- has passed gate.open (see handshake.lua).
local api = require("api")
local ecc = require("ecc")
local serialization = require("serialization")
local handshake = dofile("/usr/gns/handshake.lua")
local entries = dofile("/usr/gns/entries.lua")

local gate = {}

local TYPE = {MILKYWAY = "MW", PEGASUS = "PG", UNIVERSE = "UN"}

-- The gate's saved state: key pair, entry sequence number, address book and pinned peer keys.
-- The key pair is made on first run. Gate computers start unattended, so the file is not
-- password-protected; the computer itself has to be kept out of reach.
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

-- Signs the gate's own entry again when its name, type, dimension or address changed.
-- Returns the entry.
local function publish(state, stargate, settings)
    local address = {}
    for jsgName, glyphs in pairs(stargate.stargateAddress or {}) do
        if TYPE[jsgName] then address[TYPE[jsgName]] = glyphs end
    end
    local fields = {name = settings.name, type = TYPE[stargate.getGateType()] or "MW",
        dim = settings.dim or 0, address = address}
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
-- methods); settings = {name, dim, port}. Returns a node with the endpoint, the state and
-- sync(peerModem); call node.endpoint:shutdown() to stop.
function gate.start(state, stargate, settings)
    local sessions = setmetatable({}, {__mode = "k"}) -- connection → {key, role}
    local identity = state.identity
    publish(state, stargate, settings)

    local function status()
        local gateState, outgoing = stargate.getGateStatus()
        return {type = stargate.getGateType(), state = gateState, outgoing = outgoing, iris = stargate.getIrisState()}
    end

    -- Wraps a function so it only runs for a connection that has opened the gate.
    local function opened(fn)
        return function(...)
            local session = sessions[api.caller()]
            if not session then error("call open first", 0) end
            return fn(session, ...)
        end
    end

    local lib = {
        open = {function(request)
            local conn = api.caller()
            if request and request.network and request.network ~= "" then
                error("private networks are not supported yet", 0)
            end
            local reply, reason = handshake.accept(identity, conn, request)
            if not reply then error(reason, 0) end
            sessions[conn] = {key = request.key, role = "user"}
            reply.status = status()
            return reply
        end, "Proves both sides' keys and returns the gate status"},
        status = {opened(function() return status() end), "The gate's type, state and iris"},
        entries = {opened(function()
            local list = {}
            for _, e in pairs(state.book) do list[#list + 1] = e end
            return list
        end), "Every gate entry this gate holds, each signed by its own gate"},
    }
    local node = {state = state, endpoint = api.expose(handshake.ENDPOINT, lib, settings.port or handshake.PORT)}

    -- Pulls the address book of the gate at peerModem and keeps the entries that verify.
    -- Returns how many were taken and the refused {entry, reason} pairs, or nil and a reason.
    function node.sync(peerModem)
        local ok, proxy = pcall(api.connect, handshake.ENDPOINT, settings.port or handshake.PORT, peerModem, nil, 5)
        if not ok then return nil, tostring(proxy) end
        local reply, reason = handshake.open(proxy, identity, state.pins)
        local taken, refused
        if reply then
            local got, list = proxy.entries()
            if got == true then
                taken, refused = entries.mergeAll(state.book, list)
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
