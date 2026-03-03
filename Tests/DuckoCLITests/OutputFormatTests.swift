import Testing
@testable import DuckoCLI

struct OutputFormatTests {
    @Test func `plain makes plain formatter`() {
        let formatter = OutputFormat.plain.makeFormatter()
        #expect(formatter is PlainFormatter)
    }

    @Test func `ansi makes ANSI formatter`() {
        let formatter = OutputFormat.ansi.makeFormatter()
        #expect(formatter is ANSIFormatter)
    }

    @Test func `json makes JSON formatter`() {
        let formatter = OutputFormat.json.makeFormatter()
        #expect(formatter is JSONFormatter)
    }
}
