// DocumentSymbolProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import RockitKit

/// Implements textDocument/documentSymbol (file outline / breadcrumbs)
public final class DocumentSymbolProvider {

    /// Generate document symbols for the file outline
    public static func symbols(for ast: SourceFile) -> [LSPDocumentSymbol] {
        return ast.declarations.compactMap { declToSymbol($0) }
    }

    // MARK: - Private

    private static func declToSymbol(_ decl: Declaration) -> LSPDocumentSymbol? {
        switch decl {
        case .function(let f):
            let params = f.parameters.map { p -> String in
                var s = p.name
                if let t = p.type { s += ": \(t.summary)" }
                return s
            }
            let retStr = f.returnType.map { " : \($0.summary)" } ?? ""
            let detail = "(\(params.joined(separator: ", ")))\(retStr)"
            let range = sourceSpanToLSPRange(f.span)
            return LSPDocumentSymbol(
                name: f.name,
                detail: detail,
                kind: LSPSymbolKind.function_,
                range: range,
                selectionRange: range,
                children: nil
            )

        case .property(let p):
            let detail = p.type?.summary
            let range = sourceSpanToLSPRange(p.span)
            return LSPDocumentSymbol(
                name: p.name,
                detail: detail,
                kind: p.isVal ? LSPSymbolKind.constant : LSPSymbolKind.variable,
                range: range,
                selectionRange: range,
                children: nil
            )

        case .classDecl(let c):
            let children = c.members.compactMap { declToSymbol($0) }
            let prefix = c.modifiers.contains(.data) ? "data " :
                         c.modifiers.contains(.sealed) ? "sealed " :
                         c.modifiers.contains(.abstract) ? "abstract " : ""
            let range = sourceSpanToLSPRange(c.span)
            return LSPDocumentSymbol(
                name: c.name,
                detail: "\(prefix)class",
                kind: LSPSymbolKind.class_,
                range: range,
                selectionRange: range,
                children: children.isEmpty ? nil : children
            )

        case .interfaceDecl(let i):
            let children = i.members.compactMap { declToSymbol($0) }
            let range = sourceSpanToLSPRange(i.span)
            return LSPDocumentSymbol(
                name: i.name,
                detail: "interface",
                kind: LSPSymbolKind.interface_,
                range: range,
                selectionRange: range,
                children: children.isEmpty ? nil : children
            )

        case .enumDecl(let e):
            var children: [LSPDocumentSymbol] = []
            for entry in e.entries {
                let entryRange = sourceSpanToLSPRange(entry.span)
                children.append(LSPDocumentSymbol(
                    name: entry.name,
                    detail: nil,
                    kind: LSPSymbolKind.enumMember,
                    range: entryRange,
                    selectionRange: entryRange,
                    children: nil
                ))
            }
            children.append(contentsOf: e.members.compactMap { declToSymbol($0) })
            let range = sourceSpanToLSPRange(e.span)
            return LSPDocumentSymbol(
                name: e.name,
                detail: "enum class",
                kind: LSPSymbolKind.enum_,
                range: range,
                selectionRange: range,
                children: children.isEmpty ? nil : children
            )

        case .objectDecl(let o):
            let children = o.members.compactMap { declToSymbol($0) }
            let detail = o.isCompanion ? "companion object" : "object"
            let range = sourceSpanToLSPRange(o.span)
            return LSPDocumentSymbol(
                name: o.name,
                detail: detail,
                kind: LSPSymbolKind.object_,
                range: range,
                selectionRange: range,
                children: children.isEmpty ? nil : children
            )

        case .actorDecl(let a):
            let children = a.members.compactMap { declToSymbol($0) }
            let range = sourceSpanToLSPRange(a.span)
            return LSPDocumentSymbol(
                name: a.name,
                detail: "actor",
                kind: LSPSymbolKind.class_,
                range: range,
                selectionRange: range,
                children: children.isEmpty ? nil : children
            )

        case .viewDecl(let v):
            let params = v.parameters.map { p -> String in
                var s = p.name
                if let t = p.type { s += ": \(t.summary)" }
                return s
            }
            let range = sourceSpanToLSPRange(v.span)
            return LSPDocumentSymbol(
                name: v.name,
                detail: "view(\(params.joined(separator: ", ")))",
                kind: LSPSymbolKind.class_,
                range: range,
                selectionRange: range,
                children: nil
            )

        case .navigationDecl(let n):
            let range = sourceSpanToLSPRange(n.span)
            return LSPDocumentSymbol(
                name: n.name,
                detail: "navigation",
                kind: LSPSymbolKind.module_,
                range: range,
                selectionRange: range,
                children: nil
            )

        case .themeDecl(let t):
            let range = sourceSpanToLSPRange(t.span)
            return LSPDocumentSymbol(
                name: t.name,
                detail: "theme",
                kind: LSPSymbolKind.module_,
                range: range,
                selectionRange: range,
                children: nil
            )

        case .typeAlias(let ta):
            let range = sourceSpanToLSPRange(ta.span)
            return LSPDocumentSymbol(
                name: ta.name,
                detail: "= \(ta.type.summary)",
                kind: LSPSymbolKind.typeParameter,
                range: range,
                selectionRange: range,
                children: nil
            )
        }
    }
}
