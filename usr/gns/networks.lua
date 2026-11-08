-- GNS private networks: signed records that any gate can check offline.
--
-- network    = {id, founder, admins = {key, ...}, seq, sig}             signed by the founder
-- membership = {network, member, role, serial, signer, sig}             signed by the founder or an admin
-- revoked    = {network, seq, serials = {serial, ...}, signer, sig}     signed by the founder or an admin
--
-- Roles: user (dial, read state) < moderator (also gate settings) < admin (also memberships and
-- revocation). "gate" is a gate's own membership, so members can tell the network's gates from
-- impostors. Serials are random, so admins never have to coordinate them.
local ecc = require("ecc")

local networks = {MAX_ADMINS = 16, MAX_REVOKED = 1000}
networks.RANK = {user = 1, gate = 1, moderator = 2, admin = 3}

local function random8()
    return tostring(ecc.random.random()):sub(1, 8)
end

local function list(keys)
    local parts = {string.pack(">I2", #keys)}
    for i = 1, #keys do parts[i + 1] = string.pack(">s1", keys[i]) end
    return table.concat(parts)
end

local function isKey(k) return type(k) == "string" and #k == 22 end
local function isId(s) return type(s) == "string" and #s == 8 end
local function isSeq(n) return math.type(n) == "integer" and n >= 1 and n <= 0xFFFFFFFF end

local function signed(key, bytes, sig)
    if not isKey(key) or type(sig) ~= "string" then return false end
    local ok, good = pcall(ecc.verify, key, bytes, sig)
    return ok and good == true
end

local function networkBytes(n)
    return string.pack(">s1s1s1I4", "GNSN1", n.id, n.founder, n.seq) .. list(n.admins)
end

local function membershipBytes(m)
    return string.pack(">s1s1s1s1s1s1", "GNSM1", m.network, m.member, m.role, m.serial, m.signer)
end

local function revokedBytes(r)
    return string.pack(">s1s1I4s1", "GNSR1", r.network, r.seq, r.signer) .. list(r.serials)
end

-- True if key is the network's founder or one of its admins.
function networks.authority(network, key)
    if key == network.founder then return true end
    for i = 1, #network.admins do
        if network.admins[i] == key then return true end
    end
    return false
end

function networks.verifyNetwork(n)
    if type(n) ~= "table" or not isId(n.id) or not isKey(n.founder) or not isSeq(n.seq) then return nil, "bad network" end
    if type(n.admins) ~= "table" or #n.admins > networks.MAX_ADMINS then return nil, "bad network" end
    for i = 1, #n.admins do if not isKey(n.admins[i]) then return nil, "bad network" end end
    if not signed(n.founder, networkBytes(n), n.sig) then return nil, "bad network signature" end
    return true
end

function networks.verifyRevoked(network, r)
    if type(r) ~= "table" or r.network ~= network.id or not isSeq(r.seq) or type(r.serials) ~= "table"
        or #r.serials > networks.MAX_REVOKED then
        return nil, "bad revocation list"
    end
    for i = 1, #r.serials do if not isId(r.serials[i]) then return nil, "bad revocation list" end end
    if not networks.authority(network, r.signer) then return nil, "revocation not signed by an admin" end
    if not signed(r.signer, revokedBytes(r), r.sig) then return nil, "bad revocation signature" end
    return true
end

-- Checks membership for key against the network and its revocation list (either may be nil
-- for revoked). Returns the role, or nil and the reason.
function networks.check(network, revoked, membership, key)
    local m = membership
    if type(m) ~= "table" then return nil, "membership required" end
    if m.network ~= network.id then return nil, "membership for another network" end
    if m.member ~= key then return nil, "membership belongs to another key" end
    if not networks.RANK[m.role] or not isId(m.serial) then return nil, "bad membership" end
    if not networks.authority(network, m.signer) then return nil, "membership not signed by an admin" end
    if not signed(m.signer, membershipBytes(m), m.sig) then return nil, "bad membership signature" end
    if revoked then
        for i = 1, #revoked.serials do
            if revoked.serials[i] == m.serial then return nil, "membership revoked" end
        end
    end
    return m.role
end

-- Founder: a new network with no admins besides the founder.
function networks.create(founder)
    local n = {id = random8(), founder = founder.public, admins = {}, seq = 1}
    n.sig = tostring(ecc.sign(founder.private, networkBytes(n)))
    return n
end

-- Founder: the same network with a new admin list.
function networks.setAdmins(founder, network, admins)
    local n = {id = network.id, founder = network.founder, admins = admins, seq = network.seq + 1}
    n.sig = tostring(ecc.sign(founder.private, networkBytes(n)))
    return n
end

-- Founder or admin: a membership for memberKey.
function networks.issue(signer, network, memberKey, role)
    assert(networks.RANK[role], "unknown role")
    local m = {network = network.id, member = memberKey, role = role, serial = random8(), signer = signer.public}
    m.sig = tostring(ecc.sign(signer.private, membershipBytes(m)))
    return m
end

-- Founder or admin: the revocation list with serials added. previous may be nil.
function networks.revoke(signer, network, previous, serials)
    local all, seen = {}, {}
    for _, source in ipairs({previous and previous.serials or {}, serials}) do
        for i = 1, #source do
            if not seen[source[i]] then seen[source[i]] = true all[#all + 1] = source[i] end
        end
    end
    local r = {network = network.id, seq = (previous and previous.seq or 0) + 1, serials = all, signer = signer.public}
    r.sig = tostring(ecc.sign(signer.private, revokedBytes(r)))
    return r
end

-- Takes the newer valid network record and revocation list from update = {network, revoked}
-- into net = {network, revoked}. The network id never changes. Returns true if anything changed.
function networks.merge(net, update)
    if type(update) ~= "table" then return false end
    local changed = false
    local n = update.network
    if n and n.id == net.network.id and n.founder == net.network.founder and n.seq > net.network.seq
        and networks.verifyNetwork(n) then
        net.network, changed = n, true
    end
    local r = update.revoked
    if r and (not net.revoked or r.seq > net.revoked.seq) and networks.verifyRevoked(net.network, r) then
        net.revoked, changed = r, true
    end
    return changed
end

return networks
