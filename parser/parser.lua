-- DESIGN: concat '..' is STRICT — both operands must be strings (no Lua-style
-- number coercion). Checkpoint: tostring(n). Confirmed by the OOP battery.
local ast = require("ast.ast")

local reserved_keywords = {
    ["and"] = "and",
    ["break"] = "break",
    ["do"] = "do",
    ["else"] = "else",
    ["elseif"] = "elseif",
    ["end"] = "end",
    ["false"] = "false",
    ["for"] = "for",
    ["function"] = "function",
    ["if"] = "if",
    ["in"] = "in",
    ["local"] = "local",
    ["nil"] = "nil",
    ["not"] = "not",
    ["or"] = "or",
    ["repeat"] = "repeat",
    ["return"] = "return",
    ["then"] = "then",
    ["true"] = "true",
    ["until"] = "until",
    ["while"] = "while",
    -- NOTE: "self" is deliberately NOT a keyword — it's an ordinary identifier
    -- (Lua convention, SPEC §4 rule 2). Do not add it back here.
    -- Future Soleil keywords (class, extends, super, data, abstract,
    -- interface, implements) must be CONTEXTUAL: matched as IDENTIFIER by
    -- value in their grammar position (like "table" in type position).
    -- Reserving them breaks real Lua code that uses them as identifiers.
}

-- Soleil-only keywords: reserved in soleil dialect, ordinary identifiers in
-- lua dialect. "self" is deliberately absent (SPEC §4 rule 2).
local soleil_keywords = {
    ["class"] = true,
    ["extends"] = true,
    ["super"] = true,
    ["interface"] = true,
    ["implements"] = true,
    ["abstract"] = true,
    ["final"] = true,
    ["override"] = true,
    ["default"] = true,
    ["data"] = true,
    ["object"] = true,
}
local current_class_name = nil
local allow_signature = false   -- true while parsing an interface body
local fn_depth = 0               -- function-in-function nesting, capped at 100

local ESCAPES = {
    ["n"] = "\n", ["t"] = "\t", ["r"] = "\r", ["a"] = "\a",
    ["b"] = "\b", ["f"] = "\f", ["v"] = "\v",
    ["\\"] = "\\", ["\""] = "\"", ["'"] = "'",
}

local reserved_symbols = {
    ["+"] = "+",
    ["-"] = "-",
    ["*"] = "*",
    ["/"] = "/",
    ["%"] = "%",
    ["^"] = "^",
    ["#"] = "#",
    ["=="] = "==",
    ["~="] = "~=",
    ["<="] = "<=",
    [">="] = ">=",
    [".."] = "..",
    ["<"] = "<",
    [">"] = ">",
    ["="] = "=",
    ["("] = "(",
    [")"] = ")",
    ["{"] = "{",
    ["}"] = "}",
    ["["] = "[",
    ["]"] = "]",
    ["."] = ".",
    [","] = ",",
    [":"] = ":",
    ["?."] = "?.",
    ["?:"] = "?:",
    ["!!"] = "!!"
} -- same as above

function laxed_error(message)
    print("Parse Error, but you chose to relax, so here's what's wrong to fix and make it work in standard strict Soleil: " .. message)
end

local current_parse_line = 0        -- kept fresh by parse/tokenize for error messages

function parse_error(message)
    local at = current_parse_line > 0 and (" at line " .. current_parse_line) or ""
    error("Parse Error" .. at .. ": " .. message)
end

-- stamps a source line onto a node; returns the node (chainable)
local function at(node, line)
    node.line = line
    return node
end

function parse_warn(message)
    print("Parse Warning: " .. message)
end

-- Simple tokenizer
local function tokenize(input, dialect)
    dialect = dialect or "soleil"     -- the compiler's own language
    if dialect ~= "soleil" and dialect ~= "lua" then
        parse_error("unknown dialect: " .. tostring(dialect))
    end
    local cursor = 1
    local tokens = {}
    local line = 1
    local markers = {}

    -- shebang: Lua ignores a first line starting with '#'
     if input:sub(1, 1) == "#" then
        local nl = input:find("\n", 1, true)
        local first_line = input:sub(1, (nl or #input + 1) - 1)
        if first_line:match("^#!%s*INCOMPLETE") then
            markers[#markers + 1] = { line = 1, reason = first_line }
        end
        cursor = nl and (nl + 1) or (#input + 1)
        if nl then line = line + 1 end
    end

    while cursor <= #input do
        current_parse_line = line
        local char = input:sub(cursor, cursor)
        
        -- Skip spaces
        if char == " " or char == "\n" or char == "\t" then
            if char == "\n" then line = line + 1 end
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
                local c_span = cursor
                cursor = close + #c_close_pat
                line = line + select(2, input:sub(c_span, cursor - 1):gsub("\n", ""))
            else
                -- line comment: capture inline INCOMPLETE markers
                local line_end = input:find("\n", cursor, true) or (#input + 1)
                local text = input:sub(cursor, line_end - 1)
                if text:match("^#!%s*INCOMPLETE") then
                    markers[#markers + 1] = { line = line, reason = "--" .. text }
                end
                cursor = line_end
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
            table.insert(tokens, { type = "NUMBER", value = num, line = line })
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
                        line = line + 1
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
                value = table.concat(parts),
                line = line
            })
          -- Backtick-escaped identifiers: `class` — Soleil reserved words as names.
        -- Lua keywords cannot be escaped (they could never emit as valid Lua).
        elseif char == "`" then
            local close = input:find("`", cursor + 1, true)
            if not close or close == cursor + 1 then
                parse_error("expected identifier between backticks")
            end
            local word = input:sub(cursor + 1, close - 1)
            if reserved_keywords[word] then
                parse_error("Lua keyword '" .. word .. "' cannot be escaped with backticks")
            end
            table.insert(tokens, {
                type = "IDENTIFIER",
                value = word,
                escaped = true,     -- diagnostics/headersgen can tell it apart later
                line = line
            })
            cursor = close + 1
        -- Match identifiers and keywords (letters or _)
        elseif char:match("[a-zA-Z_]") then
            local word_start = cursor
            while cursor <= #input and input:sub(cursor, cursor):match("[a-zA-Z0-9_]") do
                cursor = cursor + 1
            end
            local word = input:sub(word_start, cursor - 1)

            if reserved_keywords[word] or (dialect == "soleil" and soleil_keywords[word]) then
                table.insert(tokens, {
                    type = "KEYWORD",
                    value = word,
                    line = line
                })
            else
                table.insert(tokens, {
                    type = "IDENTIFIER",
                    value = word,
                    line = line
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
                -- Lua: a newline IMMEDIATELY after the opening bracket is
                -- not part of the string (keeps embedded line numbers sane)
                if input:sub(content_start, content_start + 1) == "\r\n" then
                    content_start = content_start + 2
                elseif input:sub(content_start, content_start):match("[\n\r]") then
                    content_start = content_start + 1
                end
                local close = input:find(close_pat, content_start, true)
                if not close then
                    parse_error("unterminated long string")
                end
                table.insert(tokens, { type = "STRING", value = input:sub(content_start, close - 1), line = line })
                local span_start = cursor
                cursor = close + #close_pat
                line = line + select(2, input:sub(span_start, cursor - 1):gsub("\n", ""))
            else
                -- Check for 3-character symbols first
                local three_char = input:sub(cursor, cursor + 2)
                if three_char == "..." then
                    table.insert(tokens, { type = "SYMBOL", value = three_char, line = line })
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
                            value = char,
                            line = line
                        })
                        cursor = cursor + 1
                    end
                end
            end
        end
    end
    
    return tokens, markers
end

function parse(tokens, markers)
    if tokens and tokens[1] then current_parse_line = tokens[1].line or 0 end
    local ast_nodes = {}  -- collect ALL nodes
    local i = 1  -- cursor position
    local parse_expression, parse_statement, parse_if_statement  -- forward declarations
    local comparison_ops = { ["=="]=true, ["~="]=true, ["<"]=true, [">"]=true, ["<="]=true, [">="]=true }
    local function is_comparison(op)
        return comparison_ops[op] or false
    end    
    function parse_primary(scope)
        if i > #tokens then
            parse_error("unexpected end of input")
        end

        local token = tokens[i]
        
        if i <= #tokens and token.type == "NUMBER" then
            i = i + 1
            -- RAW text, never converted: 10e500 must not become `inf`
            -- (tostring(inf) emits a bare identifier into the output)
            return ast.Number(token.value)
        elseif i <= #tokens and token.type == "STRING" then
            i = i + 1
            return ast.String(token.value)
        elseif i <= #tokens and tokens[i].type == "KEYWORD" and tokens[i].value == "function" then
            local saved_fn_depth = fn_depth
            fn_depth = fn_depth + 1
            if fn_depth > 100 then
                parse_error("function nesting too deep (limit 100)")
            end
            local fn_line = tokens[i].line
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
            local args, has_varargs = parse_params()
            if is_method then
                table.insert(args, 1, ast.Param(ast.Identifier("self"), nil))  -- function a:b() gets implicit self
            end
            local return_types
            if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == ":" then
                i = i + 1
                return_types = { parse_type() }
                while tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," do
                    i = i + 1
                    return_types[#return_types + 1] = parse_type()
                end
            end
            if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == ":" then
                i = i + 1
                return_types = parse_type()
            end
            local member_start = tokens[i] and tokens[i].type == "KEYWORD"
                and (tokens[i].value == "end" or tokens[i].value == "function"
                    or tokens[i].value == "override" or tokens[i].value == "abstract")
            if (allow_signature or force_signature)
               and (i > #tokens or member_start) then
                -- signature: no body — FunctionDeclaration with nil body
                fn_depth = saved_fn_depth          -- ← before this return
                return at(ast.FunctionDeclaration(func_name, args, nil, return_types, false), fn_line)
            end
            local body = parse_block({ ["end"] = true }, scope)
            if not tokens[i] or tokens[i].type ~= "KEYWORD" or tokens[i].value ~= "end" then
                parse_error("expected 'end' after function body")
            end
            i = i + 1  -- skip 'end'
            fn_depth = saved_fn_depth          -- ← before this return
            return at(ast.FunctionDeclaration(func_name, args, body, return_types), fn_line)
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
                elseif i <= #tokens and token.type == "KEYWORD" and token.value == "super" then
            i = i + 1
            if not current_class_name then
                parse_error("'super' used outside of a class")
            end
            if not (tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == ".") then
                parse_error("expected '.' after 'super'")
            end
            i = i + 1
            if not (tokens[i] and tokens[i].type == "IDENTIFIER") then
                parse_error("expected method name after 'super.'")
            end
            local mname = ast.Identifier(tokens[i].value)
            i = i + 1
            if not (tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "(") then
                parse_error("expected '(' after 'super." .. mname.name .. "'")
            end
            return at(ast.SuperCall(mname, parse_args(scope)), token.line)
        elseif token.type == "SYMBOL" and token.value == "{" then
            return parse_table()
        elseif i <= #tokens and token.type == "SYMBOL" and token.value == "(" then
            i = i + 1
            local expr = parse_expression(scope)
            if i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == ")" then
                i = i + 1
            else
                parse_error("expected ')' after parenthesized expression")
            end
            -- parens are SEMANTIC in Lua: (f()) truncates multi-returns to one
            return at(ast.Paren(expr), token.line)
        elseif token.type == "SYMBOL" and token.value == "..." then
            i = i + 1
            return ast.VarArgs()
        end
        return nil
    end

    function parse_for_loop(scope)
        local token = tokens[i]
        i = i + 1  -- skip 'for'
        local var = read_loop_var()
        if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "=" then
            -- numeric for: for NAME = start, finish [, step] do ... end
            i = i + 1
            local start = parse_expression(scope)
            if not start then parse_error("expected start expression in numeric for") end
            if not (tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == ",") then
                parse_error("expected ',' in numeric for")
            end
            i = i + 1
            local finish = parse_expression(scope)
            if not finish then parse_error("expected limit expression in numeric for") end
            local step
            if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," then
                i = i + 1
                step = parse_expression(scope)
                if not step then parse_error("expected step expression in numeric for") end
            end
            if not (tokens[i] and tokens[i].type == "KEYWORD" and tokens[i].value == "do") then
                parse_error("expected 'do' in numeric for")
            end
            i = i + 1  -- skip 'do'
            local body = parse_block({ ["end"] = true }, scope)
            if not tokens[i] or tokens[i].type ~= "KEYWORD" or tokens[i].value ~= "end" then
                parse_error("expected 'end' after for loop body")
            end
            if i <= #tokens and tokens[i].type == "KEYWORD" and tokens[i].value == "end" then
                i = i + 1
            end
            return at(ast.ForLoop(var, start, finish, step, body), token.line)
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
        local it = parse_expression(scope)
        if not it then parse_error("expected expression after 'in'") end
        table.insert(iters, it)
        while tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," do
            i = i + 1
            local next_it = parse_expression(scope)
            if not next_it then parse_error("expected expression after ',' in generic for") end
            table.insert(iters, next_it)
        end
        if not (tokens[i] and tokens[i].type == "KEYWORD" and tokens[i].value == "do") then
            parse_error("expected 'do' in generic for")
        end
        i = i + 1  -- skip 'do'
        local body = parse_block({ ["end"] = true }, scope)
        if not tokens[i] or tokens[i].type ~= "KEYWORD" or tokens[i].value ~= "end" then
            parse_error("expected 'end' after for loop body")
        end
        if i <= #tokens and tokens[i].type == "KEYWORD" and tokens[i].value == "end" then
            i = i + 1
        end
        return at(ast.ForInLoop(vars, iters, body), token.line)
    end

    function parse_repeat_loop(scope)
        local token = tokens[i]
        i = i + 1  -- skip 'repeat'
        local body = parse_block({ ["until"] = true }, scope)
        if i <= #tokens and tokens[i].type == "KEYWORD" and tokens[i].value == "until" then
            i = i + 1
            local condition = parse_expression(scope)
            if not condition then
                parse_error("expected condition")
            end
            return at(ast.RepeatLoop(body, condition), token.line)
        end
        parse_error("expected 'until' after repeat block")
    end

    function parse_while_loop(scope)
        local token = tokens[i]
        i = i + 1  -- skip 'while'
        local condition = parse_expression(scope)
        if not condition then
            parse_error("expected condition")
        end
        while i <= #tokens and not (tokens[i].type == "KEYWORD" and tokens[i].value == "do") do
            i = i + 1
        end
        i = i + 1  -- skip 'do'
        local body = parse_block({ ["end"] = true }, scope)
        if not tokens[i] or tokens[i].type ~= "KEYWORD" or tokens[i].value ~= "end" then
            parse_error("expected 'end' after while loop body")
        end
        if i <= #tokens and tokens[i].type == "KEYWORD" and tokens[i].value == "end" then
            i = i + 1
        end
        return at(ast.WhileLoop(condition, body), token.line)
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

    function parse_block(terminators, scope)
        local token = tokens[i]
        local stmts = {}
        while i <= #tokens and not (tokens[i].type == "KEYWORD" and terminators[tokens[i].value]) do
            local stmt = parse_statement(scope)
            if stmt then
                table.insert(stmts, stmt)
            else
                -- nil = consumed an empty statement (';'); it advanced i itself
            end
        end
        return at(ast.Block(stmts), token.line)
    end

    function parse_expression(scope)        -- `or` (loosest)
        local left = parse_and(scope)
        while tokens[i] and tokens[i].type == "KEYWORD" and tokens[i].value == "or" do
            local op = tokens[i].value; i = i + 1
            left = ast.BinaryOp(left, op, parse_and(scope))
        end
        return left
    end

    function parse_assignment(scope)
        local token = tokens[i]
        local left = parse_expression(scope)
        if not left then parse_error("expected expression") end
        local targets = nil
        -- more targets: a, b = ...  (comma loop must wrap AROUND the '=' check,
        -- since the '=' only appears after ALL targets)
        while tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," do
            if not targets then targets = { left } end
            i = i + 1
            left = parse_expression(scope)
            if not left then parse_error("expected assignment target after ','") end
            targets[#targets + 1] = left
        end
        if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "=" then
            if not targets then targets = { left } end
            i = i + 1
            local values = {}
            while true do
                local v = parse_expression(scope)
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
            return at(ast.Assignment(targets, values), token.line)
        end
        return left
    end

    function parse_and(scope)               -- `and`
        local left = parse_elvis(scope)
        while tokens[i] and tokens[i].type == "KEYWORD" and tokens[i].value == "and" do
            local op = tokens[i].value; i = i + 1
            left = ast.BinaryOp(left, op, parse_elvis(scope))
        end
        return left
    end

    function parse_comparison(scope)        -- == ~= < > <= >=
        local left = parse_concat(scope)
        while tokens[i] and tokens[i].type == "SYMBOL" and is_comparison(tokens[i].value) do
            local op = tokens[i].value; i = i + 1
            left = ast.BinaryOp(left, op, parse_concat(scope))
        end
        return left
    end

    function parse_concat(scope)            -- `..` (right-assoc in Lua)
        local left = parse_addsub(scope)
        if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == ".." then
            i = i + 1
            left = ast.BinaryOp(left, "..", parse_concat(scope))
        end
        return left
    end

    function parse_addsub(scope)            -- `+ -`
        local left = parse_muldiv(scope)
        while tokens[i] and tokens[i].type == "SYMBOL" and (tokens[i].value == "+" or tokens[i].value == "-") do
            local op = tokens[i].value; i = i + 1
            left = ast.BinaryOp(left, op, parse_muldiv(scope))
        end
        return left
    end

    function parse_muldiv(scope)            -- `* / %`
        local left = parse_unary(scope)
        while tokens[i] and tokens[i].type == "SYMBOL" and (tokens[i].value == "*" or tokens[i].value == "/" or tokens[i].value == "%") do
            local op = tokens[i].value; i = i + 1
            left = ast.BinaryOp(left, op, parse_unary(scope))
        end
        return left
    end

    function parse_unary(scope)             -- `- not #`
        if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "-" then
            local op = tokens[i].value; i = i + 1
            return ast.UnaryOp(op, parse_unary(scope))
        elseif tokens[i] and tokens[i].type == "KEYWORD" and tokens[i].value == "not" then
            local op = tokens[i].value; i = i + 1
            return ast.UnaryOp(op, parse_unary(scope))
        elseif tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "#" then
            local op = tokens[i].value; i = i + 1
            return ast.UnaryOp(op, parse_unary(scope))
        end
        return parse_power(scope)
    end

    function parse_power(scope)             -- `^` (tightest, RIGHT-assoc)
        local left = parse_postfix(scope)
        if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "^" then
            i = i + 1
            -- the exponent may carry a unary operator: 2^-2 == 2^(-2);
            -- right-assoc survives because unary recurses back into power
            left = ast.BinaryOp(left, "^", parse_unary(scope))
        end
        return left
    end

    -- parses '(' args ')' — call arguments, with strict ')' handling
    function parse_args(scope)
        i = i + 1  -- skip '('
        local args = {}
        while i <= #tokens and not (tokens[i].type == "SYMBOL" and tokens[i].value == ")") do
            local arg = parse_expression(scope)
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

    function parse_postfix(scope)
        local expr = parse_primary(scope)
        if not expr then return nil end      -- primary already reported nothing; caller's nil-check fires
        while i <= #tokens do
        if tokens[i] and tokens[i].line then current_parse_line = tokens[i].line end
            -- real Lua: non-prefixexp primaries take NO suffixes. A '(' after
            -- one begins a NEW statement (a = nil\n(function() end)(23) is
            -- two statements), and nil.x / 5[1] are syntax errors.
            if expr.type == "Nil" or expr.type == "Boolean" or expr.type == "Number"
               or expr.type == "String" or expr.type == "TableConstruction" then
                break
            end
            local t = tokens[i]
            if t.type == "SYMBOL" and t.value == "." then
                i = i + 1
                if not (i <= #tokens and tokens[i].type == "IDENTIFIER") then
                    parse_error("expected field name after '.'")
                end
                local ti = ast.TableIndex(expr, ast.Identifier(tokens[i].value))
                ti.via_dot = true    -- checker: index is a literal key, not a variable
                expr = ti
                i = i + 1
            elseif t.type == "SYMBOL" and t.value == "[" then
                i = i + 1                       -- skip '['
                local index = parse_expression(scope)
                if not (i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == "]") then
                    parse_error("expected ']' after table index")
                end
                i = i + 1                       -- skip ']'
                expr = ast.TableIndex(expr, index)
            elseif t.type == "SYMBOL" and t.value == "(" then
                expr = ast.FunctionCall(expr, parse_args(scope))
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
                    expr = ast.MethodCall(expr, ast.Identifier(method_name), parse_args(scope))
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
           elseif t.type == "SYMBOL" and t.value == "?." then
                -- safe access: normal access node with receiver = expr, wrapped
                i = i + 1
                if not (i <= #tokens and tokens[i].type == "IDENTIFIER") then
                    parse_error("expected field or method name after '?.'")
                end
                local name = tokens[i].value
                i = i + 1
                local nxt = tokens[i]
                if nxt and nxt.type == "SYMBOL" and nxt.value == "(" then
                    expr = ast.SafeAccess(expr, ast.MethodCall(expr, ast.Identifier(name), parse_args(scope)))
                elseif nxt and nxt.type == "SYMBOL" and nxt.value == "{" then
                    expr = ast.SafeAccess(expr, ast.MethodCall(expr, ast.Identifier(name), { parse_table() }))
                elseif nxt and nxt.type == "STRING" then
                    expr = ast.SafeAccess(expr, ast.MethodCall(expr, ast.Identifier(name), { ast.String(nxt.value) }))
                    i = i + 1
                else
                    local ti = ast.TableIndex(expr, ast.Identifier(name))
                    ti.via_dot = true
                    expr = ast.SafeAccess(expr, ti)
                end
            elseif t.type == "SYMBOL" and t.value == "!!" then
                i = i + 1
                expr = ast.NotNullAssertion(expr)
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

    function parse_statement(scope, top_level)
        local token = tokens[i]
        if not token then return nil end
        
        if token.type == "KEYWORD" and token.value == "local" then
            i = i + 1  -- skip 'local'
            if tokens[i] and tokens[i].type == "KEYWORD"
                  and (tokens[i].value == "class" or tokens[i].value == "interface"
                       or tokens[i].value == "data" or tokens[i].value == "object") then
                -- `local class` is redundant: classes are ALREADY scope-specific.
                -- Accept with a warning and re-dispatch without the modifier.
                local noun = tokens[i].value == "interface" and "an interface" or ("a " .. tokens[i].value)
                parse_warn("'local' on " .. noun
                    .. " declaration is redundant — classes are already scope-specific"
                    .. " (line " .. tostring(tokens[i].line or "?") .. ")")
                return parse_statement(scope, top_level)
            end
            if tokens[i] and tokens[i].type == "KEYWORD" and tokens[i].value == "function" then
                -- local function Name(...) ... end
                -- desugars to: LocalDeclaration(Name, <anonymous function>)
                local fn = parse_primary(scope)
                if not fn or fn.type ~= "FunctionDeclaration" or not fn.name then
                    parse_error("expected function name after 'local function'")
                end
                if fn.name.type ~= "Identifier" then
                    parse_error("local function name must be a plain identifier")
                end
                local name = fn.name
                fn.name = nil
                return at(ast.LocalDeclaration({ name }, { fn }), token.line)
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
            local declaration_type
            if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == ":" then
                i = i + 1                               -- the declaration consumes ':'
                declaration_type = parse_type()
            end
            local values = {}
            if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "=" then
                i = i + 1
                while true do
                    local v = parse_expression(scope)
                    if not v then parse_error("expected expression") end
                    values[#values + 1] = v
                    if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," then
                        i = i + 1
                    else break end
                end
            end
            return at(ast.LocalDeclaration(names, values, declaration_type), token.line)

        elseif token.type == "KEYWORD" and token.value == "do" then
            i = i + 1  -- skip 'do'
            local body = parse_block({ ["end"] = true }, scope)
            if not tokens[i] or tokens[i].type ~= "KEYWORD" or tokens[i].value ~= "end" then
                parse_error("expected 'end' after do block")
            end
            i = i + 1
            return at(body, token.line)   -- parse_block already returns a Block — no double wrap

        elseif token.type == "SYMBOL" and token.value == "(" then
            -- parenthesized expression statement: (function() end)() etc.
            return parse_assignment()

        elseif token.type == "SYMBOL" and token.value == "{" then
            parse_error("unexpected '{' — a table constructor is an expression, not a statement")

        elseif token.type == "KEYWORD" and token.value == "if" then
            return parse_if_statement(scope)

        elseif token.type == "KEYWORD" and token.value == "while" then
            return parse_while_loop(scope)

        elseif token.type == "KEYWORD" and token.value == "for" then
            return parse_for_loop(scope)

        elseif token.type == "KEYWORD" and token.value == "break" then
            i = i + 1  -- skip 'break'
            return at(ast.BreakStatement(), token.line)
        elseif token.type == "KEYWORD" and token.value == "repeat" then
            return parse_repeat_loop(scope)
        elseif token.type == "IDENTIFIER" then
            return parse_assignment()  -- Handle assignments and function calls
        elseif token.type == "KEYWORD" and token.value == "function" then
            return parse_expression(scope)  -- function expression as a statement
        elseif token.type == "KEYWORD" and (token.value == "class"
               or token.value == "interface" or token.value == "data") then
            return parse_class(token.value, false, scope)
        elseif token.type == "KEYWORD" and token.value == "abstract" then
            i = i + 1
            if not (tokens[i] and tokens[i].value == "class") then
                parse_error("expected 'class' after 'abstract'")
            end
            return parse_class("class", true, scope)
        elseif token.type == "KEYWORD" and token.value == "final" then
            i = i + 1
            if not (tokens[i] and tokens[i].value == "class") then
                parse_error("expected 'class' after 'final'")
            end
            local node = parse_class("class", false, scope)
            node.is_final = true                       -- cannot be extended
            return node
        elseif token.type == "KEYWORD" and token.value == "object" then
            if top_level then
                return parse_class("object", false, scope)
            end
            parse_error("objects can only be declared at the top level")
        elseif token.type == "KEYWORD" and token.value == "super" then
            return parse_assignment()   -- super.m(self) as an expression statement
        elseif i <= #tokens and token.type == "KEYWORD" and token.value == "return" then
            i = i + 1  -- skip 'return'
            local return_values = {}
            -- return [explist] — stops at block terminators (return ends a block)
            local return_values = {}
            if tokens[i] and not (tokens[i].type == "KEYWORD"
                  and (tokens[i].value == "end" or tokens[i].value == "else" or tokens[i].value == "elseif"))
                  and not (tokens[i].type == "SYMBOL" and tokens[i].value == ";") then
                local ret_val = parse_expression(scope)
                if not ret_val then parse_error("expected expression in return statement") end
                table.insert(return_values, ret_val)
                while tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," do
                    i = i + 1
                    ret_val = parse_expression(scope)
                    if not ret_val then parse_error("expected expression after ',' in return statement") end
                    table.insert(return_values, ret_val)
                end
            end
            return at(ast.ReturnStatement(return_values), token.line)

        elseif token.type == "SYMBOL" and token.value == ";" then
            i = i + 1  -- empty statement
            return nil

        else
            parse_error("unexpected symbol '" .. tostring(token.value) .. "'")
        end
    end

    -- Helper function to parse if/elseif statements recursively
    function parse_if_statement(scope)
        local token = tokens[i]
        i = i + 1  -- skip 'if' or 'elseif'
        
        -- Parse condition
        local condition = parse_expression(scope)
        if not condition then
            parse_error("expected condition")
        end
        
        -- Skip to 'then'
        while i <= #tokens and not (tokens[i].type == "KEYWORD" and tokens[i].value == "then") do
            i = i + 1
        end
        i = i + 1  -- skip 'then'
        
       local thenBlock = parse_block({ ["end"] = true, ["else"] = true, ["elseif"] = true }, scope)
        
        local elseBlock = nil
        
        if not tokens[i] then
            parse_error("expected 'end', 'else', or 'elseif' after if block")
        end

        local consumed_end = false

        if i <= #tokens and tokens[i].type == "KEYWORD" and tokens[i].value == "elseif" then
            elseBlock = parse_if_statement(scope)   -- recursive call consumes the shared 'end'
            consumed_end = true
        elseif i <= #tokens and tokens[i].type == "KEYWORD" and tokens[i].value == "else" then
            i = i + 1  -- skip 'else'
            elseBlock = parse_block({ ["end"] = true }, scope)
        end

        if not consumed_end then
            if not tokens[i] or tokens[i].type ~= "KEYWORD" or tokens[i].value ~= "end" then
                parse_error("expected 'end' after if statement")
            end
            i = i + 1
        end
        
        return at(ast.IfStatement(condition, thenBlock, elseBlock), token.line)
    end
    
    function parse_type()
        local t = tokens[i]
        if not t then parse_error("unexpected end of input in type") end

        local base
        if t.type == "IDENTIFIER" and t.value == "table" then
            i = i + 1                                   -- skip 'table'
            if not (tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "[") then
                parse_error("expected '[' after 'table' — bare 'table' is not a type")
            end
            i = i + 1                                   -- skip '['
            local first = parse_type()
            local form, key, value
            if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "," then
                i = i + 1
                local second = parse_type()
                if not (tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "]") then
                    parse_error("expected ']' after table type")
                end
                i = i + 1
                form, key, value = "map", first, second
            else
                if not (tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "]") then
                    parse_error("expected ']' after table type")
                end
                i = i + 1
                if first.type == "Type" and first.type_name == "any" then
                    form, key, value = "any", first, first      -- table[any]
                else
                    form, key, value = "array", ast.Type("number", false), first   -- table[V]: arrays are number-keyed
                end
            end
            base = ast.TableType(form, key, value)
        elseif t.type == "IDENTIFIER" then
            base = ast.Type(t.value, false)
            i = i + 1
        else
            parse_error("expected type name")
        end

        while tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "?" do
            i = i + 1
            if base.type == "Type" then
                base.nullable = true                    -- T? — mutate the flag
            else
                base = ast.UnionType({ base, ast.Type("nil", false) })  -- (T | U)?
            end
        end

        if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "|" then
            local members = { base }
            while tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "|" do
                i = i + 1
                members[#members + 1] = parse_type()
            end
            return ast.UnionType(members)
        end

        return base
    end

    function parse_table()
        i = i + 1
        local fields = {}
        while i <= #tokens and not (tokens[i].type == "SYMBOL" and tokens[i].value == "}") do
            if tokens[i].type == "SYMBOL" and (tokens[i].value == "," or tokens[i].value == ";") then
                i = i + 1                                -- skip ',' or ';' (both are field separators)
            elseif tokens[i].type == "IDENTIFIER" then
                -- two sub-cases, decided by ONE-token lookahead:
                --   {name = value}  named pair
                --   anything else  positional ({a,b} is POSITIONAL in Lua —
                --     a {name} shorthand would corrupt {a,b,c,d})
                local nxt = tokens[i + 1]
                if nxt and nxt.type == "SYMBOL" and nxt.value == "=" then
                    local name = ast.Identifier(tokens[i].value)
                    i = i + 2
                    local value = parse_expression(scope)
                    if not value then parse_error("expected value after '='") end
                    table.insert(fields, ast.TableField(name, value))
                else
                    local value = parse_expression(scope)
                    if not value then parse_error("expected field name, value, or '}") end
                    table.insert(fields, ast.TableField(nil, value))
                end

            elseif tokens[i].type == "SYMBOL" and tokens[i].value == "[" then
                -- computed key: { [expr] = value }
                i = i + 1                                -- skip '['
                local key = parse_expression(scope)
                if not (tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "]") then
                    parse_error("expected ']' after table key")
                end
                i = i + 1
                if not (tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "=") then
                    parse_error("expected '=' after table key")
                end
                i = i + 1
                local value = parse_expression(scope)
                if not value then parse_error("expected value after '='") end
                local field = ast.TableField(key, value)
                field.computed = true    -- {[k] = v}: key is an expression, not the name
                table.insert(fields, field)

            else
                -- positional entry: {1, 2} / {"x"} / {f()} — no key
                local value = parse_expression(scope)
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

    -- parses '(' params ')' — shared by functions and class headers.
    -- returns { params = {...}, varargs = boolean }
    function parse_params()
        i = i + 1  -- skip '('
        local params = {}
        local varargs = false
        while i <= #tokens and not (tokens[i].type == "SYMBOL" and tokens[i].value == ")") do
            if tokens[i].type == "SYMBOL" and tokens[i].value == "..." then
                i = i + 1
                varargs = true
                if not (i <= #tokens and tokens[i].type == "SYMBOL"
                        and tokens[i].value == ")") then
                    parse_error("varargs '...' must be the last parameter")
                end
            elseif tokens[i].type == "IDENTIFIER" then
                local pname = ast.Identifier(tokens[i].value)
                i = i + 1
                local ptype
                if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == ":" then
                    i = i + 1                       -- the param consumes ':'
                    ptype = parse_type()
                end
                table.insert(params, ast.Param(pname, ptype))
            else
                parse_error("expected parameter name")
            end
            if i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == "," then
                i = i + 1
            end
        end
        if varargs then
            table.insert(params, ast.VarArgs())     -- always last: {a, b, VarArgs}
        end
        if not (i <= #tokens and tokens[i].type == "SYMBOL" and tokens[i].value == ")") then
            parse_error("expected ')'")
        end
        i = i + 1  -- skip ')'
        return params, varargs
    end

    function parse_class(kind, abstract, scope)
        if kind ~= "class" and kind ~= "interface" and kind ~= "data" and kind ~= "object" then
            parse_error("expected 'class', 'interface', or 'data'")
        end
        local token = tokens[i]
        local class_line = token.line
        i = i + 1
        if not (tokens[i] and tokens[i].type == "IDENTIFIER") then
            parse_error("expected " .. kind .. " name")
        end
        local class_name = ast.Identifier(tokens[i].value)
        i = i + 1

        -- header params: interface v2 constructor MANDATES (types only), banned
        -- on objects, required on data, optional on classes
        local params, param_varargs = {}, false
        if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "(" then
            if kind == "object" then
                parse_error("objects cannot have constructor parameters")
            end
            params, param_varargs = parse_params()
            if param_varargs then
                parse_error("class parameters cannot be varargs")
            end
        elseif kind == "data" then
            parse_error("data classes require constructor parameters")
        end

        -- extends: classes only, as name + optional args
        local extends_name, extends_args
        if tokens[i] and tokens[i].type == "KEYWORD" and tokens[i].value == "extends" then
            if kind ~= "class" then
                parse_error("only classes can extend another class")
            end
            i = i + 1
            if not (tokens[i] and tokens[i].type == "IDENTIFIER") then
                parse_error("expected superclass name after 'extends'")
            end
            extends_name = ast.Identifier(tokens[i].value)
            i = i + 1
            if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "(" then
                extends_args = parse_args(scope)
            end
        end

        -- implements: one or more INTERFACES (SPEC §9: multiple contracts)
        local implements_list
        if tokens[i] and tokens[i].type == "KEYWORD" and tokens[i].value == "implements" then
            if kind == "interface" or kind == "object" then
                parse_error(kind .. "s cannot implement interfaces")
            end
            implements_list = {}
            repeat
                i = i + 1
                if not (tokens[i] and tokens[i].type == "IDENTIFIER") then
                    parse_error("expected interface name after 'implements'")
                end
                implements_list[#implements_list + 1] = ast.Identifier(tokens[i].value)
                i = i + 1
            until not (tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == ",")
        end

        -- member loop: only [override] function members until 'end'
        local members = {}
        local seen = {}
        local saved_class = current_class_name
        local saved_signature = allow_signature
        local saved_force = force_signature
        current_class_name = class_name.name
        allow_signature = (kind == "interface") or abstract
        while i <= #tokens and not (tokens[i].type == "KEYWORD" and tokens[i].value == "end") do
            local is_override = false
            local is_default = false
            if tokens[i].type == "KEYWORD" and tokens[i].value == "default" then
                i = i + 1
                is_default = true
                if kind ~= "interface" then
                    parse_error("'default' is only allowed inside interfaces")
                end
            end
            if tokens[i].type == "KEYWORD" and tokens[i].value == "override" then
                i = i + 1
                is_override = true
            end
            -- redundant `local` on nested class declarations: warn and continue
            if tokens[i].type == "KEYWORD" and tokens[i].value == "local"
                  and tokens[i + 1] and tokens[i + 1].type == "KEYWORD"
                  and (tokens[i + 1].value == "class" or tokens[i + 1].value == "interface"
                       or tokens[i + 1].value == "data" or tokens[i + 1].value == "object") then
                parse_warn("'local' on a " .. tokens[i + 1].value
                    .. " declaration is redundant — classes are already scope-specific"
                    .. " (line " .. tostring(tokens[i].line or "?") .. ")")
                i = i + 1
            end

            -- class-prefix modifiers for NESTED classes (final/abstract before
            -- the class keyword) — distinct from member-level abstract
            local nested_is_final, nested_is_abstract = false, false
            while tokens[i].type == "KEYWORD"
                  and (tokens[i].value == "final" or tokens[i].value == "abstract") do
                local nxt2 = tokens[i + 1]
                if nxt2 and nxt2.type == "KEYWORD"
                      and (nxt2.value == "class" or nxt2.value == "interface"
                           or nxt2.value == "data" or nxt2.value == "object") then
                    if tokens[i].value == "final" then nested_is_final = true
                    else nested_is_abstract = true end
                    i = i + 1
                else
                    break                                -- member-level abstract
                end
            end
            if nested_is_final and nested_is_abstract then
                parse_error("a class cannot be both final and abstract")
            end
                        local is_abstract_member = false
            if tokens[i].type == "KEYWORD" and tokens[i].value == "abstract" then
                i = i + 1
                is_abstract_member = true
                if kind ~= "class" or not abstract then
                    parse_error("abstract members are only allowed in abstract classes")
                end
            end
local is_nested_class = false
            if tokens[i].type == "KEYWORD"
               and (tokens[i].value == "class" or tokens[i].value == "interface"
                    or tokens[i].value == "data") then
                if (nested_is_final or nested_is_abstract) and tokens[i].value ~= "class" then
                    parse_error(tokens[i].value .. "s cannot be "
                        .. (nested_is_final and "final" or "abstract"))
                end
                local nested = parse_class(tokens[i].value, nested_is_abstract, scope)
                if nested_is_final then nested.is_final = true end
                nested.nested_in = class_name.name                   -- qualification info
                table.insert(members, nested)
                is_nested_class = true
            end
            if not is_nested_class then
                if not (tokens[i].type == "KEYWORD" and tokens[i].value == "function") then
                    parse_error("expected function member or 'end' in " .. kind .. " body")
                end
                force_signature = is_abstract_member    -- BEFORE the parse
                local fn = parse_primary(scope)
                if not fn.name then
                    parse_error("class methods must be named")
                end
                fn.overrides = is_override
                fn.abstract = is_abstract_member
                fn.is_default = is_default
                if is_default and (not fn.body or #fn.body.statements == 0) then
                    parse_error("default function '" .. fn.name.name
                        .. "' requires a body and a closing 'end'")
                end
                if seen[fn.name.name] then
                    parse_error("duplicate method '" .. fn.name.name .. "' in class '"
                        .. class_name.name .. "'")
                end
                seen[fn.name.name] = true
                if kind == "interface" and fn.body and #fn.body.statements > 0
                      and not fn.is_default then
                    parse_error("interface methods cannot have bodies (in interface '"
                        .. class_name.name .. "') — use 'default' for a reference implementation")
                end
                if force_signature and fn.body then
                    parse_error("abstract methods cannot have bodies (in class '"
                        .. class_name.name .. "')")
                end
                table.insert(members, fn)
            end
        end
        current_class_name = saved_class
        allow_signature = saved_signature
        force_signature = saved_force
        if not (tokens[i] and tokens[i].type == "KEYWORD" and tokens[i].value == "end") then
            parse_error("expected 'end' after " .. kind .. " body")
        end
        i = i + 1
        local is_singleton = false
        if kind == "object" then
            is_singleton = true
        end
        return at(ast.ClassDeclaration(class_name, params, ast.Block(members),
                    abstract,is_singleton, kind, extends_name, extends_args, implements_list), class_line)
    end

    function parse_elvis(scope)
        local left = parse_comparison(scope)
        if tokens[i] and tokens[i].type == "SYMBOL" and tokens[i].value == "?:" then
            local line = tokens[i].line
            i = i + 1
            local right = parse_elvis(scope)      -- right-assoc: a ?: b ?: c
            if not right then parse_error("expected expression after '?:'") end
            return at(ast.Elvis(left, right), line)
        end
        return left
    end

    while i <= #tokens do
        current_parse_line = tokens[i].line and tokens[i].line or current_parse_line
        local stmt = parse_statement(scope, true)   -- ONE dispatcher: top level allows 'object'
        if stmt then table.insert(ast_nodes, stmt) end
    end

    return ast_nodes, { incomplete = markers or {} }  -- nodes + incomplete markers
end

return {
    tokenize = tokenize,
    parse = parse
}