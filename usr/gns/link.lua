-- GNS link: gate commands as single modem messages, as GDS sent them; no connection to keep.
--   a call         "gnsc", id, method, args       (args serialized)
--   its answer     "gnsr", id, ok, results        to the caller's modem, on the call's port
--   a gate status  "gnss", seq, status            to the devices watching the gate (gate.lua)
-- Each call and hello is sent once, as on GDS: OC delivers a modem message in range. The caller
-- waits up to WAIT seconds (game time, so lag stretches it) for the answer: measured with several
-- clients per gate and the server at 1.2 to 20 TPS, the slowest call (open, its handshake) took
-- 21 ticks, so WAIT leaves room for a server CPU about 3 times slower, and a gate
-- that is gone shows as one in WAIT seconds. The gate keeps each answer KEEP seconds, so a call
-- that reaches it twice (by two modems) is answered twice and run once.
-- OC sets every message's sender address, so a gate knows the caller by its modem: gate.lua keeps
-- what each modem proved with the gate.open handshake and answers "call open first" to one it
-- does not know (a gate that restarted); a proxy given reopen opens it again and calls once more.
-- hello is a broadcast every gate on the port answers at once, so a scan lists each as it answers.
local component = require("component")
local computer = require("computer")
local event = require("event")
local serialization = require("serialization")

local link = {CALL = "gnsc", REPLY = "gnsr", STATUS = "gnss", WAIT = 3, KEEP = 30}
-- Calls the gate answers over tnet instead: their arguments or answers outgrow a modem message.
local BIG = {update = true, console = true, gatelog = true}

function link.pack(...) return serialization.serialize(table.pack(...)) end
function link.unpack(text)
    if type(text) ~= "string" then return nil end
    local ok, t = pcall(serialization.unserialize, text)
    if ok and type(t) == "table" then return t end
end

local waiting, nextId = {}, math.random(0, 0xffffff)
local function newId()
    nextId = nextId + 1
    return ("%s%x"):format(computer.address():sub(1, 4), nextId)
end

-- Sends from card (an address) as the card would, checking for a local peer first: OC never
-- hands a card a message sent to its own address, so one to this card, on a port open on it,
-- is pushed as the modem_message signal the card would raise (as tnet does). So a gate and a
-- client on one computer reach each other; each knows the other is local by its own card's
-- address. A broadcast reaches the card itself the same way.
local function here(card, port, ...)
    if component.invoke(card, "isOpen", port) then computer.pushSignal("modem_message", card, card, port, 0, ...) end
end
function link.send(card, to, port, ...)
    if to ~= card then return component.invoke(card, "send", to, port, ...) end
    here(card, port, ...)
    return true
end
function link.broadcast(card, port, ...)
    here(card, port, ...)
    return component.invoke(card, "broadcast", port, ...)
end

-- onStatus(gateModem, status): the gates' status messages (the client sets it).
link.onStatus = nil
local function onMessage(_, _, from, port, distance, kind, id, ok, payload)
    if kind == link.REPLY then
        local w = waiting[id]
        if not w then return end
        local t = link.unpack(payload) or table.pack("bad answer")
        if w.many then
            if ok == true and type(t[1]) == "table" then w.many(from, port, distance, t[1]) end
            return
        end
        if w.address ~= from then return end
        waiting[id] = nil
        event.cancel(w.timer)
        w.callback(ok == true, table.unpack(t, 1, t.n))
    elseif kind == link.STATUS and link.onStatus then
        local t = link.unpack(ok)
        if t and type(t[1]) == "table" then link.onStatus(from, t[1]) end
    end
end
event.listen("modem_message", onMessage)

-- A wait's time is up when its timer fires, but the OS runs an expired timer with whatever signal
-- it pulls next: a computer busy past the deadline (a big redraw on a lagging server) would drop
-- answers that came in time and wait in its queue. So the timer only pushes END; it is pulled
-- after every answer queued before it, and the wait ends then.
local END = "gns_link_end"
local function onEnd(_, id)
    local w = waiting[id]
    if not w then return end
    waiting[id] = nil
    if w.many then
        if w.done then w.done() end
    else
        w.callback(false, "Timeout calling remote function: " .. w.method)
    end
end
event.listen(END, onEnd)
local function expire(id) return function() computer.pushSignal(END, id) end end

function link.stop()
    event.ignore("modem_message", onMessage)
    event.ignore(END, onEnd)
    for id, w in pairs(waiting) do event.cancel(w.timer) waiting[id] = nil end
end

-- Calls method on the gate at address: callback(ok, ...) with its answer, or (false, "Timeout
-- calling remote function: method") when none came within WAIT seconds.
function link.call(address, port, method, callback, ...)
    local id, text = newId(), link.pack(...)
    local sent, err = pcall(link.send, component.modem.address, address, port, link.CALL, id, method, text)
    if not sent then return callback(false, tostring(err)) end
    local w = {address = address, callback = callback, method = method}
    w.timer = event.timer(link.WAIT, expire(id))
    waiting[id] = w
end

-- Asks every gate on ports ({[port] = true}) to say who it is: answer(modem, port, distance,
-- {name, key}) for each answer as it comes (a gate may answer more than once), then done()
-- after seconds. One broadcast from each modem, on each port.
function link.hello(ports, seconds, answer, done)
    local id, text = newId(), link.pack()
    local w = {many = answer, done = done}
    w.timer = event.timer(seconds, expire(id))
    waiting[id] = w
    for address in component.list("modem") do
        for port in pairs(ports) do pcall(link.broadcast, address, port, link.CALL, id, "hello", text) end
    end
end

-- A stand-in for an api proxy: proxy:async(callback).method(...) makes the call; close does
-- nothing. reopen(done) opens the gate again (done(true) once it is open), for a gate that
-- answers "call open first". bucket (tnet.bucket): the caller's, for calls that go over tnet.
function link.proxy(address, port, reopen, bucket)
    local proxy = {address = address, port = port, connected = true}
    local function call(method, callback, args, again)
        local function answered(ok, ...)
            if not ok and not again and reopen and (...) == "call open first" then
                return reopen(function(open)
                    if open then return call(method, callback, args, true) end
                    callback(false, "call open first")
                end)
            end
            callback(ok, ...)
        end
        if not BIG[method] then return link.call(address, port, method, answered, table.unpack(args, 1, args.n)) end
        -- Over tnet: the gate knows this modem from its link open, so no handshake is needed.
        local api = require("api")
        api.connectAsync("gns", port, address, function(tnet, err)
            if not tnet then return answered(false, err) end
            tnet:async(function(...)
                tnet:close()
                answered(...)
            end)[method](table.unpack(args, 1, args.n))
        end, nil, 3, nil, nil, bucket)
    end
    function proxy:async(callback)
        return setmetatable({}, {__index = function(_, method)
            return function(...) call(method, callback, table.pack(...)) end
        end})
    end
    function proxy:close() end
    -- handshake.lua binds its proof to both modems.
    function proxy:getConnection() return {modem = component.modem, address = address} end
    return proxy
end

return link
