/// Punycode (RFC 3492) encode/decode using only the Swift stdlib (no Foundation).
///
/// Used by the IDNA layer to convert between U-labels and `xn--` A-labels. `decode`
/// consumes attacker-controlled `xn--` labels, so every arithmetic step is overflow-checked
/// and any malformed/out-of-range input returns `nil` (fail-closed) rather than trapping
/// (RFC 3492 §6.2).
enum Punycode {
    private static let base: UInt32 = 36
    private static let tmin: UInt32 = 1
    private static let tmax: UInt32 = 26
    private static let skew: UInt32 = 38
    private static let damp: UInt32 = 700
    private static let initialBias: UInt32 = 72
    private static let initialN: UInt32 = 128
    private static let delimiter = Unicode.Scalar(0x2D)! // '-'

    /// RFC 3492 threshold `t(k)` for the current digit position.
    private static func threshold(k: UInt32, bias: UInt32) -> UInt32 {
        k <= bias ? tmin : (k >= bias + tmax ? tmax : k - bias)
    }

    private static func adapt(delta: UInt32, numPoints: UInt32, firstTime: Bool) -> UInt32 {
        var delta = firstTime ? delta / damp : delta / 2
        delta += delta / numPoints
        var k: UInt32 = 0
        let deltaCeiling = ((base - tmin) * tmax) / 2
        while delta > deltaCeiling {
            delta /= (base - tmin)
            k += base
        }
        return k + ((base - tmin + 1) * delta) / (delta + skew)
    }

    /// Maps a digit value `0...35` to its Punycode character (`a-z`, then `0-9`).
    private static func encodeDigit(_ digit: UInt32) -> Unicode.Scalar {
        Unicode.Scalar(digit < 26 ? digit + 0x61 : digit - 26 + 0x30)!
    }

    /// Maps a Punycode character to its digit value, or `base` (invalid) for non-digits.
    private static func decodeDigit(_ scalar: Unicode.Scalar) -> UInt32 {
        let value = scalar.value
        switch value {
        case 0x41 ... 0x5A: return value - 0x41 // A-Z
        case 0x61 ... 0x7A: return value - 0x61 // a-z
        case 0x30 ... 0x39: return value - 0x30 + 26 // 0-9
        default: return base
        }
    }

    // MARK: - Decode

    // Decodes the Punycode digits of a label (without the `xn--` prefix) to its U-label scalars.
    // swiftlint:disable:next cyclomatic_complexity
    static func decode(_ input: Substring) -> [Unicode.Scalar]? {
        var n = initialN
        var i: UInt32 = 0
        var bias = initialBias
        var output: [Unicode.Scalar] = []

        var cursor = input.startIndex
        if let lastDelimiter = input.lastIndex(of: "-") {
            for scalar in input[..<lastDelimiter].unicodeScalars {
                guard scalar.value < 0x80 else { return nil }
                output.append(scalar)
            }
            cursor = input.index(after: lastDelimiter)
        }

        let scalars = Array(input.unicodeScalars)
        // Recompute the cursor as an offset into the scalar array.
        var position = input.unicodeScalars.distance(from: input.startIndex, to: cursor)

        while position < scalars.count {
            let oldi = i
            var weight: UInt32 = 1
            var k = base
            while true {
                guard position < scalars.count else { return nil }
                let digit = decodeDigit(scalars[position])
                guard digit < base else { return nil }
                position += 1

                let (scaled, mulOverflow) = digit.multipliedReportingOverflow(by: weight)
                if mulOverflow { return nil }
                let (sum, addOverflow) = i.addingReportingOverflow(scaled)
                if addOverflow { return nil }
                i = sum

                let t = threshold(k: k, bias: bias)
                if digit < t { break }

                let (newWeight, weightOverflow) = weight.multipliedReportingOverflow(by: base - t)
                if weightOverflow { return nil }
                weight = newWeight
                k += base
            }

            let outputLength = UInt32(output.count + 1)
            bias = adapt(delta: i - oldi, numPoints: outputLength, firstTime: oldi == 0)

            let (advanced, nOverflow) = n.addingReportingOverflow(i / outputLength)
            if nOverflow { return nil }
            n = advanced
            i %= outputLength

            guard let scalar = Unicode.Scalar(n) else { return nil }
            output.insert(scalar, at: Int(i))
            i += 1
        }

        return output
    }

    // MARK: - Encode

    // Encodes U-label scalars to Punycode digits (without the `xn--` prefix), or `nil` on overflow.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func encode(_ input: [Unicode.Scalar]) -> String? {
        var n = initialN
        var delta: UInt32 = 0
        var bias = initialBias
        var output: [Unicode.Scalar] = []

        for scalar in input where scalar.value < 0x80 {
            output.append(scalar)
        }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 {
            output.append(delimiter)
        }

        while handled < input.count {
            var m = UInt32.max
            for scalar in input where scalar.value >= n && scalar.value < m {
                m = scalar.value
            }

            let (scaled, mulOverflow) = (m - n).multipliedReportingOverflow(by: UInt32(handled + 1))
            if mulOverflow { return nil }
            let (sum, addOverflow) = delta.addingReportingOverflow(scaled)
            if addOverflow { return nil }
            delta = sum
            n = m

            for scalar in input {
                let value = scalar.value
                if value < n {
                    let (incremented, overflow) = delta.addingReportingOverflow(1)
                    if overflow { return nil }
                    delta = incremented
                }
                if value == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = threshold(k: k, bias: bias)
                        if q < t { break }
                        output.append(encodeDigit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(encodeDigit(q))
                    bias = adapt(delta: delta, numPoints: UInt32(handled + 1), firstTime: handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }

        var result = String.UnicodeScalarView()
        result.append(contentsOf: output)
        return String(result)
    }
}
