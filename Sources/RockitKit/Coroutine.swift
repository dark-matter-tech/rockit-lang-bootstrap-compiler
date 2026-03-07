// Coroutine.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - Coroutine ID

/// Unique identifier for a coroutine.
public struct CoroutineID: Hashable, CustomStringConvertible {
    public let id: UInt64

    public init(_ id: UInt64) {
        self.id = id
    }

    public var description: String { "coro#\(id)" }
}

// MARK: - Coroutine State

/// The lifecycle state of a coroutine.
public enum CoroutineState: Equatable, CustomStringConvertible {
    /// Created but not yet started.
    case created
    /// Currently executing on the scheduler.
    case running
    /// Suspended, waiting to be resumed with a value.
    case suspended
    /// Completed successfully with a return value.
    case completed(Value)
    /// Failed with a runtime error.
    case failed(VMError)
    /// Cancelled by parent or explicit cancellation.
    case cancelled

    public var description: String {
        switch self {
        case .created:      return "created"
        case .running:      return "running"
        case .suspended:    return "suspended"
        case .completed:    return "completed"
        case .failed:       return "failed"
        case .cancelled:    return "cancelled"
        }
    }

    /// Whether the coroutine has finished (completed, failed, or cancelled).
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    // Custom Equatable since Value and VMError may not be directly equatable in all cases
    public static func == (lhs: CoroutineState, rhs: CoroutineState) -> Bool {
        switch (lhs, rhs) {
        case (.created, .created): return true
        case (.running, .running): return true
        case (.suspended, .suspended): return true
        case (.completed(let a), .completed(let b)): return a == b
        case (.failed, .failed): return true
        case (.cancelled, .cancelled): return true
        default: return false
        }
    }
}

// MARK: - Saved Execution State

/// Captured execution state for a suspended coroutine.
/// When a coroutine suspends, its entire call stack and register state
/// is saved here so it can be restored on resume.
public struct SavedExecutionState {
    /// Saved call frames (the coroutine's own call stack).
    public var callStack: [CallFrame]

    /// The value that will be injected when the coroutine is resumed.
    /// Set by the scheduler before resuming.
    public var resumeValue: Value?

    public init(callStack: [CallFrame]) {
        self.callStack = callStack
        self.resumeValue = nil
    }
}

// MARK: - Coroutine

/// A lightweight coroutine — the fundamental unit of concurrency in Rockit.
///
/// Each coroutine has its own call stack and register state, independent
/// of the main VM stack. Coroutines are cooperatively scheduled: they
/// explicitly yield control at suspension points (await, yield, sleep).
///
/// Structured concurrency: every coroutine (except the root) has a parent.
/// A parent cannot complete until all its children have completed.
/// Cancellation propagates from parent to all children.
public final class Coroutine {
    /// Unique identifier.
    public let id: CoroutineID

    /// The function to execute (index into module's function table).
    public let functionIndex: Int

    /// The function name (for debugging/stack traces).
    public let functionName: String

    /// Arguments passed to the coroutine's entry function.
    public let arguments: [Value]

    /// Current lifecycle state.
    public private(set) var state: CoroutineState = .created

    /// Saved execution state when suspended.
    public var savedState: SavedExecutionState?

    /// Parent coroutine (nil for root coroutine).
    public private(set) weak var parent: Coroutine?

    /// Child coroutines spawned by this one.
    public private(set) var children: [CoroutineID] = []

    /// Continuation to invoke when this coroutine completes.
    /// Used by the parent to receive the result.
    public var completionContinuation: ((Value) -> Void)?

    /// Whether cancellation has been requested.
    public private(set) var isCancellationRequested: Bool = false

    /// Register to inject the resume value into when resumed from an await.
    public var awaitDestRegister: UInt16?

    public init(
        id: CoroutineID,
        functionIndex: Int,
        functionName: String,
        arguments: [Value] = [],
        parent: Coroutine? = nil
    ) {
        self.id = id
        self.functionIndex = functionIndex
        self.functionName = functionName
        self.arguments = arguments
        self.parent = parent
    }

    // MARK: - State Transitions

    /// Transition to running state.
    public func start() {
        precondition(state == .created, "Cannot start coroutine in state \(state)")
        state = .running
    }

    /// Suspend the coroutine, saving its execution state.
    public func suspend(callStack: [CallFrame]) {
        precondition(state == .running, "Cannot suspend coroutine in state \(state)")
        savedState = SavedExecutionState(callStack: callStack)
        state = .suspended
    }

    /// Resume the coroutine with a value.
    public func resume(with value: Value = .unit) {
        precondition(state == .suspended, "Cannot resume coroutine in state \(state)")
        savedState?.resumeValue = value
        state = .running
    }

    /// Complete the coroutine with a result value.
    public func complete(with value: Value) {
        guard !state.isTerminal else { return }
        state = .completed(value)
        savedState = nil
        completionContinuation?(value)
    }

    /// Fail the coroutine with an error.
    public func fail(with error: VMError) {
        guard !state.isTerminal else { return }
        state = .failed(error)
        savedState = nil
    }

    /// Cancel the coroutine and all its children.
    public func cancel() {
        guard !state.isTerminal else { return }
        isCancellationRequested = true
        state = .cancelled
        savedState = nil
    }

    // MARK: - Child Management

    /// Register a child coroutine.
    public func addChild(_ childId: CoroutineID) {
        children.append(childId)
    }

    /// Remove a child (when it completes).
    public func removeChild(_ childId: CoroutineID) {
        children.removeAll { $0 == childId }
    }

    /// Whether all children have completed (for structured concurrency join).
    public var allChildrenComplete: Bool {
        children.isEmpty
    }
}
