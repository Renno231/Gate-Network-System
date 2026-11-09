-- GNS gate.open handshake: each side proves which key it is, bound to both modem addresses.
-- The client signs  "GNS2" | "client" | nonce | client modem | gate modem
-- The gate signs    "GNS2" | "gate"   | nonce | client modem | gate modem
-- OC sets the sender address of a modem message, so a proof only works from the device that
-- made it, to the gate it was made for. See docs/design/authentication.md.
local ecc = require("ecc")

local handshake = {ENDPOINT = "gns", PORT = 160}

local function message(role, nonce, clientModem, gateModem)
    return string.pack(">s1s1s1s1s1", "GNS2", role, nonce, clientModem, gateModem)
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
    local clientModem, gateModem = conn.address, conn.modem.address
    if not verify(request.key, message("client", request.nonce, clientModem, gateModem), request.sig) then
        return nil, "client proof rejected"
    end
    return {
        key = identity.public,
        sig = tostring(ecc.sign(identity.private, message("gate", request.nonce, clientModem, gateModem))),
    }
end

-- Client side. proxy comes from api.connect; identity = {private, public}; pins maps a gate
-- modem address to the gate key seen there first; extra: more request fields (the caller's
-- grants). The signed gate.open request, and the function that checks the gate's answer
-- (ok, reply): it returns the reply and whether this was the first contact, or nil, the reason
-- and (when the key changed) the new key. Saving pins is the caller's job.
local function request(proxy, identity, pins, extra)
    local conn = proxy:getConnection()
    local clientModem, gateModem = conn.modem.address, conn.address
    local nonce = tostring(ecc.random.random()):sub(1, 16)
    local req = {key = identity.public, nonce = nonce,
        sig = tostring(ecc.sign(identity.private, message("client", nonce, clientModem, gateModem)))}
    for k, v in pairs(extra or {}) do req[k] = v end
    return req, function(ok, reply)
        if ok ~= true then return nil, tostring(reply) end
        if type(reply) ~= "table" or not verify(reply.key, message("gate", nonce, clientModem, gateModem), reply.sig) then
            return nil, "gate proof rejected"
        end
        local pinned = pins[gateModem]
        if pinned and pinned ~= reply.key then return nil, "gate key changed", reply.key end
        pins[gateModem] = reply.key
        return reply, pinned == nil
    end
end

function handshake.open(proxy, identity, pins, extra)
    local req, check = request(proxy, identity, pins, extra)
    return check(proxy.open(req))
end

-- handshake.open without waiting: callback gets what handshake.open would return.
function handshake.openAsync(proxy, identity, pins, extra, callback)
    local req, check = request(proxy, identity, pins, extra)
    proxy:async(function(...) callback(check(...)) end).open(req)
end

-- Signed passes: an incoming traveller's device answers the gate's fresh challenge, so a pass
-- cannot be replayed.  "GNSP1" | challenge | gate key
local function passBytes(challenge, gateKey) return string.pack(">s1s1s1", "GNSP1", challenge, gateKey) end
function handshake.pass(identity, challenge, gateKey)
    return tostring(ecc.sign(identity.private, passBytes(challenge, gateKey)))
end
function handshake.checkPass(key, challenge, gateKey, sig)
    return type(challenge) == "string" and verify(key, passBytes(challenge, gateKey), sig)
end

-- A new wake key: 32 hex digits. OC compares wake messages as UTF-8 text, so the key is text;
-- random bytes would be mangled into a weaker key.
function handshake.wakeKey()
    local hex = {}
    for _ = 1, 2 do
        hex[#hex + 1] = (tostring(ecc.random.random()):sub(1, 8):gsub(".", function(c) return ("%02x"):format(c:byte()) end))
    end
    return table.concat(hex)
end

handshake.message = message
return handshake
