local Codegen = {}

function Codegen.generate(ast_nodes)
    local lines = {}
    local indent = 0

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

    local codegen_stmt, codegen_expr, codegen_block       -- mutually recursive

    codegen_block = function(block)                        -- block = { statements = {...} }
        indent = indent + 1
        for _, s in ipairs(block.statements) do
            codegen_stmt(s)
        end
        indent = indent - 1
    end

    codegen_stmt = function(node)
        local kind = node.type

        if kind == "LocalDeclaration" then
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
            emit("if " .. codegen_expr(node.condition) .. " then")
            codegen_block(node.thenBlock)
            if node.elseBlock then
                if node.elseBlock.type == "IfStatement" then
                    emit("elseif " .. codegen_expr(node.elseBlock.condition) .. " then")
                    -- NOTE: recurse specially — see below
                    codegen_block(node.elseBlock.thenBlock)
                    if node.elseBlock.elseBlock then
                        emit("else")
                        codegen_block(node.elseBlock.elseBlock)
                    end
                    emit("end")
                else
                    emit("else")
                    codegen_block(node.elseBlock)
                    emit("end")
                end
            else
                emit("end")
            end

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

        else
            -- expression statements (calls): FunctionCall / MethodCall / Identifier
            emit(codegen_expr(node))
        end
    end

    -- The expression walk. v1 policy: parenthesize all binary/unary
    -- sub-expressions — correct-but-ugly beats pretty-but-wrong.
    codegen_expr = function(node)
        local kind = node.type
        if kind == "Number" then return tostring(node.value) end
        if kind == "String" then return string.format("%q", node.value) end
        if kind == "Boolean" then return tostring(node.value) end
        if kind == "Nil" then return "nil" end
        if kind == "VarArgs" then return "..." end
        if kind == "Identifier" then return node.name end

        if kind == "BinaryOp" then
            return "(" .. codegen_expr(node.left) .. " " .. node.operator
                .. " " .. codegen_expr(node.right) .. ")"
        end
        if kind == "UnaryOp" then
            return "(" .. node.operator .. " " .. codegen_expr(node.operand) .. ")"
        end

        if kind == "TableIndex" then
            if node.via_dot then
                return codegen_expr(node.table) .. "." .. node.index.name
            end
            return codegen_expr(node.table) .. "[" .. codegen_expr(node.index) .. "]"
        end

        if kind == "FunctionCall" then
            local args = {}
            for _, a in ipairs(node.arguments) do args[#args + 1] = codegen_expr(a) end
            return codegen_expr(node.func) .. "(" .. table.concat(args, ", ") .. ")"
        end

        if kind == "MethodCall" then
            local args = {}
            for _, a in ipairs(node.arguments) do args[#args + 1] = codegen_expr(a) end
            return codegen_expr(node.object) .. ":" .. node.method_name.name
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

        error("codegen: cannot emit expression '" .. tostring(kind) .. "'")
    end

    for _, stmt in ipairs(ast_nodes) do
        codegen_stmt(stmt)
    end
    return table.concat(lines, "\n")
end

return Codegen