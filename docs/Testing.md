# Testing

The bootstrap compiler has 542 unit tests across 14 test files, plus integration tests using Rockit source files.

## Test Structure

```
Tests/RockitKitTests/
├── LexerTests.swift              Lexer tokenization tests
├── ParserTests.swift             Parser AST construction tests
├── TypeCheckerTests.swift        Type checking and inference tests
├── BytecodeCodegenTests.swift    MIR → bytecode tests
├── LLVMCodeGenTests.swift        AST → LLVM IR tests
├── VMTests.swift                 Bytecode VM execution tests
├── CollectionTests.swift         List, Map, Set operations
├── CoroutineTests.swift          Coroutine suspend/resume tests
├── ActorTests.swift              Actor mailbox dispatch tests
├── ARCTests.swift                Reference counting and memory tests
├── ImportResolverTests.swift     Module import resolution tests
├── DiagnosticTests.swift         Error reporting tests
├── OptimizerTests.swift          MIR optimization pass tests
└── IntegrationTests.swift        End-to-end compilation tests
```

## Running Tests

### All Tests

```bash
swift test
```

### Filtered Tests

```bash
# By test class
swift test --filter LexerTests
swift test --filter ParserTests
swift test --filter VMTests

# By specific test method
swift test --filter "LexerTests/testStringInterpolation"
swift test --filter "TypeCheckerTests/testNullSafety"

# Multiple filters
swift test --filter "LexerTests|ParserTests"
```

### Verbose Output

```bash
swift test --verbose
```

## Test Categories

### Lexer Tests

Verify that source text produces the correct token stream:

```swift
func testBasicTokens() {
    let tokens = Lexer("val x = 42").tokenize()
    XCTAssertEqual(tokens[0].type, .val)
    XCTAssertEqual(tokens[1].type, .identifier)
    XCTAssertEqual(tokens[1].lexeme, "x")
    XCTAssertEqual(tokens[2].type, .equals)
    XCTAssertEqual(tokens[3].type, .intLiteral)
    XCTAssertEqual(tokens[3].lexeme, "42")
}
```

Key areas tested:
- All 130+ token types
- String interpolation (`$name`, `${expr}`)
- Nestable block comments
- Number formats (decimal, hex, binary, underscores)
- Significant newlines
- Edge cases (empty strings, nested interpolation, Unicode)

### Parser Tests

Verify that token streams produce correct AST nodes:

```swift
func testFunctionDeclaration() {
    let ast = Parser(tokens).parse()
    guard case .funDecl(let decl) = ast.declarations[0] else {
        XCTFail("Expected function declaration")
        return
    }
    XCTAssertEqual(decl.name, "greet")
    XCTAssertEqual(decl.parameters.count, 1)
}
```

Key areas tested:
- All declaration types (fun, class, enum, interface, actor, view)
- Expression parsing and precedence
- Control flow (if, when, for, while)
- Lambda expressions
- Type annotations and generics
- Error recovery

### Type Checker Tests

Verify type inference, null safety, and semantic validation:

```swift
func testTypeInference() {
    let typed = typeCheck("val x = 42")
    XCTAssertEqual(typed.type(of: "x"), .int)
}

func testNullSafety() {
    // Should produce error: cannot call method on nullable type
    let diags = typeCheck("val s: String? = null; s.length")
    XCTAssert(diags.hasError)
}
```

Key areas tested:
- Type inference for val/var declarations
- Null safety enforcement
- Generic type resolution
- Sealed class exhaustive matching
- Suspend/await validation
- Actor isolation checks
- Overload resolution

### VM Tests

Verify end-to-end execution via bytecode:

```swift
func testArithmetic() {
    let output = runProgram("fun main() { println(2 + 3) }")
    XCTAssertEqual(output, "5\n")
}

func testClassInstantiation() {
    let output = runProgram("""
        class Dog(val name: String) {
            fun bark(): String = "Woof! I'm $name"
        }
        fun main() {
            val d = Dog("Rex")
            println(d.bark())
        }
    """)
    XCTAssertEqual(output, "Woof! I'm Rex\n")
}
```

Key areas tested:
- Arithmetic and logic operations
- String operations and interpolation
- Class instantiation and method calls
- Inheritance and polymorphism
- Collections (List, Map)
- Control flow execution
- Coroutine scheduling
- Actor message dispatch
- ARC memory management
- Builtin functions

### ARC Tests

Verify reference counting correctness:

```swift
func testObjectDeallocation() {
    let output = runProgram("""
        class Trackable() {
            fun finalize() { println("freed") }
        }
        fun main() {
            val t = Trackable()
            // t goes out of scope → finalize called
        }
    """)
    XCTAssertContains(output, "freed")
}
```

Key areas tested:
- Object allocation and deallocation
- Reference counting (retain/release)
- Weak references
- Cycle detection
- Write barrier correctness
- String literal immortality

### LLVM CodeGen Tests

Verify LLVM IR generation:

```swift
func testFunctionCodegen() {
    let ir = generateLLVMIR("fun add(a: Int, b: Int): Int = a + b")
    XCTAssertContains(ir, "define i64 @add(i64 %0, i64 %1)")
    XCTAssertContains(ir, "add i64")
}
```

Key areas tested:
- Function signatures and calling conventions
- Control flow (branches, phi nodes)
- String constants and global data
- ARC retain/release insertion
- CPS coroutine transform
- Polymorphic dispatch (vtables)

## Integration Tests

Integration tests compile and run complete `.rok` files from the `examples/` directory:

```
examples/
├── hello.rok                Basic hello world
├── test_classes.rok         Class features
├── test_enums.rok           Enum declarations
├── test_generics.rok        Generic types
├── test_concurrency.rok     Async/await, actors
├── test_collections.rok     List, Map operations
├── test_stdlib_json.rok     JSON parsing/encoding
├── test_stdlib_math.rok     Math functions
└── ... (48 files total)
```

### Running Integration Tests

```bash
# Via Stage 0 (bytecode VM)
.build/release/rockit run examples/hello.rok

# Via Stage 1 (native compilation)
self-hosted-rockit/command build-native examples/hello.rok -o /tmp/hello
/tmp/hello
```

### Probe Test Framework

Integration tests use the Probe testing framework (part of stdlib):

```rockit
import rockit.testing.probe

fun main() {
    assertEquals(2 + 2, 4)
    assertEqualsStr("hello", "hello")
    assertTrue(1 < 2)
    assertFalse(1 > 2)
    assertGreaterThan(5, 3)
    assertStringContains("hello world", "world")
}
```

### Test Schemes (fuel.toml)

The `fuel.toml` file defines test schemes for filtering:

```toml
[test.scheme.default]
include = ["*"]
exclude = ["advanced"]

[test.scheme.all]
include = ["*"]
```

The `advanced/` directory contains tests using freestanding-mode features (Ptr, alloc, unsafe) that require Stage 1 to compile — these are excluded from the default test scheme run by Stage 0.

## CI Testing

Tests run automatically on every push and PR:

- **GitHub Actions**: Ubuntu 22.04 (swift:5.10.1-jammy container)
- **Gitea Actions**: Same container

CI runs:
1. `swift test` — all 542 unit tests
2. Stage 1 compilation (Stage 0 compiles command.rok)
3. Integration tests via Stage 1
4. Bootstrap verification (release workflow only)

## Writing New Tests

### Unit Test

Add to the appropriate test file in `Tests/RockitKitTests/`:

```swift
func testMyNewFeature() throws {
    let source = """
        fun main() {
            val x = myNewFeature()
            println(x)
        }
    """
    let output = try runAndCapture(source)
    XCTAssertEqual(output, "expected output\n")
}
```

### Integration Test

Create a `.rok` file in `examples/` or `tests/`:

```rockit
import rockit.testing.probe

fun main() {
    // Test your feature
    val result = myFunction()
    assertEquals(result, expected)
}
```

Run it:
```bash
.build/release/rockit run tests/my_test.rok
```
