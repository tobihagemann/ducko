import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let filterAccountJID = BareJID(localPart: "user", domainPart: "example.com")!

enum LinkPreviewFilterTests {
    struct FetchGate {
        @Test
        func `does not fetch when allowLinkPreviewFetches is false`() async throws {
            let fetcher = CountingLinkPreviewFetcher()
            let service = LinkPreviewService(fetcher: fetcher, store: MockPersistenceStore())
            let filter = LinkPreviewFilter(previewService: service)
            let url = try #require(URL(string: "https://example.com"))
            let context = FilterContext(accountJID: filterAccountJID, allowLinkPreviewFetches: false)
            let content = MessageContent(body: "see https://example.com", detectedURLs: [url])

            _ = await filter.filter(content, direction: .incoming, context: context)
            // The guard returns before spawning any fetch task, so there is nothing to await; yield a few times
            // to be sure no background fetch sneaks in.
            for _ in 0 ..< 5 {
                await Task.yield()
            }
            #expect(await fetcher.invocationCount == 0)
        }

        @Test
        func `fetches when allowLinkPreviewFetches is true`() async throws {
            let fetcher = CountingLinkPreviewFetcher()
            let service = LinkPreviewService(fetcher: fetcher, store: MockPersistenceStore())
            let filter = LinkPreviewFilter(previewService: service)
            let url = try #require(URL(string: "https://example.com"))
            let context = FilterContext(accountJID: filterAccountJID)
            let content = MessageContent(body: "see https://example.com", detectedURLs: [url])

            _ = await filter.filter(content, direction: .incoming, context: context)
            // The fire-and-forget Task.detached eventually invokes the fetcher; this is the control proving the
            // suppression test above is meaningful. Bounded wait so a broken filter fails by assertion, not a hang.
            let fired = await pollUntil({ await fetcher.invocationCount >= 1 }, timeout: .seconds(5))
            #expect(fired)
            #expect(await fetcher.invocationCount == 1)
        }
    }
}
