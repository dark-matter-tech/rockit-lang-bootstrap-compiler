// ConstantFoldingPass.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - Constant Value

/// A compile-time constant value tracked during folding.
internal enum ConstantValue {
    case int(Int64)
    case float(Double)
    case bool(Bool)
    case string(String)
    case null
}

// MARK: - Constant Folding Pass

/// Evaluates constant arithmetic, logic, and comparison at compile time.
/// Also folds branches on constant conditions into unconditional jumps.
internal final class ConstantFoldingPass: MIRPass {
    var name: String { "ConstantFolding" }

    func run(_ module: MIRModule) -> MIRModule {
        var result = module
        for i in 0..<result.functions.count {
            result.functions[i] = foldFunction(result.functions[i])
        }
        return result
    }

    private func foldFunction(_ function: MIRFunction) -> MIRFunction {
        var f = function
        var constants: [String: ConstantValue] = [:]

        for blockIdx in 0..<f.blocks.count {
            var newInstructions: [MIRInstruction] = []

            for inst in f.blocks[blockIdx].instructions {
                if let folded = tryFold(inst, constants: &constants) {
                    newInstructions.append(folded)
                } else {
                    recordConstant(inst, into: &constants)
                    newInstructions.append(inst)
                }
            }

            f.blocks[blockIdx].instructions = newInstructions

            // Branch folding
            if let term = f.blocks[blockIdx].terminator {
                f.blocks[blockIdx].terminator = foldTerminator(term, constants: constants)
            }
        }
        return f
    }

    // MARK: - Record Constants

    private func recordConstant(_ inst: MIRInstruction, into constants: inout [String: ConstantValue]) {
        switch inst {
        case .constInt(let d, let v):
            constants[d] = .int(v)
        case .constFloat(let d, let v):
            constants[d] = .float(v)
        case .constBool(let d, let v):
            constants[d] = .bool(v)
        case .constString(let d, let v):
            constants[d] = .string(v)
        case .constNull(let d):
            constants[d] = .null
        default:
            break
        }
    }

    // MARK: - Try Fold

    private func tryFold(_ inst: MIRInstruction, constants: inout [String: ConstantValue]) -> MIRInstruction? {
        switch inst {
        // Integer arithmetic
        case .add(let d, let l, let r, _):
            if case .int(let lv) = constants[l], case .int(let rv) = constants[r] {
                let result = lv &+ rv
                constants[d] = .int(result)
                return .constInt(dest: d, value: result)
            }
        case .sub(let d, let l, let r, _):
            if case .int(let lv) = constants[l], case .int(let rv) = constants[r] {
                let result = lv &- rv
                constants[d] = .int(result)
                return .constInt(dest: d, value: result)
            }
        case .mul(let d, let l, let r, _):
            if case .int(let lv) = constants[l], case .int(let rv) = constants[r] {
                let result = lv &* rv
                constants[d] = .int(result)
                return .constInt(dest: d, value: result)
            }
        case .div(let d, let l, let r, _):
            if case .int(let lv) = constants[l], case .int(let rv) = constants[r], rv != 0 {
                let result = lv / rv
                constants[d] = .int(result)
                return .constInt(dest: d, value: result)
            }
        case .mod(let d, let l, let r, _):
            if case .int(let lv) = constants[l], case .int(let rv) = constants[r], rv != 0 {
                let result = lv % rv
                constants[d] = .int(result)
                return .constInt(dest: d, value: result)
            }
        case .neg(let d, let o, _):
            if case .int(let v) = constants[o] {
                let result = -v
                constants[d] = .int(result)
                return .constInt(dest: d, value: result)
            }

        // Integer comparisons
        case .eq(let d, let l, let r, _):
            if case .int(let lv) = constants[l], case .int(let rv) = constants[r] {
                let result = lv == rv
                constants[d] = .bool(result)
                return .constBool(dest: d, value: result)
            }
        case .neq(let d, let l, let r, _):
            if case .int(let lv) = constants[l], case .int(let rv) = constants[r] {
                let result = lv != rv
                constants[d] = .bool(result)
                return .constBool(dest: d, value: result)
            }
        case .lt(let d, let l, let r, _):
            if case .int(let lv) = constants[l], case .int(let rv) = constants[r] {
                let result = lv < rv
                constants[d] = .bool(result)
                return .constBool(dest: d, value: result)
            }
        case .lte(let d, let l, let r, _):
            if case .int(let lv) = constants[l], case .int(let rv) = constants[r] {
                let result = lv <= rv
                constants[d] = .bool(result)
                return .constBool(dest: d, value: result)
            }
        case .gt(let d, let l, let r, _):
            if case .int(let lv) = constants[l], case .int(let rv) = constants[r] {
                let result = lv > rv
                constants[d] = .bool(result)
                return .constBool(dest: d, value: result)
            }
        case .gte(let d, let l, let r, _):
            if case .int(let lv) = constants[l], case .int(let rv) = constants[r] {
                let result = lv >= rv
                constants[d] = .bool(result)
                return .constBool(dest: d, value: result)
            }

        // Boolean logic
        case .and(let d, let l, let r):
            if case .bool(let lv) = constants[l], case .bool(let rv) = constants[r] {
                let result = lv && rv
                constants[d] = .bool(result)
                return .constBool(dest: d, value: result)
            }
        case .or(let d, let l, let r):
            if case .bool(let lv) = constants[l], case .bool(let rv) = constants[r] {
                let result = lv || rv
                constants[d] = .bool(result)
                return .constBool(dest: d, value: result)
            }
        case .not(let d, let o):
            if case .bool(let v) = constants[o] {
                let result = !v
                constants[d] = .bool(result)
                return .constBool(dest: d, value: result)
            }

        // String concatenation
        case .stringConcat(let d, let parts):
            var allConstant = true
            var pieces: [String] = []
            for part in parts {
                if case .string(let s) = constants[part] {
                    pieces.append(s)
                } else {
                    allConstant = false
                    break
                }
            }
            if allConstant {
                let result = pieces.joined()
                constants[d] = .string(result)
                return .constString(dest: d, value: result)
            }

        default:
            break
        }
        return nil
    }

    // MARK: - Branch Folding

    private func foldTerminator(_ term: MIRTerminator, constants: [String: ConstantValue]) -> MIRTerminator {
        if case .branch(let cond, let thenLabel, let elseLabel) = term {
            if case .bool(let v) = constants[cond] {
                return .jump(v ? thenLabel : elseLabel)
            }
        }
        return term
    }
}
