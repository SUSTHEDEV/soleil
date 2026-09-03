local ast = require("ast.ast")
local codegen = require("codegen.codegen")
local parser = require("parser.parser")
local helpers = require("helpers.compile_helpers")

-- Check if verbose flag is enabled
local verbose = false
local help = false
local compile = false
local output = false
local interpret = false

for _, arg in ipairs(arg) do
    if arg == "-v" or arg == "--verbose" then
        verbose = true
    elseif arg == "-h" or arg == "--help" then
        print("Usage: lua main.lua [options]")
        print("Options:")
        print("  -v, --verbose   Enable verbose output (tokens and AST)")
        print("  -h, --help      Show this help message")
        print("  -c, --compile   Compile the input")
        print("  --luajit        Compile to LuaJIT")
        print("  -o, --output    Output file")
        print("  -i, --interpret Interpret the input")
        help = true
    elseif arg == "-c" or arg == "--compile" then
        compile = true
    elseif arg == "--luajit" then
        print("LuaJIT option is not implemented yet.")
    elseif arg == "-o" or arg == "--output" then
        output = true
    elseif arg == "-i" or arg == "--interpret" then
        interpret = true
    elseif arg == "--bytecode" then
        print("Bytecode option is not implemented yet.")
    else
        print("Unknown option: " .. arg)
        print("Use -h or --help for usage information.")
    end
end

function main()
    if not help then
        local input = [[
            local x = 10
            y = 3
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
            a.b(a,x)
            a.b(x)
            a:b(x)
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

        -- Tokenize the input
        local tokens = parser.tokenize(input)
        
        if verbose then
            print("=== TOKENS ===")
            helpers.print_tokens(tokens)
            print()
        end
        
        local ast_tree = parser.parse(tokens)

        -- Print the AST only if verbose flag is set
        if verbose then
            print("=== AST ===")
            helpers.print_ast_tree(ast_tree)
        end
    end
end

main()