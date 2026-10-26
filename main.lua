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
