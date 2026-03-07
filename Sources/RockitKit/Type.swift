// Type.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - Expression Identity

/// Unique key for an expression in the AST, based on its source span start position.
/// Used as the key in the type map side-table.
public struct ExpressionID: Hashable {
    public let line: Int
    public let column: Int

    public init(_ span: SourceSpan) {
        self.line = span.start.line
        self.column = span.start.column
    }

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

// MARK: - Semantic Type

/// The semantic type representation used by the type checker.
/// This is distinct from `TypeNode` (which is syntactic, from the parser).
public indirect enum Type: Equatable {

    // MARK: Primitives

    case int
    case int32
    case int64
    case float
    case float64
    case double
    case bool
    case string
    case byteArray
    case unit
    case nothing
    case any

    // MARK: Null

    case nullType
    case nullable(Type)

    // MARK: Composite

    case classType(name: String, typeArguments: [Type])
    case interfaceType(name: String, typeArguments: [Type])
    case enumType(name: String)
    case objectType(name: String)
    case actorType(name: String)

    // MARK: Callable

    case function(parameterTypes: [Type], returnType: Type)

    // MARK: Structural

    case tuple(elements: [Type])

    // MARK: Generics

    case typeParameter(name: String, bound: Type?)

    // MARK: Error (poison)

    /// Poison type — prevents cascading errors. If any sub-expression has type `.error`,
    /// dependent expressions silently propagate `.error` without emitting additional diagnostics.
    case error
}

// MARK: - Type Helpers

extension Type {

    /// Whether this type is nullable (`T?`)
    public var isNullable: Bool {
        if case .nullable = self { return true }
        if case .nullType = self { return true }
        return false
    }

    /// Unwrap one layer of nullability: `T? → T`. Non-nullable types return self.
    public var unwrapNullable: Type {
        if case .nullable(let inner) = self { return inner }
        return self
    }

    /// Wrap in nullable if not already nullable: `T → T?`
    public var asNullable: Type {
        if isNullable { return self }
        return .nullable(self)
    }

    /// Whether this is the top type (Any)
    public var isAny: Bool {
        if case .any = self { return true }
        return false
    }

    /// Whether this is the poison/error type
    public var isError: Bool {
        if case .error = self { return true }
        return false
    }

    /// Whether this type is an unresolved generic type parameter
    public var isTypeParameter: Bool {
        if case .typeParameter = self { return true }
        return false
    }

    /// Whether this type is numeric (Int, Int32, Int64, Float, Float64, Double)
    public var isNumeric: Bool {
        switch self {
        case .int, .int32, .int64, .float, .float64, .double:
            return true
        default:
            return false
        }
    }

    /// Whether this type is an integer type
    public var isInteger: Bool {
        switch self {
        case .int, .int32, .int64:
            return true
        default:
            return false
        }
    }

    /// Whether this type is a floating-point type
    public var isFloatingPoint: Bool {
        switch self {
        case .float, .float64, .double:
            return true
        default:
            return false
        }
    }

    /// The name of this type for class/interface/enum/object/actor types
    public var typeName: String? {
        switch self {
        case .classType(let name, _),
             .interfaceType(let name, _),
             .enumType(let name),
             .objectType(let name),
             .actorType(let name):
            return name
        default:
            return nil
        }
    }
}

// MARK: - Display

extension Type: CustomStringConvertible {
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
        case .byteArray:    return "ByteArray"
        case .unit:         return "Unit"
        case .nothing:      return "Nothing"
        case .any:          return "Any"
        case .nullType:     return "null"
        case .error:        return "<error>"

        case .nullable(let inner):
            return "\(inner)?"

        case .classType(let name, let args):
            if args.isEmpty { return name }
            return "\(name)<\(args.map { "\($0)" }.joined(separator: ", "))>"

        case .interfaceType(let name, let args):
            if args.isEmpty { return name }
            return "\(name)<\(args.map { "\($0)" }.joined(separator: ", "))>"

        case .enumType(let name):
            return name

        case .objectType(let name):
            return name

        case .actorType(let name):
            return name

        case .function(let params, let ret):
            let paramStr = params.map { "\($0)" }.joined(separator: ", ")
            return "(\(paramStr)) -> \(ret)"

        case .tuple(let elements):
            return "(\(elements.map { "\($0)" }.joined(separator: ", ")))"

        case .typeParameter(let name, let bound):
            if let bound = bound {
                return "\(name) : \(bound)"
            }
            return name
        }
    }
}
