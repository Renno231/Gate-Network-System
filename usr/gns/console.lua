-- The gate console: the commands typed at the gate computer (only its OC users, the owner and
-- admins, can type there). Admins run the same commands from a client (gate.lua console, the
-- client's ssh), so a gate nobody sits at can still be set up and looked after.
local component = require("component")
local computer = require("computer")
local fingerprint = dofile("/usr/gns/vault.lua").fingerprint
local sides = require("sides")

local console = {}

-- node: from gate.start; settings and save(): the gate's settings and how to keep them; dhd:
-- the DHD or nil; stargate: the gate. Returns run(line, out): runs one command line, writing
-- each line of its output with out(text).
function console.new(node, settings, saveSettings, dhd, stargate)
    local state = node.state
    local unsaved -- why the last settings save in this command failed
    local function save()
        local ok, why = saveSettings()
        if not ok then unsaved = why or "the disk is full" end
    end
    local function ownerLine()
        if not state.owner then return "Not registered: the first client to set it up becomes its owner." end
        return ("Owner %s (%s), %s"):format(tostring(state.ownerName), fingerprint(state.owner),
            settings.public and "public: anyone may dial" or "private: the owner and grant holders")
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
        {"public on|off", "let anyone dial; the iris stays the owner's and grant holders' (a registered gate is private otherwise)"},
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
        for _, u in ipairs(usage) do out(("%-22s %s"):format(u[1], u[2])) end
    end
    function commands.status(_, out)
        local s = node.dialer.status()
        out(("%s, %s, iris %s, last dial: %s"):format(settings.name, s.state, tostring(s.iris), s.lastDial))
        if s.irisProblem then out(s.irisProblem) end
        out(("Server %.1f TPS, DHD %s, kawoosh avoidance %s"):format(s.tps, dhd and "connected" or "none", settings.kawoosh and "on" or "off"))
        out(ownerLine())
        out(("Port %d, wake key %s, sleep %s"):format(settings.port or 160, state.wake and "set" or "none",
            (tonumber(settings.sleep) or 0) > 0 and (settings.sleep .. " min") or "off"))
        local line = "Off-world alarm " .. (node.status().alarm and "ON" or "off")
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
        out(ok and ("Iris " .. tostring(now)) or tostring(now))
    end
    function commands.kawoosh(argument, out)
        local on = onOff(argument)
        if on == nil then out("Usage: kawoosh on|off (now " .. (settings.kawoosh and "on" or "off") .. ")") return end
        settings.kawoosh = on
        save()
        out("Kawoosh avoidance " .. argument)
    end
    commands.public = function(argument, out)
        local on = onOff(argument)
        if on == nil then out("Usage: public on|off (now " .. (settings.public and "on" or "off") .. ")") return end
        settings.public = on
        save()
        out(on and "Public: anyone in range may dial." or "Private: only the owner and grant holders.")
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

    return function(line, out)
        local name, argument = tostring(line):match("^%s*(%S+)%s*(.-)%s*$")
        if not name then return end
        local command = commands[name]
        if not command then
            out("Unknown command " .. name .. "; type help.")
            return
        end
        unsaved = nil
        local ok, err = pcall(command, argument, out)
        if not ok then out("Error: " .. tostring(err)) end
        if unsaved then out("Not saved: " .. tostring(unsaved) .. "; the change is lost on restart.") end
    end
end

return console
