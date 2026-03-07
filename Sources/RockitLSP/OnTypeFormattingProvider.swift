// OnTypeFormattingProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation

/// Provides on-type formatting — auto-indent after `{`, `}`, newline
public final class OnTypeFormattingProvider {

    public static let triggerCharacters = ["\n", "}", "{"]

    public static func onTypeFormatting(
        uri: String,
        position: LSPPosition,
        character: String,
        documentText: String,
        tabSize: Int,
        insertSpaces: Bool
    ) -> [LSPTextEdit] {
        let indentUnit = insertSpaces ? String(repeating: " ", count: tabSize) : "\t"
        let lines = documentText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        switch character {
        case "\n":
            return handleNewline(position: position, lines: lines, indentUnit: indentUnit)
        case "}":
            return handleCloseBrace(position: position, lines: lines, indentUnit: indentUnit)
        default:
            return []
        }
    }

    // MARK: - Newline

    private static func handleNewline(
        position: LSPPosition,
        lines: [String],
        indentUnit: String
    ) -> [LSPTextEdit] {
        let currentLine = position.line
        guard currentLine > 0 && currentLine - 1 < lines.count else { return [] }

        let prevLine = lines[currentLine - 1]
        let prevTrimmed = prevLine.trimmingCharacters(in: .whitespaces)

        // Calculate the indentation of the previous line
        let prevIndent = leadingWhitespace(prevLine)
        var targetIndent = prevIndent

        // If previous line ends with `{` or `(`, increase indent
        let stripped = stripTrailingComment(prevTrimmed)
        if stripped.hasSuffix("{") || stripped.hasSuffix("(") {
            targetIndent += indentUnit
        }

        // If the current line (just typed) is empty or only whitespace, set its indent
        if currentLine < lines.count {
            let currentContent = lines[currentLine]
            let currentTrimmed = currentContent.trimmingCharacters(in: .whitespaces)

            if currentTrimmed.isEmpty {
                let editRange = LSPRange(
                    start: LSPPosition(line: currentLine, character: 0),
                    end: LSPPosition(line: currentLine, character: currentContent.count)
                )
                return [LSPTextEdit(range: editRange, newText: targetIndent)]
            }
        }

        return []
    }

    // MARK: - Close Brace

    private static func handleCloseBrace(
        position: LSPPosition,
        lines: [String],
        indentUnit: String
    ) -> [LSPTextEdit] {
        let currentLine = position.line
        guard currentLine >= 0 && currentLine < lines.count else { return [] }

        let line = lines[currentLine]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Only auto-dedent if the line is just "}"
        guard trimmed == "}" else { return [] }

        // Find the matching opening brace's indentation
        var depth = 0
        for i in stride(from: currentLine, through: 0, by: -1) {
            let scanLine = lines[i].trimmingCharacters(in: .whitespaces)
            // Count braces (simplified — doesn't handle strings/comments perfectly)
            for ch in scanLine {
                if ch == "}" { depth += 1 }
                if ch == "{" { depth -= 1 }
            }
            if depth <= 0 {
                let matchIndent = leadingWhitespace(lines[i])
                let editRange = LSPRange(
                    start: LSPPosition(line: currentLine, character: 0),
                    end: LSPPosition(line: currentLine, character: line.count)
                )
                return [LSPTextEdit(range: editRange, newText: matchIndent + "}")]
            }
        }

        return []
    }

    // MARK: - Helpers

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

    private static func stripTrailingComment(_ line: String) -> String {
        var inString = false
        var prev: Character = "\0"
        for (i, ch) in line.enumerated() {
            if ch == "\"" && prev != "\\" { inString = !inString }
            if !inString && ch == "/" && prev == "/" {
                return String(line.prefix(i - 1)).trimmingCharacters(in: .whitespaces)
            }
            prev = ch
        }
        return line.trimmingCharacters(in: .whitespaces)
    }
}
