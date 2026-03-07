// Scheduler.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - Scheduler

/// Cooperative coroutine scheduler for the Rockit runtime.
///
/// The scheduler maintains a FIFO run queue of ready-to-execute coroutines.
/// It implements structured concurrency: parent coroutines wait for all
/// children before completing. Cancellation propagates from parent to children.
///
/// The scheduler is single-threaded and cooperative — coroutines must
/// explicitly yield (suspend/await) for the scheduler to run other coroutines.
public final class Scheduler {
    /// All known coroutines, indexed by ID.
    private var coroutines: [CoroutineID: Coroutine] = [:]

    /// FIFO run queue of coroutine IDs ready to execute.
    private var runQueue: [CoroutineID] = []

    /// Coroutines waiting for all children to complete.
    private var waitingForChildren: Set<CoroutineID> = []

    /// Next coroutine ID to assign.
    private var nextId: UInt64 = 1

    /// Maximum number of instructions a coroutine executes before yielding
    /// (cooperative time-slicing). 0 = no limit.
    public let quantum: Int

    /// Statistics
    public private(set) var totalSpawned: Int = 0
    public private(set) var totalCompleted: Int = 0
    public private(set) var totalFailed: Int = 0
    public private(set) var totalCancelled: Int = 0
    public private(set) var totalSchedulerTicks: Int = 0

    public init(quantum: Int = 1000) {
        self.quantum = quantum
    }

    // MARK: - Coroutine Lifecycle

    /// Spawn a new coroutine to execute a function.
    /// If parent is specified, the coroutine is linked for structured concurrency.
    @discardableResult
    public func spawn(
        functionIndex: Int,
        functionName: String,
        arguments: [Value] = [],
        parent: Coroutine? = nil
    ) -> Coroutine {
        let id = CoroutineID(nextId)
        nextId += 1

        let coroutine = Coroutine(
            id: id,
            functionIndex: functionIndex,
            functionName: functionName,
            arguments: arguments,
            parent: parent
        )

        coroutines[id] = coroutine
        runQueue.append(id)
        totalSpawned += 1

        // Link to parent for structured concurrency
        parent?.addChild(id)

        return coroutine
    }

    /// Get a coroutine by ID.
    public func coroutine(for id: CoroutineID) -> Coroutine? {
        coroutines[id]
    }

    /// Suspend a running coroutine, saving its state.
    public func suspend(_ coroutine: Coroutine, callStack: [CallFrame]) {
        coroutine.suspend(callStack: callStack)
    }

    /// Resume a suspended coroutine with a value.
    public func resume(_ coroutine: Coroutine, with value: Value = .unit) {
        guard case .suspended = coroutine.state else { return }
        coroutine.resume(with: value)
        runQueue.append(coroutine.id)
    }

    /// Mark a coroutine as completed.
    public func complete(_ coroutine: Coroutine, with value: Value) {
        coroutine.complete(with: value)
        totalCompleted += 1
        cleanupCoroutine(coroutine)
    }

    /// Mark a coroutine as failed.
    public func fail(_ coroutine: Coroutine, with error: VMError) {
        coroutine.fail(with: error)
        totalFailed += 1
        cleanupCoroutine(coroutine)
    }

    /// Cancel a coroutine and all its descendants.
    public func cancel(_ coroutine: Coroutine) {
        guard !coroutine.state.isTerminal else { return }

        // Cancel all children first (structured cancellation)
        for childId in coroutine.children {
            if let child = coroutines[childId] {
                cancel(child)
            }
        }

        coroutine.cancel()
        totalCancelled += 1
        cleanupCoroutine(coroutine)
    }

    // MARK: - Scheduling

    /// Dequeue the next ready coroutine from the run queue.
    /// Only returns coroutines in `.created` or `.running` state.
    public func dequeueNext() -> Coroutine? {
        while !runQueue.isEmpty {
            let id = runQueue.removeFirst()
            if let coro = coroutines[id] {
                switch coro.state {
                case .created, .running:
                    totalSchedulerTicks += 1
                    return coro
                case .suspended:
                    // Re-queued but not yet resumed — skip
                    continue
                default:
                    // Terminal — skip
                    continue
                }
            }
        }
        return nil
    }

    /// Whether there are any coroutines still running or ready to run.
    public var hasWork: Bool {
        !runQueue.isEmpty || !waitingForChildren.isEmpty
    }

    /// Number of coroutines in the run queue.
    public var readyCount: Int {
        runQueue.count
    }

    /// Total number of live (non-terminal) coroutines.
    public var liveCount: Int {
        coroutines.values.filter { !$0.state.isTerminal }.count
    }

    /// Run the scheduler until all coroutines complete.
    /// The `execute` closure is called for each coroutine to run —
    /// it should execute the coroutine's function and return when
    /// the coroutine suspends, completes, or fails.
    public func runToCompletion(execute: (Coroutine) throws -> Void) rethrows {
        while let coroutine = dequeueNext() {
            try execute(coroutine)
        }
    }

    // MARK: - Structured Concurrency

    /// Block a coroutine until all its children complete.
    /// The coroutine is suspended and moved to the waiting set.
    public func awaitChildren(_ coroutine: Coroutine, callStack: [CallFrame]) {
        if coroutine.allChildrenComplete {
            // All children already done — no need to wait
            return
        }
        coroutine.suspend(callStack: callStack)
        waitingForChildren.insert(coroutine.id)
    }

    /// Check if a waiting parent can be unblocked because all children completed.
    private func checkWaitingParents() {
        var toResume: [CoroutineID] = []
        for parentId in waitingForChildren {
            if let parent = coroutines[parentId], parent.allChildrenComplete {
                toResume.append(parentId)
            }
        }
        for parentId in toResume {
            waitingForChildren.remove(parentId)
            if let parent = coroutines[parentId], case .suspended = parent.state {
                resume(parent, with: .unit)
            }
        }
    }

    // MARK: - Cleanup

    private func cleanupCoroutine(_ coroutine: Coroutine) {
        // Remove from run queue
        runQueue.removeAll { $0 == coroutine.id }
        waitingForChildren.remove(coroutine.id)

        // Unlink from parent
        if let parent = coroutine.parent {
            parent.removeChild(coroutine.id)
        }

        // Remove from registry
        coroutines.removeValue(forKey: coroutine.id)

        // Check if any waiting parents can now be unblocked
        checkWaitingParents()
    }

    // MARK: - Statistics

    public var statsDescription: String {
        """
        --- Scheduler Statistics ---
          Total spawned:     \(totalSpawned)
          Total completed:   \(totalCompleted)
          Total failed:      \(totalFailed)
          Total cancelled:   \(totalCancelled)
          Scheduler ticks:   \(totalSchedulerTicks)
          Live coroutines:   \(liveCount)
          Ready queue size:  \(readyCount)
        --- End Scheduler Stats ---
        """
    }
}
