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
        maxNameWidth: Double,
        avatarSize: Double,
        rowChrome: Double,
        floorWidth: Double,
        maxWidth: Double
    ) -> Double {
        let floor = min(floorWidth, maxWidth)
        guard maxNameWidth > 0 else { return floor }
        let needed = maxNameWidth.rounded(.up) + avatarSize + rowChrome
        return min(max(needed, floor), maxWidth)
    }

    /// Height that fits the off-screen-measured row total, clamped at `maxHeight`.
    /// Returns the `fallbackHeight` (the flat estimate) clamped at `maxHeight`
    /// when nothing valid has been measured yet (`measuredHeight <= 0` or
    /// non-finite). Rounds up to avoid sub-point churn driving needless resizes.
    public static func fittedHeight(measuredHeight: Double, fallbackHeight: Double, maxHeight: Double) -> Double {
        guard measuredHeight.isFinite, measuredHeight > 0 else { return min(fallbackHeight, maxHeight) }
        return min(measuredHeight.rounded(.up), maxHeight)
    }

    /// Total height of all currently-visible rows: each group header, the
    /// contacts of expanded groups, and the rooms section when present and
    /// expanded.
    public static func listContentHeight(
        groups: [(contactCount: Int, isExpanded: Bool)],
        roomCount: Int,
        roomsExpanded: Bool,
        groupRowHeight: Double,
        rowHeight: Double
    ) -> Double {
        var height = 0.0
        for group in groups {
            height += groupRowHeight
            if group.isExpanded {
                height += Double(group.contactCount) * rowHeight
            }
        }
        if roomCount > 0 {
            height += groupRowHeight
            if roomsExpanded {
                height += Double(roomCount) * rowHeight
            }
        }
        return height
    }

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
