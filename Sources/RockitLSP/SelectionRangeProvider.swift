// SelectionRangeProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import RockitKit

/// Provides smart selection ranges (expand/shrink selection)
public final class SelectionRangeProvider {

    public static func selectionRanges(
        positions: [LSPPosition],
        uri: String,
        analysisResult: AnalysisResult
    ) -> [LSPSelectionRange] {
        return positions.map { pos in
            selectionRange(at: pos, uri: uri, analysisResult: analysisResult)
        }
    }

    private static func selectionRange(
        at position: LSPPosition,
        uri: String,
        analysisResult: AnalysisResult
    ) -> LSPSelectionRange {
        let sourcePos = lspPositionToSourceLocation(position, uri: uri)

        // Build a stack of enclosing ranges from outermost to innermost
        var rangeStack: [LSPRange] = []

        // Full document range
        if let lastDecl = analysisResult.ast.declarations.last {
            let lastSpan = declarationSpan(lastDecl)
            let docRange = LSPRange(
                start: LSPPosition(line: 0, character: 0),
                end: sourceLocationToLSPPosition(lastSpan.end)
            )
            rangeStack.append(docRange)
        }

        // Find enclosing ranges from AST
        for decl in analysisResult.ast.declarations {
            collectEnclosingRanges(decl: decl, at: sourcePos, into: &rangeStack)
        }

        // Sort from outermost to innermost (largest to smallest)
        rangeStack.sort { rangeSize($0) > rangeSize($1) }

        // Remove duplicates
        var deduped: [LSPRange] = []
        for r in rangeStack {
            if deduped.last.map({ $0.start.line != r.start.line || $0.start.character != r.start.character ||
                                   $0.end.line != r.end.line || $0.end.character != r.end.character }) ?? true {
                deduped.append(r)
            }
        }

        // Build nested SelectionRange from outermost to innermost
        return buildNestedSelectionRange(from: deduped)
    }

    private static func collectEnclosingRanges(
        decl: RDeclaration,
        at position: SourceLocation,
        into ranges: inout [LSPRange]
    ) {
        let span = declarationSpan(decl)
        guard spanContains(span, position) else { return }

        ranges.append(sourceSpanToLSPRange(span))

        switch decl {
        case .function(let f):
            if let body = f.body, case .block(let block) = body {
                if spanContains(block.span, position) {
                    ranges.append(sourceSpanToLSPRange(block.span))
                }
                for stmt in block.statements {
                    collectEnclosingRangesFromStmt(stmt, at: position, into: &ranges)
                }
            }

        case .classDecl(let c):
            for member in c.members {
                collectEnclosingRanges(decl: member, at: position, into: &ranges)
            }

        case .interfaceDecl(let i):
            for member in i.members {
                collectEnclosingRanges(decl: member, at: position, into: &ranges)
            }

        case .enumDecl(let e):
            for member in e.members {
                collectEnclosingRanges(decl: member, at: position, into: &ranges)
            }

        case .objectDecl(let o):
            for member in o.members {
                collectEnclosingRanges(decl: member, at: position, into: &ranges)
            }

        case .actorDecl(let a):
            for member in a.members {
                collectEnclosingRanges(decl: member, at: position, into: &ranges)
            }

        case .viewDecl(let v):
            if spanContains(v.body.span, position) {
                ranges.append(sourceSpanToLSPRange(v.body.span))
            }
            for stmt in v.body.statements {
                collectEnclosingRangesFromStmt(stmt, at: position, into: &ranges)
            }

        default:
            break
        }
    }

    private static func collectEnclosingRangesFromStmt(
        _ stmt: RStatement,
        at position: SourceLocation,
        into ranges: inout [LSPRange]
    ) {
        guard let stmtSp = statementSpan(stmt), spanContains(stmtSp, position) else { return }
        ranges.append(sourceSpanToLSPRange(stmtSp))

        switch stmt {
        case .forLoop(let f):
            if spanContains(f.body.span, position) {
                ranges.append(sourceSpanToLSPRange(f.body.span))
                for s in f.body.statements {
                    collectEnclosingRangesFromStmt(s, at: position, into: &ranges)
                }
            }

        case .whileLoop(let w):
            if spanContains(w.body.span, position) {
                ranges.append(sourceSpanToLSPRange(w.body.span))
                for s in w.body.statements {
                    collectEnclosingRangesFromStmt(s, at: position, into: &ranges)
                }
            }

        case .expression(let expr):
            collectEnclosingRangesFromExpr(expr, at: position, into: &ranges)

        case .declaration(let d):
            collectEnclosingRanges(decl: d, at: position, into: &ranges)

        default:
            break
        }
    }

    private static func collectEnclosingRangesFromExpr(
        _ expr: RExpression,
        at position: SourceLocation,
        into ranges: inout [LSPRange]
    ) {
        let exprSpan = expressionSpan(expr)
        guard spanContains(exprSpan, position) else { return }
        ranges.append(sourceSpanToLSPRange(exprSpan))

        switch expr {
        case .ifExpr(let ie):
            if spanContains(ie.thenBranch.span, position) {
                ranges.append(sourceSpanToLSPRange(ie.thenBranch.span))
            }

        case .whenExpr(let we):
            for entry in we.entries {
                switch entry.body {
                case .block(let block):
                    if spanContains(block.span, position) {
                        ranges.append(sourceSpanToLSPRange(block.span))
                    }
                case .expression(let bodyExpr):
                    collectEnclosingRangesFromExpr(bodyExpr, at: position, into: &ranges)
                }
            }

        case .lambda(let le):
            if spanContains(le.span, position) {
                ranges.append(sourceSpanToLSPRange(le.span))
            }

        case .call(let callee, _, _, _):
            collectEnclosingRangesFromExpr(callee, at: position, into: &ranges)

        default:
            break
        }
    }

    // MARK: - Helpers

    private static func spanContains(_ span: SourceSpan, _ pos: SourceLocation) -> Bool {
        if pos.line < span.start.line || pos.line > span.end.line { return false }
        if pos.line == span.start.line && pos.column < span.start.column { return false }
        if pos.line == span.end.line && pos.column > span.end.column { return false }
        return true
    }

    private static func rangeSize(_ range: LSPRange) -> Int {
        return (range.end.line - range.start.line) * 1000 + (range.end.character - range.start.character)
    }

    private static func buildNestedSelectionRange(from ranges: [LSPRange]) -> LSPSelectionRange {
        guard !ranges.isEmpty else {
            return LSPSelectionRange(
                range: LSPRange(start: LSPPosition(line: 0, character: 0),
                               end: LSPPosition(line: 0, character: 0)),
                parent: nil
            )
        }

        var result = LSPSelectionRange(range: ranges[0], parent: nil)
        for i in 1..<ranges.count {
            result = LSPSelectionRange(range: ranges[i], parent: result)
        }
        return result
    }
}
