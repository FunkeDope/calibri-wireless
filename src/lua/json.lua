--[[
Small JSON facade over dkjson (pure Lua, MIT) with the handful of calls the
companion uses. Keeps JSON null distinct from nil (calibre sends "uuid": null
and expects it back), and keeps empty {} / [] distinct through metatables.
--]]

local dk = require("dkjson")

local J = {}
J.null = dk.null

local OBJECT = { __jsontype = "object" }
local ARRAY = { __jsontype = "array" }

function J.object(t) return setmetatable(t or {}, OBJECT) end
function J.array(t) return setmetatable(t or {}, ARRAY) end

function J.encode(v, opts)
    return dk.encode(v, { indent = opts and opts.pretty or false })
end

function J.decode(s)
    if type(s) ~= "string" or s == "" then return nil, "empty" end
    local v, pos, err = dk.decode(s, 1, J.null)
    if v == nil and err then return nil, err end
    return v
end

-- Returns nil (never raises) when the file is missing, empty, half-written
-- or unreadable: the daemon replaces state.json with remove+rename on a FAT
-- volume and the UI polls it every second, so readers must tolerate a miss.
function J.load(path)
    local f, ferr = io.open(path, "rb")
    if not f then return nil, ferr end
    local ok, s = pcall(f.read, f, "*a")
    f:close()
    if not ok then return nil, s end
    local ok2, v, err = pcall(J.decode, s)
    if not ok2 then return nil, v end
    return v, err
end

-- Atomic enough for our purposes: write to .tmp then rename.
function J.dump(v, path, opts)
    local tmp = path .. ".tmp"
    local f, ferr = io.open(tmp, "wb")
    if not f then return nil, ferr end
    f:write(J.encode(v, opts))
    f:close()
    os.remove(path)
    return os.rename(tmp, path)
end

return J
