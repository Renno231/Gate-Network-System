-- Gate room mode: the gate computer's screen as the dialing room display. The gate drawn with
-- its chevrons locking (a beep for each), the wormhole's state and time, and the travellers let
-- through. Addresses and IDCs never show. Any key goes back to the console (only the computer's
-- OC users, the owner and admins, can press one).
local component = require("component")
local computer = require("computer")
local event = require("event")
local term = require("term")

local room = {}

local AMBER, DIM, TEXT, RED, SKY, BLACK = 0xFFB000, 0x4B4B4B, 0xE1E1E1, 0xFF3C3C, 0x3CB4FF, 0x000000
-- Chevron places, clockwise from the top; the order they lock in: the last of an address locks
-- at the top, the rest from the upper right round, then the two at the bottom (8 and 9 glyphs).
local ORDER = {2, 3, 4, 7, 8, 9, 5, 6}

local function lit(engaged, total)
    local on = {}
    for n = 1, engaged do on[n == total and 1 or ORDER[n] or 1] = true end
    return on
end

local function clock(seconds)
    if not seconds then return "" end
    return ("%d:%02d"):format(seconds // 60, seconds % 60)
end

-- Draws once: dialer status s, the gate's name, the traveller log.
local function draw(gpu, s, name, travellers, flash)
    local W, H = gpu.getResolution()
    gpu.setBackground(BLACK)
    gpu.fill(1, 1, W, H, " ")
    local open = s.state == "open"
    local total = math.max(#(s.target or {}), 7)
    local engaged = open and total or #(s.glyphs or {})
    local on = lit(math.min(engaged, total), total)
    local cx, cy = W // 3, H // 2 + 1
    local ry = math.max(3, math.min(H // 2 - 3, (W // 3 - 4) // 2))
    local rx = ry * 2
    -- The ring, then the horizon or the iris inside it.
    gpu.setForeground(DIM)
    for a = 0, 359, 4 do
        local t = math.rad(a)
        gpu.set(cx + math.floor(math.sin(t) * rx + 0.5), cy - math.floor(math.cos(t) * ry + 0.5), "•")
    end
    if open then
        local shut = s.iris == "CLOSED"
        gpu.setForeground(shut and DIM or SKY)
        for y = -ry + 2, ry - 2 do
            local half = math.floor(math.sqrt(math.max(0, 1 - (y / (ry - 1)) ^ 2)) * (rx - 3))
            if half > 0 then gpu.set(cx - half, cy + y, (shut and "▒" or "≈"):rep(half * 2 + 1)) end
        end
    end
    for i = 1, 9 do
        local t = math.rad((i - 1) * 40)
        gpu.setForeground(on[i] and AMBER or DIM)
        gpu.set(cx + math.floor(math.sin(t) * (rx + 2) + 0.5) - 1, cy - math.floor(math.cos(t) * (ry + 1) + 0.5), "▼▼▼")
    end
    -- The panel: name, what the gate is doing, wormhole time, travellers.
    local x, y = W * 2 // 3 - 2, 3
    local function line(text, colour)
        gpu.setForeground(colour or TEXT)
        gpu.set(x, y, tostring(text):sub(1, W - x))
        y = y + 1
    end
    line(name, AMBER)
    y = y + 1
    local headline, colour = "GATE IDLE", DIM
    if s.alarm then headline, colour = "OFF-WORLD ACTIVATION", flash and RED or TEXT
    elseif open then headline, colour = s.outgoing and "WORMHOLE OPEN" or "INCOMING WORMHOLE", SKY
    elseif engaged > 0 or s.dialing then
        headline, colour = engaged >= total and ("CHEVRON " .. total .. " LOCKED") or ("CHEVRON " .. engaged .. " ENCODED"), AMBER
    end
    line(headline, colour)
    if open then
        line("Open " .. clock(s.open) .. (s.left and ("  ·  " .. clock(s.left) .. " left") or ""), TEXT)
        line("Iris " .. tostring(s.iris), s.iris == "CLOSED" and RED or TEXT)
    end
    y = y + 1
    line("TRAVELLERS", DIM)
    if #travellers == 0 then line("none yet", DIM) end
    for i = #travellers, math.max(1, #travellers - (H - y - 2)), -1 do
        line(travellers[i].time .. "  " .. travellers[i].name, TEXT)
    end
    gpu.setForeground(DIM)
    gpu.set(1, H, ("Any key: the console"):sub(1, W))
end

-- Shows the room until a key is pressed. node: from gate.start; settings: the gate's settings.
function room.run(node, settings)
    local gpu = component.gpu
    local before, flash, last = 0, false, nil
    local function frame()
        -- node.view, not node.status: a status costs the gate five stargate calls, a tick each.
        local s = node.view()
        local engaged = s.state == "open" and 0 or #(s.glyphs or {})
        -- One beep per chevron: JSG hides the glyphs while the wormhole forms and shows them again
        -- once it is stable, so the count only starts over once the gate is idle and clear.
        if engaged > before then computer.beep(500 + engaged * 60, 0.1) end
        if engaged > before or (s.state == "idle" and engaged == 0) then before = engaged end
        flash = not flash
        local key = table.concat({s.state, engaged, tostring(s.iris), tostring(s.alarm and flash), tostring(s.open), #node.dialer.travellers})
        if key ~= last then
            last = key
            draw(gpu, s, settings.name or "Gate", node.dialer.travellers, flash)
        end
        return s.state ~= "idle" or engaged > 0 or s.dialing or s.alarm
    end
    -- Drawn again on each signal but a modem message (JSG's chevron, gate and iris events, a DHD
    -- press), and each second while the gate is busy for its clock and the alarm's flash: node.view
    -- asks the stargate nothing then. An idle gate costs nothing until something happens.
    local ok, err = pcall(function() -- Ctrl+Alt+C: the room stops drawing too
        local active, due = frame(), computer.uptime() + 1
        while true do
            local name = event.pull(active and math.max(0, due - computer.uptime()) or math.huge)
            if name == "key_down" then return end
            if name ~= "modem_message" or (active and computer.uptime() >= due) then
                local drew, busy = pcall(frame)
                active, due = not drew or busy, computer.uptime() + 1
            end
        end
    end)
    gpu.setBackground(BLACK)
    gpu.setForeground(0xFFFFFF)
    term.clear()
    if not ok then error(err, 0) end
end

return room
