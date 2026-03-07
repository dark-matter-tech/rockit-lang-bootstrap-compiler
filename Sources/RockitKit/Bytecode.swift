// Bytecode.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - Opcode

/// Every bytecode instruction's one-byte operation code.
public enum Opcode: UInt8 {
    // Constants
    case constInt       = 0x01
    case constFloat     = 0x02
    case constTrue      = 0x03
    case constFalse     = 0x04
    case constString    = 0x05
    case constNull      = 0x06

    // Memory
    case alloc          = 0x10
    case store          = 0x11
    case load           = 0x12
    case loadParam      = 0x13
    case loadGlobal     = 0x14
    case storeGlobal    = 0x15

    // Arithmetic
    case add            = 0x20
    case sub            = 0x21
    case mul            = 0x22
    case div            = 0x23
    case mod            = 0x24
    case neg            = 0x25

    // Comparison
    case eq             = 0x30
    case neq            = 0x31
    case lt             = 0x32
    case lte            = 0x33
    case gt             = 0x34
    case gte            = 0x35

    // Logic
    case and            = 0x40
    case or             = 0x41
    case not            = 0x42

    // Calls
    case call           = 0x50
    case vcall          = 0x51
    case callIndirect   = 0x52

    // Fields
    case getField       = 0x60
    case setField       = 0x61

    // Objects
    case newObject      = 0x70

    // Null safety
    case nullCheck      = 0x80
    case isNull         = 0x81

    // Type operations
    case typeCheck      = 0x90
    case typeCast       = 0x91

    // String
    case stringConcat   = 0xA0

    // Exception handling
    case tryBegin       = 0xB0
    case tryEnd         = 0xB1
    case throwOp        = 0xB2

    // Concurrency
    case awaitCall        = 0xC0
    case concurrentBegin  = 0xC1
    case concurrentEnd    = 0xC2

    // Terminators
    case ret            = 0xE0
    case retVoid        = 0xE1
    case jump           = 0xE2
    case branch         = 0xE3
    case unreachable    = 0xE4
}

extension Opcode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .constInt:     return "CONST_INT"
        case .constFloat:   return "CONST_FLOAT"
        case .constTrue:    return "CONST_TRUE"
        case .constFalse:   return "CONST_FALSE"
        case .constString:  return "CONST_STRING"
        case .constNull:    return "CONST_NULL"
        case .alloc:        return "ALLOC"
        case .store:        return "STORE"
        case .load:         return "LOAD"
        case .loadParam:    return "LOAD_PARAM"
        case .loadGlobal:   return "LOAD_GLOBAL"
        case .storeGlobal:  return "STORE_GLOBAL"
        case .add:          return "ADD"
        case .sub:          return "SUB"
        case .mul:          return "MUL"
        case .div:          return "DIV"
        case .mod:          return "MOD"
        case .neg:          return "NEG"
        case .eq:           return "EQ"
        case .neq:          return "NEQ"
        case .lt:           return "LT"
        case .lte:          return "LTE"
        case .gt:           return "GT"
        case .gte:          return "GTE"
        case .and:          return "AND"
        case .or:           return "OR"
        case .not:          return "NOT"
        case .call:         return "CALL"
        case .vcall:        return "VCALL"
        case .callIndirect: return "CALL_INDIRECT"
        case .getField:     return "GET_FIELD"
        case .setField:     return "SET_FIELD"
        case .newObject:    return "NEW_OBJECT"
        case .nullCheck:    return "NULL_CHECK"
        case .isNull:       return "IS_NULL"
        case .typeCheck:    return "TYPE_CHECK"
        case .typeCast:     return "TYPE_CAST"
        case .stringConcat: return "STRING_CONCAT"
        case .tryBegin:     return "TRY_BEGIN"
        case .tryEnd:       return "TRY_END"
        case .throwOp:      return "THROW"
        case .awaitCall:        return "AWAIT_CALL"
        case .concurrentBegin:  return "CONCURRENT_BEGIN"
        case .concurrentEnd:    return "CONCURRENT_END"
        case .ret:          return "RET"
        case .retVoid:      return "RET_VOID"
        case .jump:         return "JUMP"
        case .branch:       return "BRANCH"
        case .unreachable:  return "UNREACHABLE"
        }
    }
}

// MARK: - Constant Pool

/// Tag for constant pool entries.
public enum ConstantPoolKind: UInt8 {
    case string     = 0x01
    case typeName   = 0x02
    case fieldName  = 0x03
    case funcName   = 0x04
    case methodName = 0x05
    case globalName = 0x06
    case paramName  = 0x07
}

/// A single entry in the constant pool.
public struct ConstantPoolEntry {
    public let kind: ConstantPoolKind
    public let value: String

    public init(kind: ConstantPoolKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

// MARK: - Bytecode Type Tag

/// Compact type encoding for the binary format.
public enum BytecodeTypeTag: UInt8 {
    case unit       = 0x00
    case int        = 0x01
    case int32      = 0x02
    case int64      = 0x03
    case float      = 0x04
    case float64    = 0x05
    case double     = 0x06
    case bool       = 0x07
    case string     = 0x08
    case nothing    = 0x09
    case nullable   = 0x0A
    case reference  = 0x0B
    case function   = 0x0C
}

// MARK: - Bytecode Function

/// A compiled function in the bytecode module.
public struct BytecodeFunction {
    public let nameIndex: UInt16
    public let parameterCount: UInt16
    public let registerCount: UInt16
    public let returnTypeTag: BytecodeTypeTag
    public let bytecode: [UInt8]
    public let parameterInfo: [(nameIndex: UInt16, typeTag: BytecodeTypeTag)]
    /// Maps bytecode offsets to source line numbers for stack traces.
    public let lineTable: [(offset: UInt16, line: UInt16)]

    public init(
        nameIndex: UInt16,
        parameterCount: UInt16,
        registerCount: UInt16,
        returnTypeTag: BytecodeTypeTag,
        bytecode: [UInt8],
        parameterInfo: [(nameIndex: UInt16, typeTag: BytecodeTypeTag)],
        lineTable: [(offset: UInt16, line: UInt16)] = []
    ) {
        self.nameIndex = nameIndex
        self.parameterCount = parameterCount
        self.registerCount = registerCount
        self.returnTypeTag = returnTypeTag
        self.bytecode = bytecode
        self.parameterInfo = parameterInfo
        self.lineTable = lineTable
    }

    /// Look up the source line for a given bytecode offset.
    public func sourceLine(at offset: Int) -> Int? {
        var bestLine: UInt16? = nil
        for entry in lineTable {
            if entry.offset <= offset {
                bestLine = entry.line
            } else {
                break
            }
        }
        return bestLine.map { Int($0) }
    }
}

// MARK: - Bytecode Global

/// A global variable declaration in the bytecode module.
public struct BytecodeGlobal {
    public let nameIndex: UInt16
    public let typeTag: BytecodeTypeTag
    public let isMutable: Bool
    public let initializerFuncIndex: UInt16?

    public init(nameIndex: UInt16, typeTag: BytecodeTypeTag, isMutable: Bool, initializerFuncIndex: UInt16? = nil) {
        self.nameIndex = nameIndex
        self.typeTag = typeTag
        self.isMutable = isMutable
        self.initializerFuncIndex = initializerFuncIndex
    }
}

// MARK: - Bytecode Type Declaration

/// Type metadata (class, enum, interface) in the bytecode module.
public struct BytecodeTypeDecl {
    public let nameIndex: UInt16
    public let fields: [(nameIndex: UInt16, typeTag: BytecodeTypeTag)]
    public let methods: [UInt16]
    public let parentTypeIndex: UInt16?
    public let isActor: Bool

    public init(nameIndex: UInt16, fields: [(nameIndex: UInt16, typeTag: BytecodeTypeTag)], methods: [UInt16],
                parentTypeIndex: UInt16? = nil, isActor: Bool = false) {
        self.nameIndex = nameIndex
        self.fields = fields
        self.methods = methods
        self.parentTypeIndex = parentTypeIndex
        self.isActor = isActor
    }
}

// MARK: - Bytecode Module

/// The top-level bytecode container — one per compiled source file.
public struct BytecodeModule {
    public static let magic: [UInt8] = [0x52, 0x4F, 0x4B, 0x54] // "ROKT"
    public static let versionMajor: UInt16 = 1
    public static let versionMinor: UInt16 = 0

    public let constantPool: [ConstantPoolEntry]
    public let globals: [BytecodeGlobal]
    public let types: [BytecodeTypeDecl]
    public let functions: [BytecodeFunction]

    public init(
        constantPool: [ConstantPoolEntry],
        globals: [BytecodeGlobal],
        types: [BytecodeTypeDecl],
        functions: [BytecodeFunction]
    ) {
        self.constantPool = constantPool
        self.globals = globals
        self.types = types
        self.functions = functions
    }

    /// Total bytecode bytes across all functions.
    public var totalBytecodeSize: Int {
        functions.reduce(0) { $0 + $1.bytecode.count }
    }
}
