// RenameProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import RockitKit

/// Handles textDocument/rename and textDocument/prepareRename
public final class RenameProvider {

    /// Validate that the symbol at position is renameable and return its range
    public static func prepareRename(
        at position: LSPPosition,
        uri: String,
        analysisResult: AnalysisResult
    ) -> LSPRange? {
        let sourcePos = lspPositionToSourceLocation(position, uri: uri)
        guard let nodeCtx = ASTNavigator.findNode(in: analysisResult.ast, at: sourcePos) else {
            return nil
        }

        switch nodeCtx.kind {
        case .expression(let expr):
            switch expr {
            case .identifier(_, let span):
                return sourceSpanToLSPRange(span)
            case .memberAccess(_, let member, let span):
                return LSPRange(
                    start: LSPPosition(line: span.end.line - 1, character: span.end.column - member.count),
                    end: LSPPosition(line: span.end.line - 1, character: span.end.column)
                )
            default:
                return nil
            }
        case .declaration(let decl):
            return nameRangeForDeclaration(decl)
        case .parameter(let p):
            return sourceSpanToLSPRange(p.span)
        case .statement:
            return nil
        }
    }

    /// Perform the rename: find all references and build a WorkspaceEdit
    public static func rename(
        at position: LSPPosition,
        uri: String,
        newName: String,
        analysisResult: AnalysisResult
    ) -> LSPWorkspaceEdit? {
        let locations = ReferencesProvider.references(
            at: position,
            uri: uri,
            analysisResult: analysisResult,
            includeDeclaration: true
        )

        if locations.isEmpty { return nil }

        var changes: [String: [LSPTextEdit]] = [:]
        for loc in locations {
            let edit = LSPTextEdit(range: loc.range, newText: newName)
            changes[loc.uri, default: []].append(edit)
        }

        return LSPWorkspaceEdit(changes: changes)
    }

    // MARK: - Private Helpers

    /// Compute a range covering just the name portion of a declaration
    private static func nameRangeForDeclaration(_ decl: RDeclaration) -> LSPRange? {
        guard let name = declarationName(decl) else { return nil }
        let span = declarationSpan(decl)
        let line = span.start.line - 1 // Convert to 0-indexed
        let startCol: Int

        switch decl {
        case .function(let f):
            // "fun name" — name starts after "fun "
            startCol = span.start.column + 4
            _ = f
        case .property(let p):
            // "val name" or "var name"
            startCol = span.start.column + 4
            _ = p
        case .classDecl:
            return findNameInSpan(name: name, span: span)
        case .interfaceDecl:
            return findNameInSpan(name: name, span: span)
        case .enumDecl:
            return findNameInSpan(name: name, span: span)
        case .objectDecl:
            return findNameInSpan(name: name, span: span)
        case .actorDecl:
            return findNameInSpan(name: name, span: span)
        case .viewDecl:
            return findNameInSpan(name: name, span: span)
        default:
            return findNameInSpan(name: name, span: span)
        }

        return LSPRange(
            start: LSPPosition(line: line, character: startCol),
            end: LSPPosition(line: line, character: startCol + name.count)
        )
    }

    private static func findNameInSpan(name: String, span: SourceSpan) -> LSPRange? {
        let line = span.start.line - 1
        return LSPRange(
            start: LSPPosition(line: line, character: span.start.column),
            end: LSPPosition(line: line, character: span.start.column + name.count)
        )
    }

    private static func declarationName(_ decl: RDeclaration) -> String? {
        switch decl {
        case .function(let f): return f.name
        case .property(let p): return p.name
        case .classDecl(let c): return c.name
        case .interfaceDecl(let i): return i.name
        case .enumDecl(let e): return e.name
        case .objectDecl(let o): return o.name
        case .actorDecl(let a): return a.name
        case .viewDecl(let v): return v.name
        case .navigationDecl(let n): return n.name
        case .themeDecl(let t): return t.name
        case .typeAlias(let ta): return ta.name
        }
    }
}

// Helper extension on NodeAtPosition.Kind
extension NodeAtPosition.Kind {
    var asDeclaration: RDeclaration? {
        if case .declaration(let d) = self { return d }
        return nil
    }
}
