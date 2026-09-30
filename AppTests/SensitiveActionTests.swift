@testable import WinnowApp
import Foundation
import LocalAuthentication
import XCTest

/// The lifecycle behind revealing the recovery phrase, importing a bundle and
/// exporting a backup: a result reaches the view only while its presentation
/// is current, and every way of leaving is quiet.
@MainActor
final class SensitiveActionTests: XCTestCase {
    private struct Failure: LocalizedError { var errorDescription: String? { "the keychain said no" } }

    func testAResultIsAppliedAndTheActionFinishes() async {
        let action = SensitiveAction()
        var applied: [String] = []
        action.start(presentable: { true }) { "words" } apply: { applied.append($0) }
        XCTAssertTrue(action.busy)
        await action.finish()
        XCTAssertEqual(applied, ["words"])
        XCTAssertFalse(action.busy)
        XCTAssertNil(action.error)
    }

    func testAFailureIsReportedButCancellingOrDecliningIsNot() async {
        let action = SensitiveAction()
        action.start(presentable: { true }) { throw Failure() } apply: { (_: String) in XCTFail("nothing to apply") }
        await action.finish()
        XCTAssertEqual(action.error, "the keychain said no")
        XCTAssertFalse(action.busy)

        for quiet: any Error in [CancellationError(), LAError(.userCancel)] {
            action.start(presentable: { true }) { throw quiet } apply: { (_: String) in XCTFail("nothing to apply") }
            await action.finish()
            XCTAssertNil(action.error, "\(quiet) is a decision, not a failure")
            XCTAssertFalse(action.busy)
        }
    }

    func testAnApplyThatThrowsIsAFailure() async {
        let action = SensitiveAction()
        action.start(presentable: { true }) { "text" } apply: { _ in throw Failure() }
        await action.finish()
        XCTAssertEqual(action.error, "the keychain said no")
    }

    /// A slower first run finishing after a second began must not overwrite
    /// the second's result, and a reset discards whatever is in flight.
    func testASupersededOrResetRunIsDiscarded() async {
        let action = SensitiveAction()
        var applied: [String] = []
        let (gate, open) = AsyncStream<Void>.makeStream()
        action.start(presentable: { true }) {
            for await _ in gate { break }
            return "first"
        } apply: { applied.append($0) }
        action.start(presentable: { true }) { "second" } apply: { applied.append($0) }
        await action.finish()
        open.yield()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(applied, ["second"])

        let (held, release) = AsyncStream<Void>.makeStream()
        action.start(presentable: { true }) {
            for await _ in held { break }
            return "late"
        } apply: { applied.append($0) }
        action.reset()
        XCTAssertFalse(action.busy)
        release.yield()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(applied, ["second"], "a reset run's result never reaches the view")
        XCTAssertNil(action.error)
    }

    /// The scene went to the background while the operation ran: the value
    /// is dropped, and the sheet's own reset clears the busy state.
    func testAResultIsDroppedWhenTheSceneCannotPresentIt() async {
        let action = SensitiveAction()
        var presentable = true
        var applied: [String] = []
        action.start(presentable: { presentable }) {
            presentable = false
            return "words"
        } apply: { applied.append($0) }
        await action.finish()
        XCTAssertEqual(applied, [])
        XCTAssertNil(action.error)
        action.reset()
        XCTAssertFalse(action.busy)
    }
}
