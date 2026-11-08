-- GNS dialing: drives the JSG stargate for gate.lua. It dials the shortest address the gate
-- accepts, continues a partly dialed address, presses the DHD for fast dials, closes the iris
-- against the kawoosh, sends IDCs and answers them, and guards incoming wormholes. Everything
-- runs from timers and stargate events, so calls return at once.
--
-- Waits are in game time: computer.uptime and timers count server ticks, so lag makes them
-- longer in real time but never shorter in ticks. The TPS probe reports how far the server
-- runs behind real time.
local computer = require("computer")
local event = require("event")
local fs = require("filesystem")

local dialing = {}

dialing.TYPE = {MILKYWAY = "MW", PEGASUS = "PG", UNIVERSE = "UN"}
dialing.ORIGIN = {MW = "Point of Origin", PG = "Subido", UN = "Glyph 17"}
local DIAL_TIMEOUT = 120 -- seconds a whole dial may take
local KAWOOSH_TICKS = 20 -- ticks after the wormhole opens before the iris opens again
local IDC_TRIES = 10
local TPS_PERIOD = 30 -- seconds between TPS samples

-- The glyphs of a "[A, B, C]" dialedAddress.
local function dialedGlyphs(stargate)
    local text = tostring(stargate.dialedAddress or "[]"):match("^%[(.*)%]$") or ""
    local list = {}
    for glyph in text:gmatch("[^,]+") do list[#list + 1] = glyph:match("^%s*(.-)%s*$") end
    return list
end

-- JSG ends code messages with a colour code ("§r").
local function plain(message)
    return (tostring(message or ""):gsub("§.", ""))
end

-- Server ticks per second: game time (computer.uptime) against the real clock, which a file's
-- modification time gives. One small /tmp write per sample.
local function tpsProbe()
    local probe, last = {tps = 20}, nil
    local function sample()
        local file = io.open("/tmp/gns-tps", "w")
        if not file then return end
        file:write("t")
        file:close()
        local now = {uptime = computer.uptime(), real = fs.lastModified("/tmp/gns-tps")}
        if last and now.real > last.real then
            probe.tps = math.min(20, (now.uptime - last.uptime) * 20000 / (now.real - last.real))
        end
        last = now
    end
    sample()
    probe.timer = event.timer(TPS_PERIOD, sample, math.huge)
    return probe
end

-- stargate: the JSG component (or a stand-in); dhd: the DHD component or nil; settings: the
-- gate's settings, read live: kawoosh (false turns avoidance off) and idcs {[code] = name}.
function dialing.new(stargate, dhd, settings)
    local dialer = {state = "idle", log = {}}
    local stepTimer, listeners, idc = nil, {}, nil
    local probe = tpsProbe()

    local function note(text)
        dialer.state = text
        dialer.log[#dialer.log + 1] = text
        if #dialer.log > 20 then table.remove(dialer.log, 1) end
    end

    local function hasIris()
        return tostring(stargate.getIrisType()) ~= "NULL"
    end

    -- Moves the iris toward want ("OPENED" or "CLOSED"); true once it is there or there is none.
    local function irisTo(want)
        if not hasIris() then return true end
        local now = stargate.getIrisState()
        if now == want then return true end
        if now == "OPENED" or now == "CLOSED" then stargate.toggleIris() end
        return false
    end

    -- Runs step every tick until it returns true or deadline passes (then onTimeout).
    local function every(step, deadline, onTimeout)
        local id
        id = event.timer(0.05, function()
            if computer.uptime() >= deadline then
                if onTimeout then onTimeout() end
                return false
            end
            if step() then return false end
        end, math.huge)
        return id
    end

    local function after(ticks, fn) return event.timer(ticks / 20, fn) end

    -- Outgoing IDC: send the code once the wormhole is open; resend when the far gate asks or
    -- does not answer within 3 s.
    local function sendIdc(code)
        idc = {code = code, tries = 0}
        local function send()
            if not idc or idc.code ~= code then return end
            if idc.tries >= IDC_TRIES then note("IDC: no answer") idc = nil return end
            idc.tries = idc.tries + 1
            stargate.sendIrisCode(code)
            local try = idc.tries
            after(60, function()
                if idc and idc.code == code and idc.tries == try and not idc.answered then send() end
            end)
        end
        idc.send = send
        send()
    end

    local function onCodeRespond(message)
        if not idc then return end
        message = plain(message)
        if message:match("Resend IDC") or message == "Iris is busy!" or message:match("^Waiting") then
            after(20, idc.send)
            return
        end
        idc.answered = true
        note("IDC: " .. message)
        idc = nil
    end

    -- Incoming wormholes: the iris closes; a known IDC opens it again.
    local function onIncoming()
        dialer.incoming = true
        if hasIris() then irisTo("CLOSED") end
        note("incoming wormhole")
    end

    local function onCode(code)
        code = math.floor(tonumber(code) or -1)
        local name = (settings.idcs or {})[code]
        if not hasIris() then
            stargate.sendMessageToIncoming("Gate is open!")
            return
        end
        if not name then
            stargate.sendMessageToIncoming("Invalid IDC.")
            irisTo("CLOSED")
            note("refused IDC " .. code)
            return
        end
        note("IDC from " .. name)
        every(function()
            if stargate.getGateStatus() ~= "open" or not irisTo("OPENED") then return false end
            stargate.sendMessageToIncoming("Gate is open!")
            note("iris open for " .. name)
            return true
        end, computer.uptime() + 30)
    end

    local function onClose()
        dialer.incoming, idc = false, nil
        if hasIris() and stargate.getIrisState() == "CLOSED" then stargate.toggleIris() end
        note("closed")
    end

    for name, handler in pairs({
        stargate_incoming_wormhole = function() onIncoming() end,
        received_code = function(_, _, _, code) onCode(code) end,
        code_respond = function(_, _, _, message) onCodeRespond(message) end,
        stargate_close = function() onClose() end,
    }) do
        listeners[#listeners + 1] = {name, handler}
        event.listen(name, handler)
    end

    -- An open incoming wormhole at start (the computer restarted): close the iris until the
    -- traveller's gate resends its IDC.
    do
        local gateState, outgoing = stargate.getGateStatus()
        if gateState == "open" and not outgoing and hasIris() and next(settings.idcs or {}) then
            irisTo("CLOSED")
            pcall(stargate.sendMessageToIncoming, "Iris closed. Resend IDC.")
        end
    end

    -- The shortest form of glyphs (origin last) that the gate can dial, and its energy cost.
    local function shortest(glyphs, origin)
        for n = 6, #glyphs - 1 do
            local try = {table.unpack(glyphs, 1, n)}
            try[#try + 1] = origin
            local cost = stargate.getEnergyRequiredToDial(table.unpack(try))
            if type(cost) == "table" then return try, cost end
        end
    end

    -- Dials address {MW = {...}, PG = {...}, UN = {...}}. opts: fast (use the DHD), idc (a
    -- code to send once open). Returns {glyphs, from, open, keepAlive, seconds, fast} or errors.
    function dialer.dial(address, opts)
        opts = opts or {}
        local own = dialing.TYPE[stargate.getGateType()] or "MW"
        local origin = dialing.ORIGIN[own]
        local given = type(address) == "table" and address[own]
        if type(given) ~= "table" then error("no " .. own .. " address", 0) end
        local glyphs = {}
        for i = 1, #given do
            if type(given[i]) ~= "string" then error("bad address", 0) end
            if given[i] ~= origin then glyphs[#glyphs + 1] = given[i] end
        end
        if #glyphs < 6 or #glyphs > 8 then error("bad address", 0) end
        glyphs[#glyphs + 1] = origin
        if stepTimer then error("already dialing", 0) end
        local gateState, outgoing = stargate.getGateStatus()
        if gateState == "open" and not outgoing then error("incoming wormhole", 0) end

        local cost
        glyphs, cost = shortest(glyphs, origin)
        if not glyphs then error("the gate cannot dial that address", 0) end
        if not cost.canOpen then error(("not enough power: %d RF to open"):format(cost.open), 0) end

        -- Keep glyphs already engaged when they start this address; otherwise start over.
        local from, dialed = 1, dialedGlyphs(stargate)
        if gateState == "open" then
            stargate.disengageGate()
        elseif #dialed > 0 then
            local prefix = #dialed <= #glyphs
            for i = 1, #dialed do prefix = prefix and dialed[i] == glyphs[i] end
            if prefix then from = #dialed + 1 else stargate.abortDialing() end
        end

        dialer.target = glyphs
        local fast = opts.fast and dhd ~= nil and own ~= "UN"
        local avoid = settings.kawoosh ~= false and hasIris()
        local i, phase, openedAt, closedIris = from, "glyphs", nil, false
        note("dialing")
        local function finish(text)
            stepTimer = nil
            note(text)
        end
        stepTimer = every(function()
            local status = stargate.getGateStatus()
            if phase == "glyphs" then
                if status ~= "idle" or #dialedGlyphs(stargate) ~= i - 1 then return false end
                if i <= #glyphs then
                    if fast then dhd.pressButton(glyphs[i]) else stargate.engageSymbol(glyphs[i]) end
                    -- The iris shuts while the last glyph locks, so the kawoosh meets it.
                    if i == #glyphs and avoid then closedIris = true irisTo("CLOSED") end
                    i = i + 1
                    return false
                end
                if avoid and not irisTo("CLOSED") then return false end
                local result
                if fast and own == "MW" then
                    result = select(2, dhd.pressBRB())
                else
                    result = stargate.engageGate()
                end
                result = tostring(result)
                if result ~= "stargate_engage" and result ~= "dhd_engage" then
                    if closedIris then irisTo("OPENED") end
                    finish("dial failed: " .. result)
                    return true
                end
                phase = "opening"
                note("engaged")
                return false
            elseif phase == "opening" then
                if status ~= "open" then return false end
                openedAt = openedAt or computer.uptime()
                if closedIris and computer.uptime() - openedAt < KAWOOSH_TICKS / 20 then return false end
                if closedIris and not irisTo("OPENED") then return false end
                finish("open")
                if opts.idc then sendIdc(opts.idc) end
                return true
            end
        end, computer.uptime() + DIAL_TIMEOUT, function()
            if closedIris then irisTo("OPENED") end
            finish("timed out")
        end)

        local seconds = math.floor((stargate.getEnergyStored() - cost.open) / cost.keepAlive / 20)
        return {glyphs = #glyphs, from = from, open = cost.open, keepAlive = cost.keepAlive,
            seconds = seconds, fast = fast}
    end

    -- Stops a dial in progress, or closes an outgoing wormhole. Returns what it did.
    function dialer.close()
        if stepTimer then
            event.cancel(stepTimer)
            stepTimer = nil
        end
        idc = nil
        local gateState, outgoing = stargate.getGateStatus()
        if gateState == "open" then
            if not outgoing then return "incoming wormhole: only the dialing gate can close it" end
            stargate.disengageGate()
            return "closing"
        end
        if #dialedGlyphs(stargate) > 0 then
            stargate.abortDialing()
            irisTo("OPENED")
            return "aborting"
        end
        return "already idle"
    end

    -- The gate now. glyphs: those engaged; target: the address being dialed (or last dialed)
    -- with its point of origin, so a client can draw the chevrons.
    function dialer.status()
        local gateState, outgoing = stargate.getGateStatus()
        local ok, capacity = pcall(stargate.getMaxEnergyStored)
        local typed, irisType = pcall(stargate.getIrisType)
        return {type = stargate.getGateType(), state = gateState, outgoing = outgoing,
            iris = stargate.getIrisState(), irisType = typed and irisType or nil, dialing = stepTimer ~= nil, lastDial = dialer.state,
            energy = stargate.getEnergyStored(), capacity = ok and tonumber(capacity) or nil,
            glyphs = dialedGlyphs(stargate), target = dialer.target,
            tps = math.floor(probe.tps * 10 + 0.5) / 10}
    end

    function dialer.stop()
        if stepTimer then event.cancel(stepTimer) end
        event.cancel(probe.timer)
        for _, l in ipairs(listeners) do event.ignore(l[1], l[2]) end
    end

    return dialer
end

return dialing
