// BytecodeEmitter.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation

// MARK: - Bytecode Emitter

/// Low-level helper for emitting raw bytes into a buffer.
public final class BytecodeEmitter {
    private(set) public var bytes: [UInt8] = []

    public init() {}

    /// Current write position (byte offset).
    public var position: UInt32 { UInt32(bytes.count) }

    /// Number of bytes emitted.
    public var count: Int { bytes.count }

    /// Reset the buffer.
    public func reset() { bytes = [] }

    // MARK: - Primitive Emission

    public func emitByte(_ value: UInt8) {
        bytes.append(value)
    }

    /// Emit UInt16 in big-endian.
    public func emitUInt16(_ value: UInt16) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xFF))
    }

    /// Emit UInt32 in big-endian.
    public func emitUInt32(_ value: UInt32) {
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    /// Emit Int64 in big-endian.
    public func emitInt64(_ value: Int64) {
        let bits = UInt64(bitPattern: value)
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((bits >> shift) & 0xFF))
        }
    }

    /// Emit Double as IEEE 754 bits in big-endian.
    public func emitFloat64(_ value: Double) {
        let bits = value.bitPattern
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((bits >> shift) & 0xFF))
        }
    }

    /// Emit a UTF-8 string prefixed by its byte length (UInt32).
    public func emitString(_ value: String) {
        let utf8 = Array(value.utf8)
        emitUInt32(UInt32(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    // MARK: - Opcode Convenience

    /// Emit an opcode byte.
    public func emitOpcode(_ op: Opcode) {
        emitByte(op.rawValue)
    }
}

// MARK: - Constant Pool Builder

/// Builds and deduplicates the constant pool during codegen.
public final class ConstantPoolBuilder {
    private var entries: [ConstantPoolEntry] = []
    private var dedup: [String: UInt16] = [:]

    public init() {}

    /// Intern a value, returning its constant pool index.
    /// Same kind+value pair always returns the same index.
    @discardableResult
    public func intern(_ value: String, kind: ConstantPoolKind) -> UInt16 {
        let key = "\(kind.rawValue):\(value)"
        if let existing = dedup[key] {
            return existing
        }
        let idx = UInt16(entries.count)
        entries.append(ConstantPoolEntry(kind: kind, value: value))
        dedup[key] = idx
        return idx
    }

    /// Build the final constant pool array.
    public func build() -> [ConstantPoolEntry] {
        return entries
    }

    /// Number of entries interned so far.
    public var count: Int { entries.count }
}
