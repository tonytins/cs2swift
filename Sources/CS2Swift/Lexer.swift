/// A place in a C# source file, for diagnostics.
public struct SourceLocation: Equatable, Sendable, CustomStringConvertible {
    /// The 1-based line.
    public var line: Int
    /// The 1-based column.
    public var column: Int

    public var description: String { "\(line):\(column)" }
}

/// A C# token.
struct Token: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case identifier(String)
        case integer(String)
        case real(String)
        case string(String)
        /// `$"..."`: literal text and the source of each `{hole}`.
        case interpolated([InterpolationPart])
        case character(String)
        case punctuation(String)
        case end
    }

    var kind: Kind
    var location: SourceLocation
    /// The comments between the previous token and this one, without their markers. Doc
    /// comments (`///`) keep a leading `/` so they can be told apart.
    var comments: [String]
    /// Whether whitespace or a comment comes right before this token.
    var spaceBefore: Bool
}

/// A piece of an interpolated string.
enum InterpolationPart: Equatable, Sendable {
    case text(String)
    case hole(String, SourceLocation)
}

/// Splits C# source into tokens. Strings are unescaped; numbers keep their spelling.
struct Lexer {
    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var line = 1
    private var column = 1

    init(_ source: String, startingAt location: SourceLocation = SourceLocation(line: 1, column: 1)) {
        scalars = Array(source.unicodeScalars)
        line = location.line
        column = location.column
    }

    static let punctuators: [String] = [
        ">>=", "<<=", "??=", "...",
        "?.", "?[", "??", "=>", "==", "!=", "<=", ">=", "&&", "||", "++", "--", "+=", "-=", "*=", "/=",
        "%=", "&=", "|=", "^=", "<<", "..", "::",
        "{", "}", "(", ")", "[", "]", ";", ",", ".", ":", "?", "+", "-", "*", "/", "%", "&", "|", "^",
        "!", "~", "<", ">", "=", "@", "#",
    ].sorted { $0.count > $1.count }

    mutating func tokenize() throws(TranspileError) -> [Token] {
        var tokens: [Token] = []
        while true {
            let token = try next()
            tokens.append(token)
            if token.kind == .end { return tokens }
        }
    }

    private var current: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

    private func peek(_ offset: Int = 1) -> Unicode.Scalar? {
        index + offset < scalars.count ? scalars[index + offset] : nil
    }

    private var location: SourceLocation { SourceLocation(line: line, column: column) }

    private mutating func advance() {
        guard let scalar = current else { return }
        index += 1
        if scalar == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
    }

    private mutating func next() throws(TranspileError) -> Token {
        var comments: [String] = []
        var spaceBefore = false
        while let scalar = current {
            if scalar.properties.isWhitespace {
                spaceBefore = true
                advance()
            } else if scalar == "/", peek() == "/" {
                advance()
                advance()
                var text = ""
                while let c = current, c != "\n" {
                    text.unicodeScalars.append(c)
                    advance()
                }
                comments.append(text)
                spaceBefore = true
            } else if scalar == "/", peek() == "*" {
                let start = location
                advance()
                advance()
                var text = ""
                while !(current == "*" && peek() == "/") {
                    guard let c = current else { throw TranspileError(start, "unterminated comment") }
                    text.unicodeScalars.append(c)
                    advance()
                }
                advance()
                advance()
                comments.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
                spaceBefore = true
            } else if scalar == "#", column == 1 || precededOnLineBySpaceOnly() {
                // Preprocessor directives (#region, #nullable, ...) carry no code for us.
                while let c = current, c != "\n" { advance() }
            } else {
                break
            }
        }

        let start = location
        func token(_ kind: Token.Kind) -> Token {
            Token(kind: kind, location: start, comments: comments, spaceBefore: spaceBefore)
        }
        guard let scalar = current else { return token(.end) }

        if scalar == "$", peek() == "\"" {
            advance()
            return token(.interpolated(try interpolated()))
        }
        if scalar == "@", peek() == "\"" {
            advance()
            return token(.string(try verbatimString()))
        }
        if scalar == "\"" {
            if peek() == "\"", peek(2) == "\"" { throw TranspileError(start, "raw string literals aren't supported") }
            return token(.string(try quoted(terminator: "\"")))
        }
        if scalar == "'" {
            return token(.character(try quoted(terminator: "'")))
        }
        if scalar.properties.isAlphabetic || scalar == "_" || (scalar == "@" && peek().map(isIdentifierStart) == true) {
            if scalar == "@" { advance() }
            var name = ""
            while let c = current, c.properties.isAlphabetic || c.properties.numericType != nil || c == "_" {
                name.unicodeScalars.append(c)
                advance()
            }
            return token(.identifier(name))
        }
        if scalar.properties.numericType != nil, ("0"..."9").contains(scalar) {
            return token(number())
        }
        for punctuator in Self.punctuators where matches(punctuator) {
            for _ in punctuator.unicodeScalars { advance() }
            return token(.punctuation(punctuator))
        }
        throw TranspileError(start, "unexpected character '\(scalar)'")
    }

    private func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar == "_"
    }

    private func precededOnLineBySpaceOnly() -> Bool {
        var i = index - 1
        while i >= 0, scalars[i] != "\n" {
            if !scalars[i].properties.isWhitespace { return false }
            i -= 1
        }
        return true
    }

    private func matches(_ text: String) -> Bool {
        var i = index
        for scalar in text.unicodeScalars {
            guard i < scalars.count, scalars[i] == scalar else { return false }
            i += 1
        }
        return true
    }

    private mutating func number() -> Token.Kind {
        var text = ""
        var isReal = false
        if current == "0", peek() == "x" || peek() == "X" {
            text += "0x"
            advance()
            advance()
            while let c = current, c.properties.isASCIIHexDigit || c == "_" {
                if c != "_" { text.unicodeScalars.append(c) }
                advance()
            }
        } else {
            while let c = current {
                if ("0"..."9").contains(c) {
                    text.unicodeScalars.append(c)
                } else if c == "_" {
                    // Digit separators drop out.
                } else if c == ".", !isReal, let n = peek(), ("0"..."9").contains(n) {
                    isReal = true
                    text += "."
                } else if c == "e" || c == "E" {
                    isReal = true
                    text += "e"
                    if let sign = peek(), sign == "+" || sign == "-" {
                        advance()
                        text.unicodeScalars.append(sign)
                    }
                } else {
                    break
                }
                advance()
            }
        }
        // Suffixes: f, d, m mark a real; u, l mark an integer's width.
        var suffix = ""
        while let c = current, "fFdDmMuUlL".unicodeScalars.contains(c) {
            suffix.unicodeScalars.append(c)
            advance()
        }
        let lower = suffix.lowercased()
        if lower == "f" { return .real(text + "f") }
        if lower == "d" || lower == "m" || isReal { return .real(text + (lower == "m" ? "m" : "")) }
        return .integer(text)
    }

    private mutating func quoted(terminator: Unicode.Scalar) throws(TranspileError) -> String {
        let start = location
        advance()
        var text = ""
        while true {
            guard let c = current, c != "\n" else { throw TranspileError(start, "unterminated literal") }
            advance()
            if c == terminator { return text }
            if c == "\\" {
                text.unicodeScalars.append(try escape(start))
            } else {
                text.unicodeScalars.append(c)
            }
        }
    }

    private mutating func escape(_ start: SourceLocation) throws(TranspileError) -> Unicode.Scalar {
        guard let c = current else { throw TranspileError(start, "unterminated literal") }
        advance()
        switch c {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "0": return "\0"
        case "\\", "\"", "'": return c
        case "u", "x":
            var hex = ""
            while hex.count < 4, let h = current, h.properties.isASCIIHexDigit {
                hex.unicodeScalars.append(h)
                advance()
            }
            guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
                throw TranspileError(start, "bad \\\(c) escape")
            }
            return scalar
        default:
            throw TranspileError(start, "unsupported escape \\\(c)")
        }
    }

    private mutating func verbatimString() throws(TranspileError) -> String {
        let start = location
        advance()
        var text = ""
        while true {
            guard let c = current else { throw TranspileError(start, "unterminated literal") }
            advance()
            if c == "\"" {
                if current == "\"" {
                    advance()
                    text += "\""
                    continue
                }
                return text
            }
            text.unicodeScalars.append(c)
        }
    }

    private mutating func interpolated() throws(TranspileError) -> [InterpolationPart] {
        let start = location
        advance()
        var parts: [InterpolationPart] = []
        var text = ""
        while true {
            guard let c = current, c != "\n" else { throw TranspileError(start, "unterminated interpolated string") }
            if c == "\"" {
                advance()
                if !text.isEmpty { parts.append(.text(text)) }
                return parts
            }
            if c == "{", peek() == "{" {
                advance()
                advance()
                text += "{"
                continue
            }
            if c == "}", peek() == "}" {
                advance()
                advance()
                text += "}"
                continue
            }
            if c == "{" {
                advance()
                if !text.isEmpty { parts.append(.text(text)) }
                text = ""
                let holeStart = location
                var hole = ""
                var depth = 0
                while true {
                    guard let h = current else { throw TranspileError(start, "unterminated interpolation hole") }
                    if h == "}" && depth == 0 { break }
                    if h == "(" || h == "[" || h == "{" { depth += 1 }
                    if h == ")" || h == "]" || h == "}" { depth -= 1 }
                    if depth == 0, h == ":" || h == "," {
                        throw TranspileError(holeStart, "format specifiers and alignment in interpolated strings aren't supported")
                    }
                    if h == "\"" { throw TranspileError(holeStart, "strings inside interpolation holes aren't supported") }
                    hole.unicodeScalars.append(h)
                    advance()
                }
                advance()
                parts.append(.hole(hole, holeStart))
                continue
            }
            advance()
            if c == "\\" {
                text.unicodeScalars.append(try escape(start))
            } else {
                text.unicodeScalars.append(c)
            }
        }
    }
}

/// A construct cs2swift can't translate, or C# it can't read, with where it is.
public struct TranspileError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Where in the source file.
    public var location: SourceLocation
    /// What went wrong.
    public var message: String

    init(_ location: SourceLocation, _ message: String) {
        self.location = location
        self.message = message
    }

    public var description: String { "\(location): \(message)" }
}
