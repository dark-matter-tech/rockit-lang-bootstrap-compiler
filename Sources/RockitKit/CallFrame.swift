// CallFrame.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - Call Frame

/// Per-function-call execution state.
/// Each function call pushes a new CallFrame onto the VM's call stack.
public struct CallFrame {
    /// Index of the function in the module's function table.
    public let functionIndex: Int

    /// Instruction pointer — byte offset within the function's bytecode.
    public var pc: Int

    /// Register window for this frame. Size = function's registerCount.
    public var registers: [Value]

    /// Which register in the caller's frame should receive the return value.
    /// `nil` for void calls or the top-level main call.
    public let returnRegister: UInt16?

    /// Function name (cached for stack traces).
    public let functionName: String

    public init(
        functionIndex: Int,
        registerCount: Int,
        returnRegister: UInt16?,
        functionName: String
    ) {
        self.functionIndex = functionIndex
        self.pc = 0
        self.registers = Array(repeating: .unit, count: registerCount)
        self.returnRegister = returnRegister
        self.functionName = functionName
    }
}
