/// Turns C# comments into Swift ones: XML doc comments become Swift's Markdown doc comments.
enum Comments {
    /// The Swift comment lines, without indentation, for the comments before a declaration or
    /// statement. The lexer leaves doc comment lines (`///`) with a leading `/`.
    static func translate(_ comments: [String]) -> [String] {
        var result: [String] = []
        var doc: [String] = []
        func flushDoc() {
            guard !doc.isEmpty else { return }
            result.append(contentsOf: documentation(doc.joined(separator: "\n")).map { $0.isEmpty ? "///" : "/// " + $0 })
            doc = []
        }
        for comment in comments {
            if comment.hasPrefix("/") {
                doc.append(String(comment.dropFirst()))
            } else {
                flushDoc()
                result.append(comment.isEmpty ? "//" : "//" + (comment.hasPrefix(" ") ? comment : " " + comment))
            }
        }
        flushDoc()
        return result
    }

    private static func documentation(_ xml: String) -> [String] {
        var text = xml
        text.replace(#/<see\s+langword="null"\s*/>/#, with: "`nil`")
        text.replace(#/<see\s+langword="(\w+)"\s*/>/#) { "`\($0.output.1)`" }
        text.replace(#/<see\s+cref="(?:\w:)?([^"]+)"\s*/>/#) { "`\($0.output.1)`" }
        text.replace(#/<(?:paramref|typeparamref)\s+name="([^"]+)"\s*/>/#) { "`\($0.output.1)`" }
        text.replace(#/<c>(.*?)</c>/#) { "`\($0.output.1)`" }
        text.replace(#/<param\s+name="([^"]+)">((?s).*?)</param>/#) { "- Parameter \($0.output.1): \($0.output.2)" }
        text.replace(#/<returns>((?s).*?)</returns>/#) { "- Returns: \($0.output.1)" }
        text.replace(#/<exception\s+cref="(?:\w:)?([^"]+)">((?s).*?)</exception>/#) {
            "- Note: Debug builds assert, where the C# original throws `\($0.output.1)`, when: \($0.output.2)"
        }
        text.replace(#/<inheritdoc\s*/>/#, with: "")
        text.replace(#/</?(?:summary|remarks|para)>/#, with: "")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            String(line.hasPrefix(" ") ? line.dropFirst() : line[...])
        }
        while lines.first?.trimmingWhitespace().isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingWhitespace().isEmpty == true { lines.removeLast() }
        return lines.map { $0.trimmingWhitespace().isEmpty ? "" : $0 }
    }
}

extension StringProtocol {
    func trimmingWhitespace() -> String {
        String(drop { $0.isWhitespace }.reversed().drop { $0.isWhitespace }.reversed())
    }
}
