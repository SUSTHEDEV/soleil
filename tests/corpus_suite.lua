-- tests/corpus_suite.lua — 6th suite: the Lua 5.1 test-suite corpus through
-- the full generate pipeline. Run: lua5.1 tests/corpus_suite.lua
--
-- Every corpus file must tokenize (lua dialect), parse, emit, and the EMITTED
-- code must loadstring cleanly. This catches emitter-level breakage (invalid
-- Lua output) on real-world-scale code. Derived from the corpus campaign that
-- found the prefixexp, elseif-chain, %q-reindent, and long-string bugs.

package.path = package.path .. ";./?.lua"
local parser = require("parser.parser")
local Codegen = require("codegen.codegen")

local h = io.popen("ls tests/_lua5.1-tests/*.lua 2>/dev/null")
local files = {}
for f in h:lines() do files[#files + 1] = f end
h:close()
table.sort(files)

local passed, failed = 0, 0
for _, path in ipairs(files) do
    local fh = io.open(path, "r")
    local src = fh:read("*a")
    fh:close()

    local okt, tokens = pcall(parser.tokenize, src, "lua")
    if not okt then
        failed = failed + 1
        print("FAIL(tokenize): " .. path .. " — " .. tostring(tokens):gsub("\n", " "):sub(1, 90))
    else
        local okp, tree = pcall(parser.parse, tokens)
        if not okp then
            failed = failed + 1
            print("FAIL(parse): " .. path .. " — " .. tostring(tree):gsub("\n", " "):sub(1, 90))
        else
            local okg, out = pcall(Codegen.generate, tree)
            if not okg then
                failed = failed + 1
                print("FAIL(emit): " .. path .. " — " .. tostring(out):gsub("\n", " "):sub(1, 90))
            else
                local chunk, lerr = loadstring(out, "@" .. path)
                if not chunk then
                    failed = failed + 1
                    print("FAIL(load emitted): " .. path .. " — " .. tostring(lerr):gsub("\n", " "):sub(1, 90))
                else
                    passed = passed + 1
                end
            end
        end
    end
end

print(string.rep("-", 52))
print(("passed: %d  failed: %d"):format(passed, failed))
if failed > 0 then os.exit(1) end
