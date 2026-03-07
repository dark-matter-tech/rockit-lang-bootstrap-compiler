# Compiler Phases

The Rockit compiler processes source code through 8 phases. Each phase transforms one representation into the next, with well-defined interfaces between them.

## Phase 1: Lexer

**File:** `Lexer.swift` | **Input:** Source text | **Output:** Token stream

The lexer converts raw source text into a stream of tokens. Each token carries its type, lexeme (source text), and source location (line, column, offset).

### Key Features
- **130+ token types** — keywords, operators, literals, punctuation
- **String interpolation** — `"Hello, ${name}"` and `"Hello, $name"` produce structured token sequences
- **Nestable block comments** — `/* outer /* inner */ still comment */`
- **Significant newlines** — newlines are tokens (used for statement separation)
- **Number literals** — integers, floats, hex (`0xFF`), binary (`0b1010`), underscore separators (`1_000_000`)

### Token Categories

| Category | Examples |
|----------|---------|
| Keywords | `fun`, `val`, `var`, `class`, `if`, `when`, `for`, `return`, `suspend`, `actor`, `view` |
| Literals | `42`, `3.14`, `"hello"`, `true`, `false`, `null` |
| Operators | `+`, `-`, `*`, `/`, `==`, `!=`, `<`, `>`, `&&`, `\|\|`, `?.`, `?:`, `!!` |
| Punctuation | `(`, `)`, `{`, `}`, `[`, `]`, `,`, `.`, `:`, `->` |
| Special | `NEWLINE`, `EOF`, `STRING_INTERP_START`, `STRING_INTERP_END` |

### Example

```rockit
val x: Int = 42
```

Produces tokens:
```
VAL  "val"     (1:1)
IDENTIFIER "x" (1:5)
COLON ":"      (1:6)
IDENTIFIER "Int" (1:8)
EQUALS "="     (1:12)
INT_LITERAL "42" (1:14)
NEWLINE        (1:16)
```

---

## Phase 2: Parser

**File:** `Parser.swift` | **Input:** Token stream | **Output:** AST

The parser is a recursive descent parser that constructs an Abstract Syntax Tree from the token stream. It handles all Rockit declarations, statements, and expressions.

### Declarations Parsed

| Declaration | Syntax | AST Node |
|-------------|--------|----------|
| Function | `fun name(params): Type { ... }` | `FunDecl` |
| Class | `class Name(params) : Super { ... }` | `ClassDecl` |
| Data Class | `data class Name(val x: Int)` | `ClassDecl` (isData=true) |
| Sealed Class | `sealed class Name { ... }` | `ClassDecl` (isSealed=true) |
| Enum | `enum class Color { Red, Green, Blue }` | `EnumDecl` |
| Interface | `interface Drawable { fun draw() }` | `InterfaceDecl` |
| Object | `object Singleton { ... }` | `ObjectDecl` |
| Actor | `actor Counter { ... }` | `ActorDecl` |
| View | `view Button(label: String) { ... }` | `ViewDecl` |
| Navigation | `navigation AppNav { ... }` | `NavDecl` |
| Theme | `theme AppTheme { ... }` | `ThemeDecl` |
| Type Alias | `typealias StringList = List<String>` | `TypeAliasDecl` |
| Package | `package com.example.app` | `PackageDecl` |

### Expression Precedence (low to high)

1. Assignment (`=`, `+=`, `-=`, etc.)
2. Ternary / Elvis (`?:`)
3. Or (`||`)
4. And (`&&`)
5. Equality (`==`, `!=`)
6. Comparison (`<`, `>`, `<=`, `>=`)
7. Range (`..`, `..<`)
8. Addition (`+`, `-`)
9. Multiplication (`*`, `/`, `%`)
10. Unary (`-`, `!`, `++`, `--`)
11. Postfix (`.`, `?.`, `()`, `[]`, `!!`, `as`, `as?`, `is`)

### Error Recovery

The parser uses synchronization tokens (`;`, `}`, keywords) to recover from syntax errors and continue parsing. This allows multiple errors to be reported in a single compilation.

---

## Phase 3: Type Checker

**File:** `TypeChecker.swift` | **Input:** AST | **Output:** Typed AST

The type checker runs in two passes over the AST:

### Pass 1: Gather

- Collects all type declarations (classes, interfaces, enums)
- Registers function signatures (name, parameters, return type)
- Builds class hierarchies (inheritance, interface implementation)
- Resolves type aliases

### Pass 2: Check

- **Type inference** — `val x = 42` infers `x: Int`
- **Null safety** — `String` vs `String?`, safe calls (`?.`), elvis (`?:`), non-null assertion (`!!`)
- **Exhaustive matching** — `when` on sealed classes/enums must cover all cases (or have `else`)
- **Generics** — type parameter substitution, variance (`out`, `in`)
- **Suspend/await validation** — `await` only in suspend functions, suspend calls require `await`
- **Actor isolation** — mutable state in actors only accessed via message passing
- **Overload resolution** — selects most specific matching overload

### Type System Features

| Feature | Example |
|---------|---------|
| Null safety | `val s: String? = null; s?.length` |
| Smart casts | `if (x is String) { x.length }` — `x` is `String` in the branch |
| Generics | `class Box<T>(val value: T)` |
| Variance | `interface Producer<out T>`, `interface Consumer<in T>` |
| Type bounds | `fun <T : Comparable<T>> sort(list: List<T>)` |
| Union types | `when (x) { is Int -> ..., is String -> ... }` |

---

## Phase 4: MIR Lowering

**File:** `MIRLowering.swift` | **Input:** Typed AST | **Output:** MIR

MIR (Mid-level Intermediate Representation) is a lower-level representation closer to machine semantics:

- Complex expressions decomposed into simple operations
- Control flow normalized (if/when → conditional branches)
- Method calls resolved to concrete dispatch targets
- Closures lowered to explicit capture structs
- String interpolation lowered to concatenation chains

---

## Phase 5: MIR Optimizer

**File:** `MIROptimizer.swift` | **Input:** MIR | **Output:** Optimized MIR

### Optimization Passes

| Pass | Description |
|------|-------------|
| Constant folding | `2 + 3` → `5` at compile time |
| Dead code elimination | Remove unreachable code after `return`, `throw` |
| Function inlining | Inline small functions at call sites |
| Tree shaking | Remove unused functions and types from output |
| Copy propagation | Eliminate redundant variable copies |

### Optimization Level

The compiler uses `-O1` for native codegen. `-O2` causes regressions due to LLVM's alloca promotion patterns interacting poorly with the generated IR.

---

## Phase 6: Bytecode Codegen

**File:** `CodeGen.swift` | **Input:** Optimized MIR | **Output:** Bytecode (`.rokb`)

Generates bytecode for the Rockit VM. The bytecode format uses a register-based encoding.

### Key Opcodes

| Opcode | Code | Description |
|--------|------|-------------|
| OP_CONST | 0 | Load constant |
| OP_ADD | 1 | Integer addition |
| OP_CALL | 10 | Function call |
| OP_RET | 11 | Return from function |
| OP_LOAD_GLOBAL | 83 | Load global variable |
| OP_STORE_GLOBAL | 84 | Store global variable |
| OP_ALLOC | 40 | Allocate object |
| OP_GET_FIELD | 41 | Get object field |
| OP_SET_FIELD | 42 | Set object field |
| OP_SUSPEND | 70 | Coroutine suspend |
| OP_RESUME | 71 | Coroutine resume |
| OP_ACTOR_SEND | 80 | Actor message send |

---

## Phase 6b: LLVM Native Codegen

**File:** `LLVMCodeGen.swift` | **Input:** AST | **Output:** LLVM IR → native binary

Generates textual LLVM IR (`.ll` files), then invokes `clang` to produce a native binary.

### Key Transforms

- **CPS coroutine transform** — suspend functions converted to state machines
- **ARC insertion** — retain/release calls at object creation, assignment, scope exit
- **Polymorphic dispatch** — vtable-based method dispatch for class hierarchies
- **String literal optimization** — immortal string constants (refCount = INT64_MAX, zero malloc)
- **Inline field access** — GEP into fields array instead of runtime function calls

### Runtime Linkage

Native binaries link against `rockit_runtime.o`, which provides:
- `rockit_object_alloc` / `rockit_retain` / `rockit_release` — ARC primitives
- `rockit_println` / `rockit_print` — I/O
- `rockit_string_concat` — String operations
- `rockit_task_*` — Coroutine task scheduling
- `rockit_actor_*` — Actor mailbox dispatch

---

## Phase 7: VM (Bytecode Interpreter)

**File:** `VM.swift` | **Input:** Bytecode (`.rokb`) | **Output:** Program execution

The VM is a register-based bytecode interpreter with:

- **Object heap** (`Heap.swift`) — ARC-managed object storage
- **Coroutine scheduler** (`Scheduler.swift`) — cooperative multitasking
- **Actor runtime** (`ActorRuntime.swift`) — mailbox-based message dispatch
- **Cycle detector** (`CycleDetector.swift`) — identifies potential retain cycles
- **Builtin functions** (`BuiltinFunctions.swift`) — crypto, hashing, X.509, I/O

---

## Phase 8: Structured Concurrency

Implemented across multiple phases:

### Native Codegen (LLVMCodeGen.swift)
- CPS (Continuation-Passing Style) transform for suspend functions
- State machine generation for coroutines
- Concurrent blocks with event loop + join counter

### Bytecode VM
- Cooperative scheduler with time-sliced execution
- Coroutine suspend/resume via explicit state saving
- Concurrent block interleaving
- Actor message dispatch via mailbox queues
- Error propagation across coroutine boundaries
- Cancellation support
