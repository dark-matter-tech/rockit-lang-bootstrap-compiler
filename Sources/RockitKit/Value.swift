// Value.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - Object ID

/// Unique identifier for a heap-allocated object.
public struct ObjectID: Equatable, Hashable, CustomStringConvertible {
    public let index: Int

    public init(_ index: Int) { self.index = index }

    public var description: String { "obj#\(index)" }
}

// MARK: - Runtime Value

/// Tagged union representing a runtime value in the Rockit VM.
/// Primitives (int, float, bool) are unboxed — no heap allocation.
/// Objects live on the Heap and are referenced by ObjectID.
public enum Value: Equatable, Hashable {
    case int(Int64)
    case float(Double)
    case bool(Bool)
    case string(String)
    case null
    case unit
    case objectRef(ObjectID)
    case functionRef(UInt16)
}

// MARK: - Value Helpers

extension Value: CustomStringConvertible {
    public var description: String {
        switch self {
        case .int(let v):         return "\(v)"
        case .float(let v):       return "\(v)"
        case .bool(let v):        return v ? "true" : "false"
        case .string(let v):      return v
        case .null:               return "null"
        case .unit:               return "()"
        case .objectRef(let id):  return "<\(id)>"
        case .functionRef(let i): return "<fun#\(i)>"
        }
    }

    /// The type name of this value for error messages.
    public var typeName: String {
        switch self {
        case .int:         return "Int"
        case .float:       return "Float64"
        case .bool:        return "Bool"
        case .string:      return "String"
        case .null:        return "Nothing"
        case .unit:        return "Unit"
        case .objectRef:   return "Object"
        case .functionRef: return "Function"
        }
    }

    /// Whether this value is truthy for branch conditions.
    public var isTruthy: Bool {
        switch self {
        case .bool(let v): return v
        case .null:        return false
        case .int(let v):  return v != 0
        default:           return true
        }
    }

    /// Whether this value holds a heap reference that needs ARC tracking.
    public var isHeapReference: Bool {
        if case .objectRef = self { return true }
        return false
    }

    /// Extract the ObjectID if this is an object reference.
    public var objectID: ObjectID? {
        if case .objectRef(let id) = self { return id }
        return nil
    }
}
