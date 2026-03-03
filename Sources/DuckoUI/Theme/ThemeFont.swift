import SwiftUI

public struct ThemeFont: Codable, Sendable, Equatable {
    public let family: String?
    public let size: CGFloat
    public let weight: String

    public init(family: String? = nil, size: CGFloat, weight: String = "regular") {
        self.family = family
        self.size = size
        self.weight = weight
    }

    public var resolved: Font {
        if let family {
            return .custom(family, size: size).weight(fontWeight)
        }
        return .system(size: size, weight: fontWeight)
    }

    /// Switches on a String from external JSON, so default is appropriate.
    private var fontWeight: Font.Weight {
        switch weight {
        case "ultraLight": .ultraLight
        case "thin": .thin
        case "light": .light
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        case "heavy": .heavy
        case "black": .black
        default: .regular
        }
    }
}
