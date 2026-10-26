-- tests/roundtrip_suite.lua — 7th suite: emission integrity.
-- Run: lua5.1 tests/roundtrip_suite.lua
--
-- Emit -> re-parse -> normalized AST equivalence. Lua-mode sources must be
-- AST-isomorphic (modulo documented reformattings: local-fn pre-declare
-- splits, `local _ = fn` statements, emitter-added parens, erased soleil
-- annotations). Soleil sources and null-operator constructs are semantic
-- lowerings: checked emit->reparse->load only.
-- Found the 10e500->`inf` emitter bug (raw numerals now survive verbatim).
--   parse(src) -> emit -> re-parse(emitted) -> normalized AST equivalence
-- Catches emitter drops, duplications, and reorderings without executing.
package.path = package.path .. ";./?.lua"
local parser = require("parser.parser")
local Codegen = require("codegen.codegen")

-- normalization: what MAY differ across a faithful emission
--   - line numbers (emitter reformats layout)
--   - Paren nodes the emitter adds for prefixexp (user parens survive, but we
--     cannot distinguish them from added ones -> unwrap both sides; the
--     (f()) truncation check lives in the battery's run tier instead)
--   - Number spelling (0xFF vs 255)
local function norm(node)
    if type(node) ~= "table" then return node end
    if node.type then
        local out = { type = node.type }
        for k, v in pairs(node) do
            if k ~= "type" and k ~= "line" and k ~= "via_dot" then
                if node.type == "Paren" then
                    return norm(node.expr)          -- unwrap added/user parens alike
                end
                out[k] = norm(v)
            end
        end
        return out
    else
        -- emitted-list normalization: undo the two INTENTIONAL reformattings
        --  1. `local f` + `f = <anon fn>`  -> LocalDeclaration{f, fn}
        --  2. `local _ = <anon fn>` (statement-position anonymous fn)
        --        -> the bare FunctionDeclaration statement
        local merged = {}
        local i = 1
        while i <= #node do
            local s, nxt = node[i], node[i + 1]
            if s.type == "LocalDeclaration" and #s.names == 1 and #(s.values or {}) == 0
                  and nxt and nxt.type == "Assignment" and #nxt.variables == 1
                  and nxt.variables[1].name == s.names[1].name
                  and #nxt.values == 1 and nxt.values[1].type == "FunctionDeclaration"
                  and nxt.values[1].name == nil then
                merged[#merged + 1] = norm({ type = "LocalDeclaration",
                    names = s.names, values = { nxt.values[1] },
                    declaration_type = s.declaration_type })
                i = i + 2
            elseif s.type == "LocalDeclaration" and s.names and s.names[1] and s.names[1].name == "_"
                  and s.values and #s.values == 1 and s.values[1].type == "FunctionDeclaration"
                  and s.values[1].name == nil then
                merged[#merged + 1] = norm(s.values[1])
                i = i + 1
            else
                if s.type == "LocalDeclaration" and s.declaration_type then
                    s = { type = "LocalDeclaration", names = s.names, values = s.values }
                end
                merged[#merged + 1] = norm(s)
                i = i + 1
            end
        end
        return merged
    end
end

local function same(a, b, path, diffs)
    if a == b then return true end
    local ta, tb = type(a), type(b)
    if ta ~= "table" or tb ~= "table" then
        -- Number spelling tolerance: "0xFF" vs "255"
        local na, nb = tonumber(a), tonumber(b)
        if na and nb and (na == nb
              or math.abs(na - nb) <= 1e-9 * math.max(1, math.abs(na))) then
            return true                                  -- float formatting tolerance
        end
        diffs[#diffs + 1] = path .. ": " .. tostring(a) .. " ~= " .. tostring(b)
        return false
    end
    -- order-insensitive keyed compare + order-sensitive list compare
    local keys = {}
    for k in pairs(a) do keys[k] = true end
    for k in pairs(b) do keys[k] = true end
    for k in pairs(keys) do
        local va, vb = a[k], b[k]
        if va == nil and vb ~= nil then diffs[#diffs + 1] = path .. "." .. tostring(k) .. ": missing on source"
        elseif vb == nil and va ~= nil then diffs[#diffs + 1] = path .. "." .. tostring(k) .. ": missing on emitted"
        else same(va, vb, path .. "." .. tostring(k), diffs) end
    end
    return #diffs == 0
end

local function roundtrip(name, src, dialect, lowering_only)
    local ok, tree = pcall(parser.parse, parser.tokenize(src, dialect))
    if not ok then return name, "PARSE-SRC", tostring(tree):gsub("\n", " "):sub(1, 90) end
    local okg, out = pcall(Codegen.generate, tree)
    if not okg then return name, "EMIT", tostring(out):gsub("\n", " "):sub(1, 90) end
    local ok2, tree2 = pcall(parser.parse, parser.tokenize(out, dialect))
    if not ok2 then
        return name, "REPARSE", tostring(tree2):gsub("\n", " "):sub(1, 90) .. " | emitted: " .. out:gsub("\n", " | "):sub(1, 120)
    end
    if lowering_only then return end                 -- emit+reparse suffices for lowerings
    local diffs = {}
    same(norm(tree), norm(tree2), name, diffs)
    if #diffs > 0 then
        return name, "AST-DIFF", table.concat(diffs, "\n    "):sub(1, 300)
    end
end

local files = {}
do
    local h = io.popen("ls tests/_lua5.1-tests/*.lua 2>/dev/null")
    for f in h:lines() do files[#files + 1] = { f, "lua" } end
    h:close()
end
files[#files + 1] = { "tests/oop_integration.sol", "soleil" }

local checked, bad = 0, 0
for _, f in ipairs(files) do
    local fh = io.open(f[1], "r")
    if not fh then
        print("SKIP (missing): " .. f[1])
    else
        local src = fh:read("*a")
        fh:close()
        local name, kind, detail
        if f[2] == "lua" then
            name, kind, detail = roundtrip(f[1], src, f[2])          -- must be AST-isomorphic
        else
            name, kind, detail = roundtrip(f[1], src, f[2], true)    -- lowering: no AST diff
        end
        if kind then
            bad = bad + 1
            print("[" .. kind .. "] " .. name .. "\n    " .. tostring(detail))
        else
            checked = checked + 1
        end
    end
end

-- grammar probes: single constructs the corpus may not cover
local probes = {
    { "elvis chain", "local a : number? = nil\nlocal b : number? = 5\nprint(a ?: b ?: 7)", "soleil" },
    { "safe access", "class P(x : number) end\nlocal p : P? = P(1)\nprint(p?.x, p!!.x)", "soleil" },
    { "computed keys", "local k = \"dyn\"\nlocal t = { [k] = 1, [1] = 2 }\nprint(t.dyn)", "lua" },
    { "varargs fwd", "local function f(...) return select(\"#\", ...) end\nprint(f(1, 2, 3))", "lua" },
    { "nested tables", "local t = { a = { b = { c = 1 } } }\nprint(t.a.b.c)", "lua" },
    { "multi assign", "local a, b, c = 1, 2\nprint(a, b, c)", "lua" },
    { "string escapes", "print(\"a\\nb\\tc\\\\d\\\"e\\065\")", "lua" },
    { "long strings", "local s = [[line1\nline2]]\nprint(#s)", "lua" },
    { "numeric forms", "print(0xFF, 1e2, .5, 3.25)", "lua" },
    { "method chains", "local s = \"abc\"\nprint(s:upper():len())", "lua" },
    { "generics-ish", "local m : table[string, table[number]] = { a = {1, 2} }\nprint(m.a[2])", "soleil" },
    { "goto-less loops", "local i = 0\nrepeat i = i + 1 until i > 3\nprint(i)", "lua" },
}
local lowering_probes = { ["elvis chain"] = true, ["safe access"] = true }
for _, p in ipairs(probes) do
    local name, kind, detail = roundtrip(p[1], p[2], p[3], lowering_probes[p[1]])
    if kind then
        bad = bad + 1
        print("[" .. kind .. "] " .. name .. "\n    " .. tostring(detail))
    else
        checked = checked + 1
    end
end

print(string.format("round-trip identical: %d | divergences: %d", checked, bad))
if bad > 0 then os.exit(1) end
