// CodeGen.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation

// MARK: - Code Generator

/// Generates bytecode from an optimized MIR module.
public final class CodeGen {
    private let pool = ConstantPoolBuilder()

    /// Sentinel register value meaning "no destination" (void call).
    private static let noDestSentinel: UInt16 = 0xFFFF
    /// Sentinel parameter index for `this`.
    private static let thisParamIndex: UInt16 = 0xFFFE
    /// Sentinel parameter index for `super`.
    private static let superParamIndex: UInt16 = 0xFFFD

    /// Offset applied to MIR temp indices to avoid colliding with parameter registers.
    /// Set per-function to the function's parameter count.
    private var currentParamOffset: UInt16 = 0

    public init() {}

    // MARK: - Generate

    /// Generate a complete bytecode module from an optimized MIR module.
    public func generate(_ module: MIRModule) -> BytecodeModule {
        // Step 1: Build constant pool
        collectConstants(module)

        // Step 2: Encode globals
        let globals = module.globals.map { encodeGlobal($0) }

        // Step 3: Encode type declarations
        let types = module.types.map { encodeTypeDecl($0) }

        // Step 4: Generate functions
        let functions = module.functions.map { generateFunction($0) }

        return BytecodeModule(
            constantPool: pool.build(),
            globals: globals,
            types: types,
            functions: functions
        )
    }

    // MARK: - Constant Pool Collection

    private func collectConstants(_ module: MIRModule) {
        // Functions
        for f in module.functions {
            pool.intern(f.name, kind: .funcName)
            for (name, _) in f.parameters {
                pool.intern(name, kind: .paramName)
            }
            // Scan instructions
            for block in f.blocks {
                for inst in block.instructions {
                    collectInstructionConstants(inst)
                }
            }
        }

        // Globals
        for g in module.globals {
            pool.intern(g.name, kind: .globalName)
            if let initFunc = g.initializerFunc {
                pool.intern(initFunc, kind: .funcName)
            }
        }

        // Types
        for t in module.types {
            pool.intern(t.name, kind: .typeName)
            if let parent = t.parentType {
                pool.intern(parent, kind: .typeName)
            }
            for (fieldName, _) in t.fields {
                pool.intern(fieldName, kind: .fieldName)
            }
            for method in t.methods {
                pool.intern(method, kind: .methodName)
            }
        }
    }

    private func collectInstructionConstants(_ inst: MIRInstruction) {
        switch inst {
        case .constString(_, let value):
            pool.intern(value, kind: .string)
        case .call(_, let function, _):
            pool.intern(function, kind: .funcName)
        case .callIndirect:
            break  // No constants to intern — function ref is in a register
        case .virtualCall(_, _, let method, _):
            pool.intern(method, kind: .methodName)
        case .getField(_, _, let fieldName):
            pool.intern(fieldName, kind: .fieldName)
        case .setField(_, let fieldName, _):
            pool.intern(fieldName, kind: .fieldName)
        case .newObject(_, let typeName, _):
            pool.intern(typeName, kind: .typeName)
        case .typeCheck(_, _, let typeName):
            pool.intern(typeName, kind: .typeName)
        case .typeCast(_, _, let typeName):
            pool.intern(typeName, kind: .typeName)
        case .alloc(_, let type):
            if case .reference(let name) = type { pool.intern(name, kind: .typeName) }
        case .load(_, let src):
            if src.hasPrefix("global.") {
                pool.intern(String(src.dropFirst(7)), kind: .globalName)
            }
        default:
            break
        }
    }

    // MARK: - Function Codegen

    private func generateFunction(_ function: MIRFunction) -> BytecodeFunction {
        let nameIdx = pool.intern(function.name, kind: .funcName)

        // Build parameter name → index mapping
        var paramIndexMap: [String: UInt16] = [:]
        for (i, (name, _)) in function.parameters.enumerated() {
            paramIndexMap[name] = UInt16(i)
        }

        // Set param offset so MIR temps (%t0, %t1, ...) start after parameter registers
        currentParamOffset = UInt16(function.parameters.count)

        let registerCount = computeRegisterCount(function)

        // Pass 1: compute block offsets
        let blockOffsets = computeBlockOffsets(function)

        // Pass 2: emit bytecode
        let emitter = BytecodeEmitter()
        for block in function.blocks {
            for inst in block.instructions {
                emitInstruction(inst, emitter: emitter, paramIndexMap: paramIndexMap, blockOffsets: blockOffsets)
            }
            if let term = block.terminator {
                emitTerminator(term, emitter: emitter, blockOffsets: blockOffsets)
            }
        }

        let paramInfo: [(nameIndex: UInt16, typeTag: BytecodeTypeTag)] = function.parameters.map { (name, type) in
            (pool.intern(name, kind: .paramName), typeTag(for: type))
        }

        return BytecodeFunction(
            nameIndex: nameIdx,
            parameterCount: UInt16(function.parameters.count),
            registerCount: registerCount,
            returnTypeTag: typeTag(for: function.returnType),
            bytecode: emitter.bytes,
            parameterInfo: paramInfo,
            lineTable: []  // Stage 0 MIR doesn't carry source locations
        )
    }

    // MARK: - Register Resolution

    /// Extract register index from a `%tN` temp name.
    /// Adds currentParamOffset so MIR temps don't collide with parameter registers.
    private func resolveRegister(_ name: String) -> UInt16 {
        guard name.hasPrefix("%t"), let index = UInt16(name.dropFirst(2)) else {
            return CodeGen.noDestSentinel
        }
        return index + currentParamOffset
    }

    /// Compute the number of registers needed for a function.
    private func computeRegisterCount(_ function: MIRFunction) -> UInt16 {
        var maxReg: Int = -1
        for block in function.blocks {
            for inst in block.instructions {
                if let dest = inst.dest, dest.hasPrefix("%t"),
                   let idx = Int(dest.dropFirst(2)) {
                    maxReg = max(maxReg, idx)
                }
                for operand in inst.operands {
                    if operand.hasPrefix("%t"),
                       let idx = Int(operand.dropFirst(2)) {
                        maxReg = max(maxReg, idx)
                    }
                }
            }
        }
        // Total registers = parameter registers + MIR temp registers
        let tempRegCount = maxReg >= 0 ? maxReg + 1 : 0
        return UInt16(Int(currentParamOffset) + tempRegCount)
    }

    // MARK: - Label Resolution

    /// Pass 1: compute absolute byte offset for each block label.
    private func computeBlockOffsets(_ function: MIRFunction) -> [String: UInt32] {
        var offsets: [String: UInt32] = [:]
        var currentOffset: UInt32 = 0

        for block in function.blocks {
            offsets[block.label] = currentOffset
            for inst in block.instructions {
                currentOffset += UInt32(instructionByteSize(inst))
            }
            if let term = block.terminator {
                currentOffset += UInt32(terminatorByteSize(term))
            }
        }
        return offsets
    }

    /// Byte size of an encoded MIR instruction.
    private func instructionByteSize(_ inst: MIRInstruction) -> Int {
        switch inst {
        case .constInt, .constFloat:
            return 11  // op(1) + reg(2) + imm64(8)
        case .constBool:
            return 3   // op(1) + reg(2)
        case .constString:
            return 5   // op(1) + reg(2) + constIdx(2)
        case .constNull:
            return 3   // op(1) + reg(2)
        case .alloc:
            return 5   // op(1) + reg(2) + typeIdx(2)
        case .store, .load:
            return 5   // op(1) + reg(2) + reg(2)  OR  op(1) + idx(2) + reg(2)
        case .add, .sub, .mul, .div, .mod:
            return 7   // op(1) + 3*reg(6)
        case .neg:
            return 5   // op(1) + 2*reg(4)
        case .eq, .neq, .lt, .lte, .gt, .gte:
            return 7   // op(1) + 3*reg(6)
        case .and, .or:
            return 7   // op(1) + 3*reg(6)
        case .not:
            return 5   // op(1) + 2*reg(4)
        case .call(_, _, let args):
            return 7 + 2 * args.count  // op(1) + dest(2) + funcIdx(2) + argCount(2) + args
        case .callIndirect(_, _, let args):
            return 7 + 2 * args.count  // op(1) + dest(2) + funcRefReg(2) + argCount(2) + args
        case .virtualCall(_, _, _, let args):
            return 9 + 2 * args.count  // op(1) + dest(2) + obj(2) + methodIdx(2) + argCount(2) + args
        case .getField:
            return 7   // op(1) + dest(2) + obj(2) + fieldIdx(2)
        case .setField:
            return 7   // op(1) + obj(2) + fieldIdx(2) + value(2)
        case .newObject(_, _, let args):
            return 7 + 2 * args.count  // op(1) + dest(2) + typeIdx(2) + argCount(2) + args
        case .nullCheck, .isNull:
            return 5   // op(1) + 2*reg(4)
        case .typeCheck, .typeCast:
            return 7   // op(1) + dest(2) + operand(2) + typeIdx(2)
        case .stringConcat(_, let parts):
            return 5 + 2 * parts.count  // op(1) + dest(2) + count(2) + parts
        case .tryBegin:
            return 7   // op(1) + catchOffset(4) + exceptionReg(2)
        case .tryEnd:
            return 1   // op(1)
        case .awaitCall(_, _, let args):
            return 7 + 2 * args.count  // same layout as call
        case .concurrentBegin, .concurrentEnd:
            return 3  // op(1) + scopeId(2)
        }
    }

    /// Byte size of an encoded terminator.
    private func terminatorByteSize(_ term: MIRTerminator) -> Int {
        switch term {
        case .ret(let val):
            return val != nil ? 3 : 1  // RET reg(2) or RET_VOID
        case .jump:
            return 5   // op(1) + offset(4)
        case .branch:
            return 11  // op(1) + reg(2) + offset(4) + offset(4)
        case .throwValue:
            return 3   // op(1) + reg(2)
        case .unreachable:
            return 1
        }
    }

    // MARK: - Instruction Emission

    private func emitInstruction(
        _ inst: MIRInstruction,
        emitter: BytecodeEmitter,
        paramIndexMap: [String: UInt16],
        blockOffsets: [String: UInt32] = [:]
    ) {
        switch inst {
        // Constants
        case .constInt(let dest, let value):
            emitter.emitOpcode(.constInt)
            emitter.emitUInt16(resolveRegister(dest))
            emitter.emitInt64(value)

        case .constFloat(let dest, let value):
            emitter.emitOpcode(.constFloat)
            emitter.emitUInt16(resolveRegister(dest))
            emitter.emitFloat64(value)

        case .constBool(let dest, let value):
            emitter.emitOpcode(value ? .constTrue : .constFalse)
            emitter.emitUInt16(resolveRegister(dest))

        case .constString(let dest, let value):
            emitter.emitOpcode(.constString)
            emitter.emitUInt16(resolveRegister(dest))
            emitter.emitUInt16(pool.intern(value, kind: .string))

        case .constNull(let dest):
            emitter.emitOpcode(.constNull)
            emitter.emitUInt16(resolveRegister(dest))

        // Memory
        case .alloc(let dest, let type):
            emitter.emitOpcode(.alloc)
            emitter.emitUInt16(resolveRegister(dest))
            emitTypeIndex(type, emitter: emitter)

        case .store(let dest, let src):
            if dest.hasPrefix("global.") {
                let globalName = String(dest.dropFirst(7))
                emitter.emitOpcode(.storeGlobal)
                emitter.emitUInt16(pool.intern(globalName, kind: .globalName))
                emitter.emitUInt16(resolveRegister(src))
            } else {
                emitter.emitOpcode(.store)
                emitter.emitUInt16(resolveRegister(dest))
                emitter.emitUInt16(resolveRegister(src))
            }

        case .load(let dest, let src):
            if src.hasPrefix("param.") {
                let paramName = String(src.dropFirst(6))
                emitter.emitOpcode(.loadParam)
                emitter.emitUInt16(resolveRegister(dest))
                emitter.emitUInt16(paramIndexMap[paramName] ?? CodeGen.noDestSentinel)
            } else if src.hasPrefix("global.") {
                let globalName = String(src.dropFirst(7))
                emitter.emitOpcode(.loadGlobal)
                emitter.emitUInt16(resolveRegister(dest))
                emitter.emitUInt16(pool.intern(globalName, kind: .globalName))
            } else if src == "this" {
                emitter.emitOpcode(.loadParam)
                emitter.emitUInt16(resolveRegister(dest))
                emitter.emitUInt16(CodeGen.thisParamIndex)
            } else if src == "super" {
                emitter.emitOpcode(.loadParam)
                emitter.emitUInt16(resolveRegister(dest))
                emitter.emitUInt16(CodeGen.superParamIndex)
            } else {
                emitter.emitOpcode(.load)
                emitter.emitUInt16(resolveRegister(dest))
                emitter.emitUInt16(resolveRegister(src))
            }

        // Arithmetic
        case .add(let dest, let lhs, let rhs, _):
            emitter.emitOpcode(.add)
            emitter.emitUInt16(resolveRegister(dest))
            emitter.emitUInt16(resolveRegister(lhs))
            emitter.emitUInt16(resolveRegister(rhs))

        case .sub(let dest, let lhs, let rhs, _):
            emitter.emitOpcode(.sub)
            emitter.emitUInt16(resolveRegister(dest))
            emitter.emitUInt16(resolveRegister(lhs))
            emitter.emitUInt16(resolveRegister(rhs))

        case .mul(let dest, let lhs, let rhs, _):
            emitter.emitOpcode(.mul)
            emitter.emitUInt16(resolveRegister(dest))
            emitter.emitUInt16(resolveRegister(lhs))
            emitter.emitUInt16(resolveRegister(rhs))

        case .div(let dest, let lhs, let rhs, _):
            emitter.emitOpcode(.div)
            emitter.emitUInt16(resolveRegister(dest))
            emitter.emitUInt16(resolveRegister(lhs))
            emitter.emitUInt16(resolveRegister(rhs))

        case .mod(let dest, let lhs, let rhs, _):
            emitter.emitOpcode(.mod)
            emitter.emitUInt16(resolveRegister(dest))
            emitter.emitUInt16(resolveRegister(lhs))
            emitter.emitUInt16(resolveRegister(rhs))

        case .neg(let dest, let operand, _):
            emitter.emitOpcode(.neg)
            emitter.emitUInt16(resolveRegister(dest))
            emitter.emitUInt16(resolveRegister(operand))

        // Comparison
        case .eq(let dest, let lhs, let rhs, _):
            emitThreeReg(.eq, dest: dest, lhs: lhs, rhs: rhs, emitter: emitter)
        case .neq(let dest, let lhs, let rhs, _):
            emitThreeReg(.neq, dest: dest, lhs: lhs, rhs: rhs, emitter: emitter)
        case .lt(let dest, let lhs, let rhs, _):
            emitThreeReg(.lt, dest: dest, lhs: lhs, rhs: rhs, emitter: emitter)
        case .lte(let dest, let lhs, let rhs, _):
            emitThreeReg(.lte, dest: dest, lhs: lhs, rhs: rhs, emitter: emitter)
        case .gt(let dest, let lhs, let rhs, _):
            emitThreeReg(.gt, dest: dest, lhs: lhs, rhs: rhs, emitter: emitter)
        case .gte(let dest, let lhs, let rhs, _):
            emitThreeReg(.gte, dest: dest, lhs: lhs, rhs: rhs, emitter: emitter)

        // Logic
        case .and(let dest, let lhs, let rhs):
            emitThreeReg(.and, dest: dest, lhs: lhs, rhs: rhs, emitter: emitter)
        case .or(let dest, let lhs, let rhs):
            emitThreeReg(.or, dest: dest, lhs: lhs, rhs: rhs, emitter: emitter)
        case .not(let dest, let operand):
            emitter.emitOpcode(.not)
            emitter.emitUInt16(resolveRegister(dest))
            emitter.emitUInt16(resolveRegister(operand))

        // Calls
        case .call(let dest, let function, let args):
            emitter.emitOpcode(.call)
            emitter.emitUInt16(dest.map { resolveRegister($0) } ?? CodeGen.noDestSentinel)
            emitter.emitUInt16(pool.intern(function, kind: .funcName))
            emitter.emitUInt16(UInt16(args.count))
            for arg in args {
                emitter.emitUInt16(resolveRegister(arg))
            }

        case .callIndirect(let dest, let functionRef, let args):
            emitter.emitOpcode(.callIndirect)
            emitter.emitUInt16(dest.map { resolveRegister($0) } ?? CodeGen.noDestSentinel)
            emitter.emitUInt16(resolveRegister(functionRef))
            emitter.emitUInt16(UInt16(args.count))
            for arg in args {
                emitter.emitUInt16(resolveRegister(arg))
            }

        case .virtualCall(let dest, let object, let method, let args):
            emitter.emitOpcode(.vcall)
            emitter.emitUInt16(dest.map { resolveRegister($0) } ?? CodeGen.noDestSentinel)
            emitter.emitUInt16(resolveRegister(object))
            emitter.emitUInt16(pool.intern(method, kind: .methodName))
            emitter.emitUInt16(UInt16(args.count))
            for arg in args {
                emitter.emitUInt16(resolveRegister(arg))
            }

        // Fields
        case .getField(let dest, let object, let fieldName):
            emitter.emitOpcode(.getField)
            emitter.emitUInt16(resolveRegister(dest))
            emitter.emitUInt16(resolveRegister(object))
            emitter.emitUInt16(pool.intern(fieldName, kind: .fieldName))

        case .setField(let object, let fieldName, let value):
            emitter.emitOpcode(.setField)
            emitter.emitUInt16(resolveRegister(object))
            emitter.emitUInt16(pool.intern(fieldName, kind: .fieldName))
            emitter.emitUInt16(resolveRegister(value))

        // Objects
        case .newObject(let dest, let typeName, let args):
            emitter.emitOpcode(.newObject)
            emitter.emitUInt16(resolveRegister(dest))
            emitter.emitUInt16(pool.intern(typeName, kind: .typeName))
            emitter.emitUInt16(UInt16(args.count))
            for arg in args {
                emitter.emitUInt16(resolveRegister(arg))
            }

        // Null safety
        case .nullCheck(let dest, let operand):
            emitter.emitOpcode(.nullCheck)
            emitter.emitUInt16(resolveRegister(dest))
            emitter.emitUInt16(resolveRegister(operand))

        case .isNull(let dest, let operand):
            emitter.emitOpcode(.isNull)
            emitter.emitUInt16(resolveRegister(dest))
            emitter.emitUInt16(resolveRegister(operand))

        // Type operations
        case .typeCheck(let dest, let operand, let typeName):
            emitter.emitOpcode(.typeCheck)
            emitter.emitUInt16(resolveRegister(dest))
            emitter.emitUInt16(resolveRegister(operand))
            emitter.emitUInt16(pool.intern(typeName, kind: .typeName))

        case .typeCast(let dest, let operand, let typeName):
            emitter.emitOpcode(.typeCast)
            emitter.emitUInt16(resolveRegister(dest))
            emitter.emitUInt16(resolveRegister(operand))
            emitter.emitUInt16(pool.intern(typeName, kind: .typeName))

        // String
        case .stringConcat(let dest, let parts):
            emitter.emitOpcode(.stringConcat)
            emitter.emitUInt16(resolveRegister(dest))
            emitter.emitUInt16(UInt16(parts.count))
            for part in parts {
                emitter.emitUInt16(resolveRegister(part))
            }

        // Exception handling
        case .tryBegin(let catchLabel, let exceptionDest):
            emitter.emitOpcode(.tryBegin)
            emitter.emitUInt32(blockOffsets[catchLabel] ?? 0)
            emitter.emitUInt16(resolveRegister(exceptionDest))

        case .tryEnd:
            emitter.emitOpcode(.tryEnd)

        case .awaitCall(let dest, let function, let args):
            emitter.emitOpcode(.awaitCall)
            emitter.emitUInt16(dest.map { resolveRegister($0) } ?? CodeGen.noDestSentinel)
            emitter.emitUInt16(pool.intern(function, kind: .funcName))
            emitter.emitUInt16(UInt16(args.count))
            for arg in args {
                emitter.emitUInt16(resolveRegister(arg))
            }

        case .concurrentBegin(let scopeId):
            emitter.emitOpcode(.concurrentBegin)
            emitter.emitUInt16(pool.intern(scopeId, kind: .string))

        case .concurrentEnd(let scopeId):
            emitter.emitOpcode(.concurrentEnd)
            emitter.emitUInt16(pool.intern(scopeId, kind: .string))
        }
    }

    // MARK: - Terminator Emission

    private func emitTerminator(
        _ term: MIRTerminator,
        emitter: BytecodeEmitter,
        blockOffsets: [String: UInt32]
    ) {
        switch term {
        case .ret(let val):
            if let val = val {
                emitter.emitOpcode(.ret)
                emitter.emitUInt16(resolveRegister(val))
            } else {
                emitter.emitOpcode(.retVoid)
            }

        case .jump(let label):
            emitter.emitOpcode(.jump)
            emitter.emitUInt32(blockOffsets[label] ?? 0)

        case .branch(let condition, let thenLabel, let elseLabel):
            emitter.emitOpcode(.branch)
            emitter.emitUInt16(resolveRegister(condition))
            emitter.emitUInt32(blockOffsets[thenLabel] ?? 0)
            emitter.emitUInt32(blockOffsets[elseLabel] ?? 0)

        case .throwValue(let val):
            emitter.emitOpcode(.throwOp)
            emitter.emitUInt16(resolveRegister(val))

        case .unreachable:
            emitter.emitOpcode(.unreachable)
        }
    }

    // MARK: - Helpers

    private func emitThreeReg(_ op: Opcode, dest: String, lhs: String, rhs: String, emitter: BytecodeEmitter) {
        emitter.emitOpcode(op)
        emitter.emitUInt16(resolveRegister(dest))
        emitter.emitUInt16(resolveRegister(lhs))
        emitter.emitUInt16(resolveRegister(rhs))
    }

    /// Emit a type reference: for reference types, emit the constant pool index of the type name.
    /// For primitives, emit a sentinel (0xFFFF) — the VM uses the type tag, not a pool index.
    private func emitTypeIndex(_ type: MIRType, emitter: BytecodeEmitter) {
        if case .reference(let name) = type {
            emitter.emitUInt16(pool.intern(name, kind: .typeName))
        } else {
            emitter.emitUInt16(CodeGen.noDestSentinel)
        }
    }

    // MARK: - Type Tag

    /// Map a MIRType to a BytecodeTypeTag.
    private func typeTag(for type: MIRType) -> BytecodeTypeTag {
        switch type {
        case .unit:     return .unit
        case .int:      return .int
        case .int32:    return .int32
        case .int64:    return .int64
        case .float:    return .float
        case .float64:  return .float64
        case .double:   return .double
        case .bool:     return .bool
        case .string:   return .string
        case .nothing:  return .nothing
        case .nullable: return .nullable
        case .reference: return .reference
        case .function: return .function
        }
    }

    // MARK: - Global Encoding

    private func encodeGlobal(_ global: MIRGlobal) -> BytecodeGlobal {
        let nameIdx = pool.intern(global.name, kind: .globalName)
        let tag = typeTag(for: global.type)
        let initIdx: UInt16? = global.initializerFunc.map { pool.intern($0, kind: .funcName) }
        return BytecodeGlobal(nameIndex: nameIdx, typeTag: tag, isMutable: global.isMutable, initializerFuncIndex: initIdx)
    }

    // MARK: - Type Declaration Encoding

    private func encodeTypeDecl(_ typeDecl: MIRTypeDecl) -> BytecodeTypeDecl {
        let nameIdx = pool.intern(typeDecl.name, kind: .typeName)
        let fields = typeDecl.fields.map { (name, type) in
            (nameIndex: pool.intern(name, kind: .fieldName), typeTag: typeTag(for: type))
        }
        let methods = typeDecl.methods.map { pool.intern($0, kind: .methodName) }
        let parentIdx: UInt16? = typeDecl.parentType.map { pool.intern($0, kind: .typeName) }
        return BytecodeTypeDecl(nameIndex: nameIdx, fields: fields, methods: methods, parentTypeIndex: parentIdx, isActor: typeDecl.isActor)
    }

    // MARK: - Binary Serialization

    /// Serialize a BytecodeModule to raw bytes (.rokb format).
    public static func serialize(_ module: BytecodeModule) -> [UInt8] {
        let emitter = BytecodeEmitter()

        // Magic + version
        for b in BytecodeModule.magic { emitter.emitByte(b) }
        emitter.emitUInt16(BytecodeModule.versionMajor)
        emitter.emitUInt16(BytecodeModule.versionMinor)

        // Constant pool
        emitter.emitUInt32(UInt32(module.constantPool.count))
        for entry in module.constantPool {
            emitter.emitByte(entry.kind.rawValue)
            emitter.emitString(entry.value)
        }

        // Globals
        emitter.emitUInt32(UInt32(module.globals.count))
        for global in module.globals {
            emitter.emitUInt16(global.nameIndex)
            emitter.emitByte(global.typeTag.rawValue)
            emitter.emitByte(global.isMutable ? 1 : 0)
            emitter.emitByte(global.initializerFuncIndex != nil ? 1 : 0)
            emitter.emitUInt16(global.initializerFuncIndex ?? 0)
        }

        // Types
        emitter.emitUInt32(UInt32(module.types.count))
        for typeDecl in module.types {
            emitter.emitUInt16(typeDecl.nameIndex)
            emitter.emitUInt16(UInt16(typeDecl.fields.count))
            emitter.emitUInt16(UInt16(typeDecl.methods.count))
            emitter.emitUInt16(typeDecl.parentTypeIndex ?? 0xFFFF)
            emitter.emitByte(typeDecl.isActor ? 1 : 0)
            for (nameIdx, tag) in typeDecl.fields {
                emitter.emitUInt16(nameIdx)
                emitter.emitByte(tag.rawValue)
            }
            for methodIdx in typeDecl.methods {
                emitter.emitUInt16(methodIdx)
            }
        }

        // Functions
        emitter.emitUInt32(UInt32(module.functions.count))
        for f in module.functions {
            emitter.emitUInt16(f.nameIndex)
            emitter.emitUInt16(f.parameterCount)
            emitter.emitUInt16(f.registerCount)
            emitter.emitByte(f.returnTypeTag.rawValue)
            // Parameter info
            for (nameIdx, tag) in f.parameterInfo {
                emitter.emitUInt16(nameIdx)
                emitter.emitByte(tag.rawValue)
            }
            // Bytecode
            emitter.emitUInt32(UInt32(f.bytecode.count))
            for b in f.bytecode {
                emitter.emitByte(b)
            }
            // Line table
            emitter.emitUInt32(UInt32(f.lineTable.count))
            for (offset, line) in f.lineTable {
                emitter.emitUInt16(offset)
                emitter.emitUInt16(line)
            }
        }

        return emitter.bytes
    }

    // MARK: - Disassembly

    /// Produce a human-readable disassembly of a BytecodeModule.
    public static func disassemble(_ module: BytecodeModule) -> String {
        var lines: [String] = []
        lines.append("// Rockit Bytecode Module")
        lines.append("// Constant pool: \(module.constantPool.count) entries")
        lines.append("// Globals: \(module.globals.count)")
        lines.append("// Types: \(module.types.count)")
        lines.append("// Functions: \(module.functions.count)")
        lines.append("")

        // Constant pool
        if !module.constantPool.isEmpty {
            lines.append("--- Constant Pool ---")
            for (i, entry) in module.constantPool.enumerated() {
                lines.append("  #\(i): [\(entry.kind)] \"\(entry.value)\"")
            }
            lines.append("")
        }

        // Types
        for typeDecl in module.types {
            let name = module.constantPool[Int(typeDecl.nameIndex)].value
            lines.append("type \(name) {")
            for (nameIdx, tag) in typeDecl.fields {
                let fname = module.constantPool[Int(nameIdx)].value
                lines.append("  field \(fname): \(tag)")
            }
            for methodIdx in typeDecl.methods {
                let mname = module.constantPool[Int(methodIdx)].value
                lines.append("  method \(mname)")
            }
            lines.append("}")
            lines.append("")
        }

        // Functions
        for f in module.functions {
            let name = module.constantPool[Int(f.nameIndex)].value
            lines.append("fun \(name) (params=\(f.parameterCount), regs=\(f.registerCount)) -> \(f.returnTypeTag) {")
            lines.append(disassembleFunction(f, pool: module.constantPool))
            lines.append("}")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Disassemble a single function's bytecode.
    private static func disassembleFunction(_ f: BytecodeFunction, pool: [ConstantPoolEntry]) -> String {
        var lines: [String] = []
        let bytes = f.bytecode
        var pc = 0

        while pc < bytes.count {
            let offset = String(format: "%04X", pc)
            guard let op = Opcode(rawValue: bytes[pc]) else {
                lines.append("  \(offset): ??? (0x\(String(format: "%02X", bytes[pc])))")
                pc += 1
                continue
            }
            pc += 1

            switch op {
            case .constInt:
                let reg = readUInt16(bytes, at: &pc)
                let val = readInt64(bytes, at: &pc)
                lines.append("  \(offset): \(op)    r\(reg), \(val)")

            case .constFloat:
                let reg = readUInt16(bytes, at: &pc)
                let val = readFloat64(bytes, at: &pc)
                lines.append("  \(offset): \(op)  r\(reg), \(val)")

            case .constTrue, .constFalse:
                let reg = readUInt16(bytes, at: &pc)
                lines.append("  \(offset): \(op)   r\(reg)")

            case .constString:
                let reg = readUInt16(bytes, at: &pc)
                let idx = readUInt16(bytes, at: &pc)
                let val = Int(idx) < pool.count ? "\"\(pool[Int(idx)].value)\"" : "#\(idx)"
                lines.append("  \(offset): \(op) r\(reg), \(val)")

            case .constNull:
                let reg = readUInt16(bytes, at: &pc)
                lines.append("  \(offset): \(op)   r\(reg)")

            case .alloc:
                let reg = readUInt16(bytes, at: &pc)
                let idx = readUInt16(bytes, at: &pc)
                lines.append("  \(offset): \(op)       r\(reg), type#\(idx)")

            case .store:
                let dest = readUInt16(bytes, at: &pc)
                let src = readUInt16(bytes, at: &pc)
                lines.append("  \(offset): \(op)      r\(dest), r\(src)")

            case .load:
                let dest = readUInt16(bytes, at: &pc)
                let src = readUInt16(bytes, at: &pc)
                lines.append("  \(offset): \(op)       r\(dest), r\(src)")

            case .loadParam:
                let dest = readUInt16(bytes, at: &pc)
                let idx = readUInt16(bytes, at: &pc)
                lines.append("  \(offset): \(op) r\(dest), param#\(idx)")

            case .loadGlobal:
                let dest = readUInt16(bytes, at: &pc)
                let idx = readUInt16(bytes, at: &pc)
                let name = Int(idx) < pool.count ? pool[Int(idx)].value : "#\(idx)"
                lines.append("  \(offset): \(op) r\(dest), \(name)")

            case .storeGlobal:
                let idx = readUInt16(bytes, at: &pc)
                let src = readUInt16(bytes, at: &pc)
                let name = Int(idx) < pool.count ? pool[Int(idx)].value : "#\(idx)"
                lines.append("  \(offset): \(op) \(name), r\(src)")

            case .add, .sub, .mul, .div, .mod:
                let dest = readUInt16(bytes, at: &pc)
                let lhs = readUInt16(bytes, at: &pc)
                let rhs = readUInt16(bytes, at: &pc)
                lines.append("  \(offset): \(op)        r\(dest), r\(lhs), r\(rhs)")

            case .neg:
                let dest = readUInt16(bytes, at: &pc)
                let operand = readUInt16(bytes, at: &pc)
                lines.append("  \(offset): \(op)        r\(dest), r\(operand)")

            case .eq, .neq, .lt, .lte, .gt, .gte:
                let dest = readUInt16(bytes, at: &pc)
                let lhs = readUInt16(bytes, at: &pc)
                let rhs = readUInt16(bytes, at: &pc)
                lines.append("  \(offset): \(op)         r\(dest), r\(lhs), r\(rhs)")

            case .and, .or:
                let dest = readUInt16(bytes, at: &pc)
                let lhs = readUInt16(bytes, at: &pc)
                let rhs = readUInt16(bytes, at: &pc)
                lines.append("  \(offset): \(op)        r\(dest), r\(lhs), r\(rhs)")

            case .not:
                let dest = readUInt16(bytes, at: &pc)
                let operand = readUInt16(bytes, at: &pc)
                lines.append("  \(offset): \(op)        r\(dest), r\(operand)")

            case .call:
                let dest = readUInt16(bytes, at: &pc)
                let funcIdx = readUInt16(bytes, at: &pc)
                let argCount = readUInt16(bytes, at: &pc)
                var args: [String] = []
                for _ in 0..<argCount { args.append("r\(readUInt16(bytes, at: &pc))") }
                let fname = Int(funcIdx) < pool.count ? pool[Int(funcIdx)].value : "#\(funcIdx)"
                let destStr = dest == CodeGen.noDestSentinel ? "_" : "r\(dest)"
                lines.append("  \(offset): \(op)       \(destStr), \(fname)(\(args.joined(separator: ", ")))")

            case .callIndirect:
                let dest = readUInt16(bytes, at: &pc)
                let funcRefReg = readUInt16(bytes, at: &pc)
                let argCount = readUInt16(bytes, at: &pc)
                var args: [String] = []
                for _ in 0..<argCount { args.append("r\(readUInt16(bytes, at: &pc))") }
                let destStr = dest == CodeGen.noDestSentinel ? "_" : "r\(dest)"
                lines.append("  \(offset): \(op) \(destStr), r\(funcRefReg)(\(args.joined(separator: ", ")))")

            case .vcall:
                let dest = readUInt16(bytes, at: &pc)
                let obj = readUInt16(bytes, at: &pc)
                let methIdx = readUInt16(bytes, at: &pc)
                let argCount = readUInt16(bytes, at: &pc)
                var args: [String] = []
                for _ in 0..<argCount { args.append("r\(readUInt16(bytes, at: &pc))") }
                let mname = Int(methIdx) < pool.count ? pool[Int(methIdx)].value : "#\(methIdx)"
                let destStr = dest == CodeGen.noDestSentinel ? "_" : "r\(dest)"
                lines.append("  \(offset): \(op)      \(destStr), r\(obj).\(mname)(\(args.joined(separator: ", ")))")

            case .getField:
                let dest = readUInt16(bytes, at: &pc)
                let obj = readUInt16(bytes, at: &pc)
                let fieldIdx = readUInt16(bytes, at: &pc)
                let fname = Int(fieldIdx) < pool.count ? pool[Int(fieldIdx)].value : "#\(fieldIdx)"
                lines.append("  \(offset): \(op)  r\(dest), r\(obj).\(fname)")

            case .setField:
                let obj = readUInt16(bytes, at: &pc)
                let fieldIdx = readUInt16(bytes, at: &pc)
                let value = readUInt16(bytes, at: &pc)
                let fname = Int(fieldIdx) < pool.count ? pool[Int(fieldIdx)].value : "#\(fieldIdx)"
                lines.append("  \(offset): \(op)  r\(obj).\(fname), r\(value)")

            case .newObject:
                let dest = readUInt16(bytes, at: &pc)
                let typeIdx = readUInt16(bytes, at: &pc)
                let argCount = readUInt16(bytes, at: &pc)
                var args: [String] = []
                for _ in 0..<argCount { args.append("r\(readUInt16(bytes, at: &pc))") }
                let tname = Int(typeIdx) < pool.count ? pool[Int(typeIdx)].value : "#\(typeIdx)"
                lines.append("  \(offset): \(op) r\(dest), \(tname)(\(args.joined(separator: ", ")))")

            case .nullCheck:
                let dest = readUInt16(bytes, at: &pc)
                let operand = readUInt16(bytes, at: &pc)
                lines.append("  \(offset): \(op) r\(dest), r\(operand)")

            case .isNull:
                let dest = readUInt16(bytes, at: &pc)
                let operand = readUInt16(bytes, at: &pc)
                lines.append("  \(offset): \(op)    r\(dest), r\(operand)")

            case .typeCheck:
                let dest = readUInt16(bytes, at: &pc)
                let operand = readUInt16(bytes, at: &pc)
                let typeIdx = readUInt16(bytes, at: &pc)
                let tname = Int(typeIdx) < pool.count ? pool[Int(typeIdx)].value : "#\(typeIdx)"
                lines.append("  \(offset): \(op) r\(dest), r\(operand) is \(tname)")

            case .typeCast:
                let dest = readUInt16(bytes, at: &pc)
                let operand = readUInt16(bytes, at: &pc)
                let typeIdx = readUInt16(bytes, at: &pc)
                let tname = Int(typeIdx) < pool.count ? pool[Int(typeIdx)].value : "#\(typeIdx)"
                lines.append("  \(offset): \(op)  r\(dest), r\(operand) as \(tname)")

            case .stringConcat:
                let dest = readUInt16(bytes, at: &pc)
                let count = readUInt16(bytes, at: &pc)
                var parts: [String] = []
                for _ in 0..<count { parts.append("r\(readUInt16(bytes, at: &pc))") }
                lines.append("  \(offset): \(op) r\(dest), [\(parts.joined(separator: ", "))]")

            case .tryBegin:
                let catchOffset = readUInt32(bytes, at: &pc)
                let excReg = readUInt16(bytes, at: &pc)
                lines.append("  \(offset): \(op)  catch=@\(String(format: "%04X", catchOffset)), exc=r\(excReg)")

            case .tryEnd:
                lines.append("  \(offset): \(op)")

            case .throwOp:
                let reg = readUInt16(bytes, at: &pc)
                lines.append("  \(offset): \(op)      r\(reg)")

            case .ret:
                let reg = readUInt16(bytes, at: &pc)
                lines.append("  \(offset): \(op)        r\(reg)")

            case .retVoid:
                lines.append("  \(offset): \(op)")

            case .jump:
                let target = readUInt32(bytes, at: &pc)
                lines.append("  \(offset): \(op)       @\(String(format: "%04X", target))")

            case .branch:
                let cond = readUInt16(bytes, at: &pc)
                let thenTarget = readUInt32(bytes, at: &pc)
                let elseTarget = readUInt32(bytes, at: &pc)
                lines.append("  \(offset): \(op)     r\(cond), then=@\(String(format: "%04X", thenTarget)), else=@\(String(format: "%04X", elseTarget))")

            case .unreachable:
                lines.append("  \(offset): \(op)")

            case .awaitCall:
                let dest = readUInt16(bytes, at: &pc)
                let funcIdx = readUInt16(bytes, at: &pc)
                let argCount = readUInt16(bytes, at: &pc)
                var argRegs: [String] = []
                for _ in 0..<argCount { argRegs.append("r\(readUInt16(bytes, at: &pc))") }
                let funcName = Int(funcIdx) < pool.count ? pool[Int(funcIdx)].value : "?\(funcIdx)"
                let destStr = dest == CodeGen.noDestSentinel ? "_" : "r\(dest)"
                lines.append("  \(offset): \(op) \(destStr), \(funcName)(\(argRegs.joined(separator: ", ")))")

            case .concurrentBegin, .concurrentEnd:
                let scopeIdx = readUInt16(bytes, at: &pc)
                let scopeName = Int(scopeIdx) < pool.count ? pool[Int(scopeIdx)].value : "?\(scopeIdx)"
                lines.append("  \(offset): \(op) \(scopeName)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Byte Reading Helpers (for disassembly)

    private static func readUInt16(_ bytes: [UInt8], at pc: inout Int) -> UInt16 {
        guard pc + 1 < bytes.count else { pc = bytes.count; return 0 }
        let val = UInt16(bytes[pc]) << 8 | UInt16(bytes[pc + 1])
        pc += 2
        return val
    }

    private static func readUInt32(_ bytes: [UInt8], at pc: inout Int) -> UInt32 {
        guard pc + 3 < bytes.count else { pc = bytes.count; return 0 }
        let val = UInt32(bytes[pc]) << 24 | UInt32(bytes[pc+1]) << 16 | UInt32(bytes[pc+2]) << 8 | UInt32(bytes[pc+3])
        pc += 4
        return val
    }

    private static func readInt64(_ bytes: [UInt8], at pc: inout Int) -> Int64 {
        guard pc + 7 < bytes.count else { pc = bytes.count; return 0 }
        var bits: UInt64 = 0
        for i in 0..<8 {
            bits = bits << 8 | UInt64(bytes[pc + i])
        }
        pc += 8
        return Int64(bitPattern: bits)
    }

    private static func readFloat64(_ bytes: [UInt8], at pc: inout Int) -> Double {
        guard pc + 7 < bytes.count else { pc = bytes.count; return 0 }
        var bits: UInt64 = 0
        for i in 0..<8 {
            bits = bits << 8 | UInt64(bytes[pc + i])
        }
        pc += 8
        return Double(bitPattern: bits)
    }
}
