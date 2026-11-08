-- GNS gate endpoint: serves the gate's functions over QuickOS api. Every function except open
-- needs a connection that has passed gate.open (see handshake.lua).
local api = require("api")
local ecc = require("ecc")
local serialization = require("serialization")
local handshake = dofile("/usr/gns/handshake.lua")

local gate = {}

-- The gate's key pair, made on first run. Gate computers start unattended, so it is not
-- password-protected; the computer itself has to be kept out of reach.
function gate.identity(path)
    local file = io.open(path, "rb")
    if file then
        local identity = serialization.unserialize(file:read("*a"))
        file:close()
        if type(identity) == "table" then return identity end
    end
    local private, public = ecc.keypair()
    local identity = {private = tostring(private), public = tostring(public)}
    file = assert(io.open(path, "wb"))
    file:write(serialization.serialize(identity))
    file:close()
    return identity
end

-- Starts the endpoint. stargate is the JSG stargate component (or a stand-in with the same
-- methods). Returns the api endpoint; call :shutdown() on it to stop.
function gate.start(identity, stargate, port)
    local sessions = setmetatable({}, {__mode = "k"}) -- connection → {key, role}

    local function status()
        local state, outgoing = stargate.getGateStatus()
        return {type = stargate.getGateType(), state = state, outgoing = outgoing, iris = stargate.getIrisState()}
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
    }
    return api.expose(handshake.ENDPOINT, lib, port or handshake.PORT)
end

return gate
