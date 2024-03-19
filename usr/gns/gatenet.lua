--[[ --testing scripts
lua
gatestack = gatenet.new()
gatestack.open(1) _, receiver, sender, port, distance, msg, validated = event.pull("gatenet_connection") c = gatestack.generateConnection(sender, port, msg) p = c() if p then p:next(function(self, packet) print(packet.payload.data) end):looping(true) end 

c = gatestack.connect("18d93353-37f2-4543-90b3-d2a0acea8f2c",  "hello there", 1):next(function(self) term.write("responding!\n") self:send() end)

lua
c = gatestack.connect("9230ee77-9f01-4887-9d1c-3d35834c0b94", "hi", 1):next(function(self, packet) print(packet.payload.data) end)

lua
s = event.listen("gatenet_connection", function(_, receiver, sender, port, distance, msg, handshakeValidated) valid = handshakeValidated c = gatestack.generateConnection(sender, port, msg) if handshakeValidated then p = c():next(function(self, packet) print(packet.payload.data) end):looping(true) end end) gatestack.initiateHandshake(1)

]]

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local computer = require"computer"
local uuid = require"uuid"

local modem = component.modem
-- energy_cost = strength * 0.05 
-- by default config, max cost is 20 per send

local function deepCopy(obj, seen)
    -- Handle non-tables and previously-seen tables.
    if type(obj) ~= 'table' then return obj end
    if seen and seen[obj] then return seen[obj] end

    -- New table; mark it as seen an copy recursively.
    local s = seen or {}
    local res = {}
    s[obj] = res
    for k, v in next, obj do res[deepCopy(k, s)] = deepCopy(v, s) end
    return setmetatable(res, getmetatable(obj))
end

local packetMetaTable = {
    __index = {
        serialize = function(self)
            return serialization.serialize(self)
        end,
        copy = function(self)
            return deepCopy(self)
        end
    },
    __metatable = "locked"
}

local function createPacket(data, metadata, messageType)
    local packet = {
        header = {
            sender = "computerA",
            timestamp = os.time(),
            id = uuid.next(),
            -- connection is set later in send
        },
        payload = {
            type = messageType,
            data = data,
            metadata = metadata
        }
    }

    return setmetatable(packet, packetMetaTable)
end


local acceptorMetatable = {
    __index = function(self, value)
        if value == "accept" then
            return self.__callback
        end
    end,
    __call = function(self) return self:__callback() end,
    __metatable = 'locked'
}

local function markTime(promise, key)
    local now = computer.uptime()
    if key then
        promise[key] = now
    end
    promise.lastActive = now
end

local function makeGatestack()
    local activePromises = {}
    local blockList = {}

    local function promiseMaid(promise)
        if promise.connectionID then 
            activePromises[promise.connectionID] = nil
        end
        if promise.destination then 
            activePromises[promise.destination]= nil
        end
        if promise.timeoutID then
            event.cancel(promise.timeoutID)
            promise.timeoutID = nil
        end
    end
    local promiseMetatable = {
        __index = {
            ["next"] = function(self, onFulfilled)
                table.insert(self.callbacks, onFulfilled)
                return self
            end,

            catch = function(self, onRejected)
                table.insert(self.errCallbacks, onRejected)
                return self
            end,

            finally = function(self, onFinally)
                table.insert(self.finallyCallbacks, onFinally)
                return self
            end,

            timeout = function(self, timeoutDuration, timeoutCallback)
                local function wrappedTimeoutCallback()
                    promiseMaid(self)
                    if timeoutCallback then 
                        timeoutCallback(self, timeoutDuration)
                    end
                end
                self.timeoutID = event.timer(timeoutDuration, wrappedTimeoutCallback)
                return self
            end,

            looping = function(self, shouldLoop)
                self.loopingCallback = shouldLoop
                return self
            end,

            send = function(self, packet, port)
                if not self.destination then return end
                packet = packet or self.lastSentPacket
                if port then self.port = port end
                if packet then self.lastSentPacket = packet end
                if self.port == nil or (self.lastSentPacket == nil and packet == nil) then return end
                if not modem.isOpen(self.port) then
                    modem.open(self.port)
                end
                if packet then
                    if type(packet) == 'string' then
                        packet = createPacket(packet)
                    end
                    self.lastSentPacket = packet
                    markTime(self, "lastSentTime")
                    packet.header.connection = self.connectionID 
                    if self.destination == modem.address then
                        event.push("modem_message", self.destination, self.destination, self.port, 0, packet:serialize())
                    else
                        modem.send(self.destination, self.port, packet:serialize())
                    end
                end
                -- end
                return self
            end,

            broadcast = function(self, packet, port, headerOverride)
                packet = packet or self.lastSentPacket
                if port then self.port = port end
                if packet then self.lastSentPacket = packet end
                if self.port == nil or (self.lastSentPacket == nil and packet == nil) then return end
                if not modem.isOpen(self.port) then
                    modem.open(self.port)
                end
                if packet then
                    if type(packet) == 'string' then
                        packet = createPacket(packet)
                    end
                    self.lastSentPacket = packet
                    if headerOverride == nil or headerOverride then
                        packet.header.connection = self.connectionID
                    end
                    modem.broadcast(self.port, packet:serialize())
                end
                -- end
                return self
            end,

            label = function(self, value)
                checkArg(2, value, 'string', 'nil')
                local oldValue = self._labelName or self.connectionID
                if value then
                    self._labelName = value
                end
                return oldValue
            end,

            ['cancel'] = function(self, sendRejectionPacket)
                if sendRejectionPacket then
                    if sendRejectionPacket == true then
                        sendRejectionPacket = nil
                    end
                    self:send(createPacket(sendRejectionPacket, nil, "connectionRejected"))
                end
                self.cancelled = true
                promiseMaid(self)
                return self
            end,
        },
        __metatable = "locked"
    }

    local function makePromise(destination, port, connectionID)
        local promise = {
            destination = destination,
            port = port,
            -- lastSentPacket = packet,
            -- started = computer.uptime(), --os.time(),
            connectionID = connectionID or uuid.next(),
            cancelled = false,
            loopingCallback = false,
            callbacks = {index = 1},
            errCallbacks = {},
            finallyCallbacks = {}
        }
        markTime(promise, "started")
        if destination then
            promise.destination = destination
            activePromises[promise.destination]= promise --by modem uuid
        end
        if connectionID == false then
            promise.connectionID = nil
        end
        if promise.connectionID~=nil then
            activePromises[promise.connectionID] = promise --by promise uuid 
        end
        return setmetatable(promise, promiseMetatable)
    end

    -- local modem_messageFunction = 
    local stackListener = event.listen("modem_message", function(_, receiver, sender, port, distance, wakeup, msg, ...)
        if blockList[sender] then return end
        -- local isInternal = type(wakeup)
        -- local fromServer, fromClient --only used if internal
        -- if isInternal then
        --     fromServer = wakeup == 1
        --     fromClient = wakeup == 2
        -- end
        msg = msg or wakeup
        local currentTime = computer.uptime()
        local illegalFunction= msg:match("function.*[(]")
        local illegalCode = msg:match("[)][.:].*[('\")]")
        if illegalFunction or illegalCode then --function and code detection
            if illegalFunction or (illegalCode and not illegalCode:match("^[.][0-9]")) then
                -- print('Illegal string!', msg)
                return
            end
        end
        local packet, payloadError = serialization.unserialize(msg)
        if type(packet) == 'table' and packet.header and type(packet.header) == 'table' and packet.payload and type(packet.payload) == 'table' then
            setmetatable(packet, packetMetaTable)
            local promise = (packet.header.connection and activePromises[packet.header.connection]) 
                            -- or activePromises[sender] --the second part is for pre-made promises expecting an incoming connection, not really usefull
            if promise then
                if promise.destination ~= sender then return end -- replay attack?
                if promise.port ~= port then return end
                promise.lastReceivedPacket = packet
                promise.lastReceivedTime = currentTime
                if promise.callbacks[promise.callbacks.index] then
                    promise.callbacks[promise.callbacks.index](promise, packet)
                    if not promise.loopingCallback then
                        promise.callbacks.index = promise.callbacks.index + 1
                    end
                end
                if not promise.callbacks[promise.callbacks.index] then -- run out of :then callbacks
                    for _, callback in ipairs (promise.finallyCallbacks) do
                        callback(promise)
                    end
                    promiseMaid(promise)
                end
            else -- try to establish a new connection?
                local handshakeValidated = false
                if activePromises[packet.payload.metadata] and packet.payload.type == "handshakeSuccess" then
                    handshakeValidated = true
                end
                event.push("gatenet_connection", receiver, sender, port, distance, msg, handshakeValidated)
                --[[
                    event.listen("gatenet_connection", function(_, receiver, sender, port, distance, packet, handshakeValidated)
                        local acceptor = gatenet.generateAcceptor(sender, port, packet)
                        if handshakeValidated then
                        --attach it to whatever ui thing
                            local connection = acceptor()
                        end
                    end
                ]]
            end
        end
    end)

    local function generateConnectionObject(sender, port, packetstring) --used in event.listen("gatenet_connection")
        local acceptor = {__callback = function(self) 
            local received, payloadError = serialization.unserialize(packetstring)
            setmetatable(received, packetMetaTable)
            local isHandshake = received.payload.type == "handshakeInitiation"
            local newConnection = received.header.connection
            if isHandshake then
                newConnection = nil
            end
            local newPromise = makePromise(sender, port, newConnection)
            markTime(newPromise, "lastReceivedTime")
            newPromise.lastReceivedPacket = received
            self.__callback = nil
            --confirm handshake with response
            if isHandshake then
                newPromise:send(createPacket(nil, received.payload.metadata, "handshakeSuccess"))
            end
    
            -- since this is created as a response, could do a :send() to confirm connection is made
            return newPromise
        end}
    
        return setmetatable(acceptor, acceptorMetatable)
    end

    local function sendMessage(destination, packet, port, timeout)
        if packet and getmetatable(packet) == nil then
            packet = createPacket(packet)
        end
        
        local promise = makePromise(destination)
        if timeout and type(timeout) == 'number' then
            promise:timeout(timeout)
        end
    
        promise:send(packet, port)
    
        return promise
    end
    
    local function initiateHandshake(port, data, timeout)
        
        local promise = makePromise(nil, port)
        if timeout==nil or type(timeout) == 'number' then
            promise:timeout(timeout or 5)
        end
    
        promise:broadcast(createPacket(data, promise.connectionID, "handshakeInitiation"), port, false)
    
        return promise
    end

    local function blockModem(uuid, value)
        checkArg(1, uuid, 'string')
        if value == nil then 
            blockList[uuid] = true
        else
            blockList[uuid] = value
        end
        return true
    end
    
    local function unblockModem(uuid)
        checkArg(1, uuid, 'string')
        blockList[uuid] = nil
        return true
    end

    local function isBlocked(uuid) 
        checkArg(1, uuid, 'string')
        return blockList[uuid]
    end

    return {
        listener = stackListener,
        promise = makePromise,
        connect = sendMessage,
        block = blockModem,
        unblock = unblockModem,
        isBlocked = isBlocked,
        initiateHandshake = initiateHandshake,
        packet = createPacket,
        generateConnection = generateConnectionObject,
        open = modem.open,
    }
end


return {
    new = makeGatestack
}