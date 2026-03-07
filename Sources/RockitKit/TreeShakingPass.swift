// TreeShakingPass.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - Tree Shaking Pass

/// Removes functions and type declarations not reachable from `main`
/// or global initializer functions.
internal final class TreeShakingPass: MIRPass {
    var name: String { "TreeShaking" }

    func run(_ module: MIRModule) -> MIRModule {
        var result = module

        // Step 1: Identify roots
        var rootFunctions = Set<String>()
        rootFunctions.insert("main")
        for global in module.globals {
            if let initFunc = global.initializerFunc {
                rootFunctions.insert(initFunc)
            }
        }

        // Step 2: Build function lookup
        let funcMap = Dictionary(uniqueKeysWithValues: module.functions.map { ($0.name, $0) })

        // Step 3: Transitively discover reachable functions and types
        var reachableFunctions = Set<String>()
        var reachableTypes = Set<String>()
        var worklist = Array(rootFunctions)

        while let funcName = worklist.popLast() {
            guard reachableFunctions.insert(funcName).inserted else { continue }
            guard let f = funcMap[funcName] else { continue }

            let refs = collectReferences(from: f)
            for refFunc in refs.functions {
                if !reachableFunctions.contains(refFunc) {
                    worklist.append(refFunc)
                }
            }
            reachableTypes.formUnion(refs.types)
        }

        // Step 4: Also mark methods of reachable types
        for typeDecl in module.types where reachableTypes.contains(typeDecl.name) {
            for method in typeDecl.methods {
                if !reachableFunctions.contains(method) {
                    worklist.append(method)
                }
            }
        }
        // Re-process newly added methods
        while let funcName = worklist.popLast() {
            guard reachableFunctions.insert(funcName).inserted else { continue }
            guard let f = funcMap[funcName] else { continue }
            let refs = collectReferences(from: f)
            for refFunc in refs.functions {
                if !reachableFunctions.contains(refFunc) {
                    worklist.append(refFunc)
                }
            }
            reachableTypes.formUnion(refs.types)
        }

        // Step 5: Mark types accessed via global-style loads (enum access pattern).
        // When code uses `Color.RED`, MIR lowers it as `load "global.Color"` + `getField "RED"`.
        // The load doesn't show up as a type reference, so check explicitly.
        let typeNames = Set(module.types.map(\.name))
        for funcName in reachableFunctions {
            guard let f = funcMap[funcName] else { continue }
            for block in f.blocks {
                for inst in block.instructions {
                    if case .load(_, let src) = inst, src.hasPrefix("global.") {
                        let name = String(src.dropFirst(7))
                        if typeNames.contains(name) {
                            reachableTypes.insert(name)
                        }
                    }
                }
            }
        }

        // Step 6: Preserve class hierarchies — if any type in a sealed hierarchy is reachable,
        // keep the sealed parent and ALL sibling subclasses (needed for dynamic dispatch).
        let typeMap = Dictionary(uniqueKeysWithValues: module.types.map { ($0.name, $0) })
        var hierarchyAdded = true
        while hierarchyAdded {
            hierarchyAdded = false
            for typeName in reachableTypes {
                guard let decl = typeMap[typeName] else { continue }
                // If this type has a parent, mark the parent reachable
                if let parent = decl.parentType, !reachableTypes.contains(parent) {
                    reachableTypes.insert(parent)
                    hierarchyAdded = true
                }
                // If this type is a sealed parent, mark all subclasses reachable
                for sub in decl.sealedSubclasses {
                    if !reachableTypes.contains(sub) {
                        reachableTypes.insert(sub)
                        hierarchyAdded = true
                        // Also mark subclass methods reachable
                        if let subDecl = typeMap[sub] {
                            for method in subDecl.methods {
                                if reachableFunctions.insert(method).inserted,
                                   let f = funcMap[method] {
                                    let refs = collectReferences(from: f)
                                    for refFunc in refs.functions {
                                        if reachableFunctions.insert(refFunc).inserted {
                                            worklist.append(refFunc)
                                        }
                                    }
                                    reachableTypes.formUnion(refs.types)
                                }
                            }
                        }
                    }
                }
            }
        }
        // Process any newly discovered functions from hierarchy expansion
        while let funcName = worklist.popLast() {
            guard reachableFunctions.insert(funcName).inserted else { continue }
            guard let f = funcMap[funcName] else { continue }
            let refs = collectReferences(from: f)
            for refFunc in refs.functions {
                if !reachableFunctions.contains(refFunc) {
                    worklist.append(refFunc)
                }
            }
            reachableTypes.formUnion(refs.types)
        }

        // Step 7: Filter
        result.functions = result.functions.filter { reachableFunctions.contains($0.name) }
        result.types = result.types.filter { reachableTypes.contains($0.name) }

        return result
    }

    // MARK: - Reference Collection

    private func collectReferences(from function: MIRFunction) -> (functions: Set<String>, types: Set<String>) {
        var funcs = Set<String>()
        var types = Set<String>()

        for block in function.blocks {
            for inst in block.instructions {
                switch inst {
                case .call(_, let function, _),
                     .awaitCall(_, let function, _):
                    funcs.insert(function)
                case .callIndirect:
                    break  // Can't statically determine target
                case .constString(_, let value) where value.hasPrefix("__lambda_"):
                    // Lambda function references stored as strings
                    funcs.insert(value)
                case .virtualCall(_, _, let method, _):
                    // method may be "ClassName.method" — extract class name
                    funcs.insert(method)
                    if let dotIdx = method.firstIndex(of: ".") {
                        types.insert(String(method[method.startIndex..<dotIdx]))
                    }
                case .newObject(_, let typeName, _):
                    types.insert(typeName)
                case .typeCheck(_, _, let typeName),
                     .typeCast(_, _, let typeName):
                    types.insert(typeName)
                case .alloc(_, let type):
                    if case .reference(let name) = type { types.insert(name) }
                default:
                    break
                }
            }
        }

        // Collect from parameter types and return type
        for (_, paramType) in function.parameters {
            if case .reference(let name) = paramType { types.insert(name) }
        }
        if case .reference(let name) = function.returnType { types.insert(name) }

        return (funcs, types)
    }
}
