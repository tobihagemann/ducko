---
name: swiftui-performance-audit
description: Audit and improve SwiftUI runtime performance from code review and architecture. Use for requests to diagnose slow rendering, janky scrolling, high CPU/memory usage, excessive view updates, or layout thrash in SwiftUI apps, and to provide guidance for user-run Instruments profiling when code review alone is insufficient.
---

# SwiftUI Performance Audit

## Overview

Audit SwiftUI view performance end-to-end, from instrumentation and baselining to root-cause analysis and concrete remediation steps.

## Workflow Decision Tree

- If the user provides code, start with "Code-First Review."
- If the user only describes symptoms, ask for minimal code/context, then do "Code-First Review."
- If code review is inconclusive, go to "Guide the User to Profile" and ask for a trace or screenshots.

## 1. Code-First Review

Collect:
- Target view/feature code.
- Data flow: state, environment, observable models.
- Symptoms and reproduction steps.

Ask the user to classify the symptom if possible — this steers the review and any later profiling request:
- CPU spike or battery drain
- Janky scrolling or dropped frames
- High memory or image pressure
- Hangs or unresponsive interactions
- Excessive or unexpectedly broad view updates

Focus on:
- View invalidation storms from broad state changes.
- Unstable identity in lists (`id` churn, `UUID()` per render).
- Top-level conditional view swapping (`if/else` returning different root branches).
- Heavy work in `body` (formatting, sorting, image decoding).
- Layout thrash (deep stacks, `GeometryReader`, preference chains).
- Large images without downsampling or resizing.
- Over-animated hierarchies (implicit animations on large trees).

Use `references/code-smells.md` for the detailed smell catalog, Observation-specific fan-out guidance (iOS 17+ `@Observable` vs iOS 16- `ObservableObject`), the triage order, and remediation patterns.

Provide:
- Likely root causes with code references.
- Suggested fixes and refactors.
- If needed, a minimal repro or instrumentation suggestion.

## 2. Guide the User to Profile

Explain how to collect data with Instruments:
- Use the SwiftUI template in Instruments (Release build).
- Reproduce the exact interaction (scroll, navigation, animation).
- Capture SwiftUI timeline and Time Profiler.
- Export or screenshot the relevant lanes and the call tree.

Ask for:
- Trace export or screenshots of SwiftUI lanes + Time Profiler call tree.
- Device/OS/build configuration.

Use `references/profiling-intake.md` for the full intake checklist, default profiling request, artifacts to collect, and common traps (Debug-build timing distortion, Simulator blind spots).

### Automated trace capture and analysis

Instead of (or alongside) asking the user for screenshots, drive Instruments directly with the bundled scripts:

- `scripts/record_trace.py` wraps `xctrace record` — SwiftUI template by default, manual stop via Ctrl+C / stop-file / `--time-limit`, JSON device+template discovery, agent-orchestratable exit codes. See `references/trace-recording.md` for the attach/launch/background/time-boxed flows and the **SwiftUI-template-needs-a-real-device-or-the-host-Mac** rule (Simulator → fall back to `Time Profiler`).
- `scripts/analyze_trace.py` parses a `.trace` bundle into a structured report (SwiftUI updates, Time Profiler, hangs, animation hitches) and correlates lanes. See `references/trace-analysis.md` for `--list-logs` / `--list-signposts` / `--window` scoping and `--json-only` output.

For a macOS app like the ones this project targets, the host Mac supports the SwiftUI template, so both scripts work against a locally-run Release build. The scripts are stdlib-only Python 3 (no pip dependencies) and shell out to `xctrace`.

## 3. Analyze and Diagnose

Prioritize likely SwiftUI culprits:
- View invalidation storms from broad state changes.
- Unstable identity in lists (`id` churn, `UUID()` per render).
- Top-level conditional view swapping (`if/else` returning different root branches).
- Heavy work in `body` (formatting, sorting, image decoding).
- Layout thrash (deep stacks, `GeometryReader`, preference chains).
- Large images without downsampling or resizing.
- Over-animated hierarchies (implicit animations on large trees).

Summarize findings with evidence from traces/logs. Distinguish code-level suspicion from trace-backed evidence, and call out when profiling is still insufficient and what additional evidence would reduce uncertainty.

## 4. Remediate

Apply targeted fixes:
- Narrow state scope (`@State`/`@Observable` closer to leaf views).
- Stabilize identities for `ForEach` and lists.
- Move heavy work out of `body` into derived state updated from inputs, model-layer precomputation, memoized helpers, or background preprocessing. Use `@State` only for view-owned state, not as an ad hoc cache for arbitrary computation.
- Use `equatable()` only when equality is cheaper than recomputing the subtree and the inputs are truly value-semantic — not as a blanket fix.
- Downsample images before rendering.
- Reduce layout complexity or use fixed sizing where possible.

## Common Code Smells (and Fixes)

See `references/code-smells.md` for the full catalog — expensive formatters and heavy computed work in `body`, sorting/filtering during render, unstable identity, top-level conditional view swapping, main-thread image decode, and Observation fan-out (split by iOS 17+ `@Observable` vs iOS 16- `ObservableObject`) — plus the `@State`-is-not-a-cache and conditional-`equatable()` remediation notes and the impact-ordered triage list.

## 5. Verify

Ask the user to re-run the same capture and compare with baseline metrics.
Summarize the delta (CPU, frame drops, memory peak) if provided.

## Outputs

Provide:
- A short metrics table (before/after if available).
- Top issues (ordered by impact).
- Proposed fixes with estimated effort.

Use `references/report-template.md` when formatting the final audit.

## References

- Common code smells and remediation patterns: `references/code-smells.md`
- Profiling intake and collection checklist: `references/profiling-intake.md`
- Audit output template: `references/report-template.md`
- Recording a trace with `scripts/record_trace.py`: `references/trace-recording.md`
- Analyzing a `.trace` bundle with `scripts/analyze_trace.py`: `references/trace-analysis.md`

Add Apple documentation and WWDC resources under `references/` as they are supplied by the user.
- Optimizing SwiftUI performance with Instruments: `references/optimizing-swiftui-performance-instruments.md`
- Understanding and improving SwiftUI performance: `references/understanding-improving-swiftui-performance.md`
- Understanding hangs in your app: `references/understanding-hangs-in-your-app.md`
- Demystify SwiftUI performance (WWDC23): `references/demystify-swiftui-performance-wwdc23.md`
