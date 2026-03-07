// ASTNavigator.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import RockitKit

/// Type aliases to disambiguate from Foundation types
public typealias RExpression = RockitKit.Expression
public typealias RDeclaration = RockitKit.Declaration
public typealias RStatement = RockitKit.Statement

// MARK: - Node Context

/// The result of finding an AST node at a position
public struct NodeAtPosition {
    public enum Kind {
        case expression(RExpression)
        case declaration(RDeclaration)
        case statement(RStatement)
        case parameter(Parameter)
    }

    public let kind: Kind
    public let enclosingDeclaration: Declaration?
    public let enclosingClassName: String?
}

// MARK: - AST Navigator

/// Walks the AST to find nodes at positions and collect visible symbols
public final class ASTNavigator {

    /// Check if a SourceSpan contains the given position
    public static func spanContains(_ span: SourceSpan, _ position: SourceLocation) -> Bool {
        // Position before start
        if position.line < span.start.line { return false }
        if position.line == span.start.line && position.column < span.start.column { return false }
        // Position after end
        if position.line > span.end.line { return false }
        if position.line == span.end.line && position.column > span.end.column { return false }
        return true
    }

    /// Find the innermost AST node at the given position
    public static func findNode(in ast: SourceFile, at position: SourceLocation) -> NodeAtPosition? {
        for decl in ast.declarations {
            if let result = findInDeclaration(decl, at: position, enclosingDecl: nil, enclosingClass: nil) {
                return result
            }
        }
        return nil
    }

    /// Find declaration of a symbol by name in the AST
    public static func findDeclaration(named name: String, in ast: SourceFile) -> SourceSpan? {
        for decl in ast.declarations {
            if let span = findDeclByName(name, in: decl) {
                return span
            }
        }
        return nil
    }

    /// Collect all symbols visible at the given position
    public static func collectVisibleSymbols(
        in ast: SourceFile,
        at position: SourceLocation,
        typeCheckResult: TypeCheckResult
    ) -> [Symbol] {
        var symbols: [Symbol] = []

        // Add all top-level declarations
        for decl in ast.declarations {
            if let sym = symbolForDeclaration(decl, symbolTable: typeCheckResult.symbolTable) {
                symbols.append(sym)
            }
        }

        // Add symbols from enclosing scopes
        for decl in ast.declarations {
            let declSpan = declarationSpan(decl)
            if spanContains(declSpan, position) {
                collectLocalSymbols(from: decl, at: position, into: &symbols, symbolTable: typeCheckResult.symbolTable)
            }
        }

        // Add all type declarations as completions
        for (name, _) in typeCheckResult.symbolTable.typeDeclarations {
            if !symbols.contains(where: { $0.name == name }) {
                symbols.append(Symbol(name: name, type: .classType(name: name, typeArguments: []), kind: .typeDeclaration))
            }
        }

        // Add builtins from symbol table global scope
        if let println = typeCheckResult.symbolTable.lookup("println") {
            // If we can look up builtins, they're already in the scope chain.
            // Add common ones that might not be in the AST
            let builtinNames = ["println", "print", "readLine", "toString", "toInt",
                               "listOf", "mapOf", "setOf", "mutableListOf", "mutableMapOf",
                               "assert", "assertEquals", "assertNotEquals", "assertTrue", "assertFalse",
                               "assertEqualsStr", "assertGreaterThan", "assertLessThan",
                               "assertStringContains", "assertStartsWith", "assertEndsWith", "fail",
                               "panic", "typeOf", "abs", "min", "max"]
            for name in builtinNames {
                if let sym = typeCheckResult.symbolTable.lookup(name),
                   !symbols.contains(where: { $0.name == name }) {
                    symbols.append(sym)
                }
            }
            // Suppress unused variable warning
            _ = println
        }

        return symbols
    }

    // MARK: - Private Helpers

    private static func findInDeclaration(
        _ decl: Declaration,
        at position: SourceLocation,
        enclosingDecl: Declaration?,
        enclosingClass: String?
    ) -> NodeAtPosition? {
        let span = declarationSpan(decl)
        guard spanContains(span, position) else { return nil }

        switch decl {
        case .function(let f):
            // Check parameters
            for param in f.parameters {
                if spanContains(param.span, position) {
                    return NodeAtPosition(kind: .parameter(param), enclosingDeclaration: decl, enclosingClassName: enclosingClass)
                }
            }
            // Check body
            if let body = f.body {
                switch body {
                case .block(let block):
                    if let result = findInBlock(block, at: position, enclosingDecl: decl, enclosingClass: enclosingClass) {
                        return result
                    }
                case .expression(let expr):
                    if let result = findInExpression(expr, at: position, enclosingDecl: decl, enclosingClass: enclosingClass) {
                        return result
                    }
                }
            }
            return NodeAtPosition(kind: .declaration(decl), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)

        case .classDecl(let c):
            // Check constructor params
            for param in c.constructorParams {
                if spanContains(param.span, position) {
                    return NodeAtPosition(kind: .parameter(param), enclosingDeclaration: decl, enclosingClassName: c.name)
                }
            }
            // Check supertypes
            for st in c.superTypes {
                if let result = findInTypeNode(st, at: position, enclosingDecl: decl, enclosingClass: c.name) {
                    return result
                }
            }
            for member in c.members {
                if let result = findInDeclaration(member, at: position, enclosingDecl: decl, enclosingClass: c.name) {
                    return result
                }
            }
            return NodeAtPosition(kind: .declaration(decl), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)

        case .interfaceDecl(let i):
            // Check supertypes
            for st in i.superTypes {
                if let result = findInTypeNode(st, at: position, enclosingDecl: decl, enclosingClass: i.name) {
                    return result
                }
            }
            for member in i.members {
                if let result = findInDeclaration(member, at: position, enclosingDecl: decl, enclosingClass: i.name) {
                    return result
                }
            }
            return NodeAtPosition(kind: .declaration(decl), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)

        case .enumDecl(let e):
            for member in e.members {
                if let result = findInDeclaration(member, at: position, enclosingDecl: decl, enclosingClass: e.name) {
                    return result
                }
            }
            return NodeAtPosition(kind: .declaration(decl), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)

        case .objectDecl(let o):
            for member in o.members {
                if let result = findInDeclaration(member, at: position, enclosingDecl: decl, enclosingClass: o.name) {
                    return result
                }
            }
            return NodeAtPosition(kind: .declaration(decl), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)

        case .actorDecl(let a):
            for member in a.members {
                if let result = findInDeclaration(member, at: position, enclosingDecl: decl, enclosingClass: a.name) {
                    return result
                }
            }
            return NodeAtPosition(kind: .declaration(decl), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)

        case .viewDecl(let v):
            if let result = findInBlock(v.body, at: position, enclosingDecl: decl, enclosingClass: v.name) {
                return result
            }
            return NodeAtPosition(kind: .declaration(decl), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)

        case .property(let p):
            if let init_ = p.initializer {
                if let result = findInExpression(init_, at: position, enclosingDecl: decl, enclosingClass: enclosingClass) {
                    return result
                }
            }
            return NodeAtPosition(kind: .declaration(decl), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)

        default:
            return NodeAtPosition(kind: .declaration(decl), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)
        }
    }

    /// Check if position falls on a TypeNode (e.g. supertype reference) and return a synthetic identifier expression
    private static func findInTypeNode(
        _ typeNode: TypeNode,
        at position: SourceLocation,
        enclosingDecl: Declaration?,
        enclosingClass: String?
    ) -> NodeAtPosition? {
        switch typeNode {
        case .simple(let name, _, let span):
            if spanContains(span, position) {
                return NodeAtPosition(
                    kind: .expression(.identifier(name, span)),
                    enclosingDeclaration: enclosingDecl,
                    enclosingClassName: enclosingClass
                )
            }
        case .qualified(let base, let member, let span):
            if spanContains(span, position) {
                return NodeAtPosition(
                    kind: .expression(.identifier(member, span)),
                    enclosingDeclaration: enclosingDecl,
                    enclosingClassName: enclosingClass
                )
            }
            if let result = findInTypeNode(base, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
        case .nullable(let inner, _):
            if let result = findInTypeNode(inner, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
        default:
            break
        }
        return nil
    }

    private static func findInBlock(
        _ block: Block,
        at position: SourceLocation,
        enclosingDecl: Declaration?,
        enclosingClass: String?
    ) -> NodeAtPosition? {
        for stmt in block.statements {
            if let result = findInStatement(stmt, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
        }
        return nil
    }

    private static func findInStatement(
        _ stmt: Statement,
        at position: SourceLocation,
        enclosingDecl: Declaration?,
        enclosingClass: String?
    ) -> NodeAtPosition? {
        guard let span = statementSpan(stmt), spanContains(span, position) else { return nil }

        switch stmt {
        case .expression(let expr):
            return findInExpression(expr, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass)
                ?? NodeAtPosition(kind: .statement(stmt), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)

        case .propertyDecl(let p):
            if let init_ = p.initializer {
                if let result = findInExpression(init_, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                    return result
                }
            }
            return NodeAtPosition(kind: .declaration(.property(p)), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)

        case .returnStmt(let expr, _):
            if let expr = expr {
                if let result = findInExpression(expr, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                    return result
                }
            }
            return NodeAtPosition(kind: .statement(stmt), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)

        case .assignment(let a):
            if let result = findInExpression(a.target, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
            if let result = findInExpression(a.value, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
            return NodeAtPosition(kind: .statement(stmt), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)

        case .forLoop(let f):
            if let result = findInExpression(f.iterable, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
            if let result = findInBlock(f.body, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
            return NodeAtPosition(kind: .statement(stmt), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)

        case .whileLoop(let w):
            if let result = findInExpression(w.condition, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
            if let result = findInBlock(w.body, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
            return NodeAtPosition(kind: .statement(stmt), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)

        case .doWhileLoop(let d):
            if let result = findInBlock(d.body, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
            if let result = findInExpression(d.condition, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
            return NodeAtPosition(kind: .statement(stmt), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)

        case .tryCatch(let tc):
            if let result = findInBlock(tc.tryBody, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
            if let result = findInBlock(tc.catchBody, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
            return NodeAtPosition(kind: .statement(stmt), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)

        case .throwStmt(let expr, _):
            return findInExpression(expr, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass)
                ?? NodeAtPosition(kind: .statement(stmt), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)

        case .declaration(let d):
            return findInDeclaration(d, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass)

        case .destructuringDecl(let d):
            if let result = findInExpression(d.initializer, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
            return NodeAtPosition(kind: .statement(stmt), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)

        default:
            return NodeAtPosition(kind: .statement(stmt), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)
        }
    }

    private static func findInExpression(
        _ expr: RExpression,
        at position: SourceLocation,
        enclosingDecl: Declaration?,
        enclosingClass: String?
    ) -> NodeAtPosition? {
        let span = expressionSpan(expr)
        guard spanContains(span, position) else { return nil }

        // Try to find a more specific child node
        switch expr {
        case .binary(let left, _, let right, _):
            if let result = findInExpression(left, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
            if let result = findInExpression(right, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }

        case .unaryPrefix(_, let operand, _):
            if let result = findInExpression(operand, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }

        case .unaryPostfix(let operand, _, _):
            if let result = findInExpression(operand, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }

        case .memberAccess(let obj, _, _), .nullSafeMemberAccess(let obj, _, _):
            if let result = findInExpression(obj, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }

        case .subscriptAccess(let obj, let idx, _):
            if let result = findInExpression(obj, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
            if let result = findInExpression(idx, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }

        case .call(let callee, let args, let trailing, _):
            if let result = findInExpression(callee, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
            for arg in args {
                if let result = findInExpression(arg.value, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                    return result
                }
            }
            if let lambda = trailing {
                for stmt in lambda.body {
                    if let result = findInStatement(stmt, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                        return result
                    }
                }
            }

        case .ifExpr(let ie):
            if let result = findInExpression(ie.condition, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
            if let result = findInBlock(ie.thenBranch, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
            if let elseBranch = ie.elseBranch {
                switch elseBranch {
                case .elseBlock(let block):
                    if let result = findInBlock(block, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                        return result
                    }
                case .elseIf(let eif):
                    if let result = findInExpression(.ifExpr(eif), at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                        return result
                    }
                }
            }

        case .whenExpr(let we):
            if let subject = we.subject {
                if let result = findInExpression(subject, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                    return result
                }
            }
            for entry in we.entries {
                switch entry.body {
                case .expression(let bodyExpr):
                    if let result = findInExpression(bodyExpr, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                        return result
                    }
                case .block(let block):
                    if let result = findInBlock(block, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                        return result
                    }
                }
            }

        case .lambda(let le):
            for stmt in le.body {
                if let result = findInStatement(stmt, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                    return result
                }
            }

        case .parenthesized(let inner, _):
            if let result = findInExpression(inner, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }

        case .elvis(let left, let right, _):
            if let result = findInExpression(left, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
            if let result = findInExpression(right, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }

        case .range(let start, let end, _, _):
            if let result = findInExpression(start, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }
            if let result = findInExpression(end, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }

        case .nonNullAssert(let inner, _):
            if let result = findInExpression(inner, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }

        case .awaitExpr(let inner, _):
            if let result = findInExpression(inner, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }

        case .typeCheck(let inner, _, _), .typeCast(let inner, _, _), .safeCast(let inner, _, _):
            if let result = findInExpression(inner, at: position, enclosingDecl: enclosingDecl, enclosingClass: enclosingClass) {
                return result
            }

        default:
            break
        }

        // This expression is the deepest match
        return NodeAtPosition(kind: .expression(expr), enclosingDeclaration: enclosingDecl, enclosingClassName: enclosingClass)
    }

    // MARK: - Declaration Name Search

    private static func findDeclByName(_ name: String, in decl: Declaration) -> SourceSpan? {
        switch decl {
        case .function(let f):
            if f.name == name { return f.span }
            // Search parameters
            for p in f.parameters {
                if p.name == name { return p.span }
            }
            // Search function body for local declarations
            if let body = f.body {
                if let span = findNameInFunctionBody(name, body: body) { return span }
            }
        case .property(let p):
            if p.name == name { return p.span }
        case .classDecl(let c):
            if c.name == name { return c.span }
            // Search constructor params
            for p in c.constructorParams {
                if p.name == name { return p.span }
            }
            for member in c.members {
                if let span = findDeclByName(name, in: member) { return span }
            }
        case .interfaceDecl(let i):
            if i.name == name { return i.span }
            for member in i.members {
                if let span = findDeclByName(name, in: member) { return span }
            }
        case .enumDecl(let e):
            if e.name == name { return e.span }
            for entry in e.entries {
                if entry.name == name { return entry.span }
            }
            for member in e.members {
                if let span = findDeclByName(name, in: member) { return span }
            }
        case .objectDecl(let o):
            if o.name == name { return o.span }
            for member in o.members {
                if let span = findDeclByName(name, in: member) { return span }
            }
        case .actorDecl(let a):
            if a.name == name { return a.span }
            for member in a.members {
                if let span = findDeclByName(name, in: member) { return span }
            }
        case .viewDecl(let v):
            if v.name == name { return v.span }
        case .navigationDecl(let n):
            if n.name == name { return n.span }
        case .themeDecl(let t):
            if t.name == name { return t.span }
        case .typeAlias(let ta):
            if ta.name == name { return ta.span }
        }
        return nil
    }

    private static func findNameInFunctionBody(_ name: String, body: FunctionBody) -> SourceSpan? {
        switch body {
        case .block(let block):
            return findNameInStatements(name, stmts: block.statements)
        case .expression:
            return nil
        }
    }

    private static func findNameInStatements(_ name: String, stmts: [RStatement]) -> SourceSpan? {
        for stmt in stmts {
            if let span = findNameInStatement(name, stmt: stmt) { return span }
        }
        return nil
    }

    private static func findNameInStatement(_ name: String, stmt: RStatement) -> SourceSpan? {
        switch stmt {
        case .propertyDecl(let p):
            if p.name == name { return p.span }
        case .declaration(let d):
            if let span = findDeclByName(name, in: d) { return span }
        case .forLoop(let f):
            if f.variable == name { return f.span }
            if let span = findNameInStatements(name, stmts: f.body.statements) { return span }
        case .whileLoop(let w):
            if let span = findNameInStatements(name, stmts: w.body.statements) { return span }
        case .doWhileLoop(let d):
            if let span = findNameInStatements(name, stmts: d.body.statements) { return span }
        case .tryCatch(let tc):
            if let span = findNameInStatements(name, stmts: tc.tryBody.statements) { return span }
            if let span = findNameInStatements(name, stmts: tc.catchBody.statements) { return span }
            if let fb = tc.finallyBody {
                if let span = findNameInStatements(name, stmts: fb.statements) { return span }
            }
        case .expression(let e):
            if let span = findNameInExpression(name, expr: e) { return span }
        default:
            break
        }
        return nil
    }

    private static func findNameInExpression(_ name: String, expr: RExpression) -> SourceSpan? {
        switch expr {
        case .ifExpr(let ie):
            if let span = findNameInStatements(name, stmts: ie.thenBranch.statements) { return span }
            if let eb = ie.elseBranch {
                switch eb {
                case .elseBlock(let block):
                    if let span = findNameInStatements(name, stmts: block.statements) { return span }
                case .elseIf(let nested):
                    if let span = findNameInExpression(name, expr: .ifExpr(nested)) { return span }
                }
            }
        case .whenExpr(let we):
            for entry in we.entries {
                switch entry.body {
                case .block(let block):
                    if let span = findNameInStatements(name, stmts: block.statements) { return span }
                case .expression:
                    break
                }
            }
        case .lambda(let le):
            for p in le.parameters {
                if p.name == name { return p.span }
            }
            if let span = findNameInStatements(name, stmts: le.body) { return span }
        default:
            break
        }
        return nil
    }

    // MARK: - Symbol Collection

    private static func symbolForDeclaration(_ decl: Declaration, symbolTable: SymbolTable) -> Symbol? {
        switch decl {
        case .function(let f):
            if let sym = symbolTable.lookup(f.name) { return sym }
            return Symbol(name: f.name, type: .function(parameterTypes: [], returnType: .unit), kind: .function, span: f.span)
        case .property(let p):
            if let sym = symbolTable.lookup(p.name) { return sym }
            return Symbol(name: p.name, type: .error, kind: .variable(isMutable: !p.isVal), span: p.span)
        case .classDecl(let c):
            return Symbol(name: c.name, type: .classType(name: c.name, typeArguments: []), kind: .typeDeclaration, span: c.span)
        case .interfaceDecl(let i):
            return Symbol(name: i.name, type: .interfaceType(name: i.name, typeArguments: []), kind: .typeDeclaration, span: i.span)
        case .enumDecl(let e):
            return Symbol(name: e.name, type: .enumType(name: e.name), kind: .typeDeclaration, span: e.span)
        case .objectDecl(let o):
            return Symbol(name: o.name, type: .objectType(name: o.name), kind: .typeDeclaration, span: o.span)
        case .actorDecl(let a):
            return Symbol(name: a.name, type: .actorType(name: a.name), kind: .typeDeclaration, span: a.span)
        case .viewDecl(let v):
            return Symbol(name: v.name, type: .classType(name: v.name, typeArguments: []), kind: .typeDeclaration, span: v.span)
        default:
            return nil
        }
    }

    private static func collectLocalSymbols(
        from decl: Declaration,
        at position: SourceLocation,
        into symbols: inout [Symbol],
        symbolTable: SymbolTable
    ) {
        switch decl {
        case .function(let f):
            // Add parameters
            for param in f.parameters {
                if let sym = symbolTable.lookup(param.name) {
                    symbols.append(sym)
                } else if let typeNode = param.type {
                    symbols.append(Symbol(name: param.name, type: .error, kind: .parameter, span: param.span))
                    _ = typeNode // suppress warning
                } else {
                    symbols.append(Symbol(name: param.name, type: .error, kind: .parameter, span: param.span))
                }
            }
            // Add local declarations from body
            if let body = f.body {
                switch body {
                case .block(let block):
                    collectLocalSymbolsFromBlock(block, at: position, into: &symbols, symbolTable: symbolTable)
                case .expression:
                    break
                }
            }

        case .classDecl(let c):
            // Add class members
            for member in c.members {
                if let sym = symbolForDeclaration(member, symbolTable: symbolTable) {
                    if !symbols.contains(where: { $0.name == sym.name }) {
                        symbols.append(sym)
                    }
                }
                // Recurse into the member that contains the cursor
                let memberSpan = declarationSpan(member)
                if spanContains(memberSpan, position) {
                    collectLocalSymbols(from: member, at: position, into: &symbols, symbolTable: symbolTable)
                }
            }

        case .actorDecl(let a):
            for member in a.members {
                if let sym = symbolForDeclaration(member, symbolTable: symbolTable) {
                    if !symbols.contains(where: { $0.name == sym.name }) {
                        symbols.append(sym)
                    }
                }
                let memberSpan = declarationSpan(member)
                if spanContains(memberSpan, position) {
                    collectLocalSymbols(from: member, at: position, into: &symbols, symbolTable: symbolTable)
                }
            }

        default:
            break
        }
    }

    private static func collectLocalSymbolsFromBlock(
        _ block: Block,
        at position: SourceLocation,
        into symbols: inout [Symbol],
        symbolTable: SymbolTable
    ) {
        for stmt in block.statements {
            guard let span = statementSpan(stmt) else { continue }
            // Only include declarations that appear before the cursor position
            if span.start.line > position.line { break }
            if span.start.line == position.line && span.start.column > position.column { break }

            switch stmt {
            case .propertyDecl(let p):
                if let sym = symbolTable.lookup(p.name) {
                    symbols.append(sym)
                } else {
                    symbols.append(Symbol(name: p.name, type: .error, kind: .variable(isMutable: !p.isVal), span: p.span))
                }

            case .forLoop(let f):
                if spanContains(f.span, position) {
                    symbols.append(Symbol(name: f.variable, type: .error, kind: .variable(isMutable: false), span: f.span))
                    collectLocalSymbolsFromBlock(f.body, at: position, into: &symbols, symbolTable: symbolTable)
                }

            case .whileLoop(let w):
                if spanContains(w.span, position) {
                    collectLocalSymbolsFromBlock(w.body, at: position, into: &symbols, symbolTable: symbolTable)
                }

            case .declaration(let d):
                if let sym = symbolForDeclaration(d, symbolTable: symbolTable) {
                    symbols.append(sym)
                }

            default:
                break
            }
        }
    }
}
