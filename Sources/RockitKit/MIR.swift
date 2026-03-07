// MIR.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - MIR Type

/// Simplified type representation for the IR back-end.
/// Unlike `Type` (semantic), `MIRType` omits type parameters, variance,
/// and other front-end concerns — only what codegen needs.
public indirect enum MIRType: Equatable {
    case int
    case int32
    case int64
    case float
    case float64
    case double
    case bool
    case string
    case unit
    case nothing
    case nullable(MIRType)
    case reference(String)
    case function([MIRType], MIRType)
}

extension MIRType {
    /// Convert a front-end `Type` to a `MIRType`.
    public static func from(_ type: Type) -> MIRType {
        switch type {
        case .int:          return .int
        case .int32:        return .int32
        case .int64:        return .int64
        case .float:        return .float
        case .float64:      return .float64
        case .double:       return .double
        case .bool:         return .bool
        case .string:       return .string
        case .byteArray:    return .reference("ByteArray")
        case .unit:         return .unit
        case .nothing:      return .nothing
        case .any:          return .reference("Any")
        case .nullType:     return .nullable(.unit)
        case .error:        return .unit

        case .nullable(let inner):
            return .nullable(MIRType.from(inner))

        case .classType(let name, _):
            return .reference(name)
        case .interfaceType(let name, _):
            return .reference(name)
        case .enumType(let name):
            return .reference(name)
        case .objectType(let name):
            return .reference(name)
        case .actorType(let name):
            return .reference(name)

        case .function(let params, let ret):
            return .function(params.map { MIRType.from($0) }, MIRType.from(ret))

        case .tuple(let elements):
            if elements.isEmpty { return .unit }
            // For Stage 0, lower tuples as their first element or unit
            return .reference("Tuple\(elements.count)")

        case .typeParameter(_, let bound):
            // Type erasure: use bound or Any
            if let bound = bound {
                return MIRType.from(bound)
            }
            return .reference("Any")
        }
    }
}

extension MIRType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .int:          return "Int"
        case .int32:        return "Int32"
        case .int64:        return "Int64"
        case .float:        return "Float"
        case .float64:      return "Float64"
        case .double:       return "Double"
        case .bool:         return "Bool"
        case .string:       return "String"
        case .unit:         return "Unit"
        case .nothing:      return "Nothing"
        case .nullable(let inner):
            return "\(inner)?"
        case .reference(let name):
            return name
        case .function(let params, let ret):
            let p = params.map { "\($0)" }.joined(separator: ", ")
            return "(\(p)) -> \(ret)"
        }
    }
}

// MARK: - MIR Instruction

/// A single MIR instruction in three-address code form.
/// Every instruction that produces a value writes to `dest` (a `%tN` temp).
public enum MIRInstruction {

    // Constants
    case constInt(dest: String, value: Int64)
    case constFloat(dest: String, value: Double)
    case constBool(dest: String, value: Bool)
    case constString(dest: String, value: String)
    case constNull(dest: String)

    // Locals
    case alloc(dest: String, type: MIRType)
    case store(dest: String, src: String)
    case load(dest: String, src: String)

    // Arithmetic
    case add(dest: String, lhs: String, rhs: String, type: MIRType)
    case sub(dest: String, lhs: String, rhs: String, type: MIRType)
    case mul(dest: String, lhs: String, rhs: String, type: MIRType)
    case div(dest: String, lhs: String, rhs: String, type: MIRType)
    case mod(dest: String, lhs: String, rhs: String, type: MIRType)
    case neg(dest: String, operand: String, type: MIRType)

    // Comparison
    case eq(dest: String, lhs: String, rhs: String, type: MIRType)
    case neq(dest: String, lhs: String, rhs: String, type: MIRType)
    case lt(dest: String, lhs: String, rhs: String, type: MIRType)
    case lte(dest: String, lhs: String, rhs: String, type: MIRType)
    case gt(dest: String, lhs: String, rhs: String, type: MIRType)
    case gte(dest: String, lhs: String, rhs: String, type: MIRType)

    // Logic
    case and(dest: String, lhs: String, rhs: String)
    case or(dest: String, lhs: String, rhs: String)
    case not(dest: String, operand: String)

    // Calls
    case call(dest: String?, function: String, args: [String])
    case virtualCall(dest: String?, object: String, method: String, args: [String])
    case callIndirect(dest: String?, functionRef: String, args: [String])

    // Fields
    case getField(dest: String, object: String, fieldName: String)
    case setField(object: String, fieldName: String, value: String)

    // Objects
    case newObject(dest: String, typeName: String, args: [String])

    // Null safety
    case nullCheck(dest: String, operand: String)
    case isNull(dest: String, operand: String)

    // Type operations
    case typeCheck(dest: String, operand: String, typeName: String)
    case typeCast(dest: String, operand: String, typeName: String)

    // String
    case stringConcat(dest: String, parts: [String])

    // Exception handling
    case tryBegin(catchLabel: String, exceptionDest: String)
    case tryEnd

    // Concurrency
    case awaitCall(dest: String?, function: String, args: [String])
    case concurrentBegin(scopeId: String)
    case concurrentEnd(scopeId: String)
}

extension MIRInstruction: CustomStringConvertible {
    public var description: String {
        switch self {
        case .constInt(let d, let v):       return "\(d) = const_int \(v)"
        case .constFloat(let d, let v):     return "\(d) = const_float \(v)"
        case .constBool(let d, let v):      return "\(d) = const_bool \(v)"
        case .constString(let d, let v):    return "\(d) = const_string \"\(v)\""
        case .constNull(let d):             return "\(d) = const_null"

        case .alloc(let d, let t):          return "\(d) = alloc \(t)"
        case .store(let d, let s):          return "store \(d), \(s)"
        case .load(let d, let s):           return "\(d) = load \(s)"

        case .add(let d, let l, let r, _):  return "\(d) = add \(l), \(r)"
        case .sub(let d, let l, let r, _):  return "\(d) = sub \(l), \(r)"
        case .mul(let d, let l, let r, _):  return "\(d) = mul \(l), \(r)"
        case .div(let d, let l, let r, _):  return "\(d) = div \(l), \(r)"
        case .mod(let d, let l, let r, _):  return "\(d) = mod \(l), \(r)"
        case .neg(let d, let o, _):         return "\(d) = neg \(o)"

        case .eq(let d, let l, let r, _):   return "\(d) = eq \(l), \(r)"
        case .neq(let d, let l, let r, _):  return "\(d) = neq \(l), \(r)"
        case .lt(let d, let l, let r, _):   return "\(d) = lt \(l), \(r)"
        case .lte(let d, let l, let r, _):  return "\(d) = lte \(l), \(r)"
        case .gt(let d, let l, let r, _):   return "\(d) = gt \(l), \(r)"
        case .gte(let d, let l, let r, _):  return "\(d) = gte \(l), \(r)"

        case .and(let d, let l, let r):     return "\(d) = and \(l), \(r)"
        case .or(let d, let l, let r):      return "\(d) = or \(l), \(r)"
        case .not(let d, let o):            return "\(d) = not \(o)"

        case .call(let d, let f, let a):
            let args = a.joined(separator: ", ")
            if let d = d {
                return "\(d) = call \(f)(\(args))"
            }
            return "call \(f)(\(args))"

        case .virtualCall(let d, let obj, let m, let a):
            let args = a.joined(separator: ", ")
            if let d = d {
                return "\(d) = vcall \(obj).\(m)(\(args))"
            }
            return "vcall \(obj).\(m)(\(args))"

        case .callIndirect(let d, let ref, let a):
            let args = a.joined(separator: ", ")
            if let d = d {
                return "\(d) = call_indirect \(ref)(\(args))"
            }
            return "call_indirect \(ref)(\(args))"

        case .getField(let d, let obj, let f):
            return "\(d) = get_field \(obj).\(f)"
        case .setField(let obj, let f, let v):
            return "set_field \(obj).\(f), \(v)"

        case .newObject(let d, let t, let a):
            let args = a.joined(separator: ", ")
            return "\(d) = new \(t)(\(args))"

        case .nullCheck(let d, let o):
            return "\(d) = null_check \(o)"
        case .isNull(let d, let o):
            return "\(d) = is_null \(o)"

        case .typeCheck(let d, let o, let t):
            return "\(d) = type_check \(o) is \(t)"
        case .typeCast(let d, let o, let t):
            return "\(d) = type_cast \(o) as \(t)"

        case .stringConcat(let d, let parts):
            return "\(d) = string_concat \(parts.joined(separator: ", "))"

        case .tryBegin(let catchLabel, let dest):
            return "try_begin catch=\(catchLabel) exc=\(dest)"
        case .tryEnd:
            return "try_end"

        case .awaitCall(let d, let f, let a):
            let args = a.joined(separator: ", ")
            if let d = d {
                return "\(d) = await \(f)(\(args))"
            }
            return "await \(f)(\(args))"

        case .concurrentBegin(let id):
            return "concurrent_begin \(id)"
        case .concurrentEnd(let id):
            return "concurrent_end \(id)"
        }
    }
}


// MARK: - MIR Terminator

/// Terminates a basic block — exactly one per block.
public enum MIRTerminator {
    case ret(String?)
    case jump(String)
    case branch(condition: String, thenLabel: String, elseLabel: String)
    case throwValue(String)
    case unreachable
}

extension MIRTerminator: CustomStringConvertible {
    public var description: String {
        switch self {
        case .ret(let val):
            if let v = val { return "ret \(v)" }
            return "ret"
        case .jump(let label):
            return "jump \(label)"
        case .branch(let cond, let t, let e):
            return "branch \(cond), \(t), \(e)"
        case .throwValue(let val):
            return "throw \(val)"
        case .unreachable:
            return "unreachable"
        }
    }
}

// MARK: - MIR Basic Block

/// A basic block: a labeled sequence of instructions ending with a terminator.
public struct MIRBasicBlock {
    public let label: String
    public var instructions: [MIRInstruction]
    public var terminator: MIRTerminator?

    public init(label: String, instructions: [MIRInstruction] = [], terminator: MIRTerminator? = nil) {
        self.label = label
        self.instructions = instructions
        self.terminator = terminator
    }
}

extension MIRBasicBlock: CustomStringConvertible {
    public var description: String {
        var lines: [String] = []
        lines.append("  \(label):")
        for inst in instructions {
            lines.append("    \(inst)")
        }
        if let term = terminator {
            lines.append("    \(term)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - MIR Function

/// A MIR function with named parameters and a sequence of basic blocks.
public struct MIRFunction {
    public let name: String
    public let parameters: [(String, MIRType)]
    public let returnType: MIRType
    public var blocks: [MIRBasicBlock]

    public init(name: String, parameters: [(String, MIRType)], returnType: MIRType, blocks: [MIRBasicBlock] = []) {
        self.name = name
        self.parameters = parameters
        self.returnType = returnType
        self.blocks = blocks
    }

    /// Total instruction count across all blocks (excluding terminators)
    public var instructionCount: Int {
        blocks.reduce(0) { $0 + $1.instructions.count }
    }
}

extension MIRFunction: CustomStringConvertible {
    public var description: String {
        let params = parameters.map { "\($0.0): \($0.1)" }.joined(separator: ", ")
        var lines: [String] = []
        lines.append("fun \(name)(\(params)) -> \(returnType) {")
        for block in blocks {
            lines.append(block.description)
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }
}

// MARK: - MIR Global

/// A top-level global variable.
public struct MIRGlobal {
    public let name: String
    public let type: MIRType
    public let isMutable: Bool
    public let initializerFunc: String?

    public init(name: String, type: MIRType, isMutable: Bool, initializerFunc: String? = nil) {
        self.name = name
        self.type = type
        self.isMutable = isMutable
        self.initializerFunc = initializerFunc
    }
}

extension MIRGlobal: CustomStringConvertible {
    public var description: String {
        let keyword = isMutable ? "var" : "val"
        var s = "global \(keyword) \(name): \(type)"
        if let initFunc = initializerFunc {
            s += " = \(initFunc)()"
        }
        return s
    }
}

// MARK: - MIR Type Declaration

/// Metadata for a class, enum, or interface in the MIR.
public struct MIRTypeDecl {
    public let name: String
    public let fields: [(String, MIRType)]
    public let methods: [String]
    public let parentType: String?
    public let sealedSubclasses: [String]
    public let isActor: Bool
    public let isValueType: Bool

    public init(name: String, fields: [(String, MIRType)] = [], methods: [String] = [],
                parentType: String? = nil, sealedSubclasses: [String] = [],
                isActor: Bool = false, isValueType: Bool = false) {
        self.name = name
        self.fields = fields
        self.methods = methods
        self.parentType = parentType
        self.sealedSubclasses = sealedSubclasses
        self.isActor = isActor
        self.isValueType = isValueType
    }
}

extension MIRTypeDecl: CustomStringConvertible {
    public var description: String {
        var lines: [String] = []
        lines.append("type \(name) {")
        for (fname, ftype) in fields {
            lines.append("  field \(fname): \(ftype)")
        }
        for method in methods {
            lines.append("  method \(method)")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }
}

// MARK: - MIR Module

/// The top-level MIR container — one per source file.
public struct MIRModule {
    public var globals: [MIRGlobal]
    public var functions: [MIRFunction]
    public var types: [MIRTypeDecl]

    public init(globals: [MIRGlobal] = [], functions: [MIRFunction] = [], types: [MIRTypeDecl] = []) {
        self.globals = globals
        self.functions = functions
        self.types = types
    }

    /// Total instruction count across all functions
    public var totalInstructionCount: Int {
        functions.reduce(0) { $0 + $1.instructionCount }
    }
}

extension MIRModule: CustomStringConvertible {
    public var description: String {
        var lines: [String] = []
        lines.append("// MIR Module")
        if !types.isEmpty {
            lines.append("")
            for t in types {
                lines.append(t.description)
                lines.append("")
            }
        }
        if !globals.isEmpty {
            for g in globals {
                lines.append(g.description)
            }
            lines.append("")
        }
        for f in functions {
            lines.append(f.description)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
