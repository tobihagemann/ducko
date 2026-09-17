/// Synchronous tree walks keep platform handles in their caller's isolation domain.
enum AXTraversal {
    static func first<Node>(in root: Node, children: (Node) -> [Node]?, matching: (Node) -> Bool) -> Node? {
        var stack = [root]
        while let node = stack.popLast() {
            if matching(node) { return node }
            if let descendants = children(node) { stack.append(contentsOf: descendants.reversed()) }
        }
        return nil
    }

    static func postorder<Node>(in root: Node, children: (Node) -> [Node]?, visit: (Node) -> Void) {
        var stack = [(node: root, expanded: false)]
        while let entry = stack.popLast() {
            if entry.expanded {
                visit(entry.node)
            } else {
                stack.append((entry.node, true))
                if let descendants = children(entry.node) {
                    stack.append(contentsOf: descendants.reversed().map { ($0, false) })
                }
            }
        }
    }
}
