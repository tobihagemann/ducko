/// Builder for configuring and creating an ``XMPPClient``.
public struct XMPPClientBuilder {
    private let domain: String
    private let credentials: XMPPClient.Credentials
    private var transport: (any XMPPTransport)?
    private var interceptors: [any StanzaInterceptor] = []
    private var modules: [any XMPPModule] = []
    private var requireTLS: Bool = true
    private var preferredResource: String?

    public init(domain: String, username: String, password: String) {
        self.domain = domain
        self.credentials = XMPPClient.Credentials(username: username, password: password)
    }

    /// Sets whether TLS is required (default: `true`).
    public mutating func withRequireTLS(_ requireTLS: Bool) {
        self.requireTLS = requireTLS
    }

    /// Sets a preferred resource for binding (optional, server may ignore it).
    public mutating func withPreferredResource(_ resource: String?) {
        preferredResource = resource
    }

    /// Sets a custom transport (e.g. for testing with ``MockTransport``).
    public mutating func withTransport(_ transport: any XMPPTransport) {
        self.transport = transport
    }

    /// Adds a stanza interceptor to be registered on the client.
    public mutating func withInterceptor(_ interceptor: any StanzaInterceptor) {
        interceptors.append(interceptor)
    }

    /// Adds a module to be registered on the client.
    public mutating func withModule(_ module: any XMPPModule) {
        modules.append(module)
    }

    /// Creates and configures the client. Must be `async` because ``XMPPClient/register(_:)`` is actor-isolated.
    public func build() async -> XMPPClient {
        let client = XMPPClient(
            domain: domain,
            credentials: credentials,
            transport: transport,
            requireTLS: requireTLS,
            preferredResource: preferredResource
        )

        for interceptor in interceptors {
            await client.addInterceptor(interceptor)
        }

        for module in modules {
            await client.register(module)
        }

        return client
    }
}
