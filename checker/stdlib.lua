-- the signature / built-in header for standard libraries so that checker can have something to freaking check to (basically the Root of Trust for stdlibs types).
local function fn(params, ret, varargs)
    return { kind = "function", params = params, ret = ret, varargs = varargs or false }
end

local S = { kind = "primitive", name = "string" }
local N = { kind = "primitive", name = "number" }
local U = { kind = "primitive", name = "unknown" }    -- dynamic params: everything flows in
local NIL = { kind = "primitive", name = "nil" }
local B = { kind = "primitive", name = "boolean" }

local function opt(t) return { kind = "union", members = { t, { kind = "primitive", name = "nil" } } } end
local function array(v) return { kind = "table", form = "array", key = N, value = v } end
local U = { kind = "primitive", name = "unknown" }
local function map(k, v) return { kind = "table", form = "map", key = k, value = v } end
local function record(fields) return { kind = "record", fields = fields } end

return {
    ["print"] = fn({ U }, NIL, true),
    ["select"] = fn({ U }, U, true),   -- tuple-awareness is special-cased in the checker
    ["type"]  = fn({ U }, S),
    ["string"] = record({
        sub    = fn({ S, N, opt(N) }, S),
        len    = fn({ S }, N),
        format = fn({ S }, S, true),
        rep    = fn({ S, N }, S),
        upper  = fn({ S }, S),
        lower  = fn({ S }, S),
        byte   = fn({ S, opt(N), opt(N) }, N, true),
        char   = fn({ N }, S, true),
        find   = fn({ S, S, opt(N) }, opt(N)),
        match  = fn({ S, S }, opt(S)),
        gmatch = fn({ S, S }, A, true),
        gsub   = fn({ S, S, S }, S),
    }),
    ["math"]  = record({ floor = fn({ N }, N), max = fn({ N, N }, N) }),
    ["table"] = record({ insert = fn({ array(U), U }, NIL, true) }),
    ["pairs"]  = fn({ map(U, U) }, U),     -- iterator magic is special-cased, see 4
    ["ipairs"] = fn({ array(U) }, U),
    ["tostring"] = fn({U}, S),
    ["tonumber"] = fn({U}, opt(N)),
    ["error"] = fn({U}, NIL),
    ["pcall"] = fn({U}, B, true),           -- v1: ret is just the boolean; results are any
    ["setmetatable"] = fn({map(U, U), map(U, U)}, map(U, U)),   -- returns its (untyped) table argument
    ["getmetatable"] = fn({U}, map(U, U)),
}