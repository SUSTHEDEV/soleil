-- smoke: fake VS Code client — frame initialize + didOpen with a file
-- containing one warning (boolean key) and one error (type mismatch)
package.path = package.path .. ";./?.lua"
local json = require("lsp.json")

local function frame(msg)
    local body = json.encode(msg)
    return "Content-Length: " .. #body .. "\r\n\r\n" .. body
end

io.stdout:setvbuf("no")   -- frames must reach the server immediately
io.write(frame({ jsonrpc = "2.0", id = 1, method = "initialize", params = {} }))
io.write(frame({ jsonrpc = "2.0", method = "initialized", params = {} }))
io.write(frame({
    jsonrpc = "2.0",
    method = "textDocument/didOpen",
    params = { textDocument = { uri = "file:///smoke.sol", languageId = "soleil", version = 1,
        text = "local t : table[boolean, number] = {}\nlocal n : number = \"oops\"\nprint(t)\n" } },
}))
io.write(frame({ jsonrpc = "2.0", id = 2, method = "shutdown", params = {} }))
io.write(frame({ jsonrpc = "2.0", method = "exit", params = {} }))
