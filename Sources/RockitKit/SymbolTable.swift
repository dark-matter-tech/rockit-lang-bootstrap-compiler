// SymbolTable.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - Symbol Kind

/// What kind of binding a symbol represents
public enum SymbolKind: Equatable {
    case variable(isMutable: Bool)
    case function
    case parameter
    case typeDeclaration
    case typeAlias
    case typeParameter
    case enumEntry
}

// MARK: - Symbol

/// A named binding in the symbol table
public struct Symbol {
    public let name: String
    public let type: Type
    public let kind: SymbolKind
    public let span: SourceSpan?

    public init(name: String, type: Type, kind: SymbolKind, span: SourceSpan? = nil) {
        self.name = name
        self.type = type
        self.kind = kind
        self.span = span
    }
}

// MARK: - Type Declaration Info

/// Extra information about a type declaration (class, sealed class, enum, interface, etc.)
public struct TypeDeclInfo {
    public let name: String
    public let typeParameters: [String]
    /// Variance annotation per type parameter (nil = invariant, .out = covariant, .in = contravariant)
    public let typeParameterVariances: [Variance?]
    public var sealedSubclasses: [String]
    public var enumEntries: [String]
    public var members: [Symbol]
    public var superTypes: [String]
    public var defaultMethods: Set<String>

    public init(name: String, typeParameters: [String] = [],
                typeParameterVariances: [Variance?] = [],
                sealedSubclasses: [String] = [], enumEntries: [String] = [],
                members: [Symbol] = [], superTypes: [String] = [],
                defaultMethods: Set<String> = []) {
        self.name = name
        self.typeParameters = typeParameters
        self.typeParameterVariances = typeParameterVariances
        self.sealedSubclasses = sealedSubclasses
        self.enumEntries = enumEntries
        self.members = members
        self.superTypes = superTypes
        self.defaultMethods = defaultMethods
    }
}

// MARK: - Scope

/// A lexical scope containing symbols. Scopes form a parent chain for lookup.
public final class Scope {
    public let parent: Scope?
    private var symbols: [String: Symbol] = [:]

    public init(parent: Scope? = nil) {
        self.parent = parent
    }

    /// Define a symbol in this scope. Returns false if already defined in THIS scope.
    @discardableResult
    public func define(_ symbol: Symbol) -> Bool {
        if symbols[symbol.name] != nil {
            return false
        }
        symbols[symbol.name] = symbol
        return true
    }

    /// Look up a symbol by name, walking the parent chain.
    public func lookup(_ name: String) -> Symbol? {
        if let sym = symbols[name] {
            return sym
        }
        return parent?.lookup(name)
    }

    /// Look up a symbol only in this scope (no parent walk).
    public func lookupLocal(_ name: String) -> Symbol? {
        return symbols[name]
    }

    /// Update an existing symbol in this scope (for type inference).
    public func update(_ symbol: Symbol) {
        symbols[symbol.name] = symbol
    }
}

// MARK: - Symbol Table

/// Manages the scope stack and type declaration registry.
public final class SymbolTable {
    public private(set) var globalScope: Scope
    public private(set) var currentScope: Scope
    private var scopeStack: [Scope] = []

    /// Registry of type declarations (classes, interfaces, enums, etc.)
    public private(set) var typeDeclarations: [String: TypeDeclInfo] = [:]

    public init() {
        let builtinScope = Scope()
        self.globalScope = builtinScope
        self.currentScope = builtinScope
        populateBuiltins()
        // Push a user scope on top of builtins so user declarations can shadow builtins
        let userScope = Scope(parent: builtinScope)
        self.globalScope = userScope
        self.currentScope = userScope
    }

    /// Push a new child scope
    public func pushScope() {
        let child = Scope(parent: currentScope)
        scopeStack.append(currentScope)
        currentScope = child
    }

    /// Pop back to the parent scope
    public func popScope() {
        guard let parent = scopeStack.popLast() else { return }
        currentScope = parent
    }

    /// Define a symbol in the current scope
    @discardableResult
    public func define(_ symbol: Symbol) -> Bool {
        return currentScope.define(symbol)
    }

    /// Look up a symbol by name (walks scope chain)
    public func lookup(_ name: String) -> Symbol? {
        return currentScope.lookup(name)
    }

    /// Register a type declaration
    public func registerType(_ info: TypeDeclInfo) {
        typeDeclarations[info.name] = info
    }

    /// Look up a type declaration by name
    public func lookupType(_ name: String) -> TypeDeclInfo? {
        return typeDeclarations[name]
    }

    /// Add a sealed subclass to a parent sealed class
    public func addSealedSubclass(parent: String, child: String) {
        typeDeclarations[parent]?.sealedSubclasses.append(child)
    }

    /// Add a super type to a child type declaration
    public func addSuperType(child: String, parent: String) {
        if typeDeclarations[child] != nil && !typeDeclarations[child]!.superTypes.contains(parent) {
            typeDeclarations[child]!.superTypes.append(parent)
        }
    }

    // MARK: - Builtins

    private func populateBuiltins() {
        // Primitive types
        let builtinTypes: [(String, Type)] = [
            ("Int",       .int),
            ("Int32",     .int32),
            ("Int64",     .int64),
            ("Float",     .float),
            ("Float64",   .float64),
            ("Double",    .double),
            ("Bool",      .bool),
            ("String",    .string),
            ("ByteArray", .byteArray),
            ("Unit",      .unit),
            ("Nothing",   .nothing),
            ("Any",       .any),
        ]

        for (name, type) in builtinTypes {
            globalScope.define(Symbol(name: name, type: type, kind: .typeDeclaration))
            typeDeclarations[name] = TypeDeclInfo(name: name)
        }

        // Common generic types (List, Map, Set) — registered as type declarations
        // with type parameters so they can be resolved
        let genericTypes: [(String, [String])] = [
            ("List", ["T"]),
            ("MutableList", ["T"]),
            ("Map", ["K", "V"]),
            ("MutableMap", ["K", "V"]),
            ("Set", ["T"]),
            ("MutableSet", ["T"]),
            ("Pair", ["A", "B"]),
            ("Result", ["T", "E"]),
        ]

        for (name, typeParams) in genericTypes {
            let type = Type.classType(name: name, typeArguments: [])
            globalScope.define(Symbol(name: name, type: type, kind: .typeDeclaration))
            typeDeclarations[name] = TypeDeclInfo(name: name, typeParameters: typeParams)
        }

        // Built-in functions
        let builtinFunctions: [(String, Type)] = [
            // Output / Input
            ("println",  .function(parameterTypes: [.string], returnType: .unit)),
            ("print",    .function(parameterTypes: [.string], returnType: .unit)),
            ("readLine", .function(parameterTypes: [], returnType: .nullable(.string))),

            // String conversion
            ("toString",      .function(parameterTypes: [.typeParameter(name: "T", bound: nil)], returnType: .string)),
            ("toInt",         .function(parameterTypes: [.typeParameter(name: "T", bound: nil)], returnType: .int)),
            ("intToString",   .function(parameterTypes: [.int], returnType: .string)),
            ("floatToString", .function(parameterTypes: [.float64], returnType: .string)),
            ("formatFloat", .function(parameterTypes: [.float64, .int], returnType: .string)),
            ("toFloat", .function(parameterTypes: [.int], returnType: .float64)),
            ("listGetFloat", .function(parameterTypes: [.classType(name: "List", typeArguments: []), .int], returnType: .float64)),
            ("listSetFloat", .function(parameterTypes: [.classType(name: "List", typeArguments: []), .int, .float64], returnType: .unit)),

            // Existing string ops (registered in runtime but missing from type checker)
            ("stringLength",    .function(parameterTypes: [.string], returnType: .int)),
            ("stringSubstring", .function(parameterTypes: [.string, .int, .int], returnType: .string)),

            // Math (integer)
            ("abs", .function(parameterTypes: [.int], returnType: .int)),
            ("min", .function(parameterTypes: [.int, .int], returnType: .int)),
            ("max", .function(parameterTypes: [.int, .int], returnType: .int)),

            // Math (floating point) — delegate to C runtime
            ("rockit_math_sqrt",  .function(parameterTypes: [.double], returnType: .double)),
            ("rockit_math_sin",   .function(parameterTypes: [.double], returnType: .double)),
            ("rockit_math_cos",   .function(parameterTypes: [.double], returnType: .double)),
            ("rockit_math_tan",   .function(parameterTypes: [.double], returnType: .double)),
            ("rockit_math_pow",   .function(parameterTypes: [.double, .double], returnType: .double)),
            ("rockit_math_floor", .function(parameterTypes: [.double], returnType: .double)),
            ("rockit_math_ceil",  .function(parameterTypes: [.double], returnType: .double)),
            ("rockit_math_round", .function(parameterTypes: [.double], returnType: .double)),
            ("rockit_math_log",   .function(parameterTypes: [.double], returnType: .double)),
            ("rockit_math_exp",   .function(parameterTypes: [.double], returnType: .double)),
            ("rockit_math_abs",   .function(parameterTypes: [.double], returnType: .double)),
            ("rockit_math_atan2", .function(parameterTypes: [.double, .double], returnType: .double)),

            // Diagnostics
            ("panic",  .function(parameterTypes: [], returnType: .nothing)),
            ("typeOf", .function(parameterTypes: [.typeParameter(name: "T", bound: nil)], returnType: .string)),

            // Probe Test Framework — Assertions
            ("assert",              .function(parameterTypes: [.bool], returnType: .unit)),
            ("assertEquals",        .function(parameterTypes: [.typeParameter(name: "T", bound: nil), .typeParameter(name: "T", bound: nil)], returnType: .unit)),
            ("assertNotEquals",     .function(parameterTypes: [.typeParameter(name: "T", bound: nil), .typeParameter(name: "T", bound: nil)], returnType: .unit)),
            ("assertTrue",          .function(parameterTypes: [.bool], returnType: .unit)),
            ("assertFalse",         .function(parameterTypes: [.bool], returnType: .unit)),
            ("assertNull",          .function(parameterTypes: [.nullable(.typeParameter(name: "T", bound: nil))], returnType: .unit)),
            ("assertNotNull",       .function(parameterTypes: [.nullable(.typeParameter(name: "T", bound: nil))], returnType: .unit)),
            ("assertEqualsStr",     .function(parameterTypes: [.string, .string], returnType: .unit)),
            ("assertGreaterThan",   .function(parameterTypes: [.int, .int], returnType: .unit)),
            ("assertLessThan",      .function(parameterTypes: [.int, .int], returnType: .unit)),
            ("assertStringContains", .function(parameterTypes: [.string, .string], returnType: .unit)),
            ("assertStartsWith",    .function(parameterTypes: [.string, .string], returnType: .unit)),
            ("assertEndsWith",      .function(parameterTypes: [.string, .string], returnType: .unit)),
            ("fail",                .function(parameterTypes: [], returnType: .unit)),

            // Collection constructors
            ("listOf",  .function(parameterTypes: [], returnType: .classType(name: "List", typeArguments: []))),
            ("mapOf",   .function(parameterTypes: [], returnType: .classType(name: "Map", typeArguments: []))),
            ("setOf",   .function(parameterTypes: [], returnType: .classType(name: "Set", typeArguments: []))),
            ("mutableListOf", .function(parameterTypes: [], returnType: .classType(name: "MutableList", typeArguments: []))),
            ("mutableMapOf",  .function(parameterTypes: [], returnType: .classType(name: "MutableMap", typeArguments: []))),
        ]

        for (name, type) in builtinFunctions {
            globalScope.define(Symbol(name: name, type: type, kind: .function))
        }

        // Collection builtin functions
        let collectionBuiltins: [(String, Type)] = [
            // List operations
            ("listCreate",   .function(parameterTypes: [],
                                       returnType: .classType(name: "List", typeArguments: []))),
            ("listCreateFilled", .function(parameterTypes: [.int, .typeParameter(name: "T", bound: nil)],
                                       returnType: .classType(name: "List", typeArguments: []))),
            ("listAppend",   .function(parameterTypes: [.classType(name: "List", typeArguments: []), .typeParameter(name: "T", bound: nil)],
                                       returnType: .unit)),
            ("listGet",      .function(parameterTypes: [.classType(name: "List", typeArguments: []), .int],
                                       returnType: .typeParameter(name: "T", bound: nil))),
            ("listSet",      .function(parameterTypes: [.classType(name: "List", typeArguments: []), .int, .typeParameter(name: "T", bound: nil)],
                                       returnType: .unit)),
            ("listSize",     .function(parameterTypes: [.classType(name: "List", typeArguments: [])],
                                       returnType: .int)),
            ("listRemoveAt", .function(parameterTypes: [.classType(name: "List", typeArguments: []), .int],
                                       returnType: .typeParameter(name: "T", bound: nil))),
            ("listContains", .function(parameterTypes: [.classType(name: "List", typeArguments: []), .typeParameter(name: "T", bound: nil)],
                                       returnType: .bool)),
            ("listIndexOf",  .function(parameterTypes: [.classType(name: "List", typeArguments: []), .typeParameter(name: "T", bound: nil)],
                                       returnType: .int)),
            ("listIsEmpty",  .function(parameterTypes: [.classType(name: "List", typeArguments: [])],
                                       returnType: .bool)),
            ("listClear",    .function(parameterTypes: [.classType(name: "List", typeArguments: [])],
                                       returnType: .unit)),

            // HashMap operations
            ("mapCreate",      .function(parameterTypes: [],
                                         returnType: .classType(name: "Map", typeArguments: []))),
            ("mapPut",         .function(parameterTypes: [.classType(name: "Map", typeArguments: []), .typeParameter(name: "K", bound: nil), .typeParameter(name: "V", bound: nil)],
                                         returnType: .unit)),
            ("mapGet",         .function(parameterTypes: [.classType(name: "Map", typeArguments: []), .typeParameter(name: "K", bound: nil)],
                                         returnType: .nullable(.typeParameter(name: "V", bound: nil)))),
            ("mapRemove",      .function(parameterTypes: [.classType(name: "Map", typeArguments: []), .typeParameter(name: "K", bound: nil)],
                                         returnType: .nullable(.typeParameter(name: "V", bound: nil)))),
            ("mapContainsKey", .function(parameterTypes: [.classType(name: "Map", typeArguments: []), .typeParameter(name: "K", bound: nil)],
                                         returnType: .bool)),
            ("mapKeys",        .function(parameterTypes: [.classType(name: "Map", typeArguments: [])],
                                         returnType: .classType(name: "List", typeArguments: []))),
            ("mapValues",      .function(parameterTypes: [.classType(name: "Map", typeArguments: [])],
                                         returnType: .classType(name: "List", typeArguments: []))),
            ("mapSize",        .function(parameterTypes: [.classType(name: "Map", typeArguments: [])],
                                         returnType: .int)),
            ("mapIsEmpty",     .function(parameterTypes: [.classType(name: "Map", typeArguments: [])],
                                         returnType: .bool)),
            ("mapClear",       .function(parameterTypes: [.classType(name: "Map", typeArguments: [])],
                                         returnType: .unit)),

            // ByteArray operations
            ("byteArrayCreate",      .function(parameterTypes: [.int], returnType: .int)),
            ("byteArrayCreateFilled", .function(parameterTypes: [.int, .int], returnType: .int)),
            ("byteArrayGet",         .function(parameterTypes: [.int, .int], returnType: .int)),
            ("byteArraySet",         .function(parameterTypes: [.int, .int, .int], returnType: .unit)),
            ("byteArraySize",        .function(parameterTypes: [.int], returnType: .int)),
        ]

        for (name, type) in collectionBuiltins {
            globalScope.define(Symbol(name: name, type: type, kind: .function))
        }

        // String operation builtins
        let stringBuiltins: [(String, Type)] = [
            ("charAt",          .function(parameterTypes: [.string, .int], returnType: .string)),
            ("charCodeAt",      .function(parameterTypes: [.string, .int], returnType: .int)),
            ("substring",       .function(parameterTypes: [.string, .int, .int], returnType: .string)),
            ("stringIndexOf",   .function(parameterTypes: [.string, .string], returnType: .int)),
            ("stringSplit",     .function(parameterTypes: [.string, .string],
                                         returnType: .classType(name: "List", typeArguments: []))),
            ("startsWith",      .function(parameterTypes: [.string, .string], returnType: .bool)),
            ("endsWith",        .function(parameterTypes: [.string, .string], returnType: .bool)),
            ("stringContains",  .function(parameterTypes: [.string, .string], returnType: .bool)),
            ("stringTrim",      .function(parameterTypes: [.string], returnType: .string)),
            ("stringReplace",   .function(parameterTypes: [.string, .string, .string], returnType: .string)),
            ("stringToLower",   .function(parameterTypes: [.string], returnType: .string)),
            ("stringToUpper",   .function(parameterTypes: [.string], returnType: .string)),
            ("stringConcat",    .function(parameterTypes: [.string, .string], returnType: .string)),
            ("isDigit",         .function(parameterTypes: [.string], returnType: .bool)),
            ("isLetter",        .function(parameterTypes: [.string], returnType: .bool)),
            ("isWhitespace",    .function(parameterTypes: [.string], returnType: .bool)),
            ("isLetterOrDigit", .function(parameterTypes: [.string], returnType: .bool)),
            ("charToInt",       .function(parameterTypes: [.string], returnType: .int)),
            ("intToChar",       .function(parameterTypes: [.int], returnType: .string)),
            ("stringFromCharCodes", .function(parameterTypes: [.classType(name: "List", typeArguments: [])],
                                              returnType: .string)),
        ]

        for (name, type) in stringBuiltins {
            globalScope.define(Symbol(name: name, type: type, kind: .function))
        }

        // Process builtins
        let processBuiltins: [(String, Type)] = [
            ("processArgs", .function(parameterTypes: [],
                                      returnType: .classType(name: "List", typeArguments: []))),
            ("processExit", .function(parameterTypes: [.int], returnType: .nothing)),
            ("getEnv",      .function(parameterTypes: [.string], returnType: .nullable(.string))),
            ("executablePath", .function(parameterTypes: [], returnType: .string)),
            ("platformOS",    .function(parameterTypes: [], returnType: .string)),
        ]

        for (name, type) in processBuiltins {
            globalScope.define(Symbol(name: name, type: type, kind: .function))
        }

        // File I/O builtins
        let fileBuiltins: [(String, Type)] = [
            ("fileRead",       .function(parameterTypes: [.string], returnType: .nullable(.string))),
            ("fileWrite",      .function(parameterTypes: [.string, .string], returnType: .bool)),
            ("fileWriteBytes", .function(parameterTypes: [.string, .classType(name: "List", typeArguments: [])],
                                         returnType: .unit)),
            ("fileExists",     .function(parameterTypes: [.string], returnType: .bool)),
            ("fileDelete",     .function(parameterTypes: [.string], returnType: .bool)),
        ]

        for (name, type) in fileBuiltins {
            globalScope.define(Symbol(name: name, type: type, kind: .function))
        }

        // Network, time & random builtins
        let networkBuiltins: [(String, Type)] = [
            ("tcpConnect",  .function(parameterTypes: [.string, .int], returnType: .int)),
            ("tcpSend",     .function(parameterTypes: [.int, .string], returnType: .int)),
            ("tcpRecv",     .function(parameterTypes: [.int, .int], returnType: .string)),
            ("tcpClose",    .function(parameterTypes: [.int], returnType: .unit)),
            ("currentTimeMillis", .function(parameterTypes: [], returnType: .int)),
            ("currentTimeNanos", .function(parameterTypes: [], returnType: .int)),
            ("sleepMillis", .function(parameterTypes: [.int], returnType: .unit)),
            ("randomInt",   .function(parameterTypes: [.int], returnType: .int)),
            ("epochToComponents", .function(parameterTypes: [.int],
                                            returnType: .classType(name: "Map", typeArguments: []))),
        ]

        for (name, type) in networkBuiltins {
            globalScope.define(Symbol(name: name, type: type, kind: .function))
        }

        // Security builtins (TLS, Crypto, X.509)
        let securityBuiltins: [(String, Type)] = [
            // TLS context
            ("tlsCreateContext",       .function(parameterTypes: [], returnType: .int)),
            ("tlsCreateServerContext", .function(parameterTypes: [], returnType: .int)),
            ("tlsSetCertificate",      .function(parameterTypes: [.int, .string], returnType: .int)),
            ("tlsSetPrivateKey",       .function(parameterTypes: [.int, .string], returnType: .int)),
            ("tlsSetVerifyPeer",       .function(parameterTypes: [.int, .int], returnType: .unit)),
            ("tlsSetAlpn",             .function(parameterTypes: [.int, .string], returnType: .int)),
            // TLS connection
            ("tlsConnect",     .function(parameterTypes: [.int, .string, .int], returnType: .int)),
            ("tlsSend",        .function(parameterTypes: [.int, .string], returnType: .int)),
            ("tlsRecv",        .function(parameterTypes: [.int, .int], returnType: .string)),
            ("tlsClose",       .function(parameterTypes: [.int], returnType: .unit)),
            ("tlsGetAlpn",     .function(parameterTypes: [.int], returnType: .string)),
            ("tlsGetPeerCert", .function(parameterTypes: [.int], returnType: .int)),
            // TLS server
            ("tlsListen",  .function(parameterTypes: [.int, .int], returnType: .int)),
            ("tlsAccept",  .function(parameterTypes: [.int, .int], returnType: .int)),
            // Crypto hashing
            ("cryptoSha256", .function(parameterTypes: [.string], returnType: .string)),
            ("cryptoSha1",   .function(parameterTypes: [.string], returnType: .string)),
            ("cryptoSha512", .function(parameterTypes: [.string], returnType: .string)),
            ("cryptoMd5",    .function(parameterTypes: [.string], returnType: .string)),
            // Crypto HMAC
            ("cryptoHmacSha256", .function(parameterTypes: [.string, .string], returnType: .string)),
            ("cryptoHmacSha1",   .function(parameterTypes: [.string, .string], returnType: .string)),
            // Crypto random
            ("cryptoRandomBytes", .function(parameterTypes: [.int], returnType: .string)),
            // Crypto AES
            ("cryptoAesEncrypt", .function(parameterTypes: [.string, .string, .string, .int], returnType: .string)),
            ("cryptoAesDecrypt", .function(parameterTypes: [.string, .string, .string, .int], returnType: .string)),
            // X.509
            ("x509ParsePem",      .function(parameterTypes: [.string], returnType: .int)),
            ("x509Subject",       .function(parameterTypes: [.int], returnType: .string)),
            ("x509Issuer",        .function(parameterTypes: [.int], returnType: .string)),
            ("x509NotBefore",     .function(parameterTypes: [.int], returnType: .int)),
            ("x509NotAfter",      .function(parameterTypes: [.int], returnType: .int)),
            ("x509SerialNumber",  .function(parameterTypes: [.int], returnType: .string)),
            ("x509Free",          .function(parameterTypes: [.int], returnType: .unit)),
            // Error
            ("tlsLastError", .function(parameterTypes: [], returnType: .string)),
        ]

        for (name, type) in securityBuiltins {
            globalScope.define(Symbol(name: name, type: type, kind: .function))
        }

        // Type check builtins
        let typeCheckBuiltins: [(String, Type)] = [
            ("isMap",   .function(parameterTypes: [.typeParameter(name: "T", bound: nil)], returnType: .bool)),
            ("isList",  .function(parameterTypes: [.typeParameter(name: "T", bound: nil)], returnType: .bool)),
            ("typeOf",  .function(parameterTypes: [.typeParameter(name: "T", bound: nil)], returnType: .string)),
            ("evalRockit", .function(parameterTypes: [.string], returnType: .string)),
            ("systemExec", .function(parameterTypes: [.string], returnType: .int)),
        ]

        for (name, type) in typeCheckBuiltins {
            globalScope.define(Symbol(name: name, type: type, kind: .function))
        }
    }
}
