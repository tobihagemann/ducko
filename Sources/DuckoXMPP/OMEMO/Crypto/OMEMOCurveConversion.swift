/// Ed25519 (Edwards) ↔ X25519 (Montgomery) public key conversion.
///
/// Private keys share the same 32-byte scalar and can be converted via CryptoKit's
/// `rawRepresentation`. Public keys require the birational map between curve forms:
/// - Edwards → Montgomery: `u = (1 + y) / (1 - y) mod p`
/// - Montgomery → Edwards: `y = (u - 1) / (u + 1) mod p`
///
/// where `p = 2^255 - 19`.
enum OMEMOCurveConversion {
    /// Converts an Ed25519 public key (32 bytes) to an X25519 public key (32 bytes).
    ///
    /// The Ed25519 key encodes the y-coordinate of the Edwards curve point.
    /// Returns `nil` if the input is invalid (wrong length or `1 - y == 0`).
    static func ed25519ToX25519(_ edKey: [UInt8]) -> [UInt8]? {
        guard edKey.count == 32 else { return nil }

        let y = FieldElement.decode(edKey)
        let one = FieldElement.one

        // u = (1 + y) / (1 - y)
        let numerator = one.add(y)
        let denominator = one.subtract(y)
        guard let inverse = denominator.invert() else { return nil }
        let u = numerator.multiply(inverse)

        return u.encode()
    }

    /// Converts an X25519 public key (32 bytes) to an Ed25519 public key (32 bytes).
    ///
    /// The `signBit` determines the sign of the x-coordinate (bit 255 of the encoded point).
    /// Returns `nil` if the input is invalid (wrong length or `u + 1 == 0`).
    static func x25519ToEd25519(_ xKey: [UInt8], signBit: UInt8 = 0) -> [UInt8]? {
        guard xKey.count == 32 else { return nil }

        let u = FieldElement.decode(xKey)
        let one = FieldElement.one

        // y = (u - 1) / (u + 1)
        let numerator = u.subtract(one)
        let denominator = u.add(one)
        guard let inverse = denominator.invert() else { return nil }
        let y = numerator.multiply(inverse)

        var encoded = y.encode()
        // Set the sign bit (bit 7 of the last byte)
        encoded[31] = (encoded[31] & 0x7F) | ((signBit & 1) << 7)
        return encoded
    }
}

// MARK: - Field Arithmetic mod p = 2^255 - 19

/// A field element in GF(2^255 - 19) using 4 × 64-bit limbs (256 bits total).
///
/// Reduction is performed after each operation to keep values in [0, p).
/// Uses straightforward big-integer arithmetic with `UInt128` intermediates.
private struct FieldElement {
    /// 4 × 64-bit limbs, little-endian (index 0 is the least significant).
    let v: [UInt64]

    static let one = FieldElement(v: [1, 0, 0, 0])

    /// p = 2^255 - 19
    static let p = FieldElement(v: [
        0xFFFF_FFFF_FFFF_FFED,
        0xFFFF_FFFF_FFFF_FFFF,
        0xFFFF_FFFF_FFFF_FFFF,
        0x7FFF_FFFF_FFFF_FFFF
    ])

    // MARK: - Encode / Decode

    /// Decodes a 32-byte little-endian value into a field element.
    static func decode(_ bytes: [UInt8]) -> FieldElement {
        var adjusted = bytes
        adjusted[31] &= 0x7F // Clear sign bit

        var limbs = [UInt64](repeating: 0, count: 4)
        for k in 0 ..< 4 {
            for i in 0 ..< 8 {
                limbs[k] |= UInt64(adjusted[k * 8 + i]) << (8 * i)
            }
        }
        return FieldElement(v: limbs)
    }

    /// Encodes the field element as 32 bytes, little-endian.
    func encode() -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 32)
        for k in 0 ..< 4 {
            for i in 0 ..< 8 {
                result[k * 8 + i] = UInt8(truncatingIfNeeded: v[k] >> (8 * i))
            }
        }
        return result
    }

    // MARK: - Arithmetic

    /// Addition mod p.
    func add(_ other: FieldElement) -> FieldElement {
        var result = addRaw(other)
        if result.greaterThanOrEqualToP() {
            result = result.subtractP()
        }
        return result
    }

    /// Subtraction mod p.
    func subtract(_ other: FieldElement) -> FieldElement {
        if greaterThanOrEqual(other) {
            return subtractRaw(other)
        } else {
            return addRaw(Self.p).subtractRaw(other)
        }
    }

    /// Multiplication mod p.
    func multiply(_ other: FieldElement) -> FieldElement {
        let product = mul256(self, other)
        return reduce512(product)
    }

    /// Squaring mod p.
    func square() -> FieldElement {
        multiply(self)
    }

    /// Modular inverse via Fermat's little theorem: a^(p-2) mod p.
    func invert() -> FieldElement? {
        if v[0] == 0, v[1] == 0, v[2] == 0, v[3] == 0 { return nil }

        let z2 = square()
        let z4 = z2.square()
        let z8 = z4.square()
        let z9 = z8.multiply(self)
        let z11 = z9.multiply(z2)
        let z22 = z11.square()
        let z31 = z22.multiply(z9)

        return invertChain(z11: z11, z31: z31)
    }

    /// Squares a field element `n` times.
    func squareN(_ n: Int) -> FieldElement {
        var result = self
        for _ in 0 ..< n {
            result = result.square()
        }
        return result
    }

    // MARK: - Private Helpers

    private func invertChain(z11: FieldElement, z31: FieldElement) -> FieldElement {
        let z_10_0 = z31.squareN(5).multiply(z31)
        let z_20_0 = z_10_0.squareN(10).multiply(z_10_0)
        let z_40_0 = z_20_0.squareN(20).multiply(z_20_0)
        let z_50_0 = z_40_0.squareN(10).multiply(z_10_0)
        let z_100_0 = z_50_0.squareN(50).multiply(z_50_0)
        let z_200_0 = z_100_0.squareN(100).multiply(z_100_0)
        let z_250_0 = z_200_0.squareN(50).multiply(z_50_0)
        return z_250_0.squareN(5).multiply(z11)
    }

    private func addRaw(_ other: FieldElement) -> FieldElement {
        var result = [UInt64](repeating: 0, count: 4)
        var carry: UInt64 = 0
        for i in 0 ..< 4 {
            let sum = UInt128(v[i]) + UInt128(other.v[i]) + UInt128(carry)
            result[i] = UInt64(sum & 0xFFFF_FFFF_FFFF_FFFF)
            carry = UInt64(sum >> 64)
        }
        return FieldElement(v: result)
    }

    private func subtractRaw(_ other: FieldElement) -> FieldElement {
        var result = [UInt64](repeating: 0, count: 4)
        var borrow: UInt64 = 0
        for i in 0 ..< 4 {
            let wide = UInt128(v[i]) &- UInt128(other.v[i]) &- UInt128(borrow)
            result[i] = UInt64(wide & 0xFFFF_FFFF_FFFF_FFFF)
            borrow = (wide >> 127) != 0 ? 1 : 0
        }
        return FieldElement(v: result)
    }

    fileprivate func subtractP() -> FieldElement {
        subtractRaw(Self.p)
    }

    fileprivate func greaterThanOrEqualToP() -> Bool {
        greaterThanOrEqual(Self.p)
    }

    private func greaterThanOrEqual(_ other: FieldElement) -> Bool {
        if v[3] != other.v[3] { return v[3] > other.v[3] }
        if v[2] != other.v[2] { return v[2] > other.v[2] }
        if v[1] != other.v[1] { return v[1] > other.v[1] }
        return v[0] >= other.v[0]
    }
}

// MARK: - Multi-Precision Multiplication & Reduction

/// 256×256-bit multiplication producing an 8-element UInt64 array.
private func mul256(_ a: FieldElement, _ b: FieldElement) -> [UInt64] {
    var result = [UInt64](repeating: 0, count: 8)
    for i in 0 ..< 4 {
        var carry: UInt128 = 0
        for j in 0 ..< 4 {
            let product = UInt128(a.v[i]) * UInt128(b.v[j])
                + UInt128(result[i + j]) + carry
            result[i + j] = UInt64(product & 0xFFFF_FFFF_FFFF_FFFF)
            carry = product >> 64
        }
        result[i + 4] = UInt64(carry)
    }
    return result
}

/// Reduces a 512-bit value mod p = 2^255 - 19.
///
/// Uses the identity `2^256 ≡ 38 (mod p)` to fold the high 256 bits into the low.
private func reduce512(_ wide: [UInt64]) -> FieldElement {
    // result = low256 + 38 * high256
    var r = [UInt128](repeating: 0, count: 4)
    for i in 0 ..< 4 {
        r[i] = UInt128(wide[i]) &+ UInt128(wide[i + 4]) * 38
    }

    // Carry propagation
    for i in 0 ..< 3 {
        r[i + 1] = r[i + 1] &+ (r[i] >> 64)
        r[i] &= 0xFFFF_FFFF_FFFF_FFFF
    }

    // Fold bits above 255: overflow * 2^255 ≡ overflow * 19
    let overflow = r[3] >> 63
    r[3] &= 0x7FFF_FFFF_FFFF_FFFF
    r[0] = r[0] &+ overflow * 19

    // Carry again
    for i in 0 ..< 3 {
        r[i + 1] = r[i + 1] &+ (r[i] >> 64)
        r[i] &= 0xFFFF_FFFF_FFFF_FFFF
    }

    // One more overflow check
    let overflow2 = r[3] >> 63
    r[3] &= 0x7FFF_FFFF_FFFF_FFFF
    r[0] = r[0] &+ overflow2 * 19
    for i in 0 ..< 3 {
        r[i + 1] = r[i + 1] &+ (r[i] >> 64)
        r[i] &= 0xFFFF_FFFF_FFFF_FFFF
    }

    var result = FieldElement(v: r.map { UInt64($0) })
    if result.greaterThanOrEqualToP() {
        result = result.subtractP()
    }
    return result
}
