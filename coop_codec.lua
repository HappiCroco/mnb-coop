-- =============================================================================
-- CO-OP CODEC
-- Turns Lua values into strings for the network and back. Data only: nothing
-- received is ever run as code (no load/loadstring), and the decoder refuses
-- anything too deep, too long or malformed instead of crashing.
--
-- Format, one tag byte per value:
--   N nil   T true   F false
--   n<number>;      number written with %.17g
--   s<len>:<bytes>  string
--   t<count>;<key><value>...  table (keys are strings or numbers)
-- =============================================================================
local codec = {}

local MAX_DEPTH = 10
local MAX_STRING = 256 * 1024
local MAX_ITEMS = 20000

local fmt, concat, byte, sub, find = string.format, table.concat, string.byte, string.sub, string.find

local function encodeInto(v, out, depth)
    local t = type(v)
    if v == nil then
        out[#out + 1] = "N"
    elseif t == "boolean" then
        out[#out + 1] = v and "T" or "F"
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then v = 0 end
        if v == math.floor(v) and v > -2^53 and v < 2^53 then
            out[#out + 1] = fmt("n%d;", v)
        else
            -- shortest text that reads back as the same number (123.45, not 123.45000000000000284)
            local text = fmt("%.14g", v)
            if tonumber(text) ~= v then text = fmt("%.17g", v) end
            out[#out + 1] = "n" .. text .. ";"
        end
    elseif t == "string" then
        out[#out + 1] = "s" .. #v .. ":" .. v
    elseif t == "table" then
        if depth >= MAX_DEPTH then error("coop codec: table too deep") end
        local n, parts = 0, {}
        for k, val in pairs(v) do
            local kt = type(k)
            if (kt == "string" or kt == "number") and type(val) ~= "function" and type(val) ~= "userdata" then
                n = n + 1
                encodeInto(k, parts, depth + 1)
                encodeInto(val, parts, depth + 1)
            end
        end
        out[#out + 1] = "t" .. n .. ";"
        out[#out + 1] = concat(parts)
    else
        out[#out + 1] = "N" -- functions, userdata: not sendable
    end
end

function codec.encode(v)
    local out = {}
    encodeInto(v, out, 0)
    return concat(out)
end

-- Decoder works on (string, position) and returns value, nextPosition.
local decodeAt

local function readUntil(s, pos, ch)
    local e = find(s, ch, pos, true)
    if not e then error("coop codec: truncated") end
    return sub(s, pos, e - 1), e + 1
end

decodeAt = function(s, pos, depth, budget)
    local tag = sub(s, pos, pos)
    pos = pos + 1
    if tag == "N" then return nil, pos
    elseif tag == "T" then return true, pos
    elseif tag == "F" then return false, pos
    elseif tag == "n" then
        local text
        text, pos = readUntil(s, pos, ";")
        local num = tonumber(text)
        if not num then error("coop codec: bad number") end
        return num, pos
    elseif tag == "s" then
        local lenText
        lenText, pos = readUntil(s, pos, ":")
        local len = tonumber(lenText)
        if not len or len < 0 or len > MAX_STRING or pos + len - 1 > #s or len ~= math.floor(len) then error("coop codec: bad string") end
        return sub(s, pos, pos + len - 1), pos + len
    elseif tag == "t" then
        if depth >= MAX_DEPTH then error("coop codec: table too deep") end
        local countText
        countText, pos = readUntil(s, pos, ";")
        local count = tonumber(countText)
        if not count or count < 0 then error("coop codec: bad table") end
        budget[1] = budget[1] - count
        if budget[1] < 0 then error("coop codec: too many items") end
        local t = {}
        for _ = 1, count do
            local k, v
            k, pos = decodeAt(s, pos, depth + 1, budget)
            v, pos = decodeAt(s, pos, depth + 1, budget)
            local kt = type(k)
            if kt ~= "string" and kt ~= "number" then error("coop codec: bad key") end
            t[k] = v
        end
        return t, pos
    end
    error("coop codec: unknown tag")
end

-- Limits for data that comes from the host we chose to join (battle state is big):
-- still bounded, but far above what the host accepts from strangers.
codec.HOST_LIMITS = { items = 4000000, string = 64 * 1024 * 1024 }

-- Returns the value, or nil and an error message. Never throws.
-- `limits` (optional): { items = n, string = bytes }; defaults are the strict ones.
function codec.decode(s, limits)
    if type(s) ~= "string" or #s == 0 then return nil, "empty" end
    local savedString = MAX_STRING
    if limits and limits.string then MAX_STRING = limits.string end
    local ok, v, pos = pcall(decodeAt, s, 1, 0, { limits and limits.items or MAX_ITEMS })
    MAX_STRING = savedString
    if not ok then return nil, v end
    if pos ~= #s + 1 then return nil, "trailing data" end
    return v
end

return codec
