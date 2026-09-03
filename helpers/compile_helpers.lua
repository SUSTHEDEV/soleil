-- compile_helpers.lua - Logging and debugging utilities
local Helpers = {}

-- Print AST nodes recursively
function Helpers.print_ast(node, indent)
    indent = indent or ""
    
    if not node then
        print(indent .. "nil")
        return
    end
    
    if node.type == "Number" then
        print(indent .. "Number: " .. node.value)
    elseif node.type == "Identifier" then
        print(indent .. "Identifier: " .. node.name)
    elseif node.type == "Boolean" then
        print(indent .. "Boolean: " .. tostring(node.value))
    elseif node.type == "Nil" then
        print(indent .. "Nil")
    elseif node.type == "LocalDeclaration" then
        print(indent .. "LocalDeclaration: " .. (node.name and node.name.name or "?"))
        print(indent .. "  value:")
        Helpers.print_ast(node.value, indent .. "    ")
    elseif node.type == "IfStatement" then
        print(indent .. "IfStatement")
        print(indent .. "  condition:")
        Helpers.print_ast(node.condition, indent .. "    ")
        print(indent .. "  thenBlock:")
        Helpers.print_ast(node.thenBlock, indent .. "    ")
        if node.elseBlock then
            print(indent .. "  elseBlock:")
            Helpers.print_ast(node.elseBlock, indent .. "    ")
        end
    elseif node.type == "Block" then
        print(indent .. "Block:")
        if node.statements then
            for _, stmt in ipairs(node.statements) do
                Helpers.print_ast(stmt, indent .. "  ")
            end
        end
    elseif node.type == "BinaryOp" then
        print(indent .. "BinaryOp: " .. node.operator)
        print(indent .. "  left:")
        Helpers.print_ast(node.left, indent .. "    ")
        print(indent .. "  right:")
        Helpers.print_ast(node.right, indent .. "    ")
    elseif node.type == "Assignment" then
        print(indent .. "Assignment")
        print(indent .. "  variables:")
        for _, var in ipairs(node.variables) do
            Helpers.print_ast(var, indent .. "    ")
        end
        print(indent .. "  values:")
        for _, val in ipairs(node.values) do
            Helpers.print_ast(val, indent .. "    ")
        end
    elseif node.type == "FunctionCall" then
        print(indent .. "FunctionCall")
        print(indent .. "  func:")
        Helpers.print_ast(node.func, indent .. "    ")
        print(indent .. "  arguments:")
        if node.arguments then
            for _, arg in ipairs(node.arguments) do
                Helpers.print_ast(arg, indent .. "    ")
            end
        end
    elseif node.type == "FunctionDeclaration" then
        local fname = node.name and (node.name.name or node.name) or "(anonymous)"
        print(indent .. "FunctionDeclaration: " .. fname)
        print(indent .. "  parameters:")
        if node.parameters then
            for _, param in ipairs(node.parameters) do
                Helpers.print_ast(param, indent .. "    ")
            end
        end
        print(indent .. "  body:")
        if node.body then
            for _, stmt in ipairs(node.body.statements) do
                Helpers.print_ast(stmt, indent .. "    ")
            end
        end
    elseif node.type=="MethodCall" then
        print(indent .. "MethodCall")
        print(indent .. "  object:")
        Helpers.print_ast(node.object, indent .. "    ")
        print(indent .. "  method:")
        Helpers.print_ast(node.method_name, indent .. "    ")
        print(indent .. "  arguments:")
        if node.arguments then
            for _, arg in ipairs(node.arguments) do
                Helpers.print_ast(arg, indent .. "    ")
            end
        end
    elseif node.type == "WhileLoop" then
        print(indent .. "WhileLoop")
        print(indent .. "  condition:")
        Helpers.print_ast(node.condition, indent .. "    ")
        print(indent .. "  body:")
        if node.body then
            for _, stmt in ipairs(node.body.statements) do
                Helpers.print_ast(stmt, indent .. "    ")
            end
        end
    elseif node.type == "ForLoop" then
        print(indent .. "ForLoop")
        print(indent .. "  variable: " .. (node.variable.name or node.variable))
        print(indent .. "  start:")
        Helpers.print_ast(node.start, indent .. "    ")
        print(indent .. "  finish:")
        Helpers.print_ast(node.finish, indent .. "    ")
        print(indent .. "  step:")
        Helpers.print_ast(node.step, indent .. "    ")
        print(indent .. "  body:")
        if node.body then
            for _, stmt in ipairs(node.body.statements) do
                Helpers.print_ast(stmt, indent .. "    ")
            end
        end
    elseif node.type == "ForInLoop" then
        print(indent .. "ForInLoop")
        print(indent .. "  variables:")
        for _, var in ipairs(node.variables) do
            Helpers.print_ast(var, indent .. "    ")
        end
        print(indent .. "  iterators:")
        for _, iter in ipairs(node.iterators) do
            Helpers.print_ast(iter, indent .. "    ")
        end
        print(indent .. "  body:")
        if node.body then
            for _, stmt in ipairs(node.body.statements) do  
                Helpers.print_ast(stmt, indent .. "    ")
            end
        end
    else
        print(indent .. node.type)
    end
end

-- Print tokens for debugging
function Helpers.print_tokens(tokens)
    for _, token in ipairs(tokens) do
        print(token.type .. ": " .. token.value)
    end
end

-- Print AST tree from a list of nodes
function Helpers.print_ast_tree(ast_tree)
    if ast_tree and #ast_tree > 0 then
        print("AST Tree:")
        for _, node in ipairs(ast_tree) do
            Helpers.print_ast(node, "  ")
        end
    else
        print("No AST nodes parsed")
    end
end

return Helpers
