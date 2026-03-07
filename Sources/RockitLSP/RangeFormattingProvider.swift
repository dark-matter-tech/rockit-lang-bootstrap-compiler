// RangeFormattingProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation

/// Provides formatting for a selected range of text
public final class RangeFormattingProvider {

    public static func formatRange(
        text: String,
        range: LSPRange,
        tabSize: Int,
        insertSpaces: Bool
    ) -> [LSPTextEdit] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let indentUnit = insertSpaces ? String(repeating: " ", count: tabSize) : "\t"

        let startLine = max(0, range.start.line)
        let endLine = min(lines.count - 1, range.end.line)

        guard startLine <= endLine else { return [] }

        // Determine the indent level at the start of the range by scanning preceding lines
        var indentLevel = 0
        for i in 0..<startLine {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("{") || trimmed.hasSuffix("(") {
                indentLevel += 1
            }
            if trimmed.hasPrefix("}") || trimmed.hasPrefix(")") {
                indentLevel = max(0, indentLevel - 1)
            }
        }

        var edits: [LSPTextEdit] = []

        for lineIdx in startLine...endLine {
            let line = lines[lineIdx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { continue }

            // Adjust indent for closing braces
            if trimmed.hasPrefix("}") || trimmed.hasPrefix(")") {
                indentLevel = max(0, indentLevel - 1)
            }

            let expectedIndent = String(repeating: indentUnit, count: indentLevel)
            let currentIndent = leadingWhitespace(line)

            if currentIndent != expectedIndent {
                let editRange = LSPRange(
                    start: LSPPosition(line: lineIdx, character: 0),
                    end: LSPPosition(line: lineIdx, character: currentIndent.count)
                )
                edits.append(LSPTextEdit(range: editRange, newText: expectedIndent))
            }

            // Increase indent after opening braces
            let stripped = stripLineComment(trimmed).trimmingCharacters(in: .whitespaces)
            if (stripped.hasSuffix("{") || stripped.hasSuffix("(")) && !trimmed.hasPrefix("//") {
                indentLevel += 1
            }
        }

        return edits
    }

    private static func leadingWhitespace(_ line: String) -> String {
        var ws = ""
        for ch in line {
            if ch == " " || ch == "\t" {
                ws.append(ch)
            } else {
                break
            }
        }
        return ws
    }

    private static func stripLineComment(_ line: String) -> String {
        var inString = false
        var prev: Character = "\0"
        for (i, ch) in line.enumerated() {
            if ch == "\"" && prev != "\\" { inString = !inString }
            if !inString && ch == "/" && prev == "/" {
                return String(line.prefix(i - 1))
            }
            prev = ch
        }
        return line
    }
}
