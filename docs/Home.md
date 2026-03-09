# Rockit Bootstrap Compiler Documentation

Technical documentation for the Rockit Bootstrap Compiler (Stage 0).

## Contents

- **[Architecture](Architecture.md)** — Compiler pipeline, phase overview, and design decisions
- **[Bootstrap Process](Bootstrap-Process.md)** — How self-hosting works, the bootstrap chain, and verification
- **[Building from Source](Building-from-Source.md)** — Prerequisites, build instructions, platform-specific notes
- **[Compiler Phases](Compiler-Phases.md)** — Detailed documentation of each compiler phase
- **[Language Reference](Language-Reference.md)** — Rockit language grammar and feature summary
- **[Testing](Testing.md)** — Test suite structure, running tests, writing new tests
- **[LSP Integration](LSP-Integration.md)** — Language Server Protocol support for editors
- **[Cross-Platform Support](Cross-Platform-Support.md)** — macOS, Linux, and Windows compilation
- **[Security Architecture](Security-Architecture.md)** — Build identity, code signing, bootstrap verification
- **[Contributing](Contributing.md)** — Development workflow, coding standards, PR process
- **[Troubleshooting](Troubleshooting.md)** — Common issues and solutions

## Quick Reference

| Command | Description |
|---------|-------------|
| `swift build -c release` | Build the compiler |
| `swift test` | Run all 542 unit tests |
| `.build/release/rockit build-native file.rok` | Compile .rok to native binary |
| `.build/release/rockit compile file.rok -o out.rokb` | Compile .rok to bytecode |
| `.build/release/rockit run file.rok` | Run via bytecode VM |
| `.build/release/rockit lsp` | Start language server |

## Repository Map

```
Sources/RockitKit/     -> Core compiler library (37 files)
Sources/RockitCLI/     -> CLI entry point
Sources/RockitLSP/     -> Language server (27 files)
Sources/COpenSSL/      -> OpenSSL C interop (Linux)
Tests/RockitKitTests/  -> 542 unit tests
```
