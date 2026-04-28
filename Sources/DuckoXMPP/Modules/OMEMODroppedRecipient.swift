/// One recipient device whose key encryption was skipped during an OMEMO send
/// because its bundle was unfetchable (`item-not-found` / `bundleNotFound`).
/// XEP-0384 §5.4 mandates skipping rather than aborting the send, but the
/// caller still needs the dropped set for partial-recipient signaling.
public struct DroppedOMEMORecipient: Sendable, Equatable {
    public let jid: BareJID
    public let deviceID: UInt32

    public init(jid: BareJID, deviceID: UInt32) {
        self.jid = jid
        self.deviceID = deviceID
    }
}
