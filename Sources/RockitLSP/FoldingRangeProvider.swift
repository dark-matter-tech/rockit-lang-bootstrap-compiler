// FoldingRangeProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import RockitKit

/// Provides folding ranges for code blocks, comments, and imports
public final class FoldingRangeProvider {

    public static func foldingRanges(
        for result: AnalysisResult,
        documentText: String
    ) -> [LSPFoldingRange] {
        var ranges: [LSPFoldingRange] = []

        // Fold declarations (classes, functions, etc.)
        for decl in result.ast.declarations {
            collectFoldingRangesFromDecl(decl, into: &ranges)
        }

        // Fold consecutive import lines
        collectImportFolds(documentText: documentText, into: &ranges)

        return ranges
    }

    // MARK: - Declaration Folding

    private static func collectFoldingRangesFromDecl(
        _ decl: RDeclaration,
        into ranges: inout [LSPFoldingRange]
    ) {
        let span = declarationSpan(decl)
        let startLine = span.start.line - 1
        let endLine = span.end.line - 1

        // Only fold if the declaration spans multiple lines
        if endLine > startLine {
            ranges.append(LSPFoldingRange(
                startLine: startLine,
                startCharacter: nil,
                endLine: endLine,
                endCharacter: nil,
                kind: "region"
            ))
        }

        // Recurse into members
        switch decl {
        case .function(let f):
            if let body = f.body, case .block(let block) = body {
                for stmt in block.statements {
                    collectFoldingRangesFromStmt(stmt, into: &ranges)
                }
            }

        case .classDecl(let c):
            for member in c.members {
                collectFoldingRangesFromDecl(member, into: &ranges)
            }

        case .interfaceDecl(let i):
            for member in i.members {
                collectFoldingRangesFromDecl(member, into: &ranges)
            }

        case .enumDecl(let e):
            for member in e.members {
                collectFoldingRangesFromDecl(member, into: &ranges)
            }

        case .objectDecl(let o):
            for member in o.members {
                collectFoldingRangesFromDecl(member, into: &ranges)
            }

        case .actorDecl(let a):
            for member in a.members {
                collectFoldingRangesFromDecl(member, into: &ranges)
            }

        case .viewDecl(let v):
            for stmt in v.body.statements {
                collectFoldingRangesFromStmt(stmt, into: &ranges)
            }

        default:
            break
        }
    }

    private static func collectFoldingRangesFromStmt(
        _ stmt: RStatement,
        into ranges: inout [LSPFoldingRange]
    ) {
        switch stmt {
        case .forLoop(let f):
            let startLine = f.span.start.line - 1
            let endLine = f.span.end.line - 1
            if endLine > startLine {
                ranges.append(LSPFoldingRange(startLine: startLine, startCharacter: nil,
                                               endLine: endLine, endCharacter: nil, kind: "region"))
            }
            for s in f.body.statements {
                collectFoldingRangesFromStmt(s, into: &ranges)
            }

        case .whileLoop(let w):
            let startLine = w.span.start.line - 1
            let endLine = w.span.end.line - 1
            if endLine > startLine {
                ranges.append(LSPFoldingRange(startLine: startLine, startCharacter: nil,
                                               endLine: endLine, endCharacter: nil, kind: "region"))
            }
            for s in w.body.statements {
                collectFoldingRangesFromStmt(s, into: &ranges)
            }

        case .tryCatch(let tc):
            let startLine = tc.span.start.line - 1
            let endLine = tc.span.end.line - 1
            if endLine > startLine {
                ranges.append(LSPFoldingRange(startLine: startLine, startCharacter: nil,
                                               endLine: endLine, endCharacter: nil, kind: "region"))
            }

        case .expression(let expr):
            if case .ifExpr(let ie) = expr {
                let startLine = ie.span.start.line - 1
                let endLine = ie.span.end.line - 1
                if endLine > startLine {
                    ranges.append(LSPFoldingRange(startLine: startLine, startCharacter: nil,
                                                   endLine: endLine, endCharacter: nil, kind: "region"))
                }
            }
            if case .whenExpr(let we) = expr {
                let startLine = we.span.start.line - 1
                let endLine = we.span.end.line - 1
                if endLine > startLine {
                    ranges.append(LSPFoldingRange(startLine: startLine, startCharacter: nil,
                                                   endLine: endLine, endCharacter: nil, kind: "region"))
                }
            }

        case .declaration(let d):
            collectFoldingRangesFromDecl(d, into: &ranges)

        default:
            break
        }
    }

    // MARK: - Import Folding

    private static func collectImportFolds(
        documentText: String,
        into ranges: inout [LSPFoldingRange]
    ) {
        let lines = documentText.split(separator: "\n", omittingEmptySubsequences: false)
        var importStart: Int?
        var importEnd: Int?

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("import ") {
                if importStart == nil {
                    importStart = i
                }
                importEnd = i
            } else if trimmed.isEmpty {
                continue  // Allow blank lines between imports
            } else {
                if let start = importStart, let end = importEnd, end > start {
                    ranges.append(LSPFoldingRange(startLine: start, startCharacter: nil,
                                                   endLine: end, endCharacter: nil, kind: "imports"))
                }
                importStart = nil
                importEnd = nil
            }
        }

        // Handle imports at end of file
        if let start = importStart, let end = importEnd, end > start {
            ranges.append(LSPFoldingRange(startLine: start, startCharacter: nil,
                                           endLine: end, endCharacter: nil, kind: "imports"))
        }
    }
}
