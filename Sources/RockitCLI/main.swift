// main.swift
// RockitCLI — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation
import RockitKit
import RockitLSP

let version = "0.1.0-alpha"

func printUsage() {
    print("""
    rockit \(version) — Rockit Language Compiler
    Dark Matter Tech

    USAGE:
        rockit <subcommand> [options] <file>

    COMMANDS:
        run <file>            Execute a .rok or .rokb file
        build <file.rok>      Compile to bytecode (.rokb)
        build-native <file>   Compile to native executable via LLVM
        run-native <file>     Compile to native and execute
        emit-llvm <file>      Emit LLVM IR (.ll) for inspection
        launch                Start interactive REPL
        init [name]           Create a new Rockit project
        test [file]           Run tests (supports class-based test suites)
        bench [file|dir]      Run benchmarks and track performance
        update                Update rockit to the latest version
        lsp                   Start Language Server Protocol server
        setup-editors         Install editor plugins (VS Code, Vim, Neovim, JetBrains)
        lex <file.rok>        Tokenize and dump tokens
        parse <file.rok>      Parse and dump AST
        check <file.rok>      Type-check and report diagnostics
        lower <file.rok>      Lower to MIR and dump
        version               Print version

    TEST OPTIONS:
        --filter <name>       Filter tests (function, ClassName, or ClassName::method)
        --detailed            Show per-assertion results
        --watch               Watch for file changes and re-run tests
        --scheme <name>       Run a named test scheme from fuel.toml

    BENCH OPTIONS:
        --runs <n>            Number of measurement runs (default: 5)
        --warmup <n>          Number of warmup runs (default: 2)
        --save                Save results to .rockit/bench_history.json

    OPTIONS:
        --dump-tokens         Show token stream (with lex)
        --dump-ast            Show AST (with parse)
        --dump-types          Show inferred types (with check)
        --dump-mir            Show optimized MIR (with lower)
        --dump-mir-unoptimized Show MIR before optimization
        --dump-bytecode       Show disassembled bytecode (with build)
        --dump-llvm           Show LLVM IR (with build-native)
        --trace               Show instruction-level execution trace (with run)
        --gc-stats            Show ARC/memory statistics (with run)
        --no-color            Disable colored output
    """)
}

func lex(file: String, dumpTokens: Bool) {
    guard FileManager.default.fileExists(atPath: file) else {
        print("error: file not found: \(file)")
        exit(1)
    }

    guard let source = try? String(contentsOfFile: file, encoding: .utf8) else {
        print("error: could not read file: \(file)")
        exit(1)
    }

    let diagnostics = DiagnosticEngine()
    let lexer = Lexer(source: source, fileName: file, diagnostics: diagnostics)
    let tokens = lexer.tokenize()

    if dumpTokens {
        let nonNewline = tokens.filter { $0.kind != .newline }
        let maxLexemeLen = nonNewline.map { $0.lexeme.count }.max() ?? 0
        let padLen = min(max(maxLexemeLen, 10), 30)

        for token in tokens {
            if token.kind == .newline { continue }
            if token.kind == .eof {
                print("  EOF")
                break
            }

            let loc = "\(token.span.start.line):\(token.span.start.column)"
            let padLoc = loc.padding(toLength: 8, withPad: " ", startingAt: 0)
            let padLex = token.lexeme.padding(toLength: padLen, withPad: " ", startingAt: 0)

            print("  \(padLoc) \(padLex) \(token.kind)")
        }
    }

    // Summary
    let tokenCount = tokens.filter { $0.kind != .newline && $0.kind != .eof }.count
    print("\n\(file): \(tokenCount) tokens")

    if diagnostics.hasErrors {
        diagnostics.dump()
        print("\n\(diagnostics.errorCount) error(s)")
        exit(1)
    } else {
        print("OK")
    }
}

func parseCommand(file: String, dumpAST: Bool) {
    guard FileManager.default.fileExists(atPath: file) else {
        print("error: file not found: \(file)")
        exit(1)
    }

    guard let source = try? String(contentsOfFile: file, encoding: .utf8) else {
        print("error: could not read file: \(file)")
        exit(1)
    }

    let diagnostics = DiagnosticEngine()
    let lexer = Lexer(source: source, fileName: file, diagnostics: diagnostics)
    let tokens = lexer.tokenize()
    let parser = Parser(tokens: tokens, diagnostics: diagnostics)
    let ast = parser.parse()

    if dumpAST {
        print(ast.dump())
    }

    let declCount = ast.declarations.count
    print("\n\(file): \(declCount) declaration(s)")

    if diagnostics.hasErrors {
        diagnostics.dump()
        print("\n\(diagnostics.errorCount) error(s)")
        exit(1)
    } else {
        print("OK")
    }
}

func checkCommand(file: String, dumpTypes: Bool) {
    guard FileManager.default.fileExists(atPath: file) else {
        print("error: file not found: \(file)")
        exit(1)
    }

    guard let source = try? String(contentsOfFile: file, encoding: .utf8) else {
        print("error: could not read file: \(file)")
        exit(1)
    }

    let diagnostics = DiagnosticEngine()
    let lexer = Lexer(source: source, fileName: file, diagnostics: diagnostics)
    let tokens = lexer.tokenize()
    let parser = Parser(tokens: tokens, diagnostics: diagnostics)
    let parsedAST = parser.parse()

    let sourceDir = (file as NSString).deletingLastPathComponent
    let importResolver = ImportResolver(sourceDir: sourceDir, libPaths: findStdlibDir().map { [$0] } ?? [], diagnostics: diagnostics)
    let ast = importResolver.resolve(parsedAST)

    let checker = TypeChecker(ast: ast, diagnostics: diagnostics)
    let result = checker.check()

    if dumpTypes {
        print("--- Inferred Types ---")
        for (id, type) in result.typeMap.sorted(by: { ($0.key.line, $0.key.column) < ($1.key.line, $1.key.column) }) {
            print("  \(id.line):\(id.column)  \(type)")
        }
        print("--- End Types ---")
    }

    let declCount = ast.declarations.count
    let typeCount = result.typeMap.count
    print("\n\(file): \(declCount) declaration(s), \(typeCount) type(s) inferred")

    if diagnostics.hasErrors {
        diagnostics.dump()
        print("\n\(diagnostics.errorCount) error(s)")
        exit(1)
    } else {
        print("OK")
    }
}

func lowerCommand(file: String, dumpMIR: Bool, dumpUnoptimized: Bool = false) {
    guard FileManager.default.fileExists(atPath: file) else {
        print("error: file not found: \(file)")
        exit(1)
    }

    guard let source = try? String(contentsOfFile: file, encoding: .utf8) else {
        print("error: could not read file: \(file)")
        exit(1)
    }

    let diagnostics = DiagnosticEngine()
    let lexer = Lexer(source: source, fileName: file, diagnostics: diagnostics)
    let tokens = lexer.tokenize()
    let parser = Parser(tokens: tokens, diagnostics: diagnostics)
    let ast = parser.parse()

    let checker = TypeChecker(ast: ast, diagnostics: diagnostics)
    let typeResult = checker.check()

    let lowering = MIRLowering(typeCheckResult: typeResult)
    let unoptimized = lowering.lower()

    if dumpUnoptimized {
        print("--- Unoptimized MIR ---")
        print(unoptimized)
        print("--- End Unoptimized MIR ---")
    }

    let optimizer = MIROptimizer()
    let module = optimizer.optimize(unoptimized)

    if dumpMIR {
        print(module)
    }

    let funcCount = module.functions.count
    let instrCount = module.totalInstructionCount
    let typeCount = module.types.count
    let globalCount = module.globals.count
    let savedInstrs = unoptimized.totalInstructionCount - instrCount
    let savedFuncs = unoptimized.functions.count - funcCount
    print("\n\(file): \(funcCount) function(s), \(instrCount) instruction(s), \(typeCount) type(s), \(globalCount) global(s)")
    if savedInstrs > 0 || savedFuncs > 0 {
        print("  optimized: \(savedInstrs) instruction(s) eliminated, \(savedFuncs) function(s) removed")
    }

    if diagnostics.hasErrors {
        diagnostics.dump()
        print("\n\(diagnostics.errorCount) error(s)")
        exit(1)
    } else {
        print("OK")
    }
}

func buildCommand(file: String, dumpBytecode: Bool) {
    guard FileManager.default.fileExists(atPath: file) else {
        print("error: file not found: \(file)")
        exit(1)
    }

    guard let source = try? String(contentsOfFile: file, encoding: .utf8) else {
        print("error: could not read file: \(file)")
        exit(1)
    }

    let diagnostics = DiagnosticEngine()
    let lexer = Lexer(source: source, fileName: file, diagnostics: diagnostics)
    let tokens = lexer.tokenize()
    let parser = Parser(tokens: tokens, diagnostics: diagnostics)
    let parsedAST = parser.parse()

    let sourceDir = (file as NSString).deletingLastPathComponent
    let importResolver = ImportResolver(sourceDir: sourceDir, libPaths: findStdlibDir().map { [$0] } ?? [], diagnostics: diagnostics)
    let ast = importResolver.resolve(parsedAST)

    let checker = TypeChecker(ast: ast, diagnostics: diagnostics)
    let typeResult = checker.check()

    if diagnostics.hasErrors {
        diagnostics.dump()
        print("\n\(diagnostics.errorCount) error(s)")
        exit(1)
    }

    let lowering = MIRLowering(typeCheckResult: typeResult)
    let unoptimized = lowering.lower()
    let optimizer = MIROptimizer()
    let optimized = optimizer.optimize(unoptimized)

    let codeGen = CodeGen()
    let bytecodeModule = codeGen.generate(optimized)

    if dumpBytecode {
        print(CodeGen.disassemble(bytecodeModule))
    }

    // Serialize to .rokb
    let outputPath = file.hasSuffix(".rok")
        ? String(file.dropLast(4)) + ".rokb"
        : file + ".rokb"

    let bytes = CodeGen.serialize(bytecodeModule)
    let data = Data(bytes)
    do {
        try data.write(to: URL(fileURLWithPath: outputPath))
    } catch {
        print("error: could not write output file: \(outputPath)")
        exit(1)
    }

    let funcCount = bytecodeModule.functions.count
    let bytecodeSize = bytecodeModule.totalBytecodeSize
    let totalSize = bytes.count
    print("\n\(file) \u{2192} \(outputPath)")
    print("  \(funcCount) function(s), \(bytecodeSize) bytes bytecode, \(totalSize) bytes total")
    print("OK")
}

func runCommand(file: String, trace: Bool, gcStats: Bool) {
    guard FileManager.default.fileExists(atPath: file) else {
        print("error: file not found: \(file)")
        exit(1)
    }

    let module: BytecodeModule

    if file.hasSuffix(".rokb") {
        // Load pre-compiled bytecode
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else {
            print("error: could not read file: \(file)")
            exit(1)
        }
        do {
            module = try BytecodeLoader.load(bytes: Array(data))
        } catch {
            print("error: \(error)")
            exit(1)
        }
    } else {
        // Compile from source first
        guard let source = try? String(contentsOfFile: file, encoding: .utf8) else {
            print("error: could not read file: \(file)")
            exit(1)
        }

        let diagnostics = DiagnosticEngine()
        let lexer = Lexer(source: source, fileName: file, diagnostics: diagnostics)
        let tokens = lexer.tokenize()
        let parser = Parser(tokens: tokens, diagnostics: diagnostics)
        let parsedAST = parser.parse()

        let sourceDir = (file as NSString).deletingLastPathComponent
        let importResolver = ImportResolver(sourceDir: sourceDir, libPaths: findStdlibDir().map { [$0] } ?? [], diagnostics: diagnostics)
        let ast = importResolver.resolve(parsedAST)

        let checker = TypeChecker(ast: ast, diagnostics: diagnostics)
        let typeResult = checker.check()

        if diagnostics.hasErrors {
            diagnostics.dump()
            print("\n\(diagnostics.errorCount) error(s)")
            exit(1)
        }

        let lowering = MIRLowering(typeCheckResult: typeResult)
        let unoptimized = lowering.lower()
        let optimizer = MIROptimizer()
        let optimized = optimizer.optimize(unoptimized)
        let codeGen = CodeGen()
        module = codeGen.generate(optimized)
    }

    let config = RuntimeConfig(traceExecution: trace, gcStats: gcStats)
    let vm = VM(module: module, config: config)

    do {
        try vm.run()
        if gcStats {
            vm.printGCStats()
        }
    } catch {
        let stackTrace = vm.captureStackTrace(error: error as! VMError)
        print(stackTrace)
        exit(1)
    }
}

// MARK: - REPL

/// Count unmatched braces in a string, skipping braces inside string literals.
func countUnmatchedBraces(_ text: String) -> Int {
    var count = 0
    var inString = false
    var prevChar: Character = "\0"
    for ch in text {
        if ch == "\"" && prevChar != "\\" {
            inString = !inString
        } else if !inString {
            if ch == "{" { count += 1 }
            else if ch == "}" { count -= 1 }
        }
        prevChar = ch
    }
    return count
}

func replCommand() {
    print("Rockit REPL v\(version)")
    print("Type expressions or statements. Type :help for commands.\n")

    // Accumulate top-level declarations (fun, class, etc.)
    var topDecls = ""
    // Accumulate statements that go inside main (val/var decls, etc.)
    var mainBody = ""
    // Input history
    var history: [String] = []
    // Input counter
    var inputCount = 0

    while true {
        inputCount += 1
        print("rockit[\(inputCount)]> ", terminator: "")
        guard let line = readLine() else { break }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue; }

        // REPL commands
        if trimmed.hasPrefix(":") {
            let cmd = trimmed.lowercased()
            if cmd == ":quit" || cmd == ":q" { break }
            if cmd == ":reset" {
                topDecls = ""
                mainBody = ""
                print("State cleared.")
                continue
            }
            if cmd == ":help" || cmd == ":h" {
                print("""
                REPL Commands:
                  :help, :h         Show this help
                  :quit, :q         Exit the REPL
                  :reset            Clear all definitions and state
                  :type <expr>      Show the type of an expression
                  :ast <expr>       Show the AST of an expression
                  :env              Show defined symbols
                  :history          Show input history
                  :source           Show accumulated source code
                """)
                continue
            }
            if cmd == ":env" {
                if topDecls.isEmpty && mainBody.isEmpty {
                    print("(no definitions)")
                } else {
                    if !topDecls.isEmpty {
                        print("── Top-level declarations ──")
                        // Extract declaration names
                        for declLine in topDecls.components(separatedBy: "\n") {
                            let dl = declLine.trimmingCharacters(in: .whitespaces)
                            if dl.hasPrefix("fun ") || dl.hasPrefix("class ") || dl.hasPrefix("data class ") ||
                               dl.hasPrefix("sealed class ") || dl.hasPrefix("enum ") ||
                               dl.hasPrefix("interface ") || dl.hasPrefix("object ") {
                                // Print up to the opening brace or paren
                                if let braceIdx = dl.firstIndex(of: "{") {
                                    print("  \(dl[dl.startIndex..<braceIdx].trimmingCharacters(in: .whitespaces))")
                                } else if let parenIdx = dl.firstIndex(of: "(") {
                                    let prefix = dl[dl.startIndex..<parenIdx]
                                    print("  \(prefix)(...)")
                                } else {
                                    print("  \(dl)")
                                }
                            }
                        }
                    }
                    if !mainBody.isEmpty {
                        print("── Variables ──")
                        for bodyLine in mainBody.components(separatedBy: "\n") {
                            let bl = bodyLine.trimmingCharacters(in: .whitespaces)
                            if bl.hasPrefix("val ") || bl.hasPrefix("var ") {
                                // Print the val/var declaration
                                if let eqIdx = bl.firstIndex(of: "=") {
                                    print("  \(bl[bl.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces))")
                                } else {
                                    print("  \(bl)")
                                }
                            }
                        }
                    }
                }
                continue
            }
            if cmd == ":history" {
                if history.isEmpty {
                    print("(no history)")
                } else {
                    for (i, entry) in history.enumerated() {
                        let display = entry.contains("\n") ? entry.components(separatedBy: "\n").first! + " ..." : entry
                        print("  [\(i + 1)] \(display)")
                    }
                }
                continue
            }
            if cmd == ":source" {
                if topDecls.isEmpty && mainBody.isEmpty {
                    print("(no source)")
                } else {
                    let source = topDecls + "fun main(): Unit {\n\(mainBody)}\n"
                    print(source)
                }
                continue
            }
            if trimmed.hasPrefix(":type ") {
                let expr = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if expr.isEmpty { print("Usage: :type <expression>"); continue }
                // Wrap expression, type-check, extract type from symbol table
                let source = topDecls + "fun main(): Unit {\n\(mainBody)  val __repl_type_query__ = \(expr)\n}\n"
                let diagnostics = DiagnosticEngine()
                let lexer = Lexer(source: source, fileName: "<repl>", diagnostics: diagnostics)
                let tokens = lexer.tokenize()
                let parser = Parser(tokens: tokens, diagnostics: diagnostics)
                let ast = parser.parse()
                let checker = TypeChecker(ast: ast, diagnostics: diagnostics)
                let result = checker.check()
                if diagnostics.hasErrors {
                    diagnostics.dump()
                } else {
                    if let sym = result.symbolTable.lookup("__repl_type_query__") {
                        print("\(sym.type)")
                    } else {
                        print("Could not determine type")
                    }
                }
                continue
            }
            if trimmed.hasPrefix(":ast ") {
                let expr = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if expr.isEmpty { print("Usage: :ast <expression>"); continue }
                let source = topDecls + "fun main(): Unit {\n\(mainBody)  \(expr)\n}\n"
                let diagnostics = DiagnosticEngine()
                let lexer = Lexer(source: source, fileName: "<repl>", diagnostics: diagnostics)
                let tokens = lexer.tokenize()
                let parser = Parser(tokens: tokens, diagnostics: diagnostics)
                let ast = parser.parse()
                if diagnostics.hasErrors {
                    diagnostics.dump()
                } else {
                    print(ast)
                }
                continue
            }
            print("Unknown command: \(trimmed). Type :help for available commands.")
            continue
        }

        // Check if this is a top-level declaration (fun, class, etc.)
        let isTopDecl = trimmed.hasPrefix("fun ") || trimmed.hasPrefix("class ") ||
                        trimmed.hasPrefix("data ") || trimmed.hasPrefix("sealed ") ||
                        trimmed.hasPrefix("enum ") || trimmed.hasPrefix("interface ") ||
                        trimmed.hasPrefix("object ")

        // Multi-line support: string-aware brace counting
        var fullInput = line
        var braceCount = countUnmatchedBraces(fullInput)
        while braceCount > 0 {
            print("  ... ", terminator: "")
            guard let continuation = readLine() else { break }
            fullInput += "\n" + continuation
            braceCount = countUnmatchedBraces(fullInput)
        }

        // Add to history
        history.append(fullInput)

        let isValVar = trimmed.hasPrefix("val ") || trimmed.hasPrefix("var ")

        // Determine if this looks like a statement keyword (not an expression)
        let isStatement = trimmed.hasPrefix("println(") || trimmed.hasPrefix("print(") ||
                          trimmed.hasPrefix("if ") || trimmed.hasPrefix("if(") ||
                          trimmed.hasPrefix("while ") || trimmed.hasPrefix("while(") ||
                          trimmed.hasPrefix("for ") || trimmed.hasPrefix("for(") ||
                          trimmed.hasPrefix("return ") || trimmed.hasPrefix("return\n") ||
                          trimmed == "return"

        if isTopDecl {
            // Add declaration to top-level preamble
            topDecls += fullInput + "\n\n"
            let source = topDecls + "fun main(): Unit {\n\(mainBody)}\n"
            let diagnostics = DiagnosticEngine()
            let lexer = Lexer(source: source, fileName: "<repl>", diagnostics: diagnostics)
            let tokens = lexer.tokenize()
            let parser = Parser(tokens: tokens, diagnostics: diagnostics)
            let ast = parser.parse()
            let checker = TypeChecker(ast: ast, diagnostics: diagnostics)
            _ = checker.check()
            if diagnostics.hasErrors {
                diagnostics.dump()
                // Undo the addition
                topDecls = String(topDecls.dropLast(fullInput.count + 2))
            } else {
                print("OK")
            }
            continue
        }

        if isValVar {
            // Accumulate val/var in main body
            let newBody = mainBody + "  " + fullInput + "\n"
            let source = topDecls + "fun main(): Unit {\n\(newBody)}\n"
            let diagnostics = DiagnosticEngine()
            let lexer = Lexer(source: source, fileName: "<repl>", diagnostics: diagnostics)
            let tokens = lexer.tokenize()
            let parser = Parser(tokens: tokens, diagnostics: diagnostics)
            let ast = parser.parse()
            let checker = TypeChecker(ast: ast, diagnostics: diagnostics)
            _ = checker.check()
            if diagnostics.hasErrors {
                diagnostics.dump()
            } else {
                mainBody = newBody
            }
            continue
        }

        // For non-statement expressions, try auto-printing first
        if !isStatement {
            let exprSource = topDecls + "fun main(): Unit {\n\(mainBody)  println(toString(\(fullInput)))\n}\n"
            let exprDiag = DiagnosticEngine()
            let exprLexer = Lexer(source: exprSource, fileName: "<repl>", diagnostics: exprDiag)
            let exprTokens = exprLexer.tokenize()
            let exprParser = Parser(tokens: exprTokens, diagnostics: exprDiag)
            let exprAST = exprParser.parse()
            let exprChecker = TypeChecker(ast: exprAST, diagnostics: exprDiag)
            let exprResult = exprChecker.check()

            if !exprDiag.hasErrors {
                let lowering = MIRLowering(typeCheckResult: exprResult)
                let mir = lowering.lower()
                let optimizer = MIROptimizer()
                let optimized = optimizer.optimize(mir)
                let codeGen = CodeGen()
                let module = codeGen.generate(optimized)
                let vm = VM(module: module, config: RuntimeConfig())
                do { try vm.run() } catch {
                    let st = vm.captureStackTrace(error: error as! VMError)
                    print(st)
                }
                continue
            }
        }

        // Fall back to statement compilation
        let source = topDecls + "fun main(): Unit {\n\(mainBody)  \(fullInput)\n}\n"
        let diagnostics = DiagnosticEngine()
        let lexer = Lexer(source: source, fileName: "<repl>", diagnostics: diagnostics)
        let tokens = lexer.tokenize()
        let parser = Parser(tokens: tokens, diagnostics: diagnostics)
        let ast = parser.parse()
        let checker = TypeChecker(ast: ast, diagnostics: diagnostics)
        let typeResult = checker.check()

        if diagnostics.hasErrors {
            diagnostics.dump()
            continue
        }

        let lowering = MIRLowering(typeCheckResult: typeResult)
        let mir = lowering.lower()
        let optimizer = MIROptimizer()
        let optimized = optimizer.optimize(mir)
        let codeGen = CodeGen()
        let module = codeGen.generate(optimized)
        let vm = VM(module: module, config: RuntimeConfig())
        do { try vm.run() } catch {
            let st = vm.captureStackTrace(error: error as! VMError)
            print(st)
        }
    }
}

// MARK: - Init Command

func initCommand(name: String) {
    let fm = FileManager.default
    let projectDir = Platform.pathJoin(fm.currentDirectoryPath, name)

    guard !fm.fileExists(atPath: projectDir) else {
        print("error: directory '\(name)' already exists")
        exit(1)
    }

    do {
        try fm.createDirectory(atPath: Platform.pathJoin(projectDir, "src"), withIntermediateDirectories: true)
        try fm.createDirectory(atPath: Platform.pathJoin(projectDir, "tests"), withIntermediateDirectories: true)

        // fuel.toml
        let fuelToml = """
        [package]
        name = "\(name)"
        version = "0.1.0"

        [dependencies]

        [test]
        directory = "tests"
        recursive = true
        timeout = 30
        """
        try fuelToml.write(toFile: Platform.pathJoin(projectDir, "fuel.toml"), atomically: true, encoding: .utf8)

        // src/main.rok
        let mainRok = """
        fun main(): Unit {
            println("Hello, Rockit!")
        }
        """
        try mainRok.write(toFile: Platform.pathJoin(projectDir, "src", "main.rok"), atomically: true, encoding: .utf8)

        // tests/test_main.rok
        let testRok = """
        import rockit.testing.probe

        // Top-level @Test functions
        @Test
        fun testHello() {
            val expected = "Hello, Rockit!"
            assertEquals(expected, "Hello, Rockit!")
        }

        // Class-based test suite — setUp/tearDown run before/after each @Test
        class ArithmeticTests {
            fun setUp() { }
            fun tearDown() { }

            @Test fun testAddition() {
                assertEquals(2 + 2, 4)
            }

            @Test fun testComparisons() {
                assertTrue(10 > 5)
                assertFalse(1 == 2)
            }
        }
        """
        try testRok.write(toFile: Platform.pathJoin(projectDir, "tests", "test_main.rok"), atomically: true, encoding: .utf8)

        print("Created new Rockit project '\(name)'")
        print("  \(name)/fuel.toml")
        print("  \(name)/src/main.rok")
        print("  \(name)/tests/test_main.rok")
        print("\nGet started:")
        print("  cd \(name)")
        print("  rockit run src/main.rok")
    } catch {
        print("error: could not create project: \(error)")
        exit(1)
    }
}

// MARK: - Test Command (Probe Test Framework)

func testCommand(file: String?, filter: String? = nil, detailed: Bool = false, scheme: String? = nil) {
    let fm = FileManager.default
    let stdlibPaths: [String] = findStdlibDir().map { [$0] } ?? []

    var testFiles: [String] = []

    if let file = file {
        guard fm.fileExists(atPath: file) else {
            print("error: file not found: \(file)")
            exit(1)
        }
        testFiles = [file]
    } else {
        // Determine test directory and settings from fuel.toml
        let fuelPath = Platform.pathJoin(fm.currentDirectoryPath, "fuel.toml")
        let fuelConfig = parseFuelToml(fuelPath)
        let testDir = fuelConfig.testDirectory ?? "tests"
        let testsDir = Platform.pathJoin(fm.currentDirectoryPath, testDir)

        guard fm.fileExists(atPath: testsDir) else {
            print("error: no \(testDir)/ directory found")
            exit(1)
        }

        // If a scheme is specified, filter by scheme include/exclude patterns
        if let scheme = scheme, let schemeConfig = fuelConfig.testSchemes[scheme] {
            for include in schemeConfig.include {
                if include == "*" {
                    // Include all subdirectories
                    if let enumerator = fm.enumerator(atPath: testsDir) {
                        while let item = enumerator.nextObject() as? String {
                            if item.hasSuffix(".rok") {
                                let subdir = (item as NSString).deletingLastPathComponent
                                let excluded = schemeConfig.exclude.contains(where: { subdir.hasPrefix($0) })
                                if !excluded {
                                    testFiles.append(Platform.pathJoin(testsDir, item))
                                }
                            }
                        }
                    }
                } else {
                    let subDir = Platform.pathJoin(testsDir, include)
                    if fm.fileExists(atPath: subDir) {
                        if let enumerator = fm.enumerator(atPath: subDir) {
                            while let item = enumerator.nextObject() as? String {
                                if item.hasSuffix(".rok") {
                                    testFiles.append(Platform.pathJoin(subDir, item))
                                }
                            }
                        }
                    }
                }
            }
        } else {
            // No scheme — find all .rok files recursively
            if let enumerator = fm.enumerator(atPath: testsDir) {
                while let item = enumerator.nextObject() as? String {
                    if item.hasSuffix(".rok") {
                        testFiles.append(Platform.pathJoin(testsDir, item))
                    }
                }
            }
        }
        testFiles.sort()

        if testFiles.isEmpty {
            print("No test files found in \(testDir)/")
            exit(0)
        }
    }

    var totalPassed = 0
    var totalFailed = 0
    var totalSkipped = 0

    for testFile in testFiles {
        guard let source = try? String(contentsOfFile: testFile, encoding: .utf8) else {
            print("  SKIP  \(testFile) (could not read)")
            totalSkipped += 1
            continue
        }

        let diagnostics = DiagnosticEngine()
        let lexer = Lexer(source: source, fileName: testFile, diagnostics: diagnostics)
        let tokens = lexer.tokenize()
        let parser = Parser(tokens: tokens, diagnostics: diagnostics)
        let parsedAST = parser.parse()

        let sourceDir = (testFile as NSString).deletingLastPathComponent
        let importResolver = ImportResolver(sourceDir: sourceDir, libPaths: stdlibPaths, diagnostics: diagnostics)
        let ast = importResolver.resolve(parsedAST)

        let checker = TypeChecker(ast: ast, diagnostics: diagnostics)
        let typeResult = checker.check()

        if diagnostics.hasErrors {
            print("  FAIL  \(testFile) (compilation errors)")
            diagnostics.dump()
            totalFailed += 1
            continue
        }

        // Discover @Test annotated functions (top-level and class members)
        var tests = discoverTests(ast: ast)

        // Apply --filter if provided
        if let filter = filter {
            if filter.contains("::") {
                // Exact match: "ClassName::methodName"
                tests = tests.filter { $0.qualifiedName == filter }
            } else {
                // Match class name (all tests in class) OR function name
                tests = tests.filter {
                    $0.className == filter || $0.functionName == filter
                }
            }
        }

        if tests.isEmpty && filter == nil {
            // No @Test functions and no filter — run file as a whole (legacy mode)
            let lowering = MIRLowering(typeCheckResult: typeResult)
            let mir = lowering.lower()
            let optimizer = MIROptimizer()
            let optimized = optimizer.optimize(mir)
            let codeGen = CodeGen()
            let module = codeGen.generate(optimized)
            let vm = VM(module: module, config: RuntimeConfig())

            do {
                try vm.run()
                print("  PASS  \(testFile)")
                totalPassed += 1
            } catch {
                let st = vm.captureStackTrace(error: error as! VMError)
                print("  FAIL  \(testFile)")
                print(st)
                totalFailed += 1
            }
        } else {
            // Run each @Test function individually
            let fileName = (testFile as NSString).lastPathComponent
            // Strip existing main() to allow test wrapper main
            let sourceWithoutMain = stripMainFunction(source)
            for test in tests {
                // Generate a wrapper main() that calls this test function
                let callCode: String
                if let cls = test.className {
                    // Class method: instantiate, optionally call setUp/tearDown
                    var body = "    val __t = \(cls)()\n"
                    if test.hasSetUp { body += "    __t.setUp()\n" }
                    body += "    __t.\(test.functionName)()\n"
                    if test.hasTearDown { body += "    __t.tearDown()\n" }
                    callCode = body
                } else {
                    callCode = "    \(test.functionName)()\n"
                }

                let wrapperSource: String
                if detailed {
                    // Recording mode: assertions record P/F instead of panicking
                    wrapperSource = sourceWithoutMain
                        + "\nfun main() {\n"
                        + "    __probeRecording = 1\n"
                        + callCode
                        + "    println(\"__PROBE_RESULTS_BEGIN\")\n"
                        + "    println(__probeResults)\n"
                        + "    println(\"__PROBE_RESULTS_END\")\n"
                        + "    if (__probeFailed > 0) {\n"
                        + "        panic(\"test failed\")\n"
                        + "    }\n"
                        + "}\n"
                } else {
                    wrapperSource = sourceWithoutMain + "\nfun main() {\n" + callCode + "}\n"
                }

                let displayName = "\(fileName)::\(test.qualifiedName)"

                let wDiag = DiagnosticEngine()
                let wLexer = Lexer(source: wrapperSource, fileName: testFile, diagnostics: wDiag)
                let wTokens = wLexer.tokenize()
                let wParser = Parser(tokens: wTokens, diagnostics: wDiag)
                let wParsedAst = wParser.parse()
                let wImportResolver = ImportResolver(sourceDir: sourceDir, libPaths: stdlibPaths, diagnostics: wDiag)
                let wAst = wImportResolver.resolve(wParsedAst)
                let wChecker = TypeChecker(ast: wAst, diagnostics: wDiag)
                let wResult = wChecker.check()

                if wDiag.hasErrors {
                    print("  FAIL  \(displayName) (compilation error)")
                    totalFailed += 1
                    continue
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
                    print("  PASS  \(displayName)")
                    totalPassed += 1
                } catch {
                    if let vmErr = error as? VMError {
                        print("  FAIL  \(displayName) — \(vmErr)")
                    } else {
                        print("  FAIL  \(displayName) — \(error)")
                    }
                    totalFailed += 1
                }
            }
        }
    }

    let total = totalPassed + totalFailed + totalSkipped
    print("\n\(total) test(s): \(totalPassed) passed, \(totalFailed) failed, \(totalSkipped) skipped")
    if totalFailed > 0 { exit(1) }
}

// MARK: - Watch Test Command

#if os(macOS)
func watchTestCommand(file: String?, filter: String? = nil, detailed: Bool = false, scheme: String? = nil) {
    let fm = FileManager.default

    // Determine which directory to watch
    let watchDir: String
    if let file = file {
        watchDir = (file as NSString).deletingLastPathComponent
    } else {
        let fuelConfig = parseFuelToml(Platform.pathJoin(fm.currentDirectoryPath, "fuel.toml"))
        let testDir = fuelConfig.testDirectory ?? "tests"
        watchDir = Platform.pathJoin(fm.currentDirectoryPath, testDir)
    }

    guard fm.fileExists(atPath: watchDir) else {
        print("error: watch directory not found: \(watchDir)")
        exit(1)
    }

    print("Watching \(watchDir) for changes... (Ctrl+C to stop)\n")

    // Run tests once initially
    testCommand(file: file, filter: filter, detailed: detailed, scheme: scheme)

    // Watch for changes using DispatchSource (macOS FSEvents)
    let fd = open(watchDir, O_EVTONLY)
    guard fd >= 0 else {
        print("error: could not watch directory: \(watchDir)")
        exit(1)
    }

    let queue = DispatchQueue(label: "rockit.watch", qos: .default)
    let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd,
        eventMask: [.write, .rename, .delete],
        queue: queue
    )

    // Debounce: wait for changes to settle before re-running
    var lastRunTime = Date()
    let debounceInterval: TimeInterval = 0.5

    source.setEventHandler {
        let now = Date()
        guard now.timeIntervalSince(lastRunTime) > debounceInterval else { return }
        lastRunTime = now

        // Clear terminal and re-run
        DispatchQueue.main.async {
            print("\u{1B}[2J\u{1B}[H")  // ANSI clear screen + cursor home
            print("File change detected. Re-running tests...\n")
            testCommand(file: file, filter: filter, detailed: detailed, scheme: scheme)
            print("\nWatching for changes... (Ctrl+C to stop)")
        }
    }

    source.setCancelHandler {
        close(fd)
    }

    source.resume()

    // Keep the process alive
    dispatchMain()
}
#else
func watchTestCommand(file: String?, filter: String? = nil, detailed: Bool = false, scheme: String? = nil) {
    print("error: --watch is only supported on macOS")
    exit(1)
}
#endif

// MARK: - Benchmark Command

/// Discover functions with @Benchmark annotation in the AST.
func discoverBenchmarkFunctions(ast: SourceFile) -> [String] {
    var benchmarks: [String] = []
    for decl in ast.declarations {
        if case .function(let fn) = decl {
            if fn.annotations.contains(where: { $0.name == "Benchmark" }) {
                benchmarks.append(fn.name)
            }
        }
    }
    return benchmarks
}

func benchCommand(target: String?, runs: Int, warmup: Int, save: Bool) {
    let fm = FileManager.default
    let stdlibPaths: [String] = findStdlibDir().map { [$0] } ?? []

    var benchFiles: [String] = []

    if let target = target {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: target, isDirectory: &isDir) else {
            print("error: not found: \(target)")
            exit(1)
        }
        if isDir.boolValue {
            // Directory: find all bench_*.rok or *.rok files
            if let enumerator = fm.enumerator(atPath: target) {
                while let item = enumerator.nextObject() as? String {
                    if item.hasSuffix(".rok") {
                        benchFiles.append(Platform.pathJoin(target, item))
                    }
                }
            }
            benchFiles.sort()
        } else {
            benchFiles = [target]
        }
    } else {
        // Default: look for benchmarks/ directory
        let benchDir = Platform.pathJoin(fm.currentDirectoryPath, "benchmarks")
        if fm.fileExists(atPath: benchDir) {
            if let enumerator = fm.enumerator(atPath: benchDir) {
                while let item = enumerator.nextObject() as? String {
                    if item.hasSuffix(".rok") {
                        benchFiles.append(Platform.pathJoin(benchDir, item))
                    }
                }
            }
            benchFiles.sort()
        }
        if benchFiles.isEmpty {
            print("error: no benchmark files found. Provide a file/directory or create benchmarks/")
            exit(1)
        }
    }

    // Load previous results for comparison
    let historyPath = Platform.pathJoin(fm.currentDirectoryPath, ".rockit", "bench_history.json")
    let previousResults = loadBenchHistory(path: historyPath)

    var allResults: [String: BenchResult] = [:]

    for benchFile in benchFiles {
        guard let source = try? String(contentsOfFile: benchFile, encoding: .utf8) else {
            print("  SKIP  \(benchFile) (could not read)")
            continue
        }

        let benchName = ((benchFile as NSString).lastPathComponent as NSString).deletingPathExtension

        // Check for @Benchmark functions
        let diagnostics = DiagnosticEngine()
        let lexer = Lexer(source: source, fileName: benchFile, diagnostics: diagnostics)
        let tokens = lexer.tokenize()
        let parser = Parser(tokens: tokens, diagnostics: diagnostics)
        let parsedAST = parser.parse()

        let sourceDir = (benchFile as NSString).deletingLastPathComponent
        let importResolver = ImportResolver(sourceDir: sourceDir, libPaths: stdlibPaths, diagnostics: diagnostics)
        let ast = importResolver.resolve(parsedAST)

        let benchFunctions = discoverBenchmarkFunctions(ast: ast)

        if benchFunctions.isEmpty {
            // Whole-file benchmark mode
            let result = runWholeFileBenchmark(
                source: source, fileName: benchFile, sourceDir: sourceDir,
                stdlibPaths: stdlibPaths, warmup: warmup, runs: runs
            )
            if let result = result {
                allResults[benchName] = result
                printBenchResult(name: benchName, result: result, previous: previousResults?[benchName])
            }
        } else {
            // @Benchmark function mode
            let sourceWithoutMain = stripMainFunction(source)
            for benchFn in benchFunctions {
                let wrapperSource = sourceWithoutMain + "\nfun main() { \(benchFn)() }\n"
                let result = runWholeFileBenchmark(
                    source: wrapperSource, fileName: benchFile, sourceDir: sourceDir,
                    stdlibPaths: stdlibPaths, warmup: warmup, runs: runs
                )
                let name = "\(benchName)::\(benchFn)"
                if let result = result {
                    allResults[name] = result
                    printBenchResult(name: name, result: result, previous: previousResults?[name])
                }
            }
        }
    }

    if allResults.isEmpty {
        print("No benchmarks were run.")
        exit(1)
    }

    // Save results if --save
    if save {
        saveBenchHistory(path: historyPath, results: allResults)
        print("\nResults saved to \(historyPath)")
    }
}

struct BenchResult {
    let times: [Double]  // in milliseconds

    var min: Double { times.min() ?? 0 }
    var max: Double { times.max() ?? 0 }
    var avg: Double { times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count) }
    var median: Double {
        guard !times.isEmpty else { return 0 }
        let sorted = times.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2.0 : sorted[mid]
    }
}

func runWholeFileBenchmark(
    source: String, fileName: String, sourceDir: String,
    stdlibPaths: [String], warmup: Int, runs: Int
) -> BenchResult? {
    // Compile once
    let diagnostics = DiagnosticEngine()
    let lexer = Lexer(source: source, fileName: fileName, diagnostics: diagnostics)
    let tokens = lexer.tokenize()
    let parser = Parser(tokens: tokens, diagnostics: diagnostics)
    let parsedAST = parser.parse()
    let importResolver = ImportResolver(sourceDir: sourceDir, libPaths: stdlibPaths, diagnostics: diagnostics)
    let ast = importResolver.resolve(parsedAST)
    let checker = TypeChecker(ast: ast, diagnostics: diagnostics)
    let typeResult = checker.check()

    if diagnostics.hasErrors {
        print("  ERROR \(fileName) (compilation errors)")
        diagnostics.dump()
        return nil
    }

    let lowering = MIRLowering(typeCheckResult: typeResult)
    let mir = lowering.lower()
    let optimizer = MIROptimizer()
    let optimized = optimizer.optimize(mir)
    let codeGen = CodeGen()
    let module = codeGen.generate(optimized)

    // Create silent builtins to suppress output during benchmark runs
    let silentBuiltins = BuiltinRegistry()
    silentBuiltins.register(name: "println") { _ in .unit }
    silentBuiltins.register(name: "print") { _ in .unit }

    // Warmup runs (discard)
    for _ in 0..<warmup {
        let vm = VM(module: module, builtins: silentBuiltins)
        _ = try? vm.run()
    }

    // Measurement runs
    var times: [Double] = []
    for _ in 0..<runs {
        let vm = VM(module: module, builtins: silentBuiltins)
        let start = ProcessInfo.processInfo.systemUptime
        _ = try? vm.run()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        times.append(elapsed * 1000.0)  // convert to ms
    }

    return BenchResult(times: times)
}

func printBenchResult(name: String, result: BenchResult, previous: BenchResult?) {
    let avgStr = String(format: "%.0fms", result.avg)
    let minStr = String(format: "%.0fms", result.min)
    let maxStr = String(format: "%.0fms", result.max)

    var line = "  \(name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(avgStr) avg    min: \(minStr)  max: \(maxStr)"

    if let prev = previous {
        let diff = result.avg - prev.avg
        let pct = prev.avg > 0 ? (diff / prev.avg) * 100.0 : 0
        let sign = diff >= 0 ? "+" : ""
        let diffStr = String(format: "%@%.1fms (%@%.1f%%)", sign, diff, sign, pct)
        line += "    \(diffStr)"
        if pct > 3.0 {
            line += "  \u{26A0} regression"
        } else if pct < -1.0 {
            line += "  \u{2713} faster"
        }
    }

    print(line)
}

func loadBenchHistory(path: String) -> [String: BenchResult]? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
          let last = json.last,
          let results = last["results"] as? [String: [String: Any]] else {
        return nil
    }

    var benchResults: [String: BenchResult] = [:]
    for (name, info) in results {
        if let avg = info["avg"] as? Double {
            benchResults[name] = BenchResult(times: [avg])
        }
    }
    return benchResults
}

func saveBenchHistory(path: String, results: [String: BenchResult]) {
    let fm = FileManager.default
    let dir = (path as NSString).deletingLastPathComponent
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

    // Load existing history
    var history: [[String: Any]] = []
    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
        history = existing
    }

    // Get current git commit hash
    let commitProcess = Process()
    commitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    commitProcess.arguments = ["rev-parse", "--short", "HEAD"]
    let pipe = Pipe()
    commitProcess.standardOutput = pipe
    commitProcess.standardError = FileHandle.nullDevice
    var commit = "unknown"
    if (try? commitProcess.run()) != nil {
        commitProcess.waitUntilExit()
        if let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
            commit = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // Build results dict
    var resultsDict: [String: [String: Any]] = [:]
    for (name, result) in results {
        resultsDict[name] = [
            "min": result.min,
            "avg": result.avg,
            "max": result.max,
            "median": result.median,
            "unit": "ms"
        ]
    }

    let formatter = ISO8601DateFormatter()
    let entry: [String: Any] = [
        "date": formatter.string(from: Date()),
        "commit": commit,
        "results": resultsDict
    ]

    history.append(entry)

    // Write back
    if let data = try? JSONSerialization.data(withJSONObject: history, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Update Command

func updateCommand() {
    let repo = "Dark-Matter/moon"
    let apiURL = "https://api.github.com/repos/\(repo)/releases/latest"

    // Detect platform
    let platform: String
    #if arch(arm64) && os(macOS)
    platform = "macos-arm64"
    #elseif arch(x86_64) && os(macOS)
    platform = "macos-x86_64"
    #elseif arch(x86_64) && os(Linux)
    platform = "linux-x86_64"
    #elseif arch(arm64) && os(Linux)
    platform = "linux-arm64"
    #elseif os(Windows)
    platform = "windows-x86_64"
    #else
    print("error: unsupported platform for self-update")
    exit(1)
    #endif

    print("Checking for updates...")

    // Fetch latest release info
    guard let url = URL(string: apiURL),
          let data = try? Data(contentsOf: url) else {
        print("error: could not reach update server")
        print("  Check your internet connection, or update manually:")
        print("  https://github.com/\(repo)/releases")
        exit(1)
    }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tagName = json["tag_name"] as? String else {
        print("error: could not parse release info")
        exit(1)
    }

    let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

    if latestVersion == version {
        print("rockit \(version) is already up to date.")
        return
    }

    print("New version available: \(version) \u{2192} \(latestVersion)")

    // Determine archive name and download URL
    let ext: String
    #if os(Windows)
    ext = "zip"
    #else
    ext = "tar.gz"
    #endif
    let archiveName = "rockit-\(latestVersion)-\(platform).\(ext)"
    let downloadURL = "https://github.com/\(repo)/releases/download/\(tagName)/\(archiveName)"

    print("Downloading \(archiveName)...")

    guard let archiveURL = URL(string: downloadURL),
          let archiveData = try? Data(contentsOf: archiveURL) else {
        print("error: could not download \(archiveName)")
        print("  No prebuilt binary for \(platform). Download manually:")
        print("  https://github.com/\(repo)/releases/tag/\(tagName)")
        exit(1)
    }

    // Write to temp file
    let tmpDir = Platform.tempDirectory
    let tmpArchive = Platform.pathJoin(tmpDir, "rockit-update-\(ProcessInfo.processInfo.processIdentifier).\(ext)")
    let tmpExtract = Platform.pathJoin(tmpDir, "rockit-update-extract-\(ProcessInfo.processInfo.processIdentifier)")

    do {
        try archiveData.write(to: URL(fileURLWithPath: tmpArchive))
    } catch {
        print("error: could not save download: \(error)")
        exit(1)
    }

    // Extract
    let fm = FileManager.default
    try? fm.createDirectory(atPath: tmpExtract, withIntermediateDirectories: true)

    let extractProcess = Process()
    #if os(Windows)
    // Use PowerShell to extract zip on Windows
    extractProcess.executableURL = URL(fileURLWithPath: "powershell.exe")
    extractProcess.arguments = ["-Command", "Expand-Archive -Path '\(tmpArchive)' -DestinationPath '\(tmpExtract)' -Force"]
    #else
    extractProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    extractProcess.arguments = ["-xzf", tmpArchive, "-C", tmpExtract]
    #endif

    do {
        try extractProcess.run()
        extractProcess.waitUntilExit()
        guard extractProcess.terminationStatus == 0 else {
            print("error: failed to extract update archive")
            exit(1)
        }
    } catch {
        print("error: could not extract archive: \(error)")
        exit(1)
    }

    // Find the current binary location and replace it
    let currentBinary = CommandLine.arguments[0]
    let resolvedBinary: String
    if currentBinary.hasPrefix("/") {
        resolvedBinary = currentBinary
    } else {
        resolvedBinary = Platform.pathJoin(fm.currentDirectoryPath, currentBinary)
    }

    let newBinary: String
    #if os(Windows)
    newBinary = Platform.pathJoin(tmpExtract, "rockit", "rockit.exe")
    #else
    newBinary = Platform.pathJoin(tmpExtract, "rockit", "rockit")
    #endif

    guard fm.fileExists(atPath: newBinary) else {
        print("error: extracted archive does not contain rockit binary")
        exit(1)
    }

    // Replace binary
    let backupPath = resolvedBinary + ".bak"
    do {
        // Backup current binary
        try? fm.removeItem(atPath: backupPath)
        try fm.moveItem(atPath: resolvedBinary, toPath: backupPath)

        // Install new binary
        try fm.moveItem(atPath: newBinary, toPath: resolvedBinary)

        // Make executable
        #if !os(Windows)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resolvedBinary)
        #endif

        // Update runtime files if they exist in the archive
        let newRuntime = Platform.pathJoin(tmpExtract, "rockit", "runtime")
        if fm.fileExists(atPath: newRuntime) {
            // Find installed runtime dir
            let binaryDir = (resolvedBinary as NSString).deletingLastPathComponent
            let libRuntime = Platform.pathJoin(binaryDir, "..", "lib", "rockit", "runtime")
            if fm.fileExists(atPath: libRuntime) {
                if let files = try? fm.contentsOfDirectory(atPath: newRuntime) {
                    for file in files {
                        let src = Platform.pathJoin(newRuntime, file)
                        let dst = Platform.pathJoin(libRuntime, file)
                        try? fm.removeItem(atPath: dst)
                        try fm.copyItem(atPath: src, toPath: dst)
                    }
                }
            }
        }

        // Remove backup
        try? fm.removeItem(atPath: backupPath)

        print("Updated to rockit \(latestVersion)")
    } catch {
        // Restore backup on failure
        if fm.fileExists(atPath: backupPath) {
            try? fm.removeItem(atPath: resolvedBinary)
            try? fm.moveItem(atPath: backupPath, toPath: resolvedBinary)
        }
        print("error: could not replace binary: \(error)")
        print("  You may need to run with sudo (Unix) or as Administrator (Windows)")
        exit(1)
    }

    // Cleanup
    try? fm.removeItem(atPath: tmpArchive)
    try? fm.removeItem(atPath: tmpExtract)
}

/// Test scheme configuration from fuel.toml [test.scheme.*] sections.
struct TestSchemeConfig {
    let include: [String]
    let exclude: [String]
}

/// Parsed fuel.toml configuration with section awareness.
struct FuelConfig {
    var topLevel: [String: String] = [:]
    var testDirectory: String? = nil
    var testRecursive: Bool = true
    var testTimeout: Int = 30
    var testSchemes: [String: TestSchemeConfig] = [:]

    subscript(key: String) -> String? { topLevel[key] }
}

/// Parse a fuel.toml file into a section-aware configuration.
func parseFuelToml(_ path: String) -> FuelConfig {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
        return FuelConfig()
    }
    var config = FuelConfig()
    var currentSection = ""
    var sectionValues: [String: [String: String]] = [:]

    for line in contents.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

        // Section header
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            currentSection = String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
            continue
        }

        let parts = trimmed.components(separatedBy: "=")
        if parts.count >= 2 {
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            var value = parts.dropFirst().joined(separator: "=")
                .trimmingCharacters(in: .whitespaces)
            // Strip quotes
            if value.hasPrefix("\"") && value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }

            if currentSection.isEmpty {
                config.topLevel[key] = value
            } else {
                if sectionValues[currentSection] == nil {
                    sectionValues[currentSection] = [:]
                }
                sectionValues[currentSection]?[key] = value
            }
        }
    }

    // Process [test] section
    if let testSection = sectionValues["test"] {
        if let dir = testSection["directory"] { config.testDirectory = dir }
        if let rec = testSection["recursive"] { config.testRecursive = rec == "true" }
        if let timeout = testSection["timeout"], let t = Int(timeout) { config.testTimeout = t }
    }

    // Process [test.scheme.*] sections
    for (section, values) in sectionValues {
        if section.hasPrefix("test.scheme.") {
            let schemeName = String(section.dropFirst("test.scheme.".count))
            let include = parseTomlArray(values["include"] ?? "")
            let exclude = parseTomlArray(values["exclude"] ?? "")
            config.testSchemes[schemeName] = TestSchemeConfig(include: include, exclude: exclude)
        }
    }

    return config
}

/// Parse a TOML-style array like `["core", "types"]` into a Swift array.
func parseTomlArray(_ value: String) -> [String] {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else { return [] }
    let inner = String(trimmed.dropFirst().dropLast())
    return inner.components(separatedBy: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .map { item in
            var s = item
            if s.hasPrefix("\"") && s.hasSuffix("\"") { s = String(s.dropFirst().dropLast()) }
            return s
        }
        .filter { !$0.isEmpty }
}

/// Strip the main() function from source code (for test wrapper injection).
func stripMainFunction(_ source: String) -> String {
    // Find "fun main(" and remove the entire function body
    guard let range = source.range(of: "fun main(") else { return source }
    let before = source[source.startIndex..<range.lowerBound]

    // Find the matching closing brace
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

/// A discovered test: either a top-level @Test function or a @Test method inside a class.
struct DiscoveredTest {
    let functionName: String
    let className: String?       // nil for top-level
    let hasSetUp: Bool           // class has setUp() method
    let hasTearDown: Bool        // class has tearDown() method

    var qualifiedName: String {
        if let cls = className {
            return "\(cls)::\(functionName)"
        }
        return functionName
    }
}

/// Discover functions with @Test annotation in the AST, including class members.
func discoverTests(ast: SourceFile) -> [DiscoveredTest] {
    var tests: [DiscoveredTest] = []

    for decl in ast.declarations {
        switch decl {
        case .function(let fn):
            if fn.annotations.contains(where: { $0.name == "Test" }) {
                tests.append(DiscoveredTest(
                    functionName: fn.name, className: nil,
                    hasSetUp: false, hasTearDown: false
                ))
            }

        case .classDecl(let cls):
            // Check if this class contains any @Test methods
            var classTests: [String] = []
            var hasSetUp = false
            var hasTearDown = false

            for member in cls.members {
                if case .function(let fn) = member {
                    if fn.annotations.contains(where: { $0.name == "Test" }) {
                        classTests.append(fn.name)
                    }
                    if fn.name == "setUp" { hasSetUp = true }
                    if fn.name == "tearDown" { hasTearDown = true }
                }
            }

            for testFn in classTests {
                tests.append(DiscoveredTest(
                    functionName: testFn, className: cls.name,
                    hasSetUp: hasSetUp, hasTearDown: hasTearDown
                ))
            }

        default:
            break
        }
    }
    return tests
}

/// Backward-compatible wrapper: returns just function names (for CodeLensProvider etc.)
func discoverTestFunctions(ast: SourceFile) -> [String] {
    return discoverTests(ast: ast).filter { $0.className == nil }.map { $0.functionName }
}

// MARK: - Build Native

func buildNativeCommand(file: String, dumpLLVM: Bool) {
    guard FileManager.default.fileExists(atPath: file) else {
        print("error: file not found: \(file)")
        exit(1)
    }

    guard let source = try? String(contentsOfFile: file, encoding: .utf8) else {
        print("error: could not read file: \(file)")
        exit(1)
    }

    let basePath: String
    if file.hasSuffix(".rok") {
        basePath = String(file.dropLast(4))
    } else {
        basePath = file + ".native"
    }
    let outputPath = Platform.withExeExtension(basePath)

    // Find Runtime/ directory relative to the executable or working directory
    let runtimeDir = findRuntimeDir()
    let stdlibPaths: [String] = findStdlibDir().map { [$0] } ?? []

    do {
        let result = try LLVMCodeGen.compileToNative(
            source: source,
            fileName: file,
            outputPath: outputPath,
            runtimeDir: runtimeDir,
            libPaths: stdlibPaths,
            emitLLVM: false
        )
        print("\(file) \u{2192} \(result)")
        if dumpLLVM {
            if let llSource = try? String(contentsOfFile: outputPath + ".ll", encoding: .utf8) {
                print("\n--- LLVM IR ---")
                print(llSource)
                print("--- End LLVM IR ---")
            }
        }
        print("OK")
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

func emitLLVMCommand(file: String) {
    guard FileManager.default.fileExists(atPath: file) else {
        print("error: file not found: \(file)")
        exit(1)
    }

    guard let source = try? String(contentsOfFile: file, encoding: .utf8) else {
        print("error: could not read file: \(file)")
        exit(1)
    }

    let diagnostics = DiagnosticEngine()
    let lexer = Lexer(source: source, fileName: file, diagnostics: diagnostics)
    let tokens = lexer.tokenize()
    let parser = Parser(tokens: tokens, diagnostics: diagnostics)
    let parsedAST = parser.parse()

    let sourceDir = (file as NSString).deletingLastPathComponent
    let importResolver = ImportResolver(sourceDir: sourceDir, libPaths: findStdlibDir().map { [$0] } ?? [], diagnostics: diagnostics)
    let ast = importResolver.resolve(parsedAST)

    let checker = TypeChecker(ast: ast, diagnostics: diagnostics)
    let typeResult = checker.check()

    if diagnostics.hasErrors {
        diagnostics.dump()
        print("\n\(diagnostics.errorCount) error(s)")
        exit(1)
    }

    let lowering = MIRLowering(typeCheckResult: typeResult)
    let unoptimized = lowering.lower()
    let optimizer = MIROptimizer()
    let optimized = optimizer.optimize(unoptimized)

    let codeGen = LLVMCodeGen()
    let llvmIR = codeGen.emit(module: optimized)
    print(llvmIR)
}

func runNativeCommand(file: String) {
    guard FileManager.default.fileExists(atPath: file) else {
        print("error: file not found: \(file)")
        exit(1)
    }

    guard let source = try? String(contentsOfFile: file, encoding: .utf8) else {
        print("error: could not read file: \(file)")
        exit(1)
    }

    let outputPath = Platform.tempFilePath("rockit_native_\(ProcessInfo.processInfo.processIdentifier)")
    let runtimeDir = findRuntimeDir()
    let runNativeStdlibPaths: [String] = findStdlibDir().map { [$0] } ?? []

    do {
        let binary = try LLVMCodeGen.compileToNative(
            source: source,
            fileName: file,
            outputPath: outputPath,
            runtimeDir: runtimeDir,
            libPaths: runNativeStdlibPaths,
            emitLLVM: false
        )

        // Execute the native binary
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = Array(CommandLine.arguments.dropFirst(3))  // Forward remaining args
        try process.run()
        process.waitUntilExit()

        // Clean up
        try? FileManager.default.removeItem(atPath: binary)
        try? FileManager.default.removeItem(atPath: binary + ".ll")

        exit(process.terminationStatus)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

/// Find the Runtime/ directory containing the runtime file (.o preferred, .c fallback).
func findRuntimeDir() -> String {
    let fm = FileManager.default
    let runtimeFiles = ["rockit_runtime.o", "rockit_runtime.c"]

    func searchDir(_ dir: String) -> Bool {
        for f in runtimeFiles {
            if fm.fileExists(atPath: Platform.pathJoin(dir, f)) { return true }
        }
        return false
    }

    // Check ROCKIT_RUNTIME_DIR environment variable first
    if let envDir = ProcessInfo.processInfo.environment["ROCKIT_RUNTIME_DIR"],
       searchDir(envDir) {
        return envDir
    }

    // Try relative to current working directory
    let cwd = fm.currentDirectoryPath
    let cwdRuntime = Platform.pathJoin(cwd, "runtime")
    if searchDir(cwdRuntime) { return cwdRuntime }

    // Try relative to the executable
    let execPath = CommandLine.arguments[0]
    let execDir = (execPath as NSString).deletingLastPathComponent
    let execRuntime = Platform.pathJoin(execDir, "..", "runtime")
    if searchDir(execRuntime) { return execRuntime }

    // Try the project source tree (common during development)
    let devRuntime = Platform.pathJoin(execDir, "..", "..", "runtime")
    if searchDir(devRuntime) { return devRuntime }

    // Try installed location
    let installedRuntime = Platform.pathJoin(execDir, "..", "lib", "rockit", "runtime")
    if searchDir(installedRuntime) { return installedRuntime }

    // Fallback: assume cwd
    return cwdRuntime
}

func findStdlibDir() -> String? {
    let fm = FileManager.default

    // Check ROCKIT_STDLIB_DIR environment variable first
    if let envDir = ProcessInfo.processInfo.environment["ROCKIT_STDLIB_DIR"],
       fm.fileExists(atPath: envDir) {
        return envDir
    }

    // Try self-hosted-rockit/stdlib relative to CWD (development)
    let cwd = fm.currentDirectoryPath
    let cwdStdlib = Platform.pathJoin(cwd, "self-hosted-rockit", "stdlib")
    if fm.fileExists(atPath: Platform.pathJoin(cwdStdlib, "rockit")) { return cwdStdlib }

    // Try relative to the executable (installed: share/rockit/stdlib)
    var execPath = CommandLine.arguments[0]
    if !execPath.contains("/"),
       let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
        for dir in pathEnv.split(separator: ":") {
            let candidate = "\(dir)/\(execPath)"
            if fm.isExecutableFile(atPath: candidate) {
                execPath = candidate
                break
            }
        }
    }
    let execDir = (execPath as NSString).deletingLastPathComponent
    let installedStdlib = Platform.pathJoin(execDir, "..", "share", "rockit", "stdlib")
    if fm.fileExists(atPath: Platform.pathJoin(installedStdlib, "rockit")) { return installedStdlib }

    return nil
}

// MARK: - Main

let args = CommandLine.arguments

guard args.count >= 2 else {
    printUsage()
    exit(0)
}

switch args[1] {
case "lex":
    guard args.count >= 3 else {
        print("error: lex requires a file argument")
        exit(1)
    }
    let dumpTokens = args.contains("--dump-tokens")
    lex(file: args[2], dumpTokens: dumpTokens)

case "parse":
    guard args.count >= 3 else {
        print("error: parse requires a file argument")
        exit(1)
    }
    let dumpAST = args.contains("--dump-ast")
    parseCommand(file: args[2], dumpAST: dumpAST)

case "check":
    guard args.count >= 3 else {
        print("error: check requires a file argument")
        exit(1)
    }
    let dumpTypes = args.contains("--dump-types")
    checkCommand(file: args[2], dumpTypes: dumpTypes)

case "lower":
    guard args.count >= 3 else {
        print("error: lower requires a file argument")
        exit(1)
    }
    let dumpMIR = args.contains("--dump-mir")
    let dumpUnopt = args.contains("--dump-mir-unoptimized")
    lowerCommand(file: args[2], dumpMIR: dumpMIR, dumpUnoptimized: dumpUnopt)

case "build":
    let buildFile: String
    if args.count >= 3 && !args[2].hasPrefix("--") {
        buildFile = args[2]
    } else if FileManager.default.fileExists(atPath: "fuel.toml") {
        buildFile = "src/main.rok"
        let manifest = parseFuelToml("fuel.toml")
        if let name = manifest["name"] {
            print("Building \(name)...")
        }
    } else {
        print("error: build requires a file argument (or run from a Fuel project)")
        exit(1)
    }
    let dumpBytecode = args.contains("--dump-bytecode")
    buildCommand(file: buildFile, dumpBytecode: dumpBytecode)

case "build-native":
    guard args.count >= 3 else {
        print("error: build-native requires a file argument")
        exit(1)
    }
    let dumpLLVM = args.contains("--dump-llvm")
    buildNativeCommand(file: args[2], dumpLLVM: dumpLLVM)

case "emit-llvm":
    guard args.count >= 3 else {
        print("error: emit-llvm requires a file argument")
        exit(1)
    }
    emitLLVMCommand(file: args[2])

case "run-native":
    guard args.count >= 3 else {
        print("error: run-native requires a file argument")
        exit(1)
    }
    runNativeCommand(file: args[2])

case "run":
    guard args.count >= 3 else {
        print("error: run requires a file argument")
        exit(1)
    }
    let trace = args.contains("--trace")
    let gcStats = args.contains("--gc-stats")
    runCommand(file: args[2], trace: trace, gcStats: gcStats)

case "launch", "repl":
    replCommand()

case "init":
    let name = args.count >= 3 ? args[2] : "myproject"
    initCommand(name: name)

case "test":
    let file = args.count >= 3 && !args[2].hasPrefix("--") ? args[2] : nil
    var testFilter: String? = nil
    if let filterIdx = args.firstIndex(of: "--filter"), filterIdx + 1 < args.count {
        testFilter = args[filterIdx + 1]
    }
    let detailed = args.contains("--detailed")
    var testScheme: String? = nil
    if let schemeIdx = args.firstIndex(of: "--scheme"), schemeIdx + 1 < args.count {
        testScheme = args[schemeIdx + 1]
    }
    if args.contains("--watch") {
        watchTestCommand(file: file, filter: testFilter, detailed: detailed, scheme: testScheme)
    } else {
        testCommand(file: file, filter: testFilter, detailed: detailed, scheme: testScheme)
    }

case "bench":
    let benchTarget = args.count >= 3 && !args[2].hasPrefix("--") ? args[2] : nil
    var benchRuns = 5
    if let runsIdx = args.firstIndex(of: "--runs"), runsIdx + 1 < args.count,
       let n = Int(args[runsIdx + 1]) { benchRuns = n }
    var benchWarmup = 2
    if let warmIdx = args.firstIndex(of: "--warmup"), warmIdx + 1 < args.count,
       let n = Int(args[warmIdx + 1]) { benchWarmup = n }
    let benchSave = args.contains("--save")
    benchCommand(target: benchTarget, runs: benchRuns, warmup: benchWarmup, save: benchSave)

case "update":
    updateCommand()

case "lsp":
    let server = LSPServer()
    server.run()

case "setup-editors":
    setupEditorsCommand()

case "version":
    print("rockit \(version)")

case "--help", "-h":
    printUsage()

default:
    // Assume it's a file path
    if args[1].hasSuffix(".rok") {
        lex(file: args[1], dumpTokens: true)
    } else {
        print("error: unknown command '\(args[1])'")
        printUsage()
        exit(1)
    }
}

exit(0)
