// InliningPass.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - Function Inlining Pass

/// Inlines small, single-block, non-recursive functions at their call sites.
/// This enables downstream optimizations like escape analysis and stack promotion
/// by making callee instructions visible in the caller's scope.
internal final class InliningPass: MIRPass {
    var name: String { "Inlining" }

    /// Maximum instruction count for a function to be inlinable.
    private let maxInstructionCount = 20

    func run(_ module: MIRModule) -> MIRModule {
        let functionMap = Dictionary(uniqueKeysWithValues: module.functions.map { ($0.name, $0) })
        let typeMap = Dictionary(uniqueKeysWithValues: module.types.map { ($0.name, $0) })

        var result = module
        for i in 0..<result.functions.count {
            result.functions[i] = inlineCalls(in: result.functions[i], functionMap: functionMap, typeMap: typeMap)
        }
        return result
    }

    /// Check if a function is eligible for inlining:
    /// - Single basic block (no control flow)
    /// - Small instruction count
    /// - Not recursive
    /// - Not main
    /// - Has at least one value-type parameter or returns a value type
    private func isInlinable(_ function: MIRFunction, typeMap: [String: MIRTypeDecl]) -> Bool {
        guard function.blocks.count == 1 else { return false }
        guard function.instructionCount <= maxInstructionCount else { return false }
        guard function.name != "main" else { return false }
        // Must involve value types (this pass is specifically for enabling stack promotion)
        let hasValueTypeParam = function.parameters.contains { (_, type) in
            if case .reference(let name) = type { return typeMap[name]?.isValueType ?? false }
            return false
        }
        let returnsValueType: Bool
        if case .reference(let name) = function.returnType {
            returnsValueType = typeMap[name]?.isValueType ?? false
        } else {
            returnsValueType = false
        }
        guard hasValueTypeParam || returnsValueType else { return false }
        // Check for recursion (calls itself)
        for block in function.blocks {
            for inst in block.instructions {
                if case .call(_, let callee, _) = inst, callee == function.name {
                    return false
                }
            }
        }
        return true
    }

    private func inlineCalls(in function: MIRFunction, functionMap: [String: MIRFunction], typeMap: [String: MIRTypeDecl]) -> MIRFunction {
        var f = function
        var tempCounter = highestTempNumber(in: f) + 1

        for blockIdx in 0..<f.blocks.count {
            var newInstructions: [MIRInstruction] = []

            for inst in f.blocks[blockIdx].instructions {
                guard case .call(let callDest, let calleeName, let args) = inst,
                      let callee = functionMap[calleeName],
                      isInlinable(callee, typeMap: typeMap) else {
                    newInstructions.append(inst)
                    continue
                }

                // Inline the callee
                let block = callee.blocks[0]

                // Build temp renaming map: old temp → new temp
                var renameMap: [String: String] = [:]
                func freshTemp() -> String {
                    let t = "%t\(tempCounter)"
                    tempCounter += 1
                    return t
                }

                // Map parameter locals to argument temps.
                // The callee's pattern: alloc param local, load param.X, store local, ...
                // We map "param.X" → args[i] (the caller's argument temp)
                for (i, (paramName, _)) in callee.parameters.enumerated() {
                    if i < args.count {
                        renameMap["param.\(paramName)"] = args[i]
                    }
                }

                // First pass: assign fresh temps for all dests
                for calleeInst in block.instructions {
                    if let dest = calleeInst.dest {
                        renameMap[dest] = freshTemp()
                    }
                }

                // Second pass: emit renamed instructions, skipping parameter boilerplate
                for calleeInst in block.instructions {
                    // Skip alloc instructions for parameter locals (they become the caller's args)
                    if case .alloc(let dest, _) = calleeInst {
                        // Check if this alloc corresponds to a parameter local
                        // The callee pattern is: alloc %tN, store %tN, (load param.X)
                        // We skip allocs that are only used to hold parameter values
                        if isParamAlloc(dest, callee: callee, renameMap: renameMap) {
                            continue
                        }
                    }
                    // Skip store(paramAlloc, loadOfParam) — the parameter copy
                    if case .store(let dest, let src) = calleeInst {
                        if isParamAllocDest(dest, callee: callee) && isParamLoad(src, callee: callee) {
                            // Map the alloc dest to the same value as the param
                            if let paramTemp = renameMap[src] ?? paramSourceForLoad(src, callee: callee, renameMap: renameMap) {
                                renameMap[dest] = paramTemp
                            }
                            continue
                        }
                    }
                    // Skip load(dest, param.X) — direct param loads get mapped
                    if case .load(let dest, let src) = calleeInst, src.hasPrefix("param.") {
                        if let mapped = renameMap[src] {
                            renameMap[dest] = mapped
                        }
                        continue
                    }

                    let renamed = renameInstruction(calleeInst, renameMap: renameMap)
                    newInstructions.append(renamed)
                }

                // Handle the return value: the callee's terminator is ret(val)
                // Allocate storage for the call destination and store the returned value
                if let callDest = callDest, let term = block.terminator {
                    if case .ret(let retVal) = term, let retVal = retVal {
                        let mappedRetVal = renameMap[retVal] ?? retVal
                        // Allocate the call dest temp so it can be loaded later
                        newInstructions.append(.alloc(dest: callDest, type: callee.returnType))
                        newInstructions.append(.store(dest: callDest, src: mappedRetVal))
                    }
                }
            }

            f.blocks[blockIdx].instructions = newInstructions
        }

        return f
    }

    // MARK: - Helpers

    /// Check if an alloc dest is used as a parameter local in the callee.
    private func isParamAlloc(_ dest: String, callee: MIRFunction, renameMap: [String: String]) -> Bool {
        let block = callee.blocks[0]
        // Pattern: alloc %tN, then store %tN src where src is a load of param.X
        for (i, inst) in block.instructions.enumerated() {
            if case .alloc(let d, _) = inst, d == dest {
                // Look ahead for store(dest, loadOfParam)
                if i + 2 < block.instructions.count {
                    if case .load(let loadDest, let loadSrc) = block.instructions[i + 1],
                       loadSrc.hasPrefix("param.") {
                        if case .store(let storeDest, let storeSrc) = block.instructions[i + 2],
                           storeDest == dest, storeSrc == loadDest {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    /// Check if a dest is a parameter alloc.
    private func isParamAllocDest(_ dest: String, callee: MIRFunction) -> Bool {
        let block = callee.blocks[0]
        for (i, inst) in block.instructions.enumerated() {
            if case .alloc(let d, _) = inst, d == dest {
                if i + 2 < block.instructions.count {
                    if case .load(_, let loadSrc) = block.instructions[i + 1],
                       loadSrc.hasPrefix("param.") {
                        if case .store(let storeDest, _) = block.instructions[i + 2],
                           storeDest == dest {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    /// Check if a temp is a load from a param.
    private func isParamLoad(_ temp: String, callee: MIRFunction) -> Bool {
        let block = callee.blocks[0]
        for inst in block.instructions {
            if case .load(let dest, let src) = inst, dest == temp, src.hasPrefix("param.") {
                return true
            }
        }
        return false
    }

    /// For a load of param.X, find what the param maps to in the caller.
    private func paramSourceForLoad(_ loadTemp: String, callee: MIRFunction, renameMap: [String: String]) -> String? {
        let block = callee.blocks[0]
        for inst in block.instructions {
            if case .load(let dest, let src) = inst, dest == loadTemp, src.hasPrefix("param.") {
                return renameMap[src]
            }
        }
        return nil
    }

    /// Rename all temps in an instruction according to the renaming map.
    private func renameInstruction(_ inst: MIRInstruction, renameMap: [String: String]) -> MIRInstruction {
        func r(_ t: String) -> String { renameMap[t] ?? t }
        func rOpt(_ t: String?) -> String? { t.map { renameMap[$0] ?? $0 } }

        switch inst {
        case .constInt(let d, let v):       return .constInt(dest: r(d), value: v)
        case .constFloat(let d, let v):     return .constFloat(dest: r(d), value: v)
        case .constBool(let d, let v):      return .constBool(dest: r(d), value: v)
        case .constString(let d, let v):    return .constString(dest: r(d), value: v)
        case .constNull(let d):             return .constNull(dest: r(d))
        case .alloc(let d, let t):          return .alloc(dest: r(d), type: t)
        case .store(let d, let s):          return .store(dest: r(d), src: r(s))
        case .load(let d, let s):           return .load(dest: r(d), src: r(s))
        case .add(let d, let l, let rh, let t): return .add(dest: r(d), lhs: r(l), rhs: r(rh), type: t)
        case .sub(let d, let l, let rh, let t): return .sub(dest: r(d), lhs: r(l), rhs: r(rh), type: t)
        case .mul(let d, let l, let rh, let t): return .mul(dest: r(d), lhs: r(l), rhs: r(rh), type: t)
        case .div(let d, let l, let rh, let t): return .div(dest: r(d), lhs: r(l), rhs: r(rh), type: t)
        case .mod(let d, let l, let rh, let t): return .mod(dest: r(d), lhs: r(l), rhs: r(rh), type: t)
        case .neg(let d, let o, let t):     return .neg(dest: r(d), operand: r(o), type: t)
        case .eq(let d, let l, let rh, let t):  return .eq(dest: r(d), lhs: r(l), rhs: r(rh), type: t)
        case .neq(let d, let l, let rh, let t): return .neq(dest: r(d), lhs: r(l), rhs: r(rh), type: t)
        case .lt(let d, let l, let rh, let t):  return .lt(dest: r(d), lhs: r(l), rhs: r(rh), type: t)
        case .lte(let d, let l, let rh, let t): return .lte(dest: r(d), lhs: r(l), rhs: r(rh), type: t)
        case .gt(let d, let l, let rh, let t):  return .gt(dest: r(d), lhs: r(l), rhs: r(rh), type: t)
        case .gte(let d, let l, let rh, let t): return .gte(dest: r(d), lhs: r(l), rhs: r(rh), type: t)
        case .and(let d, let l, let rh):    return .and(dest: r(d), lhs: r(l), rhs: r(rh))
        case .or(let d, let l, let rh):     return .or(dest: r(d), lhs: r(l), rhs: r(rh))
        case .not(let d, let o):            return .not(dest: r(d), operand: r(o))
        case .call(let d, let f, let a):    return .call(dest: rOpt(d), function: f, args: a.map { r($0) })
        case .virtualCall(let d, let o, let m, let a):
            return .virtualCall(dest: rOpt(d), object: r(o), method: m, args: a.map { r($0) })
        case .callIndirect(let d, let f, let a):
            return .callIndirect(dest: rOpt(d), functionRef: r(f), args: a.map { r($0) })
        case .getField(let d, let o, let f): return .getField(dest: r(d), object: r(o), fieldName: f)
        case .setField(let o, let f, let v): return .setField(object: r(o), fieldName: f, value: r(v))
        case .newObject(let d, let t, let a): return .newObject(dest: r(d), typeName: t, args: a.map { r($0) })
        case .nullCheck(let d, let o):      return .nullCheck(dest: r(d), operand: r(o))
        case .isNull(let d, let o):         return .isNull(dest: r(d), operand: r(o))
        case .typeCheck(let d, let o, let t): return .typeCheck(dest: r(d), operand: r(o), typeName: t)
        case .typeCast(let d, let o, let t): return .typeCast(dest: r(d), operand: r(o), typeName: t)
        case .stringConcat(let d, let p):   return .stringConcat(dest: r(d), parts: p.map { r($0) })
        case .tryBegin(let c, let e):       return .tryBegin(catchLabel: c, exceptionDest: r(e))
        case .tryEnd:                       return .tryEnd
        case .awaitCall(let d, let f, let a): return .awaitCall(dest: rOpt(d), function: f, args: a.map { r($0) })
        case .concurrentBegin(let s):       return .concurrentBegin(scopeId: s)
        case .concurrentEnd(let s):         return .concurrentEnd(scopeId: s)
        }
    }

    /// Find the highest %tN number used in the function.
    private func highestTempNumber(in function: MIRFunction) -> Int {
        var max = 0
        for block in function.blocks {
            for inst in block.instructions {
                if let dest = inst.dest {
                    if let n = extractTempNumber(dest) { max = Swift.max(max, n) }
                }
                for op in inst.operands {
                    if let n = extractTempNumber(op) { max = Swift.max(max, n) }
                }
            }
        }
        return max
    }

    private func extractTempNumber(_ temp: String) -> Int? {
        let s = temp.hasPrefix("%") ? String(temp.dropFirst()) : temp
        guard s.hasPrefix("t") else { return nil }
        return Int(s.dropFirst())
    }
}
