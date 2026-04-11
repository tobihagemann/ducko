# SwiftUI Liquid Glass Reference (iOS 26+)

## Overview

Liquid Glass is Apple's design language introduced in iOS 26. It combines the optical properties of glass with a sense of fluidity — blurring content behind it, reflecting color and light from surrounding content, reacting to touch and pointer interactions, and morphing between shapes during transitions.

Key features:

- Blurs content behind the material.
- Reflects color and light from surrounding content.
- Reacts to touch and pointer interactions.
- Can morph between shapes during transitions.
- Available for standard and custom components.


## Availability

All Liquid Glass APIs require iOS 26 or later. Always provide fallbacks:

```swift
if #available(iOS 26, *) {
    // Liquid Glass implementation
} else {
    // Fallback using materials
}
```


## Core APIs

### `glassEffect` modifier

The primary modifier for applying glass effects to views:

```swift
.glassEffect(_ style: GlassEffectStyle = .regular, in shape: some Shape = .rect)
```

### Basic usage

```swift
Text("Hello")
    .padding()
    .glassEffect()  // Default regular style, rect shape
```

### With shape

```swift
Text("Rounded Glass")
    .padding()
    .glassEffect(in: .rect(cornerRadius: 16))

Image(systemName: "star")
    .padding()
    .glassEffect(in: .circle)

Text("Capsule")
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .glassEffect(in: .capsule)
```

Common shape options:

- `.capsule`
- `.rect(cornerRadius: CGFloat)`
- `.circle`


## `GlassEffectStyle`

### Prominence levels

```swift
.glassEffect(.regular)     // Standard glass appearance
.glassEffect(.prominent)   // More visible, higher contrast
```

### Tinting

Add color tint to the glass:

```swift
.glassEffect(.regular.tint(.blue))
.glassEffect(.prominent.tint(.red.opacity(0.3)))
```

### Interactivity

Make glass respond to touch / pointer hover:

```swift
// Interactive glass — responds to user interaction
.glassEffect(.regular.interactive())

// Combined with tint
.glassEffect(.regular.tint(.blue).interactive())
```

**Important:** Only use `.interactive()` on elements that actually respond to user input (buttons, tappable views, focusable elements).


## `GlassEffectContainer`

Wraps multiple glass elements for proper visual grouping, rendering performance, and morphing effects:

```swift
GlassEffectContainer {
    HStack {
        Button("One") { }.glassEffect()
        Button("Two") { }.glassEffect()
    }
}
```

### With spacing

Control the visual spacing between glass elements — smaller spacing merges effects when views are closer; larger spacing merges at greater distances:

```swift
GlassEffectContainer(spacing: 24) {
    HStack(spacing: 24) {
        GlassChip(icon: "pencil")
        GlassChip(icon: "eraser")
        GlassChip(icon: "trash")
    }
}
```

**Note:** The container's `spacing` parameter should match the actual spacing in your layout for proper glass effect rendering.

### Uniting multiple glass effects with `glassEffectUnion`

To combine multiple views into a single Liquid Glass effect — useful when views are created dynamically or live outside an HStack/VStack:

```swift
@Namespace private var namespace

GlassEffectContainer(spacing: 20) {
    HStack(spacing: 20) {
        ForEach(symbolSet.indices, id: \.self) { item in
            Image(systemName: symbolSet[item])
                .frame(width: 80, height: 80)
                .font(.system(size: 36))
                .glassEffect()
                .glassEffectUnion(id: item < 2 ? "1" : "2", namespace: namespace)
        }
    }
}
```


## Glass button styles

Built-in button styles for glass appearance:

```swift
// Standard glass button
Button("Action") { }
    .buttonStyle(.glass)

// Prominent glass button (higher visibility)
Button("Primary Action") { }
    .buttonStyle(.glassProminent)
```

### Custom glass buttons

For more control, apply the glass effect manually:

```swift
Button(action: { }) {
    Label("Settings", systemImage: "gear")
        .padding()
}
.glassEffect(.regular.interactive(), in: .capsule)
```


## Morphing transitions

Create smooth transitions between glass elements using `glassEffectID` and `@Namespace`:

```swift
struct MorphingExample: View {
    @Namespace private var animation
    @State private var isExpanded = false

    var body: some View {
        GlassEffectContainer {
            if isExpanded {
                ExpandedCard()
                    .glassEffect()
                    .glassEffectID("card", in: animation)
            } else {
                CompactCard()
                    .glassEffect()
                    .glassEffectID("card", in: animation)
            }
        }
        .animation(.smooth, value: isExpanded)
    }
}
```

### Requirements for morphing

1. Both views must have the same `glassEffectID`.
2. Use the same `@Namespace`.
3. Wrap in `GlassEffectContainer`.
4. Apply animation to the container or parent.


## Modifier order

**Critical:** apply `glassEffect` after layout and visual modifiers:

```swift
// CORRECT order
Text("Label")
    .font(.headline)            // 1. Typography
    .foregroundStyle(.primary)  // 2. Color
    .padding()                  // 3. Layout
    .glassEffect()              // 4. Glass effect LAST

// WRONG — glass applied too early
Text("Label")
    .glassEffect()
    .padding()
    .font(.headline)
```


## Advanced techniques

### Background extension effect

Stretch content behind a sidebar or inspector:

```swift
NavigationSplitView {
    // Sidebar content
} detail: {
    // Detail content
        .background {
            // Background content that extends under the sidebar
        }
}
```

### Extending horizontal scrolling under sidebar

```swift
ScrollView(.horizontal) {
    // Scrollable content
}
.scrollExtensionMode(.underSidebar)
```


## Complete examples

### Toolbar with glass buttons

```swift
struct GlassToolbar: View {
    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 16) {
                HStack(spacing: 16) {
                    ToolbarButton(icon: "pencil", action: { })
                    ToolbarButton(icon: "eraser", action: { })
                    ToolbarButton(icon: "scissors", action: { })
                    Spacer()
                    ToolbarButton(icon: "square.and.arrow.up", action: { })
                }
                .padding(.horizontal)
            }
        } else {
            // Fallback toolbar
            HStack(spacing: 16) { /* ... */ }
        }
    }
}

struct ToolbarButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 44, height: 44)
        }
        .glassEffect(.regular.interactive(), in: .circle)
    }
}
```

### Card with glass effect

```swift
struct GlassCard: View {
    let title: String
    let subtitle: String

    var body: some View {
        if #available(iOS 26, *) {
            cardContent
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
        } else {
            cardContent
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

### Segmented control with morphing

```swift
struct GlassSegmentedControl: View {
    @Binding var selection: Int
    let options: [String]
    @Namespace private var animation

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(options.indices, id: \.self) { index in
                        Button(options[index]) {
                            withAnimation(.smooth) {
                                selection = index
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .glassEffect(
                            selection == index ? .prominent.interactive() : .regular.interactive(),
                            in: .capsule
                        )
                        .glassEffectID(selection == index ? "selected" : "option\(index)", in: animation)
                    }
                }
                .padding(4)
            }
        } else {
            Picker("Options", selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index]).tag(index)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}
```


## Fallback strategies

### Using materials

```swift
if #available(iOS 26, *) {
    content.glassEffect()
} else {
    content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
}
```

### Available materials for fallback

- `.ultraThinMaterial` — closest to glass appearance.
- `.thinMaterial` — slightly more opaque.
- `.regularMaterial` — standard blur.
- `.thickMaterial` — more opaque.
- `.ultraThickMaterial` — most opaque.

### Conditional modifier extension

```swift
extension View {
    @ViewBuilder
    func glassEffectWithFallback(
        _ style: GlassEffectStyle = .regular,
        in shape: some Shape = .rect,
        fallbackMaterial: Material = .ultraThinMaterial
    ) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(style, in: shape)
        } else {
            self.background(fallbackMaterial, in: shape)
        }
    }
}
```


## Best practices

### Do

- Use `GlassEffectContainer` for grouped glass elements.
- Apply glass after layout and visual modifiers.
- Use `.interactive()` only on tappable or focusable elements.
- Match container spacing with layout spacing.
- Provide material-based fallbacks for pre–iOS 26.
- Keep glass shapes consistent within a feature.
- Use animations when changing view hierarchies so morphing transitions run.

### Don't

- Apply glass to every element — use sparingly.
- Use `.interactive()` on static content.
- Mix different corner radii arbitrarily.
- Forget `#available` guards.
- Apply glass before padding/frame modifiers.
- Nest `GlassEffectContainer` unnecessarily.


## Checklist

- [ ] `#available(iOS 26, *)` with fallback.
- [ ] `GlassEffectContainer` wraps grouped elements.
- [ ] `.glassEffect()` applied after layout modifiers.
- [ ] `.interactive()` only on user-interactable elements.
- [ ] `glassEffectID` with `@Namespace` for morphing.
- [ ] Consistent shapes and spacing across the feature.
- [ ] Container spacing matches layout spacing.
- [ ] Appropriate prominence levels used.


## Apple documentation

- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)
- [Landmarks: Building an app with Liquid Glass](https://developer.apple.com/documentation/SwiftUI/Landmarks-Building-an-app-with-Liquid-Glass)
- [`View.glassEffect(_:in:isEnabled:)`](https://developer.apple.com/documentation/SwiftUI/View/glassEffect(_:in:isEnabled:))
- [`GlassEffectContainer`](https://developer.apple.com/documentation/SwiftUI/GlassEffectContainer)
- [`GlassEffectTransition`](https://developer.apple.com/documentation/SwiftUI/GlassEffectTransition)
- [`GlassButtonStyle`](https://developer.apple.com/documentation/SwiftUI/GlassButtonStyle)
