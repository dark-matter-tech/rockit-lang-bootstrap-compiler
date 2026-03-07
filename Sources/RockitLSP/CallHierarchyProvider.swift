// CallHierarchyProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import RockitKit

/// Provides call hierarchy — incoming and outgoing calls for functions
public final class CallHierarchyProvider {

    // MARK: - Prepare (resolve the item at cursor)

    public static func prepare(
        at position: LSPPosition,
        uri: String,
        analysisResult: AnalysisResult
    ) -> [LSPCallHierarchyItem] {
        let sourcePos = lspPositionToSourceLocation(position, uri: uri)
        guard let nodeCtx = ASTNavigator.findNode(in: analysisResult.ast, at: sourcePos) else {
            return []
        }

        // Only functions produce call hierarchy items
        switch nodeCtx.kind {
        case .declaration(let decl):
            if case .function(let f) = decl {
                return [makeItem(name: f.name, kind: LSPSymbolKind.function_, span: f.span, uri: uri)]
            }
        case .expression(let expr):
            if case .identifier(let name, let span) = expr {
                // Check if this identifier refers to a function
                if let sym = analysisResult.typeCheckResult.symbolTable.lookup(name),
                   case .function = sym.kind {
                    return [makeItem(name: name, kind: LSPSymbolKind.function_, span: span, uri: uri)]
                }
            }
        default:
            break
        }

        return []
    }

    // MARK: - Incoming Calls (who calls this function?)

    public static func incomingCalls(
        item: LSPCallHierarchyItem,
        uri: String,
        analysisResult: AnalysisResult
    ) -> [LSPCallHierarchyIncomingCall] {
        let targetName = item.name
        var calls: [LSPCallHierarchyIncomingCall] = []

        for decl in analysisResult.ast.declarations {
            findCallersInDecl(decl, callee: targetName, uri: uri, into: &calls)
        }

        return calls
    }

    // MARK: - Outgoing Calls (what does this function call?)

    public static func outgoingCalls(
        item: LSPCallHierarchyItem,
        uri: String,
        analysisResult: AnalysisResult
    ) -> [LSPCallHierarchyOutgoingCall] {
        let funcName = item.name
        var calls: [LSPCallHierarchyOutgoingCall] = []

        for decl in analysisResult.ast.declarations {
            if case .function(let f) = decl, f.name == funcName {
                if let body = f.body, case .block(let block) = body {
                    for stmt in block.statements {
                        findCalleesInStmt(stmt, uri: uri, analysisResult: analysisResult, into: &calls)
                    }
                }
            }
            // Also check class/object members
            findOutgoingInNestedDecl(decl, funcName: funcName, uri: uri,
                                     analysisResult: analysisResult, into: &calls)
        }

        return calls
    }

    // MARK: - Helpers

    private static func makeItem(
        name: String,
        kind: Int,
        span: SourceSpan,
        uri: String
    ) -> LSPCallHierarchyItem {
        let range = sourceSpanToLSPRange(span)
        return LSPCallHierarchyItem(
            name: name,
            kind: kind,
            uri: uri,
            range: range,
            selectionRange: range
        )
    }

    // MARK: - Incoming Call Search

    private static func findCallersInDecl(
        _ decl: RDeclaration,
        callee: String,
        uri: String,
        into calls: inout [LSPCallHierarchyIncomingCall]
    ) {
        switch decl {
        case .function(let f):
            var callRanges: [LSPRange] = []
            if let body = f.body, case .block(let block) = body {
                for stmt in block.statements {
                    findCallSitesInStmt(stmt, callee: callee, into: &callRanges)
                }
            }
            if !callRanges.isEmpty {
                let from = makeItem(name: f.name, kind: LSPSymbolKind.function_, span: f.span, uri: uri)
                calls.append(LSPCallHierarchyIncomingCall(from: from, fromRanges: callRanges))
            }

        case .classDecl(let c):
            for member in c.members {
                findCallersInDecl(member, callee: callee, uri: uri, into: &calls)
            }
        case .objectDecl(let o):
            for member in o.members {
                findCallersInDecl(member, callee: callee, uri: uri, into: &calls)
            }
        case .actorDecl(let a):
            for member in a.members {
                findCallersInDecl(member, callee: callee, uri: uri, into: &calls)
            }
        case .viewDecl(let v):
            var callRanges: [LSPRange] = []
            for stmt in v.body.statements {
                findCallSitesInStmt(stmt, callee: callee, into: &callRanges)
            }
            if !callRanges.isEmpty {
                let from = makeItem(name: v.name, kind: LSPSymbolKind.class_, span: v.span, uri: uri)
                calls.append(LSPCallHierarchyIncomingCall(from: from, fromRanges: callRanges))
            }

        default:
            break
        }
    }

    private static func findCallSitesInStmt(
        _ stmt: RStatement,
        callee: String,
        into ranges: inout [LSPRange]
    ) {
        switch stmt {
        case .expression(let expr):
            findCallSitesInExpr(expr, callee: callee, into: &ranges)
        case .propertyDecl(let p):
            if let init_ = p.initializer {
                findCallSitesInExpr(init_, callee: callee, into: &ranges)
            }
        case .returnStmt(let expr, _):
            if let expr = expr { findCallSitesInExpr(expr, callee: callee, into: &ranges) }
        case .assignment(let a):
            findCallSitesInExpr(a.target, callee: callee, into: &ranges)
            findCallSitesInExpr(a.value, callee: callee, into: &ranges)
        case .forLoop(let f):
            findCallSitesInExpr(f.iterable, callee: callee, into: &ranges)
            for s in f.body.statements { findCallSitesInStmt(s, callee: callee, into: &ranges) }
        case .whileLoop(let w):
            findCallSitesInExpr(w.condition, callee: callee, into: &ranges)
            for s in w.body.statements { findCallSitesInStmt(s, callee: callee, into: &ranges) }
        case .declaration(let d):
            if case .function(let f) = d, let body = f.body, case .block(let block) = body {
                for s in block.statements { findCallSitesInStmt(s, callee: callee, into: &ranges) }
            }
        default:
            break
        }
    }

    private static func findCallSitesInExpr(
        _ expr: RExpression,
        callee: String,
        into ranges: inout [LSPRange]
    ) {
        switch expr {
        case .call(let calleeExpr, let args, _, let span):
            if case .identifier(let name, _) = calleeExpr, name == callee {
                ranges.append(sourceSpanToLSPRange(span))
            }
            if case .memberAccess(_, let member, _) = calleeExpr, member == callee {
                ranges.append(sourceSpanToLSPRange(span))
            }
            findCallSitesInExpr(calleeExpr, callee: callee, into: &ranges)
            for arg in args { findCallSitesInExpr(arg.value, callee: callee, into: &ranges) }

        case .binary(let l, _, let r, _):
            findCallSitesInExpr(l, callee: callee, into: &ranges)
            findCallSitesInExpr(r, callee: callee, into: &ranges)
        case .unaryPrefix(_, let op, _):
            findCallSitesInExpr(op, callee: callee, into: &ranges)
        case .parenthesized(let inner, _):
            findCallSitesInExpr(inner, callee: callee, into: &ranges)
        case .ifExpr(let ie):
            findCallSitesInExpr(ie.condition, callee: callee, into: &ranges)
            for s in ie.thenBranch.statements { findCallSitesInStmt(s, callee: callee, into: &ranges) }
            if let elseBranch = ie.elseBranch {
                switch elseBranch {
                case .elseBlock(let block):
                    for s in block.statements { findCallSitesInStmt(s, callee: callee, into: &ranges) }
                case .elseIf(let elseIf):
                    findCallSitesInExpr(.ifExpr(elseIf), callee: callee, into: &ranges)
                }
            }
        case .lambda(let le):
            for s in le.body { findCallSitesInStmt(s, callee: callee, into: &ranges) }
        default:
            break
        }
    }

    // MARK: - Outgoing Call Search

    private static func findOutgoingInNestedDecl(
        _ decl: RDeclaration,
        funcName: String,
        uri: String,
        analysisResult: AnalysisResult,
        into calls: inout [LSPCallHierarchyOutgoingCall]
    ) {
        switch decl {
        case .classDecl(let c):
            for member in c.members {
                if case .function(let f) = member, f.name == funcName {
                    if let body = f.body, case .block(let block) = body {
                        for stmt in block.statements {
                            findCalleesInStmt(stmt, uri: uri, analysisResult: analysisResult, into: &calls)
                        }
                    }
                }
                findOutgoingInNestedDecl(member, funcName: funcName, uri: uri,
                                          analysisResult: analysisResult, into: &calls)
            }
        case .objectDecl(let o):
            for member in o.members {
                if case .function(let f) = member, f.name == funcName {
                    if let body = f.body, case .block(let block) = body {
                        for stmt in block.statements {
                            findCalleesInStmt(stmt, uri: uri, analysisResult: analysisResult, into: &calls)
                        }
                    }
                }
            }
        default:
            break
        }
    }

    private static func findCalleesInStmt(
        _ stmt: RStatement,
        uri: String,
        analysisResult: AnalysisResult,
        into calls: inout [LSPCallHierarchyOutgoingCall]
    ) {
        switch stmt {
        case .expression(let expr):
            findCalleesInExpr(expr, uri: uri, analysisResult: analysisResult, into: &calls)
        case .propertyDecl(let p):
            if let init_ = p.initializer {
                findCalleesInExpr(init_, uri: uri, analysisResult: analysisResult, into: &calls)
            }
        case .returnStmt(let expr, _):
            if let expr = expr { findCalleesInExpr(expr, uri: uri, analysisResult: analysisResult, into: &calls) }
        case .assignment(let a):
            findCalleesInExpr(a.value, uri: uri, analysisResult: analysisResult, into: &calls)
        case .forLoop(let f):
            for s in f.body.statements { findCalleesInStmt(s, uri: uri, analysisResult: analysisResult, into: &calls) }
        case .whileLoop(let w):
            for s in w.body.statements { findCalleesInStmt(s, uri: uri, analysisResult: analysisResult, into: &calls) }
        case .declaration(let d):
            if case .function(let f) = d, let body = f.body, case .block(let block) = body {
                for s in block.statements { findCalleesInStmt(s, uri: uri, analysisResult: analysisResult, into: &calls) }
            }
        default:
            break
        }
    }

    private static func findCalleesInExpr(
        _ expr: RExpression,
        uri: String,
        analysisResult: AnalysisResult,
        into calls: inout [LSPCallHierarchyOutgoingCall]
    ) {
        switch expr {
        case .call(let calleeExpr, let args, _, let span):
            if let name = callFunctionName(calleeExpr) {
                // Find the definition span for the callee
                let defSpan = ASTNavigator.findDeclaration(named: name, in: analysisResult.ast)
                let targetSpan = defSpan ?? expressionSpan(calleeExpr)
                let to = makeItem(name: name, kind: LSPSymbolKind.function_,
                                  span: targetSpan, uri: uri)
                calls.append(LSPCallHierarchyOutgoingCall(
                    to: to,
                    fromRanges: [sourceSpanToLSPRange(span)]
                ))
            }
            for arg in args {
                findCalleesInExpr(arg.value, uri: uri, analysisResult: analysisResult, into: &calls)
            }

        case .binary(let l, _, let r, _):
            findCalleesInExpr(l, uri: uri, analysisResult: analysisResult, into: &calls)
            findCalleesInExpr(r, uri: uri, analysisResult: analysisResult, into: &calls)
        case .parenthesized(let inner, _):
            findCalleesInExpr(inner, uri: uri, analysisResult: analysisResult, into: &calls)
        case .ifExpr(let ie):
            findCalleesInExpr(ie.condition, uri: uri, analysisResult: analysisResult, into: &calls)
            for s in ie.thenBranch.statements { findCalleesInStmt(s, uri: uri, analysisResult: analysisResult, into: &calls) }
        case .lambda(let le):
            for s in le.body { findCalleesInStmt(s, uri: uri, analysisResult: analysisResult, into: &calls) }
        default:
            break
        }
    }

    private static func callFunctionName(_ expr: RExpression) -> String? {
        switch expr {
        case .identifier(let name, _): return name
        case .memberAccess(_, let member, _): return member
        default: return nil
        }
    }
}
