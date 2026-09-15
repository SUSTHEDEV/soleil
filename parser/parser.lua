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
    -- NOTE: "self" is deliberately NOT a keyword — it's an ordinary identifier
    -- (Lua convention, SPEC §4 rule 2). Do not add it back here.
    -- Future Soleil keywords (class, extends, super, data, abstract,
    -- interface, implements) must be CONTEXTUAL: matched as IDENTIFIER by
    -- value in their grammar position (like "table" in type position).
    -- Reserving them breaks real Lua code that uses them as identifiers.
}

local ESCAPES = {
    ["n"] = "\n", ["t"] = "\t", ["r"] = "\r", ["a"] = "\a",
    ["b"] = "\b", ["f"] = "\f", ["v"] = "\v",
    ["\\"] = "\\", ["\""] = "\"", ["'"] = "'",
}

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
    [".."] = lpeg.P(".."),
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

    -- shebang: Lua ignores a first line starting with '#'
    if input:sub(1, 1) == "#" then
        local nl = input:find("\n", 1, true)
        cursor = nl and (nl + 1) or (#input + 1)
    end

    while cursor <= #input do
        local char = input:sub(cursor, cursor)
        
        -- Skip spaces
        if char == " " or char == "\n" or char == "\t" then
            cursor = cursor + 1
        elseif char == "-" and input:sub(cursor, cursor + 1) == "--" then
            -- Skip comments
            cursor = cursor + 2                      -- now just past '--'
            local c_open = input:match("^%[=*%[", cursor)    -- long comment --[[ ... ]] / --[=[ ... ]=]
            if c_open then
                local c_level = #c_open - 2
                local c_close_pat = "]" .. string.rep("=", c_level) .. "]"
                local close = input:find(c_close_pat, cursor + #c_open, true)
                if not close then parse_error("unterminated long comment") end
                cursor = close + #c_close_pat
            else                                     -- line comment
                while cursor <= #input and input:sub(cursor, cursor) ~= "\n" do
                    cursor = cursor + 1
                end
            end
        -- Match numbers (0-9, e-notation, hex, float)
        elseif char:match("%d") or (char == "." and input:sub(cursor + 1, cursor + 1):match("%d")) then
            local num = input:match("^0[xX][0-9a-fA-F]+", cursor)
                    or input:match("^%d+%.?%d*[eE][+-]?%d+", cursor)
                    or input:match("^%d+%.?%d*", cursor)
                    or input:match("^%.%d+", cursor)

            -- prefix promised a longer numeral that never completed -> error, don't fall back
            if input:match("^0[xX]", cursor) and not num:match("^0[xX]") then
                parse_error("malformed number: incomplete hex literal")
            end
            if input:match("^%d+%.?%d*[eE]", cursor) and not input:match("^%d+%.?%d*[eE][+-]?%d+", cursor) then
                parse_error("malformed number: incomplete exponent")
            end

            cursor = cursor + #num
            table.insert(tokens, { type = "NUMBER", value = num })
        elseif char == "'" or char == '"' then
            -- short string: decode escapes at tokenize time — the token value
            -- is the true string; no downstream stage ever sees a backslash
            local quote = char
            cursor = cursor + 1                       -- skip opening quote
            local parts = {}
            while true do
                if cursor > #input then
                    parse_error("unterminated string")
                end
                local c = input:sub(cursor, cursor)
                if c == quote then
                    cursor = cursor + 1
                    break
                elseif c == "\\" then
                    local esc = input:sub(cursor + 1, cursor + 1)
                    if esc == "\n" then
                        -- backslash + real newline = newline in the string (Lua 5.1)
                        table.insert(parts, "\n")
                        cursor = cursor + 2
                    else
                        local decoded = ESCAPES[esc]
                        if decoded then
                            table.insert(parts, decoded)
                            cursor = cursor + 2
                        elseif esc:match("%d") then
                            local digits = input:match("^%d%d?%d?", cursor + 1)   -- \ddd (1-3 digits)
                            table.insert(parts, string.char(tonumber(digits)))
                            cursor = cursor + 1 + #digits
                        else
                            parse_error("invalid escape sequence '\\" .. esc .. "'")
                        end
                    end
                else
                    if c == "\n" then
                        parse_error("unterminated string")     -- no literal newline in short strings
                    end
                    table.insert(parts, c)
                    cursor = cursor + 1
                end
            end
            table.insert(tokens, {
                type = "STRING",
                value = table.concat(parts)
            })
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
            -- Long string [[ ... ]], [=[ ... ]=], [[= levels must match]] ...
            -- raw content, spans newlines; embedded [[ is safe at level >= 1
            local long_open = input:match("^%[=*%[", cursor)
            if long_open then
                local level = #long_open - 2                              -- count of '='
                local close_pat = "]" .. string.rep("=", level) .. "]"
                local content_start = cursor + #long_open
                local close = input:find(close_pat, content_start, true)
                if not close then
                    parse_error("unterminated long string")
                end
                table.insert(tokens, { type = "STRING", value = input:sub(content_start, close - 1) })
                cursor = close + #close_pat
            else
                -- Check for 3-character symbols first
                local three_char = input:sub(cursor, cursor + 2)
                if three_char == "..." then
                    table.insert(tokens, { type = "SYMBOL", value = three_char })
                    cursor = cursor + 3
                else
                    -- Then check for 2-character symbols next
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
    function parse_primary()
        if i > #tokens then
            parse_error("unexpected end of input")
        end

        local token = tokens[i]
        
        if i <= #tokens and token.type == "NUMBER" then
            i = i + 1
            return ast.Number(tonumber(token.value))
        elseif i <= #tokens and token.type == "STRING" then
            i = i + 1
            return ast.String(token.value)
        elseif i <= #tokens and tokens[i].type == "KEYWORD" and tokens[i].value == "function" then
            i = i + 1  -- skip 'function'
            -- function name: Name {'.' Name} [':' Name] — absent = anonymous
            local func_name
            local is_method = false
            if i <= #tokens and tokens[i].type == "IDENTIFIER" then
                func_name = ast.Identifier(tokens[i].value)
                i = i + 1
                while i <= #tokens and tokens[i].type == "SYMBOL"
                      and (tokens[i].value == "." or tokens[i].value == ":") do
                    local sep = tokens[i].value
                    i = i + 1
                    if not (i <= #tokens and tokens[i].type == "IDENTIFIER") then
                        parse_error("expected name after '" .. sep .. "' in function name")
                    end
                    func_name = ast.TableIndex(func_name, ast.Identifier(tokens[i].value))
                    if sep == ":" then is_method = true end
                    i = i + 1
                end
            end
            -- '(' is the param list opener — required either way
            if not (i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == "(") then
                parse_error("expected '(' after function name")
            end
            i = i + 1  -- skip '('
            local args = {}
            local has_varargs = false
            while i <= #tokens and not (tokens[i].type == "SYMBOL" and tokens[i].value == ")") do
                if tokens[i].type == "SYMBOL" and tokens[i].value == "..." then
                    i = i + 1
                    has_varargs = true
                else
                    local arg = parse_expression()
                    if arg then table.insert(args, arg) end
                    if not arg then i = i + 1 end
                end
                if i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == "," then
                    i = i + 1
                end
            end
            if has_varargs then
                table.insert(args, ast.VarArgs())   -- always last: {a, b, VarArgs}
            end
            if not (i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == ")") then
                parse_error("expected ')'")
            end
            i = i + 1  -- skip ')'
            if is_method then
                table.insert(args, 1, ast.Identifier("self"))  -- function a:b() gets implicit self
            end
            local body = parse_block{ ["end"] = true }
            if not tokens[i] or tokens[i].type ~= "KEYWORD" or tokens[i].value ~= "end" then
                parse_error("expected 'end' after function body")
            end
            i = i + 1  -- skip 'end'
            return ast.FunctionDeclaration(func_name, args, body)
        elseif i <= #tokens and token.type == "IDENTIFIER" then
            -- calls, method calls, and indexing are postfix now (parse_postfix)
            i = i + 1
            return ast.Identifier(token.value)
        elseif i <= #tokens and token.type == "KEYWORD" and (token.value == "true" or token.value == "false") then
            i = i + 1
            return ast.Boolean(token.value == "true")
        elseif i <= #tokens and token.type == "KEYWORD" and token.value == "nil" then
            i = i + 1
            return ast.Nil()
        elseif token.type == "SYMBOL" and token.value == "{" then
            return parse_table()
        elseif i <= #tokens and token.type == "SYMBOL" and token.value == "(" then
            i = i + 1
            local expr = parse_expression()
            if i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == ")" then
                i = i + 1
            end
            return expr
        elseif token.type == "SYMBOL" and token.value == "..." then
            i = i + 1
            return ast.VarArgs()
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
            if not start then parse_error("expected start expression in numeric for") end
            if not (tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == ",") then
                parse_error("expected ',' in numeric for")
            end
            i = i + 1
            local finish = parse_expression()
            if not finish then parse_error("expected limit expression in numeric for") end
            local step
            if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," then
                i = i + 1
                step = parse_expression()
                if not step then parse_error("expected step expression in numeric for") end
            end
            if not (tokens[i] and tokens[i].type == "KEYWORD" and tokens[i].value == "do") then
                parse_error("expected 'do' in numeric for")
            end
            i = i + 1  -- skip 'do'
            local body = parse_block{ ["end"] = true }
            if not tokens[i] or tokens[i].type ~= "KEYWORD" or tokens[i].value ~= "end" then
                parse_error("expected 'end' after for loop body")
            end
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
        if not it then parse_error("expected expression after 'in'") end
        table.insert(iters, it)
        while tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," do
            i = i + 1
            local next_it = parse_expression()
            if not next_it then parse_error("expected expression after ',' in generic for") end
            table.insert(iters, next_it)
        end
        if not (tokens[i] and tokens[i].type == "KEYWORD" and tokens[i].value == "do") then
            parse_error("expected 'do' in generic for")
        end
        i = i + 1  -- skip 'do'
        local body = parse_block{ ["end"] = true }
        if not tokens[i] or tokens[i].type ~= "KEYWORD" or tokens[i].value ~= "end" then
            parse_error("expected 'end' after for loop body")
        end
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
            if not condition then
                parse_error("expected condition")
            end
            return ast.RepeatLoop(body, condition)
        end
        parse_error("expected 'until' after repeat block")
    end

    function parse_while_loop()
        i = i + 1  -- skip 'while'
        local condition = parse_expression()
        if not condition then
            parse_error("expected condition")
        end
        while i <= #tokens and not (tokens[i].type == "KEYWORD" and tokens[i].value == "do") do
            i = i + 1
        end
        i = i + 1  -- skip 'do'
        local body = parse_block{ ["end"] = true }
        if not tokens[i] or tokens[i].type ~= "KEYWORD" or tokens[i].value ~= "end" then
            parse_error("expected 'end' after while loop body")
        end
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
        local left = parse_expression()
        if not left then parse_error("expected expression") end
        local targets = nil
        -- more targets: a, b = ...  (comma loop must wrap AROUND the '=' check,
        -- since the '=' only appears after ALL targets)
        while tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," do
            if not targets then targets = { left } end
            i = i + 1
            left = parse_expression()
            if not left then parse_error("expected assignment target after ','") end
            targets[#targets + 1] = left
        end
        if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "=" then
            if not targets then targets = { left } end
            i = i + 1
            local values = {}
            while true do
                local v = parse_expression()
                if not v then parse_error("expected expression after '='") end
                values[#values + 1] = v
                if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," then
                    i = i + 1
                else break end
            end
            for _, t in ipairs(targets) do
                if t.type ~= "Identifier" and t.type ~= "TableIndex" then
                    parse_error("cannot assign to this expression")
                end
            end
            return ast.Assignment(targets, values)
        end
        return left
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
        local left = parse_concat()
        while tokens[i] and tokens[i].type == "SYMBOL" and is_comparison(tokens[i].value) do
            local op = tokens[i].value; i = i + 1
            left = ast.BinaryOp(left, op, parse_concat())
        end
        return left
    end

    function parse_concat()            -- `..` (right-assoc in Lua)
        local left = parse_addsub()
        if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == ".." then
            i = i + 1
            left = ast.BinaryOp(left, "..", parse_concat())
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
        local left = parse_postfix()
        if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "^" then
            i = i + 1
            left = ast.BinaryOp(left, "^", parse_power())
        end
        return left
    end

    -- parses '(' args ')' — call arguments, with strict ')' handling
    function parse_args()
        i = i + 1  -- skip '('
        local args = {}
        while i <= #tokens and not (tokens[i].type == "SYMBOL" and tokens[i].value == ")") do
            local arg = parse_expression()
            if arg then
                table.insert(args, arg)
            end
            if i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == "," then
                i = i + 1  -- skip ','
                if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == ")" then
                    parse_error("expected expression after ','")
                end
            end
            if not arg then
                parse_error("expected expression in arguments")
            end
        end
        if not (i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == ")") then
            parse_error("expected ')'")
        end
        i = i + 1  -- skip ')'
        return args
    end

    function parse_postfix()
        local expr = parse_primary()
        while i <= #tokens do
            local t = tokens[i]
            if t.type == "SYMBOL" and t.value == "." then
                i = i + 1
                if not (i <= #tokens and tokens[i].type == "IDENTIFIER") then
                    parse_error("expected field name after '.'")
                end
                expr = ast.TableIndex(expr, ast.Identifier(tokens[i].value))
                i = i + 1
            elseif t.type == "SYMBOL" and t.value == "[" then
                i = i + 1                       -- skip '['
                local index = parse_expression()
                if not (i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == "]") then
                    parse_error("expected ']' after table index")
                end
                i = i + 1                       -- skip ']'
                expr = ast.TableIndex(expr, index)
            elseif t.type == "SYMBOL" and t.value == "(" then
                expr = ast.FunctionCall(expr, parse_args())
            elseif t.type == "SYMBOL" and t.value == ":" then
                i = i + 1
                if not (i <= #tokens and tokens[i].type == "IDENTIFIER") then
                    parse_error("expected method name after ':'")
                end
                local method_name = tokens[i].value
                i = i + 1
                -- method call args: a:b(...) | a:b{...} | a:b"..."
                local nxt = tokens[i]
                if nxt and nxt.type == "SYMBOL" and nxt.value == "(" then
                    expr = ast.MethodCall(expr, ast.Identifier(method_name), parse_args())
                elseif nxt and nxt.type == "SYMBOL" and nxt.value == "{" then
                    expr = ast.MethodCall(expr, ast.Identifier(method_name), { parse_table() })
                elseif nxt and nxt.type == "STRING" then
                    expr = ast.MethodCall(expr, ast.Identifier(method_name), { ast.String(nxt.value) })
                    i = i + 1
                else
                    parse_error("expected '(', '{', or string after method name")
                end
            elseif t.type == "SYMBOL" and t.value == "{" then
                -- call sugar: f{ ... }  ≡  f({ ... })
                expr = ast.FunctionCall(expr, { parse_table() })
            elseif t.type == "STRING" then
                -- call sugar: f"str"  ≡  f("str")
                expr = ast.FunctionCall(expr, { ast.String(t.value) })
                i = i + 1
            else
                break
            end
        end
        return expr
    end

    function parse_statement()
        local token = tokens[i]
        if not token then return nil end
        
        if token.type == "KEYWORD" and token.value == "local" then
            i = i + 1  -- skip 'local'
            if tokens[i] and tokens[i].type == "KEYWORD" and tokens[i].value == "function" then
                -- local function Name(...) ... end
                -- desugars to: LocalDeclaration(Name, <anonymous function>)
                local fn = parse_primary()
                if not fn or fn.type ~= "FunctionDeclaration" or not fn.name then
                    parse_error("expected function name after 'local function'")
                end
                if fn.name.type ~= "Identifier" then
                    parse_error("local function name must be a plain identifier")
                end
                local name = fn.name
                fn.name = nil
                return ast.LocalDeclaration({ name }, { fn })
            end
            local names = {}
            while true do
                if not (tokens[i] and tokens[i].type == "IDENTIFIER") then
                    parse_error("expected name in local declaration")
                end
                names[#names + 1] = ast.Identifier(tokens[i].value)
                i = i + 1
                if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," then
                    i = i + 1
                else break end
            end
            local values = {}
            if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "=" then
                i = i + 1
                while true do
                    local v = parse_expression()
                    if not v then parse_error("expected expression") end
                    values[#values + 1] = v
                    if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," then
                        i = i + 1
                    else break end
                end
            end
            return ast.LocalDeclaration(names, values)

        elseif token.type == "KEYWORD" and token.value == "do" then
            i = i + 1  -- skip 'do'
            local body = parse_block{ ["end"] = true }
            if not tokens[i] or tokens[i].type ~= "KEYWORD" or tokens[i].value ~= "end" then
                parse_error("expected 'end' after do block")
            end
            i = i + 1
            return ast.Block(body)

        elseif token.type == "SYMBOL" and token.value == "(" then
            -- parenthesized expression statement: (function() end)() etc.
            return parse_assignment()

        elseif token.type == "SYMBOL" and token.value == "{" then
            parse_error("unexpected '{' — a table constructor is an expression, not a statement")

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
            -- return [explist] — stops at block terminators (return ends a block)
            local return_values = {}
            if tokens[i] and not (tokens[i].type == "KEYWORD"
                  and (tokens[i].value == "end" or tokens[i].value == "else" or tokens[i].value == "elseif"))
                  and not (tokens[i].type == "SYMBOL" and tokens[i].value == ";") then
                local ret_val = parse_expression()
                if not ret_val then parse_error("expected expression in return statement") end
                table.insert(return_values, ret_val)
                while tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," do
                    i = i + 1
                    ret_val = parse_expression()
                    if not ret_val then parse_error("expected expression after ',' in return statement") end
                    table.insert(return_values, ret_val)
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
        if not condition then
            parse_error("expected condition")
        end
        
        -- Skip to 'then'
        while i <= #tokens and not (tokens[i].type == "KEYWORD" and tokens[i].value == "then") do
            i = i + 1
        end
        i = i + 1  -- skip 'then'
        
       local thenBlock = parse_block{ ["end"] = true, ["else"] = true, ["elseif"] = true }
        
        local elseBlock = nil
        
        if not tokens[i] then
            parse_error("expected 'end', 'else', or 'elseif' after if block")
        end

        local consumed_end = false

        if i <= #tokens and tokens[i].type == "KEYWORD" and tokens[i].value == "elseif" then
            elseBlock = parse_if_statement()   -- recursive call consumes the shared 'end'
            consumed_end = true
        elseif i <= #tokens and tokens[i].type == "KEYWORD" and tokens[i].value == "else" then
            i = i + 1  -- skip 'else'
            elseBlock = parse_block{ ["end"] = true }
        end

        if not consumed_end then
            if not tokens[i] or tokens[i].type ~= "KEYWORD" or tokens[i].value ~= "end" then
                parse_error("expected 'end' after if statement")
            end
            i = i + 1
        end
        
        return ast.IfStatement(condition, thenBlock, elseBlock)
    end
    
    function parse_table()
        i = i + 1
        local fields = {}
        while i <= #tokens and not (tokens[i].type == "SYMBOL" and tokens[i].value == "}") do
            if tokens[i].type == "SYMBOL" and (tokens[i].value == "," or tokens[i].value == ";") then
                i = i + 1                                -- skip ',' or ';' (both are field separators)
            elseif tokens[i].type == "IDENTIFIER" then
                -- three sub-cases, decided by ONE-token lookahead:
                --   {name = value}  pair
                --   {name,} / {name}  shorthand (≡ {["name"] = name})
                --   {name[expr]} / {name.k} / {name(...)}  positional entry whose
                --     expression merely STARTS with an identifier
                local nxt = tokens[i + 1]
                if nxt and nxt.type == "SYMBOL" and nxt.value == "=" then
                    local name = ast.Identifier(tokens[i].value)
                    i = i + 2
                    local value = parse_expression()
                    if not value then parse_error("expected value after '='") end
                    table.insert(fields, ast.TableField(name, value))
                elseif nxt and nxt.type == "SYMBOL"
                       and (nxt.value == "," or nxt.value == "}") then
                    local field_name = tokens[i].value
                    i = i + 1
                    table.insert(fields, ast.TableField(ast.Identifier(field_name), ast.Identifier(field_name)))
                else
                    local value = parse_expression()
                    if not value then parse_error("expected field name, value, or '}'") end
                    table.insert(fields, ast.TableField(nil, value))
                end

            elseif tokens[i].type == "SYMBOL" and tokens[i].value == "[" then
                -- computed key: { [expr] = value }
                i = i + 1                                -- skip '['
                local key = parse_expression()
                if not (tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "]") then
                    parse_error("expected ']' after table key")
                end
                i = i + 1
                if not (tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "=") then
                    parse_error("expected '=' after table key")
                end
                i = i + 1
                local value = parse_expression()
                if not value then parse_error("expected value after '='") end
                table.insert(fields, ast.TableField(key, value))

            else
                -- positional entry: {1, 2} / {"x"} / {f()} — no key
                local value = parse_expression()
                if not value then
                    parse_error("expected field name, value, or '}'")
                end
                table.insert(fields, ast.TableField(nil, value))
            end
        end
        if not (tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "}") then
            parse_error("expected '}'")
        end
        i = i + 1  -- skip '}'
        return ast.TableConstruction(fields)
    end

    while i <= #tokens do
        local token = tokens[i]
        
        -- Pattern: local IDENTIFIER = VALUE
        if token.type == "KEYWORD" and token.value == "local" then
            i = i + 1  -- skip 'local'
            if tokens[i] and tokens[i].type == "KEYWORD" and tokens[i].value == "function" then
                -- local function Name(...) ... end
                -- desugars to: LocalDeclaration(Name, <anonymous function>)
                local fn = parse_primary()
                if not fn or fn.type ~= "FunctionDeclaration" or not fn.name then
                    parse_error("expected function name after 'local function'")
                end
                if fn.name.type ~= "Identifier" then
                    parse_error("local function name must be a plain identifier")
                end
                local name = fn.name
                fn.name = nil
                table.insert(ast_nodes, ast.LocalDeclaration({ name }, { fn }))
            else
            local names = {}
            while true do
                if not (tokens[i] and tokens[i].type == "IDENTIFIER") then
                    parse_error("expected name in local declaration")
                end
                names[#names + 1] = ast.Identifier(tokens[i].value)
                i = i + 1
                if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," then
                    i = i + 1
                else break end
            end
            local values = {}
            if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "=" then
                i = i + 1
                while true do
                    local v = parse_expression()
                    if not v then parse_error("expected expression") end
                    values[#values + 1] = v
                    if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," then
                        i = i + 1
                    else break end
                end
            end
            table.insert(ast_nodes, ast.LocalDeclaration(names, values))
            end
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
            table.insert(ast_nodes, stmt)
        elseif token.type == "KEYWORD" and token.value == "function" then
            table.insert(ast_nodes, parse_expression())  -- function expression as a statement
        elseif i <= #tokens and token.type == "KEYWORD" and token.value == "return" then
            i = i + 1  -- skip 'return'
            -- return [explist] — stops at block terminators (return ends a block)
            local return_values = {}
            if tokens[i] and not (tokens[i].type == "KEYWORD"
                  and (tokens[i].value == "end" or tokens[i].value == "else" or tokens[i].value == "elseif"))
                  and not (tokens[i].type == "SYMBOL" and tokens[i].value == ";") then
                local ret_val = parse_expression()
                if not ret_val then parse_error("expected expression in return statement") end
                table.insert(return_values, ret_val)
                while tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," do
                    i = i + 1
                    ret_val = parse_expression()
                    if not ret_val then parse_error("expected expression after ',' in return statement") end
                    table.insert(return_values, ret_val)
                end
            end
            table.insert(ast_nodes, ast.ReturnStatement(return_values))
        elseif token.type == "KEYWORD" and token.value == "do" then
            i = i + 1  -- skip 'do'
            local body = parse_block{ ["end"] = true }
            if not tokens[i] or tokens[i].type ~= "KEYWORD" or tokens[i].value ~= "end" then
                parse_error("expected 'end' after do block")
            end
            i = i + 1
            table.insert(ast_nodes, ast.Block(body))
        elseif token.type == "SYMBOL" and token.value == "(" then
            -- parenthesized expression statement: (function() end)() etc.
            table.insert(ast_nodes, parse_assignment())
        elseif token.type == "SYMBOL" and token.value == "{" then
        parse_error("unexpected '{' — a table constructor is an expression, not a statement")
        else
            if token.type == "SYMBOL" and token.value == ";" then
                i = i + 1  -- empty statement
            else
                parse_error("unexpected symbol '" .. tostring(token.value) .. "'")
            end
        end
    end
    
    return ast_nodes  -- return the array of nodes
end

return {
    tokenize = tokenize,
    parse = parse
}