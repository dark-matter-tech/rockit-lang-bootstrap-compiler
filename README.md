# Rockit Bootstrap Compiler (Stage 0)

The Swift-based bootstrap compiler for the Rockit programming language. Its sole purpose is to compile the self-hosted Rockit compiler (Stage 1) from source.

> **Status:** Complete. All compiler phases implemented. 542 unit tests passing. Self-hosting verified (Stage 2 == Stage 3).

## What This Is

This is Stage 0 of the Rockit compiler bootstrap chain:

```
Stage 0 (this repo, Swift)  compiles  command.rok  →  Stage 1 binary
Stage 1 (rockit-compiler)   compiles  command.rok  →  Stage 2 binary
Stage 2                     compiles  command.rok  →  Stage 3 binary
                                                      Stage 2 == Stage 3 ✅
```

Once Stage 1 exists, this compiler is only needed as a recovery tool. The self-hosted compiler in [rockit-compiler](https://rustygits.com/Dark-Matter/rockit-compiler) is the production compiler.

## Build

Requires Swift 5.9+.

```bash
swift build -c release
```

## Usage

```bash
# Compile Stage 1 from the rockit-compiler repo
.build/release/rockit build-native /path/to/rockit-compiler/src/command.rok

# Run tests
swift test
```

## Structure

```
Sources/
  RockitKit/       Core compiler library (lexer, parser, type checker, codegen, VM)
  RockitCLI/       CLI entry point
  RockitLSP/       Language server protocol
  COpenSSL/        OpenSSL C interop (Linux)
Tests/
  RockitKitTests/  542 unit tests
```

## License

Proprietary — Dark Matter Tech
