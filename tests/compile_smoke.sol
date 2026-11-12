class P(name : string)
    function hi(self : P) : string return "hey " .. self.name end
end
print(P("jit64"):hi())

local a_table: table[unknown, unknown] = {}

api: number = 15

if type(api) == number then

