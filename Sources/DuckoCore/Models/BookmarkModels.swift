/// Bridge type for `Bookmark` (XEP-0402) so DuckoUI can use it without importing DuckoXMPP.
public struct RoomBookmark: Sendable, Identifiable {
    public var id: String {
        jidString
    }

    public let jidString: String
    public let name: String?
    public let autojoin: Bool
    public let nickname: String?
    public let password: String?

    public init(
        jidString: String,
        name: String? = nil,
        autojoin: Bool = false,
        nickname: String? = nil,
        password: String? = nil
    ) {
        self.jidString = jidString
        self.name = name
        self.autojoin = autojoin
        self.nickname = nickname
        self.password = password
    }
}
