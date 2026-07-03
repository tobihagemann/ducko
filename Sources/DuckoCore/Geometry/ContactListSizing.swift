import Foundation

/// Pure layout arithmetic for the auto-sizing contact-list window, extracted
/// from the SwiftUI views so the clamp, floor, and sum logic is unit-testable.
/// All dimensions are in points.
public enum ContactListSizing {
    /// Clamp a persisted Maximum-Width preference into the slider's valid range,
    /// substituting the default for a non-finite stored value, so a stray
    /// persisted number can't collapse or invalidate the window frame.
    public static func clampMaxWidth(_ stored: Double) -> Double {
        let safe = stored.isFinite ? stored : ContactListSizingDefaults.defaultMaxWidth
        return min(max(safe, ContactListSizingDefaults.sliderMinWidth), ContactListSizingDefaults.sliderMaxWidth)
    }

    /// Width that fits the widest measured name, clamped between a floor (itself
    /// never above `maxWidth`) and the user's clamped Maximum Width. Returns the
    /// floor when nothing has been measured yet (`maxNameWidth <= 0`).
    public static func fittedWidth(
        maxNameWidth: CGFloat,
        avatarSize: CGFloat,
        rowChrome: CGFloat,
        floorWidth: CGFloat,
        maxWidth: CGFloat
    ) -> CGFloat {
        let floor = min(floorWidth, maxWidth)
        guard maxNameWidth > 0 else { return floor }
        let needed = maxNameWidth.rounded(.up) + avatarSize + rowChrome
        return min(max(needed, floor), maxWidth)
    }

    /// Height that fits the off-screen-measured row total, clamped at `maxHeight`.
    /// Returns the `fallbackHeight` (the flat estimate) clamped at `maxHeight`
    /// when nothing valid has been measured yet (`measuredHeight <= 0` or
    /// non-finite). Rounds up to avoid sub-point churn driving needless resizes.
    public static func fittedHeight(measuredHeight: CGFloat, fallbackHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        guard measuredHeight.isFinite, measuredHeight > 0 else { return min(fallbackHeight, maxHeight) }
        return min(measuredHeight.rounded(.up), maxHeight)
    }

    // swiftlint:disable function_parameter_count
    /// Target *content* size after per-axis gating: an auto-size-on axis takes
    /// its computed target (width raised to the shared lower bound), a manual
    /// axis carries the window's current value so `setFrame` is a no-op there.
    /// The vertical target adds `titlebarInset` because the Contacts window uses
    /// a full-size content view — SwiftUI insets its content below the title
    /// bar's safe area, so the frame's content area must reserve that strip on
    /// top of `chrome + list`. `titlebarInset` is measured in AppKit and passed
    /// in to keep this pure. `currentContentSize` is nil when there's no window
    /// yet; a manual axis then falls back to the computed value.
    public static func targetContentSize(
        autoSizeHorizontal: Bool,
        autoSizeVertical: Bool,
        contentWidth: CGFloat,
        listHeight: CGFloat,
        chromeHeight: CGFloat,
        titlebarInset: CGFloat,
        floorWidth: CGFloat,
        maxWidth: CGFloat,
        currentContentSize: CGSize?
    ) -> CGSize {
        let minContentWidth = min(floorWidth, maxWidth)
        let width = autoSizeHorizontal ? max(contentWidth, minContentWidth) : (currentContentSize?.width ?? contentWidth)
        let autoHeight = chromeHeight + listHeight + titlebarInset
        let height = autoSizeVertical ? autoHeight : (currentContentSize?.height ?? autoHeight)
        return CGSize(width: width, height: height)
    }

    // swiftlint:enable function_parameter_count

    /// Online/total counts for a group header, taken from the unfiltered roster
    /// so the total stays stable regardless of the hide-offline or search
    /// filters applied for display. Falls back to `displayedContacts` when the
    /// group is absent from `unfilteredRoster`.
    public static func onlineCounts(
        groupID: String,
        unfilteredRoster: [ContactGroup],
        displayedContacts: [Contact],
        isOnline: (Contact) -> Bool
    ) -> (online: Int, total: Int) {
        let roster = unfilteredRoster.first { $0.id == groupID }?.contacts ?? displayedContacts
        return (roster.filter(isOnline).count, roster.count)
    }
}
