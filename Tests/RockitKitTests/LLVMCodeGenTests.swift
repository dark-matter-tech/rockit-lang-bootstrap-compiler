// LLVMCodeGenTests.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import XCTest
@testable import RockitKit

final class LLVMCodeGenTests: XCTestCase {

    // MARK: - Helpers

    /// Full pipeline: source → MIR → LLVM IR text
    private func emitLLVM(_ source: String) -> String {
        let diagnostics = DiagnosticEngine()
        let lexer = Lexer(source: source, fileName: "test.rok", diagnostics: diagnostics)
        let tokens = lexer.tokenize()
        let parser = Parser(tokens: tokens, diagnostics: diagnostics)
        let ast = parser.parse()
        let checker = TypeChecker(ast: ast, diagnostics: diagnostics)
        let result = checker.check()
        XCTAssertFalse(diagnostics.hasErrors, "Frontend errors: \(diagnostics.errorCount)")
        let lowering = MIRLowering(typeCheckResult: result)
        let module = lowering.lower()
        let optimizer = MIROptimizer()
        let optimized = optimizer.optimize(module)
        let codeGen = LLVMCodeGen()
        return codeGen.emit(module: optimized)
    }

    // MARK: - Module Structure

    func testModuleHeader() {
        let ir = emitLLVM("fun main(): Unit { }")
        XCTAssertTrue(ir.contains("; Rockit LLVM IR"))
        XCTAssertTrue(ir.contains("target triple ="))
    }

    func testMainFunctionReturnsI32() {
        let ir = emitLLVM("fun main(): Unit { }")
        XCTAssertTrue(ir.contains("define i32 @main(i32 %argc, ptr %argv)"), "main should return i32 with argc/argv")
        XCTAssertTrue(ir.contains("ret i32 0"), "main should return 0")
    }

    func testNonMainFunctionReturnsVoid() {
        let ir = emitLLVM("""
        fun helper(): Unit { }
        fun main(): Unit { helper() }
        """)
        XCTAssertTrue(ir.contains("define internal void @helper()"), "helper should return void")
        XCTAssertTrue(ir.contains("define i32 @main(i32 %argc, ptr %argv)"), "main should return i32")
    }

    // MARK: - Integer Arithmetic

    func testConstInt() {
        let ir = emitLLVM("""
        fun main(): Unit {
            val x: Int = 42
        }
        """)
        XCTAssertTrue(ir.contains("store i64 42"), "Should store integer constant 42")
    }

    func testIntegerAdd() {
        // Use a function parameter to prevent constant folding
        let ir = emitLLVM("""
        fun add(a: Int, b: Int): Int {
            return a + b
        }
        fun main(): Unit { println(add(40, 2)) }
        """)
        XCTAssertTrue(ir.contains("add i64"), "Should emit add i64 instruction")
    }

    func testIntegerSub() {
        let ir = emitLLVM("""
        fun sub(a: Int, b: Int): Int {
            return a - b
        }
        fun main(): Unit { println(sub(50, 8)) }
        """)
        XCTAssertTrue(ir.contains("sub i64"), "Should emit sub i64 instruction")
    }

    func testIntegerMul() {
        let ir = emitLLVM("""
        fun mul(a: Int, b: Int): Int {
            return a * b
        }
        fun main(): Unit { println(mul(6, 7)) }
        """)
        XCTAssertTrue(ir.contains("mul i64"), "Should emit mul i64 instruction")
    }

    func testIntegerDiv() {
        let ir = emitLLVM("""
        fun div(a: Int, b: Int): Int {
            return a / b
        }
        fun main(): Unit { println(div(100, 5)) }
        """)
        XCTAssertTrue(ir.contains("sdiv i64"), "Should emit sdiv i64 instruction")
    }

    func testIntegerMod() {
        let ir = emitLLVM("""
        fun mod(a: Int, b: Int): Int {
            return a % b
        }
        fun main(): Unit { println(mod(17, 5)) }
        """)
        XCTAssertTrue(ir.contains("srem i64"), "Should emit srem i64 instruction")
    }

    // MARK: - Boolean Operations

    func testConstBool() {
        let ir = emitLLVM("""
        fun main(): Unit {
            val x: Bool = true
            val y: Bool = false
        }
        """)
        XCTAssertTrue(ir.contains("store i1 1"), "Should store true as 1")
        XCTAssertTrue(ir.contains("store i1 0"), "Should store false as 0")
    }

    // MARK: - Comparisons

    func testIntComparison() {
        let ir = emitLLVM("""
        fun main(): Unit {
            val x: Int = 5
            val y: Int = 10
            val result: Bool = x < y
        }
        """)
        XCTAssertTrue(ir.contains("icmp slt i64"), "Should emit signed less-than comparison")
    }

    // MARK: - Print Builtin

    func testPrintlnInt() {
        let ir = emitLLVM("""
        fun main(): Unit {
            println(42)
        }
        """)
        XCTAssertTrue(ir.contains("@rockit_println_int"), "Should call rockit_println_int")
    }

    func testPrintlnString() {
        let ir = emitLLVM("""
        fun main(): Unit {
            println("Hello, Rockit!")
        }
        """)
        XCTAssertTrue(ir.contains("@rockit_println_string"), "Should call rockit_println_string")
        XCTAssertTrue(ir.contains("Hello, Rockit!"), "Should contain string literal")
    }

    // MARK: - String Literals

    func testStringLiteralGlobal() {
        let ir = emitLLVM("""
        fun main(): Unit {
            val s: String = "test"
        }
        """)
        XCTAssertTrue(ir.contains("@.str."), "Should emit string literal global")
        XCTAssertTrue(ir.contains("rockit_string_new"), "Should call rockit_string_new")
    }

    // MARK: - Functions with Parameters

    func testFunctionWithIntParam() {
        let ir = emitLLVM("""
        fun double(x: Int): Int {
            return x + x
        }
        fun main(): Unit {
            println(double(21))
        }
        """)
        XCTAssertTrue(ir.contains("define internal i64 @double("), "Should define function returning i64")
        XCTAssertTrue(ir.contains("%param.x"), "Should have parameter named x")
        XCTAssertTrue(ir.contains("ret i64"), "Should return i64")
    }

    // MARK: - Alloca Structure

    func testAllocaPrologue() {
        let ir = emitLLVM("""
        fun main(): Unit {
            val x: Int = 1
        }
        """)
        XCTAssertTrue(ir.contains("prologue:"), "Should have prologue block for allocas")
        XCTAssertTrue(ir.contains("alloca i64"), "Should allocate i64 for Int variable")
        XCTAssertTrue(ir.contains("br label %entry"), "Should branch to entry block")
    }

    // MARK: - External Declarations

    func testRuntimeDeclarations() {
        let ir = emitLLVM("fun main(): Unit { }")
        XCTAssertTrue(ir.contains("declare void @rockit_println_int(i64)"))
        XCTAssertTrue(ir.contains("declare ptr @rockit_string_new(ptr)"))
        XCTAssertTrue(ir.contains("declare void @rockit_panic(ptr)"))
    }

    // MARK: - Control Flow

    func testConditionalBranch() {
        let ir = emitLLVM("""
        fun main(): Unit {
            val x: Int = 5
            if (x > 3) {
                println(1)
            } else {
                println(0)
            }
        }
        """)
        XCTAssertTrue(ir.contains("br i1"), "Should emit conditional branch")
        XCTAssertTrue(ir.contains("icmp sgt i64"), "Should emit greater-than comparison")
    }

    // MARK: - Float Arithmetic

    func testFloatAdd() {
        let ir = emitLLVM("""
        fun addF(a: Float64, b: Float64): Float64 {
            return a + b
        }
        fun main(): Unit { println(addF(1.5, 2.5)) }
        """)
        XCTAssertTrue(ir.contains("fadd double"), "Should emit fadd for float addition")
        XCTAssertTrue(ir.contains("alloca double"), "Should allocate double for Float64")
    }

    // MARK: - Negation

    func testIntegerNeg() {
        let ir = emitLLVM("""
        fun main(): Unit {
            val x: Int = 42
            val y: Int = -x
        }
        """)
        XCTAssertTrue(ir.contains("sub i64 0,"), "Should emit sub 0 for integer negation")
    }

    // MARK: - User-Defined Function Return Types

    func testUserFunctionReturningString() {
        let ir = emitLLVM("""
        fun greet(name: String): String {
            return "Hello, " + name + "!"
        }
        fun main(): Unit {
            println(greet("World"))
        }
        """)
        XCTAssertTrue(ir.contains("define internal ptr @greet("), "greet should return ptr")
        XCTAssertTrue(ir.contains("call ptr @greet("), "call site should use ptr return type")
        XCTAssertTrue(ir.contains("rockit_println_string"), "Should println as string, not int")
    }

    func testUserFunctionReturningInt() {
        let ir = emitLLVM("""
        fun add(a: Int, b: Int): Int {
            return a + b
        }
        fun main(): Unit {
            println(add(1, 2))
        }
        """)
        XCTAssertTrue(ir.contains("define internal i64 @add("), "add should return i64")
        XCTAssertTrue(ir.contains("call i64 @add("), "call site should use i64 return type")
        XCTAssertTrue(ir.contains("rockit_println_int"), "Should println as int")
    }

    func testUserFunctionReturningBool() {
        let ir = emitLLVM("""
        fun isPositive(n: Int): Bool {
            return n > 0
        }
        fun main(): Unit {
            println(isPositive(5))
        }
        """)
        XCTAssertTrue(ir.contains("define internal i1 @isPositive("), "isPositive should return i1")
        XCTAssertTrue(ir.contains("call i1 @isPositive("), "call site should use i1 return type")
        XCTAssertTrue(ir.contains("rockit_println_bool"), "Should println as bool")
    }

    func testUserFunctionReturningFloat() {
        let ir = emitLLVM("""
        fun half(x: Float64): Float64 {
            return x / 2.0
        }
        fun main(): Unit {
            println(half(7.0))
        }
        """)
        XCTAssertTrue(ir.contains("define internal double @half("), "half should return double")
        XCTAssertTrue(ir.contains("call double @half("), "call site should use double return type")
        XCTAssertTrue(ir.contains("rockit_println_float"), "Should println as float")
    }

    func testMultipleFunctionsCrossCall() {
        let ir = emitLLVM("""
        fun double(x: Int): Int {
            return x + x
        }
        fun quadruple(x: Int): Int {
            return double(double(x))
        }
        fun main(): Unit {
            println(quadruple(10))
        }
        """)
        XCTAssertTrue(ir.contains("define internal i64 @double("), "double should return i64")
        XCTAssertTrue(ir.contains("define internal i64 @quadruple("), "quadruple should return i64")
        XCTAssertTrue(ir.contains("call i64 @double("), "should call double with i64 return")
    }

    // MARK: - Objects (Phase 1E)

    func testNewObject() {
        let ir = emitLLVM("""
        data class Point(val x: Int, val y: Int)
        fun main(): Unit {
            val p = Point(3, 4)
        }
        """)
        XCTAssertTrue(ir.contains("rockit_object_alloc"), "Should call rockit_object_alloc")
        XCTAssertTrue(ir.contains("rockit_object_set_field"), "Should set fields")
        XCTAssertTrue(ir.contains("@.typename."), "Should emit type name global")
    }

    func testGetField() {
        let ir = emitLLVM("""
        data class Point(val x: Int, val y: Int)
        fun main(): Unit {
            val p = Point(3, 4)
            println(p.x)
        }
        """)
        XCTAssertTrue(ir.contains("rockit_object_get_field"), "Should call get_field")
        XCTAssertTrue(ir.contains("i32 0"), "Should access field at index 0")
    }

    func testMethodCall() {
        let ir = emitLLVM("""
        data class IntPair(val a: Int, val b: Int) {
            fun sum(): Int {
                return a + b
            }
        }
        fun main(): Unit {
            val p = IntPair(10, 20)
            println(p.sum())
        }
        """)
        XCTAssertTrue(ir.contains("define internal i64 @IntPair_sum(ptr %this"), "Method should have this param")
        XCTAssertTrue(ir.contains("rockit_object_get_field"), "Method should access fields via this")
    }

    func testStringFieldRoundTrip() {
        let ir = emitLLVM("""
        data class Named(val name: String)
        fun main(): Unit {
            val n = Named("hello")
            println(n.name)
        }
        """)
        XCTAssertTrue(ir.contains("ptrtoint ptr"), "Should convert ptr to i64 for storage")
        XCTAssertTrue(ir.contains("inttoptr i64"), "Should convert i64 back to ptr for retrieval")
        XCTAssertTrue(ir.contains("rockit_println_string"), "Should print as string")
    }

    // MARK: - Exception Handling (Phase 1G)

    func testTryCatch() {
        let ir = emitLLVM("""
        fun main(): Unit {
            try {
                throw "error"
            } catch (e: String) {
                println(e)
            }
        }
        """)
        XCTAssertTrue(ir.contains("rockit_exc_push"), "Should push exception frame")
        XCTAssertTrue(ir.contains("_setjmp"), "Should call _setjmp")
        XCTAssertTrue(ir.contains("rockit_exc_throw"), "Should call throw")
        XCTAssertTrue(ir.contains("rockit_exc_get"), "Should get exception value in catch")
    }

    func testTryEndPops() {
        let ir = emitLLVM("""
        fun main(): Unit {
            try {
                println(42)
            } catch (e: String) {
                println(e)
            }
            println("done")
        }
        """)
        XCTAssertTrue(ir.contains("rockit_exc_pop"), "Should pop frame on normal path")
    }

    // MARK: - Type Checking (Phase 1E)

    func testTypeCheckEmitsIsType() {
        let ir = emitLLVM("""
        class Animal(val name: String)

        fun check(a: Animal): Bool {
            return a is Animal
        }

        fun main(): Unit {
            val a = Animal("Rex")
            println(check(a))
        }
        """)
        XCTAssertTrue(ir.contains("rockit_is_type"), "Should emit rockit_is_type call for 'is' operator")
    }

    func testTypeCheckEmitsTypeNameGlobal() {
        let ir = emitLLVM("""
        class Dog(val name: String)

        fun check(d: Dog): Bool {
            return d is Dog
        }

        fun main(): Unit {
            val d = Dog("Rex")
            println(check(d))
        }
        """)
        // The target type name should be interned as a global constant
        XCTAssertTrue(ir.contains("Dog"), "Should reference Dog type name")
    }

    func testTypeCastEmitsPanicOnFailure() {
        let ir = emitLLVM("""
        class Foo(val x: Int)

        fun cast(f: Foo): Foo {
            return f as Foo
        }

        fun main(): Unit {
            val f = Foo(1)
            println(cast(f))
        }
        """)
        XCTAssertTrue(ir.contains("rockit_is_type"), "Type cast should check type first")
        XCTAssertTrue(ir.contains("rockit_panic"), "Type cast should panic on failure")
        XCTAssertTrue(ir.contains("cast.ok"), "Should have cast success label")
        XCTAssertTrue(ir.contains("cast.fail"), "Should have cast failure label")
    }

    func testTypeHierarchyTable() {
        let ir = emitLLVM("""
        sealed class Shape
        class Circle(val r: Int) : Shape
        class Rect(val w: Int, val h: Int) : Shape

        fun main(): Unit {
            val c = Circle(5)
            println(c is Shape)
        }
        """)
        XCTAssertTrue(ir.contains("rockit_type_hierarchy"), "Should emit type hierarchy table for sealed classes")
        XCTAssertTrue(ir.contains("rockit_set_type_hierarchy"), "Should call set_type_hierarchy in constructor")
    }

    func testMIRTypeHierarchy() {
        // Verify that MIR preserves class hierarchy information
        let source = """
        sealed class Shape
        class Circle(val r: Int) : Shape {
            fun area(): Int { return r * r * 3 }
        }
        class Rect(val w: Int, val h: Int) : Shape {
            fun area(): Int { return w * h }
        }

        fun main(): Unit { }
        """
        let diagnostics = DiagnosticEngine()
        let lexer = Lexer(source: source, fileName: "test.rok", diagnostics: diagnostics)
        let tokens = lexer.tokenize()
        let parser = Parser(tokens: tokens, diagnostics: diagnostics)
        let ast = parser.parse()
        let checker = TypeChecker(ast: ast, diagnostics: diagnostics)
        let result = checker.check()
        let lowering = MIRLowering(typeCheckResult: result)
        let module = lowering.lower()

        let shapeDecl = module.types.first { $0.name == "Shape" }
        let circleDecl = module.types.first { $0.name == "Circle" }
        let rectDecl = module.types.first { $0.name == "Rect" }

        XCTAssertNotNil(shapeDecl, "Shape type decl should exist")
        XCTAssertNotNil(circleDecl, "Circle type decl should exist")
        XCTAssertNotNil(rectDecl, "Rect type decl should exist")

        XCTAssertEqual(shapeDecl?.sealedSubclasses, ["Circle", "Rect"],
                      "Shape should have sealed subclasses. Got: \(shapeDecl?.sealedSubclasses ?? [])")
        XCTAssertEqual(circleDecl?.parentType, "Shape",
                      "Circle should have Shape as parent. Got: \(circleDecl?.parentType ?? "nil")")
        XCTAssertEqual(rectDecl?.parentType, "Shape",
                      "Rect should have Shape as parent. Got: \(rectDecl?.parentType ?? "nil")")
    }

    func testDynamicDispatch() {
        let ir = emitLLVM("""
        sealed class Shape
        class Circle(val r: Int) : Shape {
            fun area(): Int { return r * r * 3 }
        }
        class Rect(val w: Int, val h: Int) : Shape {
            fun area(): Int { return w * h }
        }

        fun printArea(s: Shape): Unit {
            println(s.area())
        }

        fun main(): Unit {
            val c = Circle(5)
            printArea(c)
        }
        """)
        // Dynamic dispatch should be generated for s.area() in printArea
        XCTAssertTrue(ir.contains("dispatch.check"), "Should emit dispatch labels for polymorphic method call")
        XCTAssertTrue(ir.contains("Circle_area"), "Should reference Circle.area in dispatch")
        XCTAssertTrue(ir.contains("Rect_area"), "Should reference Rect.area in dispatch")
    }

    // MARK: - Collections (Phase 1F)

    func testListOf() {
        let ir = emitLLVM("""
        fun main(): Unit {
            val nums = listOf(1, 2, 3)
            println(nums.size())
        }
        """)
        XCTAssertTrue(ir.contains("rockit_list_create"), "Should create list")
        XCTAssertTrue(ir.contains("rockit_list_append"), "Should append elements")
        XCTAssertTrue(ir.contains("rockit_list_size"), "Should call size")
    }

    // MARK: - Actor Tests

    func testActorMethodGetsThisParam() {
        let ir = emitLLVM("""
        actor Counter {
            var count: Int = 0
            fun increment(): Unit {
                count = count + 1
            }
        }
        fun main(): Unit {
            val c = Counter()
            c.increment()
        }
        """)
        XCTAssertTrue(ir.contains("define internal void @Counter_increment(ptr %this)"),
                       "Actor method should have implicit this parameter")
    }

    func testActorFieldAssignment() {
        let ir = emitLLVM("""
        actor Counter {
            var count: Int = 0
            fun increment(): Unit {
                count = count + 1
            }
        }
        fun main(): Unit {
            val c = Counter()
            c.increment()
        }
        """)
        XCTAssertTrue(ir.contains("rockit_object_set_field"),
                       "Bare field assignment in actor method should emit set_field")
        XCTAssertTrue(ir.contains("rockit_object_get_field"),
                       "Bare field read in actor method should emit get_field")
    }

    func testActorFieldRead() {
        let ir = emitLLVM("""
        actor Counter {
            var count: Int = 0
            fun getCount(): Int {
                return count
            }
        }
        fun main(): Unit {
            val c = Counter()
            println(c.getCount())
        }
        """)
        XCTAssertTrue(ir.contains("define internal i64 @Counter_getCount(ptr %this)"),
                       "Actor getter should have this param and return i64")
        XCTAssertTrue(ir.contains("rockit_object_get_field"),
                       "Bare field read should use get_field")
    }

    func testAwaitParsesAsPassthrough() {
        let ir = emitLLVM("""
        suspend fun compute(): Int {
            return 42
        }
        suspend fun main(): Unit {
            val result = await compute()
            println(result)
        }
        """)
        XCTAssertTrue(ir.contains("call i64 @compute"),
                       "await should pass through to the underlying call")
    }

    // MARK: - Stack Promotion (Escape Analysis)

    func testStackPromotionForNonEscapingValueType() {
        let ir = emitLLVM("""
        data class Point(x: Int, y: Int)
        fun main(): Unit {
            val p = Point(1, 2)
            val sum = p.x + p.y
            println(sum)
        }
        """)
        XCTAssertTrue(ir.contains("alloca i8, i64 40"),
                      "Non-escaping value type should be stack-allocated (40 = 24 header + 2*8 fields)")
        XCTAssertFalse(ir.contains("call ptr @rockit_object_alloc"),
                       "Non-escaping value type should NOT use heap allocation")
    }

    func testNoStackPromotionWhenReturned() {
        let ir = emitLLVM("""
        data class Point(x: Int, y: Int)
        fun makePoint(): Point {
            return Point(1, 2)
        }
        fun main(): Unit {
            val p = makePoint()
            println(p.x)
        }
        """)
        XCTAssertTrue(ir.contains("rockit_object_alloc"),
                      "Returned value type should use heap allocation")
    }

    func testStackPromotionWithInterproceduralAnalysis() {
        let ir = emitLLVM("""
        data class Point(x: Int, y: Int)
        fun readX(p: Point): Int {
            return p.x
        }
        fun main(): Unit {
            val p = Point(3, 4)
            println(readX(p))
        }
        """)
        // p is passed to readX, but readX only reads fields — doesn't escape
        XCTAssertTrue(ir.contains("alloca i8, i64 40"),
                      "Value type passed to read-only function should be stack-promoted")
    }
}
