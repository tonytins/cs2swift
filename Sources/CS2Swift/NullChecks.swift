/// Recognizes C#'s null checks, so the emitter can follow what they prove.
enum NullChecks {
    /// A path naming what a check tests (`x`, `this._stroke`, `a.B`), or `nil` if the
    /// expression isn't a plain name or member chain.
    static func key(_ expression: Expression) -> String? {
        switch expression.unwrapped.kind {
        case .name(let name): name
        case .this: "this"
        case .member(let receiver, let name, false): key(receiver).map { $0 == "this" ? name : "\($0).\(name)" }
        default: nil
        }
    }

    /// `x is null`, `x == null`, `x is not null`, `x != null`, `x is { }`, and `x is { } y`.
    static func check(_ expression: Expression) -> (key: String, isNull: Bool)? {
        switch expression.unwrapped.kind {
        case .is(let subject, let pattern):
            guard let key = key(subject) else { return nil }
            switch pattern {
            case .null: return (key, true)
            case .not(.null), .notNull, .binding: return (key, false)
            default: return nil
            }
        case .binary(let op, let a, let b) where op == "==" || op == "!=":
            if case .null = b.unwrapped.kind, let key = key(a) { return (key, op == "==") }
            if case .null = a.unwrapped.kind, let key = key(b) { return (key, op == "==") }
            return nil
        default:
            return nil
        }
    }

    /// The operands of top-level `&&`s.
    static func conjuncts(_ expression: Expression) -> [Expression] {
        if case .binary("&&", let a, let b) = expression.kind { return conjuncts(a) + conjuncts(b) }
        return [expression]
    }

    /// The null checks among the operands of top-level `||`s.
    static func disjuncts(_ expression: Expression) -> [(key: String, isNull: Bool)] {
        if case .binary("||", let a, let b) = expression.kind { return disjuncts(a) + disjuncts(b) }
        return check(expression).map { [$0] } ?? []
    }
}
