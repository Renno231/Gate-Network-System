-- GNS gate.open handshake: each side proves which key it is, bound to both modem addresses.
-- The client signs  "GNS1" | "client" | nonce | client modem | gate modem | network
-- The gate signs    "GNS1" | "gate"   | nonce | client modem | gate modem | network
-- OC sets the sender address of a modem message, so a proof only works from the device that
-- made it, to the gate it was made for. See docs/design/authentication.md.
local ecc = require("ecc")
local networks = dofile("/usr/gns/networks.lua")

local handshake = {ENDPOINT = "gns", PORT = 160}

local function message(role, nonce, clientModem, gateModem, network)
    return string.pack(">s1s1s1s1s1s1", "GNS1", role, nonce, clientModem, gateModem, network or "")
end

local function verify(key, signed, signature)
    if type(key) ~= "string" or type(signature) ~= "string" then return false end
    local ok, valid = pcall(ecc.verify, key, signed, signature)
    return ok and valid == true
end

-- Gate side. identity = {private, public}; conn is the caller's tnet connection.
-- Returns the gate's reply fields, or nil and the reason the client's proof was refused.
function handshake.accept(identity, conn, request)
    if type(request) ~= "table" or type(request.nonce) ~= "string" or #request.nonce ~= 16 then
        return nil, "bad request"
    end
    local network = request.network or ""
    local clientModem, gateModem = conn.address, conn.modem.address
    if not verify(request.key, message("client", request.nonce, clientModem, gateModem, network), request.sig) then
        return nil, "client proof rejected"
    end
    return {
        key = identity.public,
        sig = tostring(ecc.sign(identity.private, message("gate", request.nonce, clientModem, gateModem, network))),
    }
end

-- Client side. proxy comes from api.connect; identity = {private, public}; pins maps a gate
-- modem address to the gate key seen there first. Returns the reply and whether this was the
-- first contact, or nil, the reason and (when the key changed) the new key. Saving pins is the
-- caller's job.
-- net is nil for the public network, or {network, revoked, membership} for a private one; the
-- gate must then show a valid "gate" membership of that network.
function handshake.open(proxy, identity, pins, net)
    local conn = proxy:getConnection()
    local clientModem, gateModem = conn.modem.address, conn.address
    local network = net and net.network.id or ""
    local nonce = tostring(ecc.random.random()):sub(1, 16)
    local ok, reply = proxy.open({
        key = identity.public,
        nonce = nonce,
        network = network,
        membership = net and net.membership,
        sig = tostring(ecc.sign(identity.private, message("client", nonce, clientModem, gateModem, network))),
    })
    if ok ~= true then return nil, tostring(reply) end
    if type(reply) ~= "table" or not verify(reply.key, message("gate", nonce, clientModem, gateModem, network), reply.sig) then
        return nil, "gate proof rejected"
    end
    if net and networks.check(net.network, net.revoked, reply.membership, reply.key) ~= "gate" then
        return nil, "not a gate of this network"
    end
    local pinned = pins[gateModem]
    if pinned and pinned ~= reply.key then return nil, "gate key changed", reply.key end
    pins[gateModem] = reply.key
    return reply, pinned == nil
end

handshake.message = message
return handshake
