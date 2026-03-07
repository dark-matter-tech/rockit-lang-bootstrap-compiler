# Security Architecture

The Rockit compiler implements a multi-layered security architecture covering build provenance, release integrity, code signing, and bootstrap verification.

## Security Layers

| Layer | Name | Status | Description |
|-------|------|--------|-------------|
| 1 | Build Identity | Implemented | Embedded provenance metadata in every binary |
| 2 | Release Manifests | Implemented | SHA-256 hash manifest for every file in a release |
| 3 | Code Signing | Implemented | GPG, macOS codesign + notarization, Windows Authenticode |
| 4 | Bootstrap Verification | Implemented | Fixed-point check (Thompson attack defense) |

## Layer 1: Build Identity

Every compiled binary embeds metadata about how it was built:

```
$ rockit version
rockit 0.1.0
commit:    abc1234def5678
source:    sha256:e3b0c44298fc1c149afb...
built:     2026-03-07T12:00:00Z
platform:  linux-x86_64
```

| Field | Source | Injection |
|-------|--------|-----------|
| `ROCKIT_VERSION` | `VERSION` file | sed replacement in `build.sh` |
| `ROCKIT_GIT_HASH` | `git rev-parse HEAD` | sed replacement in `build.sh` |
| `ROCKIT_SOURCE_HASH` | SHA-256 of concatenated source | Computed after other substitutions |
| `ROCKIT_BUILD_TIMESTAMP` | `date -u` | sed replacement in `build.sh` |
| `ROCKIT_BUILD_PLATFORM` | `uname -s` + `uname -m` | sed replacement in `build.sh` |

### How It Works

The `build.sh` script:
1. Concatenates `.rok` source modules into `command.rok`
2. Replaces `__ROCKIT_VERSION__`, `__ROCKIT_GIT_HASH__`, etc. with real values via `sed`
3. Computes the source hash last (after all other substitutions)
4. The resulting `command.rok` has real values baked in as string constants

## Layer 2: Release Manifests

Every release tarball includes a `MANIFEST.sha256` file listing SHA-256 hashes of all files:

```
sha256:abc123...  bin/rockit
sha256:def456...  bin/fuel
sha256:789abc...  share/rockit/rockit_runtime.o
sha256:012def...  share/rockit/stdlib/rockit/core/collections.rok
...
```

### Generation (package.sh)

```bash
find . -type f ! -name "MANIFEST.sha256" ! -name "*.sig" | sort | while read -r f; do
    hash=$(shasum -a 256 "$f" | awk '{print $1}')
    echo "sha256:${hash}  ${f#./}" >> MANIFEST.sha256
done
```

### Verification (install.sh)

The install script verifies every file against the manifest after download:

```bash
while IFS= read -r line; do
    expected_hash="${line%% *}"
    expected_hash="${expected_hash#sha256:}"
    file_path="${line#* }"
    actual_hash=$(shasum -a 256 "$file_path" | awk '{print $1}')
    if [ "$actual_hash" != "$expected_hash" ]; then
        echo "HASH MISMATCH: $file_path"
        exit 1
    fi
done < MANIFEST.sha256
```

## Layer 3: Code Signing

### Signing Methods

| Method | Platform | Tool | Env Vars |
|--------|----------|------|----------|
| GPG | All | `gpg --detach-sign` | `GPG_KEY_ID`, `GPG_PASSPHRASE` |
| macOS codesign | macOS | `codesign --sign` | `APPLE_IDENTITY`, `APPLE_TEAM_ID` |
| macOS notarization | macOS | `xcrun notarytool` | `APPLE_ID`, `APPLE_APP_PASSWORD` or `APPLE_KEYCHAIN_PROFILE` |
| Windows Authenticode | Windows | `signtool.exe` | `WIN_CERT_PATH`, `WIN_CERT_PASSWORD`, `WIN_TIMESTAMP_URL` |

### GPG Signing (Universal Baseline)

GPG signatures are the universal baseline — produced on all platforms:

```bash
# Sign a binary
gpg --batch --yes --detach-sign --armor \
    --default-key "$GPG_KEY_ID" \
    --output file.sig file

# Sign the manifest
gpg --batch --yes --detach-sign --armor \
    --default-key "$GPG_KEY_ID" \
    --output MANIFEST.sha256.sig MANIFEST.sha256
```

### macOS Codesign + Notarization

```bash
# Step 1: Code sign with hardened runtime
codesign --force --options runtime \
    --sign "Developer ID Application: IDENTITY" \
    --identifier "com.darkmatter.rockit" \
    --timestamp file

# Step 2: Create zip for notarization
ditto -c -k --keepParent file file.zip

# Step 3: Submit for notarization
xcrun notarytool submit file.zip \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait

# Step 4: Staple the notarization ticket
xcrun stapler staple file
```

### Windows Authenticode

```bash
signtool.exe sign /f "$WIN_CERT_PATH" /p "$WIN_CERT_PASSWORD" \
    /fd sha256 /tr "$WIN_TIMESTAMP_URL" /td sha256 file
```

### Verification Flow

When a user installs Rockit:

```
1. Download tarball
2. Import public GPG key (from keys/ in repo)
3. Verify MANIFEST.sha256.sig against MANIFEST.sha256
4. Verify every file hash against MANIFEST.sha256
5. Install binaries
```

The install scripts (`install.sh`, `install.ps1`) automate this process.

### CI Integration

The release workflow signs automatically:

1. GPG private key imported from `GPG_PRIVATE_KEY` secret
2. Binaries signed with GPG
3. macOS binaries additionally codesigned + notarized (if Apple credentials available)
4. Manifest generated after signing (hashes include signatures)
5. Manifest itself signed with GPG

## Layer 4: Bootstrap Verification

### Thompson Attack Defense

Every release build runs a full bootstrap verification:

```bash
# Stage 1 compiles itself → Stage 2 (native binary)
command build-native command.rok -o /tmp/stage2 \
    --runtime-path runtime/rockit_runtime.o

# Stage 1 compiles to bytecode
command compile command.rok -o /tmp/stage2.rokb

# Stage 2 compiles to bytecode
/tmp/stage2 compile command.rok -o /tmp/stage3.rokb

# Compare: Stage 2 bytecode must equal Stage 3 bytecode
diff /tmp/stage2.rokb /tmp/stage3.rokb
```

If the bytecode matches, the compiler has reached a fixed point — no backdoors were injected by the compilation process.

### Why This Works

1. **Stage 0 (Swift)** is a completely independent implementation
2. **Stage 1** is compiled by Stage 0 — if Stage 0 were compromised, Stage 2 and Stage 3 would differ
3. **Bytecode comparison** is deterministic — same source + same compiler = same bytecode
4. **Any divergence** between Stage 2 and Stage 3 bytecode indicates a compiler compromise

### User-Initiated Verification

Users can run bootstrap verification locally:

```bash
rockit verify-bootstrap
```

This runs the full Stage 2 / Stage 3 comparison and reports pass/fail with hashes.

## Key Distribution

### Public Keys

Public signing keys are stored in the `keys/` directory of the repository:

```
keys/
├── README.md           Setup instructions and documentation
└── (public keys)       GPG public keys for release verification
```

### Key Rotation

1. Generate new key pair
2. Sign new public key with old private key (chain of trust)
3. Add new public key to `keys/` directory
4. Update `SIGNING_KEY_ID` in install scripts
5. Transition period: releases signed with both old and new keys

## Threat Model

| Threat | Mitigation |
|--------|-----------|
| Tampered release binary | SHA-256 manifest + GPG signature verification |
| Compromised download channel | HTTPS + manifest verification |
| Compiler backdoor (Thompson attack) | Fixed-point bootstrap verification |
| Stolen signing key | Key rotation process, hardware key support (YubiKey) |
| Build environment compromise | Reproducible builds (same source → same bytecode) |
| Supply chain attack (dependencies) | Minimal dependencies (only swift-crypto), vendored COpenSSL |

## Security Contact

Report security vulnerabilities to the Dark Matter Tech security team. See `SECURITY.md` in the repository root for contact information and responsible disclosure policy.
