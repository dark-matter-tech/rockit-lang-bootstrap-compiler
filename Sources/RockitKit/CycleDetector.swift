// CycleDetector.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - Cycle Detector

/// Bacon-Rajan style trial deletion cycle detector.
///
/// When an object's reference count decreases but doesn't reach zero,
/// it becomes a "suspect" — potentially part of a reference cycle.
/// When the suspect buffer exceeds a threshold, the detector runs a
/// three-phase collection:
///
/// 1. **Mark**: For each suspect, trial-decrement internal references
/// 2. **Scan**: Check which suspects have trial count = 0 (garbage)
/// 3. **Collect**: Deallocate garbage objects and release their fields
public final class CycleDetector {
    private let heap: Heap
    private let threshold: Int

    /// Objects whose refcount decreased but didn't hit zero.
    private var suspects: Set<ObjectID> = []

    /// Total objects collected by cycle detection.
    public private(set) var totalCollected: Int = 0

    /// Total collection passes performed.
    public private(set) var totalPasses: Int = 0

    /// Number of current suspects.
    public var suspectCount: Int { suspects.count }

    public init(heap: Heap, threshold: Int = 256) {
        self.heap = heap
        self.threshold = threshold
    }

    // MARK: - Suspect Management

    /// Add an object to the suspect list.
    public func addSuspect(_ id: ObjectID) {
        suspects.insert(id)
    }

    /// Remove an object from suspects (e.g., if it was deallocated normally).
    public func removeSuspect(_ id: ObjectID) {
        suspects.remove(id)
    }

    // MARK: - Collection

    /// Run cycle detection if suspects exceed threshold.
    public func collectIfNeeded(release: ([ObjectID]) -> Void) {
        guard suspects.count >= threshold else { return }
        performCollection(release: release)
    }

    /// Force a cycle detection pass regardless of threshold.
    public func forceCollect(release: ([ObjectID]) -> Void) {
        performCollection(release: release)
    }

    private func performCollection(release: ([ObjectID]) -> Void) {
        totalPasses += 1
        guard !suspects.isEmpty else { return }

        // Snapshot current suspects and clear
        let currentSuspects = suspects
        suspects.removeAll()

        // Filter out already-deallocated suspects
        let liveSuspects = currentSuspects.filter { heap.refCount(of: $0) > 0 }
        guard !liveSuspects.isEmpty else { return }

        // Phase 1: Trial decrement
        // For each suspect, count how many internal references come from other suspects
        var trialCounts: [ObjectID: Int] = [:]
        for id in liveSuspects {
            trialCounts[id] = heap.refCount(of: id)
        }

        // Decrement trial counts for internal edges between suspects
        for id in liveSuspects {
            let fieldValues = heap.allFieldValues(id)
            for fieldValue in fieldValues {
                if case .objectRef(let targetId) = fieldValue, trialCounts[targetId] != nil {
                    trialCounts[targetId]! -= 1
                }
            }
        }

        // Phase 2: Identify garbage
        // Objects whose trial count reached 0 are in a cycle (only held by other cycle members)
        var garbage: Set<ObjectID> = []
        for (id, count) in trialCounts {
            if count <= 0 {
                garbage.insert(id)
            }
        }

        // Phase 3: Verify — ensure none of the garbage is reachable from non-garbage
        // This prevents false collection of objects that happen to have internal refs
        // but are also reachable from outside the suspect set.
        var confirmed = garbage
        var changed = true
        while changed {
            changed = false
            for id in liveSuspects where !confirmed.contains(id) {
                let fieldValues = heap.allFieldValues(id)
                for fieldValue in fieldValues {
                    if case .objectRef(let targetId) = fieldValue, confirmed.contains(targetId) {
                        // This non-garbage object references a garbage object
                        // The garbage object is reachable — rescue it
                        confirmed.remove(targetId)
                        changed = true
                    }
                }
            }
        }

        // Collect confirmed garbage
        if !confirmed.isEmpty {
            totalCollected += confirmed.count
            release(Array(confirmed))
        }
    }

    // MARK: - Statistics

    public var statsDescription: String {
        """
        --- Cycle Detector ---
          Collection passes:  \(totalPasses)
          Objects collected:  \(totalCollected)
          Current suspects:   \(suspects.count)
          Threshold:          \(threshold)
        --- End Cycle Stats ---
        """
    }
}
