-- GNS gate entries: each gate signs its own entry, so a device that passes it on cannot change
-- it. A client's address book of signed entries maps a gate's public key to its newest entry.
--
-- entry = {key, seq, name, type = "MW" | "PG" | "UN", dim, address = {MW = {...}, PG = {...},
--          UN = {...}}, retired = true | nil, sig}
local ecc = require("ecc")

local entries = {MAX = 1000} -- the most entries one address book keeps

local TYPES = {MW = true, PG = true, UN = true}

local function glyphs(list)
    local parts = {string.pack(">B", #list)}
    for i = 1, #list do parts[i + 1] = string.pack(">s1", list[i]) end
    return table.concat(parts)
end

local function validGlyphs(list)
    if list == nil then return true end
    if type(list) ~= "table" or #list > 9 then return false end
    for i = 1, #list do
        if type(list[i]) ~= "string" or #list[i] > 32 then return false end
    end
    return true
end

-- Checks field types and sizes. Returns true, or nil and the reason.
local function valid(e)
    if type(e) ~= "table" then return nil, "not an entry" end
    if type(e.key) ~= "string" or #e.key ~= 22 then return nil, "bad key" end
    if math.type(e.seq) ~= "integer" or e.seq < 1 or e.seq > 0xFFFFFFFF then return nil, "bad seq" end
    if type(e.name) ~= "string" or #e.name == 0 or #e.name > 32 then return nil, "bad name" end
    if not TYPES[e.type] then return nil, "bad type" end
    if math.type(e.dim) ~= "integer" or e.dim < -0x80000000 or e.dim > 0x7FFFFFFF then return nil, "bad dim" end
    local a = e.address
    if type(a) ~= "table" or not (validGlyphs(a.MW) and validGlyphs(a.PG) and validGlyphs(a.UN)) then
        return nil, "bad address"
    end
    return true
end

-- The exact bytes a gate signs. Every field except sig is covered.
function entries.signedBytes(e)
    local a = e.address
    return string.pack(">s1s1I4s1s1i4B", "GNSE2", e.key, e.seq, e.name, e.type, e.dim, e.retired and 1 or 0)
        .. glyphs(a.MW or {}) .. glyphs(a.PG or {}) .. glyphs(a.UN or {})
end

-- Signs fields as the gate with this identity. fields.seq must be higher than any earlier entry.
function entries.sign(identity, fields)
    local e = {key = identity.public, seq = fields.seq, name = fields.name, type = fields.type,
        dim = fields.dim, address = fields.address, retired = fields.retired or nil}
    assert(valid(e))
    e.sig = tostring(ecc.sign(identity.private, entries.signedBytes(e)))
    return e
end

-- Returns true if the entry is well formed and signed by its own key, or nil and the reason.
function entries.verify(e)
    local ok, reason = valid(e)
    if not ok then return nil, reason end
    if type(e.sig) ~= "string" then return nil, "bad signature" end
    local done, good = pcall(ecc.verify, e.key, entries.signedBytes(e), e.sig)
    if not (done and good == true) then return nil, "bad signature" end
    return true
end

-- Adds e to book if it is valid and newer than what book holds for that gate.
-- Returns "added" or "updated", or nil and the reason it was refused.
function entries.merge(book, e)
    local ok, reason = entries.verify(e)
    if not ok then return nil, reason end
    local current = book[e.key]
    if current and current.seq >= e.seq then return nil, "not newer" end
    if not current then
        local count = 0
        for _ in pairs(book) do count = count + 1 end
        if count >= entries.MAX then return nil, "address book full" end
    end
    book[e.key] = e
    return current and "updated" or "added"
end

-- Merges a list of entries. Returns how many were taken and a list of {entry, reason} refused.
function entries.mergeAll(book, list)
    local taken, refused = 0, {}
    if type(list) ~= "table" then return 0, {{nil, "not a list"}} end
    for i = 1, #list do
        local result, reason = entries.merge(book, list[i])
        if result then taken = taken + 1
        elseif reason ~= "not newer" then refused[#refused + 1] = {list[i], reason} end
    end
    return taken, refused
end

return entries
