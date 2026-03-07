// FileIOTests.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import XCTest
@testable import RockitKit

final class FileIOTests: XCTestCase {

    private var builtins: BuiltinRegistry!
    private let testDir = NSTemporaryDirectory()

    override func setUp() {
        super.setUp()
        builtins = BuiltinRegistry()
    }

    private func call(_ name: String, _ args: [Value]) throws -> Value {
        guard let fn = builtins.lookup(name) else {
            XCTFail("Builtin '\(name)' not registered")
            return .null
        }
        return try fn(args)
    }

    private func tempPath(_ name: String) -> String {
        return (testDir as NSString).appendingPathComponent("moon_test_\(name)")
    }

    override func tearDown() {
        // Clean up any test files
        let fm = FileManager.default
        for name in ["read.txt", "write.txt", "exists.txt", "delete.txt"] {
            try? fm.removeItem(atPath: tempPath(name))
        }
        super.tearDown()
    }

    // MARK: - fileRead

    func testFileRead() throws {
        let path = tempPath("read.txt")
        try "hello moon".write(toFile: path, atomically: true, encoding: .utf8)

        let result = try call("fileRead", [.string(path)])
        XCTAssertEqual(result, .string("hello moon"))
    }

    func testFileReadNonexistent() throws {
        let result = try call("fileRead", [.string("/nonexistent/path/file.txt")])
        XCTAssertEqual(result, .null)
    }

    // MARK: - fileWrite

    func testFileWrite() throws {
        let path = tempPath("write.txt")
        let result = try call("fileWrite", [.string(path), .string("written by moon")])
        XCTAssertEqual(result, .bool(true))

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(contents, "written by moon")
    }

    // MARK: - fileExists

    func testFileExists() throws {
        let path = tempPath("exists.txt")
        XCTAssertEqual(try call("fileExists", [.string(path)]), .bool(false))

        try "test".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(try call("fileExists", [.string(path)]), .bool(true))
    }

    // MARK: - fileDelete

    func testFileDelete() throws {
        let path = tempPath("delete.txt")
        try "to delete".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let result = try call("fileDelete", [.string(path)])
        XCTAssertEqual(result, .bool(true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testFileDeleteNonexistent() throws {
        let result = try call("fileDelete", [.string("/nonexistent/path")])
        XCTAssertEqual(result, .bool(false))
    }

    // MARK: - Round Trip

    func testFileWriteAndRead() throws {
        let path = tempPath("write.txt")
        let content = "fun main(): Unit {\n    println(\"hello\")\n}\n"
        _ = try call("fileWrite", [.string(path), .string(content)])
        let result = try call("fileRead", [.string(path)])
        XCTAssertEqual(result, .string(content))
    }
}
