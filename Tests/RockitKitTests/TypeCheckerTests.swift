// TypeCheckerTests.swift
// RockitKit Tests
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import XCTest
@testable import RockitKit

final class TypeCheckerTests: XCTestCase {

    // MARK: - Helpers

    /// Lex → Parse → Type-check, return the result
    private func typeCheck(_ source: String) -> (TypeCheckResult, DiagnosticEngine) {
        let diag = DiagnosticEngine()
        let lexer = Lexer(source: source, diagnostics: diag)
        let tokens = lexer.tokenize()
        let parser = Parser(tokens: tokens, diagnostics: diag)
        let ast = parser.parse()
        let checker = TypeChecker(ast: ast, diagnostics: diag)
        let result = checker.check()
        return (result, diag)
    }

    /// Type-check and assert no errors
    private func checkOK(_ source: String) -> TypeCheckResult {
        let (result, diag) = typeCheck(source)
        if diag.hasErrors {
            let errors = diag.diagnostics.filter { $0.severity == .error }
            XCTFail("Unexpected type errors: \(errors.map { $0.description })")
        }
        return result
    }

    /// Type-check and assert there ARE errors
    private func checkWithErrors(_ source: String) -> TypeCheckResult {
        let (result, diag) = typeCheck(source)
        XCTAssertTrue(diag.hasErrors, "Expected type errors but got none")
        return result
    }

    /// Type-check and return the number of errors
    private func errorCount(_ source: String) -> Int {
        let (_, diag) = typeCheck(source)
        return diag.errorCount
    }

    /// Check and assert a specific error message substring exists
    private func assertError(_ source: String, contains substring: String) {
        let (_, diag) = typeCheck(source)
        let errorMessages = diag.diagnostics.filter { $0.severity == .error }.map { $0.message }
        XCTAssertTrue(
            errorMessages.contains(where: { $0.contains(substring) }),
            "Expected error containing '\(substring)', got: \(errorMessages)"
        )
    }

    // MARK: - Type.swift Unit Tests

    func testTypeEquality() {
        XCTAssertEqual(Type.int, Type.int)
        XCTAssertEqual(Type.string, Type.string)
        XCTAssertNotEqual(Type.int, Type.string)
        XCTAssertEqual(Type.nullable(.int), Type.nullable(.int))
        XCTAssertNotEqual(Type.int, Type.nullable(.int))
    }

    func testTypeIsNullable() {
        XCTAssertFalse(Type.int.isNullable)
        XCTAssertFalse(Type.string.isNullable)
        XCTAssertTrue(Type.nullable(.int).isNullable)
        XCTAssertTrue(Type.nullType.isNullable)
    }

    func testTypeUnwrapNullable() {
        XCTAssertEqual(Type.nullable(.int).unwrapNullable, .int)
        XCTAssertEqual(Type.int.unwrapNullable, .int) // No-op on non-nullable
        XCTAssertEqual(Type.nullable(.string).unwrapNullable, .string)
    }

    func testTypeAsNullable() {
        XCTAssertEqual(Type.int.asNullable, .nullable(.int))
        XCTAssertEqual(Type.nullable(.int).asNullable, .nullable(.int)) // Already nullable
    }

    func testTypeIsNumeric() {
        XCTAssertTrue(Type.int.isNumeric)
        XCTAssertTrue(Type.int32.isNumeric)
        XCTAssertTrue(Type.int64.isNumeric)
        XCTAssertTrue(Type.float.isNumeric)
        XCTAssertTrue(Type.float64.isNumeric)
        XCTAssertTrue(Type.double.isNumeric)
        XCTAssertFalse(Type.string.isNumeric)
        XCTAssertFalse(Type.bool.isNumeric)
    }

    func testTypeDescription() {
        XCTAssertEqual(Type.int.description, "Int")
        XCTAssertEqual(Type.nullable(.string).description, "String?")
        XCTAssertEqual(Type.function(parameterTypes: [.int, .string], returnType: .bool).description,
                       "(Int, String) -> Bool")
        XCTAssertEqual(Type.classType(name: "User", typeArguments: []).description, "User")
        XCTAssertEqual(Type.classType(name: "List", typeArguments: [.int]).description, "List<Int>")
        XCTAssertEqual(Type.error.description, "<error>")
    }

    func testExpressionID() {
        let span1 = SourceSpan(
            start: SourceLocation(line: 1, column: 1),
            end: SourceLocation(line: 1, column: 5)
        )
        let span2 = SourceSpan(
            start: SourceLocation(line: 1, column: 1),
            end: SourceLocation(line: 1, column: 10)
        )
        let span3 = SourceSpan(
            start: SourceLocation(line: 2, column: 1),
            end: SourceLocation(line: 2, column: 5)
        )
        // Same start position → same ID
        XCTAssertEqual(ExpressionID(span1), ExpressionID(span2))
        // Different start position → different ID
        XCTAssertNotEqual(ExpressionID(span1), ExpressionID(span3))
    }

    // MARK: - SymbolTable Tests

    func testSymbolTableScopeChain() {
        let st = SymbolTable()
        let sym = Symbol(name: "x", type: .int, kind: .variable(isMutable: false))
        st.define(sym)

        XCTAssertNotNil(st.lookup("x"))

        st.pushScope()
        // Should see parent scope
        XCTAssertNotNil(st.lookup("x"))

        // Define in child scope
        let sym2 = Symbol(name: "y", type: .string, kind: .variable(isMutable: true))
        st.define(sym2)
        XCTAssertNotNil(st.lookup("y"))

        st.popScope()
        // y should not be visible from parent
        XCTAssertNil(st.lookup("y"))
        // x still visible
        XCTAssertNotNil(st.lookup("x"))
    }

    func testSymbolTableRedefinition() {
        let st = SymbolTable()
        let sym1 = Symbol(name: "x", type: .int, kind: .variable(isMutable: false))
        XCTAssertTrue(st.define(sym1))
        let sym2 = Symbol(name: "x", type: .string, kind: .variable(isMutable: true))
        XCTAssertFalse(st.define(sym2)) // Redefinition fails
    }

    func testBuiltinTypesRegistered() {
        let st = SymbolTable()
        XCTAssertNotNil(st.lookup("Int"))
        XCTAssertNotNil(st.lookup("String"))
        XCTAssertNotNil(st.lookup("Bool"))
        XCTAssertNotNil(st.lookup("List"))
        XCTAssertNotNil(st.lookup("println"))
    }

    // MARK: - Property Type Checking

    func testPropertyWithTypeAnnotation() {
        _ = checkOK("val x: Int = 42")
    }

    func testPropertyTypeInference() {
        _ = checkOK("val x = 42")
    }

    func testPropertyTypeMismatch() {
        assertError("val x: String = 42", contains: "cannot assign")
    }

    func testPropertyNoTypeNoInit() {
        assertError("val x", contains: "must have a type annotation or initializer")
    }

    func testMutableProperty() {
        _ = checkOK("var x: Int = 10")
    }

    // MARK: - Function Type Checking

    func testSimpleFunction() {
        _ = checkOK("fun greet(name: String): Unit { println(name) }")
    }

    func testFunctionWithReturnType() {
        _ = checkOK("fun add(a: Int, b: Int): Int = a + b")
    }

    func testFunctionDefaultValue() {
        _ = checkOK("fun greet(name: String = \"World\"): Unit { println(name) }")
    }

    func testFunctionDefaultValueTypeMismatch() {
        assertError(
            "fun greet(name: String = 42): Unit { println(name) }",
            contains: "default value"
        )
    }

    // MARK: - Expression Type Checking

    func testIntLiteral() {
        let result = checkOK("val x = 42")
        // The type map should contain entries
        XCTAssertFalse(result.typeMap.isEmpty)
    }

    func testStringLiteral() {
        _ = checkOK("val x = \"hello\"")
    }

    func testBoolLiteral() {
        _ = checkOK("val x = true")
    }

    func testFloatLiteral() {
        _ = checkOK("val x = 3.14")
    }

    func testArithmeticOperators() {
        _ = checkOK("val x = 1 + 2")
        _ = checkOK("val x = 10 - 5")
        _ = checkOK("val x = 3 * 4")
        _ = checkOK("val x = 10 / 3")
        _ = checkOK("val x = 10 % 3")
    }

    func testStringConcatenation() {
        _ = checkOK("""
        val x = "hello" + " world"
        """)
    }

    func testArithmeticOnNonNumeric() {
        assertError("val x = true + false", contains: "operator '+'")
    }

    func testComparisonOperators() {
        _ = checkOK("val x = 1 < 2")
        _ = checkOK("val x = 1 <= 2")
        _ = checkOK("val x = 1 > 2")
        _ = checkOK("val x = 1 >= 2")
    }

    func testEqualityOperators() {
        _ = checkOK("val x = 1 == 2")
        _ = checkOK("val x = 1 != 2")
        _ = checkOK("""
        val x = "a" == "b"
        """)
    }

    func testLogicalOperators() {
        _ = checkOK("val x = true && false")
        _ = checkOK("val x = true || false")
    }

    func testLogicalOnNonBool() {
        assertError("val x = 1 && 2", contains: "must be Bool")
    }

    func testUnaryNegate() {
        _ = checkOK("val x = -42")
    }

    func testUnaryNot() {
        _ = checkOK("val x = !true")
    }

    func testUnaryNegateOnNonNumeric() {
        assertError("val x = -true", contains: "unary '-'")
    }

    func testUnaryNotOnNonBool() {
        assertError("""
        val x = !"hello"
        """, contains: "unary '!'")
    }

    // MARK: - Null Safety

    func testNullableType() {
        _ = checkOK("val x: String? = null")
    }

    func testNullToNonNullable() {
        assertError("val x: String = null", contains: "cannot assign")
    }

    func testNonNullAssert() {
        _ = checkOK("""
        val x: String? = null
        val y: String = x!!
        """)
    }

    func testNonNullAssertWarning() {
        // !! on non-nullable should produce a warning (not error)
        let (_, diag) = typeCheck("val x: Int = 42\nval y = x!!")
        let warnings = diag.diagnostics.filter { $0.severity == .warning }
        XCTAssertTrue(warnings.contains(where: { $0.message.contains("unnecessary non-null assertion") }))
    }

    func testElvisOperator() {
        _ = checkOK("""
        val x: String? = null
        val y = x ?: "default"
        """)
    }

    // MARK: - Type Check / Cast

    func testTypeCheck() {
        _ = checkOK("""
        val x: String = "hello"
        val y = x is String
        """)
    }

    // MARK: - Control Flow

    func testIfConditionMustBeBool() {
        assertError("""
        fun test(): Unit {
            val x = 42
            if (x) { println("yes") }
        }
        """, contains: "must be Bool")
    }

    func testWhileConditionMustBeBool() {
        assertError("""
        fun test(): Unit {
            var x = 42
            while (x) { x = x - 1 }
        }
        """, contains: "must be Bool")
    }

    func testForLoop() {
        _ = checkOK("""
        fun test(): Unit {
            for (i in 1..10) {
                println("hello")
            }
        }
        """)
    }

    // MARK: - Assignment

    func testAssignToVal() {
        assertError("""
        fun test(): Unit {
            val x = 42
            x = 10
        }
        """, contains: "cannot assign to 'val'")
    }

    func testAssignToVar() {
        _ = checkOK("""
        fun test(): Unit {
            var x = 42
            x = 10
        }
        """)
    }

    func testCompoundAssignment() {
        _ = checkOK("""
        fun test(): Unit {
            var x = 42
            x += 10
        }
        """)
    }

    // MARK: - Class Declarations

    func testDataClass() {
        _ = checkOK("""
        data class User(val name: String, val age: Int)
        """)
    }

    func testClassWithMembers() {
        _ = checkOK("""
        class Counter {
            var count: Int = 0
            fun increment(): Unit {
                count += 1
            }
        }
        """)
    }

    // MARK: - Interface Declarations

    func testInterface() {
        _ = checkOK("""
        interface Printable {
            fun print(): Unit
        }
        """)
    }

    // MARK: - Enum Declarations

    func testEnumClass() {
        _ = checkOK("""
        enum class Color {
            RED,
            GREEN,
            BLUE
        }
        """)
    }

    // MARK: - Object Declarations

    func testObjectDeclaration() {
        _ = checkOK("""
        object Logger {
            fun log(msg: String): Unit {
                println(msg)
            }
        }
        """)
    }

    // MARK: - Actor Declarations

    func testActorDeclaration() {
        _ = checkOK("""
        actor Counter {
            var count: Int = 0
            fun increment(): Unit {
                count += 1
            }
        }
        """)
    }

    // MARK: - View Declarations

    func testViewDeclaration() {
        _ = checkOK("""
        view Greeting(name: String) {
            println(name)
        }
        """)
    }

    // MARK: - Sealed Class Exhaustiveness

    func testSealedClassExhaustiveWhen() {
        _ = checkOK("""
        sealed class Shape
        class Circle : Shape
        class Square : Shape

        fun describe(shape: Shape): String = when (shape) {
            is Circle -> "round"
            is Square -> "boxy"
        }
        """)
    }

    func testSealedClassNonExhaustiveWhen() {
        assertError("""
        sealed class Shape
        class Circle : Shape
        class Square : Shape
        class Triangle : Shape

        fun describe(shape: Shape): String = when (shape) {
            is Circle -> "round"
            is Square -> "boxy"
        }
        """, contains: "not exhaustive")
    }

    func testSealedClassWithElse() {
        _ = checkOK("""
        sealed class Shape
        class Circle : Shape
        class Square : Shape
        class Triangle : Shape

        fun describe(shape: Shape): String = when (shape) {
            is Circle -> "round"
            else -> "other"
        }
        """)
    }

    // MARK: - Enum Exhaustiveness

    func testEnumExhaustiveWhen() {
        _ = checkOK("""
        enum class Color { RED, GREEN, BLUE }
        fun describe(c: Color): Unit = when (c) {
            Color.RED -> println("red")
            Color.GREEN -> println("green")
            Color.BLUE -> println("blue")
        }
        """)
    }

    func testEnumNonExhaustiveWhen() {
        assertError("""
        enum class Color { RED, GREEN, BLUE }
        fun describe(c: Color): Unit = when (c) {
            Color.RED -> println("red")
            Color.GREEN -> println("green")
        }
        """, contains: "not exhaustive")
    }

    func testEnumWithElseWhen() {
        _ = checkOK("""
        enum class Color { RED, GREEN, BLUE }
        fun describe(c: Color): Unit = when (c) {
            Color.RED -> println("red")
            else -> println("other")
        }
        """)
    }

    // MARK: - Numeric Promotion

    func testNumericPromotion() {
        _ = checkOK("""
        val x: Int = 42
        val y: Double = 3.14
        val z = x + y
        """)
    }

    // MARK: - Redeclaration

    func testRedeclaration() {
        assertError("""
        val x = 42
        val x = "hello"
        """, contains: "redeclaration")
    }

    func testTypeRedeclaration() {
        assertError("""
        class Foo
        class Foo
        """, contains: "redeclaration")
    }

    // MARK: - Unresolved Reference

    func testUnresolvedReference() {
        assertError("""
        val x = unknownVar
        """, contains: "unresolved reference")
    }

    // MARK: - String Interpolation

    func testStringInterpolation() {
        _ = checkOK("""
        val name = "World"
        val greeting = "Hello, ${name}!"
        """)
    }

    // MARK: - Range Expressions

    func testRangeExpression() {
        _ = checkOK("val r = 1..10")
    }

    func testRangeWithNonInteger() {
        assertError("""
        val r = 1.5..10.5
        """, contains: "range start must be integer")
    }

    // MARK: - Integration Test

    func testHelloRockitSnippet() {
        // A representative Moon program
        let source = """
        package com.darkmatter.hello

        data class User(val name: String, val age: Int)

        fun greet(user: User): String = "Hello, ${user.name}!"

        fun main(): Unit {
            val user = User("Alice", 30)
            val greeting = greet(user)
            println(greeting)

            val numbers = listOf(1, 2, 3)
            for (n in 1..10) {
                println("number")
            }

            var counter = 0
            while (counter < 10) {
                counter += 1
            }

            val result = if (counter == 10) {
                "done"
            } else {
                "not done"
            }
        }
        """
        _ = checkOK(source)
    }

    // MARK: - Structured Concurrency Tests

    func testAwaitInsideSuspendFunctionIsOK() {
        let source = """
        suspend fun fetchData(): Int {
            return 42
        }
        suspend fun main(): Unit {
            val x = await fetchData()
        }
        """
        _ = checkOK(source)
    }

    func testAwaitInsideAsyncFunctionIsOK() {
        let source = """
        async fun fetchData(): Int {
            return 42
        }
        async fun main(): Unit {
            val x = await fetchData()
        }
        """
        _ = checkOK(source)
    }

    func testAwaitOutsideSuspendContextIsError() {
        assertError("""
        suspend fun fetchData(): Int {
            return 42
        }
        fun main(): Unit {
            val x = await fetchData()
        }
        """, contains: "'await' can only be used inside a suspend or async function")
    }

    func testAwaitInsideConcurrentBlockIsOK() {
        let source = """
        suspend fun fetchData(): Int {
            return 42
        }
        fun main(): Unit {
            concurrent {
                val x = await fetchData()
            }
        }
        """
        _ = checkOK(source)
    }

    func testCallingSuspendFunctionWithoutAwaitWarns() {
        let (_, diag) = typeCheck("""
        suspend fun fetchData(): Int {
            return 42
        }
        fun main(): Unit {
            fetchData()
        }
        """)
        let warnings = diag.diagnostics.filter { $0.severity == .warning }
        XCTAssertTrue(
            warnings.contains(where: { $0.message.contains("without 'await'") }),
            "Expected warning about calling suspend function without await, got: \(warnings.map { $0.message })"
        )
    }

    func testSuspendFunctionCallingSuspendIsOK() {
        let source = """
        suspend fun inner(): Int {
            return 42
        }
        suspend fun outer(): Int {
            val x = await inner()
            return x
        }
        """
        _ = checkOK(source)
    }
}
