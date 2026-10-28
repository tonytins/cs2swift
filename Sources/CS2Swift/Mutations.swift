/// Which locals a method changes, so the emitter can declare the rest with `let`.
struct Mutations {
    /// Names assigned to, incremented, or passed by `ref` or `out`.
    private(set) var reassigned: Set<String> = []
    /// Names changed through a member or element (`a.X = 1`, `a[0] = 1`) or a mutating call
    /// (`list.Add(x)`). These need `var` only when they hold a value type.
    private(set) var mutatedThrough: Set<String> = []

    static let mutatingMethods: Set<String> = [
        "Add", "AddRange", "Append", "Clear", "Insert", "Remove", "RemoveAt", "RemoveAll", "RemoveRange", "Reverse", "Sort",
    ]

    init(statements: [Statement]) {
        for statement in statements { visit(statement) }
    }

    init(expression: Expression) {
        visit(expression)
    }

    /// Every name an expression reads.
    static func names(in expression: Expression) -> Set<String> {
        var collector = NameCollector()
        collector.visit(expression)
        return collector.names
    }

    /// Every name a statement's expressions read.
    static func names(in statement: Statement) -> Set<String> {
        var collector = NameCollector()
        collector.visit(statement)
        return collector.names
    }

    private static func root(_ expression: Expression) -> String? {
        switch expression.unwrapped.kind {
        case .name(let name): name
        case .member(let receiver, _, _), .index(let receiver, _, _): root(receiver)
        default: nil
        }
    }

    private mutating func target(_ expression: Expression) {
        switch expression.unwrapped.kind {
        case .name(let name): reassigned.insert(name)
        case .tuple(let elements): elements.forEach { target($0) }
        default:
            if let root = Self.root(expression) { mutatedThrough.insert(root) }
        }
    }

    private mutating func visit(_ statement: Statement) {
        switch statement.kind {
        case .block(let statements): statements.forEach { visit($0) }
        case .local(_, let declarators): declarators.compactMap(\.initializer).forEach { visit($0) }
        case .deconstruct(_, let value), .expression(let value): visit(value)
        case .if(let condition, let then, let otherwise):
            visit(condition)
            visit(then)
            if let otherwise { visit(otherwise) }
        case .while(let condition, let body), .doWhile(let body, let condition):
            visit(condition)
            visit(body)
        case .for(let initializers, let condition, let increments, let body):
            initializers.forEach { visit($0) }
            if let condition { visit(condition) }
            increments.forEach { visit($0) }
            visit(body)
        case .foreach(_, let sequence, let body):
            visit(sequence)
            visit(body)
        case .switch(let subject, let sections):
            visit(subject)
            sections.flatMap(\.body).forEach { visit($0) }
        case .return(let value): if let value { visit(value) }
        case .break, .continue, .empty: break
        }
    }

    private mutating func visit(_ expression: Expression) {
        switch expression.kind {
        case .assign(_, let target, let value):
            self.target(target)
            visit(target)
            visit(value)
        case .postfix(let op, let operand), .unary(let op, let operand):
            if op == "++" || op == "--" { target(operand) }
            visit(operand)
        case .call(let callee, let arguments):
            if case .member(let receiver, let method, _) = callee.unwrapped.kind, Self.mutatingMethods.contains(method),
               let root = Self.root(receiver) {
                mutatedThrough.insert(root)
            }
            visit(callee)
            for argument in arguments {
                if argument.modifier == "ref" || argument.modifier == "out" { target(argument.value) }
                visit(argument.value)
            }
        case .member(let receiver, _, _): visit(receiver)
        case .index(let receiver, let indices, _):
            visit(receiver)
            indices.forEach { visit($0) }
        case .binary(_, let left, let right):
            visit(left)
            visit(right)
        case .conditional(let a, let b, let c):
            visit(a)
            visit(b)
            visit(c)
        case .cast(_, let operand), .fromEnd(let operand), .parenthesized(let operand), .is(let operand, _):
            visit(operand)
        case .new(_, let arguments, let initializers):
            arguments.forEach { visit($0.value) }
            initializers?.forEach { visit($0.1) }
        case .collection(let elements), .tuple(let elements): elements.forEach { visit($0) }
        case .lambda(_, let body):
            switch body {
            case .expression(let value): visit(value)
            case .block(let statements): statements.forEach { visit($0) }
            }
        case .with(let receiver, let changes):
            visit(receiver)
            changes.forEach { visit($0.1) }
        case .range(let a, let b):
            if let a { visit(a) }
            if let b { visit(b) }
        case .interpolated(let parts):
            for case .hole(let value) in parts { visit(value) }
        case .switchExpression(let subject, let arms):
            visit(subject)
            arms.forEach { visit($0.1) }
        case .integer, .real, .string, .character, .boolean, .null, .this, .name, .default, .nameof, .typeName:
            break
        }
    }
}

private struct NameCollector {
    var names: Set<String> = []

    mutating func visit(_ expression: Expression) {
        switch expression.kind {
        case .name(let name): names.insert(name)
        case .member(let receiver, _, _): visit(receiver)
        case .call(let callee, let arguments):
            visit(callee)
            arguments.forEach { visit($0.value) }
        case .index(let receiver, let indices, _):
            visit(receiver)
            indices.forEach { visit($0) }
        case .binary(_, let left, let right), .assign(_, let left, let right):
            visit(left)
            visit(right)
        case .unary(_, let operand), .postfix(_, let operand), .cast(_, let operand), .parenthesized(let operand), .fromEnd(let operand):
            visit(operand)
        case .conditional(let a, let b, let c):
            visit(a)
            visit(b)
            visit(c)
        case .new(_, let arguments, let initializers):
            arguments.forEach { visit($0.value) }
            initializers?.forEach { visit($0.1) }
        case .collection(let elements), .tuple(let elements): elements.forEach { visit($0) }
        case .lambda(_, .expression(let value)): visit(value)
        case .interpolated(let parts):
            for case .hole(let value) in parts { visit(value) }
        case .is(let subject, _): visit(subject)
        case .with(let receiver, let changes):
            visit(receiver)
            changes.forEach { visit($0.1) }
        default: break
        }
    }

    mutating func visit(_ statement: Statement) {
        switch statement.kind {
        case .expression(let value), .deconstruct(_, let value): visit(value)
        case .return(let value?): visit(value)
        case .local(_, let declarators): declarators.compactMap(\.initializer).forEach { visit($0) }
        case .if(let condition, let then, let otherwise):
            visit(condition)
            visit(then)
            if let otherwise { visit(otherwise) }
        case .block(let statements): statements.forEach { visit($0) }
        default: break
        }
    }
}
