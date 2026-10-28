#!/usr/bin/env bash
# Translates CityLimits' reusable interface files and builds the result against raylib-swift.
#
# Usage: scripts/check-citylimits.sh <CityLimits checkout> <raylib-swift checkout> [work-dir]
#
# The work directory (default: a new temporary one) gets a Swift package holding the output,
# which is left in place to read. Exits non-zero if translation or the build fails.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
citylimits="$(cd "${1:?CityLimits checkout}" && pwd)"
raylib_swift="$(cd "${2:?raylib-swift checkout}" && pwd)"
work="${3:-$(mktemp -d)}"
interface="$citylimits/CityLimits.Interface"

# UI/LoadingScreen.cs is left out until its constructor stops handing NextPhrase to the
# ticker before every field is set, which Swift refuses (cs2swift warns about it).
files=(
    UI/IMovableWindow.cs UI/WindowPlacement.cs UI/TextWrap.cs UI/ButtonRow.cs UI/TextField.cs
    UI/TextArea.cs UI/WindowFrame.cs UI/ConfirmPanel.cs UI/NoticePanel.cs
    Rendering/Camera.cs Rendering/Theme.cs
)

rm -rf "$work/Sources"
mkdir -p "$work/Sources/Interface"
cat > "$work/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CityLimitsInterface",
    dependencies: [.package(path: "$raylib_swift")],
    targets: [.target(name: "Interface", dependencies: [.product(name: "Raylib", package: "raylib-swift")])]
)
EOF

swift build --package-path "$root" --product cs2swift >/dev/null
status=0
cp "$root/scripts/citylimits-stubs.cs" "$work/Stubs.cs"
# From inside the project, so the generated headers name each file relative to it.
(cd "$interface" && "$root/.build/debug/cs2swift" -o "$work/Sources/Interface" "${files[@]}" "$work/Stubs.cs") || status=$?
swift build --package-path "$work" 2>&1 | grep -E "error|warning:" | grep -v "CRaylib/raylib" || true
swift build --package-path "$work" >/dev/null 2>&1 || status=1
echo "Output in $work/Sources/Interface"
exit "$status"
