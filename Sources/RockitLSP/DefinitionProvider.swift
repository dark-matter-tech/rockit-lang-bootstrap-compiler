// DefinitionProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import RockitKit

/// Implements textDocument/definition (go-to-definition)
public final class DefinitionProvider {

    /// Find the definition location for the symbol at the given position
    public static func definition(
        at position: LSPPosition,
        uri: String,
        analysisResult: AnalysisResult
    ) -> LSPLocation? {
        let sourcePos = lspPositionToSourceLocation(position, uri: uri)

        guard let nodeCtx = ASTNavigator.findNode(in: analysisResult.ast, at: sourcePos) else {
            return nil
        }

        switch nodeCtx.kind {
        case .expression(let expr):
            return definitionForExpression(expr, uri: uri, analysisResult: analysisResult)

        case .declaration:
            // Already at the declaration
            return nil

        case .parameter:
            // Parameters are their own definition
            return nil

        case .statement:
            return nil
        }
    }

    // MARK: - Private

    private static func definitionForExpression(
        _ expr: RockitKit.Expression,
        uri: String,
        analysisResult: AnalysisResult
    ) -> LSPLocation? {
        switch expr {
        case .identifier(let name, _):
            return lookupDefinition(name: name, uri: uri, analysisResult: analysisResult)

        case .memberAccess(let obj, let member, _):
            // Resolve the object's type, then find the member
            let objSpan = expressionSpan(obj)
            let exprId = ExpressionID(objSpan)
            if let objType = analysisResult.typeCheckResult.typeMap[exprId],
               let typeName = objType.typeName ?? typeToName(objType) {
                return lookupMemberDefinition(
                    typeName: typeName,
                    memberName: member,
                    uri: uri,
                    analysisResult: analysisResult
                )
            }

        case .nullSafeMemberAccess(let obj, let member, _):
            let objSpan = expressionSpan(obj)
            let exprId = ExpressionID(objSpan)
            if let objType = analysisResult.typeCheckResult.typeMap[exprId] {
                let unwrapped = objType.unwrapNullable
                if let typeName = unwrapped.typeName ?? typeToName(unwrapped) {
                    return lookupMemberDefinition(
                        typeName: typeName,
                        memberName: member,
                        uri: uri,
                        analysisResult: analysisResult
                    )
                }
            }

        case .call(let callee, _, _, _):
            if case .identifier(let name, _) = callee {
                return lookupDefinition(name: name, uri: uri, analysisResult: analysisResult)
            }
            if case .memberAccess(let obj, let member, _) = callee {
                let objSpan = expressionSpan(obj)
                let exprId = ExpressionID(objSpan)
                if let objType = analysisResult.typeCheckResult.typeMap[exprId],
                   let typeName = objType.typeName ?? typeToName(objType) {
                    return lookupMemberDefinition(
                        typeName: typeName,
                        memberName: member,
                        uri: uri,
                        analysisResult: analysisResult
                    )
                }
            }

        default:
            break
        }

        return nil
    }

    private static func lookupDefinition(
        name: String,
        uri: String,
        analysisResult: AnalysisResult
    ) -> LSPLocation? {
        // Check symbol table (has definition spans)
        if let sym = analysisResult.typeCheckResult.symbolTable.lookup(name),
           let defSpan = sym.span {
            return LSPLocation(
                uri: pathToURI(defSpan.start.file),
                range: sourceSpanToLSPRange(defSpan)
            )
        }

        // Check type declarations
        if analysisResult.typeCheckResult.symbolTable.lookupType(name) != nil {
            if let declSpan = ASTNavigator.findDeclaration(named: name, in: analysisResult.ast) {
                return LSPLocation(
                    uri: uri,
                    range: sourceSpanToLSPRange(declSpan)
                )
            }
        }

        // Search AST directly
        if let declSpan = ASTNavigator.findDeclaration(named: name, in: analysisResult.ast) {
            return LSPLocation(
                uri: uri,
                range: sourceSpanToLSPRange(declSpan)
            )
        }

        return nil
    }

    private static func lookupMemberDefinition(
        typeName: String,
        memberName: String,
        uri: String,
        analysisResult: AnalysisResult
    ) -> LSPLocation? {
        if let typeInfo = analysisResult.typeCheckResult.symbolTable.lookupType(typeName) {
            for member in typeInfo.members {
                if member.name == memberName, let span = member.span {
                    return LSPLocation(
                        uri: pathToURI(span.start.file),
                        range: sourceSpanToLSPRange(span)
                    )
                }
            }
        }
        return nil
    }

    private static func typeToName(_ type: Type) -> String? {
        switch type {
        case .string: return "String"
        case .int: return "Int"
        case .bool: return "Bool"
        case .classType(let name, _): return name
        case .interfaceType(let name, _): return name
        case .enumType(let name): return name
        case .actorType(let name): return name
        case .objectType(let name): return name
        default: return nil
        }
    }
}
