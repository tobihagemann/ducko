import DuckoCore
@testable import DuckoXMPP

struct MockXMPPClientFactory: XMPPClientFactory {
    let transport: any XMPPTransport

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
        return await (builder.build(), sm)
    }
}
