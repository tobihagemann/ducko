/// Builder for configuring and creating an ``XMPPClient``.
struct XMPPClientBuilder {
    private let domain: String
    private let credentials: XMPPClient.Credentials
    private var transport: (any XMPPTransport)?
    private var modules: [any XMPPModule] = []

    init(domain: String, username: String, password: String) {
        self.domain = domain
        self.credentials = XMPPClient.Credentials(username: username, password: password)
    }

    /// Sets a custom transport (e.g. for testing with ``MockTransport``).
    mutating func withTransport(_ transport: any XMPPTransport) {
        self.transport = transport
    }

    /// Adds a module to be registered on the client.
    mutating func withModule(_ module: any XMPPModule) {
        modules.append(module)
    }

    /// Creates and configures the client. Must be `async` because ``XMPPClient/register(_:)`` is actor-isolated.
    func build() async -> XMPPClient {
        let client = XMPPClient(
            domain: domain,
            credentials: credentials,
            transport: transport ?? NWConnectionTransport()
        )

        for module in modules {
            await client.register(module)
        }

        return client
    }
}
