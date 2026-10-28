// The C# syntax tree: only the shapes cs2swift reads. The parser reports anything else as
// an error, so a construct missing here can't be skipped silently.

/// A type as written: `int`, `List<string>`, `Vector2?`, `(int, float)`.
indirect enum TypeSyntax: Equatable, Sendable {
    case named(String, [TypeSyntax])
    case nullable(TypeSyntax)
    case array(TypeSyntax)
    case tuple([TypeSyntax])

    var name: String? {
        if case .named(let name, _) = self { return name }
        return nil
    }
}

/// A parsed C# file.
struct SourceFile: Sendable {
    var path: String
    var types: [TypeDeclaration]
}

/// A class, struct, interface, enum, or record.
struct TypeDeclaration: Sendable {
    enum Kind: Sendable { case `class`, `struct`, interface, `enum` }

    var kind: Kind
    var name: String
    var modifiers: Set<String>
    var attributes: [String]
    var bases: [TypeSyntax]
    var members: [Member]
    var enumCases: [EnumCase]
    var comments: [String]
    var location: SourceLocation
}

/// One case of a C# enum.
struct EnumCase: Sendable {
    var name: String
    var value: Expression?
    var comments: [String]
}

/// A member of a type.
enum Member: Sendable {
    case field(Field)
    case property(Property)
    case method(Method)
    case constructor(Method)
    case type(TypeDeclaration)

    var location: SourceLocation {
        switch self {
        case .field(let field): field.location
        case .property(let property): property.location
        case .method(let method), .constructor(let method): method.location
        case .type(let type): type.location
        }
    }
}

/// A field, or several declared together (`int a, b;`).
struct Field: Sendable {
    var modifiers: Set<String>
    var type: TypeSyntax
    var declarators: [(name: String, initializer: Expression?)]
    var comments: [String]
    var location: SourceLocation
}

/// A property, auto-implemented or with accessor bodies.
struct Property: Sendable {
    var modifiers: Set<String>
    var type: TypeSyntax
    var name: String
    var getter: Accessor?
    var setter: Accessor?
    var initializer: Expression?
    var comments: [String]
    var location: SourceLocation
}

/// A property accessor.
struct Accessor: Sendable {
    enum Body: Sendable {
        case automatic
        case expression(Expression)
        case block([Statement])
    }

    var modifiers: Set<String>
    var body: Body
    /// `init` in place of `set`.
    var isInit: Bool
}

/// A method or constructor.
struct Method: Sendable {
    enum Body: Sendable {
        case none
        case expression(Expression)
        case block([Statement])
    }

    var modifiers: Set<String>
    /// `nil` for a constructor.
    var returnType: TypeSyntax?
    var name: String
    var parameters: [Parameter]
    var body: Body
    var comments: [String]
    var location: SourceLocation
}

/// A method parameter.
struct Parameter: Sendable {
    var modifier: String?
    var type: TypeSyntax
    var name: String
    var defaultValue: Expression?
}

/// A statement, with the comments written before it.
struct Statement: Sendable {
    indirect enum Kind: Sendable {
        case block([Statement])
        /// `var x = 1;` (type `nil`) or `int x = 1, y;`.
        case local(type: TypeSyntax?, [(name: String, initializer: Expression?)])
        /// `var (a, b) = e;`
        case deconstruct(names: [String], Expression)
        case expression(Expression)
        case `if`(Expression, Statement, Statement?)
        case `while`(Expression, Statement)
        case doWhile(Statement, Expression)
        case `for`(initializers: [Statement], condition: Expression?, increments: [Expression], body: Statement)
        case foreach(name: String, Expression, Statement)
        case `switch`(Expression, [SwitchSection])
        case `return`(Expression?)
        case `break`
        case `continue`
        case empty
    }

    var kind: Kind
    var comments: [String]
    var location: SourceLocation
}

/// `case A: case B: statements`
struct SwitchSection: Sendable {
    /// The case labels; `nil` stands for `default`.
    var labels: [Expression?]
    var body: [Statement]
}

/// A call argument.
struct Argument: Sendable {
    var name: String?
    /// `ref`, `out`, or `in`.
    var modifier: String?
    var value: Expression
}

/// A pattern after `is`.
indirect enum Pattern: Sendable {
    case null
    case not(Pattern)
    case relational(String, Expression)
    case and(Pattern, Pattern)
    case or(Pattern, Pattern)
    case constant(Expression)
    /// `{ } name`: not null, and bound to a name.
    case binding(String)
    /// `{ }`: not null.
    case notNull
}

/// An expression, with where it starts.
struct Expression: Sendable {
    indirect enum Kind: Sendable {
        case integer(String)
        case real(String)
        case string(String)
        case interpolated([InterpolatedPart])
        case character(String)
        case boolean(Bool)
        case null
        case this
        case name(String)
        case member(Expression, String, nullConditional: Bool)
        case call(Expression, [Argument])
        case index(Expression, [Expression], nullConditional: Bool)
        case unary(String, Expression)
        case postfix(String, Expression)
        case binary(String, Expression, Expression)
        case assign(String, Expression, Expression)
        case conditional(Expression, Expression, Expression)
        case cast(TypeSyntax, Expression)
        /// `new T(args) { A = x }`; type `nil` for target-typed `new()`.
        case new(TypeSyntax?, [Argument], initializers: [(String, Expression)]?)
        case collection([Expression])
        case lambda([String], LambdaBody)
        case `is`(Expression, Pattern)
        case with(Expression, [(String, Expression)])
        case tuple([Expression])
        case range(Expression?, Expression?)
        case fromEnd(Expression)
        case `default`(TypeSyntax?)
        case nameof(String)
        /// Arms with a `nil` pattern for `_`.
        case switchExpression(Expression, [(Pattern?, Expression)])
        /// A predefined type used as a receiver: `int.MaxValue`, `string.Empty`.
        case typeName(String)
        /// Parentheses as written, kept so the output keeps them.
        case parenthesized(Expression)
    }

    /// The expression inside any parentheses.
    var unwrapped: Expression {
        if case .parenthesized(let inner) = kind { return inner.unwrapped }
        return self
    }

    var kind: Kind
    var location: SourceLocation
}

/// A piece of a parsed interpolated string.
enum InterpolatedPart: Sendable {
    case text(String)
    case hole(Expression)
}

/// A lambda's body.
enum LambdaBody: Sendable {
    case expression(Expression)
    case block([Statement])
}
