// CompletionProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import RockitKit

/// Implements textDocument/completion
public final class CompletionProvider {

    /// Compute completion items at the given position
    public static func complete(
        at position: LSPPosition,
        uri: String,
        analysisResult: AnalysisResult,
        documentText: String
    ) -> [LSPCompletionItem] {
        let sourcePos = lspPositionToSourceLocation(position, uri: uri)
        let lines = documentText.split(separator: "\n", omittingEmptySubsequences: false)

        guard sourcePos.line >= 1, sourcePos.line <= lines.count else { return [] }
        let lineText = String(lines[sourcePos.line - 1])
        let colIdx = min(sourcePos.column, lineText.count)
        let prefix = String(lineText.prefix(colIdx))

        if isDotCompletion(prefix: prefix) {
            return dotCompletion(prefix: prefix, sourcePos: sourcePos, analysisResult: analysisResult)
        } else {
            return scopeCompletion(sourcePos: sourcePos, prefix: prefix, analysisResult: analysisResult)
        }
    }

    // MARK: - Private

    private static func isDotCompletion(prefix: String) -> Bool {
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        // Check if user just typed a dot or is typing after a dot
        return trimmed.hasSuffix(".")
    }

    private static func dotCompletion(
        prefix: String,
        sourcePos: SourceLocation,
        analysisResult: AnalysisResult
    ) -> [LSPCompletionItem] {
        var items: [LSPCompletionItem] = []

        // Find the token just before the dot
        let nonNewlineTokens = analysisResult.tokens.filter { $0.kind != .newline }
        let dotTokenIdx = nonNewlineTokens.lastIndex { token in
            token.kind == .dot &&
            token.span.start.line == sourcePos.line &&
            token.span.start.column < sourcePos.column
        }

        if let dotIdx = dotTokenIdx, dotIdx > 0 {
            let beforeDot = nonNewlineTokens[dotIdx - 1]
            if case .identifier(let name) = beforeDot.kind {
                let typeName = resolveTypeName(name: name, tokenSpan: beforeDot.span, analysisResult: analysisResult)
                if let typeName = typeName {
                    items.append(contentsOf: membersForType(typeName, analysisResult: analysisResult))
                }
            }
        }

        return items
    }

    private static func resolveTypeName(name: String, tokenSpan: SourceSpan, analysisResult: AnalysisResult) -> String? {
        // Try typeMap first
        let exprId = ExpressionID(tokenSpan)
        if let type = analysisResult.typeCheckResult.typeMap[exprId] {
            return type.typeName ?? typeToName(type)
        }
        // Fall back to symbol table
        if let sym = analysisResult.typeCheckResult.symbolTable.lookup(name) {
            return sym.type.typeName ?? typeToName(sym.type)
        }
        // Maybe it's a type name itself (static member access)
        if analysisResult.typeCheckResult.symbolTable.lookupType(name) != nil {
            return name
        }
        // Search AST for local variable declarations and resolve from explicit type or initializer
        if let typeName = resolveLocalVariableType(name: name, in: analysisResult) {
            return typeName
        }
        return nil
    }

    private static func resolveLocalVariableType(name: String, in result: AnalysisResult) -> String? {
        for decl in result.ast.declarations {
            if let typeName = findLocalVarType(name: name, in: decl, typeCheckResult: result.typeCheckResult) {
                return typeName
            }
        }
        return nil
    }

    private static func findLocalVarType(name: String, in decl: Declaration, typeCheckResult: TypeCheckResult) -> String? {
        switch decl {
        case .function(let f):
            // Check function parameters
            for p in f.parameters where p.name == name {
                if let t = p.type { return typeNodeToTypeName(t) }
            }
            // Check body
            if let body = f.body {
                switch body {
                case .block(let block):
                    return findVarTypeInStatements(name: name, stmts: block.statements, typeCheckResult: typeCheckResult)
                case .expression:
                    return nil
                }
            }
        case .classDecl(let c):
            for p in c.constructorParams where p.name == name {
                if let t = p.type { return typeNodeToTypeName(t) }
            }
            for member in c.members {
                if let t = findLocalVarType(name: name, in: member, typeCheckResult: typeCheckResult) { return t }
            }
        case .property(let p) where p.name == name:
            if let t = p.type { return typeNodeToTypeName(t) }
            // Try to resolve from initializer type
            if let init_ = p.initializer {
                return resolveExpressionTypeName(init_, typeCheckResult: typeCheckResult)
            }
        default:
            break
        }
        return nil
    }

    private static func findVarTypeInStatements(name: String, stmts: [RockitKit.Statement], typeCheckResult: TypeCheckResult) -> String? {
        for stmt in stmts {
            switch stmt {
            case .propertyDecl(let p) where p.name == name:
                if let t = p.type { return typeNodeToTypeName(t) }
                if let init_ = p.initializer {
                    return resolveExpressionTypeName(init_, typeCheckResult: typeCheckResult)
                }
            case .forLoop(let f):
                if let t = findVarTypeInStatements(name: name, stmts: f.body.statements, typeCheckResult: typeCheckResult) { return t }
            case .whileLoop(let w):
                if let t = findVarTypeInStatements(name: name, stmts: w.body.statements, typeCheckResult: typeCheckResult) { return t }
            case .declaration(let d):
                if let t = findLocalVarType(name: name, in: d, typeCheckResult: typeCheckResult) { return t }
            default:
                break
            }
        }
        return nil
    }

    private static func resolveExpressionTypeName(_ expr: RockitKit.Expression, typeCheckResult: TypeCheckResult) -> String? {
        let span = expressionSpan(expr)
        let exprId = ExpressionID(span)
        if let type = typeCheckResult.typeMap[exprId] {
            return type.typeName ?? typeToName(type)
        }
        // For constructor calls like Dog("Rusty"), the callee name IS the type name
        if case .call(let callee, _, _, _) = expr {
            if case .identifier(let calleeName, _) = callee {
                if typeCheckResult.symbolTable.lookupType(calleeName) != nil {
                    return calleeName
                }
            }
        }
        return nil
    }

    private static func typeNodeToTypeName(_ typeNode: TypeNode) -> String? {
        switch typeNode {
        case .simple(let name, _, _): return name
        case .qualified(_, let member, _): return member
        case .nullable(let inner, _): return typeNodeToTypeName(inner)
        default: return nil
        }
    }

    private static func typeToName(_ type: Type) -> String? {
        switch type {
        case .string: return "String"
        case .int: return "Int"
        case .bool: return "Bool"
        case .float, .float64, .double: return "Double"
        case .classType(let name, _): return name
        case .interfaceType(let name, _): return name
        case .enumType(let name): return name
        case .actorType(let name): return name
        case .objectType(let name): return name
        default: return nil
        }
    }

    private static func membersForType(_ typeName: String, analysisResult: AnalysisResult) -> [LSPCompletionItem] {
        var items: [LSPCompletionItem] = []

        if let typeInfo = analysisResult.typeCheckResult.symbolTable.lookupType(typeName) {
            for member in typeInfo.members {
                items.append(symbolToCompletionItem(member))
            }

            // Add enum entries
            for entry in typeInfo.enumEntries {
                items.append(LSPCompletionItem(
                    label: entry,
                    kind: LSPCompletionItemKind.enumMember,
                    detail: typeName,
                    insertText: entry
                ))
            }
        }

        // Add common methods for built-in types
        switch typeName {
        case "String":
            items.append(contentsOf: stringCompletions())
        case "List", "MutableList":
            items.append(contentsOf: listCompletions())
        case "Map", "MutableMap":
            items.append(contentsOf: mapCompletions())
        default:
            break
        }

        return items
    }

    private static func scopeCompletion(
        sourcePos: SourceLocation,
        prefix: String,
        analysisResult: AnalysisResult
    ) -> [LSPCompletionItem] {
        var items: [LSPCompletionItem] = []
        let partial = extractPartialIdentifier(prefix: prefix)

        // Collect visible symbols
        let symbols = ASTNavigator.collectVisibleSymbols(
            in: analysisResult.ast,
            at: sourcePos,
            typeCheckResult: analysisResult.typeCheckResult
        )

        for sym in symbols {
            if partial.isEmpty || sym.name.lowercased().hasPrefix(partial.lowercased()) {
                items.append(symbolToCompletionItem(sym))
            }
        }

        // Add keywords
        let keywords = [
            "fun", "val", "var", "class", "interface", "enum", "object",
            "if", "else", "when", "for", "while", "do", "return",
            "break", "continue", "throw", "try", "catch",
            "null", "true", "false", "this", "super",
            "import", "package", "data", "sealed", "abstract", "open",
            "override", "private", "public", "internal", "protected",
            "actor", "view", "navigation", "theme",
            "suspend", "async", "await", "concurrent",
            "is", "as", "in", "typealias"
        ]

        for kw in keywords {
            if partial.isEmpty || kw.hasPrefix(partial.lowercased()) {
                items.append(LSPCompletionItem(
                    label: kw,
                    kind: LSPCompletionItemKind.keyword,
                    detail: nil,
                    insertText: kw
                ))
            }
        }

        return items
    }

    private static func symbolToCompletionItem(_ sym: Symbol) -> LSPCompletionItem {
        let kind: Int
        let detail: String

        switch sym.kind {
        case .function:
            kind = LSPCompletionItemKind.function_
            if case .function(let params, let ret) = sym.type {
                let paramStr = params.map { "\($0)" }.joined(separator: ", ")
                detail = "(\(paramStr)): \(ret)"
            } else {
                detail = "function"
            }
        case .variable(let isMutable):
            kind = isMutable ? LSPCompletionItemKind.variable : LSPCompletionItemKind.constant
            detail = "\(sym.type)"
        case .parameter:
            kind = LSPCompletionItemKind.variable
            detail = "\(sym.type)"
        case .typeDeclaration:
            kind = LSPCompletionItemKind.class_
            detail = "type"
        case .typeAlias:
            kind = LSPCompletionItemKind.class_
            detail = "typealias"
        case .typeParameter:
            kind = LSPCompletionItemKind.typeParameter
            detail = "type parameter"
        case .enumEntry:
            kind = LSPCompletionItemKind.enumMember
            detail = "\(sym.type)"
        }

        return LSPCompletionItem(
            label: sym.name,
            kind: kind,
            detail: detail,
            insertText: sym.name
        )
    }

    private static func extractPartialIdentifier(prefix: String) -> String {
        var result = ""
        for c in prefix.reversed() {
            if c.isLetter || c.isNumber || c == "_" {
                result = String(c) + result
            } else {
                break
            }
        }
        return result
    }

    // MARK: - Built-in Type Completions

    private static func stringCompletions() -> [LSPCompletionItem] {
        return [
            LSPCompletionItem(label: "length", kind: LSPCompletionItemKind.property, detail: "Int", insertText: "length"),
            LSPCompletionItem(label: "substring", kind: LSPCompletionItemKind.method, detail: "(Int, Int): String", insertText: "substring"),
            LSPCompletionItem(label: "indexOf", kind: LSPCompletionItemKind.method, detail: "(String): Int", insertText: "indexOf"),
            LSPCompletionItem(label: "contains", kind: LSPCompletionItemKind.method, detail: "(String): Bool", insertText: "contains"),
            LSPCompletionItem(label: "startsWith", kind: LSPCompletionItemKind.method, detail: "(String): Bool", insertText: "startsWith"),
            LSPCompletionItem(label: "endsWith", kind: LSPCompletionItemKind.method, detail: "(String): Bool", insertText: "endsWith"),
            LSPCompletionItem(label: "trim", kind: LSPCompletionItemKind.method, detail: "(): String", insertText: "trim"),
            LSPCompletionItem(label: "toUpper", kind: LSPCompletionItemKind.method, detail: "(): String", insertText: "toUpper"),
            LSPCompletionItem(label: "toLower", kind: LSPCompletionItemKind.method, detail: "(): String", insertText: "toLower"),
            LSPCompletionItem(label: "replace", kind: LSPCompletionItemKind.method, detail: "(String, String): String", insertText: "replace"),
            LSPCompletionItem(label: "split", kind: LSPCompletionItemKind.method, detail: "(String): List<String>", insertText: "split"),
        ]
    }

    private static func listCompletions() -> [LSPCompletionItem] {
        return [
            LSPCompletionItem(label: "size", kind: LSPCompletionItemKind.property, detail: "Int", insertText: "size"),
            LSPCompletionItem(label: "isEmpty", kind: LSPCompletionItemKind.method, detail: "(): Bool", insertText: "isEmpty"),
            LSPCompletionItem(label: "get", kind: LSPCompletionItemKind.method, detail: "(Int): T", insertText: "get"),
            LSPCompletionItem(label: "add", kind: LSPCompletionItemKind.method, detail: "(T): Unit", insertText: "add"),
            LSPCompletionItem(label: "set", kind: LSPCompletionItemKind.method, detail: "(Int, T): Unit", insertText: "set"),
            LSPCompletionItem(label: "removeAt", kind: LSPCompletionItemKind.method, detail: "(Int): T", insertText: "removeAt"),
            LSPCompletionItem(label: "contains", kind: LSPCompletionItemKind.method, detail: "(T): Bool", insertText: "contains"),
            LSPCompletionItem(label: "indexOf", kind: LSPCompletionItemKind.method, detail: "(T): Int", insertText: "indexOf"),
            LSPCompletionItem(label: "clear", kind: LSPCompletionItemKind.method, detail: "(): Unit", insertText: "clear"),
        ]
    }

    private static func mapCompletions() -> [LSPCompletionItem] {
        return [
            LSPCompletionItem(label: "size", kind: LSPCompletionItemKind.property, detail: "Int", insertText: "size"),
            LSPCompletionItem(label: "isEmpty", kind: LSPCompletionItemKind.method, detail: "(): Bool", insertText: "isEmpty"),
            LSPCompletionItem(label: "get", kind: LSPCompletionItemKind.method, detail: "(K): V?", insertText: "get"),
            LSPCompletionItem(label: "put", kind: LSPCompletionItemKind.method, detail: "(K, V): Unit", insertText: "put"),
            LSPCompletionItem(label: "remove", kind: LSPCompletionItemKind.method, detail: "(K): V?", insertText: "remove"),
            LSPCompletionItem(label: "containsKey", kind: LSPCompletionItemKind.method, detail: "(K): Bool", insertText: "containsKey"),
            LSPCompletionItem(label: "keys", kind: LSPCompletionItemKind.method, detail: "(): List<K>", insertText: "keys"),
            LSPCompletionItem(label: "values", kind: LSPCompletionItemKind.method, detail: "(): List<V>", insertText: "values"),
            LSPCompletionItem(label: "clear", kind: LSPCompletionItemKind.method, detail: "(): Unit", insertText: "clear"),
        ]
    }
}
