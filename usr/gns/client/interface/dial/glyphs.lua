-- Dial's glyph touch view, loaded when used (dial.lua's part): the dialing gate's galaxy glyphs as
-- buttons, like a DHD: tapping one adds it to the address (a glyph once, at most eight), RESET starts
-- over as on AGS, DIAL dials the address and SAVE adds it to the address book.
local api = ...
local clientEnv = api.clientEnv
local ui = api.ui
local C = api.C
local log = api.log
local say = api.say
local galaxyOf = api.galaxyOf
local GLYPHS = api.GLYPHS
local GALAXY = api.GALAXY
local dialWhenFree = api.dialWhenFree
local database = api.database
-- The dialing gate's galaxy glyphs as buttons, like a DHD: tapping one adds it to the address
-- (a glyph once, at most eight), RESET starts over as on AGS, DIAL dials the address and SAVE
-- adds it to the address book. GLYPHS on Dial, or the glyphs command.
local function show()
    if ui.modalOpen() then return end
    local c = clientEnv.fromGate()
    local galaxy = galaxyOf(c)
    local glyphs = GLYPHS[galaxy] or {}
    local typed = {}
    local cell = galaxy == "UN" and 10 or 18
    local w = math.min(ui.W - 4, 2 + ((ui.W - 8) // cell) * cell + 2)
    local columns = (w - 4) // cell
    local rows = (#glyphs + columns - 1) // columns
    local pitch = rows * 2 + 8 <= ui.H - 2 and 2 or 1 -- a blank line between rows where they fit
    local h = math.min(ui.H - 2, rows * pitch + 8)
    local box, close = ui.modal(clientEnv.root, clientEnv.shell, w, h, ("GLYPHS · %s · %s"):format(c and c.name or "no gate", GALAXY[galaxy]))
    local function has(g) for _, t in ipairs(typed) do if t == g then return true end end end
    for i, g in ipairs(glyphs) do
        local x, y = 3 + ((i - 1) % columns) * cell, 3 + ((i - 1) // columns) * pitch
        ui.Button(box, x, y, cell - 1, 1, g, function() return has(g) and C.amber or C.raised end,
            function() return has(g) and C.black or C.text end, function()
                if has(g) or #typed >= 8 then return end
                typed[#typed + 1] = g
            end)
    end
    ui.Paint(box, 3, h - 4, w - 4, 2, function(self)
        self:text(1, 1, ui.pad(#typed == 0 and "Tap the glyphs of the address, as on a DHD." or table.concat(typed, " · "), w - 4), C.amber, C.card)
        self:text(1, 2, ui.pad(("%d of 6 to 8 glyphs; the point of origin is added when it dials"):format(#typed), w - 4), C.faint, C.card)
    end)
    local function typedRow(name)
        return clientEnv.setAddress({Name = name, Type = galaxy, IDCs = {}}, typed, galaxy)
    end
    local bw = (w - 12) // 4
    ui.Button(box, 3, h - 1, bw, 1, "RESET", C.raised, C.text, function() typed = {} end)
    ui.Button(box, 5 + bw, h - 1, bw, 1, "DIAL", C.green, C.black, function()
        if #typed < 6 then log("An address has 6 to 8 glyphs.") return end
        close()
        local r = typedRow(table.concat(typed, " "))
        r.typed = true
        say(dialWhenFree(c, r))
    end)
    ui.Button(box, 7 + 2 * bw, h - 1, bw, 1, "SAVE", C.amber, C.black, function()
        if #typed < 6 then log("An address has 6 to 8 glyphs.") return end
        local r = typedRow("")
        close()
        clientEnv.ask("Name of the gate at this address", {text = "", title = "SAVE"}, function(name)
            if not name or not name:match("%S") then return end
            r.Name = name
            local p = clientEnv.profile()
            if p then r.Profiles = {[p.name] = true} end
            database[#database + 1] = r
            clientEnv.changed()
            log(("Added %s as gate %d: %s."):format(name, #database, (r[galaxy]:gsub(",", ", "))))
        end)
    end)
    ui.Button(box, 9 + 3 * bw, h - 1, bw, 1, "CLOSE", C.raised, C.text, close)
end

return {show = show}
