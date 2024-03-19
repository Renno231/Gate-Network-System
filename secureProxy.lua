local component = require("component")
-- Generates a secure proxy for a component, with exclusive access control.
local function secureProxy(componentAddress)
    -- Check if the component address exists and if it's already locked
    if not component.get(componentAddress) then
        return false, "Component does not exist or is already locked"
    end

    local proxy = component.proxy(componentAddress)
    if proxy.unlock then
        return false, "Component already locked"
    end
    local isLocked = true
    local originalMetaTable = getmetatable(proxy)

    -- Clone the original proxy to preserve its functionality without altering it
    local clonedProxy = {}
    clonedProxy.fields = proxy.fields
    for methodName, method in pairs(proxy) do
        if not proxy.fields[methodName] then
            clonedProxy[methodName] = method
        end
        local methodMeta = type(method) == 'table' and getmetatable(method)
        if type(method) == "function" or (methodMeta and rawget(methodMeta,"__call")) then
            rawset(proxy, methodName, nil)
        end
    end
    setmetatable(clonedProxy, {
        __index = originalMetaTable.__index,
        __newindex = originalMetaTable.__newindex,
        __pairs = function(t)
            -- Simple iteration without custom logic
            return next, t, nil
        end,
    })
    
    -- Override the metatable of the original proxy to intercept method calls
    local getterTypes = {}
    local newMetaTable = {
        __index = function(t, k)
            if k == "unlock" then
                return function(key)
                    if isLocked and key == clonedProxy then
                        isLocked = false -- Unlock the component
                        getterTypes = {} -- clean the table
                        return true
                    else
                        return false, "Invalid key or not locked"
                    end
                end
            elseif k == 'lock' then
                return function() isLocked = true return true end
            else
                -- Directly access the method if it exists in the cloned proxy
                if t.fields[k] and t.fields[k].getter then
                    local info
                    if not getterTypes[k] then
                        info = component.invoke(t.address, k)
                        local returnType = type(info)
                        getterTypes[k] = (returnType=='string' and info) or
                                         (returnType=='number' and 0) or
                                         ((returnType=='table' or returnType=='userdata') or {}) or
                                         (returnType=='function' and function() end)
                        if returnType == "boolean" then
                            getterTypes[k] = false --random guess of what the value is
                        end
                    end
                    if isLocked then 
                        return getterTypes[k]
                    end
                    info = info or component.invoke(t.address, k)
                    return info
                else
                    local value = clonedProxy[k] --rawget(clonedProxy, k)
                    if value then
                        local methodMeta = type(value) == 'table' and getmetatable(value)
                        if (type(value) == "function" or (methodMeta and rawget(methodMeta,"__call")) ) and isLocked then
                            -- If the component is locked, block access to its methods
                            if k:sub(1,3):lower() == 'get' then
                                --maybe do the getter return type thing here too?
                                return function() return "Component unavailable" end
                            else
                                return function() return false, "Component unavailable" end
                            end
                        else
                            return value
                        end
                    elseif type(originalMetaTable.__index) == "function" then
                        local value = originalMetaTable.__index(clonedProxy, k)
                        if type(value) == "function" and isLocked then
                            return function() return false, "Component unavailable" end
                        else
                            return value
                        end
                    end
                end
                
            end
        end,
        __newindex = originalMetaTable.__newindex,
        __pairs = originalMetaTable.__pairs and function(t)
            return function(t, k)
                local nk, nv = next(t, k)
                while nk == "unlock" or (isLocked and type(nv) == "function") do
                    nk, nv = next(t, nk) -- Skip 'unlock' and any function if locked
                end
                return nk, nv
            end, t, nil
        end,
        -- Hide the lock status from being directly manipulated or observed
        __metatable = "The metatable is locked"
    }

    -- Lock the proxy by setting the new metatable with the override
    setmetatable(proxy, newMetaTable) --this messes something up? .dialedAddress changes to weird things afterwards

    -- Return the unique key and the cloned proxy for unrestricted access
    return true, clonedProxy
end
return secureProxy