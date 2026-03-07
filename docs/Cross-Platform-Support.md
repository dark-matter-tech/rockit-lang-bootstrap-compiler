# Cross-Platform Support

The bootstrap compiler builds and runs on macOS, Linux, and (experimentally) Windows.

## Platform Matrix

| Platform | Architecture | Status | CI | Notes |
|----------|-------------|--------|-----|-------|
| macOS | arm64 (Apple Silicon) | Full | Planned | Primary development platform |
| macOS | x86_64 (Intel) | Full | — | Supported via Rosetta 2 or native |
| Linux | x86_64 | Full | GitHub Actions, Gitea | Production CI platform |
| Linux | arm64 | Full | — | Tested manually, same as x86_64 |
| Windows | x86_64 | Experimental | Planned | Requires Swift for Windows |

## macOS

### Requirements
- Xcode Command Line Tools (provides Swift and clang)

### Setup
```bash
xcode-select --install
```

### Platform-Specific Behavior
- **CryptoKit**: Uses Apple's native CryptoKit framework
- **Security framework**: Available for X.509 certificate operations (`SecCertificate`)
- **CommonCrypto**: Available for AES-CBC operations (`CCCrypt`)
- **Code signing**: `codesign` with hardened runtime + notarization via `notarytool`
- **clang**: Apple clang (ships with Xcode CLT)

### Conditional Compilation

```swift
#if canImport(CryptoKit)
import CryptoKit          // macOS native
#else
import Crypto             // swift-crypto (Linux)
#endif

#if canImport(Security)
import Security           // macOS: SecCertificate, SecRandomCopyBytes
#endif

#if canImport(CommonCrypto)
import CommonCrypto       // macOS: CCCrypt (AES-CBC)
#endif
```

## Linux

### Requirements
- Swift 5.9+ (from swift.org or Docker image)
- clang 15+
- libssl-dev (OpenSSL development headers)
- pkg-config

### Setup (Ubuntu/Debian)
```bash
sudo apt update
sudo apt install clang-15 libssl-dev pkg-config
sudo ln -sf /usr/bin/clang-15 /usr/bin/clang
```

### Docker
```bash
docker run -it swift:5.10.1-jammy bash
apt-get update && apt-get install -y clang-15 libssl-dev pkg-config
ln -sf /usr/bin/clang-15 /usr/bin/clang
```

### Platform-Specific Behavior
- **swift-crypto**: Apple's open-source CryptoKit implementation (same API as CryptoKit)
- **OpenSSL (COpenSSL)**: Used for AES-CBC encryption/decryption and X.509 operations
- **Random bytes**: `UInt8.random(in: 0...255)` (no `SecRandomCopyBytes`)
- **Code signing**: GPG detached signatures
- **clang**: System clang (clang-15 recommended)

### COpenSSL Module

The `COpenSSL` system library target wraps OpenSSL headers for Swift interop:

```
Sources/COpenSSL/
├── module.modulemap    System module definition
└── shim.h              OpenSSL header includes
```

This target is conditionally included only on Linux:

```swift
// Package.swift
.target(name: "RockitKit", dependencies: [
    .product(name: "Crypto", package: "swift-crypto"),
    .target(name: "COpenSSL", condition: .when(platforms: [.linux]))
])
```

### OpenSSL Functions Used

| Swift API (macOS) | OpenSSL API (Linux) | Purpose |
|-------------------|---------------------|---------|
| `SecCertificateCreateWithData` | `d2i_X509` | Parse X.509 certificate |
| `SecCertificateCopySubjectSummary` | `X509_get_subject_name` | Get certificate subject |
| `SecCertificateCopyValues` | `X509_get_issuer_name` | Get certificate issuer |
| `CCCrypt` (CBC mode) | `EVP_CipherInit_ex` / `EVP_CipherUpdate` | AES-CBC encrypt/decrypt |
| `SecRandomCopyBytes` | `UInt8.random` | Cryptographic random bytes |

## Windows (Experimental)

### Requirements
- Swift for Windows (from swift.org)
- Visual Studio Build Tools (provides clang-cl)
- OpenSSL for Windows (optional, for crypto builtins)

### Status

Windows support is experimental. The compiler builds with Swift for Windows, but native codegen requires a Windows-compatible clang. The bytecode path (`compile`, `run`) works fully.

### Code Signing
- Windows Authenticode via `signtool.exe` (requires code signing certificate)
- The `sign.sh` script includes Windows Authenticode support

## CI Platforms

### GitHub Actions

```yaml
# Linux CI
runs-on: ubuntu-22.04
container: swift:5.10.1-jammy
steps:
  - run: apt-get update && apt-get install -y clang-15 libssl-dev pkg-config
  - run: swift build -c release
  - run: swift test
```

### Gitea Actions

Same container and steps as GitHub Actions. Gitea runners may have less memory — the CI workflow removes debug build artifacts before release builds to conserve memory:

```yaml
- run: rm -rf .build/debug
- run: swift build -c release
```

## Native Binary Targets

When compiling to native binaries, specify the target triple:

```bash
# Linux x86_64
.build/release/rockit build-native file.rok --target-triple x86_64-unknown-linux-gnu

# macOS arm64
.build/release/rockit build-native file.rok --target-triple aarch64-apple-darwin

# macOS x86_64
.build/release/rockit build-native file.rok --target-triple x86_64-apple-darwin
```

The runtime (`rockit_runtime.o`) must be compiled for the target platform. The `runtime/rockit/build.sh` script handles this.

## Release Packaging

Release tarballs are platform-specific:

```
rockit-0.1.0-linux-x86_64.tar.gz
rockit-0.1.0-darwin-arm64.tar.gz
rockit-0.1.0-darwin-x86_64.tar.gz
```

Each contains:
```
rockit/
  bin/rockit              # Native compiler binary
  bin/fuel                # Package manager
  share/rockit/
    rockit_runtime.o      # Prebuilt runtime for this platform
    stdlib/rockit/        # Standard library (platform-independent)
  MANIFEST.sha256         # File integrity manifest
  MANIFEST.sha256.sig     # GPG signature (if signed)
```
