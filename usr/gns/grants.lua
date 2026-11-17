-- GNS grants: who may use or control a gate. A grant is signed by the gate's owner (or, for a
-- user grant, by one of the owner's admins), so a gate checks it offline and keeps no list of
-- members.
--
-- grant = {owner, gate, holder, name, role, serial, signer, by, sig}
--   owner   the owner's public key
--   gate    the gate key it covers, or "" for every gate of that owner
--   holder  the holder's public key; name: their player name
--   role    "user" or "admin"
--   signer  the owner, or an admin of the owner (user grants only), whose own grant is by
--   serial  random, so a cut-off names one grant
local ecc = require("ecc")

local grants = {RANK = {user = 1, admin = 2, owner = 3}, MAX = 16}

local function bytes(g)
    return string.pack(">s1s1s1s1s1s1s1s1", "GNSG1", g.owner, g.gate, g.holder, g.name, g.role, g.serial, g.signer)
end

local function isKey(k) return type(k) == "string" and #k == 22 end

-- budget, when given: {n = signature checks left}; none left counts as a bad signature.
local function signedBy(key, data, sig, budget)
    if not isKey(key) or type(sig) ~= "string" then return false end
    if budget then
        if budget.n <= 0 then return false end
        budget.n = budget.n - 1
    end
    local ok, good = pcall(ecc.verify, key, data, sig)
    return ok and good == true
end

-- Signatures already checked, by signature, with the bytes they sign: a grant shown at every open
-- costs one check. Up to 256, then it starts again.
local verified, nVerified = {}, 0

-- The grant's own fields and signature. Returns true, or nil and the reason.
function grants.valid(g, budget)
    if type(g) ~= "table" or not isKey(g.owner) or not isKey(g.holder) or not isKey(g.signer)
        or not (g.gate == "" or isKey(g.gate)) or (g.role ~= "user" and g.role ~= "admin")
        or type(g.name) ~= "string" or #g.name == 0 or #g.name > 32
        or type(g.serial) ~= "string" or #g.serial ~= 8 then
        return nil, "bad grant"
    end
    local data = bytes(g)
    if verified[g.sig] ~= data then
        if not signedBy(g.signer, data, g.sig, budget) then return nil, "bad grant signature" end
        if nVerified >= 256 then verified, nVerified = {}, 0 end
        verified[g.sig], nVerified = data, nVerified + 1
    end
    return true
end

-- The role grant g gives key at the gate gateKey of owner, or nil and the reason. cut holds the
-- serials that gate has cut off. Every check that needs no signature comes first; budget (see
-- signedBy) bounds the signatures.
function grants.check(g, owner, gateKey, key, cut, budget)
    if type(g) ~= "table" then return nil, "no grant" end
    if g.owner ~= owner then return nil, "grant from another owner" end
    if g.holder ~= key then return nil, "grant belongs to another key" end
    if g.gate ~= "" and g.gate ~= gateKey then return nil, "grant for another gate" end
    if cut[g.serial] then return nil, "grant cut off" end
    local by = g.by
    if g.signer ~= owner then
        if g.role ~= "user" then return nil, "only the owner grants admin" end
        -- Only the owner grants admin, so the signer's own grant is the owner's: one level, which
        -- bounds the signatures a chain of grants can make the gate check.
        if type(by) ~= "table" or by.holder ~= g.signer or by.role ~= "admin" or by.signer ~= owner then
            return nil, "grant not signed by an admin"
        end
        if cut[by.serial] then return nil, "admin's grant cut off" end
    end
    local ok, why = grants.valid(g, budget)
    if not ok then return nil, why end
    if g.signer ~= owner then
        local role, reason = grants.check(by, owner, gateKey, g.signer, cut, budget)
        if role ~= "admin" then return nil, reason == "grant cut off" and "admin's grant cut off" or "grant not signed by an admin" end
    end
    return g.role
end

-- A grant for holder, signed by signer = {private, public}: the owner, or an admin whose own
-- grant is by. gateKey nil or "" covers every gate of the owner.
function grants.issue(signer, owner, gateKey, holder, name, role, by)
    assert(role == "user" or role == "admin", "unknown role")
    local g = {owner = owner, gate = gateKey or "", holder = holder, name = tostring(name):sub(1, 32), role = role,
        serial = tostring(ecc.random.random()):sub(1, 8), signer = signer.public, by = by}
    g.sig = tostring(ecc.sign(signer.private, bytes(g)))
    return g
end

return grants
