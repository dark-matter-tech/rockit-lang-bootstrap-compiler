// Heap.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - Heap Object

/// A heap-allocated Rockit object with type metadata and fields.
public final class RockitObject {
    /// Type name of this object (e.g., "Point", "User").
    public let typeName: String

    /// Field storage, keyed by field name.
    public var fields: [String: Value]

    /// Reference count for ARC.
    public var refCount: Int

    /// Whether this object has been deallocated (for dangling reference detection).
    public var isDeallocated: Bool

    /// Weak reference flag — not counted in refCount.
    public var hasWeakRefs: Bool

    /// Element storage for List objects. nil for non-list objects.
    public var listStorage: [Value]?

    /// Key-value storage for HashMap objects. nil for non-map objects.
    public var mapStorage: [Value: Value]?

    public init(typeName: String, fields: [String: Value] = [:]) {
        self.typeName = typeName
        self.fields = fields
        self.refCount = 1
        self.isDeallocated = false
        self.hasWeakRefs = false
        self.listStorage = nil
        self.mapStorage = nil
    }
}

// MARK: - Heap

/// Object heap for the Rockit VM. Manages allocation, deallocation,
/// and field access for heap-allocated objects.
public final class Heap {
    /// All allocated objects, indexed by ObjectID.
    private var objects: [RockitObject?] = []

    /// Free list for object slot reuse.
    private var freeList: [Int] = []

    /// Statistics
    public private(set) var totalAllocations: Int = 0
    public private(set) var totalDeallocations: Int = 0
    public private(set) var peakLiveObjects: Int = 0

    /// Current number of live objects.
    public var liveObjectCount: Int {
        objects.count - freeList.count
    }

    public init() {}

    // MARK: - Allocation

    /// Allocate a new object on the heap with the given type and initial fields.
    /// Returns an ObjectID with refCount = 1.
    public func allocate(typeName: String, fields: [String: Value] = [:]) -> ObjectID {
        let obj = RockitObject(typeName: typeName, fields: fields)
        totalAllocations += 1

        let id: ObjectID
        if let reusableIndex = freeList.popLast() {
            objects[reusableIndex] = obj
            id = ObjectID(reusableIndex)
        } else {
            id = ObjectID(objects.count)
            objects.append(obj)
        }

        let live = liveObjectCount
        if live > peakLiveObjects {
            peakLiveObjects = live
        }

        return id
    }

    // MARK: - Access

    /// Get the object at the given ID. Throws if deallocated or invalid.
    public func get(_ id: ObjectID) throws -> RockitObject {
        guard id.index < objects.count, let obj = objects[id.index] else {
            throw VMError.indexOutOfBounds(index: id.index, count: objects.count)
        }
        guard !obj.isDeallocated else {
            throw VMError.nullPointerAccess(context: "access to deallocated object \(id)")
        }
        return obj
    }

    /// Get a field value from an object.
    public func getField(_ id: ObjectID, name: String) throws -> Value {
        let obj = try get(id)
        return obj.fields[name] ?? .null
    }

    /// Set a field value on an object. Returns the old value for ARC release.
    @discardableResult
    public func setField(_ id: ObjectID, name: String, value: Value) throws -> Value {
        let obj = try get(id)
        let old = obj.fields[name] ?? .null
        obj.fields[name] = value
        return old
    }

    /// Get the type name of an object.
    public func typeName(of id: ObjectID) -> String? {
        guard id.index < objects.count, let obj = objects[id.index], !obj.isDeallocated else {
            return nil
        }
        return obj.typeName
    }

    /// Get all field values of an object (for ARC cascading release).
    /// Includes collection elements so they are properly released.
    public func allFieldValues(_ id: ObjectID) -> [Value] {
        guard id.index < objects.count, let obj = objects[id.index], !obj.isDeallocated else {
            return []
        }
        var values = Array(obj.fields.values)
        if let listElements = obj.listStorage {
            values.append(contentsOf: listElements)
        }
        if let mapEntries = obj.mapStorage {
            values.append(contentsOf: mapEntries.keys)
            values.append(contentsOf: mapEntries.values)
        }
        return values
    }

    // MARK: - Deallocation

    /// Deallocate an object, marking its slot for reuse.
    public func deallocate(_ id: ObjectID) {
        guard id.index < objects.count, let obj = objects[id.index], !obj.isDeallocated else {
            return
        }
        obj.isDeallocated = true
        obj.fields = [:]
        obj.listStorage = nil
        obj.mapStorage = nil
        objects[id.index] = nil
        freeList.append(id.index)
        totalDeallocations += 1
    }

    // MARK: - ARC Access

    /// Get the reference count of an object.
    public func refCount(of id: ObjectID) -> Int {
        guard id.index < objects.count, let obj = objects[id.index], !obj.isDeallocated else {
            return 0
        }
        return obj.refCount
    }

    /// Increment the reference count.
    public func retain(_ id: ObjectID) {
        guard id.index < objects.count, let obj = objects[id.index], !obj.isDeallocated else {
            return
        }
        obj.refCount += 1
    }

    /// Decrement the reference count. Returns true if count reached zero.
    @discardableResult
    public func release(_ id: ObjectID) -> Bool {
        guard id.index < objects.count, let obj = objects[id.index], !obj.isDeallocated else {
            return false
        }
        obj.refCount -= 1
        return obj.refCount <= 0
    }

    // MARK: - Statistics

    /// Summary string for --gc-stats output.
    public var statsDescription: String {
        """
        --- Heap Statistics ---
          Total allocations:   \(totalAllocations)
          Total deallocations: \(totalDeallocations)
          Live objects:        \(liveObjectCount)
          Peak live objects:   \(peakLiveObjects)
          Free list size:      \(freeList.count)
        --- End Heap Stats ---
        """
    }
}
