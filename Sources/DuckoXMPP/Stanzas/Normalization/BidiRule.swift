/// The Bidi Rule (RFC 5893 §2) for IDNA U-labels and PRECIS localparts.
///
/// The caller establishes the Bidi context (a domain is a "Bidi domain name" if any of its
/// labels is RTL; a PRECIS localpart is its own single context) and applies `satisfies` to
/// every label only when the context is a Bidi name — including pure-ASCII/LTR labels.
enum BidiRule {
    /// True if any character has Bidi class R, AL, or AN (RFC 5893 §1.4).
    static func isRTLLabel(_ scalars: [Unicode.Scalar]) -> Bool {
        scalars.contains { scalar in
            switch UnicodeProperties.bidiClass(scalar) {
            case .r, .al, .an: true
            case .l, .en, .es, .cs, .et, .on, .bn, .nsm, .other: false
            }
        }
    }

    /// Enforces the six numbered conditions of RFC 5893 §2 for a single label.
    static func satisfies(_ scalars: [Unicode.Scalar]) -> Bool {
        let classes = scalars.map(UnicodeProperties.bidiClass)
        guard let first = classes.first else { return false }
        switch first { // Condition 1: first character must be L, R, or AL.
        case .r, .al: return satisfiesRTL(classes)
        case .l: return satisfiesLTR(classes)
        case .an, .en, .es, .cs, .et, .on, .bn, .nsm, .other: return false
        }
    }

    private static func satisfiesRTL(_ classes: [BidiClass]) -> Bool {
        var hasEN = false
        var hasAN = false
        for bidiClass in classes {
            switch bidiClass { // Condition 2.
            case .r, .al, .an, .en, .es, .cs, .et, .on, .bn, .nsm: break
            case .l, .other: return false
            }
            if bidiClass == .en { hasEN = true }
            if bidiClass == .an { hasAN = true }
        }
        if hasEN, hasAN { return false } // Condition 4.
        guard let last = lastNonNSM(classes) else { return false }
        switch last { // Condition 3.
        case .r, .al, .en, .an: return true
        case .l, .es, .cs, .et, .on, .bn, .nsm, .other: return false
        }
    }

    private static func satisfiesLTR(_ classes: [BidiClass]) -> Bool {
        for bidiClass in classes {
            switch bidiClass { // Condition 5.
            case .l, .en, .es, .cs, .et, .on, .bn, .nsm: break
            case .r, .al, .an, .other: return false
            }
        }
        guard let last = lastNonNSM(classes) else { return false }
        switch last { // Condition 6.
        case .l, .en: return true
        case .r, .al, .an, .es, .cs, .et, .on, .bn, .nsm, .other: return false
        }
    }

    private static func lastNonNSM(_ classes: [BidiClass]) -> BidiClass? {
        classes.last { $0 != .nsm }
    }
}
