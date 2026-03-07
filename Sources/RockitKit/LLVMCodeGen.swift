// LLVMCodeGen.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation

// MARK: - LLVM Code Generator

/// Generates LLVM IR text (.ll) from an optimized MIR module.
/// The emitted IR uses alloca-based register mapping; LLVM's mem2reg pass
/// (triggered by clang -O1) promotes allocas to SSA form.
public final class LLVMCodeGen {

    /// Counter for unique SSA names within a function.
    private var ssaCounter: Int = 0
    /// Map from MIR register names to their alloca LLVM names.
    private var registerMap: [String: String] = [:]
    /// Map from MIR register names to their LLVM type string.
    private var registerTypes: [String: String] = [:]
    /// String literal pool: value → C string global name (used for function references).
    private var stringPool: [String: String] = [:]
    /// Counter for string literal globals.
    private var stringCounter: Int = 0
    /// Immortal RockitString globals: value → global name (pre-built structs, no malloc).
    private var rockitStringGlobals: [String: String] = [:]
    /// Counter for RockitString globals.
    private var rockitStringCounter: Int = 0
    /// Collected function declarations (externals).
    private var externalDecls: Set<String> = []
    /// Current function's parameter names for `param.X` resolution.
    private var currentParams: [(String, MIRType)] = []
    /// Map from param name → LLVM argument name.
    private var paramMap: [String: String] = [:]
    /// The module's type declarations for field index lookup.
    private var typeDecls: [String: MIRTypeDecl] = [:]
    /// Map from function name → return type for user-defined functions.
    private var functionSignatures: [String: MIRType] = [:]
    /// Map from function name → parameter types for generic call-site conversions.
    private var functionParamTypes: [String: [MIRType]] = [:]
    /// Current class name when emitting a method (for `global.X` → field resolution).
    private var currentClassName: String? = nil
    /// String pool for type name constants (separate from string literals).
    private var typeNamePool: [String: String] = [:]
    /// Counter for type name constants.
    private var typeNameCounter: Int = 0
    /// Map from catch block label → exception dest temp name.
    private var catchBlocks: [String: String] = [:]
    /// Track all external call signatures: funcName → (returnType, [paramTypes])
    private var calledExternals: [String: (ret: String, params: [String])] = [:]
    /// Counter for unique label names (for branching in type casts, dispatch, etc.)
    private var labelCounter: Int = 0
    /// Module-level globals (enum singletons, top-level vals/vars).
    /// Maps "global.Color.RED" → LLVM type (e.g. "ptr").
    private var moduleGlobals: [String: String] = [:]
    /// Global initializer functions: "global.Color.RED" → "__init_Color_RED"
    private var globalInitializers: [String: String] = [:]
    /// Set of all function names defined in the module (for lambda pointer resolution).
    private var moduleFunctionNames: Set<String> = []
    /// Index of MIR functions by name (for interprocedural escape analysis).
    private var mirFunctionsByName: [String: MIRFunction] = [:]

    public init() {}

    // MARK: - Public API

    /// Emit LLVM IR text for the entire MIR module.
    public func emit(module: MIRModule) -> String {
        // Reset state
        ssaCounter = 0
        registerMap = [:]
        registerTypes = [:]
        stringPool = [:]
        stringCounter = 0
        rockitStringGlobals = [:]
        rockitStringCounter = 0
        externalDecls = []
        typeDecls = [:]
        functionSignatures = [:]
        functionParamTypes = [:]
        currentClassName = nil
        typeNamePool = [:]
        typeNameCounter = 0
        labelCounter = 0
        moduleGlobals = [:]
        globalInitializers = [:]
        moduleFunctionNames = Set(module.functions.map { $0.name })
        mirFunctionsByName = Dictionary(uniqueKeysWithValues: module.functions.map { ($0.name, $0) })
        nonEscapingParams = [:]

        // Index type declarations
        for t in module.types {
            typeDecls[t.name] = t
        }

        // Index function signatures for call-site return type resolution
        for f in module.functions {
            functionSignatures[f.name] = f.returnType
            functionParamTypes[f.name] = f.parameters.map { $0.1 }
        }

        // Pre-pass: find which function parameters are used as callIndirect targets.
        // This enables cross-function tracing: if foo's 3rd param is called indirectly,
        // then any call to foo marks its 3rd argument as an indirect call target.
        callableParams = [:]
        for f in module.functions {
            var callIndirectTemps = Set<String>()
            for block in f.blocks {
                for inst in block.instructions {
                    if case .callIndirect(_, let funcRef, _) = inst {
                        callIndirectTemps.insert(funcRef)
                    }
                }
            }
            if callIndirectTemps.isEmpty { continue }
            // Trace backward through load/store to find which params reach callIndirect
            var targets = callIndirectTemps
            var changed = true
            while changed {
                changed = false
                for block in f.blocks {
                    for inst in block.instructions {
                        switch inst {
                        case .load(let dest, let src):
                            if targets.contains(dest) && !targets.contains(src) {
                                targets.insert(src)
                                changed = true
                            }
                        case .store(let dest, let src):
                            if targets.contains(dest) && !targets.contains(src) {
                                targets.insert(src)
                                changed = true
                            }
                        default:
                            break
                        }
                    }
                }
            }
            // Map parameter names to indices
            var indices = Set<Int>()
            for (i, (name, _)) in f.parameters.enumerated() {
                if targets.contains("param.\(name)") {
                    indices.insert(i)
                }
            }
            if !indices.isEmpty {
                callableParams[f.name] = indices
            }
        }

        // Pre-pass: correct method return types by analyzing function bodies
        // MIR lowering may emit .unit for methods that actually return values
        for f in module.functions where f.returnType == .unit {
            let inferred = inferActualReturnType(f)
            if inferred != "void" {
                // Store a synthetic MIR type that maps to the inferred LLVM type
                switch inferred {
                case "i64": functionSignatures[f.name] = .int
                case "double": functionSignatures[f.name] = .float64
                case "i1": functionSignatures[f.name] = .bool
                case "ptr": functionSignatures[f.name] = .string  // ptr could be string or object
                default: break
                }
            }
        }

        var lines: [String] = []

        // Module header
        lines.append("; Rockit LLVM IR — generated by command (Stage 0)")
        lines.append("target triple = \"\(targetTriple())\"")
        lines.append("")

        // Collect string literals and type names from all functions
        collectStrings(module: module)
        collectTypeNames(module: module)

        // Prepare hierarchy table (this may intern additional type names)
        let hierarchyLines = emitTypeHierarchyTable(module: module)

        // Emit C string literal globals (used for function pointer references)
        for (value, name) in stringPool.sorted(by: { $0.value < $1.value }) {
            let escaped = llvmEscapeString(value)
            let len = value.utf8.count + 1  // +1 for null terminator
            lines.append("\(name) = private unnamed_addr constant [\(len) x i8] c\"\(escaped)\\00\"")
        }
        // Emit type name globals (for rockit_object_alloc and type checking)
        for (value, name) in typeNamePool.sorted(by: { $0.value < $1.value }) {
            let escaped = llvmEscapeString(value)
            let len = value.utf8.count + 1
            lines.append("\(name) = private unnamed_addr constant [\(len) x i8] c\"\(escaped)\\00\"")
        }
        // Emit immortal RockitString globals (pre-built structs, no malloc needed)
        // Layout matches C struct: { i64 refCount, i64 length, ptr chars, ptr base, i64 capacity, [N x i8] data }
        // chars points to the data[] portion (offset 40 bytes from struct start).
        // base is null (owned string, not a slice).
        for (value, name) in rockitStringGlobals.sorted(by: { $0.value < $1.value }) {
            let escaped = llvmEscapeString(value)
            let dataLen = value.utf8.count + 1  // +1 for null terminator
            let strLen = value.utf8.count
            // chars = GEP into the data[] portion of the same global (offset 40 = 5 * i64)
            lines.append("\(name) = private global <{ i64, i64, ptr, ptr, i64, [\(dataLen) x i8] }> <{ i64 9223372036854775807, i64 \(strLen), ptr getelementptr (i8, ptr \(name), i64 40), ptr null, i64 \(strLen), [\(dataLen) x i8] c\"\(escaped)\\00\" }>")
        }
        if !stringPool.isEmpty || !typeNamePool.isEmpty || !rockitStringGlobals.isEmpty {
            lines.append("")
        }

        // Emit type hierarchy table after globals it references
        lines.append(contentsOf: hierarchyLines)

        // Emit module-level globals (enum singletons, top-level variables)
        for g in module.globals {
            let globalName = "global.\(g.name)"
            let llvmTy = llvmType(g.type)
            let ty = llvmTy == "void" ? "ptr" : llvmTy
            moduleGlobals[globalName] = ty
            if let initFunc = g.initializerFunc {
                globalInitializers[globalName] = initFunc
            }
            let zeroInit: String
            switch ty {
            case "ptr": zeroInit = "null"
            case "i1": zeroInit = "false"
            case "double": zeroInit = "0.0"
            default: zeroInit = "0"
            }
            lines.append("@\(globalName) = internal global \(ty) \(zeroInit)")
        }
        if !module.globals.isEmpty {
            lines.append("")
        }

        // Emit functions first (to discover all external calls)
        var functionBodies: [String] = []
        for function in module.functions {
            functionBodies.append(emitFunction(function))
            functionBodies.append("")
        }

        // Emit known external declarations (skip any that are defined in the module)
        collectExternals(module: module)
        // Include both MIR names and mangled LLVM names (dots → underscores)
        var definedFunctions = Set(module.functions.map { $0.name })
        for f in module.functions {
            definedFunctions.insert(llvmFunctionName(f.name))
        }
        var declaredNames: Set<String> = []
        for decl in externalDecls.sorted() {
            if let atRange = decl.range(of: "@"),
               let parenRange = decl.range(of: "(", range: atRange.upperBound..<decl.endIndex) {
                let funcName = String(decl[atRange.upperBound..<parenRange.lowerBound])
                if definedFunctions.contains(funcName) { continue }
                declaredNames.insert(funcName)
            }
            lines.append(decl)
        }

        // Auto-declare any called functions that aren't defined or declared yet
        // Scan emitted function bodies for `call ... @funcName(` patterns
        let bodyText = functionBodies.joined(separator: "\n")
        autoDeclareMissingExternals(bodyText: bodyText, definedFunctions: definedFunctions,
                                     declaredNames: &declaredNames, lines: &lines)

        if !externalDecls.isEmpty || !declaredNames.isEmpty {
            lines.append("")
        }

        // Emit attributes (for setjmp returns_twice)
        lines.append("attributes #0 = { returns_twice }")
        lines.append("")

        // Append function bodies
        lines.append(contentsOf: functionBodies)

        // TBAA metadata for alias analysis — lets LLVM hoist list struct
        // field loads (size, data pointer) out of loops that store to elements
        lines.append("")
        lines.append("; TBAA metadata")
        lines.append("!0 = !{!\"Rockit TBAA\"}")
        lines.append("!1 = !{!\"list_struct_field\", !0}")
        lines.append("!2 = !{!\"list_element\", !0}")
        lines.append("!3 = !{!1, !1, i64 0}")
        lines.append("!4 = !{!2, !2, i64 0}")
        lines.append("")
        lines.append("; Branch weight metadata for bounds checks (hot path = in-bounds)")
        lines.append("!5 = !{!\"branch_weights\", i32 2000000, i32 1}")

        return lines.joined(separator: "\n")
    }

    // MARK: - Target Triple

    private func targetTriple() -> String {
        Platform.hostTargetTriple()
    }

    // MARK: - String Collection

    private func collectStrings(module: MIRModule) {
        // Pre-intern runtime panic messages
        internString("NullPointerException")
        internString("list index out of bounds")
        internString("byteArray index out of bounds")

        for function in module.functions {
            for block in function.blocks {
                for inst in block.instructions {
                    if case .constString(_, let value) = inst {
                        // Always intern — even if the string matches a function name,
                        // it may be used as a regular string (not a lambda reference).
                        internString(value)
                        // Also intern as an immortal RockitString global struct.
                        internRockitString(value)
                    }
                }
            }
        }
    }

    private func collectTypeNames(module: MIRModule) {
        for function in module.functions {
            for block in function.blocks {
                for inst in block.instructions {
                    switch inst {
                    case .newObject(_, let typeName, _):
                        internTypeName(typeName)
                    case .typeCheck(_, _, let typeName):
                        internTypeName(typeName)
                    case .typeCast(_, _, let typeName):
                        internTypeName(typeName)
                    default:
                        break
                    }
                }
            }
        }
    }

    @discardableResult
    private func internTypeName(_ value: String) -> String {
        if let existing = typeNamePool[value] {
            return existing
        }
        let name = "@.typename.\(typeNameCounter)"
        typeNameCounter += 1
        typeNamePool[value] = name
        return name
    }

    @discardableResult
    private func internString(_ value: String) -> String {
        if let existing = stringPool[value] {
            return existing
        }
        let name = "@.str.\(stringCounter)"
        stringCounter += 1
        stringPool[value] = name
        return name
    }

    /// Intern a string as an immortal RockitString global struct.
    /// Layout: { i64 refCount, i64 length, ptr chars, ptr base, [N x i8] data }
    @discardableResult
    private func internRockitString(_ value: String) -> String {
        if let existing = rockitStringGlobals[value] {
            return existing
        }
        let name = "@.rstr.\(rockitStringCounter)"
        rockitStringCounter += 1
        rockitStringGlobals[value] = name
        return name
    }

    // MARK: - Type Hierarchy Table

    /// Emit the type hierarchy table as a global constant array.
    /// Each entry is { ptr @child_name, ptr @parent_name }.
    /// Also emits a constructor function that registers it with the runtime.
    private func emitTypeHierarchyTable(module: MIRModule) -> [String] {
        // Collect all (child, parent) pairs from type declarations
        var entries: [(child: String, parent: String)] = []
        for typeDecl in module.types {
            if let parent = typeDecl.parentType {
                entries.append((child: typeDecl.name, parent: parent))
            }
        }

        guard !entries.isEmpty else { return [] }

        var lines: [String] = []

        // Ensure all type names in hierarchy are interned
        for entry in entries {
            internTypeName(entry.child)
            internTypeName(entry.parent)
        }

        // Emit the hierarchy table as a global constant array of { ptr, ptr }
        let count = entries.count
        let structType = "{ ptr, ptr }"
        var initializers: [String] = []
        for entry in entries {
            let childGlobal = typeNamePool[entry.child]!
            let parentGlobal = typeNamePool[entry.parent]!
            initializers.append("  \(structType) { ptr \(childGlobal), ptr \(parentGlobal) }")
        }
        lines.append("@rockit_type_hierarchy = private constant [\(count) x \(structType)] [")
        lines.append(initializers.joined(separator: ",\n"))
        lines.append("]")
        lines.append("")

        // Emit a constructor function that registers the hierarchy at program start
        lines.append("@llvm.global_ctors = appending global [1 x { i32, ptr, ptr }] [{ i32, ptr, ptr } { i32 65535, ptr @rockit_init_type_hierarchy, ptr null }]")
        lines.append("")
        lines.append("define internal void @rockit_init_type_hierarchy() nounwind {")
        lines.append("  call void @rockit_set_type_hierarchy(ptr @rockit_type_hierarchy, i32 \(count))")
        lines.append("  ret void")
        lines.append("}")
        lines.append("")

        return lines
    }

    // MARK: - External Declarations

    private func collectExternals(module: MIRModule) {
        // Always declare runtime functions we might use
        externalDecls.insert("declare void @rockit_println_int(i64)")
        externalDecls.insert("declare void @rockit_println_any(i64)")
        externalDecls.insert("declare void @rockit_println_float(double)")
        externalDecls.insert("declare void @rockit_println_bool(i1)")
        externalDecls.insert("declare void @rockit_println_string(ptr)")
        externalDecls.insert("declare void @rockit_println_null()")
        externalDecls.insert("declare void @rockit_print_int(i64)")
        externalDecls.insert("declare void @rockit_print_any(i64)")
        externalDecls.insert("declare void @rockit_print_float(double)")
        externalDecls.insert("declare void @rockit_print_bool(i1)")
        externalDecls.insert("declare void @rockit_print_string(ptr)")
        externalDecls.insert("declare ptr @rockit_string_new(ptr)")
        externalDecls.insert("declare ptr @rockit_string_concat(ptr, ptr)")
        externalDecls.insert("declare void @rockit_string_retain(ptr)")
        externalDecls.insert("declare void @rockit_string_release(ptr)")
        externalDecls.insert("declare i64 @rockit_string_length(ptr)")
        externalDecls.insert("declare ptr @rockit_int_to_string(i64)")
        externalDecls.insert("declare ptr @rockit_float_to_string(double)")
        externalDecls.insert("declare ptr @rockit_bool_to_string(i1)")
        externalDecls.insert("declare void @rockit_panic(ptr) noreturn")
        // Object runtime
        externalDecls.insert("declare ptr @rockit_object_alloc(ptr, i32)")
        externalDecls.insert("declare i64 @rockit_object_get_field(ptr, i32)")
        externalDecls.insert("declare void @rockit_object_set_field(ptr, i32, i64)")
        externalDecls.insert("declare void @rockit_retain(ptr)")
        externalDecls.insert("declare void @rockit_release(ptr)")
        // Universal value ARC (for write barriers on untyped fields)
        externalDecls.insert("declare void @rockit_retain_value(i64)")
        externalDecls.insert("declare void @rockit_release_value(i64)")
        // Type checking runtime
        externalDecls.insert("declare i8 @rockit_is_type(ptr, ptr)")
        externalDecls.insert("declare ptr @rockit_object_get_type_name(ptr)")
        externalDecls.insert("declare void @rockit_set_type_hierarchy(ptr, i32)")
        // List runtime
        externalDecls.insert("declare ptr @rockit_list_create()")
        externalDecls.insert("declare ptr @rockit_list_create_filled(i64, i64)")
        externalDecls.insert("declare void @rockit_list_append(ptr, i64)")
        externalDecls.insert("declare i64 @rockit_list_get(ptr, i64)")
        externalDecls.insert("declare void @rockit_list_set(ptr, i64, i64)")
        externalDecls.insert("declare i64 @rockit_list_size(ptr)")
        externalDecls.insert("declare i1 @rockit_list_is_empty(ptr)")
        externalDecls.insert("declare void @rockit_list_release(ptr)")
        // ByteArray runtime
        externalDecls.insert("declare i64 @byteArrayCreate(i64)")
        externalDecls.insert("declare i64 @byteArrayCreateFilled(i64, i64)")
        externalDecls.insert("declare i64 @byteArrayGet(i64, i64)")
        externalDecls.insert("declare void @byteArraySet(i64, i64, i64)")
        externalDecls.insert("declare i64 @byteArraySize(i64)")
        // Map runtime (string-keyed)
        externalDecls.insert("declare i64 @mapCreate()")
        externalDecls.insert("declare i64 @mapPut(i64, ptr, i64)")
        externalDecls.insert("declare i64 @mapGet(i64, ptr)")
        externalDecls.insert("declare i64 @mapKeys(i64)")
        // Exception handling
        externalDecls.insert("declare ptr @rockit_exc_push()")
        externalDecls.insert("declare void @rockit_exc_pop()")
        externalDecls.insert("declare void @rockit_exc_throw(i64)")
        externalDecls.insert("declare i64 @rockit_exc_get()")
        externalDecls.insert(Platform.setjmpDeclaration)
        // Actor runtime
        externalDecls.insert("declare ptr @rockit_actor_create(ptr, i32)")
        externalDecls.insert("declare ptr @rockit_actor_get_object(ptr)")
        externalDecls.insert("declare void @rockit_actor_release(ptr)")

        // Builtin wrappers (used by Stage 1 and user programs)
        // String operations
        externalDecls.insert("declare ptr @charAt(ptr, i64)")
        externalDecls.insert("declare i64 @charCodeAt(ptr, i64)")
        externalDecls.insert("declare ptr @intToChar(i64)")
        externalDecls.insert("declare i1 @startsWith(ptr, ptr)")
        externalDecls.insert("declare i1 @endsWith(ptr, ptr)")
        externalDecls.insert("declare ptr @stringConcat(ptr, ptr)")
        externalDecls.insert("declare i64 @stringIndexOf(ptr, ptr)")
        externalDecls.insert("declare i64 @stringLength(ptr)")
        externalDecls.insert("declare ptr @stringTrim(ptr)")
        externalDecls.insert("declare ptr @substring(ptr, i64, i64)")
        externalDecls.insert("declare i64 @toInt(i64)")
        // Character checks
        externalDecls.insert("declare i1 @isDigit(ptr)")
        externalDecls.insert("declare i1 @isLetter(ptr)")
        externalDecls.insert("declare i1 @isLetterOrDigit(ptr)")
        // Type checks
        externalDecls.insert("declare i1 @isMap(i64)")
        // Additional native runtime (remapped from bytecode builtins in emitCall)
        externalDecls.insert("declare i8 @rockit_list_contains(ptr, i64)")
        externalDecls.insert("declare i64 @rockit_list_remove_at(ptr, i64)")
        // I/O operations
        externalDecls.insert("declare ptr @readLine()")
        externalDecls.insert("declare i1 @fileExists(ptr)")
        externalDecls.insert("declare ptr @fileRead(ptr)")
        externalDecls.insert("declare i64 @fileWriteBytes(ptr, i64)")
        // Process
        externalDecls.insert("declare i64 @processArgs()")
        externalDecls.insert("declare i64 @getEnv(ptr)")
        externalDecls.insert("declare i64 @executablePath()")
        externalDecls.insert("declare i64 @platformOS()")
        externalDecls.insert("declare void @processExit(i64)")
        // Meta
        externalDecls.insert("declare i64 @evalRockit(ptr)")
        externalDecls.insert("declare i64 @systemExec(ptr)")
        externalDecls.insert("declare i64 @fileDelete(ptr)")
        // Polymorphic toString (handles both raw ints and string pointers)
        externalDecls.insert("declare ptr @toString(i64)")
        // String comparison (content-based, not pointer-based)
        externalDecls.insert("declare i1 @rockit_string_eq(i64, i64)")
        externalDecls.insert("declare i1 @rockit_string_neq(i64, i64)")
        // Process args initialization
        externalDecls.insert("declare void @rockit_set_args(i32, ptr)")
        // Math functions
        externalDecls.insert("declare double @rockit_math_sqrt(double)")
        externalDecls.insert("declare double @rockit_math_sin(double)")
        externalDecls.insert("declare double @rockit_math_cos(double)")
        externalDecls.insert("declare double @rockit_math_tan(double)")
        externalDecls.insert("declare double @rockit_math_pow(double, double)")
        externalDecls.insert("declare double @rockit_math_floor(double)")
        externalDecls.insert("declare double @rockit_math_ceil(double)")
        externalDecls.insert("declare double @rockit_math_round(double)")
        externalDecls.insert("declare double @rockit_math_log(double)")
        externalDecls.insert("declare double @rockit_math_exp(double)")
        externalDecls.insert("declare double @rockit_math_abs(double)")
        externalDecls.insert("declare double @rockit_math_atan2(double, double)")
        externalDecls.insert("declare ptr @formatFloat(double, i64)")
        externalDecls.insert("declare double @toFloat(i64)")
        externalDecls.insert("declare void @listSetFloat(ptr, i64, double)")
        externalDecls.insert("declare double @listGetFloat(ptr, i64)")
        // Networking
        externalDecls.insert("declare i64 @tcpConnect(ptr, i64)")
        externalDecls.insert("declare i64 @tcpSend(i64, ptr)")
        externalDecls.insert("declare ptr @tcpRecv(i64, i64)")
        externalDecls.insert("declare void @tcpClose(i64)")
        // TLS
        externalDecls.insert("declare i64 @tlsCreateContext()")
        externalDecls.insert("declare i64 @tlsCreateServerContext()")
        externalDecls.insert("declare i64 @tlsSetCertificate(i64, ptr)")
        externalDecls.insert("declare i64 @tlsSetPrivateKey(i64, ptr)")
        externalDecls.insert("declare void @tlsSetVerifyPeer(i64, i64)")
        externalDecls.insert("declare i64 @tlsSetAlpn(i64, ptr)")
        externalDecls.insert("declare i64 @tlsConnect(i64, ptr, i64)")
        externalDecls.insert("declare i64 @tlsSend(i64, ptr)")
        externalDecls.insert("declare ptr @tlsRecv(i64, i64)")
        externalDecls.insert("declare void @tlsClose(i64)")
        externalDecls.insert("declare ptr @tlsGetAlpn(i64)")
        externalDecls.insert("declare i64 @tlsGetPeerCert(i64)")
        externalDecls.insert("declare i64 @tlsListen(i64, i64)")
        externalDecls.insert("declare i64 @tlsAccept(i64, i64)")
        // Crypto
        externalDecls.insert("declare ptr @cryptoSha256(ptr)")
        externalDecls.insert("declare ptr @cryptoSha1(ptr)")
        externalDecls.insert("declare ptr @cryptoSha512(ptr)")
        externalDecls.insert("declare ptr @cryptoMd5(ptr)")
        externalDecls.insert("declare ptr @cryptoHmacSha256(ptr, ptr)")
        externalDecls.insert("declare ptr @cryptoHmacSha1(ptr, ptr)")
        externalDecls.insert("declare ptr @cryptoRandomBytes(i64)")
        externalDecls.insert("declare ptr @cryptoAesEncrypt(ptr, ptr, ptr, i64)")
        externalDecls.insert("declare ptr @cryptoAesDecrypt(ptr, ptr, ptr, i64)")
        // X.509
        externalDecls.insert("declare i64 @x509ParsePem(ptr)")
        externalDecls.insert("declare ptr @x509Subject(i64)")
        externalDecls.insert("declare ptr @x509Issuer(i64)")
        externalDecls.insert("declare i64 @x509NotBefore(i64)")
        externalDecls.insert("declare i64 @x509NotAfter(i64)")
        externalDecls.insert("declare ptr @x509SerialNumber(i64)")
        externalDecls.insert("declare void @x509Free(i64)")
        // TLS error
        externalDecls.insert("declare ptr @tlsLastError()")
        // Time
        externalDecls.insert("declare i64 @currentTimeMillis()")
        externalDecls.insert("declare void @sleepMillis(i64)")
        // Random
        externalDecls.insert("declare i64 @randomInt(i64)")
        // Date
        externalDecls.insert("declare i64 @epochToComponents(i64)")
    }

    /// Scan emitted IR for `call` instructions and auto-declare any functions
    /// that are not defined in the module and not already declared.
    private func autoDeclareMissingExternals(bodyText: String, definedFunctions: Set<String>,
                                              declaredNames: inout Set<String>, lines: inout [String]) {
        // Regex-like scan for: call <retType> @funcName(<args>)
        // We look for patterns: "call <type> @<name>(" and "call void @<name>("
        let scanner = bodyText as NSString
        let pattern = try! NSRegularExpression(pattern: #"call\s+(\w+)\s+@(\w+)\(([^)]*)\)"#)
        let matches = pattern.matches(in: bodyText, range: NSRange(location: 0, length: scanner.length))

        for match in matches {
            let retType = scanner.substring(with: match.range(at: 1))
            let funcName = scanner.substring(with: match.range(at: 2))
            let argsStr = scanner.substring(with: match.range(at: 3))

            // Skip if already defined or declared
            if definedFunctions.contains(funcName) { continue }
            if declaredNames.contains(funcName) { continue }

            // Parse parameter types from the call arguments
            var paramTypes: [String] = []
            if !argsStr.isEmpty {
                let args = argsStr.components(separatedBy: ",")
                for arg in args {
                    let trimmed = arg.trimmingCharacters(in: .whitespaces)
                    // Format is "type value" — extract the type
                    if let spaceIdx = trimmed.firstIndex(of: " ") {
                        let type = String(trimmed[trimmed.startIndex..<spaceIdx])
                        paramTypes.append(type)
                    }
                }
            }

            let params = paramTypes.joined(separator: ", ")
            let decl = "declare \(retType) @\(funcName)(\(params))"
            lines.append(decl)
            declaredNames.insert(funcName)
        }
    }

    // MARK: - Function Emission

    private func emitFunction(_ function: MIRFunction) -> String {
        // Reset per-function state
        ssaCounter = 0
        registerMap = [:]
        registerTypes = [:]
        currentParams = function.parameters
        paramMap = [:]

        // Reset per-function ARC and value type tracking
        ownedHeapTemps = []
        arcFlags = [:]
        knownIntTemps = []
        tempHeapKinds = [:]
        tempObjectTypes = [:]
        stackPromotedTemps = []
        stackOnlyTemps = []
        stackAllocaNames = [:]

        // Pre-pass: build temp → type name mapping for value type objects
        // 1. Track function parameters with known reference types
        for (name, type) in function.parameters {
            if case .reference(let typeName) = type, isValueType(typeName) {
                tempObjectTypes[name] = typeName
                tempObjectTypes["param.\(name)"] = typeName
            }
        }
        // 2. Track .newObject destinations and propagate through loads/stores
        for block in function.blocks {
            for inst in block.instructions {
                if case .newObject(let dest, let typeName, _) = inst {
                    tempObjectTypes[dest] = typeName
                }
                if case .load(let dest, let src) = inst, let tn = tempObjectTypes[src] {
                    tempObjectTypes[dest] = tn
                }
                if case .store(let dest, let src) = inst, let tn = tempObjectTypes[src] {
                    tempObjectTypes[dest] = tn
                }
            }
        }

        // Pre-pass: identify temps used as callIndirect function refs.
        // Trace backward through load/store chains so constString temps that
        // flow into callIndirect via intermediate copies are also included.
        indirectCallTargets = []
        for block in function.blocks {
            for inst in block.instructions {
                if case .callIndirect(_, let funcRef, _) = inst {
                    indirectCallTargets.insert(funcRef)
                }
            }
        }
        // Also mark args passed to callable parameter positions in other functions.
        for block in function.blocks {
            for inst in block.instructions {
                if case .call(_, let callee, let args) = inst,
                   let indices = callableParams[callee] {
                    for idx in indices where idx < args.count {
                        indirectCallTargets.insert(args[idx])
                    }
                }
            }
        }
        // Fixed-point: expand targets through load/store chains.
        // load(dest, src): if dest is target, add src
        // store(dest, src): if dest is target, add src
        var changed = true
        while changed {
            changed = false
            for block in function.blocks {
                for inst in block.instructions {
                    switch inst {
                    case .load(let dest, let src):
                        if indirectCallTargets.contains(dest) && !indirectCallTargets.contains(src) {
                            indirectCallTargets.insert(src)
                            changed = true
                        }
                    case .store(let dest, let src):
                        if indirectCallTargets.contains(dest) && !indirectCallTargets.contains(src) {
                            indirectCallTargets.insert(src)
                            changed = true
                        }
                    default:
                        break
                    }
                }
            }
        }

        // Pre-pass: escape analysis for stack promotion of value-type objects
        stackPromotedTemps = computeStackPromotedTemps(function)
        // Compute temps that only ever hold stack-promoted pointers (exclude from ARC)
        stackOnlyTemps = computeStackOnlyTemps(function)

        var lines: [String] = []

        // Detect if this is a method (name contains ".", e.g. "Point.sum")
        let isMethod = function.name.contains(".")
        let className: String? = function.name.contains(".") ? String(function.name.split(separator: ".").first!) : nil
        currentClassName = className

        // For the "main" function, use C ABI: i32 @main(i32 %argc, ptr %argv)
        let isMain = function.name == "main"
        isMainFunction = isMain

        // Infer actual return type (MIR may say .unit for methods that return values)
        let retType: String
        if isMain {
            retType = "i32"
        } else if function.returnType != .unit {
            retType = llvmType(function.returnType)
        } else {
            // Check if the function actually returns a value despite .unit declaration
            retType = inferActualReturnType(function)
        }

        currentReturnType = retType
        let funcName = llvmFunctionName(function.name)
        // Infer parameter types from usage (MIR lowering emits .unit for all params)
        let inferredParams = inferParamTypes(function)

        var paramList: [String] = []

        // Methods get an implicit `this` pointer as first parameter
        if isMethod {
            paramList.append("ptr %this")
        }

        for (name, type) in function.parameters {
            // Skip explicit 'this' in method parameters — already handled above
            if name == "this" && isMethod { continue }
            let lt: String
            let formal = llvmType(type)
            if formal != "void" {
                // Trust the formal MIR type when available
                lt = formal
            } else if let inferred = inferredParams[name] {
                lt = inferred
            } else {
                lt = "i64"
            }
            let paramLLVM = "%param.\(name)"
            paramMap[name] = paramLLVM
            paramList.append("\(lt) \(paramLLVM)")
        }
        let params: String
        if isMain {
            params = "i32 %argc, ptr %argv"
        } else {
            params = paramList.joined(separator: ", ")
        }

        let linkage = funcName == "main" ? "" : "internal "
        lines.append("define \(linkage)\(retType) @\(funcName)(\(params)) nounwind {")

        // Alloca prologue block: emit allocas for all temps
        let allTemps = collectTemps(function)
        let hasAllocas = !allTemps.isEmpty || !function.parameters.isEmpty || isMethod
        let firstBlockLabel = function.blocks.first.map { llvmLabel($0.label) } ?? "body"

        if hasAllocas {
            lines.append("prologue:")

            // Store `this` pointer so it's accessible like a local
            if isMethod {
                lines.append("  %p.this = alloca ptr")
                lines.append("  store ptr %this, ptr %p.this")
                registerMap["this"] = "%p.this"
                registerTypes["this"] = "ptr"
            }

            // Allocas for parameters (so we can store/load them like locals)
            for (name, type) in function.parameters {
                // Skip explicit 'this' — already handled above
                if name == "this" && isMethod { continue }
                let lt: String
                let formal = llvmType(type)
                if formal != "void" {
                    lt = formal
                } else if let inferred = inferredParams[name] {
                    lt = inferred
                } else {
                    lt = "i64"
                }
                let allocaName = "%p.\(name)"
                registerMap["param.\(name)"] = allocaName
                registerTypes["param.\(name)"] = lt
                lines.append("  \(allocaName) = alloca \(lt)")
                lines.append("  store \(lt) %param.\(name), ptr \(allocaName)")
            }
            // Allocas for MIR temps
            for (temp, type) in allTemps {
                let lt = type
                let rawName = temp.hasPrefix("%") ? String(temp.dropFirst()) : temp
                let allocaName = "%\(rawName)"
                registerMap[temp] = allocaName
                registerTypes[temp] = lt
                lines.append("  \(allocaName) = alloca \(lt)")
                // Null-init ptr allocas so ARC write barriers can safely read old values.
                if lt == "ptr" {
                    lines.append("  store ptr null, ptr \(allocaName)")
                }
            }
            // Stack-promoted value type allocas (in prologue so they're safe inside loops)
            for dest in stackPromotedTemps {
                if let typeName = tempObjectTypes[dest],
                   let decl = typeDecls[typeName] {
                    let fieldCount = decl.fields.count
                    let totalSize = 24 + fieldCount * 8
                    let rawName = dest.hasPrefix("%") ? String(dest.dropFirst()) : dest
                    let allocaName = "%\(rawName).stack"
                    lines.append("  \(allocaName) = alloca i8, i64 \(totalSize)")
                    stackAllocaNames[dest] = allocaName
                }
            }
            // ARC flag allocas: i1 flags for heap temp tracking.
            // Each flag is initialized to 0 (not allocated) and set to 1 at creation sites.
            // The actual heap temp allocas remain UNINITIALIZED to preserve LLVM optimization.
            let heapDests = collectHeapTempDests(function)
            for dest in heapDests {
                let rawName = dest.hasPrefix("%") ? String(dest.dropFirst()) : dest
                let flagName = "%\(rawName).arc"
                lines.append("  \(flagName) = alloca i1")
                lines.append("  store i1 0, ptr \(flagName)")
                arcFlags[dest] = flagName
            }
            // Initialize process args and module globals (main only)
            if isMain {
                lines.append("  call void @rockit_set_args(i32 %argc, ptr %argv)")
                // Initialize module-level globals (enum singletons, etc.)
                for (globalName, initFunc) in globalInitializers.sorted(by: { $0.key < $1.key }) {
                    let ty = moduleGlobals[globalName] ?? "ptr"
                    let funcName = llvmFunctionName(initFunc)
                    let tmp = nextSSA()
                    lines.append("  \(tmp) = call \(ty) @\(funcName)()")
                    lines.append("  store \(ty) \(tmp), ptr @\(globalName)")
                }
            }
            // Jump to first MIR block
            lines.append("  br label %\(firstBlockLabel)")
        }

        // Pre-scan for try/catch blocks to record exception destinations
        catchBlocks = [:]
        for block in function.blocks {
            for inst in block.instructions {
                if case .tryBegin(let catchLabel, let excDest) = inst {
                    catchBlocks[catchLabel] = excDest
                }
            }
        }

        // Emit basic blocks
        for block in function.blocks {
            lines.append("\(llvmLabel(block.label)):")

            // If this is a catch block, inject exception value retrieval
            // Note: rockit_exc_throw already popped the frame, so no pop here
            if let excDest = catchBlocks[block.label] {
                let excRaw = nextSSA()
                lines.append("  \(excRaw) = call i64 @rockit_exc_get()")
                // Convert i64 to the exception dest's type
                let excType = typeOf(excDest)
                if excType == "ptr" {
                    let castTmp = nextSSA()
                    lines.append("  \(castTmp) = inttoptr i64 \(excRaw) to ptr")
                    lines.append("  " + storeToTemp(excDest, value: castTmp, type: "ptr"))
                } else {
                    lines.append("  " + storeToTemp(excDest, value: excRaw, type: "i64"))
                }
            }

            // --- Flatten chains of string + into single concat_n ---
            // Pre-scan: find string add chains where intermediate results are
            // only used as the lhs of the next string add.
            var stringAddParts: [String: (lhs: String, rhs: String)] = [:]
            var useCount: [String: Int] = [:]
            for inst in block.instructions {
                if case .add(let dest, let lhs, let rhs, let type) = inst,
                   case .string = type {
                    stringAddParts[dest] = (lhs, rhs)
                }
                // Count operand uses
                for op in inst.operands {
                    useCount[op, default: 0] += 1
                }
            }
            // Also count operand uses in the terminator
            if let term = block.terminator {
                for op in term.operands {
                    useCount[op, default: 0] += 1
                }
            }
            // A string add dest is a chain intermediate if:
            // 1. It's produced by a string add
            // 2. It has exactly one use
            // 3. That use is as the lhs of another string add
            var chainIntermediate = Set<String>()
            for (_, pair) in stringAddParts {
                if stringAddParts[pair.lhs] != nil && useCount[pair.lhs] == 1 {
                    chainIntermediate.insert(pair.lhs)
                }
            }
            // Recursively flatten a chain's lhs into leaf parts
            func flattenChain(_ temp: String) -> [String] {
                if let pair = stringAddParts[temp], chainIntermediate.contains(temp) {
                    return flattenChain(pair.lhs) + [pair.rhs]
                }
                return [temp]
            }

            // --- Detect self-append: s = s + expr → use concat_consume ---
            // Pattern: load(lhsTemp, var), add(dest, lhsTemp, rhs, .string), store(var, dest)
            // Conditions: lhsTemp used only once (in the add), dest used only once (in the store)
            var loadSources: [String: String] = [:]  // temp → source variable
            var storeTargets: [String: String] = [:]  // src temp → dest variable
            for inst in block.instructions {
                if case .load(let dest, let src) = inst {
                    loadSources[dest] = src
                }
                if case .store(let dest, let src) = inst {
                    storeTargets[src] = dest
                }
            }
            var selfAppendVar: [String: String] = [:]  // add dest → variable name
            var selfAppendSkipLoad = Set<String>()  // load dests to skip
            var selfAppendSkipStore = Set<String>()  // store srcs to skip
            for inst in block.instructions {
                if case .add(let dest, let lhs, _, let type) = inst, case .string = type {
                    if let lhsSource = loadSources[lhs],
                       let storeDest = storeTargets[dest],
                       lhsSource == storeDest,
                       useCount[lhs, default: 0] == 1,
                       useCount[dest, default: 0] == 1,
                       !chainIntermediate.contains(dest) {
                        selfAppendVar[dest] = lhsSource
                        selfAppendSkipLoad.insert(lhs)
                        selfAppendSkipStore.insert(dest)
                    }
                }
            }

            for inst in block.instructions {
                // Skip loads that are part of self-append optimization
                if case .load(let dest, _) = inst, selfAppendSkipLoad.contains(dest) {
                    continue
                }
                // Skip stores that are part of self-append optimization
                if case .store(_, let src) = inst, selfAppendSkipStore.contains(src) {
                    continue
                }
                // Self-append: emit consume variant
                if case .add(let dest, _, let rhs, let type) = inst,
                   case .string = type,
                   let targetVar = selfAppendVar[dest] {
                    let emitted = emitStringConcatConsume(dest: dest, rhs: rhs, targetVar: targetVar)
                    for line in emitted {
                        lines.append("  \(line)")
                    }
                    continue
                }
                // Skip emitting chain intermediate string adds — they'll be
                // folded into the root chain's concat_n call
                if case .add(let dest, _, _, let type) = inst,
                   case .string = type,
                   chainIntermediate.contains(dest) {
                    continue
                }
                // For chain root string adds, emit with flattened parts
                if case .add(let dest, let lhs, let rhs, let type) = inst,
                   case .string = type,
                   stringAddParts[lhs] != nil,
                   chainIntermediate.contains(lhs) {
                    let parts = flattenChain(lhs) + [rhs]
                    let emitted = emitStringConcat(dest: dest, parts: parts)
                    for line in emitted {
                        lines.append("  \(line)")
                    }
                    continue
                }
                let emitted = emitInstruction(inst)
                for line in emitted {
                    lines.append("  \(line)")
                }
            }
            if let term = block.terminator {
                let emitted = emitTerminator(term, returnType: function.returnType)
                for line in emitted {
                    lines.append("  \(line)")
                }
            }
        }

        lines.append("}")
        return lines.joined(separator: "\n")
    }

    // MARK: - Return Type Inference

    /// Infer actual return type for functions that declare `.unit` but return a value.
    /// MIR lowering in Stage 0 sometimes emits `.unit` for methods that return values.
    private func inferActualReturnType(_ function: MIRFunction) -> String {
        // Look at ret terminators — if any return a value, infer the type
        for block in function.blocks {
            if case .ret(let val) = block.terminator, let val = val {
                // The ret value is a temp — figure out its type from the instructions
                for b in function.blocks {
                    for inst in b.instructions {
                        switch inst {
                        case .add(let d, _, _, let t) where d == val:
                            if case .string = t { return "ptr" }
                            return llvmArithType(t)
                        case .sub(let d, _, _, let t) where d == val,
                             .mul(let d, _, _, let t) where d == val,
                             .div(let d, _, _, let t) where d == val,
                             .mod(let d, _, _, let t) where d == val:
                            return llvmArithType(t)
                        case .neg(let d, _, let t) where d == val:
                            return llvmArithType(t)
                        case .eq(let d, _, _, _) where d == val,
                             .neq(let d, _, _, _) where d == val,
                             .lt(let d, _, _, _) where d == val,
                             .lte(let d, _, _, _) where d == val,
                             .gt(let d, _, _, _) where d == val,
                             .gte(let d, _, _, _) where d == val,
                             .and(let d, _, _) where d == val,
                             .or(let d, _, _) where d == val,
                             .not(let d, _) where d == val:
                            return "i1"
                        case .constInt(let d, _) where d == val:
                            return "i64"
                        case .constFloat(let d, _) where d == val:
                            return "double"
                        case .constBool(let d, _) where d == val:
                            return "i1"
                        case .constString(let d, _) where d == val,
                             .constNull(let d) where d == val,
                             .stringConcat(let d, _) where d == val,
                             .newObject(let d, _, _) where d == val:
                            return "ptr"
                        case .getField(let d, _, _) where d == val:
                            return "i64"  // Default; could look up field type
                        case .call(let d, let fn, _) where d == val:
                            return inferCallReturnType(fn)
                        default:
                            break
                        }
                    }
                }
                // If the ret value comes from a load, trace it
                return "i64"  // Default for methods returning values
            }
        }
        return "void"
    }

    // MARK: - Parameter Type Inference

    /// Infer actual parameter types by analyzing how they're used in the function body.
    /// MIR lowering in Stage 0 emits all params as `.unit`, so we need this.
    private func inferParamTypes(_ function: MIRFunction) -> [String: String] {
        var inferred: [String: String] = [:]
        let originMap = buildParamOriginMap(function)

        for block in function.blocks {
            for inst in block.instructions {
                switch inst {
                // If a param-loaded value feeds into arithmetic, infer its type
                case .add(_, let l, let r, let t), .sub(_, let l, let r, let t),
                     .mul(_, let l, let r, let t), .div(_, let l, let r, let t),
                     .mod(_, let l, let r, let t):
                    // For string +, MIR uses .string type on the add instruction
                    let lt: String
                    switch t {
                    case .string: lt = "ptr"
                    default: lt = llvmArithType(t)
                    }
                    inferParamFromOperand(l, type: lt, originMap: originMap, inferred: &inferred)
                    inferParamFromOperand(r, type: lt, originMap: originMap, inferred: &inferred)
                case .neg(_, let o, let t):
                    inferParamFromOperand(o, type: llvmArithType(t), originMap: originMap, inferred: &inferred)
                case .eq(_, let l, let r, let t), .neq(_, let l, let r, let t),
                     .lt(_, let l, let r, let t), .lte(_, let l, let r, let t),
                     .gt(_, let l, let r, let t), .gte(_, let l, let r, let t):
                    let lt: String
                    switch t {
                    case .string, .reference, .nullable: lt = "ptr"
                    default: lt = llvmArithType(t)
                    }
                    inferParamFromOperand(l, type: lt, originMap: originMap, inferred: &inferred)
                    inferParamFromOperand(r, type: lt, originMap: originMap, inferred: &inferred)
                case .stringConcat(_, let parts):
                    for part in parts {
                        inferParamFromOperand(part, type: "ptr", originMap: originMap, inferred: &inferred)
                    }
                // Object operations → operand must be ptr
                case .getField(_, let obj, _):
                    inferParamFromOperand(obj, type: "ptr", originMap: originMap, inferred: &inferred)
                case .setField(let obj, _, let val):
                    inferParamFromOperand(obj, type: "ptr", originMap: originMap, inferred: &inferred)
                    _ = val
                case .virtualCall(_, let obj, _, _):
                    inferParamFromOperand(obj, type: "ptr", originMap: originMap, inferred: &inferred)
                case .nullCheck(_, let operand):
                    inferParamFromOperand(operand, type: "ptr", originMap: originMap, inferred: &inferred)
                case .isNull(_, let operand):
                    inferParamFromOperand(operand, type: "ptr", originMap: originMap, inferred: &inferred)
                case .call(_, _, _):
                    break
                default:
                    break
                }
            }
        }

        // If return type is known and a param feeds into a return, infer from return type
        let retType = llvmType(function.returnType)
        if retType != "void" {
            for block in function.blocks {
                if case .ret(let val) = block.terminator, let val = val {
                    inferParamFromOperand(val, type: retType, originMap: originMap, inferred: &inferred)
                }
            }
        }

        return inferred
    }

    /// Build a reverse map: for each temp, what param (if any) does its value come from?
    /// Traces through load/store chains.
    private func buildParamOriginMap(_ function: MIRFunction) -> [String: String] {
        // Map from temp → param name it originates from
        var origin: [String: String] = [:]

        // First, find direct param loads
        for block in function.blocks {
            for inst in block.instructions {
                if case .load(let dest, let src) = inst, src.hasPrefix("param.") {
                    let paramName = String(src.dropFirst(6))
                    origin[dest] = paramName
                }
            }
        }

        // Propagate through store/load chains
        // store SLOT, SRC → if SRC has origin, SLOT gets same origin
        // load DEST, SLOT → if SLOT has origin, DEST gets same origin
        var changed = true
        while changed {
            changed = false
            for block in function.blocks {
                for inst in block.instructions {
                    switch inst {
                    case .store(let dest, let src):
                        if let paramName = origin[src], origin[dest] == nil {
                            origin[dest] = paramName
                            changed = true
                        }
                    case .load(let dest, let src):
                        if !src.hasPrefix("param."), let paramName = origin[src], origin[dest] == nil {
                            origin[dest] = paramName
                            changed = true
                        }
                    default:
                        break
                    }
                }
            }
        }

        return origin
    }

    /// Given an operand temp, trace back through loads/stores to find if it originates
    /// from a parameter, and if so, infer that parameter's type.
    private func inferParamFromOperand(_ operand: String, type: String, originMap: [String: String], inferred: inout [String: String]) {
        if let paramName = originMap[operand] {
            // Don't override a more specific type
            if inferred[paramName] == nil {
                inferred[paramName] = type
            }
        }
    }

    // MARK: - Temp Collection

    /// Collect all temps and infer their LLVM types from usage context.
    /// Two-pass: first infer direct types, then propagate through store/load chains.
    private func collectTemps(_ function: MIRFunction) -> [(String, String)] {
        var tempTypes: [String: String] = [:]
        // Track store relationships: dest ← src
        var storeEdges: [(dest: String, src: String)] = []
        // Inferred parameter types
        let inferredParams = inferParamTypes(function)

        // Pass 1: Direct type inference
        for block in function.blocks {
            for inst in block.instructions {
                switch inst {
                case .constInt(let d, _):
                    tempTypes[d] = "i64"
                    knownIntTemps.insert(d)
                case .constFloat(let d, _):
                    tempTypes[d] = "double"
                case .constBool(let d, _):
                    tempTypes[d] = "i1"
                case .constString(let d, _):
                    tempTypes[d] = "ptr"
                case .constNull(let d):
                    tempTypes[d] = "ptr"
                case .alloc(let d, let type):
                    let lt = llvmType(type)
                    // For void (Unit) allocas, leave unresolved so pass 2 can infer
                    // the actual type from store/load chains. Will default to i64 at end.
                    if lt != "void" {
                        tempTypes[d] = lt
                    }
                case .load(let d, let src):
                    // Inherit type from source
                    if src == "this" || src == "super" {
                        tempTypes[d] = "ptr"
                    } else if src.hasPrefix("global."), function.name.contains(".") {
                        // Method field access: global.x → field type
                        let fieldName = String(src.dropFirst(7))
                        let className = String(function.name.split(separator: ".").first!)
                        tempTypes[d] = fieldType(typeName: className, fieldName: fieldName)
                    } else if let globalType = moduleGlobals[src] {
                        // Module-level global (enum singleton, top-level var)
                        tempTypes[d] = globalType
                    } else if src.hasPrefix("param.") {
                        let paramName = String(src.dropFirst(6))
                        // Use formal type first, then inferred, then default
                        if let pt = function.parameters.first(where: { $0.0 == paramName }) {
                            let lt = llvmType(pt.1)
                            if lt != "void" {
                                tempTypes[d] = lt
                            } else if let inferred = inferredParams[paramName] {
                                tempTypes[d] = inferred
                            } else {
                                tempTypes[d] = "i64"
                            }
                        } else if let inferred = inferredParams[paramName] {
                            tempTypes[d] = inferred
                        } else {
                            tempTypes[d] = "i64"
                        }
                    } else if let srcType = tempTypes[src] {
                        if srcType != "void" {
                            tempTypes[d] = srcType
                        }
                    }
                    // Also record as an edge for pass 2
                    storeEdges.append((dest: d, src: src))
                case .store(let dest, let src):
                    storeEdges.append((dest: dest, src: src))
                case .add(let d, _, _, let t), .sub(let d, _, _, let t),
                     .mul(let d, _, _, let t), .div(let d, _, _, let t),
                     .mod(let d, _, _, let t):
                    if case .string = t {
                        tempTypes[d] = "ptr"  // String add → string concat
                    } else {
                        tempTypes[d] = llvmArithType(t)
                        if case .int = t { knownIntTemps.insert(d) }
                    }
                case .neg(let d, _, let t):
                    tempTypes[d] = llvmArithType(t)
                    if case .int = t { knownIntTemps.insert(d) }
                case .eq(let d, _, _, _), .neq(let d, _, _, _),
                     .lt(let d, _, _, _), .lte(let d, _, _, _),
                     .gt(let d, _, _, _), .gte(let d, _, _, _):
                    tempTypes[d] = "i1"
                case .and(let d, _, _), .or(let d, _, _), .not(let d, _):
                    tempTypes[d] = "i1"
                case .call(let d, let function, _):
                    if let d = d {
                        tempTypes[d] = inferCallReturnType(function)
                        // listGet returns integer values from list storage
                        if function == "listGet" { knownIntTemps.insert(d) }
                    }
                case .callIndirect(let d, _, _):
                    if let d = d { tempTypes[d] = "i64" }
                case .virtualCall(let d, _, let method, _):
                    if let d = d {
                        let qualifiedMethod = resolveMethodName(method)
                        if let sig = functionSignatures[qualifiedMethod] {
                            let lt = llvmType(sig)
                            tempTypes[d] = lt != "void" ? lt : "i64"
                        } else {
                            tempTypes[d] = "i64"
                        }
                    }
                case .getField(let d, let obj, let fieldName):
                    // Try to infer field type from the object's type declaration
                    var resolved = false
                    var fieldMIRType: MIRType? = nil
                    // First, try to determine the object's type from its temp type
                    if let objType = tempTypes[obj], objType == "ptr" {
                        // If the object is a method (Name.method), use the class name
                        let objClassName: String?
                        if obj.hasPrefix("param.this") || obj == "this" {
                            objClassName = function.name.contains(".") ?
                                String(function.name.split(separator: ".").first!) : nil
                        } else {
                            // Check if obj was created by newObject
                            objClassName = nil
                        }
                        if let cn = objClassName, let decl = typeDecls[cn],
                           let field = decl.fields.first(where: { $0.0 == fieldName }) {
                            let lt = llvmType(field.1)
                            tempTypes[d] = lt != "void" ? lt : "i64"
                            fieldMIRType = field.1
                            resolved = true
                        }
                    }
                    // Fallback: search all type declarations
                    if !resolved {
                        for (_, decl) in typeDecls {
                            if let field = decl.fields.first(where: { $0.0 == fieldName }) {
                                let lt = llvmType(field.1)
                                tempTypes[d] = lt != "void" ? lt : "i64"
                                fieldMIRType = field.1
                                resolved = true
                                break
                            }
                        }
                    }
                    if !resolved { tempTypes[d] = "i64" }
                    // Track int fields so println can use _int instead of _any
                    if let ft = fieldMIRType, case .int = ft { knownIntTemps.insert(d) }
                case .setField:
                    break
                case .newObject(let d, _, _):
                    tempTypes[d] = "ptr"
                case .nullCheck(let d, _):
                    tempTypes[d] = "ptr"
                case .isNull(let d, _):
                    tempTypes[d] = "i1"
                case .typeCheck(let d, _, _):
                    tempTypes[d] = "i1"
                case .typeCast(let d, _, _):
                    tempTypes[d] = "ptr"
                case .stringConcat(let d, _):
                    tempTypes[d] = "ptr"
                case .tryBegin(_, let d):
                    tempTypes[d] = "ptr"
                case .tryEnd:
                    break
                case .awaitCall(let d, _, _):
                    if let d = d { tempTypes[d] = "i64" }
                case .concurrentBegin, .concurrentEnd:
                    break
                }
            }
        }

        // Pass 2: Propagate types through store/load edges
        // If `store %t0, %t1` and %t1 has no type, inherit from %t0.
        var changed = true
        while changed {
            changed = false
            for edge in storeEdges {
                if let srcType = tempTypes[edge.src], srcType != "void" {
                    if tempTypes[edge.dest] == nil || tempTypes[edge.dest] == "void" {
                        tempTypes[edge.dest] = srcType
                        changed = true
                    }
                }
                if let destType = tempTypes[edge.dest], destType != "void" {
                    if tempTypes[edge.src] == nil || tempTypes[edge.src] == "void" {
                        tempTypes[edge.src] = destType
                        changed = true
                    }
                }
            }
        }

        // Default any remaining untyped temps to i64
        for (key, value) in tempTypes {
            if value == "void" {
                tempTypes[key] = "i64"
            }
        }

        // Ensure all alloc temps have entries (void allocas left nil by pass 1)
        for block in function.blocks {
            for inst in block.instructions {
                if case .alloc(let d, _) = inst, tempTypes[d] == nil {
                    tempTypes[d] = "i64"
                }
            }
        }

        // Pass 3: Re-propagate after alloc defaults are filled in.
        // Temps created by .load from void-typed allocs (e.g., if-expression
        // resultSlots) missed pass 2 because their source had no type yet.
        changed = true
        while changed {
            changed = false
            for edge in storeEdges {
                if let srcType = tempTypes[edge.src], srcType != "void" {
                    if tempTypes[edge.dest] == nil || tempTypes[edge.dest] == "void" {
                        tempTypes[edge.dest] = srcType
                        changed = true
                    }
                }
                if let destType = tempTypes[edge.dest], destType != "void" {
                    if tempTypes[edge.src] == nil || tempTypes[edge.src] == "void" {
                        tempTypes[edge.src] = destType
                        changed = true
                    }
                }
            }
        }

        // Pass 4: Propagate knownIntTemps through store edges
        changed = true
        while changed {
            changed = false
            for edge in storeEdges {
                if knownIntTemps.contains(edge.src) && !knownIntTemps.contains(edge.dest) {
                    knownIntTemps.insert(edge.dest)
                    changed = true
                }
            }
        }

        // Filter out parameter names and special names (they get separate allocas in the prologue)
        let paramNames = Set(function.parameters.map { "param.\($0.0)" })
        let specialNames: Set<String> = ["this", "super"]

        // Return sorted for deterministic output, excluding param/special/module-global entries
        return tempTypes
            .filter { !paramNames.contains($0.key) && !specialNames.contains($0.key) && moduleGlobals[$0.key] == nil }
            .sorted(by: { $0.key < $1.key })
    }

    // MARK: - Instruction Emission

    private func emitInstruction(_ inst: MIRInstruction) -> [String] {
        switch inst {
        case .constInt(let dest, let value):
            return [storeToTemp(dest, value: "\(value)", type: "i64")]

        case .constFloat(let dest, let value):
            let hexBits = String(value.bitPattern, radix: 16, uppercase: true)
            let llvmHex = "0x\(hexBits)"
            return [storeToTemp(dest, value: llvmHex, type: "double")]

        case .constBool(let dest, let value):
            return [storeToTemp(dest, value: value ? "1" : "0", type: "i1")]

        case .constString(let dest, let value):
            // Lambda/function references: convert to function pointer when this temp
            // flows into a callIndirect target (directly or through load/store/call chains).
            if moduleFunctionNames.contains(value) && indirectCallTargets.contains(dest) {
                let funcName = llvmFunctionName(value)
                return [storeToTemp(dest, value: "@\(funcName)", type: "ptr")]
            }
            // Use immortal RockitString global — no malloc, no free needed.
            // The global has refCount = INT64_MAX, so retain/release are no-ops.
            let rstrName = rockitStringGlobals[value]!
            trackHeapTemp(dest, kind: .string)
            var result = emitOldTempRelease(dest: dest, kind: .string)
            result.append(storeToTemp(dest, value: rstrName, type: "ptr"))
            if let flag = arcFlags[dest] { result.append("store i1 1, ptr \(flag)") }
            return result

        case .constNull(let dest):
            // Use ROCKIT_NULL sentinel (0xCAFEBABE) instead of null pointer.
            // This ensures null is distinguishable from integer 0 in untagged i64 representation.
            let destType = typeOf(dest)
            if destType == "ptr" {
                let tmp = nextSSA()
                return [
                    "\(tmp) = inttoptr i64 3405691582 to ptr",
                    storeToTemp(dest, value: tmp, type: "ptr")
                ]
            } else {
                return [storeToTemp(dest, value: "3405691582", type: "i64")]
            }

        case .alloc:
            // Allocas are emitted in the entry block; nothing to do here
            return []

        case .store(let dest, let src):
            let srcType = typeOf(src)
            let tmp = nextSSA()

            // ARC write barrier for global stores of heap types
            if dest.hasPrefix("global."), srcType == "ptr" {
                let kind = tempHeapKinds[src] ?? .unknown
                let oldTmp = nextSSA()
                var result: [String] = []
                // Load old value
                result.append("\(oldTmp) = load ptr, ptr \(addrOf(dest))")
                // Release old value (type-specific when known)
                switch kind {
                case .string:
                    result.append(contentsOf: emitInlineStringRelease(oldTmp))
                case .object:
                    result.append("call void @rockit_release(ptr \(oldTmp))")
                default:
                    let oldI64 = nextSSA()
                    result.append("\(oldI64) = ptrtoint ptr \(oldTmp) to i64")
                    result.append("call void @rockit_release_value(i64 \(oldI64))")
                }
                // Load and retain new value
                result.append("\(tmp) = load ptr, ptr \(addrOf(src))")
                switch kind {
                case .string:
                    result.append(contentsOf: emitInlineStringRetain(tmp))
                case .object:
                    result.append("call void @rockit_retain(ptr \(tmp))")
                default:
                    let newI64 = nextSSA()
                    result.append("\(newI64) = ptrtoint ptr \(tmp) to i64")
                    result.append("call void @rockit_retain_value(i64 \(newI64))")
                }
                // Store new value
                result.append("store ptr \(tmp), ptr \(addrOf(dest))")
                trackHeapTemp(dest, kind: kind)
                return result
            }

            if srcType == "ptr", let flagName = arcFlags[dest], arcFlags[src] != nil {
                // ARC write barrier: release old value, retain new, store.
                // Prevents leaks when ptr-typed locals are reassigned in loops.
                // Only when source is also ARC-tracked (heap allocation).
                // Use source's HeapKind for type-specific release (avoids rockit_release_value
                // which can crash on short strings due to OOB offset-24 read).
                let kind = tempHeapKinds[src] ?? .unknown
                var result = emitOldTempRelease(dest: dest, kind: kind)
                result.append("\(tmp) = load ptr, ptr \(addrOf(src))")
                // Use inline retain when kind is known (avoids function call overhead)
                switch kind {
                case .string:
                    result.append(contentsOf: emitInlineStringRetain(tmp))
                case .object:
                    result.append("call void @rockit_retain(ptr \(tmp))")
                default:
                    let tmpI64 = nextSSA()
                    result.append("\(tmpI64) = ptrtoint ptr \(tmp) to i64")
                    result.append("call void @rockit_retain_value(i64 \(tmpI64))")
                }
                result.append("store ptr \(tmp), ptr \(addrOf(dest))")
                result.append("store i1 1, ptr \(flagName)")
                trackHeapTemp(dest, kind: kind)
                return result
            }
            // Propagate type and knownInt info through copies
            if registerTypes[src] != nil {
                registerTypes[dest] = registerTypes[src]
            }
            if knownIntTemps.contains(src) {
                knownIntTemps.insert(dest)
            }
            return [
                "\(tmp) = load \(srcType), ptr \(addrOf(src))",
                "store \(srcType) \(tmp), ptr \(addrOf(dest))"
            ]

        case .load(let dest, let src):
            // In methods, `load global.X` means field access on `this`
            if src.hasPrefix("global."), currentClassName != nil {
                let fieldName = String(src.dropFirst(7))  // "global.x" → "x"
                return emitGetField(dest: dest, object: "this", fieldName: fieldName)
            } else if src.hasPrefix("param.") || src.hasPrefix("global.") || src == "this" || src == "super" {
                let srcType = typeOf(src)
                let tmp = nextSSA()
                // Propagate type info from param/global to dest
                if registerTypes[src] != nil {
                    registerTypes[dest] = registerTypes[src]
                }
                if knownIntTemps.contains(src) {
                    knownIntTemps.insert(dest)
                }
                // ARC write barrier on load from global: retain the loaded value
                // and release the dest temp's old value (if any). This ensures the
                // value survives if the global is overwritten, and handles loops
                // where the dest temp is reused (each iteration releases the old).
                if src.hasPrefix("global."), srcType == "ptr" {
                    let kind = tempHeapKinds[src] ?? .unknown
                    var result = emitOldTempRelease(dest: dest, kind: kind)
                    result.append("\(tmp) = load \(srcType), ptr \(addrOf(src))")
                    switch kind {
                    case .string:
                        result.append(contentsOf: emitInlineStringRetain(tmp))
                    case .object:
                        result.append("call void @rockit_retain(ptr \(tmp))")
                    default:
                        let tmpI64 = nextSSA()
                        result.append("\(tmpI64) = ptrtoint ptr \(tmp) to i64")
                        result.append("call void @rockit_retain_value(i64 \(tmpI64))")
                    }
                    result.append("store \(srcType) \(tmp), ptr \(addrOf(dest))")
                    if let flag = arcFlags[dest] {
                        result.append("store i1 1, ptr \(flag)")
                    }
                    trackHeapTemp(dest, kind: kind)
                    return result
                }
                return [
                    "\(tmp) = load \(srcType), ptr \(addrOf(src))",
                    "store \(srcType) \(tmp), ptr \(addrOf(dest))"
                ]
            } else {
                let srcType = typeOf(src)
                let tmp = nextSSA()
                // Propagate type and knownInt info through load copies
                if registerTypes[src] != nil {
                    registerTypes[dest] = registerTypes[src]
                }
                if knownIntTemps.contains(src) {
                    knownIntTemps.insert(dest)
                }
                return [
                    "\(tmp) = load \(srcType), ptr \(addrOf(src))",
                    "store \(srcType) \(tmp), ptr \(addrOf(dest))"
                ]
            }

        case .add(let dest, let lhs, let rhs, let type):
            // String + is lowered as MIR add with .string type — emit concat instead
            if case .string = type {
                return emitStringConcat(dest: dest, parts: [lhs, rhs])
            }
            return emitBinaryArith("add", "fadd", dest: dest, lhs: lhs, rhs: rhs, type: type)

        case .sub(let dest, let lhs, let rhs, let type):
            return emitBinaryArith("sub", "fsub", dest: dest, lhs: lhs, rhs: rhs, type: type)

        case .mul(let dest, let lhs, let rhs, let type):
            return emitBinaryArith("mul", "fmul", dest: dest, lhs: lhs, rhs: rhs, type: type)

        case .div(let dest, let lhs, let rhs, let type):
            return emitBinaryArith("sdiv", "fdiv", dest: dest, lhs: lhs, rhs: rhs, type: type)

        case .mod(let dest, let lhs, let rhs, let type):
            return emitBinaryArith("srem", "frem", dest: dest, lhs: lhs, rhs: rhs, type: type)

        case .neg(let dest, let operand, let type):
            let lt = llvmArithType(type)
            let tmp1 = nextSSA()
            let tmp2 = nextSSA()
            if isFloatType(type) {
                return [
                    "\(tmp1) = load \(lt), ptr \(addrOf(operand))",
                    "\(tmp2) = fneg \(lt) \(tmp1)",
                    storeToTemp(dest, value: tmp2, type: lt)
                ]
            } else {
                return [
                    "\(tmp1) = load \(lt), ptr \(addrOf(operand))",
                    "\(tmp2) = sub \(lt) 0, \(tmp1)",
                    storeToTemp(dest, value: tmp2, type: lt)
                ]
            }

        case .eq(let dest, let lhs, let rhs, let type):
            return emitComparison("icmp eq", "fcmp oeq", dest: dest, lhs: lhs, rhs: rhs, type: type)
        case .neq(let dest, let lhs, let rhs, let type):
            return emitComparison("icmp ne", "fcmp one", dest: dest, lhs: lhs, rhs: rhs, type: type)
        case .lt(let dest, let lhs, let rhs, let type):
            return emitComparison("icmp slt", "fcmp olt", dest: dest, lhs: lhs, rhs: rhs, type: type)
        case .lte(let dest, let lhs, let rhs, let type):
            return emitComparison("icmp sle", "fcmp ole", dest: dest, lhs: lhs, rhs: rhs, type: type)
        case .gt(let dest, let lhs, let rhs, let type):
            return emitComparison("icmp sgt", "fcmp ogt", dest: dest, lhs: lhs, rhs: rhs, type: type)
        case .gte(let dest, let lhs, let rhs, let type):
            return emitComparison("icmp sge", "fcmp oge", dest: dest, lhs: lhs, rhs: rhs, type: type)

        case .and(let dest, let lhs, let rhs):
            let tmp1 = nextSSA()
            let tmp2 = nextSSA()
            let tmp3 = nextSSA()
            return [
                "\(tmp1) = load i1, ptr \(addrOf(lhs))",
                "\(tmp2) = load i1, ptr \(addrOf(rhs))",
                "\(tmp3) = and i1 \(tmp1), \(tmp2)",
                storeToTemp(dest, value: tmp3, type: "i1")
            ]

        case .or(let dest, let lhs, let rhs):
            let tmp1 = nextSSA()
            let tmp2 = nextSSA()
            let tmp3 = nextSSA()
            return [
                "\(tmp1) = load i1, ptr \(addrOf(lhs))",
                "\(tmp2) = load i1, ptr \(addrOf(rhs))",
                "\(tmp3) = or i1 \(tmp1), \(tmp2)",
                storeToTemp(dest, value: tmp3, type: "i1")
            ]

        case .not(let dest, let operand):
            let tmp1 = nextSSA()
            let tmp2 = nextSSA()
            return [
                "\(tmp1) = load i1, ptr \(addrOf(operand))",
                "\(tmp2) = xor i1 \(tmp1), 1",
                storeToTemp(dest, value: tmp2, type: "i1")
            ]

        case .call(let dest, let function, let args):
            return emitCall(dest: dest, function: function, args: args)

        case .virtualCall(let dest, let object, let method, let args):
            // For now, static dispatch: call @TypeName.methodName(obj, args...)
            return emitVirtualCall(dest: dest, object: object, method: method, args: args)

        case .callIndirect(let dest, let functionRef, let args):
            // Load function pointer and call
            let ptrTmp = nextSSA()
            var lines: [String] = [
                "\(ptrTmp) = load ptr, ptr \(addrOf(functionRef))"
            ]
            var argStrs: [String] = []
            for arg in args {
                let argType = typeOf(arg)
                let tmp = nextSSA()
                lines.append("\(tmp) = load \(argType), ptr \(addrOf(arg))")
                argStrs.append("\(argType) \(tmp)")
            }
            let argList = argStrs.joined(separator: ", ")
            if let dest = dest {
                let retType = typeOf(dest)
                let resultTmp = nextSSA()
                lines.append("\(resultTmp) = call \(retType) \(ptrTmp)(\(argList))")
                lines.append(storeToTemp(dest, value: resultTmp, type: retType))
            } else {
                lines.append("call void \(ptrTmp)(\(argList))")
            }
            return lines

        case .getField(let dest, let object, let fieldName):
            return emitGetField(dest: dest, object: object, fieldName: fieldName)

        case .setField(let object, let fieldName, let value):
            return emitSetField(object: object, fieldName: fieldName, value: value)

        case .newObject(let dest, let typeName, let args):
            return emitNewObject(dest: dest, typeName: typeName, args: args)

        case .nullCheck(let dest, let operand):
            // Compare against ROCKIT_NULL sentinel (0xCAFEBABE) instead of null pointer
            let tmp1 = nextSSA()
            let sentinel = nextSSA()
            let tmp2 = nextSSA()
            let labelOk = "nullcheck.ok.\(ssaCounter)"
            let labelFail = "nullcheck.fail.\(ssaCounter)"
            ssaCounter += 1
            return [
                "\(tmp1) = load ptr, ptr \(addrOf(operand))",
                "\(sentinel) = inttoptr i64 3405691582 to ptr",
                "\(tmp2) = icmp eq ptr \(tmp1), \(sentinel)",
                "br i1 \(tmp2), label %\(labelFail), label %\(labelOk)",
                "",
                "\(labelFail):",
                "  call void @rockit_panic(ptr \(stringPool["NullPointerException"]!))",
                "  unreachable",
                "",
                "\(labelOk):",
                storeToTemp(dest, value: tmp1, type: "ptr")
            ]

        case .isNull(let dest, let operand):
            // Compare against ROCKIT_NULL sentinel (0xCAFEBABE) instead of null pointer
            let opType = typeOf(operand)
            let tmp1 = nextSSA()
            let tmp2 = nextSSA()
            if opType == "ptr" {
                let sentinel = nextSSA()
                return [
                    "\(tmp1) = load ptr, ptr \(addrOf(operand))",
                    "\(sentinel) = inttoptr i64 3405691582 to ptr",
                    "\(tmp2) = icmp eq ptr \(tmp1), \(sentinel)",
                    storeToTemp(dest, value: tmp2, type: "i1")
                ]
            } else {
                return [
                    "\(tmp1) = load i64, ptr \(addrOf(operand))",
                    "\(tmp2) = icmp eq i64 \(tmp1), 3405691582",
                    storeToTemp(dest, value: tmp2, type: "i1")
                ]
            }

        case .typeCheck(let dest, let operand, let typeName):
            // Runtime type check: call rockit_is_type(obj, targetTypeName)
            let typeNameGlobal = internTypeName(typeName)
            let objTmp = nextSSA()
            let resultTmp = nextSSA()
            let boolTmp = nextSSA()
            return [
                "\(objTmp) = load ptr, ptr \(addrOf(operand))",
                "\(resultTmp) = call i8 @rockit_is_type(ptr \(objTmp), ptr \(typeNameGlobal))",
                "\(boolTmp) = trunc i8 \(resultTmp) to i1",
                storeToTemp(dest, value: boolTmp, type: "i1")
            ]

        case .typeCast(let dest, let operand, let typeName):
            // Runtime type cast: check type, panic on failure, passthrough on success
            let typeNameGlobal = internTypeName(typeName)
            let objTmp = nextSSA()
            let resultTmp = nextSSA()
            let checkTmp = nextSSA()
            let okLabel = "cast.ok.\(nextLabelCounter())"
            let failLabel = "cast.fail.\(nextLabelCounter())"
            let panicMsg = "ClassCastException: cannot cast to \(typeName)"
            let panicGlobal = internString(panicMsg)
            return [
                "\(objTmp) = load ptr, ptr \(addrOf(operand))",
                "\(resultTmp) = call i8 @rockit_is_type(ptr \(objTmp), ptr \(typeNameGlobal))",
                "\(checkTmp) = trunc i8 \(resultTmp) to i1",
                "br i1 \(checkTmp), label %\(okLabel), label %\(failLabel)",
                "\(failLabel):",
                "call void @rockit_panic(ptr \(panicGlobal))",
                "unreachable",
                "\(okLabel):",
                storeToTemp(dest, value: objTmp, type: "ptr")
            ]

        case .stringConcat(let dest, let parts):
            return emitStringConcat(dest: dest, parts: parts)

        case .tryBegin(let catchLabel, _):
            // Push exception frame, call _setjmp, branch on result
            let bufTmp = nextSSA()
            let jmpRet = nextSSA()
            let caught = nextSSA()
            let tryBodyLabel = "try.body.\(ssaCounter)"
            ssaCounter += 1
            return [
                "\(bufTmp) = call ptr @rockit_exc_push()",
                Platform.setjmpCall(result: jmpRet, bufPtr: bufTmp),
                "\(caught) = icmp ne i32 \(jmpRet), 0",
                "br i1 \(caught), label %\(llvmLabel(catchLabel)), label %\(tryBodyLabel)",
                "",
                "\(tryBodyLabel):"
            ]
        case .tryEnd:
            return ["call void @rockit_exc_pop()"]

        case .awaitCall(let dest, let function, let args):
            // In native codegen, awaitCall is a synchronous call (Stage 0)
            return emitCall(dest: dest, function: function, args: args)

        case .concurrentBegin, .concurrentEnd:
            // In native codegen, concurrent blocks are no-ops (Stage 0)
            return []
        }
    }

    // MARK: - Terminator Emission

    /// Whether the function currently being emitted is the entry point.
    private var isMainFunction = false

    /// Temps used as function references in callIndirect instructions.
    /// Only constString values for these temps should be converted to function pointers.
    private var indirectCallTargets: Set<String> = []

    /// Maps function name → set of parameter indices that are used as callIndirect targets.
    /// Used for cross-function tracing of function references passed as arguments.
    private var callableParams: [String: Set<Int>] = [:]

    /// Actual LLVM return type for the current function (may differ from MIR's declared type).
    private var currentReturnType: String = "void"

    // MARK: - Value Type Tracking

    /// Maps temp name → type name for temps that hold value type objects.
    /// Built per-function by scanning .newObject instructions.
    private var tempObjectTypes: [String: String] = [:]

    /// Temps that hold value-type objects proven non-escaping within the current function.
    /// These use LLVM alloca (stack) instead of rockit_object_alloc (heap).
    private var stackPromotedTemps: Set<String> = []

    /// Temps that only ever receive stack-promoted object pointers (via store chains).
    /// These are excluded from ARC tracking to prevent releasing stack memory.
    private var stackOnlyTemps: Set<String> = []

    /// Maps stack-promoted temp names → their pre-allocated stack alloca LLVM names.
    private var stackAllocaNames: [String: String] = [:]

    /// Checks if a type name is a value type (primitive-only data class).
    private func isValueType(_ typeName: String) -> Bool {
        return typeDecls[typeName]?.isValueType ?? false
    }

    /// Resolve the value type name for an object temp, if known.
    /// Checks tempObjectTypes (for locally-created objects) and currentClassName (for `this`).
    private func valueTypeForTemp(_ temp: String) -> String? {
        if let tn = tempObjectTypes[temp], isValueType(tn) { return tn }
        if temp == "this", let cn = currentClassName, isValueType(cn) { return cn }
        return nil
    }

    // MARK: - Escape Analysis (Stack Promotion)

    /// Cache of per-function parameter escape analysis: funcName → set of parameter indices that don't escape.
    private var nonEscapingParams: [String: Set<Int>] = [:]

    /// Analyze whether parameter at `paramIndex` escapes within `callee`.
    /// A parameter doesn't escape if it's only used in getField/load (read-only access).
    private func paramEscapesInCallee(_ calleeName: String, paramIndex: Int) -> Bool {
        // Check cache
        if let cached = nonEscapingParams[calleeName] {
            return !cached.contains(paramIndex)
        }
        // Compute for all params of this function
        guard let callee = mirFunctionsByName[calleeName] else { return true }
        var safe = Set<Int>()
        for (idx, (name, _)) in callee.parameters.enumerated() {
            let paramLocal = "param.\(name)"
            var escapes = false
            // Build alias set for this parameter through load/store
            var aliases: Set<String> = [paramLocal]
            var changed = true
            while changed {
                changed = false
                for block in callee.blocks {
                    for inst in block.instructions {
                        if case .load(let dest, let src) = inst, aliases.contains(src), !aliases.contains(dest) {
                            aliases.insert(dest)
                            changed = true
                        }
                        if case .store(let dest, let src) = inst, aliases.contains(src), !aliases.contains(dest) {
                            aliases.insert(dest)
                            changed = true
                        }
                    }
                }
            }
            // Check if any alias escapes
            outer: for block in callee.blocks {
                for inst in block.instructions {
                    switch inst {
                    case .call(_, _, let args), .awaitCall(_, _, let args):
                        for arg in args where aliases.contains(arg) { escapes = true; break outer }
                    case .virtualCall(_, let obj, _, let args):
                        if aliases.contains(obj) { escapes = true; break outer }
                        for arg in args where aliases.contains(arg) { escapes = true; break outer }
                    case .callIndirect(_, _, let args):
                        for arg in args where aliases.contains(arg) { escapes = true; break outer }
                    case .setField(let object, _, let value):
                        if aliases.contains(value) {
                            let objectIsAlias = aliases.contains(object)
                            if !objectIsAlias { escapes = true; break outer }
                        }
                    default:
                        break
                    }
                }
                if let term = block.terminator {
                    switch term {
                    case .ret(let val):
                        if let val = val, aliases.contains(val) { escapes = true; break outer }
                    case .throwValue(let val):
                        if aliases.contains(val) { escapes = true; break outer }
                    default: break
                    }
                }
            }
            if !escapes { safe.insert(idx) }
        }
        nonEscapingParams[calleeName] = safe
        return !safe.contains(paramIndex)
    }

    /// Analyze a function to identify value-type newObject temps that do not escape.
    /// An object escapes if it is returned, thrown, passed to a call, or stored into another object.
    /// Conservative: if we can't prove non-escaping, assume it escapes.
    private func computeStackPromotedTemps(_ function: MIRFunction) -> Set<String> {
        // Step 1: Find all value-type newObject destinations
        var candidates: Set<String> = []
        for block in function.blocks {
            for inst in block.instructions {
                if case .newObject(let dest, let typeName, _) = inst {
                    if isValueType(typeName) {
                        candidates.insert(dest)
                    }
                }
            }
        }
        if candidates.isEmpty { return [] }

        // Step 2: Build alias groups through load/store chains.
        // If temp X holds a newObject result and `load Y, X` or `store Y, X`,
        // then Y is an alias of X.
        var aliasOrigin: [String: String] = [:]  // alias → original candidate
        for candidate in candidates {
            aliasOrigin[candidate] = candidate
        }

        var changed = true
        while changed {
            changed = false
            for block in function.blocks {
                for inst in block.instructions {
                    if case .store(let dest, let src) = inst {
                        if let origin = aliasOrigin[src], aliasOrigin[dest] == nil {
                            aliasOrigin[dest] = origin
                            changed = true
                        }
                    }
                    if case .load(let dest, let src) = inst {
                        if let origin = aliasOrigin[src], aliasOrigin[dest] == nil {
                            aliasOrigin[dest] = origin
                            changed = true
                        }
                    }
                }
            }
        }

        // Step 3: Identify parameter-origin locals
        var paramOrigins: Set<String> = []
        for (name, _) in function.parameters {
            paramOrigins.insert("param.\(name)")
        }

        // Step 4: Check each use for escaping behavior
        var escaped: Set<String> = []

        for block in function.blocks {
            for inst in block.instructions {
                switch inst {
                case .call(_, let callee, let args):
                    for (i, arg) in args.enumerated() {
                        if let origin = aliasOrigin[arg] {
                            // Check if the param escapes within the callee
                            if paramEscapesInCallee(callee, paramIndex: i) {
                                escaped.insert(origin)
                            }
                        }
                    }
                case .awaitCall(_, _, let args):
                    for arg in args {
                        if let origin = aliasOrigin[arg] { escaped.insert(origin) }
                    }
                case .virtualCall(_, let obj, _, let args):
                    if let origin = aliasOrigin[obj] { escaped.insert(origin) }
                    for arg in args {
                        if let origin = aliasOrigin[arg] { escaped.insert(origin) }
                    }
                case .callIndirect(_, _, let args):
                    for arg in args {
                        if let origin = aliasOrigin[arg] { escaped.insert(origin) }
                    }
                case .setField(let object, _, let value):
                    // Value stored into a different object → escapes
                    if let valueOrigin = aliasOrigin[value] {
                        let objectOrigin = aliasOrigin[object]
                        if objectOrigin != valueOrigin {
                            escaped.insert(valueOrigin)
                        }
                    }
                case .store(let dest, let src):
                    // Storing to a parameter-origin location → escapes
                    if let origin = aliasOrigin[src], paramOrigins.contains(dest) {
                        escaped.insert(origin)
                    }
                case .typeCast(_, let operand, _):
                    if let origin = aliasOrigin[operand] { escaped.insert(origin) }
                case .stringConcat(_, let parts):
                    for part in parts {
                        if let origin = aliasOrigin[part] { escaped.insert(origin) }
                    }
                default:
                    break
                }
            }

            // Check terminator
            if let term = block.terminator {
                switch term {
                case .ret(let val):
                    if let val = val, let origin = aliasOrigin[val] {
                        escaped.insert(origin)
                    }
                case .throwValue(let val):
                    if let origin = aliasOrigin[val] { escaped.insert(origin) }
                default:
                    break
                }
            }
        }

        return candidates.subtracting(escaped)
    }

    /// Compute temps that only ever receive stack-promoted object pointers.
    /// These temps are excluded from ARC tracking (no retain/release needed).
    /// A temp is "stack-only" if every value stored into it comes from a stack-promoted newObject.
    private func computeStackOnlyTemps(_ function: MIRFunction) -> Set<String> {
        guard !stackPromotedTemps.isEmpty else { return [] }
        // Track which temps are known to only hold stack-promoted values
        var stackOnly = stackPromotedTemps
        // Propagate through store chains: if store(dest, src) and src is stack-only,
        // AND dest never receives a non-stack-only value, then dest is stack-only.
        // We do this conservatively: first find all store targets, then check.
        var storeTargets: [String: [String]] = [:]  // dest → [src values stored]
        for block in function.blocks {
            for inst in block.instructions {
                if case .store(let dest, let src) = inst {
                    storeTargets[dest, default: []].append(src)
                }
            }
        }
        // Iteratively propagate stack-only status
        var changed = true
        while changed {
            changed = false
            for (dest, srcs) in storeTargets {
                if stackOnly.contains(dest) { continue }
                // dest is stack-only if ALL sources stored to it are stack-only
                if srcs.allSatisfy({ stackOnly.contains($0) }) {
                    stackOnly.insert(dest)
                    changed = true
                }
            }
        }
        return stackOnly
    }

    // MARK: - ARC Tracking

    /// The kind of heap object a temp holds (for choosing the correct release function).
    private enum HeapKind {
        case string   // rockit_string_release
        case object   // rockit_release
        case list     // rockit_list_release
        case map      // rockit_map_release
        case unknown  // rockit_release_value (type unknown at compile time, e.g. getField/listGet/mapGet)
    }

    /// Temps that own newly-allocated heap objects and need release at function exit.
    /// Populated during instruction emission; consumed when emitting ret terminators.
    private var ownedHeapTemps: [(allocaName: String, kind: HeapKind)] = []

    /// Track a temp as owning a heap value. Updates both ownedHeapTemps and tempHeapKinds.
    private func trackHeapTemp(_ dest: String, kind: HeapKind) {
        ownedHeapTemps.append((allocaName: dest, kind: kind))
        tempHeapKinds[dest] = kind
    }
    /// Temps known to contain integer values (not pointers stored as i64).
    /// Used by emitPrintCall to dispatch to rockit_println_int instead of _any.
    private var knownIntTemps: Set<String> = []
    /// Maps temp name → last assigned HeapKind, so .store barriers use type-specific release.
    private var tempHeapKinds: [String: HeapKind] = [:]

    /// Maps heap temp name → flag alloca name (e.g., "t5" → "%t5.arc").
    /// Flag allocas are i1 values initialized to 0 in the prologue, set to 1 at creation sites.
    /// Used by emitARCCleanup to conditionally release only initialized temps.
    private var arcFlags: [String: String] = [:]

    /// Emit a "temp write barrier" for a retained heap value.
    /// If the temp already holds a retained value (flag is set), release the old value first.
    /// Then retain the new value and set the flag.
    /// This makes loops safe: each iteration releases the previous retained value.
    /// - Parameters:
    ///   - dest: The temp alloca name (e.g., "%t5")
    ///   - newValI64: The new value as i64 (for rockit_retain_value / rockit_release_value)
    ///   - kind: The HeapKind for tracking in ownedHeapTemps
    private func emitTempRetainBarrier(dest: String, newValI64: String, kind: HeapKind) -> [String] {
        guard let flagName = arcFlags[dest] else {
            // No flag alloca → just retain and track
            return emitRetainCall(newValI64, kind: kind)
        }

        var lines: [String] = []

        // Check if temp already holds a retained value
        let flagTmp = nextSSA()
        let relLabel = "arc.wb.\(labelCounter)"
        let doneLabel = "arc.wbd.\(labelCounter)"
        labelCounter += 1

        lines.append("\(flagTmp) = load i1, ptr \(flagName)")
        lines.append("br i1 \(flagTmp), label %\(relLabel), label %\(doneLabel)")
        lines.append("\(relLabel):")

        // Release the old value currently in the temp
        let oldValType = registerTypes[dest] ?? "i64"
        let oldTmp = nextSSA()
        lines.append("  \(oldTmp) = load \(oldValType), ptr \(addrOf(dest))")
        if oldValType == "ptr" {
            lines.append(contentsOf: emitTypedRelease("ptr", oldTmp, kind: kind).map { "  " + $0 })
        } else {
            lines.append(contentsOf: emitTypedRelease("i64", oldTmp, kind: kind).map { "  " + $0 })
        }
        lines.append("  br label %\(doneLabel)")
        lines.append("\(doneLabel):")

        // Retain the new value — use typed function when kind is known
        lines.append(contentsOf: emitRetainCall(newValI64, kind: kind))

        // Set the flag
        lines.append("store i1 1, ptr \(flagName)")

        // Track in ownedHeapTemps (only first occurrence matters for cleanup dedup)
        trackHeapTemp(dest, kind: kind)

        return lines
    }

    /// Emit inline retain for a string pointer (no function call on fast path).
    /// Fast path: load refCount, check immortal, increment. No call needed.
    private func emitInlineStringRetain(_ ptr: String) -> [String] {
        let rc = nextSSA()
        let isImmortal = nextSSA()
        let doRetainLbl = "arc.ret.\(labelCounter)"
        let skipLbl = "arc.rets.\(labelCounter)"
        labelCounter += 1
        let newRc = nextSSA()
        return [
            "\(rc) = load i64, ptr \(ptr)",
            "\(isImmortal) = icmp eq i64 \(rc), 9223372036854775807",
            "br i1 \(isImmortal), label %\(skipLbl), label %\(doRetainLbl)",
            "\(doRetainLbl):",
            "  \(newRc) = add i64 \(rc), 1",
            "  store i64 \(newRc), ptr \(ptr)",
            "  br label %\(skipLbl)",
            "\(skipLbl):"
        ]
    }

    /// Emit inline release for a string pointer (no function call on fast path).
    /// Fast path: load refCount, check immortal, decrement. Call dealloc only when zero.
    private func emitInlineStringRelease(_ ptr: String) -> [String] {
        externalDecls.insert("declare void @rockit_string_dealloc(ptr)")
        let rc = nextSSA()
        let isImmortal = nextSSA()
        let doRelLbl = "arc.rel.\(labelCounter)"
        let skipLbl = "arc.rels.\(labelCounter)"
        let freeLbl = "arc.free.\(labelCounter)"
        labelCounter += 1
        let newRc = nextSSA()
        let needFree = nextSSA()
        return [
            "\(rc) = load i64, ptr \(ptr)",
            "\(isImmortal) = icmp eq i64 \(rc), 9223372036854775807",
            "br i1 \(isImmortal), label %\(skipLbl), label %\(doRelLbl)",
            "\(doRelLbl):",
            "  \(newRc) = sub i64 \(rc), 1",
            "  store i64 \(newRc), ptr \(ptr)",
            "  \(needFree) = icmp sle i64 \(newRc), 0",
            "  br i1 \(needFree), label %\(freeLbl), label %\(skipLbl)",
            "\(freeLbl):",
            "  call void @rockit_string_dealloc(ptr \(ptr))",
            "  br label %\(skipLbl)",
            "\(skipLbl):"
        ]
    }

    /// Emit a typed retain call. Uses inline IR for strings,
    /// `rockit_retain(ptr)` for objects, `rockit_retain_value(i64)` for unknown.
    private func emitRetainCall(_ valI64: String, kind: HeapKind) -> [String] {
        switch kind {
        case .string:
            let ptr = nextSSA()
            return ["\(ptr) = inttoptr i64 \(valI64) to ptr"] + emitInlineStringRetain(ptr)
        case .object:
            let ptr = nextSSA()
            return [
                "\(ptr) = inttoptr i64 \(valI64) to ptr",
                "call void @rockit_retain(ptr \(ptr))"
            ]
        default:
            return ["call void @rockit_retain_value(i64 \(valI64))"]
        }
    }

    /// Emit a typed release call for a value of the given LLVM type.
    private func emitTypedRelease(_ llType: String, _ val: String, kind: HeapKind) -> [String] {
        switch kind {
        case .string:
            if llType == "ptr" {
                return emitInlineStringRelease(val)
            }
            let ptr = nextSSA()
            return ["\(ptr) = inttoptr i64 \(val) to ptr"] + emitInlineStringRelease(ptr)
        case .object:
            if llType == "ptr" {
                return ["call void @rockit_release(ptr \(val))"]
            }
            let ptr = nextSSA()
            return [
                "\(ptr) = inttoptr i64 \(val) to ptr",
                "call void @rockit_release(ptr \(ptr))"
            ]
        default:
            if llType == "ptr" {
                let i64 = nextSSA()
                return [
                    "\(i64) = ptrtoint ptr \(val) to i64",
                    "call void @rockit_release_value(i64 \(i64))"
                ]
            }
            return ["call void @rockit_release_value(i64 \(val))"]
        }
    }

    /// Emit a conditional release of the old value in a temp before overwriting it.
    /// Used at heap creation sites (constString, newObject, stringConcat, heap-allocating calls)
    /// to prevent leaks when the same temp is overwritten in a loop.
    /// Unlike emitTempRetainBarrier, this does NOT retain the new value (creation sites
    /// produce objects with refcount 1 — they don't need an extra retain).
    private func emitOldTempRelease(dest: String, kind: HeapKind) -> [String] {
        guard let flagName = arcFlags[dest] else { return [] }

        var lines: [String] = []
        let flagTmp = nextSSA()
        let relLabel = "arc.ow.\(labelCounter)"
        let doneLabel = "arc.owd.\(labelCounter)"
        labelCounter += 1

        lines.append("\(flagTmp) = load i1, ptr \(flagName)")
        lines.append("br i1 \(flagTmp), label %\(relLabel), label %\(doneLabel)")
        lines.append("\(relLabel):")

        let oldValType = registerTypes[dest] ?? "i64"
        let oldTmp = nextSSA()
        lines.append("  \(oldTmp) = load \(oldValType), ptr \(addrOf(dest))")

        // Use type-specific release to avoid heuristic misidentification
        // (e.g., short strings' uninitialized bytes at offset 24 can look like heap pointers)
        let oldPtr: String
        if oldValType == "ptr" {
            oldPtr = oldTmp
        } else {
            let castTmp = nextSSA()
            lines.append("  \(castTmp) = inttoptr i64 \(oldTmp) to ptr")
            oldPtr = castTmp
        }
        switch kind {
        case .string:
            lines.append(contentsOf: emitInlineStringRelease(oldPtr).map { "  " + $0 })
        case .object:
            lines.append("  call void @rockit_release(ptr \(oldPtr))")
        case .list:
            lines.append("  call void @rockit_list_release(ptr \(oldPtr))")
        case .map:
            lines.append("  call void @rockit_map_release(ptr \(oldPtr))")
        case .unknown:
            if oldValType == "ptr" {
                let oldI64 = nextSSA()
                lines.append("  \(oldI64) = ptrtoint ptr \(oldTmp) to i64")
                lines.append("  call void @rockit_release_value(i64 \(oldI64))")
            } else {
                lines.append("  call void @rockit_release_value(i64 \(oldTmp))")
            }
        }

        lines.append("  br label %\(doneLabel)")
        lines.append("\(doneLabel):")

        return lines
    }

    /// Emit release calls for all owned heap temps except the return value.
    /// Called before every `ret` instruction to clean up function-local allocations.
    /// Uses boolean init flags to safely skip uninitialized temps.
    /// When returnValueI64 is provided, each temp's value is compared against it
    /// to avoid releasing a value that aliases the return value (common with store/load chains).
    /// Uses type-specific release functions for proper cascading deallocation.
    private func emitARCCleanup(returnTemp: String?, returnValueI64: String? = nil) -> [String] {
        var lines: [String] = []
        var seen = Set<String>()
        for (allocaName, kind) in ownedHeapTemps {
            // Skip duplicates (same temp may be appended on multiple code paths)
            guard seen.insert(allocaName).inserted else { continue }
            // Skip the return value — ownership transfers to caller
            if allocaName == returnTemp { continue }
            // Skip globals — their values persist after function return.
            // The function-local ARC flag tracks writes within this call,
            // but releasing on exit would free values still referenced by the global.
            if allocaName.hasPrefix("global.") { continue }
            // Skip temps without flags (shouldn't happen, but defensive)
            guard let flagName = arcFlags[allocaName] else { continue }

            let flagTmp = nextSSA()
            let checkLabel = "arc.chk.\(labelCounter)"
            let relLabel = "arc.rel.\(labelCounter)"
            let skipLabel = "arc.skip.\(labelCounter)"
            labelCounter += 1

            lines.append("\(flagTmp) = load i1, ptr \(flagName)")
            lines.append("br i1 \(flagTmp), label %\(checkLabel), label %\(skipLabel)")
            lines.append("\(checkLabel):")

            // Load the value (safe here because flag was set → temp was initialized)
            let valType = registerTypes[allocaName] ?? "ptr"
            let valTmp = nextSSA()
            lines.append("  \(valTmp) = load \(valType), ptr \(addrOf(allocaName))")

            // Get both ptr and i64 representations
            let valPtr: String
            let valI64: String
            if valType == "ptr" {
                valPtr = valTmp
                let castTmp = nextSSA()
                lines.append("  \(castTmp) = ptrtoint ptr \(valTmp) to i64")
                valI64 = castTmp
            } else {
                let castTmp = nextSSA()
                lines.append("  \(castTmp) = inttoptr i64 \(valTmp) to ptr")
                valPtr = castTmp
                valI64 = valTmp
            }

            // If returning a value, check for aliasing before releasing
            if let retVal = returnValueI64 {
                let cmpTmp = nextSSA()
                lines.append("  \(cmpTmp) = icmp eq i64 \(valI64), \(retVal)")
                lines.append("  br i1 \(cmpTmp), label %\(skipLabel), label %\(relLabel)")
                lines.append("  \(relLabel):")
            }

            // Call type-specific release for proper cascading deallocation
            switch kind {
            case .string:
                lines.append(contentsOf: emitInlineStringRelease(valPtr).map { "  " + $0 })
            case .object:
                lines.append("  call void @rockit_release(ptr \(valPtr))")
            case .list:
                lines.append("  call void @rockit_list_release(ptr \(valPtr))")
            case .map:
                lines.append("  call void @rockit_map_release(ptr \(valPtr))")
            case .unknown:
                lines.append("  call void @rockit_release_value(i64 \(valI64))")
            }

            lines.append("  br label %\(skipLabel)")
            lines.append("\(skipLabel):")
        }
        return lines
    }

    private func emitTerminator(_ term: MIRTerminator, returnType: MIRType) -> [String] {
        switch term {
        case .ret(let val):
            var lines: [String] = []

            if isMainFunction {
                // ARC cleanup before main returns
                lines.append(contentsOf: emitARCCleanup(returnTemp: nil))
                lines.append("ret i32 0")
                return lines
            }
            if let val = val {
                // Use the function's actual return type (may be inferred, not MIR's declared type)
                let retLLVM = currentReturnType != "void" ? currentReturnType : typeOf(val)
                let tmp = nextSSA()
                lines.append("\(tmp) = load \(retLLVM), ptr \(addrOf(val))")
                // Cast return value to i64 for alias comparison in ARC cleanup
                let retI64: String
                if retLLVM == "ptr" {
                    let castTmp = nextSSA()
                    lines.append("\(castTmp) = ptrtoint ptr \(tmp) to i64")
                    retI64 = castTmp
                } else if retLLVM == "i64" {
                    retI64 = tmp
                } else {
                    // i1/double can't alias heap objects — use 0 (never matches)
                    retI64 = "0"
                }
                // ARC: cleanup local allocations, skip any that alias the return value
                lines.append(contentsOf: emitARCCleanup(returnTemp: val, returnValueI64: retI64))
                lines.append("ret \(retLLVM) \(tmp)")
                return lines
            } else {
                // ARC cleanup before void return
                lines.append(contentsOf: emitARCCleanup(returnTemp: nil))
                lines.append("ret void")
                return lines
            }

        case .jump(let label):
            return ["br label %\(llvmLabel(label))"]

        case .branch(let condition, let thenLabel, let elseLabel):
            let tmp = nextSSA()
            return [
                "\(tmp) = load i1, ptr \(addrOf(condition))",
                "br i1 \(tmp), label %\(llvmLabel(thenLabel)), label %\(llvmLabel(elseLabel))"
            ]

        case .throwValue(let val):
            // Convert the thrown value to i64 and call rockit_exc_throw
            let valType = typeOf(val)
            let valTmp = nextSSA()
            var lines: [String] = [
                "\(valTmp) = load \(valType), ptr \(addrOf(val))"
            ]
            if valType == "ptr" {
                let castTmp = nextSSA()
                lines.append("\(castTmp) = ptrtoint ptr \(valTmp) to i64")
                lines.append("call void @rockit_exc_throw(i64 \(castTmp))")
            } else if valType == "i1" {
                let extTmp = nextSSA()
                lines.append("\(extTmp) = zext i1 \(valTmp) to i64")
                lines.append("call void @rockit_exc_throw(i64 \(extTmp))")
            } else {
                lines.append("call void @rockit_exc_throw(i64 \(valTmp))")
            }
            lines.append("unreachable")
            return lines

        case .unreachable:
            return ["unreachable"]
        }
    }

    // MARK: - Binary Arithmetic Helper

    private func emitBinaryArith(
        _ intOp: String, _ floatOp: String,
        dest: String, lhs: String, rhs: String, type: MIRType,
        intFlags: String = ""
    ) -> [String] {
        let lt = llvmArithType(type)
        let tmp1 = nextSSA()
        let tmp2 = nextSSA()
        let tmp3 = nextSSA()
        let isFloat = isFloatType(type)
        let op = isFloat ? floatOp : intOp
        let flags = (!isFloat && !intFlags.isEmpty) ? " \(intFlags)" : ""
        return [
            "\(tmp1) = load \(lt), ptr \(addrOf(lhs))",
            "\(tmp2) = load \(lt), ptr \(addrOf(rhs))",
            "\(tmp3) = \(op)\(flags) \(lt) \(tmp1), \(tmp2)",
            storeToTemp(dest, value: tmp3, type: lt)
        ]
    }

    // MARK: - Comparison Helper

    private func emitComparison(
        _ intCmp: String, _ floatCmp: String,
        dest: String, lhs: String, rhs: String, type: MIRType
    ) -> [String] {
        // For float comparisons, use fcmp
        if isFloatType(type) {
            let lt = llvmArithType(type)
            let tmp1 = nextSSA()
            let tmp2 = nextSSA()
            let tmp3 = nextSSA()
            return [
                "\(tmp1) = load \(lt), ptr \(addrOf(lhs))",
                "\(tmp2) = load \(lt), ptr \(addrOf(rhs))",
                "\(tmp3) = \(floatCmp) \(lt) \(tmp1), \(tmp2)",
                storeToTemp(dest, value: tmp3, type: "i1")
            ]
        }

        // For eq/neq on non-float types:
        // - If the MIR type is a known integer/bool type, use icmp directly
        // - If at least one operand is a known integer, use icmp directly
        //   (a known integer can never equal a string pointer, so icmp is correct)
        // - Otherwise fall back to rockit_string_eq/neq which safely handles
        //   both string pointers and integer values
        let isEqOrNeq = intCmp.contains("eq") || intCmp.contains("ne")
        if isEqOrNeq {
            let isKnownIntType: Bool
            switch type {
            case .int, .int32, .int64, .bool:
                isKnownIntType = true
            default:
                isKnownIntType = false
            }
            let hasKnownIntOperand = knownIntTemps.contains(lhs) || knownIntTemps.contains(rhs)

            // Check if operands are string (ptr) types — if so, must use string comparison
            let lhsIsPtr = typeOf(lhs) == "ptr"
            let rhsIsPtr = typeOf(rhs) == "ptr"
            let hasStringOperand = lhsIsPtr || rhsIsPtr

            if !hasStringOperand && (isKnownIntType || hasKnownIntOperand) {
                // Direct integer comparison — no function call
                let tmp1 = nextSSA()
                let tmp2 = nextSSA()
                let tmp3 = nextSSA()
                return [
                    "\(tmp1) = load i64, ptr \(addrOf(lhs))",
                    "\(tmp2) = load i64, ptr \(addrOf(rhs))",
                    "\(tmp3) = \(intCmp) i64 \(tmp1), \(tmp2)",
                    storeToTemp(dest, value: tmp3, type: "i1")
                ]
            }

            // Inline string comparison when both operands are known string pointers.
            // Avoids the expensive is_likely_string_ptr heuristic in rockit_string_eq.
            // Emits: ptr compare → length compare → memcmp
            let lhsType = typeOf(lhs)
            let rhsType = typeOf(rhs)
            let isEq = intCmp == "icmp eq"

            if lhsIsPtr && rhsIsPtr {
                externalDecls.insert("declare i32 @memcmp(ptr, ptr, i64)")
                var lines: [String] = []
                let aPtr = nextSSA()
                let bPtr = nextSSA()
                lines.append("\(aPtr) = load ptr, ptr \(addrOf(lhs))")
                lines.append("\(bPtr) = load ptr, ptr \(addrOf(rhs))")

                // Quick check: same pointer → equal
                let samePtr = nextSSA()
                lines.append("\(samePtr) = icmp eq ptr \(aPtr), \(bPtr)")
                let lblSame = "streq.same.\(labelCounter)"
                let lblLens = "streq.lens.\(labelCounter)"
                let lblCmp = "streq.cmp.\(labelCounter)"
                let lblDone = "streq.done.\(labelCounter)"
                let lblNeq = "streq.neq.\(labelCounter)"
                labelCounter += 1
                lines.append("br i1 \(samePtr), label %\(lblSame), label %\(lblLens)")

                // Same pointer → result is true (for eq) or false (for neq)
                lines.append("\(lblSame):")
                lines.append("  br label %\(lblDone)")

                // Guard: if either pointer is the null sentinel (0xCAFEBABE), can't dereference
                lines.append("\(lblLens):")
                let nullSentinel = nextSSA()
                lines.append("  \(nullSentinel) = inttoptr i64 3405691582 to ptr")
                let aIsNull = nextSSA()
                lines.append("  \(aIsNull) = icmp eq ptr \(aPtr), \(nullSentinel)")
                let lblCheckB = "streq.ckb.\(labelCounter - 1)"
                lines.append("  br i1 \(aIsNull), label %\(lblNeq), label %\(lblCheckB)")
                lines.append("\(lblCheckB):")
                let bIsNull = nextSSA()
                lines.append("  \(bIsNull) = icmp eq ptr \(bPtr), \(nullSentinel)")
                let lblLensReal = "streq.lens2.\(labelCounter - 1)"
                lines.append("  br i1 \(bIsNull), label %\(lblNeq), label %\(lblLensReal)")

                // Compare lengths
                lines.append("\(lblLensReal):")
                let aLenP = nextSSA()
                lines.append("  \(aLenP) = getelementptr i8, ptr \(aPtr), i64 8")
                let aLen = nextSSA()
                lines.append("  \(aLen) = load i64, ptr \(aLenP)")
                let bLenP = nextSSA()
                lines.append("  \(bLenP) = getelementptr i8, ptr \(bPtr), i64 8")
                let bLen = nextSSA()
                lines.append("  \(bLen) = load i64, ptr \(bLenP)")
                let lenEq = nextSSA()
                lines.append("  \(lenEq) = icmp eq i64 \(aLen), \(bLen)")
                lines.append("  br i1 \(lenEq), label %\(lblCmp), label %\(lblNeq)")

                // Lengths match → memcmp chars
                lines.append("\(lblCmp):")
                let aCharsP = nextSSA()
                lines.append("  \(aCharsP) = getelementptr i8, ptr \(aPtr), i64 16")
                let aChars = nextSSA()
                lines.append("  \(aChars) = load ptr, ptr \(aCharsP)")
                let bCharsP = nextSSA()
                lines.append("  \(bCharsP) = getelementptr i8, ptr \(bPtr), i64 16")
                let bChars = nextSSA()
                lines.append("  \(bChars) = load ptr, ptr \(bCharsP)")
                let cmpResult = nextSSA()
                lines.append("  \(cmpResult) = call i32 @memcmp(ptr \(aChars), ptr \(bChars), i64 \(aLen))")
                let cmpEq = nextSSA()
                lines.append("  \(cmpEq) = icmp eq i32 \(cmpResult), 0")
                lines.append("  br label %\(lblDone)")

                // Lengths differ → not equal
                lines.append("\(lblNeq):")
                lines.append("  br label %\(lblDone)")

                // Merge
                lines.append("\(lblDone):")
                let phi = nextSSA()
                lines.append("  \(phi) = phi i1 [ true, %\(lblSame) ], [ \(cmpEq), %\(lblCmp) ], [ false, %\(lblNeq) ]")
                if !isEq {
                    let negated = nextSSA()
                    lines.append("  \(negated) = xor i1 \(phi), true")
                    lines.append(storeToTemp(dest, value: negated, type: "i1"))
                } else {
                    lines.append(storeToTemp(dest, value: phi, type: "i1"))
                }
                return lines
            }

            // Fall back to rockit_string_eq/neq for mixed types
            let tmp1 = nextSSA()
            let tmp2 = nextSSA()
            let tmp3 = nextSSA()
            let funcName = isEq ? "@rockit_string_eq" : "@rockit_string_neq"
            var lines: [String] = []
            if lhsType == "ptr" {
                let ptmp = nextSSA()
                lines.append("\(ptmp) = load ptr, ptr \(addrOf(lhs))")
                lines.append("\(tmp1) = ptrtoint ptr \(ptmp) to i64")
            } else {
                lines.append("\(tmp1) = load i64, ptr \(addrOf(lhs))")
            }
            if rhsType == "ptr" {
                let ptmp = nextSSA()
                lines.append("\(ptmp) = load ptr, ptr \(addrOf(rhs))")
                lines.append("\(tmp2) = ptrtoint ptr \(ptmp) to i64")
            } else {
                lines.append("\(tmp2) = load i64, ptr \(addrOf(rhs))")
            }
            lines.append("\(tmp3) = call i1 \(funcName)(i64 \(tmp1), i64 \(tmp2))")
            lines.append(storeToTemp(dest, value: tmp3, type: "i1"))
            return lines
        }

        // For lt/lte/gt/gte, use standard icmp
        let lt = llvmArithType(type)
        let tmp1 = nextSSA()
        let tmp2 = nextSSA()
        let tmp3 = nextSSA()
        return [
            "\(tmp1) = load \(lt), ptr \(addrOf(lhs))",
            "\(tmp2) = load \(lt), ptr \(addrOf(rhs))",
            "\(tmp3) = \(intCmp) \(lt) \(tmp1), \(tmp2)",
            storeToTemp(dest, value: tmp3, type: "i1")
        ]
    }

    // MARK: - Call Emission

    private func emitCall(dest: String?, function: String, args: [String]) -> [String] {
        // Remap bytecode-only builtins to native runtime functions
        // Remap bytecode-only collection builtins to native runtime functions
        if let result = emitRemappedCollectionBuiltin(dest: dest, function: function, args: args) {
            return result
        }

        // Special handling for builtins
        if function == "println" || function == "print" {
            return emitPrintCall(function: function, args: args)
        }
        if function == "toString" {
            return emitToStringCall(dest: dest, args: args)
        }
        if function == "listOf" {
            return emitListOf(dest: dest, args: args)
        }
        if function == "mapOf" {
            return emitMapOf(dest: dest, args: args)
        }
        if function == "mutableListOf" {
            return emitListOf(dest: dest, args: args)
        }
        if function == "mutableMapOf" {
            return emitMapOf(dest: dest, args: args)
        }

        // Inline stringLength(s) — avoids function call overhead.
        // Emits: s->length (load from offset 8 in RockitString struct)
        if function == "stringLength", let dest = dest, args.count == 1 {
            let arg = args[0]
            var lines: [String] = []
            let sPtr = nextSSA()
            lines.append("\(sPtr) = load ptr, ptr \(addrOf(arg))")
            let lenPtr = nextSSA()
            lines.append("\(lenPtr) = getelementptr i8, ptr \(sPtr), i64 8")
            let len = nextSSA()
            lines.append("\(len) = load i64, ptr \(lenPtr)")
            lines.append(storeToTemp(dest, value: len, type: "i64"))
            registerTypes[dest] = "i64"
            knownIntTemps.insert(dest)
            return lines
        }

        // Inline charCodeAt(s, index) — avoids function call overhead.
        // Emits: (i64)(unsigned char) s->chars[index]
        // Layout: offset 16 = chars pointer in RockitString struct
        if function == "charCodeAt", let dest = dest, args.count == 2 {
            let sArg = args[0]
            let idxArg = args[1]
            var lines: [String] = []
            let sPtr = nextSSA()
            lines.append("\(sPtr) = load ptr, ptr \(addrOf(sArg))")
            let idx = nextSSA()
            lines.append("\(idx) = load i64, ptr \(addrOf(idxArg))")
            // Load chars pointer (offset 16)
            let charsFieldPtr = nextSSA()
            lines.append("\(charsFieldPtr) = getelementptr i8, ptr \(sPtr), i64 16")
            let charsPtr = nextSSA()
            lines.append("\(charsPtr) = load ptr, ptr \(charsFieldPtr)")
            // Load byte at index
            let bytePtr = nextSSA()
            lines.append("\(bytePtr) = getelementptr i8, ptr \(charsPtr), i64 \(idx)")
            let byteVal = nextSSA()
            lines.append("\(byteVal) = load i8, ptr \(bytePtr)")
            let result = nextSSA()
            lines.append("\(result) = zext i8 \(byteVal) to i64")
            lines.append(storeToTemp(dest, value: result, type: "i64"))
            registerTypes[dest] = "i64"
            knownIntTemps.insert(dest)
            return lines
        }

        // Inline toInt() for known integer arguments — avoids runtime call
        if function == "toInt", let dest = dest, args.count == 1 {
            let arg = args[0]
            if knownIntTemps.contains(arg) {
                let tmp = nextSSA()
                let argType = typeOf(arg)
                var lines: [String] = []
                lines.append("\(tmp) = load \(argType), ptr \(addrOf(arg))")
                lines.append(storeToTemp(dest, value: tmp, type: "i64"))
                registerTypes[dest] = "i64"
                knownIntTemps.insert(dest)
                return lines
            }
        }

        var lines: [String] = []

        // ARC: for heap-allocating calls, save old value BEFORE loading args
        // (dest may also be an arg — releasing after arg load would be use-after-free)
        var deferredRelease: (flagTmp: String, savedTmp: String, savedType: String, kind: HeapKind)? = nil
        if let dest = dest, let kind = heapKindForFunction(function), let flagName = arcFlags[dest] {
            let flagTmp = nextSSA()
            lines.append("\(flagTmp) = load i1, ptr \(flagName)")
            let savedType = registerTypes[dest] ?? "i64"
            let savedTmp = nextSSA()
            lines.append("\(savedTmp) = load \(savedType), ptr \(addrOf(dest))")
            deferredRelease = (flagTmp: flagTmp, savedTmp: savedTmp, savedType: savedType, kind: kind)
        }

        let formalParamTypes = functionParamTypes[function]
        var argStrs: [String] = []
        for (i, arg) in args.enumerated() {
            let argType = typeOf(arg)
            let tmp = nextSSA()
            lines.append("\(tmp) = load \(argType), ptr \(addrOf(arg))")
            // Convert arg type to match formal parameter type if needed (generic erasure)
            if let fpt = formalParamTypes, i < fpt.count {
                let formalType = llvmType(fpt[i])
                if argType != formalType {
                    if argType == "ptr" && formalType == "i64" {
                        let conv = nextSSA()
                        lines.append("\(conv) = ptrtoint ptr \(tmp) to i64")
                        argStrs.append("i64 \(conv)")
                        continue
                    } else if argType == "i64" && formalType == "ptr" {
                        let conv = nextSSA()
                        lines.append("\(conv) = inttoptr i64 \(tmp) to ptr")
                        argStrs.append("ptr \(conv)")
                        continue
                    }
                }
            }
            argStrs.append("\(argType) \(tmp)")
        }

        let argList = argStrs.joined(separator: ", ")
        let funcName = llvmFunctionName(function)

        if let dest = dest {
            let destType = typeOf(dest)
            // Use the function's formal return type for the call instruction
            let formalRetType: String
            if let sig = functionSignatures[function] {
                let lt = llvmType(sig)
                formalRetType = lt != "void" ? lt : destType
            } else {
                formalRetType = destType
            }
            let resultTmp = nextSSA()
            lines.append("\(resultTmp) = call \(formalRetType) @\(funcName)(\(argList))")
            // Convert return value if formal type differs from dest type
            if formalRetType != destType {
                let convTmp: String
                if formalRetType == "ptr" && destType == "i64" {
                    convTmp = nextSSA()
                    lines.append("\(convTmp) = ptrtoint ptr \(resultTmp) to i64")
                } else if formalRetType == "i64" && destType == "ptr" {
                    convTmp = nextSSA()
                    lines.append("\(convTmp) = inttoptr i64 \(resultTmp) to ptr")
                } else {
                    convTmp = resultTmp
                }
                lines.append(storeToTemp(dest, value: convTmp, type: destType))
            } else {
                lines.append(storeToTemp(dest, value: resultTmp, type: destType))
            }

            // ARC: track heap-allocating calls
            if let kind = heapKindForFunction(function) {
                trackHeapTemp(dest, kind: kind)
                if let flag = arcFlags[dest] { lines.append("store i1 1, ptr \(flag)") }
            }

            // ARC: deferred release of old value (after call + store, so new value is safe)
            if let dr = deferredRelease {
                let relLabel = "arc.ow.\(labelCounter)"
                let doneLabel = "arc.owd.\(labelCounter)"
                labelCounter += 1
                lines.append("br i1 \(dr.flagTmp), label %\(relLabel), label %\(doneLabel)")
                lines.append("\(relLabel):")
                let oldPtr: String
                if dr.savedType == "ptr" {
                    oldPtr = dr.savedTmp
                } else {
                    let castTmp = nextSSA()
                    lines.append("  \(castTmp) = inttoptr i64 \(dr.savedTmp) to ptr")
                    oldPtr = castTmp
                }
                switch dr.kind {
                case .string:
                    lines.append(contentsOf: emitInlineStringRelease(oldPtr).map { "  " + $0 })
                case .object:
                    lines.append("  call void @rockit_release(ptr \(oldPtr))")
                case .list:
                    lines.append("  call void @rockit_list_release(ptr \(oldPtr))")
                case .map:
                    lines.append("  call void @rockit_map_release(ptr \(oldPtr))")
                case .unknown:
                    if dr.savedType == "ptr" {
                        let oldI64 = nextSSA()
                        lines.append("  \(oldI64) = ptrtoint ptr \(dr.savedTmp) to i64")
                        lines.append("  call void @rockit_release_value(i64 \(oldI64))")
                    } else {
                        lines.append("  call void @rockit_release_value(i64 \(dr.savedTmp))")
                    }
                }
                lines.append("  br label %\(doneLabel)")
                lines.append("\(doneLabel):")
            }
        } else {
            lines.append("call void @\(funcName)(\(argList))")
        }

        return lines
    }

    /// Returns the HeapKind for functions that return newly-allocated heap objects, or nil.
    private func heapKindForFunction(_ name: String) -> HeapKind? {
        switch name {
        case "rockit_string_new", "rockit_string_concat", "rockit_string_concat_consume", "stringConcat",
             "readLine", "substring", "charAt", "stringTrim", "fileRead",
             "rockit_int_to_string", "rockit_float_to_string", "rockit_bool_to_string",
             "intToChar":
            return .string
        case "rockit_list_create", "listCreate", "listCreateFilled":
            return .list
        case "rockit_map_create", "mapCreate":
            return .map
        // Collection get ops return borrowed values that may be heap objects
        case "listGet", "mapGet", "listRemoveAt", "mapKeys":
            return .unknown
        default:
            return nil
        }
    }

    /// Pre-scan a function to identify temps that will receive heap allocations.
    /// Returns the set of dest temp names that need ARC flag allocas.
    /// Over-inclusion is safe (flag stays 0 → no release); under-inclusion is NOT.
    private func collectHeapTempDests(_ function: MIRFunction) -> Set<String> {
        var dests = Set<String>()
        for block in function.blocks {
            for inst in block.instructions {
                switch inst {
                case .constString(let dest, let value):
                    // Only if NOT a function pointer (function pointers don't get rockit_string_new)
                    if !(moduleFunctionNames.contains(value) && indirectCallTargets.contains(dest)) {
                        dests.insert(dest)
                    }
                case .newObject(let dest, _, _):
                    if !stackPromotedTemps.contains(dest) {
                        dests.insert(dest)
                    }
                case .stringConcat(let dest, _):
                    dests.insert(dest)
                case .add(let dest, _, _, let t):
                    // String addition compiles to rockit_string_concat → heap allocation
                    if case .string = t { dests.insert(dest) }
                case .getField(let dest, let object, _):
                    // getField may return a heap value (string, object, list, map)
                    // Skip if the object is a stack-only value type (fields are primitives)
                    if let tn = tempObjectTypes[object], isValueType(tn) { continue }
                    dests.insert(dest)
                case .virtualCall(let dest, _, let method, _):
                    guard let dest = dest else { continue }
                    // Collection get returns a borrowed value we'll retain
                    if method == "get" {
                        dests.insert(dest)
                    }
                case .call(let dest, let callee, _):
                    guard let dest = dest else { continue }
                    if heapKindForFunction(callee) != nil {
                        dests.insert(dest)
                    }
                    // listOf/mutableListOf → emitListOf → list creation
                    if callee == "listOf" || callee == "mutableListOf" {
                        dests.insert(dest)
                    }
                    // mapOf/mutableMapOf → emitMapOf → map creation
                    if callee == "mapOf" || callee == "mutableMapOf" {
                        dests.insert(dest)
                    }
                    // Collection get ops return borrowed references that may be heap objects
                    if callee == "listGet" || callee == "mapGet" || callee == "listRemoveAt" || callee == "mapKeys" {
                        dests.insert(dest)
                    }
                    // toString → may or may not track depending on arg type at emission time
                    // Over-include: flag stays 0 if emission doesn't track
                    if callee == "toString" {
                        dests.insert(dest)
                    }
                case .load(let dest, let src):
                    // Loading a ptr-typed global into a temp needs ARC tracking
                    // so emitOldTempRelease can release the old value in loops.
                    if src.hasPrefix("global.") {
                        let srcType = registerTypes[src] ?? moduleGlobals[src] ?? "i64"
                        if srcType == "ptr" {
                            dests.insert(dest)
                        }
                    }
                case .store(let dest, let src):
                    // If the source is ptr-typed, the dest needs ARC tracking
                    // to prevent leaks when ptr-typed locals are reassigned in loops.
                    // Skip if both src and dest are stack-only (no heap ptrs to release).
                    if stackOnlyTemps.contains(dest) { continue }
                    let srcType = registerTypes[src] ?? "i64"
                    if srcType == "ptr" {
                        dests.insert(dest)
                    }
                default:
                    break
                }
            }
        }
        return dests
    }

    // MARK: - Bytecode-to-Native Collection Remapping

    /// Remap bytecode collection builtins (listCreate, listAppend, mapCreate, etc.)
    /// to native runtime functions (rockit_list_create, rockit_list_append, etc.).
    /// Returns nil if the function is not a remappable collection builtin.
    private func emitRemappedCollectionBuiltin(dest: String?, function: String, args: [String]) -> [String]? {
        switch function {
        case "listCreate":
            return emitNativeCollectionCreate(dest: dest, nativeFn: "rockit_list_create", kind: .list)
        case "listCreateFilled":
            return emitListCreateFilled(dest: dest, args: args)
        case "mapCreate":
            return emitStringMapCreate(dest: dest)
        case "listAppend":
            return emitNativeListAppend(args: args)
        case "listGet":
            return emitInlineListGet(dest: dest, args: args)
        case "listSet":
            return emitInlineListSet(args: args)
        case "listSize":
            return emitInlineListSize(dest: dest, args: args)
        case "listGetFloat":
            return emitInlineListGetFloat(dest: dest, args: args)
        case "listSetFloat":
            return emitInlineListSetFloat(args: args)
        case "listContains":
            return emitNativeCollectionCallBool(dest: dest, nativeFn: "rockit_list_contains", args: args)
        case "listRemoveAt":
            return emitNativeCollectionCall(dest: dest, nativeFn: "rockit_list_remove_at", args: args, retType: "i64")
        case "listClear":
            return emitNativeListClear(args: args)
        case "byteArrayGet":
            return emitInlineByteArrayGet(dest: dest, args: args)
        case "byteArraySet":
            return emitInlineByteArraySet(args: args)
        case "mapPut":
            return emitStringMapPut(args: args)
        case "mapGet":
            return emitStringMapGet(dest: dest, args: args)
        case "mapKeys":
            return emitStringMapKeys(dest: dest, args: args)
        case "mapValues", "mapSize", "mapContainsKey", "mapRemove":
            // These are not used by Stage 1; fall through to normal call
            return nil
        default:
            return nil
        }
    }

    /// Emit a native collection create call (rockit_list_create or rockit_map_create)
    private func emitNativeCollectionCreate(dest: String?, nativeFn: String, kind: HeapKind) -> [String] {
        guard let dest = dest else { return [] }
        var lines: [String] = []
        // Release old value if dest was previously assigned (loop safety)
        lines.append(contentsOf: emitOldTempRelease(dest: dest, kind: kind))
        let tmp = nextSSA()
        lines.append("\(tmp) = call ptr @\(nativeFn)()")
        lines.append(storeToTemp(dest, value: tmp, type: "ptr"))
        registerTypes[dest] = "ptr"
        trackHeapTemp(dest, kind: kind)
        if let flag = arcFlags[dest] { lines.append("store i1 1, ptr \(flag)") }
        return lines
    }

    /// Load an arg as ptr, converting from i64 if needed
    private func loadArgAsPtr(_ arg: String, lines: inout [String]) -> String {
        let argType = typeOf(arg)
        let tmp = nextSSA()
        lines.append("\(tmp) = load \(argType), ptr \(addrOf(arg))")
        if argType == "ptr" { return tmp }
        let castTmp = nextSSA()
        lines.append("\(castTmp) = inttoptr i64 \(tmp) to ptr")
        return castTmp
    }

    /// Load an arg as i64, converting from ptr if needed
    private func loadArgAsI64(_ arg: String, lines: inout [String]) -> String {
        let argType = typeOf(arg)
        let tmp = nextSSA()
        lines.append("\(tmp) = load \(argType), ptr \(addrOf(arg))")
        if argType == "i64" { return tmp }
        if argType == "ptr" {
            let castTmp = nextSSA()
            lines.append("\(castTmp) = ptrtoint ptr \(tmp) to i64")
            return castTmp
        }
        if argType == "i1" {
            let castTmp = nextSSA()
            lines.append("\(castTmp) = zext i1 \(tmp) to i64")
            return castTmp
        }
        return tmp
    }

    /// Emit rockit_list_append(ptr, i64) — void return
    private func emitNativeListAppend(args: [String]) -> [String] {
        guard args.count >= 2 else { return [] }
        var lines: [String] = []
        let listPtr = loadArgAsPtr(args[0], lines: &lines)
        let val = loadArgAsI64(args[1], lines: &lines)

        // Inline fast path: if size < capacity, store directly and increment size
        // RockitList layout: refCount(0) size(8) capacity(16) data*(24)
        let sizeAddr = nextSSA()
        lines.append("\(sizeAddr) = getelementptr i8, ptr \(listPtr), i64 8")
        let size = nextSSA()
        lines.append("\(size) = load i64, ptr \(sizeAddr), !tbaa !3")
        let capAddr = nextSSA()
        lines.append("\(capAddr) = getelementptr i8, ptr \(listPtr), i64 16")
        let cap = nextSSA()
        lines.append("\(cap) = load i64, ptr \(capAddr), !tbaa !3")
        let ok = nextSSA()
        lines.append("\(ok) = icmp ult i64 \(size), \(cap)")
        let fastLabel = "append.fast.\(labelCounter)"
        let slowLabel = "append.slow.\(labelCounter)"
        let doneLabel = "append.done.\(labelCounter)"
        labelCounter += 1
        lines.append("br i1 \(ok), label %\(fastLabel), label %\(slowLabel), !prof !5")

        // Fast path: retain value, store element and increment size
        lines.append("\(fastLabel):")
        lines.append("call void @rockit_retain_value(i64 \(val))")
        let dataAddr = nextSSA()
        lines.append("\(dataAddr) = getelementptr i8, ptr \(listPtr), i64 24")
        let dataPtr = nextSSA()
        lines.append("\(dataPtr) = load ptr, ptr \(dataAddr), !tbaa !3")
        let elemAddr = nextSSA()
        lines.append("\(elemAddr) = getelementptr i64, ptr \(dataPtr), i64 \(size)")
        lines.append("store i64 \(val), ptr \(elemAddr), !tbaa !4")
        let newSize = nextSSA()
        lines.append("\(newSize) = add i64 \(size), 1")
        lines.append("store i64 \(newSize), ptr \(sizeAddr), !tbaa !3")
        lines.append("br label %\(doneLabel)")

        // Slow path: call runtime for reallocation
        lines.append("\(slowLabel):")
        lines.append("call void @rockit_list_append(ptr \(listPtr), i64 \(val))")
        lines.append("br label %\(doneLabel)")

        lines.append("\(doneLabel):")
        return lines
    }

    /// Emit rockit_list_set(ptr, i64, i64) — void return
    private func emitNativeListSet(args: [String]) -> [String] {
        guard args.count >= 3 else { return [] }
        var lines: [String] = []
        let listPtr = loadArgAsPtr(args[0], lines: &lines)
        let idx = loadArgAsI64(args[1], lines: &lines)
        let val = loadArgAsI64(args[2], lines: &lines)
        lines.append("call void @rockit_list_set(ptr \(listPtr), i64 \(idx), i64 \(val))")
        return lines
    }

    // MARK: - Inline List Access

    /// Inline listGet: GEP into RockitList.data[index]
    /// RockitList layout: refCount(0) size(8) capacity(16) data*(24)
    private func emitInlineListGet(dest: String?, args: [String]) -> [String] {
        guard let dest = dest, args.count >= 2 else { return [] }
        var lines: [String] = []
        let listPtr = loadArgAsPtr(args[0], lines: &lines)
        let idx = loadArgAsI64(args[1], lines: &lines)

        // Bounds check: idx < size
        let sizeAddr = nextSSA()
        lines.append("\(sizeAddr) = getelementptr i8, ptr \(listPtr), i64 8")
        let size = nextSSA()
        lines.append("\(size) = load i64, ptr \(sizeAddr), !tbaa !3")
        let ok = nextSSA()
        lines.append("\(ok) = icmp ult i64 \(idx), \(size)")
        let okLabel = "list.ok.\(labelCounter)"
        let oobLabel = "list.oob.\(labelCounter)"
        labelCounter += 1
        lines.append("br i1 \(ok), label %\(okLabel), label %\(oobLabel), !prof !5")
        lines.append("\(oobLabel):")
        let oobIdx = internString("list index out of bounds")
        lines.append("call void @rockit_panic(ptr \(oobIdx))")
        lines.append("unreachable")
        lines.append("\(okLabel):")

        // Inline GEP: data pointer at offset 24, then index into data array
        let dataAddr = nextSSA()
        lines.append("\(dataAddr) = getelementptr i8, ptr \(listPtr), i64 24")
        let dataPtr = nextSSA()
        lines.append("\(dataPtr) = load ptr, ptr \(dataAddr), !tbaa !3")
        let elemAddr = nextSSA()
        lines.append("\(elemAddr) = getelementptr i64, ptr \(dataPtr), i64 \(idx)")
        let result = nextSSA()
        lines.append("\(result) = load i64, ptr \(elemAddr), !tbaa !4")

        lines.append(storeToTemp(dest, value: result, type: "i64"))
        registerTypes[dest] = "i64"
        knownIntTemps.insert(dest)
        return lines
    }

    /// Inline listSet: GEP into RockitList.data[index]
    /// Skips ARC retain/release since stored values are integers in hot paths
    private func emitInlineListSet(args: [String]) -> [String] {
        guard args.count >= 3 else { return [] }
        var lines: [String] = []
        let listPtr = loadArgAsPtr(args[0], lines: &lines)
        let idx = loadArgAsI64(args[1], lines: &lines)

        // Load value — handle both i64 and double types
        let valType = typeOf(args[2])
        let valTmp = nextSSA()
        lines.append("\(valTmp) = load \(valType), ptr \(addrOf(args[2]))")
        let val: String
        if valType == "double" {
            let castTmp = nextSSA()
            lines.append("\(castTmp) = bitcast double \(valTmp) to i64")
            val = castTmp
        } else if valType == "ptr" {
            let castTmp = nextSSA()
            lines.append("\(castTmp) = ptrtoint ptr \(valTmp) to i64")
            val = castTmp
        } else {
            val = valTmp
        }

        // Bounds check: idx < size
        let sizeAddr = nextSSA()
        lines.append("\(sizeAddr) = getelementptr i8, ptr \(listPtr), i64 8")
        let size = nextSSA()
        lines.append("\(size) = load i64, ptr \(sizeAddr), !tbaa !3")
        let ok = nextSSA()
        lines.append("\(ok) = icmp ult i64 \(idx), \(size)")
        let okLabel = "list.ok.\(labelCounter)"
        let oobLabel = "list.oob.\(labelCounter)"
        labelCounter += 1
        lines.append("br i1 \(ok), label %\(okLabel), label %\(oobLabel), !prof !5")
        lines.append("\(oobLabel):")
        let oobIdx = internString("list index out of bounds")
        lines.append("call void @rockit_panic(ptr \(oobIdx))")
        lines.append("unreachable")
        lines.append("\(okLabel):")

        // Inline GEP store
        let dataAddr = nextSSA()
        lines.append("\(dataAddr) = getelementptr i8, ptr \(listPtr), i64 24")
        let dataPtr = nextSSA()
        lines.append("\(dataPtr) = load ptr, ptr \(dataAddr), !tbaa !3")
        let elemAddr = nextSSA()
        lines.append("\(elemAddr) = getelementptr i64, ptr \(dataPtr), i64 \(idx)")
        lines.append("store i64 \(val), ptr \(elemAddr), !tbaa !4")

        return lines
    }

    /// Inline listSize: load RockitList.size at offset 8
    private func emitInlineListSize(dest: String?, args: [String]) -> [String] {
        guard let dest = dest, args.count >= 1 else { return [] }
        var lines: [String] = []
        let listPtr = loadArgAsPtr(args[0], lines: &lines)

        let sizeAddr = nextSSA()
        lines.append("\(sizeAddr) = getelementptr i8, ptr \(listPtr), i64 8")
        let result = nextSSA()
        lines.append("\(result) = load i64, ptr \(sizeAddr), !tbaa !3")

        lines.append(storeToTemp(dest, value: result, type: "i64"))
        registerTypes[dest] = "i64"
        return lines
    }

    /// Inline listGetFloat: GEP into RockitList.data[index], load i64, bitcast to double
    private func emitInlineListGetFloat(dest: String?, args: [String]) -> [String] {
        guard let dest = dest, args.count >= 2 else { return [] }
        var lines: [String] = []
        let listPtr = loadArgAsPtr(args[0], lines: &lines)
        let idx = loadArgAsI64(args[1], lines: &lines)

        // Bounds check: idx < size
        let sizeAddr = nextSSA()
        lines.append("\(sizeAddr) = getelementptr i8, ptr \(listPtr), i64 8")
        let size = nextSSA()
        lines.append("\(size) = load i64, ptr \(sizeAddr), !tbaa !3")
        let ok = nextSSA()
        lines.append("\(ok) = icmp ult i64 \(idx), \(size)")
        let okLabel = "list.ok.\(labelCounter)"
        let oobLabel = "list.oob.\(labelCounter)"
        labelCounter += 1
        lines.append("br i1 \(ok), label %\(okLabel), label %\(oobLabel), !prof !5")
        lines.append("\(oobLabel):")
        let oobIdx = internString("list index out of bounds")
        lines.append("call void @rockit_panic(ptr \(oobIdx))")
        lines.append("unreachable")
        lines.append("\(okLabel):")

        // Inline GEP: data pointer at offset 24, then index into data array
        let dataAddr = nextSSA()
        lines.append("\(dataAddr) = getelementptr i8, ptr \(listPtr), i64 24")
        let dataPtr = nextSSA()
        lines.append("\(dataPtr) = load ptr, ptr \(dataAddr), !tbaa !3")
        let elemAddr = nextSSA()
        lines.append("\(elemAddr) = getelementptr i64, ptr \(dataPtr), i64 \(idx)")
        let rawVal = nextSSA()
        lines.append("\(rawVal) = load i64, ptr \(elemAddr), !tbaa !4")
        // Bitcast i64 to double
        let result = nextSSA()
        lines.append("\(result) = bitcast i64 \(rawVal) to double")

        lines.append(storeToTemp(dest, value: result, type: "double"))
        registerTypes[dest] = "double"
        return lines
    }

    /// Inline listSetFloat: bitcast double to i64, GEP into RockitList.data[index], store
    private func emitInlineListSetFloat(args: [String]) -> [String] {
        guard args.count >= 3 else { return [] }
        var lines: [String] = []
        let listPtr = loadArgAsPtr(args[0], lines: &lines)
        let idx = loadArgAsI64(args[1], lines: &lines)

        // Load the double value and bitcast to i64 for storage
        let valTmp = nextSSA()
        lines.append("\(valTmp) = load double, ptr \(addrOf(args[2]))")
        let val = nextSSA()
        lines.append("\(val) = bitcast double \(valTmp) to i64")

        // Bounds check: idx < size
        let sizeAddr = nextSSA()
        lines.append("\(sizeAddr) = getelementptr i8, ptr \(listPtr), i64 8")
        let size = nextSSA()
        lines.append("\(size) = load i64, ptr \(sizeAddr), !tbaa !3")
        let ok = nextSSA()
        lines.append("\(ok) = icmp ult i64 \(idx), \(size)")
        let okLabel = "list.ok.\(labelCounter)"
        let oobLabel = "list.oob.\(labelCounter)"
        labelCounter += 1
        lines.append("br i1 \(ok), label %\(okLabel), label %\(oobLabel), !prof !5")
        lines.append("\(oobLabel):")
        let oobIdx = internString("list index out of bounds")
        lines.append("call void @rockit_panic(ptr \(oobIdx))")
        lines.append("unreachable")
        lines.append("\(okLabel):")

        // Inline GEP store
        let dataAddr = nextSSA()
        lines.append("\(dataAddr) = getelementptr i8, ptr \(listPtr), i64 24")
        let dataPtr = nextSSA()
        lines.append("\(dataPtr) = load ptr, ptr \(dataAddr), !tbaa !3")
        let elemAddr = nextSSA()
        lines.append("\(elemAddr) = getelementptr i64, ptr \(dataPtr), i64 \(idx)")
        lines.append("store i64 \(val), ptr \(elemAddr), !tbaa !4")

        return lines
    }

    /// Inline byteArrayGet: load byte at arr+16+index, zero-extend to i64
    /// ByteArray layout: [refCount:i64, size:i64, data:byte...]
    private func emitInlineByteArrayGet(dest: String?, args: [String]) -> [String] {
        guard let dest = dest, args.count >= 2 else { return [] }
        var lines: [String] = []
        let arrPtr = loadArgAsPtr(args[0], lines: &lines)
        let idx = loadArgAsI64(args[1], lines: &lines)

        // Bounds check: idx < size (unsigned comparison catches negative indices too)
        let sizeAddr = nextSSA()
        lines.append("\(sizeAddr) = getelementptr i8, ptr \(arrPtr), i64 8")
        let size = nextSSA()
        lines.append("\(size) = load i64, ptr \(sizeAddr), !tbaa !3")
        let ok = nextSSA()
        lines.append("\(ok) = icmp ult i64 \(idx), \(size)")
        let okLabel = "ba.ok.\(labelCounter)"
        let oobLabel = "ba.oob.\(labelCounter)"
        labelCounter += 1
        lines.append("br i1 \(ok), label %\(okLabel), label %\(oobLabel), !prof !5")
        lines.append("\(oobLabel):")
        let oobMsg = internString("byteArray index out of bounds")
        lines.append("call void @rockit_panic(ptr \(oobMsg))")
        lines.append("unreachable")
        lines.append("\(okLabel):")

        // Load byte at offset 16 + index
        let dataBase = nextSSA()
        lines.append("\(dataBase) = getelementptr i8, ptr \(arrPtr), i64 16")
        let byteAddr = nextSSA()
        lines.append("\(byteAddr) = getelementptr i8, ptr \(dataBase), i64 \(idx)")
        let byteVal = nextSSA()
        lines.append("\(byteVal) = load i8, ptr \(byteAddr), !tbaa !4")
        let result = nextSSA()
        lines.append("\(result) = zext i8 \(byteVal) to i64")

        lines.append(storeToTemp(dest, value: result, type: "i64"))
        registerTypes[dest] = "i64"
        knownIntTemps.insert(dest)
        return lines
    }

    /// Inline byteArraySet: truncate value to i8, store at arr+16+index
    private func emitInlineByteArraySet(args: [String]) -> [String] {
        guard args.count >= 3 else { return [] }
        var lines: [String] = []
        let arrPtr = loadArgAsPtr(args[0], lines: &lines)
        let idx = loadArgAsI64(args[1], lines: &lines)
        let val = loadArgAsI64(args[2], lines: &lines)

        // Bounds check
        let sizeAddr = nextSSA()
        lines.append("\(sizeAddr) = getelementptr i8, ptr \(arrPtr), i64 8")
        let size = nextSSA()
        lines.append("\(size) = load i64, ptr \(sizeAddr), !tbaa !3")
        let ok = nextSSA()
        lines.append("\(ok) = icmp ult i64 \(idx), \(size)")
        let okLabel = "ba.ok.\(labelCounter)"
        let oobLabel = "ba.oob.\(labelCounter)"
        labelCounter += 1
        lines.append("br i1 \(ok), label %\(okLabel), label %\(oobLabel), !prof !5")
        lines.append("\(oobLabel):")
        let oobMsg = internString("byteArray index out of bounds")
        lines.append("call void @rockit_panic(ptr \(oobMsg))")
        lines.append("unreachable")
        lines.append("\(okLabel):")

        // Truncate and store
        let truncVal = nextSSA()
        lines.append("\(truncVal) = trunc i64 \(val) to i8")
        let dataBase = nextSSA()
        lines.append("\(dataBase) = getelementptr i8, ptr \(arrPtr), i64 16")
        let byteAddr = nextSSA()
        lines.append("\(byteAddr) = getelementptr i8, ptr \(dataBase), i64 \(idx)")
        lines.append("store i8 \(truncVal), ptr \(byteAddr), !tbaa !4")

        return lines
    }

    /// Emit listCreateFilled(size, value) — bulk list allocation
    private func emitListCreateFilled(dest: String?, args: [String]) -> [String] {
        guard let dest = dest, args.count >= 2 else { return [] }
        var lines: [String] = []
        let size = loadArgAsI64(args[0], lines: &lines)
        let value = loadArgAsI64(args[1], lines: &lines)
        let result = nextSSA()
        lines.append("\(result) = call ptr @rockit_list_create_filled(i64 \(size), i64 \(value))")
        lines.append(storeToTemp(dest, value: result, type: "ptr"))
        registerTypes[dest] = "ptr"
        // Track as heap-allocated for ARC
        if let flag = arcFlags[dest] {
            lines.append("store i1 true, ptr \(flag)")
        }
        return lines
    }

    /// Emit a native collection call with ptr first arg and i64 remaining args
    private func emitNativeCollectionCall(dest: String?, nativeFn: String, args: [String], retType: String) -> [String] {
        var lines: [String] = []
        // First arg is the collection (ptr)
        var argStrs: [String] = []
        for (i, arg) in args.enumerated() {
            if i == 0 {
                let ptr = loadArgAsPtr(arg, lines: &lines)
                argStrs.append("ptr \(ptr)")
            } else {
                let val = loadArgAsI64(arg, lines: &lines)
                argStrs.append("i64 \(val)")
            }
        }
        let argList = argStrs.joined(separator: ", ")
        if let dest = dest {
            let resultTmp = nextSSA()
            lines.append("\(resultTmp) = call \(retType) @\(nativeFn)(\(argList))")
            let destType = typeOf(dest)
            if retType != destType {
                if retType == "ptr" && destType == "i64" {
                    let conv = nextSSA()
                    lines.append("\(conv) = ptrtoint ptr \(resultTmp) to i64")
                    lines.append(storeToTemp(dest, value: conv, type: destType))
                } else if retType == "i64" && destType == "ptr" {
                    let conv = nextSSA()
                    lines.append("\(conv) = inttoptr i64 \(resultTmp) to ptr")
                    lines.append(storeToTemp(dest, value: conv, type: destType))
                } else {
                    lines.append(storeToTemp(dest, value: resultTmp, type: retType))
                }
            } else {
                lines.append(storeToTemp(dest, value: resultTmp, type: retType))
            }
        } else {
            lines.append("call \(retType) @\(nativeFn)(\(argList))")
        }
        return lines
    }

    /// Emit a native listClear call (void, single ptr arg)
    private func emitNativeListClear(args: [String]) -> [String] {
        guard args.count >= 1 else { return [] }
        var lines: [String] = []
        let listPtr = loadArgAsPtr(args[0], lines: &lines)
        externalDecls.insert("declare void @rockit_list_clear(ptr)")
        lines.append("call void @rockit_list_clear(ptr \(listPtr))")
        return lines
    }

    /// Emit a native collection call returning i1 (bool)
    private func emitNativeCollectionCallBool(dest: String?, nativeFn: String, args: [String]) -> [String] {
        var lines: [String] = []
        var argStrs: [String] = []
        for (i, arg) in args.enumerated() {
            if i == 0 {
                let ptr = loadArgAsPtr(arg, lines: &lines)
                argStrs.append("ptr \(ptr)")
            } else {
                let val = loadArgAsI64(arg, lines: &lines)
                argStrs.append("i64 \(val)")
            }
        }
        let argList = argStrs.joined(separator: ", ")
        if let dest = dest {
            let resultTmp = nextSSA()
            lines.append("\(resultTmp) = call i8 @\(nativeFn)(\(argList))")
            let destType = typeOf(dest)
            if destType == "i1" {
                let trunc = nextSSA()
                lines.append("\(trunc) = trunc i8 \(resultTmp) to i1")
                lines.append(storeToTemp(dest, value: trunc, type: "i1"))
            } else if destType == "i64" {
                let ext = nextSSA()
                lines.append("\(ext) = zext i8 \(resultTmp) to i64")
                lines.append(storeToTemp(dest, value: ext, type: "i64"))
            } else {
                lines.append(storeToTemp(dest, value: resultTmp, type: "i8"))
            }
        }
        return lines
    }

    /// Emit mapCreate() — returns i64 (StringMap handle)
    private func emitStringMapCreate(dest: String?) -> [String] {
        guard let dest = dest else { return [] }
        var lines: [String] = []
        let tmp = nextSSA()
        lines.append("\(tmp) = call i64 @mapCreate()")
        lines.append(storeToTemp(dest, value: tmp, type: "i64"))
        registerTypes[dest] = "i64"
        return lines
    }

    /// Emit mapPut(i64, ptr, i64) — string-keyed map put
    private func emitStringMapPut(args: [String]) -> [String] {
        guard args.count >= 3 else { return [] }
        var lines: [String] = []
        let mapVal = loadArgAsI64(args[0], lines: &lines)
        let key = loadArgAsPtr(args[1], lines: &lines)
        let val = loadArgAsI64(args[2], lines: &lines)
        lines.append("call i64 @mapPut(i64 \(mapVal), ptr \(key), i64 \(val))")
        return lines
    }

    /// Emit mapGet(i64, ptr) — string-keyed map get
    private func emitStringMapGet(dest: String?, args: [String]) -> [String] {
        guard args.count >= 2 else { return [] }
        var lines: [String] = []
        let mapVal = loadArgAsI64(args[0], lines: &lines)
        let key = loadArgAsPtr(args[1], lines: &lines)
        if let dest = dest {
            let tmp = nextSSA()
            lines.append("\(tmp) = call i64 @mapGet(i64 \(mapVal), ptr \(key))")
            lines.append(storeToTemp(dest, value: tmp, type: "i64"))
        } else {
            lines.append("call i64 @mapGet(i64 \(mapVal), ptr \(key))")
        }
        return lines
    }

    /// Emit mapKeys(i64) — string-keyed map keys
    private func emitStringMapKeys(dest: String?, args: [String]) -> [String] {
        guard args.count >= 1 else { return [] }
        var lines: [String] = []
        let mapVal = loadArgAsI64(args[0], lines: &lines)
        if let dest = dest {
            let tmp = nextSSA()
            lines.append("\(tmp) = call i64 @mapKeys(i64 \(mapVal))")
            lines.append(storeToTemp(dest, value: tmp, type: "i64"))
        } else {
            lines.append("call i64 @mapKeys(i64 \(mapVal))")
        }
        return lines
    }

    // MARK: - Collection Builtins

    private func emitListOf(dest: String?, args: [String]) -> [String] {
        guard let dest = dest else { return [] }
        var lines: [String] = []
        let listTmp = nextSSA()
        lines.append("\(listTmp) = call ptr @rockit_list_create()")
        for arg in args {
            let argType = typeOf(arg)
            let valTmp = nextSSA()
            lines.append("\(valTmp) = load \(argType), ptr \(addrOf(arg))")
            // Convert to i64 for storage
            if argType == "ptr" {
                let castTmp = nextSSA()
                lines.append("\(castTmp) = ptrtoint ptr \(valTmp) to i64")
                lines.append("call void @rockit_list_append(ptr \(listTmp), i64 \(castTmp))")
            } else if argType == "i1" {
                let extTmp = nextSSA()
                lines.append("\(extTmp) = zext i1 \(valTmp) to i64")
                lines.append("call void @rockit_list_append(ptr \(listTmp), i64 \(extTmp))")
            } else if argType == "double" {
                let castTmp = nextSSA()
                lines.append("\(castTmp) = bitcast double \(valTmp) to i64")
                lines.append("call void @rockit_list_append(ptr \(listTmp), i64 \(castTmp))")
            } else {
                lines.append("call void @rockit_list_append(ptr \(listTmp), i64 \(valTmp))")
            }
        }
        lines.append(contentsOf: emitOldTempRelease(dest: dest, kind: .list))
        lines.append(storeToTemp(dest, value: listTmp, type: "ptr"))
        trackHeapTemp(dest, kind: .list)
        if let flag = arcFlags[dest] { lines.append("store i1 1, ptr \(flag)") }
        return lines
    }

    private func emitMapOf(dest: String?, args: [String]) -> [String] {
        guard let dest = dest else { return [] }
        var lines: [String] = []
        let mapTmp = nextSSA()
        lines.append("\(mapTmp) = call i64 @mapCreate()")
        // mapOf takes pairs: key1, val1, key2, val2, ...
        var i = 0
        while i + 1 < args.count {
            let keyTmp = nextSSA()
            let valTmp = nextSSA()
            lines.append("\(keyTmp) = load i64, ptr \(addrOf(args[i]))")
            lines.append("\(valTmp) = load i64, ptr \(addrOf(args[i+1]))")
            // Key is a string pointer — convert i64 to ptr for mapPut
            let keyPtr = nextSSA()
            lines.append("\(keyPtr) = inttoptr i64 \(keyTmp) to ptr")
            lines.append("call i64 @mapPut(i64 \(mapTmp), ptr \(keyPtr), i64 \(valTmp))")
            i += 2
        }
        lines.append(contentsOf: emitOldTempRelease(dest: dest, kind: .map))
        lines.append(storeToTemp(dest, value: mapTmp, type: "i64"))
        trackHeapTemp(dest, kind: .map)
        if let flag = arcFlags[dest] { lines.append("store i1 1, ptr \(flag)") }
        return lines
    }

    // MARK: - Print Builtin

    private func emitPrintCall(function: String, args: [String]) -> [String] {
        guard let arg = args.first else {
            return ["call void @rockit_println_null()"]
        }

        let argType = typeOf(arg)
        let tmp = nextSSA()
        let prefix = function == "println" ? "rockit_println" : "rockit_print"

        switch argType {
        case "i64":
            if knownIntTemps.contains(arg) {
                // Known integer — safe to use typed _int (avoids false positive in _any)
                return [
                    "\(tmp) = load i64, ptr \(addrOf(arg))",
                    "call void @\(prefix)_int(i64 \(tmp))"
                ]
            }
            // Unknown i64 — may be a string pointer; use _any for auto-detection
            return [
                "\(tmp) = load i64, ptr \(addrOf(arg))",
                "call void @\(prefix)_any(i64 \(tmp))"
            ]
        case "double":
            return [
                "\(tmp) = load double, ptr \(addrOf(arg))",
                "call void @\(prefix)_float(double \(tmp))"
            ]
        case "i1":
            return [
                "\(tmp) = load i1, ptr \(addrOf(arg))",
                "call void @\(prefix)_bool(i1 \(tmp))"
            ]
        case "ptr":
            return [
                "\(tmp) = load ptr, ptr \(addrOf(arg))",
                "call void @\(prefix)_string(ptr \(tmp))"
            ]
        default:
            return [
                "\(tmp) = load i64, ptr \(addrOf(arg))",
                "call void @\(prefix)_any(i64 \(tmp))"
            ]
        }
    }

    // MARK: - toString Builtin

    private func emitToStringCall(dest: String?, args: [String]) -> [String] {
        guard let dest = dest, let arg = args.first else { return [] }

        let argType = typeOf(arg)
        let tmp = nextSSA()
        let resultTmp = nextSSA()

        switch argType {
        case "i64":
            // In Stage 1 code, i64 may actually be a string pointer stored as integer.
            // Use the runtime's toString which handles both cases.
            // NOT tracked as owned: toString may return an existing string pointer
            // without retaining (heuristic-based detection), so releasing at exit
            // would free a string we don't own.
            return [
                "\(tmp) = load i64, ptr \(addrOf(arg))",
                "\(resultTmp) = call ptr @toString(i64 \(tmp))",
                storeToTemp(dest, value: resultTmp, type: "ptr")
            ]
        case "double":
            trackHeapTemp(dest, kind: .string)
            var result = emitOldTempRelease(dest: dest, kind: .string)
            result.append("\(tmp) = load double, ptr \(addrOf(arg))")
            result.append("\(resultTmp) = call ptr @rockit_float_to_string(double \(tmp))")
            result.append(storeToTemp(dest, value: resultTmp, type: "ptr"))
            if let flag = arcFlags[dest] { result.append("store i1 1, ptr \(flag)") }
            return result
        case "i1":
            trackHeapTemp(dest, kind: .string)
            var result = emitOldTempRelease(dest: dest, kind: .string)
            result.append("\(tmp) = load i1, ptr \(addrOf(arg))")
            result.append("\(resultTmp) = call ptr @rockit_bool_to_string(i1 \(tmp))")
            result.append(storeToTemp(dest, value: resultTmp, type: "ptr"))
            if let flag = arcFlags[dest] { result.append("store i1 1, ptr \(flag)") }
            return result
        case "ptr":
            // Already a string pointer — just copy (no new allocation, no ARC tracking)
            return [
                "\(tmp) = load ptr, ptr \(addrOf(arg))",
                storeToTemp(dest, value: tmp, type: "ptr")
            ]
        default:
            trackHeapTemp(dest, kind: .string)
            var result = emitOldTempRelease(dest: dest, kind: .string)
            result.append("\(tmp) = load i64, ptr \(addrOf(arg))")
            result.append("\(resultTmp) = call ptr @rockit_int_to_string(i64 \(tmp))")
            result.append(storeToTemp(dest, value: resultTmp, type: "ptr"))
            if let flag = arcFlags[dest] { result.append("store i1 1, ptr \(flag)") }
            return result
        }
    }

    // MARK: - Virtual Call

    /// Resolve a method name to its fully-qualified name (e.g., "sum" → "Point.sum")
    /// by searching the type declarations for a matching method.
    private func resolveMethodName(_ method: String) -> String {
        // If already qualified (contains "."), use as-is
        if method.contains(".") { return method }
        // Search type declarations for a method matching this name.
        // Prefer concrete classes (those with fields) over interfaces (no fields).
        var interfaceMatch: String? = nil
        for (typeName, decl) in typeDecls {
            if decl.methods.contains("\(typeName).\(method)") {
                if !decl.fields.isEmpty || decl.isActor {
                    // Concrete class — return immediately
                    return "\(typeName).\(method)"
                } else {
                    // Interface — save as fallback
                    interfaceMatch = "\(typeName).\(method)"
                }
            }
        }
        return interfaceMatch ?? method
    }

    /// Check if a method is a known collection builtin and emit the C runtime call directly.
    private func emitCollectionMethod(dest: String?, object: String, method: String, args: [String]) -> [String]? {
        // Map method names to C runtime functions
        let methodMap: [String: (cName: String, retType: String)] = [
            "size":        ("rockit_list_size",     "i64"),
            "get":         ("rockit_list_get",      "i64"),
            "set":         ("rockit_list_set",      "void"),
            "add":         ("rockit_list_append",   "void"),
            "isEmpty":     ("rockit_list_is_empty", "i1"),
            "containsKey": ("rockit_map_contains_key", "i1"),
            "put":         ("rockit_map_put",       "void"),
        ]

        guard let info = methodMap[method] else { return nil }

        var lines: [String] = []
        let objTmp = nextSSA()
        lines.append("\(objTmp) = load ptr, ptr \(addrOf(object))")

        var argParts: [String] = ["ptr \(objTmp)"]
        for arg in args {
            let argType = typeOf(arg)
            let tmp = nextSSA()
            lines.append("\(tmp) = load \(argType), ptr \(addrOf(arg))")
            if argType == "ptr" {
                let castTmp = nextSSA()
                lines.append("\(castTmp) = ptrtoint ptr \(tmp) to i64")
                argParts.append("i64 \(castTmp)")
            } else if argType == "i1" {
                let extTmp = nextSSA()
                lines.append("\(extTmp) = zext i1 \(tmp) to i64")
                argParts.append("i64 \(extTmp)")
            } else {
                argParts.append("i64 \(tmp)")
            }
        }

        let argList = argParts.joined(separator: ", ")
        if let dest = dest, info.retType != "void" {
            let resultTmp = nextSSA()
            lines.append("\(resultTmp) = call \(info.retType) @\(info.cName)(\(argList))")
            // ARC: retain values returned by collection get (borrowed from container)
            // Uses temp write barrier to safely release previous value in loops
            if method == "get" && info.retType == "i64" {
                lines.append(contentsOf: emitTempRetainBarrier(dest: dest, newValI64: resultTmp, kind: .unknown))
            }
            lines.append(storeToTemp(dest, value: resultTmp, type: info.retType))
        } else {
            lines.append("call void @\(info.cName)(\(argList))")
        }

        return lines
    }

    private func emitVirtualCall(dest: String?, object: String, method: String, args: [String]) -> [String] {
        // Check if this is a user-defined method BEFORE trying collection dispatch.
        // Otherwise, generic method names like "get" get hijacked to rockit_list_get.
        let isUserMethod = resolveMethodName(method) != method

        if !isUserMethod {
            // Try collection method dispatch
            if let result = emitCollectionMethod(dest: dest, object: object, method: method, args: args) {
                return result
            }
        }

        // Check if this method needs dynamic dispatch (polymorphic resolution)
        if let dispatchResult = emitDynamicDispatch(dest: dest, object: object, method: method, args: args) {
            return dispatchResult
        }

        // Static dispatch: resolve method to qualified name and call with `this` as first arg
        return emitStaticMethodCall(dest: dest, object: object, method: method, args: args)
    }

    /// Emit a static (non-polymorphic) method call.
    private func emitStaticMethodCall(dest: String?, object: String, method: String, args: [String]) -> [String] {
        var lines: [String] = []
        var argStrs: [String] = []

        let objTmp = nextSSA()
        lines.append("\(objTmp) = load ptr, ptr \(addrOf(object))")
        argStrs.append("ptr \(objTmp)")

        for arg in args {
            let argType = typeOf(arg)
            let tmp = nextSSA()
            lines.append("\(tmp) = load \(argType), ptr \(addrOf(arg))")
            argStrs.append("\(argType) \(tmp)")
        }

        let argList = argStrs.joined(separator: ", ")
        let qualifiedMethod = resolveMethodName(method)
        let funcName = llvmFunctionName(qualifiedMethod)

        if let dest = dest {
            let retType: String
            if let sig = functionSignatures[qualifiedMethod] {
                let lt = llvmType(sig)
                retType = lt != "void" ? lt : typeOf(dest)
            } else {
                retType = typeOf(dest)
            }
            let resultTmp = nextSSA()
            lines.append("\(resultTmp) = call \(retType) @\(funcName)(\(argList))")
            lines.append(storeToTemp(dest, value: resultTmp, type: retType))
        } else {
            lines.append("call void @\(funcName)(\(argList))")
        }

        return lines
    }

    /// Emit dynamic dispatch: load the object's runtime type name, compare against
    /// each known subclass, and branch to the correct method implementation.
    /// Returns nil if no dynamic dispatch is needed.
    private func emitDynamicDispatch(dest: String?, object: String, method: String, args: [String]) -> [String]? {
        // Collect all types that implement a method with this name
        var allImplementors: [(typeName: String, qualifiedMethod: String)] = []
        for (typeName, decl) in typeDecls {
            let qm = "\(typeName).\(method)"
            if decl.methods.contains(qm) {
                allImplementors.append((typeName: typeName, qualifiedMethod: qm))
            }
        }

        // If 0 or 1 types implement this method, no dynamic dispatch needed
        guard allImplementors.count > 1 else { return nil }

        // Check if any of these types are in a class hierarchy relationship
        // Find the common sealed parent (if any)
        var sealedParent: String? = nil
        for (typeName, _) in allImplementors {
            if let decl = typeDecls[typeName], let parent = decl.parentType {
                if let parentDecl = typeDecls[parent], !parentDecl.sealedSubclasses.isEmpty {
                    sealedParent = parent
                    break
                }
            }
        }

        // If no sealed parent relationship, check if one implementor *is* the sealed parent
        if sealedParent == nil {
            for (typeName, _) in allImplementors {
                if let decl = typeDecls[typeName], !decl.sealedSubclasses.isEmpty {
                    sealedParent = typeName
                    break
                }
            }
        }

        let implementations: [(typeName: String, funcName: String, qualifiedMethod: String)]
        let baseFuncName: String

        if let parentName = sealedParent, let parentDecl = typeDecls[parentName] {
            // Sealed class hierarchy dispatch
            var impls: [(typeName: String, funcName: String, qualifiedMethod: String)] = []
            for subclass in parentDecl.sealedSubclasses {
                let subMethod = "\(subclass).\(method)"
                if functionSignatures[subMethod] != nil || typeDecls[subclass]?.methods.contains(subMethod) == true {
                    impls.append((typeName: subclass, funcName: llvmFunctionName(subMethod), qualifiedMethod: subMethod))
                }
            }
            guard !impls.isEmpty else { return nil }

            let baseMethod = "\(parentName).\(method)"
            if functionSignatures[baseMethod] != nil || typeDecls[parentName]?.methods.contains(baseMethod) == true {
                baseFuncName = llvmFunctionName(baseMethod)
            } else {
                baseFuncName = impls[0].funcName
            }
            implementations = impls
        } else {
            // Interface polymorphism: multiple concrete types implement the same method
            // Filter to only types with actual function implementations
            var concreteImpls: [(typeName: String, funcName: String, qualifiedMethod: String)] = []
            for impl in allImplementors {
                let qm = impl.qualifiedMethod
                if functionSignatures[qm] != nil {
                    concreteImpls.append((typeName: impl.typeName, funcName: llvmFunctionName(qm), qualifiedMethod: qm))
                }
            }
            guard concreteImpls.count > 1 else { return nil }
            implementations = concreteImpls
            baseFuncName = concreteImpls[0].funcName
        }

        var lines: [String] = []

        // Load object pointer and arguments
        let objTmp = nextSSA()
        lines.append("\(objTmp) = load ptr, ptr \(addrOf(object))")

        var argStrs: [String] = []
        argStrs.append("ptr \(objTmp)")
        for arg in args {
            let argType = typeOf(arg)
            let tmp = nextSSA()
            lines.append("\(tmp) = load \(argType), ptr \(addrOf(arg))")
            argStrs.append("\(argType) \(tmp)")
        }
        let argList = argStrs.joined(separator: ", ")

        // Determine return type from first available implementation
        let retType: String
        if let dest = dest {
            let refMethod = implementations[0].qualifiedMethod
            if let sig = functionSignatures[refMethod] {
                let lt = llvmType(sig)
                retType = lt != "void" ? lt : typeOf(dest)
            } else {
                retType = typeOf(dest)
            }
        } else {
            retType = "void"
        }

        // Load the runtime type name from the object
        let typeNamePtr = nextSSA()
        lines.append("\(typeNamePtr) = call ptr @rockit_object_get_type_name(ptr \(objTmp))")

        // Generate if-else chain for each subclass
        let dispatchId = nextLabelCounter()
        let mergeLabel = "dispatch.merge.\(dispatchId)"

        for (i, impl) in implementations.enumerated() {
            let checkLabel = "dispatch.check.\(dispatchId).\(i)"
            let callLabel = "dispatch.call.\(dispatchId).\(i)"
            let nextLabel = i + 1 < implementations.count
                ? "dispatch.check.\(dispatchId).\(i + 1)"
                : "dispatch.default.\(dispatchId)"

            // Intern the subclass type name
            let subTypeGlobal = internTypeName(impl.typeName)

            lines.append("br label %\(checkLabel)")
            lines.append("\(checkLabel):")
            // strcmp the runtime type name against this subclass name
            let cmpTmp = nextSSA()
            lines.append("\(cmpTmp) = call i8 @rockit_is_type(ptr \(objTmp), ptr \(subTypeGlobal))")
            let cmpBool = nextSSA()
            lines.append("\(cmpBool) = trunc i8 \(cmpTmp) to i1")

            // But we want exact match, not subtype match.
            // Use strcmp-like logic: compare type name pointers
            // Actually, for dispatch we want the *most specific* type.
            // Since sealed subclasses are leaves, rockit_is_type with the subclass name
            // will only match exact type (subclasses of subclasses aren't allowed in sealed).
            lines.append("br i1 \(cmpBool), label %\(callLabel), label %\(nextLabel)")

            lines.append("\(callLabel):")
            if retType != "void" {
                let resTmp = nextSSA()
                lines.append("\(resTmp) = call \(retType) @\(impl.funcName)(\(argList))")
                if let dest = dest {
                    lines.append(storeToTemp(dest, value: resTmp, type: retType))
                }
            } else {
                lines.append("call void @\(impl.funcName)(\(argList))")
            }
            lines.append("br label %\(mergeLabel)")
        }

        // Default: call the base class implementation
        let defaultLabel = "dispatch.default.\(dispatchId)"
        lines.append("\(defaultLabel):")
        if retType != "void" {
            let resTmp = nextSSA()
            lines.append("\(resTmp) = call \(retType) @\(baseFuncName)(\(argList))")
            if let dest = dest {
                lines.append(storeToTemp(dest, value: resTmp, type: retType))
            }
        } else {
            lines.append("call void @\(baseFuncName)(\(argList))")
        }
        lines.append("br label %\(mergeLabel)")

        lines.append("\(mergeLabel):")
        return lines
    }

    // MARK: - String Concat

    /// Load a concat part and convert to ptr (string) if needed.
    /// Returns (value, isOwned) — isOwned is true when a new string was allocated
    /// (toString conversion), false when the value is a borrowed reference from an alloca.
    private func loadAsString(_ part: String, into lines: inout [String]) -> (String, Bool) {
        let partType = typeOf(part)
        let raw = nextSSA()
        lines.append("\(raw) = load \(partType), ptr \(addrOf(part))")
        switch partType {
        case "ptr":
            return (raw, false)  // borrowed reference — do NOT release
        case "i64":
            let conv = nextSSA()
            lines.append("\(conv) = call ptr @rockit_int_to_string(i64 \(raw))")
            return (conv, true)
        case "double":
            let conv = nextSSA()
            lines.append("\(conv) = call ptr @rockit_float_to_string(double \(raw))")
            return (conv, true)
        case "i1":
            let conv = nextSSA()
            lines.append("\(conv) = call ptr @rockit_bool_to_string(i1 \(raw))")
            return (conv, true)
        default:
            // Treat unknown types as i64 → int_to_string
            let conv = nextSSA()
            lines.append("\(conv) = call ptr @rockit_int_to_string(i64 \(raw))")
            return (conv, true)
        }
    }

    private func emitStringConcat(dest: String, parts: [String]) -> [String] {
        guard !parts.isEmpty else {
            return [storeToTemp(dest, value: "null", type: "ptr")]
        }

        var lines: [String] = []

        if parts.count == 1 {
            let (str, _) = loadAsString(parts[0], into: &lines)
            lines.append(storeToTemp(dest, value: str, type: "ptr"))
            return lines
        }

        // For 2 parts, use simple binary concat (common case, avoids alloca overhead)
        if parts.count == 2 {
            let (lhsStr, lhsOwned) = loadAsString(parts[0], into: &lines)
            let (rhsStr, rhsOwned) = loadAsString(parts[1], into: &lines)
            let result = nextSSA()
            lines.append("\(result) = call ptr @rockit_string_concat(ptr \(lhsStr), ptr \(rhsStr))")
            if lhsOwned { lines.append(contentsOf: emitInlineStringRelease(lhsStr)) }
            if rhsOwned { lines.append(contentsOf: emitInlineStringRelease(rhsStr)) }
            lines.append(contentsOf: emitOldTempRelease(dest: dest, kind: .string))
            lines.append(storeToTemp(dest, value: result, type: "ptr"))
            trackHeapTemp(dest, kind: .string)
            if let flag = arcFlags[dest] { lines.append("store i1 1, ptr \(flag)") }
            return lines
        }

        // For 3+ parts, use single-allocation concat_n: one alloc, N memcpys, no intermediates
        externalDecls.insert("declare ptr @rockit_string_concat_n(i64, ptr)")
        var ptrs: [(String, Bool)] = []  // (ptr value, is owned)
        for part in parts {
            ptrs.append(loadAsString(part, into: &lines))
        }
        // Build stack array of string pointers
        let arrTmp = nextSSA()
        lines.append("\(arrTmp) = alloca [\(parts.count) x ptr]")
        for (i, (ptr, _)) in ptrs.enumerated() {
            let gep = nextSSA()
            lines.append("\(gep) = getelementptr ptr, ptr \(arrTmp), i64 \(i)")
            lines.append("store ptr \(ptr), ptr \(gep)")
        }
        let result = nextSSA()
        lines.append("\(result) = call ptr @rockit_string_concat_n(i64 \(parts.count), ptr \(arrTmp))")
        // Release any owned intermediates (toString conversions)
        for (ptr, owned) in ptrs {
            if owned { lines.append(contentsOf: emitInlineStringRelease(ptr)) }
        }
        lines.append(contentsOf: emitOldTempRelease(dest: dest, kind: .string))
        lines.append(storeToTemp(dest, value: result, type: "ptr"))
        trackHeapTemp(dest, kind: .string)
        if let flag = arcFlags[dest] { lines.append("store i1 1, ptr \(flag)") }
        return lines
    }

    /// Emit string concat_consume for self-append pattern (s = s + expr).
    /// Takes ownership of LHS — no extra retain, function handles release if needed.
    private func emitStringConcatConsume(dest: String, rhs: String, targetVar: String) -> [String] {
        var lines: [String] = []
        externalDecls.insert("declare ptr @rockit_string_concat_consume(ptr, ptr)")

        // Load LHS directly from variable (no retain — concat_consume takes ownership)
        let lhsPtr = nextSSA()
        lines.append("\(lhsPtr) = load ptr, ptr \(addrOf(targetVar))")

        // Load RHS
        let (rhsStr, rhsOwned) = loadAsString(rhs, into: &lines)

        // Call consume variant
        let result = nextSSA()
        lines.append("\(result) = call ptr @rockit_string_concat_consume(ptr \(lhsPtr), ptr \(rhsStr))")

        // Release RHS if it was an owned intermediate (toString conversion)
        if rhsOwned { lines.append(contentsOf: emitInlineStringRelease(rhsStr)) }

        // Store result directly to variable (ownership transferred from function)
        lines.append("store ptr \(result), ptr \(addrOf(targetVar))")

        // Also store to dest temp so any subsequent reads see the right value
        lines.append(storeToTemp(dest, value: result, type: "ptr"))

        return lines
    }

    // MARK: - Object Operations

    /// Look up field index from type declarations.
    private func fieldIndex(typeName: String, fieldName: String) -> Int? {
        guard let typeDecl = typeDecls[typeName] else { return nil }
        return typeDecl.fields.firstIndex(where: { $0.0 == fieldName })
    }

    /// Look up field type from type declarations.
    private func fieldType(typeName: String, fieldName: String) -> String {
        guard let typeDecl = typeDecls[typeName] else { return "i64" }
        if let field = typeDecl.fields.first(where: { $0.0 == fieldName }) {
            let lt = llvmType(field.1)
            return lt != "void" ? lt : "i64"
        }
        return "i64"
    }

    /// Determine the class name for an object temp by looking at newObject instructions.
    private func classNameForObject(_ temp: String) -> String? {
        // This is set during emitFunction processing
        // For `this` in methods, use currentClassName
        if temp == "this" {
            return currentClassName
        }
        return nil
    }

    private func emitNewObject(dest: String, typeName: String, args: [String]) -> [String] {
        var lines: [String] = []
        let typeNameGlobal = typeNamePool[typeName] ?? internTypeName(typeName)
        let fieldCount = typeDecls[typeName]?.fields.count ?? args.count
        let valueType = isValueType(typeName)
        let isStackPromoted = stackPromotedTemps.contains(dest)

        if valueType {
            // Allocate: stack or heap
            let objTmp: String
            if isStackPromoted, let stackAlloca = stackAllocaNames[dest] {
                // Stack allocation: use pre-allocated prologue alloca
                objTmp = stackAlloca
                // Skip header initialization — value types use inline GEP at
                // hardcoded offsets, ARC is skipped, and escape analysis
                // guarantees no runtime function receives the object.
                // Header fields (typeName, RC, fieldCount, ptrFieldBits)
                // are never read for stack-promoted value types.
            } else {
                objTmp = nextSSA()
                lines.append("\(objTmp) = call ptr @rockit_object_alloc(ptr \(typeNameGlobal), i32 \(fieldCount))")
            }

            // Value type: inline GEP field stores, no ARC retain (all fields are primitives)
            for (i, arg) in args.enumerated() {
                let argType = typeOf(arg)
                let valTmp = nextSSA()
                lines.append("\(valTmp) = load \(argType), ptr \(addrOf(arg))")
                let valI64: String
                if argType == "i1" {
                    let extTmp = nextSSA()
                    lines.append("\(extTmp) = zext i1 \(valTmp) to i64")
                    valI64 = extTmp
                } else if argType == "double" {
                    let castTmp = nextSSA()
                    lines.append("\(castTmp) = bitcast double \(valTmp) to i64")
                    valI64 = castTmp
                } else {
                    valI64 = valTmp
                }
                // Inline GEP: offset 24 (header) + i * 8
                let fieldOffset = 24 + i * 8
                let fieldGep = nextSSA()
                lines.append("\(fieldGep) = getelementptr i8, ptr \(objTmp), i64 \(fieldOffset)")
                lines.append("store i64 \(valI64), ptr \(fieldGep)")
            }

            if !isStackPromoted {
                // ptrFieldBits = 0 (no pointer fields) — stack path sets this in header init above
                let bitsGep = nextSSA()
                lines.append("\(bitsGep) = getelementptr i8, ptr \(objTmp), i64 20")
                lines.append("store i32 0, ptr \(bitsGep)")
            }

            if isStackPromoted {
                // Stack promoted: just store the pointer, no ARC tracking
                lines.append(storeToTemp(dest, value: objTmp, type: "ptr"))
            } else {
                lines.append(contentsOf: emitOldTempRelease(dest: dest, kind: .object))
                lines.append(storeToTemp(dest, value: objTmp, type: "ptr"))
                trackHeapTemp(dest, kind: .object)
                if let flag = arcFlags[dest] { lines.append("store i1 1, ptr \(flag)") }
            }
        } else {
            // Regular object: runtime calls + ARC
            let objTmp = nextSSA()
            lines.append("\(objTmp) = call ptr @rockit_object_alloc(ptr \(typeNameGlobal), i32 \(fieldCount))")
            var ptrFieldBits: UInt32 = 0

            if typeDecls[typeName] != nil {
                for (i, arg) in args.enumerated() {
                    let argType = typeOf(arg)
                    let valTmp = nextSSA()
                    lines.append("\(valTmp) = load \(argType), ptr \(addrOf(arg))")
                    let valI64: String
                    if argType == "ptr" {
                        let castTmp = nextSSA()
                        lines.append("\(castTmp) = ptrtoint ptr \(valTmp) to i64")
                        valI64 = castTmp
                        if i < 32 { ptrFieldBits |= UInt32(1 << i) }
                    } else if argType == "i1" {
                        let extTmp = nextSSA()
                        lines.append("\(extTmp) = zext i1 \(valTmp) to i64")
                        valI64 = extTmp
                    } else if argType == "double" {
                        let castTmp = nextSSA()
                        lines.append("\(castTmp) = bitcast double \(valTmp) to i64")
                        valI64 = castTmp
                    } else {
                        valI64 = valTmp
                    }
                    if argType == "ptr" || !knownIntTemps.contains(arg) {
                        lines.append("call void @rockit_retain_value(i64 \(valI64))")
                    }
                    lines.append("call void @rockit_object_set_field(ptr \(objTmp), i32 \(i), i64 \(valI64))")
                }
            } else {
                ptrFieldBits = 0
                for (i, arg) in args.enumerated() {
                    let valTmp = nextSSA()
                    lines.append("\(valTmp) = load i64, ptr \(addrOf(arg))")
                    lines.append("call void @rockit_retain_value(i64 \(valTmp))")
                    lines.append("call void @rockit_object_set_field(ptr \(objTmp), i32 \(i), i64 \(valTmp))")
                }
            }

            if typeDecls[typeName] != nil {
                let bitsGep = nextSSA()
                lines.append("\(bitsGep) = getelementptr i8, ptr \(objTmp), i64 20")
                lines.append("store i32 \(ptrFieldBits), ptr \(bitsGep)")
            }

            lines.append(contentsOf: emitOldTempRelease(dest: dest, kind: .object))
            lines.append(storeToTemp(dest, value: objTmp, type: "ptr"))
            trackHeapTemp(dest, kind: .object)
            if let flag = arcFlags[dest] { lines.append("store i1 1, ptr \(flag)") }
        }
        return lines
    }

    private func emitGetField(dest: String, object: String, fieldName: String) -> [String] {
        var lines: [String] = []

        // Load the object pointer
        let objTmp = nextSSA()
        lines.append("\(objTmp) = load ptr, ptr \(addrOf(object))")

        // Determine field index
        // Try currentClassName for method context, otherwise scan typeDecls
        let idx: Int
        if let cn = currentClassName, let i = fieldIndex(typeName: cn, fieldName: fieldName) {
            idx = i
        } else {
            // Search all type decls for this field
            var found: Int? = nil
            for (_, decl) in typeDecls {
                if let i = decl.fields.firstIndex(where: { $0.0 == fieldName }) {
                    found = i
                    break
                }
            }
            idx = found ?? 0
        }

        // Value type fast path: inline GEP, no function call, no ARC
        let vtName = valueTypeForTemp(object)
        if vtName != nil {
            let fieldOffset = 24 + idx * 8
            let fieldGep = nextSSA()
            lines.append("\(fieldGep) = getelementptr i8, ptr \(objTmp), i64 \(fieldOffset)")
            let rawTmp = nextSSA()
            lines.append("\(rawTmp) = load i64, ptr \(fieldGep)")

            let destType = typeOf(dest)
            if destType == "i1" {
                let castTmp = nextSSA()
                lines.append("\(castTmp) = trunc i64 \(rawTmp) to i1")
                lines.append(storeToTemp(dest, value: castTmp, type: "i1"))
            } else if destType == "double" {
                let castTmp = nextSSA()
                lines.append("\(castTmp) = bitcast i64 \(rawTmp) to double")
                lines.append(storeToTemp(dest, value: castTmp, type: "double"))
            } else {
                lines.append(storeToTemp(dest, value: rawTmp, type: "i64"))
            }
            return lines
        }

        // Regular object: runtime call + ARC
        let rawTmp = nextSSA()
        lines.append("\(rawTmp) = call i64 @rockit_object_get_field(ptr \(objTmp), i32 \(idx))")

        let destType = typeOf(dest)
        if destType == "ptr" {
            lines.append(contentsOf: emitTempRetainBarrier(dest: dest, newValI64: rawTmp, kind: .unknown))
            let castTmp = nextSSA()
            lines.append("\(castTmp) = inttoptr i64 \(rawTmp) to ptr")
            lines.append(storeToTemp(dest, value: castTmp, type: "ptr"))
        } else if destType == "i1" {
            let castTmp = nextSSA()
            lines.append("\(castTmp) = trunc i64 \(rawTmp) to i1")
            lines.append(storeToTemp(dest, value: castTmp, type: "i1"))
        } else if destType == "double" {
            let castTmp = nextSSA()
            lines.append("\(castTmp) = bitcast i64 \(rawTmp) to double")
            lines.append(storeToTemp(dest, value: castTmp, type: "double"))
        } else {
            lines.append(storeToTemp(dest, value: rawTmp, type: "i64"))
        }

        return lines
    }

    private func emitSetField(object: String, fieldName: String, value: String) -> [String] {
        var lines: [String] = []

        // Load the object pointer
        let objTmp = nextSSA()
        lines.append("\(objTmp) = load ptr, ptr \(addrOf(object))")

        // Determine field index
        let idx: Int
        if let cn = currentClassName, let i = fieldIndex(typeName: cn, fieldName: fieldName) {
            idx = i
        } else {
            var found: Int? = nil
            for (_, decl) in typeDecls {
                if let i = decl.fields.firstIndex(where: { $0.0 == fieldName }) {
                    found = i
                    break
                }
            }
            idx = found ?? 0
        }

        // Value type fast path: inline GEP store, no ARC
        let vtName = valueTypeForTemp(object)
        if vtName != nil {
            let valType = typeOf(value)
            let valTmp = nextSSA()
            lines.append("\(valTmp) = load \(valType), ptr \(addrOf(value))")
            let valI64: String
            if valType == "i1" {
                let extTmp = nextSSA()
                lines.append("\(extTmp) = zext i1 \(valTmp) to i64")
                valI64 = extTmp
            } else if valType == "double" {
                let castTmp = nextSSA()
                lines.append("\(castTmp) = bitcast double \(valTmp) to i64")
                valI64 = castTmp
            } else {
                valI64 = valTmp
            }
            let fieldOffset = 24 + idx * 8
            let fieldGep = nextSSA()
            lines.append("\(fieldGep) = getelementptr i8, ptr \(objTmp), i64 \(fieldOffset)")
            lines.append("store i64 \(valI64), ptr \(fieldGep)")
            return lines
        }

        // Regular object: ARC write barrier + runtime calls
        let oldVal = nextSSA()
        lines.append("\(oldVal) = call i64 @rockit_object_get_field(ptr \(objTmp), i32 \(idx))")

        let valType = typeOf(value)
        let valTmp = nextSSA()
        lines.append("\(valTmp) = load \(valType), ptr \(addrOf(value))")

        let newValI64: String
        if valType == "ptr" {
            let castTmp = nextSSA()
            lines.append("\(castTmp) = ptrtoint ptr \(valTmp) to i64")
            newValI64 = castTmp
        } else if valType == "i1" {
            let extTmp = nextSSA()
            lines.append("\(extTmp) = zext i1 \(valTmp) to i64")
            newValI64 = extTmp
        } else if valType == "double" {
            let castTmp = nextSSA()
            lines.append("\(castTmp) = bitcast double \(valTmp) to i64")
            newValI64 = castTmp
        } else {
            newValI64 = valTmp
        }

        lines.append("call void @rockit_retain_value(i64 \(newValI64))")
        lines.append("call void @rockit_object_set_field(ptr \(objTmp), i32 \(idx), i64 \(newValI64))")
        lines.append("call void @rockit_release_value(i64 \(oldVal))")

        return lines
    }

    // MARK: - Type Mapping

    private func llvmType(_ type: MIRType) -> String {
        switch type {
        case .int, .int64:      return "i64"
        case .int32:            return "i32"
        case .float, .float64, .double: return "double"
        case .bool:             return "i1"
        case .string:           return "ptr"
        case .unit:             return "void"
        case .nothing:          return "void"
        case .nullable:         return "ptr"
        case .reference:        return "ptr"
        case .function:         return "ptr"
        }
    }

    private func llvmArithType(_ type: MIRType) -> String {
        switch type {
        case .float, .float64, .double: return "double"
        case .int32:                    return "i32"
        default:                        return "i64"
        }
    }

    private func isFloatType(_ type: MIRType) -> Bool {
        switch type {
        case .float, .float64, .double: return true
        default: return false
        }
    }

    private func inferCallReturnType(_ function: String) -> String {
        // Check user-defined functions first
        if let retType = functionSignatures[function] {
            let lt = llvmType(retType)
            return lt != "void" ? lt : "void"
        }

        // Builtins
        switch function {
        case "toString", "intToString", "floatToString", "boolToString",
             "formatFloat",
             "stringSubstring", "substring", "charAt", "stringTrim",
             "stringReplace", "stringToLower", "stringToUpper",
             "stringConcat", "stringFromCharCodes", "readLine",
             "fileRead", "getEnv", "intToChar":
            return "ptr"
        case "stringLength", "charCodeAt", "stringIndexOf", "toInt",
             "charToInt", "abs", "min", "max", "listSize", "mapSize",
             "byteArrayCreate", "byteArrayCreateFilled", "byteArrayGet", "byteArraySize":
            return "i64"
        case "listOf", "mutableListOf", "mapOf", "mutableMapOf",
             "listCreate", "listCreateFilled", "mapCreate":
            return "ptr"
        case "toFloat", "listGetFloat",
             "rockit_math_sqrt", "rockit_math_sin", "rockit_math_cos",
             "rockit_math_tan", "rockit_math_pow", "rockit_math_floor",
             "rockit_math_ceil", "rockit_math_round", "rockit_math_log",
             "rockit_math_exp", "rockit_math_abs", "rockit_math_atan2":
            return "double"
        case "startsWith", "endsWith", "stringContains", "isDigit",
             "isLetter", "isWhitespace", "isLetterOrDigit",
             "fileExists", "fileWrite", "fileDelete",
             "isList", "isMap", "listContains", "mapContainsKey",
             "listIsEmpty", "mapIsEmpty":
            return "i1"
        default:
            return "i64"
        }
    }

    // MARK: - Name Helpers

    private func llvmFunctionName(_ name: String) -> String {
        // Replace dots with underscores for method names like "Class.method"
        return name.replacingOccurrences(of: ".", with: "_")
    }

    private func llvmLabel(_ label: String) -> String {
        // Replace dots with underscores in block labels
        return label.replacingOccurrences(of: ".", with: "_")
    }

    private func nextSSA() -> String {
        let name = "%_\(ssaCounter)"
        ssaCounter += 1
        return name
    }

    private func nextLabelCounter() -> Int {
        let val = labelCounter
        labelCounter += 1
        return val
    }

    /// Get the LLVM alloca address for a MIR register name.
    private func addrOf(_ name: String) -> String {
        if let mapped = registerMap[name] {
            return mapped
        }
        // For module-level globals (enum singletons, top-level vars)
        if moduleGlobals[name] != nil {
            return "@\(name)"
        }
        // For param references like "param.x"
        if name.hasPrefix("param.") {
            let paramName = String(name.dropFirst(6))
            if let mapped = registerMap["param.\(paramName)"] {
                return mapped
            }
            return "%p.\(paramName)"
        }
        // For temps like "%t0"
        if name.hasPrefix("%t") {
            return "%\(name.dropFirst(1))"
        }
        return "%\(name)"
    }

    /// Get the LLVM type for a MIR register.
    private func typeOf(_ name: String) -> String {
        if let t = registerTypes[name] {
            return t
        }
        // Module-level globals have known types
        if let t = moduleGlobals[name] {
            return t
        }
        if name.hasPrefix("param.") {
            if let t = registerTypes[name] {
                return t
            }
            let paramName = String(name.dropFirst(6))
            if let pt = currentParams.first(where: { $0.0 == paramName }) {
                return llvmType(pt.1)
            }
        }
        return "i64"
    }

    /// Store a value to a temp's alloca.
    private func storeToTemp(_ temp: String, value: String, type: String) -> String {
        return "store \(type) \(value), ptr \(addrOf(temp))"
    }

    // MARK: - String Escaping

    private func llvmEscapeString(_ s: String) -> String {
        var result = ""
        for byte in s.utf8 {
            switch byte {
            case 0x20...0x21, 0x23...0x5B, 0x5D...0x7E:
                // Printable ASCII except " (0x22) and \ (0x5C)
                result.append(Character(UnicodeScalar(byte)))
            default:
                result += String(format: "\\%02X", byte)
            }
        }
        return result
    }
}

// MARK: - Compile to Native

extension LLVMCodeGen {

    /// Compile a .rok source file to a native executable.
    /// Returns the path to the native binary, or throws on error.
    public static func compileToNative(
        source: String,
        fileName: String,
        outputPath: String,
        runtimeDir: String,
        libPaths: [String] = [],
        emitLLVM: Bool = false
    ) throws -> String {
        let diagnostics = DiagnosticEngine()

        // Frontend pipeline
        print("  Parsing \(fileName)...", terminator: "")
        fflush(stdout)
        let lexer = Lexer(source: source, fileName: fileName, diagnostics: diagnostics)
        let tokens = lexer.tokenize()
        let parser = Parser(tokens: tokens, diagnostics: diagnostics)
        let parsedAST = parser.parse()

        // Resolve imports
        let sourceDir = (fileName as NSString).deletingLastPathComponent
        let importResolver = ImportResolver(sourceDir: sourceDir, libPaths: libPaths, diagnostics: diagnostics)
        let ast = importResolver.resolve(parsedAST)
        print(" done")

        print("  Type checking...", terminator: "")
        fflush(stdout)
        let checker = TypeChecker(ast: ast, diagnostics: diagnostics)
        let typeResult = checker.check()

        if diagnostics.hasErrors {
            print("")
            diagnostics.dump()
            throw LLVMCodeGenError.frontendErrors(diagnostics.errorCount)
        }
        print(" done")

        // MIR pipeline
        print("  Lowering to MIR...", terminator: "")
        fflush(stdout)
        let lowering = MIRLowering(typeCheckResult: typeResult)
        let unoptimized = lowering.lower()
        let optimizer = MIROptimizer()
        let optimized = optimizer.optimize(unoptimized)
        print(" done")

        // LLVM IR emission
        print("  Generating LLVM IR...", terminator: "")
        fflush(stdout)
        let codeGen = LLVMCodeGen()
        let llvmIR = codeGen.emit(module: optimized)

        // Write .ll file
        let llPath = outputPath + ".ll"
        try llvmIR.write(toFile: llPath, atomically: true, encoding: .utf8)
        print(" done")

        if emitLLVM {
            return llPath
        }

        // Find clang
        guard let clangPath = Platform.findClang() else {
            throw LLVMCodeGenError.clangNotFound
        }

        // Find runtime object file — prefer pre-built .o, fall back to compiling .c
        let prebuiltObj = Platform.pathJoin(runtimeDir, "rockit_runtime.o")
        let runtimeObjPath: String
        if FileManager.default.fileExists(atPath: prebuiltObj) {
            print("  Linking native binary...", terminator: "")
            fflush(stdout)
            runtimeObjPath = prebuiltObj
        } else {
            // Fallback: compile C runtime
            let runtimeSrcPath = Platform.pathJoin(runtimeDir, "rockit_runtime.c")
            print("  Compiling runtime...", terminator: "")
            fflush(stdout)
            runtimeObjPath = Platform.tempFilePath("rockit_runtime" + Platform.objectFileExtension)
            let compileRuntime = Process()
            compileRuntime.executableURL = URL(fileURLWithPath: clangPath)
            var compileArgs = ["-c", "-O2", "-I", runtimeDir, runtimeSrcPath, "-o", runtimeObjPath]
            #if os(macOS) || os(iOS)
            // Homebrew OpenSSL include path
            let brewOpenSSLInclude = "/opt/homebrew/opt/openssl@3/include"
            if FileManager.default.fileExists(atPath: brewOpenSSLInclude) {
                compileArgs += ["-I", brewOpenSSLInclude]
            }
            #endif
            compileRuntime.arguments = compileArgs
            try compileRuntime.run()
            compileRuntime.waitUntilExit()
            guard compileRuntime.terminationStatus == 0 else {
                throw LLVMCodeGenError.linkFailed
            }
            print(" done")
            print("  Linking native binary...", terminator: "")
            fflush(stdout)
        }

        let finalOutputPath = Platform.withExeExtension(outputPath)
        let link = Process()
        link.executableURL = URL(fileURLWithPath: clangPath)
        var linkArgs = ["-O2", llPath, runtimeObjPath, "-o", finalOutputPath]
        // OpenSSL libraries
        linkArgs += ["-lssl", "-lcrypto"]
        #if os(macOS) || os(iOS)
        let brewOpenSSLLib = "/opt/homebrew/opt/openssl@3/lib"
        if FileManager.default.fileExists(atPath: brewOpenSSLLib) {
            linkArgs += ["-L", brewOpenSSLLib]
        }
        #endif
        #if os(Linux)
        linkArgs += ["-lm"]  // Linux requires explicit libm for math functions
        #endif
        link.arguments = linkArgs
        try link.run()
        link.waitUntilExit()
        guard link.terminationStatus == 0 else {
            throw LLVMCodeGenError.linkFailed
        }
        print(" done")

        return finalOutputPath
    }
}

// MARK: - Errors

public enum LLVMCodeGenError: Error, CustomStringConvertible {
    case frontendErrors(Int)
    case linkFailed
    case clangNotFound

    public var description: String {
        switch self {
        case .frontendErrors(let count):
            return "\(count) frontend error(s)"
        case .linkFailed:
            return "failed to link native binary"
        case .clangNotFound:
            return "clang not found. Install LLVM/Clang and ensure it is on your PATH"
        }
    }
}
