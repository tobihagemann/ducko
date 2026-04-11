---
name: swift-language
description: Write, review, or improve Swift APIs and value-display formatting. Covers Swift API Design Guidelines (naming, argument labels, documentation comments, terminology, general conventions) and modern FormatStyle APIs for numbers, dates, durations, measurements, and SwiftUI Text. Use when designing new APIs, refactoring existing interfaces, reviewing API clarity, or replacing legacy Formatter / String(format:) code.
license: MIT
---

# Swift Language Skill

## Overview
Use this skill for two adjacent Swift language concerns:

1. **API Design** — Design and review Swift APIs that are clear at the point of use, fluent in call sites, and aligned with established Swift naming and labeling conventions. Prioritize readability, explicit intent, and consistency across declarations, call sites, and documentation comments.
2. **FormatStyle** — Write and review Swift code that formats values for display using modern `FormatStyle` APIs instead of legacy `Formatter` subclasses or C-style `String(format:)`.

The two concerns are packaged together because both govern *how Swift code reads and presents*. API Design is the primary workflow; FormatStyle is a focused secondary section below, with its own references subfolder (`references/format-style/`).

## Work Decision Tree

### 1) Review existing code
- Inspect declarations and call sites together, not declarations alone.
- Check naming clarity and fluency (see [references/promote-clear-usage.md](references/promote-clear-usage.md), [references/strive-for-fluent-usage.md](references/strive-for-fluent-usage.md)).
- Check argument labels and parameter naming (see [references/parameters.md](references/parameters.md), [references/argument-labels.md](references/argument-labels.md)).
- Check documentation comments and symbol markup (see [references/fundamentals.md](references/fundamentals.md)).
- Check conventions and overload safety (see [references/general-conventions.md](references/general-conventions.md), [references/special-instructions.md](references/special-instructions.md)).

### 2) Improve existing code
- Rename APIs that are ambiguous, redundant, or role-unclear.
- Refactor labels to improve grammatical call-site reading.
- Replace weakly named parameters with role-based names.
- Resolve overload sets that become ambiguous with weak typing.
- Strengthen documentation summaries to describe behavior and returns precisely.

### 3) Implement new feature
- Start from use-site examples before finalizing declarations.
- Choose base names and labels so calls read as clear English phrases.
- Add defaults only when they simplify common usage.
- Define mutating/nonmutating pairs with consistent naming.
- Add concise documentation comments for every new declaration.

## Core Guidelines

### Fundamentals
- Clarity at the point of use is the top priority.
- Clarity is more important than brevity.
- Every declaration should have a documentation comment.
- Summaries should state what the declaration does, returns, accesses, creates, or is.
- Use recognized Swift symbol markup (`Parameter`, `Returns`, `Throws`, `Note`, etc.).

### Promote Clear Usage
- Include all words needed to avoid ambiguity.
- Omit needless words, especially type repetition.
- Name parameters and associated types by role, not type.
- Add role nouns when type information is weak (`Any`, `NSObject`, `String`, `Int`).

### Strive For Fluent Usage
- Prefer method names that produce grammatical, readable call sites.
- Start factory methods with `make`.
- Name side-effect-free APIs as noun phrases; side-effecting APIs as imperative verbs.
- Keep mutating/nonmutating naming pairs consistent (`sort`/`sorted`, `formUnion`/`union`).
- Boolean APIs should read as assertions (`isEmpty`, `intersects`).

### Use Terminology Well
- Prefer common words unless terms of art are necessary for precision.
- If using a term of art, preserve its established meaning.
- Avoid non-standard abbreviations.
- Embrace established domain precedent when it improves shared understanding.

### Conventions, Parameters, And Labels
- Document complexity for computed properties that are not `O(1)`.
- Prefer methods/properties to free functions except special cases.
- Follow Swift casing conventions, including acronym handling.
- Use parameter names that improve generated documentation readability.
- Prefer default arguments over method families when semantics are shared.
- Place defaulted parameters near the end.
- Apply argument labels based on grammar and meaning, not style preference.

### Special Instructions
- Label tuple members and name closure parameters in public API surfaces.
- Be explicit with unconstrained polymorphism to avoid overload ambiguity.
- Align names with semantics shown in documentation comments.

## Quick Reference

### Name Shape
| Situation | Preferred Pattern |
| --- | --- |
| Mutating verb | `reverse()` |
| Nonmutating verb | `reversed()` / `strippingNewlines()` |
| Nonmutating noun op | `union(_:)` |
| Mutating noun op | `formUnion(_:)` |
| Factory method | `makeWidget(...)` |
| Boolean query | `isEmpty`, `intersects(_:)` |

### Argument Label Rules
| Situation | Rule |
| --- | --- |
| Distinguishable unlabeled args | Omit labels only if distinction is still clear |
| Value-preserving conversion init | Omit first label |
| First arg in prepositional phrase | Usually label from the preposition |
| First arg in grammatical phrase | Omit first label |
| Defaulted arguments | Keep labels (they may be omitted at call sites) |
| All other arguments | Label them |

### Documentation Rules
| Declaration Kind | Summary Should Describe |
| --- | --- |
| Function / method | What it does and what it returns |
| Subscript | What it accesses |
| Initializer | What it creates |
| Other declarations | What it is |

## Review Checklist

### Clarity And Fluency
- [ ] Call sites are clear without reading implementation details.
- [ ] Base names include all words needed to remove ambiguity.
- [ ] Names are concise and avoid repeating type names.
- [ ] Calls read naturally and grammatically where it matters most.

### Naming Semantics
- [ ] Side-effect-free APIs read as nouns/queries.
- [ ] Side-effecting APIs read as imperative verbs.
- [ ] Mutating/nonmutating pairs use consistent naming patterns.
- [ ] Boolean APIs read as assertions.

### Parameters And Labels
- [ ] Parameter names improve docs and role clarity.
- [ ] Default parameters simplify common usage.
- [ ] Defaulted parameters are near the end.
- [ ] First argument labels follow grammar and conversion rules.
- [ ] Remaining arguments are labeled unless omission is clearly justified.

### Documentation And Conventions
- [ ] Every declaration has a useful summary comment.
- [ ] Symbol markup is used where appropriate.
- [ ] Non-`O(1)` computed property complexity is documented.
- [ ] Case conventions and acronym casing follow Swift norms.
- [ ] Overloads avoid return-type-only distinctions and weak-type ambiguities.

## FormatStyle

Modern Swift replaces legacy `Formatter` subclasses and C-style `String(format:)` with `FormatStyle` and `.formatted()`. When reviewing or writing code that displays numbers, dates, durations, measurements, lists, names, byte counts, or URLs:

### FormatStyle Review Process

1. Replace legacy formatting patterns with modern `FormatStyle` equivalents — see [references/format-style/anti-patterns.md](references/format-style/anti-patterns.md).
2. Validate number, percent, and currency formatting — see [references/format-style/numeric-styles.md](references/format-style/numeric-styles.md).
3. Validate date and time formatting — see [references/format-style/date-styles.md](references/format-style/date-styles.md).
4. Validate duration formatting — see [references/format-style/duration-styles.md](references/format-style/duration-styles.md).
5. Validate measurement, list, person name, byte count, and URL formatting — see [references/format-style/other-styles.md](references/format-style/other-styles.md).
6. Check SwiftUI `Text` views for proper `FormatStyle` integration — see [references/format-style/swiftui.md](references/format-style/swiftui.md).

### FormatStyle Core Rules

- Target iOS 15+ / macOS 12+ minimum for basic FormatStyle. Duration and URL styles require iOS 16+ / macOS 13+.
- **Never** use legacy `Formatter` subclasses (`DateFormatter`, `NumberFormatter`, `MeasurementFormatter`, `DateComponentsFormatter`, `DateIntervalFormatter`, `PersonNameComponentsFormatter`, `ByteCountFormatter`).
- **Never** use C-style `String(format:)` for number formatting. Always use `.formatted()` or `FormatStyle` directly.
- **Never** use `DispatchQueue` for formatting on background threads — `FormatStyle` types are value types and thread-safe.
- Prefer `.formatted()` instance method for simple cases, and explicit `FormatStyle` types for reusable or complex configurations.
- In SwiftUI, use `Text(_:format:)` instead of `Text("\(value.formatted())")`.
- Use `Decimal` instead of `Float`/`Double` for currency values.
- `FormatStyle` types are locale-aware by default. Only set locale explicitly when you need a specific locale different from the user's current locale.
- `FormatStyle` types conform to `Codable` and `Hashable`, making them safe to store and compare.

### FormatStyle Example

```swift
// Before — C-style format string
let minutes = Int(duration) / 60
let seconds = Int(duration) % 60
return String(format: "%02d:%02d", minutes, seconds)

// After — Duration FormatStyle
Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))
```

```swift
// Before — string interpolation in SwiftUI
Text("\(fileSize.formatted(.byteCount(style: .file)))")

// After — Text(_:format:)
Text(fileSize, format: .byteCount(style: .file))
```


## References

### API Design

- [references/fundamentals.md](references/fundamentals.md) — Core principles and documentation comment rules.
- [references/promote-clear-usage.md](references/promote-clear-usage.md) — Ambiguity reduction and role-based naming.
- [references/strive-for-fluent-usage.md](references/strive-for-fluent-usage.md) — Fluency, side effects, and mutating pairs.
- [references/use-terminology-well.md](references/use-terminology-well.md) — Terms of art, abbreviations, and precedent.
- [references/general-conventions.md](references/general-conventions.md) — Complexity docs, free function exceptions, casing, overloads.
- [references/parameters.md](references/parameters.md) — Parameter naming and default argument strategy.
- [references/argument-labels.md](references/argument-labels.md) — First-argument and general label rules.
- [references/special-instructions.md](references/special-instructions.md) — Tuple/closure naming and unconstrained polymorphism.

### FormatStyle

- [references/format-style/anti-patterns.md](references/format-style/anti-patterns.md) — legacy patterns to replace: `String(format:)`, `DateFormatter`, `NumberFormatter`, other `Formatter` subclasses.
- [references/format-style/numeric-styles.md](references/format-style/numeric-styles.md) — number, percent, and currency formatting with rounding, precision, sign, notation, scale, grouping.
- [references/format-style/date-styles.md](references/format-style/date-styles.md) — date/time compositing, ISO 8601, relative, verbatim, HTTP, interval, components styles.
- [references/format-style/duration-styles.md](references/format-style/duration-styles.md) — `Duration.TimeFormatStyle` and `Duration.UnitsFormatStyle` with patterns, units, width, fractional seconds.
- [references/format-style/other-styles.md](references/format-style/other-styles.md) — measurement, list, person name, byte count, URL formatting, custom `FormatStyle` creation.
- [references/format-style/swiftui.md](references/format-style/swiftui.md) — SwiftUI `Text` integration and best practices.


## Philosophy

- Prefer clear use-site semantics over declaration cleverness.
- Follow established Swift conventions before inventing local style rules.
- Optimize for maintainability and reviewability of public API surfaces.
- Keep guidance practical: apply the smallest change that improves clarity.
