// ARCTests.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import XCTest
@testable import RockitKit

final class ARCTests: XCTestCase {

    // MARK: - Heap Tests

    func testHeapAllocate() {
        let heap = Heap()
        let id = heap.allocate(typeName: "Point", fields: ["x": .int(1), "y": .int(2)])
        XCTAssertEqual(heap.liveObjectCount, 1)
        XCTAssertEqual(heap.totalAllocations, 1)
        XCTAssertEqual(heap.refCount(of: id), 1)
    }

    func testHeapFieldAccess() throws {
        let heap = Heap()
        let id = heap.allocate(typeName: "User", fields: ["name": .string("Alice")])
        let name = try heap.getField(id, name: "name")
        XCTAssertEqual(name, .string("Alice"))
    }

    func testHeapFieldSet() throws {
        let heap = Heap()
        let id = heap.allocate(typeName: "User", fields: ["name": .string("Alice")])
        try heap.setField(id, name: "name", value: .string("Bob"))
        let name = try heap.getField(id, name: "name")
        XCTAssertEqual(name, .string("Bob"))
    }

    func testHeapDeallocate() {
        let heap = Heap()
        let id = heap.allocate(typeName: "Temp")
        XCTAssertEqual(heap.liveObjectCount, 1)
        heap.deallocate(id)
        XCTAssertEqual(heap.liveObjectCount, 0)
        XCTAssertEqual(heap.totalDeallocations, 1)
    }

    func testHeapSlotReuse() {
        let heap = Heap()
        let id1 = heap.allocate(typeName: "A")
        heap.deallocate(id1)
        let id2 = heap.allocate(typeName: "B")
        // The freed slot should be reused
        XCTAssertEqual(id2.index, id1.index)
        XCTAssertEqual(heap.liveObjectCount, 1)
    }

    func testHeapPeakTracking() {
        let heap = Heap()
        let id1 = heap.allocate(typeName: "A")
        let id2 = heap.allocate(typeName: "B")
        let id3 = heap.allocate(typeName: "C")
        XCTAssertEqual(heap.peakLiveObjects, 3)
        heap.deallocate(id2)
        XCTAssertEqual(heap.peakLiveObjects, 3)  // Peak doesn't decrease
        XCTAssertEqual(heap.liveObjectCount, 2)
        _ = (id1, id3)  // suppress unused warnings
    }

    // MARK: - Reference Counter Tests

    func testRetainRelease() {
        let heap = Heap()
        let id = heap.allocate(typeName: "Test")
        let arc = ReferenceCounter(heap: heap)

        arc.retain(.objectRef(id))
        XCTAssertEqual(heap.refCount(of: id), 2)

        arc.release(.objectRef(id))
        XCTAssertEqual(heap.refCount(of: id), 1)
    }

    func testReleaseToZeroDeallocates() {
        let heap = Heap()
        let id = heap.allocate(typeName: "Test")
        let arc = ReferenceCounter(heap: heap)

        arc.release(.objectRef(id))
        XCTAssertEqual(heap.liveObjectCount, 0)
        XCTAssertEqual(arc.totalCascadingReleases, 1)
    }

    func testCascadingRelease() {
        let heap = Heap()
        let inner = heap.allocate(typeName: "Inner")  // refCount=1
        let outer = heap.allocate(typeName: "Outer", fields: ["child": .objectRef(inner)])
        heap.retain(inner)  // outer's field holds a reference → inner refCount=2

        let arc = ReferenceCounter(heap: heap)

        // Simulate releasing inner's local variable reference
        arc.release(.objectRef(inner))  // inner refCount → 1 (only outer holds it)

        // Now release outer — should cascade to inner
        arc.release(.objectRef(outer))  // outer refCount → 0, cascade releases inner
        XCTAssertEqual(heap.liveObjectCount, 0, "Both objects should be deallocated")
    }

    func testWriteBarrier() {
        let heap = Heap()
        let old = heap.allocate(typeName: "Old")
        let new = heap.allocate(typeName: "New")
        let arc = ReferenceCounter(heap: heap)

        arc.writeBarrier(old: .objectRef(old), new: .objectRef(new))
        XCTAssertEqual(heap.refCount(of: new), 2)  // original + retained
        XCTAssertEqual(heap.liveObjectCount, 1)     // old was released to zero
    }

    func testRetainReleaseNonObject() {
        let heap = Heap()
        let arc = ReferenceCounter(heap: heap)

        // Should be no-ops for non-object values
        arc.retain(.int(42))
        arc.release(.string("hello"))
        arc.retain(.null)
        XCTAssertEqual(arc.totalRetains, 0)
        XCTAssertEqual(arc.totalReleases, 0)
    }

    // MARK: - Weak Reference Tests

    func testWeakRefZeroed() throws {
        let heap = Heap()
        let target = heap.allocate(typeName: "Target")  // refCount=1
        let holder = heap.allocate(typeName: "Holder", fields: ["ref": .objectRef(target)])
        // Note: weak refs don't increment refCount

        let arc = ReferenceCounter(heap: heap)
        arc.registerWeakRef(target: target, holder: holder, field: "ref")

        // Release the only strong reference to target
        arc.release(.objectRef(target))  // refCount → 0, cascade + zero weak refs

        let fieldValue = try heap.getField(holder, name: "ref")
        XCTAssertEqual(fieldValue, .null, "Weak reference should be zeroed after target dealloc")
    }

    // MARK: - Cycle Detector Tests

    func testCycleDetectorSimpleCycle() {
        let heap = Heap()
        let a = heap.allocate(typeName: "A")  // refCount=1
        let b = heap.allocate(typeName: "B")  // refCount=1

        // Create cycle: A -> B -> A
        try! heap.setField(a, name: "next", value: .objectRef(b))
        try! heap.setField(b, name: "next", value: .objectRef(a))
        heap.retain(b)  // A holds B → B refCount=2
        heap.retain(a)  // B holds A → A refCount=2

        // Simulate releasing "local variable" references (allocation refs)
        _ = heap.release(a)  // A refCount → 1 (only B holds it)
        _ = heap.release(b)  // B refCount → 1 (only A holds it)

        let detector = CycleDetector(heap: heap, threshold: 1)
        detector.addSuspect(a)
        detector.addSuspect(b)

        var collected: [ObjectID] = []
        detector.forceCollect { ids in
            collected = ids
        }

        XCTAssert(collected.count == 2, "Expected both objects in cycle to be collected, got \(collected.count)")
    }

    func testCycleDetectorNoCycle() {
        let heap = Heap()
        let a = heap.allocate(typeName: "A")  // refCount=1
        let b = heap.allocate(typeName: "B")  // refCount=1

        // Linear chain: A -> B (no cycle)
        try! heap.setField(a, name: "next", value: .objectRef(b))
        heap.retain(b)  // A holds B → B refCount=2

        // A has refCount=1 (external), B has refCount=2 (external + A's field)
        // Trial decrement among suspects:
        //   A's trial: 1 (no suspect points to A) → alive
        //   B's trial: 2 - 1 (A points to B) = 1 → alive
        let detector = CycleDetector(heap: heap, threshold: 1)
        detector.addSuspect(a)
        detector.addSuspect(b)

        var collected: [ObjectID] = []
        detector.forceCollect { ids in
            collected = ids
        }

        XCTAssertEqual(collected.count, 0, "No cycle — nothing should be collected")
    }

    func testCycleDetectorSelfCycle() {
        let heap = Heap()
        let a = heap.allocate(typeName: "Node")  // refCount=1
        try! heap.setField(a, name: "self", value: .objectRef(a))
        heap.retain(a)  // self-reference → refCount=2

        // Release local variable reference
        _ = heap.release(a)  // refCount → 1 (only self holds it)

        let detector = CycleDetector(heap: heap, threshold: 1)
        detector.addSuspect(a)

        var collected: [ObjectID] = []
        detector.forceCollect { ids in
            collected = ids
        }

        XCTAssert(collected.count == 1, "Self-referencing object should be collected")
    }

    func testCycleDetectorThreshold() {
        let heap = Heap()
        let detector = CycleDetector(heap: heap, threshold: 5)

        // Add 3 suspects — under threshold, should not collect
        for _ in 0..<3 {
            let id = heap.allocate(typeName: "X")
            detector.addSuspect(id)
        }

        XCTAssertEqual(detector.totalPasses, 0, "Should not collect under threshold")
        detector.collectIfNeeded { _ in }
        XCTAssertEqual(detector.totalPasses, 0, "Should not collect under threshold")

        // Add more to exceed threshold
        for _ in 0..<3 {
            let id = heap.allocate(typeName: "X")
            detector.addSuspect(id)
        }

        detector.collectIfNeeded { _ in }
        XCTAssertEqual(detector.totalPasses, 1, "Should run collection when over threshold")
    }

    // MARK: - Statistics Tests

    func testHeapStats() {
        let heap = Heap()
        _ = heap.allocate(typeName: "A")
        _ = heap.allocate(typeName: "B")
        let stats = heap.statsDescription
        XCTAssert(stats.contains("2"), "Stats should show allocation count")
    }

    func testARCStats() {
        let heap = Heap()
        let arc = ReferenceCounter(heap: heap)
        let id = heap.allocate(typeName: "Test")
        arc.retain(.objectRef(id))
        arc.release(.objectRef(id))
        let stats = arc.statsDescription
        XCTAssert(stats.contains("1"), "Stats should show retain/release counts")
    }
}
