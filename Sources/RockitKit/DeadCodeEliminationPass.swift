// DeadCodeEliminationPass.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - Dead Code Elimination Pass

/// Removes unreachable blocks and unused pure instructions.
internal final class DeadCodeEliminationPass: MIRPass {
    var name: String { "DeadCodeElimination" }

    func run(_ module: MIRModule) -> MIRModule {
        var result = module
        for i in 0..<result.functions.count {
            result.functions[i] = eliminateDeadCode(result.functions[i])
        }
        return result
    }

    private func eliminateDeadCode(_ function: MIRFunction) -> MIRFunction {
        var f = function

        // Step 1: Remove unreachable blocks
        let reachable = reachableBlocks(in: f)
        f.blocks = f.blocks.filter { reachable.contains($0.label) }

        // Step 2: Iteratively remove dead instructions until fixpoint
        var changed = true
        while changed {
            changed = false
            let usedTemps = computeUsedTemps(in: f)

            for blockIdx in 0..<f.blocks.count {
                let before = f.blocks[blockIdx].instructions.count
                f.blocks[blockIdx].instructions = f.blocks[blockIdx].instructions.filter { inst in
                    guard let dest = inst.dest else { return true }
                    if usedTemps.contains(dest) { return true }
                    if inst.hasSideEffects { return true }
                    return false
                }
                if f.blocks[blockIdx].instructions.count < before {
                    changed = true
                }
            }
        }

        return f
    }

    private func computeUsedTemps(in function: MIRFunction) -> Set<String> {
        var used = Set<String>()
        for block in function.blocks {
            for inst in block.instructions {
                for operand in inst.operands {
                    used.insert(operand)
                }
            }
            if let term = block.terminator {
                for operand in term.operands {
                    used.insert(operand)
                }
            }
        }
        return used
    }
}
