# Soleil — Language Specification (working draft)

A strict, statically-typed dialect of Lua, based on Lua 5.1 semantics.
The compiler is written in Lua itself (self-hosted, like `kotlinc` is written in Java).

## 0. Philosophy

- **Strict by description.** There is no implicit escape from the type system.
- **Unions, not sugar.** There is exactly one composite type mechanism: unions (`A | B`).
  Nullability (`?`) is sugar for `T | nil`.
- **Pragmatic, not dogmatic.** Type-system choices are driven by implementation cost in
  the Teal fork, not by alignment with any one language.
- Types are **checked, then erased**. The output is plain Lua 5.1 source.

## 1. Compilation pipeline

```
source ── lexer ── token stream ── parser ── AST ── type checker ── codegen ── Lua 5.1
```

Types are erased at codegen. A `--no-check` mode is possible but not a language feature.

## 2. Type system

### 2.1 Value types (map 1:1 to Lua 5.1 values)

| Type | Lua value |
|---|---|
| `boolean` | boolean |
| `number` | number |
| `string` | string |
| `function` | function |
| `table[V]` / `table[K, V]` / `table[any]` | table |
| `thread` | thread |
| `userdata` | userdata |
| class names | table (nominal) |

### 2.2 Non-value types

- **`void`** — the default return type (≈ Kotlin's `Unit`). It is *not a value*:
  - may only appear in return position
  - cannot be stored, passed, assigned, or used in an expression
  - does not participate in nullability or subtyping (nothing `<: void`, `void <:` nothing)
- **`Nothing`** — the bottom type (for never-returning functions and all-paths-return
  analysis).
  - `Nothing <: T` for all `T`

### 2.3 Nullability and unions

- **`nil` is a first-class singleton type** (its only value is `nil`):
  `local x: nil = nil` is legal.
- **`T?` is sugar for `T | nil`**, kept for ergonomics.
- Union types `A | B` are the one composite mechanism; nullability is just the special
  case `T | nil`.
- Idempotence falls out of union semantics: `(T?)?` = `T?`, `nil?` = `nil`.
- The `nil` literal has type `nil` directly.
- `nil` is assignable to `nil` and to any union containing nil (`T | nil`); it is *not*
  assignable to a plain `T`.
- `void` remains distinct from `nil`: `void` returns *nothing*, `nil` is a value (§5).

```lua
local x: number?          = nil     -- ok (nil <: number | nil)
local y: number           = nil     -- error: nil is not a number
local n: nil              = nil     -- ok
local u: string | number  = 1       -- ok
```

### 2.4 `any`

- `any` is the sole escape hatch and is **only legal inside a table**:
  `table[any]` (or as `K`/`V` of `table[K, V]`).
- Bare `any` (as a variable/param/return type) is a compile error.
- `any` is assignable *to* every type in element position; nothing is assignable *from*
  `any` to a concrete type without an explicit check (see §6).
- `any` and unions are distinct tools: `any` means "anything at all" (the escape hatch);
  a union `A | B` means "one of these *known* types".

## 3. Tables

Three canonical forms, all explicit:

| Form | Meaning | Iterate | Length |
|---|---|---|---|
| `table[V]` | array (integer keys 1..n) | `ipairs` | `#` |
| `table[K, V]` | map (key `K`, value `V`) | `pairs` | — |
| `table[any]` | heterogeneous escape hatch | `pairs` | — |

Rules:

1. **Read is always nullable.** `t[k]` has type `V?` even when `V` is non-null —
   the key may be absent, and Lua answers with `nil`. This is the primary driver of
   "force null access".
2. **Write** requires the value to be `V` (or a subtype).
3. **Empty literals are errors unless annotated**: `local x = {}` → error;
   `local x: table[string] = {}` → ok.
4. **Inline entry annotations** (`{a: string = "a"}`) are never canonical:
   - all entries same type → **warning**: "boilerplate, use `table[V]`"
   - entries of differing types → **infer a union**: `{a: string = "a", b: number = 1}`
     infers `table[string, string | number]`
   - they never produce a new *nominal* type — a union is just an aggregate.

```lua
local x: table[string]       = {"a", "b"}
local m: table[string, number] = { alice = 100 }
local h: table[any]          = { 1, "two", true }
```

## 4. Classes (OOP)

Nominal types. Subtyping is inheritance-based, not structural. Single inheritance via
`extends`; overriding an inherited method must be declared with `override`.

```lua
class Player(name: string?, id: number)   -- constructor params = fields
  function say(self: Player, something: string)
    print(self.name, something)
  end
end

class Admin(role: string) extends Player("", 0)
  override function say(self: Admin, something: string)
    print(self.role .. ": " .. something)
  end
end
```

Rules:

1. **Constructor params live in the class header and are auto-promoted to fields.**
   Required params may be declared non-null (provably initialized); optional params
   are declared nullable.
2. **`self` is explicit and covariant** — an ordinary first parameter. In a base class
   it is typed `self: Class`; in an override it narrows to the subclass (`self: Admin`
   overriding `self: Player`), granting access to subclass fields. `self` is the one
   parameter that narrows in an override — every other parameter must match or widen.
3. **Undeclared field access is an error** (`p.z` where `z` is not a field).
4. Fields declared non-null are trusted as non-null after construction.
5. Access to a class field of declared type `T` yields `T` (not `T?`) — trust the
   declaration (contrast with table reads in §3).
6. **`extends`** — single inheritance; a subclass may add fields/methods and inherit
   the parent's. Super-constructor arguments go in the header (`extends Player(...)`).
7. **`override`** — required to override an inherited method; a compile error if the
   named method does not exist on an ancestor, or its signature is incompatible.
   The return type may be narrowed (covariant return: `speak(): Animal` may be
   overridden by `speak(): Dog`). `override` is a pure check with zero runtime cost
   (see §8).
8. **`super`** — inside an override, `super.m(self, ...)` calls the parent's
   implementation. Resolved at compile time to a direct flat call to the ancestor's
   function (`Player.say(self, ...)`), costing no more than an ordinary call.
9. **Instantiation** — a class is callable: `Player("bob", 42)`. AOT-compiled to a
   direct call to the constructor (no `__call` metatable).
10. **Call sites use `:`** — `p:say("hi")` auto-injects the receiver as `self`
    (`p.say(p, "hi")`). Declarations keep `self` explicit (rule 2).

```lua
local p: Player = Player("bob", 42)
p.name                                -- string? (declared nullable)
p.id                                  -- number  (declared non-null)
p.z                                   -- error: no field z
local a: Admin = Admin("admin")
local x: Player = a                   -- ok: Admin <: Player
x:say("hi")                           -- dynamic: dispatches to Admin.say
```

## 5. Functions and return types

The default return type is **`void`**: a function that promises nothing.

| Declared | `return v` | `return nil` | bare `return` | fall off end |
|---|---|---|---|---|
| `(none)` / `void` | error | error | ok (early exit) | ok |
| `: T` | ok iff `v <: T` | error | error | error (all paths must return) |
| `: T?` | ok iff `v <: T?` | ok | error (write `return nil`) | error (write explicit `return`) |

- **Returns are explicit.** Bare `return` is void-only. Every path of a value-returning
  function (`: T` or `: T?`) must end in an explicit `return v` / `return nil`.
- **`return nil`** is legal iff the return type contains nil, i.e. is `T?` (= `T | nil`).
- **bare `return`** means "return nothing" and is legal only in `void` functions.
- **All-paths-return** analysis is required for non-void functions. This shares
  machinery with null narrowing (§6).
- **Scoping is function-scoped.** A `local` declared anywhere in a function is visible
  for the whole function (one scope per function — this deliberately diverges from
  Lua's block-scoped `local`).

## 6. Null operators

Four notations; every nullable value must be discharged through one of these (or an
explicit `if x ~= nil` narrow):

| Notation | Meaning | In → out |
|---|---|---|
| `T?` | nullable type | declaration |
| `x?.f` | safe access | receiver `C?` → field `T` becomes `T?` |
| `x ?: d` | Elvis / default | `x: T?`, `d: U` → `T | U` (reduces to `T` when `U <: T`) |
| `x!!` | not-null assertion | `x: T?` → `T` (throws if nil) |

Semantics:

- **`?.`** short-circuits **only on its receiver** being nil. The "entry was removed"
  case is orthogonal — it is already covered by table-read nullability (§3). Extends
  to indexing `t?[k]` and method calls `a?.b()`.
- **`?:`** evaluates `d` only when `x` is nil (short-circuit). Result type is `T | U`
  where `x: T?` and `d: U` (non-nil `x` → `T`, else `U`); when `U <: T` this reduces to
  `T`. `?:` may therefore create a union.
- **`!!`** compiles to an explicit assertion with a message naming the expression,
  not a raw Lua "attempt to index nil":

```lua
local name: string? = player.name
local len = name?.len          -- number?  (nil if name nil)
local len = #(name ?: "")      -- number   (default)
local len = #name!!            -- number   (explicit error if name nil)
```

Precedence: `?.` / `!!` bind tighter than `?:`, which binds tighter than `and`/`or`.

## 7. Subtyping (`is_subtype`)

1. `T <: T` (reflexive)
2. **Union subtyping** — `T <: A | B` iff `T <: A` *or* `T <: B`; `A | B <: T` iff
   `A <: T` *and* `B <: T`. This subsumes nullability: `T <: T | nil` (i.e. `T <: T?`)
   falls out as union membership, and `nil <: T?` via `nil <: nil`.
3. `Sub <: Super` (nominal, transitive through the inheritance chain)
4. **Table variance is invariant**, with a single carve-out: `any` is the top of the
   element (value) position. `table[A] <: table[B]` iff `A == B` or `B == any`; the same
   holds for the value position of `table[K, V]` (keys are always invariant). No other
   element variance — in particular `table[string]` is **not** `<: table[string?]`.
5. `Nothing <: T` (bottom)
6. `void` is outside the value hierarchy: nothing `<: void`, `void <:` nothing

## 8. Codegen

The compiler is **ahead-of-time and explicit**: it resolves as much as possible at
compile time and emits **flat, structured Lua** so the runtime penalty is minimal.

- Target **Lua 5.1 / LuaJIT** source.
- Types are erased entirely; the checker guarantees well-typedness at compile time.
- **Devirtualization (flat dispatch).** A method call compiles to a *direct* flat call
  (`Player.say(p, ...)`) whenever the target can be proven statically. Dynamic dispatch
  is used *only* for methods that are overridden anywhere — and the `override` marker
  tells the compiler exactly which methods those are:
  - never overridden → direct call, no indirection
  - overridden → one lookup in a flat dispatch table (vtable)
- `x!!` → explicit assert (named).
- `?.` / `?:` → explicit `if x == nil then ... else ...` desugaring preserving
  short-circuit semantics.
- Classes → flat tables of functions with explicit `self`; inheritance carried by a
  dispatch table, **not** a metatable `__index` chain (no metatable traversal at call time).

Consequence: methods are not monkey-patchable at runtime — dispatch is fixed at compile
time. That is intentional under the "explicit" philosophy.

## 9. Planned (deferred)

Reserved but not part of the first self-hosted core. The syntax is anticipated so the
grammar isn't painted into a corner, but none of these block the path to a working
compiler.

- **`abstract`** — abstract classes (cannot be instantiated) and abstract methods
  (declared without a body; concrete subclasses must implement them). Compile-time-only.
- **`interface` / `implements`** — multiple contracts, single inheritance (Java's model).
  Interfaces erase entirely at runtime; `implements` adds a *bounded structural
  conformance check* (does the class's method set cover the interface?) alongside the
  nominal `Sub <: Super` rule. This is the one feature that would reintroduce a second,
  structural subtyping pathway — defer deliberately.
- **`final`** — a method/class that cannot be overridden/extended. Enables maximum
  devirtualization (§8): a `final` method is *always* a direct, flat call.

## 10. Bootstrap

Once the compiler type-checks and emits Lua, run it on its own source and require the
output to pass the same test suite (self-hosting). Drive development with a test harness
comparing `parse(src) == expected_ast` and `check(src) -> expected_type`.
