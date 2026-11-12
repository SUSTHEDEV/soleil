-- lsp/json.lua — minimal JSON encode/decode for the LSP wire protocol.
-- Handles exactly what LSP needs: objects, arrays, strings (with escapes),
-- numbers, booleans, null. No fancy features, no dependencies.

local json = {}

local function encode_value(v, out)
    local tv = type(v)
    if v == nil then
        out[#out + 1] = "null"
    elseif tv == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif tv == "number" then
        if v == math.floor(v) and math.abs(v) < 2^53 then
            out[#out + 1] = tostring(math.floor(v))
        else
            out[#out + 1] = tostring(v)
        end
    elseif tv == "string" then
        out[#out + 1] = string.format("%q", v):gsub("\\\n", "\\n")
    elseif tv == "table" then
        local is_array = (#v > 0) or next(v) == nil
        if is_array then
            local parts = {}
            for _, item in ipairs(v) do
                local sub = {}
                encode_value(item, sub)
                parts[#parts + 1] = table.concat(sub)
            end
            out[#out + 1] = "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, item in pairs(v) do
                local sub = {}
                encode_value(item, sub)
                parts[#parts + 1] = string.format("%q", tostring(k)) .. ":" .. table.concat(sub)
            end
            out[#out + 1] = "{" .. table.concat(parts, ",") .. "}"
        end
    end
end

function json.encode(v)
    local out = {}
    encode_value(v, out)
    return table.concat(out)
end

-- ---------------------------------------------------------------- decode --
local decode_value, parse_string

local function skip_ws(s, pos)
    while true do
        local c = s:sub(pos, pos)
        if c == " " or c == "\t" or c == "\n" or c == "\r" then
            pos = pos + 1
        else
            return pos
        end
    end
end

local ESCAPES = {
    ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f",
    n = "\n", r = "\r", t = "\t",
}

parse_string = function(s, pos)
    pos = pos + 1                                   -- skip opening quote
    local buf = {}
    while true do
        local c = s:sub(pos, pos)
        if c == "" then error("json: unterminated string") end
        if c == '"' then return table.concat(buf), pos + 1 end
        if c == "\\" then
            local e = s:sub(pos + 1, pos + 1)
            if e == "u" then
                local code = tonumber(s:sub(pos + 2, pos + 5), 16)
                if not code then error("json: bad \\u escape") end
                buf[#buf + 1] = utf8 and utf8.char(code) or string.char(code % 256)
                pos = pos + 6
            else
                buf[#buf + 1] = ESCAPES[e] or e
                pos = pos + 2
            end
        else
            buf[#buf + 1] = c
            pos = pos + 1
        end
    end
end

decode_value = function(s, pos)
    pos = skip_ws(s, pos)
    local c = s:sub(pos, pos)
    if c == "{" then
        local obj = {}
        pos = skip_ws(s, pos + 1)
        if s:sub(pos, pos) == "}" then return obj, pos + 1 end
        while true do
            pos = skip_ws(s, pos)
            local k
            k, pos = parse_string(s, pos)
            pos = skip_ws(s, pos)
            pos = pos + 1                           -- skip ':'
            local v
            v, pos = decode_value(s, pos)
            obj[k] = v
            pos = skip_ws(s, pos)
            local d = s:sub(pos, pos)
            if d == "," then pos = pos + 1
            elseif d == "}" then return obj, pos + 1
            else error("json: expected ',' or '}' at " .. pos) end
        end
    elseif c == "[" then
        local arr = {}
        pos = skip_ws(s, pos + 1)
        if s:sub(pos, pos) == "]" then return arr, pos + 1 end
        while true do
            local v
            v, pos = decode_value(s, pos)
            arr[#arr + 1] = v
            pos = skip_ws(s, pos)
            local d = s:sub(pos, pos)
            if d == "," then pos = pos + 1
            elseif d == "]" then return arr, pos + 1
            else error("json: expected ',' or ']' at " .. pos) end
        end
    elseif c == '"' then
        return parse_string(s, pos)
    elseif s:sub(pos, pos + 3) == "true" then return true, pos + 4
    elseif s:sub(pos, pos + 4) == "false" then return false, pos + 5
    elseif s:sub(pos, pos + 3) == "null" then return nil, pos + 4
    else
        local num_end = pos
        while s:sub(num_end, num_end):match("[0-9%.%-+eE]") do num_end = num_end + 1 end
        local n = tonumber(s:sub(pos, num_end - 1))
        if not n then error("json: unexpected character '" .. c .. "' at " .. pos) end
        return n, num_end
    end
end

function json.decode(s)
    local v, pos = decode_value(s, 1)
    return v, pos
end

return json
