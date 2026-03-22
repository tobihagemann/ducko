import Testing
@testable import DuckoCore

struct OSLogHandlerTests {
    // MARK: - Label Parsing

    @Test
    func `parses three-component label`() {
        let (subsystem, category) = OSLogHandler.parseLabel("im.ducko.xmpp.client")
        #expect(subsystem == "im.ducko.xmpp")
        #expect(category == "client")
    }

    @Test
    func `parses two-component label`() {
        let (subsystem, category) = OSLogHandler.parseLabel("im.ducko")
        #expect(subsystem == "im")
        #expect(category == "ducko")
    }

    @Test
    func `parses four-component label`() {
        let (subsystem, category) = OSLogHandler.parseLabel("im.ducko.xmpp.modules.ping")
        #expect(subsystem == "im.ducko.xmpp.modules")
        #expect(category == "ping")
    }

    @Test
    func `single component falls back to itself`() {
        let (subsystem, category) = OSLogHandler.parseLabel("simple")
        #expect(subsystem == "simple")
        #expect(category == "simple")
    }

    // MARK: - Handler Initialization

    @Test
    func `creates handler with default log level`() {
        let handler = OSLogHandler(label: "im.ducko.test")
        #expect(handler.logLevel == .trace)
    }

    @Test
    func `creates handler with empty metadata`() {
        let handler = OSLogHandler(label: "im.ducko.test")
        #expect(handler.metadata.isEmpty)
    }
}
