import DuckoCore
import DuckoXMPP
import Foundation

protocol CLIFormatter: Sendable {
    func formatMessage(_ message: ChatMessage) -> String
    func formatAccount(_ account: Account) -> String
    func formatPresence(jid: BareJID, status: String, message: String?) -> String
    func formatContactWithPresence(_ contact: Contact, presence: PresenceService.PresenceStatus?) -> String
    func formatGroupHeader(_ group: ContactGroup) -> String
    func formatError(_ error: any Error) -> String
    func formatEvent(_ event: XMPPEvent, accountID: UUID) -> String?
    func formatTypingIndicator(from jid: BareJID, state: ChatState) -> String?
    func formatRoom(_ room: DiscoveredRoom) -> String
    func formatRoomParticipant(_ participant: RoomParticipant) -> String
    func formatRoomParticipantGroupHeader(_ group: RoomParticipantGroup) -> String
    func formatRoomJoinedConfirmation(room: String, nickname: String, participantCount: Int, subject: String?) -> String
    func formatTransferProgress(fileName: String, fileSize: Int64, progress: Double) -> String
    func formatFileMessage(fileName: String, url: String, fileSize: Int64?) -> String
    func formatBookmark(_ bookmark: RoomBookmark) -> String
    func formatProfile(_ profile: ProfileInfo) -> String
    func formatTLSInfo(_ info: TLSInfo) -> String
    func formatServerInfo(_ info: ServerInfo) -> String
    func formatSearchedChannel(_ channel: SearchedChannel) -> String
}

func jingleProgressState(bytesTransferred: Int64, totalBytes: Int64) -> (progress: Double, state: String) {
    let progress = Double(bytesTransferred) / Double(totalBytes)
    let state = progress < 1.0 ? "transferring" : "finishing"
    return (progress, state)
}

func formatByteCount(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func nicknameFromJID(_ jid: JID) -> String {
    FullJID.parse(jid.description)?.resourcePart ?? jid.bareJID.description
}

func iso8601(_ date: Date) -> String {
    date.formatted(
        Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    )
}
