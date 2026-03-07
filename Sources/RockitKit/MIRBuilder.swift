// MIRBuilder.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - MIR Builder

/// Helper for constructing MIR functions block-by-block.
/// Manages temporary name generation, block creation, and instruction emission.
public final class MIRBuilder {

    // MARK: - State

    private var tempCounter: Int = 0
    private var blockCounter: [String: Int] = [:]
    private var blocks: [MIRBasicBlock] = []
    private var currentBlockIndex: Int = -1

    // MARK: - Temp Names

    /// Generate a unique temporary name: `%t0`, `%t1`, ...
    public func newTemp() -> String {
        let name = "%t\(tempCounter)"
        tempCounter += 1
        return name
    }

    /// Reset the temp counter (used between functions).
    public func resetTemps() {
        tempCounter = 0
    }

    // MARK: - Block Management

    /// Generate a unique block label with the given prefix.
    /// First call with "then" → "then.0", second → "then.1", etc.
    public func newBlockLabel(_ prefix: String) -> String {
        let count = blockCounter[prefix, default: 0]
        blockCounter[prefix] = count + 1
        return "\(prefix).\(count)"
    }

    /// Start a new basic block with the given label.
    /// The new block becomes the current block.
    public func startBlock(label: String) {
        let block = MIRBasicBlock(label: label)
        blocks.append(block)
        currentBlockIndex = blocks.count - 1
    }

    /// The label of the current block, or nil if none.
    public var currentBlockLabel: String? {
        guard currentBlockIndex >= 0, currentBlockIndex < blocks.count else { return nil }
        return blocks[currentBlockIndex].label
    }

    /// Whether the current block already has a terminator.
    public var isTerminated: Bool {
        guard currentBlockIndex >= 0, currentBlockIndex < blocks.count else { return true }
        return blocks[currentBlockIndex].terminator != nil
    }

    // MARK: - Emit Instructions

    /// Append an instruction to the current block.
    public func emit(_ instruction: MIRInstruction) {
        guard currentBlockIndex >= 0, currentBlockIndex < blocks.count else { return }
        blocks[currentBlockIndex].instructions.append(instruction)
    }

    /// Set the terminator for the current block.
    /// Does nothing if already terminated (prevents double-termination).
    public func terminate(_ terminator: MIRTerminator) {
        guard currentBlockIndex >= 0, currentBlockIndex < blocks.count else { return }
        if blocks[currentBlockIndex].terminator == nil {
            blocks[currentBlockIndex].terminator = terminator
        }
    }

    // MARK: - Convenience Emitters

    /// Emit a constant integer and return the dest temp.
    public func emitConstInt(_ value: Int64) -> String {
        let dest = newTemp()
        emit(.constInt(dest: dest, value: value))
        return dest
    }

    /// Emit a constant float and return the dest temp.
    public func emitConstFloat(_ value: Double) -> String {
        let dest = newTemp()
        emit(.constFloat(dest: dest, value: value))
        return dest
    }

    /// Emit a constant bool and return the dest temp.
    public func emitConstBool(_ value: Bool) -> String {
        let dest = newTemp()
        emit(.constBool(dest: dest, value: value))
        return dest
    }

    /// Emit a constant string and return the dest temp.
    public func emitConstString(_ value: String) -> String {
        let dest = newTemp()
        emit(.constString(dest: dest, value: value))
        return dest
    }

    /// Emit a null constant and return the dest temp.
    public func emitConstNull() -> String {
        let dest = newTemp()
        emit(.constNull(dest: dest))
        return dest
    }

    /// Emit an alloc and return the dest temp.
    public func emitAlloc(type: MIRType) -> String {
        let dest = newTemp()
        emit(.alloc(dest: dest, type: type))
        return dest
    }

    /// Emit a store instruction.
    public func emitStore(dest: String, src: String) {
        emit(.store(dest: dest, src: src))
    }

    /// Emit a load and return the dest temp.
    public func emitLoad(src: String) -> String {
        let dest = newTemp()
        emit(.load(dest: dest, src: src))
        return dest
    }

    /// Emit a call and return the dest temp (nil for void calls).
    public func emitCall(function: String, args: [String], hasReturn: Bool = true) -> String? {
        if hasReturn {
            let dest = newTemp()
            emit(.call(dest: dest, function: function, args: args))
            return dest
        } else {
            emit(.call(dest: nil, function: function, args: args))
            return nil
        }
    }

    // MARK: - Finish

    /// Collect all blocks and return them, resetting the builder for the next function.
    /// Ensures all blocks have a terminator (adds `unreachable` to un-terminated blocks).
    public func finishBlocks() -> [MIRBasicBlock] {
        // Ensure every block has a terminator
        for i in 0..<blocks.count {
            if blocks[i].terminator == nil {
                blocks[i].terminator = .ret(nil)
            }
        }
        let result = blocks
        blocks = []
        currentBlockIndex = -1
        blockCounter = [:]
        resetTemps()
        return result
    }
}
