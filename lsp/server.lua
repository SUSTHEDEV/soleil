-- lsp/server.lua — the soleilc language server (LSP over stdio).
-- Run: lua5.1 lsp/server.lua
-- Protocol: JSON-RPC 2.0, Content-Length framing (what VS Code speaks).
--
-- Supported:
--   initialize                        → capabilities (full-text sync)
--   textDocument/didOpen|didChange    → re-analyze, publishDiagnostics (pushed)
--   shutdown / exit                   → clean exit
--
-- Diagnostics come from the full pipeline: lex/parse warnings + first parse
-- error, checker warnings + first type error. Severity: 1 error, 2 warning.

package.path = package.path .. ";./?.lua;../?.lua"
local parser = require("parser.parser")
local Checker = require("checker.checker")
local json = require("lsp.json")

parser.parse_set_quiet(true)                        -- stdout carries only framed LSP data

local mark = io.open("/tmp/soleil_server_spawned.txt", "w")
if mark then
    mark:write("server spawned at " .. os.date("%H:%M:%S") .. "\n")
    mark:close()
end

local documents = {}                                -- uri → text

-- ------------------------------------------------------------- analyze --
local function analyze(source, filename)
    local diags = {}

    local function push(severity, message, line)
        diags[#diags + 1] = {
            range = {
                start = { line = (line or 1) - 1, character = 0 },
                -- finish at end-of-line: whole-line underline, column-agnostic
                ["end"] = { line = (line or 1) - 1, character = 1e9 },
            },
            severity = (severity == "error") and 1 or 2,
            source = "soleilc",
            message = message,
        }
    end

    -- lex + parse tier (collects warnings; first error aborts the parse)
    parser.parse_diagnostics_reset()
    local ok, tokens = pcall(parser.tokenize, source, "soleil")
    if not ok then
        for _, d in ipairs(parser.parse_diagnostics_take()) do
            push(d.severity, d.message, d.line)
        end
        return diags
    end
    local okp, ast_or_err = pcall(parser.parse, tokens)
    for _, d in ipairs(parser.parse_diagnostics_take()) do
        push(d.severity, d.message, d.line)
    end
    if not okp then
        local line = tostring(ast_or_err):match("at line (%d+)")
        push("error", tostring(ast_or_err):gsub("^.-: ", ""), line and tonumber(line) or 1)
        return diags
    end

    -- checker tier (collects warnings + first type error)
    local list = Checker.check_diagnostics(ast_or_err, {})
    for _, d in ipairs(list) do
        push(d.severity, d.message, d.line)
    end
    return diags
end

-- --------------------------------------------------------------- wire --
local WIRE_LOG = os.getenv("SOLEIL_LSP_WIRE") or "/tmp/soleil_lsp_wire.log"
local function send(msg)
    local body = json.encode(msg)
    io.write("Content-Length: ", #body, "\r\n\r\n", body)
    io.flush()
    local log = io.open(WIRE_LOG, "a")               -- set SOLEIL_LSP_WIRE to disable
    if log then
        log:write(os.date("%H:%M:%S "), body:sub(1, 400), "\n")
        log:close()
    end
end

local function reply(id, result)
    send({ jsonrpc = "2.0", id = id, result = result })
end

local function notify(method, params)
    send({ jsonrpc = "2.0", method = method, params = params })
end

local function publish(uri, text)
    local filename = uri:match("^file://(.*)$") or uri
    local diags = analyze(text, filename)
    notify("textDocument/publishDiagnostics", { uri = uri, diagnostics = diags })
end

-- read one Content-Length framed message from stdin
local function read_message()
    local headers = {}
    while true do
        local line = io.read("*l")
        if not line then return nil end
        line = line:gsub("\r$", "")                    -- CRLF framing (VS Code sends \r\n)
        if line == "" then break end                   -- blank line: body next
        local k, v = line:match("^(%S+):%s*(.+)$")
        if k then headers[k:lower()] = v end
    end
    local length = tonumber(headers["content-length"])
    if not length then return nil end
    return io.read(length)
end

-- --------------------------------------------------------------- loop --
local function handle(msg)
    local method = msg.method

    if method == "initialize" then
        reply(msg.id, { capabilities = { textDocumentSync = 1 } })  -- 1: full sync
    elseif method == "initialized" then
        -- no-op
    elseif method == "shutdown" then
        reply(msg.id, nil)
    elseif method == "exit" then
        os.exit(0)
    elseif method == "textDocument/didOpen" then
        local td = msg.params.textDocument
        documents[td.uri] = td.text
        publish(td.uri, td.text)
    elseif method == "textDocument/didChange" then
        local td = msg.params.textDocument
        local last = msg.params.contentChanges[#msg.params.contentChanges]
        documents[td.uri] = last and last.text or documents[td.uri]
        publish(td.uri, documents[td.uri])
    elseif method == "textDocument/didClose" then
        documents[msg.params.textDocument.uri] = nil
    elseif method == "workspace/didChangeConfiguration" then
        -- no-op
    elseif msg.id then
        reply(msg.id, nil)                             -- unknown request: don't hang the client
    end
end

while true do
    local body = read_message()
    if not body then break end
    local log = io.open(WIRE_LOG, "a")
    if log then
        log:write(os.date("%H:%M:%S ") .. "RECV " .. body:sub(1, 300) .. "\n")
        log:close()
    end
    local ok, msg = pcall(json.decode, body)
    if not ok then
        local el = io.open(WIRE_LOG, "a")
        if el then el:write("DECODE ERROR: " .. tostring(msg) .. "\n") el:close() end
    elseif msg then
        local okh, herr = pcall(handle, msg)
        if not okh then
            local el = io.open(WIRE_LOG, "a")
            if el then
                el:write("HANDLE CRASH: " .. tostring(herr) .. "\n" .. debug.traceback() .. "\n")
                el:close()
            end
        end
    end
end
