import DuckoCore
import SwiftUI
import Testing
@testable import DuckoUI

// MARK: - ThemeColor Tests

struct ThemeColorTests {
    @Test func `hex color parsing with hash`() {
        let color = Color(hex: "#FF0000")
        #expect(color != Color.clear)
    }

    @Test func `hex color parsing without hash`() {
        let color = Color(hex: "00FF00")
        #expect(color != Color.clear)
    }

    @Test func `light dark resolution`() {
        let themeColor = ThemeColor(light: "#FF0000", dark: "#0000FF")
        let lightResolved = themeColor.resolved(for: .light)
        let darkResolved = themeColor.resolved(for: .dark)
        #expect(lightResolved != darkResolved)
    }
}

// MARK: - ThemeFont Tests

struct ThemeFontTests {
    @Test func `system font resolution`() {
        let font = ThemeFont(size: 14, weight: "regular")
        let resolved = font.resolved
        #expect(resolved == Font.system(size: 14, weight: .regular))
    }

    @Test func `custom font resolution`() {
        let font = ThemeFont(family: "Menlo", size: 13, weight: "bold")
        let resolved = font.resolved
        #expect(resolved == Font.custom("Menlo", size: 13).weight(.bold))
    }

    @Test(arguments: [
        ("ultraLight", Font.Weight.ultraLight),
        ("thin", Font.Weight.thin),
        ("light", Font.Weight.light),
        ("regular", Font.Weight.regular),
        ("medium", Font.Weight.medium),
        ("semibold", Font.Weight.semibold),
        ("bold", Font.Weight.bold),
        ("heavy", Font.Weight.heavy),
        ("black", Font.Weight.black)
    ])
    func `known weights`(weight: String, expected: Font.Weight) {
        let font = ThemeFont(size: 14, weight: weight)
        let resolved = font.resolved
        #expect(resolved == Font.system(size: 14, weight: expected))
    }

    @Test func `unknown weight falls back to regular`() {
        let font = ThemeFont(size: 14, weight: "extraBold")
        let resolved = font.resolved
        #expect(resolved == Font.system(size: 14, weight: .regular))
    }
}

// MARK: - DuckoTheme Tests

struct DuckoThemeTests {
    private static let sampleTheme = DuckoTheme(
        id: "test",
        name: "Test Theme",
        author: "Tester",
        outgoingBubbleColor: ThemeColor(light: "#5B9BD5", dark: "#4A8BC2"),
        incomingBubbleColor: ThemeColor(light: "#E5E5EA", dark: "#38383A"),
        outgoingTextColor: ThemeColor(light: "#FFFFFF", dark: "#FFFFFF"),
        incomingTextColor: ThemeColor(light: "#000000", dark: "#FFFFFF"),
        bubbleCornerRadius: 12,
        bubblePadding: 12,
        messageFont: ThemeFont(size: 14, weight: "regular"),
        timestampFont: ThemeFont(size: 10, weight: "regular"),
        showAvatars: true,
        avatarSize: 32,
        avatarShape: .circle,
        avatarPosition: .leading,
        showStatusMessages: true,
        showPresenceIndicators: true,
        timestampStyle: .inline,
        timestampFormat: nil,
        accentColor: ThemeColor(light: "#5B9BD5", dark: "#4A8BC2"),
        backgroundColor: ThemeColor(light: "#FFFFFF", dark: "#1E1E1E"),
        separatorColor: ThemeColor(light: "#E0E0E0", dark: "#3A3A3A"),
        unreadBadgeColor: ThemeColor(light: "#FF3B30", dark: "#FF453A"),
        showLinkPreviews: true,
        linkPreviewStyle: .full
    )

    @Test func `json round trip`() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(DuckoThemeTests.sampleTheme)
        let decoded = try JSONDecoder().decode(DuckoTheme.self, from: data)
        #expect(decoded == DuckoThemeTests.sampleTheme)
    }

    @Test func `metadata fields`() {
        #expect(DuckoThemeTests.sampleTheme.id == "test")
        #expect(DuckoThemeTests.sampleTheme.name == "Test Theme")
        #expect(DuckoThemeTests.sampleTheme.author == "Tester")
    }

    @Test(arguments: [
        ("circle", DuckoTheme.AvatarShape.circle),
        ("roundedRect", DuckoTheme.AvatarShape.roundedRect),
        ("squircle", DuckoTheme.AvatarShape.squircle)
    ])
    func `avatar shape decoding`(raw: String, expected: DuckoTheme.AvatarShape) throws {
        let json = "\"\(raw)\""
        let decoded = try JSONDecoder().decode(DuckoTheme.AvatarShape.self, from: Data(json.utf8))
        #expect(decoded == expected)
    }

    @Test(arguments: [
        ("leading", DuckoTheme.AvatarPosition.leading),
        ("hidden", DuckoTheme.AvatarPosition.hidden)
    ])
    func `avatar position decoding`(raw: String, expected: DuckoTheme.AvatarPosition) throws {
        let json = "\"\(raw)\""
        let decoded = try JSONDecoder().decode(DuckoTheme.AvatarPosition.self, from: Data(json.utf8))
        #expect(decoded == expected)
    }

    @Test(arguments: [
        ("inline", DuckoTheme.TimestampStyle.inline),
        ("grouped", DuckoTheme.TimestampStyle.grouped)
    ])
    func `timestamp style decoding`(raw: String, expected: DuckoTheme.TimestampStyle) throws {
        let json = "\"\(raw)\""
        let decoded = try JSONDecoder().decode(DuckoTheme.TimestampStyle.self, from: Data(json.utf8))
        #expect(decoded == expected)
    }

    @Test(arguments: [
        ("full", DuckoTheme.LinkPreviewStyle.full),
        ("compact", DuckoTheme.LinkPreviewStyle.compact)
    ])
    func `link preview style decoding`(raw: String, expected: DuckoTheme.LinkPreviewStyle) throws {
        let json = "\"\(raw)\""
        let decoded = try JSONDecoder().decode(DuckoTheme.LinkPreviewStyle.self, from: Data(json.utf8))
        #expect(decoded == expected)
    }
}

// MARK: - ThemeEngine Tests

@MainActor
struct ThemeEngineTests {
    @Test func `init loads built in themes`() {
        let engine = ThemeEngine()
        let count = engine.availableThemes.count
        #expect(count >= 4)
    }

    @Test func `select theme persists and updates current`() {
        let engine = ThemeEngine()
        defer { engine.selectTheme(engine.availableThemes[0]) }
        guard engine.availableThemes.count >= 2 else { return }

        let second = engine.availableThemes[1]
        engine.selectTheme(second)
        #expect(engine.current.id == second.id)

        let engine2 = ThemeEngine()
        #expect(engine2.current.id == second.id)
    }

    @Test func `unknown saved ID falls back to first`() {
        let engine = ThemeEngine()
        defer { engine.selectTheme(engine.availableThemes[0]) }
        let defaults: UserDefaults = {
            if let suite = DuckoCore.BuildEnvironment.userDefaultsSuiteName {
                return UserDefaults(suiteName: suite) ?? .standard
            }
            return .standard
        }()
        defaults.set("nonexistent-theme-id", forKey: "selectedThemeID")

        let engine2 = ThemeEngine()
        #expect(engine2.current.id == "default")
    }
}
