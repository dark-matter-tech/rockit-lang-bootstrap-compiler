// SetupEditors.swift
// RockitCLI — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation
import RockitKit

/// Auto-detect installed editors and install Rockit editor support
/// (syntax highlighting, file icons, snippets).
func setupEditorsCommand() {
    let fm = FileManager.default
    let editorsDir = findEditorsDir()

    var installed: [String] = []

    // --- VS Code ---
    if let dir = editorsDir {
        let vscodeSource = Platform.pathJoin(dir, "vscode")
        if fm.fileExists(atPath: Platform.pathJoin(vscodeSource, "package.json")) {
            installed += installVSCode(source: vscodeSource, variant: "code", label: "VS Code")
            installed += installVSCode(source: vscodeSource, variant: "code-insiders", label: "VS Code Insiders")
        }
    }

    // --- Vim ---
    if let dir = editorsDir {
        let vimSource = Platform.pathJoin(dir, "vim")
        if fm.fileExists(atPath: Platform.pathJoin(vimSource, "syntax", "rockit.vim")) {
            installed += installVim(source: vimSource)
        }
    }

    // --- Neovim ---
    if let dir = editorsDir {
        let vimSource = Platform.pathJoin(dir, "vim")
        if fm.fileExists(atPath: Platform.pathJoin(vimSource, "syntax", "rockit.vim")) {
            installed += installNeovim(source: vimSource)
        }
    }

    // --- JetBrains ---
    installed += installJetBrains(editorsDir: editorsDir)

    // --- Summary ---
    if installed.isEmpty {
        print("No supported editors detected.")
        print("")
        print("  Rockit supports: VS Code, Vim, Neovim, JetBrains IDEs")
        print("")
        print("  Manual install:")
        print("    VS Code:    Copy editors/vscode/ to ~/.vscode/extensions/darkmattertech.rockit-lang-0.1.0/")
        print("    Vim:        Copy editors/vim/{ftdetect,syntax}/ to ~/.vim/")
        print("    Neovim:     Copy editors/vim/{ftdetect,syntax}/ to ~/.local/share/nvim/site/")
        print("    JetBrains:  Settings > Plugins > Install from Disk")
    } else {
        // Deduplicate names (e.g., multiple IntelliJ IDEA versions)
        var seen = Set<String>()
        let unique = installed.filter { seen.insert($0).inserted }
        print("")
        print("Installed Rockit editor support for: \(unique.joined(separator: ", "))")
        print("  Restart your editor(s) to activate.")
    }
}

// MARK: - Editor Source Directory

/// Find the bundled editor files directory.
/// Checks: installed location ($PREFIX/lib/rockit/editors/), then dev source tree (../../ide/).
private func findEditorsDir() -> String? {
    let fm = FileManager.default
    let execPath = CommandLine.arguments[0]
    let execDir = (execPath as NSString).deletingLastPathComponent

    // Installed location: $PREFIX/lib/rockit/editors/
    let installedPath = Platform.pathJoin(execDir, "..", "lib", "rockit", "editors")
    if fm.fileExists(atPath: installedPath) {
        return installedPath
    }

    // Dev: running from .build/debug/ — source tree is ../../ide/
    // The ide/ directory has vscode/, vim/, intellij-rockit/ subdirectories
    // We need to map these to the expected structure
    let devIde = Platform.pathJoin(execDir, "..", "..", "ide")
    if fm.fileExists(atPath: Platform.pathJoin(devIde, "vscode", "package.json")) {
        return devIde
    }

    // Dev: running via swift run — binary at .build/arm64-apple-macosx/debug/
    let devIde2 = Platform.pathJoin(execDir, "..", "..", "..", "ide")
    if fm.fileExists(atPath: Platform.pathJoin(devIde2, "vscode", "package.json")) {
        return devIde2
    }

    // Check from cwd
    let cwdIde = Platform.pathJoin(fm.currentDirectoryPath, "ide")
    if fm.fileExists(atPath: Platform.pathJoin(cwdIde, "vscode", "package.json")) {
        return cwdIde
    }

    // Check one level up (if cwd is RockitCompiler/)
    let parentIde = Platform.pathJoin(fm.currentDirectoryPath, "..", "ide")
    if fm.fileExists(atPath: Platform.pathJoin(parentIde, "vscode", "package.json")) {
        return parentIde
    }

    print("warning: could not find editor files")
    print("  Expected at: \(installedPath)")
    return nil
}

// MARK: - VS Code

private func installVSCode(source: String, variant: String, label: String) -> [String] {
    let fm = FileManager.default

    // Check if this VS Code variant is installed
    let hasCommand = Platform.findExecutable(variant) != nil
    let homeDir = fm.homeDirectoryForCurrentUser.path
    let extensionsDir: String

    #if os(Windows)
    if variant == "code-insiders" {
        extensionsDir = Platform.pathJoin(homeDir, ".vscode-insiders", "extensions")
    } else {
        extensionsDir = Platform.pathJoin(homeDir, ".vscode", "extensions")
    }
    #else
    if variant == "code-insiders" {
        extensionsDir = Platform.pathJoin(homeDir, ".vscode-insiders", "extensions")
    } else {
        extensionsDir = Platform.pathJoin(homeDir, ".vscode", "extensions")
    }
    #endif

    // Need either the command or the extensions directory to exist
    guard hasCommand || fm.fileExists(atPath: extensionsDir) else {
        return []
    }

    let targetDir = Platform.pathJoin(extensionsDir, "darkmattertech.rockit-lang-0.1.0")

    do {
        // Remove old version if present
        if fm.fileExists(atPath: targetDir) {
            try fm.removeItem(atPath: targetDir)
        }

        try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

        // Copy all extension files
        let filesToCopy = [
            "package.json",
            "language-configuration.json",
        ]
        for file in filesToCopy {
            let src = Platform.pathJoin(source, file)
            let dst = Platform.pathJoin(targetDir, file)
            if fm.fileExists(atPath: src) {
                try fm.copyItem(atPath: src, toPath: dst)
            }
        }

        // Copy subdirectories
        let dirsToCopy = ["syntaxes", "snippets", "icons"]
        for dir in dirsToCopy {
            let srcDir = Platform.pathJoin(source, dir)
            let dstDir = Platform.pathJoin(targetDir, dir)
            if fm.fileExists(atPath: srcDir) {
                try fm.copyItem(atPath: srcDir, toPath: dstDir)
            }
        }

        print("  \(label): installed extension to \(targetDir)")
        return [label]
    } catch {
        print("  \(label): failed — \(error.localizedDescription)")
        return []
    }
}

// MARK: - Vim

private func installVim(source: String) -> [String] {
    let fm = FileManager.default
    let homeDir = fm.homeDirectoryForCurrentUser.path

    #if os(Windows)
    let vimDir = Platform.pathJoin(homeDir, "vimfiles")
    #else
    let vimDir = Platform.pathJoin(homeDir, ".vim")
    #endif

    // Check if Vim is installed (command exists or .vim/ dir exists)
    let hasVim = Platform.findExecutable("vim") != nil || fm.fileExists(atPath: vimDir)
    guard hasVim else { return [] }

    do {
        let ftdetectDir = Platform.pathJoin(vimDir, "ftdetect")
        let syntaxDir = Platform.pathJoin(vimDir, "syntax")
        try fm.createDirectory(atPath: ftdetectDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: syntaxDir, withIntermediateDirectories: true)

        let srcFtdetect = Platform.pathJoin(source, "ftdetect", "rockit.vim")
        let srcSyntax = Platform.pathJoin(source, "syntax", "rockit.vim")
        let dstFtdetect = Platform.pathJoin(ftdetectDir, "rockit.vim")
        let dstSyntax = Platform.pathJoin(syntaxDir, "rockit.vim")

        // Remove existing and copy
        try? fm.removeItem(atPath: dstFtdetect)
        try? fm.removeItem(atPath: dstSyntax)
        try fm.copyItem(atPath: srcFtdetect, toPath: dstFtdetect)
        try fm.copyItem(atPath: srcSyntax, toPath: dstSyntax)

        print("  Vim: installed syntax files to \(vimDir)")
        return ["Vim"]
    } catch {
        print("  Vim: failed — \(error.localizedDescription)")
        return []
    }
}

// MARK: - Neovim

private func installNeovim(source: String) -> [String] {
    let fm = FileManager.default
    let homeDir = fm.homeDirectoryForCurrentUser.path

    // Neovim site directory (where user plugins go)
    let nvimSiteDir: String
    #if os(Windows)
    let localAppData = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? Platform.pathJoin(homeDir, "AppData", "Local")
    nvimSiteDir = Platform.pathJoin(localAppData, "nvim-data", "site")
    #elseif os(macOS)
    nvimSiteDir = Platform.pathJoin(homeDir, ".local", "share", "nvim", "site")
    #else
    nvimSiteDir = Platform.pathJoin(homeDir, ".local", "share", "nvim", "site")
    #endif

    // Check if Neovim is installed
    let nvimConfigDir: String
    #if os(Windows)
    nvimConfigDir = Platform.pathJoin(localAppData, "nvim")
    #else
    nvimConfigDir = Platform.pathJoin(homeDir, ".config", "nvim")
    #endif

    let hasNvim = Platform.findExecutable("nvim") != nil || fm.fileExists(atPath: nvimConfigDir)
    guard hasNvim else { return [] }

    do {
        let ftdetectDir = Platform.pathJoin(nvimSiteDir, "ftdetect")
        let syntaxDir = Platform.pathJoin(nvimSiteDir, "syntax")
        try fm.createDirectory(atPath: ftdetectDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: syntaxDir, withIntermediateDirectories: true)

        let srcFtdetect = Platform.pathJoin(source, "ftdetect", "rockit.vim")
        let srcSyntax = Platform.pathJoin(source, "syntax", "rockit.vim")
        let dstFtdetect = Platform.pathJoin(ftdetectDir, "rockit.vim")
        let dstSyntax = Platform.pathJoin(syntaxDir, "rockit.vim")

        try? fm.removeItem(atPath: dstFtdetect)
        try? fm.removeItem(atPath: dstSyntax)
        try fm.copyItem(atPath: srcFtdetect, toPath: dstFtdetect)
        try fm.copyItem(atPath: srcSyntax, toPath: dstSyntax)

        print("  Neovim: installed syntax files to \(nvimSiteDir)")
        return ["Neovim"]
    } catch {
        print("  Neovim: failed — \(error.localizedDescription)")
        return []
    }
}

// MARK: - JetBrains

private func installJetBrains(editorsDir: String?) -> [String] {
    let fm = FileManager.default
    let homeDir = fm.homeDirectoryForCurrentUser.path
    var installed: [String] = []

    // Find JetBrains IDE config directories
    let jetbrainsBaseDirs: [String]
    #if os(macOS)
    jetbrainsBaseDirs = [Platform.pathJoin(homeDir, "Library", "Application Support", "JetBrains")]
    #elseif os(Windows)
    let appData = ProcessInfo.processInfo.environment["APPDATA"] ?? Platform.pathJoin(homeDir, "AppData", "Roaming")
    jetbrainsBaseDirs = [Platform.pathJoin(appData, "JetBrains")]
    #else
    jetbrainsBaseDirs = [
        Platform.pathJoin(homeDir, ".local", "share", "JetBrains"),
        Platform.pathJoin(homeDir, ".config", "JetBrains"),
    ]
    #endif

    // Check if the JetBrains plugin source exists
    // In dev mode, it's at intellij-rockit/; in installed mode, at jetbrains/
    let pluginZipPath: String?
    if let dir = editorsDir {
        let devPlugin = Platform.pathJoin(dir, "intellij-rockit", "build", "distributions")
        let installedPlugin = Platform.pathJoin(dir, "jetbrains")
        if fm.fileExists(atPath: installedPlugin) {
            // Look for any .zip in jetbrains/
            if let items = try? fm.contentsOfDirectory(atPath: installedPlugin),
               let zip = items.first(where: { $0.hasSuffix(".zip") }) {
                pluginZipPath = Platform.pathJoin(installedPlugin, zip)
            } else {
                pluginZipPath = nil
            }
        } else if fm.fileExists(atPath: devPlugin) {
            // Dev mode: look for built plugin
            if let items = try? fm.contentsOfDirectory(atPath: devPlugin),
               let zip = items.first(where: { $0.hasSuffix(".zip") }) {
                pluginZipPath = Platform.pathJoin(devPlugin, zip)
            } else {
                pluginZipPath = nil
            }
        } else {
            pluginZipPath = nil
        }
    } else {
        pluginZipPath = nil
    }

    for baseDir in jetbrainsBaseDirs {
        guard fm.fileExists(atPath: baseDir),
              let ideDirs = try? fm.contentsOfDirectory(atPath: baseDir) else {
            continue
        }

        for ideDir in ideDirs.sorted() {
            let pluginsDir = Platform.pathJoin(baseDir, ideDir, "plugins")
            guard fm.fileExists(atPath: pluginsDir) else { continue }

            // Skip non-IDE directories (Toolbox, consentOptions, etc.)
            let knownIDEPrefixes = [
                "IntelliJIdea", "IdeaIC", "WebStorm", "CLion", "PyCharm",
                "GoLand", "Rider", "RubyMine", "PhpStorm", "DataGrip",
                "DataSpell", "AndroidStudio", "Fleet", "Writerside",
            ]
            guard knownIDEPrefixes.contains(where: { ideDir.hasPrefix($0) }) else { continue }

            // Extract a friendly IDE name (e.g., "IntelliJIdea2024.1" → "IntelliJ IDEA")
            let ideName = friendlyIDEName(ideDir)

            if let zipPath = pluginZipPath {
                // Unzip plugin into plugins directory
                let process = Process()
                #if os(Windows)
                process.executableURL = URL(fileURLWithPath: "powershell.exe")
                process.arguments = ["-Command", "Expand-Archive -Path '\(zipPath)' -DestinationPath '\(pluginsDir)' -Force"]
                #else
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-o", "-q", zipPath, "-d", pluginsDir]
                #endif
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        print("  \(ideName): installed plugin to \(pluginsDir)")
                        installed.append(ideName)
                    }
                } catch {
                    print("  \(ideName): failed to install plugin — \(error.localizedDescription)")
                }
            } else {
                print("  \(ideName): detected but no plugin .zip available")
                print("    Build with: cd ide/intellij-rockit && ./gradlew buildPlugin")
                print("    Or install from: Settings > Plugins > Marketplace > search 'Rockit'")
            }
        }
    }

    return installed
}

/// Convert JetBrains directory names to friendly names.
private func friendlyIDEName(_ dirName: String) -> String {
    if dirName.hasPrefix("IntelliJIdea") { return "IntelliJ IDEA" }
    if dirName.hasPrefix("IdeaIC") { return "IntelliJ IDEA CE" }
    if dirName.hasPrefix("WebStorm") { return "WebStorm" }
    if dirName.hasPrefix("CLion") { return "CLion" }
    if dirName.hasPrefix("PyCharm") { return "PyCharm" }
    if dirName.hasPrefix("GoLand") { return "GoLand" }
    if dirName.hasPrefix("Rider") { return "Rider" }
    if dirName.hasPrefix("Fleet") { return "Fleet" }
    if dirName.hasPrefix("RubyMine") { return "RubyMine" }
    if dirName.hasPrefix("PhpStorm") { return "PhpStorm" }
    if dirName.hasPrefix("DataGrip") { return "DataGrip" }
    if dirName.hasPrefix("DataSpell") { return "DataSpell" }
    if dirName.hasPrefix("Writerside") { return "Writerside" }
    if dirName.hasPrefix("AndroidStudio") { return "Android Studio" }
    return dirName
}
