// DocumentLinkProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation
import RockitKit

/// Makes import statements clickable — links to the imported file
public final class DocumentLinkProvider {

    public static func documentLinks(
        documentText: String,
        uri: String,
        workspaceRoot: String?
    ) -> [LSPDocumentLink] {
        var links: [LSPDocumentLink] = []
        let lines = documentText.split(separator: "\n", omittingEmptySubsequences: false)

        for (lineIdx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Match "import <package>" statements
            if trimmed.hasPrefix("import ") {
                let importName = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                guard !importName.isEmpty else { continue }

                // Calculate the range of the import path (after "import ")
                let importStart = line.distance(from: line.startIndex,
                                                 to: line.range(of: "import ")!.upperBound)
                let importEnd = importStart + importName.count

                let range = LSPRange(
                    start: LSPPosition(line: lineIdx, character: importStart),
                    end: LSPPosition(line: lineIdx, character: importEnd)
                )

                // Try to resolve the import to a file
                if let target = resolveImport(importName, fromURI: uri, workspaceRoot: workspaceRoot) {
                    links.append(LSPDocumentLink(range: range, target: target))
                }
            }
        }

        return links
    }

    // MARK: - Import Resolution

    private static func resolveImport(
        _ importName: String,
        fromURI: String,
        workspaceRoot: String?
    ) -> String? {
        let fm = FileManager.default

        // Convert dot-separated import to path: "foo.bar" → "foo/bar.rok"
        let pathFromImport = importName.replacingOccurrences(of: ".", with: "/") + ".rok"

        // Check relative to the current file's directory
        let currentDir = (uriToPath(fromURI) as NSString).deletingLastPathComponent
        let relativePath = (currentDir as NSString).appendingPathComponent(pathFromImport)
        if fm.fileExists(atPath: relativePath) {
            return pathToURI(relativePath)
        }

        // Check relative to workspace root
        if let root = workspaceRoot {
            let rootPath = (root as NSString).appendingPathComponent(pathFromImport)
            if fm.fileExists(atPath: rootPath) {
                return pathToURI(rootPath)
            }

            // Check in src/ subdirectory
            let srcPath = (root as NSString).appendingPathComponent("src/" + pathFromImport)
            if fm.fileExists(atPath: srcPath) {
                return pathToURI(srcPath)
            }
        }

        return nil
    }
}
