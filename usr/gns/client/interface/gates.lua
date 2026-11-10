-- Gates screen: the address book. Add, remove and order gates; edit a gate's name, galaxy,
-- location, address (by glyph, or worked out from its location) and IDCs; mark it home; share
-- or dial it. With addresses and IDCs hidden (Settings; a gate's kiosk by default), the screen
-- shows neither and will not open them for editing or sharing.
--
-- Commands: new, add, idc, gen, loc, rename / rn, delete / del, swap, move / mv, edit, import.
local gns, clientEnv, _, frame, R = ...
local ui = clientEnv.ui
local C = ui.C
local unicode = require("unicode")
local fingerprint = clientEnv.vaultModule.fingerprint
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
clientEnv.GLYPHS = GLYPHS -- for the glyph touch view on Dial

local function changed()
    clientEnv.changed()
    require("loom").invalidate()
end
local function copy(list) local out = {} for i, v in ipairs(list or {}) do out[i] = v end return out end
-- A new row; with a network profile in use it belongs to that profile.
local function newRow(name, galaxy)
    local p = clientEnv.profile()
    return {Name = name, Type = galaxy or "MW", IDCs = {}, Address = {MW = {}, PG = {}, UN = {}}, Profiles = p and {[p.name] = true} or nil}
end
local function indexOf(r) for i, x in ipairs(database) do if x == r then return i end end end
local function shown() return clientEnv.settings.showCodes end
local HIDDEN = "Addresses and IDCs are hidden on this device (Settings)."
-- The home gate: one gate of the address book (home on Dial dials it with its IDC).
function clientEnv.setHome(r)
    for _, x in ipairs(database) do x.home = nil end
    if r then r.home = true end
    changed()
end

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
-- All three addresses worked out from the gate's location (JSG's own algorithm), or nil and why.
local function generated(r)
    local l = r.Location
    if not (l and l.dimension and l.x and l.y and l.z) then return nil, "needs the dimension and x y z" end
    return generator.addressFromDimXYZ(l.dimension, l.x, l.y, l.z)
end
local function generate(r)
    local address, err = generated(r)
    if not address then return nil, err end
    r.Address = address
    changed()
    local l = r.Location
    return ("Worked out %s's addresses from dim %s, %s %s %s."):format(r.Name, l.dimension, l.x, l.y, l.z)
end
-- A player's own IDC for a row (a device several players share sends the presser's own).
local function setPlayerIDC(r, player, code)
    if not player then return "Press a key on this device first, so OC names the player." end
    r.PlayerIDCs = r.PlayerIDCs or {}
    r.PlayerIDCs[player] = math.tointeger(tonumber(code))
    if next(r.PlayerIDCs) == nil then r.PlayerIDCs = nil end
    changed()
    local own = r.PlayerIDCs and r.PlayerIDCs[player]
    return own and ("%s sends IDC %d for %s."):format(r.Name, own, player) or ("%s sends its own IDCs for %s."):format(r.Name, player)
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
        if clientEnv.inProfile(r) and (want == "" or clientEnv.searchText(r):find(want, 1, true)) then list[#list + 1] = {r = r, i = i} end
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
    -- The list shows only the profile's rows: the cursor is r's place among them.
    for at, item in ipairs(items()) do
        if item.r == r then list:setCursor(at) return end
    end
end
clientEnv.selectGate = selectRow

local lw = wide and 46 or 24
ui.card(frame, 1, 1, lw, R.h - 2, function()
    local p = clientEnv.profile()
    return p and ("BOOK · " .. p.name) or "ADDRESS BOOK"
end, wide and function() return #database .. " gates" end or nil)
local find = ui.Field(frame, 2, 2, lw - 2, {placeholder = "⌕ search", changed = function(t) search = t list:setCursor(1) end})
clientEnv.gatesSearch = find
list = ui.List(frame, 1, 3, lw, R.h - 5, {items = items,
    empty = "No gates. NEW adds one; SCAN on Dial learns the gates in range.",
    cells = function(item, _, w)
        local r = item.r
        if wide then
            return {{1, ui.pad(tostring(item.i), 3), C.faint}, {5, ui.pad((r.home and "⌂ " or "") .. r.Name, 22)}, {28, tostring(r.Type or ""), C.dim},
                {32, r.key and "signed" or "", C.faint}, {w - 6, shown() and #(r.IDCs or {}) > 0 and "IDC" or "", C.amber}}
        end
        return {{1, ui.pad(tostring(item.i), 3), C.faint}, {4, ui.pad((r.home and "⌂ " or "") .. r.Name, w - 9)}, {w - 4, tostring(r.Type or ""), C.dim}}
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
    -- Swaps with the next row shown (another profile's rows stay where they are).
    local r, shown = current(), items()
    local at
    for n, item in ipairs(shown) do if item.r == r then at = n end end
    local other = at and shown[at + step]
    if not other then return end
    local i, j = shown[at].i, other.i
    database[i], database[j] = database[j], database[i]
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
-- after the chosen glyph of the address), the address on the right. start: addresses to begin
-- from instead of the saved ones (GENERATE's); nothing changes until SAVE.
local editLocation
local function editAddress(r, galaxy, start)
    if ui.modalOpen() then return end
    if not shown() then log(HIDDEN) return end
    local edited = start or {MW = copy(r.Address.MW), PG = copy(r.Address.PG), UN = copy(r.Address.UN)}
    local note = start and "Generated: SAVE keeps it" or nil
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
    ui.Paint(box, 35, 3, w - 36, 1, function(self)
        self:text(1, 1, ui.pad(note or "", w - 36), C.amber, C.card)
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
    ui.Button(box, bx, 14, 11, 1, "RESET", C.raised, C.text, function()
        edited[galaxy] = copy(r.Address[galaxy])
        note = "Saved address back"
    end)
    -- All three galaxies from the location, to look over before SAVE.
    ui.Button(box, bx, 16, 11, 1, "GENERATE", C.raised, C.text, function()
        local address, err = generated(r)
        if not address then note = "GENERATE " .. err .. ": LOCATION" return end
        edited.MW, edited.PG, edited.UN = address.MW, address.PG, address.UN
        local l = r.Location
        note = ("From dim %s, %s %s %s: SAVE keeps it"):format(l.dimension, l.x, l.y, l.z)
    end)
    -- The address last dialed by hand at the DHD of the gate in range, to look over before SAVE.
    ui.Button(box, bx, 18, 11, 1, "READ DHD", C.raised, C.text, function()
        local c = clientEnv.fromGate()
        local hand = c and c.status and c.status.handDialed
        local from, glyphs = next(type(hand) == "table" and type(hand.address) == "table" and hand.address or {})
        if not c then note = "No gate in range" return end
        if not GALAXY[from] or type(glyphs) ~= "table" then note = c.name .. " has no hand dial" return end
        edited[from] = {}
        for i, g in ipairs(glyphs) do edited[from][i] = tostring(g) end
        galaxy = from
        note = ("Hand dial at %s, %s: SAVE keeps it"):format(c.name, tostring(hand.time))
    end)
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

function editLocation(r, then_)
    ask(("Location of %s: dimension, x, y, z"):format(r.Name), {text = locationText(r), title = "LOCATION"}, function(text)
        local l = parseLocation(text)
        if not l then log("Type the dimension, or the dimension and x y z.") return end
        r.Location = l
        changed()
        if then_ then then_() end
    end)
end
-- GENERATE: the worked-out addresses open in the address dialog, saved only on SAVE; without a
-- location, it is asked for first. Where addresses are hidden, only an empty address is filled.
local function generateFor(r)
    local function open()
        local address, err = generated(r)
        if not address then log(r.Name .. ": " .. err) return end
        if shown() then editAddress(r, nil, address) return end
        for _, g in ipairs(GALAXIES) do
            if #((r.Address or {})[g] or {}) > 0 then log(HIDDEN) return end
        end
        log((generate(r)))
    end
    if generated(r) then open() else editLocation(r, open) end
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
    self:text(3, 2, ui.pad(r.Name, dw - 23), C.amber, C.card)
    self:text(3, 3, "Galaxy", C.faint, C.card)
    self:text(3, 4, ui.pad(clientEnv.place(r) or "Location unknown", dw - 16), C.dim, C.card)
    self:text(3, 6, "ADDRESS", C.faint, C.card)
    local a = (r.Address or {})[r.Type or "MW"] or {}
    if not shown() then
        self:text(3, 7, ui.pad(#a > 0 and "Hidden on this device." or "No address yet.", dw - 4), C.dim, C.card)
        self:text(3, ay + 2, "IDCs", C.faint, C.card)
        self:text(9, ay + 2, ui.pad(#(r.IDCs or {}) > 0 and "hidden" or "none", dw - 20), C.dim, C.card)
        if r.home then self:text(3, ay + 4, "Home gate", C.amber, C.card) end
        return
    end
    for i = 1, 8 do
        local glyph = a[i]
        self:block(3 + ((i - 1) % per) * pitch, 7 + ((i - 1) // per) * 2, pitch - 1, glyph or "·",
            glyph and (i <= 6 and C.raised or C.head) or C.page, glyph and (i <= 6 and C.text or C.dim) or C.faint)
    end
    self:text(3, ay, ui.pad(#a == 0 and "No address yet: EDIT ADDRESS, or GENERATE from the location."
        or (wide and "6 glyphs and the origin from this galaxy; all 8 from another galaxy" or "6 + origin here, 8 elsewhere"), dw - 4), C.faint, C.card)
    self:text(3, ay + 2, "IDCs", C.faint, C.card)
    local mine = clientEnv.player and (r.PlayerIDCs or {})[clientEnv.player]
    self:text(9, ay + 2, ui.pad((#(r.IDCs or {}) > 0 and table.concat(r.IDCs, ", ") or "none") .. (mine and (" · yours " .. mine) or ""), dw - 27), C.text, C.card)
    local signed = r.key and book[r.key] and ("Signed by its gate, " .. fingerprint(r.key)) or "Added by hand, not signed by its gate"
    self:text(3, ay + 3, ui.pad(signed, dw - 4), C.faint, C.card)
    if r.home then self:text(dw - 12, ay + 3, "Home gate", C.amber, C.card) end
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
ui.Button(frame, dx + dw - 19, 2, 8, 1, function() local r = current() return r and r.home and "⌂ HOME" or "HOME" end,
    function() local r = current() return r and r.home and C.amber or C.raised end,
    function() local r = current() return r and r.home and C.black or C.text end, function()
    local r = current()
    if not r then return end
    clientEnv.setHome(not r.home and r or nil)
    log(r.home and (r.Name .. " is the home gate.") or "No home gate.")
end)
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
ui.Button(frame, dx + dw - 15, ay + 2, 6, 1, "MINE", C.raised, C.text, function()
    local r = current()
    if r and not shown() then log(HIDDEN) return end
    if not r then return end
    if not clientEnv.player then log(setPlayerIDC(r, nil)) return end
    ask(("Your own IDC for %s, %s (empty: the gate's IDCs)"):format(r.Name, clientEnv.player),
        {text = tostring((r.PlayerIDCs or {})[clientEnv.player] or ""), title = "YOUR IDC"},
        function(text) if text then log(setPlayerIDC(r, clientEnv.player, text)) end end)
end)
ui.Button(frame, dx + dw - 8, ay + 2, 6, 1, "EDIT", C.raised, C.text, function()
    local r = current()
    if r and not shown() then log(HIDDEN) return end
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
    if r and not shown() then log(HIDDEN) return end
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
    if not shown() then return HIDDEN end
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
clientEnv.command({"idc"}, "idc <gate> <code>[,<code>...] | none: the IDCs sent when it is dialed (the first one); idc <gate> mine <code>|none, idc <gate> for <player> <code>|none: a player's own", function(args)
    if not args[2] then return "Usage: idc <gate> <codes> | none" end
    if not shown() then return HIDDEN end
    local word = args[2]:lower()
    if word == "mine" then return setPlayerIDC(entry(args[1]), clientEnv.player, args[3]) end
    if word == "for" and args[3] then return setPlayerIDC(entry(args[1]), args[3], args[4]) end
    return setIDCs(entry(args[1]), args[2] == "none" and "" or table.concat(args, ",", 2))
end)
-- AGS's address book (/ags/gateEntries.ff): Lua calling GateEntry{name, gateAddress = {MW, PG,
-- UN}, IDC, ...} and HistoryEntry{...}, read the way GDS read it. Gates already in the book (any
-- galaxy's address the same) are skipped.
local function sameAddress(a, b)
    for _, g in ipairs(GALAXIES) do
        local x, y = a[g] or {}, b[g] or {}
        if #x > 0 and #x == #y and table.concat(x, ",") == table.concat(y, ",") then return true end
    end
end
local function importAGS(path)
    local file, reason = io.open(path, "r")
    if not file then return "Cannot read " .. path .. ": " .. tostring(reason) end
    local text = file:read("*a")
    file:close()
    local added, skipped = {}, {}
    local env = {HistoryEntry = function() end}
    function env.GateEntry(e)
        if type(e) ~= "table" or type(e.gateAddress) ~= "table" then return end
        local name = tostring(e.name or ("AGS gate " .. (#added + #skipped + 1)))
        local address = {}
        for _, g in ipairs(GALAXIES) do
            address[g] = {}
            for i, glyph in ipairs(type(e.gateAddress[g]) == "table" and e.gateAddress[g] or {}) do address[g][i] = tostring(glyph) end
        end
        for _, r in ipairs(database) do
            if sameAddress(r.Address or {}, address) then skipped[#skipped + 1] = name .. " (as " .. r.Name .. ")" return end
        end
        local galaxy
        for _, g in ipairs(GALAXIES) do if not galaxy and #address[g] > 0 then galaxy = g end end
        if not galaxy then skipped[#skipped + 1] = name .. " (no address)" return end
        local r = newRow(name, galaxy)
        r.Address = address
        local idc = math.tointeger(tonumber(e.IDC))
        if idc then r.IDCs = {idc} end
        database[#database + 1] = r
        added[#added + 1] = name
    end
    local chunk, err = load(text, "=" .. path, "t", env)
    if not chunk then return "Not an AGS address book: " .. tostring(err) end
    local ok, failed = pcall(chunk)
    if #added > 0 then changed() end
    local report = ("Imported %d gates from AGS%s"):format(#added, #added > 0 and (": " .. table.concat(added, ", ")) or "")
    if #skipped > 0 then report = report .. ("; skipped %d: %s"):format(#skipped, table.concat(skipped, ", ")) end
    if not ok then report = report .. "; stopped: " .. tostring(failed) end
    return report .. "."
end
clientEnv.command({"import"}, "import ags [path]: add the gates of AGS's address book (/ags/gateEntries.ff) that are not in this one", function(args)
    if (args[1] or ""):lower() ~= "ags" then return "Usage: import ags [path]" end
    return importAGS(args[2] or "/ags/gateEntries.ff")
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
    -- As GENERATE: where addresses are hidden, only an empty address is filled.
    if not shown() then
        for _, g in ipairs(GALAXIES) do
            if #((r.Address or {})[g] or {}) > 0 then return HIDDEN end
        end
    end
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
    if not shown() then return HIDDEN end
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
