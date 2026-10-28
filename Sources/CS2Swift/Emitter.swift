import Foundation

/// A note about a translation that compiles but may not behave exactly as the C# did.
public struct Warning: Equatable, Sendable, CustomStringConvertible {
    /// Where in the source file.
    public var location: SourceLocation
    /// What to check.
    public var message: String

    public var description: String { "\(location): warning: \(message)" }
}

/// Writes Swift for one parsed C# file, using what the symbol table knows about every file.
final class Emitter {
    let symbols: SymbolTable
    private(set) var warnings: [Warning] = []
    private var output = ""

    /// The types being emitted, innermost last.
    var typeStack: [TypeInfo] = []
    /// Local names in scope, innermost last, with their C# types.
    var scopes: [[String: CType]] = []
    /// Whether the code being emitted runs without an instance.
    var isStaticContext = false
    /// How many lambdas enclose the code being emitted.
    var lambdaDepth = 0
    /// Inside a property setter, C#'s `value` is Swift's `newValue`.
    var inSetter = false
    /// The current method's result, for `return new()` and `return default`.
    var returnType: CType = .void
    /// Locals the current method assigns to after declaring them.
    var reassigned: Set<String> = []
    /// Locals the current method changes through a member (`a.X = 1`) or a mutating call.
    var mutatedThrough: Set<String> = []
    /// Nullable names and members a null check has proven non-null here (`x` after
    /// `x is null ||`), written as C# paths such as `_stroke` or `bounds.Value`.
    var narrowed: Set<String> = []

    init(symbols: SymbolTable) {
        self.symbols = symbols
    }

    /// The type a declaration names, with nested types spelled with their enclosing types
    /// (`Action` inside WindowFrame is `WindowFrame.Action`), as Swift can't always find them.
    func ctype(_ syntax: TypeSyntax) -> CType {
        resolved(CType(syntax))
    }

    func resolved(_ type: CType) -> CType {
        switch type {
        case .named(let name) where !name.contains("."):
            for info in typeStack.reversed() {
                if let member = info.members[name]?.first, member.kind == .type, case .typeReference(let qualified) = member.type {
                    return .named(qualified)
                }
            }
            if name == "Action", symbols.type(named: name) == nil { return .function([], .void) }
            return type
        case .nullable(let inner): return .nullable(resolved(inner))
        case .list(let inner): return .list(resolved(inner))
        case .function(let parameters, let result): return .function(parameters.map(resolved), resolved(result))
        case .tuple(let elements): return .tuple(elements.map(resolved))
        default: return type
        }
    }

    func warn(_ location: SourceLocation, _ message: String) {
        warnings.append(Warning(location: location, message: message))
    }

    // MARK: Files and types

    func emit(_ file: SourceFile, header: String) throws(TranspileError) -> String {
        output = header
        output += "import Foundation\nimport Raylib\n"
        for type in file.types {
            output += "\n"
            try emitType(type, indent: "")
        }
        return output
    }

    private func line(_ indent: String, _ text: String) {
        output += indent + text + "\n"
    }

    private func emitComments(_ comments: [String], indent: String) {
        for comment in Comments.translate(comments) {
            line(indent, comment)
        }
    }

    private func access(_ modifiers: Set<String>, location: SourceLocation) -> String {
        if modifiers.contains("public") { return "public " }
        if modifiers.contains("private") { return "private " }
        if modifiers.contains("protected") {
            warn(location, "protected has no Swift equivalent; the member is internal")
        }
        return ""
    }

    private func emitType(_ declaration: TypeDeclaration, indent: String) throws(TranspileError) {
        let qualified = (typeStack.last.map { "\($0.qualifiedName)." } ?? "") + declaration.name
        guard let info = symbols.type(named: qualified) else {
            throw TranspileError(declaration.location, "internal error: no symbols for \(qualified)")
        }
        emitComments(declaration.comments, indent: indent)
        if typeStack.isEmpty, RaylibData.structs[declaration.name] != nil || RaylibData.aliases[declaration.name] != nil {
            warn(declaration.location, "\(declaration.name) shares its name with raylib's; code that imports both must qualify it with this module's name")
        }
        let access = access(declaration.modifiers, location: declaration.location)
        let bases = declaration.bases.compactMap(\.name).filter { symbols.type(named: $0)?.kind == .interface }
        for base in declaration.bases where base.name.map({ symbols.type(named: $0)?.kind != .interface }) ?? true {
            if declaration.kind != .enum {
                throw TranspileError(declaration.location, "inheriting from \(base.name ?? "a type") isn't supported; only interfaces")
            }
        }
        let conformances = bases.isEmpty ? "" : ": " + bases.joined(separator: ", ")

        typeStack.append(info)
        defer { typeStack.removeLast() }

        switch declaration.kind {
        case .enum:
            if declaration.attributes.contains("Flags") {
                throw TranspileError(declaration.location, "[Flags] enums aren't supported yet")
            }
            line(indent, "\(access)enum \(declaration.name): Int {")
            for enumCase in declaration.enumCases {
                emitComments(enumCase.comments, indent: indent + "    ")
                let name = Naming.lowerCamel(enumCase.name)
                if let value = enumCase.value {
                    line(indent + "    ", "case \(name) = \(try expression(value, expected: .int).code)")
                } else {
                    line(indent + "    ", "case \(name)")
                }
            }
            line(indent, "}")
            return
        case .interface:
            line(indent, "\(access)protocol \(declaration.name)\(conformances) {")
        case .struct:
            line(indent, "\(access)struct \(declaration.name)\(conformances) {")
        case .class:
            if declaration.modifiers.contains("static") {
                line(indent, "\(access)enum \(declaration.name) {")
            } else if declaration.modifiers.contains("abstract") {
                throw TranspileError(declaration.location, "abstract classes aren't supported")
            } else {
                let final = declaration.modifiers.contains("sealed") ? "final " : ""
                line(indent, "\(access)\(final)class \(declaration.name)\(conformances) {")
            }
        }

        var first = true
        for member in declaration.members {
            if !first { output += "\n" }
            first = false
            try emitMember(member, in: declaration, indent: indent + "    ")
        }
        // C# gives a class without constructors a public one; Swift's implicit init is
        // internal, so other modules couldn't create it.
        let hasConstructor = declaration.members.contains { if case .constructor = $0 { true } else { false } }
        if declaration.kind == .class, !declaration.modifiers.contains("static"), access == "public ", !hasConstructor {
            if !first { output += "\n" }
            line(indent + "    ", "public init() {}")
        }
        line(indent, "}")
    }

    private func memberInfo(_ name: String) -> MemberInfo? {
        typeStack.last?.members[name]?.first
    }

    private func emitMember(_ member: Member, in type: TypeDeclaration, indent: String) throws(TranspileError) {
        let isInterface = type.kind == .interface
        switch member {
        case .type(let nested):
            try emitType(nested, indent: indent)

        case .field(let field):
            emitComments(field.comments, indent: indent)
            let isConstant = field.modifiers.contains("const")
            let isStatic = isConstant || field.modifiers.contains("static") || type.modifiers.contains("static")
            let fieldType = ctype(field.type)
            for declarator in field.declarators {
                let swiftName = memberInfo(declarator.name)?.swiftName ?? Naming.lowerCamel(declarator.name)
                let readOnly = isConstant || field.modifiers.contains("readonly")
                let keyword = readOnly && (isStatic || !Self.hasMutableContents(fieldType)) ? "let" : "var"
                var staticKeyword = isStatic ? "static " : ""
                if isStatic && keyword == "var" {
                    staticKeyword = "nonisolated(unsafe) static "
                    warn(field.location, "a mutable static isn't safe across threads in Swift 6; it's marked nonisolated(unsafe)")
                }
                var text = access(field.modifiers, location: field.location) + staticKeyword + "\(keyword) \(swiftName): \(fieldType.swift)"
                isStaticContext = isStatic
                if let initializer = declarator.initializer {
                    text += " = " + (try expression(initializer, expected: fieldType)).code
                } else if keyword == "var", let zero = zeroValue(fieldType) {
                    text += " = " + zero
                }
                line(indent, text)
            }

        case .property(let property):
            emitComments(property.comments, indent: indent)
            let propertyType = ctype(property.type)
            let isStatic = property.modifiers.contains("static") || type.modifiers.contains("static")
            isStaticContext = isStatic
            let swiftName = memberInfo(property.name)?.swiftName ?? Naming.lowerCamel(property.name)
            let access = access(property.modifiers, location: property.location)
            let prefix = access + (isStatic ? "static " : "")
            if isInterface {
                line(indent, "var \(swiftName): \(propertyType.swift) { get\(property.setter == nil ? "" : " set") }")
                return
            }
            let getterIsAutomatic: Bool
            if case .automatic = property.getter?.body { getterIsAutomatic = true } else { getterIsAutomatic = false }
            if getterIsAutomatic {
                var keyword = "var"
                var setterAccess = ""
                if let setter = property.setter {
                    if setter.modifiers.contains("private") { setterAccess = "private(set) " }
                    if setter.isInit { keyword = "let" }
                } else if Self.hasMutableContents(propertyType) {
                    setterAccess = "private(set) "
                } else {
                    keyword = "let"
                }
                var text = prefix + setterAccess + "\(keyword) \(swiftName): \(propertyType.swift)"
                if let initializer = property.initializer {
                    text += " = " + (try expression(initializer, expected: propertyType)).code
                } else if keyword == "var", let zero = zeroValue(propertyType) {
                    text += " = " + zero
                }
                line(indent, text)
                return
            }
            line(indent, prefix + "var \(swiftName): \(propertyType.swift) {")
            if property.setter == nil, case .expression(let value) = property.getter?.body {
                try emitBody(.expression(value), parameters: [], result: propertyType, indent: indent + "    ")
            } else {
                if let getter = property.getter {
                    line(indent + "    ", "get {")
                    try emitBody(accessorBody(getter), parameters: [], result: propertyType, indent: indent + "        ")
                    line(indent + "    ", "}")
                }
                if let setter = property.setter {
                    let setterAccess = setter.modifiers.contains("private") ? "private " : ""
                    line(indent + "    ", "\(setterAccess)set {")
                    inSetter = true
                    try emitBody(accessorBody(setter), parameters: [("value", propertyType)], result: .void, indent: indent + "        ")
                    inSetter = false
                    line(indent + "    ", "}")
                }
            }
            line(indent, "}")

        case .method(let method), .constructor(let method):
            emitComments(method.comments, indent: indent)
            let isConstructor: Bool
            if case .constructor = member { isConstructor = true } else { isConstructor = false }
            let isStatic = method.modifiers.contains("static") || type.modifiers.contains("static")
            isStaticContext = isStatic
            var parameters: [String] = []
            var scope: [(String, CType)] = []
            for parameter in method.parameters {
                if let modifier = parameter.modifier, modifier != "in" {
                    throw TranspileError(method.location, "\(modifier) parameters aren't supported")
                }
                let parameterType = ctype(parameter.type)
                var spelled = parameterType.swift
                if case .function = parameterType { spelled = "@escaping " + spelled }
                var text = "_ \(Naming.escaped(parameter.name)): \(spelled)"
                if let defaultValue = parameter.defaultValue {
                    text += " = " + (try expression(inlinedConstant(defaultValue), expected: parameterType)).code
                }
                parameters.append(text)
                scope.append((parameter.name, parameterType))
            }
            let result = method.returnType.map(ctype) ?? .void
            let signature: String
            if isConstructor {
                signature = access(method.modifiers, location: method.location) + "init(\(parameters.joined(separator: ", ")))"
            } else {
                let name = memberInfo(method.name)?.swiftName ?? Naming.lowerCamel(method.name)
                let arrow = result == .void ? "" : " -> \(result.swift)"
                signature = (isInterface ? "" : access(method.modifiers, location: method.location)) + (isStatic ? "static " : "") + "func \(name)(\(parameters.joined(separator: ", ")))\(arrow)"
            }
            if case .none = method.body {
                guard isInterface else { throw TranspileError(method.location, "methods without bodies are only supported in interfaces") }
                line(indent, signature)
                return
            }
            line(indent, signature + " {")
            let body: BodyKind
            switch method.body {
            case .expression(let value): body = .expression(value)
            case .block(let statements): body = .block(statements)
            case .none: body = .block([])
            }
            if isConstructor, case .block(let statements) = method.body {
                checkInitialization(statements, in: type, parameters: Set(method.parameters.map(\.name)))
            }
            try emitBody(body, parameters: scope, result: result, indent: indent + "    ")
            line(indent, "}")
        }
    }

    /// Swift doesn't let a constructor use the object (call a method, read a property, or
    /// hand off a method) until every stored property has a value, which C# allows.
    private func checkInitialization(_ statements: [Statement], in type: TypeDeclaration, parameters: Set<String>) {
        var unset: Set<String> = []
        for member in type.members {
            if case .field(let field) = member, !field.modifiers.contains("static"), !field.modifiers.contains("const") {
                let isLet = field.modifiers.contains("readonly") && !Self.hasMutableContents(ctype(field.type))
                for declarator in field.declarators where declarator.initializer == nil {
                    if isLet || zeroValue(ctype(field.type)) == nil { unset.insert(declarator.name) }
                }
            }
            if case .property(let property) = member, !property.modifiers.contains("static"), property.initializer == nil,
               case .automatic? = property.getter?.body, property.setter == nil || property.setter?.isInit == true {
                unset.insert(property.name)
            }
        }
        guard let info = typeStack.last else { return }
        for statement in statements {
            guard !unset.isEmpty else { return }
            var assigned: String?
            var read: Set<String>
            if case .expression(let value) = statement.kind, case .assign("=", let target, let source) = value.unwrapped.kind,
               let key = NullChecks.key(target), unset.contains(key) {
                assigned = key
                read = Mutations.names(in: source)
            } else {
                read = Mutations.names(in: statement)
            }
            let used = read.subtracting(parameters).filter { name in
                guard let member = info.members[name]?.first else { return false }
                return !member.isStatic && (member.kind == .method || member.kind == .property || unset.contains(name))
            }
            if !used.isEmpty {
                warn(statement.location, "Swift won't let this constructor use \(used.sorted().joined(separator: ", ")) before \(unset.sorted().joined(separator: ", ")) \(unset.count == 1 ? "has a value" : "have values"); reorder or restructure the C#")
                return
            }
            if let assigned { unset.remove(assigned) }
        }
    }

    /// Lists and text builders are references in C#, so a `readonly` one can still change;
    /// in Swift they're values and need `var`.
    static func hasMutableContents(_ type: CType) -> Bool {
        switch type {
        case .list, .stringBuilder: true
        default: false
        }
    }

    enum BodyKind {
        case expression(Expression)
        case block([Statement])
    }

    private func accessorBody(_ accessor: Accessor) -> BodyKind {
        switch accessor.body {
        case .automatic: .block([])
        case .expression(let value): .expression(value)
        case .block(let statements): .block(statements)
        }
    }

    private func emitBody(_ body: BodyKind, parameters: [(String, CType)], result: CType, indent: String) throws(TranspileError) {
        let savedReturn = returnType
        let savedReassigned = reassigned
        let savedMutated = mutatedThrough
        returnType = result
        scopes.append(Dictionary(parameters, uniquingKeysWith: { $1 }))
        defer {
            scopes.removeLast()
            returnType = savedReturn
            reassigned = savedReassigned
            mutatedThrough = savedMutated
        }
        switch body {
        case .expression(let value):
            let analysis = Mutations(expression: value)
            reassigned = analysis.reassigned
            mutatedThrough = analysis.mutatedThrough
            line(indent, try expression(value, expected: result == .void ? nil : result).code)
        case .block(let statements):
            let analysis = Mutations(statements: statements)
            reassigned = analysis.reassigned
            mutatedThrough = analysis.mutatedThrough
            try emitStatements(statements, indent: indent)
        }
    }

    // MARK: Statements

    func emitStatements(_ statements: [Statement], indent: String) throws(TranspileError) {
        let saved = narrowed
        defer { narrowed = saved }
        for statement in statements {
            try emitStatement(statement, indent: indent)
            // `if (x is null) return;` proves x non-null for the rest of the block.
            if case .if(let condition, let then, nil) = statement.kind, Self.alwaysExits(then) {
                narrowed.formUnion(NullChecks.disjuncts(condition).compactMap { $0.isNull ? $0.key : nil })
            }
        }
    }

    private static func alwaysExits(_ statement: Statement) -> Bool {
        switch statement.kind {
        case .return, .break, .continue: true
        case .block(let statements): statements.last(where: { if case .empty = $0.kind { false } else { true } }).map(alwaysExits) ?? false
        default: false
        }
    }

    private func emitBlock(_ statement: Statement, indent: String) throws(TranspileError) {
        scopes.append([:])
        defer { scopes.removeLast() }
        if case .block(let statements) = statement.kind {
            try emitStatements(statements, indent: indent)
        } else {
            try emitStatement(statement, indent: indent)
        }
    }

    func declare(_ name: String, _ type: CType) {
        scopes[scopes.count - 1][name] = type
    }

    func local(_ name: String) -> CType? {
        for scope in scopes.reversed() {
            if let type = scope[name] { return type }
        }
        return nil
    }

    private func isReferenceType(_ type: CType) -> Bool {
        if case .named(let name) = type, let info = symbols.type(named: name) { return info.kind == .class }
        return false
    }

    private func emitStatement(_ statement: Statement, indent: String) throws(TranspileError) {
        emitComments(statement.comments, indent: indent)
        switch statement.kind {
        case .empty:
            break
        case .block(let statements):
            line(indent, "do {")
            scopes.append([:])
            try emitStatements(statements, indent: indent + "    ")
            scopes.removeLast()
            line(indent, "}")
        case .local(let declared, let declarators):
            for declarator in declarators {
                let declaredType = declared.map(ctype)
                var code = ""
                var type = declaredType ?? .unknown
                if let initializer = declarator.initializer {
                    let value = try expression(initializer, expected: declaredType)
                    code = value.code
                    if declaredType == nil { type = value.type }
                }
                let mutable = reassigned.contains(declarator.name) || (mutatedThrough.contains(declarator.name) && !isReferenceType(type))
                    || declarator.initializer == nil
                var text = (mutable ? "var " : "let ") + Naming.escaped(declarator.name)
                let needsAnnotation = declaredType != nil || (declarator.initializer.map(isLiteralOnly) ?? false) && type.isFloatingPoint
                if needsAnnotation, type != .unknown { text += ": " + type.swift }
                if !code.isEmpty { text += " = " + code }
                declare(declarator.name, type)
                line(indent, text)
            }
        case .deconstruct(let names, let value):
            let emitted = try expression(value, expected: nil)
            let mutable = names.contains { reassigned.contains($0) }
            line(indent, (mutable ? "var " : "let ") + "(\(names.map(Naming.escaped).joined(separator: ", "))) = \(emitted.code)")
            if case .tuple(let types) = emitted.type, types.count == names.count {
                for (name, type) in zip(names, types) { declare(name, type) }
            } else {
                for name in names { declare(name, .unknown) }
            }
        case .expression(let value):
            let code = try statementExpression(value)
            if !code.isEmpty { line(indent, code) }
        case .if:
            output += indent
            try emitChainedIf(statement, indent: indent)
        case .while(let condition, let body):
            line(indent, "while \(try expression(condition, expected: .bool).code) {")
            try emitBlock(body, indent: indent + "    ")
            line(indent, "}")
        case .doWhile(let body, let condition):
            line(indent, "repeat {")
            try emitBlock(body, indent: indent + "    ")
            line(indent, "} while \(try expression(condition, expected: .bool).code)")
        case .for(let initializers, let condition, let increments, let body):
            try emitFor(initializers: initializers, condition: condition, increments: increments, body: body, location: statement.location, indent: indent)
        case .foreach(let name, let sequence, let body):
            let emitted = try expression(sequence, expected: nil)
            var element = CType.unknown
            switch emitted.type.nonNullable {
            case .list(let inner): element = inner
            case .string, .stringBuilder: element = .char
            default: break
            }
            line(indent, "for \(Naming.escaped(name)) in \(emitted.code) {")
            scopes.append([name: element])
            try emitBlock(body, indent: indent + "    ")
            scopes.removeLast()
            line(indent, "}")
        case .switch(let subject, let sections):
            try emitSwitch(subject, sections, indent: indent)
        case .return(let value):
            if let value {
                line(indent, "return " + (try expression(value, expected: returnType == .void ? nil : returnType)).code)
            } else {
                line(indent, "return")
            }
        case .break:
            line(indent, "break")
        case .continue:
            line(indent, "continue")
        }
    }

    /// Writes `else if` chains without nesting each `if` one level deeper.
    private func emitChainedIf(_ statement: Statement, indent: String) throws(TranspileError) {
        guard case .if(let condition, let then, let otherwise) = statement.kind else { return }
        var clauses: [String] = []
        var bindings: [(String, CType)] = []
        let saved = narrowed
        for conjunct in NullChecks.conjuncts(condition) {
            if case .is(let subject, .binding(let name)) = conjunct.unwrapped.kind {
                let value = try expression(subject, expected: nil)
                clauses.append("let \(Naming.escaped(name)) = \(value.code)")
                bindings.append((name, value.type.nonNullable))
            } else {
                scopes.append(Dictionary(bindings, uniquingKeysWith: { $1 }))
                clauses.append(try expression(conjunct, expected: .bool).code)
                scopes.removeLast()
            }
            if let check = NullChecks.check(conjunct), !check.isNull { narrowed.insert(check.key) }
        }
        output += "if \(clauses.joined(separator: ", ")) {\n"
        scopes.append(Dictionary(bindings, uniquingKeysWith: { $1 }))
        try emitBlock(then, indent: indent + "    ")
        scopes.removeLast()
        narrowed = saved
        narrowed.formUnion(NullChecks.disjuncts(condition).compactMap { $0.isNull ? $0.key : nil })
        defer { narrowed = saved }
        if let otherwise, case .if = otherwise.kind, otherwise.comments.isEmpty {
            output += indent + "} else "
            try emitChainedIf(otherwise, indent: indent)
        } else if let otherwise {
            line(indent, "} else {")
            try emitBlock(otherwise, indent: indent + "    ")
            line(indent, "}")
        } else {
            line(indent, "}")
        }
    }

    private func emitSwitch(_ subject: Expression, _ sections: [SwitchSection], indent: String) throws(TranspileError) {
        let emitted = try expression(subject, expected: nil)
        line(indent, "switch \(emitted.code) {")
        var hasDefault = false
        var covered: Set<String> = []
        for section in sections {
            var labels: [String] = []
            var isDefault = false
            for label in section.labels {
                if let label {
                    let value = try expression(label, expected: emitted.type)
                    labels.append(value.code)
                    if case .member(_, let name, _) = label.unwrapped.kind { covered.insert(name) }
                } else {
                    isDefault = true
                }
            }
            if isDefault {
                hasDefault = true
                line(indent, "default:")
            } else {
                line(indent, "case \(labels.joined(separator: ", ")):")
            }
            var body = section.body
            if case .break? = body.last?.kind { body.removeLast() }
            if body.contains(where: { if case .break = $0.kind { return true } else { return false } }) {
                throw TranspileError(subject.location, "break before the end of a case isn't supported")
            }
            scopes.append([:])
            if body.allSatisfy({ if case .empty = $0.kind { return true } else { return false } }) {
                emitComments(body.flatMap(\.comments), indent: indent + "    ")
                line(indent + "    ", "break")
            } else {
                try emitStatements(body, indent: indent + "    ")
            }
            scopes.removeLast()
        }
        var exhaustive = false
        if case .named(let name) = emitted.type, let info = symbols.type(named: name), info.kind == .enum {
            let cases = info.members.values.flatMap { $0 }.filter { $0.kind == .enumCase }.map(\.name)
            exhaustive = Set(cases).isSubset(of: covered)
        }
        if !hasDefault && !exhaustive {
            line(indent, "default:")
            line(indent + "    ", "break")
        }
        line(indent, "}")
    }

    private func emitFor(
        initializers: [Statement], condition: Expression?, increments: [Expression], body: Statement,
        location: SourceLocation, indent: String
    ) throws(TranspileError) {
        // The usual counting loop becomes a stride, which never traps whatever its bounds.
        if initializers.count == 1, case .local(_, let declarators) = initializers[0].kind, declarators.count == 1,
           let start = declarators[0].initializer, let condition, increments.count == 1,
           case .binary(let comparison, let left, let bound) = condition.unwrapped.kind,
           case .name(let counter) = left.unwrapped.kind, counter == declarators[0].name,
           let step = Self.step(of: increments[0], counter: counter),
           !Mutations(statements: [body]).reassigned.contains(counter) {
            let boundNames = Mutations.names(in: bound)
            let bodyChanges = Mutations(statements: [body])
            if boundNames.isDisjoint(with: bodyChanges.reassigned.union(bodyChanges.mutatedThrough)) {
                let startCode = try expression(start, expected: .int)
                let boundCode = try expression(bound, expected: .int)
                if startCode.type == .int || startCode.type == .unknown, boundCode.type == .int || boundCode.type == .unknown {
                    var sequence: String?
                    switch (comparison, step > 0) {
                    case ("<", true):
                        if case .integer("0") = start.unwrapped.kind, step == 1, Self.isCount(bound) {
                            sequence = "0..<\(boundCode.code)"
                        } else {
                            sequence = "stride(from: \(startCode.code), to: \(boundCode.code), by: \(step))"
                        }
                    case ("<=", true): sequence = "stride(from: \(startCode.code), through: \(boundCode.code), by: \(step))"
                    case (">", false): sequence = "stride(from: \(startCode.code), to: \(boundCode.code), by: \(step))"
                    case (">=", false): sequence = "stride(from: \(startCode.code), through: \(boundCode.code), by: \(step))"
                    default: break
                    }
                    if let sequence {
                        line(indent, "for \(Naming.escaped(counter)) in \(sequence) {")
                        scopes.append([counter: .int])
                        try emitBlock(body, indent: indent + "    ")
                        scopes.removeLast()
                        line(indent, "}")
                        return
                    }
                }
            }
        }

        // Anything else becomes a while loop. The increments go in a defer, so `continue`
        // still runs them, as it does in C#.
        line(indent, "do {")
        scopes.append([:])
        let inner = indent + "    "
        for initializer in initializers {
            if case .local(let declared, let declarators) = initializer.kind {
                for declarator in declarators {
                    var text = "var \(Naming.escaped(declarator.name))"
                    var type = declared.map(ctype) ?? .unknown
                    if let value = declarator.initializer {
                        let emitted = try expression(value, expected: declared.map(ctype))
                        if declared == nil { type = emitted.type }
                        if declared != nil { text += ": \(type.swift)" }
                        text += " = \(emitted.code)"
                    }
                    declare(declarator.name, type)
                    line(inner, text)
                }
            } else {
                try emitStatement(initializer, indent: inner)
            }
        }
        let conditionCode = try condition.map { (value) throws(TranspileError) in try expression(value, expected: .bool).code } ?? "true"
        line(inner, "while \(conditionCode) {")
        if !increments.isEmpty {
            line(inner + "    ", "defer {")
            for increment in increments {
                line(inner + "        ", try statementExpression(increment))
            }
            line(inner + "    ", "}")
        }
        try emitBlock(body, indent: inner + "    ")
        line(inner, "}")
        scopes.removeLast()
        line(indent, "}")
    }

    private static func step(of increment: Expression, counter: String) -> Int? {
        switch increment.unwrapped.kind {
        case .postfix(let op, let target), .unary(let op, let target):
            guard case .name(counter) = target.unwrapped.kind else { return nil }
            return op == "++" ? 1 : op == "--" ? -1 : nil
        case .assign(let op, let target, let value):
            guard case .name(counter) = target.unwrapped.kind, case .integer(let text) = value.unwrapped.kind, let amount = Int(text) else { return nil }
            return op == "+=" ? amount : op == "-=" ? -amount : nil
        default:
            return nil
        }
    }

    private static func isCount(_ bound: Expression) -> Bool {
        if case .member(_, let name, false) = bound.unwrapped.kind { return name == "Count" || name == "Length" }
        return false
    }

    /// An expression used as a statement: assignments, calls, and `++`/`--`.
    func statementExpression(_ value: Expression) throws(TranspileError) -> String {
        switch value.unwrapped.kind {
        case .postfix(let op, let target) where op == "++" || op == "--",
             .unary(let op, let target) where op == "++" || op == "--":
            let targetType = try expression(target, expected: nil).type
            if op == "--", case .member(let receiver, "Length", false) = target.unwrapped.kind {
                let builder = try expression(receiver, expected: nil)
                if builder.type == .stringBuilder { return "\(builder.code).removeLast()" }
            }
            if targetType != .int && targetType != .unknown && !targetType.isNumeric {
                throw TranspileError(value.location, "\(op) on this type isn't supported")
            }
            return "\(try expression(target, expected: nil).code) \(op == "++" ? "+=" : "-=") 1"
        case .call(let callee, let arguments):
            if let assertion = try assertion(callee, arguments, location: value.location) { return assertion }
            let emitted = try expression(value, expected: nil)
            return emitted.type == .void || emitted.type == .unknown ? emitted.code : "_ = \(emitted.code)"
        default:
            return try expression(value, expected: nil).code
        }
    }

    /// C#'s argument guards (`ArgumentOutOfRangeException.ThrowIfNegativeOrZero(x)`) become
    /// debug assertions, and null checks on values Swift can't make nil disappear.
    private func assertion(_ callee: Expression, _ arguments: [Argument], location: SourceLocation) throws(TranspileError) -> String? {
        guard case .member(let receiver, let method, false) = callee.unwrapped.kind,
              case .name(let type) = receiver.unwrapped.kind,
              type.hasSuffix("Exception") else { return nil }
        let values = try arguments.map { (argument) throws(TranspileError) in try expression(argument.value, expected: nil) }
        let name = values.first.map { $0.code.replacingOccurrences(of: "\"", with: "") } ?? ""
        func check(_ condition: String, _ requirement: String) -> String {
            "assert(\(condition), \"\(name) \(requirement)\")"
        }
        switch (method, values.count) {
        case ("ThrowIfNull", 1):
            // Swift's types already keep a non-optional from being nil.
            return values[0].type.isNullable || values[0].type == .unknown ? check("\(values[0].code) != nil", "must not be nil") : ""
        case ("ThrowIfNullOrEmpty", 1): return check("!\(values[0].code).isEmpty", "must not be empty")
        case ("ThrowIfNullOrWhiteSpace", 1):
            return check("!\(values[0].code).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty", "must not be blank")
        case ("ThrowIfNegative", 1): return check("\(values[0].code) >= 0", "must not be negative")
        case ("ThrowIfZero", 1): return check("\(values[0].code) != 0", "must not be zero")
        case ("ThrowIfNegativeOrZero", 1): return check("\(values[0].code) > 0", "must be positive")
        case ("ThrowIfLessThan", 2): return check("\(values[0].code) >= \(values[1].code)", "must be at least \(values[1].code)")
        case ("ThrowIfLessThanOrEqual", 2): return check("\(values[0].code) > \(values[1].code)", "must be more than \(values[1].code)")
        case ("ThrowIfGreaterThan", 2): return check("\(values[0].code) <= \(values[1].code)", "must be at most \(values[1].code)")
        case ("ThrowIfGreaterThanOrEqual", 2): return check("\(values[0].code) < \(values[1].code)", "must be less than \(values[1].code)")
        case ("ThrowIfEqual", 2): return check("\(values[0].code) != \(values[1].code)", "must not equal \(values[1].code)")
        case ("ThrowIfNotEqual", 2): return check("\(values[0].code) == \(values[1].code)", "must equal \(values[1].code)")
        default: throw TranspileError(location, "\(type).\(method) isn't supported")
        }
    }

    /// The Swift value a C# field of this type starts with when it has no initializer.
    func zeroValue(_ type: CType) -> String? {
        switch type {
        case .int, .long, .byte, .uint: "0"
        case .float, .double: "0"
        case .bool: "false"
        case .nullable: "nil"
        case .named(let name) where RaylibData.structs[RaylibData.aliases[name] ?? name] != nil: "\(name)()"
        default: nil
        }
    }

    /// Whether an expression is made only of literals, so Swift would infer `Double` or `Int`
    /// for it without a type annotation.
    func isLiteralOnly(_ value: Expression) -> Bool {
        switch value.unwrapped.kind {
        case .integer, .real: true
        case .unary(_, let operand): isLiteralOnly(operand)
        case .binary(_, let left, let right): isLiteralOnly(left) && isLiteralOnly(right)
        default: false
        }
    }
}
