// TypeDefinitionProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import RockitKit

/// Jump to the type definition of the symbol under cursor
public final class TypeDefinitionProvider {

    public static func typeDefinition(
        at position: LSPPosition,
        uri: String,
        analysisResult: AnalysisResult
    ) -> LSPLocation? {
        let sourcePos = lspPositionToSourceLocation(position, uri: uri)
        guard let nodeCtx = ASTNavigator.findNode(in: analysisResult.ast, at: sourcePos) else {
            return nil
        }

        // Get the type of the symbol at cursor
        let typeName: String?

        switch nodeCtx.kind {
        case .expression(let expr):
            let exprId = ExpressionID(expressionSpan(expr))
            if let inferredType = analysisResult.typeCheckResult.typeMap[exprId] {
                typeName = extractTypeName(inferredType)
            } else if case .identifier(let name, _) = expr {
                // Fall back to symbol table lookup
                typeName = lookupSymbolTypeName(name, in: analysisResult)
            } else {
                typeName = nil
            }

        case .declaration(let decl):
            if case .property(let p) = decl {
                if let typeNode = p.type {
                    typeName = typeNodeTopName(typeNode)
                } else if let init_ = p.initializer {
                    let exprId = ExpressionID(expressionSpan(init_))
                    if let inferredType = analysisResult.typeCheckResult.typeMap[exprId] {
                        typeName = extractTypeName(inferredType)
                    } else {
                        typeName = nil
                    }
                } else {
                    typeName = nil
                }
            } else {
                typeName = nil
            }

        case .parameter(let p):
            if let typeNode = p.type {
                typeName = typeNodeTopName(typeNode)
            } else {
                typeName = lookupSymbolTypeName(p.name, in: analysisResult)
            }

        case .statement:
            typeName = nil
        }

        guard let name = typeName else { return nil }

        // Find the type declaration in the AST
        if let span = ASTNavigator.findDeclaration(named: name, in: analysisResult.ast) {
            return LSPLocation(uri: uri, range: sourceSpanToLSPRange(span))
        }

        return nil
    }

    // MARK: - Helpers

    private static func extractTypeName(_ type: Type) -> String? {
        switch type {
        case .classType(let name, _): return name
        case .interfaceType(let name, _): return name
        case .enumType(let name): return name
        case .objectType(let name): return name
        case .actorType(let name): return name
        case .nullable(let inner): return extractTypeName(inner)
        default: return nil  // Primitives don't have type definitions
        }
    }

    private static func lookupSymbolTypeName(_ name: String, in result: AnalysisResult) -> String? {
        if let sym = result.typeCheckResult.symbolTable.lookup(name) {
            return extractTypeName(sym.type)
        }
        return nil
    }

    private static func typeNodeTopName(_ typeNode: TypeNode) -> String? {
        switch typeNode {
        case .simple(let name, _, _): return name
        case .nullable(let inner, _): return typeNodeTopName(inner)
        case .qualified(_, let member, _): return member
        default: return nil
        }
    }
}
