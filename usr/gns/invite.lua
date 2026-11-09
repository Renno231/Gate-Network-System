-- GNS invitations: how a grant gets from the owner's or an admin's device to a player's device.
-- The issuer hosts an invitation (announced on disco as gns-invite). A player asks with their
-- public key and player name; the issuer sees the request and accepts it with a grant and the
-- gates it covers, or denies it. The player polls until it is decided and checks the grant
-- before keeping it.
local api = require("api")
local computer = require("computer")
local disco = require("disco")
local event = require("event")
local grants = dofile("/usr/gns/grants.lua")

local invite = {ENDPOINT = "gns-invite", PORT = 161, MAX_PENDING = 16}

-- Issuer side. onRequest(request) is called for each new request {address, key, name}.
-- Returns a host with accept(request, offer), deny(request) and stop(). offer = {grant, gates}
-- with gates = {[gate key] = {name, modem, port, wake}}: what the holder needs to reach and
-- wake the gates the grant covers.
function invite.host(onRequest)
    local requests, count = {}, 0
    local lib = {
        request = function(key, name)
            local address = api.caller().address
            if type(key) ~= "string" or #key ~= 22 then error("bad key", 0) end
            if type(name) ~= "string" or #name == 0 or #name > 32 then error("bad name", 0) end
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
            return request.state, request.offer
        end,
    }
    local endpoint = api.expose(invite.ENDPOINT, lib, invite.PORT)
    disco.offer(invite.ENDPOINT, invite.PORT)
    local host = {}
    function host.accept(request, offer) request.offer, request.state = offer, "accepted" end
    function host.deny(request) request.state = "denied" end
    function host.stop()
        disco.withdraw(invite.ENDPOINT)
        endpoint:shutdown()
    end
    return host
end

-- Checks an offer before the player keeps it: a grant for this key, signed by the owner, or a
-- user grant signed by an admin holding the owner's admin grant. Returns the offer and role, or
-- nil and why.
local function accepted(identity, state, offer)
    if state ~= "accepted" then return nil, state == "pending" and "no answer" or tostring(state) end
    local g = type(offer) == "table" and offer.grant
    if not grants.valid(g) or g.holder ~= identity.public then return nil, "not a grant for this device" end
    if g.signer ~= g.owner then
        local by = g.by
        if g.role ~= "user" or not grants.valid(by) or by.holder ~= g.signer or by.role ~= "admin" or by.owner ~= g.owner then
            return nil, "grant not signed by the owner or an admin"
        end
    end
    if type(offer.gates) ~= "table" then offer.gates = {} end
    return offer, g.role
end

-- Player side, without waiting: asks the first invitation found nearby and gives the issuer up
-- to timeout seconds. Calls callback(offer, role), or callback(nil, why).
function invite.join(identity, name, timeout, callback)
    disco.findAsync(invite.ENDPOINT, 2, function(hosts)
        if #hosts == 0 then return callback(nil, "no invitation nearby") end
        api.connectAsync(invite.ENDPOINT, invite.PORT, hosts[1].address, function(proxy, err)
            if not proxy then return callback(nil, err) end
            local deadline = computer.uptime() + (timeout or 120)
            local function poll()
                proxy:async(function(got, state, offer)
                    if got == true and state ~= "pending" or computer.uptime() >= deadline then
                        proxy:close()
                        return callback(accepted(identity, got == true and state or "pending", offer))
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
