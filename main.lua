local ast = require("ast.ast")
local codegen = require("codegen.codegen")
local parser = require("parser.parser")
local helpers = require("helpers.compile_helpers")
local Checker = require("checker.checker")

-- Check if verbose flag is enabled
local verbose = false
local help = false
local compile = false
local output_path = nil
local interpret = false

local i = 1
while i <= #arg do
    local a = arg[i]
    if a == "-v" or a == "--verbose" then
        verbose = true
    elseif a == "-h" or a == "--help" then
        print("Usage: lua main.lua [options]")
        print("Options:")
        print("  -v, --verbose   Enable verbose output (tokens and AST)")
        print("  -h, --help      Show this help message")
        print("  -c, --compile   Compile the input")
        print("  --luajit        Compile to LuaJIT")
        print("  -o, --output <file>  Write generated Lua to <file>")
        print("  -i, --interpret Interpret the input")
        help = true
    elseif a == "-c" or a == "--compile" then
        compile = true
    elseif a == "--luajit" then
        print("LuaJIT option is not implemented yet.")
    elseif a == "-o" or a == "--output" then
        i = i + 1
        output_path = arg[i]
        if not output_path then
            print("error: -o requires a filename")
            os.exit(1)
        end
    elseif a == "-i" or a == "--interpret" then
        interpret = true
    elseif a == "--bytecode" then
        print("Bytecode option is not implemented yet.")
    else
        print("Unknown option: " .. a)
        print("Use -h or --help for usage information.")
    end
    i = i + 1
end

function main()
    if not help then
        local input = [[
            local x = 10
            if x > 5 then
                print("x is greater than 5")
            elseif x == 5 then
                print("x is equal to 5")
            else
                print("x is less than or equal to 5")
            end
            function c(a, b)
                if a > b and a and b then
                    return a - b
                else
                    return b - a
                end
            end
            local t = {}
            local obj = {}
            obj.b = function(self, x)
                return x
            end
            print(obj:b(7))
            for i, v in ipairs(t) do
                print(i, v)
            end
            while x > 0 do
                x = x - 1
            end
            for i = 1, 10, 2 do
                print(i)
            end
            repeat
                x = x + 1
            until x >= 10
        ]]

        -- Tokenize the input (dialect comes from the extension)
        local dialect = (input_path or ""):match("%.lua$") and "lua" or "soleil"
        local tokens = parser.tokenize(input, dialect)
        
        if verbose then
            print("=== TOKENS ===")
            helpers.print_tokens(tokens)
            print()
        end
        
        local ast_tree, meta = parser.parse(tokens)

        -- Print the AST only if verbose flag is set
        if verbose then
            print("=== AST ===")
            helpers.print_ast_tree(ast_tree)
        end

        -- Type-check: loud — abort on the first violation
        local ok, err = pcall(Checker.check, ast_tree, meta)
        if not ok then
            print(tostring(err):gsub("^.-: ", ""))
            os.exit(1)
        end

        -- Generate plain Lua 5.1 from the checked AST (types are erased)
        local lua_source = codegen.generate(ast_tree)

        if output_path then
            local fh = io.open(output_path, "w")
            fh:write(lua_source .. "\n")
            fh:close()
            print("wrote " .. output_path)
        else
            print(lua_source)
        end
    end
end

main()