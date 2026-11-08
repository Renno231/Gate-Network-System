-- The GNS client's look and controls, on loom: the tier-3 palette, cards, buttons, lists, text
-- fields, the drawn stargate, modal dialogs and keyboard focus.
--
-- Keyboard navigation is loom's (arrows, Tab, Enter/Space): GNS widgets show the focus as white
-- brackets beside them, and lists move their cursor before letting the focus out.
local loom = require("loom")
local gpu = require("loom.gpu")
local input = require("loom.input")
local class = require("loom.class")
local Widget = require("loom.widget.Widget")
local TextInput = require("loom.widget.TextInput")
local Frame = require("loom.widget.Frame")
local component = require("component")
local computer = require("computer")
local event = require("event")
local unicode = require("unicode")
local ulen, usub = unicode.len, unicode.sub

local ui = {}

-- Exact tier-3 palette colours (its grey ramp and colour cube), so nothing lands on a near miss.
local C = {
    page = 0x0F0F0F, side = 0x1E1E1E, card = 0x1E1E1E, head = 0x2D2D2D, raised = 0x3C3C3C, hover = 0x4B4B4B,
    text = 0xF0F0F0, dim = 0x969696, faint = 0x696969, ring = 0xFFFFFF,
    amber = 0xFFB600, green = 0x33DB40, red = 0xFF4940, blue = 0x0092FF, sky = 0x33B6FF, black = 0x000000,
}
ui.C = C

---------------------------------------------------------------------------- layout
-- compact: 80x25, for tablets and small screens. wide: 160x50, for a computer with a tier-3 GPU
-- and screen. "auto" picks wide when the hardware allows it and the device is not a tablet.
function ui.setLayout(choice)
    local g = component.gpu
    local maxW, maxH = g.maxResolution()
    local wide
    if choice == "wide" then wide = maxW >= 160 and maxH >= 50
    elseif choice == "compact" then wide = false
    else wide = not component.isAvailable("tablet") and maxW >= 160 and maxH >= 50 end
    ui.wide = wide
    ui.W, ui.H = wide and 160 or math.min(80, maxW), wide and 50 or math.min(25, maxH)
    g.setResolution(ui.W, ui.H)
    return wide
end

---------------------------------------------------------------------------- text helpers
function ui.pad(s, w)
    s = tostring(s)
    local n = ulen(s)
    if w <= 0 then return "" end
    return n >= w and usub(s, 1, w) or s .. (" "):rep(w - n)
end
function ui.center(s, w)
    s = usub(tostring(s), 1, math.max(0, w))
    local n = ulen(s)
    local l = (w - n) // 2
    return (" "):rep(l) .. s .. (" "):rep(w - n - l)
end
-- Lines of at most w characters, broken at spaces.
function ui.wrap(s, w)
    local lines = {}
    for paragraph in (tostring(s) .. "\n"):gmatch("(.-)\n") do
        local line = ""
        for word in paragraph:gmatch("%S+") do
            while ulen(word) > w do
                if line ~= "" then lines[#lines + 1] = line line = "" end
                lines[#lines + 1] = usub(word, 1, w)
                word = usub(word, w + 1)
            end
            if line == "" then line = word
            elseif ulen(line) + 1 + ulen(word) <= w then line = line .. " " .. word
            else lines[#lines + 1] = line line = word end
        end
        lines[#lines + 1] = line
    end
    return lines
end
local function value(v, ...) if type(v) == "function" then return v(...) end return v end
ui.value = value

-- Big text: a 3x5 pixel font in half blocks, three rows tall. M, N and W are five pixels wide.
local FONT = {A = "010101111101101", B = "110101110101110", C = "011100100100011", D = "110101101101110",
    E = "111100110100111", F = "111100110100100", G = "011100101101011", H = "101101111101101", I = "111010010010111",
    J = "001001001101010", K = "101101110101101", L = "100100100100111", M = "1000111011101011000110001", N = "1000111001101011001110001",
    O = "010101101101010", P = "110101110100100", Q = "010101101110011", R = "110101110101101", S = "011100010001110",
    T = "111010010010010", U = "101101101101111", V = "101101101101010", W = "1000110001101011101110001", X = "101101010101101",
    Y = "101101010010010", Z = "111001010100111", ["0"] = "111101101101111", ["1"] = "010110010010111",
    ["2"] = "110001010100111", ["3"] = "110001010001110", ["4"] = "101101111001001", ["5"] = "111100110001110",
    ["6"] = "011100111101111", ["7"] = "111001010010010", ["8"] = "111101111101111", ["9"] = "111101111001110",
    [" "] = "0000000000"}
local bigCache = {}
local function bigRows(s)
    if bigCache[s] then return bigCache[s] end
    local rows, width = {{}, {}, {}}, -1
    for i = 1, #s do width = width + #(FONT[s:sub(i, i)] or FONT[" "]) // 5 + 1 end
    for i = 1, #s do
        local g = FONT[s:sub(i, i)] or FONT[" "]
        local gw = #g // 5
        local function on(px, col) return col <= gw and px <= 5 and g:sub((px - 1) * gw + col, (px - 1) * gw + col) == "1" end
        for col = 1, gw + 1 do
            for r = 1, 3 do
                local top, bottom = on(2 * r - 1, col), on(2 * r, col)
                rows[r][#rows[r] + 1] = top and (bottom and "█" or "▀") or (bottom and "▄" or " ")
            end
        end
    end
    local out = {table.concat(rows[1]), table.concat(rows[2]), table.concat(rows[3]), width = width}
    bigCache[s] = out
    return out
end

---------------------------------------------------------------------------- Paint
-- A widget drawn by a function each frame: paint(self), using the helpers below in coordinates
-- counted from 1 inside the widget. It does not take touches, so controls added after it on top
-- get them.
local Paint = class(Widget)
function Paint:new(parent, x, y, w, h, paint)
    local o = self.parent(parent, x, y)
    setmetatable(o, self)
    o:size(w, h)
    o._paint = paint
    return o
end
function Paint:draw()
    if not self:visible() then return end
    if self._paint then self._paint(self) end
    return true
end
function Paint:checkCollision() return false end
function Paint:fill(x, y, w, h, bg)
    if w <= 0 or h <= 0 then return end
    gpu.setBackground(bg)
    self:_gpufill(self:absX() + x - 1, self:absY() + y - 1, w, h, " ")
end
function Paint:text(x, y, s, fg, bg)
    if bg then gpu.setBackground(bg) end
    gpu.setForeground(fg or C.text)
    self:_gpuset(self:absX() + x - 1, self:absY() + y - 1, tostring(s))
end
-- [label]: roles and states. Returns the column after it.
function Paint:tag(x, y, label, fg, bg)
    self:text(x, y, "[" .. label .. "]", fg, bg)
    return x + ulen(label) + 3
end
function Paint:bar(x, y, w, fraction, fg, bg)
    local n = math.max(0, math.min(w, math.floor(w * fraction + 0.5)))
    self:text(x, y, ("█"):rep(n), fg, bg)
    self:text(x + n, y, ("░"):rep(w - n), C.hover, bg)
end
function Paint:block(x, y, w, label, bg, fg) self:text(x, y, ui.center(label, w), fg, bg) end
-- Big text centred on column cx.
function Paint:big(cx, y, s, fg, bg)
    local rows = bigRows(s)
    for r = 1, 3 do self:text(cx - rows.width // 2, y + r - 1, rows[r], fg, bg) end
end
ui.Paint = Paint

-- A card: a header strip with an amber edge, a title and a note on the right, then the body.
-- title and note may be functions; body(self) paints the inside.
function ui.card(parent, x, y, w, h, title, note, body)
    return Paint(parent, x, y, w, h, function(self)
        self:fill(1, 1, w, 1, C.head)
        self:text(1, 1, "▌", C.amber, C.head)
        local t, n = tostring(value(title) or ""), value(note)
        self:text(3, 1, t, C.dim, C.head)
        if n and ulen(t) + ulen(n) + 5 <= w then self:text(w - ulen(n), 1, n, C.faint, C.head) end
        self:fill(1, 2, w, h - 1, C.card)
        if body then body(self) end
    end)
end

---------------------------------------------------------------------------- focus
-- loom moves the keyboard focus (arrows, Tab, Enter/Space as a touch: loom's docs/Keyboard.md).
-- GNS widgets show it as white brackets beside them; while a dialog is open only its widgets
-- take focus.
local scope -- the open dialog's frame, or nil
local function inScope(w)
    if not scope then return true end
    local p = w
    while p do
        if p == scope then return true end
        p = p:getParent()
    end
    return false
end
-- [ ] beside a one-row area; corner brackets beside a taller one. bg: the colour behind it.
local function brackets(x, y, w, h, bg)
    local oldBG, oldFG = gpu.getBackground(), gpu.getForeground()
    gpu.setForeground(C.ring)
    gpu.setBackground(bg)
    local left, right = x - 1, x + w
    for r = y, y + h - 1 do
        local l, rr = "[", "]"
        if h > 1 then
            l = r == y and "┌" or (r == y + h - 1 and "└" or "│")
            rr = r == y and "┐" or (r == y + h - 1 and "┘" or "│")
        end
        if left >= 1 then gpu.set(left, r, l) end
        if right <= ui.W then gpu.set(right, r, rr) end
    end
    gpu.setBackground(oldBG)
    gpu.setForeground(oldFG)
end
-- Widget:focusable for GNS widgets: also false behind an open dialog.
local function focusable(self, v)
    if v ~= nil then self._focusable = v end
    local on = self._focusable
    if on == nil then on = true end
    return on and inScope(self)
end
local function drawFocus(self) brackets(self:absX(), self:absY(), self:width(), self:height(), value(self._around) or C.card) end
local function report(err) if ui.onError then ui.onError(err) end end

---------------------------------------------------------------------------- Button
-- label, bg and fg may be functions (read each frame). press(self) runs on Enter, Space or touch.
-- opts.around: the colour behind the button, for its focus brackets.
local Button = class(Widget)
function Button:new(parent, x, y, w, h, label, bg, fg, press, opts)
    local o = self.parent(parent, x, y)
    setmetatable(o, self)
    o:size(w, h)
    o._label, o._bg, o._fg, o._press = label, bg, fg or C.black, press
    o._around = opts and opts.around
    return o
end
function Button:draw()
    if not self:visible() then return end
    local x, y, w, h = self:absX(), self:absY(), self:width(), self:height()
    gpu.setBackground(value(self._bg, self))
    self:_gpufill(x, y, w, h, " ")
    gpu.setForeground(value(self._fg, self))
    self:_gpuset(x, y + (h - 1) // 2, ui.center(value(self._label, self), w))
    return true
end
function Button:press()
    if not self._press then return end
    local ok, err = pcall(self._press, self)
    if not ok then report(err) end
end
function Button:defaultCallback(_, eventName, _, _, _, button)
    if eventName ~= "touch" or button ~= 0 then return end
    self:press()
    return true
end
Button.focusable, Button._drawFocus = focusable, drawFocus
ui.Button = Button

-- A switch: ON in green or OFF in grey. get() reads it, set(value) changes it.
function ui.toggle(parent, x, y, get, set, opts)
    return Button(parent, x, y, 7, 1, function() return get() and "ON" or "OFF" end,
        function() return get() and C.green or C.raised end,
        function() return get() and C.black or C.dim end,
        function() set(not get()) end, opts)
end

-- ◀ value ▶: two arrow buttons around a value (a function). Returns the arrows.
function ui.chooser(parent, x, y, w, text, left, right, opts)
    Paint(parent, x + 3, y, w - 6, 1, function(self)
        self:text(1, 1, ui.center(value(text), w - 6), C.amber, value(opts and opts.around) or C.card)
    end)
    return Button(parent, x, y, 3, 1, "◀", C.raised, C.text, left, opts),
        Button(parent, x + w - 3, y, 3, 1, "▶", C.raised, C.text, right, opts)
end

---------------------------------------------------------------------------- Field
-- A one-line text field: focusing it starts typing; Escape or Up/Down leave it. opts:
-- placeholder, submit(text), changed(text), clear (empty it after Enter), mask, around, text.
local Field = class(TextInput)
function Field:new(parent, x, y, w, opts)
    opts = opts or {}
    local o = TextInput.new(self, parent, x, y, opts.text or "")
    o:size(w, 1)
    o:backgroundColor(C.raised)
    o:foregroundColor(C.text)
    if opts.placeholder then o:placeholder(opts.placeholder, C.dim) end
    o:clearOnEnter(opts.clear == true)
    if opts.mask then o:mask(opts.mask) end
    o._around = opts.around
    if opts.submit then o:on("submit", function(_, text) local ok, err = pcall(opts.submit, text) if not ok then report(err) end end) end
    if opts.changed then o:on("valueChanged", function(_, _, text) opts.changed(text) end) end
    return o
end
Field.focusable, Field._drawFocus = focusable, drawFocus
ui.Field = Field

---------------------------------------------------------------------------- List
-- Rows of an items table (or a function returning one). opts:
--   cells(item, i, width) -> {{column, text, colour}, ...}
--   selected(item, i) -> true for rows shown amber; press(item, i) on Enter/Space or touch
--   pitch: rows per item (default 1); empty: text shown when there are no items
--   scrollOnly: Up/Down scroll the text instead of moving a cursor (for reading)
-- Up/Down move the cursor; past the first or last row they move focus out of the list.
local List = class(Widget)
function List:new(parent, x, y, w, h, opts)
    local o = self.parent(parent, x, y)
    setmetatable(o, self)
    o:size(w, h)
    o._opts, o._cursor, o._scroll = opts, 1, 0
    o._around = opts.around
    return o
end
function List:items() return value(self._opts.items) or {} end
function List:rows() return math.max(1, self:height() // (self._opts.pitch or 1)) end
-- Keep the cursor inside the list and on screen.
function List:_clamp()
    local n, rows = #self:items(), self:rows()
    if self._opts.scrollOnly then
        self._scroll = math.max(0, math.min(self._scroll, n - rows))
        return
    end
    self._cursor = math.max(1, math.min(self._cursor, n))
    if self._cursor <= self._scroll then self._scroll = self._cursor - 1 end
    if self._cursor > self._scroll + rows then self._scroll = self._cursor - rows end
    self._scroll = math.max(0, math.min(self._scroll, math.max(0, n - rows)))
end
function List:cursorItem() local items = self:items() return items[self._cursor], self._cursor end
function List:setCursor(i) self._cursor = i self:_clamp() end
function List:draw()
    if not self:visible() then return end
    self:_clamp()
    local opts, items = self._opts, self:items()
    local x, y, w, h = self:absX(), self:absY(), self:width(), self:height()
    local pitch = opts.pitch or 1
    local focused = self:focused() and not opts.scrollOnly
    gpu.setBackground(C.card)
    self:_gpufill(x, y, w, h, " ")
    if #items == 0 and opts.empty then
        gpu.setForeground(C.faint)
        for i, line in ipairs(ui.wrap(value(opts.empty), w - 4)) do
            if i > h then break end
            self:_gpuset(x + 2, y + i - 1, line)
        end
    end
    for r = 1, self:rows() do
        local i = self._scroll + r
        local item = items[i]
        if not item then break end
        local ry = y + (r - 1) * pitch + (pitch - 1) // 2
        local selected = opts.selected and opts.selected(item, i)
        local bg = selected and C.amber or ((focused and i == self._cursor) and C.hover or C.card)
        gpu.setBackground(bg)
        self:_gpufill(x, ry, w, 1, " ")
        for _, cell in ipairs(opts.cells(item, i, w)) do
            gpu.setForeground(selected and C.black or (cell[3] or C.text))
            self:_gpuset(x + cell[1], ry, usub(tostring(cell[2]), 1, math.max(0, w - cell[1])))
        end
    end
    -- More above or below: a faint arrow on the right edge.
    gpu.setForeground(C.faint)
    gpu.setBackground(C.card)
    if self._scroll > 0 then self:_gpuset(x + w - 1, y, "▲") end
    if self._scroll + self:rows() < #items then self:_gpuset(x + w - 1, y + h - 1, "▼") end
    return true
end
-- Brackets around the cursor row (around the whole list when it only scrolls).
function List:_drawFocus()
    local x, y, w, h = self:absX(), self:absY(), self:width(), self:height()
    if not self._opts.scrollOnly and #self:items() > 0 then
        local pitch = self._opts.pitch or 1
        y, h = y + (self._cursor - self._scroll - 1) * pitch + (pitch - 1) // 2, 1
    end
    brackets(x, y, w, h, value(self._around) or C.card)
end
function List:_key(char, code)
    local n = #self:items()
    if self._opts.scrollOnly then
        local before = self._scroll
        if code == 200 then self._scroll = self._scroll - 1 elseif code == 208 then self._scroll = self._scroll + 1 else return false end
        self:_clamp()
        return self._scroll ~= before
    end
    if code == 200 and self._cursor > 1 then self._cursor = self._cursor - 1 return true end
    if code == 208 and self._cursor < n then self._cursor = self._cursor + 1 return true end
    if code == 28 or code == 156 or code == 57 then self:press() return true end
    return false
end
function List:press()
    local item, i = self:cursorItem()
    if item and self._opts.press then
        local ok, err = pcall(self._opts.press, item, i)
        if not ok then report(err) end
    end
end
function List:defaultCallback(_, eventName, _, x, y, button)
    if eventName == "touch" and button == 0 then
        if self._opts.scrollOnly then return true end
        local pitch = self._opts.pitch or 1
        local i = self._scroll + (y - self:absY()) // pitch + 1
        if self:items()[i] then
            self._cursor = i
            self:press()
        end
        return true
    elseif eventName == "scroll" then
        self._scroll = self._scroll - button
        if not self._opts.scrollOnly then
            local rows = self:rows()
            self._scroll = math.max(0, math.min(self._scroll, math.max(0, #self:items() - rows)))
            self._cursor = math.max(self._scroll + 1, math.min(self._cursor, self._scroll + rows))
        end
        self:_clamp()
        return true
    end
end
List.focusable = focusable
ui.List = List

---------------------------------------------------------------------------- the stargate
-- Pixels are half-block cells, two per character, so the rings are round. The geometry is
-- worked out once per size; a picture is worked out once per state and replayed after.
local GLYPH_BITS = {}
do
    local seed = 20231
    for s = 1, 39 do
        seed = (seed * 1103515245 + 12345) % 0x80000000
        GLYPH_BITS[s] = ((seed >> 9) & (seed >> 17) & 0x1FF) | 0x10
    end
end
local geometries = {}
local function geometry(Rh)
    if geometries[Rh] then return geometries[Rh] end
    local k = Rh / 22
    local R = math.ceil(Rh + 12 * k)
    local w = 2 * R + 3
    local h = w + (w % 2)
    local cx, cy, TWO_PI = (w + 1) / 2, (h + 1) / 2, 2 * math.pi
    local G = {Rh = Rh, k = k, w = w, h = h, kind = {}, val = {}, hd = {}, ha = {}}
    for y = 1, h do
        for x = 1, w do
            local i = (y - 1) * w + x
            local dx, dy = x - cx, y - cy
            local d = math.sqrt(dx * dx + dy * dy)
            local a = math.atan(dy, dx)
            local kind, v = 0, false
            if d <= Rh then
                kind, G.hd[i], G.ha[i] = 1, d, a
            elseif d <= Rh + 1.5 * k then
                v = 0x3C3C3C
            elseif d <= Rh + 6 * k then
                v = 0x4B4B4B -- the glyph track: 39 symbols
                local r = (d - (Rh + 2 * k)) / (3.5 * k)
                local sector = (((a + math.pi / 2) % TWO_PI) / TWO_PI * 39 + 0.5) % 39
                local s = math.floor(sector)
                local u = (sector - s - 0.2) / 0.6
                if r >= 0 and r < 1 and u >= 0 and u < 1 then
                    local bit = math.floor(r * 3) * 3 + math.floor(u * 3)
                    if (GLYPH_BITS[s + 1] >> bit) & 1 == 1 then kind, v = 2, s end
                end
            elseif d <= Rh + 10 * k then
                v = d <= Rh + 6.8 * k and 0x3C3C3C or (d > Rh + 9 * k and 0x696969 or 0x5A5A5A)
            end
            -- Chevrons: a wedge housing across the outer ring holding a V-shaped light.
            local u = d - (Rh + 4 * k)
            if u >= 0 and u <= 8 * k then
                for p = 1, 9 do
                    local da = (a - math.rad(-90 + (p - 1) * 40) + math.pi) % TWO_PI - math.pi
                    local t = math.abs(da * d)
                    if t <= 1.2 * k + 0.45 * u then
                        local light = k < 0.5 or (u >= k and u <= 6.8 * k and math.abs(t - 0.35 * u) <= 1.0 * k)
                        kind, v = light and 4 or 3, p
                    end
                end
            end
            G.kind[i], G.val[i] = kind, v
        end
    end
    geometries[Rh] = G
    return G
end
ui.gateSize = function(Rh) local G = geometry(Rh) return G.w, G.h // 2 end

-- Each galaxy's gate in its own colours: ring shades (by the Milky Way shade they replace),
-- glyphs, chevron housing (unlit, lit) and chevron light (unlit, lit).
local THEMES = {
    MW = {ring = {}, glyph = 0x696969, housing = {0x787878, 0x969696}, light = {0x664900, 0xFFB600}},
    PG = {ring = {[0x3C3C3C] = 0x002440, [0x4B4B4B] = 0x334980, [0x5A5A5A] = 0x334980, [0x696969] = 0x336D80},
        glyph = 0x6692BF, housing = {0x666D80, 0x6692BF}, light = {0x004980, 0x33B6FF}},
    UN = {ring = {[0x3C3C3C] = 0x5A5A5A, [0x4B4B4B] = 0x787878, [0x5A5A5A] = 0x878787, [0x696969] = 0x969696},
        glyph = 0xB4B4B4, housing = {0xA5A5A5, 0xC3C3C3}, light = {0x5A5A5A, 0xF0F0F0}},
}
-- Chevron positions clockwise from the top: glyph n of a dial lights SYMBOL[n]; the last glyph
-- (the point of origin) lights the top one.
local SYMBOL = {2, 3, 4, 7, 8, 9, 5, 6}
function ui.litChevrons(engaged, total)
    local lit = {}
    for n = 1, engaged do
        if n == total then lit[1] = true else lit[SYMBOL[n] or 1] = true end
    end
    return lit
end

local function paint(G, state, lit, theme, bg)
    theme = THEMES[theme] or THEMES.MW
    local ring = theme.ring
    local px, kind, val, hd, ha, Rh, k = {}, G.kind, G.val, G.hd, G.ha, G.Rh, G.k
    for i = 1, G.w * G.h do
        local kd, v = kind[i], val[i]
        if kd == 0 then
            px[i] = v and (ring[v] or v) or bg
        elseif kd == 1 then
            px[i] = bg -- the inside: the horizon and iris Shader draws over it
        elseif kd == 2 then
            px[i] = (state == "dial" and v == 0) and theme.light[2] or theme.glyph
        elseif kd == 3 then
            px[i] = theme.housing[lit[v] and 2 or 1]
        else
            px[i] = theme.light[lit[v] and 2 or 1]
        end
    end
    return px
end

-- Runs of equal cells as {fg, bg, column, row, length, ...}, grouped by colour.
local function runs(G, px)
    local list, w = {}, G.w
    for r = 1, G.h // 2 do
        local top, bottom = (2 * r - 2) * w, (2 * r - 1) * w
        local x = 1
        while x <= w do
            local t, b = px[top + x], px[bottom + x]
            local n = 1
            while x + n <= w and px[top + x + n] == t and px[bottom + x + n] == b do n = n + 1 end
            list[#list + 1] = {t, b, x, r, n}
            x = x + n
        end
    end
    table.sort(list, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1] < b[1] end)
    return list
end

-- The inside of the ring: a loom Shader over the still ring picture, drawing the event horizon
-- and the iris over it. The horizon looks like the show's, which filmed light through water:
-- bright blue, ripples running out from the middle, a moving net of caustic highlights. It
-- bursts out (the kawoosh) when the wormhole opens and shrinks away when it closes. The iris is
-- JSG's: metal blades (titanium, or darker trinium) that close in a spiral, or the shield, a
-- glowing forcefield. The Shader animates only while something moves.
local function mix(a, b, f)
    f = math.max(0, math.min(1, f))
    local function ch(s) local x, y = (a >> s) & 0xFF, (b >> s) & 0xFF return math.floor(x + (y - x) * f + 0.5) << s end
    return ch(16) | ch(8) | ch(0)
end
local KAWOOSH, CLOSING, IRIS_TIME, SHIELD_TIME = 0.8, 0.6, 1.5, 0.6
-- Blade shades: dark, light, seam.
-- Greys, because the palette holds those exactly; tinted metal would come out beige or lilac.
local BLADES = {IRIS_TITANIUM = {0x5A5A5A, 0xB4B4B4, 0x1E1E1E}, IRIS_CREATIVE = {0x5A5A5A, 0xB4B4B4, 0x1E1E1E},
    IRIS_TRINIUM = {0x2D2D2D, 0x787878, 0x0F0F0F}}
local sin, cos, abs, sqrt, atan, pi = math.sin, math.cos, math.abs, math.sqrt, math.atan, math.pi

-- The event horizon's colour at (x, y) from the middle, r = its distance, edge = the horizon's
-- reach now; s scales any gate size to the 22-pixel one the numbers are tuned for.
local function water(x, y, r, edge, now, s)
    x, y, r = x * s, y * s, r * s
    local wx = x + 1.6 * sin(y * 0.31 + now * 0.9)
    local wy = y + 1.6 * sin(x * 0.27 - now * 0.8)
    local caustic = 1 - abs(sin(wx * 0.45 + now * 0.6) + sin(wy * 0.45 - now * 0.5)) / 2
    caustic = caustic * caustic * caustic * caustic * caustic
    local ripple = sin(r * 0.55 - now * 2.2)
    local c = mix(0x1C5FD0, 0x5FB4FF, 0.5 + 0.3 * ripple)
    c = mix(c, 0xE8F8FF, caustic * 0.9)
    return mix(c, 0x0A2A6A, (r / (edge * s)) ^ 5)
end

local function inside(gate, parent, x, y, G)
    -- The smallest block of whole cells around the inside: columns c0.., cell rows r0.. of the gate.
    local cx, cy, Rh = (G.w + 1) / 2, (G.h + 1) / 2, G.Rh
    local c0 = math.max(1, math.floor(cx - Rh))
    local r0 = math.max(1, math.floor((cy - Rh + 1) / 2))
    local w = math.min(G.w, math.ceil(cx + Rh)) - c0 + 1
    local h = math.min(G.h // 2, math.ceil((cy + Rh) / 2)) - r0 + 1
    local px0, py0 = c0 - 1, 2 * r0 - 2 -- local pixel (1, 1) is gate pixel (c0, 2 r0 - 1)
    local s = 22 / Rh
    local shader = loom.widget.Shader(parent, x + c0 - 1, y + r0 - 1, w, h, function(px, py)
        local dx, dy = px0 + px - cx, py0 + py - cy
        local r = sqrt(dx * dx + dy * dy)
        if r > Rh then return nil end
        local now = computer.uptime()
        local phase, t, closed = gate:_at(now)
        local colour
        -- The horizon.
        if phase == "kawoosh" then
            local u = t / KAWOOSH
            if r <= Rh * math.min(1, u * 1.6) then
                colour = mix(0x5FB4FF, 0xFFFFFF, (1 - math.max(0, u - 0.4) / 0.6) * (1 - r / Rh * 0.5))
            end
        elseif phase then
            local edge = phase == "closing" and Rh * (1 - t / CLOSING) or Rh
            if r < edge then colour = water(dx, dy, r, edge, now, s) end
        end
        -- The iris over it.
        local kind = gate._irisType
        if closed > 0 and kind == "SHIELD" then
            local a = atan(dy, dx)
            local glow = 0.5 + 0.25 * sin(r * s * 0.7 - now * 3) + 0.25 * sin(a * 6 + now * 1.7 + r * s * 0.2)
            local field = mix(0x1E4BB4, 0xBFE8FF, glow * 0.6 + (r / Rh) ^ 6 * 0.6)
            return mix(colour or 0x0F0F0F, field, closed * 0.8)
        elseif closed > 0 and BLADES[kind] then
            -- A blade covers the point once the opening has shrunk inside it; the blades turn as
            -- they close, and the seams between them curve like a camera's.
            if r >= Rh * (1 - closed) then
                -- Each blade is lit along its leading edge and shades off behind it, with a
                -- one-pixel seam. A small gate has too few pixels for that: six blades, each one
                -- flat shade lit from the upper left.
                local metal, small = BLADES[kind], Rh < 12
                local n = small and 6 or 16
                local a = atan(dy, dx)
                local turns = (a + closed * 1.2 + (r / Rh) * 1.4) / (2 * pi) * n
                local b = turns % 1
                if b * 2 * pi * math.max(r, 1) / n < 0.9 then return metal[3] end
                if small then
                    local mid = (math.floor(turns) + 0.5) / n * 2 * pi - closed * 1.2 - 0.7
                    return mix(metal[1], metal[2], 0.5 + 0.5 * cos(mid + 2.4))
                end
                local light = 0.5 + 0.5 * cos(a + 2.4)
                return mix(metal[1], metal[2], 0.15 + 0.5 * (1 - b) + 0.35 * light * r / Rh)
            end
        end
        return colour
    end)
    shader:dither(false)
    shader:visible(false)
    shader.checkCollision = function() return false end
    return shader
end

-- look() -> state ("idle", "dial", "open" or "iris"), lit chevrons {[position] = true}, and the
-- galaxy ("MW", "PG" or "UN"). iris(), when given, -> the gate's iris state ("OPENED",
-- "CLOSING", "CLOSED", "OPENING") and type ("IRIS_TITANIUM", "IRIS_TRINIUM", "SHIELD", ...).
local Gate = class(Widget)
function Gate:new(parent, x, y, Rh, look, bg, iris)
    local G = geometry(Rh)
    local o = self.parent(parent, x, y)
    setmetatable(o, self)
    o:size(G.w, G.h // 2)
    o._G, o._look, o._bg, o._iris = G, look, bg or C.page, iris
    o._from, o._want, o._irisAt = 0, 0, 0
    o._inside = inside(o, parent, x, y, G)
    return o
end
-- What the inside shows at time now, worked out from when each change began so the Shader
-- moves smoothly between draws: the horizon's phase ("kawoosh", "open", "closing" or nil) and
-- the time since it began, and how far the iris is closed (0 open, 1 shut).
function Gate:_at(now)
    if self._frame ~= now then
        local phase, t = self._phase, now - (self._phaseAt or now)
        if phase == "kawoosh" and t >= KAWOOSH then phase, t = "open", t - KAWOOSH end
        if phase == "closing" and t >= CLOSING then phase = nil end
        local span = self._irisType == "SHIELD" and SHIELD_TIME or IRIS_TIME
        local f = math.min(1, (now - self._irisAt) / span)
        local closed = self._from + (self._want - self._from) * f
        self._frame, self._frameValue = now, {phase, t, closed}
    end
    local v = self._frameValue
    return v[1], v[2], v[3]
end
-- Follows the wormhole (kawoosh as it opens, closing as it shuts) and the iris (moving towards
-- open or closed at its own pace), then shows and animates the inside only as needed.
function Gate:_follow(state)
    local now = computer.uptime()
    local phase, _, closed = self:_at(now)
    local open = state == "open" or state == "iris"
    if self._open == nil then
        self._phase, self._phaseAt = open and "open" or nil, now
    elseif open and not self._open then
        self._phase, self._phaseAt = "kawoosh", now
    elseif not open and self._open then
        self._phase, self._phaseAt = "closing", now
    end
    self._open = open

    local irisState, irisType
    if self._iris then irisState, irisType = self._iris() end
    if not (BLADES[irisType] or irisType == "SHIELD") then irisType = nil end
    local want = (irisType and (irisState == "CLOSED" or irisState == "CLOSING")) and 1 or 0
    if irisType ~= self._irisType or not self._seen then
        -- No animation on first sight or when the iris changes kind.
        self._irisType, self._from, self._want, self._irisAt, self._seen = irisType, want, want, now, true
    elseif want ~= self._want then
        self._from, self._want, self._irisAt = closed, want, now
    end
    self._frame = nil
    phase, _, closed = self:_at(now)
    if self._phase == "kawoosh" and phase == "open" then self._phase, self._phaseAt = "open", self._phaseAt + KAWOOSH end
    if self._phase == "closing" and phase == nil then self._phase = nil end

    -- Moving: a horizon that shows, an iris on its way, or a shield (it always shimmers). A
    -- move that ends by itself (the kawoosh, the closing horizon, the iris) wakes the gate when
    -- it is over, so it can stop animating.
    local ends = {}
    if self._phase == "kawoosh" then ends[#ends + 1] = self._phaseAt + KAWOOSH end
    if self._phase == "closing" then ends[#ends + 1] = self._phaseAt + CLOSING end
    if closed ~= self._want and now < self._irisAt + (irisType == "SHIELD" and SHIELD_TIME or IRIS_TIME) then
        ends[#ends + 1] = self._irisAt + (irisType == "SHIELD" and SHIELD_TIME or IRIS_TIME)
    end
    local moving = #ends > 0 or (phase ~= nil and closed < 1) or (closed > 0 and irisType == "SHIELD")
    local shown = phase ~= nil or closed > 0
    self._inside:visible(shown)
    self._inside:animated(moving)
    self._inside:fps((irisType == "SHIELD" and phase == nil) and 5 or 20)
    local wake = #ends > 0 and math.max(table.unpack(ends)) or nil
    if wake and wake ~= self._wake then
        event.timer(wake - now + 0.05, function() loom.invalidate() end)
    end
    self._wake = wake
    local still = (shown and not moving) and (tostring(closed) .. tostring(irisType) .. tostring(phase)) or nil
    if still and still ~= self._still then self._inside:refresh() end
    self._still = still
end
function Gate:draw()
    if not self:visible() then return end
    local state, lit, theme = self._look()
    self:_follow(state)
    local key = {state, theme or "MW"}
    for p = 1, 9 do key[#key + 1] = lit[p] and "1" or "0" end
    key = table.concat(key, ":")
    if key ~= self._picture then
        self._runs = runs(self._G, paint(self._G, state, lit, theme, self._bg))
        self._picture = key
    end
    local x0, y0 = self:absX() - 1, self:absY() - 1
    local fg, bg
    for _, run in ipairs(self._runs) do
        if run[2] ~= bg then bg = run[2] gpu.setBackground(bg) end
        if run[1] == run[2] then
            gpu.fill(x0 + run[3], y0 + run[4], run[5], 1, " ")
        else
            if run[1] ~= fg then fg = run[1] gpu.setForeground(fg) end
            gpu.fill(x0 + run[3], y0 + run[4], run[5], 1, "▀")
        end
    end
    return true
end
function Gate:checkCollision() return false end
ui.Gate = Gate


---------------------------------------------------------------------------- modal dialogs
-- Focuses w once the current event is handled. loom gives a touched widget the focus after its
-- touch callback runs, which would take the focus from a dialog that the touch just opened.
function ui.focusSoon(w)
    event.timer(0, function()
        pcall(w.focus, w)
        loom.invalidate()
    end)
end
-- A centred dialog over shell (the frame behind it). While it is open nothing behind it takes
-- touches or focus. Returns its frame and close(); content goes in the frame (coordinates
-- inside it). Focus a widget in it after adding them.
function ui.modal(root, shell, w, h, title)
    local frame = Frame(root, math.floor((ui.W - w) / 2) + 1, math.floor((ui.H - h) / 2) + 1)
    frame:size(w, h)
    frame:backgroundColor(C.card)
    frame:z(1000)
    ui.card(frame, 1, 1, w, h, title)
    local before, beforeScope = input.focused(), scope
    shell:enabled(false)
    scope = frame
    input.focus(nil)
    local function close()
        if not frame.getParent then return end
        input.focus(nil)
        scope = beforeScope
        if not beforeScope then shell:enabled(true) end
        frame:Destroy(true)
        if before and before.getParent then ui.focusSoon(before) end
        loom.invalidate()
    end
    return frame, close
end
function ui.modalOpen() return scope ~= nil end

return ui
