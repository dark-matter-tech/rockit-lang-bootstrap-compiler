// SemanticTokensProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import RockitKit

/// Provides semantic token data for type-aware syntax highlighting
public final class SemanticTokensProvider {

    private struct RawToken: Comparable {
        let line: Int       // 0-indexed
        let startChar: Int  // 0-indexed
        let length: Int
        let tokenType: Int
        let modifiers: Int

        static func < (lhs: RawToken, rhs: RawToken) -> Bool {
            if lhs.line != rhs.line { return lhs.line < rhs.line }
            return lhs.startChar < rhs.startChar
        }
    }

    public static func semanticTokens(for result: AnalysisResult) -> [Int] {
        var rawTokens: [RawToken] = []

        // Classify lexer tokens
        for token in result.tokens {
            if let raw = classifyToken(token) {
                rawTokens.append(raw)
            }
        }

        // Reclassify identifiers using type information from AST
        reclassifyIdentifiers(in: result.ast, typeCheckResult: result.typeCheckResult, into: &rawTokens)

        rawTokens.sort()

        // Remove duplicates (same position) — prefer AST-classified over lexer
        var deduped: [RawToken] = []
        for token in rawTokens {
            if let last = deduped.last, last.line == token.line && last.startChar == token.startChar {
                // Replace with the later one (AST-classified tokens are added after lexer tokens)
                deduped[deduped.count - 1] = token
            } else {
                deduped.append(token)
            }
        }

        return deltaEncode(deduped)
    }

    // MARK: - Token Classification

    private static func classifyToken(_ token: Token) -> RawToken? {
        let line = token.span.start.line - 1  // Convert to 0-indexed
        let startChar = token.span.start.column
        let length = token.lexeme.count

        guard length > 0 else { return nil }

        let type: LSPSemanticTokenType?

        switch token.kind {
        // Keywords
        case .kwFun, .kwVal, .kwVar, .kwClass, .kwInterface, .kwObject, .kwEnum,
             .kwData, .kwSealed, .kwAbstract, .kwOpen, .kwOverride,
             .kwPrivate, .kwInternal, .kwPublic, .kwProtected, .kwCompanion,
             .kwTypealias, .kwVararg, .kwImport, .kwPackage,
             .kwThis, .kwSuper, .kwConstructor, .kwInit, .kwWhere, .kwOut,
             .kwIf, .kwElse, .kwWhen, .kwFor, .kwWhile, .kwDo,
             .kwReturn, .kwBreak, .kwContinue, .kwIn, .kwIs, .kwAs,
             .kwThrow, .kwTry, .kwCatch, .kwFinally,
             .kwView, .kwActor, .kwNavigation, .kwRoute, .kwTheme, .kwStyle,
             .kwSuspend, .kwAsync, .kwAwait, .kwConcurrent,
             .kwWeak, .kwUnowned:
            type = .keyword

        // Boolean and null literals are also keywords visually
        case .boolLiteral:
            type = .keyword
        case .nullLiteral:
            type = .keyword

        // Numbers
        case .intLiteral, .floatLiteral:
            type = .number

        // Strings
        case .stringLiteral:
            type = .string

        // Identifiers are handled by AST walk
        case .identifier:
            return nil

        default:
            return nil
        }

        guard let tokenType = type else { return nil }
        return RawToken(line: line, startChar: startChar, length: length,
                        tokenType: tokenType.rawValue, modifiers: 0)
    }

    // MARK: - AST-based Identifier Classification

    private static func reclassifyIdentifiers(
        in ast: SourceFile,
        typeCheckResult: TypeCheckResult,
        into rawTokens: inout [RawToken]
    ) {
        for decl in ast.declarations {
            classifyDeclaration(decl, typeCheckResult: typeCheckResult, into: &rawTokens)
        }
    }

    private static func classifyDeclaration(
        _ decl: RDeclaration,
        typeCheckResult: TypeCheckResult,
        into rawTokens: inout [RawToken]
    ) {
        switch decl {
        case .function(let f):
            // Function name is a function token with declaration modifier
            addIdentifierToken(name: f.name, span: f.span, type: .function_,
                             modifier: LSPSemanticTokenModifier.declaration, into: &rawTokens)
            for param in f.parameters {
                addNameToken(name: param.name, span: param.span, type: .parameter, into: &rawTokens)
            }
            if let body = f.body {
                switch body {
                case .block(let block):
                    for stmt in block.statements {
                        classifyStatement(stmt, typeCheckResult: typeCheckResult, into: &rawTokens)
                    }
                case .expression(let expr):
                    classifyExpression(expr, typeCheckResult: typeCheckResult, into: &rawTokens)
                }
            }

        case .property(let p):
            let mod = p.isVal ? LSPSemanticTokenModifier.readonly.rawValue : 0
            let declMod = (1 << LSPSemanticTokenModifier.declaration.rawValue) | mod
            addNameToken(name: p.name, span: p.span, type: .variable, modifiers: declMod, into: &rawTokens)
            if let init_ = p.initializer {
                classifyExpression(init_, typeCheckResult: typeCheckResult, into: &rawTokens)
            }

        case .classDecl(let c):
            addIdentifierToken(name: c.name, span: c.span, type: .class_,
                             modifier: LSPSemanticTokenModifier.declaration, into: &rawTokens)
            for member in c.members {
                classifyDeclaration(member, typeCheckResult: typeCheckResult, into: &rawTokens)
            }

        case .interfaceDecl(let i):
            addIdentifierToken(name: i.name, span: i.span, type: .interface_,
                             modifier: LSPSemanticTokenModifier.declaration, into: &rawTokens)
            for member in i.members {
                classifyDeclaration(member, typeCheckResult: typeCheckResult, into: &rawTokens)
            }

        case .enumDecl(let e):
            addIdentifierToken(name: e.name, span: e.span, type: .enum_,
                             modifier: LSPSemanticTokenModifier.declaration, into: &rawTokens)
            for entry in e.entries {
                addNameToken(name: entry.name, span: entry.span, type: .enumMember, into: &rawTokens)
            }
            for member in e.members {
                classifyDeclaration(member, typeCheckResult: typeCheckResult, into: &rawTokens)
            }

        case .objectDecl(let o):
            addIdentifierToken(name: o.name, span: o.span, type: .class_,
                             modifier: LSPSemanticTokenModifier.declaration, into: &rawTokens)
            for member in o.members {
                classifyDeclaration(member, typeCheckResult: typeCheckResult, into: &rawTokens)
            }

        case .actorDecl(let a):
            addIdentifierToken(name: a.name, span: a.span, type: .class_,
                             modifier: LSPSemanticTokenModifier.declaration, into: &rawTokens)
            for member in a.members {
                classifyDeclaration(member, typeCheckResult: typeCheckResult, into: &rawTokens)
            }

        case .viewDecl(let v):
            addIdentifierToken(name: v.name, span: v.span, type: .class_,
                             modifier: LSPSemanticTokenModifier.declaration, into: &rawTokens)
            for stmt in v.body.statements {
                classifyStatement(stmt, typeCheckResult: typeCheckResult, into: &rawTokens)
            }

        default:
            break
        }
    }

    private static func classifyStatement(
        _ stmt: RStatement,
        typeCheckResult: TypeCheckResult,
        into rawTokens: inout [RawToken]
    ) {
        switch stmt {
        case .expression(let expr):
            classifyExpression(expr, typeCheckResult: typeCheckResult, into: &rawTokens)
        case .propertyDecl(let p):
            let mod = p.isVal ? (1 << LSPSemanticTokenModifier.readonly.rawValue) : 0
            let declMod = (1 << LSPSemanticTokenModifier.declaration.rawValue) | mod
            addNameToken(name: p.name, span: p.span, type: .variable, modifiers: declMod, into: &rawTokens)
            if let init_ = p.initializer {
                classifyExpression(init_, typeCheckResult: typeCheckResult, into: &rawTokens)
            }
        case .returnStmt(let expr, _):
            if let expr = expr { classifyExpression(expr, typeCheckResult: typeCheckResult, into: &rawTokens) }
        case .throwStmt(let expr, _):
            classifyExpression(expr, typeCheckResult: typeCheckResult, into: &rawTokens)
        case .assignment(let a):
            classifyExpression(a.target, typeCheckResult: typeCheckResult, into: &rawTokens)
            classifyExpression(a.value, typeCheckResult: typeCheckResult, into: &rawTokens)
        case .forLoop(let f):
            classifyExpression(f.iterable, typeCheckResult: typeCheckResult, into: &rawTokens)
            for s in f.body.statements { classifyStatement(s, typeCheckResult: typeCheckResult, into: &rawTokens) }
        case .whileLoop(let w):
            classifyExpression(w.condition, typeCheckResult: typeCheckResult, into: &rawTokens)
            for s in w.body.statements { classifyStatement(s, typeCheckResult: typeCheckResult, into: &rawTokens) }
        case .declaration(let d):
            classifyDeclaration(d, typeCheckResult: typeCheckResult, into: &rawTokens)
        default:
            break
        }
    }

    private static func classifyExpression(
        _ expr: RExpression,
        typeCheckResult: TypeCheckResult,
        into rawTokens: inout [RawToken]
    ) {
        switch expr {
        case .identifier(let name, let span):
            let tokenType = resolveIdentifierType(name: name, typeCheckResult: typeCheckResult)
            let line = span.start.line - 1
            let startChar = span.start.column
            rawTokens.append(RawToken(line: line, startChar: startChar, length: name.count,
                                       tokenType: tokenType.rawValue, modifiers: 0))

        case .call(let callee, let args, _, _):
            classifyExpression(callee, typeCheckResult: typeCheckResult, into: &rawTokens)
            for arg in args {
                classifyExpression(arg.value, typeCheckResult: typeCheckResult, into: &rawTokens)
            }

        case .binary(let left, _, let right, _):
            classifyExpression(left, typeCheckResult: typeCheckResult, into: &rawTokens)
            classifyExpression(right, typeCheckResult: typeCheckResult, into: &rawTokens)

        case .unaryPrefix(_, let operand, _):
            classifyExpression(operand, typeCheckResult: typeCheckResult, into: &rawTokens)

        case .unaryPostfix(let operand, _, _):
            classifyExpression(operand, typeCheckResult: typeCheckResult, into: &rawTokens)

        case .memberAccess(let obj, _, _), .nullSafeMemberAccess(let obj, _, _):
            classifyExpression(obj, typeCheckResult: typeCheckResult, into: &rawTokens)

        case .subscriptAccess(let obj, let idx, _):
            classifyExpression(obj, typeCheckResult: typeCheckResult, into: &rawTokens)
            classifyExpression(idx, typeCheckResult: typeCheckResult, into: &rawTokens)

        case .parenthesized(let inner, _), .nonNullAssert(let inner, _), .awaitExpr(let inner, _):
            classifyExpression(inner, typeCheckResult: typeCheckResult, into: &rawTokens)

        case .elvis(let left, let right, _):
            classifyExpression(left, typeCheckResult: typeCheckResult, into: &rawTokens)
            classifyExpression(right, typeCheckResult: typeCheckResult, into: &rawTokens)

        case .ifExpr(let ie):
            classifyExpression(ie.condition, typeCheckResult: typeCheckResult, into: &rawTokens)
            for s in ie.thenBranch.statements { classifyStatement(s, typeCheckResult: typeCheckResult, into: &rawTokens) }
            if let elseBranch = ie.elseBranch {
                switch elseBranch {
                case .elseBlock(let block):
                    for s in block.statements { classifyStatement(s, typeCheckResult: typeCheckResult, into: &rawTokens) }
                case .elseIf(let elseIf):
                    classifyExpression(.ifExpr(elseIf), typeCheckResult: typeCheckResult, into: &rawTokens)
                }
            }

        case .lambda(let le):
            for s in le.body { classifyStatement(s, typeCheckResult: typeCheckResult, into: &rawTokens) }

        default:
            break
        }
    }

    private static func resolveIdentifierType(
        name: String,
        typeCheckResult: TypeCheckResult
    ) -> LSPSemanticTokenType {
        if let sym = typeCheckResult.symbolTable.lookup(name) {
            switch sym.kind {
            case .function: return .function_
            case .parameter: return .parameter
            case .variable: return .variable
            case .typeDeclaration: return .class_
            case .typeAlias: return .type
            case .typeParameter: return .typeParameter
            case .enumEntry: return .enumMember
            }
        }

        // Check type declarations
        if typeCheckResult.symbolTable.lookupType(name) != nil {
            return .class_
        }

        return .variable
    }

    // MARK: - Helpers

    private static func addIdentifierToken(
        name: String,
        span: SourceSpan,
        type: LSPSemanticTokenType,
        modifier: LSPSemanticTokenModifier,
        into rawTokens: inout [RawToken]
    ) {
        let line = span.start.line - 1
        let startChar = span.start.column
        rawTokens.append(RawToken(line: line, startChar: startChar, length: name.count,
                                   tokenType: type.rawValue, modifiers: 1 << modifier.rawValue))
    }

    private static func addNameToken(
        name: String,
        span: SourceSpan,
        type: LSPSemanticTokenType,
        modifiers: Int = 0,
        into rawTokens: inout [RawToken]
    ) {
        let line = span.start.line - 1
        let startChar = span.start.column
        rawTokens.append(RawToken(line: line, startChar: startChar, length: name.count,
                                   tokenType: type.rawValue, modifiers: modifiers))
    }

    // MARK: - Delta Encoding

    private static func deltaEncode(_ tokens: [RawToken]) -> [Int] {
        var data: [Int] = []
        var prevLine = 0
        var prevChar = 0

        for token in tokens {
            let deltaLine = token.line - prevLine
            let deltaChar = deltaLine == 0 ? token.startChar - prevChar : token.startChar

            data.append(deltaLine)
            data.append(deltaChar)
            data.append(token.length)
            data.append(token.tokenType)
            data.append(token.modifiers)

            prevLine = token.line
            prevChar = token.startChar
        }

        return data
    }
}
