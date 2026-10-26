
---------------------------------------------------------
----------------Auto generated code block----------------
---------------------------------------------------------

do
    local searchers = package.searchers or package.loaders
    local origin_seacher = searchers[2]
    searchers[2] = function(path)
        local files =
        {
------------------------
-- Modules part begin --
------------------------

["parser.parser"] = function()
--------------------
-- Module: 'parser.parser'
--------------------
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
end,

["ast.ast"] = function()
--------------------
-- Module: 'ast.ast'
--------------------
-- ast/ast.lua
local AST = {}

-- Statements
function AST.LocalDeclaration(names, values, declaration_type)
    return {
        type = "LocalDeclaration",
        names = names,              -- list of Identifier nodes
        values = values,            -- list of expression nodes (empty = plain declaration)
        declaration_type = declaration_type
    }
end

function AST.Assignment(variables, values, value_type)
    return {
        type = "Assignment",
        variables = variables,
        values = values,
        value_type = value_type
    }
end

function AST.FunctionDeclaration(name, parameters, body, return_types, abstract, overrides)
    return {
        type = "FunctionDeclaration",
        name = name,
        parameters = parameters,
        body = body,
        return_types = return_types,   -- type node or nil (untyped)
        abstract = abstract, -- for abstract methods in classes
        overrides = overrides or false -- for method overrides in classes
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

function AST.FunctionCall(func, arguments, return_type)
    return {
        type = "FunctionCall",
        func = func,
        arguments = arguments,
        return_type = return_type
    }
end

function AST.SuperCall(method_name, arguments)
    return {
        type = "SuperCall",
        method_name = method_name,   -- Identifier
        arguments = arguments        -- {expression...} — self is explicit per rule 8
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

function AST.Param(name, param_type)
    return {
        type = "Param",
        name = name,              -- Identifier
        param_type = param_type   -- type node or nil (untyped)
    }
end

function AST.ClassDeclaration(name, params, body, abstract, singleton, class_type, extends_name, extends_args, implements_list)
    return {
        type = "ClassDeclaration",
        name = name,              -- Identifier
        params = params,           -- list of Param nodes
        body = body,               -- Block
        abstract = abstract,
        singleton = singleton,
        class_type = class_type, -- "class" | "interface" | "data"
        extends_name = extends_name,   -- Identifier or nil
        extends_args = extends_args,   -- {expression...} or nil
        implements_list = implements_list,  -- {Identifier...} or nil: implemented interfaces
    }
end

function AST.SafeAccess(object, access)      -- p?.x / p?.m(args) / p?.[k]
    return {
        type = "SafeAccess",
        object = object,                     -- the (possibly-nil) receiver
        access = access                      -- downstream TableIndex/MethodCall whose
    }                                        --   receiver field IS `object`
end

function AST.Elvis(left, right)              -- a ?: b
    return {
        type = "Elvis",
        left = left,
        right = right
    }
end

function AST.Paren(expr)                     -- (expr): truncates multi-returns
    return {
        type = "Paren",
        expr = expr
    }
end

function AST.NotNullAssertion(operand)       -- p!!
    return {
        type = "NotNullAssertion",
        operand = operand
    }
end

return AST
end,

["checker.checker"] = function()
--------------------
-- Module: 'checker.checker'
--------------------
-- checker/checker.lua — the Soleil type checker
-- Tree-walking, no execution. Walks the AST the parser produced, infers
-- expression types, and checks them against declarations (SPEC §2-§5).
-- Loud by contract: every violation raises with a line number.

local stdlib = require("checker.stdlib")
local dbg_tb = debug and debug.traceback -- header for stdlib type checking
local Checker = {}

-- ===========================================================================
-- 4. SCOPE CHAIN — block-structured symbol table
-- ===========================================================================

local function new_scope(parent, in_loop, fn_ret)
    return { vars = {}, parent = parent, in_loop = in_loop or false, fn_ret = fn_ret }
end

local function current_ret(scope)
    local s = scope
    while s do
        if s.fn_ret ~= nil then return s.fn_ret, s end
        s = s.parent
    end
    return nil, nil
end -- Deprecated, but still stay for compatibility

local function current_rets(scope)
    local s = scope
    while s do
        if s.fn_ret ~= nil then return s.fn_ret end     -- fn_ret now holds the list
        s = s.parent
    end
    return nil
end 

local function current_class(scope)
    local s = scope
    while s do
        if s.current_class_type then return s.current_class_type end
        s = s.parent
    end
    return nil
end

local function find_member(ct, table_name, member_name)
    local c = ct
    while c do
        if c.class_type ~= "interface" then
            local mem = c[table_name][member_name]
            if mem then return mem end
        end
        c = c.base_class
    end
    return nil
end

local function declare(scope, name, t)
    scope.vars[name] = t
end

local function lookup(scope, name)
    local s = scope
    while s do
        local t = s.vars[name]
        if t then return t end
        s = s.parent
    end
    return nil
end

-- dotted-lvalue canonical key ("self.v") — for field-level narrowing shadows
local function lvalue_key(node)
    if node.type == "Identifier" then return node.name end
    if node.type == "TableIndex" and node.via_dot then
        local base = lvalue_key(node.table)
        if base then return base .. "." .. node.index.name end
    end
    return nil
end

local function lookup_field_narrow(scope, key)
    local s = scope
    while s do
        if s.field_narrows and s.field_narrows[key] then return s.field_narrows[key] end
        s = s.parent
    end
    return nil
end

local function lookup_owner(scope, name)     -- which scope declared it (nil = none)
    local s = scope
    while s do
        if s.vars[name] then return s end
        s = s.parent
    end
    return nil
end

-- ===========================================================================
-- 1. TYPE MODEL (internal — converted from AST type nodes, never reused raw)
--    T := { kind = "primitive", name = "number"|"string"|"boolean"|"nil"|"any" }
--       | { kind = "table", form = "array"|"map"|"any", key = T, value = T }
--       | { kind = "function", params = {T,...}, ret = T, varargs = boolean }
--       | { kind = "union", members = {T,...} }        -- nil-ness lives in members
--       | { kind = "class", name = string }            -- §4, future
--       | { kind = "record", fields = {name -> T}} -- reserved for header files
-- ===========================================================================

local function prim(name) return { kind = "primitive", name = name } end
local T_NUMBER, T_STRING, T_BOOLEAN = prim("number"), prim("string"), prim("boolean")
local T_NIL, T_ANY, T_UNKNOWN = prim("nil"), prim("any"), prim("unknown")

local function union(members)
    -- flatten nested unions (index reads wrap the WHOLE element union in nil-
    -- removal guards, producing union(union(C,S), nil)) and dedupe members
    local flat, seen = {}, {}
    local function add(m)
        if m.kind == "union" then
            for _, n in ipairs(m.members) do add(n) end
            return
        end
        local key = tostring(m)
        if not seen[key] then
            seen[key] = true
            flat[#flat + 1] = m
        end
    end
    for _, m in ipairs(members) do add(m) end
    return { kind = "union", members = flat }
end
local function has_nil_member(t)
    for _, m in ipairs(t.members) do
        if m.kind == "primitive" and m.name == "nil" then return true end
    end
    return false
end
local function strip_nil(t)
    if t.kind ~= "union" then return t end
    local kept = {}
    for _, m in ipairs(t.members) do
        if not (m.kind == "primitive" and m.name == "nil") then
            kept[#kept + 1] = m
        end
    end
    if #kept == #t.members then return t end
    if #kept == 0 then return T_NIL end
    if #kept == 1 then return kept[1] end
    return union(kept)
end
local function record(fields) return { kind = "record", fields = fields } end -- kind of internal, not the same as data classes
local function class(name, class_type, abstract, fields, methods, base_class) return { 
    kind = "class",
    name = name,
    class_type = class_type, -- valid types are: class, interface, object and data
    abstract = abstract, -- is it abstract (reminder: data classes, objects and interfaces cannot be abstract)?
    fields = fields, 
    methods = methods, 
    base_class = base_class -- the base class's table that this class extends
} end

-- Soleil.toml wiring is deferred; until it returns, defaults hold the line.
-- (options.allow_incomplete = true is the lenient-INCOMPLETE mode, settable
-- via the API once config lands)
local options = { allow_incomplete = false }

local describe  -- forward
describe = function(t)
    if t.kind == "primitive" then return t.name end
    if t.kind == "table" then
        return "table[" .. describe(t.key) .. ", " .. describe(t.value) .. "]"
    end
    if t.kind == "union" then
        local parts = {}
        for _, m in ipairs(t.members) do parts[#parts + 1] = describe(m) end
        return table.concat(parts, " | ")
    end
    if t.kind == "function" then return "function" end

    if t.kind == "record" then return "record" end

    if t.kind == "class" then return t.name end
    return t.kind
end

local function is_nil(t)
    return t.kind == "primitive" and t.name == "nil"
end

local function contains_nil(t)
    if t.kind ~= "union" then return is_nil(t) end
    for _, m in ipairs(t.members) do
        if is_nil(m) then return true end
    end
    return false
end

local function definitely_returns(stmts) -- very trust me bro feature, indeed
    for _, s in ipairs(stmts) do
        if s.type == "ReturnStatement" then return true end
        if s.type == "Block" and definitely_returns(s.statements) then return true end
        if s.type == "IfStatement" and s.elseBlock then
            -- both branches must provably return; elseif chains nest in elseBlock
            if definitely_returns(s.thenBlock.statements)
               and (s.elseBlock.type ~= "Block"          -- nested elseif chain
                    or definitely_returns(s.elseBlock.statements)) then
                return true
            end
        end
    end
    return false
end

-- ===========================================================================
-- 2. AST TYPE NODE -> INTERNAL TYPE
--    Nullable is normalized away: T? becomes union{T, nil} — the one
--    canonical representation decided for nullability.
-- ===========================================================================
local class_registry = {}
local qname_taken = {}       -- unique flat names for emitted classes

local function from_ast(node, scope, any_ok)
    if not node then return T_ANY end
    if node.type == "Type" then
        local name = node.type_name
        local base
        if name == "number" or name == "string" or name == "boolean"
           or name == "nil" or name == "any" or name == "unknown" then
            if name == "any" and not any_ok then
                error("any is only legal inside table types — use unknown for dynamic data")
            end
            base = prim(name)
        else
            local ct = lookup(scope, name)        -- classes resolve through scopes now
            if not ct then
                error("unknown type '" .. name .. "'")
            end
            base = ct
        end
        if node.nullable then
            return union({ base, T_NIL })
        end
        return base
    elseif node.type == "TableType" then
        -- the brackets are any's one legal home
        return { kind = "table", form = node.form,
                 key = from_ast(node.key, scope, true),
                 value = from_ast(node.value, scope, true) }
    elseif node.type == "UnionType" then
        local members = {}
        for _, m in ipairs(node.types) do
            members[#members + 1] = from_ast(m, scope, any_ok)
        end
        return union(members)
    end
    error("checker: cannot convert AST node '" .. tostring(node.type) .. "' to a type")
end

-- ===========================================================================
-- 3. COMPATIBILITY — can a value of type `src` be used where `dst` is expected?
--    same primitive -> yes | any -> yes (both directions)
--    union dst -> some member accepts src
--    union src -> every member is accepted
--    table -> structural on form/key/value
-- ===========================================================================

local compatible  -- forward: table case recurses

compatible = function(src, dst)
    if dst.kind == "primitive" and dst.name == "any" then return true end
    if src.kind == "primitive" and src.name == "any" then return true end

    if src.kind == "union" then
        for _, m in ipairs(src.members) do
            if not compatible(m, dst) then return false end
        end
        return true
    end
    if dst.kind == "union" then
        for _, m in ipairs(dst.members) do
            if compatible(src, m) then return true end
        end
        return false
    end
    if src.kind == "primitive" and src.name == "unknown" then
        return dst.name == "unknown" or dst.name == "any"   -- out only to itself or any
    end
    if dst.kind == "primitive" and dst.name == "unknown" then
        return true                                          -- everything flows in
    end
    if src.kind == "primitive" and dst.kind == "primitive" then
        return src.name == dst.name
    end

    if src.kind == "table" and dst.kind == "table" then
        if dst.form == "any" or src.form == "any" then return true end
        -- form is USAGE discipline (ipairs vs pairs), not runtime structure:
        -- array[number, V] and map[number, V] are the same tables. Keys decide.
        if not compatible(src.key, dst.key) then return false end
        return compatible(src.value, dst.value)
    end
    if src.kind == "record" or dst.kind == "record" then return src == dst end
    if src.kind == "class" and dst.kind == "class" then
        if dst.class_type == "interface" and src.class_type ~= "interface" then
            -- SPEC §9: bounded structural conformance — the source must cover
            -- every interface member (this is how 'implements' types flow)
            for fname, ftype in pairs(dst.fields) do
                local provided = find_member(src, "fields", fname)
                if not provided or not compatible(ftype, provided) then return false end
            end
            for mname, im in pairs(dst.methods) do
                local impl = find_member(src, "methods", mname)
                if not impl and im.is_default then
                    -- default methods satisfy themselves
                elseif not impl or #impl.params ~= #im.params then
                    return false
                elseif impl.ret and im.ret and not compatible(impl.ret, im.ret) then
                    return false
                end
            end
            return true
        end
        local c = src
        while c do
            if c.name == dst.name or (dst.qname and c.qname == dst.qname) then return true end
            c = c.base_class
        end
        return false
    end
    return false
end


local check_stmt, infer_expr  -- mutually recursive
local check_stmt_raw          -- depth-capped body of check_stmt

local function type_error(msg, node)
    local where = ""
    if node and node.line then where = " at line " .. node.line end
    error("type error" .. where .. ": " .. msg)
end

local function check_fn_body(node, fn_type, parent_scope)
    fn_type.rets = {}
    for _, rt in ipairs(node.return_types or {}) do
        fn_type.rets[#fn_type.rets + 1] = from_ast(rt, parent_scope)
    end
    -- no declared returns = promises nothing = implicit nil (honest typing)
    fn_type.ret = fn_type.rets[1] or T_NIL
    local fn_scope = new_scope(parent_scope, false, fn_type.rets)
    for _, p in ipairs(node.parameters) do
        if p.type == "Param" then
            local pt = p.param_type and from_ast(p.param_type, parent_scope) or T_ANY
            fn_type.params[#fn_type.params + 1] = pt
            declare(fn_scope, p.name.name, pt)
        else
            fn_type.varargs = true
            fn_scope.in_varargs = true
        end
    end
    if not node.body or fn_type.signature_only then
        return    -- signature: params collected above, nothing further to check
    end
    for _, s in ipairs(node.body.statements) do
        check_stmt(s, fn_scope)
    end
    if fn_type.rets[1] and not contains_nil(fn_type.rets[1])
        and not (fn_type.rets[1].kind == "primitive" and fn_type.rets[1].name == "any") then
        if not definitely_returns(node.body.statements) then
            type_error("declared return type requires all paths to return a value", node)
        end
    end
end

local function in_loop(scope)
    local s = scope
    while s do
        if s.in_loop then return true end
        s = s.parent
    end
    return false
end

-- ===========================================================================
-- 5. ERRORS — loud, line-anchored
-- ===========================================================================


-- ===========================================================================
-- 6. THE WALK
-- ===========================================================================


-- infer_expr(node, scope) -> T  — the type of an expression, or raise
infer_expr = function(node, scope, allow_type)
    local kind = node.type

    if kind == "Number" then return T_NUMBER end
    if kind == "String" then return T_STRING end
    if kind == "Boolean" then return T_BOOLEAN end
    if kind == "Nil" then return T_NIL end
    if kind == "VarArgs" then
        if not scope.in_varargs then
            type_error("'...' used outside a varargs function", node)
        end
        return T_ANY
    end

    if kind == "Identifier" then
        local t = lookup(scope, node.name)
        if not t then
            type_error("undefined variable '" .. node.name .. "'", node)
        end
        if t.kind == "class" and t.class_type ~= "object" and not allow_type then
            local owner = lookup_owner(scope, node.name)
            if owner.type_bindings and owner.type_bindings[node.name] then
                type_error("cannot use type '" .. node.name .. "' as a value", node)
            end
        end
        return t
    end

    if kind == "BinaryOp" then
        local lt = infer_expr(node.left, scope)
        local rt = infer_expr(node.right, scope)
        local op = node.operator
        if op == "+" or op == "-" or op == "*" or op == "/" or op == "%" or op == "^" then
            if not compatible(lt, T_NUMBER) or not compatible(rt, T_NUMBER) then
                type_error("arithmetic '" .. op .. "' needs numbers, got "
                    .. describe(lt) .. " and " .. describe(rt), node)
            end
            return T_NUMBER
        end
        if op == ".." then
            if not compatible(lt, T_STRING) or not compatible(rt, T_STRING) then
                type_error("concat '..' needs strings", node)
            end
            return T_STRING
        end
        if op == "==" or op == "~=" or op == "<" or op == ">" or op == "<=" or op == ">=" then
            return T_BOOLEAN
        end
        if op == "and" or op == "or" then
            return union({ lt, rt })
        end
    end

    if kind == "UnaryOp" then
        local ot = infer_expr(node.operand, scope)
        if node.operator == "not" then return T_BOOLEAN end
        if node.operator == "-" then
            if not compatible(ot, T_NUMBER) then
                type_error("unary '-' needs a number", node)
            end
            return T_NUMBER
        end
        if node.operator == "#" then return T_NUMBER end
    end

    if kind == "TableConstruction" then
        -- positional-only -> array of the element union; named/computed keys -> map;
        -- mixed -> any. Element union makes container inits strict:
        -- { Circle(1), Square(1) } : table[number, Circle | Square]
        local has_named, has_positional = false, false
        local elems = {}
        for _, f in ipairs(node.fields) do
            if f.name then has_named = true else has_positional = true end
            local et = infer_expr(f.value, scope)
            if not has_named then elems[#elems + 1] = et end
        end
        if has_named and not has_positional then
            return { kind = "table", form = "map", key = T_STRING, value = T_ANY }
        elseif has_positional and not has_named then
            return { kind = "table", form = "array", key = T_NUMBER,
                     value = #elems > 0 and union(elems) or T_ANY }
        else
            return { kind = "table", form = "any", key = T_ANY, value = T_ANY }
        end
    end

    if kind == "TableIndex" then
        -- Qualified nested-class references on a TYPE receiver:
        --   Outer.Seal            -> the nested class type (ctor-able)
        --   Outer.Seal.v          -> a member resolved statically (flat-callable)
        -- The receiver is a TYPE (not a value), so only these are reachable.
        if node.via_dot and lvalue_key(node) then
            local root_name = lvalue_key(node):match("^[^.]+")   -- chains root at an identifier
            local owner = root_name and lookup_owner(scope, root_name)
            local bt = owner and owner.vars[root_name]
            if bt and bt.kind == "class"
                  and owner.type_bindings and owner.type_bindings[root_name] then
                local parts = {}
                for part in lvalue_key(node):gmatch("[^.]+") do
                    parts[#parts + 1] = part
                end
                local cur = bt
                for i = 2, #parts do
                    local nm = parts[i]
                    local nested = cur.nested and cur.nested[nm]
                    if i == #parts and not nested then
                        -- final segment may be a MEMBER (nearest ancestor wins)
                        local c, mem = cur, nil
                        while c do
                            mem = c.methods[nm]
                            if mem then break end
                            c = c.base_class
                        end
                        if mem then
                            node.static_owner = cur.qname or cur.name
                            node.static_name = nm
                            return mem                  -- the member's fn_type
                        end
                        type_error("no nested class or method '" .. nm
                            .. "' in class '" .. cur.name .. "'", node)
                    elseif nested then
                        cur = nested
                    else
                        type_error("no nested class '" .. nm
                            .. "' in class '" .. cur.name .. "'", node)
                    end
                end
                return cur                              -- a plain nested-class reference
            end
        end
        -- flow-narrowed field reads (type(self.v) == "number" guards)
        if node.via_dot then
            local key = lvalue_key(node)
            if key then
                local shadow = lookup_field_narrow(scope, key)
                if shadow then return shadow end
            end
        end
        -- §3: reads of tables yield the value type WRAPPED NULLABLE
        local t = infer_expr(node.table, scope)
        if not node.via_dot then
            infer_expr(node.index, scope)   -- t[k]: the index is a real expression
        end                                  -- t.k: the index is a literal key name
        if t.kind == "record" then
            if node.via_dot then
                local member = t.fields[node.index.name]
                if not member then
                    type_error("no such member '" .. node.index.name .. "'", node)
                end
                return member
            end
            return T_ANY   -- record["expr"]: conservative, can't know the key
        end
        if t.kind == "class" then
            local c, field = t, nil
            while c do
                field = c.fields[node.index.name]
                if field then break end
                c = c.base_class
            end
            if not field then
                type_error("no such field '" .. node.index.name .. "' in class '"
                    .. t.name .. "'", node)
            end
            return field                                  -- §4.5 trust: inherited too
        end
        if t.kind == "table" then
            if contains_nil(t.value) then return t.value end
            return union({ t.value, T_NIL })
        end
        type_error("cannot index a non-table value", node)
    end

    if kind == "FunctionCall" then
        -- select is tuple-aware, not a plain function:
        --   select("#", ...) -> number | select(n, ...) -> (n-1) values
        if node.func.type == "Identifier" and node.func.name == "select" then
            local a1 = node.arguments[1]
            if a1 and a1.type == "String" and a1.value == "#" then
                for i = 2, #node.arguments do infer_expr(node.arguments[i], scope) end
                return T_NUMBER
            end
            for _, a in ipairs(node.arguments) do infer_expr(a, scope) end
            return T_UNKNOWN
        end
        local ft = infer_expr(node.func, scope, true)
        if ft.kind ~= "function" then
            if ft.kind == "primitive" and ft.name == "any" then
                for _, a in ipairs(node.arguments) do infer_expr(a, scope) end
                return T_ANY                     -- untyped callee: check args, trust result
            end
            if ft.kind == "class" then
                if ft.singleton or ft.abstract or ft.class_type == "interface" then
                    type_error(ft.name .. " cannot be instantiated", node)   -- per-kind rules
                end
                node.ctor_class = ft.qname or ft.name
                -- data: params required (parser enforced ≥1, checker enforces presence here)
                if #node.arguments ~= #ft.ctor_params then
                    type_error("expected " .. #ft.ctor_params .. " constructor arguments", node)
                end
                for i, cp in ipairs(ft.ctor_params) do
                    local at = infer_expr(node.arguments[i], scope)
                    if not at or not compatible(at, cp.ptype) then
                        type_error("constructor argument '" .. cp.name .. "' type mismatch", node)
                    end
                end
                return ft                                  -- the instance IS the class type
            end
            type_error("calling a non-function value (" .. describe(ft) .. ")", node)
        end
        if not ft.varargs then
            if #node.arguments > #ft.params then
                type_error("too many arguments: expected " .. #ft.params, node)
            end
            -- missing arguments pass nil: legal only for nullable/any params
            for i = #node.arguments + 1, #ft.params do
                local pt = ft.params[i]
                if not (pt.kind == "primitive" and pt.name == "any") and not contains_nil(pt) then
                    type_error("missing argument " .. i, node)
                end
            end
        end
        for i, a in ipairs(node.arguments) do
            if ft.params[i] and not compatible(infer_expr(a, scope), ft.params[i]) then
                type_error("argument " .. i .. " type mismatch", node)
            end
        end
        return ft.ret or T_ANY
    end

    if kind == "MethodCall" then
        local obj_t = infer_expr(node.object, scope)
        local mt = obj_t
        local ns = nil
        if obj_t.kind == "record" then
            ns = obj_t                                    -- namespace object itself
        elseif obj_t.kind == "primitive" and obj_t.name == "string" then
            ns = lookup(scope, "string")                  -- string methods live in the string record
        end
        if ns and ns.kind == "record" then
            local member = ns.fields[node.method_name.name]
            if not member then
                type_error("no such member '" .. node.method_name.name .. "'", node)
            end
            if member.kind == "function" then
                if not member.varargs and #node.arguments + 1 > #member.params then
                    type_error("too many arguments", node)
                end
                for i, a in ipairs(node.arguments) do
                    local ptype = member.params[i + 1]   -- param 1 = the receiver
                    if ptype and not compatible(infer_expr(a, scope), ptype) then
                        type_error("argument " .. i .. " type mismatch", node)
                    end
                end
                return member.ret or T_ANY
            end
            return member.ret or T_ANY                   -- non-function member value
        end
        if mt.kind == "table" then
            mt = mt.value                        -- method = the value stored under the key
        end
        if obj_t.kind == "class" then
            local c, m = obj_t, nil
            while c do                                  -- walk the extends chain
                m = c.methods[node.method_name.name]
                if m then break end
                c = c.base_class
            end
            if not m and obj_t.implements then
                -- interface v2 defaults: the method may live on an interface
                for _, iface in ipairs(obj_t.implements) do
                    m = iface.methods[node.method_name.name]
                    if m then break end
                end
            end
            if not m then
                type_error("no such method '" .. node.method_name.name
                    .. "' in class '" .. obj_t.name .. "'", node)
            end
            -- devirtualization stamp: the nearest CLASS providing the method
            -- (interfaces are contracts; the emitter needs a concrete owner).
            -- §8 soundness: only safe when the method is MONOMORPHIC — if any
            -- other class declares the same name, a base-typed receiver could
            -- hold an override, and static dispatch would run the wrong body.
            local owner = obj_t
            local w = obj_t
            while w do
                if w.class_type ~= "interface" and w.methods[node.method_name.name] then
                    owner = w
                    break
                end
                w = w.base_class
            end
            if owner == obj_t and not obj_t.methods[node.method_name.name] then
                -- no class in the chain provides it: an interface default does
                for _, iface in ipairs(obj_t.implements or {}) do
                    if iface.methods[node.method_name.name] then
                        owner = iface
                        break
                    end
                end
            end
            local declarers = 0
            for _, k in pairs(class_registry) do
                if k.class_type ~= "interface" and k.methods[node.method_name.name] then
                    declarers = declarers + 1
                end
            end
            if (declarers <= 1 or obj_t.is_final) and obj_t.class_type ~= "interface" then
                node.devirt_owner = owner.qname or owner.name
            end
            if m.kind == "function" then
                if not m.varargs and #node.arguments + 1 > #m.params then
                    type_error("too many arguments", node)
                end
                for i, a in ipairs(node.arguments) do
                    local ptype = m.params[i + 1]       -- +1: self occupies param 1
                    if ptype and not compatible(infer_expr(a, scope), ptype) then
                        type_error("argument " .. i .. " type mismatch", node)
                    end
                end
                return m.ret or T_ANY
            end
            return T_ANY
        end
        if obj_t.kind == "union" then
            -- union receiver: polymorphic dispatch. EVERY member must resolve the
            -- method (structural); nil members make the call possibly-nil (§3).
            local common = nil
            for _, mem in ipairs(obj_t.members) do
                if mem.kind == "primitive" and mem.name == "nil" then
                    type_error("possibly-nil receiver — guard with 'if x ~= nil'", node)
                end
                local c, m = mem, nil
                while c and c.kind == "class" do
                    m = c.methods[node.method_name.name]
                    if m then break end
                    c = c.base_class
                end
                if mem.kind ~= "class" or not m then
                    type_error("no such method '" .. node.method_name.name
                        .. "' on a union member", node)
                end
                if m.kind ~= "function" then
                    type_error("method '" .. node.method_name.name .. "' is not a function", node)
                end
                if not m.varargs and #node.arguments + 1 > #m.params then
                    type_error("too many arguments", node)
                end
                for i, a in ipairs(node.arguments) do
                    local ptype = m.params[i + 1]
                    if ptype and not compatible(infer_expr(a, scope), ptype) then
                        type_error("argument " .. i .. " type mismatch", node)
                    end
                end
                local r = m.ret or T_ANY
                if common and not (compatible(r, common) or compatible(common, r)) then
                    type_error("union members disagree on '"
                        .. node.method_name.name .. "' return type", node)
                end
                common = common or r
            end
            return common or T_ANY
        end
        if mt.kind ~= "function" then
            if mt.kind == "primitive" and mt.name == "any" then
                for _, a in ipairs(node.arguments) do infer_expr(a, scope) end
                return T_ANY
            end
            type_error("method '" .. node.method_name.name .. "' is not a function", node)
        end
        if not mt.varargs and #node.arguments + 1 > #mt.params then
            type_error("too many arguments: expected " .. (#mt.params - 1) ..
                       ", got " .. #node.arguments, node)
        end
        for i, a in ipairs(node.arguments) do
            local ptype = mt.params[i + 1]       -- +1 skips implicit self (param 1)
            if ptype and not compatible(infer_expr(a, scope), ptype) then
                type_error("argument " .. i .. " type mismatch", node)
            end
        end
        local fn_type = { kind = "function", params = {}, rets = {},
                          ret = node.return_types and from_ast(node.return_types[1], scope) or T_ANY,
                          varargs = false }
        for _, rt in ipairs(node.return_types or {}) do
            fn_type.rets[#fn_type.rets + 1] = from_ast(rt, scope)
        end
        fn_type.ret = fn_type.rets[1] or T_NIL
    end

    if kind == "FunctionDeclaration" then
        local fn_type = { kind = "function", params = {}, rets = {}, varargs = false }
        check_fn_body(node, fn_type, scope)
        return fn_type                                          -- the type IS the result
    end

    if kind == "ClassDeclaration" then
        local fn_type = {kind = "class"}
    end

    if kind == "Paren" then
        return infer_expr(node.expr, scope)     -- typing passes through
    end

    if kind == "NotNullAssertion" then
        local t = infer_expr(node.operand, scope)
        if not (t.kind == "union" and has_nil_member(t)) then
            type_error("assertion on a non-nullable value", node)   -- fail-fast
        end
        return strip_nil(t)
    end

    if kind == "Elvis" then
        local lt = infer_expr(node.left, scope)
        local rt = infer_expr(node.right, scope)
        local lnn = strip_nil(lt)
        if lnn == lt then type_error("elvis on a non-nullable left", node) end
        return union({ lnn, rt })        -- union() dedupes; `x ?: 0` (number? ?: number) collapses to number
    end

    if kind == "SafeAccess" then
        -- p?.member — receiver may be nil (that is the point). Resolve the
        -- member lookup per access form, then wrap the result nullable.
        local acc = node.access
        local recv = (acc.type == "TableIndex") and acc.table or acc.object
        local obj_t = infer_expr(recv, scope)
        local function args_ok(m)
            if not m.varargs and #acc.arguments + 1 > #m.params then
                type_error("too many arguments", node)
            end
            for i, a in ipairs(acc.arguments) do
                local ptype = m.params[i + 1]       -- +1: receiver
                if ptype and not compatible(infer_expr(a, scope), ptype) then
                    type_error("argument " .. i .. " type mismatch", node)
                end
            end
        end
        if acc.type == "TableIndex" then
            if obj_t.kind == "primitive" and (obj_t.name == "nil") then
                return T_NIL                        -- p is definitely nil
            end
            if obj_t.kind == "union" then
                -- every non-nil member must resolve the field; nil folds in
                local results = {}
                for _, mem in ipairs(obj_t.members) do
                    if not (mem.kind == "primitive" and mem.name == "nil") then
                        if mem.kind == "class" then
                            local f = mem.fields[acc.index.name]
                            if not f then
                                type_error("no such field '" .. acc.index.name
                                    .. "' in class '" .. mem.name .. "'", node)
                            end
                            results[#results + 1] = f
                        elseif mem.kind == "record" then
                            local f = mem.fields[acc.index.name]
                            if not f then type_error("no such member '" .. acc.index.name .. "'", node) end
                            results[#results + 1] = f
                        elseif mem.kind == "table" then
                            results[#results + 1] = mem.value
                        else
                            type_error("cannot safe-access into " .. describe(mem), node)
                        end
                    end
                end
                results[#results + 1] = T_NIL
                return union(results)
            end
            if obj_t.kind == "class" then
                local f = obj_t.fields[acc.index.name]
                if not f then
                    type_error("no such field '" .. acc.index.name
                        .. "' in class '" .. obj_t.name .. "'", node)
                end
                return union({ f, T_NIL })
            end
            if obj_t.kind == "record" then
                local f = obj_t.fields[acc.index.name]
                if not f then type_error("no such member '" .. acc.index.name .. "'", node) end
                return union({ f, T_NIL })
            end
            if obj_t.kind == "table" then
                infer_expr(acc.index, scope)
                return union({ obj_t.value, T_NIL })
            end
            if obj_t.kind == "primitive" and (obj_t.name == "any" or obj_t.name == "unknown") then
                infer_expr(acc.index, scope)
                return T_ANY
            end
            type_error("cannot safe-access into " .. describe(obj_t), node)
        elseif acc.type == "MethodCall" then
            if obj_t.kind == "class" then
                local c, m = obj_t, nil
                while c do
                    m = c.methods[acc.method_name.name]
                    if m then break end
                    c = c.base_class
                end
                if not m then
                    type_error("no such method '" .. acc.method_name.name
                        .. "' in class '" .. obj_t.name .. "'", node)
                end
                if m.kind ~= "function" then return union({ T_ANY, T_NIL }) end
                args_ok(m)
                return union({ m.ret or T_ANY, T_NIL })
            end
            if obj_t.kind == "union" then
                -- every non-nil member must resolve; nil members fold into the result
                local common = nil
                for _, mem in ipairs(obj_t.members) do
                    if mem.kind == "primitive" and mem.name == "string" then
                        local ns = lookup(scope, "string")
                        local member = ns and ns.kind == "record" and ns.fields[acc.method_name.name]
                        if not member then
                            type_error("no such member '" .. acc.method_name.name
                                .. "' on string", node)
                        end
                        if member.kind == "function" then args_ok(member) end
                        local r = member.ret or T_ANY
                        if common and not (compatible(r, common) or compatible(common, r)) then
                            type_error("union members disagree on '"
                                .. acc.method_name.name .. "' return type", node)
                        end
                        common = common or r
                    elseif not (mem.kind == "primitive" and mem.name == "nil") then
                        local c, m = mem, nil
                        while c and c.kind == "class" do
                            m = c.methods[acc.method_name.name]
                            if m then break end
                            c = c.base_class
                        end
                        if mem.kind ~= "class" or not m then
                            type_error("no such method '" .. acc.method_name.name
                                .. "' on a union member", node)
                        end
                        if m.kind ~= "function" then
                            type_error("method '" .. acc.method_name.name .. "' is not a function", node)
                        end
                        args_ok(m)
                        local r = m.ret or T_ANY
                        if common and not (compatible(r, common) or compatible(common, r)) then
                            type_error("union members disagree on '"
                                .. acc.method_name.name .. "' return type", node)
                        end
                        common = common or r
                    end
                end
                return union({ common or T_ANY, T_NIL })
            end
            if obj_t.kind == "primitive" and obj_t.name == "string" then
                local ns = lookup(scope, "string")
                local member = ns and ns.kind == "record" and ns.fields[acc.method_name.name]
                if not member then type_error("no such member '" .. acc.method_name.name .. "'", node) end
                if member.kind == "function" then args_ok(member) end
                return union({ member.ret or T_ANY, T_NIL })
            end
            if obj_t.kind == "primitive" and (obj_t.name == "any" or obj_t.name == "unknown") then
                for _, a in ipairs(acc.arguments) do infer_expr(a, scope) end
                return T_ANY
            end
            if obj_t.kind == "primitive" and obj_t.name == "nil" then
                return T_NIL
            end
            type_error("cannot safe-call on " .. describe(obj_t), node)
        else
            type_error("checker: unsupported safe access form '" .. acc.type .. "'", node)
        end
    end

    if kind == "SuperCall" then
        local ct = current_class(scope)
        if not ct then type_error("'super' used outside of a class", node) end
        local base = ct.base_class
        if not base then
            type_error("class '" .. ct.name .. "' has no superclass", node)
        end
        local m = nil
        local c = base
        while c do                                       -- nearest ancestor wins
            m = c.methods[node.method_name.name]
            if m then break end
            c = c.base_class
        end
        if not m then
            type_error("no method '" .. node.method_name.name .. "' to call via super", node)
        end
        -- self is EXPLICIT in super calls: args map params[1..], no +1 skip
        if not m.varargs and #node.arguments ~= #m.params then
            type_error("super." .. node.method_name.name .. " expects " ..
                #m.params .. " arguments, got " .. #node.arguments, node)
        end
        for i, a in ipairs(node.arguments) do
            if m.params[i] and not compatible(infer_expr(a, scope), m.params[i]) then
                type_error("argument " .. i .. " type mismatch", node)
            end
        end
        return m.ret or T_ANY
    end
    type_error("checker: cannot infer expression type '" .. kind .. "'", node)
end

local function call_rets(node, scope)
    infer_expr(node, scope)                       -- full call check: arity + args
    if node.type == "Paren" then node = node.expr end   -- (f()) truncates to one ret
    -- select(n, ...) spreads n-1 unknowns into the assignment targets
    if node.type == "FunctionCall" and node.func.type == "Identifier"
          and node.func.name == "select"
          and node.arguments[1] and node.arguments[1].type == "Number" then
        local rets = {}
        for _ = 2, math.floor(node.arguments[1].value) do
            rets[#rets + 1] = T_UNKNOWN
        end
        return rets
    end
    if node.type == "FunctionCall" then
        local ft = infer_expr(node.func, scope, true)   -- callee's function type → rets
        if ft.kind == "function" and ft.rets and #ft.rets > 0 then
            return ft.rets
        end
    end
    return nil
end

-- check_stmt(node, scope) — statements produce nothing; they constrain
local check_depth = 0

check_stmt = function(node, scope)
    check_depth = check_depth + 1
    if check_depth > 1500 then
        check_depth = check_depth - 1
        type_error("nesting too deep (limit 1500)", node)
    end
    check_stmt_raw(node, scope)
    check_depth = check_depth - 1
end

check_stmt_raw = function(node, scope)
    local kind = node.type

    if kind == "LocalDeclaration" then
        local declared = node.declaration_type and from_ast(node.declaration_type, scope) or nil
        local spread = #node.values == 1 and call_rets(node.values[1], scope)
        if spread then
            for i, name_node in ipairs(node.names) do
                local t = spread[i]
                if declared and t and not compatible(t, declared) then
                    type_error("cannot initialize '" .. name_node.name .. "'", node)
                end
                declare(scope, name_node.name, t or T_NIL)   -- missing rets = nil, honestly typed
            end
            return
        end
        -- aligned check: name[i] vs values[i] (extra values ignored, Lua semantics)
        for i, name_node in ipairs(node.names) do
            local value_node = node.values[i]
            local inferred = nil
            if value_node then
                inferred = infer_expr(value_node, scope)
            end
            if declared then
                -- split unions: number | string with 2 names -> per-name check
                -- (v1: single declared type applies to every name)
                if inferred and not compatible(inferred, declared) then
                    type_error("cannot initialize '" .. name_node.name
                        .. "': expected a compatible type", node)
                end
                declare(scope, name_node.name, declared)
            else
                -- no annotation: infer from the value; bare `local x` is permissive
                declare(scope, name_node.name, inferred or T_ANY)
            end
        end
        return
    end

    if kind == "Assignment" then
        if #node.values == 1 then
            local spread = call_rets(node.values[1], scope)
            if spread then
                for i, target in ipairs(node.variables) do
                    local t = spread[i]
                    if not t then
                        type_error("missing value for assignment target " .. i, node)
                    elseif target.type == "Identifier" then
                        local declared = lookup(scope, target.name)
                        if declared and not compatible(t, declared) then
                            type_error("cannot assign: types do not match", node)
                        end
                    elseif target.type == "TableIndex" then
                        local tt = infer_expr(target.table, scope)
                        if tt and tt.kind == "table" and not compatible(t, tt.value) then
                            type_error("cannot store this value in the table", node)
                        end
                    end
                end
                return
            end
        end
        for i, target in ipairs(node.variables) do
            local t = lookup(scope, target.name or "")
            if target.type == "TableIndex" then
                -- t[k] = v — check value against the table's value type
                local tt = infer_expr(target.table, scope)
                local vt = node.values[i] and infer_expr(node.values[i], scope)
                if tt.kind == "union" then
                    type_error("cannot index a possibly nil value", node)
                end
                if tt.kind == "class" then
                    -- §4 rule 3 write-half: only declared fields, only compatible values
                    local field = tt.fields[target.index.name]
                    if not field then
                        type_error("no such field '" .. target.index.name
                            .. "' in class '" .. tt.name .. "'", node)
                    end
                    if vt and not compatible(vt, field) then
                        type_error("cannot assign: field type mismatch in class '"
                            .. tt.name .. "'", node)
                    end
                elseif tt and tt.kind == "table" and vt then
                    if not compatible(vt, tt.value) then
                        type_error("cannot store this value in the table", node)
                    end
                end
            elseif target.type == "Identifier" then
                if not t then
                    type_error("assignment to undefined variable '" .. target.name .. "'", node)
                end
                local vt = node.values[i] and infer_expr(node.values[i], scope)
                if vt and not compatible(vt, t) then
                    type_error("cannot assign: types do not match", node)
                end
            else
                type_error("cannot assign to this expression", node)
            end
        end
        return
    end

    if kind == "WhileLoop" or kind == "RepeatLoop" then
        if kind ~= "RepeatLoop" then
            infer_expr(node.condition, scope)
        end
        local body_scope = new_scope(scope, kind ~= "IfStatement")  -- loop bodies carry the flag
        for _, s in ipairs(node.thenBlock and node.thenBlock.statements or node.body and node.body.statements or {}) do
            check_stmt(s, body_scope)
        end
        return
    end

    if kind == "IfStatement" then
        infer_expr(node.condition, scope)
        -- flow narrowing: derive per-branch refinements from the condition.
        --   x ~= nil / x == nil   -> nil-strip (either branch)
        --   type(x) == "lit"      -> union member pick (either branch)
        -- Assignments to the name inside a branch cancel that branch's shadow.
        local cond = node.condition
        local function assigns_key(block, key)
            local function walk(node)
                if type(node) ~= "table" then return false end
                if node.type then
                    if node.type == "Assignment" and node.variables then
                        for _, tgt in ipairs(node.variables) do
                            if lvalue_key(tgt) == key then
                                return true
                            end
                        end
                    end
                    for k, v in pairs(node) do
                        if k ~= "type" and type(v) == "table" and walk(v) then
                            return true
                        end
                    end
                else
                    for _, v in ipairs(node) do
                        if walk(v) then return true end
                    end
                end
                return false
            end
            return walk(block)
        end

        -- extract the narrowed lvalue (var or dotted field) + per-branch types
        local narrow_key, narrow_is_var, then_t, else_t
        if cond.type == "BinaryOp" and (cond.operator == "~=" or cond.operator == "==") then
            local lv = nil
            if cond.left.type == "Identifier" or cond.left.type == "TableIndex" then
                lv = cond.left
            elseif cond.right.type == "Identifier" or cond.right.type == "TableIndex" then
                lv = cond.right
            end
            if lv and (cond.right.type == "Nil" or cond.left.type == "Nil") then
                local key = lvalue_key(lv)
                if key then
                    local t = infer_expr(lv, scope)
                    local notnil = strip_nil(t)
                    narrow_key, narrow_is_var = key, lv.type == "Identifier"
                    if cond.operator == "~=" then
                        then_t, else_t = notnil, T_NIL        -- else: x IS nil
                    else
                        then_t, else_t = T_NIL, notnil        -- then: x IS nil
                    end
                end
            end
        end
        if not narrow_key and cond.type == "BinaryOp"
              and (cond.operator == "==" or cond.operator == "~=") then
            local call, lit
            if cond.left.type == "FunctionCall" and cond.left.func.type == "Identifier"
                  and cond.left.func.name == "type" and #cond.left.arguments == 1
                  and cond.right.type == "String" then
                call, lit = cond.left, cond.right.value
            elseif cond.right.type == "FunctionCall" and cond.right.func.type == "Identifier"
                  and cond.right.func.name == "type" and #cond.right.arguments == 1
                  and cond.left.type == "String" then
                call, lit = cond.right, cond.left.value
            end
            if call then
                local lv = call.arguments[1]
                local key = lvalue_key(lv)
                if key then
                    local t = infer_expr(lv, scope)
                    if t and t.kind == "union" then
                        local yes, no = {}, {}
                        for _, mem in ipairs(t.members) do
                            if mem.kind == "primitive" and mem.name == lit then
                                yes[#yes + 1] = mem
                            else
                                no[#no + 1] = mem
                            end
                        end
                        if #yes > 0 then
                            narrow_key, narrow_is_var = key, lv.type == "Identifier"
                            then_t = (#yes == 1) and yes[1] or union(yes)
                            else_t = (#no == 1) and no[1] or ((#no > 1) and union(no) or T_NIL)
                        end
                    end
                end
            end
        end

        local function branch_shadow(target_scope, t)
            if not narrow_key or not t then return end
            if narrow_is_var then
                local t0 = lookup(target_scope, narrow_key)
                if t0 ~= t then declare(target_scope, narrow_key, t) end
            else
                target_scope.field_narrows = target_scope.field_narrows or {}
                target_scope.field_narrows[narrow_key] = t
            end
        end

        local then_scope = new_scope(scope)
        if narrow_key and not assigns_key(node.thenBlock, narrow_key) then
            branch_shadow(then_scope, then_t)
        end
        for _, s in ipairs(node.thenBlock.statements) do
            check_stmt(s, then_scope)
        end
        if node.elseBlock then
            if node.elseBlock.type == "Block" then
                local else_scope = new_scope(scope)
                if narrow_key and not assigns_key(node.elseBlock, narrow_key) then
                    branch_shadow(else_scope, else_t)
                end
                for _, s in ipairs(node.elseBlock.statements) do
                    check_stmt(s, else_scope)
                end
            else
                check_stmt(node.elseBlock, scope)
            end
        end
        return
    end

    if kind == "ForLoop" then
        local body_scope = new_scope(scope, true)
        declare(body_scope, node.variable.name, T_NUMBER)   -- the loop var is a number
        for _, s in ipairs(node.body.statements) do
            check_stmt(s, body_scope)
        end
        return
    end

    if kind == "ForInLoop" then
        local kt, vt = T_ANY, T_ANY
        local first = node.iterators[1]
        if first and first.type == "FunctionCall" and first.func.type == "Identifier"
           and (first.func.name == "ipairs" or first.func.name == "pairs") then
            local tt = first.arguments[1] and infer_expr(first.arguments[1], scope)
            if tt and tt.kind == "table" then
                if first.func.name == "ipairs" then
                    kt, vt = T_NUMBER, tt.value
                    if tt.form == "map" then
                        type_error("ipairs requires an array table", first)
                    end
                else
                    kt, vt = tt.key, tt.value
                end
            end
        else
            for _, it in ipairs(node.iterators) do infer_expr(it, scope) end
        end
        local body_scope = new_scope(scope, true)
        local var_types = { kt, vt }
        for i, v in ipairs(node.variables) do
            declare(body_scope, v.name, var_types[i] or T_NIL)   -- 3rd+ vars are always nil
        end
        for _, s in ipairs(node.body.statements) do
            check_stmt(s, body_scope)
        end
        return
    end
    if kind == "Block" then
        local body_scope = new_scope(scope)
        for _, s in ipairs(node.statements) do
            check_stmt(s, body_scope)
        end
        return
    end

    if kind == "ReturnStatement" then
        local rets = current_rets(scope)
        -- a function that promises nothing cannot return anything
        if rets and #rets == 0 and #node.values > 0 then
            type_error("this function declares no return types — it cannot return values;"
                .. " add return types or return nothing", node)
        end
        if rets and #node.values == 1 then
            local spread = call_rets(node.values[1], scope)
            if spread then
                for i = 1, #rets do
                    local t = spread[i]
                    if not t then
                        if not contains_nil(rets[i]) then
                            type_error("missing return value " .. i, node)
                        end
                    elseif not compatible(t, rets[i]) then
                        type_error("return " .. i .. " type mismatch", node)
                    end
                end
                return                      -- propagation handled; positional path skipped
            end
        end
        if rets then
            for i = 1, #rets do
                local v = node.values[i]
                if v then
                    if not compatible(infer_expr(v, scope), rets[i]) then
                        type_error("return " .. i .. " type mismatch", node)
                    end
                elseif not contains_nil(rets[i]) then
                    type_error("missing return value " .. i, node)
                end
            end
            -- extra returned values beyond the declared list: legal Lua, unconstrained
        end
        return
    end

    if kind == "BreakStatement" then
        -- TODO: verify we are inside a loop (the deferred scope check)
        if not in_loop(scope) then
            type_error("'break' outside of a loop", node)
        end
        return
    end

    if kind == "FunctionDeclaration" then
        -- named function: build type, declare, then check body via the shared helper
        local fn_type = { kind = "function", params = {}, varargs = false }
        if node.name then
            if node.name.type ~= "Identifier" then
                type_error("dotted function declarations are not supported yet — assign an anonymous function instead", node)
            end
            declare(scope, node.name.name, fn_type)
        end
        check_fn_body(node, fn_type, scope)
        return
    end

    if kind == "FunctionCall" or kind == "MethodCall" or kind == "SuperCall" then
        infer_expr(node, scope)  -- expression statement: still infer for side-effect errors
        return
    end

    if kind == "ClassDeclaration" then
        local ct = class_registry[node.name.name]               -- top-level: the pre-pass shell
        if not ct then
            if scope.vars[node.name.name] then
                type_error("duplicate class name '" .. node.name.name
                    .. "' in the same scope", node)             -- function-local: no silent shadow
            end
            ct = class(node.name.name, node.class_type, node.abstract, {}, {}, nil)
            ct.line = node.line                                 -- function-local: fresh type
            local qn = node.name.name
            local bump = 2
            while qname_taken[qn] do qn = node.name.name .. "_" .. bump; bump = bump + 1 end
            qname_taken[qn] = true
            ct.qname = qn                                       -- emitter-safe flat name
        end
        ct.qname = ct.qname or node.name.name
        ct.is_final = node.is_final
        node.qname = ct.qname
        local implements_ifaces = {}
        if node.extends_name then
            local base = lookup(scope, node.extends_name.name)
            if not base or base.kind ~= "class" then
                type_error("unknown superclass '" .. node.extends_name.name .. "'", node)
            end
            if base.class_type == "interface" then
                type_error("interfaces are implemented, not extended — use 'implements' for '"
                    .. base.name .. "'", node)
            end
            if base.is_final then
                type_error("cannot extend final class '" .. base.name .. "'", node)
            end
            ct.base_class = base
            node.extends_qname = base.qname or base.name
        end
        for _, iname in ipairs(node.implements_list or {}) do
            local iface = lookup(scope, iname.name)
            if not iface or iface.kind ~= "class" or iface.class_type ~= "interface" then
                type_error("'" .. iname.name .. "' is not an interface", node)
            end
            implements_ifaces[#implements_ifaces + 1] = iface
        end
        ct.implements = implements_ifaces                       -- method resolution reads this
        node.implements_qnames = {}
        for _, iface in ipairs(implements_ifaces) do
            node.implements_qnames[#node.implements_qnames + 1] = iface.qname or iface.name
        end

        -- member walk: fields, ctor_params, methods, bodies (fills the type)
        -- interface params are ctor MANDATES only — they never become fields
        if node.class_type ~= "interface" then
            for _, p in ipairs(node.params) do
                ct.fields[p.name.name] = p.param_type
                    and from_ast(p.param_type, scope) or T_ANY
            end
        end
        ct.ctor_params = {}
        for _, p in ipairs(node.params) do
            ct.ctor_params[#ct.ctor_params + 1] = {
                name = p.name.name,
                ptype = p.param_type
                    and from_ast(p.param_type, scope) or T_ANY,
            }
        end
        declare(scope, node.name.name, ct)                      -- the name enters scope
        scope.type_bindings = scope.type_bindings or {}
        scope.type_bindings[node.name.name] = true              -- bare-name use = type, not value
        local class_scope = new_scope(scope)                    -- member bodies check against this
        class_scope.current_class_type = ct                     -- super resolution reads this
        local seen = {}                                         -- duplicate-method guard
        for _, m in ipairs(node.body.statements) do
            if m.type == "ClassDeclaration" then
                check_stmt(m, class_scope)      -- nested class: full class-branch treatment
                ct.nested = ct.nested or {}
                ct.nested[m.name.name] = class_scope.vars[m.name.name]
            else
                local fn_type = { kind = "function", params = {}, rets = {}, varargs = false }
                ct.methods[m.name.name] = fn_type
                fn_type.overrides = m.overrides
                fn_type.is_default = m.is_default
                fn_type.line = m.line
                if m.is_default then
                    if not m.body or #m.body.statements == 0 then
                        type_error("default function '" .. m.name.name .. "' requires a body", m)
                    end
                elseif kind == "interface"
                   or (node.abstract and (not m.body or #m.body.statements == 0))
                   or m.abstract then
                    fn_type.signature_only = true
                end
                check_fn_body(m, fn_type, class_scope)
                seen[m.name.name] = true
            end
        end

        -- rule 7: each own method against the nearest class ancestor
        for mname, m in pairs(ct.methods) do
            local found, ancestor_m = false, nil
            local c = ct.base_class
            while c do
                if c.class_type ~= "interface" and c.methods[mname] then
                    found, ancestor_m = true, c.methods[mname]
                    break
                end
                c = c.base_class
            end
            if m.overrides and not found then
                type_error("method '" .. mname .. "' overrides nothing", m)
            end
            if found and not m.overrides
               and not (m.signature_only or m.abstract) then
                type_error("method '" .. mname .. "' must be declared with 'override'", m)
            end
            if found and m.overrides then
                if #m.params ~= #ancestor_m.params then
                    type_error("override of '" .. mname .. "' has a different parameter count", m)
                end
                for i = 1, math.min(#m.rets or {}, #ancestor_m.rets or {}) do
                    if not compatible(m.rets[i], ancestor_m.rets[i]) then
                        type_error("override of '" .. mname .. "' return " .. i .. " type mismatch", m)
                    end
                end
                -- rule 2: self may narrow, never widen
                local s_self, a_self = m.params[1], ancestor_m.params[1]
                if s_self and a_self and not compatible(s_self, a_self) then
                    type_error("override of '" .. mname .. "' has an incompatible self type", m)
                end
                -- param positions: match-or-widen — the base's argument must
                -- flow into the override's parameter (contravariant-ish)
                for i = 2, math.min(#m.params, #ancestor_m.params) do
                    local s_p, a_p = m.params[i], ancestor_m.params[i]
                    if s_p and a_p and not compatible(a_p, s_p) then
                        type_error("override of '" .. mname .. "' parameter " .. (i - 1)
                            .. " type mismatch", m)
                    end
                end
            end
        end

        -- satisfaction: interfaces in the chain, once each, plus 'implements'
        local satisfied = {}
        local function check_iface(c)
            if satisfied[c] then return end
            satisfied[c] = true
            do
                for fname, ftype in pairs(c.fields) do
                    local provided = find_member(ct, "fields", fname)
                    if not provided then
                        type_error("class '" .. ct.name .. "' does not implement field '"
                            .. fname .. "' from interface '" .. c.name .. "'", node)
                    elseif not compatible(ftype, provided) then
                        type_error("field '" .. fname .. "' has an incompatible type for interface '"
                            .. c.name .. "'", node)
                    end
                end
                for mname, im in pairs(c.methods) do
                    local impl = find_member(ct, "methods", mname)
                    if not impl and im.is_default then
                        -- default methods satisfy themselves
                    elseif not impl then
                        type_error("class '" .. ct.name .. "' does not implement method '"
                            .. mname .. "' from interface '" .. c.name .. "'", node)
                    elseif #impl.params ~= #im.params then
                        type_error("method '" .. mname .. "' has a different parameter count than interface '"
                            .. c.name .. "'", node)
                    elseif impl.ret and im.ret and not compatible(impl.ret, im.ret) then
                        type_error("method '" .. mname .. "' has an incompatible return type for interface '"
                            .. c.name .. "'", node)
                    end
                end
                -- interface v2 ctor MANDATES: name-based — the class must have a
                -- parameter of that name whose type accepts the mandated type
                for _, mp in ipairs(c.ctor_params or {}) do
                    local cpp = nil
                    for _, cp in ipairs(ct.ctor_params or {}) do
                        if cp.name == mp.name then cpp = cp break end
                    end
                    if not cpp then
                        type_error("class '" .. ct.name .. "' needs a constructor parameter '"
                            .. mp.name .. "' (mandated by interface '" .. c.name .. "')", node)
                    elseif not compatible(mp.ptype, cpp.ptype) then
                        type_error("constructor parameter '" .. mp.name .. "' of '" .. ct.name
                            .. "' must accept " .. (mp.ptype and describe(mp.ptype) or "any")
                            .. " (mandated by interface '" .. c.name .. "')", node)
                    end
                end
            end
        end
        local c = ct.base_class
        while c do
            if c.class_type == "interface" then check_iface(c) end
            c = c.base_class
        end
        for _, iface in ipairs(implements_ifaces) do check_iface(iface) end

        declare(scope, node.name.name, ct)                      -- LAST: declare after validation
        return
    end




    type_error("checker: unknown statement '" .. tostring(kind) .. "'", node)
end

-- Checker.check(ast_nodes) — entry point: a list of top-level statements
function Checker.check(ast_nodes, meta)
    local global_scope = new_scope(nil)
    for name, t in pairs(stdlib) do
        declare(global_scope, name, t)
    end
    if meta and meta.incomplete and #meta.incomplete > 0 then
        if not options.allow_incomplete then
            local first = meta.incomplete[1]
            error("refusing to fully check: file is marked INCOMPLETE (" ..
                #meta.incomplete .. " marker(s), first at line " .. first.line .. ")")
        end
        -- lenient mode: report, don't refuse
        for _, m in ipairs(meta.incomplete) do
            parse_warn("incomplete: " .. (m.reason or "no reason given") .. " (line " .. m.line .. ")")
        end
    end
     -- Step 5: class registry — collect, build, wire
    local class_types = {}
    for k in pairs(qname_taken) do qname_taken[k] = nil end
    for _, stmt in ipairs(ast_nodes) do
        if stmt.type == "ClassDeclaration" then
            local primitives = { number = true, string = true, boolean = true,
                                 ["nil"] = true, any = true, unknown = true }
            if primitives[stmt.name.name] then
                type_error("cannot use primitive type name '" .. stmt.name.name .. "' as a class name", stmt)
            end
            if stdlib[stmt.name.name] then
                type_error("class name '" .. stmt.name.name .. "' conflicts with the standard library", stmt)
            end
            if class_types[stmt.name.name] then                     -- ← T1c: ADD
                type_error("duplicate class '" .. stmt.name.name .. "'", stmt)
            end
            local shell = class(stmt.name.name, stmt.class_type,
                stmt.abstract, {}, {}, nil)                     -- ← REPLACES lines 903-919
            shell.line = stmt.line
            shell.qname = stmt.name.name                        -- top-level: qname == name
            qname_taken[stmt.name.name] = true
            class_types[stmt.name.name] = shell
            declare(global_scope, stmt.name.name, shell)        -- ← NEW: the forward-ref line
            global_scope.type_bindings = global_scope.type_bindings or {}
            global_scope.type_bindings[stmt.name.name] = true
        end
    end
    for _, stmt in ipairs(ast_nodes) do           -- pass 2: wire inheritance pointers
        if stmt.type == "ClassDeclaration" and stmt.extends_name then
            local base = class_types[stmt.extends_name.name]
            if not base then
                type_error("unknown superclass '" .. stmt.extends_name.name .. "'", stmt)
            end
            class_types[stmt.name.name].base_class = base
        end
    end
    for name, ct in pairs(class_types) do
        local seen = { [ct] = true }
        local c = ct.base_class
        while c do
            if seen[c] then
                type_error("cyclic inheritance involving '" .. name .. "'", ct)
            end
            seen[c] = true
            c = c.base_class
        end
    end
    class_registry = class_types
    for _, stmt in ipairs(ast_nodes) do
        check_stmt(stmt, global_scope)
    end
end

return Checker

end,

["checker.stdlib"] = function()
--------------------
-- Module: 'checker.stdlib'
--------------------
-- the signature / built-in header for standard libraries so that checker can have something to freaking check to (basically the Root of Trust for stdlibs types).
local function fn(params, ret, varargs)
    return { kind = "function", params = params, ret = ret, varargs = varargs or false }
end

local S = { kind = "primitive", name = "string" }
local N = { kind = "primitive", name = "number" }
local A = { kind = "primitive", name = "any" }        -- legal only INSIDE table brackets
local U = { kind = "primitive", name = "unknown" }    -- dynamic params: everything flows in
local NIL = { kind = "primitive", name = "nil" }
local B = { kind = "primitive", name = "boolean" }

local function opt(t) return { kind = "union", members = { t, { kind = "primitive", name = "nil" } } } end
local function array(v) return { kind = "table", form = "array", key = N, value = v } end
local function map(k, v) return { kind = "table", form = "map", key = k, value = v } end
local function record(fields) return { kind = "record", fields = fields } end

return {
    ["print"] = fn({ U }, NIL, true),
    ["select"] = fn({ U }, U, true),   -- tuple-awareness is special-cased in the checker
    ["type"]  = fn({ U }, S),
    ["string"] = record({
        sub    = fn({ S, N, opt(N) }, S),
        len    = fn({ S }, N),
        format = fn({ S }, S, true),
        rep    = fn({ S, N }, S),
    }),
    ["math"]  = record({ floor = fn({ N }, N), max = fn({ N, N }, N) }),
    ["table"] = record({ insert = fn({ array(A), A }, NIL, true) }),
    ["pairs"]  = fn({ map(A, A) }, A),     -- iterator magic is special-cased, see 4
    ["ipairs"] = fn({ array(A) }, A),
    ["tostring"] = fn({U}, S),
    ["tonumber"] = fn({U}, opt(N)),
    ["error"] = fn({U}, NIL),
    ["pcall"] = fn({U}, B, true),           -- v1: ret is just the boolean; results are any
    ["setmetatable"] = fn({map(A, A), map(A, A)}, map(A, A)),   -- returns its (untyped) table argument
    ["getmetatable"] = fn({U}, map(A, A)),
}
end,

["codegen.codegen"] = function()
--------------------
-- Module: 'codegen.codegen'
--------------------
local Codegen = {}

function Codegen.generate(ast_nodes)
    local lines = {}
    local indent = 0

    -- class registry for the emitter: name → ClassDeclaration node.
    -- Full-tree walk: function-local and nested classes must resolve too
    -- (their `extends` chains and method copies depend on it). Innermost wins.
    local class_nodes = {}
    local function collect_classes(node)
        if type(node) ~= "table" then return end
        if node.type then
            if node.type == "ClassDeclaration" then
                local key = node.qname or node.name.name
                class_nodes[key] = node             -- outer first…
                collect_classes(node.body)          -- …nested overwrite: innermost wins
            end
            for k, v in pairs(node) do
                if k ~= "type" and type(v) == "table" then collect_classes(v) end
            end
        else
            for _, v in ipairs(node) do collect_classes(v) end
        end
    end
    collect_classes(ast_nodes)

    -- multiline-aware: continuation lines keep the current indentation
    local function emit(text)
        local start = 1
        while true do
            local nl = text:find("\n", start, true)
            local seg = nl and text:sub(start, nl - 1) or text:sub(start)
            lines[#lines + 1] = ("    "):rep(indent) .. seg
            if not nl then break end
            start = nl + 1
        end
    end

    local function namestr(n)
        if n.type == "Identifier" then return n.name end
        if n.type == "TableIndex" then return namestr(n.table) .. "." .. n.index.name end
        return "?"
    end

    local current_class = nil                             -- innermost class being emitted
    local codegen_stmt, codegen_expr, codegen_block       -- mutually recursive
    local prefix_str
    local codegen_stmt_raw                                -- depth-capped body
    local emit_depth = 0

    -- Lua prefixexp ::= var | functioncall | '(' exp ')' — literals, table
    -- constructors, and operators are NOT valid call/index receivers. Wrap.
    prefix_str = function(n)
        local s = codegen_expr(n)
        local k = n.type
        if k == "TableConstruction" or k == "String" or k == "Number"
           or k == "Boolean" or k == "Nil" or k == "VarArgs"
           or k == "BinaryOp" or k == "UnaryOp"
           or (k == "FunctionDeclaration" and not n.name) then
            return "(" .. s .. ")"
        end
        if k == "Paren" then return s end       -- already parenthesized
        return s
    end

    codegen_block = function(block)                        -- block = { statements = {...} }
        indent = indent + 1
        for _, s in ipairs(block.statements) do
            codegen_stmt(s)
        end
        indent = indent - 1
    end

    codegen_stmt = function(node)
        emit_depth = emit_depth + 1
        if emit_depth > 1500 then
            emit_depth = emit_depth - 1
            error("codegen: nesting too deep (limit 1500)")
        end
        codegen_stmt_raw(node)
        emit_depth = emit_depth - 1
    end

    codegen_stmt_raw = function(node)
        local kind = node.type

        if kind == "LocalDeclaration" then
            -- `local function f` desugars to Local{f, anon-fn}: the local must
            -- be PRE-DECLARED or the body's recursive call resolves to a global
            if #node.names == 1 and #node.values == 1
                  and node.values[1].type == "FunctionDeclaration"
                  and node.values[1].name == nil then
                emit("local " .. node.names[1].name)
                emit(node.names[1].name .. " = " .. codegen_expr(node.values[1]))
                return
            end
            local names, vals = {}, {}
            for _, n in ipairs(node.names) do names[#names + 1] = n.name end
            for _, v in ipairs(node.values) do vals[#vals + 1] = codegen_expr(v) end
            if #vals > 0 then
                emit("local " .. table.concat(names, ", ") .. " = " .. table.concat(vals, ", "))
            else
                emit("local " .. table.concat(names, ", "))
            end                                             -- declaration_type: dropped (erasure)

        elseif kind == "Assignment" then
            local targets, vals = {}, {}
            for _, t in ipairs(node.variables) do targets[#targets + 1] = codegen_expr(t) end
            for _, v in ipairs(node.values) do vals[#vals + 1] = codegen_expr(v) end
            emit(table.concat(targets, ", ") .. " = " .. table.concat(vals, ", "))

        elseif kind == "IfStatement" then
            -- elseif chains are NESTED IfStatements in elseBlock: walk them
            emit("if " .. codegen_expr(node.condition) .. " then")
            codegen_block(node.thenBlock)
            local eb = node.elseBlock
            while eb do
                if eb.type == "IfStatement" then
                    emit("elseif " .. codegen_expr(eb.condition) .. " then")
                    codegen_block(eb.thenBlock)
                    eb = eb.elseBlock
                else
                    emit("else")
                    codegen_block(eb)
                    eb = nil
                end
            end
            emit("end")

        elseif kind == "WhileLoop" then
            emit("while " .. codegen_expr(node.condition) .. " do")
            codegen_block(node.body)
            emit("end")

        elseif kind == "RepeatLoop" then
            emit("repeat")
            codegen_block(node.body)
            emit("until " .. codegen_expr(node.condition))

        elseif kind == "ForLoop" then
            local head = node.variable.name .. " = " .. codegen_expr(node.start)
                .. ", " .. codegen_expr(node.finish)
            if node.step then head = head .. ", " .. codegen_expr(node.step) end
            emit("for " .. head .. " do")
            codegen_block(node.body)
            emit("end")

        elseif kind == "ReturnStatement" then
            if #node.values == 0 then
                emit("return")
            else
                local vals = {}
                for _, v in ipairs(node.values) do vals[#vals + 1] = codegen_expr(v) end
                emit("return " .. table.concat(vals, ", "))
            end

        elseif kind == "BreakStatement" then
            emit("break")

        elseif kind == "Block" then                         -- do-block
            emit("do")
            codegen_block(node)
            emit("end")

        elseif kind == "FunctionDeclaration" then
            local params = {}
            for _, p in ipairs(node.parameters) do
                params[#params + 1] = (p.type == "Param") and p.name.name or "..."
            end
            if node.name then
                emit("function " .. namestr(node.name) .. "(" .. table.concat(params, ", ") .. ")")
                codegen_block(node.body)
                emit("end")
            else
                emit("local _ = " .. codegen_expr(node))    -- anonymous fn as a statement
            end

        elseif kind == "ForInLoop" then
            local vars, iters = {}, {}
            for _, v in ipairs(node.variables) do vars[#vars + 1] = v.name end
            for _, it in ipairs(node.iterators) do iters[#iters + 1] = codegen_expr(it) end
            emit("for " .. table.concat(vars, ", ") .. " in "
                .. table.concat(iters, ", ") .. " do")
            codegen_block(node.body)
            emit("end")

        elseif kind == "ClassDeclaration" then
            if node.class_type ~= "interface" then
                local cname = node.qname or node.name.name
                local saved_class = current_class
                current_class = node

                -- flat methods: __ClassName_method(self, rest...)
                -- nested ClassDeclaration members recurse (static-nested classes)
                for _, m in ipairs(node.body.statements) do
                    if m.type == "FunctionDeclaration" and m.body then
                        local params = {}
                        for i, p in ipairs(m.parameters) do
                            if i > 1 then params[#params + 1] = p.name.name end   -- self is implicit
                        end
                        emit("function __" .. cname .. "_" .. m.name.name
                            .. "(self" .. (#params > 0 and ", " .. table.concat(params, ", ") or "")
                            .. ")")
                        codegen_block(m.body)
                        emit("end")
                    elseif m.type == "ClassDeclaration" then
                        codegen_stmt(m)   -- nested class: flat names via its own qlname/cname
                    end
                end

                -- constructor: __ClassName_new(ctor_params) → instance with
                -- inherited methods copied in, base ctor chained, own fields set
                local ctor = {}
                for _, cp in ipairs(node.ctor_params or {}) do
                    ctor[#ctor + 1] = cp.name
                end
                -- ctor params come from the AST node's params (NOT the checker registry)
                local ctor = {}
                for _, p in ipairs(node.params or {}) do
                    ctor[#ctor + 1] = p.name.name
                end
                emit("function __" .. cname .. "_new(" .. table.concat(ctor, ", ") .. ")")
                indent = indent + 1
                if node.extends_name and class_nodes[node.extends_qname or node.extends_name.name] then
                    local sargs = {}
                    for _, a in ipairs(node.extends_args or {}) do
                        sargs[#sargs + 1] = codegen_expr(a)
                    end
                    emit("local self = __" .. (node.extends_qname or node.extends_name.name) .. "_new("
                        .. table.concat(sargs, ", ") .. ")")
                else
                    emit("local self = {}")
                end
                -- own fields from ctor params
                for _, p in ipairs(node.params or {}) do
                    emit("self." .. p.name.name .. " = " .. p.name.name)
                end
                -- method copies: BASE first, derived last — overrides win
                local chain = {}
                local cnode = node
                while cnode do
                    table.insert(chain, 1, cnode)
                    cnode = cnode.extends_name
                        and class_nodes[cnode.extends_qname or cnode.extends_name.name] or nil
                end
                for _, anc in ipairs(chain) do
                    for _, m in ipairs(anc.body.statements) do
                        if m.type == "FunctionDeclaration" then
                            emit("self." .. m.name.name .. " = __"
                                .. (anc.qname or anc.name.name) .. "_" .. m.name.name)
                        end
                    end
                end
                -- interface defaults fill gaps no ancestor covers
                for _, iq in ipairs(node.implements_qnames or {}) do
                    local iface_node = class_nodes[iq]
                    if iface_node then
                        for _, m in ipairs(iface_node.body.statements) do
                            if m.type == "FunctionDeclaration" and m.body and #m.body.statements > 0 then
                                local defined = false
                                for _, anc in ipairs(chain) do
                                    for _, am in ipairs(anc.body.statements) do
                                        if am.type == "FunctionDeclaration"
                                              and am.name.name == m.name.name then
                                            defined = true
                                        end
                                    end
                                end
                                if not defined then
                                    emit("self." .. m.name.name .. " = __" .. iq .. "_" .. m.name.name)
                                end
                            end
                        end
                    end
                end
                emit("return self")
                indent = indent - 1
                emit("end")

                -- object singletons: the name IS the one instance
                if node.class_type == "object" then
                    emit(node.name.name .. " = __" .. cname .. "_new()")
                end
                current_class = saved_class
            else
                -- interface v2: default methods carry CODE — flat functions
                -- implementing classes reuse when they define none of their own
                local iq = node.qname or node.name.name
                for _, m in ipairs(node.body.statements) do
                    if m.type == "FunctionDeclaration" and m.body and #m.body.statements > 0 then
                        local params = {}
                        for i, p in ipairs(m.parameters) do
                            if i > 1 then params[#params + 1] = p.name.name end
                        end
                        emit("function __" .. iq .. "_" .. m.name.name
                            .. "(self" .. (#params > 0 and ", " .. table.concat(params, ", ") or "") .. ")")
                        codegen_block(m.body)
                        emit("end")
                    end
                end
            end

        else
            -- expression statements (calls): FunctionCall / MethodCall / Identifier
            emit(codegen_expr(node))
        end
    end

    -- The expression walk. v1 policy: parenthesize all binary/unary
    -- sub-expressions — correct-but-ugly beats pretty-but-wrong.
    codegen_expr = function(node)
        local kind = node.type
        if kind == "Number" then
            -- raw lexer text prints verbatim (10e500 stays 10e500 — printing
            -- tostring(inf) would emit a bare identifier into the output).
            -- Programmatic float values get the non-finite guard instead:
            -- `inf`/`nan` are not number literals in Lua 5.1.
            if type(node.value) == "string" then return node.value end
            local v = node.value
            if v ~= v then return "(0/0)" end
            if v == math.huge then return "(1/0)" end
            if v == -math.huge then return "(-1/0)" end
            return tostring(v)
        end
        if kind == "String" then
            -- %q escapes newlines as backslash+REAL newline; emit()'s
            -- re-indent would then inject spaces INTO the literal and shift
            -- embedded line numbers. Convert to plain \n escapes.
            return (string.format("%q", node.value):gsub("\\\n", "\\n"))
        end
        if kind == "Boolean" then return tostring(node.value) end
        if kind == "Nil" then return "nil" end
        if kind == "VarArgs" then return "..." end
        if kind == "Identifier" then return node.name end
        if kind == "Paren" then return "(" .. codegen_expr(node.expr) .. ")" end

        if kind == "BinaryOp" then
            return "(" .. codegen_expr(node.left) .. " " .. node.operator
                .. " " .. codegen_expr(node.right) .. ")"
        end
        if kind == "UnaryOp" then
            return "(" .. node.operator .. " " .. codegen_expr(node.operand) .. ")"
        end

        if kind == "TableIndex" then
            if node.via_dot then
                return prefix_str(node.table) .. "." .. node.index.name
            end
            return prefix_str(node.table) .. "[" .. codegen_expr(node.index) .. "]"
        end

        if kind == "FunctionCall" and node.ctor_class then
            local args = {}
            for _, a in ipairs(node.arguments) do args[#args + 1] = codegen_expr(a) end
            return "__" .. node.ctor_class .. "_new(" .. table.concat(args, ", ") .. ")"
        end

        if kind == "FunctionCall" then
            local args = {}
            for _, a in ipairs(node.arguments) do args[#args + 1] = codegen_expr(a) end
            -- static qualified member call: Outer.Inner.m(x) -> flat call
            -- (the caller passes self explicitly; nothing is injected)
            if node.func.type == "TableIndex" and node.func.static_owner then
                return "__" .. node.func.static_owner .. "_" .. node.func.static_name
                    .. "(" .. table.concat(args, ", ") .. ")"
            end
            return prefix_str(node.func) .. "(" .. table.concat(args, ", ") .. ")"
        end

        if kind == "SuperCall" then
            -- super.m(args) → nearest ancestor's flat method, self explicit
            local base = current_class and current_class.extends_name
                and class_nodes[current_class.extends_qname or current_class.extends_name.name] or nil
            while base do
                local found = false
                for _, m in ipairs(base.body.statements) do
                    if m.type == "FunctionDeclaration"
                          and m.name.name == node.method_name.name then
                        found = true
                        break
                    end
                end
                if found then break end
                base = base.extends_name
                    and class_nodes[base.extends_qname or base.extends_name.name] or nil
            end
            if not base then
                error("codegen: no ancestor defines method '"
                    .. node.method_name.name .. "' for super call")
            end
            local args = { "self" }
            for _, a in ipairs(node.arguments) do args[#args + 1] = codegen_expr(a) end
            return "__" .. base.name.name .. "_" .. node.method_name.name
                .. "(" .. table.concat(args, ", ") .. ")"
        end
        if kind == "MethodCall" then
            local args = {}
            for _, a in ipairs(node.arguments) do args[#args + 1] = codegen_expr(a) end
            if node.devirt_owner then
                -- §8 devirtualization: static dispatch to the owning class's flat method
                return "__" .. node.devirt_owner .. "_" .. node.method_name.name
                    .. "(" .. codegen_expr(node.object)
                    .. (next(node.arguments) and ", " .. table.concat(args, ", ") or "") .. ")"
            end
            -- dynamic fallback: interface-typed receivers — instances carry methods
            return prefix_str(node.object) .. ":" .. node.method_name.name
                .. "(" .. table.concat(args, ", ") .. ")"
        end

        if kind == "TableConstruction" then
            local parts = {}
            for _, f in ipairs(node.fields) do
                if f.computed then
                    parts[#parts + 1] = "[" .. codegen_expr(f.name) .. "] = " .. codegen_expr(f.value)
                elseif f.name then
                    parts[#parts + 1] = f.name.name .. " = " .. codegen_expr(f.value)
                else
                    parts[#parts + 1] = codegen_expr(f.value)   -- positional / shorthand
                end
            end
            return "{" .. table.concat(parts, ", ") .. "}"
        end

        if kind == "FunctionDeclaration" then
            -- anonymous function in expression position (multi-line capable)
            local params = {}
            for _, p in ipairs(node.parameters) do
                params[#params + 1] = (p.type == "Param") and p.name.name or "..."
            end
            local saved, saved_indent = lines, indent
            lines, indent = {}, indent + 1
            for _, s in ipairs(node.body.statements) do
                codegen_stmt(s)
            end
            local body = table.concat(lines, "\n")
            lines, indent = saved, saved_indent
            return "function(" .. table.concat(params, ", ") .. ")\n" .. body .. "\nend"
        end

        if kind == "NotNullAssertion" then
        return "(function()\nlocal __nn = " .. codegen_expr(node.operand)
        .. "\nif __nn == nil then error(\"nil assertion failed\") end"
        .. "\nreturn __nn\nend)()"
        end

        if kind == "Elvis" then
        return "(function()\nlocal __ee = " .. codegen_expr(node.left)
        .. "\nif __ee ~= nil then return __ee end"
        .. "\nreturn " .. codegen_expr(node.right)
        .. "\nend)()"
        end

        if kind == "SafeAccess" then
            local acc = node.access
            local recv = { type = "Identifier", name = "__ss" }
            local rewritten
            if acc.type == "TableIndex" then
                rewritten = { type = "TableIndex", table = recv,
                    index = acc.index, via_dot = acc.via_dot }   -- via_dot must survive
            else
                rewritten = { type = "MethodCall", object = recv,
                    method_name = acc.method_name, arguments = acc.arguments }
            end
            return "(function()\nlocal __ss = " .. codegen_expr(node.object)
                .. "\nif __ss ~= nil then return " .. codegen_expr(rewritten) .. " end"
                .. "\nreturn nil\nend)()"
        end

        error("codegen: cannot emit expression '" .. tostring(kind) .. "'")
    end

    for _, stmt in ipairs(ast_nodes) do
        codegen_stmt(stmt)
    end
    return table.concat(lines, "\n")
end

return Codegen
end,

["helpers.compile_helpers"] = function()
--------------------
-- Module: 'helpers.compile_helpers'
--------------------
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
        local names = {}
        for _, n in ipairs(node.names or {}) do
            names[#names + 1] = n.name
        end
        print(indent .. "LocalDeclaration: " .. table.concat(names, ", "))
        for _, v in ipairs(node.values or {}) do
            print(indent .. "  value:")
            Helpers.print_ast(v, indent .. "    ")
        end
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

end,

----------------------
-- Modules part end --
----------------------
        }
        if files[path] then
            return files[path]
        else
            return origin_seacher(path)
        end
    end
end
---------------------------------------------------------
----------------Auto generated code block----------------
---------------------------------------------------------
-- resolve imports relative to THIS script, not the caller's cwd
-- (lua5.1 ../main.lua from a subdirectory must still find codegen/)
local script_dir = (arg and arg[0] or ""):match("^(.*)/") or "."
package.path = script_dir .. "/?.lua;" .. package.path

local codegen = require("codegen.codegen")
local parser = require("parser.parser")
local helpers = require("helpers.compile_helpers")
local checker = require("checker.checker")

local verbose = false
local help = false
local run = false
local output_path = nil
local input_path = nil

local function usage()
    print("Usage: lua main.lua <input.sol | input.lua> [options]")
    print("Options:")
    print("  -o, --output <file>  Write generated Lua to <file> (default: stdout)")
    print("  --run                Compile and execute in-process")
    print("  -v, --verbose        Dump tokens and AST before compiling")
    print("  -h, --help           Show this help message")
end

local i = 1
while i <= #arg do
    local a = arg[i]
    if a == "-v" or a == "--verbose" then
        verbose = true
    elseif a == "-h" or a == "--help" then
        usage()
        help = true
    elseif a == "--run" or a == "-i" or a == "--interpret" then
        run = true
    elseif a == "-o" or a == "--output" then
        i = i + 1
        output_path = arg[i]
        if not output_path then
            print("error: -o requires a filename")
            os.exit(1)
        end
    else
        input_path = a
    end
    i = i + 1
end

local function fail(msg)
    local s = tostring(msg)
    print(s:match("^.-:%d+: (.+)$") or s)   -- strip 'path:line: ' prefixes only
    os.exit(1)
end

function main()
    if help then return end

    -- input: positional file (dialect by extension) or stdin
    local source
    if input_path then
        local fh, err = io.open(input_path, "r")
        if not fh then fail("cannot open '" .. input_path .. "': " .. tostring(err)) end
        source = fh:read("*a")
        fh:close()
    else
        source = io.read("*a")
    end
    if not source or source == "" then
        fail("no input: give a file path or pipe source on stdin")
    end

    -- dialect from the extension: .lua = plain Lua mode, anything else = soleil
    local dialect = (input_path or ""):match("%.lua$") and "lua" or "soleil"

    -- tokenize -> parse -> check -> generate; every tier fails loud
    local ok, tokens, markers = pcall(parser.tokenize, source, dialect)
    if not ok then fail(tokens) end

    if verbose then
        print("=== TOKENS ===")
        helpers.print_tokens(tokens)
        print()
    end

    -- pcall returns (ok, ret1, ret2, ...) FLAT: the tree and meta are separate
    local ok2, ast_tree, meta = pcall(parser.parse, tokens, markers)
    if not ok2 then fail(ast_tree) end

    if verbose then
        print("=== AST ===")
        helpers.print_ast_tree(ast_tree)
    end

    local ok3, err = pcall(checker.check, ast_tree, meta)
    if not ok3 then fail(err) end

    local ok4, lua_source = pcall(codegen.generate, ast_tree)
    if not ok4 then fail(lua_source) end

    if run then
        local chunk, load_err = loadstring(lua_source, "=" .. (input_path or "stdin"))
        if not chunk then fail("generated code failed to load: " .. tostring(load_err)) end
        local run_ok, run_err = pcall(chunk)
        if not run_ok then fail("runtime: " .. tostring(run_err)) end
    elseif output_path then
        local out, oerr = io.open(output_path, "w")
        if not out then fail("cannot write '" .. output_path .. "': " .. tostring(oerr)) end
        out:write(lua_source, "\n")
        out:close()
        print("wrote " .. output_path)
    else
        print(lua_source)
    end
end

main()