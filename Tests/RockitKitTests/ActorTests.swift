// ActorTests.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import XCTest
@testable import RockitKit

final class ActorTests: XCTestCase {

    // MARK: - Capability Tests

    func testDefaultCapabilities() {
        let registry = CapabilityRegistry()
        let caps = registry.allCapabilities
        XCTAssert(caps.contains("Network"))
        XCTAssert(caps.contains("FileSystem"))
        XCTAssert(caps.contains("Camera"))
        XCTAssert(caps.count >= 10)
    }

    func testCapabilityInitialStatus() {
        let registry = CapabilityRegistry()
        XCTAssertEqual(registry.status(of: "Network"), .unknown)
        XCTAssertFalse(registry.check("Network"))
    }

    func testCapabilityGrantDeny() {
        let registry = CapabilityRegistry()
        registry.grant("Network")
        XCTAssertTrue(registry.check("Network"))
        XCTAssertEqual(registry.status(of: "Network"), .granted)

        registry.deny("Camera")
        XCTAssertFalse(registry.check("Camera"))
        XCTAssertEqual(registry.status(of: "Camera"), .denied)
    }

    func testCapabilityRequest() {
        let registry = CapabilityRegistry()
        // Default: auto-grant in Stage 0
        let status = registry.request("Network")
        XCTAssertEqual(status, .granted)
        XCTAssertTrue(registry.check("Network"))
    }

    func testCapabilityRequestWithHandler() {
        let registry = CapabilityRegistry()
        registry.requestHandler = { name in
            name == "Network" ? .granted : .denied
        }
        XCTAssertEqual(registry.request("Network"), .granted)
        XCTAssertEqual(registry.request("Camera"), .denied)
    }

    func testCapabilityRequire() throws {
        let registry = CapabilityRegistry()
        registry.grant("Network")
        XCTAssertNoThrow(try registry.require("Network"))

        registry.deny("Camera")
        XCTAssertThrowsError(try registry.require("Camera"))
    }

    func testCapabilityRequireAutoGrant() throws {
        let registry = CapabilityRegistry()
        // Unknown → auto-request → auto-grant in Stage 0
        XCTAssertNoThrow(try registry.require("Storage"))
        XCTAssertTrue(registry.check("Storage"))
    }

    func testCapabilityCustomRegistration() {
        let registry = CapabilityRegistry()
        registry.register(CapabilityDescriptor(name: "CustomAPI", summary: "Custom API access"))
        XCTAssertEqual(registry.status(of: "CustomAPI"), .unknown)
        XCTAssertNotNil(registry.descriptor(for: "CustomAPI"))
    }

    func testCapabilityStats() {
        let registry = CapabilityRegistry()
        registry.grant("Network")
        registry.deny("Camera")
        let stats = registry.statsDescription
        XCTAssert(stats.contains("Granted"))
        XCTAssert(stats.contains("Denied"))
    }

    // MARK: - Actor Instance Tests

    func testActorCreation() {
        let scheduler = Scheduler()
        let runtime = ActorRuntime(scheduler: scheduler)
        let heap = Heap()
        let objId = heap.allocate(typeName: "Counter")

        let actor = runtime.createActor(typeName: "Counter", objectID: objId)
        XCTAssertEqual(actor.typeName, "Counter")
        XCTAssertFalse(actor.isShutDown)
        XCTAssertEqual(runtime.liveActorCount, 1)
        XCTAssertEqual(runtime.totalActorsCreated, 1)
    }

    func testActorLookup() {
        let scheduler = Scheduler()
        let runtime = ActorRuntime(scheduler: scheduler)
        let heap = Heap()
        let objId = heap.allocate(typeName: "Counter")

        let actor = runtime.createActor(typeName: "Counter", objectID: objId)
        let found = runtime.actor(for: actor.id)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, actor.id)
    }

    func testActorDestroy() {
        let scheduler = Scheduler()
        let runtime = ActorRuntime(scheduler: scheduler)
        let heap = Heap()
        let objId = heap.allocate(typeName: "Counter")

        let actor = runtime.createActor(typeName: "Counter", objectID: objId)
        runtime.destroyActor(actor.id)
        XCTAssertNil(runtime.actor(for: actor.id))
        XCTAssertEqual(runtime.liveActorCount, 0)
    }

    // MARK: - Mailbox Tests

    func testMailboxEnqueueDequeue() {
        let mailbox = Mailbox()
        let msg = ActorMessage(methodName: "increment", arguments: [.int(1)])
        mailbox.enqueue(msg)
        XCTAssertEqual(mailbox.pendingCount, 1)
        XCTAssertTrue(mailbox.hasMessages)

        let dequeued = mailbox.dequeue()
        XCTAssertNotNil(dequeued)
        XCTAssertEqual(dequeued?.methodName, "increment")
        XCTAssertTrue(mailbox.isProcessing)
    }

    func testMailboxSerialExecution() {
        let mailbox = Mailbox()
        mailbox.enqueue(ActorMessage(methodName: "a"))
        mailbox.enqueue(ActorMessage(methodName: "b"))

        // First message can be dequeued
        let first = mailbox.dequeue()
        XCTAssertEqual(first?.methodName, "a")

        // Second message blocked while first is processing
        let blocked = mailbox.dequeue()
        XCTAssertNil(blocked)

        // Finish processing first
        mailbox.finishProcessing()
        XCTAssertFalse(mailbox.isProcessing)

        // Now second can be dequeued
        let second = mailbox.dequeue()
        XCTAssertEqual(second?.methodName, "b")
    }

    func testMailboxFIFOOrder() {
        let mailbox = Mailbox()
        mailbox.enqueue(ActorMessage(methodName: "first"))
        mailbox.enqueue(ActorMessage(methodName: "second"))
        mailbox.enqueue(ActorMessage(methodName: "third"))

        var order: [String] = []
        while let msg = mailbox.dequeue() {
            order.append(msg.methodName)
            mailbox.finishProcessing()
        }
        XCTAssertEqual(order, ["first", "second", "third"])
        XCTAssertEqual(mailbox.totalProcessed, 3)
    }

    // MARK: - Message Dispatch Tests

    func testSendMessage() throws {
        let scheduler = Scheduler()
        let runtime = ActorRuntime(scheduler: scheduler)
        let heap = Heap()
        let objId = heap.allocate(typeName: "Counter")

        let actor = runtime.createActor(typeName: "Counter", objectID: objId)
        try runtime.send(to: actor.id, method: "increment", arguments: [.int(1)])

        XCTAssertEqual(runtime.totalMessagesSent, 1)
        XCTAssertEqual(actor.mailbox.pendingCount, 1)
    }

    func testSendToUnknownActor() {
        let scheduler = Scheduler()
        let runtime = ActorRuntime(scheduler: scheduler)
        XCTAssertThrowsError(try runtime.send(to: ActorID(999), method: "test"))
    }

    func testSendToShutDownActor() {
        let scheduler = Scheduler()
        let runtime = ActorRuntime(scheduler: scheduler)
        let heap = Heap()
        let objId = heap.allocate(typeName: "Counter")

        let actor = runtime.createActor(typeName: "Counter", objectID: objId)
        runtime.destroyActor(actor.id)
        XCTAssertThrowsError(try runtime.send(to: actor.id, method: "test"))
    }

    func testProcessNextMessage() throws {
        let scheduler = Scheduler()
        let runtime = ActorRuntime(scheduler: scheduler)
        let heap = Heap()
        let objId = heap.allocate(typeName: "Counter")

        let actor = runtime.createActor(typeName: "Counter", objectID: objId)
        try runtime.send(to: actor.id, method: "increment", arguments: [.int(5)])

        let msg = runtime.processNext(for: actor.id)
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.methodName, "increment")
        XCTAssertEqual(msg?.arguments, [.int(5)])

        runtime.finishProcessing(for: actor.id)
        XCTAssertEqual(runtime.totalMessagesProcessed, 1)
    }

    func testActorsWithPendingMessages() throws {
        let scheduler = Scheduler()
        let runtime = ActorRuntime(scheduler: scheduler)
        let heap = Heap()

        let obj1 = heap.allocate(typeName: "A")
        let obj2 = heap.allocate(typeName: "B")
        let actor1 = runtime.createActor(typeName: "A", objectID: obj1)
        let actor2 = runtime.createActor(typeName: "B", objectID: obj2)

        try runtime.send(to: actor1.id, method: "doSomething")
        // actor2 has no messages

        let ready = runtime.actorsWithPendingMessages()
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(ready.first?.id, actor1.id)
        _ = actor2  // suppress warning
    }

    func testMessageReply() throws {
        let scheduler = Scheduler()
        let runtime = ActorRuntime(scheduler: scheduler)
        let heap = Heap()
        let objId = heap.allocate(typeName: "Calculator")

        let actor = runtime.createActor(typeName: "Calculator", objectID: objId)

        var receivedReply: Value?
        try runtime.send(
            to: actor.id,
            method: "compute",
            arguments: [.int(21)],
            replyContinuation: { receivedReply = $0 }
        )

        let msg = runtime.processNext(for: actor.id)
        // Simulate processing and replying
        msg?.replyContinuation?(.int(42))
        runtime.finishProcessing(for: actor.id)

        XCTAssertEqual(receivedReply, .int(42))
    }

    // MARK: - State Isolation Tests

    func testStateIsolationEnforced() {
        let scheduler = Scheduler()
        let runtime = ActorRuntime(scheduler: scheduler)
        let heap = Heap()

        let obj1 = heap.allocate(typeName: "A")
        let obj2 = heap.allocate(typeName: "B")
        let actor1 = runtime.createActor(typeName: "A", objectID: obj1)
        let actor2 = runtime.createActor(typeName: "B", objectID: obj2)

        // Accessing actor1's state from actor2's context should fail
        XCTAssertThrowsError(
            try runtime.validateAccess(actorId: actor1.id, fromContext: actor2.id)
        )

        // Accessing actor1's state from actor1's context should succeed
        XCTAssertNoThrow(
            try runtime.validateAccess(actorId: actor1.id, fromContext: actor1.id)
        )
    }

    // MARK: - Statistics Tests

    func testActorRuntimeStats() throws {
        let scheduler = Scheduler()
        let runtime = ActorRuntime(scheduler: scheduler)
        let heap = Heap()
        let objId = heap.allocate(typeName: "Test")

        let actor = runtime.createActor(typeName: "Test", objectID: objId)
        try runtime.send(to: actor.id, method: "ping")

        let stats = runtime.statsDescription
        XCTAssert(stats.contains("1"), "Stats should show actor/message counts")
    }
}
