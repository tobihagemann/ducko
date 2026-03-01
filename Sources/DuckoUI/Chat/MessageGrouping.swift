import DuckoCore
import Foundation

struct MessagePosition {
    let isFirstInGroup: Bool
    let isLastInGroup: Bool
}

func computeMessagePositions(
    _ messages: [ChatMessage],
    groupingInterval: TimeInterval = 120
) -> [UUID: MessagePosition] {
    guard !messages.isEmpty else { return [:] }

    var positions: [UUID: MessagePosition] = [:]

    for (index, message) in messages.enumerated() {
        let prevMessage = index > 0 ? messages[index - 1] : nil
        let nextMessage = index < messages.count - 1 ? messages[index + 1] : nil

        let isFirstInGroup = !isSameGroup(message, as: prevMessage, interval: groupingInterval)
        let isLastInGroup = !isSameGroup(message, as: nextMessage, interval: groupingInterval)

        positions[message.id] = MessagePosition(isFirstInGroup: isFirstInGroup, isLastInGroup: isLastInGroup)
    }

    return positions
}

private func isSameGroup(_ a: ChatMessage, as b: ChatMessage?, interval: TimeInterval) -> Bool {
    guard let b else { return false }
    guard a.isOutgoing == b.isOutgoing else { return false }
    guard a.fromJID == b.fromJID else { return false }
    return abs(a.timestamp.timeIntervalSince(b.timestamp)) <= interval
}
