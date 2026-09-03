local lpeg = require("lpeg") -- unused for now, but will be used later for more advanced parsing (better to keep this here for now)
local ast = require("ast.ast")

local reserved_keywords = {
    ["and"] = lpeg.P("and"),
    ["break"] = lpeg.P("break"),
    ["do"] = lpeg.P("do"),
    ["else"] = lpeg.P("else"),
    ["elseif"] = lpeg.P("elseif"),
    ["end"] = lpeg.P("end"),
    ["false"] = lpeg.P("false"),
    ["for"] = lpeg.P("for"),
    ["function"] = lpeg.P("function"),
    ["if"] = lpeg.P("if"),
    ["in"] = lpeg.P("in"),
    ["local"] = lpeg.P("local"),
    ["nil"] = lpeg.P("nil"),
    ["not"] = lpeg.P("not"),
    ["or"] = lpeg.P("or"),
    ["repeat"] = lpeg.P("repeat"),
    ["return"] = lpeg.P("return"),
    ["then"] = lpeg.P("then"),
    ["true"] = lpeg.P("true"),
    ["until"] = lpeg.P("until"),
    ["while"] = lpeg.P("while"),
    ["class"] = lpeg.P("class"),
    ["extends"] = lpeg.P("extends"),
    ["super"] = lpeg.P("super"),
    ["self"] = lpeg.P("self"),
    ["data"] = lpeg.P("data"),
    ["abstract"] = lpeg.P("abstract"),
    ["interface"] = lpeg.P("interface"),
    ["implements"] = lpeg.P("implements"),
} -- later use this for more advanced parsing, but for now, we can just use simple string matching

local reserved_symbols = {
    ["+"] = lpeg.P("+"),
    ["-"] = lpeg.P("-"),
    ["*"] = lpeg.P("*"),
    ["/"] = lpeg.P("/"),
    ["%"] = lpeg.P("%"),
    ["^"] = lpeg.P("^"),
    ["#"] = lpeg.P("#"),
    ["=="] = lpeg.P("=="),
    ["~="] = lpeg.P("~="),
    ["<="] = lpeg.P("<="),
    [">="] = lpeg.P(">="),
    ["<"] = lpeg.P("<"),
    [">"] = lpeg.P(">"),
    ["="] = lpeg.P("="),
    ["("] = lpeg.P("("),
    [")"] = lpeg.P(")"),
    ["{"] = lpeg.P("{"),
    ["}"] = lpeg.P("}"),
    ["["] = lpeg.P("["),
    ["]"] = lpeg.P("]"),
    ["."] = lpeg.P("."),
    [","] = lpeg.P(","),
    [":"] = lpeg.P(":"),
} -- same as above

function parse_error(message)
    error("Parse Error: " .. message)
end

-- Simple tokenizer
local function tokenize(input)
    local cursor = 1
    local tokens = {}
    
    while cursor <= #input do
        local char = input:sub(cursor, cursor)
        
        -- Skip spaces
        if char == " " or char == "\n" or char == "\t" then
            cursor = cursor + 1
        elseif char == "-" and input:sub(cursor, cursor + 1) == "--" then
            -- Skip comments
            cursor = cursor + 2
            while cursor <= #input and input:sub(cursor, cursor) ~= "\n" do
                cursor = cursor + 1
            end    
        -- Match numbers (0-9)
        elseif char:match("%d") then
            local num_start = cursor
            while cursor <= #input and input:sub(cursor, cursor):match("%d") do
                cursor = cursor + 1
            end
            table.insert(tokens, {
                type = "NUMBER",
                value = input:sub(num_start, cursor - 1)
            })
        elseif char == "'" or char == '"' then
            local quote = char
            local str_start = cursor + 1
            cursor = cursor + 1
            while cursor <= #input and input:sub(cursor, cursor) ~= quote do
                cursor = cursor + 1
            end
            table.insert(tokens, {
                type = "STRING",
                value = input:sub(str_start, cursor - 1)
            })
            cursor = cursor + 1
        -- Match identifiers and keywords (letters or _)
        elseif char:match("[a-zA-Z_]") then
            local word_start = cursor
            while cursor <= #input and input:sub(cursor, cursor):match("[a-zA-Z0-9_]") do
                cursor = cursor + 1
            end
            local word = input:sub(word_start, cursor - 1)
            
            if reserved_keywords[word] then
                table.insert(tokens, {
                    type = "KEYWORD",
                    value = word
                })
            else
                table.insert(tokens, {
                    type = "IDENTIFIER",
                    value = word
                })
            end
        -- Handle operators and punctuation
        else
            -- Check for 2-character symbols first
            local two_char = input:sub(cursor, cursor + 1)
            if reserved_symbols[two_char] then
                table.insert(tokens, {
                    type = "SYMBOL",
                    value = two_char
                })
                cursor = cursor + 2
            else
                -- Then single-character symbols
                table.insert(tokens, {
                    type = "SYMBOL",
                    value = char
                })
                cursor = cursor + 1
            end
        end
    end
    
    return tokens
end

function parse(tokens)
    local ast_nodes = {}  -- collect ALL nodes
    local i = 1  -- cursor position
    local parse_expression, parse_statement, parse_if_statement  -- forward declarations
    local comparison_ops = { ["=="]=true, ["~="]=true, ["<"]=true, [">"]=true, ["<="]=true, [">="]=true }
    local function is_comparison(op)
        return comparison_ops[op] or false
    end    
    function parse_primary(function_name_bool)
        local token = tokens[i]
        
        if i <= #tokens and token.type == "NUMBER" then
            i = i + 1
            return ast.Number(tonumber(token.value))
        elseif i <= #tokens and token.type == "STRING" then
            i = i + 1
            return ast.String(token.value)
        elseif i <= #tokens and tokens[i].type == "KEYWORD" and tokens[i].value == "function" then
            i = i + 1  -- skip 'function'
            local args = {}
            local func_name = parse_primary(true)  -- parse function name
            if i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == "(" then
                i = i + 1  -- skip '('
                while i <= #tokens and not (tokens[i].type == "SYMBOL" and tokens[i].value == ")") do
                   local arg = parse_expression()  -- parse argument expression
                   if arg then
                        table.insert(args, arg)
                    end
                    if i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == "," then
                        i = i + 1  -- skip ','
                    end
                    if not arg then 
                        i = i + 1  -- skip unrecognized tokens
                    end
                end
                if i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == ")" then
                    i = i + 1  -- skip ')'
                end
            end
            local body = parse_block{ ["end"] = true }
            if i <= #tokens and tokens[i].type == "KEYWORD" and tokens[i].value == "end" then
                i = i + 1  -- skip 'end'
            end
            return ast.FunctionDeclaration(func_name, args, body)
        elseif i <= #tokens and token.type == "IDENTIFIER" then
            local name = token.value
            i = i + 1
            if function_name_bool then
                return ast.Identifier(name)
            elseif i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == "(" then
                    i = i + 1  -- skip '('
                    local args = {}
                    while i <= #tokens and not (tokens[i].type == "SYMBOL" and tokens[i].value == ")") do
                    local arg = parse_expression()  -- parse argument expression
                    if arg then
                            table.insert(args, arg)
                        end
                        if i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == "," then
                            i = i + 1  -- skip ','
                        end
                        if not arg then 
                            i = i + 1  -- skip unrecognized tokens
                        end
                    end
                    if i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == ")" then
                        i = i + 1  -- skip ')'
                    end
                    return ast.FunctionCall(ast.Identifier(name), args)
            elseif i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == ":" then
                i = i + 1  -- skip ':'
                if i <= #tokens and tokens[i].type == "IDENTIFIER" then
                    local method_name = tokens[i].value
                    i = i + 1
                    if i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == "(" then
                        i = i + 1  -- skip '('
                        local args = {}
                        while i <= #tokens and not (tokens[i].type == "SYMBOL" and tokens[i].value == ")") do
                            local arg = parse_expression()  -- parse argument expression
                            if arg then
                                table.insert(args, arg)
                            end
                            if i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == "," then
                                i = i + 1  -- skip ','
                            end
                            if not arg then 
                                i = i + 1  -- skip unrecognized tokens
                            end
                        end
                        if i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == ")" then
                            i = i + 1  -- skip ')'
                        end
                        return ast.MethodCall(ast.Identifier(name), ast.Identifier(method_name), args)
                    end
                end
            elseif i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == "." then
                i = i + 1  -- skip '.'
                if i <= #tokens and tokens[i].type == "IDENTIFIER" then
                    local field_name = tokens[i].value
                    i = i + 1
                    return ast.TableField(ast.Identifier(name), nil, ast.Identifier(field_name))
                end
            else
                return ast.Identifier(name)
            end
        elseif i <= #tokens and token.type == "KEYWORD" and (token.value == "true" or token.value == "false") then
            i = i + 1
            return ast.Boolean(token.value == "true")
        elseif i <= #tokens and token.type == "KEYWORD" and token.value == "nil" then
            i = i + 1
            return ast.Nil()
        elseif i <= #tokens and token.type == "SYMBOL" and token.value == "(" then
            i = i + 1
            local expr = parse_expression()
            if i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == ")" then
                i = i + 1
            end
            return expr
        end
        return nil
    end

    function parse_for_loop()
        i = i + 1  -- skip 'for'
        local var = read_loop_var()
        if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "=" then
            -- numeric for: for NAME = start, finish [, step] do ... end
            i = i + 1
            local start = parse_expression()
            if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," then
                i = i + 1
            end
            local finish = parse_expression()
            local step
            if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," then
                i = i + 1
                step = parse_expression()
            end
            while i <= #tokens and not (tokens[i].type == "KEYWORD" and tokens[i].value == "do") do
                i = i + 1
            end
            i = i + 1  -- skip 'do'
            local body = parse_block{ ["end"] = true }
            if i <= #tokens and tokens[i].type == "KEYWORD" and tokens[i].value == "end" then
                i = i + 1
            end
            return ast.ForLoop(var, start, finish, step, body)
        end
        -- generic for: for NAME {, NAME} in explist do ... end
        local vars = { var }
        while tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," do
            i = i + 1
            vars[#vars + 1] = read_loop_var()
        end
        if tokens[i] and tokens[i].type == "KEYWORD" and tokens[i].value == "in" then
            i = i + 1
        end
        local iters = {}
        local it = parse_expression()
        if it then
            table.insert(iters, it)
        end
        while tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," do
            i = i + 1
            local next_it = parse_expression()
            if next_it then
                table.insert(iters, next_it)
            end
        end
        while i <= #tokens and not (tokens[i].type == "KEYWORD" and tokens[i].value == "do") do
            i = i + 1
        end
        i = i + 1  -- skip 'do'
        local body = parse_block{ ["end"] = true }
        if i <= #tokens and tokens[i].type == "KEYWORD" and tokens[i].value == "end" then
            i = i + 1
        end
        return ast.ForInLoop(vars, iters, body)
    end

    function parse_repeat_loop()
        i = i + 1  -- skip 'repeat'
        local body = parse_block{ ["until"] = true }
        if i <= #tokens and tokens[i].type == "KEYWORD" and tokens[i].value == "until" then
            i = i + 1
            local condition = parse_expression()
            return ast.RepeatLoop(body, condition)
        end
        parse_error("expected 'until' after repeat block")
    end

    function parse_while_loop()
        i = i + 1  -- skip 'while'
        local condition = parse_expression()
        while i <= #tokens and not (tokens[i].type == "KEYWORD" and tokens[i].value == "do") do
            i = i + 1
        end
        i = i + 1  -- skip 'do'
        local body = parse_block{ ["end"] = true }
        if i <= #tokens and tokens[i].type == "KEYWORD" and tokens[i].value == "end" then
            i = i + 1
        end
        return ast.WhileLoop(condition, body)
    end

    -- read one loop variable (numeric for: exactly one; generic for: one or more)
    function read_loop_var()
        if i <= #tokens and tokens[i].type == "IDENTIFIER" then
            local name = tokens[i].value
            i = i + 1
            return ast.Identifier(name)
        end
        parse_error("expected loop variable name, got ...")  -- when error reporting lands
    end

    function parse_block(terminators)
        local stmts = {}
        while i <= #tokens and not (tokens[i].type == "KEYWORD" and terminators[tokens[i].value]) do
            local stmt = parse_statement()
            if stmt then
                table.insert(stmts, stmt)
            else
                i = i + 1   -- progress guard (unrecognized token)
            end
        end
        return ast.Block(stmts)
    end

    function parse_expression()        -- `or` (loosest)
        local left = parse_and()
        while tokens[i] and tokens[i].type == "KEYWORD" and tokens[i].value == "or" do
            local op = tokens[i].value; i = i + 1
            left = ast.BinaryOp(left, op, parse_and())
        end
        return left
    end

    function parse_assignment()
        local left = parse_expression()          -- parse LHS (Identifier or call, etc.)
        if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "=" then
            i = i + 1
            local values = { parse_expression() }  -- RHS is a full expression
            return ast.Assignment({left}, values)
        end
        return left                                -- no `=` → it's an expression statement
    end

    function parse_and()               -- `and`
        local left = parse_comparison()
        while tokens[i] and tokens[i].type == "KEYWORD" and tokens[i].value == "and" do
            local op = tokens[i].value; i = i + 1
            left = ast.BinaryOp(left, op, parse_comparison())
        end
        return left
    end

    function parse_comparison()        -- == ~= < > <= >=
        local left = parse_addsub()
        while tokens[i] and tokens[i].type == "SYMBOL" and is_comparison(tokens[i].value) do
            local op = tokens[i].value; i = i + 1
            left = ast.BinaryOp(left, op, parse_addsub())
        end
        return left
    end

    function parse_addsub()            -- `+ -`
        local left = parse_muldiv()
        while tokens[i] and tokens[i].type == "SYMBOL" and (tokens[i].value == "+" or tokens[i].value == "-") do
            local op = tokens[i].value; i = i + 1
            left = ast.BinaryOp(left, op, parse_muldiv())
        end
        return left
    end

    function parse_muldiv()            -- `* / %`
        local left = parse_unary()
        while tokens[i] and tokens[i].type == "SYMBOL" and (tokens[i].value == "*" or tokens[i].value == "/" or tokens[i].value == "%") do
            local op = tokens[i].value; i = i + 1
            left = ast.BinaryOp(left, op, parse_unary())
        end
        return left
    end

    function parse_unary()             -- `- not #`
        if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "-" then
            local op = tokens[i].value; i = i + 1
            return ast.UnaryOp(op, parse_unary())
        elseif tokens[i] and tokens[i].type == "KEYWORD" and tokens[i].value == "not" then
            local op = tokens[i].value; i = i + 1
            return ast.UnaryOp(op, parse_unary())
        elseif tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "#" then
            local op = tokens[i].value; i = i + 1
            return ast.UnaryOp(op, parse_unary())
        end
        return parse_power()
    end

    function parse_power()             -- `^` (tightest, RIGHT-assoc)
        local left = parse_primary()
        if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "^" then
            i = i + 1
            left = ast.BinaryOp(left, "^", parse_power())
        end
        return left
    end

    function parse_statement()
        local token = tokens[i]
        if not token then return nil end
        
        if token.type == "KEYWORD" and token.value == "local" then
            i = i + 1  -- skip 'local'
            if i <= #tokens and tokens[i].type == "IDENTIFIER" then
                local name = tokens[i].value
                i = i + 1
                
                -- Check for '='
                if i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == "=" then
                    i = i + 1
                    local value = parse_assignment()
                    return ast.LocalDeclaration(ast.Identifier(name), value)
                else
                    -- local without assignment
                    return ast.LocalDeclaration(ast.Identifier(name), ast.Nil())
                end
            end
        
        elseif token.type == "KEYWORD" and token.value == "if" then
            return parse_if_statement()

        elseif token.type == "KEYWORD" and token.value == "while" then
            return parse_while_loop()

        elseif token.type == "KEYWORD" and token.value == "for" then
            return parse_for_loop()

        elseif token.type == "KEYWORD" and token.value == "break" then
            i = i + 1  -- skip 'break'
            return ast.BreakStatement()
        elseif token.type == "KEYWORD" and token.value == "repeat" then
            return parse_repeat_loop()
        elseif token.type == "IDENTIFIER" then
            return parse_assignment()  -- Handle assignments and function calls
        elseif token.type == "KEYWORD" and token.value == "function" then
            return parse_expression()  -- function expression as a statement
        elseif i <= #tokens and token.type == "KEYWORD" and token.value == "return" then
            i = i + 1  -- skip 'return'
            local return_values = {}
            while i <= #tokens and not (tokens[i].type == "KEYWORD" and tokens[i].value == "end") do
                local ret_val = parse_expression()
                if ret_val then
                    table.insert(return_values, ret_val)
                end
                if not ret_val then 
                    i = i + 1  -- skip unrecognized tokens
                end
            end
            return ast.ReturnStatement(return_values)
        end
    end

    -- Helper function to parse if/elseif statements recursively
    function parse_if_statement()
        i = i + 1  -- skip 'if' or 'elseif'
        
        -- Parse condition
        local condition = parse_expression()
        
        -- Skip to 'then'
        while i <= #tokens and not (tokens[i].type == "KEYWORD" and tokens[i].value == "then") do
            i = i + 1
        end
        i = i + 1  -- skip 'then'
        
       local thenBlock = parse_block{ ["end"] = true, ["else"] = true, ["elseif"] = true }
        
        local elseBlock = nil
        
        -- Handle elseif (chain it as a nested if)
        if i <= #tokens and tokens[i].type == "KEYWORD" and tokens[i].value == "elseif" then
            elseBlock = parse_if_statement()  -- recursive call for elseif chain
        
        -- Handle else
        elseif i <= #tokens and tokens[i].type == "KEYWORD" and tokens[i].value == "else" then
            i = i + 1  -- skip 'else'
            elseBlock = parse_block{ ["end"] = true }
        end
        
        -- Skip 'end' if this is an if (not elseif)
        if i <= #tokens and tokens[i].type == "KEYWORD" and tokens[i].value == "end" then
            i = i + 1  -- skip 'end'
        end
        
        return ast.IfStatement(condition, thenBlock, elseBlock)
    end
    
    while i <= #tokens do
        local token = tokens[i]
        
        -- Pattern: local IDENTIFIER = VALUE
        if token.type == "KEYWORD" and token.value == "local" then
            i = i + 1  -- skip 'local'
            if i <= #tokens and tokens[i].type == "IDENTIFIER" then
                local name = tokens[i].value
                i = i + 1
                
                -- Check for '='
                if i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == "=" then
                    i = i + 1
                    local value = parse_expression()
                    table.insert(ast_nodes, ast.LocalDeclaration(ast.Identifier(name), value))
                else
                    -- local without assignment
                    table.insert(ast_nodes, ast.LocalDeclaration(ast.Identifier(name), ast.Nil()))
                end
            end
        
        -- Pattern: if CONDITION then ... end (with optional elseif/else)
        elseif token.type == "KEYWORD" and token.value == "if" then
            table.insert(ast_nodes, parse_if_statement())

        elseif token.type == "KEYWORD" and token.value == "while" then
            table.insert(ast_nodes, parse_while_loop())

        elseif token.type == "KEYWORD" and token.value == "for" then
            table.insert(ast_nodes, parse_for_loop())

        elseif token.type == "KEYWORD" and token.value == "break" then
            i = i + 1  -- skip 'break'
            table.insert(ast_nodes, ast.BreakStatement())
        elseif token.type == "KEYWORD" and token.value == "repeat" then
            table.insert(ast_nodes, parse_repeat_loop())
        elseif token.type == "IDENTIFIER" then
            local stmt = parse_assignment()
            if stmt then
                table.insert(ast_nodes, stmt)
            end
            if not stmt then 
                i = i + 1  -- skip unrecognized tokens
            end        
        elseif token.type == "KEYWORD" and token.value == "function" then
            table.insert(ast_nodes, parse_expression())  -- function expression as a statement
        elseif i <= #tokens and token.type == "KEYWORD" and token.value == "return" then
            i = i + 1  -- skip 'return'
            local return_values = {}
            while i <= #tokens and not (tokens[i].type == "KEYWORD" and tokens[i].value == "end") do
                local ret_val = parse_expression()
                if ret_val then
                    table.insert(return_values, ret_val)
                end
                if not ret_val then 
                    i = i + 1  -- skip unrecognized tokens
                end
            end
            table.insert(ast_nodes, ast.ReturnStatement(return_values))
        else
            i = i + 1  -- skip unrecognized tokens
        end
    end
    
    return ast_nodes  -- return the array of nodes
end

return {
    tokenize = tokenize,
    parse = parse
}