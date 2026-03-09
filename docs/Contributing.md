# Contributing

## Development Workflow

### Branch Strategy

| Branch | Purpose |
|--------|---------|
| `develop` | Active development. PRs merge here. |
| `master` | Testing and integration. Merges from develop. |
| `staging` | Production. Merges from master. Tagged with version numbers. Triggers releases. |
| `feature/*` | Feature branches. Branch from develop, PR back to develop. |
| `fix/*` | Bug fix branches. Same flow as feature branches. |

### Workflow

1. Branch from `develop`
2. Make changes
3. Run tests locally (`swift test`)
4. Push and open PR against `develop`
5. CI must pass (all 542 tests green)
6. Code review
7. Merge to `develop`

### Release Process

1. Merge `develop` → `master` for testing and integration
2. Run full test suite + bootstrap verification on master
3. Merge `master` → `staging` for production release
4. Tag with version: `git tag v0.1.1`
5. CI builds release artifacts automatically (triggered by staging)

## Coding Standards

### Swift Style

- **One type per file.** No multi-type files.
- **`public`** for API that RockitKit consumers need. **`internal`** or **`private`** for everything else.
- **Every compiler phase gets its own file(s)** in RockitKit.
- **AST nodes should be enums** with associated values where possible (Swift's algebraic types map well to compiler IR).
- **All diagnostics go through `DiagnosticEngine`** — never `print()` errors directly.
- **Descriptive names.** This is a compiler — clarity matters more than brevity.

### Naming Conventions

```swift
// Types: UpperCamelCase
class TypeChecker { ... }
enum TokenType { ... }

// Functions/methods: lowerCamelCase
func resolveType(_ node: ASTNode) -> RockitType { ... }

// Variables: lowerCamelCase
let currentToken: Token
var scopeDepth: Int

// Constants: lowerCamelCase (Swift convention)
let maxScopeDepth = 256

// Files: UpperCamelCase matching primary type
// TypeChecker.swift contains class TypeChecker
```

### Error Handling

```swift
// DO: Use DiagnosticEngine
diagnosticEngine.report(.error, "Type mismatch: expected \(expected), got \(actual)", at: node.location)

// DON'T: Print directly
print("Error: type mismatch")  // Never do this
```

### Testing

- **Tests for every phase.** The compiler must be testable at each boundary: source→tokens, tokens→AST, AST→typed AST, etc.
- **Test names describe the scenario:** `testWhenExpressionExhaustiveCheck`, not `testWhen1`
- **One assertion per behavior** where practical

```swift
// Good: clear, focused test
func testNullSafetyRejectsMethodOnNullable() {
    let diags = typeCheck("val s: String? = null; s.length")
    XCTAssert(diags.hasError(containing: "cannot call"))
}

// Bad: vague, testing too much
func testTypes() {
    // 50 assertions in one test
}
```

## Project Structure Guidelines

### Adding a New Compiler Phase

1. Create a new file in `Sources/RockitKit/` (e.g., `NewPhase.swift`)
2. Define the public API as a class or struct
3. Add tests in `Tests/RockitKitTests/NewPhaseTests.swift`
4. Wire it into the pipeline in `main.swift`

### Adding a New AST Node

When adding a new AST node type, update ALL of these files:

1. `AST.swift` — node definition
2. `Parser.swift` — parsing logic
3. `TypeChecker.swift` — type checking (both gather and check passes)
4. `MIRLowering.swift` — MIR lowering
5. `CodeGen.swift` — bytecode generation
6. `LLVMCodeGen.swift` — LLVM IR generation
7. Add tests for each phase

### Adding a New Builtin Function

1. Add the function to `BuiltinFunctions.swift`
2. Register it in the builtin registry
3. Add cross-platform implementation (`#if canImport(...)` for macOS vs Linux)
4. Add tests

### Adding a New LSP Feature

1. Create a provider in `Sources/RockitLSP/` (e.g., `NewFeatureProvider.swift`)
2. Register the capability in `LSPServer.swift`
3. Wire the handler in the message router
4. Test with an LSP client

## Building and Testing

```bash
# Build
swift build                    # Debug
swift build -c release         # Release

# Test
swift test                     # All tests
swift test --filter LexerTests # Specific test file
swift test --verbose           # Verbose output

# Compile Stage 1
.build/release/rockit build-native self-hosted-rockit/command.rok

# Run a Rockit file
.build/release/rockit run examples/hello.rok
```

## Pull Request Checklist

Before submitting a PR:

- [ ] All 542 existing tests pass (`swift test`)
- [ ] New tests added for new functionality
- [ ] No compiler warnings (`swift build 2>&1 | grep warning` should be empty)
- [ ] Code follows the coding standards above
- [ ] Commit messages are clear and descriptive
- [ ] PR description explains the change and motivation
- [ ] If modifying codegen: verify Stage 1 compilation still works

## Common Pitfalls

### Stage 1 Compatibility

Changes to Stage 0 (Swift compiler) must not break Stage 1 compilation. If you modify the bytecode format, LLVM IR generation, or runtime interface, verify that `command.rok` still compiles:

```bash
swift build -c release
.build/release/rockit build-native self-hosted-rockit/command.rok
self-hosted-rockit/command version
```

### Cross-Platform Code

Always use conditional compilation for platform-specific code:

```swift
#if canImport(CryptoKit)
// macOS path
#else
// Linux path (using swift-crypto or COpenSSL)
#endif
```

Never use `#if os(macOS)` for framework availability — use `canImport` instead, as it's more precise and forward-compatible.

### Memory in CI

CI containers have limited memory. Avoid patterns that increase memory usage:
- Don't keep both debug and release builds (`rm -rf .build/debug` before release)
- Avoid very large test inputs
- Be mindful of string retention in the VM heap during tests
