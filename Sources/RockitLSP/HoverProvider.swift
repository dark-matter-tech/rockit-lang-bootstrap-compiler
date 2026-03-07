// HoverProvider.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import RockitKit

/// Implements textDocument/hover
public final class HoverProvider {

    /// Compute hover information at the given position
    public static func hover(
        at position: LSPPosition,
        uri: String,
        analysisResult: AnalysisResult
    ) -> LSPHover? {
        let sourcePos = lspPositionToSourceLocation(position, uri: uri)

        guard let nodeCtx = ASTNavigator.findNode(in: analysisResult.ast, at: sourcePos) else {
            return nil
        }

        switch nodeCtx.kind {
        case .expression(let expr):
            return hoverForExpression(expr, analysisResult: analysisResult)

        case .declaration(let decl):
            return hoverForDeclaration(decl, analysisResult: analysisResult)

        case .parameter(let param):
            let typeStr = param.type?.summary ?? "Unknown"
            var text = "```rockit\n\(param.name): \(typeStr)\n```"
            text += "\n\n*(parameter)*"
            return LSPHover(
                contents: LSPMarkupContent(kind: "markdown", value: text),
                range: sourceSpanToLSPRange(param.span)
            )

        case .statement:
            return nil
        }
    }

    // MARK: - Expression Hover

    private static func hoverForExpression(_ expr: RockitKit.Expression, analysisResult: AnalysisResult) -> LSPHover? {
        let span = expressionSpan(expr)
        let exprId = ExpressionID(span)
        let type = analysisResult.typeCheckResult.typeMap[exprId]

        switch expr {
        case .identifier(let name, _):
            if let sym = analysisResult.typeCheckResult.symbolTable.lookup(name) {
                let text = formatSymbolHover(sym, analysisResult: analysisResult)
                return LSPHover(
                    contents: LSPMarkupContent(kind: "markdown", value: text),
                    range: sourceSpanToLSPRange(span)
                )
            }
            if let type = type {
                return LSPHover(
                    contents: LSPMarkupContent(kind: "markdown", value: "```rockit\n\(name): \(type)\n```"),
                    range: sourceSpanToLSPRange(span)
                )
            }

        case .memberAccess(let receiver, let member, _):
            var lines: [String] = []
            // Try to resolve the receiver type and show member detail
            let receiverSpan = expressionSpan(receiver)
            let receiverType = analysisResult.typeCheckResult.typeMap[ExpressionID(receiverSpan)]
            if let receiverType = receiverType {
                lines.append("```rockit")
                if let type = type {
                    lines.append("\(member): \(type)")
                } else {
                    lines.append(member)
                }
                lines.append("```")
                lines.append("")
                lines.append("*member of* `\(receiverType)`")
            } else if let type = type {
                lines.append("```rockit")
                lines.append("\(member): \(type)")
                lines.append("```")
            }
            if !lines.isEmpty {
                return LSPHover(
                    contents: LSPMarkupContent(kind: "markdown", value: lines.joined(separator: "\n")),
                    range: sourceSpanToLSPRange(span)
                )
            }

        case .call(let callee, _, _, _):
            if case .identifier(let name, _) = callee {
                if let sym = analysisResult.typeCheckResult.symbolTable.lookup(name) {
                    let text = formatSymbolHover(sym, analysisResult: analysisResult)
                    return LSPHover(
                        contents: LSPMarkupContent(kind: "markdown", value: text),
                        range: sourceSpanToLSPRange(span)
                    )
                }
            }
            if let type = type {
                return LSPHover(
                    contents: LSPMarkupContent(kind: "markdown", value: "```rockit\n\(type)\n```"),
                    range: sourceSpanToLSPRange(span)
                )
            }

        case .stringLiteral(let value, _):
            return LSPHover(
                contents: LSPMarkupContent(kind: "markdown", value: "```rockit\nString\n```\n\nLength: \(value.count)"),
                range: sourceSpanToLSPRange(span)
            )

        case .intLiteral(let value, _):
            return LSPHover(
                contents: LSPMarkupContent(kind: "markdown", value: "```rockit\nInt\n```\n\nValue: `\(value)`"),
                range: sourceSpanToLSPRange(span)
            )

        case .floatLiteral(let value, _):
            return LSPHover(
                contents: LSPMarkupContent(kind: "markdown", value: "```rockit\nFloat\n```\n\nValue: `\(value)`"),
                range: sourceSpanToLSPRange(span)
            )

        case .boolLiteral(let value, _):
            return LSPHover(
                contents: LSPMarkupContent(kind: "markdown", value: "```rockit\nBool\n```\n\nValue: `\(value)`"),
                range: sourceSpanToLSPRange(span)
            )

        case .nullLiteral(_):
            return LSPHover(
                contents: LSPMarkupContent(kind: "markdown", value: "```rockit\nnull\n```\n\nThe null literal — represents the absence of a value."),
                range: sourceSpanToLSPRange(span)
            )

        case .this(_):
            if let type = type {
                return LSPHover(
                    contents: LSPMarkupContent(kind: "markdown", value: "```rockit\nthis: \(type)\n```\n\nReference to the current instance."),
                    range: sourceSpanToLSPRange(span)
                )
            }

        case .super(_):
            if let type = type {
                return LSPHover(
                    contents: LSPMarkupContent(kind: "markdown", value: "```rockit\nsuper: \(type)\n```\n\nReference to the superclass."),
                    range: sourceSpanToLSPRange(span)
                )
            }

        default:
            if let type = type {
                return LSPHover(
                    contents: LSPMarkupContent(kind: "markdown", value: "```rockit\n\(type)\n```"),
                    range: sourceSpanToLSPRange(span)
                )
            }
        }

        return nil
    }

    // MARK: - Declaration Hover

    private static func hoverForDeclaration(_ decl: Declaration, analysisResult: AnalysisResult) -> LSPHover? {
        let span = declarationSpan(decl)
        var sections: [String] = []

        switch decl {
        case .function(let f):
            sections.append(formatFunctionSignature(f))
            let memberCount = countMembers(in: [])
            _ = memberCount // functions don't have members

        case .property(let p):
            let keyword = p.isVal ? "val" : "var"
            let typeStr = p.type.map { ": \($0.summary)" } ?? ""
            sections.append("```rockit\n\(keyword) \(p.name)\(typeStr)\n```")
            if p.isVal {
                sections.append("*(immutable binding)*")
            } else {
                sections.append("*(mutable variable)*")
            }

        case .classDecl(let c):
            sections.append(formatClassSignature(c))
            sections.append(formatClassBody(c))

        case .interfaceDecl(let i):
            sections.append(formatInterfaceSignature(i))
            sections.append(formatInterfaceBody(i))

        case .enumDecl(let e):
            sections.append(formatEnumSignature(e))
            sections.append(formatEnumBody(e))

        case .actorDecl(let a):
            let sig = "```rockit\nactor \(a.name)\n```"
            sections.append(sig)
            if !a.members.isEmpty {
                sections.append(formatMemberList(a.members, label: "actor"))
            }

        case .viewDecl(let v):
            let params = v.parameters.map { formatParam($0) }
            sections.append("```rockit\nview \(v.name)(\(params.joined(separator: ", ")))\n```")

        case .objectDecl(let o):
            var sig = "```rockit\n"
            if o.isCompanion { sig += "companion " }
            sig += "object \(o.name)"
            if !o.superTypes.isEmpty {
                sig += " : " + o.superTypes.map { $0.summary }.joined(separator: ", ")
            }
            sig += "\n```"
            sections.append(sig)
            if !o.members.isEmpty {
                sections.append(formatMemberList(o.members, label: "object"))
            }

        case .typeAlias(let ta):
            sections.append("```rockit\ntypealias \(ta.name) = \(ta.type.summary)\n```")

        default:
            return nil
        }

        let text = sections.filter { !$0.isEmpty }.joined(separator: "\n\n---\n\n")

        return LSPHover(
            contents: LSPMarkupContent(kind: "markdown", value: text),
            range: sourceSpanToLSPRange(span)
        )
    }

    // MARK: - Class Formatting

    private static func formatClassSignature(_ c: ClassDecl) -> String {
        var sig = "```rockit\n"

        // Modifiers
        var mods: [String] = []
        if c.modifiers.contains(.data) { mods.append("data") }
        if c.modifiers.contains(.sealed) { mods.append("sealed") }
        if c.modifiers.contains(.abstract) { mods.append("abstract") }
        if c.modifiers.contains(.open) { mods.append("open") }
        if !mods.isEmpty { sig += mods.joined(separator: " ") + " " }

        sig += "class \(c.name)"

        // Type parameters
        if !c.typeParameters.isEmpty {
            sig += "<" + c.typeParameters.map { formatTypeParam($0) }.joined(separator: ", ") + ">"
        }

        // Constructor parameters
        if !c.constructorParams.isEmpty {
            sig += "(\n"
            for (i, p) in c.constructorParams.enumerated() {
                sig += "    \(formatParam(p))"
                if i < c.constructorParams.count - 1 { sig += "," }
                sig += "\n"
            }
            sig += ")"
        }

        // Supertypes
        if !c.superTypes.isEmpty {
            sig += " : " + c.superTypes.map { $0.summary }.joined(separator: ", ")
        }

        sig += "\n```"
        return sig
    }

    private static func formatClassBody(_ c: ClassDecl) -> String {
        var parts: [String] = []

        // Count members by kind
        let properties = c.members.compactMap { decl -> String? in
            if case .property(let p) = decl {
                let kw = p.isVal ? "val" : "var"
                return "- `\(kw) \(p.name)\(p.type.map { ": \($0.summary)" } ?? "")`"
            }
            return nil
        }
        let methods = c.members.compactMap { decl -> String? in
            if case .function(let f) = decl { return "- `fun \(f.name)(\(f.parameters.map { formatParam($0) }.joined(separator: ", ")))\(f.returnType.map { ": \($0.summary)" } ?? "")`" }
            return nil
        }
        let nested = c.members.compactMap { decl -> String? in
            switch decl {
            case .classDecl(let nc): return "- `class \(nc.name)`"
            case .interfaceDecl(let ni): return "- `interface \(ni.name)`"
            case .enumDecl(let ne): return "- `enum class \(ne.name)`"
            case .objectDecl(let no): return "- `\(no.isCompanion ? "companion " : "")object \(no.name)`"
            default: return nil
            }
        }

        if !properties.isEmpty {
            parts.append("**Properties**\n" + properties.joined(separator: "\n"))
        }
        if !methods.isEmpty {
            parts.append("**Methods**\n" + methods.joined(separator: "\n"))
        }
        if !nested.isEmpty {
            parts.append("**Nested Types**\n" + nested.joined(separator: "\n"))
        }

        if parts.isEmpty && c.members.isEmpty {
            return "*(empty class)*"
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Interface Formatting

    private static func formatInterfaceSignature(_ i: InterfaceDecl) -> String {
        var sig = "```rockit\ninterface \(i.name)"
        if !i.typeParameters.isEmpty {
            sig += "<" + i.typeParameters.map { formatTypeParam($0) }.joined(separator: ", ") + ">"
        }
        if !i.superTypes.isEmpty {
            sig += " : " + i.superTypes.map { $0.summary }.joined(separator: ", ")
        }
        sig += "\n```"
        return sig
    }

    private static func formatInterfaceBody(_ i: InterfaceDecl) -> String {
        if i.members.isEmpty { return "" }

        let methods = i.members.compactMap { decl -> String? in
            if case .function(let f) = decl {
                return "- `fun \(f.name)(\(f.parameters.map { formatParam($0) }.joined(separator: ", ")))\(f.returnType.map { ": \($0.summary)" } ?? "")`"
            }
            return nil
        }
        let properties = i.members.compactMap { decl -> String? in
            if case .property(let p) = decl {
                let kw = p.isVal ? "val" : "var"
                return "- `\(kw) \(p.name)\(p.type.map { ": \($0.summary)" } ?? "")`"
            }
            return nil
        }

        var parts: [String] = []
        if !properties.isEmpty { parts.append("**Properties**\n" + properties.joined(separator: "\n")) }
        if !methods.isEmpty { parts.append("**Methods**\n" + methods.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Enum Formatting

    private static func formatEnumSignature(_ e: EnumClassDecl) -> String {
        var sig = "```rockit\nenum class \(e.name)"
        if !e.typeParameters.isEmpty {
            sig += "<" + e.typeParameters.map { formatTypeParam($0) }.joined(separator: ", ") + ">"
        }
        sig += "\n```"
        return sig
    }

    private static func formatEnumBody(_ e: EnumClassDecl) -> String {
        var parts: [String] = []

        if !e.entries.isEmpty {
            let entryNames = e.entries.map { "- `\($0.name)`" }
            parts.append("**Entries**\n" + entryNames.joined(separator: "\n"))
        }

        let methods = e.members.compactMap { decl -> String? in
            if case .function(let f) = decl {
                return "- `fun \(f.name)(\(f.parameters.map { formatParam($0) }.joined(separator: ", ")))\(f.returnType.map { ": \($0.summary)" } ?? "")`"
            }
            return nil
        }
        if !methods.isEmpty {
            parts.append("**Methods**\n" + methods.joined(separator: "\n"))
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Function Formatting

    private static func formatFunctionSignature(_ f: FunctionDecl) -> String {
        var sig = "```rockit\n"

        // Modifiers
        var mods: [String] = []
        for m in f.modifiers {
            switch m {
            case .suspend: mods.append("suspend")
            case .async: mods.append("async")
            case .override: mods.append("override")
            case .open: mods.append("open")
            case .abstract: mods.append("abstract")
            case .public: mods.append("public")
            case .private: mods.append("private")
            case .internal: mods.append("internal")
            case .protected: mods.append("protected")
            default: break
            }
        }
        if !mods.isEmpty { sig += mods.joined(separator: " ") + " " }

        sig += "fun \(f.name)"

        // Type parameters
        if !f.typeParameters.isEmpty {
            sig += "<" + f.typeParameters.map { formatTypeParam($0) }.joined(separator: ", ") + ">"
        }

        sig += "("
        if f.parameters.count <= 2 {
            sig += f.parameters.map { formatParam($0) }.joined(separator: ", ")
        } else {
            sig += "\n"
            for (i, p) in f.parameters.enumerated() {
                sig += "    \(formatParam(p))"
                if i < f.parameters.count - 1 { sig += "," }
                sig += "\n"
            }
        }
        sig += ")"

        if let ret = f.returnType {
            sig += ": \(ret.summary)"
        }

        sig += "\n```"
        return sig
    }

    // MARK: - Symbol Hover

    private static func formatSymbolHover(_ sym: Symbol, analysisResult: AnalysisResult) -> String {
        switch sym.kind {
        case .function:
            // Try to find the full function declaration in the AST for richer info
            if let funcDecl = findFunctionDecl(named: sym.name, in: analysisResult.ast) {
                return formatFunctionSignature(funcDecl)
            }
            if case .function(let params, let ret) = sym.type {
                let paramStr = params.map { "\($0)" }.joined(separator: ", ")
                return "```rockit\nfun \(sym.name)(\(paramStr)): \(ret)\n```"
            }
            return "```rockit\nfun \(sym.name)\n```"

        case .variable(let isMutable):
            let keyword = isMutable ? "var" : "val"
            return "```rockit\n\(keyword) \(sym.name): \(sym.type)\n```\n\n*(\(isMutable ? "mutable variable" : "immutable binding"))*"

        case .parameter:
            return "```rockit\n\(sym.name): \(sym.type)\n```\n\n*(parameter)*"

        case .typeDeclaration:
            // Try to find the full type declaration in the AST
            if let typeDecl = findTypeDecl(named: sym.name, in: analysisResult.ast) {
                return hoverTextForTypeDecl(typeDecl, analysisResult: analysisResult)
            }
            return "```rockit\nclass \(sym.name)\n```"

        case .enumEntry:
            return "```rockit\n\(sym.name)\n```\n\n*(enum entry)*"

        case .typeAlias:
            return "```rockit\ntypealias \(sym.name) = \(sym.type)\n```"

        case .typeParameter:
            return "```rockit\n\(sym.name)\n```\n\n*(type parameter)*"
        }
    }

    // MARK: - AST Lookups

    private static func findFunctionDecl(named name: String, in ast: SourceFile) -> FunctionDecl? {
        for decl in ast.declarations {
            if let f = findFunctionIn(decl, named: name) { return f }
        }
        return nil
    }

    private static func findFunctionIn(_ decl: Declaration, named name: String) -> FunctionDecl? {
        switch decl {
        case .function(let f) where f.name == name:
            return f
        case .classDecl(let c):
            for member in c.members {
                if let f = findFunctionIn(member, named: name) { return f }
            }
        case .interfaceDecl(let i):
            for member in i.members {
                if let f = findFunctionIn(member, named: name) { return f }
            }
        case .objectDecl(let o):
            for member in o.members {
                if let f = findFunctionIn(member, named: name) { return f }
            }
        default:
            break
        }
        return nil
    }

    private static func findTypeDecl(named name: String, in ast: SourceFile) -> Declaration? {
        for decl in ast.declarations {
            if let found = findTypeDeclIn(decl, named: name) { return found }
        }
        return nil
    }

    private static func findTypeDeclIn(_ decl: Declaration, named name: String) -> Declaration? {
        switch decl {
        case .classDecl(let c) where c.name == name: return decl
        case .interfaceDecl(let i) where i.name == name: return decl
        case .enumDecl(let e) where e.name == name: return decl
        case .objectDecl(let o) where o.name == name: return decl
        case .actorDecl(let a) where a.name == name: return decl
        case .classDecl(let c):
            for member in c.members {
                if let found = findTypeDeclIn(member, named: name) { return found }
            }
        default:
            break
        }
        return nil
    }

    private static func hoverTextForTypeDecl(_ decl: Declaration, analysisResult: AnalysisResult) -> String {
        switch decl {
        case .classDecl(let c):
            return formatClassSignature(c) + "\n\n---\n\n" + formatClassBody(c)
        case .interfaceDecl(let i):
            let sig = formatInterfaceSignature(i)
            let body = formatInterfaceBody(i)
            return body.isEmpty ? sig : sig + "\n\n---\n\n" + body
        case .enumDecl(let e):
            let sig = formatEnumSignature(e)
            let body = formatEnumBody(e)
            return body.isEmpty ? sig : sig + "\n\n---\n\n" + body
        case .actorDecl(let a):
            var text = "```rockit\nactor \(a.name)\n```"
            if !a.members.isEmpty {
                text += "\n\n---\n\n" + formatMemberList(a.members, label: "actor")
            }
            return text
        case .objectDecl(let o):
            var sig = "```rockit\n"
            if o.isCompanion { sig += "companion " }
            sig += "object \(o.name)"
            if !o.superTypes.isEmpty {
                sig += " : " + o.superTypes.map { $0.summary }.joined(separator: ", ")
            }
            sig += "\n```"
            if !o.members.isEmpty {
                sig += "\n\n---\n\n" + formatMemberList(o.members, label: "object")
            }
            return sig
        default:
            return ""
        }
    }

    // MARK: - Formatting Helpers

    private static func formatParam(_ p: Parameter) -> String {
        var s = ""
        if p.isVal { s += "val " }
        if p.isVar { s += "var " }
        s += p.name
        if let t = p.type { s += ": \(t.summary)" }
        if p.defaultValue != nil { s += " = ..." }
        return s
    }

    private static func formatTypeParam(_ tp: TypeParameter) -> String {
        var s = ""
        if let variance = tp.variance {
            switch variance {
            case .in: s += "in "
            case .out: s += "out "
            }
        }
        s += tp.name
        if let bound = tp.upperBound {
            s += " : \(bound.summary)"
        }
        return s
    }

    private static func formatMemberList(_ members: [Declaration], label: String) -> String {
        let properties = members.compactMap { decl -> String? in
            if case .property(let p) = decl {
                let kw = p.isVal ? "val" : "var"
                return "- `\(kw) \(p.name)\(p.type.map { ": \($0.summary)" } ?? "")`"
            }
            return nil
        }
        let methods = members.compactMap { decl -> String? in
            if case .function(let f) = decl {
                return "- `fun \(f.name)(\(f.parameters.map { formatParam($0) }.joined(separator: ", ")))\(f.returnType.map { ": \($0.summary)" } ?? "")`"
            }
            return nil
        }

        var parts: [String] = []
        if !properties.isEmpty { parts.append("**Properties**\n" + properties.joined(separator: "\n")) }
        if !methods.isEmpty { parts.append("**Methods**\n" + methods.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    private static func countMembers(in members: [Declaration]) -> (properties: Int, methods: Int) {
        var props = 0, meths = 0
        for m in members {
            switch m {
            case .property: props += 1
            case .function: meths += 1
            default: break
            }
        }
        return (props, meths)
    }
}
