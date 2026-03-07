// MIRLoweringTests.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import XCTest
@testable import RockitKit

final class MIRLoweringTests: XCTestCase {

    // MARK: - Helpers

    /// Lex → parse → type check → lower → return MIRModule
    private func lower(_ source: String) -> MIRModule {
        let diagnostics = DiagnosticEngine()
        let lexer = Lexer(source: source, fileName: "test.rok", diagnostics: diagnostics)
        let tokens = lexer.tokenize()
        let parser = Parser(tokens: tokens, diagnostics: diagnostics)
        let ast = parser.parse()
        let checker = TypeChecker(ast: ast, diagnostics: diagnostics)
        let result = checker.check()
        let lowering = MIRLowering(typeCheckResult: result)
        return lowering.lower()
    }

    /// Lower and find a function by name
    private func findFunction(_ module: MIRModule, named name: String) -> MIRFunction? {
        return module.functions.first { $0.name == name }
    }

    /// Get all instructions from a function's entry block
    private func entryInstructions(_ func_: MIRFunction) -> [MIRInstruction] {
        guard let entry = func_.blocks.first else { return [] }
        return entry.instructions
    }

    /// Get the textual dump of a function's entry block instructions
    private func instructionTexts(_ func_: MIRFunction) -> [String] {
        return entryInstructions(func_).map { "\($0)" }
    }

    // MARK: - MIR Type Tests

    func testMIRTypeFromPrimitives() {
        XCTAssertEqual(MIRType.from(.int), .int)
        XCTAssertEqual(MIRType.from(.int32), .int32)
        XCTAssertEqual(MIRType.from(.int64), .int64)
        XCTAssertEqual(MIRType.from(.float), .float)
        XCTAssertEqual(MIRType.from(.float64), .float64)
        XCTAssertEqual(MIRType.from(.double), .double)
        XCTAssertEqual(MIRType.from(.bool), .bool)
        XCTAssertEqual(MIRType.from(.string), .string)
        XCTAssertEqual(MIRType.from(.unit), .unit)
        XCTAssertEqual(MIRType.from(.nothing), .nothing)
    }

    func testMIRTypeFromNullable() {
        XCTAssertEqual(MIRType.from(.nullable(.string)), .nullable(.string))
        XCTAssertEqual(MIRType.from(.nullable(.int)), .nullable(.int))
    }

    func testMIRTypeFromComposite() {
        XCTAssertEqual(MIRType.from(.classType(name: "User", typeArguments: [])), .reference("User"))
        XCTAssertEqual(MIRType.from(.enumType(name: "Color")), .reference("Color"))
        XCTAssertEqual(MIRType.from(.interfaceType(name: "Drawable", typeArguments: [])), .reference("Drawable"))
        XCTAssertEqual(MIRType.from(.actorType(name: "Counter")), .reference("Counter"))
    }

    func testMIRTypeFromFunction() {
        let funcType = MIRType.from(.function(parameterTypes: [.int, .string], returnType: .bool))
        XCTAssertEqual(funcType, .function([.int, .string], .bool))
    }

    func testMIRTypeDescription() {
        XCTAssertEqual(MIRType.int.description, "Int")
        XCTAssertEqual(MIRType.nullable(.string).description, "String?")
        XCTAssertEqual(MIRType.reference("User").description, "User")
        XCTAssertEqual(MIRType.function([.int], .bool).description, "(Int) -> Bool")
    }

    // MARK: - Instruction Description Tests

    func testInstructionDescriptions() {
        XCTAssert(MIRInstruction.constInt(dest: "%t0", value: 42).description.contains("const_int 42"))
        XCTAssert(MIRInstruction.constString(dest: "%t0", value: "hi").description.contains("const_string"))
        XCTAssert(MIRInstruction.add(dest: "%t2", lhs: "%t0", rhs: "%t1", type: .int).description.contains("add"))
        XCTAssert(MIRInstruction.call(dest: "%t0", function: "println", args: ["%t1"]).description.contains("call println"))
        XCTAssert(MIRInstruction.newObject(dest: "%t0", typeName: "User", args: ["%t1"]).description.contains("new User"))
    }

    func testTerminatorDescriptions() {
        XCTAssertEqual(MIRTerminator.ret(nil).description, "ret")
        XCTAssertEqual(MIRTerminator.ret("%t0").description, "ret %t0")
        XCTAssert(MIRTerminator.jump("label").description.contains("jump label"))
        XCTAssert(MIRTerminator.branch(condition: "%t0", thenLabel: "a", elseLabel: "b").description.contains("branch"))
    }

    // MARK: - Literal Lowering

    func testIntLiteral() {
        let module = lower("fun main(): Unit { val x: Int = 42 }")
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        XCTAssert(texts.contains { $0.contains("const_int 42") }, "Expected const_int 42, got: \(texts)")
    }

    func testFloatLiteral() {
        let module = lower("fun main(): Unit { val x: Double = 3.14 }")
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        XCTAssert(texts.contains { $0.contains("const_float 3.14") }, "Expected const_float, got: \(texts)")
    }

    func testStringLiteral() {
        let module = lower("fun main(): Unit { val x: String = \"hello\" }")
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        XCTAssert(texts.contains { $0.contains("const_string") }, "Expected const_string, got: \(texts)")
    }

    func testBoolLiteral() {
        let module = lower("fun main(): Unit { val x: Bool = true }")
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        XCTAssert(texts.contains { $0.contains("const_bool true") }, "Expected const_bool true, got: \(texts)")
    }

    func testNullLiteral() {
        let module = lower("fun main(): Unit { val x: String? = null }")
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        XCTAssert(texts.contains { $0.contains("const_null") }, "Expected const_null, got: \(texts)")
    }

    // MARK: - Arithmetic Lowering

    func testAddition() {
        let module = lower("fun main(): Unit { val x: Int = 1 + 2 }")
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        XCTAssert(texts.contains { $0.contains("add") }, "Expected add instruction, got: \(texts)")
    }

    func testSubtraction() {
        let module = lower("fun main(): Unit { val x: Int = 5 - 3 }")
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        XCTAssert(texts.contains { $0.contains("sub") }, "Expected sub instruction, got: \(texts)")
    }

    func testMultiplication() {
        let module = lower("fun main(): Unit { val x: Int = 4 * 5 }")
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        XCTAssert(texts.contains { $0.contains("mul") }, "Expected mul instruction, got: \(texts)")
    }

    func testDivision() {
        let module = lower("fun main(): Unit { val x: Int = 10 / 2 }")
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        XCTAssert(texts.contains { $0.contains("div") }, "Expected div instruction, got: \(texts)")
    }

    func testModulo() {
        let module = lower("fun main(): Unit { val x: Int = 10 % 3 }")
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        XCTAssert(texts.contains { $0.contains("mod") }, "Expected mod instruction, got: \(texts)")
    }

    // MARK: - Comparison Lowering

    func testComparisons() {
        let module = lower("""
        fun main(): Unit {
            val a: Bool = 1 == 2
            val b: Bool = 1 != 2
            val c: Bool = 1 < 2
            val d: Bool = 1 > 2
        }
        """)
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        XCTAssert(texts.contains { $0.contains("eq") }, "Expected eq")
        XCTAssert(texts.contains { $0.contains("neq") }, "Expected neq")
        XCTAssert(texts.contains { $0.contains("lt") }, "Expected lt")
        XCTAssert(texts.contains { $0.contains("gt") }, "Expected gt")
    }

    // MARK: - Logic Lowering

    func testLogicOperators() {
        let module = lower("""
        fun main(): Unit {
            val a: Bool = true && false
            val b: Bool = true || false
        }
        """)
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        // Short-circuit && and || use branch-based evaluation instead of and/or instructions
        let blockLabels = f!.blocks.map { $0.label }
        XCTAssert(blockLabels.contains { $0.contains("and.") }, "Expected and.rhs/and.merge blocks for short-circuit &&")
        XCTAssert(blockLabels.contains { $0.contains("or.") }, "Expected or.rhs/or.merge blocks for short-circuit ||")
    }

    // MARK: - Unary Operations

    func testNegation() {
        let module = lower("fun main(): Unit { val x: Int = -42 }")
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        XCTAssert(texts.contains { $0.contains("neg") }, "Expected neg instruction, got: \(texts)")
    }

    func testLogicalNot() {
        let module = lower("fun main(): Unit { val x: Bool = !true }")
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        XCTAssert(texts.contains { $0.contains("not") }, "Expected not instruction, got: \(texts)")
    }

    // MARK: - Variable Lowering

    func testValDeclaration() {
        let module = lower("fun main(): Unit { val x: Int = 42 }")
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        // Should have alloc, const_int, store
        XCTAssert(texts.contains { $0.contains("alloc") }, "Expected alloc, got: \(texts)")
        XCTAssert(texts.contains { $0.contains("store") }, "Expected store, got: \(texts)")
    }

    func testVarAssignment() {
        let module = lower("""
        fun main(): Unit {
            var x: Int = 10
            x = 20
        }
        """)
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        // Should have two store instructions (init + reassignment)
        let storeCount = texts.filter { $0.contains("store") }.count
        XCTAssert(storeCount >= 2, "Expected at least 2 stores, got \(storeCount): \(texts)")
    }

    // MARK: - Function Lowering

    func testFunctionDeclaration() {
        let module = lower("""
        fun greet(name: String): String {
            return name
        }
        """)
        let f = findFunction(module, named: "greet")
        XCTAssertNotNil(f)
        XCTAssertEqual(f!.name, "greet")
        XCTAssertEqual(f!.parameters.count, 1)
        XCTAssertEqual(f!.parameters[0].0, "name")
        XCTAssertEqual(f!.returnType, .string)
    }

    func testFunctionCall() {
        let module = lower("""
        fun main(): Unit {
            println("hello")
        }
        """)
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        XCTAssert(texts.contains { $0.contains("call println") }, "Expected call println, got: \(texts)")
    }

    func testMultipleFunctions() {
        let module = lower("""
        fun add(a: Int, b: Int): Int {
            return a
        }
        fun main(): Unit {
            val x: Int = add(1, 2)
        }
        """)
        XCTAssertNotNil(findFunction(module, named: "add"))
        XCTAssertNotNil(findFunction(module, named: "main"))
        XCTAssertEqual(module.functions.count, 2)
    }

    func testExpressionBodyFunction() {
        let module = lower("""
        fun double(x: Int): Int = x
        """)
        let f = findFunction(module, named: "double")
        XCTAssertNotNil(f)
        XCTAssertEqual(f!.returnType, .int)
        // Entry block should have a ret terminator
        XCTAssertNotNil(f!.blocks.first?.terminator)
    }

    // MARK: - Control Flow

    func testIfStatement() {
        let module = lower("""
        fun main(): Unit {
            val x: Bool = true
            if (x) {
                println("yes")
            } else {
                println("no")
            }
        }
        """)
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        // Should have multiple blocks: entry, then, else, merge
        XCTAssert(f!.blocks.count >= 3, "Expected multiple blocks for if, got \(f!.blocks.count)")
        // Check for branch terminator
        let hasBranch = f!.blocks.contains { block in
            if case .branch = block.terminator { return true }
            return false
        }
        XCTAssert(hasBranch, "Expected branch terminator")
    }

    func testWhileLoop() {
        let module = lower("""
        fun main(): Unit {
            var i: Int = 0
            while (i < 10) {
                i = i + 1
            }
        }
        """)
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        // Should have: entry, while.header, while.body, while.exit
        XCTAssert(f!.blocks.count >= 4, "Expected at least 4 blocks for while, got \(f!.blocks.count)")
        let hasHeaderBlock = f!.blocks.contains { $0.label.hasPrefix("while.header") }
        XCTAssert(hasHeaderBlock, "Expected while.header block")
    }

    func testForLoop() {
        let module = lower("""
        fun main(): Unit {
            for (i in 1..10) {
                println("hi")
            }
        }
        """)
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        // Should have for.header, for.body, for.exit blocks
        let hasForHeader = f!.blocks.contains { $0.label.hasPrefix("for.header") }
        XCTAssert(hasForHeader, "Expected for.header block")
    }

    func testWhenExpression() {
        let module = lower("""
        fun main(): Unit {
            val x: Int = 1
            when (x) {
                1 -> println("one")
                2 -> println("two")
                else -> println("other")
            }
        }
        """)
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        // Should have multiple blocks for when entries
        XCTAssert(f!.blocks.count >= 3, "Expected multiple blocks for when, got \(f!.blocks.count)")
    }

    // MARK: - Null Safety

    func testNonNullAssert() {
        let module = lower("""
        fun main(): Unit {
            val x: String? = null
            val y: String = x!!
        }
        """)
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        XCTAssert(texts.contains { $0.contains("null_check") }, "Expected null_check, got: \(texts)")
    }

    func testElvisOperator() {
        let module = lower("""
        fun main(): Unit {
            val x: String? = null
            val y: String = x ?: "default"
        }
        """)
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        // Should have is_null check and branch blocks
        let hasIsNull = f!.blocks.flatMap { $0.instructions }.contains { inst in
            "\(inst)".contains("is_null")
        }
        XCTAssert(hasIsNull, "Expected is_null instruction for elvis")
    }

    func testTypeCheckIs() {
        let module = lower("""
        fun check(x: String): Bool {
            return x is String
        }
        """)
        let f = findFunction(module, named: "check")
        XCTAssertNotNil(f)
        let allInsts = f!.blocks.flatMap { $0.instructions }.map { "\($0)" }
        XCTAssert(allInsts.contains { $0.contains("type_check") }, "Expected type_check, got: \(allInsts)")
    }

    func testTypeCastAs() {
        let module = lower("""
        fun cast(x: String): Int {
            return x as Int
        }
        """)
        let f = findFunction(module, named: "cast")
        XCTAssertNotNil(f)
        let allInsts = f!.blocks.flatMap { $0.instructions }.map { "\($0)" }
        XCTAssert(allInsts.contains { $0.contains("type_cast") }, "Expected type_cast, got: \(allInsts)")
    }

    func testSafeCast() {
        let module = lower("""
        fun safeCast(x: String): Int? {
            return x as? Int
        }
        """)
        let f = findFunction(module, named: "safeCast")
        XCTAssertNotNil(f)
        // Should have type_check + branch for safe cast
        let hasTypeCheck = f!.blocks.flatMap { $0.instructions }.contains { inst in
            "\(inst)".contains("type_check")
        }
        XCTAssert(hasTypeCheck, "Expected type_check for safe cast")
    }

    // MARK: - Class Lowering

    func testClassDeclaration() {
        let module = lower("""
        class User(val name: String, val age: Int) {
            fun greet(): String {
                return name
            }
        }
        """)
        // Should have a type declaration
        let typeDecl = module.types.first { $0.name == "User" }
        XCTAssertNotNil(typeDecl)
        XCTAssert(typeDecl!.fields.contains { $0.0 == "name" }, "Expected name field")
        XCTAssert(typeDecl!.fields.contains { $0.0 == "age" }, "Expected age field")
        XCTAssert(typeDecl!.methods.contains("User.greet"), "Expected User.greet method")

        // Should have the lowered method
        let greetFunc = findFunction(module, named: "User.greet")
        XCTAssertNotNil(greetFunc)
    }

    func testClassConstructorCall() {
        let module = lower("""
        class Point(val x: Int, val y: Int)
        fun main(): Unit {
            val p: Point = Point(1, 2)
        }
        """)
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        XCTAssert(texts.contains { $0.contains("new Point") }, "Expected new Point, got: \(texts)")
    }

    // MARK: - Enum Lowering

    func testEnumDeclaration() {
        let module = lower("""
        enum class Color {
            RED,
            GREEN,
            BLUE
        }
        """)
        // Type has a $variant field for the entry name
        let typeDecl = module.types.first { $0.name == "Color" }
        XCTAssertNotNil(typeDecl)
        XCTAssert(typeDecl!.fields.contains { $0.0 == "$variant" }, "Expected $variant field")

        // Each entry becomes a global singleton
        XCTAssert(module.globals.contains { $0.name == "Color.RED" }, "Expected Color.RED global")
        XCTAssert(module.globals.contains { $0.name == "Color.GREEN" }, "Expected Color.GREEN global")
        XCTAssert(module.globals.contains { $0.name == "Color.BLUE" }, "Expected Color.BLUE global")

        // Each entry has an initializer function
        XCTAssert(module.functions.contains { $0.name == "__init_Color_RED" }, "Expected init function for RED")
    }

    // MARK: - Object Lowering

    func testObjectDeclaration() {
        let module = lower("""
        object Config {
            val version: String = "1.0"
        }
        """)
        let typeDecl = module.types.first { $0.name == "Config" }
        XCTAssertNotNil(typeDecl)
        XCTAssert(typeDecl!.fields.contains { $0.0 == "version" }, "Expected version field")
    }

    // MARK: - String Interpolation

    func testStringInterpolation() {
        let module = lower("""
        fun main(): Unit {
            val name: String = "world"
            val msg: String = "hello ${name}!"
        }
        """)
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        XCTAssert(texts.contains { $0.contains("string_concat") }, "Expected string_concat, got: \(texts)")
    }

    // MARK: - Global Properties

    func testTopLevelProperty() {
        let module = lower("""
        val VERSION: String = "1.0"
        """)
        XCTAssert(module.globals.contains { $0.name == "VERSION" }, "Expected VERSION global")
        let global = module.globals.first { $0.name == "VERSION" }!
        XCTAssertEqual(global.isMutable, false)
        XCTAssertNotNil(global.initializerFunc)
    }

    func testTopLevelMutableProperty() {
        let module = lower("""
        var count: Int = 0
        """)
        let global = module.globals.first { $0.name == "count" }
        XCTAssertNotNil(global)
        XCTAssertEqual(global!.isMutable, true)
    }

    // MARK: - Actor Lowering

    func testActorDeclaration() {
        let module = lower("""
        actor Counter {
            var count: Int = 0
            fun increment(): Unit {
                count = count + 1
            }
        }
        """)
        let typeDecl = module.types.first { $0.name == "Counter" }
        XCTAssertNotNil(typeDecl)
        XCTAssert(typeDecl!.fields.contains { $0.0 == "count" }, "Expected count field")
        XCTAssert(typeDecl!.methods.contains("Counter.increment"), "Expected Counter.increment")
        XCTAssertNotNil(findFunction(module, named: "Counter.increment"))
    }

    // MARK: - Module Textual Dump

    func testModuleDump() {
        let module = lower("""
        fun main(): Unit {
            println("hello")
        }
        """)
        let dump = module.description
        XCTAssert(dump.contains("MIR Module"), "Expected MIR Module header")
        XCTAssert(dump.contains("fun main"), "Expected fun main in dump")
    }

    // MARK: - Integration

    func testFullProgramLowering() {
        let module = lower("""
        val greeting: String = "Hello"

        fun add(a: Int, b: Int): Int {
            return a
        }

        fun main(): Unit {
            val x: Int = add(1, 2)
            val y: Int = 10
            if (x == y) {
                println("equal")
            } else {
                println("not equal")
            }
        }
        """)
        XCTAssert(module.functions.count >= 2, "Expected at least 2 functions (add, main)")
        XCTAssert(module.globals.count >= 1, "Expected at least 1 global")
        XCTAssertNotNil(findFunction(module, named: "main"))
        XCTAssertNotNil(findFunction(module, named: "add"))
        XCTAssert(module.totalInstructionCount > 0, "Expected non-zero instruction count")
    }

    func testInterfaceLowering() {
        let module = lower("""
        interface Drawable {
            fun draw(): Unit
        }
        """)
        let typeDecl = module.types.first { $0.name == "Drawable" }
        XCTAssertNotNil(typeDecl)
        XCTAssert(typeDecl!.methods.contains("Drawable.draw"), "Expected Drawable.draw method")
    }

    func testReturnStatement() {
        let module = lower("""
        fun early(x: Int): Int {
            return x
        }
        """)
        let f = findFunction(module, named: "early")
        XCTAssertNotNil(f)
        // Entry block should end with ret
        let entryTerm = f!.blocks.first?.terminator
        if case .ret(let val) = entryTerm {
            XCTAssertNotNil(val, "Expected return with a value")
        } else {
            XCTFail("Expected ret terminator, got \(String(describing: entryTerm))")
        }
    }

    func testDoWhileLoop() {
        let module = lower("""
        fun main(): Unit {
            var x: Int = 0
            do {
                x = x + 1
            } while (x < 5)
        }
        """)
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let hasDoWhileBody = f!.blocks.contains { $0.label.hasPrefix("dowhile.body") }
        XCTAssert(hasDoWhileBody, "Expected dowhile.body block")
    }

    func testCompoundAssignment() {
        let module = lower("""
        fun main(): Unit {
            var x: Int = 10
            x += 5
        }
        """)
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        // Should have load, add, store sequence
        XCTAssert(texts.contains { $0.contains("add") }, "Expected add for +=, got: \(texts)")
    }

    func testMemberAccess() {
        let module = lower("""
        class User(val name: String)
        fun main(): Unit {
            val u: User = User("Alice")
            val n: String = u.name
        }
        """)
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        XCTAssert(texts.contains { $0.contains("get_field") && $0.contains("name") }, "Expected get_field .name, got: \(texts)")
    }

    func testRangeExpression() {
        let module = lower("""
        fun main(): Unit {
            val r: Int = 1..10
        }
        """)
        let f = findFunction(module, named: "main")
        XCTAssertNotNil(f)
        let texts = instructionTexts(f!)
        XCTAssert(texts.contains { $0.contains("rangeTo") }, "Expected rangeTo call, got: \(texts)")
    }
}
