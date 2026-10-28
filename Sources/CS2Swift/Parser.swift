/// A recursive-descent parser for the subset of C# cs2swift translates. Anything outside it
/// is an error at its location, never skipped.
struct Parser {
    private var tokens: [Token]
    private var position = 0
    private let path: String

    init(source: String, path: String) throws(TranspileError) {
        var lexer = Lexer(source)
        tokens = try lexer.tokenize()
        self.path = path
    }

    private init(tokens: [Token], path: String) {
        self.tokens = tokens
        self.path = path
    }

    // MARK: Files and types

    mutating func parseFile() throws(TranspileError) -> SourceFile {
        var types: [TypeDeclaration] = []
        var blockNamespaces = 0
        while !atEnd {
            if isIdentifier("global") || isIdentifier("using") {
                if isIdentifier("using"), peekKind(1) == .punctuation("(") || isIdentifier("var", 1) {
                    throw error("using statements outside a method")
                }
                while !isPunctuation(";") { try advanceOrFail() }
                position += 1
            } else if isIdentifier("namespace") {
                position += 1
                _ = try qualifiedName()
                if isPunctuation(";") {
                    position += 1
                } else {
                    try expect("{")
                    blockNamespaces += 1
                }
            } else if isPunctuation("}"), blockNamespaces > 0 {
                position += 1
                blockNamespaces -= 1
            } else {
                types.append(try typeDeclaration(attributes: try attributes(), comments: current.comments))
            }
        }
        return SourceFile(path: path, types: types)
    }

    private static let typeModifiers: Set<String> = [
        "public", "private", "internal", "protected", "static", "sealed", "abstract", "readonly",
        "partial", "file", "unsafe", "new", "const", "virtual", "override", "required", "extern", "volatile",
    ]

    private mutating func modifiers() -> Set<String> {
        var result: Set<String> = []
        while case .identifier(let word) = current.kind, Self.typeModifiers.contains(word) {
            // `new()` at a member's start is a target-typed expression, not a modifier; it
            // can't start a member, so a `new` followed by `(` isn't seen here.
            result.insert(word)
            position += 1
        }
        return result
    }

    private mutating func attributes() throws(TranspileError) -> [String] {
        var names: [String] = []
        while isPunctuation("[") {
            position += 1
            var depth = 1
            var first = true
            while depth > 0 {
                if first, case .identifier(let name) = current.kind { names.append(name) }
                first = false
                if isPunctuation("[") { depth += 1 }
                if isPunctuation("]") { depth -= 1 }
                if isPunctuation(",") && depth == 1 { first = true }
                try advanceOrFail()
            }
        }
        return names
    }

    private mutating func typeDeclaration(attributes: [String], comments: [String]) throws(TranspileError) -> TypeDeclaration {
        let modifiers = modifiers()
        let location = current.location
        guard case .identifier(let keyword) = current.kind else { throw error("expected a type declaration") }
        let kind: TypeDeclaration.Kind
        switch keyword {
        case "class": kind = .class
        case "struct": kind = .struct
        case "interface": kind = .interface
        case "enum": kind = .enum
        case "record": throw error("records aren't supported yet")
        case "delegate": throw error("delegate types aren't supported; use Func or Action")
        default: throw error("expected class, struct, interface, or enum, found '\(keyword)'")
        }
        position += 1
        let name = try identifier()
        if isPunctuation("<") { throw error("generic types aren't supported") }
        if isPunctuation("(") { throw error("primary constructors aren't supported") }
        var bases: [TypeSyntax] = []
        if isPunctuation(":") {
            position += 1
            repeat {
                if isPunctuation(",") { position += 1 }
                bases.append(try type())
            } while isPunctuation(",")
        }
        if isIdentifier("where") { throw error("generic constraints aren't supported") }
        try expect("{")

        var members: [Member] = []
        var cases: [EnumCase] = []
        if kind == .enum {
            while !isPunctuation("}") {
                let caseComments = current.comments
                _ = try self.attributes()
                let caseName = try identifier()
                var value: Expression?
                if isPunctuation("=") {
                    position += 1
                    value = try expression()
                }
                cases.append(EnumCase(name: caseName, value: value, comments: caseComments))
                if isPunctuation(",") { position += 1 } else { break }
            }
            try expect("}")
        } else {
            while !isPunctuation("}") {
                members.append(try member(in: name, kind: kind))
            }
            try expect("}")
        }
        if isPunctuation(";") { position += 1 }
        return TypeDeclaration(
            kind: kind, name: name, modifiers: modifiers, attributes: attributes, bases: bases,
            members: members, enumCases: cases, comments: comments, location: location
        )
    }

    private mutating func member(in typeName: String, kind: TypeDeclaration.Kind) throws(TranspileError) -> Member {
        let comments = current.comments
        let attributes = try attributes()
        let start = position
        let modifiers = modifiers()
        let location = current.location

        if case .identifier(let word) = current.kind, ["class", "struct", "interface", "enum", "record", "delegate"].contains(word) {
            position = start
            return .type(try typeDeclaration(attributes: attributes, comments: comments))
        }
        if isIdentifier("event") { throw error("events aren't supported") }
        if isPunctuation("~") { throw error("finalizers aren't supported") }
        if isIdentifier(typeName), peekKind(1) == .punctuation("(") {
            position += 1
            let parameters = try parameterList()
            if isPunctuation(":") { throw error("constructor initializers (: this(...) or : base(...)) aren't supported") }
            let body = try methodBody()
            return .constructor(Method(
                modifiers: modifiers, returnType: nil, name: typeName, parameters: parameters,
                body: body, comments: comments, location: location
            ))
        }

        let memberType = try type()
        if isIdentifier("operator") || isIdentifier("implicit") || isIdentifier("explicit") {
            throw error("operator declarations aren't supported")
        }
        if isIdentifier("this") { throw error("indexers aren't supported") }
        let name = try identifier()
        if isPunctuation(".") { throw error("explicit interface implementations aren't supported") }
        if isPunctuation("<") { throw error("generic methods aren't supported") }

        if isPunctuation("(") {
            let parameters = try parameterList()
            let body = try methodBody()
            return .method(Method(
                modifiers: modifiers, returnType: memberType, name: name, parameters: parameters,
                body: body, comments: comments, location: location
            ))
        }
        if isPunctuation("=>") {
            position += 1
            let body = try expression()
            try expect(";")
            return .property(Property(
                modifiers: modifiers, type: memberType, name: name,
                getter: Accessor(modifiers: [], body: .expression(body), isInit: false),
                setter: nil, initializer: nil, comments: comments, location: location
            ))
        }
        if isPunctuation("{") {
            position += 1
            var getter: Accessor?
            var setter: Accessor?
            while !isPunctuation("}") {
                let accessorModifiers = self.modifiers()
                let accessorName = try identifier()
                let body: Accessor.Body
                if isPunctuation(";") {
                    position += 1
                    body = .automatic
                } else if isPunctuation("=>") {
                    position += 1
                    body = .expression(try expression())
                    try expect(";")
                } else {
                    body = .block(try block())
                }
                let accessor = Accessor(modifiers: accessorModifiers, body: body, isInit: accessorName == "init")
                switch accessorName {
                case "get": getter = accessor
                case "set", "init": setter = accessor
                default: throw error("unexpected accessor '\(accessorName)'")
                }
            }
            try expect("}")
            var initializer: Expression?
            if isPunctuation("=") {
                position += 1
                initializer = try expression()
                try expect(";")
            }
            return .property(Property(
                modifiers: modifiers, type: memberType, name: name, getter: getter, setter: setter,
                initializer: initializer, comments: comments, location: location
            ))
        }

        var declarators: [(name: String, initializer: Expression?)] = []
        var declaratorName = name
        while true {
            var initializer: Expression?
            if isPunctuation("=") {
                position += 1
                initializer = try expression()
            }
            declarators.append((declaratorName, initializer))
            if isPunctuation(",") {
                position += 1
                declaratorName = try identifier()
            } else {
                break
            }
        }
        try expect(";")
        return .field(Field(modifiers: modifiers, type: memberType, declarators: declarators, comments: comments, location: location))
    }

    private mutating func parameterList() throws(TranspileError) -> [Parameter] {
        try expect("(")
        var parameters: [Parameter] = []
        while !isPunctuation(")") {
            _ = try attributes()
            var modifier: String?
            if case .identifier(let word) = current.kind, ["ref", "out", "in", "params", "this", "scoped"].contains(word) {
                modifier = word
                position += 1
            }
            let parameterType = try type()
            let name = try identifier()
            var defaultValue: Expression?
            if isPunctuation("=") {
                position += 1
                defaultValue = try expression()
            }
            parameters.append(Parameter(modifier: modifier, type: parameterType, name: name, defaultValue: defaultValue))
            if isPunctuation(",") { position += 1 } else { break }
        }
        try expect(")")
        return parameters
    }

    private mutating func methodBody() throws(TranspileError) -> Method.Body {
        if isPunctuation(";") {
            position += 1
            return .none
        }
        if isPunctuation("=>") {
            position += 1
            let body = try expression()
            try expect(";")
            return .expression(body)
        }
        return .block(try block())
    }

    // MARK: Types

    mutating func type() throws(TranspileError) -> TypeSyntax {
        var result: TypeSyntax
        if isPunctuation("(") {
            position += 1
            var elements: [TypeSyntax] = []
            repeat {
                if isPunctuation(",") { position += 1 }
                elements.append(try type())
                if case .identifier = current.kind { position += 1 }
            } while isPunctuation(",")
            try expect(")")
            result = .tuple(elements)
        } else {
            let name = try qualifiedName()
            var arguments: [TypeSyntax] = []
            if isPunctuation("<") {
                position += 1
                repeat {
                    if isPunctuation(",") { position += 1 }
                    arguments.append(try type())
                } while isPunctuation(",")
                try expectClosingAngle()
            }
            result = .named(name, arguments)
        }
        while true {
            if isPunctuation("?") {
                position += 1
                result = .nullable(result)
            } else if isPunctuation("["), peekKind(1) == .punctuation("]") {
                position += 2
                result = .array(result)
            } else {
                return result
            }
        }
    }

    /// Closes a type argument list, splitting a `>>` the lexer never forms (it lexes `>` alone).
    private mutating func expectClosingAngle() throws(TranspileError) {
        try expect(">")
    }

    private mutating func qualifiedName() throws(TranspileError) -> String {
        var name = try identifier()
        while isPunctuation("."), case .identifier(let next) = peekKind(1) {
            position += 2
            name += "." + next
        }
        return name
    }

    // MARK: Statements

    private mutating func block() throws(TranspileError) -> [Statement] {
        try expect("{")
        var statements: [Statement] = []
        while !isPunctuation("}") {
            statements.append(try statement())
        }
        let closing = current
        try expect("}")
        // Comments before the closing brace would otherwise be lost.
        if !closing.comments.isEmpty {
            statements.append(Statement(kind: .empty, comments: closing.comments, location: closing.location))
        }
        return statements
    }

    private mutating func statement() throws(TranspileError) -> Statement {
        let comments = current.comments
        let location = current.location
        func make(_ kind: Statement.Kind) -> Statement { Statement(kind: kind, comments: comments, location: location) }

        if isPunctuation("{") { return make(.block(try block())) }
        if isPunctuation(";") {
            position += 1
            return make(.empty)
        }
        guard case .identifier(let word) = current.kind else {
            let value = try expression()
            try expect(";")
            return make(.expression(value))
        }
        switch word {
        case "if":
            position += 1
            try expect("(")
            let condition = try expression()
            try expect(")")
            let then = try statement()
            var otherwise: Statement?
            if isIdentifier("else") {
                position += 1
                otherwise = try statement()
            }
            return make(.if(condition, then, otherwise))
        case "while":
            position += 1
            try expect("(")
            let condition = try expression()
            try expect(")")
            return make(.while(condition, try statement()))
        case "do":
            position += 1
            let body = try statement()
            guard isIdentifier("while") else { throw error("expected while") }
            position += 1
            try expect("(")
            let condition = try expression()
            try expect(")")
            try expect(";")
            return make(.doWhile(body, condition))
        case "for":
            position += 1
            try expect("(")
            var initializers: [Statement] = []
            if !isPunctuation(";") {
                if let local = try localDeclaration(comments: [], location: current.location) {
                    initializers.append(local)
                } else {
                    repeat {
                        if isPunctuation(",") { position += 1 }
                        let value = try expression()
                        initializers.append(Statement(kind: .expression(value), comments: [], location: value.location))
                    } while isPunctuation(",")
                }
            }
            try expect(";")
            let condition = isPunctuation(";") ? nil : try expression()
            try expect(";")
            var increments: [Expression] = []
            while !isPunctuation(")") {
                increments.append(try expression())
                if isPunctuation(",") { position += 1 }
            }
            try expect(")")
            return make(.for(initializers: initializers, condition: condition, increments: increments, body: try statement()))
        case "foreach":
            position += 1
            try expect("(")
            if isIdentifier("var"), peekKind(1) == .punctuation("(") { throw error("deconstructing foreach isn't supported") }
            if !isIdentifier("var") { _ = try type() } else { position += 1 }
            let name = try identifier()
            guard isIdentifier("in") else { throw error("expected in") }
            position += 1
            let sequence = try expression()
            try expect(")")
            return make(.foreach(name: name, sequence, try statement()))
        case "switch":
            position += 1
            try expect("(")
            let subject = try expression()
            try expect(")")
            try expect("{")
            var sections: [SwitchSection] = []
            while !isPunctuation("}") {
                var labels: [Expression?] = []
                while isIdentifier("case") || isIdentifier("default") {
                    if isIdentifier("default") {
                        position += 1
                        labels.append(nil)
                    } else {
                        position += 1
                        labels.append(try expression())
                        if isIdentifier("when") { throw error("case guards (when) aren't supported") }
                    }
                    try expect(":")
                }
                guard !labels.isEmpty else { throw error("expected case or default") }
                var body: [Statement] = []
                while !isIdentifier("case") && !isIdentifier("default") && !isPunctuation("}") {
                    body.append(try statement())
                }
                sections.append(SwitchSection(labels: labels, body: body))
            }
            try expect("}")
            return make(.switch(subject, sections))
        case "return":
            position += 1
            if isPunctuation(";") {
                position += 1
                return make(.return(nil))
            }
            let value = try expression()
            try expect(";")
            return make(.return(value))
        case "break":
            position += 1
            try expect(";")
            return make(.break)
        case "continue":
            position += 1
            try expect(";")
            return make(.continue)
        case "throw": throw error("throw isn't supported; NewSO code reports errors without exceptions")
        case "try": throw error("try/catch isn't supported")
        case "using", "lock", "goto", "yield", "unsafe", "fixed", "checked", "unchecked":
            throw error("\(word) statements aren't supported")
        default:
            break
        }
        if let local = try localDeclaration(comments: comments, location: location) {
            try expect(";")
            return local
        }
        let value = try expression()
        try expect(";")
        return make(.expression(value))
    }

    /// A local declaration, without its `;`, or `nil` (and no tokens used) if this isn't one.
    private mutating func localDeclaration(comments: [String], location: SourceLocation) throws(TranspileError) -> Statement? {
        if isIdentifier("const") { position += 1 }
        if isIdentifier("var"), peekKind(1) == .punctuation("(") {
            position += 2
            var names: [String] = []
            repeat {
                if isPunctuation(",") { position += 1 }
                names.append(try identifier())
            } while isPunctuation(",")
            try expect(")")
            try expect("=")
            return Statement(kind: .deconstruct(names: names, try expression()), comments: comments, location: location)
        }
        let start = position
        var declaredType: TypeSyntax?
        if isIdentifier("var"), case .identifier = peekKind(1) {
            position += 1
        } else {
            do {
                declaredType = try type()
            } catch {
                position = start
                return nil
            }
            guard case .identifier = current.kind,
                  [.punctuation("="), .punctuation(";"), .punctuation(",")].contains(peekKind(1)) else {
                position = start
                return nil
            }
        }
        var declarators: [(name: String, initializer: Expression?)] = []
        repeat {
            if isPunctuation(",") { position += 1 }
            let name = try identifier()
            var initializer: Expression?
            if isPunctuation("=") {
                position += 1
                initializer = try expression()
            }
            declarators.append((name, initializer))
        } while isPunctuation(",")
        return Statement(kind: .local(type: declaredType, declarators), comments: comments, location: location)
    }

    // MARK: Expressions

    mutating func expression() throws(TranspileError) -> Expression {
        if let lambda = try lambda() { return lambda }
        let target = try conditional()
        if case .punctuation(let op) = current.kind,
           ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "??="].contains(op) {
            position += 1
            let value = try expression()
            return Expression(kind: .assign(op, target, value), location: target.location)
        }
        return target
    }

    private mutating func lambda() throws(TranspileError) -> Expression? {
        let location = current.location
        var parameters: [String]?
        if case .identifier(let name) = current.kind, peekKind(1) == .punctuation("=>") {
            parameters = [name]
            position += 2
        } else if isPunctuation("(") {
            var i = position + 1
            var names: [String] = []
            var simple = true
            var typed = false
            var lastWasName = false
            while i < tokens.count {
                if tokens[i].kind == .punctuation(")") { break }
                if case .identifier(let name) = tokens[i].kind {
                    if lastWasName { typed = true }
                    names.append(name)
                    lastWasName = true
                } else if tokens[i].kind == .punctuation(",") {
                    lastWasName = false
                } else {
                    simple = false
                    break
                }
                i += 1
            }
            if simple, i + 1 < tokens.count, tokens[i + 1].kind == .punctuation("=>") {
                if typed { throw error("lambda parameters with types aren't supported") }
                parameters = names
                position = i + 2
            }
        }
        guard let parameters else { return nil }
        if isPunctuation("{") {
            return Expression(kind: .lambda(parameters, .block(try block())), location: location)
        }
        return Expression(kind: .lambda(parameters, .expression(try expression())), location: location)
    }

    private mutating func conditional() throws(TranspileError) -> Expression {
        let condition = try coalescing()
        guard isPunctuation("?") else { return condition }
        position += 1
        let then = try expression()
        try expect(":")
        let otherwise = try expression()
        return Expression(kind: .conditional(condition, then, otherwise), location: condition.location)
    }

    private mutating func coalescing() throws(TranspileError) -> Expression {
        let left = try binary(level: 0)
        guard isPunctuation("??") else { return left }
        position += 1
        let right = try coalescing()
        return Expression(kind: .binary("??", left, right), location: left.location)
    }

    private static let binaryLevels: [[String]] = [
        ["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="], ["<", ">", "<=", ">="], ["<<", ">>"], ["+", "-"], ["*", "/", "%"],
    ]

    private mutating func binary(level: Int) throws(TranspileError) -> Expression {
        guard level < Self.binaryLevels.count else { return try rangeExpression() }
        var left = try binary(level: level + 1)
        while true {
            if level == 6, isIdentifier("is") {
                position += 1
                left = Expression(kind: .is(left, try pattern()), location: left.location)
                continue
            }
            if level == 6, isIdentifier("as") { throw error("as casts aren't supported") }
            var op: String?
            if case .punctuation(let p) = current.kind, Self.binaryLevels[level].contains(p),
               !(p == ">" && peekKind(1) == .punctuation(">") && !tokens[min(position + 1, tokens.count - 1)].spaceBefore) {
                op = p
            } else if level == 7, isPunctuation(">"), peekKind(1) == .punctuation(">"), !tokens[position + 1].spaceBefore {
                op = ">>"
            }
            guard let op else { return left }
            position += op == ">>" && current.kind == .punctuation(">") ? 2 : 1
            let right = try binary(level: level + 1)
            left = Expression(kind: .binary(op, left, right), location: left.location)
        }
    }

    private mutating func rangeExpression() throws(TranspileError) -> Expression {
        let location = current.location
        if isPunctuation("..") {
            position += 1
            if isPunctuation("]") { return Expression(kind: .range(nil, nil), location: location) }
            return Expression(kind: .range(nil, try unary()), location: location)
        }
        let start = try unary()
        guard isPunctuation("..") else { return start }
        position += 1
        if isPunctuation("]") { return Expression(kind: .range(start, nil), location: location) }
        return Expression(kind: .range(start, try unary()), location: location)
    }

    private static let castableKeywords: Set<String> = ["int", "float", "double", "char", "byte", "uint", "long", "short", "ushort", "sbyte", "ulong", "bool", "string", "decimal"]

    private mutating func unary() throws(TranspileError) -> Expression {
        let location = current.location
        if case .punctuation(let op) = current.kind, ["!", "-", "+", "~", "++", "--", "^"].contains(op) {
            position += 1
            let operand = try unary()
            if op == "^" { return Expression(kind: .fromEnd(operand), location: location) }
            return Expression(kind: .unary(op, operand), location: location)
        }
        if isPunctuation("&") || isPunctuation("*") { throw error("pointers aren't supported") }
        if isIdentifier("await") { throw error("async code isn't supported") }
        if isPunctuation("("), let cast = try castExpression() { return cast }
        return try postfix(try primary())
    }

    private mutating func castExpression() throws(TranspileError) -> Expression? {
        let start = position
        let location = current.location
        position += 1
        let target: TypeSyntax
        do {
            target = try type()
        } catch {
            position = start
            return nil
        }
        guard isPunctuation(")") else {
            position = start
            return nil
        }
        position += 1
        let isKeyword = target.name.map(Self.castableKeywords.contains) ?? false
        let startsOperand: Bool
        switch current.kind {
        case .identifier(let word): startsOperand = !["is", "as", "switch", "with", "and", "or"].contains(word)
        case .integer, .real, .string, .interpolated, .character: startsOperand = true
        case .punctuation(let p): startsOperand = p == "(" || p == "!" || p == "~" || (isKeyword && (p == "-" || p == "+"))
        case .end: startsOperand = false
        }
        guard startsOperand, isKeyword || target.name?.first?.isUppercase == true else {
            position = start
            return nil
        }
        return Expression(kind: .cast(target, try unary()), location: location)
    }

    private mutating func postfix(_ base: Expression) throws(TranspileError) -> Expression {
        var result = base
        while true {
            let location = result.location
            if isPunctuation(".") || isPunctuation("?.") {
                let nullConditional = isPunctuation("?.")
                position += 1
                let name = try identifier()
                if isPunctuation("<"), looksLikeGenericCall() { throw error("generic method calls aren't supported") }
                result = Expression(kind: .member(result, name, nullConditional: nullConditional), location: location)
            } else if isPunctuation("(") {
                result = Expression(kind: .call(result, try arguments(closing: ")")), location: location)
            } else if isPunctuation("[") || isPunctuation("?[") {
                let nullConditional = isPunctuation("?[")
                position += 1
                var indices: [Expression] = []
                while !isPunctuation("]") {
                    indices.append(try expression())
                    if isPunctuation(",") { position += 1 }
                }
                try expect("]")
                result = Expression(kind: .index(result, indices, nullConditional: nullConditional), location: location)
            } else if isPunctuation("++") || isPunctuation("--"), case .punctuation(let op) = current.kind {
                position += 1
                result = Expression(kind: .postfix(op, result), location: location)
            } else if isPunctuation("!"), !current.spaceBefore {
                position += 1
                result = Expression(kind: .postfix("!", result), location: location)
            } else if isIdentifier("switch"), peekKind(1) == .punctuation("{") {
                position += 2
                var arms: [(Pattern?, Expression)] = []
                while !isPunctuation("}") {
                    var pattern: Pattern?
                    if isIdentifier("_") {
                        position += 1
                    } else {
                        pattern = try self.pattern()
                    }
                    if isIdentifier("when") { throw error("switch arm guards (when) aren't supported") }
                    try expect("=>")
                    arms.append((pattern, try expression()))
                    if isPunctuation(",") { position += 1 }
                }
                try expect("}")
                result = Expression(kind: .switchExpression(result, arms), location: location)
            } else if isIdentifier("with"), peekKind(1) == .punctuation("{") {
                position += 1
                result = Expression(kind: .with(result, try initializerList()), location: location)
            } else {
                return result
            }
        }
    }

    private func looksLikeGenericCall() -> Bool {
        var i = position + 1
        var depth = 1
        while i < tokens.count, depth > 0 {
            switch tokens[i].kind {
            case .punctuation("<"): depth += 1
            case .punctuation(">"): depth -= 1
            case .identifier, .punctuation(","), .punctuation("."), .punctuation("?"), .punctuation("["), .punctuation("]"): break
            default: return false
            }
            i += 1
        }
        return depth == 0 && i < tokens.count && tokens[i].kind == .punctuation("(")
    }

    private mutating func arguments(closing: String) throws(TranspileError) -> [Argument] {
        position += 1
        var result: [Argument] = []
        while !isPunctuation(closing) {
            var name: String?
            if case .identifier(let label) = current.kind, peekKind(1) == .punctuation(":") {
                name = label
                position += 2
            }
            var modifier: String?
            if case .identifier(let word) = current.kind, ["ref", "out", "in"].contains(word) {
                modifier = word
                position += 1
                if word == "out", isIdentifier("var") || isIdentifier("_") {
                    throw error("out variable declarations aren't supported")
                }
            }
            result.append(Argument(name: name, modifier: modifier, value: try expression()))
            if isPunctuation(",") { position += 1 } else { break }
        }
        try expect(closing)
        return result
    }

    private mutating func initializerList() throws(TranspileError) -> [(String, Expression)] {
        try expect("{")
        var result: [(String, Expression)] = []
        while !isPunctuation("}") {
            let name = try identifier()
            try expect("=")
            result.append((name, try expression()))
            if isPunctuation(",") { position += 1 } else { break }
        }
        try expect("}")
        return result
    }

    private mutating func primary() throws(TranspileError) -> Expression {
        let token = current
        let location = token.location
        func make(_ kind: Expression.Kind) -> Expression { Expression(kind: kind, location: location) }
        switch token.kind {
        case .integer(let text):
            position += 1
            return make(.integer(text))
        case .real(let text):
            position += 1
            return make(.real(text))
        case .string(let text):
            position += 1
            return make(.string(text))
        case .character(let text):
            position += 1
            return make(.character(text))
        case .interpolated(let parts):
            position += 1
            var parsed: [InterpolatedPart] = []
            for part in parts {
                switch part {
                case .text(let text): parsed.append(.text(text))
                case .hole(let source, let holeLocation):
                    var lexer = Lexer(source, startingAt: holeLocation)
                    var parser = Parser(tokens: try lexer.tokenize(), path: path)
                    let value = try parser.expression()
                    guard parser.atEnd else { throw TranspileError(holeLocation, "couldn't read the interpolation hole") }
                    parsed.append(.hole(value))
                }
            }
            return make(.interpolated(parsed))
        case .punctuation("("):
            position += 1
            let first = try expression()
            if isPunctuation(",") {
                var elements = [first]
                while isPunctuation(",") {
                    position += 1
                    elements.append(try expression())
                }
                try expect(")")
                return make(.tuple(elements))
            }
            try expect(")")
            return make(.parenthesized(first))
        case .punctuation("["):
            position += 1
            var elements: [Expression] = []
            while !isPunctuation("]") {
                if isPunctuation("..") { throw error("spread elements aren't supported") }
                elements.append(try expression())
                if isPunctuation(",") { position += 1 } else { break }
            }
            try expect("]")
            return make(.collection(elements))
        case .identifier(let word):
            switch word {
            case "true", "false":
                position += 1
                return make(.boolean(word == "true"))
            case "null":
                position += 1
                return make(.null)
            case "this":
                position += 1
                return make(.this)
            case "base": throw error("base isn't supported")
            case "typeof", "sizeof", "stackalloc", "checked", "unchecked", "throw":
                throw error("\(word) expressions aren't supported")
            case "default":
                position += 1
                if isPunctuation("(") {
                    position += 1
                    let target = try type()
                    try expect(")")
                    return make(.default(target))
                }
                return make(.default(nil))
            case "nameof":
                position += 1
                try expect("(")
                var name = try identifier()
                while isPunctuation(".") {
                    position += 1
                    name = try identifier()
                }
                try expect(")")
                return make(.nameof(name))
            case "new":
                position += 1
                return try newExpression(location)
            default:
                if Self.castableKeywords.contains(word) || word == "object" {
                    position += 1
                    return make(.typeName(word))
                }
                position += 1
                if isPunctuation("<"), looksLikeGenericCall() { throw error("generic method calls aren't supported") }
                return make(.name(word))
            }
        default:
            throw error("expected an expression")
        }
    }

    private mutating func newExpression(_ location: SourceLocation) throws(TranspileError) -> Expression {
        if isPunctuation("[") {
            position += 1
            try expect("]")
            let elements = try collectionInitializer()
            return Expression(kind: .collection(elements), location: location)
        }
        var target: TypeSyntax?
        if !isPunctuation("(") && !isPunctuation("{") {
            target = try type()
            if case .array = target {
                return Expression(kind: .collection(try collectionInitializer()), location: location)
            }
            if isPunctuation("[") { throw error("arrays created by size aren't supported") }
        }
        var arguments: [Argument] = []
        if isPunctuation("(") {
            arguments = try self.arguments(closing: ")")
        }
        var initializers: [(String, Expression)]?
        if isPunctuation("{") {
            if case .identifier = peekKind(1), peekKind(2) == .punctuation("=") {
                initializers = try initializerList()
            } else if peekKind(1) == .punctuation("}") {
                position += 2
                initializers = []
            } else {
                throw error("collection initializers aren't supported; use a collection expression")
            }
        }
        return Expression(kind: .new(target, arguments, initializers: initializers), location: location)
    }

    private mutating func collectionInitializer() throws(TranspileError) -> [Expression] {
        try expect("{")
        var elements: [Expression] = []
        while !isPunctuation("}") {
            elements.append(try expression())
            if isPunctuation(",") { position += 1 } else { break }
        }
        try expect("}")
        return elements
    }

    private mutating func pattern() throws(TranspileError) -> Pattern {
        var left = try primaryPattern()
        while true {
            if isIdentifier("and") {
                position += 1
                left = .and(left, try primaryPattern())
            } else if isIdentifier("or") {
                position += 1
                left = .or(left, try primaryPattern())
            } else {
                return left
            }
        }
    }

    private mutating func primaryPattern() throws(TranspileError) -> Pattern {
        if isIdentifier("not") {
            position += 1
            return .not(try primaryPattern())
        }
        if isIdentifier("null") {
            position += 1
            return .null
        }
        if isPunctuation("{") {
            guard peekKind(1) == .punctuation("}") else { throw error("property patterns aren't supported") }
            position += 2
            if case .identifier(let name) = current.kind, !["and", "or", "when"].contains(name) {
                position += 1
                return .binding(name)
            }
            return .notNull
        }
        if case .punctuation(let op) = current.kind, ["<", ">", "<=", ">="].contains(op) {
            position += 1
            return .relational(op, try binary(level: 7))
        }
        if case .identifier(let word) = current.kind, word.first?.isUppercase == true || Self.castableKeywords.contains(word),
           case .identifier = peekKind(1) {
            throw error("type patterns aren't supported")
        }
        return .constant(try binary(level: 7))
    }

    // MARK: Tokens

    var atEnd: Bool { current.kind == .end }

    private var current: Token { tokens[min(position, tokens.count - 1)] }

    private func peekKind(_ offset: Int) -> Token.Kind {
        tokens[min(position + offset, tokens.count - 1)].kind
    }

    private func isPunctuation(_ text: String) -> Bool { current.kind == .punctuation(text) }

    private func isIdentifier(_ text: String, _ offset: Int = 0) -> Bool { peekKind(offset) == .identifier(text) }

    private mutating func identifier() throws(TranspileError) -> String {
        guard case .identifier(let name) = current.kind else { throw error("expected a name") }
        position += 1
        return name
    }

    private mutating func expect(_ text: String) throws(TranspileError) {
        guard isPunctuation(text) else { throw error("expected '\(text)'") }
        position += 1
    }

    private mutating func advanceOrFail() throws(TranspileError) {
        guard !atEnd else { throw error("unexpected end of file") }
        position += 1
    }

    private func error(_ message: String) -> TranspileError {
        TranspileError(current.location, message)
    }
}
