import Testing

struct AXTraversalTests {
    @Test
    func `preorder chooses the first match without visiting later children`() {
        let tree = [0: [1, 2], 1: [3, 4], 2: [5]]
        var visits: [Int] = []
        let result = AXTraversal.first(in: 0, children: { tree[$0] }, matching: { node in
            visits.append(node)
            return node == 4 || node == 2
        })
        #expect(result == 4)
        #expect(visits == [0, 1, 3, 4])
    }

    @Test
    func `postorder preserves child order duplicate identifiers and missing children`() {
        let tree = [0: [1, 2], 1: [3, 4], 2: [5]]
        let identifiers = [0: "root", 1: "duplicate", 2: "duplicate", 3: "leaf", 4: "duplicate", 5: "last"]
        var collected: [String] = []
        AXTraversal.postorder(in: 0, children: { tree[$0] }, visit: { node in
            if let identifier = identifiers[node] { collected.append(identifier) }
        })
        #expect(collected == ["leaf", "duplicate", "duplicate", "last", "duplicate", "root"])
        #expect(AXTraversal.first(in: 0, children: { tree[$0] }, matching: { $0 == 99 }) == nil)
    }

    @Test
    func `deep trees use iterative lookup and collection without a depth cap`() {
        let depth = 20000
        let children: (Int) -> [Int]? = { $0 < depth ? [$0 + 1] : nil }
        #expect(AXTraversal.first(in: 0, children: children, matching: { $0 == depth }) == depth)
        var values: [Int] = []
        AXTraversal.postorder(in: 0, children: children, visit: { values.append($0) })
        #expect(values == Array((0 ... depth).reversed()))
    }
}
