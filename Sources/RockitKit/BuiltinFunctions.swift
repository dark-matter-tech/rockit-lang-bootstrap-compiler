// BuiltinRegistry.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Security)
import Security
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(COpenSSL)
import COpenSSL
#endif

// MARK: - Builtin Function Type

/// Signature for built-in functions: takes arguments, returns a value.
public typealias BuiltinFunction = ([Value]) throws -> Value

// MARK: - Builtin Registry

/// Extensible registry of built-in functions available to Rockit programs.
/// Built-ins are resolved by name during function dispatch.
public final class BuiltinRegistry {
    private var functions: [String: BuiltinFunction] = [:]

    public init() {
        registerDefaults()
    }

    /// Register a built-in function by name.
    public func register(name: String, function: @escaping BuiltinFunction) {
        functions[name] = function
    }

    /// Look up a built-in function. Returns nil if not registered.
    public func lookup(_ name: String) -> BuiltinFunction? {
        return functions[name]
    }

    /// Check if a function name is a built-in.
    public func isBuiltin(_ name: String) -> Bool {
        return functions[name] != nil
    }

    /// All registered built-in names.
    public var registeredNames: [String] {
        Array(functions.keys).sorted()
    }

    // MARK: - Default Built-ins

    private func registerDefaults() {
        // Output
        register(name: "println") { args in
            let text = args.map { $0.description }.joined(separator: " ")
            print(text)
            return .unit
        }

        register(name: "print") { args in
            let text = args.map { $0.description }.joined(separator: " ")
            Swift.print(text, terminator: "")
            return .unit
        }

        // String conversion
        register(name: "toString") { args in
            guard let first = args.first else { return .string("") }
            return .string(first.description)
        }

        register(name: "toInt") { args in
            guard let first = args.first else {
                throw VMError.typeMismatch(expected: "Int", actual: "nothing", operation: "toInt")
            }
            switch first {
            case .int(let v):
                return .int(v)
            case .float(let v):
                return .int(Int64(v))
            case .string(let s):
                if let v = Int64(s) {
                    return .int(v)
                }
                throw VMError.typeMismatch(expected: "parseable Int", actual: "String(\(s))", operation: "toInt")
            case .bool(let b):
                return .int(b ? 1 : 0)
            default:
                throw VMError.typeMismatch(expected: "Int", actual: first.typeName, operation: "toInt")
            }
        }

        register(name: "intToString") { args in
            guard case .int(let v) = args.first else {
                throw VMError.typeMismatch(expected: "Int", actual: args.first?.typeName ?? "nothing", operation: "intToString")
            }
            return .string("\(v)")
        }

        register(name: "floatToString") { args in
            guard case .float(let v) = args.first else {
                throw VMError.typeMismatch(expected: "Float64", actual: args.first?.typeName ?? "nothing", operation: "floatToString")
            }
            return .string("\(v)")
        }

        register(name: "formatFloat") { args in
            guard args.count >= 2,
                  case .float(let v) = args[0],
                  case .int(let decimals) = args[1] else {
                throw VMError.typeMismatch(expected: "Float64, Int", actual: "\(args)", operation: "formatFloat")
            }
            return .string(String(format: "%.\(decimals)f", v))
        }

        register(name: "toFloat") { args in
            guard case .int(let v) = args.first else {
                throw VMError.typeMismatch(expected: "Int", actual: args.first?.typeName ?? "nothing", operation: "toFloat")
            }
            return .float(Double(v))
        }

        // String operations
        register(name: "stringLength") { args in
            guard case .string(let s) = args.first else {
                throw VMError.typeMismatch(expected: "String", actual: args.first?.typeName ?? "nothing", operation: "stringLength")
            }
            return .int(Int64(s.count))
        }

        register(name: "stringSubstring") { args in
            guard args.count >= 3,
                  case .string(let s) = args[0],
                  case .int(let start) = args[1],
                  case .int(let end) = args[2] else {
                throw VMError.typeMismatch(expected: "String, Int, Int", actual: "invalid args", operation: "stringSubstring")
            }
            let startIdx = s.index(s.startIndex, offsetBy: Int(start))
            let endIdx = s.index(s.startIndex, offsetBy: min(Int(end), s.count))
            return .string(String(s[startIdx..<endIdx]))
        }

        register(name: "charAt") { args in
            guard args.count >= 2,
                  case .string(let s) = args[0],
                  case .int(let index) = args[1] else {
                throw VMError.typeMismatch(expected: "String, Int", actual: "invalid args", operation: "charAt")
            }
            guard index >= 0, Int(index) < s.count else {
                throw VMError.indexOutOfBounds(index: Int(index), count: s.count)
            }
            let charIdx = s.index(s.startIndex, offsetBy: Int(index))
            return .string(String(s[charIdx]))
        }

        register(name: "charCodeAt") { args in
            guard args.count >= 2,
                  case .string(let s) = args[0],
                  case .int(let index) = args[1] else {
                throw VMError.typeMismatch(expected: "String, Int", actual: "invalid args", operation: "charCodeAt")
            }
            guard index >= 0, Int(index) < s.count else {
                throw VMError.indexOutOfBounds(index: Int(index), count: s.count)
            }
            let charIdx = s.index(s.startIndex, offsetBy: Int(index))
            return .int(Int64(s[charIdx].unicodeScalars.first!.value))
        }

        register(name: "substring") { args in
            guard args.count >= 3,
                  case .string(let s) = args[0],
                  case .int(let start) = args[1],
                  case .int(let end) = args[2] else {
                throw VMError.typeMismatch(expected: "String, Int, Int", actual: "invalid args", operation: "substring")
            }
            let startIdx = s.index(s.startIndex, offsetBy: max(0, min(Int(start), s.count)))
            let endIdx = s.index(s.startIndex, offsetBy: max(0, min(Int(end), s.count)))
            return .string(String(s[startIdx..<endIdx]))
        }

        register(name: "stringIndexOf") { args in
            guard args.count >= 2,
                  case .string(let s) = args[0],
                  case .string(let search) = args[1] else {
                throw VMError.typeMismatch(expected: "String, String", actual: "invalid args", operation: "stringIndexOf")
            }
            if let range = s.range(of: search) {
                return .int(Int64(s.distance(from: s.startIndex, to: range.lowerBound)))
            }
            return .int(-1)
        }

        register(name: "startsWith") { args in
            guard args.count >= 2,
                  case .string(let s) = args[0],
                  case .string(let prefix) = args[1] else {
                throw VMError.typeMismatch(expected: "String, String", actual: "invalid args", operation: "startsWith")
            }
            return .bool(s.hasPrefix(prefix))
        }

        register(name: "endsWith") { args in
            guard args.count >= 2,
                  case .string(let s) = args[0],
                  case .string(let suffix) = args[1] else {
                throw VMError.typeMismatch(expected: "String, String", actual: "invalid args", operation: "endsWith")
            }
            return .bool(s.hasSuffix(suffix))
        }

        register(name: "stringContains") { args in
            guard args.count >= 2,
                  case .string(let s) = args[0],
                  case .string(let search) = args[1] else {
                throw VMError.typeMismatch(expected: "String, String", actual: "invalid args", operation: "stringContains")
            }
            return .bool(s.contains(search))
        }

        register(name: "stringTrim") { args in
            guard case .string(let s) = args.first else {
                throw VMError.typeMismatch(expected: "String", actual: args.first?.typeName ?? "nothing", operation: "stringTrim")
            }
            return .string(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        register(name: "stringReplace") { args in
            guard args.count >= 3,
                  case .string(let s) = args[0],
                  case .string(let target) = args[1],
                  case .string(let replacement) = args[2] else {
                throw VMError.typeMismatch(expected: "String, String, String", actual: "invalid args", operation: "stringReplace")
            }
            return .string(s.replacingOccurrences(of: target, with: replacement))
        }

        register(name: "stringToLower") { args in
            guard case .string(let s) = args.first else {
                throw VMError.typeMismatch(expected: "String", actual: args.first?.typeName ?? "nothing", operation: "stringToLower")
            }
            return .string(s.lowercased())
        }

        register(name: "stringToUpper") { args in
            guard case .string(let s) = args.first else {
                throw VMError.typeMismatch(expected: "String", actual: args.first?.typeName ?? "nothing", operation: "stringToUpper")
            }
            return .string(s.uppercased())
        }

        // Character classification
        register(name: "isDigit") { args in
            guard case .string(let s) = args.first, let ch = s.first else {
                throw VMError.typeMismatch(expected: "String (single char)", actual: args.first?.typeName ?? "nothing", operation: "isDigit")
            }
            return .bool(ch.isNumber)
        }

        register(name: "isLetter") { args in
            guard case .string(let s) = args.first, let ch = s.first else {
                throw VMError.typeMismatch(expected: "String (single char)", actual: args.first?.typeName ?? "nothing", operation: "isLetter")
            }
            return .bool(ch.isLetter)
        }

        register(name: "isWhitespace") { args in
            guard case .string(let s) = args.first, let ch = s.first else {
                throw VMError.typeMismatch(expected: "String (single char)", actual: args.first?.typeName ?? "nothing", operation: "isWhitespace")
            }
            return .bool(ch.isWhitespace)
        }

        register(name: "isLetterOrDigit") { args in
            guard case .string(let s) = args.first, let ch = s.first else {
                throw VMError.typeMismatch(expected: "String (single char)", actual: args.first?.typeName ?? "nothing", operation: "isLetterOrDigit")
            }
            return .bool(ch.isLetter || ch.isNumber)
        }

        register(name: "charToInt") { args in
            guard case .string(let s) = args.first, let ch = s.first else {
                throw VMError.typeMismatch(expected: "String (single char)", actual: args.first?.typeName ?? "nothing", operation: "charToInt")
            }
            return .int(Int64(ch.asciiValue ?? 0))
        }

        register(name: "intToChar") { args in
            guard case .int(let code) = args.first else {
                throw VMError.typeMismatch(expected: "Int", actual: args.first?.typeName ?? "nothing", operation: "intToChar")
            }
            guard code >= 0, code <= 127, let scalar = UnicodeScalar(Int(code)) else {
                return .string("")
            }
            return .string(String(Character(scalar)))
        }

        // Input
        register(name: "readLine") { _ in
            if let line = Swift.readLine() {
                return .string(line)
            }
            return .null
        }

        // File I/O
        register(name: "fileRead") { args in
            guard case .string(let path) = args.first else {
                throw VMError.typeMismatch(expected: "String", actual: args.first?.typeName ?? "nothing", operation: "fileRead")
            }
            do {
                let contents = try String(contentsOfFile: path, encoding: .utf8)
                return .string(contents)
            } catch {
                return .null
            }
        }

        register(name: "fileWrite") { args in
            guard args.count >= 2,
                  case .string(let path) = args[0],
                  case .string(let content) = args[1] else {
                throw VMError.typeMismatch(expected: "String, String", actual: "invalid args", operation: "fileWrite")
            }
            do {
                try content.write(toFile: path, atomically: true, encoding: .utf8)
                return .bool(true)
            } catch {
                return .bool(false)
            }
        }

        register(name: "fileExists") { args in
            guard case .string(let path) = args.first else {
                throw VMError.typeMismatch(expected: "String", actual: args.first?.typeName ?? "nothing", operation: "fileExists")
            }
            return .bool(FileManager.default.fileExists(atPath: path))
        }

        register(name: "fileDelete") { args in
            guard case .string(let path) = args.first else {
                throw VMError.typeMismatch(expected: "String", actual: args.first?.typeName ?? "nothing", operation: "fileDelete")
            }
            do {
                try FileManager.default.removeItem(atPath: path)
                return .bool(true)
            } catch {
                return .bool(false)
            }
        }

        // Process
        register(name: "processArgs") { _ in
            // Returns args as a null-separated string for now.
            // Will return a List once heap-aware version is wired up.
            let args = CommandLine.arguments
            return .string(args.joined(separator: "\0"))
        }

        register(name: "processExit") { args in
            guard case .int(let code) = args.first else {
                throw VMError.typeMismatch(expected: "Int", actual: args.first?.typeName ?? "nothing", operation: "processExit")
            }
            exit(Int32(code))
        }

        register(name: "getEnv") { args in
            guard case .string(let name) = args.first else {
                throw VMError.typeMismatch(expected: "String", actual: args.first?.typeName ?? "nothing", operation: "getEnv")
            }
            if let value = ProcessInfo.processInfo.environment[name] {
                return .string(value)
            }
            return .null
        }

        register(name: "executablePath") { _ in
            return .string(CommandLine.arguments[0])
        }

        register(name: "platformOS") { _ in
            #if os(Windows)
            return .string("windows")
            #elseif os(macOS)
            return .string("macos")
            #else
            return .string("linux")
            #endif
        }

        // Math
        register(name: "abs") { args in
            switch args.first {
            case .int(let v):   return .int(Swift.abs(v))
            case .float(let v): return .float(Swift.abs(v))
            default:
                throw VMError.typeMismatch(expected: "Int or Float64", actual: args.first?.typeName ?? "nothing", operation: "abs")
            }
        }

        register(name: "min") { args in
            guard args.count >= 2 else { return args.first ?? .null }
            switch (args[0], args[1]) {
            case (.int(let a), .int(let b)):     return .int(Swift.min(a, b))
            case (.float(let a), .float(let b)): return .float(Swift.min(a, b))
            default:
                throw VMError.typeMismatch(expected: "matching numeric types", actual: "\(args[0].typeName), \(args[1].typeName)", operation: "min")
            }
        }

        register(name: "max") { args in
            guard args.count >= 2 else { return args.first ?? .null }
            switch (args[0], args[1]) {
            case (.int(let a), .int(let b)):     return .int(Swift.max(a, b))
            case (.float(let a), .float(let b)): return .float(Swift.max(a, b))
            default:
                throw VMError.typeMismatch(expected: "matching numeric types", actual: "\(args[0].typeName), \(args[1].typeName)", operation: "max")
            }
        }

        // Math (floating point)
        register(name: "rockit_math_sqrt") { args in
            guard case .float(let v) = args.first else { return .float(0.0) }
            return .float(Foundation.sqrt(v))
        }
        register(name: "rockit_math_sin") { args in
            guard case .float(let v) = args.first else { return .float(0.0) }
            return .float(Foundation.sin(v))
        }
        register(name: "rockit_math_cos") { args in
            guard case .float(let v) = args.first else { return .float(0.0) }
            return .float(Foundation.cos(v))
        }
        register(name: "rockit_math_tan") { args in
            guard case .float(let v) = args.first else { return .float(0.0) }
            return .float(Foundation.tan(v))
        }
        register(name: "rockit_math_pow") { args in
            guard args.count >= 2, case .float(let base) = args[0], case .float(let exp) = args[1] else { return .float(0.0) }
            return .float(Foundation.pow(base, exp))
        }
        register(name: "rockit_math_floor") { args in
            guard case .float(let v) = args.first else { return .float(0.0) }
            return .float(Foundation.floor(v))
        }
        register(name: "rockit_math_ceil") { args in
            guard case .float(let v) = args.first else { return .float(0.0) }
            return .float(Foundation.ceil(v))
        }
        register(name: "rockit_math_round") { args in
            guard case .float(let v) = args.first else { return .float(0.0) }
            return .float(Foundation.round(v))
        }
        register(name: "rockit_math_log") { args in
            guard case .float(let v) = args.first else { return .float(0.0) }
            return .float(Foundation.log(v))
        }
        register(name: "rockit_math_exp") { args in
            guard case .float(let v) = args.first else { return .float(0.0) }
            return .float(Foundation.exp(v))
        }
        register(name: "rockit_math_abs") { args in
            guard case .float(let v) = args.first else { return .float(0.0) }
            return .float(Foundation.fabs(v))
        }
        register(name: "rockit_math_atan2") { args in
            guard args.count >= 2, case .float(let y) = args[0], case .float(let x) = args[1] else { return .float(0.0) }
            return .float(Foundation.atan2(y, x))
        }

        // Diagnostics
        register(name: "panic") { _ in
            throw VMError.unreachable
        }

        // Type queries
        register(name: "typeOf") { args in
            guard let first = args.first else { return .string("Nothing") }
            return .string(first.typeName)
        }

        // ── Probe Test Framework — Assertions ─────────────────────────────

        register(name: "assert") { args in
            guard let first = args.first else {
                throw VMError.userException(message: "assert: expected boolean argument")
            }
            let condition: Bool
            switch first {
            case .bool(let b): condition = b
            case .int(let i): condition = i != 0
            default: condition = false
            }
            if !condition {
                let message = args.count >= 2 ? args[1].description : "Assertion failed"
                throw VMError.userException(message: "ASSERTION FAILED: \(message)")
            }
            return .unit
        }

        register(name: "assertEquals") { args in
            guard args.count >= 2 else {
                throw VMError.userException(message: "assertEquals: expected 2 arguments")
            }
            if args[0] != args[1] {
                let message = args.count >= 3 ? args[2].description : ""
                let detail = message.isEmpty ? "" : " — \(message)"
                throw VMError.userException(
                    message: "ASSERTION FAILED: expected \(args[0]) to equal \(args[1])\(detail)")
            }
            return .unit
        }

        register(name: "assertNotEquals") { args in
            guard args.count >= 2 else {
                throw VMError.userException(message: "assertNotEquals: expected 2 arguments")
            }
            if args[0] == args[1] {
                let message = args.count >= 3 ? args[2].description : ""
                let detail = message.isEmpty ? "" : " — \(message)"
                throw VMError.userException(
                    message: "ASSERTION FAILED: expected \(args[0]) to not equal \(args[1])\(detail)")
            }
            return .unit
        }

        register(name: "assertTrue") { args in
            guard let first = args.first, case .bool(let b) = first, b else {
                let message = args.count >= 2 ? args[1].description : "Expected true"
                throw VMError.userException(message: "ASSERTION FAILED: \(message)")
            }
            return .unit
        }

        register(name: "assertFalse") { args in
            guard let first = args.first else {
                throw VMError.userException(message: "assertFalse: expected boolean argument")
            }
            if case .bool(let b) = first, b {
                let message = args.count >= 2 ? args[1].description : "Expected false"
                throw VMError.userException(message: "ASSERTION FAILED: \(message)")
            }
            return .unit
        }

        register(name: "assertNull") { args in
            guard let first = args.first else {
                throw VMError.userException(message: "assertNull: expected argument")
            }
            if first != .null {
                throw VMError.userException(message: "ASSERTION FAILED: expected null, got \(first)")
            }
            return .unit
        }

        register(name: "assertNotNull") { args in
            guard let first = args.first else {
                throw VMError.userException(message: "assertNotNull: expected argument")
            }
            if first == .null {
                throw VMError.userException(message: "ASSERTION FAILED: expected non-null value")
            }
            return .unit
        }
    }

    // MARK: - Collection Builtins

    /// Register collection builtins that need heap and ARC access.
    /// Called by VM after heap and ARC are initialized.
    public func registerCollectionBuiltins(heap: Heap, arc: ReferenceCounter) {
        registerListBuiltins(heap: heap, arc: arc)
        registerHashMapBuiltins(heap: heap, arc: arc)
        registerHeapAwareStringBuiltins(heap: heap)
        registerProcessBuiltins(heap: heap)
        registerFileIOBuiltins(heap: heap)
        registerNetworkBuiltins(heap: heap)
        registerTypeCheckBuiltins(heap: heap)
        registerCompilerBuiltins()
        registerSecurityBuiltins()
    }

    // MARK: Type Check Builtins

    private func registerTypeCheckBuiltins(heap: Heap) {
        register(name: "isMap") { args in
            guard let first = args.first else { return .bool(false) }
            guard case .objectRef(let id) = first else { return .bool(false) }
            guard let obj = try? heap.get(id) else { return .bool(false) }
            return .bool(obj.mapStorage != nil)
        }

        register(name: "isList") { args in
            guard let first = args.first else { return .bool(false) }
            guard case .objectRef(let id) = first else { return .bool(false) }
            guard let obj = try? heap.get(id) else { return .bool(false) }
            return .bool(obj.listStorage != nil)
        }

        register(name: "typeOf") { args in
            guard let first = args.first else { return .string("null") }
            switch first {
            case .int: return .string("Int")
            case .float: return .string("Float")
            case .string: return .string("String")
            case .bool: return .string("Bool")
            case .null: return .string("null")
            case .unit: return .string("Unit")
            case .objectRef(let id):
                guard let obj = try? heap.get(id) else { return .string("object") }
                if obj.mapStorage != nil { return .string("Map") }
                if obj.listStorage != nil { return .string("List") }
                return .string("object")
            case .functionRef:
                return .string("Function")
            }
        }
    }

    // MARK: Compiler Builtins

    private func registerCompilerBuiltins() {
        register(name: "evalRockit") { args in
            guard case .string(let source) = args.first else {
                throw VMError.typeMismatch(
                    expected: "String",
                    actual: args.first?.typeName ?? "nothing",
                    operation: "evalRockit"
                )
            }

            var output = ""

            // Full pipeline: Lex → Parse → TypeCheck → MIR → Optimize → CodeGen
            let diagnostics = DiagnosticEngine()
            let lexer = Lexer(source: source, fileName: "<repl>", diagnostics: diagnostics)
            let tokens = lexer.tokenize()
            let parser = Parser(tokens: tokens, diagnostics: diagnostics)
            let ast = parser.parse()

            if diagnostics.hasErrors {
                let msgs = diagnostics.diagnostics
                    .filter { $0.severity == .error }
                    .map { $0.description }
                return .string("ERROR: " + msgs.joined(separator: "\n"))
            }

            let checker = TypeChecker(ast: ast, diagnostics: diagnostics)
            let typeResult = checker.check()

            // Continue even with type errors (warnings)
            let lowering = MIRLowering(typeCheckResult: typeResult)
            let mir = lowering.lower()
            let optimizer = MIROptimizer()
            let optimized = optimizer.optimize(mir)
            let codeGen = CodeGen()
            let module = codeGen.generate(optimized)

            // Create VM with output-capturing println/print
            let captureBuiltins = BuiltinRegistry()
            captureBuiltins.register(name: "println") { innerArgs in
                output += innerArgs.map { $0.description }.joined(separator: " ") + "\n"
                return .unit
            }
            captureBuiltins.register(name: "print") { innerArgs in
                output += innerArgs.map { $0.description }.joined(separator: " ")
                return .unit
            }
            let vm = VM(module: module, builtins: captureBuiltins)

            do {
                try vm.run()
            } catch {
                return .string("RUNTIME ERROR: \(error)")
            }

            return .string(output)
        }

        register(name: "systemExec") { args in
            guard case .string(let cmd) = args.first else {
                throw VMError.typeMismatch(
                    expected: "String",
                    actual: args.first?.typeName ?? "nothing",
                    operation: "systemExec"
                )
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Platform.shellExecutable)
            process.arguments = [Platform.shellFlag, cmd]
            try process.run()
            process.waitUntilExit()
            return .int(Int64(process.terminationStatus))
        }

        register(name: "fileDelete") { args in
            guard case .string(let path) = args.first else {
                throw VMError.typeMismatch(
                    expected: "String",
                    actual: args.first?.typeName ?? "nothing",
                    operation: "fileDelete"
                )
            }
            let success = FileManager.default.isDeletableFile(atPath: path)
            if success {
                try? FileManager.default.removeItem(atPath: path)
                return .int(1)
            }
            return .int(0)
        }
    }

    // MARK: List Builtins

    private func registerListBuiltins(heap: Heap, arc: ReferenceCounter) {
        func extractList(_ args: [Value], operation: String) throws -> RockitObject {
            guard let first = args.first, case .objectRef(let id) = first else {
                throw VMError.typeMismatch(
                    expected: "List",
                    actual: args.first?.typeName ?? "nothing",
                    operation: operation
                )
            }
            let obj = try heap.get(id)
            guard obj.typeName == "List" || obj.typeName == "MutableList" else {
                throw VMError.typeMismatch(
                    expected: "List", actual: obj.typeName, operation: operation
                )
            }
            return obj
        }

        register(name: "listCreate") { _ in
            let id = heap.allocate(typeName: "List")
            let obj = try heap.get(id)
            obj.listStorage = []
            return .objectRef(id)
        }

        register(name: "listCreateFilled") { args in
            guard args.count >= 2 else {
                throw VMError.typeMismatch(expected: "2 arguments", actual: "\(args.count)", operation: "listCreateFilled")
            }
            guard case .int(let size) = args[0] else {
                throw VMError.typeMismatch(expected: "Int", actual: "\(args[0])", operation: "listCreateFilled")
            }
            let id = heap.allocate(typeName: "List")
            let obj = try heap.get(id)
            obj.listStorage = Array(repeating: args[1], count: Int(size))
            return .objectRef(id)
        }

        register(name: "listAppend") { args in
            let obj = try extractList(args, operation: "listAppend")
            guard args.count >= 2 else {
                throw VMError.typeMismatch(expected: "2 arguments", actual: "\(args.count)", operation: "listAppend")
            }
            let element = args[1]
            obj.listStorage?.append(element)
            arc.retain(element)
            return .unit
        }

        register(name: "listGet") { args in
            let obj = try extractList(args, operation: "listGet")
            guard args.count >= 2, case .int(let index) = args[1] else {
                throw VMError.typeMismatch(expected: "Int", actual: args.count >= 2 ? args[1].typeName : "nothing", operation: "listGet")
            }
            guard let storage = obj.listStorage, index >= 0, Int(index) < storage.count else {
                throw VMError.indexOutOfBounds(index: Int(index), count: obj.listStorage?.count ?? 0)
            }
            return storage[Int(index)]
        }

        register(name: "listSet") { args in
            let obj = try extractList(args, operation: "listSet")
            guard args.count >= 3, case .int(let index) = args[1] else {
                throw VMError.typeMismatch(expected: "Int", actual: args.count >= 2 ? args[1].typeName : "nothing", operation: "listSet")
            }
            let newValue = args[2]
            guard obj.listStorage != nil, index >= 0, Int(index) < obj.listStorage!.count else {
                throw VMError.indexOutOfBounds(index: Int(index), count: obj.listStorage?.count ?? 0)
            }
            let oldValue = obj.listStorage![Int(index)]
            obj.listStorage![Int(index)] = newValue
            arc.retain(newValue)
            arc.release(oldValue)
            return .unit
        }

        register(name: "listSetFloat") { args in
            let obj = try extractList(args, operation: "listSetFloat")
            guard args.count >= 3, case .int(let index) = args[1], case .float(let value) = args[2] else {
                throw VMError.typeMismatch(expected: "List, Int, Float", actual: "\(args)", operation: "listSetFloat")
            }
            guard obj.listStorage != nil, index >= 0, Int(index) < obj.listStorage!.count else {
                throw VMError.indexOutOfBounds(index: Int(index), count: obj.listStorage?.count ?? 0)
            }
            obj.listStorage![Int(index)] = .float(value)
            return .unit
        }

        register(name: "listGetFloat") { args in
            let obj = try extractList(args, operation: "listGetFloat")
            guard args.count >= 2, case .int(let index) = args[1] else {
                throw VMError.typeMismatch(expected: "List, Int", actual: "\(args)", operation: "listGetFloat")
            }
            guard let storage = obj.listStorage, index >= 0, Int(index) < storage.count else {
                throw VMError.indexOutOfBounds(index: Int(index), count: obj.listStorage?.count ?? 0)
            }
            if case .float(let value) = storage[Int(index)] { return .float(value) }
            return .float(0.0)
        }

        register(name: "listSize") { args in
            let obj = try extractList(args, operation: "listSize")
            return .int(Int64(obj.listStorage?.count ?? 0))
        }

        register(name: "listRemoveAt") { args in
            let obj = try extractList(args, operation: "listRemoveAt")
            guard args.count >= 2, case .int(let index) = args[1] else {
                throw VMError.typeMismatch(expected: "Int", actual: args.count >= 2 ? args[1].typeName : "nothing", operation: "listRemoveAt")
            }
            guard obj.listStorage != nil, index >= 0, Int(index) < obj.listStorage!.count else {
                throw VMError.indexOutOfBounds(index: Int(index), count: obj.listStorage?.count ?? 0)
            }
            let removed = obj.listStorage!.remove(at: Int(index))
            // Ownership transfer: list's retain becomes caller's retain
            return removed
        }

        register(name: "listContains") { args in
            let obj = try extractList(args, operation: "listContains")
            guard args.count >= 2 else {
                throw VMError.typeMismatch(expected: "2 arguments", actual: "\(args.count)", operation: "listContains")
            }
            return .bool(obj.listStorage?.contains(args[1]) ?? false)
        }

        register(name: "listIndexOf") { args in
            let obj = try extractList(args, operation: "listIndexOf")
            guard args.count >= 2 else {
                throw VMError.typeMismatch(expected: "2 arguments", actual: "\(args.count)", operation: "listIndexOf")
            }
            if let index = obj.listStorage?.firstIndex(of: args[1]) {
                return .int(Int64(index))
            }
            return .int(-1)
        }

        register(name: "listIsEmpty") { args in
            let obj = try extractList(args, operation: "listIsEmpty")
            return .bool(obj.listStorage?.isEmpty ?? true)
        }

        register(name: "listClear") { args in
            let obj = try extractList(args, operation: "listClear")
            if let elements = obj.listStorage {
                for element in elements {
                    arc.release(element)
                }
            }
            obj.listStorage = []
            return .unit
        }
    }

    // MARK: HashMap Builtins

    private func registerHashMapBuiltins(heap: Heap, arc: ReferenceCounter) {
        func extractMap(_ args: [Value], operation: String) throws -> RockitObject {
            guard let first = args.first, case .objectRef(let id) = first else {
                throw VMError.typeMismatch(
                    expected: "HashMap",
                    actual: args.first?.typeName ?? "nothing",
                    operation: operation
                )
            }
            let obj = try heap.get(id)
            guard obj.typeName == "HashMap" || obj.typeName == "Map" || obj.typeName == "MutableMap" else {
                throw VMError.typeMismatch(
                    expected: "HashMap", actual: obj.typeName, operation: operation
                )
            }
            return obj
        }

        register(name: "mapCreate") { _ in
            let id = heap.allocate(typeName: "HashMap")
            let obj = try heap.get(id)
            obj.mapStorage = [:]
            return .objectRef(id)
        }

        register(name: "mapPut") { args in
            let obj = try extractMap(args, operation: "mapPut")
            guard args.count >= 3 else {
                throw VMError.typeMismatch(expected: "3 arguments", actual: "\(args.count)", operation: "mapPut")
            }
            let key = args[1]
            let newValue = args[2]
            if let oldValue = obj.mapStorage?[key] {
                // Key exists: release old value, retain new value
                arc.release(oldValue)
            } else {
                // New key: retain the key
                arc.retain(key)
            }
            obj.mapStorage?[key] = newValue
            arc.retain(newValue)
            return .unit
        }

        register(name: "mapGet") { args in
            let obj = try extractMap(args, operation: "mapGet")
            guard args.count >= 2 else {
                throw VMError.typeMismatch(expected: "2 arguments", actual: "\(args.count)", operation: "mapGet")
            }
            return obj.mapStorage?[args[1]] ?? .null
        }

        register(name: "mapRemove") { args in
            let obj = try extractMap(args, operation: "mapRemove")
            guard args.count >= 2 else {
                throw VMError.typeMismatch(expected: "2 arguments", actual: "\(args.count)", operation: "mapRemove")
            }
            let key = args[1]
            guard let removedValue = obj.mapStorage?.removeValue(forKey: key) else {
                return .null
            }
            arc.release(key)
            // Ownership transfer for value: map's retain becomes caller's retain
            return removedValue
        }

        register(name: "mapContainsKey") { args in
            let obj = try extractMap(args, operation: "mapContainsKey")
            guard args.count >= 2 else {
                throw VMError.typeMismatch(expected: "2 arguments", actual: "\(args.count)", operation: "mapContainsKey")
            }
            return .bool(obj.mapStorage?[args[1]] != nil)
        }

        register(name: "mapKeys") { args in
            let obj = try extractMap(args, operation: "mapKeys")
            let keys = obj.mapStorage.map { Array($0.keys) } ?? []
            let listId = heap.allocate(typeName: "List")
            let listObj = try heap.get(listId)
            listObj.listStorage = keys
            for key in keys {
                arc.retain(key)
            }
            return .objectRef(listId)
        }

        register(name: "mapValues") { args in
            let obj = try extractMap(args, operation: "mapValues")
            let values = obj.mapStorage.map { Array($0.values) } ?? []
            let listId = heap.allocate(typeName: "List")
            let listObj = try heap.get(listId)
            listObj.listStorage = values
            for value in values {
                arc.retain(value)
            }
            return .objectRef(listId)
        }

        register(name: "mapSize") { args in
            let obj = try extractMap(args, operation: "mapSize")
            return .int(Int64(obj.mapStorage?.count ?? 0))
        }

        register(name: "mapIsEmpty") { args in
            let obj = try extractMap(args, operation: "mapIsEmpty")
            return .bool(obj.mapStorage?.isEmpty ?? true)
        }

        register(name: "mapClear") { args in
            let obj = try extractMap(args, operation: "mapClear")
            if let entries = obj.mapStorage {
                for (key, value) in entries {
                    arc.release(key)
                    arc.release(value)
                }
            }
            obj.mapStorage = [:]
            return .unit
        }
    }

    // MARK: Heap-Aware String Builtins

    private func registerProcessBuiltins(heap: Heap) {
        // Override the simple processArgs with a heap-aware version that returns a List.
        // Returns args after "--" when present, otherwise args starting from source file.
        register(name: "processArgs") { _ in
            let allArgs = CommandLine.arguments
            var userArgs: [String] = []

            // If there's a "--" separator, return everything after it
            if let dashIdx = allArgs.firstIndex(of: "--") {
                userArgs = Array(allArgs[(dashIdx + 1)...])
            } else {
                // Find the source file (.rok or .rokb) and return it + everything after
                var foundSource = false
                for arg in allArgs {
                    if foundSource {
                        userArgs.append(arg)
                    } else if arg.hasSuffix(".rok") || arg.hasSuffix(".rokb") {
                        userArgs.append(arg)
                        foundSource = true
                    }
                }
            }
            if userArgs.isEmpty {
                userArgs = allArgs  // fallback: return all args
            }
            let listId = heap.allocate(typeName: "List")
            let listObj = try heap.get(listId)
            listObj.listStorage = userArgs.map { .string($0) }
            return .objectRef(listId)
        }
    }

    private func registerHeapAwareStringBuiltins(heap: Heap) {
        register(name: "stringSplit") { args in
            guard args.count >= 2,
                  case .string(let s) = args[0],
                  case .string(let delimiter) = args[1] else {
                throw VMError.typeMismatch(expected: "String, String", actual: "invalid args", operation: "stringSplit")
            }
            let parts = delimiter.isEmpty ? s.map { String($0) } : s.components(separatedBy: delimiter)
            let listId = heap.allocate(typeName: "List")
            let listObj = try heap.get(listId)
            listObj.listStorage = parts.map { .string($0) }
            return .objectRef(listId)
        }

        register(name: "stringConcat") { args in
            guard args.count >= 2,
                  case .string(let a) = args[0],
                  case .string(let b) = args[1] else {
                throw VMError.typeMismatch(expected: "String, String", actual: "invalid args", operation: "stringConcat")
            }
            return .string(a + b)
        }

        register(name: "stringFromCharCodes") { args in
            guard args.count >= 1, case .objectRef(let id) = args[0] else {
                throw VMError.typeMismatch(expected: "List of Int", actual: args.first?.typeName ?? "nothing", operation: "stringFromCharCodes")
            }
            let obj = try heap.get(id)
            guard let elements = obj.listStorage else {
                throw VMError.typeMismatch(expected: "List", actual: obj.typeName, operation: "stringFromCharCodes")
            }
            var result = ""
            for element in elements {
                guard case .int(let code) = element, let scalar = UnicodeScalar(Int(code)) else { continue }
                result.append(Character(scalar))
            }
            return .string(result)
        }

        register(name: "stringToBytes") { args in
            guard args.count >= 1, case .string(let s) = args[0] else {
                throw VMError.typeMismatch(expected: "String", actual: args.first?.typeName ?? "nothing", operation: "stringToBytes")
            }
            let utf8Bytes = Array(s.utf8)
            let listId = heap.allocate(typeName: "List")
            let listObj = try heap.get(listId)
            listObj.listStorage = utf8Bytes.map { .int(Int64($0)) }
            return .objectRef(listId)
        }
    }

    // MARK: Network, Time & Random Builtins

    private func registerNetworkBuiltins(heap: Heap) {
        register(name: "tcpConnect") { args in
            guard args.count >= 2,
                  case .string(let host) = args[0],
                  case .int(let port) = args[1] else {
                throw VMError.typeMismatch(expected: "String, Int", actual: "invalid args", operation: "tcpConnect")
            }
            var hints = addrinfo()
            #if os(Linux)
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
            #else
            hints.ai_socktype = SOCK_STREAM
            #endif
            var result: UnsafeMutablePointer<addrinfo>?
            let portStr = String(port)
            let ret = getaddrinfo(host, portStr, &hints, &result)
            guard ret == 0, let addrInfo = result else {
                if let r = result { freeaddrinfo(r) }
                return .int(-1)
            }
            let fd = socket(Int32(addrInfo.pointee.ai_family),
                           Int32(addrInfo.pointee.ai_socktype),
                           Int32(addrInfo.pointee.ai_protocol))
            guard fd >= 0 else {
                freeaddrinfo(addrInfo)
                return .int(-1)
            }
            let connResult = connect(fd, addrInfo.pointee.ai_addr,
                                     addrInfo.pointee.ai_addrlen)
            freeaddrinfo(addrInfo)
            guard connResult == 0 else {
                close(fd)
                return .int(-1)
            }
            return .int(Int64(fd))
        }

        register(name: "tcpSend") { args in
            guard args.count >= 2,
                  case .int(let fd) = args[0],
                  case .string(let data) = args[1] else {
                throw VMError.typeMismatch(expected: "Int, String", actual: "invalid args", operation: "tcpSend")
            }
            let bytes = Array(data.utf8)
            let sent = bytes.withUnsafeBufferPointer { buf in
                send(Int32(fd), buf.baseAddress, buf.count, 0)
            }
            return .int(Int64(sent))
        }

        register(name: "tcpRecv") { args in
            guard args.count >= 2,
                  case .int(let fd) = args[0],
                  case .int(let maxBytes) = args[1] else {
                throw VMError.typeMismatch(expected: "Int, Int", actual: "invalid args", operation: "tcpRecv")
            }
            var buffer = [UInt8](repeating: 0, count: Int(maxBytes))
            let n = buffer.withUnsafeMutableBufferPointer { buf in
                recv(Int32(fd), buf.baseAddress, buf.count, 0)
            }
            if n <= 0 { return .string("") }
            return .string(String(bytes: buffer[0..<n], encoding: .utf8) ?? "")
        }

        register(name: "tcpClose") { args in
            guard case .int(let fd) = args.first else {
                throw VMError.typeMismatch(expected: "Int", actual: args.first?.typeName ?? "nothing", operation: "tcpClose")
            }
            close(Int32(fd))
            return .unit
        }

        register(name: "currentTimeMillis") { _ in
            let ms = Int64(Date().timeIntervalSince1970 * 1000)
            return .int(ms)
        }

        register(name: "currentTimeNanos") { _ in
            var ts = timespec()
            clock_gettime(CLOCK_MONOTONIC, &ts)
            return .int(Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec))
        }

        register(name: "sleepMillis") { args in
            guard case .int(let ms) = args.first else {
                throw VMError.typeMismatch(expected: "Int", actual: args.first?.typeName ?? "nothing", operation: "sleepMillis")
            }
            usleep(UInt32(ms * 1000))
            return .unit
        }

        register(name: "randomInt") { args in
            guard case .int(let bound) = args.first else {
                throw VMError.typeMismatch(expected: "Int", actual: args.first?.typeName ?? "nothing", operation: "randomInt")
            }
            if bound <= 0 { return .int(0) }
            return .int(Int64.random(in: 0..<bound))
        }

        register(name: "epochToComponents") { args in
            guard case .int(let epochSec) = args.first else {
                throw VMError.typeMismatch(expected: "Int", actual: args.first?.typeName ?? "nothing", operation: "epochToComponents")
            }
            let date = Date(timeIntervalSince1970: TimeInterval(epochSec))
            let cal = Calendar(identifier: .gregorian)
            let tz = TimeZone(identifier: "UTC")!
            let comps = cal.dateComponents(in: tz, from: date)
            let mapId = heap.allocate(typeName: "HashMap")
            let mapObj = try heap.get(mapId)
            mapObj.mapStorage = [:]
            mapObj.mapStorage?[.string("year")] = .int(Int64(comps.year ?? 1970))
            mapObj.mapStorage?[.string("month")] = .int(Int64(comps.month ?? 1))
            mapObj.mapStorage?[.string("day")] = .int(Int64(comps.day ?? 1))
            mapObj.mapStorage?[.string("hour")] = .int(Int64(comps.hour ?? 0))
            mapObj.mapStorage?[.string("minute")] = .int(Int64(comps.minute ?? 0))
            mapObj.mapStorage?[.string("second")] = .int(Int64(comps.second ?? 0))
            // 1=Sunday in Calendar, convert to 0=Sunday
            mapObj.mapStorage?[.string("dayOfWeek")] = .int(Int64((comps.weekday ?? 1) - 1))
            return .objectRef(mapId)
        }
    }

    // MARK: Heap-Aware File I/O Builtins

    private func registerFileIOBuiltins(heap: Heap) {
        register(name: "fileWriteBytes") { args in
            guard args.count >= 2,
                  case .string(let path) = args[0],
                  case .objectRef(let id) = args[1] else {
                throw VMError.typeMismatch(
                    expected: "String, List of Int",
                    actual: "invalid args",
                    operation: "fileWriteBytes"
                )
            }
            let obj = try heap.get(id)
            guard let elements = obj.listStorage else {
                throw VMError.typeMismatch(
                    expected: "List",
                    actual: obj.typeName,
                    operation: "fileWriteBytes"
                )
            }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(elements.count)
            for (index, element) in elements.enumerated() {
                guard case .int(let value) = element else {
                    throw VMError.typeMismatch(
                        expected: "Int",
                        actual: element.typeName,
                        operation: "fileWriteBytes (element \(index))"
                    )
                }
                guard value >= 0, value <= 255 else {
                    throw VMError.typeMismatch(
                        expected: "Int in range 0-255",
                        actual: "Int(\(value))",
                        operation: "fileWriteBytes (element \(index))"
                    )
                }
                bytes.append(UInt8(value))
            }
            let data = Data(bytes)
            let url = URL(fileURLWithPath: path)
            do {
                try data.write(to: url)
                return .unit
            } catch {
                throw VMError.userException(message: "fileWriteBytes: failed to write to '\(path)': \(error.localizedDescription)")
            }
        }
    }

    // MARK: Security Builtins

    private func registerSecurityBuiltins() {
        // TLS builtins remain LLVM-only (require OpenSSL C library)
        let tlsOnlyNames = [
            "tlsCreateContext", "tlsCreateServerContext",
            "tlsSetCertificate", "tlsSetPrivateKey", "tlsSetVerifyPeer", "tlsSetAlpn",
            "tlsConnect", "tlsSend", "tlsRecv", "tlsClose",
            "tlsGetAlpn", "tlsGetPeerCert",
            "tlsListen", "tlsAccept",
            "tlsLastError",
        ]
        for name in tlsOnlyNames {
            register(name: name) { _ in
                throw VMError.userException(
                    message: "\(name) requires OpenSSL — use LLVM-compiled binary"
                )
            }
        }

        // X.509 certificate parsing via Security framework
        registerX509Builtins()

        // Crypto hashing — implemented via CryptoKit
        register(name: "cryptoSha256") { args in
            guard case .string(let input) = args.first else {
                throw VMError.typeMismatch(expected: "String", actual: args.first?.typeName ?? "nothing", operation: "cryptoSha256")
            }
            let data = Data(input.utf8)
            let digest = SHA256.hash(data: data)
            return .string(String(bytes: Array(digest), encoding: .isoLatin1) ?? "")
        }

        register(name: "cryptoSha1") { args in
            guard case .string(let input) = args.first else {
                throw VMError.typeMismatch(expected: "String", actual: args.first?.typeName ?? "nothing", operation: "cryptoSha1")
            }
            let data = Data(input.utf8)
            let digest = Insecure.SHA1.hash(data: data)
            return .string(String(bytes: Array(digest), encoding: .isoLatin1) ?? "")
        }

        register(name: "cryptoSha512") { args in
            guard case .string(let input) = args.first else {
                throw VMError.typeMismatch(expected: "String", actual: args.first?.typeName ?? "nothing", operation: "cryptoSha512")
            }
            let data = Data(input.utf8)
            let digest = SHA512.hash(data: data)
            return .string(String(bytes: Array(digest), encoding: .isoLatin1) ?? "")
        }

        register(name: "cryptoMd5") { args in
            guard case .string(let input) = args.first else {
                throw VMError.typeMismatch(expected: "String", actual: args.first?.typeName ?? "nothing", operation: "cryptoMd5")
            }
            let data = Data(input.utf8)
            let digest = Insecure.MD5.hash(data: data)
            return .string(String(bytes: Array(digest), encoding: .isoLatin1) ?? "")
        }

        // HMAC
        register(name: "cryptoHmacSha256") { args in
            guard args.count >= 2,
                  case .string(let key) = args[0],
                  case .string(let msg) = args[1] else {
                throw VMError.typeMismatch(expected: "String, String", actual: "invalid args", operation: "cryptoHmacSha256")
            }
            let keyData = SymmetricKey(data: Data(key.utf8))
            let mac = HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: keyData)
            return .string(String(bytes: Array(Data(mac)), encoding: .isoLatin1) ?? "")
        }

        register(name: "cryptoHmacSha1") { args in
            guard args.count >= 2,
                  case .string(let key) = args[0],
                  case .string(let msg) = args[1] else {
                throw VMError.typeMismatch(expected: "String, String", actual: "invalid args", operation: "cryptoHmacSha1")
            }
            let keyData = SymmetricKey(data: Data(key.utf8))
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(msg.utf8), using: keyData)
            return .string(String(bytes: Array(Data(mac)), encoding: .isoLatin1) ?? "")
        }

        // Random bytes
        register(name: "cryptoRandomBytes") { args in
            guard case .int(let count) = args.first else {
                throw VMError.typeMismatch(expected: "Int", actual: args.first?.typeName ?? "nothing", operation: "cryptoRandomBytes")
            }
            if count <= 0 { return .string("") }
            var bytes = [UInt8](repeating: 0, count: Int(count))
            #if canImport(Security)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            #else
            for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
            #endif
            return .string(String(bytes: bytes, encoding: .isoLatin1) ?? "")
        }

        // AES encrypt (mode 0=CBC, 1=GCM)
        register(name: "cryptoAesEncrypt") { args in
            guard args.count >= 4,
                  case .string(let key) = args[0],
                  case .string(let iv) = args[1],
                  case .string(let plaintext) = args[2],
                  case .int(let mode) = args[3] else {
                throw VMError.typeMismatch(expected: "String, String, String, Int", actual: "invalid args", operation: "cryptoAesEncrypt")
            }
            let keyBytes = Array(key.unicodeScalars.map { UInt8($0.value & 0xFF) })
            let ivBytes = Array(iv.unicodeScalars.map { UInt8($0.value & 0xFF) })
            let ptBytes = Array(plaintext.unicodeScalars.map { UInt8($0.value & 0xFF) })

            if mode == 1 {
                // AES-GCM
                let symmetricKey = SymmetricKey(data: keyBytes)
                let nonce = try AES.GCM.Nonce(data: ivBytes)
                let sealed = try AES.GCM.seal(Data(ptBytes), using: symmetricKey, nonce: nonce)
                // Return ciphertext + tag (same as C implementation)
                var result = Array(sealed.ciphertext)
                result.append(contentsOf: sealed.tag)
                return .string(String(bytes: result, encoding: .isoLatin1) ?? "")
            } else {
                // AES-CBC
                #if canImport(CommonCrypto)
                let bufferSize = ptBytes.count + kCCBlockSizeAES128
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                var numBytesEncrypted = 0
                let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                     CCOptions(kCCOptionPKCS7Padding),
                                     keyBytes, keyBytes.count,
                                     ivBytes,
                                     ptBytes, ptBytes.count,
                                     &buffer, bufferSize, &numBytesEncrypted)
                guard status == kCCSuccess else { return .string("") }
                return .string(String(bytes: Array(buffer[0..<numBytesEncrypted]), encoding: .isoLatin1) ?? "")
                #elseif canImport(COpenSSL)
                let ctx = EVP_CIPHER_CTX_new()
                defer { EVP_CIPHER_CTX_free(ctx) }
                EVP_CipherInit_ex(ctx, EVP_aes_256_cbc(), nil, keyBytes, ivBytes, 1)
                var outLen: Int32 = 0
                var buffer = [UInt8](repeating: 0, count: ptBytes.count + 16)
                EVP_CipherUpdate(ctx, &buffer, &outLen, ptBytes, Int32(ptBytes.count))
                var totalLen = outLen
                var finalBuf = [UInt8](repeating: 0, count: 16)
                EVP_CipherFinal_ex(ctx, &finalBuf, &outLen)
                for i in 0..<Int(outLen) { buffer[Int(totalLen) + i] = finalBuf[i] }
                totalLen += outLen
                return .string(String(bytes: Array(buffer[0..<Int(totalLen)]), encoding: .isoLatin1) ?? "")
                #else
                return .string("")
                #endif
            }
        }

        // AES decrypt (mode 0=CBC, 1=GCM)
        register(name: "cryptoAesDecrypt") { args in
            guard args.count >= 4,
                  case .string(let key) = args[0],
                  case .string(let iv) = args[1],
                  case .string(let ciphertext) = args[2],
                  case .int(let mode) = args[3] else {
                throw VMError.typeMismatch(expected: "String, String, String, Int", actual: "invalid args", operation: "cryptoAesDecrypt")
            }
            let keyBytes = Array(key.unicodeScalars.map { UInt8($0.value & 0xFF) })
            let ivBytes = Array(iv.unicodeScalars.map { UInt8($0.value & 0xFF) })
            let ctBytes = Array(ciphertext.unicodeScalars.map { UInt8($0.value & 0xFF) })

            if mode == 1 {
                // AES-GCM: last 16 bytes are tag
                guard ctBytes.count >= 16 else { return .string("") }
                let cipherLen = ctBytes.count - 16
                let ct = Array(ctBytes[0..<cipherLen])
                let tag = Array(ctBytes[cipherLen...])
                let symmetricKey = SymmetricKey(data: keyBytes)
                let nonce = try AES.GCM.Nonce(data: ivBytes)
                let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(ct), tag: Data(tag))
                let decrypted = try AES.GCM.open(sealedBox, using: symmetricKey)
                return .string(String(bytes: Array(decrypted), encoding: .isoLatin1) ?? "")
            } else {
                // AES-CBC
                #if canImport(CommonCrypto)
                let bufferSize = ctBytes.count + kCCBlockSizeAES128
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                var numBytesDecrypted = 0
                let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                     CCOptions(kCCOptionPKCS7Padding),
                                     keyBytes, keyBytes.count,
                                     ivBytes,
                                     ctBytes, ctBytes.count,
                                     &buffer, bufferSize, &numBytesDecrypted)
                guard status == kCCSuccess else { return .string("") }
                return .string(String(bytes: Array(buffer[0..<numBytesDecrypted]), encoding: .isoLatin1) ?? "")
                #elseif canImport(COpenSSL)
                let ctx = EVP_CIPHER_CTX_new()
                defer { EVP_CIPHER_CTX_free(ctx) }
                EVP_CipherInit_ex(ctx, EVP_aes_256_cbc(), nil, keyBytes, ivBytes, 0)
                var outLen: Int32 = 0
                var buffer = [UInt8](repeating: 0, count: ctBytes.count + 16)
                EVP_CipherUpdate(ctx, &buffer, &outLen, ctBytes, Int32(ctBytes.count))
                var totalLen = outLen
                var finalBuf = [UInt8](repeating: 0, count: 16)
                EVP_CipherFinal_ex(ctx, &finalBuf, &outLen)
                for i in 0..<Int(outLen) { buffer[Int(totalLen) + i] = finalBuf[i] }
                totalLen += outLen
                return .string(String(bytes: Array(buffer[0..<Int(totalLen)]), encoding: .isoLatin1) ?? "")
                #else
                return .string("")
                #endif
            }
        }
    }

    // MARK: - X.509 Certificate Builtins

    /// Handle table for parsed certificates
    #if canImport(Security)
    private static var x509Handles: [Int: SecCertificate] = [:]
    #else
    private static var x509Handles: [Int: OpaquePointer] = [:]
    #endif
    private static var x509NextHandle: Int = 0
    /// Store raw PEM data for fields Security framework can't extract directly
    private static var x509PemData: [Int: Data] = [:]

    private func registerX509Builtins() {

        // x509ParsePem(pemData: String) -> Int (handle, or -1 on error)
        register(name: "x509ParsePem") { args in
            guard case .string(let pemString) = args.first else {
                throw VMError.typeMismatch(expected: "String", actual: args.first?.typeName ?? "nothing", operation: "x509ParsePem")
            }
            // Strip PEM headers and decode base64
            let lines = pemString.components(separatedBy: "\n")
            var base64 = ""
            var inBlock = false
            for line in lines {
                if line.hasPrefix("-----BEGIN") { inBlock = true; continue }
                if line.hasPrefix("-----END") { break }
                if inBlock { base64 += line.trimmingCharacters(in: .whitespaces) }
            }
            guard let derData = Data(base64Encoded: base64) else {
                return .int(-1)
            }
            #if canImport(Security)
            guard let cert = SecCertificateCreateWithData(nil, derData as CFData) else {
                return .int(-1)
            }
            #else
            let cert: OpaquePointer? = derData.withUnsafeBytes { rawBuf -> OpaquePointer? in
                guard let basePtr = rawBuf.baseAddress else { return nil }
                var p: UnsafePointer<UInt8>? = basePtr.assumingMemoryBound(to: UInt8.self)
                return d2i_X509(nil, &p, derData.count)
            }
            guard let cert else { return .int(-1) }
            #endif
            let handle = BuiltinRegistry.x509NextHandle
            BuiltinRegistry.x509NextHandle += 1
            BuiltinRegistry.x509Handles[handle] = cert
            BuiltinRegistry.x509PemData[handle] = derData
            return .int(Int64(handle))
        }

        // x509Subject(handle: Int) -> String
        register(name: "x509Subject") { args in
            guard case .int(let h) = args.first else {
                throw VMError.typeMismatch(expected: "Int", actual: args.first?.typeName ?? "nothing", operation: "x509Subject")
            }
            guard let cert = BuiltinRegistry.x509Handles[Int(h)] else { return .string("") }
            #if canImport(Security)
            #if os(macOS)
            if let values = SecCertificateCopyValues(cert, [kSecOIDX509V1SubjectName] as CFArray, nil) as? [String: Any],
               let subjectEntry = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
               let subjectValue = subjectEntry[kSecPropertyKeyValue as String] {
                if let pairs = subjectValue as? [[String: Any]] {
                    let parts = pairs.compactMap { pair -> String? in
                        guard let label = pair[kSecPropertyKeyLabel as String] as? String,
                              let value = pair[kSecPropertyKeyValue as String] as? String else { return nil }
                        return "\(label)=\(value)"
                    }
                    return .string(parts.joined(separator: ", "))
                }
            }
            #endif
            let summary = SecCertificateCopySubjectSummary(cert) as String? ?? ""
            return .string("CN=\(summary)")
            #else
            let subj = X509_get_subject_name(cert)
            let buf = X509_NAME_oneline(subj, nil, 0)
            let result = buf != nil ? String(cString: buf!) : ""
            COpenSSL_free(buf)
            return .string(result)
            #endif
        }

        // x509Issuer(handle: Int) -> String
        register(name: "x509Issuer") { args in
            guard case .int(let h) = args.first else {
                throw VMError.typeMismatch(expected: "Int", actual: args.first?.typeName ?? "nothing", operation: "x509Issuer")
            }
            guard let cert = BuiltinRegistry.x509Handles[Int(h)] else { return .string("") }
            #if canImport(Security)
            #if os(macOS)
            if let values = SecCertificateCopyValues(cert, [kSecOIDX509V1IssuerName] as CFArray, nil) as? [String: Any],
               let issuerEntry = values[kSecOIDX509V1IssuerName as String] as? [String: Any],
               let issuerValue = issuerEntry[kSecPropertyKeyValue as String] {
                if let pairs = issuerValue as? [[String: Any]] {
                    let parts = pairs.compactMap { pair -> String? in
                        guard let label = pair[kSecPropertyKeyLabel as String] as? String,
                              let value = pair[kSecPropertyKeyValue as String] as? String else { return nil }
                        return "\(label)=\(value)"
                    }
                    return .string(parts.joined(separator: ", "))
                }
            }
            #endif
            let summary = SecCertificateCopySubjectSummary(cert) as String? ?? ""
            return .string("CN=\(summary)")
            #else
            let issuer = X509_get_issuer_name(cert)
            let buf = X509_NAME_oneline(issuer, nil, 0)
            let result = buf != nil ? String(cString: buf!) : ""
            COpenSSL_free(buf)
            return .string(result)
            #endif
        }

        // x509NotBefore(handle: Int) -> Int (epoch seconds)
        register(name: "x509NotBefore") { args in
            guard case .int(let h) = args.first else {
                throw VMError.typeMismatch(expected: "Int", actual: args.first?.typeName ?? "nothing", operation: "x509NotBefore")
            }
            guard let cert = BuiltinRegistry.x509Handles[Int(h)] else { return .int(0) }
            #if canImport(Security)
            #if os(macOS)
            if let values = SecCertificateCopyValues(cert, [kSecOIDX509V1ValidityNotBefore] as CFArray, nil) as? [String: Any],
               let entry = values[kSecOIDX509V1ValidityNotBefore as String] as? [String: Any],
               let number = entry[kSecPropertyKeyValue as String] as? NSNumber {
                let cfAbsTime = number.doubleValue
                let epoch = Int64(cfAbsTime + 978307200)
                return .int(epoch)
            }
            #endif
            return .int(0)
            #else
            let asn1 = X509_get0_notBefore(cert)
            var tmVal = tm()
            ASN1_TIME_to_tm(asn1, &tmVal)
            let epoch = Int64(timegm(&tmVal))
            return .int(epoch)
            #endif
        }

        // x509NotAfter(handle: Int) -> Int (epoch seconds)
        register(name: "x509NotAfter") { args in
            guard case .int(let h) = args.first else {
                throw VMError.typeMismatch(expected: "Int", actual: args.first?.typeName ?? "nothing", operation: "x509NotAfter")
            }
            guard let cert = BuiltinRegistry.x509Handles[Int(h)] else { return .int(0) }
            #if canImport(Security)
            #if os(macOS)
            if let values = SecCertificateCopyValues(cert, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any],
               let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
               let number = entry[kSecPropertyKeyValue as String] as? NSNumber {
                let cfAbsTime = number.doubleValue
                let epoch = Int64(cfAbsTime + 978307200)
                return .int(epoch)
            }
            #endif
            return .int(0)
            #else
            let asn1 = X509_get0_notAfter(cert)
            var tmVal = tm()
            ASN1_TIME_to_tm(asn1, &tmVal)
            let epoch = Int64(timegm(&tmVal))
            return .int(epoch)
            #endif
        }

        // x509SerialNumber(handle: Int) -> String (hex)
        register(name: "x509SerialNumber") { args in
            guard case .int(let h) = args.first else {
                throw VMError.typeMismatch(expected: "Int", actual: args.first?.typeName ?? "nothing", operation: "x509SerialNumber")
            }
            guard let cert = BuiltinRegistry.x509Handles[Int(h)] else { return .string("") }
            #if canImport(Security)
            #if os(macOS)
            if let values = SecCertificateCopyValues(cert, [kSecOIDX509V1SerialNumber] as CFArray, nil) as? [String: Any],
               let entry = values[kSecOIDX509V1SerialNumber as String] as? [String: Any],
               let serialStr = entry[kSecPropertyKeyValue as String] as? String {
                return .string(serialStr)
            }
            #endif
            if let serialData = SecCertificateCopySerialNumberData(cert, nil) as Data? {
                let hex = serialData.map { String(format: "%02X", $0) }.joined()
                return .string(hex)
            }
            return .string("")
            #else
            let serial = X509_get_serialNumber(cert)
            let bn = ASN1_INTEGER_to_BN(serial, nil)
            let hexPtr = BN_bn2hex(bn)
            let hex = hexPtr != nil ? String(cString: hexPtr!) : ""
            COpenSSL_free(hexPtr)
            BN_free(bn)
            return .string(hex)
            #endif
        }

        // x509Free(handle: Int) -> Unit
        register(name: "x509Free") { args in
            guard case .int(let h) = args.first else {
                throw VMError.typeMismatch(expected: "Int", actual: args.first?.typeName ?? "nothing", operation: "x509Free")
            }
            #if !canImport(Security)
            if let cert = BuiltinRegistry.x509Handles[Int(h)] {
                X509_free(cert)
            }
            #endif
            BuiltinRegistry.x509Handles.removeValue(forKey: Int(h))
            BuiltinRegistry.x509PemData.removeValue(forKey: Int(h))
            return .null
        }
    }
}
