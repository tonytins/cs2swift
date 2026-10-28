/// A C# type as cs2swift understands it, for choosing conversions.
indirect enum CType: Equatable, Sendable {
    case int, float, double, bool, string, char, byte, uint, long, void
    /// A user type, a raylib struct or enum, or a name nothing describes.
    case named(String)
    case nullable(CType)
    case list(CType)
    case stringBuilder
    case function([CType], CType)
    case tuple([CType])
    /// A type used as a receiver, such as `Theme` in `Theme.Accent`.
    case typeReference(String)
    case unknown

    var isInteger: Bool { [.int, .byte, .uint, .long].contains(self) }
    var isFloatingPoint: Bool { self == .float || self == .double }
    var isNumeric: Bool { isInteger || isFloatingPoint }

    var nonNullable: CType {
        if case .nullable(let inner) = self { return inner }
        return self
    }

    var isNullable: Bool {
        if case .nullable = self { return true }
        return false
    }

    init(_ syntax: TypeSyntax) {
        switch syntax {
        case .nullable(let inner): self = .nullable(CType(inner))
        case .array(let element): self = .list(CType(element))
        case .tuple(let elements): self = .tuple(elements.map(CType.init))
        case .named(let qualified, let arguments):
            let name = qualified.split(separator: ".").last.map(String.init) ?? qualified
            switch (name, arguments.count) {
            case ("int", 0), ("Int32", 0), ("short", 0), ("Int16", 0), ("sbyte", 0), ("ushort", 0): self = .int
            case ("float", 0), ("Single", 0): self = .float
            case ("double", 0), ("Double", 0): self = .double
            case ("bool", 0), ("Boolean", 0): self = .bool
            case ("string", 0), ("String", 0): self = .string
            case ("char", 0), ("Char", 0): self = .char
            case ("byte", 0), ("Byte", 0): self = .byte
            case ("uint", 0), ("UInt32", 0): self = .uint
            case ("long", 0), ("Int64", 0), ("ulong", 0): self = .long
            case ("void", 0): self = .void
            case ("object", 0): self = .unknown
            case ("StringBuilder", 0): self = .stringBuilder
            case ("List", 1), ("IReadOnlyList", 1), ("IList", 1), ("IEnumerable", 1), ("ICollection", 1), ("IReadOnlyCollection", 1):
                self = .list(CType(arguments[0]))
            case ("Func", _) where !arguments.isEmpty:
                self = .function(arguments.dropLast().map(CType.init), CType(arguments[arguments.count - 1]))
            case ("Action", 0):
                // Resolved later: a type declared in the code wins over System.Action.
                self = .named("Action")
            case ("Action", _):
                self = .function(arguments.map(CType.init), .void)
            default:
                // Nested types are known by their qualified name (WindowFrame.Action).
                self = .named(qualified)
            }
        }
    }

    /// The Swift spelling.
    var swift: String {
        switch self {
        case .int, .long: "Int"
        case .float: "Float"
        case .double: "Double"
        case .bool: "Bool"
        case .string, .stringBuilder: "String"
        case .char: "Character"
        case .byte: "UInt8"
        case .uint: "UInt32"
        case .void: "Void"
        case .named(let name), .typeReference(let name): name
        case .nullable(let inner):
            if case .function = inner { "(\(inner.swift))?" } else { inner.swift + "?" }
        case .list(let element): "[\(element.swift)]"
        case .function(let parameters, let result): "(\(parameters.map(\.swift).joined(separator: ", "))) -> \(result.swift)"
        case .tuple(let elements): "(\(elements.map(\.swift).joined(separator: ", ")))"
        case .unknown: "Any"
        }
    }

    /// The type of raylib's spelling in RaylibData (`Int`, `Float`, `Pointer<Image>`, `Color`).
    init(raylib spelling: String) {
        switch spelling {
        case "Int", "Int16": self = .int
        case "Float": self = .float
        case "Double": self = .double
        case "Bool": self = .bool
        case "String": self = .string
        case "UInt8", "CChar": self = .byte
        case "UInt32", "UInt16": self = .uint
        case "Void": self = .void
        case "?": self = .unknown
        default:
            if spelling.hasPrefix("Pointer<") {
                self = .named(spelling)
            } else {
                self = .named(RaylibData.aliases[spelling] ?? spelling)
            }
        }
    }
}

/// What cs2swift knows about one member of a type.
struct MemberInfo: Sendable {
    enum Kind: Sendable { case field, constant, property, method, constructor, enumCase, type }

    var kind: Kind
    var name: String
    var swiftName: String
    var isStatic: Bool
    /// A field's or property's type, or a method's result.
    var type: CType
    var parameters: [ParameterInfo]
    var isReadOnly: Bool
    /// A constant's value, inlined where Swift can't reach a private constant (default arguments).
    var initializer: Expression? = nil
}

/// A method parameter, for matching and converting arguments.
struct ParameterInfo: Sendable {
    var name: String
    var type: CType
    var modifier: String?
    var defaultValue: Expression?
}

/// What cs2swift knows about one type in the files it reads.
struct TypeInfo: Sendable {
    var name: String
    /// The name with its enclosing types, such as `WindowFrame.Action`.
    var qualifiedName: String
    var kind: TypeDeclaration.Kind
    var isStatic: Bool
    var members: [String: [MemberInfo]]
}

/// Every type in the input and reference files, by simple and qualified name.
struct SymbolTable: Sendable {
    private(set) var types: [String: TypeInfo] = [:]

    init(files: [SourceFile]) {
        for file in files {
            for type in file.types { add(type, outer: nil) }
        }
    }

    private mutating func add(_ declaration: TypeDeclaration, outer: String?, visible: [String: String] = [:]) {
        let qualified = outer.map { "\($0).\(declaration.name)" } ?? declaration.name
        var visible = visible
        for case .type(let nested) in declaration.members { visible[nested.name] = "\(qualified).\(nested.name)" }
        func CType(_ syntax: TypeSyntax) -> CS2Swift.CType { Self.qualify(CS2Swift.CType(syntax), visible) }
        let isStaticType = declaration.modifiers.contains("static")
        var members: [String: [MemberInfo]] = [:]
        var swiftNames: [String: [String]] = [:]

        func record(_ info: MemberInfo) {
            members[info.name, default: []].append(info)
        }

        for enumCase in declaration.enumCases {
            record(MemberInfo(kind: .enumCase, name: enumCase.name, swiftName: Naming.lowerCamel(enumCase.name), isStatic: true,
                              type: .named(qualified), parameters: [], isReadOnly: true))
        }
        for member in declaration.members {
            switch member {
            case .field(let field):
                let isConstant = field.modifiers.contains("const")
                for declarator in field.declarators {
                    record(MemberInfo(
                        kind: isConstant ? .constant : .field, name: declarator.name, swiftName: "",
                        isStatic: isStaticType || isConstant || field.modifiers.contains("static"), type: CType(field.type),
                        parameters: [], isReadOnly: isConstant || field.modifiers.contains("readonly"),
                        initializer: isConstant ? declarator.initializer : nil
                    ))
                }
            case .property(let property):
                record(MemberInfo(
                    kind: .property, name: property.name, swiftName: "",
                    isStatic: isStaticType || property.modifiers.contains("static"), type: CType(property.type),
                    parameters: [], isReadOnly: property.setter == nil
                ))
            case .method(let method):
                record(MemberInfo(
                    kind: .method, name: method.name, swiftName: "",
                    isStatic: isStaticType || method.modifiers.contains("static"), type: method.returnType.map { CType($0) } ?? .void,
                    parameters: method.parameters.map { ParameterInfo(name: $0.name, type: CType($0.type), modifier: $0.modifier, defaultValue: $0.defaultValue) },
                    isReadOnly: true
                ))
            case .constructor(let method):
                record(MemberInfo(
                    kind: .constructor, name: "init", swiftName: "init", isStatic: true, type: .named(qualified),
                    parameters: method.parameters.map { ParameterInfo(name: $0.name, type: CType($0.type), modifier: $0.modifier, defaultValue: $0.defaultValue) },
                    isReadOnly: true
                ))
            case .type(let nested):
                record(MemberInfo(kind: .type, name: nested.name, swiftName: nested.name, isStatic: true,
                                  type: .typeReference("\(qualified).\(nested.name)"), parameters: [], isReadOnly: true))
                add(nested, outer: qualified, visible: visible)
            }
        }

        // Swift names: lower camel case, without a leading underscore unless dropping it would
        // collide with another member (`_text` beside `Text`).
        for (name, infos) in members where infos.first?.swiftName.isEmpty == true {
            swiftNames[Naming.lowerCamel(Naming.trimmingUnderscores(name)), default: []].append(name)
        }
        for (name, infos) in members where infos.first?.swiftName.isEmpty == true {
            let plain = Naming.lowerCamel(Naming.trimmingUnderscores(name))
            let collides = (swiftNames[plain]?.count ?? 0) > 1
            let swiftName = collides && name.hasPrefix("_") ? "_" + plain : plain
            members[name] = infos.map { info in
                var info = info
                info.swiftName = swiftName
                return info
            }
        }

        let info = TypeInfo(name: declaration.name, qualifiedName: qualified, kind: declaration.kind, isStatic: isStaticType, members: members)
        types[qualified] = info
        if types[declaration.name] == nil { types[declaration.name] = info }
    }

    func type(named name: String) -> TypeInfo? { types[name] }

    private static func qualify(_ type: CType, _ visible: [String: String]) -> CType {
        switch type {
        case .named(let name): visible[name].map(CType.named) ?? (name == "Action" ? .function([], .void) : type)
        case .nullable(let inner): .nullable(qualify(inner, visible))
        case .list(let inner): .list(qualify(inner, visible))
        case .function(let parameters, let result): .function(parameters.map { qualify($0, visible) }, qualify(result, visible))
        case .tuple(let elements): .tuple(elements.map { qualify($0, visible) })
        default: type
        }
    }
}

/// Swift spellings of C# names.
enum Naming {
    /// `IsDragging` → `isDragging`, `UI` → `ui`, `HTTPServer` → `httpServer`.
    static func lowerCamel(_ name: String) -> String {
        let characters = Array(name)
        var upperPrefix = 0
        while upperPrefix < characters.count, characters[upperPrefix].isUppercase { upperPrefix += 1 }
        guard upperPrefix > 0 else { return escaped(name) }
        let lowered: String
        if upperPrefix == characters.count || upperPrefix == 1 {
            lowered = String(characters[..<upperPrefix]).lowercased() + String(characters[upperPrefix...])
        } else if characters[upperPrefix].isLetter {
            lowered = String(characters[..<(upperPrefix - 1)]).lowercased() + String(characters[(upperPrefix - 1)...])
        } else {
            lowered = String(characters[..<upperPrefix]).lowercased() + String(characters[upperPrefix...])
        }
        return escaped(lowered)
    }

    static func trimmingUnderscores(_ name: String) -> String {
        let trimmed = name.drop { $0 == "_" }
        return trimmed.isEmpty ? name : String(trimmed)
    }

    static let keywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
        "internal", "let", "open", "operator", "private", "protocol", "public", "rethrows", "static", "struct",
        "subscript", "typealias", "var", "break", "case", "continue", "default", "defer", "do", "else",
        "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where", "while", "as", "Any",
        "catch", "false", "is", "nil", "super", "self", "Self", "throw", "throws", "true", "try", "Type",
    ]

    static func escaped(_ name: String) -> String {
        keywords.contains(name) ? "`\(name)`" : name
    }
}
