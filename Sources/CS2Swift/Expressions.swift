import Foundation

/// Swift code for an expression, and the C# type it has.
struct Emitted {
    var code: String
    var type: CType
    /// A numeric literal, which Swift converts to whatever type the context needs.
    var isLiteral = false
}

extension Emitter {
    /// Emits an expression, converted to `expected` where C# would convert it implicitly
    /// (an `int` where a `float` is wanted, say).
    func expression(_ value: Expression, expected: CType?) throws(TranspileError) -> Emitted {
        convert(try raw(value, expected: expected), to: expected)
    }

    /// C#'s implicit numeric conversions, made explicit.
    func convert(_ value: Emitted, to target: CType?) -> Emitted {
        guard let target = target?.nonNullable, !value.isLiteral else { return value }
        let argument = Self.isParenthesized(value.code) ? value.code : "(\(value.code))"
        switch (value.type, target) {
        case (let from, .float) where from.isInteger:
            return Emitted(code: "Float\(argument)", type: .float)
        case (let from, .double) where from.isInteger || from == .float:
            return Emitted(code: "Double\(argument)", type: .double)
        case (.int, .byte), (.long, .byte):
            return Emitted(code: "UInt8(clamping: \(value.code))", type: .byte)
        case (.byte, .int), (.uint, .int):
            return Emitted(code: "Int(\(value.code))", type: .int)
        default:
            return value
        }
    }

    private func raw(_ value: Expression, expected: CType?) throws(TranspileError) -> Emitted {
        let location = value.location
        switch value.kind {
        case .integer(let text):
            return Emitted(code: text, type: .int, isLiteral: true)
        case .real(let text):
            if text.hasSuffix("m") { throw TranspileError(location, "decimal literals aren't supported") }
            var number = text.hasSuffix("f") ? String(text.dropLast()) : text
            if !number.contains(".") && !number.contains("e") { number += ".0" }
            return Emitted(code: number, type: text.hasSuffix("f") ? .float : .double, isLiteral: true)
        case .string(let text):
            return Emitted(code: Self.quoted(text), type: .string)
        case .character(let text):
            return Emitted(code: Self.quoted(text), type: .char)
        case .interpolated(let parts):
            var code = "\""
            for part in parts {
                switch part {
                case .text(let text): code += String(Self.quoted(text).dropFirst().dropLast())
                case .hole(let hole):
                    let emitted = try expression(hole, expected: nil)
                    if emitted.type.isFloatingPoint {
                        warn(hole.location, "Swift writes a whole float as \"1.0\" where C# writes \"1\"")
                    }
                    code += "\\(\(emitted.code))"
                }
            }
            return Emitted(code: code + "\"", type: .string)
        case .boolean(let flag):
            return Emitted(code: flag ? "true" : "false", type: .bool)
        case .null:
            return Emitted(code: "nil", type: expected.map { $0.isNullable ? $0 : .nullable($0) } ?? .unknown)
        case .this:
            return Emitted(code: "self", type: typeStack.last.map { .named($0.qualifiedName) } ?? .unknown)
        case .parenthesized(let inner):
            let emitted = try expression(inner, expected: expected)
            return Emitted(code: "(\(emitted.code))", type: emitted.type, isLiteral: emitted.isLiteral)
        case .name(let name):
            return unwrappedIfNarrowed(value, try self.name(name, location: location))
        case .typeName(let name):
            return Emitted(code: name, type: .typeReference(name))
        case .nameof(let name):
            return Emitted(code: Self.quoted(name), type: .string)
        case .member(let receiver, let name, let nullConditional):
            return unwrappedIfNarrowed(value, try member(receiver, name, nullConditional: nullConditional, location: location))
        case .call(let callee, let arguments):
            return try call(callee, arguments, location: location)
        case .index(let receiver, let indices, let nullConditional):
            return try index(receiver, indices, nullConditional: nullConditional, location: location)
        case .unary(let op, let operand):
            if op == "++" || op == "--" { throw TranspileError(location, "\(op) inside an expression isn't supported") }
            let emitted = try expression(operand, expected: expected)
            return Emitted(code: (op == "+" ? "" : op) + emitted.code, type: emitted.type, isLiteral: emitted.isLiteral)
        case .postfix(let op, let operand):
            if op == "!" {
                let emitted = try expression(operand, expected: nil)
                warn(location, "the null-forgiving ! became a force unwrap, which traps on nil")
                return Emitted(code: emitted.code + "!", type: emitted.type.nonNullable)
            }
            throw TranspileError(location, "\(op) inside an expression isn't supported")
        case .binary(let op, let left, let right):
            return try binary(op, left, right, expected: expected, location: location)
        case .assign(let op, let target, let value):
            return try assignment(op, target, value, location: location)
        case .conditional(let condition, let then, let otherwise):
            let test = try expression(condition, expected: .bool)
            let saved = narrowed
            narrowed.formUnion(NullChecks.conjuncts(condition).compactMap { NullChecks.check($0).flatMap { $0.isNull ? nil : $0.key } })
            var a = try raw(then, expected: expected)
            narrowed = saved
            narrowed.formUnion(NullChecks.disjuncts(condition).compactMap { $0.isNull ? $0.key : nil })
            var b = try raw(otherwise, expected: expected)
            narrowed = saved
            let common = expected ?? Self.promoted(a.type, b.type) ?? (a.type == .unknown ? b.type : a.type)
            a = convert(a, to: common)
            b = convert(b, to: common)
            return Emitted(code: "\(test.code) ? \(a.code) : \(b.code)", type: common)
        case .cast(let target, let operand):
            return try cast(ctype(target), operand, location: location)
        case .new(let target, let arguments, let initializers):
            return try new(target.map(ctype) ?? expected, arguments, initializers, location: location)
        case .collection(let elements):
            var element: CType?
            if case .list(let inner)? = expected?.nonNullable { element = inner }
            let codes = try elements.map { (item) throws(TranspileError) in try expression(item, expected: element) }
            let type = CType.list(element ?? codes.first?.type ?? .unknown)
            return Emitted(code: "[\(codes.map(\.code).joined(separator: ", "))]", type: expected ?? type)
        case .lambda(let parameters, let body):
            return try lambda(parameters, body, expected: expected, location: location)
        case .is(let subject, let pattern):
            let emitted = try expression(subject, expected: nil)
            guard Self.isPure(subject) else { throw TranspileError(location, "is patterns need a plain name or member as their subject") }
            return Emitted(code: try self.pattern(pattern, subject: emitted), type: .bool)
        case .with(let receiver, let changes):
            let emitted = try expression(receiver, expected: expected)
            var assignments: [String] = []
            for (field, change) in changes {
                let (swiftName, fieldType) = memberOf(emitted.type, field)
                assignments.append("$0.\(swiftName) = \(try expression(change, expected: fieldType).code)")
            }
            return Emitted(code: "with(\(emitted.code)) { \(assignments.joined(separator: "; ")) }", type: emitted.type)
        case .tuple(let elements):
            var expectedElements: [CType]?
            if case .tuple(let types)? = expected, types.count == elements.count { expectedElements = types }
            var codes: [Emitted] = []
            for (offset, element) in elements.enumerated() {
                codes.append(try expression(element, expected: expectedElements?[offset]))
            }
            return Emitted(code: "(\(codes.map(\.code).joined(separator: ", ")))", type: .tuple(codes.map(\.type)))
        case .range, .fromEnd:
            throw TranspileError(location, "ranges are only supported as an index")
        case .default(let target):
            let type = target.map(ctype) ?? expected ?? .unknown
            guard let zero = zeroValue(type) else { throw TranspileError(location, "default of \(type.swift) isn't supported") }
            return Emitted(code: zero, type: type, isLiteral: type.isNumeric)
        case .switchExpression(let subject, let arms):
            return try switchExpression(subject, arms, expected: expected, location: location)
        }
    }

    // MARK: Names and members

    private func name(_ name: String, location: SourceLocation) throws(TranspileError) -> Emitted {
        if name == "value", inSetter, local("value") != nil {
            return Emitted(code: "newValue", type: local("value") ?? .unknown)
        }
        if let type = local(name) {
            return Emitted(code: Naming.escaped(name), type: type)
        }
        // Members of this type and the types around it.
        for (depth, type) in typeStack.enumerated().reversed() {
            guard let info = type.members[name]?.first else { continue }
            if info.kind == .type { return Emitted(code: "\(type.qualifiedName).\(name)", type: info.type) }
            if info.isStatic {
                let qualify = !(isStaticContext && depth == typeStack.count - 1) || local(info.swiftName) != nil
                return Emitted(code: qualify ? "\(type.qualifiedName).\(info.swiftName)" : info.swiftName, type: info.type)
            }
            let needsSelf = lambdaDepth > 0 || local(info.swiftName) != nil || local(Naming.trimmingUnderscores(name)) != nil
            return Emitted(code: needsSelf ? "self.\(info.swiftName)" : info.swiftName, type: info.type)
        }
        if let info = symbols.type(named: name) {
            return Emitted(code: info.qualifiedName, type: .typeReference(info.qualifiedName))
        }
        if name.first?.isUppercase == true {
            return Emitted(code: name, type: .typeReference(name))
        }
        warn(location, "'\(name)' isn't declared in any file cs2swift read")
        return Emitted(code: Naming.escaped(name), type: .unknown)
    }

    /// The Swift name and type of a field or property of a value of the given type.
    func memberOf(_ type: CType, _ name: String) -> (String, CType?) {
        if case .named(let typeName) = type.nonNullable {
            if let fields = RaylibData.structs[RaylibData.aliases[typeName] ?? typeName] {
                let swiftName = Naming.lowerCamel(name)
                for field in fields where field.hasPrefix(swiftName + ":") {
                    return (swiftName, CType(raylib: String(field.dropFirst(swiftName.count + 1))))
                }
            }
            if let info = symbols.type(named: typeName)?.members[name]?.first {
                return (info.swiftName, info.type)
            }
        }
        return (Naming.lowerCamel(name), nil)
    }

    private func member(_ receiver: Expression, _ name: String, nullConditional: Bool, location: SourceLocation) throws(TranspileError) -> Emitted {
        let base = try expression(receiver, expected: nil)
        if case .typeReference(let typeName) = base.type {
            return try staticMember(typeName, base.code, name, location: location)
        }
        let access = nullConditional ? "?." : "."
        func wrap(_ type: CType) -> CType { nullConditional && !type.isNullable ? .nullable(type) : type }

        switch (base.type.nonNullable, name) {
        case (.string, "Length"), (.list, "Count"), (.list, "Length"), (.stringBuilder, "Length"):
            return Emitted(code: base.code + access + "count", type: wrap(.int))
        default: break
        }
        if base.type.isNullable && !nullConditional {
            if name == "Value" {
                warn(location, ".Value became a force unwrap, which traps on nil")
                return Emitted(code: base.code + "!", type: base.type.nonNullable)
            }
            if name == "HasValue" { return Emitted(code: "(\(base.code) != nil)", type: .bool) }
        }
        let (swiftName, type) = memberOf(base.type, name)
        if type == nil, base.type != .unknown, !isRaylibValue(base.type) {
            warn(location, "nothing says what '\(name)' is on \(base.type.swift)")
        }
        return Emitted(code: base.code + access + swiftName, type: wrap(type ?? .unknown))
    }

    private func isRaylibValue(_ type: CType) -> Bool {
        if case .named(let name) = type.nonNullable { return RaylibData.structs[RaylibData.aliases[name] ?? name] != nil }
        return false
    }

    private func staticMember(_ typeName: String, _ code: String, _ name: String, location: SourceLocation) throws(TranspileError) -> Emitted {
        switch (typeName, name) {
        case ("string", "Empty"): return Emitted(code: "\"\"", type: .string)
        case ("int", "MaxValue"): return Emitted(code: "Int(Int32.max)", type: .int)
        case ("int", "MinValue"): return Emitted(code: "Int(Int32.min)", type: .int)
        case ("float", "MaxValue"): return Emitted(code: "Float.greatestFiniteMagnitude", type: .float)
        case ("float", "MinValue"): return Emitted(code: "-Float.greatestFiniteMagnitude", type: .float)
        case ("float", "Epsilon"): return Emitted(code: "Float.leastNonzeroMagnitude", type: .float)
        case ("float", "PositiveInfinity"): return Emitted(code: "Float.infinity", type: .float)
        case ("float", "NegativeInfinity"): return Emitted(code: "-Float.infinity", type: .float)
        case ("float", "NaN"): return Emitted(code: "Float.nan", type: .float)
        case ("double", "MaxValue"): return Emitted(code: "Double.greatestFiniteMagnitude", type: .double)
        case ("Math", "PI"): return Emitted(code: "Double.pi", type: .double)
        case ("MathF", "PI"): return Emitted(code: "Float.pi", type: .float)
        case ("Vector2", _), ("Vector3", _):
            if ["Zero", "One", "UnitX", "UnitY", "UnitZ"].contains(name) {
                return Emitted(code: "\(typeName).\(Naming.lowerCamel(name))", type: .named(typeName))
            }
        case ("Color", _):
            return Emitted(code: "Color.\(Naming.lowerCamel(name))", type: .named("Color"))
        default: break
        }
        if RaylibData.enums.contains(typeName) {
            let caseName = RaylibData.enumCaseRenames["\(typeName).\(name)"] ?? Naming.lowerCamel(name)
            return Emitted(code: "\(typeName).\(caseName)", type: .named(typeName))
        }
        if let info = symbols.type(named: typeName) {
            guard let member = info.members[name]?.first else {
                throw TranspileError(location, "\(typeName) has no member \(name)")
            }
            if member.kind == .type { return Emitted(code: "\(info.qualifiedName).\(name)", type: member.type) }
            return Emitted(code: "\(info.qualifiedName).\(member.swiftName)", type: member.type)
        }
        if typeName == "Raylib" { return Emitted(code: name, type: .unknown) }
        return Emitted(code: "\(code).\(Naming.lowerCamel(name))", type: .unknown)
    }

    // MARK: Calls

    private func call(_ callee: Expression, _ arguments: [Argument], location: SourceLocation) throws(TranspileError) -> Emitted {
        switch callee.unwrapped.kind {
        case .member(let receiver, let method, let nullConditional):
            let base = try expression(receiver, expected: nil)
            if case .typeReference(let typeName) = base.type {
                return try staticCall(typeName, base.code, method, arguments, location: location)
            }
            return try instanceCall(base, method, arguments, nullConditional: nullConditional, location: location)
        case .name(let name):
            if name == "ReferenceEquals" || name == "Equals", arguments.count == 2 {
                let a = try expression(arguments[0].value, expected: nil)
                let b = try expression(arguments[1].value, expected: nil)
                if isReference(a.type) && isReference(b.type) { return Emitted(code: "\(a.code) === \(b.code)", type: .bool) }
                warn(location, "ReferenceEquals became ==, which compares values")
                return Emitted(code: "\(a.code) == \(b.code)", type: .bool)
            }
            if local(name) == nil {
                for (depth, type) in typeStack.enumerated().reversed() {
                    guard let overloads = type.members[name], overloads.first?.kind == .method else { continue }
                    let method = try choose(overloads, arguments, location: location)
                    let args = try self.arguments(arguments, method.parameters, location: location)
                    var prefix = ""
                    if method.isStatic {
                        if !(isStaticContext && depth == typeStack.count - 1) { prefix = "\(type.qualifiedName)." }
                    } else if lambdaDepth > 0 {
                        prefix = "self."
                    }
                    return Emitted(code: "\(prefix)\(method.swiftName)(\(args.joined(separator: ", ")))", type: method.type)
                }
            }
        default:
            break
        }
        let function = try expression(callee, expected: nil)
        var parameterTypes: [CType]?
        var result = CType.unknown
        if case .function(let types, let returns) = function.type.nonNullable {
            parameterTypes = types
            result = returns
        }
        let args = try arguments.enumerated().map { (offset, argument) throws(TranspileError) in
            try expression(argument.value, expected: parameterTypes?[safe: offset]).code
        }
        return Emitted(code: "\(function.code)(\(args.joined(separator: ", ")))", type: result)
    }

    private func isReference(_ type: CType) -> Bool {
        if case .named(let name) = type.nonNullable { return symbols.type(named: name)?.kind == .class }
        return false
    }

    private func choose(_ overloads: [MemberInfo], _ arguments: [Argument], location: SourceLocation) throws(TranspileError) -> MemberInfo {
        for overload in overloads {
            let required = overload.parameters.filter { $0.defaultValue == nil }.count
            if (required...overload.parameters.count).contains(arguments.count) { return overload }
        }
        throw TranspileError(location, "no overload of \(overloads[0].name) takes \(arguments.count) arguments")
    }

    /// The arguments in parameter order, named ones placed and skipped defaults filled in,
    /// each converted to its parameter's type.
    func arguments(_ arguments: [Argument], _ parameters: [ParameterInfo], location: SourceLocation) throws(TranspileError) -> [String] {
        var slots: [Argument?] = Array(repeating: nil, count: parameters.count)
        var next = 0
        for argument in arguments {
            var slot = next
            if let name = argument.name {
                guard let index = parameters.firstIndex(where: { $0.name == name }) else {
                    throw TranspileError(location, "no parameter named \(name)")
                }
                slot = index
            }
            guard slots.indices.contains(slot) else { throw TranspileError(location, "too many arguments") }
            slots[slot] = argument
            next = slot + 1
        }
        let last = slots.lastIndex { $0 != nil } ?? -1
        var codes: [String] = []
        for (index, parameter) in parameters.enumerated() where index <= last {
            if let argument = slots[index] {
                var code = try expression(argument.value, expected: parameter.type).code
                if argument.modifier == "ref" { code = "&" + code }
                codes.append(code)
            } else if let defaultValue = parameter.defaultValue {
                codes.append(try expression(inlinedConstant(defaultValue), expected: parameter.type).code)
            } else {
                throw TranspileError(location, "missing an argument for \(parameter.name)")
            }
        }
        return codes
    }

    private func staticCall(_ typeName: String, _ code: String, _ method: String, _ arguments: [Argument], location: SourceLocation) throws(TranspileError) -> Emitted {
        func values(_ expected: CType? = nil) throws(TranspileError) -> [Emitted] {
            try arguments.map { (argument) throws(TranspileError) in try expression(argument.value, expected: expected) }
        }
        switch typeName {
        case "Raylib":
            return try raylibCall(method, arguments, location: location)
        case "Math", "MathF":
            return try mathCall(typeName, method, arguments, location: location)
        case "string":
            let args = try values()
            switch (method, args.count) {
            case ("IsNullOrEmpty", 1):
                return Emitted(code: args[0].type.isNullable ? "(\(args[0].code) ?? \"\").isEmpty" : "\(args[0].code).isEmpty", type: .bool)
            case ("IsNullOrWhiteSpace", 1):
                let text = args[0].type.isNullable ? "(\(args[0].code) ?? \"\")" : args[0].code
                return Emitted(code: "\(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty", type: .bool)
            case ("Join", 2):
                var list = args[1].code
                if case .list(let element) = args[1].type, element != .string { list += ".map { String(describing: $0) }" }
                return Emitted(code: "\(list).joined(separator: \(args[0].code))", type: .string)
            default: break
            }
        case "Vector2":
            let functions = ["Distance": "Vector2Distance", "Lerp": "Vector2Lerp", "Normalize": "Vector2Normalize", "Dot": "Vector2DotProduct", "DistanceSquared": "Vector2DistanceSqr"]
            if let function = functions[method] {
                let args = try values()
                let result: CType = method.hasPrefix("Distance") || method == "Dot" ? .float : .named("Vector2")
                return Emitted(code: "\(function)(\(args.map(\.code).joined(separator: ", ")))", type: result)
            }
        case "float":
            if method == "IsNaN", arguments.count == 1 { return Emitted(code: "\(try values()[0].code).isNaN", type: .bool) }
            if method == "IsFinite", arguments.count == 1 { return Emitted(code: "\(try values()[0].code).isFinite", type: .bool) }
        default:
            if let info = symbols.type(named: typeName), let overloads = info.members[method] {
                let chosen = try choose(overloads, arguments, location: location)
                let args = try self.arguments(arguments, chosen.parameters, location: location)
                return Emitted(code: "\(info.qualifiedName).\(chosen.swiftName)(\(args.joined(separator: ", ")))", type: chosen.type)
            }
            if symbols.type(named: typeName) == nil {
                let args = try values()
                return Emitted(code: "\(code).\(Naming.lowerCamel(method))(\(args.map(\.code).joined(separator: ", ")))", type: .unknown)
            }
        }
        throw TranspileError(location, "\(typeName).\(method) isn't supported")
    }

    private func raylibCall(_ function: String, _ arguments: [Argument], location: SourceLocation) throws(TranspileError) -> Emitted {
        guard let signature = RaylibData.functions[function] else {
            throw TranspileError(location, "Raylib.\(function) isn't in raylib \(RaylibData.raylibVersion)'s raylib.h")
        }
        let parts = signature.components(separatedBy: "->")
        if parts[0].hasSuffix("...") { throw TranspileError(location, "variadic raylib functions (\(function)) aren't supported") }
        let parameterTypes = parts[0].isEmpty ? [] : parts[0].split(separator: ",").map { CType(raylib: String($0)) }
        guard parameterTypes.count == arguments.count else {
            throw TranspileError(location, "Raylib.\(function) takes \(parameterTypes.count) arguments in raylib.h, not \(arguments.count)")
        }
        var codes: [String] = []
        for (argument, type) in zip(arguments, parameterTypes) {
            let expected: CType? = if case .named(let name) = type, name.hasPrefix("Pointer<") { nil } else { type }
            var code = try expression(argument.value, expected: expected).code
            if argument.modifier == "ref" || argument.modifier == "out" { code = "&" + code }
            codes.append(code)
        }
        var call = "\(function)(\(codes.joined(separator: ", ")))"
        let result = CType(raylib: parts[1])
        if RaylibData.intResultOnly.contains(function) {
            call = "Int(\(call))"
        } else if result == .string {
            call = "String(cString: \(call))"
        }
        return Emitted(code: call, type: result)
    }

    private func mathCall(_ typeName: String, _ method: String, _ arguments: [Argument], location: SourceLocation) throws(TranspileError) -> Emitted {
        var values = try arguments.map { (argument) throws(TranspileError) in try raw(argument.value, expected: nil) }
        var common = values.first?.type ?? .unknown
        for value in values.dropFirst() {
            common = Self.promoted(common, value.type) ?? (common == .unknown ? value.type : common)
        }
        values = values.map { convert($0, to: common) }
        let codes = values.map(\.code)
        func one(_ format: (String) -> String) throws(TranspileError) -> Emitted {
            guard codes.count == 1 else { throw TranspileError(location, "\(typeName).\(method) takes one argument") }
            return Emitted(code: format(codes[0]), type: common == .int ? (typeName == "MathF" ? .float : .double) : common)
        }
        switch method {
        case "Max", "Min":
            guard codes.count == 2 else { break }
            return Emitted(code: "\(method.lowercased())(\(codes.joined(separator: ", ")))", type: common)
        case "Clamp":
            guard codes.count == 3 else { break }
            return Emitted(code: "clamp(\(codes.joined(separator: ", ")))", type: common)
        case "Abs":
            guard codes.count == 1 else { break }
            return Emitted(code: "abs(\(codes[0]))", type: common)
        case "Floor": return try one { "\($0).rounded(.down)" }
        case "Ceiling": return try one { "\($0).rounded(.up)" }
        case "Truncate": return try one { "\($0).rounded(.towardZero)" }
        case "Round":
            if codes.count == 1 { return try one { "\($0).rounded(.toNearestOrEven)" } }
        case "Sqrt", "Sin", "Cos", "Tan", "Asin", "Acos", "Atan", "Exp", "Log":
            return try one { "\(method.lowercased())(\($0))" }
        case "Atan2", "Pow":
            guard codes.count == 2 else { break }
            return Emitted(code: "\(method.lowercased())(\(codes.joined(separator: ", ")))", type: common)
        default: break
        }
        throw TranspileError(location, "\(typeName).\(method) isn't supported")
    }

    private func instanceCall(_ base: Emitted, _ method: String, _ arguments: [Argument], nullConditional: Bool, location: SourceLocation) throws(TranspileError) -> Emitted {
        let access = nullConditional ? "?." : "."
        func values(_ expected: CType? = nil) throws(TranspileError) -> [Emitted] {
            try arguments.map { (argument) throws(TranspileError) in try expression(argument.value, expected: expected) }
        }
        let type = base.type.nonNullable

        if method == "Invoke", case .function(let parameters, let result) = type {
            var codes: [String] = []
            for (offset, argument) in arguments.enumerated() {
                codes.append(try expression(argument.value, expected: parameters[safe: offset]).code)
            }
            let callee = nullConditional ? base.code + "?" : base.code
            return Emitted(code: "\(callee)(\(codes.joined(separator: ", ")))", type: nullConditional && !result.isNullable ? .nullable(result) : result)
        }
        if method == "ToString" {
            if arguments.count > 1 || (arguments.count == 1 && !Self.isInvariantCulture(arguments[0].value)) {
                throw TranspileError(location, "ToString with a format isn't supported")
            }
            switch type {
            case .string, .stringBuilder: return Emitted(code: base.code, type: .string)
            case .int, .long, .byte, .uint: return Emitted(code: "String(\(base.code))", type: .string)
            default:
                if type.isFloatingPoint { warn(location, "Swift writes a whole float as \"1.0\" where C# writes \"1\"") }
                return Emitted(code: "String(describing: \(base.code))", type: .string)
            }
        }
        if method == "Equals", arguments.count == 1 {
            return Emitted(code: "\(base.code) == \(try values()[0].code)", type: .bool)
        }

        switch type {
        case .string:
            let args = try values()
            switch (method, args.count) {
            case ("Trim", 0): return Emitted(code: "\(base.code)\(access)trimmingCharacters(in: .whitespacesAndNewlines)", type: .string)
            case ("ToUpper", 0), ("ToUpperInvariant", 0): return Emitted(code: "\(base.code)\(access)uppercased()", type: .string)
            case ("ToLower", 0), ("ToLowerInvariant", 0): return Emitted(code: "\(base.code)\(access)lowercased()", type: .string)
            case ("StartsWith", 1): return Emitted(code: "\(base.code)\(access)hasPrefix(\(args[0].code))", type: .bool)
            case ("EndsWith", 1): return Emitted(code: "\(base.code)\(access)hasSuffix(\(args[0].code))", type: .bool)
            case ("Contains", 1): return Emitted(code: "\(base.code)\(access)contains(\(args[0].code))", type: .bool)
            case ("Replace", 2):
                return Emitted(code: "\(base.code)\(access)replacingOccurrences(of: \(args[0].code), with: \(args[1].code))", type: .string)
            case ("Substring", 1): return Emitted(code: "String(\(base.code).dropFirst(\(args[0].code)))", type: .string)
            case ("Substring", 2):
                return Emitted(code: "String(\(base.code).dropFirst(\(args[0].code)).prefix(\(args[1].code)))", type: .string)
            case ("Split", 1), ("Split", 2):
                let removeEmpty = args.count == 2 && args[1].code.contains("removeEmptyEntries")
                let separator = args[0].code
                let omitting = removeEmpty ? "" : ", omittingEmptySubsequences: false"
                return Emitted(code: "\(base.code).split(separator: \(separator)\(omitting)).map(String.init)", type: .list(.string))
            default: break
            }
        case .list(let element):
            switch (method, arguments.count) {
            case ("Add", 1): return Emitted(code: "\(base.code).append(\(try values(element)[0].code))", type: .void)
            case ("AddRange", 1): return Emitted(code: "\(base.code).append(contentsOf: \(try values()[0].code))", type: .void)
            case ("Clear", 0): return Emitted(code: "\(base.code).removeAll()", type: .void)
            case ("Insert", 2):
                let index = try expression(arguments[0].value, expected: .int).code
                let item = try expression(arguments[1].value, expected: element).code
                return Emitted(code: "\(base.code).insert(\(item), at: \(index))", type: .void)
            case ("RemoveAt", 1): return Emitted(code: "\(base.code).remove(at: \(try values(.int)[0].code))", type: .void)
            case ("Contains", 1): return Emitted(code: "\(base.code)\(access)contains(\(try values(element)[0].code))", type: .bool)
            case ("IndexOf", 1): return Emitted(code: "(\(base.code).firstIndex(of: \(try values(element)[0].code)) ?? -1)", type: .int)
            case ("Reverse", 0): return Emitted(code: "\(base.code).reverse()", type: .void)
            case ("Sort", 0): return Emitted(code: "\(base.code).sort()", type: .void)
            default: break
            }
        case .stringBuilder:
            switch (method, arguments.count) {
            case ("Append", 1):
                let value = try expression(arguments[0].value, expected: nil)
                let text = value.type == .string || value.type == .char ? value.code : "String(describing: \(value.code))"
                return Emitted(code: "\(base.code).append(\(text))", type: .void)
            case ("Clear", 0): return Emitted(code: "\(base.code).removeAll()", type: .void)
            default: break
            }
        case .named("Vector2"):
            if method == "Length", arguments.isEmpty { return Emitted(code: "Vector2Length(\(base.code))", type: .float) }
            if method == "LengthSquared", arguments.isEmpty { return Emitted(code: "Vector2LengthSqr(\(base.code))", type: .float) }
        case .named(let name):
            if let info = symbols.type(named: name), let overloads = info.members[method] {
                let chosen = try choose(overloads, arguments, location: location)
                let args = try self.arguments(arguments, chosen.parameters, location: location)
                let result = nullConditional && chosen.type != .void && !chosen.type.isNullable ? CType.nullable(chosen.type) : chosen.type
                return Emitted(code: "\(base.code)\(access)\(chosen.swiftName)(\(args.joined(separator: ", ")))", type: result)
            }
            if symbols.type(named: name) == nil, RaylibData.structs[RaylibData.aliases[name] ?? name] == nil {
                warn(location, "nothing says what \(name).\(method) takes; pass its file with --reference")
                let args = try values()
                return Emitted(code: "\(base.code)\(access)\(Naming.lowerCamel(method))(\(args.map(\.code).joined(separator: ", ")))", type: .unknown)
            }
        case .unknown:
            let args = try values()
            return Emitted(code: "\(base.code)\(access)\(Naming.lowerCamel(method))(\(args.map(\.code).joined(separator: ", ")))", type: .unknown)
        default: break
        }
        throw TranspileError(location, "\(method) on \(base.type.swift) isn't supported")
    }

    private static func isInvariantCulture(_ value: Expression) -> Bool {
        if case .member(_, "InvariantCulture", _) = value.unwrapped.kind { return true }
        return false
    }

    // MARK: Operators

    /// The type C# computes in mixed arithmetic, or `nil` if the types aren't both numbers.
    static func promoted(_ a: CType, _ b: CType) -> CType? {
        let a = a.nonNullable, b = b.nonNullable
        guard a.isNumeric, b.isNumeric else { return a == b ? a : nil }
        if a == .double || b == .double { return .double }
        if a == .float || b == .float { return .float }
        return .int
    }

    private func binary(_ op: String, _ left: Expression, _ right: Expression, expected: CType?, location: SourceLocation) throws(TranspileError) -> Emitted {
        if op == "&&" || op == "||" {
            let a = try expression(left, expected: .bool)
            let saved = narrowed
            if op == "&&" {
                narrowed.formUnion(NullChecks.conjuncts(left).compactMap { NullChecks.check($0).flatMap { $0.isNull ? nil : $0.key } })
            } else {
                narrowed.formUnion(NullChecks.disjuncts(left).compactMap { $0.isNull ? $0.key : nil })
            }
            defer { narrowed = saved }
            let b = try expression(right, expected: .bool)
            return Emitted(code: "\(a.code) \(op) \(b.code)", type: .bool)
        }
        var a = try raw(left, expected: nil)
        var b = try raw(right, expected: op == "??" ? a.type.nonNullable : nil)

        func parenthesizedIfBinary(_ value: Emitted, _ source: Expression) -> String {
            switch source.kind {
            case .binary, .conditional, .is: "(\(value.code))"
            default: value.code
            }
        }

        switch op {
        case "??":
            if !a.type.isNullable && a.type != .unknown {
                return a
            }
            b = convert(b, to: a.type.nonNullable)
            return Emitted(code: "\(parenthesizedIfBinary(a, left)) ?? \(parenthesizedIfBinary(b, right))", type: b.type)
        case "==", "!=":
            if case .null = right.unwrapped.kind { return Emitted(code: "\(a.code) \(op) nil", type: .bool) }
            if case .null = left.unwrapped.kind { return Emitted(code: "\(b.code) \(op) nil", type: .bool) }
            if let common = Self.promoted(a.type, b.type) {
                a = convert(a, to: common)
                b = convert(b, to: common)
            }
            return Emitted(code: "\(a.code) \(op) \(b.code)", type: .bool)
        case "<", ">", "<=", ">=":
            if let common = Self.promoted(a.type, b.type) {
                a = convert(a, to: common)
                b = convert(b, to: common)
            }
            return Emitted(code: "\(a.code) \(op) \(b.code)", type: .bool)
        case "&", "|", "^":
            if a.type == .bool || b.type == .bool {
                guard op != "^" else { return Emitted(code: "\(a.code) != \(b.code)", type: .bool) }
                warn(location, "\(op) on bools became \(op)\(op), which skips the right side when the left decides")
                return Emitted(code: "\(a.code) \(op)\(op) \(b.code)", type: .bool)
            }
            return Emitted(code: "\(parenthesizedIfBinary(a, left)) \(op) \(parenthesizedIfBinary(b, right))", type: Self.promoted(a.type, b.type) ?? a.type)
        case "<<", ">>":
            return Emitted(code: "\(parenthesizedIfBinary(a, left)) \(op) \(parenthesizedIfBinary(b, right))", type: a.type)
        default:
            break
        }

        // Arithmetic.
        if op == "+", a.type == .string || b.type == .string {
            func text(_ value: Emitted) -> String {
                switch value.type {
                case .string: value.code
                case .char, .int, .long, .byte, .uint: "String(\(value.code))"
                default: "String(describing: \(value.code))"
                }
            }
            return Emitted(code: "\(text(a)) + \(text(b))", type: .string)
        }
        let vectorTypes: Set<String> = ["Vector2", "Vector3", "Vector4"]
        if case .named(let vector) = a.type, vectorTypes.contains(vector) {
            b = convert(b, to: b.type.isNumeric ? .float : nil)
            return Emitted(code: "\(a.code) \(op) \(b.code)", type: a.type)
        }
        if case .named(let vector) = b.type, vectorTypes.contains(vector) {
            a = convert(a, to: a.type.isNumeric ? .float : nil)
            return Emitted(code: "\(a.code) \(op) \(b.code)", type: b.type)
        }
        let common = Self.promoted(a.type, b.type) ?? (a.type == .unknown ? b.type : a.type)
        a = convert(a, to: common)
        b = convert(b, to: common)
        if op == "%", common.isFloatingPoint {
            return Emitted(code: "\(a.code).truncatingRemainder(dividingBy: \(b.code))", type: common)
        }
        return Emitted(code: "\(a.code) \(op) \(b.code)", type: common, isLiteral: a.isLiteral && b.isLiteral)
    }

    private func assignment(_ op: String, _ target: Expression, _ value: Expression, location: SourceLocation) throws(TranspileError) -> Emitted {
        let key = NullChecks.key(target)
        if let key { narrowed.remove(key) }
        let left = try expression(target, expected: nil)
        let type = left.type
        switch op {
        case "=":
            return Emitted(code: "\(left.code) = \(try expression(value, expected: type).code)", type: .void)
        case "|=", "&=":
            let right = try expression(value, expected: type)
            if type == .bool {
                return Emitted(code: "\(left.code) = \(right.code) \(op == "|=" ? "||" : "&&") \(left.code)", type: .void)
            }
            return Emitted(code: "\(left.code) \(op) \(right.code)", type: .void)
        case "??=":
            return Emitted(code: "\(left.code) = \(left.code) ?? \(try expression(value, expected: type.nonNullable).code)", type: .void)
        case "%=" where type.isFloatingPoint:
            let right = try expression(value, expected: type)
            return Emitted(code: "\(left.code) = \(left.code).truncatingRemainder(dividingBy: \(right.code))", type: .void)
        default:
            var expected: CType? = type
            if case .named(let name) = type, ["Vector2", "Vector3", "Vector4"].contains(name) { expected = nil }
            var right = try expression(value, expected: expected)
            if expected == nil, right.type.isNumeric { right = convert(right, to: .float) }
            if type == .string, op == "+=", right.type != .string {
                right = Emitted(code: right.type == .char ? "String(\(right.code))" : "String(describing: \(right.code))", type: .string)
            }
            return Emitted(code: "\(left.code) \(op) \(right.code)", type: .void)
        }
    }

    private func cast(_ target: CType, _ operand: Expression, location: SourceLocation) throws(TranspileError) -> Emitted {
        let value = try expression(operand, expected: nil)
        let source = value.type.nonNullable
        let code = Self.isSimple(operand) ? value.code : value.code
        switch target {
        case .int, .long:
            if source.isFloatingPoint {
                let inner = Self.isParenthesized(code) ? String(code.dropFirst().dropLast()) : code
                return Emitted(code: "Int(saturating: \(inner))", type: .int)
            }
            if source == .char { return Emitted(code: "\(code).utf16Code", type: .int) }
            if source == .int || source == .long { return value }
            if source.isInteger { return Emitted(code: "Int(\(code))", type: .int) }
            if case .named(let name) = source {
                if RaylibData.enums.contains(name) { return Emitted(code: "Int(\(code).rawValue)", type: .int) }
                if symbols.type(named: name)?.kind == .enum { return Emitted(code: "\(code).rawValue", type: .int) }
            }
            if source == .unknown { return Emitted(code: "Int(\(code))", type: .int) }
        case .float, .double:
            if source == target { return value }
            if source.isNumeric || source == .unknown { return Emitted(code: "\(target.swift)(\(code))", type: target, isLiteral: value.isLiteral) }
        case .char:
            if source.isInteger || source == .unknown { return Emitted(code: "Character(utf16: \(code))", type: .char) }
        case .byte:
            if source.isInteger { return Emitted(code: value.isLiteral ? code : "UInt8(truncatingIfNeeded: \(code))", type: .byte, isLiteral: value.isLiteral) }
        case .uint:
            if source.isInteger { return Emitted(code: value.isLiteral ? code : "UInt32(truncatingIfNeeded: \(code))", type: .uint, isLiteral: value.isLiteral) }
        default:
            break
        }
        throw TranspileError(location, "casting \(source.swift) to \(target.swift) isn't supported")
    }

    // MARK: Other expressions

    private func index(_ receiver: Expression, _ indices: [Expression], nullConditional: Bool, location: SourceLocation) throws(TranspileError) -> Emitted {
        let base = try expression(receiver, expected: nil)
        guard indices.count == 1 else { throw TranspileError(location, "multidimensional indexing isn't supported") }
        let isString = base.type.nonNullable == .string
        switch indices[0].unwrapped.kind {
        case .range(let start, let end):
            let lower = try start.map { (value) throws(TranspileError) in try expression(value, expected: .int).code }
            let upper = try end.map { (value) throws(TranspileError) in try expression(value, expected: .int).code }
            var slice = base.code
            if let lower { slice += ".dropFirst(\(lower))" }
            if let upper { slice += ".prefix(\(lower.map { "\(upper) - \($0)" } ?? upper))" }
            return Emitted(code: isString ? "String(\(slice))" : "Array(\(slice))", type: base.type.nonNullable)
        case .fromEnd(let offset):
            guard Self.isPure(receiver) else { throw TranspileError(location, "^ indexes need a plain name or member") }
            if isString { throw TranspileError(location, "indexing a string by position isn't supported") }
            let amount = try expression(offset, expected: .int).code
            var element = CType.unknown
            if case .list(let inner) = base.type.nonNullable { element = inner }
            return Emitted(code: "\(base.code)[\(base.code).count - \(amount)]", type: element)
        default:
            if isString { throw TranspileError(location, "indexing a string by position isn't supported") }
            let position = try expression(indices[0], expected: .int)
            var element = CType.unknown
            if case .list(let inner) = base.type.nonNullable { element = inner }
            return Emitted(code: "\(base.code)\(nullConditional ? "?" : "")[\(position.code)]", type: nullConditional ? .nullable(element) : element)
        }
    }

    private func lambda(_ parameters: [String], _ body: LambdaBody, expected: CType?, location: SourceLocation) throws(TranspileError) -> Emitted {
        var parameterTypes: [CType] = []
        var result = CType.unknown
        if case .function(let types, let returns) = expected?.nonNullable {
            parameterTypes = types
            result = returns
        }
        var scope: [String: CType] = [:]
        for (offset, name) in parameters.enumerated() where name != "_" {
            scope[name] = parameterTypes[safe: offset] ?? .unknown
        }
        let header = parameters.isEmpty ? "" : " \(parameters.map(Naming.escaped).joined(separator: ", ")) in"
        lambdaDepth += 1
        scopes.append(scope)
        defer {
            scopes.removeLast()
            lambdaDepth -= 1
        }
        switch body {
        case .expression(let value):
            let code = try expression(value, expected: result == .unknown || result == .void ? nil : result).code
            return Emitted(code: "{\(header) \(code) }", type: expected ?? .unknown)
        case .block:
            throw TranspileError(location, "lambdas with statement bodies aren't supported yet")
        }
    }

    private func pattern(_ pattern: Pattern, subject: Emitted) throws(TranspileError) -> String {
        switch pattern {
        case .null: return "\(subject.code) == nil"
        case .not(.null): return "\(subject.code) != nil"
        case .not(let inner): return "!(\(try self.pattern(inner, subject: subject)))"
        case .relational(let op, let value):
            return "\(subject.code) \(op) \(try expression(value, expected: subject.type).code)"
        case .constant(let value):
            return "\(subject.code) == \(try expression(value, expected: subject.type).code)"
        case .and(let a, let b):
            return "(\(try self.pattern(a, subject: subject)) && \(try self.pattern(b, subject: subject)))"
        case .or(let a, let b):
            return "(\(try self.pattern(a, subject: subject)) || \(try self.pattern(b, subject: subject)))"
        case .notNull:
            return "\(subject.code) != nil"
        case .binding:
            throw TranspileError(SourceLocation(line: 0, column: 0), "is { } name is only supported as part of an if condition")
        }
    }

    private func switchExpression(_ subject: Expression, _ arms: [(Pattern?, Expression)], expected: CType?, location: SourceLocation) throws(TranspileError) -> Emitted {
        let emitted = try expression(subject, expected: nil)
        var cases: [String] = []
        var result = expected
        var hasDefault = false
        for (pattern, value) in arms {
            let arm = try expression(value, expected: result)
            if result == nil { result = arm.type }
            if let pattern {
                cases.append("case \(try caseLabels(pattern, subjectType: emitted.type, location: location).joined(separator: ", ")): return \(arm.code)")
            } else {
                hasDefault = true
                cases.append("default: return \(arm.code)")
            }
        }
        guard hasDefault else { throw TranspileError(location, "switch expressions need a _ arm") }
        let type = result ?? .unknown
        return Emitted(code: "{ () -> \(type.swift) in switch \(emitted.code) { \(cases.joined(separator: "; ")) } }()", type: type)
    }

    private func caseLabels(_ pattern: Pattern, subjectType: CType, location: SourceLocation) throws(TranspileError) -> [String] {
        switch pattern {
        case .constant(let value): return [try expression(value, expected: subjectType).code]
        case .or(let a, let b):
            return try caseLabels(a, subjectType: subjectType, location: location) + caseLabels(b, subjectType: subjectType, location: location)
        case .null: return ["nil"]
        default: throw TranspileError(location, "only constant and or patterns are supported in switch arms")
        }
    }

    private func unwrappedIfNarrowed(_ source: Expression, _ value: Emitted) -> Emitted {
        guard value.type.isNullable, let key = NullChecks.key(source), narrowed.contains(key) else { return value }
        return Emitted(code: value.code + "!", type: value.type.nonNullable)
    }

    private func new(_ target: CType?, _ arguments: [Argument], _ initializers: [(String, Expression)]?, location: SourceLocation) throws(TranspileError) -> Emitted {
        guard let target = target?.nonNullable else {
            throw TranspileError(location, "target-typed new() needs a type cs2swift can see")
        }
        switch target {
        case .list:
            return Emitted(code: "\(target.swift)()", type: target)
        case .stringBuilder:
            if let first = arguments.first { return try expression(first.value, expected: .string) }
            return Emitted(code: "\"\"", type: .stringBuilder)
        case .named(let name):
            if let fields = RaylibData.structs[RaylibData.aliases[name] ?? name] {
                return try raylibStruct(name, fields, arguments, initializers, location: location)
            }
            if let info = symbols.type(named: name) {
                if initializers?.isEmpty == false { throw TranspileError(location, "object initializers on \(name) aren't supported") }
                let constructors = info.members["init"] ?? []
                if constructors.isEmpty {
                    guard arguments.isEmpty else { throw TranspileError(location, "\(name) has no constructor taking arguments") }
                    return Emitted(code: "\(info.qualifiedName)()", type: .named(info.qualifiedName))
                }
                let chosen = try choose(constructors, arguments, location: location)
                let args = try self.arguments(arguments, chosen.parameters, location: location)
                return Emitted(code: "\(info.qualifiedName)(\(args.joined(separator: ", ")))", type: .named(info.qualifiedName))
            }
            let args = try arguments.map { (argument) throws(TranspileError) in try expression(argument.value, expected: nil).code }
            warn(location, "nothing says what \(name)'s constructor takes")
            return Emitted(code: "\(name)(\(args.joined(separator: ", ")))", type: target)
        default:
            throw TranspileError(location, "new \(target.swift) isn't supported")
        }
    }

    private func raylibStruct(_ name: String, _ fields: [String], _ arguments: [Argument], _ initializers: [(String, Expression)]?, location: SourceLocation) throws(TranspileError) -> Emitted {
        let parsed = fields.map { field -> (String, CType) in
            let parts = field.split(separator: ":", maxSplits: 1).map(String.init)
            return (parts[0], CType(raylib: parts.count > 1 ? parts[1] : "?"))
        }
        if arguments.isEmpty && (initializers?.isEmpty ?? true) {
            return Emitted(code: "\(name)()", type: .named(name))
        }
        var values: [String: Expression] = [:]
        if !arguments.isEmpty {
            guard arguments.count == parsed.count else {
                throw TranspileError(location, "new \(name) with \(arguments.count) arguments isn't supported; give all \(parsed.count) fields")
            }
            for (argument, field) in zip(arguments, parsed) { values[field.0] = argument.value }
        }
        for (field, value) in initializers ?? [] {
            let swiftName = Naming.lowerCamel(field)
            guard parsed.contains(where: { $0.0 == swiftName }) else { throw TranspileError(location, "\(name) has no field \(field)") }
            values[swiftName] = value
        }
        var labelled: [String] = []
        for (field, type) in parsed {
            if let value = values[field] {
                labelled.append("\(field): \(try expression(value, expected: type).code)")
            } else {
                guard let zero = zeroValue(type) else { throw TranspileError(location, "\(name).\(field) needs a value") }
                labelled.append("\(field): \(zero)")
            }
        }
        return Emitted(code: "\(name)(\(labelled.joined(separator: ", ")))", type: .named(name))
    }

    // MARK: Helpers

    /// A constant's value in place of its name, for default arguments: Swift evaluates them
    /// where the call is, so they can't name a private constant.
    func inlinedConstant(_ value: Expression) -> Expression {
        var info: MemberInfo?
        switch value.unwrapped.kind {
        case .name(let name):
            info = typeStack.reversed().lazy.compactMap { $0.members[name]?.first }.first
        case .member(let receiver, let name, false):
            if case .name(let typeName) = receiver.unwrapped.kind { info = symbols.type(named: typeName)?.members[name]?.first }
        default:
            break
        }
        guard let info, info.kind == .constant, let initializer = info.initializer else { return value }
        return inlinedConstant(initializer)
    }

    static func isPure(_ expression: Expression) -> Bool {
        switch expression.unwrapped.kind {
        case .name, .this: true
        case .member(let receiver, _, _): isPure(receiver)
        default: false
        }
    }

    static func isSimple(_ expression: Expression) -> Bool { isPure(expression) }

    /// Whether code is wrapped in one pair of parentheses that match each other.
    static func isParenthesized(_ code: String) -> Bool {
        guard code.hasPrefix("("), code.hasSuffix(")") else { return false }
        var depth = 0
        var inString = false
        for (offset, character) in code.enumerated() {
            if character == "\"" { inString.toggle() }
            if inString { continue }
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if depth == 0 && offset < code.count - 1 { return false }
        }
        return true
    }

    static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            case "\0": result += "\\0"
            default:
                if scalar.value < 0x20 {
                    result += "\\u{\(String(scalar.value, radix: 16))}"
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
