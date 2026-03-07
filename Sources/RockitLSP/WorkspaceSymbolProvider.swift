// WorkspaceSymbolProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation
import RockitKit

/// Provides workspace-wide symbol search
public final class WorkspaceSymbolProvider {

    public static func symbols(
        query: String,
        workspaceRoot: String?,
        analysisEngine: AnalysisEngine,
        documentManager: DocumentManager
    ) -> [LSPSymbolInformation] {
        var results: [LSPSymbolInformation] = []

        guard let root = workspaceRoot else { return results }

        let rokFiles = findRokFiles(in: root)

        for filePath in rokFiles {
            let uri = pathToURI(filePath)

            let ast: SourceFile?
            if let cachedResult = analysisEngine.getOrAnalyze(uri: uri) {
                ast = cachedResult.ast
            } else {
                ast = quickParse(filePath: filePath)
            }

            guard let sourceFile = ast else { continue }

            for decl in sourceFile.declarations {
                collectSymbols(from: decl, uri: uri, query: query,
                              containerName: nil, into: &results)
            }
        }

        return results
    }

    // MARK: - File Discovery

    private static func findRokFiles(in root: String) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [String] = []
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "rok" {
                files.append(url.path)
            }
        }
        return files
    }

    private static func quickParse(filePath: String) -> SourceFile? {
        guard let text = try? String(contentsOfFile: filePath, encoding: .utf8) else { return nil }
        let diags = DiagnosticEngine()
        let lexer = Lexer(source: text, fileName: filePath, diagnostics: diags)
        let tokens = lexer.tokenize()
        let parser = Parser(tokens: tokens, diagnostics: diags)
        return parser.parse()
    }

    // MARK: - Symbol Collection

    private static func collectSymbols(
        from decl: RDeclaration,
        uri: String,
        query: String,
        containerName: String?,
        into results: inout [LSPSymbolInformation]
    ) {
        let name: String
        let kind: Int
        let span: SourceSpan

        switch decl {
        case .function(let f):
            name = f.name; kind = LSPSymbolKind.function_; span = f.span
        case .property(let p):
            name = p.name; kind = p.isVal ? LSPSymbolKind.constant : LSPSymbolKind.variable; span = p.span
        case .classDecl(let c):
            name = c.name; kind = LSPSymbolKind.class_; span = c.span
            // Recurse into members
            for member in c.members {
                collectSymbols(from: member, uri: uri, query: query, containerName: c.name, into: &results)
            }
        case .interfaceDecl(let i):
            name = i.name; kind = LSPSymbolKind.interface_; span = i.span
            for member in i.members {
                collectSymbols(from: member, uri: uri, query: query, containerName: i.name, into: &results)
            }
        case .enumDecl(let e):
            name = e.name; kind = LSPSymbolKind.enum_; span = e.span
            for member in e.members {
                collectSymbols(from: member, uri: uri, query: query, containerName: e.name, into: &results)
            }
        case .objectDecl(let o):
            name = o.name; kind = LSPSymbolKind.object_; span = o.span
            for member in o.members {
                collectSymbols(from: member, uri: uri, query: query, containerName: o.name, into: &results)
            }
        case .actorDecl(let a):
            name = a.name; kind = LSPSymbolKind.class_; span = a.span
            for member in a.members {
                collectSymbols(from: member, uri: uri, query: query, containerName: a.name, into: &results)
            }
        case .viewDecl(let v):
            name = v.name; kind = LSPSymbolKind.class_; span = v.span
        case .navigationDecl(let n):
            name = n.name; kind = LSPSymbolKind.module_; span = n.span
        case .themeDecl(let t):
            name = t.name; kind = LSPSymbolKind.module_; span = t.span
        case .typeAlias(let ta):
            name = ta.name; kind = LSPSymbolKind.typeParameter; span = ta.span
        }

        // Filter by query
        if !query.isEmpty && !name.lowercased().contains(query.lowercased()) {
            return
        }

        let location = LSPLocation(uri: uri, range: sourceSpanToLSPRange(span))
        results.append(LSPSymbolInformation(
            name: name,
            kind: kind,
            location: location,
            containerName: containerName
        ))
    }
}
