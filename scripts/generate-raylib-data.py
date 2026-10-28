#!/usr/bin/env python3
"""Writes Sources/CS2Swift/Generated/RaylibData.swift: what cs2swift knows about raylib.

Usage: scripts/generate-raylib-data.py <raylib-swift checkout> <Raylib-cs checkout>

From raylib-swift it reads the vendored raylib.h (function signatures, struct fields, enum
values) and the generated CRaylib.apinotes (the Swift name of every enum case). From
Raylib-cs it reads the enums, to map each Raylib-cs member to raylib-swift's case by value.
Rerun it when either side updates.
"""

import pathlib
import re
import sys

if len(sys.argv) != 3:
    sys.exit(__doc__)
raylib_swift = pathlib.Path(sys.argv[1])
raylib_cs = pathlib.Path(sys.argv[2])
header_path = raylib_swift / "Sources/CRaylib/raylib/raylib.h"
apinotes_path = raylib_swift / "Sources/CRaylib/include/CRaylib.apinotes"
cs_types = raylib_cs / "Raylib-cs/types"
for path in (header_path, apinotes_path, cs_types):
    if not path.exists():
        sys.exit(f"error: {path} doesn't exist")

header = header_path.read_text()
raylib_version = re.search(r'#define RAYLIB_VERSION\s+"([^"]+)"', header).group(1)
cs_props = raylib_cs / "Directory.Build.props"
cs_version = re.search(r"<RaylibCsVersion>([^<]+)</RaylibCsVersion>", cs_props.read_text()) if cs_props.exists() else None
cs_version = cs_version.group(1) if cs_version else "unknown"

# Typedef aliases such as `typedef Texture Texture2D;`.
aliases = dict((m.group(2), m.group(1)) for m in re.finditer(r"^typedef (\w+) (\w+);", header, re.M))

SCALARS = {
    "int": "Int", "unsigned int": "UInt32", "float": "Float", "double": "Double", "bool": "Bool",
    "char": "CChar", "unsigned char": "UInt8", "unsigned short": "UInt16", "short": "Int16",
    "long": "Int", "void": "Void", "const char *": "String",
}


def swift_type(c_type):
    c_type = " ".join(c_type.replace("*", " * ").split()).replace(" *", " *")
    c_type = re.sub(r"\s*\*", " *", c_type).strip()
    if c_type in SCALARS:
        return SCALARS[c_type]
    if c_type.endswith(" *") and not c_type.endswith("* *"):
        base = c_type[:-2].removeprefix("const ").strip()
        return "Pointer<" + (SCALARS.get(base) or base) + ">"
    if re.fullmatch(r"\w+", c_type):
        return c_type
    return "?"


# Functions: `RLAPI <type> <name>(<params>);`
functions = {}
int_result_only = []
for m in re.finditer(r"^RLAPI (.+?)\b(\w+)\((.*?)\);", header, re.M):
    result, name, params = m.group(1).strip(), m.group(2), m.group(3).strip()
    types = []
    variadic = False
    if params not in ("", "void"):
        for param in params.split(","):
            param = param.strip()
            if param == "...":
                variadic = True
                continue
            p = re.match(r"(.*?)(\w+)$", param)
            types.append(swift_type(p.group(1)))
    result_type = swift_type(result)
    if result_type == "Int" and "Int" not in types:
        int_result_only.append(name)
    functions[name] = ",".join(types) + ("..." if variadic else "") + "->" + result_type

# Structs: `typedef struct Name { fields } Name;`
structs = {}
for m in re.finditer(r"^typedef struct (\w+) \{(.*?)\} \1;", header, re.M | re.S):
    fields = []
    for line in m.group(2).splitlines():
        code = line.split("//")[0].strip().rstrip(";")
        if not code:
            continue
        d = re.match(r"(.*?\**)\s*(\w+(?:\s*,\s*\w+)*)$", code)
        if not d or "[" in code:
            fields.append("?:?")
            continue
        names = [n.strip() for n in d.group(2).split(",")]
        stars = code.count("*")
        base = d.group(1).replace("*", "").strip()
        type_ = swift_type(base + (" *" * stars) if stars else base)
        fields.extend(f"{n}:{type_}" for n in names)
    structs[m.group(1)] = fields

# Enum values in raylib.h, and their Swift case names from the API notes.
c_values = {}  # enum -> {value: [C constant, ...]}
for m in re.finditer(r"^typedef enum \{(.*?)\} (\w+);", header, re.M | re.S):
    values, nxt = {}, 0
    for line in m.group(1).splitlines():
        code = line.split("//")[0].strip().rstrip(",")
        if not code:
            continue
        name, _, value = code.partition("=")
        value = int(value.strip(), 0) if value.strip() else nxt
        values.setdefault(value, []).append(name.strip())
        nxt = value + 1
    c_values[m.group(2)] = values
swift_names = dict(re.findall(r"- Name: (\w+)\n  SwiftName: '(\w+)'", apinotes_path.read_text()))
option_sets = re.findall(r"- Name: (\w+)\n  EnumKind: NSOptions", apinotes_path.read_text())


def lower_camel(name):
    return name[:1].lower() + name[1:]


renames = {}
problems = []
for path in sorted(cs_types.glob("*.cs")):
    text = re.sub(r"//.*", "", path.read_text())
    for m in re.finditer(r"public enum (\w+)(?:\s*:\s*\w+)?\s*\{(.*?)\}", text, re.S):
        enum, body = m.group(1), m.group(2)
        if enum not in c_values:
            continue
        nxt = 0
        seen = {}
        for entry in body.split(","):
            entry = re.sub(r"\[.*?\]", "", entry).strip()
            if not entry:
                continue
            member, _, value = entry.partition("=")
            member, value = member.strip(), value.strip()
            if value in seen:  # an alias of an earlier member, such as Diffuse = Albedo
                value = seen[value]
            else:
                value = int(value.rstrip("uU"), 0) if value else nxt
            seen[member] = value
            nxt = value + 1
            constants = c_values[enum].get(value)
            if not constants:
                problems.append(f"{enum}.{member} = {value} has no raylib constant")
                continue
            swift = swift_names[constants[0]]
            if swift != lower_camel(member):
                renames[f"{enum}.{member}"] = swift

if problems:
    sys.exit("error: " + "\n".join(problems))


def literal(items):
    return "[\n" + "".join(f"        {item},\n" for item in items) + "    ]"


out = f"""// Generated by scripts/generate-raylib-data.py from raylib {raylib_version}'s raylib.h, raylib-swift's
// CRaylib.apinotes, and Raylib-cs {cs_version}. Don't edit; rerun the script.

/// What cs2swift knows about raylib and raylib-swift.
enum RaylibData {{
    /// The raylib version the data came from.
    static let raylibVersion = "{raylib_version}"

    /// Each raylib function's parameter and result types, as `Int,Float,Color->Void`. A
    /// `const char *` is `String`, any other pointer `Pointer<T>`, and a trailing `...` marks
    /// a variadic function.
    static let functions: [String: String] = {literal(f'"{k}": "{v}"' for k, v in sorted(functions.items()))}

    /// Functions whose only `int` is their result. raylib-swift has no `Int` overload for
    /// them, so a call is wrapped in `Int(...)`.
    static let intResultOnly: Set<String> = {literal(f'"{n}"' for n in sorted(int_result_only))}

    /// Each struct's fields in declaration order, as `name:Type`.
    static let structs: [String: [String]] = {literal(f'"{k}": [{", ".join(chr(34) + f + chr(34) for f in v)}]' for k, v in sorted(structs.items()))}

    /// raylib's typedef aliases, such as `Texture2D` for `Texture`.
    static let aliases: [String: String] = {literal(f'"{k}": "{v}"' for k, v in sorted(aliases.items()))}

    /// raylib's enums, by name.
    static let enums: Set<String> = {literal(f'"{n}"' for n in sorted(c_values))}

    /// The enums raylib-swift imports as option sets.
    static let optionSets: Set<String> = {literal(f'"{n}"' for n in sorted(option_sets))}

    /// Raylib-cs enum members whose raylib-swift case isn't the member's name in lower camel
    /// case, matched by value: `"ConfigFlags.BorderlessWindowMode": "borderlessWindowedMode"`.
    static let enumCaseRenames: [String: String] = {literal(f'"{k}": "{v}"' for k, v in sorted(renames.items()))}
}}
"""
target = pathlib.Path(__file__).resolve().parent.parent / "Sources/CS2Swift/Generated/RaylibData.swift"
target.write_text(out)
print(f"Wrote {target} ({len(functions)} functions, {len(structs)} structs, {len(renames)} enum renames)")
