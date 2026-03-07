// VMError.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - VM Error

/// Runtime errors raised during bytecode execution.
public enum VMError: Error, CustomStringConvertible {
    /// Attempted to dereference null.
    case nullPointerAccess(context: String)

    /// Type mismatch in operation (expected vs actual).
    case typeMismatch(expected: String, actual: String, operation: String)

    /// Division or modulo by zero.
    case divisionByZero

    /// Call stack exceeded maximum depth.
    case stackOverflow(depth: Int)

    /// Invalid or corrupt bytecode encountered.
    case invalidBytecode(detail: String)

    /// Executed an unreachable instruction.
    case unreachable

    /// Array or field index out of bounds.
    case indexOutOfBounds(index: Int, count: Int)

    /// Failed type cast.
    case invalidCast(from: String, to: String)

    /// Read from uninitialized variable or register.
    case uninitializedVariable(name: String)

    /// Referenced function not found in module.
    case unknownFunction(name: String)

    /// Referenced global not found.
    case unknownGlobal(name: String)

    /// Referenced type not found.
    case unknownType(name: String)

    /// Invalid opcode byte.
    case unknownOpcode(byte: UInt8)

    /// Bytecode file validation failure.
    case invalidBytecodeFile(detail: String)

    /// Capability not granted.
    case capabilityDenied(name: String)

    /// Actor isolation violation.
    case actorIsolationViolation(actor: String, field: String)

    /// Uncaught user exception (throw without matching catch).
    case userException(message: String)

    public var description: String {
        switch self {
        case .nullPointerAccess(let ctx):
            return "NullPointerError: attempted to access null value\(ctx.isEmpty ? "" : " (\(ctx))")"
        case .typeMismatch(let expected, let actual, let op):
            return "TypeError: \(op) expected \(expected), got \(actual)"
        case .divisionByZero:
            return "ArithmeticError: division by zero"
        case .stackOverflow(let depth):
            return "StackOverflowError: call stack exceeded \(depth) frames"
        case .invalidBytecode(let detail):
            return "BytecodeError: \(detail)"
        case .unreachable:
            return "UnreachableError: executed unreachable instruction"
        case .indexOutOfBounds(let index, let count):
            return "IndexError: index \(index) out of bounds (count: \(count))"
        case .invalidCast(let from, let to):
            return "CastError: cannot cast \(from) to \(to)"
        case .uninitializedVariable(let name):
            return "UninitializedError: variable '\(name)' used before initialization"
        case .unknownFunction(let name):
            return "ReferenceError: unknown function '\(name)'"
        case .unknownGlobal(let name):
            return "ReferenceError: unknown global '\(name)'"
        case .unknownType(let name):
            return "ReferenceError: unknown type '\(name)'"
        case .unknownOpcode(let byte):
            return "BytecodeError: unknown opcode 0x\(String(format: "%02X", byte))"
        case .invalidBytecodeFile(let detail):
            return "LoadError: \(detail)"
        case .capabilityDenied(let name):
            return "CapabilityError: capability '\(name)' not granted"
        case .actorIsolationViolation(let actor, let field):
            return "IsolationError: cannot access '\(field)' on actor '\(actor)' from outside"
        case .userException(let message):
            return "Exception: \(message)"
        }
    }
}

// MARK: - Stack Trace

/// A single frame in a runtime stack trace.
public struct StackTraceFrame: CustomStringConvertible {
    public let functionName: String
    public let bytecodeOffset: Int
    public let sourceLine: Int?

    public init(functionName: String, bytecodeOffset: Int, sourceLine: Int? = nil) {
        self.functionName = functionName
        self.bytecodeOffset = bytecodeOffset
        self.sourceLine = sourceLine
    }

    public var description: String {
        if let line = sourceLine {
            return "  at \(functionName) (line \(line)) [offset 0x\(String(format: "%04X", bytecodeOffset))]"
        }
        return "  at \(functionName) [offset 0x\(String(format: "%04X", bytecodeOffset))]"
    }
}

/// A complete runtime stack trace.
public struct StackTrace: CustomStringConvertible {
    public let error: VMError
    public let frames: [StackTraceFrame]

    public init(error: VMError, frames: [StackTraceFrame]) {
        self.error = error
        self.frames = frames
    }

    public var description: String {
        var lines = [error.description]
        for frame in frames {
            lines.append(frame.description)
        }
        return lines.joined(separator: "\n")
    }
}
