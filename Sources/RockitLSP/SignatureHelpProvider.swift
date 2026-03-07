// SignatureHelpProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import RockitKit

/// Implements textDocument/signatureHelp (parameter hints inside function calls)
public final class SignatureHelpProvider {

    /// Compute signature help at the given position
    public static func signatureHelp(
        at position: LSPPosition,
        uri: String,
        analysisResult: AnalysisResult,
        documentText: String
    ) -> LSPSignatureHelp? {
        let sourcePos = lspPositionToSourceLocation(position, uri: uri)

        // Filter out newline tokens for easier navigation
        let tokens = analysisResult.tokens.filter { $0.kind != .newline && $0.kind != .eof }

        // Find the token at or just before the cursor
        guard let tokenIdx = findTokenAtOrBefore(tokens, position: sourcePos) else { return nil }

        // Walk backward to find the opening '(' and count commas for active parameter
        var parenDepth = 0
        var commaCount = 0
        var openParenIdx: Int? = nil

        for i in stride(from: tokenIdx, through: 0, by: -1) {
            let tok = tokens[i]
            if tok.kind == .rightParen { parenDepth += 1 }
            else if tok.kind == .leftParen {
                if parenDepth == 0 {
                    openParenIdx = i
                    break
                }
                parenDepth -= 1
            }
            else if tok.kind == .comma && parenDepth == 0 {
                commaCount += 1
            }
        }

        guard let parenIdx = openParenIdx, parenIdx > 0 else { return nil }

        // The token before '(' should be the function name
        let calleeToken = tokens[parenIdx - 1]
        guard case .identifier(let funcName) = calleeToken.kind else { return nil }

        // Look up the function in the symbol table
        guard let sym = analysisResult.typeCheckResult.symbolTable.lookup(funcName) else { return nil }

        // Build parameter labels
        let paramLabels: [String]
        let returnStr: String

        if case .function(let paramTypes, let returnType) = sym.type {
            // Try to find the actual function declaration for better parameter names
            if let funcDecl = findFunctionDecl(named: funcName, in: analysisResult.ast) {
                paramLabels = funcDecl.parameters.map { p in
                    var s = p.name
                    if let t = p.type { s += ": \(t.summary)" }
                    if p.defaultValue != nil { s += " = ..." }
                    return s
                }
            } else {
                // Builtin — use type info
                paramLabels = paramTypes.enumerated().map { i, t in "arg\(i): \(t)" }
            }
            returnStr = ": \(returnType)"
        } else {
            return nil
        }

        let sigLabel = "\(funcName)(\(paramLabels.joined(separator: ", ")))\(returnStr)"
        let paramInfos = paramLabels.map { LSPParameterInformation(label: $0) }
        let activeParam = paramInfos.isEmpty ? 0 : min(commaCount, paramInfos.count - 1)

        return LSPSignatureHelp(
            signatures: [LSPSignatureInformation(label: sigLabel, parameters: paramInfos)],
            activeSignature: 0,
            activeParameter: activeParam
        )
    }

    // MARK: - Private

    private static func findTokenAtOrBefore(_ tokens: [Token], position: SourceLocation) -> Int? {
        var bestIdx: Int? = nil
        for (i, tok) in tokens.enumerated() {
            if tok.span.start.line < position.line ||
               (tok.span.start.line == position.line && tok.span.start.column <= position.column) {
                bestIdx = i
            } else {
                break
            }
        }
        return bestIdx
    }

    private static func findFunctionDecl(named name: String, in ast: SourceFile) -> FunctionDecl? {
        for decl in ast.declarations {
            if let result = findFuncInDecl(named: name, decl: decl) {
                return result
            }
        }
        return nil
    }

    private static func findFuncInDecl(named name: String, decl: Declaration) -> FunctionDecl? {
        switch decl {
        case .function(let f):
            if f.name == name { return f }

        case .classDecl(let c):
            for member in c.members {
                if let result = findFuncInDecl(named: name, decl: member) { return result }
            }

        case .interfaceDecl(let i):
            for member in i.members {
                if let result = findFuncInDecl(named: name, decl: member) { return result }
            }

        case .objectDecl(let o):
            for member in o.members {
                if let result = findFuncInDecl(named: name, decl: member) { return result }
            }

        case .actorDecl(let a):
            for member in a.members {
                if let result = findFuncInDecl(named: name, decl: member) { return result }
            }

        default:
            break
        }
        return nil
    }
}
