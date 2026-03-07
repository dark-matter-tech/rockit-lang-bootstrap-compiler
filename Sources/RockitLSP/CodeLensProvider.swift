// CodeLensProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation
import RockitKit

/// Provides CodeLens items for @Test functions, showing inline pass/fail indicators.
/// Tests run automatically when the file is first opened and again on each save.
public final class CodeLensProvider {

    /// Result of running a single test function
    enum TestResult {
        case pass
        case fail(String)
        case compileError(String)

        var isPass: Bool {
            if case .pass = self { return true }
            return false
        }
        var isFail: Bool {
            switch self {
            case .fail, .compileError: return true
            default: return false
            }
        }
    }

    /// Cache: uri -> [testFunctionName: TestResult]
    private static var testResultsCache: [String: [String: TestResult]] = [:]

    // MARK: - Public API

    /// Return CodeLens items for all @Test functions in the document,
    /// including class-level "Run N tests" lenses for test suite classes.
    /// Runs tests immediately if no cached results exist (first open or after save).
    public static func codeLenses(
        for result: AnalysisResult,
        uri: String,
        source: String,
        filePath: String,
        workspaceRoot: String?
    ) -> [LSPCodeLens] {
        // Discover @Test functions from the AST (top-level only for backward compat)
        let testFunctionNames = discoverTestFunctions(ast: result.ast)
        let classTests = discoverClassTests(ast: result.ast)
        guard !testFunctionNames.isEmpty || !classTests.isEmpty else { return [] }

        // Run tests if we don't have cached results
        if testResultsCache[uri] == nil {
            runTests(source: source, filePath: filePath, uri: uri, workspaceRoot: workspaceRoot)
        }

        let cached = testResultsCache[uri] ?? [:]
        var lenses: [LSPCodeLens] = []

        // Top-level @Test function lenses
        for decl in result.ast.declarations {
            guard case .function(let fn) = decl else { continue }
            guard fn.annotations.contains(where: { $0.name == "Test" }) else { continue }

            let line = fn.span.start.line - 1  // Convert to 0-indexed
            let range = LSPRange(
                start: LSPPosition(line: line, character: 0),
                end: LSPPosition(line: line, character: 0)
            )

            let command: LSPCommand
            if let testResult = cached[fn.name] {
                switch testResult {
                case .pass:
                    command = LSPCommand(
                        title: "\u{2705} \(fn.name) passed",
                        command: "rockit.runTest",
                        arguments: [fn.name]
                    )
                case .fail(let message):
                    command = LSPCommand(
                        title: "\u{274C} \(fn.name) — \(message)",
                        command: "rockit.runTest",
                        arguments: [fn.name]
                    )
                case .compileError(let message):
                    command = LSPCommand(
                        title: "\u{26A0}\u{FE0F} \(fn.name) — \(message)",
                        command: "rockit.runTest",
                        arguments: [fn.name]
                    )
                }
            } else {
                command = LSPCommand(
                    title: "\u{25B6}\u{FE0F} Run Test",
                    command: "rockit.runTest",
                    arguments: [fn.name]
                )
            }

            lenses.append(LSPCodeLens(range: range, command: command))
        }

        // Class-level lenses: "Run N tests" on classes containing @Test methods
        for (className, info) in classTests {
            let line = info.line - 1  // Convert to 0-indexed
            let range = LSPRange(
                start: LSPPosition(line: line, character: 0),
                end: LSPPosition(line: line, character: 0)
            )

            let testCount = info.testNames.count
            let passCount = info.testNames.filter { cached["\(className)::\($0)"]?.isPass == true }.count
            let failCount = info.testNames.filter { cached["\(className)::\($0)"]?.isFail == true }.count

            let title: String
            if passCount + failCount == testCount && testCount > 0 {
                if failCount > 0 {
                    title = "\u{274C} \(className): \(passCount)/\(testCount) passed"
                } else {
                    title = "\u{2705} \(className): \(testCount)/\(testCount) passed"
                }
            } else {
                title = "\u{25B6}\u{FE0F} Run \(testCount) test\(testCount == 1 ? "" : "s")"
            }

            let command = LSPCommand(
                title: title,
                command: "rockit.runTestClass",
                arguments: [className]
            )
            lenses.append(LSPCodeLens(range: range, command: command))

            // Also add per-method lenses inside the class
            for (methodName, methodLine) in info.methods {
                let mLine = methodLine - 1
                let mRange = LSPRange(
                    start: LSPPosition(line: mLine, character: 0),
                    end: LSPPosition(line: mLine, character: 0)
                )
                let key = "\(className)::\(methodName)"
                let mCommand: LSPCommand
                if let testResult = cached[key] {
                    switch testResult {
                    case .pass:
                        mCommand = LSPCommand(
                            title: "\u{2705} \(methodName) passed",
                            command: "rockit.runTest",
                            arguments: [key]
                        )
                    case .fail(let message):
                        mCommand = LSPCommand(
                            title: "\u{274C} \(methodName) — \(message)",
                            command: "rockit.runTest",
                            arguments: [key]
                        )
                    case .compileError(let message):
                        mCommand = LSPCommand(
                            title: "\u{26A0}\u{FE0F} \(methodName) — \(message)",
                            command: "rockit.runTest",
                            arguments: [key]
                        )
                    }
                } else {
                    mCommand = LSPCommand(
                        title: "\u{25B6}\u{FE0F} Run Test",
                        command: "rockit.runTest",
                        arguments: [key]
                    )
                }
                lenses.append(LSPCodeLens(range: mRange, command: mCommand))
            }
        }

        return lenses
    }

    /// Run all @Test functions in a file (top-level and class members) and cache results.
    public static func runTests(
        source: String,
        filePath: String,
        uri: String,
        workspaceRoot: String?
    ) {
        let diagnostics = DiagnosticEngine()
        let lexer = Lexer(source: source, fileName: filePath, diagnostics: diagnostics)
        let tokens = lexer.tokenize()
        let parser = Parser(tokens: tokens, diagnostics: diagnostics)
        let parsedAST = parser.parse()

        let sourceDir = (filePath as NSString).deletingLastPathComponent
        let stdlibPaths: [String] = findStdlibDir(workspaceRoot: workspaceRoot).map { [$0] } ?? []
        let importResolver = ImportResolver(sourceDir: sourceDir, libPaths: stdlibPaths, diagnostics: diagnostics)
        let ast = importResolver.resolve(parsedAST)

        let checker = TypeChecker(ast: ast, diagnostics: diagnostics)
        _ = checker.check()

        // Discover @Test functions (top-level)
        let testFunctions = discoverTestFunctions(ast: ast)
        // Discover class-based @Test methods
        let classTests = discoverClassTests(ast: ast)

        guard !testFunctions.isEmpty || !classTests.isEmpty else { return }

        if diagnostics.hasErrors {
            var results: [String: TestResult] = [:]
            for testFn in testFunctions {
                results[testFn] = .compileError("compile error")
            }
            for (className, info) in classTests {
                for testName in info.testNames {
                    results["\(className)::\(testName)"] = .compileError("compile error")
                }
            }
            testResultsCache[uri] = results
            return
        }

        // Strip main() and run each test individually
        let sourceWithoutMain = stripMainFunction(source)
        var results: [String: TestResult] = [:]

        // Run top-level @Test functions
        for testFn in testFunctions {
            let wrapperSource = sourceWithoutMain + "\nfun main() { \(testFn)() }\n"
            let result = runSingleTest(wrapperSource: wrapperSource, filePath: filePath, sourceDir: sourceDir, stdlibPaths: stdlibPaths)
            results[testFn] = result
        }

        // Run class-based @Test methods
        for (className, info) in classTests {
            // Check if class has setUp/tearDown
            var hasSetUp = false
            var hasTearDown = false
            for decl in ast.declarations {
                if case .classDecl(let cls) = decl, cls.name == className {
                    for member in cls.members {
                        if case .function(let fn) = member {
                            if fn.name == "setUp" { hasSetUp = true }
                            if fn.name == "tearDown" { hasTearDown = true }
                        }
                    }
                }
            }

            for testName in info.testNames {
                var body = "    val __t = \(className)()\n"
                if hasSetUp { body += "    __t.setUp()\n" }
                body += "    __t.\(testName)()\n"
                if hasTearDown { body += "    __t.tearDown()\n" }

                let wrapperSource = sourceWithoutMain + "\nfun main() {\n" + body + "}\n"
                let result = runSingleTest(wrapperSource: wrapperSource, filePath: filePath, sourceDir: sourceDir, stdlibPaths: stdlibPaths)
                results["\(className)::\(testName)"] = result
            }
        }

        testResultsCache[uri] = results
    }

    /// Run a single test with the given wrapper source and return the result.
    private static func runSingleTest(
        wrapperSource: String,
        filePath: String,
        sourceDir: String,
        stdlibPaths: [String]
    ) -> TestResult {
        let wDiag = DiagnosticEngine()
        let wLexer = Lexer(source: wrapperSource, fileName: filePath, diagnostics: wDiag)
        let wTokens = wLexer.tokenize()
        let wParser = Parser(tokens: wTokens, diagnostics: wDiag)
        let wParsedAst = wParser.parse()
        let wImportResolver = ImportResolver(sourceDir: sourceDir, libPaths: stdlibPaths, diagnostics: wDiag)
        let wAst = wImportResolver.resolve(wParsedAst)
        let wChecker = TypeChecker(ast: wAst, diagnostics: wDiag)
        let wResult = wChecker.check()

        if wDiag.hasErrors {
            return .compileError("compile error")
        }

        let lowering = MIRLowering(typeCheckResult: wResult)
        let mir = lowering.lower()
        let optimizer = MIROptimizer()
        let optimized = optimizer.optimize(mir)
        let codeGen = CodeGen()
        let module = codeGen.generate(optimized)
        let vm = VM(module: module, config: RuntimeConfig())

        do {
            try vm.run()
            return .pass
        } catch {
            if let vmErr = error as? VMError {
                return .fail("\(vmErr)")
            } else {
                return .fail("\(error)")
            }
        }
    }

    /// Clear cached test results for a URI (called on didChange)
    public static func invalidateCache(uri: String) {
        testResultsCache.removeValue(forKey: uri)
    }

    // MARK: - Private Helpers

    /// Discover top-level functions with @Test annotation in the AST
    private static func discoverTestFunctions(ast: SourceFile) -> [String] {
        var testFunctions: [String] = []
        for decl in ast.declarations {
            if case .function(let fn) = decl {
                if fn.annotations.contains(where: { $0.name == "Test" }) {
                    testFunctions.append(fn.name)
                }
            }
        }
        return testFunctions
    }

    /// Info about a class that contains @Test methods
    struct ClassTestInfo {
        let line: Int                           // line of the class keyword
        let testNames: [String]                 // names of @Test methods
        let methods: [(String, Int)]            // (methodName, line) for each @Test method
    }

    /// Discover classes containing @Test methods
    private static func discoverClassTests(ast: SourceFile) -> [String: ClassTestInfo] {
        var result: [String: ClassTestInfo] = [:]
        for decl in ast.declarations {
            if case .classDecl(let cls) = decl {
                var testNames: [String] = []
                var methods: [(String, Int)] = []
                for member in cls.members {
                    if case .function(let fn) = member {
                        if fn.annotations.contains(where: { $0.name == "Test" }) {
                            testNames.append(fn.name)
                            methods.append((fn.name, fn.span.start.line))
                        }
                    }
                }
                if !testNames.isEmpty {
                    result[cls.name] = ClassTestInfo(
                        line: cls.span.start.line,
                        testNames: testNames,
                        methods: methods
                    )
                }
            }
        }
        return result
    }

    /// Strip the main() function from source code for test wrapper injection
    private static func stripMainFunction(_ source: String) -> String {
        guard let range = source.range(of: "fun main(") else { return source }
        let before = source[source.startIndex..<range.lowerBound]

        let afterStart = range.lowerBound
        var depth = 0
        var foundOpenBrace = false
        var endIdx = source.endIndex
        var idx = source.index(after: afterStart)
        while idx < source.endIndex {
            let ch = source[idx]
            if ch == "{" {
                depth += 1
                foundOpenBrace = true
            } else if ch == "}" {
                depth -= 1
                if foundOpenBrace && depth == 0 {
                    endIdx = source.index(after: idx)
                    break
                }
            }
            idx = source.index(after: idx)
        }

        let after = source[endIdx..<source.endIndex]
        return String(before) + String(after)
    }

    /// Find the stdlib directory for import resolution
    private static func findStdlibDir(workspaceRoot: String?) -> String? {
        let fm = FileManager.default

        // 1. Check ROCKIT_STDLIB_DIR environment variable
        if let envDir = ProcessInfo.processInfo.environment["ROCKIT_STDLIB_DIR"],
           fm.fileExists(atPath: envDir) {
            return envDir
        }

        // 2. Try Stage1/stdlib relative to workspace root (development)
        if let root = workspaceRoot {
            let devStdlib = (root as NSString).appendingPathComponent("Stage1/stdlib")
            if fm.fileExists(atPath: (devStdlib as NSString).appendingPathComponent("rockit")) {
                return devStdlib
            }
        }

        // 3. Try Stage1/stdlib relative to CWD (development)
        let cwd = fm.currentDirectoryPath
        let cwdStdlib = (cwd as NSString).appendingPathComponent("Stage1/stdlib")
        if fm.fileExists(atPath: (cwdStdlib as NSString).appendingPathComponent("rockit")) {
            return cwdStdlib
        }

        // 4. Try relative to the executable (installed: share/rockit/stdlib)
        let execPath = CommandLine.arguments[0]
        let execDir = (execPath as NSString).deletingLastPathComponent
        let installedStdlib = ((execDir as NSString).appendingPathComponent("..") as NSString)
            .appendingPathComponent("share/rockit/stdlib")
        if fm.fileExists(atPath: (installedStdlib as NSString).appendingPathComponent("rockit")) {
            return installedStdlib
        }

        return nil
    }
}
