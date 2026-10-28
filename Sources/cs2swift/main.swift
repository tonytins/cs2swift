// Usage: cs2swift -o <output-dir> [--reference <file-or-dir>]... <file-or-dir>...
//
// Translates each C# file to a Swift file of the same name in the output directory, and
// writes CSharpSupport.swift beside them. References are read for their declarations only.
// Errors and warnings go to standard error; the exit status is 1 if any file failed.

import CS2Swift
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\nusage: cs2swift -o <output-dir> [--reference <path>]... <path>...\n".utf8))
    exit(2)
}

var output: String?
var inputs: [String] = []
var references: [String] = []
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "-o", "--output":
        guard let value = arguments.popFirst() else { fail("\(argument) needs a directory") }
        output = value
    case "--reference":
        guard let value = arguments.popFirst() else { fail("--reference needs a path") }
        references.append(value)
    default:
        if argument.hasPrefix("-") { fail("unknown option \(argument)") }
        inputs.append(argument)
    }
}
guard let output else { fail("no output directory") }
guard !inputs.isEmpty else { fail("no input files") }

/// The C# files at a path: the file itself, or every .cs file under a directory, in order.
func csharpFiles(at path: String) -> [String] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { fail("\(path) doesn't exist") }
    guard isDirectory.boolValue else { return [path] }
    let files = FileManager.default.enumerator(atPath: path)?.compactMap { $0 as? String } ?? []
    return files.filter { $0.hasSuffix(".cs") && !$0.contains("/obj/") && !$0.contains("/bin/") }.sorted().map { "\(path)/\($0)" }
}

func read(_ paths: [String]) -> [Transpiler.Source] {
    paths.flatMap(csharpFiles).map { path in
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("couldn't read \(path)") }
        return (path, text)
    }
}

let result = Transpiler.transpile(read(inputs), references: read(references))

do {
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    for file in result.files {
        try file.swift.write(toFile: "\(output)/\(file.name)", atomically: true, encoding: .utf8)
    }
    try Transpiler.supportSource.write(toFile: "\(output)/\(Transpiler.supportFileName)", atomically: true, encoding: .utf8)
} catch {
    fail("couldn't write to \(output): \(error.localizedDescription)")
}

for (path, warning) in result.warnings {
    FileHandle.standardError.write(Data("\(path):\(warning)\n".utf8))
}
for (path, error) in result.errors {
    FileHandle.standardError.write(Data("\(path):\(error.location): error: \(error.message)\n".utf8))
}
print("Translated \(result.files.count) of \(result.files.count + result.errors.count) files, with \(result.warnings.count) warnings.")
exit(result.errors.isEmpty ? 0 : 1)
