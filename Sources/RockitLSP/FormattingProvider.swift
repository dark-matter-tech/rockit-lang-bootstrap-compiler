// FormattingProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation

/// Provides document formatting via a simple brace-depth pretty printer
public final class FormattingProvider {

    public static func format(
        text: String,
        tabSize: Int,
        insertSpaces: Bool
    ) -> [LSPTextEdit] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var formatted: [String] = []
        var indentLevel = 0
        let indentUnit = insertSpaces ? String(repeating: " ", count: tabSize) : "\t"
        var inBlockComment = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Track block comments
            if inBlockComment {
                let indent = String(repeating: indentUnit, count: indentLevel)
                formatted.append(trimmed.isEmpty ? "" : indent + trimmed)
                if trimmed.contains("*/") {
                    inBlockComment = false
                }
                continue
            }

            if trimmed.hasPrefix("/*") && !trimmed.contains("*/") {
                inBlockComment = true
            }

            // Decrease indent before lines starting with }
            if trimmed.hasPrefix("}") || trimmed.hasPrefix(")") {
                indentLevel = max(0, indentLevel - 1)
            }

            if trimmed.isEmpty {
                formatted.append("")
            } else {
                let indent = String(repeating: indentUnit, count: indentLevel)
                formatted.append(indent + trimmed)
            }

            // Increase indent after lines ending with { or (
            let stripped = stripLineComment(trimmed).trimmingCharacters(in: .whitespaces)
            if (stripped.hasSuffix("{") || stripped.hasSuffix("(")) && !trimmed.hasPrefix("//") {
                indentLevel += 1
            }
        }

        // Trim trailing blank lines (keep one)
        while formatted.count > 1 && formatted.last == "" && formatted[formatted.count - 2] == "" {
            formatted.removeLast()
        }

        // Ensure single newline at EOF
        if formatted.last != "" {
            formatted.append("")
        }

        let result = formatted.joined(separator: "\n")

        // Return a single whole-document replacement
        let lastLine = lines.count - 1
        let lastChar = lines.last?.count ?? 0
        let fullRange = LSPRange(
            start: LSPPosition(line: 0, character: 0),
            end: LSPPosition(line: lastLine, character: lastChar)
        )

        return [LSPTextEdit(range: fullRange, newText: result)]
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
