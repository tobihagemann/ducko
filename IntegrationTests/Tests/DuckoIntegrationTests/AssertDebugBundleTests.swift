import Foundation
import Testing

/// Pins the dict-validation contract of `assertDebugBundle` (release-bundle
/// bypass + dict-shape misclassification) and the literal path components of
/// `appBundleURL` / `executableURL` so a rename in `AppAccessor.swift` forces
/// a synchronized test update. Top-level `enum` to opt out of the parent
/// suite's `.enabled(if: TestCredentials.isAvailable)` trait.
enum AssertDebugBundleTests {
    struct DebugBundleGate {
        private let bundlePath = "/Users/example/Ducko.app"

        @Test func `valid debug info dict passes`() throws {
            try AppAccessor.assertDebugBundle(
                info: ["DuckoBuildConfiguration": "debug"],
                bundlePath: bundlePath
            )
        }

        @Test func `nil info dict throws appBundleNotDebug`() {
            #expect(throws: TestHarnessError.appBundleNotDebug(path: bundlePath)) {
                try AppAccessor.assertDebugBundle(info: nil, bundlePath: bundlePath)
            }
        }

        @Test func `missing DuckoBuildConfiguration key throws appBundleNotDebug`() {
            #expect(throws: TestHarnessError.appBundleNotDebug(path: bundlePath)) {
                try AppAccessor.assertDebugBundle(info: [:], bundlePath: bundlePath)
            }
        }

        @Test func `release configuration value throws appBundleNotDebug`() {
            #expect(throws: TestHarnessError.appBundleNotDebug(path: bundlePath)) {
                try AppAccessor.assertDebugBundle(
                    info: ["DuckoBuildConfiguration": "release"],
                    bundlePath: bundlePath
                )
            }
        }

        @Test func `malformed configuration type throws appBundleNotDebug`() {
            #expect(throws: TestHarnessError.appBundleNotDebug(path: bundlePath)) {
                try AppAccessor.assertDebugBundle(
                    info: ["DuckoBuildConfiguration": 0],
                    bundlePath: bundlePath
                )
            }
        }
    }

    struct BundleURLInvariants {
        @Test func `appBundleURL last component is Ducko_app`() {
            #expect(AppAccessor.appBundleURL.lastPathComponent == "Ducko.app")
        }

        @Test func `executableURL path contains Contents MacOS layout`() {
            #expect(AppAccessor.executableURL.path.contains("/Contents/MacOS/"))
        }

        @Test func `executableURL last component is DuckoApp`() {
            #expect(AppAccessor.executableURL.lastPathComponent == "DuckoApp")
        }
    }
}
