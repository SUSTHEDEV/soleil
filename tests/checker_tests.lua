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
  -- abstract classes: signatures, bodies, mixed
  "abstract class Animal\n    abstract function speak(self : Animal) : string\nend",
  "abstract class Animal\n    function breathe(self : Animal) print(1) end\nend",
  "abstract class Animal\n    abstract function speak(self : Animal) : string\n    function breathe(self : Animal) print(1) end\nend",
  "abstract class Animal\n    abstract function speak(self : Animal) : string\nend\nclass Dog extends Animal(\"woof\")\n    override function speak(self : Dog) : string return \"woof\" end\nend",
  "abstract class A\n    abstract function f(self : A) : string\nend\nclass Plain function g(self : Plain) end end\nlocal ok : string = \"clean\"",
  -- rule 2: self covariance (narrow ok, same-type ok)
  "class Player(name : string?) function say(self : Player) end end\nclass A extends Player(\"\") override function say(self : A) end end",
  "class Player(name : string?) function say(self : Player) end end\nclass A extends Player(\"\") override function say(self : Player) end end",
  -- no flag leakage: classes after an abstract class parse/check independently
  "abstract class A\n    abstract function f(self : A) : string\nend\nclass Plain function g(self : Plain) end end\nlocal ok : string = \"still parses and checks\"",
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
  -- null operators: ?.
  "class P(x : number) end\nlocal p : P? = nil\nlocal v : number? = p?.x",
  "class P(x : number) end\nlocal p : P? = P(5)\nlocal v : number? = p?.x",
  "class P(x : number) function get(self : P) : number return self.x end end\nlocal p : P? = nil\nlocal v : number? = p?.get()",
  "class C(r : number) function a(self : C) : number return 3 end end\nclass S(s : number) function a(self : S) : number return 4 end end\nlocal t : C | S? = S(1)\nlocal v : number? = t?.a()",
  "local s : string? = \"hi\"\nlocal v : number? = s?.len()",
  -- null operators: ?:
  "local p : number? = nil\nlocal n : number = p ?: 0",
  "local p : number? = 9\nlocal n : number = p ?: 0",
  "local b : boolean? = false\nlocal v : boolean = b ?: true",
  "local xs : table[number] = {}\nlocal n : number = xs[1] ?: 42",
  "local a : number? = nil\nlocal b : number? = 5\nlocal n : number = a ?: b ?: 7",
  -- null operators: !!
  "local p : number? = 1\nlocal n : number = p!!",
  "local xs : table[number] = {7}\nlocal n : number = xs[1]!! + 1",
  -- compositions
  "class P(x : number) end\nlocal p : P? = P(6)\nlocal n : number = (p?.x ?: 0) + 1",
  "class P(x : number) end\nlocal p : P? = P(7)\nlocal n : number = p?.x!! + 1",
  -- field typing
  "class P(x : number?)\n    function get(self : P) : number? return self.x end\nend\nlocal v : number? = P(9):get()",
  "class P(v : number | string)\n    function isnum(self : P) : boolean return type(self.v) == \"number\" end\nend\nlocal b : boolean = P(1):isnum()",
  "class Engine(power : number)\n    function rev(self : Engine) : number return self.power end\nend\nclass Car(engine : Engine)\n    function drive(self : Car) : number return self.engine:rev() end\nend\nlocal n : number = Car(Engine(40)):drive()",
  "class Bag(items : table[number])\n    function first(self : Bag) : number? return self.items[1] end\nend\nlocal v : number? = Bag({3, 1, 2}):first()",
  -- polymorphic containers (union dispatch + nil-guard narrowing)
  "class Circle(r : number)\n    function area(self : Circle) : number return 3 end\nend\n"
    .. "class Square(s : number)\n    function area(self : Square) : number return 4 end\nend\n"
    .. "local shapes : table[Circle | Square] = { Circle(1), Square(1) }\n"
    .. "local t = 0\nfor i = 1, 2 do\n    local s = shapes[i]\n    if s ~= nil then t = t + s:area() end\nend",
  -- inheritance: super-args, fn-local factories, sibling same-name classes, do-blocks
  "class A(x : number)\n    function get(self : A) : number return self.x end\nend\n"
    .. "class B(y : number) extends A(y)\n    function both(self : B) : number return self.x + self.y end\nend\n"
    .. "local n : number = B(3):both()",
  "local function make()\n    class C(x : number)\n        function get(self : C) : number return self.x end\n    end\n    return C(5)\nend\nlocal n : number = make():get()",
  "local function f()\n    class Q(x : number) function g(self : Q) : number return self.x end end\n    return Q(1):g() end\n"
    .. "local function h()\n    class Q(x : number) function g(self : Q) : number return self.x end end\n    return Q(2):g() end",
  "do local z = 7 print(z) end",
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
  -- abstract classes
  { "abstract class A\n    abstract function f(self : A) print(1) end\nend", "abstract methods cannot have bodies" },
  { "class C abstract function f(self : C) end end",              "abstract members are only allowed in abstract classes" },
  { "interface I abstract function f(self : I) end end",          "abstract members are only allowed in abstract classes" },
  -- rule 2: self widening denied
  { "class Player(name : string?) function say(self : Player) end end\nclass A extends Player(\"\") override function say(self : A) end end\nclass Z extends A override function say(self : Player) end end", "incompatible self type" },
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
  -- null operators
  { "local x : number = 1\nprint(x!!)",                          "assertion on a non-nullable" },
  { "local x : number = 1\nprint(x ?: 0)",                       "elvis on a non-nullable" },
  { "class P(x : number) end\nlocal p : P? = P(1)\nprint(p?.nope)", "no such field" },
  { "class P(x : number) function get(self : P) : number return self.x end end\nlocal p : P? = P(1)\nprint(p?.get(9))", "too many arguments" },
  { "class Circle(r : number) function area(self : Circle) : number return 3 end end\n"
    .. "class Square(s : number) function area(self : Square) : number return 4 end end\n"
    .. "local shapes : table[Circle | Square] = { Circle(1), Square(1) }\nprint(shapes[1]:area())", "possibly-nil receiver" },
  { "class Circle(r : number) function area(self : Circle) : number return 3 end end\n"
    .. "class Square(s : number) function area(self : Square) : number return 4 end end\n"
    .. "local shapes : table[Circle | Square] = { Circle(1), Square(1) }\n"
    .. "local s = shapes[1]\nif s ~= nil then print(s:area(1)) end", "too many arguments" },
  -- container element strictness
  { "local xs : table[number] = {1, \"x\"}",                     "cannot initialize" },
  { "class Bag(items : table[number]) end\nlocal b = Bag({9, \"x\"})", "type mismatch" },
  -- class-name discipline
  { "local function f()\n    class Q(x : number) end\n    class Q(y : number) end\n    return Q(1)\nend", "duplicate class name" },
  { "local function f()\n    class Q(x : number) end\n    return Q\nend", "as a value" },
  { "class A(x : number) end\nclass B extends A\n    function f(self : B) : number return super.nope(self) end\nend", "no method" },
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
