// VMTests.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import XCTest
@testable import RockitKit

final class VMTests: XCTestCase {

    // MARK: - Helpers

    /// Full pipeline: source → lex → parse → type check → lower → optimize → codegen → BytecodeModule
    private func compile(_ source: String) -> BytecodeModule {
        let diagnostics = DiagnosticEngine()
        let lexer = Lexer(source: source, fileName: "test.rok", diagnostics: diagnostics)
        let tokens = lexer.tokenize()
        let parser = Parser(tokens: tokens, diagnostics: diagnostics)
        let ast = parser.parse()
        let checker = TypeChecker(ast: ast, diagnostics: diagnostics)
        let result = checker.check()
        let lowering = MIRLowering(typeCheckResult: result)
        let module = lowering.lower()
        let optimizer = MIROptimizer()
        let optimized = optimizer.optimize(module)
        let codeGen = CodeGen()
        return codeGen.generate(optimized)
    }

    /// Compile and run, capturing printed output.
    private func runCapturing(_ source: String) throws -> [String] {
        let module = compile(source)
        var output: [String] = []
        let builtins = BuiltinRegistry()
        builtins.register(name: "println") { args in
            output.append(args.map { $0.description }.joined(separator: " "))
            return .unit
        }
        builtins.register(name: "print") { args in
            output.append(args.map { $0.description }.joined(separator: " "))
            return .unit
        }
        let vmWithCapture = VM(module: module, builtins: builtins)
        try vmWithCapture.run()
        return output
    }

    /// Compile and run using the scheduler-driven concurrent execution mode.
    private func runConcurrentCapturing(_ source: String) throws -> [String] {
        let module = compile(source)
        var output: [String] = []
        let builtins = BuiltinRegistry()
        builtins.register(name: "println") { args in
            output.append(args.map { $0.description }.joined(separator: " "))
            return .unit
        }
        builtins.register(name: "print") { args in
            output.append(args.map { $0.description }.joined(separator: " "))
            return .unit
        }
        let vmWithCapture = VM(module: module, builtins: builtins)
        try vmWithCapture.runConcurrent()
        return output
    }

    /// Compile and run, expecting no errors.
    private func runSuccessfully(_ source: String) throws {
        let module = compile(source)
        let vm = VM(module: module)
        try vm.run()
    }

    // MARK: - Value Tests

    func testValueDescription() {
        XCTAssertEqual(Value.int(42).description, "42")
        XCTAssertEqual(Value.float(3.14).description, "3.14")
        XCTAssertEqual(Value.bool(true).description, "true")
        XCTAssertEqual(Value.bool(false).description, "false")
        XCTAssertEqual(Value.string("hello").description, "hello")
        XCTAssertEqual(Value.null.description, "null")
        XCTAssertEqual(Value.unit.description, "()")
    }

    func testValueTypeName() {
        XCTAssertEqual(Value.int(0).typeName, "Int")
        XCTAssertEqual(Value.float(0).typeName, "Float64")
        XCTAssertEqual(Value.bool(true).typeName, "Bool")
        XCTAssertEqual(Value.string("").typeName, "String")
        XCTAssertEqual(Value.null.typeName, "Nothing")
    }

    func testValueTruthy() {
        XCTAssertTrue(Value.bool(true).isTruthy)
        XCTAssertFalse(Value.bool(false).isTruthy)
        XCTAssertFalse(Value.null.isTruthy)
        XCTAssertTrue(Value.int(1).isTruthy)
        XCTAssertFalse(Value.int(0).isTruthy)
        XCTAssertTrue(Value.string("x").isTruthy)
    }

    func testValueEquality() {
        XCTAssertEqual(Value.int(42), Value.int(42))
        XCTAssertNotEqual(Value.int(42), Value.int(43))
        XCTAssertEqual(Value.string("hi"), Value.string("hi"))
        XCTAssertEqual(Value.null, Value.null)
        XCTAssertNotEqual(Value.int(0), Value.bool(false))
    }

    // MARK: - BytecodeLoader Tests

    func testLoaderRoundTrip() throws {
        let module = compile("fun main(): Unit { val x: Int = 42 }")
        let bytes = CodeGen.serialize(module)
        let loaded = try BytecodeLoader.load(bytes: bytes)

        XCTAssertEqual(loaded.constantPool.count, module.constantPool.count)
        XCTAssertEqual(loaded.functions.count, module.functions.count)
        XCTAssertEqual(loaded.globals.count, module.globals.count)
        XCTAssertEqual(loaded.types.count, module.types.count)
    }

    func testLoaderInvalidMagic() {
        let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00]
        XCTAssertThrowsError(try BytecodeLoader.load(bytes: bytes))
    }

    func testLoaderTooSmall() {
        let bytes: [UInt8] = [0x4D, 0x4F]
        XCTAssertThrowsError(try BytecodeLoader.load(bytes: bytes))
    }

    func testLoaderFunctionBytecodePreserved() throws {
        let module = compile("fun main(): Unit { val x: Int = 42 }")
        let bytes = CodeGen.serialize(module)
        let loaded = try BytecodeLoader.load(bytes: bytes)

        let origFunc = module.functions.first!
        let loadedFunc = loaded.functions.first!
        XCTAssertEqual(origFunc.bytecode, loadedFunc.bytecode)
        XCTAssertEqual(origFunc.parameterCount, loadedFunc.parameterCount)
        XCTAssertEqual(origFunc.registerCount, loadedFunc.registerCount)
    }

    func testLoaderConstantPoolValues() throws {
        let module = compile("""
        fun main(): Unit {
            println("hello")
        }
        """)
        let bytes = CodeGen.serialize(module)
        let loaded = try BytecodeLoader.load(bytes: bytes)

        let hasHello = loaded.constantPool.contains { $0.value == "hello" }
        XCTAssert(hasHello, "Expected 'hello' in constant pool")
    }

    // MARK: - VM Error Tests

    func testVMErrorDescription() {
        let err = VMError.divisionByZero
        XCTAssert(err.description.contains("division by zero"))

        let err2 = VMError.nullPointerAccess(context: "test")
        XCTAssert(err2.description.contains("null"))

        let err3 = VMError.stackOverflow(depth: 1024)
        XCTAssert(err3.description.contains("1024"))
    }

    func testStackTrace() {
        let trace = StackTrace(
            error: .divisionByZero,
            frames: [
                StackTraceFrame(functionName: "main", bytecodeOffset: 10),
                StackTraceFrame(functionName: "add", bytecodeOffset: 5)
            ]
        )
        XCTAssert(trace.description.contains("main"))
        XCTAssert(trace.description.contains("add"))
        XCTAssert(trace.description.contains("division by zero"))
    }

    // MARK: - End-to-End Execution Tests

    func testRunEmptyMain() throws {
        try runSuccessfully("fun main(): Unit { }")
    }

    func testRunConstantAssignment() throws {
        try runSuccessfully("fun main(): Unit { val x: Int = 42 }")
    }

    func testRunPrintln() throws {
        let output = try runCapturing("""
        fun main(): Unit {
            println("hello world")
        }
        """)
        XCTAssertEqual(output, ["hello world"])
    }

    func testRunPrintlnInt() throws {
        let output = try runCapturing("""
        fun main(): Unit {
            println(42)
        }
        """)
        XCTAssertEqual(output.first, "42")
    }

    func testRunArithmetic() throws {
        // Constant folding may fold 2+3 to 5, but the result should still be correct
        try runSuccessfully("""
        fun main(): Unit {
            val x: Int = 2 + 3
        }
        """)
    }

    func testRunBooleanLogic() throws {
        try runSuccessfully("""
        fun main(): Unit {
            val x: Bool = true
            val y: Bool = false
        }
        """)
    }

    func testRunIfElse() throws {
        let output = try runCapturing("""
        fun main(): Unit {
            val x: Bool = true
            if (x) {
                println("yes")
            } else {
                println("no")
            }
        }
        """)
        XCTAssert(output.contains("yes"))
    }

    func testRunWhileLoop() throws {
        try runSuccessfully("""
        fun main(): Unit {
            var i: Int = 0
            while (i < 5) {
                i = i + 1
            }
        }
        """)
    }

    func testRunFunctionCall() throws {
        let output = try runCapturing("""
        fun greet(): Unit {
            println("hi")
        }
        fun main(): Unit {
            greet()
        }
        """)
        XCTAssertEqual(output, ["hi"])
    }

    func testRunFunctionWithArgs() throws {
        try runSuccessfully("""
        fun add(a: Int, b: Int): Int {
            return a
        }
        fun main(): Unit {
            val x: Int = add(1, 2)
        }
        """)
    }

    func testRunClassConstruction() throws {
        try runSuccessfully("""
        class Point(val x: Int, val y: Int)
        fun main(): Unit {
            val p: Point = Point(1, 2)
        }
        """)
    }

    func testRunFieldAccess() throws {
        try runSuccessfully("""
        class User(val name: String)
        fun main(): Unit {
            val u: User = User("Alice")
            val n: String = u.name
        }
        """)
    }

    func testRunNullCheck() throws {
        try runSuccessfully("""
        fun main(): Unit {
            val x: String? = null
        }
        """)
    }

    func testRunStringInterpolation() throws {
        try runSuccessfully("""
        fun main(): Unit {
            val name: String = "world"
            val msg: String = "hello"
        }
        """)
    }

    func testRunGlobal() throws {
        try runSuccessfully("""
        val VERSION: String = "1.0"
        fun main(): Unit { }
        """)
    }

    func testRunMultipleFunctions() throws {
        try runSuccessfully("""
        fun helper(): Unit { }
        fun main(): Unit {
            helper()
        }
        """)
    }

    // MARK: - RuntimeConfig Tests

    func testDefaultConfig() {
        let config = RuntimeConfig.default
        XCTAssertEqual(config.maxCallStackDepth, 1024)
        XCTAssertEqual(config.maxHeapObjects, 1_000_000)
        XCTAssertFalse(config.traceExecution)
        XCTAssertFalse(config.gcStats)
    }

    func testCustomConfig() {
        let config = RuntimeConfig(maxCallStackDepth: 512, traceExecution: true)
        XCTAssertEqual(config.maxCallStackDepth, 512)
        XCTAssertTrue(config.traceExecution)
    }

    // MARK: - Builtin Registry Tests

    func testBuiltinRegistration() {
        let registry = BuiltinRegistry()
        XCTAssertTrue(registry.isBuiltin("println"))
        XCTAssertTrue(registry.isBuiltin("print"))
        XCTAssertTrue(registry.isBuiltin("toString"))
        XCTAssertFalse(registry.isBuiltin("nonexistent"))
    }

    func testBuiltinToString() throws {
        let registry = BuiltinRegistry()
        let fn = registry.lookup("toString")!
        let result = try fn([.int(42)])
        XCTAssertEqual(result, .string("42"))
    }

    func testBuiltinStringLength() throws {
        let registry = BuiltinRegistry()
        let fn = registry.lookup("stringLength")!
        let result = try fn([.string("hello")])
        XCTAssertEqual(result, .int(5))
    }

    func testBuiltinTypeOf() throws {
        let registry = BuiltinRegistry()
        let fn = registry.lookup("typeOf")!
        XCTAssertEqual(try fn([.int(1)]), .string("Int"))
        XCTAssertEqual(try fn([.string("")]), .string("String"))
        XCTAssertEqual(try fn([.null]), .string("Nothing"))
    }

    func testBuiltinAbs() throws {
        let registry = BuiltinRegistry()
        let fn = registry.lookup("abs")!
        XCTAssertEqual(try fn([.int(-5)]), .int(5))
        XCTAssertEqual(try fn([.int(5)]), .int(5))
        XCTAssertEqual(try fn([.float(-3.14)]), .float(3.14))
    }

    func testBuiltinMinMax() throws {
        let registry = BuiltinRegistry()
        let minFn = registry.lookup("min")!
        let maxFn = registry.lookup("max")!
        XCTAssertEqual(try minFn([.int(3), .int(7)]), .int(3))
        XCTAssertEqual(try maxFn([.int(3), .int(7)]), .int(7))
    }

    // MARK: - Serialization Round-Trip via Loader

    func testSerializeLoadExecute() throws {
        let module = compile("""
        fun main(): Unit {
            val x: Int = 42
        }
        """)
        let bytes = CodeGen.serialize(module)
        let loaded = try BytecodeLoader.load(bytes: bytes)
        let vm = VM(module: loaded)
        try vm.run()
    }

    // MARK: - Trace Mode

    func testTraceMode() throws {
        let module = compile("fun main(): Unit { val x: Int = 42 }")
        var traceOutput: [String] = []
        let config = RuntimeConfig(traceExecution: true)
        let builtins = BuiltinRegistry()
        let vm = VM(module: module, config: config, builtins: builtins)
        vm.outputCapture = { traceOutput.append($0) }
        try vm.run()
        // Trace should have produced some output
        XCTAssert(traceOutput.count > 0, "Expected trace output")
    }

    // MARK: - Error Handling

    func testUnknownFunctionError() {
        let module = BytecodeModule(constantPool: [], globals: [], types: [], functions: [])
        let vm = VM(module: module)
        XCTAssertThrowsError(try vm.run()) { error in
            XCTAssert("\(error)".contains("main"), "Expected error about missing main")
        }
    }

    // MARK: - Enum When Matching (End-to-End)

    func testEnumWhenMatching() throws {
        let output = try runCapturing("""
        enum class Color { RED, GREEN, BLUE }
        fun describe(c: Color): String {
            when (c) {
                Color.RED -> { return "red" }
                Color.GREEN -> { return "green" }
                Color.BLUE -> { return "blue" }
            }
            return "unknown"
        }
        fun main(): Unit {
            val r: Color = Color.RED
            val g: Color = Color.GREEN
            val b: Color = Color.BLUE
            println(describe(r))
            println(describe(g))
            println(describe(b))
        }
        """)
        XCTAssertEqual(output, ["red", "green", "blue"])
    }

    func testEnumGlobalInitialization() throws {
        // Verify that enum globals are properly initialized (not left as null)
        let output = try runCapturing("""
        enum class Direction { NORTH, SOUTH, EAST, WEST }
        fun main(): Unit {
            val d: Direction = Direction.NORTH
            println("ok")
        }
        """)
        XCTAssertEqual(output, ["ok"])
    }

    func testEnumWhenWithElse() throws {
        let output = try runCapturing("""
        enum class Size { SMALL, MEDIUM, LARGE }
        fun label(s: Size): String {
            when (s) {
                Size.SMALL -> { return "S" }
                else -> { return "other" }
            }
            return "?"
        }
        fun main(): Unit {
            println(label(Size.SMALL))
            println(label(Size.LARGE))
        }
        """)
        XCTAssertEqual(output, ["S", "other"])
    }

    // MARK: - Sealed Class When Matching (End-to-End)

    func testSealedClassWhenMatching() throws {
        let output = try runCapturing("""
        sealed class Shape
        class Circle(val radius: Int) : Shape
        class Rect(val width: Int, val height: Int) : Shape

        fun describe(s: Shape): String {
            when (s) {
                is Circle -> { return "circle" }
                is Rect -> { return "rect" }
            }
            return "unknown"
        }
        fun main(): Unit {
            val c: Shape = Circle(5)
            val r: Shape = Rect(3, 4)
            println(describe(c))
            println(describe(r))
        }
        """)
        XCTAssertEqual(output, ["circle", "rect"])
    }

    // MARK: - Global Val Initialization

    func testGlobalValInitialization() throws {
        let output = try runCapturing("""
        val GREETING: String = "hello"
        fun main(): Unit {
            println(GREETING)
        }
        """)
        XCTAssertEqual(output, ["hello"])
    }

    func testGlobalValIntInitialization() throws {
        let output = try runCapturing("""
        val MAGIC: Int = 42
        fun main(): Unit {
            println(MAGIC)
        }
        """)
        XCTAssertEqual(output, ["42"])
    }

    // MARK: - When as Expression (Return Value)

    func testWhenAsExpressionInt() throws {
        let output = try runCapturing("""
        fun label(x: Int): String {
            when (x) {
                1 -> { return "one" }
                2 -> { return "two" }
                else -> { return "other" }
            }
            return "?"
        }
        fun main(): Unit {
            println(label(1))
            println(label(2))
            println(label(3))
        }
        """)
        XCTAssertEqual(output, ["one", "two", "other"])
    }

    func testEnumMultipleWhenCalls() throws {
        // Verify enum matching works across multiple function calls
        let output = try runCapturing("""
        enum class Op { ADD, SUB, MUL }
        fun name(op: Op): String {
            when (op) {
                Op.ADD -> { return "add" }
                Op.SUB -> { return "sub" }
                Op.MUL -> { return "mul" }
            }
            return "?"
        }
        fun main(): Unit {
            println(name(Op.ADD))
            println(name(Op.SUB))
            println(name(Op.MUL))
            println(name(Op.ADD))
        }
        """)
        XCTAssertEqual(output, ["add", "sub", "mul", "add"])
    }

    func testFunctionWithMultipleParams() throws {
        // Ensure parameter passing works correctly for multiple params
        let output = try runCapturing("""
        fun add(a: Int, b: Int): Int {
            return a + b
        }
        fun main(): Unit {
            println(add(3, 4))
        }
        """)
        XCTAssertEqual(output, ["7"])
    }

    // MARK: - For Loop Tests

    func testForLoopRangeInclusive() throws {
        let output = try runCapturing("""
        fun main(): Unit {
            var sum: Int = 0
            for (i in 1..5) {
                sum = sum + i
            }
            println(sum)
        }
        """)
        XCTAssertEqual(output, ["15"])  // 1+2+3+4+5 = 15
    }

    func testForLoopRangeExclusive() throws {
        let output = try runCapturing("""
        fun main(): Unit {
            var sum: Int = 0
            for (i in 0..<5) {
                sum = sum + i
            }
            println(sum)
        }
        """)
        XCTAssertEqual(output, ["10"])  // 0+1+2+3+4 = 10
    }

    func testForLoopRangePrint() throws {
        let output = try runCapturing("""
        fun main(): Unit {
            for (i in 1..3) {
                println(i)
            }
        }
        """)
        XCTAssertEqual(output, ["1", "2", "3"])
    }

    func testForLoopNested() throws {
        let output = try runCapturing("""
        fun main(): Unit {
            var sum: Int = 0
            for (i in 1..3) {
                for (j in 1..3) {
                    sum = sum + i * j
                }
            }
            println(sum)
        }
        """)
        // (1*1+1*2+1*3) + (2*1+2*2+2*3) + (3*1+3*2+3*3) = 6+12+18 = 36
        XCTAssertEqual(output, ["36"])
    }

    // MARK: - String Interpolation Tests

    func testStringInterpolation() throws {
        let output = try runCapturing("""
        fun main(): Unit {
            val name: String = "World"
            println("Hello, ${name}!")
        }
        """)
        XCTAssertEqual(output, ["Hello, World!"])
    }

    func testStringInterpolationExpression() throws {
        let output = try runCapturing("""
        fun main(): Unit {
            val a: Int = 3
            val b: Int = 4
            println("${a} + ${b} = ${a + b}")
        }
        """)
        XCTAssertEqual(output, ["3 + 4 = 7"])
    }

    // MARK: - Lambda Tests

    func testLambdaCallDirect() throws {
        let output = try runCapturing("""
        fun main(): Unit {
            val f = { x: Int -> x + 1 }
            println(f(5))
        }
        """)
        XCTAssertEqual(output, ["6"])
    }

    func testLambdaPassToFunction() throws {
        let output = try runCapturing("""
        fun apply(f: (Int) -> Int, x: Int): Int {
            return f(x)
        }
        fun main(): Unit {
            println(apply({ x: Int -> x * 2 }, 3))
        }
        """)
        XCTAssertEqual(output, ["6"])
    }

    func testLambdaNoParams() throws {
        let output = try runCapturing("""
        fun main(): Unit {
            val f = { 42 }
            println(f())
        }
        """)
        XCTAssertEqual(output, ["42"])
    }

    // MARK: - Generics Tests

    func testGenericFunctionInferred() throws {
        // Generic function with type inference (no explicit type args)
        let output = try runCapturing("""
        fun identity<T>(x: T): T {
            return x
        }
        fun main(): Unit {
            println(identity(42))
            println(identity("hello"))
        }
        """)
        XCTAssertEqual(output, ["42", "hello"])
    }

    func testGenericDataClass() throws {
        // Generic data class instantiation
        let output = try runCapturing("""
        data class Box<T>(val value: T)
        fun main(): Unit {
            val b = Box(42)
            println(b.value)
        }
        """)
        XCTAssertEqual(output, ["42"])
    }

    func testGenericMultipleTypeParams() throws {
        // Multiple type parameters
        let output = try runCapturing("""
        fun first<A, B>(a: A, b: B): A {
            return a
        }
        fun main(): Unit {
            println(first(1, "hello"))
        }
        """)
        XCTAssertEqual(output, ["1"])
    }

    // MARK: - Interface Tests

    func testInterfaceImplementation() throws {
        // Class implements interface and method is called
        let output = try runCapturing("""
        interface Greeter {
            fun greet(): String
        }
        class EnglishGreeter : Greeter {
            fun greet(): String {
                return "Hello"
            }
        }
        fun main(): Unit {
            val g = EnglishGreeter()
            println(g.greet())
        }
        """)
        XCTAssertEqual(output, ["Hello"])
    }

    func testInterfaceMissingMethod() throws {
        // Class omits required method → should produce type error
        let diagnostics = DiagnosticEngine()
        let source = """
        interface Speaker {
            fun speak(): String
        }
        class Mute : Speaker {
        }
        fun main(): Unit {
        }
        """
        let lexer = Lexer(source: source, fileName: "test.rok", diagnostics: diagnostics)
        let tokens = lexer.tokenize()
        let parser = Parser(tokens: tokens, diagnostics: diagnostics)
        let ast = parser.parse()
        let checker = TypeChecker(ast: ast, diagnostics: diagnostics)
        _ = checker.check()
        XCTAssertTrue(diagnostics.hasErrors, "Should report missing interface method")
    }

    func testInterfacePolymorphicDispatch() throws {
        // Different classes implementing same interface, dispatched by runtime type
        let output = try runCapturing("""
        interface Animal {
            fun sound(): String
        }
        class Dog : Animal {
            fun sound(): String {
                return "Woof"
            }
        }
        class Cat : Animal {
            fun sound(): String {
                return "Meow"
            }
        }
        fun makeSound(a: Animal): Unit {
            println(a.sound())
        }
        fun main(): Unit {
            makeSound(Dog())
            makeSound(Cat())
        }
        """)
        XCTAssertEqual(output, ["Woof", "Meow"])
    }

    // MARK: - Structured Concurrency Tests

    func testAwaitCallReturnsValue() throws {
        let output = try runCapturing("""
        suspend fun compute(): Int {
            return 42
        }
        suspend fun main(): Unit {
            val result = await compute()
            println(result)
        }
        """)
        XCTAssertEqual(output, ["42"])
    }

    func testConcurrentBlockExecutesAllTasks() throws {
        let output = try runCapturing("""
        suspend fun taskA(): Int {
            return 1
        }
        suspend fun taskB(): Int {
            return 2
        }
        suspend fun main(): Unit {
            concurrent {
                val a = await taskA()
                val b = await taskB()
                println(a)
                println(b)
            }
        }
        """)
        XCTAssertEqual(output, ["1", "2"])
    }

    func testAwaitPassthroughForNonSuspend() throws {
        let output = try runCapturing("""
        suspend fun double(x: Int): Int {
            return x * 2
        }
        suspend fun main(): Unit {
            val result = await double(21)
            println(result)
        }
        """)
        XCTAssertEqual(output, ["42"])
    }

    // MARK: - Scheduled Concurrency Tests (runConcurrent)

    func testScheduledAwaitCall() throws {
        let output = try runConcurrentCapturing("""
        suspend fun compute(): Int {
            return 42
        }
        suspend fun main(): Unit {
            val result = await compute()
            println(result)
        }
        """)
        XCTAssertEqual(output, ["42"])
    }

    func testScheduledAwaitChain() throws {
        let output = try runConcurrentCapturing("""
        suspend fun inner(): Int {
            return 10
        }
        suspend fun middle(): Int {
            val x = await inner()
            return x * 2
        }
        suspend fun main(): Unit {
            val result = await middle()
            println(result)
        }
        """)
        XCTAssertEqual(output, ["20"])
    }

    func testScheduledAwaitMultiple() throws {
        let output = try runConcurrentCapturing("""
        suspend fun fetchA(): String {
            return "hello"
        }
        suspend fun fetchB(): String {
            return "world"
        }
        suspend fun main(): Unit {
            val a = await fetchA()
            val b = await fetchB()
            println(a)
            println(b)
        }
        """)
        XCTAssertEqual(output, ["hello", "world"])
    }

    // MARK: - Concurrent Block Tests (runConcurrent)

    func testConcurrentBlockInterleaving() throws {
        let output = try runConcurrentCapturing("""
        suspend fun taskA(): Int {
            return 10
        }
        suspend fun taskB(): Int {
            return 20
        }
        suspend fun main(): Unit {
            concurrent {
                val a = await taskA()
                println(a)
                val b = await taskB()
                println(b)
            }
            println("done")
        }
        """)
        XCTAssertTrue(output.contains("10"), "taskA result should appear")
        XCTAssertTrue(output.contains("20"), "taskB result should appear")
        XCTAssertEqual(output.last, "done", "done should be printed after concurrent block")
    }

    func testConcurrentBlockJoin() throws {
        let output = try runConcurrentCapturing("""
        suspend fun slow(): String {
            return "finished"
        }
        suspend fun main(): Unit {
            concurrent {
                val r = await slow()
                println(r)
            }
            println("after")
        }
        """)
        XCTAssertEqual(output, ["finished", "after"])
    }

    // MARK: - Actor Message Passing Tests (runConcurrent)

    func testActorMethodCall() throws {
        let output = try runConcurrentCapturing("""
        actor Counter {
            var count: Int = 0
            fun increment(): Unit {
                count = count + 1
            }
            fun getCount(): Int {
                return count
            }
        }
        suspend fun main(): Unit {
            val c = Counter()
            c.increment()
            c.increment()
            c.increment()
            println(c.getCount())
        }
        """)
        XCTAssertEqual(output, ["3"])
    }

    func testActorSerialExecution() throws {
        let output = try runConcurrentCapturing("""
        actor Greeter {
            var greeting: String = "hi"
            fun setGreeting(g: String): Unit {
                greeting = g
            }
            fun greet(): String {
                return greeting
            }
        }
        suspend fun main(): Unit {
            val g = Greeter()
            g.setGreeting("hello")
            println(g.greet())
        }
        """)
        XCTAssertEqual(output, ["hello"])
    }

    // MARK: - Error Propagation Tests (runConcurrent)

    func testChildFailurePropagation() throws {
        // A child that throws should propagate the error to the parent
        let module = compile("""
        suspend fun failing(): Int {
            throw "child error"
        }
        suspend fun main(): Unit {
            val r = await failing()
            println(r)
        }
        """)
        let builtins = BuiltinRegistry()
        builtins.register(name: "println") { _ in .unit }
        let vm = VM(module: module, builtins: builtins)
        XCTAssertThrowsError(try vm.runConcurrent())
    }

    func testConcurrentModeNonAsyncStillWorks() throws {
        // Programs without async should still work in runConcurrent mode
        let output = try runConcurrentCapturing("""
        fun main(): Unit {
            println("sync")
        }
        """)
        XCTAssertEqual(output, ["sync"])
    }
}
