// StringBuiltinTests.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import XCTest
@testable import RockitKit

final class StringBuiltinTests: XCTestCase {

    private var heap: Heap!
    private var arc: ReferenceCounter!
    private var builtins: BuiltinRegistry!

    override func setUp() {
        super.setUp()
        heap = Heap()
        arc = ReferenceCounter(heap: heap)
        builtins = BuiltinRegistry()
        builtins.registerCollectionBuiltins(heap: heap, arc: arc)
    }

    private func call(_ name: String, _ args: [Value]) throws -> Value {
        guard let fn = builtins.lookup(name) else {
            XCTFail("Builtin '\(name)' not registered")
            return .null
        }
        return try fn(args)
    }

    // MARK: - charAt

    func testCharAt() throws {
        XCTAssertEqual(try call("charAt", [.string("hello"), .int(0)]), .string("h"))
        XCTAssertEqual(try call("charAt", [.string("hello"), .int(4)]), .string("o"))
    }

    func testCharAtOutOfBounds() throws {
        XCTAssertThrowsError(try call("charAt", [.string("hi"), .int(5)])) { error in
            if case VMError.indexOutOfBounds = error {} else {
                XCTFail("Expected indexOutOfBounds, got \(error)")
            }
        }
    }

    func testCharAtNegativeIndex() throws {
        XCTAssertThrowsError(try call("charAt", [.string("hi"), .int(-1)])) { error in
            if case VMError.indexOutOfBounds = error {} else {
                XCTFail("Expected indexOutOfBounds, got \(error)")
            }
        }
    }

    // MARK: - stringIndexOf

    func testStringIndexOf() throws {
        XCTAssertEqual(try call("stringIndexOf", [.string("hello world"), .string("world")]), .int(6))
        XCTAssertEqual(try call("stringIndexOf", [.string("hello"), .string("ell")]), .int(1))
        XCTAssertEqual(try call("stringIndexOf", [.string("hello"), .string("xyz")]), .int(-1))
        XCTAssertEqual(try call("stringIndexOf", [.string("aabaa"), .string("a")]), .int(0))
    }

    // MARK: - stringSplit

    func testStringSplit() throws {
        let result = try call("stringSplit", [.string("a,b,c"), .string(",")])
        guard case .objectRef(let id) = result else {
            XCTFail("Expected objectRef"); return
        }
        let obj = try heap.get(id)
        XCTAssertEqual(obj.listStorage?.count, 3)
        XCTAssertEqual(obj.listStorage?[0], .string("a"))
        XCTAssertEqual(obj.listStorage?[1], .string("b"))
        XCTAssertEqual(obj.listStorage?[2], .string("c"))
    }

    func testStringSplitEmptyDelimiter() throws {
        let result = try call("stringSplit", [.string("abc"), .string("")])
        guard case .objectRef(let id) = result else {
            XCTFail("Expected objectRef"); return
        }
        let obj = try heap.get(id)
        XCTAssertEqual(obj.listStorage?.count, 3)
        XCTAssertEqual(obj.listStorage?[0], .string("a"))
        XCTAssertEqual(obj.listStorage?[1], .string("b"))
        XCTAssertEqual(obj.listStorage?[2], .string("c"))
    }

    func testStringSplitNoMatch() throws {
        let result = try call("stringSplit", [.string("hello"), .string(",")])
        guard case .objectRef(let id) = result else {
            XCTFail("Expected objectRef"); return
        }
        let obj = try heap.get(id)
        XCTAssertEqual(obj.listStorage?.count, 1)
        XCTAssertEqual(obj.listStorage?[0], .string("hello"))
    }

    // MARK: - startsWith / endsWith

    func testStartsWith() throws {
        XCTAssertEqual(try call("startsWith", [.string("hello"), .string("hel")]), .bool(true))
        XCTAssertEqual(try call("startsWith", [.string("hello"), .string("xyz")]), .bool(false))
        XCTAssertEqual(try call("startsWith", [.string("hello"), .string("")]), .bool(true))
    }

    func testEndsWith() throws {
        XCTAssertEqual(try call("endsWith", [.string("hello"), .string("llo")]), .bool(true))
        XCTAssertEqual(try call("endsWith", [.string("hello"), .string("xyz")]), .bool(false))
        XCTAssertEqual(try call("endsWith", [.string("hello"), .string("")]), .bool(true))
    }

    // MARK: - stringContains

    func testStringContains() throws {
        XCTAssertEqual(try call("stringContains", [.string("hello world"), .string("world")]), .bool(true))
        XCTAssertEqual(try call("stringContains", [.string("hello"), .string("xyz")]), .bool(false))
    }

    // MARK: - stringTrim

    func testStringTrim() throws {
        XCTAssertEqual(try call("stringTrim", [.string("  hello  ")]), .string("hello"))
        XCTAssertEqual(try call("stringTrim", [.string("\n\thello\t\n")]), .string("hello"))
        XCTAssertEqual(try call("stringTrim", [.string("hello")]), .string("hello"))
    }

    // MARK: - stringReplace

    func testStringReplace() throws {
        XCTAssertEqual(try call("stringReplace", [.string("hello world"), .string("world"), .string("moon")]), .string("hello moon"))
        XCTAssertEqual(try call("stringReplace", [.string("aaa"), .string("a"), .string("b")]), .string("bbb"))
    }

    // MARK: - stringToLower / stringToUpper

    func testStringToLower() throws {
        XCTAssertEqual(try call("stringToLower", [.string("HELLO")]), .string("hello"))
        XCTAssertEqual(try call("stringToLower", [.string("Hello World")]), .string("hello world"))
    }

    func testStringToUpper() throws {
        XCTAssertEqual(try call("stringToUpper", [.string("hello")]), .string("HELLO"))
        XCTAssertEqual(try call("stringToUpper", [.string("Hello World")]), .string("HELLO WORLD"))
    }

    // MARK: - Character Classification

    func testIsDigit() throws {
        XCTAssertEqual(try call("isDigit", [.string("5")]), .bool(true))
        XCTAssertEqual(try call("isDigit", [.string("0")]), .bool(true))
        XCTAssertEqual(try call("isDigit", [.string("a")]), .bool(false))
        XCTAssertEqual(try call("isDigit", [.string(" ")]), .bool(false))
    }

    func testIsLetter() throws {
        XCTAssertEqual(try call("isLetter", [.string("a")]), .bool(true))
        XCTAssertEqual(try call("isLetter", [.string("Z")]), .bool(true))
        XCTAssertEqual(try call("isLetter", [.string("5")]), .bool(false))
        XCTAssertEqual(try call("isLetter", [.string(" ")]), .bool(false))
    }

    func testIsWhitespace() throws {
        XCTAssertEqual(try call("isWhitespace", [.string(" ")]), .bool(true))
        XCTAssertEqual(try call("isWhitespace", [.string("\t")]), .bool(true))
        XCTAssertEqual(try call("isWhitespace", [.string("\n")]), .bool(true))
        XCTAssertEqual(try call("isWhitespace", [.string("a")]), .bool(false))
    }

    func testIsLetterOrDigit() throws {
        XCTAssertEqual(try call("isLetterOrDigit", [.string("a")]), .bool(true))
        XCTAssertEqual(try call("isLetterOrDigit", [.string("5")]), .bool(true))
        XCTAssertEqual(try call("isLetterOrDigit", [.string(" ")]), .bool(false))
        XCTAssertEqual(try call("isLetterOrDigit", [.string("!")]), .bool(false))
    }

    // MARK: - charToInt / intToChar

    func testCharToInt() throws {
        XCTAssertEqual(try call("charToInt", [.string("A")]), .int(65))
        XCTAssertEqual(try call("charToInt", [.string("0")]), .int(48))
        XCTAssertEqual(try call("charToInt", [.string(" ")]), .int(32))
    }

    func testIntToChar() throws {
        XCTAssertEqual(try call("intToChar", [.int(65)]), .string("A"))
        XCTAssertEqual(try call("intToChar", [.int(48)]), .string("0"))
        XCTAssertEqual(try call("intToChar", [.int(32)]), .string(" "))
    }

    // MARK: - stringConcat

    func testStringConcat() throws {
        XCTAssertEqual(try call("stringConcat", [.string("hello"), .string(" world")]), .string("hello world"))
        XCTAssertEqual(try call("stringConcat", [.string(""), .string("abc")]), .string("abc"))
    }

    // MARK: - stringFromCharCodes

    func testStringFromCharCodes() throws {
        // Create a list of char codes for "Hi"
        let list = try call("listCreate", [])
        _ = try call("listAppend", [list, .int(72)])   // 'H'
        _ = try call("listAppend", [list, .int(105)])  // 'i'
        let result = try call("stringFromCharCodes", [list])
        XCTAssertEqual(result, .string("Hi"))
    }
}
