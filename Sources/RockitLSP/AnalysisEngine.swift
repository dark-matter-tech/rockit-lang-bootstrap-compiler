// AnalysisEngine.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation
import RockitKit

/// Result of analyzing a document
public struct AnalysisResult {
    public let tokens: [Token]
    public let ast: SourceFile
    public let typeCheckResult: TypeCheckResult
    public let diagnostics: [Diagnostic]
}

/// Drives the compiler pipeline for LSP analysis
public final class AnalysisEngine {
    private let documentManager: DocumentManager

    public init(documentManager: DocumentManager) {
        self.documentManager = documentManager
    }

    /// Run the full compiler frontend on a document and cache results.
    /// Returns nil if the document is not open.
    public func analyze(uri: String) -> AnalysisResult? {
        guard let text = documentManager.getText(uri) else { return nil }
        let path = uriToPath(uri)

        let diagnosticEngine = DiagnosticEngine()

        // Phase 1: Lex
        let lexer = Lexer(source: text, fileName: path, diagnostics: diagnosticEngine)
        let tokens = lexer.tokenize()

        // Phase 2: Parse
        let parser = Parser(tokens: tokens, diagnostics: diagnosticEngine)
        let parsedAst = parser.parse()

        // Phase 2.5: Resolve imports (load stdlib modules)
        let sourceDir = (path as NSString).deletingLastPathComponent
        let stdlibPaths = findStdlibDir(sourceFilePath: path).map { [$0] } ?? []
        let importResolver = ImportResolver(sourceDir: sourceDir, libPaths: stdlibPaths, diagnostics: diagnosticEngine)
        let ast = importResolver.resolve(parsedAst)

        // Phase 3: Type check
        let checker = TypeChecker(ast: ast, diagnostics: diagnosticEngine)
        let typeResult = checker.check()

        let result = AnalysisResult(
            tokens: tokens,
            ast: ast,
            typeCheckResult: typeResult,
            diagnostics: diagnosticEngine.diagnostics
        )

        // Cache for subsequent queries (hover, completion, etc.)
        documentManager.setCachedAnalysis(
            uri: uri,
            tokens: tokens,
            ast: ast,
            result: typeResult,
            diagnostics: diagnosticEngine.diagnostics
        )

        return result
    }

    /// Get cached analysis or re-analyze
    public func getOrAnalyze(uri: String) -> AnalysisResult? {
        if let doc = documentManager.get(uri),
           let tokens = doc.tokens,
           let ast = doc.ast,
           let result = doc.typeCheckResult {
            return AnalysisResult(
                tokens: tokens,
                ast: ast,
                typeCheckResult: result,
                diagnostics: doc.cachedDiagnostics
            )
        }
        return analyze(uri: uri)
    }

    /// Find the stdlib directory for import resolution.
    /// Walks up from the source file's directory to find Stage1/stdlib.
    private func findStdlibDir(sourceFilePath: String) -> String? {
        let fm = FileManager.default

        // 1. ROCKIT_STDLIB_DIR environment variable
        if let envDir = ProcessInfo.processInfo.environment["ROCKIT_STDLIB_DIR"],
           fm.fileExists(atPath: envDir) {
            return envDir
        }

        // 2. Walk up from the source file's directory to find Stage1/stdlib
        var dir = (sourceFilePath as NSString).deletingLastPathComponent
        while dir != "/" && !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent("Stage1/stdlib")
            if fm.fileExists(atPath: (candidate as NSString).appendingPathComponent("rockit")) {
                return candidate
            }
            dir = (dir as NSString).deletingLastPathComponent
        }

        // 3. Relative to the executable (installed: share/rockit/stdlib)
        let execPath = CommandLine.arguments[0]
        let execDir = (execPath as NSString).deletingLastPathComponent
        let installedStdlib = (execDir as NSString).appendingPathComponent("../share/rockit/stdlib")
        if fm.fileExists(atPath: (installedStdlib as NSString).appendingPathComponent("rockit")) {
            return installedStdlib
        }

        // 4. Common install locations
        let home = NSHomeDirectory()
        let locations = [
            (home as NSString).appendingPathComponent(".local/share/rockit/stdlib"),
            "/usr/local/share/rockit/stdlib",
        ]
        for loc in locations {
            if fm.fileExists(atPath: (loc as NSString).appendingPathComponent("rockit")) {
                return loc
            }
        }

        return nil
    }
}
