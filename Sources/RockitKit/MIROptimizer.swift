// MIROptimizer.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - MIR Pass Protocol

/// A single optimization pass that transforms a MIR module.
public protocol MIRPass {
    /// Human-readable name for debugging.
    var name: String { get }

    /// Transform the module, returning the optimized version.
    func run(_ module: MIRModule) -> MIRModule
}

// MARK: - MIR Optimizer

/// Runs optimization passes on a MIR module in a fixed order:
/// Constant Folding → Dead Code Elimination → Tree Shaking.
public final class MIROptimizer {
    private let passes: [MIRPass]

    public init() {
        passes = [
            InliningPass(),
            ConstantFoldingPass(),
            DeadCodeEliminationPass(),
            TreeShakingPass(),
        ]
    }

    /// Run all registered passes in order.
    public func optimize(_ module: MIRModule) -> MIRModule {
        var result = module
        for pass in passes {
            result = pass.run(result)
        }
        return result
    }
}
