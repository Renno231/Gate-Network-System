-- GNS vault: the device's identity key and private data, encrypted under a password.
--
-- File layout: "GNSV1" | salt (16 bytes) | iterations (4 bytes, big-endian) | ecc.encrypt(state)
-- The key comes from PBKDF2 (ecc.keyFromPassword); a wrong password fails the MAC check.
local ecc = require("ecc")
local fs = require("filesystem")
local serialization = require("serialization")

local vault = {}
vault.ITERATIONS = 10000 -- about 0.5 s on a tier-3 computer
local MAGIC = "GNSV1"

-- "GNS-1a2b-3c4d-5e6f-7a8b": the first 8 bytes of SHA-256 of a public key.
function vault.fingerprint(publicKey)
    local hex = ecc.sha256.digest(tostring(publicKey)):toHex():sub(1, 16)
    return "GNS-" .. hex:sub(1, 4) .. "-" .. hex:sub(5, 8) .. "-" .. hex:sub(9, 12) .. "-" .. hex:sub(13, 16)
end

function vault.exists(path)
    return fs.exists(path)
end

local Vault = {}
Vault.__index = Vault

-- Writes the vault next to the old one, then replaces it, so a failed write keeps the old file.
function Vault:save()
    local data = MAGIC .. self.salt .. string.pack(">I4", self.iterations)
        .. tostring(ecc.encrypt(serialization.serialize(self.state), self.key))
    local temp = self.path .. ".new"
    local file, reason = io.open(temp, "wb")
    if not file then return nil, reason end
    file:write(data)
    file:close()
    if fs.exists(self.path) then fs.remove(self.path) end
    return fs.rename(temp, self.path)
end

function Vault:changePassword(password)
    local key, salt = ecc.keyFromPassword(password, nil, vault.ITERATIONS)
    self.key, self.salt, self.iterations = tostring(key), salt, vault.ITERATIONS
    return self:save()
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
    local file, reason = io.open(path, "rb")
    if not file then return nil, reason end
    local data = file:read("*a")
    file:close()
    if data:sub(1, #MAGIC) ~= MAGIC or #data < #MAGIC + 20 then return nil, "not a GNS vault" end
    local salt = data:sub(#MAGIC + 1, #MAGIC + 16)
    local iterations = string.unpack(">I4", data, #MAGIC + 17)
    local key = tostring(ecc.keyFromPassword(password, salt, iterations))
    local ok, plain = pcall(ecc.decrypt, data:sub(#MAGIC + 21), key)
    if not ok then return nil, "wrong password" end
    local state = serialization.unserialize(tostring(plain))
    if type(state) ~= "table" or type(state.identity) ~= "table" then return nil, "damaged vault" end
    return setmetatable({path = path, salt = salt, iterations = iterations, key = key, state = state}, Vault)
end

return vault
