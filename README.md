# cs2swift

Translates C# written against [Raylib-cs](https://github.com/raylib-cs/raylib-cs) into Swift
written against [raylib-swift](https://github.com/tonytins/raylib-swift).

It exists to share code between two projects: [CityLimits](https://github.com/tonytins/citylimits),
a C# game on Raylib-cs, and SimsCraft, whose client is Swift on raylib-swift. Re-run it when
the C# changes, and the Swift follows.

```sh
swift run cs2swift -o Generated/ --reference ../CityLimits/CityLimits.Core UI/ButtonRow.cs UI/TextField.cs
```

Each C# file becomes a Swift file of the same name, and `CSharpSupport.swift` is written
beside them. `--reference` files and directories are read only for what they declare, so
calls into code that isn't being translated still get the right conversions.

## How it works

cs2swift parses the subset of C# the shared code uses, works out each expression's type
from the files it reads and from a table of raylib's API, and writes Swift that does what
the C# did:

| C# | Swift |
| --- | --- |
| `Raylib.DrawText(text, x, y, 20, Color.RayWhite)` | `DrawText(text, x, y, 20, Color.rayWhite)` |
| `KeyboardKey.KpEnter`, `ConfigFlags.ResizableWindow` | `KeyboardKey.kpEnter`, `ConfigFlags.windowResizable` |
| `Raylib.GetScreenWidth()` (no `Int` overload) | `Int(GetScreenWidth())` |
| `right - width` (`float` minus `int`) | `right - Float(width)` |
| `(int)bounds.X` | `Int(saturating: bounds.x)` |
| `new Rectangle { X = x, Width = w }` | `Rectangle(x: x, y: 0, width: Float(w), height: 0)` |
| `bounds with { Height = 30 }` | `with(bounds) { $0.height = 30 }` |
| `for (var i = n - 1; i >= 0; i--)` | `for i in stride(from: n - 1, through: 0, by: -1)` |
| `enabled is null \|\| enabled[i]` | `enabled == nil \|\| enabled![i]` |
| `if (logo is { } l && ...)` | `if let l = logo, ...` |
| `public static class`, `sealed class` | `public enum`, `public final class` |
| `StringBuilder`, `List<T>`, `IReadOnlyList<T>` | `String`, `[T]` |
| `/// <summary>` doc comments | `///` Markdown doc comments |

Names become Swift's: `IsDragging` is `isDragging`, `_title` is `title` (or `_title` when
a `Title` property would collide). Parameters are unlabeled (`_ name: T`), so calls keep
C#'s shape and named arguments are put in order.

### What it refuses

Anything outside the subset is an error at its line, and nothing is written for that file:
exceptions (`throw`, `try`), `out` variables, generics, records, events, LINQ, `async`,
inheritance from classes, and statement-bodied lambdas, among others. Refusing beats
guessing: a wrong translation that compiles is worse than one that doesn't.

### What to check by hand

Some translations compile but can behave differently. Each one prints a warning with its
line:

- **`.Value` and `!`** on a nullable become force unwraps, which trap on `nil` where C#
  throws. Unwraps cs2swift adds itself after a null check (`x is null || x.Count`) are safe.
- **`ReferenceEquals`** on strings becomes `==`, which compares contents.
- **Floats in interpolated strings** print as `1.0` where C# prints `1`.
- **`&` and `|` on bools** become `&&` and `||`, which skip the right side when the left decides.
- **Constructors** that use the object before every field has a value: Swift's two-phase
  initialization refuses them, so reorder the C#.
- **Mutable statics** become `nonisolated(unsafe)`, which isn't safe across threads.

And some differences are always there:

- **Integer overflow traps** in Swift where C# wraps.
- **Argument guards** (`ArgumentOutOfRangeException.ThrowIfNegativeOrZero`) become
  `assert`s, which only debug builds check.
- **Lists are values** in Swift. C# code that relies on two variables sharing one `List`
  won't behave the same.
- `Math.Clamp` with its bounds the wrong way round gives the high bound instead of throwing.

## Keeping it in sync

Generated files carry a header saying so. Don't edit them: change the C# and run cs2swift
again, and put Swift-only code in files of its own (extensions work well). When a new C#
construct shows up, cs2swift stops with an error that names it, so a sync never quietly
drops code.

`scripts/check-citylimits.sh <CityLimits> <raylib-swift> [work-dir]` translates CityLimits'
reusable interface files and builds the result against raylib-swift. CI runs it against
both projects' main branches, so a change on either side that breaks the translation
shows up there.

### Raylib data

`Sources/CS2Swift/Generated/RaylibData.swift` is generated from raylib-swift's `raylib.h`
and `CRaylib.apinotes`, and from Raylib-cs's enums, which name some cases differently from
raylib (`ConfigFlags.ResizableWindow` is raylib's `FLAG_WINDOW_RESIZABLE`). Regenerate it when
either updates:

```sh
scripts/generate-raylib-data.py <raylib-swift checkout> <Raylib-cs checkout>
```

## Requirements

Swift 6.0 or later. The output needs raylib-swift with its `Int` overloads and vector
operators.

## License

zlib. See [LICENSE](LICENSE).
