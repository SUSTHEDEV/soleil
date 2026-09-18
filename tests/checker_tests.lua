-- tests/checker_tests.lua — regression suite for the Soleil type checker
-- Run: lua5.1 tests/checker_tests.lua
--
-- VALID programs must type-check clean. INVALID programs must raise a type
-- error whose message CONTAINS the expected fragment. This is the same
-- must-pass/must-error contract as tests.lua, applied to semantics.

package.path = package.path .. ";./?.lua;./.rocks/share/lua/5.1/?.lua"
local parser = require("parser.parser")
local Checker = require("checker.checker")

local passed, failed = 0, 0

-- ---------------------------------------------------------------------------
-- VALID: must type-check with zero errors
-- ---------------------------------------------------------------------------
local valid = {
  -- literals & inference
  "local x = 1",
  "local s = \"a\"",
  "local b = true",
  "local n = nil",
  -- annotated locals, all type forms
  "local x : number = 1",
  "local s : string = \"a\"",
  "local t : table[string, number] = {}",
  "local t : table[number] = {}",
  "local t : table[any] = {}",
  "local s : string? = nil",
  "local u : number | string = 1",
  "local u : number | string = \"a\"",
  -- any accepts everything, everything accepts any
  "local a : any = 1",
  "local a : any = {}",
  "local n : number = a",  -- placeholder replaced below
  -- assignment compatibility
  "local x : number = 1\nx = 2",
  "local s : string? = \"a\"\ns = nil",
  -- §3: table reads yield V?
  "local t : table[string, number] = {}\nlocal n : number? = t.k",
  "local t : table[string, number] = {}\nlocal key = \"a\"\nlocal n : number? = t[key]",
  -- table stores check the value type
  "local t : table[string, number] = {}\nt.k = 5",
  -- operators
  "local x = 1 + 2 * 3",
  "local s = \"a\" .. \"b\"",
  "local c = 1 < 2",
  "local t = {}\nlocal x = -#t",
  "local x = 2 ^ 3",
  -- blocks & scoping
  "do local x = 1 end",
  "local x = true\nlocal y = 0\nif x then y = 1 end",
  "local x = true\nwhile x do break end",
  "repeat until x",
  "for i = 1, 10 do end",
  "local t = {}\nfor k, v in pairs(t) do end",
  -- functions parse & declare (call checking is Step 3)
  "local f = function(x : number) : number return x end",
  "function g(a, b : string) end",
}

-- fix the any-echo case: needs `a` declared first
valid[15] = "local a : any = 1\nlocal n : number = a"

-- ---------------------------------------------------------------------------
-- INVALID: must raise a type error containing the fragment
-- ---------------------------------------------------------------------------
local invalid = {
  { "local x : string = 1",                    "cannot initialize" },
  { "local x : number = \"s\"",                "cannot initialize" },
  { "local x : number = 1\nx = \"s\"",         "cannot assign" },
  { "local x : number = 1\nx = nil",           "cannot assign" },          -- T? -> T
  { "y = 5",                                   "undefined variable" },
  { "local x : number = undefined_var",        "undefined variable" },
  { "local p : Player = nil",                  "unknown type" },
  { "local t : table = {}",                    "expected '['" },           -- parse-level, loud
  { "local t : table[string, number] = {}\nlocal n : number = t.k", "cannot initialize" },
  { "local t : table[string, number] = {}\nt.k = \"oops\"",         "cannot store" },
  { "local x = 1 + \"a\"",                     "needs numbers" },
  { "local x = \"a\" - \"b\"",                 "needs numbers" },
  { "local s : number = \"a\" .. \"b\"",       "cannot initialize" },      -- .. yields string
  { "print(x)",                                "undefined variable" },     -- stdlib not seeded yet
}

-- ---------------------------------------------------------------------------
local function run_valid(src)
  local ok_t, toks = pcall(parser.tokenize, src)
  if not ok_t then failed = failed + 1
    print(("FAIL (lex):     %s"):format(src:gsub("\n", " | ")))
    return end
  local ok_p, nodes = pcall(parser.parse, toks)
  if not ok_p then failed = failed + 1
    print(("FAIL (parse):   %s"):format(src:gsub("\n", " | ")))
    return end
  local ok_c, err = pcall(Checker.check, nodes)
  if ok_c then
    passed = passed + 1
  else
    failed = failed + 1
    print(("FAIL (types):   %-44s -> %s"):format(src:gsub("\n", " | "), tostring(err):gsub("^.-: ", "")))
  end
end

local function run_invalid(src, fragment)
  local ok_t, toks = pcall(parser.tokenize, src)
  if not ok_t then
    -- lexer-level rejection counts (e.g. parse-loud cases) if the fragment matches
    if tostring(toks):find(fragment, 1, true) then passed = passed + 1
    else failed = failed + 1; print(("FAIL (lex msg): %s"):format(src)) end
    return end
  local ok_p, nodes = pcall(parser.parse, toks)
  if not ok_p then
    if tostring(nodes):find(fragment, 1, true) then passed = passed + 1
    else failed = failed + 1; print(("FAIL (parse msg): %s"):format(src)) end
    return end
  local ok_c, err = pcall(Checker.check, nodes)
  if not ok_c then
    local msg = tostring(err)
    if msg:find(fragment, 1, true) then
      passed = passed + 1
    else
      failed = failed + 1
      print(("FAIL (fragment): %-40s expected '%s', got '%s'")
        :format(src:gsub("\n", " | "), fragment, msg:gsub("^.-: ", "")))
    end
  else
    failed = failed + 1
    print(("FAIL (no error): %s — accepted but should fail on '%s'")
      :format(src:gsub("\n", " | "), fragment))
  end
end

for _, src in ipairs(valid) do run_valid(src) end
for _, case in ipairs(invalid) do run_invalid(case[1], case[2]) end

print(string.rep("-", 52))
print(("passed: %d  failed: %d"):format(passed, failed))
if failed > 0 then os.exit(1) end
