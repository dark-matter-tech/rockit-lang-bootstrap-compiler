// MIRLowering.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - MIR Lowering

/// Lowers a type-checked AST into MIR (Rockit Intermediate Representation).
/// Produces a `MIRModule` containing functions, globals, and type declarations.
public final class MIRLowering {
    private let result: TypeCheckResult
    private let diagnostics: DiagnosticEngine
    private var builder = MIRBuilder()

    /// Maps local variable names to their alloc temps
    private var locals: [String: String] = [:]

    /// The current class name (for method name mangling)
    private var currentClassName: String?

    /// Stack of (continueLabel, breakLabel) for loop break/continue support
    private var loopStack: [(continueLabel: String, breakLabel: String)] = []

    /// Accumulated module components
    private var functions: [MIRFunction] = []
    private var globals: [MIRGlobal] = []
    private var typeDecls: [MIRTypeDecl] = []

    /// Extension function names: maps "ReceiverType.method" to true
    private var extensionFunctions: Set<String> = []

    /// Counter for unique lambda names
    private var lambdaCounter: Int = 0

    /// Counter for unique concurrent scope IDs
    private var concurrentScopeCounter: Int = 0

    /// Interface declarations indexed by name (for default method inheritance)
    private var interfaceDecls: [String: InterfaceDecl] = [:]

    /// Function declarations indexed by name (for default parameter injection)
    private var functionDeclarations: [String: FunctionDecl] = [:]

    /// Member properties with default values, indexed by type name
    private var memberPropertyDefaults: [String: [(String, Expression)]] = [:]

    public init(typeCheckResult: TypeCheckResult) {
        self.result = typeCheckResult
        self.diagnostics = typeCheckResult.diagnostics
    }

    /// Lower the entire AST to a MIR module.
    public func lower() -> MIRModule {
        // Pre-scan for extension functions, interface declarations, and function declarations
        for decl in result.ast.declarations {
            if case .function(let f) = decl {
                if let receiverType = f.receiverType {
                    extensionFunctions.insert("\(receiverType).\(f.name)")
                }
                functionDeclarations[f.name] = f
            }
            if case .interfaceDecl(let i) = decl {
                interfaceDecls[i.name] = i
            }
            // Also scan class/actor members for method declarations and member defaults
            if case .classDecl(let c) = decl {
                var defaults: [(String, Expression)] = []
                for member in c.members {
                    if case .function(let f) = member {
                        functionDeclarations["\(c.name).\(f.name)"] = f
                    }
                    if case .property(let p) = member, let init_ = p.initializer {
                        defaults.append((p.name, init_))
                    }
                }
                if !defaults.isEmpty {
                    memberPropertyDefaults[c.name] = defaults
                }
                // Also scan nested classes (sealed subclasses)
                for member in c.members {
                    if case .classDecl(let nested) = member {
                        var nestedDefaults: [(String, Expression)] = []
                        for nestedMember in nested.members {
                            if case .function(let f) = nestedMember {
                                functionDeclarations["\(nested.name).\(f.name)"] = f
                            }
                            if case .property(let p) = nestedMember, let init_ = p.initializer {
                                nestedDefaults.append((p.name, init_))
                            }
                        }
                        if !nestedDefaults.isEmpty {
                            memberPropertyDefaults[nested.name] = nestedDefaults
                        }
                    }
                }
            }
            if case .actorDecl(let a) = decl {
                var defaults: [(String, Expression)] = []
                for member in a.members {
                    if case .function(let f) = member {
                        functionDeclarations["\(a.name).\(f.name)"] = f
                    }
                    if case .property(let p) = member, let init_ = p.initializer {
                        defaults.append((p.name, init_))
                    }
                }
                if !defaults.isEmpty {
                    memberPropertyDefaults[a.name] = defaults
                }
            }
        }

        for decl in result.ast.declarations {
            lowerDeclaration(decl)
        }
        return MIRModule(globals: globals, functions: functions, types: typeDecls)
    }

    // MARK: - Declaration Lowering

    private func lowerDeclaration(_ decl: Declaration) {
        switch decl {
        case .function(let f):
            lowerFunction(f)
        case .property(let p):
            lowerTopLevelProperty(p)
        case .classDecl(let c):
            lowerClass(c)
        case .interfaceDecl(let i):
            lowerInterface(i)
        case .enumDecl(let e):
            lowerEnum(e)
        case .objectDecl(let o):
            lowerObject(o)
        case .actorDecl(let a):
            lowerActor(a)
        case .viewDecl(let v):
            lowerView(v)
        case .navigationDecl(let n):
            lowerNavigation(n)
        case .themeDecl(let t):
            lowerTheme(t)
        case .typeAlias:
            break
        }
    }

    // MARK: - Function Lowering

    private func lowerFunction(_ f: FunctionDecl) {
        let savedLocals = locals
        let savedBuilder = builder
        builder = MIRBuilder()
        locals = [:]

        var params: [(String, MIRType)] = []

        // Extension functions get an implicit 'this' parameter
        if let receiverType = f.receiverType {
            let mirType = MIRType.reference(receiverType)
            params.append(("this", mirType))
        } else if let className = currentClassName {
            // Class/actor methods get an implicit 'this' parameter
            let mirType = MIRType.reference(className)
            params.append(("this", mirType))
        }

        // Get formal parameter types from the function's symbol table entry
        var formalParamTypes: [Type] = []
        if let sym = result.symbolTable.lookup(f.name),
           case .function(let paramTypes, _) = sym.type {
            formalParamTypes = paramTypes
        }

        params += f.parameters.enumerated().map { (i, p) in
            let type: MIRType
            if i < formalParamTypes.count {
                type = MIRType.from(formalParamTypes[i])
            } else if let typeNode = p.type {
                let resolved = result.symbolTable.lookup(p.name)?.type ?? .error
                type = MIRType.from(resolved)
                _ = typeNode // suppress unused warning
            } else {
                type = .unit
            }
            return (p.name, type)
        }

        let retType: MIRType
        if let sym = result.symbolTable.lookup(f.name),
           case .function(_, let rt) = sym.type {
            retType = MIRType.from(rt)
        } else {
            retType = .unit
        }

        let funcName: String
        if let receiverType = f.receiverType {
            funcName = "\(receiverType).\(f.name)"
        } else if let className = currentClassName {
            funcName = "\(className).\(f.name)"
        } else if result.functionOverloads[f.name] != nil {
            funcName = "\(f.name)$\(f.parameters.count)"
        } else {
            funcName = f.name
        }

        builder.startBlock(label: "entry")

        // Alloc and store each parameter
        for (name, type) in params {
            let slot = builder.emitAlloc(type: type)
            locals[name] = slot
            // Parameters are available as their name; store the param value
            let paramTemp = builder.newTemp()
            builder.emit(.load(dest: paramTemp, src: "param.\(name)"))
            builder.emitStore(dest: slot, src: paramTemp)
        }

        // Lower body
        if let body = f.body {
            switch body {
            case .block(let block):
                lowerBlock(block)
            case .expression(let expr):
                let val = lowerExpression(expr)
                if !builder.isTerminated {
                    builder.terminate(.ret(val))
                }
            }
        }

        // Ensure terminator
        if !builder.isTerminated {
            builder.terminate(.ret(nil))
        }

        let blocks = builder.finishBlocks()
        let mirFunc = MIRFunction(name: funcName, parameters: params, returnType: retType, blocks: blocks)
        functions.append(mirFunc)

        locals = savedLocals
        builder = savedBuilder
    }

    // MARK: - Top-Level Property

    private func lowerTopLevelProperty(_ p: PropertyDecl) {
        let type: MIRType
        if let sym = result.symbolTable.lookup(p.name) {
            type = MIRType.from(sym.type)
        } else {
            type = .unit
        }

        let isMutable = !p.isVal
        var initFunc: String? = nil

        if p.initializer != nil {
            // Create an initializer function
            let initName = "__init_\(p.name)"
            initFunc = initName

            let savedLocals = locals
            locals = [:]
            builder.startBlock(label: "entry")

            let val = lowerExpression(p.initializer!)
            builder.terminate(.ret(val))

            let blocks = builder.finishBlocks()
            let mirFunc = MIRFunction(name: initName, parameters: [], returnType: type, blocks: blocks)
            functions.append(mirFunc)
            locals = savedLocals
        }

        globals.append(MIRGlobal(name: p.name, type: type, isMutable: isMutable, initializerFunc: initFunc))
    }

    // MARK: - Class Lowering

    /// Convert an AST TypeNode to a MIRType without requiring a symbol table lookup.
    private func mirTypeFromTypeNode(_ node: TypeNode) -> MIRType {
        switch node {
        case .simple(let name, _, _):
            switch name {
            case "Int":     return .int
            case "Int32":   return .int32
            case "Int64":   return .int64
            case "Float":   return .float
            case "Float64": return .float64
            case "Double":  return .double
            case "Bool":    return .bool
            case "String":  return .string
            case "Unit":    return .unit
            case "Nothing": return .nothing
            default:        return .reference(name)
            }
        case .nullable(let inner, _):
            return .nullable(mirTypeFromTypeNode(inner))
        case .function(let paramTypes, let retType, _):
            return .function(paramTypes.map { mirTypeFromTypeNode($0) }, mirTypeFromTypeNode(retType))
        case .tuple, .qualified:
            return .unit
        }
    }

    private func isPrimitiveFieldType(_ type: MIRType) -> Bool {
        switch type {
        case .int, .int32, .int64, .float, .float64, .double, .bool:
            return true
        default:
            return false
        }
    }

    private func lowerClass(_ c: ClassDecl) {
        // Build MIRTypeDecl
        var fields: [(String, MIRType)] = []
        var methodNames: [String] = []

        let isDataClass = c.modifiers.contains(.data)
        for param in c.constructorParams {
            // Data class params are always fields; regular class params need explicit val/var
            if isDataClass || param.isVal || param.isVar {
                let paramType: MIRType
                if let sym = result.symbolTable.lookupType(c.name),
                   let memberSym = sym.members.first(where: { $0.name == param.name }) {
                    paramType = MIRType.from(memberSym.type)
                } else if let typeNode = param.type {
                    // Fallback: resolve from the parameter's type annotation
                    paramType = mirTypeFromTypeNode(typeNode)
                } else {
                    paramType = .unit
                }
                fields.append((param.name, paramType))
            }
        }

        // Gather member fields and methods
        for member in c.members {
            switch member {
            case .property(let p):
                let propType: MIRType
                if let info = result.symbolTable.lookupType(c.name),
                   let memberSym = info.members.first(where: { $0.name == p.name }) {
                    propType = MIRType.from(memberSym.type)
                } else {
                    propType = .unit
                }
                fields.append((p.name, propType))
            case .function(let f):
                methodNames.append("\(c.name).\(f.name)")
            case .objectDecl(let obj) where obj.isCompanion:
                for companionMember in obj.members {
                    if case .function(let f) = companionMember {
                        methodNames.append("\(c.name).\(f.name)")
                    }
                }
            case .classDecl:
                // Nested classes (e.g., sealed subclasses) are lowered separately below
                break
            default:
                break
            }
        }

        // Inherit interface default methods
        let classOwnMethods = Set(methodNames.map { name -> String in
            // methodNames are "ClassName.method" — extract the method part
            if let dotIdx = name.lastIndex(of: ".") {
                return String(name[name.index(after: dotIdx)...])
            }
            return name
        })
        var inheritedDefaults: [FunctionDecl] = []
        for superType in c.superTypes {
            if case .simple(let superName, _, _) = superType,
               let ifaceDecl = interfaceDecls[superName] {
                for member in ifaceDecl.members {
                    if case .function(let f) = member, f.body != nil,
                       !classOwnMethods.contains(f.name) {
                        methodNames.append("\(c.name).\(f.name)")
                        inheritedDefaults.append(f)
                    }
                }
            }
        }

        // Retrieve hierarchy info from the type checker's symbol table
        let typeInfo = result.symbolTable.lookupType(c.name)
        let parentType = typeInfo?.superTypes.first
        let sealedSubs = typeInfo?.sealedSubclasses ?? []

        // Value type eligibility: data class with only primitive fields, no inheritance
        let isValueType = isDataClass && parentType == nil && sealedSubs.isEmpty
            && !fields.isEmpty && fields.allSatisfy { isPrimitiveFieldType($0.1) }

        typeDecls.append(MIRTypeDecl(name: c.name, fields: fields, methods: methodNames,
                                     parentType: parentType, sealedSubclasses: sealedSubs,
                                     isValueType: isValueType))

        // Lower nested classes (e.g., sealed subclasses)
        for member in c.members {
            if case .classDecl(let nested) = member {
                lowerClass(nested)
            }
        }

        // Lower member methods
        let savedClassName = currentClassName
        currentClassName = c.name
        for member in c.members {
            if case .function(let f) = member {
                lowerFunction(f)
            }
            // Companion object: lower its methods as ClassName.method (static, no 'this')
            if case .objectDecl(let obj) = member, obj.isCompanion {
                for companionMember in obj.members {
                    if case .function(let f) = companionMember {
                        lowerFunction(f)
                    }
                }
            }
        }
        // Lower inherited interface default methods as class methods
        for f in inheritedDefaults {
            lowerFunction(f)
        }
        currentClassName = savedClassName
    }

    // MARK: - Interface Lowering

    private func lowerInterface(_ i: InterfaceDecl) {
        var methodNames: [String] = []
        for member in i.members {
            if case .function(let f) = member {
                methodNames.append("\(i.name).\(f.name)")
            }
        }
        typeDecls.append(MIRTypeDecl(name: i.name, methods: methodNames))
    }

    // MARK: - Enum Lowering

    private func lowerEnum(_ e: EnumClassDecl) {
        // Enum type has a single $variant field storing the entry name
        let fields: [(String, MIRType)] = [("$variant", .string)]
        var methodNames: [String] = []
        for member in e.members {
            if case .function(let f) = member {
                methodNames.append("\(e.name).\(f.name)")
            }
        }
        typeDecls.append(MIRTypeDecl(name: e.name, fields: fields, methods: methodNames))

        // Create a global singleton for each enum entry
        for entry in e.entries {
            let globalName = "\(e.name).\(entry.name)"
            let initName = "__init_\(e.name)_\(entry.name)"

            // Create initializer function: allocates an object with $variant = "entryName"
            let savedLocals = locals
            locals = [:]
            builder.startBlock(label: "entry")

            let variantStr = builder.emitConstString(entry.name)
            let dest = builder.newTemp()
            builder.emit(.newObject(dest: dest, typeName: e.name, args: [variantStr]))
            builder.terminate(.ret(dest))

            let blocks = builder.finishBlocks()
            let mirFunc = MIRFunction(name: initName, parameters: [], returnType: .reference(e.name), blocks: blocks)
            functions.append(mirFunc)
            locals = savedLocals

            globals.append(MIRGlobal(name: globalName, type: .reference(e.name), isMutable: false, initializerFunc: initName))
        }

        // Lower member methods
        let savedClassName = currentClassName
        currentClassName = e.name
        for member in e.members {
            if case .function(let f) = member {
                lowerFunction(f)
            }
        }
        currentClassName = savedClassName
    }

    // MARK: - Object Lowering

    private func lowerObject(_ o: ObjectDecl) {
        var fields: [(String, MIRType)] = []
        var methodNames: [String] = []

        for member in o.members {
            switch member {
            case .property(let p):
                let propType: MIRType
                if let info = result.symbolTable.lookupType(o.name),
                   let memberSym = info.members.first(where: { $0.name == p.name }) {
                    propType = MIRType.from(memberSym.type)
                } else {
                    propType = .unit
                }
                fields.append((p.name, propType))
            case .function(let f):
                methodNames.append("\(o.name).\(f.name)")
            default:
                break
            }
        }

        typeDecls.append(MIRTypeDecl(name: o.name, fields: fields, methods: methodNames))

        // Lower methods
        let savedClassName = currentClassName
        currentClassName = o.name
        for member in o.members {
            if case .function(let f) = member {
                lowerFunction(f)
            }
        }
        currentClassName = savedClassName
    }

    // MARK: - Actor Lowering (as class for Stage 0)

    private func lowerActor(_ a: ActorDecl) {
        var fields: [(String, MIRType)] = []
        var methodNames: [String] = []

        for member in a.members {
            switch member {
            case .property(let p):
                let propType: MIRType
                if let info = result.symbolTable.lookupType(a.name),
                   let memberSym = info.members.first(where: { $0.name == p.name }) {
                    propType = MIRType.from(memberSym.type)
                } else {
                    propType = .unit
                }
                fields.append((p.name, propType))
            case .function(let f):
                methodNames.append("\(a.name).\(f.name)")
            default:
                break
            }
        }

        typeDecls.append(MIRTypeDecl(name: a.name, fields: fields, methods: methodNames, isActor: true))

        let savedClassName = currentClassName
        currentClassName = a.name
        for member in a.members {
            if case .function(let f) = member {
                lowerFunction(f)
            }
        }
        currentClassName = savedClassName
    }

    // MARK: - View / Navigation / Theme (compiled as functions)

    private func lowerView(_ v: ViewDecl) {
        // Lower view as a function with its params and body
        let funcDecl = FunctionDecl(
            annotations: [], modifiers: [], name: v.name,
            typeParameters: [], parameters: v.parameters,
            returnType: nil, body: .block(v.body), span: v.span
        )
        lowerFunction(funcDecl)
    }

    private func lowerNavigation(_ n: NavigationDecl) {
        // Lower navigation as a parameterless function
        let funcDecl = FunctionDecl(
            annotations: [], modifiers: [], name: n.name,
            typeParameters: [], parameters: [],
            returnType: nil, body: .block(n.body), span: n.span
        )
        lowerFunction(funcDecl)
    }

    private func lowerTheme(_ t: ThemeDecl) {
        // Lower theme as a parameterless function
        let funcDecl = FunctionDecl(
            annotations: [], modifiers: [], name: t.name,
            typeParameters: [], parameters: [],
            returnType: nil, body: .block(t.body), span: t.span
        )
        lowerFunction(funcDecl)
    }

    // MARK: - Block & Statement Lowering

    private func lowerBlock(_ block: Block) {
        for stmt in block.statements {
            if builder.isTerminated { break }
            lowerStatement(stmt)
        }
    }

    private func lowerStatement(_ stmt: Statement) {
        switch stmt {
        case .expression(let expr):
            let _ = lowerExpression(expr)

        case .propertyDecl(let p):
            lowerLocalProperty(p)

        case .returnStmt(let expr, _):
            if let expr = expr {
                let val = lowerExpression(expr)
                builder.terminate(.ret(val))
            } else {
                builder.terminate(.ret(nil))
            }

        case .assignment(let a):
            lowerAssignment(a)

        case .forLoop(let f):
            lowerForLoop(f)

        case .whileLoop(let w):
            lowerWhileLoop(w)

        case .doWhileLoop(let d):
            lowerDoWhileLoop(d)

        case .throwStmt(let expr, _):
            let val = lowerExpression(expr)
            builder.terminate(.throwValue(val))

        case .tryCatch(let tc):
            lowerTryCatch(tc)

        case .breakStmt:
            if let loop = loopStack.last {
                builder.terminate(.jump(loop.breakLabel))
            }

        case .continueStmt:
            if let loop = loopStack.last {
                builder.terminate(.jump(loop.continueLabel))
            }

        case .declaration(let decl):
            lowerDeclaration(decl)

        case .destructuringDecl(let d):
            lowerDestructuringDecl(d)
        }
    }

    // MARK: - Local Property

    private func lowerLocalProperty(_ p: PropertyDecl) {
        let type: MIRType
        if let sym = result.symbolTable.lookup(p.name) {
            type = MIRType.from(sym.type)
        } else if let init_ = p.initializer {
            // Fallback: infer type from initializer expression via typeMap
            type = lookupExprType(init_)
        } else {
            type = .unit
        }

        let slot = builder.emitAlloc(type: type)
        locals[p.name] = slot

        if let initializer = p.initializer {
            let val = lowerExpression(initializer)
            builder.emitStore(dest: slot, src: val)
        }
    }

    // MARK: - Destructuring Decl

    /// Lower `val (a, b, c) = expr` — eval expr, then listGet for each name.
    private func lowerDestructuringDecl(_ d: DestructuringDecl) {
        let initVal = lowerExpression(d.initializer)
        for (i, name) in d.names.enumerated() {
            let idxConst = builder.emitConstInt(Int64(i))
            let element = builder.newTemp()
            builder.emit(.call(dest: element, function: "listGet", args: [initVal, idxConst]))
            let slot = builder.emitAlloc(type: .int)
            locals[name] = slot
            builder.emitStore(dest: slot, src: element)
        }
    }

    // MARK: - Assignment

    private func lowerAssignment(_ a: AssignmentStmt) {
        let value = lowerExpression(a.value)

        switch a.op {
        case .assign:
            if case .identifier(let name, _) = a.target {
                if let slot = locals[name] {
                    builder.emitStore(dest: slot, src: value)
                } else if currentClassName != nil,
                          typeDecls.first(where: { $0.name == currentClassName })?.fields.contains(where: { $0.0 == name }) == true {
                    // Bare field name in a method — treat as this.fieldName
                    let thisTemp: String
                    if let slot = locals["this"] {
                        thisTemp = builder.emitLoad(src: slot)
                    } else {
                        thisTemp = builder.emitLoad(src: "this")
                    }
                    builder.emit(.setField(object: thisTemp, fieldName: name, value: value))
                } else {
                    // Module-level global variable
                    builder.emitStore(dest: "global.\(name)", src: value)
                }
            } else if case .memberAccess(let obj, let member, _) = a.target {
                let objTemp = lowerExpression(obj)
                builder.emit(.setField(object: objTemp, fieldName: member, value: value))
            } else if case .subscriptAccess(let obj, let index, _) = a.target {
                let objTemp = lowerExpression(obj)
                let idxTemp = lowerExpression(index)
                let dest = builder.newTemp()
                builder.emit(.call(dest: dest, function: "listSet", args: [objTemp, idxTemp, value]))
            }

        case .plusAssign, .minusAssign, .timesAssign, .divideAssign, .moduloAssign:
            if case .identifier(let name, _) = a.target {
                let targetVal: String
                let isField: Bool
                if let slot = locals[name] {
                    targetVal = builder.emitLoad(src: slot)
                    isField = false
                } else if currentClassName != nil,
                          typeDecls.first(where: { $0.name == currentClassName })?.fields.contains(where: { $0.0 == name }) == true {
                    // Bare field name — load via getField on this
                    let thisTemp: String
                    if let thisSlot = locals["this"] {
                        thisTemp = builder.emitLoad(src: thisSlot)
                    } else {
                        thisTemp = builder.emitLoad(src: "this")
                    }
                    let fieldTemp = builder.newTemp()
                    builder.emit(.getField(dest: fieldTemp, object: thisTemp, fieldName: name))
                    targetVal = fieldTemp
                    isField = true
                } else {
                    targetVal = builder.emitLoad(src: "global.\(name)")
                    isField = false
                }

                let resultTemp = builder.newTemp()
                let opType = lookupExprType(a.target)

                switch a.op {
                case .plusAssign:
                    builder.emit(.add(dest: resultTemp, lhs: targetVal, rhs: value, type: opType))
                case .minusAssign:
                    builder.emit(.sub(dest: resultTemp, lhs: targetVal, rhs: value, type: opType))
                case .timesAssign:
                    builder.emit(.mul(dest: resultTemp, lhs: targetVal, rhs: value, type: opType))
                case .divideAssign:
                    builder.emit(.div(dest: resultTemp, lhs: targetVal, rhs: value, type: opType))
                case .moduloAssign:
                    builder.emit(.mod(dest: resultTemp, lhs: targetVal, rhs: value, type: opType))
                default:
                    break
                }

                if isField {
                    let thisTemp2: String
                    if let thisSlot = locals["this"] {
                        thisTemp2 = builder.emitLoad(src: thisSlot)
                    } else {
                        thisTemp2 = builder.emitLoad(src: "this")
                    }
                    builder.emit(.setField(object: thisTemp2, fieldName: name, value: resultTemp))
                } else if let slot = locals[name] {
                    builder.emitStore(dest: slot, src: resultTemp)
                }
            } else if case .memberAccess(let obj, let member, _) = a.target {
                // Member compound assignment: obj.field op= value
                let objTemp = lowerExpression(obj)
                let oldVal = builder.newTemp()
                builder.emit(.getField(dest: oldVal, object: objTemp, fieldName: member))

                let resultTemp = builder.newTemp()
                let opType = lookupExprType(a.target)

                switch a.op {
                case .plusAssign:
                    builder.emit(.add(dest: resultTemp, lhs: oldVal, rhs: value, type: opType))
                case .minusAssign:
                    builder.emit(.sub(dest: resultTemp, lhs: oldVal, rhs: value, type: opType))
                case .timesAssign:
                    builder.emit(.mul(dest: resultTemp, lhs: oldVal, rhs: value, type: opType))
                case .divideAssign:
                    builder.emit(.div(dest: resultTemp, lhs: oldVal, rhs: value, type: opType))
                case .moduloAssign:
                    builder.emit(.mod(dest: resultTemp, lhs: oldVal, rhs: value, type: opType))
                default:
                    break
                }

                builder.emit(.setField(object: objTemp, fieldName: member, value: resultTemp))
            }
        }
    }

    // MARK: - Control Flow: While

    private func lowerWhileLoop(_ w: WhileLoop) {
        let headerLabel = builder.newBlockLabel("while.header")
        let bodyLabel = builder.newBlockLabel("while.body")
        let exitLabel = builder.newBlockLabel("while.exit")

        loopStack.append((continueLabel: headerLabel, breakLabel: exitLabel))

        builder.terminate(.jump(headerLabel))

        // Header: evaluate condition
        builder.startBlock(label: headerLabel)
        let cond = lowerExpression(w.condition)
        builder.terminate(.branch(condition: cond, thenLabel: bodyLabel, elseLabel: exitLabel))

        // Body
        builder.startBlock(label: bodyLabel)
        lowerBlock(w.body)
        if !builder.isTerminated {
            builder.terminate(.jump(headerLabel))
        }

        loopStack.removeLast()

        // Exit
        builder.startBlock(label: exitLabel)
    }

    // MARK: - Control Flow: Do-While

    private func lowerDoWhileLoop(_ d: DoWhileLoop) {
        let bodyLabel = builder.newBlockLabel("dowhile.body")
        let condLabel = builder.newBlockLabel("dowhile.cond")
        let exitLabel = builder.newBlockLabel("dowhile.exit")

        loopStack.append((continueLabel: condLabel, breakLabel: exitLabel))

        builder.terminate(.jump(bodyLabel))

        // Body
        builder.startBlock(label: bodyLabel)
        lowerBlock(d.body)
        if !builder.isTerminated {
            builder.terminate(.jump(condLabel))
        }

        // Condition
        builder.startBlock(label: condLabel)
        let cond = lowerExpression(d.condition)
        builder.terminate(.branch(condition: cond, thenLabel: bodyLabel, elseLabel: exitLabel))

        loopStack.removeLast()

        // Exit
        builder.startBlock(label: exitLabel)
    }

    // MARK: - Control Flow: Try-Catch

    private func lowerTryCatch(_ tc: TryCatch) {
        let catchLabel = builder.newBlockLabel("catch")
        let endLabel = builder.newBlockLabel("try.end")

        // Register for the caught exception value
        let exceptionSlot = builder.emitAlloc(type: .string)

        // Push exception handler
        builder.emit(.tryBegin(catchLabel: catchLabel, exceptionDest: exceptionSlot))

        // Lower try body
        lowerBlock(tc.tryBody)
        if !builder.isTerminated {
            // Normal exit: pop handler and jump past catch
            builder.emit(.tryEnd)
            // Emit finally after try (normal path)
            if let finallyBody = tc.finallyBody {
                lowerBlock(finallyBody)
            }
            builder.terminate(.jump(endLabel))
        }

        // Catch block
        builder.startBlock(label: catchLabel)
        // Exception value is already in exceptionSlot (placed by VM)
        locals[tc.catchVariable] = exceptionSlot
        lowerBlock(tc.catchBody)
        if !builder.isTerminated {
            // Emit finally after catch
            if let finallyBody = tc.finallyBody {
                lowerBlock(finallyBody)
            }
            builder.terminate(.jump(endLabel))
        }

        // End
        builder.startBlock(label: endLabel)
    }

    // MARK: - Control Flow: For Loop

    private func lowerForLoop(_ f: ForLoop) {
        // Check if iterable is a range expression — emit direct counter loop
        if case .range(let start, let end, let inclusive, _) = f.iterable {
            lowerForLoopRange(variable: f.variable, start: start, end: end, inclusive: inclusive, body: f.body)
            return
        }

        // Map destructuring: for ((k, v) in map)
        if let destructured = f.destructuredVariables, destructured.count >= 2 {
            lowerForLoopMapDestructure(keyVar: destructured[0], valueVar: destructured[1], iterable: f.iterable, body: f.body)
            return
        }

        // Collection iteration via index-based loop using listSize/listGet
        lowerForLoopList(variable: f.variable, iterable: f.iterable, body: f.body)
    }

    /// Lower a for loop over a range as a direct counter loop.
    /// `for (i in start..end)` or `for (i in start..<end)`
    private func lowerForLoopRange(variable: String, start: Expression, end: Expression, inclusive: Bool, body: Block) {
        let headerLabel = builder.newBlockLabel("for.header")
        let bodyLabel = builder.newBlockLabel("for.body")
        let incrLabel = builder.newBlockLabel("for.incr")
        let exitLabel = builder.newBlockLabel("for.exit")

        // continue jumps to increment (not header) so counter advances
        loopStack.append((continueLabel: incrLabel, breakLabel: exitLabel))

        // Lower start and end expressions
        let startTemp = lowerExpression(start)
        let endTemp = lowerExpression(end)

        // Alloc loop variable and initialize to start
        let loopVarSlot = builder.emitAlloc(type: .int)
        locals[variable] = loopVarSlot
        builder.emitStore(dest: loopVarSlot, src: startTemp)

        builder.terminate(.jump(headerLabel))

        // Header: load loop var, compare with end
        builder.startBlock(label: headerLabel)
        let current = builder.emitLoad(src: loopVarSlot)
        let cond = builder.newTemp()
        if inclusive {
            builder.emit(.lte(dest: cond, lhs: current, rhs: endTemp, type: .int))
        } else {
            builder.emit(.lt(dest: cond, lhs: current, rhs: endTemp, type: .int))
        }
        builder.terminate(.branch(condition: cond, thenLabel: bodyLabel, elseLabel: exitLabel))

        // Body
        builder.startBlock(label: bodyLabel)
        lowerBlock(body)
        if !builder.isTerminated {
            builder.terminate(.jump(incrLabel))
        }

        // Increment: load current, add 1, store back, jump to header
        builder.startBlock(label: incrLabel)
        let cur = builder.emitLoad(src: loopVarSlot)
        let one = builder.emitConstInt(1)
        let next = builder.newTemp()
        builder.emit(.add(dest: next, lhs: cur, rhs: one, type: .int))
        builder.emitStore(dest: loopVarSlot, src: next)
        builder.terminate(.jump(headerLabel))

        loopStack.removeLast()

        // Exit
        builder.startBlock(label: exitLabel)
    }

    /// Lower a for loop over a List as an index-based counter loop.
    /// `for (item in myList)` → `var i = 0; while (i < listSize(list)) { item = listGet(list, i); body; i++ }`
    private func lowerForLoopList(variable: String, iterable: Expression, body: Block) {
        let headerLabel = builder.newBlockLabel("for.header")
        let bodyLabel = builder.newBlockLabel("for.body")
        let incrLabel = builder.newBlockLabel("for.incr")
        let exitLabel = builder.newBlockLabel("for.exit")

        loopStack.append((continueLabel: incrLabel, breakLabel: exitLabel))

        // Evaluate the list expression once
        let listTemp = lowerExpression(iterable)

        // Get list size
        let sizeTemp = builder.newTemp()
        builder.emit(.call(dest: sizeTemp, function: "listSize", args: [listTemp]))

        // Alloc index counter, initialize to 0
        let indexSlot = builder.emitAlloc(type: .int)
        let zero = builder.emitConstInt(0)
        builder.emitStore(dest: indexSlot, src: zero)

        builder.terminate(.jump(headerLabel))

        // Header: index < size?
        builder.startBlock(label: headerLabel)
        let currentIdx = builder.emitLoad(src: indexSlot)
        let cond = builder.newTemp()
        builder.emit(.lt(dest: cond, lhs: currentIdx, rhs: sizeTemp, type: .int))
        builder.terminate(.branch(condition: cond, thenLabel: bodyLabel, elseLabel: exitLabel))

        // Body: item = listGet(list, index)
        builder.startBlock(label: bodyLabel)
        let idx = builder.emitLoad(src: indexSlot)
        let element = builder.newTemp()
        builder.emit(.call(dest: element, function: "listGet", args: [listTemp, idx]))

        let loopVarSlot = builder.emitAlloc(type: .reference("Any"))
        locals[variable] = loopVarSlot
        builder.emitStore(dest: loopVarSlot, src: element)

        lowerBlock(body)
        if !builder.isTerminated {
            builder.terminate(.jump(incrLabel))
        }

        // Increment: index++
        builder.startBlock(label: incrLabel)
        let cur = builder.emitLoad(src: indexSlot)
        let one = builder.emitConstInt(1)
        let next = builder.newTemp()
        builder.emit(.add(dest: next, lhs: cur, rhs: one, type: .int))
        builder.emitStore(dest: indexSlot, src: next)
        builder.terminate(.jump(headerLabel))

        loopStack.removeLast()

        builder.startBlock(label: exitLabel)
    }

    /// Lower a for loop with map destructuring: `for ((k, v) in map)`.
    /// Strategy: keys = mapKeys(map), iterate keys by index, mapGet for values.
    private func lowerForLoopMapDestructure(keyVar: String, valueVar: String, iterable: Expression, body: Block) {
        let headerLabel = builder.newBlockLabel("for.header")
        let bodyLabel = builder.newBlockLabel("for.body")
        let incrLabel = builder.newBlockLabel("for.incr")
        let exitLabel = builder.newBlockLabel("for.exit")

        loopStack.append((continueLabel: incrLabel, breakLabel: exitLabel))

        // Evaluate the map expression once
        let mapTemp = lowerExpression(iterable)

        // Get keys list: keys = mapKeys(map)
        let keysTemp = builder.newTemp()
        builder.emit(.call(dest: keysTemp, function: "mapKeys", args: [mapTemp]))

        // Get keys list size
        let sizeTemp = builder.newTemp()
        builder.emit(.call(dest: sizeTemp, function: "listSize", args: [keysTemp]))

        // Alloc index counter, initialize to 0
        let indexSlot = builder.emitAlloc(type: .int)
        let zero = builder.emitConstInt(0)
        builder.emitStore(dest: indexSlot, src: zero)

        builder.terminate(.jump(headerLabel))

        // Header: index < size?
        builder.startBlock(label: headerLabel)
        let currentIdx = builder.emitLoad(src: indexSlot)
        let cond = builder.newTemp()
        builder.emit(.lt(dest: cond, lhs: currentIdx, rhs: sizeTemp, type: .int))
        builder.terminate(.branch(condition: cond, thenLabel: bodyLabel, elseLabel: exitLabel))

        // Body: k = listGet(keys, index), v = mapGet(map, k)
        builder.startBlock(label: bodyLabel)
        let idx = builder.emitLoad(src: indexSlot)
        let keyElement = builder.newTemp()
        builder.emit(.call(dest: keyElement, function: "listGet", args: [keysTemp, idx]))

        let keySlot = builder.emitAlloc(type: .int)
        locals[keyVar] = keySlot
        builder.emitStore(dest: keySlot, src: keyElement)

        let valueElement = builder.newTemp()
        builder.emit(.call(dest: valueElement, function: "mapGet", args: [mapTemp, keyElement]))

        let valueSlot = builder.emitAlloc(type: .int)
        locals[valueVar] = valueSlot
        builder.emitStore(dest: valueSlot, src: valueElement)

        lowerBlock(body)
        if !builder.isTerminated {
            builder.terminate(.jump(incrLabel))
        }

        // Increment: index++
        builder.startBlock(label: incrLabel)
        let cur = builder.emitLoad(src: indexSlot)
        let one = builder.emitConstInt(1)
        let next = builder.newTemp()
        builder.emit(.add(dest: next, lhs: cur, rhs: one, type: .int))
        builder.emitStore(dest: indexSlot, src: next)
        builder.terminate(.jump(headerLabel))

        loopStack.removeLast()

        builder.startBlock(label: exitLabel)
    }

    // MARK: - Expression Lowering

    /// Lower an expression, returning the temp holding the result.
    @discardableResult
    private func lowerExpression(_ expr: Expression) -> String {
        switch expr {
        // Literals
        case .intLiteral(let value, _):
            return builder.emitConstInt(value)

        case .floatLiteral(let value, _):
            return builder.emitConstFloat(value)

        case .stringLiteral(let value, _):
            return builder.emitConstString(value)

        case .boolLiteral(let value, _):
            return builder.emitConstBool(value)

        case .nullLiteral:
            return builder.emitConstNull()

        case .interpolatedString(let parts, _):
            return lowerInterpolatedString(parts)

        // References
        case .identifier(let name, _):
            if let slot = locals[name] {
                return builder.emitLoad(src: slot)
            }
            // Check if this is a bare field reference in a method body
            if currentClassName != nil,
               typeDecls.first(where: { $0.name == currentClassName })?.fields.contains(where: { $0.0 == name }) == true {
                let thisTemp: String
                if let thisSlot = locals["this"] {
                    thisTemp = builder.emitLoad(src: thisSlot)
                } else {
                    thisTemp = builder.emitLoad(src: "this")
                }
                let fieldTemp = builder.newTemp()
                builder.emit(.getField(dest: fieldTemp, object: thisTemp, fieldName: name))
                return fieldTemp
            }
            // Global or unresolved — emit a load from the name directly
            return builder.emitLoad(src: "global.\(name)")

        case .this:
            if let slot = locals["this"] {
                return builder.emitLoad(src: slot)
            }
            return builder.emitLoad(src: "this")

        case .super:
            return builder.emitLoad(src: "super")

        // Binary operators
        case .binary(let left, let op, let right, _):
            return lowerBinary(left: left, op: op, right: right)

        // Unary prefix
        case .unaryPrefix(let op, let operand, _):
            return lowerUnaryPrefix(op: op, operand: operand)

        // Unary postfix
        case .unaryPostfix(let operand, let op, _):
            return lowerUnaryPostfix(operand: operand, op: op)

        // Member access
        case .memberAccess(let obj, let member, _):
            // Check if this is an enum entry reference (e.g., Color.RED)
            if case .identifier(let typeName, _) = obj,
               let typeInfo = result.symbolTable.lookupType(typeName),
               !typeInfo.enumEntries.isEmpty,
               typeInfo.enumEntries.contains(member) {
                // Enum entry — load from the global singleton
                return builder.emitLoad(src: "global.\(typeName).\(member)")
            }
            let objTemp = lowerExpression(obj)
            let dest = builder.newTemp()
            builder.emit(.getField(dest: dest, object: objTemp, fieldName: member))
            return dest

        case .nullSafeMemberAccess(let obj, let member, _):
            return lowerNullSafeMemberAccess(object: obj, member: member)

        // Subscript
        case .subscriptAccess(let obj, let index, _):
            let objTemp = lowerExpression(obj)
            let idxTemp = lowerExpression(index)
            let dest = builder.newTemp()
            builder.emit(.virtualCall(dest: dest, object: objTemp, method: "get", args: [idxTemp]))
            return dest

        // Call
        case .call(let callee, let args, let trailing, _):
            return lowerCall(callee: callee, arguments: args, trailingLambda: trailing)

        // If expression
        case .ifExpr(let ie):
            return lowerIfExpr(ie)

        // When expression
        case .whenExpr(let we):
            return lowerWhenExpr(we)

        // Lambda
        case .lambda(let le):
            return lowerLambda(le)

        // Type operations
        case .typeCheck(let expr, let typeNode, _):
            return lowerTypeCheck(expr: expr, typeNode: typeNode)

        case .typeCast(let expr, let typeNode, _):
            return lowerTypeCast(expr: expr, typeNode: typeNode)

        case .safeCast(let expr, let typeNode, _):
            return lowerSafeCast(expr: expr, typeNode: typeNode)

        case .nonNullAssert(let expr, _):
            return lowerNonNullAssert(expr: expr)

        case .awaitExpr(let expr, _):
            return lowerAwaitExpr(expr: expr)

        case .concurrentBlock(let body, _):
            let scopeId = "concurrent_\(concurrentScopeCounter)"
            concurrentScopeCounter += 1
            builder.emit(.concurrentBegin(scopeId: scopeId))
            for stmt in body {
                lowerStatement(stmt)
            }
            builder.emit(.concurrentEnd(scopeId: scopeId))
            return builder.emitConstNull()

        // Elvis
        case .elvis(let left, let right, _):
            return lowerElvis(left: left, right: right)

        // Range
        case .range(let start, let end, let inclusive, _):
            return lowerRange(start: start, end: end, inclusive: inclusive)

        // Parenthesized
        case .parenthesized(let inner, _):
            return lowerExpression(inner)

        // Error
        case .error:
            return builder.emitConstNull()
        }
    }

    // MARK: - Binary Operations

    private func lowerBinary(left: Expression, op: BinaryOp, right: Expression) -> String {
        // Short-circuit: && and || must NOT eagerly evaluate the right operand
        if op == .and {
            return lowerShortCircuitAnd(left: left, right: right)
        }
        if op == .or {
            return lowerShortCircuitOr(left: left, right: right)
        }

        let lhs = lowerExpression(left)
        let rhs = lowerExpression(right)
        let dest = builder.newTemp()
        let type = lookupExprType(left)

        switch op {
        case .plus:     builder.emit(.add(dest: dest, lhs: lhs, rhs: rhs, type: type))
        case .minus:    builder.emit(.sub(dest: dest, lhs: lhs, rhs: rhs, type: type))
        case .times:    builder.emit(.mul(dest: dest, lhs: lhs, rhs: rhs, type: type))
        case .divide:   builder.emit(.div(dest: dest, lhs: lhs, rhs: rhs, type: type))
        case .modulo:   builder.emit(.mod(dest: dest, lhs: lhs, rhs: rhs, type: type))

        case .equalEqual:   builder.emit(.eq(dest: dest, lhs: lhs, rhs: rhs, type: type))
        case .notEqual:     builder.emit(.neq(dest: dest, lhs: lhs, rhs: rhs, type: type))
        case .less:         builder.emit(.lt(dest: dest, lhs: lhs, rhs: rhs, type: type))
        case .lessEqual:    builder.emit(.lte(dest: dest, lhs: lhs, rhs: rhs, type: type))
        case .greater:      builder.emit(.gt(dest: dest, lhs: lhs, rhs: rhs, type: type))
        case .greaterEqual: builder.emit(.gte(dest: dest, lhs: lhs, rhs: rhs, type: type))

        case .and, .or:
            fatalError("unreachable: && and || handled above")
        }

        return dest
    }

    // MARK: - Short-Circuit Boolean Operators

    private func lowerShortCircuitAnd(left: Expression, right: Expression) -> String {
        let leftVal = lowerExpression(left)
        let rhsLabel = builder.newBlockLabel("and.rhs")
        let mergeLabel = builder.newBlockLabel("and.merge")
        let resultSlot = builder.emitAlloc(type: .bool)

        // If left is false, short-circuit to false
        let falseConst = builder.emitConstBool(false)
        builder.emitStore(dest: resultSlot, src: falseConst)
        builder.terminate(.branch(condition: leftVal, thenLabel: rhsLabel, elseLabel: mergeLabel))

        // RHS: evaluate right, store result
        builder.startBlock(label: rhsLabel)
        let rightVal = lowerExpression(right)
        builder.emitStore(dest: resultSlot, src: rightVal)
        builder.terminate(.jump(mergeLabel))

        // Merge
        builder.startBlock(label: mergeLabel)
        return builder.emitLoad(src: resultSlot)
    }

    private func lowerShortCircuitOr(left: Expression, right: Expression) -> String {
        let leftVal = lowerExpression(left)
        let rhsLabel = builder.newBlockLabel("or.rhs")
        let mergeLabel = builder.newBlockLabel("or.merge")
        let resultSlot = builder.emitAlloc(type: .bool)

        // If left is true, short-circuit to true
        let trueConst = builder.emitConstBool(true)
        builder.emitStore(dest: resultSlot, src: trueConst)
        builder.terminate(.branch(condition: leftVal, thenLabel: mergeLabel, elseLabel: rhsLabel))

        // RHS: evaluate right, store result
        builder.startBlock(label: rhsLabel)
        let rightVal = lowerExpression(right)
        builder.emitStore(dest: resultSlot, src: rightVal)
        builder.terminate(.jump(mergeLabel))

        // Merge
        builder.startBlock(label: mergeLabel)
        return builder.emitLoad(src: resultSlot)
    }

    // MARK: - Unary Operations

    private func lowerUnaryPrefix(op: UnaryOp, operand: Expression) -> String {
        let operandTemp = lowerExpression(operand)
        let dest = builder.newTemp()
        let type = lookupExprType(operand)

        switch op {
        case .negate:
            builder.emit(.neg(dest: dest, operand: operandTemp, type: type))
        case .not:
            builder.emit(.not(dest: dest, operand: operandTemp))
        }

        return dest
    }

    private func lowerUnaryPostfix(operand: Expression, op: PostfixOp) -> String {
        switch op {
        case .nonNullAssert:
            return lowerNonNullAssert(expr: operand)
        }
    }

    // MARK: - String Interpolation

    private func lowerInterpolatedString(_ parts: [StringPart]) -> String {
        var partTemps: [String] = []
        for part in parts {
            switch part {
            case .literal(let s):
                partTemps.append(builder.emitConstString(s))
            case .interpolation(let expr):
                partTemps.append(lowerExpression(expr))
            }
        }
        let dest = builder.newTemp()
        builder.emit(.stringConcat(dest: dest, parts: partTemps))
        return dest
    }

    // MARK: - Call Lowering

    private func lowerCall(callee: Expression, arguments: [CallArgument], trailingLambda: LambdaExpr?) -> String {
        let argTemps = arguments.map { lowerExpression($0.value) }

        // Handle method calls: callee is memberAccess
        if case .memberAccess(let obj, let method, _) = callee {
            // Check for static/companion method calls: ClassName.method()
            if case .identifier(let typeName, _) = obj {
                // If the identifier is a type declaration (class, enum, object)
                if let typeInfo = result.symbolTable.lookupType(typeName) {
                    // Check if method is a sealed subclass constructor (e.g., Shape.Circle(5))
                    if typeInfo.sealedSubclasses.contains(method),
                       result.symbolTable.lookupType(method) != nil {
                        let dest = builder.newTemp()
                        builder.emit(.newObject(dest: dest, typeName: method, args: argTemps))
                        return dest
                    }
                    // Otherwise, call as static method
                    let dest = builder.newTemp()
                    builder.emit(.call(dest: dest, function: "\(typeName).\(method)", args: argTemps))
                    return dest
                }
            }

            let objTemp = lowerExpression(obj)

            // Check if this is an extension function call
            for extName in extensionFunctions {
                if extName.hasSuffix(".\(method)") {
                    let dest = builder.newTemp()
                    builder.emit(.call(dest: dest, function: extName, args: [objTemp] + argTemps))
                    return dest
                }
            }

            let dest = builder.newTemp()
            builder.emit(.virtualCall(dest: dest, object: objTemp, method: method, args: argTemps))
            return dest
        }

        // Handle null-safe method calls
        if case .nullSafeMemberAccess(let obj, let method, _) = callee {
            let objTemp = lowerExpression(obj)
            // Null-safe call: check null, branch
            let isNullTemp = builder.newTemp()
            builder.emit(.isNull(dest: isNullTemp, operand: objTemp))

            let nonNullLabel = builder.newBlockLabel("safecall.nonnull")
            let nullLabel = builder.newBlockLabel("safecall.null")
            let mergeLabel = builder.newBlockLabel("safecall.merge")

            let resultSlot = builder.emitAlloc(type: .nullable(.unit))

            builder.terminate(.branch(condition: isNullTemp, thenLabel: nullLabel, elseLabel: nonNullLabel))

            // Non-null path: do the call
            builder.startBlock(label: nonNullLabel)
            let callResult = builder.newTemp()
            builder.emit(.virtualCall(dest: callResult, object: objTemp, method: method, args: argTemps))
            builder.emitStore(dest: resultSlot, src: callResult)
            builder.terminate(.jump(mergeLabel))

            // Null path: store null
            builder.startBlock(label: nullLabel)
            let nullVal = builder.emitConstNull()
            builder.emitStore(dest: resultSlot, src: nullVal)
            builder.terminate(.jump(mergeLabel))

            // Merge
            builder.startBlock(label: mergeLabel)
            return builder.emitLoad(src: resultSlot)
        }

        // Simple function call
        if case .identifier(let name, _) = callee {
            // Check if it's a constructor call (type declaration)
            if let sym = result.symbolTable.lookup(name), sym.kind == .typeDeclaration {
                let dest = builder.newTemp()
                builder.emit(.newObject(dest: dest, typeName: name, args: argTemps))
                // Initialize member properties with default values
                if let defaults = memberPropertyDefaults[name] {
                    for (fieldName, defaultExpr) in defaults {
                        let defaultVal = lowerExpression(defaultExpr)
                        builder.emit(.setField(object: dest, fieldName: fieldName, value: defaultVal))
                    }
                }
                return dest
            }

            // Check if it's a local variable holding a function reference
            if locals[name] != nil {
                let calleeTemp = lowerExpression(callee)
                let dest = builder.newTemp()
                builder.emit(.callIndirect(dest: dest, functionRef: calleeTemp, args: argTemps))
                return dest
            }

            // Inject default parameter values for missing arguments
            var allArgTemps = argTemps
            if let funcDecl = functionDeclarations[name],
               allArgTemps.count < funcDecl.parameters.count {
                for i in allArgTemps.count..<funcDecl.parameters.count {
                    if let defaultExpr = funcDecl.parameters[i].defaultValue {
                        let defaultTemp = lowerExpression(defaultExpr)
                        allArgTemps.append(defaultTemp)
                    }
                }
            }

            // Pack vararg arguments into a list if this is a vararg function
            let finalArgs: [String]
            if let varargIdx = result.varargFunctions[name] {
                finalArgs = packVarargs(argTemps: allArgTemps, varargIndex: varargIdx)
            } else {
                finalArgs = allArgTemps
            }

            // Regular function call — resolve overloads by arity
            let resolvedName: String
            if result.functionOverloads[name] != nil {
                resolvedName = "\(name)$\(finalArgs.count)"
            } else {
                resolvedName = name
            }
            let dest = builder.newTemp()
            builder.emit(.call(dest: dest, function: resolvedName, args: finalArgs))
            return dest
        }

        // Fallback: indirect call (e.g. calling a lambda stored in a variable)
        let calleeTemp = lowerExpression(callee)
        let dest = builder.newTemp()
        builder.emit(.callIndirect(dest: dest, functionRef: calleeTemp, args: argTemps))
        return dest
    }

    // MARK: - Await

    /// Lower an await expression. If the inner expression is a function call,
    /// emit an `awaitCall` MIR instruction. Otherwise, fall through to regular lowering.
    private func lowerAwaitExpr(expr: Expression) -> String {
        // Unwrap: await someCall(args) → awaitCall(dest, funcName, args)
        if case .call(let callee, let arguments, let trailingLambda, _) = expr {
            // For simple function calls (identifier callee), emit awaitCall
            if case .identifier(let name, _) = callee {
                let argTemps = arguments.map { lowerExpression($0.value) }

                // Inject default parameter values
                var allArgTemps = argTemps
                if let funcDecl = functionDeclarations[name],
                   allArgTemps.count < funcDecl.parameters.count {
                    for i in allArgTemps.count..<funcDecl.parameters.count {
                        if let defaultExpr = funcDecl.parameters[i].defaultValue {
                            let defaultTemp = lowerExpression(defaultExpr)
                            allArgTemps.append(defaultTemp)
                        }
                    }
                }

                // Pack varargs
                let finalArgs: [String]
                if let varargIdx = result.varargFunctions[name] {
                    finalArgs = packVarargs(argTemps: allArgTemps, varargIndex: varargIdx)
                } else {
                    finalArgs = allArgTemps
                }

                // Resolve overloads
                let resolvedName: String
                if result.functionOverloads[name] != nil {
                    resolvedName = "\(name)$\(finalArgs.count)"
                } else {
                    resolvedName = name
                }

                let dest = builder.newTemp()
                builder.emit(.awaitCall(dest: dest, function: resolvedName, args: finalArgs))
                return dest
            }

            // For method calls on objects, emit awaitCall with qualified name
            if case .memberAccess(let obj, let method, _) = callee {
                let objTemp = lowerExpression(obj)
                let argTemps = arguments.map { lowerExpression($0.value) }
                let dest = builder.newTemp()
                // Emit as awaitCall with virtual dispatch semantics
                // The VM will handle this as a virtual await
                builder.emit(.awaitCall(dest: dest, function: "vcall.\(method)", args: [objTemp] + argTemps))
                return dest
            }
        }

        // Fallback: await on a non-call expression — just evaluate it
        return lowerExpression(expr)
    }

    // MARK: - Vararg Packing

    /// Pack arguments from `varargIndex` onward into a single list argument.
    private func packVarargs(argTemps: [String], varargIndex: Int) -> [String] {
        let before = Array(argTemps.prefix(varargIndex))
        let varargArgs = Array(argTemps.dropFirst(varargIndex))

        // Create a list and append each vararg argument
        let listTemp = builder.newTemp()
        builder.emit(.call(dest: listTemp, function: "listCreate", args: []))
        for arg in varargArgs {
            let appendResult = builder.newTemp()
            builder.emit(.call(dest: appendResult, function: "listAppend", args: [listTemp, arg]))
        }

        return before + [listTemp]
    }

    // MARK: - If Expression

    private func lowerIfExpr(_ ie: IfExpr) -> String {
        let cond = lowerExpression(ie.condition)

        let thenLabel = builder.newBlockLabel("if.then")
        let elseLabel = builder.newBlockLabel("if.else")
        let mergeLabel = builder.newBlockLabel("if.merge")

        let resultSlot = builder.emitAlloc(type: .unit)

        builder.terminate(.branch(condition: cond, thenLabel: thenLabel, elseLabel: elseLabel))

        // Then branch
        builder.startBlock(label: thenLabel)
        if let thenVal = lowerBlockAsExpression(ie.thenBranch) {
            builder.emitStore(dest: resultSlot, src: thenVal)
        }
        if !builder.isTerminated {
            builder.terminate(.jump(mergeLabel))
        }

        // Else branch
        builder.startBlock(label: elseLabel)
        if let elseBranch = ie.elseBranch {
            switch elseBranch {
            case .elseBlock(let block):
                if let elseVal = lowerBlockAsExpression(block) {
                    builder.emitStore(dest: resultSlot, src: elseVal)
                }
            case .elseIf(let elseIf):
                let elseIfVal = lowerIfExpr(elseIf)
                builder.emitStore(dest: resultSlot, src: elseIfVal)
            }
        }
        if !builder.isTerminated {
            builder.terminate(.jump(mergeLabel))
        }

        // Merge
        builder.startBlock(label: mergeLabel)
        return builder.emitLoad(src: resultSlot)
    }

    /// Lower a block and return the value of its last expression, if any.
    private func lowerBlockAsExpression(_ block: Block) -> String? {
        guard !block.statements.isEmpty else {
            return nil
        }
        // Lower all statements except the last
        for stmt in block.statements.dropLast() {
            if builder.isTerminated { return nil }
            lowerStatement(stmt)
        }
        // If the last statement is an expression, capture its value
        if !builder.isTerminated, let last = block.statements.last {
            if case .expression(let expr) = last {
                return lowerExpression(expr)
            } else {
                lowerStatement(last)
            }
        }
        return nil
    }

    // MARK: - When Expression

    private func lowerWhenExpr(_ we: WhenExpr) -> String {
        let subject: String?
        if let subjectExpr = we.subject {
            subject = lowerExpression(subjectExpr)
        } else {
            subject = nil
        }

        let mergeLabel = builder.newBlockLabel("when.merge")
        let resultSlot = builder.emitAlloc(type: .unit)

        for (index, entry) in we.entries.enumerated() {
            let bodyLabel = builder.newBlockLabel("when.body\(index)")
            let nextLabel: String
            if index + 1 < we.entries.count {
                nextLabel = builder.newBlockLabel("when.check\(index + 1)")
            } else {
                nextLabel = mergeLabel
            }

            // If there's a guard, conditions branch to the guard block first
            let condTarget: String
            if entry.guard_ != nil {
                condTarget = builder.newBlockLabel("when.guard\(index)")
            } else {
                condTarget = bodyLabel
            }

            // Evaluate condition
            var isElse = false
            for condition in entry.conditions {
                switch condition {
                case .expression(let expr):
                    if case .identifier(let name, _) = expr, name == "else" {
                        isElse = true
                    } else if let subj = subject {
                        let condVal = lowerExpression(expr)
                        let cmpTemp = builder.newTemp()
                        builder.emit(.eq(dest: cmpTemp, lhs: subj, rhs: condVal, type: .unit))
                        builder.terminate(.branch(condition: cmpTemp, thenLabel: condTarget, elseLabel: nextLabel))
                    } else {
                        let condVal = lowerExpression(expr)
                        builder.terminate(.branch(condition: condVal, thenLabel: condTarget, elseLabel: nextLabel))
                    }
                case .isType(_, _):
                    if let subj = subject {
                        let checkTemp = builder.newTemp()
                        let typeName = typeNodeName(condition)
                        builder.emit(.typeCheck(dest: checkTemp, operand: subj, typeName: typeName))
                        builder.terminate(.branch(condition: checkTemp, thenLabel: condTarget, elseLabel: nextLabel))
                    }
                case .isTypeWithBindings(_, _, _):
                    if let subj = subject {
                        let checkTemp = builder.newTemp()
                        let typeName = typeNodeName(condition)
                        builder.emit(.typeCheck(dest: checkTemp, operand: subj, typeName: typeName))
                        builder.terminate(.branch(condition: checkTemp, thenLabel: condTarget, elseLabel: nextLabel))
                    }
                case .inRange(let startExpr, let endExpr, _):
                    if let subj = subject {
                        let startVal = lowerExpression(startExpr)
                        let endVal = lowerExpression(endExpr)
                        let geTemp = builder.newTemp()
                        builder.emit(.gte(dest: geTemp, lhs: subj, rhs: startVal, type: .int))
                        let leTemp = builder.newTemp()
                        builder.emit(.lte(dest: leTemp, lhs: subj, rhs: endVal, type: .int))
                        let andTemp = builder.newTemp()
                        builder.emit(.and(dest: andTemp, lhs: geTemp, rhs: leTemp))
                        builder.terminate(.branch(condition: andTemp, thenLabel: condTarget, elseLabel: nextLabel))
                    }
                }
            }

            if isElse {
                builder.terminate(.jump(condTarget))
            }

            // Guard block (if present)
            if let guardExpr = entry.guard_ {
                builder.startBlock(label: condTarget)
                let guardVal = lowerExpression(guardExpr)
                builder.terminate(.branch(condition: guardVal, thenLabel: bodyLabel, elseLabel: nextLabel))
            }

            // Body
            builder.startBlock(label: bodyLabel)

            // Emit destructuring bindings for isTypeWithBindings
            for condition in entry.conditions {
                if case .isTypeWithBindings(_, let bindings, _) = condition, let subj = subject {
                    let typeName = typeNodeName(condition)
                    // Look up field names from type declaration
                    let fieldNames: [String]
                    if let typeInfo = result.symbolTable.lookupType(typeName) {
                        fieldNames = typeInfo.members.filter { sym in
                            if case .variable = sym.kind { return true }
                            return false
                        }.map { $0.name }
                    } else {
                        fieldNames = bindings // Fallback: use binding names as field names
                    }
                    for (i, binding) in bindings.enumerated() {
                        let fieldName = i < fieldNames.count ? fieldNames[i] : binding
                        let fieldTemp = builder.newTemp()
                        builder.emit(.getField(dest: fieldTemp, object: subj, fieldName: fieldName))
                        let slot = builder.emitAlloc(type: .int)
                        locals[binding] = slot
                        builder.emitStore(dest: slot, src: fieldTemp)
                    }
                }
            }

            switch entry.body {
            case .expression(let expr):
                let val = lowerExpression(expr)
                builder.emitStore(dest: resultSlot, src: val)
            case .block(let block):
                lowerBlock(block)
            }
            if !builder.isTerminated {
                builder.terminate(.jump(mergeLabel))
            }

            // Next check block (if not last)
            if index + 1 < we.entries.count {
                builder.startBlock(label: nextLabel)
            }
        }

        // Merge
        builder.startBlock(label: mergeLabel)
        return builder.emitLoad(src: resultSlot)
    }

    // MARK: - Lambda

    private func lowerLambda(_ le: LambdaExpr) -> String {
        let lambdaBuilder = MIRBuilder()
        let lambdaName = "__lambda_\(lambdaCounter)"
        lambdaCounter += 1

        let savedLocals = locals
        let savedBuilder = builder

        // Detect captured variables: identifiers in the lambda body that exist in the enclosing scope
        let paramNames = Set(le.parameters.map { $0.name })
        var freeVarNames: Set<String> = []
        for stmt in le.body {
            collectFreeVars(stmt: stmt, into: &freeVarNames)
        }
        let captures = freeVarNames.filter { savedLocals[$0] != nil && !paramNames.contains($0) }.sorted()

        locals = [:]
        builder = lambdaBuilder

        // Build parameter list: captured vars first, then user params
        var allParams: [(String, MIRType)] = captures.map { ("__cap_\($0)", .reference("Any")) }
        let userParams: [(String, MIRType)] = le.parameters.map { p in
            let type: MIRType = p.type.flatMap { _ in
                if let sym = result.symbolTable.lookup(p.name) {
                    return MIRType.from(sym.type)
                }
                return nil
            } ?? .unit
            return (p.name, type)
        }
        allParams.append(contentsOf: userParams)

        builder.startBlock(label: "entry")
        // Set up captured var locals
        for capName in captures {
            let slot = builder.emitAlloc(type: .reference("Any"))
            locals[capName] = slot
            let paramTemp = builder.newTemp()
            builder.emit(.load(dest: paramTemp, src: "param.__cap_\(capName)"))
            builder.emitStore(dest: slot, src: paramTemp)
        }
        // Set up user param locals
        for (name, type) in userParams {
            let slot = builder.emitAlloc(type: type)
            locals[name] = slot
            let paramTemp = builder.newTemp()
            builder.emit(.load(dest: paramTemp, src: "param.\(name)"))
            builder.emitStore(dest: slot, src: paramTemp)
        }

        // Lower body
        if le.body.count > 1 {
            for stmt in le.body.dropLast() {
                lowerStatement(stmt)
            }
        }
        if !builder.isTerminated, let lastStmt = le.body.last {
            if case .expression(let expr) = lastStmt {
                let resultTemp = lowerExpression(expr)
                builder.terminate(.ret(resultTemp))
            } else {
                lowerStatement(lastStmt)
                if !builder.isTerminated {
                    builder.terminate(.ret(nil))
                }
            }
        } else if !builder.isTerminated {
            builder.terminate(.ret(nil))
        }

        let blocks = builder.finishBlocks()
        let mirFunc = MIRFunction(name: lambdaName, parameters: allParams, returnType: .unit, blocks: blocks)
        functions.append(mirFunc)

        builder = savedBuilder
        locals = savedLocals

        if captures.isEmpty {
            // No captures: return function name string directly
            return builder.emitConstString(lambdaName)
        }

        // Build closure list: [funcName, cap0, cap1, ...]
        let listTemp = builder.newTemp()
        builder.emit(.call(dest: listTemp, function: "listCreate", args: []))
        let fnNameTemp = builder.emitConstString(lambdaName)
        builder.emit(.call(dest: nil, function: "listAppend", args: [listTemp, fnNameTemp]))
        for capName in captures {
            let capVal = builder.emitLoad(src: savedLocals[capName]!)
            builder.emit(.call(dest: nil, function: "listAppend", args: [listTemp, capVal]))
        }
        return listTemp
    }

    // MARK: - Free Variable Collection

    private func collectFreeVars(stmt: Statement, into names: inout Set<String>) {
        switch stmt {
        case .expression(let expr):
            collectFreeVars(expr: expr, into: &names)
        case .propertyDecl(let p):
            if let e = p.initializer { collectFreeVars(expr: e, into: &names) }
        case .returnStmt(let e, _):
            if let e = e { collectFreeVars(expr: e, into: &names) }
        case .throwStmt(let e, _):
            collectFreeVars(expr: e, into: &names)
        case .assignment(let a):
            collectFreeVars(expr: a.value, into: &names)
            if case .identifier(let n, _) = a.target { names.insert(n) }
        case .forLoop(let f):
            collectFreeVars(expr: f.iterable, into: &names)
            f.body.statements.forEach { collectFreeVars(stmt: $0, into: &names) }
        case .whileLoop(let w):
            collectFreeVars(expr: w.condition, into: &names)
            w.body.statements.forEach { collectFreeVars(stmt: $0, into: &names) }
        case .doWhileLoop(let d):
            collectFreeVars(expr: d.condition, into: &names)
            d.body.statements.forEach { collectFreeVars(stmt: $0, into: &names) }
        case .tryCatch(let tc):
            tc.tryBody.statements.forEach { collectFreeVars(stmt: $0, into: &names) }
            tc.catchBody.statements.forEach { collectFreeVars(stmt: $0, into: &names) }
            tc.finallyBody?.statements.forEach { collectFreeVars(stmt: $0, into: &names) }
        case .declaration(let d):
            if case .function(let f) = d {
                if case .block(let b) = f.body { b.statements.forEach { collectFreeVars(stmt: $0, into: &names) } }
            }
        case .destructuringDecl(let d):
            collectFreeVars(expr: d.initializer, into: &names)
        default: break
        }
    }

    private func collectFreeVars(expr: Expression, into names: inout Set<String>) {
        switch expr {
        case .identifier(let n, _): names.insert(n)
        case .binary(let l, _, let r, _):
            collectFreeVars(expr: l, into: &names)
            collectFreeVars(expr: r, into: &names)
        case .unaryPrefix(_, let e, _): collectFreeVars(expr: e, into: &names)
        case .unaryPostfix(let e, _, _): collectFreeVars(expr: e, into: &names)
        case .call(let callee, let args, let trailing, _):
            collectFreeVars(expr: callee, into: &names)
            args.forEach { collectFreeVars(expr: $0.value, into: &names) }
            if let t = trailing { t.body.forEach { collectFreeVars(stmt: $0, into: &names) } }
        case .memberAccess(let obj, _, _): collectFreeVars(expr: obj, into: &names)
        case .nullSafeMemberAccess(let obj, _, _): collectFreeVars(expr: obj, into: &names)
        case .subscriptAccess(let obj, let idx, _):
            collectFreeVars(expr: obj, into: &names)
            collectFreeVars(expr: idx, into: &names)
        case .ifExpr(let ie):
            collectFreeVars(expr: ie.condition, into: &names)
            ie.thenBranch.statements.forEach { collectFreeVars(stmt: $0, into: &names) }
            if let el = ie.elseBranch {
                switch el {
                case .elseBlock(let b): b.statements.forEach { collectFreeVars(stmt: $0, into: &names) }
                case .elseIf(let eif): collectFreeVars(expr: .ifExpr(eif), into: &names)
                }
            }
        case .whenExpr(let we):
            if let subj = we.subject { collectFreeVars(expr: subj, into: &names) }
            for entry in we.entries {
                for cond in entry.conditions {
                    if case .expression(let e) = cond { collectFreeVars(expr: e, into: &names) }
                    if case .inRange(let s, let e, _) = cond {
                        collectFreeVars(expr: s, into: &names)
                        collectFreeVars(expr: e, into: &names)
                    }
                }
                if let g = entry.guard_ { collectFreeVars(expr: g, into: &names) }
                switch entry.body {
                case .expression(let e): collectFreeVars(expr: e, into: &names)
                case .block(let b): b.statements.forEach { collectFreeVars(stmt: $0, into: &names) }
                }
            }
        case .interpolatedString(let parts, _):
            for part in parts {
                if case .interpolation(let e) = part { collectFreeVars(expr: e, into: &names) }
            }
        case .parenthesized(let e, _): collectFreeVars(expr: e, into: &names)
        case .elvis(let l, let r, _):
            collectFreeVars(expr: l, into: &names)
            collectFreeVars(expr: r, into: &names)
        case .nonNullAssert(let e, _): collectFreeVars(expr: e, into: &names)
        case .awaitExpr(let e, _): collectFreeVars(expr: e, into: &names)
        case .concurrentBlock(let body, _):
            for stmt in body { collectFreeVars(stmt: stmt, into: &names) }
        case .range(let s, let e, _, _):
            collectFreeVars(expr: s, into: &names)
            collectFreeVars(expr: e, into: &names)
        case .lambda(let le):
            le.body.forEach { collectFreeVars(stmt: $0, into: &names) }
        default: break
        }
    }

    // MARK: - Null Safety

    private func lowerNullSafeMemberAccess(object: Expression, member: String) -> String {
        let objTemp = lowerExpression(object)
        let isNullTemp = builder.newTemp()
        builder.emit(.isNull(dest: isNullTemp, operand: objTemp))

        let nonNullLabel = builder.newBlockLabel("safe.nonnull")
        let nullLabel = builder.newBlockLabel("safe.null")
        let mergeLabel = builder.newBlockLabel("safe.merge")

        let resultSlot = builder.emitAlloc(type: .nullable(.unit))

        builder.terminate(.branch(condition: isNullTemp, thenLabel: nullLabel, elseLabel: nonNullLabel))

        // Non-null path
        builder.startBlock(label: nonNullLabel)
        let fieldVal = builder.newTemp()
        builder.emit(.getField(dest: fieldVal, object: objTemp, fieldName: member))
        builder.emitStore(dest: resultSlot, src: fieldVal)
        builder.terminate(.jump(mergeLabel))

        // Null path
        builder.startBlock(label: nullLabel)
        let nullVal = builder.emitConstNull()
        builder.emitStore(dest: resultSlot, src: nullVal)
        builder.terminate(.jump(mergeLabel))

        // Merge
        builder.startBlock(label: mergeLabel)
        return builder.emitLoad(src: resultSlot)
    }

    private func lowerNonNullAssert(expr: Expression) -> String {
        let operandTemp = lowerExpression(expr)
        let dest = builder.newTemp()
        builder.emit(.nullCheck(dest: dest, operand: operandTemp))
        return dest
    }

    private func lowerElvis(left: Expression, right: Expression) -> String {
        let leftVal = lowerExpression(left)
        let isNullTemp = builder.newTemp()
        builder.emit(.isNull(dest: isNullTemp, operand: leftVal))

        let nonNullLabel = builder.newBlockLabel("elvis.nonnull")
        let nullLabel = builder.newBlockLabel("elvis.null")
        let mergeLabel = builder.newBlockLabel("elvis.merge")

        let resultSlot = builder.emitAlloc(type: .unit)

        builder.terminate(.branch(condition: isNullTemp, thenLabel: nullLabel, elseLabel: nonNullLabel))

        // Non-null: use left value
        builder.startBlock(label: nonNullLabel)
        builder.emitStore(dest: resultSlot, src: leftVal)
        builder.terminate(.jump(mergeLabel))

        // Null: evaluate right
        builder.startBlock(label: nullLabel)
        let rightVal = lowerExpression(right)
        builder.emitStore(dest: resultSlot, src: rightVal)
        builder.terminate(.jump(mergeLabel))

        // Merge
        builder.startBlock(label: mergeLabel)
        return builder.emitLoad(src: resultSlot)
    }

    // MARK: - Type Operations

    private func lowerTypeCheck(expr: Expression, typeNode: TypeNode) -> String {
        let operandTemp = lowerExpression(expr)
        let dest = builder.newTemp()
        let typeName = typeNodeSimpleName(typeNode)
        builder.emit(.typeCheck(dest: dest, operand: operandTemp, typeName: typeName))
        return dest
    }

    private func lowerTypeCast(expr: Expression, typeNode: TypeNode) -> String {
        let operandTemp = lowerExpression(expr)
        let dest = builder.newTemp()
        let typeName = typeNodeSimpleName(typeNode)
        builder.emit(.typeCast(dest: dest, operand: operandTemp, typeName: typeName))
        return dest
    }

    private func lowerSafeCast(expr: Expression, typeNode: TypeNode) -> String {
        let operandTemp = lowerExpression(expr)
        let typeName = typeNodeSimpleName(typeNode)

        // Check type, branch on result
        let checkTemp = builder.newTemp()
        builder.emit(.typeCheck(dest: checkTemp, operand: operandTemp, typeName: typeName))

        let castLabel = builder.newBlockLabel("safecast.ok")
        let nullLabel = builder.newBlockLabel("safecast.null")
        let mergeLabel = builder.newBlockLabel("safecast.merge")

        let resultSlot = builder.emitAlloc(type: .nullable(.unit))

        builder.terminate(.branch(condition: checkTemp, thenLabel: castLabel, elseLabel: nullLabel))

        // Cast succeeds
        builder.startBlock(label: castLabel)
        let castTemp = builder.newTemp()
        builder.emit(.typeCast(dest: castTemp, operand: operandTemp, typeName: typeName))
        builder.emitStore(dest: resultSlot, src: castTemp)
        builder.terminate(.jump(mergeLabel))

        // Cast fails — store null
        builder.startBlock(label: nullLabel)
        let nullVal = builder.emitConstNull()
        builder.emitStore(dest: resultSlot, src: nullVal)
        builder.terminate(.jump(mergeLabel))

        // Merge
        builder.startBlock(label: mergeLabel)
        return builder.emitLoad(src: resultSlot)
    }

    // MARK: - Range

    private func lowerRange(start: Expression, end: Expression, inclusive: Bool) -> String {
        let startTemp = lowerExpression(start)
        let endTemp = lowerExpression(end)
        let rangeName = inclusive ? "rangeTo" : "rangeUntil"
        let dest = builder.newTemp()
        builder.emit(.call(dest: dest, function: rangeName, args: [startTemp, endTemp]))
        return dest
    }

    // MARK: - Helpers

    /// Look up the MIR type for an expression using the type map.
    private func lookupExprType(_ expr: Expression) -> MIRType {
        let id = ExpressionID(expr.span)
        if let type = result.typeMap[id] {
            return MIRType.from(type)
        }
        return .unit
    }

    /// Extract a simple name from a TypeNode.
    private func typeNodeSimpleName(_ node: TypeNode) -> String {
        switch node {
        case .simple(let name, _, _):
            return name
        case .nullable(let inner, _):
            return typeNodeSimpleName(inner) + "?"
        case .qualified(_, let member, _):
            return member
        default:
            return "Any"
        }
    }

    /// Extract a type name from a WhenCondition.
    private func typeNodeName(_ condition: WhenCondition) -> String {
        switch condition {
        case .isType(let typeNode, _):
            return typeNodeSimpleName(typeNode)
        case .isTypeWithBindings(let typeNode, _, _):
            return typeNodeSimpleName(typeNode)
        case .expression, .inRange:
            return "Any"
        }
    }
}
