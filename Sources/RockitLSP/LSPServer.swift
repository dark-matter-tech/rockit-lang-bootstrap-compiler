// LSPServer.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation
import RockitKit

/// The Rockit Language Server — main entry point for `rockit lsp`
public final class LSPServer {
    private let documentManager = DocumentManager()
    private let analysisEngine: AnalysisEngine
    private let input: FileHandle
    private let output: FileHandle
    private var workspaceRoot: String?

    public init() {
        self.analysisEngine = AnalysisEngine(documentManager: documentManager)
        self.input = FileHandle.standardInput
        self.output = FileHandle.standardOutput
    }

    /// Main run loop — reads JSON-RPC messages from stdin, dispatches, responds on stdout
    public func run() {
        log("Rockit LSP server starting (version 0.1.0)")

        while let message = JSONRPCProtocol.readMessage(from: input) {
            handleMessage(message)
        }

        log("Rockit LSP server shutting down")
    }

    // MARK: - Message Dispatch

    private func handleMessage(_ msg: JSONRPCMessage) {
        switch msg.method {

        // Lifecycle
        case "initialize":
            handleInitialize(msg)
        case "initialized":
            break // notification, no response
        case "shutdown":
            handleShutdown(msg)
        case "exit":
            exit(0)

        // Document Sync
        case "textDocument/didOpen":
            handleDidOpen(msg)
        case "textDocument/didChange":
            handleDidChange(msg)
        case "textDocument/didClose":
            handleDidClose(msg)
        case "textDocument/didSave":
            // Re-analyze on save
            if let uri = extractURI(msg.params) {
                analyzeAndPublishDiagnostics(uri: uri)
                // Run @Test functions and cache results for CodeLens
                if let source = documentManager.getText(uri) {
                    let filePath = uriToPath(uri)
                    CodeLensProvider.runTests(
                        source: source,
                        filePath: filePath,
                        uri: uri,
                        workspaceRoot: workspaceRoot
                    )
                }
            }

        // Language Features
        case "textDocument/hover":
            handleHover(msg)
        case "textDocument/completion":
            handleCompletion(msg)
        case "textDocument/definition":
            handleDefinition(msg)
        case "textDocument/documentSymbol":
            handleDocumentSymbol(msg)
        case "textDocument/signatureHelp":
            handleSignatureHelp(msg)
        case "textDocument/references":
            handleReferences(msg)
        case "textDocument/prepareRename":
            handlePrepareRename(msg)
        case "textDocument/rename":
            handleRename(msg)
        case "textDocument/semanticTokens/full":
            handleSemanticTokensFull(msg)
        case "textDocument/formatting":
            handleFormatting(msg)
        case "textDocument/inlayHint":
            handleInlayHint(msg)
        case "workspace/symbol":
            handleWorkspaceSymbol(msg)
        case "textDocument/codeAction":
            handleCodeAction(msg)
        case "textDocument/foldingRange":
            handleFoldingRange(msg)
        case "textDocument/documentHighlight":
            handleDocumentHighlight(msg)
        case "textDocument/selectionRange":
            handleSelectionRange(msg)
        case "textDocument/implementation":
            handleImplementation(msg)
        case "textDocument/typeDefinition":
            handleTypeDefinition(msg)
        case "textDocument/documentLink":
            handleDocumentLink(msg)
        case "textDocument/onTypeFormatting":
            handleOnTypeFormatting(msg)
        case "callHierarchy/incomingCalls":
            handleCallHierarchyIncoming(msg)
        case "callHierarchy/outgoingCalls":
            handleCallHierarchyOutgoing(msg)
        case "textDocument/prepareCallHierarchy":
            handlePrepareCallHierarchy(msg)
        case "textDocument/prepareTypeHierarchy":
            handlePrepareTypeHierarchy(msg)
        case "typeHierarchy/supertypes":
            handleTypeHierarchySupertypes(msg)
        case "typeHierarchy/subtypes":
            handleTypeHierarchySubtypes(msg)
        case "textDocument/rangeFormatting":
            handleRangeFormatting(msg)
        case "textDocument/codeLens":
            handleCodeLens(msg)

        default:
            if let id = msg.id {
                sendError(id: id, code: -32601, message: "Method not found: \(msg.method)")
            }
        }
    }

    // MARK: - Lifecycle

    private func handleInitialize(_ msg: JSONRPCMessage) {
        guard let id = msg.id else { return }

        // Extract workspace root from initialize params
        if let params = msg.params {
            if let rootUri = params["rootUri"] as? String {
                workspaceRoot = uriToPath(rootUri)
            } else if let rootPath = params["rootPath"] as? String {
                workspaceRoot = rootPath
            }
        }

        let capabilities: [String: Any] = [
            "textDocumentSync": [
                "openClose": true,
                "change": 2  // Incremental sync
            ] as [String: Any],
            "hoverProvider": true,
            "completionProvider": [
                "triggerCharacters": [".", ":"],
                "resolveProvider": false
            ] as [String: Any],
            "definitionProvider": true,
            "documentSymbolProvider": true,
            "signatureHelpProvider": [
                "triggerCharacters": ["(", ","]
            ] as [String: Any],
            "referencesProvider": true,
            "renameProvider": [
                "prepareProvider": true
            ] as [String: Any],
            "semanticTokensProvider": [
                "legend": [
                    "tokenTypes": LSPSemanticTokenType.legend,
                    "tokenModifiers": LSPSemanticTokenModifier.legend
                ] as [String: Any],
                "full": true
            ] as [String: Any],
            "documentFormattingProvider": true,
            "inlayHintProvider": true,
            "workspaceSymbolProvider": true,
            "codeActionProvider": [
                "codeActionKinds": ["quickfix", "refactor"]
            ] as [String: Any],
            "foldingRangeProvider": true,
            "documentHighlightProvider": true,
            "selectionRangeProvider": true,
            "implementationProvider": true,
            "typeDefinitionProvider": true,
            "documentLinkProvider": [
                "resolveProvider": false
            ] as [String: Any],
            "documentOnTypeFormattingProvider": [
                "firstTriggerCharacter": "\n",
                "moreTriggerCharacter": ["}", "{"]
            ] as [String: Any],
            "callHierarchyProvider": true,
            "typeHierarchyProvider": true,
            "documentRangeFormattingProvider": true,
            "codeLensProvider": [
                "resolveProvider": false
            ] as [String: Any]
        ]

        let result: [String: Any] = [
            "capabilities": capabilities,
            "serverInfo": [
                "name": "rockit-lsp",
                "version": "0.3.0"
            ] as [String: Any]
        ]

        sendResult(id: id, result: result)
        log("Initialized with capabilities (workspace: \(workspaceRoot ?? "none"))")
    }

    private func handleShutdown(_ msg: JSONRPCMessage) {
        guard let id = msg.id else { return }
        sendResult(id: id, result: NSNull())
        log("Shutdown requested")
    }

    // MARK: - Document Sync

    private func handleDidOpen(_ msg: JSONRPCMessage) {
        guard let params = msg.params,
              let textDocument = params["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let text = textDocument["text"] as? String else { return }

        let version = textDocument["version"] as? Int ?? 0
        documentManager.open(uri: uri, text: text, version: version)
        log("Opened: \(uriToPath(uri))")
        analyzeAndPublishDiagnostics(uri: uri)
    }

    private func handleDidChange(_ msg: JSONRPCMessage) {
        guard let params = msg.params,
              let textDocument = params["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let changes = params["contentChanges"] as? [[String: Any]] else { return }

        let version = textDocument["version"] as? Int ?? 0

        for change in changes {
            guard let text = change["text"] as? String else { continue }

            if let rangeJSON = change["range"] as? [String: Any],
               let range = LSPRange(json: rangeJSON) {
                // Incremental change
                documentManager.applyIncrementalChange(uri: uri, version: version, range: range, text: text)
            } else {
                // Full content replacement (fallback)
                documentManager.update(uri: uri, text: text, version: version)
            }
        }

        // Invalidate test results cache — tests re-run on next save
        CodeLensProvider.invalidateCache(uri: uri)

        analyzeAndPublishDiagnostics(uri: uri)
    }

    private func handleDidClose(_ msg: JSONRPCMessage) {
        guard let uri = extractURI(msg.params) else { return }
        documentManager.close(uri: uri)
        publishDiagnostics(uri: uri, diagnostics: [])
        log("Closed: \(uriToPath(uri))")
    }

    // MARK: - Language Features

    private func handleHover(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let (uri, position) = extractTextDocumentPosition(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: NSNull()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: uri) else {
            sendResult(id: id, result: NSNull())
            return
        }

        if let hover = HoverProvider.hover(at: position, uri: uri, analysisResult: result) {
            sendResult(id: id, result: hover.toJSON())
        } else {
            sendResult(id: id, result: NSNull())
        }
    }

    private func handleCompletion(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let (uri, position) = extractTextDocumentPosition(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: NSNull()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: uri),
              let text = documentManager.getText(uri) else {
            sendResult(id: id, result: NSNull())
            return
        }

        let items = CompletionProvider.complete(
            at: position,
            uri: uri,
            analysisResult: result,
            documentText: text
        )

        sendResult(id: id, result: items.map { $0.toJSON() })
    }

    private func handleDefinition(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let (uri, position) = extractTextDocumentPosition(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: NSNull()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: uri) else {
            sendResult(id: id, result: NSNull())
            return
        }

        if let location = DefinitionProvider.definition(at: position, uri: uri, analysisResult: result) {
            sendResult(id: id, result: location.toJSON())
        } else {
            sendResult(id: id, result: NSNull())
        }
    }

    private func handleDocumentSymbol(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let uri = extractURI(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: [Any]()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: uri) else {
            sendResult(id: id, result: [Any]())
            return
        }

        let symbols = DocumentSymbolProvider.symbols(for: result.ast)
        sendResult(id: id, result: symbols.map { $0.toJSON() })
    }

    private func handleSignatureHelp(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let (uri, position) = extractTextDocumentPosition(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: NSNull()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: uri),
              let text = documentManager.getText(uri) else {
            sendResult(id: id, result: NSNull())
            return
        }

        if let sigHelp = SignatureHelpProvider.signatureHelp(
            at: position,
            uri: uri,
            analysisResult: result,
            documentText: text
        ) {
            sendResult(id: id, result: sigHelp.toJSON())
        } else {
            sendResult(id: id, result: NSNull())
        }
    }

    // MARK: - Find References

    private func handleReferences(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let (uri, position) = extractTextDocumentPosition(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: [Any]()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: uri) else {
            sendResult(id: id, result: [Any]())
            return
        }

        let includeDecl = (msg.params?["context"] as? [String: Any])?["includeDeclaration"] as? Bool ?? true
        let locations = ReferencesProvider.references(
            at: position, uri: uri,
            analysisResult: result,
            includeDeclaration: includeDecl
        )
        sendResult(id: id, result: locations.map { $0.toJSON() })
    }

    // MARK: - Rename

    private func handlePrepareRename(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let (uri, position) = extractTextDocumentPosition(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: NSNull()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: uri) else {
            sendResult(id: id, result: NSNull())
            return
        }

        if let range = RenameProvider.prepareRename(at: position, uri: uri, analysisResult: result) {
            sendResult(id: id, result: range.toJSON())
        } else {
            sendResult(id: id, result: NSNull())
        }
    }

    private func handleRename(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let (uri, position) = extractTextDocumentPosition(msg.params),
              let newName = msg.params?["newName"] as? String else {
            if let id = msg.id { sendResult(id: id, result: NSNull()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: uri) else {
            sendResult(id: id, result: NSNull())
            return
        }

        if let edit = RenameProvider.rename(at: position, uri: uri, newName: newName, analysisResult: result) {
            sendResult(id: id, result: edit.toJSON())
        } else {
            sendResult(id: id, result: NSNull())
        }
    }

    // MARK: - Semantic Tokens

    private func handleSemanticTokensFull(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let uri = extractURI(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: ["data": [Int]()]) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: uri) else {
            sendResult(id: id, result: ["data": [Int]()])
            return
        }

        let data = SemanticTokensProvider.semanticTokens(for: result)
        sendResult(id: id, result: ["data": data])
    }

    // MARK: - Formatting

    private func handleFormatting(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let uri = extractURI(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: [Any]()) }
            return
        }

        guard let text = documentManager.getText(uri) else {
            sendResult(id: id, result: [Any]())
            return
        }

        let options = msg.params?["options"] as? [String: Any]
        let tabSize = options?["tabSize"] as? Int ?? 4
        let insertSpaces = options?["insertSpaces"] as? Bool ?? true

        let edits = FormattingProvider.format(text: text, tabSize: tabSize, insertSpaces: insertSpaces)
        sendResult(id: id, result: edits.map { $0.toJSON() })
    }

    // MARK: - Inlay Hints

    private func handleInlayHint(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let uri = extractURI(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: [Any]()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: uri) else {
            sendResult(id: id, result: [Any]())
            return
        }

        let range: LSPRange?
        if let rangeJSON = msg.params?["range"] as? [String: Any] {
            range = LSPRange(json: rangeJSON)
        } else {
            range = nil
        }

        let hints = InlayHintsProvider.inlayHints(for: result, uri: uri, range: range)
        sendResult(id: id, result: hints.map { $0.toJSON() })
    }

    // MARK: - Workspace Symbols

    private func handleWorkspaceSymbol(_ msg: JSONRPCMessage) {
        guard let id = msg.id else { return }

        let query = msg.params?["query"] as? String ?? ""
        let symbols = WorkspaceSymbolProvider.symbols(
            query: query,
            workspaceRoot: workspaceRoot,
            analysisEngine: analysisEngine,
            documentManager: documentManager
        )
        sendResult(id: id, result: symbols.map { $0.toJSON() })
    }

    // MARK: - Code Actions

    private func handleCodeAction(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let uri = extractURI(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: [Any]()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: uri),
              let text = documentManager.getText(uri) else {
            sendResult(id: id, result: [Any]())
            return
        }

        let range: LSPRange?
        if let rangeJSON = msg.params?["range"] as? [String: Any] {
            range = LSPRange(json: rangeJSON)
        } else {
            range = nil
        }

        let diagnostics = (msg.params?["context"] as? [String: Any])?["diagnostics"] as? [[String: Any]] ?? []

        let actions = CodeActionProvider.codeActions(
            uri: uri,
            range: range,
            diagnostics: diagnostics,
            analysisResult: result,
            documentText: text
        )
        sendResult(id: id, result: actions.map { $0.toJSON() })
    }

    // MARK: - Folding Ranges

    private func handleFoldingRange(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let uri = extractURI(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: [Any]()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: uri),
              let text = documentManager.getText(uri) else {
            sendResult(id: id, result: [Any]())
            return
        }

        let ranges = FoldingRangeProvider.foldingRanges(for: result, documentText: text)
        sendResult(id: id, result: ranges.map { $0.toJSON() })
    }

    // MARK: - Document Highlight

    private func handleDocumentHighlight(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let (uri, position) = extractTextDocumentPosition(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: [Any]()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: uri) else {
            sendResult(id: id, result: [Any]())
            return
        }

        let highlights = DocumentHighlightProvider.highlights(at: position, uri: uri, analysisResult: result)
        sendResult(id: id, result: highlights.map { $0.toJSON() })
    }

    // MARK: - Selection Range

    private func handleSelectionRange(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let uri = extractURI(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: [Any]()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: uri) else {
            sendResult(id: id, result: [Any]())
            return
        }

        let positions: [LSPPosition]
        if let positionsJSON = msg.params?["positions"] as? [[String: Any]] {
            positions = positionsJSON.compactMap { LSPPosition(json: $0) }
        } else {
            positions = []
        }

        let ranges = SelectionRangeProvider.selectionRanges(positions: positions, uri: uri, analysisResult: result)
        sendResult(id: id, result: ranges.map { $0.toJSON() })
    }

    // MARK: - Go to Implementation

    private func handleImplementation(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let (uri, position) = extractTextDocumentPosition(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: [Any]()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: uri) else {
            sendResult(id: id, result: [Any]())
            return
        }

        let locations = ImplementationProvider.implementations(at: position, uri: uri, analysisResult: result)
        sendResult(id: id, result: locations.map { $0.toJSON() })
    }

    // MARK: - Go to Type Definition

    private func handleTypeDefinition(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let (uri, position) = extractTextDocumentPosition(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: NSNull()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: uri) else {
            sendResult(id: id, result: NSNull())
            return
        }

        if let location = TypeDefinitionProvider.typeDefinition(at: position, uri: uri, analysisResult: result) {
            sendResult(id: id, result: location.toJSON())
        } else {
            sendResult(id: id, result: NSNull())
        }
    }

    // MARK: - Document Links

    private func handleDocumentLink(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let uri = extractURI(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: [Any]()) }
            return
        }

        guard let text = documentManager.getText(uri) else {
            sendResult(id: id, result: [Any]())
            return
        }

        let links = DocumentLinkProvider.documentLinks(
            documentText: text, uri: uri, workspaceRoot: workspaceRoot
        )
        sendResult(id: id, result: links.map { $0.toJSON() })
    }

    // MARK: - On Type Formatting

    private func handleOnTypeFormatting(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let (uri, position) = extractTextDocumentPosition(msg.params),
              let ch = msg.params?["ch"] as? String else {
            if let id = msg.id { sendResult(id: id, result: [Any]()) }
            return
        }

        guard let text = documentManager.getText(uri) else {
            sendResult(id: id, result: [Any]())
            return
        }

        let options = msg.params?["options"] as? [String: Any]
        let tabSize = options?["tabSize"] as? Int ?? 4
        let insertSpaces = options?["insertSpaces"] as? Bool ?? true

        let edits = OnTypeFormattingProvider.onTypeFormatting(
            uri: uri, position: position, character: ch,
            documentText: text, tabSize: tabSize, insertSpaces: insertSpaces
        )
        sendResult(id: id, result: edits.map { $0.toJSON() })
    }

    // MARK: - Call Hierarchy

    private func handlePrepareCallHierarchy(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let (uri, position) = extractTextDocumentPosition(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: [Any]()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: uri) else {
            sendResult(id: id, result: [Any]())
            return
        }

        let items = CallHierarchyProvider.prepare(at: position, uri: uri, analysisResult: result)
        sendResult(id: id, result: items.map { $0.toJSON() })
    }

    private func handleCallHierarchyIncoming(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let params = msg.params,
              let itemJSON = params["item"] as? [String: Any],
              let item = LSPCallHierarchyItem(json: itemJSON) else {
            if let id = msg.id { sendResult(id: id, result: [Any]()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: item.uri) else {
            sendResult(id: id, result: [Any]())
            return
        }

        let calls = CallHierarchyProvider.incomingCalls(item: item, uri: item.uri, analysisResult: result)
        sendResult(id: id, result: calls.map { $0.toJSON() })
    }

    private func handleCallHierarchyOutgoing(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let params = msg.params,
              let itemJSON = params["item"] as? [String: Any],
              let item = LSPCallHierarchyItem(json: itemJSON) else {
            if let id = msg.id { sendResult(id: id, result: [Any]()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: item.uri) else {
            sendResult(id: id, result: [Any]())
            return
        }

        let calls = CallHierarchyProvider.outgoingCalls(item: item, uri: item.uri, analysisResult: result)
        sendResult(id: id, result: calls.map { $0.toJSON() })
    }

    // MARK: - Type Hierarchy

    private func handlePrepareTypeHierarchy(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let (uri, position) = extractTextDocumentPosition(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: [Any]()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: uri) else {
            sendResult(id: id, result: [Any]())
            return
        }

        let items = TypeHierarchyProvider.prepare(at: position, uri: uri, analysisResult: result)
        sendResult(id: id, result: items.map { $0.toJSON() })
    }

    private func handleTypeHierarchySupertypes(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let params = msg.params,
              let itemJSON = params["item"] as? [String: Any],
              let item = LSPTypeHierarchyItem(json: itemJSON) else {
            if let id = msg.id { sendResult(id: id, result: [Any]()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: item.uri) else {
            sendResult(id: id, result: [Any]())
            return
        }

        let supertypes = TypeHierarchyProvider.supertypes(item: item, uri: item.uri, analysisResult: result)
        sendResult(id: id, result: supertypes.map { $0.toJSON() })
    }

    private func handleTypeHierarchySubtypes(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let params = msg.params,
              let itemJSON = params["item"] as? [String: Any],
              let item = LSPTypeHierarchyItem(json: itemJSON) else {
            if let id = msg.id { sendResult(id: id, result: [Any]()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: item.uri) else {
            sendResult(id: id, result: [Any]())
            return
        }

        let subtypes = TypeHierarchyProvider.subtypes(item: item, uri: item.uri, analysisResult: result)
        sendResult(id: id, result: subtypes.map { $0.toJSON() })
    }

    // MARK: - Code Lens

    private func handleCodeLens(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let uri = extractURI(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: [Any]()) }
            return
        }

        guard let result = analysisEngine.getOrAnalyze(uri: uri),
              let source = documentManager.getText(uri) else {
            sendResult(id: id, result: [Any]())
            return
        }

        let filePath = uriToPath(uri)
        let lenses = CodeLensProvider.codeLenses(
            for: result, uri: uri,
            source: source, filePath: filePath,
            workspaceRoot: workspaceRoot
        )
        sendResult(id: id, result: lenses.map { $0.toJSON() })
    }

    // MARK: - Range Formatting

    private func handleRangeFormatting(_ msg: JSONRPCMessage) {
        guard let id = msg.id,
              let uri = extractURI(msg.params) else {
            if let id = msg.id { sendResult(id: id, result: [Any]()) }
            return
        }

        guard let text = documentManager.getText(uri),
              let rangeJSON = msg.params?["range"] as? [String: Any],
              let range = LSPRange(json: rangeJSON) else {
            if let id = msg.id { sendResult(id: id, result: [Any]()) }
            return
        }

        let options = msg.params?["options"] as? [String: Any]
        let tabSize = options?["tabSize"] as? Int ?? 4
        let insertSpaces = options?["insertSpaces"] as? Bool ?? true

        let edits = RangeFormattingProvider.formatRange(
            text: text, range: range, tabSize: tabSize, insertSpaces: insertSpaces
        )
        sendResult(id: id, result: edits.map { $0.toJSON() })
    }

    // MARK: - Helpers

    private func analyzeAndPublishDiagnostics(uri: String) {
        guard let result = analysisEngine.analyze(uri: uri) else { return }
        let lspDiags = DiagnosticsProvider.convert(result.diagnostics, uri: uri)
        publishDiagnostics(uri: uri, diagnostics: lspDiags)
    }

    private func publishDiagnostics(uri: String, diagnostics: [LSPDiagnostic]) {
        let params: [String: Any] = [
            "uri": uri,
            "diagnostics": diagnostics.map { $0.toJSON() }
        ]
        JSONRPCProtocol.writeNotification(method: "textDocument/publishDiagnostics", params: params, to: output)
    }

    private func extractTextDocumentPosition(_ params: [String: Any]?) -> (String, LSPPosition)? {
        guard let params = params,
              let textDocument = params["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = params["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int else { return nil }
        return (uri, LSPPosition(line: line, character: character))
    }

    private func extractURI(_ params: [String: Any]?) -> String? {
        guard let params = params,
              let textDocument = params["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String else { return nil }
        return uri
    }

    private func sendResult(id: JSONRPCId, result: Any) {
        JSONRPCProtocol.writeResponse(id: id, result: result, error: nil, to: output)
    }

    private func sendError(id: JSONRPCId, code: Int, message: String) {
        JSONRPCProtocol.writeResponse(id: id, result: nil, error: JSONRPCError(code: code, message: message), to: output)
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write("[\(timestamp)] rockit-lsp: \(message)\n".data(using: .utf8)!)
    }
}
