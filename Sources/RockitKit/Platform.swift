// Platform.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation

/// Cross-platform utilities for the Rockit compiler.
/// All OS-specific behavior is centralized here so the rest
/// of the codebase can remain platform-agnostic.
public enum Platform {

    // MARK: - Path Operations

    /// Join path components using Foundation's URL-based path joining,
    /// which handles separators correctly on all platforms.
    public static func pathJoin(_ components: String...) -> String {
        guard let first = components.first else { return "" }
        var url = URL(fileURLWithPath: first)
        for component in components.dropFirst() {
            url.appendPathComponent(component)
        }
        return url.path
    }

    /// Platform-appropriate temporary directory path.
    public static var tempDirectory: String {
        NSTemporaryDirectory()
    }

    /// Build a temporary file path with the given name.
    public static func tempFilePath(_ name: String) -> String {
        pathJoin(tempDirectory, name)
    }

    // MARK: - Executable Extensions

    /// File extension for native executables. Empty on Unix, ".exe" on Windows.
    public static var executableExtension: String {
        #if os(Windows)
        return ".exe"
        #else
        return ""
        #endif
    }

    /// File extension for object files. ".o" on Unix, ".obj" on Windows.
    public static var objectFileExtension: String {
        #if os(Windows)
        return ".obj"
        #else
        return ".o"
        #endif
    }

    /// Append the correct executable extension if needed.
    public static func withExeExtension(_ path: String) -> String {
        if executableExtension.isEmpty { return path }
        if path.hasSuffix(executableExtension) { return path }
        return path + executableExtension
    }

    // MARK: - Tool Resolution

    /// Find an executable by name on the system PATH.
    public static func findExecutable(_ name: String) -> String? {
        let candidates: [String]
        #if os(Windows)
        candidates = [name, name + ".exe"]
        #else
        candidates = [name]
        #endif

        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else {
            return nil
        }

        let separator: Character
        #if os(Windows)
        separator = ";"
        #else
        separator = ":"
        #endif

        let fm = FileManager.default
        for dir in pathEnv.split(separator: separator).map(String.init) {
            for candidate in candidates {
                let fullPath = pathJoin(dir, candidate)
                if fm.isExecutableFile(atPath: fullPath) {
                    return fullPath
                }
            }
        }
        return nil
    }

    /// Find the clang compiler. Searches PATH first, then platform-specific fallbacks.
    public static func findClang() -> String? {
        if let found = findExecutable("clang") {
            return found
        }

        let fallbacks: [String]
        #if os(macOS)
        fallbacks = ["/usr/bin/clang", "/opt/homebrew/bin/clang"]
        #elseif os(Windows)
        fallbacks = [
            "C:\\Program Files\\LLVM\\bin\\clang.exe",
            "C:\\Program Files (x86)\\LLVM\\bin\\clang.exe",
        ]
        #else
        fallbacks = ["/usr/bin/clang", "/usr/local/bin/clang"]
        #endif

        let fm = FileManager.default
        for path in fallbacks {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    // MARK: - Shell Execution

    /// Platform-appropriate shell executable for running command strings.
    public static var shellExecutable: String {
        #if os(Windows)
        return "cmd.exe"
        #else
        return "/bin/sh"
        #endif
    }

    /// Shell flag for passing a command string.
    public static var shellFlag: String {
        #if os(Windows)
        return "/c"
        #else
        return "-c"
        #endif
    }

    // MARK: - LLVM Target Triple

    /// Returns the LLVM target triple for the host platform.
    public static func hostTargetTriple() -> String {
        #if arch(arm64) && os(macOS)
        let arch = "arm64-apple-macosx"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(arch)\(version.majorVersion).0.0"
        #elseif arch(x86_64) && os(macOS)
        let arch = "x86_64-apple-macosx"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(arch)\(version.majorVersion).0.0"
        #elseif arch(x86_64) && os(Linux)
        return "x86_64-unknown-linux-gnu"
        #elseif arch(arm64) && os(Linux)
        return "aarch64-unknown-linux-gnu"
        #elseif arch(x86_64) && os(Windows)
        return "x86_64-pc-windows-msvc"
        #elseif arch(arm64) && os(Windows)
        return "aarch64-pc-windows-msvc"
        #else
        return "x86_64-unknown-linux-gnu"
        #endif
    }

    // MARK: - setjmp ABI

    /// LLVM IR declaration for setjmp. MSVC _setjmp takes an extra ptr parameter.
    public static var setjmpDeclaration: String {
        #if os(Windows)
        return "declare i32 @_setjmp(ptr, ptr) #0"
        #else
        return "declare i32 @_setjmp(ptr) #0"
        #endif
    }

    /// LLVM IR call to setjmp.
    public static func setjmpCall(result: String, bufPtr: String) -> String {
        #if os(Windows)
        return "\(result) = call i32 @_setjmp(ptr \(bufPtr), ptr null) #0"
        #else
        return "\(result) = call i32 @_setjmp(ptr \(bufPtr)) #0"
        #endif
    }

    // MARK: - File Operations

    /// Delete a file if it exists. No error on missing files.
    public static func removeFileIfExists(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
