# LSP Integration

The bootstrap compiler includes a Language Server Protocol (LSP) implementation that provides IDE features for Rockit in any LSP-compatible editor.

## Starting the Language Server

```bash
.build/release/rockit lsp
```

The server communicates via JSON-RPC over stdin/stdout, following the [LSP specification](https://microsoft.github.io/language-server-protocol/).

## Supported Features

| Feature | LSP Method | Status |
|---------|------------|--------|
| Diagnostics | `textDocument/publishDiagnostics` | Full |
| Completion | `textDocument/completion` | Full |
| Hover | `textDocument/hover` | Full |
| Go to Definition | `textDocument/definition` | Full |
| Find References | `textDocument/references` | Full |
| Semantic Tokens | `textDocument/semanticTokens/full` | Full |
| Document Symbols | `textDocument/documentSymbol` | Full |
| Signature Help | `textDocument/signatureHelp` | Full |
| Rename | `textDocument/rename` | Full |
| Code Actions | `textDocument/codeAction` | Partial |
| Formatting | `textDocument/formatting` | Planned |

## Architecture

```
Sources/RockitLSP/  (27 files)
├── LSPServer.swift              JSON-RPC transport, message routing
├── LSPTypes.swift               LSP protocol type definitions
├── LSPDocument.swift            Document model, incremental sync
├── CompletionProvider.swift     Auto-completion
├── DefinitionProvider.swift     Go-to-definition
├── HoverProvider.swift          Hover information (types, docs)
├── ReferencesProvider.swift     Find all references
├── DiagnosticsProvider.swift    Real-time error reporting
├── SemanticTokensProvider.swift Semantic syntax highlighting
├── DocumentSymbolProvider.swift Document outline
├── SignatureHelpProvider.swift  Function signature hints
├── RenameProvider.swift         Symbol renaming
├── CodeActionProvider.swift     Quick fixes and refactorings
└── ...
```

### How It Works

1. The LSP server receives a document open/change notification
2. The document is re-lexed and re-parsed incrementally
3. The type checker runs on the updated AST
4. Diagnostics (errors, warnings) are pushed to the editor
5. Feature requests (completion, hover, etc.) query the typed AST

The LSP reuses `RockitKit` — the same lexer, parser, and type checker used for compilation. This guarantees that editor diagnostics match compiler output exactly.

## Editor Setup

### VS Code

Install the Rockit extension (or configure manually):

```json
// .vscode/settings.json
{
    "rockit.lsp.path": "/path/to/.build/release/rockit",
    "rockit.lsp.args": ["lsp"]
}
```

### Neovim (nvim-lspconfig)

```lua
-- init.lua
local lspconfig = require('lspconfig')
local configs = require('lspconfig.configs')

configs.rockit = {
    default_config = {
        cmd = { '/path/to/.build/release/rockit', 'lsp' },
        filetypes = { 'rockit' },
        root_dir = lspconfig.util.root_pattern('fuel.toml', '.git'),
    },
}

lspconfig.rockit.setup{}
```

### IntelliJ IDEA

The Rockit IntelliJ plugin is available as a separate project ([intellij-rockit](https://rustygits.com/Dark-Matter/intellij-rockit)). It includes built-in LSP client support.

### Sublime Text

```json
// LSP.sublime-settings
{
    "clients": {
        "rockit": {
            "enabled": true,
            "command": ["/path/to/.build/release/rockit", "lsp"],
            "selector": "source.rockit"
        }
    }
}
```

### Emacs (lsp-mode)

```elisp
(with-eval-after-load 'lsp-mode
  (add-to-list 'lsp-language-id-configuration '(rockit-mode . "rockit"))
  (lsp-register-client
    (make-lsp-client
      :new-connection (lsp-stdio-connection '("/path/to/.build/release/rockit" "lsp"))
      :major-modes '(rockit-mode)
      :server-id 'rockit-lsp)))
```

## Diagnostics

The LSP reports diagnostics in real-time as you type:

- **Errors**: Type mismatches, undefined variables, null safety violations, missing returns
- **Warnings**: Unused variables, unreachable code, deprecated API usage
- **Notes**: Related information (e.g., "defined here" for type mismatch errors)

Diagnostics include source locations (line, column, span) for precise underlining in the editor.

## Completion

The completion provider offers:

- **Keywords**: `fun`, `val`, `var`, `class`, `if`, `when`, `for`, etc.
- **Local variables**: In-scope variables with their types
- **Functions**: Available functions with parameter signatures
- **Members**: Fields and methods on an expression (after `.`)
- **Types**: Class, interface, enum, and type alias names
- **Imports**: Available modules for `import` statements

## Semantic Tokens

Semantic highlighting provides rich syntax coloring beyond what regex-based highlighting can achieve:

| Token Type | Examples |
|------------|---------|
| `keyword` | `fun`, `val`, `class`, `if` |
| `function` | Function names at declaration and call sites |
| `variable` | Local variables |
| `parameter` | Function parameters |
| `property` | Class fields |
| `class` | Class, interface, enum names |
| `type` | Type annotations |
| `string` | String literals |
| `number` | Numeric literals |
| `comment` | Line and block comments |
| `operator` | Operators |
