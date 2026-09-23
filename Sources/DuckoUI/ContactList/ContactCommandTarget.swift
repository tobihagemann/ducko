import DuckoCore

/// What the Contact menu commands act on: the selected Contacts row or the active conversation.
public struct ContactCommandTarget {
    /// `nil` when the target has no Contact Info window.
    public let contactInfoRef: ContactInfoRef?
    public let transcriptRef: ConversationRef
    public let chatKey: ConversationKey
    /// The roster contact, set only for a Contacts contact row.
    let contact: Contact?
}
