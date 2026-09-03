-- ast/ast.lua
local AST = {}

-- Statements
function AST.LocalDeclaration(name, value, declaration_type)
    return {
        type = "LocalDeclaration",
        name = name,
        value = value,
        declaration_type = declaration_type
    }
end

function AST.Assignment(variables, values)
    return {
        type = "Assignment",
        variables = variables,
        values = values
    }
end

function AST.FunctionDeclaration(name, parameters, body)
    return {
        type = "FunctionDeclaration",
        name = name,
        parameters = parameters,
        body = body
    }
end

function AST.IfStatement(condition, thenBlock, elseBlock)
    return {
        type = "IfStatement",
        condition = condition,
        thenBlock = thenBlock,
        elseBlock = elseBlock
    }
end

function AST.WhileLoop(condition, body)
    return {
        type = "WhileLoop",
        condition = condition,
        body = body
    }
end

function AST.ForLoop(variable, start, finish, step, body)
    return {
        type = "ForLoop",
        variable = variable,
        start = start,
        finish = finish,
        step = step,
        body = body
    }
end

function AST.ForInLoop(variables, iterators, body)
    return {
        type = "ForInLoop",
        variables = variables,   -- {Identifier(i), Identifier(v)} — list, 1+
        iterators = iterators,   -- {FunctionCall(ipairs, {t})} — expression list
        body = body
    }
end

function AST.RepeatLoop(body, condition)
    return {
        type = "RepeatLoop",
        body = body,
        condition = condition
    }
end

function AST.ReturnStatement(values)
    return {
        type = "ReturnStatement",
        values = values
    }
end

function AST.BreakStatement()
    return {
        type = "BreakStatement"
    }
end

function AST.Block(statements)
    return {
        type = "Block",
        statements = statements
    }
end

-- Expressions
function AST.BinaryOp(left, operator, right)
    return {
        type = "BinaryOp",
        operator = operator,
        left = left,
        right = right
    }
end

function AST.UnaryOp(operator, operand)
    return {
        type = "UnaryOp",
        operator = operator,
        operand = operand
    }
end

function AST.FunctionCall(func, arguments)
    return {
        type = "FunctionCall",
        func = func,
        arguments = arguments
    }
end

function AST.TableConstruction(fields)
    return {
        type = "TableConstruction",
        fields = fields
    }
end

function AST.TableIndex(table, index)
    return {
        type = "TableIndex",
        table = table,
        index = index
    }
end

function AST.TableField(name, value)
    return {
        type = "TableField",
        name = name,
        value = value
    }
end

-- Literals
function AST.Number(value)
    return {
        type = "Number",
        value = value
    }
end

function AST.String(value)
    return {
        type = "String",
        value = value
    }
end

function AST.Boolean(value)
    return {
        type = "Boolean",
        value = value
    }
end

function AST.Nil()
    return {
        type = "Nil"
    }
end

function AST.Identifier(name)
    return {
        type = "Identifier",
        name = name
    }
end

function AST.VarArgs()
    return {
        type = "VarArgs"
    }
end

function AST.Type(type_name, nullable)
    return {
        type = "Type",
        type_name = type_name,
        nullable = nullable
    }
end

function AST.UnionType(type_table)
    return {
        type = "UnionType",
        types = type_table
    }
end

function AST.TableType(form, key_type, value_type)
    return {
        type = "TableType",
        form = form, -- array (table) / map (dictionary) / any (heterogeneous)
        key = key_type,
        value = value_type
    }
end

function AST.MethodCall(object, method_name, arguments)
    return {
        type = "MethodCall",
        object = object,
        method_name = method_name,
        arguments = arguments
    }
end

return AST