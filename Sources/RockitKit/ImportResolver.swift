// ImportResolver.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation

/// Resolves import declarations by loading, parsing, and merging imported .rok files.
/// Uses the same flattening strategy as the Stage 1 self-hosting compiler.
public class ImportResolver {
    private let diagnostics: DiagnosticEngine
    private let sourceDir: String
    private let libPaths: [String]
    private var imported: Set<String> = []

    public init(sourceDir: String, libPaths: [String] = [], diagnostics: DiagnosticEngine) {
        self.sourceDir = sourceDir
        self.libPaths = libPaths
        self.diagnostics = diagnostics
    }

    /// Resolve all imports in the AST, returning a new SourceFile with merged declarations.
    public func resolve(_ ast: SourceFile) -> SourceFile {
        var allDeclarations = [Declaration]()

        for imp in ast.imports {
            resolveImport(imp, into: &allDeclarations)
        }

        allDeclarations.append(contentsOf: ast.declarations)

        return SourceFile(
            packageDecl: ast.packageDecl,
            imports: ast.imports,
            declarations: allDeclarations,
            span: ast.span
        )
    }

    private func resolveImport(_ imp: ImportDecl, into declarations: inout [Declaration]) {
        let relativePath = imp.path.joined(separator: "/") + ".rok"

        // Check if already imported (prevent cycles)
        if imported.contains(relativePath) { return }
        imported.insert(relativePath)

        // Search for the file
        guard let filePath = findFile(relativePath) else {
            diagnostics.warning("unresolved import '\(imp.path.joined(separator: "."))'", at: imp.span.start)
            return
        }

        guard let source = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            diagnostics.warning("could not read imported file: \(filePath)", at: imp.span.start)
            return
        }
        // Parse the imported file
        let importDiag = DiagnosticEngine()
        let lexer = Lexer(source: source, fileName: filePath, diagnostics: importDiag)
        let tokens = lexer.tokenize()
        let parser = Parser(tokens: tokens, diagnostics: importDiag)
        let importedAST = parser.parse()
        // Note: import parse errors are in importDiag, not forwarded

        // Recursively resolve imports in the imported file
        let importedDir = (filePath as NSString).deletingLastPathComponent
        let subResolver = ImportResolver(sourceDir: importedDir, libPaths: libPaths, diagnostics: diagnostics)
        subResolver.imported = self.imported
        let resolvedImportedAST = subResolver.resolve(importedAST)
        self.imported = subResolver.imported

        // Merge declarations
        declarations.append(contentsOf: resolvedImportedAST.declarations)
    }

    private func findFile(_ relativePath: String) -> String? {
        // 1. Relative to source directory
        let localPath = (sourceDir as NSString).appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: localPath) {
            return localPath
        }

        // 2. Search library paths
        for libPath in libPaths {
            let libFilePath = (libPath as NSString).appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: libFilePath) {
                return libFilePath
            }
        }

        return nil
    }
}
