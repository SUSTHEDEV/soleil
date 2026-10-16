package.path = package.path .. ";./?.lua"
local parser = require("parser.parser")
local Checker = require("checker.checker")
local Codegen = require("codegen.codegen")

local pass, fail = 0, 0
local function run(src, label, expect)
  local ok_p, r = pcall(parser.parse, parser.tokenize(src, "soleil"))
  if not ok_p then fail = fail + 1; print("FAIL (parse) " .. label .. ": " .. tostring(r):gsub("^.-:%d+: ", "")); return end
  local ok_c, r2 = pcall(Checker.check, r)
  if not ok_c then fail = fail + 1; print("FAIL (check) " .. label .. ": " .. tostring(r2):gsub("^.-: type error: ", "")); return end
  local out = io.open("/tmp/daily_gen.lua", "w")
  out:write(Codegen.generate(r))
  out:close()
  local ok_r, got = pcall(dofile, "/tmp/daily_gen.lua")
  if not ok_r then fail = fail + 1; print("FAIL (run)   " .. label .. ": " .. tostring(got):gsub("^.-:%d+: ", "")); return end
  if expect ~= nil and got ~= expect then
    fail = fail + 1
    print("FAIL (output) " .. label .. ": expected [" .. tostring(expect) .. "], got [" .. tostring(got) .. "]")
    return
  end
  pass = pass + 1
end

-- 1. bank account: state mutation, returns final balance
run([[
class Account(balance : number)
    function deposit(self : Account, amount : number) : number
        self.balance = self.balance + amount
        return self.balance
    end
    function withdraw(self : Account, amount : number) : number
        if self.balance >= amount then
            self.balance = self.balance - amount
        end
        return self.balance
    end
end
local acct : Account = Account(100)
acct:deposit(50)
return acct:withdraw(30)
]], "bank account", 120)

-- 2. employee/manager: override through base-typed var (returns the title)
run([[
class Employee(name : string)
    function title(self : Employee) : string
        return self.name
    end
end
class Manager(name : string, reports : number) extends Employee("mgr")
    override function title(self : Manager) : string
        return self.name .. " (" .. tostring(self.reports) .. ")"
    end
end
local e : Employee = Employee("alice")
local m : Manager = Manager("bob", 3)
return e:title() .. " / " .. m:title()
]], "employee/manager polymorphism", "alice / bob (3 reports)")

-- 3. builder: method chaining through self
run([[
class Builder(parts : table[string, string])
    function set(self : Builder, k : string, v : string) : Builder
        self.parts[k] = v
        return self
    end
    function get(self : Builder, k : string) : string
        return self.parts[k]
    end
end
local b : Builder = Builder({ mode = "fast" })
b:set("level", "high")
return b:get("level") .. "/" .. b:get("mode")
]], "method chaining", "high/fast")

-- 4. data class formatting
run([[
data User(name : string, admin : boolean)
    function label(self : User) : string
        if self.admin then
            return self.name .. " (admin)"
        end
        return self.name
    end
end
local u = User("carol", true)
return u:label()
]], "data class formatting", "carol (admin)")

-- 5. interface consumers: two impls through the interface type
run([[
interface Greeter
    function greet(self : Greeter) : string
end
class Formal extends Greeter
    function greet(self : Formal) : string
        return "Good evening."
    end
end
class Casual extends Greeter
    function greet(self : Casual) : string
        return "Hey!"
    end
end
local f : Greeter = Formal()
local c : Greeter = Casual()
return f:greet() .. " / " .. c:greet()
]], "interface consumers", "Good evening. / Hey!")

-- 6. the factory idiom: local class closing over state
run([[
local function makeCounter(start : number)
    class Counter
        function bump(self : Counter) : number
            start = start + 1
            return start
        end
    end
    return Counter()
end
local c = makeCounter(10)
c:bump()
return c:bump()
]], "factory idiom", 12)

print("=============================")
print("passed: " .. pass .. "  failed: " .. fail)
if fail > 0 then os.exit(1) end
