-- Recursive-combos battery: hunt for scoping/nesting gaps like the args-global bug
package.path = package.path .. ";./?.lua"
local parser = require("parser.parser")
local Checker = require("checker.checker")
local Codegen = require("codegen.codegen")

local payloads = {
    { name = "class",   value = 42, stmts = {
        "class P(y : number)",
        "    function get(self : P) : number return self.y end",
        "end",
        "local p = P(42)" }, ret = "p:get()" },
    { name = "fn",      value = 9,  stmts = {
        "local function inner(a : number) : number return a end" }, ret = "inner(9)" },
    { name = "anon",    value = 11, stmts = {
        "local g = function(a : number) : number return a end" }, ret = "g(11)" },
    { name = "multi",   value = 7,  stmts = {
        "local function mr() : number, number return 3, 4 end",
        "local a, b = mr()" }, ret = "a + b" },
    { name = "varargs", value = 5,  stmts = {
        "local function va(a : number, ...) : number return a end" }, ret = "va(5, 1, 2)" },
    { name = "class_fn", value = 13, stmts = {
        "class P(y : number)",
        "    function get(self : P) : number return self.y end",
        "end",
        "local function mk(v : number) : P return P(v) end",
        "local p = mk(13)" }, ret = "p:get()" },
    { name = "f_nullable", value = 9, stmts = {
        "class P(x : number?)",
        "    function get(self : P) : number? return self.x end",
        "end",
        "local p = P(9)" }, rtyp = "number?", ret = "p:get()" },
    { name = "f_ufield", value = "true", stmts = {
        "class P(v : number | string)",
        "    function isnum(self : P) : boolean return type(self.v) == \"number\" end",
        "end",
        "local p = P(1)" }, rtyp = "boolean", ret = "p:isnum()" },
    { name = "f_chain", value = 40, stmts = {
        "class Engine(power : number)",
        "    function rev(self : Engine) : number return self.power end",
        "end",
        "class Car(engine : Engine)",
        "    function drive(self : Car) : number return self.engine:rev() end",
        "end" }, ret = "Car(Engine(40)):drive()" },
    { name = "f_array", value = 3, stmts = {
        "class Bag(items : table[number])",
        "    function first(self : Bag) : number? return self.items[1] end",
        "end" }, rtyp = "number?", ret = "Bag({3, 1, 2}):first()" },
    { name = "f_poly", value = 7, stmts = {
        "class Circle(r : number)",
        "    function area(self : Circle) : number return 3 end",
        "end",
        "class Square(s : number)",
        "    function area(self : Square) : number return 4 end",
        "end",
        "local shapes : table[Circle | Square] = { Circle(1), Square(1) }",
        "local t = 0",
        "for i = 1, 2 do",
        "    local s = shapes[i]",
        "    if s ~= nil then t = t + s:area() end",
        "end" }, ret = "t" },
    { name = "f_super_args", value = 6, stmts = {
        "class A(x : number)",
        "    function get(self : A) : number return self.x end",
        "end",
        "class B(y : number) extends A(y)",
        "    function both(self : B) : number return self.x + self.y end",
        "end" }, ret = "B(3):both()" },
}

local fn_wrappers = {
    { name = "fn_local",  params = 0, build = function(i, body, ret)
        return "local function Wf" .. i .. "()\n" .. body .. "return " .. ret .. "\nend\n", "Wf" .. i .. "()" end },
    { name = "fn_global", params = 0, build = function(i, body, ret)
        return "function Wg" .. i .. "()\n" .. body .. "return " .. ret .. "\nend\n", "Wg" .. i .. "()" end },
    { name = "anon",      params = 0, build = function(i, body, ret)
        return "local Wa" .. i .. " = function()\n" .. body .. "return " .. ret .. "\nend\n", "Wa" .. i .. "()" end },
    { name = "method",    params = 1, build = function(i, body, ret, rtyp)
        rtyp = rtyp or "number"
        return "class Wc" .. i .. "(x : number)\n    function run(self : Wc" .. i .. ") : " .. rtyp .. "\n"
            .. body .. "return " .. ret .. "\n    end\nend\n", "Wc" .. i .. "(0):run()" end },
}

local outer_wrappers = {
    { name = "for", build = function(i, src) return "for wo" .. i .. " = 1, 1 do\n" .. src .. "end\n" end },
    { name = "do",  build = function(i, src) return "do\n" .. src .. "end\n" end },
    { name = "if",  build = function(i, src) return "if true then\n" .. src .. "end\n" end },
}

-- ---- AST invariant walk: self-param must live in a class member; named wrappers must keep params ----
local function walk(node, in_class_body, bad)
    if type(node) ~= "table" then return end
    if node.type then
        if node.type == "FunctionDeclaration" and node.parameters then
            local named = nil
            if node.name and node.name.type == "Identifier" then named = node.name.name end
            for _, p in ipairs(node.parameters) do
                if p.type == "Param" and p.name.name == "self" and not in_class_body then
                    bad[#bad + 1] = "self-param leaked into non-method fn"
                end
            end
            if named and named:match("^W[fga]%d+$") and #node.parameters ~= 0 then
                bad[#bad + 1] = "wrapper fn '" .. named .. "' grew " .. #node.parameters .. " phantom params"
            end
            if named and named:match("^Wr%d+$") and #node.parameters ~= 1 then
                bad[#bad + 1] = "wrapper method 'run' has " .. #node.parameters .. " params"
            end
        end
        if node.type == "LocalDeclaration" and node.values and #node.values == 1
              and node.values[1].type == "FunctionDeclaration"
              and node.names[1] and node.names[1].name:match("^Wa%d+$")
              and #node.values[1].parameters ~= 0 then
            bad[#bad + 1] = "anon wrapper '" .. node.names[1].name .. "' grew phantom params"
        end
        local deep = in_class_body or node.type == "ClassDeclaration"
        for k, v in pairs(node) do
            if k ~= "type" and k ~= "line" and type(v) == "table" then
                walk(v, deep, bad)
            end
        end
    else
        for _, v in ipairs(node) do walk(v, in_class_body, bad) end
    end
end

local counts = { total = 0, parse = 0, check = 0, run = 0, inv = 0, ok = 0 }
local failures = {}
local function report(cat, label, detail)
    counts[cat] = counts[cat] + 1
    failures[#failures + 1] = string.format("[%s] %s\n%s", cat, label, detail or "")
end

-- generate all combos: fn-stack depth 1..3 (innermost first), outer prefix 0..2 from {for, do, if}
local function gen(fnstack, outstack, payload)
    local body, ret = table.concat(payload.stmts, "\n"), payload.ret
    for d = 1, #fnstack do
        body, ret = fn_wrappers[fnstack[d]].build(d, body .. "\n", ret, payload.rtyp)
    end
    local src = body .. "print(" .. ret .. ")\n"
    for d = 1, #outstack do
        src = outer_wrappers[outstack[d]].build(d, src)
    end
    return src
end

local FW, OW = #fn_wrappers, #outer_wrappers
local stacks = {}
local function copy(t)
    local r = {}
    for n = 1, #t do r[n] = t[n] end
    return r
end
local function push_stacks(depth, cur)
    if depth == 0 then stacks[#stacks + 1] = copy(cur) return end
    for w = 1, FW do
        cur[#cur + 1] = w
        push_stacks(depth - 1, cur)
        cur[#cur] = nil
    end
end
for d = 1, 5 do push_stacks(d, {}) end

local prefixes = { {} }
for a = 1, OW do prefixes[#prefixes + 1] = { a } end
for a = 1, OW do for b = 1, OW do prefixes[#prefixes + 1] = { a, b } end end

local function tier_run(label, out, want)
    local okg, emitted = pcall(Codegen.generate, out)
    if not okg then report("run", label, "EMIT: " .. tostring(emitted)) return end
    local fh = io.open("/tmp/_rcb.lua", "w") fh:write(emitted) fh:close()
    local h = io.popen("lua5.1 /tmp/_rcb.lua 2>&1")
    local outp = h:read("*a") h:close()
    if outp ~= tostring(want) .. "\n" then
        report("run", label, "got '" .. tostring(outp) .. "' want '" .. tostring(want) .. "'")
    end
end

local function run_generated(fstack, prefix, payload)
    counts.total = counts.total + 1
    local names = {}
    for _, w in ipairs(fstack) do names[#names + 1] = fn_wrappers[w].name end
    local label = "d" .. #fstack .. "/p" .. #prefix .. " " .. payload.name .. " <- "
        .. table.concat(prefix, ",") .. " | " .. table.concat(names, ">")
    local src = gen(fstack, prefix, payload)

    local ok, tree = pcall(parser.parse, parser.tokenize(src, "soleil"))
    if not ok then report("parse", label, tostring(tree)) return end

    local bad = {}
    walk(tree, false, bad)
    if #bad > 0 then report("inv", label, table.concat(bad, "; ")) end

    local okc, err = pcall(Checker.check, tree)
    if not okc then
        report("check", label, tostring(err):gsub("^.-: type error: ", "") .. "\nSOURCE:\n" .. src)
        return
    end

    -- run tier: fn-depth <= 2 to keep subprocess count sane
    if #fstack <= 2 then tier_run(label, tree, payload.value) end
    counts.ok = counts.ok + 1
end

local deep_prefixes = { {} }
for a = 1, 2 do deep_prefixes[#deep_prefixes + 1] = { a } end
for _, fstack in ipairs(stacks) do
    local pfx = (#fstack <= 3) and prefixes or deep_prefixes
    for _, prefix in ipairs(pfx) do
        for _, payload in ipairs(payloads) do
            run_generated(fstack, prefix, payload)
        end
    end
end

-- ---- hand-written adversarial recursive cases ----
local adversarial = {
    { name = "forward local ref must error", expect_err = true, src =
        "local function a() return b() end\nlocal function b() : number return 1 end" },
    { name = "type used as value must error", expect_err = true, src =
        "local function f()\n    class Q(x : number) end\n    return Q\nend" },
    { name = "container element mismatch must error", expect_err = true, src =
        "local xs : table[number] = {1, \"x\"}" },
    { name = "unguarded union receiver must error", expect_err = true, src =
        "class Circle(r : number)\n    function area(self : Circle) : number return 3 end\nend\n"
     .. "class Square(s : number)\n    function area(self : Square) : number return 4 end\nend\n"
     .. "local shapes : table[Circle | Square] = { Circle(1), Square(1) }\n"
     .. "print(shapes[1]:area())" },
    { name = "union arg mismatch must error", expect_err = true, src =
        "class Circle(r : number)\n    function area(self : Circle) : number return 3 end\nend\n"
     .. "class Square(s : number)\n    function area(self : Square) : number return 4 end\nend\n"
     .. "local shapes : table[Circle | Square] = { Circle(1), Square(1) }\n"
     .. "local s = shapes[1]\nif s ~= nil then print(s:area(1)) end" },
    { name = "super for missing method must error", expect_err = true, src =
        "class A(x : number) end\n"
     .. "class B extends A\n    function f(self : B) : number return super.nope(self) end\nend" },
    { name = "dup local class same scope must error", expect_err = true, src =
        "local function f()\n    class Q(x : number) end\n    class Q(y : number) end\n    return Q(1)\nend" },
    { name = "sibling fns, same local class name", want = "3", src =
        "local function f()\n    class Q(x : number)\n        function g(self : Q) : number return self.x end\n    end\n    return Q(1):g()\nend\n"
     .. "local function h()\n    class Q(x : number)\n        function g(self : Q) : number return self.x end\n    end\n    return Q(2):g()\nend\n"
     .. "print(f() + h())" },
    { name = "call-on-call factory closure", want = "8", src =
        "local function mk(v : number)\n    class P(x : number)\n        function bump(self : P) : number return self.x + v end\n    end\n    return P(v)\nend\n"
     .. "print(mk(4):bump())" },
    { name = "class inside for inside fn", want = "8", src =
        "local function f()\n    for i = 1, 1 do\n        class S(k : number)\n            function get(self : S) : number return self.k end\n        end\n"
     .. "        local s = S(8)\n        return s:get()\n    end\n    return 0\nend\nprint(f())" },
    { name = "sibling method call", want = "12", src =
        "class R(n : number)\n    function twice(self : R) : number return self.n + self.n end\n"
     .. "    function quad(self : R) : number return self:twice() + self:twice() end\nend\nprint(R(3):quad())" },
    { name = "super chain 3 deep", want = "C+B", src =
        "class A(x : number)\n    function who(self : A) : string return \"A\" end\nend\n"
     .. "class B extends A\n    override function who(self : B) : string return \"B\" end\nend\n"
     .. "class C extends B\n    override function who(self : C) : string return \"C+\" .. super.who(self) end\nend\n"
     .. "print(C():who())" },
    { name = "local fn inside method", want = "10", src =
        "class M(n : number)\n    function calc(self : M) : number\n"
     .. "        local function add(a : number, b : number) : number return a + b end\n"
     .. "        return add(self.n, self.n)\n    end\nend\nprint(M(5):calc())" },
    { name = "depth-4 fn>method>fn>method>class", want = "21", src =
        "local function outer()\n    class L1(q : number)\n        function go(self : L1) : number\n"
     .. "            local function mid()\n                class L2(r : number)\n                    function run(self : L2) : number\n"
     .. "                        local function leaf(v : number) : number return v * 3 end\n"
     .. "                        return leaf(self.r + 4)\n                    end\n                end\n"
     .. "                return L2(3):run()\n            end\n            return mid()\n        end\n    end\n"
     .. "    return L1(0):go()\nend\nprint(outer())" },
}

local function run_adversarial(tc)
    counts.total = counts.total + 1
    local ok, tree = pcall(parser.parse, parser.tokenize(tc.src, "soleil"))
    if not ok then
        if tc.expect_err then counts.ok = counts.ok + 1
        else report("parse", tc.name, tostring(tree)) end
        return
    end
    local okc, err = pcall(Checker.check, tree)
    if tc.expect_err then
        if okc then report("check", tc.name, "EXPECTED ERROR but checked clean")
        else counts.ok = counts.ok + 1 end
        return
    end
    if not okc then report("check", tc.name, tostring(err):gsub("^.-: type error: ", "")) return end
    tier_run(tc.name, tree, tc.want)
    counts.ok = counts.ok + 1
end

for _, tc in ipairs(adversarial) do run_adversarial(tc) end

-- ---- report ----
print(string.format("combos: %d | clean: %d | parse: %d | invariant: %d | check: %d | run: %d",
    counts.total, counts.ok, counts.parse, counts.inv, counts.check, counts.run))
if #failures > 0 then
    print("\n--- failures ---")
    local shown = 0
    for _, f in ipairs(failures) do
        if f:sub(1, 8) == "[check] " or shown < 3 then
            print(f)
            if f:sub(1, 8) == "[check] " then shown = shown + 1 end
        end
    end
    -- unique failure signatures
    local sig, order = {}, {}
    for _, f in ipairs(failures) do
        local s = f:match("%[(%w+)%] [^\n]*\n(.*)") or f
        if not sig[s] then sig[s] = 0; order[#order + 1] = s end
        sig[s] = sig[s] + 1
    end
    print("\n--- unique signatures ---")
    for _, s in ipairs(order) do print(sig[s] .. "x: " .. s:sub(1, 160)) end
end
