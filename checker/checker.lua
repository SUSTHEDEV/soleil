-- checker/checker.lua — the Soleil type checker
-- Tree-walking, no execution. Walks the AST the parser produced, infers
-- expression types, and checks them against declarations (SPEC §2-§5).
-- Loud by contract: every violation raises with a line number.

local Checker = {}

-- ===========================================================================
-- 1. TYPE MODEL (internal — converted from AST type nodes, never reused raw)
--    T := { kind = "primitive", name = "number"|"string"|"boolean"|"nil"|"any" }
--       | { kind = "table", form = "array"|"map"|"any", key = T, value = T }
--       | { kind = "function", params = {T,...}, ret = T, varargs = boolean }
--       | { kind = "union", members = {T,...} }        -- nil-ness lives in members
--       | { kind = "class", name = string }            -- §4, future
-- ===========================================================================

local function prim(name) return { kind = "primitive", name = name } end
local T_NUMBER, T_STRING, T_BOOLEAN = prim("number"), prim("string"), prim("boolean")
local T_NIL, T_ANY = prim("nil"), prim("any")

local function union(members) return { kind = "union", members = members } end

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

-- ===========================================================================
-- 2. AST TYPE NODE -> INTERNAL TYPE
--    Nullable is normalized away: T? becomes union{T, nil} — the one
--    canonical representation decided for nullability.
-- ===========================================================================

local function from_ast(node)
    if not node then return T_ANY end
    if node.type == "Type" then
        local name = node.type_name
        local base
        if name == "number" or name == "string" or name == "boolean" or name == "nil" or name == "any" then
            base = prim(name)
        else
            -- unknown names are loud until classes land (§4)
            error("unknown type '" .. name .. "'")
        end
        if node.nullable then
            return union({ base, T_NIL })
        end
        return base
    elseif node.type == "TableType" then
        return {
            kind = "table",
            form = node.form,
            key = from_ast(node.key),
            value = from_ast(node.value),
        }
    elseif node.type == "UnionType" then
        local members = {}
        for _, m in ipairs(node.types) do
            members[#members + 1] = from_ast(m)
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

    if src.kind == "primitive" and dst.kind == "primitive" then
        return src.name == dst.name
    end

    if src.kind == "table" and dst.kind == "table" then
        if dst.form == "any" or src.form == "any" then return true end
        if src.form ~= dst.form then return false end
        return compatible(src.key, dst.key) and compatible(src.value, dst.value)
    end

    return false
end

-- ===========================================================================
-- 4. SCOPE CHAIN — block-structured symbol table
-- ===========================================================================

local function new_scope(parent, in_loop)
    return { vars = {}, parent = parent, in_loop = in_loop or false }
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

local function type_error(msg, node)
    local where = ""
    if node and node.line then where = " at line " .. node.line end
    error("type error" .. where .. ": " .. msg)
end

-- ===========================================================================
-- 6. THE WALK
-- ===========================================================================

local check_stmt, infer_expr  -- mutually recursive

-- infer_expr(node, scope) -> T  — the type of an expression, or raise
infer_expr = function(node, scope)
    local kind = node.type

    if kind == "Number" then return T_NUMBER end
    if kind == "String" then return T_STRING end
    if kind == "Boolean" then return T_BOOLEAN end
    if kind == "Nil" then return T_NIL end
    if kind == "VarArgs" then return T_ANY end

    if kind == "Identifier" then
        local t = lookup(scope, node.name)
        if not t then
            type_error("undefined variable '" .. node.name .. "'", node)
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
        -- positional-only -> array; has named/computed keys -> map; mixed -> any
        local has_named, has_positional = false, false
        for _, f in ipairs(node.fields) do
            if f.name then has_named = true else has_positional = true end
            infer_expr(f.value, scope)
        end
        if has_named and not has_positional then
            return { kind = "table", form = "map", key = T_STRING, value = T_ANY }
        elseif has_positional and not has_named then
            return { kind = "table", form = "array", key = T_NUMBER, value = T_ANY }
        else
            return { kind = "table", form = "any", key = T_ANY, value = T_ANY }
        end
    end

    if kind == "TableIndex" then
        -- §3: reads of tables yield the value type WRAPPED NULLABLE
        local t = infer_expr(node.table, scope)
        if not node.via_dot then
            infer_expr(node.index, scope)   -- t[k]: the index is a real expression
        end                                  -- t.k: the index is a literal key name
        if t.kind == "table" then
            if contains_nil(t.value) then return t.value end
            return union({ t.value, T_NIL })
        end
        type_error("cannot index a non-table value", node)
    end

    if kind == "FunctionCall" then
        local ft = infer_expr(node.func, scope)
        -- TODO (Step 3, §5): check ft is a function type, arity, arg types
        for _, a in ipairs(node.arguments) do infer_expr(a, scope) end
        return T_ANY
    end

    if kind == "MethodCall" then
        infer_expr(node.object, scope)
        -- TODO (Step 3): resolve method on the object's type
        for _, a in ipairs(node.arguments) do infer_expr(a, scope) end
        return T_ANY
    end

    if kind == "FunctionDeclaration" then
        -- anonymous function in expression position: build its function type
        local params = {}
        for _, p in ipairs(node.parameters) do
            params[#params + 1] = p.param_type and from_ast(p.param_type) or T_ANY
        end
        -- TODO (Step 3): child scope, check body, all-paths-return (§5)
        return { kind = "function", params = params,
                 ret = node.return_type and from_ast(node.return_type) or T_ANY,
                 varargs = false }
    end

    type_error("checker: cannot infer expression type '" .. kind .. "'", node)
end

-- check_stmt(node, scope) — statements produce nothing; they constrain
check_stmt = function(node, scope)
    local kind = node.type

    if kind == "LocalDeclaration" then
        local declared = node.declaration_type and from_ast(node.declaration_type) or nil
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
        for i, target in ipairs(node.variables) do
            local t = lookup(scope, target.name or "")
            if target.type == "TableIndex" then
                -- t[k] = v — check value against the table's value type
                local tt = infer_expr(target.table, scope)
                local vt = node.values[i] and infer_expr(node.values[i], scope)
                if tt.kind == "union" then
                    type_error("cannot index a possibly nil value", node)
                end
                if tt and tt.kind == "table" and vt then
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
        local then_scope = new_scope(scope)
        for _, s in ipairs(node.thenBlock.statements) do
            check_stmt(s, then_scope)
        end
        if node.elseBlock then
            if node.elseBlock.type == "Block" then
                local else_scope = new_scope(scope)
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
        for _, it in ipairs(node.iterators) do
            infer_expr(it, scope)
        end
        local body_scope = new_scope(scope, true)
        for _, v in ipairs(node.variables) do
            -- TODO (Step 4): iterator types from pairs/ipairs signatures
            declare(body_scope, v.name, T_ANY)
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
        for _, v in ipairs(node.values) do
            infer_expr(v, scope)
        end
        -- TODO (Step 3, §5): check values against the enclosing function's return type
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
        -- named function: build type, declare, then check body in a child scope
        local params = {}
        for _, p in ipairs(node.parameters) do
            params[#params + 1] = p.param_type and from_ast(p.param_type) or T_ANY
        end
        local fn_type = {
            kind = "function",
            params = params,
            ret = node.return_type and from_ast(node.return_type) or T_ANY,
            varargs = false,
        }
        if node.name then
            -- dotted names (a.b.c) are pre-declared by earlier code — v1: simple names only
            declare(scope, node.name.name, fn_type)
        end
        local fn_scope = new_scope(scope)
        for i, p in ipairs(node.parameters) do
            declare(fn_scope, p.name.name, params[i])
        end
        for _, s in ipairs(node.body.statements) do
            check_stmt(s, fn_scope)
        end
        return
    end

    if kind == "FunctionCall" or kind == "MethodCall" then
        infer_expr(node, scope)  -- expression statement: still infer for side-effect errors
        return
    end

    type_error("checker: unknown statement '" .. tostring(kind) .. "'", node)
end

-- Checker.check(ast_nodes) — entry point: a list of top-level statements
function Checker.check(ast_nodes)
    local global_scope = new_scope(nil)
    -- minimal stdlib stubs — real signatures are Step 4 (§7)
    declare(global_scope, "print", T_ANY)
    declare(global_scope, "pairs", T_ANY)
    declare(global_scope, "ipairs", T_ANY)
    declare(global_scope, "type", T_ANY)
    declare(global_scope, "tostring", T_ANY)
    declare(global_scope, "tonumber", T_ANY)
    declare(global_scope, "error", T_ANY)
    declare(global_scope, "pcall", T_ANY)
    declare(global_scope, "setmetatable", T_ANY)
    declare(global_scope, "getmetatable", T_ANY)
    declare(global_scope, "string", T_ANY)
    declare(global_scope, "math", T_ANY)
    declare(global_scope, "table", T_ANY)
    for _, stmt in ipairs(ast_nodes) do
        check_stmt(stmt, global_scope)
    end
end

return Checker
