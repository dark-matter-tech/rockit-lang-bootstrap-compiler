// ActorRuntime.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - Actor ID

/// Unique identifier for an actor instance.
public struct ActorID: Hashable, CustomStringConvertible {
    public let id: UInt64

    public init(_ id: UInt64) {
        self.id = id
    }

    public var description: String { "actor#\(id)" }
}

// MARK: - Actor Message

/// A message sent to an actor's mailbox.
public struct ActorMessage {
    /// The method to invoke on the actor.
    public let methodName: String

    /// Arguments to the method.
    public let arguments: [Value]

    /// Continuation to invoke with the result (for async replies).
    public let replyContinuation: ((Value) -> Void)?

    /// The coroutine that sent this message (for scheduling).
    public let senderCoroutine: CoroutineID?

    public init(
        methodName: String,
        arguments: [Value] = [],
        replyContinuation: ((Value) -> Void)? = nil,
        senderCoroutine: CoroutineID? = nil
    ) {
        self.methodName = methodName
        self.arguments = arguments
        self.replyContinuation = replyContinuation
        self.senderCoroutine = senderCoroutine
    }
}

// MARK: - Mailbox

/// A serial FIFO message queue for an actor.
/// Messages are processed one at a time, guaranteeing serial execution
/// within the actor and eliminating the need for locks.
public final class Mailbox {
    /// The queue of pending messages.
    private var queue: [ActorMessage] = []

    /// Whether the actor is currently processing a message.
    public private(set) var isProcessing: Bool = false

    /// Total messages received.
    public private(set) var totalReceived: Int = 0

    /// Total messages processed.
    public private(set) var totalProcessed: Int = 0

    public init() {}

    /// Enqueue a message for processing.
    public func enqueue(_ message: ActorMessage) {
        queue.append(message)
        totalReceived += 1
    }

    /// Dequeue the next message if not currently processing.
    public func dequeue() -> ActorMessage? {
        guard !isProcessing, !queue.isEmpty else { return nil }
        isProcessing = true
        return queue.removeFirst()
    }

    /// Mark current message as processed.
    public func finishProcessing() {
        isProcessing = false
        totalProcessed += 1
    }

    /// Number of pending messages.
    public var pendingCount: Int { queue.count }

    /// Whether there are messages waiting to be processed.
    public var hasMessages: Bool { !queue.isEmpty }
}

// MARK: - Actor Instance

/// A runtime actor instance. Actors are heap-allocated objects with
/// a serial mailbox for message processing. State is isolated —
/// fields can only be accessed from within the actor's own execution context.
public final class ActorInstance {
    /// Unique identifier for this actor.
    public let id: ActorID

    /// The actor's type name.
    public let typeName: String

    /// The heap object ID backing this actor's state.
    public let objectID: ObjectID

    /// The actor's mailbox for serial message processing.
    public let mailbox: Mailbox

    /// Whether this actor has been shut down.
    public private(set) var isShutDown: Bool = false

    public init(id: ActorID, typeName: String, objectID: ObjectID) {
        self.id = id
        self.typeName = typeName
        self.objectID = objectID
        self.mailbox = Mailbox()
    }

    /// Shut down the actor, preventing new messages.
    public func shutDown() {
        isShutDown = true
    }
}

// MARK: - Actor Runtime

/// The actor runtime manages actor instances and message dispatch.
///
/// When a method is called on an actor, it's enqueued as a message
/// in the actor's mailbox. The scheduler picks up actor messages
/// and processes them serially within the actor's context, ensuring
/// state isolation without locks.
public final class ActorRuntime {
    /// All active actor instances.
    private var actors: [ActorID: ActorInstance] = [:]

    /// Next actor ID to assign.
    private var nextId: UInt64 = 1

    /// The scheduler for coordinating coroutines and actors.
    private let scheduler: Scheduler

    /// Statistics
    public private(set) var totalActorsCreated: Int = 0
    public private(set) var totalMessagesSent: Int = 0
    public private(set) var totalMessagesProcessed: Int = 0

    public init(scheduler: Scheduler) {
        self.scheduler = scheduler
    }

    // MARK: - Actor Lifecycle

    /// Create a new actor instance.
    public func createActor(typeName: String, objectID: ObjectID) -> ActorInstance {
        let id = ActorID(nextId)
        nextId += 1
        let actor = ActorInstance(id: id, typeName: typeName, objectID: objectID)
        actors[id] = actor
        totalActorsCreated += 1
        return actor
    }

    /// Get an actor by ID.
    public func actor(for id: ActorID) -> ActorInstance? {
        actors[id]
    }

    /// Shut down and remove an actor.
    public func destroyActor(_ id: ActorID) {
        actors[id]?.shutDown()
        actors.removeValue(forKey: id)
    }

    // MARK: - Message Dispatch

    /// Send a message to an actor. Returns immediately.
    /// The message is enqueued in the actor's mailbox for serial processing.
    public func send(
        to actorId: ActorID,
        method: String,
        arguments: [Value] = [],
        senderCoroutine: CoroutineID? = nil,
        replyContinuation: ((Value) -> Void)? = nil
    ) throws {
        guard let actor = actors[actorId] else {
            throw VMError.nullPointerAccess(context: "send to unknown actor \(actorId)")
        }
        guard !actor.isShutDown else {
            throw VMError.nullPointerAccess(context: "send to shut down actor \(actorId)")
        }

        let message = ActorMessage(
            methodName: method,
            arguments: arguments,
            replyContinuation: replyContinuation,
            senderCoroutine: senderCoroutine
        )
        actor.mailbox.enqueue(message)
        totalMessagesSent += 1
    }

    /// Process the next pending message for an actor, if available.
    /// Returns the message that was dequeued, or nil if none.
    public func processNext(for actorId: ActorID) -> ActorMessage? {
        guard let actor = actors[actorId] else { return nil }
        return actor.mailbox.dequeue()
    }

    /// Mark the current message as processed for an actor.
    public func finishProcessing(for actorId: ActorID) {
        guard let actor = actors[actorId] else { return }
        actor.mailbox.finishProcessing()
        totalMessagesProcessed += 1
    }

    /// Get all actors that have pending messages ready to process.
    public func actorsWithPendingMessages() -> [ActorInstance] {
        actors.values.filter { $0.mailbox.hasMessages && !$0.mailbox.isProcessing && !$0.isShutDown }
    }

    /// Number of live actors.
    public var liveActorCount: Int {
        actors.count
    }

    // MARK: - State Isolation

    /// Validate that field access is happening from within the actor's own context.
    /// In Stage 0, this is a runtime check. In later stages, it's enforced at compile time.
    public func validateAccess(actorId: ActorID, fromContext contextActorId: ActorID?) throws {
        guard contextActorId == actorId else {
            throw VMError.actorIsolationViolation(
                actor: actors[actorId]?.typeName ?? "unknown",
                field: "state"
            )
        }
    }

    // MARK: - Statistics

    public var statsDescription: String {
        let totalPending = actors.values.reduce(0) { $0 + $1.mailbox.pendingCount }
        return """
        --- Actor Runtime ---
          Actors created:     \(totalActorsCreated)
          Live actors:        \(actors.count)
          Messages sent:      \(totalMessagesSent)
          Messages processed: \(totalMessagesProcessed)
          Pending messages:   \(totalPending)
        --- End Actor Stats ---
        """
    }
}
