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
  -- Step 3: call checking end-to-end
  "local f = function(x : number) : number return x end\nlocal n : number = f(1)",
  "local f = function(x : number?) : number? return x end\nf()",
  "local c = true\nfunction g() : number if c then return 1 else return 2 end end",
  "function g() : number? end",
  -- Step 4: stdlib records, receivers, iterators
  "print(\"hi\", 1, nil)",
  "local s = \"abc\"\nlocal n : number = s:len()",
  "local s = \"abc\"\nlocal t : string = s:sub(1, 2)",
  "local t : string = string.sub(\"abc\", 1, 2)",
  "local s : string = tostring(5)",
  "local n : number? = tonumber(\"x\")",
  "local t = {}\nsetmetatable(t, {})",
  "pcall(print, 1)",
  "local t : table[string, number] = {}\nfor k, v in pairs(t) do local n2 : number = v end",
  "local t : table[string] = {}\nfor i, v in ipairs(t) do local s2 : string = v end",
  "local t : table[string] = {}\nfor i, v, ghost in ipairs(t) do local n2 : number = i end",
  -- unknown: flows in, checkpointed out
  "local x : unknown = 5",
  "local x : unknown = \"s\"",
  "local x : unknown = 5\nlocal a : any = x",
  "local x : unknown = 5\nlocal s : string = tostring(x)",
  -- classes: declare, instantiate, methods, fields
  "class Player(name : string?, id : number) function say(self : Player, msg : string) print(msg) end end\nlocal p : Player = Player(\"bob\", 42)\np:say(\"hi\")\nlocal n : number = p.id",
  "class Player(name : string?, id : number) function say(self : Player, msg : string) print(msg) end end\nlocal p : Player? = nil",
  "data Pair(a : number, b : number) end",
  "object Counter function inc(self, x : number) : number return x end end",
  "interface Shape(name : string)\n    function area(self : Shape) : number\nend\nclass Circle(x : number, name : string) extends Shape\n    function area(self : Circle) : number return self.x end\nend",
  -- inheritance + rule 7 + super
  "class Player(name : string?) function say(self : Player) end end\nclass A extends Player(\"\") override function say(self : A) end end",
  "class Player(name : string?) function say(self : Player) end end\nclass A extends Player(\"\") override function say(self : A) super.say(self) end end",
  -- multi-return types
  "function g() : number return 1 end\nlocal n : number = g()",
  "function h() : number, string return 1, \"a\" end\nlocal n : number = h()",
  "local f = function() : number, string return 1, \"a\" end\nlocal n : number = f()",
  "interface I\n    function area(self : I) : number\nend\nclass C extends I\n    function area(self : C) : number return 1 end\nend",
  "class B(x : number) function two(self : B) : number, string return 1, \"s\" end end\nclass A extends B(x)\n    override function two(self : A) : number, string return 1, \"s\" end\nend",
  -- call-ret propagation
  "function get() : number, string return 1, \"a\" end\nfunction f2() : number, string return get() end",
  "function f() : number, string return 1, \"a\" end\nlocal a, b = f()\nlocal s : string = b",
  "local f = function(x : number) : number return x end\nlocal n : number = f(7)",
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
  { "print(x)",                                "undefined variable" },
  -- Step 3: call contract
  { "local f = function(x : number) : number return x end\nlocal n : number = f(\"s\")", "argument 1 type mismatch" },
  { "local f = function(x : number) : number return x end\nf(1, 2)", "too many arguments" },
  { "local f = function(x : number) : number return x end\nf()", "missing argument" },
  { "function g() : number end",               "all paths to return" },
  { "local bad = 5\nbad(1)",                   "calling a non-function value" },
  { "local x = ...",                           "outside a varargs function" },
  -- Step 4: stdlib
  { "local s = \"abc\"\nlocal n : number = s:len() + \"x\"", "needs numbers" },
  { "local s = \"abc\"\ns:sub(\"x\")",                  "argument 1 type mismatch" },
  { "local s = \"abc\"\ns:nope()",                        "no such member" },
  { "string.nope()",                           "no such member" },
  { "local t : table[string, number] = {}\nfor k, v in pairs(t) do local s2 : string = v end", "cannot initialize" },
  { "local t : table[string, number] = {}\nfor i, v in ipairs(t) do end", "requires an array table" },
  { "local t : table[string] = {}\nfor i, v, ghost in ipairs(t) do local n : string = ghost end", "cannot initialize" },
  -- unknown: out only to itself or any
  { "local x : unknown = 5\nlocal n : number = x", "cannot initialize" },
  { "local x : unknown = 5\nlocal n = x + 1", "needs numbers" },
  { "local x : unknown = 5\nlocal v = x.k", "cannot index" },
  { "local x : unknown = 5\nx()", "calling a non-function" },
  -- classes: field trust, rule 3, constructors, methods
  { "class Player(name : string?, id : number) function say(self : Player, msg : string) print(msg) end end\nlocal p : Player = Player(\"bob\", 42)\nlocal s : string = p.id", "cannot initialize" },
  { "class Player(name : string?, id : number) function say(self : Player, msg : string) print(msg) end end\nlocal p : Player = Player(\"bob\", 42)\nlocal s : string = p.zzz", "no such field" },
  { "class Player(name : string?, id : number) function say(self : Player, msg : string) print(msg) end end\nlocal p : Player = Player(\"bob\")", "expected 2 constructor arguments" },
  { "class Player(name : string?, id : number) function say(self : Player, msg : string) print(msg) end end\nlocal p : Player = Player(\"bob\", \"s\")", "constructor argument 'id' type mismatch" },
  { "class Player(name : string?, id : number) function say(self : Player, msg : string) print(msg) end end\nlocal p : Player = Player(\"bob\", 42)\np:fly()", "no such method" },
  { "class Player(name : string?, id : number) function say(self : Player, msg : string) print(msg) end end\nlocal p : Player = Player(\"bob\", 42)\np:say(42)", "argument 1 type mismatch" },
  { "interface Shape(name : string)\n    function area(self : Shape) : number\nend\nlocal s : Shape = Shape(\"x\")", "cannot be instantiated" },
  -- inheritance + rule 7 + super
  { "class Player(name : string?) function say(self : Player) end end\nclass A extends Player(\"\") override function fly(self : A) end end", "overrides nothing" },
  { "class Player(name : string?) function say(self : Player) end end\nclass A extends Player(\"\") function say(self : A) end end", "must be declared with 'override'" },
  { "class Player(name : string?) function say(self : Player) end end\nclass A extends Player(\"\") override function say(self : A) super.say() end end", "expects 1 arguments" },
  { "class L function f(self : L) super.f(self) end end", "has no superclass" },
  -- interfaces: satisfaction
  { "interface Shape(name : string)\n    function area(self : Shape) : number\nend\nclass Circle(x : number) extends Shape\nend", "does not implement" },
  { "interface Shape(name : string)\n    function area(self : Shape) : number\nend\nclass Circle(x : number, name : string) extends Shape\n    function area(self : Circle) : string return \"s\" end\nend", "incompatible return type" },
  { "interface Shape function area(self : Shape) : number return 1 end end", "cannot have bodies" },
  -- call-ret propagation
  { "function get() : number, number return 1, 2 end\nfunction f2() : number, string return get() end", "return 2 type mismatch" },
  { "function get() : number return 1 end\nfunction f2() : number, string return get() end", "missing return value 2" },
  { "function f() : number, string return 1, \"a\" end\nlocal a, b = f()\nlocal n : number = b", "cannot initialize" },
  { "local f = function(x : number) : number return x end\nlocal n : number = f(\"s\")", "argument 1 type mismatch" },
  -- multi-return types
  { "local f = function() : string return 1 end",                 "return 1 type mismatch" },
  { "function g() : number return 1 end\nlocal s : string = g()", "cannot initialize" },
  { "function h() : number, string return 1, \"a\" end\nlocal s : string = h()", "cannot initialize" },
  { "function h() : number, string return 1 end",                 "missing return value 2" },
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
