local os = require("os")

local multiplier = 0x5DEECE66D
local addend = 0xB
local mask = (1 << 48) - 1

local JavaRandom = {}
JavaRandom.__index = JavaRandom

function JavaRandom.new(seed)
    local self = setmetatable({}, JavaRandom)
    self:setSeed(seed or math.floor(os.time()))
    return self
end

function JavaRandom:setSeed(seed)
    self.seed = (seed ~ multiplier) & mask
end

function JavaRandom:next(bits)
    local oldseed, nextseed = self.seed
    nextseed = ((oldseed * multiplier + addend) & mask)
    self.seed = nextseed -- important to NOT use setSeed here
    return (nextseed >> (48 - bits)) & ((1 << bits) - 1)
end

-- Mimics Java's nextInt method, limiting the output to a specific bound
function JavaRandom:nextInt(bound)
    if not bound then
        return self:next(32)
    end
    local bits, val
    repeat
        bits = self:next(31)
        val = bits % bound
    until bits - val + (bound - 1) >= 0
    return val
end

local GlyphsMW = {[0] = "Sculptor","Scorpius","Centaurus","Monoceros","Point of Origin","Pegasus","Andromeda","Serpens Caput","Aries","Libra","Eridanus","Leo Minor","Hydra","Sagittarius","Sextans","Scutum","Pisces","Virgo","Bootes","Auriga","Corona Australis","Gemini","Leo","Cetus","Triangulum","Aquarius","Microscopium","Equuleus","Crater","Perseus","Cancer","Norma","Taurus","Canis Minor","Capricornus","Lynx","Orion","Piscis Austrinus"};
local GlyphsPG = {[0] = "Danami","Arami","Setas","Aldeni","Aaxel","Bydo","Avoniv","Ecrumig","Laylox","Ca Po","Alura","Lenchan","Acjesis","Dawnre","Subido","Zamilloz","Recktic","Robandus","Placeholder1","Zeo","Tahnan","Elenami","Hamlinto","Salma","Abrin","Poco Re","Hacemill","Olavii","Ramnon","Placeholder2","Gilltin","Sibbron","Amiwill","Illume","Sandovi","Baselai","Once El","Roehi"};
local GlyphsUN = {blacklist = {[37] = true, [17] = true}}
GlyphsMW.blacklist = {[4] = true}
GlyphsPG.blacklist = {[18] =true, [14] = true, [29]= true}

local function calculateSeed(dim, x, y, z)
	return (((y + z * 31) * 31 + x) * 31 + dim);
end

local function addressFromDimXYZ(dimension, x,y,z)
    local seed = calculateSeed(dimension, x,y,z)
	local length = 8;
    local Address = {}
    local random = JavaRandom.new(seed)
    for addressType = 1, 3 do
		local max = 38 + (addressType == 3 and -2 or 0);
		local symbols = (addressType == 1 and GlyphsMW) or (addressType == 2 and GlyphsPG) or GlyphsUN;
		local address = {};
		for i = 1, length do
			local glyphID = 0;
            local glyph
			repeat
				glyphID = random:nextInt(max) + (addressType == 3 and 1 or 0);
                glyph = addressType == 3 and "Glyph "..tostring(glyphID) or symbols[glyphID]
            until not (symbols.blacklist[glyphID] or address[glyph] )
            address[glyph] = true
            table.insert(address, glyph)
		end
        for i,v in pairs (address) do
            if type(i) == 'string' then address[i] = nil end
        end
        Address[(addressType == 1 and "MW") or (addressType == 2 and "PG") or "UN"] = address
	end
    return Address
end

return {
    addressFromDimXYZ = addressFromDimXYZ,
    calculateSeed = calculateSeed,
    Random = JavaRandom
}