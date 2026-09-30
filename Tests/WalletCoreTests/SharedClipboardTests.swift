import Foundation
import Testing
import TestSupport

@Suite("Native Share clipboard verification")
struct SharedClipboardTests {
    private final class Clock {
        var elapsed: TimeInterval = 0
        var pauses: [TimeInterval] = []
        func now() -> Date { Date(timeIntervalSinceReferenceDate: elapsed) }
        func pause(_ duration: TimeInterval) {
            pauses.append(duration)
            elapsed += duration
        }
    }

    enum ReadFailure: Error, Equatable, Sendable {
        case transport, badJSON
    }

    @Test func slowValidReadUsesRemainingBudget() throws {
        let clock = Clock()
        var budgets: [TimeInterval] = []
        let result = try SharedClipboard.wait(expected: "offer", timeout: 15, read: { remaining in
            budgets.append(remaining)
            guard remaining >= 3 else { throw ReadFailure.transport }
            clock.elapsed += 3
            return "offer"
        }, isShareDismissed: { true }, now: clock.now, pause: clock.pause)
        #expect(result)
        #expect(budgets == [15])
        #expect(clock.elapsed == 3)
        #expect(clock.pauses.isEmpty)
    }

    @Test(arguments: [15.0, 16.0])
    func validReadAtOrAfterDeadlineCannotPass(duration: TimeInterval) throws {
        let clock = Clock()
        var calls = 0
        let result = try SharedClipboard.wait(expected: "offer", timeout: 15, read: { _ in
            calls += 1
            clock.elapsed += duration
            return "offer"
        }, isShareDismissed: { true }, now: clock.now, pause: clock.pause)
        #expect(!result)
        #expect(calls == 1)
        #expect(clock.elapsed == duration)
    }

    @Test func mismatchedBytesCannotPass() throws {
        let clock = Clock()
        let result = try SharedClipboard.wait(expected: "offer", timeout: 15, read: { _ in
            clock.elapsed += 3
            return "offer "
        }, isShareDismissed: { true }, now: clock.now, pause: clock.pause)
        #expect(!result)
        #expect(clock.elapsed >= 15)
    }

    @Test func exactBytesRequireDismissedShare() throws {
        let clock = Clock()
        let result = try SharedClipboard.wait(expected: "offer", timeout: 15, read: { _ in
            clock.elapsed += 3
            return "offer"
        }, isShareDismissed: { false }, now: clock.now, pause: clock.pause)
        #expect(!result)
        #expect(clock.elapsed >= 15)
    }

    @Test(arguments: [ReadFailure.transport, .badJSON])
    func readFailureRemainsFatal(failure: ReadFailure) {
        let clock = Clock()
        var calls = 0
        do {
            _ = try SharedClipboard.wait(expected: "offer", timeout: 15, read: { _ in
                calls += 1
                throw failure
            }, isShareDismissed: { true }, now: clock.now, pause: clock.pause)
            Issue.record("Clipboard read failure was swallowed")
        } catch {
            #expect(error as? ReadFailure == failure)
        }
        #expect(calls == 1)
        #expect(clock.elapsed == 0)
        #expect(clock.pauses.isEmpty)
    }

    @Test func observationsUseDecreasingRemainingBudgets() throws {
        let clock = Clock()
        var budgets: [TimeInterval] = []
        let result = try SharedClipboard.wait(expected: "offer", timeout: 15, read: { remaining in
            budgets.append(remaining)
            clock.elapsed += 3
            return budgets.count == 1 ? "pending" : "offer"
        }, isShareDismissed: { true }, now: clock.now, pause: clock.pause)
        #expect(result)
        #expect(budgets.count == 2)
        #expect(budgets[0] == 15)
        #expect(abs(budgets[1] - 11.8) < 0.000001)
        #expect(clock.pauses == [0.2])
    }
}
