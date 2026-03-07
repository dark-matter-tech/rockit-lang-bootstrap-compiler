// DocumentHighlightProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import RockitKit

/// Highlights all occurrences of the symbol under the cursor within the document
public final class DocumentHighlightProvider {

    public static func highlights(
        at position: LSPPosition,
        uri: String,
        analysisResult: AnalysisResult
    ) -> [LSPDocumentHighlight] {
        // Reuse ReferencesProvider to find all occurrences
        let locations = ReferencesProvider.references(
            at: position,
            uri: uri,
            analysisResult: analysisResult,
            includeDeclaration: true
        )

        // Convert locations to highlights (all in the same document)
        return locations.compactMap { loc in
            guard loc.uri == uri else { return nil }

            // Check if this location is a write (assignment target) or read
            let kind = classifyHighlight(
                range: loc.range,
                analysisResult: analysisResult
            )

            return LSPDocumentHighlight(range: loc.range, kind: kind)
        }
    }

    private static func classifyHighlight(
        range: LSPRange,
        analysisResult: AnalysisResult
    ) -> Int {
        // Check if the position corresponds to a declaration or assignment target
        let sourcePos = SourceLocation(file: "", line: range.start.line + 1, column: range.start.character)

        for decl in analysisResult.ast.declarations {
            if isWriteLocation(decl, at: sourcePos) {
                return 3  // Write
            }
        }

        return 2  // Read (default)
    }

    private static func isWriteLocation(_ decl: RDeclaration, at position: SourceLocation) -> Bool {
        switch decl {
        case .property(let p):
            if p.span.start.line == position.line && p.span.start.column == position.column {
                return true
            }

        case .function(let f):
            if f.span.start.line == position.line && f.span.start.column == position.column {
                return true
            }
            if let body = f.body, case .block(let block) = body {
                for stmt in block.statements {
                    if isWriteStatement(stmt, at: position) { return true }
                }
            }

        case .classDecl(let c):
            for member in c.members {
                if isWriteLocation(member, at: position) { return true }
            }

        default:
            break
        }
        return false
    }

    private static func isWriteStatement(_ stmt: RStatement, at position: SourceLocation) -> Bool {
        switch stmt {
        case .propertyDecl(let p):
            return p.span.start.line == position.line && p.span.start.column == position.column

        case .assignment(let a):
            let targetSpan = expressionSpan(a.target)
            return targetSpan.start.line == position.line && targetSpan.start.column == position.column

        case .forLoop(let f):
            for s in f.body.statements {
                if isWriteStatement(s, at: position) { return true }
            }

        case .whileLoop(let w):
            for s in w.body.statements {
                if isWriteStatement(s, at: position) { return true }
            }

        case .declaration(let d):
            return isWriteLocation(d, at: position)

        default:
            break
        }
        return false
    }
}
