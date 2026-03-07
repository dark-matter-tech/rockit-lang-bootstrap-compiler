// TypeResolver.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

/// Resolves syntactic `TypeNode` (from the parser) into semantic `Type` (for the type checker).
public final class TypeResolver {
    private let symbolTable: SymbolTable
    private let diagnostics: DiagnosticEngine

    public init(symbolTable: SymbolTable, diagnostics: DiagnosticEngine) {
        self.symbolTable = symbolTable
        self.diagnostics = diagnostics
    }

    /// Resolve a TypeNode to a semantic Type
    public func resolve(_ node: TypeNode) -> Type {
        switch node {
        case .simple(let name, let typeArgs, let span):
            return resolveSimple(name: name, typeArguments: typeArgs, span: span)

        case .nullable(let inner, _):
            let innerType = resolve(inner)
            if innerType.isError { return .error }
            return .nullable(innerType)

        case .function(let paramTypes, let returnType, _):
            let resolvedParams = paramTypes.map { resolve($0) }
            let resolvedReturn = resolve(returnType)
            if resolvedParams.contains(where: { $0.isError }) || resolvedReturn.isError {
                return .error
            }
            return .function(parameterTypes: resolvedParams, returnType: resolvedReturn)

        case .tuple(let elements, _):
            let resolvedElements = elements.map { resolve($0) }
            if resolvedElements.contains(where: { $0.isError }) {
                return .error
            }
            return .tuple(elements: resolvedElements)

        case .qualified(let base, let member, let span):
            let baseType = resolve(base)
            if baseType.isError { return .error }
            // For qualified types like Result.Success, look up the member
            if let baseName = baseType.typeName,
               let typeInfo = symbolTable.lookupType(baseName) {
                // Check sealed subclasses
                if typeInfo.sealedSubclasses.contains(member) {
                    return .classType(name: member, typeArguments: [])
                }
                // Check enum entries
                if typeInfo.enumEntries.contains(member) {
                    return .enumType(name: baseName)
                }
            }
            diagnostics.error("unknown member type '\(member)' in '\(baseType)'", at: span.start)
            return .error
        }
    }

    // MARK: - Private

    private func resolveSimple(name: String, typeArguments: [TypeNode], span: SourceSpan) -> Type {
        // Check builtin type mapping first
        if let builtin = builtinType(for: name) {
            if !typeArguments.isEmpty {
                diagnostics.error("primitive type '\(name)' does not accept type arguments", at: span.start)
                return .error
            }
            return builtin
        }

        // Resolve type arguments
        let resolvedArgs = typeArguments.map { resolve($0) }
        if resolvedArgs.contains(where: { $0.isError }) {
            return .error
        }

        // Look up in symbol table
        if let symbol = symbolTable.lookup(name) {
            switch symbol.kind {
            case .typeAlias:
                // Return the resolved target type directly
                if resolvedArgs.isEmpty {
                    return symbol.type
                }
                return symbol.type
            case .typeDeclaration:
                return resolveTypeDeclaration(name: name, typeArguments: resolvedArgs, span: span)
            case .typeParameter:
                if !typeArguments.isEmpty {
                    diagnostics.error("type parameter '\(name)' does not accept type arguments", at: span.start)
                    return .error
                }
                return symbol.type
            default:
                diagnostics.error("'\(name)' is not a type", at: span.start)
                return .error
            }
        }

        diagnostics.error("unknown type '\(name)'", at: span.start)
        return .error
    }

    private func resolveTypeDeclaration(name: String, typeArguments: [Type], span: SourceSpan) -> Type {
        guard let typeInfo = symbolTable.lookupType(name) else {
            // Known type but no TypeDeclInfo — treat as simple class type
            return .classType(name: name, typeArguments: typeArguments)
        }

        // Validate type argument count if type parameters are declared
        if !typeInfo.typeParameters.isEmpty && !typeArguments.isEmpty
            && typeArguments.count != typeInfo.typeParameters.count {
            diagnostics.error(
                "type '\(name)' expects \(typeInfo.typeParameters.count) type argument(s), got \(typeArguments.count)",
                at: span.start
            )
            return .error
        }

        // Determine the appropriate Type variant
        // Check if it's an enum
        if !typeInfo.enumEntries.isEmpty {
            return .enumType(name: name)
        }

        // Default: class type (covers classes, interfaces, generic types)
        return .classType(name: name, typeArguments: typeArguments)
    }

    /// Map builtin type names to semantic types
    private func builtinType(for name: String) -> Type? {
        switch name {
        case "Int":       return .int
        case "Int32":     return .int32
        case "Int64":     return .int64
        case "Float":     return .float
        case "Float64":   return .float64
        case "Double":    return .double
        case "Bool":      return .bool
        case "String":    return .string
        case "ByteArray": return .byteArray
        case "Unit":      return .unit
        case "Nothing":   return .nothing
        default:          return nil
        }
    }
}
