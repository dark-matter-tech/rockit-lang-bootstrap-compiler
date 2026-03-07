// DocumentManager.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation
import RockitKit

/// Tracks the state of all open documents
public final class DocumentManager {

    /// State for a single open document
    public struct DocumentState {
        public let uri: String
        public var version: Int
        public var text: String
        public var lines: [Substring]
        public var tokens: [Token]?
        public var ast: SourceFile?
        public var typeCheckResult: TypeCheckResult?
        public var cachedDiagnostics: [Diagnostic]
    }

    private var documents: [String: DocumentState] = [:]

    public init() {}

    /// Register a newly opened document
    public func open(uri: String, text: String, version: Int) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        documents[uri] = DocumentState(
            uri: uri,
            version: version,
            text: text,
            lines: lines,
            tokens: nil,
            ast: nil,
            typeCheckResult: nil,
            cachedDiagnostics: []
        )
    }

    /// Update document content (full sync)
    public func update(uri: String, text: String, version: Int) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        documents[uri] = DocumentState(
            uri: uri,
            version: version,
            text: text,
            lines: lines,
            tokens: nil,
            ast: nil,
            typeCheckResult: nil,
            cachedDiagnostics: []
        )
    }

    /// Remove a closed document
    public func close(uri: String) {
        documents.removeValue(forKey: uri)
    }

    /// Get the document state
    public func get(_ uri: String) -> DocumentState? {
        return documents[uri]
    }

    /// Get the raw text for a document
    public func getText(_ uri: String) -> String? {
        return documents[uri]?.text
    }

    /// Get the split lines for a document
    public func getLines(_ uri: String) -> [Substring]? {
        return documents[uri]?.lines
    }

    /// Store cached analysis results
    public func setCachedAnalysis(uri: String, tokens: [Token], ast: SourceFile,
                                   result: TypeCheckResult, diagnostics: [Diagnostic]) {
        documents[uri]?.tokens = tokens
        documents[uri]?.ast = ast
        documents[uri]?.typeCheckResult = result
        documents[uri]?.cachedDiagnostics = diagnostics
    }

    /// Apply an incremental (range-based) text change
    public func applyIncrementalChange(uri: String, version: Int, range: LSPRange, text: String) {
        guard var doc = documents[uri] else { return }

        let lines = doc.lines
        let startLine = range.start.line
        let startChar = range.start.character
        let endLine = range.end.line
        let endChar = range.end.character

        guard startLine >= 0 && startLine < lines.count &&
              endLine >= 0 && endLine < lines.count else {
            // Fallback to full replacement
            update(uri: uri, text: text, version: version)
            return
        }

        // Build the new text by splicing
        let startLineText = lines[startLine]
        let endLineText = lines[endLine]

        let prefix = startLineText.prefix(startChar)
        let suffixStart = endLineText.index(endLineText.startIndex, offsetBy: min(endChar, endLineText.count))
        let suffix = endLineText[suffixStart...]

        var newText = ""
        // Lines before the change
        for i in 0..<startLine {
            newText += lines[i] + "\n"
        }
        // The changed region
        newText += prefix + text + suffix
        // Lines after the change
        for i in (endLine + 1)..<lines.count {
            if i == lines.count - 1 {
                newText += "\n" + lines[i]
            } else {
                newText += "\n" + lines[i]
            }
        }

        let newLines = newText.split(separator: "\n", omittingEmptySubsequences: false)
        doc.version = version
        doc.text = newText
        doc.lines = newLines
        doc.tokens = nil
        doc.ast = nil
        doc.typeCheckResult = nil
        doc.cachedDiagnostics = []
        documents[uri] = doc
    }

    /// Get all tracked document URIs
    public func allURIs() -> [String] {
        return Array(documents.keys)
    }
}
