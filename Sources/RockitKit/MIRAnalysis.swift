// MIRAnalysis.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - MIRInstruction Analysis

extension MIRInstruction {

    /// The temp written by this instruction, or nil if it does not produce a value.
    public var dest: String? {
        switch self {
        case .constInt(let d, _),
             .constFloat(let d, _),
             .constBool(let d, _),
             .constString(let d, _),
             .constNull(let d):
            return d
        case .alloc(let d, _),
             .load(let d, _):
            return d
        case .store:
            return nil
        case .add(let d, _, _, _),
             .sub(let d, _, _, _),
             .mul(let d, _, _, _),
             .div(let d, _, _, _),
             .mod(let d, _, _, _),
             .neg(let d, _, _):
            return d
        case .eq(let d, _, _, _),
             .neq(let d, _, _, _),
             .lt(let d, _, _, _),
             .lte(let d, _, _, _),
             .gt(let d, _, _, _),
             .gte(let d, _, _, _):
            return d
        case .and(let d, _, _),
             .or(let d, _, _),
             .not(let d, _):
            return d
        case .call(let d, _, _):
            return d
        case .callIndirect(let d, _, _):
            return d
        case .virtualCall(let d, _, _, _):
            return d
        case .getField(let d, _, _):
            return d
        case .setField:
            return nil
        case .newObject(let d, _, _):
            return d
        case .nullCheck(let d, _),
             .isNull(let d, _):
            return d
        case .typeCheck(let d, _, _),
             .typeCast(let d, _, _):
            return d
        case .stringConcat(let d, _):
            return d
        case .tryBegin(_, let d):
            return d
        case .tryEnd:
            return nil
        case .awaitCall(let d, _, _):
            return d
        case .concurrentBegin, .concurrentEnd:
            return nil
        }
    }

    /// All temp names read (used) by this instruction.
    public var operands: [String] {
        switch self {
        case .constInt, .constFloat, .constBool, .constString, .constNull:
            return []
        case .alloc:
            return []
        case .store(let d, let s):
            return [d, s]
        case .load(_, let s):
            return [s]
        case .add(_, let l, let r, _),
             .sub(_, let l, let r, _),
             .mul(_, let l, let r, _),
             .div(_, let l, let r, _),
             .mod(_, let l, let r, _):
            return [l, r]
        case .neg(_, let o, _):
            return [o]
        case .eq(_, let l, let r, _),
             .neq(_, let l, let r, _),
             .lt(_, let l, let r, _),
             .lte(_, let l, let r, _),
             .gt(_, let l, let r, _),
             .gte(_, let l, let r, _):
            return [l, r]
        case .and(_, let l, let r),
             .or(_, let l, let r):
            return [l, r]
        case .not(_, let o):
            return [o]
        case .call(_, _, let args):
            return args
        case .callIndirect(_, let ref, let args):
            return [ref] + args
        case .virtualCall(_, let obj, _, let args):
            return [obj] + args
        case .getField(_, let obj, _):
            return [obj]
        case .setField(let obj, _, let v):
            return [obj, v]
        case .newObject(_, _, let args):
            return args
        case .nullCheck(_, let o),
             .isNull(_, let o):
            return [o]
        case .typeCheck(_, let o, _),
             .typeCast(_, let o, _):
            return [o]
        case .stringConcat(_, let parts):
            return parts
        case .tryBegin(_, let d):
            return [d]
        case .tryEnd:
            return []
        case .awaitCall(_, _, let args):
            return args
        case .concurrentBegin, .concurrentEnd:
            return []
        }
    }

    /// Whether this instruction has side effects beyond writing to its dest temp.
    public var hasSideEffects: Bool {
        switch self {
        case .store, .setField:
            return true
        case .call, .callIndirect, .virtualCall, .awaitCall:
            return true
        case .newObject:
            return true
        case .nullCheck:
            return true
        case .tryBegin, .tryEnd:
            return true
        case .concurrentBegin, .concurrentEnd:
            return true
        default:
            return false
        }
    }
}

// MARK: - MIRTerminator Analysis

extension MIRTerminator {

    /// Temp names used by this terminator.
    public var operands: [String] {
        switch self {
        case .ret(let v):
            return v.map { [$0] } ?? []
        case .jump:
            return []
        case .branch(let cond, _, _):
            return [cond]
        case .throwValue(let v):
            return [v]
        case .unreachable:
            return []
        }
    }

    /// Block labels this terminator can jump to.
    public var successorLabels: [String] {
        switch self {
        case .ret, .unreachable, .throwValue:
            return []
        case .jump(let label):
            return [label]
        case .branch(_, let t, let e):
            return [t, e]
        }
    }
}

// MARK: - Reachability

/// Compute the set of reachable block labels from the entry block.
public func reachableBlocks(in function: MIRFunction) -> Set<String> {
    guard let entry = function.blocks.first else { return [] }
    var visited = Set<String>()
    var worklist = [entry.label]
    let blockMap = Dictionary(uniqueKeysWithValues: function.blocks.map { ($0.label, $0) })

    while let label = worklist.popLast() {
        guard visited.insert(label).inserted else { continue }
        if let block = blockMap[label] {
            // Check instructions for exception handler targets
            for inst in block.instructions {
                if case .tryBegin(let catchLabel, _) = inst {
                    if !visited.contains(catchLabel) {
                        worklist.append(catchLabel)
                    }
                }
            }
            if let term = block.terminator {
                for succ in term.successorLabels {
                    if !visited.contains(succ) {
                        worklist.append(succ)
                    }
                }
            }
        }
    }
    return visited
}
