# Fail-Closed Encryption Resolution: Sentinels and Optional Binding

When implementing a fail-closed encryption gate (e.g., "encryption is required → must throw, not silently fall back to plaintext"), two related design choices control whether the gate actually closes:

1. **The shape of the resolution enum** — explicit cases vs empty-value sentinels.
2. **The shape of the dispatch branching** — which optional you bind first.

Get either wrong and the gate fails open in a way that compiles cleanly, passes every existing test, and silently downgrades user-encrypted traffic to plaintext.

## Principle 1 — Prefer explicit cases over empty-value sentinels

Anti-pattern:

```swift
enum EncryptionResolution {
    case proceed(trustedDeviceIDs: [UInt32])
    case userDisabled
    case noLocalDevicesForPeer
    case noTrustedDevicesForPeer
}

// In the resolver:
guard let omemoService else { return .proceed(trustedDeviceIDs: []) } // "[]" is a sentinel meaning "throw later"
```

The doc comment promises: "callers throw `omemoServiceUnavailable` when ids are empty." That promise is enforced nowhere by the compiler. Every consumer that pattern-matches `.proceed(ids)` and treats `ids` as authoritative (e.g. `if ids.isEmpty { plaintext }` or `if let ids` for nil-coalescing) silently bypasses the gate.

Pattern:

```swift
enum EncryptionResolution {
    case proceed(trustedDeviceIDs: [UInt32])
    case userDisabled
    case noLocalDevicesForPeer
    case noTrustedDevicesForPeer
    case serviceUnavailable     // explicit
}

// In the resolver:
guard let omemoService else { return .serviceUnavailable }
```

The compiler's exhaustivity check (combined with the project rule that forbids `default:` on project-defined enums) now forces every dispatch site to handle `.serviceUnavailable` explicitly. Routing logic is in the type, not in a comment.

**Rule:** an enum-resolution outcome that means "you must throw" should be its own case, not an empty associated value of an existing case.

## Principle 2 — Branch on the signal-carrying optional first

Once the resolver returns a clean enum, each dispatch site must consume it without losing information. The trap is at dispatch sites that flatten the enum back into an optional (e.g. `[UInt32]?`) for downstream helpers.

Anti-pattern:

```swift
// In dispatchSend:
if let omemoService, let trustedDeviceIDs = context.trustedDeviceIDs {
    // encrypted path
} else {
    // plaintext path — silently runs when omemoService is nil
}
```

When `trustedDeviceIDs` is non-nil (= "encryption required") but `omemoService` is nil, `if let omemoService, let …` shortcircuits on `omemoService` and falls into the plaintext branch. The `trustedDeviceIDs != nil` signal is silently discarded.

Pattern:

```swift
// In dispatchSend:
guard let trustedDeviceIDs = context.trustedDeviceIDs else {
    // plaintext path — intentional, .userDisabled was set
    try await sendPlaintext()
    return
}
guard let omemoService else {
    // Unreachable in production: resolveEncryption returns .serviceUnavailable
    // when the service is nil. Defense in depth.
    throw EncryptionError.serviceUnavailable
}
// encrypted path
```

The signal-carrying optional (`trustedDeviceIDs`) is bound first. The cofactor (`omemoService`) is guarded only on the encrypt branch, with a typed throw if it's missing. Falling through to the plaintext path is impossible.

**Rule:** when one optional carries a security-relevant signal ("encryption required") and another carries a runtime dependency ("OMEMO service handle"), branch on the signal first, then guard the dependency on the encrypt arm. Never combine them into a single `if let A, let B` — the `else` branch becomes a silent downgrade.

## Detection

Both anti-patterns survive every internal review that lacks adversarial pairing. They were caught here only by running 7 reviewers (6 internal + 1 codex peer review) and noticing convergence: when ≥3 independent reviewers flag the same fail-closed bypass through different lenses (correctness, security, consistency), the bug is almost certainly real even if the lines compile and tests pass.

## Reference Files

- `keychain-fundamentals.md` — error-handling discipline for security APIs
- `common-anti-patterns.md` — adjacent anti-patterns (silent error swallowing, default values that bypass checks)
