import Foundation

public struct DuckoTheme: Codable, Sendable, Identifiable, Equatable {
    // MARK: - Metadata

    public let id: String
    public let name: String
    public let author: String
    public let version: String

    // MARK: - Bubble Config

    public let outgoingBubbleColor: ThemeColor
    public let incomingBubbleColor: ThemeColor
    public let outgoingTextColor: ThemeColor
    public let incomingTextColor: ThemeColor
    public let bubbleCornerRadius: CGFloat
    public let bubblePadding: CGFloat

    // MARK: - Typography

    public let messageFont: ThemeFont
    public let timestampFont: ThemeFont

    // MARK: - Avatar Config

    public let showAvatars: Bool
    public let avatarSize: CGFloat
    public let avatarShape: AvatarShape
    public let avatarPosition: AvatarPosition

    // MARK: - Contact List Config

    public let showStatusMessages: Bool
    public let showPresenceIndicators: Bool

    // MARK: - Timestamp Config

    public let timestampStyle: TimestampStyle
    public let timestampFormat: String?

    // MARK: - Colors

    public let accentColor: ThemeColor
    public let backgroundColor: ThemeColor
    public let separatorColor: ThemeColor
    public let unreadBadgeColor: ThemeColor

    // MARK: - Link Preview Config

    public let showLinkPreviews: Bool
    public let linkPreviewStyle: LinkPreviewStyle

    // MARK: - Nested Enums

    public enum AvatarShape: String, Codable, Sendable {
        case circle
        case roundedRect
        case squircle
    }

    public enum AvatarPosition: String, Codable, Sendable {
        case leading
        case hidden
    }

    public enum TimestampStyle: String, Codable, Sendable {
        case inline
        case grouped
    }

    public enum LinkPreviewStyle: String, Codable, Sendable {
        case full
        case compact
    }
}
