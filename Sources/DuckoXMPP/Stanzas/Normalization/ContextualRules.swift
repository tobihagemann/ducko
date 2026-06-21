/// RFC 5892 Appendix A contextual rules, shared by PRECIS (localpart/resourcepart) and IDNA
/// (domain labels) since the rule set is identical.
///
/// Only the rules decidable without `Joining_Type`/`Script` (not exposed by the stdlib) are
/// accepted; the rest — the ZWNJ joining-type branch, Greek keraia, Hebrew geresh/gershayim,
/// and Katakana middle dot — are conservatively rejected.
enum ContextualRules {
    /// Evaluates the contextual rule for the CONTEXTJ/CONTEXTO code point at `index`.
    static func satisfied(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        switch scalars[index].value {
        case 0x200C, 0x200D: // ZERO WIDTH NON-JOINER / JOINER: require a preceding Virama.
            return index > 0 && scalars[index - 1].properties.canonicalCombiningClass.rawValue == 9
        case 0x00B7: // MIDDLE DOT: only between U+006C.
            return index > 0 && index + 1 < scalars.count
                && scalars[index - 1].value == 0x006C && scalars[index + 1].value == 0x006C
        case 0x0660 ... 0x0669: // ARABIC-INDIC DIGITS: must not mix with Extended Arabic-Indic.
            return !scalars.contains { (0x06F0 ... 0x06F9).contains($0.value) }
        case 0x06F0 ... 0x06F9: // EXTENDED ARABIC-INDIC DIGITS: must not mix with Arabic-Indic.
            return !scalars.contains { (0x0660 ... 0x0669).contains($0.value) }
        default:
            return false
        }
    }
}
