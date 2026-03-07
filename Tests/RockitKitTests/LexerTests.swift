// LexerTests.swift
// RockitKit Tests
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import XCTest
@testable import RockitKit

final class LexerTests: XCTestCase {

    // MARK: - Helpers

    private func lex(_ source: String) -> [Token] {
        let lexer = Lexer(source: source)
        return lexer.tokenize().filter { $0.kind != .newline }
    }

    private func kinds(_ source: String) -> [TokenKind] {
        lex(source).map(\.kind)
    }

    // MARK: - Keywords

    func testKeywords() {
        XCTAssertEqual(kinds("fun val var class"), [.kwFun, .kwVal, .kwVar, .kwClass, .eof])
        XCTAssertEqual(kinds("view actor navigation route"), [.kwView, .kwActor, .kwNavigation, .kwRoute, .eof])
        XCTAssertEqual(kinds("suspend async await concurrent"), [.kwSuspend, .kwAsync, .kwAwait, .kwConcurrent, .eof])
        XCTAssertEqual(kinds("weak unowned"), [.kwWeak, .kwUnowned, .eof])
        XCTAssertEqual(kinds("if else when for while"), [.kwIf, .kwElse, .kwWhen, .kwFor, .kwWhile, .eof])
        XCTAssertEqual(kinds("sealed data enum interface object"), [.kwSealed, .kwData, .kwEnum, .kwInterface, .kwObject, .eof])
        XCTAssertEqual(kinds("return break continue"), [.kwReturn, .kwBreak, .kwContinue, .eof])
        XCTAssertEqual(kinds("is as in"), [.kwIs, .kwAs, .kwIn, .eof])
        XCTAssertEqual(kinds("true false null"), [.boolLiteral(true), .boolLiteral(false), .nullLiteral, .eof])
    }

    // MARK: - Identifiers

    func testIdentifiers() {
        XCTAssertEqual(kinds("foo bar baz"), [.identifier("foo"), .identifier("bar"), .identifier("baz"), .eof])
        XCTAssertEqual(kinds("_private __dunder"), [.identifier("_private"), .identifier("__dunder"), .eof])
        XCTAssertEqual(kinds("camelCase PascalCase"), [.identifier("camelCase"), .identifier("PascalCase"), .eof])
    }

    func testIdentifierVsKeyword() {
        // "funky" should be an identifier, not keyword "fun" + "ky"
        XCTAssertEqual(kinds("funky"), [.identifier("funky"), .eof])
        XCTAssertEqual(kinds("values"), [.identifier("values"), .eof])
        XCTAssertEqual(kinds("className"), [.identifier("className"), .eof])
    }

    // MARK: - Number Literals

    func testIntegerLiterals() {
        XCTAssertEqual(kinds("42"), [.intLiteral(42), .eof])
        XCTAssertEqual(kinds("0"), [.intLiteral(0), .eof])
        XCTAssertEqual(kinds("1_000_000"), [.intLiteral(1000000), .eof])
    }

    func testHexLiterals() {
        XCTAssertEqual(kinds("0xFF"), [.intLiteral(255), .eof])
        XCTAssertEqual(kinds("0x5B21B6"), [.intLiteral(0x5B21B6), .eof])
    }

    func testBinaryLiterals() {
        XCTAssertEqual(kinds("0b1010"), [.intLiteral(10), .eof])
        XCTAssertEqual(kinds("0b1111_0000"), [.intLiteral(0xF0), .eof])
    }

    func testFloatLiterals() {
        XCTAssertEqual(kinds("3.14"), [.floatLiteral(3.14), .eof])
        XCTAssertEqual(kinds("1.0e10"), [.floatLiteral(1.0e10), .eof])
        XCTAssertEqual(kinds("2.5E-3"), [.floatLiteral(2.5e-3), .eof])
    }

    // MARK: - String Literals

    func testSimpleString() {
        let tokens = lex(#""Hello, Rockit!""#)
        XCTAssertEqual(tokens[0].kind, .stringLiteral("Hello, Rockit!"))
    }

    func testStringEscapes() {
        let tokens = lex(#""line1\nline2\ttab""#)
        XCTAssertEqual(tokens[0].kind, .stringLiteral("line1\nline2\ttab"))
    }

    func testStringInterpolation() {
        let tokens = lex(#""Hello, ${name}!""#)
        if case .stringLiteral(let s) = tokens[0].kind {
            XCTAssertTrue(s.contains("${name}"))
        } else {
            XCTFail("Expected string literal")
        }
    }

    // MARK: - Operators

    func testArithmeticOperators() {
        XCTAssertEqual(kinds("+ - * / %"), [.plus, .minus, .star, .slash, .percent, .eof])
    }

    func testComparisonOperators() {
        XCTAssertEqual(kinds("== != < <= > >="), [.equalEqual, .bangEqual, .less, .lessEqual, .greater, .greaterEqual, .eof])
    }

    func testAssignmentOperators() {
        XCTAssertEqual(kinds("= += -= *= /= %="), [.equal, .plusEqual, .minusEqual, .starEqual, .slashEqual, .percentEqual, .eof])
    }

    func testLogicalOperators() {
        XCTAssertEqual(kinds("&& || !"), [.ampAmp, .pipePipe, .bang, .eof])
    }

    func testNullOperators() {
        XCTAssertEqual(kinds("?. ?: !!"), [.questionDot, .questionColon, .bangBang, .eof])
    }

    func testRangeOperators() {
        XCTAssertEqual(kinds(".. ..<"), [.dotDot, .dotDotLess, .eof])
    }

    func testArrow() {
        XCTAssertEqual(kinds("-> =>"), [.arrow, .fatArrow, .eof])
    }

    // MARK: - Delimiters

    func testDelimiters() {
        XCTAssertEqual(kinds("( ) { } [ ] , : ; @"), [
            .leftParen, .rightParen, .leftBrace, .rightBrace,
            .leftBracket, .rightBracket, .comma, .colon,
            .semicolon, .at, .eof
        ])
    }

    // MARK: - Comments

    func testSingleLineComment() {
        XCTAssertEqual(kinds("val x // this is a comment"), [.kwVal, .identifier("x"), .eof])
    }

    func testMultiLineComment() {
        XCTAssertEqual(kinds("val /* comment */ x"), [.kwVal, .identifier("x"), .eof])
    }

    func testNestedComments() {
        XCTAssertEqual(kinds("val /* outer /* inner */ still outer */ x"), [.kwVal, .identifier("x"), .eof])
    }

    // MARK: - Full Statements

    func testValDeclaration() {
        let expected: [TokenKind] = [
            .kwVal, .identifier("name"), .colon, .identifier("String"),
            .equal, .stringLiteral("Moon"), .eof
        ]
        XCTAssertEqual(kinds(#"val name: String = "Moon""#), expected)
    }

    func testFunctionDeclaration() {
        let source = "fun add(a: Int, b: Int): Int"
        let expected: [TokenKind] = [
            .kwFun, .identifier("add"), .leftParen,
            .identifier("a"), .colon, .identifier("Int"), .comma,
            .identifier("b"), .colon, .identifier("Int"),
            .rightParen, .colon, .identifier("Int"), .eof
        ]
        XCTAssertEqual(kinds(source), expected)
    }

    func testDataClass() {
        let source = "data class User(val id: String)"
        let expected: [TokenKind] = [
            .kwData, .kwClass, .identifier("User"), .leftParen,
            .kwVal, .identifier("id"), .colon, .identifier("String"),
            .rightParen, .eof
        ]
        XCTAssertEqual(kinds(source), expected)
    }

    func testViewDeclaration() {
        let source = "view Counter()"
        let expected: [TokenKind] = [
            .kwView, .identifier("Counter"), .leftParen, .rightParen, .eof
        ]
        XCTAssertEqual(kinds(source), expected)
    }

    func testActorDeclaration() {
        let source = "actor ShoppingCart"
        let expected: [TokenKind] = [
            .kwActor, .identifier("ShoppingCart"), .eof
        ]
        XCTAssertEqual(kinds(source), expected)
    }

    func testSuspendFunction() {
        let source = "suspend fun fetchUser(id: String): User"
        let expected: [TokenKind] = [
            .kwSuspend, .kwFun, .identifier("fetchUser"), .leftParen,
            .identifier("id"), .colon, .identifier("String"),
            .rightParen, .colon, .identifier("User"), .eof
        ]
        XCTAssertEqual(kinds(source), expected)
    }

    func testNullSafety() {
        let source = "optional?.length ?: 0"
        let expected: [TokenKind] = [
            .identifier("optional"), .questionDot, .identifier("length"),
            .questionColon, .intLiteral(0), .eof
        ]
        XCTAssertEqual(kinds(source), expected)
    }

    func testGenerics() {
        let source = "Result<User>"
        let expected: [TokenKind] = [
            .identifier("Result"), .less, .identifier("User"), .greater, .eof
        ]
        XCTAssertEqual(kinds(source), expected)
    }

    func testAnnotation() {
        let source = "@Capability"
        let expected: [TokenKind] = [
            .at, .identifier("Capability"), .eof
        ]
        XCTAssertEqual(kinds(source), expected)
    }

    // MARK: - Source Locations

    func testSourceLocations() {
        let tokens = lex("val x = 42")
        XCTAssertEqual(tokens[0].span.start.line, 1)
        XCTAssertEqual(tokens[0].span.start.column, 1) // val
        XCTAssertEqual(tokens[1].span.start.column, 5) // x
        XCTAssertEqual(tokens[2].span.start.column, 7) // =
        XCTAssertEqual(tokens[3].span.start.column, 9) // 42
    }

    // MARK: - Error Recovery

    func testUnterminatedString() {
        let diag = DiagnosticEngine()
        let lexer = Lexer(source: #""unterminated"#, diagnostics: diag)
        _ = lexer.tokenize()
        XCTAssertTrue(diag.hasErrors)
    }
}
