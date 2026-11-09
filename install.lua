-- GNS installer: installs GNS, or updates it, from GitHub, with the loom and ecc libraries it
-- needs. Run it on a QuickOS computer with an internet card:
--   wget -f https://raw.githubusercontent.com/Renno231/Gate-Network-System/main/install.lua /tmp/gns-install.lua
--   /tmp/gns-install.lua
-- gns update does the same. Only files that changed since the last install are downloaded, and
-- none is replaced until all have arrived, so a dropped connection leaves the old install whole.
-- The vault, settings and gate state are written at run time and are never part of an install.
local component = require("component")
local fs = require("filesystem")
local serialization = require("serialization")

local SOURCES = {
    {repo = "Renno231/Gate-Network-System", branch = "main", from = "usr/", to = "/usr/"},
    {repo = "Renno231/Renno-Programs", branch = "master", from = "loom/lib/", to = "/usr/lib/"},
    {repo = "Renno231/Renno-Programs", branch = "master", from = "ecc/lib/", to = "/usr/lib/"},
}
local RECORD = "/usr/gns/installed.lua" -- installed path -> git blob sha
local HEADERS = {["User-Agent"] = "GNS-installer"}

local function fail(message)
    io.stderr:write(message .. "\n")
    os.exit(1)
end
if not component.isAvailable("internet") then fail("Installing GNS needs an internet card.") end
if not (fs.exists("/usr/lib/api.lua") and fs.exists("/usr/lib/disco.lua")) then
    fail("GNS runs on QuickOS (it needs TNET's api and disco libraries).")
end

-- The body of a GET, or nil and why not.
local function get(url)
    local ok, request = pcall(component.internet.request, url, nil, HEADERS)
    if not ok or not request then return nil, tostring(request) end
    local parts, deadline = {}, require("computer").uptime() + 30
    while true do
        local connected, reason = request.finishConnect()
        if connected then break end
        if connected == nil then request.close() return nil, tostring(reason) end
        if require("computer").uptime() > deadline then request.close() return nil, "timed out" end
        os.sleep(0.05)
    end
    local code, message = request.response()
    while true do
        local data, reason = request.read()
        if not data then
            request.close()
            if reason then return nil, tostring(reason) end
            break
        end
        parts[#parts + 1] = data
        if #data == 0 then os.sleep(0.05) end
    end
    if code and code ~= 200 then return nil, ("HTTP %d %s"):format(code, tostring(message or "")) end
    return table.concat(parts)
end

local loaded, value = pcall(dofile, RECORD)
local record = loaded and type(value) == "table" and value or {}

-- What each source holds now: {path, sha, url}; and what of it this computer lacks.
local json = require("json")
local trees, wanted, changed = {}, {}, {}
for _, source in ipairs(SOURCES) do
    local key = source.repo .. "@" .. source.branch
    if not trees[key] then
        io.write("Reading " .. key .. "... ")
        local body, reason = get(("https://api.github.com/repos/%s/git/trees/%s?recursive=1"):format(source.repo, source.branch))
        if not body then fail("could not list " .. key .. ": " .. reason) end
        local ok, tree = pcall(json.decode, body)
        if not ok or type(tree) ~= "table" or type(tree.tree) ~= "table" then fail("could not read the list of " .. key) end
        if tree.truncated then fail("the list of " .. key .. " came back cut short") end
        trees[key] = tree.tree
        print("ok")
    end
    for _, item in ipairs(trees[key]) do
        if item.type == "blob" and item.path:sub(1, #source.from) == source.from then
            local target = source.to .. item.path:sub(#source.from + 1)
            wanted[target] = item.sha
            if record[target] ~= item.sha or not fs.exists(target) then
                changed[#changed + 1] = {target = target, sha = item.sha,
                    url = ("https://raw.githubusercontent.com/%s/%s/%s"):format(source.repo, source.branch, item.path)}
            end
        end
    end
end
if #changed == 0 then
    print("GNS is up to date.")
    return
end

-- Download every changed file beside its place, then put them all in place.
for i, file in ipairs(changed) do
    io.write(("[%d/%d] %s... "):format(i, #changed, file.target))
    local body, reason = get(file.url)
    if body then
        -- A full disk shows up as a failed write or flush (closing does not say).
        fs.makeDirectory(fs.path(file.target))
        local out
        out, reason = io.open(file.target .. ".new", "wb")
        if out then
            body, reason = out:write(body)
            if body then body, reason = out:flush() end
            out:close()
        end
        body = out and body
    end
    if not body then
        for j = 1, i do fs.remove(changed[j].target .. ".new") end
        fail("failed: " .. tostring(reason) .. "\nNothing was changed.")
    end
    print("ok")
end
for _, file in ipairs(changed) do
    if fs.exists(file.target) then fs.remove(file.target) end
    fs.rename(file.target .. ".new", file.target)
    record[file.target] = file.sha
end
for target in pairs(record) do
    if not wanted[target] then record[target] = nil end
end
local out = assert(io.open(RECORD, "w"))
out:write("return " .. serialization.serialize(record, math.huge))
out:close()
print(("Installed %d files. Run gns to start it; gns autorun on starts it at boot."):format(#changed))
