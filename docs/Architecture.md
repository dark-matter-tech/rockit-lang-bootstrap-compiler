# Architecture

The Rockit Bootstrap Compiler (Stage 0) is a full compiler pipeline written in Swift. It exists to compile the self-hosted Rockit compiler from source, completing the bootstrap cycle.

## Design Philosophy

1. **Correctness over performance** — Stage 0 is a reference implementation. Every edge case must be handled correctly, even if a faster approach exists.
2. **Testability at every boundary** — Each phase produces an intermediate representation that can be inspected and tested independently.
3. **Library-first** — The compiler is packaged as `RockitKit` (a Swift library), with the CLI as a thin wrapper. This lets other tools (LSP, Fuel, editor plugins) reuse compiler internals.

## High-Level Pipeline

```
.rok source
    │
    ▼
┌─────────┐
│  Lexer   │  Source text → Token stream
└────┬─────┘
     │
     ▼
┌─────────┐
│  Parser  │  Token stream → Abstract Syntax Tree (AST)
└────┬─────┘
     │
     ▼
┌──────────────┐
│ Type Checker  │  AST → Typed AST (with resolved types, null safety, generics)
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ MIR Lowering  │  Typed AST → Mid-level Intermediate Representation
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ MIR Optimizer │  MIR → Optimized MIR (constant folding, DCE, inlining, tree shaking)
└──────┬───────┘
       │
       ├──────────────────┐
       ▼                  ▼
┌────────────┐    ┌──────────────┐
│  CodeGen   │    │ LLVMCodeGen  │
│ (Bytecode) │    │ (Native)     │
└─────┬──────┘    └──────┬───────┘
      │                  │
      ▼                  ▼
   .rokb file       LLVM IR → clang → native binary
      │
      ▼
┌─────────┐
│   VM    │  Bytecode interpreter (ARC, coroutines, actors)
└─────────┘
```

## Two Codegen Paths

### Bytecode Path (`compile` / `run`)

- **CodeGen.swift** lowers MIR to a custom bytecode format (`.rokb`)
- **VM.swift** interprets bytecode with a register-based VM
- Supports ARC (via Heap.swift), coroutines (Scheduler.swift, Coroutine.swift), and actor dispatch (ActorRuntime.swift)
- Used for: development, testing, `rockit run`, bootstrap verification (Stage 2 == Stage 3 bytecode comparison)

### Native Path (`build-native`)

- **LLVMCodeGen.swift** lowers AST directly to LLVM IR (textual `.ll` format)
- Shells out to `clang` to compile LLVM IR → native binary
- Links against `rockit_runtime.o` (C runtime providing ARC, task scheduling, I/O)
- Used for: production builds, Stage 1 compilation, release binaries

## Module Structure

```
RockitKit (library)
├── Lexical Analysis
│   ├── Token.swift          130+ token types, source locations
│   └── Lexer.swift          Tokenizer with string interpolation, nestable comments
├── Syntax Analysis
│   ├── AST.swift            All AST node definitions (enums with associated values)
│   └── Parser.swift         Recursive descent, all declarations and expressions
├── Semantic Analysis
│   └── TypeChecker.swift    Two-pass type checker (gather → check)
├── Intermediate Representation
│   ├── MIRLowering.swift    AST → MIR conversion
│   └── MIROptimizer.swift   Optimization passes on MIR
├── Code Generation
│   ├── CodeGen.swift        MIR → bytecode
│   └── LLVMCodeGen.swift    AST → LLVM IR → native binary
├── Runtime (VM)
│   ├── VM.swift             Bytecode interpreter
│   ├── Heap.swift           Object heap with ARC
│   ├── Scheduler.swift      Coroutine scheduler
│   ├── Coroutine.swift      Suspend/resume state machines
│   ├── ActorRuntime.swift   Actor mailbox dispatch
│   └── CycleDetector.swift  ARC cycle detection
├── Infrastructure
│   ├── Diagnostic.swift     Error/warning reporting engine
│   ├── ImportResolver.swift Module import resolution
│   └── BuiltinFunctions.swift  Crypto, X.509, hashing builtins
└── CLI (RockitCLI)
    └── main.swift           Command dispatch, test runner, REPL

RockitLSP (library)
├── LSPServer.swift          JSON-RPC transport
├── CompletionProvider.swift
├── DefinitionProvider.swift
├── HoverProvider.swift
├── DiagnosticsProvider.swift
├── SemanticTokensProvider.swift
└── ... (27 files total)
```

## Key Design Decisions

### Why Swift?

- Strong type system catches compiler bugs at compile time
- Algebraic data types (enums with associated values) map naturally to AST nodes
- Swift Package Manager provides clean dependency management
- macOS is the primary development platform; Swift is native
- `swift-crypto` provides cross-platform CryptoKit API for Linux builds

### Why Two-Pass Type Checking?

The type checker runs in two passes:
1. **Gather pass** — collects all type declarations, function signatures, and class hierarchies
2. **Check pass** — validates types, resolves generics, checks null safety, verifies exhaustive matching

This allows forward references (a function can call another function declared later in the file) and handles mutual recursion between types.

### Why MIR?

The Mid-level IR sits between the AST and codegen:
- **Decouples frontend from backend** — parser changes don't affect codegen
- **Enables optimization** — constant folding, dead code elimination, and inlining operate on MIR
- **Simplifies codegen** — MIR is closer to machine semantics than the AST

### Why Textual LLVM IR (not LLVM C API)?

- Zero LLVM build dependency — only needs `clang` at link time
- Simpler build process (no linking against libLLVM)
- Textual IR is human-readable and debuggable
- Sufficient for Stage 0's purpose (correctness, not extreme optimization)

## Error Handling

All compiler diagnostics go through `DiagnosticEngine`:
- Source locations attached to every token and AST node
- Errors, warnings, and notes with source spans
- Multiple diagnostics can be reported before aborting
- Never uses `print()` for error output directly

## Memory Model

The runtime uses Automatic Reference Counting (ARC):
- **Compile time**: The compiler inserts retain/release calls at appropriate points
- **Runtime (VM)**: `Heap.swift` manages object lifetimes with reference counting
- **Runtime (native)**: `rockit_runtime.c` provides ARC primitives (retain, release, object allocation)
- **Cycle detection**: `CycleDetector.swift` identifies potential retain cycles
- **No garbage collector** — deterministic deallocation, predictable performance
