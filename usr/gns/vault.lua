-- GNS vault: the device's identity key and private data, encrypted under a password.
--
-- File layout: "GNSV1" | salt (16 bytes) | iterations (4 bytes, big-endian) | ecc.encrypt(state)
-- The key comes from PBKDF2 (ecc.keyFromPassword); a wrong password fails the MAC check.
-- Copies (address book backups) use the same layout with "GNSC1", sealed under the password the
-- vault had when they were made.
local ecc = require("ecc")
local fs = require("filesystem")
local serialization = require("serialization")

local vault = {}
vault.ITERATIONS = 10000 -- about 0.5 s on a tier-3 computer
local MAGIC, COPY = "GNSV1", "GNSC1"

-- "GNS-1a2b-3c4d-5e6f-7a8b": the first 8 bytes of SHA-256 of a public key.
function vault.fingerprint(publicKey)
    local hex = ecc.sha256.digest(tostring(publicKey)):toHex():sub(1, 16)
    return "GNS-" .. hex:sub(1, 4) .. "-" .. hex:sub(5, 8) .. "-" .. hex:sub(9, 12) .. "-" .. hex:sub(13, 16)
end

function vault.exists(path)
    return fs.exists(path) or fs.exists(path .. ".new")
end

local Vault = {}
Vault.__index = Vault

local function seal(self, magic, data)
    return magic .. self.salt .. string.pack(">I4", self.iterations)
        .. tostring(ecc.encrypt(serialization.serialize(data), self.key))
end
-- The salt, iterations and ciphertext of sealed bytes, or nil if they are not magic's.
local function split(magic, data)
    if data:sub(1, #magic) ~= magic or #data < #magic + 20 then return nil end
    return data:sub(#magic + 1, #magic + 16), string.unpack(">I4", data, #magic + 17), data:sub(#magic + 21)
end
local function readAll(path)
    local file, reason = io.open(path, "rb")
    if not file then return nil, reason end
    local data = file:read("*a")
    file:close()
    return data
end
-- Writes next to the old file, then replaces it, so a failed write keeps the old file.
-- Returns true, or nil and why. The gate's state is saved the same way (gate.save).
local function replace(path, data)
    local temp = path .. ".new"
    -- Cut off mid-replace last time: the new file was whole (its size checked), so it goes in place.
    if not fs.exists(path) and fs.exists(temp) then fs.rename(temp, path) end
    local file, reason = io.open(temp, "wb")
    if not file then return nil, reason end
    local wrote, why = file:write(data)
    file:close()
    -- OpenOS drops the last flush's error on close: a full disk shows only in the size.
    if not wrote or fs.size(temp) ~= #data then
        fs.remove(temp)
        return nil, "could not write " .. path .. ": " .. tostring(why or "the disk is full")
    end
    if fs.exists(path) then fs.remove(path) end
    return fs.rename(temp, path)
end

-- A locked vault (the client quit) is never written: a callback answering late would seal
-- nothing over it.
-- Sealing a big book can run the computer out of memory (a tablet with Gates open, at about 260
-- gates): that comes back as nil and "not enough memory", as any other failed save does.
local function sealTo(self, path, magic, data)
    local ok, done, why = pcall(function() return replace(path, seal(self, magic, data)) end)
    if not ok then return nil, tostring(done) end
    return done, why
end
function Vault:save()
    if not self.key or not self.state then return nil, "the vault is locked" end
    return sealTo(self, self.path, MAGIC, self.state)
end

-- Writes data (a table) to path, sealed under the vault's password.
function Vault:writeCopy(path, data)
    if not self.key then return nil, "the vault is locked" end
    return sealTo(self, path, COPY, data)
end
-- Reads a copy written by writeCopy. One sealed under an older password returns nil and
-- "older password" unless that password is given.
function Vault:readCopy(path, password)
    local data, reason = readAll(path)
    if not data then return nil, reason end
    local salt, iterations, sealed = split(COPY, data)
    if not salt then return nil, "not a GNS backup" end
    local key = self.key
    if salt ~= self.salt or iterations ~= self.iterations then
        if not password then return nil, "older password" end
        key = tostring(ecc.keyFromPassword(password, salt, iterations))
    end
    local ok, plain = pcall(ecc.decrypt, sealed, key)
    if not ok then return nil, "wrong password" end
    local copy = serialization.unserialize(tostring(plain))
    if type(copy) ~= "table" then return nil, "damaged backup" end
    return copy
end

function Vault:changePassword(password)
    local old = {self.key, self.salt, self.iterations}
    local key, salt = ecc.keyFromPassword(password, nil, vault.ITERATIONS)
    self.key, self.salt, self.iterations = tostring(key), salt, vault.ITERATIONS
    local ok, why = self:save()
    if not ok then self.key, self.salt, self.iterations = old[1], old[2], old[3] end
    return ok, why
end

function Vault:publicKey()
    return self.state.identity.public
end

function Vault:fingerprint()
    return vault.fingerprint(self.state.identity.public)
end

-- Drops the key and state from memory. The vault must be opened again to use it.
function Vault:lock()
    self.key, self.state = nil, nil
end

-- Creates a vault at path. state is the initial contents; an identity key pair is added if absent.
function vault.create(path, password, state)
    state = state or {}
    if not state.identity then
        local private, public = ecc.keypair()
        state.identity = {private = tostring(private), public = tostring(public)}
    end
    local key, salt = ecc.keyFromPassword(password, nil, vault.ITERATIONS)
    local self = setmetatable({path = path, salt = salt, iterations = vault.ITERATIONS,
        key = tostring(key), state = state}, Vault)
    local ok, reason = self:save()
    if not ok then return nil, reason end
    return self
end

-- Opens the vault at path. Returns the vault, or nil and "wrong password" / another reason.
function vault.open(path, password)
    if not fs.exists(path) and fs.exists(path .. ".new") then fs.rename(path .. ".new", path) end
    local data, reason = readAll(path)
    if not data then return nil, reason end
    local salt, iterations, sealed = split(MAGIC, data)
    if not salt then return nil, "not a GNS vault" end
    local key = tostring(ecc.keyFromPassword(password, salt, iterations))
    local ok, plain = pcall(ecc.decrypt, sealed, key)
    if not ok then return nil, "wrong password" end
    local state = serialization.unserialize(tostring(plain))
    if type(state) ~= "table" or type(state.identity) ~= "table" then return nil, "damaged vault" end
    return setmetatable({path = path, salt = salt, iterations = iterations, key = key, state = state}, Vault)
end

vault.replace = replace
return vault
