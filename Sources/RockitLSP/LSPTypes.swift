// LSPTypes.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation
import RockitKit

// MARK: - LSP Position / Range / Location

/// 0-indexed line and character (UTF-16 code units per LSP spec)
public struct LSPPosition {
    public let line: Int
    public let character: Int

    func toJSON() -> [String: Any] {
        return ["line": line, "character": character]
    }

    init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    init?(json: [String: Any]) {
        guard let line = json["line"] as? Int,
              let character = json["character"] as? Int else { return nil }
        self.line = line
        self.character = character
    }
}

/// A range in a document
public struct LSPRange {
    public let start: LSPPosition
    public let end: LSPPosition

    func toJSON() -> [String: Any] {
        return ["start": start.toJSON(), "end": end.toJSON()]
    }

    init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }

    init?(json: [String: Any]) {
        guard let startJSON = json["start"] as? [String: Any],
              let endJSON = json["end"] as? [String: Any],
              let start = LSPPosition(json: startJSON),
              let end = LSPPosition(json: endJSON) else { return nil }
        self.start = start
        self.end = end
    }
}

/// A location in a document (URI + range)
public struct LSPLocation {
    public let uri: String
    public let range: LSPRange

    func toJSON() -> [String: Any] {
        return ["uri": uri, "range": range.toJSON()]
    }
}

// MARK: - LSP Diagnostic

public struct LSPDiagnostic {
    public let range: LSPRange
    public let severity: Int  // 1=Error, 2=Warning, 3=Information, 4=Hint
    public let message: String
    public let source: String

    func toJSON() -> [String: Any] {
        return [
            "range": range.toJSON(),
            "severity": severity,
            "message": message,
            "source": source
        ]
    }
}

// MARK: - LSP Completion

public struct LSPCompletionItem {
    public let label: String
    public let kind: Int
    public let detail: String?
    public let insertText: String?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "label": label,
            "kind": kind
        ]
        if let detail = detail { json["detail"] = detail }
        if let insertText = insertText { json["insertText"] = insertText }
        return json
    }
}

// MARK: - LSP Hover

public struct LSPMarkupContent {
    public let kind: String  // "markdown" or "plaintext"
    public let value: String

    func toJSON() -> [String: Any] {
        return ["kind": kind, "value": value]
    }
}

public struct LSPHover {
    public let contents: LSPMarkupContent
    public let range: LSPRange?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = ["contents": contents.toJSON()]
        if let range = range { json["range"] = range.toJSON() }
        return json
    }
}

// MARK: - LSP Document Symbol

public struct LSPDocumentSymbol {
    public let name: String
    public let detail: String?
    public let kind: Int
    public let range: LSPRange
    public let selectionRange: LSPRange
    public let children: [LSPDocumentSymbol]?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "name": name,
            "kind": kind,
            "range": range.toJSON(),
            "selectionRange": selectionRange.toJSON()
        ]
        if let detail = detail { json["detail"] = detail }
        if let children = children {
            json["children"] = children.map { $0.toJSON() }
        }
        return json
    }
}

// MARK: - LSP Signature Help

public struct LSPParameterInformation {
    public let label: String

    func toJSON() -> [String: Any] {
        return ["label": label]
    }
}

public struct LSPSignatureInformation {
    public let label: String
    public let parameters: [LSPParameterInformation]

    func toJSON() -> [String: Any] {
        return [
            "label": label,
            "parameters": parameters.map { $0.toJSON() }
        ]
    }
}

public struct LSPSignatureHelp {
    public let signatures: [LSPSignatureInformation]
    public let activeSignature: Int
    public let activeParameter: Int

    func toJSON() -> [String: Any] {
        return [
            "signatures": signatures.map { $0.toJSON() },
            "activeSignature": activeSignature,
            "activeParameter": activeParameter
        ]
    }
}

// MARK: - LSP Constants

public enum LSPSymbolKind {
    public static let file = 1
    public static let module_ = 2
    public static let namespace = 3
    public static let class_ = 5
    public static let method = 6
    public static let property = 7
    public static let field = 8
    public static let constructor = 9
    public static let enum_ = 10
    public static let interface_ = 11
    public static let function_ = 12
    public static let variable = 13
    public static let constant = 14
    public static let object_ = 19
    public static let enumMember = 22
    public static let typeParameter = 26
}

public enum LSPCompletionItemKind {
    public static let text = 1
    public static let method = 2
    public static let function_ = 3
    public static let constructor = 4
    public static let field = 5
    public static let variable = 6
    public static let class_ = 7
    public static let interface_ = 8
    public static let module_ = 9
    public static let property = 10
    public static let keyword = 14
    public static let snippet = 15
    public static let enumMember = 20
    public static let constant = 21
    public static let struct_ = 22
    public static let event = 23
    public static let typeParameter = 25
}

// MARK: - LSP Text Edit

public struct LSPTextEdit {
    public let range: LSPRange
    public let newText: String

    func toJSON() -> [String: Any] {
        return ["range": range.toJSON(), "newText": newText]
    }
}

// MARK: - LSP Workspace Edit

public struct LSPWorkspaceEdit {
    public let changes: [String: [LSPTextEdit]]

    func toJSON() -> [String: Any] {
        var changesJSON: [String: Any] = [:]
        for (uri, edits) in changes {
            changesJSON[uri] = edits.map { $0.toJSON() }
        }
        return ["changes": changesJSON]
    }
}

// MARK: - LSP Inlay Hint

public struct LSPInlayHint {
    public let position: LSPPosition
    public let label: String
    public let kind: Int  // 1 = Type, 2 = Parameter
    public let paddingLeft: Bool
    public let paddingRight: Bool

    func toJSON() -> [String: Any] {
        return [
            "position": position.toJSON(),
            "label": label,
            "kind": kind,
            "paddingLeft": paddingLeft,
            "paddingRight": paddingRight
        ]
    }
}

// MARK: - LSP Symbol Information (flat, for workspace symbols)

public struct LSPSymbolInformation {
    public let name: String
    public let kind: Int
    public let location: LSPLocation
    public let containerName: String?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "name": name,
            "kind": kind,
            "location": location.toJSON()
        ]
        if let container = containerName { json["containerName"] = container }
        return json
    }
}

// MARK: - LSP Code Action

public struct LSPCodeAction {
    public let title: String
    public let kind: String
    public let diagnostics: [LSPDiagnostic]?
    public let edit: LSPWorkspaceEdit?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "title": title,
            "kind": kind
        ]
        if let diagnostics = diagnostics {
            json["diagnostics"] = diagnostics.map { $0.toJSON() }
        }
        if let edit = edit {
            json["edit"] = edit.toJSON()
        }
        return json
    }
}

// MARK: - LSP Semantic Token Types

public enum LSPSemanticTokenType: Int, CaseIterable {
    case namespace = 0
    case type = 1
    case class_ = 2
    case enum_ = 3
    case interface_ = 4
    case struct_ = 5
    case typeParameter = 6
    case parameter = 7
    case variable = 8
    case property = 9
    case enumMember = 10
    case function_ = 11
    case method = 12
    case keyword = 13
    case comment = 14
    case string = 15
    case number = 16
    case operator_ = 17

    public static var legend: [String] {
        return allCases.map { $0.tokenName }
    }

    public var tokenName: String {
        switch self {
        case .namespace: return "namespace"
        case .type: return "type"
        case .class_: return "class"
        case .enum_: return "enum"
        case .interface_: return "interface"
        case .struct_: return "struct"
        case .typeParameter: return "typeParameter"
        case .parameter: return "parameter"
        case .variable: return "variable"
        case .property: return "property"
        case .enumMember: return "enumMember"
        case .function_: return "function"
        case .method: return "method"
        case .keyword: return "keyword"
        case .comment: return "comment"
        case .string: return "string"
        case .number: return "number"
        case .operator_: return "operator"
        }
    }
}

public enum LSPSemanticTokenModifier: Int, CaseIterable {
    case declaration = 0
    case definition = 1
    case readonly = 2
    case static_ = 3

    public static var legend: [String] {
        return allCases.map { $0.modifierName }
    }

    public var modifierName: String {
        switch self {
        case .declaration: return "declaration"
        case .definition: return "definition"
        case .readonly: return "readonly"
        case .static_: return "static"
        }
    }
}

// MARK: - LSP Folding Range

public struct LSPFoldingRange {
    public let startLine: Int
    public let startCharacter: Int?
    public let endLine: Int
    public let endCharacter: Int?
    public let kind: String?  // "comment", "imports", "region"

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "startLine": startLine,
            "endLine": endLine
        ]
        if let sc = startCharacter { json["startCharacter"] = sc }
        if let ec = endCharacter { json["endCharacter"] = ec }
        if let kind = kind { json["kind"] = kind }
        return json
    }
}

// MARK: - LSP Document Highlight

public struct LSPDocumentHighlight {
    public let range: LSPRange
    public let kind: Int  // 1 = Text, 2 = Read, 3 = Write

    func toJSON() -> [String: Any] {
        return [
            "range": range.toJSON(),
            "kind": kind
        ]
    }
}

// MARK: - LSP Selection Range

public class LSPSelectionRange {
    public let range: LSPRange
    public let parent: LSPSelectionRange?

    public init(range: LSPRange, parent: LSPSelectionRange?) {
        self.range = range
        self.parent = parent
    }

    func toJSON() -> [String: Any] {
        var json: [String: Any] = ["range": range.toJSON()]
        if let parent = parent {
            json["parent"] = parent.toJSON()
        }
        return json
    }
}

// MARK: - LSP Call Hierarchy

public struct LSPCallHierarchyItem {
    public let name: String
    public let kind: Int
    public let uri: String
    public let range: LSPRange
    public let selectionRange: LSPRange

    func toJSON() -> [String: Any] {
        return [
            "name": name,
            "kind": kind,
            "uri": uri,
            "range": range.toJSON(),
            "selectionRange": selectionRange.toJSON()
        ]
    }

    init(name: String, kind: Int, uri: String, range: LSPRange, selectionRange: LSPRange) {
        self.name = name
        self.kind = kind
        self.uri = uri
        self.range = range
        self.selectionRange = selectionRange
    }

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String,
              let kind = json["kind"] as? Int,
              let uri = json["uri"] as? String,
              let rangeJSON = json["range"] as? [String: Any],
              let range = LSPRange(json: rangeJSON),
              let selRangeJSON = json["selectionRange"] as? [String: Any],
              let selRange = LSPRange(json: selRangeJSON) else { return nil }
        self.name = name
        self.kind = kind
        self.uri = uri
        self.range = range
        self.selectionRange = selRange
    }
}

public struct LSPCallHierarchyIncomingCall {
    public let from: LSPCallHierarchyItem
    public let fromRanges: [LSPRange]

    func toJSON() -> [String: Any] {
        return [
            "from": from.toJSON(),
            "fromRanges": fromRanges.map { $0.toJSON() }
        ]
    }
}

public struct LSPCallHierarchyOutgoingCall {
    public let to: LSPCallHierarchyItem
    public let fromRanges: [LSPRange]

    func toJSON() -> [String: Any] {
        return [
            "to": to.toJSON(),
            "fromRanges": fromRanges.map { $0.toJSON() }
        ]
    }
}

// MARK: - LSP Type Hierarchy

public struct LSPTypeHierarchyItem {
    public let name: String
    public let kind: Int
    public let uri: String
    public let range: LSPRange
    public let selectionRange: LSPRange

    func toJSON() -> [String: Any] {
        return [
            "name": name,
            "kind": kind,
            "uri": uri,
            "range": range.toJSON(),
            "selectionRange": selectionRange.toJSON()
        ]
    }

    init(name: String, kind: Int, uri: String, range: LSPRange, selectionRange: LSPRange) {
        self.name = name
        self.kind = kind
        self.uri = uri
        self.range = range
        self.selectionRange = selectionRange
    }

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String,
              let kind = json["kind"] as? Int,
              let uri = json["uri"] as? String,
              let rangeJSON = json["range"] as? [String: Any],
              let range = LSPRange(json: rangeJSON),
              let selRangeJSON = json["selectionRange"] as? [String: Any],
              let selRange = LSPRange(json: selRangeJSON) else { return nil }
        self.name = name
        self.kind = kind
        self.uri = uri
        self.range = range
        self.selectionRange = selRange
    }
}

// MARK: - LSP Document Link

public struct LSPDocumentLink {
    public let range: LSPRange
    public let target: String?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = ["range": range.toJSON()]
        if let target = target { json["target"] = target }
        return json
    }
}

// MARK: - LSP Command

public struct LSPCommand {
    public let title: String
    public let command: String
    public let arguments: [Any]?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "title": title,
            "command": command
        ]
        if let arguments = arguments {
            json["arguments"] = arguments
        }
        return json
    }
}

// MARK: - LSP Code Lens

public struct LSPCodeLens {
    public let range: LSPRange
    public let command: LSPCommand?

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "range": range.toJSON()
        ]
        if let command = command {
            json["command"] = command.toJSON()
        }
        return json
    }
}

// MARK: - Position Conversion

/// Convert LSP position (0-indexed line, 0-indexed character) to Rockit SourceLocation (1-indexed line, 0-indexed column)
public func lspPositionToSourceLocation(_ pos: LSPPosition, uri: String) -> SourceLocation {
    return SourceLocation(file: uriToPath(uri), line: pos.line + 1, column: pos.character)
}

/// Convert Rockit SourceLocation to LSP position
public func sourceLocationToLSPPosition(_ loc: SourceLocation) -> LSPPosition {
    return LSPPosition(line: loc.line - 1, character: loc.column)
}

/// Convert Rockit SourceSpan to LSP range
public func sourceSpanToLSPRange(_ span: SourceSpan) -> LSPRange {
    return LSPRange(
        start: sourceLocationToLSPPosition(span.start),
        end: sourceLocationToLSPPosition(span.end)
    )
}

// MARK: - URI Helpers

/// Convert file:// URI to filesystem path
public func uriToPath(_ uri: String) -> String {
    if uri.hasPrefix("file://") {
        let path = String(uri.dropFirst(7))
        // Handle percent-encoded characters
        return path.removingPercentEncoding ?? path
    }
    return uri
}

/// Convert filesystem path to file:// URI
public func pathToURI(_ path: String) -> String {
    return "file://\(path)"
}

// MARK: - Expression Span Helper

/// Extract the SourceSpan from any Expression case
public func expressionSpan(_ expr: RockitKit.Expression) -> SourceSpan {
    switch expr {
    case .intLiteral(_, let span),
         .floatLiteral(_, let span),
         .stringLiteral(_, let span),
         .interpolatedString(_, let span),
         .boolLiteral(_, let span),
         .nullLiteral(let span),
         .identifier(_, let span),
         .this(let span),
         .super(let span),
         .binary(_, _, _, let span),
         .unaryPrefix(_, _, let span),
         .unaryPostfix(_, _, let span),
         .memberAccess(_, _, let span),
         .nullSafeMemberAccess(_, _, let span),
         .subscriptAccess(_, _, let span),
         .call(_, _, _, let span),
         .typeCheck(_, _, let span),
         .typeCast(_, _, let span),
         .safeCast(_, _, let span),
         .nonNullAssert(_, let span),
         .awaitExpr(_, let span),
         .concurrentBlock(_, let span),
         .elvis(_, _, let span),
         .range(_, _, _, let span),
         .parenthesized(_, let span),
         .error(let span):
        return span
    case .ifExpr(let ie):
        return ie.span
    case .whenExpr(let we):
        return we.span
    case .lambda(let le):
        return le.span
    }
}

/// Extract the SourceSpan from any Statement case
public func statementSpan(_ stmt: RockitKit.Statement) -> SourceSpan? {
    switch stmt {
    case .propertyDecl(let p): return p.span
    case .expression(let e): return expressionSpan(e)
    case .returnStmt(_, let span): return span
    case .breakStmt(let span): return span
    case .continueStmt(let span): return span
    case .throwStmt(_, let span): return span
    case .tryCatch(let tc): return tc.span
    case .assignment(let a): return a.span
    case .forLoop(let f): return f.span
    case .whileLoop(let w): return w.span
    case .doWhileLoop(let d): return d.span
    case .declaration(let d): return declarationSpan(d)
    case .destructuringDecl(let d): return d.span
    }
}

/// Extract the SourceSpan from any Declaration case
public func declarationSpan(_ decl: RockitKit.Declaration) -> SourceSpan {
    switch decl {
    case .function(let f): return f.span
    case .property(let p): return p.span
    case .classDecl(let c): return c.span
    case .interfaceDecl(let i): return i.span
    case .enumDecl(let e): return e.span
    case .objectDecl(let o): return o.span
    case .actorDecl(let a): return a.span
    case .viewDecl(let v): return v.span
    case .navigationDecl(let n): return n.span
    case .themeDecl(let t): return t.span
    case .typeAlias(let ta): return ta.span
    }
}
