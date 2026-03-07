// AST.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - Top-Level

/// A complete Rockit source file
public struct SourceFile {
    public let packageDecl: PackageDecl?
    public let imports: [ImportDecl]
    public let declarations: [Declaration]
    public let span: SourceSpan

    public init(packageDecl: PackageDecl?, imports: [ImportDecl],
                declarations: [Declaration], span: SourceSpan) {
        self.packageDecl = packageDecl
        self.imports = imports
        self.declarations = declarations
        self.span = span
    }
}

/// Package declaration: `package com.darkmatter.hello`
public struct PackageDecl {
    public let path: [String]
    public let span: SourceSpan

    public init(path: [String], span: SourceSpan) {
        self.path = path
        self.span = span
    }
}

/// Import declaration: `import moon.core.List`
public struct ImportDecl {
    public let path: [String]
    public let span: SourceSpan

    public init(path: [String], span: SourceSpan) {
        self.path = path
        self.span = span
    }
}

// MARK: - Modifiers and Annotations

/// Declaration modifiers
public enum Modifier: Hashable {
    case `public`
    case `private`
    case `internal`
    case protected
    case data
    case sealed
    case open
    case abstract
    case override
    case suspend
    case async
    case weak
    case unowned
}

/// Annotation: `@Capability(requires = Capability.Payments)`
public struct Annotation {
    public let name: String
    public let arguments: [CallArgument]
    public let span: SourceSpan

    public init(name: String, arguments: [CallArgument], span: SourceSpan) {
        self.name = name
        self.arguments = arguments
        self.span = span
    }
}

// MARK: - Declarations

/// Top-level and member declarations
public enum Declaration {
    case function(FunctionDecl)
    case property(PropertyDecl)
    case classDecl(ClassDecl)
    case interfaceDecl(InterfaceDecl)
    case enumDecl(EnumClassDecl)
    case objectDecl(ObjectDecl)
    case actorDecl(ActorDecl)
    case viewDecl(ViewDecl)
    case navigationDecl(NavigationDecl)
    case themeDecl(ThemeDecl)
    case typeAlias(TypeAliasDecl)
}

/// Function declaration
public struct FunctionDecl {
    public let annotations: [Annotation]
    public let modifiers: Set<Modifier>
    public let name: String
    public let receiverType: String?
    public let typeParameters: [TypeParameter]
    public let parameters: [Parameter]
    public let returnType: TypeNode?
    public let body: FunctionBody?
    public let span: SourceSpan

    public init(annotations: [Annotation], modifiers: Set<Modifier>, name: String,
                receiverType: String? = nil,
                typeParameters: [TypeParameter], parameters: [Parameter],
                returnType: TypeNode?, body: FunctionBody?, span: SourceSpan) {
        self.annotations = annotations
        self.modifiers = modifiers
        self.name = name
        self.receiverType = receiverType
        self.typeParameters = typeParameters
        self.parameters = parameters
        self.returnType = returnType
        self.body = body
        self.span = span
    }
}

/// Function body — either a block or a single expression
public enum FunctionBody {
    case block(Block)
    case expression(Expression)
}

/// A parameter in a function or constructor
public struct Parameter {
    public let name: String
    public let type: TypeNode?
    public let defaultValue: Expression?
    public let isVal: Bool
    public let isVar: Bool
    public let isVararg: Bool
    public let span: SourceSpan

    public init(name: String, type: TypeNode?, defaultValue: Expression?,
                isVal: Bool = false, isVar: Bool = false, isVararg: Bool = false, span: SourceSpan) {
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
        self.isVal = isVal
        self.isVar = isVar
        self.isVararg = isVararg
        self.span = span
    }
}

/// Type parameter: `<T>`, `<out T>`, `<T : Entity>`
public struct TypeParameter {
    public let variance: Variance?
    public let name: String
    public let upperBound: TypeNode?
    public let span: SourceSpan

    public init(variance: Variance?, name: String, upperBound: TypeNode?, span: SourceSpan) {
        self.variance = variance
        self.name = name
        self.upperBound = upperBound
        self.span = span
    }
}

/// Generic variance annotation
public enum Variance {
    case `in`
    case out
}

/// Property declaration: `val`/`var`
public struct PropertyDecl {
    public let annotations: [Annotation]
    public let modifiers: Set<Modifier>
    public let isVal: Bool
    public let name: String
    public let type: TypeNode?
    public let initializer: Expression?
    public let span: SourceSpan

    public init(annotations: [Annotation], modifiers: Set<Modifier>, isVal: Bool,
                name: String, type: TypeNode?, initializer: Expression?, span: SourceSpan) {
        self.annotations = annotations
        self.modifiers = modifiers
        self.isVal = isVal
        self.name = name
        self.type = type
        self.initializer = initializer
        self.span = span
    }
}

/// Class declaration (includes data class and sealed class)
public struct ClassDecl {
    public let annotations: [Annotation]
    public let modifiers: Set<Modifier>
    public let name: String
    public let typeParameters: [TypeParameter]
    public let constructorParams: [Parameter]
    public let superTypes: [TypeNode]
    public let superCallArgs: [CallArgument]
    public let members: [Declaration]
    public let span: SourceSpan

    public init(annotations: [Annotation], modifiers: Set<Modifier>, name: String,
                typeParameters: [TypeParameter], constructorParams: [Parameter],
                superTypes: [TypeNode], superCallArgs: [CallArgument],
                members: [Declaration], span: SourceSpan) {
        self.annotations = annotations
        self.modifiers = modifiers
        self.name = name
        self.typeParameters = typeParameters
        self.constructorParams = constructorParams
        self.superTypes = superTypes
        self.superCallArgs = superCallArgs
        self.members = members
        self.span = span
    }
}

/// Interface declaration
public struct InterfaceDecl {
    public let annotations: [Annotation]
    public let name: String
    public let typeParameters: [TypeParameter]
    public let superTypes: [TypeNode]
    public let members: [Declaration]
    public let span: SourceSpan

    public init(annotations: [Annotation], name: String, typeParameters: [TypeParameter],
                superTypes: [TypeNode], members: [Declaration], span: SourceSpan) {
        self.annotations = annotations
        self.name = name
        self.typeParameters = typeParameters
        self.superTypes = superTypes
        self.members = members
        self.span = span
    }
}

/// Enum class declaration
public struct EnumClassDecl {
    public let annotations: [Annotation]
    public let name: String
    public let typeParameters: [TypeParameter]
    public let entries: [EnumEntry]
    public let members: [Declaration]
    public let span: SourceSpan

    public init(annotations: [Annotation], name: String, typeParameters: [TypeParameter],
                entries: [EnumEntry], members: [Declaration], span: SourceSpan) {
        self.annotations = annotations
        self.name = name
        self.typeParameters = typeParameters
        self.entries = entries
        self.members = members
        self.span = span
    }
}

/// A single enum entry
public struct EnumEntry {
    public let name: String
    public let arguments: [CallArgument]
    public let span: SourceSpan

    public init(name: String, arguments: [CallArgument], span: SourceSpan) {
        self.name = name
        self.arguments = arguments
        self.span = span
    }
}

/// Object declaration (including companion)
public struct ObjectDecl {
    public let annotations: [Annotation]
    public let modifiers: Set<Modifier>
    public let isCompanion: Bool
    public let name: String
    public let superTypes: [TypeNode]
    public let superCallArgs: [CallArgument]
    public let members: [Declaration]
    public let span: SourceSpan

    public init(annotations: [Annotation], modifiers: Set<Modifier>, name: String,
                isCompanion: Bool = false,
                superTypes: [TypeNode], superCallArgs: [CallArgument],
                members: [Declaration], span: SourceSpan) {
        self.annotations = annotations
        self.modifiers = modifiers
        self.isCompanion = isCompanion
        self.name = name
        self.superTypes = superTypes
        self.superCallArgs = superCallArgs
        self.members = members
        self.span = span
    }
}

/// Actor declaration
public struct ActorDecl {
    public let annotations: [Annotation]
    public let name: String
    public let members: [Declaration]
    public let span: SourceSpan

    public init(annotations: [Annotation], name: String, members: [Declaration], span: SourceSpan) {
        self.annotations = annotations
        self.name = name
        self.members = members
        self.span = span
    }
}

/// View declaration
public struct ViewDecl {
    public let annotations: [Annotation]
    public let name: String
    public let parameters: [Parameter]
    public let body: Block
    public let span: SourceSpan

    public init(annotations: [Annotation], name: String, parameters: [Parameter],
                body: Block, span: SourceSpan) {
        self.annotations = annotations
        self.name = name
        self.parameters = parameters
        self.body = body
        self.span = span
    }
}

/// Navigation declaration
public struct NavigationDecl {
    public let name: String
    public let body: Block
    public let span: SourceSpan

    public init(name: String, body: Block, span: SourceSpan) {
        self.name = name
        self.body = body
        self.span = span
    }
}

/// Theme declaration
public struct ThemeDecl {
    public let name: String
    public let body: Block
    public let span: SourceSpan

    public init(name: String, body: Block, span: SourceSpan) {
        self.name = name
        self.body = body
        self.span = span
    }
}

/// Type alias declaration
public struct TypeAliasDecl {
    public let name: String
    public let typeParameters: [TypeParameter]
    public let type: TypeNode
    public let span: SourceSpan

    public init(name: String, typeParameters: [TypeParameter], type: TypeNode, span: SourceSpan) {
        self.name = name
        self.typeParameters = typeParameters
        self.type = type
        self.span = span
    }
}

// MARK: - Type Nodes

/// A type annotation in source code
public indirect enum TypeNode {
    case simple(name: String, typeArguments: [TypeNode], span: SourceSpan)
    case nullable(TypeNode, span: SourceSpan)
    case function(parameterTypes: [TypeNode], returnType: TypeNode, span: SourceSpan)
    case tuple(elements: [TypeNode], span: SourceSpan)
    case qualified(base: TypeNode, member: String, span: SourceSpan)
}

// MARK: - Statements

/// A block of statements: `{ ... }`
public struct Block {
    public let statements: [Statement]
    public let span: SourceSpan

    public init(statements: [Statement], span: SourceSpan) {
        self.statements = statements
        self.span = span
    }
}

/// A statement within a block
public enum Statement {
    case propertyDecl(PropertyDecl)
    case expression(Expression)
    case returnStmt(Expression?, SourceSpan)
    case breakStmt(SourceSpan)
    case continueStmt(SourceSpan)
    case throwStmt(Expression, SourceSpan)
    case tryCatch(TryCatch)
    case assignment(AssignmentStmt)
    case forLoop(ForLoop)
    case whileLoop(WhileLoop)
    case doWhileLoop(DoWhileLoop)
    case declaration(Declaration)
    case destructuringDecl(DestructuringDecl)
}

/// Destructuring val declaration: `val (a, b, c) = expr`
public struct DestructuringDecl {
    public let names: [String]
    public let initializer: Expression
    public let span: SourceSpan

    public init(names: [String], initializer: Expression, span: SourceSpan) {
        self.names = names
        self.initializer = initializer
        self.span = span
    }
}

/// Assignment statement
public struct AssignmentStmt {
    public let target: Expression
    public let op: AssignmentOp
    public let value: Expression
    public let span: SourceSpan

    public init(target: Expression, op: AssignmentOp, value: Expression, span: SourceSpan) {
        self.target = target
        self.op = op
        self.value = value
        self.span = span
    }
}

/// Assignment operators
public enum AssignmentOp {
    case assign
    case plusAssign
    case minusAssign
    case timesAssign
    case divideAssign
    case moduloAssign
}

/// For-in loop
public struct ForLoop {
    public let variable: String
    /// Destructured variable names for map iteration: `for ((k, v) in map)`
    public let destructuredVariables: [String]?
    public let iterable: Expression
    public let body: Block
    public let span: SourceSpan

    public init(variable: String, iterable: Expression, body: Block, span: SourceSpan) {
        self.variable = variable
        self.destructuredVariables = nil
        self.iterable = iterable
        self.body = body
        self.span = span
    }

    public init(destructuredVariables: [String], iterable: Expression, body: Block, span: SourceSpan) {
        self.variable = destructuredVariables.joined(separator: "_")
        self.destructuredVariables = destructuredVariables
        self.iterable = iterable
        self.body = body
        self.span = span
    }
}

/// While loop
public struct WhileLoop {
    public let condition: Expression
    public let body: Block
    public let span: SourceSpan

    public init(condition: Expression, body: Block, span: SourceSpan) {
        self.condition = condition
        self.body = body
        self.span = span
    }
}

/// Do-while loop
public struct DoWhileLoop {
    public let body: Block
    public let condition: Expression
    public let span: SourceSpan

    public init(body: Block, condition: Expression, span: SourceSpan) {
        self.body = body
        self.condition = condition
        self.span = span
    }
}

/// Try-catch statement
public struct TryCatch {
    public let tryBody: Block
    public let catchVariable: String
    public let catchBody: Block
    public let finallyBody: Block?
    public let span: SourceSpan

    public init(tryBody: Block, catchVariable: String, catchBody: Block, finallyBody: Block? = nil, span: SourceSpan) {
        self.tryBody = tryBody
        self.catchVariable = catchVariable
        self.catchBody = catchBody
        self.finallyBody = finallyBody
        self.span = span
    }
}

// MARK: - Expressions

/// An expression in the AST
public indirect enum Expression {
    // Literals
    case intLiteral(Int64, SourceSpan)
    case floatLiteral(Double, SourceSpan)
    case stringLiteral(String, SourceSpan)
    case interpolatedString([StringPart], SourceSpan)
    case boolLiteral(Bool, SourceSpan)
    case nullLiteral(SourceSpan)

    // References
    case identifier(String, SourceSpan)
    case `this`(SourceSpan)
    case `super`(SourceSpan)

    // Operators
    case binary(left: Expression, op: BinaryOp, right: Expression, span: SourceSpan)
    case unaryPrefix(op: UnaryOp, operand: Expression, span: SourceSpan)
    case unaryPostfix(operand: Expression, op: PostfixOp, span: SourceSpan)

    // Access
    case memberAccess(object: Expression, member: String, span: SourceSpan)
    case nullSafeMemberAccess(object: Expression, member: String, span: SourceSpan)
    case subscriptAccess(object: Expression, index: Expression, span: SourceSpan)

    // Calls
    case call(callee: Expression, arguments: [CallArgument], trailingLambda: LambdaExpr?, span: SourceSpan)

    // Control-flow expressions
    case ifExpr(IfExpr)
    case whenExpr(WhenExpr)

    // Lambdas
    case lambda(LambdaExpr)

    // Type operations
    case typeCheck(Expression, TypeNode, span: SourceSpan)
    case typeCast(Expression, TypeNode, span: SourceSpan)
    case safeCast(Expression, TypeNode, span: SourceSpan)
    case nonNullAssert(Expression, span: SourceSpan)

    // Concurrency
    case awaitExpr(Expression, span: SourceSpan)
    case concurrentBlock(body: [Statement], span: SourceSpan)

    // Elvis
    case elvis(left: Expression, right: Expression, span: SourceSpan)

    // Ranges
    case range(start: Expression, end: Expression, inclusive: Bool, span: SourceSpan)

    // Parenthesized
    case parenthesized(Expression, span: SourceSpan)

    // Error node for recovery
    case error(SourceSpan)
}

/// Part of an interpolated string
public enum StringPart {
    case literal(String)
    case interpolation(Expression)
}

/// A call argument (positional or named)
public struct CallArgument {
    public let label: String?
    public let value: Expression
    public let span: SourceSpan

    public init(label: String?, value: Expression, span: SourceSpan) {
        self.label = label
        self.value = value
        self.span = span
    }
}

/// Binary operators
public enum BinaryOp: String {
    case plus = "+"
    case minus = "-"
    case times = "*"
    case divide = "/"
    case modulo = "%"
    case equalEqual = "=="
    case notEqual = "!="
    case less = "<"
    case lessEqual = "<="
    case greater = ">"
    case greaterEqual = ">="
    case and = "&&"
    case or = "||"
}

/// Unary prefix operators
public enum UnaryOp: String {
    case negate = "-"
    case not = "!"
}

/// Postfix operators
public enum PostfixOp: String {
    case nonNullAssert = "!!"
}

/// Lambda expression
public struct LambdaExpr {
    public let parameters: [Parameter]
    public let body: [Statement]
    public let span: SourceSpan

    public init(parameters: [Parameter], body: [Statement], span: SourceSpan) {
        self.parameters = parameters
        self.body = body
        self.span = span
    }
}

/// If expression (also used as statement)
public struct IfExpr {
    public let condition: Expression
    public let thenBranch: Block
    public let elseBranch: ElseBranch?
    public let span: SourceSpan

    public init(condition: Expression, thenBranch: Block, elseBranch: ElseBranch?, span: SourceSpan) {
        self.condition = condition
        self.thenBranch = thenBranch
        self.elseBranch = elseBranch
        self.span = span
    }
}

/// Else branch of an if expression
public indirect enum ElseBranch {
    case elseBlock(Block)
    case elseIf(IfExpr)
}

/// When expression
public struct WhenExpr {
    public let subject: Expression?
    public let entries: [WhenEntry]
    public let span: SourceSpan

    public init(subject: Expression?, entries: [WhenEntry], span: SourceSpan) {
        self.subject = subject
        self.entries = entries
        self.span = span
    }
}

/// A single when entry
public struct WhenEntry {
    public let conditions: [WhenCondition]
    public let guard_: Expression?
    public let body: WhenBody
    public let span: SourceSpan

    public init(conditions: [WhenCondition], guard_: Expression? = nil, body: WhenBody, span: SourceSpan) {
        self.conditions = conditions
        self.guard_ = guard_
        self.body = body
        self.span = span
    }
}

/// Body of a when entry — either a single expression or a block
public enum WhenBody {
    case expression(Expression)
    case block(Block)
}

/// A condition in a when entry
public enum WhenCondition {
    case expression(Expression)
    case isType(TypeNode, SourceSpan)
    case inRange(Expression, Expression, SourceSpan) // in start..end
    case isTypeWithBindings(TypeNode, [String], SourceSpan) // is Type(val a, val b)
}

// MARK: - AST Dump

extension SourceFile {
    public func dump(indent: Int = 0) -> String {
        var lines: [String] = []
        let pad = String(repeating: "  ", count: indent)
        lines.append("\(pad)SourceFile")
        if let pkg = packageDecl {
            lines.append(pkg.dump(indent: indent + 1))
        }
        for imp in imports {
            lines.append(imp.dump(indent: indent + 1))
        }
        for decl in declarations {
            lines.append(decl.dump(indent: indent + 1))
        }
        return lines.joined(separator: "\n")
    }
}

extension PackageDecl {
    public func dump(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        return "\(pad)PackageDecl: \(path.joined(separator: "."))"
    }
}

extension ImportDecl {
    public func dump(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        return "\(pad)ImportDecl: \(path.joined(separator: "."))"
    }
}

extension Declaration {
    public func dump(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch self {
        case .function(let f):
            var header = "\(pad)FunctionDecl: "
            if !f.modifiers.isEmpty {
                header += f.modifiers.map { "\($0)" }.joined(separator: " ") + " "
            }
            if let receiver = f.receiverType {
                header += "fun \(receiver).\(f.name)"
            } else {
                header += "fun \(f.name)"
            }
            if !f.typeParameters.isEmpty {
                header += "<\(f.typeParameters.map { $0.name }.joined(separator: ", "))>"
            }
            header += "(\(f.parameters.map { paramSummary($0) }.joined(separator: ", ")))"
            if let ret = f.returnType {
                header += ": \(ret.summary)"
            }
            var lines = [header]
            if let body = f.body {
                lines.append(body.dump(indent: indent + 1))
            }
            return lines.joined(separator: "\n")

        case .property(let p):
            var s = "\(pad)PropertyDecl: \(p.isVal ? "val" : "var") \(p.name)"
            if let t = p.type { s += ": \(t.summary)" }
            if let init_ = p.initializer {
                s += "\n\(init_.dump(indent: indent + 1))"
            }
            return s

        case .classDecl(let c):
            var header = "\(pad)ClassDecl: "
            if c.modifiers.contains(.data) { header += "data " }
            if c.modifiers.contains(.sealed) { header += "sealed " }
            if c.modifiers.contains(.abstract) { header += "abstract " }
            if c.modifiers.contains(.open) { header += "open " }
            header += "class \(c.name)"
            if !c.typeParameters.isEmpty {
                let tpStrings = c.typeParameters.map { tp -> String in
                    var s = ""
                    if let v = tp.variance { s += "\(v) " }
                    s += tp.name
                    return s
                }
                header += "<\(tpStrings.joined(separator: ", "))>"
            }
            var lines = [header]
            for m in c.members {
                lines.append(m.dump(indent: indent + 1))
            }
            return lines.joined(separator: "\n")

        case .interfaceDecl(let i):
            var lines = ["\(pad)InterfaceDecl: \(i.name)"]
            for m in i.members {
                lines.append(m.dump(indent: indent + 1))
            }
            return lines.joined(separator: "\n")

        case .enumDecl(let e):
            var lines = ["\(pad)EnumDecl: \(e.name)"]
            for entry in e.entries {
                lines.append("\(pad)  Entry: \(entry.name)")
            }
            for m in e.members {
                lines.append(m.dump(indent: indent + 1))
            }
            return lines.joined(separator: "\n")

        case .objectDecl(let o):
            let companionPrefix = o.isCompanion ? "companion " : ""
            var lines = ["\(pad)ObjectDecl: \(companionPrefix)\(o.name)"]
            for m in o.members {
                lines.append(m.dump(indent: indent + 1))
            }
            return lines.joined(separator: "\n")

        case .actorDecl(let a):
            var lines = ["\(pad)ActorDecl: \(a.name)"]
            for m in a.members {
                lines.append(m.dump(indent: indent + 1))
            }
            return lines.joined(separator: "\n")

        case .viewDecl(let v):
            var lines = ["\(pad)ViewDecl: \(v.name)(\(v.parameters.map { paramSummary($0) }.joined(separator: ", ")))"]
            lines.append(v.body.dump(indent: indent + 1))
            return lines.joined(separator: "\n")

        case .navigationDecl(let n):
            var lines = ["\(pad)NavigationDecl: \(n.name)"]
            lines.append(n.body.dump(indent: indent + 1))
            return lines.joined(separator: "\n")

        case .themeDecl(let t):
            var lines = ["\(pad)ThemeDecl: \(t.name)"]
            lines.append(t.body.dump(indent: indent + 1))
            return lines.joined(separator: "\n")

        case .typeAlias(let ta):
            return "\(pad)TypeAlias: \(ta.name) = \(ta.type.summary)"
        }
    }
}

extension FunctionBody {
    public func dump(indent: Int = 0) -> String {
        switch self {
        case .block(let b):
            return b.dump(indent: indent)
        case .expression(let e):
            let pad = String(repeating: "  ", count: indent)
            return "\(pad)ExprBody:\n\(e.dump(indent: indent + 1))"
        }
    }
}

extension Block {
    public func dump(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        var lines = ["\(pad)Block"]
        for stmt in statements {
            lines.append(stmt.dump(indent: indent + 1))
        }
        return lines.joined(separator: "\n")
    }
}

extension Statement {
    public func dump(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch self {
        case .propertyDecl(let p):
            return Declaration.property(p).dump(indent: indent)
        case .expression(let e):
            return e.dump(indent: indent)
        case .returnStmt(let e, _):
            if let e = e {
                return "\(pad)Return\n\(e.dump(indent: indent + 1))"
            }
            return "\(pad)Return"
        case .breakStmt:
            return "\(pad)Break"
        case .continueStmt:
            return "\(pad)Continue"
        case .throwStmt(let e, _):
            return "\(pad)Throw\n\(e.dump(indent: indent + 1))"
        case .tryCatch(let tc):
            return "\(pad)TryCatch(\(tc.catchVariable))\n\(tc.tryBody.dump(indent: indent + 1))\n\(tc.catchBody.dump(indent: indent + 1))"
        case .assignment(let a):
            return "\(pad)Assignment(\(a.op))\n\(a.target.dump(indent: indent + 1))\n\(a.value.dump(indent: indent + 1))"
        case .forLoop(let f):
            if let vars = f.destructuredVariables {
                return "\(pad)For((\(vars.joined(separator: ", "))) in)\n\(f.iterable.dump(indent: indent + 1))\n\(f.body.dump(indent: indent + 1))"
            }
            return "\(pad)For(\(f.variable) in)\n\(f.iterable.dump(indent: indent + 1))\n\(f.body.dump(indent: indent + 1))"
        case .whileLoop(let w):
            return "\(pad)While\n\(w.condition.dump(indent: indent + 1))\n\(w.body.dump(indent: indent + 1))"
        case .doWhileLoop(let d):
            return "\(pad)DoWhile\n\(d.body.dump(indent: indent + 1))\n\(d.condition.dump(indent: indent + 1))"
        case .declaration(let d):
            return d.dump(indent: indent)
        case .destructuringDecl(let d):
            return "\(pad)Destructure(\(d.names.joined(separator: ", ")))\n\(d.initializer.dump(indent: indent + 1))"
        }
    }
}

extension Expression {
    public func dump(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch self {
        case .intLiteral(let v, _):
            return "\(pad)IntLiteral(\(v))"
        case .floatLiteral(let v, _):
            return "\(pad)FloatLiteral(\(v))"
        case .stringLiteral(let s, _):
            return "\(pad)StringLiteral(\"\(s)\")"
        case .interpolatedString(let parts, _):
            var lines = ["\(pad)InterpolatedString"]
            for part in parts {
                switch part {
                case .literal(let s):
                    lines.append("\(pad)  Literal(\"\(s)\")")
                case .interpolation(let e):
                    lines.append("\(pad)  Interpolation")
                    lines.append(e.dump(indent: indent + 2))
                }
            }
            return lines.joined(separator: "\n")
        case .boolLiteral(let v, _):
            return "\(pad)BoolLiteral(\(v))"
        case .nullLiteral:
            return "\(pad)NullLiteral"
        case .identifier(let name, _):
            return "\(pad)Identifier(\(name))"
        case .this:
            return "\(pad)This"
        case .super:
            return "\(pad)Super"
        case .binary(let l, let op, let r, _):
            return "\(pad)Binary(\(op.rawValue))\n\(l.dump(indent: indent + 1))\n\(r.dump(indent: indent + 1))"
        case .unaryPrefix(let op, let operand, _):
            return "\(pad)UnaryPrefix(\(op.rawValue))\n\(operand.dump(indent: indent + 1))"
        case .unaryPostfix(let operand, let op, _):
            return "\(pad)UnaryPostfix(\(op.rawValue))\n\(operand.dump(indent: indent + 1))"
        case .memberAccess(let obj, let member, _):
            return "\(pad)MemberAccess(.\(member))\n\(obj.dump(indent: indent + 1))"
        case .nullSafeMemberAccess(let obj, let member, _):
            return "\(pad)NullSafeAccess(?.\(member))\n\(obj.dump(indent: indent + 1))"
        case .subscriptAccess(let obj, let idx, _):
            return "\(pad)Subscript\n\(obj.dump(indent: indent + 1))\n\(idx.dump(indent: indent + 1))"
        case .call(let callee, let args, let trailing, _):
            var lines = ["\(pad)Call"]
            lines.append(callee.dump(indent: indent + 1))
            for arg in args {
                let label = arg.label.map { "\($0) = " } ?? ""
                lines.append("\(pad)  Arg(\(label))")
                lines.append(arg.value.dump(indent: indent + 2))
            }
            if let lambda = trailing {
                lines.append("\(pad)  TrailingLambda")
                for stmt in lambda.body {
                    lines.append(stmt.dump(indent: indent + 2))
                }
            }
            return lines.joined(separator: "\n")
        case .ifExpr(let ie):
            var lines = ["\(pad)If"]
            lines.append(ie.condition.dump(indent: indent + 1))
            lines.append(ie.thenBranch.dump(indent: indent + 1))
            if let elseB = ie.elseBranch {
                switch elseB {
                case .elseBlock(let b):
                    lines.append("\(pad)  Else")
                    lines.append(b.dump(indent: indent + 2))
                case .elseIf(let eif):
                    lines.append(Expression.ifExpr(eif).dump(indent: indent + 1))
                }
            }
            return lines.joined(separator: "\n")
        case .whenExpr(let we):
            var lines = ["\(pad)When"]
            if let subj = we.subject {
                lines.append(subj.dump(indent: indent + 1))
            }
            for entry in we.entries {
                lines.append("\(pad)  WhenEntry")
                for cond in entry.conditions {
                    switch cond {
                    case .expression(let e):
                        lines.append(e.dump(indent: indent + 2))
                    case .isType(let t, _):
                        lines.append("\(pad)    is \(t.summary)")
                    case .inRange(let start, let end, _):
                        lines.append("\(pad)    in \(start.dump(indent: 0))..\(end.dump(indent: 0))")
                    case .isTypeWithBindings(let t, let bindings, _):
                        lines.append("\(pad)    is \(t.summary)(\(bindings.joined(separator: ", ")))")
                    }
                }
                switch entry.body {
                case .expression(let e):
                    lines.append(e.dump(indent: indent + 2))
                case .block(let b):
                    lines.append(b.dump(indent: indent + 2))
                }
            }
            return lines.joined(separator: "\n")
        case .lambda(let le):
            var lines = ["\(pad)Lambda"]
            if !le.parameters.isEmpty {
                lines.append("\(pad)  Params: \(le.parameters.map { $0.name }.joined(separator: ", "))")
            }
            for stmt in le.body {
                lines.append(stmt.dump(indent: indent + 1))
            }
            return lines.joined(separator: "\n")
        case .typeCheck(let e, let t, _):
            return "\(pad)TypeCheck(is \(t.summary))\n\(e.dump(indent: indent + 1))"
        case .typeCast(let e, let t, _):
            return "\(pad)TypeCast(as \(t.summary))\n\(e.dump(indent: indent + 1))"
        case .safeCast(let e, let t, _):
            return "\(pad)SafeCast(as? \(t.summary))\n\(e.dump(indent: indent + 1))"
        case .nonNullAssert(let e, _):
            return "\(pad)NonNullAssert(!!)\n\(e.dump(indent: indent + 1))"
        case .awaitExpr(let e, _):
            return "\(pad)Await\n\(e.dump(indent: indent + 1))"
        case .concurrentBlock(let body, _):
            let stmts = body.map { $0.dump(indent: indent + 1) }.joined(separator: "\n")
            return "\(pad)Concurrent\n\(stmts)"
        case .elvis(let l, let r, _):
            return "\(pad)Elvis(?:)\n\(l.dump(indent: indent + 1))\n\(r.dump(indent: indent + 1))"
        case .range(let s, let e, let incl, _):
            return "\(pad)Range(\(incl ? ".." : "..<"))\n\(s.dump(indent: indent + 1))\n\(e.dump(indent: indent + 1))"
        case .parenthesized(let e, _):
            return "\(pad)Paren\n\(e.dump(indent: indent + 1))"
        case .error:
            return "\(pad)Error"
        }
    }
}

extension TypeNode {
    /// Short summary string for type display
    public var summary: String {
        switch self {
        case .simple(let name, let args, _):
            if args.isEmpty { return name }
            return "\(name)<\(args.map { $0.summary }.joined(separator: ", "))>"
        case .nullable(let inner, _):
            return "\(inner.summary)?"
        case .function(let params, let ret, _):
            return "(\(params.map { $0.summary }.joined(separator: ", "))) -> \(ret.summary)"
        case .tuple(let elements, _):
            return "(\(elements.map { $0.summary }.joined(separator: ", ")))"
        case .qualified(let base, let member, _):
            return "\(base.summary).\(member)"
        }
    }
}

/// Helper for parameter display in dump
private func paramSummary(_ p: Parameter) -> String {
    var s = ""
    if p.isVal { s += "val " }
    if p.isVar { s += "var " }
    s += p.name
    if let t = p.type { s += ": \(t.summary)" }
    if p.defaultValue != nil { s += " = ..." }
    return s
}
