// RuntimeConfig.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - Runtime Configuration

/// Central configuration for the Rockit VM runtime.
public struct RuntimeConfig {
    /// Maximum call stack depth before StackOverflow.
    public var maxCallStackDepth: Int

    /// Maximum heap objects before refusing allocation.
    public var maxHeapObjects: Int

    /// Number of suspect objects before triggering cycle detection.
    public var cycleDetectorThreshold: Int

    /// Enable instruction-level trace output.
    public var traceExecution: Bool

    /// Enable GC/ARC statistics output.
    public var gcStats: Bool

    /// Scheduler time-slice quantum (instructions per coroutine turn).
    public var schedulerQuantum: Int

    public init(
        maxCallStackDepth: Int = 1024,
        maxHeapObjects: Int = 1_000_000,
        cycleDetectorThreshold: Int = 256,
        traceExecution: Bool = false,
        gcStats: Bool = false,
        schedulerQuantum: Int = 1000
    ) {
        self.maxCallStackDepth = maxCallStackDepth
        self.maxHeapObjects = maxHeapObjects
        self.cycleDetectorThreshold = cycleDetectorThreshold
        self.traceExecution = traceExecution
        self.gcStats = gcStats
        self.schedulerQuantum = schedulerQuantum
    }

    /// Default configuration for normal execution.
    public static let `default` = RuntimeConfig()
}
