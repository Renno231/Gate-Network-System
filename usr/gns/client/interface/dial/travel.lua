-- Dial's travel features, loaded when used (dial.lua's part): GDO through an open wormhole, dial-back,
-- routes and scheduled dials, and the home gate. Returns its functions.
local api = ...
local gns = api.gns
local clientEnv = api.clientEnv
local log = api.log
local say = api.say
local guard = api.guard
local row = api.row
local galaxyOf = api.galaxyOf
local database = api.database
local onChange = api.onChange
local connections = api.connections
local link = api.link
local findConnection = api.findConnection
local openGate = api.openGate
local fresh = api.fresh
local identity = api.identity
local grantsFor = api.grantsFor
local disengage = api.disengage
local vaultState = api.vaultState
local nearest = api.nearest
local dialWhenFree = api.dialWhenFree
local isAdmin = api.isAdmin
local waiting = api.waiting
local sameSix = clientEnv.sameSix
local route = dofile(gns.path.gns .. "route.lua")

-- The book row of the gate c's wormhole reaches, from c's own status: its dial's target (whoever
-- dialed it), or the glyphs a hand dial engaged. A gate the book lacks: a row of just those
-- glyphs, with no IDC (not the book's). A status naming no glyphs: the chosen row.
-- The book row of the gate c's wormhole reaches. The book may hold a gate twice (imported, then
-- scanned): of its rows, prefer (else the chosen row) wins.
local function reachedRow(c, prefer)
    local s = c.status or {}
    local glyphs = type(s.target) == "table" and #s.target > 0 and s.target or s.glyphs
    if type(glyphs) ~= "table" or #glyphs < 6 then return row() end
    local galaxy, chosen, first = galaxyOf(c), prefer or row(), nil
    for _, r in ipairs(database) do
        local same = sameSix(r, galaxy, glyphs)
        if same and r == chosen then return r end
        if same then first = first or r end
    end
    return first or clientEnv.setAddress({IDCs = {}}, glyphs, galaxy)
end

local function waitOpen(c, done, want)
    local stop, mine
    local function check()
        local s = c.status or {}
        local open = s.state == "open" and s.outgoing and not s.dialing and (not want or reachedRow(c, want) == want)
        -- The gate took this device's dial (doDial follows it) and is dialing it. The gate answers
        -- a dial before it sends the change.
        mine = mine or (s.dialing and c.follow ~= nil and not c.follow.closing)
        if open or (mine and not s.dialing) then
            stop()
            waiting[stop] = nil
            done(open)
        end
    end
    stop = onChange(c, 300 + 120 + (clientEnv.settings.dialSpeed or 0) + 10, check, function()
        waiting[stop] = nil
        done(false)
    end)
    waiting[stop] = true
    check()
end

-- Whether gate connection x is the gate of row r: by its key, else (a row added by hand) by the
-- address x publishes, the first six glyphs of a galaxy both have. nil when neither tells.
local function isRow(x, r)
    if not r then return nil end
    if r.key then return x.key == r.key end
    local own = x.entry and x.entry.address
    if type(own) ~= "table" or not (r.MW or r.PG or r.UN) then return nil end
    for _, kind in ipairs({"MW", "PG", "UN"}) do
        if sameSix(r, kind, own[kind]) then return true end
    end
    return false
end

-- The gate at the far end of c's open outgoing wormhole (OC modem messages cross it): r's gate
-- (by key or published address), else the gate with an incoming wormhole. A gate a scan already
-- opened through the wormhole counts too. Calls done(connection) as soon as r's gate answers and
-- opens, or done(nil, why).
local function reachFar(c, r, done)
    for _, x in ipairs(connections) do
        if x ~= c and isRow(x, r) then return done(x) end
    end
    local waiting, best, why, finished, seen = 1, nil, "no GNS gate answers through the wormhole", false, {}
    local function finish(x)
        if finished then return end
        if x then finished = true return done(x) end
        waiting = waiting - 1
        if waiting > 0 then return end
        finished = true
        if best then done(best) else done(nil, why) end
    end
    link.hello(clientEnv.ports(), 2, guard(function(address, port, _, hello)
        if finished or seen[address] or address == c.address or findConnection(address) then return end
        seen[address], waiting = true, waiting + 1
        openGate(address, port, guard(function(x, reason)
            if not x then why = tostring(hello.name or address:sub(1, 8)) .. ": " .. tostring(reason) return finish() end
            local s = x.status or {}
            local named = isRow(x, r)
            if named then return finish(x) end
            if named == nil and s.state == "open" and not s.outgoing then best = best or x end
            finish()
        end))
    end), guard(function() finish() end))
end

-- The IDC a gate row sends for the player pressing: theirs, else the row's first; or nil.
local idcOf = clientEnv.idcFor
local function rowOf(c)
    for _, r in ipairs(database) do if c.key and r.key == c.key then return r end end
end

-- GDO: through c's open outgoing wormhole, a signed pass to a GNS gate that knows this device,
-- else a numeric IDC (code, or the destination's first one).
local function gdo(c, code)
    if not c then return "No gate in range." end
    -- The gate as it is now: a wormhole dialed at its DHD, or since this device last used it.
    fresh(c, function()
        local s = c.status or {}
        if not (s.state == "open" and s.outgoing) then log(c.name .. " has no open outgoing wormhole.") return end
        local r = reachedRow(c) -- the gate the wormhole reaches, not the row chosen since
        local function numeric(why)
            local idc = code or idcOf(r)
            if not idc then log("GDO: " .. (why or "no IDC for " .. (r and r.Name or "the far gate"))) return end
            c.proxy:async(guard(function(ok, result)
                log(ok == true and ("GDO: IDC sent to " .. tostring(r and r.Name or "the far gate") .. ".") or ("GDO refused: " .. tostring(result)))
                -- The far gate's answer comes back to c as its dial state: follow it to the log.
                if ok == true then c.follow = {last = "open", idc = idc} end -- the gate sends its changes
            end)).sendIdc(idc)
        end
        if code then return numeric() end
        reachFar(c, r, function(far)
            if not far then return numeric() end
            -- The far gate's open proved this device's key from its modem: the pass is one message.
            far.proxy:async(guard(function(passed, result)
                if passed == true then log("GDO: " .. far.name .. " took your signed pass; its iris opens.") return end
                log(far.name .. ": pass refused: " .. tostring(result))
                numeric()
            end)).pass()
        end)
    end)
    return code and "GDO: sending IDC..." or "GDO: sending your pass..."
end

-- Dial-back: once c's outgoing wormhole is open, the far gate is handed a signed route back to
-- c (with c's IDC) to dial after delay seconds, and c's side is closed so it is free.
local function dialBack(c, delay, want)
    if not c then return "No gate in range." end
    local own = c.entry and c.entry.address
    if not own then return c.name .. " has not published its address." end
    local back = rowOf(c)
    waitOpen(c, function(open)
        if not open then log("Dial-back: the wormhole from " .. c.name .. " did not open.") return end
        reachFar(c, reachedRow(c, want), function(far, why)
            if not far then log("Dial-back: " .. tostring(why)) return end
            local r = route.sign(identity, {{address = own, idc = idcOf(back), delay = delay}}, 0, grantsFor(far.owner, far.key))
            -- The far gate holds the route until it is free, so this side closes at once, without
            -- waiting for its answer: that answer crosses the wormhole and can be lost.
            far.proxy:async(guard(function(ok, result)
                if ok ~= true and not tostring(result):find("^Timeout") then
                    log(far.name .. ": dial-back refused: " .. tostring(result))
                end
            end)).queue(r, 1)
            log(("Asked %s to dial %s back in %d s; closing this side."):format(far.name, c.name, delay))
            disengage(c)
        end)
    end, want)
    return ("Dial-back to %s once the wormhole is open..."):format(c.name)
end

-- The grants for every gate of a route: c's and those of the gate each later hop starts from,
-- each gate's best first, taken in turn, since a gate reads at most 16.
local function routeGrants(c, rows)
    local lists = {grantsFor(c.owner, c.key)}
    for i = 1, #rows - 1 do
        local key = type(rows[i].key) == "string" and #rows[i].key == 22 and rows[i].key or nil
        local a = key and vaultState.access[key]
        lists[#lists + 1] = grantsFor(a and a.owner, key)
    end
    local out, seen = {}, {}
    for n = 1, 16 do
        for _, list in ipairs(lists) do
            local g = list[n]
            if g and not seen[g] and #out < 16 then seen[g] = true out[#out + 1] = g end
        end
    end
    return out
end

-- Hands c a signed route: it dials rows[1], the gate there dials rows[2] once free, and so on.
-- every > 0 repeats it (a scheduled dial, admins only).
local function sendRoute(c, rows, every)
    if not c then return "No gate in range." end
    local hops = {}
    -- Each later hop names the gate that carries it out when its key is known (a row signed by
    -- its gate): relaying gates hand the route only to it. The first needs none: c proved its key.
    for i, r in ipairs(rows) do
        local by = i > 1 and rows[i - 1].key or nil
        hops[i] = {address = clientEnv.address(r), idc = idcOf(r), delay = 0, gate = type(by) == "string" and #by == 22 and by or nil}
    end
    if #hops == 0 or #hops > route.MAX_HOPS then return "A route has 1 to " .. route.MAX_HOPS .. " gates." end
    local signed = route.sign(identity, hops, every or 0, routeGrants(c, rows))
    c.proxy:async(guard(function(ok, result)
        if ok ~= true then log(c.name .. ": route refused: " .. tostring(result)) return end
        log(("%s: route %s (%d hop%s)."):format(c.name, tostring(result), #hops, #hops == 1 and "" or "s"))
        if not every or every == 0 then c.follow = {last = "dialing", start = true} end -- the gate sends its changes
    end)).queue(signed, 1)
    return ("Sending %s a route of %d hop%s..."):format(c.name, #hops, #hops == 1 and "" or "s")
end

return {gdo = gdo, dialBack = dialBack, waitOpen = waitOpen,
    gdoCommand = function(args)
    return gdo(clientEnv.fromGate(), math.tointeger(tonumber(args[1])))
    end,
    back = function(args)
    return dialBack(clientEnv.fromGate(), math.tointeger(tonumber(args[1])) or 5)
    end,
    route = function(args)
    local rows = {}
    for _, a in ipairs(args) do
        local r = clientEnv.findEntry(a)
        if not r then return "No gate " .. a .. " in the address book." end
        rows[#rows + 1] = r
    end
    return sendRoute(clientEnv.fromGate(), rows)
    end,
    home = function(args)
    local word = (args[1] or ""):lower()
    if word == "set" then
        local r = clientEnv.findEntry(args[2])
        if not r then return "No gate " .. tostring(args[2]) .. " in the address book." end
        clientEnv.setHome(r)
        return r.Name .. " is the home gate."
    elseif word == "none" then
        clientEnv.setHome(nil)
        return "No home gate."
    end
    local home
    for _, r in ipairs(database) do if r.home then home = r end end
    if not home then return "No home gate: home set <gate>, or HOME on Gates." end
    local c = nearest(home)
    local said = dialWhenFree(c, home) -- a busy gate: it waits, as DIAL does
    if not c then return said end
    if word == "back" then
        dialBack(c, math.tointeger(tonumber(args[2])) or 5, home)
    elseif not idcOf(home) and home.key then
        waitOpen(c, function(open) if open then say(gdo(c)) end end, home)
    end
    return said
    end,
    schedule = function(args)
    local c = clientEnv.fromGate()
    if not c then return "No gate in range." end
    local minutes = math.tointeger(tonumber(args[1]))
    if minutes and args[2] then
        local r = clientEnv.findEntry(args[2])
        if not r then return "No gate " .. args[2] .. " in the address book." end
        if minutes < 1 then return "At least every minute." end
        return sendRoute(c, {r}, minutes * 60)
    end
    if not isAdmin(c) then return c.name .. ": scheduled dials need the admin role." end
    api.part("admin").remote(c, "schedule " .. table.concat(args, " "), function(text) log("  " .. c.name .. ": " .. text) end)
    end}
