// CodeActionProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import RockitKit

/// Provides quick-fix and refactoring code actions
public final class CodeActionProvider {

    public static func codeActions(
        uri: String,
        range: LSPRange?,
        diagnostics: [[String: Any]],
        analysisResult: AnalysisResult,
        documentText: String
    ) -> [LSPCodeAction] {
        var actions: [LSPCodeAction] = []

        // Action 1: Add explicit type annotation for untyped val/var
        if let range = range {
            actions.append(contentsOf: addTypeAnnotationActions(
                uri: uri,
                range: range,
                analysisResult: analysisResult,
                documentText: documentText
            ))
        }

        // Action 2: Diagnostic-driven actions
        for diagJSON in diagnostics {
            let message = diagJSON["message"] as? String ?? ""

            if message.lowercased().contains("unused") {
                if let action = removeUnusedAction(
                    uri: uri,
                    diagJSON: diagJSON,
                    documentText: documentText
                ) {
                    actions.append(action)
                }
            }
        }

        return actions
    }

    // MARK: - Add Type Annotation

    private static func addTypeAnnotationActions(
        uri: String,
        range: LSPRange,
        analysisResult: AnalysisResult,
        documentText: String
    ) -> [LSPCodeAction] {
        var actions: [LSPCodeAction] = []

        // Walk top-level and nested declarations looking for properties in the range
        for decl in analysisResult.ast.declarations {
            findUntypedProperties(in: decl, range: range, uri: uri,
                                  result: analysisResult, into: &actions)
        }

        return actions
    }

    private static func findUntypedProperties(
        in decl: RDeclaration,
        range: LSPRange,
        uri: String,
        result: AnalysisResult,
        into actions: inout [LSPCodeAction]
    ) {
        switch decl {
        case .property(let p):
            checkUntypedProperty(p, range: range, uri: uri, result: result, into: &actions)

        case .function(let f):
            if let body = f.body {
                switch body {
                case .block(let block):
                    for stmt in block.statements {
                        if case .propertyDecl(let p) = stmt {
                            checkUntypedProperty(p, range: range, uri: uri, result: result, into: &actions)
                        }
                    }
                case .expression:
                    break
                }
            }

        case .classDecl(let c):
            for member in c.members {
                findUntypedProperties(in: member, range: range, uri: uri, result: result, into: &actions)
            }

        default:
            break
        }
    }

    private static func checkUntypedProperty(
        _ p: PropertyDecl,
        range: LSPRange,
        uri: String,
        result: AnalysisResult,
        into actions: inout [LSPCodeAction]
    ) {
        guard p.type == nil, let initializer = p.initializer else { return }

        let propLine = p.span.start.line - 1  // 0-indexed
        guard propLine >= range.start.line && propLine <= range.end.line else { return }

        let exprId = ExpressionID(expressionSpan(initializer))
        guard let inferredType = result.typeCheckResult.typeMap[exprId] else { return }

        let typeStr = typeDisplayString(inferredType)
        if typeStr == "<error>" { return }

        // Insert ": Type" after the variable name
        let insertPos = LSPPosition(
            line: propLine,
            character: p.span.start.column + (p.isVal ? 4 : 4) + p.name.count
        )
        let insertRange = LSPRange(start: insertPos, end: insertPos)
        let edit = LSPTextEdit(range: insertRange, newText: ": \(typeStr)")

        actions.append(LSPCodeAction(
            title: "Add explicit type '\(typeStr)'",
            kind: "refactor",
            diagnostics: nil,
            edit: LSPWorkspaceEdit(changes: [uri: [edit]])
        ))
    }

    // MARK: - Remove Unused Variable

    private static func removeUnusedAction(
        uri: String,
        diagJSON: [String: Any],
        documentText: String
    ) -> LSPCodeAction? {
        guard let rangeJSON = diagJSON["range"] as? [String: Any],
              let range = LSPRange(json: rangeJSON) else { return nil }

        let lines = documentText.split(separator: "\n", omittingEmptySubsequences: false)
        let lineIdx = range.start.line
        guard lineIdx >= 0 && lineIdx < lines.count else { return nil }

        // Remove the entire line
        let removeRange = LSPRange(
            start: LSPPosition(line: lineIdx, character: 0),
            end: LSPPosition(line: lineIdx + 1, character: 0)
        )

        let edit = LSPTextEdit(range: removeRange, newText: "")

        return LSPCodeAction(
            title: "Remove unused declaration",
            kind: "quickfix",
            diagnostics: nil,
            edit: LSPWorkspaceEdit(changes: [uri: [edit]])
        )
    }

    // MARK: - Type Display

    private static func typeDisplayString(_ type: Type) -> String {
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
        case .nullable(let inner): return "\(typeDisplayString(inner))?"
        case .classType(let name, let args):
            if args.isEmpty { return name }
            return "\(name)<\(args.map { typeDisplayString($0) }.joined(separator: ", "))>"
        case .interfaceType(let name, let args):
            if args.isEmpty { return name }
            return "\(name)<\(args.map { typeDisplayString($0) }.joined(separator: ", "))>"
        case .enumType(let name): return name
        case .objectType(let name): return name
        case .actorType(let name): return name
        case .function(let params, let ret):
            let paramStr = params.map { typeDisplayString($0) }.joined(separator: ", ")
            return "(\(paramStr)) -> \(typeDisplayString(ret))"
        case .tuple(let elems):
            return "(\(elems.map { typeDisplayString($0) }.joined(separator: ", ")))"
        case .typeParameter(let name, _): return name
        case .error: return "<error>"
        default: return "Any"
        }
    }
}
