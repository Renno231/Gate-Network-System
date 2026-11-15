-- Dial's hand-dial feature, loaded when used (dial.lua's part): a gate's last address dialed by
-- hand on its DHD (status.handDialed), and saving it. Returns its functions.
local api = ...
local clientEnv = api.clientEnv
local log = api.log
local guard = api.guard
local database = api.database
local GALAXY = api.GALAXY
local settings = api.settings
local fresh = api.fresh
local loom = require("loom")

-- A gate's last address dialed by hand on its DHD (status.handDialed), and saving it.
local function inBook(hand)
    for galaxy, glyphs in pairs(hand.address) do
        if type(glyphs) == "table" then
            local names = {}
            for i, g in ipairs(glyphs) do names[i] = tostring(g) end
            for _, r in ipairs(database) do
                if clientEnv.sameSix(r, galaxy, names) then return r end
            end
        end
    end
end

local function notice(c, hand)
    if type(hand.address) ~= "table" or inBook(hand) then return end
    c.unsaved = hand.time -- Dial's one-tap line offers SAVE until it is saved
    log(("%s was dialed by hand at %s: save [name] keeps the address."):format(c.name, tostring(hand.time)))
end

local function saveHandDial(c, name)
    local hand = c.status and c.status.handDialed
    if type(hand) ~= "table" or type(hand.address) ~= "table" then return c.name .. " has not been dialed by hand." end
    local known = inBook(hand)
    if known then return ("%s's last hand dial is %s, already in the address book."):format(c.name, known.Name) end
    local galaxy, glyphs = next(hand.address)
    if not GALAXY[galaxy] or type(glyphs) ~= "table" then return c.name .. " sent a bad address." end
    local names = {}
    for i, glyph in ipairs(glyphs) do names[i] = tostring(glyph) end
    local p = clientEnv.profile()
    database[#database + 1] = clientEnv.setAddress({Name = name, Type = galaxy, IDCs = {}, Profiles = p and {[p.name] = true} or nil}, names, galaxy)
    c.unsaved = nil
    clientEnv.changed()
    loom.invalidate()
    if not settings.showCodes then return ("Saved %s as gate %d (addresses are hidden on this device)."):format(name, #database) end
    return ("Saved %s as gate %d: %s."):format(name, #database, table.concat(names, ", "))
end

return {notice = notice, save = function(args)
    local c = clientEnv.fromGate()
    if not c then return "No gate in range." end
    -- The gate's last hand dial as it is now: this device was not told of it.
    fresh(c, function()
        if args[1] then return log(saveHandDial(c, table.concat(args, " "))) end
        local hand = c.status and c.status.handDialed
        if type(hand) ~= "table" then return log(c.name .. " has not been dialed by hand.") end
        if inBook(hand) then return log(saveHandDial(c, "")) end
        clientEnv.ask("Name for the gate dialed by hand at " .. c.name, {text = c.name .. " dial " .. tostring(hand.time), title = "SAVE"}, guard(function(name)
            if name and name:match("%S") then log(saveHandDial(c, name)) end
        end))
    end)
    return ("Asking %s for its last hand dial..."):format(c.name)
    end}
