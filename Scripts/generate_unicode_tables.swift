#!/usr/bin/env swift
//
// Generates `Sources/DuckoXMPP/Stanzas/Normalization/UnicodeTables.generated.swift`
// from the Unicode Character Database (UCD).
//
// This script is run MANUALLY — it is not part of `swift build`. Re-run it only when
// bumping the pinned Unicode version (and confirm the host stdlib reports the same
// version via the sentinel assertion below, because the generated derived-property
// tables must agree with the OS-supplied NFC/lowercase/NFKC operations at runtime).
//
// Pinned version: Unicode 17.0.0 (matches the macOS 26 stdlib `String`).
//
// Inputs (download into one directory, then pass it as the first argument):
//   base="https://www.unicode.org/Public/17.0.0/ucd"
//   curl -sO "$base/UnicodeData.txt"
//   curl -sO "$base/Blocks.txt"
//   curl -sO "$base/CaseFolding.txt"
//   curl -sO "$base/HangulSyllableType.txt"
//   curl -s "$base/extracted/DerivedBidiClass.txt" -o DerivedBidiClass.txt
//
// Usage:
//   swift Scripts/generate_unicode_tables.swift <ucd-dir>
//
// Derivations implemented:
//   - PRECIS IdentifierClass / FreeformClass derived property (RFC 8264 §9).
//   - IDNA2008 derived property (RFC 5892 §2–3, Appendix B exceptions).
//   - Bidi_Class (RFC 5893 input table, with UCD @missing defaults).
//   - PRECIS Width_Mapping (Wide/Narrow decompositions only — never full NFKC).
//
// Properties read from the host stdlib (`Unicode.Scalar.Properties`, pinned to the
// asserted version): General_Category, Default_Ignorable_Code_Point,
// Noncharacter_Code_Point, White_Space, Join_Control. NFKC comes from Foundation.
// Everything else is read from the UCD text files above.

import Foundation

let pinnedVersion = "17.0.0"
let maxCodePoint: UInt32 = 0x10FFFF

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: generate_unicode_tables.swift <ucd-dir>\n".utf8))
    exit(2)
}

let ucdDir = CommandLine.arguments[1]

// MARK: - Host version assertion

// U+088F and U+0C5C are assigned in Unicode 17.0 but not 16.0; if the host stdlib does
// not see them as assigned letters, its Unicode version predates the pinned tables and
// the generated NFKC-derived categories would disagree with the runtime.
for sentinel: UInt32 in [0x088F, 0x0C5C] {
    let scalar = Unicode.Scalar(sentinel)!
    guard scalar.properties.generalCategory != .unassigned else {
        FileHandle.standardError.write(Data(
            "host stdlib Unicode version is older than \(pinnedVersion) (U+\(String(sentinel, radix: 16)) unassigned)\n".utf8
        ))
        exit(1)
    }
}

// MARK: - UCD file loading

func readUCD(_ name: String) -> String {
    let path = "\(ucdDir)/\(name)"
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
        FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
        exit(1)
    }
    return contents
}

/// Parses `START..END ; VALUE` / `CP ; VALUE` lines (ignoring `#` comments) into (range, value) pairs.
func parsePropertyLines(_ text: String) -> [(ClosedRange<UInt32>, String)] {
    var result: [(ClosedRange<UInt32>, String)] = []
    for rawLine in text.split(separator: "\n") {
        let line = rawLine.prefix { $0 != "#" }
        let fields = line.split(separator: ";")
        guard fields.count >= 2 else { continue }
        let cpField = fields[0].trimmingCharacters(in: .whitespaces)
        let value = fields[1].trimmingCharacters(in: .whitespaces)
        guard !cpField.isEmpty, !value.isEmpty else { continue }
        let bounds = cpField.components(separatedBy: "..")
        guard let start = UInt32(bounds[0], radix: 16) else { continue }
        let end = bounds.count > 1 ? (UInt32(bounds[1], radix: 16) ?? start) : start
        result.append((start ... end, value))
    }
    return result
}

// MARK: - Bidi_Class (with @missing defaults)

var bidiClass = [UInt8](repeating: bidiCode("L"), count: Int(maxCodePoint) + 1)

func bidiCode(_ name: String) -> UInt8 {
    switch name {
    case "L", "Left_To_Right": return 0
    case "R", "Right_To_Left": return 1
    case "AL", "Arabic_Letter": return 2
    case "AN", "Arabic_Number": return 3
    case "EN", "European_Number": return 4
    case "ES", "European_Separator": return 5
    case "CS", "Common_Separator": return 6
    case "ET", "European_Terminator": return 7
    case "ON", "Other_Neutral": return 8
    case "BN", "Boundary_Neutral": return 9
    case "NSM", "Nonspacing_Mark": return 10
    default: return 11 // other (B, S, WS, and explicit-formatting codes)
    }
}

let bidiText = readUCD("DerivedBidiClass.txt")
// Apply UCD @missing defaults first (they override the blanket L default for RTL blocks),
// then the explicit assignments.
for rawLine in bidiText.split(separator: "\n") {
    guard rawLine.contains("@missing:") else { continue }
    let payload = rawLine.split(separator: ":", maxSplits: 1)[1]
    let fields = payload.split(separator: ";")
    guard fields.count >= 2 else { continue }
    let bounds = fields[0].trimmingCharacters(in: .whitespaces).components(separatedBy: "..")
    guard let start = UInt32(bounds[0], radix: 16) else { continue }
    let end = bounds.count > 1 ? (UInt32(bounds[1], radix: 16) ?? start) : start
    let code = bidiCode(fields[1].trimmingCharacters(in: .whitespaces))
    for cp in start ... end where cp <= maxCodePoint {
        bidiClass[Int(cp)] = code
    }
}

for (range, value) in parsePropertyLines(bidiText) {
    let code = bidiCode(value)
    for cp in range where cp <= maxCodePoint {
        bidiClass[Int(cp)] = code
    }
}

// MARK: - Hangul_Syllable_Type (OldHangulJamo = L, V, T)

var oldHangulJamo = Set<UInt32>()
for (range, value) in parsePropertyLines(readUCD("HangulSyllableType.txt")) where ["L", "V", "T"].contains(value) {
    for cp in range {
        oldHangulJamo.insert(cp)
    }
}

// MARK: - IgnorableBlocks (IDNA category D)

let ignorableBlockNames: Set<String> = [
    "Combining Diacritical Marks for Symbols",
    "Musical Symbols",
    "Ancient Greek Musical Notation"
]
var ignorableBlocks: [ClosedRange<UInt32>] = []
for (range, value) in parsePropertyLines(readUCD("Blocks.txt")) where ignorableBlockNames.contains(value) {
    ignorableBlocks.append(range)
}

func inIgnorableBlock(_ cp: UInt32) -> Bool {
    ignorableBlocks.contains { $0.contains(cp) }
}

// MARK: - CaseFolding (C + F mappings)

var caseFold = [UInt32: [UInt32]]()
for rawLine in readUCD("CaseFolding.txt").split(separator: "\n") {
    let line = rawLine.prefix { $0 != "#" }
    let fields = line.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    guard fields.count >= 3, let cp = UInt32(fields[0], radix: 16) else { continue }
    let status = fields[1]
    guard status == "C" || status == "F" else { continue }
    caseFold[cp] = fields[2].split(separator: " ").compactMap { UInt32($0, radix: 16) }
}

func caseFolded(_ s: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in s.unicodeScalars {
        if let mapping = caseFold[scalar.value] {
            for value in mapping {
                scalars.append(Unicode.Scalar(value)!)
            }
        } else {
            scalars.append(scalar)
        }
    }
    return String(scalars)
}

// MARK: - Wide/Narrow width decomposition (UnicodeData.txt field 5)

var widthMapping = [(UInt32, [UInt32])]()
for rawLine in readUCD("UnicodeData.txt").split(separator: "\n") {
    let fields = rawLine.split(separator: ";", omittingEmptySubsequences: false)
    guard fields.count > 5, let cp = UInt32(fields[0], radix: 16) else { continue }
    let decomposition = fields[5]
    guard decomposition.hasPrefix("<wide>") || decomposition.hasPrefix("<narrow>") else { continue }
    let targets = decomposition.split(separator: " ").compactMap { UInt32($0, radix: 16) }
    guard !targets.isEmpty else { continue }
    widthMapping.append((cp, targets))
}

// MARK: - Exceptions (RFC 5892 §2.6 / RFC 8264 §9.6)

enum Derived: UInt8 { case pvalid = 0, contextj = 1, contexto = 2, disallowed = 3, unassigned = 4 }

var exceptions = [UInt32: Derived]()
for cp: UInt32 in [0x00DF, 0x03C2, 0x06FD, 0x06FE, 0x0F0B, 0x3007] {
    exceptions[cp] = .pvalid
}

for cp: UInt32 in [0x00B7, 0x0375, 0x05F3, 0x05F4, 0x30FB] {
    exceptions[cp] = .contexto
}

for cp: UInt32 in 0x0660 ... 0x0669 {
    exceptions[cp] = .contexto
}

for cp: UInt32 in 0x06F0 ... 0x06F9 {
    exceptions[cp] = .contexto
}

for cp: UInt32 in [0x0640, 0x07FA, 0x302E, 0x302F, 0x303B] {
    exceptions[cp] = .disallowed
}

for cp: UInt32 in 0x3031 ... 0x3035 {
    exceptions[cp] = .disallowed
}

// MARK: - Per-code-point category helpers (host stdlib)

func isLetterDigits(_ gc: Unicode.GeneralCategory) -> Bool {
    switch gc {
    case .lowercaseLetter, .uppercaseLetter, .otherLetter, .decimalNumber,
         .modifierLetter, .nonspacingMark, .spacingMark: return true
    default: return false
    }
}

func isOtherLetterDigits(_ gc: Unicode.GeneralCategory) -> Bool {
    switch gc {
    case .titlecaseLetter, .letterNumber, .otherNumber, .enclosingMark: return true
    default: return false
    }
}

func isSymbol(_ gc: Unicode.GeneralCategory) -> Bool {
    switch gc {
    case .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: return true
    default: return false
    }
}

func isPunctuation(_ gc: Unicode.GeneralCategory) -> Bool {
    switch gc {
    case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
         .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
    default: return false
    }
}

func nfkc(_ s: String) -> String {
    s.precomposedStringWithCompatibilityMapping
}

/// True if `s` is not NFKC-stable. Compares by scalar identity, NOT `String` equality —
/// `String ==` is canonical-equivalence-based and would treat a canonical singleton like
/// U+2126 (OHM SIGN ≡ U+03A9) as unchanged, missing its HasCompat/Unstable status.
func changesUnderNFKC(_ s: String) -> Bool {
    Array(nfkc(s).unicodeScalars) != Array(s.unicodeScalars)
}

// MARK: - Derived property algorithms

/// RFC 8264 §9 — `freeform` toggles the ID_DIS-or-FREE_PVAL branches.
func precisDerived(_ scalar: Unicode.Scalar, freeform: Bool) -> Derived {
    let cp = scalar.value
    if let exception = exceptions[cp] { return exception }
    // BackwardCompatible (G): empty set.
    let gc = scalar.properties.generalCategory
    if gc == .unassigned, !scalar.properties.isNoncharacterCodePoint { return .unassigned }
    if (0x21 ... 0x7E).contains(cp) { return .pvalid }
    if scalar.properties.isJoinControl { return .contextj }
    if oldHangulJamo.contains(cp) { return .disallowed }
    if scalar.properties.isDefaultIgnorableCodePoint || scalar.properties.isNoncharacterCodePoint { return .disallowed }
    if gc == .control { return .disallowed }
    if changesUnderNFKC(String(scalar)) { return freeform ? .pvalid : .disallowed }
    if isLetterDigits(gc) { return .pvalid }
    if isOtherLetterDigits(gc) { return freeform ? .pvalid : .disallowed }
    if gc == .spaceSeparator { return freeform ? .pvalid : .disallowed }
    if isSymbol(gc) { return freeform ? .pvalid : .disallowed }
    if isPunctuation(gc) { return freeform ? .pvalid : .disallowed }
    return .disallowed
}

/// RFC 5892 §3.
func idnaDerived(_ scalar: Unicode.Scalar) -> Derived {
    let cp = scalar.value
    if let exception = exceptions[cp] { return exception }
    // BackwardCompatible (G): empty set.
    let gc = scalar.properties.generalCategory
    if gc == .unassigned, !scalar.properties.isNoncharacterCodePoint { return .unassigned }
    if cp == 0x002D || (0x0030 ... 0x0039).contains(cp) || (0x0061 ... 0x007A).contains(cp) { return .pvalid }
    if scalar.properties.isJoinControl { return .contextj }
    let s = String(scalar)
    if Array(nfkc(caseFolded(nfkc(s))).unicodeScalars) != Array(s.unicodeScalars) { return .disallowed } // Unstable (B)
    if scalar.properties.isDefaultIgnorableCodePoint || scalar.properties.isWhitespace
        || scalar.properties.isNoncharacterCodePoint { return .disallowed } // IgnorableProperties (C)
    if inIgnorableBlock(cp) { return .disallowed } // IgnorableBlocks (D)
    if oldHangulJamo.contains(cp) { return .disallowed }
    if isLetterDigits(gc) { return .pvalid }
    return .disallowed
}

// MARK: - Emit

/// Encodes a total partition over 0...maxCodePoint as ascending `start:value` breakpoints
/// (the next start implies the previous run's end). `value` is a single hex digit.
func encodePartition(_ values: (UInt32) -> UInt8) -> String {
    var entries: [String] = []
    var previous: UInt8?
    for cp in 0 ... maxCodePoint {
        let value = values(cp)
        if value != previous {
            entries.append("\(String(cp, radix: 16)):\(String(value, radix: 16))")
            previous = value
        }
    }
    return entries.joined(separator: ";")
}

/// Surrogates (`Unicode.Scalar(cp) == nil`) are DISALLOWED.
let identifierData = encodePartition { cp in
    guard let scalar = Unicode.Scalar(cp) else { return Derived.disallowed.rawValue }
    return precisDerived(scalar, freeform: false).rawValue
}

let freeformData = encodePartition { cp in
    guard let scalar = Unicode.Scalar(cp) else { return Derived.disallowed.rawValue }
    return precisDerived(scalar, freeform: true).rawValue
}

let idnaData = encodePartition { cp in
    guard let scalar = Unicode.Scalar(cp) else { return Derived.disallowed.rawValue }
    return idnaDerived(scalar).rawValue
}

let bidiData = encodePartition { cp in bidiClass[Int(cp)] }

let widthData = widthMapping
    .sorted { $0.0 < $1.0 }
    .map { "\(String($0.0, radix: 16))=\($0.1.map { String($0, radix: 16) }.joined(separator: " "))" }
    .joined(separator: ";")

func chunkedLiteral(_ s: String, indent: String) -> String {
    // Break a long literal across concatenated lines so individual source lines stay readable.
    let chunkSize = 2000
    var chunks: [String] = []
    var index = s.startIndex
    while index < s.endIndex {
        let end = s.index(index, offsetBy: chunkSize, limitedBy: s.endIndex) ?? s.endIndex
        chunks.append(String(s[index ..< end]))
        index = end
    }
    if chunks.isEmpty { chunks = [""] }
    return chunks.map { "\(indent)\"\($0)\"" }.joined(separator: " +\n")
}

let output = """
// Generated by Scripts/generate_unicode_tables.swift — DO NOT EDIT.
//
// Unicode \(pinnedVersion). Derived-property partitions (PRECIS IdentifierClass /
// FreeformClass per RFC 8264 §9, IDNA2008 per RFC 5892), Bidi_Class (RFC 5893 input),
// and the PRECIS Wide/Narrow width mapping. See Scripts/generate_unicode_tables.swift.

enum UnicodeTables {
    static let unicodeVersion = "\(pinnedVersion)"

    // Total partitions over 0...0x10FFFF as ascending "start:value" breakpoints (hex);
    // each run extends to the next start. value: 0=PVALID 1=CONTEXTJ 2=CONTEXTO
    // 3=DISALLOWED 4=UNASSIGNED.
    static let identifierClass =
\(chunkedLiteral(identifierData, indent: "        "))

    static let freeformClass =
\(chunkedLiteral(freeformData, indent: "        "))

    static let idna =
\(chunkedLiteral(idnaData, indent: "        "))

    // Bidi_Class breakpoints; value: 0=L 1=R 2=AL 3=AN 4=EN 5=ES 6=CS 7=ET 8=ON 9=BN
    // 10=NSM 11=other.
    static let bidiClass =
\(chunkedLiteral(bidiData, indent: "        "))

    // Sparse Wide/Narrow width map as "cp=scalar[ scalar...]" (hex), ';'-separated.
    static let widthMapping =
\(chunkedLiteral(widthData, indent: "        "))
}
"""

let outputPath = "Sources/DuckoXMPP/Stanzas/Normalization/UnicodeTables.generated.swift"
try! output.write(toFile: outputPath, atomically: true, encoding: .utf8)
FileHandle.standardError.write(Data("wrote \(outputPath)\n".utf8))
