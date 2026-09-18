import CTreeSitter
import Foundation

/// Owning handle for a parsed tree. TSNode values are only valid while this
/// object is alive, so node extraction APIs take it as a parameter.
public final class ParsedTree {
    let tree: OpaquePointer

    init(tree: OpaquePointer) {
        self.tree = tree
    }

    deinit {
        ts_tree_delete(tree)
    }

    public var root: TSNode {
        ts_tree_root_node(tree)
    }
}

public final class Parser {
    private let parser: OpaquePointer

    public init?(language: OpaquePointer) {
        parser = ts_parser_new()
        guard ts_parser_set_language(parser, language) else {
            ts_parser_delete(parser)
            return nil
        }
    }

    deinit {
        ts_parser_delete(parser)
    }

    public func parse(_ bytes: [UInt8]) -> ParsedTree? {
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return nil }
            let raw = ts_parser_parse_string(
                parser, nil,
                UnsafePointer<CChar>(OpaquePointer(base)),
                UInt32(buf.count)
            )
            guard let raw else { return nil }
            return ParsedTree(tree: raw)
        }
    }
}

public extension TSNode {
    var typeName: String { String(cString: ts_node_type(self)) }
    var isNamed: Bool { ts_node_is_named(self) }
    var startByte: Int { Int(ts_node_start_byte(self)) }
    var endByte: Int { Int(ts_node_end_byte(self)) }
    var startRow: Int { Int(ts_node_start_point(self).row) }
    var endRow: Int { Int(ts_node_end_point(self).row) }
    var childCount: Int { Int(ts_node_child_count(self)) }

    func child(_ index: Int) -> TSNode? {
        guard index >= 0 && index < childCount else { return nil }
        return ts_node_child(self, UInt32(index))
    }

    func field(_ name: String) -> TSNode? {
        var name = name
        let node = name.withUTF8 { buf in
            ts_node_child_by_field_name(
                self, UnsafePointer<CChar>(OpaquePointer(buf.baseAddress!)),
                UInt32(buf.count))
        }
        return ts_node_is_null(node) ? nil : node
    }

    func text(in bytes: [UInt8]) -> String {
        guard startByte < endByte, endByte <= bytes.count else { return "" }
        return String(decoding: bytes[startByte..<endByte], as: UTF8.self)
    }

    /// Terminal identifier of an expression: `a.b.c()` callee -> `c`.
    /// Descends into the last named child until a plain identifier is found.
    func terminalIdentifier(in bytes: [UInt8], maxDepth: Int = 8) -> String? {
        switch typeName {
        case "identifier", "type_identifier", "field_identifier",
             "property_identifier", "simple_identifier",
             "shorthand_property_identifier":
            let s = text(in: bytes)
            return s.isEmpty ? nil : s
        default:
            break
        }
        guard maxDepth > 0 else { return nil }
        var i = childCount - 1
        while i >= 0 {
            if let c = child(i), c.isNamed,
               let s = c.terminalIdentifier(in: bytes, maxDepth: maxDepth - 1) {
                return s
            }
            i -= 1
        }
        return nil
    }

    /// Root identifier of an expression: `a.b.c` -> `a`. Descends into the
    /// FIRST named child until a plain identifier is found — the complement
    /// of terminalIdentifier, used to capture call receivers (`m` in `m.f()`).
    func rootIdentifier(in bytes: [UInt8], maxDepth: Int = 8) -> String? {
        switch typeName {
        case "identifier", "type_identifier", "field_identifier",
             "property_identifier", "simple_identifier",
             "shorthand_property_identifier":
            let s = text(in: bytes)
            return s.isEmpty ? nil : s
        default:
            break
        }
        guard maxDepth > 0 else { return nil }
        var i = 0
        while i < childCount {
            if let c = child(i), c.isNamed,
               let s = c.rootIdentifier(in: bytes, maxDepth: maxDepth - 1) {
                return s
            }
            i += 1
        }
        return nil
    }
}
