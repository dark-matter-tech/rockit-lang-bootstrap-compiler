// BreakContinueTests.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import XCTest
@testable import RockitKit

final class BreakContinueTests: XCTestCase {

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

    private func runCapturing(_ source: String) throws -> [String] {
        let module = compile(source)
        var output: [String] = []
        let builtins = BuiltinRegistry()
        builtins.register(name: "println") { args in
            output.append(args.map { $0.description }.joined(separator: " "))
            return .unit
        }
        let vm = VM(module: module, builtins: builtins)
        try vm.run()
        return output
    }

    // MARK: - While Loop Break

    func testWhileBreak() throws {
        let output = try runCapturing("""
        fun main(): Unit {
            var i: Int = 0
            while (true) {
                if (i == 3) {
                    break
                }
                println(toString(i))
                i = i + 1
            }
            println("done")
        }
        """)
        XCTAssertEqual(output, ["0", "1", "2", "done"])
    }

    // MARK: - While Loop Continue

    func testWhileContinue() throws {
        let output = try runCapturing("""
        fun main(): Unit {
            var i: Int = 0
            while (i < 5) {
                i = i + 1
                if (i == 3) {
                    continue
                }
                println(toString(i))
            }
        }
        """)
        XCTAssertEqual(output, ["1", "2", "4", "5"])
    }

    // MARK: - For Range Break

    func testForRangeBreak() throws {
        let output = try runCapturing("""
        fun main(): Unit {
            for (i in 0..<10) {
                if (i == 3) {
                    break
                }
                println(toString(i))
            }
            println("done")
        }
        """)
        XCTAssertEqual(output, ["0", "1", "2", "done"])
    }

    // MARK: - For Range Continue

    func testForRangeContinue() throws {
        let output = try runCapturing("""
        fun main(): Unit {
            for (i in 0..<5) {
                if (i == 2) {
                    continue
                }
                println(toString(i))
            }
        }
        """)
        XCTAssertEqual(output, ["0", "1", "3", "4"])
    }

    // MARK: - Break + Continue Together

    func testBreakAndContinueTogether() throws {
        let output = try runCapturing("""
        fun main(): Unit {
            var i: Int = 0
            while (i < 10) {
                i = i + 1
                if (i == 2) {
                    continue
                }
                if (i == 5) {
                    break
                }
                println(toString(i))
            }
            println("end")
        }
        """)
        XCTAssertEqual(output, ["1", "3", "4", "end"])
    }

    // MARK: - Nested Loop Break

    func testNestedLoopBreak() throws {
        let output = try runCapturing("""
        fun main(): Unit {
            for (i in 0..<3) {
                for (j in 0..<3) {
                    if (j == 1) {
                        break
                    }
                    println(toString(j))
                }
                println(toString(i))
            }
        }
        """)
        // Inner loop breaks at j==1, so only prints j=0 each time
        XCTAssertEqual(output, ["0", "0", "0", "1", "0", "2"])
    }

    // MARK: - For Range Continue Increments Counter

    func testForRangeContinueIncrementsCounter() throws {
        // Verify that continue in a for-range loop still increments the counter
        let output = try runCapturing("""
        fun main(): Unit {
            var sum: Int = 0
            for (i in 1..5) {
                if (i == 3) {
                    continue
                }
                sum = sum + i
            }
            println(toString(sum))
        }
        """)
        // 1 + 2 + 4 + 5 = 12 (skip 3)
        XCTAssertEqual(output, ["12"])
    }
}
