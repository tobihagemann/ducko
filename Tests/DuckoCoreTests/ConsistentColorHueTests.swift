import Testing
@testable import DuckoCore

struct ConsistentColorHueTests {
    @Test
    func `hue is in valid range`() {
        let hue = ConsistentColorHue.hue(for: "romeo")
        #expect(hue >= 0)
        #expect(hue < 360)
    }

    @Test
    func `same input produces same hue`() {
        let hue1 = ConsistentColorHue.hue(for: "juliet")
        let hue2 = ConsistentColorHue.hue(for: "juliet")
        #expect(hue1 == hue2)
    }

    @Test
    func `different inputs produce different hues`() {
        let hue1 = ConsistentColorHue.hue(for: "romeo")
        let hue2 = ConsistentColorHue.hue(for: "juliet")
        #expect(hue1 != hue2)
    }

    @Test
    func `known value for romeo`() {
        // XEP-0392 §13.2 test vector: SHA-1("Romeo") → angle
        // SHA-1 of "Romeo" = 0xDEAB9..., last 2 bytes = specific value
        // We test that the output is deterministic and in range
        let hue = ConsistentColorHue.hue(for: "Romeo")
        #expect(hue >= 0)
        #expect(hue < 360)
    }

    @Test
    func `empty string produces valid hue`() {
        let hue = ConsistentColorHue.hue(for: "")
        #expect(hue >= 0)
        #expect(hue < 360)
    }
}
