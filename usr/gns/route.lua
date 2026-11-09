-- GNS routes: signed dial instructions a gate carries out, and passes on to the next gate of the
-- route through its open wormhole (OC modem messages cross it). A dial-back is a route of one
-- hop. Every gate checks the signature and the signer's role offline, so no gate on the way needs
-- the signer's address book or connection.
--
-- route = {id, key, every, hops = {{address = {MW, PG, UN}, idc, delay}, ...}, grants, sig}
--   key     the signer's public key; grants: the signer's grants, for the gates of the route
--   every   seconds between repeats (a scheduled dial; admins only), or 0
--   delay   seconds a gate waits before it dials that hop
local ecc = require("ecc")

local route = {MAX_HOPS = 8}

local function glyphs(list)
    local parts = {string.pack(">B", #list)}
    for i = 1, #list do parts[i + 1] = string.pack(">s1", list[i]) end
    return table.concat(parts)
end

local function validGlyphs(list)
    if list == nil then return true end
    if type(list) ~= "table" or #list > 9 then return false end
    for i = 1, #list do if type(list[i]) ~= "string" or #list[i] > 32 then return false end end
    return true
end

local function whole(n, max) return math.type(n) == "integer" and n >= 0 and n <= max end

local function bytes(r)
    local parts = {string.pack(">s1s1s1I4B", "GNSQ1", r.id, r.key, r.every, #r.hops)}
    for _, h in ipairs(r.hops) do
        local a = h.address
        parts[#parts + 1] = glyphs(a.MW or {}) .. glyphs(a.PG or {}) .. glyphs(a.UN or {})
            .. string.pack(">i4I2", h.idc or -1, h.delay)
    end
    return table.concat(parts)
end

-- Checks the route's form and signature. Returns true, or nil and the reason.
function route.verify(r)
    if type(r) ~= "table" or type(r.id) ~= "string" or #r.id ~= 8 or type(r.key) ~= "string" or #r.key ~= 22
        or not whole(r.every, 86400 * 7) or type(r.hops) ~= "table" or #r.hops == 0 or #r.hops > route.MAX_HOPS then
        return nil, "bad route"
    end
    for _, h in ipairs(r.hops) do
        local a = type(h) == "table" and h.address
        if type(a) ~= "table" or not (validGlyphs(a.MW) and validGlyphs(a.PG) and validGlyphs(a.UN))
            or not whole(h.delay, 3600) or (h.idc ~= nil and not whole(h.idc, 0x7FFFFFFF)) then
            return nil, "bad route"
        end
    end
    local ok, good = pcall(ecc.verify, r.key, bytes(r), r.sig)
    if not (ok and good == true) then return nil, "bad route signature" end
    return true
end

-- A route signed by identity = {private, public}. hops as above; every 0 for one run.
function route.sign(identity, hops, every, grantList)
    local r = {id = tostring(ecc.random.random()):sub(1, 8), key = identity.public, every = every or 0,
        hops = hops, grants = grantList or {}}
    r.sig = tostring(ecc.sign(identity.private, bytes(r)))
    return r
end

-- True if address (a hop's {MW, PG, UN}) names the gate whose own address is own (the same form):
-- the first six glyphs of a galaxy both have match.
function route.names(address, own)
    for _, galaxy in ipairs({"MW", "PG", "UN"}) do
        local a, b = address[galaxy], own[galaxy]
        if type(a) == "table" and type(b) == "table" and #a >= 6 and #b >= 6 then
            local same = true
            for i = 1, 6 do same = same and a[i] == b[i] end
            if same then return true end
        end
    end
    return false
end

return route
