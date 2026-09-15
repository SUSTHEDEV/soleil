-- tests/integration.lua — realistic full programs fed through the front end.
-- Run: lua5.1 tests/integration.lua
-- Unlike tests.lua (single-line grammar probes), these are whole-program
-- scripts a real user might write. Every one is valid Lua 5.1.

package.path = package.path .. ";./?.lua"
local parser = require("parser.parser")

local passed, failed = 0, 0
local failures = {}

local programs = {}

local function add(name, src) programs[#programs + 1] = { name, src } end

-- ---------------------------------------------------------------------------
-- 1. A realistic module: closures, recursion, tables, loops
-- ---------------------------------------------------------------------------
add("module script", [=[
-- string utilities module
local M = {}

local VOWELS = "aeiou"

function M.count_vowels(s)
  local n = 0
  for i = 1, #s do
    local c = s:sub(i, i):lower()
    if VOWELS:find(c, 1, true) then
      n = n + 1
    end
  end
  return n
end

function M.split(s, sep)
  local parts = {}
  local start = 1
  while true do
    local pos = s:find(sep, start, true)
    if not pos then break end
    parts[#parts + 1] = s:sub(start, pos - 1)
    start = pos + #sep
  end
  parts[#parts + 1] = s:sub(start)
  return parts
end

function M.memoize(fn)
  local cache = {}
  return function(x)
    if cache[x] == nil then
      cache[x] = fn(x)
    end
    return cache[x]
  end
end

return M
]=])

-- ---------------------------------------------------------------------------
-- 2. Recursion + higher-order functions + varargs
-- ---------------------------------------------------------------------------
add("recursion and varargs", [=[
local function fib(n)
  if n < 2 then return n end
  return fib(n - 1) + fib(n - 2)
end

local function sum(...)
  local total = 0
  local args = { ... }
  for _, v in ipairs(args) do
    total = total + v
  end
  return total
end

local function map(t, fn)
  local out = {}
  for i, v in ipairs(t) do
    out[i] = fn(v)
  end
  return out
end

print(fib(10), sum(1, 2, 3), #map({1, 2, 3}, function(x) return x * 2 end))
]=])

-- ---------------------------------------------------------------------------
-- 3. OOP-flavored Lua (classes as tables + metatable-free dispatch)
-- ---------------------------------------------------------------------------
add("oop style", [=[
local Account = {}
Account.__index = Account

function Account.new(balance)
  local self = setmetatable({}, Account)
  self.balance = balance or 0
  return self
end

function Account:deposit(amount)
  self.balance = self.balance + amount
end

function Account:withdraw(amount)
  if amount > self.balance then
    error("insufficient funds")
  end
  self.balance = self.balance - amount
  return self.balance
end

local acct = Account.new(100)
acct:deposit(50)
print(acct.balance)
]=])

-- ---------------------------------------------------------------------------
-- 4. State machine with while/repeat/break nesting
-- ---------------------------------------------------------------------------
add("state machine", [=[
local queue = { "walk", "attack", "idle" }
local head = 1
local state = "idle"
local ticks = 0

while head <= #queue do
  state = queue[head]
  head = head + 1
  ticks = 0

  repeat
    ticks = ticks + 1
    if state == "attack" and ticks > 3 then
      break
    end
    local busy = ticks < 2
    if not busy then
      print(state, ticks)
    end
  until ticks >= 5
end
]=])

-- ---------------------------------------------------------------------------
-- 5. Table-heavy: nesting, shorthands, iteration
-- ---------------------------------------------------------------------------
add("table playground", [=[
local config = {
  name = "server",
  ports = { 80, 443, 8080 },
  options = {
    debug = false,
    retries = 3,
    handler = function(req)
      return { status = 200, body = req }
    end,
  },
}

local keys = {}
for k, v in pairs(config) do
  keys[#keys + 1] = k
end

local total = 0
for _, p in ipairs(config.ports) do
  total = total + p
end
print(config.name, total, #keys)
]=])

-- ---------------------------------------------------------------------------
-- Single-line constructs that are valid Lua but never probed yet
-- ---------------------------------------------------------------------------
add("swap (multiple assign)", "a, b = b, a")
add("multiple local decl", "local x, y = 1, 2")
add("call sugar: table arg", "f{a = 1}")
add("call sugar: string arg", 'f("x")')
add("positional table", "local t = {1, 2, 3}")
add("computed key", "local t = {[k] = v}")
add("mixed table", "local t = {1, a = 2, [x] = 3}")
add("method on call result", "local s = get():gsub('a', 'b')")
add("long string", "local s = [[hello\nworld]]")
add("long comment", "--[[ ignored ]] local x = 1")
add("nested returns", "local function f() return function() return 1 end end")
add("paren call chain", "local x = (f())(1)")
add("double paren", "local x = ((f))(2)")
add("semicolon block", "do x = 1; y = 2; end")

-- ---------------------------------------------------------------------------
local function try_parse(src)
  local ok_tok, tokens_or_err = pcall(parser.tokenize, src)
  if not ok_tok then return false, tokens_or_err end
  return pcall(parser.parse, tokens_or_err)
end

print(string.rep("-", 46))
for _, prog in ipairs(programs) do
  local ok, err = try_parse(prog[2])
  if ok then
    passed = passed + 1
    print(("ok    %s"):format(prog[1]))
  else
    failed = failed + 1
    failures[#failures + 1] = prog[1]
    local msg = tostring(err):gsub("^.-:%d+: ", "")
    print(("FAIL  %-26s -> %s"):format(prog[1], msg))
  end
end

print(string.rep("-", 46))
print(("passed: %d  failed: %d"):format(passed, failed))
if failed > 0 then os.exit(1) end
