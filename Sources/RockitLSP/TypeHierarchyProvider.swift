// TypeHierarchyProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import RockitKit

/// Provides type hierarchy — supertypes and subtypes for classes/interfaces
public final class TypeHierarchyProvider {

    // MARK: - Prepare

    public static func prepare(
        at position: LSPPosition,
        uri: String,
        analysisResult: AnalysisResult
    ) -> [LSPTypeHierarchyItem] {
        let sourcePos = lspPositionToSourceLocation(position, uri: uri)
        guard let nodeCtx = ASTNavigator.findNode(in: analysisResult.ast, at: sourcePos) else {
            return []
        }

        guard let targetName = ReferencesProvider.extractSymbolName(from: nodeCtx) else {
            return []
        }

        // Find the type declaration
        for decl in analysisResult.ast.declarations {
            if let item = matchTypeDecl(decl, name: targetName, uri: uri) {
                return [item]
            }
        }

        return []
    }

    // MARK: - Supertypes

    public static func supertypes(
        item: LSPTypeHierarchyItem,
        uri: String,
        analysisResult: AnalysisResult
    ) -> [LSPTypeHierarchyItem] {
        var results: [LSPTypeHierarchyItem] = []
        let targetName = item.name

        for decl in analysisResult.ast.declarations {
            switch decl {
            case .classDecl(let c) where c.name == targetName:
                for superType in c.superTypes {
                    if let name = typeNodeName(superType) {
                        if let superItem = findTypeItem(named: name, in: analysisResult.ast, uri: uri) {
                            results.append(superItem)
                        }
                    }
                }

            case .interfaceDecl(let i) where i.name == targetName:
                for superType in i.superTypes {
                    if let name = typeNodeName(superType) {
                        if let superItem = findTypeItem(named: name, in: analysisResult.ast, uri: uri) {
                            results.append(superItem)
                        }
                    }
                }

            case .objectDecl(let o) where o.name == targetName:
                for superType in o.superTypes {
                    if let name = typeNodeName(superType) {
                        if let superItem = findTypeItem(named: name, in: analysisResult.ast, uri: uri) {
                            results.append(superItem)
                        }
                    }
                }

            default:
                break
            }
        }

        return results
    }

    // MARK: - Subtypes

    public static func subtypes(
        item: LSPTypeHierarchyItem,
        uri: String,
        analysisResult: AnalysisResult
    ) -> [LSPTypeHierarchyItem] {
        var results: [LSPTypeHierarchyItem] = []
        let targetName = item.name

        for decl in analysisResult.ast.declarations {
            collectSubtypes(of: targetName, in: decl, uri: uri, into: &results)
        }

        return results
    }

    // MARK: - Helpers

    private static func collectSubtypes(
        of targetName: String,
        in decl: RDeclaration,
        uri: String,
        into results: inout [LSPTypeHierarchyItem]
    ) {
        switch decl {
        case .classDecl(let c):
            if c.superTypes.contains(where: { typeNodeName($0) == targetName }) {
                let range = sourceSpanToLSPRange(c.span)
                results.append(LSPTypeHierarchyItem(
                    name: c.name, kind: LSPSymbolKind.class_, uri: uri,
                    range: range, selectionRange: range
                ))
            }
            for member in c.members {
                collectSubtypes(of: targetName, in: member, uri: uri, into: &results)
            }

        case .interfaceDecl(let i):
            if i.superTypes.contains(where: { typeNodeName($0) == targetName }) {
                let range = sourceSpanToLSPRange(i.span)
                results.append(LSPTypeHierarchyItem(
                    name: i.name, kind: LSPSymbolKind.interface_, uri: uri,
                    range: range, selectionRange: range
                ))
            }

        case .objectDecl(let o):
            if o.superTypes.contains(where: { typeNodeName($0) == targetName }) {
                let range = sourceSpanToLSPRange(o.span)
                results.append(LSPTypeHierarchyItem(
                    name: o.name, kind: LSPSymbolKind.object_, uri: uri,
                    range: range, selectionRange: range
                ))
            }

        default:
            break
        }
    }

    private static func matchTypeDecl(
        _ decl: RDeclaration,
        name: String,
        uri: String
    ) -> LSPTypeHierarchyItem? {
        switch decl {
        case .classDecl(let c) where c.name == name:
            let range = sourceSpanToLSPRange(c.span)
            return LSPTypeHierarchyItem(name: c.name, kind: LSPSymbolKind.class_, uri: uri,
                                         range: range, selectionRange: range)
        case .interfaceDecl(let i) where i.name == name:
            let range = sourceSpanToLSPRange(i.span)
            return LSPTypeHierarchyItem(name: i.name, kind: LSPSymbolKind.interface_, uri: uri,
                                         range: range, selectionRange: range)
        case .enumDecl(let e) where e.name == name:
            let range = sourceSpanToLSPRange(e.span)
            return LSPTypeHierarchyItem(name: e.name, kind: LSPSymbolKind.enum_, uri: uri,
                                         range: range, selectionRange: range)
        case .objectDecl(let o) where o.name == name:
            let range = sourceSpanToLSPRange(o.span)
            return LSPTypeHierarchyItem(name: o.name, kind: LSPSymbolKind.object_, uri: uri,
                                         range: range, selectionRange: range)
        case .actorDecl(let a) where a.name == name:
            let range = sourceSpanToLSPRange(a.span)
            return LSPTypeHierarchyItem(name: a.name, kind: LSPSymbolKind.class_, uri: uri,
                                         range: range, selectionRange: range)
        case .classDecl(let c):
            for member in c.members {
                if let item = matchTypeDecl(member, name: name, uri: uri) { return item }
            }
            return nil
        default:
            return nil
        }
    }

    private static func findTypeItem(
        named name: String,
        in ast: SourceFile,
        uri: String
    ) -> LSPTypeHierarchyItem? {
        for decl in ast.declarations {
            if let item = matchTypeDecl(decl, name: name, uri: uri) {
                return item
            }
        }
        return nil
    }

    private static func typeNodeName(_ typeNode: TypeNode) -> String? {
        switch typeNode {
        case .simple(let name, _, _): return name
        case .qualified(_, let member, _): return member
        default: return nil
        }
    }
}
