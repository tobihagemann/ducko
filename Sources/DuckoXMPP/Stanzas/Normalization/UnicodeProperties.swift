// Typed accessors over the generated `UnicodeTables` data (Unicode 17.0.0).
//
// The generated partitions are stored as compact `start:value` breakpoint strings; they
// are parsed once into sorted range arrays on first use and queried by binary search.

/// PRECIS / IDNA2008 derived property value (RFC 8264 §9, RFC 5892 §3).
enum DerivedProperty: UInt8 {
    case pvalid = 0
    case contextj = 1
    case contexto = 2
    case disallowed = 3
    case unassigned = 4
}

/// Bidi_Class values used by the RFC 5893 Bidi Rule. `other` collapses every class the
/// rule never admits (B, S, WS, and the explicit-formatting codes).
enum BidiClass: UInt8 {
    case l = 0
    case r = 1
    case al = 2
    case an = 3
    case en = 4
    case es = 5
    case cs = 6
    case et = 7
    case on = 8
    case bn = 9
    case nsm = 10
    case other = 11
}

enum UnicodeProperties {
    /// A total partition over `0...0x10FFFF`: `starts[i]` begins a run that ends just before
    /// `starts[i + 1]`. Lookup returns the value of the run containing the code point.
    private struct Partition {
        let starts: [UInt32]
        let values: [UInt8]

        func value(for codePoint: UInt32) -> UInt8 {
            var low = 0
            var high = starts.count - 1
            var match = 0
            while low <= high {
                let mid = (low + high) / 2
                if starts[mid] <= codePoint {
                    match = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            return values[match]
        }
    }

    private static func parsePartition(_ encoded: String) -> Partition {
        var starts: [UInt32] = []
        var values: [UInt8] = []
        for entry in encoded.split(separator: ";") {
            let fields = entry.split(separator: ":")
            starts.append(UInt32(fields[0], radix: 16)!)
            values.append(UInt8(fields[1], radix: 16)!)
        }
        return Partition(starts: starts, values: values)
    }

    private static let identifierPartition = parsePartition(UnicodeTables.identifierClass)
    private static let freeformPartition = parsePartition(UnicodeTables.freeformClass)
    private static let idnaPartition = parsePartition(UnicodeTables.idna)
    private static let bidiPartition = parsePartition(UnicodeTables.bidiClass)

    private static let widthTable: [UInt32: [Unicode.Scalar]] = {
        var table: [UInt32: [Unicode.Scalar]] = [:]
        for entry in UnicodeTables.widthMapping.split(separator: ";") {
            let sides = entry.split(separator: "=")
            guard let codePoint = UInt32(sides[0], radix: 16) else { continue }
            let targets = sides[1].split(separator: " ").compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }
            table[codePoint] = targets
        }
        return table
    }()

    /// PRECIS IdentifierClass derived property (basis for `UsernameCaseMapped`).
    static func identifierClass(_ scalar: Unicode.Scalar) -> DerivedProperty {
        DerivedProperty(rawValue: identifierPartition.value(for: scalar.value))!
    }

    /// PRECIS FreeformClass derived property (basis for `OpaqueString`).
    static func freeformClass(_ scalar: Unicode.Scalar) -> DerivedProperty {
        DerivedProperty(rawValue: freeformPartition.value(for: scalar.value))!
    }

    /// IDNA2008 (RFC 5892) derived property for domain labels.
    static func idna(_ scalar: Unicode.Scalar) -> DerivedProperty {
        DerivedProperty(rawValue: idnaPartition.value(for: scalar.value))!
    }

    static func bidiClass(_ scalar: Unicode.Scalar) -> BidiClass {
        BidiClass(rawValue: bidiPartition.value(for: scalar.value))!
    }

    /// PRECIS Width-Mapping replacement for a Wide/Narrow code point, or `nil` if none.
    static func widthMapping(_ scalar: Unicode.Scalar) -> [Unicode.Scalar]? {
        widthTable[scalar.value]
    }
}
