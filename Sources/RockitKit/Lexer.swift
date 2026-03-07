// Lexer.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

/// Tokenizes Rockit source code into a stream of `Token`s.
///
/// The lexer is a single-pass scanner that processes UTF-8 source text
/// character by character. It handles:
/// - All Rockit keywords (Kotlin-inherited + Rockit-specific)
/// - String literals with `${}` interpolation
/// - Integer and floating-point number literals (decimal, hex, binary)
/// - Single-line (`//`) and multi-line (`/* */`) comments
/// - All operators and delimiters from the Rockit spec grammar
/// - Significant newlines (Rockit uses newlines as statement terminators)
public final class Lexer {

    // MARK: - State

    private let source: String
    private let fileName: String
    private var chars: String.UnicodeScalarView
    private var index: String.UnicodeScalarView.Index
    private var line: Int = 1
    private var column: Int = 1
    private let diagnostics: DiagnosticEngine

    /// Tracks brace depth inside string interpolation
    private var interpolationDepth: [Int] = []

    // MARK: - Keyword Table

    private static let keywords: [String: TokenKind] = [
        // Declarations
        "fun":         .kwFun,
        "val":         .kwVal,
        "var":         .kwVar,
        "class":       .kwClass,
        "interface":   .kwInterface,
        "object":      .kwObject,
        "enum":        .kwEnum,
        "data":        .kwData,
        "sealed":      .kwSealed,
        "abstract":    .kwAbstract,
        "open":        .kwOpen,
        "override":    .kwOverride,
        "private":     .kwPrivate,
        "internal":    .kwInternal,
        "public":      .kwPublic,
        "protected":   .kwProtected,
        "companion":   .kwCompanion,
        "typealias":   .kwTypealias,
        "vararg":      .kwVararg,

        // Rockit-specific
        "view":        .kwView,
        "actor":       .kwActor,
        "navigation":  .kwNavigation,
        "route":       .kwRoute,
        "theme":       .kwTheme,
        "style":       .kwStyle,
        "suspend":     .kwSuspend,
        "async":       .kwAsync,
        "await":       .kwAwait,
        "concurrent":  .kwConcurrent,
        "weak":        .kwWeak,
        "unowned":     .kwUnowned,

        // Control flow
        "if":          .kwIf,
        "else":        .kwElse,
        "when":        .kwWhen,
        "for":         .kwFor,
        "while":       .kwWhile,
        "do":          .kwDo,
        "return":      .kwReturn,
        "break":       .kwBreak,
        "continue":    .kwContinue,
        "in":          .kwIn,
        "is":          .kwIs,
        "as":          .kwAs,
        "throw":       .kwThrow,
        "try":         .kwTry,
        "catch":       .kwCatch,
        "finally":     .kwFinally,

        // Type & module
        "import":      .kwImport,
        "package":     .kwPackage,
        "this":        .kwThis,
        "super":       .kwSuper,
        "constructor": .kwConstructor,
        "init":        .kwInit,
        "where":       .kwWhere,
        "out":         .kwOut,

        // Literals
        "true":        .boolLiteral(true),
        "false":       .boolLiteral(false),
        "null":        .nullLiteral,
    ]

    // MARK: - Init

    public init(source: String, fileName: String = "<stdin>", diagnostics: DiagnosticEngine = DiagnosticEngine()) {
        self.source = source
        self.fileName = fileName
        self.chars = source.unicodeScalars
        self.index = self.chars.startIndex
        self.diagnostics = diagnostics
    }

    // MARK: - Public API

    /// Tokenize the entire source. Returns the token list (always ends with `.eof`).
    public func tokenize() -> [Token] {
        var tokens: [Token] = []

        while true {
            let tok = nextToken()
            tokens.append(tok)
            if tok.kind == .eof { break }
        }

        return tokens
    }

    /// Produce the next token from the source.
    public func nextToken() -> Token {
        skipWhitespaceAndComments()

        guard !isAtEnd else {
            return makeToken(.eof, lexeme: "")
        }

        let startLine = line
        let startCol = column

        let c = peek()

        // Newline
        if c == "\n" {
            advance()
            return makeTokenAt(.newline, lexeme: "\\n", line: startLine, col: startCol)
        }

        // Numbers
        if c.isDigit {
            return lexNumber()
        }

        // Strings
        if c == "\"" {
            return lexString()
        }

        // Identifiers & keywords
        if c.isIdentStart {
            return lexIdentifier()
        }

        // Annotation shorthand: @Identifier
        if c == "@" {
            advance()
            return makeTokenAt(.at, lexeme: "@", line: startLine, col: startCol)
        }

        // Operators & punctuation
        return lexOperator()
    }

    // MARK: - Character Helpers

    private var isAtEnd: Bool {
        index >= chars.endIndex
    }

    private func peek() -> Unicode.Scalar {
        guard !isAtEnd else { return "\0" }
        return chars[index]
    }

    private func peekNext() -> Unicode.Scalar {
        let next = chars.index(after: index)
        guard next < chars.endIndex else { return "\0" }
        return chars[next]
    }

    @discardableResult
    private func advance() -> Unicode.Scalar {
        let c = chars[index]
        index = chars.index(after: index)
        if c == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
        return c
    }

    private func match(_ expected: Unicode.Scalar) -> Bool {
        guard !isAtEnd, chars[index] == expected else { return false }
        advance()
        return true
    }

    // MARK: - Skip Whitespace & Comments

    private func skipWhitespaceAndComments() {
        while !isAtEnd {
            let c = peek()

            // Whitespace (not newlines — those are tokens)
            if c == " " || c == "\t" || c == "\r" {
                advance()
                continue
            }

            // Single-line comment
            if c == "/" && peekNext() == "/" {
                advance(); advance()
                while !isAtEnd && peek() != "\n" {
                    advance()
                }
                continue
            }

            // Multi-line comment (nestable)
            if c == "/" && peekNext() == "*" {
                advance(); advance()
                var depth = 1
                while !isAtEnd && depth > 0 {
                    if peek() == "/" && peekNext() == "*" {
                        advance(); advance()
                        depth += 1
                    } else if peek() == "*" && peekNext() == "/" {
                        advance(); advance()
                        depth -= 1
                    } else {
                        advance()
                    }
                }
                if depth > 0 {
                    diagnostics.error("unterminated block comment", at: currentLocation())
                }
                continue
            }

            break
        }
    }

    // MARK: - Number Literals

    private func lexNumber() -> Token {
        let startLine = line
        let startCol = column
        var text = ""

        // Hex: 0x...
        if peek() == "0" && (peekNext() == "x" || peekNext() == "X") {
            text.append(Character(advance()))
            text.append(Character(advance()))
            while !isAtEnd && (peek().isHexDigit || peek() == "_") {
                if peek() != "_" { text.append(Character(advance())) }
                else { advance() }
            }
            guard let value = Int64(text.dropFirst(2), radix: 16) else {
                diagnostics.error("invalid hex literal '\(text)'", at: loc(startLine, startCol))
                return makeTokenAt(.intLiteral(0), lexeme: text, line: startLine, col: startCol)
            }
            return makeTokenAt(.intLiteral(value), lexeme: text, line: startLine, col: startCol)
        }

        // Binary: 0b...
        if peek() == "0" && (peekNext() == "b" || peekNext() == "B") {
            text.append(Character(advance()))
            text.append(Character(advance()))
            while !isAtEnd && (peek() == "0" || peek() == "1" || peek() == "_") {
                if peek() != "_" { text.append(Character(advance())) }
                else { advance() }
            }
            guard let value = Int64(text.dropFirst(2), radix: 2) else {
                diagnostics.error("invalid binary literal '\(text)'", at: loc(startLine, startCol))
                return makeTokenAt(.intLiteral(0), lexeme: text, line: startLine, col: startCol)
            }
            return makeTokenAt(.intLiteral(value), lexeme: text, line: startLine, col: startCol)
        }

        // Decimal (possibly float)
        var isFloat = false
        while !isAtEnd && (peek().isDigit || peek() == "_") {
            if peek() != "_" { text.append(Character(advance())) }
            else { advance() }
        }

        // Fractional part
        if !isAtEnd && peek() == "." && peekNext().isDigit {
            isFloat = true
            text.append(Character(advance()))  // .
            while !isAtEnd && (peek().isDigit || peek() == "_") {
                if peek() != "_" { text.append(Character(advance())) }
                else { advance() }
            }
        }

        // Exponent
        if !isAtEnd && (peek() == "e" || peek() == "E") {
            isFloat = true
            text.append(Character(advance()))
            if !isAtEnd && (peek() == "+" || peek() == "-") {
                text.append(Character(advance()))
            }
            while !isAtEnd && peek().isDigit {
                text.append(Character(advance()))
            }
        }

        if isFloat {
            let value = Double(text) ?? 0.0
            return makeTokenAt(.floatLiteral(value), lexeme: text, line: startLine, col: startCol)
        } else {
            let value = Int64(text) ?? 0
            return makeTokenAt(.intLiteral(value), lexeme: text, line: startLine, col: startCol)
        }
    }

    // MARK: - String Literals

    private func lexString() -> Token {
        let startLine = line
        let startCol = column
        advance() // consume opening "

        // Check for triple-quoted (multi-line) string: """..."""
        if peek() == "\"" && peekNext() == "\"" {
            advance() // consume second "
            advance() // consume third "
            return lexTripleQuotedString(startLine: startLine, startCol: startCol)
        }

        var value = ""

        while !isAtEnd && peek() != "\"" && peek() != "\n" {
            if peek() == "\\" {
                advance()
                guard !isAtEnd else { break }
                let escaped = advance()
                switch escaped {
                case "n":  value.append("\n")
                case "t":  value.append("\t")
                case "r":  value.append("\r")
                case "\\": value.append("\\")
                case "\"": value.append("\"")
                case "$":  value.append("$")
                case "0":  value.append("\0")
                case "u":
                    // \u{XXXX} unicode escape
                    if match("{") {
                        var hex = ""
                        while !isAtEnd && peek() != "}" {
                            hex.append(Character(advance()))
                        }
                        if match("}"), let code = UInt32(hex, radix: 16),
                           let scalar = Unicode.Scalar(code) {
                            value.append(Character(scalar))
                        } else {
                            diagnostics.error("invalid unicode escape", at: loc(startLine, startCol))
                        }
                    }
                default:
                    diagnostics.error("invalid escape sequence '\\(escaped)'", at: currentLocation())
                    value.append(Character(escaped))
                }
                continue
            }

            // String interpolation: ${...}
            // For the lexer, we just include it literally in the string value.
            // The parser will handle interpolation segments.
            // TODO: Phase 2 — emit interpolation tokens for the parser
            if peek() == "$" && peekNext() == "{" {
                advance() // $
                advance() // {
                value.append("${")
                var depth = 1
                while !isAtEnd && depth > 0 {
                    if peek() == "{" { depth += 1 }
                    if peek() == "}" { depth -= 1 }
                    if depth > 0 { value.append(Character(advance())) }
                }
                if !isAtEnd { advance() } // closing }
                value.append("}")
                continue
            }

            // Simple $identifier interpolation
            if peek() == "$" && peekNext().isIdentStart {
                advance() // $
                value.append("$")
                while !isAtEnd && peek().isIdentContinue {
                    value.append(Character(advance()))
                }
                continue
            }

            value.append(Character(advance()))
        }

        if isAtEnd || peek() == "\n" {
            diagnostics.error("unterminated string literal", at: loc(startLine, startCol))
        } else {
            advance() // consume closing "
        }

        return makeTokenAt(.stringLiteral(value), lexeme: "\"\(value)\"", line: startLine, col: startCol)
    }

    /// Lex a triple-quoted (multi-line) string: """..."""
    private func lexTripleQuotedString(startLine: Int, startCol: Int) -> Token {
        var value = ""

        // Skip leading newline if present
        if !isAtEnd && peek() == "\n" {
            advance()
        }

        while !isAtEnd {
            // Check for closing """
            if peek() == "\"" && peekNext() == "\"" {
                let afterSecond = chars.index(after: chars.index(after: index))
                if afterSecond < chars.endIndex && chars[afterSecond] == "\"" {
                    advance() // consume first "
                    advance() // consume second "
                    advance() // consume third "
                    return makeTokenAt(.stringLiteral(value), lexeme: "\"\"\"\(value)\"\"\"",
                                       line: startLine, col: startCol)
                }
            }

            if peek() == "\\" {
                advance()
                guard !isAtEnd else { break }
                let escaped = advance()
                switch escaped {
                case "n":  value.append("\n")
                case "t":  value.append("\t")
                case "r":  value.append("\r")
                case "\\": value.append("\\")
                case "\"": value.append("\"")
                case "$":  value.append("$")
                case "0":  value.append("\0")
                case "u":
                    if match("{") {
                        var hex = ""
                        while !isAtEnd && peek() != "}" {
                            hex.append(Character(advance()))
                        }
                        if match("}"), let code = UInt32(hex, radix: 16),
                           let scalar = Unicode.Scalar(code) {
                            value.append(Character(scalar))
                        } else {
                            diagnostics.error("invalid unicode escape", at: loc(startLine, startCol))
                        }
                    }
                default:
                    value.append("\\")
                    value.append(Character(escaped))
                }
                continue
            }

            // String interpolation: ${...}
            if peek() == "$" && peekNext() == "{" {
                advance() // $
                advance() // {
                value.append("${")
                var depth = 1
                while !isAtEnd && depth > 0 {
                    if peek() == "{" { depth += 1 }
                    if peek() == "}" { depth -= 1 }
                    if depth > 0 { value.append(Character(advance())) }
                }
                if !isAtEnd { advance() } // closing }
                value.append("}")
                continue
            }

            // Simple $identifier interpolation
            if peek() == "$" && peekNext().isIdentStart {
                advance() // $
                value.append("$")
                while !isAtEnd && peek().isIdentContinue {
                    value.append(Character(advance()))
                }
                continue
            }

            value.append(Character(advance()))
        }

        diagnostics.error("unterminated multi-line string literal", at: loc(startLine, startCol))
        return makeTokenAt(.stringLiteral(value), lexeme: "\"\"\"\(value)\"\"\"",
                           line: startLine, col: startCol)
    }

    // MARK: - Identifiers & Keywords

    private func lexIdentifier() -> Token {
        let startLine = line
        let startCol = column
        var text = ""

        while !isAtEnd && peek().isIdentContinue {
            text.append(Character(advance()))
        }

        // Check keyword table
        if let keyword = Lexer.keywords[text] {
            return makeTokenAt(keyword, lexeme: text, line: startLine, col: startCol)
        }

        // Underscore by itself is a special token
        if text == "_" {
            return makeTokenAt(.underscore, lexeme: "_", line: startLine, col: startCol)
        }

        return makeTokenAt(.identifier(text), lexeme: text, line: startLine, col: startCol)
    }

    // MARK: - Operators & Punctuation

    private func lexOperator() -> Token {
        let startLine = line
        let startCol = column
        let c = advance()

        switch c {
        case "(": return makeTokenAt(.leftParen, lexeme: "(", line: startLine, col: startCol)
        case ")": return makeTokenAt(.rightParen, lexeme: ")", line: startLine, col: startCol)
        case "{": return makeTokenAt(.leftBrace, lexeme: "{", line: startLine, col: startCol)
        case "}": return makeTokenAt(.rightBrace, lexeme: "}", line: startLine, col: startCol)
        case "[": return makeTokenAt(.leftBracket, lexeme: "[", line: startLine, col: startCol)
        case "]": return makeTokenAt(.rightBracket, lexeme: "]", line: startLine, col: startCol)
        case ",": return makeTokenAt(.comma, lexeme: ",", line: startLine, col: startCol)
        case ";": return makeTokenAt(.semicolon, lexeme: ";", line: startLine, col: startCol)
        case "#": return makeTokenAt(.hash, lexeme: "#", line: startLine, col: startCol)
        case "\\": return makeTokenAt(.backslash, lexeme: "\\", line: startLine, col: startCol)

        case "+":
            if match("=") { return makeTokenAt(.plusEqual, lexeme: "+=", line: startLine, col: startCol) }
            return makeTokenAt(.plus, lexeme: "+", line: startLine, col: startCol)

        case "-":
            if match(">") { return makeTokenAt(.arrow, lexeme: "->", line: startLine, col: startCol) }
            if match("=") { return makeTokenAt(.minusEqual, lexeme: "-=", line: startLine, col: startCol) }
            return makeTokenAt(.minus, lexeme: "-", line: startLine, col: startCol)

        case "*":
            if match("=") { return makeTokenAt(.starEqual, lexeme: "*=", line: startLine, col: startCol) }
            return makeTokenAt(.star, lexeme: "*", line: startLine, col: startCol)

        case "/":
            if match("=") { return makeTokenAt(.slashEqual, lexeme: "/=", line: startLine, col: startCol) }
            return makeTokenAt(.slash, lexeme: "/", line: startLine, col: startCol)

        case "%":
            if match("=") { return makeTokenAt(.percentEqual, lexeme: "%=", line: startLine, col: startCol) }
            return makeTokenAt(.percent, lexeme: "%", line: startLine, col: startCol)

        case "=":
            if match("=") { return makeTokenAt(.equalEqual, lexeme: "==", line: startLine, col: startCol) }
            if match(">") { return makeTokenAt(.fatArrow, lexeme: "=>", line: startLine, col: startCol) }
            return makeTokenAt(.equal, lexeme: "=", line: startLine, col: startCol)

        case "!":
            if match("=") { return makeTokenAt(.bangEqual, lexeme: "!=", line: startLine, col: startCol) }
            if match("!") { return makeTokenAt(.bangBang, lexeme: "!!", line: startLine, col: startCol) }
            return makeTokenAt(.bang, lexeme: "!", line: startLine, col: startCol)

        case "<":
            if match("=") { return makeTokenAt(.lessEqual, lexeme: "<=", line: startLine, col: startCol) }
            return makeTokenAt(.less, lexeme: "<", line: startLine, col: startCol)

        case ">":
            if match("=") { return makeTokenAt(.greaterEqual, lexeme: ">=", line: startLine, col: startCol) }
            return makeTokenAt(.greater, lexeme: ">", line: startLine, col: startCol)

        case "&":
            if match("&") { return makeTokenAt(.ampAmp, lexeme: "&&", line: startLine, col: startCol) }
            diagnostics.error("unexpected character '&' (did you mean '&&'?)", at: loc(startLine, startCol))
            return makeTokenAt(.ampAmp, lexeme: "&", line: startLine, col: startCol)

        case "|":
            if match("|") { return makeTokenAt(.pipePipe, lexeme: "||", line: startLine, col: startCol) }
            diagnostics.error("unexpected character '|' (did you mean '||'?)", at: loc(startLine, startCol))
            return makeTokenAt(.pipePipe, lexeme: "|", line: startLine, col: startCol)

        case ".":
            if match(".") {
                if match("<") { return makeTokenAt(.dotDotLess, lexeme: "..<", line: startLine, col: startCol) }
                return makeTokenAt(.dotDot, lexeme: "..", line: startLine, col: startCol)
            }
            if match("*") { return makeTokenAt(.dotStar, lexeme: ".*", line: startLine, col: startCol) }
            return makeTokenAt(.dot, lexeme: ".", line: startLine, col: startCol)

        case ":":
            if match(":") { return makeTokenAt(.colonColon, lexeme: "::", line: startLine, col: startCol) }
            return makeTokenAt(.colon, lexeme: ":", line: startLine, col: startCol)

        case "?":
            if match(".") { return makeTokenAt(.questionDot, lexeme: "?.", line: startLine, col: startCol) }
            if match(":") { return makeTokenAt(.questionColon, lexeme: "?:", line: startLine, col: startCol) }
            return makeTokenAt(.question, lexeme: "?", line: startLine, col: startCol)

        default:
            diagnostics.error("unexpected character '\(c)'", at: loc(startLine, startCol))
            return makeTokenAt(.identifier(String(c)), lexeme: String(c), line: startLine, col: startCol)
        }
    }

    // MARK: - Token Factories

    private func makeToken(_ kind: TokenKind, lexeme: String) -> Token {
        let loc = currentLocation()
        return Token(kind: kind, lexeme: lexeme, span: SourceSpan(start: loc, end: loc))
    }

    private func makeTokenAt(_ kind: TokenKind, lexeme: String, line: Int, col: Int) -> Token {
        let start = SourceLocation(file: fileName, line: line, column: col)
        let end = currentLocation()
        return Token(kind: kind, lexeme: lexeme, span: SourceSpan(start: start, end: end))
    }

    private func currentLocation() -> SourceLocation {
        SourceLocation(file: fileName, line: line, column: column)
    }

    private func loc(_ line: Int, _ col: Int) -> SourceLocation {
        SourceLocation(file: fileName, line: line, column: col)
    }
}

// MARK: - Unicode.Scalar Extensions

extension Unicode.Scalar {
    var isDigit: Bool {
        self >= "0" && self <= "9"
    }

    var isHexDigit: Bool {
        isDigit || (self >= "a" && self <= "f") || (self >= "A" && self <= "F")
    }

    var isIdentStart: Bool {
        (self >= "a" && self <= "z") ||
        (self >= "A" && self <= "Z") ||
        self == "_"
    }

    var isIdentContinue: Bool {
        isIdentStart || isDigit
    }
}
