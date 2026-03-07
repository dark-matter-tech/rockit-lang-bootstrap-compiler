// ReferenceCounter.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - Reference Counter

/// Automatic Reference Counting manager for the Rockit VM.
/// Handles retain/release with cascading deallocation, weak reference
/// zeroing, and unowned reference validation.
public final class ReferenceCounter {
    /// The heap this ARC manager operates on.
    private let heap: Heap

    /// The cycle detector for handling reference cycles.
    public let cycleDetector: CycleDetector

    /// Weak reference table: ObjectID → set of (holder ObjectID, field name).
    /// When the target is deallocated, these fields are zeroed to .null.
    private var weakRefs: [ObjectID: [(holder: ObjectID, field: String)]] = [:]

    /// Unowned reference set: ObjectIDs that have unowned references.
    /// Accessing a deallocated unowned ref traps.
    private var unownedRefs: Set<ObjectID> = []

    /// Statistics
    public private(set) var totalRetains: Int = 0
    public private(set) var totalReleases: Int = 0
    public private(set) var totalCascadingReleases: Int = 0

    public init(heap: Heap, cycleDetectorThreshold: Int = 256) {
        self.heap = heap
        self.cycleDetector = CycleDetector(heap: heap, threshold: cycleDetectorThreshold)
    }

    // MARK: - Retain / Release

    /// Retain a value. Only affects objectRef values.
    public func retain(_ value: Value) {
        guard case .objectRef(let id) = value else { return }
        heap.retain(id)
        totalRetains += 1
    }

    /// Release a value. Only affects objectRef values.
    /// If the reference count drops to zero, cascading release occurs.
    public func release(_ value: Value) {
        guard case .objectRef(let id) = value else { return }
        totalReleases += 1

        let hitZero = heap.release(id)
        if hitZero {
            cascadingRelease(id)
        } else {
            // Count decreased but not to zero — suspect for cycle detection
            cycleDetector.addSuspect(id)
        }
    }

    /// Write a new value to a location, releasing the old and retaining the new.
    /// Returns the old value for debugging/stats purposes.
    @discardableResult
    public func writeBarrier(old: Value, new: Value) -> Value {
        retain(new)
        release(old)
        return old
    }

    // MARK: - Cascading Release

    /// When an object's refcount hits zero, release all its fields
    /// and deallocate it. This may cascade to other objects.
    private func cascadingRelease(_ id: ObjectID) {
        totalCascadingReleases += 1

        // Zero weak references pointing to this object
        zeroWeakRefs(for: id)

        // Mark unowned refs as invalid
        unownedRefs.remove(id)

        // Release all field values
        let fieldValues = heap.allFieldValues(id)
        heap.deallocate(id)

        // Cascade: release each field that is an object reference
        for fieldValue in fieldValues {
            release(fieldValue)
        }
    }

    // MARK: - Weak References

    /// Register a weak reference: when `target` is deallocated,
    /// `holder.field` will be zeroed to .null.
    public func registerWeakRef(target: ObjectID, holder: ObjectID, field: String) {
        weakRefs[target, default: []].append((holder: holder, field: field))
    }

    /// Zero all weak references pointing to the given object.
    private func zeroWeakRefs(for target: ObjectID) {
        guard let refs = weakRefs.removeValue(forKey: target) else { return }
        for (holder, field) in refs {
            try? heap.setField(holder, name: field, value: .null)
        }
    }

    // MARK: - Unowned References

    /// Register that an object has unowned references to it.
    public func registerUnownedRef(_ id: ObjectID) {
        unownedRefs.insert(id)
    }

    /// Validate an unowned reference. Throws if the object is deallocated.
    public func validateUnowned(_ id: ObjectID) throws {
        if heap.refCount(of: id) <= 0 {
            throw VMError.nullPointerAccess(context: "dangling unowned reference to \(id)")
        }
    }

    // MARK: - Cycle Collection

    /// Trigger cycle detection if the suspect buffer exceeds threshold.
    public func collectCyclesIfNeeded() {
        cycleDetector.collectIfNeeded { [weak self] collectedIDs in
            guard let self = self else { return }
            for id in collectedIDs {
                self.cascadingRelease(id)
            }
        }
    }

    /// Force a cycle collection pass.
    public func forceCollectCycles() {
        cycleDetector.forceCollect { [weak self] collectedIDs in
            guard let self = self else { return }
            for id in collectedIDs {
                self.cascadingRelease(id)
            }
        }
    }

    // MARK: - Statistics

    public var statsDescription: String {
        """
        --- ARC Statistics ---
          Total retains:           \(totalRetains)
          Total releases:          \(totalReleases)
          Cascading releases:      \(totalCascadingReleases)
          Cycle suspects:          \(cycleDetector.suspectCount)
          Cycles collected:        \(cycleDetector.totalCollected)
        --- End ARC Stats ---
        """
    }
}
