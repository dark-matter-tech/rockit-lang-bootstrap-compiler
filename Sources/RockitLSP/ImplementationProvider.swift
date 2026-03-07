// ImplementationProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import RockitKit

/// Provides go-to-implementation for interfaces and abstract/open classes
public final class ImplementationProvider {

    public static func implementations(
        at position: LSPPosition,
        uri: String,
        analysisResult: AnalysisResult
    ) -> [LSPLocation] {
        let sourcePos = lspPositionToSourceLocation(position, uri: uri)
        guard let nodeCtx = ASTNavigator.findNode(in: analysisResult.ast, at: sourcePos) else {
            return []
        }

        guard let targetName = ReferencesProvider.extractSymbolName(from: nodeCtx) else {
            return []
        }

        // Check if the target is a type declaration
        guard isTypeDeclaration(targetName, in: analysisResult) else {
            return []
        }

        var locations: [LSPLocation] = []

        // Walk all declarations looking for types that extend/implement the target
        for decl in analysisResult.ast.declarations {
            collectImplementors(of: targetName, in: decl, uri: uri, into: &locations)
        }

        return locations
    }

    // MARK: - Helpers

    private static func isTypeDeclaration(
        _ name: String,
        in result: AnalysisResult
    ) -> Bool {
        if let sym = result.typeCheckResult.symbolTable.lookup(name) {
            if case .typeDeclaration = sym.kind { return true }
        }
        if result.typeCheckResult.symbolTable.lookupType(name) != nil {
            return true
        }
        for decl in result.ast.declarations {
            switch decl {
            case .classDecl(let c) where c.name == name: return true
            case .interfaceDecl(let i) where i.name == name: return true
            case .enumDecl(let e) where e.name == name: return true
            case .objectDecl(let o) where o.name == name: return true
            case .actorDecl(let a) where a.name == name: return true
            default: continue
            }
        }
        return false
    }

    private static func collectImplementors(
        of targetName: String,
        in decl: RDeclaration,
        uri: String,
        into locations: inout [LSPLocation]
    ) {
        switch decl {
        case .classDecl(let c):
            if c.superTypes.contains(where: { typeNodeName($0) == targetName }) {
                locations.append(LSPLocation(uri: uri, range: sourceSpanToLSPRange(c.span)))
            }
            for member in c.members {
                collectImplementors(of: targetName, in: member, uri: uri, into: &locations)
            }

        case .objectDecl(let o):
            if o.superTypes.contains(where: { typeNodeName($0) == targetName }) {
                locations.append(LSPLocation(uri: uri, range: sourceSpanToLSPRange(o.span)))
            }
            for member in o.members {
                collectImplementors(of: targetName, in: member, uri: uri, into: &locations)
            }

        case .interfaceDecl(let i):
            // Interfaces can extend other interfaces
            if i.superTypes.contains(where: { typeNodeName($0) == targetName }) {
                locations.append(LSPLocation(uri: uri, range: sourceSpanToLSPRange(i.span)))
            }
            for member in i.members {
                collectImplementors(of: targetName, in: member, uri: uri, into: &locations)
            }

        default:
            break
        }
    }

    private static func typeNodeName(_ typeNode: TypeNode) -> String? {
        switch typeNode {
        case .simple(let name, _, _): return name
        case .qualified(_, let member, _): return member
        default: return nil
        }
    }
}
