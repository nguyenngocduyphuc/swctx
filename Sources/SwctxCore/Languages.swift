import CTreeSitter
import CGrammarBash
import CGrammarCss
import CGrammarGo
import CGrammarHtml
import CGrammarJavascript
import CGrammarJson
import CGrammarPython
import CGrammarRust
import CGrammarSwift
import CGrammarTsx
import CGrammarTypescript
import CGrammarYaml
import Foundation

public struct LanguageProfile: @unchecked Sendable {
    public let id: String
    public let language: OpaquePointer?  // nil => heuristic chunking only
    /// Node types that become retrieval chunks at top level.
    public let chunkTypes: Set<String>
    /// Node types that act as transparent wrappers (export statements etc.).
    public let transparentTypes: Set<String>
    /// Node types considered symbol definitions during full-tree extraction.
    public let defTypes: Set<String>
    /// Call-site node types (edge kind `calls`).
    public let callTypes: Set<String>
    /// Callee names never emitted as `calls` edges: builtins and ubiquitous
    /// stdlib/object methods that cannot resolve to user-defined symbols.
    /// Applies to the extracted terminal identifier regardless of qualifier
    /// (`parser.add_argument()` and `add_argument()` are both suppressed).
    public let callDenylist: Set<String>
    /// Import/include node types (edge kind `imports`).
    public let importTypes: Set<String>
    /// Declaration node types that may carry nominal subtyping info
    /// (edge kind `implements`): swift class/protocol declarations with
    /// `inheritance_specifier` children, python `class_definition` bases,
    /// ts/tsx `class_heritage`, rust `impl_item` trait impls.
    public let implTypes: Set<String>
    /// Type-annotation node types (edge kind `uses_type`): swift/ts
    /// `type_annotation`, python `type`.
    public let typeRefTypes: Set<String>
    /// Preferred field names that hold the declared name.
    public let nameFields: [String]
    /// Max tree depth at which a defType still counts as a symbol
    /// (e.g. python `assignment` only at module level, json `pair` only at top level).
    public let defDepths: [String: Int]

    public init(id: String, language: OpaquePointer?, chunkTypes: Set<String>,
                transparentTypes: Set<String> = [], defTypes: Set<String>,
                callTypes: Set<String> = [], importTypes: Set<String> = [],
                implTypes: Set<String> = [], typeRefTypes: Set<String> = [],
                nameFields: [String] = ["name"], defDepths: [String: Int] = [:],
                callDenylist: Set<String> = []) {
        self.id = id
        self.language = language
        self.chunkTypes = chunkTypes
        self.transparentTypes = transparentTypes
        self.defTypes = defTypes
        self.callTypes = callTypes
        self.callDenylist = callDenylist
        self.importTypes = importTypes
        self.implTypes = implTypes
        self.typeRefTypes = typeRefTypes
        self.nameFields = nameFields
        self.defDepths = defDepths
    }
}

public enum Languages {
    /// Extension / basename -> language id.
    static let extMap: [String: String] = [
        "swift": "swift",
        "py": "python", "pyi": "python",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "jsx": "tsx",
        "ts": "typescript", "mts": "typescript", "cts": "typescript",
        "tsx": "tsx",
        "go": "go",
        "rs": "rust",
        "json": "json",
        "yaml": "yaml", "yml": "yaml",
        "html": "html", "htm": "html",
        "css": "css",
        "sh": "bash", "bash": "bash", "zsh": "bash",
        "md": "markdown", "markdown": "markdown",
        "txt": "text", "toml": "text",
    ]

    static let baseNames: [String: String] = [
        "makefile": "bash", "dockerfile": "bash", "justfile": "bash",
        "gemfile": "text", "podfile": "text",
    ]

    public static func languageID(forPath path: String) -> String? {
        let lower = (path as NSString).lastPathComponent.lowercased()
        if let b = baseNames[lower] { return b }
        let ext = (lower as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return extMap[ext]
    }

    public static func profile(_ id: String) -> LanguageProfile? {
        profiles[id]
    }

    private static let jsLikeDefs: Set<String> = [
        "function_declaration", "function_expression", "class_declaration",
        "method_definition", "lexical_declaration", "variable_declaration",
        "generator_function_declaration", "abstract_class_declaration",
        "interface_declaration", "type_alias_declaration", "enum_declaration",
        "internal_module", "module", "ambient_declaration",
        "public_field_definition", "method_signature", "function_signature",
    ]

    /// ts/tsx declarations whose heritage clauses are nominal subtyping
    /// (`extends`/`implements` on classes, `extends` on interfaces).
    /// javascript intentionally excluded (ctxe parity: no implements edges).
    private static let jsLikeImpls: Set<String> = [
        "class_declaration", "abstract_class_declaration",
        "interface_declaration",
    ]

    // MARK: - Call-edge denylist (builtins + ubiquitous stdlib/object methods)

    private static let pythonCallDenylist: Set<String> = [
        // builtins + common exception types
        "print", "len", "str", "int", "float", "list", "dict", "set", "tuple",
        "range", "enumerate", "zip", "map", "filter", "sorted", "isinstance",
        "getattr", "setattr", "hasattr", "open", "type", "repr", "abs", "min",
        "max", "sum", "any", "all", "super", "iter", "next", "vars", "dir",
        "callable", "format", "input",
        "Exception", "ValueError", "TypeError", "KeyError", "RuntimeError",
        "NotImplementedError", "StopIteration", "Path",
        // common object methods (terminal identifier of obj.method())
        "append", "extend", "insert", "remove", "pop", "get", "keys", "values",
        "items", "update", "strip", "lstrip", "rstrip", "split", "rsplit",
        "join", "replace", "startswith", "endswith", "lower", "upper", "title",
        "find", "index", "count", "encode", "decode",
        "read", "write", "close", "read_text", "write_text", "exists", "mkdir",
        "glob", "add_argument", "add_subparsers", "set_defaults", "parse_args",
        "group", "groups", "search", "match", "sub", "findall", "compile",
        "sleep", "dump", "dumps", "load", "loads",
        // residual method/http noise observed on a real 4.7k-file index
        "bool", "now", "round", "exit", "SystemExit", "wc", "strftime",
        "strptime", "isoformat", "splitlines", "resolve", "getenv", "environ",
        "find_all", "finditer", "escape", "iterdir", "is_dir", "setdefault",
        "raises", "add_parser", "urlopen", "post", "put", "delete",
        "save", "start", "end", "send", "request", "Session", "Request",
    ]

    private static let jsLikeCallDenylist: Set<String> = [
        "console", "log", "require", "setTimeout", "Promise", "then", "catch",
        "map", "filter", "reduce", "forEach", "push", "slice", "splice",
        "JSON", "stringify", "parse", "querySelector", "addEventListener",
        "toString", "hasOwnProperty",
    ]

    private static let goCallDenylist: Set<String> = [
        "Println", "Printf", "Errorf", "Sprintf", "Fatalf", "append", "len",
        "cap", "make", "new", "copy", "delete", "panic", "recover",
    ]

    private static let rustCallDenylist: Set<String> = [
        "println", "format", "vec", "unwrap", "expect", "clone", "to_string",
        "push", "insert", "get", "iter", "collect", "map",
        "Some", "None", "Ok", "Err",
    ]

    private static let swiftCallDenylist: Set<String> = [
        "print", "debugPrint", "fatalError", "assert", "append", "map", "filter",
        "reduce", "forEach", "first", "count", "isEmpty", "contains",
    ]

    /// Builtin/ubiquitous type names never emitted as `uses_type` edges —
    /// they would flood the graph with unresolvable noise.
    static let typeDenylist: Set<String> = [
        "String", "Int", "Bool", "Double", "Float", "Character", "Array",
        "Dictionary", "Set", "Optional", "Result", "Error", "Date", "Data",
        "URL", "UUID", "Void", "Self", "Any", "AnyObject", "AnyHashable",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Int8", "Int16",
        "Int32", "Int64", "Substring", "Encoding", "Decoder", "Encoder",
        "CodingKey", "AnyView", "View", "some", "Promise", "Record",
        "Partial", "Required", "Readonly", "Pick", "Omit", "Exclude",
        "Extract", "NonNullable", "Parameters", "ReturnType", "Map",
        "WeakMap", "RegExp", "Number", "Boolean", "Object", "Symbol",
        "BigInt", "Unknown", "Never", "Undefined", "Null",
    ]

    private static let profiles: [String: LanguageProfile] = [
        "swift": LanguageProfile(
            id: "swift", language: tree_sitter_swift(),
            chunkTypes: [
                "class_declaration", "function_declaration", "protocol_declaration",
                "init_declaration", "deinit_declaration", "subscript_declaration",
                "typealias_declaration", "property_declaration", "enum_declaration",
                "struct_declaration", "extension_declaration", "operator_declaration",
                "precedence_group_declaration", "macro_declaration",
            ],
            defTypes: [
                "class_declaration", "function_declaration", "protocol_declaration",
                "init_declaration", "subscript_declaration", "typealias_declaration",
                "property_declaration", "enum_declaration", "struct_declaration",
                "extension_declaration", "protocol_function_declaration",
            ],
            callTypes: ["call_expression"],
            importTypes: ["import_declaration"],
            // This grammar emits `class_declaration` for struct/class/enum/
            // extension/actor decls (verified against vendored parser);
            // `protocol_declaration` is separate. Both take
            // `inheritance_specifier` children.
            implTypes: ["class_declaration", "protocol_declaration"],
            // `type_annotation` covers `let x: T`; parameters and return
            // positions surface as bare `type`/`user_type`/`return_type`
            // (verified against the vendored parser).
            typeRefTypes: ["type_annotation", "type", "user_type",
                           "return_type", "constructed_type"],
            nameFields: ["name", "type"], callDenylist: swiftCallDenylist),
        "python": LanguageProfile(
            id: "python", language: tree_sitter_python(),
            chunkTypes: [
                "function_definition", "class_definition", "decorated_definition",
            ],
            defTypes: [
                "function_definition", "class_definition", "assignment",
            ],
            callTypes: ["call"],
            importTypes: ["import_statement", "import_from_statement"],
            implTypes: ["class_definition"],
            typeRefTypes: ["type"],
            nameFields: ["name"], defDepths: ["assignment": 2],
            callDenylist: pythonCallDenylist),
        "javascript": LanguageProfile(
            id: "javascript", language: tree_sitter_javascript(),
            chunkTypes: jsLikeDefs,
            transparentTypes: ["export_statement"],
            defTypes: jsLikeDefs,
            callTypes: ["call_expression"],
            importTypes: ["import_statement", "import_expression"],
            nameFields: ["name"], callDenylist: jsLikeCallDenylist),
        "typescript": LanguageProfile(
            id: "typescript", language: tree_sitter_typescript(),
            chunkTypes: jsLikeDefs,
            transparentTypes: ["export_statement"],
            defTypes: jsLikeDefs,
            callTypes: ["call_expression"],
            importTypes: ["import_statement", "import_expression"],
            implTypes: jsLikeImpls, typeRefTypes: ["type_annotation"],
            nameFields: ["name"], callDenylist: jsLikeCallDenylist),
        "tsx": LanguageProfile(
            id: "tsx", language: tree_sitter_tsx(),
            chunkTypes: jsLikeDefs,
            transparentTypes: ["export_statement"],
            defTypes: jsLikeDefs,
            callTypes: ["call_expression"],
            importTypes: ["import_statement", "import_expression"],
            implTypes: jsLikeImpls, typeRefTypes: ["type_annotation"],
            nameFields: ["name"], callDenylist: jsLikeCallDenylist),
        "go": LanguageProfile(
            id: "go", language: tree_sitter_go(),
            chunkTypes: [
                "function_declaration", "method_declaration", "type_declaration",
                "const_declaration", "var_declaration",
            ],
            defTypes: [
                "function_declaration", "method_declaration", "type_declaration",
                "const_declaration", "var_declaration", "const_spec", "var_spec",
            ],
            callTypes: ["call_expression"],
            importTypes: ["import_declaration"],
            nameFields: ["name"],
            defDepths: ["const_declaration": 1, "var_declaration": 1,
                        "const_spec": 2, "var_spec": 2],
            callDenylist: goCallDenylist),
        "rust": LanguageProfile(
            id: "rust", language: tree_sitter_rust(),
            chunkTypes: [
                "function_item", "struct_item", "enum_item", "impl_item",
                "trait_item", "mod_item", "const_item", "static_item",
                "type_item", "macro_definition", "union_item",
            ],
            transparentTypes: ["impl_item", "mod_item", "trait_item", "declaration_list"],
            defTypes: [
                "function_item", "struct_item", "enum_item", "trait_item",
                "mod_item", "const_item", "static_item", "type_item",
                "macro_definition", "union_item",
            ],
            callTypes: ["call_expression", "generic_function", "macro_invocation"],
            importTypes: ["use_declaration"],
            implTypes: ["impl_item"],
            nameFields: ["name"], callDenylist: rustCallDenylist),
        // Data formats: window chunks (per-pair/per-element chunking was 78% of
        // all chunks and pure retrieval noise); symbols still extracted for json.
        "json": LanguageProfile(
            id: "json", language: tree_sitter_json(),
            chunkTypes: [], defTypes: ["pair"], nameFields: ["key"],
            defDepths: ["pair": 2]),
        "yaml": LanguageProfile(
            id: "yaml", language: tree_sitter_yaml(),
            chunkTypes: [], defTypes: []),
        "html": LanguageProfile(
            id: "html", language: tree_sitter_html(),
            chunkTypes: [], defTypes: []),
        "css": LanguageProfile(
            id: "css", language: tree_sitter_css(),
            chunkTypes: [], defTypes: []),
        "bash": LanguageProfile(
            id: "bash", language: tree_sitter_bash(),
            chunkTypes: ["function_definition", "command"],
            defTypes: ["function_definition"],
            callTypes: ["command"],
            nameFields: ["name"]),
        "markdown": LanguageProfile(
            id: "markdown", language: nil,
            chunkTypes: [], defTypes: []),
        "text": LanguageProfile(
            id: "text", language: nil,
            chunkTypes: [], defTypes: []),
    ]
}
