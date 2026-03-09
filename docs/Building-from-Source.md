# Building from Source

## Prerequisites

| Dependency | Version | Platform | Purpose |
|------------|---------|----------|---------|
| Swift | 5.9+ | All | Compiler toolchain |
| clang | 15+ | All | LLVM IR → native binary |
| Xcode CLT | Latest | macOS | Provides Swift + clang |
| libssl-dev | Any | Linux | OpenSSL crypto builtins |
| pkg-config | Any | Linux | OpenSSL discovery |

## Platform Setup

### macOS

Install Xcode Command Line Tools (provides both Swift and clang):

```bash
xcode-select --install
```

Verify:
```bash
swift --version    # Swift 5.9+
clang --version    # Apple clang 15+
```

### Ubuntu / Debian

```bash
# System dependencies
sudo apt update
sudo apt install clang-15 libssl-dev pkg-config

# Symlink clang (if needed)
sudo ln -sf /usr/bin/clang-15 /usr/bin/clang

# Swift (if not installed)
# Follow instructions at https://swift.org/download
# Or use the official Swift Docker image: swift:5.10.1-jammy
```

Verify:
```bash
swift --version    # Swift 5.9+
clang --version    # clang 15+
pkg-config --modversion openssl
```

### Docker (Linux)

```bash
docker run -it swift:5.10.1-jammy bash
apt-get update && apt-get install -y clang-15 libssl-dev pkg-config
ln -sf /usr/bin/clang-15 /usr/bin/clang
```

## Building

### Debug Build

```bash
swift build
```

Debug builds include assertions and debug symbols. Slower but useful for development.

### Release Build

```bash
swift build -c release
```

Release builds are optimized. Use this for compiling Stage 1 (the self-hosted compiler).

The compiled binary is at `.build/release/rockit`.

### Running Tests

```bash
# All 542 tests
swift test

# Specific test file
swift test --filter LexerTests

# Specific test case
swift test --filter "LexerTests/testStringInterpolation"
```

## Project Layout (SPM)

The project uses Swift Package Manager with standard directory layout:

```
Package.swift              SPM manifest
Sources/
├── RockitKit/             Core compiler library (37 files)
├── RockitCLI/             CLI entry point (main.swift)
├── RockitLSP/             Language server (27 files)
└── COpenSSL/              OpenSSL C interop (Linux only)
    ├── module.modulemap
    └── shim.h
Tests/
└── RockitKitTests/        Unit tests (14 files, 542 tests)
```

## Package.swift Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| [swift-crypto](https://github.com/apple/swift-crypto) | 3.0.0+ | Cross-platform CryptoKit (SHA-256, HMAC, AES-GCM) |

The `COpenSSL` system library target is conditionally included on Linux for OpenSSL C interop (AES-CBC, X.509 operations).

## Compiling Stage 1

Once Stage 0 is built, use it to compile the self-hosted compiler:

```bash
# From the RockitCompiler directory
.build/release/rockit build-native self-hosted-rockit/command.rok

# The Stage 1 binary is written to self-hosted-rockit/command
self-hosted-rockit/command version
```

### With Runtime (for native builds)

Native builds link against the Rockit runtime. Build it first:

```bash
cd runtime/rockit && bash build.sh && cd ../..

# Then compile with explicit runtime path
.build/release/rockit build-native self-hosted-rockit/command.rok \
  --runtime-path runtime/rockit_runtime.o
```

### Cross-Compilation

Specify a target triple for cross-compilation:

```bash
.build/release/rockit build-native self-hosted-rockit/command.rok \
  --target-triple x86_64-unknown-linux-gnu \
  --runtime-path runtime/rockit_runtime.o
```

## Troubleshooting Build Issues

### "No such module 'CryptoKit'" on Linux

This is expected. The `Package.swift` conditionally uses `swift-crypto` (Apple's open-source CryptoKit) on Linux. Make sure `swift build` resolves dependencies:

```bash
swift package resolve
swift build
```

### "pkg-config: openssl not found" on Linux

Install OpenSSL development headers:

```bash
sudo apt install libssl-dev pkg-config
```

### clang not found

The native codegen path requires clang. Install it:

```bash
# macOS
xcode-select --install

# Linux
sudo apt install clang-15
sudo ln -sf /usr/bin/clang-15 /usr/bin/clang
```

### Out of Memory in CI

If building in a container with limited memory, avoid having both debug and release builds:

```bash
rm -rf .build/debug
swift build -c release
```

### Swift Version Too Old

The minimum Swift version is 5.9. Check with:

```bash
swift --version
```

On Linux, install a newer Swift from [swift.org/download](https://swift.org/download) or use the `swift:5.10.1-jammy` Docker image.
