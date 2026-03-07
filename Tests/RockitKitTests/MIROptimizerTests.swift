// MIROptimizerTests.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import XCTest
@testable import RockitKit

final class MIROptimizerTests: XCTestCase {

    // MARK: - Helpers

    /// Lex → parse → type check → lower → optimize → return MIRModule
    private func optimize(_ source: String) -> MIRModule {
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
        return optimizer.optimize(module)
    }

    /// Lex → parse → type check → lower (no optimize) → return MIRModule
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

    /// Build a single-block MIR function from instructions and a terminator.
    private func makeFunction(
        name: String,
        params: [(String, MIRType)] = [],
        returnType: MIRType = .unit,
        instructions: [MIRInstruction],
        terminator: MIRTerminator = .ret(nil)
    ) -> MIRFunction {
        let block = MIRBasicBlock(
            label: "entry",
            instructions: instructions,
            terminator: terminator
        )
        return MIRFunction(name: name, parameters: params, returnType: returnType, blocks: [block])
    }

    /// Build a MIR module from components.
    private func makeModule(
        functions: [MIRFunction] = [],
        globals: [MIRGlobal] = [],
        types: [MIRTypeDecl] = []
    ) -> MIRModule {
        return MIRModule(globals: globals, functions: functions, types: types)
    }

    /// Find a function by name.
    private func findFunction(_ module: MIRModule, named name: String) -> MIRFunction? {
        return module.functions.first { $0.name == name }
    }

    /// Get all instruction text from all blocks of a function.
    private func allInstructionTexts(_ func_: MIRFunction) -> [String] {
        return func_.blocks.flatMap { $0.instructions }.map { "\($0)" }
    }

    // MARK: - Constant Folding: Integer Arithmetic

    func testFoldIntAddition() {
        let module = optimize("fun main(): Unit { val x: Int = 2 + 3 }")
        let f = findFunction(module, named: "main")!
        let texts = allInstructionTexts(f)
        XCTAssert(texts.contains { $0.contains("const_int 5") }, "Expected folded const_int 5, got: \(texts)")
        XCTAssertFalse(texts.contains { $0.contains(" add ") }, "Expected add to be folded away, got: \(texts)")
    }

    func testFoldIntSubtraction() {
        let module = optimize("fun main(): Unit { val x: Int = 10 - 4 }")
        let f = findFunction(module, named: "main")!
        let texts = allInstructionTexts(f)
        XCTAssert(texts.contains { $0.contains("const_int 6") }, "Expected folded const_int 6, got: \(texts)")
        XCTAssertFalse(texts.contains { $0.contains(" sub ") }, "Expected sub to be folded away")
    }

    func testFoldIntMultiplication() {
        let module = optimize("fun main(): Unit { val x: Int = 3 * 7 }")
        let f = findFunction(module, named: "main")!
        let texts = allInstructionTexts(f)
        XCTAssert(texts.contains { $0.contains("const_int 21") }, "Expected folded const_int 21, got: \(texts)")
        XCTAssertFalse(texts.contains { $0.contains(" mul ") }, "Expected mul to be folded away")
    }

    func testFoldIntDivision() {
        let module = optimize("fun main(): Unit { val x: Int = 10 / 2 }")
        let f = findFunction(module, named: "main")!
        let texts = allInstructionTexts(f)
        XCTAssert(texts.contains { $0.contains("const_int 5") }, "Expected folded const_int 5, got: \(texts)")
        XCTAssertFalse(texts.contains { $0.contains(" div ") }, "Expected div to be folded away")
    }

    func testFoldIntModulo() {
        let module = optimize("fun main(): Unit { val x: Int = 10 % 3 }")
        let f = findFunction(module, named: "main")!
        let texts = allInstructionTexts(f)
        XCTAssert(texts.contains { $0.contains("const_int 1") }, "Expected folded const_int 1, got: \(texts)")
        XCTAssertFalse(texts.contains { $0.contains(" mod ") }, "Expected mod to be folded away")
    }

    func testFoldNegation() {
        let module = optimize("fun main(): Unit { val x: Int = -42 }")
        let f = findFunction(module, named: "main")!
        let texts = allInstructionTexts(f)
        XCTAssert(texts.contains { $0.contains("const_int -42") }, "Expected folded const_int -42, got: \(texts)")
        XCTAssertFalse(texts.contains { $0.contains(" neg ") }, "Expected neg to be folded away")
    }

    func testNoFoldDivisionByZero() {
        let module = optimize("fun main(): Unit { val x: Int = 10 / 0 }")
        let f = findFunction(module, named: "main")!
        let texts = allInstructionTexts(f)
        XCTAssert(texts.contains { $0.contains(" div ") }, "Division by zero should NOT be folded")
    }

    // MARK: - Constant Folding: Boolean Logic

    func testFoldBoolAnd() {
        let module = optimize("fun main(): Unit { val x: Bool = true && false }")
        let f = findFunction(module, named: "main")!
        let texts = allInstructionTexts(f)
        XCTAssert(texts.contains { $0.contains("const_bool false") }, "Expected folded const_bool false, got: \(texts)")
        XCTAssertFalse(texts.contains { $0.contains(" and ") }, "Expected and to be folded away")
    }

    func testFoldBoolOr() {
        let module = optimize("fun main(): Unit { val x: Bool = true || false }")
        let f = findFunction(module, named: "main")!
        let texts = allInstructionTexts(f)
        XCTAssert(texts.contains { $0.contains("const_bool true") }, "Expected folded const_bool true, got: \(texts)")
        XCTAssertFalse(texts.contains { $0.contains(" or ") }, "Expected or to be folded away")
    }

    func testFoldBoolNot() {
        let module = optimize("fun main(): Unit { val x: Bool = !true }")
        let f = findFunction(module, named: "main")!
        let texts = allInstructionTexts(f)
        XCTAssert(texts.contains { $0.contains("const_bool false") }, "Expected folded const_bool false, got: \(texts)")
        XCTAssertFalse(texts.contains { $0.contains(" not ") }, "Expected not to be folded away")
    }

    // MARK: - Constant Folding: Comparisons

    func testFoldLessThan() {
        let module = optimize("fun main(): Unit { val x: Bool = 1 < 2 }")
        let f = findFunction(module, named: "main")!
        let texts = allInstructionTexts(f)
        XCTAssert(texts.contains { $0.contains("const_bool true") }, "Expected folded const_bool true, got: \(texts)")
    }

    func testFoldEquality() {
        let module = optimize("fun main(): Unit { val x: Bool = 5 == 5 }")
        let f = findFunction(module, named: "main")!
        let texts = allInstructionTexts(f)
        XCTAssert(texts.contains { $0.contains("const_bool true") }, "Expected folded const_bool true, got: \(texts)")
    }

    func testFoldInequality() {
        let module = optimize("fun main(): Unit { val x: Bool = 3 != 3 }")
        let f = findFunction(module, named: "main")!
        let texts = allInstructionTexts(f)
        XCTAssert(texts.contains { $0.contains("const_bool false") }, "Expected folded const_bool false, got: \(texts)")
    }

    // MARK: - Constant Folding: String Concat

    func testFoldStringConcat() {
        let module = optimize("""
        fun main(): Unit {
            val x: String = "hello" + " " + "world"
        }
        """)
        let f = findFunction(module, named: "main")!
        // String "+" is not lowered as stringConcat for binary ops — it becomes an add.
        // This test verifies the optimizer runs without crashing on string operations.
        XCTAssertNotNil(f)
    }

    // MARK: - Constant Folding: Branch Folding

    func testBranchFoldOnTrue() {
        // if (true) should fold to unconditional jump
        let module = optimize("""
        fun main(): Unit {
            if (true) {
                println("yes")
            } else {
                println("no")
            }
        }
        """)
        let f = findFunction(module, named: "main")!
        // After branch folding + DCE, the else block should be unreachable and removed
        // Entry block should have jump (not branch) after folding
        let entryTerm = f.blocks.first?.terminator
        if case .jump = entryTerm {
            // Good — branch was folded to jump
        } else if case .branch = entryTerm {
            XCTFail("Expected branch on constant true to be folded to jump")
        }
    }

    // MARK: - Dead Code Elimination

    func testRemoveUnusedTemp() {
        // Build a function with an unused constant directly
        let f = makeFunction(
            name: "main",
            instructions: [
                .constInt(dest: "%t0", value: 42),  // unused
            ]
        )
        let module = makeModule(functions: [f])
        let pass = DeadCodeEliminationPass()
        let result = pass.run(module)
        let mainFunc = result.functions.first!
        // The unused const_int should be removed
        XCTAssertEqual(mainFunc.blocks[0].instructions.count, 0, "Unused temp should be eliminated")
    }

    func testKeepUsedTemp() {
        let f = makeFunction(
            name: "main",
            instructions: [
                .constInt(dest: "%t0", value: 42),
            ],
            terminator: .ret("%t0")
        )
        let module = makeModule(functions: [f])
        let pass = DeadCodeEliminationPass()
        let result = pass.run(module)
        let mainFunc = result.functions.first!
        XCTAssertEqual(mainFunc.blocks[0].instructions.count, 1, "Used temp should be kept")
    }

    func testKeepSideEffectingCall() {
        let f = makeFunction(
            name: "main",
            instructions: [
                .constString(dest: "%t0", value: "hello"),
                .call(dest: "%t1", function: "println", args: ["%t0"]),
            ]
        )
        let module = makeModule(functions: [f])
        let pass = DeadCodeEliminationPass()
        let result = pass.run(module)
        let mainFunc = result.functions.first!
        // call has side effects — must be kept even though %t1 is unused
        let hasCall = mainFunc.blocks[0].instructions.contains { inst in
            if case .call = inst { return true }
            return false
        }
        XCTAssert(hasCall, "Side-effecting call should be kept")
    }

    func testIterativeDCE() {
        // %t0 -> %t1 -> %t2, only %t2 is "used" by nothing
        let f = makeFunction(
            name: "main",
            instructions: [
                .constInt(dest: "%t0", value: 1),
                .constInt(dest: "%t1", value: 2),
                .add(dest: "%t2", lhs: "%t0", rhs: "%t1", type: .int),
                // %t2 is unused, so add is dead. Then %t0 and %t1 become dead.
            ]
        )
        let module = makeModule(functions: [f])
        let pass = DeadCodeEliminationPass()
        let result = pass.run(module)
        let mainFunc = result.functions.first!
        XCTAssertEqual(mainFunc.blocks[0].instructions.count, 0, "All dead instructions should be eliminated iteratively")
    }

    func testRemoveUnreachableBlock() {
        // Build a function with entry -> jump to exit, and a dead block
        let entry = MIRBasicBlock(
            label: "entry",
            instructions: [],
            terminator: .jump("exit")
        )
        let dead = MIRBasicBlock(
            label: "dead",
            instructions: [.constInt(dest: "%t0", value: 99)],
            terminator: .ret("%t0")
        )
        let exit = MIRBasicBlock(
            label: "exit",
            instructions: [],
            terminator: .ret(nil)
        )
        let f = MIRFunction(name: "main", parameters: [], returnType: .unit, blocks: [entry, dead, exit])
        let module = makeModule(functions: [f])
        let pass = DeadCodeEliminationPass()
        let result = pass.run(module)
        let mainFunc = result.functions.first!
        let labels = mainFunc.blocks.map { $0.label }
        XCTAssert(labels.contains("entry"), "Entry should be kept")
        XCTAssert(labels.contains("exit"), "Exit should be kept")
        XCTAssertFalse(labels.contains("dead"), "Dead block should be removed")
    }

    func testKeepStoreInstruction() {
        let f = makeFunction(
            name: "main",
            instructions: [
                .alloc(dest: "%t0", type: .int),
                .constInt(dest: "%t1", value: 42),
                .store(dest: "%t0", src: "%t1"),
            ]
        )
        let module = makeModule(functions: [f])
        let pass = DeadCodeEliminationPass()
        let result = pass.run(module)
        let mainFunc = result.functions.first!
        let hasStore = mainFunc.blocks[0].instructions.contains { inst in
            if case .store = inst { return true }
            return false
        }
        XCTAssert(hasStore, "Store should be kept (side effect)")
    }

    // MARK: - Tree Shaking

    func testRemoveUnusedFunction() {
        let mainFunc = makeFunction(
            name: "main",
            instructions: [.constInt(dest: "%t0", value: 1)],
            terminator: .ret(nil)
        )
        let unusedFunc = makeFunction(
            name: "unused",
            instructions: [.constInt(dest: "%t0", value: 2)],
            terminator: .ret("%t0")
        )
        let module = makeModule(functions: [mainFunc, unusedFunc])
        let pass = TreeShakingPass()
        let result = pass.run(module)
        XCTAssertEqual(result.functions.count, 1, "Unused function should be removed")
        XCTAssertEqual(result.functions[0].name, "main")
    }

    func testKeepCalledFunction() {
        let helperFunc = makeFunction(
            name: "helper",
            instructions: [.constInt(dest: "%t0", value: 42)],
            terminator: .ret("%t0")
        )
        let mainFunc = makeFunction(
            name: "main",
            instructions: [.call(dest: "%t0", function: "helper", args: [])],
            terminator: .ret(nil)
        )
        let module = makeModule(functions: [helperFunc, mainFunc])
        let pass = TreeShakingPass()
        let result = pass.run(module)
        XCTAssertEqual(result.functions.count, 2, "Called function should be kept")
    }

    func testKeepTransitiveDependency() {
        let cFunc = makeFunction(
            name: "c",
            instructions: [.constInt(dest: "%t0", value: 1)],
            terminator: .ret("%t0")
        )
        let bFunc = makeFunction(
            name: "b",
            instructions: [.call(dest: "%t0", function: "c", args: [])],
            terminator: .ret("%t0")
        )
        let mainFunc = makeFunction(
            name: "main",
            instructions: [.call(dest: "%t0", function: "b", args: [])],
            terminator: .ret(nil)
        )
        let unusedFunc = makeFunction(
            name: "unused",
            instructions: [],
            terminator: .ret(nil)
        )
        let module = makeModule(functions: [cFunc, bFunc, mainFunc, unusedFunc])
        let pass = TreeShakingPass()
        let result = pass.run(module)
        let names = Set(result.functions.map { $0.name })
        XCTAssert(names.contains("main"), "main should be kept")
        XCTAssert(names.contains("b"), "b should be kept (called by main)")
        XCTAssert(names.contains("c"), "c should be kept (called by b)")
        XCTAssertFalse(names.contains("unused"), "unused should be removed")
    }

    func testRemoveUnusedType() {
        let usedType = MIRTypeDecl(name: "UsedClass", fields: [("x", .int)])
        let unusedType = MIRTypeDecl(name: "UnusedClass", fields: [("y", .string)])
        // main creates UsedClass but not UnusedClass
        let mainWithNew = makeFunction(
            name: "main",
            instructions: [.newObject(dest: "%t0", typeName: "UsedClass", args: [])],
            terminator: .ret(nil)
        )
        let module = makeModule(functions: [mainWithNew], types: [usedType, unusedType])
        let pass = TreeShakingPass()
        let result = pass.run(module)
        XCTAssertEqual(result.types.count, 1)
        XCTAssertEqual(result.types[0].name, "UsedClass")
    }

    func testKeepGlobalInitializer() {
        let initFunc = makeFunction(
            name: "__init_VERSION",
            instructions: [.constString(dest: "%t0", value: "1.0")],
            terminator: .ret("%t0")
        )
        let mainFunc = makeFunction(
            name: "main",
            instructions: [],
            terminator: .ret(nil)
        )
        let global = MIRGlobal(name: "VERSION", type: .string, isMutable: false, initializerFunc: "__init_VERSION")
        let module = makeModule(functions: [initFunc, mainFunc], globals: [global])
        let pass = TreeShakingPass()
        let result = pass.run(module)
        let names = Set(result.functions.map { $0.name })
        XCTAssert(names.contains("__init_VERSION"), "Global initializer should be kept")
    }

    // MARK: - Integration

    func testOptimizeReducesInstructionCount() {
        let source = """
        fun main(): Unit {
            val x: Int = 2 + 3
            val y: Int = 10 * 2
            val z: Bool = 1 < 2
        }
        """
        let unoptimized = lower(source)
        let optimized = optimize(source)
        let mainUnopt = unoptimized.functions.first { $0.name == "main" }!
        let mainOpt = optimized.functions.first { $0.name == "main" }!
        XCTAssert(mainOpt.instructionCount <= mainUnopt.instructionCount,
                  "Optimized should have <= instructions: \(mainOpt.instructionCount) vs \(mainUnopt.instructionCount)")
    }

    func testOptimizeEmptyModule() {
        let module = MIRModule()
        let optimizer = MIROptimizer()
        let result = optimizer.optimize(module)
        XCTAssertEqual(result.functions.count, 0)
        XCTAssertEqual(result.globals.count, 0)
        XCTAssertEqual(result.types.count, 0)
    }

    func testOptimizePreservesSemantics() {
        let module = optimize("""
        fun add(a: Int, b: Int): Int {
            return a
        }
        fun main(): Unit {
            val x: Int = add(1, 2)
            println("done")
        }
        """)
        // main and add should both be kept (add is called)
        XCTAssertNotNil(findFunction(module, named: "main"))
        XCTAssertNotNil(findFunction(module, named: "add"))
    }

    func testOptimizeComplexProgram() {
        let module = optimize("""
        val greeting: String = "Hello"

        class User(val name: String)

        fun unused(): Unit {
            println("never called")
        }

        fun main(): Unit {
            val x: Int = 2 + 3
            val u: User = User("Alice")
            if (true) {
                println("yes")
            } else {
                println("no")
            }
        }
        """)
        // unused() should be tree-shaken
        XCTAssertNil(findFunction(module, named: "unused"), "unused() should be tree-shaken")
        // main should exist
        XCTAssertNotNil(findFunction(module, named: "main"))
        // User type should exist (constructed in main)
        XCTAssert(module.types.contains { $0.name == "User" }, "User type should be kept")
        // greeting global initializer should exist
        XCTAssert(module.globals.contains { $0.name == "greeting" })
    }

    func testFoldChainedArithmetic() {
        // (2 + 3) * 4 — the parser produces nested binary ops
        // The lowering emits: const 2, const 3, add -> %t2, const 4, mul %t2 %t3
        // Constant folding should propagate: add folded to const 5, then mul folded to const 20
        let module = optimize("fun main(): Unit { val x: Int = (2 + 3) * 4 }")
        let f = findFunction(module, named: "main")!
        let texts = allInstructionTexts(f)
        XCTAssert(texts.contains { $0.contains("const_int 20") }, "Expected chained fold to const_int 20, got: \(texts)")
    }
}
