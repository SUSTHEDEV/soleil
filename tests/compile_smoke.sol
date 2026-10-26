class P(name : string)
    function hi(self : P) : string return "hey " .. self.name end
end
print(P("jit64"):hi())
