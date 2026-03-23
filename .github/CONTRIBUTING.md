# Contributing to Ducko

## Did you find a bug?

- Ensure you're running the latest version of Ducko.
- Ensure the bug was not [already reported](https://github.com/tobihagemann/ducko/issues).
- If you're unable to find an open issue addressing the problem, [submit a new one](https://github.com/tobihagemann/ducko/issues/new).

## Did you write a patch that fixes a bug?

- Open a new pull request with the patch.
- Ensure the PR description clearly describes the problem and solution. Include the relevant issue number if applicable.

## Do you intend to add a new feature or change an existing one?

- Suggest your change by [submitting a new issue](https://github.com/tobihagemann/ducko/issues/new) and start writing code.

## Development Setup

See the [README](../README.md) for prerequisites, building, running, testing, and code style setup.

Key conventions for contributors:

- **Module boundaries are strict** — see the architecture diagram in the README. Each module has import rules enforced at build time.
- **Pure Swift** — no `@objc`, no NSObject subclasses (except where Apple protocols require it).
- **Value types preferred** — structs and enums over classes.
- **Swift Testing** — use `import Testing`, `@Test`, `#expect`, `#require` (not XCTest).
- **Strict concurrency** — all types must be `Sendable`. Use actors for mutable shared state.
- **Exhaustive switches** — never use `default:` on project-defined enums.

Run `./Scripts/format.sh`, `./Scripts/lint.sh`, and `swift test` before pushing.

## Use of Generative AI

AI tools may assist your work, but every contribution must be fully understood, reviewed, and tested by you. Only submit changes you can clearly explain and justify. Unverified or low-quality AI output will be closed without further review.

## Code of Conduct

Help us keep Ducko open and inclusive. Please read and follow our [Code of Conduct](CODE_OF_CONDUCT.md).

## Above all, thank you for your contributions

Thank you for taking the time to contribute to the project!
