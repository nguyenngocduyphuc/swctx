import Foundation

/// SentencePiece *unigram* tokenizer, ported to pure Swift for XLM-R-family
/// models (BGE-M3 `sentencepiece.bpe.model`, multilingual-e5, XLM-RoBERTa).
///
/// The binary `.model` protobuf is parsed by hand (no external deps):
///   ModelProto { pieces(1){piece(1),score(2,fixed32),type(3)},
///                trainer_spec(2){model_type(3),treat_whitespace_as_suffix(24),
///                                byte_fallback(35), unk/bos/eos/pad_id(40-43)},
///                normalizer_spec(3){name(1),precompiled_charsmap(2),
///                                   add_dummy_prefix(3),
///                                   remove_extra_whitespaces(4),
///                                   escape_whitespaces(5)} }
///
/// Fidelity to google/sentencepiece (verified against `sentencepiece` 0.2.x
/// outputs on BGE-M3's real model):
/// - `nmt_nfkc`-style normalization via the model's `precompiled_charsmap`.
///   The blob is a Darts-clone double-array trie + a NUL-terminated
///   replacement-string table; both are decoded natively in `CharsMap`.
///   Whitespace pipeline mirrors `Normalizer::Normalize`: leading-space skip,
///   optional "▁" (U+2581) dummy prefix, space collapsing, and ' ' → '▁'
///   escaping. When a model ships no charsmap, input passes through with only
///   the whitespace rules — there is intentionally no fallback NFC pass
///   (documented deviation: for models *with* a charsmap we are exact; for
///   models without one, C++ also applies no extra normalization).
/// - Unigram Viterbi identical to `unigram::Model::EncodeOptimized`: a byte
///   trie over NORMAL/USER_DEFINED/UNUSED pieces (UNUSED skipped at encode
///   time), user-defined pieces score `0.1*(byteLen-1)` so they always win,
///   and any character with no single-char match gets an unknown node scored
///   `minNormalScore - 10` covering exactly one UTF-8 character.
/// - Post-processing identical to `PopulateSentencePieceText`: consecutive
///   unknowns merge into a single `<unk>` id; with `trainer_spec.byte_fallback`
///   each unknown character's UTF-8 bytes emit their `<0xNN>` piece ids.
/// - XLM-R encode convention: `ids = [bos] + pieces + [eos]`, content
///   truncated to `maxLen - 2` so specials always fit. `attentionMask` is all
///   ones — callers pad (with `padID` when ≥ 0) as needed, like BGEEmbedder.
///
/// Deliberate limitations:
/// - Only `model_type == UNIGRAM` (1). BPE/WORD/CHAR models throw.
/// - No `norm_to_orig` alignment map, no NBest/Sample encode.
/// - Piece matching uses a plain byte trie built at load (C++ uses a
///   serialized Darts array for pieces too; same results, more memory).
/// - Malformed-UTF-8 recovery is simplified (Swift `String` input is always
///   valid UTF-8, so the path is unreachable through the public API).
public struct SPTokenizer: @unchecked Sendable {
    public enum SPError: Error, Equatable {
        case malformedModel(String)
        case unsupportedModelType(Int)
    }

    /// ModelProto.SentencePiece.Type enum values.
    private enum PieceType {
        static let normal: UInt8 = 1
        static let unknown: UInt8 = 2
        static let control: UInt8 = 3
        static let userDefined: UInt8 = 4
        static let unused: UInt8 = 5
        static let byte: UInt8 = 6
    }

    /// Score penalty applied to unknown characters (unigram.cc kUnkPenalty).
    private static let unkPenalty: Float = 10.0
    /// Whitespace escape symbol U+2581 (▁) in UTF-8.
    private static let spaceSymbolUTF8: [UInt8] = [0xE2, 0x96, 0x81]
    /// The raw space byte that `remove_extra_whitespaces` collapses on.
    private static let spaceByte: UInt8 = 0x20

    public let vocabSize: Int
    public let unkID: Int32
    public let bosID: Int32
    public let eosID: Int32
    /// -1 when the model defines no pad piece (e.g. BGE-M3).
    public let padID: Int32
    public let byteFallbackEnabled: Bool
    /// Normalizer name from NormalizerSpec (e.g. "nmt_nfkc"), informational.
    public let normalizerName: String

    private let pieces: [String]
    private let scores: [Float]
    private let types: [UInt8]
    /// Piece lookup keyed by UTF-8 *bytes*, not String — Swift String
    /// equality is canonical-equivalence-aware and would collapse pieces
    /// that differ only in combining-mark order (BGE-M3 contains such pairs).
    private let pieceToID: [[UInt8]: Int32]
    private let trie = PieceTrie()
    private let minScore: Float
    /// byte value → piece id for `<0xNN>` BYTE pieces; -1 when absent.
    private let byteIDs: [Int32]
    private let charsmap: CharsMap?
    private let addDummyPrefix: Bool
    private let removeExtraWhitespaces: Bool
    private let escapeWhitespaces: Bool
    private let treatWhitespaceAsSuffix: Bool

    // MARK: - Loading

    public init(modelURL: URL) throws {
        try self.init(modelData: Data(contentsOf: modelURL))
    }

    public init(modelData data: Data) throws {
        var reader = ProtoReader(Array(data))
        var parsedPieces: [(piece: String, score: Float, type: UInt8)] = []
        var modelType = 1
        var treatWhitespaceAsSuffix = false
        var byteFallback = false
        var specUnkID: Int32 = 0
        var bosID: Int32 = 1
        var eosID: Int32 = 2
        var padID: Int32 = -1
        var normalizerName = ""
        var charsmapBlob: [UInt8]?
        var addDummyPrefix = true
        var removeExtraWhitespaces = true
        var escapeWhitespaces = true

        while let tag = reader.tag() {
            switch (tag.field, tag.wire) {
            case (1, 2):  // pieces
                guard let sub = reader.fieldData() else {
                    throw SPError.malformedModel("truncated pieces field")
                }
                parsedPieces.append(try Self.parsePiece(sub))
            case (2, 2):  // trainer_spec
                guard let sub = reader.fieldData() else {
                    throw SPError.malformedModel("truncated trainer_spec")
                }
                var tr = ProtoReader(sub)
                while let t = tr.tag() {
                    switch (t.field, t.wire) {
                    case (3, 0):
                        // A truncated or non-representable modelType means a
                        // corrupt spec — fail loud, never silently tokenize
                        // as the wrong model type.
                        guard let tv = tr.varint(), let m = Int(exactly: tv) else {
                            throw SPError.malformedModel("bad modelType varint")
                        }
                        modelType = m
                    case (24, 0): treatWhitespaceAsSuffix = (tr.varint() ?? 0) != 0
                    case (35, 0): byteFallback = (tr.varint() ?? 0) != 0
                    case (40, 0): specUnkID = Self.int32(tr.varint() ?? 0)
                    case (41, 0): bosID = Self.int32(tr.varint() ?? 1)
                    case (42, 0): eosID = Self.int32(tr.varint() ?? 2)
                    case (43, 0): padID = Self.int32(tr.varint() ?? UInt64(bitPattern: -1))
                    default: tr.skip(wire: t.wire)
                    }
                }
            case (3, 2):  // normalizer_spec
                guard let sub = reader.fieldData() else {
                    throw SPError.malformedModel("truncated normalizer_spec")
                }
                var nr = ProtoReader(sub)
                while let t = nr.tag() {
                    switch (t.field, t.wire) {
                    case (1, 2):
                        normalizerName = String(
                            decoding: nr.fieldData() ?? [], as: UTF8.self)
                    case (2, 2):
                        charsmapBlob = nr.fieldData().map { Array($0) }
                    case (3, 0): addDummyPrefix = (nr.varint() ?? 1) != 0
                    case (4, 0): removeExtraWhitespaces = (nr.varint() ?? 1) != 0
                    case (5, 0): escapeWhitespaces = (nr.varint() ?? 1) != 0
                    default: nr.skip(wire: t.wire)
                    }
                }
            default:
                reader.skip(wire: tag.wire)
            }
        }
        guard !parsedPieces.isEmpty else {
            throw SPError.malformedModel("model contains no pieces")
        }
        guard modelType == 1 else {
            throw SPError.unsupportedModelType(modelType)
        }

        vocabSize = parsedPieces.count
        self.bosID = bosID
        self.eosID = eosID
        self.padID = padID
        byteFallbackEnabled = byteFallback
        self.normalizerName = normalizerName
        self.addDummyPrefix = addDummyPrefix
        self.removeExtraWhitespaces = removeExtraWhitespaces
        self.escapeWhitespaces = escapeWhitespaces
        self.treatWhitespaceAsSuffix = treatWhitespaceAsSuffix

        var pieces: [String] = []
        var scores: [Float] = []
        var types: [UInt8] = []
        var pieceToID: [[UInt8]: Int32] = [:]
        var minScore = Float.greatestFiniteMagnitude
        var detectedUnk: Int32 = -1
        var byteIDs = [Int32](repeating: -1, count: 256)
        pieces.reserveCapacity(parsedPieces.count)
        scores.reserveCapacity(parsedPieces.count)
        types.reserveCapacity(parsedPieces.count)

        for (i, sp) in parsedPieces.enumerated() {
            guard !sp.piece.isEmpty, !sp.piece.contains("\0") else {
                throw SPError.malformedModel(
                    "piece \(i) is empty or contains NUL")
            }
            let utf8 = Array(sp.piece.utf8)
            guard pieceToID[utf8] == nil else {
                throw SPError.malformedModel("duplicate piece \(sp.piece)")
            }
            let id = Int32(i)
            pieces.append(sp.piece)
            scores.append(sp.score)
            types.append(sp.type)
            pieceToID[utf8] = id

            switch sp.type {
            case PieceType.normal:
                minScore = min(minScore, sp.score)
                trie.insert(utf8, id: id)
            case PieceType.userDefined, PieceType.unused:
                trie.insert(utf8, id: id)
            case PieceType.unknown:
                guard detectedUnk == -1 else {
                    throw SPError.malformedModel("multiple unk pieces")
                }
                detectedUnk = id
            case PieceType.byte:
                if let b = Self.pieceToByte(sp.piece) { byteIDs[b] = id }
            default:
                break  // CONTROL and anything else: not matchable from input.
            }
        }
        self.unkID = detectedUnk >= 0 ? detectedUnk : specUnkID
        guard self.unkID >= 0 || byteFallback else {
            throw SPError.malformedModel(
                "no unk piece and byte_fallback is off")
        }
        guard minScore.isFinite else {
            throw SPError.malformedModel("no NORMAL pieces")
        }
        self.pieces = pieces
        self.scores = scores
        self.types = types
        self.pieceToID = pieceToID
        self.minScore = minScore
        self.byteIDs = byteIDs
        if let blob = charsmapBlob {
            // An undecodable charsmap is treated as absent rather than fatal —
            // input then passes through with only the whitespace pipeline.
            charsmap = CharsMap(blob: blob)
        } else {
            charsmap = nil
        }
    }

    /// "<0xNN>" BYTE piece → byte value, else nil.
    private static func pieceToByte(_ piece: String) -> Int? {
        let u = Array(piece.utf8)
        guard u.count == 6, u[0] == 0x3C, u[1] == 0x30, u[2] == 0x78,
              u[5] == 0x3E else { return nil }
        func hex(_ b: UInt8) -> Int? {
            switch b {
            case 0x30...0x39: return Int(b - 0x30)
            case 0x41...0x46: return Int(b - 0x41 + 10)
            default: return nil
            }
        }
        guard let hi = hex(u[3]), let lo = hex(u[4]) else { return nil }
        return hi << 4 | lo
    }

    private static func int32(_ v: UInt64) -> Int32 {
        Int32(bitPattern: UInt32(truncatingIfNeeded: v))
    }

    private static func parsePiece(_ bytes: ArraySlice<UInt8>) throws
        -> (piece: String, score: Float, type: UInt8) {
        var r = ProtoReader(bytes)
        var piece = ""
        var score: Float = 0
        var type: UInt8 = PieceType.normal
        while let t = r.tag() {
            switch (t.field, t.wire) {
            case (1, 2):
                piece = String(decoding: r.fieldData() ?? [], as: UTF8.self)
            case (2, 5):
                guard let f = r.fixed32Float() else {
                    throw SPError.malformedModel("truncated piece score")
                }
                score = f
            case (3, 0):
                type = UInt8(truncatingIfNeeded: r.varint() ?? 1)
            default:
                r.skip(wire: t.wire)
            }
        }
        return (piece, score, type)
    }

    // MARK: - Public API

    /// Looks up a piece string's id (any type, incl. controls). nil → absent.
    public func id(forPiece piece: String) -> Int32? {
        pieceToID[Array(piece.utf8)]
    }

    /// Returns the piece string for an id, nil if out of range.
    public func piece(id: Int32) -> String? {
        let i = Int(id)
        return (0..<vocabSize).contains(i) ? pieces[i] : nil
    }

    /// Encodes `text` XLM-R style: `[bos] + pieces + [eos]`.
    /// Content pieces are truncated to `maxLen - 2` (or `maxLen` when
    /// `addSpecialTokens` is false). `attentionMask` is all ones; pad on the
    /// caller side with `padID` (when ≥ 0) if a fixed length is needed.
    public func encode(_ text: String, maxLen: Int = 512,
                       addSpecialTokens: Bool = true)
        -> (ids: [Int32], attentionMask: [Int32]) {
        var ids = viterbiIDs(text)
        let specials = addSpecialTokens ? 2 : 0
        let budget = max(0, maxLen - specials)
        if ids.count > budget { ids = Array(ids.prefix(budget)) }
        if addSpecialTokens {
            ids = [bosID] + ids + [eosID]
        }
        return (ids, [Int32](repeating: 1, count: ids.count))
    }

    /// Piece-level view of `encode` (no specials). Useful for debugging;
    /// byte fallback shows the literal `<0xNN>` pieces, merged unknowns
    /// show as a single `<unk>`.
    public func encodeToPieces(_ text: String) -> [String] {
        let normalized = normalize(text)
        var out: [String] = []
        var prevUnk = false
        for node in viterbi(normalized) {
            if node.id == unkID {
                if byteFallbackEnabled {
                    for b in normalized[node.start..<node.end] {
                        out.append(String(format: "<0x%02X>", b))
                    }
                } else if !prevUnk {
                    out.append("<unk>")
                }
                prevUnk = true
            } else {
                out.append(piece(id: node.id) ?? "<unk>")
                prevUnk = false
            }
        }
        return out
    }

    // MARK: - Normalization (Normalizer::Normalize equivalent)

    /// Applies the precompiled charsmap longest-prefix rewriting and the
    /// whitespace pipeline, returning normalized UTF-8 bytes.
    func normalize(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        let spaceSymbol = escapeWhitespaces
            ? Self.spaceSymbolUTF8 : [Self.spaceByte]
        var normalized: [UInt8] = []
        normalized.reserveCapacity(bytes.count + bytes.count / 2)

        var pos = 0
        // Ignores heading space (characters normalizing to a single space).
        if removeExtraWhitespaces {
            while pos < bytes.count {
                let p = normalizePrefix(bytes, at: pos)
                if p.out != [Self.spaceByte] { break }
                pos += p.consumed
            }
        }
        if pos >= bytes.count { return [] }

        if !treatWhitespaceAsSuffix && addDummyPrefix {
            normalized.append(contentsOf: spaceSymbol)
        }

        var isPrevSpace = removeExtraWhitespaces
        while pos < bytes.count {
            let p = normalizePrefix(bytes, at: pos)
            var sp = p.out
            // Removes heading spaces when the previous piece ended with one.
            while isPrevSpace && sp.first == Self.spaceByte {
                sp = sp.dropFirst()
            }
            if !sp.isEmpty {
                for b in sp {
                    if b == Self.spaceByte {
                        normalized.append(contentsOf: spaceSymbol)
                    } else {
                        normalized.append(b)
                    }
                }
                isPrevSpace = sp.last == Self.spaceByte
            }
            pos += p.consumed
            if !removeExtraWhitespaces { isPrevSpace = false }
        }

        // Ignores trailing space.
        if removeExtraWhitespaces {
            while normalized.suffix(spaceSymbol.count)
                .elementsEqual(spaceSymbol) {
                normalized.removeLast(spaceSymbol.count)
            }
        }
        if treatWhitespaceAsSuffix && addDummyPrefix {
            normalized.append(contentsOf: spaceSymbol)
        }
        return normalized
    }

    /// Longest charsmap rule matching `input[pos...]` → replacement bytes +
    /// consumed input length. No rule → one UTF-8 character passes through
    /// (a malformed byte emits U+FFFD, consuming one byte).
    private func normalizePrefix(_ input: [UInt8], at pos: Int)
        -> (out: ArraySlice<UInt8>, consumed: Int) {
        if let cm = charsmap, let m = cm.longestMatch(input[pos...]) {
            return (cm.replacement(at: m.value), m.length)
        }
        let mblen = Self.oneCharLen(input[pos...])
        let seg = input[pos..<(pos + mblen)]
        if Self.isValidUTF8(seg) { return (seg, mblen) }
        return ([0xEF, 0xBF, 0xBD][...], 1)  // U+FFFD
    }

    /// sentencepiece `OneCharLen`: lead-byte nibble → UTF-8 char length.
    private static func oneCharLen(_ bytes: some Collection<UInt8>) -> Int {
        guard let b = bytes.first else { return 0 }
        let table: [Int] = [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 3, 4]
        return min(table[Int(b >> 4)], bytes.count)
    }

    private static func isValidUTF8(_ bytes: some Collection<UInt8>) -> Bool {
        let a = Array(bytes)
        guard let first = a.first else { return false }
        if first < 0x80 { return a.count == 1 }
        for b in a.dropFirst() where b & 0xC0 != 0x80 { return false }
        // Reject overlongs, surrogates and out-of-range lead bytes.
        switch first {
        case 0xC2...0xDF: return a.count == 2
        case 0xE0: return a.count == 3 && a[1] >= 0xA0
        case 0xED: return a.count == 3 && a[1] <= 0x9F
        case 0xE1...0xEC, 0xEE, 0xEF: return a.count == 3
        case 0xF0: return a.count == 4 && a[1] >= 0x90
        case 0xF4: return a.count == 4 && a[1] <= 0x8F
        case 0xF1...0xF3: return a.count == 4
        default: return false
        }
    }

    // MARK: - Viterbi (unigram::Model::EncodeOptimized equivalent)

    private struct LatticeNode {
        var id: Int32 = -1
        var score: Float = 0
        var start: Int = -1
    }

    /// Best-path segmentation of normalized UTF-8 bytes.
    /// Returns (start, end, id) nodes in order; unk nodes carry `unkID`.
    private func viterbi(_ normalized: [UInt8])
        -> [(start: Int, end: Int, id: Int32)] {
        let size = normalized.count
        guard size > 0 else { return [] }
        let unkScore = minScore - Self.unkPenalty
        var best = [LatticeNode](repeating: LatticeNode(), count: size + 1)
        var maxFrontier = 0
        var start = 0
        while start < size {
            var scoreTillHere = best[start].score
            // Periodic re-zeroing keeps accumulated scores inside float range.
            if scoreTillHere < -100_000 || scoreTillHere > 100_000 {
                let off = scoreTillHere
                var i = start
                while i <= maxFrontier {
                    if i == start || best[i].start != -1 {
                        best[i].score -= off
                    }
                    i += 1
                }
                scoreTillHere = 0
            }
            var hasSingleNode = false
            let mblen = Self.oneCharLen(normalized[start...])
            var node = trie.root
            var pos = start
            while pos < size {
                guard let child = node.child[normalized[pos]] else { break }
                node = child
                pos += 1
                let id = node.pieceID
                if id < 0 { continue }
                if types[Int(id)] == PieceType.unused { continue }
                maxFrontier = max(maxFrontier, pos)
                let length = pos - start
                let score = types[Int(id)] == PieceType.userDefined
                    ? 0.1 * Float(length - 1) : scores[Int(id)]
                let candidate = score + scoreTillHere
                if best[pos].start == -1 || candidate > best[pos].score {
                    best[pos].score = candidate
                    best[pos].start = start
                    best[pos].id = id
                }
                if !hasSingleNode && length == mblen { hasSingleNode = true }
            }
            if !hasSingleNode {
                maxFrontier = max(maxFrontier, start + mblen)
                let target = start + mblen
                let candidate = unkScore + scoreTillHere
                if best[target].start == -1 || candidate > best[target].score {
                    best[target].score = candidate
                    best[target].start = start
                    best[target].id = unkID
                }
            }
            start += mblen
        }
        var out: [(start: Int, end: Int, id: Int32)] = []
        var end = size
        while end > 0 {
            let n = best[end]
            guard n.start >= 0 else { break }  // unreachable; defensive
            out.append((n.start, end, n.id))
            end = n.start
        }
        return out.reversed()
    }

    /// Viterbi + post-processing (unk merge / byte fallback) → piece ids.
    private func viterbiIDs(_ text: String) -> [Int32] {
        let normalized = normalize(text)
        var ids: [Int32] = []
        ids.reserveCapacity(normalized.count / 2 + 1)
        var prevUnk = false
        for node in viterbi(normalized) {
            if node.id == unkID {
                if byteFallbackEnabled {
                    for b in normalized[node.start..<node.end] {
                        let bid = byteIDs[Int(b)]
                        ids.append(bid >= 0 ? bid : unkID)
                    }
                } else if !prevUnk {
                    ids.append(unkID)
                }
                prevUnk = true
            } else {
                ids.append(node.id)
                prevUnk = false
            }
        }
        return ids
    }
}

// MARK: - Piece prefix trie

/// Byte-level prefix trie over matchable pieces (NORMAL/USER_DEFINED/UNUSED).
/// Class-based; immutable after `SPTokenizer.init` finishes building it.
private final class PieceTrie: @unchecked Sendable {
    final class Node {
        var child: [UInt8: Node] = [:]
        var pieceID: Int32 = -1
    }
    let root = Node()

    func insert(_ bytes: some Sequence<UInt8>, id: Int32) {
        var node = root
        for b in bytes {
            if let next = node.child[b] {
                node = next
            } else {
                let next = Node()
                node.child[b] = next
                node = next
            }
        }
        node.pieceID = id
    }
}

// MARK: - Precompiled charsmap (Darts-clone double-array)

/// Decodes NormalizerSpec.precompiled_charsmap:
/// `[u32 trie_byte_size][trie units][NUL-terminated replacement table]`.
/// Unit layout (darts.h DoubleArrayUnit):
///   label    = unit & 0xFF   (MSB set → leaf unit, never matches a byte)
///   has_leaf = (unit >> 8) & 1
///   offset   = (unit >> 10) << ((unit & 0x200) >> 6)
///   value    = unit & 0x7FFFFFFF   (leaf units only; offset into table)
private struct CharsMap: Sendable {
    let units: [UInt32]
    let table: [UInt8]

    init?(blob: [UInt8]) {
        guard blob.count >= 4 else { return nil }
        let trieSize = Int(UInt32(blob[0]) | UInt32(blob[1]) << 8
            | UInt32(blob[2]) << 16 | UInt32(blob[3]) << 24)
        // Matches sentencepiece's sanity checks: multiple of 1 KiB, ≥ 1 KiB.
        guard trieSize >= 1024, trieSize & 0x3FF == 0,
              trieSize + 4 <= blob.count else { return nil }
        var units = [UInt32]()
        units.reserveCapacity(trieSize / 4)
        var i = 4
        while i < 4 + trieSize {
            units.append(UInt32(blob[i]) | UInt32(blob[i + 1]) << 8
                | UInt32(blob[i + 2]) << 16 | UInt32(blob[i + 3]) << 24)
            i += 4
        }
        let table = Array(blob[(4 + trieSize)...])
        guard table.last == 0 else { return nil }
        self.units = units
        self.table = table
    }

    private func offset(_ u: UInt32) -> Int {
        Int(u >> 10) << Int((u & 0x200) >> 6)
    }

    /// Longest charsmap key that is a prefix of `key[0...]`.
    /// Returns (value = offset into `table`, length = bytes consumed).
    /// Mirrors darts commonPrefixSearch keeping only the longest result.
    func longestMatch(_ key: some Sequence<UInt8>) -> (value: Int, length: Int)? {
        guard !units.isEmpty else { return nil }
        var best: (Int, Int)?
        var node = 0
        node ^= offset(units[node])
        var i = 0
        for byte in key {
            node ^= Int(byte)
            if node < 0 || node >= units.count { return best }
            let u = units[node]
            // label check incl. MSB (leaf units never match a byte label).
            if (u & 0x800000FF) != UInt32(byte) { return best }
            node ^= offset(u)
            if (u & 0x100) != 0 && node >= 0 && node < units.count {
                best = (Int(units[node] & 0x7FFFFFFF), i + 1)
            }
            i += 1
        }
        return best
    }

    /// NUL-terminated replacement string starting at `value` in the table.
    func replacement(at value: Int) -> ArraySlice<UInt8> {
        guard value >= 0, value < table.count else { return [] }
        let end = table[value...].firstIndex(of: 0) ?? table.count
        return table[value..<end]
    }
}

// MARK: - Minimal protobuf wire reader

/// Hand-rolled protobuf reader: varint, fixed32, length-delimited.
/// Group wire types are unsupported — ModelProto never uses them.
/// `pos` is an element offset into `data` (not an index).
private struct ProtoReader {
    let data: ArraySlice<UInt8>
    var pos = 0

    init(_ data: [UInt8]) { self.data = data[...] }
    init(_ data: ArraySlice<UInt8>) { self.data = data }

    /// Returns (fieldNumber, wireType); nil at end or on tag 0.
    /// A giant varint tag must not trap `Int(...)` — treat as unreadable.
    mutating func tag() -> (field: Int, wire: Int)? {
        guard let t = varint(), t != 0,
              let field = Int(exactly: t >> 3) else { return nil }
        return (field, Int(t & 7))
    }

    mutating func varint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while pos < data.count && shift < 70 {
            let b = data[data.index(data.startIndex, offsetBy: pos)]
            pos += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    mutating func fieldData() -> ArraySlice<UInt8>? {
        guard let len = varint() else { return nil }
        // `Int(len)` traps when the varint exceeds Int.max; a malformed
        // model file must fail soft, not crash the parser.
        guard let n = Int(exactly: len), n <= data.count - pos else { return nil }
        let r = data.dropFirst(pos).prefix(n)
        pos += n
        return r
    }

    mutating func fixed32Float() -> Float? {
        guard pos + 4 <= data.count else { return nil }
        let i0 = data.index(data.startIndex, offsetBy: pos)
        let v = UInt32(data[i0]) | UInt32(data[i0 + 1]) << 8
            | UInt32(data[i0 + 2]) << 16 | UInt32(data[i0 + 3]) << 24
        pos += 4
        return Float(bitPattern: v)
    }

    @discardableResult
    mutating func skip(wire: Int) -> Bool {
        switch wire {
        case 0: return varint() != nil
        case 1:
            pos += 8
            return pos <= data.count
        case 2: return fieldData() != nil
        case 5:
            pos += 4
            return pos <= data.count
        default: return false
        }
    }
}
