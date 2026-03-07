// TypeChecker.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - Type Check Result

/// The output of the type checker
public struct TypeCheckResult {
    public let ast: SourceFile
    public let typeMap: [ExpressionID: Type]
    public let symbolTable: SymbolTable
    public let diagnostics: DiagnosticEngine
    public let functionOverloads: [String: Set<Int>]
    /// Maps function name → index of the vararg parameter
    public let varargFunctions: [String: Int]
}

// MARK: - Type Checker

/// Two-pass type checker for Rockit.
///
/// **Pass 1** gathers all declarations (functions, properties, classes, etc.)
/// into the symbol table so that forward references work.
///
/// **Pass 2** walks expression trees, infers/checks types, enforces null safety,
/// and checks sealed-class exhaustiveness in `when` expressions.
public final class TypeChecker {
    private let ast: SourceFile
    private let diagnostics: DiagnosticEngine
    private let symbolTable: SymbolTable
    private let resolver: TypeResolver
    private var typeMap: [ExpressionID: Type] = [:]
    /// Tracks overloaded function names: baseName -> set of arities
    private var functionOverloads: [String: Set<Int>] = [:]
    /// Tracks functions with vararg parameters: funcName -> vararg param index
    private var varargFunctions: [String: Int] = [:]
    /// Tracks the current enclosing actor name (nil when outside an actor)
    private var currentActorName: String? = nil
    /// Tracks the current enclosing class name (nil when outside a class)
    private var currentClassName: String? = nil
    /// Tracks the receiver type for extension functions (e.g. "Int" for `fun Int.double()`)
    private var currentReceiverType: String? = nil
    /// Tracks whether we are inside a suspend or async function (or concurrent block)
    private var inSuspendContext: Bool = false
    /// Names of functions declared with `suspend` or `async` modifier
    private var suspendFunctions: Set<String> = []

    public init(ast: SourceFile, diagnostics: DiagnosticEngine) {
        self.ast = ast
        self.diagnostics = diagnostics
        self.symbolTable = SymbolTable()
        self.resolver = TypeResolver(symbolTable: symbolTable, diagnostics: diagnostics)
    }

    /// Run both passes and return the result.
    public func check() -> TypeCheckResult {
        // Pass 1: gather declarations
        for decl in ast.declarations {
            gatherDeclaration(decl)
        }

        // Pass 2: check bodies and expressions
        for decl in ast.declarations {
            checkDeclaration(decl)
        }

        return TypeCheckResult(
            ast: ast,
            typeMap: typeMap,
            symbolTable: symbolTable,
            diagnostics: diagnostics,
            functionOverloads: functionOverloads,
            varargFunctions: varargFunctions
        )
    }

    // MARK: - Pass 1: Declaration Gathering

    private func gatherDeclaration(_ decl: Declaration) {
        switch decl {
        case .function(let f):
            gatherFunction(f)
        case .property(let p):
            gatherProperty(p)
        case .classDecl(let c):
            gatherClass(c)
        case .interfaceDecl(let i):
            gatherInterface(i)
        case .enumDecl(let e):
            gatherEnum(e)
        case .objectDecl(let o):
            gatherObject(o)
        case .actorDecl(let a):
            gatherActor(a)
        case .viewDecl(let v):
            gatherView(v)
        case .navigationDecl(let n):
            gatherNavigation(n)
        case .themeDecl(let t):
            gatherTheme(t)
        case .typeAlias(let ta):
            gatherTypeAlias(ta)
        }
    }

    private func gatherFunction(_ f: FunctionDecl) {
        // Temporarily register type parameters so param/return types can resolve
        if !f.typeParameters.isEmpty {
            symbolTable.pushScope()
            for tp in f.typeParameters {
                let bound: Type? = tp.upperBound.map { resolver.resolve($0) }
                let tpType = Type.typeParameter(name: tp.name, bound: bound)
                symbolTable.define(Symbol(name: tp.name, type: tpType, kind: .typeParameter, span: tp.span))
            }
        }
        let paramTypes = f.parameters.map { param -> Type in
            if let typeNode = param.type {
                return resolver.resolve(typeNode)
            }
            return .error
        }
        let returnType: Type
        if let retNode = f.returnType {
            returnType = resolver.resolve(retNode)
        } else {
            returnType = .unit
        }
        if !f.typeParameters.isEmpty {
            symbolTable.popScope()
        }
        let funcType = Type.function(parameterTypes: paramTypes, returnType: returnType)
        let arity = paramTypes.count
        // Track suspend/async functions
        if f.modifiers.contains(.suspend) || f.modifiers.contains(.async) {
            suspendFunctions.insert(f.name)
        }
        // Track vararg parameter index
        if let varargIdx = f.parameters.firstIndex(where: { $0.isVararg }) {
            varargFunctions[f.name] = varargIdx
        }
        let symbol = Symbol(name: f.name, type: funcType, kind: .function, span: f.span)
        if !symbolTable.define(symbol) {
            // Check if this is a valid overload (same name, different arity)
            if let existing = symbolTable.lookup(f.name),
               case .function(let existingParams, _) = existing.type,
               existingParams.count != arity {
                // Valid overload — register under mangled name
                let mangledName = "\(f.name)$\(arity)"
                let mangledSymbol = Symbol(name: mangledName, type: funcType, kind: .function, span: f.span)
                symbolTable.define(mangledSymbol)
                // Track overloads
                if functionOverloads[f.name] == nil {
                    functionOverloads[f.name] = [existingParams.count, arity]
                } else {
                    functionOverloads[f.name]?.insert(arity)
                }
            } else {
                diagnostics.error("redeclaration of '\(f.name)'", at: f.span.start)
            }
        }
    }

    private func gatherProperty(_ p: PropertyDecl, allowRedeclaration: Bool = false) {
        let type: Type
        if let typeNode = p.type {
            type = resolver.resolve(typeNode)
        } else if p.initializer != nil {
            // Type will be inferred in pass 2
            type = .error
        } else {
            diagnostics.error("property '\(p.name)' must have a type annotation or initializer", at: p.span.start)
            type = .error
        }
        let isMutable = !p.isVal
        let symbol = Symbol(name: p.name, type: type, kind: .variable(isMutable: isMutable), span: p.span)
        if !symbolTable.define(symbol) {
            if allowRedeclaration {
                // Kotlin-style: allow rebinding val/var in the same local scope
                symbolTable.currentScope.update(symbol)
            } else {
                diagnostics.error("redeclaration of '\(p.name)'", at: p.span.start)
            }
        }
    }

    private func gatherClass(_ c: ClassDecl) {
        // Register the class as a type declaration
        let typeParamNames = c.typeParameters.map { $0.name }
        let typeParamVariances = c.typeParameters.map { $0.variance }
        let superTypeNames = c.superTypes.compactMap { superType -> String? in
            if case .simple(let name, _, _) = superType { return name }
            return nil
        }

        var info = TypeDeclInfo(
            name: c.name,
            typeParameters: typeParamNames,
            typeParameterVariances: typeParamVariances,
            superTypes: superTypeNames
        )

        // Register type parameters in a new scope for the class body
        symbolTable.pushScope()
        for tp in c.typeParameters {
            let bound: Type? = tp.upperBound.map { resolver.resolve($0) }
            let tpType = Type.typeParameter(name: tp.name, bound: bound)
            symbolTable.define(Symbol(name: tp.name, type: tpType, kind: .typeParameter, span: tp.span))
        }

        // Gather constructor parameters as members
        for param in c.constructorParams {
            if param.isVal || param.isVar {
                let paramType: Type
                if let typeNode = param.type {
                    paramType = resolver.resolve(typeNode)
                } else {
                    paramType = .error
                }
                let memberSymbol = Symbol(
                    name: param.name,
                    type: paramType,
                    kind: .variable(isMutable: param.isVar),
                    span: param.span
                )
                info.members.append(memberSymbol)
            }
        }

        // Gather members
        for member in c.members {
            gatherDeclaration(member)
            if case .function(let f) = member {
                let paramTypes = f.parameters.map { p -> Type in
                    p.type.map { resolver.resolve($0) } ?? .error
                }
                let retType = f.returnType.map { resolver.resolve($0) } ?? .unit
                let memberSym = Symbol(
                    name: f.name,
                    type: .function(parameterTypes: paramTypes, returnType: retType),
                    kind: .function,
                    span: f.span
                )
                info.members.append(memberSym)
            } else if case .property(let p) = member {
                let propType = p.type.map { resolver.resolve($0) } ?? .error
                let memberSym = Symbol(
                    name: p.name,
                    type: propType,
                    kind: .variable(isMutable: !p.isVal),
                    span: p.span
                )
                info.members.append(memberSym)
            }
        }

        symbolTable.popScope()

        symbolTable.registerType(info)

        // Track sealed subclasses: nested classes in a sealed class are subclasses
        if c.modifiers.contains(.sealed) {
            for member in c.members {
                if case .classDecl(let nested) = member {
                    symbolTable.addSealedSubclass(parent: c.name, child: nested.name)
                    // Also register the sealed parent as a supertype of the nested class
                    symbolTable.addSuperType(child: nested.name, parent: c.name)
                }
            }
        }

        // If this class has a sealed parent, register as subclass
        for superName in superTypeNames {
            if let parentInfo = symbolTable.lookupType(superName),
               !parentInfo.sealedSubclasses.isEmpty || true {
                // We don't know if parent is sealed at gather time (forward ref),
                // so we always try. The TypeDeclInfo will just accumulate subclass names.
                symbolTable.addSealedSubclass(parent: superName, child: c.name)
            }
        }

        // Register class symbol
        let classType = Type.classType(name: c.name, typeArguments: [])
        let symbol = Symbol(name: c.name, type: classType, kind: .typeDeclaration, span: c.span)
        if !symbolTable.define(symbol) {
            diagnostics.error("redeclaration of type '\(c.name)'", at: c.span.start)
        }
    }

    private func gatherInterface(_ i: InterfaceDecl) {
        let typeParamNames = i.typeParameters.map { $0.name }
        let typeParamVariances = i.typeParameters.map { $0.variance }
        let superTypeNames = i.superTypes.compactMap { st -> String? in
            if case .simple(let name, _, _) = st { return name }
            return nil
        }

        var info = TypeDeclInfo(
            name: i.name,
            typeParameters: typeParamNames,
            typeParameterVariances: typeParamVariances,
            superTypes: superTypeNames
        )

        symbolTable.pushScope()
        for tp in i.typeParameters {
            let bound: Type? = tp.upperBound.map { resolver.resolve($0) }
            let tpType = Type.typeParameter(name: tp.name, bound: bound)
            symbolTable.define(Symbol(name: tp.name, type: tpType, kind: .typeParameter, span: tp.span))
        }

        for member in i.members {
            gatherDeclaration(member)
            if case .function(let f) = member {
                let paramTypes = f.parameters.map { p -> Type in
                    p.type.map { resolver.resolve($0) } ?? .error
                }
                let retType = f.returnType.map { resolver.resolve($0) } ?? .unit
                info.members.append(Symbol(
                    name: f.name,
                    type: .function(parameterTypes: paramTypes, returnType: retType),
                    kind: .function,
                    span: f.span
                ))
                if f.body != nil {
                    info.defaultMethods.insert(f.name)
                }
            } else if case .property(let p) = member {
                let propType = p.type.map { resolver.resolve($0) } ?? .error
                info.members.append(Symbol(
                    name: p.name,
                    type: propType,
                    kind: .variable(isMutable: !p.isVal),
                    span: p.span
                ))
            }
        }

        symbolTable.popScope()
        symbolTable.registerType(info)

        let ifaceType = Type.interfaceType(name: i.name, typeArguments: [])
        let symbol = Symbol(name: i.name, type: ifaceType, kind: .typeDeclaration, span: i.span)
        if !symbolTable.define(symbol) {
            diagnostics.error("redeclaration of type '\(i.name)'", at: i.span.start)
        }
    }

    private func gatherEnum(_ e: EnumClassDecl) {
        let entryNames = e.entries.map { $0.name }
        var info = TypeDeclInfo(
            name: e.name,
            typeParameters: e.typeParameters.map { $0.name },
            enumEntries: entryNames
        )

        // Gather members
        for member in e.members {
            gatherDeclaration(member)
            if case .function(let f) = member {
                let paramTypes = f.parameters.map { p -> Type in
                    p.type.map { resolver.resolve($0) } ?? .error
                }
                let retType = f.returnType.map { resolver.resolve($0) } ?? .unit
                info.members.append(Symbol(
                    name: f.name,
                    type: .function(parameterTypes: paramTypes, returnType: retType),
                    kind: .function,
                    span: f.span
                ))
            }
        }

        symbolTable.registerType(info)

        // Register enum entries as symbols
        let enumType = Type.enumType(name: e.name)
        for entry in e.entries {
            symbolTable.define(Symbol(name: entry.name, type: enumType, kind: .enumEntry, span: entry.span))
        }

        let symbol = Symbol(name: e.name, type: enumType, kind: .typeDeclaration, span: e.span)
        if !symbolTable.define(symbol) {
            diagnostics.error("redeclaration of type '\(e.name)'", at: e.span.start)
        }
    }

    private func gatherObject(_ o: ObjectDecl) {
        var info = TypeDeclInfo(name: o.name)
        for member in o.members {
            gatherDeclaration(member)
            if case .property(let p) = member {
                let propType = p.type.map { resolver.resolve($0) } ?? .error
                info.members.append(Symbol(
                    name: p.name, type: propType,
                    kind: .variable(isMutable: !p.isVal), span: p.span
                ))
            } else if case .function(let f) = member {
                let paramTypes = f.parameters.map { p -> Type in
                    p.type.map { resolver.resolve($0) } ?? .error
                }
                let retType = f.returnType.map { resolver.resolve($0) } ?? .unit
                info.members.append(Symbol(
                    name: f.name,
                    type: .function(parameterTypes: paramTypes, returnType: retType),
                    kind: .function, span: f.span
                ))
            }
        }
        symbolTable.registerType(info)

        let objType = Type.objectType(name: o.name)
        let symbol = Symbol(name: o.name, type: objType, kind: .typeDeclaration, span: o.span)
        if !symbolTable.define(symbol) {
            diagnostics.error("redeclaration of type '\(o.name)'", at: o.span.start)
        }
    }

    private func gatherActor(_ a: ActorDecl) {
        var info = TypeDeclInfo(name: a.name)
        for member in a.members {
            gatherDeclaration(member)
            if case .property(let p) = member {
                let propType = p.type.map { resolver.resolve($0) } ?? .error
                info.members.append(Symbol(
                    name: p.name, type: propType,
                    kind: .variable(isMutable: !p.isVal), span: p.span
                ))
            } else if case .function(let f) = member {
                let paramTypes = f.parameters.map { p -> Type in
                    p.type.map { resolver.resolve($0) } ?? .error
                }
                let retType = f.returnType.map { resolver.resolve($0) } ?? .unit
                info.members.append(Symbol(
                    name: f.name,
                    type: .function(parameterTypes: paramTypes, returnType: retType),
                    kind: .function, span: f.span
                ))
            }
        }
        symbolTable.registerType(info)

        let actorType = Type.actorType(name: a.name)
        let symbol = Symbol(name: a.name, type: actorType, kind: .typeDeclaration, span: a.span)
        if !symbolTable.define(symbol) {
            diagnostics.error("redeclaration of type '\(a.name)'", at: a.span.start)
        }
    }

    private func gatherView(_ v: ViewDecl) {
        // Views are compiled as functions — register as function symbol
        let paramTypes = v.parameters.map { p -> Type in
            p.type.map { resolver.resolve($0) } ?? .error
        }
        let funcType = Type.function(parameterTypes: paramTypes, returnType: .unit)
        let symbol = Symbol(name: v.name, type: funcType, kind: .function, span: v.span)
        if !symbolTable.define(symbol) {
            diagnostics.error("redeclaration of '\(v.name)'", at: v.span.start)
        }
    }

    private func gatherNavigation(_ n: NavigationDecl) {
        // Navigations are compiled as parameterless functions
        let funcType = Type.function(parameterTypes: [], returnType: .unit)
        let symbol = Symbol(name: n.name, type: funcType, kind: .function, span: n.span)
        if !symbolTable.define(symbol) {
            diagnostics.error("redeclaration of '\(n.name)'", at: n.span.start)
        }
    }

    private func gatherTheme(_ t: ThemeDecl) {
        // Themes are compiled as parameterless functions
        let funcType = Type.function(parameterTypes: [], returnType: .unit)
        let symbol = Symbol(name: t.name, type: funcType, kind: .function, span: t.span)
        if !symbolTable.define(symbol) {
            diagnostics.error("redeclaration of '\(t.name)'", at: t.span.start)
        }
    }

    private func gatherTypeAlias(_ ta: TypeAliasDecl) {
        let aliasedType = resolver.resolve(ta.type)
        let symbol = Symbol(name: ta.name, type: aliasedType, kind: .typeAlias, span: ta.span)
        if !symbolTable.define(symbol) {
            diagnostics.error("redeclaration of type '\(ta.name)'", at: ta.span.start)
        }
        symbolTable.registerType(TypeDeclInfo(name: ta.name))
    }

    // MARK: - Pass 2: Type Checking

    private func checkDeclaration(_ decl: Declaration) {
        switch decl {
        case .function(let f):
            checkFunction(f)
        case .property(let p):
            checkProperty(p)
        case .classDecl(let c):
            checkClass(c)
        case .interfaceDecl(let i):
            checkInterface(i)
        case .enumDecl(let e):
            checkEnumClass(e)
        case .objectDecl(let o):
            checkObject(o)
        case .actorDecl(let a):
            checkActor(a)
        case .viewDecl(let v):
            checkView(v)
        case .navigationDecl(let n):
            checkNavigation(n)
        case .themeDecl(let t):
            checkTheme(t)
        case .typeAlias:
            break // Already resolved in pass 1
        }
    }

    private func checkFunction(_ f: FunctionDecl) {
        symbolTable.pushScope()

        // Track suspend context
        let previousSuspendContext = inSuspendContext
        if f.modifiers.contains(.suspend) || f.modifiers.contains(.async) {
            inSuspendContext = true
        }

        // Track receiver type for extension functions (e.g. fun Int.double())
        let previousReceiverType = currentReceiverType
        if let receiver = f.receiverType {
            currentReceiverType = receiver
        }

        // Register type parameters
        for tp in f.typeParameters {
            let bound: Type? = tp.upperBound.map { resolver.resolve($0) }
            let tpType = Type.typeParameter(name: tp.name, bound: bound)
            symbolTable.define(Symbol(name: tp.name, type: tpType, kind: .typeParameter, span: tp.span))
        }

        // Register parameters
        for param in f.parameters {
            let paramType: Type
            if let typeNode = param.type {
                paramType = resolver.resolve(typeNode)
            } else {
                paramType = .error
            }
            symbolTable.define(Symbol(name: param.name, type: paramType, kind: .parameter, span: param.span))

            // Check default value
            if let defaultVal = param.defaultValue {
                let defaultType = checkExpression(defaultVal)
                if !paramType.isError && !defaultType.isError {
                    if !typesCompatible(source: defaultType, target: paramType) {
                        diagnostics.error(
                            "default value of type '\(defaultType)' is not compatible with parameter type '\(paramType)'",
                            at: param.span.start
                        )
                    }
                }
            }
        }

        // Check body
        if let body = f.body {
            switch body {
            case .block(let block):
                checkBlock(block)
            case .expression(let expr):
                let _ = checkExpression(expr)
            }
        }

        inSuspendContext = previousSuspendContext
        currentReceiverType = previousReceiverType
        symbolTable.popScope()
    }

    private func checkProperty(_ p: PropertyDecl) {
        guard let initializer = p.initializer else { return }

        let initType = checkExpression(initializer)

        if let typeNode = p.type {
            let declaredType = resolver.resolve(typeNode)
            if !declaredType.isError && !initType.isError {
                if !typesCompatible(source: initType, target: declaredType) {
                    diagnostics.error(
                        "cannot assign '\(initType)' to '\(declaredType)'",
                        at: p.span.start
                    )
                }
            }
        } else {
            // Infer type from initializer — update symbol table
            if !initType.isError {
                let updatedSymbol = Symbol(
                    name: p.name,
                    type: initType,
                    kind: .variable(isMutable: !p.isVal),
                    span: p.span
                )
                // Re-define in current scope (replaces .error placeholder)
                symbolTable.currentScope.update(updatedSymbol)
            }
        }
    }

    private func checkClass(_ c: ClassDecl) {
        let previousClass = currentClassName
        currentClassName = c.name
        symbolTable.pushScope()

        // Register type parameters
        for tp in c.typeParameters {
            let bound: Type? = tp.upperBound.map { resolver.resolve($0) }
            let tpType = Type.typeParameter(name: tp.name, bound: bound)
            symbolTable.define(Symbol(name: tp.name, type: tpType, kind: .typeParameter, span: tp.span))
        }

        // Register constructor params as accessible members
        for param in c.constructorParams {
            let paramType: Type = param.type.map { resolver.resolve($0) } ?? .error
            symbolTable.define(Symbol(name: param.name, type: paramType, kind: .parameter, span: param.span))
        }

        // Pre-register member properties and functions so they're visible in method bodies
        for member in c.members {
            if case .property(let p) = member {
                let propType = p.type.map { resolver.resolve($0) } ?? .error
                symbolTable.define(Symbol(name: p.name, type: propType, kind: .variable(isMutable: !p.isVal), span: p.span))
            } else if case .function(let f) = member {
                let paramTypes = f.parameters.map { p -> Type in
                    p.type.map { resolver.resolve($0) } ?? .error
                }
                let retType = f.returnType.map { resolver.resolve($0) } ?? .unit
                symbolTable.define(Symbol(
                    name: f.name,
                    type: .function(parameterTypes: paramTypes, returnType: retType),
                    kind: .function, span: f.span
                ))
            }
        }

        // Check members
        for member in c.members {
            checkDeclaration(member)
        }

        // Check interface implementation: verify all required methods are provided
        if let classInfo = symbolTable.lookupType(c.name) {
            for superTypeName in classInfo.superTypes {
                if let ifaceInfo = symbolTable.lookupType(superTypeName),
                   !ifaceInfo.members.isEmpty {
                    // This is an interface — check that all its methods are implemented
                    let classMethods = Set(classInfo.members.filter {
                        if case .function = $0.kind { return true }
                        return false
                    }.map { $0.name })

                    for ifaceMember in ifaceInfo.members {
                        if case .function = ifaceMember.kind,
                           !classMethods.contains(ifaceMember.name),
                           !ifaceInfo.defaultMethods.contains(ifaceMember.name) {
                            diagnostics.error(
                                "class '\(c.name)' does not implement interface method '\(superTypeName).\(ifaceMember.name)'",
                                at: c.span.start
                            )
                        }
                    }
                }
            }
        }

        symbolTable.popScope()
        currentClassName = previousClass
    }

    private func checkInterface(_ i: InterfaceDecl) {
        symbolTable.pushScope()
        for tp in i.typeParameters {
            let bound: Type? = tp.upperBound.map { resolver.resolve($0) }
            let tpType = Type.typeParameter(name: tp.name, bound: bound)
            symbolTable.define(Symbol(name: tp.name, type: tpType, kind: .typeParameter, span: tp.span))
        }
        for member in i.members {
            checkDeclaration(member)
        }
        symbolTable.popScope()
    }

    private func checkEnumClass(_ e: EnumClassDecl) {
        // Check member declarations
        for member in e.members {
            checkDeclaration(member)
        }
    }

    private func checkObject(_ o: ObjectDecl) {
        symbolTable.pushScope()
        for member in o.members {
            checkDeclaration(member)
        }
        symbolTable.popScope()
    }

    private func checkActor(_ a: ActorDecl) {
        let previousActor = currentActorName
        currentActorName = a.name
        symbolTable.pushScope()
        for member in a.members {
            checkDeclaration(member)
        }
        symbolTable.popScope()
        currentActorName = previousActor
    }

    private func checkView(_ v: ViewDecl) {
        symbolTable.pushScope()
        for param in v.parameters {
            let paramType: Type = param.type.map { resolver.resolve($0) } ?? .error
            symbolTable.define(Symbol(name: param.name, type: paramType, kind: .parameter, span: param.span))
        }
        checkBlock(v.body)
        symbolTable.popScope()
    }

    private func checkNavigation(_ n: NavigationDecl) {
        symbolTable.pushScope()
        checkBlock(n.body)
        symbolTable.popScope()
    }

    private func checkTheme(_ t: ThemeDecl) {
        symbolTable.pushScope()
        checkBlock(t.body)
        symbolTable.popScope()
    }

    // MARK: - Block & Statement Checking

    private func checkBlock(_ block: Block) {
        symbolTable.pushScope()
        for stmt in block.statements {
            checkStatement(stmt)
        }
        symbolTable.popScope()
    }

    private func checkStatement(_ stmt: Statement) {
        switch stmt {
        case .expression(let expr):
            let _ = checkExpression(expr)

        case .propertyDecl(let p):
            // Gather into scope then check (allow rebinding in local scopes)
            gatherProperty(p, allowRedeclaration: true)
            checkProperty(p)

        case .returnStmt(let expr, _):
            if let expr = expr {
                let _ = checkExpression(expr)
            }

        case .throwStmt(let expr, _):
            let _ = checkExpression(expr)

        case .tryCatch(let tc):
            checkBlock(tc.tryBody)
            symbolTable.pushScope()
            symbolTable.define(Symbol(name: tc.catchVariable, type: .string,
                                     kind: .variable(isMutable: false), span: tc.span))
            checkBlock(tc.catchBody)
            symbolTable.popScope()

        case .assignment(let a):
            checkAssignment(a)

        case .forLoop(let f):
            checkForLoop(f)

        case .whileLoop(let w):
            let condType = checkExpression(w.condition)
            if !condType.isError && condType != .bool {
                diagnostics.error("while condition must be Bool, got '\(condType)'", at: w.span.start)
            }
            checkBlock(w.body)

        case .doWhileLoop(let d):
            checkBlock(d.body)
            let condType = checkExpression(d.condition)
            if !condType.isError && condType != .bool {
                diagnostics.error("do-while condition must be Bool, got '\(condType)'", at: d.span.start)
            }

        case .declaration(let decl):
            gatherDeclaration(decl)
            checkDeclaration(decl)

        case .destructuringDecl(let d):
            let _ = checkExpression(d.initializer)
            for name in d.names {
                let symbol = Symbol(name: name, type: .classType(name: "Any", typeArguments: []),
                                    kind: .variable(isMutable: false), span: d.span)
                symbolTable.define(symbol)
            }

        case .breakStmt, .continueStmt:
            break
        }
    }

    private func checkAssignment(_ a: AssignmentStmt) {
        let targetType = checkExpression(a.target)
        let valueType = checkExpression(a.value)

        // Check mutability
        if case .identifier(let name, let span) = a.target {
            if let sym = symbolTable.lookup(name) {
                if case .variable(let isMutable) = sym.kind, !isMutable {
                    diagnostics.error("cannot assign to 'val' property '\(name)'", at: span.start)
                }
            }
        }

        // Check type compatibility
        if !targetType.isError && !valueType.isError {
            if a.op == .assign {
                if !typesCompatible(source: valueType, target: targetType) {
                    diagnostics.error(
                        "cannot assign '\(valueType)' to '\(targetType)'",
                        at: a.span.start
                    )
                }
            } else {
                // Compound assignment: +=, -=, etc.
                if !checkCompoundAssignment(targetType: targetType, valueType: valueType, op: a.op) {
                    diagnostics.error(
                        "operator '\(a.op)' is not applicable for '\(targetType)' and '\(valueType)'",
                        at: a.span.start
                    )
                }
            }
        }
    }

    private func checkCompoundAssignment(targetType: Type, valueType: Type, op: AssignmentOp) -> Bool {
        switch op {
        case .plusAssign:
            return (targetType.isNumeric && valueType.isNumeric) ||
                   (targetType == .string && valueType == .string)
        case .minusAssign, .timesAssign, .divideAssign, .moduloAssign:
            return targetType.isNumeric && valueType.isNumeric
        case .assign:
            return true
        }
    }

    private func checkForLoop(_ f: ForLoop) {
        let iterableType = checkExpression(f.iterable)
        symbolTable.pushScope()

        if let destructured = f.destructuredVariables, destructured.count >= 2 {
            // Map destructuring: for ((k, v) in map) — declare both k and v as Any
            for varName in destructured {
                symbolTable.define(Symbol(name: varName, type: .typeParameter(name: "Any", bound: nil), kind: .variable(isMutable: false), span: f.span))
            }
        } else {
            // Infer loop variable type from iterable
            let varType: Type
            if case .classType(let name, let args) = iterableType,
               (name == "List" || name == "MutableList" || name == "Set" || name == "MutableSet"),
               let elementType = args.first {
                varType = elementType
            } else if iterableType.isError {
                varType = .error
            } else {
                // Ranges produce Int
                varType = .int
            }

            symbolTable.define(Symbol(name: f.variable, type: varType, kind: .variable(isMutable: false), span: f.span))
        }
        checkBlock(f.body)
        symbolTable.popScope()
    }

    // MARK: - Expression Type Checking

    @discardableResult
    private func checkExpression(_ expr: Expression) -> Type {
        let type = inferExpression(expr)
        // Record in type map
        let id = ExpressionID(expr.span)
        typeMap[id] = type
        return type
    }

    private func inferExpression(_ expr: Expression) -> Type {
        switch expr {
        // Literals
        case .intLiteral:
            return .int
        case .floatLiteral:
            return .double
        case .stringLiteral:
            return .string
        case .interpolatedString(let parts, _):
            // Check each interpolation expression
            for part in parts {
                if case .interpolation(let subExpr) = part {
                    let _ = checkExpression(subExpr)
                }
            }
            return .string
        case .boolLiteral:
            return .bool
        case .nullLiteral:
            return .nullType

        // References
        case .identifier(let name, let span):
            if let sym = symbolTable.lookup(name) {
                return sym.type
            }
            diagnostics.error("unresolved reference '\(name)'", at: span.start)
            return .error

        case .this(let span):
            if let className = currentClassName {
                return .classType(name: className, typeArguments: [])
            } else if let actorName = currentActorName {
                return .actorType(name: actorName)
            } else if let receiver = currentReceiverType {
                return resolver.resolve(TypeNode.simple(name: receiver, typeArguments: [], span: span))
            }
            diagnostics.error("'this' used outside of a class or actor", at: span.start)
            return .error

        case .super(let span):
            if let className = currentClassName,
               let typeInfo = symbolTable.lookupType(className),
               let parent = typeInfo.superTypes.first {
                return .classType(name: parent, typeArguments: [])
            }
            diagnostics.error("'super' used outside of a class", at: span.start)
            return .error

        // Binary
        case .binary(let left, let op, let right, let span):
            return checkBinary(left: left, op: op, right: right, span: span)

        // Unary prefix
        case .unaryPrefix(let op, let operand, let span):
            return checkUnaryPrefix(op: op, operand: operand, span: span)

        // Unary postfix
        case .unaryPostfix(let operand, let op, let span):
            return checkUnaryPostfix(operand: operand, op: op, span: span)

        // Member access
        case .memberAccess(let obj, let member, let span):
            return checkMemberAccess(object: obj, member: member, nullSafe: false, span: span)

        case .nullSafeMemberAccess(let obj, let member, let span):
            return checkMemberAccess(object: obj, member: member, nullSafe: true, span: span)

        // Subscript
        case .subscriptAccess(let obj, let index, _):
            let _ = checkExpression(obj)
            let _ = checkExpression(index)
            // For Stage 0, return .error — full subscript typing deferred
            return .error

        // Call
        case .call(let callee, let args, let trailing, let span):
            return checkCall(callee: callee, arguments: args, trailingLambda: trailing, span: span)

        // If expression
        case .ifExpr(let ie):
            return checkIfExpr(ie)

        // When expression
        case .whenExpr(let we):
            return checkWhenExpr(we)

        // Lambda
        case .lambda(let le):
            return checkLambda(le)

        // Type operations
        case .typeCheck(let expr, _, _):
            let exprType = checkExpression(expr)
            if exprType.isError { return .error }
            return .bool

        case .typeCast(let expr, let typeNode, _):
            let _ = checkExpression(expr)
            return resolver.resolve(typeNode)

        case .safeCast(let expr, let typeNode, _):
            let _ = checkExpression(expr)
            let targetType = resolver.resolve(typeNode)
            if targetType.isError { return .error }
            return .nullable(targetType)

        case .nonNullAssert(let expr, let span):
            let exprType = checkExpression(expr)
            if exprType.isError { return .error }
            if !exprType.isNullable {
                diagnostics.warning("unnecessary non-null assertion on non-nullable type '\(exprType)'", at: span.start)
                return exprType
            }
            return exprType.unwrapNullable

        case .awaitExpr(let expr, let span):
            // await must be inside a suspend/async function or concurrent block
            if !inSuspendContext {
                diagnostics.error("'await' can only be used inside a suspend or async function, or a concurrent block", at: span.start)
            }
            return checkExpression(expr)

        case .concurrentBlock(let body, _):
            // concurrent { ... } creates a suspend context for its body
            let previousSuspendContext = inSuspendContext
            inSuspendContext = true
            for stmt in body {
                checkStatement(stmt)
            }
            inSuspendContext = previousSuspendContext
            return .unit

        // Elvis
        case .elvis(let left, let right, let span):
            return checkElvis(left: left, right: right, span: span)

        // Range
        case .range(let start, let end, _, let span):
            let startType = checkExpression(start)
            let endType = checkExpression(end)
            if !startType.isError && !startType.isInteger {
                diagnostics.error("range start must be integer, got '\(startType)'", at: span.start)
            }
            if !endType.isError && !endType.isInteger {
                diagnostics.error("range end must be integer, got '\(endType)'", at: span.start)
            }
            return .classType(name: "IntRange", typeArguments: [])

        // Parenthesized
        case .parenthesized(let inner, _):
            return checkExpression(inner)

        // Error
        case .error:
            return .error
        }
    }

    // MARK: - Binary Operations

    private func checkBinary(left: Expression, op: BinaryOp, right: Expression, span: SourceSpan) -> Type {
        let leftType = checkExpression(left)
        let rightType = checkExpression(right)

        if leftType.isError || rightType.isError { return .error }

        // Unresolved type parameters are treated as compatible with any concrete type.
        // This allows generic builtin functions (e.g., listGet returning T) to be used
        // in arithmetic/comparison expressions without full generic inference.
        let effectiveLeft = leftType.isTypeParameter ? rightType : leftType
        let effectiveRight = rightType.isTypeParameter ? leftType : rightType

        switch op {
        case .plus:
            if effectiveLeft == .string || effectiveRight == .string {
                return .string
            }
            if effectiveLeft.isNumeric && effectiveRight.isNumeric {
                return promoteNumeric(effectiveLeft, effectiveRight)
            }
            diagnostics.error("operator '+' cannot be applied to '\(leftType)' and '\(rightType)'", at: span.start)
            return .error

        case .minus, .times, .divide, .modulo:
            if effectiveLeft.isNumeric && effectiveRight.isNumeric {
                return promoteNumeric(effectiveLeft, effectiveRight)
            }
            diagnostics.error("operator '\(op.rawValue)' cannot be applied to '\(leftType)' and '\(rightType)'", at: span.start)
            return .error

        case .equalEqual, .notEqual:
            // Any two values can be compared for equality
            return .bool

        case .less, .lessEqual, .greater, .greaterEqual:
            if effectiveLeft.isNumeric && effectiveRight.isNumeric {
                return .bool
            }
            if effectiveLeft == .string && effectiveRight == .string {
                return .bool
            }
            diagnostics.error("operator '\(op.rawValue)' cannot be applied to '\(leftType)' and '\(rightType)'", at: span.start)
            return .error

        case .and, .or:
            if leftType != .bool {
                diagnostics.error("left operand of '\(op.rawValue)' must be Bool, got '\(leftType)'", at: span.start)
                return .error
            }
            if rightType != .bool {
                diagnostics.error("right operand of '\(op.rawValue)' must be Bool, got '\(rightType)'", at: span.start)
                return .error
            }
            return .bool
        }
    }

    private func promoteNumeric(_ a: Type, _ b: Type) -> Type {
        // Double > Float64 > Float > Int64 > Int32 > Int
        if a == .double || b == .double { return .double }
        if a == .float64 || b == .float64 { return .float64 }
        if a == .float || b == .float { return .float }
        if a == .int64 || b == .int64 { return .int64 }
        if a == .int32 || b == .int32 { return .int32 }
        return .int
    }

    // MARK: - Unary Operations

    private func checkUnaryPrefix(op: UnaryOp, operand: Expression, span: SourceSpan) -> Type {
        let operandType = checkExpression(operand)
        if operandType.isError { return .error }

        switch op {
        case .negate:
            if operandType.isNumeric { return operandType }
            diagnostics.error("unary '-' cannot be applied to '\(operandType)'", at: span.start)
            return .error
        case .not:
            if operandType == .bool { return .bool }
            diagnostics.error("unary '!' cannot be applied to '\(operandType)'", at: span.start)
            return .error
        }
    }

    private func checkUnaryPostfix(operand: Expression, op: PostfixOp, span: SourceSpan) -> Type {
        let operandType = checkExpression(operand)
        if operandType.isError { return .error }

        switch op {
        case .nonNullAssert:
            if !operandType.isNullable {
                diagnostics.warning("unnecessary non-null assertion on non-nullable type '\(operandType)'", at: span.start)
                return operandType
            }
            return operandType.unwrapNullable
        }
    }

    // MARK: - Member Access

    private func checkMemberAccess(object: Expression, member: String, nullSafe: Bool, span: SourceSpan) -> Type {
        let objType = checkExpression(object)
        if objType.isError { return .error }

        let baseType: Type
        if nullSafe {
            if !objType.isNullable {
                diagnostics.warning("unnecessary null-safe access on non-nullable type '\(objType)'", at: span.start)
            }
            baseType = objType.unwrapNullable
        } else {
            if objType.isNullable && objType != .nullType {
                diagnostics.error("member access on nullable type '\(objType)' requires '?.' operator", at: span.start)
                return .error
            }
            baseType = objType
        }

        // Look up member in type declaration
        if let typeName = baseType.typeName,
           let typeInfo = symbolTable.lookupType(typeName) {
            if let memberSym = typeInfo.members.first(where: { $0.name == member }) {
                // Actor isolation: prevent direct field access from outside the actor
                if case .actorType(let actorName) = baseType,
                   currentActorName != actorName,
                   case .variable = memberSym.kind {
                    diagnostics.error("cannot access actor field '\(member)' from outside actor '\(actorName)'; use a method instead", at: span.start)
                    return .error
                }
                let resultType = memberSym.type
                return nullSafe ? resultType.asNullable : resultType
            }
        }

        // For String, provide common members
        if baseType == .string {
            switch member {
            case "length": return nullSafe ? Type.int.asNullable : .int
            case "isEmpty": return nullSafe ? Type.bool.asNullable : .bool
            default: break
            }
        }

        // For Stage 0, allow unknown member access with a warning-free .error
        // to avoid noise from unresolved stdlib members
        return .error
    }

    // MARK: - Call

    private func checkCall(callee: Expression, arguments: [CallArgument], trailingLambda: LambdaExpr?, span: SourceSpan) -> Type {
        let calleeType = checkExpression(callee)

        // Warn if calling a suspend function without await
        if case .identifier(let name, _) = callee, suspendFunctions.contains(name), !inSuspendContext {
            diagnostics.warning("call to suspend function '\(name)' without 'await'", at: span.start)
        }

        // Check arguments and collect their types
        var argTypes: [Type] = []
        for arg in arguments {
            argTypes.append(checkExpression(arg.value))
        }

        // Check trailing lambda with context inference from callee's last parameter type
        if let lambda = trailingLambda {
            if case .function(let paramTypes, _) = calleeType,
               let lastParamType = paramTypes.last {
                let _ = checkLambda(lambda, expectedType: lastParamType)
            } else {
                let _ = checkLambda(lambda)
            }
        }

        if calleeType.isError { return .error }

        // If callee is a function type, return its return type
        if case .function(let paramTypes, let returnType) = calleeType {
            let totalArgs = arguments.count + (trailingLambda != nil ? 1 : 0)
            if totalArgs != paramTypes.count {
                // Allow variadic-like built-in functions (println accepts any number)
                // For Stage 0, just warn if significantly off
                // Skip strict arity check for builtins
            }
            // Substitute type parameters if the return type contains them
            if returnType.isTypeParameter {
                let substituted = substituteTypeParams(paramTypes: paramTypes, argTypes: argTypes, returnType: returnType, span: span)
                return substituted
            }
            return returnType
        }

        // If callee is a type (constructor call), return that type
        if case .classType(let name, let args) = calleeType {
            return .classType(name: name, typeArguments: args)
        }
        if case .enumType(let name) = calleeType {
            return .enumType(name: name)
        }

        // For identifiers that resolve to type declarations, treat as constructor
        if case .identifier(let name, _) = callee {
            if let sym = symbolTable.lookup(name), sym.kind == .typeDeclaration {
                return sym.type
            }
        }

        return .error
    }

    // MARK: - Generic Type Substitution

    /// Build a type parameter binding map by matching param types to arg types,
    /// then substitute in the return type.
    /// When `span` is provided, emits diagnostics for bound violations.
    private func substituteTypeParams(paramTypes: [Type], argTypes: [Type], returnType: Type, span: SourceSpan? = nil) -> Type {
        var bindings: [String: Type] = [:]
        for (paramType, argType) in zip(paramTypes, argTypes) {
            if case .typeParameter(let name, _) = paramType, !argType.isError {
                bindings[name] = argType
            }
        }
        // Task 5: Verify each concrete type satisfies the type parameter's upper bound
        if let span = span {
            for (paramType, _) in zip(paramTypes, argTypes) {
                if case .typeParameter(let name, let bound) = paramType,
                   let bound = bound,
                   let concrete = bindings[name],
                   !concrete.isError {
                    if !satisfiesBound(concrete: concrete, bound: bound) {
                        diagnostics.error(
                            "type '\(concrete)' does not satisfy bound '\(bound)' for type parameter '\(name)'",
                            at: span.start
                        )
                    }
                }
            }
        }
        return substitute(returnType, bindings: bindings)
    }

    /// Check if a concrete type satisfies an upper bound constraint.
    /// For example, if bound is `Comparable`, checks that concrete implements `Comparable`.
    private func satisfiesBound(concrete: Type, bound: Type) -> Bool {
        if concrete == bound { return true }
        if concrete.isError || bound.isError { return true }
        // Type parameters satisfy any bound (deferred checking)
        if concrete.isTypeParameter { return true }
        // Check if the concrete type's supertypes include the bound
        if let boundName = bound.typeName,
           let concreteName = concrete.typeName,
           let typeInfo = symbolTable.lookupType(concreteName) {
            if typeInfo.superTypes.contains(boundName) { return true }
            // Walk the supertype chain transitively
            for superName in typeInfo.superTypes {
                let superType = Type.classType(name: superName, typeArguments: [])
                if satisfiesBound(concrete: superType, bound: bound) { return true }
            }
        }
        // Numeric types satisfy numeric bounds
        if concrete.isNumeric && bound.isNumeric { return true }
        return false
    }

    /// Substitute type parameters in a type using a binding map.
    private func substitute(_ type: Type, bindings: [String: Type]) -> Type {
        switch type {
        case .typeParameter(let name, _):
            return bindings[name] ?? type
        case .function(let params, let ret):
            return .function(
                parameterTypes: params.map { substitute($0, bindings: bindings) },
                returnType: substitute(ret, bindings: bindings)
            )
        case .nullable(let inner):
            return .nullable(substitute(inner, bindings: bindings))
        default:
            return type
        }
    }

    // MARK: - If Expression

    private func checkIfExpr(_ ie: IfExpr) -> Type {
        let condType = checkExpression(ie.condition)
        if !condType.isError && condType != .bool {
            diagnostics.error("if condition must be Bool, got '\(condType)'", at: ie.span.start)
        }

        // Check then branch and infer type from last expression
        let thenType = checkBlockAsExpression(ie.thenBranch)

        // Check else branch
        var elseType: Type = .unit
        if let elseBranch = ie.elseBranch {
            switch elseBranch {
            case .elseBlock(let block):
                elseType = checkBlockAsExpression(block)
            case .elseIf(let elseIf):
                elseType = checkIfExpr(elseIf)
            }
        }

        // If both branches have the same type, use it as the if-expression type
        if thenType == elseType && !thenType.isError {
            return thenType
        }
        // If either is Unit (statement block), return Unit
        if thenType == .unit || elseType == .unit {
            return .unit
        }
        // Otherwise return the then-branch type (best effort)
        return thenType.isError ? elseType : thenType
    }

    /// Check a block and return the type of its last expression, or .unit if last is a statement.
    private func checkBlockAsExpression(_ block: Block) -> Type {
        guard !block.statements.isEmpty else {
            return .unit
        }
        for stmt in block.statements.dropLast() {
            checkStatement(stmt)
        }
        if let last = block.statements.last {
            if case .expression(let expr) = last {
                return checkExpression(expr)
            } else {
                checkStatement(last)
            }
        }
        return .unit
    }

    // MARK: - When Expression

    private func checkWhenExpr(_ we: WhenExpr) -> Type {
        var subjectType: Type = .error
        if let subject = we.subject {
            subjectType = checkExpression(subject)
        }

        var hasElse = false
        var coveredTypes: [String] = []
        var branchTypes: [Type] = []

        for entry in we.entries {
            symbolTable.pushScope()

            for condition in entry.conditions {
                switch condition {
                case .expression(let expr):
                    if case .identifier(let name, _) = expr, name == "else" {
                        hasElse = true
                    } else {
                        let _ = checkExpression(expr)
                        // Detect enum entry references for exhaustiveness (e.g., Color.RED → "RED")
                        if let entryName = extractEnumEntryName(expr) {
                            coveredTypes.append(entryName)
                        }
                    }
                case .isType(let typeNode, _):
                    let resolvedType = resolver.resolve(typeNode)
                    if let name = resolvedType.typeName {
                        coveredTypes.append(name)
                    }
                    // Smart cast: narrow subject type in this scope
                    if let subject = we.subject,
                       case .identifier(let subjectName, let subjectSpan) = subject {
                        let narrowed = Symbol(
                            name: subjectName,
                            type: resolvedType,
                            kind: .variable(isMutable: false),
                            span: subjectSpan
                        )
                        symbolTable.currentScope.update(narrowed)
                    }
                case .inRange(let start, let end, _):
                    let _ = checkExpression(start)
                    let _ = checkExpression(end)
                case .isTypeWithBindings(let typeNode, let bindings, _):
                    let resolvedType = resolver.resolve(typeNode)
                    if let name = resolvedType.typeName {
                        coveredTypes.append(name)
                    }
                    // Smart cast + bind each destructured name as a local
                    if let subject = we.subject,
                       case .identifier(let subjectName, let subjectSpan) = subject {
                        let narrowed = Symbol(
                            name: subjectName,
                            type: resolvedType,
                            kind: .variable(isMutable: false),
                            span: subjectSpan
                        )
                        symbolTable.currentScope.update(narrowed)
                    }
                    // Bind each destructured name as Any in scope
                    for binding in bindings {
                        let sym = Symbol(
                            name: binding,
                            type: .classType(name: "Any", typeArguments: []),
                            kind: .variable(isMutable: false),
                            span: entry.span
                        )
                        symbolTable.define(sym)
                    }
                }
            }

            // Check guard expression
            if let guardExpr = entry.guard_ {
                let guardType = checkExpression(guardExpr)
                if !guardType.isError && guardType != .bool {
                    diagnostics.error("when guard must be Bool, got '\(guardType)'", at: entry.span.start)
                }
            }

            switch entry.body {
            case .expression(let expr):
                let bodyType = checkExpression(expr)
                branchTypes.append(bodyType)
            case .block(let block):
                checkBlock(block)
                branchTypes.append(.unit)
            }

            symbolTable.popScope()
        }

        // Sealed class exhaustiveness check
        if !subjectType.isError, let typeName = subjectType.typeName,
           let typeInfo = symbolTable.lookupType(typeName),
           !typeInfo.sealedSubclasses.isEmpty {
            checkSealedExhaustiveness(
                subclasses: typeInfo.sealedSubclasses,
                coveredTypes: coveredTypes,
                hasElse: hasElse,
                span: we.span
            )
        }

        // Enum exhaustiveness check
        if !subjectType.isError, let typeName = subjectType.typeName,
           let typeInfo = symbolTable.lookupType(typeName),
           !typeInfo.enumEntries.isEmpty {
            checkEnumExhaustiveness(
                entries: typeInfo.enumEntries,
                coveredTypes: coveredTypes,
                hasElse: hasElse,
                span: we.span
            )
        }

        // Infer when-expression return type from branch types
        if let firstType = branchTypes.first,
           branchTypes.allSatisfy({ $0 == firstType || $0.isError }) {
            return firstType
        }
        return .unit
    }

    private func checkSealedExhaustiveness(subclasses: [String], coveredTypes: [String], hasElse: Bool, span: SourceSpan) {
        if hasElse { return }
        let missing = subclasses.filter { !coveredTypes.contains($0) }
        if !missing.isEmpty {
            let missingStr = missing.joined(separator: ", ")
            diagnostics.error("'when' is not exhaustive; missing: \(missingStr)", at: span.start)
        }
    }

    private func checkEnumExhaustiveness(entries: [String], coveredTypes: [String], hasElse: Bool, span: SourceSpan) {
        if hasElse { return }
        let missing = entries.filter { !coveredTypes.contains($0) }
        if !missing.isEmpty {
            let missingStr = missing.joined(separator: ", ")
            diagnostics.error("'when' is not exhaustive; missing: \(missingStr)", at: span.start)
        }
    }

    /// Extract the enum entry name from a when condition expression.
    /// Handles `EnumType.ENTRY` (memberAccess) and bare `ENTRY` (identifier that's an enumEntry symbol).
    private func extractEnumEntryName(_ expr: Expression) -> String? {
        // Pattern: EnumType.ENTRY (e.g., Color.RED)
        if case .memberAccess(let obj, let member, _) = expr,
           case .identifier(let typeName, _) = obj,
           let typeInfo = symbolTable.lookupType(typeName),
           !typeInfo.enumEntries.isEmpty,
           typeInfo.enumEntries.contains(member) {
            return member
        }
        // Pattern: bare ENTRY name (if imported/in scope as enum entry)
        if case .identifier(let name, _) = expr,
           let sym = symbolTable.lookup(name),
           sym.kind == .enumEntry {
            return name
        }
        return nil
    }

    // MARK: - Lambda

    /// Check a lambda expression, optionally using an expected function type
    /// to infer parameter types (Task 7: closure context inference).
    @discardableResult
    private func checkLambda(_ le: LambdaExpr, expectedType: Type? = nil) -> Type {
        symbolTable.pushScope()

        // Task 7: Infer parameter types from expected function type
        let expectedParams: [Type]?
        if let expectedType = expectedType, case .function(let ep, _) = expectedType {
            expectedParams = ep
        } else {
            expectedParams = nil
        }

        let paramTypes: [Type] = le.parameters.enumerated().map { (i, param) in
            let type: Type
            if let typeNode = param.type {
                type = resolver.resolve(typeNode)
            } else if let ep = expectedParams, i < ep.count {
                type = ep[i]
            } else {
                type = .error
            }
            symbolTable.define(Symbol(name: param.name, type: type, kind: .parameter, span: param.span))
            return type
        }

        // Task 6: Infer return type from last expression in body
        var returnType: Type = .unit
        if !le.body.isEmpty {
            for stmt in le.body.dropLast() {
                checkStatement(stmt)
            }
            if let last = le.body.last {
                if case .expression(let expr) = last {
                    returnType = checkExpression(expr)
                } else {
                    checkStatement(last)
                }
            }
        }

        symbolTable.popScope()

        // If parameters have no types and couldn't be inferred, return .error
        if paramTypes.contains(where: { $0.isError }) && !le.parameters.isEmpty {
            return .error
        }

        return .function(parameterTypes: paramTypes, returnType: returnType)
    }

    // MARK: - Elvis

    private func checkElvis(left: Expression, right: Expression, span: SourceSpan) -> Type {
        let leftType = checkExpression(left)
        let rightType = checkExpression(right)

        if leftType.isError || rightType.isError { return .error }

        if !leftType.isNullable {
            diagnostics.warning("left operand of '?:' is not nullable; elvis operator is unnecessary", at: span.start)
            return leftType
        }

        // Result is the non-nullable left type, or the right type — whichever is broader
        let unwrapped = leftType.unwrapNullable
        if typesCompatible(source: rightType, target: unwrapped) {
            return unwrapped
        }
        // If right type differs, result is their common supertype — for Stage 0, use right type
        return rightType
    }

    // MARK: - Type Compatibility

    /// Check if `source` can be assigned to `target`
    private func typesCompatible(source: Type, target: Type) -> Bool {
        if source == target { return true }
        if source.isError || target.isError { return true } // Suppress cascading
        if source == .any || target == .any { return true } // Any is compatible with everything
        if source == .nothing { return true } // Nothing is a subtype of everything
        if source == .nullType && target.isNullable { return true } // null → T?

        // Numeric widening
        if target.isNumeric && source.isNumeric {
            return numericRank(source) <= numericRank(target)
        }

        // Nullable compatibility: T is compatible with T?
        if case .nullable(let inner) = target {
            return typesCompatible(source: source, target: inner)
        }

        // Task 8: Variance-aware generic type compatibility
        // List<Dog> assignable to List<Animal> when out variance
        if case .classType(let sName, let sArgs) = source,
           case .classType(let tName, let tArgs) = target,
           sName == tName, sArgs.count == tArgs.count, !sArgs.isEmpty {
            if let typeInfo = symbolTable.lookupType(sName) {
                for (i, (sArg, tArg)) in zip(sArgs, tArgs).enumerated() {
                    if sArg == tArg { continue }
                    let variance: Variance? = i < typeInfo.typeParameterVariances.count
                        ? typeInfo.typeParameterVariances[i] : nil
                    switch variance {
                    case .out:
                        // Covariant: source arg must be subtype of target arg
                        if !typesCompatible(source: sArg, target: tArg) { return false }
                    case .in:
                        // Contravariant: target arg must be subtype of source arg
                        if !typesCompatible(source: tArg, target: sArg) { return false }
                    case nil:
                        // Invariant: must be exact match
                        return false
                    }
                }
                return true
            }
        }

        // Subtype compatibility: Dog assignable to Animal (via supertype chain)
        if let sourceName = source.typeName,
           let targetName = target.typeName,
           let sourceInfo = symbolTable.lookupType(sourceName) {
            if sourceInfo.superTypes.contains(targetName) { return true }
            for superName in sourceInfo.superTypes {
                let superType = Type.classType(name: superName, typeArguments: [])
                if typesCompatible(source: superType, target: target) { return true }
            }
        }

        return false
    }

    private func numericRank(_ type: Type) -> Int {
        switch type {
        case .int:     return 1
        case .int32:   return 2
        case .int64:   return 3
        case .float:   return 4
        case .float64: return 5
        case .double:  return 6
        default:       return 0
        }
    }
}

// MARK: - Expression Span Helper

extension Expression {
    /// Extract the source span from an expression
    var span: SourceSpan {
        switch self {
        case .intLiteral(_, let s),
             .floatLiteral(_, let s),
             .stringLiteral(_, let s),
             .interpolatedString(_, let s),
             .boolLiteral(_, let s),
             .nullLiteral(let s),
             .identifier(_, let s),
             .this(let s),
             .super(let s),
             .error(let s):
            return s
        case .binary(_, _, _, let span),
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
             .parenthesized(_, let span):
            return span
        case .unaryPrefix(_, _, let span):
            return span
        case .unaryPostfix(_, _, let span):
            return span
        case .ifExpr(let ie):
            return ie.span
        case .whenExpr(let we):
            return we.span
        case .lambda(let le):
            return le.span
        }
    }
}
