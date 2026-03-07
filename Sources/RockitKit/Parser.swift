// Parser.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

/// Recursive descent parser for the Rockit language.
///
/// Consumes a token array produced by `Lexer` and produces an AST (`SourceFile`).
/// Uses Pratt parsing (precedence climbing) for expressions.
public final class Parser {

    // MARK: - State

    private let tokens: [Token]
    private var current: Int = 0
    private let diagnostics: DiagnosticEngine

    /// Delimiter depth for newline significance
    private var parenDepth: Int = 0
    private var bracketDepth: Int = 0

    // MARK: - Init

    public init(tokens: [Token], diagnostics: DiagnosticEngine) {
        self.tokens = tokens
        self.diagnostics = diagnostics
    }

    // MARK: - Public API

    /// Parse the entire token stream into a SourceFile AST.
    public func parse() -> SourceFile {
        let startSpan = peek().span
        skipNewlines()
        let packageDecl = parsePackageDecl()
        skipNewlines()
        let imports = parseImports()
        skipNewlines()
        var declarations: [Declaration] = []
        while !check(.eof) {
            skipNewlines()
            if check(.eof) { break }
            // Skip stray closing braces at top level to avoid infinite loops
            if check(.rightBrace) {
                advance()
                continue
            }
            if let decl = parseDeclarationRecovering() {
                declarations.append(decl)
            }
            skipNewlines()
        }
        let endSpan = peek().span
        return SourceFile(packageDecl: packageDecl, imports: imports,
                          declarations: declarations,
                          span: span(from: startSpan.start, to: endSpan.end))
    }

    // MARK: - Token Navigation

    private func peek() -> Token {
        guard current < tokens.count else { return tokens[tokens.count - 1] }
        return tokens[current]
    }

    private func peekNext() -> Token {
        let idx = current + 1
        guard idx < tokens.count else { return tokens[tokens.count - 1] }
        return tokens[idx]
    }

    private var currentKind: TokenKind { peek().kind }

    @discardableResult
    private func advance() -> Token {
        let tok = peek()
        if current < tokens.count { current += 1 }
        return tok
    }

    private func check(_ kind: TokenKind) -> Bool {
        return peek().kind == kind
    }

    private func checkIdentifier() -> String? {
        if case .identifier(let name) = peek().kind { return name }
        return nil
    }

    private func checkIntLiteral() -> Int64? {
        if case .intLiteral(let v) = peek().kind { return v }
        return nil
    }

    private func checkFloatLiteral() -> Double? {
        if case .floatLiteral(let v) = peek().kind { return v }
        return nil
    }

    private func checkStringLiteral() -> String? {
        if case .stringLiteral(let v) = peek().kind { return v }
        return nil
    }

    private func checkBoolLiteral() -> Bool? {
        if case .boolLiteral(let v) = peek().kind { return v }
        return nil
    }

    @discardableResult
    private func match(_ kind: TokenKind) -> Bool {
        if check(kind) { advance(); return true }
        return false
    }

    @discardableResult
    private func expect(_ kind: TokenKind, _ message: String) -> Token {
        if check(kind) { return advance() }
        diagnostics.error(message, at: peek().span.start)
        return Token(kind: kind, lexeme: "", span: peek().span)
    }

    private func expectIdentifier(_ message: String) -> String {
        if let name = checkIdentifier() { advance(); return name }
        // Allow soft keywords as identifiers
        if let name = softKeywordAsIdentifier() { advance(); return name }
        diagnostics.error(message, at: peek().span.start)
        return "<error>"
    }

    /// Soft keywords that can be used as identifiers in most contexts
    private func softKeywordAsIdentifier() -> String? {
        switch currentKind {
        case .kwData: return "data"
        case .kwRoute: return "route"
        case .kwStyle: return "style"
        case .kwInit: return "init"
        case .kwConstructor: return "constructor"
        case .kwOut: return "out"
        case .kwIn: return "in"
        default: return nil
        }
    }

    /// Like expectIdentifier but also allows keywords (for member access like .style, .route)
    private func expectMemberName(_ message: String) -> String {
        if let name = checkIdentifier() { advance(); return name }
        // Allow keywords as member names
        if let name = memberKeywordName() { advance(); return name }
        diagnostics.error(message, at: peek().span.start)
        return "<error>"
    }

    /// Map keyword tokens to their string names for member access
    private func memberKeywordName() -> String? {
        switch currentKind {
        case .kwRoute: return "route"
        case .kwStyle: return "style"
        case .kwInit: return "init"
        case .kwConstructor: return "constructor"
        case .kwData: return "data"
        case .kwIn: return "in"
        case .kwOut: return "out"
        case .kwIs: return "is"
        case .kwAs: return "as"
        default: return nil
        }
    }

    private func skipNewlines() {
        while check(.newline) { advance() }
    }

    /// Skip newlines unless we're about to see a continuation token
    private func skipStatementNewlines() {
        while check(.newline) {
            // Look past all newlines to see what comes next
            let saved = save()
            var nextIdx = current
            while nextIdx < tokens.count && tokens[nextIdx].kind == .newline {
                nextIdx += 1
            }
            restore(saved)
            // If next real token is a continuation, stop
            if nextIdx < tokens.count {
                let nextKind = tokens[nextIdx].kind
                if isContinuationToken(nextKind) {
                    break
                }
            }
            advance()
        }
    }

    private func isContinuationToken(_ kind: TokenKind) -> Bool {
        switch kind {
        case .dot, .questionDot, .questionColon:
            return true
        default:
            return false
        }
    }

    private func save() -> Int { current }
    private func restore(_ position: Int) { current = position }

    private func span(from start: SourceLocation, to end: SourceLocation) -> SourceSpan {
        SourceSpan(start: start, end: end)
    }

    private func spanFrom(_ token: Token) -> SourceSpan {
        span(from: token.span.start, to: previous().span.end)
    }

    private func previous() -> Token {
        guard current > 0 else { return tokens[0] }
        return tokens[current - 1]
    }

    private var atEnd: Bool { check(.eof) }

    // MARK: - Error Recovery

    private func synchronize() {
        while !check(.eof) {
            if check(.newline) || check(.semicolon) {
                advance()
                return
            }
            switch currentKind {
            case .kwFun, .kwVal, .kwVar, .kwClass, .kwInterface, .kwEnum,
                 .kwObject, .kwActor, .kwView, .kwNavigation, .kwTheme,
                 .kwTypealias, .kwImport, .kwPackage, .kwData, .kwSealed,
                 .kwAbstract, .kwOpen, .kwPublic, .kwPrivate, .kwInternal,
                 .kwProtected, .kwOverride, .kwSuspend, .kwAsync, .at:
                return
            case .rightBrace:
                return
            default:
                advance()
            }
        }
    }

    private func parseDeclarationRecovering() -> Declaration? {
        let saved = save()
        let declStart = peek()
        let annotations = parseAnnotations()
        let modifiers = parseModifiers()
        skipNewlines()

        if let decl = tryParseDeclaration(annotations: annotations, modifiers: modifiers) {
            return decl
        }

        // If modifiers were empty, try parsing as a top-level statement expression
        if annotations.isEmpty && modifiers.isEmpty {
            restore(saved)
            // Try as an expression statement — wrap as property for top level
            diagnostics.error("expected declaration", at: peek().span.start)
            synchronize()
            return nil
        }

        diagnostics.error("expected declaration after modifiers", at: declStart.span.start)
        synchronize()
        return nil
    }

    // MARK: - Package & Imports

    private func parsePackageDecl() -> PackageDecl? {
        guard check(.kwPackage) else { return nil }
        let start = advance()
        let path = parseDottedName()
        return PackageDecl(path: path, span: spanFrom(start))
    }

    private func parseImports() -> [ImportDecl] {
        var imports: [ImportDecl] = []
        while true {
            skipNewlines()
            guard check(.kwImport) else { break }
            let start = advance()
            let path = parseDottedName()
            imports.append(ImportDecl(path: path, span: spanFrom(start)))
        }
        return imports
    }

    private func parseDottedName() -> [String] {
        var parts: [String] = []
        parts.append(expectIdentifier("expected name"))
        while match(.dot) {
            parts.append(expectIdentifier("expected name after '.'"))
        }
        return parts
    }

    // MARK: - Annotations & Modifiers

    private func parseAnnotations() -> [Annotation] {
        var annotations: [Annotation] = []
        while check(.at) {
            let start = advance()
            let name = expectIdentifier("expected annotation name")
            var arguments: [CallArgument] = []
            if check(.leftParen) {
                arguments = parseCallArgumentList()
            }
            annotations.append(Annotation(name: name, arguments: arguments,
                                          span: spanFrom(start)))
            skipNewlines()
        }
        return annotations
    }

    private func parseModifiers() -> Set<Modifier> {
        var mods: Set<Modifier> = []
        loop: while true {
            switch currentKind {
            case .kwPublic:    mods.insert(.public); advance()
            case .kwPrivate:   mods.insert(.private); advance()
            case .kwInternal:  mods.insert(.internal); advance()
            case .kwProtected: mods.insert(.protected); advance()
            case .kwData:      mods.insert(.data); advance()
            case .kwSealed:    mods.insert(.sealed); advance()
            case .kwOpen:      mods.insert(.open); advance()
            case .kwAbstract:  mods.insert(.abstract); advance()
            case .kwOverride:  mods.insert(.override); advance()
            case .kwSuspend:   mods.insert(.suspend); advance()
            case .kwAsync:     mods.insert(.async); advance()
            case .kwWeak:      mods.insert(.weak); advance()
            case .kwUnowned:   mods.insert(.unowned); advance()
            default:           break loop
            }
            skipNewlines()
        }
        return mods
    }

    // MARK: - Declarations

    private func tryParseDeclaration(annotations: [Annotation],
                                     modifiers: Set<Modifier>) -> Declaration? {
        switch currentKind {
        case .kwFun:
            return .function(parseFunctionDecl(annotations: annotations, modifiers: modifiers))
        case .kwVal:
            return .property(parsePropertyDecl(annotations: annotations, modifiers: modifiers, isVal: true))
        case .kwVar:
            return .property(parsePropertyDecl(annotations: annotations, modifiers: modifiers, isVal: false))
        case .kwClass:
            return .classDecl(parseClassDecl(annotations: annotations, modifiers: modifiers))
        case .kwInterface:
            return .interfaceDecl(parseInterfaceDecl(annotations: annotations))
        case .kwEnum:
            return .enumDecl(parseEnumClassDecl(annotations: annotations))
        case .kwObject:
            return .objectDecl(parseObjectDecl(annotations: annotations, modifiers: modifiers))
        case .kwCompanion:
            return .objectDecl(parseCompanionObjectDecl(annotations: annotations, modifiers: modifiers))
        case .kwActor:
            return .actorDecl(parseActorDecl(annotations: annotations))
        case .kwView:
            return .viewDecl(parseViewDecl(annotations: annotations))
        case .kwNavigation:
            return .navigationDecl(parseNavigationDecl())
        case .kwTheme:
            return .themeDecl(parseThemeDecl())
        case .kwTypealias:
            return .typeAlias(parseTypeAliasDecl())
        default:
            return nil
        }
    }

    // MARK: - Function Declaration

    private func parseFunctionDecl(annotations: [Annotation],
                                   modifiers: Set<Modifier>) -> FunctionDecl {
        let start = expect(.kwFun, "expected 'fun'")
        skipNewlines()

        // Support Kotlin-style type params before name: fun <T> name(...)
        var typeParams: [TypeParameter] = []
        if check(.less) {
            typeParams = parseTypeParameterList()
            skipNewlines()
        }

        let firstName = expectIdentifier("expected function name")

        // Check for extension function: fun TypeName.methodName(...)
        var name = firstName
        var receiverType: String? = nil
        if check(.dot) {
            let saved = save()
            advance() // consume '.'
            if let methodName = checkIdentifier() {
                advance()
                receiverType = firstName
                name = methodName
            } else {
                restore(saved)
            }
        }

        // Also support type params after name: fun name<T>(...)
        if typeParams.isEmpty {
            typeParams = parseTypeParameterList()
        }
        expect(.leftParen, "expected '(' after function name")
        parenDepth += 1
        let params = parseParameterList()
        parenDepth -= 1
        expect(.rightParen, "expected ')' after parameters")
        let returnType = parseOptionalReturnType()
        skipNewlines()
        let body = parseFunctionBody()
        return FunctionDecl(annotations: annotations, modifiers: modifiers,
                            name: name, receiverType: receiverType,
                            typeParameters: typeParams,
                            parameters: params, returnType: returnType,
                            body: body, span: spanFrom(start))
    }

    private func parseParameterList() -> [Parameter] {
        var params: [Parameter] = []
        skipNewlines()
        guard !check(.rightParen) else { return params }
        params.append(parseParameter())
        while match(.comma) {
            skipNewlines()
            params.append(parseParameter())
        }
        skipNewlines()
        return params
    }

    private func parseParameter() -> Parameter {
        skipNewlines()
        let start = peek()
        var isVal = false
        var isVar = false
        var isVararg = false
        if check(.kwVal) { isVal = true; advance() }
        else if check(.kwVar) { isVar = true; advance() }
        else if check(.kwVararg) { isVararg = true; advance() }
        let name = expectIdentifier("expected parameter name")
        let type = parseOptionalTypeAnnotation()
        var defaultValue: Expression? = nil
        if match(.equal) {
            skipNewlines()
            defaultValue = parseExpression()
        }
        return Parameter(name: name, type: type, defaultValue: defaultValue,
                         isVal: isVal, isVar: isVar, isVararg: isVararg, span: spanFrom(start))
    }

    private func parseOptionalReturnType() -> TypeNode? {
        guard match(.colon) else { return nil }
        skipNewlines()
        return parseType()
    }

    private func parseOptionalTypeAnnotation() -> TypeNode? {
        guard match(.colon) else { return nil }
        skipNewlines()
        return parseType()
    }

    private func parseFunctionBody() -> FunctionBody? {
        skipNewlines()
        if check(.leftBrace) {
            return .block(parseBlock())
        } else if match(.equal) {
            skipNewlines()
            return .expression(parseExpression())
        }
        return nil
    }

    // MARK: - Property Declaration

    private func parsePropertyDecl(annotations: [Annotation], modifiers: Set<Modifier>,
                                   isVal: Bool) -> PropertyDecl {
        let start = advance() // consume val/var
        skipNewlines()
        let name = expectIdentifier("expected property name")
        let type = parseOptionalTypeAnnotation()
        var initializer: Expression? = nil
        if match(.equal) {
            skipNewlines()
            initializer = parseExpression()
        }
        return PropertyDecl(annotations: annotations, modifiers: modifiers,
                            isVal: isVal, name: name, type: type,
                            initializer: initializer, span: spanFrom(start))
    }

    /// Parse destructuring val declaration: `val (a, b, c) = expr`
    private func parseDestructuringDecl() -> DestructuringDecl {
        let start = expect(.kwVal, "expected 'val'")
        expect(.leftParen, "expected '(' for destructuring")
        var names: [String] = []
        names.append(expectIdentifier("expected variable name"))
        while match(.comma) {
            skipNewlines()
            names.append(expectIdentifier("expected variable name"))
        }
        expect(.rightParen, "expected ')' after destructured variables")
        expect(.equal, "expected '=' after destructuring pattern")
        skipNewlines()
        let initializer = parseExpression()
        return DestructuringDecl(names: names, initializer: initializer, span: spanFrom(start))
    }

    // MARK: - Class Declaration

    private func parseClassDecl(annotations: [Annotation],
                                modifiers: Set<Modifier>) -> ClassDecl {
        let start = expect(.kwClass, "expected 'class'")
        skipNewlines()
        let name = expectIdentifier("expected class name")
        let typeParams = parseTypeParameterList()
        var ctorParams: [Parameter] = []
        if check(.leftParen) {
            advance()
            parenDepth += 1
            ctorParams = parseParameterList()
            parenDepth -= 1
            expect(.rightParen, "expected ')' after constructor parameters")
        }
        let (superTypes, superCallArgs) = parseInheritanceClause()
        skipNewlines()
        var members: [Declaration] = []
        if check(.leftBrace) {
            members = parseClassBody()
        }
        return ClassDecl(annotations: annotations, modifiers: modifiers, name: name,
                         typeParameters: typeParams, constructorParams: ctorParams,
                         superTypes: superTypes, superCallArgs: superCallArgs,
                         members: members, span: spanFrom(start))
    }

    private func parseInheritanceClause() -> ([TypeNode], [CallArgument]) {
        guard match(.colon) else { return ([], []) }
        skipNewlines()
        var superTypes: [TypeNode] = []
        var superCallArgs: [CallArgument] = []

        let firstType = parseType()
        superTypes.append(firstType)
        // Check for super constructor call args: Result<T>()
        if check(.leftParen) {
            superCallArgs = parseCallArgumentList()
        }
        while match(.comma) {
            skipNewlines()
            superTypes.append(parseType())
        }
        return (superTypes, superCallArgs)
    }

    private func parseClassBody() -> [Declaration] {
        expect(.leftBrace, "expected '{' for class body")
        skipNewlines()
        var members: [Declaration] = []
        while !check(.rightBrace) && !check(.eof) {
            skipNewlines()
            if check(.rightBrace) || check(.eof) { break }
            let annotations = parseAnnotations()
            let modifiers = parseModifiers()
            skipNewlines()
            if let decl = tryParseDeclaration(annotations: annotations, modifiers: modifiers) {
                members.append(decl)
            } else {
                diagnostics.error("expected member declaration", at: peek().span.start)
                synchronize()
            }
            skipNewlines()
        }
        expect(.rightBrace, "expected '}' to close class body")
        return members
    }

    // MARK: - Interface Declaration

    private func parseInterfaceDecl(annotations: [Annotation]) -> InterfaceDecl {
        let start = expect(.kwInterface, "expected 'interface'")
        skipNewlines()
        let name = expectIdentifier("expected interface name")
        let typeParams = parseTypeParameterList()
        let (superTypes, _) = parseInheritanceClause()
        skipNewlines()
        var members: [Declaration] = []
        if check(.leftBrace) {
            members = parseClassBody()
        }
        return InterfaceDecl(annotations: annotations, name: name,
                             typeParameters: typeParams, superTypes: superTypes,
                             members: members, span: spanFrom(start))
    }

    // MARK: - Enum Class Declaration

    private func parseEnumClassDecl(annotations: [Annotation]) -> EnumClassDecl {
        let start = expect(.kwEnum, "expected 'enum'")
        expect(.kwClass, "expected 'class' after 'enum'")
        skipNewlines()
        let name = expectIdentifier("expected enum name")
        let typeParams = parseTypeParameterList()
        skipNewlines()
        expect(.leftBrace, "expected '{' for enum body")
        skipNewlines()

        var entries: [EnumEntry] = []
        var members: [Declaration] = []

        // Parse enum entries until we hit a member or closing brace
        while !check(.rightBrace) && !check(.eof) {
            skipNewlines()
            if check(.rightBrace) || check(.eof) { break }
            // If it looks like a declaration keyword, switch to members
            if isDeclarationStart() { break }
            if let entryName = checkIdentifier() {
                let entryStart = advance()
                var args: [CallArgument] = []
                if check(.leftParen) {
                    args = parseCallArgumentList()
                }
                entries.append(EnumEntry(name: entryName, arguments: args,
                                         span: spanFrom(entryStart)))
                _ = match(.comma)
                skipNewlines()
            } else {
                break
            }
        }

        // Parse members
        while !check(.rightBrace) && !check(.eof) {
            skipNewlines()
            if check(.rightBrace) || check(.eof) { break }
            let annotations = parseAnnotations()
            let modifiers = parseModifiers()
            skipNewlines()
            if let decl = tryParseDeclaration(annotations: annotations, modifiers: modifiers) {
                members.append(decl)
            } else {
                diagnostics.error("expected member declaration in enum", at: peek().span.start)
                synchronize()
            }
            skipNewlines()
        }

        expect(.rightBrace, "expected '}' to close enum body")
        return EnumClassDecl(annotations: annotations, name: name,
                             typeParameters: typeParams, entries: entries,
                             members: members, span: spanFrom(start))
    }

    private func isDeclarationStart() -> Bool {
        switch currentKind {
        case .kwFun, .kwVal, .kwVar, .kwClass, .kwInterface, .kwEnum,
             .kwObject, .kwActor, .kwView, .kwNavigation, .kwTheme,
             .kwTypealias, .kwData, .kwSealed, .kwAbstract, .kwOpen,
             .kwPublic, .kwPrivate, .kwInternal, .kwProtected,
             .kwOverride, .kwSuspend, .kwAsync, .kwCompanion, .at:
            return true
        default:
            return false
        }
    }

    // MARK: - Object Declaration

    private func parseObjectDecl(annotations: [Annotation],
                                 modifiers: Set<Modifier>) -> ObjectDecl {
        let start = expect(.kwObject, "expected 'object'")
        skipNewlines()
        let name = expectIdentifier("expected object name")
        let (superTypes, superCallArgs) = parseInheritanceClause()
        skipNewlines()
        var members: [Declaration] = []
        if check(.leftBrace) {
            members = parseClassBody()
        }
        return ObjectDecl(annotations: annotations, modifiers: modifiers, name: name,
                          superTypes: superTypes, superCallArgs: superCallArgs,
                          members: members, span: spanFrom(start))
    }

    // MARK: - Companion Object Declaration

    private func parseCompanionObjectDecl(annotations: [Annotation],
                                          modifiers: Set<Modifier>) -> ObjectDecl {
        let start = expect(.kwCompanion, "expected 'companion'")
        skipNewlines()
        expect(.kwObject, "expected 'object' after 'companion'")
        skipNewlines()
        // Companion objects may optionally have a name
        var name = "Companion"
        if let ident = checkIdentifier() {
            name = ident
            advance()
        }
        let (superTypes, superCallArgs) = parseInheritanceClause()
        skipNewlines()
        var members: [Declaration] = []
        if check(.leftBrace) {
            members = parseClassBody()
        }
        return ObjectDecl(annotations: annotations, modifiers: modifiers, name: name,
                          isCompanion: true,
                          superTypes: superTypes, superCallArgs: superCallArgs,
                          members: members, span: spanFrom(start))
    }

    // MARK: - Actor Declaration

    private func parseActorDecl(annotations: [Annotation]) -> ActorDecl {
        let start = expect(.kwActor, "expected 'actor'")
        skipNewlines()
        let name = expectIdentifier("expected actor name")
        skipNewlines()
        var members: [Declaration] = []
        if check(.leftBrace) {
            members = parseClassBody()
        }
        return ActorDecl(annotations: annotations, name: name,
                         members: members, span: spanFrom(start))
    }

    // MARK: - View Declaration

    private func parseViewDecl(annotations: [Annotation]) -> ViewDecl {
        let start = expect(.kwView, "expected 'view'")
        skipNewlines()
        let name = expectIdentifier("expected view name")
        expect(.leftParen, "expected '(' after view name")
        parenDepth += 1
        let params = parseParameterList()
        parenDepth -= 1
        expect(.rightParen, "expected ')' after view parameters")
        skipNewlines()
        let body = parseBlock()
        return ViewDecl(annotations: annotations, name: name,
                        parameters: params, body: body, span: spanFrom(start))
    }

    // MARK: - Navigation Declaration

    private func parseNavigationDecl() -> NavigationDecl {
        let start = expect(.kwNavigation, "expected 'navigation'")
        skipNewlines()
        let name = expectIdentifier("expected navigation name")
        skipNewlines()
        let body = parseBlock()
        return NavigationDecl(name: name, body: body, span: spanFrom(start))
    }

    // MARK: - Theme Declaration

    private func parseThemeDecl() -> ThemeDecl {
        let start = expect(.kwTheme, "expected 'theme'")
        skipNewlines()
        let name = expectIdentifier("expected theme name")
        skipNewlines()
        let body = parseBlock()
        return ThemeDecl(name: name, body: body, span: spanFrom(start))
    }

    // MARK: - Type Alias Declaration

    private func parseTypeAliasDecl() -> TypeAliasDecl {
        let start = expect(.kwTypealias, "expected 'typealias'")
        skipNewlines()
        let name = expectIdentifier("expected type alias name")
        let typeParams = parseTypeParameterList()
        expect(.equal, "expected '=' in type alias")
        skipNewlines()
        let type = parseType()
        return TypeAliasDecl(name: name, typeParameters: typeParams,
                             type: type, span: spanFrom(start))
    }

    // MARK: - Type Parsing

    private func parseType() -> TypeNode {
        let start = peek()
        var type: TypeNode

        if check(.leftParen) {
            // Could be function type or tuple type
            type = parseFunctionOrTupleType()
        } else {
            let name = expectIdentifier("expected type name")
            var typeArgs: [TypeNode] = []
            if check(.less) {
                if let args = tryParseTypeArguments() {
                    typeArgs = args
                }
            }
            type = .simple(name: name, typeArguments: typeArgs, span: spanFrom(start))

            // Qualified type: Result.Success
            while match(.dot) {
                let member = expectIdentifier("expected type member name")
                type = .qualified(base: type, member: member, span: spanFrom(start))
            }
        }

        // Nullable: Type?
        if match(.question) {
            type = .nullable(type, span: spanFrom(start))
        }

        return type
    }

    private func parseFunctionOrTupleType() -> TypeNode {
        let start = peek()
        let saved = save()

        // Try parsing as function type: (Type, Type) -> ReturnType
        advance() // consume (
        parenDepth += 1
        var paramTypes: [TypeNode] = []
        skipNewlines()
        if !check(.rightParen) {
            paramTypes.append(parseType())
            while match(.comma) {
                skipNewlines()
                paramTypes.append(parseType())
            }
        }
        skipNewlines()
        parenDepth -= 1
        if match(.rightParen) {
            skipNewlines()
            if match(.arrow) {
                skipNewlines()
                let returnType = parseType()
                return .function(parameterTypes: paramTypes, returnType: returnType,
                                 span: spanFrom(start))
            }
        }

        // Not a function type — restore and treat as parenthesized/tuple
        restore(saved)
        advance() // consume (
        parenDepth += 1
        var elements: [TypeNode] = []
        skipNewlines()
        if !check(.rightParen) {
            elements.append(parseType())
            while match(.comma) {
                skipNewlines()
                elements.append(parseType())
            }
        }
        skipNewlines()
        parenDepth -= 1
        expect(.rightParen, "expected ')' in type")

        if elements.count == 1 {
            return elements[0]
        }
        return .tuple(elements: elements, span: spanFrom(start))
    }

    /// Try to parse `<Type, Type, ...>`. Returns nil and restores position on failure.
    /// Suppresses diagnostics during speculation.
    private func tryParseTypeArguments() -> [TypeNode]? {
        let saved = save()
        let diagCount = diagnostics.diagnostics.count
        guard match(.less) else { return nil }
        skipNewlines()

        // Quick check: if next token can't start a type, bail early
        if checkIdentifier() == nil && !check(.leftParen) && softKeywordAsIdentifier() == nil {
            restore(saved)
            diagnostics.truncate(to: diagCount)
            return nil
        }

        var args: [TypeNode] = []
        args.append(parseType())
        while match(.comma) {
            skipNewlines()
            args.append(parseType())
        }
        skipNewlines()
        guard match(.greater) else {
            restore(saved)
            diagnostics.truncate(to: diagCount)
            return nil
        }
        return args
    }

    private func parseTypeParameterList() -> [TypeParameter] {
        guard match(.less) else { return [] }
        skipNewlines()
        var params: [TypeParameter] = []
        params.append(parseTypeParameter())
        while match(.comma) {
            skipNewlines()
            params.append(parseTypeParameter())
        }
        skipNewlines()
        expect(.greater, "expected '>' to close type parameters")
        return params
    }

    private func parseTypeParameter() -> TypeParameter {
        let start = peek()
        var variance: Variance? = nil
        if check(.kwOut) { variance = .out; advance() }
        else if check(.kwIn) { variance = .in; advance() }
        let name = expectIdentifier("expected type parameter name")
        var upperBound: TypeNode? = nil
        if match(.colon) {
            skipNewlines()
            upperBound = parseType()
        }
        return TypeParameter(variance: variance, name: name, upperBound: upperBound,
                             span: spanFrom(start))
    }

    // MARK: - Blocks & Statements

    private func parseBlock() -> Block {
        let start = expect(.leftBrace, "expected '{'")
        skipNewlines()
        var statements: [Statement] = []
        while !check(.rightBrace) && !check(.eof) {
            skipNewlines()
            if check(.rightBrace) || check(.eof) { break }
            statements.append(parseStatement())
            consumeStatementTerminator()
        }
        expect(.rightBrace, "expected '}'")
        return Block(statements: statements, span: spanFrom(start))
    }

    private func consumeStatementTerminator() {
        // Consume newlines, semicolons, or allow implicit termination before } or EOF
        if check(.newline) || check(.semicolon) {
            while check(.newline) || check(.semicolon) { advance() }
        }
        // It's ok to be at } or EOF without explicit terminator
    }

    private func parseStatement() -> Statement {
        skipNewlines()

        switch currentKind {
        case .kwVal:
            // Check for destructuring: val (a, b) = expr
            if peekNext().kind == .leftParen {
                return .destructuringDecl(parseDestructuringDecl())
            }
            return .propertyDecl(parsePropertyDecl(annotations: [], modifiers: [], isVal: true))
        case .kwVar:
            return .propertyDecl(parsePropertyDecl(annotations: [], modifiers: [], isVal: false))
        case .kwReturn:
            return parseReturnStmt()
        case .kwBreak:
            let tok = advance()
            return .breakStmt(tok.span)
        case .kwContinue:
            let tok = advance()
            return .continueStmt(tok.span)
        case .kwThrow:
            let start = advance()
            let expr = parseExpression()
            return .throwStmt(expr, spanFrom(start))
        case .kwTry:
            return .tryCatch(parseTryCatch())
        case .kwFor:
            return .forLoop(parseForLoop())
        case .kwWhile:
            return .whileLoop(parseWhileLoop())
        case .kwDo:
            return .doWhileLoop(parseDoWhileLoop())
        default:
            // Check for modifiers/annotations that indicate a nested declaration
            if isDeclarationStart() || check(.at) {
                let annotations = parseAnnotations()
                let modifiers = parseModifiers()
                skipNewlines()
                if let decl = tryParseDeclaration(annotations: annotations, modifiers: modifiers) {
                    return .declaration(decl)
                }
            }
            // Expression or assignment
            return parseExpressionOrAssignment()
        }
    }

    private func parseReturnStmt() -> Statement {
        let start = expect(.kwReturn, "expected 'return'")
        // Return value is optional — if next token is newline/}/EOF, no value
        if check(.newline) || check(.rightBrace) || check(.eof) || check(.semicolon) {
            return .returnStmt(nil, start.span)
        }
        let expr = parseExpression()
        return .returnStmt(expr, spanFrom(start))
    }

    private func parseForLoop() -> ForLoop {
        let start = expect(.kwFor, "expected 'for'")
        expect(.leftParen, "expected '(' after 'for'")
        parenDepth += 1

        // Check for destructuring pattern: for ((k, v) in expr)
        if check(.leftParen) {
            advance() // consume inner '('
            var destructured: [String] = []
            destructured.append(expectIdentifier("expected destructured variable name"))
            while match(.comma) {
                skipNewlines()
                destructured.append(expectIdentifier("expected destructured variable name"))
            }
            expect(.rightParen, "expected ')' after destructured variables")
            skipNewlines()
            expect(.kwIn, "expected 'in'")
            let iterable = parseExpression()
            parenDepth -= 1
            expect(.rightParen, "expected ')' after for clause")
            skipNewlines()
            let body = parseBlock()
            return ForLoop(destructuredVariables: destructured, iterable: iterable,
                           body: body, span: spanFrom(start))
        }

        let variable = expectIdentifier("expected loop variable")
        expect(.kwIn, "expected 'in'")
        let iterable = parseExpression()
        parenDepth -= 1
        expect(.rightParen, "expected ')' after for clause")
        skipNewlines()
        let body = parseBlock()
        return ForLoop(variable: variable, iterable: iterable,
                       body: body, span: spanFrom(start))
    }

    private func parseWhileLoop() -> WhileLoop {
        let start = expect(.kwWhile, "expected 'while'")
        expect(.leftParen, "expected '(' after 'while'")
        parenDepth += 1
        let condition = parseExpression()
        parenDepth -= 1
        expect(.rightParen, "expected ')' after while condition")
        skipNewlines()
        let body = parseBlock()
        return WhileLoop(condition: condition, body: body, span: spanFrom(start))
    }

    private func parseDoWhileLoop() -> DoWhileLoop {
        let start = expect(.kwDo, "expected 'do'")
        skipNewlines()
        let body = parseBlock()
        skipNewlines()
        expect(.kwWhile, "expected 'while' after do block")
        expect(.leftParen, "expected '('")
        parenDepth += 1
        let condition = parseExpression()
        parenDepth -= 1
        expect(.rightParen, "expected ')'")
        return DoWhileLoop(body: body, condition: condition, span: spanFrom(start))
    }

    private func parseExpressionOrAssignment() -> Statement {
        let expr = parseExpression()
        // Check for assignment operators
        if let op = assignmentOp(currentKind) {
            advance()
            skipNewlines()
            let value = parseExpression()
            let assignSpan: SourceSpan
            switch expr {
            case .identifier(_, let s): assignSpan = span(from: s.start, to: previous().span.end)
            case .memberAccess(_, _, let s): assignSpan = span(from: s.start, to: previous().span.end)
            case .subscriptAccess(_, _, let s): assignSpan = span(from: s.start, to: previous().span.end)
            default: assignSpan = span(from: exprSpan(expr).start, to: previous().span.end)
            }
            return .assignment(AssignmentStmt(target: expr, op: op,
                                              value: value, span: assignSpan))
        }
        return .expression(expr)
    }

    private func assignmentOp(_ kind: TokenKind) -> AssignmentOp? {
        switch kind {
        case .equal:        return .assign
        case .plusEqual:    return .plusAssign
        case .minusEqual:  return .minusAssign
        case .starEqual:   return .timesAssign
        case .slashEqual:  return .divideAssign
        case .percentEqual: return .moduloAssign
        default:            return nil
        }
    }

    // MARK: - Expression Parsing (Pratt)

    /// Parse an expression with the given minimum binding power.
    private func parseExpression(minPrecedence: Int = 0) -> Expression {
        var left = parsePrefixExpression()

        while true {
            // Handle newlines carefully
            if check(.newline) && parenDepth == 0 && bracketDepth == 0 {
                // Look past newlines to see if next real token continues the expression
                let saved = save()
                skipNewlines()
                let nextKind = currentKind
                if isContinuationToken(nextKind) {
                    // Continue parsing — leave position past newlines
                } else if isInfixOperator(nextKind) {
                    // Binary operator on next line is NOT a continuation in Rockit
                    restore(saved)
                    break
                } else {
                    restore(saved)
                    break
                }
            }

            // Elvis operator ?:
            if check(.questionColon) {
                let prec = 2
                if prec < minPrecedence { break }
                advance()
                skipNewlines()
                let right = parseExpression(minPrecedence: prec + 1)
                left = .elvis(left: left, right: right,
                              span: span(from: exprSpan(left).start, to: exprSpan(right).end))
                continue
            }

            // Type check: `is` operator
            if check(.kwIs) {
                let prec = 6
                if prec < minPrecedence { break }
                advance()
                skipNewlines()
                let type = parseType()
                left = .typeCheck(left, type,
                                  span: span(from: exprSpan(left).start, to: previous().span.end))
                continue
            }

            // Type cast: `as` operator
            if check(.kwAs) {
                let prec = 6
                if prec < minPrecedence { break }
                advance()
                // Check for safe cast: as?
                if match(.question) {
                    skipNewlines()
                    let type = parseType()
                    left = .safeCast(left, type,
                                     span: span(from: exprSpan(left).start, to: previous().span.end))
                } else {
                    skipNewlines()
                    let type = parseType()
                    left = .typeCast(left, type,
                                     span: span(from: exprSpan(left).start, to: previous().span.end))
                }
                continue
            }

            // Range operators
            if check(.dotDot) || check(.dotDotLess) {
                let prec = 7
                if prec < minPrecedence { break }
                let inclusive = check(.dotDot)
                advance()
                skipNewlines()
                let right = parseExpression(minPrecedence: prec + 1)
                left = .range(start: left, end: right, inclusive: inclusive,
                              span: span(from: exprSpan(left).start, to: exprSpan(right).end))
                continue
            }

            // Standard binary operators
            if let (op, prec) = binaryOpInfo(currentKind) {
                if prec < minPrecedence { break }
                advance()
                skipNewlines()
                let right = parseExpression(minPrecedence: prec + 1)
                left = .binary(left: left, op: op, right: right,
                               span: span(from: exprSpan(left).start, to: exprSpan(right).end))
                continue
            }

            break
        }

        return left
    }

    private func isInfixOperator(_ kind: TokenKind) -> Bool {
        switch kind {
        case .plus, .minus, .star, .slash, .percent,
             .equalEqual, .bangEqual, .less, .lessEqual, .greater, .greaterEqual,
             .ampAmp, .pipePipe, .questionColon, .dotDot, .dotDotLess,
             .kwIs, .kwAs:
            return true
        default:
            return false
        }
    }

    /// Returns (BinaryOp, precedence) for a token kind, or nil.
    private func binaryOpInfo(_ kind: TokenKind) -> (BinaryOp, Int)? {
        switch kind {
        case .pipePipe:    return (.or, 3)
        case .ampAmp:      return (.and, 4)
        case .equalEqual:  return (.equalEqual, 5)
        case .bangEqual:   return (.notEqual, 5)
        case .less:        return (.less, 6)
        case .lessEqual:   return (.lessEqual, 6)
        case .greater:     return (.greater, 6)
        case .greaterEqual: return (.greaterEqual, 6)
        case .plus:        return (.plus, 8)
        case .minus:       return (.minus, 8)
        case .star:        return (.times, 9)
        case .slash:       return (.divide, 9)
        case .percent:     return (.modulo, 9)
        default:           return nil
        }
    }

    // MARK: - Prefix Expression

    private func parsePrefixExpression() -> Expression {
        switch currentKind {
        case .minus:
            let start = advance()
            let operand = parsePrefixExpression()
            return .unaryPrefix(op: .negate, operand: operand,
                                span: span(from: start.span.start, to: exprSpan(operand).end))
        case .bang:
            let start = advance()
            let operand = parsePrefixExpression()
            return .unaryPrefix(op: .not, operand: operand,
                                span: span(from: start.span.start, to: exprSpan(operand).end))
        case .kwAwait:
            let start = advance()
            let operand = parsePrefixExpression()
            return .awaitExpr(operand,
                              span: span(from: start.span.start, to: exprSpan(operand).end))
        default:
            return parsePostfixExpression()
        }
    }

    // MARK: - Postfix Expression

    private func parsePostfixExpression() -> Expression {
        var expr = parsePrimaryExpression()

        loop: while true {
            switch currentKind {
            case .dot:
                advance()
                let member = expectMemberName("expected member name after '.'")
                expr = .memberAccess(object: expr, member: member,
                                     span: span(from: exprSpan(expr).start, to: previous().span.end))

            case .questionDot:
                advance()
                let member = expectMemberName("expected member name after '?.'")
                expr = .nullSafeMemberAccess(object: expr, member: member,
                                             span: span(from: exprSpan(expr).start, to: previous().span.end))

            case .bangBang:
                advance()
                expr = .nonNullAssert(expr,
                                      span: span(from: exprSpan(expr).start, to: previous().span.end))

            case .leftParen:
                let args = parseCallArgumentList()
                let trailing = parseOptionalTrailingLambda()
                expr = .call(callee: expr, arguments: args, trailingLambda: trailing,
                             span: span(from: exprSpan(expr).start, to: previous().span.end))

            case .leftBracket:
                advance()
                bracketDepth += 1
                skipNewlines()
                let index = parseExpression()
                skipNewlines()
                bracketDepth -= 1
                expect(.rightBracket, "expected ']'")
                expr = .subscriptAccess(object: expr, index: index,
                                        span: span(from: exprSpan(expr).start, to: previous().span.end))

            case .leftBrace:
                // Trailing lambda only if no newline between call and brace
                // Check if previous token was on same line or one newline away
                if canBeTrailingLambda() {
                    let lambda = parseLambdaExpression()
                    expr = .call(callee: expr, arguments: [], trailingLambda: lambda,
                                 span: span(from: exprSpan(expr).start, to: previous().span.end))
                } else {
                    break loop
                }

            case .less:
                // Try generic type arguments on call: decode<User>()
                let saved = save()
                if tryParseTypeArguments() != nil {
                    if check(.leftParen) {
                        // It's a generic call like decode<User>()
                        let args = parseCallArgumentList()
                        let trailing = parseOptionalTrailingLambda()
                        // Encode type args in the callee as a member with type info
                        // For now, wrap as a call with type args ignored at AST level
                        expr = .call(callee: expr, arguments: args, trailingLambda: trailing,
                                     span: span(from: exprSpan(expr).start, to: previous().span.end))
                    } else {
                        restore(saved)
                        break loop
                    }
                } else {
                    break loop
                }

            case .newline:
                // Check for continuation on next line
                let saved = save()
                skipNewlines()
                if currentKind == .dot || currentKind == .questionDot {
                    // Continue the chain
                    continue
                }
                restore(saved)
                break loop

            default:
                break loop
            }
        }

        return expr
    }

    private func canBeTrailingLambda() -> Bool {
        // A trailing lambda `{` must be on the same line as the preceding expression
        guard check(.leftBrace) else { return false }
        // Check that there's no newline between the previous token and the `{`
        if current > 0 {
            let prev = tokens[current - 1]
            // If previous token is newline, this is NOT a trailing lambda
            if prev.kind == .newline { return false }
            switch prev.kind {
            case .rightParen, .identifier:
                return true
            default:
                // Also allow keywords used as identifiers
                if memberKeywordName() != nil { return true }
                return false
            }
        }
        return false
    }

    private func parseOptionalTrailingLambda() -> LambdaExpr? {
        // Skip newlines and check for trailing lambda
        if check(.leftBrace) {
            return parseLambdaExpression()
        }
        return nil
    }

    // MARK: - Primary Expression

    /// Check if the current keyword can be used as an identifier in expression context
    private func keywordAsIdentifier() -> String? {
        switch currentKind {
        case .kwRoute: return "route"
        case .kwStyle: return "style"
        case .kwInit: return "init"
        case .kwConstructor: return "constructor"
        default: return nil
        }
    }

    private func parsePrimaryExpression() -> Expression {
        let start = peek()

        if let v = checkIntLiteral() {
            advance()
            return .intLiteral(v, start.span)
        }
        if let v = checkFloatLiteral() {
            advance()
            return .floatLiteral(v, start.span)
        }
        if let v = checkBoolLiteral() {
            advance()
            return .boolLiteral(v, start.span)
        }
        if check(.nullLiteral) {
            advance()
            return .nullLiteral(start.span)
        }
        if let s = checkStringLiteral() {
            return parseStringExpression(s)
        }
        if let name = checkIdentifier() {
            advance()
            return .identifier(name, start.span)
        }
        // Allow certain keywords to be used as identifiers in expression context
        if let name = keywordAsIdentifier() {
            advance()
            return .identifier(name, start.span)
        }

        switch currentKind {
        case .kwThis:
            advance()
            return .this(start.span)
        case .kwSuper:
            advance()
            return .super(start.span)
        case .kwIf:
            return .ifExpr(parseIfExpression())
        case .kwWhen:
            return .whenExpr(parseWhenExpression())
        case .kwTry:
            return parseTryExpression()
        case .leftParen:
            return parseParenExpression()
        case .leftBrace:
            return .lambda(parseLambdaExpression())
        case .kwConcurrent:
            advance()
            let body = parseBlock()
            return .concurrentBlock(body: body.statements,
                                    span: span(from: start.span.start, to: body.span.end))
        case .dot:
            // Enum shorthand: .primary, .headline
            advance()
            let member = expectMemberName("expected name after '.'")
            return .memberAccess(object: .identifier("", start.span), member: member,
                                 span: spanFrom(start))
        default:
            diagnostics.error("expected expression", at: start.span.start)
            advance()
            return .error(start.span)
        }
    }

    // MARK: - String Interpolation

    private func parseStringExpression(_ rawValue: String) -> Expression {
        let start = advance() // consume string token

        // Check if string contains interpolation markers
        guard rawValue.contains("$") else {
            return .stringLiteral(rawValue, start.span)
        }

        let parts = splitInterpolation(rawValue)
        // If no interpolation was found ($ was escaped or not valid)
        if parts.count == 1, case .literal = parts[0] {
            return .stringLiteral(rawValue, start.span)
        }

        var stringParts: [StringPart] = []
        for part in parts {
            switch part {
            case .literal(let s):
                stringParts.append(.literal(s))
            case .interpolation(let code):
                let subDiag = DiagnosticEngine()
                let subLexer = Lexer(source: code, diagnostics: subDiag)
                let subTokens = subLexer.tokenize()
                let subParser = Parser(tokens: subTokens, diagnostics: diagnostics)
                let expr = subParser.parseExpression()
                stringParts.append(.interpolation(expr))
            }
        }

        return .interpolatedString(stringParts, start.span)
    }

    private enum RawStringPart {
        case literal(String)
        case interpolation(String)
    }

    private func splitInterpolation(_ s: String) -> [RawStringPart] {
        var parts: [RawStringPart] = []
        var current = ""
        var i = s.startIndex

        while i < s.endIndex {
            let c = s[i]
            if c == "$" {
                let next = s.index(after: i)
                if next < s.endIndex && s[next] == "{" {
                    // ${expression}
                    if !current.isEmpty {
                        parts.append(.literal(current))
                        current = ""
                    }
                    // Find matching }
                    var depth = 1
                    var j = s.index(after: next)
                    var exprStr = ""
                    while j < s.endIndex && depth > 0 {
                        if s[j] == "{" { depth += 1 }
                        else if s[j] == "}" { depth -= 1; if depth == 0 { break } }
                        exprStr.append(s[j])
                        j = s.index(after: j)
                    }
                    parts.append(.interpolation(exprStr))
                    if j < s.endIndex { j = s.index(after: j) }
                    i = j
                    continue
                } else if next < s.endIndex && (s[next].isLetter || s[next] == "_") {
                    // $identifier
                    if !current.isEmpty {
                        parts.append(.literal(current))
                        current = ""
                    }
                    var j = next
                    var ident = ""
                    while j < s.endIndex && (s[j].isLetter || s[j].isNumber || s[j] == "_") {
                        ident.append(s[j])
                        j = s.index(after: j)
                    }
                    parts.append(.interpolation(ident))
                    i = j
                    continue
                } else {
                    // Literal $
                    current.append(c)
                }
            } else {
                current.append(c)
            }
            i = s.index(after: i)
        }

        if !current.isEmpty {
            parts.append(.literal(current))
        }
        return parts
    }

    // MARK: - Call Arguments

    private func parseCallArgumentList() -> [CallArgument] {
        expect(.leftParen, "expected '('")
        parenDepth += 1
        skipNewlines()
        var args: [CallArgument] = []
        if !check(.rightParen) {
            args.append(parseCallArgument())
            while match(.comma) {
                skipNewlines()
                args.append(parseCallArgument())
            }
        }
        skipNewlines()
        parenDepth -= 1
        expect(.rightParen, "expected ')'")
        return args
    }

    private func parseCallArgument() -> CallArgument {
        skipNewlines()
        let start = peek()
        // Check for named argument: `name = value`
        if let name = checkIdentifier() {
            let saved = save()
            advance()
            if match(.equal) {
                skipNewlines()
                let value = parseExpression()
                return CallArgument(label: name, value: value, span: spanFrom(start))
            }
            restore(saved)
        }
        let value = parseExpression()
        return CallArgument(label: nil, value: value, span: spanFrom(start))
    }

    // MARK: - Lambda Expression

    private func parseLambdaExpression() -> LambdaExpr {
        let start = expect(.leftBrace, "expected '{'")
        skipNewlines()

        // Try to detect `params ->` pattern
        var parameters: [Parameter] = []
        let saved = save()
        if tryParseLambdaParams(&parameters) {
            // Successfully parsed params -> ...
        } else {
            restore(saved)
            parameters = []
        }

        // Parse body statements
        var body: [Statement] = []
        while !check(.rightBrace) && !check(.eof) {
            skipNewlines()
            if check(.rightBrace) || check(.eof) { break }
            body.append(parseStatement())
            consumeStatementTerminator()
        }
        expect(.rightBrace, "expected '}'")
        return LambdaExpr(parameters: parameters, body: body, span: spanFrom(start))
    }

    /// Try to parse lambda parameters: `name ->`, `name: Type ->`, or `name: Type, name: Type ->`
    /// Returns true if successful, false otherwise.
    private func tryParseLambdaParams(_ params: inout [Parameter]) -> Bool {
        // Look for pattern: identifier [: Type] [, identifier [: Type]]* ->
        guard checkIdentifier() != nil else { return false }
        var tempParams: [Parameter] = []

        let paramStart = peek()
        let name = checkIdentifier()!
        advance()

        // Optional type annotation
        var typeNode: TypeNode? = nil
        if match(.colon) {
            skipNewlines()
            typeNode = parseType()
        }
        tempParams.append(Parameter(name: name, type: typeNode, defaultValue: nil,
                                    span: paramStart.span))

        while match(.comma) {
            skipNewlines()
            let pStart = peek()
            guard let pName = checkIdentifier() else { return false }
            advance()

            var pType: TypeNode? = nil
            if match(.colon) {
                skipNewlines()
                pType = parseType()
            }
            tempParams.append(Parameter(name: pName, type: pType, defaultValue: nil,
                                        span: pStart.span))
        }
        skipNewlines()
        guard match(.arrow) else { return false }
        skipNewlines()
        params = tempParams
        return true
    }

    // MARK: - If Expression

    private func parseIfExpression() -> IfExpr {
        let start = expect(.kwIf, "expected 'if'")
        expect(.leftParen, "expected '(' after 'if'")
        parenDepth += 1
        let condition = parseExpression()
        parenDepth -= 1
        expect(.rightParen, "expected ')' after if condition")
        skipNewlines()
        let thenBranch = parseBlock()
        skipNewlines()
        var elseBranch: ElseBranch? = nil
        if match(.kwElse) {
            skipNewlines()
            if check(.kwIf) {
                elseBranch = .elseIf(parseIfExpression())
            } else {
                elseBranch = .elseBlock(parseBlock())
            }
        }
        return IfExpr(condition: condition, thenBranch: thenBranch,
                      elseBranch: elseBranch, span: spanFrom(start))
    }

    // MARK: - When Expression

    private func parseWhenExpression() -> WhenExpr {
        let start = expect(.kwWhen, "expected 'when'")
        var subject: Expression? = nil
        if check(.leftParen) {
            advance()
            parenDepth += 1
            subject = parseExpression()
            parenDepth -= 1
            expect(.rightParen, "expected ')' after when subject")
        }
        skipNewlines()
        expect(.leftBrace, "expected '{' after when")
        skipNewlines()
        var entries: [WhenEntry] = []
        while !check(.rightBrace) && !check(.eof) {
            skipNewlines()
            if check(.rightBrace) || check(.eof) { break }
            entries.append(parseWhenEntry())
            skipNewlines()
        }
        expect(.rightBrace, "expected '}' to close when")
        return WhenExpr(subject: subject, entries: entries, span: spanFrom(start))
    }

    private func parseWhenEntry() -> WhenEntry {
        let start = peek()
        var conditions: [WhenCondition] = []

        // Handle `else ->` as a special when entry
        if check(.kwElse) {
            let elseToken = advance()
            let elseSpan = elseToken.span
            conditions.append(.expression(.identifier("else", elseSpan)))
        } else {
            conditions.append(parseWhenCondition())
            while match(.comma) {
                skipNewlines()
                conditions.append(parseWhenCondition())
            }
        }

        // Optional guard: `if condition`
        skipNewlines()
        var guardExpr: Expression? = nil
        if check(.kwIf) {
            advance()
            skipNewlines()
            guardExpr = parseExpression()
        }

        skipNewlines()
        expect(.arrow, "expected '->' in when entry")
        skipNewlines()

        let body: WhenBody
        if check(.leftBrace) {
            body = .block(parseBlock())
        } else {
            body = .expression(parseExpression())
        }

        return WhenEntry(conditions: conditions, guard_: guardExpr, body: body, span: spanFrom(start))
    }

    private func parseWhenCondition() -> WhenCondition {
        if check(.kwIs) {
            let start = advance()
            skipNewlines()
            let type = parseType()
            // Check for destructuring bindings: is Type(val a, val b)
            if check(.leftParen) {
                advance()
                var bindings: [String] = []
                while !check(.rightParen) && !check(.eof) {
                    skipNewlines()
                    if check(.kwVal) { advance() }
                    bindings.append(expectIdentifier("expected binding name"))
                    if !check(.rightParen) {
                        expect(.comma, "expected ',' between bindings")
                    }
                    skipNewlines()
                }
                expect(.rightParen, "expected ')' after bindings")
                return .isTypeWithBindings(type, bindings, spanFrom(start))
            }
            return .isType(type, spanFrom(start))
        }
        if check(.kwIn) {
            let start = advance()
            skipNewlines()
            let rangeExpr = parseExpression()
            // Range expressions are parsed as .range(start, end, inclusive, span)
            if case .range(let rangeStart, let rangeEnd, _, _) = rangeExpr {
                return .inRange(rangeStart, rangeEnd, spanFrom(start))
            }
            // If not a range, treat as a single value check
            return .expression(rangeExpr)
        }
        return .expression(parseExpression())
    }

    // MARK: - Try-Catch Statement

    private func parseTryCatch() -> TryCatch {
        let start = expect(.kwTry, "expected 'try'")
        skipNewlines()
        let tryBody = parseBlock()
        skipNewlines()
        expect(.kwCatch, "expected 'catch' after try block")
        expect(.leftParen, "expected '(' after 'catch'")
        parenDepth += 1
        let variable = expectIdentifier("expected catch variable name")
        // Skip optional type annotation (: Type)
        if check(.colon) {
            advance()
            let _ = parseType()
        }
        parenDepth -= 1
        expect(.rightParen, "expected ')' after catch clause")
        skipNewlines()
        let catchBody = parseBlock()
        skipNewlines()
        var finallyBody: Block? = nil
        if check(.kwFinally) {
            advance()
            skipNewlines()
            finallyBody = parseBlock()
        }
        return TryCatch(tryBody: tryBody, catchVariable: variable,
                        catchBody: catchBody, finallyBody: finallyBody, span: spanFrom(start))
    }

    // MARK: - Try Expression

    private func parseTryExpression() -> Expression {
        let start = expect(.kwTry, "expected 'try'")
        skipNewlines()
        // For now, treat `try` as a prefix on the next expression
        let expr = parseExpression()
        return .parenthesized(expr, span: spanFrom(start))
    }

    // MARK: - Parenthesized Expression

    private func parseParenExpression() -> Expression {
        let start = expect(.leftParen, "expected '('")
        parenDepth += 1
        skipNewlines()
        let expr = parseExpression()
        skipNewlines()
        parenDepth -= 1
        expect(.rightParen, "expected ')'")
        return .parenthesized(expr, span: spanFrom(start))
    }

    // MARK: - Helpers

    /// Get the SourceSpan from an expression
    private func exprSpan(_ expr: Expression) -> SourceSpan {
        switch expr {
        case .intLiteral(_, let s): return s
        case .floatLiteral(_, let s): return s
        case .stringLiteral(_, let s): return s
        case .interpolatedString(_, let s): return s
        case .boolLiteral(_, let s): return s
        case .nullLiteral(let s): return s
        case .identifier(_, let s): return s
        case .this(let s): return s
        case .super(let s): return s
        case .binary(_, _, _, let s): return s
        case .unaryPrefix(_, _, let s): return s
        case .unaryPostfix(_, _, let s): return s
        case .memberAccess(_, _, let s): return s
        case .nullSafeMemberAccess(_, _, let s): return s
        case .subscriptAccess(_, _, let s): return s
        case .call(_, _, _, let s): return s
        case .ifExpr(let ie): return ie.span
        case .whenExpr(let we): return we.span
        case .lambda(let le): return le.span
        case .typeCheck(_, _, let s): return s
        case .typeCast(_, _, let s): return s
        case .safeCast(_, _, let s): return s
        case .nonNullAssert(_, let s): return s
        case .awaitExpr(_, let s): return s
        case .concurrentBlock(_, let s): return s
        case .elvis(_, _, let s): return s
        case .range(_, _, _, let s): return s
        case .parenthesized(_, let s): return s
        case .error(let s): return s
        }
    }
}
