-- Gates screen: the address book. Add, remove and order gates; edit a gate's name, galaxy,
-- location, address (by glyph, or worked out from its location) and IDCs; share or dial it.
--
-- Commands: new, add, idc, gen, loc, rename / rn, delete / del, swap, move / mv, edit.
local gns, clientEnv, _, frame, R = ...
local ui = clientEnv.ui
local C = ui.C
local unicode = require("unicode")
local fingerprint = dofile(gns.path.gns .. "vault.lua").fingerprint
local generator = dofile(gns.path.gns .. "address.lua")

local database = clientEnv.database
local book = clientEnv.vault.state.book
local log = clientEnv.log
local wide = R.wide
local GALAXIES = {"MW", "PG", "UN"}
local GALAXY = {MW = "Milky Way", PG = "Pegasus", UN = "Universe"}
local GLYPHS = {
    MW = {"Andromeda", "Aquarius", "Aries", "Auriga", "Bootes", "Cancer", "Canis Minor", "Capricornus", "Centaurus", "Cetus",
        "Corona Australis", "Crater", "Equuleus", "Eridanus", "Gemini", "Hydra", "Leo", "Leo Minor", "Libra", "Lynx",
        "Microscopium", "Monoceros", "Norma", "Orion", "Pegasus", "Perseus", "Pisces", "Piscis Austrinus", "Sagittarius",
        "Scorpius", "Sculptor", "Scutum", "Serpens Caput", "Sextans", "Taurus", "Triangulum", "Virgo"},
    PG = {"Aaxel", "Abrin", "Acjesis", "Aldeni", "Alura", "Amiwill", "Arami", "Avoniv", "Baselai", "Bydo", "Ca Po", "Danami",
        "Dawnre", "Ecrumig", "Elenami", "Gilltin", "Hacemill", "Hamlinto", "Illume", "Laylox", "Lenchan", "Olavii", "Once El",
        "Poco Re", "Ramnon", "Recktic", "Robandus", "Roehi", "Salma", "Sandovi", "Setas", "Sibbron", "Tahnan", "Zamilloz", "Zeo"},
    UN = {},
}
for i = 1, 36 do if i ~= 17 then GLYPHS.UN[#GLYPHS.UN + 1] = "Glyph " .. i end end

local function changed()
    clientEnv.changed()
    require("loom").invalidate()
end
local function copy(list) local out = {} for i, v in ipairs(list or {}) do out[i] = v end return out end
local function newRow(name, galaxy)
    return {Name = name, Type = galaxy or "MW", IDCs = {}, Address = {MW = {}, PG = {}, UN = {}}}
end
local function indexOf(r) for i, x in ipairs(database) do if x == r then return i end end end

-- A glyph of a galaxy by name, any case, _ for spaces; the start of a name is enough when only
-- one glyph starts that way.
local function glyphNamed(galaxy, word)
    local want = word:gsub("_", " "):lower()
    local found
    for _, g in ipairs(GLYPHS[galaxy]) do
        if g:lower() == want then return g end
        if g:lower():sub(1, #want) == want then
            if found then found = false elseif found == nil then found = g end
        end
    end
    return found or nil
end
local function galaxyNamed(word)
    word = tostring(word or ""):upper()
    for _, g in ipairs(GALAXIES) do if word == g or GALAXY[g]:upper():gsub(" ", "") == word then return g end end
end
-- "dim, x, y, z" (commas or spaces) as a Location.
local function parseLocation(text)
    local n = {}
    for v in tostring(text):gmatch("-?%d+") do n[#n + 1] = math.tointeger(tonumber(v)) end
    if #n == 1 then return {dimension = n[1]} end
    if #n == 4 then return {dimension = n[1], x = n[2], y = n[3], z = n[4]} end
end
local function locationText(r)
    local l = r.Location or {}
    if l.dimension == nil then return "" end
    if l.x == nil then return tostring(l.dimension) end
    return ("%s, %s, %s, %s"):format(l.dimension, l.x, l.y, l.z)
end
-- Works out all three addresses from the gate's location (JSG's own algorithm).
local function generate(r)
    local l = r.Location
    if not (l and l.dimension and l.x and l.y and l.z) then return nil, "needs the dimension and x y z" end
    r.Address = generator.addressFromDimXYZ(l.dimension, l.x, l.y, l.z)
    changed()
    return ("Worked out %s's addresses from dim %s, %s %s %s."):format(r.Name, l.dimension, l.x, l.y, l.z)
end
local function setIDCs(r, text)
    local codes = {}
    for code in tostring(text or ""):gmatch("%d+") do codes[#codes + 1] = math.tointeger(tonumber(code)) end
    r.IDCs = codes
    changed()
    return #codes > 0 and (r.Name .. " IDCs: " .. table.concat(codes, ", ")) or (r.Name .. " has no IDCs now.")
end

---------------------------------------------------------------------------- the list
local search = ""
local function items()
    local list, want = {}, search:lower()
    for i, r in ipairs(database) do
        local hay = (tostring(r.Name) .. " " .. tostring(r.Type) .. " " .. (clientEnv.place(r) or "")):lower()
        if want == "" or hay:find(want, 1, true) then list[#list + 1] = {r = r, i = i} end
    end
    return list
end
local list
local function current()
    local item = list:cursorItem()
    return item and item.r
end
local function selectRow(r)
    search = ""
    if clientEnv.gatesSearch then clientEnv.gatesSearch:text("") end
    local i = indexOf(r)
    if i then list:setCursor(i) end
end
clientEnv.selectGate = selectRow

local lw = wide and 46 or 24
ui.card(frame, 1, 1, lw, R.h - 2, "ADDRESS BOOK", wide and function() return #database .. " gates" end or nil)
local find = ui.Field(frame, 2, 2, lw - 2, {placeholder = "⌕ search", changed = function(t) search = t list:setCursor(1) end})
clientEnv.gatesSearch = find
list = ui.List(frame, 1, 3, lw, R.h - 5, {items = items,
    empty = "No gates. NEW adds one; SCAN on Dial learns the gates in range.",
    cells = function(item, _, w)
        local r = item.r
        if wide then
            return {{1, ui.pad(tostring(item.i), 3), C.faint}, {5, ui.pad(r.Name, 22)}, {28, tostring(r.Type or ""), C.dim},
                {32, r.key and "signed" or "", C.faint}, {w - 6, #(r.IDCs or {}) > 0 and "IDC" or "", C.amber}}
        end
        return {{1, ui.pad(tostring(item.i), 3), C.faint}, {4, ui.pad(r.Name, w - 9)}, {w - 4, tostring(r.Type or ""), C.dim}}
    end})
local function ask(message, opts, fn) clientEnv.ask(message, opts, fn) end
local function newGate()
    ask("Name of the new gate", {text = "", title = "NEW GATE"}, function(name)
        if not name or not name:match("%S") then return end
        local at = (indexOf(current()) or #database) + 1
        local r = newRow(name)
        table.insert(database, at, r)
        changed()
        selectRow(r)
        log("Added " .. name .. " as gate " .. at .. ".")
    end)
end
local function deleteGate()
    local r = current()
    if not r then return end
    ask(("Delete %s from the address book?"):format(r.Name), {title = "DELETE"}, function()
        local i = indexOf(r)
        if i then table.remove(database, i) end
        changed()
        log("Deleted " .. r.Name .. ".")
    end)
end
local function shift(step)
    local r = current()
    local i = r and indexOf(r)
    if not i or not database[i + step] then return end
    database[i], database[i + step] = database[i + step], database[i]
    changed()
    selectRow(r)
end
local by = R.h
if wide then
    ui.Button(frame, 1, by, 14, 1, "+ NEW", C.green, C.black, newGate, {around = C.page})
    ui.Button(frame, 17, by, 14, 1, "DELETE", C.red, C.black, deleteGate, {around = C.page})
    ui.Button(frame, 33, by, 5, 1, "▲", C.raised, C.text, function() shift(-1) end, {around = C.page})
    ui.Button(frame, 40, by, 5, 1, "▼", C.raised, C.text, function() shift(1) end, {around = C.page})
else
    ui.Button(frame, 1, by, 5, 1, "+", C.green, C.black, newGate, {around = C.page})
    ui.Button(frame, 8, by, 5, 1, "DEL", C.red, C.black, deleteGate, {around = C.page})
    ui.Button(frame, 15, by, 3, 1, "▲", C.raised, C.text, function() shift(-1) end, {around = C.page})
    ui.Button(frame, 20, by, 3, 1, "▼", C.raised, C.text, function() shift(1) end, {around = C.page})
end

---------------------------------------------------------------------------- glyph editor
-- A dialog for one galaxy's address at a time: the galaxy's glyphs on the left (Enter adds one
-- after the chosen glyph of the address), the address on the right.
local function editAddress(r, galaxy)
    if ui.modalOpen() then return end
    local edited = {MW = copy(r.Address.MW), PG = copy(r.Address.PG), UN = copy(r.Address.UN)}
    galaxy = galaxy or r.Type or "MW"
    local w, h = 68, math.min(ui.H - 2, 22)
    local box, close = ui.modal(clientEnv.root, clientEnv.shell, w, h, "ADDRESS · " .. r.Name)
    local lh = h - 8
    local glyphs, address
    local chooserLeft = ui.chooser(box, 3, 3, 30, function() return GALAXY[galaxy] end, function()
        for i, g in ipairs(GALAXIES) do if g == galaxy then galaxy = GALAXIES[(i - 2) % 3 + 1] break end end
    end, function()
        for i, g in ipairs(GALAXIES) do if g == galaxy then galaxy = GALAXIES[i % 3 + 1] break end end
    end)
    ui.Paint(box, 2, 5, w - 2, 1, function(self)
        self:text(1, 1, "GLYPHS (Enter adds)", C.faint, C.card)
        self:text(27, 1, ("ADDRESS  %d of 8"):format(#edited[galaxy]), C.faint, C.card)
    end)
    glyphs = ui.List(box, 2, 6, 22, lh, {items = function() return GLYPHS[galaxy] end,
        cells = function(g) return {{1, g, C.text}} end,
        selected = function(g) for _, x in ipairs(edited[galaxy]) do if x == g then return true end end end,
        press = function(g)
            local a = edited[galaxy]
            for _, x in ipairs(a) do if x == g then return end end
            if #a >= 8 then log("An address has at most 8 glyphs.") return end
            local at = #a > 0 and math.min(address._cursor, #a) + 1 or 1
            table.insert(a, at, g)
            address:setCursor(at)
        end})
    address = ui.List(box, 28, 6, 24, lh, {items = function() return edited[galaxy] end,
        empty = "Empty: add glyphs from the left.",
        cells = function(g, i) return {{1, tostring(i), C.faint}, {4, g, C.amber}} end})
    local function move(step)
        local a, i = edited[galaxy], address._cursor
        if not a[i] or not a[i + step] then return end
        a[i], a[i + step] = a[i + step], a[i]
        address:setCursor(i + step)
    end
    local bx = 55
    ui.Button(box, bx, 6, 11, 1, "▲ UP", C.raised, C.text, function() move(-1) end)
    ui.Button(box, bx, 8, 11, 1, "▼ DOWN", C.raised, C.text, function() move(1) end)
    ui.Button(box, bx, 10, 11, 1, "REMOVE", C.raised, C.text, function()
        local a = edited[galaxy]
        if a[address._cursor] then table.remove(a, address._cursor) address:setCursor(address._cursor) end
    end)
    ui.Button(box, bx, 12, 11, 1, "CLEAR", C.red, C.black, function() edited[galaxy] = {} end)
    ui.Button(box, bx, 14, 11, 1, "RESET", C.raised, C.text, function() edited[galaxy] = copy(r.Address[galaxy]) end)
    local half = 14
    ui.Button(box, w // 2 - half - 1, h - 1, half, 1, "SAVE", C.green, C.black, function()
        r.Address = edited
        changed()
        close()
        log("Saved " .. r.Name .. "'s address.")
    end)
    ui.Button(box, w // 2 + 2, h - 1, half, 1, "CANCEL", C.raised, C.text, close)
    ui.focusSoon(chooserLeft)
end

local function editLocation(r, then_)
    ask(("Location of %s: dimension, x, y, z"):format(r.Name), {text = locationText(r), title = "LOCATION"}, function(text)
        local l = parseLocation(text)
        if not l then log("Type the dimension, or the dimension and x y z.") return end
        r.Location = l
        changed()
        if then_ then then_() end
    end)
end
local function generateFor(r)
    local message, err = generate(r)
    if message then log(message) return end
    editLocation(r, function()
        local m, e = generate(r)
        log(m or (r.Name .. ": " .. e))
    end)
end

---------------------------------------------------------------------------- the gate
local dx, dw = lw + 3, R.w - lw - 2
local per, pitch = 0, wide and 13 or 9
per = (dw - 3) // pitch
local addressRows = (8 - 1) // per + 1
local ay = 7 + addressRows * 2 -- the row after the address
ui.card(frame, dx, 1, dw, R.h, "GATE", function() local r = current() return r and ("[" .. tostring(r.Type) .. "]") end, function(self)
    local r = current()
    if not r then self:text(3, 3, "No gate chosen.", C.faint, C.card) return end
    self:text(3, 2, ui.pad(r.Name, dw - 14), C.amber, C.card)
    self:text(3, 3, "Galaxy", C.faint, C.card)
    self:text(3, 4, ui.pad(clientEnv.place(r) or "Location unknown", dw - 16), C.dim, C.card)
    self:text(3, 6, "ADDRESS", C.faint, C.card)
    local a = (r.Address or {})[r.Type or "MW"] or {}
    for i = 1, 8 do
        local glyph = a[i]
        self:block(3 + ((i - 1) % per) * pitch, 7 + ((i - 1) // per) * 2, pitch - 1, glyph or "·",
            glyph and (i <= 6 and C.raised or C.head) or C.page, glyph and (i <= 6 and C.text or C.dim) or C.faint)
    end
    self:text(3, ay, ui.pad(#a == 0 and "No address yet: EDIT ADDRESS, or GENERATE from the location."
        or (wide and "6 glyphs and the origin from this galaxy; all 8 from another galaxy" or "6 + origin here, 8 elsewhere"), dw - 4), C.faint, C.card)
    self:text(3, ay + 2, "IDCs", C.faint, C.card)
    self:text(9, ay + 2, ui.pad(#(r.IDCs or {}) > 0 and table.concat(r.IDCs, ", ") or "none", dw - 20), C.text, C.card)
    local signed = r.key and book[r.key] and ("Signed by its gate, " .. fingerprint(r.key)) or "Added by hand, not signed by its gate"
    self:text(3, ay + 3, ui.pad(signed, dw - 4), C.faint, C.card)
    if wide then
        local oy = ay + 5
        for _, g in ipairs(GALAXIES) do
            if g ~= r.Type then
                local other = (r.Address or {})[g] or {}
                self:text(3, oy, GALAXY[g], C.faint, C.card)
                self:text(14, oy, ui.pad(#other > 0 and table.concat(other, " · ") or "unknown", dw - 16), C.dim, C.card)
                oy = oy + 1
            end
        end
        self:text(1, ay + 8, ui.center(GALAXY[r.Type] or "", dw), C.faint, C.card)
    end
end)
local first = list
ui.Button(frame, dx + dw - 10, 2, 8, 1, "RENAME", C.raised, C.text, function()
    local r = current()
    if r then ask("New name for " .. r.Name, {text = r.Name, title = "RENAME"}, function(name)
        if name and name:match("%S") then r.Name = name changed() end
    end) end
end)
ui.chooser(frame, dx + 10, 3, 18, function() local r = current() return r and GALAXY[r.Type] or "" end, function()
    local r = current()
    if not r then return end
    for i, g in ipairs(GALAXIES) do if g == r.Type then r.Type = GALAXIES[(i - 2) % 3 + 1] break end end
    changed()
end, function()
    local r = current()
    if not r then return end
    for i, g in ipairs(GALAXIES) do if g == r.Type then r.Type = GALAXIES[i % 3 + 1] break end end
    changed()
end)
ui.Button(frame, dx + dw - 12, 4, 10, 1, "LOCATION", C.raised, C.text, function()
    local r = current()
    if r then editLocation(r) end
end)
ui.Button(frame, dx + dw - (wide and 30 or 22), 6, wide and 14 or 8, 1, wide and "EDIT ADDRESS" or "EDIT", C.amber, C.black, function()
    local r = current()
    if r then editAddress(r) end
end)
ui.Button(frame, dx + dw - (wide and 14 or 12), 6, wide and 12 or 10, 1, "GENERATE", C.raised, C.text, function()
    local r = current()
    if r then generateFor(r) end
end)
ui.Button(frame, dx + dw - 8, ay + 2, 6, 1, "EDIT", C.raised, C.text, function()
    local r = current()
    if r then ask(("IDCs for %s (numbers, separated by commas)"):format(r.Name), {text = table.concat(r.IDCs or {}, ", "), title = "IDCS"},
        function(text) log(setIDCs(r, text)) end) end
end)
if wide then
    local gw = ui.gateSize(12)
    ui.Gate(frame, dx + (dw - gw) // 2, ay + 9, 12, function()
        local r = current()
        return "idle", {}, r and r.Type or "MW"
    end, C.card)
end
local bw = (dw - 7) // 2
ui.Button(frame, dx + 2, R.h - 3, bw, 3, "SHARE", C.blue, C.black, function()
    local r = current()
    if r and clientEnv.openShare then clientEnv.openShare({r}) end
end)
ui.Button(frame, dx + 4 + bw, R.h - 3, dw - 6 - bw, 3, "DIAL", C.green, C.black, function()
    local r = current()
    if not r then return end
    clientEnv.dest = r
    clientEnv.show("dial")
end)

---------------------------------------------------------------------------- commands
local function entry(selector)
    local r, i = clientEnv.findEntry(selector)
    if not r then error("no gate " .. tostring(selector) .. " in the address book", 0) end
    return r, i
end
local function rest(args, from) return (table.concat(args, " ", from):gsub("_", " ")) end
clientEnv.command({"new"}, "new <name> [MW|PG|UN]: add a gate to the address book", function(args)
    if not args[1] then return "Usage: new <name> [MW|PG|UN]" end
    local galaxy = #args > 1 and galaxyNamed(args[#args])
    local name = rest(args, 1)
    if galaxy then name = table.concat(args, " ", 1, #args - 1):gsub("_", " ") end
    local r = newRow(name, galaxy)
    database[#database + 1] = r
    changed()
    return ("Added %s as gate %d."):format(name, #database)
end)
clientEnv.command({"add", "address"}, "add <gate> <MW|PG|UN> <glyph> ...: set an address (glyph names with _ for spaces, or their first letters); a new name adds the gate", function(args)
    local galaxy = galaxyNamed(args[2])
    if not args[1] or not galaxy then return "Usage: add <gate> <MW|PG|UN> <glyph> <glyph> ..." end
    local r = clientEnv.findEntry(args[1])
    local made = false
    if not r then
        r = newRow((args[1]:gsub("_", " ")), galaxy)
        database[#database + 1] = r
        made = true
    end
    local glyphs = {}
    local words = {}
    for i = 3, #args do for w in args[i]:gmatch("[^,]+") do words[#words + 1] = w end end
    for _, word in ipairs(words) do
        local g = glyphNamed(galaxy, word)
        if not g then return ("%s is not a %s glyph (or is not the start of just one)."):format(word, GALAXY[galaxy]) end
        for _, x in ipairs(glyphs) do if x == g then return g .. " is in the address twice." end end
        glyphs[#glyphs + 1] = g
    end
    if #glyphs > 8 then return "An address has at most 8 glyphs." end
    r.Address = r.Address or {MW = {}, PG = {}, UN = {}}
    r.Address[galaxy] = glyphs
    changed()
    return ("%s %s %s address: %s"):format(made and "Added" or "Set", r.Name, galaxy, table.concat(glyphs, ", "))
end)
clientEnv.command({"idc"}, "idc <gate> <code>[,<code>...] | none: the IDCs sent when it is dialed (the first one)", function(args)
    if not args[2] then return "Usage: idc <gate> <codes> | none" end
    return setIDCs(entry(args[1]), args[2] == "none" and "" or table.concat(args, ",", 2))
end)
clientEnv.command({"loc", "location"}, "loc <gate> <dim> [x y z]: where the gate is", function(args)
    local r = entry(args[1])
    local l = parseLocation(table.concat(args, " ", 2))
    if not l then return "Usage: loc <gate> <dim> [x y z]" end
    r.Location = l
    changed()
    return r.Name .. ": " .. clientEnv.place(r)
end)
clientEnv.command({"gen", "generate"}, "gen <gate> [dim x y z]: work out its addresses from its location", function(args)
    local r = entry(args[1])
    if #args > 1 then
        local l = parseLocation(table.concat(args, " ", 2))
        if not l or not l.x then return "Usage: gen <gate> [dim x y z]" end
        r.Location = l
    end
    local message, err = generate(r)
    return message or (r.Name .. " " .. err .. ": gen <gate> dim x y z")
end)
clientEnv.command({"rename", "rn"}, "rn <gate> <new name>: rename a gate", function(args)
    local r = entry(args[1])
    if not args[2] then return "Usage: rn <gate> <new name>" end
    local old = r.Name
    r.Name = rest(args, 2)
    changed()
    return old .. " is now " .. r.Name .. "."
end)
clientEnv.command({"delete", "del", "remove", "rmv"}, "del <gate>: remove a gate from the address book", function(args)
    local r, i = entry(args[1])
    table.remove(database, i)
    changed()
    return "Deleted " .. r.Name .. "."
end)
clientEnv.command({"swap"}, "swap <gate> <gate>: swap two gates' places in the address book", function(args)
    local a, i = entry(args[1])
    local b, j = entry(args[2])
    database[i], database[j] = b, a
    changed()
    return ("Swapped %s and %s."):format(a.Name, b.Name)
end)
clientEnv.command({"move", "mv"}, "mv <gate> <number>: move a gate to a place in the address book", function(args)
    local r, i = entry(args[1])
    local to = math.tointeger(tonumber(args[2]))
    if not to then return "Usage: mv <gate> <number>" end
    to = math.max(1, math.min(#database, to))
    table.remove(database, i)
    table.insert(database, to, r)
    changed()
    return ("Moved %s to %d."):format(r.Name, to)
end)
clientEnv.command({"edit"}, "edit <gate> [MW|PG|UN|idc|loc]: put the command that sets it in the command bar, to change", function(args)
    local r, i = entry(args[1])
    local what = (args[2] or r.Type or "MW"):lower()
    if what == "idc" then
        clientEnv.prefill(("idc %d %s"):format(i, #(r.IDCs or {}) > 0 and table.concat(r.IDCs, ",") or "none"))
    elseif what == "loc" then
        clientEnv.prefill(("loc %d %s"):format(i, locationText(r):gsub(",", "")))
    else
        local galaxy = galaxyNamed(what) or "MW"
        local words = {}
        for _, g in ipairs((r.Address or {})[galaxy] or {}) do words[#words + 1] = (g:gsub(" ", "_")) end
        clientEnv.prefill(("add %d %s %s"):format(i, galaxy, table.concat(words, " ")))
    end
end)

return {first = first}
