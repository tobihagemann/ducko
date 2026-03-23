import Foundation
import Testing
@testable import DuckoUI

struct TranscriptDateFilterTests {
    @Test func labels() {
        #expect(TranscriptDateFilter.anyTime.label == "Any Time")
        #expect(TranscriptDateFilter.today.label == "Today")
        #expect(TranscriptDateFilter.thisWeek.label == "This Week")
        #expect(TranscriptDateFilter.thisMonth.label == "This Month")
        #expect(TranscriptDateFilter.before(Date()).label == "Before...")
        #expect(TranscriptDateFilter.after(Date()).label == "After...")
        #expect(TranscriptDateFilter.range(from: Date(), to: Date()).label == "Custom Range")
    }

    @Test func `anyTime returns no bounds`() {
        let interval = TranscriptDateFilter.anyTime.dateInterval
        #expect(interval.after == nil)
        #expect(interval.before == nil)
    }

    @Test func `today returns start of today`() {
        let interval = TranscriptDateFilter.today.dateInterval
        let expectedStart = Calendar.current.startOfDay(for: Date())
        #expect(interval.after == expectedStart)
        #expect(interval.before == nil)
    }

    @Test func `thisWeek returns start of week`() {
        let interval = TranscriptDateFilter.thisWeek.dateInterval
        let expectedStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start
        #expect(interval.after == expectedStart)
        #expect(interval.before == nil)
    }

    @Test func `thisMonth returns start of month`() {
        let interval = TranscriptDateFilter.thisMonth.dateInterval
        let expectedStart = Calendar.current.dateInterval(of: .month, for: Date())?.start
        #expect(interval.after == expectedStart)
        #expect(interval.before == nil)
    }

    @Test func `before returns upper bound only`() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let interval = TranscriptDateFilter.before(date).dateInterval
        #expect(interval.after == nil)
        #expect(interval.before == date)
    }

    @Test func `after returns lower bound only`() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let interval = TranscriptDateFilter.after(date).dateInterval
        #expect(interval.after == date)
        #expect(interval.before == nil)
    }

    @Test func `range returns both bounds`() {
        let from = Date(timeIntervalSince1970: 1_000_000)
        let to = Date(timeIntervalSince1970: 2_000_000)
        let interval = TranscriptDateFilter.range(from: from, to: to).dateInterval
        #expect(interval.after == from)
        #expect(interval.before == to)
    }

    @Test func equatable() {
        #expect(TranscriptDateFilter.anyTime == .anyTime)
        #expect(TranscriptDateFilter.today == .today)
        #expect(TranscriptDateFilter.thisWeek != .thisMonth)

        let date = Date(timeIntervalSince1970: 1_000_000)
        #expect(TranscriptDateFilter.before(date) == .before(date))
        #expect(TranscriptDateFilter.before(date) != .after(date))
    }
}
