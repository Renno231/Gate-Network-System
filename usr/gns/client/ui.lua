-- The GNS client's look and controls, on loom: the tier-3 palette, cards, buttons, lists, text
-- fields, the drawn stargate, modal dialogs and keyboard focus.
--
-- Keyboard navigation is loom's (arrows, Tab, Enter/Space): GNS widgets show the focus as white
-- brackets beside them, and lists move their cursor before letting the focus out.
local loom = require("loom")
local gpu = require("loom.gpu")
local run = require("loom.run")
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
-- A tier-2 screen has 16 fixed colours with four greys (black, 0x333333, 0xCCCCCC, white), and
-- OC shows any other grey as the colour nearest in brightness: blue or brown. So on such a screen
-- the client's greys are taken to the nearest of the four (grey), the pages' (C) once here.
local function grey(c)
    if not ui.fourBit or not c then return c end
    local v = c & 0xFF
    if c ~= v * 0x10101 then return c end
    return v < 0x1A and 0 or v < 0x60 and 0x333333 or v < 0xE6 and 0xCCCCCC or 0xFFFFFF
end
function ui.setLayout(choice)
    local g = component.gpu
    if g.getDepth() == 4 and not ui.fourBit then
        ui.fourBit = true
        for k, v in pairs(C) do C[k] = grey(v) end
    end
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
    -- On 16 colours the card and raised greys are one grey: a field there is black to show.
    o:backgroundColor(ui.fourBit and C.page or C.raised)
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
--   pitch: rows per item, or a function returning it (default 1); a cell's fourth value puts it
--   on that line of its item (0 is the first), which the cursor colour then covers whole
--   empty: text shown when there are no items
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
function List:rows() return math.max(1, self:height() // (value(self._opts.pitch) or 1)) end
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
    local pitch = value(opts.pitch) or 1
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
        local top = y + (r - 1) * pitch
        local ry = top + (pitch - 1) // 2
        local selected = opts.selected and opts.selected(item, i)
        local bg = selected and C.amber or ((focused and i == self._cursor) and C.hover or C.card)
        local cells, lines = opts.cells(item, i, w), false
        for _, cell in ipairs(cells) do lines = lines or cell[4] ~= nil end
        gpu.setBackground(bg)
        if lines then self:_gpufill(x, top, w, pitch, " ") else self:_gpufill(x, ry, w, 1, " ") end
        for _, cell in ipairs(cells) do
            gpu.setForeground(selected and C.black or (cell[3] or C.text))
            self:_gpuset(x + cell[1], cell[4] and (top + cell[4]) or ry, usub(tostring(cell[2]), 1, math.max(0, w - cell[1])))
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
        local pitch = value(self._opts.pitch) or 1
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
        local pitch = value(self._opts.pitch) or 1
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
-- worked out once per size; a picture is worked out once per state and replayed after. Both are
-- strings (a byte per pixel; packed runs): as tables they took over 400 KB of a client's 2 MB.
local GLYPH_BITS = {}
do
    local seed = 20231
    for s = 1, 39 do
        seed = (seed * 1103515245 + 12345) % 0x80000000
        GLYPH_BITS[s] = ((seed >> 9) & (seed >> 17) & 0x1FF) | 0x10
    end
end
-- The flat gate's glyph s whose mark is at angle a, distance d from the middle (e = d - Rh), or
-- nil: one dot wide, across the middle of the glyph track.
local function glyphMark(e, a, d, k)
    local r = (e - 2 * k) / (3.5 * k)
    if r < 0.15 or r >= 0.85 then return nil end
    local sector = (((a + math.pi / 2) % (2 * math.pi)) / (2 * math.pi) * 39 + 0.5) % 39
    local s = math.floor(sector)
    if math.abs(sector - s - 0.5) * 2 * math.pi * d / 39 < 0.5 then return s end
end
local SHADES = {0x3C3C3C, 0x4B4B4B, 0x5A5A5A, 0x696969}
local SHADE_OF = {}
for i, v in ipairs(SHADES) do SHADE_OF[v] = i end
local geometries = {}
-- flat: the braille gate's version. A braille cell shows two colours, so glyph symbols a few dots
-- across, a thin rim and a chevron's housing round its light break up into specks: the ring is
-- one shade (two on a screen with more greys), each glyph one mark, each chevron a solid wedge.
local function geometry(Rh, flat)
    local key = flat and -Rh or Rh
    if geometries[key] then return geometries[key] end
    local k = Rh / 22
    local R = math.ceil(Rh + 12 * k)
    local w = 2 * R + 3
    local h = w + (w % 2)
    local cx, cy, TWO_PI = (w + 1) / 2, (h + 1) / 2, 2 * math.pi
    -- A pixel's byte: 0 the background, 1-4 a ring shade (SHADES), 5 the inside, 6-44 glyph
    -- s + 6, 46-54 chevron p's housing (p + 45), 56-64 its light (p + 55).
    local G, rows, cells = {Rh = Rh, k = k, w = w, h = h, cx = cx, cy = cy, flat = flat}, {}, {}
    for y = 1, h do
        for x = 1, w do
            local dx, dy = x - cx, y - cy
            local d = math.sqrt(dx * dx + dy * dy)
            local a = math.atan(dy, dx)
            local kind, v = 0, false
            if d <= Rh then
                kind = 1
            elseif flat and d <= Rh + 10 * k then
                v = (d > Rh + 1.5 * k and d <= Rh + 6 * k) and 0x4B4B4B or 0x3C3C3C
                local s = glyphMark(d - Rh, a, d, k)
                if s then kind, v = 2, s end
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
                        local light = k < 0.5 or flat or (u >= k and u <= 6.8 * k and math.abs(t - 0.35 * u) <= 1.0 * k)
                        kind, v = light and 4 or 3, p
                    end
                end
            end
            cells[x] = kind == 0 and (SHADE_OF[v] or 0) or kind == 1 and 5 or kind == 2 and v + 6 or kind == 3 and v + 45 or v + 55
        end
        rows[y] = string.char(table.unpack(cells, 1, w))
    end
    G.px = table.concat(rows)
    -- The band: the cells (column, row bytes) holding glyph track or chevron light, which move
    -- while the gate dials (Gate:_overlay).
    local band, px = {}, G.px
    local function moves(b) return b == 2 or (b >= 6 and b <= 44) or b >= 56 end
    for r = 1, h // 2 do
        for x = 1, w do
            if moves(px:byte((2 * r - 2) * w + x)) or moves(px:byte((2 * r - 1) * w + x)) then band[#band + 1] = string.char(x, r) end
        end
    end
    G.band = table.concat(band)
    geometries[key] = G
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

-- Each pixel byte's colour in this state.
local function colours(state, lit, theme, bg)
    theme = THEMES[theme] or THEMES.MW
    local c = {[0] = bg, [5] = bg} -- the inside: the horizon and iris Shader draws over it
    for i, v in ipairs(SHADES) do c[i] = theme.ring[v] or v end
    for s = 0, 38 do c[s + 6] = (state == "dial" and s == 0) and theme.light[2] or theme.glyph end
    for p = 1, 9 do
        c[p + 45] = theme.housing[lit[p] and 2 or 1]
        c[p + 55] = theme.light[lit[p] and 2 or 1]
    end
    for i, v in pairs(c) do c[i] = grey(v) end
    return c
end

-- The picture: runs of equal cells (fg, bg, column, row, length) grouped by colour, packed.
local RUN = "<I3I3BBB"
local function picture(G, c)
    local px, w, list, keys = G.px, G.w, {}, {}
    for r = 1, G.h // 2 do
        local top, bottom = (2 * r - 2) * w, (2 * r - 1) * w
        local x = 1
        while x <= w do
            local t, b = c[px:byte(top + x)], c[px:byte(bottom + x)]
            local n = 1
            while x + n <= w and c[px:byte(top + x + n)] == t and c[px:byte(bottom + x + n)] == b do n = n + 1 end
            list[#list + 1] = string.pack(RUN, t, b, x, r, n)
            keys[#list] = b << 37 | t << 13 | #list -- by background, then foreground (under 8192 runs)
            x = x + n
        end
    end
    table.sort(keys)
    for i, k in ipairs(keys) do keys[i] = list[k & 0x1FFF] end
    return table.concat(keys)
end

-- The inside of the ring: a loom Shader over the still ring picture, drawing the event horizon
-- and the iris over it. The horizon looks like the show's, which filmed light through water:
-- bright blue, ripples running out from the middle, a moving net of caustic highlights. It
-- bursts out (the kawoosh) when the wormhole opens and shrinks away when it closes. The iris is
-- JSG's: metal blades (titanium, or darker trinium) that close in a spiral, or the shield, a
-- glowing forcefield. The Shader animates only while something moves.
-- One channel of mix; outside it, so the horizon's thousands of mixes a frame make no closures.
local floor = math.floor
local function channel(a, b, f, s)
    local x, y = (a >> s) & 0xFF, (b >> s) & 0xFF
    return floor(x + (y - x) * f + 0.5) << s
end
local function mix(a, b, f)
    f = f < 0 and 0 or f > 1 and 1 or f
    return channel(a, b, f, 16) | channel(a, b, f, 8) | channel(a, b, f, 0)
end
local KAWOOSH, CLOSING, IRIS_TIME, SHIELD_TIME = 1.0, 0.6, 1.5, 0.6
-- Blade shades: dark, light, seam.
-- Greys, because the palette holds those exactly; tinted metal would come out beige or lilac.
local BLADES = {IRIS_TITANIUM = {0x5A5A5A, 0xB4B4B4, 0x1E1E1E}, IRIS_CREATIVE = {0x5A5A5A, 0xB4B4B4, 0x1E1E1E},
    IRIS_TRINIUM = {0x2D2D2D, 0x787878, 0x0F0F0F}}
local sin, cos, abs, sqrt, atan, pi = math.sin, math.cos, math.abs, math.sqrt, math.atan, math.pi

-- The event horizon's colour at (x, y) from the middle, r = its distance, edge = the horizon's
-- reach now; s scales any gate size to the 22-pixel one the numbers are tuned for. since: seconds
-- since the wormhole opened, for the ring of water the kawoosh leaves running out and fading.
local function water(x, y, r, edge, now, s, since)
    x, y, r = x * s, y * s, r * s
    local wx = x + 1.6 * sin(y * 0.31 + now * 0.9)
    local wy = y + 1.6 * sin(x * 0.27 - now * 0.8)
    local caustic = 1 - abs(sin(wx * 0.45 + now * 0.6) + sin(wy * 0.45 - now * 0.5)) / 2
    caustic = caustic * caustic * caustic * caustic * caustic
    local ripple = sin(r * 0.55 - now * 2.2)
    local c = mix(0x1C5FD0, 0x5FB4FF, 0.5 + 0.3 * ripple)
    c = mix(c, 0xE8F8FF, caustic * 0.9)
    if since and since < 1.2 then c = mix(c, 0xFFFFFF, math.exp(-((r - since * 25) / 1.6) ^ 2) * (1 - since / 1.2)) end
    return mix(c, 0x0A2A6A, (r / (edge * s)) ^ 5)
end

local function outCubic(f) f = 1 - f return 1 - f * f * f end
-- The kawoosh: the horizon bursts out past the ring (0.3 s), holds, and pulls back into it by 1 s,
-- its edge churning. Its colour at (x, y) from the middle (r away), t seconds in; nil past its
-- edge. far: its reach, k the gate's scale.
local function burst(x, y, r, t, Rh, far, k)
    local reach
    if t < 0.3 then reach = far * outCubic(t / 0.3)
    elseif t < 0.55 then reach = far
    else reach = far - (far - Rh) * outCubic(math.min(1, (t - 0.55) / 0.45)) end
    if r > reach + 2.1 * k then return nil end
    local a = atan(y, x)
    reach = reach + k * (1.3 * sin(a * 7 + t * 23) + 0.8 * sin(a * 13 - t * 17))
    if r > reach then return nil end
    local ray = 0.5 + 0.5 * sin(a * 11 + r / k * 0.35 - t * 14)
    local c = mix(0xFFFFFF, 0x8FD0FF, (r / reach) ^ 2 * 0.8 + ray * 0.25)
    if t > 0.55 then c = mix(c, 0x5FB4FF, (t - 0.55) / 0.45 * 0.7) end
    return c
end

-- The colour at (dx, dy) gate pixels from the middle at time now: the horizon and the iris over
-- it inside the ring, the kawoosh past it; nil where none of them shows.
local function insideColour(gate, G, dx, dy, now)
    local Rh = G.Rh
    local s = 22 / Rh
    local r = sqrt(dx * dx + dy * dy)
    local phase, t, closed = gate:_at(now)
    if r > Rh then
        -- Past the ring only the kawoosh shows, and not through a shut iris.
        if phase ~= "kawoosh" or closed > 0 then return nil end
        return burst(dx, dy, r, t, Rh, Rh + 11 * G.k, G.k) -- its reach: inside the gate's box
    end
    local colour
    -- The horizon.
    if phase == "kawoosh" then
        colour = burst(dx, dy, r, t, Rh, Rh + 11 * G.k, G.k) or water(dx, dy, r, Rh, now, s)
    elseif phase then
        local edge = phase == "closing" and Rh * (1 - t / CLOSING) or Rh
        if r < edge then colour = water(dx, dy, r, edge, now, s, phase == "open" and t) end
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
            if b * 2 * pi * math.max(r, 1) / n < 0.9 then return grey(metal[3]) end
            if small then
                local mid = (math.floor(turns) + 0.5) / n * 2 * pi - closed * 1.2 - 0.7
                return grey(mix(metal[1], metal[2], 0.5 + 0.5 * cos(mid + 2.4)))
            end
            local light = 0.5 + 0.5 * cos(a + 2.4)
            return grey(mix(metal[1], metal[2], 0.15 + 0.5 * (1 - b) + 0.35 * light * r / Rh))
        end
    end
    return colour
end

local function inside(gate, parent, x, y, G)
    -- The smallest block of whole cells around the inside: columns c0.., cell rows r0.. of the gate.
    local cx, cy, Rh = (G.w + 1) / 2, (G.h + 1) / 2, G.Rh
    local c0 = math.max(1, math.floor(cx - Rh))
    local r0 = math.max(1, math.floor((cy - Rh + 1) / 2))
    local w = math.min(G.w, math.ceil(cx + Rh)) - c0 + 1
    local h = math.min(G.h // 2, math.ceil((cy + Rh) / 2)) - r0 + 1
    local px0, py0 = c0 - 1, 2 * r0 - 2 -- local pixel (1, 1) is gate pixel (c0, 2 r0 - 1)
    local shader = loom.widget.Shader(parent, x + c0 - 1, y + r0 - 1, w, h, function(px, py)
        return insideColour(gate, G, px0 + px - cx, py0 + py - cy, computer.uptime())
    end)
    shader:dither(false)
    shader:visible(false)
    shader.checkCollision = function() return false end
    -- The kawoosh bursts past the ring: for it the Shader covers the whole gate, else the inside.
    function shader.whole(on)
        if on then px0, py0 = 0, 0 shader:x(x) shader:y(y) shader:size(G.w, G.h // 2)
        else px0, py0 = c0 - 1, 2 * r0 - 2 shader:x(x + c0 - 1) shader:y(y + r0 - 1) shader:size(w, h) end
    end
    return shader
end

-- While the gate dials its glyph track turns, the other way round at each chevron, and once the
-- last chevron locks it comes to rest with the point of origin at the top (a Pegasus gate: a
-- light runs round its glyphs instead). A chevron flashes white as it locks. Drawn over the still
-- picture, in the cells G.band, only while some of it moves.
local TURN, SETTLE, FLASH, TWO_PI = 1.4, 0.6, 0.35, 2 * math.pi
-- One pixel of the band: geometry byte b at gate pixel (x, y), c the picture's colours.
local function bandPixel(gate, G, c, b, x, y, now)
    if b == 2 or (b >= 6 and b <= 44) then
        if gate._chase then
            if b == 2 then return c[2] end
            return b - 6 == gate._chase and gate._glyphOn or gate._glyphOff
        end
        local dx, dy, k = x - G.cx, y - G.cy, G.k
        local d = sqrt(dx * dx + dy * dy)
        if G.flat then
            local s = glyphMark(d - G.Rh, atan(dy, dx) - gate._turned, d, k)
            if s then return s == gate._top and gate._glyphOn or gate._glyphOff end
            return c[2]
        end
        local r = (d - (G.Rh + 2 * k)) / (3.5 * k)
        if r >= 0 and r < 1 then
            local sector = (((atan(dy, dx) - gate._turned + pi / 2) % TWO_PI) / TWO_PI * 39 + 0.5) % 39
            local s = floor(sector)
            local u = (sector - s - 0.2) / 0.6
            if u >= 0 and u < 1 and (GLYPH_BITS[s + 1] >> (floor(r * 3) * 3 + floor(u * 3))) & 1 == 1 then
                return s == gate._top and gate._glyphOn or gate._glyphOff
            end
        end
        return c[2]
    elseif b >= 56 then
        local at = gate._litAt[b - 55]
        if at and now - at < FLASH then return grey(mix(0xFFFFFF, c[b], (now - at) / FLASH)) end
    end
    return c[b]
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
    o._litAt, o._dir = {}, 1
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
        self._phase, self._phaseAt = open and "open" or nil, now - 2
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
    local whole = self._phase == "kawoosh"
    if whole ~= self._whole then self._inside.whole(whole) self._whole = whole end

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
    -- 5 fps for a still shield's shimmer, and on the gate's own computer, where the gate needs the time.
    self._inside:fps(((irisType == "SHIELD" and phase == nil) or (package.loaded["gns.here"] or {}).gate) and 5 or 20)
    local wake = #ends > 0 and math.max(table.unpack(ends)) or nil
    if wake and wake ~= self._wake then
        event.timer(wake - now + 0.05, function() loom.invalidate() end)
    end
    self._wake = wake
    local still = (shown and not moving) and (tostring(closed) .. tostring(irisType) .. tostring(phase)) or nil
    if still and still ~= self._still then self._inside:refresh() end
    self._still = still
end
-- Moves the glyph track and the chevron flashes on to now; true while any of them moves.
function Gate:_turn(state, lit, engaged, total, theme, now)
    local dt = math.min(0.25, now - (self._turnAt or now))
    self._turnAt = now
    local litAt, was, moving = self._litAt, self._lit, false
    for p = 1, 9 do
        if not lit[p] then litAt[p] = nil
        elseif was and not was[p] then litAt[p] = now end -- not on first sight
        if litAt[p] and now - litAt[p] < FLASH then moving = true end
    end
    self._lit = lit
    if state == "dial" and engaged and total and engaged < total then
        if self._engaged and engaged ~= self._engaged then self._dir = -self._dir end
        self._engaged = engaged
        self._spin, self._settle, moving = (self._spin or 0) + self._dir * TURN * dt, nil, true
    else
        self._engaged = nil
        if self._spin and theme == "PG" then self._spin = nil
        elseif self._spin then
            if not self._settle then self._settle = {self._spin, floor(self._spin / TWO_PI + 0.5) * TWO_PI, now} end
            local from, to, at = table.unpack(self._settle)
            local f = (now - at) / SETTLE
            if f >= 1 then self._spin, self._settle = nil, nil
            else self._spin, moving = from + (to - from) * outCubic(f), true end
        end
    end
    local spin = self._spin or 0
    self._turned = spin
    self._chase = theme == "PG" and self._spin and floor(spin / TWO_PI * 39) % 39 or nil
    -- The glyph lit at the top while dialing: the one the turned track has brought there.
    self._top = state == "dial" and floor((-spin % TWO_PI) / TWO_PI * 39 + 0.5) % 39 or -1
    return moving
end
local function fill(x0, y0, x, r, n, t, b)
    gpu.setBackground(b)
    if t == b then gpu.fill(x0 + x, y0 + r, n, 1, " ")
    else gpu.setForeground(t) gpu.fill(x0 + x, y0 + r, n, 1, "▀") end
end
-- Draws the band over the picture, in runs of equal cells along a row.
function Gate:_overlay(x0, y0, now)
    local G, c = self._G, self._colours
    local px, w, band = G.px, G.w, G.band
    local fx, fr, ft, fb, fn = 0, 0, nil, nil, 0
    for i = 1, #band, 2 do
        local x, r = band:byte(i, i + 1)
        local t = bandPixel(self, G, c, px:byte((2 * r - 2) * w + x), x, 2 * r - 1, now)
        local b = bandPixel(self, G, c, px:byte((2 * r - 1) * w + x), x, 2 * r, now)
        if r == fr and x == fx + fn and t == ft and b == fb then fn = fn + 1
        else
            if fn > 0 then fill(x0, y0, fx, fr, fn, ft, fb) end
            fx, fr, ft, fb, fn = x, r, t, b, 1
        end
    end
    if fn > 0 then fill(x0, y0, fx, fr, fn, ft, fb) end
end
function Gate:draw()
    if not self:visible() then return end
    local part = gpu.part(self) -- a turning ring redraws only the gate
    local state, lit, theme, engaged, total = self._look()
    self:_follow(state)
    local key = {state, theme or "MW"}
    for p = 1, 9 do key[#key + 1] = lit[p] and "1" or "0" end
    key = table.concat(key, ":")
    if key ~= self._picture then
        local T = THEMES[theme] or THEMES.MW
        self._colours = colours(state, lit, theme, self._bg)
        self._glyphOff, self._glyphOn = grey(T.glyph), T.light[2]
        self._runs = picture(self._G, self._colours)
        self._picture = key
    end
    local x0, y0 = self:absX() - 1, self:absY() - 1
    local fg, bg
    local runs, at = self._runs, 1
    while at <= #runs do
        local t, b, x, y, n
        t, b, x, y, n, at = string.unpack(RUN, runs, at)
        if b ~= bg then bg = b gpu.setBackground(bg) end
        if t == b then
            gpu.fill(x0 + x, y0 + y, n, 1, " ")
        else
            if t ~= fg then fg = t gpu.setForeground(fg) end
            gpu.fill(x0 + x, y0 + y, n, 1, "▀")
        end
    end
    local now = computer.uptime()
    local moving = self:_turn(state, lit, engaged, total, theme, now)
    if moving or self._spin then self:_overlay(x0, y0, now) end
    gpu.partEnd(part)
    -- 5 fps on the gate's own computer, where the gate needs the time.
    if moving then run.request((package.loaded["gns.here"] or {}).gate and 0.2 or 0.05, self) end
    return true
end
function Gate:checkCollision() return false end
ui.Gate = Gate

---------------------------------------------------------------------------- the stargate in braille
-- The tablet's gate: the same gate drawn in braille characters, 2 x 4 dots a cell, so the same
-- cells hold four times the pixels of the half-block gate. A cell shows two colours: of its eight
-- dots' colours the most common is its background, the one furthest from that its dots, and each
-- dot takes the nearer of the two. The still picture is worked out once per state; the inside
-- (horizon, kawoosh, iris) and the turning glyph track are worked out again each frame they move.
local BIT = {0x01, 0x08, 0x02, 0x10, 0x04, 0x20, 0x40, 0x80} -- dot (dx, dy) of a cell: BIT[dy * 2 + dx + 1]
local BRAILLE = {}
local function brailleChar(bits)
    local ch = BRAILLE[bits]
    if not ch then ch = unicode.char(0x2800 + bits) BRAILLE[bits] = ch end
    return ch
end
local function apart(a, b)
    local dr, dg, db = (a >> 16) - (b >> 16), ((a >> 8) & 0xFF) - ((b >> 8) & 0xFF), (a & 0xFF) - (b & 0xFF)
    return dr * dr + dg * dg + db * db
end
-- One cell from its eight dot colours d: foreground, background and character. The background
-- is the commonest colour; the dots, the colour with the most of (dots x distance from it), so
-- a small bright chevron light still shows, and a ring of several greys snapped to the few a
-- tier-2 screen has stays whole instead of breaking up.
local seen, count = {}, {}
local function brailleCell(d)
    local n = 0
    for i = 1, 8 do
        local c, k = d[i], 1
        while k <= n and seen[k] ~= c do k = k + 1 end
        if k > n then n, seen[k], count[k] = k, c, 0 end
        count[k] = count[k] + 1
    end
    if n == 1 then return d[1], d[1], " " end
    local bg, best = seen[1], count[1]
    for k = 2, n do if count[k] > best then bg, best = seen[k], count[k] end end
    local fg, most = bg, -1
    for k = 1, n do
        local f = count[k] * apart(seen[k], bg)
        if f > most then fg, most = seen[k], f end
    end
    local bits = 0
    for i = 1, 8 do
        local c = d[i]
        if c == fg or (c ~= bg and apart(c, fg) < apart(c, bg)) then bits = bits | BIT[i] end
    end
    if bits == 0xFF then return fg, fg, " " end
    return fg, bg, brailleChar(bits)
end
-- The cells of a braille gate: all of them, those holding some of the inside, and those holding
-- some of the glyph track or a chevron light (string.char(column, row) each).
local brailles = {}
local function brailleGeometry(Rh)
    if brailles[Rh] then return brailles[Rh] end
    local G = geometry(Rh, true)
    local B = {G = G, cols = (G.w + 1) // 2, rows = (G.h + 3) // 4}
    local all, inner, band = {}, {}, {}
    for r = 1, B.rows do
        for c = 1, B.cols do
            local hasInside, hasBand = false, false
            for i = 0, 7 do
                local x, y = 2 * c - 1 + i % 2, 4 * r - 3 + i // 2
                local b = x <= G.w and y <= G.h and G.px:byte((y - 1) * G.w + x) or 0
                if b == 5 then hasInside = true end
                if b == 2 or (b >= 6 and b <= 44) or b >= 56 then hasBand = true end
            end
            local at = string.char(c, r)
            all[#all + 1] = at
            if hasInside then inner[#inner + 1] = at end
            if hasBand then band[#band + 1] = at end
        end
    end
    B.all, B.inner, B.band = table.concat(all), table.concat(inner), table.concat(band)
    brailles[Rh] = B
    return B
end
-- A braille gate's size in cells, for Rh (its horizon's radius in dots).
ui.brailleSize = function(Rh) local B = brailleGeometry(Rh) return B.cols, B.rows end

local dots = {}
-- Cell (col, row)'s eight dot colours into dots: the picture's colours c, the moving band over
-- them (band), the inside over both (inner; whole: past the ring too, for the kawoosh).
local function cellDots(gate, G, c, col, row, now, band, inner, whole)
    local px, w, h = G.px, G.w, G.h
    for i = 0, 7 do
        local x, y = 2 * col - 1 + i % 2, 4 * row - 3 + i // 2
        local b = x <= w and y <= h and px:byte((y - 1) * w + x) or 0
        local v
        if inner and (b == 5 or whole) then v = insideColour(gate, G, x - G.cx, y - G.cy, now) end
        if not v then v = band and bandPixel(gate, G, c, b, x, y, now) or c[b] end
        dots[i + 1] = v
    end
    return brailleCell(dots)
end
-- The still picture: runs of cells with the same colours along a row, packed.
local CELLS = "<I3I3BBs1"
local function braillePicture(B, c)
    local out = {}
    for r = 1, B.rows do
        local runFg, runBg, runX, text = nil, nil, nil, {}
        for col = 1, B.cols + 1 do
            local fg, bg, ch
            if col <= B.cols then fg, bg, ch = cellDots(nil, B.G, c, col, r, 0, false, false) end
            if col > B.cols or fg ~= runFg or bg ~= runBg then
                if runX then out[#out + 1] = string.pack(CELLS, runFg, runBg, runX, r, table.concat(text)) end
                runFg, runBg, runX, text = fg, bg, col, {}
            end
            text[#text + 1] = ch
        end
    end
    return table.concat(out)
end

local BrailleGate = class(Widget)
-- Gate's own following of the wormhole, iris and glyph track; the inside is drawn here, so
-- what Gate tells its Shader is kept instead.
BrailleGate._at, BrailleGate._follow, BrailleGate._turn = Gate._at, Gate._follow, Gate._turn
local KEPT = {visible = function(self, v) self.shown = v end, animated = function(self, v) self.moving = v end,
    fps = function() end, refresh = function() end, whole = function() end}
KEPT.__index = KEPT
-- As ui.Gate (look, bg, iris), Rh the horizon's radius in dots.
function BrailleGate:new(parent, x, y, Rh, look, bg, iris)
    local B = brailleGeometry(Rh)
    local o = self.parent(parent, x, y)
    setmetatable(o, self)
    o:size(B.cols, B.rows)
    o._B, o._G, o._look, o._bg, o._iris = B, B.G, look, bg or C.page, iris
    o._from, o._want, o._irisAt = 0, 0, 0
    o._litAt, o._dir = {}, 1
    o._inside = setmetatable({}, KEPT)
    return o
end
function BrailleGate:draw()
    if not self:visible() then return end
    local part = gpu.part(self)
    local B, G = self._B, self._G
    local state, lit, theme, engaged, total = self._look()
    self:_follow(state)
    local key = {state, theme or "MW"}
    for p = 1, 9 do key[#key + 1] = lit[p] and "1" or "0" end
    key = table.concat(key, ":")
    if key ~= self._picture then
        local T = THEMES[theme] or THEMES.MW
        self._colours = colours(state, lit, theme, self._bg)
        self._glyphOff, self._glyphOn = grey(T.glyph), T.light[2]
        self._runs = braillePicture(B, self._colours)
        self._picture = key
    end
    local x0, y0 = self:absX() - 1, self:absY() - 1
    local fg, bg
    local runs, at = self._runs, 1
    while at <= #runs do
        local t, b, x, y, s
        t, b, x, y, s, at = string.unpack(CELLS, runs, at)
        if b ~= bg then bg = b gpu.setBackground(b) end
        if t ~= fg then fg = t gpu.setForeground(t) end
        gpu.set(x0 + x, y0 + y, s)
    end
    local now = computer.uptime()
    local moving = self:_turn(state, lit, engaged, total, theme, now)
    local band, inner = moving or self._spin ~= nil, self._inside.shown
    if band or inner then
        local cells = self._whole and B.all or ((inner and B.inner or "") .. (band and B.band or ""))
        local c = self._colours
        for i = 1, #cells, 2 do
            local col, row = cells:byte(i, i + 1)
            local t, b, ch = cellDots(self, G, c, col, row, now, band, inner, self._whole)
            if b ~= bg then bg = b gpu.setBackground(b) end
            if t ~= fg then fg = t gpu.setForeground(t) end
            gpu.set(x0 + col, y0 + row, ch)
        end
    end
    gpu.partEnd(part)
    -- 10 frames a second; 5 on the gate's own computer, where the gate needs the time.
    if moving or self._inside.moving then run.request((package.loaded["gns.here"] or {}).gate and 0.2 or 0.1, self) end
    return true
end
-- Seen idle while hidden: so the next wormhole bursts open and the iris is seen closing (Gate
-- shows neither on first sight).
function BrailleGate:idle()
    if self._open ~= nil then return end
    local kind
    if self._iris then kind = select(2, self._iris()) end
    self._open, self._seen, self._from, self._want = false, true, 0, 0
    self._irisType = (BLADES[kind] or kind == "SHIELD") and kind or nil
end
function BrailleGate:checkCollision() return false end
ui.BrailleGate = BrailleGate


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
    local x, y = math.floor((ui.W - w) / 2) + 1, math.floor((ui.H - h) / 2) + 1
    -- A black margin and a light outline round it: on a 16-colour screen the card greys are all
    -- one grey, and the dialog would melt into the cards behind it.
    local edge = Frame(root, x - 1, y - 1)
    edge:size(w + 2, h + 2)
    edge:backgroundColor(C.page)
    edge:z(999)
    ui.Paint(edge, 1, 1, w + 2, h + 2, function(self)
        local line = string.rep("─", w)
        self:text(1, 1, "┌" .. line .. "┐", C.dim, C.page)
        for r = 2, h + 1 do self:text(1, r, "│", C.dim, C.page) self:text(w + 2, r, "│", C.dim, C.page) end
        self:text(1, h + 2, "└" .. line .. "┘", C.dim, C.page)
    end)
    local frame = Frame(root, x, y)
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
        edge:Destroy(true)
        if before and before.getParent then ui.focusSoon(before) end
        loom.invalidate()
    end
    return frame, close
end
function ui.modalOpen() return scope ~= nil end

return ui
