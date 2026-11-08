-- The gate console: the commands the gate's owner types at the gate computer. A network admin
-- runs the same commands from a client (gate.lua console, the client's ssh), so a gate nobody
-- sits at can still be set up and looked after.
local fingerprint = dofile("/usr/gns/vault.lua").fingerprint

local console = {}

-- node: from gate.start; settings and save(): the gate's settings and how to keep them; dhd:
-- the DHD or nil; stargate: the gate. Returns run(line, out): runs one command line, writing
-- each line of its output with out(text).
function console.new(node, settings, save, dhd, stargate)
    local state = node.state
    local function networkName()
        return state.net and ("private, founder " .. fingerprint(state.net.network.founder)) or "public"
    end

    local commands = {}
    local usage = {
        {"status", "gate state and network"},
        {"book", "the gates in this gate's address book"},
        {"sync <modem>", "pull the address book (and network state) of another gate"},
        {"trust <fingerprint>", "let this gate join the network founded by that key"},
        {"name <name>", "rename the gate (its entry is signed again)"},
        {"dim <number>", "the dimension published in the gate's entry"},
        {"close", "stop dialing or close the outgoing wormhole"},
        {"iris [open|close]", "open or close the iris (alone: the other way)"},
        {"log", "recent dialing, iris and IDC events"},
        {"idc", "list the IDCs that open the iris for incoming travellers"},
        {"idc add <code> <name>", "let an IDC open the iris; idc remove <code>"},
        {"kawoosh on|off", "close the iris while the wormhole forms"},
    }
    function commands.help(_, out)
        for _, u in ipairs(usage) do out(("%-22s %s"):format(u[1], u[2])) end
    end
    function commands.status(_, out)
        local s = node.dialer.status()
        out(("%s, %s, iris %s, last dial: %s"):format(settings.name, s.state, tostring(s.iris), s.lastDial))
        out(("Server %.1f TPS, DHD %s, kawoosh avoidance %s"):format(s.tps, dhd and "connected" or "none", settings.kawoosh and "on" or "off"))
        out("Network: " .. networkName())
        if state.trust then out("Trusts founder " .. state.trust) end
    end
    function commands.book(_, out)
        local count = 0
        for _, e in pairs(state.book) do
            count = count + 1
            out(("%-16s %s seq %-3d %s%s"):format(e.name, e.type, e.seq, fingerprint(e.key), e.network and " (private)" or ""))
        end
        out(count .. " gates")
    end
    function commands.sync(modem, out)
        if modem == "" then out("Usage: sync <modem address>") return end
        local taken, refused = node.sync(modem)
        if not taken then
            out("Sync failed: " .. tostring(refused))
            return
        end
        out(("Synced from %s: %d new, %d refused"):format(modem:sub(1, 8), taken, #refused))
        for _, r in ipairs(refused) do out("Refused " .. tostring(r[1] and r[1].name) .. ": " .. r[2]) end
    end
    function commands.trust(founder, out)
        if not founder:match("^GNS%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x$") then
            out("Usage: trust GNS-xxxx-xxxx-xxxx-xxxx")
            return
        end
        node.trust(founder)
        out("Trusting founder " .. founder)
    end
    function commands.name(name, out)
        if name == "" then out("Name: " .. settings.name) return end
        settings.name = name
        save()
        node.publish()
        out("Renamed to " .. name)
    end
    function commands.dim(argument, out)
        local dim = math.tointeger(tonumber(argument))
        if argument == "" then out("Dimension " .. tostring(settings.dim)) return end
        if not dim then out("Usage: dim <number>") return end
        settings.dim = dim
        save()
        node.publish()
        out("Dimension " .. dim)
    end
    function commands.close(_, out) out(tostring(node.dialer.close())) end
    function commands.log(_, out)
        for _, line in ipairs(node.dialer.log) do out(line) end
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
        local typed, kind = pcall(stargate.getIrisType)
        if typed and kind == "NULL" then out("This gate has no iris.") return end
        local now = stargate.getIrisState()
        local want = ({open = "OPENED", close = "CLOSED"})[argument]
        if argument == "" then want = now == "CLOSED" and "OPENED" or "CLOSED" end
        if not want then out("Usage: iris [open|close] (now " .. tostring(now) .. ")") return end
        if now == want then out("Iris " .. now) return end
        if now ~= "OPENED" and now ~= "CLOSED" then out("The iris is moving: " .. tostring(now)) return end
        stargate.toggleIris()
        out("Iris " .. tostring(stargate.getIrisState()))
    end
    function commands.kawoosh(argument, out)
        if argument ~= "on" and argument ~= "off" then
            out("Usage: kawoosh on|off (now " .. (settings.kawoosh and "on" or "off") .. ")")
            return
        end
        settings.kawoosh = argument == "on"
        save()
        out("Kawoosh avoidance " .. argument)
    end

    return function(line, out)
        local name, argument = tostring(line):match("^%s*(%S+)%s*(.-)%s*$")
        if not name then return end
        local command = commands[name]
        if not command then
            out("Unknown command " .. name .. "; type help.")
            return
        end
        local ok, err = pcall(command, argument, out)
        if not ok then out("Error: " .. tostring(err)) end
    end
end

return console
