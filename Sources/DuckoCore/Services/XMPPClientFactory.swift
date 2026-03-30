import DuckoXMPP

public protocol XMPPClientFactory: Sendable {
    func makeClient(
        account: Account,
        password: String,
        previousSMState: SMResumeState?,
        requireTLSOverride: Bool?,
        omemoService: OMEMOService?
    ) async -> (XMPPClient, StreamManagementModule)
}
