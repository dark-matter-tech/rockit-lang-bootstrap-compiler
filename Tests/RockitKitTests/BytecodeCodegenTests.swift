// BytecodeCodegenTests.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import XCTest
@testable import RockitKit

final class BytecodeCodegenTests: XCTestCase {

    // MARK: - Helpers

    /// Full pipeline: source → lex → parse → type check → lower → optimize → codegen
    private func codegen(_ source: String) -> BytecodeModule {
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

    /// Find a bytecode function by looking up its name in the constant pool.
    private func findFunction(_ module: BytecodeModule, named name: String) -> BytecodeFunction? {
        return module.functions.first { f in
            Int(f.nameIndex) < module.constantPool.count &&
            module.constantPool[Int(f.nameIndex)].value == name
        }
    }

    /// Get the disassembly of a module.
    private func disassemble(_ module: BytecodeModule) -> String {
        return CodeGen.disassemble(module)
    }

    /// Check if a function's bytecode contains a given opcode.
    private func containsOpcode(_ f: BytecodeFunction, _ op: Opcode) -> Bool {
        return f.bytecode.contains(op.rawValue)
    }

    // MARK: - Constant Pool Tests

    func testConstantPoolDeduplication() {
        let pool = ConstantPoolBuilder()
        let idx1 = pool.intern("hello", kind: .string)
        let idx2 = pool.intern("hello", kind: .string)
        XCTAssertEqual(idx1, idx2, "Same string should return same index")
        XCTAssertEqual(pool.count, 1, "Pool should have 1 entry after dedup")
    }

    func testConstantPoolDifferentKinds() {
        let pool = ConstantPoolBuilder()
        let idx1 = pool.intern("name", kind: .string)
        let idx2 = pool.intern("name", kind: .fieldName)
        XCTAssertNotEqual(idx1, idx2, "Different kinds with same value should get different indices")
        XCTAssertEqual(pool.count, 2)
    }

    func testConstantPoolMultipleStrings() {
        let pool = ConstantPoolBuilder()
        let idx1 = pool.intern("hello", kind: .string)
        let idx2 = pool.intern("world", kind: .string)
        XCTAssertEqual(idx1, 0)
        XCTAssertEqual(idx2, 1)
        XCTAssertEqual(pool.count, 2)
    }

    // MARK: - Emitter Tests

    func testEmitterUInt16() {
        let emitter = BytecodeEmitter()
        emitter.emitUInt16(0x1234)
        XCTAssertEqual(emitter.bytes, [0x12, 0x34])
    }

    func testEmitterUInt32() {
        let emitter = BytecodeEmitter()
        emitter.emitUInt32(0x12345678)
        XCTAssertEqual(emitter.bytes, [0x12, 0x34, 0x56, 0x78])
    }

    func testEmitterInt64() {
        let emitter = BytecodeEmitter()
        emitter.emitInt64(42)
        XCTAssertEqual(emitter.count, 8)
        // 42 = 0x000000000000002A
        XCTAssertEqual(emitter.bytes[7], 0x2A)
        XCTAssertEqual(emitter.bytes[0], 0x00)
    }

    func testEmitterFloat64() {
        let emitter = BytecodeEmitter()
        emitter.emitFloat64(3.14)
        XCTAssertEqual(emitter.count, 8)
    }

    func testEmitterOpcode() {
        let emitter = BytecodeEmitter()
        emitter.emitOpcode(.constInt)
        XCTAssertEqual(emitter.bytes, [0x01])
    }

    // MARK: - Opcode Encoding Tests

    func testOpcodeValues() {
        XCTAssertEqual(Opcode.constInt.rawValue, 0x01)
        XCTAssertEqual(Opcode.add.rawValue, 0x20)
        XCTAssertEqual(Opcode.call.rawValue, 0x50)
        XCTAssertEqual(Opcode.ret.rawValue, 0xE0)
        XCTAssertEqual(Opcode.jump.rawValue, 0xE2)
        XCTAssertEqual(Opcode.branch.rawValue, 0xE3)
    }

    func testOpcodeDescriptions() {
        XCTAssertEqual(Opcode.constInt.description, "CONST_INT")
        XCTAssertEqual(Opcode.add.description, "ADD")
        XCTAssertEqual(Opcode.call.description, "CALL")
        XCTAssertEqual(Opcode.ret.description, "RET")
    }

    // MARK: - End-to-End Codegen Tests

    func testSimpleConstant() {
        let module = codegen("fun main(): Unit { val x: Int = 42 }")
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f, "Expected main function")
        XCTAssert(containsOpcode(f!, .constInt), "Expected CONST_INT opcode")
    }

    func testArithmeticFolded() {
        // 2 + 3 should be folded to 5 by the optimizer
        let module = codegen("fun main(): Unit { val x: Int = 2 + 3 }")
        let f = findFunction(module, named: "main")!
        // After optimization, the add should be folded — just a CONST_INT 5
        XCTAssert(containsOpcode(f, .constInt), "Expected CONST_INT for folded result")
    }

    func testFunctionCall() {
        let module = codegen("""
        fun main(): Unit {
            println("hello")
        }
        """)
        let f = findFunction(module, named: "main")!
        XCTAssert(containsOpcode(f, .call), "Expected CALL opcode")
        XCTAssert(containsOpcode(f, .constString), "Expected CONST_STRING for argument")
    }

    func testIfElse() {
        let module = codegen("""
        fun main(): Unit {
            val x: Bool = true
            if (x) {
                println("yes")
            } else {
                println("no")
            }
        }
        """)
        let f = findFunction(module, named: "main")!
        // Should have branch or jump opcodes for control flow
        let hasCF = containsOpcode(f, .branch) || containsOpcode(f, .jump)
        XCTAssert(hasCF, "Expected branch or jump opcodes for if/else")
    }

    func testWhileLoop() {
        let module = codegen("""
        fun main(): Unit {
            var i: Int = 0
            while (i < 10) {
                i = i + 1
            }
        }
        """)
        let f = findFunction(module, named: "main")!
        XCTAssert(containsOpcode(f, .branch), "Expected BRANCH opcode for while condition")
        XCTAssert(containsOpcode(f, .jump), "Expected JUMP opcode for while loop back-edge")
    }

    func testClassConstruction() {
        let module = codegen("""
        class Point(val x: Int, val y: Int)
        fun main(): Unit {
            val p: Point = Point(1, 2)
        }
        """)
        let f = findFunction(module, named: "main")!
        XCTAssert(containsOpcode(f, .newObject), "Expected NEW_OBJECT opcode")
        // Point type should be in the module
        let hasPointType = module.types.contains { t in
            Int(t.nameIndex) < module.constantPool.count &&
            module.constantPool[Int(t.nameIndex)].value == "Point"
        }
        XCTAssert(hasPointType, "Expected Point type declaration")
    }

    func testFieldAccess() {
        let module = codegen("""
        class User(val name: String)
        fun main(): Unit {
            val u: User = User("Alice")
            val n: String = u.name
        }
        """)
        let f = findFunction(module, named: "main")!
        XCTAssert(containsOpcode(f, .getField), "Expected GET_FIELD opcode")
    }

    func testNullSafety() {
        let module = codegen("""
        fun main(): Unit {
            val x: String? = null
            val y: String = x!!
        }
        """)
        let f = findFunction(module, named: "main")!
        XCTAssert(containsOpcode(f, .nullCheck), "Expected NULL_CHECK opcode")
    }

    func testMultipleFunctions() {
        let module = codegen("""
        fun add(a: Int, b: Int): Int {
            return a
        }
        fun main(): Unit {
            val x: Int = add(1, 2)
        }
        """)
        XCTAssertNotNil(findFunction(module, named: "main"))
        XCTAssertNotNil(findFunction(module, named: "add"))
        XCTAssertEqual(module.functions.count, 2)
        // add should have parameters
        let addFunc = findFunction(module, named: "add")!
        XCTAssertEqual(addFunc.parameterCount, 2)
    }

    func testRegisterCount() {
        let module = codegen("fun main(): Unit { val x: Int = 42 }")
        let f = findFunction(module, named: "main")!
        XCTAssert(f.registerCount > 0, "Expected non-zero register count")
    }

    func testGlobals() {
        let module = codegen("""
        val VERSION: String = "1.0"
        fun main(): Unit { }
        """)
        XCTAssert(module.globals.count >= 1, "Expected at least 1 global")
        let hasVersion = module.globals.contains { g in
            Int(g.nameIndex) < module.constantPool.count &&
            module.constantPool[Int(g.nameIndex)].value == "VERSION"
        }
        XCTAssert(hasVersion, "Expected VERSION global")
    }

    func testStringInterpolation() {
        let module = codegen("""
        fun main(): Unit {
            val name: String = "world"
            val msg: String = "hello ${name}!"
        }
        """)
        let f = findFunction(module, named: "main")!
        XCTAssert(containsOpcode(f, .stringConcat), "Expected STRING_CONCAT opcode")
    }

    // MARK: - Binary Serialization Tests

    func testSerializeMagicNumber() {
        let module = codegen("fun main(): Unit { }")
        let bytes = CodeGen.serialize(module)
        XCTAssertEqual(Array(bytes[0..<4]), [0x52, 0x4F, 0x4B, 0x54], "Expected ROKT magic")
    }

    func testSerializeVersion() {
        let module = codegen("fun main(): Unit { }")
        let bytes = CodeGen.serialize(module)
        // Version 1.0 → major=0x0001, minor=0x0000
        XCTAssertEqual(bytes[4], 0x00)
        XCTAssertEqual(bytes[5], 0x01)
        XCTAssertEqual(bytes[6], 0x00)
        XCTAssertEqual(bytes[7], 0x00)
    }

    func testSerializeNonEmpty() {
        let module = codegen("""
        fun main(): Unit {
            val x: Int = 42
            println("hello")
        }
        """)
        let bytes = CodeGen.serialize(module)
        XCTAssert(bytes.count > 8, "Serialized bytecode should be more than just header")
    }

    // MARK: - Disassembly Tests

    func testDisassembleContainsFunctionName() {
        let module = codegen("fun main(): Unit { val x: Int = 42 }")
        let text = disassemble(module)
        XCTAssert(text.contains("fun main"), "Disassembly should contain function name")
    }

    func testDisassembleContainsOpcodes() {
        let module = codegen("fun main(): Unit { val x: Int = 42 }")
        let text = disassemble(module)
        XCTAssert(text.contains("CONST_INT"), "Disassembly should contain CONST_INT")
    }

    func testDisassembleContainsConstantPool() {
        let module = codegen("""
        fun main(): Unit {
            println("hello")
        }
        """)
        let text = disassemble(module)
        XCTAssert(text.contains("Constant Pool"), "Disassembly should show constant pool")
        XCTAssert(text.contains("hello"), "Disassembly should show string constant")
    }

    // MARK: - Integration Tests

    func testComplexProgram() {
        let module = codegen("""
        val greeting: String = "Hello"

        class User(val name: String)

        fun greet(u: User): String {
            return u.name
        }

        fun main(): Unit {
            val u: User = User("Alice")
            val msg: String = greet(u)
            println(msg)
        }
        """)
        XCTAssertNotNil(findFunction(module, named: "main"))
        XCTAssertNotNil(findFunction(module, named: "greet"))
        XCTAssert(module.globals.count >= 1, "Expected greeting global")
        XCTAssert(module.types.count >= 1, "Expected User type")
        XCTAssert(module.constantPool.count > 0, "Expected non-empty constant pool")
        XCTAssert(module.totalBytecodeSize > 0, "Expected non-zero bytecode")
    }

    func testEmptyFunction() {
        let module = codegen("fun main(): Unit { }")
        let f = findFunction(module, named: "main")!
        // Should at least have a RET_VOID
        XCTAssert(containsOpcode(f, .retVoid), "Expected RET_VOID for empty function")
    }

    func testTypeDeclarations() {
        let module = codegen("""
        enum class Color {
            RED,
            GREEN,
            BLUE
        }
        fun main(): Unit {
            val c: Color = Color.RED
        }
        """)
        let hasColor = module.types.contains { t in
            Int(t.nameIndex) < module.constantPool.count &&
            module.constantPool[Int(t.nameIndex)].value == "Color"
        }
        XCTAssert(hasColor, "Expected Color type declaration")
    }

    func testReturnValue() {
        let module = codegen("""
        fun answer(): Int {
            return 42
        }
        fun main(): Unit {
            val x: Int = answer()
        }
        """)
        let f = findFunction(module, named: "answer")!
        XCTAssert(containsOpcode(f, .ret), "Expected RET opcode (with value)")
        XCTAssertEqual(f.returnTypeTag, .int, "Expected Int return type")
    }
}
