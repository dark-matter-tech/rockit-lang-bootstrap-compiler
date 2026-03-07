// ReferencesProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import RockitKit

/// Finds all references to a symbol in the document
public final class ReferencesProvider {

    public static func references(
        at position: LSPPosition,
        uri: String,
        analysisResult: AnalysisResult,
        includeDeclaration: Bool
    ) -> [LSPLocation] {
        let sourcePos = lspPositionToSourceLocation(position, uri: uri)
        guard let nodeCtx = ASTNavigator.findNode(in: analysisResult.ast, at: sourcePos) else {
            return []
        }

        guard let targetName = extractSymbolName(from: nodeCtx) else { return [] }

        let defSpan = resolveDefinitionSpan(
            name: targetName,
            analysisResult: analysisResult
        )

        var locations: [LSPLocation] = []

        for decl in analysisResult.ast.declarations {
            collectReferencesInDecl(
                decl,
                targetName: targetName,
                defSpan: defSpan,
                uri: uri,
                includeDeclaration: includeDeclaration,
                into: &locations
            )
        }

        return locations
    }

    // MARK: - Symbol Name Extraction

    static func extractSymbolName(from nodeCtx: NodeAtPosition) -> String? {
        switch nodeCtx.kind {
        case .expression(let expr):
            switch expr {
            case .identifier(let name, _): return name
            case .memberAccess(_, let member, _): return member
            case .nullSafeMemberAccess(_, let member, _): return member
            default: return nil
            }
        case .declaration(let decl):
            return declarationName(decl)
        case .parameter(let p):
            return p.name
        case .statement:
            return nil
        }
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

    // MARK: - Definition Span Resolution

    private static func resolveDefinitionSpan(
        name: String,
        analysisResult: AnalysisResult
    ) -> SourceSpan? {
        if let sym = analysisResult.typeCheckResult.symbolTable.lookup(name) {
            return sym.span
        }
        return ASTNavigator.findDeclaration(named: name, in: analysisResult.ast)
    }

    // MARK: - AST Walking

    private static func collectReferencesInDecl(
        _ decl: RDeclaration,
        targetName: String,
        defSpan: SourceSpan?,
        uri: String,
        includeDeclaration: Bool,
        into locations: inout [LSPLocation]
    ) {
        // Check declaration name itself
        if let name = declarationName(decl), name == targetName {
            let span = declarationSpan(decl)
            if includeDeclaration || span != defSpan {
                let nameRange = nameRangeForDeclaration(decl)
                locations.append(LSPLocation(uri: uri, range: nameRange))
            }
        }

        // Walk into declaration body
        switch decl {
        case .function(let f):
            // Check parameters
            for param in f.parameters {
                if param.name == targetName {
                    locations.append(LSPLocation(uri: uri, range: sourceSpanToLSPRange(param.span)))
                }
            }
            // Check body
            if let body = f.body {
                switch body {
                case .block(let block):
                    for stmt in block.statements {
                        collectReferencesInStmt(stmt, targetName: targetName, defSpan: defSpan,
                                                 uri: uri, includeDeclaration: includeDeclaration, into: &locations)
                    }
                case .expression(let expr):
                    collectReferencesInExpr(expr, targetName: targetName, uri: uri, into: &locations)
                }
            }

        case .classDecl(let c):
            for member in c.members {
                collectReferencesInDecl(member, targetName: targetName, defSpan: defSpan,
                                         uri: uri, includeDeclaration: includeDeclaration, into: &locations)
            }

        case .interfaceDecl(let i):
            for member in i.members {
                collectReferencesInDecl(member, targetName: targetName, defSpan: defSpan,
                                         uri: uri, includeDeclaration: includeDeclaration, into: &locations)
            }

        case .enumDecl(let e):
            for entry in e.entries {
                if entry.name == targetName {
                    locations.append(LSPLocation(uri: uri, range: sourceSpanToLSPRange(entry.span)))
                }
            }
            for member in e.members {
                collectReferencesInDecl(member, targetName: targetName, defSpan: defSpan,
                                         uri: uri, includeDeclaration: includeDeclaration, into: &locations)
            }

        case .objectDecl(let o):
            for member in o.members {
                collectReferencesInDecl(member, targetName: targetName, defSpan: defSpan,
                                         uri: uri, includeDeclaration: includeDeclaration, into: &locations)
            }

        case .actorDecl(let a):
            for member in a.members {
                collectReferencesInDecl(member, targetName: targetName, defSpan: defSpan,
                                         uri: uri, includeDeclaration: includeDeclaration, into: &locations)
            }

        case .viewDecl(let v):
            for param in v.parameters {
                if param.name == targetName {
                    locations.append(LSPLocation(uri: uri, range: sourceSpanToLSPRange(param.span)))
                }
            }
            for stmt in v.body.statements {
                collectReferencesInStmt(stmt, targetName: targetName, defSpan: defSpan,
                                         uri: uri, includeDeclaration: includeDeclaration, into: &locations)
            }

        case .property(let p):
            if let init_ = p.initializer {
                collectReferencesInExpr(init_, targetName: targetName, uri: uri, into: &locations)
            }

        default:
            break
        }
    }

    private static func collectReferencesInStmt(
        _ stmt: RStatement,
        targetName: String,
        defSpan: SourceSpan?,
        uri: String,
        includeDeclaration: Bool,
        into locations: inout [LSPLocation]
    ) {
        switch stmt {
        case .expression(let expr):
            collectReferencesInExpr(expr, targetName: targetName, uri: uri, into: &locations)

        case .propertyDecl(let p):
            if p.name == targetName {
                locations.append(LSPLocation(uri: uri, range: sourceSpanToLSPRange(p.span)))
            }
            if let init_ = p.initializer {
                collectReferencesInExpr(init_, targetName: targetName, uri: uri, into: &locations)
            }

        case .returnStmt(let expr, _):
            if let expr = expr {
                collectReferencesInExpr(expr, targetName: targetName, uri: uri, into: &locations)
            }

        case .throwStmt(let expr, _):
            collectReferencesInExpr(expr, targetName: targetName, uri: uri, into: &locations)

        case .assignment(let a):
            collectReferencesInExpr(a.target, targetName: targetName, uri: uri, into: &locations)
            collectReferencesInExpr(a.value, targetName: targetName, uri: uri, into: &locations)

        case .forLoop(let f):
            collectReferencesInExpr(f.iterable, targetName: targetName, uri: uri, into: &locations)
            for s in f.body.statements {
                collectReferencesInStmt(s, targetName: targetName, defSpan: defSpan,
                                         uri: uri, includeDeclaration: includeDeclaration, into: &locations)
            }

        case .whileLoop(let w):
            collectReferencesInExpr(w.condition, targetName: targetName, uri: uri, into: &locations)
            for s in w.body.statements {
                collectReferencesInStmt(s, targetName: targetName, defSpan: defSpan,
                                         uri: uri, includeDeclaration: includeDeclaration, into: &locations)
            }

        case .doWhileLoop(let d):
            collectReferencesInExpr(d.condition, targetName: targetName, uri: uri, into: &locations)
            for s in d.body.statements {
                collectReferencesInStmt(s, targetName: targetName, defSpan: defSpan,
                                         uri: uri, includeDeclaration: includeDeclaration, into: &locations)
            }

        case .tryCatch(let tc):
            for s in tc.tryBody.statements {
                collectReferencesInStmt(s, targetName: targetName, defSpan: defSpan,
                                         uri: uri, includeDeclaration: includeDeclaration, into: &locations)
            }
            for s in tc.catchBody.statements {
                collectReferencesInStmt(s, targetName: targetName, defSpan: defSpan,
                                         uri: uri, includeDeclaration: includeDeclaration, into: &locations)
            }
            if let finallyBody = tc.finallyBody {
                for s in finallyBody.statements {
                    collectReferencesInStmt(s, targetName: targetName, defSpan: defSpan,
                                             uri: uri, includeDeclaration: includeDeclaration, into: &locations)
                }
            }

        case .declaration(let d):
            collectReferencesInDecl(d, targetName: targetName, defSpan: defSpan,
                                     uri: uri, includeDeclaration: includeDeclaration, into: &locations)

        default:
            break
        }
    }

    private static func collectReferencesInExpr(
        _ expr: RExpression,
        targetName: String,
        uri: String,
        into locations: inout [LSPLocation]
    ) {
        switch expr {
        case .identifier(let name, let span):
            if name == targetName {
                locations.append(LSPLocation(uri: uri, range: sourceSpanToLSPRange(span)))
            }

        case .memberAccess(let obj, let member, let span):
            collectReferencesInExpr(obj, targetName: targetName, uri: uri, into: &locations)
            if member == targetName {
                let memberRange = LSPRange(
                    start: LSPPosition(line: span.end.line - 1, character: span.end.column - member.count),
                    end: LSPPosition(line: span.end.line - 1, character: span.end.column)
                )
                locations.append(LSPLocation(uri: uri, range: memberRange))
            }

        case .nullSafeMemberAccess(let obj, let member, let span):
            collectReferencesInExpr(obj, targetName: targetName, uri: uri, into: &locations)
            if member == targetName {
                let memberRange = LSPRange(
                    start: LSPPosition(line: span.end.line - 1, character: span.end.column - member.count),
                    end: LSPPosition(line: span.end.line - 1, character: span.end.column)
                )
                locations.append(LSPLocation(uri: uri, range: memberRange))
            }

        case .call(let callee, let args, _, _):
            collectReferencesInExpr(callee, targetName: targetName, uri: uri, into: &locations)
            for arg in args {
                collectReferencesInExpr(arg.value, targetName: targetName, uri: uri, into: &locations)
            }

        case .binary(let left, _, let right, _):
            collectReferencesInExpr(left, targetName: targetName, uri: uri, into: &locations)
            collectReferencesInExpr(right, targetName: targetName, uri: uri, into: &locations)

        case .unaryPrefix(_, let operand, _):
            collectReferencesInExpr(operand, targetName: targetName, uri: uri, into: &locations)

        case .unaryPostfix(let operand, _, _):
            collectReferencesInExpr(operand, targetName: targetName, uri: uri, into: &locations)

        case .subscriptAccess(let obj, let index, _):
            collectReferencesInExpr(obj, targetName: targetName, uri: uri, into: &locations)
            collectReferencesInExpr(index, targetName: targetName, uri: uri, into: &locations)

        case .parenthesized(let inner, _):
            collectReferencesInExpr(inner, targetName: targetName, uri: uri, into: &locations)

        case .nonNullAssert(let inner, _):
            collectReferencesInExpr(inner, targetName: targetName, uri: uri, into: &locations)

        case .awaitExpr(let inner, _):
            collectReferencesInExpr(inner, targetName: targetName, uri: uri, into: &locations)

        case .elvis(let left, let right, _):
            collectReferencesInExpr(left, targetName: targetName, uri: uri, into: &locations)
            collectReferencesInExpr(right, targetName: targetName, uri: uri, into: &locations)

        case .typeCheck(let expr, _, _), .typeCast(let expr, _, _), .safeCast(let expr, _, _):
            collectReferencesInExpr(expr, targetName: targetName, uri: uri, into: &locations)

        case .range(let start, let end, _, _):
            collectReferencesInExpr(start, targetName: targetName, uri: uri, into: &locations)
            collectReferencesInExpr(end, targetName: targetName, uri: uri, into: &locations)

        case .ifExpr(let ie):
            collectReferencesInExpr(ie.condition, targetName: targetName, uri: uri, into: &locations)
            for s in ie.thenBranch.statements {
                collectReferencesInStmt(s, targetName: targetName, defSpan: nil,
                                         uri: uri, includeDeclaration: true, into: &locations)
            }
            if let elseBranch = ie.elseBranch {
                switch elseBranch {
                case .elseBlock(let block):
                    for s in block.statements {
                        collectReferencesInStmt(s, targetName: targetName, defSpan: nil,
                                                 uri: uri, includeDeclaration: true, into: &locations)
                    }
                case .elseIf(let elseIf):
                    collectReferencesInExpr(.ifExpr(elseIf), targetName: targetName, uri: uri, into: &locations)
                }
            }

        case .whenExpr(let we):
            if let subject = we.subject {
                collectReferencesInExpr(subject, targetName: targetName, uri: uri, into: &locations)
            }
            for entry in we.entries {
                switch entry.body {
                case .expression(let bodyExpr):
                    collectReferencesInExpr(bodyExpr, targetName: targetName, uri: uri, into: &locations)
                case .block(let block):
                    for s in block.statements {
                        collectReferencesInStmt(s, targetName: targetName, defSpan: nil,
                                                 uri: uri, includeDeclaration: true, into: &locations)
                    }
                }
            }

        case .lambda(let le):
            for s in le.body {
                collectReferencesInStmt(s, targetName: targetName, defSpan: nil,
                                         uri: uri, includeDeclaration: true, into: &locations)
            }

        case .interpolatedString(let parts, _):
            for part in parts {
                if case .interpolation(let e) = part {
                    collectReferencesInExpr(e, targetName: targetName, uri: uri, into: &locations)
                }
            }

        case .concurrentBlock(let stmts, _):
            for s in stmts {
                collectReferencesInStmt(s, targetName: targetName, defSpan: nil,
                                         uri: uri, includeDeclaration: true, into: &locations)
            }

        default:
            break
        }
    }

    // MARK: - Name Range Helper

    static func nameRangeForDeclaration(_ decl: RDeclaration) -> LSPRange {
        let span = declarationSpan(decl)
        return sourceSpanToLSPRange(span)
    }
}
