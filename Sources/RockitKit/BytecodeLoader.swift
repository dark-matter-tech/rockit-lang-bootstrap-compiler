// BytecodeLoader.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation

// MARK: - Bytecode Loader

/// Deserializes a `.rokb` binary file into a `BytecodeModule`.
/// Mirrors the format written by `CodeGen.serialize()`.
public final class BytecodeLoader {

    /// Load a BytecodeModule from a file path.
    public static func load(from url: URL) throws -> BytecodeModule {
        let data = try Data(contentsOf: url)
        return try load(bytes: Array(data))
    }

    /// Load a BytecodeModule from raw bytes.
    public static func load(bytes: [UInt8]) throws -> BytecodeModule {
        var reader = ByteReader(bytes: bytes)

        // Validate magic
        guard reader.remaining >= 8 else {
            throw VMError.invalidBytecodeFile(detail: "file too small")
        }
        let magic = reader.readBytes(4)
        guard magic == BytecodeModule.magic else {
            throw VMError.invalidBytecodeFile(detail: "invalid magic number")
        }

        // Version
        let major = reader.readUInt16()
        let minor = reader.readUInt16()
        guard major == BytecodeModule.versionMajor else {
            throw VMError.invalidBytecodeFile(
                detail: "unsupported version \(major).\(minor), expected \(BytecodeModule.versionMajor).\(BytecodeModule.versionMinor)")
        }

        // Constant pool
        let poolCount = reader.readUInt32()
        var constantPool: [ConstantPoolEntry] = []
        constantPool.reserveCapacity(Int(poolCount))
        for _ in 0..<poolCount {
            let kindByte = reader.readByte()
            guard let kind = ConstantPoolKind(rawValue: kindByte) else {
                throw VMError.invalidBytecodeFile(detail: "unknown constant pool kind 0x\(String(format: "%02X", kindByte))")
            }
            let str = reader.readString()
            constantPool.append(ConstantPoolEntry(kind: kind, value: str))
        }

        // Globals
        let globalCount = reader.readUInt32()
        var globals: [BytecodeGlobal] = []
        globals.reserveCapacity(Int(globalCount))
        for _ in 0..<globalCount {
            let nameIndex = reader.readUInt16()
            let typeTagByte = reader.readByte()
            let typeTag = BytecodeTypeTag(rawValue: typeTagByte) ?? .unit
            let isMutable = reader.readByte() != 0
            let hasInit = reader.readByte() != 0
            let initIdx = reader.readUInt16()
            globals.append(BytecodeGlobal(
                nameIndex: nameIndex,
                typeTag: typeTag,
                isMutable: isMutable,
                initializerFuncIndex: hasInit ? initIdx : nil
            ))
        }

        // Types
        let typeCount = reader.readUInt32()
        var types: [BytecodeTypeDecl] = []
        types.reserveCapacity(Int(typeCount))
        for _ in 0..<typeCount {
            let nameIndex = reader.readUInt16()
            let fieldCount = reader.readUInt16()
            let methodCount = reader.readUInt16()
            let parentIdx = reader.readUInt16()
            let parentTypeIndex: UInt16? = parentIdx == 0xFFFF ? nil : parentIdx
            let isActor = reader.readByte() != 0
            var fields: [(nameIndex: UInt16, typeTag: BytecodeTypeTag)] = []
            for _ in 0..<fieldCount {
                let fNameIdx = reader.readUInt16()
                let fTagByte = reader.readByte()
                let fTag = BytecodeTypeTag(rawValue: fTagByte) ?? .unit
                fields.append((fNameIdx, fTag))
            }
            var methods: [UInt16] = []
            for _ in 0..<methodCount {
                methods.append(reader.readUInt16())
            }
            types.append(BytecodeTypeDecl(nameIndex: nameIndex, fields: fields, methods: methods, parentTypeIndex: parentTypeIndex, isActor: isActor))
        }

        // Functions
        let funcCount = reader.readUInt32()
        var functions: [BytecodeFunction] = []
        functions.reserveCapacity(Int(funcCount))
        for _ in 0..<funcCount {
            let nameIndex = reader.readUInt16()
            let paramCount = reader.readUInt16()
            let regCount = reader.readUInt16()
            let retTagByte = reader.readByte()
            let retTag = BytecodeTypeTag(rawValue: retTagByte) ?? .unit

            // Parameter info
            var paramInfo: [(nameIndex: UInt16, typeTag: BytecodeTypeTag)] = []
            for _ in 0..<paramCount {
                let pNameIdx = reader.readUInt16()
                let pTagByte = reader.readByte()
                let pTag = BytecodeTypeTag(rawValue: pTagByte) ?? .unit
                paramInfo.append((pNameIdx, pTag))
            }

            // Bytecode
            let codeLen = reader.readUInt32()
            let bytecode = reader.readBytes(Int(codeLen))

            // Line table (offset → source line)
            var lineTable: [(offset: UInt16, line: UInt16)] = []
            if reader.remaining >= 4 {
                let lineCount = reader.readUInt32()
                for _ in 0..<lineCount {
                    let bOffset = reader.readUInt16()
                    let bLine = reader.readUInt16()
                    lineTable.append((bOffset, bLine))
                }
            }

            functions.append(BytecodeFunction(
                nameIndex: nameIndex,
                parameterCount: paramCount,
                registerCount: regCount,
                returnTypeTag: retTag,
                bytecode: bytecode,
                parameterInfo: paramInfo,
                lineTable: lineTable
            ))
        }

        return BytecodeModule(
            constantPool: constantPool,
            globals: globals,
            types: types,
            functions: functions
        )
    }
}

// MARK: - Byte Reader

/// Sequential byte reader for deserializing binary data.
internal struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset: Int = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count - offset }

    mutating func readByte() -> UInt8 {
        guard offset < bytes.count else { return 0 }
        let b = bytes[offset]
        offset += 1
        return b
    }

    mutating func readUInt16() -> UInt16 {
        guard offset + 1 < bytes.count else { offset = bytes.count; return 0 }
        let val = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        offset += 2
        return val
    }

    mutating func readUInt32() -> UInt32 {
        guard offset + 3 < bytes.count else { offset = bytes.count; return 0 }
        let val = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset+1]) << 16 |
                  UInt32(bytes[offset+2]) << 8 | UInt32(bytes[offset+3])
        offset += 4
        return val
    }

    mutating func readInt64() -> Int64 {
        guard offset + 7 < bytes.count else { offset = bytes.count; return 0 }
        var bits: UInt64 = 0
        for i in 0..<8 {
            bits = bits << 8 | UInt64(bytes[offset + i])
        }
        offset += 8
        return Int64(bitPattern: bits)
    }

    mutating func readFloat64() -> Double {
        guard offset + 7 < bytes.count else { offset = bytes.count; return 0 }
        var bits: UInt64 = 0
        for i in 0..<8 {
            bits = bits << 8 | UInt64(bytes[offset + i])
        }
        offset += 8
        return Double(bitPattern: bits)
    }

    /// Read a length-prefixed UTF-8 string (UInt32 length + bytes).
    mutating func readString() -> String {
        let length = readUInt32()
        let strBytes = readBytes(Int(length))
        return String(bytes: strBytes, encoding: .utf8) ?? ""
    }

    mutating func readBytes(_ count: Int) -> [UInt8] {
        let end = min(offset + count, bytes.count)
        let result = Array(bytes[offset..<end])
        offset = end
        return result
    }
}
