// VM.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation

// MARK: - VM

/// The Rockit Virtual Machine. Loads and executes bytecode modules
/// using a register-based architecture with a call stack.
public final class VM {
    /// The loaded bytecode module.
    private let module: BytecodeModule

    /// Runtime configuration.
    private let config: RuntimeConfig

    /// Built-in function registry.
    private let builtins: BuiltinRegistry

    /// Call stack.
    private var callStack: [CallFrame] = []

    /// Global variable storage, indexed by constant pool index of the global name.
    private var globals: [UInt16: Value] = [:]

    /// Last return value from a function that had no caller frame to receive it.
    /// Used by global initializers to capture their result.
    private var lastReturnValue: Value = .unit

    /// Function lookup: name → index in module.functions.
    private var functionTable: [String: Int] = [:]

    /// Type lookup: name → index in module.types.
    private var typeTable: [String: Int] = [:]

    /// Type field name → field index mapping for fast field access.
    private var typeFieldIndices: [String: [String: Int]] = [:]

    /// Parent type map: typeName → parentTypeName (for polymorphic dispatch).
    private var parentTypeMap: [String: String] = [:]

    /// Actor type names for concurrency routing.
    private var actorTypeNames: Set<String> = []

    /// The currently executing coroutine (nil in synchronous mode).
    private var currentCoroutine: Coroutine?

    /// Actor runtime for message-passing concurrency.
    private lazy var actorRuntime = ActorRuntime(scheduler: scheduler)

    /// Maps heap object indices to actor IDs for actor detection at call sites.
    private var actorObjectMap: [Int: ActorID] = [:]

    /// Exception handler stack for try/catch.
    private var exceptionHandlers: [(catchPC: Int, exceptionReg: UInt16, frameIndex: Int)] = []

    /// Heap for object allocation with ARC memory management.
    private let arcHeap: Heap

    /// Automatic Reference Counting manager.
    private let arc: ReferenceCounter

    /// Output capture for testing (nil = print to stdout).
    public var outputCapture: ((String) -> Void)?

    /// Total instructions executed (for stats).
    private var instructionCount: Int = 0

    /// Cooperative scheduler for structured concurrency.
    private let scheduler = Scheduler()

    /// Stack of active concurrent scopes. Each scope collects spawned coroutines.
    private var concurrentScopes: [ConcurrentScope] = []

    /// A concurrent scope tracks coroutines spawned between concurrentBegin and concurrentEnd.
    private struct ConcurrentScope {
        let scopeIdx: UInt16
        var spawnedCoroutines: [Coroutine] = []
    }

    public init(module: BytecodeModule, config: RuntimeConfig = .default, builtins: BuiltinRegistry? = nil) {
        self.module = module
        self.config = config
        self.builtins = builtins ?? BuiltinRegistry()
        self.arcHeap = Heap()
        self.arc = ReferenceCounter(heap: arcHeap, cycleDetectorThreshold: config.cycleDetectorThreshold)
        buildLookupTables()
        self.builtins.registerCollectionBuiltins(heap: arcHeap, arc: arc)
    }

    // MARK: - Setup

    private func buildLookupTables() {
        // Function table
        for (i, f) in module.functions.enumerated() {
            let name = constantString(f.nameIndex)
            functionTable[name] = i
        }

        // Type table + field indices + parent type map
        for (i, t) in module.types.enumerated() {
            let typeName = constantString(t.nameIndex)
            typeTable[typeName] = i
            var fieldMap: [String: Int] = [:]
            for (fi, (nameIdx, _)) in t.fields.enumerated() {
                fieldMap[constantString(nameIdx)] = fi
            }
            typeFieldIndices[typeName] = fieldMap
            if let parentIdx = t.parentTypeIndex {
                parentTypeMap[typeName] = constantString(parentIdx)
            }
            if t.isActor {
                actorTypeNames.insert(typeName)
            }
        }
    }

    private func constantString(_ index: UInt16) -> String {
        let i = Int(index)
        guard i < module.constantPool.count else { return "<invalid#\(i)>" }
        return module.constantPool[i].value
    }

    // MARK: - Execution

    /// Run the module by calling its `main` function.
    public func run() throws {
        guard let mainIdx = functionTable["main"] else {
            throw VMError.unknownFunction(name: "main")
        }

        // Initialize globals
        try initializeGlobals()

        // Set up main frame
        let mainFunc = module.functions[mainIdx]
        let frame = CallFrame(
            functionIndex: mainIdx,
            registerCount: Int(mainFunc.registerCount),
            returnRegister: nil,
            functionName: "main"
        )
        callStack.append(frame)

        // Execute
        try executeLoop()
    }

    /// Run the module using the cooperative scheduler for structured concurrency.
    /// Await calls actually suspend and resume via the Scheduler.
    public func runConcurrent() throws {
        guard let mainIdx = functionTable["main"] else {
            throw VMError.unknownFunction(name: "main")
        }

        try initializeGlobals()

        // Spawn root coroutine for main
        scheduler.spawn(
            functionIndex: mainIdx,
            functionName: "main"
        )

        // Run scheduler loop
        try scheduler.runToCompletion { [self] coroutine in
            try self.executeCoroutine(coroutine)
        }
    }

    /// Execute a single coroutine until it completes or suspends.
    private func executeCoroutine(_ coroutine: Coroutine) throws {
        currentCoroutine = coroutine

        if let saved = coroutine.savedState {
            // Resume: restore saved call stack
            callStack.append(contentsOf: saved.callStack)
            // Inject resume value into the destination register
            if let resumeVal = saved.resumeValue,
               let destReg = coroutine.awaitDestRegister,
               !callStack.isEmpty {
                callStack[callStack.count - 1].registers[Int(destReg)] = resumeVal
                arc.retain(resumeVal)
            }
            coroutine.savedState = nil
            coroutine.awaitDestRegister = nil
        } else {
            // Fresh start
            let f = module.functions[coroutine.functionIndex]
            var frame = CallFrame(
                functionIndex: coroutine.functionIndex,
                registerCount: Int(f.registerCount),
                returnRegister: nil,
                functionName: coroutine.functionName
            )
            for (i, arg) in coroutine.arguments.prefix(Int(f.parameterCount)).enumerated() {
                frame.registers[i] = arg
                arc.retain(arg)
            }
            callStack.append(frame)
            coroutine.start()
        }

        do {
            try executeLoop()
        } catch {
            // Propagate error: fail the coroutine and its parent
            if let vmError = error as? VMError {
                scheduler.fail(coroutine, with: vmError)
            } else {
                scheduler.fail(coroutine, with: .userException(message: error.localizedDescription))
            }
            currentCoroutine = nil
            throw error
        }

        // If we get here and the coroutine is still running (not suspended or terminal), it completed
        if case .running = coroutine.state {
            scheduler.complete(coroutine, with: lastReturnValue)
        }

        currentCoroutine = nil
    }

    /// Run a specific function by name with arguments.
    public func call(function name: String, args: [Value] = []) throws -> Value {
        guard let funcIdx = functionTable[name] else {
            // Check builtins
            if let builtin = builtins.lookup(name) {
                return try builtin(args)
            }
            throw VMError.unknownFunction(name: name)
        }

        let f = module.functions[funcIdx]
        let frame = CallFrame(
            functionIndex: funcIdx,
            registerCount: Int(f.registerCount),
            returnRegister: nil,
            functionName: name
        )
        callStack.append(frame)

        // Load arguments into registers for LOAD_PARAM to read
        for (i, arg) in args.prefix(Int(f.parameterCount)).enumerated() {
            callStack[callStack.count - 1].registers[i] = arg
        }

        try executeLoop()

        return .unit
    }

    private func initializeGlobals() throws {
        for (_, global) in module.globals.enumerated() {
            let nameIdx = global.nameIndex
            // Initialize with default value based on type
            switch global.typeTag {
            case .int, .int32, .int64:  globals[nameIdx] = .int(0)
            case .float, .float64, .double: globals[nameIdx] = .float(0.0)
            case .bool:                 globals[nameIdx] = .bool(false)
            case .string:               globals[nameIdx] = .string("")
            case .nullable:             globals[nameIdx] = .null
            default:                    globals[nameIdx] = .null
            }

            // Run initializer function if present
            if let initIdx = global.initializerFuncIndex {
                let initFuncName = constantString(initIdx)
                if let funcIndex = functionTable[initFuncName] {
                    let initFunc = module.functions[funcIndex]
                    let frame = CallFrame(
                        functionIndex: funcIndex,
                        registerCount: Int(initFunc.registerCount),
                        returnRegister: nil,
                        functionName: initFuncName
                    )
                    lastReturnValue = .unit
                    callStack.append(frame)
                    try executeLoop()
                    globals[nameIdx] = lastReturnValue
                }
            }
        }
    }

    // MARK: - Main Execution Loop

    private func executeLoop() throws {
        while !callStack.isEmpty {
            // Check for cancellation in coroutine mode
            if let coro = currentCoroutine, coro.isCancellationRequested {
                scheduler.cancel(coro)
                callStack.removeAll()
                return
            }

            let frameIdx = callStack.count - 1
            let f = module.functions[callStack[frameIdx].functionIndex]
            let bytecode = f.bytecode

            while callStack[frameIdx].pc < bytecode.count {
                let pc = callStack[frameIdx].pc
                guard let opcode = Opcode(rawValue: bytecode[pc]) else {
                    throw VMError.unknownOpcode(byte: bytecode[pc])
                }
                callStack[frameIdx].pc += 1

                if config.traceExecution {
                    trace(opcode: opcode, pc: pc, frame: callStack[frameIdx])
                }
                instructionCount += 1

                do { switch opcode {
                // MARK: Constants
                case .constInt:
                    let reg = readUInt16(bytecode, frame: frameIdx)
                    let val = readInt64(bytecode, frame: frameIdx)
                    callStack[frameIdx].registers[Int(reg)] = .int(val)

                case .constFloat:
                    let reg = readUInt16(bytecode, frame: frameIdx)
                    let val = readFloat64(bytecode, frame: frameIdx)
                    callStack[frameIdx].registers[Int(reg)] = .float(val)

                case .constTrue:
                    let reg = readUInt16(bytecode, frame: frameIdx)
                    callStack[frameIdx].registers[Int(reg)] = .bool(true)

                case .constFalse:
                    let reg = readUInt16(bytecode, frame: frameIdx)
                    callStack[frameIdx].registers[Int(reg)] = .bool(false)

                case .constString:
                    let reg = readUInt16(bytecode, frame: frameIdx)
                    let idx = readUInt16(bytecode, frame: frameIdx)
                    callStack[frameIdx].registers[Int(reg)] = .string(constantString(idx))

                case .constNull:
                    let reg = readUInt16(bytecode, frame: frameIdx)
                    callStack[frameIdx].registers[Int(reg)] = .null

                // MARK: Memory
                case .alloc:
                    // alloc is a MIR-level concept for reserving a register slot.
                    // The register is already initialized to .unit by frame creation.
                    // The actual value comes from a subsequent store instruction.
                    // We must NOT write to the register here, as it may already hold
                    // a parameter value placed by the caller.
                    let _ = readUInt16(bytecode, frame: frameIdx) // dest register
                    let _ = readUInt16(bytecode, frame: frameIdx) // type index

                case .store:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let src = readUInt16(bytecode, frame: frameIdx)
                    callStack[frameIdx].registers[Int(dest)] = callStack[frameIdx].registers[Int(src)]

                case .load:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let src = readUInt16(bytecode, frame: frameIdx)
                    callStack[frameIdx].registers[Int(dest)] = callStack[frameIdx].registers[Int(src)]

                case .loadParam:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let paramIdx = readUInt16(bytecode, frame: frameIdx)
                    // Parameters are stored in the first N registers by the caller
                    callStack[frameIdx].registers[Int(dest)] = callStack[frameIdx].registers[Int(paramIdx)]

                case .loadGlobal:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let nameIdx = readUInt16(bytecode, frame: frameIdx)
                    callStack[frameIdx].registers[Int(dest)] = globals[nameIdx] ?? .null

                case .storeGlobal:
                    let nameIdx = readUInt16(bytecode, frame: frameIdx)
                    let src = readUInt16(bytecode, frame: frameIdx)
                    let newValue = callStack[frameIdx].registers[Int(src)]
                    if let oldValue = globals[nameIdx] {
                        arc.release(oldValue)
                    }
                    globals[nameIdx] = newValue

                // MARK: Arithmetic
                case .add:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let lhs = callStack[frameIdx].registers[Int(readUInt16(bytecode, frame: frameIdx))]
                    let rhs = callStack[frameIdx].registers[Int(readUInt16(bytecode, frame: frameIdx))]
                    callStack[frameIdx].registers[Int(dest)] = try performAdd(lhs, rhs)

                case .sub:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let lhs = callStack[frameIdx].registers[Int(readUInt16(bytecode, frame: frameIdx))]
                    let rhs = callStack[frameIdx].registers[Int(readUInt16(bytecode, frame: frameIdx))]
                    callStack[frameIdx].registers[Int(dest)] = try performSub(lhs, rhs)

                case .mul:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let lhs = callStack[frameIdx].registers[Int(readUInt16(bytecode, frame: frameIdx))]
                    let rhs = callStack[frameIdx].registers[Int(readUInt16(bytecode, frame: frameIdx))]
                    callStack[frameIdx].registers[Int(dest)] = try performMul(lhs, rhs)

                case .div:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let lhs = callStack[frameIdx].registers[Int(readUInt16(bytecode, frame: frameIdx))]
                    let rhs = callStack[frameIdx].registers[Int(readUInt16(bytecode, frame: frameIdx))]
                    callStack[frameIdx].registers[Int(dest)] = try performDiv(lhs, rhs)

                case .mod:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let lhs = callStack[frameIdx].registers[Int(readUInt16(bytecode, frame: frameIdx))]
                    let rhs = callStack[frameIdx].registers[Int(readUInt16(bytecode, frame: frameIdx))]
                    callStack[frameIdx].registers[Int(dest)] = try performMod(lhs, rhs)

                case .neg:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let operand = callStack[frameIdx].registers[Int(readUInt16(bytecode, frame: frameIdx))]
                    switch operand {
                    case .int(let v):   callStack[frameIdx].registers[Int(dest)] = .int(-v)
                    case .float(let v): callStack[frameIdx].registers[Int(dest)] = .float(-v)
                    default: throw VMError.typeMismatch(expected: "numeric", actual: operand.typeName, operation: "neg")
                    }

                // MARK: Comparison
                case .eq:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let lhs = callStack[frameIdx].registers[Int(readUInt16(bytecode, frame: frameIdx))]
                    let rhs = callStack[frameIdx].registers[Int(readUInt16(bytecode, frame: frameIdx))]
                    callStack[frameIdx].registers[Int(dest)] = .bool(lhs == rhs)

                case .neq:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let lhs = callStack[frameIdx].registers[Int(readUInt16(bytecode, frame: frameIdx))]
                    let rhs = callStack[frameIdx].registers[Int(readUInt16(bytecode, frame: frameIdx))]
                    callStack[frameIdx].registers[Int(dest)] = .bool(lhs != rhs)

                case .lt:
                    try executeComparison(bytecode, frame: frameIdx, op: <)
                case .lte:
                    try executeComparison(bytecode, frame: frameIdx, op: <=)
                case .gt:
                    try executeComparison(bytecode, frame: frameIdx, op: >)
                case .gte:
                    try executeComparison(bytecode, frame: frameIdx, op: >=)

                // MARK: Logic
                case .and:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let lhs = callStack[frameIdx].registers[Int(readUInt16(bytecode, frame: frameIdx))]
                    let rhs = callStack[frameIdx].registers[Int(readUInt16(bytecode, frame: frameIdx))]
                    callStack[frameIdx].registers[Int(dest)] = .bool(lhs.isTruthy && rhs.isTruthy)

                case .or:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let lhs = callStack[frameIdx].registers[Int(readUInt16(bytecode, frame: frameIdx))]
                    let rhs = callStack[frameIdx].registers[Int(readUInt16(bytecode, frame: frameIdx))]
                    callStack[frameIdx].registers[Int(dest)] = .bool(lhs.isTruthy || rhs.isTruthy)

                case .not:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let operand = callStack[frameIdx].registers[Int(readUInt16(bytecode, frame: frameIdx))]
                    callStack[frameIdx].registers[Int(dest)] = .bool(!operand.isTruthy)

                // MARK: Calls
                case .call:
                    try executeCall(bytecode, frame: frameIdx)
                    // After call returns, we may have a different frame count
                    if callStack.isEmpty { return }
                    continue

                case .vcall:
                    try executeVirtualCall(bytecode, frame: frameIdx)
                    if callStack.isEmpty { return }
                    continue

                case .callIndirect:
                    try executeCallIndirect(bytecode, frame: frameIdx)
                    if callStack.isEmpty { return }
                    continue

                // MARK: Fields
                case .getField:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let objReg = readUInt16(bytecode, frame: frameIdx)
                    let fieldIdx = readUInt16(bytecode, frame: frameIdx)
                    let obj = callStack[frameIdx].registers[Int(objReg)]
                    let fieldName = constantString(fieldIdx)
                    let fieldResult = try getField(obj, fieldName: fieldName)
                    callStack[frameIdx].registers[Int(dest)] = fieldResult
                    arc.retain(fieldResult)

                case .setField:
                    let objReg = readUInt16(bytecode, frame: frameIdx)
                    let fieldIdx = readUInt16(bytecode, frame: frameIdx)
                    let valReg = readUInt16(bytecode, frame: frameIdx)
                    let obj = callStack[frameIdx].registers[Int(objReg)]
                    let fieldName = constantString(fieldIdx)
                    let value = callStack[frameIdx].registers[Int(valReg)]
                    try setField(obj, fieldName: fieldName, value: value)

                // MARK: Objects
                case .newObject:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let typeIdx = readUInt16(bytecode, frame: frameIdx)
                    let argCount = readUInt16(bytecode, frame: frameIdx)
                    var args: [Value] = []
                    for _ in 0..<argCount {
                        let argReg = readUInt16(bytecode, frame: frameIdx)
                        args.append(callStack[frameIdx].registers[Int(argReg)])
                    }
                    let typeName = constantString(typeIdx)
                    let objId = createObject(typeName: typeName, args: args)
                    callStack[frameIdx].registers[Int(dest)] = .objectRef(objId)

                // MARK: Null Safety
                case .nullCheck:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let operandReg = readUInt16(bytecode, frame: frameIdx)
                    let operand = callStack[frameIdx].registers[Int(operandReg)]
                    if case .null = operand {
                        throw VMError.nullPointerAccess(context: "null check failed")
                    }
                    callStack[frameIdx].registers[Int(dest)] = operand

                case .isNull:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let operandReg = readUInt16(bytecode, frame: frameIdx)
                    let operand = callStack[frameIdx].registers[Int(operandReg)]
                    callStack[frameIdx].registers[Int(dest)] = .bool(operand == .null)

                // MARK: Type Operations
                case .typeCheck:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let operandReg = readUInt16(bytecode, frame: frameIdx)
                    let typeIdx = readUInt16(bytecode, frame: frameIdx)
                    let operand = callStack[frameIdx].registers[Int(operandReg)]
                    let typeName = constantString(typeIdx)
                    callStack[frameIdx].registers[Int(dest)] = .bool(valueIsType(operand, typeName: typeName))

                case .typeCast:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let operandReg = readUInt16(bytecode, frame: frameIdx)
                    let typeIdx = readUInt16(bytecode, frame: frameIdx)
                    let operand = callStack[frameIdx].registers[Int(operandReg)]
                    let typeName = constantString(typeIdx)
                    guard valueIsType(operand, typeName: typeName) else {
                        throw VMError.invalidCast(from: operand.typeName, to: typeName)
                    }
                    callStack[frameIdx].registers[Int(dest)] = operand

                // MARK: String
                case .stringConcat:
                    let dest = readUInt16(bytecode, frame: frameIdx)
                    let count = readUInt16(bytecode, frame: frameIdx)
                    var parts: [String] = []
                    for _ in 0..<count {
                        let partReg = readUInt16(bytecode, frame: frameIdx)
                        parts.append(callStack[frameIdx].registers[Int(partReg)].description)
                    }
                    callStack[frameIdx].registers[Int(dest)] = .string(parts.joined())

                // MARK: Exception Handling
                case .tryBegin:
                    let catchOffset = readUInt32(bytecode, frame: frameIdx)
                    let excReg = readUInt16(bytecode, frame: frameIdx)
                    exceptionHandlers.append((catchPC: Int(catchOffset), exceptionReg: excReg, frameIndex: frameIdx))

                case .tryEnd:
                    if !exceptionHandlers.isEmpty {
                        exceptionHandlers.removeLast()
                    }

                case .throwOp:
                    let valReg = readUInt16(bytecode, frame: frameIdx)
                    let thrownValue = callStack[frameIdx].registers[Int(valReg)]
                    let message: String
                    if case .string(let s) = thrownValue {
                        message = s
                    } else {
                        message = thrownValue.description
                    }
                    try handleThrow(message: message, currentFrame: frameIdx)
                    // If handler was in the same frame, continue executing with updated PC
                    if callStack.count > frameIdx {
                        break
                    }
                    // Frames were unwound — return so the parent executeLoop picks up
                    return

                // MARK: Terminators
                case .ret:
                    let valReg = readUInt16(bytecode, frame: frameIdx)
                    let returnVal = callStack[frameIdx].registers[Int(valReg)]
                    let returnReg = callStack[frameIdx].returnRegister
                    // Release all registers except the return value
                    releaseFrame(frameIdx, exceptRegister: Int(valReg))
                    callStack.removeLast()
                    if let retReg = returnReg, !callStack.isEmpty {
                        callStack[callStack.count - 1].registers[Int(retReg)] = returnVal
                        arc.retain(returnVal)
                    } else {
                        // No caller frame — save for global initializers
                        lastReturnValue = returnVal
                    }
                    return

                case .retVoid:
                    // Release all registers in the frame
                    releaseFrame(frameIdx, exceptRegister: nil)
                    callStack.removeLast()
                    return

                case .jump:
                    let target = readUInt32(bytecode, frame: frameIdx)
                    callStack[frameIdx].pc = Int(target)

                case .branch:
                    let condReg = readUInt16(bytecode, frame: frameIdx)
                    let thenTarget = readUInt32(bytecode, frame: frameIdx)
                    let elseTarget = readUInt32(bytecode, frame: frameIdx)
                    let condition = callStack[frameIdx].registers[Int(condReg)]
                    callStack[frameIdx].pc = condition.isTruthy ? Int(thenTarget) : Int(elseTarget)

                // MARK: Concurrency
                case .awaitCall:
                    try executeAwaitCall(bytecode, frame: frameIdx)
                    if callStack.isEmpty { return }
                    continue

                case .concurrentBegin:
                    let scopeIdx = readUInt16(bytecode, frame: frameIdx)
                    pushConcurrentScope(scopeIdx)

                case .concurrentEnd:
                    let scopeIdx = readUInt16(bytecode, frame: frameIdx)
                    try executeConcurrentScope(scopeIdx)

                case .unreachable:
                    throw VMError.unreachable
                } // end switch
                } catch let error as VMError {
                    // If there's an exception handler, route the error there
                    if !exceptionHandlers.isEmpty {
                        let currentFrame = callStack.count - 1
                        try handleThrow(message: error.description, currentFrame: currentFrame)
                        // If handler was in the same frame, continue the loop with updated PC
                        if callStack.count > currentFrame {
                            continue
                        }
                        // Frames were unwound — return so parent executeLoop picks up
                        return
                    } else {
                        throw error
                    }
                } // end do/catch
            }

            // If we reach the end of bytecode without a terminator, pop frame
            releaseFrame(frameIdx, exceptRegister: nil)
            callStack.removeLast()
        }
    }

    // MARK: - Exception Handling

    /// Handle a throw by unwinding to the nearest catch handler.
    /// If no handler is found, re-throws as a Swift error.
    private func handleThrow(message: String, currentFrame: Int) throws {
        guard let handler = exceptionHandlers.popLast() else {
            // No handler — propagate as VM error
            throw VMError.userException(message: message)
        }

        // Unwind frames between current and handler's frame
        while callStack.count > handler.frameIndex + 1 {
            let topIdx = callStack.count - 1
            releaseFrame(topIdx, exceptRegister: nil)
            callStack.removeLast()
            // Remove any exception handlers from unwound frames
            exceptionHandlers.removeAll { $0.frameIndex >= callStack.count }
        }

        // Store exception message in the handler's register and jump to catch
        callStack[handler.frameIndex].registers[Int(handler.exceptionReg)] = .string(message)
        callStack[handler.frameIndex].pc = handler.catchPC
    }

    // MARK: - ARC Frame Cleanup

    /// Release all objectRef values in a frame's registers when it's being popped.
    /// Optionally skip one register (the return value being transferred to caller).
    /// Deduplicates objectRefs so each unique object is released only once,
    /// since register copies (store/load) don't retain.
    private func releaseFrame(_ frameIdx: Int, exceptRegister: Int?) {
        let registers = callStack[frameIdx].registers
        // Collect the objectID being returned so we never release it
        var excludedObjects = Set<Int>()
        if let er = exceptRegister, case .objectRef(let id) = registers[er] {
            excludedObjects.insert(id.index)
        }
        var releasedObjects = Set<Int>()
        for (i, value) in registers.enumerated() {
            if i == exceptRegister { continue }
            if case .objectRef(let id) = value {
                if excludedObjects.contains(id.index) { continue }
                if releasedObjects.contains(id.index) { continue }
                releasedObjects.insert(id.index)
            }
            arc.release(value)
        }
        arc.collectCyclesIfNeeded()
    }

    // MARK: - Byte Reading

    private func readUInt16(_ bytecode: [UInt8], frame: Int) -> UInt16 {
        let pc = callStack[frame].pc
        guard pc + 1 < bytecode.count else { callStack[frame].pc = bytecode.count; return 0 }
        let val = UInt16(bytecode[pc]) << 8 | UInt16(bytecode[pc + 1])
        callStack[frame].pc += 2
        return val
    }

    private func readUInt32(_ bytecode: [UInt8], frame: Int) -> UInt32 {
        let pc = callStack[frame].pc
        guard pc + 3 < bytecode.count else { callStack[frame].pc = bytecode.count; return 0 }
        let val = UInt32(bytecode[pc]) << 24 | UInt32(bytecode[pc+1]) << 16 |
                  UInt32(bytecode[pc+2]) << 8 | UInt32(bytecode[pc+3])
        callStack[frame].pc += 4
        return val
    }

    private func readInt64(_ bytecode: [UInt8], frame: Int) -> Int64 {
        let pc = callStack[frame].pc
        guard pc + 7 < bytecode.count else { callStack[frame].pc = bytecode.count; return 0 }
        var bits: UInt64 = 0
        for i in 0..<8 {
            bits = bits << 8 | UInt64(bytecode[pc + i])
        }
        callStack[frame].pc += 8
        return Int64(bitPattern: bits)
    }

    private func readFloat64(_ bytecode: [UInt8], frame: Int) -> Double {
        let pc = callStack[frame].pc
        guard pc + 7 < bytecode.count else { callStack[frame].pc = bytecode.count; return 0 }
        var bits: UInt64 = 0
        for i in 0..<8 {
            bits = bits << 8 | UInt64(bytecode[pc + i])
        }
        callStack[frame].pc += 8
        return Double(bitPattern: bits)
    }

    // MARK: - Arithmetic Helpers

    private func performAdd(_ lhs: Value, _ rhs: Value) throws -> Value {
        switch (lhs, rhs) {
        case (.int(let a), .int(let b)):     return .int(a &+ b)
        case (.float(let a), .float(let b)): return .float(a + b)
        case (.string(let a), .string(let b)): return .string(a + b)
        default: throw VMError.typeMismatch(expected: "matching types", actual: "\(lhs.typeName) + \(rhs.typeName)", operation: "add")
        }
    }

    private func performSub(_ lhs: Value, _ rhs: Value) throws -> Value {
        switch (lhs, rhs) {
        case (.int(let a), .int(let b)):     return .int(a &- b)
        case (.float(let a), .float(let b)): return .float(a - b)
        default: throw VMError.typeMismatch(expected: "numeric", actual: "\(lhs.typeName) - \(rhs.typeName)", operation: "sub")
        }
    }

    private func performMul(_ lhs: Value, _ rhs: Value) throws -> Value {
        switch (lhs, rhs) {
        case (.int(let a), .int(let b)):     return .int(a &* b)
        case (.float(let a), .float(let b)): return .float(a * b)
        default: throw VMError.typeMismatch(expected: "numeric", actual: "\(lhs.typeName) * \(rhs.typeName)", operation: "mul")
        }
    }

    private func performDiv(_ lhs: Value, _ rhs: Value) throws -> Value {
        switch (lhs, rhs) {
        case (.int(let a), .int(let b)):
            guard b != 0 else { throw VMError.divisionByZero }
            return .int(a / b)
        case (.float(let a), .float(let b)):
            guard b != 0.0 else { throw VMError.divisionByZero }
            return .float(a / b)
        default: throw VMError.typeMismatch(expected: "numeric", actual: "\(lhs.typeName) / \(rhs.typeName)", operation: "div")
        }
    }

    private func performMod(_ lhs: Value, _ rhs: Value) throws -> Value {
        switch (lhs, rhs) {
        case (.int(let a), .int(let b)):
            guard b != 0 else { throw VMError.divisionByZero }
            return .int(a % b)
        default: throw VMError.typeMismatch(expected: "Int", actual: "\(lhs.typeName) % \(rhs.typeName)", operation: "mod")
        }
    }

    // MARK: - Comparison Helper

    private func executeComparison(_ bytecode: [UInt8], frame: Int, op: (Int64, Int64) -> Bool) throws {
        let dest = readUInt16(bytecode, frame: frame)
        let lhs = callStack[frame].registers[Int(readUInt16(bytecode, frame: frame))]
        let rhs = callStack[frame].registers[Int(readUInt16(bytecode, frame: frame))]
        switch (lhs, rhs) {
        case (.int(let a), .int(let b)):
            callStack[frame].registers[Int(dest)] = .bool(op(a, b))
        case (.float(let a), .float(let b)):
            // Convert float comparison to int comparison semantics
            let result: Bool
            if a < b { result = op(-1, 0) }
            else if a > b { result = op(1, 0) }
            else { result = op(0, 0) }
            callStack[frame].registers[Int(dest)] = .bool(result)
        default:
            throw VMError.typeMismatch(expected: "numeric", actual: "\(lhs.typeName) cmp \(rhs.typeName)", operation: "comparison")
        }
    }

    // MARK: - Function Call

    private func executeCall(_ bytecode: [UInt8], frame frameIdx: Int) throws {
        let destReg = readUInt16(bytecode, frame: frameIdx)
        let funcIdx = readUInt16(bytecode, frame: frameIdx)
        let argCount = readUInt16(bytecode, frame: frameIdx)

        var args: [Value] = []
        for _ in 0..<argCount {
            let argReg = readUInt16(bytecode, frame: frameIdx)
            args.append(callStack[frameIdx].registers[Int(argReg)])
        }

        let funcName = constantString(funcIdx)

        // Module functions take precedence over builtins (user code shadows builtins)
        if let targetIdx = functionTable[funcName] {
            guard callStack.count < config.maxCallStackDepth else {
                throw VMError.stackOverflow(depth: callStack.count)
            }

            let targetFunc = module.functions[targetIdx]
            let returnReg: UInt16? = destReg != 0xFFFF ? destReg : nil

            var newFrame = CallFrame(
                functionIndex: targetIdx,
                registerCount: Int(targetFunc.registerCount),
                returnRegister: returnReg,
                functionName: funcName
            )

            // Pass arguments: store in first N registers (for LOAD_PARAM to read)
            for (i, arg) in args.prefix(Int(targetFunc.parameterCount)).enumerated() {
                newFrame.registers[i] = arg
                arc.retain(arg)
            }

            callStack.append(newFrame)

            // Execute the called function
            try executeLoop()
        } else if let builtin = builtins.lookup(funcName) {
            // Fall back to built-in functions
            let result = try builtin(args)
            if destReg != 0xFFFF {
                callStack[frameIdx].registers[Int(destReg)] = result
                arc.retain(result)
            }
        } else {
            throw VMError.unknownFunction(name: funcName)
        }
    }

    // MARK: - Await Call

    /// Execute an await call — either synchronously (run mode) or via scheduler (runConcurrent mode).
    private func executeAwaitCall(_ bytecode: [UInt8], frame frameIdx: Int) throws {
        let destReg = readUInt16(bytecode, frame: frameIdx)
        let funcIdx = readUInt16(bytecode, frame: frameIdx)
        let argCount = readUInt16(bytecode, frame: frameIdx)

        var args: [Value] = []
        for _ in 0..<argCount {
            let argReg = readUInt16(bytecode, frame: frameIdx)
            args.append(callStack[frameIdx].registers[Int(argReg)])
        }

        let funcName = constantString(funcIdx)

        // Check builtins first (builtins are always synchronous)
        if let builtin = builtins.lookup(funcName) {
            let result = try builtin(args)
            if destReg != 0xFFFF {
                callStack[frameIdx].registers[Int(destReg)] = result
                arc.retain(result)
            }
            return
        }

        // Module function
        guard let targetIdx = functionTable[funcName] else {
            throw VMError.unknownFunction(name: funcName)
        }

        guard callStack.count < config.maxCallStackDepth else {
            throw VMError.stackOverflow(depth: callStack.count)
        }

        // --- Coroutine mode: spawn child, suspend parent ---
        if let parentCoro = currentCoroutine {
            let childCoro = scheduler.spawn(
                functionIndex: targetIdx,
                functionName: funcName,
                arguments: args,
                parent: parentCoro
            )

            // Track child in concurrent scope if active
            if !concurrentScopes.isEmpty {
                concurrentScopes[concurrentScopes.count - 1].spawnedCoroutines.append(childCoro)
            }

            // When child completes, resume parent with the result
            childCoro.completionContinuation = { [weak self] result in
                guard let self = self else { return }
                self.scheduler.resume(parentCoro, with: result)
            }

            // Save parent state and suspend
            parentCoro.awaitDestRegister = destReg != 0xFFFF ? destReg : nil
            scheduler.suspend(parentCoro, callStack: callStack)
            callStack.removeAll()
            return
        }

        // --- Synchronous mode (unchanged) ---
        let coroutine = scheduler.spawn(
            functionIndex: targetIdx,
            functionName: funcName,
            arguments: args
        )
        coroutine.start()

        let targetFunc = module.functions[targetIdx]
        let returnReg: UInt16? = destReg != 0xFFFF ? destReg : nil

        var newFrame = CallFrame(
            functionIndex: targetIdx,
            registerCount: Int(targetFunc.registerCount),
            returnRegister: returnReg,
            functionName: funcName
        )

        for (i, arg) in args.prefix(Int(targetFunc.parameterCount)).enumerated() {
            newFrame.registers[i] = arg
            arc.retain(arg)
        }

        callStack.append(newFrame)
        try executeLoop()

        let resultVal = lastReturnValue
        scheduler.complete(coroutine, with: resultVal)
    }

    // MARK: - Concurrent Scopes

    private func pushConcurrentScope(_ scopeIdx: UInt16) {
        concurrentScopes.append(ConcurrentScope(scopeIdx: scopeIdx))
    }

    private func executeConcurrentScope(_ scopeIdx: UInt16) throws {
        guard let scope = concurrentScopes.last, scope.scopeIdx == scopeIdx else {
            throw VMError.invalidBytecode(detail: "concurrent scope mismatch")
        }
        concurrentScopes.removeLast()

        // Coroutine mode: wait for all children in this scope to complete
        if let parentCoro = currentCoroutine, !parentCoro.allChildrenComplete {
            scheduler.awaitChildren(parentCoro, callStack: callStack)
            callStack.removeAll()
            return
        }

        // Synchronous mode: coroutines already executed inline
    }

    // MARK: - Indirect Call

    private func executeCallIndirect(_ bytecode: [UInt8], frame frameIdx: Int) throws {
        let destReg = readUInt16(bytecode, frame: frameIdx)
        let funcRefReg = readUInt16(bytecode, frame: frameIdx)
        let argCount = readUInt16(bytecode, frame: frameIdx)

        var args: [Value] = []
        for _ in 0..<argCount {
            let argReg = readUInt16(bytecode, frame: frameIdx)
            args.append(callStack[frameIdx].registers[Int(argReg)])
        }

        // Read function reference from register (string or closure list)
        let funcRef = callStack[frameIdx].registers[Int(funcRefReg)]
        let funcName: String
        switch funcRef {
        case .string(let name):
            funcName = name
        case .objectRef(let objId):
            // Closure: list where [0] = function name, [1..] = captured values
            if let listStorage = (try? arcHeap.get(objId))?.listStorage, !listStorage.isEmpty,
               case .string(let name) = listStorage[0] {
                funcName = name
                // Prepend captured values before user args
                let capturedArgs = Array(listStorage.dropFirst())
                args = capturedArgs + args
            } else {
                throw VMError.typeMismatch(expected: "String (function reference)", actual: funcRef.typeName, operation: "CALL_INDIRECT")
            }
        default:
            throw VMError.typeMismatch(expected: "String (function reference)", actual: funcRef.typeName, operation: "CALL_INDIRECT")
        }

        // Check builtins first
        if let builtin = builtins.lookup(funcName) {
            let result = try builtin(args)
            if destReg != 0xFFFF {
                callStack[frameIdx].registers[Int(destReg)] = result
                arc.retain(result)
            }
            return
        }

        // Module function
        guard let targetIdx = functionTable[funcName] else {
            throw VMError.unknownFunction(name: funcName)
        }

        guard callStack.count < config.maxCallStackDepth else {
            throw VMError.stackOverflow(depth: callStack.count)
        }

        let targetFunc = module.functions[targetIdx]
        let returnReg: UInt16? = destReg != 0xFFFF ? destReg : nil

        var newFrame = CallFrame(
            functionIndex: targetIdx,
            registerCount: Int(targetFunc.registerCount),
            returnRegister: returnReg,
            functionName: funcName
        )

        for (i, arg) in args.prefix(Int(targetFunc.parameterCount)).enumerated() {
            newFrame.registers[i] = arg
            arc.retain(arg)
        }

        callStack.append(newFrame)
        try executeLoop()
    }

    // MARK: - Virtual Call

    private func executeVirtualCall(_ bytecode: [UInt8], frame frameIdx: Int) throws {
        let destReg = readUInt16(bytecode, frame: frameIdx)
        let objReg = readUInt16(bytecode, frame: frameIdx)
        let methodIdx = readUInt16(bytecode, frame: frameIdx)
        let argCount = readUInt16(bytecode, frame: frameIdx)

        var args: [Value] = []
        for _ in 0..<argCount {
            let argReg = readUInt16(bytecode, frame: frameIdx)
            args.append(callStack[frameIdx].registers[Int(argReg)])
        }

        let obj = callStack[frameIdx].registers[Int(objReg)]
        let methodName = constantString(methodIdx)

        // Actor message routing: in coroutine mode, route actor calls through mailbox
        if let parentCoro = currentCoroutine,
           case .objectRef(let objId) = obj,
           let actorId = actorObjectMap[objId.index] {
            try executeActorCall(
                actorId: actorId,
                objectId: objId,
                obj: obj,
                methodName: methodName,
                args: args,
                destReg: destReg,
                frameIdx: frameIdx,
                parentCoro: parentCoro
            )
            return
        }

        // Resolve the method: try runtime type first, walk parent chain, then bare name
        let resolvedName: String
        if case .objectRef(let objId) = obj,
           let runtimeTypeName = arcHeap.typeName(of: objId) {
            // Walk the type hierarchy: runtime type → parent → grandparent → ...
            var currentType: String? = runtimeTypeName
            var found: String? = nil
            while let typeName = currentType {
                let qualified = "\(typeName).\(methodName)"
                if functionTable[qualified] != nil {
                    found = qualified
                    break
                }
                currentType = parentTypeMap[typeName]
            }
            resolvedName = found ?? methodName
        } else if functionTable[methodName] != nil {
            resolvedName = methodName
        } else {
            resolvedName = methodName
        }

        if let funcIndex = functionTable[resolvedName] {
            guard callStack.count < config.maxCallStackDepth else {
                throw VMError.stackOverflow(depth: callStack.count)
            }

            let targetFunc = module.functions[funcIndex]
            let returnReg: UInt16? = destReg != 0xFFFF ? destReg : nil

            var newFrame = CallFrame(
                functionIndex: funcIndex,
                registerCount: Int(targetFunc.registerCount),
                returnRegister: returnReg,
                functionName: resolvedName
            )

            // First arg is `this` (the object)
            newFrame.registers[0] = obj
            arc.retain(obj)
            for (i, arg) in args.prefix(Int(targetFunc.parameterCount)).enumerated() {
                newFrame.registers[i + 1] = arg
                arc.retain(arg)
            }

            callStack.append(newFrame)
            try executeLoop()
        } else if let builtin = builtins.lookup(methodName) {
            let allArgs = [obj] + args
            let result = try builtin(allArgs)
            if destReg != 0xFFFF {
                callStack[frameIdx].registers[Int(destReg)] = result
                arc.retain(result)
            }
        } else {
            throw VMError.unknownFunction(name: resolvedName)
        }
    }

    // MARK: - Actor Call

    /// Route a method call on an actor through the mailbox.
    /// Spawns a coroutine to process the message and suspends the caller.
    private func executeActorCall(
        actorId: ActorID,
        objectId: ObjectID,
        obj: Value,
        methodName: String,
        args: [Value],
        destReg: UInt16,
        frameIdx: Int,
        parentCoro: Coroutine
    ) throws {
        let runtimeTypeName = arcHeap.typeName(of: objectId) ?? "Unknown"

        // Walk type hierarchy to find the method
        var currentType: String? = runtimeTypeName
        var resolvedName: String? = nil
        while let typeName = currentType {
            let qualified = "\(typeName).\(methodName)"
            if functionTable[qualified] != nil {
                resolvedName = qualified
                break
            }
            currentType = parentTypeMap[typeName]
        }

        guard let funcName = resolvedName, let funcIndex = functionTable[funcName] else {
            throw VMError.unknownFunction(name: "\(runtimeTypeName).\(methodName)")
        }

        // Spawn a coroutine to execute the actor method
        let childCoro = scheduler.spawn(
            functionIndex: funcIndex,
            functionName: funcName,
            arguments: [obj] + args,
            parent: parentCoro
        )

        // When child completes, resume parent with the result and finish mailbox processing
        childCoro.completionContinuation = { [weak self] result in
            guard let self = self else { return }
            self.actorRuntime.finishProcessing(for: actorId)
            self.scheduler.resume(parentCoro, with: result)
        }

        // Enqueue the message in the actor's mailbox
        try actorRuntime.send(
            to: actorId,
            method: funcName,
            arguments: [obj] + args,
            senderCoroutine: parentCoro.id
        )

        // Dequeue immediately (actor processes one message at a time)
        _ = actorRuntime.processNext(for: actorId)

        // Suspend the caller
        parentCoro.awaitDestRegister = destReg != 0xFFFF ? destReg : nil
        scheduler.suspend(parentCoro, callStack: callStack)
        callStack.removeAll()
    }

    // MARK: - Object Management (ARC-backed)

    private func createObject(typeName: String, args: [Value]) -> ObjectID {
        var fields: [String: Value] = [:]

        // Look up type to get field names
        if let typeIdx = typeTable[typeName],
           typeIdx < module.types.count {
            let typeDecl = module.types[typeIdx]
            for (i, (nameIdx, _)) in typeDecl.fields.enumerated() {
                let fieldName = constantString(nameIdx)
                if i < args.count {
                    fields[fieldName] = args[i]
                } else {
                    fields[fieldName] = .null
                }
            }
        } else {
            // No type info — store positionally
            for (i, arg) in args.enumerated() {
                fields["$\(i)"] = arg
            }
        }

        let id = arcHeap.allocate(typeName: typeName, fields: fields)

        // Retain any object references stored as fields
        for fieldValue in fields.values {
            arc.retain(fieldValue)
        }

        // Register actor instances for message-passing dispatch
        if actorTypeNames.contains(typeName) {
            let actorInstance = actorRuntime.createActor(typeName: typeName, objectID: id)
            actorObjectMap[id.index] = actorInstance.id
        }

        return id
    }

    private func getField(_ value: Value, fieldName: String) throws -> Value {
        guard case .objectRef(let id) = value else {
            if case .null = value {
                throw VMError.nullPointerAccess(context: "field access '\(fieldName)' on null")
            }
            throw VMError.typeMismatch(expected: "Object", actual: value.typeName, operation: "getField(\(fieldName))")
        }
        return try arcHeap.getField(id, name: fieldName)
    }

    private func setField(_ value: Value, fieldName: String, value newValue: Value) throws {
        guard case .objectRef(let id) = value else {
            if case .null = value {
                throw VMError.nullPointerAccess(context: "field set '\(fieldName)' on null")
            }
            throw VMError.typeMismatch(expected: "Object", actual: value.typeName, operation: "setField(\(fieldName))")
        }
        // Write barrier: retain new value, release old value
        let oldValue = try arcHeap.setField(id, name: fieldName, value: newValue)
        arc.retain(newValue)
        arc.release(oldValue)
    }

    // MARK: - Type Checking

    private func valueIsType(_ value: Value, typeName: String) -> Bool {
        switch (value, typeName) {
        case (.int, "Int"), (.int, "Int64"):       return true
        case (.float, "Float64"), (.float, "Double"): return true
        case (.bool, "Bool"):                       return true
        case (.string, "String"):                   return true
        case (.null, _):                            return false
        case (.objectRef(let id), _):
            // Walk the type hierarchy for subtype checks
            var currentType: String? = arcHeap.typeName(of: id)
            while let ct = currentType {
                if ct == typeName { return true }
                currentType = parentTypeMap[ct]
            }
            return false
        default: return false
        }
    }

    // MARK: - Tracing

    private func trace(opcode: Opcode, pc: Int, frame: CallFrame) {
        let msg = "  [\(frame.functionName)] 0x\(String(format: "%04X", pc)): \(opcode)"
        if let capture = outputCapture {
            capture(msg)
        } else {
            Swift.print(msg)
        }
    }

    // MARK: - Stack Trace

    /// Build a stack trace from the current call stack state.
    public func captureStackTrace(error: VMError) -> StackTrace {
        let frames = callStack.reversed().map { frame in
            let func_ = module.functions[frame.functionIndex]
            let line = func_.sourceLine(at: frame.pc)
            return StackTraceFrame(functionName: frame.functionName, bytecodeOffset: frame.pc, sourceLine: line)
        }
        return StackTrace(error: error, frames: frames)
    }

    // MARK: - GC Stats

    /// Print GC/ARC statistics (for --gc-stats flag).
    public func printGCStats() {
        let output = """
        \(arcHeap.statsDescription)
        \(arc.statsDescription)
        \(arc.cycleDetector.statsDescription)
          Instructions executed: \(instructionCount)
        """
        if let capture = outputCapture {
            capture(output)
        } else {
            Swift.print(output)
        }
    }
}
