import DuckoCore
@testable import DuckoXMPP

struct MockXMPPClientFactory: XMPPClientFactory {
    let transport: any XMPPTransport
    let modules: [any XMPPModule]

    init(transport: any XMPPTransport, modules: [any XMPPModule] = []) {
        self.transport = transport
        self.modules = modules
    }

    func makeClient(
        account: Account,
        password: String,
        previousSMState: SMResumeState?,
        requireTLSOverride: Bool?,
        omemoService: OMEMOService?
    ) async -> (XMPPClient, StreamManagementModule) {
        var builder = XMPPClientBuilder(
            domain: account.jid.domainPart,
            username: account.jid.localPart ?? "",
            password: password
        )
        builder.withTransport(transport)
        builder.withRequireTLS(false)
        let sm = StreamManagementModule(previousState: previousSMState)
        builder.withModule(sm)
        builder.withInterceptor(sm)
        for module in modules {
            builder.withModule(module)
        }
        return await (builder.build(), sm)
    }
}
