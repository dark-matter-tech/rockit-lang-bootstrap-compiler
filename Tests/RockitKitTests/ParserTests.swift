// ParserTests.swift
// RockitKit Tests
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import XCTest
@testable import RockitKit

final class ParserTests: XCTestCase {

    // MARK: - Helpers

    /// Lex + parse, return SourceFile and DiagnosticEngine
    private func parseSource(_ source: String) -> (SourceFile, DiagnosticEngine) {
        let diag = DiagnosticEngine()
        let lexer = Lexer(source: source, diagnostics: diag)
        let tokens = lexer.tokenize()
        let parser = Parser(tokens: tokens, diagnostics: diag)
        let file = parser.parse()
        return (file, diag)
    }

    /// Parse and assert no errors
    private func parseOK(_ source: String) -> SourceFile {
        let (file, diag) = parseSource(source)
        if diag.hasErrors {
            XCTFail("Unexpected parse errors: \(diag.diagnostics.map { $0.description })")
        }
        return file
    }

    /// Parse and assert there ARE errors
    private func parseWithErrors(_ source: String) -> SourceFile {
        let (file, diag) = parseSource(source)
        XCTAssertTrue(diag.hasErrors, "Expected parse errors but got none")
        return file
    }

    /// Helper to get the first declaration
    private func firstDecl(_ source: String) -> Declaration {
        let file = parseOK(source)
        XCTAssertFalse(file.declarations.isEmpty, "Expected at least one declaration")
        return file.declarations[0]
    }

    /// Helper to extract FunctionDecl
    private func funcDecl(_ source: String) -> FunctionDecl {
        if case .function(let f) = firstDecl(source) { return f }
        XCTFail("Expected function declaration"); fatalError()
    }

    /// Helper to extract PropertyDecl
    private func propDecl(_ source: String) -> PropertyDecl {
        if case .property(let p) = firstDecl(source) { return p }
        XCTFail("Expected property declaration"); fatalError()
    }

    /// Helper to extract ClassDecl
    private func classDecl(_ source: String) -> ClassDecl {
        if case .classDecl(let c) = firstDecl(source) { return c }
        XCTFail("Expected class declaration"); fatalError()
    }

    // MARK: - Package & Imports

    func testPackageDeclaration() {
        let file = parseOK("package com.darkmatter.hello")
        XCTAssertNotNil(file.packageDecl)
        XCTAssertEqual(file.packageDecl?.path, ["com", "darkmatter", "hello"])
    }

    func testImportDeclaration() {
        let file = parseOK("import rockit.core.List")
        XCTAssertEqual(file.imports.count, 1)
        XCTAssertEqual(file.imports[0].path, ["rockit", "core", "List"])
    }

    func testMultipleImports() {
        let file = parseOK("""
        import rockit.core.List
        import rockit.http.HttpClient
        """)
        XCTAssertEqual(file.imports.count, 2)
        XCTAssertEqual(file.imports[0].path, ["rockit", "core", "List"])
        XCTAssertEqual(file.imports[1].path, ["rockit", "http", "HttpClient"])
    }

    func testNoPackage() {
        let file = parseOK("val x = 1")
        XCTAssertNil(file.packageDecl)
    }

    func testPackageAndImports() {
        let file = parseOK("""
        package com.example
        import rockit.core.List
        val x = 1
        """)
        XCTAssertEqual(file.packageDecl?.path, ["com", "example"])
        XCTAssertEqual(file.imports.count, 1)
        XCTAssertEqual(file.declarations.count, 1)
    }

    // MARK: - Property Declarations

    func testValWithType() {
        let p = propDecl("val name: String = \"Moon\"")
        XCTAssertTrue(p.isVal)
        XCTAssertEqual(p.name, "name")
        if case .simple(let name, _, _) = p.type {
            XCTAssertEqual(name, "String")
        } else {
            XCTFail("Expected simple type")
        }
        if case .stringLiteral(let s, _) = p.initializer {
            XCTAssertEqual(s, "Moon")
        } else {
            XCTFail("Expected string literal initializer")
        }
    }

    func testValWithInference() {
        let p = propDecl("val version = 1.0")
        XCTAssertTrue(p.isVal)
        XCTAssertEqual(p.name, "version")
        XCTAssertNil(p.type)
        if case .floatLiteral(let v, _) = p.initializer {
            XCTAssertEqual(v, 1.0)
        } else {
            XCTFail("Expected float literal")
        }
    }

    func testVarDeclaration() {
        let p = propDecl("var counter: Int = 0")
        XCTAssertFalse(p.isVal)
        XCTAssertEqual(p.name, "counter")
    }

    func testNullableType() {
        let p = propDecl("val optional: String? = null")
        XCTAssertEqual(p.name, "optional")
        if case .nullable(let inner, _) = p.type,
           case .simple(let name, _, _) = inner {
            XCTAssertEqual(name, "String")
        } else {
            XCTFail("Expected nullable String type")
        }
        if case .nullLiteral = p.initializer {} else {
            XCTFail("Expected null literal")
        }
    }

    func testHexLiteral() {
        let p = propDecl("val hex = 0xFF")
        if case .intLiteral(let v, _) = p.initializer {
            XCTAssertEqual(v, 255)
        } else {
            XCTFail("Expected int literal")
        }
    }

    // MARK: - Function Declarations

    func testSimpleFunction() {
        let f = funcDecl("""
        fun add(a: Int, b: Int): Int {
            return a + b
        }
        """)
        XCTAssertEqual(f.name, "add")
        XCTAssertEqual(f.parameters.count, 2)
        XCTAssertEqual(f.parameters[0].name, "a")
        XCTAssertEqual(f.parameters[1].name, "b")
        if case .simple(let name, _, _) = f.returnType {
            XCTAssertEqual(name, "Int")
        } else {
            XCTFail("Expected Int return type")
        }
        if case .block(let b) = f.body {
            XCTAssertEqual(b.statements.count, 1)
        } else {
            XCTFail("Expected block body")
        }
    }

    func testExpressionBodyFunction() {
        let f = funcDecl("fun multiply(a: Int, b: Int): Int = a * b")
        XCTAssertEqual(f.name, "multiply")
        if case .expression(let e) = f.body,
           case .binary(_, let op, _, _) = e {
            XCTAssertEqual(op, .times)
        } else {
            XCTFail("Expected expression body with multiplication")
        }
    }

    func testDefaultParameters() {
        let f = funcDecl("""
        fun greet(name: String, greeting: String = "Hello"): String {
            return name
        }
        """)
        XCTAssertEqual(f.parameters.count, 2)
        XCTAssertNil(f.parameters[0].defaultValue)
        XCTAssertNotNil(f.parameters[1].defaultValue)
        if case .stringLiteral(let s, _) = f.parameters[1].defaultValue {
            XCTAssertEqual(s, "Hello")
        } else {
            XCTFail("Expected string default value")
        }
    }

    func testSuspendFunction() {
        let f = funcDecl("""
        suspend fun fetchUser(id: String): User {
            return id
        }
        """)
        XCTAssertTrue(f.modifiers.contains(.suspend))
        XCTAssertEqual(f.name, "fetchUser")
    }

    func testFunctionNoReturnType() {
        let f = funcDecl("fun main() { }")
        XCTAssertEqual(f.name, "main")
        XCTAssertNil(f.returnType)
        XCTAssertEqual(f.parameters.count, 0)
    }

    func testAbstractFunction() {
        let file = parseOK("""
        interface Foo {
            fun bar(): Int
        }
        """)
        if case .interfaceDecl(let i) = file.declarations[0],
           case .function(let f) = i.members[0] {
            XCTAssertEqual(f.name, "bar")
            XCTAssertNil(f.body)
        } else {
            XCTFail("Expected interface with abstract function")
        }
    }

    // MARK: - Class Declarations

    func testDataClass() {
        let c = classDecl("data class User(val id: String, val name: String)")
        XCTAssertTrue(c.modifiers.contains(.data))
        XCTAssertEqual(c.name, "User")
        XCTAssertEqual(c.constructorParams.count, 2)
        XCTAssertTrue(c.constructorParams[0].isVal)
        XCTAssertEqual(c.constructorParams[0].name, "id")
        XCTAssertEqual(c.constructorParams[1].name, "name")
    }

    func testSealedClass() {
        let file = parseOK("""
        sealed class Result<out T> {
            data class Success<T>(val data: T) : Result<T>()
            data class Error(val message: String) : Result<Nothing>()
            object Loading : Result<Nothing>()
        }
        """)
        if case .classDecl(let c) = file.declarations[0] {
            XCTAssertTrue(c.modifiers.contains(.sealed))
            XCTAssertEqual(c.name, "Result")
            XCTAssertEqual(c.typeParameters.count, 1)
            XCTAssertEqual(c.typeParameters[0].name, "T")
            XCTAssertNotNil(c.typeParameters[0].variance)
            XCTAssertEqual(c.members.count, 3)
        } else {
            XCTFail("Expected sealed class")
        }
    }

    func testClassInheritance() {
        let c = classDecl("class Foo : Bar()")
        XCTAssertEqual(c.name, "Foo")
        XCTAssertEqual(c.superTypes.count, 1)
        if case .simple(let name, _, _) = c.superTypes[0] {
            XCTAssertEqual(name, "Bar")
        }
    }

    func testClassWithBody() {
        let file = parseOK("""
        class Foo {
            fun bar(): Int = 42
        }
        """)
        if case .classDecl(let c) = file.declarations[0] {
            XCTAssertEqual(c.members.count, 1)
            if case .function(let f) = c.members[0] {
                XCTAssertEqual(f.name, "bar")
            }
        }
    }

    func testObjectDeclaration() {
        let file = parseOK("object Singleton { }")
        if case .objectDecl(let o) = file.declarations[0] {
            XCTAssertEqual(o.name, "Singleton")
        } else {
            XCTFail("Expected object declaration")
        }
    }

    // MARK: - Interface Declarations

    func testInterface() {
        let file = parseOK("""
        interface Serializable {
            fun toBytes(): ByteArray
        }
        """)
        if case .interfaceDecl(let i) = file.declarations[0] {
            XCTAssertEqual(i.name, "Serializable")
            XCTAssertEqual(i.members.count, 1)
        } else {
            XCTFail("Expected interface")
        }
    }

    func testInterfaceDefaultMethod() {
        let file = parseOK("""
        interface Foo {
            fun bar(): String = "default"
        }
        """)
        if case .interfaceDecl(let i) = file.declarations[0],
           case .function(let f) = i.members[0] {
            XCTAssertNotNil(f.body)
        }
    }

    // MARK: - Actor Declarations

    func testActorDeclaration() {
        let file = parseOK("""
        actor ShoppingCart {
            fun add(item: String) { }
        }
        """)
        if case .actorDecl(let a) = file.declarations[0] {
            XCTAssertEqual(a.name, "ShoppingCart")
            XCTAssertEqual(a.members.count, 1)
        } else {
            XCTFail("Expected actor declaration")
        }
    }

    // MARK: - View Declarations

    func testViewDeclaration() {
        let file = parseOK("""
        view ProductCard(product: String) {
            product
        }
        """)
        if case .viewDecl(let v) = file.declarations[0] {
            XCTAssertEqual(v.name, "ProductCard")
            XCTAssertEqual(v.parameters.count, 1)
            XCTAssertEqual(v.parameters[0].name, "product")
        } else {
            XCTFail("Expected view declaration")
        }
    }

    // MARK: - Navigation & Theme

    func testNavigationDeclaration() {
        let file = parseOK("""
        navigation App {
            x
        }
        """)
        if case .navigationDecl(let n) = file.declarations[0] {
            XCTAssertEqual(n.name, "App")
        } else {
            XCTFail("Expected navigation declaration")
        }
    }

    func testThemeDeclaration() {
        let file = parseOK("""
        theme AppTheme {
            x
        }
        """)
        if case .themeDecl(let t) = file.declarations[0] {
            XCTAssertEqual(t.name, "AppTheme")
        } else {
            XCTFail("Expected theme declaration")
        }
    }

    // MARK: - Expression Parsing

    func testBinaryArithmetic() {
        let p = propDecl("val x = 1 + 2 * 3")
        // Should be: 1 + (2 * 3) due to precedence
        if case .binary(let left, let op, let right, _) = p.initializer {
            XCTAssertEqual(op, .plus)
            if case .intLiteral(1, _) = left {} else { XCTFail("Expected 1") }
            if case .binary(_, let op2, _, _) = right {
                XCTAssertEqual(op2, .times)
            } else {
                XCTFail("Expected multiplication on right")
            }
        } else {
            XCTFail("Expected binary expression")
        }
    }

    func testComparisonAndLogical() {
        let p = propDecl("val x = a > 0 && b < 10")
        if case .binary(_, let op, _, _) = p.initializer {
            XCTAssertEqual(op, .and)
        } else {
            XCTFail("Expected && operator")
        }
    }

    func testUnaryNegate() {
        let p = propDecl("val x = -42")
        if case .unaryPrefix(let op, _, _) = p.initializer {
            XCTAssertEqual(op, .negate)
        } else {
            XCTFail("Expected unary negate")
        }
    }

    func testUnaryNot() {
        let p = propDecl("val x = !flag")
        if case .unaryPrefix(let op, _, _) = p.initializer {
            XCTAssertEqual(op, .not)
        } else {
            XCTFail("Expected unary not")
        }
    }

    func testMemberAccessChain() {
        let p = propDecl("val x = product.thumbnailUrl")
        if case .memberAccess(let obj, let member, _) = p.initializer {
            XCTAssertEqual(member, "thumbnailUrl")
            if case .identifier(let name, _) = obj {
                XCTAssertEqual(name, "product")
            }
        } else {
            XCTFail("Expected member access")
        }
    }

    func testNullSafeChain() {
        let p = propDecl("val x = optional?.length")
        if case .nullSafeMemberAccess(_, let member, _) = p.initializer {
            XCTAssertEqual(member, "length")
        } else {
            XCTFail("Expected null safe access")
        }
    }

    func testElvisOperator() {
        let p = propDecl("val x = optional?.length ?: 0")
        if case .elvis(let left, let right, _) = p.initializer {
            if case .nullSafeMemberAccess = left {} else { XCTFail("Expected ?. on left") }
            if case .intLiteral(0, _) = right {} else { XCTFail("Expected 0 on right") }
        } else {
            XCTFail("Expected elvis operator")
        }
    }

    func testNonNullAssert() {
        let p = propDecl("val x = value!!")
        if case .nonNullAssert(_, _) = p.initializer {} else {
            XCTFail("Expected non-null assert")
        }
    }

    func testFunctionCall() {
        let p = propDecl("val x = add(40, 2)")
        if case .call(let callee, let args, _, _) = p.initializer {
            if case .identifier(let name, _) = callee {
                XCTAssertEqual(name, "add")
            }
            XCTAssertEqual(args.count, 2)
        } else {
            XCTFail("Expected function call")
        }
    }

    func testNamedArguments() {
        let p = propDecl("val x = greet(name = \"Micah\")")
        if case .call(_, let args, _, _) = p.initializer {
            XCTAssertEqual(args.count, 1)
            XCTAssertEqual(args[0].label, "name")
        } else {
            XCTFail("Expected call with named argument")
        }
    }

    func testTrailingLambda() {
        let p = propDecl("val x = items.filter { x }")
        if case .call(_, _, let trailing, _) = p.initializer {
            XCTAssertNotNil(trailing)
        } else {
            XCTFail("Expected call with trailing lambda")
        }
    }

    func testRangeExpression() {
        let p = propDecl("val x = 0..10")
        if case .range(_, _, let inclusive, _) = p.initializer {
            XCTAssertTrue(inclusive)
        } else {
            XCTFail("Expected range expression")
        }
    }

    func testExclusiveRangeExpression() {
        let p = propDecl("val x = 0..<10")
        if case .range(_, _, let inclusive, _) = p.initializer {
            XCTAssertFalse(inclusive)
        } else {
            XCTFail("Expected exclusive range expression")
        }
    }

    func testParenthesizedExpression() {
        let p = propDecl("val x = (a + b)")
        if case .parenthesized(let inner, _) = p.initializer,
           case .binary(_, let op, _, _) = inner {
            XCTAssertEqual(op, .plus)
        } else {
            XCTFail("Expected parenthesized expression")
        }
    }

    // MARK: - When Expressions

    func testWhenWithSubject() {
        let f = funcDecl("""
        fun test(x: Int) = when (x) {
            1 -> "one"
            2 -> "two"
        }
        """)
        if case .expression(let e) = f.body,
           case .whenExpr(let we) = e {
            XCTAssertNotNil(we.subject)
            XCTAssertEqual(we.entries.count, 2)
        } else {
            XCTFail("Expected when expression body")
        }
    }

    func testWhenWithIsChecks() {
        let f = funcDecl("""
        fun test(r: Result) = when (r) {
            is Success -> "ok"
            is Error -> "fail"
        }
        """)
        if case .expression(let e) = f.body,
           case .whenExpr(let we) = e {
            XCTAssertEqual(we.entries.count, 2)
            if case .isType = we.entries[0].conditions[0] {} else {
                XCTFail("Expected is-type condition")
            }
        } else {
            XCTFail("Expected when expression")
        }
    }

    // MARK: - If Expressions

    func testIfElse() {
        let file = parseOK("""
        fun test() {
            if (x > 0) {
                y
            } else {
                z
            }
        }
        """)
        if case .function(let f) = file.declarations[0],
           case .block(let b) = f.body,
           case .expression(let e) = b.statements[0],
           case .ifExpr(let ie) = e {
            XCTAssertNotNil(ie.elseBranch)
        } else {
            XCTFail("Expected if-else expression")
        }
    }

    func testElseIf() {
        let file = parseOK("""
        fun test() {
            if (x > 0) {
                a
            } else if (x < 0) {
                b
            } else {
                c
            }
        }
        """)
        if case .function(let f) = file.declarations[0],
           case .block(let b) = f.body,
           case .expression(let e) = b.statements[0],
           case .ifExpr(let ie) = e,
           case .elseIf(let eif) = ie.elseBranch {
            XCTAssertNotNil(eif.elseBranch)
        } else {
            XCTFail("Expected else-if chain")
        }
    }

    // MARK: - For Loop

    func testForInLoop() {
        let file = parseOK("""
        fun test() {
            for (i in items) {
                x
            }
        }
        """)
        if case .function(let f) = file.declarations[0],
           case .block(let b) = f.body,
           case .forLoop(let loop) = b.statements[0] {
            XCTAssertEqual(loop.variable, "i")
        } else {
            XCTFail("Expected for loop")
        }
    }

    // MARK: - While Loop

    func testWhileLoop() {
        let file = parseOK("""
        fun test() {
            while (x > 0) {
                x
            }
        }
        """)
        if case .function(let f) = file.declarations[0],
           case .block(let b) = f.body,
           case .whileLoop = b.statements[0] {
            // ok
        } else {
            XCTFail("Expected while loop")
        }
    }

    // MARK: - Lambda Expressions

    func testLambdaWithParams() {
        let p = propDecl("val f = { x -> x }")
        if case .lambda(let le) = p.initializer {
            XCTAssertEqual(le.parameters.count, 1)
            XCTAssertEqual(le.parameters[0].name, "x")
        } else {
            XCTFail("Expected lambda")
        }
    }

    func testLambdaNoParams() {
        let p = propDecl("val f = { 42 }")
        if case .lambda(let le) = p.initializer {
            XCTAssertEqual(le.parameters.count, 0)
            XCTAssertEqual(le.body.count, 1)
        } else {
            XCTFail("Expected lambda")
        }
    }

    // MARK: - Type Check and Cast

    func testIsOperator() {
        let p = propDecl("val x = r is String")
        if case .typeCheck(_, let type, _) = p.initializer,
           case .simple(let name, _, _) = type {
            XCTAssertEqual(name, "String")
        } else {
            XCTFail("Expected type check")
        }
    }

    func testAsOperator() {
        let p = propDecl("val x = r as String")
        if case .typeCast(_, let type, _) = p.initializer,
           case .simple(let name, _, _) = type {
            XCTAssertEqual(name, "String")
        } else {
            XCTFail("Expected type cast")
        }
    }

    // MARK: - String Interpolation

    func testSimpleInterpolation() {
        let p = propDecl("val x = \"Hello, $name\"")
        if case .interpolatedString(let parts, _) = p.initializer {
            XCTAssertEqual(parts.count, 2)
            if case .literal(let s) = parts[0] { XCTAssertEqual(s, "Hello, ") }
            if case .interpolation(let e) = parts[1] {
                if case .identifier(let n, _) = e { XCTAssertEqual(n, "name") }
            }
        } else {
            XCTFail("Expected interpolated string")
        }
    }

    func testExpressionInterpolation() {
        let p = propDecl("val x = \"${greeting}, ${name}!\"")
        if case .interpolatedString(let parts, _) = p.initializer {
            XCTAssertEqual(parts.count, 4)
        } else {
            XCTFail("Expected interpolated string")
        }
    }

    // MARK: - Annotations

    func testAnnotation() {
        let file = parseOK("""
        @Capability
        fun test() { }
        """)
        if case .function(let f) = file.declarations[0] {
            XCTAssertEqual(f.annotations.count, 1)
            XCTAssertEqual(f.annotations[0].name, "Capability")
        }
    }

    func testAnnotationWithArgs() {
        let file = parseOK("""
        @Capability(requires = Payments)
        fun test() { }
        """)
        if case .function(let f) = file.declarations[0] {
            XCTAssertEqual(f.annotations.count, 1)
            XCTAssertEqual(f.annotations[0].arguments.count, 1)
            XCTAssertEqual(f.annotations[0].arguments[0].label, "requires")
        }
    }

    // MARK: - Modifiers

    func testPublicModifier() {
        let file = parseOK("public fun test() { }")
        if case .function(let f) = file.declarations[0] {
            XCTAssertTrue(f.modifiers.contains(.public))
        }
    }

    func testPrivateVar() {
        let file = parseOK("""
        actor Foo {
            private var items = 0
        }
        """)
        if case .actorDecl(let a) = file.declarations[0],
           case .property(let p) = a.members[0] {
            XCTAssertTrue(p.modifiers.contains(.private))
        }
    }

    // MARK: - Return Statement

    func testReturnWithValue() {
        let file = parseOK("""
        fun test(): Int {
            return 42
        }
        """)
        if case .function(let f) = file.declarations[0],
           case .block(let b) = f.body,
           case .returnStmt(let expr, _) = b.statements[0] {
            if case .intLiteral(42, _) = expr {} else {
                XCTFail("Expected return 42")
            }
        } else {
            XCTFail("Expected return statement")
        }
    }

    func testReturnWithoutValue() {
        let file = parseOK("""
        fun test() {
            return
        }
        """)
        if case .function(let f) = file.declarations[0],
           case .block(let b) = f.body,
           case .returnStmt(let expr, _) = b.statements[0] {
            XCTAssertNil(expr)
        } else {
            XCTFail("Expected return without value")
        }
    }

    // MARK: - Assignment

    func testSimpleAssignment() {
        let file = parseOK("""
        fun test() {
            x = 42
        }
        """)
        if case .function(let f) = file.declarations[0],
           case .block(let b) = f.body,
           case .assignment(let a) = b.statements[0] {
            XCTAssertEqual(a.op, .assign)
        } else {
            XCTFail("Expected assignment")
        }
    }

    func testCompoundAssignment() {
        let file = parseOK("""
        fun test() {
            x += 1
        }
        """)
        if case .function(let f) = file.declarations[0],
           case .block(let b) = f.body,
           case .assignment(let a) = b.statements[0] {
            XCTAssertEqual(a.op, .plusAssign)
        } else {
            XCTFail("Expected += assignment")
        }
    }

    // MARK: - Subscript Access

    func testSubscriptAccess() {
        let p = propDecl("val x = arr[0]")
        if case .subscriptAccess(_, let idx, _) = p.initializer,
           case .intLiteral(0, _) = idx {} else {
            XCTFail("Expected subscript access")
        }
    }

    // MARK: - Generic Types

    func testGenericType() {
        let p = propDecl("val x: List<String> = y")
        if case .simple(let name, let args, _) = p.type {
            XCTAssertEqual(name, "List")
            XCTAssertEqual(args.count, 1)
        } else {
            XCTFail("Expected generic type")
        }
    }

    func testNestedGenericType() {
        let p = propDecl("val x: Map<String, List<Int>> = y")
        if case .simple(let name, let args, _) = p.type {
            XCTAssertEqual(name, "Map")
            XCTAssertEqual(args.count, 2)
            if case .simple(let inner, let innerArgs, _) = args[1] {
                XCTAssertEqual(inner, "List")
                XCTAssertEqual(innerArgs.count, 1)
            }
        } else {
            XCTFail("Expected nested generic type")
        }
    }

    // MARK: - Type Parameters

    func testTypeParameterWithVariance() {
        let file = parseOK("""
        class Box<out T> { }
        """)
        if case .classDecl(let c) = file.declarations[0] {
            XCTAssertEqual(c.typeParameters.count, 1)
            XCTAssertEqual(c.typeParameters[0].name, "T")
            if case .out = c.typeParameters[0].variance {} else {
                XCTFail("Expected out variance")
            }
        }
    }

    // MARK: - Newline Handling

    func testNewlineTerminatesStatement() {
        let file = parseOK("""
        fun test() {
            val x = 1
            val y = 2
        }
        """)
        if case .function(let f) = file.declarations[0],
           case .block(let b) = f.body {
            XCTAssertEqual(b.statements.count, 2)
        }
    }

    func testMethodChainAcrossNewlines() {
        let p = propDecl("""
        val x = foo
            .bar()
            .baz()
        """)
        // Should parse as foo.bar().baz()
        if case .call(let callee, _, _, _) = p.initializer,
           case .memberAccess(_, let member, _) = callee {
            XCTAssertEqual(member, "baz")
        } else {
            XCTFail("Expected chained method call across newlines")
        }
    }

    // MARK: - Error Recovery

    func testMissingBraceRecovery() {
        // Should produce errors but not crash
        let _ = parseWithErrors("fun test() { val x = ")
    }

    func testPartialParseStillProducesAST() {
        // Even with errors, the parser should produce some declarations
        let (file, diag) = parseSource("val x = 1\nfun {\nval y = 2")
        XCTAssertTrue(diag.hasErrors)
        // Should still have parsed some declarations
        XCTAssertGreaterThan(file.declarations.count, 0)
    }

    // MARK: - Integration Test

    func testHelloRockitFile() {
        // Read the hello.rok example file and verify it parses
        let source = """
        package com.darkmatter.hello
        import rockit.core.List
        import rockit.http.HttpClient
        val appName: String = "Moon Demo"
        var counter: Int = 0
        fun add(a: Int, b: Int): Int {
            return a + b
        }
        fun multiply(a: Int, b: Int): Int = a * b
        data class User(val id: String, val name: String, val email: String)
        interface Serializable {
            fun toBytes(): ByteArray
        }
        actor ShoppingCart {
            fun add(item: String) { }
        }
        view ProductCard(product: String) {
            product
        }
        navigation App {
            x
        }
        theme AppTheme {
            x
        }
        fun main() {
            print("Hello, Rockit!")
            val user = User("1", "Micah", "micah@darkmatter.tech")
        }
        """
        let file = parseOK(source)
        XCTAssertEqual(file.packageDecl?.path, ["com", "darkmatter", "hello"])
        XCTAssertEqual(file.imports.count, 2)
        // Should have: 2 vals, 2 funs, data class, interface, actor, view, navigation, theme, main
        XCTAssertGreaterThanOrEqual(file.declarations.count, 11)
    }

    // MARK: - AST Dump

    func testASTDump() {
        let file = parseOK("val x: Int = 42")
        let output = file.dump()
        XCTAssertTrue(output.contains("SourceFile"))
        XCTAssertTrue(output.contains("PropertyDecl"))
        XCTAssertTrue(output.contains("val x"))
        XCTAssertTrue(output.contains("IntLiteral(42)"))
    }
}
