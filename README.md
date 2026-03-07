# Rockit Bootstrap Compiler (Stage 0)

The Swift-based bootstrap compiler for the [Rockit programming language](https://rustygits.com/Dark-Matter/rockit-compiler). Stage 0 of the compiler bootstrap chain — it compiles the self-hosted Rockit compiler from source, completing the bootstrap cycle.

> **Status:** Complete. All 8 compiler phases implemented. 542 unit tests passing. Self-hosting verified (Stage 2 == Stage 3 bytecode match).

## Bootstrap Chain

Rockit follows a standard self-hosting bootstrap strategy:

```
Stage 0 (this repo, Swift)  compiles  command.rok  →  Stage 1 binary
Stage 1 (rockit-compiler)   compiles  command.rok  →  Stage 2 binary
Stage 2                     compiles  command.rok  →  Stage 3 binary
                                                      Stage 2 == Stage 3 ✅
```

Once Stage 1 exists, this compiler serves as a recovery tool and reference implementation. The self-hosted compiler in [rockit-compiler](https://rustygits.com/Dark-Matter/rockit-compiler) is the production compiler.

## Prerequisites

| Dependency | Version | Purpose |
|------------|---------|---------|
| Swift | 5.9+ | Compiler toolchain |
| clang | 15+ | LLVM IR → native binary |
| libssl-dev | any | OpenSSL crypto builtins (Linux only) |
| pkg-config | any | OpenSSL discovery (Linux only) |

**macOS:** Xcode Command Line Tools provides Swift and clang.

**Linux:**
```bash
# Ubuntu/Debian
sudo apt install clang-15 libssl-dev pkg-config

# Swift (if not installed)
# https://swift.org/download
```

## Build

```bash
# Debug build
swift build

# Release build (optimized, used for Stage 1 compilation)
swift build -c release
```

## Usage

```bash
# Compile Stage 1 from the rockit-compiler repo
.build/release/rockit build-native /path/to/rockit-compiler/src/command.rok

# Run a .rok file (bytecode, via VM)
.build/release/rockit run hello.rok

# Compile to bytecode
.build/release/rockit compile hello.rok -o hello.rokb

# Compile to native binary
.build/release/rockit build-native hello.rok

# Start the language server
.build/release/rockit lsp

# Run tests
swift test
```

## Compiler Pipeline

```
.rok source → Lexer → Tokens → Parser → AST → Type Checker → Typed AST
    → MIR Lowering → MIR → Optimizer → Optimized MIR → Codegen → Bytecode/LLVM IR
```

| Phase | File | Description |
|-------|------|-------------|
| Lexer | `Lexer.swift` | 130+ token types, string interpolation, nestable comments |
| Parser | `Parser.swift` | Recursive descent, all declarations and expressions |
| Type Checker | `TypeChecker.swift` | Type inference, null safety, exhaustive matching, generics |
| MIR Lowering | `MIRLowering.swift` | AST → mid-level intermediate representation |
| MIR Optimizer | `MIROptimizer.swift` | Constant folding, dead code elimination, inlining, tree shaking |
| Bytecode Codegen | `CodeGen.swift` | MIR → bytecode for the VM |
| LLVM Codegen | `LLVMCodeGen.swift` | AST → LLVM IR → native binary via clang |
| VM | `VM.swift` | Bytecode interpreter with ARC, coroutines, actor dispatch |

## Project Structure

```
Sources/
├── RockitKit/                 Core compiler library (37 files)
│   ├── Token.swift            Token types and source locations
│   ├── Lexer.swift            Tokenizer
│   ├── AST.swift              AST node definitions
│   ├── Parser.swift           Recursive descent parser
│   ├── TypeChecker.swift      Two-pass type checker
│   ├── MIRLowering.swift      AST → MIR
│   ├── MIROptimizer.swift     Optimization passes
│   ├── CodeGen.swift          MIR → bytecode
│   ├── LLVMCodeGen.swift      AST → LLVM IR → native
│   ├── VM.swift               Bytecode interpreter
│   ├── Heap.swift             Object heap (ARC)
│   ├── Diagnostic.swift       Error/warning reporting
│   ├── ImportResolver.swift   Module import resolution
│   ├── BuiltinFunctions.swift Crypto, X.509, hashing builtins
│   ├── Scheduler.swift        Coroutine scheduler
│   ├── Coroutine.swift        Suspend/resume state machines
│   ├── ActorRuntime.swift     Actor mailbox dispatch
│   ├── CycleDetector.swift    ARC cycle detection
│   └── ...
├── RockitCLI/                 CLI entry point
│   └── main.swift             Command dispatch, test runner, REPL
├── RockitLSP/                 Language Server Protocol (27 files)
│   ├── LSPServer.swift        JSON-RPC server
│   ├── CompletionProvider.swift
│   ├── DefinitionProvider.swift
│   ├── HoverProvider.swift
│   ├── DiagnosticsProvider.swift
│   ├── SemanticTokensProvider.swift
│   └── ...
└── COpenSSL/                  OpenSSL C interop (Linux)
    ├── module.modulemap
    └── shim.h

Tests/
└── RockitKitTests/            542 unit tests (14 files)
    ├── LexerTests.swift
    ├── ParserTests.swift
    ├── TypeCheckerTests.swift
    ├── BytecodeCodegenTests.swift
    ├── LLVMCodeGenTests.swift
    ├── VMTests.swift
    ├── CollectionTests.swift
    ├── CoroutineTests.swift
    ├── ActorTests.swift
    ├── ARCTests.swift
    └── ...
```

## Documentation

Full technical documentation is in the [`docs/`](docs/Home.md) directory:

- [Architecture](docs/Architecture.md) — Pipeline design and key decisions
- [Bootstrap Process](docs/Bootstrap-Process.md) — Self-hosting and verification
- [Building from Source](docs/Building-from-Source.md) — Platform setup and build instructions
- [Compiler Phases](docs/Compiler-Phases.md) — All 8 phases in detail
- [Language Reference](docs/Language-Reference.md) — Rockit syntax and features
- [Security Architecture](docs/Security-Architecture.md) — Signing, manifests, Thompson defense
- [Testing](docs/Testing.md) — Test suite and CI
- [Troubleshooting](docs/Troubleshooting.md) — Common issues

## Related Repositories

| Repository | Description |
|------------|-------------|
| [rockit-compiler](https://rustygits.com/Dark-Matter/rockit-compiler) | Self-hosted compiler (Stage 1+), the production compiler |
| [launchpad](https://rustygits.com/Dark-Matter/launchpad) | Standard library (15 modules) |
| [fuel](https://rustygits.com/Dark-Matter/fuel) | Package manager |
| [moon](https://rustygits.com/Dark-Matter/moon) | Monorepo (umbrella, IDE plugins, specs) |

## License

Proprietary — Dark Matter Tech
