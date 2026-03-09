# Bootstrap Process

## What Is Self-Hosting?

A self-hosting compiler is one that can compile its own source code. Rockit follows the standard self-hosting bootstrap strategy used by production compilers (GCC, Rust, Go, etc.).

## The Bootstrap Chain

```
Stage 0 (this repo, Swift)
    │
    │  compiles command.rok
    ▼
Stage 1 (rockit-compiler repo, Rockit)
    │
    │  compiles command.rok
    ▼
Stage 2 (Rockit, compiled by Stage 1)
    │
    │  compiles command.rok
    ▼
Stage 3 (Rockit, compiled by Stage 2)

Verification: Stage 2 bytecode == Stage 3 bytecode (fixed point)
```

### Stage 0 — Bootstrap Compiler (This Repo)

- Written in Swift
- Full compiler pipeline: lexer, parser, type checker, MIR, optimizer, codegen
- Produces both bytecode (`.rokb`) and native binaries (via LLVM IR + clang)
- **Purpose**: Compile Stage 1 from source. Once Stage 1 exists, Stage 0 becomes a recovery tool and reference implementation.

### Stage 1 — Self-Hosted Compiler

- Written in Rockit (`.rok` files)
- Lives in the [rockit-compiler](https://rustygits.com/Dark-Matter/rockit-compiler) repo
- Compiled by Stage 0 into a native binary
- Contains the same compiler pipeline reimplemented in Rockit
- **Purpose**: The production compiler. All subsequent versions are compiled by the previous version.

### Stage 2 — First Self-Compiled Binary

- Stage 1 compiles its own source code
- Produces a new compiler binary
- **Purpose**: Prove that Stage 1 can compile itself (self-hosting works)

### Stage 3 — Verification Binary

- Stage 2 compiles the same source code
- Produces another compiler binary
- **Purpose**: Verify fixed-point convergence (Stage 2 output == Stage 3 output)

## Fixed-Point Verification

The critical invariant: **Stage 2 bytecode must be identical to Stage 3 bytecode**.

```
Stage 1 compiles command.rok → stage2.rokb (bytecode)
Stage 2 compiles command.rok → stage3.rokb (bytecode)
diff stage2.rokb stage3.rokb → must be identical
```

If they match, the compiler has reached a fixed point — it produces the same output regardless of which stage compiled it. This proves:
1. The compiler is correct (it faithfully reproduces itself)
2. No compiler-level backdoors exist (Thompson attack defense)

### Thompson Attack Defense

Ken Thompson's 1984 paper "Reflections on Trusting Trust" described how a compiler could be modified to insert backdoors that persist even after the malicious source is removed — the compromised compiler would re-insert the backdoor when compiling itself.

Fixed-point verification defends against this:
- Stage 0 (Swift) is a completely independent implementation
- If Stage 0 were compromised, Stage 2 and Stage 3 would differ (the backdoor injection would produce different output depending on which compiler did the compilation)
- Bytecode comparison catches any divergence

## Build Identity

Every compiled binary includes embedded provenance metadata:

| Field | Example | Source |
|-------|---------|--------|
| Version | `0.1.0` | `VERSION` file |
| Git Hash | `abc1234` | `git rev-parse HEAD` |
| Source Hash | `sha256:...` | SHA-256 of concatenated source |
| Build Timestamp | `2026-03-07T12:00:00Z` | Build time (UTC) |
| Build Platform | `darwin-arm64` | `uname -s` + `uname -m` |

View with `rockit version`:
```
rockit 0.1.0
commit:    abc1234
source:    sha256:e3b0c44298fc1c149afb...
built:     2026-03-07T12:00:00Z
platform:  darwin-arm64
```

## How Stage 1 Source Is Built

The Stage 1 compiler is split across multiple `.rok` files for maintainability. A build script (`build.sh`) concatenates them into a single `command.rok`:

```bash
# build.sh concatenation order:
lexer.rok → parser.rok → typechecker.rok → optimizer.rok → llvmgen.rok → update.rok → codegen.rok
```

The `codegen.rok` file contains `main()` and is always last. The build script also:
1. Strips duplicate `main()` functions from non-entry modules
2. Injects build identity placeholders (version, git hash, timestamp, platform)
3. Computes source hash after all other substitutions

## Running the Bootstrap Locally

```bash
# 1. Build Stage 0
cd RockitCompiler
swift build -c release

# 2. Compile Stage 1 from source
.build/release/rockit build-native self-hosted-rockit/command.rok

# 3. Verify the binary works
self-hosted-rockit/command version

# 4. Run bootstrap verification
self-hosted-rockit/command verify-bootstrap
```

## Bootstrap Verification in CI

The release workflow performs full Thompson attack defense:

```yaml
# Build Stage 2 native binary
self-hosted-rockit/command build-native self-hosted-rockit/command.rok -o /tmp/stage2

# Bytecode comparison
self-hosted-rockit/command compile self-hosted-rockit/command.rok -o /tmp/stage2.rokb
/tmp/stage2 compile self-hosted-rockit/command.rok -o /tmp/stage3.rokb
diff /tmp/stage2.rokb /tmp/stage3.rokb  # Must match
```

## Recovery Scenario

If the Stage 1 binary is ever lost or corrupted:

1. Clone this repo (Stage 0)
2. `swift build -c release`
3. `.build/release/rockit build-native /path/to/rockit-compiler/src/command.rok`
4. A fresh Stage 1 binary is produced from source
5. Verify with `command verify-bootstrap`

This is why Stage 0 is maintained even after self-hosting is achieved — it's the root of trust for the entire bootstrap chain.
