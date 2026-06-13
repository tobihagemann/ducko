import Foundation

/// UserDefaults keys and bounds for the contact-list window's auto-sizing
/// preferences (Appearance settings). Shared by the preferences UI, the window,
/// and the app scene so all three stay in sync through `@AppStorage` on the same
/// keys and store — Adium's "Automatic Sizing" controls.
public enum ContactListSizingDefaults {
    public static let autoSizeVerticalKey = "contactListAutoSizeVertical"
    public static let autoSizeHorizontalKey = "contactListAutoSizeHorizontal"
    public static let maxWidthKey = "contactListMaxWidth"

    /// Default value for the user's Maximum Width preference.
    public static let defaultMaxWidth: Double = 280
    /// Bounds of the Maximum Width slider (not the preference itself).
    public static let sliderMinWidth: Double = 150
    public static let sliderMaxWidth: Double = 400
}
