// CoroutineTests.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import XCTest
@testable import RockitKit

final class CoroutineTests: XCTestCase {

    // MARK: - Coroutine Lifecycle Tests

    func testCoroutineCreation() {
        let coro = Coroutine(
            id: CoroutineID(1),
            functionIndex: 0,
            functionName: "test",
            arguments: [.int(42)]
        )
        XCTAssertEqual(coro.state, .created)
        XCTAssertEqual(coro.id, CoroutineID(1))
        XCTAssertEqual(coro.functionName, "test")
        XCTAssertEqual(coro.arguments, [.int(42)])
        XCTAssertFalse(coro.isCancellationRequested)
    }

    func testCoroutineStartTransition() {
        let coro = Coroutine(id: CoroutineID(1), functionIndex: 0, functionName: "test")
        coro.start()
        XCTAssertEqual(coro.state, .running)
    }

    func testCoroutineSuspendResume() {
        let coro = Coroutine(id: CoroutineID(1), functionIndex: 0, functionName: "test")
        coro.start()

        let frame = CallFrame(functionIndex: 0, registerCount: 4, returnRegister: nil, functionName: "test")
        coro.suspend(callStack: [frame])
        XCTAssertEqual(coro.state, .suspended)
        XCTAssertNotNil(coro.savedState)
        XCTAssertEqual(coro.savedState?.callStack.count, 1)

        coro.resume(with: .int(99))
        XCTAssertEqual(coro.state, .running)
        XCTAssertEqual(coro.savedState?.resumeValue, .int(99))
    }

    func testCoroutineCompletion() {
        let coro = Coroutine(id: CoroutineID(1), functionIndex: 0, functionName: "test")
        coro.start()
        coro.complete(with: .string("done"))
        XCTAssertEqual(coro.state, .completed(.string("done")))
        XCTAssert(coro.state.isTerminal)
    }

    func testCoroutineFailure() {
        let coro = Coroutine(id: CoroutineID(1), functionIndex: 0, functionName: "test")
        coro.start()
        coro.fail(with: .divisionByZero)
        XCTAssert(coro.state.isTerminal)
        if case .failed = coro.state {} else {
            XCTFail("Expected .failed state")
        }
    }

    func testCoroutineCancellation() {
        let coro = Coroutine(id: CoroutineID(1), functionIndex: 0, functionName: "test")
        coro.start()
        coro.cancel()
        XCTAssertEqual(coro.state, .cancelled)
        XCTAssertTrue(coro.isCancellationRequested)
        XCTAssert(coro.state.isTerminal)
    }

    func testCompletionContinuation() {
        let coro = Coroutine(id: CoroutineID(1), functionIndex: 0, functionName: "test")
        var received: Value?
        coro.completionContinuation = { received = $0 }
        coro.start()
        coro.complete(with: .int(42))
        XCTAssertEqual(received, .int(42))
    }

    // MARK: - Scheduler Tests

    func testSchedulerSpawn() {
        let scheduler = Scheduler()
        let coro = scheduler.spawn(functionIndex: 0, functionName: "task1")
        XCTAssertEqual(scheduler.readyCount, 1)
        XCTAssertEqual(scheduler.totalSpawned, 1)
        XCTAssertNotNil(scheduler.coroutine(for: coro.id))
    }

    func testSchedulerDequeue() {
        let scheduler = Scheduler()
        let coro = scheduler.spawn(functionIndex: 0, functionName: "task1")
        let dequeued = scheduler.dequeueNext()
        XCTAssertEqual(dequeued?.id, coro.id)
        XCTAssertEqual(scheduler.readyCount, 0)
    }

    func testSchedulerFIFOOrder() {
        let scheduler = Scheduler()
        let c1 = scheduler.spawn(functionIndex: 0, functionName: "first")
        let c2 = scheduler.spawn(functionIndex: 1, functionName: "second")
        let c3 = scheduler.spawn(functionIndex: 2, functionName: "third")

        XCTAssertEqual(scheduler.dequeueNext()?.id, c1.id)
        XCTAssertEqual(scheduler.dequeueNext()?.id, c2.id)
        XCTAssertEqual(scheduler.dequeueNext()?.id, c3.id)
        XCTAssertNil(scheduler.dequeueNext())
    }

    func testSchedulerSuspendResume() {
        let scheduler = Scheduler()
        let coro = scheduler.spawn(functionIndex: 0, functionName: "task1")

        // Dequeue and start
        let dequeued = scheduler.dequeueNext()!
        dequeued.start()

        // Suspend
        let frame = CallFrame(functionIndex: 0, registerCount: 2, returnRegister: nil, functionName: "task1")
        scheduler.suspend(dequeued, callStack: [frame])
        XCTAssertEqual(dequeued.state, .suspended)
        XCTAssertEqual(scheduler.readyCount, 0)

        // Resume
        scheduler.resume(dequeued, with: .int(10))
        XCTAssertEqual(scheduler.readyCount, 1)

        let resumed = scheduler.dequeueNext()!
        XCTAssertEqual(resumed.id, coro.id)
        XCTAssertEqual(resumed.state, .running)
    }

    func testSchedulerComplete() {
        let scheduler = Scheduler()
        let coro = scheduler.spawn(functionIndex: 0, functionName: "task1")
        let dequeued = scheduler.dequeueNext()!
        dequeued.start()
        scheduler.complete(dequeued, with: .int(42))
        XCTAssertEqual(scheduler.totalCompleted, 1)
        XCTAssertNil(scheduler.coroutine(for: coro.id))
    }

    func testSchedulerCancel() {
        let scheduler = Scheduler()
        let coro = scheduler.spawn(functionIndex: 0, functionName: "task1")
        let dequeued = scheduler.dequeueNext()!
        dequeued.start()
        scheduler.cancel(dequeued)
        XCTAssertEqual(scheduler.totalCancelled, 1)
        XCTAssertNil(scheduler.coroutine(for: coro.id))
    }

    // MARK: - Structured Concurrency Tests

    func testParentChildRelationship() {
        let scheduler = Scheduler()
        let parent = scheduler.spawn(functionIndex: 0, functionName: "parent")
        let child = scheduler.spawn(functionIndex: 1, functionName: "child", parent: parent)

        XCTAssertEqual(parent.children.count, 1)
        XCTAssertEqual(parent.children.first, child.id)
        XCTAssertFalse(parent.allChildrenComplete)
    }

    func testParentWaitsForChildren() {
        let scheduler = Scheduler()
        let parent = scheduler.spawn(functionIndex: 0, functionName: "parent")

        // Dequeue and start the parent
        let p = scheduler.dequeueNext()!
        p.start()

        // Spawn children while parent is running
        let child1 = scheduler.spawn(functionIndex: 1, functionName: "child1", parent: p)
        let child2 = scheduler.spawn(functionIndex: 2, functionName: "child2", parent: p)

        // Parent suspends waiting for children
        let frame = CallFrame(functionIndex: 0, registerCount: 2, returnRegister: nil, functionName: "parent")
        scheduler.awaitChildren(p, callStack: [frame])
        XCTAssertEqual(p.state, .suspended)

        // Complete child1
        let c1 = scheduler.dequeueNext()!  // child1
        c1.start()
        scheduler.complete(c1, with: .unit)

        // Parent still waiting (child2 not done)
        XCTAssertEqual(p.state, .suspended)

        // Complete child2
        let c2 = scheduler.dequeueNext()!  // child2
        c2.start()
        scheduler.complete(c2, with: .unit)

        // Parent should now be resumed
        XCTAssertEqual(p.state, .running)
        XCTAssertEqual(scheduler.readyCount, 1)
        _ = (parent, child1, child2)  // suppress warnings
    }

    func testCancellationPropagation() {
        let scheduler = Scheduler()
        let parent = scheduler.spawn(functionIndex: 0, functionName: "parent")
        let child1 = scheduler.spawn(functionIndex: 1, functionName: "child1", parent: parent)
        let child2 = scheduler.spawn(functionIndex: 2, functionName: "child2", parent: parent)

        // Dequeue and start parent
        let p = scheduler.dequeueNext()!
        p.start()

        // Cancel parent — should cascade to children
        scheduler.cancel(p)
        XCTAssertEqual(scheduler.totalCancelled, 3)
        XCTAssertNil(scheduler.coroutine(for: parent.id))
        XCTAssertNil(scheduler.coroutine(for: child1.id))
        XCTAssertNil(scheduler.coroutine(for: child2.id))
    }

    func testRunToCompletion() {
        let scheduler = Scheduler()
        var executionOrder: [String] = []

        let _ = scheduler.spawn(functionIndex: 0, functionName: "task1")
        let _ = scheduler.spawn(functionIndex: 1, functionName: "task2")
        let _ = scheduler.spawn(functionIndex: 2, functionName: "task3")

        scheduler.runToCompletion { coro in
            coro.start()
            executionOrder.append(coro.functionName)
            scheduler.complete(coro, with: .unit)
        }

        XCTAssertEqual(executionOrder, ["task1", "task2", "task3"])
        XCTAssertEqual(scheduler.totalCompleted, 3)
        XCTAssertFalse(scheduler.hasWork)
    }

    func testMultipleCoroutinesInterleaving() {
        let scheduler = Scheduler()
        var executionLog: [String] = []

        let c1 = scheduler.spawn(functionIndex: 0, functionName: "A")
        let c2 = scheduler.spawn(functionIndex: 1, functionName: "B")

        // Round 1: A runs, suspends; B runs, suspends
        let a1 = scheduler.dequeueNext()!
        a1.start()
        executionLog.append("A:run1")
        let frameA = CallFrame(functionIndex: 0, registerCount: 2, returnRegister: nil, functionName: "A")
        scheduler.suspend(a1, callStack: [frameA])

        let b1 = scheduler.dequeueNext()!
        b1.start()
        executionLog.append("B:run1")
        let frameB = CallFrame(functionIndex: 1, registerCount: 2, returnRegister: nil, functionName: "B")
        scheduler.suspend(b1, callStack: [frameB])

        // Resume both
        scheduler.resume(a1)
        scheduler.resume(b1)

        // Round 2: A completes, B completes
        let a2 = scheduler.dequeueNext()!
        executionLog.append("A:run2")
        scheduler.complete(a2, with: .unit)

        let b2 = scheduler.dequeueNext()!
        executionLog.append("B:run2")
        scheduler.complete(b2, with: .unit)

        XCTAssertEqual(executionLog, ["A:run1", "B:run1", "A:run2", "B:run2"])
        XCTAssertEqual(scheduler.totalCompleted, 2)
        _ = (c1, c2)  // suppress warnings
    }

    // MARK: - Statistics Tests

    func testSchedulerStats() {
        let scheduler = Scheduler()
        let c1 = scheduler.spawn(functionIndex: 0, functionName: "a")
        let c2 = scheduler.spawn(functionIndex: 1, functionName: "b")

        let d1 = scheduler.dequeueNext()!
        d1.start()
        scheduler.complete(d1, with: .unit)

        let d2 = scheduler.dequeueNext()!
        d2.start()
        scheduler.fail(d2, with: .divisionByZero)

        let stats = scheduler.statsDescription
        XCTAssert(stats.contains("2"), "Stats should show spawn count")
        _ = (c1, c2)  // suppress warnings
    }
}
