import ApplicationServices
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(1)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    switch result {
    case .success: return value
    case .attributeUnsupported, .noValue: return nil
    default: fail("Accessibility read failed for \(name): \(result.rawValue)")
    }
}

func find(in element: AXUIElement, depth: Int = 0, matching predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    guard depth < 64 else { return nil }
    if predicate(element) { return element }
    for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        if let match = find(in: child, depth: depth + 1, matching: predicate) { return match }
    }
    return nil
}

guard CommandLine.arguments.count == 4, let pid = Int32(CommandLine.arguments[1]), pid > 0 else {
    fail("Expected a process ID, container identifier, and button label")
}
guard AXIsProcessTrusted() else { fail("Accessibility permission is required") }
let application = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(application, 2)
let identifier = CommandLine.arguments[2]
let buttonLabel = CommandLine.arguments[3]
func container() -> AXUIElement? {
    for window in (attribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
        if let found = find(in: window, matching: { attribute($0, kAXIdentifierAttribute) as? String == identifier }) { return found }
    }
    return nil
}
guard let target = container() else { fail("Container \(identifier) not found in process \(pid)") }
guard let button = find(in: target, matching: {
    attribute($0, kAXRoleAttribute) as? String == kAXButtonRole
        && (attribute($0, kAXDescriptionAttribute) as? String == buttonLabel
            || attribute($0, kAXTitleAttribute) as? String == buttonLabel)
}) else { fail("Dismiss button not found") }
guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { fail("Dismiss action failed") }
let deadline = ContinuousClock.now + .seconds(2)
while container() != nil, ContinuousClock.now < deadline { usleep(20000) }
guard container() == nil else { fail("Container remained visible") }
print("Dismissed \(identifier)")
