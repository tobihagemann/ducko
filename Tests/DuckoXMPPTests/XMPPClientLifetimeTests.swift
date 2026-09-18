import DuckoTestSupport
import Testing
@testable import DuckoXMPP

struct XMPPClientLifetimeTests {
    @Test(arguments: [false, true])
    func `registered modules do not retain their client`(registerModule: Bool) async {
        var client: XMPPClient? = XMPPClient(
            domain: "example.com", credentials: .init(username: "user", password: "pass"),
            transport: MockTransport()
        )
        weak var releasedClient = client
        if registerModule { await client?.register(PingModule()) }
        await client?.disconnect()
        client = nil
        #expect(releasedClient == nil)
    }
}
