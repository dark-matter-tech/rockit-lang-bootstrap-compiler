// DiagnosticsProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import RockitKit

/// Converts Rockit compiler diagnostics to LSP diagnostic format
public final class DiagnosticsProvider {

    /// Convert an array of Rockit Diagnostics to LSP Diagnostics
    public static func convert(_ diagnostics: [Diagnostic], uri: String) -> [LSPDiagnostic] {
        return diagnostics.compactMap { diag -> LSPDiagnostic? in
            guard let loc = diag.location else { return nil }

            let startPos = sourceLocationToLSPPosition(loc)
            // Highlight at least one character beyond the start
            let endPos = LSPPosition(line: startPos.line, character: startPos.character + 1)

            let severity: Int
            switch diag.severity {
            case .error:   severity = 1
            case .warning: severity = 2
            case .note:    severity = 3
            }

            return LSPDiagnostic(
                range: LSPRange(start: startPos, end: endPos),
                severity: severity,
                message: diag.message,
                source: "rockit"
            )
        }
    }
}
