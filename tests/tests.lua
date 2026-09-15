-- tests/tests.lua — regression suite for the soleilc front end (lexer + parser)
-- Run: lua5.1 tests/tests.lua
--
-- Valid sources MUST parse. Malformed sources MUST raise a parse error.
-- Add a case here whenever you fix a bug or add a construct, so regressions
-- (like `1.5` lexing as `1[5]`) get caught the moment they reappear.

package.path = package.path .. ";./?.lua"
local parser = require("parser.parser")

local passed, failed = 0, 0

-- ---------------------------------------------------------------------------
-- VALID: every entry must parse without error
-- ---------------------------------------------------------------------------
local valid = {
  -- statements
  "local x = 10",
  "x = 5",
  "local x",
  "print(1, 2)",
  "do local x = 1 end",
  "local x = 1; local y = 2",
  "",
  -- if / elseif / else
  "if x then y = 1 end",
  "if a then elseif b then else end",
  "if a then b = 1 elseif c then d = 2 else e = 3 end",
  -- loops
  "while x < 10 do x = x + 1 end",
  "while a and b do c = 1 end",
  "repeat x = x + 1 until x > 10",
  "repeat local y = 1 until y == 1",
  "repeat until x",
  "for i = 1, 10 do end",
  "for i = 1, 10, 2 do print(i) end",
  "for i, v in ipairs(t) do print(i, v) end",
  "for i = 1, n do while x do y = y + 1 end end",
  "while a do repeat b = b + 1 until b > 5 end",
  "function f() while true do break end end",
  "for i = 1, 10 do if i == 5 then break end end",
  -- functions
  "function foo(a) end",
  "function foo(a, b) return a end",
  "local f = function(a, b) return a end",
  "local f = function() return 1 end",
  "local g = function() while true do break end end",
  -- calls
  "f()",
  "f(1, 2)",
  "a:b(1)",
  "obj:method(x, y)",
  "local x = f(g(1))",
  -- expressions / precedence
  "local x = 1 + 2 * 3",
  "local x = not a",
  "local x = #t",
  "local x = -#t + not b",
  "local s = a .. b",
  "local b = a < 1 and c > 2",
  "local x = a % b",
  "local y = 2^3^4",
  -- postfix / member access
  "local x = a.b.c",
  "local x = a.b",
  "local x = -a.b",
  "local x = a[1].b",
  "local m = t[1][2]",
  "local m = t[a + 1][2]",
  "local x = t.a.b",
  "local x = f(1).a",
  -- tables
  "local t = {}",
  "local t = {a = 1, b = 2}",
  "local t = {a}",
  "local t = {a, b = 2}",
  "local t = {1, 2, 3}",
  "local t = {[k] = v}",
  "local t = {1, a = 2, [x] = 3}",
  "do x = 1 end",
  "do local x = 1; y = 2; end",
  "local s = a .. b",
  "local s = a .. b .. c",
  "local x = f(1)",
  "local x = f(1, 2)",
  "if a then return else b = 1 end",
  "local x = {p = {q = 1}}",
  "local x = {a = 1}.a",
  -- numerals (every Lua 5.1 form)
  "local x = 42",
  "local x = 1.5",
  "local x = 5.",
  "local x = 5.0",
  "local x = .5",
  "local x = 0xFF",
  "local x = 0x1a",
  "local x = 1e10",
  "local x = 1.5e-3",
  "local x = 2E+2",
}

-- ---------------------------------------------------------------------------
-- MALFORMED: every entry must raise a parse error (silence = regression)
-- ---------------------------------------------------------------------------
local malformed = {
  -- unterminated constructs
  "a[",
  "a[1",
  "t[k",
  "x.",
  "f(",
  "f(1, 2",
  "while x do",
  "for i = 1, 2 do",
  "for i, v in t do",
  "function f() return 1",
  "repeat x = 1",
  "if a then b = 1",
  "if a then b = 1 elseif c then",
  "if a then b = 1 else c = 2",
  "{a = 1",                -- bare '{' is not a statement
  -- missing required tokens
  "if then end",
  "while do end",
  "a:b",
  "a:b c",
  -- broken declarations / expressions
  "for = 1, 2 do end",
  "local x =",
  "a +",
  "while",
  "a[",
  "function f(",
  -- numeral edge cases that must not silently misparse
  "local x = 0x",
  "local x = 1e",
  -- string edge cases that must not silently pass
  "local s = \"abc",
  "local s = \"bad\\q\"",
  "local x = f(1,)",
  "for i = 1, , 2 do end",
  "for i = 1, 10, 2, junk do end",
  "local x = 1,,2",
  "x = ,",
}

-- ---------------------------------------------------------------------------
-- KNOWN GAPS: currently accepted silently, but SHOULD be errors.
-- Each entry here is an open work item; move it up to `malformed` when fixed.
-- ---------------------------------------------------------------------------
local known_gaps = {}  -- empty: all known gaps have been fixed and promoted

-- ---------------------------------------------------------------------------
-- tokenize AND parse both under pcall: the lexer can raise malformed-number
-- errors too, so tokenize must never run bare (it's an argument to the old
-- pcall call, evaluated before pcall took control).
local function try_parse(src)
  local ok_tok, tokens_or_err = pcall(parser.tokenize, src)
  if not ok_tok then return false, tokens_or_err end
  return pcall(parser.parse, tokens_or_err)
end

local function run_valid(src)
  local ok = try_parse(src)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print(("FAIL (should parse):    %s"):format(src))
  end
end

local function run_malformed(src)
  local ok = try_parse(src)
  if not ok then
    passed = passed + 1
  else
    failed = failed + 1
    print(("FAIL (should error):    %s"):format(src))
  end
end

for _, src in ipairs(valid) do run_valid(src) end
for _, src in ipairs(malformed) do run_malformed(src) end

for _, src in ipairs(known_gaps) do
  local ok = try_parse(src)
  if not ok then
    -- fixed! promote the case: move it from known_gaps to malformed
    failed = failed + 1
    print(("PROMOTE (gap fixed, move to malformed): %s"):format(src))
  else
    print(("known gap (accepted silently):          %s"):format(src))
  end
end

print(("="):rep(48))
print(("passed: %d  failed: %d"):format(passed, failed))
if failed > 0 then os.exit(1) end
