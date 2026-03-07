// Diagnostic.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

/// Severity level for compiler diagnostics
public enum DiagnosticSeverity {
    case error
    case warning
    case note
}

/// A compiler diagnostic (error, warning, or note)
public struct Diagnostic: CustomStringConvertible {
    public let severity: DiagnosticSeverity
    public let message: String
    public let location: SourceLocation?

    public init(_ severity: DiagnosticSeverity, _ message: String, at location: SourceLocation? = nil) {
        self.severity = severity
        self.message = message
        self.location = location
    }

    public var description: String {
        let prefix: String
        switch severity {
        case .error:   prefix = "error"
        case .warning: prefix = "warning"
        case .note:    prefix = "note"
        }
        if let loc = location {
            return "\(loc): \(prefix): \(message)"
        }
        return "\(prefix): \(message)"
    }
}

/// Collects diagnostics during compilation
public final class DiagnosticEngine {
    public private(set) var diagnostics: [Diagnostic] = []

    public var hasErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }

    public var errorCount: Int {
        diagnostics.filter { $0.severity == .error }.count
    }

    public init() {}

    public func error(_ message: String, at location: SourceLocation? = nil) {
        diagnostics.append(Diagnostic(.error, message, at: location))
    }

    public func warning(_ message: String, at location: SourceLocation? = nil) {
        diagnostics.append(Diagnostic(.warning, message, at: location))
    }

    public func note(_ message: String, at location: SourceLocation? = nil) {
        diagnostics.append(Diagnostic(.note, message, at: location))
    }

    /// Remove diagnostics added after the given count (for speculative parsing rollback)
    public func truncate(to count: Int) {
        if diagnostics.count > count {
            diagnostics.removeSubrange(count...)
        }
    }

    public func dump() {
        for diag in diagnostics {
            print(diag)
        }
    }
}
