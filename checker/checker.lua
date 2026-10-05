-- checker/checker.lua — the Soleil type checker
-- Tree-walking, no execution. Walks the AST the parser produced, infers
-- expression types, and checks them against declarations (SPEC §2-§5).
-- Loud by contract: every violation raises with a line number.

local stdlib = require("checker.stdlib") -- header for stdlib type checking
local Checker = {}

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

local function union(members) return { kind = "union", members = members } end
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

local options = require("config.config")

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

local function from_ast(node)
    if not node then return T_ANY end
    if node.type == "Type" then
        local name = node.type_name
        local base
        if name == "number" or name == "string" or name == "boolean" or name == "nil" or name == "any" or name == "unknown" then
            base = prim(name)
        else 
            local ct = class_registry[name]
            -- unknown names are loud until classes land (§4)
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
        if src.form ~= dst.form then return false end
        return compatible(src.key, dst.key) and compatible(src.value, dst.value)
    end
    if src.kind == "record" or dst.kind == "record" then return src == dst end
    if src.kind == "class" and dst.kind == "class" then
        local c = src
        while c do
            if c.name == dst.name then return true end
            c = c.base_class
        end
        return false
    end
    return false
end

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
            local m = c[table_name][member_name]
            if m then return m end
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

local check_stmt, infer_expr  -- mutually recursive

local function type_error(msg, node)
    local where = ""
    if node and node.line then where = " at line " .. node.line end
    error("type error" .. where .. ": " .. msg)
end

local function check_fn_body(node, fn_type, parent_scope)
    fn_type.rets = {}
    for _, rt in ipairs(node.return_types or {}) do
        fn_type.rets[#fn_type.rets + 1] = from_ast(rt)
    end
    fn_type.ret = fn_type.rets[1] or T_ANY    -- head: existing consumers keep working
    local fn_scope = new_scope(parent_scope, false, fn_type.rets)
    for _, p in ipairs(node.parameters) do
        if p.type == "Param" then
            local pt = p.param_type and from_ast(p.param_type) or T_ANY
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
infer_expr = function(node, scope)
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
        local ft = infer_expr(node.func, scope)
        if ft.kind ~= "function" then
            if ft.kind == "primitive" and ft.name == "any" then
                for _, a in ipairs(node.arguments) do infer_expr(a, scope) end
                return T_ANY                     -- untyped callee: check args, trust result
            end
            if ft.kind == "class" then
                if ft.singleton or ft.abstract or ft.class_type == "interface" then
                    type_error(ft.name .. " cannot be instantiated", node)   -- per-kind rules
                end
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
            if not m then
                type_error("no such method '" .. node.method_name.name
                    .. "' in class '" .. obj_t.name .. "'", node)
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
                          ret = node.return_types and from_ast(node.return_types[1]) or T_ANY,
                          varargs = false }
        for _, rt in ipairs(node.return_types or {}) do
            fn_type.rets[#fn_type.rets + 1] = from_ast(rt)
        end
        fn_type.ret = fn_type.rets[1] or T_ANY
    end

    if kind == "FunctionDeclaration" then
        local fn_type = { kind = "function", params = {}, rets = {}, varargs = false }
        check_fn_body(node, fn_type, scope)
        return fn_type                                          -- the type IS the result
    end

    if kind == "ClassDeclaration" then
        local fn_type = {kind = "class"}
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
    if node.type == "FunctionCall" then
        local ft = infer_expr(node.func, scope)   -- callee's function type → rets
        if ft.kind == "function" and ft.rets and #ft.rets > 0 then
            return ft.rets
        end
    end
    return nil
end

-- check_stmt(node, scope) — statements produce nothing; they constrain
check_stmt = function(node, scope)
    local kind = node.type

    if kind == "LocalDeclaration" then
        local declared = node.declaration_type and from_ast(node.declaration_type) or nil
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
        local ct = class_registry[node.name.name]
        declare(scope, node.name.name, ct)
        local class_scope = new_scope(scope)
        class_scope.class_type = ct              -- §4.5 field trust reads this via self
        class_scope.current_class_type = ct      -- super resolution reads this
        local seen = {}
        for _, m in ipairs(node.body.statements) do
            local fn_type = { kind = "function", params = {}, rets = {}, varargs = false }
            -- params loop (Param → build+declare, VarArgs → reject in classes)
            -- rule 2: first param must be named self, typed compatibly with ct
            ct.methods[m.name.name] = fn_type      -- shared reference: filled by check_fn_body
            fn_type.overrides = m.overrides        -- rule 7 needs the flag on the type
            fn_type.line = m.line                  -- and the line, for rule 7's errors
            if kind == "interface" or (abstract and #m.body.statements == 0) then
                fn_type.signature_only = true
            end
            check_fn_body(m, fn_type, class_scope)
            seen[m.name.name] = true
        end
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
            local fields = {}
            for _, p in ipairs(stmt.params) do
                fields[p.name.name] = p.param_type and from_ast(p.param_type) or T_ANY
            end
            local ct = class(stmt.name.name, stmt.class_type,
                stmt.abstract, fields, {}, nil)   -- base_class wired in pass 2
            ct.line = stmt.line
            local ctor_params = {}                          -- ← ADD: ordered, for constructor calls
            for _, p in ipairs(stmt.params) do              -- ← ADD
                ctor_params[#ctor_params + 1] = {           -- ← ADD
                    name = p.name.name,                     -- ← ADD
                    ptype = p.param_type and from_ast(p.param_type) or T_ANY,  -- ← ADD
                }                                           -- ← ADD
            end                                             -- ← ADD
            ct.ctor_params = ctor_params                    -- ← ADD
            class_types[stmt.name.name] = ct
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
    for _, ct in pairs(class_types) do
        for mname, m in pairs(ct.methods) do
            local found, ancestor_m = false, nil
            local c = ct.base_class
            while c do
                if c.class_type ~= "interface" and c.methods[mname] then   -- interfaces don't demand override
                    found, ancestor_m = true, c.methods[mname]
                    break
                end
                c = c.base_class
            end
            if m.overrides and not found then
                type_error("method '" .. mname .. "' overrides nothing", m)
            end
            if found and not m.overrides then
                type_error("method '" .. mname .. "' must be declared with 'override'", m)
            end
            if found and m.overrides then
                if #m.params ~= #ancestor_m.params then
                    type_error("override of '" .. mname .. "' has a different parameter count", m)
                end
                if m.ret and ancestor_m.ret and not compatible(m.ret, ancestor_m.ret) then
                    type_error("override of '" .. mname .. "' has an incompatible return type", m)
                end
                -- rule 2: self may narrow (Admin <: Player), never widen   ← INSERT
                local s_self, a_self = m.params[1], ancestor_m.params[1]
                if s_self and a_self
                   and not compatible(s_self, a_self) then
                    type_error("override of '" .. mname .. "' has an incompatible self type", m)
                end
            end
        end
    end
    for _, ct in pairs(class_types) do
        if ct.base_class then
            local satisfied = {}
            local c = ct.base_class
            while c do
                if c.class_type == "interface" and not satisfied[c.name] then
                    satisfied[c.name] = true
                    for fname, ftype in pairs(c.fields) do
                        local provided = find_member(ct, "fields", fname)
                        if not provided then
                            type_error("class '" .. ct.name .. "' does not implement field '"
                                .. fname .. "' from interface '" .. c.name .. "'", ct)
                        elseif not compatible(ftype, provided) then
                            type_error("field '" .. fname .. "' has an incompatible type for interface '"
                                .. c.name .. "'", ct)
                        end
                    end
                    for mname, m in pairs(c.methods) do
                        local impl = find_member(ct, "methods", mname)
                        if not impl then
                            type_error("class '" .. ct.name .. "' does not implement method '"
                                .. mname .. "' from interface '" .. c.name .. "'", ct)
                        elseif #impl.params ~= #m.params then
                            type_error("method '" .. mname .. "' has a different parameter count than interface '"
                                .. c.name .. "'", ct)
                        elseif impl.ret and m.ret and not compatible(impl.ret, m.ret) then
                            type_error("method '" .. mname .. "' has an incompatible return type for interface '"
                                .. c.name .. "'", ct)
                        end
                    end
                end
                c = c.base_class
            end
        end
    end
end

return Checker
