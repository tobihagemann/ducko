# SwiftUI List Patterns Reference

## ForEach Identity and Stability

**Always provide stable identity for `ForEach`.** Never use `.indices` for dynamic content.

```swift
// Good - stable identity via Identifiable
extension User: Identifiable {
    var id: String { userId }
}

ForEach(users) { user in
    UserRow(user: user)
}

// Good - stable identity via keypath
ForEach(users, id: \.userId) { user in
    UserRow(user: user)
}

// Wrong - indices create static content
ForEach(users.indices, id: \.self) { index in
    UserRow(user: users[index])  // Can crash on removal!
}

// Wrong - unstable identity
ForEach(users, id: \.self) { user in
    UserRow(user: user)  // Only works if User is Hashable and stable
}
```

**Critical**: Ensure **constant number of views per element** in `ForEach`:

```swift
// Good - consistent view count
ForEach(items) { item in
    ItemRow(item: item)
}

// Bad - variable view count breaks identity
ForEach(items) { item in
    if item.isSpecial {
        SpecialRow(item: item)
        DetailRow(item: item)
    } else {
        RegularRow(item: item)
    }
}
```

**Avoid inline filtering:**

```swift
// Bad - unstable identity, changes on every update
ForEach(items.filter { $0.isEnabled }) { item in
    ItemRow(item: item)
}

// Good - prefilter and cache
@State private var enabledItems: [Item] = []

var body: some View {
    ForEach(enabledItems) { item in
        ItemRow(item: item)
    }
    .onChange(of: items) { _, newItems in
        enabledItems = newItems.filter { $0.isEnabled }
    }
}
```

**Avoid `AnyView` in list rows:**

```swift
// Bad - hides identity, increases cost
ForEach(items) { item in
    AnyView(item.isSpecial ? SpecialRow(item: item) : RegularRow(item: item))
}

// Good - Create a unified row view
ForEach(items) { item in
    ItemRow(item: item)
}

struct ItemRow: View {
    let item: Item

    var body: some View {
        if item.isSpecial {
            SpecialRow(item: item)
        } else {
            RegularRow(item: item)
        }
    }
}
```

**Why**: Stable identity is critical for performance and animations. Unstable identity causes excessive diffing, broken animations, and potential crashes.

## Enumerated Sequences

**Always convert enumerated sequences to arrays. To be able to use them in a ForEach.**

```swift
let items = ["A", "B", "C"]

// Correct
ForEach(Array(items.enumerated()), id: \.offset) { index, item in
    Text("\(index): \(item)")
}

// Wrong - Doesn't compile, enumerated() isn't an array
ForEach(items.enumerated(), id: \.offset) { index, item in
    Text("\(index): \(item)")
}
```

## List with Custom Styling

```swift
// Remove default background and separators
List(items) { item in
    ItemRow(item: item)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowSeparator(.hidden)
}
.listStyle(.plain)
.scrollContentBackground(.hidden)
.background(Color.customBackground)
.environment(\.defaultMinListRowHeight, 1)  // Allows custom row heights
```

## List with Pull-to-Refresh

```swift
List(items) { item in
    ItemRow(item: item)
}
.refreshable {
    await loadItems()
}
```

## List Selection & Double-Click (macOS)

For single-click select + double-click open, use native selection plus `contextMenu`'s `primaryAction` — **never** a row tap gesture.

```swift
List(selection: $selection) {
    ForEach(items) { item in
        ItemRow(item: item)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())   // whole row hit-testable for selection
            .tag(item.id)
    }
}
.contextMenu(forSelectionType: Item.ID.self) { _ in
    // per-selection menu (may be empty; per-row .contextMenu still works)
} primaryAction: { ids in
    if let id = ids.first { open(id) }   // fires on double-click AND Return
}
```

- **Do not** attach `.onTapGesture(count:)` or `.simultaneousGesture(TapGesture())` to a row for double-click. The gesture owns the row's hit-tested content area (its `.contentShape`) and wins the gesture arena there, so `List` never sees single clicks in the content — **only the `listRowInsets` margins (no content/gesture) still select**. Symptom: "edges select, center doesn't; double-click works everywhere." `primaryAction` avoids this because it installs no row gesture.
- A plain `Button` row selects reliably but **can't deselect** (it only ever *sets* selection) — wrong for list semantics. Use `List(selection:)`, not buttons.
- Exclude headers/section rows from selection with `.selectionDisabled()`.
- Requires macOS 13+ (`forSelectionType`); `.selectionDisabled()` is macOS 14+.

## Sizing a Window to List Content (macOS)

`.windowResizability(.contentSize)` fits a window to its content — but a `List` is **greedy in both axes and reports no intrinsic content size**, so the window won't shrink to fit it. Drive the size explicitly:

- **Height**: give the `List` a `.frame(height:)` computed from visible row count × measured row heights, capped at screen height (so a long list scrolls instead of overflowing).
- **Width**: a `List` never reports the widest row, so measure it yourself (e.g. render the labels off-screen with `.fixedSize()` and a max-reducing `PreferenceKey`) and set the content's width.

Two measurement gotchas:

- `.plain` reserves its **own** per-row horizontal padding (~8pt leading, ~9pt trailing — trailing leaves room for the scroller) **on top of** your `listRowInsets`; compensate when aligning row content to a header outside the list.
- A `List` row renders its text **noticeably wider** (~14pt for a ~20-char label) than an identical off-screen `Text` with the same modifiers, so off-screen measurement under-reports row width — add an offset. `.accessibilityElement(children: .combine)` on a row also hides the inner label, so AX can't expose its width directly.

## Animating List Resize (macOS)

A `List` does **not** animate size + content changes cleanly. `.frame(height: computedHeight).animation(.smooth, value: computedHeight)` animates the container's height while the rows pop in/out (jumpy on insert/remove); keying the animation on the data triggers (search text, expansion state) instead of a derived height is better but still not smooth. Separately, a **window-level** frame `.animation(value: width/height)` animates every static sibling in that view tree too (e.g. a header's avatar slides as the window reflows) — scope animation to only the changing subtree. For an auto-sizing list (e.g. an Adium-style buddy list), snapping (no animation) is the safe default; a smooth resize needs coordinated row-transition + frame animation, or an AppKit-level window-frame animation.

## Summary Checklist

- [ ] ForEach uses stable identity (never `.indices` for dynamic content)
- [ ] Constant number of views per ForEach element
- [ ] No inline filtering in ForEach (prefilter and cache instead)
- [ ] No `AnyView` in list rows
- [ ] Don't convert enumerated sequences to arrays
- [ ] Use `.refreshable` for pull-to-refresh
- [ ] Custom list styling uses appropriate modifiers
