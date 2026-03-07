// InlayHintsProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import RockitKit

/// Provides inlay hints showing inferred types for untyped declarations
public final class InlayHintsProvider {

    public static func inlayHints(
        for result: AnalysisResult,
        uri: String,
        range: LSPRange?
    ) -> [LSPInlayHint] {
        var hints: [LSPInlayHint] = []

        for decl in result.ast.declarations {
            collectHints(from: decl, result: result, range: range, into: &hints)
        }

        return hints
    }

    // MARK: - Hint Collection

    private static func collectHints(
        from decl: RDeclaration,
        result: AnalysisResult,
        range: LSPRange?,
        into hints: inout [LSPInlayHint]
    ) {
        switch decl {
        case .function(let f):
            if let body = f.body {
                switch body {
                case .block(let block):
                    for stmt in block.statements {
                        collectHintsFromStmt(stmt, result: result, range: range, into: &hints)
                    }
                case .expression:
                    break
                }
            }

        case .property(let p):
            checkPropertyHint(p, result: result, range: range, into: &hints)

        case .classDecl(let c):
            for member in c.members {
                collectHints(from: member, result: result, range: range, into: &hints)
            }

        case .interfaceDecl(let i):
            for member in i.members {
                collectHints(from: member, result: result, range: range, into: &hints)
            }

        case .enumDecl(let e):
            for member in e.members {
                collectHints(from: member, result: result, range: range, into: &hints)
            }

        case .objectDecl(let o):
            for member in o.members {
                collectHints(from: member, result: result, range: range, into: &hints)
            }

        case .actorDecl(let a):
            for member in a.members {
                collectHints(from: member, result: result, range: range, into: &hints)
            }

        case .viewDecl(let v):
            for stmt in v.body.statements {
                collectHintsFromStmt(stmt, result: result, range: range, into: &hints)
            }

        default:
            break
        }
    }

    private static func collectHintsFromStmt(
        _ stmt: RStatement,
        result: AnalysisResult,
        range: LSPRange?,
        into hints: inout [LSPInlayHint]
    ) {
        switch stmt {
        case .propertyDecl(let p):
            checkPropertyHint(p, result: result, range: range, into: &hints)

        case .forLoop(let f):
            for s in f.body.statements {
                collectHintsFromStmt(s, result: result, range: range, into: &hints)
            }

        case .whileLoop(let w):
            for s in w.body.statements {
                collectHintsFromStmt(s, result: result, range: range, into: &hints)
            }

        case .declaration(let d):
            collectHints(from: d, result: result, range: range, into: &hints)

        case .expression(let expr):
            if case .ifExpr(let ie) = expr {
                for s in ie.thenBranch.statements {
                    collectHintsFromStmt(s, result: result, range: range, into: &hints)
                }
                if let elseBranch = ie.elseBranch {
                    switch elseBranch {
                    case .elseBlock(let block):
                        for s in block.statements {
                            collectHintsFromStmt(s, result: result, range: range, into: &hints)
                        }
                    case .elseIf(let elseIf):
                        let wrappedExpr: RExpression = .ifExpr(elseIf)
                        collectHintsFromStmt(.expression(wrappedExpr), result: result, range: range, into: &hints)
                    }
                }
            }

        default:
            break
        }
    }

    private static func checkPropertyHint(
        _ p: PropertyDecl,
        result: AnalysisResult,
        range: LSPRange?,
        into hints: inout [LSPInlayHint]
    ) {
        // Only hint for properties without explicit type annotation
        guard p.type == nil, let initializer = p.initializer else { return }

        let exprId = ExpressionID(expressionSpan(initializer))
        guard let inferredType = result.typeCheckResult.typeMap[exprId] else { return }

        // Skip error types and trivially obvious types
        let typeStr = typeToString(inferredType)
        if typeStr == "<error>" || typeStr == "Unit" { return }

        // Position: after the property name
        // val name = expr  →  val name: Type = expr
        let hintLine = p.span.start.line - 1  // 0-indexed
        let hintChar = p.span.start.column + (p.isVal ? 4 : 4) + p.name.count

        // Check range filter
        if let range = range {
            if hintLine < range.start.line || hintLine > range.end.line { return }
        }

        hints.append(LSPInlayHint(
            position: LSPPosition(line: hintLine, character: hintChar),
            label: ": \(typeStr)",
            kind: 1,  // Type hint
            paddingLeft: false,
            paddingRight: true
        ))
    }

    // MARK: - Type Display

    private static func typeToString(_ type: Type) -> String {
        switch type {
        case .int: return "Int"
        case .int32: return "Int32"
        case .int64: return "Int64"
        case .float: return "Float"
        case .float64: return "Float64"
        case .double: return "Double"
        case .bool: return "Bool"
        case .string: return "String"
        case .unit: return "Unit"
        case .nothing: return "Nothing"
        case .any: return "Any"
        case .byteArray: return "ByteArray"
        case .nullType: return "Null"
        case .nullable(let inner): return "\(typeToString(inner))?"
        case .classType(let name, let args):
            if args.isEmpty { return name }
            return "\(name)<\(args.map { typeToString($0) }.joined(separator: ", "))>"
        case .interfaceType(let name, let args):
            if args.isEmpty { return name }
            return "\(name)<\(args.map { typeToString($0) }.joined(separator: ", "))>"
        case .enumType(let name): return name
        case .objectType(let name): return name
        case .actorType(let name): return name
        case .function(let params, let ret):
            let paramStr = params.map { typeToString($0) }.joined(separator: ", ")
            return "(\(paramStr)) -> \(typeToString(ret))"
        case .tuple(let elems):
            return "(\(elems.map { typeToString($0) }.joined(separator: ", ")))"
        case .typeParameter(let name, _): return name
        case .error: return "<error>"
        }
    }
}
