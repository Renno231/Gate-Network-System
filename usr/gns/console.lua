-- The gate console: the commands typed at the gate computer (only its OC users, the owner and
-- admins, can type there). Admins run the same commands from a client (gate.lua console, the
-- client's ssh), so a gate nobody sits at can still be set up and looked after.
local component = require("component")
local computer = require("computer")
local fingerprint = dofile("/usr/gns/vault.lua").fingerprint
local sides = require("sides")

local console = {}

-- node: from gate.start; settings and save(): the gate's settings and how to keep them; dhd:
-- the DHD or nil; stargate: the gate. Returns run(line, out, role): runs one command line, writing
-- each line of its output with out(text). role: the caller's, for a command sent from a client
-- (gate.lua console); nil at the gate computer, where only its OC users type.
function console.new(node, settings, saveSettings, dhd, stargate)
    local state = node.state
    local unsaved -- why the last settings save in this command failed
    local function save()
        local ok, why = saveSettings()
        if not ok then unsaved = why or "the disk is full" end
    end
    local LEVELS = {anyone = "anyone", users = "user", admins = "admin", owner = "owner"}
    local SAID = {anyone = "anyone", user = "users", admin = "admins", owner = "owner"}
    local function level(control)
        local v = type(settings.allow) == "table" and settings.allow[control]
        return SAID[v] and v or "user"
    end
    local function ownerLine()
        if state.owner == nil then return "Not registered: the first client to set it up becomes its owner." end
        if state.owner == "public" then return "Public: nobody owns it or can claim it; anyone may use it." end
        return ("Owner %s (%s); dial: %s, close: %s, iris: %s%s"):format(tostring(state.ownerName), fingerprint(state.owner),
            SAID[level("dial")], SAID[level("close")], SAID[level("iris")], settings.silent and "; silent" or "")
    end
    local function onOff(word) if word == "on" then return true elseif word == "off" then return false end end

    local commands = {}
    local usage = {
        {"status", "gate state, owner and access"},
        {"name <name>", "rename the gate (its entry is signed again)"},
        {"dim <number>", "the dimension published in the gate's entry"},
        {"close", "stop dialing or close the outgoing wormhole"},
        {"iris [open|close]", "open or close the iris (alone: the other way)"},
        {"log", "recent dialing, iris, IDC and route events"},
        {"history [n]", "the gate log: who did what here, newest first (500 kept)"},
        {"idc", "list the IDCs that open the iris for incoming travellers"},
        {"idc add <code> <name>", "let an IDC open the iris; idc remove <code>"},
        {"kawoosh on|off", "close the iris while the wormhole forms"},
        {"allow [dial|close|iris] [anyone|users|admins|owner]", "who may use each control (users: anyone with access; the default)"},
        {"silent on|off", "answer only the owner and players with access: strangers' scans and calls get nothing"},
        {"owner public", "give the gate to the public (the owner only): nobody owns it or can claim it"},
        {"local on|off", "take commands only from the client on this computer; travellers still pass"},
        {"port <number>", "the modem port of this gate's network (restart gns after)"},
        {"sleep <minutes>|off", "shut down when idle; the wake key or the DHD wakes it"},
        {"wake new", "a new wake key: grant holders get it when they next open the gate"},
        {"redstone <level>|off", "the redstone level that wakes the gate (DHD signal)"},
        {"alarm <side>|all|off", "redstone out on an off-world activation"},
        {"schedule", "scheduled dials; schedule remove <n>"},
        {"users", "the OC users of this computer (the owner and admins)"},
        {"cut", "how many grants this gate has cut off"},
    }
    function commands.help(_, out)
        for _, u in ipairs(usage) do
            if #u[1] > 22 then out(u[1]) out((" "):rep(23) .. u[2]) else out(("%-22s %s"):format(u[1], u[2])) end
        end
    end
    function commands.status(_, out)
        local s = node.dialer.status()
        out(("%s, %s, %s, last dial: %s"):format(settings.name, s.state, node.dialer.irisWords(s.iris):lower(), s.lastDial))
        if s.irisProblem then out(s.irisProblem) end
        -- The gate measures the server's speed only when asked: an idle gate's first status starts it.
        out(("Server %s, DHD %s, kawoosh avoidance %s"):format(s.tps and (("%.1f"):format(s.tps):gsub("%.0$", "") .. " TPS") or "TPS measuring (status again in 5 s)",
            dhd and "connected" or "none", settings.kawoosh and "on" or "off"))
        out(ownerLine() .. (settings.localOnly and "; commands only from this computer" or ""))
        out(("Port %d, wake key %s, sleep %s"):format(settings.port or 160, state.wake and "set" or "none",
            (tonumber(settings.sleep) or 0) > 0 and (settings.sleep .. " min") or "off"))
        local line = "Off-world alarm " .. (node.view().alarm and "ON" or "off")
        if component.isAvailable("redstone") then
            local rs, side = component.redstone, settings.alarm
            local out1 = side == "all" and 0 or (math.tointeger(sides[side]) or math.tointeger(side))
            line = line .. (", redstone wake level %d"):format(rs.getWakeThreshold())
            if out1 then line = line .. (", redstone out %s = %d"):format(tostring(side), rs.getOutput(out1)) end
        end
        out(line)
    end
    function commands.name(name, out)
        if name == "" then out("Name: " .. settings.name) return end
        -- The signed entry holds 1 to 32 bytes; a longer name saved would stop gns at every start.
        if #name > 32 then out("A gate name is at most 32 bytes.") return end
        settings.name = name
        save()
        node.publish()
        out("Renamed to " .. name)
    end
    function commands.dim(argument, out)
        local dim = math.tointeger(tonumber(argument))
        if argument == "" then out("Dimension " .. tostring(settings.dim)) return end
        if not dim or dim < -0x80000000 or dim > 0x7FFFFFFF then out("Usage: dim <number>") return end
        settings.dim = dim
        save()
        node.publish()
        out("Dimension " .. dim)
    end
    function commands.close(_, out) out(tostring(node.dialer.close())) end
    function commands.log(_, out)
        for _, line in ipairs(node.dialer.log) do out(line) end
    end
    function commands.history(argument, out)
        local entries = node.history(math.tointeger(tonumber(argument)) or 20)
        for _, e in ipairs(entries) do out(("%s  %s"):format(e[1], e[2])) end
        if #entries == 0 then out("Nothing logged yet.") end
    end
    function commands.idc(argument, out)
        local action, code, name = argument:match("^(%S*)%s*(%S*)%s*(.-)%s*$")
        code = math.tointeger(tonumber(code))
        if action == "add" and code and name ~= "" then
            settings.idcs[code] = name
        elseif action == "remove" and code then
            settings.idcs[code] = nil
        elseif action ~= "" then
            out("Usage: idc | idc add <code> <name> | idc remove <code>")
            return
        end
        if action ~= "" then save() end
        local count = 0
        for c, n in pairs(settings.idcs) do
            count = count + 1
            out(("%-10d %s"):format(c, n))
        end
        out(count .. " IDCs")
    end
    function commands.iris(argument, out)
        local want = ({open = "OPENED", close = "CLOSED"})[argument]
        if argument ~= "" and not want then
            out("Usage: iris [open|close] (now " .. tostring(stargate.getIrisState()) .. ")")
            return
        end
        local ok, now = pcall(node.dialer.iris, want)
        out(ok and node.dialer.irisWords(now) or tostring(now))
    end
    function commands.kawoosh(argument, out)
        local on = onOff(argument)
        if on == nil then out("Usage: kawoosh on|off (now " .. (settings.kawoosh and "on" or "off") .. ")") return end
        settings.kawoosh = on
        save()
        out("Kawoosh avoidance " .. argument)
    end
    local function ownedGate(out)
        if state.owner == nil or state.owner == "public" then
            out("Only an owned gate has these settings: on this one anyone may use every control.")
            return false
        end
        return true
    end
    function commands.allow(argument, out)
        local control, who = argument:match("^(%S*)%s*(%S*)$")
        if control == "" then
            for _, c in ipairs({"dial", "close", "iris"}) do out(("%-6s %s"):format(c, SAID[level(c)])) end
            return
        end
        if not ({dial = true, close = true, iris = true})[control] or not LEVELS[who] then
            out("Usage: allow [dial|close|iris] [anyone|users|admins|owner]")
            return
        end
        if not ownedGate(out) then return end
        settings.allow = type(settings.allow) == "table" and settings.allow or {}
        settings.allow[control] = LEVELS[who] ~= "user" and LEVELS[who] or nil
        if not next(settings.allow) then settings.allow = nil end
        save()
        out(("%s: %s"):format(control, who))
    end
    function commands.silent(argument, out)
        local on = onOff(argument)
        if on == nil then out("Usage: silent on|off (now " .. (settings.silent and "on" or "off") .. ")") return end
        if not ownedGate(out) then return end
        settings.silent = on or nil
        save()
        out(on and "Silent: only the owner and players with access get an answer." or "The gate answers every scan.")
    end
    function commands.owner(argument, out, role)
        if argument ~= "public" then out(ownerLine()) out("owner public: give the gate to the public") return end
        if role and role ~= "owner" then out("Only the owner can give the gate to the public.") return end
        node.release(role and "the owner" or "the gate console")
        out("The gate is public now: nobody owns it or can claim it, and anyone may use it.")
    end
    commands["local"] = function(argument, out)
        local on = onOff(argument)
        if on == nil then out("Usage: local on|off (now " .. (settings.localOnly and "on" or "off") .. ")") return end
        settings.localOnly = on or nil
        save()
        out(on and "Only the client on this computer controls the gate; travellers still pass."
            or "Every device the gate's access allows controls it.")
    end
    function commands.port(argument, out)
        local port = math.tointeger(tonumber(argument))
        if not port or port < 1 or port > 65535 then out("Usage: port <1-65535> (now " .. (settings.port or 160) .. ")") return end
        settings.port = port
        save()
        out("Port " .. port .. ". Restart gns to serve on it; clients choose the same port in Settings.")
    end
    function commands.sleep(argument, out)
        local minutes = argument == "off" and 0 or math.tointeger(tonumber(argument))
        if not minutes or minutes < 0 then out("Usage: sleep <minutes>|off") return end
        settings.sleep = minutes
        save()
        if minutes == 0 then out("The gate stays on.") return end
        out(("The gate sleeps after %d idle minutes%s."):format(minutes, state.wake and "" or " once it has a wake key (registration makes one)"))
    end
    function commands.wake(argument, out)
        if argument ~= "new" then out("Usage: wake new (a wake key is " .. (state.wake and "set" or "not set") .. ")") return end
        node.newWake()
        out("New wake key. Grant holders get it when they next open the gate.")
    end
    function commands.redstone(argument, out)
        local level = argument == "off" and 0 or math.tointeger(tonumber(argument))
        if not level or level < 0 or level > 15 then out("Usage: redstone <1-15>|off") return end
        settings.redstoneWake = level == 0 and false or level
        save()
        node.applyWake()
        out(level == 0 and "Redstone does not wake the gate." or ("Redstone level " .. level .. " wakes the gate."))
    end
    function commands.alarm(argument, out)
        if argument == "off" then settings.alarm = nil
        elseif argument == "all" or math.tointeger(sides[argument])
            or (math.tointeger(tonumber(argument)) and tonumber(argument) >= 0 and tonumber(argument) <= 5) then
            settings.alarm = math.tointeger(tonumber(argument)) or argument
        else
            out("Usage: alarm bottom|top|back|front|right|left|0-5|all|off (now " .. tostring(settings.alarm or "off") .. ")")
            return
        end
        save()
        out("Alarm redstone: " .. tostring(settings.alarm or "off"))
    end
    function commands.schedule(argument, out)
        local n = math.tointeger(tonumber(argument:match("^remove%s+(%d+)$")))
        if n then
            if not state.schedules[n] then out("No scheduled dial " .. n) return end
            table.remove(state.schedules, n)
            node.save()
            out("Removed scheduled dial " .. n)
            return
        end
        for i, s in ipairs(state.schedules) do
            local hops = #s.route.hops
            out(("%d. every %d min, %d hop%s, by %s"):format(i, s.every // 60, hops, hops == 1 and "" or "s", fingerprint(s.route.key):sub(1, 13)))
        end
        out(#state.schedules .. " scheduled dials")
    end
    function commands.users(_, out)
        local list = {computer.users()}
        out(#list == 0 and "No users: anyone can use this computer." or table.concat(list, ", "))
    end
    function commands.cut(_, out)
        local count = 0
        for _ in pairs(state.cut) do count = count + 1 end
        out(count .. " grants cut off")
    end

    return function(line, out, role)
        local name, argument = tostring(line):match("^%s*(%S+)%s*(.-)%s*$")
        if not name then return end
        local command = commands[name]
        if not command then
            out("Unknown command " .. name .. "; type help.")
            return
        end
        unsaved = nil
        local ok, err = pcall(command, argument, out, role)
        if not ok then out("Error: " .. tostring(err)) end
        if unsaved then out("Not saved: " .. tostring(unsaved) .. "; the change is lost on restart.") end
    end
end

return console
