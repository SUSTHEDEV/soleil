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