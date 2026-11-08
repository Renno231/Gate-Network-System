-- GNS invitations: how a membership gets from an admin's device to a new member's device.
-- The admin hosts an invitation (announced on disco as gns-invite). A member asks to join with
-- its public key and a name; the admin sees the request and accepts it with a role or denies
-- it. The member polls until it is decided and checks what it receives before keeping it.
local api = require("api")
local computer = require("computer")
local disco = require("disco")
local event = require("event")
local networks = dofile("/usr/gns/networks.lua")

local invite = {ENDPOINT = "gns-invite", PORT = 161, MAX_PENDING = 16}

-- Admin side. net = the vault's {name, network, revoked, membership}. onRequest(request) is
-- called for each new request {address, key, name}. Returns a host with accept(request, grant),
-- deny(request) and stop().
function invite.host(net, onRequest)
    local requests, count = {}, 0
    local lib = {
        request = function(key, name)
            local address = api.caller().address
            if type(key) ~= "string" or #key ~= 22 then error("bad key", 0) end
            if type(name) ~= "string" or #name == 0 or #name > 24 then error("bad name", 0) end
            if not requests[address] then
                if count >= invite.MAX_PENDING then error("too many requests", 0) end
                count = count + 1
            end
            local request = {address = address, key = key, name = name, state = "pending"}
            requests[address] = request
            onRequest(request)
            return "pending"
        end,
        result = function()
            local request = requests[api.caller().address]
            if not request then error("no request", 0) end
            return request.state, request.grant
        end,
    }
    local endpoint = api.expose(invite.ENDPOINT, lib, invite.PORT)
    disco.offer(invite.ENDPOINT, invite.PORT)
    local host = {}
    function host.accept(request, grant)
        request.grant, request.state = grant, "accepted"
    end
    function host.deny(request)
        request.state = "denied"
    end
    function host.stop()
        disco.withdraw(invite.ENDPOINT)
        endpoint:shutdown()
    end
    return host
end

-- Checks a grant before the member keeps it. Returns the grant and role, or nil and why.
local function accepted(identity, state, grant)
    if state ~= "accepted" then return nil, state == "pending" and "no answer" or tostring(state) end
    if type(grant) ~= "table" or not networks.verifyNetwork(grant.network) then return nil, "bad network record" end
    if grant.revoked and not networks.verifyRevoked(grant.network, grant.revoked) then return nil, "bad revocation list" end
    local role, why = networks.check(grant.network, grant.revoked, grant.membership, identity.public)
    if not role then return nil, why end
    return grant, role
end

-- Member side, without waiting: asks the first invitation found nearby and gives the admin up
-- to timeout seconds. Calls callback(grant, role) with grant = {name, network, revoked,
-- membership}, or callback(nil, why).
function invite.join(identity, name, timeout, callback)
    disco.findAsync(invite.ENDPOINT, 2, function(hosts)
        if #hosts == 0 then return callback(nil, "no invitation nearby") end
        api.connectAsync(invite.ENDPOINT, invite.PORT, hosts[1].address, function(proxy, err)
            if not proxy then return callback(nil, err) end
            local deadline = computer.uptime() + (timeout or 120)
            local function poll()
                proxy:async(function(got, state, grant)
                    if got == true and state ~= "pending" or computer.uptime() >= deadline then
                        proxy:close()
                        return callback(accepted(identity, got == true and state or "pending", grant))
                    end
                    event.timer(1, poll)
                end).result()
            end
            proxy:async(function(sent, reason)
                if sent ~= true then
                    proxy:close()
                    return callback(nil, tostring(reason))
                end
                event.timer(1, poll)
            end).request(identity.public, name)
        end, nil, 3)
    end)
end

return invite
