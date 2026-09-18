-- config/config.lua — build configuration for soleilc
-- Reads a TOML config file (default: Soleil.toml) and merges it over
-- built-in defaults. Missing file = pure defaults, never an error.

-- Local dependencies first, so the vendored .rocks copy wins over any
-- system-installed duplicate.
package.path = "./.rocks/share/lua/5.1/?.lua;" .. package.path

local toml = require("tinytoml")

-- Defaults mirror the SPEC's philosophy: types are checked then erased,
-- the checker is strict about nullability unless loosened.
local function default_config()
    return {
        build = {
            target = "5.1",
            optimize = false,
        },
        checker = {
            strict_null = true,     -- reject T? -> T without a check (SPEC §2)
            warn_unused = false,
        },
        codegen = {
            erase_types = true,     -- checked, then erased (SPEC §8)
        },
    }
end

-- deep-merge `user` over `base` (user wins); returns base
local function merge(base, user)
    for k, v in pairs(user) do
        if type(v) == "table" and type(base[k]) == "table" then
            merge(base[k], v)
        else
            base[k] = v
        end
    end
    return base
end

local Config = {}

-- Config.load([path]) -> config table
-- Missing file is fine: you get pure defaults.
function Config.load(path)
    path = path or "Soleil.toml"
    local user = {}
    local fh = io.open(path, "r")
    if fh then
        fh:close()
        user = toml.parse(path)
    end
    return merge(default_config(), user)
end

return Config
