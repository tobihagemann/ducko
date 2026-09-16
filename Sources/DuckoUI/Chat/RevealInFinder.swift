import AppKit
import Foundation

/// Shows saved files in Finder. `activateFileViewerSelecting` takes the whole set at once, so a message carrying more
/// than one saved file reveals all of them rather than an arbitrary first. What it does with an empty set is not
/// documented.
func revealInFinder(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
}
