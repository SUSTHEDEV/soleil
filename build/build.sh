#!/usr/bin/env bash
# build/build.sh — assemble and compile the soleilc distribution
#   ./build/build.sh            → build/soleilc.luac      (Lua 5.1 bytecode)
#   ./build/build.sh -j         → build/soleilc.jit       (LuaJIT bytecode)
#   ./build/build.sh -j         → build/soleilc.jit      (LuaJIT 32-bit)
#   ./build/build.sh -J         → build/soleilc.jit      (LuaJIT 64-bit)
set -euo pipefail

# location-independent: everything anchors to the repo root,
# wherever the script is invoked from (our recurring cwd nemesis)
cd "$(dirname "$0")/.."

export PATH="$HOME/.luarocks/bin:$PATH"   # dodges the stale /usr/local wrapper

MONO=build/soleilc_mono.lua

echo "== combining modules =="
luacc -o "$MONO" \
    main parser.parser ast.ast checker.checker checker.stdlib \
    codegen.codegen helpers.compile_helpers
echo "   $(wc -c < "$MONO") bytes"

build_51() {
    echo "== luac (5.1 bytecode) =="
    luac -o build/soleilc.luac "$MONO"
    echo "   build/soleilc.luac ($(wc -c < build/soleilc.luac) bytes)"
}

build_jit() {
    local arch="$1"
    echo "== luajit (jit bytecode) =="
    if [[ "$arch" -eq 64 ]]; then
        luajit -bX "$MONO" build/soleilc.lj64
        echo "   build/soleilc.lj64 ($(wc -c < build/soleilc.lj64) bytes)"
    elif [[ "$arch" -eq 32 ]]; then
        luajit -bW "$MONO" build/soleilc.lj32
        echo "   build/soleilc.lj32 ($(wc -c < build/soleilc.lj32) bytes)"
    else
        echo "unknown arch: $arch" >&2
        exit 2
    fi
}

if [[ $# -eq 0 ]]; then
    build_51
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case $1 in
    -j | --luajit_32)
            build_jit 32
            ;;
    -l | --lua51)
            build_51
            ;;
    -h | --help)
            echo "usage: build/build.sh [-l] [-j] [-J]"
            echo "  (no flags)  build/soleilc.luac   — Lua 5.1 bytecode"
            echo "  -l          build/soleilc.luac   — Lua 5.1, explicit"
            echo "  -j          build/soleilc.jit    — LuaJIT 32-bit (-bW)"
            echo "  -J          build/soleilc.jit    — LuaJIT 64-bit (-bX)"
            exit 0
            ;;
    -J | --luajit_64)
            build_jit 64
            ;;
    *)
            echo "unknown option: $1 (see --help)" >&2
            exit 2
            ;;
    esac
    shift
done
