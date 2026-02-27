import Testing
@testable import DuckoCLI

struct OutputFormatTests {
    @Test func plainMakesPlainFormatter() {
        let formatter = OutputFormat.plain.makeFormatter()
        #expect(formatter is PlainFormatter)
    }

    @Test func ansiMakesANSIFormatter() {
        let formatter = OutputFormat.ansi.makeFormatter()
        #expect(formatter is ANSIFormatter)
    }

    @Test func jsonMakesJSONFormatter() {
        let formatter = OutputFormat.json.makeFormatter()
        #expect(formatter is JSONFormatter)
    }
}
