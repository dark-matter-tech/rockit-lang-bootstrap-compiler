// Token.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

/// Source location for error reporting
public struct SourceLocation: Equatable, CustomStringConvertible {
    public let file: String
    public let line: Int
    public let column: Int

    public init(file: String = "<unknown>", line: Int, column: Int) {
        self.file = file
        self.line = line
        self.column = column
    }

    public var description: String {
        "\(file):\(line):\(column)"
    }
}

/// A span of source text
public struct SourceSpan: Equatable {
    public let start: SourceLocation
    public let end: SourceLocation

    public init(start: SourceLocation, end: SourceLocation) {
        self.start = start
        self.end = end
    }
}

/// Every token the Rockit lexer can produce
public enum TokenKind: Equatable {

    // MARK: - Literals

    case intLiteral(Int64)
    case floatLiteral(Double)
    case stringLiteral(String)
    case boolLiteral(Bool)
    case nullLiteral                      // null

    // MARK: - Identifier

    case identifier(String)

    // MARK: - Keywords — Declarations

    case kwFun                            // fun
    case kwVal                            // val
    case kwVar                            // var
    case kwClass                          // class
    case kwInterface                      // interface
    case kwObject                         // object
    case kwEnum                           // enum
    case kwData                           // data
    case kwSealed                         // sealed
    case kwAbstract                       // abstract
    case kwOpen                           // open
    case kwOverride                       // override
    case kwPrivate                        // private
    case kwInternal                       // internal
    case kwPublic                         // public
    case kwProtected                      // protected
    case kwCompanion                      // companion
    case kwTypealias                      // typealias
    case kwVararg                         // vararg

    // MARK: - Keywords — Rockit-Specific

    case kwView                           // view
    case kwActor                          // actor
    case kwNavigation                     // navigation
    case kwRoute                          // route
    case kwTheme                          // theme
    case kwStyle                          // style
    case kwSuspend                        // suspend
    case kwAsync                          // async
    case kwAwait                          // await
    case kwConcurrent                     // concurrent
    case kwWeak                           // weak
    case kwUnowned                        // unowned

    // MARK: - Keywords — Control Flow

    case kwIf                             // if
    case kwElse                           // else
    case kwWhen                           // when
    case kwFor                            // for
    case kwWhile                          // while
    case kwDo                             // do
    case kwReturn                         // return
    case kwBreak                          // break
    case kwContinue                       // continue
    case kwIn                             // in
    case kwIs                             // is
    case kwAs                             // as
    case kwThrow                          // throw
    case kwTry                            // try
    case kwCatch                          // catch
    case kwFinally                        // finally

    // MARK: - Keywords — Type

    case kwImport                         // import
    case kwPackage                        // package
    case kwThis                           // this
    case kwSuper                          // super
    case kwConstructor                    // constructor
    case kwInit                           // init
    case kwWhere                          // where
    case kwOut                            // out

    // MARK: - Operators — Arithmetic

    case plus                             // +
    case minus                            // -
    case star                             // *
    case slash                            // /
    case percent                          // %

    // MARK: - Operators — Comparison

    case equalEqual                       // ==
    case bangEqual                        // !=
    case less                             // <
    case lessEqual                        // <=
    case greater                          // >
    case greaterEqual                     // >=

    // MARK: - Operators — Logical

    case ampAmp                           // &&
    case pipePipe                         // ||
    case bang                             // !

    // MARK: - Operators — Assignment

    case equal                            // =
    case plusEqual                        // +=
    case minusEqual                      // -=
    case starEqual                       // *=
    case slashEqual                      // /=
    case percentEqual                    // %=

    // MARK: - Operators — Null/Range

    case question                         // ?
    case questionDot                      // ?.
    case questionColon                    // ?:  (elvis)
    case bangBang                         // !!
    case dotDot                           // ..
    case dotDotLess                       // ..<

    // MARK: - Operators — Other

    case arrow                            // ->
    case fatArrow                         // =>
    case colonColon                       // ::
    case dot                              // .
    case dotStar                          // .*

    // MARK: - Delimiters

    case leftParen                        // (
    case rightParen                       // )
    case leftBrace                        // {
    case rightBrace                       // }
    case leftBracket                      // [
    case rightBracket                     // ]
    case comma                            // ,
    case colon                            // :
    case semicolon                        // ;
    case at                               // @
    case hash                             // #
    case underscore                       // _
    case backslash                        // \

    // MARK: - String Interpolation

    case stringInterpolationStart         // ${
    case stringInterpolationEnd           // } (inside string)

    // MARK: - Special

    case newline
    case eof
}

/// A single token with its kind and source span
public struct Token: Equatable {
    public let kind: TokenKind
    public let lexeme: String
    public let span: SourceSpan

    public init(kind: TokenKind, lexeme: String, span: SourceSpan) {
        self.kind = kind
        self.lexeme = lexeme
        self.span = span
    }
}

// MARK: - Debug

extension Token: CustomStringConvertible {
    public var description: String {
        switch kind {
        case .identifier(let name):
            return "identifier(\(name))"
        case .intLiteral(let v):
            return "int(\(v))"
        case .floatLiteral(let v):
            return "float(\(v))"
        case .stringLiteral(let v):
            return "string(\"\(v)\")"
        case .eof:
            return "EOF"
        case .newline:
            return "newline"
        default:
            return lexeme.isEmpty ? "\(kind)" : "'\(lexeme)'"
        }
    }
}
