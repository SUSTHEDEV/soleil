class Player(name : string, id : number)
    function say(self : Player, msg : string)
        print(self.name .. " says: " .. msg)
    end
    function id_value(self : Player) : number
        return self.id
    end
end

class Admin(role : string) extends Player("admin", 0)
    override function say(self : Admin, msg : string)
        print("[" .. self.role .. "] " .. msg)
    end
end

object Registry
    function put(self, k : string, v : number)
        print("stored " .. k)
    end
end

local p : Player = Player("bob", 42)
p:say("hello")
local n : number = p:id_value()
print("id is " .. tostring(n))

local a : Admin = Admin("root")
a:say("override works")

local x : Player = a
x:say("dynamic through Player")

Registry:put("key", 1)
