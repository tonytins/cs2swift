@testable import CS2Swift
import Testing

/// Translates one C# file (wrapped in a static class unless it declares its own types) and
/// returns the Swift, or the first error.
private func swift(_ csharp: String, wrap: Bool = true) -> (code: String, warnings: [String], error: String?) {
    let source = wrap ? "public static class T\n{\n\(csharp)\n}\n" : csharp
    let result = Transpiler.transpile([("T.cs", source)])
    return (result.files.first?.swift ?? "", result.warnings.map(\.warning.message), result.errors.first?.error.message)
}

private func expectSwift(_ csharp: String, contains expected: [String], wrap: Bool = true, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
    let output = swift(csharp, wrap: wrap)
    #expect(output.error == nil, "\(output.error ?? "")", sourceLocation: sourceLocation)
    for fragment in expected {
        #expect(output.code.contains(fragment), "missing \(fragment) in:\n\(output.code)", sourceLocation: sourceLocation)
    }
}

// MARK: Declarations

@Test func staticClassesBecomeEnumsWithTypedConstants() {
    expectSwift("    private const int Gap = 10;\n    public const float Zoom = 0.25f;", contains: [
        "public enum T {", "private static let gap: Int = 10", "public static let zoom: Float = 0.25",
    ])
}

@Test func classesKeepTheirShape() {
    expectSwift("""
    public sealed class Box
    {
        private readonly int _size;
        private readonly List<string> _items = [];
        public Box(int size) { _size = size; }
        public int Size => _size;
        public bool Open { get; private set; }
        public void Add(string item) => _items.Add(item);
    }
    """, contains: [
        "public final class Box {", "private let _size: Int", "private var items: [String] = []",
        "public init(_ size: Int) {", "self._size = size", "public var size: Int {",
        "public private(set) var `open`: Bool = false", "items.append(item)",
    ], wrap: false)
}

@Test func privateFieldsKeepTheirUnderscoreOnlyWhenTheyCollide() {
    expectSwift("""
    public sealed class Field
    {
        private string _text = "";
        private int _count;
        public string Text => _text;
    }
    """, contains: ["private var _text: String = \"\"", "private var count: Int = 0", "public var text: String {"], wrap: false)
}

@Test func nestedTypesAreSpelledInFull() {
    expectSwift("""
    public sealed class Frame
    {
        public enum Action { None, Close }
        public Action Update() => Action.Close;
    }
    """, contains: ["public enum Action: Int {", "case none", "public func update() -> Frame.Action {", "Frame.Action.close"], wrap: false)
}

@Test func defaultArgumentsInlinePrivateConstants() {
    expectSwift("    private const int Size = 20;\n    public static int Measure(int size = Size) => size;", contains: [
        "public static func measure(_ size: Int = 20) -> Int {",
    ])
}

@Test func docCommentsBecomeMarkdown() {
    expectSwift("""
        /// <summary>Draws <paramref name="text"/> with <see cref="Theme"/>.</summary>
        /// <returns>The width.</returns>
        public static int Draw(string text) => 0;
    """, contains: ["/// Draws `text` with `Theme`.", "/// - Returns: The width."])
}

// MARK: Statements

@Test func countingLoopsBecomeRangesOrStrides() {
    expectSwift("""
        public static void F(List<int> xs, int n)
        {
            for (var i = 0; i < xs.Count; i++) { }
            for (var i = n - 1; i >= 0; i--) { }
            for (var i = 2; i < n; i += 2) { }
        }
    """, contains: ["for i in 0..<xs.count {", "for i in stride(from: n - 1, through: 0, by: -1) {", "for i in stride(from: 2, to: n, by: 2) {"])
}

@Test func otherLoopsKeepTheirIncrementInADefer() {
    expectSwift("""
        public static void F()
        {
            for (var key = Next(); key != 0; key = Next()) { if (key == 1) continue; }
        }
        private static int Next() => 0;
    """, contains: ["var key = next()", "while key != 0 {", "defer {", "key = next()", "continue"])
}

@Test func switchesDropBreaksAndGainADefault() {
    expectSwift("""
        public static int F(int x)
        {
            switch (x)
            {
                case 1:
                case 2:
                    return 3;
                case 4:
                    break;
            }
            return 0;
        }
    """, contains: ["switch x {", "case 1, 2:", "return 3", "case 4:\n            break", "default:\n            break"])
}

@Test func localsThatNeverChangeAreLet() {
    expectSwift("""
        public static int F()
        {
            var a = 1;
            var b = 2;
            b += a;
            return b;
        }
    """, contains: ["let a = 1", "var b = 2"])
}

// MARK: Numbers

@Test func intsMeetingFloatsArePromotedAsCSharpDoes() {
    expectSwift("""
        public static float F(int width, float x) => x - width + (width / 2);
    """, contains: ["x - Float(width) + Float(width / 2)"])
}

@Test func floatToIntCastsSaturate() {
    expectSwift("    public static int F(float x) => (int)(x * 2);", contains: ["Int(saturating: x * 2)"])
}

@Test func literalOnlyFloatLocalsGetAType() {
    expectSwift("    public static void F() { var s = 1f / 3f; }", contains: ["let s: Float = 1.0 / 3.0"])
}

// MARK: Null checks

@Test func nullChecksNarrowWhatFollows() {
    expectSwift("""
        public static bool F(IReadOnlyList<bool>? on, int i) => on is null || i >= on.Count || on[i];
    """, contains: ["on == nil || i >= on!.count || on![i]"])
}

@Test func earlyReturnsNarrowTheRestOfTheBlock() {
    expectSwift("""
        public static int F(string? s)
        {
            if (s is null) return 0;
            return s.Length;
        }
    """, contains: ["return s!.count"])
}

@Test func bindingPatternsBecomeIfLet() {
    expectSwift("""
        public static int F(string? s)
        {
            if (s is { } text && text.Length > 1) return text.Length;
            return 0;
        }
    """, contains: ["if let text = s, text.count > 1 {"])
}

@Test func coalescingANonOptionalDropsTheFallback() {
    expectSwift("    public static string F(string s) => s ?? string.Empty;", contains: ["public static func f(_ s: String) -> String {\n        s\n"])
}

// MARK: Raylib-cs

@Test func raylibCallsLoseTheirPrefixAndKeepCSharpConversions() {
    expectSwift("""
        public static void F(Vector2 mouse, int x)
        {
            if (Raylib.IsKeyPressed(KeyboardKey.Escape)) Raylib.DrawCircle(x, x, 6, Color.RayWhite);
            var w = Raylib.GetScreenWidth();
        }
    """, contains: ["if IsKeyPressed(KeyboardKey.escape) {", "DrawCircle(x, x, 6, Color.rayWhite)", "let w = Int(GetScreenWidth())"])
}

@Test func raylibCsEnumNamesMapToRaylibSwift() {
    expectSwift("    public static bool F() => Raylib.IsWindowState(ConfigFlags.BorderlessWindowMode);", contains: [
        "IsWindowState(ConfigFlags.borderlessWindowedMode)",
    ])
}

@Test func raylibStructsAreBuiltWithEveryField() {
    expectSwift("""
        public static Rectangle F(float x, int w) => new Rectangle { X = x, Width = w };
        public static Color G() => new() { R = 1, G = 2, B = 3, A = 255 };
    """, contains: ["Rectangle(x: x, y: 0, width: Float(w), height: 0)", "Color(r: 1, g: 2, b: 3, a: 255)"])
}

@Test func withExpressionsUseTheSupportFunction() {
    expectSwift("    public static Rectangle F(Rectangle r) => r with { Height = 30 };", contains: ["with(r) { $0.height = 30 }"])
}

@Test func unknownRaylibFunctionsAreErrors() {
    #expect(swift("    public static void F() => Raylib.NoSuchThing();").error?.contains("isn't in raylib") == true)
}

// MARK: Library calls

@Test func stringBuildersBecomeStrings() {
    expectSwift("""
    public sealed class Box
    {
        private readonly StringBuilder _text = new();
        public void F(char c) { _text.Append(c); _text.Length--; }
        public string Text => _text.ToString();
    }
    """, contains: ["private var _text: String = \"\"", "_text.append(c)", "_text.removeLast()", "public var text: String {\n        _text\n"], wrap: false)
}

@Test func argumentGuardsBecomeAssertions() {
    expectSwift("""
        public static void F(int size, string text)
        {
            ArgumentOutOfRangeException.ThrowIfNegativeOrZero(size);
            ArgumentNullException.ThrowIfNull(text);
        }
    """, contains: ["assert(size > 0, \"size must be positive\")"])
    #expect(!swift("    public static void F(string text) { ArgumentNullException.ThrowIfNull(text); }").code.contains("text != nil"))
}

@Test func rangesOnStringsBecomePrefixes() {
    expectSwift("    public static string F(string s, int n) => s[..n] + \"...\";", contains: ["String(s.prefix(n)) + \"...\""])
}

// MARK: What it refuses

@Test(arguments: [
    ("    public static void F() { throw new Exception(); }", "throw"),
    ("    public static void F() { Use(out var x); }", "out variable"),
    ("    public static T Make<T>() => default;", "generic"),
    ("    public static void F() { try { } catch { } }", "try"),
    ("    public event Action Changed;", "events"),
])
func unsupportedConstructsAreErrors(csharp: String, message: String) {
    let output = swift(csharp)
    #expect(output.error?.contains(message) == true, "\(output.error ?? "no error")")
    #expect(output.code.isEmpty)
}

@Test func usingTheObjectBeforeItsFieldsAreSetIsFlagged() {
    let output = swift("""
    public sealed class Ticker
    {
        private readonly Func<int> _next;
        public Ticker() { _next = Next; }
        private int Next() => 1;
    }
    """, wrap: false)
    #expect(output.warnings.contains { $0.contains("won't let this constructor use Next before _next") })
}

@Test func translationsAreDeterministic() {
    let source = "    public static int F(int a, float b) => (int)(a + b);"
    #expect(swift(source).code == swift(source).code)
}
