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
-- JSG's abort clears the glyphs at once and again later (its STARGATE_FAIL task: 53 ticks from
-- idle, 83 while the ring dials): a glyph engaged in between is lost.
local ABORT_CLEAR = 4.2
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
-- dialer.on.incoming(), on.admitted(name) and on.closed(), when set, are told of an incoming
-- wormhole, a traveller let through the iris, and the wormhole closing; on.handDialed(address)
-- of an outgoing wormhole the gate did not dial (a player at the DHD), with its address
-- {[type] = glyphs, without the point of origin}. travellers lists the last ten {time, name}.
function dialing.new(stargate, dhd, settings)
    local dialer = {state = "idle", log = {}, on = {}, travellers = {}}
    local stepTimer, listeners, idc = nil, {}, nil
    local handAt = -math.huge -- when a player last pressed a glyph at the DHD (handBusy)
    local abortedAt = -math.huge -- when GNS last aborted a dial (ABORT_CLEAR)
    local probe = tpsProbe()

    local function note(text)
        dialer.state = text
        dialer.log[#dialer.log + 1] = text
        if #dialer.log > 20 then table.remove(dialer.log, 1) end
    end

    local function hasIris()
        return tostring(stargate.getIrisType()) ~= "NULL"
    end

    -- Toggles the iris. JSG refuses unless the iris mode (set in the gate's screen) is OC: then,
    -- or when a shield lacks power, dialer.irisProblem says why and the iris counts as stuck.
    -- Returns true when it moves, false when it is busy, nil when it is stuck.
    local function toggleIris()
        local ok, code, message = stargate.toggleIris()
        if ok then dialer.irisProblem = nil return true end
        if code == "stargate_iris_busy" then return false end
        local problem = code == "stargate_iris_error_mode" and "Iris mode is not OC: set it to OC in the gate's screen"
            or plain(message or code)
        if dialer.irisProblem ~= problem then note(problem) end
        dialer.irisProblem = problem
    end

    -- Moves the iris toward want ("OPENED" or "CLOSED"); true once it is there, there is none,
    -- or it cannot be moved (dialer.irisProblem).
    local function irisTo(want)
        if not hasIris() then return true end
        local now = stargate.getIrisState()
        if now == want then return true end
        -- JSG turns a moving iris back too (StargateClassicBaseTile.toggleIris).
        if now == "OPENED" or now == "CLOSED" or (now == "OPENING" and want == "CLOSED")
            or (now == "CLOSING" and want == "OPENED") then return toggleIris() == nil end
        return false
    end

    -- Runs step every tick until it returns true or deadline passes (then onTimeout).
    local stopped = false -- dialer.stop: the dialer's timers drop when they next fire
    local function every(step, deadline, onTimeout)
        local id
        id = event.timer(0.05, function()
            if stopped then return false end
            if computer.uptime() >= deadline then
                if onTimeout then onTimeout() end
                return false
            end
            if step() then return false end
        end, math.huge)
        return id
    end

    local function after(ticks, fn)
        return event.timer(ticks / 20, function() if not stopped then fn() end end)
    end

    -- Outgoing IDC: send the code once the wormhole is open; resend when the far gate asks or
    -- does not answer within 3 s.
    local function sendIdc(code)
        idc = {code = code, tries = 0}
        local function send()
            if not idc or idc.code ~= code then return end
            if idc.tries >= IDC_TRIES then note("IDC: no answer") idc = nil return end
            idc.tries = idc.tries + 1
            stargate.sendIrisCode(tostring(code))
            local try = idc.tries
            after(60, function()
                if idc and idc.code == code and idc.tries == try and not idc.waiting then send() end
            end)
        end
        idc.send = send
        send()
    end

    -- JSG answers "Waiting on computer..." at once when the far gate's iris is worked by a
    -- computer; the far computer's own answer follows (for GNS, once its iris is open).
    local function onCodeRespond(message)
        if not idc then return end
        message = plain(message)
        if message:match("^Waiting") then
            if not idc.waiting then
                idc.waiting = true
                local current = idc
                after(600, function() if idc == current then note("IDC: no answer") idc = nil end end)
            end
            return
        end
        if message:match("Resend IDC") or message == "Iris is busy!" then
            idc.waiting = nil
            after(20, idc.send)
            return
        end
        note("IDC: " .. message)
        idc = nil
    end

    -- Incoming wormholes: the iris closes; a known IDC or a signed pass opens it again.
    local admitted
    local function onIncoming()
        dialer.incoming, dialer.openedAt, admitted = true, computer.uptime(), nil
        if hasIris() then irisTo("CLOSED") end
        note("incoming wormhole")
        if dialer.on.incoming then dialer.on.incoming() end
    end

    -- Lets a traveller through: the iris opens once the wormhole is open.
    local function admit(name)
        admitted = name
        local log = dialer.travellers
        log[#log + 1] = {time = os.date("%H:%M"), name = name}
        if #log > 10 then table.remove(log, 1) end
        if dialer.on.admitted then dialer.on.admitted(name) end
        if not hasIris() then return end
        local wormhole = dialer.openedAt -- this wormhole only: not one that comes in after it
        every(function()
            if not dialer.incoming or dialer.openedAt ~= wormhole then return true end
            if stargate.getGateStatus() ~= "open" or not irisTo("OPENED") then return false end
            -- irisTo counts a stuck iris as there: say so instead of "Gate is open!".
            if stargate.getIrisState() ~= "OPENED" then
                local why = dialer.irisProblem or "the iris does not open"
                stargate.sendMessageToIncoming("Iris stuck: " .. why)
                note("iris stuck for " .. name .. ": " .. why)
                return true
            end
            stargate.sendMessageToIncoming("Gate is open!")
            note("iris open for " .. name)
            return true
        end, computer.uptime() + 30)
    end

    -- A signed pass was accepted (gate.lua checks it): the same as a known IDC.
    function dialer.admit(name)
        if not dialer.incoming then error("no incoming wormhole", 0) end
        note("pass from " .. name)
        admit(name)
        return true
    end

    -- JSG lets any gate whose last dial was this one send a code, with or without a wormhole,
    -- so only codes during an incoming wormhole count, and a wrong one does not shut an iris
    -- already opened for this wormhole's traveller.
    local function onCode(code)
        if not dialer.incoming then return end
        code = math.floor(tonumber(code) or -1)
        local name = (settings.idcs or {})[code]
        if not hasIris() then
            stargate.sendMessageToIncoming("Gate is open!")
            if name then note("IDC from " .. name) admit(name) end
            return
        end
        if not name then
            stargate.sendMessageToIncoming("Invalid IDC.")
            if not admitted then irisTo("CLOSED") end
            note("refused IDC " .. code)
            return
        end
        note("IDC from " .. name)
        admit(name)
    end

    -- An outgoing wormhole this dialer did not open: a player dialed it by hand on the DHD. JSG
    -- shows the dialed glyphs again once the wormhole is stable (not while it is unstable).
    local function onHandDialed()
        local own = dialing.TYPE[stargate.getGateType()] or "MW"
        local glyphs = {}
        for _, glyph in ipairs(dialedGlyphs(stargate)) do
            if glyph ~= dialing.ORIGIN[own] then glyphs[#glyphs + 1] = glyph end
        end
        dialer.openedAt, dialer.by, dialer.target = computer.uptime(), nil, nil
        local ok, cost = pcall(stargate.getEnergyRequiredToDial, table.unpack(dialedGlyphs(stargate)))
        dialer.keepAlive = ok and type(cost) == "table" and cost.keepAlive or nil
        note("dialed by hand")
        if #glyphs >= 6 and dialer.on.handDialed then dialer.on.handDialed({[own] = glyphs}) end
    end

    local function onClose()
        dialer.incoming, dialer.openedAt, idc, admitted = false, nil, nil, nil
        -- A dial of GNS's own already under way (dialed over this wormhole) keeps its dialer.
        if not stepTimer then dialer.by = nil end
        if hasIris() and stargate.getIrisState() == "CLOSED" then toggleIris() end
        note("closed")
        if dialer.on.closed then dialer.on.closed() end
    end

    for name, handler in pairs({
        -- JSG sends it twice in one tick (StargateAbstractBaseTile.incomingWormhole and after it).
        stargate_incoming_wormhole = function()
            if not (dialer.incoming and computer.uptime() - dialer.openedAt < 1) then onIncoming() end
        end,
        received_code = function(_, _, _, code) onCode(code) end,
        code_respond = function(_, _, _, message) onCodeRespond(message) end,
        stargate_close = function() onClose() end,
        -- A glyph pressed at the DHD with no dial of GNS's own: a player is dialing (handBusy).
        stargate_dhd_chevron_engaged = function()
            if not stepTimer then handAt = computer.uptime() end
        end,
        -- The only sign that a far gate stopped dialing here before its wormhole opened.
        stargate_wormhole_closed_fully = function()
            if dialer.incoming or dialer.openedAt then onClose() end
        end,
        -- Outgoing: a dial of ours is still stepping, or has finished (openedAt) when the event
        -- comes late. Incoming: GNS started while the wormhole was opening, when JSG reports only
        -- "unstable", which says neither way.
        stargate_wormhole_stabilized = function(_, _, _, initiating)
            if initiating and not stepTimer and not dialer.openedAt then onHandDialed() end
            if not initiating and not dialer.incoming then onIncoming() end
        end,
    }) do
        listeners[#listeners + 1] = {name, handler}
        event.listen(name, handler)
    end

    -- An outgoing wormhole already open when the server starts (a player at the DHD woke the
    -- computer): dialed by hand. Called once the on handlers are set.
    function dialer.adopt()
        local gateState, outgoing = stargate.getGateStatus()
        if gateState == "open" and outgoing and not dialer.openedAt then onHandDialed() end
    end

    -- An incoming wormhole at start, forming (the DHD's redstone woke the computer) or open (the
    -- computer restarted): close the iris until the traveller's gate resends its IDC.
    do
        local gateState, outgoing = stargate.getGateStatus()
        local incoming = gateState == "incoming" or (gateState == "open" and not outgoing)
        if incoming then dialer.incoming, dialer.openedAt = true, computer.uptime() end
        if incoming and hasIris() then
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

    -- The glyphs this gate dials for address {MW = {...}, PG = {...}, UN = {...}}, with its
    -- point of origin, and their energy cost. Errors when the gate cannot dial it.
    local function plan(address)
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
        local cost
        glyphs, cost = shortest(glyphs, origin)
        if not glyphs then error("the gate cannot dial that address", 0) end
        return glyphs, cost, own
    end

    -- How long a wormhole can stay open on stored energy after paying open, in seconds.
    local function openFor(cost)
        return math.max(0, math.floor((stargate.getEnergyStored() - cost.open) / math.max(cost.keepAlive, 1) / 20))
    end

    -- What a dial of address would cost, without dialing: {glyphs, open, keepAlive, seconds,
    -- canOpen, energy}.
    function dialer.cost(address)
        local glyphs, cost = plan(address)
        return {glyphs = #glyphs, open = cost.open, keepAlive = cost.keepAlive, canOpen = cost.canOpen == true,
            seconds = openFor(cost), energy = stargate.getEnergyStored()}
    end

    -- Dials address {MW = {...}, PG = {...}, UN = {...}}. opts: fast (use the DHD), idc (a
    -- code to send once open), speed (seconds the whole dial takes, spread evenly over the
    -- glyphs and the engage, as on GDS; the DHD is only pressed under 25 s; absent or 0: as fast
    -- as the gate goes). Returns {glyphs, from, open, keepAlive, seconds, fast} or errors.
    function dialer.dial(address, opts)
        opts = opts or {}
        local glyphs, cost, own = plan(address)
        if stepTimer then
            -- The same address again: the caller can tell it from a dial elsewhere.
            local same = dialer.target and #dialer.target == #glyphs
            for i = 1, #glyphs do same = same and dialer.target[i] == glyphs[i] end
            error(same and "already dialing it" or "already dialing", 0)
        end
        local gateState, outgoing = stargate.getGateStatus()
        if gateState == "incoming" or (gateState == "open" and not outgoing) or dialer.incoming then
            error("incoming wormhole", 0)
        end
        -- Its own wormhole to that address is open (GNS's dial, or a hand dial): dialing it again
        -- would close it and pay twice.
        -- The first six glyphs name the gate: a hand dial may use more glyphs than GNS's shortest.
        if gateState == "open" then
            local open = dialer.target or dialedGlyphs(stargate)
            local same = #open >= 7 and #glyphs >= 7
            for i = 1, 6 do same = same and open[i] == glyphs[i] end
            if same then error("already open to it", 0) end
        end
        -- Closing, failing, or a chevron locking: the gate is busy until it is idle again.
        if gateState ~= "idle" and gateState ~= "open" then error("already dialing", 0) end
        if not cost.canOpen then error(("not enough power: %d RF to open"):format(cost.open), 0) end

        -- Keep glyphs already engaged when they start this address; otherwise start over.
        local from, dialed = 1, dialedGlyphs(stargate)
        if gateState == "open" then
            stargate.disengageGate()
        elseif #dialed > 0 then
            -- A player's glyphs that start this address are kept (they may finish it here); if they
            -- press on, the dial step sees a glyph it did not engage and stops.
            local prefix = #dialed <= #glyphs
            for i = 1, #dialed do prefix = prefix and dialed[i] == glyphs[i] end
            if prefix then from = #dialed + 1
            elseif dialer.handBusy() then error("already dialing", 0)
            else stargate.abortDialing() abortedAt = computer.uptime() end
        end

        dialer.target = glyphs
        local speed = math.max(0, math.min(tonumber(opts.speed) or 0, DIAL_TIMEOUT))
        local fast = opts.fast and dhd ~= nil and own ~= "UN" and speed < 25
        local gap, nextAt = speed / #glyphs, 0
        local avoid = settings.kawoosh ~= false and hasIris()
        local i, phase, openedAt, closedIris, pressing = from, "glyphs", nil, false, fast
        note("dialing")
        local function finish(text)
            stepTimer = nil
            note(text)
        end
        -- An incoming wormhole shut the iris for itself: it stays shut.
        local function release()
            if closedIris and not dialer.incoming then irisTo("OPENED") end
        end
        stepTimer = every(function()
            if dialer.incoming then
                finish("dial failed: incoming wormhole")
                return true
            end
            local status = stargate.getGateStatus()
            if phase == "glyphs" then
                if status ~= "idle" then return false end
                -- JSG takes a DHD press whenever the gate is idle, as it is between a slow dial's
                -- glyphs: a glyph more than this dial engaged is a player's, and the dial is lost.
                local n = #dialedGlyphs(stargate)
                if n > i - 1 then
                    release()
                    finish("dial failed: a glyph was pressed at the DHD")
                    return true
                end
                if n ~= i - 1 then return false end
                if computer.uptime() < math.max(nextAt, abortedAt + ABORT_CLEAR) then return false end
                if i <= #glyphs then
                    nextAt = computer.uptime() + gap
                    -- A DHD without the chevron upgrade locks the 7th symbol it takes as the last
                    -- one, and then the gate takes no more: on a longer address the DHD presses
                    -- the first 6 and the ring engages the rest.
                    if not (pressing and (#glyphs <= 7 or i <= 6) and select(2, dhd.pressButton(glyphs[i])) == "dhd_pressed") then
                        pressing = false
                        local spun, code, message = stargate.engageSymbol(glyphs[i])
                        if not spun then
                            release()
                            finish("dial failed: " .. plain(message or code))
                            return true
                        end
                    end
                    -- The iris shuts while the last glyph locks, so the kawoosh meets it.
                    if i == #glyphs and avoid then closedIris = true irisTo("CLOSED") end
                    i = i + 1
                    return false
                end
                if avoid then
                    closedIris = true
                    if not irisTo("CLOSED") then return false end
                end
                local engaged, why
                if pressing and own == "MW" then
                    local _, code, message = dhd.pressBRB()
                    engaged, why = code == "dhd_engage", message or code
                else
                    local result, code, message, reason = stargate.engageGate()
                    engaged, why = result == "stargate_engage", message or code
                    if reason then why = why .. ": " .. tostring(reason):lower():gsub("_", " ") end
                end
                if not engaged then
                    release()
                    finish("dial failed: " .. plain(why))
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
                dialer.openedAt, dialer.keepAlive = computer.uptime(), cost.keepAlive
                if opts.idc then sendIdc(opts.idc) end
                return true
            end
        end, computer.uptime() + DIAL_TIMEOUT + speed, function()
            release()
            finish("timed out")
        end)

        return {glyphs = #glyphs, from = from, open = cost.open, keepAlive = cost.keepAlive,
            seconds = openFor(cost), fast = fast}
    end

    -- The GDO: sends code through this gate's open outgoing wormhole to the far gate's iris.
    function dialer.sendCode(code)
        local gateState, outgoing = stargate.getGateStatus()
        if gateState ~= "open" or not outgoing then error("no outgoing wormhole", 0) end
        -- The far gate's answer replaces this, so a client following the dial sees it even
        -- when it repeats the last answer.
        dialer.state = "open"
        sendIdc(code)
        return true
    end

    -- Stops a dial in progress, or closes an outgoing wormhole. Returns what it did.
    function dialer.close()
        if stargate.getGateStatus() == "unstable" then return "the wormhole is opening or closing: try again in 3 s" end
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
        -- The ring spinning to the first glyph engages it only once it stops: abort that too.
        if #dialedGlyphs(stargate) > 0 or gateState == "dialing_computer" then
            -- JSG aborts only while idle or dialing by computer, not while a DHD press locks a
            -- chevron: keep trying for a few seconds.
            local function abort()
                if stepTimer then return true end -- a new dial began: its glyphs are not to abort
                if select(2, stargate.abortDialing()) ~= "stargate_aborting" then return false end
                abortedAt = computer.uptime()
                if not dialer.incoming then irisTo("OPENED") end
                return true
            end
            if not abort() then every(abort, computer.uptime() + 5) end
            return "aborting"
        end
        return "already idle"
    end

    -- The gate now. glyphs: those engaged; target: the address being dialed (or last dialed)
    -- with its point of origin, so a client can draw the chevrons.
    -- A player dialing at the DHD: glyphs engaged with no dial of GNS's own, one pressed in the
    -- last minute (JSG says idle between presses, and a dial here would abort or join theirs).
    -- Glyphs left engaged longer than that count as abandoned.
    function dialer.handBusy()
        return not stepTimer and #dialedGlyphs(stargate) > 0 and computer.uptime() - handAt <= 60
    end

    function dialer.status()
        local gateState, outgoing = stargate.getGateStatus()
        local ok, capacity = pcall(stargate.getMaxEnergyStored)
        local typed, irisType = pcall(stargate.getIrisType)
        -- open: seconds the wormhole has been open; left: how long an outgoing one can stay open.
        local open, left = nil, nil
        if gateState == "open" and dialer.openedAt then
            open = math.floor(computer.uptime() - dialer.openedAt)
            if outgoing and dialer.keepAlive then left = math.floor(stargate.getEnergyStored() / math.max(dialer.keepAlive, 1) / 20) end
        end
        return {type = stargate.getGateType(), state = gateState, outgoing = outgoing,
            iris = stargate.getIrisState(), irisType = typed and irisType or nil, irisProblem = dialer.irisProblem, dialing = stepTimer ~= nil, lastDial = dialer.state,
            energy = stargate.getEnergyStored(), capacity = ok and tonumber(capacity) or nil,
            glyphs = dialedGlyphs(stargate), target = dialer.target, open = open, left = left,
            tps = math.floor(probe.tps * 10 + 0.5) / 10}
    end

    -- Works the iris by hand (the iris RPC, the gate console): want "OPENED", "CLOSED" or nil
    -- for the other way. Returns the iris state, or errors with why it does not move.
    function dialer.iris(want)
        if not hasIris() then error("this gate has no iris", 0) end
        local now = stargate.getIrisState()
        want = want or (now == "CLOSED" and "OPENED" or "CLOSED")
        if now == want then return now end
        if now ~= "OPENED" and now ~= "CLOSED" then error("the iris is moving: " .. tostring(now), 0) end
        local moved = toggleIris()
        if moved == false then error("the iris is busy", 0) end
        if moved == nil then error(dialer.irisProblem, 0) end
        return stargate.getIrisState()
    end

    function dialer.stop()
        stopped = true
        if stepTimer then event.cancel(stepTimer) end
        event.cancel(probe.timer)
        for _, l in ipairs(listeners) do event.ignore(l[1], l[2]) end
    end

    return dialer
end

return dialing
