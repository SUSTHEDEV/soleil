# Soleil — Language Specification

A strict, statically-typed dialect of Lua, based on Lua 5.1 semantics.
The compiler is written in Lua itself (self-hosted, like `kotlinc` is written in Java).

Status: **v1 core complete.** Everything in §§1–10 is implemented and locked behind
the test suites (`tests/` — parser, checker, integration, corpus, and a 59,198-combo
recursive battery). §§11–12 are deliberately deferred.

## 0. Philosophy

- **Strict by description.** There is no implicit escape from the type system.
  Nothing is silently `any`; a function that declares no return types returns `nil`
  and may not return values; `unknown` must be proven before use.
- **Unions, not sugar.** There is exactly one composite type mechanism: unions
  (`A | B`). Nullability (`?`) is sugar for `T | nil`.
- **Checked, then erased.** Types are validated at compile time and stripped at
  codegen. The output is plain Lua 5.1 source with zero runtime type machinery.
- **Loud, not silent.** The checker aborts on the first violation. There is no
  error recovery and no unchecked mode.

## 1. Compilation pipeline

```
source ── lexer ── tokens ── parser ── AST ── type checker ── codegen ── Lua 5.1
```

- Two dialects: **soleil** (`.sol`, full grammar) and **lua** (`.lua`, plain Lua —
  parsed and emitted, never type-checked). The CLI picks the dialect by extension.
- Errors are tiered and loud: lex/parse errors carry line numbers
  (`Parse Error at line N: …`); checker errors carry the offending node's line
  (`type error at line N: …`). All tiers exit non-zero.
- Nesting is bounded: 100 nested functions at parse; 1500 statement levels in the
  checker and emitter (loud errors, never a C-stack crash).

## 2. Type system

### 2.1 Value types

| Type | Lua value |
|---|---|
| `boolean` | boolean |
| `number` | number |
| `string` | string |
| `nil` | nil (singleton) |
| `table[V]` / `table[K, V]` / `table[any]` | table |
| class / interface / data names | table (nominal) |

**Numerals.** All Lua 5.1 spellings: decimal, exponent (`1e10`, `3.25e-3`),
hex (`0xFF`), and trailing-dot (`.5`, `2.`). No 5.4 additions — hex floats
(`0x1p4`) are not grammar and `inf`/`nan` are **not literals** (they are
ordinary identifiers in Lua 5.1). Overflowing literals keep their raw text
end-to-end: `10e500` compiles to `10e500`, never to a printed `inf` — emitting
`tostring(inf)` would silently reference an undefined global. Programmatic
non-finite values are emitted as guarded expressions (`(1/0)`, `(-1/0)`,
`(0/0)`).

### 2.2 `nil` and nullability

- **`nil` is a first-class singleton type.** `local x : nil = nil` is legal.
- **`T?` is sugar for `T | nil`.** This is the canonical spelling: `x : T | nil`
  is *not* grammar — write `T?` (or `(A | B)?` is likewise not grammar; a nullable
  union of two members is written with the `?` on the last member: `A | B?`).
- `nil` is assignable to `nil` and to any union containing nil. It is never
  assignable to a plain `T`.
- Idempotence: `(T?)?` = `T?`.

### 2.3 `any` — table-only, the one trusted channel

- **`any` is legal only inside table brackets**: `table[any]`,
  `table[K, any]`, `table[any, V]`, and union members *within* those brackets
  (`table[number | any]`). Everywhere else — parameters, returns, locals,
  class fields, interface mandates, interface member types, unions outside
  tables — bare `any` is a compile error.
- The rule exists because `unknown` removed any need for signature-level
  `any`: everything flows *into* `unknown`, and `tonumber`/`tostring` are the
  checkpoints out. Dynamic *signatures* are typed `unknown`; dynamic
  *collections* are typed with `any` in their brackets.
- Inside its legal home, `any` is assignable in both directions — it is the
  one trusted channel, and it is opt-in only: nothing produces `any`
  implicitly.
- `any` cannot be used as a class name (nominal namespace protection).
- Standard-library signatures follow the same split: dynamic parameters are
  `unknown` (`print(v : unknown)`, `tonumber(v : unknown)`), while
  untyped *containers* stay `table[any]` / `table[any, any]`.

### 2.4 `unknown` — untyped variadic data

`unknown` is the type of values whose shape the compiler cannot know. The only
producer is varargs data: `select(n, ...)` spreads unknowns (and a bare `...`
flows as unknown into `any` positions).

Boundary rules (strict, deliberately diverging from Kotlin platform types):

| Direction | Rule |
|---|---|
| `unknown → unknown` | ok |
| `unknown → any` | ok |
| `unknown → T` (any concrete `T`, including `T?`) | **error** |
| arithmetic / concat on `unknown` | error |
| `tonumber(u)` | `number?` — checkpoint out |
| `tostring(u)` | `string` — checkpoint out |

The rule of thumb: **unknown goes nowhere without a checkpoint or `any`.**

## 3. Tables

| Form | Meaning | Iterate | Length |
|---|---|---|---|
| `table[V]` | array — number-keyed | `ipairs` | `#` |
| `table[K, V]` | map | `pairs` | — |
| `table[any]` | heterogeneous escape hatch | `pairs` | — |

Rules:

1. **Read is always nullable.** `t[k]` has type `V?` even when `V` is non-null.
   Discharge with a nil-guard, `?:`, or `!!` (§7).
2. **Literals are element-checked.** A positional literal infers the *union* of its
   elements: `{Circle(1), Square(1)}` types as `table[number, Circle | Square]`,
   so it assigns cleanly to `table[Circle | Square]` and rejects
   `{1, "x"}` against `table[number]`.
3. `{a = 1}` is a named pair. `{a, b, c}` is **positional** — Lua semantics; there
   is no `{name}` shorthand.
4. Flow narrowing applies to element reads: `xs[1]` is `V?`, so `xs[1] + 1` needs
   a guard (`if s ~= nil`, `xs[1] ?: 0`, or `xs[1]!!`).
5. Constructors and other literals are not callable/indexable (Lua's `prefixexp`
   rule): `({1,2})[1]` is required; `{1,2}[1]` is a syntax error.

## 4. Functions

```lua
local function add(a : number, b : number) : number
    return a + b
end

local function div(a : number, b : number) : number, string?   -- multi-returns
    if b == 0 then return nil, "div by zero" end
    return a / b, nil
end

local function va(head : number, ...) : number                 -- varargs last
    return head + select("#", ...)
end
```

- **Implicit nil.** A function that declares no return types returns `nil` and
  *may not return values*: `return 42` in a rets-less function is an error
  ("add return types or return nothing"). This is the runtime-honest encoding —
  Lua's no-return, bare `return`, and `return nil` are indistinguishable at runtime.
- **Multi-returns are declared comma-separated** and checked per position.
  Call results spread: `local q, m = div(1, 2)`.
- **Parenthesization truncates.** `(f())` yields exactly one value:
  `local a, b = (f())` binds `b` as nil. The parens are semantic (an `AST.Paren`
  node), never discarded.
- **`local function` may recurse** — the name is pre-declared (`local f; f = …`).
- **Scoping is lexical and block-scoped**, as in Lua.
- Factories returning body-local classes cannot name the return type (lexical
  scoping); declare the class outside the function, or return through an
  interface / `: any`.

## 5. Strict operators

- **Concat `..` requires strings.** Numbers do not implicitly coerce:
  `tostring(42) .. "!"` is the spelled-out form. `tonumber`/`tostring` are the
  conversion checkpoints for the whole language.
- Arithmetic requires numbers on both sides. Comparison operators require
  like-typed operands.
- Call sugar: `f{...}` ≡ `f({...})`, `f"str"` ≡ `f("str")` — receivers must be
  callable (see §3.5).

## 6. Classes (OOP)

Nominal types; single inheritance via `extends`; multiple contracts via
`implements` (§8).

```lua
class Player(name : string?, id : number)
    function say(self : Player, something : string)
        print(self.name, something)
    end
end

class Admin(role : string) extends Player("", 0)
    override function say(self : Admin, something : string)
        print(self.role .. ": " .. something)
    end
end

local p = Player("bob", 42)     -- inferred exactly: p : Player
p:say("hi")                     -- ':' injects self; declarations keep it explicit
```

Rules:

1. **Constructor params live in the header and are auto-promoted to fields.**
   Declare them nullable unless proven initialized. Fields of declared type `T`
   read as `T` (trusted — contrast with table reads, §3.1).
2. **`self` is explicit and covariant** — the one parameter that may *narrow* in
   an override (`self: Admin` overriding `self: Player`). Every other parameter
   must match or widen; returns may narrow; counts must match. `override` is
   required to shadow an ancestor method and is a compile error when the method
   does not exist or the signature is incompatible.
3. **`super.m(self, ...)`** — args map the declared params 1:1 (self is explicit).
   Resolved statically to the nearest ancestor providing `m`; compiles to a flat
   call.
4. **Undeclared field access is an error.** Field reads narrow under guards
   (§7): `type(self.v) == "number"` and `self.v ~= nil` both refine `self.v`.
5. **`extends` takes exactly one class**, with super-constructor arguments in the
   header (`extends Player("", 0)`). Chained constructors run base-first.
   Extending an interface is an error — interfaces are `implemented`.
6. **Kinds**: `class` (standard), **`data`** (params required, plain aggregate),
   **`object`** (singleton — the name *is* the one instance; top-level only,
   never abstract, no params), **`abstract`** (prefix on classes: not
   instantiable; abstract members are body-less and concrete subclasses must
   implement them), **`final`** (prefix on classes: cannot be extended — sealed).
   `final abstract` is rejected as contradictory.
7. **`final` and dispatch**: a method call on a final-typed receiver always
   compiles to a direct flat call — no subclass can exist, so the method is
   monomorphic by construction, even when unrelated classes share the name.
7. **Classes nest and localize freely.** A class may be declared inside a
   function, a method, or another class; the compiler assigns each a unique
   flat runtime name, so same-named local classes coexist.

## 7. Null safety

Every nullable value must be discharged through one of:

| Form | Meaning | In → out |
|---|---|---|
| `T?` | nullable type | declaration |
| `x?.f` / `x?.m(args)` | safe access | receiver `C?` → result wrapped `?` |
| `x ?: d` | elvis / default | `x : T?`, `d : U` → union; **substitutes on nil only** (`false` passes through) |
| `x!!` | not-null assertion | `x : T?` → `T`; runtime `error("nil assertion failed")` if nil |
| `if x ~= nil` | flow narrowing | see below |

Precedence: `?.` / `!!` bind tightest (postfix); `?:` sits between `and` and the
comparison level, and is right-associative.

**Flow narrowing** (locals and dotted fields, both branch directions):

- `if x ~= nil` narrows `x` in the *then* block; `if x == nil` narrows in the
  *else* block. The complement branch types `x` as `nil` (any use fails loudly).
- `if type(x) == "number"` refines a union `x` to its `number` member in the
  then-branch, and to the complement in the else-branch. Works on locals and
  dotted fields (`type(self.v) == …`).
- **An assignment to the narrowed name inside a branch cancels that branch's
  shadow** — the stale refinement cannot lie about a reassigned value.

## 8. Interfaces

Java's model: **multiple contracts, single inheritance.** Interfaces erase
entirely at runtime — except default methods (§8.3).

```lua
interface Named(name : string)
    function label(self : Named) : string
end

interface Greeter
    default function greet(self : Greeter) : string
        return "hello"
    end
end

class Dog(name : string, tag : string?) extends Animal(name) implements Named, Greeter
    function label(self : Dog) : string return self.name end
    -- greet is inherited from Greeter's default
end
```

### 8.1 `implements`

- `implements A, B` — one or more interfaces, comma-separated. Only `class` and
  `data` may implement; interfaces and objects may not.
- Satisfaction is checked at the declaration: every interface field and method
  must be provided (methods matched on parameter count and return compatibility),
  **except default methods**, which satisfy themselves (§8.3).

### 8.2 Constructor mandates (name-based)

An interface's constructor parameters are **type mandates**, not runtime values:

```lua
interface A(x : string) end
interface B(x : number) end

class C(x : string | number) implements A, B end          -- ok
class C(x : string | number?) implements A, B end         -- ok (nullable union)
class C(x : string) implements A, B end                   -- error: x must accept number
```

- Mandates match **by parameter name**: the class must have a parameter of that
  name whose type *accepts* the mandated type (each mandate flows in).
- Positions are irrelevant; extra class parameters are fine; a missing named
  parameter is an error naming the mandating interface.

### 8.3 Default methods

- `default function m(...) ... end` inside an interface carries a **reference
  implementation**. The body is required (a body-less default is an error), and
  ordinary interface members may *not* have bodies.
- A default satisfies its own contract: implementing classes need not override it.
  A class may still provide its own — the override wins.
- Runtime: defaults compile to flat `__Interface_m` functions; an implementing
  class's constructor installs the default on `self` only when no ancestor
  defines the method.

### 8.4 Interface-typed values

`local g : Greeter = Dog(...)` type-checks via **bounded structural conformance**:
the class must cover every interface member (with the default-method rule). This
is the one structural pathway; classes themselves remain nominal. Method calls
through interface-typed receivers dispatch dynamically to the instance's methods.

## 9. `unknown`, revisited — what produces what

| Expression | Type |
|---|---|
| annotated function, declared rets | exactly those types |
| rets-less function call | `nil` |
| `select("#", ...)` | `number` |
| `select(n, ...)` | `n−1` unknowns |
| `tonumber(x)` | `number?` |
| `tostring(x)` | `string` |
| `type(x)` | `string` |
| `pair`/`ipair` iteration variables | the container's declared `V` / index `number` |

Nothing else produces `unknown` or `any` implicitly. `any` is written by the
programmer or it does not exist.

## 10. Codegen

- Target: **Lua 5.1** source. Types are erased entirely.
- **Classes compile to flat structures**: `__ClassName_method(self, ...)` functions;
  the constructor `__ClassName_new(params)` builds a table, runs the base
  constructor first (if `extends`), sets fields, then installs methods — **base
  methods copied first, derived last, so overrides win**; interface defaults
  install only where no ancestor defines the method. No metatable `__index`
  traversal at call time.
- **Devirtualization**: a method call compiles to a direct flat call when the
  checker can prove the method is monomorphic across the program (census-gated).
  Polymorphic call sites — overridden methods and interface-typed receivers —
  dispatch dynamically through the instance-carried method. Consequence: methods
  are not monkey-patchable at runtime. Intentional.
- **Null operators**: `!!` → named runtime assertion; `?.` / `?:` → nil-checked
  IIFEs (`and`/`or` desugaring is *unsound* on `false` and never used).
- Literals and constructors are parenthesized whenever they occupy a
  call/index receiver position (`prefixexp` rule).
- Function-local and nested classes receive unique flat names; sibling
  same-named local classes coexist.

## 11. Tooling

```
lua main.lua <input.sol | input.lua> [options]
    -o, --output <file>   write generated Lua (default: stdout)
    --run                 compile and execute in-process
    -v, --verbose         dump tokens and AST
    -h, --help
```

- Dialect by extension: `.sol` → soleil (checked), `.lua` → lua (parse+emit only).
- Imports resolve relative to the compiler script, not the caller's cwd.
- Files may carry `#!INCOMPLETE` markers (shebang or `--#!INCOMPLETE` inline):
  the checker **refuses** to fully check a marked file unless lenient mode is
  requested via the API (`options.allow_incomplete`).

Test suites (`tests/`): parser (128), checker (192), whole-program integration
(19), corpus parse→emit→load over the Lua 5.1 test suite (24), AST **round-trip
emission integrity** (39 files/constructs: emit → re-parse → normalized
equivalence — Lua-mode output must be AST-isomorphic; soleil constructs are
verified lowerings), and a recursive-combination battery (59,198 combos:
nesting × field typing × payload shapes, plus expect-error adversarial
contracts).

## 12. Planned (deferred)

- **`final` methods** — member-level sealing (class-level `final` ships today);
  enables maximal devirtualization.
- **Hex-float literals** — deliberately absent (Lua 5.1 has none); revisit only
  with a 5.4 target.
- **Soleil.toml** — build configuration (`strict_null`, `allow_incomplete`,
  `optimize`); the loader exists, the CLI wiring does not.
- **Generics** — `table[T]` is today's only parameterized shape.
- **Ecosystem**: `lua2sol` (untyped Lua → annotated Soleil migration tool),
  `headersgen` (C headers → `.hds` stdlib files), a tree-walking interpreter for
  `-i`, REPL/LSP, LuaJIT-targeted emission.
- **Self-hosting** (SPEC §10 of the original draft): compile Soleil with Soleil.
