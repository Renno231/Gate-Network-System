-- GNS dialing: drives the JSG stargate for gate.lua. It dials the shortest address the gate
-- accepts, continues a partly dialed address, presses the DHD for fast dials, closes the iris
-- against the kawoosh, sends IDCs and answers them, and guards incoming wormholes. Everything
-- runs from timers and stargate events, so calls return at once.
--
-- Waits are in game time: computer.uptime and timers count server ticks, so lag makes them
-- longer in real time but never shorter in ticks. The TPS probe reports how far the server
-- runs behind real time, so a player waiting knows why (the client shows it).
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
-- The TPS probe's span of game time. 2 s: a DHD dial engages its glyphs in about 5 s, so the
-- figure is there while chevrons still engage, and a tick's rounding (2.5 % in 2 s) stays well
-- inside the gap to the 18 TPS a player is told about. Over a minute, the figure would average
-- an idle stretch instead of the server now.
local SPAN_MIN, SPAN_MAX = 2, 60

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
-- modification time gives. Measured only when asked (a status built for a client or the room
-- display, a dial starting), against the measurement before: nothing runs while the gate idles.
-- read() returns the figure, or nil until two measurements SPAN_MIN..SPAN_MAX apart give one.
-- A span across a server restart counts the time the server was down, so the first figure after
-- one reads low; the next span is right again.
local function tpsProbe()
    local probe, last, at = {}, nil, nil
    function probe.read()
        local up = computer.uptime()
        if last and up - last.uptime < SPAN_MIN then return probe.tps end
        local file = io.open("/tmp/gns-tps", "w")
        if not file then return probe.tps end
        file:write("t")
        file:close()
        local now = {uptime = up, real = fs.lastModified("/tmp/gns-tps")}
        if last and up - last.uptime <= SPAN_MAX and now.real > last.real then
            probe.tps, at = math.min(20, (now.uptime - last.uptime) * 20000 / (now.real - last.real)), up
        end
        last = now
        if at and up - at > SPAN_MAX then probe.tps = nil end
        return probe.tps
    end
    -- A fresh span from now (a dial starting): the figure then covers the dial, not the idle time
    -- before it, when the server may have run at another speed. A span begun under SPAN_MIN ago is kept.
    function probe.start()
        if last and computer.uptime() - last.uptime < SPAN_MIN then return end
        probe.tps, last = nil, nil
        probe.read()
    end
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
    -- job: GNS's own dial under way ({step, timer, deadline}), stepped by the stargate's events.
    local job, listeners, idc = nil, {}, nil
    local handAt = -math.huge -- when a player last pressed a glyph at the DHD (handBusy)
    local adopted -- who dialed the outgoing wormhole open or forming at start (adopt)
    local abortedAt = -math.huge -- when GNS last aborted a dial (ABORT_CLEAR)
    local pressAt = -math.huge -- when a glyph was last pressed at the DHD, by anyone
    local probe = tpsProbe()

    local function note(text)
        dialer.state = text
        dialer.log[#dialer.log + 1] = text
        if #dialer.log > 20 then table.remove(dialer.log, 1) end
    end

    -- The iris type, asked at most once a minute (a player fits or removes an iris rarely).
    local irisType, irisTypeAt = nil, -math.huge
    local function getIrisType()
        if computer.uptime() - irisTypeAt > 60 then
            local ok, t = pcall(stargate.getIrisType)
            irisType, irisTypeAt = ok and tostring(t) or nil, computer.uptime()
        end
        return irisType
    end
    dialer.irisType = getIrisType
    -- The iris's state as a player says it, for an iris or a shield: "Iris shut", "Shield going up".
    local WORDS = {
        iris = {OPENED = "open", CLOSED = "shut", OPENING = "opening", CLOSING = "closing"},
        shield = {OPENED = "down", CLOSED = "up", OPENING = "going down", CLOSING = "going up"},
    }
    function dialer.irisWords(state)
        local shield = getIrisType() == "SHIELD"
        return (shield and "Shield " or "Iris ") .. (WORDS[shield and "shield" or "iris"][state] or tostring(state):lower())
    end
    local function hasIris()
        local t = getIrisType()
        return t ~= nil and t ~= "NULL"
    end
    -- The gate type never changes for a gate's component.
    local gateType
    function dialer.gateType()
        gateType = gateType or stargate.getGateType()
        return gateType
    end
    local shut = false -- GNS shut the iris (irisTo): a closing wormhole opens it again (onClose)

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
            or (now == "CLOSING" and want == "OPENED") then
            local moved = toggleIris()
            if moved then shut = want == "CLOSED" end
            return moved == nil
        end
        return false
    end

    local stopped = false -- dialer.stop: the dialer's timers drop when they next fire
    -- The dialer's news from its own timers (not a stargate event): dialer.on.changed hears it;
    -- moved: the gate's state moved on with no signal of its own (an abort began or ended).
    local function changed(moved)
        if dialer.on.changed then dialer.on.changed(moved) end
    end
    -- Ends the dial under way (job), dropping its timers.
    local function endJob()
        if not job then return end
        if job.timer then event.cancel(job.timer) end
        if job.deadline then event.cancel(job.deadline) end
        job = nil
    end

    local function after(ticks, fn)
        return event.timer(ticks / 20, function() if not stopped then fn() end end)
    end

    -- Outgoing IDC: sent once the wormhole is open, as on GDS. JSG answers every code it takes
    -- (code_respond), so it is sent again only when the far gate asks (onCodeRespond).
    local function sendIdc(code)
        idc = {code = code}
        local function send()
            if not idc or idc.code ~= code then return end
            local sent, why = stargate.sendIrisCode(tostring(code))
            if sent == false then note("IDC not sent: " .. (tostring(why):gsub("_", " "))) idc = nil end
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
    -- stable: the wormhole has formed; letting: the traveller let through, whose iris opens once
    -- it has (both cleared by the next incoming wormhole or the close).
    local admitted, stable, letting
    local function onIncoming(formed)
        dialer.incoming, dialer.openedAt, admitted, stable, letting = true, computer.uptime(), nil, formed, nil
        if hasIris() then irisTo("CLOSED") end
        note("incoming wormhole")
        if job then job.step("incoming") end
        if dialer.on.incoming then dialer.on.incoming() end
    end

    -- Opens the iris for the traveller let through, once the wormhole is stable; the stargate's
    -- events (stable, the iris moving) try again until it is open.
    local function letIn()
        local name = letting
        if not (name and dialer.incoming and stable and irisTo("OPENED")) then return end
        letting = nil
        -- irisTo counts a stuck iris as there: say so instead of "Gate is open!".
        if stargate.getIrisState() ~= "OPENED" then
            local why = dialer.irisProblem or "the iris does not open"
            stargate.sendMessageToIncoming("Iris stuck: " .. why)
            note("iris stuck for " .. name .. ": " .. why)
            return
        end
        stargate.sendMessageToIncoming("Gate is open!")
        note("iris open for " .. name)
    end

    -- Lets a traveller through: the iris opens once the wormhole is open.
    local function admit(name)
        admitted = name
        local log = dialer.travellers
        log[#log + 1] = {time = os.date("%H:%M"), name = name}
        if #log > 10 then table.remove(log, 1) end
        if dialer.on.admitted then dialer.on.admitted(name) end
        if not hasIris() then return end
        letting = name
        letIn()
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

    -- An outgoing wormhole this dialer did not open: a player dialed it by hand on the DHD, or
    -- GNS before the computer restarted (adopted: who dialed it). JSG shows the dialed glyphs
    -- again once the wormhole is stable (not while it is unstable).
    local function onHandDialed()
        local by = adopted
        adopted = nil
        local own = dialing.TYPE[dialer.gateType()] or "MW"
        local glyphs, dialed = {}, dialedGlyphs(stargate)
        for _, glyph in ipairs(dialed) do
            if glyph ~= dialing.ORIGIN[own] then glyphs[#glyphs + 1] = glyph end
        end
        dialer.openedAt, dialer.by, dialer.target = computer.uptime(), by, nil
        local ok, cost = pcall(stargate.getEnergyRequiredToDial, table.unpack(dialed))
        dialer.keepAlive = ok and type(cost) == "table" and cost.keepAlive or nil
        if by then note("open") return end
        note("dialed by hand")
        if #glyphs >= 6 and dialer.on.handDialed then dialer.on.handDialed({[own] = glyphs}) end
    end

    local function onClose()
        dialer.incoming, dialer.openedAt, idc, admitted, adopted, stable, letting = false, nil, nil, nil, nil, nil, nil
        dialer.stableAt = nil
        -- A dial of GNS's own already under way (dialed over this wormhole) keeps its dialer.
        if not job then dialer.by = nil end
        -- Only an iris GNS shut: one an admin shut by hand stays shut.
        if shut and hasIris() and stargate.getIrisState() == "CLOSED" then toggleIris() end
        shut = false
        note("closed")
        if dialer.on.closed then dialer.on.closed() end
    end

    -- A dial of GNS's own under way steps on the stargate's events.
    local function step(name, value)
        if job then job.step(name, value) end
    end
    local function onIris(name)
        step(name)
        letIn()
    end
    for name, handler in pairs({
        -- JSG sends it twice in one tick (StargateAbstractBaseTile.incomingWormhole and after it).
        stargate_incoming_wormhole = function()
            if not (dialer.incoming and computer.uptime() - dialer.openedAt < 1) then onIncoming(false) end
        end,
        received_code = function(_, _, _, code) onCode(code) end,
        code_respond = function(_, _, _, message) onCodeRespond(message) end,
        stargate_close = function(name)
            onClose()
            step(name)
        end,
        -- A glyph pressed at the DHD with no dial of GNS's own: a player is dialing (handBusy).
        stargate_dhd_chevron_engaged = function(name)
            pressAt = computer.uptime()
            if dialer.abortAfterPress then dialer.abortAfterPress() end -- a close waiting on this press's lock
            if job then step(name) else handAt = computer.uptime() end
        end,
        -- Also a Pegasus DHD's press done: an abort it refused goes now (close).
        stargate_spin_chevron_engaged = function(name)
            if dialer.abortWanted then dialer.abortWanted() end
            step(name)
        end,
        stargate_failed = function(name, _, _, reason) step(name, reason) end,
        stargate_iris_opened = onIris,
        stargate_iris_closed = onIris,
        -- The only sign that a far gate stopped dialing here before its wormhole opened.
        stargate_wormhole_closed_fully = function(name)
            if dialer.incoming or dialer.openedAt then onClose() end
            step(name)
        end,
        -- Outgoing: a dial of ours is still stepping, or has finished (openedAt) when the event
        -- comes late. Incoming: GNS started while the wormhole was opening, when JSG reports only
        -- "unstable", which says neither way.
        stargate_wormhole_stabilized = function(name, _, _, initiating)
            if initiating then
                if job then step(name, true) elseif not dialer.openedAt then onHandDialed() end
                return
            end
            if not dialer.incoming then onIncoming(true) end
            stable = true
            letIn()
        end,
    }) do
        listeners[#listeners + 1] = {name, handler}
        event.listen(name, handler)
    end

    -- An outgoing wormhole already open (or forming) when the computer starts: GNS's own dial
    -- from before a restart when by (the device key that dialed it, saved) is given, else dialed
    -- by hand (a player at the DHD woke the computer). Called once the on handlers are set.
    function dialer.adopt(by)
        local gateState, outgoing = stargate.getGateStatus()
        if gateState == "unstable" or (gateState == "open" and outgoing) then adopted = by end
        if gateState == "open" and outgoing and not dialer.openedAt then onHandDialed() end
        -- GNS's own dial, cut off by the restart before it opened: its steps are lost, so stop it.
        if by and not job and (gateState == "dialing" or gateState == "dialing_computer") then
            note("dial stopped: the computer restarted")
            dialer.close()
        end
    end

    -- An incoming wormhole at start, forming (the DHD's redstone woke the computer) or open (the
    -- computer restarted): close the iris until the traveller's gate resends its IDC.
    do
        local gateState, outgoing = stargate.getGateStatus()
        local incoming = gateState == "incoming" or (gateState == "open" and not outgoing)
        if incoming then dialer.incoming, dialer.openedAt, stable = true, computer.uptime(), gateState == "open" end
        if incoming and hasIris() then
            irisTo("CLOSED")
            shut = true -- shut before the restart too: GNS's, opened again once the wormhole closes
        end
        -- The dialing gate hears it (code_respond): its IDC, and a route it relays, go again now.
        if incoming then
            pcall(stargate.sendMessageToIncoming, hasIris() and "Iris closed. Resend IDC." or "Gate computer started. Resend IDC.")
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
        local own = dialing.TYPE[dialer.gateType()] or "MW"
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
    local function openFor(cost, energy)
        return math.max(0, math.floor((energy - cost.open) / math.max(cost.keepAlive, 1) / 20))
    end

    -- What a dial of address would cost, without dialing: {glyphs, open, keepAlive, seconds,
    -- canOpen, energy}.
    function dialer.cost(address)
        local glyphs, cost = plan(address)
        local energy = stargate.getEnergyStored()
        return {glyphs = #glyphs, open = cost.open, keepAlive = cost.keepAlive, canOpen = cost.canOpen == true,
            seconds = openFor(cost, energy), energy = energy}
    end

    -- Dials address {MW = {...}, PG = {...}, UN = {...}}. opts: fast (use the DHD), idc (a
    -- code to send once open), speed (seconds the whole dial takes, spread evenly over the
    -- glyphs and the engage, as on GDS; the DHD is only pressed under 25 s; absent or 0: as fast
    -- as the gate goes). Returns {glyphs, from, open, keepAlive, seconds, fast} or errors.
    -- opts.status: {state, outgoing} the caller just asked the stargate for.
    function dialer.dial(address, opts)
        opts = opts or {}
        if job then
            -- The same gate again (its first six glyphs): the caller can tell it from a dial
            -- elsewhere. No stargate call: a client waiting for the gate asks again and again.
            local given = type(address) == "table" and address[dialing.TYPE[dialer.gateType()] or "MW"]
            local same = type(given) == "table" and dialer.target ~= nil
            for i = 1, 6 do same = same and given[i] == dialer.target[i] end
            error(same and "already dialing it" or "already dialing", 0)
        end
        probe.start() -- the status during the dial has the server's speed during the dial
        local glyphs, cost, own = plan(address)
        local gateState, outgoing
        if opts.status then gateState, outgoing = opts.status[1], opts.status[2]
        else gateState, outgoing = stargate.getGateStatus() end
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
        if not cost.canOpen then
            error(("not enough power: %d RF to open, %d stored, %d RF/t to keep it open"):format(cost.open,
                math.floor(stargate.getEnergyStored()), cost.keepAlive), 0)
        end

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
        local i, closedIris, pressing, pressed, kawooshed = from, false, fast, 0, false
        -- The iris shuts while the glyphs go in, so it is shut when the gate engages: from the
        -- first glyph on a fast dial, else the glyphs before the end that cover its 3 s (a shield's
        -- 1 s), as on GDS.
        local irisFrom = gap == 0 and from
            or math.max(from, #glyphs + 1 - math.ceil((getIrisType() == "SHIELD" and 1 or 3) / gap))
        -- The Milky Way DHD takes no press until the last one has locked, 10 to 14 ticks after it
        -- (25 to 29 for the glyph that locks the address). Each press waits 12 ticks (27 for the
        -- last), when most have locked, then goes in at the first tick the gate takes it: about
        -- 0.2 s a dial slower than trying from 10, for a few refused presses instead of a dozen.
        local lockedAt, irisShut = 0, false
        -- What the dial waits for: "clear" (the wormhole open before it closing), "glyph" (glyph i,
        -- once its gap and an abort's clearing have passed), "lock" (the ring's glyph locking),
        -- "engage" (the iris shut, then the gate engaged), "opening" (the wormhole forming),
        -- "kawoosh" (the iris opening again after it).
        local phase = gateState == "open" and "clear" or "glyph"
        local j = {}
        job = j
        dialer.ring = false -- true once a glyph is engaged by turning the ring, not pressed at the DHD
        note("dialing")
        local function finish(text)
            if job == j then endJob() end
            note(text)
        end
        -- An incoming wormhole shut the iris for itself: it stays shut.
        local function release()
            if closedIris and not dialer.incoming then irisTo("OPENED") end
        end
        local function fail(text)
            release()
            finish(text)
        end
        local step
        -- Steps again after seconds: the dial's own delays (a glyph's gap, the kawoosh).
        local function wait(seconds, name)
            if j.timer then event.cancel(j.timer) end
            j.timer = event.timer(math.max(seconds, 0.05), function()
                j.timer = nil
                if job == j and not stopped then step(name) changed() end
            end)
        end
        local function retry() return wait(math.max(lockedAt - computer.uptime(), 0.05)) end
        -- Runs on the stargate's events (name and its first value) and the dial's own delays:
        -- the gate's state is never asked while it dials.
        step = function(name, value)
            if job ~= j then return end
            if name == "incoming" then return fail("dial failed: incoming wormhole") end
            if name == "stargate_failed" then
                local why = tostring(value or ""):gsub("_", " ")
                return fail("dial failed: " .. (why ~= "" and why or "the gate did not open"))
            end
            if name == "stargate_dhd_chevron_engaged" then
                if pressed > 0 then pressed = pressed - 1 return end
                -- JSG takes a DHD press whenever the gate is idle, as it is between a slow dial's
                -- glyphs: a glyph this dial did not press is a player's, and the dial is lost.
                return fail("dial failed: a glyph was pressed at the DHD")
            end
            if phase == "clear" then
                if name ~= "stargate_wormhole_closed_fully" then return end
                phase = "glyph"
            elseif phase == "lock" then
                -- The ring's glyph and the Pegasus DHD's signal once the gate is idle again.
                if name ~= "stargate_spin_chevron_engaged" then return end
                if j.timer then event.cancel(j.timer) j.timer = nil end
                phase = "glyph"
            end
            if phase == "glyph" then
                local ready = math.max(nextAt, abortedAt + ABORT_CLEAR)
                if computer.uptime() < ready then return wait(ready - computer.uptime()) end
                if i <= #glyphs then
                    if avoid and not closedIris and i >= irisFrom then closedIris = true irisTo("CLOSED") end
                    -- A DHD without the chevron upgrade locks the 7th symbol it takes as the last
                    -- one, and then the gate takes no more: on a longer address the DHD presses
                    -- the first 6 and the ring engages the rest.
                    local byDhd
                    if pressing and (#glyphs <= 7 or i <= 6) then
                        local _, code = dhd.pressButton(glyphs[i])
                        if code == "dhd_failure_busy" then return retry() end
                        byDhd = code == "dhd_pressed"
                        if byDhd then pressed = pressed + 1 end
                    end
                    if not byDhd then
                        pressing, dialer.ring = false, true
                        local spun, code, message = stargate.engageSymbol(glyphs[i])
                        if code == "stargate_failure_busy" then return wait(0.25) end
                        if not spun then return fail("dial failed: " .. plain(message or code)) end
                    end
                    nextAt, phase = computer.uptime() + gap, "lock"
                    i = i + 1
                    -- The Milky Way DHD's chevron locks with no signal (StargateMilkyWayBaseTile).
                    if byDhd and own == "MW" then
                        phase, lockedAt = "glyph", computer.uptime() + (i > #glyphs and 1.35 or 0.6)
                        wait(math.max(gap, lockedAt - computer.uptime()))
                    end
                    return
                end
                phase = "engage"
            end
            if phase == "engage" then
                if avoid and not irisShut then
                    closedIris = true
                    irisShut = irisTo("CLOSED")
                    if not irisShut then return end -- stargate_iris_closed steps again
                end
                local engaged, why, busy
                if pressing and own == "MW" then
                    local _, code, message = dhd.pressBRB()
                    engaged, why, busy = code == "dhd_engage", message or code, code == "dhd_failure_busy"
                else
                    local result, code, message, reason = stargate.engageGate()
                    engaged, why, busy = result == "stargate_engage", message or code, code == "stargate_failure_busy"
                    if reason then why = why .. ": " .. tostring(reason):lower():gsub("_", " ") end
                end
                if busy then return retry() end
                if not engaged then return fail("dial failed: " .. plain(why)) end
                phase = "opening"
                note("engaged")
                return
            end
            if name == "stargate_close" or name == "stargate_wormhole_closed_fully" then
                return fail("dial failed: the wormhole closed")
            end
            if phase == "opening" then
                if name ~= "stargate_wormhole_stabilized" or not value then return end
                phase, dialer.stableAt = "kawoosh", computer.uptime()
                if closedIris then return wait(KAWOOSH_TICKS / 20, "kawoosh") end
            end
            if name == "kawoosh" then kawooshed = true end
            -- stargate_iris_opened steps again while the iris opens.
            if closedIris and not (kawooshed and irisTo("OPENED")) then return end
            finish("open")
            dialer.openedAt, dialer.keepAlive = computer.uptime(), cost.keepAlive
            if opts.idc then sendIdc(opts.idc) end
        end
        j.step = step
        j.deadline = event.timer(DIAL_TIMEOUT + speed, function()
            if job ~= j or stopped then return end
            local engaged = phase == "opening" or phase == "kawoosh"
            fail("timed out")
            -- A ring that stopped mid-glyph (its chunk unloaded, say) leaves JSG dialing for good.
            if not engaged then dialer.close() end
            changed()
        end)
        step()

        return {glyphs = #glyphs, from = from, open = cost.open, keepAlive = cost.keepAlive,
            seconds = openFor(cost, stargate.getEnergyStored()), fast = fast}
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
        local gateState, outgoing = stargate.getGateStatus()
        if gateState == "unstable" then return "the wormhole is opening or closing: try again in 3 s" end
        endJob()
        idc = nil
        if gateState == "open" then
            if not outgoing then return "incoming wormhole: only the dialing gate can close it" end
            stargate.disengageGate()
            return "closing"
        end
        -- The ring spinning to the first glyph engages it only once it stops: abort that too.
        if #dialedGlyphs(stargate) > 0 or gateState == "dialing_computer" then
            -- JSG aborts only while idle or dialing by computer (StargateClassicBaseTile.abortDialing):
            -- not while a DHD press locks a chevron, so then once it has. Failing, JSG clears the
            -- glyphs itself.
            local retry
            local function abort()
                if retry then event.cancel(retry) retry = nil end
                if not (job or stopped) -- a new dial began: its glyphs are not to abort
                    and select(2, stargate.abortDialing()) ~= "stargate_aborting" then return false end
                dialer.abortWanted, dialer.abortAfterPress = nil, nil
                if job or stopped then return true end
                abortedAt = computer.uptime()
                -- Only an iris GNS shut: one an admin shut by hand stays shut.
                if shut and not dialer.incoming then irisTo("OPENED") end
                changed(true)
                after(ABORT_CLEAR * 20 + 2, function() changed(true) end) -- failing ends, with no signal
                return true
            end
            -- A refused abort always waits for the lock: the lock can end between JSG's refusal and
            -- any look at the gate's state, and a close that then waited for nothing was lost.
            if not abort() then
                -- A Pegasus DHD's press ends with stargate_spin_chevron_engaged; a Milky Way one's
                -- chevron locks 10 to 29 ticks after the press, with no signal: the abort goes
                -- 1.5 s after the last press, and a press whose signal comes in later moves it.
                dialer.abortWanted = abort
                if (dialing.TYPE[dialer.gateType()] or "MW") == "MW" then
                    dialer.abortAfterPress = function()
                        if retry then event.cancel(retry) end
                        retry = after(math.max(1, (pressAt + 1.5 - computer.uptime()) * 20), abort)
                    end
                    dialer.abortAfterPress()
                end
            end
            return "aborting"
        end
        return "already idle"
    end

    -- The gate now. glyphs: those engaged; target: the address being dialed (or last dialed)
    -- with its point of origin, so a client can draw the chevrons.
    -- A player dialing at the DHD: glyphs engaged with no dial of GNS's own, one pressed in the
    -- last minute (JSG says idle between presses, and a dial here would abort or join theirs).
    -- Glyphs left engaged longer than that count as abandoned.
    -- Also returns when the last press stops counting.
    function dialer.handBusy()
        return not job and computer.uptime() - handAt <= 60 and #dialedGlyphs(stargate) > 0, handAt + 60
    end

    -- GNS's own dial is going on: no stargate call, unlike status (five, a tick each).
    function dialer.busy() return job ~= nil end

    -- The server's TPS to a tenth, or nil while the probe has no span yet: file calls only.
    function dialer.tps() return probe.read() and math.floor(probe.tps * 10 + 0.5) / 10 end

    -- The status s brought up to date: the stargate is asked only for what need names (state,
    -- glyphs, iris, energy; a call each) or, with no s, all of it. The dialer's own part costs no call.
    local capacity, capacityAt = nil, -math.huge
    function dialer.status(s, need)
        local all = s == nil
        s, need = s or {}, need or {}
        if all or need.state then s.state, s.outgoing = stargate.getGateStatus() end
        if all or need.energy then
            s.energy = stargate.getEnergyStored()
            -- The capacity changes only with the gate's capacitors: asked at most once a minute.
            if computer.uptime() - capacityAt > 60 then
                local ok, c = pcall(stargate.getMaxEnergyStored)
                capacity, capacityAt = ok and tonumber(c) or nil, computer.uptime()
            end
        end
        if all or need.iris then s.iris, s.irisType = stargate.getIrisState(), getIrisType() end
        if all or need.glyphs then s.glyphs = dialedGlyphs(stargate) end
        -- JSG empties the dialed address while the wormhole forms: every chevron stays locked.
        if job and dialer.state == "engaged" and #(s.glyphs or {}) == 0 then s.glyphs = dialer.target end
        -- open: seconds the wormhole has been open; left: how long an outgoing one can stay open.
        s.open, s.left = nil, nil
        if s.state == "open" and dialer.openedAt then
            s.open = math.floor(computer.uptime() - dialer.openedAt)
            if s.outgoing and dialer.keepAlive then s.left = math.floor((s.energy or 0) / math.max(dialer.keepAlive, 1) / 20) end
        end
        s.type, s.irisProblem, s.dialing, s.lastDial = dialer.gateType(), dialer.irisProblem, job ~= nil, dialer.state
        -- The ring turns only while GNS engages glyphs with it: a DHD press (a fast dial under
        -- 25 s, or a player at the DHD) locks chevrons with the ring still.
        s.spinning = job ~= nil and dialer.ring or nil
        s.capacity, s.target, s.tps = capacity, dialer.target, dialer.tps()
        return s
    end

    -- Works the iris by hand (the iris RPC, the gate console): want "OPENED", "CLOSED" or nil
    -- for the other way. Returns the iris state (OPENING or CLOSING once it moves) and the state
    -- before, or errors with why it does not move.
    function dialer.iris(want)
        if not hasIris() then error("this gate has no iris", 0) end
        local now = stargate.getIrisState()
        want = want or (now == "CLOSED" and "OPENED" or "CLOSED")
        if now == want then return now, now end
        if now ~= "OPENED" and now ~= "CLOSED" then error("the iris is moving: " .. tostring(now), 0) end
        local moved = toggleIris()
        if moved then shut = false end
        if moved == false then error("the iris is busy", 0) end
        if moved == nil then error(dialer.irisProblem, 0) end
        return want == "OPENED" and "OPENING" or "CLOSING", now
    end

    function dialer.stop()
        stopped = true
        endJob()
        for _, l in ipairs(listeners) do event.ignore(l[1], l[2]) end
    end

    return dialer
end

return dialing
